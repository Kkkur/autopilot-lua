-- cal.lua -- the five stage wizard, and the file it writes.
--
-- Calibration is how the program learns the ship. Nothing about this vessel is
-- written into the code: which propeller is on which side, how fast a
-- differential turns the hull, what a redstone strength does to the balloon and
-- how hard the thing can stop are all measured here and read back by
-- sc/flight.lua. The shape of what gets written down is described at the top of
-- that file, because that is the file that has to understand it.
--
-- Five stages, in a fixed order, each confirmed before it runs and each
-- skippable, so redoing the brake ladder does not throw away the rest. The
-- order is not a preference. The movement stages need a held altitude to
-- measure against, so the balloon is learned before anything that moves
-- horizontally, and everything needs to know which line is on which side, so
-- sides is first.
--
--   sides    which line is left, right or main, which way it spins, how much
--            yaw each side is worth, and where the nose actually points
--   balloon  redstone strength against climb rate, and the strength that holds
--   yaw      differential RPM against yaw rate, and what a full turn costs
--   forward  common RPM against settled speed, and what full cruise costs
--   brake    reverse RPM against deceleration and worst pitch, main then all
--
-- A finished run also records the inventory it saw: which relays answered and
-- how many lines each had. That is what the preflight checker compares against,
-- which keeps the ship out of the code and still catches a missing part.
--
-- Everything here is allowed to be missing. A ship that has never been
-- calibrated still flies, badly, on the fallbacks in flight.lua, and an
-- uncalibrated ship saying so beats an uncalibrated ship pretending.

local util, ship, config, log, flight, turbine = ...

local cal = {}

cal.FILE = nil

cal.sides = {}        -- line name -> { side = "left"|"right"|"main"|"none", reverse }
cal.noseOffset = nil  -- degrees between the hull's +Z and where the main pushes
cal.yawAuth = {}      -- { left, right }, deg/s per RPM
cal.yawCurve = nil    -- { pos, neg }, differential RPM against yaw rate
cal.fwdCurve = nil    -- { pos, neg }, common RPM against settled speed
cal.brakeCurve = nil  -- { main, all }, reverse RPM against deceleration
cal.balloonCurve = nil
cal.altHover = nil
cal.stressAtTurn = nil
cal.stressAtCruise = nil
cal.inventory = nil   -- what the ship looked like when it was last measured
cal.meta = {}         -- when each stage was last run, for the screen

-- The order is the wizard's running order and the screen's row order, so there
-- is one list of them rather than two that can disagree.
cal.STAGES = {
    {
        id = "sides", title = "SIDES", meta = "sidesAt",
        what = "Spins each propeller on its own and reads which side of the hull it sits on.",
        room = "A few blocks of drift in every direction. The ship moves a little on each line.",
    },
    {
        id = "balloon", title = "BALLOON", meta = "balloonAt",
        what = "Walks the redstone strength from nothing to full and writes down the climb rate at each.",
        room = "Clear air above and below. At strength 0 the ship sinks, and at 15 it climbs.",
    },
    {
        id = "yaw", title = "YAW", meta = "yawAt",
        what = "Drives one side against the other and writes down how fast the hull comes round.",
        room = "Room to spin on the spot, both ways.",
    },
    {
        id = "forward", title = "FORWARD", meta = "forwardAt",
        what = "Runs the ship up at each throttle step and writes down the speed it settles at.",
        room = "A long run ahead and behind. This is the stage that covers ground.",
    },
    {
        id = "brake", title = "BRAKING", meta = "brakeAt",
        what = "Runs up to speed and reverses, on the main alone and then on all five.",
        room = "A long run ahead, four times over, with room to overshoot.",
    },
}

function cal.stageById(id)
    for _, stage in ipairs(cal.STAGES) do
        if stage.id == id then return stage end
    end
    return nil
end

-- == PERSISTENCE =============================================

function cal.init(dataDir)
    cal.FILE = fs.combine(dataDir, "cal.cfg")
    cal.load()
    return cal
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
function cal.parsePair(data)
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
function cal.parseBrake(data)
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

