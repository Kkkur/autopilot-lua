-- control.lua -- the flight loop.
--
-- A shell over sc/flight.lua. This file reads the pose, keeps the phase and the
-- timers, and writes RPM. Every decision worth arguing about is made in
-- flight.lua, where it is pure and can be tested on a computer that is not on a
-- ship.
--
-- The ship it flies turns by driving one side against the other and holds its
-- altitude on a balloon. So a leg is not one problem, it is three in order:
-- point at the target, run at it, stop. That is the phase machine, and the
-- altitude loop runs underneath all three because the balloon is the only thing
-- holding the ship up and there is no phase in which it should stop being
-- commanded.

local util, ship, cal, config, log, flight, turbine = ...

local control = {}

control.running = false        -- is the autopilot commanding anything
control.target = nil           -- {x, y, z} world
control.targetName = nil
control.phase = "idle"
control.reason = nil           -- why the phase machine last changed its mind
control.status = "IDLE"
control.statusKind = "dim"
control.state = nil            -- last good ship state
control.fault = nil            -- why the last read failed, if it did
control.dist = nil
control.eta = nil
control.demands = {}           -- line name -> rpm last decided
control.arrivedAt = nil        -- set once on arrival, cleared by whoever reads it
control.onArrive = nil         -- hook the navigator hangs its queue off
control.manual = nil           -- { throttle, yaw, level } or nil
control.hold = nil             -- position being held, once arrived

-- What the screen wants to see and the pilot wants to argue with.
control.info = {
    err = nil, bearing = nil, yawRate = nil, pitch = nil,
    want = nil, have = nil, lateral = nil,
    common = nil, differential = nil, balloon = nil,
}

-- Seconds the ship has been inside the padding band and no longer swinging.
-- The phase machine will not commit to cruise on the strength of one tick, and
-- this is the memory that lets it insist.
local alignedFor = 0
local legBegan = 0
local creepTries = 0
local lastTrim = 0
local lastTick = nil

local yawPID, spdPID, altPID

local function makePIDs()
    yawPID = util.newPID(config.get("yawKp"), config.get("yawKi"), config.get("yawKd"),
        -1e6, 1e6, 50)
    spdPID = util.newPID(config.get("spdKp"), config.get("spdKi"), config.get("spdKd"),
        -config.get("cruiseMaxRpm"), config.get("cruiseMaxRpm"), config.get("spdILimit"))
    altPID = util.newPID(config.get("altKp"), config.get("altKi"), config.get("altKd"),
        -1e6, 1e6, 50)
end

-- Gains can move while flying, from the TUNE tab or a `set` command, so the
-- PIDs are told rather than rebuilt. Rebuilding would drop the integral and put
-- a step in the output.
function control.refreshGains()
    if not yawPID then return end
    yawPID:setGains(config.get("yawKp"), config.get("yawKi"), config.get("yawKd"))
    spdPID:setGains(config.get("spdKp"), config.get("spdKi"), config.get("spdKd"))
    spdPID:setLimits(-config.get("cruiseMaxRpm"), config.get("cruiseMaxRpm"),
        config.get("spdILimit"))
    altPID:setGains(config.get("altKp"), config.get("altKi"), config.get("altKd"))
end

function control.init()
    makePIDs()
    for _, name in ipairs(ship.order) do control.demands[name] = 0 end
    return control
end

function control.resetPIDs()
    if yawPID then yawPID:reset(); spdPID:reset(); altPID:reset() end
    alignedFor = 0
    lastTick = nil
end

-- == COMMANDS ================================================

local function enterPhase(phase, why)
    if control.phase ~= phase then
        control.phase = phase
        alignedFor = 0
        log.infof("phase %s: %s", phase, tostring(why))
    end
    control.reason = why
end

