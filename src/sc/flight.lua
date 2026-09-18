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

-- The whole tank phase in one call: rotate, do not translate.
--
-- The pid is an argument rather than something this module keeps, because a
-- module that keeps state is a module that cannot be tested twice in one run.
--
-- `haveRate` is what the hull is actually doing, and without it this is a turn
-- flown blind. The ladder says what differential holds a rate once the hull has
-- settled at it, which is a fine thing to ask for and no way to stop: a hull
-- asked for a slower turn simply gets less push, and coasts through the heading
-- on the momentum it already had. Nothing in that loop can ever command the
-- other way. That is the overshoot, and no gain fixes it, because the number
-- that says to reverse is one this function was never given.
--
-- So the demand is the ladder's feed forward plus the error between the rate
-- wanted and the rate there is. When the hull is turning faster than the
-- approach allows, that term goes negative and the propellers push the other
-- way, which is what stopping is.
function flight.tankDemand(err, pid, cal, cfg, dt, haveRate)
    local wantRate = flight.wantYawRate(err, pid, cfg.yawRateMax, dt)

    -- Held down to what can still be stopped in the error that is left, and
    -- only when the demand is driving the hull towards the heading. A demand
    -- pointing the other way is the controller braking an overshoot out, and
    -- limiting that would be limiting the recovery by how small the mistake
    -- is: the tighter the overshoot the weaker the correction allowed, which
    -- is backwards and was measured as such.
    local limit = flight.approachRate(err, cal.yawAccel, cfg.yawBrakeSafety,
        cfg.yawApproachMin)
    if limit and wantRate * err > 0 and math.abs(wantRate) > limit then
        wantRate = util.sign(wantRate) * limit
    end

    local diff = flight.yawDifferential(wantRate, cal.yawCurve, cfg.tankRpmMax)

    if not diff then
        -- No ladder yet, so the best available statement is that a full rate
        -- deserves full RPM. Calibration replaces this with the truth.
        diff = cfg.tankRpmMax * util.clamp(wantRate / cfg.yawRateMax, -1, 1)
    end

    -- The inner loop: what the hull is doing against what it was asked for.
    -- Feed forward alone holds a rate; this is what changes one, and it is the
    -- only term in the whole turn that can put the propellers into reverse.
    if haveRate and (cfg.yawRateKp or 0) > 0 then
        local slope = flight.rpmPerRate(cal, cfg)
        diff = diff + (wantRate - haveRate) * slope * cfg.yawRateKp
        diff = util.clamp(diff, -cfg.tankRpmMax, cfg.tankRpmMax)
    end

    -- Below the minimum a speed controller buzzes without turning anything, so
    -- a demand that small is worth nothing and costs stress.
    if math.abs(diff) < cfg.tankRpmMin then diff = 0 end

    local scaleL, scaleR = flight.sideScales(
        cal.yawAuth and cal.yawAuth.left, cal.yawAuth and cal.yawAuth.right)

    return {
        left  = util.clamp(diff * scaleL, -cfg.tankRpmMax, cfg.tankRpmMax),
        right = util.clamp(-diff * scaleR, -cfg.tankRpmMax, cfg.tankRpmMax),
        main  = 0,
        rate  = wantRate,
        diff  = diff,
    }
end

-- Cruise holds its heading with a much smaller differential than a turn uses,
-- because the point is to stop the drift rather than to swing the hull. The
-- error is scaled against the angle that would send it back to the tank phase,
-- so a trim reaches its own ceiling exactly where trimming stops being enough.
--
-- The side scales are not applied here. This returns a differential, and `mix`
-- is the one place a differential is split across the two sides.
function flight.yawTrim(err, cfg)
    if math.abs(err) < cfg.yawTrimThresh then return 0 end
    return util.clamp(err / cfg.tankReentry, -1, 1) * cfg.yawTrimRpm
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
function flight.speedLimitForDistance(d, aMax, margin)
    if not aMax or aMax <= 0 then return math.huge end
    if d <= 0 then return 0 end
    return math.sqrt(2 * aMax * d / (margin or 1))
end

