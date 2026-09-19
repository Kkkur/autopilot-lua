# Adding a relay computer for telemetry

A relay is a computer that is not the flight computer, sits touching hardware
the flight computer cannot reach, and says what it sees over rednet. There are
three on this ship already. The fuel relay reads the tanks. The turbine relay
holds four speed controllers and a stressometer. The cruise relay holds the
main propeller and the balloon.

This is how to add a fourth kind. The worked example is a **cargo relay**, a
computer touching the item vaults that reports how full they are, because a
reporting relay is the simplest kind and everything harder is this plus
actuators.

## The two rules first

Both of these are in `CLAUDE.md` and both are easy to break by accident.

**A relay never commands the ship.** It reports and it advises. The autopilot
never cuts thrust because of a number that arrived on a radio, because a chunk
unloading looks exactly like a tank going empty. Your relay may say the hold is
overloaded. It may not ask for less throttle.

**A relay that holds actuators is sent its orders every tick, changed or not.**
The wired path sends only what changed, to save server ticks, and doing that to
a relay reads at the far end as the flight computer having died. A pure
telemetry relay has no actuators and therefore no deadman, so this rule costs
you nothing. The moment you give it something that spins, it applies.

## The nine places a new role touches

Miss one and the failure is usually silent, so this is a list rather than
prose.

| Place | What goes there |
| --- | --- |
| `cargo/` | the relay program, its `startup.lua`, and its copies of `sc/log.lua` and `sc/link.lua` |
| `manifest.lua` | a role entry: title, data folder, link path, file list, and a version bump |
| `install.lua` | the role in `PEER_ROLES`, and a positive test in `look` and `guess` |
| `src/sc/cargo.lua` | the receiving end on the flight computer |
| `src/starcatcher.lua` | loading that module, calling `init`, and its listen loop |
| `src/sc/config.lua` | any tuning number the new code reads, including its staleness |
| `src/sc/ui.lua` | where the pilot sees it |
| `src/sc/telemetry.lua` | the columns the flight recorder writes |
| `tools/deploy.py` and `tools/sim.lua` | the desktop harness: the copy plan, the shared file check, and a stub so the simulator has one |

## 1. The relay program

Copy `relay/` rather than starting from nothing. `relay/fuel_relay.lua` is the
reference implementation of a reporting relay and every part of it is there for
a reason that cost somebody a trip out to the ship.

    cargo/
      startup.lua           runs the program on boot, restarts it on a crash
      cargo_relay.lua       the program
      sc/log.lua            an exact copy, banner line aside
      sc/link.lua           an exact copy

`sc/log.lua` and `sc/link.lua` are the same files as the flight computer's. The
one line that differs is the crash banner, which names the computer that left
the file. `tools/deploy.py` compares the copies and ignores that line, so do
not improve one copy without improving all of them.

### The head of the program

Module loading, the data folder, and the constants. Constants live in the relay
and not in a config file: the relay has one job, and tuning lives on the flight
computer where the pilot can reach it from the TUNE tab.

```lua
local ARGS = { ... }

local ROOT = fs.getDir(shell and shell.getRunningProgram() or "cargo_relay.lua")
local DATA = "cargorelay"

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

local PROTOCOL    = "starcatcher-cargo"  -- must match sc/cargo.lua on computer 0
local HOSTNAME    = "cargo"
local SAMPLE      = 0.5                  -- seconds between reads
local SEND_EVERY  = 1.0                  -- seconds between broadcasts
local MODEM_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local log = loadModule("log")
local link = loadModule("link")
```

Pick a protocol name nobody else on the air uses. It is the first half of the
addressing; the passcode is the second.

### The message

One flat table, versioned, carrying everything the flight computer needs to
draw its panel without asking a follow up question. Work out here whatever this
computer is best placed to work out, which is anything needing fast samples,
and leave to the flight computer whatever only it knows, which is speed,
distance and what the pilot asked for.

```lua
local function buildMessage()
    local slots, used, capacity = {}, 0, 0
    for _, entry in ipairs(vaults) do
        used = used + entry.used
        capacity = capacity + entry.capacity
        slots[#slots + 1] = {
            side = entry.side, used = entry.used, capacity = entry.capacity,
            ok = entry.ok, err = entry.err,
        }
    end
    return {
        v = 1,
        id = os.getComputerID(),
        label = os.getComputerLabel(),
        clock = os.clock(),
        slots = slots,
        used = used,
        capacity = capacity,
        fraction = capacity > 0 and used / capacity or 0,
    }
end
```

