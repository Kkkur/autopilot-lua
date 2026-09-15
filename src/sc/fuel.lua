-- fuel.lua -- the other computer's half of the ship, on this one.
--
-- A relay computer sits touching the fluid tanks and broadcasts what it sees on
-- rednet. This module is the receiving end: it keeps the last message, notices
-- when the link goes quiet, and turns tank numbers into the two things a captain
-- actually asks, which are "how long can I keep flying" and "can I get there".
--
-- Nothing here commands anything. It cannot: the tanks are on a computer that is
-- not this one, and the autopilot never stops flying because of a fuel number.
-- It reads, it works out consequences, and it says them out loud.
--
-- The relay does the fast sampling and the burn rate fit, because it is the one
-- with the peripherals. This end adds what only it knows: how fast the ship is
-- moving and how far away the target is. Range is where those two meet.

local util, ship, cal, control, config, log = ...

local fuel = {}

fuel.PROTOCOL = "starcatcher-fuel"
fuel.MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

fuel.modem = nil          -- side the modem was opened on, nil if there is none
fuel.snap = nil           -- the last message from the relay, as it arrived
fuel.at = nil             -- os.clock() when it arrived
fuel.relayId = nil
fuel.messages = 0
fuel.everSeen = false

-- == LINK ====================================================

function fuel.init()
    for _, side in ipairs(fuel.MODEM_SIDES) do
        if peripheral.getType(side) == "modem" then
            local wrapped = peripheral.wrap(side)
            -- Wireless first: the relay is a separate computer somewhere else
            -- on the hull, and if it were on this computer's wired network it
            -- would not need to be a separate computer at all.
            if wrapped.isWireless and wrapped.isWireless() then
                fuel.modem = side
                break
            end
            fuel.modem = fuel.modem or side
        end
    end

    if not fuel.modem then
        log.warn("fuel: no modem, so no fuel link. The autopilot flies fine without one.")
        return false
    end

    rednet.open(fuel.modem)
    log.infof("fuel: listening on %s, protocol %s", fuel.modem, fuel.PROTOCOL)
    return true
end

function fuel.close()
    if fuel.modem then
        pcall(rednet.close, fuel.modem)
        fuel.modem = nil
    end
end

