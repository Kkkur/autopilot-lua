-- control.lua -- the flight loop.
--
-- Two nested loops per body axis. The outer one turns "we are 140 blocks short"
-- into "fly at 12 m/s". The inner one turns "fly at 12 m/s" into RPM, and that
-- is where velocity calibration earns its keep: the curve says what 12 m/s
-- costs on this ship, so the loop starts from the right answer and only has to
-- trim it, instead of hunting for it from zero every flight.
--
-- With no curve it degrades to what the old autopilot did, proportional with
-- damping, which flies but overshoots. `useCurves off` forces that path if you
-- want to compare.

local util, ship, cal, config, log = ...

local control = {}

control.running = false        -- is the autopilot commanding anything
control.target = nil           -- {x, y, z} world
control.targetName = nil
control.phase = "idle"
control.status = "IDLE"
control.statusKind = "dim"
control.state = nil            -- last good ship state
control.fault = nil            -- why the last read failed, if it did
control.dist = nil
control.eta = nil
control.axisInfo = {}          -- per axis: want, have, rpm, ff, trim
control.demands = {}           -- line name -> rpm last decided
control.arrivedAt = nil        -- set once on arrival, cleared by whoever reads it
control.onArrive = nil         -- hook the navigator hangs its queue off
control.manual = nil           -- {x, y, z} body-frame speed command, or nil
control.hold = nil             -- position being station kept, when arrived

local posPID, spdPID = {}, {}
local lastTick = nil

local function makePIDs()
    for _, axis in ipairs(util.AXIS_ORDER) do
        posPID[axis] = util.newPID(config.get("posKp"), config.get("posKi"), config.get("posKd"),
            -1e6, 1e6, 50)
        spdPID[axis] = util.newPID(config.get("spdKp"), config.get("spdKi"), config.get("spdKd"),
            -config.get("maxRpm"), config.get("maxRpm"), config.get("spdILimit"))
    end
end

-- Gains can move while flying, from the TUNE tab or a `set` command, so the
-- PIDs are told rather than rebuilt. Rebuilding would drop the integral and
-- put a step in the output.
function control.refreshGains()
    for _, axis in ipairs(util.AXIS_ORDER) do
        if posPID[axis] then
            posPID[axis]:setGains(config.get("posKp"), config.get("posKi"), config.get("posKd"))
            spdPID[axis]:setGains(config.get("spdKp"), config.get("spdKi"), config.get("spdKd"))
            spdPID[axis]:setLimits(-config.get("maxRpm"), config.get("maxRpm"), config.get("spdILimit"))
        end
    end
end

function control.init()
    makePIDs()
    for _, name in ipairs(ship.order) do control.demands[name] = 0 end
    return control
end

function control.resetPIDs()
    for _, axis in ipairs(util.AXIS_ORDER) do
        if posPID[axis] then posPID[axis]:reset() end
        if spdPID[axis] then spdPID[axis]:reset() end
    end
    lastTick = nil
end

-- == COMMANDS ================================================

function control.setTarget(x, y, z, name)
    control.target = { x = x, y = y, z = z }
    control.targetName = name
    control.hold = nil
    control.arrivedAt = nil
    control.resetPIDs()
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
    control.resetPIDs()
    log.infof("autopilot engaged towards %s", control.targetName or "coords")
    return true
end

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

-- Fly by hand: a body-frame speed command that goes through the same inner
-- loop, so the calibrated curves and the slew limit apply to it too.
function control.setManual(bx, by, bz)
    if bx == 0 and by == 0 and bz == 0 then
        control.manual = nil
        if not control.target then control.stop("MANUAL OFF") end
        return
    end
    control.manual = { x = bx, y = by, z = bz }
    control.target = nil
    control.targetName = nil
    control.running = true
end

-- == THE LOOP ================================================

-- Desired body-frame speed along one axis, given how far off we are on it and
-- how far the whole leg still has to run. The taper is what stops the ship
-- arriving at 20 m/s and sailing straight through the waypoint.
local function wantedSpeed(axis, err, dist, dt)
    local cap = axis == "y" and config.get("climbSpeed") or config.get("cruiseSpeed")

    -- What the axis has actually been measured doing caps it further. Asking
    -- for 30 m/s out of a line that tops out at 9 only winds up the integral.
    local top = cal.topSpeed(axis)
    if top and top > 0.2 and config.get("useCurves") then cap = math.min(cap, top) end

    local want = posPID[axis]:update(err, dt)

    -- Bleed off over the last slowRadius blocks of the leg, on distance rather
    -- than on this axis alone, so a diagonal approach slows as one machine.
    local radius = config.get("slowRadius")
    if dist and radius > 0 then
        cap = cap * util.clamp(dist / radius, 0.02, 1.0)
    end
    return util.clamp(want, -cap, cap)
end

-- Desired speed to RPM for one axis. Feed-forward off the curve, trim off the
-- PID. Returns the axis RPM plus the two halves, because seeing them split is
-- how you tell a bad curve from bad gains on the PROPS tab.
local function axisRpm(axis, want, have, dt)
    local maxRpm = config.get("maxRpm")
    local ff = 0
    if config.get("useCurves") then
        local curve = cal.curveFor(axis, want)
        local guess = util.curveRpmFor(curve, want)
        if guess then ff = guess * util.sign(want) end
    end
    local trim = spdPID[axis]:update(want - have, dt)
    local total = util.clamp(ff + trim, -maxRpm, maxRpm)
    return total, ff, trim
end

