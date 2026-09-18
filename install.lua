-- install.lua -- put Starcatcher on this computer, over the wire, and pair it.
--
--   wget run https://raw.githubusercontent.com/Kkkur/autopilot-lua/master/install.lua
--
-- Reads manifest.lua from the repo, works out what this computer is from what
-- is bolted to it, downloads only the files that role uses and writes them
-- where that role expects them. Adding a file later is an edit to the manifest
-- rather than a new installer on four computers.
--
-- Then it pairs. The flight computer sets the passcode, takes the ids of the
-- other three and pings each one until all three have answered. Every other
-- computer takes the same word, shows its own id and waits to be pinged. A
-- relay answers a ping only when its own passcode matches, which is what makes
-- the checklist mean that both ends typed the same word rather than that both
-- are powered.
--
-- **Pairing happens after the download, never before.** This file has no
-- business carrying a second copy of the link.cfg format. It installs
-- sc/link.lua, loads the copy it has just written, and pairs through that. The
-- path differs by role, so the manifest says where each role's copy landed.
--
-- **There is no embedded fallback copy of the files, and that was ruled on.**
-- The plan carried one, for the case of this wizard arriving by hand while the
-- repo is unreachable. It would be eight thousand lines inside this file that
-- go stale the moment src/ changes, and a wizard that installs a stale ship
-- while saying it installed a whole one is worse than a wizard that stops. If
-- the repo cannot be reached, copy the tree across by hand.

local OWNER, REPO, BRANCH = "Kkkur", "autopilot-lua", "master"
local RAW = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/"
local STAMP = "starcatcher_version.txt"

-- Pairing has its own protocol. The two flight protocols carry orders, and a
-- computer that is still being installed has no business hearing those.
local PAIR = "starcatcher-pair"

-- The three the flight computer collects, in the order the checklist shows
-- them. The names are the manifest's role names, so what is typed at the
-- prompt and what is written into link.peers are the same word.
local PEER_ROLES = { "fuel", "turbine", "cruise" }

local ARGS = { ... }

local function die(...)
    printError(...)
    error("", 0)
end

if not http then
    die("HTTP is off on this server, so nothing can be downloaded.",
        "Copy the files across by hand instead.")
end

-- == THE ID, IN LARGE DIGITS =================================
--
-- First thing on the screen, because the flight computer is about to ask for
-- the other three ids and somebody is going to read them off these screens.
-- Three by five cells drawn as coloured blocks, which is the whole of it: a
-- font here would be a file to download before the downloader runs.

local DIGITS = {
    ["0"] = { "###", "# #", "# #", "# #", "###" },
    ["1"] = { "  #", "  #", "  #", "  #", "  #" },
    ["2"] = { "###", "  #", "###", "#  ", "###" },
    ["3"] = { "###", "  #", "###", "  #", "###" },
    ["4"] = { "# #", "# #", "###", "  #", "  #" },
    ["5"] = { "###", "#  ", "###", "  #", "###" },
    ["6"] = { "###", "#  ", "###", "# #", "###" },
    ["7"] = { "###", "  #", "  #", "  #", "  #" },
    ["8"] = { "###", "# #", "###", "# #", "###" },
    ["9"] = { "###", "# #", "###", "  #", "###" },
}

local BLANK = { "   ", "   ", "   ", "   ", "   " }

local function bigNumber(text)
    for row = 1, 5 do
        for i = 1, #text do
            local glyph = DIGITS[text:sub(i, i)] or BLANK
            local line = glyph[row]
            for c = 1, #line do
                term.setBackgroundColour(line:sub(c, c) == "#" and colours.white or colours.black)
                write("  ")
            end
            term.setBackgroundColour(colours.black)
            write(" ")
        end
        print("")
    end
    term.setBackgroundColour(colours.black)
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

-- == PAIRING =================================================

-- The link module this computer will actually run, loaded from where it was
-- just written. Anything else is a second copy of the file format, and two
-- copies of a file format is how the installer and the program end up
-- disagreeing about what a paired ship looks like.
local function loadLink(spec)
    if type(spec.link) ~= "string" then
        return nil, "the manifest does not say where this role keeps sc/link.lua"
    end
    if not fs.exists(spec.link) then
        return nil, spec.link .. " is not there, so the download did not land"
    end
    local handle = fs.open(spec.link, "r")
    if not handle then return nil, spec.link .. " could not be opened for reading" end
    local body = handle.readAll()
    handle.close()
    local chunk, err = load(body, "@" .. spec.link, "t", _ENV)
    if not chunk then return nil, spec.link .. " did not parse: " .. tostring(err) end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then
        return nil, spec.link .. " did not return a module: " .. tostring(mod)
    end
    mod.init(spec.data)
    return mod
end

local function wirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m.isWireless and m.isWireless() then return name end
        end
    end
    return nil
end

-- Blank means leave this computer unpaired, and it says what that costs. An
-- unpaired ship flies, which is the state every ship is in before the wizard
-- has been round it, and link.lua is loud about it on the screen and in the log
-- from then on.
local function askPasscode(link)
    print("")
    print("The passcode goes on all four computers and has to be the same word")
    print("on each. It travels in the clear, so it is a name tag, not a lock.")
    while true do
        write("passcode (blank to leave this computer unpaired): ")
        local word = read()
        if word == "" then
            link.clear()
            print("")
            print("Left unpaired. This computer answers anything on its protocol,")
            print("and says so at boot and on the PROPS tab until it is paired.")
            return nil
        end
        local ok, why = link.set(word)
        if ok then return word end
        printError(why)
    end