`v = 1` is load bearing. The receiving end refuses anything whose `v` it does
not know, which is what lets an old relay and a new flight computer fail loudly
instead of reading a field that moved.

Every failing peripheral carries its own `ok` and `err` all the way to the
screen. A relay that swallows a dead vault and reports a smaller total is a
relay that reports a hold emptying itself.

### The loops

Five of them under `parallel.waitForAny`, and the last three only when there is
a modem.

```lua
local function sampleLoop()          -- read the hardware, rebuild the message
local function sendLoop()            -- broadcast it every SEND_EVERY
local function answerLoop()          -- answer a ping out of band
local function screenLoop()          -- the relay's own screen
local function pairLoop()            -- link.respond, so the installer can pair it
```

`sendLoop` broadcasts rather than addressing the flight computer, so a relay
needs to know nothing about who is listening:

```lua
local function sendLoop()
    while true do
        rednet.broadcast(link.stamp(latest), PROTOCOL)
        sent = sent + 1
        sleep(SEND_EVERY)
    end
end
```

`link.stamp` is what puts the passcode on. Nothing leaves a relay unstamped.

`answerLoop` is what makes a `cargo` command on the flight computer feel
immediate rather than waiting up to a second for the next broadcast:

```lua
local function answerLoop()
    while true do
        local id, message = rednet.receive(PROTOCOL)
        local allowed, why = link.check(id, message)
        if not allowed then
            if link.refused == 1 then log.warn("refusing messages: " .. tostring(why)) end
        elseif type(message) == "table" and message.cmd == "ping" then
            rednet.send(id, link.stamp(latest), PROTOCOL)
        end
    end
end
```

The refusal is logged once and then counted. A neighbor's autopilot
broadcasting once a second would otherwise bury the one line that mattered.

`pairLoop` runs for as long as the relay runs, not only while some wizard is on
screen. Read the comment block in `sc/link.lua` for why: the first version
answered pings only during setup, and any relay rebooting mid install became a
computer that was powered, wired and deaf, with no way back but reinstalling
every computer on the ship.

```lua
local function pairLoop()
    link.respond("cargo", function(kind, id, why)
        if kind == "answered" then
            log.debugf("pair ping from %d, answered", id)
        else
            log.warnf("pair ping from %d refused: %s", id, tostring(why))
        end
    end)
end
```

The string `"cargo"` is the role name and it has to match the key in
`manifest.lua`, because that is what the installer prints when it says which
computer answered.

### Its own disk

A relay going quiet is the one event nobody can see from the flight computer,
since the way it is seen from there is by the messages stopping. So the relay
writes its last word to its own disk, which is a folder on the host and
readable after it falls off the radio.

```lua
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
```

Wrapped in `pcall`, every time. A full disk costs a dropped sample and never a
flight.

### The two flags every relay has

```
cargo_relay --once          print one reading and exit, for checking the wiring
cargo_relay --passcode W    set the passcode this relay answers to
```

`--once` is how somebody standing at the computer finds out whether the
peripherals are seen at all, without reading a screen that refreshes twice a
second. `--passcode` is how a relay is repaired when its word has drifted from
the rest of the ship, without running the installer over it again.

## 2. The manifest

```lua
cargo = {
    title = "cargo relay",
    data = "cargorelay",
    link = "sc/link.lua",
    files = {
        { "cargo/startup.lua", "startup.lua" },
        { "cargo/cargo_relay.lua", "cargo_relay.lua" },
        { "cargo/sc/log.lua", "sc/log.lua" },
        { "cargo/sc/link.lua", "sc/link.lua" },
    },
},
```

The left path is the repo, the right path is where it lands on that computer. A
relay lives at the root of its own filesystem while the flight computer keeps
its modules under `src/`. `link` says where that role's copy of `sc/link.lua`
ended up, because the installer pairs the ship through the module it just
wrote rather than carrying a second copy of the file format.

Bump `manifest.version` in the same commit. The stamp is only worth reading if
it moves when the program does.

## 3. The installer

Two edits. First the peer list, so the flight computer is asked for this
relay's id during setup:

```lua
local PEER_ROLES = { "fuel", "turbine", "cruise", "cargo" }
```

