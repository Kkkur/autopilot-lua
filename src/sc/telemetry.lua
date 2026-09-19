-- telemetry.lua -- what the ship was doing, written down where it can be read.
--
-- The simulator is gone as the way this gets tested. Testing happens on the
-- real ship now, which means the only thing anyone on the outside can see is
-- what the computers write to their own disks. A CC: Tweaked computer's
-- filesystem is a folder on the host, so a file written here is a file readable
-- there, and that is the whole idea.
--
-- Three things get written, and they are three because they answer three
-- different questions.
--
--   snapshot.txt   what the ship is doing right now. Rewritten every sample,
--                  never appended, so reading it costs one read and never a
--                  search for the end. This is the one to look at while the
--                  ship is in the air.
--   flight.csv     one row per sample, with a header. This is the one to look
--                  at afterwards, when the question is what changed and when.
--   events.csv     one row per thing that happened rather than per tick: a
--                  phase change, a gate refusal, a safe hold, an alarm. A
--                  per tick file buries these, which is why they are separate.
--
-- Nothing here is allowed to be load bearing. Every write is wrapped, a full
-- disk or a missing folder costs a dropped sample and never a flight, because a
-- ship that falls out of the sky over a log file is worse than no log file.

local util, config = ...

local telemetry = {}

telemetry.dir = nil
telemetry.enabled = false
telemetry.dropped = 0        -- writes that failed, reported on the screen
telemetry.samples = 0

local csv = nil              -- the open flight.csv handle
local events = nil           -- the open events.csv handle
local csvPath, eventPath, snapPath = nil, nil, nil
local written = 0            -- bytes into the current flight.csv, roughly

-- The columns, in order, and the only place the order is written down. Both the
-- header and every row are built from this, so a column added here appears in
-- both or in neither.
telemetry.COLUMNS = {
    "t", "phase", "running", "safe", "status",
    "px", "py", "pz", "yaw", "pitch", "yawRate",
    "vx", "vy", "vz", "fwd", "speed",
    "tx", "ty", "tz", "dist", "remaining", "err", "lateral",
    "want", "common", "differential", "wantDiff", "balloon", "altErr",
    "ctlDt", "vValid", "response", "envelope", "brakeMode", "stopDist",
    "aDemand", "saturated", "terminal", "motionWhy", "yawWhy",
    "fuelPct", "fuelBurn", "endurance",
    "stressPct", "stress", "stressCap", "links", "popup", "demands",
}

-- == PLUMBING ================================================

local function safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then telemetry.dropped = telemetry.dropped + 1 end
    return ok, err
end

local function nextNumber(dir, pattern)
    local highest = 0
    if fs.exists(dir) then
        for _, name in ipairs(fs.list(dir)) do
            local n = tonumber(name:match(pattern) or "")
            if n and n > highest then highest = n end
        end
    end
    return highest + 1
end

