# Starcatcher

A Create: Avionics autopilot for a propeller ship. One computer flies it. Two
optional ones watch the fuel and drive the turbines.

This is the old `starcatcher` autopilot ported off redstone. The old one talked
to a relay computer over rednet, which fed analog levels into a redstone relay,
which drove the engines, and it held altitude with a balloon it had no control
over. So it flew in two dimensions: X and Z, tank turn then cruise, with the
heading PID fighting a ship that could only push one way.

This one commands Create rotation speed controllers through Create: Avionics and
reads its own pose from CC: Sable, and the vertical axis is the autopilot's to
fly. Where the old one relayed because it had no other way to reach an engine,
this one relays only what will not fit on one computer.

Two things are somewhere else on the hull rather than on this computer: the fuel
tanks, and the speed controllers for the bottom turbines. Each gets a small
computer of its own that talks over a wireless modem. The fuel one reports; the
turbine one takes orders and reports the stress. Take either away and the
autopilot flies on whatever is still wired to it, with the panels saying so.

Nothing about the ship is written into the program. It finds every speed
controller on its network by itself, learns what each one does from `cal`, and
learns how fast the ship actually flies from `vcal`.

## The ship it was built for

Four propellers around the hull, north, south, east and west, and a big one
underneath for lift. Five rotation speed controllers, one per propeller line,
all on the computer's wired network.

It does not care. Three propellers, eleven, two lifts and no lateral thrust at
all: calibration measures whatever is bolted on and the controller uses what it
finds. A body axis with no propeller on it says so on the screen and is left
alone rather than guessed at.

## Hardware

- Propeller bearings, however many, pointing however they point.
- One Create rotation speed controller per propeller line, on the wired
  network. These are the only blocks the program commands.
- CC: Sable, and the flight computer on the assembled ship. The `sublevel`
  global is what the pose is read from. Note that the global is present on every
  computer with the mod installed, riding a ship or not; what tells you the
  computer is in the wrong place is the call failing, not the global missing.
  See `deps/README.md`.
- Optional: an altitude sensor, for the altitude, air pressure and vertical
  speed readouts.
- Optional: a wireless modem, and a second computer touching the fuel tanks
  with a wireless modem of its own. That is the fuel relay, and it is the whole
  of `relay/`.
- Optional: a third computer holding speed controllers of its own and a
  stressometer. That is the turbine relay, `turbines/`. Its lines become the
  autopilot's lines, and it reports the stress on the whole kinetic network.

Propeller bearings are read, never written. If a bearing reports its speed zone
anchor, the program links it back to the controller that drives it and shows
thrust and sail power per line, and marks the line with the most sail power as
the main propeller with a `*`.

## Install

