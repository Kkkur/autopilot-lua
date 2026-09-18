-- config.lua -- every number the autopilot flies by, in one place.
--
-- The schema below is the whole tuning surface. Anything listed here can be
-- changed from the TUNE tab or with `set <key> <value>` while flying, is
-- written to disk the moment it changes, and is loaded again at boot. Nothing
-- else in the program is allowed to hardcode a flight constant: if it matters,
-- it lives here and the pilot can reach it.
--
-- Every entry carries two sentences. `help` is what the setting does, and
-- `symptom` is what the ship is doing when you reach for it. The second one is
-- the one that gets used: a pilot at the TUNE tab is there because something
-- looked wrong, not because they wanted a definition. The README used to be the
-- only place that knowledge lived, which put it on a different screen from the
-- setting it describes.

local config = {}

config.FILE = nil   -- filled in by init, lives under the data directory

-- group: which TUNE page it shows up on.
-- kind:  "number" | "int" | "bool"
-- step:  how far one arrow-key nudge moves it.
config.SCHEMA = {
    -- == THE TURN ============================================
    -- This ship steers by driving one side against the other, so these are the
    -- numbers that decide how it points itself at anything.
    { key = "tankRpmMax",    group = "tank",   kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Most differential RPM a tank turn will ask for.",
      symptom = "the hull comes round too slowly to be worth watching" },
    { key = "tankRpmMin",    group = "tank",   kind = "int",    def = 16,   min = 0,   max = 128, step = 4,
      help = "Below this a controller buzzes without turning anything, so it is dropped.",
      symptom = "the turbines whine at the end of a turn without moving the hull" },
    { key = "tankPadding",   group = "tank",   kind = "number", def = 2.0,  min = 0.1, max = 30,  step = 0.5,
      help = "Degrees of heading error that count as lined up.",
      symptom = "it hunts back and forth instead of committing to the run" },
    { key = "tankHold",      group = "tank",   kind = "number", def = 2.0,  min = 0,   max = 30,  step = 0.5,
      help = "Seconds it must stay lined up before cruise is committed to.",
      symptom = "it sets off while the nose is still swinging through the bearing" },
    { key = "tankHoldRate",  group = "tank",   kind = "number", def = 2.0,  min = 0.1, max = 30,  step = 0.5,
      help = "Yaw rate below which the hull counts as no longer swinging.",
      symptom = "a heavy hull never settles enough to be called lined up" },
    { key = "tankReentry",   group = "tank",   kind = "number", def = 25.0, min = 1,   max = 180, step = 5,
      help = "Heading error in cruise that sends it back to a tank turn.",
      symptom = "it wanders off the bearing and keeps running anyway" },
    { key = "yawRateMax",    group = "tank",   kind = "number", def = 30.0, min = 1,   max = 180, step = 5,
      help = "Fastest turn the autopilot will ask for, deg/s.",
      symptom = "turns are violent enough to throw the cargo about" },
    { key = "yawKp",         group = "tank",   kind = "number", def = 4.0,  min = 0,   max = 100, step = 0.5,
      help = "Heading error to wanted yaw rate. Raise it if turns finish slowly.",
      symptom = "the last few degrees of a turn take longer than the first ninety" },
    { key = "yawKi",         group = "tank",   kind = "number", def = 0.0,  min = 0,   max = 20,  step = 0.1,
      help = "Integral on heading. Trims out a steady pull to one side.",
      symptom = "it settles a few degrees off the bearing and stays there" },
    { key = "yawKd",         group = "tank",   kind = "number", def = 0.5,  min = 0,   max = 50,  step = 0.1,
      help = "Derivative on heading. Raise it if the hull swings past and back.",
      symptom = "the nose overshoots the bearing and comes back through it" },

    -- == THE RUN =============================================
    -- Once it is pointing the right way it is one propeller problem.
    { key = "cruiseSpeed",   group = "cruise", kind = "number", def = 12.0, min = 0.5, max = 120, step = 0.5,
      help = "Top speed the autopilot will ask for, m/s.",
      symptom = "it flies faster than you want to watch, or slower than the fuel allows" },
    { key = "cruiseRampTime", group = "cruise", kind = "number", def = 7.0, min = 0,   max = 120, step = 0.5,
      help = "Seconds thrust takes to come on. Five propellers at once is a shove.",
      symptom = "the ship lurches when a leg starts" },
    { key = "cruiseMaxRpm",  group = "cruise", kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Ceiling on the common thrust demand.",
      symptom = "full throttle asks for more stress than the network carries" },
    { key = "cruiseMinRpm",  group = "cruise", kind = "int",    def = 16,   min = 0,   max = 128, step = 4,
      help = "Below this the thrust demand is dropped to zero.",
      symptom = "the propellers turn at a crawl without moving the ship" },
    { key = "yawTrimInterval", group = "cruise", kind = "number", def = 3.0, min = 0.1, max = 60, step = 0.5,
      help = "Seconds between heading trims while running.",
      symptom = "it fidgets with the heading the whole way there" },
    { key = "yawTrimThresh", group = "cruise", kind = "number", def = 0.5,  min = 0,   max = 30,  step = 0.1,
      help = "Heading error small enough to leave alone while running.",
      symptom = "small corrections cost stress and buy nothing" },
    { key = "yawTrimRpm",    group = "cruise", kind = "int",    def = 128,  min = 0,   max = 256, step = 16,
      help = "Most differential a trim may use. A trim is not a turn.",
      symptom = "a mid run correction turns into a full turn" },

    -- == STOPPING ============================================
    -- The part that ends flights when it is got wrong.
    { key = "arriveDist",    group = "brake",  kind = "number", def = 1.0,  min = 0.1, max = 100, step = 0.5,
      help = "Inside this many blocks of the target, the leg is done.",
      symptom = "it fusses over the last block instead of calling it arrived" },
    { key = "brakeMargin",   group = "brake",  kind = "number", def = 3.0,  min = 1.0, max = 10,  step = 0.1,
      help = "How much earlier than the last moment it starts stopping.",
      symptom = "the ship sails past the point and has to come back for it" },
    { key = "brakeRpmMax",   group = "brake",  kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Most reverse RPM a stop will ask for.",
      symptom = "stops are longer than the room you have" },
    { key = "brakeSlew",     group = "brake",  kind = "int",    def = 16,   min = 1,   max = 256, step = 4,
      help = "How fast reverse comes on. Suddenness is what tips the hull.",
      symptom = "the nose dips hard the moment braking starts" },
    { key = "pitchLimit",    group = "brake",  kind = "number", def = 12.0, min = 1,   max = 80,  step = 1,
      help = "Degrees of nose down that count as tipping. Caps the brake ladder.",
      symptom = "the nose over alarm fires on an ordinary stop" },
    { key = "pitchWatch",    group = "brake",  kind = "bool",   def = true,
      help = "Raise a popup when the hull pitches past the limit in flight.",
      symptom = "you would rather watch the pitch yourself than be asked about it" },

    -- == ARRIVING ============================================
    -- A hull that cannot strafe stops on its bearing and lives with what that
    -- leaves.
    { key = "lateralCorrect", group = "arrival", kind = "number", def = 4.0, min = 0.1, max = 100, step = 0.5,
      help = "Blocks off the line that are worth turning around for.",
      symptom = "it turns around for an error you would have ignored" },
    { key = "creepSpeed",    group = "arrival", kind = "number", def = 1.5,  min = 0.1, max = 20,  step = 0.5,
      help = "Speed of the short correcting run onto the point, m/s.",
      symptom = "the last approach is either a crawl or another overshoot" },
    { key = "creepTries",    group = "arrival", kind = "int",    def = 3,    min = 1,   max = 20,  step = 1,
      help = "Attempts at the point before it gives up and says so.",
      symptom = "it pirouettes over the target instead of admitting it cannot land on it" },
    { key = "holdDrift",     group = "arrival", kind = "number", def = 6.0,  min = 0.1, max = 100, step = 0.5,
      help = "Drift while holding that is worth turning and creeping back for.",
      symptom = "a moored ship wanders, or fights the current all night" },

    -- == THE BALLOON =========================================
    -- The only thing holding the ship up, which is why the floor exists and why
    -- it is not zero.
    { key = "altKp",         group = "altitude", kind = "number", def = 0.5, min = 0,  max = 20,  step = 0.05,
      help = "Altitude error to wanted climb rate, (m/s) per block.",
      symptom = "it takes forever to reach a height you asked for" },
    { key = "altKi",         group = "altitude", kind = "number", def = 0.0, min = 0,  max = 5,   step = 0.01,
      help = "Integral on altitude. Trims out a slow leak or a heavy load.",
      symptom = "it settles a few blocks under the height and stays there" },
    { key = "altKd",         group = "altitude", kind = "number", def = 0.8, min = 0,  max = 20,  step = 0.05,
      help = "Damping on vertical speed. Raise it if the ship porpoises.",
      symptom = "the ship rises and falls through the height it wants" },
    { key = "altDeadband",   group = "altitude", kind = "number", def = 2.0, min = 0,  max = 50,  step = 0.5,
      help = "Blocks of altitude error worth doing nothing about.",
      symptom = "the balloon level twitches while the ship is level" },
    { key = "climbRateMax",  group = "altitude", kind = "number", def = 3.0, min = 0.1, max = 30, step = 0.5,
      help = "Fastest climb the autopilot will ask the balloon for, m/s.",
      symptom = "climbs are slower than the leg can afford" },
    { key = "sinkRateMax",   group = "altitude", kind = "number", def = 3.0, min = 0.1, max = 30, step = 0.5,
      help = "Fastest descent it will ask for. Down is the cheap way to lose a ship.",
      symptom = "descents are quicker than you are comfortable watching" },
    { key = "balloonFloor",  group = "altitude", kind = "int",    def = 2,   min = 0,  max = 15,  step = 1,
      help = "Strength the balloon is never driven below. Zero is the ground.",
      symptom = "the ship sinks faster than it can catch itself" },
    { key = "balloonStale",  group = "altitude", kind = "number", def = 5.0, min = 1,  max = 120, step = 1,
      help = "Seconds of silence before the balloon relay counts as lost.",
      symptom = "a busy server trips the lost part alarm on a relay that is fine" },
    { key = "altAskDelta",   group = "altitude", kind = "number", def = 15.0, min = 0, max = 200, step = 5,
      help = "Altitude change big enough to ask about before flying it.",
      symptom = "it climbs without asking, or asks about every waypoint" },

    -- == MIXING ==============================================
    -- How a demand is split across whatever propellers the ship turned out to
    -- have. The shares are for a hull whose main is worth more than a turbine.
    { key = "mainShare",     group = "mix",    kind = "number", def = 1.0,  min = 0,   max = 2,   step = 0.05,
      help = "Share of the thrust demand the main propeller takes.",
      symptom = "the main is doing more or less of the work than it should" },
    { key = "turbineShare",  group = "mix",    kind = "number", def = 1.0,  min = 0,   max = 2,   step = 0.05,
      help = "Share of the thrust demand each turbine takes.",
      symptom = "the turbines run out of range before the main does" },
    { key = "maxRpm",        group = "mix",    kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Ceiling on any one line. The controller clamps here itself.",
      symptom = "a controller is being asked for more than it will take" },
    { key = "minRpm",        group = "mix",    kind = "int",    def = 16,   min = 0,   max = 256, step = 4,
      help = "Below this a demand is dropped to zero rather than buzzing.",
      symptom = "lines hum at idle without turning" },
    { key = "rpmSlew",       group = "mix",    kind = "int",    def = 64,   min = 4,   max = 256, step = 8,
      help = "Most RPM one line may change per tick. Softens the shove.",
      symptom = "demands arrive as a kick rather than a push" },

    -- == GAINS ===============================================
    -- The speed loop, which is what the forward ladder feeds.
    { key = "spdKp",         group = "gains",  kind = "number", def = 18.0, min = 0,   max = 200, step = 1,
      help = "Speed error to RPM trim, on top of the calibrated feed forward.",
      symptom = "it never quite reaches the speed it asked for" },
    { key = "spdKi",         group = "gains",  kind = "number", def = 4.0,  min = 0,   max = 100, step = 0.5,
      help = "Integral on speed error. Covers what calibration got wrong.",
      symptom = "it runs steadily under or over the wanted speed" },
    { key = "spdKd",         group = "gains",  kind = "number", def = 2.0,  min = 0,   max = 100, step = 0.5,
      help = "Derivative on speed error.",
      symptom = "the throttle surges as the speed comes up" },
    { key = "spdILimit",     group = "gains",  kind = "number", def = 6.0,  min = 0,   max = 100, step = 1,
      help = "Clamp on the speed integral, in m/s seconds.",
      symptom = "a long slow leg ends with the throttle wound up to nothing useful" },

    -- == THE LOOP ============================================
    { key = "tick",          group = "loop",   kind = "number", def = 0.1,  min = 0.05, max = 2.0, step = 0.05,
      help = "Control loop period, seconds. 0.05 is one server tick. Every number on the screen is as fresh as this, because the pose the screen draws is the one this loop read.",
      symptom = "the server is struggling, or the readouts lag behind the ship" },
    { key = "yawAsleep",     group = "loop",   kind = "number", def = 0.05, min = 0,    max = 5,   step = 0.01,
      help = "Reported yaw rate under this, deg/s, is read as the physics engine having gone quiet rather than as a hull standing still, and the heading is differentiated over yawWindow instead. Zero trusts the reported figure always.",
      symptom = "a slow turn reads zero every few samples, and the yaw ladder comes out low" },
    { key = "yawWindow",     group = "loop",   kind = "number", def = 1.0,  min = 0.2,  max = 5,   step = 0.1,
      help = "Seconds of headings the differentiated yaw rate is worked out over. Longer reads a slower turn; too long and a fast one turns past half a circle between the two ends.",
      symptom = "the fallback yaw rate is noisy, or lags a turn that is changing" },

    -- == CALIBRATION =========================================
    -- The five stage wizard measures the ship with these. They are the only
    -- numbers here that describe a measurement rather than a flight.
    { key = "calRpm",        group = "cal",    kind = "int",    def = 128,  min = 16,  max = 256, step = 16,
      help = "RPM one line spins at while the wizard reads which side it is on.",
      symptom = "the sides stage cannot tell which way a line pushes" },
    { key = "calSample",     group = "cal",    kind = "number", def = 0.15, min = 0.05, max = 2, step = 0.05,
      help = "Seconds between live readings while the wizard watches the ship. Also how long a reading is averaged over before it is kept.",
      symptom = "the wizard's live row moves too fast or too slowly to read" },
    { key = "calMinDrift",   group = "cal",    kind = "number", def = 0.15, min = 0.01, max = 5, step = 0.05,
      help = "Speed below this reads as noise rather than as thrust.",
      symptom = "a line that does nothing is filed as though it pushed" },
    { key = "calMinYaw",     group = "cal",    kind = "number", def = 1.0,  min = 0.05, max = 30, step = 0.25,
      help = "Yaw below this reads as a line on neither side, which is the main. It is the sides stage's question and nothing else's.",
      symptom = "the main is filed as a side, or a side as the main" },
    { key = "calYawFloor",   group = "cal",    kind = "number", def = 0.01, min = 0.001, max = 5, step = 0.01,
      help = "Yaw rate the ladder counts as the hull not turning at all, deg/s. Far under calMinYaw on purpose: the bottom rung of a heavy ship turns it slowly, and slowly is the reading, not a failure.",
      symptom = "the low rungs of the yaw ladder are thrown away as no reading" },
    { key = "calSteps",      group = "cal",    kind = "int",    def = 4,    min = 2,   max = 16,  step = 1,
      help = "Rungs in the yaw and forward ladders.",
      symptom = "the curves are too coarse to follow the ship's real shape" },
    { key = "calStartRpm",   group = "cal",    kind = "int",    def = 64,   min = 8,   max = 256, step = 8,
      help = "Lowest rung of the yaw and forward ladders.",
      symptom = "the bottom rung does not move the ship at all" },
    { key = "calEndRpm",     group = "cal",    kind = "int",    def = 256,  min = 16,  max = 256, step = 8,
      help = "Highest rung of the yaw and forward ladders.",
      symptom = "the top rung asks for more than the network can supply" },
    { key = "calStable",     group = "cal",    kind = "number", def = 0.25, min = 0.01, max = 5,  step = 0.05,
      help = "How much a speed may still be changing before the wizard calls the reading steady. It is advice on the screen, not a decision: the pilot ends every rung.",
      symptom = "the wizard says STEADY on a hull that is plainly still accelerating" },
    { key = "calYawStable",  group = "cal",    kind = "number", def = 1.5,  min = 0.05, max = 30, step = 0.25,
      help = "The same, for a yaw rate. A hull swings slower than it accelerates.",
      symptom = "the yaw rungs never read as steady, or read steady too soon" },
    { key = "calBothWays",   group = "cal",    kind = "bool",   def = true,
      help = "Measure the yaw and forward ladders both ways. Twice as slow, twice as right.",
      symptom = "calibration takes longer than the fuel allows" },
    { key = "calFlyStrength", group = "cal",   kind = "int",    def = 15,   min = 0,   max = 15,  step = 1,
      help = "Balloon strength the wizard lifts the ship to before it measures anything that moves. Full by default, because a hull on the ground answers a propeller with friction.",
      symptom = "the ship never gets clear of the ground, or climbs faster than you want while a ladder runs" },
    { key = "calBalloonStep", group = "cal",   kind = "int",    def = 3,    min = 1,   max = 5,   step = 1,
      help = "Strengths skipped in the balloon sweep before it refines around hover.",
      symptom = "the balloon sweep takes an age, or steps over hover entirely" },

    -- == PREFLIGHT ===========================================
    { key = "fuelMargin",    group = "preflight", kind = "number", def = 1.25, min = 1, max = 5, step = 0.05,
      help = "How much more fuel than the leg needs before it is allowed.",
      symptom = "legs are refused that you know perfectly well it can make" },
    { key = "requireStressBudget", group = "preflight", kind = "bool", def = true,
      help = "Refuse a leg the kinetic network cannot supply at full demand.",
      symptom = "you would rather find out in the air than be told on the ground" },

    -- == FUEL ================================================
    -- These live here rather than on the relay because they are the captain's
    -- judgement calls, not facts about the tanks.
    { key = "fuelWarn",      group = "fuel",   kind = "number", def = 30.0, min = 0,   max = 100, step = 5,
      help = "Below this percent the fuel panel warns.",
      symptom = "the warning comes too late to do anything about" },
    { key = "fuelCrit",      group = "fuel",   kind = "number", def = 12.0, min = 0,   max = 100, step = 2,
      help = "Below this percent it says land or refuel now.",
      symptom = "the gate refuses to fly on fuel you were happy to spend" },
    { key = "fuelReserve",   group = "fuel",   kind = "number", def = 20.0, min = 0,   max = 90,  step = 5,
      help = "Fuel that is not yours to spend. Endurance is quoted above it.",
      symptom = "endurance reads longer than you would ever fly on" },
    { key = "fuelStale",     group = "fuel",   kind = "number", def = 8.0,  min = 1,   max = 120, step = 1,
      help = "Seconds of silence before the relay link counts as lost.",
      symptom = "the fuel link flickers between live and lost" },
    { key = "fuelImbalance", group = "fuel",   kind = "number", def = 15.0, min = 0,   max = 100, step = 5,
      help = "Percent difference between tanks that reads as a pump fault.",
      symptom = "it calls a pump fault on tanks that always sit uneven" },

    -- == TURBINE RELAY =======================================
    -- Stress is the relay's reading. What counts as too much of it is the
    -- captain's call, so the thresholds live here.
    { key = "stressWarn",    group = "turbine", kind = "number", def = 75.0, min = 0, max = 100, step = 5,
      help = "Percent of stress capacity that reads as working the network hard.",
      symptom = "the stress readout is orange the whole time" },
    { key = "stressCrit",    group = "turbine", kind = "number", def = 92.0, min = 0, max = 100, step = 2,
      help = "Percent at which the next demand is what breaks the network.",
      symptom = "the network stops before the alarm ever fires" },
    { key = "turbineStale",  group = "turbine", kind = "number", def = 5.0,  min = 1, max = 120, step = 1,
      help = "Seconds of silence before the turbine relay counts as lost.",
      symptom = "a lagging server trips the lost part alarm on a relay that is fine" },

    -- == TELEMETRY ===========================================
    -- How the ship is read from outside the game: a CC computer's disk is a
    -- folder on the host, so what gets written here is what anyone debugging a
    -- flight afterwards has to work from.
    { key = "telemetry",     group = "telemetry", kind = "bool",   def = true,
      help = "Write the flight to starcatcher/telemetry. Off costs nothing and tells nobody anything.",
      symptom = "the disk is filling and you do not need the record" },
    { key = "telemetryHz",   group = "telemetry", kind = "number", def = 2.0, min = 0.1, max = 20, step = 0.5,
      help = "Samples per second written to flight.csv. The sample touches no peripheral.",
      symptom = "the flight csv is too coarse to see what happened in a stop" },
    { key = "telemetryMaxKb", group = "telemetry", kind = "int",   def = 200, min = 16, max = 2048, step = 16,
      help = "Kilobytes per flight.csv before it starts a numbered new one.",
      symptom = "one enormous csv, or a hundred tiny ones" },
    { key = "telemetryKeep", group = "telemetry", kind = "int",   def = 4,   min = 1,   max = 64,  step = 1,
      help = "Flight csv files kept. The oldest is deleted when a new one starts, because a CC computer holds about a megabyte in total.",
      symptom = "the computer is out of space, and nothing can be installed on it" },

    -- == SCREEN ==============================================
    { key = "uiTick",        group = "ui",     kind = "number", def = 0.1,  min = 0.05, max = 2, step = 0.05,
      help = "Screen refresh period, seconds. Redrawing costs no server tick, so this can sit under the control loop without loading anything.",
      symptom = "the screen feels sluggish, or this computer is using too much CPU" },
    { key = "uiExtrasTick",  group = "ui",     kind = "number", def = 1.0,  min = 0.1, max = 30, step = 0.1,
      help = "Seconds between reads of the altimeter and the mass. These are mainThread calls and they cost a server tick each, so they are read on their own slow clock rather than once a frame.",
      symptom = "altitude and mass are stale, or the screen is costing server ticks" },
    { key = "logLevel",      group = "ui",     kind = "int",    def = 2,    min = 0,   max = 3,   step = 1,
      help = "0 errors, 1 warnings, 2 info, 3 everything.",
      symptom = "the log is noise, or it is missing the thing you are chasing" },
    { key = "colorful",      group = "ui",     kind = "bool",   def = true,
      help = "Full colour. Off gives a readable monochrome for gold monitors.",
      symptom = "the screen is a gold monitor and everything reads as one shade" },
}

