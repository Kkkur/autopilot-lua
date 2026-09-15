-- nav.lua -- waypoints and the queue that walks them.
--
-- starcatcher's waypoints were X and Z only, because its ship held altitude
-- with a balloon and the autopilot never had a say. This one flies the Y axis
-- too, so a waypoint is a point, not a pin on a map. A saved waypoint with no
-- Y still loads: it means "this X and Z, whatever height you are at", and the
-- controller is told to leave the altitude alone for that leg.

local util, control, log = ...

local nav = {}

nav.FILE = nil
nav.points = {}     -- ordered: {name, x, y|nil, z}
nav.route = {}      -- names still to visit on the current route
nav.routeFrom = nil -- what the route was asked for, for the screen

function nav.init(dataDir)
    nav.FILE = fs.combine(dataDir, "waypoints.cfg")
    nav.load()
    return nav
end

function nav.load()
    nav.points = {}
    if not nav.FILE or not fs.exists(nav.FILE) then return false end
    local handle = fs.open(nav.FILE, "r")
    if not handle then return false end
    local data = textutils.unserialize(handle.readAll())
    handle.close()
    if type(data) ~= "table" then return false end
    for _, wp in ipairs(data) do
        if type(wp) == "table" and type(wp.name) == "string"
                and type(wp.x) == "number" and type(wp.z) == "number" then
            nav.points[#nav.points + 1] = {
                name = wp.name, x = wp.x, z = wp.z,
                y = type(wp.y) == "number" and wp.y or nil,
            }
        end
    end
    return true
end

function nav.save()
    if not nav.FILE then return false end
    local dir = fs.getDir(nav.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(nav.FILE, "w")
    if not handle then return false end
    handle.write(textutils.serialize(nav.points))
    handle.close()
    return true
end

function nav.find(name)
    local lower = tostring(name):lower()
    for index, wp in ipairs(nav.points) do
        if wp.name:lower() == lower then return wp, index end
    end
    return nil
end

function nav.add(name, x, y, z)
    local existing, index = nav.find(name)
    local wp = { name = name, x = x, y = y, z = z }
    if existing then
        nav.points[index] = wp
    else
        nav.points[#nav.points + 1] = wp
    end
    nav.save()
    log.infof("waypoint %s: %s", existing and "updated" or "saved", nav.describe(wp))
    return wp, existing ~= nil
end

function nav.remove(name)
    local wp, index = nav.find(name)
    if not wp then return false end
    table.remove(nav.points, index)
    nav.save()
    -- A route that still points at it would fly to a hole in the table.
    for i = #nav.route, 1, -1 do
        if nav.route[i]:lower() == name:lower() then table.remove(nav.route, i) end
    end
    log.info("waypoint deleted: " .. wp.name)
    return true
end

function nav.rename(from, to)
    local wp = nav.find(from)
    if not wp then return false, "no waypoint called " .. from end
    if nav.find(to) then return false, to .. " already exists" end
    wp.name = to
    nav.save()
    return true
end

function nav.describe(wp)
    if wp.y then
        return string.format("%s  X %d  Y %d  Z %d", wp.name,
            util.round(wp.x), util.round(wp.y), util.round(wp.z))
    end
    return string.format("%s  X %d  Z %d  (any height)", wp.name,
        util.round(wp.x), util.round(wp.z))
end

function nav.names()
    local out = {}
    for _, wp in ipairs(nav.points) do out[#out + 1] = wp.name end
    return out
end

-- == FLYING ==================================================

-- Point the controller at one waypoint. A waypoint with no Y is flown at the
-- height the ship happens to be at when the leg starts, which is what "any
-- height" has to mean once the autopilot owns the vertical axis.
function nav.engage(wp, currentY)
    local y = wp.y or currentY
    if not y then return false, "no altitude for this waypoint and no pose to read one from" end
    control.setTarget(wp.x, y, wp.z, wp.name)
    return control.start()
end

function nav.goTo(name, currentY)
    local wp = nav.find(name)
    if not wp then return false, "no waypoint called " .. tostring(name) end
    nav.route = {}
    nav.routeFrom = nil
    return nav.engage(wp, currentY)
end

function nav.goToCoords(x, y, z)
    control.setTarget(x, y, z, nil)
    nav.route = {}
    nav.routeFrom = nil
    return control.start()
end

-- A route is just a list of names. Every arrival pops the next one.
function nav.setRoute(names, currentY)
    local missing = {}
    for _, name in ipairs(names) do
        if not nav.find(name) then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        return false, "unknown: " .. table.concat(missing, ", ")
    end
    nav.route = {}
    for _, name in ipairs(names) do nav.route[#nav.route + 1] = name end
    nav.routeFrom = #nav.route
    log.infof("route set: %s", table.concat(names, " -> "))
    return nav.next(currentY)
end

function nav.next(currentY)
    local name = table.remove(nav.route, 1)
    if not name then
        nav.routeFrom = nil
        return false, "route complete"
    end
    local wp = nav.find(name)
    if not wp then return nav.next(currentY) end
    return nav.engage(wp, currentY)
end

function nav.clearRoute()
    nav.route = {}
    nav.routeFrom = nil
end

-- Hung off the controller, so an arrival walks the route without the UI or the
-- command layer having to notice.
function nav.onArrive(_, currentY)
    if #nav.route == 0 then
        nav.routeFrom = nil
        return
    end
    local ok, err = nav.next(currentY)
    if not ok then log.warn("route: " .. tostring(err)) end
end

return nav
