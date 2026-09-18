-- turbine_relay.lua -- a propeller half of the ship, on its own computer.
--
-- Create rotation speed controllers and a stressometer sit on this computer's
-- network. It drives the controllers when the autopilot tells it to, reports the
-- stress the whole time, and stops the turbines the moment the autopilot stops
-- talking.
--
-- One program, more than one computer. The ship has two of these: the turbine
-- relay holding the four turbines and the stressometer, and the cruise relay
-- holding the main propeller, the redstone relay that drives the balloon and
-- the two steam vents that fill it. They run the same file, because two
-- programs for one job drift apart, and which of the two a computer is comes
-- from what it finds on its own network rather than from anything typed.
--
-- The balloon is two vents and the strength goes to both. The redstone relay
-- is written on every side for that reason: which sides the vents are wired to
-- is a fact about how the ship was built, and this file is not allowed to know
-- those. It reports what the vents say about themselves as well, because until
-- they could be read the only thing known about the balloon up on the flight
-- computer was the number this relay had written to a wire.
--
-- Two computers means two things this program has to get right that a single
-- relay never had to:
--
--   Peripheral names are per network, not global, so both relays will happily
--   offer a Create_RotationSpeedController_0. Every line this one advertises is
--   therefore named "<this computer's id>:<peripheral name>", and a command
--   addressed to another relay's id is not ours to obey.
--
--   The deadman is not the same for everything. See DEADMAN below.
--
-- setTargetSpeed is a mainThread call and costs a server tick each, which is
-- the reason this is worth being a separate computer: those ticks are spent
-- here instead of inside the flight loop. The pattern is the one from
-- src/old/autopilot.lua, which is where the flush below comes from.
--
--   turbine_relay            run it
--   turbine_relay --once     print one reading and exit, for checking the wiring
--   turbine_relay --spin N   drive every line at N rpm for ten seconds, by hand
--   turbine_relay --balloon N  hold the balloon at strength N for ten seconds
--   turbine_relay --passcode W set the passcode this relay answers to
--
-- Everything it writes lives in turbinerelay/ next to this file.

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

-- Two computers run this program, so the hostname cannot be a constant. CC's
-- rednet.host looks the name up on the network first and errors with "Hostname
-- in use" when somebody already answers to it, which killed whichever of the
-- two relays booted second, at its modem, for a reason that had nothing to do
-- with turbines. It is qualified by computer id instead, the way every line
-- name on this ship is.
local HOSTNAME    = "turbines" .. tostring(os.getComputerID())
local SEND_EVERY  = 1.0     -- seconds between stress broadcasts
local MAX_RPM     = 256     -- what a speed controller will take, either way
local MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- The deadman, and the one place in this program where two things that look
-- like each other are deliberately opposite. Do not tidy them into agreement.
--
-- A radio goes quiet when a chunk unloads, when the flight computer crashes, or
-- when someone breaks it. Turbines left running at the last thing they were told
-- fly the ship into terrain, so thrust expires. A balloon left at the last thing
-- it was told is the only reason the ship is still in the air, so lift does not.
--
-- Zeroing the balloon on silence would mean a chunk unload drops the ship out of
-- the sky, which is the exact failure the whole fuel and relay design exists to
-- avoid.
local DEADMAN     = 3.0     -- seconds without a command before thrust goes to 0
local BALLOON_HOLDS_ON_SILENCE = true

-- Every side of the redstone relay, together, because this ship has two steam
-- vents and they are not on the same side of it. One side was the whole of the
-- bug: the vent that was wired to it lifted and the other one sat cold, so the
-- balloon answered a strength of 15 with half the gas it should have.
--
-- Every side rather than the two that happen to be used, since which sides
-- they are is a fact about how the ship was built and this file is not allowed
-- to know those. A side with nothing on it costs a redstone update nobody
-- reads.
local BALLOON_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local BALLOON_FILE = "balloon.cfg"

local log = loadModule("log")
-- The passcode this relay answers to. An engine driven over a radio is the one
-- thing on this ship where a stray message has a physical consequence, which is
-- why both halves of both protocols carry it.
local link = loadModule("link")

-- == THE NETWORK =============================================

local lines = {}        -- name -> wrapped controller
local order = {}        -- names, sorted, so line 1 is always line 1
local stressometer = nil
local balloonRelay = nil
local vents = {}        -- every steam vent, separately, in peripheral name order
local modemSide = nil

local ID = os.getComputerID()