-- The order these are listed in is the order they appear down the left of the
-- TUNE tab, which is the order a pilot walks a ship: how it turns, how it runs,
-- how it stops, how it arrives, what holds it up, then the machinery.
config.GROUPS = {
    { id = "tank",     title = "TANK TURN" },
    { id = "cruise",   title = "CRUISE" },
    { id = "brake",    title = "BRAKING" },
    { id = "arrival",  title = "ARRIVAL" },
    { id = "altitude", title = "ALTITUDE" },
    { id = "mix",      title = "MIXING" },
    { id = "gains",    title = "GAINS" },
    { id = "loop",     title = "LOOP" },
    { id = "preflight", title = "PREFLIGHT" },
    { id = "cal",      title = "CALIBRATION" },
    { id = "fuel",     title = "FUEL" },
    { id = "turbine",  title = "TURBINES" },
    { id = "telemetry", title = "TELEMETRY" },
    { id = "ui",       title = "INTERFACE" },
}

local byKey = {}
for _, entry in ipairs(config.SCHEMA) do byKey[entry.key] = entry end
config.byKey = byKey

config.values = {}

function config.defaults()
    local t = {}
    for _, entry in ipairs(config.SCHEMA) do t[entry.key] = entry.def end
    return t
end

-- Coerce whatever came off disk or off the command line into the declared kind,
-- and refuse rather than guess when it does not fit. Returns value, error.
function config.coerce(key, raw)
    local entry = byKey[key]
    if not entry then return nil, "no such setting: " .. tostring(key) end
    if entry.kind == "bool" then
        if type(raw) == "boolean" then return raw end
        local s = tostring(raw):lower()
        if s == "true" or s == "yes" or s == "on" or s == "1" then return true end
        if s == "false" or s == "no" or s == "off" or s == "0" then return false end
        return nil, key .. " is on or off"
    end
    local n = tonumber(raw)
    if not n then return nil, key .. " is a number" end
    if entry.kind == "int" then n = math.floor(n + 0.5) end
    if entry.min and n < entry.min then return nil, string.format("%s is at least %g", key, entry.min) end
    if entry.max and n > entry.max then return nil, string.format("%s is at most %g", key, entry.max) end
    return n
