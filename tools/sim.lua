-- sim.lua -- run starcatcher outside Minecraft.
--
-- Stubs enough of CC: Tweaked, CC: Sable and Create: Avionics to boot the real
-- program against a toy ship, and integrates a pose from whatever thrust the
-- autopilot asks for. Nothing here ships to the computer. It exists so that a
-- change to the control loop or the screen can be caught on the desktop instead
-- of at 300 blocks up.
--
-- The ship is a tank turn hull: nothing wired to this computer at all, four
-- turbines on one relay and a main propeller on another, all five pointing the
-- same way, steering on differential thrust and floating on a balloon driven by
-- a redstone strength signal.
--
-- Run it with any Lua 5.2+ that can see this folder, or through tools/sim.js.
--
--   lua tools/sim.lua            boot, fly a leg, print the screen
--   lua tools/sim.lua --frames 400
--   lua tools/sim.lua --physics   check the hull, without the autopilot

local SRC = SIM_SRC or "../src/"

local options = { frames = 1600, verbose = false, script = "fly" }
for index = 1, #(arg or {}) do
    if arg[index] == "--frames" then options.frames = tonumber(arg[index + 1]) or 1600 end
    if arg[index] == "--verbose" then options.verbose = true end
    if arg[index] == "--tabs" then options.script = "tabs"; options.frames = 400 end
if arg[index] == "--clicks" then options.script = "clicks"; options.frames = 400 end
    if arg[index] == "--cal" then options.script = "cal"; options.frames = 9000 end
    if arg[index] == "--test" then options.script = "test" end
    -- The physics probe is about the hull, so it picks its own ship and there is
    -- no sense in asking for it against the other one.
    if arg[index] == "--physics" then options.script = "physics" end
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
-- One state table for both hulls. A hull is then a layout, a physics step and a
-- pose, and everything below this point is written against `sim` rather than
-- against either ship.
--
-- `props` is every propeller on the vessel wherever its controller lives, wired
-- to this computer or out on a relay. Physics does not care which, the same way
-- the mixer does not.

local sim = {
    position = { x = 0, y = 80, z = 0 },
    velocity = { x = 0, y = 0, z = 0 },
    yaw = 0,            -- deg, Minecraft convention, 0 facing +Z
    yawRate = 0,        -- deg/s
    pitch = 0,          -- deg, positive nose up
    pitchRate = 0,      -- deg/s
    balloon = 0,        -- redstone strength, 0 to 15
    lines = {},         -- speed controllers wired to this computer
    props = {},         -- every propeller, wired or remote
}

local stepPhysics, poseOf, angularVelocityOf

-- == THE TANK TURN HULL ======================================
--
-- Five propellers all pointing along the hull, each reversible. Four are
-- turbines in left and right pairs on one relay, the fifth is the main
-- propeller on another. There is no sideways thrust and no vertical thrust: the
-- ship turns by driving one side against the other and floats on a balloon.
--
-- Three things here exist to be found by calibration rather than read out of the
-- program, because that is what the real ship makes you do:
--
--   the two sides have different lever arms, so equal RPM is not equal torque
--   the main propeller is nearly three times the turbine
--   nothing is wired to this computer, so ship.discover() sees zero lines
--
-- Levers are signed and a positive torque raises yaw, which is the ship turning
-- to its own right. At yaw 0 the hull faces +Z and its own right is -X, so the
-- left side sits at +X, and a forward push there swings the nose right. The left
-- lever is the positive one for that reason and no other. Which line the
-- autopilot calls left is not written down anywhere it can read: it has to spin
-- each one and watch.

local TANK_TURBINE_POWER = 0.0045
local TANK_MAIN_POWER    = 0.0120
local TANK_LEVER_LEFT    =  1.45   -- the weaker side, on purpose
local TANK_LEVER_RIGHT   = -1.60

-- Steady yaw rate at a full differential is deg(torque / inertia) / drag, which
-- with these comes out near 32 deg/s, a little over the 30 the tank phase caps
-- itself at. A hull that cannot quite reach its own cap is the uninteresting
-- case. The inertia is in radians and the rate is in degrees, which is worth
-- saying out loud because sizing one in the units of the other is a factor of
-- 57 and the ship spins like a top.
local TANK_INERTIA   = 15.73
local TANK_YAW_DRAG  = 0.80

-- Drag in the ship's own frame. A hull this shape slides sideways badly, which
-- is what makes the velocity left over after a turn bleed off instead of
-- carrying the ship past its target.
local TANK_DRAG_FWD  = 0.55
local TANK_DRAG_LAT  = 2.20
local TANK_DRAG_VERT = 0.90

local TANK_GRAVITY   = 1.60     -- m/s/s down, with the balloon off
local TANK_LIFT_MAX  = 3.20     -- m/s/s up, at strength 15

