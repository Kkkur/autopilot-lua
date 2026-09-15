-- turbine_relay.lua -- the turbine half of the ship, on its own computer.
--
-- Two Create rotation speed controllers and a stressometer sit on this
-- computer's network. It drives the controllers when the autopilot tells it to,
-- reports the stress the whole time, and stops the turbines the moment the
-- autopilot stops talking.
--
-- setTargetSpeed is a mainThread call and costs a server tick each, which is
-- the reason this is worth being a separate computer: those ticks are spent
-- here instead of inside the flight loop. The pattern is the one from
-- src/old/autopilot.lua, which is where the flush below comes from.
--
--   turbine_relay          run it
--   turbine_relay --once   print one reading and exit, for checking the wiring
--   turbine_relay --spin N drive both lines at N rpm for ten seconds, by hand
--
-- Everything it writes lives in turbinerelay/logs/ next to this file.

local ARGS = { ... }

local ROOT = fs.getDir(shell and shell.getRunningProgram() or "turbine_relay.lua")
local DATA = "turbinerelay"

local function loadModule(name, ...)
    local path = fs.combine(fs.combine(ROOT, "sc"), name .. ".lua")
    if not fs.exists(path) then
        error("missing module: " .. path .. "\nCopy the sc folder, not just the one file.", 0)
    end
    local handle = fs.open(path, "r")
    local source = handle.readAll()
    handle.close()
    local chunk, err = load(source, "@" .. name .. ".lua", "t", _ENV)
    if not chunk then error("could not load " .. name .. ": " .. tostring(err), 0) end
    return chunk(...)
end

-- == SETTINGS ================================================

local PROTOCOL    = "starcatcher-turbine"  -- must match the flight computer
local HOSTNAME    = "turbines"
local SEND_EVERY  = 1.0     -- seconds between stress broadcasts
local MAX_RPM     = 256     -- what a speed controller will take, either way
local DEADMAN     = 3.0     -- seconds without a command before the turbines stop
local MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local log = loadModule("log")

-- == THE NETWORK =============================================

local lines = {}        -- name -> wrapped controller
local order = {}        -- names, sorted, so line 1 is always line 1
local stressometer = nil
local modemSide = nil

local function shortName(name)
    return "#" .. (name:match("_(%d+)$") or name)
end

