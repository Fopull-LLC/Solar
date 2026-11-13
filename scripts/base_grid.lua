-- BASE GRID — the shared power grid of a base (deep-space addendum M6, with
-- B9b's cables; docs/base-building.md §12). Q19, settled: every structure
-- within 150 m of a base's tower shares ONE grid automatically; beyond that a
-- Power Cable (base_cable.lua) joins two grids into one.
--
-- On the Build Kit node (scenes/system.ron) beside bases.lua and base_tower.lua.
-- The rulebook half is pure (it loads in a luajit test: tests/smoke_base_grid.lua);
-- the scene half keeps the grids in step with the records and the clock.
--
-- ── WHAT A GRID IS ──────────────────────────────────────────────────────────
--
--   members   a union of structures: those within RADIUS of a standing tower
--             join that tower's base, and a cable joins the structures at its
--             two ends. A grid is one connected set (a union-find over sids).
--   sources   Isotope Skids (`power.kind = "rtg"`: gen EC/s, always) and Solar
--             Arrays (`"solar"`: electronics.solarOutput at the array, by the
--             sun's place in its world's year). Reactors (step 11) join here.
--   loads     each tower's 2 EC/s (parts_base tower.draw), in base order; a
--             part with `power.kind = "load"` draws its `use` (none yet: the
--             shed and the hab have no loads until they are lived in).
--   storage   Battery Banks (`"store"`: cap EC, charged at eff). A grid holds
--             one pool: every bank in it at the same state of charge.
--
-- ── THE SOLVE (on change, and at most every `every` seconds; never a frame) ──
--
-- The light is the only thing that changes by itself, and on these worlds it
-- is periodic: a world doesn't turn, so a spot's day is its YEAR round its
-- sun. The year is cut into SLOTS slots, anchored once on the agency clock
-- (`grid.a0`, saved), and each array's output is worked out once per slot of
-- that year (its PROFILE, rebuilt only when the grid changes) by moving the
-- world on its conic round the sun (electronics.kepler) and asking
-- electronics.solarOutput there. Within a slot the supply is constant, so the
-- store follows a straight line, clamped at full and at empty:
--
--     P = supply − load      P ≥ 0: e ← min(C, e + eff·P·dt)
--                            P < 0: e ← e + P·dt until empty; then the loads
--                                   are shed (towers in base order) until the
--                                   supply covers them again
--
-- That is exact for any step, so `advance` takes one call for any dt and lands
-- where any number of small calls do (the smoke test checks it to 1e-6), and
-- the same call catches a base up on the save clock when it loads (the
-- pattern of step 3's thermal advance). A long catch-up skips whole years: a
-- year that comes back to where it started repeats, and one that never
-- touches full or empty adds the same every year until it would.
--
-- ── S5: THE NETWORK (base_power.lua; docs/base-building.md §16) ─────────────
-- A grid is also a network: each structure a bus (a tower's 150 m share one),
-- its live cables the edges (a breaker open or tripped at an end, or a burn,
-- takes a cable out, and may split the grid). base_power solves the flow of
-- every slot of the year once, on a rebuild: the losses (`lossP`) are one
-- more load in `advance`, and a slot that trips a breaker or burns a cable
-- (`trip`) stops the step at its start: `advance_all` opens what tripped,
-- rebuilds the grids (each keeps its own clock while it catches up) and goes
-- on. Without base_power in the scene the grid is lossless, as before.
--
-- ── SAVE ────────────────────────────────────────────────────────────────────
--
--   grid.a0   the agency clock the slots are anchored on
--   grid.a    the agency clock the grids were last advanced to
--   grid.e    { ["<sid>:<uid>"] = EC } every Battery Bank's charge
--
-- COST: nothing per frame but two version compares. The grids advance every
-- `every` seconds (a few multiplies a slot crossed: at 1000x warp about a
-- hundred) and are rebuilt when a structure, a base or a cable changes.
--
-- Probes: grids(), gridOf(bid), gridOfStruct(sid), status(gid), advanceNow(),
-- rebuildNow(), slotInfo(), stored(gid), PROF.

defaults = {
  --@range 0.5 10 --@units s
  every = 2.0,
}

RADIUS = 150.0
SLOTS = 96
CATCH_MAX = 30 * 86400
EPS = 1e-9

version = 0
PROF = { rebuild_ms = 0, advance_ms = 0, n_rebuild = 0, n_advance = 0, slots = 0 }

-- ── pure: the union of structures ───────────────────────────────────────────

local function uf_new() return { p = {} } end
local function uf_find(U, a)
  local p = U.p
  if p[a] == nil then p[a] = a return a end
  local r = a
  while p[r] ~= r do r = p[r] end
  while p[a] ~= r do local n = p[a]; p[a] = r; a = n end
  return r
end
local function uf_join(U, a, b)
  local ra, rb = uf_find(U, a), uf_find(U, b)
  if ra ~= rb then
    -- (the smaller key keeps the root: the grid's id is stable as members join)
    if tostring(ra) < tostring(rb) then U.p[rb] = ra else U.p[ra] = rb end
  end
end

-- Straight-line metres between two body-relative points (150 m on a 600 m
-- world: the chord is within 1 % of the arc).
local function dist(ax, ay, az, bx, by, bz) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) end

-- ── pure: the wiring rule (W2, playtest 11-12b; work/baseloop/DESIGN.md) ────
-- "Everything on a grid must be connected to a power source with power
-- cables. Nothing should be part of the grid automatically." A part has power
-- only where a cable path joins it to something that makes or stores it.
--
--   EQUIPMENT has its own terminal and wants its own cable: every source
--   (solar, rtg, a plant's generator), every Battery Bank, every tower and
--   mast, every Transformer, and every machine drawing FIXTURE_KW or more.
--   A BUILDING's own circuit is the rest of its structure: the walls, floors
--   and roofs, and the small fixtures in them (lights, screens, doors,
--   sensors; a structural piece's own pump, the Airlock Wall's). It is dead
--   until a cable lands on any of its pieces.
--
-- A NODE is what a cable's end joins: "s<sid>" a structure's circuit,
-- "s<sid>:<uid>" a piece of equipment. A record marked `aw` ("as wired
-- before": every structure of a save from before the rule, a scenario's
-- station) keeps the old rule: all its parts are one node, and within 150 m
-- of a tower it joins the base.
FIXTURE_KW = 0.5
WIRE_VERSION = 2
WIRED = true      -- false: every record as wired before (the old rule; tests of it)
local STRUCTURAL = { wall = true, floor = true, slab = true, post = true, hab = true, block = true }
function isEquipment(d)
  if not d then return false end
  if d.tower then return true end
  local pw = d.power
  if not pw then return false end
  local k = pw.kind
  if k == "rtg" or k == "solar" or k == "store" or k == "plant" or k == "xfmr" then return true end
  if (k == "load" or k == "aux") and not STRUCTURAL[d.snap or ""] then
    return (pw.use or FIXTURE_KW) >= FIXTURE_KW
  end
  return false
end
function nodeKey(r, p, d)
  if r.aw or not WIRED or not isEquipment(d) then return "s" .. tostring(r.id) end
  return "s" .. tostring(r.id) .. ":" .. tostring(p.uid)
end
local function pkey(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end

-- THE GRIDS. `structs` = structures.list(); `bases` = bases.list() (standing);
-- `cables` = { { a = { sid, uid }, z = { sid, uid } } }; `defs(id)` the parts;
-- `pose(rec, p, seat)` structures.partPose. → grids (list), bySid (sid → the
-- grid of that structure's own circuit), byNode (node → grid), nodeOf
-- ("sid:uid" → node)
-- grid = { id, sids = { sid … }, nodes = { node … }, bases = { bid … },
--          parts = { { rec, p, def, node } … }, busOf = { [node] = bus },
--          baseNode = { [bid] = node } }
function buildGrids(structs, bases, cables, defs, pose, radius)
  radius = radius or RADIUS
  local U = uf_new()
  -- (S5) the BUSES: the same union without the cables, so each node knows
  -- the lossless bus it sits on (an as-wired-before tower's 150 m share one)
  local Bu = uf_new()
  local byId, nodeOf, nodes = {}, {}, {}
  local function note(k) if U.p[k] == nil then nodes[#nodes + 1] = k end uf_find(U, k); uf_find(Bu, k) end
  for _, r in ipairs(structs or {}) do
    byId[r.id] = r
    note("s" .. tostring(r.id))
    for _, p in ipairs(r.bp or {}) do
      local k = nodeKey(r, p, defs(p.id))
      nodeOf[pkey(r.id, p.uid)] = k
      note(k)
    end
  end
  local function node_at(e) return e and (nodeOf[pkey(e.sid, e.uid)] or (byId[e.sid] and ("s" .. tostring(e.sid)))) or nil end
  local baseNode = {}
  for _, b in ipairs(bases or {}) do
    local bk = "b" .. string.format("%06d", b.id)
    uf_find(U, bk)
    local tr = b.sid and byId[b.sid]
    if tr then
      -- the tower's own terminal (its structure's circuit when as wired before)
      local tn = (b.uid ~= nil and nodeOf[pkey(b.sid, b.uid)]) or nil
      if not tn then
        tn = "s" .. tostring(b.sid)
        if not (tr.aw or not WIRED) then
          for _, p in ipairs(tr.bp or {}) do local d = defs(p.id); if d and d.tower then tn = nodeOf[pkey(tr.id, p.uid)] or tn break end end
        end
      end
      baseNode[b.id] = tn
      uf_join(U, bk, tn); uf_join(Bu, bk, tn)
    end
    -- the radius, for structures as wired before only: one with any part
    -- within it of a tower joins the base
    for _, r in ipairs(structs or {}) do
      if (r.aw or not WIRED) and r.b == b.b then
        -- (S5) a structure of network gear alone (a pole, a junction) is on
        -- the line its cables make, never on the tower's low-voltage ring
        local gearOnly = #(r.bp or {}) > 0
        for _, p in ipairs(r.bp or {}) do local d = defs(p.id); if not (d and d.netgear and not d.power) then gearOnly = false break end end
        if not gearOnly then
          for _, p in ipairs(r.bp or {}) do
            local x, y, z = pose(r, p, 0)
            if dist(x, y, z, b.x, b.y, b.z) <= radius then uf_join(U, bk, "s" .. tostring(r.id)); uf_join(Bu, bk, "s" .. tostring(r.id)) break end
          end
        end
      end
    end
  end
  -- the cables
  for _, c in ipairs(cables or {}) do
    local a, z = node_at(c.a), node_at(c.z)
    if a and z then uf_join(U, a, z) end
  end
  local roots, out, bySid, byNode = {}, {}, {}, {}
  local function grid_of(root)
    local g = roots[root]
    if not g then
      g = { id = root, sids = {}, nodes = {}, bases = {}, parts = {}, cables = 0, bus = {}, busOf = {}, cableList = {},
            baseNode = baseNode, nodeOf = nodeOf, hasSid = {} }
      roots[root] = g
      out[#out + 1] = g
    end
    return g
  end
  for _, b in ipairs(bases or {}) do
    local g = grid_of(uf_find(U, "b" .. string.format("%06d", b.id)))
    g.bases[#g.bases + 1] = b.id
  end
  for _, k in ipairs(nodes) do
    local g = grid_of(uf_find(U, k))
    g.nodes[#g.nodes + 1] = k
    g.busOf[k] = uf_find(Bu, k)
    byNode[k] = g
  end
  for _, r in ipairs(structs or {}) do
    local own = "s" .. tostring(r.id)
    local g0 = byNode[own]
    g0.bus[r.id] = g0.busOf[own]
    bySid[r.id] = g0
    if not g0.hasSid[r.id] then g0.hasSid[r.id] = true; g0.sids[#g0.sids + 1] = r.id end
    for _, p in ipairs(r.bp or {}) do
      local d = defs(p.id)
      if d then
        local k = nodeOf[pkey(r.id, p.uid)]
        local g = byNode[k]
        g.parts[#g.parts + 1] = { rec = r, p = p, def = d, node = k }
        if not g.hasSid[r.id] then g.hasSid[r.id] = true; g.sids[#g.sids + 1] = r.id end
      end
    end
  end
  for _, c in ipairs(cables or {}) do
    local a, z = node_at(c.a), node_at(c.z)
    local g = a and byNode[a]
    if g and z and byNode[z] == g then g.cables = g.cables + 1; g.cableList[#g.cableList + 1] = c end
  end
  -- (a grid with nothing on it that makes, stores or draws power is dropped)
  local keep, used = {}, {}
  for _, g in ipairs(out) do
    local live = #g.bases > 0
    for _, e in ipairs(g.parts) do if e.def.power or e.def.tower then live = true end end
    if live then
      table.sort(g.bases)
      -- the id: its first base's, else its first structure's own circuit,
      -- else its first piece of equipment
      local m, mk = nil, nil
      for _, k in ipairs(g.nodes) do
        local sid = k:match("^s([^:]+)$")
        if sid then
          local n = tonumber(sid) or sid
          if m == nil or (type(n) == type(m) and n < m) or (type(n) ~= type(m) and tostring(n) < tostring(m)) then m = n end
        elseif not mk or k < mk then mk = k end
      end
      g.id = (#g.bases > 0) and ("b" .. tostring(g.bases[1])) or (m ~= nil and ("s" .. tostring(m))) or mk
      used[g.id] = true
      keep[#keep + 1] = g
    else
      for _, k in ipairs(g.nodes) do byNode[k] = nil end
      for _, sid in ipairs(g.sids) do if bySid[sid] == g then bySid[sid] = nil end end
    end
  end
  return keep, bySid, byNode, nodeOf
end

-- ── pure: what a grid is made of ────────────────────────────────────────────
-- → M = { base (EC/s always), arrays = { { key, gen, x,y,z, ax,ay,az } },
--         loads = { { kind, bid?, need, label } }, need, stores = { { key, cap, eff, fill } },
--         C, eff, sources = n, body }
-- `towerNeed` = the tower's draw (parts_base tower.draw).
function gridModel(g, pose, towerNeed, opts)
  opts = opts or {}
  local M = { base = 0, arrays = {}, loads = {}, need = 0, stores = {}, C = 0, eff = 1, sources = 0, rtg = 0, body = nil,
              rtgs = {}, breakers = {}, xfmrs = {}, mainsOff = {}, plant = 0, plants = {} }
  local effw, capw = 0, 0
  -- (S5) a breaker with no cable at all is its structure's MAIN: open or
  -- tripped, that structure's own loads are off the grid
  for _, e in ipairs(g.parts) do
    local pw = e.def.power
    if pw and pw.kind == "breaker" then
      local key = tostring(e.rec.id) .. ":" .. tostring(e.p.uid)
      local main = not (opts.cablesAt and (opts.cablesAt[key] or 0) > 0)
      local st = opts.state and opts.state(e.rec.id, e.p.uid) or "closed"
      -- (scn_dust) its trip setting: the long-time pickup dial, Ir = 0.3..1 of
      -- the frame's amps (`st.ir`, set by a hand or a scenario; 1 by default)
      local stt = e.rec.st and e.rec.st[tostring(e.p.uid)]
      local ir = type(stt) == "table" and tonumber(stt.ir) or nil
      ir = ir and math.max(IR_MIN, math.min(1, ir)) or 1
      M.breakers[#M.breakers + 1] = { key = key, sid = e.rec.id, uid = e.p.uid, node = e.node, pw = pw, main = main, state = st, kW = breakerKW_(pw) * ir, ir = ir }
      if main and st ~= "closed" then M.mainsOff[e.rec.id] = true end
    elseif pw and pw.kind == "xfmr" then
      M.xfmrs[#M.xfmrs + 1] = { key = tostring(e.rec.id) .. ":" .. tostring(e.p.uid), sid = e.rec.id, uid = e.p.uid, pw = pw }
    end
  end
  -- (W2) a main cuts its structure's own circuit: a piece of equipment has
  -- its own terminal and is past it
  local function mainOff(sid, node) return M.mainsOff[sid] and (node == nil or node == "s" .. tostring(sid)) end
  for _, bid in ipairs(g.bases) do
    local bsid = opts.baseSid and opts.baseSid(bid) or nil
    local bnode = g.baseNode and g.baseNode[bid] or nil
    if not (bsid and mainOff(bsid, bnode)) then
      -- (W1) each base's own tower draw: a Camp Mast's is 0.5 (opts.towerNeedOf), the Tower's towerNeed
      local tn = (opts.towerNeedOf and opts.towerNeedOf(bid)) or towerNeed or 2.0
      M.loads[#M.loads + 1] = { kind = "tower", bid = bid, need = tn, label = "tower", sid = bsid, node = bnode }
      M.need = M.need + tn
    end
  end
  for _, e in ipairs(g.parts) do
    local pw, r, p = e.def.power, e.rec, e.p
    M.body = M.body or r.b
    local key = tostring(r.id) .. ":" .. tostring(p.uid)
    if pw and pw.kind == "rtg" then
      M.base = M.base + (pw.gen or 0)
      M.rtg = M.rtg + (pw.gen or 0)
      M.sources = M.sources + 1
      M.rtgs[#M.rtgs + 1] = { sid = r.id, gen = pw.gen or 0, node = e.node }
    elseif pw and pw.kind == "solar" then
      local gx, gy, gz, U, F = pose(r, p, pw.lift or 1.0)
      -- the cells track about the part's +X (= up × front)
      local ax, ay, az = U.y * F.z - U.z * F.y, U.z * F.x - U.x * F.z, U.x * F.y - U.y * F.x
      M.arrays[#M.arrays + 1] = { key = string.format("%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f", key, gx, gy, gz, ax, ay, az),
                                  gen = pw.gen or 0, x = gx, y = gy, z = gz, ax = ax, ay = ay, az = az, b = r.b, sid = r.id, node = e.node,
                                  pk = key, uid = p.uid }   -- (G4: pk = "sid:uid", its dust and sky)
      M.sources = M.sources + 1
    elseif pw and pw.kind == "store" then
      -- (J6: `effk` on the part = the installing Engineer's bonus, fixed at placement)
      local eff = pw.eff or 1
      if tonumber(p.effk) then eff = math.max(eff, math.min(0.99, eff + tonumber(p.effk))) end
      -- (X8) a bank may arrive with its own charge (`fill` on the part: an
      -- abandoned base's battery is flat)
      local fill = tonumber(p.fill) or pw.fill or 0
      M.stores[#M.stores + 1] = { key = key, cap = pw.cap or 0, eff = eff, fill = fill, sid = r.id, node = e.node }
      M.C = M.C + (pw.cap or 0)
      effw, capw = effw + eff * (pw.cap or 0), capw + (pw.cap or 0)
    elseif pw and pw.kind == "load" and not mainOff(r.id, e.node)
           and not (r.st and type(r.st[tostring(p.uid)]) == "table" and r.st[tostring(p.uid)].off) then
      -- (S8: a life-support machine switched off by its run terminal draws
      -- nothing; and so does a light switched off, or any load whose switch
      -- is off: `st.off` is every piece's switch)
      M.loads[#M.loads + 1] = { kind = "load", need = pw.use or 0, label = e.def.label, sid = r.id, uid = p.uid, node = e.node }
      M.need = M.need + (pw.use or 0)
    elseif pw and pw.kind == "plant" then
      -- (S6) a turbine-generator: what its plant makes now (reactor_plant
      -- publishes it; held over each step, the grid rebuilt when it moves)
      local kw = opts.plantKW and opts.plantKW(r.id, p.uid) or 0
      M.plants[#M.plants + 1] = { sid = r.id, uid = p.uid, kw = kw, node = e.node }
      if kw > 0 then
        M.base = M.base + kw
        M.plant = M.plant + kw
        M.sources = M.sources + 1
        M.rtgs[#M.rtgs + 1] = { sid = r.id, gen = kw, node = e.node }
      end
    elseif pw and pw.kind == "aux" and not mainOff(r.id, e.node) then
      -- (S6) a plant's pump, heater or fan, while it runs
      local kw = opts.auxKW and opts.auxKW(r.id, p.uid) or 0
      if kw > 0 then
        M.loads[#M.loads + 1] = { kind = "aux", need = kw, label = e.def.label, sid = r.id, uid = p.uid, node = e.node }
        M.need = M.need + kw
      end
    end
  end
  M.eff = capw > 0 and effw / capw or 1
  return M
end
-- (a breaker's rating in kW at 400 V: base_power.breakerKW's figure)
function breakerKW_(pw) return (pw and pw.amps or 63) * 400 / 1000 end
IR_MIN = 0.3            -- (scn_dust) the lowest a breaker's trip dial goes

-- (S5) THE NETWORK SPEC of a grid for base_power.network: its buses, where
-- each source, load and store sits, its live cables (`cables` = the grid's,
-- every one on a closed path) with their guards and transformers.
-- prof(arr) = an array's year of slots (or nil). → spec
function netSpec(g, M, prof, defsAt)
  local idx, buses = {}, {}
  -- (W2) a bus is a node's (a structure's circuit, a piece of equipment);
  -- `at(x)` = the bus of a model entry (its node, else its structure's circuit)
  local function busOf(node)
    local k = (g.busOf and g.busOf[node]) or node
    local i = idx[k]
    if not i then buses[#buses + 1] = k; i = #buses; idx[k] = i end
    return i
  end
  local function own(sid) return "s" .. tostring(sid) end
  local function at(x) return busOf(x.node or (g.bus and g.bus[x.sid]) or own(x.sid)) end
  if g.nodes then for _, k in ipairs(g.nodes) do busOf(k) end
  else for _, sid in ipairs(g.sids) do busOf(g.bus[sid] or own(sid)) end end
  local spec = { buses = buses, gen = {}, arrays = {}, loads = {}, stores = {}, edges = {}, mains = {}, xfmrs = {} }
  for i = 1, #buses do spec.gen[i] = 0 end
  for _, r in ipairs(M.rtgs or {}) do local b = at(r); spec.gen[b] = spec.gen[b] + r.gen end
  for _, a in ipairs(M.arrays) do spec.arrays[#spec.arrays + 1] = { bus = at(a), prof = prof and prof(a) or nil, kW = 0 } end
  local bySid = {}
  for _, l in ipairs(M.loads) do
    local b = l.sid and at(l) or 1
    spec.loads[#spec.loads + 1] = { bus = b, kW = l.need, sid = l.sid }
    -- (a main guards its structure's own circuit)
    if l.sid and (l.node == nil or l.node == own(l.sid)) then bySid[l.sid] = (bySid[l.sid] or 0) + l.need end
  end
  for _, st in ipairs(M.stores) do spec.stores[#spec.stores + 1] = { bus = at(st), cap = st.cap } end
  local brk, xf = {}, {}
  for _, b in ipairs(M.breakers) do
    brk[b.key] = b
    if b.main and b.state == "closed" then spec.mains[#spec.mains + 1] = { key = b.key, kW = b.kW, sid = b.sid, load = bySid[b.sid] or 0 } end
  end
  for _, x in ipairs(M.xfmrs) do xf[x.key] = x; spec.xfmrs[#spec.xfmrs + 1] = { key = x.key, pw = x.pw } end
  local function endBus(e)
    local k = g.nodeOf and g.nodeOf[tostring(e.sid) .. ":" .. tostring(e.uid)]
    return busOf(k or (g.bus and g.bus[e.sid]) or own(e.sid))
  end
  for _, c in ipairs(g.cableList or {}) do
    local ka, kz = tostring(c.a.sid) .. ":" .. tostring(c.a.uid), tostring(c.z.sid) .. ":" .. tostring(c.z.uid)
    local e = { id = c.id, a = endBus(c.a), z = endBus(c.z), ty = c.ty or "lv16", len = c.len or 1, guard = {}, xf = {} }
    for _, k in ipairs({ ka, kz }) do
      if brk[k] then e.guard[#e.guard + 1] = { key = k, kW = brk[k].kW } end
      if xf[k] then e.xf[#e.xf + 1] = { key = k, pw = xf[k].pw } end
    end
    spec.edges[#spec.edges + 1] = e
  end
  return spec
end

-- ── pure: the year's light ──────────────────────────────────────────────────
-- The period of `body` round its sun (two-body, from its state now relative
-- to the sun): → seconds | nil (no sun, unbound).
function yearOf(body, sun)
  if not (body and sun) or body == sun then return nil end
  local rx, ry, rz = body.x - sun.x, body.y - sun.y, body.z - sun.z
  local vx, vy, vz = (body.vx or 0) - (sun.vx or 0), (body.vy or 0) - (sun.vy or 0), (body.vz or 0) - (sun.vz or 0)
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  local mu = sun.mu or 0
  if r < 1e-6 or mu <= 0 then return nil end
  local inv_a = 2 / r - (vx * vx + vy * vy + vz * vz) / mu
  if inv_a <= 1e-15 then return nil end
  local a = 1 / inv_a
  return 2 * math.pi * math.sqrt(a * a * a / mu)
end

-- An array's output in each slot of the year: { [1..N] EC/s }.
-- ctx = { E (electronics), bodies (one read, now), body (the world's record
-- in it), sun, ref (the home-orbit flux), L (slot length), N, lead (game
-- seconds from now to the start of slot 0, in [0, Y)) }.
-- Slot j is sampled at its middle: lead + (j + 0.5)·L seconds from now.
function slotLight(arr, ctx)
  local E, b, sun, N, L = ctx.E, ctx.body, ctx.sun, ctx.N, ctx.L
  local out = {}
  local hx, hy, hz = b.x - sun.x, b.y - sun.y, b.z - sun.z
  local hvx, hvy, hvz = (b.vx or 0) - (sun.vx or 0), (b.vy or 0) - (sun.vy or 0), (b.vz or 0) - (sun.vz or 0)
  local Y = N * L
  for j = 0, N - 1 do
    local t = (ctx.lead + (j + 0.5) * L) % Y
    local px, py, pz = E.kepler(hx, hy, hz, hvx, hvy, hvz, sun.mu or 0, t)
    local sx, sy, sz = sun.x + (sun.vx or 0) * t, sun.y + (sun.vy or 0) * t, sun.z + (sun.vz or 0) * t
    local wx, wy, wz = sx + px, sy + py, sz + pz
    -- (the two bodies that matter: the sun, and the world the array stands on)
    local bl = { { name = sun.name, x = sx, y = sy, z = sz, radius = sun.radius, mu = sun.mu, star = sun.star },
                 { name = b.name, x = wx, y = wy, z = wz, radius = b.radius, mu = b.mu } }
    local o = E.solarOutput(arr.gen, wx + arr.x, wy + arr.y, wz + arr.z, arr.ax, arr.ay, arr.az, bl, ctx.ref)
    out[j + 1] = o or 0
  end
  return out
end

-- ── pure: the store over time (exact) ───────────────────────────────────────
-- M (gridModel plus): prof = { [1..N] solar EC/s } | nil, N, L, A0; (S5)
-- lossP = { [1..N] kW lost in the cables and transformers } | nil (a load on
-- top of `need`), trip = { [1..N] events } | nil (the slots that trip a
-- breaker or burn a cable).
-- st = { e }. Steps st from agency time a0 to a1. → st, rep
-- rep = { short (s with loads shed), slots (slots crossed), years (skipped),
--         trip (the events, when a slot that trips was reached), stopAt (the
--         agency time it stopped there: the caller opens what tripped, rebuilds
--         the grid and goes on from there) }
local function supply_in(M, k)
  local s = M.base
  if M.prof then s = s + M.prof[(k % M.N) + 1] end
  return s
end
local function need_in(M, k)
  if M.lossP then return M.need + (M.lossP[(k % M.N) + 1] or 0) end
  return M.need
end
function needAt(M, k) return need_in(M, k) end
local function seg(st, sup, need, M, d, rep)
  local P = sup - need
  if P >= 0 then
    if M.C > 0 then
      local e = st.e + P * M.eff * d
      if e > M.C then rep.clamp = true; e = M.C end
      st.e = e
    end
  elseif st.e <= 0 then
    st.e = 0
    rep.short = rep.short + d
    rep.clamp = true
  else
    local tE = st.e / -P
    if tE >= d then
      st.e = st.e + P * d
    else
      st.e = 0
      rep.short = rep.short + (d - tE)
      rep.clamp = true
    end
  end
end
local function slot_of(M, a) return math.floor((a - M.A0) / M.L + 1e-12) end

function advance(st, M, a0, a1, rep)
  rep = rep or { short = 0, slots = 0, years = 0 }
  rep.short, rep.slots, rep.years = rep.short or 0, rep.slots or 0, rep.years or 0
  if not (a1 and a0) or a1 < a0 then return st, rep end
  st.e = math.max(0, math.min(M.C, st.e or 0))
  local L, N = M.L or 1e9, M.N or 1
  local Y = L * N
  local a = a0
  local guard = 0
  -- (S5) a slot that trips stops the step at its start (or at a0 when the
  -- grid is already in it): the same moment for one long step or many short
  if M.trip then
    local ev = M.trip[(slot_of(M, a) % N) + 1]
    if ev then rep.trip, rep.stopAt = ev, a return st, rep end
  end
  while a < a1 - EPS do
    guard = guard + 1
    if guard > 5e6 then error(string.format("advance stuck at %.17g (to %.17g, L %.17g, A0 %.17g)", a, a1, L, M.A0)) end
    local k = slot_of(M, a)
    local edge = M.A0 + (k + 1) * L
    -- (an edge that rounds onto `a` itself: the next one)
    if edge <= a then k = k + 1; edge = M.A0 + (k + 1) * L end
    if M.trip and M.trip[(k % N) + 1] then rep.trip, rep.stopAt = M.trip[(k % N) + 1], a return st, rep end
    -- whole years at once when there are many left (from a slot edge; never
    -- across a slot that trips: that stops the step within its first year)
    if M.prof and not M.trip and a1 - a > 2 * Y and math.abs(a - (M.A0 + k * L)) < 1e-6 then
      local e0, s0 = st.e, rep.short
      local lo, hi = 0, 0
      rep.clamp = false
      for i = 0, N - 1 do
        seg(st, supply_in(M, k + i), need_in(M, k + i), M, L, rep)
        local de = st.e - e0
        if de < lo then lo = de end
        if de > hi then hi = de end
      end
      rep.slots = rep.slots + N
      a = M.A0 + (k + N) * L
      local left = math.floor((a1 - a) / Y) - 1
      if left > 0 then
        local dE, dS = st.e - e0, rep.short - s0
        if math.abs(dE) < 1e-9 then
          -- the year came back to where it began: every year is this one
          rep.short = rep.short + dS * left
          a = a + left * Y
          rep.years = rep.years + left
        elseif not rep.clamp then
          -- a straight year: the same gain each year until it would clamp
          local K = left
          if dE > 0 then K = math.min(K, math.floor((M.C - hi - st.e) / dE)) end
          if dE < 0 then K = math.min(K, math.floor((st.e + lo) / -dE)) end
          if K > 0 then
            st.e = st.e + K * dE
            a = a + K * Y
            rep.years = rep.years + K
          end
        end
      end

    else
      local b = math.min(edge, a1)
      seg(st, supply_in(M, k), need_in(M, k), M, b - a, rep)
      rep.slots = rep.slots + 1
      a = b
    end
  end
  return st, rep
end

-- The grid as it is at agency time `a` with store st: → supply, need, served
-- (load index → true), powered (all served), short (some shed), loss (kW)
function statusAt(M, st, a)
  local k = (M.L and M.A0) and slot_of(M, a) or 0
  local sup = (M.L and M.A0) and supply_in(M, k) or M.base
  local loss = (M.L and M.A0) and (need_in(M, k) - M.need) or 0
  local served, all = {}, true
  if (st.e or 0) > EPS or sup + 1e-9 >= M.need + loss then
    for i in ipairs(M.loads) do served[i] = true end
  else
    local left = sup - loss
    for i, l in ipairs(M.loads) do
      if l.need <= left + 1e-9 then served[i] = true; left = left - l.need else all = false end
    end
  end
  return sup, M.need, served, all, loss
end
function slotOf(M, a) return slot_of(M, a) end

-- ── the scene half ──────────────────────────────────────────────────────────

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end

local G = { list = {}, byId = {}, bySid = {}, byNode = {}, nodeOf = {}, byBase = {}, models = {}, st = {}, status = {}, flow = {}, short = {}, edgeOf = {}, dead = {} }
trips = 0                 -- probes: breakers tripped and cables burnt since the start
local vers = { st = nil, bs = nil, cb = nil }
local dirty, last_rebuild, last_adv = true, -10, -10
local slot = nil          -- { A0, L, N, Y, body, ref }
local light_cache = {}    -- array key → profile
local e_saved = nil       -- grid.e as read
local caught = nil        -- the last catch-up: { dt, years, short }

local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end

-- ── G4: dust on the panels, cloud and dust over them ────────────────────────
-- (PLAN scenarios2 §2 G4; electronics.lua soilFactor/skyFactor/dustStep.)
-- Every solar piece of a grid carries the dust a storm laid on it (saved:
-- grid.dust = { ["sid:uid"] = 0..1 }) and the age dust kit_paint gives every
-- exterior piece (since it was placed or last wiped: grid.wipe = { key =
-- agency time }). The weather is read where it is simulated: the structure
-- within SOIL_R of the camera on the camera's world (weather.current());
-- farther off, the dust stays as it was and the sky is clear. Each panel's
-- factor is quantised to SOIL_Q, and the grids are rebuilt only when one
-- steps (the profile and the network's flows are the light times it).
SOIL_R = 3000.0
SOIL_Q = 0.02
SOIL = { k = {}, sky = {}, t = nil, n_steps = 0 }
local soil_d, soil_w = nil, nil
local function soil_tables()
  if not soil_d then
    soil_d = (save and save.get and save.get("grid.dust")) or {}
    soil_w = (save and save.get and save.get("grid.wipe")) or {}
    if type(soil_d) ~= "table" then soil_d = {} end
    if type(soil_w) ~= "table" then soil_w = {} end
  end
  return soil_d, soil_w
end
-- the factor in use for panel pk (1 before the first tick)
function soil_k(pk) local f = SOIL.k[pk]; if f == nil then return 1 end return f end
local soiled_cache = {}
-- an array's year of slots, times its factor (cached per factor step)
function soiled(arr)
  local p = light_cache[arr.key]
  if not p then return nil end
  local f = soil_k(arr.pk)
  if f >= 1 then return p end
  local c = soiled_cache[arr.key]
  if c and c.f == f and c.src == p then return c.p end
  local q = {}
  for j = 1, #p do q[j] = p[j] * f end
  soiled_cache[arr.key] = { f = f, src = p, p = q }
  return q
end
-- (pure) a panel's factor: storm dust d, age dust a (kit_paint level), sky s
function soilOf3(E, d, a, s)
  local eff = 1 - (1 - (d or 0)) * (1 - E.AGE_DUST * (a or 0))
  return E.soilFactor(eff, s), eff
end
local function soil_eye()
  local pc = ref("planet_camera")
  if pc and pc.cam_x then return pc.cam_x, pc.cam_y, pc.cam_z end
  return nil
end
local function soil_tick(force_dt)
  local E, ST = ref("electronics"), ref("structures")
  if not (E and E.dustStep and ST and ST.get) then return false end
  local D, Wp = soil_tables()
  local an = agency_now()
  local dt = force_dt or (SOIL.t and math.max(0, math.min(an - SOIL.t, CATCH_MAX)) or 0)
  SOIL.t = an
  local wx = ref("weather")
  local o = wx and wx.current and wx.current() or nil
  local ex, ey, ez = soil_eye()
  local ob = o and o.body and space and space.body and space.body(o.body)
  local KP = ref("kit_paint")
  local changed = false
  for _, g in ipairs(G.list) do
    local M = G.models[g.id]
    for _, arr in ipairs(M and M.arrays or {}) do
      local pk = arr.pk
      local rec = ST.get(arr.sid)
      local near = false
      if o and ob and ex and rec and rec.b == o.body then
        local rx, ry, rz = ex - ob.x, ey - ob.y, ez - ob.z
        near = (rx - (rec.x or 0)) ^ 2 + (ry - (rec.y or 0)) ^ 2 + (rz - (rec.z or 0)) ^ 2 < SOIL_R * SOIL_R
      end
      local d = tonumber(D[pk]) or 0
      if near and dt > 0 then d = E.dustStep(d, o, dt) end
      D[pk] = math.floor(d * 1e4 + 0.5) / 1e4
      local s = near and E.skyFactor(o) or 1
      SOIL.sky[pk] = s
      local age = 0
      if KP and KP.dustOf and rec then
        local part = ST.getPart and ST.getPart(arr.sid, arr.uid)
        if part then
          local t0 = part.pt or (type(part.paid) == "table" and part.paid.t) or rec.t or 0
          local w = tonumber(Wp[pk])
          if w and w > t0 then t0 = w end
          local ok, lv = pcall(KP.dustOf, rec, { pt = t0 }, an)
          if ok and type(lv) == "number" then age = lv end
        end
      end
      local f = soilOf3(E, D[pk], age, s)
      local q = math.floor(f / SOIL_Q + 0.5) * SOIL_Q
      if q > 1 then q = 1 end
      if SOIL.k[pk] ~= q then SOIL.k[pk] = q; changed = true end
    end
  end
  if save and save.set then save.set("grid.dust", D) end
  if changed then SOIL.n_steps = SOIL.n_steps + 1; dirty = true end
  return changed
end
-- (probes, the menu, the terminal) a panel's dust, age dust, sky and factor
function soilInfo(sid, uid)
  local D = soil_tables()
  local pk = tostring(sid) .. ":" .. tostring(uid)
  return { dust = tonumber(D[pk]) or 0, sky = SOIL.sky[pk] or 1, k = soil_k(pk) }
end
-- the mean factor of a structure's panels (1 with none)
function soilOfStruct(sid)
  local n, s = 0, 0
  local pre = tostring(sid) .. ":"
  for pk, f in pairs(SOIL.k) do if pk:sub(1, #pre) == pre then n, s = n + 1, s + f end end
  return n > 0 and s / n or 1
end
-- (scenarios, probes) lay dust on every panel of a structure (0..1)
function setDust(sid, d)
  local D = soil_tables()
  local pre = tostring(sid) .. ":"
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  local pb = ref("parts_base")
  for _, p in ipairs(rec and rec.bp or {}) do
    local def = pb and pb.partInfo(p.id)
    if def and def.power and def.power.kind == "solar" then D[pre .. tostring(p.uid)] = math.max(0, math.min(1, d or 0)) end
  end
  soil_tick(0)
  return true
end
-- An Engineer's cloth: the panel's dust off, its age dust too.
function wipe(sid, uid)
  local D, Wp = soil_tables()
  local pk = tostring(sid) .. ":" .. tostring(uid)
  D[pk] = 0
  Wp[pk] = agency_now()
  if save and save.set then save.set("grid.wipe", Wp) end
  soil_tick(0)
  return true
end
local function engineer_why()
  local c = ref("crew")
  if not (c and c.hasRole) then return nil end
  local id = c.activeId and c.activeId()
  if id == nil then return "Engineers only" end
  local ok, yes = pcall(c.hasRole, id, "engineer")
  if ok and yes == true then return nil end
  return "Engineers only"
end
WIPE_S = 10.0
-- the menu on a solar piece: what reaches its cells, and the wipe
local function soil_provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local def = defs(part.id)
  if not (def and def.power and def.power.kind == "solar") then return {} end
  local sid, uid = rec.id, part.uid
  return {
    { id = "sg_cells", type = "info", label = "Cells", group = "Solar", value = function()
        local s = soilInfo(sid, uid)
        local txt = string.format("%d %% of their output · dust %d %% · sky %d %%", math.floor(s.k * 100 + 0.5),
          math.floor(s.dust * 100 + 0.5), math.floor(s.sky * 100 + 0.5))
        return txt
      end },
    { id = "sg_wipe", type = "action", label = "Wipe the panel", group = "Solar", hint = string.format("%.0f s", WIPE_S),
      enabled = function() return engineer_why() == nil end,
      why = function() return engineer_why() end,
      job = { secs = WIPE_S, label = "Wiping the panel",
        check = function() if not (ST.getPart and ST.getPart(sid, uid)) then return false, "it's gone" end return true end,
        tick = function() end,
        done = function()
          wipe(sid, uid)
          if ctx and ctx.toast then ctx.toast("panel wiped") end
          return true
        end } },
  }, def.label
end
soilProviderFn = soil_provider
local soil_reg = false

-- The slots of the year: anchored once on the agency clock (grid.a0, saved).
local function slots_for(bodies, bname)
  local E = ref("electronics")
  if not (E and E.sunOf and E.kepler) then return nil end
  local b = nil
  for _, x in ipairs(bodies or {}) do if x.name == bname then b = x end end
  if not b then return nil end
  local sun = E.sunOf(b.x, b.y, b.z, bodies, nil)
  if not sun or sun.name == b.name then return nil end
  local Y = yearOf(b, sun)
  if not Y or Y ~= Y or Y <= 0 then return nil end
  local a0 = tonumber(save.get("grid.a0"))
  local an = agency_now()
  if not a0 then a0 = an; save.set("grid.a0", a0) end
  local L = Y / SLOTS
  -- game seconds from now to the start of slot 0 of the current year
  local lead = (a0 - an) % Y
  local ref_flux = sun.mu / math.max((sun.x - b.x) ^ 2 + (sun.y - b.y) ^ 2 + (sun.z - b.z) ^ 2, 1)
  -- (copies: the profile is built against THIS read, whenever it is rebuilt)
  local function snap(x)
    return { name = x.name, x = x.x, y = x.y, z = x.z, vx = x.vx or 0, vy = x.vy or 0, vz = x.vz or 0,
             radius = x.radius, mu = x.mu, star = x.star }
  end
  return { A0 = a0, L = L, N = SLOTS, Y = Y, body = snap(b), sun = snap(sun), ref = ref_flux, lead = lead, E = E, at = an }
end

local function profile_of(M, bodies)
  if #M.arrays == 0 then return nil end
  local sl = slot
  if not sl then return nil end
  local prof = {}
  for j = 1, sl.N do prof[j] = 0 end
  for _, arr in ipairs(M.arrays) do
    local p = light_cache[arr.key]
    if not p and arr.b == sl.body.name then
      local ok, res = pcall(slotLight, arr, sl)
      if ok then p = res; light_cache[arr.key] = p end
    end
    if p then
      local f = soil_k(arr.pk)
      for j = 1, sl.N do prof[j] = prof[j] + p[j] * f end
    end
  end
  return prof
end

local function read_e()
  if e_saved then return e_saved end
  e_saved = (save and save.get and save.get("grid.e")) or {}
  if type(e_saved) ~= "table" then e_saved = {} end
  return e_saved
end

-- Charge in each store of grid g now (from its pool).
local function spread(g, M, e)
  local t = read_e()
  for _, s in ipairs(M.stores) do
    t[s.key] = (M.C > 0) and (e * s.cap / M.C) or 0
  end
end

local function cables_list()
  local cb = ref("base_cable")
  return (cb and cb.list) and cb.list() or {}
end

local function towers_need()
  local d = defs("tower")
  return (d and d.tower and d.tower.draw) or 2.0
end

local function write_save(a)
  if not (save and save.set) then return end
  local t = read_e()
  -- (only the stores that still exist are kept)
  local keep = {}
  for _, g in ipairs(G.list) do
    for _, s in ipairs(G.models[g.id].stores) do keep[s.key] = t[s.key] or 0 end
  end
  e_saved = keep
  save.set("grid.e", keep)
  save.set("grid.a", a)
end

-- (S5) which cables carry power: not burnt through, and no open or tripped
-- breaker at either end. → live (list), dead = { [id] = why }
local function breaker_state(sid, uid)
  local BP = ref("base_power")
  if BP and BP.breakerState then return BP.breakerState(sid, uid) end
  return "closed"
end
local function split_cables(all)
  local live, dead, at = {}, {}, {}
  local ST = ref("structures")
  for _, c in ipairs(all) do
    local ka, kz = tostring(c.a.sid) .. ":" .. tostring(c.a.uid), tostring(c.z.sid) .. ":" .. tostring(c.z.uid)
    at[ka] = (at[ka] or 0) + 1
    at[kz] = (at[kz] or 0) + 1
    local why = nil
    if c.burnt then why = "burnt through" end
    if not why and ST then
      for _, e in ipairs({ c.a, c.z }) do
        local p = ST.getPart(e.sid, e.uid)
        local d = p and defs(p.id)
        if d and d.power and d.power.kind == "breaker" then
          local s = breaker_state(e.sid, e.uid)
          if s ~= "closed" then why = (s == "tripped") and "breaker tripped" or "breaker open" end
        end
      end
    end
    if why then dead[c.id] = why else live[#live + 1] = c end
  end
  return live, dead, at
end

-- Every grid to agency time `a` (exact; capped for a catch-up). A breaker
-- that trips (or a cable that burns) on the way stops its grid there: what
-- tripped is opened, the grids are rebuilt (that grid may split in two, each
-- half keeping its banks' charge) and the halves go on from that moment.
-- → max dt
local topology
local function apply_events(events)
  local BP, CB = ref("base_power"), ref("base_cable")
  for _, x in ipairs(events) do
    for _, ev in ipairs(x.ev) do
      if ev.kind == "trip" then
        local sid, uid = ev.key:match("^(.-):(.+)$")
        sid, uid = tonumber(sid) or sid, tonumber(uid) or uid
        if BP and BP.setBreaker then BP.setBreaker(sid, uid, false, "trip") end
      elseif ev.kind == "burn" and CB and CB.setBurnt then
        CB.setBurnt(ev.id, x.t)
      end
      ev.t = x.t
      if BP then
        BP.lastTrips = BP.lastTrips or {}
        BP.lastTrips[#BP.lastTrips + 1] = ev
        while #BP.lastTrips > 20 do table.remove(BP.lastTrips, 1) end
      end
      trips = trips + 1
      local msg = (ev.kind == "burn") and string.format("Cable %s burnt through: it carried %.1f kW, rated %.1f kW", tostring(ev.id), ev.kW, ev.rating)
        or string.format("A breaker tripped%s: %.1f kW through a %.1f kW rating", ev.main and " (a structure's main)" or "", ev.kW, ev.rating)
      if caption and now() > 1 then pcall(caption, msg) end
      if log then log("base_grid: " .. msg) end
    end
  end
end
local function advance_all(a)
  local a_last = tonumber(save.get("grid.a"))
  if not a_last or a_last > a then a_last = a end
  local dt = math.min(a - a_last, CATCH_MAX)
  local a0 = a - dt
  local w0 = wall()
  local nslots = 0
  local clk = {}            -- sid → the agency time its grid has reached
  for _ = 1, 24 do
    local events = {}
    for _, g in ipairs(G.list) do
      local M, st = G.models[g.id], G.st[g.id]
      if M and st then
        local t0 = clk[g.nodes[1] or -1] or a0
        local rep = { short = 0, slots = 0, years = 0 }
        advance(st, M, t0, a, rep)
        local t1 = rep.stopAt or a
        for _, k in ipairs(g.nodes) do clk[k] = t1 end
        nslots = nslots + rep.slots
        spread(g, M, st.e)
        if rep.trip then events[#events + 1] = { ev = rep.trip, t = t1, gid = g.id } end
        if dt > 60 and not rep.trip then caught = { dt = dt, years = rep.years, short = rep.short, grid = g.id } end
        G.short[g.id] = (G.short[g.id] or 0) + rep.short
      end
    end
    if #events == 0 then break end
    apply_events(events)
    topology(a, clk)
  end
  -- the status of each grid now, and its flows (the overlay and menus read them)
  for _, g in ipairs(G.list) do
    local M, st = G.models[g.id], G.st[g.id]
    if M and st then
      local sup, need, served, all, loss = statusAt(M, st, a)
      local s = { supply = sup, need = need, served = served, powered = all, stored = st.e, cap = M.C,
                  short = G.short[g.id] or 0, dt = dt, t = a, loss = loss or 0 }
      G.short[g.id] = 0
      local BP = ref("base_power")
      if M.net and BP then
        local k = (slotOf(M, a) % M.N) + 1
        local F = BP.flowsAt(M.net, k)
        G.flow[g.id] = { F = F, k = k }
        s.loss = F.loss
        s.limited, s.limitEl = BP.limitedBy(M.net, F)
        s.limitShare = s.limitEl and s.limitEl.share or 0
      else
        G.flow[g.id] = nil
      end
      G.status[g.id] = s
    end
  end
  local FT = ref("feats"); if FT and FT.gridTick then pcall(FT.gridTick, G.list, G.models, G.status, a, { slotOf = slotOf, slotLight = slotLight, slotInfo = slotInfo }) end   -- (progression P2)
  write_save(a)
  last_adv = now()
  if w0 then PROF.advance_ms = (wall() - w0) * 1000 end
  PROF.n_advance = PROF.n_advance + 1
  PROF.slots = nslots
  return dt
end

-- Build the grids from the records as they are (the old ones already
-- advanced): each store's charge from grid.e. `clk` (sid → agency time a
-- grid has reached, mid-advance) carries over to the grids they are in now.
topology = function(a, clk)
  local ST, B = ref("structures"), ref("bases")
  local w0 = wall()
  local bodies = space and space.bodies and space.bodies() or {}
  local all = cables_list()
  local live, dead, at = split_cables(all)
  local blist = B.list()
  local grids, bySid, byNode, nodeOf = buildGrids(ST.list(), blist, live, defs, ST.partPose, RADIUS)
  -- the slots: once per session, on the home world (off-world building is
  -- step 13's: a moon's light needs its own slots)
  if not slot then
    local hb = save.get("base.body")
    local bn = nil
    for _, g in ipairs(grids) do
      for _, e in ipairs(g.parts) do if e.def.power and e.def.power.kind == "solar" then bn = bn or e.rec.b end end
    end
    if bn or hb then slot = slots_for(bodies, bn or hb) end
  end
  local bsid = {}
  for _, b in ipairs(blist) do bsid[b.id] = b.sid end
  local RP = ref("reactor_plant")
  local BT = ref("base_tower")
  local opts = { cablesAt = at, state = breaker_state, baseSid = function(bid) return bsid[bid] end,
                 towerNeedOf = BT and BT.drawOf or nil,
                 plantKW = RP and RP.gridGen or nil,
                 -- (S7) a plant's pumps, the fluid network's pumps and the airlocks' pumps
                 auxKW = function(sid, uid)
                   local FN, RA, LX, LZ, TB = ref("fluid_net"), ref("room_air"), ref("logistics"), ref("lasers"), ref("timber")
                   return (RP and RP.gridAux and RP.gridAux(sid, uid) or 0) + (FN and FN.gridAux and FN.gridAux(sid, uid) or 0)
                          -- (W1) a Sawbench while it saws
                          + (TB and TB.gridAux and TB.gridAux(sid, uid) or 0)
                          + (RA and RA.gridAux and RA.gridAux(sid, uid) or 0)
                          -- (X5) a quarry drive while it digs, a conveyor line while it runs, a tube blower
                          + (LX and LX.gridAux and LX.gridAux(sid, uid) or 0)
                          -- (X9) a Capacitor Bank while it charges, a Laser Emitter while it burns CW
                          + (LZ and LZ.gridAux and LZ.gridAux(sid, uid) or 0)
                 end }
  local BP = ref("base_power")
  local t = read_e()
  local models, sts, byId, byBase, edgeOf = {}, {}, {}, {}, {}
  for _, g in ipairs(grids) do
    local M = gridModel(g, ST.partPose, towers_need(), opts)
    if slot then
      M.A0, M.L, M.N = slot.A0, slot.L, slot.N
      M.prof = profile_of(M, bodies)
    else
      -- (no sun to slot: the light now, held)
      M.A0, M.L, M.N = 0, 1e9, 1
      M.prof = nil
    end
    -- (S5) the network: losses by slot, the slots that trip something
    if BP and BP.network then
      local spec = netSpec(g, M, function(arr) return soiled(arr) end)
      local ok, net = pcall(BP.network, spec)
      if ok and net then
        M.net = net
        M.lossP, M.trip, M.peak, M.xpeak = BP.yearOf(net, M.N)
        for i, e in ipairs(net.edges) do edgeOf[e.id] = { gid = g.id, i = i } end
      elseif log then log("base_grid: the network of " .. tostring(g.id) .. " failed: " .. tostring(net)) end
    end
    local e = 0
    for _, s in ipairs(M.stores) do
      local have = t[s.key]
      if have == nil then have = s.cap * s.fill end
      e = e + math.max(0, math.min(s.cap, tonumber(have) or 0))
    end
    models[g.id] = M
    sts[g.id] = { e = e }
    byId[g.id] = g
    for _, bid in ipairs(g.bases) do byBase[bid] = g end
    if clk then
      local c = nil
      for _, k in ipairs(g.nodes) do if clk[k] then c = c and math.min(c, clk[k]) or clk[k] end end
      for _, k in ipairs(g.nodes) do clk[k] = c or a end
    end
  end
  G.list, G.bySid, G.models, G.st, G.byId, G.byBase = grids, bySid, models, sts, byId, byBase
  G.byNode, G.nodeOf = byNode, nodeOf
  G.edgeOf, G.dead = edgeOf, dead
  G.status, G.flow = {}, {}
  local CB = ref("base_cable")
  vers.st, vers.bs, vers.cb = ST.version, B.version, CB and CB.version or 0
  version = version + 1
  if w0 then PROF.topo_ms = (wall() - w0) * 1000 end
end

-- Rebuild the grids from the records (the old ones first advanced to now).
local function rebuild()
  local ST, B = ref("structures"), ref("bases")
  if not (ST and B and ST.list and ST.partPose) then return false end
  local w0 = wall()
  local a = agency_now()
  if #G.list > 0 then advance_all(a) end
  topology(a)
  advance_all(a)
  last_rebuild = now()
  dirty = false
  if w0 then PROF.rebuild_ms = (wall() - w0) * 1000 end
  PROF.n_rebuild = PROF.n_rebuild + 1
  return true
end

-- ── the API ─────────────────────────────────────────────────────────────────

function grids() return G.list end
-- (a question asked right after a change gets the grids as they are now: the
-- versions are compared and the grids rebuilt on the spot if they moved)
local function fresh()
  local ST, B, CB = ref("structures"), ref("bases"), ref("base_cable")
  if not (ST and B) then return end
  local cv = CB and CB.version or 0
  if ST.version ~= vers.st or B.version ~= vers.bs or cv ~= vers.cb then
    vers.st, vers.bs, vers.cb = ST.version, B.version, cv
    dirty = true
  end
  -- (perfmap 2026-11-11) Every part-state write bumps structures.version (a
  -- door, a heater's thermostat, a seal, a creak), and the readers asking
  -- every frame (the map's base tags through base_tower.bases, the console's
  -- POWER page, comms) each forced a whole rebuild on the next frame: up to
  -- a rebuild a frame in Dust Season's storm with the map open (one measured
  -- at 1.45 s). A rebuild in an earlier frame less than half a second ago
  -- holds; update() rebuilds when the half second is up, as it always did.
  -- (The same frame, or a clock that is not moving, still rebuilds at once.)
  local t = now()
  if dirty and t > last_rebuild and t - last_rebuild < FRESH_MIN then return end
  if dirty then rebuild() end
end
FRESH_MIN = 0.5
local grid_at
function gridOf(bid) fresh() return G.byBase[bid] end
-- (S5) A cable's flow now: → { P (kW, + from its a end to its z end), share
-- (of its rating), loss (kW), cap (kW), dead, why, burnt, grid } | nil
function cableFlow(id)
  fresh()
  local why = G.dead and G.dead[id]
  if why then return { dead = true, why = why, burnt = why == "burnt through", P = 0, share = 0, loss = 0 } end
  local eo = G.edgeOf and G.edgeOf[id]
  if not eo then return nil end
  local M, f = G.models[eo.gid], G.flow[eo.gid]
  if not (M and M.net and f) then return nil end
  local P = f.F.P[eo.i] or 0
  local cap = M.net.cap[eo.i]
  return { P = P, share = math.abs(P) / cap, loss = f.F.cl[eo.i] or 0, cap = cap, grid = eo.gid,
           peak = M.peak and M.peak[eo.i] or nil }
end
-- (S5) A breaker's or a transformer's state and flow now:
-- breaker → { state, kW, rating, share, main, cables }; transformer →
-- { kW, share, loss, cables } | {}
function partFlow(sid, uid)
  fresh()
  local g = grid_at(sid, uid)
  local key = tostring(sid) .. ":" .. tostring(uid)
  local M = g and G.models[g.id]
  local f = g and G.flow[g.id]
  local out = { state = breaker_state(sid, uid), cables = 0 }
  local CB = ref("base_cable")
  local mine = (CB and CB.at) and CB.at(sid, uid) or {}
  out.cables = #mine
  if not (M and M.net) then return out end
  for _, b in ipairs(M.breakers or {}) do
    if b.key == key then
      out.rating, out.main, out.ir = b.kW, b.main, b.ir
      local kw = 0
      if b.main then
        for _, m in ipairs(M.net.mains or {}) do if m.key == key then kw = m.load end end
      elseif f then
        for i, e in ipairs(M.net.edges) do
          for _, gd in ipairs(e.guard or {}) do if gd.key == key then kw = math.max(kw, math.abs(f.F.P[i] or 0)) end end
        end
      end
      out.kW, out.share = kw, kw / b.kW
    end
  end
  for _, x in ipairs(M.xfmrs or {}) do
    if x.key == key then
      local S = f and f.F.xl[key] or 0
      out.kW, out.share = S, S / (x.pw.kva or 100)
      local BP = ref("base_power")
      out.loss = BP and BP.xfmrLossKW(x.pw, S) or 0
    end
  end
  return out
end

-- (W2) the grid a PART is on: its own terminal's when it is a piece of
-- equipment, else its structure's circuit's. nil: on no grid.
grid_at = function(sid, uid)
  if uid ~= nil then
    local k = G.nodeOf and G.nodeOf[tostring(sid) .. ":" .. tostring(uid)]
    if k then return G.byNode[k], k end
  end
  return G.bySid[sid], "s" .. tostring(sid)
end
-- The grid of a structure's own circuit (its lights, its rooms' machines'
-- sockets); with `uid`, the grid of that part.
function gridOfStruct(sid, uid) fresh() return (grid_at(sid, uid)) end
function gridOfPart(sid, uid) fresh() return (grid_at(sid, uid)) end
function nodeOf(sid, uid) fresh() local _, k = grid_at(sid, uid) return k end
-- (straight from the records: right after a placement, before any rebuild)
function nodeKeyOf(sid, uid)
  local ST = ref("structures")
  local r = ST and ST.get and ST.get(sid)
  local p = r and ST.getPart(sid, uid)
  if not p then return "s" .. tostring(sid) end
  return nodeKey(r, p, defs(p.id))
end
-- Is a part a piece of equipment that wants its own cable (and is its
-- structure under the wiring rule)? → true | false
function wantsCable(sid, uid)
  local ST = ref("structures")
  local r = ST and ST.get and ST.get(sid)
  local p = r and ST.getPart(sid, uid)
  if not p or r.aw or not WIRED then return false end
  return isEquipment(defs(p.id))
end
-- Is a structure's own circuit DEAD under the wiring rule: no cable path from
-- it to a source or a store? (Its fittings are dark: kit_live. A structure
-- as wired before is never dead this way: off any grid its fittings ran on
-- their own cells, and still do.) Cheap: table reads only, asked per light.
function circuitDead(sid)
  if not WIRED then return false end
  local ST = ref("structures")
  local r = ST and ST.get and ST.get(sid)
  if not r or r.aw then return false end
  local g = G.bySid[sid]
  if not g then return true end
  local M = G.models[g.id]
  return not (M and ((M.sources or 0) > 0 or (M.C or 0) > 0))
end
-- NOT WIRED: the one line a part's plate and menu show when it is equipment
-- under the rule with no cable, or a cable to nothing live. nil: fine (or
-- not electrical, or as wired before).
function wireWhy(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  if not (d and (d.power or d.tower)) then return nil end
  local W = wiring(sid, uid)
  if W.legacy then return nil end
  local pw = d.power
  if pw and (pw.kind == "breaker") then return nil end
  if W.cables == 0 then
    if W.equipment then
      local makes = pw and (pw.kind == "solar" or pw.kind == "rtg" or pw.kind == "plant")
      return makes and "NOT WIRED: its power goes nowhere (run a Power Cable from it to a battery or to what it should feed)"
        or (pw and pw.kind == "store") and "NOT WIRED: nothing charges it and it feeds nothing (run a Power Cable to a source, and one to what it should feed)"
        or "NOT WIRED: run a Power Cable from it to a powered part"
    end
    return "no cable reaches this building: run a Power Cable from a source or a battery to any piece of it"
  end
  if not W.live then return "its cables reach no source and no charged battery" end
  return nil
end
-- WIRED TO: what a part's terminal (or its structure's circuit) is cabled to.
-- → { cables = n, live (its grid has a source or a charged store), sources,
--     grid, equipment (it wants its own cable), legacy (as wired before) }
function wiring(sid, uid)
  fresh()
  local k = nodeKeyOf(sid, uid)
  local g = G.byNode[k]
  local ST, CB = ref("structures"), ref("base_cable")
  local r = ST and ST.get and ST.get(sid)
  local out = { cables = 0, live = false, sources = 0, grid = g and g.id or nil, node = k,
                equipment = wantsCable(sid, uid), legacy = (r and r.aw) and true or (not WIRED) }
  -- the cables on this node: its own part's, or (a circuit) any of its structure's pieces'
  for _, c in ipairs((CB and CB.list) and CB.list() or {}) do
    for _, e in ipairs({ c.a, c.z }) do
      if nodeKeyOf(e.sid, e.uid) == k then
        out.cables = out.cables + 1
        local o = (e == c.a) and c.z or c.a
        out.to = out.to or {}
        out.to[#out.to + 1] = { sid = o.sid, uid = o.uid, cable = c.id, len = c.len }
      end
    end
  end
  local M, s = g and G.models[g.id], g and G.status[g.id]
  if M then
    out.sources = M.sources or 0
    out.live = (M.sources or 0) > 0 or ((s and s.stored or 0) > 1e-6)
    out.powered = s and s.powered or false
  end
  return out
end
-- (scenarios) a start state already lived in: sid's grid with its stores full.
-- → true | nil (no grid with a store)
-- (scn_dust) `frac`: charged to that share of the store instead (0..1)
function chargeFull(sid, frac)
  fresh()
  local g = G.bySid[sid]
  local M, st = g and G.models[g.id], g and G.st[g.id]
  if not (M and st and (M.C or 0) > 0) then return nil end
  st.e = M.C * (frac and math.max(0, math.min(1, frac)) or 1)
  spread(g, M, st.e)
  return true
end
-- (S6) Is a part's load served now? (a plant's pump on a grid short and
-- flat drops out.) → true | false | nil (not on a grid, or no load)
function partServed(sid, uid)
  local g = grid_at(sid, uid)
  local M, s = g and G.models[g.id], g and G.status[g.id]
  if not (M and s and s.served) then return nil end
  for i, l in ipairs(M.loads) do if l.sid == sid and l.uid == uid then return s.served[i] == true end end
  return nil
end
-- (the interaction plan §3) WHY NOT: would a hand on piece (sid, uid)'s
-- switch be refused making it `want`? A breaker can't be closed into its
-- trip (Reset clears it); a cable on its CLOSE terminal has it (logic_net's
-- authority). A load's switch is never refused: no power is a reason it
-- doesn't RUN (`powerWhy`), not a reason it can't be switched. → nil | sentence
function whyNot(sid, uid, want)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not p then return "that piece is gone" end
  local d = defs(p.id)
  local pw = d and d.power
  local PI = ref("part_info")
  local who = "the " .. tostring(d and d.label or "piece")
  if PI and PI.called then local ok, n = pcall(PI.called, sid, uid); if ok and n then who = n end end
  if pw and pw.kind == "breaker" and want and breaker_state(sid, uid) == "tripped" then
    return who .. " tripped: Reset it first (it closes on a fault otherwise)"
  end
  local LN = ref("logic_net")
  if LN and LN.whyNot then
    local ok, w = pcall(LN.whyNot, sid, uid, want)
    if ok and w then return w end
  end
  return nil
end
-- WARN: what opening breaker (sid, uid) cuts, or nil (never a refusal)
function warnOf(sid, uid, want)
  if want then return nil end
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  if not (d and d.power and d.power.kind == "breaker") then return nil end
  local f = partFlow(sid, uid) or {}
  if f.main then return string.format("opening it cuts its structure off the grid (%.1f kW of lights, air and pumps)", f.kW or 0) end
  if (f.kW or 0) > 0.01 then return string.format("opening it stops %.1f kW across its cable", f.kW) end
  return nil
end
-- Why piece (sid, uid) has no power now, or nil when it has (or draws none):
-- "not on a base grid" | "the grid is short and its store is flat" | "its
-- structure's main breaker is open".
function powerWhy(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  local pw = d and d.power
  if not (pw and (pw.kind == "load" or pw.kind == "aux")) then return nil end
  local g, k = grid_at(sid, uid)
  local own = (k == "s" .. tostring(sid))
  -- (W2) no cable, or a cable to nothing that makes power: say what to do
  local W = wiring(sid, uid)
  if not W.legacy then
    if W.cables == 0 then
      return own and "no power: no cable reaches this building (run a Power Cable from a source or a battery to any piece of it)"
                 or "no power: NOT WIRED (run a Power Cable from it to a powered part)"
    end
    if not W.live then return "no power: its cables reach no source and no charged battery" end
  end
  if not g then return "no power: not on a base grid (a Power Cable from a source or a battery)" end
  local M, s = G.models[g.id], G.status[g.id]
  if M and M.mainsOff and M.mainsOff[sid] and own then return "no power: its structure's main breaker is open" end
  local served = partServed(sid, uid)
  if served == false then return "no power: the grid is short and its store is flat" end
  return nil
end
function model(gid) return G.models[gid] end
-- { supply, need, powered, stored, cap, short, served, t } | nil
function status(gid) return G.status[gid] end
function stored(gid) local s = G.status[gid]; return s and s.stored or 0 end
function slotInfo() return slot end
function lastCatchUp() return caught end
function markDirty() dirty = true end
function advanceNow() if #G.list > 0 then return advance_all(agency_now()) end return 0 end
function rebuildNow() light_cache = {}; return rebuild() end

-- A base's tower on its grid: → { supply, need (the grid's), draw (this
-- tower's), powered, stored, cap, grid, src = { … } }
function towerPower(bid)
  fresh()
  local g = G.byBase[bid]
  local BT = ref("base_tower")
  local d = (BT and BT.drawOf and BT.drawOf(bid)) or towers_need()
  if not g then return { supply = 0, need = d, draw = d, powered = false, stored = 0, cap = 0, src = {} } end
  local M, s = G.models[g.id], G.status[g.id]
  local powered = false
  if s then
    for i, l in ipairs(M.loads) do if l.bid == bid then powered = s.served[i] == true end end
  end
  local src = {}
  for _, e in ipairs(g.parts) do
    local pw = e.def.power
    if pw and (pw.kind == "rtg" or pw.kind == "solar" or pw.kind == "store") then
      src[#src + 1] = { id = e.p.id, uid = e.p.uid, sid = e.rec.id, label = e.def.label, kind = pw.kind, gen = pw.gen, cap = pw.cap }
    end
  end
  return { supply = s and s.supply or 0, need = M.need, draw = d, powered = powered, stored = s and s.stored or 0,
           cap = M.C, grid = g.id, src = src, short = s and s.short or 0, structures = #g.sids, towers = #g.bases,
           cables = g.cables, sources = M.sources, solar = s and (s.supply - M.base) or 0, rtg = M.base,
           loss = s and s.loss or 0, limited = s and s.limited or nil, limitShare = s and s.limitShare or 0,
           breakers = #(M.breakers or {}), xfmrs = #(M.xfmrs or {}), plant = M.plant or 0 }
end

-- How long the store lasts at this draw with no sun (s; nil = forever).
function nightLeft(gid)
  local M, s = G.models[gid], G.status[gid]
  if not (M and s) then return 0 end
  local net = M.base - M.need - (s.loss or 0)
  if net >= 0 then return nil end
  return s.stored / -net
end

function start(node)
  if findScripts then
    local all = findScripts("base_grid")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  G = { list = {}, byId = {}, bySid = {}, byNode = {}, nodeOf = {}, byBase = {}, models = {}, st = {}, status = {}, flow = {}, short = {}, edgeOf = {}, dead = {} }
  vers = { st = nil, bs = nil, cb = nil }
  trips = 0
  dirty, last_rebuild, last_adv, slot, light_cache, e_saved, caught = true, -10, -10, nil, {}, nil, nil
  SOIL, soil_d, soil_w, soiled_cache, soil_reg = { k = {}, sky = {}, t = nil, n_steps = 0 }, nil, nil, {}, false
  -- (W2) is this a save from before the wiring rule? Decided HERE, as the
  -- scene loads, from the save itself: a new game has no structures yet and
  -- is stamped at once, so what it builds (or a scenario stages) a moment
  -- later is never taken for old.
  migrated = true
  if save and save.get and tonumber(save.get("grid.wv")) ~= WIRE_VERSION then
    local l = save.get("struct.list")
    if type(l) == "table" and #l > 0 then migrated = false
    elseif save.set then save.set("grid.wv", WIRE_VERSION) end
  end
end

-- (W2) OLD SAVES. A save from before the wiring rule has no `grid.wv`: every
-- structure standing in it is marked `aw` ("as wired before") and keeps the
-- rule it was built under (one bus a structure; the tower's 150 m), so
-- nothing the player built goes dark. What is built from now on wants its
-- cables. Once per save. → the number marked
function migrate()
  migrated = true
  if not (save and save.get and save.set) then return 0 end
  if tonumber(save.get("grid.wv")) == WIRE_VERSION then return 0 end
  local ST = ref("structures")
  if not (ST and ST.list and ST.put) then migrated = false return 0 end
  local n = 0
  for _, r in ipairs(ST.list()) do
    if not r.aw then r.aw = 1; ST.put(r); n = n + 1 end
  end
  save.set("grid.wv", WIRE_VERSION)
  if n > 0 and log then log(string.format("base_grid: %d structure(s) from before the wiring rule keep their grid as it was", n)) end
  return n
end
-- (a structure's menu: "Rewire by hand") drop the mark: its equipment wants
-- cables from now on. → true | nil
function rewire(sid)
  local ST = ref("structures")
  local r = ST and ST.get and ST.get(sid)
  if not (r and r.aw) then return nil end
  r.aw = nil
  ST.put(r)
  dirty = true
  return true
end

-- (W2) THE MENU on anything electrical: what its terminal is wired to, or
-- that it is not; on a structure as wired before, the way to the new rule.
local function wire_provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local def = defs(part.id)
  if not (def and (def.power or def.tower)) then return {} end
  local sid, uid = rec.id, part.uid
  local out = {}
  out[#out + 1] = { id = "wg_wired", type = "info", label = "Wiring", group = "Power", value = function()
      local W = wiring(sid, uid)
      if W.legacy then return "as wired before: shares its base's grid" end
      if W.cables == 0 then return W.equipment and "NOT WIRED · no cable on its terminal" or "the building's circuit · NO CABLE reaches it" end
      local names = {}
      for i, e in ipairs(W.to or {}) do
        if i > 3 then names[#names + 1] = string.format("+%d more", #W.to - 3) break end
        local op = ST.getPart(e.sid, e.uid)
        local od = op and defs(op.id)
        names[#names + 1] = string.format("%s (%.0f m)", od and od.label or "part", e.len or 0)
      end
      return string.format("%s%s · %s", W.equipment and "" or "the building's circuit: ", table.concat(names, ", "),
        W.live and "LIVE" or "no source on these cables")
    end }
  if rec.aw and WIRED then
    out[#out + 1] = { id = "wg_rewire", type = "action", label = "Rewire this structure by hand", group = "Power",
      hint = "its sources, batteries and machines will each want a cable",
      enabled = function() return engineer_why() == nil end,
      why = function() return engineer_why() end,
      job = { secs = 3.0, label = "Pulling the old bus links",
        check = function() if not ST.get(sid) then return false, "it's gone" end return true end,
        tick = function() end,
        done = function()
          rewire(sid)
          if ctx and ctx.toast then ctx.toast("rewired: cable each source, battery and machine") end
          return true
        end } }
  end
  return out, def.label
end
wireProviderFn = wire_provider
local wire_reg = false

function update(node, dt)
  local ST, B, CB = ref("structures"), ref("bases"), ref("base_cable")
  if not (ST and B) then return end
  if not migrated then migrate() end
  if not wire_reg then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", wire_provider, { id = "base_grid_wire", order = 5 }); wire_reg = true end
  end
  local sv, bv, cv = ST.version, B.version, CB and CB.version or 0
  if sv ~= vers.st or bv ~= vers.bs or cv ~= vers.cb then
    vers.st, vers.bs, vers.cb = sv, bv, cv
    dirty = true
  end
  local t = now()
  -- (on change: at once the first time, then at most twice a second while a
  -- stand or a placement churns the records)
  if dirty and t - last_rebuild > 0.5 then
    if #G.list > 0 then soil_tick() end   -- (G4: the sky and dust as they are now)
    rebuild()
    return
  end
  local every = (params and params.every) or 2.0
  if #G.list > 0 and t - last_adv >= every then
    -- (G4) the panels' dust and sky first: a factor that steps rebuilds the
    -- grids (advanced to now with the old one), so the step lands from here
    if soil_tick() then rebuild() return end
    advance_all(agency_now())
  end
  if not soil_reg then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", soil_provider, { id = "base_grid_soil", order = 6 }); soil_reg = true end
  end
end
