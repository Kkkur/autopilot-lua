-- popup.lua -- what a modal says, without any of the drawing.
--
-- Pure, for the same reason preflight.lua is: the interesting part of a modal
-- is not the box, it is the sentence that tells a pilot what pressing the key
-- will cost. A descriptor is a table and nothing here touches a screen, so
-- every one of those sentences is checkable under `starcatcher --test`.
--
--   severity  "alarm" | "warn" | "info"
--   title     the one line across the top
--   lines     what happened
--   cost      what it means for the ship
--   choices   { key, label, action }, the action being what the caller gets back
--
-- A line is { text, kind }, kind being the colour hint the rest of the program
-- already speaks: good, warn, bad, dim, accent.
--
-- One rule holds across all of these and is a safety property rather than a
-- preference: a popup never parks the control loop. ui.runWizard parks it on
-- purpose because the wizard has its hands on the propellers. A modal that
-- stopped the balloon being commanded would drop the ship out of the sky while
-- the pilot read it.

local util = ...

local popup = {}

local function say(list, kind, fmt, ...)
    list[#list + 1] = { text = select("#", ...) > 0 and string.format(fmt, ...) or fmt,
        kind = kind or "hi" }
end

-- == THE GATE ================================================

-- What the checker found, and what flying anyway would mean. The failing items
-- carry both sentences themselves, so this arranges rather than writes.
function popup.preflight(report, what)
    local lines, cost = {}, {}
    for _, item in ipairs((report and report.items) or {}) do
        if not item.ok then
            say(lines, item.kind, "%s", item.text)
            if item.cost then say(cost, "dim", "%s", item.cost) end
        end
    end
    if #lines == 0 then say(lines, "good", "nothing is wrong with this ship") end

    return {
        severity = report and report.ok and "warn" or "alarm",
        title = "NOT READY TO " .. string.upper(what or "FLY"),
        lines = lines,
        cost = cost,
        choices = {
            { key = "f", label = "fly anyway", action = "override" },
            { key = "c", label = "cancel", action = "cancel" },
        },
    }
end

-- The whole checklist, asked for rather than triggered. `check` is what a pilot
-- types before untying, so it lists what passed as well as what did not: a
-- popup that only ever shows failures cannot tell the difference between a ship
-- that is ready and a checker that is not running.
function popup.report(report)
    local lines, cost = {}, {}
    for _, item in ipairs((report and report.items) or {}) do
        if item.ok then
            say(lines, "good", "%s", item.id)
        else
            say(lines, item.kind, "%s", item.text)
            if item.cost then say(cost, "dim", "%s", item.cost) end
        end
    end
    if #lines == 0 then say(lines, "dim", "the checker returned nothing at all") end
    return {
        severity = report and report.ok and "info" or "warn",
        title = report and report.ok and "READY TO FLY" or "NOT READY TO FLY",
        lines = lines,
        cost = cost,
        choices = { { key = "enter", label = "close", action = "done" } },
    }
end

-- The fuel gate is its own popup because the answer is a quantity rather than a
-- list: how far short it runs, in the two units a pilot thinks in.
function popup.fuelShortfall(shortSeconds, shortBlocks)
    local lines, cost = {}, {}
    say(lines, "bad", "the tanks do not hold enough for this leg")
    say(cost, "warn", "about %s short", util.fmtETA(math.max(0, shortSeconds or 0)))
    if shortBlocks and shortBlocks > 0 then
        say(cost, "warn", "which is roughly %.0f blocks before the target", shortBlocks)
    end
    say(cost, "dim", "the engine burns at a flat rate, so throttling back buys nothing")
    return {
        severity = "warn",
        title = "NOT ENOUGH FUEL",
        lines = lines,
        cost = cost,
        choices = {
            { key = "f", label = "fly anyway", action = "override" },
            { key = "c", label = "cancel", action = "cancel" },
        },
    }
end

-- Taking control by hand with something missing. Same failures, different
-- consequence: by hand the pilot is the loop that is missing, which is worth
-- saying out loud rather than reusing the autopilot's wording.
function popup.manualOverride(report)
    local lines, cost = {}, {}
    for _, item in ipairs((report and report.items) or {}) do
        if not item.ok then say(lines, item.kind, "%s", item.text) end
    end
    say(cost, "warn", "by hand there is nothing between a throttle and the ground")
    say(cost, "dim", "the balloon is still commanded, and only the balloon")
    return {
        severity = "warn",
        title = "TAKE CONTROL ANYWAY",
        lines = lines,
        cost = cost,
        choices = {
            { key = "t", label = "take control", action = "override" },
            { key = "c", label = "cancel", action = "cancel" },
        },
    }
