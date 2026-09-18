-- link.lua -- the passcode every message on this ship carries.
--
-- Rednet is a broadcast medium. Two ships in one chunk hear each other, a
-- neighbour's relay answers your orders, and a mistyped computer id sends four
-- turbines somebody else's RPM. So every message this program sends carries a
-- passcode, and every message it receives is dropped unless the passcode
-- matches.
--
-- **Be honest about what this is.** CC: Tweaked has no encryption, so the
-- passcode travels in the clear and anyone in range running a modem sniffer can
-- read it off the air. It is real protection against the accidents that
-- actually happen and no protection at all against a person who wants in. It is
-- written down here rather than implied, because a pilot who believed this was
-- security would make a worse decision than one who knows it is a name tag.
--
-- **A ship with no passcode set obeys anything on its protocol.** That is
-- deliberate and it is what lets a half installed ship fly: the installer sets
-- the passcode, and until it has, the relays behave exactly as they did before
-- this file existed. What is not allowed is for that to be quiet, so a link
-- with no passcode says so on the screen and in the log.
--
-- The same file is carried by all four programs, the way sc/log.lua is. A
-- change here is a change to three copies of it, and tools/deploy.py checks
-- them against each other rather than trusting them.

local link = {}

link.FILE = nil         -- set by init, lives beside the program's own data
link.pass = nil         -- nil means this computer has not been paired
link.refused = 0        -- messages dropped because the passcode did not match
link.refusedFrom = nil  -- the last computer that sent one
link.refusedAt = nil    -- when, so the screen can say how long it has gone on

-- A passcode is one word. Spaces and punctuation are not forbidden for any
-- cryptographic reason, there is nothing cryptographic here: they are forbidden
-- because this gets typed at a prompt on four computers and read off a screen
-- between them, and a passcode nobody can retype is a ship nobody can pair.
function link.valid(pass)
    if type(pass) ~= "string" then return false, "a passcode is a word" end
    if #pass < 3 then return false, "a passcode is at least three characters" end
    if #pass > 24 then return false, "a passcode is at most twenty four characters" end
    if pass:find("%s") then return false, "a passcode has no spaces in it" end
    if not pass:match("^[%w%-_]+$") then
        return false, "a passcode is letters, digits, dashes and underscores"
    end
    return true
end

function link.init(dataDir)
    link.FILE = fs.combine(dataDir, "link.cfg")
    link.load()
    return link
end

