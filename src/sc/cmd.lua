-- cmd.lua -- the command line.
--
-- Every command returns a line of text and a colour hint, and never touches the
-- screen itself. That makes the whole command set testable, and it is why the
-- same dispatcher can later be pointed at a modem without any of it changing.

local util, ship, cal, control, nav, fuel, turbine, config, ui, log = ...

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
            -- Two numbers is the old starcatcher shape: X and Z, any height.
            z, y = tonumber(args[3]), nil
            if not z then return "usage: save <name> [x y z]", "warn" end
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
        ui.tab = 3
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
        local ok, err = nav.goTo(args[1], pos and pos.y or nil)
        if not ok then return tostring(err), "bad" end
        ui.tab = 1
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
        local ok, err = nav.goToCoords(x, y, z)
        if not ok then return tostring(err), "bad" end
        ui.tab = 1
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
        local ok, err = nav.setRoute(args, pos and pos.y or nil)
        if not ok then return tostring(err), "bad" end
        ui.tab = 1
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
        local ok, err = control.start()
        return ok and "engaged" or tostring(err), ok and "good" or "warn"
    end,
})

define("manual", {
    aliases = { "man" },
    usage = "manual <side> <up> <fwd>",
    help = "Fly by hand: a body-frame speed in m/s. All zeros gives it back.",
    run = function(args)
        local sx = tonumber(args[1]) or 0
        local sy = tonumber(args[2]) or 0
        local sz = tonumber(args[3]) or 0
        control.setManual(sx, sy, sz)
        if not control.manual then return "manual off", "warn" end
        ui.tab = 1
        return string.format("manual %+.1f %+.1f %+.1f m/s", sx, sy, sz), "warn"
    end,
})

-- == CALIBRATION =============================================

define("cal", {
    aliases = { "calibrate" },
    usage = "cal",
    help = "Learn which way each propeller pushes. Run this first, on a new ship.",
    run = function()
        control.stop("CALIBRATING")
        ui.runWizard("DIRECTION CALIBRATION", function(ctx)
            cal.runDirection(ctx)
            ctx.clearFields()
            ctx.note("done. Press Enter to go back.", "good")
            ctx.waitEnter()
        end)
        return "direction calibration finished", "good"
    end,
})

define("vcal", {
    aliases = { "velcal", "speedtest" },
    usage = "vcal [x|y|z]",
    help = "Measure how fast the ship flies at each RPM step, and save the curve.",
    run = function(args)
        local axis = args[1] and args[1]:lower() or nil
        if axis and not util.AXIS_INDEX[axis] then return "axis is x, y or z", "warn" end
        if #cal.missingLines() == #ship.order then
            return "nothing is calibrated yet, run `cal` first", "bad"
        end
        control.stop("CALIBRATING")
        ui.runWizard("VELOCITY CALIBRATION", function(ctx)
            cal.runVelocity(ctx, axis)
            ctx.clearFields()
            ctx.note("done. Press Enter to go back.", "good")
            ctx.waitEnter()
        end)
        ui.tab = 4
        return "velocity calibration finished", "good"
    end,
})

define("curves", {
    usage = "curves",
    help = "Show the measured speed curves.",
    run = function()
        ui.tab = 4
        local parts = {}
        for _, entry in ipairs(cal.summary()) do
            parts[#parts + 1] = string.format("%s %s", entry.axis:upper(),
                entry.top and string.format("%.1f m/s", entry.top) or "-")
        end
        return table.concat(parts, "  "), "hi"
    end,
})

define("forget", {
    usage = "forget curves|dirs|all",
    help = "Throw away calibration data so it can be measured again.",
    run = function(args)
        local what = (args[1] or ""):lower()
        if what == "curves" then
            cal.curves = {}
            cal.meta.velocityAt = nil
        elseif what == "dirs" or what == "directions" then
            cal.axes = {}
            cal.meta.directionAt = nil
        elseif what == "all" then
            cal.curves, cal.axes, cal.meta = {}, {}, {}
        else
            return "forget curves, dirs or all", "warn"
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
