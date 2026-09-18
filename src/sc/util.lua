-- util.lua -- vectors, quaternions, small formatters, a PID.
--
-- Everything here is pure. No peripherals, no screen, no files, so the whole
-- module can be exercised by `starcatcher --test` on a computer that is not on
-- a ship and has nothing attached to it.

local util = {}

-- == QUATERNIONS =============================================

-- Rotate v by the quaternion (ux, uy, uz, w): v + 2u x (u x v + w v).
-- Negate the vector part to rotate the other way, which is what turns a world
-- vector into a body frame one.
function util.qRotate(ux, uy, uz, w, vx, vy, vz)
    local tx = uy * vz - uz * vy + w * vx
    local ty = uz * vx - ux * vz + w * vy
    local tz = ux * vy - uy * vx + w * vz
    return vx + 2 * (uy * tz - uz * ty),
           vy + 2 * (uz * tx - ux * tz),
           vz + 2 * (ux * ty - uy * tx)
end

function util.worldToBody(q, vx, vy, vz)
    return util.qRotate(-q.x, -q.y, -q.z, q.w, vx, vy, vz)
end

function util.bodyToWorld(q, vx, vy, vz)
    return util.qRotate(q.x, q.y, q.z, q.w, vx, vy, vz)
end

-- CC: Sable has shipped more than one shape for these. A vector is {x, y, z} in
-- the current source and an array in some builds, and a quaternion is either
-- flat {x, y, z, w} or the CC: Advanced Math pair of a scalar a and a vector v.
-- Read whichever turned up rather than guessing from the version.
function util.toVec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v.x, v.y, v.z
    if type(x) ~= "number" then x, y, z = v[1], v[2], v[3] end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

function util.toQuat(q)
    if type(q) ~= "table" then return nil end
    local x, y, z, w
    if type(q.w) == "number" and type(q.x) == "number" then
        x, y, z, w = q.x, q.y, q.z, q.w
    elseif type(q.a) == "number" and type(q.v) == "table" then
        local v = util.toVec(q.v)
        if not v then return nil end
        x, y, z, w = v.x, v.y, v.z, q.a
    elseif type(q[1]) == "number" and type(q[4]) == "number" then
        x, y, z, w = q[1], q[2], q[3], q[4]
    else
        return nil
    end
    if type(y) ~= "number" or type(z) ~= "number" then return nil end
    -- qRotate is only a rotation for a unit quaternion, anything else scales
    -- the vector it is given.
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-9 then return nil end
    return { x = x / len, y = y / len, z = z / len, w = w / len }
end

-- == SCALARS =================================================

-- Into (-180, 180]. 180 stays 180 rather than flipping to -180, because a
-- heading readout that jumps sign when the ship points due north is a bug
-- report waiting to happen.
function util.wrapAngle(a)
    a = (a + 180) % 360
    if a <= 0 then a = a + 360 end
    return a - 180
end

-- The average of a set of headings, which is not the average of a set of
-- numbers. Two readings either side of north, 179 and -179, are two degrees
-- apart and average to zero, which is due south. So they are averaged as
-- directions and read back as an angle.
--
-- Returns nil for an empty set, and for a set that cancels out entirely, which
-- is a genuine answer: four readings 90 degrees apart have no mean heading and
-- saying zero would be a lie.
function util.meanAngle(list)
    local sx, sz, count = 0, 0, 0
    for _, a in ipairs(list or {}) do
        if type(a) == "number" then
            local r = math.rad(a)
            sx, sz = sx + math.sin(r), sz + math.cos(r)
            count = count + 1
        end
    end
    if count == 0 then return nil end
    if math.abs(sx) < 1e-9 and math.abs(sz) < 1e-9 then return nil end
    return util.wrapAngle(math.deg(math.atan2(sx, sz)))
end

-- How far the widest of those readings sits from their mean. A small spread is
-- a set of readings that agree; a large one is a set whose mean is arithmetic
-- rather than meaningful, and the wizard says so rather than writing it down.
function util.angleSpread(list, mean)
    mean = mean or util.meanAngle(list)
    if not mean then return nil end
    local worst = 0
    for _, a in ipairs(list or {}) do
        if type(a) == "number" then
            local off = math.abs(util.wrapAngle(a - mean))
            if off > worst then worst = off end
        end
    end
    return worst
end

