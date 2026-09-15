-- fuel relay: the computer touches both create:fluid_tank blocks directly.
-- the modem on top is wireless and is for rednet, not for finding peripherals.

local MODEM = "top"

local function isTank(side)
  if peripheral.getType(side) == "modem" then return false end
  return peripheral.hasType(side, "fluid_storage") or peripheral.getType(side):find("fluid_tank") ~= nil
end

local function findTanks()
  local tanks = {}
  for _, side in ipairs(peripheral.getNames()) do
    if isTank(side) then
      tanks[#tanks + 1] = { side = side, p = peripheral.wrap(side) }
    end
  end
  return tanks
end

-- what methods does this thing actually have? printed once, so we stop guessing
local function dumpMethods(t)
  local ms = peripheral.getMethods(t.side)
  table.sort(ms)
  print(t.side .. "  [" .. table.concat({ peripheral.getType(t.side) }, ", ") .. "]")
  print("  " .. table.concat(ms, " "))
end

local function status(t)
  local ok, list = pcall(t.p.tanks)
  if not ok then return t.side .. ": tanks() failed: " .. tostring(list) end
  if #list == 0 then return t.side .. ": empty" end

  local out = {}
  for i, tank in ipairs(list) do
    -- {name = "minecraft:lava", amount = 12000} ; capacity absent on some builds
    local fluid = tank.name or "?"
    local amount = tank.amount or 0
    local line = string.format("  #%d %s %d mB", i, fluid, amount)
    if tank.capacity then
      line = line .. string.format(" / %d mB  (%.1f%%)", tank.capacity, amount / tank.capacity * 100)
    end
    out[#out + 1] = line
  end
  return t.side .. ":\n" .. table.concat(out, "\n")
end

if peripheral.getType(MODEM) ~= "modem" then
  print("warning: no modem on " .. MODEM .. ", rednet will not open")
else
  rednet.open(MODEM)
  print("rednet open on " .. MODEM .. "  id " .. os.getComputerID())
end

local tanks = findTanks()
print(("found %d tank(s)"):format(#tanks))
if #tanks == 0 then
  print("nothing matched. everything attached:")
  for _, side in ipairs(peripheral.getNames()) do
    print("  " .. side .. "  " .. peripheral.getType(side))
  end
  return
end

for _, t in ipairs(tanks) do dumpMethods(t) end
print("")
sleep(2)

while true do
  term.clear()
  term.setCursorPos(1, 1)
  print("FUEL  " .. os.date("%H:%M:%S"))
  print(("-"):rep(26))
  for _, t in ipairs(tanks) do print(status(t)) end
  sleep(1)
end
