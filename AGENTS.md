# Starcatcher

A Create: Avionics autopilot for a propeller ship in Minecraft, written in Lua
for CC: Tweaked. Four computers: one flies the ship, one watches the fuel, and
two drive the propellers and the balloon that are not wired to the first.

`README.md` is the full description and `md/STATE.md` is where things actually
stand. `md/HANDOFF.md` is how to pick the work up. Read `md/STATE.md` before
changing anything. This file is the map and the house rules.

## Where the live instance is

This folder is the source of truth. The computers in the world run copies, and
the copies are kept in step by the installer, which fetches this repo over HTTP.
CC: Tweaked cannot pull from a folder on the host.

    C:\Users\WinterOS\AppData\Roaming\PrismLauncher\instances\Skyline SMP\
      minecraft\saves\New World (1)\computercraft\computer\

        0/    the flight computer   <- startup.lua + src/
        1/    the fuel relay        <- relay/
        2/    the turbine relay     <- turbines/
        3/    the cruise relay      <- turbines/, same program as 2

Each numbered folder is that computer's whole filesystem as seen from inside
the game. The way a change reaches a ship is the installer, run on the computer
itself:

    wget run https://raw.githubusercontent.com/Kkkur/autopilot-lua/master/install.lua

`tools/deploy.py` copies from this folder instead, and is for the desktop loop
while code is changing. **Do not run `deploy.py --write` against the save unless
it is asked for.** The owner has ruled that the installer is what sets a ship up.

What the computers write themselves lives beside their programs and is not
copied back: `0/starcatcher/`, `1/fuelrelay/`, `2/turbinerelay/`,
`3/turbinerelay/`, each with a `logs/` folder. Those logs are the first place to
look when something misbehaved in the world rather than on the desktop.

## Versions, and why the stamp lies

`manifest.lua` holds the one version number. The installer writes it into
`starcatcher_version.txt` on each computer, which is how a computer says what it
is running.

**Bump `manifest.version` in the same commit as any change to a program.** The
stamp is only worth reading if it is bumped when the program is. It has already
been wrong once: five commits landed, the manifest stayed at 0.10.0, and
computer 0 reported a version of a program it no longer had.

The stamp is a claim, not a check. What settles it:

    diff -rq src "<instance>/0/src"

