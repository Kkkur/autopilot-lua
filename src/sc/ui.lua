-- ui.lua -- the screen and the keyboard.
--
-- One window, drawn off-screen and flipped, so nothing ever flickers. Eight
-- tabs, because a flight computer that fits everything on one screen is either
-- lying or unreadable, and a command line at the bottom that is always live:
-- you can type `goto dock` while the CAL tab is up.
--
-- Everything the pilot can do has both a key and a command. Keys are for
-- flying, commands are for saying exactly what you mean.

local util, ship, cal, control, nav, fuel, turbine, config, log, telemetry, flight, popup,
    link = ...

local ui = {}

local W, H = term.getSize()
local win = window.create(term.current(), 1, 1, W, H)

ui.TABS = { "FLIGHT", "MANUAL", "PROPS", "NAV", "CAL", "TUNE", "FUEL", "LOG" }

-- Named, because the tab a command wants to put up was a bare number in five
-- files and inserting MANUAL in the middle would have moved every one of them
-- silently. Anything that sets ui.tab says which tab it means.
ui.TAB = {}
for index, name in ipairs(ui.TABS) do ui.TAB[name] = index end

ui.tab = ui.TAB.FLIGHT
ui.sel = { nav = 1, tune = 1, props = 1 }
ui.tuneGroup = 1
ui.logScroll = 0
ui.input = ""
ui.history = {}
ui.historyAt = nil
ui.message = nil          -- transient line under the status bar
ui.messageKind = "hi"
ui.onCommand = nil        -- set by the host
ui.busy = false           -- a wizard owns the screen
ui.popup = nil            -- a modal descriptor owns the screen and the keyboard

-- == COLOURS =================================================

local FULL = {
    bg = colours.black, panel = colours.grey, accent = colours.cyan,
    hi = colours.white, dim = colours.lightGrey, good = colours.lime,
    warn = colours.orange, bad = colours.red, bar = colours.cyan,
    barBg = colours.grey, tabOn = colours.cyan, tabOff = colours.grey,
    ink = colours.black,
}

local MONO = {
    bg = colours.black, panel = colours.grey, accent = colours.white,
    hi = colours.white, dim = colours.lightGrey, good = colours.white,
    warn = colours.lightGrey, bad = colours.white, bar = colours.lightGrey,
    barBg = colours.grey, tabOn = colours.white, tabOff = colours.grey,
    ink = colours.black,
}

local function C(name)
    local colourful = term.isColour() and config.get("colorful") ~= false
    return (colourful and FULL or MONO)[name] or colours.white
end

-- == PRIMITIVES ==============================================

local function clear(bg)
    win.setBackgroundColour(bg or C("bg"))
    win.clear()
end

local function at(x, y, text, fg, bg)
    if y < 1 or y > H then return end
    win.setCursorPos(x, y)
    win.setTextColour(fg or C("hi"))
    win.setBackgroundColour(bg or C("bg"))
    win.write(tostring(text))
end