-- util.tidyCurve takes magnitudes, which would fold the sinking half of this
-- ladder onto the climbing half, so the balloon is read straight instead.
function cal.parseBalloon(data)
    if type(data) ~= "table" then return nil end
    local rungs = {}
    for _, rung in ipairs(data) do
        if type(rung) == "table" and type(rung.rpm) == "number"
                and type(rung.speed) == "number" then
            rungs[#rungs + 1] = { rpm = rung.rpm, speed = rung.speed }
        end
    end
    table.sort(rungs, function(a, b) return a.rpm < b.rpm end)
    if #rungs == 0 then return nil end
    return rungs
end

function cal.load()
    cal.sides, cal.yawAuth, cal.meta = {}, {}, {}
    cal.noseOffset, cal.yawCurve, cal.fwdCurve, cal.brakeCurve = nil, nil, nil, nil
    cal.balloonCurve, cal.altHover, cal.inventory = nil, nil, nil
    cal.stressAtTurn, cal.stressAtCruise = nil, nil

    if not cal.FILE or not fs.exists(cal.FILE) then return false end
    local handle = fs.open(cal.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end

    cal.sides = cal.parseSides(data.sides)
    cal.noseOffset = tonumber(data.noseOffset)
    if type(data.yawAuth) == "table" then
        cal.yawAuth = { left = tonumber(data.yawAuth.left),
                        right = tonumber(data.yawAuth.right) }
    end
    cal.yawCurve = cal.parsePair(data.yawCurve)
    cal.fwdCurve = cal.parsePair(data.fwdCurve)
    cal.brakeCurve = cal.parseBrake(data.brakeCurve)
    cal.balloonCurve = cal.parseBalloon(data.balloonCurve)
    cal.altHover = tonumber(data.altHover)
    cal.stressAtTurn = tonumber(data.stressAtTurn)
    cal.stressAtCruise = tonumber(data.stressAtCruise)
    cal.inventory = type(data.inventory) == "table" and data.inventory or nil
    cal.meta = type(data.meta) == "table" and data.meta or {}
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
        sides = cal.sides, noseOffset = cal.noseOffset, yawAuth = cal.yawAuth,
        yawCurve = cal.yawCurve, fwdCurve = cal.fwdCurve,
        brakeCurve = cal.brakeCurve, balloonCurve = cal.balloonCurve,
        altHover = cal.altHover, inventory = cal.inventory,
        stressAtTurn = cal.stressAtTurn, stressAtCruise = cal.stressAtCruise,
        meta = cal.meta,
    }))
    handle.close()
    return true
end

-- == QUERIES THE REST OF THE PROGRAM ASKS ====================

function cal.sideOf(name)
    return cal.sides[name]
end

