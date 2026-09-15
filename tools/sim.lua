-- sim.lua -- run starcatcher outside Minecraft.
--
-- Stubs enough of CC: Tweaked, CC: Sable and Create: Avionics to boot the real
-- program against a toy ship: five speed controllers, four propellers around
-- the hull and a big one, a pose that integrates whatever thrust the autopilot
-- asks for. Nothing here ships to the computer. It exists so that a change to
-- the control loop or the screen can be caught on the desktop instead of at
-- 300 blocks up.
--
-- Run it with any Lua 5.2+ that can see this folder, or through tools/sim.js.
--
--   lua tools/sim.lua            boot, fly a leg, print the screen
--   lua tools/sim.lua --frames 400

local SRC = SIM_SRC or "../src/"

local options = { frames = 250, verbose = false, script = "fly" }
for index = 1, #(arg or {}) do
    if arg[index] == "--frames" then options.frames = tonumber(arg[index + 1]) or 250 end
    if arg[index] == "--verbose" then options.verbose = true end
    if arg[index] == "--vcal" then options.script = "vcal"; options.frames = 4000 end
    if arg[index] == "--tabs" then options.script = "tabs"; options.frames = 400 end
if arg[index] == "--clicks" then options.script = "clicks"; options.frames = 400 end
    if arg[index] == "--cal" then options.script = "cal"; options.frames = 3000 end
    if arg[index] == "--test" then options.script = "test" end
end

math.atan2 = math.atan2 or math.atan

-- == CLOCK ===================================================

local clock = 0

-- == IN-MEMORY FILESYSTEM ====================================

local files = {}
local dirs = { [""] = true, ["starcatcher"] = true }

local function normalise(path)
    path = tostring(path):gsub("\\", "/"):gsub("//+", "/"):gsub("^%./", ""):gsub("/$", "")
    return path
end

-- Program files come off the real disk; everything the program writes goes to
-- the table above and is thrown away when the run ends.
local function realRead(path)
    -- A host that cannot open files (a browser, or fengari) hands the sources
    -- in through SIM_FILES instead.
    if type(SIM_FILES) == "table" and SIM_FILES[path] then return SIM_FILES[path] end
    if io and io.open then
        local handle = io.open(path, "r")
        if not handle then return nil end
        local content = handle:read("*a")
        handle:close()
        return content
    end
    return nil
end

local function isProgramFile(path)
    return path:find("%.lua$") ~= nil
end

fs = {}
function fs.combine(a, b)
    a, b = normalise(a), normalise(b)
    if a == "" then return b end
    return normalise(a .. "/" .. b)
end
function fs.getDir(path)
    path = normalise(path)
    return (path:match("^(.*)/[^/]*$")) or ""
end
function fs.exists(path)
    path = normalise(path)
    if files[path] ~= nil or dirs[path] == true then return true end
    if isProgramFile(path) then return realRead(path) ~= nil end
    return false
end
function fs.makeDir(path)
    dirs[normalise(path)] = true
