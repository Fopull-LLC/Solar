-- SUPPLY CRATES — steel field crates left round the base, for the crew's kit
-- and ore between trips (playtest 2026-10-27: "supply crates around the base
-- for storage, which persists in the save").
--
-- WHAT THEY ARE. Five ribbed olive-drab crates (prefabs/SupplyCrate,
-- tools/gen_crate.py): two against the Commerce Depot's front wall, one at
-- the VAB's apron, one beside the Command Centre's walk and one on the fuel
-- spur by the pad — where you come back to with a full pack or set off from.
-- Static and heavy: you walk into one, you stand on it, the gravity gun
-- strains at it. Each is an inventory container, "crate:<n>" (inventory.lua),
-- 400 kg and 480 L (items.CRATE_KG, items.VOL.crate): materials and items,
-- moved by hand between the crate and the pack of whoever is standing at it.
--
-- THE CONTENTS ARE THE SAVE'S (`inv.crate:<n>`, `inv.gear.crate:<n>`, the
-- fills beside them) like every other container, so a crate keeps what is in
-- it across sessions; the crates themselves are laid out again each session
-- from LAYOUT in the base's own frame (base_facilities frameOf / dirAt), on
-- the terrain under each spot (terrain.raycast: the ground, never a prop or
-- a roof), parented to the home planet so they ride it.
--
-- OPENING ONE. Walk up to it (within `reach` of its side): facility_menu
-- shows "Open the supply crate · E" and E opens the suit pack's panel
-- (inventory_panel) with the crate beside the pack — click a row to move it.
-- A right-click on a crate offers the same (context_registry "prop").
--
-- Pure parts (luajit, tests/smoke_crates.lua): LAYOUT, cidOf, isCrate,
-- labelOf, layoutOf, pick(list, x,y,z, reach).
--
--     local sc = findScript("supply_crates")
--     sc.nearAstro(astroNode)   → { id, cid, name, node }, d   (within reach)
--     sc.list()                 → { { id, cid, name, node? } … }