function control.setTarget(x, y, z, name)
    control.target = { x = x, y = y, z = z }
    control.targetName = name
    control.hold = nil
    control.arrivedAt = nil
    creepTries = 0
    legBegan = os.clock()
    control.resetPIDs()
    enterPhase("tank", "new target")
    log.infof("target set: %s (%.1f, %.1f, %.1f)", name or "coords", x, y, z)
end

function control.clearTarget()
    control.target = nil
    control.targetName = nil
    control.hold = nil
end

function control.start()
    if not control.target and not control.manual then return false, "no target" end
    control.running = true
    legBegan = os.clock()
    creepTries = 0
    control.resetPIDs()
    enterPhase("tank", "engaged")
    log.infof("autopilot engaged towards %s", control.targetName or "coords")
    return true
end

-- Thrust stops. The balloon does not, and the difference is the whole reason
-- this is two sentences rather than one loop over everything.
function control.stop(why)
    control.running = false
    control.manual = nil
    control.hold = nil
    control.phase = "idle"
    control.status = why or "STOPPED"
    control.statusKind = "dim"
    control.resetPIDs()
    for _, name in ipairs(ship.order) do control.demands[name] = 0 end
    pcall(ship.allStop)
    log.info("stopped: " .. (why or "by command"))
end

-- Fly by hand. Throttle and yaw are fractions of the ship's own maxima, so what
-- the pilot asks for means the same thing on a ship whose curves have been
-- measured and on one whose have not. Level is the balloon, straight through.
function control.setManual(throttle, yaw, level)
    if throttle == 0 and yaw == 0 and level == nil then
        control.manual = nil
        if not control.target then control.stop("MANUAL OFF") end
        return
    end
    control.manual = { throttle = throttle or 0, yaw = yaw or 0, level = level }
    control.target = nil
    control.targetName = nil
    control.running = true
    enterPhase("manual", "by hand")
end

-- == READING THE SHIP ========================================

-- Speed along the hull rather than speed through the air. A ship that has just
-- turned is still carrying the velocity of where it used to be pointing, and
-- braking against that number would brake against a crosswind.
local function forwardSpeed(state)
    return state.bz or 0
end

-- == THE BALLOON =============================================
--
-- Runs in every phase, including none of them. There is no state of this
-- program in which the thing holding the ship up should stop being told what to
-- do, which is why this is not inside the phase machine below.
local function driveBalloon(state, wantY)
    if not turbine or not turbine.setBalloon then return nil end
    local haveY = state.position.y
    local altErr = (wantY or haveY) - haveY
    local vspeed = state.velocity and state.velocity.y or 0
    local level = flight.balloonLevel(altErr, vspeed, cal, config.values)
    control.info.balloon = level
    control.info.altErr = altErr
    if level ~= control.lastBalloon then
        control.lastBalloon = level
        pcall(turbine.setBalloon, level)
    end
    return level
end

-- == THE LOOP ================================================

local function setStatus(text, kind)
    control.status = text
    control.statusKind = kind or "hi"
end

