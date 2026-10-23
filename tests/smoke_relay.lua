-- SMOKE: the ground relay network — relay beacons (scripts/comms.lua), the
-- coverage math (scripts/electronics.lua), and the beacon as pack gear
-- (scripts/inventory.lua). No engine: the scene, the save and space are stubs.
--
--   * a beacon's reach suits the home world's scale (a few hundred metres);
--   * a probe rover past the ground station's horizon routes home through a
--     chain of beacons (the solve treats them as relays);
--   * coverage(home).ground goes up as beacons go down, and sky >= ground;
--   * relayStats / linkedBodies / networkVersion / onNetworkChanged;
--   * beacons survive a save round trip (a fresh comms reading the same save),
--     and picking one up takes it out of the save;
--   * gear: buying a beacon spends money and weighs in the pack.
--
--   luajit solar/tests/smoke_relay.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

-- ── electronics (pure) ──────────────────────────────────────────────────────
local E = setmetatable({}, { __index = _G })
do
  local chunk = assert(loadfile("solar/scripts/electronics.lua"))
  setfenv(chunk, E)
  chunk()
end
local C = E.COMMS
local R = 807

local reach = E.groundReach(R, C.beacon.mast, C.coverLift, C.coverRx, C.beacon.power)
check(reach > 250 and reach < 500, "a probe hears a beacon from a few hundred metres of ground (got " .. reach .. ")")
local bb = E.groundReach(R, C.beacon.mast, C.beacon.mast, C.beacon.power, C.beacon.power)
check(bb > 250 and bb < 600, "beacon to probe reach, ground taken from a mast (got " .. bb .. ")")
check(E.linkStrength(350, E.linkRange(C.beacon.power, C.beacon.power)) > 0.6,
  "two beacons 350 m apart link strongly")
-- THE MAST: in a basin 30 m deep the grazing allowance, measured from the
-- ground under each mast, lets two beacons 260 m apart see each other; two
-- antennas that low with no mast under them don't.
do
  local W = { { name = "w", x = 0, y = 0, z = 0, radius = R } }
  local rg, m = R - 30, C.beacon.mast
  local th = 260 / rg
  local ax, ay = 0, rg + m
  local bx2, by2 = math.sin(th) * (rg + m), math.cos(th) * (rg + m)
  check(E.segmentBlocked(ax, ay, 0, bx2, by2, 0, W, C.occlude, nil, true, m, m) == nil,
    "two beacons 260 m apart in a 30 m basin see each other over their masts")
  check(E.segmentBlocked(ax, ay, 0, bx2, by2, 0, W, C.occlude, nil, true) == "w",
    "...the same two points with no mast under them don't")
  local n1 = E.beaconNode("b:1", "A", ax, ay, 0)
  check(n1.agl == m and n1.relay == C.beacon.power, "a beacon node carries its mast and relays")
