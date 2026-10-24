-- COMMS NETWORK — who can talk to home, and through whom.
--
-- ── THE API (for goals, missions, the map, the HUD) ─────────────────────────
-- Lives HERE, on the "Electronics" node of the system scene. Reach it with
--
--     local net = findScript("comms")
--
--   net.relayStats()       { ground = { [body] = n }, orbit = { [body] = n }, total = n,
--                            linked = { ground = { [body] = n }, orbit = { [body] = n }, total = n } }
--                          ground = relay beacons planted on that body AND relay-capable craft
--                          (a relay dish, or a beacon part) standing on its ground — a relay
--                          rover is a ground relay like a beacon; orbit = relay craft off the
--                          ground round that body; `linked` counts only those with a path home.
--   net.coverage(body)     { ground = 0..1, sky = 0..1, samples = n, ready }: the share of the body's
--                          surface (a fixed grid of electronics.COMMS.coverSamples points, a
--                          probe core's antenna 1 m off the ground) that links home through
--                          the ground station, relay beacons and landed relay craft only
--                          (`ground`), and
--                          through any relay at all, satellites included (`sky`). `ready` is
--                          false until that world's ground under the grid has been measured
--                          once (its terrain resident; then kept in the save) — before that the
--                          samples sit on the nominal sphere and the number can still shift.
--   net.linkedBodies()     { "Vever", "Iru", … } sorted: bodies with a relay on or round them
--                          (or the ground station) that has a path home.
--   net.networkVersion     a number that changes whenever the network CHANGES: a beacon placed
--                          or picked up, a link made or lost. Poll it (cheap) and compare
--                          with ~= (it starts again from 0 when the system scene loads), or
--   net.onNetworkChanged(fn)   fn(version) after each change; returns an unsubscribe function.
--                          (Listeners live as long as the scene: subscribe again after a load.)
--
-- All of it is cached: relayStats and linkedBodies are rebuilt once per network
-- change; coverage(body) is recomputed when the network changed (at most every
-- 0.5 s) or every 10 s while satellites move over it (or the ground under the
-- grid is still streaming in) — call it as often as you like. A recompute is
-- 200 samples against the relays in reach of that body.
--
-- RELAY BEACONS (the cheap ground relay, electronics.COMMS.beacon): the crew
-- carries them (inventory gear "beacon", bought at the base from the I panel)
-- and plants them from the tool belt (a beacon is on it while one is carried). They are kept HERE, in the save
-- ("comms.beacons" = the id list, "comms.beacon.<id>" = one each, body-relative),
-- and spawned as RelayBeacon nodes parented to their planet.
--
--   net.beaconList()                   { { id, name, body, x,y,z (antenna, world), gx,gy,gz (ground),
--                                         linked, strength, hops, names } }
--   net.placeBeacon(body, gx, gy, gz)  plant one at a world ground point → id
--   net.removeBeacon(id)               pick it up → true
--   net.beaconNear(x, y, z, r)         the nearest beacon within r m → entry, distance
--   net.previewLinks(gx, gy, gz)       what a beacon planted here would link to:
--                                      { { name, strength (path home), hop, home, dist, x,y,z }… }, connected
--   net.coverageGrid(body)             the map tint: { dirs = {{ux,uy,uz}…}, r = {…}, cov = {2|1|0…} }
--
-- ── THE SOLVE ───────────────────────────────────────────────────────────────
-- A few times a second this gathers every transmitter in the save:
--
--   the GROUND STATION   the Tracking Station's dish at the base, on the home
--                        world. DSN-scale power: the root of the network.
--   every RELAY BEACON   planted on the ground (above)
--   every LIVE craft     what its powered, extended antennas add up to
--                        (vessel_controller `commsNode`)
--   every craft OFF the  a fleet record not rebuilt yet (flight_ops
--   scene               `fleetOffline`): its antennas from its part records
--
-- and hands them to the rulebook (electronics.solveNetwork): the KSP link
-- budget (two antennas reach sqrt(P1·P2)), line of sight against every planet
-- and moon, relays chaining the signal home, and the strongest path for each
-- craft. Every craft then reads its own answer (`statusOf`), the orbit map
-- draws the links (`linkLines`), and the Tracking Station lists them.
--
-- What a link is FOR: a probe core takes commands only over one, and it is the
-- pipe science will be transmitted down (`bandwidth`, a placeholder for now).
--
--     net.statusOf(vesselNode.id)   { connected, strength, hops, names, parentPos, bandwidth }
--                                   (a beacon: statusOf("b:<id>"))
--     net.linkLines()               { { ax,ay,az, bx,by,bz, strength, used } }
--     net.station()                 x, y, z of the ground station (or nil)

defaults = {
  --@header Network
  -- Seconds between solves. The answer moves with the craft, but slowly: a
  -- quarter second is plenty, and the solve is O(n²) in transmitters.
  --@range 0.05 2
  refresh = 0.25,
  -- Coverage: the least time between recomputes after a change, and the most
  -- time a cached answer is kept while satellites move.
  --@range 0.5 10 --@units s
  cover_min = 0.5,
  --@range 2 60 --@units s
  cover_max = 10.0,
}

-- The clock, as of this script's last frame. Not `time` directly: these
-- functions are called from OTHER scripts (the goals, the map, the belt), and
-- the engine stamps `time` (and `params`) into a script's environment only
-- when one of ITS OWN hooks runs (floptle-script host.rs ~8299): called from
-- another script it is a frame stale, and nil before this script's first
-- frame in a scene — the goals poll the network from their start().
local clock = 0
local warned_time = false
local function now()
  if type(time) == "number" then
    clock = time
  elseif not warned_time then
    warned_time = true
    log("comms: `time` is " .. type(time) .. " in a call from another script; using this script's last frame time")
  end
  return clock
end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local status = {}     -- id → status (see header)
local lines = {}      -- the last solve's usable links, as world segments
local nodes = {}      -- the last solve's transmitters (id → node)
local list_last = {}  -- the last solve's transmitter list, in order
local solve_t = -100
local station_pos = nil
local offline, offline_t = nil, -100

-- Published for the HUD and the tracking station.
solves = 0
transmitters = 0
networkVersion = 0

-- ── change notification ─────────────────────────────────────────────────────

local listeners = {}
local derived = {}    -- per-version caches (relayStats, linkedBodies, ground solve)
local function bump()
  networkVersion = networkVersion + 1
  derived = {}
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, networkVersion)
    if not ok then log("comms: onNetworkChanged listener failed: " .. tostring(err)) end
  end
