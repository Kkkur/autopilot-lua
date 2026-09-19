-- starcatcher.lua -- entry point.
--
-- A Create: Avionics autopilot for a tank turn hull: propellers all pointing
-- one way, steering on the difference between its two sides, floating on a
-- balloon. Nothing about the vessel is written into the program. It finds every
-- rotation speed controller on its network and on its relays, and `cal`
-- measures what each one is worth.
--
--   starcatcher            fly
--   starcatcher --test     check the maths, needs no ship and no peripherals
--   starcatcher --help     the short version of the README
--
-- Everything is saved under starcatcher/ next to wherever this is run from.

local ARGS = { ... }

-- == MODULE LOADING ==========================================
-- Modules take their dependencies as arguments rather than reaching for
-- globals, which is what lets the test run build a subset of them on a
-- computer with no ship attached.

local ROOT = fs.getDir(shell and shell.getRunningProgram() or "starcatcher.lua")
local MODULES = fs.combine(ROOT, "sc")

local function loadModule(name, ...)
    local path = fs.combine(MODULES, name .. ".lua")
    if not fs.exists(path) then
        error("missing module: " .. path .. "\nCopy the whole folder, not just the one file.", 0)
    end
    local handle = fs.open(path, "r")
    local source = handle.readAll()
    handle.close()
    local chunk, err = load(source, "@" .. name .. ".lua", "t", _ENV)
    if not chunk then error("could not load " .. name .. ": " .. tostring(err), 0) end
    return chunk(...)
end

local DATA = "starcatcher"

local util = loadModule("util")
local config = loadModule("config")

-- == --test ==================================================

if ARGS[1] == "--test" or ARGS[1] == "-t" then
    local stubShip = { order = {}, remoteLines = {}, readState = function() return nil end }
    local stubCal = { topForward = function() return nil end }
    local stubControl = {}
    local stubLog = setmetatable({}, { __index = function() return function() end end })
    -- flight is pure the way util is, so it needs nothing stubbed at all. That
    -- is the whole point of it being its own module. cal reads it, for the
    -- mixer the ladders are measured through, so it is built first.
    local flightModule = loadModule("flight", util)
    -- cal is loaded with a stub ship and no relay: the parsing it is being
    -- tested on never touches the network, and nothing here writes to disk.
    local stubTurbine = { hasBalloon = function() return false end }
    -- preflight and popup are pure in the same way flight is, so both load with
    -- nothing attached and both are checked against stub tables. popup comes
    -- before cal because the wizard asks its questions with it.
    local preflightModule = loadModule("preflight", util, flightModule)
    local popupModule = loadModule("popup", util)
    -- cal is loaded with a stub ship and no relay: the parsing it is being
    -- tested on never touches the network, and nothing here writes to disk.
    local calModule = loadModule("cal", util, stubShip, config, stubLog,
        flightModule, stubTurbine, popupModule)
    -- The fuel module never touches a peripheral until init is called, so it
    -- can be loaded and have its arithmetic checked on a computer with no modem.
    -- link is loaded without init, so it has no file and no passcode: exactly
    -- the state an unpaired computer is in, which is the half of it worth
    -- checking on a computer with no modem.
    local linkModule = loadModule("link")
    local fuelModule = loadModule("fuel", util, stubShip, stubCal, stubControl, config,
        stubLog, linkModule)
    -- The real ship module, because what the turbine tests check is that a line
    -- on a radio lands in it the same way a line on a wire does. Nothing in
    -- ship.lua touches a peripheral until discover is called, and it is not.
    local shipModule = loadModule("ship", util, config)
    local turbineModule = loadModule("turbine", util, shipModule, config, stubLog, linkModule)
    local tests = loadModule("tests", util, config, calModule, fuelModule,
        turbineModule, shipModule, flightModule, preflightModule, popupModule, linkModule, stubShip)
    return tests.run() and 0 or 1
end

if ARGS[1] == "--help" or ARGS[1] == "-h" then
    print("starcatcher -- Create: Avionics autopilot")
    print("")
    print("  cal          measure the ship: sides, balloon, yaw, align, forward, cruise, brake")
    print("  cal yaw      run one stage of it again")
    print("  save <name>  pin a waypoint where you are")
    print("  goto <name>  fly there")
    print("  fly x y z    fly to coordinates")
    print("  route a b c  fly a list of them in order")
    print("  stop         cut the propellers")
    print("  check        ask whether the ship is fit to fly, and why not")
    print("  manual       fly by hand, or press IJKL on the MANUAL tab")
    print("  set k v      change any tuning value")
    print("  help         the full command list, in the program")
    print("")
    print("F1-F8 switch tabs. Type commands at the bottom at any time.")
    return 0
end

-- == WIRING ==================================================

if not fs.exists(DATA) then fs.makeDir(DATA) end

config.init(DATA)

local log = loadModule("log")
log.init(DATA, function() return config.get("logLevel") end)