Copy the `src` folder onto the flight computer, and `startup.lua` next to it at
the root:

    startup.lua
    src/starcatcher.lua
    src/sc/*.lua

`startup.lua` runs the autopilot on boot and after a chunk reload, and restarts
it if it crashes. It always comes up idle with the propellers stopped: nothing
takes a target back up on its own. Typing `exit`, or Ctrl+T, leaves you in the
shell rather than starting it again.

And, if there is a fuel relay, copy `relay` onto the second computer:

    fuel_relay.lua
    startup.lua
    sc/log.lua

And `turbines` onto the third, if there is a turbine relay:

    turbine_relay.lua
    startup.lua
    sc/log.lua

If the FLIGHT tab says `position unavailable: NO CC: SABLE`, the CC: Sable jar
is not loaded on that computer at all. `NOT ON A SUB-LEVEL` is the other one: the
jar is there and the computer is not on an assembled ship. They are different
faults and the screen names which.

Run `starcatcher --test` first. It checks the quaternion, mixing, curve and
config maths, the fuel arithmetic and the turbine link, and prints
`161 passed, 0 failed`. It needs no ship, no peripherals and no relays.

Then run `starcatcher`.

Everything it writes lives in `starcatcher/` next to the program:
`config.cfg`, `cal.cfg`, `waypoints.cfg`, `logs/`, `crashes/`.

## First flight

1. `starcatcher`
2. `cal` : spin each propeller, say which way it pushed. Once per ship.
3. `vcal` : measure how fast the ship flies at each RPM. Once per ship, and
   again after the ship gets heavier.
4. `save home`
5. `fly 1200 95 -400`

That is the whole thing.

## The screen

Seven tabs. `F1`..`F7`, `left` and `right` to step through them, or click them.
The tab bar is seven cells of equal width that tile the whole line, so every
column on it belongs to a tab and a click never lands in a gap.
The command line at the bottom is always live: you can type `goto dock` while
the CAL tab is up.

- **FLIGHT** : position, heading, speed against the measured top speed, target,
  distance, ETA, and the three body axes as wanted speed / actual speed / RPM.
  The propeller lines are along the bottom.
- **PROPS** : the kinetic network's stress across the top, then every line with
  a signed RPM bar, thrust and stress, then every propeller bearing with which
  line drives it. A line marked `~` is driven over the radio.
- **NAV** : the waypoint table. `up`/`down` picks, `enter` flies there, `del`
  removes. The route queue is underneath.
- **CAL** : what is calibrated, when, and the measured speed curve per axis.
- **TUNE** : every tuning value, live. `left`/`right` changes the selected one,
  `[` and `]` switch group. Changes save and apply at once.
- **TEL** : everything the ship reads about itself, a section at a time down
  the left the way TUNE does its groups: FUEL, TANKS, TURBINES, POSE and
  ADVICE. `up`/`down` or `left`/`right` picks a section, or click its name.
  Nothing on this tab commands anything. Adding a readout is adding one entry
  to `ui.TELEMETRY` and nothing else.
- **LOG** : this session's log. `pageUp`/`pageDown` scrolls.

Keys are for flying and commands are for saying exactly what you mean.
`up`/`down` walk the command history when you are typing and the list when you
are not.

## Commands

    save <name> [x y z]     pin a waypoint, or where the ship is now
    del <name>              forget one
    rename <old> <new>
    list                    the NAV tab
    goto <name>             fly to a waypoint
    fly <x> <y> <z>         fly to coordinates
    route <a> <b> <c>       fly a list of them, one leg after the next
    hold                    station keep right here
    stop                    cut the propellers
    resume                  engage again on the target already set
    manual <side> <up> <fwd>   fly by hand, body frame speed in m/s
    cal                     direction calibration
    vcal [x|y|z]            velocity calibration
    curves                  the measured curves
    forget curves|dirs|all  throw calibration away
    set <key> <value>       change any tuning value
    get [key]               read one, or open TUNE
    reset [key]             back to the default
    tel                     the TEL tab, and ask the fuel relay for a reading
                            now. `fuel` still works and means the same
    turbines                the turbine relay: link, stress and its lines
    rescan                  look at the network again
    help [command]

`tab` completes commands, waypoint names after `goto`, `del` and `route`, and
setting names after `set` and `get`. The completion is shown greyed ahead of
the cursor rather than applied silently.

## Direction calibration

The program has no idea which controller drives which propeller, or which way a
propeller pushes at positive RPM. Both depend on how the ship was built, so both
are measured once per ship. Type `cal`.

It walks the controllers one at a time and waits for you at every step:

    line 2 of 5   #1
    currently: south
    spinning for 24.3s. Press Enter to stop it.
    drift   +0.00  +0.00  +1.40   looks like south
    strongest  +0.00  +0.00  +1.40

The propeller spins from when you press Enter until you press Enter again, with
the live drift on screen the whole time. Nothing is on a timer, a heavy ship can
take as long as it needs. Enter is the stop key on purpose: a letter would leave
its character queued and type itself into the answer that follows.

**Spin direction is asked first.** Whether positive RPM turns a propeller the
right way is a property of that propeller, which side of the shaft it sits on
and which way its blades face, not of where on the ship it is mounted. Answer
`n` and it spins the other way and shows you again, so the drift you then
describe is the one the autopilot will actually produce. The answer is saved as
`reverse` next to the direction, and every command to that line is negated from
then on.

Answers are `up`, `down`, `north`, `south`, `east`, `west`, `none` for a
controller that drives no propeller, or `skip` to leave it as it was. The
suggestion in brackets is the strongest drift seen while it was spinning, taken
as the change from just before spin up, so pressing Enter through the whole run
is usually right. Your eyes win over the number, the number is only a
suggestion.

`s` skips a line without spinning it, `q` stops early and saves what has been
answered so far.

A propeller that pushes `down` is not a mistake to be flipped, it is just a
downward propeller. The autopilot runs it backwards when it needs to climb.

These are the ship's own directions, not the world's. `north` means the way the
ship's north propeller pointed while it was being calibrated, and the pose
quaternion keeps that true after the ship turns.

The ship moves during all of this, so give it clear air on every side.

## Velocity calibration

This is the part the old autopilot never had, and it is what makes the
difference between "push harder when far away" and "fly at 8 m/s".

Type `vcal`. For each body axis that has a propeller on it, and for each
direction along that axis, it walks a ladder of RPM steps. At every rung it
drives the axis and waits until the ship's speed stops changing, then writes
down the speed it settled at:

    measurement 7 of 36   axis Y+   131 rpm
    speed   5.20 m/s   trend +0.031 m/s2   SETTLING
    hold  [############--------]  2.1/3.0s
    time  [#####---------------]  3.4/12.0s

A rung is kept when the speed has held steady for `velHold` seconds with less
than `velStable` m/s² of drift left in it. If it never settles inside
`velSettle` seconds, the fastest speed seen is kept and marked as not settled,
because a noisy number is still better than no number. Between rungs everything
stops for `velCooldown` seconds so the next one does not start from the speed
the last one built up.

Each rung is saved the moment it is measured. A run you stop halfway through
with `q` leaves a shorter but perfectly usable curve behind.

Both directions are measured by default, because ships are rarely symmetric:
climbing against gravity is not the same machine as sinking with it. `set
velBothWays off` halves the run if you do not care.

The curve is what the controller looks up. Asked to fly at 6 m/s it reads the
RPM that produced 6 m/s last time and starts there, then trims with a PID
instead of hunting from zero. It is also where the speed bar's scale, the ETA
and the cruise speed clamp come from: the autopilot will not ask an axis for
more than that axis has ever been seen to do.

Run it again after the ship changes weight, gains sails, or loses a propeller.

## How the control works

Two nested loops per body axis.

The outer loop turns position error into a wanted speed. The world error from
the ship to the target is rotated into the ship's own frame with the inverse of
the pose quaternion, run through a PID, and clamped by `cruiseSpeed`
(`climbSpeed` on the vertical), by the measured top speed for that axis, and by
a taper over the last `slowRadius` blocks of the leg. The taper is what stops
the ship arriving at 20 m/s and sailing through the waypoint.

The inner loop turns wanted speed into RPM. The feed forward comes off the
measured curve, the trim comes off a second PID on the speed error, and the sum
is clamped to `maxRpm`.

That axis RPM is then spread over the lines serving the axis, scaled by how much
of each line's thrust lands on it, negated for a line calibrated `reverse`,
dropped to zero below `minRpm`, and slew limited to `rpmSlew` RPM of change per
tick. Two propellers on the same axis fall out of this for free: opposed ones
get opposite signs and push the same real direction, parallel ones get the same
sign.

With no curve measured yet, the feed forward is zero and the inner PID does all
the work, which is roughly what the bare bones autopilot did. It flies. It just
overshoots more. `set useCurves off` forces that path if you want to compare.

Going through the quaternion rather than a yaw angle is deliberate. The two mods
disagree on yaw sign: the Sable notes derive it as `atan2(-forward.x, forward.z)`
and `navigation_table.getHeading` documents `atan2(x, z)`. Rotating by the
quaternion never asks the question, and it stays correct when the ship pitches
or rolls.

CC: Sable has shipped more than one shape for that quaternion. The current
source returns a flat `{x, y, z, w}`, older builds return the CC: Advanced Math
pair of a scalar `a` and a vector part `v`, which is what the original
`autopilot_sender.lua` read. `toQuat` takes either, plus a plain array, and
normalizes the result, since `qRotate` is only a rotation for a unit quaternion.
If a future build returns something else again, the status line names the keys
it got (`ORIENTATION SHAPE {a,v}`) instead of dying on a nil.

`setTargetSpeed` is a mainThread write and costs a server tick each. Only what
changed is sent, and those go out in one `parallel.waitForAll` batch, which is
the difference between a 20 Hz loop and a 4 Hz one on a five propeller ship.

## Tuning

Everything is on the TUNE tab, or `set <key> <value>`, and every change saves
and applies immediately. Nothing in the program hardcodes a flight constant.

    cruiseSpeed  top speed the autopilot will ask for, m/s
    climbSpeed   the same for the vertical axis, which is the expensive one
    arriveDist   inside this many blocks, the leg is done
    slowRadius   distance over which the approach speed is bled off
    holdAlt      fly the target Y, rather than drifting to it
    stationKeep  after arriving, keep fighting drift instead of cutting out

    tick         control loop period. 0.05 is one server tick
    maxRpm       ceiling on any one line
    minRpm       below this a demand is dropped rather than buzzing
    rpmSlew      most RPM one line may change per tick

    posKp/Ki/Kd  position error to wanted speed, (m/s) per block
    spdKp/Ki/Kd  speed error to RPM trim, on top of the curve
    spdILimit    clamp on the speed integral
    useCurves    use the measured curves as feed forward

    calRpm, calSample, calMinDrift            direction calibration
    velSteps, velStartRpm, velEndRpm          the RPM ladder
    velSettle, velHold, velStable, velCooldown   what counts as settled
    velBothWays                               measure both directions

    uiTick, logLevel, colorful                the screen

Oscillating around the target: raise `spdKd`, or lower `posKp`. Crawling in:
raise `posKp`. Overshooting the waypoint: raise `slowRadius`. Lurching on
arrival: lower `spdILimit`. A heavy ship that does not drift enough to read
during direction calibration: raise `calRpm`. A still ship that reads as
drifting: raise `calMinDrift`. Velocity rungs that never settle: raise
`velSettle` or `velStable`.

`reset` puts everything back.

## The fuel relay

`relay/` is a second, much smaller program for a second computer. That computer
sits touching the fuel tanks, with a wireless modem on top, and does nothing but
read them and say so.

    relay/fuel_relay.lua     the program
    relay/startup.lua        runs it on boot, and restarts it if it dies
    relay/sc/log.lua         the same log module the autopilot uses
    relay/test.lua           finds the tanks and prints their real method list

`startup.lua` means the relay is running whenever the computer is, which is what
you want from something whose whole job is to be on the air. Ctrl+T stops it and
leaves five seconds to press Ctrl+T again for the shell.

Create's fluid tank has no ComputerCraft peripheral of its own. What answers is
CC: Tweaked's generic `fluid_storage`, whose `tanks()` gives a fluid name and an
amount and **no maximum at all**. So the relay finds the maximum the hard way:
it asks for it under every name a build might offer it, and if nothing answers
it falls back to the size written at the top of the relay, which is `TANK_BLOCKS`
blocks of Create's 8000 mB each: 63 blocks, so 504,000 mB a tank and 1,008,000
across the pair. It then raises that assumption whenever it sees more fluid in
there than it believed could fit, rounding up to a whole tank block rather than
a whole tank, so a taller tank lands on its real size. A maximum that was
guessed is marked with a `~` on both screens and named as a guess in the advice.
It is never quietly presented as a reading. Corrected maximums are written to
`fuelrelay/learned.cfg` and survive a reboot.

Twice a second it reads both tanks. Once a second it broadcasts everything it
knows on the `starcatcher-fuel` protocol: per tank the fluid, the amount, the
maximum and where that maximum came from, plus the totals and the rate. The rate
is a least squares fit over the last minute of samples rather than the
difference between the last two readings, which on a tank being fed by a pump is
mostly noise.

The fit waits for the window to fill before it quotes anything, and it waits on
real elapsed time rather than on a count of samples. Four samples is two
seconds, and two seconds of a tank that reads in whole mB is a slope fitted
through rounding: the relay used to come up announcing a burn of 22 mB a second
and walk it back to 1.8 as the window filled, which is a number a captain plans
a leg on. Until it has its twenty seconds the relay says how much it has
gathered instead of guessing.

Its log lives in `fuelrelay/logs/` and is deliberately quiet: crossing a level,
changing fluid, a tank going silent, a capacity being corrected. A line twice a
second would bury the one that mattered.

### What the autopilot does with it

`sc/fuel.lua` listens, and adds the two things the relay cannot know: how fast
this ship is actually moving, and how far away the target is.

    burn        mB per second, from the relay's fit
    reserve     fuel that is not yours to spend, `set fuelReserve`
    endurance   how long the fuel above the reserve lasts at this burn
    dry         how long everything lasts, quoted separately
    range       endurance at the speed the ship is making right now

A fit has gaps: the relay has just booted, the flow dipped under the noise
floor, the window has not filled. Endurance and dry used to be computed inside
`if burn > 0` and so left the screen entirely on every one of them, and a
captain watching two numbers vanish mid leg learns nothing from the blank. The
last burn that was actually measured is held for `fuelBurnHold` seconds and
quoted with its age, in the warning colour, never in the live one.

Range is the point of all of it. A burn rate is a number; "range 4720 blk,
target 115 out" is an answer. With a target set, the advice panel says whether
the leg can be flown, whether it can be flown and returned from, or whether it
cannot be flown at all.

It also says the things that are invisible in a total: two tanks holding
different fluids, or one tank at 57% while the other is at 31%, which is a pump
that has stopped and a total that still reads a comfortable 44% right up until
half the supply is gone.

The link itself is watched. A relay that has gone quiet for `fuelStale` seconds
is reported as lost, in red, over the last numbers it sent, rather than leaving
a stale reading looking live.

    fuelWarn       below this percent the panel warns
    fuelCrit       below this percent it says land or refuel now
    fuelReserve    fuel held back, which endurance and range are quoted above
    fuelStale      seconds of silence before the link counts as lost
    fuelImbalance  percent difference between tanks that reads as a pump fault
    fuelBurnHold   seconds a measured burn keeps answering after the flow stops

None of it ever commands anything.

## The turbine relay

`turbines/` is the third computer. It holds the speed controllers for the
turbines that are not wired to the flight computer, and a stressometer watching
the whole kinetic network.

    turbines/turbine_relay.lua   the program
    turbines/startup.lua         runs it on boot, and restarts it if it dies
    turbines/sc/log.lua          the same log module again

It finds its controllers the way everything else here does, by matching on
`setTargetSpeed` and `getTargetSpeed` rather than on a type string, and its
`flush` is the one from `src/old/autopilot.lua`: only what changed is written,
and the writes go out in one `parallel.waitForAll`, because `setTargetSpeed`
costs a server tick each. Spending those ticks over here instead of inside the
flight loop is the reason this is worth being a separate computer at all.

It broadcasts once a second on `starcatcher-turbine`: the stress, the capacity,
whether the network is overstressed, and per line the RPM it was ordered to make
and the RPM `getTargetSpeed` says it is making. The stressometer's `overstressed`
and `stress_change` events are put on the air the moment they fire rather than
waiting for the next broadcast.

It takes `set`, `stop` and `ping`. Lines can be addressed by name, by `#3`, or
by number.

**The turbines stop three seconds after the flight computer goes quiet.** A
radio goes silent when a chunk unloads, when the flight computer crashes, or
when somebody breaks it, and turbines left running at the last thing they were
told fly the ship into terrain. `turbine_relay --spin 128` drives both lines by
hand for ten seconds, for the check where you walk out and look at them.

### What the autopilot does with it

`sc/turbine.lua` adopts the relay's lines into `ship` as lines of its own. After
that nothing else in the program knows the difference: `cal` walks them in the
direction wizard, the mixer gives them a share of an axis, the PROPS tab draws
them. The only code that knows is `ship.flush`, which puts their RPM on the
radio instead of into a peripheral.

Two things follow from the orders being radio rather than a wire.

The first is that **every remote line is sent on every tick, changed or not**.
The wired path sends only what changed, which saves server ticks; doing that
here would be read at the other end as this computer having died. There is a
heartbeat as well, for the times the control loop is parked and a calibration
run is driving the turbines directly.

The second is that a line can leave. When the relay stops naming a controller,
it is dropped rather than left in the mixer, because thrust divided between a
propeller that is there and one that is not is thrust aimed at nothing.

Stress sits across the top of the PROPS tab and on the FLIGHT tab next to the
fuel, quoted as a percentage and as the headroom left in stress units, which is
the number that decides whether asking for more RPM will get you any. The advice
for it shares the TEL tab's ADVICE section: a captain does not care which
computer noticed the problem.

    stressWarn     percent of capacity that reads as working the network hard
    stressCrit     percent at which the next demand is what breaks it
    turbineStale   seconds of silence before the turbine relay counts as lost

Like the fuel link, it never commands anything on its own. Overstress is
reported, not reacted to: the kinetic network has already stopped by then, and
an autopilot that cut thrust on top of that would be dropping the ship on
purpose.

## Which clock

`os.clock` on CC: Tweaked is not seconds. It counts the ticks the computer has
been up, twenty to the second when the server is keeping up and fewer when it
is not. Every duration in this program used to be taken off it, so every
duration was quoted in a second that stretches under load: a burn rate fitted
over "sixty seconds" of a server running at twelve ticks had measured a hundred
real seconds of fuel and called it sixty, and a log read afterwards to work out
how long something took was reading a clock that had been stopping.

So there are two clocks and which one a number belongs to is decided by who
reads it.

    util.now()      real seconds, off os.epoch. Everything a person reads:
                    log stamps, fuel age, burn, endurance, dry, every ETA,
                    the calibration rung timers
    log.now()       the same thing, for the relays and for log itself, which
                    are loaded with no dependencies and cannot reach util
    os.clock()      game ticks, on purpose. The control loop's dt, the yaw
                    trail window, the relay deadman

The control loop stays on ticks because the physics it is steering steps on
ticks, and the turn was measured and tuned against that. Moving it to wall time
is a change to the flight model, not a formatting fix, and it needs a turn on
the real ship behind it.

## Testing it on the desktop

`tools/sim.lua` stubs enough of CC: Tweaked, CC: Sable and Create: Avionics to
boot the real program against a toy ship: five speed controllers, four
propellers and a big one, a pose that integrates whatever thrust the autopilot
asks for, a pretend fuel relay on rednet with two tanks, one of them draining
faster than the other so the imbalance advice has something to find, and a
pretend turbine relay with two more lines and a stressometer, so the adopting,
the heartbeat and the stress panel are all exercised on the desktop.

    cd tools
    npm install          # once, for fengari; or use any Lua 5.2+
    node sim.js          # boot, fly a leg, print the screen it drew
    node sim.js --tabs   # photograph every tab
    node sim.js --clicks # click every tab cell and say which tab came up
    node sim.js --cal    # walk the direction wizard
    node sim.js --vcal   # walk the velocity wizard and print the curves
    node sim.js --test   # the self test, without a computer to type it on
    node syntax.js       # parse every Lua file in the repo, relay included

The flight run asserts that the autopilot actually closed on its target. None of
this ships to the computer; it exists so a change to the control loop or the
screen gets caught on the desktop instead of at 300 blocks up.

The relay cannot be booted out here, because it needs peripherals that only
exist in the game, so `tools/syntax.js` parses it instead. That catches the
mistake that actually happens when editing a long file, which is an `end` in the
wrong place, and it catches it before the walk out to the ship.

## What it does not do

- **No yaw control.** Nothing here produces a torque on purpose. The ship points
  wherever it points, and the autopilot flies sideways if that is the short way.
  The old starcatcher's tank turn needed a clutch and reversible propeller
  banks; this one steers with thrust instead of turning to face the target.
- **No docking, no fleet link, no shipchat.** The old program's `docking.lua`
  and `systems.lua` read a redstone relay's display cache, which does not exist
  here. Fuel came back, as a computer of its own; see above.
- **The fuel readout never touches the propellers.** It advises. An autopilot
  that cut the engines over a number read off a modem would be an autopilot
  that lands a ship because a chunk unloaded.
- Calibration only offers the six cardinal directions. A propeller mounted at an
  angle gets rounded to the nearest one, though a hand edited diagonal entry in
  `cal.cfg` is honoured by the mixer.
- The altitude loop does not know the ship's mass or the local air pressure.
  `aero.getGravity()` and `sublevel.getMass()` are read for the panel and are
  there when the controller wants them.
- Wind, or any other steady push, leaves a standing offset unless `posKi` is
  turned up. It defaults to zero.

## The bare bones one

`src/old/autopilot.lua` is the single file version this grew out of: the same
quaternion handling and the same direction calibration, proportional control
with damping, no waypoints, no curves, no tabs. It is kept because it is 600
lines and it flies, and because it is the shortest readable statement of how
this ship is commanded.