end

local function askPeerId(role, taken)
    while true do
        write("  " .. role .. " relay id: ")
        local answer = read()
        local id = tonumber(answer)
        if not id or id < 0 or id ~= math.floor(id) then
            printError("  a computer id is a whole number, the big one on its screen")
        elseif id == os.getComputerID() then
            printError("  that is this computer's own id")
        elseif taken[id] then
            printError("  #" .. id .. " is already the " .. taken[id] .. " relay")
        else
            taken[id] = role
            return id
        end
    end
end

-- The flight computer's half. It does not continue until all three have
-- answered, on purpose: a ship whose link.peers is short is a ship that flies
-- with a part of itself deaf, and nothing downstream would say so.
local function pairCommand(link, modem)
    local peers, taken = {}, {}
    print("")
    print("Now the other three. Install them first and leave each at its waiting")
    print("screen: a relay that has already rebooted is running the relay program")
    print("and is no longer listening for a ping.")
    print("")
    for _, role in ipairs(PEER_ROLES) do
        peers[role] = askPeerId(role, taken)
    end

    rednet.open(modem)
    print("")
    print("Pinging. This waits until all three answer. Ctrl and T to give up.")
    print("")
    local _, top = term.getCursorPos()
    for _ = 1, #PEER_ROLES + 1 do print("") end

    local answered = {}
    local function redraw(note)
        for i, role in ipairs(PEER_ROLES) do
            term.setCursorPos(1, top + i - 1)
            term.clearLine()
            write(string.format("  %-8s #%-4d %s", role, peers[role],
                answered[role] and "here" or "waiting"))
        end
        term.setCursorPos(1, top + #PEER_ROLES)
        term.clearLine()
        if note then write("  " .. note) end
        term.setCursorPos(1, top + #PEER_ROLES + 1)
    end
    redraw()

    while true do
        local waiting = 0
        for _, role in ipairs(PEER_ROLES) do
            if not answered[role] then
                waiting = waiting + 1
                rednet.send(peers[role], link.stamp({ kind = "ping", role = role }), PAIR)
            end
        end
        if waiting == 0 then break end

        local deadline = os.clock() + 2
        while os.clock() < deadline do
            local id, message = rednet.receive(PAIR, deadline - os.clock())
            if not id then break end
            local allowed, why = link.check(id, message)
            if not allowed then
                redraw(why)
            elseif type(message) == "table" and message.kind == "here" then
                local hit = nil
                for _, role in ipairs(PEER_ROLES) do
                    if peers[role] == id then hit = role end
                end
                if hit then
                    answered[hit] = true
                    redraw()
                else
                    redraw("#" .. id .. " answered and is not one of the three")
                end
            end
        end
    end

    rednet.close(modem)
    link.peers = peers
    link.save()
    print("")
    print("All three answered to the same passcode. The ship is paired.")
end

-- Every other computer's half. It answers pings for as long as the pilot leaves
-- this screen up, because the flight computer may be installed last and may be
-- retried, and a relay that answered once and stopped listening looks from the
-- other end exactly like a relay that never heard.
local function pairRelay(link, modem, role)
    rednet.open(modem)
    print("")
    print("Waiting to be pinged by the flight computer. Leave this screen up")
    print("until it says it has all three, then press Enter.")
    print("")

    local seen = {}
    local function listen()
        while true do
            local id, message = rednet.receive(PAIR)
            local allowed, why = link.check(id, message)
            if not allowed then
                print("  refused: " .. why)
            elseif type(message) == "table" and message.kind == "ping" then
                rednet.send(id, link.stamp({
                    kind = "here",
                    role = role,
                    id = os.getComputerID(),
                }), PAIR)
                if not seen[id] then
                    seen[id] = true
                    print("  answered the flight computer, #" .. id)
                    link.peers = { command = id }
                    link.save()
                end
            end
        end
    end

    parallel.waitForAny(listen, function() read() end)
    rednet.close(modem)
end

local function pair(link, spec, role)
    local word = askPasscode(link)
    if not word then return end
    local modem = wirelessModem()
    if not modem then
        printError("")
        printError("No wireless modem on this computer, so it cannot be paired now.")
        printError("Bolt one on, then set the same word on each computer by hand:")
        printError("  flight computer: passcode <word>")
        printError("  either relay: fuel_relay --passcode <word>")
        return
    end
    if role == "command" then
        pairCommand(link, modem)
    else
        pairRelay(link, modem, role)
    end
end

-- == RUN =====================================================

term.clear()
term.setCursorPos(1, 1)
print("Starcatcher installer. This computer is")
print("")
bigNumber(tostring(os.getComputerID()))
print("")
if os.getComputerLabel() then print("labelled " .. os.getComputerLabel()) end

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
for _, entry in ipairs(spec.files) do
    local from, to = entry[1], entry[2]
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

-- The stamp is the record of which manifest this computer was installed from,
-- read off the disk by whoever is standing in front of it or by the tools on
-- the desktop. Nothing in the program reads it yet. It is written last, so a
-- half finished install never claims to be a whole one.
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

-- Pairing goes through the module that was just installed, and a failure to
-- pair is not a failure to install: the files are down and stamped either way,
-- and an unpaired ship flies.
local link, linkErr = loadLink(spec)
if not link then
    printError("")
    printError("Installed, but not paired: " .. linkErr)
    printError("Set the passcode by hand on all four computers once that is fixed.")
else
    pair(link, spec, role)
end

print("")
write("Reboot now? [Y/n] ")
if (read():lower() or "") ~= "n" then os.reboot() end
