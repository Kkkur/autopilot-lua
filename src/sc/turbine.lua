-- turbine.lua -- the turbine relay's half of the ship, on this one.
--
-- A second relay computer holds the speed controllers for the bottom turbines
-- and a stressometer watching the whole kinetic network. This module is the
-- receiving end of that: it adopts the relay's lines into `ship` so the mixer
-- cannot tell they are somewhere else, it sends them their RPM, and it reads
-- the stress back.
--
-- The one thing it has that the fuel link does not is a heartbeat. The relay
-- stops its turbines when nobody has ordered anything for a few seconds, which
-- is the right behaviour for an engine driven over a radio and the reason the
-- orders have to keep going out even when the number has not changed.

local util, ship, config, log = ...

local turbine = {}

turbine.PROTOCOL = "starcatcher-turbine"
turbine.MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

turbine.modem = nil
turbine.snap = nil        -- the relay's last message, as it arrived
turbine.at = nil          -- os.clock() when it arrived
turbine.relayId = nil
turbine.messages = 0
turbine.everSeen = false
turbine.demand = {}       -- name -> rpm, what the relay is being told to do
turbine.sentAt = nil
turbine.wasOverstressed = false

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
    -- The relay's own deadman stops the turbines a few seconds after this
    -- computer goes quiet, but leaving that to a timeout when we know we are
    -- shutting down is sloppy. Say so.
    if turbine.modem and turbine.relayId then
        pcall(rednet.send, turbine.relayId, { cmd = "stop" }, turbine.PROTOCOL)
    end
    turbine.modem = nil
end

function turbine.age()
    if not turbine.at then return nil end
    return os.clock() - turbine.at
end

function turbine.isLive()
    local age = turbine.age()
    return age ~= nil and age <= config.get("turbineStale")
end

-- == WHAT THE RELAY SAYS =====================================

-- Adopting a line is what makes the rest of the program work unchanged: after
-- this, `cal` will calibrate it, the mixer will give it a share of an axis, and
-- the PROPS tab will draw it, all without knowing it is on a radio.
local function adoptLines(message, id)
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
    for name in pairs(ship.remoteLines) do
        if not seen[name] then
            if ship.dropRemote(name) then
                log.warnf("turbines: relay no longer has %s", name)
            end
        end
    end
end

function turbine.accept(id, message)
    if type(message) ~= "table" or message.v ~= 1 or type(message.lines) ~= "table" then
        return false
    end
    local gap = turbine.everSeen and not turbine.isLive() and turbine.age() or nil
    turbine.snap = message
    turbine.at = os.clock()
    turbine.relayId = id
    turbine.messages = turbine.messages + 1

    if not turbine.everSeen then
        turbine.everSeen = true
        log.infof("turbines: relay #%d found, %d line(s), stressometer %s",
            id, #message.lines, message.stressOk and "yes" or "no")
    elseif gap then
        log.infof("turbines: link to relay #%d back after %ds", id, math.floor(gap))
    end

    -- Overstress is logged on the edge, not every second it stays true.
    if message.overstressed and not turbine.wasOverstressed then
        log.error("turbines: OVERSTRESSED. The kinetic network has stopped.")
    elseif turbine.wasOverstressed and not message.overstressed then
        log.info("turbines: overstress cleared")
    end
    turbine.wasOverstressed = message.overstressed == true

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

function turbine.send(demands)
    if not turbine.modem then return false end
    for name, rpm in pairs(demands) do turbine.demand[name] = rpm end
    local message = { cmd = "set", rpm = turbine.demand }
    if turbine.relayId then
        rednet.send(turbine.relayId, message, turbine.PROTOCOL)
    else
        rednet.broadcast(message, turbine.PROTOCOL)
    end
    turbine.sentAt = os.clock()
    return true
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
        if next(turbine.demand) ~= nil and quiet >= 1.0 then
            pcall(turbine.send, {})
        end
        sleep(0.5)
    end
end

function turbine.stop()
    if not turbine.modem then return false end
    for name in pairs(turbine.demand) do turbine.demand[name] = 0 end
    if turbine.relayId then
        rednet.send(turbine.relayId, { cmd = "stop" }, turbine.PROTOCOL)
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

function turbine.status()
    local out = { link = "none", age = turbine.age(), relayId = turbine.relayId, lines = {} }

    if not turbine.modem then out.link = "nomodem"; return out end
    if not turbine.snap then out.link = "waiting"; return out end

    local snap = turbine.snap
    out.link = turbine.isLive() and "live" or "stale"
    out.snap = snap
    out.lines = snap.lines
    out.stress = snap.stress
    out.capacity = snap.stressCapacity
    out.fraction = snap.stressFraction
    out.overstressed = snap.overstressed == true
    out.stressOk = snap.stressOk == true
    out.stressError = snap.stressError
    -- Headroom is the number that decides whether another propeller can be
    -- asked for more, which is the question stress actually gets asked.
    if out.stress and out.capacity then
        out.headroom = out.capacity - out.stress
    end
    return out
end

function turbine.advice(status)
    local out = {}
    local function say(kind, fmt, ...) out[#out + 1] = { kind = kind, text = string.format(fmt, ...) } end

    if status.link == "nomodem" or status.link == "waiting" then return out end
    if status.link == "stale" then
        say("bad", "turbine relay silent for %s. Its own timer has stopped the turbines.",
            util.fmtETA(status.age))
        return out
    end

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
        say("warn", "no stressometer on the relay%s",
            status.stressError and (": " .. status.stressError) or ".")
    end

    return out
end

return turbine