end
local g = E.surfaceGrid(200)
check(#g == 200 and E.surfaceGrid(200) == g, "the coverage grid is fixed (200 points, cached)")
local sumy = 0
for _, u in ipairs(g) do sumy = sumy + u[2] end
check(math.abs(sumy) < 1e-6, "the grid covers both hemispheres evenly")

-- ── the stub world ──────────────────────────────────────────────────────────
-- Vever (r 807) far from its star; the base at its north pole.
local VX, VY, VZ = 5.0e6, 0, 0
local BODIES = {
  { name = "Sol", x = 0, y = 0, z = 0, radius = 5000, mu = 1e12, soi = 1e12 },
  { name = "Vever", x = VX, y = VY, z = VZ, radius = R, mu = 1e6, soi = 3e4 },
}
local function body(n) for _, b in ipairs(BODIES) do if b.name == n then return b end end end
-- a point on Vever `arc` metres from the pole along +X, `h` m above the datum
local function surf(arc, h, az)
  local th = arc / R
  az = az or 0
  local r = R + (h or 0)
  return VX + math.sin(th) * math.cos(az) * r, VY + math.cos(th) * r, VZ + math.sin(th) * math.sin(az) * r
end

local STORE = {}
local save = {
  get = function(k, d) local v = STORE[k]; if v == nil then return d end return v end,
  set = function(k, v) STORE[k] = v end,
  delete = function(k) local had = STORE[k] ~= nil; STORE[k] = nil; return had end,
}
local space = {
  bodies = function() return BODIES end,
  body = function(n) return body(n) end,
  dominant = function(x, y, z)
    local v = body("Vever")
    local d = math.sqrt((x - v.x) ^ 2 + (y - v.y) ^ 2 + (z - v.z) ^ 2)
    return d < v.soi and "Vever" or "Sol"
  end,
}
local bx, by, bz = surf(0, 0)
local BF = { valid = true, sited = true, baseBody = "Vever", baseX = bx, baseY = by, baseZ = bz }
local ROVER = { x = 0, y = 0, z = 0 }
local VESSELS = {
  { node = { id = 77, valid = true, name = "Rover" }, craftName = "Rover",
    commsNode = function() return { x = ROVER.x, y = ROVER.y, z = ROVER.z, any = 100, relay = 0, rate = 1 } end },
}
local spawned = {}

local function new_comms()
  local env = setmetatable({}, { __index = _G })
  env.save, env.space = save, space
  env.time = 0
  env.log = function() end
  env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  env.find = function(n)
    if n == "Vever" then return { name = "Vever", valid = true } end
    return nil
  end
  env.findScript = function(k)
    if k == "electronics" then return E end
    if k == "base_facilities" then return BF end
    return nil
  end
  env.findScripts = function(k)
    if k == "vessel_controller" then return VESSELS end
    return {}
  end
  env.terrain = TERRAIN
  env.spawn = function(prefab, pos, cb, parent)
    local n = { valid = true, prefab = prefab, parent = parent }
    function n:setUp() end
    function n:destroy() self.valid = false end
    spawned[#spawned + 1] = n
    cb(n)
  end
  local chunk = assert(loadfile("solar/scripts/comms.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = env.defaults
  env.start({})
  return env
end

local net = new_comms()
local function tick(dt)
  net.time = net.time + (dt or 3.0)
  net.update({}, dt or 3.0)
end

-- The rover 1.3 km round the world: far below the ground station's horizon.
ROVER.x, ROVER.y, ROVER.z = surf(1300, 1.0)
tick()
local st = net.statusOf(77)
check(st and not st.connected, "a rover 1.3 km round the world has no link with no beacons")
check(st and st.why and st.why:find("horizon") ~= nil, "...and says the station is below the horizon")
local cov0 = net.coverage("Vever")
check(cov0.samples == 200, "coverage samples the fixed 200-point grid")
check(cov0.ground > 0 and cov0.ground < 0.15, "the base alone covers a little of the world (got " .. cov0.ground .. ")")
local v0 = net.networkVersion
local heard = {}
local unsub = net.onNetworkChanged(function(v) heard[#heard + 1] = v end)

-- A chain of four beacons out toward the rover.
local ids = {}
local covs = { cov0.ground }
for i, arc in ipairs({ 330, 660, 990, 1200 }) do
  local x, y, z = surf(arc, 0)
  local links, connected = net.previewLinks(x, y, z)
  check(connected and #links > 0, string.format("the preview at %d m names what it links to", arc))
  ids[i] = net.placeBeacon("Vever", x, y, z)
  tick()
  covs[#covs + 1] = net.coverage("Vever").ground
end
if os.getenv("RELAY_VERBOSE") then print("ground coverage by beacons", table.concat(covs, " ")) end
check(#ids == 4 and ids[4] ~= nil, "four beacons placed")
for i = 2, #covs do
  check(covs[i] > covs[i - 1], string.format("ground coverage goes up with beacon %d (%.3f -> %.3f)", i - 1, covs[i - 1], covs[i]))
end
check(net.networkVersion > v0 and #heard >= 4, "the network version moves and listeners hear each change")
unsub()

st = net.statusOf(77)
check(st and st.connected, "the rover now has a link home")
local through = false
for _, pid in ipairs(st and st.path or {}) do if tostring(pid):sub(1, 2) == "b:" then through = true end end
check(through, "...routed through the ground relays")
check(st and st.hops >= 4, "...over several hops (got " .. tostring(st and st.hops) .. ")")
for _, id in ipairs(ids) do
  local bs = net.statusOf("b:" .. id)
  check(bs and bs.connected, "beacon " .. id .. " has a path home")
end

local rs = net.relayStats()
check(rs.ground.Vever == 4 and rs.total == 4 and rs.linked.ground.Vever == 4, "relayStats counts the ground relays")
check(next(rs.orbit) == nil, "...and no orbiters")
local lb = net.linkedBodies()
check(#lb == 1 and lb[1] == "Vever", "linkedBodies: the home world")
local cov = net.coverage("Vever")
check(cov.sky >= cov.ground, "sky coverage includes the ground network")
local grid = net.coverageGrid("Vever")
check(grid and #grid.cov == 200 and #grid.dirs == 200, "the map gets the grid and its flags")

-- A relay satellite over the far side: sky coverage beyond the ground.
local sx, sy, sz = surf(1300, 600)
VESSELS[2] = { node = { id = 88, valid = true, name = "Sat" }, craftName = "Sat",
  commsNode = function() return { x = sx, y = sy, z = sz, any = 2.25e5, relay = 2.25e5, rate = 12 } end }
tick()
local cov2 = net.coverage("Vever")
check(cov2.sky > cov2.ground + 0.05, string.format("a relay satellite adds sky coverage (%.2f vs ground %.2f)", cov2.sky, cov2.ground))
check(math.abs(cov2.ground - cov.ground) < 1e-9, "...and the ground number doesn't count it")
check((net.relayStats().orbit.Vever or 0) == 1, "relayStats counts the orbiter")
VESSELS[2] = nil
tick()

-- ── relay CRAFT on the ground (the playtest, 2026-10-23) ────────────────────
-- "drove a vehicle with a relay beacon and antenna on it on top of a mountain
-- … my signal coverage actually went DOWN to zero". A rover carrying a relay
-- beacon part (relay 1500, like a planted one) is a ground relay like any
-- other: linked, it extends the network; unlinked, it changes nothing.
do
  local VERBOSE = os.getenv("RELAY_VERBOSE")
  local base = net.coverage("Vever")
  -- far round the world, out of everyone's reach: unlinked
  local fx, fy, fz = surf(2400, 45, 2.5)
  VESSELS[2] = { node = { id = 91, valid = true, name = "Relay Rover" }, craftName = "Relay Rover",
    commsNode = function() return { x = fx, y = fy, z = fz, any = 1500, relay = 1500, rate = 2 } end }
  tick()
  local s3 = net.statusOf(91)
  local c1 = net.coverage("Vever")
  check(s3 and not s3.connected, "a relay rover far round the world has no link")
  check(c1.ground >= base.ground - 1e-12 and c1.sky >= base.sky - 1e-12, string.format(
    "an UNLINKED relay rover never lowers coverage (ground %.3f → %.3f, sky %.3f → %.3f)", base.ground, c1.ground, base.sky, c1.sky))
  -- on a mountain 40 m high, 300 m past the last beacon: chained in
  local mx, my, mz = surf(1500, 40)
  fx, fy, fz = mx, my, mz
  tick()
  s3 = net.statusOf(91)
  local c2 = net.coverage("Vever")
  check(s3 and s3.connected and s3.hops >= 5, "the mountain-top relay rover links home through the beacon chain")
  check(c2.ground > c1.ground + 0.01, string.format(
    "...and the ground coverage goes UP with it (%.3f → %.3f)", c1.ground, c2.ground))
  check(c2.sky >= c2.ground, "...sky still includes ground")
  local rs3 = net.relayStats()
  check(rs3.ground.Vever == 5 and rs3.linked.ground.Vever == 5 and next(rs3.orbit) == nil,
    "relayStats counts a landed relay rover as a ground relay, not an orbiter")
  if VERBOSE then
    print(string.format("  relay rover: base %.3f · unlinked on the far side %.3f · chained on a mountain %.3f (ground)",
      base.ground, c1.ground, c2.ground))
  end

  -- THE MOVING WORLD. Vever runs ~240 m/s on its rails. The station is read
  -- in this frame, the rover's last report is a tenth of a second old, and
  -- coverage is asked for later still; nothing may come out of where its
  -- world is. Coverage stays put while the world moves.
  local VV = body("Vever")
  local vz0, bz0 = VV.z, BF.baseZ
  local node = VESSELS[2].node
  local ox, oy, oz = 0.0, 0.6, 0.0 -- the antenna's offset from the craft root
  local function at_rover() return mx - ox, my - oy, mz - oz end
  node.worldX, node.worldY, node.worldZ = at_rover()
  local stale = { mx, my, mz }
  VESSELS[2].commsNode = function()
    return { x = stale[1], y = stale[2], z = stale[3], ox = ox, oy = oy, oz = oz, any = 1500, relay = 1500, rate = 2 }
  end
  tick()
  local ref = net.coverage("Vever")
  local worst = 0
  local seen = {}
  for k = 1, 8 do
    -- the world moves 60 m (a quarter second); the rover's report lags 24 m
    -- behind it; the base and the rover root move with the world
    local d = 60
    stale = { mx, my, mz + d * k - 24 }
    VV.z = VV.z + d
    mz = mz + d
    BF.baseZ = BF.baseZ + d
    node.worldX, node.worldY, node.worldZ = at_rover()
    tick()
    -- asked again after the world moved on (no solve in between)
    VV.z = VV.z + 30
    mz = mz + 30
    BF.baseZ = BF.baseZ + 30
    node.worldX, node.worldY, node.worldZ = at_rover()
    net.time = net.time + 11 -- past cover_max: a fresh recompute
    local c = net.coverage("Vever")
    seen[#seen + 1] = string.format("%.3f", c.ground)
    worst = math.max(worst, math.abs(c.ground - ref.ground), math.abs(c.sky - ref.sky))
    local st = net.statusOf(91)
    check(st and st.connected, "the rover stays linked while its world moves (step " .. k .. ")")
    -- the link lines sit where their worlds are now
    for _, l in ipairs(net.linkLines()) do
      if l.a == "home" or l.b == "home" then
        local hx, hy, hz = l.a == "home" and l.ax or l.bx, l.a == "home" and l.ay or l.by, l.a == "home" and l.az or l.bz
        check(math.abs(hz - (BF.baseZ + (hz - BF.baseZ))) < 1e-9 and math.abs(hz - BF.baseZ) < 1e-6,
          "a link line's station end is at the station now")
        break
      end
    end
  end
  if VERBOSE then print("  coverage as the world moves: " .. table.concat(seen, " ")) end
  check(worst < 1e-9, string.format("coverage holds still while the world moves (worst change %.4f)", worst))
  VESSELS[2] = nil
  VV.z, BF.baseZ = vz0, bz0
  tick()
end

-- ── save round trip ────────────────────────────────────────────────────────
check(type(STORE["comms.beacons"]) == "table" and #STORE["comms.beacons"] == 4, "the beacon index is in the save")
for _, id in ipairs(ids) do
  local rec = STORE["comms.beacon." .. id]
  check(type(rec) == "table" and rec.b == "Vever", "beacon " .. id .. " has its own save record")
end
-- every record small enough for a save value
for k, v in pairs(STORE) do
  if k:sub(1, 6) == "comms." and type(v) == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    check(n < 40, k .. " stays a small value")
  end
end
local before = net.beaconList()
local net2 = new_comms()
net2.time = 100
net2.update({}, 3.0)
local after = net2.beaconList()
check(#after == #before, "a reload finds every beacon")
for i = 1, #before do
  check(after[i].name == before[i].name and math.abs(after[i].gx - before[i].gx) < 1e-6
    and math.abs(after[i].gy - before[i].gy) < 1e-6, "...in the same place: " .. before[i].name)
end
check(net2.statusOf(77) and net2.statusOf(77).connected, "...and the rover is linked again after the reload")
local nodes = 0
for _, n in ipairs(spawned) do if n.valid and n.prefab == "RelayBeacon" then nodes = nodes + 1 end end
check(nodes >= 4, "beacon nodes are spawned on the planet")

-- pick one up: out of the network and the save
local gx, gy, gz = after[4].gx, after[4].gy, after[4].gz
local near = net2.beaconNear(gx + 1, gy, gz, 3)
check(near and near.id == ids[4], "beaconNear finds the one under the aim")
check(net2.removeBeacon(ids[4]), "it can be picked up")
check(STORE["comms.beacon." .. ids[4]] == nil and #STORE["comms.beacons"] == 3, "...and leaves the save")
net2.time = net2.time + 5
net2.update({}, 5)
check(net2.relayStats().ground.Vever == 3, "three left")
-- next placement gets a fresh name, never a reused one
local x5, y5, z5 = surf(1200, 0, 0.3)
local id5 = net2.placeBeacon("Vever", x5, y5, z5)
check(id5 == 5 and STORE["comms.beacon.5"].n == "Relay 5", "ids are never reused")

-- ── the ground under the grid: measured once, kept in the save ─────────────
do
  check(net2.coverage("Vever").ready == false, "with no terrain to measure, coverage says it isn't ready")
  -- a world whose ground is a sphere 10 m under the datum
  TERRAIN = { query = function(x, y, z)
    return math.sqrt((x - VX) ^ 2 + (y - VY) ^ 2 + (z - VZ) ^ 2) - (R - 10)
  end }
  local net3 = new_comms()
  net3.time = 200
  net3.update({}, 3.0)
  local c3 = net3.coverage("Vever")
  check(c3.ready == true, "once the ground is measured, coverage is ready")
  local enc = STORE["comms.ground.Vever"]
  check(type(enc) == "string" and #enc == 400, "the grid's ground is kept in the save (400 chars)")
  local grid = net3.coverageGrid("Vever")
  check(math.abs(grid.r[17] - (R - 10 + C.coverLift)) < 0.5, "...at the measured height")
  TERRAIN = nil
  local net4 = new_comms()
  net4.time = 300
  net4.update({}, 3.0)
  local c4 = net4.coverage("Vever")
  check(c4.ready == true and math.abs(c4.ground - c3.ground) < 1e-9,
    "a reload with no terrain resident reads the same ground from the save")
end

-- ── gear ────────────────────────────────────────────────────────────────────
do
  local env = setmetatable({}, { __index = _G })
  local funds = 100
  local CO = { spend = function(a) if funds < a then return false end funds = funds - a return true end }
  env.save = save
  env.log = function() end
  env.findScript = function(k) if k == "company" then return CO end return nil end
  local chunk = assert(loadfile("solar/scripts/inventory.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = env.defaults
  local inv = env
  STORE["inv.astro"] = {}
  local ok = inv.buyGear("astro", "beacon", 1)
  check(ok and funds == 100 - inv.GEAR.beacon.cost and inv.gearCount("astro", "beacon") == 1, "buying a beacon spends money")
  local ok2, why = inv.buyGear("astro", "beacon", 1)
  check(not ok2 and why == "not enough money" and inv.gearCount("astro", "beacon") == 1, "...and refuses past the balance")
  check(math.abs(inv.mass("astro") - inv.GEAR.beacon.kg) < 1e-9, "a beacon weighs in the pack")
  check(#inv.items("astro") == 0, "gear is not cargo (the depot never sells it)")
  check(inv.removeGear("astro", "beacon", 1) == 1 and inv.gearCount("astro", "beacon") == 0, "planting takes it out")
  check(inv.addGear("astro", "beacon", 1) == 1, "picking up puts it back")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_relay: all %d checks passed", passed))