-- Matching on the methods rather than on the type string, the way the old
-- autopilot did, keeps this working for peripherals that report more than one
-- type and for whatever Avionics renames next.
local function findPeripherals()
    lines, order, stressometer = {}, {}, nil
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.setTargetSpeed and p.getTargetSpeed then
            lines[name] = p
            order[#order + 1] = name
        elseif p and p.getStress and p.getStressCapacity and not stressometer then
            stressometer = { name = name, p = p }
        end
    end
    table.sort(order)
    return #order
end

-- == DRIVING =================================================

local demand = {}       -- name -> rpm the autopilot asked for
local sent = {}         -- name -> rpm actually written, so nothing is resent
local lastCommand = nil -- os.clock() of the last order from the flight computer

-- setTargetSpeed yields a server tick each, so only what changed is written and
-- the writes go out together rather than one after another.
local function flush()
    local calls = {}
    for _, name in ipairs(order) do
        local rpm = demand[name] or 0
        if sent[name] ~= rpm then
            sent[name] = rpm
            calls[#calls + 1] = function() lines[name].setTargetSpeed(rpm) end
        end
    end
    if #calls > 0 then parallel.waitForAll(table.unpack(calls)) end
end

local function allStop()
    for _, name in ipairs(order) do demand[name] = 0 end
    flush()
end

local function clampRpm(value)
    local rpm = tonumber(value) or 0
    if rpm ~= rpm then return 0 end          -- a NaN off the wire is a zero here
    if rpm > MAX_RPM then return MAX_RPM end
    if rpm < -MAX_RPM then return -MAX_RPM end
    return math.floor(rpm + 0.5)
end

-- A command can name its lines or number them. Naming is what the flight
-- computer does once it has seen a reading; numbering is what a human types.
local function applyCommand(message)
    local wanted = message.rpm
    if type(wanted) ~= "table" then return false, "no rpm table" end
    local touched = 0
    for key, value in pairs(wanted) do
        local name = nil
        if type(key) == "number" then name = order[key]
        elseif lines[key] then name = key
        else
            -- "#3" or "3", which is what the short name on the screen says.
            for _, candidate in ipairs(order) do
                if shortName(candidate) == key or shortName(candidate) == "#" .. key then
                    name = candidate
                end
            end
        end
        if name then
            demand[name] = clampRpm(value)
            touched = touched + 1
        end
    end
    if touched == 0 then return false, "no line matched" end
    flush()
    return true
end

-- == STRESS ==================================================

local stress = { value = 0, capacity = 0, fraction = 0, overstressed = false, ok = false }

local function readStress()
    if not stressometer then
        stress.ok = false
        return
    end
    local okValue, value = pcall(stressometer.p.getStress)
    local okCap, capacity = pcall(stressometer.p.getStressCapacity)
    if not okValue or not okCap then
        stress.ok, stress.err = false, tostring(value)
        return
    end
    stress.ok, stress.err = true, nil
    stress.value = value or 0
    stress.capacity = capacity or 0
    -- Capacity is what the network can supply and stress is what is being drawn,
    -- so the fraction is how close the whole kinetic network is to giving up.
    -- A capacity of zero is a network with nothing running, not a division.
    stress.fraction = (stress.capacity or 0) > 0 and (stress.value / stress.capacity) or 0
end

-- == THE MESSAGE =============================================

local function buildMessage()
    local list = {}
    for index, name in ipairs(order) do
        local actual = nil
        local ok, value = pcall(lines[name].getTargetSpeed)
        if ok then actual = value end
        list[index] = {
            name = name,
            short = shortName(name),
            demand = demand[name] or 0,
            actual = actual,
        }
    end
    return {
        v = 1,
        id = os.getComputerID(),
        label = os.getComputerLabel(),
        clock = os.clock(),
        lines = list,
        maxRpm = MAX_RPM,
        stress = stress.ok and stress.value or nil,
        stressCapacity = stress.ok and stress.capacity or nil,
        stressFraction = stress.ok and stress.fraction or nil,
        overstressed = stress.overstressed,
        stressOk = stress.ok,
        stressError = stress.err,
        deadman = DEADMAN,
        commandAge = lastCommand and (os.clock() - lastCommand) or nil,
    }
end

local function broadcast()
    if modemSide then rednet.broadcast(buildMessage(), PROTOCOL) end
end

-- == SCREEN ==================================================

local function drawBar(x, y, width, fraction, colour)
    local filled = math.max(0, math.min(width, math.floor((fraction or 0) * width + 0.5)))
    term.setCursorPos(x, y)
    term.setBackgroundColour(colour)
    term.write(string.rep(" ", filled))
    term.setBackgroundColour(colours.grey)
    term.write(string.rep(" ", width - filled))
    term.setBackgroundColour(colours.black)
end

-- Zero in the middle, filling left for reverse and right for forward, because
-- that is the shape a turbine demand actually has on a ship that tank turns.
local function drawSignedBar(x, y, width, rpm)
    local half = math.floor(width / 2)
    local cells = math.floor(math.abs(rpm) / MAX_RPM * half + 0.5)
    term.setCursorPos(x, y)
    term.setBackgroundColour(colours.grey)
    term.write(string.rep(" ", width))
    if cells > 0 then
        term.setBackgroundColour(rpm < 0 and colours.orange or colours.lime)
        term.setCursorPos(rpm < 0 and (x + half - cells) or (x + half + 1), y)
        term.write(string.rep(" ", cells))
    end
    term.setBackgroundColour(colours.black)
end

local function stressColour()
    if stress.overstressed then return colours.red end
    if stress.fraction >= 0.9 then return colours.red end
    if stress.fraction >= 0.7 then return colours.orange end
    return colours.lime
end

local function draw()
    local W, H = term.getSize()
    term.setBackgroundColour(colours.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setTextColour(colours.black)
    term.setBackgroundColour(colours.cyan)
    term.write(string.rep(" ", W))
    term.setCursorPos(2, 1)
    term.write("TURBINES  #" .. os.getComputerID())
    local stamp = log.timestamp()
    term.setCursorPos(math.max(1, W - #stamp), 1)
    term.write(stamp)
    term.setBackgroundColour(colours.black)

    local y = 3
    term.setTextColour(stressColour())
    term.setCursorPos(2, y)
    if not stress.ok then
        term.write("no stressometer")
    elseif stress.overstressed then
        term.write(string.format("OVERSTRESSED  %.0f / %.0f su", stress.value, stress.capacity))
    else
        term.write(string.format("stress %.0f / %.0f su  %d%%",
            stress.value, stress.capacity, math.floor(stress.fraction * 100 + 0.5)))
    end
    y = y + 1
    drawBar(2, y, W - 2, stress.fraction, stressColour())
    y = y + 2

    for _, name in ipairs(order) do
        if y + 1 > H - 3 then break end
        local rpm = demand[name] or 0
        term.setTextColour(rpm ~= 0 and colours.white or colours.lightGrey)
        term.setCursorPos(2, y)
        term.write(string.format("%-4s %+5d rpm", shortName(name), rpm))
        drawSignedBar(math.min(W - 18, 18), y, 17, rpm)
        y = y + 1
    end

    y = math.min(y + 1, H - 2)
    term.setTextColour(colours.lightGrey)
    term.setCursorPos(2, y)
    local age = lastCommand and (os.clock() - lastCommand) or nil
    if not modemSide then
        term.setTextColour(colours.red)
        term.write("NO MODEM - nothing can command these")
    elseif not age then
        term.write("waiting for the flight computer")
    elseif age > DEADMAN then
        term.setTextColour(colours.orange)
        term.write(string.format("no orders for %.0fs, turbines stopped", age))
    else
        term.write(string.format("flying, last order %.1fs ago", age))
    end

    term.setCursorPos(2, H)
    term.setTextColour(colours.grey)
    term.write("Ctrl+T stops the turbines and quits")
end

-- == BOOT ====================================================

if not fs.exists(DATA) then fs.makeDir(DATA) end
log.init(DATA, function() return 2 end)
log.info("=== turbine relay starting ===")

for _, side in ipairs(MODEM_SIDES) do
    if peripheral.getType(side) == "modem" then
        local wrapped = peripheral.wrap(side)
        if wrapped.isWireless and wrapped.isWireless() then modemSide = side; break end
        modemSide = modemSide or side
    end
end

if modemSide then
    rednet.open(modemSide)
    rednet.host(PROTOCOL, HOSTNAME)
    log.infof("rednet open on %s, id %d, protocol %s", modemSide, os.getComputerID(), PROTOCOL)
else
    log.error("no modem on any side. nothing can command these turbines.")
end

local found = findPeripherals()
log.infof("found %d speed controller(s), stressometer %s", found,
    stressometer and stressometer.name or "none")
for index, name in ipairs(order) do
    log.infof("  line %d  %s  %s", index, shortName(name), name)
end

if found == 0 then
    log.error("no rotation speed controllers on the network")
    print("No rotation speed controller found. Attached:")
    for _, name in ipairs(peripheral.getNames()) do
        print("  " .. name .. "  " .. peripheral.getType(name))
    end
    print("")
    print("Check the modems on the controllers themselves.")
    log.close()
    return
end

allStop()
readStress()

if ARGS[1] == "--once" then
    print(textutils.serialise(buildMessage()))
    log.close()
    return
end

-- Spinning them by hand, for the check where you walk out and look at them,
-- which no amount of telemetry replaces.
if ARGS[1] == "--spin" then
    local rpm = clampRpm(ARGS[2])
    print(("driving both lines at %d rpm for 10s"):format(rpm))
    for _, name in ipairs(order) do demand[name] = rpm end
    flush()
    sleep(10)
    allStop()
    log.infof("manual spin at %d rpm finished", rpm)
    log.close()
    return
end

-- == LOOPS ===================================================

-- Orders arrive over a radio. A radio goes quiet when a chunk unloads, when the
-- flight computer crashes, or when someone breaks it, and turbines left running
-- at the last thing they were told fly the ship into terrain. So the last order
-- has a shelf life, and when it expires the turbines stop.
local function deadmanLoop()
    while true do
        if lastCommand and (os.clock() - lastCommand) > DEADMAN then
            local running = false
            for _, name in ipairs(order) do
                if (demand[name] or 0) ~= 0 then running = true end
            end
            if running then
                log.warnf("no orders for %.1fs, stopping the turbines", os.clock() - lastCommand)
                allStop()
            end
        end
        sleep(0.5)
    end
end

local function commandLoop()
    while true do
        local id, message = rednet.receive(PROTOCOL)
        if type(message) == "table" then
            if message.cmd == "set" then
                lastCommand = os.clock()
                local ok, err = applyCommand(message)
                if not ok then log.warnf("bad set from %d: %s", id, tostring(err)) end
            elseif message.cmd == "stop" then
                lastCommand = os.clock()
                allStop()
                log.infof("stop from %d", id)
            elseif message.cmd == "ping" then
                rednet.send(id, buildMessage(), PROTOCOL)
            end
        end
    end
end

local function reportLoop()
    while true do
        readStress()
        broadcast()
        sleep(SEND_EVERY)
    end
end

-- The stressometer raises events rather than making us poll for the moment that
-- matters. Overstressed is worth saying the instant it happens, not up to a
-- second later on the next broadcast.
local function eventLoop()
    while true do
        local event = os.pullEvent()
        if event == "overstressed" then
            stress.overstressed = true
            readStress()
            broadcast()
            log.error("OVERSTRESSED")
        elseif event == "stress_change" then
            local was = stress.overstressed
            readStress()
            -- Nothing reports the recovery, so it is inferred: stress back under
            -- what the network can supply means the network is turning again.
            if was and stress.fraction < 1.0 then
                stress.overstressed = false
                log.info("overstress cleared")
                broadcast()
            end
        end
    end
end

local function screenLoop()
    while true do
        local ok, err = pcall(draw)
        if not ok then log.error("draw: " .. tostring(err)) end
        sleep(0.5)
    end
end

local function idleLoop()
    while true do sleep(60) end
end

log.info("turbine relay running")

local ok, err = pcall(parallel.waitForAny, screenLoop, eventLoop, deadmanLoop,
    modemSide and reportLoop or idleLoop,
    modemSide and commandLoop or idleLoop)

-- Ctrl+T raises Terminated again on the next yield, and setTargetSpeed yields,
-- so the stop has to survive being interrupted or the turbines keep spinning
-- with nobody driving them.
for _ = 1, 3 do
    if pcall(allStop) then break end
end

term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.clear()
term.setCursorPos(1, 1)
term.setCursorBlink(true)

if not ok and err ~= "Terminated" then
    local path = log.crash(err, {
        "lines : " .. #order,
        "modem : " .. tostring(modemSide),
        "stress: " .. tostring(stress.value) .. " / " .. tostring(stress.capacity),
    })
    log.error("crash: " .. tostring(err))
    printError("turbine relay crashed: " .. tostring(err))
    if path then print("written to " .. path) end
end

if modemSide then
    rednet.unhost(PROTOCOL)
    rednet.close(modemSide)
end
log.close()
print("turbines stopped.")