end
function fs.list(path)
    path = normalise(path)
    local out = {}
    for name in pairs(files) do
        local rest = name:match("^" .. path:gsub("%W", "%%%0") .. "/(.+)$")
        if rest and not rest:find("/") then out[#out + 1] = rest end
    end
    table.sort(out)
    return out
end
function fs.open(path, mode)
    path = normalise(path)
    if mode == "r" then
        local content = files[path]
        if content == nil and isProgramFile(path) then content = realRead(path) end
        if content == nil then return nil, "no such file" end
        return {
            readAll = function() return content end,
            readLine = function() return nil end,
            close = function() end,
        }
    end
    local buffer = {}
    files[path] = ""
    return {
        write = function(text) buffer[#buffer + 1] = tostring(text); files[path] = table.concat(buffer) end,
        writeLine = function(text)
            buffer[#buffer + 1] = tostring(text) .. "\n"
            files[path] = table.concat(buffer)
        end,
        flush = function() end,
        close = function() files[path] = table.concat(buffer) end,
    }
end

-- == TERMINAL ================================================

local WIDTH, HEIGHT = 51, 19

local function newSurface()
    local surface = { cx = 1, cy = 1, fg = 1, bg = 32768, rows = {} }
    for y = 1, HEIGHT do surface.rows[y] = string.rep(" ", WIDTH) end

    function surface.getSize() return WIDTH, HEIGHT end
    function surface.isColour() return true end
    surface.isColor = surface.isColour
    function surface.setCursorPos(x, y) surface.cx, surface.cy = math.floor(x), math.floor(y) end
    function surface.getCursorPos() return surface.cx, surface.cy end
    function surface.setTextColour(c) surface.fg = c end
    surface.setTextColor = surface.setTextColour
    function surface.setBackgroundColour(c) surface.bg = c end
    surface.setBackgroundColor = surface.setBackgroundColour
    function surface.setCursorBlink() end
    function surface.setVisible() end
    function surface.reposition() end
    function surface.clear()
        for y = 1, HEIGHT do surface.rows[y] = string.rep(" ", WIDTH) end
    end
    function surface.clearLine()
        if surface.rows[surface.cy] then surface.rows[surface.cy] = string.rep(" ", WIDTH) end
    end
    function surface.write(text)
        text = tostring(text)
        local y, x = surface.cy, surface.cx
        if not surface.rows[y] then return end
        if x < 1 then text = text:sub(2 - x); x = 1 end
        local row = surface.rows[y]
        local tail = x + #text - 1
        if tail > WIDTH then text = text:sub(1, WIDTH - x + 1) end
        if #text > 0 then
            surface.rows[y] = row:sub(1, x - 1) .. text .. row:sub(x + #text)
        end
        surface.cx = x + #text
    end
    function surface.current() return surface end
    return surface
end

term = newSurface()
term.current = function() return term end
term.native = term.current

window = {}
function window.create(parent, x, y, w, h)
    -- One surface for everything is a lie the real window API does not tell,
    -- but it is enough to catch a draw that writes off the end of a row.
    local _ = { parent, x, y, w, h }
    return term
end

colours = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, grey = 128, lightGrey = 256, cyan = 512, purple = 1024,
    blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768,
}
colors = colours

keys = { enter = 257, backspace = 259, tab = 258, up = 265, down = 264,
         left = 263, right = 262, delete = 261, pageUp = 266, pageDown = 267,
         leftBracket = 91, rightBracket = 93, q = 81 }
for index = 1, 12 do keys["f" .. index] = 290 + index end
for byte = string.byte("a"), string.byte("z") do
    keys[string.char(byte)] = keys[string.char(byte)] or byte
end

-- == SERIALISATION ===========================================

textutils = {}
function textutils.serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "number" or t == "boolean" then return tostring(value) end
    if t == "string" then return string.format("%q", value) end
    if t ~= "table" then return "nil" end
    local parts = { "{" }
    for k, v in pairs(value) do
        local key
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            key = k .. " = "
        else
            key = "[" .. textutils.serialize(k) .. "] = "
        end
        parts[#parts + 1] = indent .. "  " .. key .. textutils.serialize(v, indent .. "  ") .. ","
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end
textutils.serialise = textutils.serialize
function textutils.unserialize(text)
    local chunk = load("return " .. tostring(text), "cfg", "t", {})
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    return ok and value or nil
end
textutils.unserialise = textutils.unserialize

-- == THE TOY SHIP ============================================
--
-- Four propellers around the hull, north, south, east and west, plus a big one
-- underneath doing lift. Each has a speed controller. Drag is linear, thrust is
-- proportional to RPM, and the big one is four times the propeller of the small
-- ones, which is what makes the velocity calibration curves come out different
-- per axis, which is the whole point of measuring them.

local sim = {
    position = { x = 0, y = 80, z = 0 },
    velocity = { x = 0, y = 0, z = 0 },
    lines = {},
}

local LAYOUT = {
    { name = "Create_RotationSpeedController_0", axis = { 0, 0, -1 }, power = 0.0060 },
    { name = "Create_RotationSpeedController_1", axis = { 0, 0,  1 }, power = 0.0060 },
    { name = "Create_RotationSpeedController_2", axis = { 1, 0,  0 }, power = 0.0055 },
    { name = "Create_RotationSpeedController_3", axis = { -1, 0, 0 }, power = 0.0055 },
    { name = "Create_RotationSpeedController_4", axis = { 0, 1,  0 }, power = 0.0220 },
}

local DRAG = 0.55

for index, entry in ipairs(LAYOUT) do
    sim.lines[entry.name] = { rpm = 0, axis = entry.axis, power = entry.power, id = index }
end

local function stepPhysics(dt)
    local ax, ay, az = 0, 0, 0
    for _, line in pairs(sim.lines) do
        ax = ax + line.axis[1] * line.rpm * line.power
        ay = ay + line.axis[2] * line.rpm * line.power
        az = az + line.axis[3] * line.rpm * line.power
    end
    local v = sim.velocity
    v.x = v.x + (ax - v.x * DRAG) * dt
    v.y = v.y + (ay - v.y * DRAG) * dt
    v.z = v.z + (az - v.z * DRAG) * dt
    sim.position.x = sim.position.x + v.x * dt
    sim.position.y = sim.position.y + v.y * dt
    sim.position.z = sim.position.z + v.z * dt
end

-- CC: Sable, identity orientation: the ship never turns, which is honest,
-- because nothing in this autopilot produces a torque.
sublevel = {
    getLogicalPose = function()
        return {
            position = { x = sim.position.x, y = sim.position.y, z = sim.position.z },
            orientation = { x = 0, y = 0, z = 0, w = 1 },
        }
    end,
    getLinearVelocity = function()
        return { x = sim.velocity.x, y = sim.velocity.y, z = sim.velocity.z }
    end,
    getMass = function() return 12000 end,
}

-- == PERIPHERALS =============================================

local wrapped = {}
for _, entry in ipairs(LAYOUT) do
    local line = sim.lines[entry.name]
    wrapped[entry.name] = {
        setTargetSpeed = function(rpm) line.rpm = rpm end,
        getTargetSpeed = function() return line.rpm end,
        getSelfId = function() return line.id end,
        getSpeed = function() return line.rpm end,
        getKind = function() return "split_shaft" end,
        isOverstressed = function() return false end,
        hasSource = function() return true end,
    }
    local bearingName = "create_avionics:propeller_bearing_" .. (line.id - 1)
    wrapped[bearingName] = {
        getThrust = function() return math.abs(line.rpm) * 40 end,
        getThrustVector = function() return { line.axis[1], line.axis[2], line.axis[3] } end,
        getFacingVector = function() return { line.axis[1], line.axis[2], line.axis[3] } end,
        getAxis = function() return line.axis[2] ~= 0 and "up" or "north" end,
        getSailPower = function() return line.power > 0.01 and 64 or 16 end,
        getSubnetworkAnchorId = function() return line.id end,
        isAssembled = function() return true end,
    }
end
wrapped["create_avionics:altitude_sensor_0"] = {
    getHeight = function() return sim.position.y end,
    getAirPressure = function() return math.max(0, 1 - sim.position.y / 500) end,
    getVerticalSpeed = function() return sim.velocity.y end,
}

local function SEED_CURVE(a, b, c)
    return string.format(
        "{ [1] = { rpm = 48, speed = %s }, [2] = { rpm = 152, speed = %s }, [3] = { rpm = 256, speed = %s } }",
        a, b, c)
end

-- A ship that has already been through `cal` and `vcal`, so a headless run can get
-- straight to the part worth testing. The directions match LAYOUT above.
files["starcatcher/cal.cfg"] = [[{
  axes = {
    Create_RotationSpeedController_0 = { [1] = 0, [2] = 0, [3] = -1, reverse = false },
    Create_RotationSpeedController_1 = { [1] = 0, [2] = 0, [3] = 1, reverse = false },
    Create_RotationSpeedController_2 = { [1] = 1, [2] = 0, [3] = 0, reverse = false },
    Create_RotationSpeedController_3 = { [1] = -1, [2] = 0, [3] = 0, reverse = false },
    Create_RotationSpeedController_4 = { [1] = 0, [2] = 1, [3] = 0, reverse = false },
  },
  curves = {
    x = { pos = ]] .. SEED_CURVE(1.7, 5.4, 9.2) .. [[, neg = ]] .. SEED_CURVE(1.7, 5.4, 9.2) .. [[ },
    y = { pos = ]] .. SEED_CURVE(1.9, 6.0, 10.2) .. [[, neg = ]] .. SEED_CURVE(1.9, 6.0, 10.2) .. [[ },
    z = { pos = ]] .. SEED_CURVE(1.8, 5.9, 10.0) .. [[, neg = ]] .. SEED_CURVE(1.8, 5.9, 10.0) .. [[ },
  },
  meta = { directionAt = "seeded", velocityAt = "seeded" },
}]]

peripheral = {}
function peripheral.getNames()
    local out = {}
    for name in pairs(wrapped) do out[#out + 1] = name end
    table.sort(out)
    return out
end
-- A wireless modem on top, which is not part of the ship and never shows up in
-- ship.discover, because the only thing that asks for it by side is the fuel
-- link. Everything else finds its peripherals through getNames.
local MODEM = { isWireless = function() return true end }

function peripheral.wrap(name)
    if name == "top" then return MODEM end
    return wrapped[name]
end
function peripheral.getType(name)
    if name == "top" then return "modem" end
    return wrapped[name] and "peripheral" or nil
end
function peripheral.hasType(name, kind)
    return peripheral.getType(name) == kind
end
function peripheral.getMethods(name)
    local out = {}
    for key, value in pairs(wrapped[name] or {}) do
        if type(value) == "function" then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

-- == THE FUEL RELAY, PRETENDED ===============================
--
-- The real relay is a second computer with its hands on two create:fluid_tank
-- blocks. From this side it is nothing but a rednet message once a second, so
-- that is all the simulator has to be: two tanks, one of them lagging behind
-- the other the way a ship with a tired pump does, draining at a steady rate.
-- It exists so the FUEL tab and its advice can be photographed on the desktop.

local relay = {
    tanks = {
        { side = "left",  fluid = "minecraft:lava", amount = 289800, capacity = 504000, capSource = "assumed" },
        { side = "right", fluid = "minecraft:lava", amount = 161280, capacity = 504000, capSource = "assumed" },
    },
    burn = 240.0,   -- mB/s, split across the two tanks
}

local function relayMessage()
    local total, capacity, worst = 0, 0, nil
    local list = {}
    for _, tank in ipairs(relay.tanks) do
        total = total + tank.amount
        capacity = capacity + tank.capacity
        local fraction = tank.amount / tank.capacity
        if worst == nil or fraction < worst then worst = fraction end
        list[#list + 1] = {
            side = tank.side, fluid = tank.fluid, fluids = { tank.fluid },
            amount = tank.amount, capacity = tank.capacity,
            capSource = tank.capSource, ok = true,
        }
    end
    return {
        v = 1, id = 12, label = "fuel", clock = clock,
        tanks = list, total = total, capacity = capacity,
        fraction = capacity > 0 and total / capacity or 0,
        worstFraction = worst,
        rate = -relay.burn, rateSamples = 120, rateWindow = 60,
        assumedCapacity = 504000,
    }
end

-- == THE TURBINE RELAY, PRETENDED ============================
--
-- Two speed controllers on a third computer, and a stressometer watching the
-- kinetic network. The autopilot adopts these as lines of its own, so this is
-- also what tests that a line on a radio is indistinguishable from a line on a
-- wire everywhere except ship.flush.

local turbineRelay = {
    lines = {
        { name = "Create_RotationSpeedController_7", short = "#7", demand = 0, actual = 0 },
        { name = "Create_RotationSpeedController_8", short = "#8", demand = 0, actual = 0 },
    },
    capacity = 8192,
    overstressed = false,
}

local function turbineMessage()
    local list, drawn = {}, 0
    for index, entry in ipairs(turbineRelay.lines) do
        -- Stress rises with how hard the turbines are being driven, which is the
        -- only part of Create's stress model worth pretending about here.
        drawn = drawn + math.abs(entry.actual) * 12
        list[index] = { name = entry.name, short = entry.short,
                        demand = entry.demand, actual = entry.actual }
    end
    return {
        v = 1, id = 19, label = "turbines", clock = clock,
        lines = list, maxRpm = 256,
        stress = 900 + drawn, stressCapacity = turbineRelay.capacity,
        stressFraction = (900 + drawn) / turbineRelay.capacity,
        overstressed = turbineRelay.overstressed,
        stressOk = true, deadman = 3.0,
    }
end

rednet = {}
function rednet.open() end
function rednet.close() end
function rednet.host() end
function rednet.unhost() end
function rednet.isOpen() return true end

-- Orders to the turbine relay are obeyed instantly here. The real one takes a
-- server tick per controller, which is the whole reason it is a separate
-- computer and not this computer's problem.
local function deliver(message)
    if type(message) ~= "table" then return end
    for _, entry in ipairs(turbineRelay.lines) do
        if message.cmd == "stop" then
            entry.demand, entry.actual = 0, 0
        elseif message.cmd == "set" and type(message.rpm) == "table" then
            local rpm = message.rpm[entry.name]
            if rpm then entry.demand, entry.actual = rpm, rpm end
        end
    end
end

function rednet.broadcast(message) deliver(message) end
function rednet.send(_, message) deliver(message) end

-- Blocks for a second and then hands over a reading, which is exactly the shape
-- the real ones have. Sleeping here is what keeps the relay loops from starving
-- the control loop in the scheduler below.
function rednet.receive(protocol)
    sleep(1.0)
    if protocol == "starcatcher-turbine" then
        return 19, turbineMessage(), protocol
    end
    local share = relay.burn / #relay.tanks
    for index, tank in ipairs(relay.tanks) do
        -- The second tank drains faster, so the imbalance advice has something
        -- to find. A simulator that only ever shows the happy path tests the
        -- happy path.
        tank.amount = math.max(0, tank.amount - share * (index == 2 and 1.6 or 0.4))
    end
    return 12, relayMessage(), "starcatcher-fuel"
end

-- == SCHEDULER ===============================================
--
-- CC runs coroutines that yield on events. This is the smallest thing that
-- behaves the same way: sleeps advance the clock, event pulls take from a
-- queue, and when the queue runs dry the run is over.

local eventQueue = {}
local function queueEvent(...) eventQueue[#eventQueue + 1] = { ... } end

-- A pause in the script: the pilot sitting there watching the drift build up
-- before they press a key. Without it every prompt is answered on the same
-- frame it is asked and nothing has time to move.
local function queueWait(frames) eventQueue[#eventQueue + 1] = { wait = frames or 20 } end

local frames = 0
local finished = false

function sleep(secs)
    coroutine.yield({ kind = "sleep", secs = secs or 0.05 })
end

os = os or {}
os.clock = function() return clock end
os.time = function() return clock / 3600 % 24 end
os.day = function() return 1 end
os.getComputerID = function() return 7 end
os.pullEvent = function()
    local event = coroutine.yield({ kind = "event" })
    return table.unpack(event)
end
os.pullEventRaw = os.pullEvent
os.startTimer = function() return 1 end
os.queueEvent = queueEvent

parallel = {}

-- Advance the world. Every sleep is a physics step, and the frame budget is
-- what stops a headless run of an infinite control loop from being infinite.
local lastScreen = nil
local shots = {}

local function snapshotScreen()
    local blank = true
    local copy = {}
    for y = 1, HEIGHT do
        copy[y] = term.rows[y]
        if copy[y]:match("%S") then blank = false end
    end
    if not blank then lastScreen = copy end
end

local function advance(secs)
    snapshotScreen()
    secs = secs or 0.05
    clock = clock + secs
    stepPhysics(secs)
    frames = frames + 1
    if frames > options.frames then
        finished = true
        error("Terminated", 0)
    end
end

local function runAll(waitForAll, ...)
    local tasks = { ... }
    local routines, pending = {}, {}

    local function step(index, value)
        local ok, request = coroutine.resume(routines[index], value)
        if not ok then error(request, 0) end
        pending[index] = request
    end

    for index, fn in ipairs(tasks) do routines[index] = coroutine.create(fn) end
    for index in ipairs(routines) do step(index, nil) end

    while true do
        local alive = false
        for index, routine in ipairs(routines) do
            if coroutine.status(routine) == "dead" then
                if not waitForAll then return index end
            else
                alive = true
                local request = pending[index]
                if type(request) == "table" and request.kind == "event" then
                    local event = eventQueue[1]
                    if event and event.wait then
                        event.wait = event.wait - 1
                        if event.wait <= 0 then table.remove(eventQueue, 1) end
                        advance(0.05)
                        event = nil
                    else
                        event = table.remove(eventQueue, 1)
                    end
                    if event then
                        step(index, event)
                        if event[1] == "key" or event[1] == "mouse_click" then
                            snapshotScreen()
                            shots[#shots + 1] = {
                                label = event[1] == "key" and "after key" or
                                    ("click x=" .. tostring(event[3])),
                                rows = lastScreen,
                            }
                        end
                    else
                        -- Nobody is pressing anything. This loop stays blocked
                        -- while the others keep flying.
                        advance(0.05)
                    end
                else
                    advance(type(request) == "table" and request.secs or 0.05)
                    step(index, nil)
                end
            end
        end
        if not alive then return 0 end
    end
end

function parallel.waitForAll(...) return runAll(true, ...) end
function parallel.waitForAny(...) return runAll(false, ...) end

shell = { getRunningProgram = function() return SRC .. "starcatcher.lua" end }

function printError(...) io.write("ERROR: "); print(...) end
function write(text) io.write(tostring(text)) end

-- == RUN =====================================================

local function typeLine(text)
    for index = 1, #text do queueEvent("char", text:sub(index, index)) end
    queueEvent("key", keys.enter)
end

if options.script == "cal" then
    -- Walk the direction wizard with a pilot who agrees with everything: spin
    -- it, let it drift, stop it, yes that is the right way, yes that is the
    -- direction.
    typeLine("cal")
    -- Five wired lines and the two the turbine relay hands over, plus slack, so
    -- the wizard is always answered to the end no matter what the toy ship gains.
    for _ = 1, 8 do
        queueWait(10)
        queueEvent("key", keys.enter)      -- spin this one
        queueWait(60)
        queueEvent("key", keys.enter)      -- stop it
        queueWait(5)
        queueEvent("key", keys.enter)      -- yes, right way round
        queueWait(5)
        queueEvent("key", keys.enter)      -- take the suggested direction
    end
    queueWait(5)
    queueEvent("key", keys.enter)
elseif options.script == "tabs" then
    -- Walk every tab and photograph each one, which is the cheapest way to
    -- catch a draw that indexes off the end of something.
    typeLine("save home")
    typeLine("save dock 200 96 -140")
    typeLine("fly 120 95 60")
    for _, key in ipairs({ keys.f2, keys.f3, keys.f4, keys.f5, keys.f6, keys.f7, keys.f1 }) do
        queueEvent("key", key)
    end
elseif options.script == "clicks" then
    -- Click the tab bar rather than pressing F keys. drawTabs and handleClick
    -- lay the bar out separately, and a disagreement of one column between them
    -- is a pilot pressing FUEL and getting TUNE, which no F key test can catch.
    -- The last column is in here on purpose: the bar used to stop short of the
    -- right hand edge and the columns past it did nothing at all.
    typeLine("save home")
    for _, x in ipairs({ 12, 20, 27, 34, 41, 48, 51, 4 }) do
        queueEvent("mouse_click", 1, x, 1)
    end
elseif options.script == "vcal" then
    -- Drive the velocity calibration wizard end to end. Nothing answers it, so
    -- it runs its whole ladder on the toy ship and writes the curves out.
    typeLine("vcal y")
else

-- A short flight: save where we are, fly somewhere, watch it get there.
queueEvent("char", "f")
queueEvent("char", "l")
queueEvent("char", "y")
queueEvent("char", " ")
queueEvent("char", "1")
queueEvent("char", "2")
queueEvent("char", "0")
queueEvent("char", " ")
queueEvent("char", "9")
queueEvent("char", "5")
queueEvent("char", " ")
queueEvent("char", "6")
queueEvent("char", "0")
queueEvent("key", keys.enter)
queueEvent("key", keys.f2)
queueEvent("key", keys.f1)
end

local chunk = assert(loadfile(SRC .. "starcatcher.lua"))

-- The self test needs none of the ship above it, but it does need the argument,
-- and starcatcher reads its arguments as chunk varargs rather than off `arg`.
if options.script == "test" then
    local ok, err = pcall(chunk, "--test")
    if not ok then print("FAILED: " .. tostring(err)); error(err, 0) end
    return
end

local ok, err = pcall(chunk)

print("")
print("=== screen ===")
for y = 1, HEIGHT do
    print(string.format("%2d|%s|", y, (lastScreen or term.rows)[y]))
end
print("")
print(string.format("position  %.1f %.1f %.1f", sim.position.x, sim.position.y, sim.position.z))
print(string.format("velocity  %.2f %.2f %.2f", sim.velocity.x, sim.velocity.y, sim.velocity.z))
local rpms = {}
for _, entry in ipairs(LAYOUT) do
    rpms[#rpms + 1] = string.format("%s=%d", entry.name:match("_(%d+)$"), sim.lines[entry.name].rpm)
end
print("rpm       " .. table.concat(rpms, " "))
if not ok and not finished and tostring(err):find("Terminated") == nil then
    print("")
    print("FAILED: " .. tostring(err))
    error(err, 0)
end
if options.script == "cal" then
    print("")
    print("=== wizard, mid run ===")
    local shot = shots[math.min(6, #shots)] or { rows = lastScreen }
    for y = 1, HEIGHT do print(string.format("%2d|%s|", y, (shot.rows or {})[y] or "")) end
    print("")
    print("=== cal.cfg ===")
    print(files["starcatcher/cal.cfg"] or "(nothing written)")
    return
end

if options.script == "tabs" then
    for index, shot in ipairs(shots) do
        print("")
        print("=== screen " .. index .. " ===")
        for y = 1, HEIGHT do print(string.format("%2d|%s|", y, (shot.rows or {})[y] or "")) end
    end
    print("")
    print("captured " .. #shots .. " screens over " .. frames .. " frames")
    return
end

if options.script == "clicks" then
    -- Only the click shots are interesting, and only the tab bar and the line
    -- under it, which is enough to say which tab came up.
    for _, shot in ipairs(shots) do
        if shot.label:match("^click") then
            print(string.format("%-12s %s", shot.label, (shot.rows or {})[2] or ""))
        end
    end
    print("")
    print("clicked " .. #shots .. " times over " .. frames .. " frames")
    return
end

if options.script == "vcal" then
    print("")
    print("=== cal.cfg ===")
    print(files["starcatcher/cal.cfg"] or "(nothing written)")
    print("")
    print("simulation finished after " .. frames .. " frames")
    return
end

local target = { x = 120, y = 95, z = 60 }
local left = math.sqrt((target.x - sim.position.x) ^ 2
                     + (target.y - sim.position.y) ^ 2
                     + (target.z - sim.position.z) ^ 2)
local began = math.sqrt(target.x ^ 2 + (target.y - 80) ^ 2 + target.z ^ 2)
print(string.format("distance to the target: %.1f of the %.1f it started with", left, began))
print("")
if left >= began then
    print("FAILED: the autopilot did not close on its target")
    error("no progress", 0)
end
print("simulation finished cleanly after " .. frames .. " frames")
