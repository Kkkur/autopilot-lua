-- fuel_relay.lua -- the fuel half of the ship, on its own computer.
--
-- The autopilot on computer 0 flies. This one watches the tanks and talks. It
-- sits touching both create:fluid_tank blocks, reads them twice a second, works
-- out what is actually happening to the fluid over time, and broadcasts the
-- whole picture over rednet on the wireless modem on top.
--
-- It is a separate computer on purpose: reading a peripheral is cheap, but the
-- autopilot's control loop is not allowed to be interrupted by anything, and a
-- relay that dies should not take the propellers with it.
--
--   fuel_relay           run it
--   fuel_relay --once    print one reading and exit, for checking the wiring
--   fuel_relay --passcode W  set the passcode this relay answers to
--
-- Everything it writes lives in fuelrelay/ next to this file: logs/, and
-- learned.cfg for the tank capacities it worked out by watching.

local ARGS = { ... }

local ROOT = fs.getDir(shell and shell.getRunningProgram() or "fuel_relay.lua")
local DATA = "fuelrelay"

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
-- Constants on purpose, not a config file. This program has one job, and the
-- autopilot is where tuning lives.

local PROTOCOL    = "starcatcher-fuel"  -- must match sc/fuel.lua on computer 0
local HOSTNAME    = "fuel"              -- so rednet.lookup finds us too
local SAMPLE      = 0.5                 -- seconds between tank reads
local SEND_EVERY  = 1.0                 -- seconds between broadcasts
local HISTORY     = 600                 -- samples kept: five minutes at 0.5s
local RATE_WINDOW = 60                  -- seconds of history the rate fit uses
local BLOCK_MB    = 8000                -- mB per tank block, Create's default
local TANK_BLOCKS = 63                  -- blocks in each of this ship's tanks
local ASSUMED_CAP = BLOCK_MB * TANK_BLOCKS   -- 504,000 mB, and 1,008,000 across both
local MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local log = loadModule("log")
-- The passcode this relay answers to. Same file on all four computers, and the
-- comment at the top of it says plainly what a plaintext passcode on a
-- broadcast medium is and is not worth.
local link = loadModule("link")

-- == TANKS ===================================================

local tanks = {}
local modemSide = nil
local learned = {}

local function isTank(side)
    local kind = peripheral.getType(side)
    if not kind or kind == "modem" then return false end
    if peripheral.hasType(side, "fluid_storage") then return true end
    return kind:find("fluid_tank") ~= nil
end

-- CC: Tweaked's generic fluid_storage gives tanks() returning {name, amount}
-- and documents no capacity at all, and Create's tank adds no peripheral of its
-- own, so the maximum has to be found the hard way: ask for it in every shape a
-- build might offer it, and if nothing answers, assume the Create default and
-- correct that assumption upward whenever more fluid turns up in there than we
-- thought could fit. A guessed maximum is labelled as guessed the whole way to
-- the captain's screen rather than being quietly presented as a fact.
local CAPACITY_METHODS = { "getCapacity", "getTankCapacity", "getMaxAmount", "size" }

local function probeCapacity(entry)
    local has = {}
    for _, name in ipairs(peripheral.getMethods(entry.side) or {}) do has[name] = true end

    for _, name in ipairs(CAPACITY_METHODS) do
        if has[name] then
            local ok, value = pcall(entry.p[name])
            if ok and type(value) == "number" and value > 0 then
                return value, "method:" .. name
            end
        end
    end

    local ok, contents = pcall(entry.p.tanks)
    if ok and type(contents) == "table" then
        local total = 0
        for _, t in ipairs(contents) do
            if type(t.capacity) == "number" then total = total + t.capacity end
        end
        if total > 0 then return total, "reported" end
    end

    return ASSUMED_CAP, "assumed"
end