-- Every line this relay advertises carries the id of the computer holding it.
-- Two relays on one ship will both offer a Create_RotationSpeedController_0, and
-- a flight computer that keyed on the bare name would file them as one propeller
-- and fly on half a ship.
local function qualify(name)
    return ID .. ":" .. name
end

-- "#2.0" reads as line 0 on relay 2, which is what a pilot standing in front of
-- two relays needs the screen to say.
local function shortName(name)
    return "#" .. ID .. "." .. (name:match("_(%d+)$") or name)
end

-- Matching on the methods rather than on the type string, the way the old
-- autopilot did, keeps this working for peripherals that report more than one
-- type and for whatever Avionics renames next.
local function findPeripherals()
    lines, order, stressometer, balloonRelay, vents = {}, {}, nil, nil, {}
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.setTargetSpeed and p.getTargetSpeed then
            lines[name] = p
            order[#order + 1] = name
        elseif p and p.getStress and p.getStressCapacity and not stressometer then
            stressometer = { name = name, p = p }
        elseif p and p.setAnalogOutput and not balloonRelay then
            balloonRelay = { name = name, p = p }
        elseif p and p.getBalloonLift and p.getGasOutput then
            -- Every vent, kept apart rather than summed. Two vents on one
            -- balloon fail one at a time: a boiler that went cold under one of
            -- them is a ship that still flies and is quietly half as strong,
            -- and a total would hide exactly that.
            vents[#vents + 1] = { name = name, p = p }
        end
    end
    table.sort(order)
    table.sort(vents, function(a, b) return a.name < b.name end)
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

-- == THE BALLOON =============================================
--
-- A strength from 0 to 15 on one side of a redstone relay, where 0 is off and
-- higher is more lift. Only the cruise relay has the hardware; every other
-- computer running this file simply never finds one.

local balloonLevel = 0

local function clampLevel(value)
    local level = tonumber(value) or 0
    if level ~= level then return 0 end
    return math.max(0, math.min(15, math.floor(level + 0.5)))
end

-- Written down the way the fuel relay persists the tank capacities it learned,
-- and for a sharper reason: a relay that reboots in the air comes back holding
-- what it was holding rather than at zero, which is the ground.
local function saveBalloon()
    local handle = fs.open(fs.combine(DATA, BALLOON_FILE), "w")
    if not handle then return false end
    handle.write(tostring(balloonLevel))
    handle.close()
    return true
end

local function loadBalloon()
    local path = fs.combine(DATA, BALLOON_FILE)
    if not fs.exists(path) then return false end
    local handle = fs.open(path, "r")
    if not handle then return false end
    local text = handle.readAll()
    handle.close()
    local level = tonumber(text)
    if not level then return false end
    balloonLevel = clampLevel(level)
    return true
end

local function driveBalloon(level)
    if not balloonRelay then return false, "no redstone relay on this computer" end
    balloonLevel = clampLevel(level)
    -- Each side is its own call and each call yields a server tick, so they go
    -- out together. Six one after another is six ticks of the balloon at two
    -- different strengths, which is the ship leaning while it climbs.
    local calls, failed = {}, nil
    for _, side in ipairs(BALLOON_SIDES) do
        calls[#calls + 1] = function()
            local ok, err = pcall(balloonRelay.p.setAnalogOutput, side, balloonLevel)
            if not ok then failed = side .. ": " .. tostring(err) end
        end
    end
    parallel.waitForAll(table.unpack(calls))
    if failed then return false, failed end
    saveBalloon()
    return true
end

local function clampRpm(value)
    local rpm = tonumber(value) or 0
    if rpm ~= rpm then return 0 end          -- a NaN off the wire is a zero here
    if rpm > MAX_RPM then return MAX_RPM end
    if rpm < -MAX_RPM then return -MAX_RPM end
    return math.floor(rpm + 0.5)
end

-- Which local controller a key in a command refers to, or nil when the key is
-- not this relay's business.
--
-- The qualified form is what the flight computer sends once it has seen a
-- reading, and it is the only form that is safe with two relays on one protocol:
-- a bare name matches on both computers and would have the cruise relay obeying
-- an order meant for a turbine. The unqualified forms are kept for a human at a
-- keyboard, who is talking to one relay on purpose.
local function resolveLine(key)
    if type(key) == "number" then return order[key] end
    if type(key) ~= "string" then return nil end

    local owner, rest = key:match("^(%d+):(.+)$")
    if owner then
        if tonumber(owner) ~= ID then return nil end
        return lines[rest] and rest or nil
    end

    if lines[key] then return key end
    -- "#2.3", or "3", which is what the short name on the screen says.
    for _, candidate in ipairs(order) do
        if shortName(candidate) == key or candidate:match("_(%d+)$") == key then
            return candidate
        end
    end
    return nil
end

local function applyCommand(message)
    local wanted = message.rpm
    if type(wanted) ~= "table" then return false, "no rpm table" end
    local touched = 0
    for key, value in pairs(wanted) do
        local name = resolveLine(key)
        if name then
            demand[name] = clampRpm(value)
            touched = touched + 1
        end
    end
    -- Not an error. With two relays on one protocol, every broadcast that is
    -- meant for the other one lands here naming lines this computer does not
    -- have, and that is the system working.
    if touched == 0 then return true, "nothing here was named" end
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

-- == THE VENTS ===============================================
--
-- What the balloon is actually doing, as opposed to what strength it was told
-- to hold. Until these peripherals existed the only thing anybody knew about
-- the balloon was the number this relay had written to a redstone wire, and a
-- vent whose boiler had gone cold looked exactly like one that was working.
--
-- Two kinds of number come off a vent and they are not the same kind. The gas
-- figures are that vent's own: its output, its signal, its boiler. The balloon
-- figures are the whole balloon's, reported identically by every vent attached
-- to it, so they are read once rather than summed. Summing them would report
-- twice the lift on a ship with two vents.
--
-- None of these yield, unlike setTargetAmount, so reading them every broadcast
-- costs no server tick.
local function ask(vent, method, ...)
    local fn = vent.p[method]
    if not fn then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

-- "#3 vent 0", not "#3.0", which is what shortName would make of a peripheral
-- called Create_SteamVent_0 and is already the name of the propeller line on
-- that relay. Two different things on one screen under one name is the sort of
-- confusion that gets read as a fault in the wrong part of the ship.
local function ventName(name, index)
    return "#" .. ID .. " vent " .. (name:match("_(%d+)$") or tostring(index - 1))
end

local function readVents()
    local list, balloon = {}, nil
    for index, vent in ipairs(vents) do
        local attached = ask(vent, "hasBalloon") == true
        list[index] = {
            name = qualify(vent.name),
            short = ventName(vent.name, index),
            gas = ask(vent, "getGasType"),
            output = ask(vent, "getGasOutput"),
            signal = ask(vent, "getSignalStrength"),
            target = ask(vent, "getTargetAmount"),
            efficiency = ask(vent, "getBoilerEfficiency"),
            active = ask(vent, "isActive"),
            hasBalloon = attached,
        }
        if attached and not balloon then
            local mix = {}
            for _, entry in ipairs(ask(vent, "getBalloonGasMix") or {}) do
                mix[#mix + 1] = { type = entry.type, amount = entry.amount }
            end
            balloon = {
                lift = ask(vent, "getBalloonLift"),
                filled = ask(vent, "getBalloonFilledVolume"),
                target = ask(vent, "getBalloonTargetVolume"),
                change = ask(vent, "getBalloonVolumeChange"),
                height = ask(vent, "getBalloonHeight"),
                capacity = ask(vent, "getBalloonCapacity"),
                mix = #mix > 0 and mix or nil,
            }
        end
    end
    return list, balloon
end

-- == THE MESSAGE =============================================

local function buildMessage()
    local list = {}
    for index, name in ipairs(order) do
        local actual = nil
        local ok, value = pcall(lines[name].getTargetSpeed)
        if ok then actual = value end
        list[index] = {
            name = qualify(name),
            short = shortName(name),
            demand = demand[name] or 0,
            actual = actual,
        }
    end
    local ventList, balloonInfo = readVents()
    return {
        v = 1,
        id = ID,
        label = os.getComputerLabel(),
        balloon = balloonRelay and balloonLevel or nil,
        hasBalloon = balloonRelay ~= nil,
        vents = #ventList > 0 and ventList or nil,
        balloonInfo = balloonInfo,
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


-- == TELEMETRY ===============================================
--
-- A relay that goes quiet is the one event nobody can see from the flight
-- computer, because the way it is seen from there is by the messages stopping.
-- So the relay writes its own last word to its own disk, which is a folder on
-- the host: whatever it was holding, and when, still readable after it fell off
-- the radio. Same shape as the message it broadcasts, because that message is
-- already everything it knows.
local TELEMETRY = fs.combine(DATA, "telemetry")

local function writeTelemetry(message)
    local ok = pcall(function()
        if not fs.exists(TELEMETRY) then fs.makeDir(TELEMETRY) end
        local handle = fs.open(fs.combine(TELEMETRY, "snapshot.txt"), "w")
        if not handle then return end
        handle.writeLine("-- rewritten every broadcast, computer " .. os.getComputerID())
        handle.writeLine("-- clock " .. string.format("%.1f", os.clock()))
        handle.writeLine(textutils.serialise(message))
        handle.close()
    end)
    return ok
end

local function broadcast()
    local message = buildMessage()
    writeTelemetry(message)
    if modemSide then rednet.broadcast(link.stamp(message), PROTOCOL) end
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

    if balloonRelay then
        term.setTextColour(balloonLevel > 0 and colours.lightBlue or colours.orange)
        term.setCursorPos(2, y)
        term.write(string.format("balloon %2d / 15 on every side", balloonLevel))
        drawBar(math.min(W - 18, 18), y, 17, balloonLevel / 15, colours.lightBlue)
        y = y + 1
    end

    -- One row per vent, on the computer they are wired to. A cold boiler is
    -- read off this screen by whoever walked out here to look at it, which is
    -- the whole reason this relay has a screen at all.
    for index, vent in ipairs(vents) do
        if y + 1 > H - 3 then break end
        local efficiency = ask(vent, "getBoilerEfficiency") or 0
        local attached = ask(vent, "hasBalloon") == true
        local active = ask(vent, "isActive") == true
        term.setTextColour((attached and active and efficiency > 0.9) and colours.white
            or colours.orange)
        term.setCursorPos(2, y)
        term.write(string.format("%-9s %s boiler %d%%", ventName(vent.name, index),
            attached and (active and "gas" or "off") or "no balloon",
            math.floor(efficiency * 100 + 0.5)))
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
        if balloonRelay then
            term.write(string.format("no orders %.0fs, thrust off, balloon held", age))
        else
            term.write(string.format("no orders for %.0fs, turbines stopped", age))
        end
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
link.init(DATA)
if link.pass then
    log.info("paired: every message carries the passcode and anything without it is dropped")
else
    log.warn("no passcode set, so this relay answers anything on its protocol")
end
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
    -- Hosting is a courtesy: nothing on this ship looks a relay up by name,
    -- every order arrives addressed or broadcast. So a refusal is reported and
    -- the relay carries on, rather than a nicety taking the turbines down.
    local hosted, why = pcall(rednet.host, PROTOCOL, HOSTNAME)
    if not hosted then
        log.warnf("rednet.host refused the name %s: %s. Orders are addressed, so this costs nothing.",
            HOSTNAME, tostring(why))
    end
    log.infof("rednet open on %s, id %d, protocol %s, hostname %s",
        modemSide, os.getComputerID(), PROTOCOL, HOSTNAME)
else
    log.error("no modem on any side. nothing can command these turbines.")
end

local found = findPeripherals()
log.infof("found %d speed controller(s), stressometer %s, redstone relay %s", found,
    stressometer and stressometer.name or "none",
    balloonRelay and balloonRelay.name or "none")
for index, name in ipairs(order) do
    log.infof("  line %d  %s  %s", index, shortName(name), qualify(name))
end

-- A relay that rebooted in the air comes back holding what it was holding. The
-- alternative is a ship that descends every time a chunk reloads.
if balloonRelay then
    if loadBalloon() then
        log.infof("balloon restored to %d from the last run", balloonLevel)
    else
        log.info("no saved balloon level, starting at 0")
    end
    local ok, err = pcall(balloonRelay.p.setAnalogOutput, BALLOON_SIDE, balloonLevel)
    if not ok then log.error("balloon: " .. tostring(err)) end
end

-- A computer holding the balloon and nothing that spins is a legitimate relay
-- and stopping here would leave the ship with no lift. It says what it is
-- missing and carries on with the half of the job it can do.
if found == 0 and balloonRelay then
    log.warn("no rotation speed controllers here, running as a balloon relay only")
end

if found == 0 and not balloonRelay then
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


-- Pairing by hand, for a relay whose passcode has to change without running the
-- installer over it again. Every computer on the ship needs the same word, and
-- a relay paired to a different one looks exactly like a relay that is deaf.
if ARGS[1] == "--passcode" then
    if not ARGS[2] or ARGS[2]:lower() == "off" then
        link.clear()
        print("passcode cleared. This relay now answers anything on its protocol.")
        log.close()
        return
    end
    local ok, why = link.set(ARGS[2])
    if not ok then
        printError(why)
        log.close()
        return
    end
    print("passcode set. Set the same word on every other computer on this ship.")
    log.close()
    return
end

if ARGS[1] == "--once" then
    print(textutils.serialise(buildMessage()))
    log.close()
    return
end

-- Spinning them by hand, for the check where you walk out and look at them,
-- which no amount of telemetry replaces.
if ARGS[1] == "--spin" then
    local rpm = clampRpm(ARGS[2])
    print(("driving %d line(s) at %d rpm for 10s"):format(#order, rpm))
    for _, name in ipairs(order) do demand[name] = rpm end
    flush()
    sleep(10)
    allStop()
    log.infof("manual spin at %d rpm finished", rpm)
    log.close()
    return
end

-- The balloon needs the same walk out and look at it check the propellers get,
-- and it is the one part of the ship whose failure is not audible.
if ARGS[1] == "--balloon" then
    if not balloonRelay then
        print("No redstone relay on this computer. The balloon is on another one.")
        log.close()
        return
    end
    local level = clampLevel(ARGS[2])
    print(("holding the balloon at %d for 10s"):format(level))
    driveBalloon(level)
    sleep(10)
    log.infof("manual balloon at %d finished, left there", level)
    log.close()
    return
end

-- == LOOPS ===================================================

-- Orders arrive over a radio. A radio goes quiet when a chunk unloads, when the
-- flight computer crashes, or when someone breaks it, and turbines left running
-- at the last thing they were told fly the ship into terrain. So the last order
-- has a shelf life, and when it expires the thrust stops.
--
-- The balloon is untouched here, on purpose. See DEADMAN at the top of the file
-- for why these two are opposite and must stay that way.
local function deadmanLoop()
    while true do
        if lastCommand and (os.clock() - lastCommand) > DEADMAN then
            local running = false
            for _, name in ipairs(order) do
                if (demand[name] or 0) ~= 0 then running = true end
            end
            if running then
                log.warnf("no orders for %.1fs, stopping the turbines", os.clock() - lastCommand)
                if BALLOON_HOLDS_ON_SILENCE and balloonRelay then
                    log.infof("balloon held at %d. Lift is not thrust.", balloonLevel)
                end
                allStop()
            end
        end
        sleep(0.5)
    end
end

local function commandLoop()
    while true do
        local id, message = rednet.receive(PROTOCOL)
        local allowed, why = link.check(id, message)
        if not allowed then
            -- Counted rather than repeated, and it does NOT touch lastCommand.
            -- A refused message must not feed the deadman: a neighbour's ship
            -- broadcasting at one a second would otherwise keep these turbines
            -- alive on orders this relay never obeyed.
            if link.refused == 1 then log.warn("refusing orders: " .. tostring(why)) end
        elseif type(message) == "table" then
            if message.cmd == "set" then
                lastCommand = os.clock()
                local ok, err = applyCommand(message)
                if not ok then log.warnf("bad set from %d: %s", id, tostring(err)) end
            elseif message.cmd == "balloon" then
                lastCommand = os.clock()
                if balloonRelay then
                    local ok, err = driveBalloon(message.level)
                    if not ok then log.warnf("balloon from %d: %s", id, tostring(err)) end
                end
                -- A relay with no redstone relay says nothing. On this ship the
                -- balloon command reaches both computers and only one of them
                -- has anything to do about it.
            elseif message.cmd == "stop" then
                lastCommand = os.clock()
                allStop()
                -- stop is thrust, not lift. A pilot who wants the balloon down
                -- says so with a balloon command.
                log.infof("stop from %d", id)
            elseif message.cmd == "ping" then
                rednet.send(id, link.stamp(buildMessage()), PROTOCOL)
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

-- Answering the installer's ping, for as long as this relay runs rather than
-- only while the wizard is on its screen. See link.lua for why: a relay that
-- stopped answering the moment it rebooted is a relay that is powered, running
-- and deaf, and the pilot's only way back was reinstalling all four computers.
--
-- The role reported is the one this relay worked out for itself from its own
-- peripherals, so the checklist on the flight computer says what each computer
-- believes it is rather than what somebody typed.
local function pairLoop()
    link.respond(balloonRelay and "cruise" or "turbine", function(kind, id, why)
        if kind == "answered" then
            log.debugf("pair ping from %d, answered", id)
        else
            log.warnf("pair ping from %d refused: %s", id, tostring(why))
        end
    end)
end

local function idleLoop()
    while true do sleep(60) end
end

log.info("turbine relay running")

local ok, err = pcall(parallel.waitForAny, screenLoop, eventLoop, deadmanLoop,
    modemSide and reportLoop or idleLoop,
    modemSide and commandLoop or idleLoop,
    modemSide and pairLoop or idleLoop)

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
