-- Veilpiercer autopilot, bare bones.
-- Position and orientation come from CC: Sable's sublevel global. Every Create
-- rotation speed controller on the network is found automatically and driven as
-- one propeller line, which is Create: Avionics. No waypoint queue, no docking,
-- no fleet link yet.
--
-- Nothing about the ship is hardcoded. Which controller is which, and which way
-- each one pushes, is learned by the calibration on [C] and kept in
-- autopilot.cfg. Run "autopilot --test" to check the math without a ship.

local CONFIG_FILE = "autopilot.cfg"

-- The vocabulary calibration answers in. These are body frame directions, the
-- ship's own, so they match world directions only while it sits at identity
-- orientation.
local DIRECTIONS = {
    up    = {  0,  1,  0 },
    down  = {  0, -1,  0 },
    north = {  0,  0, -1 },
    south = {  0,  0,  1 },
    east  = {  1,  0,  0 },
    west  = { -1,  0,  0 },
    none  = {  0,  0,  0 },
}

local DIR_ORDER = { "up", "down", "north", "south", "east", "west", "none" }

local MAX_RPM     = 256     -- the speed controller clamps here itself
local MIN_RPM     = 24      -- below this a propeller is not worth spinning
local GAIN        = 8.0     -- RPM per block of position error
local DAMP        = 40.0    -- RPM per m/s of closing speed, kills the overshoot
local ARRIVE_DIST = 6.0
local TICK        = 0.4

local CAL_RPM       = 128   -- what one propeller spins at while being calibrated
local CAL_SAMPLE    = 0.3   -- seconds between live drift readings
local CAL_MIN_DRIFT = 0.15  -- m/s below which a drift is not worth reading

-- Rotate v by the quaternion (ux, uy, uz, w): v + 2u x (u x v + w v).
-- Negate the vector part to rotate the other way, which is what turns a world
-- vector into a body frame one.
local function qRotate(ux, uy, uz, w, vx, vy, vz)
    local tx = uy * vz - uz * vy + w * vx
    local ty = uz * vx - ux * vz + w * vy
    local tz = ux * vy - uy * vx + w * vz
    return vx + 2 * (uy * tz - uz * ty),
           vy + 2 * (uz * tx - ux * tz),
           vz + 2 * (ux * ty - uy * tx)
end

local function worldToBody(q, vx, vy, vz)
    return qRotate(-q.x, -q.y, -q.z, q.w, vx, vy, vz)
end

-- CC: Sable has shipped more than one shape for these. A vector is {x, y, z} in
-- the current source and an array in some builds, and a quaternion is either
-- flat {x, y, z, w} or the CC: Advanced Math pair of a scalar a and a vector v.
-- Read whichever turned up rather than guessing from the version.
local function toVec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v.x, v.y, v.z
    if type(x) ~= "number" then x, y, z = v[1], v[2], v[3] end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function toQuat(q)
    if type(q) ~= "table" then return nil end
    local x, y, z, w
    if type(q.w) == "number" and type(q.x) == "number" then
        x, y, z, w = q.x, q.y, q.z, q.w
    elseif type(q.a) == "number" and type(q.v) == "table" then
        local v = toVec(q.v)
        if not v then return nil end
        x, y, z, w = v.x, v.y, v.z, q.a
    elseif type(q[1]) == "number" and type(q[4]) == "number" then
        x, y, z, w = q[1], q[2], q[3], q[4]
    else
        return nil
    end
    if type(y) ~= "number" or type(z) ~= "number" then return nil end
    -- qRotate is only a rotation for a unit quaternion, anything else scales
    -- the vector it is given.
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-9 then return nil end
    return { x = x / len, y = y / len, z = z / len, w = w / len }
end