-- How hard this ship can stop without tipping, off the measured brake ladder.
-- The cap is the last rung that kept pitch inside the limit, so a hull that
-- noses over at full reverse is never asked to plan around full reverse.
function flight.maxDecel(cal, cfg, which)
    local ladder = cal.brakeCurve and cal.brakeCurve[which or "all"]
    if not ladder or #ladder == 0 then return nil end
    local best = nil
    for _, rung in ipairs(ladder) do
        if rung.pitch == nil or math.abs(rung.pitch) <= cfg.pitchLimit then
            if best == nil or rung.speed > best then best = rung.speed end
        end
    end
    return best
end

function flight.wantSpeed(d, elapsed, cfg, cal)
    local want = cfg.cruiseSpeed * flight.throttleFraction(elapsed, cfg.cruiseRampTime)
    local limit = flight.speedLimitForDistance(d, flight.maxDecel(cal, cfg), cfg.brakeMargin)
    if limit < want then want = limit end
    -- Never ask for more than the ship has ever been seen to do. Asking politely
    -- does not make a saturated propeller faster, it only winds the integral up.
    local top = cal.fwdCurve and util.curveTopSpeed(cal.fwdCurve.pos)
    if top and top > 0 and want > top then want = top end
    return want
end

-- Feed forward off the measured ladder, trimmed by a PID on what the ship is
-- actually doing. The ladder is what gets it roughly right on the first tick;
-- the trim is what covers everything the ladder did not know about, a headwind
-- or a heavier hull than the day it was measured.
function flight.thrustRpm(want, have, fwdCurve, pid, dt, cap)
    local ladder = nil
    if fwdCurve then ladder = want >= 0 and fwdCurve.pos or fwdCurve.neg end
    local feed = util.curveRpmFor(ladder, math.abs(want))
    local rpm = (feed or 0) * util.sign(want)
    rpm = rpm + pid:update(want - have, dt)
    if cap then rpm = util.clamp(rpm, -cap, cap) end
    return rpm
end

-- == BRAKING =================================================

-- Full reverse on all five can tip the hull nose over, so how much of the ship
-- brakes depends on how much braking is actually needed. The main propeller is
-- tried first and the turbines are recruited only when the main cannot supply
-- what the distance demands.
--
-- Returns the plan and, always, the reason for it. Two different reasons get two
-- different strings, because "braking" on a screen tells a pilot nothing.
function flight.brakePlan(v, d, pitch, cal, cfg)
    local aMax = flight.maxDecel(cal, cfg)
    local vLimit = flight.speedLimitForDistance(d, aMax, cfg.brakeMargin)

    if v <= vLimit then
        return { main = 0, turbines = 0 }, "inside the stopping distance"
    end

    if pitch and math.abs(pitch) > cfg.pitchLimit then
        -- Already past the tip limit. More reverse is what put it there.
        return { main = 0, turbines = 0 },
            string.format("pitch %.0f deg, past the %g limit", pitch, cfg.pitchLimit)
    end

    local aReq = d > 0 and (v * v) / (2 * d) or math.huge
    if aMax and aReq > aMax then aReq = aMax end

    local mainMax = flight.maxDecel(cal, cfg, "main")
    local mainLadder = cal.brakeCurve and cal.brakeCurve.main
    local allLadder = cal.brakeCurve and cal.brakeCurve.all

    if mainMax and aReq <= mainMax then
        local rpm = util.curveRpmFor(mainLadder, aReq) or cfg.brakeRpmMax
        return { main = -util.clamp(rpm, 0, cfg.brakeRpmMax), turbines = 0 },
            string.format("main alone, %.1f m/s/s", aReq)
    end

    local rpm = util.curveRpmFor(allLadder, aReq) or cfg.brakeRpmMax
    rpm = util.clamp(rpm, 0, cfg.brakeRpmMax)
    return { main = -rpm, turbines = -rpm },
        string.format("all five, %.1f m/s/s", aReq)
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

-- How fast a line may change. Suddenness is what tips the hull and what spikes
-- the stress, and neither shows up in a steady state test.
function flight.applySlew(previous, wanted, slew)
    local out = {}
    for name, want in pairs(wanted) do
        local was = previous[name] or 0
        local step = want - was
        if step > slew then step = slew elseif step < -slew then step = -slew end
        out[name] = util.round(was + step)
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
        local vLimit = flight.speedLimitForDistance(
            state.d, flight.maxDecel(cal, cfg), cfg.brakeMargin)
        if state.v > vLimit then
            return "brake", string.format("%.1f m/s with %.0f blk left", state.v, state.d)
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
