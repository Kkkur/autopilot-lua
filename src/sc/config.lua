-- config.lua -- every number the autopilot flies by, in one place.
--
-- The schema below is the whole tuning surface. Anything listed here can be
-- changed from the TUNE tab or with `set <key> <value>` while flying, is
-- written to disk the moment it changes, and is loaded again at boot. Nothing
-- else in the program is allowed to hardcode a flight constant: if it matters,
-- it lives here and the pilot can reach it.

local config = {}

config.FILE = nil   -- filled in by init, lives under the data directory

-- group: which TUNE page it shows up on.
-- kind:  "number" | "int" | "bool"
-- step:  how far one arrow-key nudge moves it.
config.SCHEMA = {
    -- Flight envelope
    { key = "cruiseSpeed",   group = "flight", kind = "number", def = 12.0, min = 0.5, max = 120, step = 0.5,
      help = "Top speed the autopilot will ask for, m/s." },
    { key = "slowRadius",    group = "flight", kind = "number", def = 40.0, min = 1,   max = 500, step = 5,
      help = "Distance over which the approach speed is bled off to zero." },
    { key = "holdAlt",       group = "flight", kind = "bool",   def = true,
      help = "Hold the target Y as hard as X and Z, rather than drifting to it." },
    { key = "climbSpeed",    group = "flight", kind = "number", def = 6.0,  min = 0.5, max = 60,  step = 0.5,
      help = "Top vertical speed, m/s. Kept separate: up is the expensive axis." },
    { key = "stationKeep",   group = "flight", kind = "bool",   def = true,
      help = "After arriving, keep fighting drift instead of cutting the props." },

    -- Loop and outputs
    { key = "tick",          group = "loop",   kind = "number", def = 0.2,  min = 0.05, max = 2.0, step = 0.05,
      help = "Control loop period, seconds. 0.05 is one server tick." },
    { key = "maxRpm",        group = "loop",   kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Ceiling on any one line. The controller clamps here itself." },
    { key = "minRpm",        group = "loop",   kind = "int",    def = 16,   min = 0,   max = 256, step = 4,
      help = "Below this a demand is dropped to zero rather than buzzing." },
    { key = "rpmSlew",       group = "loop",   kind = "int",    def = 64,   min = 4,   max = 256, step = 8,
      help = "Most RPM one line may change per tick. Softens the shove." },

    -- Gains. The speed loop is what the velocity calibration feeds.
    { key = "posKp",         group = "gains",  kind = "number", def = 0.35, min = 0,   max = 5,   step = 0.05,
      help = "Position error to demanded speed, (m/s) per block." },
    { key = "posKi",         group = "gains",  kind = "number", def = 0.0,  min = 0,   max = 1,   step = 0.01,
      help = "Integral on position. Trims out a steady push like wind." },
    { key = "posKd",         group = "gains",  kind = "number", def = 0.0,  min = 0,   max = 5,   step = 0.05,
      help = "Derivative on position error." },
    { key = "spdKp",         group = "gains",  kind = "number", def = 18.0, min = 0,   max = 200, step = 1,
      help = "Speed error to RPM trim, on top of the calibrated feed-forward." },
    { key = "spdKi",         group = "gains",  kind = "number", def = 4.0,  min = 0,   max = 100, step = 0.5,
      help = "Integral on speed error. Covers what calibration got wrong." },
    { key = "spdKd",         group = "gains",  kind = "number", def = 2.0,  min = 0,   max = 100, step = 0.5,
      help = "Derivative on speed error." },
    { key = "spdILimit",     group = "gains",  kind = "number", def = 6.0,  min = 0,   max = 100, step = 1,
      help = "Clamp on the speed integral, in m/s-seconds." },
    { key = "useCurves",     group = "gains",  kind = "bool",   def = true,
      help = "Use the measured RPM-to-speed curves as feed-forward." },

    -- Direction calibration
    { key = "calRpm",        group = "cal",    kind = "int",    def = 128,  min = 16,  max = 256, step = 16,
      help = "RPM one line spins at while its direction is being read." },
    { key = "calSample",     group = "cal",    kind = "number", def = 0.3,  min = 0.05, max = 2, step = 0.05,
      help = "Seconds between live drift readings during calibration." },
    { key = "calMinDrift",   group = "cal",    kind = "number", def = 0.15, min = 0.01, max = 5, step = 0.05,
      help = "Drift below this reads as noise, not as a direction." },

    -- Velocity calibration
    { key = "velSteps",      group = "vcal",   kind = "int",    def = 6,    min = 2,   max = 16,  step = 1,
      help = "How many RPM steps each axis is measured at." },
    { key = "velStartRpm",   group = "vcal",   kind = "int",    def = 48,   min = 8,   max = 256, step = 8,
      help = "Lowest RPM step of a velocity run." },
    { key = "velEndRpm",     group = "vcal",   kind = "int",    def = 256,  min = 16,  max = 256, step = 8,
      help = "Highest RPM step of a velocity run." },
    { key = "velSettle",     group = "vcal",   kind = "number", def = 12.0, min = 1,   max = 120, step = 1,
      help = "Seconds a step may take to reach a steady speed before giving up." },
    { key = "velHold",       group = "vcal",   kind = "number", def = 3.0,  min = 0.5, max = 60,  step = 0.5,
      help = "Seconds the speed has to stay steady before the step is kept." },
    { key = "velStable",     group = "vcal",   kind = "number", def = 0.25, min = 0.01, max = 5,  step = 0.05,
      help = "How much the speed may still be changing, m/s per second." },
    { key = "velCooldown",   group = "vcal",   kind = "number", def = 4.0,  min = 0,   max = 60,  step = 0.5,
      help = "Seconds of all-stop between steps, to shed the speed built up." },
    { key = "velBothWays",   group = "vcal",   kind = "bool",   def = true,
      help = "Measure each axis in both directions. Twice as slow, twice as right." },

    -- Fuel. The numbers live here rather than on the relay because these are
    -- the captain's judgement calls, not facts about the tanks.
    { key = "fuelWarn",      group = "fuel",   kind = "number", def = 30.0, min = 0,   max = 100, step = 5,
      help = "Below this percent the fuel panel warns." },
    { key = "fuelCrit",      group = "fuel",   kind = "number", def = 12.0, min = 0,   max = 100, step = 2,
      help = "Below this percent it says land or refuel now." },
    { key = "fuelReserve",   group = "fuel",   kind = "number", def = 20.0, min = 0,   max = 90,  step = 5,
      help = "Fuel that is not yours to spend. Endurance is quoted above it." },
    { key = "fuelStale",     group = "fuel",   kind = "number", def = 8.0,  min = 1,   max = 120, step = 1,
      help = "Seconds of silence before the relay link counts as lost." },
    { key = "fuelImbalance", group = "fuel",   kind = "number", def = 15.0, min = 0,   max = 100, step = 5,
      help = "Percent difference between tanks that reads as a pump fault." },

    -- Turbine relay. Stress is the relay's reading; what counts as too much of
    -- it is the captain's call, so the thresholds live here.
    { key = "stressWarn",    group = "turbine", kind = "number", def = 75.0, min = 0, max = 100, step = 5,
      help = "Percent of stress capacity that reads as working the network hard." },
    { key = "stressCrit",    group = "turbine", kind = "number", def = 92.0, min = 0, max = 100, step = 2,
      help = "Percent at which the next demand is what breaks the network." },
    { key = "turbineStale",  group = "turbine", kind = "number", def = 5.0,  min = 1, max = 120, step = 1,
      help = "Seconds of silence before the turbine relay counts as lost." },

    -- == THE TANK TURN HULL ==================================
    -- Everything below flies the ship that exists. Everything above it flies the
    -- one that was replaced, and is retired in stage 7 once nothing reads it.

    -- The turn. The ship steers by driving one side against the other, so these
    -- are the numbers that decide how it points itself at anything.
    { key = "tankRpmMax",    group = "tank",   kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Most differential RPM a tank turn will ask for." },
    { key = "tankRpmMin",    group = "tank",   kind = "int",    def = 16,   min = 0,   max = 128, step = 4,
      help = "Below this a controller buzzes without turning anything, so it is dropped." },
    { key = "tankPadding",   group = "tank",   kind = "number", def = 2.0,  min = 0.1, max = 30,  step = 0.5,
      help = "Degrees of heading error that count as lined up." },
    { key = "tankHold",      group = "tank",   kind = "number", def = 2.0,  min = 0,   max = 30,  step = 0.5,
      help = "Seconds it must stay lined up before cruise is committed to." },
    { key = "tankHoldRate",  group = "tank",   kind = "number", def = 2.0,  min = 0.1, max = 30,  step = 0.5,
      help = "Yaw rate below which the hull counts as no longer swinging." },
    { key = "tankReentry",   group = "tank",   kind = "number", def = 25.0, min = 1,   max = 180, step = 5,
      help = "Heading error in cruise that sends it back to a tank turn." },
    { key = "yawRateMax",    group = "tank",   kind = "number", def = 30.0, min = 1,   max = 180, step = 5,
      help = "Fastest turn the autopilot will ask for, deg/s." },
    { key = "yawKp",         group = "tank",   kind = "number", def = 4.0,  min = 0,   max = 100, step = 0.5,
      help = "Heading error to wanted yaw rate. Raise it if turns finish slowly." },
    { key = "yawKi",         group = "tank",   kind = "number", def = 0.0,  min = 0,   max = 20,  step = 0.1,
      help = "Integral on heading. Trims out a steady pull to one side." },
    { key = "yawKd",         group = "tank",   kind = "number", def = 0.5,  min = 0,   max = 50,  step = 0.1,
      help = "Derivative on heading. Raise it if the hull swings past and back." },

    -- The run. Once it is pointing the right way it is one propeller problem.
    { key = "cruiseRampTime", group = "cruise", kind = "number", def = 7.0, min = 0,   max = 120, step = 0.5,
      help = "Seconds thrust takes to come on. Five propellers at once is a shove." },
    { key = "cruiseMaxRpm",  group = "cruise", kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Ceiling on the common thrust demand." },
    { key = "cruiseMinRpm",  group = "cruise", kind = "int",    def = 16,   min = 0,   max = 128, step = 4,
      help = "Below this the thrust demand is dropped to zero." },
    { key = "yawTrimInterval", group = "cruise", kind = "number", def = 3.0, min = 0.1, max = 60, step = 0.5,
      help = "Seconds between heading trims while running." },
    { key = "yawTrimThresh", group = "cruise", kind = "number", def = 0.5,  min = 0,   max = 30,  step = 0.1,
      help = "Heading error small enough to leave alone while running." },
    { key = "yawTrimRpm",    group = "cruise", kind = "int",    def = 128,  min = 0,   max = 256, step = 16,
      help = "Most differential a trim may use. A trim is not a turn." },

    -- Stopping, which is the part that ends flights when it is got wrong.
    { key = "arriveDist",    group = "brake",  kind = "number", def = 1.0,  min = 0.1, max = 100, step = 0.5,
      help = "Inside this many blocks of the target, the leg is done." },
    { key = "brakeMargin",   group = "brake",  kind = "number", def = 3.0,  min = 1.0, max = 10,  step = 0.1,
      help = "How much earlier than the last moment it starts stopping. Raise it if the ship sails past the point." },
    { key = "brakeRpmMax",   group = "brake",  kind = "int",    def = 256,  min = 16,  max = 256, step = 16,
      help = "Most reverse RPM a stop will ask for." },
    { key = "brakeSlew",     group = "brake",  kind = "int",    def = 16,   min = 1,   max = 256, step = 4,
      help = "How fast reverse comes on. Suddenness is what tips the hull." },
    { key = "pitchLimit",    group = "brake",  kind = "number", def = 12.0, min = 1,   max = 80,  step = 1,
      help = "Degrees of nose down that count as tipping. Caps the brake ladder." },
    { key = "pitchWatch",    group = "brake",  kind = "bool",   def = true,
      help = "Raise a popup when the hull pitches past the limit in flight." },

    -- Arriving. A hull that cannot strafe stops on its bearing and lives with
    -- whatever that leaves.
    { key = "lateralCorrect", group = "arrival", kind = "number", def = 4.0, min = 0.1, max = 100, step = 0.5,
      help = "Blocks off the line that are worth turning around for." },
    { key = "creepSpeed",    group = "arrival", kind = "number", def = 1.5,  min = 0.1, max = 20,  step = 0.5,
      help = "Speed of the short correcting run onto the point, m/s." },
    { key = "creepTries",    group = "arrival", kind = "int",    def = 3,    min = 1,   max = 20,  step = 1,
      help = "Attempts at the point before it gives up and says so." },
    { key = "holdDrift",     group = "arrival", kind = "number", def = 6.0,  min = 0.1, max = 100, step = 0.5,
      help = "Drift while holding that is worth turning and creeping back for." },

    -- How a demand is split across whatever propellers the ship turned out to
    -- have. The shares are for a hull whose main is worth more than a turbine.
    { key = "mainShare",     group = "mix",    kind = "number", def = 1.0,  min = 0,   max = 2,   step = 0.05,
      help = "Share of the thrust demand the main propeller takes." },
    { key = "turbineShare",  group = "mix",    kind = "number", def = 1.0,  min = 0,   max = 2,   step = 0.05,
      help = "Share of the thrust demand each turbine takes." },

    -- The balloon. This is the only thing holding the ship up, which is why the
    -- floor exists and why it is not zero.
    { key = "altKp",         group = "altitude", kind = "number", def = 0.5, min = 0,  max = 20,  step = 0.05,
      help = "Altitude error to wanted climb rate, (m/s) per block." },
    { key = "altKi",         group = "altitude", kind = "number", def = 0.0, min = 0,  max = 5,   step = 0.01,
      help = "Integral on altitude. Trims out a slow leak or a heavy load." },
    { key = "altKd",         group = "altitude", kind = "number", def = 0.8, min = 0,  max = 20,  step = 0.05,
      help = "Damping on vertical speed. Raise it if the ship porpoises." },
    { key = "altDeadband",   group = "altitude", kind = "number", def = 2.0, min = 0,  max = 50,  step = 0.5,
      help = "Blocks of altitude error worth doing nothing about." },
    { key = "climbRateMax",  group = "altitude", kind = "number", def = 3.0, min = 0.1, max = 30, step = 0.5,
      help = "Fastest climb the autopilot will ask the balloon for, m/s." },
    { key = "sinkRateMax",   group = "altitude", kind = "number", def = 3.0, min = 0.1, max = 30, step = 0.5,
      help = "Fastest descent it will ask for. Kept separate: down is the cheap way to lose a ship." },
    { key = "balloonFloor",  group = "altitude", kind = "int",    def = 2,   min = 0,  max = 15,  step = 1,
      help = "Strength the balloon is never driven below. Zero is the ground." },
    { key = "balloonStale",  group = "altitude", kind = "number", def = 5.0, min = 1,  max = 120, step = 1,
      help = "Seconds of silence before the balloon relay counts as lost." },
    { key = "altAskDelta",   group = "altitude", kind = "number", def = 15.0, min = 0, max = 200, step = 5,
      help = "Altitude change big enough to ask about before flying it." },

    -- Preflight
    { key = "fuelMargin",    group = "preflight", kind = "number", def = 1.25, min = 1, max = 5, step = 0.05,
      help = "How much more fuel than the leg needs before it is allowed." },
    { key = "requireStressBudget", group = "preflight", kind = "bool", def = true,
      help = "Refuse a leg the kinetic network cannot supply at full demand." },

    -- Screen
    { key = "uiTick",        group = "ui",     kind = "number", def = 0.25, min = 0.05, max = 2, step = 0.05,
      help = "Screen refresh period, seconds." },
    { key = "logLevel",      group = "ui",     kind = "int",    def = 2,    min = 0,   max = 3,   step = 1,
      help = "0 errors, 1 warnings, 2 info, 3 everything." },
    { key = "colorful",      group = "ui",     kind = "bool",   def = true,
      help = "Full colour. Off gives a readable monochrome for gold monitors." },
}

config.GROUPS = {
    { id = "tank",     title = "TANK TURN" },
    { id = "cruise",   title = "CRUISE" },
    { id = "brake",    title = "BRAKING" },
    { id = "arrival",  title = "ARRIVAL" },
    { id = "altitude", title = "ALTITUDE" },
    { id = "mix",      title = "MIXING" },
    { id = "preflight", title = "PREFLIGHT" },
    { id = "flight",   title = "FLIGHT ENVELOPE" },
    { id = "loop",     title = "CONTROL LOOP" },
    { id = "gains",    title = "GAINS" },
    { id = "cal",      title = "DIRECTION CAL" },
    { id = "vcal",     title = "VELOCITY CAL" },
    { id = "fuel",     title = "FUEL" },
    { id = "turbine",  title = "TURBINE RELAY" },
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
    -- old config from an older build still boots.
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
