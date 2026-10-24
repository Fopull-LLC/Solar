-- SMOKE HARNESS: relay beacons go back to the launch with a revert.
--
-- A beacon planted during a flight comes out of the suit pack; a revert puts
-- the pack back as it was at the launch, so the beacon must be taken up too
-- (or it is a free one: plant, revert, plant again). And one picked up during
-- the flight went back in the pack, which the revert empties again, so it
-- must stand again. comms.beaconSnapshot / beaconRestore, which
-- vessel_spawner's snapshot and restore call.
--
--   luajit solar/tests/smoke_revert_beacons.lua

local checks, failures = 0, {}
local function check(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end

local store = {}
local save = {
  get = function(k) return deep(store[k]) end,
  set = function(k, v) store[k] = deep(v) end,
  delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
}
local body = { name = "Golil", x = 1000, y = 0, z = 0, radius = 100 }
local nodes = {}
local env = setmetatable({}, { __index = _G })
env.save = save
env.log = function() end
env.time = 0
env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
env.findScript = function() return nil end
env.find = function(n) return n == "Golil" and { valid = true } or nil end
env.space = { body = function(n) return n == "Golil" and body or nil end }
env.spawn = function(prefab, p, cb)
  local n = { valid = true, prefab = prefab }
  n.destroy = function(self) self.valid = false end
  n.setUp = function() end
  nodes[#nodes + 1] = n
  if cb then cb(n) end
  return n
end
local chunk = assert(loadfile("solar/scripts/comms.lua"))
setfenv(chunk, env)
chunk()
local refreshes = 0
env.refreshNow = function() refreshes = refreshes + 1 end -- (the solve is not under test)
local C = env

local a = C.placeBeacon("Golil", 1100, 0, 0)
local b = C.placeBeacon("Golil", 1000, 100, 0)
check(a == 1 and b == 2 and #C.beaconList() == 2, "two beacons stand before the launch")
local snap = C.beaconSnapshot()
check(#snap.order == 2, "the launch snapshot holds them")

-- the flight: one planted, one picked up
local c = C.placeBeacon("Golil", 1000, 0, 100)
check(C.removeBeacon(a), "a beacon picked up in flight")
check(#C.beaconList() == 2 and store["comms.beacon.3"] ~= nil, "...one new one standing")
local node_c
for _, e in ipairs(C.beaconList()) do if e.id == c then node_c = e.node end end

local gone, back = C.beaconRestore(snap)
check(gone == 1 and back == 1, "the revert takes one up and stands one again: " .. tostring(gone) .. ", " .. tostring(back))
local ids = {}
for _, e in ipairs(C.beaconList()) do ids[#ids + 1] = e.id end
check(#ids == 2 and ids[1] == 1 and ids[2] == 2, "the beacons are the launch's, in their order")
check(store["comms.beacon.3"] == nil, "the planted one is out of the save")
check(node_c and node_c.valid == false, "...and out of the world")
check(store["comms.beacon.1"] and store["comms.beacon.1"].x == 100, "the picked-up one is back in the save where it stood")
check(store["comms.beacons"][1] == 1 and store["comms.beacons"][2] == 2, "the index is written")
check((store["comms.beaconSeq"] or 0) == 3, "...and a reverted beacon's id is not handed out again")
local spawned_a = 0
for _, n in ipairs(nodes) do if n.valid and n.name == "Relay 1" then spawned_a = spawned_a + 1 end end
check(spawned_a == 1, "the one standing again is in the world once")
local g2, b2 = C.beaconRestore(snap)
check(g2 == 0 and b2 == 0, "a second restore changes nothing")

if #failures > 0 then
  print("REVERT BEACON SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("revert beacon smoke: %d checks passed", checks))