end

function onNetworkChanged(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do if f == fn then table.remove(listeners, i) return end end
  end
end

-- ── relay beacons ───────────────────────────────────────────────────────────

local beacons = nil   -- id → { id, name, body, x,y,z (body-relative ground), node }
local order = {}      -- ids, placed order

local function load_beacons()
  beacons, order = {}, {}
  for _, id in ipairs(save.get("comms.beacons") or {}) do
    local r = save.get("comms.beacon." .. tostring(id))
    if type(r) == "table" and r.b and r.x then
      beacons[id] = { id = id, name = r.n or ("Relay " .. tostring(id)), body = r.b, x = r.x, y = r.y, z = r.z }
      order[#order + 1] = id
    end
  end
end

local function write_index()
  save.set("comms.beacons", order)
end

local function up_of(b)
  local l = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
  if l < 1e-6 then return 0, 1, 0 end
  return b.x / l, b.y / l, b.z / l
end

-- Where a beacon's antenna is, in world space, now.
local function beacon_world(b, h)
  local body = space.body(b.body)
  if not body then return nil end
  local ux, uy, uz = up_of(b)
  h = h or 0
  return body.x + b.x + ux * h, body.y + b.y + uy * h, body.z + b.z + uz * h
end

-- The node in the world: parented to its planet like the base buildings
-- (local = body-relative), its +Y up the radial, the origin half its height
-- above the ground (the model is centred).
local function spawn_node(b)
  if b.node and b.node.valid then return true end
  if b.spawning then return false end
  local planet = find(b.body)
  if not planet then return false end
  local E = ref("electronics")
  local half = ((E and E.COMMS.beacon.height) or 2.4) * 0.5
  local ux, uy, uz = up_of(b)
  local wx, wy, wz = beacon_world(b, half)
  if not wx then return false end
  local lx, ly, lz = b.x + ux * half, b.y + uy * half, b.z + uz * half
  -- a forward that isn't the up: any tangent
  local fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
  if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
  b.spawning = true
  spawn("RelayBeacon", vec3(wx, wy, wz), function(inst)
    b.spawning = false
    if not beacons or beacons[b.id] ~= b then inst:destroy() return end
    inst:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz))
    inst.x, inst.y, inst.z = lx, ly, lz
    inst.name = b.name
    b.node = inst
  end, planet)
  return true
end

