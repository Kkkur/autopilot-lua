-- turbine.lua -- the propeller relays' half of the ship, on this one.
--
-- Relay computers hold the speed controllers this computer has none of, and a
-- stressometer watching the kinetic network. This module is the receiving end:
-- it adopts their lines into `ship` so the mixer cannot tell they are somewhere
-- else, it sends them their RPM, and it reads the stress back.
--
-- There is more than one relay. The turbine relay holds the four turbines and
-- the stressometer; the cruise relay holds the main propeller and the balloon.
-- Everything here is therefore per relay, keyed by the computer id that spoke,
-- and the single hardest rule in the file is that a message from one relay says
-- nothing whatever about another relay's lines. Dropping every line not named in
-- the message being handled was right with one relay and, with two, is each of
-- them deleting the other's ship once a second.
--
-- Line names arrive qualified by the relay that owns them, "<id>:<peripheral>",
-- because peripheral names are per network and both relays offer a
-- Create_RotationSpeedController_0.
--
-- The one thing this has that the fuel link does not is a heartbeat. A relay
-- stops its turbines when nobody has ordered anything for a few seconds, which
-- is the right behaviour for an engine driven over a radio and the reason the
-- orders have to keep going out even when the number has not changed.

local util, ship, config, log = ...

local turbine = {}

turbine.PROTOCOL = "starcatcher-turbine"
turbine.MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

turbine.modem = nil
turbine.messages = 0
turbine.sentAt = nil

-- id -> { snap, at, everSeen, wasOverstressed, lines = { name = true } }
-- The set of lines is what makes a drop safe: only what this relay named last
-- time is a candidate for this relay having lost it.
turbine.relays = {}
turbine.order = {}        -- relay ids, sorted, so the screen is stable

turbine.demand = {}       -- qualified name -> rpm, what the relays are told
turbine.balloon = nil     -- the level last commanded, or nil if never

