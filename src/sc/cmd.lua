-- cmd.lua -- the command line.
--
-- Every command returns a line of text and a colour hint, and never touches the
-- screen itself. That makes the whole command set testable, and it is why the
-- same dispatcher can later be pointed at a modem without any of it changing.

local util, ship, cal, control, nav, fuel, turbine, config, ui, log, preflight, popup,
    telemetry, link = ...

local cmd = {}

cmd.quit = false

local handlers = {}
local order = {}

local function define(name, spec)
    handlers[name] = spec
    order[#order + 1] = name
    for _, alias in ipairs(spec.aliases or {}) do handlers[alias] = spec end
end

local function currentPos()
    local state = ship.readState()
    if not state then return nil, "no pose: " .. tostring(select(2, ship.readState())) end
    return state.position
end

-- == THE GATE ================================================
--
-- Everything that puts the propellers to work runs the checker first and
-- refuses by name if it fails. Calibration is the one thing that does not,
-- because calibration is how a ship reaches a state the checker would pass in
-- the first place.
--
-- Every refusal can be overridden from the popup. The point of this is not to
-- stop a pilot, it is to make sure that flying without a side of turbines is a
-- thing somebody decided rather than a thing nobody noticed.

local function firstFailure(report)
    return preflight.failures(report)[1]
end

local function gate(what, to, descriptor)
    local report = preflight.check(ship, cal, fuel, turbine, config, link)

    if not report.ok then
        local item = firstFailure(report)
        telemetry.event("gate", "refused " .. what, item and item.text)
        local choice = ui.showPopup(descriptor and descriptor(report)
            or popup.preflight(report, what))
        if choice ~= "override" then
            return false, item and item.text or "not ready to " .. what
        end
        log.warn(what .. ": flown past the gate on " .. tostring(item and item.id))
        telemetry.event("gate", "overridden " .. what, item and item.id)
        return true
    end

    -- The ship is fit. Whether this particular leg is affordable is a second
    -- question, and only a leg with somewhere to go has it.
    local plan = to and preflight.planFor(ship, cal, config, to)
    if not plan then return true end

    local tanks = fuel.status()
    local leg = preflight.forLeg(report, tanks, turbine.status(), plan)
    if leg.ok then return true end

    local shortfall = leg.byId.fuelTime
    local modal
    if shortfall and not shortfall.ok then
        local short = leg.seconds * config.get("fuelMargin") - (tanks.endurance or 0)
        local speed = cal.topForward() or config.get("cruiseSpeed")
        modal = popup.fuelShortfall(short, short * speed)
    else
        modal = popup.preflight(leg, what)
    end

    local item = firstFailure(leg)
    telemetry.event("gate", "refused leg for " .. what, item and item.text)
    if ui.showPopup(modal) ~= "override" then
        return false, item and item.text or "the leg is not affordable"
    end
    log.warn(what .. ": leg flown past the gate on purpose")
    telemetry.event("gate", "overridden leg for " .. what, item and item.id)
    return true
end

-- == WAYPOINTS ===============================================

define("save", {
    usage = "save <name> [x y z]",
    help = "Pin a waypoint. With no coordinates it saves where the ship is now.",
    run = function(args)
        local name = args[1]
        if not name then return "usage: save <name> [x y z]", "warn" end
        local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
        if not x then
            local pos, err = currentPos()
            if not pos then return err, "bad" end
            x, y, z = pos.x, pos.y, pos.z
        elseif not z then
            -- Two numbers is the old starcatcher shape, X and Z. This autopilot
            -- owns the vertical axis, so the height is taken from the ship
            -- rather than left empty: a waypoint is a point, not a pin on a map,
            -- and "any height" was only ever honest on a hull that could not
            -- choose one.
            z = tonumber(args[3])
            if not z then return "usage: save <name> [x y z]", "warn" end
            local pos, err = currentPos()
            if not pos then return "no pose, so no height to save with it: " .. tostring(err), "bad" end
            y = pos.y
        end
        local wp, replaced = nav.add(name, x, y, z)
        return (replaced and "updated " or "saved ") .. nav.describe(wp), "good"
    end,
})

define("del", {
    aliases = { "delete", "rm" },
    usage = "del <name>",
    help = "Forget a waypoint.",
    run = function(args)
        if not args[1] then return "usage: del <name>", "warn" end
        if nav.remove(args[1]) then return "deleted " .. args[1], "good" end
        return "no waypoint called " .. args[1], "bad"
    end,
})

define("rename", {
    usage = "rename <old> <new>",
    help = "Rename a waypoint.",
    run = function(args)
        if not (args[1] and args[2]) then return "usage: rename <old> <new>", "warn" end
        local ok, err = nav.rename(args[1], args[2])
        return ok and ("renamed to " .. args[2]) or err, ok and "good" or "bad"
    end,
})

define("list", {
    aliases = { "ls", "wp" },
    usage = "list",
    help = "Show the waypoint table on the NAV tab.",
    run = function()
        ui.tab = ui.TAB.NAV
        return string.format("%d waypoints", #nav.points), "hi"
    end,
})

-- == FLYING ==================================================

define("goto", {
    aliases = { "go" },
    usage = "goto <name>",
    help = "Fly to a saved waypoint.",
    run = function(args)
        if not args[1] then return "usage: goto <name>", "warn" end
        local pos = currentPos()
        local wp = nav.find(args[1])
        local allowed, refused = gate("fly", wp)
        if not allowed then return refused, "bad" end
        local ok, err = nav.goTo(args[1], pos and pos.y or nil)
        if not ok then return tostring(err), "bad" end
        ui.tab = ui.TAB.FLIGHT
        return "flying to " .. args[1], "good"
    end,
})

define("fly", {
    aliases = { "gotocoords", "coords" },
    usage = "fly <x> <y> <z>",
    help = "Fly to raw coordinates. Two numbers means X and Z at the present height.",
    run = function(args)
        local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
        if x and y and not z then
            local pos = currentPos()
            if not pos then return "no pose, so no height to hold", "bad" end
            x, z, y = x, y, pos.y
        end
        if not (x and y and z) then return "usage: fly <x> <y> <z>", "warn" end
        local allowed, refused = gate("fly", { x = x, y = y, z = z })
        if not allowed then return refused, "bad" end
        local ok, err = nav.goToCoords(x, y, z)
        if not ok then return tostring(err), "bad" end
        ui.tab = ui.TAB.FLIGHT
        return string.format("flying to %d %d %d", util.round(x), util.round(y), util.round(z)), "good"
    end,
})

define("route", {
    usage = "route <name> <name> ...",
    help = "Fly a list of waypoints in order, one leg after the next.",
    run = function(args)
        if #args == 0 then
            nav.clearRoute()
            return "route cleared", "warn"
        end
        local pos = currentPos()
        -- Gated on the ship, not on the legs. A route is checked leg by leg as
        -- each one is engaged, and quoting a fuel budget for the whole list
        -- would be quoting it against a position the ship is not at yet.
        local allowed, refused = gate("fly the route")
        if not allowed then return refused, "bad" end
        local ok, err = nav.setRoute(args, pos and pos.y or nil)
        if not ok then return tostring(err), "bad" end
        ui.tab = ui.TAB.FLIGHT
        return "route: " .. table.concat(args, " > "), "good"
    end,
})

define("stop", {
    aliases = { "halt", "x" },
    usage = "stop",
    help = "Cut the propellers and drop the target.",
    run = function()
        control.stop("STOPPED BY PILOT")
        nav.clearRoute()
        control.clearTarget()
        return "all stop", "warn"
    end,
})

define("hold", {
    usage = "hold",
    help = "Station keep right here, fighting drift, until told otherwise.",
    run = function()
        local pos, err = currentPos()
        if not pos then return err, "bad" end
        control.setTarget(pos.x, pos.y, pos.z, "hold")
        control.hold = { x = pos.x, y = pos.y, z = pos.z }
        control.start()
        return "holding position", "good"
    end,
})

define("resume", {
    aliases = { "start", "engage" },
    usage = "resume",
    help = "Re-engage on the target already set.",
    run = function()
        local allowed, refused = gate("engage", control.target)
        if not allowed then return refused, "bad" end
        local ok, err = control.start()
        return ok and "engaged" or tostring(err), ok and "good" or "warn"
    end,
})

define("manual", {
    aliases = { "man" },
    usage = "manual <throttle> <yaw> [level] | manual off",
    help = "Fly by hand. Throttle and yaw are -1 to 1, level is the balloon 0 to 15.",
    run = function(args)
        -- `manual off` is its own word rather than three zeros, because handing
        -- the ship back is a thing a pilot means rather than a value they set.
        local first = (args[1] or ""):lower()
        if first == "off" or first == "stop" then
            control.setManual(0, 0, nil)
            return "the autopilot has the ship back", "good"
        end
        -- Fractions rather than m/s, so what you ask for means the same thing on
        -- a ship whose curves have been measured and one whose have not.
        local throttle = util.clamp(tonumber(args[1]) or 0, -1, 1)
        local yaw = util.clamp(tonumber(args[2]) or 0, -1, 1)
        local level = args[3] and util.clamp(tonumber(args[3]) or 0, 0, 15) or nil
        if throttle ~= 0 or yaw ~= 0 or level then
            local allowed, refused = gate("fly by hand", nil, popup.manualOverride)
            if not allowed then return refused, "bad" end
        end
        control.setManual(throttle, yaw, level)
        if not control.manual then return "manual off", "warn" end
        ui.tab = ui.TAB.MANUAL
        return string.format("manual throttle %+.2f yaw %+.2f%s", throttle, yaw,
            level and string.format(" level %d", level) or ""), "warn"
    end,
})

define("check", {
    aliases = { "preflight" },
    usage = "check",
    help = "Ask the preflight checker whether this ship is fit to be told to fly.",
    run = function()
        -- The same checker the gate runs, asked rather than triggered. Nothing
        -- here acts on the answer: that is the gate's job, and a checker a pilot
        -- can consult without committing to anything is the point.
        local report = preflight.check(ship, cal, fuel, turbine, config, link)
        ui.showPopup(popup.report(report))
        if report.ok then
            return string.format("ready, %d checks passed", #report.items), "good"
        end
        local item = firstFailure(report)
        return item and item.text or "not ready to fly", "bad"
    end,
})

define("balloon", {
    usage = "balloon <0-15> | balloon auto",
    help = "Hold the balloon at a strength by hand, or give the height back to the loop.",
    run = function(args)
        local what = (args[1] or ""):lower()
        if what == "auto" or what == "off" then
            control.setManual(0, 0, nil)
            return "the altitude loop has the balloon back", "good"
        end
        local level = tonumber(args[1])
        if not level then return "usage: balloon <0-15> or balloon auto", "warn" end
        level = util.clamp(util.round(level), 0, 15)
        -- Setting the level by hand is flying by hand with no thrust, which is
        -- what it is, rather than a second path into the balloon that the
        -- altitude loop would overwrite a tick later.
        local allowed, refused = gate("hold the balloon by hand", nil, popup.manualOverride)
        if not allowed then return refused, "bad" end
        control.setManual(0, 0, level)
        ui.tab = ui.TAB.MANUAL
        return string.format("balloon held at %d, and the leg is off", level), "warn"
    end,
})

define("passcode", {
    aliases = { "pair" },
    usage = "passcode <word> | passcode off",
    help = "Set the passcode this ship's messages carry. Every computer needs the same one.",
    run = function(args)
        local what = args[1]
        if not what then
            local status = link.status()
            if not status.paired then
                return "no passcode set, so anything on this protocol is obeyed", "warn"
            end
            if status.refused > 0 then
                return string.format("paired, and %d message(s) refused, last from #%s",
                    status.refused, tostring(status.refusedFrom)), "warn"
            end
            return "paired, and nothing has been refused", "good"
        end
        if what:lower() == "off" or what:lower() == "clear" then
            link.clear()
            log.warn("passcode cleared, this computer now obeys anything on its protocol")
            return "passcode cleared. Clear it on the relays too, or they stop answering.", "warn"
        end
        local ok, why = link.set(what)
        if not ok then return why, "bad" end
        log.info("passcode set")
        -- Said plainly, because a pilot who sets this on one computer and walks
        -- away has just made three relays deaf and will read it as a fault.
        return "passcode set. Set the same one on computers 1, 2 and 3.", "warn"
    end,
})

-- Asks each computer on the ship to answer for itself. Everything else on this
-- screen is inferred from messages that arrive on their own: a relay reads as
-- lost when its broadcasts stop, which it also does when a chunk unloads, when
-- a modem is broken and when somebody typed a different passcode. This is the
-- one question with a direct answer, and the answer names the role the relay
-- believes it has, so a redstone relay on the wrong computer shows up here
-- rather than in a balloon that never moves.
define("ping", {
    aliases = { "peers" },
    usage = "ping | ping <id> ...",
    help = "Ask each computer on this ship to answer for itself.",
    run = function(args)
        if not turbine.modem then
            return "no modem on this computer, so there is nobody to ask", "bad"
        end

        local ids, where = {}, {}
        if #args > 0 then
            for _, word in ipairs(args) do
                local id = tonumber(word)
                if not id then return "a computer id is a number: ping 1 2 3", "bad" end
                ids[#ids + 1] = id
                where[id] = "asked for"
            end
        else
            for role, id in pairs(link.peers or {}) do
                if role ~= "command" and type(id) == "number" then
                    ids[#ids + 1] = id
                    where[id] = role
                end
            end
            -- A ship installed before the wizard wrote its peers down still has
            -- relays talking to it, so the next best list is whoever has spoken.
            if #ids == 0 then
                for _, id in ipairs(turbine.order) do
                    ids[#ids + 1] = id
                    where[id] = "heard from"
                end
            end
            if #ids == 0 then
                return "no peers written down and no relay has spoken. Try `ping 1 2 3`", "warn"
            end
            table.sort(ids)
        end

        local answers, refusals = link.sweep(ids, 2)
        local said, quiet, refused = {}, {}, {}
        for _, id in ipairs(ids) do
            if answers[id] then
                said[#said + 1] = string.format("#%d %s", id, answers[id])
            elseif refusals[id] then
                refused[#refused + 1] = string.format("#%d", id)
            else
                quiet[#quiet + 1] = string.format("#%d %s", id, where[id] or "")
            end
        end

        if #quiet == 0 and #refused == 0 then
            return "answered: " .. table.concat(said, ", "), "good"
        end
        local parts = {}
        if #said > 0 then parts[#parts + 1] = "answered " .. table.concat(said, ", ") end
        if #refused > 0 then
            parts[#parts + 1] = "wrong passcode at " .. table.concat(refused, ", ")
        end
        if #quiet > 0 then parts[#parts + 1] = "no answer from " .. table.concat(quiet, ", ") end
        log.warn("ping: " .. table.concat(parts, "; "))
        return table.concat(parts, "; "), "bad"
    end,
})

-- == CALIBRATION =============================================

define("cal", {
    aliases = { "calibrate" },
    usage = "cal [sides|balloon|yaw|forward|brake]",
    help = "Measure the ship. Five stages, each confirmed and each skippable.",
    run = function(args)
        local only = args[1] and args[1]:lower() or nil
        if only and not cal.stageById(only) then
            return "the stages are sides, balloon, yaw, align, forward, cruise and brake", "warn"
        end
        -- Calibration is the one thing the gate never blocks. It is how a ship
        -- gets into a state the checker would pass in the first place.
        control.stop("CALIBRATING")
        ui.runWizard(only and ("CALIBRATION: " .. only:upper()) or "CALIBRATION",
            function(ctx)
                cal.runWizard(ctx, only)
                ctx.clearFields()
                ctx.note("done. Press Enter to go back.", "good")
                ctx.waitEnter()
            end)
        ui.tab = ui.TAB.CAL
        return "calibration finished", "good"
    end,
})

define("curves", {
    usage = "curves",
    help = "Show what calibration measured, stage by stage.",
    run = function()
        ui.tab = ui.TAB.CAL
        local parts = {}
        for _, row in ipairs(cal.summary()) do
            parts[#parts + 1] = string.format("%s %s", row.title,
                row.done and "ok" or "-")
        end
        return table.concat(parts, "  "), "hi"
    end,
})

define("inventory", {
    aliases = { "inv" },
    usage = "inventory",
    help = "Compare the ship on the network against the one that was measured.",
    run = function()
        local ok, items = cal.inventoryCheck()
        if #items == 0 then
            local now = cal.inventoryNow()
            return string.format("%d lines, unchanged since calibration", now.total), "good"
        end
        -- The first difference, in its own words. The rest are on the CAL tab,
        -- because a status line that lists four faults is read as one.
        return items[1].text, ok and "warn" or "bad"
    end,
})

define("forget", {
    usage = "forget sides|balloon|yaw|align|forward|cruise|brake|all",
    help = "Throw away one stage of calibration so it can be measured again.",
    run = function(args)
        local what = (args[1] or ""):lower()
        if what == "sides" then
            cal.sides, cal.yawAuth, cal.noseOffset = {}, {}, nil
            cal.meta.sidesAt = nil
        elseif what == "balloon" then
            cal.balloonCurve, cal.altHover = nil, nil
            cal.meta.balloonAt = nil
        elseif what == "yaw" then
            cal.yawCurve, cal.stressAtTurn = nil, nil
            cal.meta.yawAt = nil
        elseif what == "forward" then
            cal.fwdCurve, cal.stressAtCruise = nil, nil
            cal.meta.forwardAt = nil
        elseif what == "align" then
            cal.frontOffset, cal.alignSpread, cal.alignPoints = nil, nil, nil
            cal.frontConfirmed = nil
            cal.meta.alignAt = nil
        elseif what == "cruise" then
            -- The nose offset is left where it is. The cruise stage refines a
            -- number the sides stage measured rather than owning it, and
            -- throwing it away here would leave the ship steering by nothing.
            cal.frontConfirmed = nil
            cal.meta.cruiseAt = nil
        elseif what == "brake" then
            cal.brakeCurve = nil
            cal.meta.brakeAt = nil
        elseif what == "all" then
            cal.sides, cal.yawAuth, cal.meta = {}, {}, {}
            cal.noseOffset, cal.yawCurve, cal.fwdCurve = nil, nil, nil
            cal.brakeCurve, cal.balloonCurve, cal.altHover = nil, nil, nil
            cal.stressAtTurn, cal.stressAtCruise, cal.inventory = nil, nil, nil
            cal.frontOffset, cal.alignSpread, cal.alignPoints = nil, nil, nil
            cal.frontConfirmed = nil
        else
            return "forget sides, balloon, yaw, align, forward, cruise, brake or all", "warn"
        end
        cal.save()
        return "forgotten: " .. what, "warn"
    end,
})

-- == SETTINGS ================================================

define("set", {
    usage = "set <key> <value>",
    help = "Change any tuning value. Saved at once, applied at once.",
    run = function(args)
        if not args[1] then return "usage: set <key> <value>", "warn" end
        if not args[2] then return "usage: set " .. args[1] .. " <value>", "warn" end
        local value, err = config.set(args[1], args[2])
        if err then return err, "bad" end
        local _ = value
        return args[1] .. " = " .. config.format(args[1]), "good"
    end,
})

define("get", {
    usage = "get [key]",
    help = "Read a tuning value, or open the TUNE tab with no argument.",
    run = function(args)
        if not args[1] then
            ui.tab = 5
            return "tuning", "hi"
        end
        if not config.byKey[args[1]] then return "no such setting: " .. args[1], "bad" end
        return string.format("%s = %s   %s", args[1], config.format(args[1]),
            config.byKey[args[1]].help), "hi"
    end,
})

define("reset", {
    usage = "reset [key]",
    help = "Put a setting, or everything, back to its default.",
    run = function(args)
        local ok, err = config.reset(args[1])
        if err then return err, "bad" end
        local _ = ok
        return args[1] and (args[1] .. " = " .. config.format(args[1])) or "all settings reset", "warn"
    end,
})

-- == HOUSEKEEPING ============================================

define("rescan", {
    usage = "rescan",
    help = "Look at the network again, after plugging something in.",
    run = function()
        control.stop("RESCANNING")
        turbine.ping()
        local found = ship.discover()
        cal.load()
        control.init()
        return string.format("%d propeller lines, %d bearings", found, #ship.bearings), "good"
    end,
})

define("tab", {
    usage = "tab <1-7>",
    help = "Switch tab. F1 to F7 does the same thing.",
    run = function(args)
        local n = tonumber(args[1])
        if not n or not ui.TABS[n] then return "tab 1 to " .. #ui.TABS, "warn" end
        ui.tab = n
        return ui.TABS[n], "hi"
    end,
})

define("log", {
    usage = "log",
    help = "Open the log tab.",
    run = function() ui.tab = 7; return log.path or "log", "hi" end,
})

-- == FUEL ====================================================

define("fuel", {
    usage = "fuel",
    help = "Open the fuel tab and ask the relay for a reading now.",
    run = function()
        ui.tab = 6
        fuel.ping()
        local status = fuel.status()
        if status.link == "nomodem" then
            return "no modem on this computer, so there is no fuel link", "bad"
        elseif status.link == "waiting" then
            return "listening on " .. tostring(fuel.modem) .. ", relay has not spoken yet", "warn"
        elseif status.link == "stale" then
            return string.format("relay silent for %s, showing the last reading",
                util.fmtETA(status.age)), "bad"
        end
        -- The one line worth putting on the status bar is the level and how long
        -- it lasts, because that is the question that made the pilot type this.
        local level = math.floor(status.fraction * 100 + 0.5)
        if status.burn > 0 then
            return string.format("%d%%, burning %.1f mB/s, %s to reserve",
                level, status.burn, util.fmtETA(status.endurance)),
                level <= config.get("fuelCrit") and "bad"
                    or level <= config.get("fuelWarn") and "warn" or "good"
        end
        return string.format("%d%%, %d of %d mB, no flow",
            level, status.total, status.capacity),
            level <= config.get("fuelWarn") and "warn" or "good"
    end,
})

-- == TURBINES ================================================

define("turbines", {
    aliases = { "stress" },
    usage = "turbines",
    help = "The turbine relay: its link, its stress, and its lines.",
    run = function()
        ui.tab = 2
        turbine.ping()
        local status = turbine.status()
        if status.link == "nomodem" then
            return "no modem on this computer, so there is no turbine relay", "bad"
        elseif status.link == "waiting" then
            return "listening on " .. tostring(turbine.modem) .. ", relay has not spoken yet", "warn"
        elseif status.link == "stale" then
            return string.format("relay silent for %s, its turbines have stopped",
                util.fmtETA(status.age)), "bad"
        elseif status.overstressed then
            return "OVERSTRESSED, the kinetic network has stopped", "bad"
        elseif not status.stressOk then
            return string.format("%d line(s), no stressometer on the relay", #status.lines), "warn"
        end
        local level = math.floor((status.fraction or 0) * 100 + 0.5)
        return string.format("%d line(s), stress %d%%, %.0f su spare",
            #status.lines, level, status.headroom or 0),
            level >= config.get("stressCrit") and "bad"
                or level >= config.get("stressWarn") and "warn" or "good"
    end,
})

define("help", {
    aliases = { "?", "commands" },
    usage = "help [command]",
    help = "This.",
    run = function(args)
        if args[1] and handlers[args[1]] then
            local spec = handlers[args[1]]
            return spec.usage .. "  -  " .. spec.help, "hi"
        end
        return table.concat(order, " "), "hi"
    end,
})

define("exit", {
    aliases = { "quit" },
    usage = "exit",
    help = "Stop the propellers and leave.",
    run = function()
        cmd.quit = true
        return "shutting down", "warn"
    end,
})

-- == DISPATCH ================================================

function cmd.names()
    local out = {}
    for _, name in ipairs(order) do out[#out + 1] = name end
    return out
end

function cmd.run(text)
    local parts = {}
    for token in tostring(text):gmatch("%S+") do parts[#parts + 1] = token end
    if #parts == 0 then return nil end
    local name = table.remove(parts, 1):lower()
    local spec = handlers[name]
    if not spec then
        return "unknown command: " .. name .. "   try `help`", "bad"
    end
    log.infof("command: %s %s", name, table.concat(parts, " "))
    local ok, reply, kind = pcall(spec.run, parts)
    if not ok then
        log.error("command failed: " .. tostring(reply))
        return "failed: " .. tostring(reply), "bad"
    end
    return reply, kind
end

return cmd