-- A heading the pilot typed, in the convention the F3 screen uses: -180 to 180,
-- south is zero. 270 is accepted and wrapped, because a pilot who types what a
-- compass mod told them should not have their reading thrown away.
--
-- Returns nil and a reason, in the words of what was typed, rather than a
-- silent zero. A heading of zero is due south and is a perfectly ordinary
-- answer, so it cannot double as the failure.
function util.parseHeading(text)
    if type(text) ~= "string" then return nil, "nothing was typed" end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil, "nothing was typed" end
    local value = tonumber(trimmed)
    if not value then return nil, string.format("%q is not a number of degrees", trimmed) end
    if value < -360 or value > 360 then
        return nil, string.format("%s is not a heading. F3 reads between -180 and 180.", trimmed)
    end
    return util.wrapAngle(value)
end

function util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function util.round(v)
    return math.floor(v + 0.5)
end

function util.len3(x, y, z)
    return math.sqrt(x * x + y * y + z * z)
end

function util.sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end
end

-- Yaw of the body +Z axis once it is taken out to the world, in degrees,
-- Minecraft convention: 0 faces +Z, +90 faces -X. Rotating the axis by the
-- quaternion never has to pick a sign convention for the quaternion itself,
-- which is exactly where CC: Sable and the navigation table disagree.
function util.yawOf(q)
    local fx, _, fz = util.bodyToWorld(q, 0, 0, 1)
    if math.abs(fx) < 1e-9 and math.abs(fz) < 1e-9 then return 0 end
    return util.wrapAngle(math.deg(math.atan2(-fx, fz)))
end

-- Pitch of the body +Z axis once it is taken out to the world, in degrees,
-- positive nose up. Read the same way yawOf is, off the rotated axis rather than
-- out of the quaternion's components, so neither of them has to agree with CC:
-- Sable about which sign convention the quaternion itself uses.
--
-- This is the tip axis. A hull braking hard noses over, and that is the one
-- attitude that ends a flight early.
function util.pitchOf(q)
    local _, fy, _ = util.bodyToWorld(q, 0, 0, 1)
    return math.deg(math.asin(util.clamp(fy, -1, 1)))
end

-- Roll, read off the body +X axis the same way the other two are read off +Z,
-- in degrees. Positive means that side of the hull is down.
--
-- Which side of the ship +X is depends on how it was built, so this is signed
-- information and not an instruction: it is here because a hull that is
-- leaning says so here before it says so by sliding, and nothing in the
-- control loop reads it. Naming the side rather than saying "right" is the
-- honest version, since this file has no way to know which is which.
function util.rollOf(q)
    local _, ry, _ = util.bodyToWorld(q, 1, 0, 0)
    return math.deg(math.asin(util.clamp(-ry, -1, 1)))
end

