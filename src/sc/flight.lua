-- flight.lua -- the maths that flies a tank turn hull.
--
-- Pure. No peripherals, no screen, no files, no globals, exactly like
-- sc/util.lua. Everything is a function of its arguments, so all of it runs
-- under `starcatcher --test` on a computer that is not on a ship and has
-- nothing attached to it. `control.lua` is the shell that reads the pose, calls
-- in here and writes RPM.
--
-- Nothing in this file holds a tuning number. Every constant arrives in `cfg`,
-- which is the config module's values, and everything measured arrives in
-- `cal`. A default written in here would be a number the pilot cannot reach
-- from the TUNE tab, which is the one rule this codebase does not bend.
--
-- == The ship this describes ==
--
-- Five propellers all pointing along the hull, each reversible. Four are
-- turbines in left and right pairs, the fifth is the main propeller. There is
-- no sideways thrust and no vertical thrust. The ship turns by driving one side
-- against the other and holds altitude on a balloon.
--
-- == Conventions, which are worth reading before changing anything ==
--
-- Yaw is degrees, Minecraft convention, 0 facing +Z, and comes from
-- util.yawOf. Increasing yaw turns the ship to its own right.
--
-- Heading error is wrapAngle(bearing - yaw - noseOffset) and is positive when
-- the target is to the right.
--
-- Yaw rate is deg/s and is measured rather than differenced, out of
-- sublevel.getAngularVelocity().y, which is radians about world Y and runs
-- opposite to this yaw convention. control.lua does that conversion; by the
-- time a number reaches this file it is deg/s and positive means yaw rising.
--
-- RPM is signed, -256 to 256, positive being whichever direction calibration
-- found pushes the hull forward.
--
-- A differential is a single signed RPM meaning "this much harder on the left
-- than on the right". Positive raises yaw, which is the ship turning to its own
-- right, because a forward push on the left side is what swings the nose that
-- way. Getting this backwards flies a confident mirror image, so it is worth
-- saying twice: left harder, nose right, yaw rising.
--
-- == The shape of `cal` ==
--
-- What the calibration wizard leaves behind. Written down here because this is
-- the file that reads it.
--
--   sides        line key -> { side = "left"|"right"|"main"|"none", reverse }
--   noseOffset   degrees between the hull's +Z and where the main actually pushes
--   yawAuth      { left = deg/s per RPM, right = deg/s per RPM }
--   yawAccel     deg/s/s, how fast the hull gets up to a turn and out of one
--   yawCurve     { pos = ladder, neg = ladder }, differential RPM against yaw rate
--   fwdCurve     { pos = ladder, neg = ladder }, common RPM against settled speed
--   brakeCurve   { main = ladder, all = ladder }, reverse RPM against deceleration
--   balloonCurve ladder, redstone strength against climb rate
--   altHover     the strength that held level
--   stressAtTurn, stressAtCruise
--
-- A ladder is util's curve shape, a list of { rpm, speed } sorted by rpm, so
-- curveSpeedAt, curveRpmFor and curveTopSpeed all work on it unchanged. `speed`
-- carries deg/s in the yaw ladder and m/s/s in the brake ladders, which is a
-- liberty taken on purpose: reusing four tested functions beats four more
-- copies of the same interpolation. The brake ladder carries a third field,
-- `pitch`, that util neither knows nor needs to.

local util = ...

local flight = {}

-- == BEARINGS AND ERRORS =====================================

-- Which way to point to get from one place to the other, in the same units and
-- the same convention util.yawOf answers in, so the two can be subtracted.
function flight.bearingTo(x1, z1, x2, z2)
    local dx, dz = x2 - x1, z2 - z1
    if math.abs(dx) < 1e-9 and math.abs(dz) < 1e-9 then return 0 end
    return util.wrapAngle(math.deg(math.atan2(-dx, dz)))
end

-- Positive means the target is off to the right. noseOffset is what calibration
-- found between the hull's own +Z and the direction the main propeller actually
-- pushes, which on a ship built by hand is never quite zero.
function flight.headingError(bearing, yaw, noseOffset)
    return util.wrapAngle(bearing - yaw - (noseOffset or 0))
end

-- How far off the straight line between here and the target the ship has ended
-- up, in blocks, signed positive to the right. A hull that cannot strafe cannot
-- fix this without turning, which is why arrival has a whole behaviour for it.
function flight.lateralError(pos, target, yaw)
    local rad = math.rad(yaw)
    local fx, fz = -math.sin(rad), math.cos(rad)
    -- The ship's own right, which is forward crossed with up.
    local rx, rz = -fz, fx
    return (target.x - pos.x) * rx + (target.z - pos.z) * rz
end

-- == THE TANK TURN ===========================================

-- Heading error into a wanted yaw rate, capped. The cap is what keeps a large
-- error from asking for a rate the hull cannot hold, which would wind the
-- integral up against a ship that is already doing its best.
function flight.wantYawRate(err, pid, rateCap, dt)
    return util.clamp(pid:update(err, dt), -rateCap, rateCap)
end

-- The fastest the hull may still be turning at this heading error and be able
-- to stop on the heading rather than sail past it.
--
-- This is the braking distance sum, in degrees instead of metres. A hull that
-- can shed `accel` degrees a second every second needs `rate^2 / 2accel`
-- degrees to come to a stop, so at an error of `err` the most it can be doing
-- and still arrive is the square root of twice the deceleration times the
-- error. A proportional controller has no such term: it asks for the fastest
-- turn allowed until the error is small and then asks the hull to stop dead,
-- which a hull with any mass to it cannot do. That is not a gain that wants
-- raising, it is a sum that was missing.
--
-- `safety` is how much of the measured deceleration to trust. Less than all of
-- it, because the number was measured once, on a ship whose cargo moves.
--
-- The floor matters as much as the curve. Without it the profile asks for
-- nothing at all in the last fraction of a degree, the demand falls under
-- tankRpmMin, and the hull stops half a degree out for ever.
function flight.approachRate(err, accel, safety, floor)
    if not accel or accel <= 0 then return nil end
    local usable = accel * util.clamp(safety or 1, 0.05, 1)
    local rate = math.sqrt(2 * usable * math.abs(err))
    return math.max(rate, floor or 0)
