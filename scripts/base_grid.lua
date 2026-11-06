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

-- THE GRIDS. `structs` = structures.list(); `bases` = bases.list() (standing);
-- `cables` = { { a = { sid, uid }, z = { sid, uid } } }; `defs(id)` the parts;
-- `pose(rec, p, seat)` structures.partPose. → grids (list), bySid (sid → grid)
-- grid = { id, sids = { sid … }, bases = { bid … }, parts = { { rec, p, def } … } }
function buildGrids(structs, bases, cables, defs, pose, radius)
  radius = radius or RADIUS
  local U = uf_new()
  -- (S5) the BUSES: the same union without the cables, so each structure
  -- knows the lossless bus it sits on (a tower's 150 m share one)
  local Bu = uf_new()
  local byId = {}
  for _, r in ipairs(structs or {}) do byId[r.id] = r; uf_find(U, "s" .. tostring(r.id)); uf_find(Bu, "s" .. tostring(r.id)) end
  -- the radius: a structure with any part within it of a tower joins the base
  for _, b in ipairs(bases or {}) do
    local bk = "b" .. string.format("%06d", b.id)
    uf_find(U, bk)
    if b.sid and byId[b.sid] then uf_join(U, bk, "s" .. tostring(b.sid)); uf_join(Bu, bk, "s" .. tostring(b.sid)) end
    for _, r in ipairs(structs or {}) do
      -- (S5) a structure of network gear alone (a pole, a junction) is on
      -- the line its cables make, never on the tower's low-voltage ring
      local gearOnly = #(r.bp or {}) > 0
      for _, p in ipairs(r.bp or {}) do local d = defs(p.id); if not (d and d.netgear and not d.power) then gearOnly = false break end end
      if r.b == b.b and not gearOnly then
        for _, p in ipairs(r.bp or {}) do
          local x, y, z = pose(r, p, 0)
          if dist(x, y, z, b.x, b.y, b.z) <= radius then uf_join(U, bk, "s" .. tostring(r.id)); uf_join(Bu, bk, "s" .. tostring(r.id)) break end
        end
      end
    end
  end
  -- the cables
  for _, c in ipairs(cables or {}) do
    local a, z = c.a and byId[c.a.sid], c.z and byId[c.z.sid]
    if a and z then uf_join(U, "s" .. tostring(a.id), "s" .. tostring(z.id)) end
  end
  local roots, out, bySid = {}, {}, {}
  local function grid_of(root)
    local g = roots[root]
    if not g then
      g = { id = root, sids = {}, bases = {}, parts = {}, cables = 0, bus = {}, cableList = {} }
      roots[root] = g
      out[#out + 1] = g
    end
    return g
  end
  for _, b in ipairs(bases or {}) do
    local g = grid_of(uf_find(U, "b" .. string.format("%06d", b.id)))
    g.bases[#g.bases + 1] = b.id
  end
  for _, r in ipairs(structs or {}) do
    local g = grid_of(uf_find(U, "s" .. tostring(r.id)))
    g.sids[#g.sids + 1] = r.id
    g.bus[r.id] = uf_find(Bu, "s" .. tostring(r.id))
    bySid[r.id] = g
    for _, p in ipairs(r.bp or {}) do
      local d = defs(p.id)
      if d then g.parts[#g.parts + 1] = { rec = r, p = p, def = d } end
    end
  end
  for _, c in ipairs(cables or {}) do
    local g = c.a and bySid[c.a.sid]
    if g and c.z and bySid[c.z.sid] == g then g.cables = g.cables + 1; g.cableList[#g.cableList + 1] = c end
  end
  -- (a grid with nothing on it that makes, stores or draws power is dropped)
  local keep = {}
  for _, g in ipairs(out) do
    local live = #g.bases > 0
    for _, e in ipairs(g.parts) do if e.def.power then live = true end end
    if live then
      table.sort(g.bases)
      -- the id: its first base's, or its first structure's
      local m = nil
      for _, sid in ipairs(g.sids) do if not m or sid < m then m = sid end end
      g.id = (#g.bases > 0) and ("b" .. tostring(g.bases[1])) or ("s" .. tostring(m))
      keep[#keep + 1] = g
    else
      for _, sid in ipairs(g.sids) do bySid[sid] = nil end
    end
  end
  return keep, bySid
end

-- ── pure: what a grid is made of ────────────────────────────────────────────
-- → M = { base (EC/s always), arrays = { { key, gen, x,y,z, ax,ay,az } },
--         loads = { { kind, bid?, need, label } }, need, stores = { { key, cap, eff, fill } },
--         C, eff, sources = n, body }
-- `towerNeed` = the tower's draw (parts_base tower.draw).
function gridModel(g, pose, towerNeed, opts)
  opts = opts or {}
  local M = { base = 0, arrays = {}, loads = {}, need = 0, stores = {}, C = 0, eff = 1, sources = 0, rtg = 0, body = nil,
              rtgs = {}, breakers = {}, xfmrs = {}, mainsOff = {} }
  local effw, capw = 0, 0
  -- (S5) a breaker with no cable at all is its structure's MAIN: open or
  -- tripped, that structure's own loads are off the grid
  for _, e in ipairs(g.parts) do
    local pw = e.def.power
    if pw and pw.kind == "breaker" then
      local key = tostring(e.rec.id) .. ":" .. tostring(e.p.uid)
      local main = not (opts.cablesAt and (opts.cablesAt[key] or 0) > 0)
      local st = opts.state and opts.state(e.rec.id, e.p.uid) or "closed"
      M.breakers[#M.breakers + 1] = { key = key, sid = e.rec.id, uid = e.p.uid, pw = pw, main = main, state = st, kW = breakerKW_(pw) }
      if main and st ~= "closed" then M.mainsOff[e.rec.id] = true end
    elseif pw and pw.kind == "xfmr" then
      M.xfmrs[#M.xfmrs + 1] = { key = tostring(e.rec.id) .. ":" .. tostring(e.p.uid), sid = e.rec.id, uid = e.p.uid, pw = pw }
    end
  end
  for _, bid in ipairs(g.bases) do
    local bsid = opts.baseSid and opts.baseSid(bid) or nil
    if not (bsid and M.mainsOff[bsid]) then
      M.loads[#M.loads + 1] = { kind = "tower", bid = bid, need = towerNeed or 2.0, label = "tower", sid = bsid }
      M.need = M.need + (towerNeed or 2.0)
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
      M.rtgs[#M.rtgs + 1] = { sid = r.id, gen = pw.gen or 0 }
    elseif pw and pw.kind == "solar" then
      local gx, gy, gz, U, F = pose(r, p, pw.lift or 1.0)
      -- the cells track about the part's +X (= up × front)
      local ax, ay, az = U.y * F.z - U.z * F.y, U.z * F.x - U.x * F.z, U.x * F.y - U.y * F.x
      M.arrays[#M.arrays + 1] = { key = string.format("%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f", key, gx, gy, gz, ax, ay, az),
                                  gen = pw.gen or 0, x = gx, y = gy, z = gz, ax = ax, ay = ay, az = az, b = r.b, sid = r.id }
      M.sources = M.sources + 1
    elseif pw and pw.kind == "store" then
      -- (J6: `effk` on the part = the installing Engineer's bonus, fixed at placement)
      local eff = pw.eff or 1
      if tonumber(p.effk) then eff = math.max(eff, math.min(0.99, eff + tonumber(p.effk))) end
      M.stores[#M.stores + 1] = { key = key, cap = pw.cap or 0, eff = eff, fill = pw.fill or 0, sid = r.id }
      M.C = M.C + (pw.cap or 0)
      effw, capw = effw + eff * (pw.cap or 0), capw + (pw.cap or 0)
    elseif pw and pw.kind == "load" and not M.mainsOff[r.id] then
      M.loads[#M.loads + 1] = { kind = "load", need = pw.use or 0, label = e.def.label, sid = r.id }
      M.need = M.need + (pw.use or 0)
    end
  end
  M.eff = capw > 0 and effw / capw or 1
  return M
end
-- (a breaker's rating in kW at 400 V: base_power.breakerKW's figure)
function breakerKW_(pw) return (pw and pw.amps or 63) * 400 / 1000 end

-- (S5) THE NETWORK SPEC of a grid for base_power.network: its buses, where
-- each source, load and store sits, its live cables (`cables` = the grid's,
-- every one on a closed path) with their guards and transformers.
-- prof(arr) = an array's year of slots (or nil). → spec
function netSpec(g, M, prof, defsAt)
  local idx, buses = {}, {}
  local function busOf(sid)
    local k = g.bus[sid] or ("s" .. tostring(sid))
    local i = idx[k]
    if not i then buses[#buses + 1] = k; i = #buses; idx[k] = i end
    return i
  end
  for _, sid in ipairs(g.sids) do busOf(sid) end
  local spec = { buses = buses, gen = {}, arrays = {}, loads = {}, stores = {}, edges = {}, mains = {}, xfmrs = {} }
  for i = 1, #buses do spec.gen[i] = 0 end
  for _, r in ipairs(M.rtgs or {}) do local b = busOf(r.sid); spec.gen[b] = spec.gen[b] + r.gen end
  for _, a in ipairs(M.arrays) do spec.arrays[#spec.arrays + 1] = { bus = busOf(a.sid), prof = prof and prof(a) or nil, kW = 0 } end
  local bySid = {}
  for _, l in ipairs(M.loads) do
    local b = l.sid and busOf(l.sid) or 1
    spec.loads[#spec.loads + 1] = { bus = b, kW = l.need, sid = l.sid }
    if l.sid then bySid[l.sid] = (bySid[l.sid] or 0) + l.need end
  end
  for _, st in ipairs(M.stores) do spec.stores[#spec.stores + 1] = { bus = busOf(st.sid), cap = st.cap } end
  local brk, xf = {}, {}
  for _, b in ipairs(M.breakers) do
    brk[b.key] = b
    if b.main and b.state == "closed" then spec.mains[#spec.mains + 1] = { key = b.key, kW = b.kW, sid = b.sid, load = bySid[b.sid] or 0 } end
  end
  for _, x in ipairs(M.xfmrs) do xf[x.key] = x; spec.xfmrs[#spec.xfmrs + 1] = { key = x.key, pw = x.pw } end
  for _, c in ipairs(g.cableList or {}) do
    local ka, kz = tostring(c.a.sid) .. ":" .. tostring(c.a.uid), tostring(c.z.sid) .. ":" .. tostring(c.z.uid)
    local e = { id = c.id, a = busOf(c.a.sid), z = busOf(c.z.sid), ty = c.ty or "lv16", len = c.len or 1, guard = {}, xf = {} }
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

local G = { list = {}, byId = {}, bySid = {}, byBase = {}, models = {}, st = {}, status = {}, flow = {}, short = {}, edgeOf = {}, dead = {} }
trips = 0                 -- probes: breakers tripped and cables burnt since the start
local vers = { st = nil, bs = nil, cb = nil }
local dirty, last_rebuild, last_adv = true, -10, -10
local slot = nil          -- { A0, L, N, Y, body, ref }
local light_cache = {}    -- array key → profile
local e_saved = nil       -- grid.e as read
local caught = nil        -- the last catch-up: { dt, years, short }

local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end

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
    if p then for j = 1, sl.N do prof[j] = prof[j] + p[j] end end
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
        local t0 = clk[g.sids[1] or -1] or a0
        local rep = { short = 0, slots = 0, years = 0 }
        advance(st, M, t0, a, rep)
        local t1 = rep.stopAt or a
        for _, sid in ipairs(g.sids) do clk[sid] = t1 end
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
  local grids, bySid = buildGrids(ST.list(), blist, live, defs, ST.partPose, RADIUS)
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
  local opts = { cablesAt = at, state = breaker_state, baseSid = function(bid) return bsid[bid] end }
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
      local spec = netSpec(g, M, function(arr) return light_cache[arr.key] end)
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
      for _, sid in ipairs(g.sids) do if clk[sid] then c = c and math.min(c, clk[sid]) or clk[sid] end end
      for _, sid in ipairs(g.sids) do clk[sid] = c or a end
    end
  end
  G.list, G.bySid, G.models, G.st, G.byId, G.byBase = grids, bySid, models, sts, byId, byBase
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
  if dirty then rebuild() end
end
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
  local g = G.bySid[sid]
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
      out.rating, out.main = b.kW, b.main
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

function gridOfStruct(sid) fresh() return G.bySid[sid] end
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
  local d = towers_need()
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
           breakers = #(M.breakers or {}), xfmrs = #(M.xfmrs or {}) }
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
  G = { list = {}, byId = {}, bySid = {}, byBase = {}, models = {}, st = {}, status = {}, flow = {}, short = {}, edgeOf = {}, dead = {} }
  vers = { st = nil, bs = nil, cb = nil }
  trips = 0
  dirty, last_rebuild, last_adv, slot, light_cache, e_saved, caught = true, -10, -10, nil, {}, nil, nil
end

function update(node, dt)
  local ST, B, CB = ref("structures"), ref("bases"), ref("base_cable")
  if not (ST and B) then return end
  local sv, bv, cv = ST.version, B.version, CB and CB.version or 0
  if sv ~= vers.st or bv ~= vers.bs or cv ~= vers.cb then
    vers.st, vers.bs, vers.cb = sv, bv, cv
    dirty = true
  end
  local t = now()
  -- (on change: at once the first time, then at most twice a second while a
  -- stand or a placement churns the records)
  if dirty and t - last_rebuild > 0.5 then rebuild() return end
  local every = (params and params.every) or 2.0
  if #G.list > 0 and t - last_adv >= every then advance_all(agency_now()) end
end