-- Thrust is applied above the centre of mass, so it pitches the hull: nose up
-- under power and nose down under reverse. Full reverse on all five settles
-- near 16 degrees, which is past the 12 the brake calibration is looking for,
-- and the main alone reaches about 6, which is not. That gap is the entire
-- reason braking is graduated.
local TANK_PITCH_GAIN  = 2.08   -- deg per m/s/s of forward acceleration
local TANK_PITCH_STIFF = 4.00
local TANK_PITCH_DAMP  = 2.50

local function tankStep(dt)
    local thrust, torque = 0, 0
    for _, prop in ipairs(sim.props) do
        -- A relay line reports `actual`, not `rpm`. Every propeller on this hull
        -- is on a relay, so that is the only field there is to turn.
        local force = prop.line.actual * prop.power
        thrust = thrust + force
        torque = torque + force * prop.lever
    end

    sim.yawRate = sim.yawRate
        + (math.deg(torque / TANK_INERTIA) - sim.yawRate * TANK_YAW_DRAG) * dt
    sim.yaw = (sim.yaw + sim.yawRate * dt + 180) % 360 - 180

    local settled = TANK_PITCH_GAIN * thrust
    sim.pitchRate = sim.pitchRate
        + ((settled - sim.pitch) * TANK_PITCH_STIFF - sim.pitchRate * TANK_PITCH_DAMP) * dt
    sim.pitch = sim.pitch + sim.pitchRate * dt

    -- Nose vector for this yaw. util.yawOf reads yaw off the body +Z axis as
    -- atan2(-fx, fz), so going back the other way puts the minus on x.
    local rad = math.rad(sim.yaw)
    local nx, nz = -math.sin(rad), math.cos(rad)

    local v = sim.velocity
    -- Split the velocity into along the hull and across it, drag each on its own
    -- terms, and put it back. Sideways drag is what a hull with no side thrust
    -- actually has.
    local along = v.x * nx + v.z * nz
    local sx, sz = v.x - along * nx, v.z - along * nz
    along = along + (thrust - along * TANK_DRAG_FWD) * dt
    sx = sx - sx * TANK_DRAG_LAT * dt
    sz = sz - sz * TANK_DRAG_LAT * dt
    v.x, v.z = along * nx + sx, along * nz + sz

    local lift = TANK_LIFT_MAX * (sim.balloon / 15)
    v.y = v.y + (lift - TANK_GRAVITY - v.y * TANK_DRAG_VERT) * dt

    sim.position.x = sim.position.x + v.x * dt
    sim.position.y = sim.position.y + v.y * dt
    sim.position.z = sim.position.z + v.z * dt
end

-- Yaw about world Y then pitch about the body X axis. The yaw half carries a
-- minus: a rotation about +Y by a takes body +Z to (sin a, 0, cos a), and this
-- yaw convention wants (-sin yaw, 0, cos yaw), so the rotation angle is -yaw.
-- Anything that gets that sign backwards flies a confident mirror image.
local function tankPose()
    local cy, sy = math.cos(math.rad(sim.yaw) / 2), math.sin(math.rad(sim.yaw) / 2)
    local cp, sp = math.cos(math.rad(sim.pitch) / 2), math.sin(math.rad(sim.pitch) / 2)
    return { x = -cy * sp, y = -cp * sy, z = -sy * sp, w = cy * cp }
end

-- Radians per second about the world axes, which is the shape CC: Sable hands
-- over and not the deg/s the rest of this file thinks in. The y component is
-- negative of the yaw rate for the same reason the quaternion above is.
local function tankAngularVelocity()
    local rad = math.rad(sim.yaw)
    local pitchRad = math.rad(sim.pitchRate)
    return {
        x = -pitchRad * math.cos(rad),
        y = -math.rad(sim.yawRate),
        z = -pitchRad * math.sin(rad),
    }
end

-- == WHICH SHIP ==============================================

-- == THE SHIP ================================================

local START_Y = 120

stepPhysics, poseOf, angularVelocityOf = tankStep, tankPose, tankAngularVelocity
sim.position = { x = 0, y = START_Y, z = 0 }
sim.balloon = 8      -- roughly hovering, which is where a ship is found

-- Create: Avionics puts gravity on the flight computer.
aero = { getGravity = function() return TANK_GRAVITY end }

sublevel = {
    getLogicalPose = function()
        return {
            position = { x = sim.position.x, y = sim.position.y, z = sim.position.z },
            orientation = poseOf(),
        }
    end,
    getLinearVelocity = function()
        return { x = sim.velocity.x, y = sim.velocity.y, z = sim.velocity.z }
    end,
    getAngularVelocity = function() return angularVelocityOf() end,
    getMass = function() return 12000 end,
}


-- == PERIPHERALS =============================================

-- On the tank hull this stays empty but for the modem below. Computer 0 owns the
-- maths and owns nothing that spins, so ship.discover() finds no lines at all
-- and every propeller arrives a second later over the radio.
local wrapped = {}