local function findTanks()
    local found = {}
    for _, side in ipairs(peripheral.getNames()) do
        if isTank(side) then
            local entry = { side = side, p = peripheral.wrap(side), amount = 0 }
            entry.capacity, entry.capSource = probeCapacity(entry)
            found[#found + 1] = entry
        end
    end
    table.sort(found, function(a, b) return a.side < b.side end)
    return found
end

-- Learned capacities survive a reboot, so a tank that happened to be half full
-- at boot does not report a smaller maximum than it did yesterday.
local LEARNED = fs.combine(DATA, "learned.cfg")

local function loadLearned()
    if not fs.exists(LEARNED) then return {} end
    local handle = fs.open(LEARNED, "r")
    local text = handle.readAll()
    handle.close()
    local value = textutils.unserialise(text)
    return type(value) == "table" and value or {}
end

local function saveLearned()
    local handle = fs.open(LEARNED, "w")
    if not handle then return end
    handle.write(textutils.serialise(learned))
    handle.close()
end

local function readTank(entry)
    local ok, contents = pcall(entry.p.tanks)
    if not ok then
        entry.ok, entry.err, entry.amount, entry.fluid = false, tostring(contents), 0, nil
        return
    end
    entry.ok, entry.err = true, nil

    local amount, names = 0, {}
    for _, t in ipairs(contents or {}) do
        amount = amount + (t.amount or 0)
        if t.name and (t.amount or 0) > 0 then names[#names + 1] = t.name end
    end
    entry.amount = amount
    entry.fluids = names
    entry.fluid = names[1]

    -- More fluid than we believed fits means the belief was wrong, not that the
    -- tank is over-full. The correction rounds up to a whole Create tank block
    -- rather than to a whole tank, so a tank that turns out to be taller than
    -- TANK_BLOCKS lands on its real size instead of double it.
    if amount > entry.capacity then
        entry.capacity = math.ceil(amount / BLOCK_MB) * BLOCK_MB
        entry.capSource = "learned"
        learned[entry.side] = entry.capacity
        saveLearned()
        log.warnf("%s holds %d mB, more than assumed. capacity raised to %d mB",
            entry.side, amount, entry.capacity)
    end
end

-- == HISTORY AND RATE ========================================

local history = {}      -- {t = os.clock(), total = mB}, newest last

local function record(total)
    history[#history + 1] = { t = os.clock(), total = total }
    while #history > HISTORY do table.remove(history, 1) end
end

-- Least squares slope over the recent window, in mB per second, signed the way
-- the fluid is going: negative is being burned. A single pair of readings is
-- far too noisy to put in front of a captain, which is why this fits a line
-- rather than differencing the last two samples.
local function fluidRate()
    local now = os.clock()
    local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, sample in ipairs(history) do
        if now - sample.t <= RATE_WINDOW then
            local x, y = sample.t - now, sample.total
            n = n + 1; sx = sx + x; sy = sy + y; sxx = sxx + x * x; sxy = sxy + x * y
        end
    end
    if n < 4 then return nil, n end
    local denom = n * sxx - sx * sx
    if math.abs(denom) < 1e-9 then return nil, n end
    return (n * sxy - sx * sy) / denom, n
end

-- == EVENT LOGGING ===========================================
-- The tanks are read twice a second. Writing that to disk twice a second would
-- bury the one line that matters, so only what a captain would want to read
-- afterwards gets logged: crossing a level, changing fluid, a tank going quiet.

local MARKS = { 0.90, 0.75, 0.50, 0.25, 0.10, 0.05 }
local lastMark, lastFluid, lastOk = nil, {}, {}

local function noteLevels(fraction)
    local mark = nil
    for _, m in ipairs(MARKS) do
        if fraction <= m then mark = m end
    end
    if mark ~= lastMark then
        if mark and (lastMark == nil or mark < lastMark) then
            log.warnf("fuel falling through %d%%", math.floor(mark * 100))
        elseif lastMark then
            log.infof("fuel rising through %d%%", math.floor(lastMark * 100))
        end
        lastMark = mark
    end
end

local function noteTanks()
    for _, entry in ipairs(tanks) do
        if entry.ok ~= lastOk[entry.side] then
            if entry.ok then log.infof("%s answering again", entry.side)
            else log.errorf("%s stopped answering: %s", entry.side, tostring(entry.err)) end
            lastOk[entry.side] = entry.ok
        end
        if entry.fluid ~= lastFluid[entry.side] then
            log.infof("%s now holds %s", entry.side, entry.fluid or "nothing")
            lastFluid[entry.side] = entry.fluid
        end
    end
end

-- == THE MESSAGE =============================================
-- One flat table, versioned, carrying everything computer 0 needs to draw its
-- FUEL tab without having to ask a follow-up question. The rate and the totals
-- are worked out here because this is the computer with the fast samples; the
-- autopilot adds the one thing only it knows, which is how far away the target
-- is and how fast the ship is closing on it.

local function buildMessage()
    local total, capacity, worst = 0, 0, nil
    local list = {}
    for _, entry in ipairs(tanks) do
        total = total + entry.amount
        capacity = capacity + entry.capacity
        local fraction = entry.capacity > 0 and entry.amount / entry.capacity or 0
        if worst == nil or fraction < worst then worst = fraction end
        list[#list + 1] = {
            side = entry.side,
            fluid = entry.fluid,
            fluids = entry.fluids,
            amount = entry.amount,
            capacity = entry.capacity,
            capSource = entry.capSource,
            ok = entry.ok,
            err = entry.err,
        }
    end

    local rate, samples = fluidRate()
    return {
        v = 1,
        id = os.getComputerID(),
        label = os.getComputerLabel(),
        clock = os.clock(),
        tanks = list,
        total = total,
        capacity = capacity,
        fraction = capacity > 0 and total / capacity or 0,
        worstFraction = worst,
        rate = rate,                -- mB/s, negative is burning
        rateSamples = samples,
        rateWindow = RATE_WINDOW,
        assumedCapacity = ASSUMED_CAP,
    }
end

-- == LOCAL SCREEN ============================================

local function comma(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function levelColour(fraction)
    if fraction <= 0.12 then return colours.red end
    if fraction <= 0.30 then return colours.orange end
    return colours.lime
end

local function drawBar(x, y, width, fraction, colour)
    local filled = math.max(0, math.min(width, math.floor((fraction or 0) * width + 0.5)))
    term.setCursorPos(x, y)
    term.setBackgroundColour(colour)
    term.write(string.rep(" ", filled))
    term.setBackgroundColour(colours.grey)
    term.write(string.rep(" ", width - filled))
    term.setBackgroundColour(colours.black)
end

local function draw(msg, sent)
    local W, H = term.getSize()
    term.setBackgroundColour(colours.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setTextColour(colours.black)
    term.setBackgroundColour(colours.cyan)
    term.write(string.rep(" ", W))
    term.setCursorPos(2, 1)
    term.write("FUEL RELAY  #" .. os.getComputerID())
    local stamp = log.timestamp()
    term.setCursorPos(math.max(1, W - #stamp), 1)
    term.write(stamp)
    term.setBackgroundColour(colours.black)

    local y = 3
    term.setTextColour(levelColour(msg.fraction))
    term.setCursorPos(2, y)
    term.write(string.format("%s / %s mB   %d%%", comma(msg.total), comma(msg.capacity),
        math.floor(msg.fraction * 100 + 0.5)))
    y = y + 1
    drawBar(2, y, W - 2, msg.fraction, levelColour(msg.fraction))
    y = y + 2

    for _, t in ipairs(msg.tanks) do
        if y + 1 > H - 3 then break end
        local fraction = t.capacity > 0 and t.amount / t.capacity or 0
        term.setTextColour(t.ok and colours.white or colours.red)
        term.setCursorPos(2, y)
        term.write(string.format("%-7s %s", t.side,
            t.ok and ((t.fluid or "empty"):gsub("^.*:", "")) or "OFFLINE"))
        term.setTextColour(colours.lightGrey)
        term.setCursorPos(2, y + 1)
        term.write(string.format("  %s/%s %3d%%%s", comma(t.amount), comma(t.capacity),
            math.floor(fraction * 100 + 0.5), t.capSource ~= "reported" and " ~" or ""))
        drawBar(math.min(W - 12, 26), y + 1, 10, fraction, levelColour(fraction))
        y = y + 2
    end

    y = math.min(y + 1, H - 2)
    term.setTextColour(colours.lightGrey)
    term.setCursorPos(2, y)
    if msg.rate then
        term.write(string.format("%+.1f mB/s over %ds", msg.rate, msg.rateWindow))
    else
        term.write("rate: gathering samples")
    end
    term.setCursorPos(2, y + 1)
    term.write(modemSide and ("sent " .. sent .. " on " .. modemSide)
        or "NO MODEM - nothing is being sent")

    term.setCursorPos(2, H)
    term.setTextColour(colours.grey)
    term.write("~ means the maximum is a guess")
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
log.info("=== fuel relay starting ===")

learned = loadLearned()

for _, side in ipairs(MODEM_SIDES) do
    if peripheral.getType(side) == "modem" then
        local wrapped = peripheral.wrap(side)
        -- A wired modem would carry rednet too, but the autopilot is on the
        -- other side of the ship and the point of this computer is that it
        -- needs no cable run. Prefer wireless, take wired only if that is all
        -- there is, and say which in the log so a silent link is findable.
        if wrapped.isWireless and wrapped.isWireless() then modemSide = side; break end
        modemSide = modemSide or side
    end
end

if modemSide then
    local wrapped = peripheral.wrap(modemSide)
    rednet.open(modemSide)
    rednet.host(PROTOCOL, HOSTNAME)
    log.infof("rednet open on %s (%s), id %d, protocol %s", modemSide,
        (wrapped.isWireless and wrapped.isWireless()) and "wireless" or "wired",
        os.getComputerID(), PROTOCOL)
else
    log.error("no modem on any side. readings stay on this screen only.")
end

tanks = findTanks()
log.infof("found %d tank(s)", #tanks)
for _, entry in ipairs(tanks) do
    if learned[entry.side] and learned[entry.side] > entry.capacity then
        entry.capacity, entry.capSource = learned[entry.side], "learned"
    end
    log.infof("  %s  type %s  capacity %d mB (%s)", entry.side,
        peripheral.getType(entry.side), entry.capacity, entry.capSource)
end

if #tanks == 0 then
    log.error("no fluid tanks touching this computer")
    print("No create:fluid_tank found on any side. Attached:")
    for _, side in ipairs(peripheral.getNames()) do
        print("  " .. side .. "  " .. peripheral.getType(side))
    end
    print("")
    print("The computer has to be touching the tanks, or on a wired")
    print("network with them. Run `test` to see the method list.")
    log.close()
    return
end

for _, entry in ipairs(tanks) do readTank(entry) end

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

-- == LOOPS ===================================================

local sent = 0
local latest = buildMessage()


-- == TELEMETRY ===============================================
--
-- A relay that goes quiet is the one event nobody can see from the flight
-- computer, because the way it is seen from there is by the messages stopping.
-- So the relay writes its own last word to its own disk, which is a folder on
-- the host: whatever it was reading, and when, still readable after it fell off
-- the radio. Same shape as the message it broadcasts, because that message is
-- already everything it knows.
local TELEMETRY = fs.combine(DATA, "telemetry")

local function writeTelemetry(message)
    pcall(function()
        if not fs.exists(TELEMETRY) then fs.makeDir(TELEMETRY) end
        local handle = fs.open(fs.combine(TELEMETRY, "snapshot.txt"), "w")
        if not handle then return end
        handle.writeLine("-- rewritten every sample, computer " .. os.getComputerID())
        handle.writeLine("-- clock " .. string.format("%.1f", os.clock()))
        handle.writeLine(textutils.serialise(message))
        handle.close()
    end)
end

local function sampleLoop()
    while true do
        for _, entry in ipairs(tanks) do readTank(entry) end
        local total = 0
        for _, entry in ipairs(tanks) do total = total + entry.amount end
        record(total)
        latest = buildMessage()
        writeTelemetry(latest)
        noteTanks()
        noteLevels(latest.fraction)
        sleep(SAMPLE)
    end
end

local function sendLoop()
    while true do
        rednet.broadcast(link.stamp(latest), PROTOCOL)
        sent = sent + 1
        sleep(SEND_EVERY)
    end
end

-- The autopilot can ask for a reading out of band rather than waiting for the
-- next broadcast, which is what makes `fuel` on computer 0 feel immediate.
local function answerLoop()
    while true do
        local id, message = rednet.receive(PROTOCOL)
        local allowed, why = link.check(id, message)
        if not allowed then
            -- Once, and then counted. A neighbour's autopilot broadcasting at
            -- one a second would otherwise fill this relay's log with the same
            -- sentence and bury the one that mattered.
            if link.refused == 1 then log.warn("refusing messages: " .. tostring(why)) end
        elseif type(message) == "table" and message.cmd == "ping" then
            rednet.send(id, link.stamp(latest), PROTOCOL)
            log.debugf("ping from %d, answered", id)
        end
    end
end

local function screenLoop()
    while true do
        local ok, err = pcall(draw, latest, sent)
        if not ok then log.error("draw: " .. tostring(err)) end
        sleep(0.5)
    end
end

-- Answering the installer's ping, for as long as this relay runs rather than
-- only while the wizard is on its screen. See link.lua for why: a relay that
-- stopped answering the moment it rebooted is a relay that is powered, running
-- and deaf, and the pilot's only way back was reinstalling all four computers.
local function pairLoop()
    link.respond("fuel", function(kind, id, why)
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

log.info("relay running")

local ok, err = pcall(parallel.waitForAny, sampleLoop, screenLoop,
    modemSide and sendLoop or idleLoop,
    modemSide and answerLoop or idleLoop,
    modemSide and pairLoop or idleLoop)

term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.clear()
term.setCursorPos(1, 1)
term.setCursorBlink(true)

if not ok and err ~= "Terminated" then
    local path = log.crash(err, {
        "tanks : " .. #tanks,
        "modem : " .. tostring(modemSide),
        "sent  : " .. sent,
    })
    log.error("crash: " .. tostring(err))
    printError("fuel relay crashed: " .. tostring(err))
    if path then print("written to " .. path) end
end

if modemSide then
    rednet.unhost(PROTOCOL)
    rednet.close(modemSide)
end
log.close()
print("fuel relay stopped.")