local function line(y, text, fg, bg)
    if y < 1 or y > H then return end
    text = tostring(text)
    if #text > W then text = text:sub(1, W) end
    at(1, y, text .. string.rep(" ", W - #text), fg, bg)
end

local function rule(y, label)
    local text = label and ("-- " .. label .. " ") or ""
    line(y, text .. string.rep("-", math.max(0, W - #text)), C("panel"))
end

-- A bar drawn as coloured background rather than as characters. Reads as a
-- solid block on any font, which "#" and "=" never quite do.
local function bar(x, y, width, frac, fg, bg)
    frac = util.clamp(frac or 0, 0, 1)
    local filled = util.round(width * frac)
    if filled > 0 then
        at(x, y, string.rep(" ", filled), C("ink"), fg or C("bar"))
    end
    if width - filled > 0 then
        at(x + filled, y, string.rep(" ", width - filled), C("ink"), bg or C("barBg"))
    end
end

-- Signed bar: zero in the middle, fills left for negative, right for positive.
-- This is the shape a propeller demand actually has.
local function biBar(x, y, width, value, maxValue, fg)
    local half = math.floor(width / 2)
    local frac = util.clamp((value or 0) / (maxValue ~= 0 and maxValue or 1), -1, 1)
    at(x, y, string.rep(" ", width), C("ink"), C("barBg"))
    local cells = util.round(math.abs(frac) * half)
    if cells > 0 then
        if frac < 0 then
            at(x + half - cells, y, string.rep(" ", cells), C("ink"), fg or C("bar"))
        else
            at(x + half + 1, y, string.rep(" ", cells), C("ink"), fg or C("bar"))
        end
    end
    at(x + half, y, "|", C("dim"), C("barBg"))
end

-- Thousands separators, because 14200 and 142000 are the same shape at a
-- glance and one of them is ten times the fuel.
local function comma(n)
    local text = tostring(math.floor((n or 0) + 0.5))
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Fuel is coloured against the captain's own thresholds rather than a fixed
-- third and two thirds, since what counts as low depends on the ship.
local function fuelColour(fraction)
    if not fraction then return C("dim") end
    local level = fraction * 100
    if level <= config.get("fuelCrit") then return C("bad") end
    if level <= config.get("fuelWarn") then return C("warn") end
    return C("good")
end

-- Greedy word wrap. The advice panel writes sentences, not fields, and a
-- sentence that runs off the right hand edge loses the half that mattered.
-- Stress is coloured the same way, against the captain's thresholds. It reads
-- backwards from fuel: here a high number is the bad one.
local function stressColour(fraction)
    if not fraction then return C("dim") end
    local level = fraction * 100
    if level >= config.get("stressCrit") then return C("bad") end
    if level >= config.get("stressWarn") then return C("warn") end
    return C("good")
end

local function wrapText(text, width)
    local out, current = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if current == "" then
            current = word
        elseif #current + 1 + #word <= width then
            current = current .. " " .. word
        else
            out[#out + 1] = current
            current = word
        end
    end
    if current ~= "" then out[#out + 1] = current end
    return out
end

local function kindColour(kind)
    if kind == "good" then return C("good") end
    if kind == "warn" then return C("warn") end
    if kind == "bad" then return C("bad") end
    if kind == "dim" then return C("dim") end
    if kind == "accent" then return C("accent") end
    return C("hi")
end

-- A reply to a command sits over the flight status for a few seconds and then
-- gets out of the way. A sticky one would hide the phase the ship is actually
-- in, which is the line you want when you look up mid-flight.
ui.MESSAGE_SECONDS = 8

function ui.say(text, kind)
    ui.message = text
    ui.messageKind = kind or "hi"
    ui.messageAt = os.clock()
end

-- == PANE ====================================================
--
-- A tab body is built as a list of rows and then placed, rather than written
-- straight down the screen as it is composed. Almost every tab has rows to
-- spare: before this they all fell to the bottom as one dead block while the
-- readout above them sat shoulder to shoulder, which is what made a tab hard
-- to read without anything being wrong with what it said.
--
-- A gap is a request for air between two groups. It is spent only out of the
-- rows nothing else wanted, one at a time and evenly, so the tab that has
-- something to say on every line loses no room and the tab that has not comes
-- out spaced. Nothing is ever dropped to make a gap.
local Pane = {}
Pane.__index = Pane

local function pane(top, bottom)
    return setmetatable({ top = top or 2, bottom = bottom or (H - 2), items = {} },
        Pane)
end

-- fn(y) draws one row, and is called only once the row it lands on is known.
function Pane:row(fn)
    self.items[#self.items + 1] = { draw = fn }
    return self
end

function Pane:text(text, fg, bg)
    return self:row(function(y) line(y, text, fg, bg) end)
end

function Pane:rule(label)
    return self:row(function(y) rule(y, label) end)
end

-- weight is the most air this boundary can take. One row reads as a break
-- between groups; a large weight is how a tab pins what follows to the bottom.
function Pane:gap(weight)
    self.items[#self.items + 1] = { gap = weight or 1, rows = 0 }
    return self
end

-- How many rows are left for content, so a list knows how much of itself fits
-- before it starts queueing rows that would be cut off the bottom.
function Pane:left()
    local used = 0
    for _, item in ipairs(self.items) do
        if item.draw then used = used + 1 end
    end
    return self.bottom - self.top + 1 - used
end

function Pane:place()
    local free = self:left()
    local gaps = {}
    for _, item in ipairs(self.items) do
        if item.gap then item.rows = 0; gaps[#gaps + 1] = item end
    end
    -- Round robin rather than first come first served: two groups either side
    -- of a tab both want the same air, and handing it all to the first gap
    -- pushes everything below it into the same huddle this is meant to undo.
    local handed = true
    while free > 0 and handed do
        handed = false
        for _, gap in ipairs(gaps) do
            if free > 0 and gap.rows < gap.gap then
                gap.rows = gap.rows + 1
                free = free - 1
                handed = true
            end
        end
    end

    local y = self.top
    for _, item in ipairs(self.items) do
        if y > self.bottom then break end
        if item.draw then
            item.draw(y)
            y = y + 1
        else
            for _ = 1, item.rows do
                if y > self.bottom then break end
                line(y, "", C("bg"))
                y = y + 1
            end
        end
    end
    while y <= self.bottom do line(y, "", C("bg")); y = y + 1 end
end

-- == CHROME ==================================================

-- The tabs are cells of equal width rather than labels with spaces between
-- them, and the cells tile the bar exactly: every column belongs to some tab,
-- so a click can never land in a gap. The remainder of the division is handed
-- out one column at a time from the left instead of being left over at the
-- right, where it would read as a dead strip.
--
-- drawTabs and handleClick both lay the bar out through here. Two layouts that
-- disagree by a column is a pilot pressing FUEL and getting TUNE.
local CLOCK_WIDTH = 8       -- HH:MM:SS

-- Widest name plus a column of air each side, so no two labels ever touch.
local function roomiestCell()
    local longest = 0
    for _, name in ipairs(ui.TABS) do
        if #name > longest then longest = #name end
    end
    return longest + 2
end

-- The clock is the cheapest proof the loop is still running, but it is worth
-- less than legible tabs, so it only gets its corner when the tabs can still
-- have their full cells without it. On a 51 column computer they cannot, and
-- the clock goes.
local function tabBarWidth()
    local withClock = W - (CLOCK_WIDTH + 1)
    if withClock >= roomiestCell() * #ui.TABS then return withClock end
    return W
end

local function tabLabels()
    local avail = tabBarWidth()
    local base = math.floor(avail / #ui.TABS)
    local extra = avail % #ui.TABS
    local labels = {}
    for index, name in ipairs(ui.TABS) do
        local width = base + (index <= extra and 1 or 0)
        -- A pocket screen cannot spell FLIGHT in four columns. Cutting it is
        -- still better than dropping the tab off the edge, where it cannot be
        -- clicked at all.
        local text = #name > width and name:sub(1, width) or name
        local pad = width - #text
        local left = math.floor(pad / 2)
        labels[index] = string.rep(" ", left) .. text .. string.rep(" ", pad - left)
    end
    return labels
end

local function drawTabs()
    win.setCursorPos(1, 1)
    win.setBackgroundColour(C("tabOff"))
    win.setTextColour(C("ink"))
    win.write(string.rep(" ", W))
    local x = 1
    for index, label in ipairs(tabLabels()) do
        local active = index == ui.tab
        at(x, 1, label, active and C("ink") or C("hi"), active and C("tabOn") or C("tabOff"))
        x = x + #label
    end
    if tabBarWidth() < W then
        at(W - CLOCK_WIDTH + 1, 1, log.timestamp(), C("ink"), C("tabOff"))
    end
end

local function drawStatusBar(snap)
    local y = H - 1
    local engaged = snap.running and " ENGAGED " or "  IDLE   "
    at(1, y, string.rep(" ", W), C("hi"), C("bg"))
    at(1, y, engaged, C("ink"), snap.running and C("good") or C("panel"))
    local fresh = ui.message and (os.clock() - (ui.messageAt or 0)) < ui.MESSAGE_SECONDS
    local text = (fresh and ui.message) or snap.status or ""
    local kind = fresh and ui.messageKind or snap.statusKind
    at(#engaged + 2, y, text:sub(1, math.max(0, W - #engaged - 2)), kindColour(kind), C("bg"))
end

-- The command line. Tab completes against commands and waypoint names, and the
-- completion is shown greyed ahead of the cursor rather than guessed silently.
local completions = {}

function ui.setCompletions(list)
    completions = list or {}
end

local function completeFor(text)
    if text == "" then return nil end
    local head, rest = text:match("^(%S+)%s+(.*)$")
    local candidates, prefix
    if head then
        candidates = {}
        if head:lower() == "goto" or head:lower() == "del" or head:lower() == "route"
                or head:lower() == "delete" then
            -- Complete the last word of the tail against waypoint names.
            local before, last = rest:match("^(.-)([^%s]*)$")
            for _, name in ipairs(nav.names()) do
                if name:lower():sub(1, #last) == last:lower() and #last > 0 then
                    return head .. " " .. before .. name
                end
            end
            return nil
        elseif head:lower() == "set" or head:lower() == "get" then
            local before, last = rest:match("^(.-)([^%s]*)$")
            for _, entry in ipairs(config.SCHEMA) do
                if #last > 0 and entry.key:lower():sub(1, #last) == last:lower() then
                    return head .. " " .. before .. entry.key
                end
            end
            return nil
        end
        return nil
    end
    prefix = text:lower()
    candidates = completions
    for _, name in ipairs(candidates) do
        if name:sub(1, #prefix) == prefix then return name end
    end
    return nil
end

local function drawInput()
    local y = H
    at(1, y, string.rep(" ", W), C("hi"), C("bg"))
    at(1, y, "> ", C("accent"), C("bg"))
    at(3, y, ui.input, C("hi"), C("bg"))
    local guess = completeFor(ui.input)
    if guess and #guess > #ui.input then
        at(3 + #ui.input, y, guess:sub(#ui.input + 1), C("dim"), C("bg"))
    end
end

-- == TAB: FLIGHT =============================================
--
-- Rebuilt in stage 7 for the hull that is here. The tab it replaced drew three
-- axis rows, one per world axis, which described a ship that could strafe. This
-- one can do exactly two things: point itself, and push along the way it is
-- pointing, with a balloon underneath holding it up. So the tab is those three
-- questions in that order, each as want against have, and the phase ladder
-- across the top says which of them the autopilot is working on right now.

local PHASES = { { id = "tank", label = "TURN" }, { id = "cruise", label = "RUN" },
                 { id = "brake", label = "STOP" }, { id = "arrived", label = "HOLD" } }

-- The phase machine, drawn as the machine it is. A phase name on a status line
-- tells a pilot what is happening; the ladder tells them what happens next,
-- which is the thing worth knowing while watching a stop.
local function drawPhases(y, phase)
    local x = 2
    for index, entry in ipairs(PHASES) do
        local active = phase == entry.id
        at(x, y, " " .. entry.label .. " ", active and C("ink") or C("dim"),
            active and C("accent") or C("bg"))
        x = x + #entry.label + 2
        if index < #PHASES then
            at(x, y, ">", C("panel"), C("bg"))
            x = x + 1
        end
    end
    if phase == "safe" then
        at(x + 1, y, "SAFE HOLD", C("ink"), C("bad"))
    elseif phase == "manual" then
        at(x + 1, y, "BY HAND", C("ink"), C("warn"))
    end
end

-- want against have, with the demand that is meant to close the gap drawn as a
-- signed bar. Three rows of this is the whole ship: heading, speed, height.
--
-- The columns are fixed rather than formatted one after another, because the
-- three rows only read as a table if want sits under want on all three of them.
-- NOTE_AT is where the row's own extra number goes and is the last column the
-- text may use: everything from BAR_AT right belongs to the bar.
local WANT_AT, HAVE_AT, NOTE_AT, BAR_AT, BAR_WIDTH = 11, 19, 27, 38, 13

local function wantHave(y, label, want, have, demand, demandMax, colour)
    at(1, y, string.rep(" ", W), C("hi"), C("bg"))
    at(2, y, util.pad(label, WANT_AT - 3), C("dim"), C("bg"))
    at(WANT_AT, y, string.format("%7s", want and string.format("%+.1f", want) or "--"),
        colour or C("hi"), C("bg"))
    at(HAVE_AT, y, string.format("%7s", have and string.format("%+.1f", have) or "--"),
        colour or C("hi"), C("bg"))
    if demand ~= nil then
        biBar(BAR_AT, y, BAR_WIDTH, demand, demandMax)
    end
end

-- The row's own number, in the one column left between the table and the bar.
local function rowNote(y, text, colour)
    at(NOTE_AT, y, util.pad(tostring(text):sub(1, BAR_AT - NOTE_AT - 1),
        BAR_AT - NOTE_AT - 1), colour or C("dim"), C("bg"))
end

local function drawFlight(snap, reads)
    local p = pane()
    local state = snap.state
    local info = snap.info or {}

    -- Four groups, in the order a pilot asks the questions: where am I, what
    -- am I doing, how hard is the ship working at it, and what is it spending.
    if state then
        local pos = state.position
        p:text(string.format(" X %8.1f  Y %7.1f  Z %8.1f   %s", pos.x, pos.y, pos.z,
            util.compass(state.yaw)), C("hi"))
        p:text(string.format(" HDG %5.1f  SPD %5.2f m/s  VS %+5.2f  PITCH %+5.1f",
            state.yaw, state.speed, state.velocity.y, util.pitchOf(state.orientation)),
            C("dim"))
    else
        p:text(" position unavailable: " .. tostring(snap.fault), C("bad"))
        p:text(" nothing below this line is being flown", C("dim"))
    end

    p:gap()
    p:row(function(y) drawPhases(y, snap.phase) end)

    -- The leg. Distance and ETA belong next to the name of the thing they are
    -- distance and ETA to.
    if snap.target then
        local t = snap.target
        p:text(string.format(" %-10s %5d %4d %6d   %6.1f blk   %s",
            snap.targetName or "[coords]", util.round(t.x), util.round(t.y), util.round(t.z),
            snap.dist or 0, snap.eta and util.fmtETA(snap.eta) or "--"), C("warn"))
        if #nav.route > 0 then
            p:text(" then " .. table.concat(nav.route, " > "), C("dim"))
        end
    else
        p:text(" no target. `goto <name>` or `fly <x> <y> <z>`", C("dim"))
    end
    if snap.reason then
        p:text(" " .. tostring(snap.reason), C("dim"))
    end

    p:gap()
    p:row(function(y)
        rule(y)
        at(WANT_AT + 3, y, " WANT ", C("dim"), C("bg"))
        at(HAVE_AT + 3, y, " HAVE ", C("dim"), C("bg"))
    end)

    -- Heading: the error is what the turn is working on, so that is what is
    -- drawn rather than two absolute bearings a pilot has to subtract.
    local lined = math.abs(info.err or 0) <= config.get("tankPadding")
    p:row(function(y)
        if info.bearing then
            wantHave(y, "HDG deg", info.bearing, state and state.yaw,
                info.differential or 0, config.get("tankRpmMax"),
                lined and C("good") or C("hi"))
            rowNote(y, string.format("%+.1f off", info.err or 0),
                lined and C("good") or C("warn"))
        else
            wantHave(y, "HDG deg", nil, state and state.yaw, 0,
                config.get("tankRpmMax"), C("dim"))
        end
    end)

    p:row(function(y)
        wantHave(y, "SPD m/s", info.want, info.have, info.common or 0,
            config.get("cruiseMaxRpm"))
        local top = cal.topForward()
        rowNote(y, top and string.format("top %.1f", top) or "unmeasured")
    end)

    -- Lift is the one row that is not a propeller demand, so its bar is the
    -- strength itself: zero to fifteen, the whole range the balloon has.
    p:row(function(y)
        if info.balloon then
            local onFloor = info.balloon <= config.get("balloonFloor")
            at(1, y, string.rep(" ", W), C("hi"), C("bg"))
            at(2, y, util.pad("LIFT blk", WANT_AT - 3), C("dim"), C("bg"))
            at(WANT_AT, y, string.format("%7s",
                info.altErr and string.format("%+.1f", info.altErr) or "by hand"),
                onFloor and C("warn") or C("hi"), C("bg"))
            at(HAVE_AT, y, string.format("%7s", string.format("%d/15", info.balloon)),
                onFloor and C("warn") or C("hi"), C("bg"))
            rowNote(y, onFloor and "on the floor" or "")
            bar(BAR_AT, y, BAR_WIDTH, info.balloon / 15, onFloor and C("warn") or C("bar"))
        else
            line(y, " LIFT  no relay is holding the balloon", C("bad"))
        end
    end)

    -- Fuel and stress, one line each, on the tab the pilot actually watches. A
    -- level that only appears when you go looking for it is a level nobody sees
    -- until it is a problem.
    p:gap(2)
    local status = reads.fuel
    if status.link == "live" or status.link == "stale" then
        local text = string.format(" FUEL %3d%%  %s mB",
            math.floor(status.fraction * 100 + 0.5), comma(status.total))
        if status.burn > 0 then
            text = text .. "   " .. util.fmtETA(status.endurance) .. " to reserve"
        elseif status.filling then
            text = text .. "   filling"
        end
        if status.link == "stale" then text = text .. "   LINK LOST" end
        p:text(text, status.link == "stale" and C("bad") or fuelColour(status.fraction))
    end

    local turbines = reads.turbines
    if turbines.overstressed then
        p:text(" OVERSTRESSED. The kinetic network has stopped turning.", C("bad"))
    elseif turbines.link == "stale" then
        p:text(" A TURBINE RELAY HAS STOPPED ANSWERING", C("bad"))
    elseif turbines.fraction then
        p:text(string.format(" STRESS %3d%%  %.0f su spare   %d lines on %d relays",
            math.floor(turbines.fraction * 100 + 0.5), turbines.headroom or 0,
            #ship.order, #(turbines.relays or {})), stressColour(turbines.fraction))
    end

    local extras = reads.extras
    if extras.altitude or extras.mass then
        local bits = {}
        if extras.altitude then bits[#bits + 1] = string.format("ALT %.0fm", extras.altitude) end
        if extras.pressure then bits[#bits + 1] = string.format("PRESS %.0f%%", extras.pressure * 100) end
        if extras.mass then bits[#bits + 1] = string.format("MASS %.0f", extras.mass) end
        p:text(" " .. table.concat(bits, "   "), C("dim"))
    end

    p:place()
end

-- == TAB: MANUAL =============================================
--
-- Flying by hand gets a tab of its own, because the mode is then visible at a
-- glance: it is literally which tab you are on. The alternative, a mode flag on
-- the flight tab, is how a pilot ends up surprised by their own ship.
--
-- IJKL and UO, which leaves the arrow keys meaning what they mean everywhere
-- else in this program. The letters are read only while the command line is
-- empty, so `inventory` typed on this tab is a command and not six throttle
-- nudges.

ui.MANUAL_STEP = 0.1        -- one press of I or K, as a fraction of full

-- The same fixed columns the flight tab uses, for the same reason: the keys
-- that move a demand belong beside the demand they move, and a legend that runs
-- under the number it explains is two readouts fighting for one column.
local MANUAL_KEYS_AT, MANUAL_VALUE_AT = 12, 25

local function manualRow(y, label, value, span, keys_, colour)
    at(1, y, string.rep(" ", W), C("hi"), C("bg"))
    at(2, y, util.pad(label, MANUAL_KEYS_AT - 3), C("dim"), C("bg"))
    at(MANUAL_KEYS_AT, y, util.pad(keys_, MANUAL_VALUE_AT - MANUAL_KEYS_AT - 1),
        C("dim"), C("bg"))
    at(MANUAL_VALUE_AT, y, string.format("%+6.2f", value or 0), colour or C("hi"), C("bg"))
    biBar(W - 16, y, 15, value or 0, span)
end

local function drawManual(snap)
    local p = pane()
    local hand = control.manual
    local state = snap.state

    p:rule("BY HAND")
    if hand then
        p:text(" the propellers are taking orders from this tab", C("warn"))
    else
        p:text(" not by hand. Any key below takes control.", C("dim"))
    end
    p:gap()

    p:row(function(y)
        manualRow(y, "THROTTLE", hand and hand.throttle or 0, 1, "I up  K down",
            hand and C("warn") or C("dim"))
    end)
    p:row(function(y)
        manualRow(y, "YAW", hand and hand.yaw or 0, 1, "J left  L rt",
            hand and C("warn") or C("dim"))
    end)

    -- The balloon is not a fraction of anything, it is a strength from nothing
    -- to fifteen, so it gets a plain bar and its own number.
    local level = (hand and hand.level) or (snap.info and snap.info.balloon)
    p:row(function(y)
        at(1, y, string.rep(" ", W), C("hi"), C("bg"))
        at(2, y, util.pad("BALLOON", MANUAL_KEYS_AT - 3), C("dim"), C("bg"))
        at(MANUAL_KEYS_AT, y, util.pad("U up  O down", MANUAL_VALUE_AT - MANUAL_KEYS_AT - 1),
            C("dim"), C("bg"))
        at(MANUAL_VALUE_AT, y, level and string.format(" %2d/15", level) or "    --",
            level and C("hi") or C("dim"), C("bg"))
        if level then bar(W - 16, y, 15, level / 15, C("bar")) end
    end)

    p:gap(2)
    p:rule("WHAT THE SHIP IS DOING")
    if state then
        p:text(string.format(" SPD %5.2f m/s  YAW %+5.1f deg/s  PITCH %+5.1f",
            state.speed, ship.yawRate() or 0, util.pitchOf(state.orientation)), C("hi"))
        p:text(string.format(" X %7.1f  Y %6.1f  Z %7.1f  HDG %5.1f %s",
            state.position.x, state.position.y, state.position.z,
            state.yaw, util.compass(state.yaw)), C("dim"))
    else
        p:text(" position unavailable: " .. tostring(snap.fault), C("bad"))
        p:text(" by hand still flies with no pose. Nothing else does.", C("dim"))
    end

    -- The thing a pilot flying by hand most needs to know is that nothing is
    -- watching the height for them except the loop that always runs. It sits
    -- at the foot of the tab, where the eye lands last.
    p:gap(99)
    p:rule("STILL AUTOMATIC")
    p:text(" the balloon holds its level. Nothing else is.", C("dim"))
    p:text(" space, or `manual off`, hands the ship back", C("accent"))

    p:place()
end

-- == TAB: PROPS ==============================================

local function drawProps(snap, reads)
    local p = pane()

    -- The passcode belongs on the tab the relays are on, because the fault it
    -- explains looks like a relay fault: a relay that is powered, wired and
    -- broadcasting, and deaf to every order this computer sends.
    local pass = link and link.status()
    if pass and pass.refused > 0 then
        p:text(string.format(" %d message(s) refused, last from #%s. Passcodes differ.",
            pass.refused, tostring(pass.refusedFrom)), C("bad"))
        p:gap()
    elseif pass and not pass.paired then
        p:text(" no passcode set. Anything in range on this protocol is obeyed.",
            C("warn"))
        p:gap()
    end

    -- The relay's stressometer watches the whole kinetic network, which is what
    -- every line on this tab is drawing from. It belongs above them, not on a
    -- tab of its own.
    local turbines = reads.turbines
    if turbines.link ~= "nomodem" then
        p:rule("KINETIC NETWORK")
        p:row(function(y)
            if turbines.link == "waiting" then
                line(y, " turbine relay has not spoken yet", C("dim"))
            elseif turbines.link == "stale" then
                line(y, string.format(" turbine relay SILENT for %s, its turbines have stopped",
                    util.fmtETA(turbines.age)), C("bad"))
            elseif turbines.overstressed then
                line(y, " OVERSTRESSED. The kinetic network has stopped turning.", C("bad"))
            elseif not turbines.stressOk then
                line(y, " no stressometer on the relay", C("warn"))
            else
                at(1, y, string.format(" stress %.0f / %.0f su", turbines.stress, turbines.capacity),
                    stressColour(turbines.fraction), C("bg"))
                at(W - 15, y, string.format("%3d%%", math.floor(turbines.fraction * 100 + 0.5)),
                    stressColour(turbines.fraction), C("bg"))
                bar(W - 10, y, 10, turbines.fraction, stressColour(turbines.fraction), C("barBg"))
            end
        end)
    end

    -- Grouped by the computer that owns them, because that is the unit a
    -- propeller goes missing in. Five lines in one list say nothing about which
    -- relay to walk out to; the same five under two headings say it at a glance.
    local byRelay, order = {}, {}
    for _, name in ipairs(ship.order) do
        local remote = ship.remoteLines[name]
        local owner = remote and remote.relay or "wired"
        if not byRelay[owner] then
            byRelay[owner] = {}
            order[#order + 1] = owner
        end
        local group = byRelay[owner]
        group[#group + 1] = name
    end
    table.sort(order, function(a, b)
        if a == "wired" then return true end
        if b == "wired" then return false end
        return a < b
    end)

    if #ship.order == 0 then
        p:gap()
        p:rule("PROPELLER LINES")
        p:text(" nothing on the network that takes a target speed", C("bad"))
    end

    local maxRpm = config.get("maxRpm")
    local linkOf = {}
    for _, one in ipairs(turbines.relays or {}) do linkOf[one.relayId] = one end

    -- Two rows held back for the bearings heading and its first line, so a
    -- long list of propellers cannot push the section that follows it off the
    -- bottom without saying it was there.
    local RESERVE = 2

    for _, owner in ipairs(order) do
        if p:left() <= RESERVE + 1 then break end
        p:gap()
        p:row(function(y)
            if owner == "wired" then
                rule(y, "ON THIS COMPUTER")
            else
                local one = linkOf[owner]
                local note = one and one.link or "waiting"
                if one and one.hasBalloon then note = note .. ", holds the balloon" end
                rule(y, string.format("RELAY #%d  %s", owner, note))
                if one and one.link == "stale" then
                    at(W - 12, y, " NOT ANSWERING", C("ink"), C("bad"))
                end
            end
        end)

        for _, name in ipairs(byRelay[owner]) do
            if p:left() <= RESERVE then break end
            p:row(function(y)
                local line_ = ship.lines[name]
                local entry = cal.sideOf(name)
                local label = entry and entry.side or "unfiled"
                local rpm = snap.demands and snap.demands[name] or 0
                local colour = entry and C("hi") or C("warn")
                at(1, y, string.rep(" ", W), C("hi"), C("bg"))
                -- Five columns for the name, not four: a relay id of ten or more
                -- reads as #10.3 and the fourth column was where it overflowed.
                at(1, y, string.format("%s%-5s %-6s %-3s %5d", line_.main and "*" or " ",
                    util.shortName(name), label,
                    entry and entry.reverse and "rev" or "", rpm), colour)
                biBar(26, y, math.max(6, W - 40), rpm, maxRpm,
                    entry and C("bar") or C("warn"))
                local tele = ship.readLineTelemetry(name)
                if tele then
                    if tele.overstressed then
                        at(W - 9, y, util.padLeft("STRESSED", 9), C("bad"), C("bg"))
                    elseif tele.thrust then
                        at(W - 9, y, util.padLeft(string.format("%.0fpN", tele.thrust), 9), C("dim"), C("bg"))
                    elseif tele.speed then
                        at(W - 9, y, util.padLeft(string.format("%.0frpm", tele.speed), 9), C("dim"), C("bg"))
                    end
                end
            end)
        end
    end

    p:gap(99)
    p:rule("PROPELLER BEARINGS")
    if #ship.bearings == 0 then
        p:text(" none found. Thrust and sail readouts are off.", C("dim"))
    end
    for _, bearing in ipairs(ship.bearings) do
        if p:left() <= 0 then break end
        p:row(function(y)
            local bits = { util.pad(util.shortName(bearing.name), 5) }
            local okAxis, axis = pcall(bearing.wrap.getAxis)
            bits[#bits + 1] = util.pad(okAxis and tostring(axis) or "?", 8)
            local okSail, sail = pcall(bearing.wrap.getSailPower)
            bits[#bits + 1] = util.pad(okSail and string.format("sail %.0f", sail) or "", 10)
            local okThrust, thrust = pcall(bearing.wrap.getThrust)
            bits[#bits + 1] = util.pad(okThrust and string.format("%.0fpN", thrust) or "", 10)
            bits[#bits + 1] = bearing.line and ("<- " .. util.shortName(bearing.line)) or "unlinked"
            line(y, " " .. table.concat(bits, " "), C("dim"))
        end)
    end

    p:place()
end

-- == TAB: NAV ================================================

local function drawNav(snap)
    local p = pane()
    p:rule(string.format("WAYPOINTS (%d)", #nav.points))
    if #nav.points == 0 then
        p:text(" none yet. `save <name>` pins where you are standing.", C("dim"))
    end
    ui.sel.nav = util.clamp(ui.sel.nav, 1, math.max(1, #nav.points))
    -- Three rows kept for the route panel that is pinned to the foot of the
    -- tab, whatever the list does above it.
    local room = p:left() - 3
    local first = math.max(1, math.min(ui.sel.nav - math.floor(room / 2), #nav.points - room + 1))
    -- Remembered so a click knows which waypoint is under the cursor once the
    -- list has scrolled.
    ui.navFirst = first
    for index = first, math.min(#nav.points, first + room - 1) do
        local wp = nav.points[index]
        p:row(function(y)
            if index == first then ui.navTop = y end
            local selected = index == ui.sel.nav
            local active = snap.targetName and snap.targetName:lower() == wp.name:lower()
            local text = string.format("%s %-12s X %-7d %-7s Z %-7d",
                active and ">" or " ", wp.name, util.round(wp.x),
                wp.y and ("Y " .. util.round(wp.y)) or "Y any", util.round(wp.z))
            line(y, text, selected and C("ink") or (active and C("good") or C("hi")),
                selected and C("accent") or C("bg"))
        end)
    end

    p:gap(99)
    p:rule("ROUTE")
    p:text(#nav.route > 0 and (" " .. table.concat(nav.route, " > ")) or " empty",
        #nav.route > 0 and C("warn") or C("dim"))
    p:text(" up/down pick  enter fly  del remove  `route a b`", C("dim"))
    p:place()
end

-- == TAB: CAL ================================================

-- A ladder drawn as a column chart, which is the only honest way to look at
-- four numbers and decide whether the ship is behaving linearly.
local function drawCurve(x, y, width, height, curve, colour)
    local top = util.curveTopSpeed(curve)
    if not curve or #curve == 0 or not top or top <= 0 then
        at(x, y + height - 1, "no samples", C("dim"), C("bg"))
        return
    end
    local slot = math.max(1, math.floor(width / #curve))
    for index, sample in ipairs(curve) do
        local cells = util.round((sample.speed / top) * height)
        for row = 0, height - 1 do
            local filled = row < cells
            at(x + (index - 1) * slot, y + height - 1 - row, string.rep(" ", math.max(1, slot - 1)),
                C("ink"), filled and (colour or C("bar")) or C("bg"))
        end
    end
end

-- One row per stage of the wizard, in the order the wizard runs them, because
-- the thing a pilot wants off this tab is which stage still has to be done.
local function drawCal(snap)
    -- The last row is the hint line, which is always there and is drawn after
    -- the pane rather than in it.
    local p = pane(2, H - 3)
    p:rule("CALIBRATION")

    for _, row in ipairs(cal.summary()) do
        if p:left() <= 3 then break end
        p:row(function(y)
            at(1, y, string.rep(" ", W), C("hi"), C("bg"))
            -- What the stage measured is the sentence worth reading, so it gets
            -- the room and the timestamp gets whatever is left. It was the other
            -- way round until stage 7, which cut the detail mid word on a 51
            -- column screen: the date a stage was run is the less useful of the two.
            local text = string.format(" %d %-8s %s", row.index, row.title, row.detail or "")
            at(1, y, text:sub(1, W - 1), row.done and C("good") or C("warn"), C("bg"))
            if row.at and #text + #row.at + 2 <= W then
                at(W - #row.at - 1, y, row.at, C("dim"), C("bg"))
            end
        end)
    end

    -- The two ladders worth a picture. Yaw and forward are what the controller
    -- spends every tick reading, and a kink in either is visible here and
    -- nowhere else. Each ladder is its own group: two rows about yaw sitting
    -- against two rows about forward read as one block of four numbers.
    for _, entry in ipairs({
        { label = "YAW", curve = cal.yawCurve and cal.yawCurve.pos, unit = "deg/s" },
        { label = "FWD", curve = cal.fwdCurve and cal.fwdCurve.pos, unit = "m/s" },
    }) do
        if p:left() < 3 then break end
        local curve = entry.curve
        p:gap()
        p:row(function(y)
            local top = util.curveTopSpeed(curve)
            at(1, y, string.format(" %-4s top %s", entry.label,
                top and string.format("%.2f %s", top, entry.unit) or "unmeasured"),
                top and C("hi") or C("dim"), C("bg"))
            at(W - 24, y, string.rep(" ", 24), C("hi"), C("bg"))
            drawCurve(W - 24, y, 24, 1, curve, C("bar"))
        end)
        p:row(function(y)
            if curve and #curve > 0 then
                local lo, hi = curve[1], curve[#curve]
                at(1, y, string.format("    %d rpm %.2f  ->  %d rpm %.2f",
                    lo.rpm, lo.speed, hi.rpm, hi.speed), C("dim"), C("bg"))
            else
                at(1, y, "    no samples", C("dim"), C("bg"))
            end
        end)
    end

    if cal.inventory and p:left() > 1 then
        local ok, items = cal.inventoryCheck()
        if not ok and #items > 0 then
            p:gap()
            p:text(" " .. items[1].text, kindColour(items[1].kind))
        end
    end

    p:place()
    line(H - 2, " `cal` all five   `cal yaw` one   `forget <stage>`", C("dim"))
    local _ = snap
end

-- == TAB: TUNE ===============================================
--
-- Two panels: the groups down the left, the selected group's settings filling
-- the rest. A single row of group names worked while there were six of them and
-- was already unreadable at fifteen, and a name in a list is a click target in a
-- way a name in a run of words is not.
--
-- The last group is MEASURED, and it is not a config group. It is what
-- calibration learned, shown here because a pilot looking for the number that
-- decides how the ship behaves should not have to know which file it lives in.
-- Editing one is allowed and says out loud that the next run of that stage
-- overwrites it.

local GROUP_WIDTH = 13

-- The group list the tab shows, which is the config groups plus the measured
-- one. Built here rather than added to config.GROUPS, because config holds the
-- numbers a pilot chooses and cal holds the ones the ship was measured doing,
-- and merging them in the model to save a line in the view would blur that.
function ui.tuneGroups()
    local out = {}
    for _, group in ipairs(config.GROUPS) do out[#out + 1] = group end
    out[#out + 1] = { id = "measured", title = "MEASURED", measured = true }
    return out
end

-- What is in the selected group, as rows the drawing and the editing agree on.
-- Two functions deciding separately what row three is would be the tab bar bug
-- again, one panel down.
function ui.tuneRows()
    local groups = ui.tuneGroups()
    ui.tuneGroup = util.clamp(ui.tuneGroup, 1, #groups)
    local group = groups[ui.tuneGroup]
    local rows = {}
    if group.measured then
        for _, entry in ipairs(cal.MEASURED) do
            local value = entry.get()
            rows[#rows + 1] = {
                measured = true, id = entry.id, label = entry.title, entry = entry,
                value = value,
                text = value and string.format("%.3g", value) or "--",
                help = entry.help,
                note = value and ("measured by the " .. entry.stage .. " stage")
                    or ("the " .. entry.stage .. " stage would measure this"),
            }
        end
    else
        for _, key in ipairs(config.keysIn(group.id)) do
            local entry = config.byKey[key]
            rows[#rows + 1] = {
                key = key, label = key, entry = entry,
                value = config.values[key], text = config.format(key),
                help = entry.help, note = entry.symptom and ("when " .. entry.symptom) or nil,
            }
        end
    end
    ui.sel.tune = util.clamp(ui.sel.tune, 1, math.max(1, #rows))
    return rows, group
end

local function drawTune()
    local rows, group = ui.tuneRows()
    local groups = ui.tuneGroups()

    -- The left panel. It scrolls with the selection rather than being cut off,
    -- because a group you cannot see is a group you cannot click.
    local room = H - 6
    local first = util.clamp(ui.tuneGroup - math.floor(room / 2), 1,
        math.max(1, #groups - room + 1))
    ui.tuneFirstGroup = first
    for row = 0, room - 1 do
        local index = first + row
        local y = 2 + row
        local entry = groups[index]
        if not entry then
            at(1, y, string.rep(" ", GROUP_WIDTH), C("hi"), C("bg"))
        else
            local selected = index == ui.tuneGroup
            at(1, y, util.pad(" " .. entry.title, GROUP_WIDTH),
                selected and C("ink") or (entry.measured and C("accent") or C("dim")),
                selected and C("accent") or C("bg"))
        end
    end

    local x = GROUP_WIDTH + 2
    local width = W - x + 1
    local y = 2
    at(x - 1, y, "|", C("panel"), C("bg"))
    at(x, y, util.pad(group.title, width), C("ink"), C("panel")); y = y + 1

    local listRoom = H - 6 - y + 1
    local firstRow = util.clamp(ui.sel.tune - math.floor(listRoom / 2), 1,
        math.max(1, #rows - listRoom + 1))
    ui.tuneFirstRow = firstRow
    ui.tuneTop = y
    for offset = 0, listRoom - 1 do
        local index = firstRow + offset
        local row = rows[index]
        if not row then
            at(x - 1, y, "|" .. string.rep(" ", width), C("panel"), C("bg"))
        else
            local selected = index == ui.sel.tune
            at(x - 1, y, "|", C("panel"), C("bg"))
            at(x, y, util.pad(string.format(" %-16s %8s", row.label, row.text), width),
                selected and C("ink") or (row.value == nil and C("dim") or C("hi")),
                selected and C("accent") or C("bg"))
            -- A bar only where there is a range to draw it against. A measured
            -- value has no range: it is whatever the ship did.
            local entry = row.entry
            if not row.measured and entry.kind ~= "bool" and entry.max then
                local frac = (row.value - entry.min) / math.max(1e-9, entry.max - entry.min)
                bar(x + 27, y, math.max(4, W - x - 27), frac,
                    selected and C("accent") or C("bar"), C("barBg"))
            elseif not row.measured and entry.kind == "bool" then
                at(x + 27, y, row.value and "on" or "off",
                    row.value and C("good") or C("dim"),
                    selected and C("accent") or C("bg"))
            end
        end
        y = y + 1
    end

    -- The last three lines are the reason the tab exists. A setting's own
    -- sentence is longer than fifty columns, so it wraps rather than being cut:
    -- the half that runs off the edge is usually the half that said what to do.
    -- The full description and the preview are one Enter away, in the popup.
    local row = rows[ui.sel.tune]
    rule(H - 5)
    local note = row and (row.note or row.help)
        or "up/down pick   left/right nudge   enter opens it   [ ] group"
    local wrapped = wrapText(note, W - 2)
    for offset = 0, 2 do
        line(H - 4 + offset, wrapped[offset + 1] and (" " .. wrapped[offset + 1]) or "",
            C("dim"))
    end
end

-- == TAB: FUEL ===============================================
--
-- Everything the relay computer knows, plus the two things it cannot know on
-- its own: how fast this ship is going, and how far away the target is. The
-- advice panel at the bottom is the point of the tab. The numbers above it are
-- there so the captain can check the advice rather than take it on faith.

-- Advice wraps rather than being cut off, and a wrapped line is indented so it
-- reads as a continuation and not as a second, shorter warning.
local function drawAdvice(p, status, snap, turbines)
    local items = fuel.advice(status, snap)
    -- The turbine relay's advice goes in the same panel. A captain does not care
    -- which computer noticed the problem.
    for _, item in ipairs(turbine.advice(turbines)) do items[#items + 1] = item end
    for _, item in ipairs(items) do
        for index, part in ipairs(wrapText(item.text, W - 3)) do
            if p:left() <= 0 then break end
            p:text((index == 1 and " " or "   ") .. part, kindColour(item.kind))
        end
    end
end

local function drawFuel(snap, reads)
    local p = pane()
    local status = reads.fuel

    -- The link line first. Every number under it is worth exactly what the link
    -- is worth, and a stale reading that looks live is how a ship runs dry.
    local linkText, linkColour
    if status.link == "nomodem" then
        linkText, linkColour = "no modem on this computer", C("bad")
    elseif status.link == "waiting" then
        linkText, linkColour = "listening on " .. tostring(fuel.modem) .. ", nothing heard yet", C("warn")
    elseif status.link == "stale" then
        linkText = string.format("relay #%d SILENT for %s", status.relayId or -1,
            util.fmtETA(status.age))
        linkColour = C("bad")
    else
        linkText = string.format("relay #%d   %.1fs ago   %d msgs",
            status.relayId or -1, status.age or 0, fuel.messages)
        linkColour = C("good")
    end
    p:rule("LINK")
    p:text(" " .. linkText, linkColour)

    if not status.snap then
        p:gap(99)
        p:rule("ADVICE")
        drawAdvice(p, status, snap, reads.turbines)
        p:place()
        return
    end

    p:gap()
    p:rule("TOTAL")
    p:row(function(y)
        local headline = string.format(" %s / %s mB", comma(status.total), comma(status.capacity))
        at(1, y, headline, fuelColour(status.fraction), C("bg"))
        at(W - 10, y, string.format("%7d%%", math.floor(status.fraction * 100 + 0.5)),
            fuelColour(status.fraction), C("bg"))
    end)
    p:row(function(y)
        bar(2, y, W - 2, status.fraction, fuelColour(status.fraction), C("barBg"))
    end)

    p:gap()
    p:rule("TANKS")
    for _, tank in ipairs(status.tanks) do
        -- Four rows held back: the flow heading and its line, and the advice
        -- heading and its first line. A ship with many tanks still gets told
        -- what to do about them.
        if p:left() <= 4 then break end
        p:row(function(y)
            local fraction = (tank.capacity or 0) > 0 and tank.amount / tank.capacity or 0
            if tank.ok == false then
                line(y, string.format(" %-6s OFFLINE  %s", tank.side, tostring(tank.err)), C("bad"))
            else
                -- The mod prefix is dropped: the captain knows what dimension he is
                -- in, and `lava` reads faster than `minecraft:lava` in six columns.
                local fluidName = (tank.fluid or "empty"):gsub("^.*:", "")
                at(1, y, string.format(" %-6s %-9s %6s/%-6s", tank.side, fluidName:sub(1, 9),
                    comma(tank.amount), comma(tank.capacity)), C("hi"), C("bg"))
                -- A tilde is the difference between a maximum that was read off the
                -- tank and one the relay assumed. It is small on purpose and it is
                -- never left off.
                at(W - 16, y, tank.capSource ~= "reported" and "~" or " ", C("dim"), C("bg"))
                at(W - 15, y, string.format("%3d%%", math.floor(fraction * 100 + 0.5)),
                    fuelColour(fraction), C("bg"))
                bar(W - 10, y, 10, fraction, fuelColour(fraction), C("barBg"))
            end
        end)
    end

    p:gap()
    p:rule("FLOW")
    if status.filling then
        p:text(string.format(" filling %+.1f mB/s   full in %s",
            status.filling, util.fmtETA(status.fullIn)), C("good"))
    elseif status.burn > 0 then
        p:text(string.format(" burn %.1f mB/s   res %s   dry %s",
            status.burn, util.fmtETA(status.endurance), util.fmtETA(status.dry)),
            status.endurance and status.endurance < 120 and C("bad") or C("hi"))
    else
        p:text(" no flow measured", C("dim"))
    end
    if p:left() > 2 then
        local rangeText
        if status.range then
            rangeText = string.format(" range %.0f blk at %.1f m/s", status.range, status.speed)
            if status.rangeAtCruise then
                rangeText = rangeText .. string.format("   %.0f blk at cruise", status.rangeAtCruise)
            end
        elseif status.rangeAtCruise then
            rangeText = string.format(" range %.0f blk at cruise, stationary now", status.rangeAtCruise)
        else
            rangeText = " range needs a burn rate and a speed"
        end
        p:text(rangeText, C("dim"))
    end

    p:gap()
    p:rule("ADVICE")
    drawAdvice(p, status, snap, reads.turbines)
    p:place()
end

-- == TAB: LOG ================================================

local function drawLog()
    local y = 2
    rule(y, "LOG  " .. (log.path or "")); y = y + 1
    local room = H - 2 - y + 1
    local total = #log.lines
    ui.logScroll = util.clamp(ui.logScroll, 0, math.max(0, total - room))
    local first = math.max(1, total - room + 1 - ui.logScroll)
    for index = first, math.min(total, first + room - 1) do
        local entry = log.lines[index]
        local colour = C("hi")
        if entry.level == "ERROR" then colour = C("bad")
        elseif entry.level == "WARN" then colour = C("warn")
        elseif entry.level == "DEBUG" then colour = C("dim") end
        line(y, " " .. entry.msg, colour)
        y = y + 1
    end
    while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
end

-- == POPUPS ==================================================
--
-- A popup is a descriptor from sc/popup.lua drawn over whatever tab is up. It
-- owns the screen and the keyboard and nothing else.
--
-- It does not set ui.busy, and that is deliberate rather than an oversight.
-- ui.busy parks the control loop, which is right for the calibration wizard
-- because the wizard has its hands on the propellers. A modal that stopped the
-- balloon being commanded would drop the ship out of the sky while the pilot
-- read it.

local function popupBody(p, width)
    local body = {}
    local function fold(list)
        for _, item in ipairs(list or {}) do
            for _, text in ipairs(wrapText(item.text, width)) do
                body[#body + 1] = { text = text, kind = item.kind }
            end
        end
    end
    fold(p.lines)
    if p.cost and #p.cost > 0 then
        body[#body + 1] = { text = "", kind = "dim" }
        fold(p.cost)
    end
    return body
end

local function choiceLine(p)
    local parts = {}
    for _, choice in ipairs(p.choices or {}) do
        parts[#parts + 1] = string.format("[%s] %s",
            choice.key == "enter" and "Enter" or string.upper(choice.key), choice.label)
    end
    return table.concat(parts, "  ")
end

local function centre(text, y, fg, bg)
    at(math.max(1, math.floor((W - #text) / 2) + 1), y, text, fg, bg)
end

-- Losing a part in the air takes the whole screen, because it is the one thing
-- in this program that must not be mistaken for a status line.
local function drawAlarm(p)
    local field = C("bad")
    for y = 1, H do line(y, "", C("hi"), field) end
    local title = " " .. p.title .. " "
    local inverted = math.floor(os.clock() * 2) % 2 == 0
    centre(title, 2, inverted and field or C("hi"), inverted and C("hi") or field)
    local y = 4
    for _, item in ipairs(popupBody(p, W - 4)) do
        if y <= H - 3 then at(3, y, item.text, C("hi"), field); y = y + 1 end
    end
    line(H - 1, "", C("ink"), C("hi"))
    centre(choiceLine(p), H - 1, C("ink"), C("hi"))
end

local function drawBox(p)
    local inner = math.min(W - 6, 44)
    local body = popupBody(p, inner)
    local height = #body + 4
    local top = math.max(2, math.floor((H - height) / 2))
    local left = math.max(1, math.floor((W - inner - 2) / 2) + 1)
    local panel = C("panel")
    local header = C(p.severity == "warn" and "warn" or "accent")

    for row = top, math.min(H, top + height - 1) do
        at(left, row, string.rep(" ", inner + 2), C("hi"), panel)
    end
    at(left, top, string.rep(" ", inner + 2), C("ink"), header)
    at(left + 1, top, p.title:sub(1, inner), C("ink"), header)

    local y = top + 1
    for _, item in ipairs(body) do
        at(left + 1, y, item.text, kindColour(item.kind), panel)
        y = y + 1
    end
    at(left + 1, y + 1, choiceLine(p):sub(1, inner), C("hi"), panel)
end

local function drawPopup(p)
    if p.severity == "alarm" then drawAlarm(p) else drawBox(p) end
end

-- == DRAW ====================================================

-- Paint one frame. Everything that yields has already been read by the caller,
-- so from the clear to the flip this runs straight through: nothing else can
-- get a turn and see the half-drawn window.
local function paint(snap, reads)
    win.setVisible(false)
    clear()
    drawTabs()
    if ui.tab == ui.TAB.FLIGHT then drawFlight(snap, reads)
    elseif ui.tab == ui.TAB.MANUAL then drawManual(snap)
    elseif ui.tab == ui.TAB.PROPS then drawProps(snap, reads)
    elseif ui.tab == ui.TAB.NAV then drawNav(snap)
    elseif ui.tab == ui.TAB.CAL then drawCal(snap)
    elseif ui.tab == ui.TAB.TUNE then drawTune()
    elseif ui.tab == ui.TAB.FUEL then drawFuel(snap, reads)
    else drawLog() end
    drawStatusBar(snap)
    drawInput()
    if ui.popup then drawPopup(ui.popup) end
    win.setVisible(true)
    if ui.popup then
        win.setCursorBlink(false)
        return
    end
    win.setCursorPos(3 + #ui.input, H)
    win.setTextColour(C("hi"))
    win.setCursorBlink(true)
end

-- What the last read of the yielding instruments turned up. The screen loop
-- refreshes it; a keystroke repaints from it. Peripheral numbers a quarter of
-- a second old are the same numbers, and waiting for fresh ones is what makes
-- a keyboard feel dead.
local lastReads = nil

-- Read the instruments that cost a server tick. sublevel and aero calls are
-- mainThread, so every one of these yields, and that is precisely why none of
-- them may happen inside paint: a yield between the clear and the flip hands
-- the screen to another loop mid-frame. Both statuses are read once here
-- rather than once per tab, which also drops a duplicate pose read per frame.
local function readInstruments()
    return {
        extras = ship.readExtras(),
        fuel = fuel.status(),
        turbines = turbine.status(),
    }
end

-- A paint that threw halfway leaves the window hidden, and a hidden window is
-- a frozen screen, so the flip is given back before the error goes up.
local function guardedPaint(snap, reads)
    local ok, err = pcall(paint, snap, reads)
    if not ok then
        pcall(win.setVisible, true)
        error(err, 0)
    end
end

-- The full frame: read, then paint. This is the screen loop's, and it yields.
function ui.draw()
    if ui.busy then return end
    lastReads = readInstruments()
    guardedPaint(control.snapshot(), lastReads)
end

-- The answer to a keystroke or a click. control.snapshot is a plain copy and
-- paint never yields, so this runs to completion the moment it is called and
-- cannot interleave with the screen loop's frame. That is what makes typing
-- land on the screen at the speed it was typed.
function ui.repaint()
    if ui.busy then return end
    if not lastReads then return ui.draw() end
    guardedPaint(control.snapshot(), lastReads)
end

-- == INPUT ===================================================

local function submit()
    local text = ui.input
    ui.input = ""
    ui.historyAt = nil
    if text:match("^%s*$") then return end
    ui.history[#ui.history + 1] = text
    if #ui.history > 50 then table.remove(ui.history, 1) end
    if ui.onCommand then
        local reply, kind = ui.onCommand(text)
        if reply then ui.say(reply, kind) end
    end
end

-- Up and Down mean two different things depending on whether you are typing.
-- With something in the buffer they walk the history, which is what a command
-- line does. With an empty buffer they move the selection, which is what a
-- list does.
local function historyStep(dir)
    if #ui.history == 0 then return false end
    if ui.historyAt == nil then
        ui.historyAt = #ui.history + 1
    end
    ui.historyAt = util.clamp(ui.historyAt + dir, 1, #ui.history + 1)
    ui.input = ui.history[ui.historyAt] or ""
    return true
end

local function listStep(dir)
    if ui.tab == ui.TAB.NAV then
        ui.sel.nav = util.clamp(ui.sel.nav + dir, 1, math.max(1, #nav.points))
    elseif ui.tab == ui.TAB.TUNE then
        local rows = ui.tuneRows()
        ui.sel.tune = util.clamp(ui.sel.tune + dir, 1, math.max(1, #rows))
    elseif ui.tab == ui.TAB.LOG then
        ui.logScroll = math.max(0, ui.logScroll - dir)
    end
end

-- == FLYING BY HAND ==========================================
--
-- IJKL and UO, read only on the MANUAL tab and only while the command line is
-- empty, so a command typed there is a command. Each press moves the demand by
-- a step and hands the whole thing to control.setManual, which is the same call
-- `manual 0.4 0 8` makes: one way into flying by hand, whether it was typed or
-- pressed.
local MANUAL_KEYS = {
    i = { throttle = 1 }, k = { throttle = -1 },
    l = { yaw = 1 }, j = { yaw = -1 },
    u = { level = 1 }, o = { level = -1 },
}

-- Returns true when the key was a manual control and has been acted on.
--
-- It goes out through the command line rather than straight at control, for the
-- same reason the NAV tab's Enter does: `manual` is gated by the preflight
-- checker, and the moment there are two ways to take control one of them is
-- ungated.
function ui.handleManualKey(ch)
    local move = MANUAL_KEYS[tostring(ch):lower()]
    if not move then return false end
    local hand = control.manual or { throttle = 0, yaw = 0, level = nil }
    local step = ui.MANUAL_STEP
    local throttle = util.clamp(hand.throttle + (move.throttle or 0) * step, -1, 1)
    local yaw = util.clamp(hand.yaw + (move.yaw or 0) * step, -1, 1)
    local level = hand.level
    if move.level then
        -- The balloon starts from whatever it is holding right now, so the first
        -- press nudges the ship rather than jumping it to a level off a table.
        local current = level or control.info.balloon or cal.altHover or config.get("balloonFloor")
        level = util.clamp(util.round(current + move.level), 0, 15)
    end
    ui.input = string.format("manual %.2f %.2f%s", throttle, yaw,
        level and string.format(" %d", level) or "")
    submit()
    return true
end

-- Which choice an event picks, or nil. Letters are matched on the char event
-- rather than the key event on purpose: a key event arrives first and its char
-- follows, so resolving on the key would leave the char queued and it would
-- type itself into the command line the moment the popup closed.
local function popupChoice(p, event, p1)
    for _, choice in ipairs(p.choices or {}) do
        if choice.key == "enter" then
            if event == "key" and p1 == keys.enter then return choice.action end
        elseif event == "char" and tostring(p1):lower() == choice.key then
            return choice.action
        end
        if event == "key" and p1 == keys.escape and choice.action == "cancel" then
            return choice.action
        end
    end
    return nil
end

local function closePopup(p, action)
    if ui.popup == p then ui.popup = nil end
    telemetry.event("popup", "answered " .. p.title, action)
    if p.onChoice then pcall(p.onChoice, action) end
    return action
end

-- Put a popup up and carry on. This is what the control loop's alarms use: the
-- ship has already done the safe thing by the time it is drawn, and the answer
-- arrives whenever the pilot gets to it.
function ui.raise(descriptor, onChoice)
    descriptor.onChoice = onChoice or descriptor.onChoice
    ui.popup = descriptor
    telemetry.event("popup", "raised " .. descriptor.title, descriptor.severity)
    pcall(ui.repaint)
    return descriptor
end

-- Put a popup up and wait for the answer, which is what a gate needs. This runs
-- on the input loop and blocks only that: the control loop and the screen loop
-- are untouched, so the balloon is still being commanded while the pilot reads.
function ui.showPopup(descriptor)
    ui.popup = descriptor
    telemetry.event("popup", "asked " .. descriptor.title, descriptor.severity)
    pcall(ui.repaint)
    while ui.popup == descriptor do
        local event, p1 = os.pullEvent()
        if event == "term_resize" or event == "monitor_resize" then
            ui.resize()
        else
            local action = popupChoice(descriptor, event, p1)
            if action then return closePopup(descriptor, action) end
        end
        pcall(ui.repaint)
    end
    -- Something else took the screen while this was up, which is an alarm
    -- arriving mid question. The gate reads a nil as no.
    return nil
end

-- The TUNE editor. Its own loop rather than ui.showPopup's, because this modal
-- takes keys that are not choices: arrows nudge, digits type a value exactly,
-- and the box redraws after each so the pilot is reading the number they are
-- about to commit to. Like every other popup it leaves ui.busy alone, so the
-- balloon is still being flown while somebody edits altKp.
function ui.editSetting(row)
    if not row then return nil end
    local typed = ""

    local function describe()
        if row.measured then
            return popup.measured(row.entry, row.entry.get(), typed)
        end
        return popup.setting(row.entry, config.format(row.key),
            flight.preview(row.key, config.values[row.key], cal, config.values), typed)
    end

    local function commit()
        if typed == "" then return nil end
        local ok, err
        if row.measured then
            ok, err = cal.setMeasured(row.id, typed)
        else
            ok, err = config.set(row.key, typed)
        end
        typed = ""
        if not ok then
            ui.say(tostring(err), "bad")
            return false
        end
        ui.say(row.label .. " = " .. (row.measured and tostring(ok) or config.format(row.key)),
            "good")
        return true
    end

    ui.popup = describe()
    pcall(ui.repaint)
    local result = "done"
    while true do
        local event, p1 = os.pullEvent()
        local finished = false
        if event == "key" then
            if p1 == keys.enter then
                -- Enter with something typed commits it and stays open, so a
                -- value can be tried against the preview before leaving.
                if typed ~= "" then commit() else finished = true end
            elseif p1 == keys.escape then
                typed = ""
                result = "cancel"
                finished = true
            elseif p1 == keys.backspace then
                typed = typed:sub(1, -2)
            elseif p1 == keys.left or p1 == keys.right then
                if not row.measured then
                    config.nudge(row.key, p1 == keys.right and 1 or -1)
                end
            end
        elseif event == "char" then
            local ch = tostring(p1)
            if ch:match("[%d%.%-]") then
                typed = typed .. ch
            elseif typed == "" and ch:lower() == "r" and not row.measured then
                config.reset(row.key)
                ui.say(row.key .. " reset to " .. config.format(row.key), "good")
            elseif typed == "" and ch:lower() == "c" then
                result = "cancel"
                finished = true
            end
        elseif event == "term_resize" or event == "monitor_resize" then
            ui.resize()
        end
        if finished then break end
        ui.popup = describe()
        pcall(ui.repaint)
    end

    ui.popup = nil
    pcall(ui.repaint)
    return result
end

function ui.handleKey(key)
    if ui.popup then
        local action = popupChoice(ui.popup, "key", key)
        if action then closePopup(ui.popup, action) end
        return
    end
    if key == keys.tab then
        local guess = completeFor(ui.input)
        if guess then ui.input = guess end
        return
    end
    if key == keys.enter then
        if ui.input == "" and ui.tab == ui.TAB.NAV and nav.points[ui.sel.nav] then
            -- Through the command line rather than straight at nav, so a
            -- waypoint flown from the list passes the same gate one typed does.
            ui.input = "goto " .. nav.points[ui.sel.nav].name
            submit()
        elseif ui.input == "" and ui.tab == ui.TAB.TUNE then
            local rows = ui.tuneRows()
            ui.editSetting(rows[ui.sel.tune])
        else
            submit()
        end
        return
    end
    if key == keys.backspace then
        ui.input = ui.input:sub(1, -2)
        return
    end
    if key == keys.up then
        if ui.input ~= "" or ui.historyAt then historyStep(-1) else listStep(-1) end
        return
    end
    if key == keys.down then
        if ui.input ~= "" or ui.historyAt then historyStep(1) else listStep(1) end
        return
    end
    if key == keys.left or key == keys.right then
        local dir = key == keys.right and 1 or -1
        if ui.tab == ui.TAB.TUNE then
            local rows = ui.tuneRows()
            local row = rows[ui.sel.tune]
            -- A measured value has no step to nudge by: it is whatever the ship
            -- was doing. Editing one is typing a number, which the popup does.
            if row and not row.measured then
                config.nudge(row.key, dir)
                ui.say(row.key .. " = " .. config.format(row.key), "good")
            elseif row then
                ui.say("open it with Enter to type a measured value", "dim")
            end
        else
            ui.tab = ((ui.tab - 1 + dir) % #ui.TABS) + 1
        end
        return
    end
    if key == keys.leftBracket or key == keys.rightBracket then
        local dir = key == keys.rightBracket and 1 or -1
        ui.tuneGroup = ((ui.tuneGroup - 1 + dir) % #ui.tuneGroups()) + 1
        ui.sel.tune = 1
        return
    end
    if key == keys.pageUp then ui.logScroll = ui.logScroll + 5; return end
    if key == keys.pageDown then ui.logScroll = math.max(0, ui.logScroll - 5); return end
    if key == keys.delete and ui.tab == ui.TAB.NAV then
        local wp = nav.points[ui.sel.nav]
        if wp then
            nav.remove(wp.name)
            ui.say("deleted " .. wp.name, "warn")
        end
        return
    end
    -- F1 to F8 pick a tab outright, which is faster than cycling when you know
    -- where you are going.
    for index = 1, #ui.TABS do
        if key == keys["f" .. index] then ui.tab = index; return end
    end
end

function ui.handleChar(ch)
    if ui.popup then
        local action = popupChoice(ui.popup, "char", ch)
        if action then closePopup(ui.popup, action) end
        return
    end
    -- On the MANUAL tab the letters fly the ship, but only with nothing typed:
    -- `inventory` has to still be a command there and not six throttle nudges.
    if ui.tab == ui.TAB.MANUAL and ui.input == "" then
        if ch == " " then
            ui.input = "manual off"
            submit()
            return
        end
        if ui.handleManualKey(ch) then return end
    end
    ui.input = ui.input .. ch
    ui.historyAt = nil
end

function ui.handleClick(x, y)
    if ui.popup then return end
    if y == 1 then
        local at_ = 1
        for index, label in ipairs(tabLabels()) do
            if x >= at_ and x < at_ + #label then ui.tab = index; return end
            at_ = at_ + #label
        end
        return
    end
    if ui.tab == ui.TAB.TUNE then
        -- Two panels, two click targets. The left picks a group, the right picks
        -- a setting, and clicking the selected setting opens its popup. The
        -- layout comes from the same GROUP_WIDTH the drawing used, so a click
        -- cannot land one column away from what the pilot pressed.
        if x <= GROUP_WIDTH then
            local index = (ui.tuneFirstGroup or 1) + (y - 2)
            if ui.tuneGroups()[index] then
                ui.tuneGroup = index
                ui.sel.tune = 1
            end
            return
        end
        local index = (ui.tuneFirstRow or 1) + (y - (ui.tuneTop or 3))
        local rows = ui.tuneRows()
        if rows[index] then
            if ui.sel.tune == index then
                ui.editSetting(rows[index])
            else
                ui.sel.tune = index
            end
        end
        return
    end
    if ui.tab == ui.TAB.NAV then
        -- Clicking a waypoint selects it; clicking the selected one flies there.
        local index = (ui.navFirst or 1) + (y - (ui.navTop or 3))
        if nav.points[index] then
            if ui.sel.nav == index then
                ui.input = "goto " .. nav.points[index].name
                submit()
            else
                ui.sel.nav = index
            end
        end
    end
end

function ui.resize()
    W, H = term.getSize()
    win.reposition(1, 1, W, H)
end

-- == WIZARD ==================================================
--
-- Calibration takes the whole screen and its own event loop, because it is a
-- conversation, not a readout. The context it hands to cal.lua is deliberately
-- small: draw this, ask that, tell me if they gave up.

local function wizardFrame(title, subtitle)
    clear()
    at(1, 1, string.rep(" ", W), C("ink"), C("accent"))
    at(2, 1, title, C("ink"), C("accent"))
    if subtitle then
        local text = subtitle:sub(1, math.max(0, W - #title - 4))
        at(W - #text, 1, text, C("ink"), C("accent"))
    end
end

-- A line reader that draws on the wizard screen instead of using read(), which
-- would fight the window for the cursor.
local function readLineAt(y, prompt, default)
    local buffer = ""
    while true do
        local shown = prompt .. buffer
        line(y, " " .. shown, C("hi"), C("bg"))
        if buffer == "" and default and default ~= "" then
            at(2 + #shown, y, "(" .. default .. ")", C("dim"), C("bg"))
        end
        win.setVisible(true)
        win.setCursorPos(2 + #shown, y)
        win.setCursorBlink(true)
        local event, p1 = os.pullEvent()
        if event == "char" then
            buffer = buffer .. p1
        elseif event == "paste" then
            buffer = buffer .. p1
        elseif event == "key" then
            if p1 == keys.enter then
                win.setCursorBlink(false)
                return buffer
            elseif p1 == keys.backspace then
                buffer = buffer:sub(1, -2)
            end
        elseif event == "term_resize" then
            ui.resize()
        end
    end
end

function ui.makeWizard(title)
    local ctx = {}
    local notes = {}
    local fields = {}
    local abort = false

    local function render()
        wizardFrame(title, "q or Q stops")
        local y = 2

        -- The card that offers a stage: what it does, how much room it wants,
        -- and what the last run of it found.
        if fields.stageTitle then
            line(y, string.format(" stage %d of %d   %s", fields.stageIndex or 1,
                fields.stageTotal or 1, fields.stageTitle), C("accent")); y = y + 1
            if fields.what then line(y, " " .. fields.what, C("hi")); y = y + 1 end
            if fields.room then line(y, " " .. fields.room, C("warn")); y = y + 1 end
            if fields.current then
                line(y, string.format(" now: %s%s", fields.current,
                    fields.at and ("   last run " .. fields.at) or ""), C("dim")); y = y + 1
            end
        end

        if fields.step then
            line(y, string.format(" line %d of %d   %s", fields.step, fields.total,
                util.shortName(fields.line or "")), C("hi")); y = y + 1
            line(y, string.format(" currently: %s%s", fields.current or "unfiled",
                fields.reversed and " (reversed)" or ""), C("dim")); y = y + 1
        end

        if fields.rungLabel then
            local counter = fields.rungIndex
                and string.format("measurement %d of %d   ", fields.rungIndex, fields.rungTotal or 0)
                or ""
            line(y, " " .. counter .. fields.rungLabel, C("hi")); y = y + 1
        end

        -- One live row, whatever the stage happens to be measuring. The label
        -- and the unit come with the reading, so a yaw rate is never drawn as
        -- metres per second.
        if fields.value then
            line(y, string.format(" %-6s %+7.2f %-5s  trend %+6.3f  %s",
                fields.valueLabel or "value", fields.value, fields.unit or "",
                fields.slope or 0, (fields.phase or ""):upper()),
                fields.phase == "cooldown" and C("warn") or C("hi")); y = y + 1
            at(1, y, " hold ", C("dim"), C("bg"))
            bar(7, y, math.max(6, W - 22), (fields.held or 0) / math.max(0.1, fields.holdNeeded or 1),
                fields.phase == "cooldown" and C("warn") or C("good"))
            at(W - 14, y, string.format("%4.1f/%-4.1fs", fields.held or 0, fields.holdNeeded or 0),
                C("dim"), C("bg")); y = y + 1
            at(1, y, " time ", C("dim"), C("bg"))
            bar(7, y, math.max(6, W - 22), (fields.elapsed or 0) / math.max(0.1, fields.settle or 1),
                C("panel"))
            at(W - 14, y, string.format("%4.1f/%-4.1fs", fields.elapsed or 0, fields.settle or 0),
                C("dim"), C("bg")); y = y + 1
        end

        -- The sides stage reads two numbers at once and the second one is the
        -- one that decides the answer, so it gets its own row rather than
        -- sharing the live line.
        if fields.yawRate then
            line(y, string.format(" yaw    %+7.2f deg/s%s", fields.yawRate,
                fields.guess and ("   looks like the " .. fields.guess) or ""),
                C("accent")); y = y + 1
        end
        if fields.drift then
            local d = fields.drift
            line(y, string.format(" drift  %+6.2f %+6.2f %+6.2f", d[1], d[2], d[3]),
                C("dim")); y = y + 1
        end
        if fields.pitch then
            line(y, string.format(" nose   %+7.1f deg   from %.1f m/s", fields.pitch,
                fields.from or 0), C("warn")); y = y + 1
        end

        if fields.samples and #fields.samples > 0 then
            rule(y, "SO FAR"); y = y + 1
            local parts = {}
            for _, sample in ipairs(fields.samples) do
                parts[#parts + 1] = string.format("%d:%.1f", sample.rpm, sample.speed)
            end
            line(y, " " .. table.concat(parts, "  "), C("dim")); y = y + 1
        end

        -- panel{prompt = false} clears it, which merging a nil could not do.
        if fields.prompt and fields.prompt ~= false then
            line(y, " " .. fields.prompt, C("accent")); y = y + 1
        end

        -- The notes are the running commentary and they live at the bottom.
        local noteTop = math.max(y + 1, H - 8)
        rule(noteTop)
        local row = noteTop + 1
        local first = math.max(1, #notes - (H - noteTop - 2))
        for index = first, #notes do
            line(row, " " .. notes[index].text, kindColour(notes[index].kind))
            row = row + 1
        end
        while row <= H do line(row, "", C("bg")); row = row + 1 end
        win.setVisible(true)
    end

    ctx.panel = function(t)
        for k, v in pairs(t) do fields[k] = v end
        render()
    end

    ctx.note = function(text, kind)
        notes[#notes + 1] = { text = text, kind = kind or "hi" }
        while #notes > 40 do table.remove(notes, 1) end
        log.info("cal: " .. text)
        render()
    end

    ctx.clearFields = function()
        fields = {}
        render()
    end

    ctx.aborted = function() return abort end

    -- Blocks until Enter. Enter is the stop key on purpose: a letter would
    -- leave its char event queued and type itself into the answer that follows.
    ctx.waitEnter = function()
        while true do
            local event, p1 = os.pullEvent()
            if event == "key" then
                if p1 == keys.enter then return end
                if p1 == keys.q then abort = true; return end
            elseif event == "term_resize" then
                ui.resize(); render()
            end
        end
    end

    -- Blocks until the pilot gives up. Paired against a measurement in
    -- parallel.waitForAny, so a run can always be stopped mid-step.
    ctx.waitAbort = function()
        while true do
            local event, p1 = os.pullEvent()
            if event == "key" and p1 == keys.q then
                abort = true
                return
            elseif event == "term_resize" then
                ui.resize(); render()
            end
        end
    end

    ctx.ask = function(question, opts)
        opts = opts or {}
        render()
        local answer = readLineAt(H - 10 > 2 and H - 10 or 2,
            (question ~= "" and question .. " " or ""), opts.default)
        if answer:lower() == "q" then abort = true end
        if answer == "" and opts.default then return opts.default end
        return answer
    end

    ctx.yesno = function(question, default)
        while true do
            local answer = ctx.ask(question .. (default and " [Y/n]" or " [y/N]"), {})
            answer = answer:lower()
            if answer == "" then return default end
            if answer == "y" or answer == "yes" then return true end
            if answer == "n" or answer == "no" then return false end
            if answer == "q" then return default end
        end
    end

    ctx.render = render
    render()
    return ctx
end

-- Hand the screen to a wizard, run it, give the screen back. The pcall is not
-- optional: a calibration that errors out has to still hand the propellers
-- back to a stopped state.
function ui.runWizard(title, fn)
    ui.busy = true
    -- The control loop has to be out of the propellers before the wizard puts
    -- its hands on them, or a control tick lands in the middle of a spin and
    -- zeroes the line being measured.
    if ui.waitParked then ui.waitParked() end
    local ctx = ui.makeWizard(title)
    local ok, err = pcall(fn, ctx)
    ui.busy = false
    win.setCursorBlink(false)
    if not ok and err ~= "Terminated" then
        log.error("wizard: " .. tostring(err))
        ui.say("calibration failed: " .. tostring(err), "bad")
    end
    ui.draw()
    return ok, err
end

function ui.size()
    return W, H
end

return ui
