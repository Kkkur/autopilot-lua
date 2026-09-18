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
-- computer takes the same word, shows its own id and answers pings. A relay
-- answers only when its own passcode matches, which is what makes the checklist
-- mean that both ends typed the same word rather than that both are powered.
--
-- **The asking and the answering both live in sc/link.lua**, and the relay
-- programs run the same responder for as long as they run. So the order the
-- four computers are installed in does not matter and neither does which
-- screen is up: a relay that has rebooted into its own program still answers.
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

-- The three the flight computer collects, in the order the checklist shows
-- them. The names are the manifest's role names, so what is typed at the
-- prompt and what is written into link.peers are the same word.
local PEER_ROLES = { "fuel", "turbine", "cruise" }

-- What each of them hosts on rednet. This is the one question that can be put
-- to a computer whose program is too old to answer a pairing ping: rednet's
-- own lookup is answered by CC: Tweaked itself and not by anything in this
-- repository, so a relay that is running answers it whatever version it is
-- carrying. That is what tells a relay that is switched off apart from a relay
-- that is switched on and deaf, and those two have different fixes.
local PEER_PROTOCOL = {
    fuel = "starcatcher-fuel",
    turbine = "starcatcher-turbine",
    cruise = "starcatcher-turbine",
}

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
-- Each computer picks its own role, out of what is bolted to it. A relay is
-- self describing: the tanks, the speed controllers and the redstone relay each
-- say what that computer is for, so none of it has to be remembered by whoever
-- is standing at the keyboard.
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

-- Asked hardest question first, and the flight computer last, because it is the
-- only role with no positive test. It is defined by what it does not have: it
-- owns nothing that spins.
--
-- The first version asked about CC: Sable third and got this wrong on every
-- ship. `sublevel` is a global API and not a peripheral, so it is on every
-- computer the mod is loaded on, and the turbine relay was told it was the
-- flight computer while its own screen listed the speed controllers that prove
-- it is not.
local function guess(found)
    -- The redstone relay first, because that is the same test the relay program
    -- itself uses to decide it is the one holding the balloon. Two answers to
    -- one question is how they end up disagreeing.
    if found.redstone then return "cruise" end
    if found.tanks then return "fuel" end
    if found.controllers > 0 then return "turbine" end
    if found.modem or found.sublevel then return "command" end
    return nil
end