-- The lines on the ship right now that calibration filed under a side. A saved
-- line that is not on the network is not one of them, which is the difference
-- between what was measured and what is here.
function cal.linesOfSide(side)
    local out = {}
    for _, name in ipairs(ship.order) do
        local entry = cal.sides[name]
        if entry and entry.side == side then out[#out + 1] = name end
    end
    return out
end

-- Lines the ship has that calibration has never seen.
function cal.missingLines()
    local out = {}
    for _, name in ipairs(ship.order) do
        if not cal.sides[name] then out[#out + 1] = name end
    end
    return out
end

-- The fastest this ship has been measured going, either way along the hull.
function cal.topForward()
    if not cal.fwdCurve then return nil end
    local best = nil
    for _, way in ipairs({ "pos", "neg" }) do
        local top = util.curveTopSpeed(cal.fwdCurve[way])
        if top and (not best or top > best) then best = top end
    end
    return best
end

-- The fastest turn measured, deg/s, which is what a leg's turn time is budgeted
-- against and what the TUNE preview quotes.
function cal.topYawRate()
    if not cal.yawCurve then return nil end
    local best = nil
    for _, way in ipairs({ "pos", "neg" }) do
        local top = util.curveTopSpeed(cal.yawCurve[way])
        if top and (not best or top > best) then best = top end
    end
    return best
end

-- == THE INVENTORY ===========================================
--
-- What the ship was made of when it was last measured. Comparing this against
-- what is on the network now is how a missing propeller gets named without a
-- single fact about this vessel being written into the program.

function cal.inventoryNow()
    local counts, order = {}, {}
    local sides = { left = 0, right = 0, main = 0, none = 0 }
    for _, name in ipairs(ship.order) do
        local remote = ship.remoteLines[name]
        local key = remote and remote.relay or "wire"
        if not counts[key] then counts[key] = 0; order[#order + 1] = key end
        counts[key] = counts[key] + 1
        local entry = cal.sides[name]
        local side = entry and entry.side or "none"
        sides[side] = (sides[side] or 0) + 1
    end
    table.sort(order, function(a, b) return tostring(a) < tostring(b) end)

    local relays = {}
    for _, key in ipairs(order) do
        relays[#relays + 1] = {
            id = key ~= "wire" and key or nil,
            wired = key == "wire" or nil,
            lines = counts[key],
        }
    end
    return { relays = relays, sides = sides, total = #ship.order }
end

local function relayLabel(entry)
    if entry.wired or not entry.id then return "the wire" end
    return "relay #" .. tostring(entry.id)
end

-- What has changed since the ship was measured. Each difference gets its own
-- sentence in the words of the thing that differs, because "inventory mismatch"
-- on a screen tells a pilot nothing about which computer to walk to.
function cal.inventoryCheck()
    local items = {}
    local function say(kind, fmt, ...)
        items[#items + 1] = { kind = kind, text = string.format(fmt, ...) }
    end

    if not cal.inventory or type(cal.inventory.relays) ~= "table" then
        say("warn", "this ship has never finished a calibration run, so there is nothing to compare against")
        return false, items
    end

    local now = cal.inventoryNow()
    local nowBy = {}
    for _, entry in ipairs(now.relays) do
        nowBy[entry.id or "wire"] = entry
    end

    local seen = {}
    for _, was in ipairs(cal.inventory.relays) do
        local key = was.id or "wire"
        seen[key] = true
        local isNow = nowBy[key]
        if not isNow then
            say("bad", "%s answered when the ship was measured and is not here now",
                relayLabel(was))
        elseif isNow.lines ~= was.lines then
            say("bad", "%s had %d line(s) when the ship was measured and has %d now",
                relayLabel(was), was.lines or 0, isNow.lines)
        end
    end
    for _, entry in ipairs(now.relays) do
        if not seen[entry.id or "wire"] then
            say("warn", "%s is here with %d line(s) and was not part of the measured ship",
                relayLabel(entry), entry.lines)
        end
    end

    local wasSides = type(cal.inventory.sides) == "table" and cal.inventory.sides or nil
    if wasSides then
        for _, side in ipairs({ "left", "right", "main" }) do
            local was, isNow = wasSides[side] or 0, now.sides[side] or 0
            if was ~= isNow then
                say("bad", "%d propeller(s) on the %s when measured, %d now", was, side, isNow)
            end
        end
    end

    for _, item in ipairs(items) do
        if item.kind == "bad" then return false, items end
    end
    return true, items
end

-- == WHAT THE SCREEN SHOWS ===================================

-- One row per stage: whether it has been run, when, and the headline number it
-- produced. The CAL tab and the wizard's own menu both read this.
function cal.summary()
    local out = {}
    for index, stage in ipairs(cal.STAGES) do
        local row = {
            index = index, id = stage.id, title = stage.title,
            at = cal.meta[stage.meta], done = false, detail = "not measured",
        }

        if stage.id == "sides" then
            local total = #ship.order
            local missing = #cal.missingLines()
            row.done = total > 0 and missing == 0
            if total == 0 then
                row.detail = "no propellers on the network"
            else
                row.detail = string.format("%d of %d, %dL %dR %dM",
                    total - missing, total, #cal.linesOfSide("left"),
                    #cal.linesOfSide("right"), #cal.linesOfSide("main"))
            end
        elseif stage.id == "balloon" then
            row.done = cal.balloonCurve ~= nil and cal.altHover ~= nil
            if row.done then
                row.detail = string.format("%d rungs, holds level at %d",
                    #cal.balloonCurve, cal.altHover)
            end
        elseif stage.id == "yaw" then
            row.done = cal.yawCurve ~= nil
            if row.done then
                row.detail = string.format("top %.1f deg/s%s", cal.topYawRate() or 0,
                    cal.stressAtTurn and string.format(", %.0f su", cal.stressAtTurn) or "")
            end
        elseif stage.id == "forward" then
            row.done = cal.fwdCurve ~= nil
            if row.done then
                row.detail = string.format("top %.2f m/s%s", cal.topForward() or 0,
                    cal.stressAtCruise and string.format(", %.0f su", cal.stressAtCruise) or "")
            end
        elseif stage.id == "brake" then
            row.done = cal.brakeCurve ~= nil
            if row.done then
                local cfg = config.values
                local mainMax = flight.maxDecel(cal, cfg, "main")
                local allMax = flight.maxDecel(cal, cfg, "all")
                row.detail = string.format("main %s, all %s m/s/s",
                    mainMax and string.format("%.2f", mainMax) or "-",
                    allMax and string.format("%.2f", allMax) or "-")
            end
        end

        out[#out + 1] = row
    end
    return out
end

-- == THE WIZARD ==============================================
--
-- ctx is the screen. It is handed in rather than reached for, so this file
-- never touches term directly and the whole flow can be driven by a test
-- harness or, later, by a remote console.
--
--   ctx.panel(t)              draw the wizard body from a table of fields
--   ctx.ask(question, opts)   a line of text back, with a default
--   ctx.yesno(question, def)  true or false
--   ctx.waitEnter()           blocks until Enter
--   ctx.waitAbort()           blocks until the pilot gives up, for waitForAny
--   ctx.aborted()             true once the pilot pressed q
--   ctx.note(text, kind)      one scrolling line in the wizard log
--   ctx.clearFields()         forget the panel, between stages

local function stamp()
    return os.day() .. "d " .. log.timestamp()
end

local function cfg()
    return config.values
end

-- The ladder the yaw and forward stages walk.
function cal.rpmLadder()
    local steps = config.get("calSteps")
    local first, last = config.get("calStartRpm"), config.get("calEndRpm")
    if last < first then first, last = last, first end
    if steps == 1 then return { last } end
    local out = {}
    for index = 0, steps - 1 do
        out[#out + 1] = util.round(first + (last - first) * index / (steps - 1))
    end
    return out
end

-- What the ship is doing, in whichever of the three quantities a stage measures.
local function forwardSpeed()
    local v = ship.bodyVelocity()
    return v and v.z or nil
end

local function climbRate()
    local state = ship.readState()
    return state and state.velocity.y or nil
end

local function pitchNow()
    local state = ship.readState()
    return state and util.pitchOf(state.orientation) or nil
end

local function stressNow()
    if not turbine or not turbine.status then return nil end
    local ok, status = pcall(turbine.status)
    if not ok or type(status) ~= "table" then return nil end
    return status.stress
end

-- One rung: drive it, watch the number it is supposed to move, and keep the
-- value it stopped moving at. Every stage measures something different, so what
-- is driven and what is read are both arguments, and what counts as steady is
-- config's.
--
-- A rung that runs out of patience is kept anyway, from the average of the last
-- readings rather than from the largest one seen. A ship that never settled
-- still has a speed; the peak it touched on the way is a transient and writing
-- that down would put a number in the ladder the hull cannot hold.
local function track(ctx, opts)
    local settle = opts.settle or config.get("calSettle")
    local hold = opts.hold or config.get("calHold")
    local stable = opts.stable or config.get("calStable")

    if opts.apply then opts.apply() end

    local started = os.clock()
    local history, holdFrom = {}, nil
    local result, reason = nil, nil

    local function sampler()
        while true do
            local now = os.clock()
            local value = opts.read()
            if value == nil then
                reason = "lost the pose"
                return
            end

            history[#history + 1] = { t = now, v = value }
            while #history > 2 and now - history[1].t > 1.5 do table.remove(history, 1) end

            local slope = 0
            if #history >= 2 then
                local a, b = history[1], history[#history]
                local span = b.t - a.t
                if span > 0.2 then slope = (b.v - a.v) / span end
            end

            -- Steady is not enough on its own where a sign was asked for: a ship
            -- that has not started moving yet is perfectly steady at zero.
            local steady = math.abs(slope) <= stable
            if opts.wantSign then steady = steady and value * opts.wantSign > 0 end
            holdFrom = steady and (holdFrom or now) or nil
            local held = holdFrom and (now - holdFrom) or 0

            if opts.live then
                opts.live({
                    value = value, slope = slope, held = held, holdNeeded = hold,
                    elapsed = now - started, settle = settle,
                    phase = steady and "settling" or "changing",
                })
            end

            if held >= hold then
                result = value
                return
            end
            if now - started > settle then
                local sum, count = 0, 0
                for _, entry in ipairs(history) do sum = sum + entry.v; count = count + 1 end
                result = count > 0 and sum / count or value
                reason = "did not settle"
                return
            end
            sleep(config.get("calSample"))
        end
    end

    parallel.waitForAny(sampler, ctx.waitAbort)
    if ctx.aborted() then return nil, "stopped" end
    return result, reason
end

-- Between rungs the ship has to shed what the last one built up, or the next
-- rung starts from the wrong speed and reads high.
local function cooldown(ctx, read, label)
    local secs = config.get("calCooldown")
    if secs <= 0 or ctx.aborted() then return end
    ship.allStop()
    local started = os.clock()
    local function wait()
        while os.clock() - started < secs do
            ctx.panel({
                value = read() or 0, valueLabel = label, phase = "cooldown",
                elapsed = os.clock() - started, settle = secs,
                held = os.clock() - started, holdNeeded = secs, slope = 0,
                pitch = false, yawRate = false, drift = false, guess = false,
            })
            sleep(config.get("calSample"))
        end
    end
    parallel.waitForAny(wait, ctx.waitAbort)
    ship.allStop()
end

-- The balloon is held where calibration last found it holds, for every stage
-- that measures something horizontal. A stage that let the ship sink while it
-- measured a speed would be measuring a dive.
local function holdAltitude(ctx)
    if not turbine or not turbine.hasBalloon or not turbine.hasBalloon() then return end
    local level = cal.altHover
    if not level then
        ctx.note("balloon not measured yet, so it is left where it is", "warn")
        return
    end
    pcall(turbine.setBalloon, level)
    ctx.note(string.format("balloon held at %d while this runs", level))
end

-- == STAGE: SIDES ============================================

-- Positive RPM on a line either pushes the hull forward or it does not, and it
-- either swings the nose or it does not. Those two readings are the whole
-- stage: a line that pushes forward and swings the nose right is on the left
-- side, because that is what being on the left side means.
local function stageSides(ctx)
    local names = ship.order
    if #names == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end

    ctx.note(string.format("%d lines, one at a time. Give the ship clear air.", #names))
    local auth = { left = 0, right = 0 }
    local measured = { left = false, right = false }
    local done, skipped = 0, 0

    for index, name in ipairs(names) do
        if ctx.aborted() then break end
        local current = cal.sides[name]

        ctx.panel({
            step = index, total = #names, line = name,
            current = current and current.side or nil,
            reversed = current and current.reverse or nil,
            prompt = "[Enter] spin it   s skip   q stop",
        })
        local choice = ctx.ask("", { default = "", hint = "Enter to spin, s, or q" }):lower()
        if choice == "q" then break end

        if choice == "s" then
            skipped = skipped + 1
            ctx.note(util.shortName(name) .. " left as it was")
        else
            -- The yaw rate at the moment the speed settled, not the largest seen
            -- on the way there. A hull that is still coming up to speed is still
            -- swinging, and the swing it ends at is the one it can hold.
            local yawRate, drift = 0, nil
            local speed, reason = track(ctx, {
                apply = function() ship.driveOnly(name, config.get("calRpm")) end,
                read = forwardSpeed,
                live = function(live)
                    yawRate = ship.yawRate() or 0
                    drift = ship.bodyVelocity()
                    live.step = index
                    live.total = #names
                    live.line = name
                    live.valueLabel = "speed"
                    live.unit = "m/s"
                    live.yawRate = yawRate
                    live.guess = false
                    live.drift = drift and { drift.x, drift.y, drift.z } or nil
                    ctx.panel(live)
                end,
            })
            ship.allStop()

            if ctx.aborted() then break end
            if not speed then
                ctx.note(string.format("%s: %s", util.shortName(name), tostring(reason)), "bad")
            else
                local minDrift, minYaw = config.get("calMinDrift"), config.get("calMinYaw")
                local reverse = speed < 0
                local forwardSign = reverse and -1 or 1
                -- Read with the thrust turned round to point forward, so a
                -- propeller mounted backwards lands on the same side as its
                -- neighbour rather than on the opposite one.
                local yawForward = yawRate * forwardSign

                local guess
                if math.abs(speed) < minDrift and math.abs(yawRate) < minYaw then
                    guess = "none"
                elseif math.abs(yawForward) < minYaw then
                    guess = "main"
                elseif yawForward > 0 then
                    guess = "left"
                else
                    guess = "right"
                end

                ctx.panel({
                    step = index, total = #names, line = name,
                    value = speed, valueLabel = "speed", unit = "m/s",
                    yawRate = yawRate, guess = guess,
                    drift = drift and { drift.x, drift.y, drift.z } or nil,
                    prompt = string.format("%+.2f m/s, %+.1f deg/s%s", speed, yawRate,
                        reason and (" (" .. reason .. ")") or ""),
                })
                local answer = ctx.ask("Which side is it on?", {
                    default = guess,
                    choices = { "left", "right", "main", "none" },
                    extra = { "skip" },
                })
                answer = (answer or ""):lower()
                if answer == "" then answer = guess end

                if answer == "skip" then
                    skipped = skipped + 1
                    ctx.note(util.shortName(name) .. " left as it was")
                elseif answer == "left" or answer == "right" or answer == "main"
                        or answer == "none" then
                    cal.sides[name] = { side = answer, reverse = reverse }
                    done = done + 1
                    if answer == "left" or answer == "right" then
                        auth[answer] = auth[answer] + math.abs(yawRate) / config.get("calRpm")
                        measured[answer] = true
                    end
                    if answer == "main" and drift then
                        -- Where the nose actually points. The main is the only
                        -- line whose thrust is meant to be straight down the
                        -- hull, so its drift is what the offset is measured off.
                        local bx, bz = drift.x * forwardSign, drift.z * forwardSign
                        if util.len3(bx, 0, bz) >= minDrift then
                            cal.noseOffset = util.wrapAngle(math.deg(math.atan2(-bx, bz)))
                            ctx.note(string.format("nose offset %+.1f deg", cal.noseOffset))
                        end
                    end
                    ctx.note(string.format("%s -> %s%s", util.shortName(name), answer,
                        reverse and " (reversed)" or ""), "good")
                    log.infof("cal: %s = %s reverse=%s yaw=%.2f speed=%.2f",
                        name, answer, tostring(reverse), yawRate, speed)
                    cal.save()
                else
                    ctx.note("left, right, main or none. Left as it was.", "bad")
                end
            end
        end
    end

    ship.allStop()
    -- A side with no reading this run keeps what it had. Half a run is still
    -- worth keeping, and a zero here would divide the mixer by nothing.
    for _, side in ipairs({ "left", "right" }) do
        if measured[side] and auth[side] > 0 then cal.yawAuth[side] = auth[side] end
    end

    cal.inventory = cal.inventoryNow()
    cal.meta.sidesAt = stamp()
    cal.save()
    ctx.note(string.format("sides saved: %d set, %d left alone", done, skipped), "good")
    if cal.yawAuth.left and cal.yawAuth.right then
        ctx.note(string.format("yaw authority  left %.4f  right %.4f deg/s per rpm",
            cal.yawAuth.left, cal.yawAuth.right))
    end
    return true
end

-- == STAGE: BALLOON ==========================================

-- A coarse sweep to find where the climb rate crosses zero, then the strengths
-- either side of it one at a time. Hover is the number that matters and it has
-- to be exact; the rest of the ladder only has to be shaped right.
local function stageBalloon(ctx)
    if not turbine or not turbine.hasBalloon or not turbine.hasBalloon() then
        ctx.note("no relay is holding the balloon, so there is nothing to measure", "bad")
        return false
    end

    local step = config.get("calBalloonStep")
    local dwell = config.get("calBalloonDwell")
    local levels, seen = {}, {}
    for level = 0, 15, step do
        levels[#levels + 1] = level
        seen[level] = true
    end
    if not seen[15] then levels[#levels + 1] = 15; seen[15] = true end

    local samples = {}
    local function measure(level, index, total)
        local climb, reason = track(ctx, {
            apply = function() pcall(turbine.setBalloon, level) end,
            read = climbRate,
            settle = dwell,
            live = function(live)
                live.rungIndex = index
                live.rungTotal = total
                live.rungLabel = string.format("strength %d", level)
                live.valueLabel = "climb"
                live.unit = "m/s"
                live.samples = samples
                ctx.panel(live)
            end,
        })
        if ctx.aborted() or not climb then return nil, reason end
        samples[#samples + 1] = { rpm = level, speed = climb }
        table.sort(samples, function(a, b) return a.rpm < b.rpm end)
        cal.balloonCurve = samples
        cal.save()
        ctx.note(string.format("strength %2d -> %+.2f m/s%s", level, climb,
            reason and (" (" .. reason .. ")") or ""), reason and "warn" or "good")
        log.infof("cal: balloon level=%d climb=%.3f %s", level, climb, reason or "settled")
        return climb
    end

    ctx.note(string.format("sweeping %d strengths, %.0fs each. The ship will sink and climb.",
        #levels, dwell), "warn")
    for index, level in ipairs(levels) do
        if ctx.aborted() then break end
        if not measure(level, index, #levels) then break end
    end

    -- Refine around the crossing: the two strengths either side of where the
    -- ship stops sinking and starts climbing are the only ones hover can be.
    if not ctx.aborted() then
        local below, above = nil, nil
        for _, sample in ipairs(samples) do
            if sample.speed < 0 then below = sample.rpm end
            if sample.speed >= 0 and not above then above = sample.rpm end
        end
        if below and above and above - below > 1 then
            local extra = {}
            for level = below + 1, above - 1 do extra[#extra + 1] = level end
            ctx.note(string.format("crossing is between %d and %d, walking the %d between",
                below, above, #extra))
            for index, level in ipairs(extra) do
                if ctx.aborted() then break end
                if not seen[level] then
                    seen[level] = true
                    if not measure(level, index, #extra) then break end
                end
            end
        elseif not below then
            ctx.note("this balloon climbs at every strength, including zero", "warn")
        elseif not above then
            ctx.note("this balloon never held level, even at full strength", "bad")
        end
    end

    -- Hover is the measured strength whose climb rate is nearest to nothing,
    -- and a tie goes upward. A ship parked a hair light is a ship that drifts
    -- up; a ship parked a hair heavy is one that arrives on the ground.
    local best = nil
    for _, sample in ipairs(samples) do
        if not best or math.abs(sample.speed) < math.abs(best.speed)
                or (math.abs(sample.speed) == math.abs(best.speed) and sample.speed > best.speed) then
            best = sample
        end
    end
    if best then
        cal.altHover = best.rpm
        pcall(turbine.setBalloon, cal.altHover)
        ctx.note(string.format("holds level at strength %d, %+.2f m/s", best.rpm, best.speed), "good")
    end

    cal.meta.balloonAt = stamp()
    cal.save()
    return true
end

-- == STAGE: YAW ==============================================

local function stageYaw(ctx)
    if #cal.linesOfSide("left") == 0 or #cal.linesOfSide("right") == 0 then
        ctx.note("no line on one of the two sides, so there is nothing to turn against. Run sides first.", "bad")
        return false
    end
    holdAltitude(ctx)

    local ladder = cal.rpmLadder()
    local ways = config.get("calBothWays") and { 1, -1 } or { 1 }
    local total = #ladder * #ways
    local index = 0
    cal.yawCurve = cal.yawCurve or {}

    for _, sign in ipairs(ways) do
        local way = sign > 0 and "pos" or "neg"
        local samples = {}
        for _, diff in ipairs(ladder) do
            if ctx.aborted() then break end
            index = index + 1

            local rate, reason = track(ctx, {
                apply = function()
                    ship.flush(flight.mix(0, diff * sign, ship.order, cal, cfg()))
                end,
                read = ship.yawRate,
                stable = config.get("calYawStable"),
                wantSign = sign,
                live = function(live)
                    live.rungIndex = index
                    live.rungTotal = total
                    live.rungLabel = string.format("differential %+d", diff * sign)
                    live.valueLabel = "yaw"
                    live.unit = "deg/s"
                    live.samples = samples
                    ctx.panel(live)
                end,
            })

            if ctx.aborted() then break end
            if rate and math.abs(rate) > 0 then
                samples[#samples + 1] = { rpm = diff, speed = math.abs(rate) }
                ctx.note(string.format("%+4d rpm -> %.1f deg/s%s", diff * sign, math.abs(rate),
                    reason and (" (" .. reason .. ")") or ""), reason and "warn" or "good")
                log.infof("cal: yaw way=%s rpm=%d rate=%.2f %s", way, diff, rate, reason or "settled")
                -- The stress of a full turn is read at the top rung, while the
                -- ship is actually doing it. Read after the stop and it is the
                -- stress of nothing happening.
                if diff == ladder[#ladder] then
                    local stress = stressNow()
                    if stress then
                        cal.stressAtTurn = stress
                        ctx.note(string.format("a full turn draws %.0f su", stress))
                    end
                end
            else
                ctx.note(string.format("%+4d rpm -> no reading (%s)", diff * sign,
                    tostring(reason)), "bad")
            end

            cal.yawCurve[way] = util.tidyCurve(samples)
            cal.save()
            cooldown(ctx, function() return ship.yawRate() or 0 end, "yaw")
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    cal.meta.yawAt = stamp()
    cal.save()
    return true
end

-- == STAGE: FORWARD ==========================================

local function stageForward(ctx)
    if #ship.order == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end
    holdAltitude(ctx)

    local ladder = cal.rpmLadder()
    local ways = config.get("calBothWays") and { 1, -1 } or { 1 }
    local total = #ladder * #ways
    local index = 0
    cal.fwdCurve = cal.fwdCurve or {}

    for _, sign in ipairs(ways) do
        local way = sign > 0 and "pos" or "neg"
        local samples = {}
        for _, rpm in ipairs(ladder) do
            if ctx.aborted() then break end
            index = index + 1

            local speed, reason = track(ctx, {
                apply = function()
                    ship.flush(flight.mix(rpm * sign, 0, ship.order, cal, cfg()))
                end,
                read = forwardSpeed,
                wantSign = sign,
                live = function(live)
                    live.rungIndex = index
                    live.rungTotal = total
                    live.rungLabel = string.format("throttle %+d", rpm * sign)
                    live.valueLabel = "speed"
                    live.unit = "m/s"
                    live.samples = samples
                    ctx.panel(live)
                end,
            })

            if ctx.aborted() then break end
            if speed and math.abs(speed) > 0 then
                samples[#samples + 1] = { rpm = rpm, speed = math.abs(speed) }
                ctx.note(string.format("%+4d rpm -> %.2f m/s%s", rpm * sign, math.abs(speed),
                    reason and (" (" .. reason .. ")") or ""), reason and "warn" or "good")
                log.infof("cal: forward way=%s rpm=%d speed=%.3f %s", way, rpm, speed,
                    reason or "settled")
                if rpm == ladder[#ladder] then
                    local stress = stressNow()
                    if stress then
                        cal.stressAtCruise = stress
                        ctx.note(string.format("full cruise draws %.0f su", stress))
                    end
                end
            else
                ctx.note(string.format("%+4d rpm -> no reading (%s)", rpm * sign,
                    tostring(reason)), "bad")
            end

            cal.fwdCurve[way] = util.tidyCurve(samples)
            cal.save()
            cooldown(ctx, function() return forwardSpeed() or 0 end, "speed")
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    cal.meta.forwardAt = stamp()
    cal.save()
    return true
end

-- == STAGE: BRAKING ==========================================

-- Run up, reverse, and write down how hard it stopped and how far the nose went
-- over doing it. Two rungs each for the main alone and for all five, and the
-- pilot is asked before every one of the four, because each is a run at speed
-- and the ship covers ground it has to have.
local function brakeRun(ctx, which, rpm, label)
    local top = config.get("cruiseMaxRpm")
    local v0 = track(ctx, {
        apply = function() ship.flush(flight.mix(top, 0, ship.order, cal, cfg())) end,
        read = forwardSpeed,
        settle = config.get("calRunup"),
        wantSign = 1,
        live = function(live)
            live.rungLabel = label .. ", running up"
            live.valueLabel = "speed"
            live.unit = "m/s"
            ctx.panel(live)
        end,
    })
    if ctx.aborted() or not v0 or v0 <= 0 then
        ship.allStop()
        return nil, ctx.aborted() and "stopped" or "never got moving"
    end

    -- The reverse itself is not a settle. What is wanted is the slope of the
    -- speed while it comes off, so this runs until the ship is stopped or until
    -- it runs out of patience, and measures what happened over that.
    local turbines = which == "all" and -rpm or 0
    ship.flush(flight.mixParts(-rpm, turbines, 0, ship.order, cal, cfg()))

    local started = os.clock()
    local limit = config.get("calSettle")
    local worstPitch, v, elapsed = 0, v0, 0

    local function run()
        while true do
            local now = os.clock()
            elapsed = now - started
            local speed = forwardSpeed()
            if not speed then return end
            v = speed
            -- Nose over only. The run up leaves the hull sitting nose high, and
            -- taking the largest pitch either way would write that down as the
            -- cost of braking when it is the cost of getting up to speed.
            local pitch = pitchNow()
            if pitch and -pitch > worstPitch then worstPitch = -pitch end
            ctx.panel({
                rungLabel = label .. ", stopping",
                valueLabel = "speed", unit = "m/s", value = speed, slope = 0,
                phase = "braking", elapsed = elapsed, settle = limit,
                held = 0, holdNeeded = 0, pitch = worstPitch, from = v0,
            })
            if speed <= 0 or elapsed >= limit then return end
            sleep(config.get("calSample"))
        end
    end

    parallel.waitForAny(run, ctx.waitAbort)
    ship.allStop()
    if ctx.aborted() then return nil, "stopped" end
    if elapsed <= 0 then return nil, "stopped before it was measured" end

    local decel = (v0 - math.max(v, 0)) / elapsed
    return { rpm = rpm, speed = decel, pitch = worstPitch }, nil, v0
end

local function stageBrake(ctx)
    if #ship.order == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end
    if #cal.linesOfSide("main") == 0 then
        ctx.note("no line is filed as the main, so there is no main to stop on. Run sides first.", "bad")
        return false
    end
    holdAltitude(ctx)

    local full = config.get("brakeRpmMax")
    local rungs = { util.round(full / 2), full }
    cal.brakeCurve = cal.brakeCurve or {}

    for _, which in ipairs({ "main", "all" }) do
        local kept = {}
        for _, rpm in ipairs(rungs) do
            if ctx.aborted() then break end
            local label = string.format("%s at %d rpm",
                which == "main" and "the main alone" or "all five", rpm)

            ctx.panel({
                rungLabel = label,
                prompt = "a run up to full speed and a stop. Room ahead.",
            })
            if not ctx.yesno("Run " .. label .. "?", true) then
                ctx.note(label .. " skipped")
            else
                local rung, reason, from = brakeRun(ctx, which, rpm, label)
                if rung then
                    kept[#kept + 1] = rung
                    table.sort(kept, function(a, b) return a.rpm < b.rpm end)
                    cal.brakeCurve[which] = kept
                    cal.save()
                    ctx.note(string.format("%s: %.2f m/s/s from %.1f m/s, nose %+.1f deg",
                        label, rung.speed, from or 0, rung.pitch or 0), "good")
                    log.infof("cal: brake which=%s rpm=%d decel=%.3f pitch=%.2f",
                        which, rpm, rung.speed, rung.pitch or 0)
                else
                    ctx.note(string.format("%s: no reading (%s)", label, tostring(reason)), "bad")
                end
                cooldown(ctx, function() return forwardSpeed() or 0 end, "speed")
            end
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    cal.meta.brakeAt = stamp()
    cal.save()
    return true
end

local RUNNERS = {
    sides = stageSides,
    balloon = stageBalloon,
    yaw = stageYaw,
    forward = stageForward,
    brake = stageBrake,
}

-- == THE RUN =================================================

-- Every stage is confirmed before it runs, with what it does and how much room
-- it needs, and every stage can be passed over. A wizard that has to be taken
-- from the top to fix one ladder is a wizard nobody re-runs.
function cal.runWizard(ctx, only)
    local stages = {}
    for _, stage in ipairs(cal.STAGES) do
        if not only or only == stage.id then stages[#stages + 1] = stage end
    end
    if #stages == 0 then
        ctx.note("no such stage. They are sides, balloon, yaw, forward and brake.", "bad")
        return false
    end

    local rows = {}
    for _, row in ipairs(cal.summary()) do rows[row.id] = row end

    local ran = 0
    for index, stage in ipairs(stages) do
        if ctx.aborted() then break end
        ctx.clearFields()

        local row = rows[stage.id]
        ctx.panel({
            stageIndex = index, stageTotal = #stages, stageTitle = stage.title,
            what = stage.what, room = stage.room,
            current = row and row.detail or nil,
            at = row and row.at or nil,
            prompt = "[Enter] run it   s skip   q stop",
        })
        local choice = ctx.ask("", { default = "", hint = "Enter to run, s, or q" }):lower()
        if choice == "q" then break end

        if choice == "s" then
            ctx.note(stage.title .. " skipped")
        else
            -- The card goes away once the stage starts. Its prompt offered a
            -- choice that has already been made, and a stale prompt on a screen
            -- is a screen nobody trusts.
            ctx.clearFields()
            ctx.panel({ stageIndex = index, stageTotal = #stages, stageTitle = stage.title })
            ctx.note("== " .. stage.title .. " ==", "warn")
            local ok, err = pcall(RUNNERS[stage.id], ctx)
            -- A stage that errors out has to hand the propellers back stopped
            -- before the next one is offered, and has to say what broke in the
            -- words the error came in.
            pcall(ship.allStop)
            if not ok then
                ctx.note(stage.title .. " failed: " .. tostring(err), "bad")
                log.error("cal: " .. stage.title .. " failed: " .. tostring(err))
            elseif err ~= false then
                ran = ran + 1
            end
        end
    end

    ship.allStop()
    if ran > 0 then
        cal.inventory = cal.inventoryNow()
        cal.save()
    end
    ctx.clearFields()
    if ctx.aborted() then
        ctx.note("calibration stopped early. What was measured is saved.", "warn")
    else
        ctx.note(string.format("calibration finished, %d stage(s) run", ran), "good")
    end
    return true
end

return cal