Then a positive test, so the relay identifies itself from what is bolted to it
rather than from whoever is standing at the keyboard. In `look`, notice the
hardware:

```lua
if peripheral.hasType(name, "item_storage") then found.vaults = true end
```

In `guess`, place it by how specific the test is:

```lua
if found.redstone then return "cruise" end
if found.tanks then return "fuel" end
if found.vaults then return "cargo" end
if found.controllers > 0 then return "turbine" end
if found.modem or found.sublevel then return "command" end
```

Order matters and the flight computer stays last, because it is the only role
with no positive test: it is defined by owning nothing that spins. Do not test
for `sublevel` to tell relays apart. It is a global API present on every
computer on a ship with the mod loaded, and putting it earlier is what once
told the turbine relay it was the flight computer.

Add a line to `describe` too, so the installer can say out loud what it saw.

## 4. The receiving end

`src/sc/cargo.lua`, modeled on `src/sc/fuel.lua`. It keeps the last message,
notices when the link goes quiet, and turns raw numbers into the thing a
captain actually asks.

```lua
local util, ship, config, log, link = ...

local cargo = {}

cargo.PROTOCOL = "starcatcher-cargo"
cargo.snap = nil        -- the last message, as it arrived
cargo.at = nil          -- os.clock() when it arrived
cargo.relayId = nil
cargo.messages = 0
cargo.everSeen = false
```

`accept` is split out of the loop so the same validation can be tested with no
modem anywhere near it. The passcode is checked **before** anything is read out
of the message, because a message from another ship is not a malformed message
from this one:

```lua
function cargo.accept(id, message)
    local allowed, why = link.check(id, message)
    if not allowed then
        cargo.refusedWhy = why
        return false, why
    end
    if type(message) ~= "table" or message.v ~= 1 or type(message.slots) ~= "table" then
        return false
    end
    cargo.snap, cargo.at, cargo.relayId = message, os.clock(), id
    cargo.messages = cargo.messages + 1
    return true
end

function cargo.listen()
    if not cargo.modem then
        while true do sleep(60) end
    end
    while true do
        local id, message = rednet.receive(cargo.PROTOCOL)
        local ok, err = pcall(cargo.accept, id, message)
        if not ok then log.error("cargo: bad message: " .. tostring(err)) end
    end
end
```

The idle branch matters. This runs under `parallel.waitForAny` and a task that
returns there takes the whole program down with it, so a computer with no modem
sleeps forever instead of finishing.

Share the modem the fuel link already opened. Two protocols share one modem
perfectly well, and `fuel.init` leaves the side it found in `fuel.modem`,
which is how `turbine.init` is already given one:

```lua
function cargo.init(side)
    -- same search as turbine.init: wireless first, wired only if that is all
    -- there is, because a relay on this computer's wired network would not
    -- need to be a separate computer at all.
end
```

Staleness is a question the receiving end answers, not the relay:

```lua
function cargo.age()
    if not cargo.at then return nil end
    return os.clock() - cargo.at
end

function cargo.isLive()
    local age = cargo.age()
    return age ~= nil and age <= config.get("cargoStale")
end
```

`status()` returns a flat table for the screen with a `link` field that is one
of `nomodem`, `waiting`, `stale` or `live`. The panel draws that line first and
colors everything under it by what the link is worth, because a stale reading
that looks live is how a ship runs out of something.

If the relay is worth advice as well as numbers, write an `advice(status)` that
returns a list of `{ kind, text }`, worst first. Every line in it should be
something the pilot would otherwise work out in their head from two numbers on
different tabs. Look at `fuel.advice` for the shape.

## 5. Wiring it into the flight computer

In `src/starcatcher.lua`, load it after `link` and before `ui`:

```lua
local cargo = loadModule("cargo", util, ship, config, log, link)
```

Then, beside the other inits:

```lua
fuel.init()
turbine.init(fuel.modem)
cargo.init(fuel.modem)
```

Then give it the listen loop, alongside `fuel.listen`:

```lua
local ok, err = pcall(parallel.waitForAny, controlLoop, screenLoop, inputLoop,
    fuel.listen, turbine.listen, turbine.heartbeat, cargo.listen, bootReport,
    telemetryLoop)
```

Everything a relay adds is optional. A ship with no modem, or with that
computer switched off, flies exactly as it did before: the panels say so and
nothing else changes. Keep it that way. Nothing in the control loop may require
a relay to have spoken.

