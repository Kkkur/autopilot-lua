-- ui.lua -- the screen and the keyboard.
--
-- One window, drawn off-screen and flipped, so nothing ever flickers. Seven
-- tabs, because a flight computer that fits everything on one screen is either
-- lying or unreadable, and a command line at the bottom that is always live:
-- you can type `goto dock` while the CAL tab is up.
--
-- Everything the pilot can do has both a key and a command. Keys are for
-- flying, commands are for saying exactly what you mean.

local util, ship, cal, control, nav, fuel, turbine, config, log = ...

local ui = {}

local W, H = term.getSize()
local win = window.create(term.current(), 1, 1, W, H)

ui.tab = 1
ui.TABS = { "FLIGHT", "PROPS", "NAV", "CAL", "TUNE", "FUEL", "LOG" }
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

local function drawFlight(snap, reads)
    local y = 2
    local state = snap.state
    local extras = reads.extras

    rule(y, "SHIP"); y = y + 1
    if state then
        local p = state.position
        line(y, string.format(" X %8.1f   Y %7.1f   Z %8.1f", p.x, p.y, p.z), C("hi")); y = y + 1
        line(y, string.format(" HDG %6.1f %-3s   SPD %5.2f m/s   V %+5.2f",
            state.yaw, util.compass(state.yaw), state.speed, state.velocity.y), C("hi")); y = y + 1
    else
        line(y, " position unavailable: " .. tostring(snap.fault), C("bad")); y = y + 1
        line(y, "", C("dim")); y = y + 1
    end

    -- Speed bar against whatever the ship has actually been measured doing.
    local top = cal.topSpeed("z") or cal.topSpeed("x") or config.get("cruiseSpeed")
    local frac = state and top and top > 0 and (state.speed / top) or 0
    at(1, y, " SPD ", C("dim"), C("bg"))
    bar(6, y, math.max(4, W - 18), frac, frac > 0.98 and C("warn") or C("bar"))
    at(W - 11, y, string.format("%5.1f/%-4.0f", state and state.speed or 0, top or 0), C("dim"), C("bg"))
    y = y + 1

    rule(y, "TARGET"); y = y + 1
    if snap.target then
        local t = snap.target
        line(y, string.format(" %-10s X %d  Y %d  Z %d",
            snap.targetName or "[coords]", util.round(t.x), util.round(t.y), util.round(t.z)),
            C("hi")); y = y + 1
        local eta = snap.eta and util.fmtETA(snap.eta) or "---"
        line(y, string.format(" DIST %7.1f blk   ETA %-10s %s",
            snap.dist or 0, eta, snap.phase:upper()), C("warn")); y = y + 1
        if #nav.route > 0 then
            line(y, " THEN " .. table.concat(nav.route, " > "), C("dim")); y = y + 1
        end
    else
        line(y, " no target. `goto <name>` or `fly <x> <y> <z>`", C("dim")); y = y + 1
        line(y, "", C("bg")); y = y + 1
    end

    -- This ship has one axis it can push along and one it can turn about, so
    -- three axis rows describe a vessel that is not here. What matters is the
    -- heading it is trying to hold, the speed it is trying to make, and the
    -- balloon, which is the only thing keeping it up.
    --
    -- The full rebuild of this tab is stage 7. This is the honest short version.
    local info = snap.info or {}
    rule(y, "STEERING  want / have"); y = y + 1

    if info.err then
        line(y, string.format(" HDG    %+6.1f deg off   %+5.1f deg/s",
            info.err, info.yawRate or 0), C("hi"))
        biBar(W - 14, y, 13, info.differential or 0, config.get("tankRpmMax"))
    else
        line(y, " HDG    no leg running", C("dim"))
    end
    y = y + 1

    line(y, string.format(" SPD    %+6.2f %+6.2f m/s", info.want or 0, info.have or 0), C("hi"))
    biBar(W - 14, y, 13, info.common or 0, config.get("cruiseMaxRpm"))
    y = y + 1

    if info.balloon then
        line(y, string.format(" LIFT   strength %2d of 15   %+5.1f blk",
            info.balloon, info.altErr or 0),
            info.balloon <= config.get("balloonFloor") and C("warn") or C("hi"))
    else
        line(y, " LIFT   no relay is holding the balloon", C("bad"))
    end
    y = y + 1

    if snap.reason then
        line(y, " " .. tostring(snap.reason), C("dim")); y = y + 1
    end

    if y < H - 2 then
        rule(y, "SHIP SYSTEMS"); y = y + 1
        local bits = {}
        if extras.altitude then bits[#bits + 1] = string.format("ALT %.0fm", extras.altitude) end
        if extras.pressure then bits[#bits + 1] = string.format("PRESS %.0f%%", extras.pressure * 100) end
        if extras.vspeed then bits[#bits + 1] = string.format("VS %+.2f", extras.vspeed) end
        if extras.mass then bits[#bits + 1] = string.format("MASS %.0f", extras.mass) end
        if #bits == 0 then bits[1] = "no altimeter fitted" end
        line(y, " " .. table.concat(bits, "   "), C("dim")); y = y + 1

        -- Fuel gets a line of its own on the tab the pilot actually watches. A
        -- level that only appears when you go looking for it is a level nobody
        -- sees until it is a problem.
        if y <= H - 2 then
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
                line(y, text, status.link == "stale" and C("bad") or fuelColour(status.fraction))
                y = y + 1
            end
        end

        -- And stress, on the same terms: the number that decides whether asking
        -- for more RPM will get you any.
        if y <= H - 2 then
            local turbines = reads.turbines
            if turbines.overstressed then
                line(y, " OVERSTRESSED", C("bad")); y = y + 1
            elseif turbines.link == "stale" then
                line(y, " TURBINE RELAY LOST", C("bad")); y = y + 1
            elseif turbines.fraction then
                line(y, string.format(" STRESS %3d%%  %.0f su spare",
                    math.floor(turbines.fraction * 100 + 0.5), turbines.headroom or 0),
                    stressColour(turbines.fraction))
                y = y + 1
            end
        end
    end

    -- Whatever room is left goes to the propellers themselves, two to a row,
    -- so the flight tab alone is enough to see a line that has stopped
    -- answering without switching to PROPS.
    if y < H - 2 and #ship.order > 0 then
        rule(y, "LINES"); y = y + 1
        local perRow = math.max(1, math.floor(W / 17))
        local column = 0
        for _, name in ipairs(ship.order) do
            if y > H - 2 then break end
            local axis = cal.axisOf(name)
            local rpm = snap.demands and snap.demands[name] or 0
            local text = string.format("%s%-3s %-5s %4d", ship.lines[name].main and "*" or " ",
                util.shortName(name), util.labelFor(axis):sub(1, 5), rpm)
            at(1 + column * 17, y, text, axis and (rpm ~= 0 and C("good") or C("hi")) or C("warn"), C("bg"))
            column = column + 1
            if column >= perRow then column = 0; y = y + 1 end
        end
        if column > 0 then y = y + 1 end
    end
    while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
end

-- == TAB: PROPS ==============================================

local function drawProps(snap, reads)
    local y = 2

    -- The relay's stressometer watches the whole kinetic network, which is what
    -- every line on this tab is drawing from. It belongs above them, not on a
    -- tab of its own.
    local turbines = reads.turbines
    if turbines.link ~= "nomodem" then
        rule(y, "KINETIC NETWORK"); y = y + 1
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
        y = y + 1
    end

    rule(y, "PROPELLER LINES"); y = y + 1
    if #ship.order == 0 then
        line(y, " nothing on the network that takes a target speed", C("bad"))
        y = y + 1
    end
    local maxRpm = config.get("maxRpm")
    for index, name in ipairs(ship.order) do
        if y > H - 4 then break end
        local line_ = ship.lines[name]
        local axis = cal.axisOf(name)
        local label = util.labelFor(axis)
        local rpm = snap.demands and snap.demands[name] or 0
        local tag = line_.main and "*" or " "
        local colour = axis and C("hi") or C("warn")
        at(1, y, string.rep(" ", W), C("hi"), C("bg"))
        -- A line driven over the radio is marked, because when it stops doing
        -- what it is told the place to look is a different computer.
        at(1, y, string.format("%s%-4s %-6s %-3s %5d", line_.remote and "~" or tag,
            util.shortName(name), label,
            axis and axis.reverse and "rev" or "", rpm), colour)
        biBar(24, y, math.max(6, W - 38), rpm, maxRpm,
            axis and C("bar") or C("warn"))
        local tele = ship.readLineTelemetry(name)
        if tele then
            local note = ""
            if tele.overstressed then
                note = "STRESSED"
                at(W - 9, y, util.padLeft(note, 9), C("bad"), C("bg"))
            elseif tele.thrust then
                at(W - 9, y, util.padLeft(string.format("%.0fpN", tele.thrust), 9), C("dim"), C("bg"))
            elseif tele.speed then
                at(W - 9, y, util.padLeft(string.format("%.0frpm", tele.speed), 9), C("dim"), C("bg"))
            end
        end
        y = y + 1
        local _ = index
    end

    rule(y, "PROPELLER BEARINGS"); y = y + 1
    if #ship.bearings == 0 then
        line(y, " none found. Thrust and sail readouts are off.", C("dim")); y = y + 1
    end
    for _, bearing in ipairs(ship.bearings) do
        if y > H - 2 then break end
        local bits = { util.pad(util.shortName(bearing.name), 5) }
        local okAxis, axis = pcall(bearing.wrap.getAxis)
        bits[#bits + 1] = util.pad(okAxis and tostring(axis) or "?", 8)
        local okSail, sail = pcall(bearing.wrap.getSailPower)
        bits[#bits + 1] = util.pad(okSail and string.format("sail %.0f", sail) or "", 10)
        local okThrust, thrust = pcall(bearing.wrap.getThrust)
        bits[#bits + 1] = util.pad(okThrust and string.format("%.0fpN", thrust) or "", 10)
        bits[#bits + 1] = bearing.line and ("<- " .. util.shortName(bearing.line)) or "unlinked"
        line(y, " " .. table.concat(bits, " "), C("dim"))
        y = y + 1
    end
    while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
end

-- == TAB: NAV ================================================

local function drawNav(snap)
    local y = 2
    rule(y, string.format("WAYPOINTS (%d)", #nav.points)); y = y + 1
    if #nav.points == 0 then
        line(y, " none yet. `save <name>` pins where you are standing.", C("dim")); y = y + 1
    end
    ui.sel.nav = util.clamp(ui.sel.nav, 1, math.max(1, #nav.points))
    local room = H - 6 - y
    local first = math.max(1, math.min(ui.sel.nav - math.floor(room / 2), #nav.points - room))
    -- Remembered so a click knows which waypoint is under the cursor once the
    -- list has scrolled.
    ui.navFirst = first
    ui.navTop = y
    for index = first, math.min(#nav.points, first + room) do
        local wp = nav.points[index]
        local selected = index == ui.sel.nav
        local active = snap.targetName and snap.targetName:lower() == wp.name:lower()
        local text = string.format("%s %-12s X %-7d %-7s Z %-7d",
            active and ">" or " ", wp.name, util.round(wp.x),
            wp.y and ("Y " .. util.round(wp.y)) or "Y any", util.round(wp.z))
        line(y, text, selected and C("ink") or (active and C("good") or C("hi")),
            selected and C("accent") or C("bg"))
        y = y + 1
    end

    while y < H - 4 do line(y, "", C("bg")); y = y + 1 end
    rule(y, "ROUTE"); y = y + 1
    line(y, #nav.route > 0 and (" " .. table.concat(nav.route, " > ")) or " empty",
        #nav.route > 0 and C("warn") or C("dim")); y = y + 1
    line(y, " up/down pick  enter fly  del remove  `route a b`", C("dim")); y = y + 1
    while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
end

-- == TAB: CAL ================================================

-- A curve drawn as a column chart, which is the only honest way to look at six
-- numbers and decide whether the ship is behaving linearly.
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

local function drawCal(snap)
    local y = 2
    local missing = cal.missingLines()
    rule(y, "DIRECTION"); y = y + 1
    line(y, string.format(" %d of %d lines calibrated%s",
        #ship.order - #missing, #ship.order,
        cal.meta.directionAt and ("   last run " .. cal.meta.directionAt) or ""),
        #missing > 0 and C("warn") or C("good")); y = y + 1
    if #missing > 0 then
        local names = {}
        for _, name in ipairs(missing) do names[#names + 1] = util.shortName(name) end
        line(y, " uncalibrated: " .. table.concat(names, " ") .. "   run `cal`", C("warn")); y = y + 1
    else
        line(y, " `cal` again after a propeller moves or is rewired", C("dim")); y = y + 1
    end

    rule(y, "VELOCITY"); y = y + 1
    line(y, cal.meta.velocityAt and (" last run " .. cal.meta.velocityAt)
        or " never run. `vcal` measures what this ship can actually do.",
        cal.meta.velocityAt and C("dim") or C("warn")); y = y + 1

    -- Two rows per axis: the headline with its sparkline, and the endpoints.
    for _, entry in ipairs(cal.summary()) do
        if y + 2 > H - 3 then break end
        local curve = entry.pos or entry.neg
        at(1, y, string.format(" %s  %d line%s  top %s", entry.axis:upper(), entry.lines,
            entry.lines == 1 and "" or "s",
            entry.top and string.format("%.2f m/s", entry.top) or "unmeasured"),
            entry.top and C("hi") or C("dim"), C("bg"))
        at(W - 24, y, string.rep(" ", 24), C("hi"), C("bg"))
        drawCurve(W - 24, y, 24, 1, curve, C("bar"))
        if curve and #curve > 0 then
            local lo, hi = curve[1], curve[#curve]
            at(1, y + 1, string.format("    %d rpm %.2f  ->  %d rpm %.2f",
                lo.rpm, lo.speed, hi.rpm, hi.speed), C("dim"), C("bg"))
        else
            at(1, y + 1, "    no samples", C("dim"), C("bg"))
        end
        y = y + 2
    end

    while y <= H - 3 do line(y, "", C("bg")); y = y + 1 end
    line(H - 2, " `cal` dirs   `vcal` speeds   `vcal y` one axis", C("dim"))
    local _ = snap
end

-- == TAB: TUNE ===============================================

local function drawTune()
    local y = 2
    local group = config.GROUPS[ui.tuneGroup]
    local names = {}
    for index, entry in ipairs(config.GROUPS) do
        names[#names + 1] = (index == ui.tuneGroup and "[" .. entry.id .. "]" or entry.id)
    end
    line(y, " " .. table.concat(names, " "), C("dim")); y = y + 1
    rule(y, group.title); y = y + 1

    local keys = config.keysIn(group.id)
    ui.sel.tune = util.clamp(ui.sel.tune, 1, math.max(1, #keys))
    for index, key in ipairs(keys) do
        if y > H - 4 then break end
        local selected = index == ui.sel.tune
        local entry = config.byKey[key]
        -- A boolean gets its word in colour at the bar column instead, so it
        -- does not read as "holdAlt on on".
        local text = string.format(" %-14s %10s", key,
            entry.kind == "bool" and "" or config.format(key))
        line(y, text, selected and C("ink") or C("hi"), selected and C("accent") or C("bg"))
        if entry.kind ~= "bool" and entry.max then
            local frac = (config.values[key] - entry.min) / math.max(1e-9, entry.max - entry.min)
            bar(28, y, math.max(4, W - 30), frac,
                selected and C("accent") or C("bar"), C("barBg"))
        elseif entry.kind == "bool" then
            at(28, y, config.values[key] and "on" or "off",
                config.values[key] and C("good") or C("dim"),
                selected and C("accent") or C("bg"))
        end
        y = y + 1
    end

    while y < H - 3 do line(y, "", C("bg")); y = y + 1 end
    local key = keys[ui.sel.tune]
    local entry = key and config.byKey[key]
    rule(H - 3)
    line(H - 2, entry and (" " .. entry.help) or " left/right change   [ ] group   `set <key> <v>`",
        C("dim"))
end

-- == TAB: FUEL ===============================================
--
-- Everything the relay computer knows, plus the two things it cannot know on
-- its own: how fast this ship is going, and how far away the target is. The
-- advice panel at the bottom is the point of the tab. The numbers above it are
-- there so the captain can check the advice rather than take it on faith.

-- Advice wraps rather than being cut off, and a wrapped line is indented so it
-- reads as a continuation and not as a second, shorter warning.
local function drawAdvice(status, snap, y, turbines)
    local items = fuel.advice(status, snap)
    -- The turbine relay's advice goes in the same panel. A captain does not care
    -- which computer noticed the problem.
    for _, item in ipairs(turbine.advice(turbines)) do items[#items + 1] = item end
    for _, item in ipairs(items) do
        for index, part in ipairs(wrapText(item.text, W - 3)) do
            if y > H - 2 then break end
            line(y, (index == 1 and " " or "   ") .. part, kindColour(item.kind))
            y = y + 1
        end
    end
    while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
    return y
end

local function drawFuel(snap, reads)
    local y = 2
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
    rule(y, "LINK"); y = y + 1
    line(y, " " .. linkText, linkColour); y = y + 1

    if not status.snap then
        line(y, "", C("bg")); y = y + 1
        rule(y, "ADVICE"); y = y + 1
        y = drawAdvice(status, snap, y, reads.turbines)
        while y <= H - 2 do line(y, "", C("bg")); y = y + 1 end
        return
    end

    rule(y, "TOTAL"); y = y + 1
    local headline = string.format(" %s / %s mB", comma(status.total), comma(status.capacity))
    at(1, y, headline, fuelColour(status.fraction), C("bg"))
    at(W - 10, y, string.format("%7d%%", math.floor(status.fraction * 100 + 0.5)),
        fuelColour(status.fraction), C("bg"))
    y = y + 1
    bar(2, y, W - 2, status.fraction, fuelColour(status.fraction), C("barBg"))
    y = y + 1

    rule(y, "TANKS"); y = y + 1
    for _, tank in ipairs(status.tanks) do
        if y > H - 6 then break end
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
        y = y + 1
    end

    rule(y, "FLOW"); y = y + 1
    if status.filling then
        line(y, string.format(" filling %+.1f mB/s   full in %s",
            status.filling, util.fmtETA(status.fullIn)), C("good"))
    elseif status.burn > 0 then
        line(y, string.format(" burn %.1f mB/s   res %s   dry %s",
            status.burn, util.fmtETA(status.endurance), util.fmtETA(status.dry)),
            status.endurance and status.endurance < 120 and C("bad") or C("hi"))
    else
        line(y, " no flow measured", C("dim"))
    end
    y = y + 1
    if y <= H - 2 then
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
        line(y, rangeText, C("dim")); y = y + 1
    end

    rule(y, "ADVICE"); y = y + 1
    y = drawAdvice(status, snap, y, reads.turbines)
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

-- == DRAW ====================================================

-- Paint one frame. Everything that yields has already been read by the caller,
-- so from the clear to the flip this runs straight through: nothing else can
-- get a turn and see the half-drawn window.
local function paint(snap, reads)
    win.setVisible(false)
    clear()
    drawTabs()
    if ui.tab == 1 then drawFlight(snap, reads)
    elseif ui.tab == 2 then drawProps(snap, reads)
    elseif ui.tab == 3 then drawNav(snap)
    elseif ui.tab == 4 then drawCal(snap)
    elseif ui.tab == 5 then drawTune()
    elseif ui.tab == 6 then drawFuel(snap, reads)
    else drawLog() end
    drawStatusBar(snap)
    drawInput()
    win.setVisible(true)
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
    if ui.tab == 3 then
        ui.sel.nav = util.clamp(ui.sel.nav + dir, 1, math.max(1, #nav.points))
    elseif ui.tab == 5 then
        local keys = config.keysIn(config.GROUPS[ui.tuneGroup].id)
        ui.sel.tune = util.clamp(ui.sel.tune + dir, 1, math.max(1, #keys))
    elseif ui.tab == 7 then
        ui.logScroll = math.max(0, ui.logScroll - dir)
    end
end

function ui.handleKey(key)
    if key == keys.tab then
        local guess = completeFor(ui.input)
        if guess then ui.input = guess end
        return
    end
    if key == keys.enter then
        if ui.input == "" and ui.tab == 3 and nav.points[ui.sel.nav] then
            local wp = nav.points[ui.sel.nav]
            local state = ship.readState()
            local ok, err = nav.goTo(wp.name, state and state.position.y or nil)
            ui.say(ok and ("flying to " .. wp.name) or tostring(err), ok and "good" or "bad")
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
        if ui.tab == 5 then
            local keys_ = config.keysIn(config.GROUPS[ui.tuneGroup].id)
            local name = keys_[ui.sel.tune]
            if name then
                config.nudge(name, dir)
                ui.say(name .. " = " .. config.format(name), "good")
            end
        else
            ui.tab = ((ui.tab - 1 + dir) % #ui.TABS) + 1
        end
        return
    end
    if key == keys.leftBracket or key == keys.rightBracket then
        local dir = key == keys.rightBracket and 1 or -1
        ui.tuneGroup = ((ui.tuneGroup - 1 + dir) % #config.GROUPS) + 1
        ui.sel.tune = 1
        return
    end
    if key == keys.pageUp then ui.logScroll = ui.logScroll + 5; return end
    if key == keys.pageDown then ui.logScroll = math.max(0, ui.logScroll - 5); return end
    if key == keys.delete and ui.tab == 3 then
        local wp = nav.points[ui.sel.nav]
        if wp then
            nav.remove(wp.name)
            ui.say("deleted " .. wp.name, "warn")
        end
        return
    end
    -- F1..F7 pick a tab outright, which is faster than cycling when you know
    -- where you are going.
    for index = 1, #ui.TABS do
        if key == keys["f" .. index] then ui.tab = index; return end
    end
end

function ui.handleChar(ch)
    ui.input = ui.input .. ch
    ui.historyAt = nil
end

function ui.handleClick(x, y)
    if y == 1 then
        local at_ = 1
        for index, label in ipairs(tabLabels()) do
            if x >= at_ and x < at_ + #label then ui.tab = index; return end
            at_ = at_ + #label
        end
        return
    end
    if ui.tab == 3 then
        -- Clicking a waypoint selects it; clicking the selected one flies there.
        local index = (ui.navFirst or 1) + (y - (ui.navTop or 3))
        if nav.points[index] then
            if ui.sel.nav == index then
                local state = ship.readState()
                local ok, err = nav.goTo(nav.points[index].name, state and state.position.y or nil)
                ui.say(ok and ("flying to " .. nav.points[index].name) or tostring(err),
                    ok and "good" or "bad")
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

        if fields.step then
            line(y, string.format(" line %d of %d   %s", fields.step, fields.total,
                util.shortName(fields.line or "")), C("hi")); y = y + 1
            line(y, string.format(" currently: %s%s", fields.current or "?",
                fields.reversed and " (reversed)" or ""), C("dim")); y = y + 1
        end

        if fields.stepNo then
            line(y, string.format(" measurement %d of %d   axis %s%s   %d rpm",
                fields.stepNo, fields.totalSteps, (fields.axis or "?"):upper(),
                fields.way == "neg" and "-" or "+", fields.rpm or 0), C("hi")); y = y + 1
        end

        if fields.spinning and not fields.done then
            line(y, string.format(" spinning for %.1fs. Press Enter to stop it.",
                fields.elapsed or 0), C("warn")); y = y + 1
        end

        if fields.drift then
            local d = fields.drift
            line(y, string.format(" drift  %+6.2f %+6.2f %+6.2f   looks like %s",
                d[1], d[2], d[3], fields.guess or "?"), C("hi")); y = y + 1
        end
        if fields.best then
            local b = fields.best
            line(y, string.format(" strongest %+6.2f %+6.2f %+6.2f", b[1], b[2], b[3]),
                C("accent")); y = y + 1
        end
        if fields.noPose then
            line(y, " no pose read, so no measurement. Use your eyes.", C("bad")); y = y + 1
        end

        if fields.speed then
            line(y, string.format(" speed %6.2f m/s   trend %+6.3f m/s2   %s",
                fields.speed, fields.slope or 0, (fields.phase or ""):upper()),
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