local telemetry = loadModule("telemetry", util, config)
telemetry.init(DATA)

local ship = loadModule("ship", util, config)
local flight = loadModule("flight", util)
-- The passcode both protocols carry. It is loaded before either link is opened,
-- because a link that opened first would spend its first second obeying
-- anything on the air.
local link = loadModule("link")
link.init(DATA)
-- turbine before cal and before control: the balloon is a relay, and both the
-- wizard that measures it and the loop that drives it need the link to exist
-- before they are built.
local turbine = loadModule("turbine", util, ship, config, log, link)
local popup = loadModule("popup", util)
local cal = loadModule("cal", util, ship, config, log, flight, turbine, popup)
local control = loadModule("control", util, ship, cal, config, log, flight, turbine,
    telemetry)
local nav = loadModule("nav", util, control, log)
local fuel = loadModule("fuel", util, ship, cal, control, config, log, link)
local preflight = loadModule("preflight", util, flight)
local ui = loadModule("ui", util, ship, cal, control, nav, fuel, turbine, config, log,
    telemetry, flight, popup, link)
local cmd = loadModule("cmd", util, ship, cal, control, nav, fuel, turbine, config, ui, log,
    preflight, popup, telemetry, link)

log.info("=== starcatcher starting ===")
if link.pass then
    log.info("paired: every message this ship sends carries its passcode")
else
    log.warn("no passcode set. Any ship in range on this protocol is obeyed.")
end
telemetry.event("boot", "starcatcher starting", "computer " .. os.getComputerID())
log.infof("computer %d, screen %dx%d", os.getComputerID(), ui.size())