-- Spread an axis demand over the lines that serve it, then apply the floor and
-- the slew limit per line.
local function spread(demands, axis, rpm)
    local lines = cal.linesOnAxis(axis)
    if #lines == 0 then return end
    local minRpm = config.get("minRpm")
    local maxRpm = config.get("maxRpm")
    for _, line in ipairs(lines) do
        local value = rpm * line.share
        if line.reverse then value = -value end
        if math.abs(value) < minRpm then value = 0 end
        demands[line.name] = (demands[line.name] or 0) + util.clamp(value, -maxRpm, maxRpm)
    end
end

local function applySlew(demands)
    local slew = config.get("rpmSlew")
    local maxRpm = config.get("maxRpm")
    local out = {}
    for _, name in ipairs(ship.order) do
        local wanted = util.clamp(demands[name] or 0, -maxRpm, maxRpm)
        local previous = control.demands[name] or 0
        local delta = util.clamp(wanted - previous, -slew, slew)
        out[name] = util.round(previous + delta)
    end
    return out
end

local function setStatus(text, kind, phase)
    control.status = text
    control.statusKind = kind or "hi"
    if phase then control.phase = phase end
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
        -- This is what a disassembled ship looks like. Stop, do not guess.
        setStatus(why, "bad", "fault")
        control.axisInfo = {}
        if control.running then
            control.running = false
            log.warn("pose read failed, autopilot disengaged: " .. tostring(why))
        end
        for _, name in ipairs(ship.order) do control.demands[name] = 0 end
        pcall(ship.allStop)
        return
    end

    if not control.running then
        setStatus(control.target and "READY" or "NO TARGET",
            control.target and "warn" or "dim", "idle")
        control.axisInfo = {}
        local zeros = {}
        for _, name in ipairs(ship.order) do zeros[name] = 0 end
        control.demands = applySlew(zeros)
        ship.flush(control.demands)
        return
    end

    -- Where we are trying to be, in world space, and how wrong that is.
    local wantVel = nil
    local dist = nil

    if control.manual then
        wantVel = control.manual
        setStatus(string.format("MANUAL %+.0f %+.0f %+.0f",
            wantVel.x, wantVel.y, wantVel.z), "warn", "manual")
    else
        local goal = control.hold or control.target
        local p = state.position
        local dx, dy, dz = goal.x - p.x, goal.y - p.y, goal.z - p.z
        if not config.get("holdAlt") and not control.hold then dy = 0 end
        dist = util.len3(dx, dy, dz)
        control.dist = dist

        if not control.hold and dist <= config.get("arriveDist") then
            -- Arrived. Either park here and keep fighting the drift, or let go.
            local name = control.targetName
            control.arrivedAt = name or "target"
            log.infof("arrived at %s, %.1f blocks out", name or "target", dist)
            control.eta = nil
            if config.get("stationKeep") then
                control.hold = { x = goal.x, y = goal.y, z = goal.z }
                setStatus("ARRIVED, HOLDING", "good", "hold")
            else
                control.stop("ARRIVED")
                setStatus("ARRIVED", "good", "idle")
                if control.onArrive then control.onArrive(name) end
                return
            end
            if control.onArrive then control.onArrive(name) end
        elseif control.hold then
            control.eta = nil
            setStatus(string.format("HOLDING %.1f blk", dist), "good", "hold")
        else
            local top = cal.topSpeed("x") or config.get("cruiseSpeed")
            local along = state.speed
            control.eta = along > 0.4 and dist / along or nil
            if config.get("holdAlt") and math.abs(dy) > config.get("arriveDist") * 2
                    and dist > config.get("slowRadius") then
                setStatus(string.format("CLIMB %+.0f m   %.0f blk out", dy, dist), "warn", "climb")
            else
                setStatus(string.format("CRUISE %.0f blk  %.1f m/s", dist, along), "good", "cruise")
            end
            local _ = top
        end

        -- World error into the ship's own frame, which is the only frame the
        -- propellers know anything about.
        local ex, ey, ez = util.worldToBody(state.orientation, dx, dy, dz)
        local errs = { x = ex, y = ey, z = ez }
        wantVel = {}
        for _, axis in ipairs(util.AXIS_ORDER) do
            wantVel[axis] = wantedSpeed(axis, errs[axis], dist, dt)
        end
        control.axisErr = errs
    end

    local have = { x = state.bx, y = state.by, z = state.bz }
    local demands = {}
    for _, name in ipairs(ship.order) do demands[name] = 0 end

    control.axisInfo = {}
    for _, axis in ipairs(util.AXIS_ORDER) do
        local want = wantVel[axis] or 0
        if not cal.hasAxis(axis) then
            -- Nothing on the ship can push this way. Say so rather than
            -- pretending the demand went somewhere.
            control.axisInfo[axis] = { want = want, have = have[axis], rpm = 0, blind = true }
        else
            local rpm, ff, trim = axisRpm(axis, want, have[axis], dt)
            spread(demands, axis, rpm)
            control.axisInfo[axis] = {
                want = want, have = have[axis], rpm = rpm, ff = ff, trim = trim,
            }
        end
    end

    control.demands = applySlew(demands)
    ship.flush(control.demands)
end

-- A snapshot for the screen, so the UI never reaches into the controller's
-- working state mid-tick.
function control.snapshot()
    return {
        running = control.running,
        phase = control.phase,
        status = control.status,
        statusKind = control.statusKind,
        state = control.state,
        fault = control.fault,
        target = control.target,
        targetName = control.targetName,
        hold = control.hold,
        dist = control.dist,
        eta = control.eta,
        axisInfo = control.axisInfo,
        demands = control.demands,
    }
end

return control
