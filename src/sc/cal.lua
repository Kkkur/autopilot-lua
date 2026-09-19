-- cal.lua -- the seven stage wizard, and the file it writes.
--
-- Calibration is how the program learns the ship. Nothing about this vessel is
-- written into the code: which propeller is on which side, how fast a
-- differential turns the hull, what a redstone strength does to the balloon and
-- how hard the thing can stop are all measured here and read back by
-- sc/flight.lua. The shape of what gets written down is described at the top of
-- that file, because that is the file that has to understand it.
--
-- Seven stages, in a fixed order, each confirmed before it runs and each
-- skippable, so redoing the brake ladder does not throw away the rest. The
-- order is not a preference. The movement stages need a held altitude to
-- measure against, so the balloon is learned before anything that moves
-- horizontally, and everything needs to know which line is on which side, so
-- sides is first.
--
--   sides    which line is left, right or main, which way it spins, how much
--            yaw each side is worth, and where the nose actually points
--   balloon  redstone strength against climb rate, and the strength that holds
--   yaw      differential RPM against yaw rate, and what a full turn costs
--   align    turns to each point of the compass and asks the pilot which way
--            the ship is really pointing, which is the one thing here that no
--            sensor on the network can answer
--   forward  common RPM against settled speed, and what full cruise costs
--   cruise   flies a leg and measures the course it made against the heading
--            it held, which is the nose offset measured properly
--   brake    reverse RPM against deceleration and worst pitch, main then all
--
-- A finished run also records the inventory it saw: which relays answered and
-- how many lines each had. That is what the preflight checker compares against,
-- which keeps the ship out of the code and still catches a missing part.
--
-- Everything here is allowed to be missing. A ship that has never been
-- calibrated still flies, badly, on the fallbacks in flight.lua, and an
-- uncalibrated ship saying so beats an uncalibrated ship pretending.
--
-- **No measurement here ends on a clock.** Every rung runs until the pilot
-- presses Enter, with the live number and whether it has stopped moving on the
-- screen the whole time. The wizard used to end a rung once the reading had
-- been steady for a few seconds, which sounds right and is not: a hull that
-- has not begun to move yet is perfectly steady at zero, so on a real ship
-- with turbines that take seconds to come up, every rung ended before the
-- ship had answered. A whole balloon sweep read no climb at any strength. The
-- pilot is standing there watching the ship, and is the only thing in the
-- room that can tell a settled reading from one that has not started.

local util, ship, config, log, flight, turbine, popup = ...

local cal = {}

cal.FILE = nil

cal.sides = {}        -- line name -> { side = "left"|"right"|"main"|"none", reverse }
cal.noseOffset = nil  -- degrees between the hull's +Z and where the main pushes
cal.frontOffset = nil -- degrees between the hull's +Z and the end the crew calls the front
cal.roseMirror = nil  -- 1, or -1 for a ship whose rose comes out east for west
cal.alignMissed = nil -- points of the rose the front came out not facing
cal.alignPoints = nil -- { { want, pose, ok }, ... }, the rose as the pilot answered it
cal.frontConfirmed = nil -- the pilot has looked at the ship and said the front is the front
cal.yawAuth = {}      -- { left, right }, deg/s per RPM
cal.yawCurve = nil    -- { pos, neg }, differential RPM against yaw rate
cal.fwdCurve = nil    -- { pos, neg }, common RPM against settled speed
cal.brakeCurve = nil  -- { main, all }, reverse RPM against deceleration, from forward motion
cal.brakeResponse = nil -- { pos, neg }, the same split by which way the ship was going
cal.fwdResponse = nil -- { pos = { tau, accel }, neg = ... }, how the speed gets there
cal.balloonCurve = nil
cal.altHover = nil
cal.yawAccel = nil     -- deg/s/s, how fast the hull gets into a turn and out of one
cal.stressAtTurn = nil
cal.stressAtCruise = nil
cal.inventory = nil   -- what the ship looked like when it was last measured
cal.meta = {}         -- when each stage was last run, for the screen

-- Which filing of the sides every curve below was measured through, and which
-- filing the ship is on now.
--
-- A ladder is not a property of the hull. It is a property of the hull *and* of
-- which line this program calls left, because the differential it wrote down
-- was put on the water by `flight.mix` reading `cal.sides`. Re-file the sides
-- the other way round and every rung in that ladder now describes a turn the
-- ship makes in the opposite direction, and nothing in the numbers says so:
-- `util.tidyCurve` keeps magnitudes, so a backwards ladder and a correct one
-- are the same file.
--
-- That cost a flight. The sides stage was re-run and came out the mirror of the
-- filing the last yaw ladder was measured through, the yaw stage then found
-- every rung already measured and resumed rather than turning the ship once,
-- and the wrong way check that exists precisely to catch this never got a rung
-- to look at. The align stage flew the ship away from every heading it was
-- sent to.
--
-- So the sides carry a revision, every curve records the revision it was
-- measured under, and a ladder from an older one is not resumable. It is not
-- thrown away either: it is still the best guess the ship has until something
-- better is measured, and the stage says out loud why it is starting again.
cal.sidesRev = 0
cal.curveRev = {}     -- { yaw = n, fwd = n, brake = n }

-- The order is the wizard's running order and the screen's row order, so there
-- is one list of them rather than two that can disagree.
cal.STAGES = {
    {
        id = "sides", title = "SIDES", meta = "sidesAt",
        what = "Spins each propeller on its own and reads which side of the hull it sits on.",
        room = "Off the ground, and a few blocks of drift in every direction. A propeller read against the ground is read against friction.",
    },
    {
        id = "balloon", title = "BALLOON", meta = "balloonAt",
        what = "Walks the redstone strength from nothing to full and writes down the climb rate at each.",
        room = "Clear air above and below. At strength 0 the ship sinks, and at 15 it climbs.",
    },
    {
        id = "yaw", title = "YAW", meta = "yawAt",
        what = "Drives one side against the other and writes down how fast the hull comes round.",
        room = "Off the ground, with room to spin on the spot both ways.",
    },
    {
        id = "align", title = "ALIGN", meta = "alignAt",
        what = "Turns to each of the eight points of the compass and asks you what the ship is really pointing at.",
        room = "Off the ground, with room to spin on the spot, and a view of the sky. You will be reading degrees off F3.",
    },
    {
        id = "forward", title = "FORWARD", meta = "forwardAt",
        what = "Runs the ship up at each throttle step and writes down the speed it settles at.",
        room = "Off the ground, with a long run ahead and behind. This is the stage that covers ground.",
    },
    {
        -- The title is the width of the CAL tab's column and no wider. What
        -- the stage does is the sentence under it.
        id = "cruise", title = "CRUISE", meta = "cruiseAt",
        what = "Flies a leg north and measures the course it actually made against the heading it held.",
        room = "Off the ground, with a long clear run to the north. The longer the leg the better the reading.",
    },
    {
        id = "brake", title = "BRAKING", meta = "brakeAt",
        what = "Runs up to speed and reverses, on the main alone and then on all five.",
        room = "Off the ground, with a long run ahead four times over and room to overshoot.",
    },
}

function cal.stageById(id)
    for _, stage in ipairs(cal.STAGES) do
        if stage.id == id then return stage end
    end
    return nil
end

-- == PERSISTENCE =============================================

function cal.init(dataDir)
    cal.FILE = fs.combine(dataDir, "cal.cfg")
    cal.load()
    return cal
end

-- Which side each line pushes from, keyed by the saved name.
--
-- Deliberately not filtered against what is on the network. At boot every line
-- on this ship is on a relay and none of them have adopted yet, so filtering
-- here threw away the whole calibration a second before the propellers arrived,
-- and nothing ever loaded it again. A line in the file that never turns up is
-- harmless: the mixer only ever iterates lines the ship actually has.
function cal.parseSides(data)
    local sides = {}
    if type(data) ~= "table" then return sides end
    local allowed = { left = true, right = true, main = true, none = true }
    for name, entry in pairs(data) do
        if type(name) == "string" and type(entry) == "table"
                and allowed[entry.side] then
            sides[name] = { side = entry.side, reverse = entry.reverse == true }
        end
    end
    return sides
end

