-- COMMS NETWORK — who can talk to home, and through whom.
--
-- A few times a second this gathers every transmitter in the save:
--
--   the GROUND STATION   the Tracking Station's dish at the base, on the home
--                        world. DSN-scale power: the root of the network.
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
--     local net = findScript("comms")
--     net.statusOf(vesselNode.id)   { connected, strength, hops, names, parentPos, bandwidth }
--     net.linkLines()               { { ax,ay,az, bx,by,bz, strength, used } }
--     net.station()                 x, y, z of the ground station (or nil)

defaults = {
  --@header Network
  -- Seconds between solves. The answer moves with the craft, but slowly: a
  -- quarter second is plenty, and the solve is O(n²) in transmitters.
  --@range 0.05 2
  refresh = 0.25,
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local status = {}     -- id → status (see header)
local lines = {}      -- the last solve's usable links, as world segments
local nodes = {}      -- the last solve's transmitters (id → node)
local solve_t = -100
local station_pos = nil
local offline, offline_t = nil, -100

-- Published for the HUD and the tracking station.
solves = 0
transmitters = 0

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

local function solve()
  local E = ref("electronics")
  if not E then return end
  local list = {}
  local sx, sy, sz = station()
  if sx then
    station_pos = { x = sx, y = sy, z = sz }
    list[#list + 1] = { id = "home", name = "Ground station", x = sx, y = sy, z = sz, home = true,
                        power = E.COMMS.station }
  else
    station_pos = nil
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.commsNode then
      local cn = v.commsNode()
      if cn and cn.x and (cn.any or 0) <= 0 then
        cn = { x = cn.x, y = cn.y, z = cn.z, any = 0, relay = 0, rate = 0, silent = cn.silent }
      end
      if cn and cn.x then
        list[#list + 1] = { id = n.id, name = v.craftName or n.name or "Vessel", x = cn.x, y = cn.y, z = cn.z,
                            any = cn.any or 0, relay = cn.relay or 0, rate = cn.rate or 1, silent = cn.silent }
      end
    end
  end
  -- Craft off the scene barely move between solves and reading the fleet is a
  -- save read (a copy of every record): refreshed every two seconds.
  local fo = ref("flight_ops")
  if fo and fo.fleetOffline and (not offline or time - offline_t > 2.0) then
    offline, offline_t = fo.fleetOffline(), time
  end
  if offline then
    for _, r in ipairs(offline) do
      local powered = (r.charge or 0) > 0
      local ant = E.antennaSummary(r.parts or {}, nil, powered)
      local any = E.antennaSummary(r.parts or {}, nil, true)
      list[#list + 1] = { id = "f:" .. tostring(r.fid), name = r.name or "Vessel", x = r.wx, y = r.wy, z = r.wz,
                          any = ant.any, relay = ant.relay, rate = ant.rate, offline = true,
                          silent = (any.n == 0) and "no antenna aboard" or (not powered and "no power for its radio") or nil }
    end
  end
  local bodies = space.bodies() or {}
  local st, links = E.solveNetwork(list, bodies)
  local by = {}
  for _, nd in ipairs(list) do by[nd.id] = nd end
  -- Names along each path, and where the next hop is (the dishes point at it).
  for id, s in pairs(st) do
    local names = {}
    for i, pid in ipairs(s.path or {}) do
      if i > 1 then names[#names + 1] = by[pid] and by[pid].name or tostring(pid) end
    end
    s.names = names
    local p = s.parent and by[s.parent]
    if p then s.parentPos = { x = p.x, y = p.y, z = p.z } end
  end
  status, nodes = st, by
  local ls = {}
  for _, l in ipairs(links) do
    local a, b = by[l.a], by[l.b]
    if a and b then
      ls[#ls + 1] = { a = l.a, b = l.b, strength = l.strength, used = l.used,
                      ax = a.x, ay = a.y, az = a.z, bx = b.x, by = b.y, bz = b.z }
    end
  end
  lines = ls
  transmitters = #list
  solves = solves + 1
end

-- A craft's link home (by its root node id, or "f:<fid>" for one off the
-- scene). nil before the first solve or for a craft with no radio.
function statusOf(id)
  return status[id]
end

-- Every usable link at the last solve, endpoints in world space as of then.
-- The map moves the ends of live craft onto where they are now.
function linkLines()
  return lines
end

-- A transmitter from the last solve (its name, position, power).
function nodeOf(id) return nodes[id] end

-- Solve now (a probe that just moved two craft; the tracking station on open).
function refreshNow() solve(); solve_t = time end

function update(node, dt)
  if time - solve_t >= params.refresh then
    solve_t = time
    solve()
  end
end