local function relayState(id)
    local state = turbine.relays[id]
    if not state then
        state = { id = id, lines = {}, everSeen = false, wasOverstressed = false }
        turbine.relays[id] = state
        turbine.order[#turbine.order + 1] = id
        table.sort(turbine.order)
    end
    return state
end

turbine.relayState = relayState

-- == LINK ====================================================

-- Takes the side the fuel link already opened, if there is one, because two
-- protocols share one modem perfectly well and opening it twice is pointless.
function turbine.init(side)
    if side and peripheral.getType(side) == "modem" then
        turbine.modem = side
    else
        for _, candidate in ipairs(turbine.MODEM_SIDES) do
            if peripheral.getType(candidate) == "modem" then
                local wrapped = peripheral.wrap(candidate)
                if wrapped.isWireless and wrapped.isWireless() then
                    turbine.modem = candidate
                    break
                end
                turbine.modem = turbine.modem or candidate
            end
        end
    end

    if not turbine.modem then
        log.warn("turbines: no modem, so no turbine relay. Local lines still fly.")
        return false
    end

    rednet.open(turbine.modem)
    -- ship.flush calls this for every remote line on every tick.
    ship.sendRemote = turbine.send
    log.infof("turbines: listening on %s, protocol %s", turbine.modem, turbine.PROTOCOL)
    return true
end

function turbine.close()
    ship.sendRemote = nil
    -- Each relay's own deadman stops its turbines a few seconds after this
    -- computer goes quiet, but leaving that to a timeout when we know we are
    -- shutting down is sloppy. Say so, to every one of them.
    --
    -- The balloon is left where it is. Shutting the autopilot down is not a
    -- reason to stop holding the ship up.
    if turbine.modem then
        for _, id in ipairs(turbine.order) do
            pcall(rednet.send, id, { cmd = "stop" }, turbine.PROTOCOL)
        end
    end
    turbine.modem = nil
end

function turbine.age(id)
    if id then
        local state = turbine.relays[id]
        return state and state.at and (os.clock() - state.at) or nil
    end
    -- With no relay named, the age that matters is the worst one, because a
    -- ship is as linked as its least linked half.
    local worst = nil
    for _, other in ipairs(turbine.order) do
        local age = turbine.age(other)
        if age and (worst == nil or age > worst) then worst = age end
    end
    return worst
end

function turbine.isLive(id)
    local age = turbine.age(id)
    return age ~= nil and age <= config.get("turbineStale")
end

-- Which relay owns a line, out of what the relays themselves said. The name
-- carries it, but reading it off the adopted line rather than off the string is
-- what keeps the format in one place.
function turbine.ownerOf(name)
    local line = ship.lines[name]
    if line and line.relay then return line.relay end
    local owner = tostring(name):match("^(%d+):")
    return owner and tonumber(owner) or nil
end

-- == WHAT THE RELAY SAYS =====================================

-- Adopting a line is what makes the rest of the program work unchanged: after
-- this, `cal` will calibrate it, the mixer will give it a share of an axis, and
-- the PROPS tab will draw it, all without knowing it is on a radio.
local function adoptLines(message, id)
    local state = relayState(id)
    local seen = {}

    for _, entry in ipairs(message.lines or {}) do
        if type(entry.name) == "string" then
            seen[entry.name] = true
            local added = ship.addRemote(entry.name, { relay = id, short = entry.short })
            if added then
                log.infof("turbines: adopted %s from relay #%d", entry.short or entry.name, id)
            end
            -- Telemetry is left on the line for ship.readLineTelemetry to find.
            local line = ship.lines[entry.name]
            if line then
                line.actual = entry.actual
                line.relayDemand = entry.demand
                line.overstressed = message.overstressed == true
            end
        end
    end

    -- Only this relay's own lines are candidates for being dropped. The other
    -- relay is not silent, it simply was not the one talking, and reading its
    -- absence from this message as a loss is how two relays delete each other's
    -- propellers once a second.
    for name in pairs(state.lines) do
        if not seen[name] then
            if ship.dropRemote(name) then
                log.warnf("turbines: relay #%d no longer has %s", id, name)
            end
            turbine.demand[name] = nil
        end
    end

    state.lines = seen
end

function turbine.accept(id, message)
    if type(message) ~= "table" or message.v ~= 1 or type(message.lines) ~= "table" then
        return false
    end

    local state = relayState(id)
    local gap = state.everSeen and not turbine.isLive(id) and turbine.age(id) or nil
    state.snap = message
    state.at = os.clock()
    state.hasBalloon = message.hasBalloon == true
    state.balloon = message.balloon
    turbine.messages = turbine.messages + 1

    if not state.everSeen then
        state.everSeen = true
        log.infof("turbines: relay #%d found, %d line(s), stressometer %s, balloon %s",
            id, #message.lines, message.stressOk and "yes" or "no",
            message.hasBalloon and "yes" or "no")
    elseif gap then
        log.infof("turbines: link to relay #%d back after %ds", id, math.floor(gap))
    end

    -- Overstress is logged on the edge, not every second it stays true, and per
    -- relay, because two kinetic networks fail separately.
    if message.overstressed and not state.wasOverstressed then
        log.errorf("turbines: relay #%d OVERSTRESSED. Its kinetic network has stopped.", id)
    elseif state.wasOverstressed and not message.overstressed then
        log.infof("turbines: relay #%d overstress cleared", id)
    end
    state.wasOverstressed = message.overstressed == true

    adoptLines(message, id)
    return true
end

function turbine.listen()
    if not turbine.modem then
        while true do sleep(60) end
    end
    while true do
        local id, message = rednet.receive(turbine.PROTOCOL)
        local ok, err = pcall(turbine.accept, id, message)
        if not ok then log.error("turbines: bad message: " .. tostring(err)) end
    end
end

-- == ORDERS ==================================================

-- Every demand goes to the relay that owns the line, and every relay that owns
-- anything hears from us on every flush. Sending one relay's numbers to both
-- would work, since a relay ignores what it does not hold, but it doubles the
-- radio traffic on a mod where that is a server tick.
--
-- A line whose owner is not known yet is broadcast, which is what happens in the
-- second between boot and the first reading.
function turbine.send(demands)
    if not turbine.modem then return false end
    for name, rpm in pairs(demands) do turbine.demand[name] = rpm end

    local byRelay, loose = {}, nil
    for name, rpm in pairs(turbine.demand) do
        local owner = turbine.ownerOf(name)
        if owner then
            byRelay[owner] = byRelay[owner] or {}
            byRelay[owner][name] = rpm
        else
            loose = loose or {}
            loose[name] = rpm
        end
    end

    for id, rpm in pairs(byRelay) do
        rednet.send(id, { cmd = "set", rpm = rpm }, turbine.PROTOCOL)
    end
    if loose then
        rednet.broadcast({ cmd = "set", rpm = loose }, turbine.PROTOCOL)
    end

    -- A relay with nothing to do still has to hear from us, or its deadman reads
    -- the silence as this computer having died and it stops turbines that a
    -- calibration run is in the middle of using.
    for _, id in ipairs(turbine.order) do
        if not byRelay[id] then
            rednet.send(id, { cmd = "set", rpm = {} }, turbine.PROTOCOL)
        end
    end

    turbine.sentAt = os.clock()
    return true
end

-- The balloon is lift, not thrust, so it is not a line and never goes through
-- the mixer. Only the relay holding a redstone relay does anything with this;
-- the rest hear it and have nothing to do about it.
function turbine.setBalloon(level)
    if not turbine.modem then return false, "no modem on this computer" end
    turbine.balloon = level
    local target = nil
    for _, id in ipairs(turbine.order) do
        if turbine.relays[id].hasBalloon then target = id end
    end
    if target then
        rednet.send(target, { cmd = "balloon", level = level }, turbine.PROTOCOL)
    else
        rednet.broadcast({ cmd = "balloon", level = level }, turbine.PROTOCOL)
    end
    turbine.sentAt = os.clock()
    return true
end

function turbine.hasBalloon()
    for _, id in ipairs(turbine.order) do
        if turbine.relays[id].hasBalloon then return true, id end
    end
    return false
end

-- The heartbeat. ship.flush already sends on every control tick, so this only
-- has anything to do when the control loop is parked, which is exactly when the
-- relay would otherwise time out and stop turbines that a calibration run is in
-- the middle of using.
function turbine.heartbeat()
    if not turbine.modem then
        while true do sleep(60) end
    end
    while true do
        local quiet = turbine.sentAt and (os.clock() - turbine.sentAt) or math.huge
        -- Any relay that has ever spoken is owed a heartbeat, whether or not it
        -- currently holds a line we are driving. A relay with nothing to do still
        -- counts down its deadman.
        local anyone = next(turbine.demand) ~= nil or #turbine.order > 0
        if anyone and quiet >= 1.0 then
            pcall(turbine.send, {})
        end
        sleep(0.5)
    end
end

-- Reaches every relay, including one that has not spoken yet, because a stop
-- that misses half the ship is worse than no stop at all.
--
-- Thrust only. The balloon is what is holding the ship up and a stop is not a
-- request to come down.
function turbine.stop()
    if not turbine.modem then return false end
    for name in pairs(turbine.demand) do turbine.demand[name] = 0 end
    if #turbine.order > 0 then
        for _, id in ipairs(turbine.order) do
            rednet.send(id, { cmd = "stop" }, turbine.PROTOCOL)
        end
    else
        rednet.broadcast({ cmd = "stop" }, turbine.PROTOCOL)
    end
    turbine.sentAt = os.clock()
    return true
end

function turbine.ping()
    if not turbine.modem then return false, "no modem on this computer" end
    rednet.broadcast({ cmd = "ping" }, turbine.PROTOCOL)
    return true
end

-- == WHAT IT MEANS ===========================================

-- One relay's own reading.
function turbine.relayStatus(id)
    local state = turbine.relays[id]
    local out = { relayId = id, link = "none", age = turbine.age(id), lines = {} }
    if not state or not state.snap then out.link = "waiting"; return out end

    local snap = state.snap
    out.link = turbine.isLive(id) and "live" or "stale"
    out.snap = snap
    out.lines = snap.lines
    out.stress = snap.stress
    out.capacity = snap.stressCapacity
    out.fraction = snap.stressFraction
    out.overstressed = snap.overstressed == true
    out.stressOk = snap.stressOk == true
    out.stressError = snap.stressError
    out.hasBalloon = snap.hasBalloon == true
    out.balloon = snap.balloon
    -- Headroom is the number that decides whether another propeller can be
    -- asked for more, which is the question stress actually gets asked.
    if out.stress and out.capacity then
        out.headroom = out.capacity - out.stress
    end
    return out
end

-- The ship's reading, which is every relay's, with the worst of each number
-- brought to the top. A ship is as stressed as its most stressed network and as
-- linked as its least linked half.
function turbine.status()
    local out = { link = "none", relays = {}, lines = {}, age = turbine.age() }

    if not turbine.modem then out.link = "nomodem"; return out end
    if #turbine.order == 0 then out.link = "waiting"; return out end

    for _, id in ipairs(turbine.order) do
        local one = turbine.relayStatus(id)
        out.relays[#out.relays + 1] = one

        for _, entry in ipairs(one.lines or {}) do
            out.lines[#out.lines + 1] = entry
        end

        if one.link == "stale" or out.link == "none" then out.link = one.link end
        if one.link == "live" and out.link ~= "stale" then out.link = "live" end

        if one.overstressed then out.overstressed = true end
        if one.stressOk then
            out.stressOk = true
            if one.fraction and (out.fraction == nil or one.fraction > out.fraction) then
                out.fraction = one.fraction
                out.stress = one.stress
                out.capacity = one.capacity
                out.headroom = one.headroom
                out.worstRelay = id
            end
        elseif one.stressError and not out.stressError then
            out.stressError = one.stressError
        end

        if one.hasBalloon then
            out.hasBalloon = true
            out.balloon = one.balloon
            out.balloonRelay = id
        end
    end

    out.stressOk = out.stressOk == true
    out.overstressed = out.overstressed == true
    return out
end

function turbine.advice(status)
    local out = {}
    local function say(kind, fmt, ...) out[#out + 1] = { kind = kind, text = string.format(fmt, ...) } end

    if status.link == "nomodem" or status.link == "waiting" then return out end

    -- Named one at a time. Two relays going quiet are two different problems and
    -- a pilot needs to know which computer to walk to.
    local anyStale = false
    for _, one in ipairs(status.relays or {}) do
        if one.link == "stale" then
            anyStale = true
            if one.hasBalloon then
                say("bad", "relay #%d silent for %s. Thrust stopped, balloon still held at %s.",
                    one.relayId, util.fmtETA(one.age), tostring(one.balloon))
            else
                say("bad", "relay #%d silent for %s. Its own timer has stopped its turbines.",
                    one.relayId, util.fmtETA(one.age))
            end
        end
    end
    if anyStale then return out end

    if status.overstressed then
        say("bad", "OVERSTRESSED. The kinetic network has stopped turning.")
    elseif status.fraction then
        local level = status.fraction * 100
        if level >= config.get("stressCrit") then
            say("bad", "stress %d%%. The next demand is what breaks it.", math.floor(level + 0.5))
        elseif level >= config.get("stressWarn") then
            say("warn", "stress %d%%, %.0f su of headroom left.",
                math.floor(level + 0.5), status.headroom or 0)
        end
    end

    if not status.stressOk then
        say("warn", "no stressometer on any relay%s",
            status.stressError and (": " .. status.stressError) or ".")
    end

    -- The balloon is the one part whose absence is silent. A ship with no
    -- redstone relay answering has no lift and nothing else says so.
    if not status.hasBalloon then
        say("bad", "no relay is holding the balloon. Nothing here controls lift.")
    end

    return out
end

return turbine