-- One tick of a leg: where the phase machine is, and what the propellers are
-- told because of it. Returns the main's thrust, the turbines' thrust and the
-- differential, all signed RPM, for the mixer. The main and the turbines are
-- separate because braking is graduated: a stop on the main alone has to reach
-- the propellers as the main alone.
local function flyLeg(state, goal, dt)
    local cfg = config.values
    local p = state.position

    local bearing = flight.bearingTo(p.x, p.z, goal.x, goal.z)
    local err = flight.headingError(bearing, state.yaw, cal.noseOffset)
    local yawRate = ship.yawRate() or 0
    local pitch = util.pitchOf(state.orientation)
    local dx, dz = goal.x - p.x, goal.z - p.z
    local d = math.sqrt(dx * dx + dz * dz)
    local v = forwardSpeed(state)
    local lateral = flight.lateralError(p, goal, state.yaw)

    control.dist = d
    control.info.bearing = bearing
    control.info.err = err
    control.info.yawRate = yawRate
    control.info.pitch = pitch
    control.info.have = v
    control.info.lateral = lateral

    -- The memory the phase machine insists on: not just lined up, but lined up
    -- and no longer swinging, for long enough to believe.
    if math.abs(err) <= cfg.tankPadding and math.abs(yawRate) <= cfg.tankHoldRate then
        alignedFor = alignedFor + dt
    else
        alignedFor = 0
    end

    local stopped = math.abs(v) < 0.3 and math.abs(state.speed or 0) < 0.5
    local nextPhase, why = flight.phaseNext(control.phase, {
        err = err, yawRate = yawRate, d = d, v = v,
        lateral = lateral, alignedFor = alignedFor, stopped = stopped,
    }, cfg, cal)

    if nextPhase ~= control.phase then
        if nextPhase == "tank" and control.phase == "brake" then
            -- Turning around for a second run at the point. It is allowed a few
            -- of these and then it says so rather than pirouetting forever.
            creepTries = creepTries + 1
        end
        if nextPhase == "cruise" then legBegan = os.clock() end
        enterPhase(nextPhase, why)
    else
        control.reason = why
    end

    if control.phase == "arrived" then
        return 0, 0, 0, d
    end

    -- Two different ways to fail to arrive, and they get two different strings.
    -- Being off to the side is a hull that cannot strafe; being short or past is
    -- a stop that did not land where it was aimed, and the fix for one is not the
    -- fix for the other.
    if creepTries > cfg.creepTries then
        if math.abs(lateral) > cfg.lateralCorrect then
            setStatus(string.format("GAVE UP, %.1f blk OFF THE LINE", math.abs(lateral)), "bad")
        else
            setStatus(string.format("GAVE UP, STOPPED %.1f blk OUT", d), "bad")
        end
        return 0, 0, 0, d
    end

    -- Tank: rotate, do not translate.
    if control.phase == "tank" then
        local demand = flight.tankDemand(err, yawPID, cal, cfg, dt)
        control.info.want = 0
        control.info.common = 0
        control.info.differential = demand.diff
        setStatus(string.format("TURN %+.0f deg  %.0f blk", err, d), "warn")
        return 0, 0, demand.diff, d
    end

    -- Cruise: run at it, trimming the heading rather than turning.
    if control.phase == "cruise" then
        local elapsed = os.clock() - legBegan
        -- Creeping is the same run at a speed the pilot would call walking, so
        -- it shares this whole path rather than being a fourth phase.
        local want = creepTries > 0 and cfg.creepSpeed
            or flight.wantSpeed(d, elapsed, cfg, cal)
        local common = flight.thrustRpm(want, v, cal.fwdCurve, spdPID, dt, cfg.cruiseMaxRpm)
        if math.abs(common) < cfg.cruiseMinRpm then common = 0 end

        -- The trim is on its own clock. Nudging the heading every tick fights
        -- the hull's own swing and costs stress for nothing.
        local now = os.clock()
        if now - lastTrim >= cfg.yawTrimInterval then
            lastTrim = now
            control.trim = flight.yawTrim(err, cfg)
        end

        control.info.want = want
        control.info.common = common
        control.info.differential = control.trim or 0
        setStatus(string.format("RUN %.0f blk  %.1f m/s", d, v), "good")
        return common, common, control.trim or 0, d
    end

    -- Brake: reverse, graduated, heading still trimmed.
    if control.phase == "brake" then
        local plan, reason = flight.brakePlan(v, d, pitch, cal, cfg)
        control.reason = reason
        control.info.want = 0
        control.info.common = plan.main
        control.info.differential = control.trim or 0
        control.brakePlan = plan
        setStatus(string.format("STOP %.0f blk  %.1f m/s", d, v), "warn")
        -- The turbines hold back whatever the heading trim is asking for, so the
        -- ship never loses its nose in the middle of a stop.
        return plan.main, plan.turbines,
            plan.turbines ~= 0 and (control.trim or 0) or 0, d
    end

    return 0, 0, 0, d
