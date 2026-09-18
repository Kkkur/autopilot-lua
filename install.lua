-- install.lua -- put Starcatcher on this computer, over the wire.
--
--   wget run https://raw.githubusercontent.com/Kkkur/autopilot-lua/master/install.lua
--
-- Reads manifest.lua from the repo, works out what this computer is from what
-- is bolted to it, downloads only the files that role uses and writes them
-- where that role expects them. Adding a file later is an edit to the manifest
-- rather than a new installer on four computers.
--
-- What this is not, yet. The plan has the installer also doing the pairing: the
-- passcode, the peer ids and the live checklist of who has answered. None of
-- that is here because none of it exists yet, it is stage 8, and an installer
-- that asked for a passcode nothing reads would be a wizard that lies. This is
-- the delivery half only. When the passcode lands, the pairing half joins it
-- here and the big computer id goes on the screen with it, because reading an
-- id off a screen is only worth doing when something is about to ask for it.

local OWNER, REPO, BRANCH = "Kkkur", "autopilot-lua", "master"
local RAW = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/"
local STAMP = "starcatcher_version.txt"

local ARGS = { ... }

local function die(...)
    printError(...)
    error("", 0)
end

if not http then
    die("HTTP is off on this server, so nothing can be downloaded.",
        "Copy the files across by hand instead.")
end

-- == FETCHING ================================================

-- A cache buster, because CC caches a raw.githubusercontent response and a
-- reinstall after a push would otherwise hand back the file from before it.
local function fetch(path)
    local url = RAW .. path .. "?at=" .. tostring(os.epoch and os.epoch("utc") or os.clock())
    local handle, err = http.get(url)
    if not handle then return nil, tostring(err) end
    local body = handle.readAll()
    handle.close()
    return body
end

-- == WHICH COMPUTER IS THIS ==================================
--
-- Each computer picks its own role, out of what it can see. A relay is self
-- describing and the flight computer is the one holding the instrument that
-- reads the ship's pose, so none of this has to be remembered by whoever is
-- standing at the keyboard.
local function look()
    local found = { controllers = 0 }
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if type(p) == "table" then
            if p.setTargetSpeed and p.getTargetSpeed then
                found.controllers = found.controllers + 1
            end
            if p.getStress and p.getStressCapacity then found.stressometer = true end
            if p.setAnalogOutput then found.redstone = true end
            if peripheral.hasType(name, "fluid_storage")
                or (peripheral.getType(name) or ""):find("fluid_tank") then
                found.tanks = true
            end
            if p.isWireless then found.modem = true end
        end
    end
    found.sublevel = type(sublevel) == "table"
    return found
end

local function guess(found)
    -- The redstone relay first, because that is the same test the relay program
    -- itself uses to decide it is the one holding the balloon. Two answers to
    -- one question is how they end up disagreeing.
    if found.redstone then return "cruise" end
    if found.tanks then return "fuel" end
    if found.sublevel then return "command" end
    if found.controllers > 0 then return "turbine" end
    return nil
end

local function describe(found)
    local parts = {}
    if found.sublevel then parts[#parts + 1] = "CC: Sable" end
    if found.controllers > 0 then
        parts[#parts + 1] = found.controllers .. " speed controller(s)"
    end
    if found.stressometer then parts[#parts + 1] = "a stressometer" end
    if found.redstone then parts[#parts + 1] = "a redstone relay" end
    if found.tanks then parts[#parts + 1] = "fluid tanks" end
    if found.modem then parts[#parts + 1] = "a modem" end
    if #parts == 0 then return "nothing at all" end
    return table.concat(parts, ", ")
end

-- == RUN =====================================================

print("Starcatcher installer")
print("computer " .. os.getComputerID() ..
    (os.getComputerLabel() and (", labelled " .. os.getComputerLabel()) or ""))
print("")

local body, err = fetch("manifest.lua")
if not body then die("could not read the manifest: " .. err) end
local chunk, loadErr = load(body, "@manifest.lua", "t", _ENV)
if not chunk then die("the manifest did not parse: " .. tostring(loadErr)) end
local ok, manifest = pcall(chunk)
if not ok or type(manifest) ~= "table" then
    die("the manifest did not return a table: " .. tostring(manifest))
end

print("manifest " .. tostring(manifest.version) .. "  " .. tostring(manifest.note))
print("")

local found = look()
print("on this computer: " .. describe(found))

local role = ARGS[1] and ARGS[1]:lower() or nil
if role and not manifest.roles[role] then
    die("no such role: " .. role,
        "the roles are command, fuel, turbine and cruise")
end

if not role then
    role = guess(found)
    if not role then
        print("")
        print("Nothing here says what this computer is. Name it yourself:")
        print("  install command | fuel | turbine | cruise")
        return
    end
    print("so this is the " .. manifest.roles[role].title .. ".")
    write("Right? [Y/n] ")
    local answer = read():lower()
    if answer == "n" or answer == "no" then
        print("Run it again with the role you want:")
        print("  install command | fuel | turbine | cruise")
        return
    end
end

local spec = manifest.roles[role]
print("")
print("installing the " .. spec.title .. ", " .. #spec.files .. " files")

local written, failed = 0, {}
for _, pair in ipairs(spec.files) do
    local from, to = pair[1], pair[2]
    write("  " .. to .. " ")
    local text, fetchErr = fetch(from)
    if not text then
        failed[#failed + 1] = to .. ": " .. fetchErr
        print("FAILED")
    else
        local dir = fs.getDir(to)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local handle = fs.open(to, "w")
        if not handle then
            failed[#failed + 1] = to .. ": could not be opened for writing"
            print("FAILED")
        else
            handle.write(text)
            handle.close()
            written = written + 1
            print("ok")
        end
    end
end

print("")
if #failed > 0 then
    printError(#failed .. " file(s) did not land:")
    for _, line in ipairs(failed) do printError("  " .. line) end
    printError("Nothing has been stamped. Run it again rather than rebooting.")
    return
end

-- The stamp is what `check` reads later to say a computer is behind. It is
-- written last, so a half finished install never claims to be a whole one.
local stamp = fs.open(STAMP, "w")
if stamp then
    stamp.writeLine(tostring(manifest.version))
    stamp.writeLine(role)
    stamp.writeLine(tostring(os.day()) .. " " .. tostring(math.floor(os.time() * 1000)))
    stamp.close()
end

print(written .. " files written. This is the " .. spec.title ..
    ", version " .. tostring(manifest.version) .. ".")
print("What it writes itself goes in " .. spec.data .. "/ and is never downloaded over.")
print("")
write("Reboot now? [Y/n] ")
if (read():lower() or "") ~= "n" then os.reboot() end