end

-- Calibration gives deg/s of yaw per RPM for each side, and they differ,
-- because the two sides of a hand built hull are never the same distance out.
-- Equal torque needs the weaker side at full RPM and the stronger held back to
-- match, so the turn is symmetric and the hull does not crab through it.
function flight.sideScales(authL, authR)
    if not authL or not authR or authL <= 0 or authR <= 0 then return 1, 1 end
    local ref = math.min(authL, authR)
    return ref / authL, ref / authR
end

-- A wanted yaw rate back through the measured ladder into the differential RPM
-- that produced it, so the command is expressed in the units the ship was
-- measured in rather than in a gain somebody guessed.
--
-- Returns nil when there is no ladder, which is the caller's cue to fall back
-- on plain proportional rather than to invent a number here.
function flight.yawDifferential(wantRate, yawCurve, rpmCap)
    if not yawCurve then return nil end
    local ladder = wantRate >= 0 and yawCurve.pos or yawCurve.neg
    local rpm = util.curveRpmFor(ladder, math.abs(wantRate))
    if not rpm then return nil end
    return util.clamp(rpm, 0, rpmCap) * util.sign(wantRate)
end

-- How much differential a change of one degree a second of yaw is worth, in
-- RPM. Off the measured ladder when there is one, since that is exactly what
-- the ladder says, and off the configured limits when there is not.
--
-- This is the gain the inner loop needs and it is not a number anybody has to
-- choose: a hull that reaches its top rate at full differential answers a rate
-- error the size of that top rate with a full differential.
function flight.rpmPerRate(cal, cfg)
    local top = nil
    if cal.yawCurve then
        for _, way in ipairs({ "pos", "neg" }) do
            local speed = util.curveTopSpeed(cal.yawCurve[way])
            if speed and (not top or speed > top) then top = speed end
        end
    end
    if not top or top <= 0 then top = cfg.yawRateMax end
    if top <= 0 then return 0 end
    return cfg.tankRpmMax / top
end

-- Which way to point the hull so that the end of it the crew calls the front
-- ends up on a given heading.
--
-- The hull is what the autopilot can command and the front is what a pilot can
-- see, and on a ship whose +Z runs aft they are a half turn apart. The align
-- stage sends the ship to each point of the compass and asks where the front
-- came out, so the heading it commands has to be this one. Sending the hull
-- bare drives the front to the opposite point and files eight readings of the
-- same mistake.
--
-- With no offset known yet this is the heading itself, which is the only honest
-- answer on the first point of a first run.
function flight.hullHeadingFor(want, frontOffset)
    return util.wrapAngle(want - (frontOffset or 0))
end

-- The sampled turn: heading PID, stopping and sample limits, rate response,
-- ladder inversion, terminal coast check, then actuator minimum. Nothing may
-- replace the result with a fixed close-in push after these limits.
--
-- Model the measured hull as rate' = (equilibriumRate - rate) / tau.
-- The ladder supplies equilibriumRate and topRate / acceleration supplies tau.
-- This is a model, not a measurement of transient drag; the safety fraction
-- lengthens tau to leave room for a heavier hull.
function flight.yawResponse(cal, cfg)
    local slope = flight.rpmPerRate(cal, cfg)
    local top = slope > 0 and cfg.tankRpmMax / slope or cfg.yawRateMax
    local accel = cal.yawAccel
    if not accel or accel <= 0 then accel = cfg.yawAccelAssumed end
    local tau = top / (accel * cfg.yawBrakeSafety)
    return tau, accel
end

-- The sampled turn, with its ceilings handed in rather than read out of `cfg`.
--
-- Two callers with different authority share this arithmetic. A tank turn has
-- the whole differential and a hull that is not otherwise being pushed. A
-- running correction has a ceiling, a much slower rate, and a bearing that is
-- moving under it, so it cannot simply be given the tank result: the tank
-- minimum pulse exists to rescue a hull stopped dead outside the band, and a
-- ship at cruise speed is not stopped.
--
-- `limits` carries rpmMax, rpmMin, rateMax, fineBand and pulse, where pulse is
-- whether a demand under the minimum may be promoted to one minimum pulse.
function flight.yawCore(err, pid, cal, cfg, dt, haveRate, limits)
    dt = math.max(dt or 0, cfg.tick)
    local tau, accel = flight.yawResponse(cal, cfg)
    local floor = math.min(cfg.yawApproachMin, limits.fineBand / dt)
    local approach = flight.approachRate(err, accel, cfg.yawBrakeSafety, floor)
    -- Half the remaining error over a sample plus the hull response time gives
    -- two real, positive poles with the default rate gain in the linear model. The
    -- extra tau matters: err/dt alone ignores the motion while rate is changing.
    local stepCap = cfg.yawStepFraction * math.abs(err) / (dt + tau)
    local cap = math.min(limits.rateMax, approach, stepCap)
    local raw = flight.wantYawRate(err, pid, limits.rateMax, dt)
    local want = util.sign(err) * util.clamp(raw * util.sign(err), 0, cap)

    -- Invert the response over the period for which the command will be held:
    -- nextRate = decay * haveRate + (1 - decay) * equilibriumRate.
    -- An unbounded proportional rate correction can stop the current swing
    -- and start the opposite one before the next sample. Bound the inverse by
    -- yawRateKp too: an assumed slow hull may actually respond much faster.
    -- Full reverse remains available when stopping a fast swing requires it.
    local decay = math.exp(-dt / tau)
    local equilibrium = want
    local rateGain = math.min(cfg.yawRateKp, decay / (1 - decay))
    if haveRate then equilibrium = want + rateGain * (want - haveRate) end
    local diff = flight.yawDifferential(equilibrium, cal.yawCurve, limits.rpmMax)
    if not diff then
        diff = util.clamp(equilibrium / limits.rateMax, -1, 1) * limits.rpmMax
    end

    -- With zero thrust the model still travels rate * tau degrees. Both the
    -- current heading and that resting heading must fit before calling it done.
    -- No rate reading means no claim that the ship has stopped.
    local coast = haveRate and err - haveRate * tau or err
    local settleRate = limits.fineBand / (dt + tau)
    local settled = haveRate ~= nil and math.abs(err) <= limits.fineBand
        and math.abs(coast) <= limits.fineBand and math.abs(haveRate) <= settleRate
    if settled then
        diff, want = 0, 0
        pid:reset()
    else
        -- Include the mixer's minimum, or a command the turn thinks it sent
        -- disappears downstream. One minimum pulse rescues a hull stopped just
        -- outside the band, only toward both the current and resting heading.
        -- Promoting a tiny correction away from the heading restarts the swing.
        local minimum = math.max(limits.rpmMin, cfg.minRpm)
        if math.abs(diff) < minimum then
            if limits.pulse and math.abs(coast) > limits.fineBand
                    and diff * coast > 0 and diff * err > 0 then
                diff = util.sign(diff) * math.min(minimum, limits.rpmMax)
            else
                diff = 0
            end
        end
    end

    local scaleL, scaleR = flight.sideScales(
        cal.yawAuth and cal.yawAuth.left, cal.yawAuth and cal.yawAuth.right)
    return {
        left = diff * scaleL, right = -diff * scaleR, main = 0,
        rate = want, diff = diff, cap = cap, stepCap = stepCap,
        floor = floor, dt = dt, tau = tau, coast = coast,
        settled = settled, settleRate = settleRate, rateGain = rateGain,
    }
