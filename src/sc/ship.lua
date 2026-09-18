-- ship.lua -- what is bolted to this computer, and what the ship is doing.
--
-- Nothing about the vessel is written into the program. Everything here is
-- found at boot by asking the network what it can do, never by matching on a
-- peripheral type string, because a Create: Avionics block reports several
-- types and the set has changed between builds.
--
-- Propeller lines are rotation speed controllers. Propeller bearings are read
-- only: they are the instrument panel, not the actuator. The link between the
-- two is the kinetic graph itself, through getSubnetworkAnchorId, so a bearing
-- knows which controller drives it without anybody writing it down.

local util, config = ...

local ship = {}

ship.lines = {}        -- name -> { wrap = peripheral, bearings = {...}, ... }
ship.order = {}        -- line names, sorted, the order everything iterates in
ship.bearings = {}     -- every propeller bearing found, wrapped
ship.altimeter = nil
ship.velSensors = {}   -- axis -> wrapped velocity_sensor, when any are fitted
ship.hasSublevel = false

ship.lastSent = {}     -- what was last pushed at each line
ship.lastRpm = {}      -- what the controller last decided, sent or not

-- Lines that belong to a relay computer instead of to this one. The mixer, the
-- calibration and the screen cannot tell the difference: a line is a name that
-- takes an RPM, and whether that RPM crosses a wired network or a radio is the
-- business of ship.flush and nothing else.
--
-- The name a relay line is filed under is the qualified one the relay itself
-- advertises, "<relay id>:<peripheral name>". Peripheral names are per network,
-- so two relays both offer a Create_RotationSpeedController_0, and keying on the
-- bare name files two propellers as one and flies the ship on half its engines.
ship.remoteLines = {}  -- name -> { relay = id, short = "#2.3" }
ship.sendRemote = nil  -- set by sc/turbine.lua; nil means there is no relay

-- The last pose headings read, each with the clock it was read at. This is
-- what a yaw rate is worked out from on the ticks where the physics engine has
-- stopped reporting one. readState fills it for nothing, since the heading is
-- something it works out anyway.
ship.yawTrail = {}

-- == DISCOVERY ===============================================

local function methodsOf(p)
    local set = {}
    for k, v in pairs(p) do if type(v) == "function" then set[k] = true end end
    return set
end