local wired = ship.discover()
log.infof("network: %d wired propeller lines, %d bearings, altimeter %s",
    wired, #ship.bearings, ship.altimeter and "yes" or "no")
-- Relay lines arrive a second later, over the radio, and adopt themselves into
-- `ship` when they do, so this count is the wired ones only. On this ship that
-- number is zero and always will be: computer 0 carries a modem and owns
-- nothing that spins. A boot warning built on it would fire every single time.

cal.init(DATA)
nav.init(DATA)
control.init()

-- Both relays are optional. A ship with no modem, or with the relay computers
-- switched off, flies exactly as it did before on whatever lines are wired to
-- this computer: the panels say so and nothing else changes.
fuel.init()
turbine.init(fuel.modem)

ui.setCompletions(cmd.names())
ui.onCommand = function(text) return cmd.run(text) end

-- Gains live in config and can be changed from the TUNE tab mid-flight, so the
-- controller is told when one moves rather than re-reading them every tick.
config.onChange = function(key)
    control.refreshGains()
    if key then log.infof("set %s = %s", key, config.format(key)) end
end

-- What the control loop does when something goes wrong in the air. The ship has
-- already done the safe thing by the time this runs: safeHold puts thrust at
-- zero and freezes the balloon, and this only asks what to do next. That order
-- matters, because a modal that had to be answered before the ship acted would
-- be a modal the ship waited behind.
control.onAlarm = function(kind, what, detail)
    if kind == "part" then
        ui.raise(popup.partLost(what, detail), function(action)
            if action == "resume" then
                control.clearSafeHold()
                control.start()
            elseif action == "stop" then
                control.clearSafeHold()
                control.stop("STOPPED AFTER A PART WAS LOST")
                nav.clearRoute()
            end
        end)
    elseif kind == "overstress" then
        ui.raise(popup.overstressed(what), function(action)
            if action == "hold" then
                control.safeHold("OVERSTRESSED")
            elseif action == "ease" then
                config.set("cruiseMaxRpm", math.floor(config.get("cruiseMaxRpm") / 2))
                ui.say("cruiseMaxRpm eased to " .. config.format("cruiseMaxRpm"), "warn")
            end
        end)
    elseif kind == "pitch" then
        ui.raise(popup.pitch(what, config.get("pitchLimit")), function(action)
            if action == "hold" then
                control.safeHold("NOSED OVER")
            elseif action == "ease" then
                config.set("brakeSlew", math.max(1, math.floor(config.get("brakeSlew") / 2)))
                ui.say("brakeSlew eased to " .. config.format("brakeSlew"), "warn")
            end
        end)
    end
end

-- An arrival pops the next leg of the route, if there is one.
control.onArrive = function(name)
    local state = ship.readState()
    nav.onArrive(name, state and state.position.y or nil)
end

-- == BOOT WARNINGS ===========================================
-- Said once, on the status line, rather than as a modal that has to be clicked
-- through before the screen appears.

-- Counted across the relays as well as the wire, and counted late, because every
-- propeller on this ship arrives about a second after boot. Reporting on the
-- wired count alone is what made this warning fire on every single start.
local function propellerReport()
    local total = #ship.order
    if type(sublevel) ~= "table" then
        ui.say("no CC: Sable on this computer, so there is no pose to fly by", "bad")
        log.error("boot: sublevel global missing")
        return
    end
    if total == 0 then
        ui.say("no propellers yet, wired or on a relay. Check the relay computers.", "bad")
        log.error("boot: no speed controllers on the wire or the radio")
        return
    end

    local uncalibrated = 0
    for _, name in ipairs(ship.order) do
        if not cal.sides[name] then uncalibrated = uncalibrated + 1 end
    end

    if uncalibrated == total then
        ui.say(string.format("%d propellers, none calibrated. Type `cal` to start.", total), "warn")
    elseif uncalibrated > 0 then
        ui.say(string.format("%d of %d propellers not calibrated. Type `cal`.",
            uncalibrated, total), "warn")
    elseif not cal.fwdCurve then
        ui.say("sides known, speeds unmeasured. Run `cal` where there is room.", "warn")
    elseif not turbine.hasBalloon() then
        ui.say("no relay is holding the balloon. Nothing here controls lift.", "bad")
    else
        ui.say(string.format("%d propellers ready.", total), "good")
    end
end

-- Said once the relays have had their second to speak up. It then sleeps rather
-- than returning, because this runs under waitForAny and a task that finishes
-- there takes the whole program down with it.
local function bootReport()
    sleep(1.5)
    pcall(propellerReport)
    while true do sleep(60) end
end

-- == LOOPS ===================================================
--
-- Three of them. The control loop owns the propellers, the screen loop owns the
-- window, and the input loop owns the keyboard. Only one of the three ever
-- blocks, and the parked handshake is what keeps the control loop out of a
-- calibration run: the wizard commands one propeller at a time and a control
-- tick landing in the middle of that would fight it.

local parked = false

ui.waitParked = function()
    local deadline = os.clock() + 2
    while not parked and os.clock() < deadline do sleep(0.05) end
end

local function controlLoop()
    while true do
        if ui.busy then
            parked = true
            sleep(0.1)
        else
            parked = false
            local ok, err = pcall(control.tick)
            if not ok then
                log.error("control tick: " .. tostring(err))
                pcall(ship.allStop)
                sleep(0.5)
            end
            sleep(config.get("tick"))
        end
    end
end

-- Its own loop, at its own rate. Nothing it reads touches a peripheral: the
-- pose is the one the control loop already read and both relay statuses come
-- off what last arrived on the radio, so this costs no server tick and cannot
-- slow the propellers down by running.
local function telemetryLoop()
    while true do
        if config.get("telemetry") then
            local ok, err = pcall(telemetry.sample, control.snapshot(), fuel.status(),
                turbine.status(), ui.popup and ui.popup.title or nil)
            if not ok then log.error("telemetry: " .. tostring(err)) end
        end
        sleep(1 / math.max(0.1, config.get("telemetryHz")))
    end
end

local function screenLoop()
    while true do
        if not ui.busy then
            local ok, err = pcall(ui.draw)
            if not ok then log.error("draw: " .. tostring(err)) end
        end
        sleep(config.get("uiTick"))
    end
end

local function inputLoop()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "char" then
            ui.handleChar(p1)
        elseif event == "paste" then
            ui.handleChar(p1)
        elseif event == "key" then
            ui.handleKey(p1)
        elseif event == "mouse_click" then
            ui.handleClick(p2, p3)
        elseif event == "mouse_scroll" then
            ui.handleKey(p1 < 0 and keys.pageUp or keys.pageDown)
        elseif event == "term_resize" or event == "monitor_resize" then
            ui.resize()
        end
        if cmd.quit then return end
        -- repaint, not draw: the answer to a keypress has to be on the screen
        -- before the next one is typed, and re-reading the instruments here
        -- would spend four server ticks doing it.
        if not ui.busy then pcall(ui.repaint) end
    end
end

log.info("boot complete")
ui.draw()

local ok, err = pcall(parallel.waitForAny, controlLoop, screenLoop, inputLoop,
    fuel.listen, turbine.listen, turbine.heartbeat, bootReport, telemetryLoop)

-- setTargetSpeed yields, and a yield after Ctrl+T raises Terminated again, so
-- the stop has to survive being interrupted or the propellers keep spinning
-- with nobody flying them.
for _ = 1, 3 do
    if pcall(ship.allStop) then break end
end
pcall(turbine.stop)

term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.clear()
term.setCursorPos(1, 1)
term.setCursorBlink(true)

if not ok and err ~= "Terminated" then
    local path = log.crash(err, {
        "running: " .. tostring(control.running),
        "phase  : " .. tostring(control.phase),
        "target : " .. tostring(control.targetName),
    })
    log.error("crash: " .. tostring(err))
    printError("starcatcher crashed: " .. tostring(err))
    if path then print("written to " .. path) end
end

telemetry.event("boot", "shutting down", tostring(control.phase))
telemetry.close()
fuel.close()
turbine.close()
log.close()
print("propellers stopped.")