## Layout

    startup.lua       runs the autopilot on boot, restarts it on a crash
    src/              the autopilot: starcatcher.lua plus sc/*.lua
    relay/            the fuel relay program, computer 1
    turbines/         the relay program, run by computers 2 and 3 both
    install.lua       the installer, fetched over HTTP by a computer in the world
    manifest.lua      which files each role needs, where they land, and the version
    tools/            the desktop harness, never shipped to a computer
    md/               STATE, HANDOFF and the plans, gitignored
    deps/             mod sources and docs, reference only, never loaded

`src/old/autopilot.lua` is the single file version this grew out of. It is kept
because it still flies and because it is the shortest readable statement of how
the ship is commanded. The relays' `flush` comes from it.

Each relay carries its own copy of `sc/log.lua` and `sc/link.lua`. They are the
same files. **A change to logging, or to the link, is a change to three files.**
`tools/deploy.py` checks the copies against each other rather than trusting them.

## Checks

Nothing here needs Minecraft to be running. Run all of them before saying a
change works.

    cd tools
    npm install        once, for fengari
    node syntax.js     parse every Lua file, relays and installer included
    node sim.js --test the self test
    node sim.js        boot, fly a leg, print the screen it drew
    node sim.js --tabs photograph every tab
    node sim.js --clicks  click every tab cell, check the right tab came up
    node sim.js --cal  walk the wizard headless, check what it measured

The self test is pure and needs no ship, so it also runs in the world as
`src/starcatcher --test` on a bare computer. **Do not write the count of tests
into a document.** It goes stale within a session; the run says the number.

`tools/sim.lua` stubs CC: Tweaked, CC: Sable, Create: Avionics, rednet, and the
relays. A change to the control loop, the mixer or the screen should be caught
there before anyone walks out to the ship.

**Three things the desktop cannot reach, and every one has cost a world trip:**

- The relays cannot be booted here, because they need real peripherals.
  `syntax.js` is the whole of what covers them.
- `install.lua` is never run here, only parsed.
- **The align stage cannot be answered here.** Its question is the number a
  pilot reads off F3. Any arithmetic in it has to be pulled out into
  `sc/flight.lua`, where the self test can reach it, or it is not covered at all.
  `flight.hullHeadingFor` was pulled out for exactly this reason.

## How it fits together

The flight computer owns the maths: pose from CC: Sable, position error through
a PID into a wanted speed, wanted speed through the measured curve into RPM,
RPM mixed across whatever propellers serve that axis.

Nothing about the ship is written into the program. Lines are found on the
network, their directions come from `cal`, their speeds from `vcal`.

A relay line is a line like any other. `sc/turbine.lua` adopts the turbine
relay's controllers into `ship`, and from then on `cal`, the mixer and the PROPS
tab cannot tell them apart. The only code that knows is `ship.flush`, which puts
their RPM on the radio instead of into a peripheral.

Two rules fall out of that and are easy to break by accident:

- **Remote lines are sent every tick, changed or not.** The wired path sends only
  what changed, to save server ticks. Doing that to a relay would be read at the
  other end as this computer having died, and the relay would stop its turbines.
- **Relays never command the ship back.** Fuel and stress are reported and
  advised on. An autopilot that cut thrust over a number read off a radio is an
  autopilot that lands a ship because a chunk unloaded.

## The turn

`sc/flight.lua` is pure and holds no tuning numbers at all. Everything arrives
in `cfg`, which is the config module's values, and everything measured arrives
in `cal`.

The order inside `flight.tankDemand` is the order it has to stay in: heading
error into a wanted rate, the wanted rate held down by the approach profile, the
rate priced by the measured ladder, the inner rate loop, then the close in
shaping, then the overshoot ceiling, then the minimum.

Four things about it that were each a bug first:

- **A missing measurement must fail safe, not fail open.** `flight.approachRate`
  returns nil without a deceleration, and for one version nil meant no limit at
  all, which is the same command as a hull that stops instantly. A ship with no
  `cal.yawAccel` now flies on `yawAccelAssumed`, which is low on purpose, because
  guessing low brakes early and guessing high sails past.
- **The heading error cannot tell a brake from a drive.** A nose swinging left
  through a heading that is itself off to the left is being braked by a demand
  pointing left, and by the error alone that is indistinguishable from driving.
  The rate is what tells them apart. Nothing that shapes or caps a demand may
  ever touch the brake: the term that stops a swing must not end up the weaker
  of the two.
- **Close in, a measurement of a turn is the wrong thing to ask.** Inside
  `yawNearBand` the push is a flat step in RPM and inside `yawFineBand` there is
  none, because the ladder prices a third of a degree at most of the differential
  the ship owns.
- **A turn has to remember the push that overshot.** Otherwise the correction
  after a crossing is aimed the other way with the same authority, which is how
  one overshoot becomes four. The memory is a table the caller owns, the way the
  PID is, so two turns in one run cannot inherit each other's mistakes.

## The front and the hull

The hull's own +Z is what the autopilot commands. The end of the ship the crew
calls the front is what a pilot can see, and on this ship they are a half turn
apart. Nothing on the network will ever say which end is the front, which is the
whole reason the align stage exists and asks.

**Anything that sends the ship to a heading a pilot is going to check must go
through `flight.hullHeadingFor`.** Commanding the hull and then asking about the
front sends the front to the opposite compass point and files eight readings of
the same mistake, which is what the align stage did until 0.12.0.

`cal.frontOffset` is the difference. The screens read in it; the maths does not.

## The screen

`line()` in `sc/ui.lua` truncates at the screen width and says nothing about it.
**Prose goes through `wrapText`, never through `line` directly.** A stage that
explains in one sentence how much clear air it wants, with the half naming the
distance cut off, has told the pilot nothing.

Two entry points and they are not interchangeable: `ui.draw` reads the
instruments then paints and belongs to the screen loop, `ui.repaint` paints from
cached reads and is what input uses. **`ui.paint` contains no yields**, because
`sublevel` and `aero` calls are `mainThread` and a yield mid frame hands the
screen to another loop.

A tab is built as a list of rows and placed afterwards. `Pane` collects rows and
gaps, then spends the rows nothing wanted as air between the groups. `gap(99)`
pins a footer to the foot.

## House style

The existing code is the specification for new code. Match it.

- Every tuning number lives in `sc/config.lua` and nowhere else. If a constant
  matters, the pilot can reach it from the TUNE tab. A new key there also has to
  go into the hand built `cfg` table in `sc/tests.lua`, or `tankDemand` reads nil
  out of it and the failure is a comparison against nil three files away.
- Comments explain why, not what. A comment that restates the line above it is
  worse than no comment.
- Failures are named on screen in the words of the thing that failed, never
  swallowed and never turned into a generic message. Two different faults get
  two different strings.
- `mainThread` peripheral calls yield a server tick each. Send only what changed,
  and send it through `parallel.waitForAll`.
- Positive yaw is the ship turning to its own right, and a tank hull turns right
  by pushing harder on its **left** side. `flight.lua` says so twice at the top.
  A change to a sign here needs a measurement behind it, not an argument.
- A test whose claim has been overtaken is rewritten to state the new truth, not
  deleted and not loosened. The old claim is what is being changed, so say so.
- Prose in markdown: no hyphens used as punctuation, US English, plain words.
  There is a hook that checks this and it will reject a file that breaks it.

## Working here

The owner plans first and asks in rounds, because the ship changes faster than
the code does. Ask with concrete options and a recommendation, and keep the
round short.

One commit per piece of work, pushed once every check above is green, with
`manifest.version` bumped in the same commit. Check `git var GIT_AUTHOR_IDENT`
says `Kkkur <santibrrz091@gmail.com>` before the first commit of a session: the
machine has a second GitHub account on it and it is not this project's.

**`grep` through the shell is proxied on this machine** and mangles some
patterns. Prefer the Grep tool. Plain `grep` with compound predicates, or
`find -exec`, fails with an rtk error.

`AGENTS.md` is a copy of this file for tools that look for that name instead.
They are the same document and both are updated together.