defaults = {
  --- How close (m, from the crew to the crate's centre) E opens it.
  --@range 1 6 --@units m
  reach = 2.4,
  --- 0 lays out nothing.
  --@range 0 1
  enabled = 1,
}

-- (u east, v north) in the base frame, `along` the axis the crate's long side
-- lies on ("u" | "v"), and a name to tell them apart. The depot's front wall
-- is at v = 3, its yard strip u −59..−41; the VAB apron's west edge u = −24;
-- the Command walk u 46..54; the fuel spur v 101..107 west of the pad lot.
LAYOUT = {
  { id = 1, u = -58.9, v = 1.8, along = "v", name = "Depot crate A" },
  { id = 2, u = -58.0, v = 1.8, along = "v", name = "Depot crate B" },
  { id = 3, u = -21.5, v = -3.4, along = "u", name = "Apron crate" },
  { id = 4, u = 46.8, v = 0.9, along = "u", name = "Command crate" },
  { id = 5, u = -24.5, v = 103.0, along = "u", name = "Pad crate" },
}

function cidOf(id) return "crate:" .. tostring(id) end
function isCrate(cid) return type(cid) == "string" and cid:sub(1, 6) == "crate:" end
function layoutOf(id)
  id = tonumber(id)
  for _, e in ipairs(LAYOUT) do if e.id == id then return e end end
  return nil
end
function labelOf(cid)
  if not isCrate(cid) then return nil end
  local e = layoutOf(cid:sub(7))
  return e and e.name or ("Supply crate " .. cid:sub(7))
end

-- The nearest of `list` ({ x, y, z } each) within `reach` of a point. → e, d
function pick(list, x, y, z, reach)
  local best, bd = nil, reach or math.huge
  for _, e in ipairs(list or {}) do
    if e.x then
      local d = math.sqrt((x - e.x) ^ 2 + (y - e.y) ^ 2 + (z - e.z) ^ 2)
      if d < bd then best, bd = e, d end
    end
  end
  return best, best and bd or nil
end

-- ── in the world ────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function unit(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 1, 0 end
  return x / l, y / l, z / l
end

local nodes = {}      -- id → node
local spawning = {}   -- id → true while a spawn is in flight
local tries = {}      -- id → failed placements this session
local placed_body = nil
local next_t = 0
HALF_H = 0.312        -- the model is 0.633 m tall, centred: a few mm sunk into the ground

-- The base frame from the save (base_props' reading of it).
local function base_frame()
  local bf = ref("base_facilities")
  if not (bf and bf.sited and bf.frameOf and bf.dirAt) then return nil end
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (type(name) == "string" and bx and by and bz) then return nil end
  local R = save.get("base.r") or len(bx, by, bz)
  return bf.frameOf({ x = bx, y = by, z = bz }, save.get("base.heading") or 0, R), name, R, bf
end

-- Lay one crate: the terrain under its spot, the crate on it, its long side
-- along the layout axis. → true once a spawn is under way (or done).
local function place(e, Fr, body, R, bf)
  local planet = find and find(body.name)
  if not planet then return false end
  local d = bf.dirAt(Fr, e.u, e.v)
  local top = R + 80.0
  local o = vec3(body.x + d.x * top, body.y + d.y * top, body.z + d.z * top)
  local h = terrain and terrain.raycast and terrain.raycast(o, vec3(-d.x, -d.y, -d.z), 200.0)
  if not (h and h.pos and h.exact ~= false) then return false end
  -- the long side's direction, in the tangent plane here
  local ax = e.along == "u" and Fr.eu or Fr.ev
  local k = ax.x * d.x + ax.y * d.y + ax.z * d.z
  local fx, fy, fz = unit(ax.x - d.x * k, ax.y - d.y * k, ax.z - d.z * k)
  -- body-relative (the planet node's frame), half the crate over the ground
  local lx = h.pos.x - body.x + d.x * HALF_H
  local ly = h.pos.y - body.y + d.y * HALF_H
  local lz = h.pos.z - body.z + d.z * HALF_H
  spawning[e.id] = true
  spawn("SupplyCrate", vec3(body.x + lx, body.y + ly, body.z + lz), function(n)
    spawning[e.id] = nil
    if not valid(n) then return end
    if valid(nodes[e.id]) then n:destroy() return end
    if n.setUp then n:setUp(vec3(d.x, d.y, d.z), vec3(fx, fy, fz)) end
    n.x, n.y, n.z = lx, ly, lz
    nodes[e.id] = n
  end, planet)
  return true
end

-- Every crate: { id, cid, name, node (nil until it stands) }.
function list()
  local out = {}
  for _, e in ipairs(LAYOUT) do
    out[#out + 1] = { id = e.id, cid = cidOf(e.id), name = e.name, node = valid(nodes[e.id]) and nodes[e.id] or nil }
  end
  return out
end

-- The crate node → its entry (the context menu's pick, a probe).
function ofNode(n)
  if not n then return nil end
  for _, e in ipairs(LAYOUT) do
    local c = nodes[e.id]
    if valid(c) and (c == n or c.id == n.id or (n.parent and (n.parent == c or n.parent.id == c.id))) then
      return { id = e.id, cid = cidOf(e.id), name = e.name, node = c }
    end
  end
  return nil
end

-- The crate the crew member `a` (a node) is standing at, within reach. → e, d
function nearAstro(a, reach)
  if not (a and a.distanceTo) then return nil end
  local best, bd = nil, reach or params.reach
  for _, e in ipairs(LAYOUT) do
    local c = nodes[e.id]
    if valid(c) then
      local d = a:distanceTo(c)
      if d and d < bd then best, bd = { id = e.id, cid = cidOf(e.id), name = e.name, node = c }, d end
    end
  end
  return best, best and bd or nil
end
placed = 0   -- crates standing (probes)

-- Open the crate in the suit pack's panel.
function open(cid)
  local ip = ref("inventory_panel")
  if ip and ip.openCrate then return ip.openCrate(cid) end
  return false
end

-- ── the right-click menu (context_registry "prop") ──────────────────────────
local provider_on = nil
local function provider(t, ctx)
  local e = t and ofNode(t.node)
  if not e then return {} end
  local inv = ref("inventory")
  local out = {}
  if inv then
    out[#out + 1] = { type = "meter", id = "load", label = "LOAD",
      frac = function() local c = inv.cap(e.cid); return c > 0 and inv.mass(e.cid) / c or 0 end,
      value = function() return (inv.lineFull or inv.line)(e.cid) end }
    local n = 0
    for _, g in ipairs(inv.itemList and inv.itemList(e.cid) or {}) do n = n + g.n end
    for _, it in ipairs(inv.items(e.cid)) do n = n + it.n end
    out[#out + 1] = { type = "info", id = "holds", label = "HOLDS", value = n == 0 and "nothing" or string.format("%d piece%s", n, n == 1 and "" or "s") }
  end
  out[#out + 1] = { type = "action", id = "openCrate", label = "Open the crate", hint = "E",
    enabled = function()
      local a = ctx and ctx.actor
      return a and a.kind == "crew" and a.node and a.node.distanceTo and a.node:distanceTo(e.node) < params.reach + 1.5 or false
    end,
    why = "walk up to it",
    act = function() return open(e.cid) end }
  return out, string.upper(e.name), "supply crate · 400 kg · 480 L"
end

function start(node)
  placed_body = nil
end

function update(node, dt)
  if (params.enabled or 1) <= 0 or not spawn then return end
  -- the right-click rows, once the registry is there
  if not provider_on then
    local reg = ref("context_registry")
    if reg and reg.register then
      reg.register("prop", provider, { id = "supply_crates", order = 5 })
      provider_on = true
    end
  end
  if (time or 0) < next_t then return end
  next_t = (time or 0) + 1.0
  local Fr, name, R, bf = base_frame()
  if not Fr then return end
  local body = space.body(name)
  if not body then return end
  if placed_body ~= name then
    placed_body = name
    for id, n in pairs(nodes) do if valid(n) then n:destroy() end nodes[id] = nil end
    tries = {}
  end
  -- Only once the crew is near the base (its ground is resident).
  local a = find and find("Astronaut")
  if a and len(a.x - (body.x + Fr.c.x * R), a.y - (body.y + Fr.c.y * R), a.z - (body.z + Fr.c.z * R)) > 900 then return end
  local n_ok = 0
  for _, e in ipairs(LAYOUT) do
    if valid(nodes[e.id]) then
      n_ok = n_ok + 1
    elseif not spawning[e.id] and (tries[e.id] or 0) < 120 then
      if not place(e, Fr, body, R, bf) then tries[e.id] = (tries[e.id] or 0) + 1 end
    end
  end
  if n_ok ~= placed and log and n_ok == #LAYOUT then log(string.format("supply crates: %d standing round the base", n_ok)) end
  placed = n_ok
end