-- For the screen when a peripheral shape is not understood, so the keys can be
-- read off rather than guessed at.
function util.keyList(t)
    if type(t) ~= "table" then return type(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return "{" .. table.concat(keys, ",") .. "}"
end

-- == NAMES AND LABELS ========================================

-- Trailing number off a peripheral name, so the screen can say "#3" instead of
-- "Create_RotationSpeedController_3".
--
-- A line on a relay arrives named "<relay id>:<peripheral name>" and reads as
-- "#2.3", line 3 on relay 2. Without the relay in it, the two ships' worth of
-- propellers that both end in _0 would be two rows on the screen with the same
-- label, which is the display half of the collision the qualified name fixes.
function util.shortName(name)
    local relay, rest = tostring(name):match("^(%d+):(.+)$")
    if relay then
        return "#" .. relay .. "." .. (rest:match("_(%d+)$") or rest)
    end
    return "#" .. (name:match("_(%d+)$") or name)
end

-- == FORMATTERS ==============================================

function util.fmtETA(secs)
    if not secs or secs ~= secs or secs == math.huge or secs < 0 then return "---" end
    secs = math.floor(secs)
    if secs > 86400 then return "---" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    local parts = {}
    if h > 0 then parts[#parts + 1] = h .. "h" end
    if m > 0 then parts[#parts + 1] = m .. "m" end
    if s > 0 or #parts == 0 then parts[#parts + 1] = s .. "s" end
    return table.concat(parts, " ")
end

-- 16 points is more resolution than anyone flying a brick needs, but it reads
-- nicely next to a heading in degrees.
-- Indexed from yaw -180, which is due north, and running the way yaw does:
-- 0 is south, -90 is east, +90 is west. That is Minecraft's convention, not a
-- compass rose's, and getting it backwards is the classic way to fly a ship
-- confidently in the wrong direction.
local COMPASS = { "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" }

function util.compass(yaw)
    local idx = math.floor(((util.wrapAngle(yaw) + 180) % 360) / 22.5 + 0.5) % 16
    return COMPASS[idx + 1]
end

function util.pad(s, n)
    s = tostring(s)
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

function util.padLeft(s, n)
    s = tostring(s)
    if #s >= n then return s:sub(1, n) end
    return string.rep(" ", n - #s) .. s
end

-- == PID =====================================================
-- Same shape starcatcher flew with, plus a clamp on the integral so a long
-- approach cannot wind it up into a lurch on arrival.
local PID = {}
PID.__index = PID

function util.newPID(kp, ki, kd, minOut, maxOut, iLimit)
    return setmetatable({
        kp = kp, ki = ki, kd = kd,
        minOut = minOut or -math.huge,
        maxOut = maxOut or math.huge,
        iLimit = iLimit or math.huge,
        integral = 0, lastErr = nil,
    }, PID)
end

function PID:update(err, dt)
    if dt <= 0 then dt = 0.001 end
    self.integral = util.clamp(self.integral + err * dt, -self.iLimit, self.iLimit)
    local deriv = self.lastErr and (err - self.lastErr) / dt or 0
    self.lastErr = err
    local out = self.kp * err + self.ki * self.integral + self.kd * deriv
    return util.clamp(out, self.minOut, self.maxOut)
end

function PID:setGains(kp, ki, kd)
    self.kp, self.ki, self.kd = kp, ki, kd
end

function PID:setLimits(minOut, maxOut, iLimit)
    self.minOut, self.maxOut = minOut, maxOut
    if iLimit then self.iLimit = iLimit end
end

function PID:reset()
    self.integral = 0
    self.lastErr = nil
end

-- == SPEED CURVES ============================================
-- What velocity calibration produces: a list of {rpm, speed} samples per body
-- axis, sorted by rpm, measured on the real ship. Each direction of travel
-- gets its own curve, because a ship is rarely symmetric. Climbing against
-- gravity is not the same machine as sinking with it.

-- Speed the ship settles at when this axis is driven at `rpm`. Both arguments
-- are magnitudes; the caller keeps track of sign.
function util.curveSpeedAt(curve, rpm)
    if not curve or #curve == 0 then return nil end
    rpm = math.abs(rpm)
    local first = curve[1]
    if rpm <= first.rpm then
        -- Below the lowest sample, scale the lowest one down rather than
        -- pretending it was measured.
        if first.rpm <= 0 then return first.speed end
        return first.speed * (rpm / first.rpm)
    end
    for i = 1, #curve - 1 do
        local a, b = curve[i], curve[i + 1]
        if rpm <= b.rpm then
            local span = b.rpm - a.rpm
            local t = span > 1e-9 and (rpm - a.rpm) / span or 0
            return a.speed + (b.speed - a.speed) * t
        end
    end
    -- Past the top sample the curve is flat, not extrapolated. A propeller that
    -- is already saturated does not go faster because we asked nicely.
    return curve[#curve].speed
end

-- The inverse: what RPM to ask for to fly at `speed`. Returns nil when there is
-- no curve, which is the caller's cue to fall back on plain proportional.
function util.curveRpmFor(curve, speed)
    if not curve or #curve < 1 then return nil end
    local want = math.abs(speed)
    local prev = nil
    for i = 1, #curve do
        local s = curve[i]
        if s.speed >= want then
            if not prev then
                if s.speed <= 1e-6 then return s.rpm end
                return s.rpm * (want / s.speed)
            end
            local span = s.speed - prev.speed
            local t = span > 1e-6 and (want - prev.speed) / span or 0
            return prev.rpm + (s.rpm - prev.rpm) * t
        end
        prev = s
    end
    -- Asked for more than the ship has ever done. Give it everything.
    return curve[#curve].rpm
end

-- Fastest this axis was ever seen to go, for the ETA and the cruise clamp.
function util.curveTopSpeed(curve)
    if not curve or #curve == 0 then return nil end
    local best = 0
    for _, s in ipairs(curve) do if s.speed > best then best = s.speed end end
    return best
end

-- Samples come in as they are measured and are not necessarily in order if a
-- run was interrupted and resumed. Sort and drop duplicates before saving.
function util.tidyCurve(samples)
    local out = {}
    for _, s in ipairs(samples or {}) do
        if type(s) == "table" and type(s.rpm) == "number" and type(s.speed) == "number" then
            out[#out + 1] = { rpm = math.abs(s.rpm), speed = math.abs(s.speed) }
        end
    end
    table.sort(out, function(a, b) return a.rpm < b.rpm end)
    local dedup = {}
    for _, s in ipairs(out) do
        local last = dedup[#dedup]
        if last and math.abs(last.rpm - s.rpm) < 0.5 then
            dedup[#dedup] = s
        else
            dedup[#dedup + 1] = s
        end
    end
    return dedup
end

return util
