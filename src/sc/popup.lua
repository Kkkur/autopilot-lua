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

return popup
