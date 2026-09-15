-- sim.lua -- run starcatcher outside Minecraft.
--
-- Stubs enough of CC: Tweaked, CC: Sable and Create: Avionics to boot the real
-- program against a toy ship, and integrates a pose from whatever thrust the
-- autopilot asks for. Nothing here ships to the computer. It exists so that a
-- change to the control loop or the screen can be caught on the desktop instead
-- of at 300 blocks up.
--
-- There are two toy ships, because the program is mid rewrite and the two halves
-- need different vessels to be checkable at all.
--
--   omni  the hull the current src/ flies: five speed controllers wired to this
--         computer, four around the sides pushing north, south, east and west,
--         a big one underneath for lift, and an orientation that never changes.
--   tank  the hull the rewrite is for: nothing wired to this computer at all,
--         four turbines on one relay and a main propeller on another, all five
--         pointing the same way, steering on differential thrust and floating on
--         a balloon driven by a redstone strength signal.
--
-- `omni` stays the default until control.lua is rewritten in stage 4, because
-- until then nothing in src/ can produce a torque and the tank hull would simply
-- sit there. Pick the other one with --hull tank.
--
-- Run it with any Lua 5.2+ that can see this folder, or through tools/sim.js.
--
--   lua tools/sim.lua            boot, fly a leg, print the screen
--   lua tools/sim.lua --frames 400
--   lua tools/sim.lua --hull tank

local SRC = SIM_SRC or "../src/"

local options = { frames = 250, verbose = false, script = "fly", hull = "omni" }
for index = 1, #(arg or {}) do
    if arg[index] == "--frames" then options.frames = tonumber(arg[index + 1]) or 250 end
    if arg[index] == "--verbose" then options.verbose = true end
    if arg[index] == "--hull" then options.hull = tostring(arg[index + 1] or "omni") end
    if arg[index] == "--vcal" then options.script = "vcal"; options.frames = 4000 end
    if arg[index] == "--tabs" then options.script = "tabs"; options.frames = 400 end
if arg[index] == "--clicks" then options.script = "clicks"; options.frames = 400 end
    if arg[index] == "--cal" then options.script = "cal"; options.frames = 3000 end
    if arg[index] == "--test" then options.script = "test" end
    -- The physics probe is about the hull, so it picks its own ship and there is
    -- no sense in asking for it against the other one.
    if arg[index] == "--physics" then options.script = "physics"; options.hull = "tank" end
end

if options.hull ~= "omni" and options.hull ~= "tank" then
    error("no such hull: " .. options.hull .. ". It is omni or tank.", 0)
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

-- == THE OMNI HULL ===========================================
--
-- Four propellers around the hull, north, south, east and west, plus a big one
-- underneath doing lift. Each has a speed controller wired to this computer.
-- Drag is linear, thrust is proportional to RPM, and the big one is four times
-- the propeller of the small ones, which is what makes the velocity calibration
-- curves come out different per axis, which is the whole point of measuring
-- them.
--
-- This ship never turns, which is honest, because nothing in the autopilot that
-- flies it produces a torque.

local OMNI_LAYOUT = {
    { name = "Create_RotationSpeedController_0", axis = { 0, 0, -1 }, power = 0.0060 },
    { name = "Create_RotationSpeedController_1", axis = { 0, 0,  1 }, power = 0.0060 },
    { name = "Create_RotationSpeedController_2", axis = { 1, 0,  0 }, power = 0.0055 },
    { name = "Create_RotationSpeedController_3", axis = { -1, 0, 0 }, power = 0.0055 },
    { name = "Create_RotationSpeedController_4", axis = { 0, 1,  0 }, power = 0.0220 },
}

local OMNI_DRAG = 0.55

local function omniStep(dt)
    local ax, ay, az = 0, 0, 0
    for _, line in pairs(sim.lines) do
        ax = ax + line.axis[1] * line.rpm * line.power
        ay = ay + line.axis[2] * line.rpm * line.power
        az = az + line.axis[3] * line.rpm * line.power
    end
    local v = sim.velocity
    v.x = v.x + (ax - v.x * OMNI_DRAG) * dt
    v.y = v.y + (ay - v.y * OMNI_DRAG) * dt
    v.z = v.z + (az - v.z * OMNI_DRAG) * dt
    sim.position.x = sim.position.x + v.x * dt
    sim.position.y = sim.position.y + v.y * dt
    sim.position.z = sim.position.z + v.z * dt
end

local function omniPose()
    return { x = 0, y = 0, z = 0, w = 1 }
end

local function omniAngularVelocity()
    return { x = 0, y = 0, z = 0 }
end

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
-- Levers are signed, left negative and right positive, and a positive torque
-- raises yaw. Which of those the autopilot calls left is not written down
-- anywhere it can read: it has to spin each one and watch.

local TANK_TURBINE_POWER = 0.0045
local TANK_MAIN_POWER    = 0.0120
local TANK_LEVER_LEFT    = -1.45   -- the weaker side, on purpose
local TANK_LEVER_RIGHT   =  1.60

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

if options.hull == "tank" then
    stepPhysics, poseOf, angularVelocityOf = tankStep, tankPose, tankAngularVelocity
    sim.position = { x = 0, y = 120, z = 0 }
    sim.balloon = 8      -- roughly hovering, which is where a ship is found
    -- Create: Avionics puts gravity on this computer. The omni hull is left
    -- without it so that this stage changes nothing about how that ship reads.
    aero = { getGravity = function() return TANK_GRAVITY end }
else
    stepPhysics, poseOf, angularVelocityOf = omniStep, omniPose, omniAngularVelocity
    for index, entry in ipairs(OMNI_LAYOUT) do
        sim.lines[entry.name] = { rpm = 0, axis = entry.axis, power = entry.power, id = index }
    end