-- Accepts a message and says whether it was one of ours. Split out from the
-- loop so the same validation can be tested without a modem.
function fuel.accept(id, message)
    if type(message) ~= "table" or message.v ~= 1 or type(message.tanks) ~= "table" then
        return false
    end
    -- The gap is measured before the clock is stamped, or the line below
    -- reports every recovery as having taken no time at all.
    local gap = fuel.everSeen and not fuel.isLive() and fuel.age() or nil
    fuel.snap = message
    fuel.at = os.clock()
    fuel.relayId = id
    fuel.messages = fuel.messages + 1
    if not fuel.everSeen then
        fuel.everSeen = true
        log.infof("fuel: relay #%d found, %d tank(s), %d mB of %d",
            id, #message.tanks, message.total or 0, message.capacity or 0)
    elseif gap then
        log.infof("fuel: link to relay #%d back after %ds", id, math.floor(gap))
    end
    return true
end

-- Runs as one of the host's parallel loops. rednet.receive yields, so this
-- costs nothing while nothing is being said.
function fuel.listen()
    if not fuel.modem then
        while true do sleep(60) end
    end
    while true do
        local id, message = rednet.receive(fuel.PROTOCOL)
        local ok, err = pcall(fuel.accept, id, message)
        if not ok then log.error("fuel: bad message: " .. tostring(err)) end
    end
end

-- Asks for a reading now rather than waiting for the next broadcast. Used by
-- the `fuel` command so typing it feels immediate.
function fuel.ping()
    if not fuel.modem then return false, "no modem on this computer" end
    rednet.broadcast({ cmd = "ping" }, fuel.PROTOCOL)
    return true
end

function fuel.age()
    if not fuel.at then return nil end
    return os.clock() - fuel.at
end

function fuel.isLive()
    local age = fuel.age()
    return age ~= nil and age <= config.get("fuelStale")
end

-- == WHAT IT MEANS ===========================================

-- The reserve is fuel the captain has decided is not his to spend: it is what
-- gets the ship home, or at least down. Endurance and range are quoted against
-- what is left above it, with the run to dry given separately, because a number
-- that counts the reserve as usable is the number that strands ships.
local function usableAmount(snap)
    local reserve = config.get("fuelReserve") / 100
    return math.max(0, (snap.total or 0) - reserve * (snap.capacity or 0))
end

function fuel.status()
    local out = {
        link = "none",
        age = fuel.age(),
        relayId = fuel.relayId,
        tanks = {},
    }

    if not fuel.modem then
        out.link = "nomodem"
        return out
    end
    if not fuel.snap then
        out.link = "waiting"
        return out
    end

    local snap = fuel.snap
    out.link = fuel.isLive() and "live" or "stale"
    out.snap = snap
    out.tanks = snap.tanks
    out.total = snap.total or 0
    out.capacity = snap.capacity or 0
    out.fraction = snap.fraction or (out.capacity > 0 and out.total / out.capacity or 0)
    out.rate = snap.rate
    out.guessed = false
    for _, t in ipairs(snap.tanks) do
        if t.capSource and t.capSource ~= "reported" then out.guessed = true end
    end

    -- A rate under a tenth of a mB per second is the fit finding nothing, not a
    -- ship sipping fuel. Calling that a burn produces an endurance of days.
    local rate = snap.rate
    if rate and math.abs(rate) < 0.1 then rate = 0 end
    out.burn = (rate and rate < 0) and -rate or 0
    out.filling = (rate and rate > 0) and rate or nil

    out.usable = usableAmount(snap)
    if out.burn > 0 then
        out.endurance = out.usable / out.burn
        out.dry = out.total / out.burn
    end
    if out.filling then
        local room = math.max(0, out.capacity - out.total)
        out.fullIn = room / out.filling
    end

    -- Range is endurance flown at the speed the ship is actually making, not at
    -- the speed it was tuned for. A ship holding station has an endurance and no
    -- range at all, which is the honest answer.
    local state = ship.readState()
    out.speed = state and state.speed or nil
    if out.endurance and out.speed and out.speed > 0.1 then
        out.range = out.endurance * out.speed
    end
    -- What it would manage at the cruise it is allowed to ask for, which is the
    -- number worth planning the next leg against.
    local cruise = math.min(config.get("cruiseSpeed"),
        cal.topForward() or config.get("cruiseSpeed"))
    if out.endurance and cruise and cruise > 0 then
        out.rangeAtCruise = out.endurance * cruise
    end

    return out
end

-- == ADVICE ==================================================
--
-- Every line here is something the captain would otherwise have to work out in
-- his head from two numbers on different tabs. Ordered worst first, because the
-- panel is short and the top of it is what gets read.

local function pct(x) return math.floor((x or 0) * 100 + 0.5) end

function fuel.advice(status, snap)
    local out = {}
    local function say(kind, fmt, ...) out[#out + 1] = { kind = kind, text = string.format(fmt, ...) } end

    if status.link == "nomodem" then
        say("warn", "no modem on this computer. Put one on and `rescan`.")
        return out
    end
    if status.link == "waiting" then
        say("warn", "listening on %s, the relay has not spoken yet.", fuel.modem)
        return out
    end
    if status.link == "stale" then
        say("bad", "link lost %s ago. Numbers are from before that.", util.fmtETA(status.age))
    end

    for _, t in ipairs(status.tanks or {}) do
        if t.ok == false then
            say("bad", "tank on %s stopped answering: %s", t.side, tostring(t.err))
        end
    end

    -- Two tanks holding different fluids is either a plumbing mistake or a
    -- deliberate second fuel, and either way the total above is a lie.
    local fluids = {}
    for _, t in ipairs(status.tanks or {}) do
        if t.fluid then fluids[t.fluid] = (fluids[t.fluid] or 0) + 1 end
    end
    local distinct = {}
    for name in pairs(fluids) do distinct[#distinct + 1] = name end
    if #distinct > 1 then
        table.sort(distinct)
        local short = {}
        for _, name in ipairs(distinct) do short[#short + 1] = (name:gsub("^.*:", "")) end
        say("warn", "different fluids: %s. The total is not one supply.",
            table.concat(short, " and "))
    end

    -- Uneven tanks on a ship that pumps between them means a valve or a pump is
    -- not doing its job, and the low one runs dry while the total still reads fine.
    local lo, hi = nil, nil
    for _, t in ipairs(status.tanks or {}) do
        if t.ok ~= false and (t.capacity or 0) > 0 then
            local f = t.amount / t.capacity
            lo = (lo == nil or f < lo) and f or lo
            hi = (hi == nil or f > hi) and f or hi
        end
    end
    if lo and hi and (hi - lo) * 100 > config.get("fuelImbalance") then
        say("warn", "tanks uneven: %d%% against %d%%. Check the pumps.", pct(lo), pct(hi))
    end

    local crit, warn = config.get("fuelCrit"), config.get("fuelWarn")
    local level = pct(status.fraction)
    if status.total and status.total <= 0 then
        say("bad", "tanks are empty.")
    elseif level <= crit then
        say("bad", "fuel critical at %d%%. Land or refuel now.", level)
    elseif level <= warn then
        say("warn", "fuel low at %d%%.", level)
    end

    if status.filling then
        say("good", "filling at %.1f mB/s%s", status.filling,
            status.fullIn and (", full in " .. util.fmtETA(status.fullIn)) or "")
    elseif status.burn and status.burn > 0 then
        local reserve = config.get("fuelReserve")
        say(status.endurance and status.endurance < 120 and "bad" or "hi",
            "burning %.1f mB/s, %s above the %d%% reserve.",
            status.burn, util.fmtETA(status.endurance), reserve)
    elseif status.link == "live" then
        say("dim", "no flow for %ds. Nothing is drawing fuel.",
            (status.snap and status.snap.rateWindow) or 60)
    end

    -- The one that matters: can this leg be finished on what is in the tanks.
    if snap and snap.target and snap.dist and status.range then
        if status.range < snap.dist then
            say("bad", "target %.0f blk out, range %.0f. It will not make it.",
                snap.dist, status.range)
        elseif status.range < snap.dist * 2 then
            say("warn", "range %.0f blk reaches the target at %.0f, but not back.",
                status.range, snap.dist)
        else
            say("good", "range %.0f blk, target %.0f out. Comfortable.",
                status.range, snap.dist)
        end
    elseif status.rangeAtCruise and status.burn > 0 then
        say("hi", "range at cruise %.0f blk.", status.rangeAtCruise)
    end

    if status.guessed then
        say("dim", "a tank maximum is a guess, not a reading.")
    end

    if #out == 0 then say("good", "fuel nominal at %d%%.", level) end
    return out
end

return fuel
