-- cal.lua -- the two calibrations, and the file they share.
--
-- DIRECTION calibration answers "which way does this propeller push, and does
-- positive RPM get it there". That is the one the old autopilot had, kept
-- almost move for move because it worked: spin one line, watch the drift, let
-- the pilot's eyes overrule the number.
--
-- VELOCITY calibration answers the question the old one never asked: "how fast
-- does this ship actually go". It walks each body axis through a ladder of RPM
-- steps, waits at every rung until the speed stops changing, and writes down
-- what it settled at. That table turns the controller from "push harder when
-- far away" into "fly at 8 m/s", because it can look up what 8 m/s costs.
--
-- Both write to the same file, and either can be re-run without losing the
-- other.

local util, ship, config, log = ...

local cal = {}

cal.FILE = nil
cal.axes = {}     -- line name -> {x, y, z, reverse = bool}
cal.curves = {}   -- "x"|"y"|"z" -> { pos = {{rpm,speed},...}, neg = {...} }
cal.meta = {}     -- when each half was last run, for the screen

-- == WHAT THE TANK TURN HULL MEASURES ========================
--
-- The fields sc/flight.lua reads. The five stage wizard that fills them is
-- stage 5; this is the file they live in and the shape they are written down
-- in. flight.lua carries the full description at the top, because it is the
-- file that has to understand them.
--
-- Every one of them is allowed to be missing. A ship that has not been
-- calibrated still flies, badly, on the fallbacks in flight.lua, and an
-- uncalibrated ship saying so beats an uncalibrated ship pretending.

cal.sides = {}        -- line name -> { side, reverse }
cal.noseOffset = nil
cal.yawAuth = {}      -- { left, right }, deg/s per RPM
cal.yawCurve = nil    -- { pos, neg }, differential RPM against yaw rate
cal.fwdCurve = nil    -- { pos, neg }, common RPM against settled speed
cal.brakeCurve = nil  -- { main, all }, reverse RPM against deceleration
cal.balloonCurve = nil
cal.altHover = nil
cal.stressAtTurn = nil
cal.stressAtCruise = nil
cal.inventory = nil   -- what the ship looked like when it was last measured

-- == PERSISTENCE =============================================

function cal.init(dataDir)
    cal.FILE = fs.combine(dataDir, "cal.cfg")
    cal.load()
    return cal
end