end

function config.get(key)
    return config.values[key]
end

-- Single place a setting changes. onChange, if the host gave one, is how the
-- control loop learns its gains moved without polling for it.
config.onChange = nil

function config.set(key, raw)
    local value, err = config.coerce(key, raw)
    if err then return nil, err end
    local old = config.values[key]
    config.values[key] = value
    if old ~= value then
        config.save()
        if config.onChange then config.onChange(key, value, old) end
    end
    return value
end

function config.format(key)
    local v = config.values[key]
    local entry = byKey[key]
    if not entry then return tostring(v) end
    if entry.kind == "bool" then return v and "on" or "off" end
    if entry.kind == "int" then return string.format("%d", v) end
    return string.format("%g", v)
end

-- One arrow-key nudge in the TUNE tab.
function config.nudge(key, dir)
    local entry = byKey[key]
    if not entry then return nil, "no such setting" end
    if entry.kind == "bool" then
        return config.set(key, not config.values[key])
    end
    return config.set(key, config.values[key] + entry.step * dir)
end

function config.reset(key)
    if key then
        local entry = byKey[key]
        if not entry then return nil, "no such setting: " .. key end
        return config.set(key, entry.def)
    end
    config.values = config.defaults()
    config.save()
    if config.onChange then config.onChange(nil, nil, nil) end
    return true
end

function config.keysIn(group)
    local out = {}
    for _, entry in ipairs(config.SCHEMA) do
        if entry.group == group then out[#out + 1] = entry.key end
    end
    return out
end

function config.load()
    config.values = config.defaults()
    if not config.FILE or not fs.exists(config.FILE) then return false end
    local handle = fs.open(config.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end
    -- Unknown keys are dropped and bad values fall back to the default, so an
    -- old config from an older build still boots. The flight envelope keys the
    -- omni hull flew by are retired rather than migrated: there is nothing on
    -- this ship for climbSpeed or slowRadius to mean.
    for key, raw in pairs(data) do
        if byKey[key] then
            local value = config.coerce(key, raw)
            if value ~= nil then config.values[key] = value end
        end
    end
    return true
end

function config.save()
    if not config.FILE then return false end
    local dir = fs.getDir(config.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(config.FILE, "w")
    if not handle then return false end
    handle.write(textutils.serialize(config.values))
    handle.close()
    return true
end

function config.init(dataDir)
    config.FILE = fs.combine(dataDir, "config.cfg")
    config.load()
    return config
end

return config
