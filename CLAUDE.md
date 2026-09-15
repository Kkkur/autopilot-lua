# Starcatcher

A Create: Avionics autopilot for a propeller ship in Minecraft, written in Lua
for CC: Tweaked. Three computers: one flies the ship, one watches the fuel, one
drives the turbines that are not wired to the first.

`README.md` is the full description and is the thing to read before changing
anything. This file is the map.

## Where the live instance is

This folder is the source of truth. The computers in the world run copies, and
the copies have to be kept in step by hand, because CC: Tweaked has no way to
pull from a folder on the host.

    C:\Users\WinterOS\AppData\Roaming\PrismLauncher\instances\Skyline SMP\
      minecraft\saves\New World (1)\computercraft\computer\

        0/    the flight computer   <- startup.lua + src/
        1/    the fuel relay        <- relay/
        2/    the turbine relay     <- turbines/

Each numbered folder is that computer's whole filesystem as seen from inside
the game. After editing here, copy across and check:

    cp startup.lua        <instance>/0/startup.lua
    cp -r src/*           <instance>/0/src/
    cp relay/*            <instance>/1/
    cp turbines/*         <instance>/2/
    diff -rq src "<instance>/0/src"

What the computers write themselves lives beside their programs and is not
copied back: `0/starcatcher/`, `1/fuelrelay/`, `2/turbinerelay/`, each with a
`logs/` folder. Those logs are the first place to look when something misbehaved
in the world rather than on the desktop.

## Layout

    startup.lua       runs the autopilot on boot, restarts it on a crash
    src/              the autopilot: starcatcher.lua plus sc/*.lua
    relay/            the fuel relay program, computer 1
    turbines/         the turbine relay program, computer 2
    tools/            the desktop harness, never shipped to a computer
    deps/             mod sources and docs, reference only, never loaded

`src/old/autopilot.lua` is the single file version this grew out of. It is kept
because it still flies and because it is the shortest readable statement of how
the ship is commanded. The relays' `flush` comes from it.

Each relay carries its own copy of `sc/log.lua`. They are the same file. A
change to logging is a change to three files.

## Checks

Nothing here needs Minecraft to be running.

    cd tools
    npm install        once, for fengari
    node syntax.js     parse every Lua file, relays included
    node sim.js --test the self test, currently 161 passing
    node sim.js        boot, fly a leg, print the screen it drew
    node sim.js --tabs photograph every tab
    node sim.js --clicks  click every tab cell, check the right tab came up

`tools/sim.lua` stubs CC: Tweaked, CC: Sable, Create: Avionics, rednet, and both
relays. A change to the control loop, the mixer or the screen should be caught
there before anyone walks out to the ship. The relays themselves cannot be booted
on the desktop because they need real peripherals, so `syntax.js` is what covers
them.

Run all of the above before saying a change works.

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

## House style

The existing code is the specification for new code. Match it.

- Every tuning number lives in `sc/config.lua` and nowhere else. If a constant
  matters, the pilot can reach it from the TUNE tab.
- Comments explain why, not what. A comment that restates the line above it is
  worse than no comment.
- Failures are named on screen in the words of the thing that failed, never
  swallowed and never turned into a generic message. Two different faults get
  two different strings.
- `mainThread` peripheral calls yield a server tick each. Send only what changed,
  and send it through `parallel.waitForAll`.
- Prose in markdown: no hyphens used as punctuation, US English, plain words.
