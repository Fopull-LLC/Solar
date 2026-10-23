-- SMOKE: where the crew sits, where they step out, and which craft the save
-- keeps (vessel_controller.lua crew stations + exitSpot, flight_ops.lua
-- fleetSync + landing_surface + respawn), against stubs.
--
--   * a craft with a pod AND a Command Seat lists both; the crew starts in the
--     pod (the command part), F boards the one NEAREST the astronaut, and the
--     command part (staging keep-side, the rover's front) stays the pod;
--   * stepping out picks the first side whose spot overlaps nothing;
--   * the fleet keeps a craft that LEFT ITS LAUNCH SPOT (a rover never flies)
--     and skips one still in its clamps; the record carries the crew position
--     and whether it ever flew;
--   * a landed craft is put back on whatever surface is under it (the pad's
--     deck, not the ground below it), skipping anything overhead, and a craft
--     at the base waits for the base to be standing.
--
--   luajit solar/tests/smoke_crew_stations.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- ── vessel_controller.lua ──────────────────────────────────────────────────
local astro = { name = "Astronaut", valid = true, visible = true, x = 0, y = 0, z = 0, id = 99 }
local BP = { parts = {
  { uid = 1, id = "plate", kind = "structural", x = 0, y = 0.62, z = 0 },
  { uid = 6, id = "pod", kind = "crewed", x = -0.4, y = 1.07, z = 0, parent = 1 },
  { uid = 7, id = "seat", kind = "crewed", seat = 1, x = 0.45, y = 1.17, z = 0, parent = 1 },
} }
local store = { ["shipyard.blueprint"] = BP }
local overlap = function() return {} end
local VE
VE = setmetatable({
  vec3 = vec3, time = 10.0,
  find = function(n) if n == "Astronaut" then return astro end end,
  findScripts = function() return {} end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  overlapSphere = function(...) return overlap(...) end,
  log = function() end,
}, { __index = function(_, k)
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local vc = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(vc, VE)
vc()
VE.params = {}
for k, v in pairs(VE.defaults) do VE.params[k] = v end
local node = { id = 5, valid = true, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0, name = "Vessel",
               children = function() return {} end }
local info = { origin = vec3(0, 0, 0), vel = vec3(0, 0, 0), parts = {} }
VE.start(node)

check(#VE.crewSeats == 2, "a pod and a seat: two crew positions (" .. #VE.crewSeats .. ")")
check(VE.crewStation() == 6 and VE.podSeat == false, "the crew starts in the pod (the command part)")
check(VE.podLX == -0.4, "the camera centre is the pod")

-- walk up to the SEAT (it faces +X) and press F
astro.x, astro.y, astro.z = 2.0, 1.2, 0.0
check(VE.boardNow(node, info) == true, "F beside the seat boards")
check(VE.crewStation() == 7 and VE.podSeat == true, "...the SEAT, not the pod")
check(VE.podLX == 0.45 and VE.podLY == 1.17, "the seat pose and camera follow the seat (podL = the seat)")
check(astro.visible == true, "a seat's rider stays in view")

-- stand down, walk round to the POD and press F
VE.standDown(node, -2.0, 1.2, 0.0, 0, 0, 0)
VE.time = 20.0
astro.x, astro.y, astro.z = -2.0, 1.2, 0.0
check(VE.boardNow(node, info) == true, "F beside the pod boards")
check(VE.crewStation() == 6 and VE.podSeat == false, "...the POD")
check(astro.visible == false, "a pod hides its crew")

-- too far from both: nothing
VE.standDown(node, -9.0, 1.2, 0.0, 0, 0, 0)
VE.time = 30.0
astro.x = -9.0
check(VE.boardNow(node, info) == false, "out of reach of every crew position: F does nothing")

-- the command part never moved: a staging cut, the damage model and the
-- rover's front still key off the pod (r2FrontOf is handed pod_uid)
VE.setStation(7)
check(VE.commandUid() == 6, "crew in the seat: the pod is still the COMMAND part")

-- a restored craft wakes in the crew position it was saved in
check(VE.setStation(7) == true and VE.crewStation() == 7, "setStation by uid (the fleet record's `station`)")
check(VE.setStation(42) == false and VE.crewStation() == 7, "an unknown uid changes nothing")

-- ── exitSpot: the first clear side ─────────────────────────────────────────
VE.setStation(7)
local px, py, pz = 0.45, 1.17, 0.0
-- nothing in the way: out on the right (+X), as before
local ex, ey, ez = VE.exitSpot(node, info, px, py, pz)
check(ex > px + 0.5 and math.abs(ez) < 1e-6, "clear: the crew steps out on the right")
-- a clamp block on the right (+X): the next side
overlap = function(c) if c.x > px + 0.3 then return { { node = { id = 500, name = "PadClamps" } } } end return {} end
ex, ey, ez = VE.exitSpot(node, info, px, py, pz)
check(ex < px - 0.5, "something on the right: out on the left instead (" .. string.format("%.2f", ex) .. ")")
-- the crew's own capsule never counts against a spot
overlap = function() return { { node = astro } } end
ex = VE.exitSpot(node, info, px, py, pz)
check(ex > px + 0.5, "overlapping only themselves is clear")
-- everything blocked: the old spot (right), not nowhere
overlap = function() return { { node = { id = 501, name = "Wall" } } } end
ex, ey = VE.exitSpot(node, info, px, py, pz)
check(ex > px + 0.5 and ey > py, "boxed in: the right-hand spot, as before")
overlap = function() return {} end

-- ── leftPad ────────────────────────────────────────────────────────────────
store["shipyard.pilot"] = 1
VE.start(node)
check(VE.hasFlown == false and VE.leftPad == false, "a fresh rollout has neither flown nor left the pad")
local fp = VE.fleetParts()
check(fp and fp.station == 6 and fp.flown == false, "the fleet manifest carries the crew position and `flown`")

-- ── flight_ops.lua ─────────────────────────────────────────────────────────
local fstore = {}
local crafts = {}
local hits = {}           -- raycast answers, top down, along -Y from the origin
local bf = { valid = true, sited = false, FOOTPRINT_RADIUS = 175.0 }
local spawned = {}
local FE = setmetatable({
  time = 100, params = {}, vec3 = vec3,
  save = { get = function(k) return fstore[k] end, set = function(k, v) fstore[k] = v end, flush = function() end },
  findScript = function(k) if k == "base_facilities" then return bf end return nil end,
  findScripts = function(k) if k == "vessel_controller" then return crafts end return {} end,
  space = { body = function() return { name = "Vever", x = 0, y = 0, z = 0, radius = 300, mu = 7e5, soi = 3800 } end,
            dominant = function() return "Vever" end,
            elements = function() return nil end, time = function() return 0 end },
  assembly = { info = function(n) return n.info end, rebuild = function() end },
  raycast = function(ox, oy, oz, dx, dy, dz, max)
    for _, h in ipairs(hits) do
      if h < oy - 1e-6 and oy - h <= max then return { x = ox, y = h, z = oz, distance = oy - h, nx = 0, ny = 1, nz = 0 } end
    end
    return nil
  end,
  spawn = function(prefab, pos, cb) spawned[#spawned + 1] = { prefab = prefab, pos = pos } end,
  terrain = { warm = function() end },
  log = function() end, print = function() end,
}, { __index = _G })
local fo = assert(loadfile("solar/scripts/flight_ops.lua"))
setfenv(fo, FE)
fo()
for k, v in pairs(FE.defaults or {}) do FE.params[k] = v end

local function craft(id, flown, left, landed_y)
  local n = { id = id, valid = true, x = 0, y = landed_y or 301, z = 0, vx = 0, vy = 0, vz = 0,
              pitch = 0, yaw = 0, roll = 0, name = "Vessel" }
  n.info = { origin = vec3(0, landed_y or 301, 0), grounded = true, parts = {} }
  return { node = n, hasFlown = flown, leftPad = left, craftName = "C" .. id,
           fleetParts = function() return { parts = { { uid = 1, id = "pod", kind = "crewed", x = 0, y = 0.5, z = 0 } },
                                            fuel = 0, charge = 0, crew = false, station = 1, flown = flown } end }
end
hits = { 300.0 }
crafts = { craft(11, false, true), craft(12, false, false), craft(13, true, true) }
local f = FE.fleetSync()
local names = {}
for _, r in pairs(f) do names[r.name] = r end
check(names.C11 ~= nil, "a rover driven off the pad (never flown, leftPad) is kept")
check(names.C12 == nil, "a rollout still in its clamps is not")
check(names.C13 ~= nil, "a craft that flew is kept")
check(names.C11 and names.C11.station == 1 and names.C11.flown == false, "the record carries the crew position and `flown`")

-- landing_surface: the deck, not the ground below it; overhead skipped
hits = { 330.0, 304.5, 300.0 }        -- a tower arm 26 m up, the pad deck, the ground
local h = FE.landing_surface(0, 304.5, 0, 0, 1, 0)
check(h and math.abs(h.y - 304.5) < 1e-6, "a craft on the deck finds the deck (" .. tostring(h and h.y) .. ")")
h = FE.landing_surface(0, 300.0, 0, 0, 1, 0)
check(h and math.abs(h.y - 300.0) < 1e-6, "a craft on the ground finds the ground under the arm and the deck's edge")

-- respawn waits for the base, then puts the craft on the deck
fstore["fleet.craft"] = { c9 = { name = "Padded", body = "Vever", x = 0, y = 304.5, z = 0, vx = 0, vy = 0, vz = 0,
  landed = true, parts = { { uid = 1, id = "pod", prefab = "PartPod", x = 0, y = 0.5, z = 0 } } } }
fstore["base.body"], fstore["base.x"], fstore["base.y"], fstore["base.z"] = "Vever", 0, 300, 120
crafts = {}
FE.fleetRescan()
hits = { 300.0 }                       -- the pad isn't up yet: only the ground
FE.time = 101
FE.fleetRestore()
check(#spawned == 0, "a craft at the base waits while the base isn't standing (no spawn into the ground under the pad)")
bf.sited = true
hits = { 330.0, 304.5, 300.0 }
FE.time = 102
FE.fleetRestore()
check(#spawned == 1 and math.abs(spawned[1].pos.y - 304.75) < 1e-6,
  "base standing: rebuilt a hand's width over the DECK (" .. tostring(spawned[1] and spawned[1].pos.y) .. ")")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("%d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_stations: all %d checks passed", passed))