function beaconList()
  if not beacons then load_beacons() end
  local E = ref("electronics")
  local mast = E and E.COMMS.beacon.mast or 2.2
  local out = {}
  for _, id in ipairs(order) do
    local b = beacons[id]
    local x, y, z = beacon_world(b, mast)
    local gx, gy, gz = beacon_world(b, 0)
    local st = status["b:" .. tostring(id)]
    out[#out + 1] = { id = id, name = b.name, body = b.body, x = x, y = y, z = z, gx = gx, gy = gy, gz = gz,
                      linked = st and st.connected or false, strength = st and st.strength or 0,
                      hops = st and st.hops or 0, names = st and st.names or nil, node = b.node }
  end
  return out
end

function placeBeacon(bodyName, gx, gy, gz)
  if not beacons then load_beacons() end
  local body = space.body(bodyName or "")
  if not body then return nil, "no world there" end
  local seq = (save.get("comms.beaconSeq") or 0) + 1
  save.set("comms.beaconSeq", seq)
  local b = { id = seq, name = "Relay " .. seq, body = bodyName,
              x = gx - body.x, y = gy - body.y, z = gz - body.z }
  save.set("comms.beacon." .. seq, { n = b.name, b = b.body, x = b.x, y = b.y, z = b.z })
  beacons[seq] = b
  order[#order + 1] = seq
  write_index()
  spawn_node(b)
  log(string.format("comms: %s planted on %s", b.name, bodyName))
  refreshNow()
  return seq
end

function removeBeacon(id)
  if not beacons then load_beacons() end
  local b = beacons[id]
  if not b then return false end
  if b.node and b.node.valid then b.node:destroy() end
  beacons[id] = nil
  for i, v in ipairs(order) do if v == id then table.remove(order, i) break end end
  write_index()
  if save.delete then save.delete("comms.beacon." .. tostring(id)) else save.set("comms.beacon." .. tostring(id), false) end
  log(string.format("comms: %s picked up", b.name))
  refreshNow()
  return true
end

-- A revert to launch (vessel_spawner) puts the beacons back as they were at
-- the launch, with the pack: one planted since is taken up (the pack has it
-- again), one picked up since stands again. The record is plain data.
function beaconSnapshot()
  if not beacons then load_beacons() end
  local snap = { order = {}, rec = {} }
  for _, id in ipairs(order) do
    local b = beacons[id]
    snap.order[#snap.order + 1] = id
    snap.rec[id] = { n = b.name, b = b.body, x = b.x, y = b.y, z = b.z }
  end
  return snap
end

-- Returns how many beacons were taken up and how many stood again.
function beaconRestore(snap)
  if type(snap) ~= "table" or type(snap.order) ~= "table" then return 0, 0 end
  if not beacons then load_beacons() end
  local gone, back = 0, 0
  local was = {}
  for i, id in ipairs(order) do was[i] = id end
  for _, id in ipairs(was) do
    if not snap.rec[id] then
      local b = beacons[id]
      if b.node and b.node.valid then b.node:destroy() end
      beacons[id] = nil
      if save.delete then save.delete("comms.beacon." .. tostring(id)) else save.set("comms.beacon." .. tostring(id), false) end
      gone = gone + 1
    end
  end
  local new_order = {}
  for _, id in ipairs(snap.order) do
    local r = snap.rec[id]
    if not beacons[id] then
      beacons[id] = { id = id, name = r.n, body = r.b, x = r.x, y = r.y, z = r.z }
      save.set("comms.beacon." .. tostring(id), { n = r.n, b = r.b, x = r.x, y = r.y, z = r.z })
      back = back + 1
    end
    new_order[#new_order + 1] = id
  end
  order = new_order
  write_index()
  -- (comms.beaconSeq is left where it is: a reverted beacon's id is not reused)
  if gone + back > 0 then
    log(string.format("comms: revert — %d beacon(s) taken up, %d standing again", gone, back))
    for _, id in ipairs(order) do spawn_node(beacons[id]) end
    refreshNow()
  end
  return gone, back
end

function beaconNear(x, y, z, r)
  local best, bd = nil, r or 3.0
  for _, e in ipairs(beaconList()) do
    if e.gx then
      local d = math.sqrt((x - e.gx) ^ 2 + (y - e.gy) ^ 2 + (z - e.gz) ^ 2)
      if d < bd then best, bd = e, d end
    end
  end
  return best, best and bd or nil
end

-- ── the ground station ──────────────────────────────────────────────────────

local function world_of(n)
  if n.worldX then return n.worldX, n.worldY, n.worldZ end
  local x, y, z = n.x, n.y, n.z
  local p, guard = n.parent, 0
  while p and guard < 8 do
    x, y, z = x + p.x, y + p.y, z + p.z
    p, guard = p.parent, guard + 1
  end
  return x, y, z
end

-- The ground station: the Tracking Station's dish, a few metres up its mast;
-- the base centre if the building isn't standing (a save mid-siting).
function station()
  local bf = ref("base_facilities")
  local body = bf and bf.baseBody and space.body(bf.baseBody)
  local x, y, z
  local dish = find("FacTracking")
  if dish then
    x, y, z = world_of(dish)
  elseif bf and bf.sited and bf.baseX then
    x, y, z = bf.baseX, bf.baseY, bf.baseZ
  end
  if not x then return nil end
  if body then
    local ux, uy, uz = x - body.x, y - body.y, z - body.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    if l > 1e-3 then x, y, z = x + ux / l * 6, y + uy / l * 6, z + uz / l * 6 end
  end
  return x, y, z
end

local function station_body()
  local bf = ref("base_facilities")
  return bf and bf.baseBody or nil
end

-- ── the solve ───────────────────────────────────────────────────────────────

-- Is a craft off the ground round `body`? (Relay stats file a relay craft as
-- an orbiter or as a lander by this.)
local function aloft(x, y, z, body)
  local b = body and space.body(body)
  if not b then return true end
  local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
  return d > b.radius + math.max(60, b.radius * 0.12)
end

local last_sig = ""

-- ── one instant ─────────────────────────────────────────────────────────────
-- EVERY position the network uses is kept RELATIVE TO ITS WORLD (`frame` =
-- the body's name, `rx..rz` = the offset) and turned into world space against
-- ONE read of space.bodies() at the moment it is used. These worlds move a
-- few hundred metres a second on their rails: the ground station read in one
-- frame and a rover read a tenth of a second earlier, or a relay remembered
-- from the last solve set against the planet where it is now, put antennas
-- tens of metres into the ground or up in the air. That made links blink and
-- swung the coverage map between ~0 and ~45 % of the world from one recompute
-- to the next — which is how a relay rover parked on a mountain (whose moving
-- relay made coverage recompute every few seconds) seemed to drive coverage
-- to zero (2026-10-23).
local function body_index(bodies)
  local by = {}
  for _, b in ipairs(bodies or {}) do by[b.name] = b end
  return by
end

local function finite(v) return type(v) == "number" and v == v and v > -math.huge and v < math.huge end

-- The world a point belongs to (the smallest sphere of influence holding it),
-- from the same read.
local function frame_of(x, y, z, bodies)
  local best, bs = nil, math.huge
  for _, b in ipairs(bodies or {}) do
    local soi = (b.soi or -1) < 0 and math.huge or b.soi
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
    if d <= soi and soi < bs then best, bs = b, soi end
  end
  return best
end

-- Pin a node (world x,y,z as of `by`'s read) to its world.
local function pin(nd, by, bodies, name)
  local b = (name and by[name]) or frame_of(nd.x, nd.y, nd.z, bodies)
  if b then
    nd.frame, nd.rx, nd.ry, nd.rz = b.name, nd.x - b.x, nd.y - b.y, nd.z - b.z
  end
  return nd
end

-- Where a pinned node is in the read `by` (unpinned: where it was).
local function place(nd, by)
  local b = nd.frame and by[nd.frame]
  if b then return b.x + nd.rx, b.y + nd.ry, b.z + nd.rz end
  return nd.x, nd.y, nd.z
end

-- Copies of `list` placed at the read `bodies` (the nodes themselves untouched).
local function placed(list, bodies)
  local by = body_index(bodies)
  local out = {}
  for i, nd in ipairs(list) do
    local c = {}
    for k, v in pairs(nd) do c[k] = v end
    c.x, c.y, c.z = place(nd, by)
    out[i] = c
  end
  return out
end

local function solve()
  local E = ref("electronics")
  if not E then return end
  if not beacons then load_beacons() end
  -- the one read every position below is taken against
  local bodies = space.bodies() or {}
  local by = body_index(bodies)
  local list = {}
  local sx, sy, sz = station()
  if sx and finite(sx) and finite(sy) and finite(sz) then
    station_pos = { x = sx, y = sy, z = sz }
    local sb = station_body()
    list[#list + 1] = pin({ id = "home", name = "Ground station", x = sx, y = sy, z = sz, home = true,
                            power = E.COMMS.station, body = sb }, by, bodies, sb)
  else
    station_pos = nil
  end
  local mast = E.COMMS.beacon.mast
  for _, id in ipairs(order) do
    local b = beacons[id]
    local x, y, z = beacon_world(b, mast)
    if x then
      local nd = E.beaconNode("b:" .. tostring(id), b.name, x, y, z)
      nd.body = b.body
      list[#list + 1] = pin(nd, by, bodies, b.body)
    end
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.commsNode then
      local cn = v.commsNode()
      if cn and cn.x and (cn.any or 0) <= 0 then
        cn = { x = cn.x, y = cn.y, z = cn.z, ox = cn.ox, oy = cn.oy, oz = cn.oz, any = 0, relay = 0, rate = 0,
               silent = cn.silent }
      end
      if cn and cn.x then
        -- The craft where it is NOW (its root node, read in this frame like
        -- the bodies) plus its antenna's offset from the root; a craft that
        -- doesn't publish the offset is taken where it last said it was.
        local x, y, z = cn.x, cn.y, cn.z
        local rx, ry, rz = n.worldX or n.x, n.worldY or n.y, n.worldZ or n.z
        if cn.ox and finite(rx) and finite(ry) and finite(rz) then
          x, y, z = rx + cn.ox, ry + cn.oy, rz + cn.oz
        end
        if finite(x) and finite(y) and finite(z) then
          local nd = pin({ id = n.id, name = v.craftName or n.name or "Vessel", x = x, y = y, z = z,
                           any = cn.any or 0, relay = cn.relay or 0, rate = cn.rate or 1, silent = cn.silent,
                           craft = true }, by, bodies)
          list[#list + 1] = nd
        end
      end
    end
  end
  -- Craft off the scene barely move between solves and reading the fleet is a
  -- save read (a copy of every record): refreshed every two seconds — and
  -- pinned to their worlds as read then, so a two-second-old record is placed
  -- where its world is NOW (a landed rover 480 m behind its planet, before).
  local fo = ref("flight_ops")
  if fo and fo.fleetOffline and (not offline or now() - offline_t > 2.0) then
    offline, offline_t = fo.fleetOffline(), now()
    local ob = space.bodies() or {}
    local oby = body_index(ob)
    for _, r in ipairs(offline) do
      if finite(r.wx) and finite(r.wy) and finite(r.wz) then
        local p = pin({ x = r.wx, y = r.wy, z = r.wz }, oby, ob, r.body)
        r.frame, r.rx, r.ry, r.rz = p.frame, p.rx, p.ry, p.rz
      end
    end
  end
  if offline then
    for _, r in ipairs(offline) do
      if finite(r.wx) and finite(r.wy) and finite(r.wz) then
        local powered = (r.charge or 0) > 0
        local ant = E.antennaSummary(r.parts or {}, nil, powered)
        local any = E.antennaSummary(r.parts or {}, nil, true)
        local nd = { id = "f:" .. tostring(r.fid), name = r.name or "Vessel", x = r.wx, y = r.wy, z = r.wz,
                     any = ant.any, relay = ant.relay, rate = ant.rate, offline = true, craft = true,
                     frame = r.frame, rx = r.rx, ry = r.ry, rz = r.rz,
                     silent = (any.n == 0) and "no antenna aboard" or (not powered and "no power for its radio") or nil }
        nd.x, nd.y, nd.z = place(nd, by)
        list[#list + 1] = nd
      end
    end
  end
  -- A relay craft standing on a world (a rover with a relay beacon or a dish
  -- parked on a ridge) is a GROUND relay, exactly like a planted beacon: it
  -- carries the ground network, not just the sky number.
  for _, nd in ipairs(list) do
    if nd.craft and (nd.relay or 0) > 0 and nd.frame then
      nd.landed = not aloft(nd.x, nd.y, nd.z, nd.frame)
    end
  end
  local st, links = E.solveNetwork(list, bodies)
  local byid = {}
  for _, nd in ipairs(list) do byid[nd.id] = nd end
  -- Names along each path, and where the next hop is (the dishes point at it).
  for id, s in pairs(st) do
    local names = {}
    for i, pid in ipairs(s.path or {}) do
      if i > 1 then names[#names + 1] = byid[pid] and byid[pid].name or tostring(pid) end
    end
    s.names = names
    local p = s.parent and byid[s.parent]
    if p then s.parentPos = { x = p.x, y = p.y, z = p.z } end
  end
  status, nodes, list_last = st, byid, list
  local ls = {}
  for _, l in ipairs(links) do
    local a, b = byid[l.a], byid[l.b]
    if a and b then
      ls[#ls + 1] = { a = l.a, b = l.b, strength = l.strength, used = l.used,
                      ax = a.x, ay = a.y, az = a.z, bx = b.x, by = b.y, bz = b.z }
    end
  end
  lines = ls
  transmitters = #list
  solves = solves + 1
  -- THE CHANGE SIGNATURE: who is connected, and through whom the relays are.
  -- Craft moving along their orbits don't change it; a link made or lost does.
  local parts = {}
  for _, nd in ipairs(list) do
    local s = st[nd.id]
    local c = s and s.connected
    if (nd.relay or 0) > 0 or nd.home then
      parts[#parts + 1] = tostring(nd.id) .. (c and (">" .. tostring(s.parent or "")) or "-")
    else
      parts[#parts + 1] = tostring(nd.id) .. (c and "+" or "-")
    end
  end
  table.sort(parts)
  local sig = table.concat(parts, ",")
  if sig ~= last_sig then
    last_sig = sig
    bump()
  end
end

-- A craft's link home (by its root node id, or "f:<fid>" for one off the
-- scene, "b:<id>" for a beacon). nil before the first solve or for a craft
-- with no radio.
function statusOf(id)
  return status[id]
end

-- Every usable link at the last solve, its ends placed where their worlds
-- are NOW (the map also moves the ends of live craft onto the craft).
function linkLines()
  local by = body_index(space.bodies() or {})
  for _, l in ipairs(lines) do
    local a, b = nodes[l.a], nodes[l.b]
    if a and b then
      l.ax, l.ay, l.az = place(a, by)
      l.bx, l.by, l.bz = place(b, by)
    end
  end
  return lines
end

-- A transmitter from the last solve (its name, position, power).
function nodeOf(id) return nodes[id] end

-- Solve now (a probe that just moved two craft; the tracking station on open).
function refreshNow() solve(); solve_t = now() end

-- ── what a beacon planted HERE would link to (the placement preview) ────────

function previewLinks(gx, gy, gz)
  local E = ref("electronics")
  if not E then return {}, false end
  local name = space.dominant(gx, gy, gz)
  local body = name and space.body(name)
  local x, y, z = gx, gy, gz
  if body then
    local ux, uy, uz = gx - body.x, gy - body.y, gz - body.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    if l > 1e-6 then
      local m = E.COMMS.beacon.mast
      x, y, z = gx + ux / l * m, gy + uy / l * m, gz + uz / l * m
    end
  end
  local p = E.COMMS.beacon.power
  local bodies = space.bodies() or {}
  local out, connected = {}, false
  for _, nd in ipairs(placed(list_last, bodies)) do
    local up = nd.home and (nd.power or E.COMMS.station) or (nd.relay or 0)
    local st = status[nd.id]
    if up > 0 and st and st.connected then
      local range = E.linkRange(p, up)
      local d = math.sqrt((x - nd.x) ^ 2 + (y - nd.y) ^ 2 + (z - nd.z) ^ 2)
      if d < range and d > 0.5 then
        local s = E.linkStrength(d, range)
        if s > 1e-4 and E.segmentBlocked(x, y, z, nd.x, nd.y, nd.z, bodies, E.COMMS.occlude, nil, true,
            E.COMMS.beacon.mast, nd.agl) == nil then
          out[#out + 1] = { name = nd.name, strength = s * (st.strength or 1), hop = s, home = nd.home == true, dist = d,
                            x = nd.x, y = nd.y, z = nd.z }
          connected = true
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.strength > b.strength end)
  return out, connected
end

-- ── stats, coverage, linked bodies ──────────────────────────────────────────

local function dominant(x, y, z)
  return space.dominant(x, y, z)
end

function relayStats()
  if derived.stats then return derived.stats end
  if not beacons then load_beacons() end
  local s = { ground = {}, orbit = {}, total = 0, linked = { ground = {}, orbit = {}, total = 0 } }
  local function add(t, k) t[k] = (t[k] or 0) + 1 end
  for _, id in ipairs(order) do
    local b = beacons[id]
    add(s.ground, b.body)
    s.total = s.total + 1
    local st = status["b:" .. tostring(id)]
    if st and st.connected then add(s.linked.ground, b.body); s.linked.total = s.linked.total + 1 end
  end
  for _, nd in ipairs(list_last) do
    if not nd.home and not nd.beacon and (nd.relay or 0) > 0 then
      local bn = nd.frame or dominant(nd.x, nd.y, nd.z)
      local st = status[nd.id]
      local linked = st and st.connected
      if bn and nd.landed then
        -- a relay craft standing on the ground counts as a ground relay
        add(s.ground, bn)
        s.total = s.total + 1
        if linked then add(s.linked.ground, bn); s.linked.total = s.linked.total + 1 end
      elseif bn and aloft(nd.x, nd.y, nd.z, bn) then
        add(s.orbit, bn)
        s.total = s.total + 1
        if linked then add(s.linked.orbit, bn); s.linked.total = s.linked.total + 1 end
      end
    end
  end
  derived.stats = s
  return s
end

function linkedBodies()
  if derived.bodies then return derived.bodies end
  local set = {}
  for _, nd in ipairs(list_last) do
    local st = status[nd.id]
    if st and st.connected and (nd.home or (nd.relay or 0) > 0) then
      local bn = nd.body or nd.frame or dominant(nd.x, nd.y, nd.z)
      if bn then set[bn] = true end
    end
  end
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  derived.bodies = out
  return out
end

-- The relays with a path home, split: those the GROUND network alone carries
-- (the station, beacons and relay craft standing on the ground, reaching it
-- through each other only), and all of them. Kept pinned to their worlds
-- (`frame`, `rx..rz`): coverage places them against its own read.
local function is_ground(nd) return nd.home or nd.beacon or nd.landed end
local function relay_sets()
  if derived.relays then return derived.relays.ground, derived.relays.all end
  local E = ref("electronics")
  local bodies = space.bodies() or {}
  local now_list = placed(list_last, bodies)
  local ground_nodes = {}
  for _, nd in ipairs(now_list) do
    if is_ground(nd) then ground_nodes[#ground_nodes + 1] = nd end
  end
  local gst = (E and #ground_nodes > 0) and E.solveNetwork(ground_nodes, bodies) or {}
  local ground, all = {}, {}
  for _, nd in ipairs(list_last) do
    local up = nd.home and (nd.power or (E and E.COMMS.station) or 0) or (nd.relay or 0)
    if up > 0 then
      local st = status[nd.id]
      local r = { id = nd.id, x = nd.x, y = nd.y, z = nd.z, power = up, beacon = nd.beacon, home = nd.home,
                  agl = nd.agl, landed = nd.landed, frame = nd.frame, rx = nd.rx, ry = nd.ry, rz = nd.rz }
      if st and st.connected then all[#all + 1] = r end
      if is_ground(nd) and gst[nd.id] and gst[nd.id].connected then ground[#ground + 1] = r end
    end
  end
  derived.relays = { ground = ground, all = all }
  return ground, all
end

-- The ground under each grid direction, as a radius from the body's centre:
-- found by sphere-tracing the terrain field down the radial (terrain.query)
-- while that world's terrain is resident, and KEPT IN THE SAVE once the whole
-- grid is known ("comms.ground.<body>", 2 characters a sample, 0.25 m steps),
-- so a coverage number never moves because the ground streamed in late. Until
-- the grid is complete EVERY sample uses the nominal radius (never a mix) and
-- coverage() says ready = false.
local ground_r = {}   -- body → { [i] = radius, R, done }
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function enc_radii(g, R, n)
  local out = {}
  for i = 1, n do
    local v = math.floor((g[i] - R + 512) * 4 + 0.5)
    if v < 0 then v = 0 elseif v > 4095 then v = 4095 end
    local hi, lo = math.floor(v / 64), v % 64
    out[#out + 1] = B64:sub(hi + 1, hi + 1) .. B64:sub(lo + 1, lo + 1)
  end
  return table.concat(out)
end
local function dec_radii(str, R, n)
  if type(str) ~= "string" or #str ~= n * 2 then return nil end
  local g = {}
  for i = 1, n do
    local hi = B64:find(str:sub(i * 2 - 1, i * 2 - 1), 1, true)
    local lo = B64:find(str:sub(i * 2, i * 2), 1, true)
    if not (hi and lo) then return nil end
    g[i] = R + ((hi - 1) * 64 + (lo - 1)) / 4 - 512
  end
  return g
end

local function ground_radii(name, body, grid)
  local g = ground_r[name]
  if g and g.done then return g end
  local w = save.get("world." .. name)
  local R = (w and w.radius) or body.radius or 100
  if not g then
    g = dec_radii(save.get("comms.ground." .. name), R, #grid) or {}
    g.R = R
    g.done = g[#grid] ~= nil
    ground_r[name] = g
    if g.done then return g end
  end
  local top = R + ((w and w.relief) or R * 0.05) * 2 + 20
  local missing = 0
  for i, u in ipairs(grid) do
    if not g[i] then
      local r, found = top, false
      if terrain and terrain.query then
        for _ = 1, 40 do
          local q = terrain.query(body.x + u[1] * r, body.y + u[2] * r, body.z + u[3] * r)
          if not q then break end
          if q < 0.25 then found = true break end
          r = r - q
          if r < R * 0.5 then break end
        end
      end
      if found then g[i] = r else missing = missing + 1 end
    end
  end
  g.done = missing == 0
  if g.done then save.set("comms.ground." .. name, enc_radii(g, R, #grid)) end
  return g
end

local cover = {}      -- body → { t, version, ground, sky, flags, r }
local cover_err = false

local function compute_cover(name)
  local E = ref("electronics")
  -- one read of the bodies: the samples and every relay are placed against it
  local bodies = space.bodies() or {}
  local by = body_index(bodies)
  local body = by[name or ""]
  if not (E and body) then return nil end
  local grid = E.surfaceGrid(E.COMMS.coverSamples)
  local radii = ground_radii(name, body, grid)
  local ground, all = relay_sets()
  local function at_now(list)
    local out = {}
    for i, r in ipairs(list) do
      local c = {}
      for k, v in pairs(r) do c[k] = v end
      c.x, c.y, c.z = place(r, by)
      out[i] = c
    end
    return out
  end
  ground, all = at_now(ground), at_now(all)
  -- Only relays near enough to matter: the ground set's on this body, and any
  -- relay within reach of its surface (a satellite overhead, a moon's beacon).
  local rx = E.COMMS.coverRx
  local function near(list)
    local out = {}
    for _, r in ipairs(list) do
      local d = math.sqrt((r.x - body.x) ^ 2 + (r.y - body.y) ^ 2 + (r.z - body.z) ^ 2)
      if d - body.radius * 1.2 < E.linkRange(rx, r.power) then out[#out + 1] = r end
    end
    return out
  end
  local g_rel, a_rel = near(ground), near(all)
  local lift = E.COMMS.coverLift
  local flags, rs = {}, {}
  local ng, ns = 0, 0
  for i, u in ipairs(grid) do
    local r = (radii.done and radii[i] or radii.R or body.radius) + lift
    rs[i] = r
    local px, py, pz = body.x + u[1] * r, body.y + u[2] * r, body.z + u[3] * r
    local f = 0
    if #g_rel > 0 and E.hears(px, py, pz, rx, g_rel, bodies) > 0 then
      f = 2
    elseif #a_rel > #g_rel and E.hears(px, py, pz, rx, a_rel, bodies) > 0 then
      f = 1
    end
    flags[i] = f
    if f == 2 then ng = ng + 1 end
    if f >= 1 then ns = ns + 1 end
  end
  local n = #grid
  -- moving relays (anything not on the ground) make the answer go stale
  local moving = false
  for _, r in ipairs(a_rel) do if not (r.home or r.beacon) then moving = true end end
  local c = { t = now(), version = networkVersion, ground = ng / n, sky = ns / n, samples = n,
              flags = flags, r = rs, moving = moving, radiiDone = radii.done }
  cover[name] = c
  return c
end

local function cover_of(name)
  local c = cover[name]
  if c then
    local age = now() - c.t
    local stale = (c.version ~= networkVersion and age >= ((params and params.cover_min) or 0.5))
      or ((c.moving or not c.radiiDone) and age >= ((params and params.cover_max) or 10.0))
    if not stale then return c end
  end
  -- A failure here must never leave the map at zero: keep the last answer.
  local ok, fresh = pcall(compute_cover, name)
  if not ok then
    if not cover_err then
      cover_err = true
      log("comms: coverage of " .. tostring(name) .. " failed: " .. tostring(fresh))
    end
    if c then c.t = now() end
    return c
  end
  return fresh or c
end

function coverage(name)
  local c = cover_of(name)
  if not c then return { ground = 0, sky = 0, samples = 0, ready = false } end
  return { ground = c.ground, sky = c.sky, samples = c.samples, ready = c.radiiDone == true }
end

function coverageGrid(name)
  local c = cover_of(name)
  local E = ref("electronics")
  if not (c and E) then return nil end
  return { dirs = E.surfaceGrid(E.COMMS.coverSamples), r = c.r, cov = c.flags,
           ground = c.ground, sky = c.sky, version = c.version }
end

-- ── the frame ───────────────────────────────────────────────────────────────

function start(node)
  load_beacons()
end

function update(node, dt)
  if not beacons then load_beacons() end
  -- Beacon nodes: (re)spawned once their planet's node exists.
  for _, id in ipairs(order) do
    local b = beacons[id]
    if not (b.node and b.node.valid) then spawn_node(b) end
  end
  if now() - solve_t >= (params.refresh or 0.25) then
    solve_t = now()
    solve()
  end
end