-- No altimeter either. The flight computer carries a modem and nothing else, so
-- height comes off the pose like everything else does and readExtras is left
-- with nothing to report.

-- A ship that has already been through `cal`, so a headless run gets straight to
-- the part worth testing. Every number below is what the toy ship above actually
-- does, worked out from its own constants rather than guessed, because a seeded
-- calibration that disagrees with the physics tests the autopilot against a ship
-- that does not exist.
--
--   yaw      rate is linear in the differential, 32 deg/s at 256
--   forward  0.030 thrust per rpm over 0.55 drag, so 13.96 m/s at 256
--   brake    the main is 0.012 of that 0.030, and pitch is 2.08 deg per m/s/s
--   balloon  (3.2 * level / 15 - 1.6) / 0.9, which crosses zero near 7.5
files["starcatcher/cal.cfg"] = [[{
  sides = {
    ["2:Create_RotationSpeedController_0"] = { side = "left",  reverse = false },
    ["2:Create_RotationSpeedController_1"] = { side = "left",  reverse = false },
    ["2:Create_RotationSpeedController_2"] = { side = "right", reverse = false },
    ["2:Create_RotationSpeedController_3"] = { side = "right", reverse = false },
    ["3:Create_RotationSpeedController_0"] = { side = "main",  reverse = false },
  },
  noseOffset = 0,
  yawAuth = { left = 0.0594, right = 0.0655 },
  yawCurve = {
    pos = { { rpm = 64, speed = 8.0 }, { rpm = 128, speed = 16.0 },
            { rpm = 192, speed = 24.0 }, { rpm = 256, speed = 32.0 } },
    neg = { { rpm = 64, speed = 8.0 }, { rpm = 128, speed = 16.0 },
            { rpm = 192, speed = 24.0 }, { rpm = 256, speed = 32.0 } },
  },
  fwdCurve = {
    pos = { { rpm = 64, speed = 3.49 }, { rpm = 128, speed = 6.98 },
            { rpm = 192, speed = 10.47 }, { rpm = 256, speed = 13.96 } },
    neg = { { rpm = 64, speed = 3.49 }, { rpm = 128, speed = 6.98 },
            { rpm = 192, speed = 10.47 }, { rpm = 256, speed = 13.96 } },
  },
  brakeCurve = {
    main = { { rpm = 128, speed = 1.54, pitch = 3.2 },
             { rpm = 256, speed = 3.07, pitch = 6.4 } },
    all  = { { rpm = 128, speed = 3.84, pitch = 8.0 },
             { rpm = 256, speed = 7.68, pitch = 16.0 } },
  },
  balloonCurve = {
    { rpm = 0, speed = -1.78 }, { rpm = 4, speed = -0.83 },
    { rpm = 7, speed = -0.12 }, { rpm = 8, speed = 0.12 },
    { rpm = 11, speed = 0.83 }, { rpm = 15, speed = 1.78 },
  },
  altHover = 8,
  stressAtTurn = 3360,
  stressAtCruise = 3360,
  inventory = {
    relays = { { id = 2, lines = 4 }, { id = 3, lines = 1 } },
  },
  meta = { sidesAt = "seeded", yawAt = "seeded", forwardAt = "seeded",
           brakeAt = "seeded", balloonAt = "seeded" },
}]]

-- The wizard, driven headless, measures a ship that is not really there in real
-- time. Every rung waits for a number to stop moving, and at the shipped
-- defaults five stages take about eight minutes of simulated time. These are
-- the same settings a pilot can reach from the TUNE tab, wound down to what the
-- toy ship needs, so what is being tested is the wizard and not the patience of
-- whoever runs it.
if options.script == "cal" then
    files["starcatcher/config.cfg"] = [[{
      calSettle = 8, calHold = 1, calStable = 0.3, calYawStable = 1.5,
      calCooldown = 1, calSample = 0.2, calSteps = 3,
      calBalloonDwell = 4, calRunup = 5,
    }]]
    -- and it starts from a ship nobody has ever measured, because a run that
    -- began from the seeded answers would be testing the file rather than the
    -- five stages that write it.
    files["starcatcher/cal.cfg"] = nil
end

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

-- Computer ids match the ship the hull is pretending to be, so what the screen
-- says lines up with what you would read off the computers in the world.
local FUEL_RELAY_ID = 1

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
        v = 1, id = FUEL_RELAY_ID, label = "fuel", clock = clock,
        tanks = list, total = total, capacity = capacity,
        fraction = capacity > 0 and total / capacity or 0,
        worstFraction = worst,
        rate = -relay.burn, rateSamples = 120, rateWindow = 60,
        assumedCapacity = 504000,
    }
end