end

function control.tick()
    local now = os.clock()
    local dt = lastTick and (now - lastTick) or config.get("tick")
    lastTick = now
    if dt <= 0 then dt = 0.001 end

    local state, why = ship.readState()
    control.state = state or control.state
    control.fault = state and nil or why

    if not state then
        -- This is what a disassembled ship looks like. Stop, do not guess. The
        -- balloon is left where it is: with no pose there is no telling whether
        -- changing it would help, and the last level was at least flying.
        setStatus(why, "bad")
        control.phase = "fault"
        if control.running then
            control.running = false
            log.warn("pose read failed, autopilot disengaged: " .. tostring(why))
        end
        for _, name in ipairs(ship.order) do control.demands[name] = 0 end
        pcall(ship.allStop)
        return
    end

    local cfg = config.values
    local goal = control.hold or control.target

    -- Altitude first, and unconditionally, because it is the only loop whose
    -- failure is measured in metres per second downwards.
    driveBalloon(state, goal and goal.y or nil)

    if not control.running then
        setStatus(control.target and "READY" or "NO TARGET",
            control.target and "warn" or "dim")
        control.phase = "idle"
        local zeros = {}
        for _, name in ipairs(ship.order) do zeros[name] = 0 end
        control.demands = flight.applySlew(control.demands, zeros, cfg.rpmSlew)
        ship.flush(control.demands)
        return
    end

    local mainCommon, turbineCommon, differential = 0, 0, 0

    if control.manual then
        mainCommon = control.manual.throttle * cfg.cruiseMaxRpm
        turbineCommon = mainCommon
        differential = control.manual.yaw * cfg.tankRpmMax
        control.info.common = mainCommon
        control.info.differential = differential
        setStatus(string.format("MANUAL thr %+.0f%%  yaw %+.0f%%",
            control.manual.throttle * 100, control.manual.yaw * 100), "warn")
    elseif goal then
        local d
        mainCommon, turbineCommon, differential, d = flyLeg(state, goal, dt)

        if control.phase == "arrived" and not control.hold then
            local name = control.targetName
            control.arrivedAt = name or "target"
            control.eta = nil
            log.infof("arrived at %s, %.1f blocks out", name or "target", d or 0)
            control.hold = { x = goal.x, y = goal.y, z = goal.z }
            setStatus(string.format("ARRIVED, HOLDING %.1f blk", d or 0), "good")
            if control.onArrive then control.onArrive(name) end
        elseif control.phase == "arrived" then
            setStatus(string.format("HOLDING %.1f blk", d or 0), "good")
            -- Holding is the same behaviour as a leg, continuously. Drift past
            -- holdDrift is a new leg onto the same point.
            if d and d > cfg.holdDrift then
                creepTries = 0
                enterPhase("tank", string.format("drifted %.1f blk", d))
            end
        end

        local v = forwardSpeed(state)
        control.eta = (v > 0.4 and d) and d / v or nil
    else
        setStatus("NO TARGET", "dim")
    end

    -- Braking has its own slew, because how fast reverse comes on is what tips
    -- the hull, and it is not the same number as the one that softens a launch.
    local slew = control.phase == "brake" and cfg.brakeSlew or cfg.rpmSlew

    local wanted = flight.mixParts(mainCommon, turbineCommon, differential,
        ship.order, cal, cfg)
    control.demands = flight.applySlew(control.demands, wanted, slew)
    ship.flush(control.demands)
end

-- A snapshot for the screen, so the UI never reaches into the controller's
-- working state mid-tick.
function control.snapshot()
    return {
        running = control.running,
        phase = control.phase,
        reason = control.reason,
        status = control.status,
        statusKind = control.statusKind,
        state = control.state,
        fault = control.fault,
        target = control.target,
        targetName = control.targetName,
        hold = control.hold,
        dist = control.dist,
        eta = control.eta,
        info = control.info,
        demands = control.demands,
    }
end

return control