-- Only the lines actually on the network right now are loaded back. Anything
-- on the network with no usable entry is returned as missing, so the caller
-- can say what still needs a run.
function cal.parseAxes(data, names)
    local axes, missing = {}, {}
    for _, name in ipairs(names) do
        local v = type(data) == "table" and data[name] or nil
        if type(v) == "table" and type(v[1]) == "number"
                and type(v[2]) == "number" and type(v[3]) == "number" then
            axes[name] = { v[1], v[2], v[3], reverse = v.reverse == true }
        else
            missing[#missing + 1] = name
        end
    end
    return axes, missing
end

function cal.parseCurves(data)
    local curves = {}
    if type(data) ~= "table" then return curves end
    for _, axis in ipairs(util.AXIS_ORDER) do
        local entry = data[axis]
        if type(entry) == "table" then
            local out = {}
            for _, way in ipairs({ "pos", "neg" }) do
                local samples = util.tidyCurve(entry[way])
                if #samples > 0 then out[way] = samples end
            end
            if out.pos or out.neg then curves[axis] = out end
        end
    end
    return curves
end

-- Which side each line pushes from, keyed by the saved name.
--
-- Deliberately not filtered against what is on the network. At boot every line
-- on this ship is on a relay and none of them have adopted yet, so filtering
-- here threw away the whole calibration a second before the propellers arrived,
-- and nothing ever loaded it again. A line in the file that never turns up is
-- harmless: the mixer only ever iterates lines the ship actually has.
function cal.parseSides(data)
    local sides = {}
    if type(data) ~= "table" then return sides end
    local allowed = { left = true, right = true, main = true, none = true }
    for name, entry in pairs(data) do
        if type(name) == "string" and type(entry) == "table"
                and allowed[entry.side] then
            sides[name] = { side = entry.side, reverse = entry.reverse == true }
        end
    end
    return sides
end

-- A pair of ladders, the shape util's curve family reads.
local function parsePair(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, way in ipairs({ "pos", "neg" }) do
        local samples = util.tidyCurve(data[way])
        if #samples > 0 then out[way] = samples end
    end
    if not out.pos and not out.neg then return nil end
    return out
end

-- The brake ladders carry a pitch per rung, which util.tidyCurve neither knows
-- nor keeps, so they are tidied here instead.
local function parseBrake(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, which in ipairs({ "main", "all" }) do
        local rungs = {}
        for _, rung in ipairs(type(data[which]) == "table" and data[which] or {}) do
            if type(rung) == "table" and type(rung.rpm) == "number"
                    and type(rung.speed) == "number" then
                rungs[#rungs + 1] = {
                    rpm = math.abs(rung.rpm),
                    speed = math.abs(rung.speed),
                    pitch = type(rung.pitch) == "number" and rung.pitch or nil,
                }
            end
        end
        table.sort(rungs, function(a, b) return a.rpm < b.rpm end)
        if #rungs > 0 then out[which] = rungs end
    end
    if not out.main and not out.all then return nil end
    return out
end

function cal.load()
    cal.axes, cal.curves, cal.meta = {}, {}, {}
    cal.sides, cal.yawAuth = {}, {}
    cal.noseOffset, cal.yawCurve, cal.fwdCurve, cal.brakeCurve = nil, nil, nil, nil
    cal.balloonCurve, cal.altHover, cal.inventory = nil, nil, nil
    cal.stressAtTurn, cal.stressAtCruise = nil, nil

    if not cal.FILE or not fs.exists(cal.FILE) then return false end
    local handle = fs.open(cal.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end
    -- The very first builds wrote the axis table at the top level with no
    -- wrapper. Read that shape too rather than making anyone recalibrate.
    local axisData = type(data.axes) == "table" and data.axes or data
    cal.axes = cal.parseAxes(axisData, ship.order)
    cal.curves = cal.parseCurves(data.curves)
    cal.meta = type(data.meta) == "table" and data.meta or {}

    cal.sides = cal.parseSides(data.sides)
    cal.noseOffset = tonumber(data.noseOffset)
    if type(data.yawAuth) == "table" then
        cal.yawAuth = { left = tonumber(data.yawAuth.left),
                        right = tonumber(data.yawAuth.right) }
    end
    cal.yawCurve = parsePair(data.yawCurve)
    cal.fwdCurve = parsePair(data.fwdCurve)
    cal.brakeCurve = parseBrake(data.brakeCurve)
    -- util.tidyCurve takes magnitudes, which folds the sinking half of this one
    -- onto the climbing half, so the balloon ladder is read straight instead.
    if type(data.balloonCurve) == "table" then
        local rungs = {}
        for _, rung in ipairs(data.balloonCurve) do
            if type(rung) == "table" and type(rung.rpm) == "number"
                    and type(rung.speed) == "number" then
                rungs[#rungs + 1] = { rpm = rung.rpm, speed = rung.speed }
            end
        end
        table.sort(rungs, function(a, b) return a.rpm < b.rpm end)
        if #rungs > 0 then cal.balloonCurve = rungs end
    end
    cal.altHover = tonumber(data.altHover)
    cal.stressAtTurn = tonumber(data.stressAtTurn)
    cal.stressAtCruise = tonumber(data.stressAtCruise)
    cal.inventory = type(data.inventory) == "table" and data.inventory or nil
    return true
end

function cal.save()
    if not cal.FILE then return false end
    local dir = fs.getDir(cal.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle, reason = fs.open(cal.FILE, "w")
    if not handle then
        log.errorf("could not write %s: %s", cal.FILE, tostring(reason))
        return false
    end
    handle.write(textutils.serialize({
        axes = cal.axes, curves = cal.curves, meta = cal.meta,
        sides = cal.sides, noseOffset = cal.noseOffset, yawAuth = cal.yawAuth,
        yawCurve = cal.yawCurve, fwdCurve = cal.fwdCurve,
        brakeCurve = cal.brakeCurve, balloonCurve = cal.balloonCurve,
        altHover = cal.altHover, inventory = cal.inventory,
        stressAtTurn = cal.stressAtTurn, stressAtCruise = cal.stressAtCruise,
    }))
    handle.close()
    return true
end

-- == QUERIES THE REST OF THE PROGRAM ASKS ====================

function cal.missingLines()
    local _, missing = cal.parseAxes(cal.axes, ship.order)
    return missing
end

function cal.axisOf(name)
    return cal.axes[name]
end

-- The lines that can push along a body axis, with how much of their thrust
-- lands on it. A line mounted on the axis gives +-1; DIRECTIONS only produces
-- those two, but the dot product is kept general so a hand-edited diagonal
-- entry in the file still flies.
function cal.linesOnAxis(axis)
    local index = util.AXIS_INDEX[axis]
    local out = {}
    for _, name in ipairs(ship.order) do
        local a = cal.axes[name]
        if a then
            local share = a[index]
            if math.abs(share) > 1e-6 then
                out[#out + 1] = { name = name, share = share, reverse = a.reverse }
            end
        end
    end
    return out
end

function cal.hasAxis(axis)
    return #cal.linesOnAxis(axis) > 0
end

function cal.curveFor(axis, signedSpeed)
    local entry = cal.curves[axis]
    if not entry then return nil end
    if signedSpeed < 0 then return entry.neg or entry.pos end
    return entry.pos or entry.neg
end

-- Top speed this ship has been measured doing along an axis, either way.
function cal.topSpeed(axis)
    local entry = cal.curves[axis]
    if not entry then return nil end
    local best = nil
    for _, way in ipairs({ "pos", "neg" }) do
        local top = util.curveTopSpeed(entry[way])
        if top and (not best or top > best) then best = top end
    end
    return best
end

-- The demand table that drives one axis at `rpm` towards its positive
-- direction. Shared by velocity calibration and by the manual nudge keys.
function cal.axisDemand(axis, rpm)
    local demands = {}
    for _, name in ipairs(ship.order) do demands[name] = 0 end
    for _, line in ipairs(cal.linesOnAxis(axis)) do
        local value = rpm * line.share
        if line.reverse then value = -value end
        demands[line.name] = util.round(util.clamp(value, -config.get("maxRpm"), config.get("maxRpm")))
    end
    return demands
end

-- == DIRECTION CALIBRATION ===================================
--
-- ctx is the screen. It is handed in rather than reached for, so this file
-- never touches term directly and the whole flow can be driven by a test
-- harness or, later, by a remote console.
--
--   ctx.panel(t)              draw the wizard body from a table of fields
--   ctx.ask(question, opts)   a line of text back, with a default
--   ctx.yesno(question, def)  true or false
--   ctx.waitEnter()           blocks until Enter, used as the stop key
--   ctx.aborted()             true once the pilot pressed Q
--   ctx.note(text, kind)      one scrolling line in the wizard log

-- Spin one line and keep spinning it until Enter, live drift on screen the
-- whole time. The reading kept is the largest one seen, not whatever happened
-- to be on screen at the moment of the keypress.
local function spinAndWatch(ctx, name, base, sign)
    local bestX, bestY, bestZ, bestMag = 0, 0, 0, 0
    local started = os.clock()

    local function watch()
        while true do
            local now = ship.bodyVelocity()
            if now and base then
                local dx, dy, dz = now.x - base.x, now.y - base.y, now.z - base.z
                local mag = util.len3(dx, dy, dz)
                if mag > bestMag then bestX, bestY, bestZ, bestMag = dx, dy, dz, mag end
                ctx.panel({
                    prompt = false,
                    drift = { dx, dy, dz },
                    guess = util.dominantDirection(dx, dy, dz, config.get("calMinDrift")),
                    best = { bestX, bestY, bestZ },
                    elapsed = os.clock() - started,
                    spinning = true,
                })
            else
                ctx.panel({ noPose = true, prompt = false,
                    elapsed = os.clock() - started, spinning = true })
            end
            sleep(config.get("calSample"))
        end
    end

    ship.driveOnly(name, config.get("calRpm") * sign)
    -- Enter only. A letter key would leave its char event queued for the read
    -- that comes next and type itself into the answer.
    parallel.waitForAny(watch, ctx.waitEnter)
    ship.allStop()
    return bestX, bestY, bestZ, bestMag
end

function cal.runDirection(ctx)
    local names = ship.order
    if #names == 0 then
        ctx.note("no propeller lines on the network", "bad")
        return false
    end

    ctx.note(string.format("%d lines. One at a time. Give it clear air.", #names))
    local done, skipped = 0, 0

    for index, name in ipairs(names) do
        if ctx.aborted() then break end

        ctx.panel({
            step = index, total = #names, line = name,
            current = util.labelFor(cal.axes[name]),
            reversed = cal.axes[name] and cal.axes[name].reverse,
            prompt = "[Enter] spin it   s skip   q finish",
        })

        local choice = ctx.ask("", { default = "", hint = "Enter to spin, s, or q" }):lower()
        if choice == "q" then break end

        if choice == "s" then
            skipped = skipped + 1
            ctx.note(util.shortName(name) .. " skipped")
        else
            local sign = 1
            local base = ship.bodyVelocity()
            local dx, dy, dz, mag = spinAndWatch(ctx, name, base, sign)

            -- Which way is forward is a property of the propeller, not of where
            -- it sits, so it gets asked before anything is read off the drift.
            if not ctx.yesno("Is it spinning the right way?", true) then
                sign = -1
                ctx.note("reversed, watch it again", "warn")
                dx, dy, dz, mag = spinAndWatch(ctx, name, ship.bodyVelocity(), sign)
            end

            local guess = mag > 0 and util.dominantDirection(dx, dy, dz, config.get("calMinDrift")) or "none"
            ctx.panel({
                step = index, total = #names, line = name,
                best = { dx, dy, dz }, guess = guess,
                prompt = "Which way did it push the ship?",
            })
            local answer = ctx.ask("Which way did it push the ship?", {
                default = guess,
                choices = util.DIR_ORDER,
                extra = { "skip" },
            })
            answer = (answer or ""):lower()
            if answer == "" then answer = guess end
            if answer == "skip" then
                skipped = skipped + 1
                ctx.note(util.shortName(name) .. " left as it was")
            elseif util.DIRECTIONS[answer] then
                cal.axes[name] = util.makeAxis(answer, sign < 0)
                done = done + 1
                ctx.note(string.format("%s -> %s%s", util.shortName(name), answer,
                    sign < 0 and " (reversed)" or ""), "good")
                log.infof("cal: %s = %s reverse=%s", name, answer, tostring(sign < 0))
            else
                ctx.note("not a direction, left as it was", "bad")
            end
        end
    end

    ship.allStop()
    cal.meta.directionAt = os.day() .. "d " .. log.timestamp()
    cal.save()
    ctx.note(string.format("direction calibration saved: %d set, %d skipped", done, skipped), "good")
    return true
end

-- == VELOCITY CALIBRATION ====================================
--
-- One axis at a time, one RPM rung at a time. The ship is pushed until its
-- speed stops changing, and the speed it stopped changing at is the sample.
-- Everything about the ladder is in config: how many rungs, how long a rung
-- may take, how still counts as still.

local function rpmLadder()
    local steps = config.get("velSteps")
    local first = config.get("velStartRpm")
    local last = config.get("velEndRpm")
    if last < first then first, last = last, first end
    local out = {}
    if steps == 1 then return { last } end
    for i = 0, steps - 1 do
        out[#out + 1] = util.round(first + (last - first) * i / (steps - 1))
    end
    return out
end

cal.rpmLadder = rpmLadder

-- Drive one rung and wait for the speed to settle. Returns the settled speed,
-- or nil plus a reason. The speed watched is the body-frame component along
-- the axis being driven, signed the way we are pushing, so a ship that gets
-- shoved sideways by its own wash does not poison the sample.
local function measureStep(ctx, axis, rpm, sign, onLive)
    local index = util.AXIS_INDEX[axis]
    local settle = config.get("velSettle")
    local hold = config.get("velHold")
    local stable = config.get("velStable")

    local demands = cal.axisDemand(axis, rpm * sign)
    ship.flush(demands)

    local started = os.clock()
    local history = {}
    local holdFrom = nil
    local best = 0
    local result, reason = nil, nil

    local function sampler()
        while true do
            local v = ship.bodyVelocity()
            local now = os.clock()
            if not v then
                reason = "lost the pose"
                return
            end
            local along = ({ v.x, v.y, v.z })[index] * sign
            if along > best then best = along end

            history[#history + 1] = { t = now, v = along }
            while #history > 2 and now - history[1].t > 1.5 do table.remove(history, 1) end

            -- Slope over the last second and a bit. A ship that is still
            -- accelerating has not told us its top speed yet.
            local slope = 0
            if #history >= 2 then
                local a, b = history[1], history[#history]
                local dt = b.t - a.t
                if dt > 0.2 then slope = (b.v - a.v) / dt end
            end

            local steady = math.abs(slope) <= stable and along > 0
            if steady then
                holdFrom = holdFrom or now
            else
                holdFrom = nil
            end
            local held = holdFrom and (now - holdFrom) or 0

            onLive({
                axis = axis, rpm = rpm, sign = sign,
                speed = along, slope = slope,
                held = held, holdNeeded = hold,
                elapsed = now - started, settle = settle,
                phase = steady and "settling" or "accelerating",
            })

            if held >= hold then
                result = along
                return
            end
            if now - started > settle then
                -- Out of patience. The best speed seen is still a real number
                -- and better than no sample at all, it is just noisier.
                result = best
                reason = "timeout"
                return
            end
            sleep(0.2)
        end
    end

    parallel.waitForAny(sampler, ctx.waitAbort)
    ship.allStop()
    if ctx.aborted() then return nil, "aborted" end
    return result, reason
end

-- Between rungs the ship has to shed what it built up, or the next rung starts
-- from the wrong speed and reads high.
local function cooldown(ctx, onLive, axis, sign)
    local secs = config.get("velCooldown")
    if secs <= 0 then return end
    local index = util.AXIS_INDEX[axis]
    local started = os.clock()
    local function wait()
        while os.clock() - started < secs do
            local v = ship.bodyVelocity()
            local along = v and ({ v.x, v.y, v.z })[index] * sign or 0
            onLive({
                axis = axis, sign = sign, rpm = 0, speed = along,
                phase = "cooldown", elapsed = os.clock() - started, settle = secs,
                held = os.clock() - started, holdNeeded = secs,
            })
            sleep(0.2)
        end
    end
    parallel.waitForAny(wait, ctx.waitAbort)
    ship.allStop()
end

function cal.runVelocity(ctx, onlyAxis)
    local ladder = rpmLadder()
    local axes = {}
    for _, axis in ipairs(util.AXIS_ORDER) do
        if (not onlyAxis or onlyAxis == axis) and cal.hasAxis(axis) then
            axes[#axes + 1] = axis
        end
    end

    if #axes == 0 then
        ctx.note("no calibrated lines to measure. Run direction calibration first.", "bad")
        return false
    end

    local ways = config.get("velBothWays") and { 1, -1 } or { 1 }
    local totalSteps = #axes * #ways * #ladder
    local stepNo = 0

    ctx.note(string.format("velocity run: %d axes, %d rungs each, %d measurements",
        #axes, #ladder, totalSteps), "warn")
    ctx.note("the ship will fly itself hard in every direction. Clear air, all sides.", "warn")

    for _, axis in ipairs(axes) do
        cal.curves[axis] = cal.curves[axis] or {}
        for _, sign in ipairs(ways) do
            local way = sign > 0 and "pos" or "neg"
            local samples = {}

            for _, rpm in ipairs(ladder) do
                if ctx.aborted() then break end
                stepNo = stepNo + 1

                local function onLive(live)
                    live.stepNo = stepNo
                    live.totalSteps = totalSteps
                    live.way = way
                    live.samples = samples
                    ctx.panel(live)
                end

                local speed, reason = measureStep(ctx, axis, rpm, sign, onLive)
                if ctx.aborted() then break end

                if speed and speed > 0 then
                    samples[#samples + 1] = { rpm = rpm, speed = speed }
                    ctx.note(string.format("%s%s %3d rpm -> %.2f m/s%s", axis, way == "pos" and "+" or "-",
                        rpm, speed, reason == "timeout" and " (did not settle)" or ""),
                        reason == "timeout" and "warn" or "good")
                    log.infof("vcal: axis=%s way=%s rpm=%d speed=%.3f %s",
                        axis, way, rpm, speed, reason or "settled")
                else
                    ctx.note(string.format("%s%s %3d rpm -> no reading (%s)", axis,
                        way == "pos" and "+" or "-", rpm, tostring(reason)), "bad")
                    log.warnf("vcal: axis=%s way=%s rpm=%d no reading (%s)",
                        axis, way, rpm, tostring(reason))
                end

                -- Saved after every rung. A run that gets interrupted halfway
                -- still leaves a usable, if short, curve behind.
                cal.curves[axis][way] = util.tidyCurve(samples)
                cal.save()

                if not ctx.aborted() then cooldown(ctx, onLive, axis, sign) end
            end
            if ctx.aborted() then break end
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    cal.meta.velocityAt = os.day() .. "d " .. log.timestamp()
    cal.save()
    if ctx.aborted() then
        ctx.note("velocity calibration stopped early, what was measured is saved", "warn")
    else
        ctx.note("velocity calibration saved", "good")
    end
    return true
end

-- A one-line summary per axis for the CAL tab.
function cal.summary()
    local out = {}
    for _, axis in ipairs(util.AXIS_ORDER) do
        local lines = cal.linesOnAxis(axis)
        local entry = cal.curves[axis]
        out[#out + 1] = {
            axis = axis,
            lines = #lines,
            pos = entry and entry.pos or nil,
            neg = entry and entry.neg or nil,
            top = cal.topSpeed(axis),
        }
    end
    return out
end

return cal
