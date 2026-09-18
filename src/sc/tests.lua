-- tests.lua -- `starcatcher --test`.
--
-- Everything checked here is pure: quaternions, the flight maths, curve lookup,
-- config coercion, calibration file parsing, and what the fuel relay's numbers
-- mean.
-- No ship, no peripherals, no modem. If this passes on a bare computer, the
-- maths that flies the ship is sound and anything still wrong is wiring.

local util, config, cal, fuel, turbine, ship, flight, preflight, popup, link = ...

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

    -- == names ==
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

    -- == the calibration file ==
    -- Every field is allowed to be missing and none of them may be guessed at,
    -- so what is tested is that junk is refused rather than rounded off.
    local sides = cal.parseSides({
        a = { side = "left" },
        b = { side = "right", reverse = true },
        c = { side = "sideways" },
        d = "junk",
    })
    check(sides.a and sides.a.side == "left", "a side loads")
    check(sides.a.reverse == false, "an entry with no reverse flag still loads")
    check(sides.b.reverse == true, "and the flag round trips")
    check(sides.c == nil, "a side that is not a side is dropped")
    check(sides.d == nil, "a line that is not a table is dropped")
    check(next(cal.parseSides(nil)) == nil, "no file means no sides")

    local pair = cal.parsePair({
        pos = { { rpm = 128, speed = 6 }, { rpm = 64, speed = 3 } },
        neg = {},
    })
    check(pair and #pair.pos == 2, "a ladder loads")
    check(pair.pos[1].rpm == 64, "and comes back sorted")
    check(pair.neg == nil, "an empty direction is dropped")
    check(cal.parsePair({ pos = {}, neg = {} }) == nil, "an empty pair is no pair at all")

    local brake = cal.parseBrake({
        main = { { rpm = 256, speed = 3, pitch = 6.4 }, { rpm = -128, speed = -1.5 } },
        all = "junk",
    })
    check(brake and #brake.main == 2, "a brake ladder loads")
    check(brake.main[1].rpm == 128 and brake.main[1].speed == 1.5,
        "a rung written negative is read as a magnitude")
    check(brake.main[2].pitch == 6.4, "the pitch util does not know about survives")
    check(brake.main[1].pitch == nil, "and a rung without one keeps nil")
    check(brake.all == nil, "a ladder that is not a table is dropped")

    -- The balloon ladder crosses zero, so it must not be folded onto itself the
    -- way the magnitude ladders are.
    local balloon = cal.parseBalloon({
        { rpm = 8, speed = 0.12 }, { rpm = 0, speed = -1.78 }, { rpm = 15, speed = 1.78 },
    })
    check(balloon and #balloon == 3, "the balloon ladder loads")
    check(balloon[1].rpm == 0 and balloon[1].speed < 0, "sinking stays negative")
    check(cal.parseBalloon({}) == nil, "an empty balloon ladder is nil")

    -- == the wizard, without a ship ==
    config.values = config.defaults()
    local ladder = cal.rpmLadder()
    check(#ladder == config.get("calSteps"), "the ladder has as many rungs as asked for")
    check(ladder[1] == config.get("calStartRpm"), "and starts where it was told to")
    check(ladder[#ladder] == config.get("calEndRpm"), "and ends where it was told to")
    for _, stage in ipairs(cal.STAGES) do
        check(cal.stageById(stage.id) == stage, stage.id .. " is reachable by name")
    end
    check(cal.stageById("axes") == nil, "a stage that does not exist is not invented")
    check(#cal.summary() == #cal.STAGES, "the screen gets a row for every stage")
    for _, row in ipairs(cal.summary()) do
        check(row.done == false, "an unmeasured stage does not claim to be done")
    end

    -- == the inventory ==
    -- The checker compares the ship on the network against the one that was
    -- measured, so what it must never do is pass a ship with a part missing.
    cal.inventory = nil
    check(select(1, cal.inventoryCheck()) == false, "a ship never measured does not pass")
    cal.inventory = {
        relays = { { id = 2, lines = 4 }, { id = 3, lines = 1 } },
        sides = { left = 2, right = 2, main = 1 },
        total = 5,
    }
    local invOk, invItems = cal.inventoryCheck()
    check(invOk == false, "a ship with no lines on the network fails against a measured one")
    local named = false
    for _, item in ipairs(invItems) do
        if item.text:find("relay #2") then named = true end
    end
    check(named, "and the relay that is missing is named")
    cal.inventory = nil

    -- == the sides, swapped ==
    -- The yaw stage offers this when the hull turns the other way to the one it
    -- was asked for, which is the sides filed backwards and nothing else.
    local savedSides, savedAuth = cal.sides, cal.yawAuth
    cal.sides = {
        l = { side = "left", reverse = true }, r = { side = "right" },
        m = { side = "main" }, off = { side = "none" },
    }
    cal.yawAuth = { left = 0.02, right = 0.08 }
    local moved = cal.swapSides()
    check(moved == 2, "only the two sides count as swapped")
    check(cal.sides.l.side == "right" and cal.sides.r.side == "left",
        "left and right change places")
    check(cal.sides.l.reverse == true, "and a line mounted backwards stays backwards")
    check(cal.sides.m.side == "main" and cal.sides.off.side == "none",
        "the main and an idle line are left where they are")
    near(cal.yawAuth.left, 0.08, "the authority travels with the side")
    near(cal.yawAuth.right, 0.02, "both ways")
    cal.sides, cal.yawAuth = savedSides, savedAuth

    -- == a yaw rate the engine has stopped reporting ==
    -- getAngularVelocity is the last figure the physics engine published, and a
    -- hull creeping round slowly enough is close enough to still for it to stop
    -- publishing: the reading drops to zero on a ship that never stopped
    -- turning. Below yawAsleep the heading is differentiated instead.
    config.values = config.defaults()
    local savedSublevel = sublevel
    local reportedY = -math.rad(12)
    sublevel = { getAngularVelocity = function() return { x = 0, y = reportedY, z = 0 } end }

    near(ship.yawRate(), 12, "a reported rate comes back in degrees, sign flipped")

    -- Two headings a second apart, the second one further round: a turn to the
    -- ship's own right, which is yaw rising, same as the reported one.
    local now = os.clock()
    reportedY = 0
    ship.yawTrail = { { t = now - 1, yaw = 10 }, { t = now, yaw = 13 } }
    near(ship.yawRate(), 3, "a reported zero falls back on the heading")

    ship.yawTrail = { { t = now - 1, yaw = 13 }, { t = now, yaw = 10 } }
    near(ship.yawRate(), -3, "and the fallback turns the other way when the hull does")

    -- Past the end of the circle, which is the one way differentiating a
    -- heading can hand back the wrong sign.
    ship.yawTrail = { { t = now - 1, yaw = 179 }, { t = now, yaw = -179 } }
    near(ship.yawRate(), 2, "a heading that wraps past 180 is still a small turn")

    -- A ship that really is holding still has nothing to fall back on to.
    ship.yawTrail = { { t = now - 1, yaw = 10 }, { t = now, yaw = 10 } }
    near(ship.yawRate(), 0, "a hull that is actually still reads zero")

    -- Two readings taken in the same instant are noise over nothing.
    ship.yawTrail = { { t = now, yaw = 10 }, { t = now, yaw = 13 } }
    near(ship.yawRate(), 0, "two headings from the same moment are not a rate")

    -- And the window is not allowed to stretch: too long a span can have turned
    -- past half a circle between its two ends.
    ship.yawTrail = { { t = now - 30, yaw = 10 }, { t = now, yaw = 13 } }
    near(ship.yawRate(), 0, "a stale pair of headings is not a rate either")

    ship.yawTrail = {}
    ship.noteYaw(10)
    ship.noteYaw(nil)
    ship.noteYaw(13)
    check(#ship.yawTrail == 2, "a heading that is not a number is not written down")
    check(ship.yawTrail[#ship.yawTrail].yaw == 13, "and the newest one is kept")
    ship.yawTrail = {}
    sublevel = savedSublevel

    -- == mixing ==
    -- The mixer is the one place a side becomes an RPM. What matters is that a
    -- differential pushes the two sides opposite ways, that a line mounted
    -- backwards is negated on top of that, and that the main is never part of
    -- a turn.
    config.values = config.defaults()
    local mixCal = {
        sides = {
            l = { side = "left" }, r = { side = "right" },
            m = { side = "main" }, rev = { side = "left", reverse = true },
        },
        yawAuth = { left = 0.06, right = 0.06 },
    }
    local lines = { "l", "r", "m", "rev" }
    local out = flight.mix(0, 128, lines, mixCal, config.values)
    check(out.l > 0 and out.r < 0, "a differential drives the two sides opposite ways")
    check(out.m == 0, "and leaves the main out of it")
    check(out.rev < 0, "a line mounted backwards is negated on top of its side")

    out = flight.mix(200, 0, lines, mixCal, config.values)
    check(out.l == out.r and out.l > 0, "plain thrust drives both sides the same")
    check(out.m > 0, "and the main with them")

    -- Graduated braking is the reason the main and the turbines are given their
    -- thrust separately. A plan that reverses the main alone has to arrive at
    -- the propellers as the main alone, which a single common number cannot say.
    out = flight.mixParts(-200, 0, 0, lines, mixCal, config.values)
    check(out.m < 0, "the main alone reverses")
    check(out.l == 0 and out.r == 0, "and the turbines stay out of it")

    -- The two sides of a hand built hull are never the same distance out, so
    -- equal torque needs the stronger side held back.
    local scaleL, scaleR = flight.sideScales(0.04, 0.08)
    near(scaleL, 1, "the weaker side runs at full")
    near(scaleR, 0.5, "and the stronger is halved to match")
    scaleL, scaleR = flight.sideScales(nil, 0.08)
    check(scaleL == 1 and scaleR == 1, "an unmeasured side is not scaled at all")

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

    -- Roll is read off the body +X axis, so a hull rolled a quarter turn about
    -- its own forward axis puts that axis straight down.
    local rollQ = { x = 0, y = 0, z = math.sqrt(0.5), w = math.sqrt(0.5) }
    near(math.abs(util.rollOf(rollQ)), 90, "a quarter turn about forward is 90 degrees of roll", 1e-3)
    near(util.rollOf({ x = 0, y = 0, z = 0, w = 1 }), 0, "and level is no roll")

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

    -- What the vents report is the balloon as it is rather than as it was
    -- asked for, and a ship with two of them fails at one of them.
    turbine.accept(3, relayLines(3, { "Create_RotationSpeedController_0" }, {
        hasBalloon = true, balloon = 7,
        balloonInfo = { lift = 900, filled = 600, target = 640, change = -2.5,
                        height = 6, capacity = 1200 },
        vents = {
            { name = "3:Create_SteamVent_0", short = "#3 vent 0", gas = "steam",
              output = 0.8, signal = 7, efficiency = 1.0, active = true, hasBalloon = true },
            { name = "3:Create_SteamVent_1", short = "#3 vent 1", gas = "steam",
              output = 0, signal = 7, efficiency = 0.4, active = true, hasBalloon = true },
        },
    }))
    local vented = turbine.status()
    check(vented.balloonInfo and vented.balloonInfo.lift == 900,
        "the balloon's own lift reaches the flight computer")
    check(vented.vents and #vented.vents == 2, "both vents arrive, separately")

    local coldBoiler, losing = false, false
    for _, item in ipairs(turbine.advice(vented)) do
        if item.text:find("vent 1") and item.text:find("40") then coldBoiler = true end
        if item.text:find("losing") then losing = true end
    end
    check(coldBoiler, "a vent at 40 percent boiler heat is named, and named on its own")
    check(losing, "a balloon losing volume is said before the altitude says it")

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
    -- Positive error means the target is off to the right, and the way a tank
    -- hull turns right is by pushing harder on its left.
    check(demand.left > 0 and demand.right < 0, "a right hand error pushes the left side")
    check(demand.main == 0, "and the main stays out of a tank turn")
    near(demand.rate, 30, "the wanted rate is capped at yawRateMax")

    pid:reset()
    demand = flight.tankDemand(-20, pid, calShip, cfg, 0.2)
    check(demand.left < 0 and demand.right > 0, "and the other way round the other way")

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
    check(mixed.ta > 0 and mixed.tc < 0, "a positive differential pushes the left side")
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


    -- == preflight ==
    --
    -- The checker never touches a peripheral, so the whole of it runs against
    -- tables that say what a ship would have said. Each stub below is a ship in
    -- one particular state, and what is checked is that the failure is named
    -- correctly, not merely counted. This runs on a bare computer in the world
    -- as `starcatcher --test`, which is where it gets run now.

    local function fakeShip(hasPose)
        return {
            order = { "2:a", "2:b", "3:c" },
            remoteLines = {},
            readState = function()
                if not hasPose then return nil, "NOT ON A SUB-LEVEL" end
                return {
                    position = { x = 0, y = 100, z = 0 },
                    orientation = { x = 0, y = 0, z = 0, w = 1 },
                    velocity = { x = 0, y = 0, z = 0 },
                    yaw = 0, speed = 0, bx = 0, by = 0, bz = 0,
                }
            end,
        }
    end

    local function fakeCal(opts)
        opts = opts or {}
        return {
            sides = {},
            noseOffset = 0,
            yawCurve = { pos = { { rpm = 256, speed = 30 } } },
            fwdCurve = { pos = { { rpm = 256, speed = 12 } } },
            brakeCurve = { main = { { rpm = 256, speed = 3 } } },
            balloonCurve = { { rpm = 15, speed = 1.8 } },
            stressAtTurn = opts.stressAtTurn or 1000,
            stressAtCruise = opts.stressAtCruise or 1000,
            linesOfSide = function(side)
                if side == "left" then return opts.left or { "2:a" } end
                if side == "right" then return opts.right or { "2:b" } end
                return opts.main or { "3:c" }
            end,
            inventoryCheck = function()
                if opts.inventory == false then
                    return false, { { kind = "bad",
                        text = "relay #2 had 4 line(s) when the ship was measured and has 2 now" } }
                end
                return true, {}
            end,
            summary = function()
                if opts.unmeasured then
                    return { { title = "SIDES", done = true }, { title = "YAW", done = false } }
                end
                return { { title = "SIDES", done = true }, { title = "YAW", done = true } }
            end,
            topForward = function() return 12 end,
        }
    end

    local function fakeFuel(link, fraction, endurance)
        return { status = function()
            return { link = link, fraction = fraction, endurance = endurance }
        end }
    end

    local function fakeTurbines(opts)
        opts = opts or {}
        return {
            status = function()
                return {
                    link = opts.link or "live",
                    relays = opts.relays or { { relayId = 2, link = "live", lines = {} } },
                    stressOk = opts.stressOk ~= false,
                    capacity = opts.capacity or 8192,
                    stress = opts.stress or 900,
                }
            end,
            hasBalloon = function() return opts.balloon ~= false end,
        }
    end

    local fakeConfig = {
        get = function(key)
            if key == "fuelCrit" then return 12 end
            return nil
        end,
        values = { cruiseSpeed = 12, yawRateMax = 30, fuelMargin = 1.25,
            requireStressBudget = true, brakeMargin = 3.0, brakeRpmMax = 256 },
    }

    local whole = function() return preflight.check(fakeShip(true), fakeCal(),
        fakeFuel("live", 0.5, 3600), fakeTurbines(), fakeConfig) end

    local report = whole()
    check(report.ok, "a whole ship passes the gate")
    check(report.byId.steer.ok, "with a side each way it can steer")
    check(report.byId.balloon.ok, "and something is holding the balloon")
    check(#preflight.failures(report) == 0, "and there is nothing to report")

    report = preflight.check(fakeShip(false), fakeCal(), fakeFuel("live", 0.5, 3600),
        fakeTurbines(), fakeConfig)
    check(not report.ok, "no pose is a refusal")
    check(report.byId.sable.text:find("SUB%-LEVEL") ~= nil,
        "and it is refused in CC: Sable's own words")
    check(report.byId.sable.cost ~= nil, "a failure always says what it would cost")

    report = preflight.check(fakeShip(true), fakeCal({ right = {} }),
        fakeFuel("live", 0.5, 3600), fakeTurbines(), fakeConfig)
    check(not report.ok, "a missing side is a refusal")
    check(report.byId.steer.text:find("0 on the right") ~= nil, "and it says which side")
    check(report.byId.cruise.ok, "but there is still something pushing forward")

    report = preflight.check(fakeShip(true), fakeCal(), fakeFuel("live", 0.5, 3600),
        fakeTurbines({ balloon = false }), fakeConfig)
    check(not report.ok, "nothing holding the balloon is a refusal")

    report = preflight.check(fakeShip(true), fakeCal(), fakeFuel("live", 0.5, 3600),
        fakeTurbines({ relays = { { relayId = 2, link = "stale", lines = {} } } }), fakeConfig)
    check(not report.ok, "a relay that stopped answering is a refusal")
    check(report.byId.relays.text:find("#2") ~= nil, "and it is named by number")

    report = preflight.check(fakeShip(true), fakeCal(), fakeFuel("live", 0.04, 3600),
        fakeTurbines(), fakeConfig)
    check(not report.ok, "four percent of fuel is a refusal, not a warning")

    report = preflight.check(fakeShip(true), fakeCal(), fakeFuel("waiting"),
        fakeTurbines(), fakeConfig)
    check(report.ok, "but a fuel relay that has not spoken only warns")
    check(not report.byId.fuel.ok, "and it still says so")

    report = preflight.check(fakeShip(true), fakeCal({ inventory = false }),
        fakeFuel("live", 0.5, 3600), fakeTurbines(), fakeConfig)
    check(not report.ok, "a ship that is not the measured one is a refusal")
    check(report.byId.inventory.text:find("has 2 now") ~= nil,
        "in the words cal.inventoryCheck already wrote")

    report = preflight.check(fakeShip(true), fakeCal({ unmeasured = true }),
        fakeFuel("live", 0.5, 3600), fakeTurbines(), fakeConfig)
    check(not report.ok, "an unmeasured stage is a refusal")
    check(report.byId.curves.text:find("yaw") ~= nil, "and it names the stage")

    check(preflight.failures(whole()) ~= nil, "failures always returns a list")
    local ranked = preflight.failures(preflight.check(fakeShip(true),
        fakeCal({ right = {} }), fakeFuel("waiting"), fakeTurbines(), fakeConfig))
    check(ranked[1].kind == "bad", "and it puts the refusals above the warnings")

    -- == the leg ==

    local fit = whole()
    local plan = { dist = 500, headingChange = 90, altChange = 0,
        cal = fakeCal(), cfg = fakeConfig.values }

    local leg = preflight.forLeg(fit, { endurance = 3600 },
        { stressOk = true, capacity = 8192, stress = 900 }, plan)
    check(leg.ok, "an hour of fuel covers a five hundred block leg")
    check(leg.seconds > 0, "and the leg has a length in seconds")

    leg = preflight.forLeg(fit, { endurance = 5 },
        { stressOk = true, capacity = 8192, stress = 900 }, plan)
    check(not leg.ok, "five seconds of fuel does not")
    check(leg.byId.fuelTime.cost:find("short") ~= nil, "and it says how far short")

    leg = preflight.forLeg(fit, { endurance = 3600 },
        { stressOk = true, capacity = 100, stress = 90 }, plan)
    check(not leg.ok, "a network that cannot carry the turn is a refusal")

    leg = preflight.forLeg(fit, { endurance = 3600 }, nil, plan)
    check(leg.ok, "no stressometer is a warning rather than a refusal")

    plan.cfg = { cruiseSpeed = 12, yawRateMax = 30, fuelMargin = 1.25,
        requireStressBudget = false, brakeMargin = 3.0, brakeRpmMax = 256 }
    leg = preflight.forLeg(fit, { endurance = 3600 },
        { stressOk = true, capacity = 100, stress = 90 }, plan)
    check(leg.ok, "and so is the captain turning the budget off")

    -- == popups ==
    --
    -- What is checked is the sentence, because the sentence is the whole reason
    -- this module is separate from the drawing.

    local function joined(list)
        local out = ""
        for _, item in ipairs(list or {}) do out = out .. " " .. item.text end
        return out
    end

    local failing = preflight.check(fakeShip(true), fakeCal({ right = {} }),
        fakeFuel("live", 0.5, 3600), fakeTurbines(), fakeConfig)
    local modal = popup.preflight(failing, "fly")
    check(modal.severity == "alarm", "a refusal is loud")
    check(modal.title:find("FLY") ~= nil, "and says what it is refusing")
    check(#modal.lines > 0, "it lists what is wrong")
    check(#modal.cost > 0, "and what each one would cost")
    local actions = {}
    for _, choice in ipairs(modal.choices) do actions[choice.action] = choice.key end
    check(actions.override ~= nil and actions.cancel ~= nil,
        "every refusal can be overridden or cancelled")

    modal = popup.partLost("relay #2 stopped answering", "it was holding the balloon")
    check(modal.severity == "alarm", "a part lost in the air is the loud one")
    check(modal.lines[1].text:find("#2") ~= nil, "and it names the part")
    check(joined(modal.cost):find("balloon") ~= nil, "it says the balloon is being held")
    check(joined(modal.cost):find("zero") ~= nil, "and that thrust is already at zero")

    modal = popup.fuelShortfall(120, 1400)
    check(modal.title:find("FUEL") ~= nil, "the fuel popup is about fuel")
    check(joined(modal.cost):find("short") ~= nil, "and quotes the shortfall")

    modal = popup.altitudeChange(100, 60)
    check(modal.title == "DESCENT", "going down is called a descent")
    modal = popup.altitudeChange(100, 160)
    check(modal.title == "CLIMB", "and going up a climb")
    check(#modal.choices == 3, "and it offers change, keep or cancel")

    modal = popup.overstressed({ overstressed = true, fraction = 1, worstRelay = 3 })
    check(modal.lines[1].text:find("stopped") ~= nil, "an overstressed network has stopped")
    check(modal.lines[2].text:find("#3") ~= nil, "and the worst relay is named")

    modal = popup.pitch(-19, 12)
    check(modal.lines[1].text:find("19") ~= nil, "the pitch popup quotes the angle")

    -- Every popup in the program offers a way out, because one that does not is
    -- a modal a pilot cannot dismiss while the ship is in the air.
    for _, built in ipairs({
        popup.preflight(failing, "fly"),
        popup.manualOverride(failing),
        popup.fuelShortfall(10, 100),
        popup.altitudeChange(100, 60),
        popup.overstressed({ fraction = 0.99 }),
        popup.pitch(-19, 12),
        popup.partLost("something", nil),
    }) do
        check(#built.choices > 0, built.title .. " offers at least one way out")
        check(built.title ~= nil and #built.title > 0, built.title .. " has a title")
    end

    -- == the tuning surface ==
    --
    -- Stage 7 retired the flight envelope the omni hull flew by. These are the
    -- keys, by name, because a key that comes back because something still reads
    -- it would otherwise come back silently.
    for _, gone in ipairs({ "climbSpeed", "holdAlt", "slowRadius", "posKp", "posKi",
                            "posKd", "useCurves", "stationKeep", "velSteps" }) do
        check(config.byKey[gone] == nil, gone .. " is retired and stays retired")
    end
    check(config.byKey.cruiseSpeed ~= nil and config.byKey.cruiseSpeed.group == "cruise",
        "cruiseSpeed moved to the group that describes the run")
    for _, group in ipairs(config.GROUPS) do
        check(#config.keysIn(group.id) > 0, "the " .. group.id .. " group has settings in it")
    end
    local groupIds = {}
    for _, group in ipairs(config.GROUPS) do groupIds[group.id] = true end
    for _, entry in ipairs(config.SCHEMA) do
        check(groupIds[entry.group] == true, entry.key .. " is in a group the TUNE tab draws")
        check(type(entry.help) == "string" and #entry.help > 0, entry.key .. " says what it does")
        check(type(entry.symptom) == "string" and #entry.symptom > 0,
            entry.key .. " says what the ship is doing when you reach for it")
    end

    -- == what a setting means on this ship ==
    --
    -- The preview is the part of the TUNE tab that turns a number into a
    -- decision, and the thing worth testing is that it refuses to invent one.
    local previewCal = {
        fwdCurve = { pos = { { rpm = 64, speed = 4 }, { rpm = 256, speed = 16 } } },
        yawCurve = { pos = { { rpm = 64, speed = 5 }, { rpm = 256, speed = 20 } } },
        brakeCurve = { all = { { rpm = 128, speed = 3, pitch = 4 },
                               { rpm = 256, speed = 6, pitch = 20 } } },
        balloonCurve = { { rpm = 0, speed = -2 }, { rpm = 8, speed = 0 },
                         { rpm = 15, speed = 2 } },
    }
    local previewCfg = { cruiseSpeed = 12, pitchLimit = 12, brakeMargin = 3.0 }

    check(flight.preview("cruiseMaxRpm", 256, previewCal, previewCfg):find("16.0 m/s") ~= nil,
        "the top of the throttle is quoted as the speed it was measured doing")
    check(flight.preview("cruiseMaxRpm", 256, {}, previewCfg) == nil,
        "and says nothing at all on a ship that has never been measured")
    check(flight.preview("tankRpmMax", 256, previewCal, previewCfg):find("20.0 deg/s") ~= nil,
        "a differential is quoted as the turn it produced")
    check(flight.preview("cruiseSpeed", 99, previewCal, previewCfg):find("more than") ~= nil,
        "asking for more than the ship has done is answered in its own words")
    check(flight.preview("cruiseSpeed", 99, previewCal, previewCfg):find("16.0") ~= nil,
        "and that answer quotes what it has actually done")
    check(flight.preview("pitchLimit", 12, previewCal, previewCfg):find("3.0") ~= nil,
        "a tighter pitch limit leaves only the rungs that stayed inside it")
    check(flight.preview("pitchLimit", 30, previewCal, previewCfg):find("6.0") ~= nil,
        "and a looser one lets the harder rung back in")
    check(flight.preview("balloonFloor", 0, previewCal, previewCfg):find("sinking") ~= nil,
        "a floor of zero is quoted as the sink it was measured doing")
    check(flight.preview("arriveDist", 1, previewCal, previewCfg) == nil,
        "a setting with nothing measured behind it previews nothing")

    near(flight.climbAtLevel(previewCal.balloonCurve, 4), -1.0, "the balloon ladder reads between rungs")
    near(flight.climbAtLevel(previewCal.balloonCurve, 8), 0.0, "and exactly on one")
    check(flight.climbAtLevel(nil, 8) == nil, "and refuses an unmeasured ladder")

    -- == the setting popup ==
    local entry = config.byKey.cruiseMaxRpm
    modal = popup.setting(entry, "256", "this ship ran 16.0 m/s at 256 rpm", "12")
    check(joined(modal.lines):find(entry.symptom, 1, true) ~= nil,
        "the editor says what the ship is doing when you reach for the setting")
    check(joined(modal.cost):find("16.0 m/s") ~= nil, "and what the value means on this hull")
    check(joined(modal.cost):find("typing: 12") ~= nil,
        "a half typed value is shown rather than applied")

    modal = popup.measured({ id = "altHover", title = "hover level", stage = "balloon",
        unit = "strength", help = "what holds this ship up" }, 7)
    check(joined(modal.cost):find("overwrites") ~= nil,
        "editing a measured value says the stage will overwrite it")
    modal = popup.measured({ id = "altHover", title = "hover level", stage = "balloon",
        unit = "strength", help = "what holds this ship up" }, nil)
    check(joined(modal.lines):find("balloon stage") ~= nil,
        "and an unmeasured one names the stage that would measure it")

    modal = popup.report(whole())
    check(modal.title:find("READY") ~= nil and modal.title:find("NOT") == nil,
        "a ship that passes every check is told so plainly")
    modal = popup.report(failing)
    check(modal.title:find("NOT READY") ~= nil, "and one that does not is not")
    check(#modal.choices > 0, "the checklist can be closed")

    -- == the measured values, by hand ==
    check(#cal.MEASURED > 0, "the measured values are listed somewhere the screen can read")
    for _, measured in ipairs(cal.MEASURED) do
        check(type(measured.stage) == "string" and cal.stageById(measured.stage) ~= nil,
            measured.id .. " names the stage that measures it")
        check(type(measured.help) == "string" and #measured.help > 0,
            measured.id .. " says what it is")
    end
    cal.altHover = nil
    check(cal.measured("altHover") == nil, "an unmeasured value reads as missing")
    check(select(2, cal.measured("altHover")) == "balloon",
        "and says which stage would have measured it")
    cal.setMeasured("altHover", "7")
    check(cal.altHover == 7, "a hand edited measurement lands where the controller reads it")
    check(select(2, cal.setMeasured("altHover", "nonsense")) ~= nil, "and junk is refused")

    -- == the passcode ==
    --
    -- The envelope, not the secrecy. There is no secrecy: the comment at the
    -- top of link.lua says so, and what is checked here is that an unpaired
    -- computer obeys everything, a paired one obeys only its own ship, and that
    -- the two ways of failing get two different sentences.
    link.pass, link.refused, link.refusedFrom = nil, 0, nil
    check(link.check(7, { cmd = "set" }) == true, "an unpaired computer obeys anything")
    check(link.stamp({ cmd = "set" }).pass == nil,
        "and stamps nothing, so a paired relay refuses it as unstamped")
    check(link.status().paired == false, "and says out loud that it is unpaired")

    check(select(2, link.valid("ab")) ~= nil, "a passcode of two characters is refused")
    check(select(2, link.valid("two words")) ~= nil, "and one with a space in it")
    check(select(2, link.valid(string.rep("x", 25))) ~= nil, "and one nobody could retype")
    check(link.valid("starcatcher-1") == true, "letters, digits and dashes are a passcode")

    link.pass = "skyline"
    check(link.stamp({ cmd = "set" }).pass == "skyline", "a paired computer stamps every message")
    check(link.check(7, { cmd = "set", pass = "skyline" }) == true, "and obeys its own ship")

    local ok, why = link.check(7, { cmd = "set" })
    check(ok == false and why:find("no passcode at all") ~= nil,
        "an unstamped message is refused as unstamped")
    ok, why = link.check(9, { cmd = "set", pass = "other" })
    check(ok == false and why:find("different passcode") ~= nil,
        "and a wrong one as a different passcode, which is a different fix")
    check(link.status().refused == 2, "refusals are counted")
    check(link.status().refusedFrom == 9, "and the last sender is named")

    -- The checker's two answers about pairing, which are not the same answer.
    -- Unpaired is a ship that has not been round the installer yet. Refusing is
    -- a relay that looks alive and will not take an order.
    link.pass, link.refused, link.refusedFrom = nil, 0, nil
    local unpaired = preflight.check(fakeShip(true), fakeCal(), fakeFuel("live", 0.5, 3600),
        fakeTurbines(), fakeConfig, link)
    check(unpaired.byId.passcode.ok == false, "an unpaired ship is told so")
    check(unpaired.byId.passcode.kind == "warn", "and it is a warning, because the ship still flies")
    check(unpaired.ok == true, "so the gate lets it fly")

    link.pass = "skyline"
    link.check(4, { cmd = "set", pass = "somebody else" })
    local mismatched = preflight.check(fakeShip(true), fakeCal(), fakeFuel("live", 0.5, 3600),
        fakeTurbines(), fakeConfig, link)
    check(mismatched.byId.passcode.ok == false, "a refused message is a failing check")
    check(mismatched.ok == false, "and this one does stop the gate")
    check(mismatched.byId.passcode.text:find("#4") ~= nil, "naming the computer that sent it")
    link.pass, link.refused, link.refusedFrom = nil, 0, nil

    -- == answering a ping ==
    --
    -- The rule, without the radio. What matters is that a ping is answered only
    -- when the passcode agrees, that the answer names the role the answering
    -- computer believes it has, and that nothing else on the protocol is
    -- treated as a ping. This is the half of the pairing exchange that can be
    -- checked on a computer with no modem.
    link.pass, link.refused, link.answered, link.peers = "skyline", 0, 0, nil
    local reply = link.answer("turbine", 0, { kind = "ping", pass = "skyline" })
    check(reply ~= nil and reply.kind == "here", "a ping with the right passcode is answered")
    check(reply.role == "turbine", "and the answer says what this computer believes it is")
    check(reply.pass == "skyline", "and carries the passcode itself, so the asker can refuse it")
    check(link.peers and link.peers.command == 0, "who asked is written down")

    local refusedReply, refusedWhy = link.answer("turbine", 9, { kind = "ping", pass = "other" })
    check(refusedReply == nil and refusedWhy ~= nil, "a ping with a different passcode is not answered")
    check(link.answer("turbine", 0, { cmd = "set" }) == nil,
        "and an order on the pairing protocol is not a ping")
    check(link.answered == 1, "only the answered ones are counted")

    -- An unpaired relay answers anything, which is the state every computer is
    -- in before the wizard has been round it and is what lets a half installed
    -- ship be found at all.
    link.pass, link.peers = nil, nil
    check(link.answer("fuel", 3, { kind = "ping" }) ~= nil, "an unpaired computer answers any ping")
    link.pass, link.refused, link.answered, link.peers = nil, 0, 0, nil

    print(string.format("%d passed, %d failed", passed, failed))
    return failed == 0
end

return tests
