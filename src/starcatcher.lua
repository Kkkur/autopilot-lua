-- starcatcher.lua -- entry point.
--
-- A Create: Avionics autopilot for a ship with four propellers and a big one.
-- Or three propellers. Or eleven. Nothing about the vessel is written into the
-- program: it finds every rotation speed controller on its network, learns what
-- each one does from `cal`, learns how fast the ship flies from `vcal`, and
-- flies to whatever you point it at.
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
    -- cal is loaded with a stub ship: the parsing it is being tested on never
    -- touches the network, and nothing here is allowed to write to disk.
    local stubShip = { order = {}, readState = function() return nil end }
    local stubCal = { topSpeed = function() return nil end }
    local stubControl = {}
    local stubLog = setmetatable({}, { __index = function() return function() end end })
    local calModule = loadModule("cal", util, stubShip, config, stubLog)
    -- The fuel module never touches a peripheral until init is called, so it
    -- can be loaded and have its arithmetic checked on a computer with no modem.
    local fuelModule = loadModule("fuel", util, stubShip, stubCal, stubControl, config, stubLog)
    -- The real ship module, because what the turbine tests check is that a line
    -- on a radio lands in it the same way a line on a wire does. Nothing in
    -- ship.lua touches a peripheral until discover is called, and it is not.
    local shipModule = loadModule("ship", util)
    local turbineModule = loadModule("turbine", util, shipModule, config, stubLog)
    -- flight is pure the way util is, so it needs nothing stubbed at all. That
    -- is the whole point of it being its own module.
    local flightModule = loadModule("flight", util)
    local tests = loadModule("tests", util, config, calModule, fuelModule,
        turbineModule, shipModule, flightModule)
    return tests.run() and 0 or 1
end

if ARGS[1] == "--help" or ARGS[1] == "-h" then
    print("starcatcher -- Create: Avionics autopilot")
    print("")
    print("  cal          learn which way each propeller pushes")
    print("  vcal         measure how fast the ship flies per RPM")
    print("  save <name>  pin a waypoint where you are")
    print("  goto <name>  fly there")
    print("  fly x y z    fly to coordinates")
    print("  route a b c  fly a list of them in order")
    print("  stop         cut the propellers")
    print("  set k v      change any tuning value")
    print("  help         the full command list, in the program")
    print("")
    print("F1-F6 switch tabs. Type commands at the bottom at any time.")
    return 0
end

-- == WIRING ==================================================

if not fs.exists(DATA) then fs.makeDir(DATA) end

config.init(DATA)

local log = loadModule("log")
log.init(DATA, function() return config.get("logLevel") end)

local ship = loadModule("ship", util)
local cal = loadModule("cal", util, ship, config, log)
local control = loadModule("control", util, ship, cal, config, log)
local nav = loadModule("nav", util, control, log)
local fuel = loadModule("fuel", util, ship, cal, control, config, log)
local turbine = loadModule("turbine", util, ship, config, log)
local ui = loadModule("ui", util, ship, cal, control, nav, fuel, turbine, config, log)
local cmd = loadModule("cmd", util, ship, cal, control, nav, fuel, turbine, config, ui, log)

log.info("=== starcatcher starting ===")
log.infof("computer %d, screen %dx%d", os.getComputerID(), ui.size())

local found = ship.discover()
log.infof("network: %d propeller lines, %d bearings, altimeter %s",
    found, #ship.bearings, ship.altimeter and "yes" or "no")
-- Relay lines arrive a second later, over the radio, and adopt themselves into
-- `ship` when they do. So this count is the wired ones only, and the boot
-- warning below is about those.

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

-- An arrival pops the next leg of the route, if there is one.
control.onArrive = function(name)
    local state = ship.readState()
    nav.onArrive(name, state and state.position.y or nil)
end

-- == BOOT WARNINGS ===========================================
-- Said once, on the status line, rather than as a modal that has to be clicked
-- through before the screen appears.

if type(sublevel) ~= "table" then
    ui.say("no CC: Sable on this computer, so there is no pose to fly by", "bad")
    log.error("boot: sublevel global missing")
elseif found == 0 then
    ui.say("no rotation speed controllers on the network. Check the modems.", "bad")
    log.error("boot: no speed controllers found")
else
    local missing = cal.missingLines()
    if #missing == #ship.order then
        ui.say(string.format("%d lines, none calibrated. Type `cal` to start.", found), "warn")
    elseif #missing > 0 then
        ui.say(string.format("%d of %d lines not calibrated. Type `cal`.", #missing, found), "warn")
    elseif not cal.meta.velocityAt then
        ui.say("directions known, speeds unmeasured. Type `vcal` when you have room.", "warn")
    else
        ui.say(string.format("%d propeller lines ready.", found), "good")
    end
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
    fuel.listen, turbine.listen, turbine.heartbeat)

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

fuel.close()
turbine.close()
log.close()
print("propellers stopped.")
