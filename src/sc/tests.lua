-- tests.lua -- `starcatcher --test`.
--
-- Everything checked here is pure: quaternions, mixing, curve lookup, config
-- coercion, calibration file parsing, and what the fuel relay's numbers mean.
-- No ship, no peripherals, no modem. If this passes on a bare computer, the
-- maths that flies the ship is sound and anything still wrong is wiring.

local util, config, cal, fuel, turbine, ship = ...

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

    local function relayLines(names, extra)
        local list = {}
        for index, name in ipairs(names) do
            list[index] = { name = name, short = "#" .. name:match("%d+$"), demand = 0, actual = 0 }
        end
        local message = { v = 1, lines = list, maxRpm = 256,
                          stress = 6000, stressCapacity = 8000, stressFraction = 0.75,
                          stressOk = true, overstressed = false }
        for key, value in pairs(extra or {}) do message[key] = value end
        return message
    end

    check(turbine.accept(19, { v = 1, lines = {} }) == true, "a well formed message is taken")
    check(turbine.accept(19, { v = 2, lines = {} }) == false, "a future version is refused")
    check(turbine.accept(19, 42) == false, "junk on the protocol is refused")

    turbine.modem = "top"
    turbine.accept(19, relayLines({ "Create_RotationSpeedController_7",
                                    "Create_RotationSpeedController_8" }))
    check(#ship.order == 2, "the relay's lines are adopted as the ship's own")
    check(ship.lines["Create_RotationSpeedController_7"].remote == true,
        "and they are marked as living on a radio")
    check(cal ~= nil and ship.lines["Create_RotationSpeedController_7"].wrap == nil,
        "a remote line has no peripheral to wrap")

    -- Sending twice with the same number has to put it on the air twice, or the
    -- relay's deadman reads the silence as this computer having died.
    local outbox = {}
    ship.sendRemote = function(demands)
        local copy = {}
        for name, rpm in pairs(demands) do copy[name] = rpm end
        outbox[#outbox + 1] = copy
    end
    ship.flush({ ["Create_RotationSpeedController_7"] = 120 })
    ship.flush({ ["Create_RotationSpeedController_7"] = 120 })
    check(#outbox == 2, "an unchanged remote demand is sent again anyway")
    check(outbox[2]["Create_RotationSpeedController_7"] == 120, "and it is the right number")
    ship.sendRemote = nil

    local status = turbine.status()
    near(status.fraction, 0.75, "stress comes through as a fraction")
    near(status.headroom, 2000, "headroom is capacity less stress")
    check(status.link == "live", "a message just received is a live link")

    local warned = false
    for _, item in ipairs(turbine.advice(status)) do
        if item.kind == "warn" or item.kind == "bad" then warned = true end
    end
    check(warned, "75% stress is worth saying out loud")

    turbine.accept(19, relayLines({ "Create_RotationSpeedController_7",
                                    "Create_RotationSpeedController_8" },
                                  { overstressed = true }))
    local shouted = false
    for _, item in ipairs(turbine.advice(turbine.status())) do
        if item.kind == "bad" then shouted = true end
    end
    check(shouted, "overstress is advised as critical")

    -- A controller broken off the relay stops being named, and a line the mixer
    -- still believes in would have it dividing thrust between a propeller that
    -- is not there and one that is.
    turbine.accept(19, relayLines({ "Create_RotationSpeedController_7" }))
    check(#ship.order == 1 and ship.lines["Create_RotationSpeedController_8"] == nil,
        "a line the relay stops naming is dropped")

    turbine.modem = nil
    check(turbine.status().link == "nomodem", "no modem is a link state, not an error")

    print(string.format("%d passed, %d failed", passed, failed))
    return failed == 0
end

return tests