local function describe(found)
    local parts = {}
    -- Said because its absence is worth knowing, not because it tells the
    -- roles apart. It is a global API and every computer on a ship with the mod
    -- loaded has it.
    if found.sublevel then parts[#parts + 1] = "the CC: Sable API" end
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
    -- Blank means two different things, and which one it means depends on
    -- whether this computer is already paired. Reinstalling is the ordinary way
    -- a fix reaches a relay, and a reinstall that quietly unpaired the ship
    -- because the pilot pressed Enter would be a wizard that breaks what it was
    -- run to repair. Forgetting a passcode stays possible, by typing a new one
    -- here or by `--passcode` on the relay itself.
    local already = link.pass
    local prompt = already
        and "passcode (blank to keep the one already set): "
        or "passcode (blank to leave this computer unpaired): "
    while true do
        write(prompt)
        local word = read()
        if word == "" and already then
            print("")
            print("Keeping the passcode this computer already had.")
            return already
        end
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
--
-- The asking is link.sweep's, not this file's, so the installer and the `ping`
-- command on the flight computer ask the same question in the same words.
local function pairCommand(link, modem)
    local peers, taken = {}, {}
    print("")
    print("Now the other three. Install them first and let them reboot: each one")
    print("answers from its own program, so the order does not matter and no")
    print("screen has to be left up anywhere.")
    print("")
    for _, role in ipairs(PEER_ROLES) do
        peers[role] = askPeerId(role, taken)
    end

    rednet.open(modem)
    print("")
    print("Pinging. This waits until all three answer. Ctrl and T to give up.")
    print("")
    local _, top = term.getCursorPos()
    local NOTE_LINES = 3
    for _ = 1, #PEER_ROLES + NOTE_LINES do print("") end

    local answered = {}
    local reasons = {}          -- why a peer is still silent, in its own words

    local function redraw(note)
        for i, role in ipairs(PEER_ROLES) do
            term.setCursorPos(1, top + i - 1)
            term.clearLine()
            local said = answered[role]
            local state = said and ("here, says it is the " .. said)
                or (reasons[role] and reasons[role].tag or "waiting")
            write(string.format("  %-8s #%-4d %s", role, peers[role], state))
        end
        -- The note area says the whole of one fault rather than the first
        -- forty characters of it. A sentence that tells the pilot to reinstall
        -- a computer is worthless cut off at the word "reinstall".
        local said = note
        if not said then
            for _, role in ipairs(PEER_ROLES) do
                if not answered[role] and reasons[role] then
                    said = reasons[role].say
                    break
                end
            end
        end
        local wrapped = {}
        for word in tostring(said or ""):gmatch("%S+") do
            local last = wrapped[#wrapped]
            if last and #last + #word + 1 <= 48 then
                wrapped[#wrapped] = last .. " " .. word
            else
                wrapped[#wrapped + 1] = word
            end
        end
        for offset = 0, NOTE_LINES - 1 do
            term.setCursorPos(1, top + #PEER_ROLES + offset)
            term.clearLine()
            if wrapped[offset + 1] then write("  " .. wrapped[offset + 1]) end
        end
        term.setCursorPos(1, top + #PEER_ROLES + NOTE_LINES)
    end
    redraw()

    -- A peer that says nothing looks the same whatever is wrong with it, and
    -- this screen used to sit saying "waiting" at all three until somebody
    -- walked away. So after a few fruitless sweeps it asks rednet who is out
    -- there at all, which separates a relay that is off or out of range from
    -- one that is running a program older than the pairing responder. The
    -- second of those answers no ping ever, however long the wizard waits.
    local function diagnose()
        local seen, asked = {}, {}
        for _, role in ipairs(PEER_ROLES) do
            local protocol = PEER_PROTOCOL[role]
            if not answered[role] and protocol and not asked[protocol] then
                asked[protocol] = true
                for _, id in ipairs({ rednet.lookup(protocol) }) do seen[id] = true end
            end
        end
        for _, role in ipairs(PEER_ROLES) do
            local id = peers[role]
            if answered[role] then
                reasons[role] = nil
            elseif seen[id] then
                reasons[role] = {
                    tag = "running, but deaf",
                    say = string.format(
                        "#%d is running and hosting %s, so it is powered and in range, "
                        .. "and it did not answer the ping. Its program is older than the "
                        .. "pairing responder. Run the installer on #%d again.",
                        id, PEER_PROTOCOL[role], id),
                }
            else
                reasons[role] = {
                    tag = "nothing heard",
                    say = string.format(
                        "#%d has said nothing at all. It is switched off, out of modem "
                        .. "range, or sitting at a shell rather than running its own "
                        .. "program. It answers from that program, so reboot it.", id),
                }
            end
        end
    end

    local rounds = 0
    while true do
        local asking = {}
        for _, role in ipairs(PEER_ROLES) do
            if not answered[role] then asking[#asking + 1] = peers[role] end
        end
        if #asking == 0 then break end

        local replies, refusals = link.sweep(asking, 2)
        local note = nil
        for _, role in ipairs(PEER_ROLES) do
            local id = peers[role]
            if replies[id] then
                answered[role] = replies[id]
                reasons[role] = nil
                -- Worth saying rather than swallowing. A computer that answers
                -- to the cruise slot calling itself the turbine relay is a
                -- redstone relay on the wrong computer, and it is far cheaper
                -- to read that here than out of a balloon that never moves.
                if replies[id] ~= role then
                    note = string.format("#%d answered the %s slot calling itself the %s",
                        id, role, replies[id])
                end
            elseif refusals[id] then
                -- A refusal is the one fault the ping itself can name, and it
                -- beats anything the lookup could work out, so it wins the row.
                reasons[role] = { tag = "refused the ping", say = refusals[id] }
            end
        end

        rounds = rounds + 1
        -- Two sweeps first, because a relay that is mid reboot answers the
        -- third, and telling a pilot to reinstall a computer that was about to
        -- answer is worse than four seconds of "waiting". Then every tenth, so
        -- a diagnosis that has gone stale is replaced rather than left up.
        if rounds == 2 or rounds % 10 == 0 then diagnose() end
        redraw(note)
    end

    rednet.close(modem)
    link.peers = peers
    link.save()
    print("")
    print("All three answered to the same passcode. The ship is paired.")
end

-- A relay has nothing to wait for. It answers the flight computer's ping from
-- its own program, for as long as it runs, so the passcode is the whole of its
-- half of the pairing and the sooner it reboots into that program the sooner it
-- can be found. This used to hold a screen open until somebody pressed Enter,
-- which was the wizard being the only window a relay could be seen through.
local function pair(link, spec, role)
    local word = askPasscode(link)

    if role ~= "command" then
        if word then
            print("")
            print("Paired. This relay answers the flight computer from its own")
            print("program once it has rebooted, so there is nothing to wait for.")
        end
        if word and not wirelessModem() then
            printError("")
            printError("No wireless modem on this computer, so nothing can reach it.")
            printError("Bolt one on and reboot. The passcode is already saved.")
        end
        return
    end

    if not word then return end
    local modem = wirelessModem()
    if not modem then
        printError("")
        printError("No wireless modem on this computer, so it cannot ping anybody.")
        printError("Bolt one on, then set the same word on each computer by hand:")
        printError("  flight computer: passcode <word>")
        printError("  either relay: fuel_relay --passcode <word>")
        return
    end
    pairCommand(link, modem)
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

-- A CC: Tweaked computer holds about a megabyte, and the game says nothing
-- about that until a write fails. What fills one is never the program, which
-- is a few hundred kilobytes: it is what the program wrote about itself, a
-- flight csv and a log file per session. So the room is counted out loud
-- before anything is downloaded, because a pilot told at the start that the
-- disk is nearly full can clear it before a half installed ship is on it.
local free = fs.getFreeSpace("/")
if type(free) == "number" then
    print(string.format("%d kB free on this computer", math.floor(free / 1024)))
end

local written, failed, noRoom = 0, {}, false
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
            -- A full disk raises here rather than returning anything, and an
            -- unguarded raise took the installer out mid file, leaving a
            -- truncated program on the computer and no word of why. The part
            -- file goes with it: half a module is worse than none, since the
            -- next boot loads it and fails somewhere further in.
            local ok, why = pcall(function()
                handle.write(text)
                handle.close()
            end)
            if ok then
                written = written + 1
                print("ok")
            else
                pcall(handle.close)
                pcall(fs.delete, to)
                local text_ = tostring(why)
                if text_:find("out of space") then
                    noRoom = true
                    failed[#failed + 1] = to .. ": no room left on this computer"
                else
                    failed[#failed + 1] = to .. ": " .. text_
                end
                print("FAILED")
            end
        end
    end
end

print("")
if #failed > 0 then
    printError(#failed .. " file(s) did not land:")
    for _, line in ipairs(failed) do printError("  " .. line) end
    if noRoom then
        printError("")
        printError("The disk is full. The program is not what fills it. These are,")
        printError("and both are records rather than program, safe to delete:")
        printError("  " .. spec.data .. "/telemetry   one csv per flight")
        printError("  " .. spec.data .. "/logs        one file per session")
        printError("  delete " .. spec.data .. "/telemetry")
        printError("Then run this again.")
    end
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

-- It reboots itself rather than asking. An installed computer that is sitting
-- at a shell prompt is a computer that is not doing its job, and on a ship that
-- means a relay nobody can reach or an autopilot nobody is flying. The pause is
-- long enough to read the screen and to interrupt.
print("")
print("Rebooting in 3 seconds. Ctrl and T now for the shell instead.")
sleep(3)
os.reboot()