end

-- == IN FLIGHT ===============================================

function popup.altitudeChange(fromY, toY)
    local delta = (toY or 0) - (fromY or 0)
    local lines, cost = {}, {}
    say(lines, "warn", "this leg %s %.0f blocks, from %.0f to %.0f",
        delta >= 0 and "climbs" or "descends", math.abs(delta), fromY or 0, toY or 0)
    say(cost, "dim", delta >= 0
        and "climbing is the expensive axis and the balloon is the only way up"
        or "descending is the cheap way to lose a ship, so it is worth meaning it")
    return {
        severity = "info",
        title = delta >= 0 and "CLIMB" or "DESCENT",
        lines = lines,
        cost = cost,
        choices = {
            { key = "y", label = "change altitude", action = "change" },
            { key = "k", label = "keep this height", action = "keep" },
            { key = "c", label = "cancel the leg", action = "cancel" },
        },
    }
end

function popup.overstressed(status)
    local lines, cost = {}, {}
    if status and status.overstressed then
        say(lines, "bad", "the kinetic network has stopped")
    else
        say(lines, "bad", "stress is at %d%% of what the network carries",
            math.floor((status and status.fraction or 0) * 100 + 0.5))
    end
    if status and status.worstRelay then
        say(lines, "dim", "worst on relay #%d", status.worstRelay)
    end
    say(cost, "warn", "a network that stops stops every propeller on it at once")
    say(cost, "dim", "easing off keeps the ship flying at whatever it can afford")
    return {
        severity = "alarm",
        title = "OVERSTRESSED",
        lines = lines,
        cost = cost,
        choices = {
            { key = "h", label = "safe hold", action = "hold" },
            { key = "e", label = "ease the throttle", action = "ease" },
            { key = "p", label = "press on", action = "press" },
        },
    }
end

function popup.pitch(pitch, limit)
    local lines, cost = {}, {}
    say(lines, "bad", "the nose is %.0f degrees down, past the %.0f it was allowed",
        math.abs(pitch or 0), limit or 0)
    say(cost, "warn", "a hull that tips far enough stops pushing where it is pointing")
    say(cost, "dim", "easing off spreads the stop over more distance instead")
    return {
        severity = "alarm",
        title = "NOSING OVER",
        lines = lines,
        cost = cost,
        choices = {
            { key = "h", label = "safe hold", action = "hold" },
            { key = "e", label = "ease the brake", action = "ease" },
            { key = "p", label = "press on", action = "press" },
        },
    }
end

-- The loud one. A part going quiet in the air is the alarm the whole severity
-- field exists for, and the ship is already in a safe hold by the time it is
-- drawn: thrust at zero, the leg abandoned, the heading left alone and the
-- balloon held where it was. The choices are what to do next, not whether to
-- act, because waiting for an answer before acting is how the answer arrives
-- too late.
function popup.partLost(what, detail)
    local lines, cost = {}, {}
    say(lines, "bad", "%s", what or "a part of the ship")
    if detail then say(lines, "dim", "%s", detail) end
    say(cost, "warn", "thrust is at zero and the leg is abandoned")
    say(cost, "warn", "the balloon is holding the level it was already holding")
    say(cost, "dim", "it is not descending: the computer that would fly a descent may be the quiet one")
    return {
        severity = "alarm",
        title = "PART LOST IN FLIGHT",
        lines = lines,
        cost = cost,
        choices = {
            { key = "h", label = "keep holding", action = "hold" },
            { key = "r", label = "fly on without it", action = "resume" },
            { key = "s", label = "all stop", action = "stop" },
        },
    }
end

-- == ONE SETTING =============================================