end

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
for _, entry in ipairs(options.hull == "tank" and {} or OMNI_LAYOUT) do
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
-- The altimeter is on the omni hull only. On the tank hull the flight computer
-- carries a modem and nothing else, so height comes off the pose like everything
-- else does, and readExtras is left with nothing to report.
if options.hull ~= "tank" then
    wrapped["create_avionics:altitude_sensor_0"] = {
        getHeight = function() return sim.position.y end,
        getAirPressure = function() return math.max(0, 1 - sim.position.y / 500) end,
        getVerticalSpeed = function() return sim.velocity.y end,
    }
end

local function SEED_CURVE(a, b, c)
    return string.format(
        "{ [1] = { rpm = 48, speed = %s }, [2] = { rpm = 152, speed = %s }, [3] = { rpm = 256, speed = %s } }",
        a, b, c)
end

-- A ship that has already been through `cal` and `vcal`, so a headless run can get
-- straight to the part worth testing. The directions match OMNI_LAYOUT above.
--
-- The tank hull is deliberately left uncalibrated. Its calibration is five
-- stages that do not exist yet, and seeding it in the old file's shape would
-- describe a ship of six directions that this one does not have.
if options.hull ~= "tank" then
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
local FUEL_RELAY_ID = options.hull == "tank" and 1 or 12

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
-- The omni hull has one such relay. The tank hull has two, and they name their
-- controllers exactly the way the real relay program does today, which is to say
-- by the bare peripheral name. Peripheral names are per network, so both relays
-- offer a Create_RotationSpeedController_0 and the flight computer cannot tell
-- them apart. That collision is not an oversight here: it is the defect stage 3
-- has to fix, and a simulator that quietly worked around it would hide the one
-- thing worth seeing.

local turbineRelays

if options.hull == "tank" then
    turbineRelays = {
        {
            id = 2, label = "turbines", capacity = 8192, overstressed = false,
            lines = {
                { name = "Create_RotationSpeedController_0", short = "#0", demand = 0, actual = 0 },
                { name = "Create_RotationSpeedController_1", short = "#1", demand = 0, actual = 0 },
                { name = "Create_RotationSpeedController_2", short = "#2", demand = 0, actual = 0 },
                { name = "Create_RotationSpeedController_3", short = "#3", demand = 0, actual = 0 },
            },
        },
        {
            -- The cruise relay also holds the redstone relay driving the balloon,
            -- which is why the balloon command has an address to go to at all.
            id = 3, label = "cruise", capacity = 8192, overstressed = false,
            balloon = true,
            lines = {
                { name = "Create_RotationSpeedController_0", short = "#0", demand = 0, actual = 0 },
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
else
    turbineRelays = {
        {
            id = 19, label = "turbines", capacity = 8192, overstressed = false,
            lines = {
                { name = "Create_RotationSpeedController_7", short = "#7", demand = 0, actual = 0 },
                { name = "Create_RotationSpeedController_8", short = "#8", demand = 0, actual = 0 },
            },
        },
    }
end

local function turbineMessage(unit)
    local list, drawn = {}, 0
    for index, entry in ipairs(unit.lines) do
        -- Stress rises with how hard the turbines are being driven, which is the
        -- only part of Create's stress model worth pretending about here.
        drawn = drawn + math.abs(entry.actual) * 12
        list[index] = { name = entry.name, short = entry.short,
                        demand = entry.demand, actual = entry.actual }
    end
    return {
        v = 1, id = unit.id, label = unit.label, clock = clock,
        lines = list, maxRpm = 256,
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
            local rpm = message.rpm[entry.name]
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
    local function order(id, rpm) rednet.send(id, { cmd = "set", rpm = rpm }) end
    local function turbines(l1, l2, r1, r2)
        order(2, { Create_RotationSpeedController_0 = l1, Create_RotationSpeedController_1 = l2,
                   Create_RotationSpeedController_2 = r1, Create_RotationSpeedController_3 = r2 })
    end
    local function main(rpm) order(3, { Create_RotationSpeedController_0 = rpm }) end
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
    turbines(-256, -256, 256, 256)
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
local rpms = {}
if options.hull == "tank" then
    -- Attitude is the whole point of this hull, so it goes on the report beside
    -- the position. Two propellers can read the same and be on different relays,
    -- so each RPM is named by the side it turns rather than by its controller.
    print(string.format("attitude  yaw %.1f (%.1f deg/s)  pitch %.1f", sim.yaw, sim.yawRate, sim.pitch))
    print(string.format("balloon   %d of 15", sim.balloon))
    for _, prop in ipairs(sim.props) do
        rpms[#rpms + 1] = prop.side .. "=" .. tostring(prop.line.actual)
    end
else
    for _, entry in ipairs(OMNI_LAYOUT) do
        -- tostring rather than %d: a nil here means the run already failed, and
        -- a report that crashes on its way to saying so tells you nothing.
        rpms[#rpms + 1] = entry.name:match("_(%d+)$") .. "=" .. tostring(sim.lines[entry.name].rpm)
    end
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

-- The tank hull has no arrival assertion yet, and saying so is the point. Its
-- control loop is stage 4: until then every propeller it owns is on a relay this
-- program cannot route to, so the ship sits where it was left and a FAILED here
-- would be the harness reporting a stage that has not been written as a bug.
-- Turn this into the same assertion the omni hull gets when control.lua lands.
if options.hull == "tank" then
    print("the tank hull is not flown yet: control.lua is stage 4")
    print("simulation finished cleanly after " .. frames .. " frames")
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
