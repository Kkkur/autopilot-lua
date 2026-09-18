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