-- == THE TURBINE RELAYS, PRETENDED ===========================
--
-- Speed controllers on another computer and a stressometer watching the kinetic
-- network. The autopilot adopts these as lines of its own, so this is also what
-- tests that a line on a radio is indistinguishable from a line on a wire
-- everywhere except ship.flush.
--
-- There are two of them, and both offer a Create_RotationSpeedController_0,
-- because peripheral names are per network. That collision is the reason every line a relay advertises is named
-- "<that relay's computer id>:<peripheral name>", and the reason this stub
-- builds the names the same way the real relay program does rather than handing
-- over something already tidy.

-- The same two functions the relay program has, kept in step with it by hand
-- the way everything else on these computers is.
local function qualify(id, name) return id .. ":" .. name end
local function shortFor(id, name) return "#" .. id .. "." .. name:match("_(%d+)$") end

local function relayLine(id, name)
    return { name = qualify(id, name), port = name, short = shortFor(id, name),
             demand = 0, actual = 0 }
end

local turbineRelays = {
    {
        id = 2, label = "turbines", capacity = 8192, overstressed = false,
        lines = {
            relayLine(2, "Create_RotationSpeedController_0"),
            relayLine(2, "Create_RotationSpeedController_1"),
            relayLine(2, "Create_RotationSpeedController_2"),
            relayLine(2, "Create_RotationSpeedController_3"),
        },
    },
    {
        -- The cruise relay also holds the redstone relay driving the balloon,
        -- which is why the balloon command has an address to go to at all.
        -- Its one controller is named _0 on purpose: so is a turbine.
        id = 3, label = "cruise", capacity = 8192, overstressed = false,
        balloon = true,
        lines = {
            relayLine(3, "Create_RotationSpeedController_0"),
        },
    },
}

local two, three = turbineRelays[1], turbineRelays[2]
sim.props = {
    { line = two.lines[1], power = TANK_TURBINE_POWER, lever = TANK_LEVER_LEFT,  side = "left" },
    { line = two.lines[2], power = TANK_TURBINE_POWER, lever = TANK_LEVER_LEFT,  side = "left" },
    { line = two.lines[3], power = TANK_TURBINE_POWER, lever = TANK_LEVER_RIGHT, side = "right" },
    { line = two.lines[4], power = TANK_TURBINE_POWER, lever = TANK_LEVER_RIGHT, side = "right" },
    { line = three.lines[1], power = TANK_MAIN_POWER,  lever = 0,                side = "main" },
}

local function turbineMessage(unit)
    local list, drawn = {}, 0
    for index, entry in ipairs(unit.lines) do
        -- Stress rises with how hard the turbines are being driven, which is the
        -- only part of Create's stress model worth pretending about here.
        drawn = drawn + math.abs(entry.actual) * 2.4
        list[index] = { name = entry.name, short = entry.short,
                        demand = entry.demand, actual = entry.actual }
    end
    return {
        v = 1, id = unit.id, label = unit.label, clock = clock,
        lines = list, maxRpm = 256,
        hasBalloon = unit.balloon == true,
        balloon = unit.balloon and sim.balloon or nil,
        stress = 900 + drawn, stressCapacity = unit.capacity,
        stressFraction = (900 + drawn) / unit.capacity,
        overstressed = unit.overstressed,
        stressOk = true, deadman = 3.0,
    }
end

rednet = {}
function rednet.open() end
function rednet.close() end
function rednet.host() end
function rednet.unhost() end
function rednet.isOpen() return true end

-- Orders to a turbine relay are obeyed instantly here. The real one takes a
-- server tick per controller, which is the whole reason it is a separate
-- computer and not this computer's problem.
local function deliverTo(unit, message)
    if message.cmd == "stop" then
        for _, entry in ipairs(unit.lines) do entry.demand, entry.actual = 0, 0 end
        return
    end
    if message.cmd == "balloon" and unit.balloon then
        -- Only the relay holding the redstone relay can do anything with this.
        -- Any other one hearing it does nothing, quietly, the way a computer with
        -- no such peripheral does.
        if type(message.level) == "number" then
            sim.balloon = math.max(0, math.min(15, math.floor(message.level + 0.5)))
        end
        return
    end
    if message.cmd == "set" and type(message.rpm) == "table" then
        for _, entry in ipairs(unit.lines) do
            -- The qualified name is what the flight computer sends. The bare one
            -- is kept because a human at a keyboard talks to one relay on
            -- purpose, and because it is what catches a command that was meant
            -- for the other relay and arrived here unqualified.
            local rpm = message.rpm[entry.name]
            if rpm == nil then rpm = message.rpm[entry.port] end
            if rpm then entry.demand, entry.actual = rpm, rpm end
        end
    end
end

local function deliver(message, id)
    if type(message) ~= "table" then return end
    for _, unit in ipairs(turbineRelays) do
        if id == nil or id == unit.id then deliverTo(unit, message) end
    end