## 6. Config

Every tuning number lives in `src/sc/config.lua` and nowhere else, so the pilot
can reach it from the TUNE tab.

```lua
{ key = "cargoStale", group = "cargo", kind = "number", def = 5, min = 1, max = 60, step = 1,
  help = "Seconds without a word from the cargo relay after which its numbers are called stale rather than current.",
  symptom = "the hold reads full long after the relay stopped talking" },
```

`help` is what the number does. `symptom` is what a pilot sees when it is
wrong, which is how somebody finds the key without already knowing its name. A
new key also has to go into the hand built `cfg` table in `src/sc/tests.lua` if
anything in `flight.lua` reads it, or a test reads nil out of it and fails
three files away from the cause.

## 7. Telemetry columns

Add the fields to `telemetry.COLUMNS` in `src/sc/telemetry.lua` and fill them in
`telemetry.sample`. The column list is the only place the order is written
down, so a column added there appears in both the header and every row or in
neither.

```lua
cargoPct = cargoStatus.fraction and cargoStatus.fraction * 100 or nil,
```

The sample is passed both relay statuses already read off the radio, so nothing
it does costs a server tick. Keep it that way: read from a cached status, never
from a peripheral.

Also add the link to the `links` column, which is the one place a reader can
see at a glance which relays were alive at a given row.

## 8. The desktop harness

`tools/deploy.py`:

```python
PLAN = [
    (0, "flight computer", [("startup.lua", "startup.lua"), ("src", "src")]),
    (1, "fuel relay", [("relay", ".")]),
    (2, "turbine relay", [("turbines", ".")]),
    (3, "cruise relay", [("turbines", ".")]),
    (4, "cargo relay", [("cargo", ".")]),
]

SHARED = [
    ["src/sc/log.lua", "relay/sc/log.lua", "turbines/sc/log.lua", "cargo/sc/log.lua"],
    ["src/sc/link.lua", "relay/sc/link.lua", "turbines/sc/link.lua", "cargo/sc/link.lua"],
]
```

The `SHARED` entry is the important half. It is what catches the copy you
forgot, and forgetting one is silent until the ship refuses to pair.

`tools/sim.lua` needs a stub that answers the way the real relay does, or every
screen test runs against a flight computer that has never heard of cargo. The
fuel stub is the model: build the message the same way the relay builds it, by
hand, and keep the two in step deliberately.

## 9. Checks, and what they cannot reach

From `tools/`:

    node syntax.js        parses every Lua file, the new relay included
    node sim.js --test    the self test
    node sim.js --tabs    photographs every tab
    node sim.js --clicks  clicks every tab cell

Three things the desktop cannot reach, and this is the honest part:

- **The relay program never boots here.** It needs real peripherals.
  `syntax.js` parsing it is the whole of the coverage. Everything you want
  checked has to be pulled out into a pure function the self test can call.
- **`install.lua` is only parsed, never run.** Your `look` and `guess` edits
  are unverified until a real computer runs them.
- **Pairing is not simulated.** Two computers disagreeing about a passcode look
  exactly like a relay that is deaf.

So write the relay so that the parts worth checking are not in the relay:
message building, rate fitting, and anything with arithmetic in it belong
somewhere the self test can reach.

## 10. Installing it on the ship

On the new computer:

    wget run https://raw.githubusercontent.com/Kkkur/autopilot-lua/master/install.lua

It looks at what is bolted to itself, picks the role, downloads only that
role's files, and asks for the passcode. Set the same word on every computer on
the ship. Then on the flight computer, run the installer again so it learns the
new relay's id, or the new relay is a computer nobody pings.

Do not push files into the save folder by hand. `tools/deploy.py --write` exists
for the desktop loop while code is changing and is not how a ship is set up.

## What to check once it is up

1. The relay's own screen shows readings and a rising sent count.
2. The flight computer's panel says `live` with an age under a second.
3. Turn the relay off. The panel goes stale, it says so in red, and the ship
   keeps flying exactly as before.
4. Turn it back on. The log on the flight computer says the link came back and
   how long it was gone.
5. `<relay data folder>/logs/` on the host has the boot lines, and
   `telemetry/snapshot.txt` has the last thing it saw.

Step 3 is the one worth doing properly. A relay whose absence stops the ship is
worse than no relay at all.
