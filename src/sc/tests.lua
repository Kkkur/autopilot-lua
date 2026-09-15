-- tests.lua -- `starcatcher --test`.
--
-- Everything checked here is pure: quaternions, the flight maths, curve lookup,
-- config coercion, calibration file parsing, and what the fuel relay's numbers
-- mean.
-- No ship, no peripherals, no modem. If this passes on a bare computer, the
-- maths that flies the ship is sound and anything still wrong is wiring.

local util, config, cal, fuel, turbine, ship, flight = ...

local tests = {}

local passed, failed = 0, 0

local function check(ok, what)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. what)
    end
end

local function near(a, b, what, tol)
    check(type(a) == "number" and math.abs(a - b) < (tol or 1e-6),
        string.format("%s: got %s want %.6f", what, tostring(a), b))
end

function tests.run()
    passed, failed = 0, 0

    -- == quaternions ==
    local x, y, z = util.qRotate(0, 0, 0, 1, 3, -4, 5)
    near(x, 3, "identity x"); near(y, -4, "identity y"); near(z, 5, "identity z")

    -- 90 degrees about +Y takes body +Z to world +X.
    local h = math.sqrt(0.5)
    x, y, z = util.qRotate(0, h, 0, h, 0, 0, 1)
    near(x, 1, "yaw90 x"); near(y, 0, "yaw90 y"); near(z, 0, "yaw90 z")

    -- So a world +X vector read on that ship is body +Z.
    local q = { x = 0, y = h, z = 0, w = h }
    x, y, z = util.worldToBody(q, 1, 0, 0)
    near(x, 0, "toBody x"); near(y, 0, "toBody y"); near(z, 1, "toBody z")

    x, y, z = util.bodyToWorld(q, util.worldToBody(q, 2, 3, -7))
    near(x, 2, "round x"); near(y, 3, "round y"); near(z, -7, "round z")

    -- Every quaternion shape CC: Sable has handed out reads the same rotation.
    local flat = util.toQuat({ x = 0, y = h, z = 0, w = h })
    local pair = util.toQuat({ a = h, v = { x = 0, y = h, z = 0 } })
    local list = util.toQuat({ 0, h, 0, h })
    for _, shape in ipairs({ flat, pair, list }) do
        local bx, by, bz = util.worldToBody(shape, 1, 0, 0)
        near(bx, 0, "shape x"); near(by, 0, "shape y"); near(bz, 1, "shape z")
    end
    check(util.toQuat({ a = h, v = { 0, h, 0 } }) ~= nil, "an array vector part still reads")
    check(util.toQuat("nope") == nil, "junk is not a quaternion")
    check(util.toQuat({ foo = 1 }) == nil, "an unknown shape is refused")
    check(util.toQuat({ x = 0, y = 0, z = 0, w = 0 }) == nil, "a zero quaternion is refused")
    near(util.toQuat({ x = 0, y = 2, z = 0, w = 0 }).y, 1, "a long quaternion is normalized")

    check(util.toVec({ x = 1, y = 2, z = 3 }).z == 3, "a named vector reads")
    check(util.toVec({ 1, 2, 3 }).z == 3, "an array vector reads")
    check(util.toVec({ x = 1, y = 2 }) == nil, "a short vector is refused")
    check(util.keyList({ a = 1, v = 2 }) == "{a,v}", "keys are listed for the screen")
    check(util.keyList(nil) == "nil", "and a non table says so")

    -- == yaw ==
    near(util.yawOf({ x = 0, y = 0, z = 0, w = 1 }), 0, "identity faces +Z")
    -- That quarter turn about +Y points the ship at world +X, which is east,
    -- which is yaw -90 the way Minecraft counts.
    near(util.yawOf({ x = 0, y = h, z = 0, w = h }), -90, "a quarter turn faces east")
    check(util.compass(util.yawOf({ x = 0, y = h, z = 0, w = h })) == "E", "and reads as east")
    near(util.wrapAngle(370), 10, "wrap over")
    near(util.wrapAngle(-190), 170, "wrap under")
    near(util.wrapAngle(180), 180, "180 stays 180")
    check(util.compass(0) == "S", "0 degrees is south")
    check(util.compass(180) == "N", "180 degrees is north")

    -- == labels and directions ==
    check(util.dominantDirection(0, 0, -2.4) == "north", "reads a north drift")
    check(util.dominantDirection(-1.1, 0.2, 0.3) == "west", "reads the dominant axis")
    check(util.dominantDirection(0.01, 0, -0.02) == "none", "ignores noise")
    check(util.labelFor({ 0, 0, 1 }) == "south", "labels a known axis")
    check(util.labelFor({ 0.5, 0.5, 0 }) == "custom", "does not invent a label")
    check(util.labelFor(nil) == "?", "an uncalibrated line has no label")
    check(util.makeAxis("up", true).reverse == true, "the reverse flag is carried")
    check(util.DIRECTIONS.up.reverse == nil, "the shared direction is never tagged")
    check(util.labelFor(util.makeAxis("up", true)) == "up", "reversing does not change the label")
    check(util.shortName("Create_RotationSpeedController_3") == "#3", "short name")

    -- == PID ==
    local pid = util.newPID(2, 0, 0, -10, 10)
    near(pid:update(3, 0.1), 6, "proportional")
    near(pid:update(100, 0.1), 10, "output clamps")
    pid = util.newPID(0, 1, 0, -100, 100, 2)
    pid:update(10, 1); pid:update(10, 1)
    near(pid.integral, 2, "the integral is clamped")
    pid:reset()
    near(pid.integral, 0, "reset clears it")

    -- == speed curves ==
    -- A ship that does 2 m/s at 50 rpm, 4 at 100, 5 at 200: real propellers
    -- flatten off, so the top of the curve is not a straight line.
    local curve = { { rpm = 50, speed = 2 }, { rpm = 100, speed = 4 }, { rpm = 200, speed = 5 } }
    near(util.curveSpeedAt(curve, 50), 2, "curve at a sample")
    near(util.curveSpeedAt(curve, 75), 3, "curve between samples")
    near(util.curveSpeedAt(curve, 150), 4.5, "curve on the flat part")
    near(util.curveSpeedAt(curve, 25), 1, "curve below the lowest sample")
    near(util.curveSpeedAt(curve, 400), 5, "curve does not extrapolate past the top")
    near(util.curveRpmFor(curve, 2), 50, "inverse at a sample")
    near(util.curveRpmFor(curve, 3), 75, "inverse between samples")
    near(util.curveRpmFor(curve, 4.5), 150, "inverse on the flat part")
    near(util.curveRpmFor(curve, 99), 200, "asking for more than it has gives everything")
    near(util.curveTopSpeed(curve), 5, "top speed")
    check(util.curveRpmFor(nil, 5) == nil, "no curve, no answer")
    check(util.curveSpeedAt({}, 5) == nil, "an empty curve has no answer")

    local tidy = util.tidyCurve({ { rpm = 200, speed = 5 }, { rpm = 50, speed = 2 },
                                  { rpm = -100, speed = -4 }, "junk" })
    check(#tidy == 3, "tidy drops junk")
    check(tidy[1].rpm == 50 and tidy[3].rpm == 200, "tidy sorts by rpm")
    check(tidy[2].speed == 4, "tidy takes magnitudes")

    -- == config ==
    config.values = config.defaults()
    check(config.get("maxRpm") == 256, "defaults load")
    check(select(2, config.coerce("nope", 1)) ~= nil, "an unknown key is refused")
    check(config.coerce("maxRpm", "128") == 128, "numbers come off strings")
    check(config.coerce("minRpm", "3.7") == 4, "an int setting rounds")
    check(config.coerce("colorful", "off") == false, "off is false")
    check(config.coerce("colorful", "yes") == true, "yes is true")
    check(select(2, config.coerce("colorful", "maybe")) ~= nil, "maybe is not a boolean")
    check(select(2, config.coerce("maxRpm", 9999)) ~= nil, "over the maximum is refused")
    check(select(2, config.coerce("maxRpm", 1)) ~= nil, "under the minimum is refused")
    check(config.format("colorful") == "on", "booleans format as words")
    for _, entry in ipairs(config.SCHEMA) do
        check(config.coerce(entry.key, entry.def) ~= nil,
            "the default for " .. entry.key .. " passes its own bounds")
    end

    -- == calibration file ==
    local axes, missing = cal.parseAxes(nil, { "a", "b", "c" })
    check(next(axes) == nil and #missing == 3, "no config means everything is missing")
    axes, missing = cal.parseAxes({ a = { 0, 1, 0 }, b = "junk", c = { 1, 2 } }, { "a", "b", "c" })
    check(axes.a[2] == 1, "a good entry loads")
    check(#missing == 2 and missing[1] == "b" and missing[2] == "c", "bad entries are named")
    axes, missing = cal.parseAxes({ a = { 0, 1, 0 }, z = { 1, 0, 0 } }, { "a" })
    check(#missing == 0 and axes.z == nil, "a controller that left is dropped")
    check(axes.a.reverse == false, "an old file with no reverse flag still loads")
    axes = cal.parseAxes({ a = { 0, 1, 0, reverse = true } }, { "a" })
    check(axes.a.reverse == true, "and the flag round trips")

    local curves = cal.parseCurves({
        y = { pos = { { rpm = 100, speed = 3 }, { rpm = 50, speed = 1 } }, neg = {} },
        q = { pos = { { rpm = 10, speed = 1 } } },
    })
    check(curves.y and #curves.y.pos == 2, "a curve loads")
    check(curves.y.pos[1].rpm == 50, "and comes back sorted")
    check(curves.y.neg == nil, "an empty direction is dropped")
    check(curves.q == nil, "a bogus axis name is dropped")

    -- == mixing ==
    -- Two propellers on the same axis, one mounted up and one mounted down,
    -- both wired forwards. Asking to climb must drive them opposite ways so
    -- they push the same real direction.
    local up = util.makeAxis("up")
    local down = util.makeAxis("down")
    local index = util.AXIS_INDEX.y
    near(up[index], 1, "up is +y")
    near(down[index], -1, "down is -y")
    local rpmUp = 100 * up[index] * (up.reverse and -1 or 1)
    local rpmDown = 100 * down[index] * (down.reverse and -1 or 1)
    check(rpmUp > 0 and rpmDown < 0, "opposed propellers get opposite signs")
    local revUp = util.makeAxis("up", true)
    check(100 * revUp[index] * (revUp.reverse and -1 or 1) < 0,
        "a reversed line is negated on top of where it points")

    -- == fuel ==
    -- The relay is a computer that is not here, so what gets tested is the
    -- arithmetic this end does to its message: what counts as a burn, what the
    -- reserve takes out of the endurance, and what the advice says about it.
    config.values = config.defaults()
    local function relay(total, capacity, rate, tanks)
        return { v = 1, total = total, capacity = capacity, rate = rate,
                 fraction = total / capacity, rateWindow = 60,
                 tanks = tanks or {
                     { side = "left", fluid = "minecraft:lava", amount = total / 2,
                       capacity = capacity / 2, capSource = "reported", ok = true },
                     { side = "right", fluid = "minecraft:lava", amount = total / 2,
                       capacity = capacity / 2, capSource = "reported", ok = true },
                 } }
    end

    check(fuel.accept(3, { v = 1, tanks = {} }) == true, "a well formed message is taken")
    check(fuel.accept(3, { v = 2, tanks = {} }) == false, "a future version is refused")
    check(fuel.accept(3, "hello") == false, "junk on the protocol is refused")

    fuel.modem = "top"
    fuel.accept(3, relay(16000, 32000, -10))
    local status = fuel.status()
    near(status.fraction, 0.5, "half full reads as half")
    near(status.burn, 10, "a negative rate is a burn")
    -- 20% of 32000 is 6400 held back, so 9600 of the 16000 is the captain's.
    near(status.usable, 9600, "the reserve comes off the usable fuel")
    near(status.endurance, 960, "endurance is usable over burn")
    near(status.dry, 1600, "and dry is everything over burn")

    fuel.accept(3, relay(16000, 32000, 0.02))
    status = fuel.status()
    check(status.burn == 0 and status.filling == nil,
        "a rate in the noise is neither a burn nor a fill")

    fuel.accept(3, relay(8000, 32000, 20))
    status = fuel.status()
    near(status.filling, 20, "a positive rate is a fill")
    near(status.fullIn, 1200, "and it knows when the tanks are full")

    -- Two tanks at 90% and 10% average out to a total that looks fine, which is
    -- exactly the case the imbalance check exists for.
    fuel.accept(3, relay(16000, 32000, -10, {
        { side = "left", fluid = "minecraft:lava", amount = 14400, capacity = 16000,
          capSource = "reported", ok = true },
        { side = "right", fluid = "minecraft:lava", amount = 1600, capacity = 16000,
          capSource = "reported", ok = true },
    }))
    local found = false
    for _, item in ipairs(fuel.advice(fuel.status(), {})) do
        if item.text:find("uneven") then found = true end
    end
    check(found, "uneven tanks are called out even when the total looks healthy")

    fuel.accept(3, relay(1000, 32000, -10))
    local critical = false
    for _, item in ipairs(fuel.advice(fuel.status(), {})) do
        if item.kind == "bad" then critical = true end
    end
    check(critical, "3% fuel is advised as critical")

    fuel.modem = nil
    check(fuel.status().link == "nomodem", "no modem is a link state, not an error")

    -- == turbines ==
    -- The relay is a computer that is not here either. What matters is that its
    -- lines land in `ship` looking exactly like wired ones, that they leave
    -- again when the relay stops naming them, and that their RPM goes out over
    -- the radio instead of into a peripheral that does not exist.
    config.values = config.defaults()

    -- Lines arrive named the way a relay names them: its own computer id, then
    -- the peripheral name. Both relays on this ship hold a controller ending _0,
    -- which is exactly why the id is in there.
    local function relayLines(id, ports, extra)
        local list = {}
        for index, port in ipairs(ports) do
            list[index] = { name = id .. ":" .. port, short = util.shortName(id .. ":" .. port),
                            demand = 0, actual = 0 }
        end
        local message = { v = 1, id = id, lines = list, maxRpm = 256,
                          stress = 6000, stressCapacity = 8000, stressFraction = 0.75,
                          stressOk = true, overstressed = false }
        for key, value in pairs(extra or {}) do message[key] = value end
        return message
    end

    check(util.shortName("2:Create_RotationSpeedController_3") == "#2.3",
        "a relay line reads as its relay and its number")
    check(util.shortName("Create_RotationSpeedController_3") == "#3",
        "and a wired one is unchanged")

    check(turbine.accept(19, { v = 1, lines = {} }) == true, "a well formed message is taken")
    check(turbine.accept(19, { v = 2, lines = {} }) == false, "a future version is refused")
    check(turbine.accept(19, 42) == false, "junk on the protocol is refused")

    turbine.modem = "top"
    turbine.accept(2, relayLines(2, { "Create_RotationSpeedController_0",
                                      "Create_RotationSpeedController_1" }))
    check(#ship.order == 2, "the relay's lines are adopted as the ship's own")
    check(ship.lines["2:Create_RotationSpeedController_0"].remote == true,
        "and they are marked as living on a radio")
    check(ship.lines["2:Create_RotationSpeedController_0"].wrap == nil,
        "a remote line has no peripheral to wrap")
    check(ship.lines["2:Create_RotationSpeedController_0"].port
        == "Create_RotationSpeedController_0",
        "the bare name is kept, for telling a human which block this is")

    -- The second relay. Its controller has the same peripheral name as the first
    -- relay's, which is the collision the whole qualified name exists for, and
    -- neither relay's message says anything about the other one's lines.
    turbine.accept(3, relayLines(3, { "Create_RotationSpeedController_0" },
        { hasBalloon = true, balloon = 7 }))
    check(#ship.order == 3, "two relays make three lines, not one")
    check(ship.lines["3:Create_RotationSpeedController_0"] ~= nil
        and ship.lines["2:Create_RotationSpeedController_0"] ~= nil,
        "two controllers with the same peripheral name are two propellers")

    -- The defect this stage exists for. Relay 2 speaking again must not read as
    -- relay 3 having lost everything, or the two of them delete each other's
    -- half of the ship once a second and the ship flies on nothing.
    turbine.accept(2, relayLines(2, { "Create_RotationSpeedController_0",
                                      "Create_RotationSpeedController_1" }))
    check(#ship.order == 3, "one relay talking does not drop the other relay's lines")

    check(turbine.ownerOf("3:Create_RotationSpeedController_0") == 3, "a line knows its relay")
    local hasBalloon, balloonId = turbine.hasBalloon()
    check(hasBalloon and balloonId == 3, "and the relay holding the balloon is known")

    -- Sending twice with the same number has to put it on the air twice, or the
    -- relay's deadman reads the silence as this computer having died.
    local outbox = {}
    ship.sendRemote = function(demands)
        local copy = {}
        for name, rpm in pairs(demands) do copy[name] = rpm end
        outbox[#outbox + 1] = copy
    end
    ship.flush({ ["2:Create_RotationSpeedController_0"] = 120 })
    ship.flush({ ["2:Create_RotationSpeedController_0"] = 120 })
    check(#outbox == 2, "an unchanged remote demand is sent again anyway")
    check(outbox[2]["2:Create_RotationSpeedController_0"] == 120, "and it is the right number")
    ship.sendRemote = nil

    local status = turbine.status()
    near(status.fraction, 0.75, "stress comes through as a fraction")
    near(status.headroom, 2000, "headroom is capacity less stress")
    check(status.link == "live", "a message just received is a live link")
    local seenRelay = {}
    for _, one in ipairs(status.relays) do seenRelay[one.relayId] = true end
    check(seenRelay[2] and seenRelay[3], "the status carries every relay that has spoken")
    check(status.hasBalloon == true and status.balloon == 7,
        "and says who is holding the balloon and at what")

    local warned = false
    for _, item in ipairs(turbine.advice(status)) do
        if item.kind == "warn" or item.kind == "bad" then warned = true end
    end
    check(warned, "75 percent stress is worth saying out loud")

    turbine.accept(2, relayLines(2, { "Create_RotationSpeedController_0",
                                      "Create_RotationSpeedController_1" },
                                  { overstressed = true }))
    local shouted = false
    for _, item in ipairs(turbine.advice(turbine.status())) do
        if item.kind == "bad" then shouted = true end
    end
    check(shouted, "overstress is advised as critical")

    -- A controller broken off the relay stops being named, and a line the mixer
    -- still believes in would have it dividing thrust between a propeller that
    -- is not there and one that is.
    turbine.accept(2, relayLines(2, { "Create_RotationSpeedController_0" }))
    check(ship.lines["2:Create_RotationSpeedController_1"] == nil,
        "a line the relay stops naming is dropped")
    check(ship.lines["3:Create_RotationSpeedController_0"] ~= nil,
        "and the other relay's line is not collateral")

    turbine.modem = nil
    check(turbine.status().link == "nomodem", "no modem is a link state, not an error")

    -- == pitch ==
    -- The tip axis. A quarter turn about +X takes body +Z to world -Y, which is
    -- nose down, so the sign that reads as nose up is the other one.
    near(util.pitchOf({ x = 0, y = 0, z = 0, w = 1 }), 0, "identity is level")
    near(util.pitchOf({ x = -h, y = 0, z = 0, w = h }), 90, "nose straight up")
    near(util.pitchOf({ x = h, y = 0, z = 0, w = h }), -90, "nose straight down")
    -- Yaw alone never reads as pitch, which is the mistake that would have a
    -- ship refuse to brake as soon as it stopped pointing at +Z.
    near(util.pitchOf({ x = 0, y = h, z = 0, w = h }), 0, "a turn is not a tip")

    -- == the flight maths ==
    -- One calibrated ship, used by everything below. The two sides differ on
    -- purpose, the main is worth more than a turbine, and the brake ladder has a
    -- rung past the tip limit so graduated braking has something to refuse.
    local calShip = {
        sides = {
            ta = { side = "left",  reverse = false },
            tb = { side = "left",  reverse = false },
            tc = { side = "right", reverse = false },
            td = { side = "right", reverse = true },
            mn = { side = "main",  reverse = false },
            xx = { side = "none",  reverse = false },
        },
        noseOffset = 4,
        yawAuth = { left = 0.059, right = 0.066 },
        yawCurve = {
            pos = { { rpm = 64, speed = 8 }, { rpm = 128, speed = 16 }, { rpm = 256, speed = 32 } },
            neg = { { rpm = 64, speed = 8 }, { rpm = 128, speed = 16 }, { rpm = 256, speed = 32 } },
        },
        fwdCurve = {
            pos = { { rpm = 64, speed = 3 }, { rpm = 128, speed = 7 }, { rpm = 256, speed = 13 } },
            neg = { { rpm = 64, speed = 3 }, { rpm = 128, speed = 7 }, { rpm = 256, speed = 13 } },
        },
        brakeCurve = {
            main = { { rpm = 128, speed = 1.7, pitch = 3 }, { rpm = 256, speed = 3.4, pitch = 6 } },
            all  = { { rpm = 128, speed = 4.0, pitch = 8 }, { rpm = 256, speed = 7.5, pitch = 16 } },
        },
        balloonCurve = {
            { rpm = 0, speed = -1.78 }, { rpm = 7, speed = -0.05 },
            { rpm = 8, speed = 0.12 }, { rpm = 15, speed = 1.78 },
        },
        altHover = 7,
        stressAtTurn = 2400, stressAtCruise = 3600,
    }

    local cfg = {
        tankRpmMax = 256, tankRpmMin = 16, tankPadding = 2.0, tankHold = 2.0,
        tankHoldRate = 2.0, tankReentry = 25, yawRateMax = 30,
        cruiseSpeed = 12, cruiseRampTime = 7.0, yawTrimThresh = 0.5, yawTrimRpm = 128,
        arriveDist = 1.0, brakeMargin = 1.3, brakeRpmMax = 256, pitchLimit = 12,
        lateralCorrect = 4.0,
        maxRpm = 256, minRpm = 16, mainShare = 1.0, turbineShare = 1.0,
        altDeadband = 2.0, altKp = 0.5, altKd = 0.8, climbRateMax = 3, sinkRateMax = 3,
        balloonFloor = 2,
    }

    -- Bearings answer in the convention yawOf does, or the two could not be
    -- subtracted from one another, which is all headingError does.
    near(flight.bearingTo(0, 0, 0, 10), 0, "due +Z is bearing 0")
    near(flight.bearingTo(0, 0, -10, 0), 90, "due -X is bearing 90")
    near(flight.bearingTo(0, 0, 10, 0), -90, "due +X is bearing -90")
    near(flight.bearingTo(5, 5, 5, 5), 0, "no distance, no bearing")

    near(flight.headingError(90, 0, 0), 90, "a target to the right is positive")
    near(flight.headingError(0, 90, 0), -90, "and to the left is negative")
    near(flight.headingError(10, 0, 4), 6, "the nose offset comes off the error")
    near(flight.headingError(-170, 170, 0), 20, "the error wraps the short way")

    -- A ship facing +Z with the target off to its right, which is -X.
    near(flight.lateralError({ x = 0, z = 0 }, { x = -6, z = 40 }, 0), 6,
        "lateral error is positive to the right")
    near(flight.lateralError({ x = 0, z = 0 }, { x = 0, z = 40 }, 0), 0,
        "dead ahead is not off the line")

    local scaleL, scaleR = flight.sideScales(0.059, 0.066)
    near(scaleL, 1, "the weaker side runs at full rpm")
    check(scaleR < 1, "and the stronger is held back to match")
    near(0.059 * scaleL, 0.066 * scaleR, "so the two sides make equal torque")
    scaleL, scaleR = flight.sideScales(nil, 0.066)
    check(scaleL == 1 and scaleR == 1, "an uncalibrated side is not scaled")

    -- The ladder tops out at 256, so a rate past the fastest measured turn asks
    -- for everything rather than extrapolating a rate the hull has never done.
    near(flight.yawDifferential(16, calShip.yawCurve, 256), 128, "a rate reads back off the ladder")
    near(flight.yawDifferential(-16, calShip.yawCurve, 256), -128, "and the other way is signed")
    near(flight.yawDifferential(99, calShip.yawCurve, 256), 256, "past the top it asks for everything")
    near(flight.yawDifferential(16, calShip.yawCurve, 64), 64, "the cap is obeyed")
    check(flight.yawDifferential(16, nil, 256) == nil, "no ladder, no answer")

    local pid = util.newPID(4, 0, 0, -1000, 1000)
    local demand = flight.tankDemand(20, pid, calShip, cfg, 0.2)
    check(demand.left < 0 and demand.right > 0, "a right hand error drives the sides opposite")
    check(demand.main == 0, "and the main stays out of a tank turn")
    near(demand.rate, 30, "the wanted rate is capped at yawRateMax")

    pid:reset()
    demand = flight.tankDemand(-20, pid, calShip, cfg, 0.2)
    check(demand.left > 0 and demand.right < 0, "and the other way round the other way")

    pid:reset()
    demand = flight.tankDemand(0.01, pid, calShip, cfg, 0.2)
    check(demand.left == 0 and demand.right == 0,
        "a demand under tankRpmMin buzzes without turning, so it is dropped")

    near(flight.yawTrim(0.2, cfg), 0, "inside the threshold there is nothing to trim")
    near(flight.yawTrim(25, cfg), 128, "at the reentry angle the trim is at its ceiling")
    near(flight.yawTrim(-25, cfg), -128, "and it is signed")
    near(flight.yawTrim(12.5, cfg), 64, "and proportional in between")

    near(flight.throttleFraction(0, 7), 0, "thrust starts at nothing")
    near(flight.throttleFraction(7, 7), 1 - math.exp(-1), "and is 63 percent after one tau")
    check(flight.throttleFraction(100, 7) > 0.99, "and is all of it eventually")
    near(flight.throttleFraction(3, 0), 1, "no ramp means no ramping")

    near(flight.maxDecel(calShip, cfg), 4.0,
        "the brake cap is the last rung that kept pitch inside the limit")
    near(flight.maxDecel(calShip, cfg, "main"), 3.4, "the main never tips it at all")
    check(flight.maxDecel({}, cfg) == nil, "an unmeasured ship has no cap")

    -- Worth pinning, because it is not obvious and it decides whether the ship
    -- ever brakes gently. Braking begins at vLimit, where the deceleration the
    -- distance demands is already aMax over brakeMargin. So the main is used
    -- alone only on a ship whose main can supply that much on its own, and on a
    -- hull where it cannot, every stop recruits the turbines however gentle it
    -- looks. This ship is deliberately on the useful side of that line.
    check(flight.maxDecel(calShip, cfg, "main")
        > flight.maxDecel(calShip, cfg) / cfg.brakeMargin,
        "the main can supply what the margin asks for, so gentle stops exist")

    near(flight.speedLimitForDistance(100, 4, 1.3), math.sqrt(2 * 4 * 100 / 1.3), "stopping distance")
    near(flight.speedLimitForDistance(0, 4, 1.3), 0, "on top of it, stopped")
    check(flight.speedLimitForDistance(100, nil, 1.3) == math.huge,
        "with no measurement there is no limit to impose")

    -- Far away and long since up to speed, so cruiseSpeed is what is left after
    -- both the ramp and the stopping distance have had their say.
    near(flight.wantSpeed(5000, 600, cfg, calShip), 12, "a long leg asks for cruise speed")
    check(flight.wantSpeed(5000, 0.5, cfg, calShip) < 2, "a leg that just began ramps up")
    check(flight.wantSpeed(4, 600, cfg, calShip) < 12, "and close in, the distance caps it")

    local spd = util.newPID(0, 0, 0, -1000, 1000)
    near(flight.thrustRpm(7, 7, calShip.fwdCurve, spd, 0.2), 128,
        "at speed the feed forward is the whole answer")
    spd:reset()
    near(flight.thrustRpm(-7, -7, calShip.fwdCurve, spd, 0.2), -128, "and reverse is signed")
    spd:reset()
    near(flight.thrustRpm(7, 7, calShip.fwdCurve, spd, 0.2, 64), 64, "the cap is obeyed")
    spd = util.newPID(10, 0, 0, -1000, 1000)
    check(flight.thrustRpm(7, 5, calShip.fwdCurve, spd, 0.2) > 128,
        "and falling short of the wanted speed adds trim on top")

    -- Braking, which is the part that ends flights when it is got wrong.
    local plan, why = flight.brakePlan(2, 500, 0, calShip, cfg)
    check(plan.main == 0 and plan.turbines == 0, "nothing to do a long way out")
    check(why:find("inside") ~= nil, "and it says why")

    plan, why = flight.brakePlan(8.8, 12, 0, calShip, cfg)
    check(plan.main < 0 and plan.turbines == 0, "a gentle stop is the main alone")
    check(why:find("main alone") ~= nil, "and it says so")

    plan, why = flight.brakePlan(13, 12, 0, calShip, cfg)
    check(plan.main < 0 and plan.turbines < 0, "a hard stop recruits the turbines")
    check(why:find("all five") ~= nil, "and it says so in different words")

    plan, why = flight.brakePlan(13, 12, 17, calShip, cfg)
    check(plan.main == 0 and plan.turbines == 0, "already tipping, so it stops adding reverse")
    check(why:find("pitch") ~= nil, "and names the pitch rather than a general message")

    -- Mixing, where the differential is split and a backwards propeller is a
    -- flag in a file rather than a special case in the code.
    local lines = { "ta", "tb", "tc", "td", "mn", "xx" }
    local mixed = flight.mix(128, 0, lines, calShip, cfg)
    check(mixed.ta == mixed.tb, "two lines on the same side agree")
    check(mixed.td == -mixed.tc, "and a reversed line is negated")
    near(mixed.mn, 128, "the main takes its share")
    check(mixed.xx == 0, "a line calibrated as none is left alone")

    mixed = flight.mix(0, 64, lines, calShip, cfg)
    check(mixed.ta < 0 and mixed.tc > 0, "a positive differential raises yaw")
    check(mixed.mn == 0, "and the main takes no part in a turn")

    mixed = flight.mix(300, 0, lines, calShip, cfg)
    near(mixed.mn, 256, "nothing leaves here above maxRpm")
    mixed = flight.mix(8, 0, lines, calShip, cfg)
    check(mixed.mn == 0, "and nothing leaves here buzzing below minRpm")

    local slewed = flight.applySlew({ mn = 0 }, { mn = 256 }, 16)
    near(slewed.mn, 16, "a line climbs no faster than the slew")
    slewed = flight.applySlew({ mn = 0 }, { mn = -256 }, 16)
    near(slewed.mn, -16, "in either direction")
    slewed = flight.applySlew({ mn = 100 }, { mn = 104 }, 16)
    near(slewed.mn, 104, "and a small change arrives whole")
    slewed = flight.applySlew({}, { mn = 8 }, 16)
    near(slewed.mn, 8, "a line nobody has driven yet starts from zero")

    -- The balloon ladder crosses zero, which is the one thing util's curve
    -- family cannot read, so it has its own walk and its own tests.
    near(flight.levelForClimb(calShip.balloonCurve, -1.78), 0, "full sink is strength 0")
    near(flight.levelForClimb(calShip.balloonCurve, 1.78), 15, "full climb is strength 15")
    check(flight.levelForClimb(calShip.balloonCurve, 0) > 7, "and holding is between them")
    near(flight.levelForClimb(calShip.balloonCurve, -99), 0, "past the bottom it stays on the ladder")
    near(flight.levelForClimb(calShip.balloonCurve, 99), 15, "and past the top as well")
    check(flight.levelForClimb(nil, 0) == nil, "no ladder, no answer")

    check(flight.balloonLevel(40, 0, calShip, cfg) == 15, "a long way below the target, climb")
    check(flight.balloonLevel(-40, 0, calShip, cfg) == cfg.balloonFloor,
        "and a long way above it, sink to the floor and no further")
    check(flight.balloonLevel(0, 0, calShip, cfg) >= 7, "on the target, hold")
    -- The floor is a safety property, not a preference. A balloon commanded to
    -- zero is a ship on its way down, and the pilot asked for a descent, not that.
    check(flight.balloonLevel(-999, 0, calShip, cfg) >= cfg.balloonFloor,
        "nothing drives the balloon below the floor")
    local uncal = { altHover = 9 }
    check(flight.balloonLevel(50, 0, uncal, cfg) == 9,
        "an uncalibrated ship holds its hover level rather than guessing")

    -- The fuel gate is a time budget, because the engine burns at a flat rate
    -- whatever the propellers are doing.
    local legA = flight.legTime(1200, 0, 0, calShip, cfg)
    local legB = flight.legTime(1200, 180, 0, calShip, cfg)
    check(legB > legA, "a leg that has to turn first takes longer")
    check(flight.legTime(1200, 0, 300, calShip, cfg) > legA, "and so does one that has to climb")
    near(flight.legTime(0, 0, 0, calShip, cfg), 12 / 4.0, "a leg of no distance is still a stop")

    near(flight.stressNeeded("tank", calShip), 2400, "a turn costs what the turn was measured at")
    near(flight.stressNeeded("cruise", calShip), 3600, "and cruise what cruise was measured at")
    near(flight.stressNeeded("brake", calShip), 3600, "braking is the worse of the two")
    near(flight.stressNeeded("arrived", calShip), 0, "and arriving costs nothing")

    -- The phase machine. Both conditions are tested before cruise is committed
    -- to, which is the deliberate difference from the two reference autopilots.
    local phase, reason = flight.phaseNext("tank",
        { err = 40, yawRate = 20, d = 200, v = 0, alignedFor = 0 }, cfg, calShip)
    check(phase == "tank", "a big error stays in the turn")
    check(reason:find("deg to turn") ~= nil, "and says how far there is to go")

    phase = flight.phaseNext("tank",
        { err = 1, yawRate = 8, d = 200, v = 0, alignedFor = 99 }, cfg, calShip)
    check(phase == "tank", "lined up but still swinging does not commit")

    phase = flight.phaseNext("tank",
        { err = 1, yawRate = 0.5, d = 200, v = 0, alignedFor = 0.5 }, cfg, calShip)
    check(phase == "tank", "steady but not held long enough does not commit either")

    phase, reason = flight.phaseNext("tank",
        { err = 1, yawRate = 0.5, d = 200, v = 0, alignedFor = 3 }, cfg, calShip)
    check(phase == "cruise", "lined up, steady and held is what commits")
    check(reason:find("steady") ~= nil, "and says so")

    phase = flight.phaseNext("cruise",
        { err = 40, yawRate = 0, d = 200, v = 5, alignedFor = 0 }, cfg, calShip)
    check(phase == "tank", "an error past tankReentry drops back to the turn")

    phase, reason = flight.phaseNext("cruise",
        { err = 0, yawRate = 0, d = 4, v = 12, alignedFor = 0 }, cfg, calShip)
    check(phase == "brake", "too fast for what is left starts the stop")
    check(reason:find("m/s") ~= nil, "and says how fast with how far")

    phase = flight.phaseNext("cruise",
        { err = 0, yawRate = 0, d = 4000, v = 12, alignedFor = 0 }, cfg, calShip)
    check(phase == "cruise", "and a long way out it simply runs")

    phase = flight.phaseNext("brake",
        { err = 0, yawRate = 0, d = 30, v = 4, alignedFor = 0, stopped = false }, cfg, calShip)
    check(phase == "brake", "still moving, still stopping")

    phase = flight.phaseNext("brake",
        { err = 0, yawRate = 0, d = 0.5, v = 0, lateral = 0.2, stopped = true }, cfg, calShip)
    check(phase == "arrived", "stopped and close enough is the end of the leg")

    phase, reason = flight.phaseNext("brake",
        { err = 0, yawRate = 0, d = 8, v = 0, lateral = 7, stopped = true }, cfg, calShip)
    check(phase == "tank", "stopped well off the line turns onto the point")
    check(reason:find("off the line") ~= nil, "and says that is why")

    phase, reason = flight.phaseNext("brake",
        { err = 0, yawRate = 0, d = 8, v = 0, lateral = 0.1, stopped = true }, cfg, calShip)
    check(phase == "tank", "stopped short but on the line simply goes again")
    check(reason:find("short") ~= nil, "and says that instead, in different words")

    print(string.format("%d passed, %d failed", passed, failed))
    return failed == 0
end

return tests