-- Every peripheral is wrapped once, here, and never re-wrapped in a loop.
function ship.discover()
    ship.lines, ship.order, ship.bearings, ship.velSensors = {}, {}, {}, {}
    ship.altimeter = nil

    for _, name in ipairs(peripheral.getNames()) do
        local ok, p = pcall(peripheral.wrap, name)
        if ok and type(p) == "table" then
            local m = methodsOf(p)

            if m.setTargetSpeed and m.getTargetSpeed then
                ship.lines[name] = {
                    name = name,
                    wrap = p,
                    bearings = {},
                    kinetic = m.getSelfId and true or false,
                }
                ship.order[#ship.order + 1] = name
            end

            if m.getThrust and m.getThrustVector then
                ship.bearings[#ship.bearings + 1] = { name = name, wrap = p, methods = m }
            end

            if m.getHeight and m.getAirPressure and not ship.altimeter then
                ship.altimeter = p
            end

            if m.getVelocity and m.getAxis and not m.getThrust then
                local okAxis, axis = pcall(p.getAxis)
                if okAxis and type(axis) == "string" then
                    ship.velSensors[axis:lower()] = p
                end
            end
        end
    end

    ship.hasSublevel = type(sublevel) == "table"
    -- A rescan wipes the table above, so the relay's lines are put back before
    -- the sort. Losing them here would drop half the ship every time someone
    -- plugged a peripheral in.
    for name, entry in pairs(ship.remoteLines) do ship.addRemote(name, entry) end
    table.sort(ship.order)
    ship.linkBearings()
    return #ship.order
end

-- A line on a relay computer. It has no wrap, so everything that would call one
-- is guarded on line.remote, and its telemetry is whatever the relay last said
-- rather than whatever a getter returns.
function ship.addRemote(name, entry)
    ship.remoteLines[name] = entry
    if not ship.lines[name] then
        ship.lines[name] = {
            name = name,
            wrap = nil,
            remote = true,
            relay = entry.relay,
            -- The bare peripheral name, for the one place it is still wanted:
            -- telling a human which block on that computer's network this is.
            port = tostring(name):match("^%d+:(.+)$") or name,
            short = entry.short,
            bearings = {},
            kinetic = false,
        }
        ship.order[#ship.order + 1] = name
        table.sort(ship.order)
        return true
    end
    ship.lines[name].remote = true
    ship.lines[name].relay = entry.relay
    return false
end

-- Told by sc/turbine.lua when the relay stops naming a line, which means the
-- controller was broken or the relay was rebuilt. Leaving a phantom line in the
-- mixer would have the autopilot dividing thrust between propellers that are
-- not there.
function ship.dropRemote(name)
    if not ship.remoteLines[name] then return false end
    ship.remoteLines[name] = nil
    ship.lines[name] = nil
    ship.lastSent[name] = nil
    ship.lastRpm[name] = nil
    for index, other in ipairs(ship.order) do
        if other == name then table.remove(ship.order, index); break end
    end
    return true
end

-- A bearing reports the id of the block that anchors its speed zone. For a
-- propeller driven through a speed controller that anchor is the controller,
-- so this hands every line the list of propellers it actually turns without
-- anyone having to say so. Wrapped in pcall throughout: a plain Create speed
-- controller with no Avionics on top has none of these methods.
function ship.linkBearings()
    local byId = {}
    for _, name in ipairs(ship.order) do
        local line = ship.lines[name]
        line.bearings = {}
        if line.kinetic and line.wrap then
            local ok, id = pcall(line.wrap.getSelfId)
            if ok and id ~= nil then
                line.id = id
                byId[id] = line
            end
        end
    end

    for _, bearing in ipairs(ship.bearings) do
        bearing.line = nil
        if bearing.methods.getSubnetworkAnchorId then
            local ok, anchor = pcall(bearing.wrap.getSubnetworkAnchorId)
            if ok and anchor ~= nil and byId[anchor] then
                local line = byId[anchor]
                line.bearings[#line.bearings + 1] = bearing
                bearing.line = line.name
            end
        end
    end

    -- Sail power is how big a propeller is. The one line with markedly more of
    -- it than the rest is the main propeller, and the screen says so.
    local best, bestPower = nil, 0
    for _, name in ipairs(ship.order) do
        local line = ship.lines[name]
        line.sailPower = nil
        local total = 0
        for _, bearing in ipairs(line.bearings) do
            if bearing.methods.getSailPower then
                local ok, power = pcall(bearing.wrap.getSailPower)
                if ok and type(power) == "number" then total = total + power end
            end
        end
        if #line.bearings > 0 then line.sailPower = total end
        if total > bestPower then best, bestPower = name, total end
    end
    for _, name in ipairs(ship.order) do ship.lines[name].main = false end
    if best and bestPower > 0 then ship.lines[best].main = true end
end

-- == STATE ===================================================

-- Every sublevel call is mainThread and errors outright when the computer is
-- not on an assembled sub-level, so the whole read goes through pcall. The
-- second return is what to put on the screen when it fails.
function ship.readState()
    if not ship.hasSublevel then return nil, "NO CC: SABLE" end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok then return nil, "NOT ON A SUB-LEVEL" end
    if type(pose) ~= "table" then return nil, "POSE IS NOT A TABLE" end

    local position = util.toVec(pose.position)
    if not position then return nil, "POSITION SHAPE " .. util.keyList(pose.position) end
    local orientation = util.toQuat(pose.orientation)
    if not orientation then return nil, "ORIENTATION SHAPE " .. util.keyList(pose.orientation) end

    -- A failed velocity read leaves zeroes while the pose still succeeds, and a
    -- zero velocity is exactly what a ship at rest looks like. So whether the
    -- read worked travels with the state: a controller that cannot tell the two
    -- apart will call a moving ship stopped and freeze its thrust.
    local velocity, velocityOk = { x = 0, y = 0, z = 0 }, false
    local okVel, raw = pcall(sublevel.getLinearVelocity)
    if okVel then
        local read = util.toVec(raw)
        if read then velocity, velocityOk = read, true end
    end

    local state = {
        position = position,
        orientation = orientation,
        velocity = velocity,
        velocityOk = velocityOk,
        yaw = util.yawOf(orientation),
        speed = util.len3(velocity.x, velocity.y, velocity.z),
    }
    state.bx, state.by, state.bz = util.worldToBody(orientation, velocity.x, velocity.y, velocity.z)
    ship.noteYaw(state.yaw)
    return state
end

-- Body-frame velocity only, for calibration, which reads it constantly and
-- does not care where the ship is.
function ship.bodyVelocity()
    local state = ship.readState()
    if not state then return nil end
    return { x = state.bx, y = state.by, z = state.bz }
end

-- A heading, kept with the moment it was read, so a rate can be made of it
-- later. Everything that reads the pose feeds this, and nothing else has to
-- know it exists.
function ship.noteYaw(yaw)
    if type(yaw) ~= "number" then return end
    local trail = ship.yawTrail
    local now = os.clock()
    trail[#trail + 1] = { t = now, yaw = yaw }
    local span = config and config.get("yawWindow") or 1
    while #trail > 2 and now - trail[1].t > span do table.remove(trail, 1) end
end

-- Has the pose been read recently enough that the trail is worth reading and
-- nobody needs to read it again? One mainThread call is a server tick, so this
-- is the difference between the control loop, which reads the pose every tick
-- anyway, and the calibration wizard, which on the yaw ladder reads nothing else.
local function trailIsFresh()
    local last = ship.yawTrail[#ship.yawTrail]
    if not last then return false end
    return os.clock() - last.t < (config and config.get("tick") or 0.1)
end

-- The turn the heading itself made, which is a yaw rate that owes the physics
-- engine nothing.
local function yawRateFromTrail()
    local trail = ship.yawTrail
    if #trail < 2 then return nil end
    local first, last = trail[1], trail[#trail]
    local span = last.t - first.t
    -- Too short a span divides the pose's own jitter by almost nothing. Too
    -- long a one can have turned past half a circle, and a turn that has
    -- wrapped comes back with the wrong sign, which is worse than no reading.
    local window = config and config.get("yawWindow") or 1
    if span < 0.2 or span > window * 2 then return nil end
    return util.wrapAngle(last.yaw - first.yaw) / span
end

-- Yaw rate out of CC: Sable, in the units and the sign the rest of the program
-- thinks in. getAngularVelocity is radians about the world axes, and its y runs
-- opposite to this yaw convention, which is the single easiest sign in the
-- program to get backwards and the hardest to notice. It lives here rather than
-- in the control loop because calibration measures the same number the
-- controller flies by, and two readings of it would be two conventions.
--
-- **A reported zero is not the same claim as a hull at rest.** The figure is
-- the last one the physics engine published, and a hull creeping round at half
-- a degree a second is close enough to still for the engine to stop publishing
-- it: the reading drops to exactly zero for a sample or two and comes back, on
-- a ship that never stopped turning. Averaged into a calibration rung those
-- zeroes read the ladder low, and one of them caught by the sides stage files a
-- propeller as the main. So below yawAsleep the heading is asked instead. The
-- pose never sleeps, and util.yawOf produced both numbers, so they are the same
-- convention and the fallback cannot flip a sign.
function ship.yawRate()
    if type(sublevel) ~= "table" or not sublevel.getAngularVelocity then return nil end
    local ok, raw = pcall(sublevel.getAngularVelocity)
    if not ok then return nil end
    local vec = util.toVec(raw)
    if not vec then return nil end
    local reported = -math.deg(vec.y)

    local asleep = config and config.get("yawAsleep") or 0
    if math.abs(reported) > asleep then return reported end

    if not trailIsFresh() then ship.readState() end
    local turned = yawRateFromTrail()
    if turned and math.abs(turned) > asleep then return turned end
    return reported
end

-- The same rate, measured off the heading and never off the physics engine.
--
-- Calibration writes its answer to disk and every later flight is priced off
-- it, so the one number it must not take on trust is the one it is measuring.
-- `ship.yawRate` hands back `getAngularVelocity` whenever that is above
-- `yawAsleep`, which on a yaw rung is always, so the heading is never consulted
-- and the pose is never even read: a whole ladder can be written down while the
-- hull's heading has not moved at all, and nothing in the stage would know.
-- That is not a hypothetical. It is what the last two ladders on this ship did.
--
-- The trail needs a span before it can answer, so the first sample or two of a
-- rung still come back off the engine. A rung runs for twenty seconds and the
-- window is one second, so what gets averaged is the heading.
function ship.yawRateHeading()
    -- Unconditionally, because this is the call that feeds the trail. Without
    -- it the trail holds whatever some other loop happened to leave there.
    ship.readState()
    local turned = yawRateFromTrail()
    if turned then return turned end
    return ship.yawRate()
end

-- Which way north is, as a heading in the same convention everything else here
-- speaks. CC: Sable keeps it per dimension rather than per world, and a
-- datapack can move it, so it is asked for rather than written down as 180.
--
-- This is the one direction in the program that is not measured off the ship.
-- It is what the calibration wizard turns to so the pilot can look at the sky
-- and say whether the ship agrees, which is the only check for handedness and
-- for which end is the front that this program can never make on its own.
--
-- Returns nil and what to put on screen, the way readState does.
function ship.magneticNorth()
    if type(aero) ~= "table" or not aero.getMagneticNorth then
        return nil, "NO CC: SABLE AERODYNAMICS"
    end
    local ok, raw = pcall(aero.getMagneticNorth)
    if not ok then return nil, "THIS DIMENSION HAS NO MAGNETIC NORTH" end
    local vec = util.toVec(raw)
    if not vec then return nil, "NORTH SHAPE " .. util.keyList(raw) end
    -- A north of zero length is a dimension where the direction means nothing,
    -- which is a different thing from the call having failed and is said
    -- differently.
    if math.abs(vec.x) < 1e-9 and math.abs(vec.z) < 1e-9 then
        return nil, "NORTH IS STRAIGHT UP OR NOWHERE AT ALL"
    end
    return util.wrapAngle(math.deg(math.atan2(-vec.x, vec.z)))
end

-- Extras that are nice on the panel and never load-bearing. Each one is
-- optional hardware, so each one is allowed to come back nil.
function ship.readExtras()
    local extras = {}
    if ship.altimeter then
        local ok, h = pcall(ship.altimeter.getHeight)
        if ok then extras.altitude = h end
        local okP, p = pcall(ship.altimeter.getAirPressure)
        if okP then extras.pressure = p end
        local okV, v = pcall(ship.altimeter.getVerticalSpeed)
        if okV then extras.vspeed = v end
    end
    if ship.hasSublevel then
        local ok, mass = pcall(sublevel.getMass)
        if ok and type(mass) == "number" then extras.mass = mass end
    end
    if type(aero) == "table" and aero.getGravity then
        local ok, g = pcall(aero.getGravity)
        if ok and type(g) == "number" then extras.gravity = g end
    end
    return extras
end

-- Thrust and stress per line, for the PROPS tab. Getters do not yield, so this
-- is cheap enough to run on the screen refresh rather than the control loop.
function ship.readLineTelemetry(name)
    local line = ship.lines[name]
    if not line then return nil end
    local t = { thrust = nil, speed = nil, overstressed = false, assembled = nil }

    -- A relay line has no peripheral here to ask. What it has is whatever the
    -- relay said last, which the turbine module leaves on the line for exactly
    -- this. A relay that has gone quiet leaves the last thing it said, and the
    -- link age on the screen is what tells you how old that is.
    if line.remote then
        t.remote = true
        t.speed = line.actual
        t.overstressed = line.overstressed == true
        return t
    end

    local okSpeed, speed = pcall(line.wrap.getSpeed)
    if okSpeed and type(speed) == "number" then t.speed = speed end
    local okStress, over = pcall(line.wrap.isOverstressed)
    if okStress then t.overstressed = over == true end

    local total = 0
    local sawThrust = false
    for _, bearing in ipairs(line.bearings) do
        local okT, thrust = pcall(bearing.wrap.getThrust)
        if okT and type(thrust) == "number" then total = total + thrust; sawThrust = true end
        if t.assembled == nil and bearing.methods.isAssembled then
            local okA, assembled = pcall(bearing.wrap.isAssembled)
            if okA then t.assembled = assembled end
        end
    end
    if sawThrust then t.thrust = total end
    return t
end

-- == OUTPUT ==================================================

-- setTargetSpeed is a mainThread write and costs a server tick each. Sending
-- only what changed and sending those in one parallel batch is the difference
-- between a 20 Hz loop and a 4 Hz one on a five propeller ship.
function ship.flush(demands)
    local calls = {}
    local remote, anyRemote = {}, false
    for name, rpm in pairs(demands) do
        local line = ship.lines[name]
        if line then
            ship.lastRpm[name] = rpm
            if line.remote then
                -- Every remote line goes out every flush, changed or not. The
                -- relay stops its turbines when nobody has spoken to it for a
                -- few seconds, so "send only what changed" would be read over
                -- there as the flight computer having died.
                remote[name] = rpm
                anyRemote = true
                ship.lastSent[name] = rpm
            elseif ship.lastSent[name] ~= rpm then
                ship.lastSent[name] = rpm
                calls[#calls + 1] = function()
                    pcall(line.wrap.setTargetSpeed, rpm)
                end
            end
        end
    end
    if anyRemote and ship.sendRemote then pcall(ship.sendRemote, remote) end
    if #calls > 0 then parallel.waitForAll(table.unpack(calls)) end
    return #calls
end

function ship.allStop()
    local zero = {}
    for _, name in ipairs(ship.order) do zero[name] = 0 end
    ship.flush(zero)
end

-- Used by calibration: one line at whatever it is asked for, everything else
-- held at zero, so the drift that gets measured belongs to one propeller.
function ship.driveOnly(name, rpm)
    local demands = {}
    for _, other in ipairs(ship.order) do demands[other] = 0 end
    if name then demands[name] = rpm end
    ship.flush(demands)
end

function ship.count()
    return #ship.order
end

return ship
