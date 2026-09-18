-- preflight.lua -- is this ship fit to be told to fly.
--
-- Pure the way sc/flight.lua is: no peripherals of its own, no screen, no
-- files, no globals. It is handed the modules that already know things and it
-- asks them read only questions, so the whole of it runs under
-- `starcatcher --test` against stub tables.
--
-- It returns a report and never acts on one. The gate in cmd.lua decides what
-- to do about a failure, and popup.lua decides what to say about it, because a
-- checker that refuses things is a checker nobody can test.
--
-- Every item carries two sentences of its own. `text` is what is wrong, in the
-- words of the thing that is wrong, and `cost` is what flying anyway would mean.
-- A shared "preflight failed" tells a pilot neither, and the second sentence is
-- the one that lets someone decide to override on purpose rather than by habit.
--
-- An item's `kind` is "bad" when the leg should not be flown and "warn" when it
-- can be but the pilot should know. `ok` is false for both: the report's own
-- `ok` is what the gate reads, and it is false if anything is bad.

local util, flight = ...

local preflight = {}

local function newReport()
    return { ok = true, items = {}, byId = {} }
end

-- kind is the severity if this item is not ok. A passing item is always "good".
local function add(report, id, ok, kind, text, cost)
    local item = {
        id = id, ok = ok, kind = ok and "good" or kind,
        text = text, cost = not ok and cost or nil,
    }
    report.items[#report.items + 1] = item
    report.byId[id] = item
    if not ok and kind == "bad" then report.ok = false end
    return item
end

-- Everything the failing items said, worst first, which is the order a popup
-- lists them in and the order a status line takes its one line from.
function preflight.failures(report)
    local bad, warn = {}, {}
    for _, item in ipairs(report.items) do
        if not item.ok then
            if item.kind == "bad" then bad[#bad + 1] = item else warn[#warn + 1] = item end
        end
    end
    for _, item in ipairs(warn) do bad[#bad + 1] = item end
    return bad
end

-- == THE SHIP ITSELF =========================================

function preflight.check(ship, cal, fuel, turbine, config, link)
    local report = newReport()

    local state, fault = ship.readState()
    add(report, "sable", state ~= nil, "bad",
        state and "pose reads" or ("no pose: " .. tostring(fault)),
        "nothing on this computer knows where the ship is, so a leg would be flown blind")

    local turbines = turbine.status()
    local tanks = fuel.status()
    local noModem = turbines.link == "nomodem" and tanks.link == "nomodem"
    add(report, "modem", not noModem, "bad",
        noModem and "no modem on this computer" or "modem open",
        "every propeller on this ship is on a relay and none of them can be reached")

    -- A relay that has gone quiet is worse than one that never spoke, because
    -- the quiet one was flying the ship a moment ago.
    local silent = {}
    for _, one in ipairs(turbines.relays or {}) do
        if one.link == "stale" then silent[#silent + 1] = one.relayId end
    end
    if #silent > 0 then
        local names = {}
        for _, id in ipairs(silent) do names[#names + 1] = "#" .. tostring(id) end
        add(report, "relays", false, "bad",
            "relay " .. table.concat(names, " and ") .. " stopped answering",
            "its propellers have already stopped themselves and will not take an order")
    else
        add(report, "relays", true, "bad",
            string.format("%d relay(s) answering", #(turbines.relays or {})))
    end

    local left = #cal.linesOfSide("left")
    local right = #cal.linesOfSide("right")
    add(report, "steer", left > 0 and right > 0, "bad",
        string.format("%d propeller(s) on the left, %d on the right", left, right),
        "a tank turn is one side against the other, so with a side missing the ship cannot point itself")

    local main = #cal.linesOfSide("main")
    add(report, "cruise", main + left + right > 0, "bad",
        string.format("%d propeller(s) pushing forward", main + left + right),
        "there is nothing to run at the target with")

    local hasBalloon = turbine.hasBalloon()
    add(report, "balloon", hasBalloon == true, "bad",
        hasBalloon and "the balloon is on a relay that is answering"
            or "no relay is holding the balloon",
        "nothing here controls lift, and lift is the only thing keeping the ship up")

    -- Two ways for fuel to fail a check and they are not the same failure. Not
    -- knowing is a warning, because the ship still flies. Knowing and it being
    -- almost gone is not.
    local level = (tanks.fraction or 0) * 100
    if tanks.link == "live" or tanks.link == "stale" then
        add(report, "fuel", level > config.get("fuelCrit"), "bad",
            string.format("%d%% in the tanks", math.floor(level + 0.5)),
            "the leg begins on fuel the captain already called critical")
    else
        add(report, "fuel", false, "warn", "the fuel relay has not spoken",
            "the leg is flown without knowing how much is left to fly it with")
    end

    -- Which end is the front, which is the one thing about this ship no sensor
    -- can answer and so the one thing a pilot has to have confirmed by hand.
    --
    -- Two failures, and they are not the same failure. Never having been asked
    -- is a warning: the ship flies, it just flies on a front offset of nothing
    -- and a screen that may disagree with the sky. Thrust and the front
    -- pointing opposite ways is a refusal, because that ship runs away from
    -- every target it is given and does it at cruise speed.
    if cal.frontOffset and cal.noseOffset then
        local apart = math.abs(util.wrapAngle(cal.frontOffset - cal.noseOffset))
        local backwards = apart >= 180 - config.get("calFlipTol")
        add(report, "front", not backwards, "bad",
            backwards
                and string.format("the front and the thrust are %.0f degrees apart", apart)
                or string.format("the front sits %+.1f degrees off the hull", cal.frontOffset),
            "the propellers are filed the wrong way round, so the ship flies away from the target")
    elseif not cal.frontOffset then
        add(report, "front", false, "warn", "nobody has confirmed which end is the front",
            "every heading on the screen is the hull's own axis, which is not always the way the ship faces")
    else
        add(report, "front", true, "warn",
            string.format("the front sits %+.1f degrees off the hull", cal.frontOffset))
    end

    -- What was measured against what is here now. cal answers this one fully,
    -- each difference already in its own words, so the first of them is the
    -- text and the rest go on the CAL tab.
    local inventoryOk, differences = cal.inventoryCheck()
    add(report, "inventory", inventoryOk, "bad",
        differences[1] and differences[1].text or "the ship is the one that was measured",
        "the numbers the autopilot flies by were measured on a different ship")
    report.byId.inventory.detail = differences

    -- The passcode, and only the half of it that has a physical consequence.
    -- Being unpaired is a warning: the ship flies, and that is the state every
    -- ship is in before the installer has been round all four computers. A
    -- relay answering with a different passcode is a refusal, because it looks
    -- exactly like a relay that is there and works and will not take an order.
    local pass = link and link.status()
    if pass and pass.refused > 0 then
        add(report, "passcode", false, "bad",
            string.format("%d message(s) refused, last from computer #%s",
                pass.refused, tostring(pass.refusedFrom)),
            "something on this protocol is not part of this ship, or a relay was paired to a different passcode")
    elseif pass and not pass.paired then
        add(report, "passcode", false, "warn", "no passcode set on this computer",
            "any ship in range on this protocol can drive these propellers, and this one obeys it")
    else
        add(report, "passcode", true, "bad", "paired")
    end

    local unmeasured = {}
    for _, row in ipairs(cal.summary()) do
        if not row.done then unmeasured[#unmeasured + 1] = row.title:lower() end
    end
    add(report, "curves", #unmeasured == 0, "bad",
        #unmeasured == 0 and "every stage measured"
            or ("never measured: " .. table.concat(unmeasured, ", ")),
        "the ship would be flown on the defaults, which describe no vessel in particular")

    return report
end

-- == THE LEG =================================================
--
-- Two resources, two different questions. Fuel buys time, so it is checked
-- against how long the leg takes. Stress buys thrust, so it is checked against
-- the hardest instant of the leg rather than against its length.
--
-- What a leg from where the ship is now to a point costs, in the shape forLeg
-- wants. It lives here rather than in cmd.lua so the bearing is worked out by
-- the same function the controller steers on, not by a second copy of an atan.
function preflight.planFor(ship, cal, config, to)
    local state = ship.readState()
    if not state or not to then return nil end
    local p = state.position
    local dx, dz = to.x - p.x, to.z - p.z
    return {
        dist = math.sqrt(dx * dx + dz * dz),
        headingChange = util.wrapAngle(flight.bearingTo(p.x, p.z, to.x, to.z) - state.yaw),
        altChange = (to.y or p.y) - p.y,
        cal = cal,
        cfg = config.values,
    }
end

-- `plan` is { dist, headingChange, altChange, cal, cfg }. The report from
-- check() is passed back in so the two halves are one answer: a leg is arguable
-- only once the ship itself is.
function preflight.forLeg(report, fuelStatus, stress, plan)
    local out = newReport()
    out.ok = report.ok

    local cfg = plan.cfg
    local seconds = flight.legTime(plan.dist, plan.headingChange, plan.altChange,
        plan.cal, cfg)
    out.seconds = seconds

    local endurance = fuelStatus and fuelStatus.endurance or nil
    if not endurance then
        add(out, "fuelTime", true, "warn",
            "nothing is burning, so the leg costs no time that can be counted")
    else
        local needed = seconds * cfg.fuelMargin
        add(out, "fuelTime", endurance >= needed, "bad",
            string.format("the leg takes %s and there is %s of fuel to spend",
                util.fmtETA(seconds), util.fmtETA(endurance)),
            string.format("it runs out about %s short of the target",
                util.fmtETA(math.max(0, needed - endurance))))
    end

    if not cfg.requireStressBudget then
        add(out, "stressBudget", true, "warn", "the stress budget is not being checked")
    elseif not (stress and stress.stressOk and stress.capacity) then
        add(out, "stressBudget", true, "warn",
            "no stressometer on any relay, so the budget cannot be checked")
    else
        local worst = math.max(flight.stressNeeded("tank", plan.cal),
            flight.stressNeeded("cruise", plan.cal))
        local spare = stress.capacity - (stress.stress or 0)
        add(out, "stressBudget", worst <= stress.capacity, "bad",
            string.format("the hardest part of the leg draws %.0f su and the network carries %.0f",
                worst, stress.capacity),
            string.format("the kinetic network stops, and with %.0f su spare it stops during the turn",
                spare))
    end

    for _, item in ipairs(out.items) do
        if not item.ok and item.kind == "bad" then out.ok = false end
    end
    return out
end

return preflight
