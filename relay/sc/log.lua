-- log.lua -- one ring buffer for the LOG tab, one file per session on disk.
--
-- The on-screen buffer is what the pilot reads while flying. The file is what
-- gets read afterwards when something went wrong, and it is flushed on every
-- line because a crash is exactly when the tail matters.

local log = {}

local LEVELS = { ERROR = 0, WARN = 1, INFO = 2, DEBUG = 3 }

log.lines = {}      -- newest last: {t = clock, level = "INFO", msg = "..."}
log.MAX_LINES = 200
log.file = nil
log.path = nil
log.dir = nil
log.levelFn = function() return 2 end
log.seq = 0
log.dropped = 0     -- lines the disk refused, which is how a full disk is seen
log.KEEP_FILES = 8  -- sessions kept on disk, oldest deleted at the next boot

local function nextLogNumber(dir)
    local highest = 0
    if fs.exists(dir) then
        for _, name in ipairs(fs.list(dir)) do
            local n = tonumber(name:match("^log_(%d+)%.txt$") or "")
            if n and n > highest then highest = n end
        end
    end
    return highest + 1
end

function log.timestamp()
    local secs = math.floor(os.clock())
    return string.format("%02d:%02d:%02d",
        math.floor(secs / 3600) % 24, math.floor(secs / 60) % 60, secs % 60)
end

-- A CC: Tweaked computer holds about a megabyte and says nothing about it
-- until a write fails somewhere else entirely: the first sign here was an
-- installer that could not land a file. One session is one log file, so the
-- files are what grows without limit, and the oldest of them are worth least.
local function pruneLogs(dir)
    local numbers = {}
    for _, name in ipairs(fs.list(dir)) do
        local n = tonumber(name:match("^log_(%d+)%.txt$") or "")
        if n then numbers[#numbers + 1] = n end
    end
    table.sort(numbers)
    for index = 1, #numbers - (log.KEEP_FILES - 1) do
        pcall(fs.delete, fs.combine(dir, "log_" .. numbers[index] .. ".txt"))
    end
end

function log.init(dataDir, levelFn)
    log.dir = fs.combine(dataDir, "logs")
    if not fs.exists(log.dir) then fs.makeDir(log.dir) end
    if levelFn then log.levelFn = levelFn end
    pcall(pruneLogs, log.dir)
    log.path = fs.combine(log.dir, "log_" .. nextLogNumber(log.dir) .. ".txt")
    log.file = fs.open(log.path, "w")
    log.write("INFO", "log opened: " .. log.path)
    return log
end

function log.write(level, msg)
    local want = LEVELS[level] or 2
    log.seq = log.seq + 1
    local entry = { t = os.clock(), level = level, msg = tostring(msg), seq = log.seq }

    -- The screen buffer honours the level filter. The file does not: a debug
    -- line that was filtered off the screen is still the one you want later.
    if want <= (log.levelFn() or 2) then
        log.lines[#log.lines + 1] = entry
        while #log.lines > log.MAX_LINES do table.remove(log.lines, 1) end
    end

    -- The disk filling up must not take the ship down with it. A write that
    -- fails is counted and the file is let go of, so the screen buffer carries
    -- on and the loop that was flying carries on with it.
    if log.file then
        local ok = pcall(function()
            log.file.writeLine(string.format("[%s] [%s] %s", log.timestamp(), level, entry.msg))
            log.file.flush()
        end)
        if not ok then
            log.dropped = log.dropped + 1
            pcall(log.file.close)
            log.file = nil
        end
    end
end

function log.info(msg)  log.write("INFO", msg) end
function log.warn(msg)  log.write("WARN", msg) end
function log.error(msg) log.write("ERROR", msg) end
function log.debug(msg) log.write("DEBUG", msg) end

function log.infof(fmt, ...)  log.write("INFO",  string.format(fmt, ...)) end
function log.warnf(fmt, ...)  log.write("WARN",  string.format(fmt, ...)) end
function log.errorf(fmt, ...) log.write("ERROR", string.format(fmt, ...)) end
function log.debugf(fmt, ...) log.write("DEBUG", string.format(fmt, ...)) end

function log.close()
    if log.file then
        log.write("INFO", "session ending")
        log.file.close()
        log.file = nil
    end
end

-- Written next to the logs when the top level pcall catches something, with
-- whatever the caller thought was worth knowing about the flight at the time.
function log.crash(err, facts)
    local dir = fs.combine(log.dir or "", "crashes")
    if not fs.exists(dir) then fs.makeDir(dir) end
    local n = 1
    while fs.exists(fs.combine(dir, "crash_" .. n .. ".txt")) do n = n + 1 end
    local path = fs.combine(dir, "crash_" .. n .. ".txt")
    local handle = fs.open(path, "w")
    if not handle then return nil end
    handle.writeLine("=== FUEL RELAY CRASH ===")
    handle.writeLine("time  : " .. log.timestamp())
    handle.writeLine("error : " .. tostring(err))
    for _, line in ipairs(facts or {}) do handle.writeLine(line) end
    handle.writeLine("")
    handle.writeLine("--- last " .. #log.lines .. " log lines ---")
    for _, entry in ipairs(log.lines) do
        handle.writeLine(string.format("[%s] %s", entry.level, entry.msg))
    end
    handle.close()
    return path
end

return log