-- The rose as the pilot answered it. Kept whole rather than reduced to the
-- flips it settled, because the eight answers are the evidence for them: a
-- pilot looking at the CAL tab and wondering why the front offset is what it
-- is can see which point the ship came out wrong on.
--
-- A file written before the stage asked yes or no carries `seen`, the heading
-- the pilot typed at that point. It reads back as an answer that agreed,
-- because a point the old stage kept is a point it was happy with.
function cal.parsePoints(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, entry in ipairs(data) do
        if type(entry) == "table" and tonumber(entry.pose) then
            out[#out + 1] = {
                want = tonumber(entry.want),
                pose = tonumber(entry.pose),
                ok = entry.ok ~= false,
            }
        end
    end
    if #out == 0 then return nil end
    return out
end

-- A pair of ladders, the shape util's curve family reads.
function cal.parsePair(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, way in ipairs({ "pos", "neg" }) do
        local samples = util.tidyCurve(data[way])
        if #samples > 0 then out[way] = samples end
    end
    if not out.pos and not out.neg then return nil end
    return out
end

-- The brake ladders carry a pitch per rung, which util.tidyCurve neither knows
-- nor keeps, so they are tidied here instead.
function cal.parseBrake(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, which in ipairs({ "main", "all" }) do
        local rungs = {}
        for _, rung in ipairs(type(data[which]) == "table" and data[which] or {}) do
            if type(rung) == "table" and type(rung.rpm) == "number"
                    and type(rung.speed) == "number" then
                rungs[#rungs + 1] = {
                    rpm = math.abs(rung.rpm),
                    speed = math.abs(rung.speed),
                    pitch = type(rung.pitch) == "number" and rung.pitch or nil,
                }
            end
        end
        table.sort(rungs, function(a, b) return a.rpm < b.rpm end)
        if #rungs > 0 then out[which] = rungs end
    end
    if not out.main and not out.all then return nil end
    return out
end

-- The same ladders split by which way the ship was travelling when it stopped.
-- The brake stage runs up forwards and reverses, so it only ever measures the
-- positive side, and `cal.brakeCurve` stays where that reading goes. This is
-- where a measurement of stopping from backward motion would go, and until
-- something measures one, flight.lua says so rather than cloning the forward
-- ladder across and calling it measured.
function cal.parseDirected(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, way in ipairs({ "pos", "neg" }) do
        local side = cal.parseBrake(data[way])
        if side then out[way] = side end
    end
    if not out.pos and not out.neg then return nil end
    return out
end

-- The forward response, one entry each way: `tau` seconds and `accel` m/s/s.
-- Nothing measures these yet either. They exist so a pilot who has worked the
-- numbers out from a flight can type them in, and so the assumed figures in
-- config are labelled as assumed everywhere rather than quietly standing in.
function cal.parseResponse(data)
    if type(data) ~= "table" then return nil end
    local out = {}
    for _, way in ipairs({ "pos", "neg" }) do
        local entry = data[way]
        if type(entry) == "table" then
            local tau, accel = tonumber(entry.tau), tonumber(entry.accel)
            if (tau and tau > 0) or (accel and accel > 0) then
                out[way] = { tau = tau and tau > 0 and tau or nil,
                             accel = accel and accel > 0 and accel or nil }
            end
        end
    end
    if not out.pos and not out.neg then return nil end
    return out
end

-- util.tidyCurve takes magnitudes, which would fold the sinking half of this
-- ladder onto the climbing half, so the balloon is read straight instead.
function cal.parseBalloon(data)
    if type(data) ~= "table" then return nil end
    local rungs = {}
    for _, rung in ipairs(data) do
        if type(rung) == "table" and type(rung.rpm) == "number"
                and type(rung.speed) == "number" then
            rungs[#rungs + 1] = { rpm = rung.rpm, speed = rung.speed }
        end
    end
    table.sort(rungs, function(a, b) return a.rpm < b.rpm end)
    if #rungs == 0 then return nil end
    return rungs
end

function cal.load()
    cal.sides, cal.yawAuth, cal.meta = {}, {}, {}
    cal.sidesRev, cal.curveRev = 0, {}
    cal.noseOffset, cal.yawCurve, cal.fwdCurve, cal.brakeCurve = nil, nil, nil, nil
    cal.brakeResponse, cal.fwdResponse = nil, nil
    cal.balloonCurve, cal.altHover, cal.inventory = nil, nil, nil
    cal.stressAtTurn, cal.stressAtCruise = nil, nil
    cal.yawAccel = nil
    cal.frontOffset, cal.alignMissed, cal.alignPoints = nil, nil, nil
    cal.roseMirror, cal.frontConfirmed = nil, nil

    if not cal.FILE or not fs.exists(cal.FILE) then return false end
    local handle = fs.open(cal.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end

    cal.sides = cal.parseSides(data.sides)
    cal.noseOffset = tonumber(data.noseOffset)
    cal.yawAccel = tonumber(data.yawAccel)
    cal.frontOffset = tonumber(data.frontOffset)
    cal.alignMissed = tonumber(data.alignMissed)
    cal.alignPoints = cal.parsePoints(data.alignPoints)
    -- Anything but the mirror is no mirror, so a file that has never heard of
    -- this field is a ship whose rose was never found to be back to front.
    cal.roseMirror = tonumber(data.roseMirror) == -1 and -1 or 1
    cal.frontConfirmed = data.frontConfirmed == true
    if type(data.yawAuth) == "table" then
        cal.yawAuth = { left = tonumber(data.yawAuth.left),
                        right = tonumber(data.yawAuth.right) }
    end
    cal.yawCurve = cal.parsePair(data.yawCurve)
    cal.fwdCurve = cal.parsePair(data.fwdCurve)
    cal.brakeCurve = cal.parseBrake(data.brakeCurve)
    cal.brakeResponse = cal.parseDirected(data.brakeResponse)
    cal.fwdResponse = cal.parseResponse(data.fwdResponse)
    cal.balloonCurve = cal.parseBalloon(data.balloonCurve)
    cal.altHover = tonumber(data.altHover)
    cal.stressAtTurn = tonumber(data.stressAtTurn)
    cal.stressAtCruise = tonumber(data.stressAtCruise)
    cal.inventory = type(data.inventory) == "table" and data.inventory or nil
    cal.meta = type(data.meta) == "table" and data.meta or {}
    cal.sidesRev = tonumber(data.sidesRev) or 0
    cal.curveRev = type(data.curveRev) == "table" and data.curveRev or {}
    return true
end

function cal.save()
    if not cal.FILE then return false end
    local dir = fs.getDir(cal.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle, reason = fs.open(cal.FILE, "w")
    if not handle then
        log.errorf("could not write %s: %s", cal.FILE, tostring(reason))
        return false
    end
    handle.write(textutils.serialize({
        sides = cal.sides, noseOffset = cal.noseOffset, yawAuth = cal.yawAuth,
        frontOffset = cal.frontOffset, alignMissed = cal.alignMissed,
        roseMirror = cal.roseMirror, alignPoints = cal.alignPoints,
        frontConfirmed = cal.frontConfirmed,
        yawCurve = cal.yawCurve, fwdCurve = cal.fwdCurve,
        brakeCurve = cal.brakeCurve, brakeResponse = cal.brakeResponse,
        fwdResponse = cal.fwdResponse, balloonCurve = cal.balloonCurve,
        altHover = cal.altHover, inventory = cal.inventory,
        stressAtTurn = cal.stressAtTurn, stressAtCruise = cal.stressAtCruise,
        yawAccel = cal.yawAccel,
        sidesRev = cal.sidesRev, curveRev = cal.curveRev,
        meta = cal.meta,
    }))
    handle.close()
    return true
end

-- == QUERIES THE REST OF THE PROGRAM ASKS ====================

function cal.sideOf(name)
    return cal.sides[name]
end

-- The lines on the ship right now that calibration filed under a side. A saved
-- line that is not on the network is not one of them, which is the difference
-- between what was measured and what is here.
function cal.linesOfSide(side)
    local out = {}
    for _, name in ipairs(ship.order) do
        local entry = cal.sides[name]
        if entry and entry.side == side then out[#out + 1] = name end
    end
    return out
end

-- Left becomes right and right becomes left, authorities and all.
--
-- Every way the handedness of the ship can change goes through here, so there
-- is one place that decides a ladder is stale rather than three that can
-- disagree. Called by the sides stage, by the swap and by the flip.
function cal.sidesChanged()
    cal.sidesRev = (cal.sidesRev or 0) + 1
end

-- Whether a curve measured earlier still describes this ship. A ladder from a
-- different filing of the sides is not resumable, because every rung in it now
-- names a turn the ship makes the other way.
function cal.curveCurrent(which)
    return (cal.curveRev and cal.curveRev[which]) == (cal.sidesRev or 0)
end

function cal.curveMeasured(which)
    cal.curveRev = cal.curveRev or {}
    cal.curveRev[which] = cal.sidesRev or 0
end

-- Magnitudes cannot prove handedness. Only a signed yaw measurement made
-- through the current filing can authorize a closed-loop turn.
function cal.yawReady()
    if not cal.curveCurrent("yaw") then
        return false, "yaw ladder was not measured with the current sides"
    end
    for _, way in ipairs({ "pos", "neg" }) do
        local ladder = cal.yawCurve and cal.yawCurve[way]
        if not ladder or #ladder == 0 then
            return false, "yaw ladder has no " .. way .. " direction measurement"
        end
        local last = 0
        for _, rung in ipairs(ladder) do
            if rung.speed <= 0 or rung.speed < last then
                return false, "yaw " .. way .. " ladder falls at " .. rung.rpm .. " rpm"
            end
            last = rung.speed
        end
    end
    return true
end

function cal.prepareYaw()
    if not cal.curveCurrent("yaw") then
        -- Stamping the first new rung must not certify the other old direction.
        cal.yawCurve, cal.yawAccel = {}, nil
    end
end

-- The sides stage decides handedness from one reading per line, and one
-- reading is enough to get it backwards: a line read while the physics engine
-- was reporting nothing, or a hull that was still swinging from the line
-- before it. Every line filed the wrong way round is the same mistake made
-- once, because they were all read against the same yaw. The yaw stage is
-- where it shows, as a hull that turns the opposite way to the one it was
-- asked for, and this is the whole of the fix: the mixer puts the differential
-- on whichever lines are called left, so swapping the two labels swaps the
-- turn. Nothing else in the file needs touching, since a side's authority
-- travels with its name.
function cal.swapSides()
    -- Every filed line, not just the ones on the network now. A line that is
    -- off the air is still on the side it was measured on, and leaving it
    -- behind would file one propeller against the other three.
    local swapped = 0
    for _, entry in pairs(cal.sides) do
        if entry.side == "left" then
            entry.side = "right"
            swapped = swapped + 1
        elseif entry.side == "right" then
            entry.side = "left"
            swapped = swapped + 1
        end
    end
    cal.yawAuth.left, cal.yawAuth.right = cal.yawAuth.right, cal.yawAuth.left
    cal.sidesChanged()
    return swapped
end

-- Every line turned round, which is what a ship that answers full ahead by
-- going astern is asking for.
--
-- The reverse flag is decided in the sides stage from the sign of one speed
-- reading, and one reading is enough to get it backwards on a hull that had
-- not begun to move, or on a line read while the physics engine was reporting
-- nothing. It is one mistake made once, because every line was read the same
-- way, and the forward ladder is where it shows.
--
-- The sides are swapped as well, and that is not tidiness. `mix` negates a
-- reversed line after the differential has been added to it, so flipping the
-- flag alone would invert the turn along with the thrust and throw away a yaw
-- ladder that was right. Swapping the two sides puts the differential back
-- where it was: a left line at c + d becomes a right line at -(c - d), which
-- is the same d and the opposite c. Thrust reverses, handedness does not.
function cal.flipThrust()
    local flipped = 0
    for _, entry in pairs(cal.sides) do
        entry.reverse = not entry.reverse
        flipped = flipped + 1
    end
    cal.swapSides()
    -- The nose offset was read off the main's drift with the thrust turned the
    -- way the flag said it pointed. The flag now says the other way, so the
    -- offset is half a circle out.
    if cal.noseOffset then cal.noseOffset = util.wrapAngle(cal.noseOffset + 180) end
    return flipped
end

-- Lines the ship has that calibration has never seen.
function cal.missingLines()
    local out = {}
    for _, name in ipairs(ship.order) do
        if not cal.sides[name] then out[#out + 1] = name end
    end
    return out
end

-- The fastest this ship has been measured going, either way along the hull.
function cal.topForward()
    if not cal.fwdCurve then return nil end
    local best = nil
    for _, way in ipairs({ "pos", "neg" }) do
        local top = util.curveTopSpeed(cal.fwdCurve[way])
        if top and (not best or top > best) then best = top end
    end
    return best
end

-- The fastest turn measured, deg/s, which is what a leg's turn time is budgeted
-- against and what the TUNE preview quotes.
function cal.topYawRate()
    if not cal.yawCurve then return nil end
    local best = nil
    for _, way in ipairs({ "pos", "neg" }) do
        local top = util.curveTopSpeed(cal.yawCurve[way])
        if top and (not best or top > best) then best = top end
    end
    return best
end

-- == THE MEASURED VALUES, BY HAND ============================
--
-- What the wizard learned, in a shape the TUNE tab can show and edit. These are
-- the single numbers rather than the ladders: a ladder is four readings and a
-- picture, and it belongs on the CAL tab where it is drawn.
--
-- Hand editable on purpose. A pilot who knows the hull holds at strength 7
-- should be able to say so without flying the balloon stage again, the way a
-- hand edited cal.cfg has always been honored. The popup says plainly that the
-- next run of that stage overwrites it, because the alternative is finding out
-- by watching a good number disappear.

cal.MEASURED = {
    { id = "yawAuthLeft", title = "yaw left", unit = "deg/s per rpm", stage = "sides",
      help = "How much yaw a rpm on the left side is worth.",
      get = function() return cal.yawAuth and cal.yawAuth.left end,
      set = function(v) cal.yawAuth = cal.yawAuth or {}; cal.yawAuth.left = v end },
    { id = "yawAuthRight", title = "yaw right", unit = "deg/s per rpm", stage = "sides",
      help = "The same for the right side. The two differ on a hull whose sides are not mirrored.",
      get = function() return cal.yawAuth and cal.yawAuth.right end,
      set = function(v) cal.yawAuth = cal.yawAuth or {}; cal.yawAuth.right = v end },
    { id = "noseOffset", title = "nose offset", unit = "deg", stage = "sides",
      help = "Degrees between where the hull points and where the main propeller pushes.",
      get = function() return cal.noseOffset end,
      set = function(v) cal.noseOffset = v end },
    { id = "frontOffset", title = "front offset", unit = "deg", stage = "align",
      help = "Degrees between where the hull points and the end of it the crew calls the front. The screens read in this; the maths does not.",
      get = function() return cal.frontOffset end,
      set = function(v) cal.frontOffset = v end },
    { id = "altHover", title = "hover level", unit = "strength 0 to 15", stage = "balloon",
      help = "The redstone strength that came nearest to holding this ship's height.",
      get = function() return cal.altHover end,
      set = function(v) cal.altHover = v end },
    { id = "yawAccel", title = "yaw acceleration", unit = "deg/s/s", stage = "yaw",
      help = "How fast the hull gets up to a turn, which is what the approach assumes it can be stopped at. Too high and it sails past the heading; too low and the last ninety degrees crawl.",
      get = function() return cal.yawAccel end,
      set = function(v) cal.yawAccel = v end },
    { id = "stressAtTurn", title = "stress, turning", unit = "su", stage = "yaw",
      help = "What the kinetic network was carrying at a full turn.",
      get = function() return cal.stressAtTurn end,
      set = function(v) cal.stressAtTurn = v end },
    { id = "stressAtCruise", title = "stress, cruising", unit = "su", stage = "forward",
      help = "What it was carrying at full cruise. The gate budgets against this.",
      get = function() return cal.stressAtCruise end,
      set = function(v) cal.stressAtCruise = v end },
}

function cal.measuredById(id)
    for _, entry in ipairs(cal.MEASURED) do
        if entry.id == id then return entry end
    end
    return nil
end

-- Returns the value, or nil with the stage that would have measured it, so the
-- screen can say which stage to run rather than printing a dash.
function cal.measured(id)
    local entry = cal.measuredById(id)
    if not entry then return nil, nil end
    return entry.get(), entry.stage
end

function cal.setMeasured(id, raw)
    local entry = cal.measuredById(id)
    if not entry then return nil, "no such measurement: " .. tostring(id) end
    local value = tonumber(raw)
    if not value then return nil, entry.id .. " is a number" end
    entry.set(value)
    cal.meta[entry.id .. "ByHand"] = log.timestamp and log.timestamp() or true
    cal.save()
    log.infof("measured %s set by hand to %g", entry.id, value)
    return value
end

-- == THE INVENTORY ===========================================
--
-- What the ship was made of when it was last measured. Comparing this against
-- what is on the network now is how a missing propeller gets named without a
-- single fact about this vessel being written into the program.

function cal.inventoryNow()
    local counts, order = {}, {}
    local sides = { left = 0, right = 0, main = 0, none = 0 }
    for _, name in ipairs(ship.order) do
        local remote = ship.remoteLines[name]
        local key = remote and remote.relay or "wire"
        if not counts[key] then counts[key] = 0; order[#order + 1] = key end
        counts[key] = counts[key] + 1
        local entry = cal.sides[name]
        local side = entry and entry.side or "none"
        sides[side] = (sides[side] or 0) + 1
    end
    table.sort(order, function(a, b) return tostring(a) < tostring(b) end)

    local relays = {}
    for _, key in ipairs(order) do
        relays[#relays + 1] = {
            id = key ~= "wire" and key or nil,
            wired = key == "wire" or nil,
            lines = counts[key],
        }
    end
    return { relays = relays, sides = sides, total = #ship.order }
end

local function relayLabel(entry)
    if entry.wired or not entry.id then return "the wire" end
    return "relay #" .. tostring(entry.id)
end

-- What has changed since the ship was measured. Each difference gets its own
-- sentence in the words of the thing that differs, because "inventory mismatch"
-- on a screen tells a pilot nothing about which computer to walk to.
function cal.inventoryCheck()
    local items = {}
    local function say(kind, fmt, ...)
        items[#items + 1] = { kind = kind, text = string.format(fmt, ...) }
    end

    if not cal.inventory or type(cal.inventory.relays) ~= "table" then
        say("warn", "this ship has never finished a calibration run, so there is nothing to compare against")
        return false, items
    end

    local now = cal.inventoryNow()
    local nowBy = {}
    for _, entry in ipairs(now.relays) do
        nowBy[entry.id or "wire"] = entry
    end

    local seen = {}
    for _, was in ipairs(cal.inventory.relays) do
        local key = was.id or "wire"
        seen[key] = true
        local isNow = nowBy[key]
        if not isNow then
            say("bad", "%s answered when the ship was measured and is not here now",
                relayLabel(was))
        elseif isNow.lines ~= was.lines then
            say("bad", "%s had %d line(s) when the ship was measured and has %d now",
                relayLabel(was), was.lines or 0, isNow.lines)
        end
    end
    for _, entry in ipairs(now.relays) do
        if not seen[entry.id or "wire"] then
            say("warn", "%s is here with %d line(s) and was not part of the measured ship",
                relayLabel(entry), entry.lines)
        end
    end

    local wasSides = type(cal.inventory.sides) == "table" and cal.inventory.sides or nil
    if wasSides then
        for _, side in ipairs({ "left", "right", "main" }) do
            local was, isNow = wasSides[side] or 0, now.sides[side] or 0
            if was ~= isNow then
                say("bad", "%d propeller(s) on the %s when measured, %d now", was, side, isNow)
            end
        end
    end

    for _, item in ipairs(items) do
        if item.kind == "bad" then return false, items end
    end
    return true, items
end

-- == WHAT THE SCREEN SHOWS ===================================

-- One row per stage: whether it has been run, when, and the headline number it
-- produced. The CAL tab and the wizard's own menu both read this.
function cal.summary()
    local out = {}
    for index, stage in ipairs(cal.STAGES) do
        local row = {
            index = index, id = stage.id, title = stage.title,
            at = cal.meta[stage.meta], done = false, detail = "not measured",
        }

        if stage.id == "sides" then
            local total = #ship.order
            local missing = #cal.missingLines()
            row.done = total > 0 and missing == 0
            if total == 0 then
                row.detail = "no propellers on the network"
            else
                row.detail = string.format("%d of %d, %dL %dR %dM",
                    total - missing, total, #cal.linesOfSide("left"),
                    #cal.linesOfSide("right"), #cal.linesOfSide("main"))
            end
        elseif stage.id == "balloon" then
            row.done = cal.balloonCurve ~= nil and cal.altHover ~= nil
            if row.done then
                row.detail = string.format("%d rungs, holds level at %d",
                    #cal.balloonCurve, cal.altHover)
            end
        elseif stage.id == "yaw" then
            local ready, why = cal.yawReady()
            row.done = ready
            if not ready then row.detail = why end
            if row.done then
                row.detail = string.format("top %.1f deg/s%s%s", cal.topYawRate() or 0,
                    cal.yawAccel and string.format(", %.1f deg/s/s", cal.yawAccel) or "",
                    cal.stressAtTurn and string.format(", %.0f su", cal.stressAtTurn) or "")
            end
        elseif stage.id == "forward" then
            row.done = cal.fwdCurve ~= nil
            if row.done then
                row.detail = string.format("top %.2f m/s%s", cal.topForward() or 0,
                    cal.stressAtCruise and string.format(", %.0f su", cal.stressAtCruise) or "")
            end
        elseif stage.id == "align" then
            row.done = cal.frontOffset ~= nil
            if row.done then
                row.detail = string.format("front %+.1f deg%s%s%s", cal.frontOffset,
                    cal.roseMirror == -1 and ", mirrored" or "",
                    (cal.alignMissed or 0) > 0
                        and string.format(", %d wrong", cal.alignMissed) or "",
                    cal.frontConfirmed and ", confirmed" or "")
            end
        elseif stage.id == "cruise" then
            row.done = cal.meta.cruiseAt ~= nil
            if row.done then
                row.detail = string.format("nose %+.1f, front %s", cal.noseOffset or 0,
                    cal.frontConfirmed and "confirmed" or "unconfirmed")
            end
        elseif stage.id == "brake" then
            row.done = cal.brakeCurve ~= nil
            if row.done then
                local cfg = config.values
                local mainMax = flight.maxDecel(cal, cfg, "main")
                local allMax = flight.maxDecel(cal, cfg, "all")
                row.detail = string.format("main %s, all %s m/s/s",
                    mainMax and string.format("%.2f", mainMax) or "-",
                    allMax and string.format("%.2f", allMax) or "-")
            end
        end

        out[#out + 1] = row
    end
    return out
end

-- == THE WIZARD ==============================================
--
-- ctx is the screen. It is handed in rather than reached for, so this file
-- never touches term directly and the whole flow can be driven by a test
-- harness or, later, by a remote console.
--
--   ctx.panel(t)              draw the wizard body from a table of fields
--   ctx.ask(question, opts)   a line of text back, with a default
--   ctx.yesno(question, def)  true or false
--   ctx.waitEnter()           blocks until Enter
--   ctx.waitAbort()           blocks until the pilot gives up, for waitForAny
--   ctx.aborted()             true once the pilot pressed q
--   ctx.note(text, kind)      one scrolling line in the wizard log
--   ctx.clearFields()         forget the panel, between stages

local function stamp()
    return os.day() .. "d " .. log.timestamp()
end

local function cfg()
    return config.values
end

-- The ladder the yaw and forward stages walk.
function cal.rpmLadder()
    local steps = config.get("calSteps")
    local first, last = config.get("calStartRpm"), config.get("calEndRpm")
    if last < first then first, last = last, first end
    if steps == 1 then return { last } end
    local out = {}
    for index = 0, steps - 1 do
        out[#out + 1] = util.round(first + (last - first) * index / (steps - 1))
    end
    return out
end

-- What the ship is doing, in whichever of the three quantities a stage measures.
local function forwardSpeed()
    local v = ship.bodyVelocity()
    return v and v.z or nil
end

local function climbRate()
    local state = ship.readState()
    return state and state.velocity.y or nil
end

local function pitchNow()
    local state = ship.readState()
    return state and util.pitchOf(state.orientation) or nil
end

-- A number written at the precision it was measured to. The top of a yaw
-- ladder is tens of degrees a second and the bottom of one on a heavy hull is
-- hundredths, and one format cannot say both: %.1f turns the bottom rung into
-- "0.0 deg/s", which reads as a rung that did nothing.
local function fine(value)
    local size = math.abs(value or 0)
    if size < 1 then return string.format("%.3f", value or 0) end
    if size < 10 then return string.format("%.2f", value or 0) end
    return string.format("%.1f", value or 0)
end

local function stressNow()
    if not turbine or not turbine.status then return nil end
    local ok, status = pcall(turbine.status)
    if not ok or type(status) ~= "table" then return nil end
    return status.stress
end

-- One rung: drive it, show what the ship is doing, and keep the reading when
-- the pilot says so. Every stage measures something different, so what is
-- driven and what is read are both arguments.
--
-- **Nothing here is on a clock, and that is the whole of the fix.** A rung
-- used to end itself once the reading had been steady for a few seconds, and a
-- hull that has not begun to move yet is perfectly steady at zero. So every
-- rung ended about three seconds in, off a number the turbines had not
-- produced yet: a balloon sweep where all six strengths read no climb, a yaw
-- ladder whose second rung was slower than its first. The pilot is standing
-- there watching the ship. The pilot decides when the reading is the reading.
--
-- What is kept is the average over the last second and a half rather than the
-- instant Enter landed on, because a hand on a key is not a measurement.
-- How long a kept reading is averaged over. Not a tuning knob: it is the
-- length of a hand coming down on a key, not a property of any ship.
local KEEP_SPAN = 1.5

-- One sample into a rolling window, and the average of what is in it. Whatever
-- is kept from a rung goes through here, because the number on the screen at
-- the instant Enter landed is a sample and the average of the last second and
-- a half is a reading.
local function windowMean(history, value, now)
    history[#history + 1] = { t = now, v = value }
    while #history > 2 and now - history[1].t > KEEP_SPAN do table.remove(history, 1) end
    local sum = 0
    for _, entry in ipairs(history) do sum = sum + entry.v end
    return sum / #history
end

local function track(ctx, opts)
    local stable = opts.stable or config.get("calStable")
    local floor = opts.floor or 0
    local autoCap = config.get("calAutoSeconds")
    local autoMin = math.min(config.get("calAutoMin"), autoCap)
    local autoLeft, autoWhy = autoCap, nil

    if opts.apply then opts.apply() end
    -- The prompt that offered this rung is gone the moment it is running, and
    -- the one that ends it takes its place. A stage whose rung is worth more
    -- than the reading on the panel says so in `keepPrompt`, because that line
    -- is the only text in front of a pilot with a finger on Enter.
    ctx.panel({ prompt = false })

    local started = util.now()
    local history = {}
    local lost = false
    -- The steepest the reading rose while the rung was coming up to speed. The
    -- settled value is what the ladder wants; this is how fast the hull got
    -- there, and it is free here because the samples are being taken anyway.
    local climb = 0

    local function sampler()
        while true do
            local now = util.now()
            local value = opts.read()
            if value == nil then
                lost = true
                return
            end

            windowMean(history, value, now)
            history[#history].physics = os.clock()

            local slope = 0
            if #history >= 2 then
                local a, b = history[1], history[#history]
                local span = b.physics - a.physics
                if span > 0.2 then slope = (b.v - a.v) / span end
            end

            if math.abs(slope) > math.abs(climb) and value * slope > 0 then
                -- Only a rise, and only one in the direction the reading is
                -- already going. A fall is the hull being stopped by the
                -- cooldown that follows, which is a different measurement.
                climb = math.abs(slope)
            end

            local steady = math.abs(slope) <= stable
            local moving = math.abs(value) >= floor

            if opts.live then
                -- Steady and moving are advice, not a decision. They are what
                -- the panel colours, so the pilot can see the moment the ship
                -- has finished answering rather than count seconds.
                opts.live({
                    value = value, slope = slope, elapsed = now - started,
                    steady = steady,
                    moving = moving,
                    floor = floor > 0 and floor or nil,
                    phase = steady and "steady" or "changing",
                    auto = opts.auto and autoLeft or nil,
                    keepPrompt = opts.keepPrompt
                        or (opts.auto and "running itself   [Enter] keeps it now   [Q] stops")
                        or "[Enter] keeps this reading   [Q] stops",
                })
            end

            -- Unattended. The pilot is not standing there, so something has to
            -- decide, and the two things that end a rung are the two things the
            -- pilot was watching: the trend flattening, or long enough gone.
            --
            -- The minimum is not politeness. A hull that has not begun to move
            -- is perfectly steady at zero, which is the bug that ended every
            -- rung three seconds in and filed a balloon sweep of six strengths
            -- that all read no climb. Steady only counts once the ship has had
            -- its `calAutoMin` to answer, and only while it is actually moving
            -- when the rung expected movement at all.
            if opts.auto then
                local elapsed = now - started
                autoLeft = math.max(0, autoCap - elapsed)
                if elapsed >= autoCap then
                    autoWhy = "kept on the clock"
                    return
                end
                if elapsed >= autoMin and steady and (floor <= 0 or moving) then
                    autoWhy = "kept once the trend flattened"
                    return
                end
            end

            sleep(config.get("calSample"))
        end
    end

    if opts.auto then
        -- q still stops the run. An unattended wizard a pilot cannot interrupt
        -- is worse than one that asks.
        parallel.waitForAny(sampler, ctx.waitAbort)
    else
        parallel.waitForAny(sampler, ctx.waitEnter)
    end
    ctx.panel({ keepPrompt = false })
    if ctx.aborted() then return nil, "stopped" end
    if lost then return nil, "lost the pose" end

    local sum, count = 0, 0
    for _, entry in ipairs(history) do sum = sum + entry.v; count = count + 1 end
    if count == 0 then return nil, "nothing was read" end
    local result = sum / count

    -- The reading is kept whatever it says, because the pilot asked for it to
    -- be. What it is worth is said out loud alongside it, in the words of the
    -- thing that is wrong with it.
    local reason = nil
    if math.abs(result) < floor then
        reason = "never moved"
    elseif opts.wantSign and result * opts.wantSign <= 0 then
        reason = "went the wrong way"
    end
    return result, reason, climb, autoWhy
end

-- Between rungs the ship has to shed what the last one built up, or the next
-- rung starts from the wrong speed and reads high. This is not a clock either:
-- it ends when the ship is actually back to rest, and the pilot can cut it
-- short on a hull that drifts for ever.
local function cooldown(ctx, read, label, floor, auto)
    if ctx.aborted() then return end
    floor = floor or config.get("calMinDrift")
    ship.allStop()
    local started = util.now()
    local function wait()
        while true do
            local value = read() or 0
            if math.abs(value) < floor then return end
            local elapsed = util.now() - started
            -- Unattended there is no Enter to cut this short, and some things a
            -- stage drives do not come back to rest on their own: a balloon is
            -- still holding the ship up after ship.allStop, so a cooldown
            -- waiting for the climb to stop waits for ever. It ends on the cap
            -- and the next rung's own settling absorbs what is left.
            if auto and elapsed >= config.get("calAutoSeconds") then return end
            ctx.panel({
                value = value, valueLabel = label, phase = "cooldown",
                elapsed = elapsed, slope = 0,
                steady = false, moving = true, floor = floor,
                auto = auto and math.max(0, config.get("calAutoSeconds") - elapsed) or nil,
                keepPrompt = auto and "settling   [Enter] goes on now   [Q] stops"
                    or "[Enter] goes on without waiting   [Q] stops",
                pitch = false, yawRate = false, drift = false, guess = false,
            })
            sleep(config.get("calSample"))
        end
    end
    parallel.waitForAny(wait, ctx.waitEnter)
    ctx.panel({ keepPrompt = false, phase = false })
    ship.allStop()
end

-- == THE LADDER WALKER =======================================
--
-- The yaw, forward and balloon stages are the same stage three times: a list of
-- rungs, each one driven and read and written down, and a curve built out of
-- what came back. They were three copies of that loop, and a fix to one of them
-- was a fix to one of them.
--
-- What the copies could not do is what a pilot actually needs. A rung kept by
-- accident used to mean the whole ladder again, because the loop only went
-- forwards and the stage only wrote its curve at the end. So:
--
--   every rung is written down the moment it is kept, not at the end
--   a ladder reopens on what is already measured, not on an empty one
--   the pilot moves to any rung, taken or not, and takes it again
--
-- A rung that is taken is green and a rung that is not is red, on a strip that
-- is always on the screen, so "which ones have I done" is never a question the
-- pilot has to hold in his head while the ship swings underneath him.
--
-- `opts`:
--   rungs        list of { key, label, way, apply, wantSign }
--   read         what the rung measures
--   valueLabel, unit, stable, floor
--   resume       function(rung) -> value already measured, or nil
--   keep         function(rung, value, climb, reason) -> true if written down
--   cooldownRead what has to come back to rest between rungs
--   cooldownLabel
--   onWrongWay   function(rung, value) -> true to measure the rung again
--   auto         run the untaken rungs without asking
local function walkLadder(ctx, opts)
    local rungs = opts.rungs
    local taken = {}
    local at = 1

    -- What a previous run of this stage already measured. The whole point of
    -- writing each rung down as it is kept is being able to come back to it,
    -- and a stage that reopened on a blank ladder would overwrite the half it
    -- was meant to be finishing.
    local resumed = 0
    for index, rung in ipairs(rungs) do
        local had = opts.resume and opts.resume(rung) or nil
        if had then
            taken[index] = had
            resumed = resumed + 1
        end
    end
    -- A ladder that exists but could not be resumed is the dangerous case, and
    -- it is the one that has to be said out loud. Silently starting over on a
    -- stale ladder looks identical to starting over on no ladder at all, and
    -- the pilot has no way to tell that the numbers on the CAL tab no longer
    -- describe the ship.
    if resumed == 0 and opts.staleNote then
        ctx.note(opts.staleNote, "warn")
    end
    if resumed > 0 then
        ctx.note(string.format(
            "%d of %d rungs are already measured and are kept as they are. "
            .. "Move to one with the arrows to take it again.", resumed, #rungs),
            "good")
        -- Start on the first rung nobody has taken, which is where a pilot
        -- coming back to a half finished ladder meant to be.
        for index = 1, #rungs do
            if not taken[index] then at = index; break end
        end
    end

    -- The strip. One cell per rung, coloured by whether it has a reading, with
    -- the rung the pilot is on marked. This goes on the panel every frame,
    -- during the rung as well as between them.
    local function strip()
        local cells = {}
        for index, rung in ipairs(rungs) do
            cells[index] = {
                label = rung.short or tostring(index),
                taken = taken[index] ~= nil,
                here = index == at,
            }
        end
        return cells
    end

    local function panelFor(extra)
        local t = extra or {}
        t.rungIndex = at
        t.rungTotal = #rungs
        t.rungCells = strip()
        t.rungLabel = rungs[at].label
        t.valueLabel = opts.valueLabel
        t.unit = opts.unit
        return t
    end

    -- One rung, driven and read and handed to `keep`. Returns false only when
    -- the pilot stopped the whole run.
    local function measure(auto)
        local rung = rungs[at]
        local again = true
        while again do
            again = false
            local value, reason, climb, autoWhy = track(ctx, {
                apply = rung.apply,
                read = opts.read,
                stable = opts.stable,
                floor = opts.floor,
                wantSign = rung.wantSign,
                auto = auto,
                live = function(live)
                    ctx.panel(panelFor(live))
                end,
            })

            if ctx.aborted() then return false end

            -- The handedness offer. Asking it unattended would hang the run on
            -- a question nobody is there to answer, so unattended says what it
            -- found and leaves the rung untaken.
            if reason == "went the wrong way" and opts.onWrongWay then
                ship.allStop()
                if auto then
                    ctx.note(string.format("%s went the wrong way. Left untaken: "
                        .. "which way round the sides are filed is not a question "
                        .. "an unattended run may answer.", rung.label), "bad")
                else
                    again = opts.onWrongWay(rung, value) and not ctx.aborted()
                    if again then taken = {} end
                    if again and opts.cooldownRead then
                        cooldown(ctx, opts.cooldownRead, opts.cooldownLabel, nil, auto)
                    end
                end
            end

            if not again then
                if value and not reason and opts.keep(rung, value, climb, reason) then
                    taken[at] = value
                    ctx.note(string.format("%s -> %s %s%s", rung.label, fine(value),
                        opts.unit or "", autoWhy and ("   " .. autoWhy) or ""), "good")
                else
                    -- Left untaken on purpose. A rung in the ladder that the
                    -- ship never actually produced is an RPM the mixer will ask
                    -- for later and not get.
                    taken[at] = nil
                    ctx.note(string.format("%s -> nothing kept: %s", rung.label,
                        tostring(reason or "no reading")), "bad")
                end
                if opts.cooldownRead then
                    cooldown(ctx, opts.cooldownRead, opts.cooldownLabel, nil, auto)
                end
            end
        end
        return true
    end

    if opts.auto then
        for index = 1, #rungs do
            if ctx.aborted() then break end
            if not taken[index] then
                at = index
                if not measure(true) then break end
            end
        end
        return taken
    end

    -- The card between rungs. Everything that can be pressed is named on it,
    -- in the same bracketed form the rest of the program uses.
    while not ctx.aborted() do
        local left = 0
        for index = 1, #rungs do if not taken[index] then left = left + 1 end end

        ctx.panel(panelFor({
            value = false, keepPrompt = false,
            rungValue = taken[at] and string.format("%s %s", fine(taken[at]), opts.unit or "")
                or false,
            prompt = string.format(
                "[Enter] %s   [Left] [Right] another rung   [A] run the rest alone   "
                .. "[D] done   [Q] stop%s",
                taken[at] and "take it again" or "measure it",
                left == 0 and "   every rung has a reading" or
                    string.format("   %d still to take", left)),
        }))

        local choice = ctx.rungChoice()
        if choice == "quit" then break end
        if choice == "done" then break end
        if choice == "left" then
            at = ((at - 2) % #rungs) + 1
        elseif choice == "right" then
            at = (at % #rungs) + 1
        elseif choice == "auto" then
            ctx.note("running the rest of the ladder alone. [Q] stops it.", "warn")
            for index = 1, #rungs do
                if ctx.aborted() then break end
                if not taken[index] then
                    at = index
                    if not measure(true) then break end
                end
            end
        elseif choice == "take" then
            if not measure(false) then break end
            -- Forward to the next rung nobody has taken, so walking a fresh
            -- ladder is still Enter, Enter, Enter.
            for step = 1, #rungs do
                local index = ((at + step - 1) % #rungs) + 1
                if not taken[index] then at = index; break end
            end
        end
    end

    return taken
end

-- Nothing is measured on the ground. A hull sitting on blocks answers a
-- propeller with friction rather than with thrust, and friction is not in any
-- of the models the ladders feed: it is why the first run of this wizard filed
-- a line as pushing nothing, and why a yaw rung at 128 rpm came out slower
-- than the same ladder's 64.
--
-- So every stage that reads motion lifts the ship clear first, at
-- calFlyStrength, which is full by default. Whether the ship is clear is not
-- something this program can see. It can see the height going up, and the
-- pilot can see the ground, so it shows the one and waits for the other.
local function flyClear(ctx, why, auto)
    if not turbine or not turbine.hasBalloon or not turbine.hasBalloon() then
        ctx.note("no relay is holding the balloon, so this measures the ship where it sits", "warn")
        return
    end
    local level = util.clamp(math.floor(config.get("calFlyStrength") + 0.5), 0, 15)
    pcall(turbine.setBalloon, level)
    ctx.note(string.format("balloon to %d. %s needs the ship off the ground.", level, why), "warn")

    -- Unattended there is nobody to look at the ground, so this waits on the
    -- one thing it can see instead: the ship climbing, and then long enough at
    -- it to be clear of whatever it was sitting on. It is the weakest part of
    -- an unattended run and it is the part that is said out loud, because a
    -- ladder measured against friction is a ladder that reads low all the way
    -- up and says nothing about it.
    if auto then
        ctx.note("nobody is watching the ground, so this climbs for "
            .. util.fmtETA(config.get("calAutoSeconds"))
            .. " and trusts it. Start the run with the ship already clear if you can.",
            "warn")
        local started = util.now()
        local function climb()
            while util.now() - started < config.get("calAutoSeconds") do
                local state = ship.readState()
                ctx.panel({
                    value = state and state.velocity.y or 0,
                    valueLabel = "climb", unit = "m/s",
                    slope = 0, elapsed = util.now() - started, steady = false, moving = true,
                    auto = math.max(0, config.get("calAutoSeconds") - (util.now() - started)),
                    rungLabel = state and string.format("height %.1f", state.position.y)
                        or "no pose",
                    keepPrompt = "climbing to clear air   [Enter] goes on now   [Q] stops",
                })
                sleep(config.get("calSample"))
            end
        end
        parallel.waitForAny(climb, ctx.waitEnter)
        ctx.panel({ keepPrompt = false, rungLabel = false, auto = false })
        return
    end

    local function watch()
        while true do
            local state = ship.readState()
            ctx.panel({
                value = state and state.velocity.y or 0,
                valueLabel = "climb", unit = "m/s",
                slope = 0, elapsed = 0, steady = false, moving = true,
                rungLabel = state and string.format("height %.1f", state.position.y)
                    or "no pose",
                keepPrompt = "[Enter] when it is clear of the ground   q stops",
            })
            sleep(config.get("calSample"))
        end
    end
    parallel.waitForAny(watch, ctx.waitEnter)
    ctx.panel({ keepPrompt = false, rungLabel = false })
end

-- What the balloon is put back to when a stage that flew is done. Left at full
-- the ship climbs until something stops it, and the thing that usually stops
-- it is the build limit.
local function settleBack(ctx)
    if not turbine or not turbine.hasBalloon or not turbine.hasBalloon() then return end
    if not cal.altHover then
        ctx.note("balloon left at full: no hover strength has been measured yet", "warn")
        return
    end
    pcall(turbine.setBalloon, cal.altHover)
    ctx.note(string.format("balloon back to %d, where it holds level", cal.altHover))
end

-- == STAGE: SIDES ============================================

-- Positive RPM on a line either pushes the hull forward or it does not, and it
-- either swings the nose or it does not. Those two readings are the whole
-- stage: a line that pushes forward and swings the nose right is on the left
-- side, because that is what being on the left side means.
--
-- The size of the swing is kept as well as its direction, and that is the part
-- a pilot cannot guess from the screen. It becomes the side's yaw authority,
-- and `flight.sideScales` holds the stronger side back to match the weaker one,
-- so a rung ended early files a side as weak and the mixer spends the rest of
-- the ship's life turning on one propeller. A pilot who already knows the sides
-- still has to let each rung even out, and the stage now says so rather than
-- looking like a handedness check that happens to take a while.
local function stageSides(ctx, auto)
    local names = ship.order
    if #names == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end

    ctx.note(string.format("%d lines, one at a time. Give the ship clear air.", #names))
    ctx.note("Each spin measures how hard that side turns the hull, not only which way. "
        .. "That number is what the mixer splits a turn by, so let every rung run until "
        .. "the swing is steady before you keep it. Ending one early files the side as "
        .. "weak and the ship turns on one propeller from then on.", "warn")
    -- A propeller read against the ground is read against friction, and the
    -- line that came out of that was filed as pushing nothing at all.
    flyClear(ctx, "reading which side a line is on", auto)
    local auth = { left = 0, right = 0 }
    local measured = { left = false, right = false }
    local done, skipped = 0, 0

    for index, name in ipairs(names) do
        if ctx.aborted() then break end
        local current = cal.sides[name]

        ctx.panel({
            step = index, total = #names, line = name,
            current = current and current.side or nil,
            reversed = current and current.reverse or nil,
            prompt = "[Enter] spin it   s skip   q stop",
        })
        -- Unattended every line is spun. Skipping one is a decision about a
        -- ship, and there is nobody here to make it.
        local choice = auto and ""
            or ctx.ask("", { default = "", hint = "Enter to spin, s, or q" }):lower()
        if choice == "q" then break end

        if choice == "s" then
            skipped = skipped + 1
            ctx.note(util.shortName(name) .. " left as it was")
        else
            -- The yaw rate at the moment the speed settled, not the largest seen
            -- on the way there. A hull that is still coming up to speed is still
            -- swinging, and the swing it ends at is the one it can hold.
            -- The yaw is averaged over the same window the speed is, and for
            -- the same reason. A single reading taken at the moment Enter
            -- landed is one sample of a number that arrives noisy, and a hull
            -- the physics engine has stopped reporting a rate for hands back a
            -- zero: one of those, caught at the wrong instant, files a
            -- propeller on the wrong side or files it as the main.
            local yawRate, drift = 0, nil
            local yawHistory = {}
            local speed, reason = track(ctx, {
                apply = function() ship.driveOnly(name, config.get("calRpm")) end,
                read = forwardSpeed,
                auto = auto,
                keepPrompt = not auto and "[Enter] when the swing is steady   [Q] stops" or nil,
                live = function(live)
                    yawRate = windowMean(yawHistory, ship.yawRateHeading() or 0, util.now())
                    drift = ship.bodyVelocity()
                    live.step = index
                    live.total = #names
                    live.line = name
                    live.valueLabel = "speed"
                    live.unit = "m/s"
                    live.yawRate = yawRate
                    live.guess = false
                    live.drift = drift and { drift.x, drift.y, drift.z } or nil
                    ctx.panel(live)
                end,
            })
            ship.allStop()

            if ctx.aborted() then break end
            if not speed then
                ctx.note(string.format("%s: %s", util.shortName(name), tostring(reason)), "bad")
            else
                local minDrift, minYaw = config.get("calMinDrift"), config.get("calMinYaw")
                local reverse = speed < 0
                local forwardSign = reverse and -1 or 1
                -- Read with the thrust turned round to point forward, so a
                -- propeller mounted backwards lands on the same side as its
                -- neighbour rather than on the opposite one.
                local yawForward = yawRate * forwardSign

                local guess
                if math.abs(speed) < minDrift and math.abs(yawRate) < minYaw then
                    guess = "none"
                elseif math.abs(yawForward) < minYaw then
                    guess = "main"
                elseif yawForward > 0 then
                    guess = "left"
                else
                    guess = "right"
                end

                ctx.panel({
                    step = index, total = #names, line = name,
                    value = speed, valueLabel = "speed", unit = "m/s",
                    yawRate = yawRate, guess = guess,
                    drift = drift and { drift.x, drift.y, drift.z } or nil,
                    prompt = string.format("%+.2f m/s, %+.1f deg/s%s", speed, yawRate,
                        reason and (" (" .. reason .. ")") or ""),
                })
                -- Unattended the guess is the answer. That is exactly what
                -- the guess is for, and the reading behind it is now given the
                -- full rung rather than whatever a pilot in a hurry allowed it.
                local answer = auto and guess or ctx.ask("Which side is it on?", {
                    default = guess,
                    choices = { "left", "right", "main", "none" },
                    extra = { "skip" },
                })
                answer = (answer or ""):lower()
                if answer == "" then answer = guess end

                if answer == "skip" then
                    skipped = skipped + 1
                    ctx.note(util.shortName(name) .. " left as it was")
                elseif answer == "left" or answer == "right" or answer == "main"
                        or answer == "none" then
                    local was = cal.sides[name]
                    cal.sides[name] = { side = answer, reverse = reverse }
                    -- Only when the filing actually moved. Re-running the stage
                    -- and confirming what was already there must not throw away
                    -- a ladder that is still describing this ship correctly.
                    if not was or was.side ~= answer or was.reverse ~= reverse then
                        cal.sidesChanged()
                    end
                    done = done + 1
                    if answer == "left" or answer == "right" then
                        auth[answer] = auth[answer] + math.abs(yawRate) / config.get("calRpm")
                        measured[answer] = true
                        -- The wizard's own threshold for a hull that is not
                        -- turning. A reading under it is still filed, because
                        -- the pilot asked for it to be, but it is worth saying
                        -- that the authority it just became is noise.
                        if math.abs(yawForward) < minYaw then
                            ctx.note(string.format(
                                "%s swung %.2f deg/s, under the %.2f this counts as turning at all. "
                                .. "Its side is filed, but the authority off it is noise. "
                                .. "Spin it again with clear air and let it even out.",
                                util.shortName(name), math.abs(yawForward), minYaw), "warn")
                        end
                    end
                    if answer == "main" and drift then
                        -- Where the nose actually points. The main is the only
                        -- line whose thrust is meant to be straight down the
                        -- hull, so its drift is what the offset is measured off.
                        local bx, bz = drift.x * forwardSign, drift.z * forwardSign
                        if util.len3(bx, 0, bz) >= minDrift then
                            cal.noseOffset = util.wrapAngle(math.deg(math.atan2(-bx, bz)))
                            ctx.note(string.format("nose offset %+.1f deg", cal.noseOffset))
                        end
                    end
                    ctx.note(string.format("%s -> %s%s", util.shortName(name), answer,
                        reverse and " (reversed)" or ""), "good")
                    log.infof("cal: %s = %s reverse=%s yaw=%.2f speed=%.2f",
                        name, answer, tostring(reverse), yawRate, speed)
                    cal.save()
                else
                    ctx.note("left, right, main or none. Left as it was.", "bad")
                end
            end
        end
    end

    ship.allStop()
    settleBack(ctx)
    -- A side with no reading this run keeps what it had. Half a run is still
    -- worth keeping, and a zero here would divide the mixer by nothing.
    for _, side in ipairs({ "left", "right" }) do
        if measured[side] and auth[side] > 0 then cal.yawAuth[side] = auth[side] end
    end

    cal.inventory = cal.inventoryNow()
    cal.meta.sidesAt = stamp()
    cal.save()
    ctx.note(string.format("sides saved: %d set, %d left alone", done, skipped), "good")
    if cal.yawAuth.left and cal.yawAuth.right then
        ctx.note(string.format("yaw authority  left %.4f  right %.4f deg/s per rpm",
            cal.yawAuth.left, cal.yawAuth.right))
        -- What the mixer is about to do with those two numbers, in the RPM the
        -- pilot will read off the PROPS tab. A pair that came out lopsided is
        -- invisible as two small decimals and obvious as this.
        local scaleL, scaleR = flight.sideScales(cal.yawAuth.left, cal.yawAuth.right)
        local top = config.get("maxRpm")
        ctx.note(string.format(
            "so a full turn is %d rpm one side against %d the other. "
            .. "The weaker side is turned up all the way and the stronger held back to "
            .. "match it, which is how the hull turns without crabbing.",
            util.round(top * scaleL), util.round(top * scaleR)),
            math.min(scaleL, scaleR) < 0.5 and "warn" or nil)
        if math.min(scaleL, scaleR) < 0.5 then
            ctx.note("Two sides of the same hull do not differ by that much. "
                .. "One of the rungs above was kept before the hull had finished swinging. "
                .. "Run this stage again with clear air, or set the two authorities equal "
                .. "by hand, and measure the yaw ladder after it.", "warn")
        end
    end
    return true
end

-- == STAGE: BALLOON ==========================================

-- A coarse sweep to find where the climb rate crosses zero, then the strengths
-- either side of it one at a time. Hover is the number that matters and it has
-- to be exact; the rest of the ladder only has to be shaped right.
local function stageBalloon(ctx, auto)
    if not turbine or not turbine.hasBalloon or not turbine.hasBalloon() then
        ctx.note("no relay is holding the balloon, so there is nothing to measure", "bad")
        return false
    end

    local step = config.get("calBalloonStep")
    local levels, seen = {}, {}
    for level = 0, 15, step do
        levels[#levels + 1] = level
        seen[level] = true
    end
    if not seen[15] then levels[#levels + 1] = 15; seen[15] = true end

    -- Every strength ever measured, by strength. The curve is rebuilt from this
    -- on each keep, so a strength taken again replaces its old reading instead
    -- of landing beside it, and the refinement pass below can add to it without
    -- the coarse sweep having to be held separately.
    local held = {}

    local function commit()
        local samples = {}
        for level, climb in pairs(held) do
            samples[#samples + 1] = { rpm = level, speed = climb }
        end
        table.sort(samples, function(a, b) return a.rpm < b.rpm end)
        cal.balloonCurve = samples
        cal.save()
        return samples
    end

    local function rungsFor(list)
        local rungs = {}
        for _, level in ipairs(list) do
            rungs[#rungs + 1] = {
                key = tostring(level), level = level,
                short = tostring(level),
                label = string.format("strength %d", level),
                apply = function() pcall(turbine.setBalloon, level) end,
            }
        end
        return rungs
    end

    local sweep = {
        read = climbRate,
        -- No floor: at hover the answer is no climb at all, and a rung that
        -- refused to believe a zero would refuse to find hover.
        valueLabel = "climb", unit = "m/s",
        -- No cooldown, and that is not an omission. Every other ladder stops
        -- its propellers and waits for the hull to come back to rest, but a
        -- balloon holds the ship up: after ship.allStop it is still climbing at
        -- whatever strength was last set, so a cooldown waiting for the climb
        -- to reach zero waits for ever. The next strength is simply set and the
        -- rung settles into it, which is what the sweep did before it shared
        -- this walker.
        auto = auto,
        resume = function(rung)
            for _, sample in ipairs(cal.balloonCurve or {}) do
                if sample.rpm == rung.level then
                    held[rung.level] = sample.speed
                    return sample.speed
                end
            end
            return nil
        end,
        keep = function(rung, climb)
            held[rung.level] = climb
            log.infof("cal: balloon level=%d climb=%.3f", rung.level, climb)
            commit()
            return true
        end,
    }

    -- The sweep starts at zero, and zero on the ground is a ship that does not
    -- sink because it is already resting on something. Every strength then
    -- reads no climb, which is exactly what the first run of this wrote down.
    flyClear(ctx, "the balloon sweep", auto)
    ctx.note(string.format("sweeping %d strengths. The ship will sink and climb, and each "
        .. "strength is written down as it is kept.", #levels), "warn")

    sweep.rungs = rungsFor(levels)
    walkLadder(ctx, sweep)
    local samples = commit()

    -- Refine around the crossing: the two strengths either side of where the
    -- ship stops sinking and starts climbing are the only ones hover can be.
    if not ctx.aborted() then
        local below, above = nil, nil
        for _, sample in ipairs(samples) do
            if sample.speed < 0 then below = sample.rpm end
            if sample.speed >= 0 and not above then above = sample.rpm end
        end
        if below and above and above - below > 1 then
            local extra = {}
            for level = below + 1, above - 1 do
                if not held[level] then extra[#extra + 1] = level end
            end
            if #extra > 0 then
                ctx.note(string.format("crossing is between %d and %d, walking the %d between",
                    below, above, #extra))
                sweep.rungs = rungsFor(extra)
                walkLadder(ctx, sweep)
                samples = commit()
            end
        elseif not below then
            ctx.note("this balloon climbs at every strength, including zero", "warn")
        elseif not above then
            ctx.note("this balloon never held level, even at full strength", "bad")
        end
    end

    -- Hover is the measured strength whose climb rate is nearest to nothing,
    -- and a tie goes upward. A ship parked a hair light is a ship that drifts
    -- up; a ship parked a hair heavy is one that arrives on the ground.
    local best = nil
    for _, sample in ipairs(samples) do
        if not best or math.abs(sample.speed) < math.abs(best.speed)
                or (math.abs(sample.speed) == math.abs(best.speed) and sample.speed > best.speed) then
            best = sample
        end
    end
    if best then
        cal.altHover = best.rpm
        pcall(turbine.setBalloon, cal.altHover)
        ctx.note(string.format("holds level at strength %d, %+.2f m/s", best.rpm, best.speed), "good")
    end

    cal.meta.balloonAt = stamp()
    cal.save()
    return true
end

-- == STAGE: YAW ==============================================

local function stageYaw(ctx, auto)
    if #cal.linesOfSide("left") == 0 or #cal.linesOfSide("right") == 0 then
        ctx.note("no line on one of the two sides, so there is nothing to turn against. Run yaw's sides first.", "bad")
        return false
    end
    flyClear(ctx, "the yaw ladder", auto)

    local ladder = cal.rpmLadder()
    local ways = config.get("calBothWays") and { 1, -1 } or { 1 }
    local hadStale = cal.yawCurve and not cal.curveCurrent("yaw")
    cal.prepareYaw()
    cal.yawCurve = cal.yawCurve or {}
    -- A resumed ladder keeps its measured acceleration too. Clearing it when
    -- all rungs are resumed silently replaces a measurement with the fallback.
    -- The swap below is offered once, and only while the ladder has kept
    -- nothing this run, because the offer is about how the sides were filed and
    -- not about this rung. Past the first kept reading a hull that turns the
    -- wrong way is a hull that did something else, and swapping the sides
    -- underneath a half measured ladder leaves half of it measured the other
    -- handedness.
    local kept, offeredSwap = 0, false

    -- Both ways in one list, so the arrows walk the whole ladder rather than
    -- stopping at the turn. `samples` per way is what the curve is built from
    -- and it is rewritten from `held` on every keep, because a rung taken again
    -- has to replace its old reading rather than sit beside it.
    local rungs, held = {}, { pos = {}, neg = {} }
    for _, sign in ipairs(ways) do
        local way = sign > 0 and "pos" or "neg"
        for _, diff in ipairs(ladder) do
            rungs[#rungs + 1] = {
                key = way .. ":" .. diff, way = way, rpm = diff, sign = sign,
                short = string.format("%+d", diff * sign),
                label = string.format("differential %+d", diff * sign),
                wantSign = sign,
                apply = function()
                    ship.flush(flight.mix(0, diff * sign, ship.order, cal, cfg()))
                end,
            }
        end
    end

    local function commit(way)
        local samples = {}
        for rpm, speed in pairs(held[way]) do
            samples[#samples + 1] = { rpm = rpm, speed = speed }
        end
        cal.yawCurve[way] = util.tidyCurve(samples)
        cal.curveMeasured("yaw")
        cal.save()
    end

    walkLadder(ctx, {
        rungs = rungs,
        read = ship.yawRateHeading,
        stable = config.get("calYawStable"),
        -- Not calMinYaw. That number answers the sides stage's question,
        -- whether a line swings the nose enough to be on a side at all, and at
        -- one degree a second it would throw away the bottom half of a heavy
        -- ship's ladder as no reading.
        floor = config.get("calYawFloor"),
        valueLabel = "yaw", unit = "deg/s",
        cooldownRead = function() return ship.yawRateHeading() or 0 end,
        cooldownLabel = "yaw",
        auto = auto,
        staleNote = hadStale
            and "there is a yaw ladder on file, but it was measured with the sides filed "
                .. "differently, so every rung in it names a turn this ship now makes the "
                .. "other way. It is being measured again from the bottom."
            or nil,

        -- What the last run of this stage left behind, rung by rung. This is
        -- the whole of resuming: a ladder reopens on its own readings.
        --
        -- Unless the sides have been filed again since, in which case every
        -- rung in it describes a turn this ship now makes the other way and
        -- resuming would hand back a ladder that reads correct and flies
        -- backwards.
        resume = function(rung)
            if not cal.curveCurrent("yaw") then return nil end
            for _, sample in ipairs(cal.yawCurve[rung.way] or {}) do
                if sample.rpm == rung.rpm then
                    held[rung.way][rung.rpm] = sample.speed
                    return sample.speed
                end
            end
            return nil
        end,

        onWrongWay = function(rung, rate)
            -- The hull turning the other way to the one it was asked for is not
            -- a bad rung. It is the two sides filed backwards, and every rung
            -- after this one reads the same, so the ladder ends empty and the
            -- stage never says why. Say why, and offer the one thing that fixes
            -- it.
            if kept > 0 or offeredSwap then return false end
            offeredSwap = true
            ctx.note(string.format(
                "asked for %s and the hull turned %s deg/s, the other way",
                rung.short, fine(rate or 0)), "bad")
            ctx.note("that is left and right filed backwards, not a bad reading", "warn")
            if not ctx.yesno("Swap the two sides and measure this rung again?", true) then
                ctx.note("left as it is, so the ladder turns the wrong way all the way up", "warn")
                return false
            end
            local moved = cal.swapSides()
            held = { pos = {}, neg = {} }
            cal.prepareYaw()
            cal.save()
            ctx.note(string.format(
                "%d lines swapped over, and the authorities with them", moved), "good")
            log.infof("cal: yaw swapped %d lines, rung %s read %.3f",
                moved, rung.short, rate or 0)
            return true
        end,

        keep = function(rung, rate, climb)
            held[rung.way][rung.rpm] = math.abs(rate)
            kept = kept + 1
            -- How hard the hull can be got turning, which is also how hard it
            -- can be stopped: the same propellers do both and the drag is on
            -- the braking side. The fastest rise any rung managed is the one
            -- kept, because it is the top rung that a turn is flown at.
            if climb and climb > (cal.yawAccel or 0) then cal.yawAccel = climb end
            -- The engine's own figure alongside the one being written down.
            -- They disagreed by three times on this ship and nothing said so,
            -- because only one of the two was ever read.
            log.infof("cal: yaw way=%s rpm=%d rate=%.2f engine=%s",
                rung.way, rung.rpm, rate,
                ship.yawRate() and string.format("%.2f", ship.yawRate()) or "none")
            -- The stress of a full turn is read at the top rung, while the ship
            -- is actually doing it. Read after the stop and it is the stress of
            -- nothing happening.
            if rung.rpm == ladder[#ladder] then
                local stress = stressNow()
                if stress then
                    cal.stressAtTurn = stress
                    ctx.note(string.format("a full turn draws %.0f su", stress))
                end
                if cal.yawAccel then
                    ctx.note(string.format(
                        "the hull gets up to a turn at %s deg/s/s, which is what the approach brakes on",
                        fine(cal.yawAccel)))
                end
            end
            -- Written down here, one rung at a time. The stage used to hold the
            -- whole ladder in memory and a stop halfway through was a stage to
            -- run again from the bottom.
            commit(rung.way)
            return true
        end,
    })

    ship.allStop()
    settleBack(ctx)
    cal.meta.yawAt = stamp()
    cal.save()
    return true
end

-- == STAGE: ALIGN ============================================
--
-- The one thing in this program that cannot be measured off the ship: which
-- end of it is the front.
--
-- Everything else here reads a sensor. The pose says which way the hull's own
-- +Z axis points, the drift says which way a propeller pushed, the yaw rate
-- says which way the hull came round. None of them say which end a player
-- standing on the deck would call the front, and nothing on the network ever
-- will. So the ship is turned to a heading the pilot can check against the sky
-- and the pilot is asked.
--
-- The rose is walked rather than one point taken, because eight readings say
-- something one cannot: a turn that lands short at every point by a growing
-- amount is a yaw ladder that is off, and a set of readings that disagree with
-- each other is a hull that was still swinging when it was read.

-- The eight points in Minecraft yaw, which is the convention the whole program
-- reads and writes in: 0 is south, 180 is north, -90 is east, +90 is west.
-- Written out rather than stepped off north by an offset, because an offset has
-- a sign and that sign was wrong: the rose ran the way a compass rose runs and
-- sent the ship to the mirror of every point it named.
cal.ROSE = {
    { name = "north", yaw = 180 },  { name = "north east", yaw = -135 },
    { name = "east", yaw = -90 },   { name = "south east", yaw = -45 },
    { name = "south", yaw = 0 },    { name = "south west", yaw = 45 },
    { name = "west", yaw = 90 },    { name = "north west", yaw = 135 },
}
local ROSE = cal.ROSE

-- Where a point of the rose sits, given what this world calls north and which
-- way round the rose came out on this ship.
--
-- In an ordinary world north is yaw 180 and there is no mirror, so this is the
-- identity. A dimension whose north is elsewhere carries the whole rose with
-- it. A mirror of -1 reflects the rose about the line from north to south,
-- which swaps east with west and leaves north and south where they are: that
-- is the one wrongness a pilot can see that a half turn of the front does not
-- account for.
function cal.rosePoint(point, north, mirror)
    local turned = (mirror == -1) and -point.yaw or point.yaw
    return util.wrapAngle(turned + util.wrapAngle((north or 180) - 180))
end

-- Which yaw this world's north sits at, as the wizard is going to fly it.
--
-- The program's rose is meant to land on the same points as the rose the pilot
-- reads off F3, so the dimension wins when it can answer: it is the only thing
-- here that knows the world. `calNorthYaw` is the fallback, and it is 180
-- because that is north in Minecraft yaw.
--
-- A disagreement is asked about rather than resolved quietly, because the one
-- reason a pilot has had to move this number is a ship whose front is the
-- other end from its hull, and that is not what this number is for. Turning
-- north to cancel a backwards hull turns every label on the rose into a lie
-- while the arithmetic underneath stays consistent, which is the worst shape a
-- wrong setting can have. `cal.frontOffset` is the number that fixes it and
-- the stage now asks for it outright.
local function northYaw(ctx)
    local configured = util.wrapAngle(config.get("calNorthYaw"))
    local sensed, why = ship.magneticNorth()

    if not sensed then
        ctx.note(string.format(
            "the dimension has no magnetic north to give (%s), so the rose is walked on calNorthYaw, %+.1f",
            tostring(why), configured), "warn")
        return configured
    end
    if math.abs(util.wrapAngle(sensed - configured)) <= 1 then
        ctx.note(string.format("north is %+.1f, and the dimension agrees", sensed), "good")
        return sensed
    end

    ctx.note(string.format("calNorthYaw says north is %+.1f, the dimension says %+.1f",
        configured, sensed), "warn")
    if ctx.yesno(string.format(
        "Walk the rose on the dimension's north, %+.1f? Moving north moves every label on the compass and is not what corrects a ship whose front is the other end from its hull. The front offset does that, and the next question asks for it.",
        sensed), true) then
        return sensed
    end
    return configured
end

-- Command a turn to a heading and hold it until the pilot says it has arrived.
--
-- The same code the leg flies with, PID and measured ladder included, because a
-- turn measured through some other arithmetic would be measuring the other
-- arithmetic. With no ladder `flight.tankDemand` falls back to plain
-- proportional and the caller says so once.
--
-- Nothing here ends on a clock or on an arrival. A hull that has not begun to
-- turn yet sits exactly on the heading it started from, and a wizard that took
-- that for an arrival would file the ship as pointing wherever it was parked.
function cal.turnTo(ctx, want, label)
    if ctx.aborted() then return nil, "stopped" end
    local ready, why = cal.yawReady()
    if not ready then
        ship.allStop()
        ctx.note(why .. ". The yaw stage must verify the turn direction first.", "bad")
        if not ctx.yesno("Measure yaw before turning to a heading?", true) then
            return nil, why
        end
        stageYaw(ctx, false)
        if ctx.aborted() then return nil, "stopped" end
        ready, why = cal.yawReady()
        if not ready then
            ctx.note(why .. ". No heading turn was started.", "bad")
            return nil, why
        end
        -- The yaw stage restores hover on exit. Regain clearance before the
        -- enclosing stage resumes its turn rather than turning on that descent.
        flyClear(ctx, "turning to a heading")
        if ctx.aborted() then return nil, "stopped" end
    end
    local pid = util.newPID(config.get("yawKp"), config.get("yawKi"),
        config.get("yawKd"), -1e6, 1e6, 50)
    local tol = config.get("calAlignTol")
    local started = util.now()
    local last = os.clock()
    -- The turn is traced once a second rather than once a sample, because the
    -- point is to read the numbers back afterwards and a pilot who leaves the
    -- ship sitting on a point would otherwise fill the log with one heading.
    local lastTrace = 0
    local err, pose = nil, nil
    local skipped = false

    local function drive()
        while true do
            local readAt = util.now()
            local state = ship.readState()
            if not state then
                ctx.note("lost the pose mid turn", "bad")
                return
            end
            local now = util.now()
            -- Rates and the hull evolve on game ticks; wall time belongs only
            -- to the display and diagnostics, even on a lagging server.
            local physicsNow = os.clock()
            local dt = physicsNow - last
            if dt <= 0 then dt = config.get("calSample") end
            last = physicsNow

            pose = state.yaw
            err = util.wrapAngle(want - pose)
            -- The rate the hull is actually turning at, which is what lets the
            -- turn stop rather than coast through the heading.
            local rate = ship.yawRate()
            local rateAt = util.now()
            local demand = flight.tankDemand(err, pid, cal, cfg(), dt, rate)
            ship.flush(flight.mix(0, demand.diff, ship.order, cal, cfg()))
            local sentAt = util.now()

            -- Trace cadence is not control cadence. Print dt explicitly and
            -- time the reads and send so a world log can locate the delay.
            if now - lastTrace >= 1 then
                lastTrace = now
                log.infof(
                    "cal: align turn off=%+.3f rate=%s rpm=%+.0f want=%+.3f cap=%.3f dt=%.3f tau=%.3f coast=%+.3f settled=%s gain=%.3f poseTime=%.3f rateTime=%.3f sendTime=%.3f",
                    err, rate and string.format("%+.3f", rate) or "none",
                    demand.diff, demand.rate, demand.cap, dt, demand.tau,
                    demand.coast, tostring(demand.settled), demand.rateGain,
                    now - readAt, rateAt - now, sentAt - rateAt)
            end

            ctx.panel({
                rungLabel = label,
                value = err, valueLabel = "off", unit = "deg",
                slope = rate or 0,
                elapsed = now - started,
                steady = math.abs(err) <= tol,
                moving = true,
                wanted = want, pose = pose,
                keepPrompt = "[Enter] when it has stopped swinging   s skips this point   q stops",
            })
            sleep(config.get("calSample"))
        end
    end

    local function waitKey()
        while true do
            local event, p1 = os.pullEvent()
            if event == "key" then
                if p1 == keys.enter then return end
                if p1 == keys.s then skipped = true; return end
                if p1 == keys.q then ctx.stop(); return end
            end
        end
    end

    parallel.waitForAny(drive, waitKey)
    ship.allStop()
    ctx.panel({ keepPrompt = false, wanted = false, pose = false })
    if ctx.aborted() then return nil, "stopped" end
    if skipped then return nil, "skipped" end
    if not pose then return nil, "no pose" end
    return pose, nil, err
end

local function stageAlign(ctx)
    if #cal.linesOfSide("left") == 0 or #cal.linesOfSide("right") == 0 then
        ctx.note("no line on one of the two sides, so the ship cannot be turned. Run sides first.", "bad")
        return false
    end
    if not cal.yawCurve then
        ctx.note("no yaw ladder yet, so the turns run on plain proportional and land roughly", "warn")
    end

    local north = northYaw(ctx)

    -- Two things can be wrong about the way round this ship reads, and both of
    -- them are a flip rather than a number.
    --
    -- The front can be the other end of the hull, which puts north where south
    -- should be and east where west should be, both at once. And the rose can
    -- come out mirrored, which swaps east with west and leaves north and south
    -- alone. Between them they cover every way round this ship has come out.
    --
    -- So the stage does not ask for a heading off F3 any more. It asks two
    -- questions a pilot answers by looking out of the window: at north, is the
    -- front facing north, and at the next point, is it facing that. A number
    -- typed at a prompt while a ship drifts can be mistyped and was. Yes and no
    -- cannot, and the coordinates were never wrong, only flipped.
    local known = cal.frontOffset or 0
    local mirror = cal.roseMirror == -1 and -1 or 1
    if cal.frontOffset then
        ctx.note(string.format("starting from the front %+.1f off the hull%s, and checking it",
            known, mirror == -1 and " and a mirrored rose" or ""))
    end

    flyClear(ctx, "turning to each point of the compass")

    local points, misses = {}, {}
    local wrong = 0

    for index, point in ipairs(ROSE) do
        if ctx.aborted() then break end
        ctx.panel({ rungIndex = index, rungTotal = #ROSE })

        -- The first point settles the half turn and the second settles the
        -- mirror, because those are the two points where a no still has
        -- something to teach. After them a no is a point this ship came out
        -- wrong on and is written down as one.
        local settles = (index == 1 and "flip") or (index == 2 and "mirror") or nil
        local tries = 0

        while tries < 2 do
            tries = tries + 1
            local want = cal.rosePoint(point, north, mirror)
            local aim = flight.hullHeadingFor(want, known)
            local label = string.format("point %d of %d, %s, front to %+.1f (hull to %+.1f)",
                index, #ROSE, point.name, want, aim)

            local pose, reason, missed = cal.turnTo(ctx, aim, label)
            if ctx.aborted() then break end
            if not pose then
                ctx.note(string.format("%s: %s", point.name, tostring(reason)), "warn")
                if reason ~= "skipped" then return false end
                break
            end

            local facing = ctx.yesno(
                string.format("Is the front of the ship facing %s?", point.name), true)
            if ctx.aborted() then break end

            if not facing and settles and tries < 2 then
                -- Nothing is written down for a point that was flown the wrong
                -- way round. Keeping it would file the mistake as evidence
                -- about the hull rather than as the thing that taught the flip.
                if settles == "flip" then
                    known = util.wrapAngle(known + 180)
                    ctx.note(string.format(
                        "then the front is the other end of the hull. It sits %+.1f off it, and every point from here is flown around the front. Going round again.",
                        known), "warn")
                else
                    mirror = -mirror
                    ctx.note(mirror == -1
                        and "then the rose is mirrored: this ship comes out east where the compass says west. Turning the rose over and going round again."
                        or "then the rose is not mirrored after all. Turning it back and going round again.", "warn")
                end
                log.infof("cal: align %s settled the %s: offset=%.1f mirror=%d",
                    point.name, settles, known, mirror)
            else
                -- How close the controller got, which needs no pilot at all and
                -- is the only evidence in the stage about the turn rather than
                -- about the hull.
                misses[#misses + 1] = missed or util.wrapAngle(aim - pose)
                points[#points + 1] = { want = want, pose = pose, ok = facing }
                if facing then
                    ctx.note(string.format("%s: the front is facing it, hull at %+.1f",
                        point.name, pose), "good")
                else
                    wrong = wrong + 1
                    ctx.note(string.format(
                        "%s: the front is not facing it, and both flips are settled by now, so this is written down as a point the ship came out wrong on.",
                        point.name), "bad")
                end
                log.infof("cal: align %s want=%.1f aim=%.1f pose=%.1f facing=%s",
                    point.name, want, aim, pose, tostring(facing))
                break
            end
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    settleBack(ctx)

    if #points == 0 then
        ctx.note("nothing was answered, so nothing is written down", "bad")
        return false
    end

    -- Points the ship came out wrong on after both flips were settled. One is
    -- a turn that landed badly. Several is the pair of flips not being the
    -- whole story about this hull, and writing the pair down anyway would file
    -- a guess as a measurement, so it is offered rather than taken.
    if wrong > 0 then
        local action = ctx.choose(popup.calRose(wrong, #points, known, mirror))
        if action ~= "keep" then
            ctx.note("the rose was thrown away. Nothing was written down.", "warn")
            return false
        end
    end

    cal.frontOffset = known
    cal.roseMirror = mirror
    cal.alignMissed = wrong
    cal.alignPoints = points
    cal.meta.alignAt = stamp()
    cal.save()
    ctx.note(string.format(
        "the front sits %+.1f deg off the hull%s, and %d of %d points came out facing the way they were sent",
        known, mirror == -1 and " on a mirrored rose" or "", #points - wrong, #points), "good")

    -- What the turn itself did, which is the handedness question. A controller
    -- that cannot get near the heading it was given is not a controller that
    -- needs tuning, it is one steering the wrong way.
    local wide, oneWay = 0, 0
    for _, miss in ipairs(misses) do
        if math.abs(miss) > config.get("calAlignTol") then wide = wide + 1 end
        oneWay = oneWay + util.sign(miss)
    end
    if #misses >= 3 and wide >= #misses - 1 and math.abs(oneWay) >= #misses - 1 then
        local action = ctx.choose(popup.calHandedness(
            string.format("%d of %d turns finished wide, and every one of them on the same side",
                wide, #misses),
            { "left and right are filed the wrong way round",
              "the turn is being driven away from the heading it was given" }))
        if action == "swap" then
            local moved = cal.swapSides()
            cal.save()
            ctx.note(string.format("%d lines swapped over. Run this stage again to check it.", moved), "good")
        end
    end

    -- Thrust and the front pointing opposite ways. Either number on its own
    -- looks reasonable; it is the pair that says the ship is filed backwards.
    if cal.noseOffset then
        local apart = math.abs(util.wrapAngle(known - cal.noseOffset))
        if apart >= 180 - config.get("calFlipTol") then
            local action = ctx.choose(popup.calBackwards(
                string.format("the front is %+.1f off the hull and the thrust is %+.1f, which is %.0f apart",
                    known, cal.noseOffset, apart),
                { "the main propeller pushes out of the stern",
                  "this ship flies away from every target it is given" }))
            if action == "flip" then
                local flipped = cal.flipThrust()
                cal.save()
                ctx.note(string.format("%d lines turned round, nose offset now %+.1f",
                    flipped, cal.noseOffset or 0), "good")
            end
        end
    end

    -- The confirmation preflight looks for. It is asked here rather than
    -- assumed from the arithmetic, because the arithmetic is what is being
    -- checked.
    local confirm = ctx.choose(popup.calFrontFlip(known, mirror, wrong, #points))
    cal.frontConfirmed = confirm == "confirm"
    if not cal.frontConfirmed then
        ctx.note("the front is written down but not confirmed. Run the stage again when you can see it.", "warn")
    end
    cal.save()
    return true
end

-- == STAGE: CRUISE ALIGN =====================================
--
-- Where the ship actually goes when it is told to go straight.
--
-- The sides stage takes the nose offset off one drift reading of one propeller,
-- taken in the second the pilot pressed a key. This takes it off a whole leg at
-- speed, which is the thing the number is for: the autopilot turns until thrust
-- points at the target and then trusts it to fly there.
local function stageCruise(ctx)
    if #ship.order == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end
    if not cal.fwdCurve then
        ctx.note("no forward ladder yet, so the leg runs at the configured cruise rpm", "warn")
    end

    local north = northYaw(ctx)

    flyClear(ctx, "the cruise leg")

    local pose = cal.turnTo(ctx, north, string.format("lining up on north, %+.1f", north))
    if ctx.aborted() then return false end
    if pose then
        ctx.note(string.format("lined up, the hull reads %+.1f", pose))
    else
        return false
    end

    local start = ship.readState()
    if not start then
        ctx.note("no pose, so there is nothing to measure a course against", "bad")
        return false
    end

    local rpm = config.get("cruiseMaxRpm")
    ctx.note(string.format("running at %d rpm. Let it go as far as you have room for.", rpm), "warn")

    local headings = {}
    local last = nil
    local floor = config.get("calCourseMin")

    local function fly()
        ship.flush(flight.mix(rpm, 0, ship.order, cal, cfg()))
        while true do
            local state = ship.readState()
            if not state then
                ctx.note("lost the pose mid leg", "bad")
                return
            end
            last = state
            headings[#headings + 1] = state.yaw
            local dx = state.position.x - start.position.x
            local dz = state.position.z - start.position.z
            local gone = util.len3(dx, 0, dz)
            ctx.panel({
                rungLabel = string.format("flown %.1f m of the %.0f this reading needs",
                    gone, floor),
                value = state.speed, valueLabel = "speed", unit = "m/s",
                slope = 0, elapsed = 0,
                steady = gone >= floor, moving = gone >= floor, floor = floor,
                course = gone >= 1 and flight.bearingTo(start.position.x, start.position.z,
                    state.position.x, state.position.z) or nil,
                pose = state.yaw,
                keepPrompt = "[Enter] ends the leg and takes the course   q stops",
            })
            sleep(config.get("calSample"))
        end
    end

    parallel.waitForAny(fly, ctx.waitEnter)
    ship.allStop()
    ctx.panel({ keepPrompt = false, course = false, pose = false })
    settleBack(ctx)
    if ctx.aborted() then return false end
    if not last then
        ctx.note("the leg was never read", "bad")
        return false
    end

    local dx = last.position.x - start.position.x
    local dz = last.position.z - start.position.z
    local gone = util.len3(dx, 0, dz)
    -- A course measured over four blocks is the noise in the pose rather than a
    -- heading, the same way a rung that never moved is not a slow rung.
    if gone < floor then
        ctx.note(string.format("the leg was %.1f m, under the %.0f this reading needs. Nothing kept.",
            gone, floor), "bad")
        return false
    end

    local course = flight.bearingTo(start.position.x, start.position.z,
        last.position.x, last.position.z)
    -- The heading over the whole leg, not the one it finished on. A hull that
    -- wandered a degree or two did not fly the heading it happened to end at.
    local held = util.meanAngle(headings) or last.yaw
    local offset = util.wrapAngle(course - held)
    ctx.note(string.format("%.1f m on a heading of %+.1f made a course of %+.1f",
        gone, held, course), "good")
    log.infof("cal: cruise gone=%.1f held=%.1f course=%.1f offset=%.1f",
        gone, held, course, offset)

    local apart = math.abs(offset)
    if apart >= 180 - config.get("calFlipTol") then
        -- An offset of half a circle is not an offset. It is a ship that has
        -- been told to fly in reverse for ever, and writing it down as a number
        -- would hide that behind arithmetic that works.
        local action = ctx.choose(popup.calBackwards(
            string.format("it flew %.0f degrees away from where it was pointing", apart),
            { string.format("over %.0f m at %d rpm", gone, rpm),
              "the propellers are filed the wrong way round" }))
        if action == "flip" then
            local flipped = cal.flipThrust()
            cal.save()
            ctx.note(string.format("%d lines turned round. Run this stage again to check it.",
                flipped), "good")
        end
    else
        local action = ctx.choose(popup.calReplace("NOSE OFFSET",
            "where the ship goes when it is told to go straight",
            cal.noseOffset, offset, "deg",
            string.format("measured over %.0f m at %d rpm", gone, rpm)))
        if action == "take" then
            cal.noseOffset = offset
            ctx.note(string.format("nose offset is %+.1f deg", offset), "good")
        else
            ctx.note(string.format("kept the %s it had",
                cal.noseOffset and string.format("%+.1f", cal.noseOffset) or "nothing"), "warn")
        end
    end

    -- And the question the pair of stages exists for, asked while the pilot is
    -- still stood there looking at a ship that has just flown somewhere.
    local confirm = ctx.choose(popup.calFront(
        util.wrapAngle(held + (cal.frontOffset or 0)), held, cal.frontOffset or 0))
    cal.frontConfirmed = confirm == "confirm"
    if not cal.frontConfirmed then
        ctx.note("the front is still unconfirmed. Preflight will say so.", "warn")
    end

    cal.meta.cruiseAt = stamp()
    cal.save()
    return true
end

-- == STAGE: FORWARD ==========================================

local function stageForward(ctx, auto)
    if #ship.order == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end
    flyClear(ctx, "the forward ladder", auto)

    local ladder = cal.rpmLadder()
    local ways = config.get("calBothWays") and { 1, -1 } or { 1 }
    cal.fwdCurve = cal.fwdCurve or {}
    -- Offered once, and only while the ladder has kept nothing this run, for
    -- the same reason the yaw stage's swap is: it is about how the lines were
    -- filed and not about this rung, and turning the ship round underneath a
    -- half measured ladder leaves half of it measured the other way round.
    local kept, offeredFlip = 0, false

    local rungs, held = {}, { pos = {}, neg = {} }
    for _, sign in ipairs(ways) do
        local way = sign > 0 and "pos" or "neg"
        for _, rpm in ipairs(ladder) do
            rungs[#rungs + 1] = {
                key = way .. ":" .. rpm, way = way, rpm = rpm, sign = sign,
                short = string.format("%+d", rpm * sign),
                label = string.format("throttle %+d", rpm * sign),
                wantSign = sign,
                apply = function()
                    ship.flush(flight.mix(rpm * sign, 0, ship.order, cal, cfg()))
                end,
            }
        end
    end

    local function commit(way)
        local samples = {}
        for rpm, speed in pairs(held[way]) do
            samples[#samples + 1] = { rpm = rpm, speed = speed }
        end
        cal.fwdCurve[way] = util.tidyCurve(samples)
        cal.curveMeasured("fwd")
        cal.save()
    end

    walkLadder(ctx, {
        rungs = rungs,
        read = forwardSpeed,
        floor = config.get("calMinDrift"),
        valueLabel = "speed", unit = "m/s",
        cooldownRead = function() return forwardSpeed() or 0 end,
        cooldownLabel = "speed",
        auto = auto,
        staleNote = cal.fwdCurve and (cal.fwdCurve.pos or cal.fwdCurve.neg)
            and not cal.curveCurrent("fwd")
            and "there is a forward ladder on file, but the lines have been filed again "
                .. "since it was measured. It is being measured again from the bottom."
            or nil,

        resume = function(rung)
            if not cal.curveCurrent("fwd") then return nil end
            for _, sample in ipairs(cal.fwdCurve[rung.way] or {}) do
                if sample.rpm == rung.rpm then
                    held[rung.way][rung.rpm] = sample.speed
                    return sample.speed
                end
            end
            return nil
        end,

        onWrongWay = function(rung, speed)
            -- A ship asked for full ahead that goes astern is not a bad rung.
            -- Every line is filed the wrong way round, every rung after this
            -- one reads the same, and the ladder ends empty without the stage
            -- ever saying why.
            if kept > 0 or offeredFlip then return false end
            offeredFlip = true
            ctx.note(string.format("asked for %s and the ship made %s m/s, the other way",
                rung.short, fine(speed or 0)), "bad")
            ctx.note("that is every line filed the wrong way round, not a bad reading", "warn")
            if not ctx.yesno("Turn every line round and measure this rung again?", true) then
                ctx.note("left as it is, so the ladder runs backwards all the way up", "warn")
                return false
            end
            local flipped = cal.flipThrust()
            cal.save()
            ctx.note(string.format(
                "%d lines turned round, sides swapped with them so the turn is unchanged",
                flipped), "good")
            log.infof("cal: forward flipped %d lines, rung %s read %.3f",
                flipped, rung.short, speed or 0)
            return true
        end,

        keep = function(rung, speed)
            held[rung.way][rung.rpm] = math.abs(speed)
            kept = kept + 1
            log.infof("cal: forward way=%s rpm=%d speed=%.3f", rung.way, rung.rpm, speed)
            if rung.rpm == ladder[#ladder] then
                local stress = stressNow()
                if stress then
                    cal.stressAtCruise = stress
                    ctx.note(string.format("full cruise draws %.0f su", stress))
                end
            end
            commit(rung.way)
            return true
        end,
    })

    ship.allStop()
    settleBack(ctx)
    cal.meta.forwardAt = stamp()
    cal.save()
    return true
end

-- == STAGE: BRAKING ==========================================

-- Run up, reverse, and write down how hard it stopped and how far the nose went
-- over doing it. Two rungs each for the main alone and for all five, and the
-- pilot is asked before every one of the four, because each is a run at speed
-- and the ship covers ground it has to have.
local function brakeRun(ctx, which, rpm, label, auto)
    local top = config.get("cruiseMaxRpm")
    -- Half the speed the ship is known to make. A stop measured from a crawl
    -- is a deceleration the hull never has to produce, and it goes into the
    -- ladder the arrival phase reads, so it is worth asking about rather than
    -- keeping quietly.
    local measured = cal.topForward()
    local floor = measured and measured * 0.5 or config.get("calMinDrift")
    local v0 = track(ctx, {
        apply = function() ship.flush(flight.mix(top, 0, ship.order, cal, cfg())) end,
        read = forwardSpeed,
        wantSign = 1,
        floor = floor,
        auto = auto,
        live = function(live)
            live.rungLabel = label .. ", running up"
            live.valueLabel = "speed"
            live.unit = "m/s"
            live.keepPrompt = auto and "running up by itself   [Q] stops"
                or "[Enter] starts the stop   [Q] stops"
            ctx.panel(live)
        end,
    })
    if ctx.aborted() or not v0 or v0 <= 0 then
        ship.allStop()
        return nil, ctx.aborted() and "stopped" or "never got moving"
    end
    if v0 < floor then
        ship.allStop()
        -- Unattended this is not asked, it is refused. A stop measured from a
        -- crawl is a deceleration the hull never has to produce, and writing it
        -- into the ladder the arrival phase reads is worse than having no rung
        -- there at all.
        if auto then
            return nil, string.format("run up reached only %.1f m/s, under half of %.1f",
                v0, measured or 0)
        end
        if not ctx.yesno(string.format(
                "only reached %.1f m/s, under half the %.1f this ship makes. Stop from that anyway?",
                v0, measured or 0), false) then
            return nil, string.format("run up reached only %.1f m/s", v0)
        end
        ship.flush(flight.mix(top, 0, ship.order, cal, cfg()))
    end

    -- The reverse itself is not a settle. What is wanted is the slope of the
    -- speed while it comes off, so this runs until the ship is stopped or until
    -- it runs out of patience, and measures what happened over that.
    local turbines = which == "all" and -rpm or 0
    ship.flush(flight.mixParts(-rpm, turbines, 0, ship.order, cal, cfg()))

    local started = util.now()
    local worstPitch, v, elapsed = 0, v0, 0

    local function run()
        while true do
            local now = util.now()
            elapsed = now - started
            local speed = forwardSpeed()
            if not speed then return end
            v = speed
            -- Nose over only. The run up leaves the hull sitting nose high, and
            -- taking the largest pitch either way would write that down as the
            -- cost of braking when it is the cost of getting up to speed.
            local pitch = pitchNow()
            if pitch and -pitch > worstPitch then worstPitch = -pitch end
            ctx.panel({
                rungLabel = label .. ", stopping",
                valueLabel = "speed", unit = "m/s", value = speed, slope = 0,
                phase = "braking", elapsed = elapsed,
                steady = false, moving = true,
                keepPrompt = auto and "stopping by itself   [Q] stops"
                    or "[Enter] takes the stop as measured   [Q] stops",
                pitch = worstPitch, from = v0,
            })
            -- The stop ends when the ship has stopped, which is an event and
            -- not a length of time. A hull whose reverse cannot hold it is one
            -- the pilot ends by hand, and that is worth knowing too.
            if speed <= 0 then return end
            -- A reverse that cannot hold the ship would otherwise sit here
            -- until somebody pressed a key, and unattended nobody will. What is
            -- measured up to the cap is still a real deceleration.
            if auto and elapsed >= config.get("calAutoSeconds") then return end
            sleep(config.get("calSample"))
        end
    end

    parallel.waitForAny(run, auto and ctx.waitAbort or ctx.waitEnter)
    ship.allStop()
    if ctx.aborted() then return nil, "stopped" end
    if elapsed <= 0 then return nil, "stopped before it was measured" end

    local decel = (v0 - math.max(v, 0)) / elapsed
    return { rpm = rpm, speed = decel, pitch = worstPitch }, nil, v0
end

local function stageBrake(ctx, auto)
    if #ship.order == 0 then
        ctx.note("no propeller lines on the network, wired or on a relay", "bad")
        return false
    end
    if #cal.linesOfSide("main") == 0 then
        ctx.note("no line is filed as the main, so there is no main to stop on. Run sides first.", "bad")
        return false
    end
    flyClear(ctx, "the brake runs", auto)

    local full = config.get("brakeRpmMax")
    local rungs = { util.round(full / 2), full }
    cal.brakeCurve = cal.brakeCurve or {}

    for _, which in ipairs({ "main", "all" }) do
        -- What a previous run of this stage already got, so a stage stopped
        -- after two of its four runs finishes rather than starts again. Each
        -- run is written down as it lands, the same way the ladders are.
        local kept = {}
        if cal.curveCurrent("brake") then
            for _, rung in ipairs(cal.brakeCurve[which] or {}) do kept[#kept + 1] = rung end
        end
        local function alreadyHave(rpm)
            for _, rung in ipairs(kept) do if rung.rpm == rpm then return true end end
            return false
        end

        for _, rpm in ipairs(rungs) do
            if ctx.aborted() then break end
            local label = string.format("%s at %d rpm",
                which == "main" and "the main alone" or "all five", rpm)

            ctx.panel({
                rungLabel = label,
                prompt = "a run up to full speed and a stop. Room ahead.",
            })
            local run
            if auto then
                -- Unattended, a run that already has a reading is left alone.
                -- Every stop costs the ship a length of clear air, and
                -- measuring one twice for the same number spends it twice.
                run = not alreadyHave(rpm)
                if not run then
                    ctx.note(label .. " already measured, left as it is", "good")
                end
            else
                run = ctx.yesno("Run " .. label .. "?" ..
                    (alreadyHave(rpm) and " It already has a reading." or ""), true)
            end
            if not run then
                if not auto then ctx.note(label .. " skipped") end
            else
                -- A run taken again replaces its old reading rather than
                -- landing beside it in the ladder.
                for index = #kept, 1, -1 do
                    if kept[index].rpm == rpm then table.remove(kept, index) end
                end
                local rung, reason, from = brakeRun(ctx, which, rpm, label, auto)
                if rung then
                    kept[#kept + 1] = rung
                    table.sort(kept, function(a, b) return a.rpm < b.rpm end)
                    cal.brakeCurve[which] = kept
                    cal.curveMeasured("brake")
                    cal.save()
                    ctx.note(string.format("%s: %.2f m/s/s from %.1f m/s, nose %+.1f deg",
                        label, rung.speed, from or 0, rung.pitch or 0), "good")
                    log.infof("cal: brake which=%s rpm=%d decel=%.3f pitch=%.2f",
                        which, rpm, rung.speed, rung.pitch or 0)
                else
                    ctx.note(string.format("%s: no reading (%s)", label, tostring(reason)), "bad")
                end
                cooldown(ctx, function() return forwardSpeed() or 0 end, "speed")
            end
        end
        if ctx.aborted() then break end
    end

    ship.allStop()
    settleBack(ctx)
    cal.meta.brakeAt = stamp()
    cal.save()
    return true
end

local RUNNERS = {
    sides = stageSides,
    balloon = stageBalloon,
    yaw = stageYaw,
    align = stageAlign,
    forward = stageForward,
    cruise = stageCruise,
    brake = stageBrake,
}

-- == THE RUN =================================================

-- Every stage is confirmed before it runs, with what it does and how much room
-- it needs, and every stage can be passed over. A wizard that has to be taken
-- from the top to fix one ladder is a wizard nobody re-runs.
-- `auto` runs the whole thing with nobody at the keyboard. Every rung ends on
-- its own trend flattening or on calAutoSeconds, whichever comes first, and
-- every question a stage would ask is answered with the thing the stage already
-- worked out: the sides stage takes its own guess, the ladders skip the rung
-- rather than ask which way round the ship is filed.
--
-- **align and cruise are not in it and cannot be.** Those two stages exist
-- because no sensor on this network can say which end of the hull the crew call
-- the front, which is why the align stage turns the ship to a compass point and
-- asks a human what he sees. An unattended run that answered that question
-- would be inventing the one number the whole stage was built to stop being
-- invented. So an unattended run does the five that are measurements and says
-- plainly that the front is still owed.
function cal.runWizard(ctx, only, auto)
    local stages = {}
    for _, stage in ipairs(cal.STAGES) do
        local wanted = not only or only == stage.id
        if auto and (stage.id == "align" or stage.id == "cruise") then wanted = false end
        if wanted then stages[#stages + 1] = stage end
    end
    if #stages == 0 then
        if auto then
            ctx.note("nothing to run alone. align and cruise need a pilot at the screen.", "bad")
            return false
        end
        ctx.note("no such stage. They are sides, balloon, yaw, align, forward, cruise and brake.", "bad")
        return false
    end

    if auto then
        ctx.note(string.format(
            "running %d stages with nobody at the keyboard. Each rung ends when its trend "
            .. "flattens or after %s, whichever comes first, and what it measures is written "
            .. "down as it goes. [Q] stops it and keeps what is measured.",
            #stages, util.fmtETA(config.get("calAutoSeconds"))), "warn")
        ctx.note("align and cruise are not in this. Which end is the front is the one thing "
            .. "nothing on the network can answer, so run `cal align` yourself afterwards.", "warn")
    end

    local rows = {}
    for _, row in ipairs(cal.summary()) do rows[row.id] = row end

    local ran = 0
    for index, stage in ipairs(stages) do
        if ctx.aborted() then break end
        ctx.clearFields()

        local row = rows[stage.id]
        ctx.panel({
            stageIndex = index, stageTotal = #stages, stageTitle = stage.title,
            what = stage.what, room = stage.room,
            current = row and row.detail or nil,
            at = row and row.at or nil,
            prompt = "[Enter] run it   [S] skip it   [Q] stop",
        })
        local choice = auto and ""
            or ctx.ask("", { default = "", hint = "Enter to run, s, or q" }):lower()
        if choice == "q" then break end

        if choice == "s" then
            ctx.note(stage.title .. " skipped")
        else
            -- The card goes away once the stage starts. Its prompt offered a
            -- choice that has already been made, and a stale prompt on a screen
            -- is a screen nobody trusts.
            ctx.clearFields()
            ctx.panel({ stageIndex = index, stageTotal = #stages, stageTitle = stage.title })
            ctx.note("== " .. stage.title .. " ==", "warn")
            local ok, err = pcall(RUNNERS[stage.id], ctx, auto)
            -- A stage that errors out has to hand the propellers back stopped
            -- before the next one is offered, and has to say what broke in the
            -- words the error came in.
            pcall(ship.allStop)
            if not ok then
                ctx.note(stage.title .. " failed: " .. tostring(err), "bad")
                log.error("cal: " .. stage.title .. " failed: " .. tostring(err))
            elseif err ~= false then
                ran = ran + 1
            end
        end
    end

    ship.allStop()
    if ran > 0 then
        cal.inventory = cal.inventoryNow()
        cal.save()
    end
    ctx.clearFields()
    if auto and not ctx.aborted() then
        ctx.note("the five measured stages are done. The front is still whatever it was: "
            .. "run `cal align` and answer it yourself, or the ship flies its rose "
            .. "around the wrong end.", "warn")
    end
    if ctx.aborted() then
        ctx.note("calibration stopped early. What was measured is saved, rung by rung, "
            .. "so running it again carries on rather than starting over.", "warn")
    else
        ctx.note(string.format("calibration finished, %d stage(s) run", ran), "good")
    end
    return true
end

return cal