end

function rednet.broadcast(message) deliver(message, nil) end
function rednet.send(id, message) deliver(message, id) end

-- Blocks for a second and then hands over a reading, which is exactly the shape
-- the real ones have. Sleeping here is what keeps the relay loops from starving
-- the control loop in the scheduler below.
--
-- Two relays on one protocol take turns, because that is what two computers each
-- broadcasting once a second look like from this end.
local nextRelay = 0

function rednet.receive(protocol)
    sleep(1.0)
    if protocol == "starcatcher-turbine" then
        nextRelay = (nextRelay % #turbineRelays) + 1
        local unit = turbineRelays[nextRelay]
        return unit.id, turbineMessage(unit), protocol
    end
    local share = relay.burn / #relay.tanks
    for index, tank in ipairs(relay.tanks) do
        -- The second tank drains faster, so the imbalance advice has something
        -- to find. A simulator that only ever shows the happy path tests the
        -- happy path.
        tank.amount = math.max(0, tank.amount - share * (index == 2 and 1.6 or 0.4))
    end
    return FUEL_RELAY_ID, relayMessage(), "starcatcher-fuel"
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

-- Minecraft runs at twenty ticks a second and so does this, however long the
-- scheduler step that got here was. A relay loop sleeping a whole second would
-- otherwise hand the physics a dt of 1.0, and explicit Euler on a drag of 2.2
-- per second is unstable at that step size: the sideways velocity flips sign and
-- doubles every step until the ship is a hundred orders of magnitude away.
-- Minecraft runs at twenty ticks a second and so does this, however long the
-- scheduler step that got here was. A relay loop sleeping a whole second would
-- otherwise hand the physics a dt of 1.0, and explicit Euler on a drag of 2.2
-- per second is unstable at that step size: the sideways velocity flips sign and
-- doubles every step until the ship is a hundred orders of magnitude away.
local MAX_STEP = 0.05

-- Time moves once, for everybody.
--
-- The obvious way to write this scheduler is to advance the clock by each task's
-- own sleep as that task is resumed. That is wrong, and wrong in a way that only
-- shows up once something depends on how old a message is: with seven loops
-- running, the clock races ahead about seven times faster than any one loop's
-- own sleeps, so a relay broadcasting once a second looks, from the flight
-- computer, like a relay that speaks every fourteen seconds. Every link in the
-- program reads as permanently stale.
--
-- So the clock is advanced to the earliest thing waiting to wake, and everything
-- due at that moment wakes together, which is what a cooperative scheduler
-- actually does.
local function advanceTo(when)
    snapshotScreen()
    local secs = when - clock
    if secs < 0 then secs = 0 end
    clock = when
    while secs > 1e-9 do
        local step = secs > MAX_STEP and MAX_STEP or secs
        stepPhysics(step)
        secs = secs - step
    end
    frames = frames + 1
    if frames > options.frames then
        finished = true
        error("Terminated", 0)
    end
end

local function runAll(waitForAll, ...)
    local tasks = { ... }
    local routines, wakeAt, waiting = {}, {}, {}

    local function step(index, value)
        local ok, request = coroutine.resume(routines[index], value)
        if not ok then error(request, 0) end
        if coroutine.status(routines[index]) == "dead" then
            wakeAt[index], waiting[index] = nil, nil
            return
        end
        if type(request) == "table" and request.kind == "event" then
            waiting[index], wakeAt[index] = true, nil
        else
            waiting[index] = nil
            wakeAt[index] = clock + ((type(request) == "table" and request.secs) or 0.05)
        end
    end

    -- Time passing wakes everything that was due, whatever else the script
    -- happened to have queued. Leaving this out of any branch is a deadlock:
    -- a key waiting for a task that is asleep, and a task that is never woken
    -- because a key is waiting. That is what made the calibration scripts sit
    -- at their first prompt for the whole run.
    local function wakeDue()
        for index in ipairs(routines) do
            if wakeAt[index] and wakeAt[index] <= clock + 1e-9 then step(index, nil) end
        end
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
            end
        end
        if not alive then return 0 end

        local event = eventQueue[1]

        if event and event.wait then
            -- A pause the script asked for: the pilot sitting there watching the
            -- drift build up before pressing the next key.
            event.wait = event.wait - 1
            if event.wait <= 0 then table.remove(eventQueue, 1) end
            advanceTo(clock + 0.05)
            wakeDue()
        elseif event then
            local target = nil
            for index in ipairs(routines) do
                if waiting[index] then target = index; break end
            end
            if target then
                table.remove(eventQueue, 1)
                step(target, event)
                if event[1] == "key" or event[1] == "mouse_click" then
                    snapshotScreen()
                    shots[#shots + 1] = {
                        label = event[1] == "key" and "after key" or
                            ("click x=" .. tostring(event[3])),
                        rows = lastScreen,
                    }
                end
            else
                -- Something is queued and nobody is listening for it yet.
                advanceTo(clock + 0.05)
                wakeDue()
            end
        else
            local earliest = nil
            for index in ipairs(routines) do
                if wakeAt[index] and (earliest == nil or wakeAt[index] < earliest) then
                    earliest = wakeAt[index]
                end
            end
            if not earliest then
                -- Everything is blocked on an event and nobody is pressing
                -- anything. The world still turns.
                advanceTo(clock + 0.05)
            else
                advanceTo(earliest)
                wakeDue()
            end
        end
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
    -- Walk the five stage wizard with a pilot who agrees with everything: run
    -- the stage, accept the side it read, yes run the brake test.
    --
    -- The waits are what makes this work rather than decoration. A key pressed
    -- while a rung is settling is swallowed by the abort watcher the settle runs
    -- against, so every answer has to arrive after the measurement it answers
    -- has finished. Generous is safe: the wizard sits at its prompt.
    -- Nothing is on the network at boot. Every propeller on this ship is on a
    -- relay and they adopt about a second in, so a wizard started before that
    -- measures a ship with no propellers on it.
    queueWait(60)
    typeLine("cal")

    -- Sides: one prompt to spin each line and one to accept what it read.
    queueWait(20); queueEvent("key", keys.enter)
    for _ = 1, 5 do
        queueWait(20);  queueEvent("key", keys.enter)
        queueWait(230); queueEvent("key", keys.enter)
    end

    -- Balloon: a sweep and a refinement, and nothing to answer while it runs.
    queueWait(20); queueEvent("key", keys.enter)
    queueWait(900)

    -- Yaw, then forward. Both ladders, both ways, no questions.
    queueEvent("key", keys.enter)
    queueWait(1300)
    queueEvent("key", keys.enter)
    queueWait(1300)

    -- Braking: four run ups, each one confirmed on its own.
    queueEvent("key", keys.enter)
    for _ = 1, 4 do
        queueWait(20);  queueEvent("key", keys.enter)
        queueWait(420)
    end

    queueWait(20); queueEvent("key", keys.enter)
elseif options.script == "tabs" then
    -- Walk every tab and photograph each one, which is the cheapest way to
    -- catch a draw that indexes off the end of something.
    --
    -- The wait is the preflight gate, not decoration. Every propeller is on a
    -- relay and they adopt about a second after boot, so a leg ordered before
    -- then is a leg ordered on a ship with no propellers on it, and the gate
    -- refuses it with a popup.
    queueWait(60)
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
else

-- A short flight: save where we are, fly somewhere, watch it get there. The
-- wait first, because the relays carry every propeller and adopt about a second
-- in, and the preflight gate refuses a leg on a ship that has none yet.
queueWait(60)
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

-- == THE PHYSICS PROBE =======================================
--
-- The tank hull is new and nothing in src/ can command it yet, so without this
-- it would ship unmeasured. This drives the relays directly, through the same
-- rednet path the autopilot uses, and checks the ship does what the plan says
-- the ship does. It loads util.lua because the pose has to be read back by the
-- same code the autopilot reads it with, which is the only way the sign
-- conventions are actually tested rather than asserted twice in one voice.

if options.script == "physics" then
    local util = assert(loadfile(SRC .. "sc/util.lua"))()
    local failures = 0

    local function report(name, got, want, tolerance, unit)
        local ok = math.abs(got - want) <= tolerance
        if not ok then failures = failures + 1 end
        print(string.format("%-34s %8.2f  want %.2f +/- %.2f %s  %s",
            name, got, want, tolerance, unit or "", ok and "ok" or "FAILED"))
    end

    local function claim(name, ok, detail)
        if not ok then failures = failures + 1 end
        print(string.format("%-34s %-28s %s", name, detail or "", ok and "ok" or "FAILED"))
    end

    local function reset()
        sim.position = { x = 0, y = 120, z = 0 }
        sim.velocity = { x = 0, y = 0, z = 0 }
        sim.yaw, sim.yawRate, sim.pitch, sim.pitchRate = 0, 0, 0, 0
        sim.balloon = 0
        for _, unit in ipairs(turbineRelays) do
            for _, line in ipairs(unit.lines) do line.demand, line.actual = 0, 0 end
        end
    end

    -- Through rednet rather than by reaching into the tables, so a relay that
    -- ignores an order it should have obeyed shows up here as a ship that does
    -- not move.
    -- Addressed by the qualified name, which is the whole point: relay 2 and
    -- relay 3 both hold a Create_RotationSpeedController_0, and an order that
    -- named the bare one would turn two propellers on two computers.
    local function order(id, rpm) rednet.send(id, { cmd = "set", rpm = rpm }) end
    local function turbines(l1, l2, r1, r2)
        order(2, {
            ["2:Create_RotationSpeedController_0"] = l1,
            ["2:Create_RotationSpeedController_1"] = l2,
            ["2:Create_RotationSpeedController_2"] = r1,
            ["2:Create_RotationSpeedController_3"] = r2,
        })
    end
    local function main(rpm) order(3, { ["3:Create_RotationSpeedController_0"] = rpm }) end
    local function balloon(level) rednet.send(3, { cmd = "balloon", level = level }) end

    local function settle(secs)
        for _ = 1, math.floor(secs / 0.05) do stepPhysics(0.05) end
    end

    print("=== the pose, read back by util ===")
    -- A quaternion this program builds and util reads is the one place a sign
    -- error hides completely, because every other number stays plausible.
    for _, yaw in ipairs({ 0, 37, 90, -120, 179 }) do
        reset()
        sim.yaw = yaw
        report("yawOf at " .. yaw, util.yawOf(util.toQuat(sublevel.getLogicalPose().orientation)), yaw, 0.01, "deg")
    end

    print("")
    print("=== the tank turn ===")
    reset()
    -- Left hard forward and right hard back, which is what the mixer does with
    -- a positive differential, and what turns the ship to its own right.
    turbines(256, 256, -256, -256)
    settle(12)
    local fullRate = sim.yawRate
    report("full differential yaw rate", fullRate, 32.0, 3.0, "deg/s")
    -- CC: Sable reports radians about the world axes, and the y component runs
    -- opposite to this yaw convention. Getting that backwards turns the ship
    -- away from every target it is given.
    report("angular velocity y", sublevel.getAngularVelocity().y, -math.rad(fullRate), 0.01, "rad/s")

    reset()
    turbines(256, 256, 0, 0)
    settle(12)
    local leftOnly = math.abs(sim.yawRate)
    reset()
    turbines(0, 0, 256, 256)
    settle(12)
    local rightOnly = math.abs(sim.yawRate)
    report("left side authority", leftOnly, 15.2, 1.0, "deg/s")
    report("right side authority", rightOnly, 16.8, 1.0, "deg/s")
    claim("the sides differ", rightOnly > leftOnly + 0.5,
        string.format("%.2f against %.2f", rightOnly, leftOnly))

    print("")
    print("=== two relays, one protocol ===")
    local twoRelay, threeRelay = turbineRelays[1], turbineRelays[2]
    reset()
    -- Both relays hold a controller whose peripheral name ends _0. An order for
    -- one of them must leave the other alone, or the ship turns when it was told
    -- to go straight.
    order(2, { ["3:Create_RotationSpeedController_0"] = 256 })
    claim("a line belonging elsewhere is ignored", twoRelay.lines[1].actual == 0,
        "turbine _0 stayed at " .. tostring(twoRelay.lines[1].actual))
    reset()
    main(256)
    claim("the main turns when named", threeRelay.lines[1].actual == 256, "main at 256")
    claim("and no turbine turned with it", twoRelay.lines[1].actual == 0, "turbines at 0")

    print("")
    print("=== braking and the tip ===")
    reset()
    main(-256)
    settle(12)
    local mainPitch = math.abs(sim.pitch)
    reset()
    turbines(-256, -256, -256, -256)
    main(-256)
    settle(12)
    local allPitch = math.abs(sim.pitch)
    report("main alone, worst pitch", mainPitch, 6.4, 1.5, "deg")
    report("all five, worst pitch", allPitch, 16.0, 2.0, "deg")
    -- The whole reason braking is graduated: one configuration is inside the
    -- limit and the other is not, so there is a choice to make.
    claim("main is inside pitchLimit", mainPitch < 12.0, string.format("%.1f deg", mainPitch))
    claim("all five is past pitchLimit", allPitch > 12.0, string.format("%.1f deg", allPitch))

    print("")
    print("=== the balloon ===")
    reset()
    balloon(15)
    settle(20)
    report("strength 15, climb rate", sim.velocity.y, 1.78, 0.15, "m/s")
    reset()
    balloon(0)
    settle(20)
    report("strength 0, sink rate", sim.velocity.y, -1.78, 0.15, "m/s")

    local hover, best = nil, math.huge
    for level = 0, 15 do
        reset()
        balloon(level)
        settle(20)
        if math.abs(sim.velocity.y) < best then hover, best = level, math.abs(sim.velocity.y) end
    end
    claim("hovers somewhere in range", hover ~= nil and hover > 0 and hover < 15,
        "strength " .. tostring(hover))

    print("")
    if failures > 0 then
        print(failures .. " physics check(s) FAILED")
        error("the toy ship does not behave", 0)
    end
    print("every physics check passed")
    return
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
-- Attitude is the whole point of this hull, so it goes on the report beside the
-- position. Two propellers can read the same and be on different relays, so each
-- RPM is named by the side it turns rather than by its controller.
local rpms = {}
print(string.format("attitude  yaw %.1f (%.1f deg/s)  pitch %.1f", sim.yaw, sim.yawRate, sim.pitch))
print(string.format("balloon   %d of 15", sim.balloon))
for _, prop in ipairs(sim.props) do
    rpms[#rpms + 1] = prop.side .. "=" .. tostring(prop.line.actual)
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

    -- The wizard is only worth running headless if something reads what it
    -- wrote. The toy ship's own constants are the answer key: a run that files
    -- a turbine on the wrong side, or a top speed the hull cannot do, is a run
    -- that would fly the real ship into something.
    print("")
    print("=== what it measured, against the toy ship ===")
    local failures = 0
    local function claim(name, ok, detail)
        if not ok then failures = failures + 1 end
        print(string.format("%-34s %-24s %s", name, detail or "", ok and "ok" or "FAILED"))
    end

    local measured = textutils.unserialize(files["starcatcher/cal.cfg"] or "")
    if type(measured) ~= "table" then
        claim("the wizard wrote a file", false, "nothing readable")
    else
        local truth = {
            ["2:Create_RotationSpeedController_0"] = "left",
            ["2:Create_RotationSpeedController_1"] = "left",
            ["2:Create_RotationSpeedController_2"] = "right",
            ["2:Create_RotationSpeedController_3"] = "right",
            ["3:Create_RotationSpeedController_0"] = "main",
        }
        for name, side in pairs(truth) do
            local got = measured.sides and measured.sides[name]
            claim("side of " .. name:gsub("Create_RotationSpeedController", "rsc"),
                got ~= nil and got.side == side and got.reverse == false,
                (got and got.side or "nothing") .. ", wanted " .. side)
        end

        local function top(pair)
            local best = 0
            for _, way in ipairs({ "pos", "neg" }) do
                for _, rung in ipairs((pair or {})[way] or {}) do
                    if rung.speed > best then best = rung.speed end
                end
            end
            return best
        end

        local yawTop = top(measured.yawCurve)
        claim("top yaw rate", yawTop > 28 and yawTop < 34,
            string.format("%.1f deg/s, want 32", yawTop))
        local fwdTop = top(measured.fwdCurve)
        claim("top speed", fwdTop > 12.5 and fwdTop < 14.5,
            string.format("%.2f m/s, want 13.96", fwdTop))
        claim("hover strength", measured.altHover == 7 or measured.altHover == 8,
            tostring(measured.altHover) .. ", want 7 or 8")
        claim("both sides have an authority",
            measured.yawAuth ~= nil and (measured.yawAuth.left or 0) > 0
                and (measured.yawAuth.right or 0) > 0,
            string.format("%.4f and %.4f", (measured.yawAuth or {}).left or 0,
                (measured.yawAuth or {}).right or 0))
        -- The weaker side is the left one on this hull, by construction, and a
        -- run that got that backwards would compensate a turn the wrong way.
        claim("the left side is the weaker",
            ((measured.yawAuth or {}).left or 0) < ((measured.yawAuth or {}).right or 0),
            "left under right")

        local mainRungs = measured.brakeCurve and measured.brakeCurve.main
        local allRungs = measured.brakeCurve and measured.brakeCurve.all
        claim("both brake ladders measured",
            mainRungs and #mainRungs == 2 and allRungs and #allRungs == 2,
            string.format("%d main, %d all", mainRungs and #mainRungs or 0,
                allRungs and #allRungs or 0))
        if mainRungs and allRungs then
            claim("all five stops harder than the main",
                allRungs[#allRungs].speed > mainRungs[#mainRungs].speed,
                string.format("%.2f against %.2f", allRungs[#allRungs].speed,
                    mainRungs[#mainRungs].speed))
            claim("and noses over further doing it",
                (allRungs[#allRungs].pitch or 0) > (mainRungs[#mainRungs].pitch or 0),
                string.format("%.1f against %.1f deg", allRungs[#allRungs].pitch or 0,
                    mainRungs[#mainRungs].pitch or 0))
        end
    end

    print("")
    if failures > 0 then
        print("FAILED: " .. failures .. " of the measurements are wrong")
        error("calibration measured the wrong ship", 0)
    end
    print("every measurement matches the toy ship, over " .. frames .. " frames")
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

local target = { x = 120, y = 95, z = 60 }
local left = math.sqrt((target.x - sim.position.x) ^ 2
                     + (target.y - sim.position.y) ^ 2
                     + (target.z - sim.position.z) ^ 2)
local began = math.sqrt(target.x ^ 2 + (target.y - START_Y) ^ 2 + target.z ^ 2)
print(string.format("distance to the target: %.1f of the %.1f it started with", left, began))
print("")
if left >= began then
    print("FAILED: the autopilot did not close on its target")
    error("no progress", 0)
end
print("simulation finished cleanly after " .. frames .. " frames")