end

-- The tank turn: the whole differential, the whole rate, and the minimum pulse.
-- This wrapper is the behaviour the owner validated on the ship and the
-- baseline the regressions hold; the ceilings below are what it has always used.
function flight.tankDemand(err, pid, cal, cfg, dt, haveRate)
    return flight.yawCore(err, pid, cal, cfg, dt, haveRate, {
        rpmMax = cfg.tankRpmMax, rpmMin = cfg.tankRpmMin,
        rateMax = cfg.yawRateMax, fineBand = cfg.yawFineBand, pulse = true,
    })
end

-- Holding a heading while running. Worked out fresh on every control update,
-- off the measured rate, because a correction decided three seconds and thirty
-- six blocks ago is not feedback, it is a remembered actuator demand.
--
-- No minimum pulse: the hull is already being pushed along its own axis, so a
-- correction too small for the mixer to send is a correction not worth sending
-- rather than a ship stuck outside its band.
--
-- The side scales are not applied here. This returns a differential, and `mix`
-- is the one place a differential is split across the two sides.
function flight.cruiseYawDemand(err, pid, cal, cfg, dt, haveRate)
    return flight.yawCore(err, pid, cal, cfg, dt, haveRate, {
        rpmMax = cfg.yawTrimRpm, rpmMin = cfg.minRpm,
        rateMax = cfg.cruiseYawRateMax, fineBand = cfg.yawTrimThresh, pulse = false,
    })
end

-- == SPEED ===================================================

-- Thrust comes on over cruiseRampTime rather than all at once, because five
-- propellers going from nothing to full in one tick is a shove that costs more
-- stress than it buys speed.
function flight.throttleFraction(elapsed, tau)
    if not tau or tau <= 0 then return 1 end
    if elapsed <= 0 then return 0 end
    return 1 - math.exp(-elapsed / tau)
end

-- The fastest this ship may be going and still be able to stop in the distance
-- it has left. This replaces slowRadius entirely: a fixed radius is a guess
-- about the ship, and this is a measurement of it.
--
-- `lag` is the seconds between deciding a command and the propellers turning at
-- it, during which the ship keeps going at the speed it already had. Solving
-- `w*L + w*w/(2a) = d` for w is where the first term under the root comes from.
-- Without it a stop is planned as though reverse were instantaneous, which is
-- the arithmetic that lands a ship past the point having braked on time.
--
-- The margin is applied here, once, as a derate of the deceleration. Everything
-- that asks about stopping asks this function, so it is applied in one place
-- and no caller has to remember to divide by it again.
--
-- Returns nil, not infinity, when there is no deceleration to plan against. An
-- unmeasured direction is unknown, and unknown is not infinitely stoppable. The
-- caller names the unavailable case; it does not silently drop the constraint.
function flight.speedLimitForDistance(d, aMax, margin, lag)
    if not aMax or aMax <= 0 then return nil end
    if d <= 0 then return 0 end
    local a = aMax / math.max(margin or 1, 1e-9)
    local L = math.max(lag or 0, 0)
    return math.sqrt(a * L * a * L + 2 * a * d) - a * L
end