-- A CC: Tweaked computer holds about a megabyte and nothing in the game says
-- so until a write fails. The rotation on its own only decided how big each
-- file was, never how many there were, so a ship that flew often filled its
-- own disk and the first thing to notice was the installer failing to write a
-- file. The oldest files go when a new one starts: the record of the flight
-- happening now is worth more than the record of the tenth one back.
local function prune()
    local keep = config.get("telemetryKeep")
    local numbers = {}
    for _, name in ipairs(fs.list(telemetry.dir)) do
        local n = tonumber(name:match("^flight_(%d+)%.csv$") or "")
        if n then numbers[#numbers + 1] = n end
    end
    table.sort(numbers)
    for index = 1, #numbers - keep do
        pcall(fs.delete, fs.combine(telemetry.dir, "flight_" .. numbers[index] .. ".csv"))
    end
end

local function openCsv()
    local n = nextNumber(telemetry.dir, "^flight_(%d+)%.csv$")
    csvPath = fs.combine(telemetry.dir, "flight_" .. n .. ".csv")
    csv = fs.open(csvPath, "w")
    written = 0
    if csv then
        csv.writeLine(table.concat(telemetry.COLUMNS, ","))
        csv.flush()
    end
    safely(prune)
end

function telemetry.init(dataDir)
    telemetry.dir = fs.combine(dataDir, "telemetry")
    if not fs.exists(telemetry.dir) then fs.makeDir(telemetry.dir) end
    snapPath = fs.combine(telemetry.dir, "snapshot.txt")
    eventPath = fs.combine(telemetry.dir, "events.csv")

    local fresh = not fs.exists(eventPath)
    events = fs.open(eventPath, fresh and "w" or "a")
    if events then
        if fresh then events.writeLine("t,kind,what,detail") end
        events.flush()
    end

    safely(openCsv)
    telemetry.enabled = true
    return telemetry
end

function telemetry.close()
    if csv then pcall(csv.close); csv = nil end
    if events then pcall(events.close); events = nil end
    telemetry.enabled = false
end

-- A comma or a newline inside a field would put the next reader one column out,
-- and the fields here carry sentences written for a pilot.
local function field(value)
    if value == nil then return "" end
    if type(value) == "boolean" then return value and "1" or "0" end
    if type(value) == "number" then
        if value ~= value then return "nan" end
        return string.format("%.3f", value):gsub("%.?0+$", "")
    end
    return (tostring(value):gsub("[,\r\n]", " "))
end

-- == EVENTS ==================================================
--
-- Anything worth a line of its own. The kind is what to grep for from the host:
-- phase, gate, safehold, alarm, popup, boot.
function telemetry.event(kind, what, detail)
    if not events then return end
    safely(function()
        events.writeLine(table.concat({
            field(util.now()), field(kind), field(what), field(detail),
        }, ","))
        events.flush()
    end)
end

-- == THE SAMPLE ==============================================

-- Everything that is known about the ship at one instant, from the three places
-- that know it. None of these calls touch a peripheral: the pose is the one the
-- control loop already read, and both statuses are read off what the relays
-- last said over the radio. So a sample costs no server tick, which is why it
-- can run at its own rate rather than on the control loop's.
function telemetry.sample(snap, tanks, turbines, popup)
    if not telemetry.enabled then return end
    telemetry.samples = telemetry.samples + 1

    local state = snap.state or {}
    local pos = state.position or {}
    local vel = state.velocity or {}
    local target = snap.hold or snap.target or {}
    local info = snap.info or {}

    local links = {}
    for _, one in ipairs(turbines.relays or {}) do
        links[#links + 1] = string.format("%s:%s", tostring(one.relayId), tostring(one.link))
    end
    links[#links + 1] = "fuel:" .. tostring(tanks.link)

    local demands = {}
    for name, rpm in pairs(snap.demands or {}) do
        demands[#demands + 1] = string.format("%s=%d", util.shortName(name), util.round(rpm))
    end
    table.sort(demands)

    local row = {
        t = util.now(),
        phase = snap.phase,
        running = snap.running,
        safe = snap.safe,
        status = snap.status,
        px = pos.x, py = pos.y, pz = pos.z,
        yaw = state.yaw,
        pitch = info.pitch,
        yawRate = info.yawRate,
        vx = vel.x, vy = vel.y, vz = vel.z,
        fwd = state.bz,
        speed = state.speed,
        tx = target.x, ty = target.y, tz = target.z,
        dist = snap.dist,
        remaining = info.remaining,
        err = info.err,
        lateral = info.lateral,
        want = info.want,
        common = info.common,
        differential = info.differential,
        wantDiff = info.wantDiff,
        balloon = info.balloon,
        altErr = info.altErr,
        -- The control loop's own period, not this file's sampling interval.
        -- A row that implied the logging rate was the controller would send
        -- anyone reading it after a flight looking for the wrong fault.
        ctlDt = info.dt,
        vValid = info.vValid,
        response = info.response,
        envelope = info.envelope,
        brakeMode = info.brakeMode,
        stopDist = info.stopDist,
        aDemand = info.aDemand,
        saturated = info.saturated,
        terminal = info.terminal,
        motionWhy = info.motionWhy,
        yawWhy = info.yawWhy,
        fuelPct = tanks.fraction and tanks.fraction * 100 or nil,
        fuelBurn = tanks.burn,
        endurance = tanks.endurance,
        stressPct = turbines.fraction and turbines.fraction * 100 or nil,
        stress = turbines.stress,
        stressCap = turbines.capacity,
        links = table.concat(links, " "),
        popup = popup,
        demands = table.concat(demands, " "),
    }

    safely(telemetry.writeRow, row, snap)
end

function telemetry.writeRow(row, snap)
    if csv then
        local cells = {}
        for index, name in ipairs(telemetry.COLUMNS) do cells[index] = field(row[name]) end
        local text = table.concat(cells, ",")
        csv.writeLine(text)
        csv.flush()
        written = written + #text + 1
        -- One flight, one file, until it gets big enough to be slow to open. A
        -- rotation loses nothing: the rows carry a clock and the files are
        -- numbered in order.
        if written > config.get("telemetryMaxKb") * 1024 then
            pcall(csv.close)
            openCsv()
        end
    end

    if snapPath then
        local handle = fs.open(snapPath, "w")
        if handle then
            handle.writeLine("-- starcatcher telemetry, rewritten every sample")
            handle.writeLine("computer   = " .. os.getComputerID())
            handle.writeLine("samples    = " .. telemetry.samples)
            handle.writeLine("dropped    = " .. telemetry.dropped)
            handle.writeLine("csv        = " .. tostring(csvPath))
            handle.writeLine("")
            for _, name in ipairs(telemetry.COLUMNS) do
                handle.writeLine(string.format("%-12s = %s", name, field(row[name])))
            end
            handle.writeLine("")
            handle.writeLine("reason     = " .. field(snap.reason))
            handle.writeLine("fault      = " .. field(snap.fault))
            handle.writeLine("target     = " .. field(snap.targetName))
            handle.close()
        end
    end
end

return telemetry