-- The TUNE tab's editor: what the setting does, what the ship is doing when you
-- reach for it, and what the value means on this hull once it has been run back
-- through the measured curves. The preview is the part that turns a number into
-- a decision, and it is absent rather than invented when the stage that would
-- have measured it has not been run.
--
-- `typed` is whatever the pilot has keyed in so far. It is shown rather than
-- applied, because a value that took effect halfway through being typed would
-- fly the ship at 2 on the way to 25.
function popup.setting(entry, value, preview, typed)
    local lines, cost = {}, {}
    say(lines, "hi", "%s", entry.help or entry.key)
    if entry.symptom then say(lines, "dim", "reach for it when %s", entry.symptom) end
    say(cost, "dim", "now %s, default %s", tostring(value), tostring(entry.def))
    if entry.min and entry.max then
        say(cost, "dim", "between %g and %g", entry.min, entry.max)
    end
    if preview then say(cost, "accent", "%s", preview) end
    if typed and typed ~= "" then say(cost, "warn", "typing: %s", typed) end
    return {
        severity = "info",
        title = string.upper(entry.key),
        lines = lines,
        cost = cost,
        choices = {
            { key = "enter", label = "done", action = "done" },
            { key = "r", label = "default", action = "reset" },
        },
    }
end

-- The same editor for something calibration measured rather than something the
-- pilot chose. Hand editing is allowed, and the one thing this has to say that
-- the settings popup does not is that the next run of that stage overwrites it.
-- A pilot who finds that out by watching a good number disappear learns the same
-- fact at the worst possible moment.
function popup.measured(entry, value, typed)
    local lines, cost = {}, {}
    say(lines, "hi", "%s", entry.help or entry.id)
    if value == nil then
        say(lines, "warn", "not measured yet. Run the %s stage, or type it in.", entry.stage)
    else
        say(lines, "dim", "measured by the %s stage", entry.stage)
    end
    say(cost, "dim", "now %s %s", value and string.format("%.4g", value) or "unmeasured",
        entry.unit or "")
    say(cost, "warn", "running the %s stage again overwrites whatever is typed here",
        entry.stage)
    if typed and typed ~= "" then say(cost, "warn", "typing: %s", typed) end
    return {
        severity = "info",
        title = string.upper(entry.title or entry.id),
        lines = lines,
        cost = cost,
        choices = {
            { key = "enter", label = "done", action = "done" },
            { key = "c", label = "cancel", action = "cancel" },
        },
    }
end

-- == THE WIZARD ASKS =========================================
--
-- Calibration measures the ship and is sometimes wrong about it, and the only
-- thing in the room that can tell is the pilot. These are the questions it asks
-- when it is about to overwrite something it worked out itself. They are
-- popups rather than another line of wizard log on purpose: a line scrolls
-- past, and what is being decided here is which way round the ship is.
--
-- Enter is the answer that changes nothing, on every one of these. A pilot
-- pressing it to get past a box has not agreed to have their calibration
-- rewritten, and the one box where nothing-to-change is not a choice, the front
-- confirmation, spends Enter on "not sure" rather than on "yes".
--
-- Nothing here parks anything. The control loop is already out of the
-- propellers for the whole wizard, which is the one place in the program where
-- that is true.

-- Thrust and the front of the ship pointing opposite ways. Whatever measured
-- it, the meaning is the same: every line is filed the wrong way round, and
-- the ship will fly away from anything it is sent to.
function popup.calBackwards(detail, evidence)
    local lines, cost = {}, {}
    say(lines, "bad", "%s", detail)
    for _, item in ipairs(evidence or {}) do say(lines, "dim", "%s", item) end
    say(cost, "warn", "turning them round reverses thrust and leaves the turn alone")
    say(cost, "dim", "the two sides swap with them, which is what keeps the yaw ladder")
    return {
        severity = "alarm",
        title = "THE SHIP IS FILED BACKWARDS",
        lines = lines,
        cost = cost,
        choices = {
            { key = "t", label = "turn every line round", action = "flip" },
            { key = "enter", label = "leave it as it is", action = "leave" },
        },
    }
end

-- The turn running away instead of arriving. Left and right are the wrong way
-- round, which is one mistake made once, because every line was read against
-- the same yaw.
function popup.calHandedness(detail, evidence)
    local lines, cost = {}, {}
    say(lines, "bad", "%s", detail)
    for _, item in ipairs(evidence or {}) do say(lines, "dim", "%s", item) end
    say(cost, "warn", "swapping them turns the ship the other way for the same command")
    say(cost, "dim", "an autopilot that steers the wrong way never arrives at all")
    return {
        severity = "alarm",
        title = "THE TURN GOES THE WRONG WAY",
        lines = lines,
        cost = cost,
        choices = {
            { key = "s", label = "swap left and right", action = "swap" },
            { key = "enter", label = "leave it as it is", action = "leave" },
        },
    }
end