function link.load()
    link.pass = nil
    if not link.FILE or not fs.exists(link.FILE) then return false end
    local handle = fs.open(link.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end
    if type(data.pass) == "string" and link.valid(data.pass) then
        link.pass = data.pass
    end
    link.peers = type(data.peers) == "table" and data.peers or nil
    return link.pass ~= nil
end

function link.save()
    if not link.FILE then return false end
    local dir = fs.getDir(link.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(link.FILE, "w")
    if not handle then return false end
    handle.write(textutils.serialize({ pass = link.pass, peers = link.peers }))
    handle.close()
    return true
end

function link.set(pass)
    local ok, why = link.valid(pass)
    if not ok then return nil, why end
    link.pass = pass
    link.refused, link.refusedFrom, link.refusedAt = 0, nil, nil
    link.save()
    return pass
end

-- Forgetting the passcode is allowed and is how a ship whose relays have gone
-- out of step is put back together: clear it everywhere, then set it again.
function link.clear()
    link.pass = nil
    link.refused, link.refusedFrom, link.refusedAt = 0, nil, nil
    link.save()
    return true
end

-- == THE ENVELOPE ============================================

-- Outbound. An unpaired computer sends no passcode field at all rather than an
-- empty one, so a paired receiver refuses it as unstamped and says exactly that
-- instead of reporting a mismatch against nothing.
function link.stamp(message)
    if type(message) ~= "table" then return message end
    if link.pass then message.pass = link.pass end
    return message
end

-- Inbound. Returns ok, and on a refusal the sentence that says why, in the
-- words of the thing that is wrong: an unstamped message and a wrong passcode
-- are two different faults with two different fixes.
function link.check(id, message)
    if not link.pass then return true end
    if type(message) ~= "table" then return false, "not a message this ship speaks" end
    if message.pass == nil then
        link.refused = link.refused + 1
        link.refusedFrom = id
        link.refusedAt = os.clock()
        return false, string.format("computer #%s sent no passcode at all", tostring(id))
    end
    if message.pass ~= link.pass then
        link.refused = link.refused + 1
        link.refusedFrom = id
        link.refusedAt = os.clock()
        return false, string.format("computer #%s is using a different passcode", tostring(id))
    end
    return true
end

-- == THE PAIRING PROTOCOL ====================================
--
-- Its own protocol, `starcatcher-pair`, carrying two messages: a ping, and the
-- answer to one. A computer being installed has no business hearing an order,
-- and a ping is not an order.
--
-- **Every program on this ship answers a ping, not only the installer.** The
-- first version lived inside the wizard, and a relay therefore answered only
-- while the wizard was on its screen. So any one of the four computers being
-- switched off or rebooted in the middle of a setup left the others pinging a
-- relay that was powered, running, wired and deaf, with no way back but
-- reinstalling all four. The responder now runs for as long as the relay runs,
-- which means the checklist asks a question about the ship rather than a
-- question about which screen somebody is standing in front of.
--
-- Answering is reporting, and reporting is what a relay is allowed to do. There
-- is nothing here that commands anything.

link.PAIR = "starcatcher-pair"
link.answered = 0       -- pings answered since boot
link.pingedBy = nil     -- the last computer to ask
link.pingedAt = nil     -- when, so a screen can say how long ago

function link.hello(role)
    return { kind = "here", role = role, id = os.getComputerID() }
end

-- The reply to one ping, or nil and the reason it was refused. Split out from
-- the loop so the answering rule can be checked on a computer with no modem.
function link.answer(role, id, message)
    if type(message) ~= "table" or message.kind ~= "ping" then return nil end
    local allowed, why = link.check(id, message)
    if not allowed then return nil, why end

    link.answered = link.answered + 1
    link.pingedBy, link.pingedAt = id, os.clock()

    -- Who asked is worth keeping. It is how a relay knows which computer is
    -- flying it, and it is written down the first time rather than every time,
    -- because a disk write a second is a disk write a second.
    if link.peers == nil or link.peers.command ~= id then
        link.peers = link.peers or {}
        link.peers.command = id
        link.save()
    end

    return link.stamp(link.hello(role))
end

-- A task, run under parallel beside everything else a relay does. It never
-- returns, because a task that returns under waitForAny takes the program with
-- it.
function link.respond(role, onEvent)
    while true do
        local id, message = rednet.receive(link.PAIR)
        local reply, why = link.answer(role, id, message)
        if reply then
            rednet.send(id, reply, link.PAIR)
            if onEvent then pcall(onEvent, "answered", id) end
        elseif why and onEvent then
            pcall(onEvent, "refused", id, why)
        end
    end
end

-- The asking half. One round: ping everybody named, then listen for as long as
-- it was given. It does not decide when to stop asking, because the installer
-- must not stop and a pilot at a keyboard must, and that is not this file's
-- decision to make.
function link.sweep(ids, seconds)
    local answers, refusals = {}, {}
    for _, id in ipairs(ids) do
        rednet.send(id, link.stamp({ kind = "ping" }), link.PAIR)
    end
    local deadline = os.clock() + (seconds or 2)
    while true do
        local left = deadline - os.clock()
        if left <= 0 then break end
        local id, message = rednet.receive(link.PAIR, left)
        if not id then break end
        local allowed, why = link.check(id, message)
        if not allowed then
            refusals[id] = why
        elseif type(message) == "table" and message.kind == "here" then
            answers[id] = message.role or "unnamed"
        end
    end
    return answers, refusals
end

-- What the screen and the preflight checker read. `paired` is the question that
-- matters, and `refused` is the one that explains a relay that seems to be
-- there and seems to be deaf.
function link.status()
    return {
        paired = link.pass ~= nil,
        refused = link.refused,
        refusedFrom = link.refusedFrom,
        age = link.refusedAt and (os.clock() - link.refusedAt) or nil,
    }
end

return link