-- For the screen when a shape is not understood, so the keys can be read off
-- rather than guessed at.
local function keyList(t)
    if type(t) ~= "table" then return type(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return "{" .. table.concat(keys, ",") .. "}"
end

-- One propeller's share of the demand: proportional on position error, damped
-- on the speed already built up along the same axis. axis.reverse is the spin
-- correction, axis[1..3] is where the thrust goes once that is applied.
local function demandFor(axis, ex, ey, ez, vx, vy, vz)
    local along = ex * axis[1] + ey * axis[2] + ez * axis[3]
    local closing = vx * axis[1] + vy * axis[2] + vz * axis[3]
    local rpm = along * GAIN - closing * DAMP
    if math.abs(rpm) < MIN_RPM then return 0 end
    if rpm > MAX_RPM then rpm = MAX_RPM elseif rpm < -MAX_RPM then rpm = -MAX_RPM end
    if axis.reverse then rpm = -rpm end
    return math.floor(rpm + 0.5)
end

-- A calibrated line is one of the named directions plus which way it has to
-- spin to get there. DIRECTIONS is shared, so never hand it out to be tagged.
local function makeAxis(direction, reverse)
    local d = DIRECTIONS[direction]
    return { d[1], d[2], d[3], reverse = reverse or false }
end

-- Which named direction a measured drift is closest to, for calibration to
-- offer as its suggested answer.
local function dominantDirection(bx, by, bz)
    if math.sqrt(bx * bx + by * by + bz * bz) < CAL_MIN_DRIFT then return "none" end
    local best, bestDot = "none", 0
    for _, name in ipairs(DIR_ORDER) do
        local d = DIRECTIONS[name]
        local dot = bx * d[1] + by * d[2] + bz * d[3]
        if dot > bestDot then best, bestDot = name, dot end
    end
    return best
end

local function labelFor(axis)
    if not axis then return "?" end
    for _, name in ipairs(DIR_ORDER) do
        local d = DIRECTIONS[name]
        if axis[1] == d[1] and axis[2] == d[2] and axis[3] == d[3] then return name end
    end
    return "custom"
end

-- Read the saved axes back, but only for the controllers actually on the
-- network now. Anything on the network with no usable entry comes back in the
-- second return so the caller can say what needs calibrating.
local function parseConfig(data, names)
    local axes, missing = {}, {}
    for _, name in ipairs(names) do
        local v = type(data) == "table" and data[name] or nil
        if type(v) == "table" and type(v[1]) == "number"
                and type(v[2]) == "number" and type(v[3]) == "number" then
            axes[name] = { v[1], v[2], v[3], reverse = v.reverse == true }
        else
            missing[#missing + 1] = name
        end
    end
    return axes, missing
end

-- Trailing number off a peripheral name, so the screen can say "#3" instead of
-- "Create_RotationSpeedController_3".
local function shortName(name)
    return "#" .. (name:match("_(%d+)$") or name)
end

local function selfTest()
    local function near(a, b, what)
        assert(math.abs(a - b) < 1e-6, string.format("%s: got %.6f want %.6f", what, a, b))
    end

    local x, y, z = qRotate(0, 0, 0, 1, 3, -4, 5)
    near(x, 3, "identity x") near(y, -4, "identity y") near(z, 5, "identity z")

    -- 90 degrees about +Y takes body +Z to world +X.
    local h = math.sqrt(0.5)
    x, y, z = qRotate(0, h, 0, h, 0, 0, 1)
    near(x, 1, "yaw90 x") near(y, 0, "yaw90 y") near(z, 0, "yaw90 z")

    -- So a world +X vector read on that ship is body +Z.
    local q = { x = 0, y = h, z = 0, w = h }
    x, y, z = worldToBody(q, 1, 0, 0)
    near(x, 0, "toBody x") near(y, 0, "toBody y") near(z, 1, "toBody z")

    -- Round trip through both directions returns the vector.
    x, y, z = qRotate(q.x, q.y, q.z, q.w, worldToBody(q, 2, 3, -7))
    near(x, 2, "round x") near(y, 3, "round y") near(z, -7, "round z")

    -- Every quaternion shape CC: Sable has handed out reads the same rotation.
    local flat = toQuat({ x = 0, y = h, z = 0, w = h })
    local pair = toQuat({ a = h, v = { x = 0, y = h, z = 0 } })
    local list = toQuat({ 0, h, 0, h })
    for _, shape in ipairs({ flat, pair, list }) do
        local bx, by, bz = worldToBody(shape, 1, 0, 0)
        near(bx, 0, "shape x") near(by, 0, "shape y") near(bz, 1, "shape z")
    end
    assert(toQuat({ a = h, v = { 0, h, 0 } }), "an array vector part still reads")
    assert(toQuat("nope") == nil, "junk is not a quaternion")
    assert(toQuat({ foo = 1 }) == nil, "an unknown shape is refused")
    assert(toQuat({ x = 0, y = 0, z = 0, w = 0 }) == nil, "a zero quaternion is refused")
    near(toQuat({ x = 0, y = 2, z = 0, w = 0 }).y, 1, "a long quaternion is normalized")

    assert(toVec({ x = 1, y = 2, z = 3 }).z == 3, "a named vector reads")
    assert(toVec({ 1, 2, 3 }).z == 3, "an array vector reads")
    assert(toVec({ x = 1, y = 2 }) == nil, "a short vector is refused")
    assert(keyList({ a = 1, v = 2 }) == "{a,v}", "keys are listed for the screen")
    assert(keyList(nil) == "nil", "and a non table says so")

    -- Target 100 blocks east, level ship, at rest.
    assert(demandFor(DIRECTIONS.east, 100, 0, 0, 0, 0, 0) == MAX_RPM, "east saturates")
    assert(demandFor(DIRECTIONS.west, 100, 0, 0, 0, 0, 0) == -MAX_RPM, "west opposes east")
    assert(demandFor(DIRECTIONS.north, 100, 0, 0, 0, 0, 0) == 0, "north ignores it")
    assert(demandFor(DIRECTIONS.up, 0, 4, 0, 0, 0, 0) == 32, "up tracks altitude")
    assert(demandFor(DIRECTIONS.up, 0, 2, 0, 0, 0, 0) == 0, "small error stays under MIN_RPM")
    assert(demandFor(DIRECTIONS.none, 100, 100, 100, 0, 0, 0) == 0, "an unused propeller idles")

    -- A propeller that pushes down is driven backwards to climb.
    assert(demandFor(DIRECTIONS.down, 0, 4, 0, 0, 0, 0) == -32, "a down propeller reverses")

    -- A propeller wired to spin the other way does the same job at the opposite
    -- sign, and that is on top of where it points, not instead of it.
    assert(demandFor(makeAxis("up"), 0, 4, 0, 0, 0, 0) == 32, "plain up")
    assert(demandFor(makeAxis("up", true), 0, 4, 0, 0, 0, 0) == -32, "reversed up")
    assert(demandFor(makeAxis("down", true), 0, 4, 0, 0, 0, 0) == 32, "reversed down")
    assert(DIRECTIONS.up.reverse == nil, "the shared direction is never tagged")
    assert(labelFor(makeAxis("up", true)) == "up", "reversing does not change the label")

    -- Already closing fast, so damping pulls the demand back.
    local still = demandFor(DIRECTIONS.east, 5, 0, 0, 0, 0, 0)
    local moving = demandFor(DIRECTIONS.east, 5, 0, 0, 3, 0, 0)
    assert(moving < still, "damping cuts the demand")

    assert(dominantDirection(0, 0, -2.4) == "north", "reads a north drift")
    assert(dominantDirection(-1.1, 0.2, 0.3) == "west", "reads the dominant axis")
    assert(dominantDirection(0.01, 0, -0.02) == "none", "ignores noise")

    assert(labelFor({ 0, 0, 1 }) == "south", "labels a known axis")
    assert(labelFor({ 0.5, 0.5, 0 }) == "custom", "does not invent a label")
    assert(labelFor(nil) == "?", "an uncalibrated line has no label")

    local names = { "a", "b", "c" }
    local axes, missing = parseConfig(nil, names)
    assert(next(axes) == nil and #missing == 3, "no config means everything is missing")
    axes, missing = parseConfig({ a = { 0, 1, 0 }, b = "junk", c = { 1, 2 } }, names)
    assert(axes.a[2] == 1, "a good entry loads")
    assert(#missing == 2 and missing[1] == "b" and missing[2] == "c", "bad entries are named")
    axes, missing = parseConfig({ a = { 0, 1, 0 }, z = { 1, 0, 0 } }, { "a" })
    assert(#missing == 0 and axes.z == nil, "a controller that left is dropped")
    assert(axes.a.reverse == false, "an old config with no reverse flag still loads")
    axes = parseConfig({ a = { 0, 1, 0, reverse = true } }, { "a" })
    assert(axes.a.reverse == true, "and the flag round trips")

    assert(shortName("Create_RotationSpeedController_3") == "#3", "short name")

    print("all tests passed")
end

local args = { ... }
if args[1] == "--test" then
    selfTest()
    return
end

local props, order, axes = {}, {}, {}
local target, running = nil, false
local lastSent, lastRpm = {}, {}
local prompting, controlIdle = false, false

-- Anything on the network that can be told a target speed is a propeller line.
-- Matching on the methods rather than the type string keeps this working for
-- peripherals that report more than one type.
local function findControllers()
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.setTargetSpeed and p.getTargetSpeed then
            props[name] = p
            order[#order + 1] = name
        end
    end
    table.sort(order)
    return #order
end

-- Every sublevel call is mainThread and errors outright when the computer is
-- not on an assembled sub-level, so the whole read goes through pcall. The
-- second return is what to put on the screen when it fails.
local function readState()
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok then return nil, "NOT ON A SUB-LEVEL" end
    if type(pose) ~= "table" then return nil, "POSE IS NOT A TABLE" end
    local position = toVec(pose.position)
    if not position then return nil, "POSITION SHAPE " .. keyList(pose.position) end
    local orientation = toQuat(pose.orientation)
    if not orientation then return nil, "ORIENTATION SHAPE " .. keyList(pose.orientation) end
    local velocity = { x = 0, y = 0, z = 0 }
    local okVel, raw = pcall(sublevel.getLinearVelocity)
    if okVel then velocity = toVec(raw) or velocity end
    return { position = position, orientation = orientation, velocity = velocity }
end

local function bodyVelocity()
    local state = readState()
    if not state then return nil end
    local v = state.velocity
    local x, y, z = worldToBody(state.orientation, v.x, v.y, v.z)
    return { x = x, y = y, z = z }
end

-- setTargetSpeed yields a server tick each, so send only what changed and send
-- those together.
local function flush(demands)
    local calls = {}
    for name, rpm in pairs(demands) do
        lastRpm[name] = rpm
        if lastSent[name] ~= rpm then
            lastSent[name] = rpm
            calls[#calls + 1] = function() props[name].setTargetSpeed(rpm) end
        end
    end
    if #calls > 0 then parallel.waitForAll(table.unpack(calls)) end
end

local function allStop()
    local zero = {}
    for name in pairs(props) do zero[name] = 0 end
    flush(zero)
end

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then return parseConfig(nil, order) end
    local handle = fs.open(CONFIG_FILE, "r")
    if not handle then return parseConfig(nil, order) end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    return parseConfig(data, order)
end

local function saveConfig()
    local handle, reason = fs.open(CONFIG_FILE, "w")
    if not handle then
        printError("Could not write " .. CONFIG_FILE .. ": " .. tostring(reason))
        return false
    end
    handle.write(textutils.serialize(axes))
    handle.close()
    return true
end

local function askYesNo(question, default)
    while true do
        write(question .. (default and " [Y/n] " or " [y/N] "))
        local answer = read():lower()
        if answer == "" then return default end
        if answer == "y" or answer == "yes" then return true end
        if answer == "n" or answer == "no" then return false end
    end
end

local function askDirection(question, default)
    while true do
        write(question .. " (" .. default .. ") ")
        local answer = read()
        if answer == "" then return default end
        answer = answer:lower()
        if DIRECTIONS[answer] then return answer end
        if answer == "skip" then return nil end
        print("  one of: " .. table.concat(DIR_ORDER, ", ") .. ", or skip")
    end
end

-- Spins one propeller and keeps spinning it until the user presses Enter, live
-- drift on screen the whole time. The reading kept is the largest one seen, not
-- whatever happened to be on screen at the moment of the keypress.
local function spinAndWatch(name, base, sign)
    local bestX, bestY, bestZ, bestMag = 0, 0, 0, 0

    local function watch()
        local _, line = term.getCursorPos()
        while true do
            local now = bodyVelocity()
            term.setCursorPos(1, line)
            term.clearLine()
            if now and base then
                local dx, dy, dz = now.x - base.x, now.y - base.y, now.z - base.z
                local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
                if mag > bestMag then bestX, bestY, bestZ, bestMag = dx, dy, dz, mag end
                write(string.format("  drift %+.2f %+.2f %+.2f, looks like %s",
                    dx, dy, dz, dominantDirection(dx, dy, dz)))
            else
                write("  no pose read, so no measurement, use your eyes")
            end
            sleep(CAL_SAMPLE)
        end
    end

    -- Enter only. A letter key would leave its char event queued for the read
    -- that comes next and type itself into the answer.
    local function untilEnter()
        repeat
            local _, key = os.pullEvent("key")
        until key == keys.enter
    end

    local demands = {}
    for _, other in ipairs(order) do demands[other] = 0 end
    demands[name] = CAL_RPM * sign
    flush(demands)
    parallel.waitForAny(watch, untilEnter)
    allStop()
    print("")
    return bestX, bestY, bestZ, bestMag
end

local function calibrate()
    term.clear()
    term.setCursorPos(1, 1)
    print("Calibration, " .. #order .. " propeller lines found.")
    print("Each one runs alone until you stop it. The ship moves,")
    print("so give it clear air on every side.")

    for index, name in ipairs(order) do
        print("")
        print(string.format("[%d/%d] %s  now: %s",
            index, #order, shortName(name), labelFor(axes[name])))
        write("  [Enter] spin it, s skip, q finish: ")
        local choice = read():lower()
        if choice == "q" then break end
        if choice ~= "s" then
            local sign = 1
            local dx, dy, dz, mag = spinAndWatch(name, bodyVelocity(), sign)

            -- Which way is forward is a property of the propeller, not of where
            -- it sits, so it gets asked before anything is read off the drift.
            if not askYesNo("  Is it spinning the right way?", true) then
                sign = -1
                print("  reversed, watch it again")
                dx, dy, dz, mag = spinAndWatch(name, bodyVelocity(), sign)
            end

            local guess = mag > 0 and dominantDirection(dx, dy, dz) or "none"
            if mag > 0 then
                print(string.format("  strongest drift %+.2f %+.2f %+.2f", dx, dy, dz))
            end
            local answer = askDirection("  Which way did it push the ship?", guess)
            if answer then axes[name] = makeAxis(answer, sign < 0) end
        end
    end

    print("")
    for _, name in ipairs(order) do
        local axis = axes[name]
        print(string.format("%-4s %-6s %s", shortName(name), labelFor(axis),
            axis and axis.reverse and "reversed" or ""))
    end
    if saveConfig() then print("Saved to " .. CONFIG_FILE) end
    write("Enter to return: ")
    read()
end

local function draw(state, status, dist)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== AVIONICS AUTOPILOT (bare bones) ===")
    print(string.format("Status : %s", status))
    if state then
        local p, v = state.position, state.velocity
        print(string.format("Pos    : %.1f, %.1f, %.1f", p.x, p.y, p.z))
        print(string.format("Speed  : %.2f m/s", math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)))
    else
        print("Pos    : ---")
        print("Speed  : ---")
    end
    if target then
        print(string.format("Target : %.1f, %.1f, %.1f", target.x, target.y, target.z))
        print(string.format("Dist   : %.1f m", dist or 0))
    else
        print("Target : NONE")
        print("Dist   : ---")
    end
    print("---------------------------------------")
    for _, name in ipairs(order) do
        local axis = axes[name]
        print(string.format("%-4s %-6s %-4s %5d rpm", shortName(name), labelFor(axis),
            axis and axis.reverse and "rev" or "", lastRpm[name] or 0))
    end
    print("---------------------------------------")
    print("[T] target [S] start/stop [C] calibrate [Q] quit")
end

local function control()
    while true do
        if prompting then
            controlIdle = true
            sleep(0.1)
        else
            controlIdle = false
            local state, why = readState()
            local status, dist = "IDLE", nil

            if not state then
                status = why
                allStop()
            elseif not running or not target then
                status = target and "READY" or "NO TARGET"
                allStop()
            else
                local p = state.position
                local dx, dy, dz = target.x - p.x, target.y - p.y, target.z - p.z
                dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist < ARRIVE_DIST then
                    status = "ARRIVED"
                    running = false
                    allStop()
                else
                    status = "FLYING"
                    local v = state.velocity
                    local ex, ey, ez = worldToBody(state.orientation, dx, dy, dz)
                    local bvx, bvy, bvz = worldToBody(state.orientation, v.x, v.y, v.z)
                    local demands = {}
                    for _, name in ipairs(order) do
                        demands[name] = demandFor(axes[name] or DIRECTIONS.none,
                            ex, ey, ez, bvx, bvy, bvz)
                    end
                    flush(demands)
                end
            end

            if not prompting then draw(state, status, dist) end
            sleep(TICK)
        end
    end
end

-- Anything that reads the keyboard has to own the screen while it does. The
-- control loop redraws every TICK and draw() starts with term.clear(), so an
-- unguarded prompt gets wiped out from under whatever is being typed. Waiting
-- for controlIdle also keeps calibration out of the middle of a batch of
-- setTargetSpeed calls, which yield.
local function withScreen(fn)
    running = false
    prompting = true
    while not controlIdle do sleep(0.05) end
    local ok, err = pcall(fn)
    pcall(allStop)
    prompting = false
    if not ok and err ~= "Terminated" then printError(err) end
end

-- Printed under the live screen rather than over a cleared one, so the position
-- being flown from stays readable while the target is typed.
local function askTarget()
    print("")
    print("Set target, anything but a number cancels")
    write("X: ")
    local x = tonumber(read())
    write("Y: ")
    local y = tonumber(read())
    write("Z: ")
    local z = tonumber(read())
    if x and y and z then target = { x = x, y = y, z = z } end
end

local function input()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.s then
            running = not running
        elseif key == keys.q then
            return
        elseif key == keys.c then
            withScreen(calibrate)
        elseif key == keys.t then
            withScreen(askTarget)
        end
    end
end

if type(sublevel) ~= "table" then
    error("CC: Sable is not loaded, this computer has no sublevel API", 0)
end

if findControllers() == 0 then
    error("No rotation speed controllers on the network, check the modems", 0)
end

local missing
axes, missing = loadConfig()
if #missing > 0 then
    print(#missing .. " of " .. #order .. " propeller lines are not calibrated.")
    print("Press [C] in the autopilot to calibrate. Until then they stay stopped.")
    print("")
    write("Enter to continue: ")
    read()
end

local ok, err = pcall(parallel.waitForAny, control, input)
-- setTargetSpeed yields, and a yield after Ctrl+T raises Terminated again, so
-- the stop has to survive that or the propellers keep spinning.
pcall(allStop)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