-- A better reading of something already measured. Both numbers are on the
-- screen with what each was measured over, because a pilot asked to replace a
-- number they cannot see is a pilot pressing whichever key is nearest.
function popup.calReplace(title, what, oldValue, newValue, unit, over)
    local lines, cost = {}, {}
    say(lines, "hi", "%s", what)
    say(lines, oldValue == nil and "warn" or "dim", "now      %s %s",
        oldValue and string.format("%+.1f", oldValue) or "never measured", unit or "")
    say(lines, "good", "measured  %+.1f %s", newValue or 0, unit or "")
    if over then say(cost, "dim", "%s", over) end
    say(cost, "warn", "the autopilot steers by this number on every leg")
    return {
        severity = "info",
        title = string.upper(title),
        lines = lines,
        cost = cost,
        choices = {
            { key = "t", label = "take the new one", action = "take" },
            { key = "enter", label = "keep what is there", action = "keep" },
        },
    }
end

-- Points of the rose the front came out not facing, once the half turn and
-- the mirror were both settled. The two flips are still offered, because a
-- single bad turn should not throw away seven good answers, but a pilot who
-- keeps them should know how many points disagreed with them.
function popup.calRose(wrong, total, offset, mirror)
    local lines, cost = {}, {}
    say(lines, "warn", "on %d of %d points the front was not facing the way it was sent",
        wrong or 0, total or 0)
    say(lines, "dim", "and by then neither the front nor the rose had anything left to learn")
    say(cost, "hi", "the front sits %+.1f degrees off the hull%s", offset or 0,
        mirror == -1 and ", on a mirrored rose" or "")
    say(cost, "dim", "one point is a turn that landed badly, several is a hull these two flips do not describe")
    return {
        severity = "warn",
        title = "THE ROSE DISAGREES",
        lines = lines,
        cost = cost,
        choices = {
            { key = "enter", label = "keep both flips", action = "keep" },
            { key = "d", label = "throw the stage away", action = "drop" },
        },
    }
end

-- What the rose settled, put in front of the pilot as a sentence rather than
-- as the arithmetic. The stage asked yes or no eight times and this is what
-- those answers came to, so the last word on it is also yes or no.
function popup.calFrontFlip(offset, mirror, wrong, total)
    local lines, cost = {}, {}
    local half = math.abs(math.abs(offset or 0) - 180) < 1
    say(lines, half and "warn" or "hi", half
        and "the front is the other end of the hull from its own +Z"
        or string.format("the front sits %+.1f degrees off the hull", offset or 0))
    say(lines, mirror == -1 and "warn" or "dim", mirror == -1
        and "and the rose is mirrored: east and west are the other way round"
        or "and the rose is the way round the compass is")
    say(lines, (wrong or 0) > 0 and "warn" or "good",
        "%d of %d points came out facing the way they were sent",
        (total or 0) - (wrong or 0), total or 0)
    say(cost, "dim", "this is what the screens will read in from now on")
    say(cost, "warn", "if that does not match what you can see, run the stage again")
    return {
        severity = "info",
        title = "WHICH WAY ROUND THIS SHIP IS",
        lines = lines,
        cost = cost,
        choices = {
            { key = "enter", label = "that is the front", action = "confirm" },
            { key = "a", label = "run it again", action = "again" },
        },
    }
end

-- The question the alignment stages exist for. The program cannot see the ship
-- and the pilot cannot see the pose, so this is the one place the two are put
-- side by side and the pilot is asked which of them is lying.
function popup.calFront(seen, pose, offset)
    local lines, cost = {}, {}
    say(lines, "hi", "you read       %+.1f degrees", seen or 0)
    say(lines, "hi", "the pose says  %+.1f degrees", pose or 0)
    say(lines, math.abs(offset or 0) < 1 and "good" or "warn",
        "the front sits %+.1f degrees off the hull", offset or 0)
    say(cost, "dim", "this is what the screens will read in from now on")
    say(cost, "warn", "if that does not match what you can see, read it again")
    return {
        severity = "info",
        title = "WHERE THE FRONT IS",
        lines = lines,
        cost = cost,
        choices = {
            { key = "y", label = "that is right", action = "confirm" },
            { key = "r", label = "read it again", action = "again" },
            -- Enter is neither of those on purpose. A pilot who presses it
            -- without looking at the ship has not confirmed anything, and
            -- confirming is exactly what preflight will believe afterwards.
            { key = "enter", label = "not sure", action = "unsure" },
        },
    }
end

return popup