-- The braking rungs that are actually usable, in the direction the ship is
-- travelling. Rungs past the pitch limit are dropped before anything reads the
-- ladder, because a safe maximum on its own does not make every RPM under it
-- safe: interpolating the original ladder for a gentle stop can still land on a
-- rung the hull noses over at.
--
-- `cal.brakeResponse` is the directional shape, and `cal.brakeCurve` is the
-- legacy one. The brake stage runs up forwards and reverses, so the legacy
-- ladder is a measurement of stopping forward motion and nothing else. It is
-- read as the positive side only. Cloning it onto the negative side would be
-- calling a guess a measurement.
function flight.brakeLadder(cal, cfg, which, sign)
    which = which or "all"
    local way = (sign or 1) >= 0 and "pos" or "neg"
    local raw = nil
    if cal.brakeResponse and cal.brakeResponse[way] then
        raw = cal.brakeResponse[way][which]
    end
    if not raw and way == "pos" then
        raw = cal.brakeCurve and cal.brakeCurve[which]
    end
    if not raw or #raw == 0 then return nil end

    local kept = {}
    for _, rung in ipairs(raw) do
        if rung.pitch == nil or math.abs(rung.pitch) <= cfg.pitchLimit then
            kept[#kept + 1] = rung
        end
    end
    if #kept == 0 then return nil end
    return kept
end

-- How hard this ship can stop without tipping, off the usable rungs.
function flight.maxDecel(cal, cfg, which, sign)
    local ladder = flight.brakeLadder(cal, cfg, which, sign)
    if not ladder then return nil end
    return util.curveTopSpeed(ladder)
end

-- The deceleration a stop is planned against, and where the number came from.
-- Three answers and they are three because they mean three different things:
-- "measured" is the brake stage's ladder, "assumed" is brakeAccelAssumed with
-- nothing behind it, and "unavailable" is a direction with no bound at all.
-- Every screen and every row of telemetry carries which one it was.
function flight.brakeBound(cal, cfg, which, sign)
    local measured = flight.maxDecel(cal, cfg, which, sign)
    if measured and measured > 0 then return measured, "measured" end
    if cfg.brakeAssume and cfg.brakeAccelAssumed > 0 then
        return cfg.brakeAccelAssumed, "assumed"
    end
    return nil, "unavailable"
end

-- The fastest this ship has ever been measured travelling the way it is being
-- asked to travel. Asking politely does not make a saturated propeller faster.
function flight.fwdTop(cal, cfg, sign)
    local ladder = cal.fwdCurve and cal.fwdCurve[(sign or 1) >= 0 and "pos" or "neg"]
    local top = ladder and util.curveTopSpeed(ladder)
    if top and top > 0 then return top end
    return cfg.cruiseSpeed
end

-- The longitudinal response model: `dv/dt = (u - v) / tau`, where u is the
-- speed a held thrust command settles at. Exactly the shape the turn uses, and
-- exactly as much of an assumption: the ladder measures where the ship ends up,
-- never how it got there.
--
-- Nothing on this ship has measured a forward response yet. So unless
-- `cal.fwdResponse` has been filled in by hand, this is the assumed
-- acceleration, said to be assumed, and the safety fraction lengthens tau
-- because a longer modelled response asks for less per sample.
function flight.fwdResponse(cal, cfg, sign)
    local way = (sign or 1) >= 0 and "pos" or "neg"
    local measured = cal.fwdResponse and cal.fwdResponse[way]
    local top = flight.fwdTop(cal, cfg, sign)

    local accel = measured and measured.accel
    local source = "measured"
    if cfg.fwdAssumeResponse or not accel or accel <= 0 then
        accel, source = cfg.fwdAccelAssumed, "assumed"
    end
    if accel <= 0 then accel = 0.05 end

    local tau = source == "measured" and measured.tau or nil
    if not tau or tau <= 0 then
        tau = top / (accel * util.clamp(cfg.fwdBrakeSafety, 0.05, 1))
    end
    return math.max(tau, cfg.tick), accel, source
end

-- Everything between deciding a command and the propellers turning at it: the
-- slew, the radio, the relay's own loop. It is not measured either, which is
-- why it is one named setting rather than three guesses in three files.
function flight.actuatorLag(cfg)
    return math.max(cfg.actuatorLag or 0, 0)
end

-- What a held command does over a period, under the response model above.
-- Returns the speed at the end of the hold and the distance covered getting
-- there. Both the governor and the terminal check are written in terms of this
-- rather than of a step, because a command is held for a whole period and the
-- motion during that period is the thing that overshoots.
function flight.holdMotion(v, u, tau, h)
    if h <= 0 then return v, 0 end
    local b = math.exp(-h / tau)
    return b * v + (1 - b) * u, u * h + (v - u) * tau * (1 - b)
end

-- The reference ramp. Thrust comes on over cruiseRampTime rather than all at
-- once, because five propellers going from nothing to full in one tick is a
-- shove that costs more stress than it buys speed.
--
-- This is the requested speed and nothing more. It used to cap itself on the
-- stopping distance, which put the envelope in one of the two places that need
-- it; `motionPlan` is the other, and is now the only one.
function flight.wantSpeed(elapsed, cfg, cal)
    local want = cfg.cruiseSpeed * flight.throttleFraction(elapsed, cfg.cruiseRampTime)
    return math.min(want, flight.fwdTop(cal, cfg, 1))
end

-- == THE SIGNED SPEED GOVERNOR ===============================
--
-- `req` is what the caller wants and what the ship is doing:
--
--   requested   signed speed asked for, m/s. Negative is travel astern.
--   remaining   signed blocks left along the committed travel axis. Negative
--               means the ship has gone past the point, which a radial
--               distance cannot say and which decides everything below.
--   v           signed speed along the hull, m/s
--   vValid      false when the velocity read failed. A zero velocity from a
--               failed read is not a ship at rest.
--   horizontal  speed through the air, m/s, for the terminal check
--   lateral     blocks off the committed line
--   allowAway   the caller has a reason to travel away from the point
--
-- `memory` is the caller's, not this file's. It carries the last reference, the
-- approach direction across a zero crossing, and the speed trim.
--
-- The governor's order is requested speed, reachable range, acceleration bounds
-- over the period, then the stopping envelope last so nothing can undo it.
function flight.motionPlan(req, cal, cfg, dt, memory)
    dt = math.max(dt or 0, cfg.tick)
    memory = memory or {}
    local v = req.v or 0
    local valid = req.vValid ~= false
    local remaining = req.remaining or 0
    local requested = req.requested or 0

    -- Which way the point lies. At zero it is whichever way the ship came in,
    -- kept in the caller's memory, because a sign read off a distance that is
    -- crossing zero chatters between the two answers every update.
    local toward = util.sign(remaining)
    if toward == 0 then toward = memory.approach or 1 end
    memory.approach = toward

    -- Braking opposes the motion the ship actually has, never the travel the
    -- pilot wants. At rest the approach direction stands in for it.
    local moveSign = util.sign(v)
    if moveSign == 0 then moveSign = toward end

    local tau, accel, response = flight.fwdResponse(cal, cfg, requested ~= 0 and requested or moveSign)
    local aMax, envelope = flight.brakeBound(cal, cfg, "all", moveSign)
    local lag = flight.actuatorLag(cfg)

    -- The arrival band is reserved before anything else is allowed to spend the
    -- distance, so a stop is planned to end at the edge of the band rather than
    -- on the point with the band as an afterthought.
    local available = math.max(0, math.abs(remaining) - cfg.arriveDist)
    local allowed = flight.speedLimitForDistance(available, aMax, cfg.brakeMargin, lag)
    local needed = aMax and (math.abs(v) * lag
        + v * v * cfg.brakeMargin / (2 * aMax)) or nil

    local reason
    local vRef = util.clamp(requested,
        -flight.fwdTop(cal, cfg, -1), flight.fwdTop(cal, cfg, 1))

    if requested == 0 then
        -- A commanded zero is a zero. Nothing below may floor it into a push.
        vRef, reason = 0, "asked for nothing"
    elseif vRef * toward < 0 and not req.allowAway then
        vRef, reason = 0, "the point is behind the way it is being asked to go"
    else
        -- Bound the reference by what the hull can actually do over this period,
        -- measured from the reference it was last given rather than from the
        -- speed it has, so a lagging ship does not drag the reference down with
        -- it and stall the leg.
        local previous = memory.vRef or v
        local up = accel * dt * cfg.fwdStepFraction
        local down = (aMax or accel) * dt
        vRef = util.clamp(vRef, previous - down, previous + up)

        -- The trim covers a headwind or a heavier hull than the day the ladder
        -- was measured, and nothing faster than that. It is frozen while the
        -- propellers are saturated, so it cannot wind up against a ship that is
        -- already doing its best.
        if valid and not memory.saturated then
            local trim = (memory.trim or 0) + (requested - v) * cfg.fwdTrimKi * dt
            memory.trim = util.clamp(trim, -cfg.fwdTrimMax, cfg.fwdTrimMax)
        end
        vRef = vRef + (memory.trim or 0) * util.sign(vRef)

        -- The envelope last, so no earlier stage and no later floor can put the
        -- reference above what the remaining distance allows.
        if allowed then
            if math.abs(vRef) > allowed then vRef = util.sign(vRef) * allowed end
            reason = string.format("%.1f m/s allowed with %.0f blk of room", allowed, available)
        else
            vRef = 0
            reason = "nothing has measured or assumed a stop in this direction"
        end
    end

    -- The terminal state. Every one of these, because each rules out a
    -- different way of looking stopped without being stopped: a failed velocity
    -- read, a hull sliding through the band, sideways drift a hull that cannot
    -- strafe has no way to null, and a coast that leaves the band after thrust
    -- ends.
    local coast = select(2, flight.holdMotion(v, 0, tau, dt + lag))
    local settled = valid
        and math.abs(remaining) <= cfg.arriveDist
        and math.abs(v) <= cfg.arriveSpeed
        and (req.horizontal or 0) <= cfg.arriveDrift
        and math.abs(req.lateral or 0) <= cfg.lateralCorrect
        and math.abs(remaining - coast) <= cfg.arriveDist
    if settled then
        vRef, reason = 0, "stopped inside the band and coasting to a stop inside it"
        memory.trim = 0
    end

    memory.vRef = vRef
    return {
        vRef = vRef, v = v, valid = valid, remaining = remaining, toward = toward,
        allowed = allowed, available = available, envelope = envelope,
        aBrake = aMax, lag = lag, tau = tau, accel = accel, response = response,
        needed = needed, coast = coast, settled = settled, reason = reason,
        trim = memory.trim or 0,
    }
end

-- The plan into commands for the main and for the turbines, both signed RPM.
--
-- One path for cruising, creeping and stopping. Which of those it is falls out
-- of the arithmetic rather than being decided beforehand: an equilibrium speed
-- opposite to the motion the ship has is a brake, and the brake ladders are the
-- measured data for that case, so it is read off them instead of off the
-- forward ladder.
function flight.longitudinalDemand(plan, cal, cfg, dt, memory)
    dt = math.max(dt or 0, cfg.tick)
    memory = memory or {}
    local v, vRef = plan.v, plan.vRef

    if plan.settled then
        memory.saturated = false
        return { main = 0, turbines = 0, mode = "hold", u = 0,
            reason = plan.reason or "stopped" }
    end

    -- The equilibrium speed a held command has to settle at for the ship to
    -- arrive at vRef by the end of the hold. The gain is the inverse of the
    -- model over that horizon, bounded by fwdRateKp, because an assumed
    -- response may be badly wrong about a hull and an unbounded inverse would
    -- amplify that error rather than correct for it.
    local horizon = dt + plan.lag
    local decay = math.exp(-horizon / plan.tau)
    local gain = math.min(cfg.fwdRateKp, decay / math.max(1 - decay, 1e-9))
    local u = vRef
    if plan.valid then u = vRef + gain * (vRef - v) end

    -- Braking is the same envelope the phase machine and the governor use, and
    -- it is read against the speed magnitude. That is the sign error that let a
    -- ship moving backwards past its stopping limit sail on: the old check
    -- compared a signed speed against a limit that is never negative.
    --
    -- Above the envelope the brake ladders are the measured data and this is a
    -- stop. Under it, a slower reference is met by asking the propellers for
    -- less, which is what the forward ladder measures and is gentler than
    -- reversing for a speed the distance never demanded reversing for.
    -- A ship at rest reads a velocity of a thousandth of a metre a second with
    -- whatever sign the physics engine last had, and asking that sign whether
    -- the ship is going the wrong way turns the first update of every leg into
    -- a stop. Below the speed that counts as stopped there is nothing to brake.
    local moving = math.abs(v) > cfg.arriveSpeed
    local over = plan.allowed ~= nil and math.abs(v) > plan.allowed and moving
    local braking = over or (moving and (u * v < 0 or vRef == 0))
    if not braking then
        local ladder = cal.fwdCurve and cal.fwdCurve[u >= 0 and "pos" or "neg"]
        local feed = util.curveRpmFor(ladder, math.abs(u))
        local rpm = (feed or math.abs(u) / math.max(flight.fwdTop(cal, cfg, u), 1e-9)
            * cfg.cruiseMaxRpm) * util.sign(u)
        rpm = util.clamp(rpm, -cfg.cruiseMaxRpm, cfg.cruiseMaxRpm)
        memory.saturated = math.abs(rpm) >= cfg.cruiseMaxRpm - 1e-9

        local resolution = nil
        if rpm ~= 0 and math.abs(rpm) < cfg.cruiseMinRpm then
            -- Not silently dropped. A creep the mixer cannot send is a
            -- resolution limit of this ship, and the pilot is told which one.
            resolution = string.format("%.1f m/s needs under the %d rpm the mixer sends",
                math.abs(vRef), cfg.cruiseMinRpm)
            rpm = 0
        end
        return { main = rpm, turbines = rpm, mode = "drive", u = u,
            resolution = resolution, saturated = memory.saturated,
            reason = resolution or string.format("holding %.1f m/s", vRef) }
    end

    -- How hard it has to stop: enough to fit inside the distance that is left,
    -- and enough to be back under the envelope by the end of the hold,
    -- whichever is more, and never more than the ladder says is safe. The
    -- margin is in the distance term and nowhere else, so it is applied once.
    local moveSign = util.sign(v)
    local aRoom = plan.available > 0
        and (v * v * cfg.brakeMargin) / (2 * plan.available) or math.huge
    local aBack = plan.allowed
        and (math.abs(v) - plan.allowed) / horizon or math.abs(v) / horizon
    local aReq = math.max(aRoom, aBack, 0)
    if plan.aBrake then aReq = math.min(aReq, plan.aBrake) end

    -- Do not turn a completed stop into a backward launch. The command is held
    -- for a whole period plus its own delay, and a demand that would carry the
    -- speed through zero is cut to the one that arrives at zero.
    local toZero = math.abs(v) / horizon
    local clipped = false
    if aReq > toZero then aReq, clipped = toZero, true end

    local mainMax = flight.maxDecel(cal, cfg, "main", moveSign)
    local which = (mainMax and aReq <= mainMax) and "main" or "all"
    local ladder = flight.brakeLadder(cal, cfg, which, moveSign)
    local rpm
    if ladder then
        rpm = util.curveRpmFor(ladder, aReq)
    else
        -- No usable rungs in this direction. The demand is still real, so it is
        -- scaled off the assumed bound rather than dropped: a lack of data is
        -- not a reason to ask for no brake at all.
        local bound = plan.aBrake or cfg.brakeAccelAssumed
        rpm = cfg.brakeRpmMax * util.clamp(aReq / math.max(bound, 1e-9), 0, 1)
    end
    rpm = util.clamp(rpm or 0, 0, cfg.brakeRpmMax) * -moveSign
    memory.saturated = math.abs(rpm) >= cfg.brakeRpmMax - 1e-9

    local resolution = nil
    if rpm ~= 0 and math.abs(rpm) < cfg.minRpm then
        resolution = string.format("%.2f m/s/s needs under the %d rpm the mixer sends",
            aReq, cfg.minRpm)
        rpm = 0
    end

    local reason
    if resolution then
        reason = resolution
    elseif clipped then
        reason = string.format("%s, cut to land on zero", which == "main"
            and "main alone" or "all five")
    else
        reason = string.format("%s, %.1f m/s/s", which == "main" and "main alone" or "all five", aReq)
    end

    return {
        main = rpm, turbines = which == "all" and rpm or 0,
        mode = "brake", which = which, u = u, aReq = aReq,
        clipped = clipped, resolution = resolution, saturated = memory.saturated,
        reason = reason,
    }
end

-- == ALLOCATION ==============================================
--
-- What the two sides can actually be told, before rounding. For a turbine base
-- command c after its share, side scales l and r, and a per line limit R, the
-- differential d has to satisfy both sides at once:
--
--     (-R-c)/l <= d <= (R-c)/l        the left line
--     (c-R)/r  <= d <= (c+R)/r        the right line
--
-- At c = R there is no positive headroom on the left at all. Clipping the one
-- side that ran out changes the common thrust as well as losing the steering,
-- which is a stop that quietly becomes a turn. So when `reserve` is set the
-- common thrust is held back instead, and the caller is told what it actually
-- got rather than what it asked for.
function flight.allocateMotion(mainCommon, turbineCommon, differential, cal, cfg, reserve)
    local scaleL, scaleR = flight.sideScales(
        cal.yawAuth and cal.yawAuth.left, cal.yawAuth and cal.yawAuth.right)
    local share = cfg.turbineShare
    local R = cfg.maxRpm
    local c = turbineCommon * share

    local function room(base)
        return math.max((-R - base) / scaleL, (base - R) / scaleR),
               math.min((R - base) / scaleL, (base + R) / scaleR)
    end

    local lo, hi = room(c)
    local given = util.clamp(differential, lo, hi)
    local held = 0

    if reserve and math.abs(given) < math.abs(differential) - 1e-9 then
        -- Hold the turbines back to exactly the thrust that leaves room for the
        -- differential that was asked for, and no further.
        local need = math.abs(differential) * math.max(scaleL, scaleR)
        local ceiling = math.max(R - need, 0)
        local wanted = util.clamp(c, -ceiling, ceiling)
        held = c - wanted
        c = wanted
        lo, hi = room(c)
        given = util.clamp(differential, lo, hi)
    end

    return {
        main = mainCommon,
        turbines = share > 1e-9 and c / share or 0,
        differential = given,
        requested = differential,
        held = held,
        lo = lo, hi = hi,
        saturated = math.abs(given) < math.abs(differential) - 1e-9,
    }
end

-- == MIXING ==================================================

-- Common thrust and a differential across whatever lines the ship turned out to
-- have. The side a line is on and which way it has to spin both come from
-- calibration, so a propeller mounted backwards is a flag in a file rather than
-- a special case in here.
function flight.mix(common, differential, lines, cal, cfg)
    return flight.mixParts(common, common, differential, lines, cal, cfg)
end

-- The same, with the main propeller and the turbines given their own thrust.
-- Graduated braking is the reason this exists: a plan that reverses the main
-- alone has to reach the propellers as the main alone, and a single common
-- number cannot say that.
function flight.mixParts(mainCommon, turbineCommon, differential, lines, cal, cfg)
    local scaleL, scaleR = flight.sideScales(
        cal.yawAuth and cal.yawAuth.left, cal.yawAuth and cal.yawAuth.right)

    local out = {}
    for _, name in ipairs(lines) do
        local entry = cal.sides and cal.sides[name]
        local side = entry and entry.side or "none"
        local rpm = 0

        if side == "main" then
            rpm = mainCommon * cfg.mainShare
        elseif side == "left" then
            rpm = turbineCommon * cfg.turbineShare + differential * scaleL
        elseif side == "right" then
            rpm = turbineCommon * cfg.turbineShare - differential * scaleR
        end

        if entry and entry.reverse then rpm = -rpm end

        rpm = util.clamp(rpm, -cfg.maxRpm, cfg.maxRpm)
        if math.abs(rpm) < cfg.minRpm then rpm = 0 end
        out[name] = util.round(rpm)
    end
    return out
end

-- How much a line may change on this update. The per update figure is what the
-- turn was validated with and is what `slewTimed` off keeps. The timed figure
-- is the honest one on a loop whose period moves: sixteen RPM an update is a
-- different ramp at dt 0.3 than at dt 1.2, and the stopping planner prices
-- neither.
function flight.slewLimit(cfg, braking, dt)
    if cfg.slewTimed then
        local rate = braking and cfg.brakeSlewRate or cfg.rpmSlewRate
        return rate * math.max(dt or 0, 0)
    end
    return braking and cfg.brakeSlew or cfg.rpmSlew
end

-- How fast a line may change. Suddenness is what tips the hull and what spikes
-- the stress, and neither shows up in a steady state test.
--
-- `carry`, when the caller keeps one, is the fraction of RPM that rounding
-- threw away last time. Relays take integers only, so without it a slew of
-- under half an RPM an update rounds to nothing for ever and the line never
-- moves at all.
function flight.applySlew(previous, wanted, slew, carry)
    local out = {}
    for name, want in pairs(wanted) do
        local was = (previous[name] or 0) + (carry and carry[name] or 0)
        local step = want - was
        if step > slew then step = slew elseif step < -slew then step = -slew end
        local exact = was + step
        local rounded = util.round(exact)
        if carry then carry[name] = exact - rounded end
        out[name] = rounded
    end
    return out
end

-- == THE BALLOON =============================================

-- The balloon ladder is the one measured curve util's family cannot read. Every
-- other ladder is a magnitude against a magnitude, and this one crosses zero:
-- strength 0 sinks, strength 15 climbs, and the level that holds is somewhere in
-- between. curveRpmFor takes absolute values and would fold the sinking half
-- onto the climbing half. So this walks the ladder itself.
function flight.levelForClimb(curve, climb)
    if not curve or #curve == 0 then return nil end
    if climb <= curve[1].speed then return curve[1].rpm end
    for index = 1, #curve - 1 do
        local a, b = curve[index], curve[index + 1]
        if climb <= b.speed then
            local span = b.speed - a.speed
            local t = math.abs(span) > 1e-9 and (climb - a.speed) / span or 0
            return a.rpm + (b.rpm - a.rpm) * t
        end
    end
    return curve[#curve].rpm
end

-- Altitude error into a redstone strength. Proportional on the error, damped on
-- the vertical speed the ship already has, then through the ladder into the
-- level that produced that climb rate.
--
-- The floor is not a tuning nicety. A balloon commanded to zero is a ship on its
-- way down, and the pilot asked for a slower climb, not for that.
function flight.balloonLevel(altErr, vspeed, cal, cfg)
    local want = 0
    if math.abs(altErr) > cfg.altDeadband then
        want = altErr * cfg.altKp
    end
    want = want - (vspeed or 0) * cfg.altKd
    want = util.clamp(want, -cfg.sinkRateMax, cfg.climbRateMax)

    local level = flight.levelForClimb(cal.balloonCurve, want)
    if not level then
        -- No ladder yet. The hover level is the only honest starting point, and
        -- holding is better than guessing a climb rate on an uncalibrated ship.
        level = cal.altHover or cfg.balloonFloor
    end

    level = util.clamp(util.round(level), cfg.balloonFloor, 15)
    return level
end

-- == BUDGETS =================================================

-- What a leg will cost in seconds. The engine burns at a flat rate whatever the
-- propellers do, so this is the whole fuel question: a leg is affordable when
-- the time it takes fits inside the fuel that is the captain's to spend.
function flight.legTime(dist, headingChange, altChange, cal, cfg)
    local turnRate = cfg.yawRateMax
    if cal.yawCurve then
        local top = util.curveTopSpeed(cal.yawCurve.pos)
        if top and top > 0 and top < turnRate then turnRate = top end
    end
    local turnTime = turnRate > 0 and math.abs(headingChange or 0) / turnRate or 0

    local climbRate = nil
    if cal.balloonCurve and #cal.balloonCurve > 0 then
        climbRate = math.abs(cal.balloonCurve[#cal.balloonCurve].speed)
    end
    local climbTime = (climbRate and climbRate > 0)
        and math.abs(altChange or 0) / climbRate or 0

    local cruiseSpeed = cfg.cruiseSpeed
    local top = cal.fwdCurve and util.curveTopSpeed(cal.fwdCurve.pos)
    if top and top > 0 and top < cruiseSpeed then cruiseSpeed = top end
    local cruiseTime = cruiseSpeed > 0 and (dist or 0) / cruiseSpeed or 0

    local aMax = flight.maxDecel(cal, cfg)
    local brakeTime = (aMax and aMax > 0) and cruiseSpeed / aMax or 0

    return turnTime + climbTime + cruiseTime + brakeTime
end

-- Stress is the other resource and it gates a different question: not how long
-- the ship can fly but how hard it can push at one instant. Calibration records
-- what a full turn and a full cruise each drew.
function flight.stressNeeded(phase, cal)
    if phase == "tank" then return cal.stressAtTurn or 0 end
    if phase == "cruise" then return cal.stressAtCruise or 0 end
    if phase == "brake" then
        return math.max(cal.stressAtTurn or 0, cal.stressAtCruise or 0)
    end
    return 0
end

-- == THE PHASE MACHINE =======================================

-- `state` carries everything the decision is made on, because the alternative is
-- a nine argument function whose call sites are impossible to read:
--
--   err        heading error, deg
--   yawRate    deg/s, measured
--   d          distance to the target, blocks
--   remaining  signed blocks along the committed travel axis. Defaults to d,
--              which is the same thing until the ship has gone past the point.
--   v          speed along the hull, m/s
--   lateral    blocks off the bearing
--   alignedFor seconds the ship has been inside the padding and steady
--   stopped    true when the ship has come to rest
--
-- Returns the next phase and, always, why. The reason goes on the screen.
function flight.phaseNext(phase, state, cfg, cal)
    if phase == "tank" then
        if math.abs(state.err) <= cfg.tankPadding
            and math.abs(state.yawRate) <= cfg.tankHoldRate then
            -- Both conditions, not just the angle. A hull still swinging through
            -- the padding band would commit mid swing and need correcting again
            -- a second later.
            if (state.alignedFor or 0) >= cfg.tankHold then
                return "cruise", "lined up and steady"
            end
            return "tank", "lined up, holding"
        end
        return "tank", string.format("%.0f deg to turn", state.err)
    end

    if phase == "cruise" then
        if math.abs(state.err) > cfg.tankReentry then
            return "tank", string.format("%.0f deg off, turning again", state.err)
        end
        -- The same envelope the speed governor uses, on the same reserved
        -- distance, against the speed magnitude rather than the signed speed.
        -- Comparing a signed speed to a limit that is never negative is how a
        -- ship travelling backwards past the point never entered a stop at all.
        local remaining = state.remaining or state.d
        local moveSign = util.sign(state.v)
        if moveSign == 0 then moveSign = util.sign(remaining) end
        local aMax, envelope = flight.brakeBound(cal, cfg, "all", moveSign)
        local available = math.max(0, math.abs(remaining) - cfg.arriveDist)
        local vLimit = flight.speedLimitForDistance(available, aMax, cfg.brakeMargin,
            flight.actuatorLag(cfg))
        if not vLimit then
            return "brake", "no stopping distance is known in this direction"
        end
        if math.abs(state.v) > vLimit then
            return "brake", string.format("%.1f m/s with %.0f blk left, %s",
                math.abs(state.v), math.abs(remaining), envelope)
        end
        return "cruise", "running"
    end

    if phase == "brake" then
        if state.stopped then
            if math.abs(state.lateral or 0) > cfg.lateralCorrect then
                return "tank", string.format("%.1f blk off the line", state.lateral)
            end
            if state.d <= cfg.arriveDist then
                return "arrived", string.format("%.1f blk out", state.d)
            end
            return "tank", string.format("%.0f blk short", state.d)
        end
        return "brake", "stopping"
    end

    return phase, "holding"
end

-- == WHAT A SETTING MEANS ON THIS SHIP =======================
--
-- The TUNE tab's preview. A number on its own is not a decision: 256 RPM is
-- meaningless until it is the speed this hull was measured doing at 256 RPM.
-- Everything here runs the value back through what calibration measured, and
-- every one of them returns nil rather than a guess when the stage that would
-- have measured it has not been run. An invented preview is worse than none,
-- because a pilot would tune against it.
--
-- Pure, like the rest of this file, so the sentences are checkable without a
-- ship: the wording is the part worth testing.

-- The balloon ladder is a level against a climb rate and is walked rather than
-- read through util's curve family, for the same reason levelForClimb is.
function flight.climbAtLevel(curve, level)
    if not curve or #curve == 0 then return nil end
    if level <= curve[1].rpm then return curve[1].speed end
    for index = 1, #curve - 1 do
        local a, b = curve[index], curve[index + 1]
        if level <= b.rpm then
            local span = b.rpm - a.rpm
            local t = math.abs(span) > 1e-9 and (level - a.rpm) / span or 0
            return a.speed + (b.speed - a.speed) * t
        end
    end
    return curve[#curve].speed
end

function flight.preview(key, value, cal, cfg)
    cal = cal or {}
    local fwd = cal.fwdCurve and cal.fwdCurve.pos
    local yaw = cal.yawCurve and cal.yawCurve.pos

    if key == "cruiseMaxRpm" then
        local speed = util.curveSpeedAt(fwd, value)
        return speed and string.format("this ship ran %.1f m/s at %d rpm", speed, value)
    end

    if key == "cruiseSpeed" then
        local rpm = util.curveRpmFor(fwd, value)
        local top = util.curveTopSpeed(fwd)
        if top and value > top then
            return string.format("more than the %.1f m/s it has ever been measured doing", top)
        end
        return rpm and string.format("about %d rpm on the measured ladder", util.round(rpm))
    end

    if key == "tankRpmMax" or key == "yawTrimRpm" then
        local rate = util.curveSpeedAt(yaw, value)
        return rate and string.format("this hull came round at %.1f deg/s on %d differential",
            rate, value)
    end

    if key == "yawRateMax" then
        local rpm = util.curveRpmFor(yaw, value)
        local top = util.curveTopSpeed(yaw)
        if top and value > top then
            return string.format("faster than the %.1f deg/s it has ever turned", top)
        end
        return rpm and string.format("about %d differential rpm", util.round(rpm))
    end

    if key == "brakeRpmMax" then
        local ladder = cal.brakeCurve and cal.brakeCurve.all
        local decel = util.curveSpeedAt(ladder, value)
        return decel and string.format("all five stopped at %.1f m/s/s on %d rpm reverse",
            decel, value)
    end

    if key == "pitchLimit" then
        local capped = flight.maxDecel(cal, { pitchLimit = value }, "all")
        if not capped then return nil end
        return string.format("leaves %.1f m/s/s of the measured braking usable", capped)
    end

    if key == "brakeMargin" then
        local aMax = flight.maxDecel(cal, cfg, "all")
        if not aMax or aMax <= 0 then return nil end
        local v = cfg.cruiseSpeed
        return string.format("a stop from %.0f m/s begins %.0f blocks out",
            v, v * v * value / (2 * aMax))
    end

    if key == "balloonFloor" then
        local climb = flight.climbAtLevel(cal.balloonCurve, value)
        if not climb then return nil end
        if climb < 0 then
            return string.format("strength %d was measured sinking at %.2f m/s", value, -climb)
        end
        return string.format("strength %d was measured climbing at %.2f m/s", value, climb)
    end

    if key == "fuelReserve" or key == "fuelWarn" or key == "fuelCrit" then
        return nil   -- these are percentages of a tank, and a tank is not measured here
    end

    return nil
end

return flight
