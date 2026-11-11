-- KIT_LOAD — what a Build Kit piece carries, and what happens when it is
-- asked to carry too much (progression W2; work/progression/PLAN.md §3.4;
-- docs/base-building.md §37). Ty 11-11 on wood: "obviously it shouldn't
-- sustain crazy damage ... on the home planet they'll last forever
-- essentially, just not handle crazy heavy weights."
--
-- A pure RECORDS half (it loads from disk in a luajit test,
-- tests/smoke_kit_load.lua) and a SCENE half on the Build Kit node
-- (scenes/system.ron): the 2 Hz driver. Everything is in a structure's frame
-- (+X right, +Y up, +Z front; kit_snap.frameOf) or its body's, never a world
-- point kept past the frame (docs/positions-and-frames.md rule 1).
--
-- ── CAPACITY ────────────────────────────────────────────────────────────────
-- By how a piece carries (kindOf):
--   bend   floors, beams, trusses, decks, roofs (snap "floor"; a wall or a
--          post laid flat): a point load at the middle of a clear span L is
--          carried up to  cap = S × sec × (2/L)²  kN  (S the material's
--          STRENGTH, sec the piece's SEC), so a 6 m span carries a ninth of a
--          2 m one. Worked as moments: each span between two bearings and
--          each overhang past the last one (an overhang of a counts as a
--          span of 2a) is asked  M × L / (S × sec × hp)  with M the point
--          loads' moments (F (s − g0)(g1 − s) / L on a span, F × reach on an
--          overhang) and its own weight's (w L²/8, w a²/2); the worst is r.
--          Its bearings are what it rests on and, for a piece the kit counts
--          as on the ground, the ground itself where the terrain is under it
--          (sampled: a beam laid across a dug gap spans the gap). A plate (a
--          floor, a deck: sides within 1.5 of each other) spans whichever
--          way does better.
--   post   r = F / (S × POST_K × min(1, 3/L) × hp)   (a slender post less)
--   wall   r = F / (S × WALL_K × length × hp)
--   solid  r = F / (S × SOLID_K × max(1, area) × hp)
-- A piece founded on the ground — a pile (`gnd`), a cast footing (`ft`), or
-- a post, wall or block standing on it — carries anything (r = 0) and hands
-- nothing on. Steel, concrete and regocrete use the same rules at 15-40 ×
-- timber's strength, so a base built the usual way never sags; timber is the
-- thing a player breaks first. A 4 m timber beam on posts carries about
-- 600 kg at its middle: a motorcycle yes, a fuelled hopper (1.5 t) no.
--
-- ── LOADS ───────────────────────────────────────────────────────────────────
-- Dead: each piece's own weight (9.81 × mass), handed down to what it rests
-- on by the lever rule along its span (or by nearness, for a post or a
-- wall). Live: 1 kN for each walker standing on a piece, and each craft's
-- whole weight (its true mass: dry, propellant, hold and crew) shared over
-- the tyres it has down (or, legs and skids, its lowest parts) and given to
-- the piece under each. Evaluated at 2 Hz and only while a walker or a craft
-- is on a piece that is not founded on the ground; only the pieces under the
-- live loads (and what rests on them) are worked out. Nothing at all runs a
-- frame while nobody is on such a piece.
--
-- ── WHAT IT DOES ────────────────────────────────────────────────────────────
--   r > 0.7   it creaks (CC0 recordings of a big timber creaking, spatial at
--             the piece, more often and louder as r rises; steel groans) and
--             it SAGS: its drawn mesh is lowered by up to min(12 cm, 2 % of
--             the span) at r 1.3 (its colliders stay put), and what rests on
--             it rides down with it
--   r > 1.0   for 2 s: its hp (the part state `hp`, the field lasers and
--             damage use) falls 0.15 a second, and its capacity with it
--             (cap × hp: a cracked beam carries less); splinters tick
--   hp 0      it breaks: a crack, chunks, and kit_snap.fallsWith takes down
--             what it held; crew on it fall, a craft on it drops
-- A piece that held on keeps the hp it lost (the Repair Kit mends it). No
-- popup, no caption: the creak and the sag are the warning. Placement is
-- never refused: build a long wooden pier and drive a rocket onto it.
--
-- Probes: lastResult(sid), stateOf(sid, uid), stats(), evaluateNow(), addMass(node id, t).

-- the material's strength for carrying (kN at a 2 m span with sec 1); not
-- MATS.strength, which is a laser's and a joint's (timber 40 there too)
STRENGTH = { wood = 40, steel = 600, concrete = 1500, regocrete = 1200, glass = 150, graphite = 60, film = 1 }
-- a bending piece's section factor; a floor-class piece not named takes SEC_BEND
SEC = {
  beam2 = 0.6, beam4 = 0.6, beam6w = 1.0, trussW4 = 2.0, deck24 = 0.6, plankFloor = 0.3, shingleRoof = 0.3,
  floor = 0.3, floor21 = 0.3, floor11 = 0.3, catwalk = 0.3, roofPitch = 0.3, roofRidge = 0.3,
}
SEC_BEND = 0.3
POST_K = 0.2         -- a post: S × 0.2 × min(1, 3/L)
WALL_K = 1.0         -- a wall: S × 1.0 per metre of it
SOLID_K = 4.0        -- anything else: S × 4 per m² of footprint
WALKER_KN = 1.0
G = 9.81
CREAK_R = 0.7
BREAK_R = 1.0
BREAK_HOLD = 2.0     -- s over 1.0 before it starts to give
HP_RATE = 0.15       -- hp a second while it gives
SAG_MAX = 0.12       -- m, at r = CREAK_R + SAG_SPAN
SAG_SPAN = 0.6
EVERY = 0.5          -- s between evaluations (2 Hz)
PLATE = 1.5          -- a piece whose sides are within this ratio spans either way
GROUND_STEP = 0.5    -- m between the terrain samples under a piece laid on the ground

local abs, min, max, sqrt, cos, sin, floor = math.abs, math.min, math.max, math.sqrt, math.cos, math.sin, math.floor

-- ── pure ────────────────────────────────────────────────────────────────────
function strengthOf(d)
  return STRENGTH[d and d.mat or ""] or 100
end

-- How the piece carries: "bend" | "post" | "wall" | "solid"
function kindOf(p, d)
  local c = d.snap or (d.deck and "slab") or "block"
  local flat = abs(p.pitch or 0) > 1e-3 or abs(p.roll or 0) > 1e-3
  if c == "floor" then return "bend" end
  if c == "post" then return flat and "bend" or "post" end
  if c == "wall" then return flat and "bend" or "wall" end
  return "solid"
end
function secOf(d)
  return SEC[d.piece or ""] or SEC_BEND
end
-- the point load at the middle of a clear span L a bending piece carries (kN)
function capAt(d, L, hp)
  local Le = max(1.0, L or 2.0)
  return strengthOf(d) * secOf(d) * (hp or 1) * (2 / Le) ^ 2
end
-- what an upright piece carries (kN), its box a = kit_snap.solid
function axialCap(kind, d, a, hp)
  local S = strengthOf(d) * (hp or 1)
  if kind == "post" then return S * POST_K * min(1, 3 / max(0.5, a.y1 - a.y0)) end
  if kind == "wall" then return S * WALL_K * max(0.5, 2 * max(a.hx, a.hz)) end
  return S * SOLID_K * max(1, 4 * a.hx * a.hz)
end
-- the sag shown at r on a span L (m)
function sagOf(r, L)
  if not r or r <= CREAK_R then return 0 end
  local k = min(1, (r - CREAK_R) / SAG_SPAN)
  return min(SAG_MAX, 0.02 * max(2, L or 2)) * k
end
-- seconds to the next creak and its volume at r (nil: quiet)
function creakOf(r)
  if not r or r <= CREAK_R then return nil end
  local k = min(1, (r - CREAK_R) / 0.4)
  return 3.2 - 2.4 * k, 0.35 + 0.55 * k
end
-- One step of a piece's state st = { over, hp } at r over dt: → hp, broke
function stepHp(st, r, dt)
  st.hp = st.hp or 1.0
  if r and r > BREAK_R then st.over = (st.over or 0) + dt else st.over = 0 end
  if st.over >= BREAK_HOLD then st.hp = max(0, st.hp - HP_RATE * dt) end
  return st.hp, st.hp <= 0
end

-- a rect's axes in the structure frame: X = (c, -s), Z = (s, c) (kit_snap.solid's yaw)
local function rect_axes(a)
  local c, s = cos(a.yaw or 0), sin(a.yaw or 0)
  return c, -s, s, c
end
-- (x, z) into a's rect, and how far it was outside
local function clamp_in(a, x, z)
  local Xx, Xz, Zx, Zz = rect_axes(a)
  local dx, dz = x - a.x, z - a.z
  local u, v = dx * Xx + dz * Xz, dx * Zx + dz * Zz
  local cu, cv = max(-a.hx, min(a.hx, u)), max(-a.hz, min(a.hz, v))
  local out = sqrt((u - cu) ^ 2 + (v - cv) ^ 2)
  return a.x + cu * Xx + cv * Zx, a.z + cu * Xz + cv * Zz, out
end
local function in_rect(a, x, z, m)
  local Xx, Xz, Zx, Zz = rect_axes(a)
  local dx, dz = x - a.x, z - a.z
  return abs(dx * Xx + dz * Xz) <= a.hx + m and abs(dx * Zx + dz * Zz) <= a.hz + m
end

-- ── THE MODEL: per structure, kept on kit_snap's graph (dropped with it) ─────
-- node fields: p, d, a (kit_snap), kind, found, ygnd, W (kN), sup = { m … }
-- (what it rests on), dep = { n … } (what rests on it), axes = { { ex, ez, hl } … }
local function axes_of(n)
  local a = n.a
  local Xx, Xz, Zx, Zz = rect_axes(a)
  local hx, hz = a.hx, a.hz
  local out = {}
  if hx >= hz then out[1] = { Xx, Xz, hx } else out[1] = { Zx, Zz, hz } end
  if max(hx, hz) < PLATE * max(1e-3, min(hx, hz)) then
    out[2] = (hx >= hz) and { Zx, Zz, hz } or { Xx, Xz, hx }
  end
  return out
end
function model(rec, defs, KS)
  local g = KS.graphOf(rec, defs)
  if g.kl then return g.kl end
  local hang = KS.supportMap(rec, defs)
  local M = { list = {}, by = {}, g = g }
  for _, n in ipairs(g.list) do
    local p, d, a = n.p, n.d, n.a
    local e = { p = p, d = d, a = a, src = n, kind = kindOf(p, d), sup = {}, dep = {}, W = G * (d.mass or 0),
                hang = hang[p.uid], cand = {} }
    local yg = KS.isGrounded(p, a)
    e.found = p.gnd == true or p.ft ~= nil or (yg and e.kind ~= "bend")
    e.ygnd = yg and not e.found
    if e.kind == "bend" then e.axes = axes_of(e) end
    M.list[#M.list + 1] = e
    M.by[n] = e
    M.by[p.uid] = e
  end
  -- what holds each piece, by the graph's links (m.adj lists who m holds)
  for _, m in ipairs(g.list) do
    local em = M.by[m]
    local adj = m.adj or {}
    for i = 1, #adj, 2 do
      local en = M.by[adj[i]]
      if en then en.cand[#en.cand + 1] = em; en.cand[#en.cand + 1] = adj[i + 1] end
    end
  end
  for _, e in ipairs(M.list) do
    if not e.found and e.hang ~= nil then
      local on, side, fall = {}, {}, {}
      for i = 1, #e.cand, 2 do
        local m, w = e.cand[i], e.cand[i + 1]
        if w == 0 then on[#on + 1] = m
        elseif e.kind == "bend" and (m.kind == "post" or m.kind == "wall")
          and min(e.a.y1, m.a.y1) - max(e.a.y0, m.a.y0) > 0.03 then side[#side + 1] = m   -- (a beam's end in a post, a roof against a gable; not a fence standing on it)
        elseif m.hang ~= nil and m.hang < e.hang then fall[#fall + 1] = m end
      end
      local sup = on
      for _, m in ipairs(side) do sup[#sup + 1] = m end
      if #sup == 0 then sup = fall end
      e.sup = sup
      for _, m in ipairs(sup) do m.dep[#m.dep + 1] = e end
    end
    e.cand = nil
  end
  -- the order the loads go down in: a piece after everything resting on it
  local cnt, order, q, h = {}, {}, {}, 1
  for _, e in ipairs(M.list) do cnt[e] = #e.dep; if #e.dep == 0 then q[#q + 1] = e end end
  while h <= #q do
    local e = q[h]; h = h + 1
    order[#order + 1] = e
    for _, m in ipairs(e.sup) do
      cnt[m] = cnt[m] - 1
      if cnt[m] == 0 then q[#q + 1] = m end
    end
  end
  if #order < #M.list then      -- (a ring of pieces each resting on the next: taken as they come)
    local seen = {}
    for _, e in ipairs(order) do seen[e] = true end
    for _, e in ipairs(M.list) do if not seen[e] then order[#order + 1] = e end end
  end
  for i, e in ipairs(order) do e.ord = i end
  M.order = order
  g.kl = M
  return M
end

-- Is a graph node founded on the ground (it carries anything)? (no model needed)
local function founded(KS, n)
  local p, a = n.p, n.a
  return p.gnd == true or p.ft ~= nil or (KS.isGrounded(p, a) and kindOf(p, n.d) ~= "bend")
end
-- The piece of rec whose top is under the structure-local point (lx, ly, lz),
-- within `reach` below it (the highest such top). → model node | nil, and
-- whether there was one at all (a founded piece answers nil, true: the model
-- is only built for a load it has to work out)
function pieceUnder(rec, defs, KS, lx, ly, lz, reach)
  local g = KS.graphOf(rec, defs)
  local best, by = nil, -1e9
  KS.nodesNear(g, lx, lz, 0.5, function(n)
    local a = n.a
    if a.y1 <= ly + 0.15 and a.y1 >= ly - (reach or 1.5) and a.y1 > by and in_rect(a, lx, lz, 0.08) then
      best, by = n, a.y1
    end
  end)
  if not best then return nil, false end
  if founded(KS, best) then return nil, true end
  return model(rec, defs, KS).by[best], true
end

-- the bearings along one axis of a bending piece: { { s0, s1, m|false } … }
local function bearings(e, ex, ez, hl, ground)
  local a = e.a
  local out = {}
  for _, m in ipairs(e.sup) do
    local b = m.a
    local Xx, Xz, Zx, Zz = rect_axes(b)
    local sm = (b.x - a.x) * ex + (b.z - a.z) * ez
    local ext = b.hx * abs(ex * Xx + ez * Xz) + b.hz * abs(ex * Zx + ez * Zz)
    local s0, s1 = max(-hl, sm - ext), min(hl, sm + ext)
    if s1 >= s0 - 1e-6 then out[#out + 1] = { s0, max(s0, s1), m } end
  end
  if e.ygnd then
    local gi = ground and ground(e, ex, ez, hl)
    if gi == nil then out[#out + 1] = { -hl, hl, false }
    else for _, iv in ipairs(gi) do out[#out + 1] = { max(-hl, iv[1]), min(hl, iv[2]), false } end end
  end
  return out
end
local function merged_of(ivs)
  local s = {}
  for i, v in ipairs(ivs) do s[i] = v end
  table.sort(s, function(x, y) return x[1] < y[1] end)
  local m = {}
  for _, v in ipairs(s) do
    local last = m[#m]
    if last and v[1] <= last[2] + 0.02 then last[2] = max(last[2], v[2]) else m[#m + 1] = { v[1], v[2] } end
  end
  return m
end
-- the worst demand q = M × Leff over the spans and overhangs of one axis.
-- loads = { { F, x, z } … }; W its own weight. → q, Leff
local function axis_demand(e, ex, ez, hl, ivs, loads)
  local a = e.a
  local mg = merged_of(ivs)
  if #mg == 0 then mg = { { -hl, -hl }, { hl, hl } } end
  local w = e.W / max(0.1, 2 * hl)
  local segs = {}
  local function brg(k) return min(mg[k][2] - mg[k][1], 0.3) / 2 end
  if mg[1][1] > -hl + 0.05 then segs[#segs + 1] = { oh = true, lo = -hl, hi = mg[1][1], sb = mg[1][1], M = 0 } end
  for k = 1, #mg - 1 do
    local g0, g1 = mg[k][2], mg[k + 1][1]
    if g1 > g0 + 1e-3 then
      segs[#segs + 1] = { lo = g0, hi = g1, c0 = g0 - brg(k), c1 = g1 + brg(k + 1), M = 0 }
    end
  end
  if mg[#mg][2] < hl - 0.05 then segs[#segs + 1] = { oh = true, lo = mg[#mg][2], hi = hl, sb = mg[#mg][2], M = 0 } end
  for _, L in ipairs(loads) do
    local s = (L[2] - a.x) * ex + (L[3] - a.z) * ez
    for _, sg in ipairs(segs) do
      if s > sg.lo and s < sg.hi then
        if sg.oh then sg.M = sg.M + L[1] * abs(s - sg.sb)
        else sg.M = sg.M + L[1] * (s - sg.c0) * (sg.c1 - s) / (sg.c1 - sg.c0) end
        break
      end
    end
  end
  local q, Le = 0, 0
  for _, sg in ipairs(segs) do
    local L, Lx
    if sg.oh then L = sg.hi - sg.lo; Lx = max(1.0, 2 * L); sg.M = sg.M + w * L * L / 2
    else L = sg.c1 - sg.c0; Lx = max(1.0, L); sg.M = sg.M + w * L * L / 8 end
    local qq = sg.M * Lx
    if qq > q then q, Le = qq, Lx end
  end
  return q, Le
end
-- how a load at s along an axis goes to the bearings: { m|false, frac, … }
local function lever(s, ivs)
  local inside = {}
  for _, v in ipairs(ivs) do if s >= v[1] - 0.01 and s <= v[2] + 0.01 then inside[#inside + 1] = v end end
  if #inside > 0 then
    local o = {}
    for _, v in ipairs(inside) do o[#o + 1] = v[3]; o[#o + 1] = 1 / #inside end
    return o
  end
  local L, R
  for _, v in ipairs(ivs) do
    if v[2] < s and (not L or v[2] > L[2]) then L = v end
    if v[1] > s and (not R or v[1] < R[1]) then R = v end
  end
  if L and R then
    local f = (R[1] - s) / max(1e-6, R[1] - L[2])
    return { L[3], f, R[3], 1 - f }
  end
  local one = L or R
  return one and { one[3], 1 } or {}
end
-- an upright piece's loads to what it stands on, by nearness
local function near_share(x, z, sup)
  local o, tot = {}, 0
  for _, m in ipairs(sup) do
    local _, _, d = clamp_in(m.a, x, z)
    local k = 1 / max(0.05, d)
    o[#o + 1] = m; o[#o + 1] = k
    tot = tot + k
  end
  for i = 2, #o, 2 do o[i] = o[i] / tot end
  return o
end

-- What the live loads do. loads = { { uid, F (kN), x, z (structure frame) } … };
-- opts = { ground = function(e, ex, ez, hl) → { { s0, s1 } … } | nil (all
-- ground), groundAny = function(e) → is there ground anywhere under it,
-- hp = function(uid) → hp }.
-- → res = { [uid] = { r, cap, load, span, kind, off (m, its own sag plus what
-- it rests on), own (its own sag), unheld (laid on the ground by the kit's
-- rule with nothing under it now: it falls) } } for every piece under a live load and
-- what rests on those (off only); stats { nodes }.
function evaluate(rec, defs, KS, loads, opts)
  opts = opts or {}
  local M = model(rec, defs, KS)
  local live = {}
  for _, L in ipairs(loads or {}) do
    local e = M.by[L.uid or L[1]]
    if e then
      live[e] = live[e] or {}
      table.insert(live[e], { L.F or L[2], L.x or L[3], L.z or L[4] })
    end
  end
  -- under the live loads (down), and what rests on any of those (up)
  local D, S, q = {}, {}, {}
  for e in pairs(live) do D[e] = true; q[#q + 1] = e end
  local h = 1
  while h <= #q do
    local e = q[h]; h = h + 1
    for _, m in ipairs(e.sup) do if not D[m] then D[m] = true; q[#q + 1] = m end end
  end
  for e in pairs(D) do S[e] = true end
  q = {}
  for e in pairs(D) do q[#q + 1] = e end
  h = 1
  while h <= #q do
    local e = q[h]; h = h + 1
    for _, n in ipairs(e.dep) do if not S[n] then S[n] = true; q[#q + 1] = n end end
  end
  local list = {}
  for e in pairs(S) do list[#list + 1] = e end
  table.sort(list, function(x, y) return x.ord < y.ord end)
  local inbox = {}       -- e → { { F, x, z } … } handed down to it
  local res, share0 = {}, {}
  for _, e in ipairs(list) do
    local pts = { { e.W, e.a.x, e.a.z } }
    for _, L in ipairs(inbox[e] or {}) do pts[#pts + 1] = L end
    for _, L in ipairs(live[e] or {}) do pts[#pts + 1] = L end
    local hp = opts.hp and opts.hp(e.p.uid) or 1.0
    local r, cap, load, span = 0, math.huge, 0, nil
    local F = 0
    for _, L in ipairs(pts) do F = F + L[1] end
    local route        -- function(x, z) → shares { m|false, frac … }
    local unheld = false
    if e.found or e.hang == nil then
      route = nil
    elseif e.kind == "bend" then
      -- the axis it does best along (a plate spans either way)
      local best
      local bendPts = {}
      for i = 2, #pts do bendPts[#bendPts + 1] = pts[i] end
      for _, ax in ipairs(e.axes) do
        local ex, ez, hl = ax[1], ax[2], ax[3]
        local ivs = bearings(e, ex, ez, hl, opts.ground)
        local qd, Le = axis_demand(e, ex, ez, hl, ivs, bendPts)
        local S0 = strengthOf(e.d) * secOf(e.d) * hp
        local rr = qd / max(1e-9, S0)
        if not best or rr < best.r then best = { r = rr, Le = Le, ivs = ivs, ex = ex, ez = ez } end
      end
      r = best.r
      -- (laid on the ground by the kit's rule, but nothing under it at all now:
      -- the beams it lay on broke, the bank was dug away — it falls)
      if #best.ivs == 0 and e.ygnd and #e.sup == 0 and opts.groundAny and not opts.groundAny(e) then unheld = true end
      span = best.Le > 0 and best.Le or nil
      cap = span and capAt(e.d, span, hp) or math.huge
      load = r * cap
      local ivs, ex, ez, ax, az = best.ivs, best.ex, best.ez, e.a.x, e.a.z
      route = function(x, z) return lever((x - ax) * ex + (z - az) * ez, ivs) end
    else
      cap = axialCap(e.kind, e.d, e.a, hp)
      load = F
      r = F / max(1e-9, cap)
      local sup = e.sup
      route = function(x, z) return near_share(x, z, sup) end
    end
    if D[e] and not e.found and e.hang ~= nil then
      res[e.p.uid] = { r = r, cap = cap, load = load, span = span, kind = e.kind, uid = e.p.uid, e = e, unheld = unheld or nil }
    end
    -- hand the loads down: one point per piece below, at the loads' centroid where they enter it
    if route then
      share0[e] = route(e.a.x, e.a.z)
      local acc = {}
      for _, L in ipairs(pts) do
        local sh = route(L[2], L[3])
        for i = 1, #sh, 2 do
          local m, f = sh[i], sh[i + 1]
          if m and f > 0 and S[m] then
            local cx, cz = clamp_in(m.a, L[2], L[3])
            local A = acc[m]
            if not A then A = { 0, 0, 0 }; acc[m] = A end
            local fF = L[1] * f
            A[1], A[2], A[3] = A[1] + fF, A[2] + fF * cx, A[3] + fF * cz
          end
        end
      end
      for m, A in pairs(acc) do
        if A[1] > 0 then
          inbox[m] = inbox[m] or {}
          table.insert(inbox[m], { A[1], A[2] / A[1], A[3] / A[1] })
        end
      end
    end
  end
  -- the sag shown: its own, plus what it rests on (shared as its centre's load is)
  local off = {}
  for i = #list, 1, -1 do
    local e = list[i]
    local R = res[e.p.uid]
    local own = R and sagOf(R.r, R.span or 2) or 0
    local inh = 0
    local sh = share0[e]
    if sh then for k = 1, #sh, 2 do local m = sh[k]; if m then inh = inh + (off[m] or 0) * sh[k + 1] end end end
    off[e] = own + inh
    if off[e] > 1e-4 or R then
      res[e.p.uid] = res[e.p.uid] or { uid = e.p.uid, e = e, kind = e.kind }
      res[e.p.uid].off = off[e]
      res[e.p.uid].own = own
    end
  end
  return res, { nodes = #list }
end

-- Is a load on this piece one the model has to work out? (not founded)
function loadable(e) return e ~= nil and not e.found and e.hang ~= nil end

-- ── the scene half ──────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end

local CREAKS = { "audio/ambience/cave_creak_1.ogg", "audio/ambience/cave_creak_2.ogg", "audio/ambience/cave_creak_3.ogg" }
local GROANS = { "audio/ambience/cave_groan_1.ogg", "audio/ambience/cave_groan_2.ogg" }
local TICKS = { "audio/kenney/impact/impactWood_light_000.ogg", "audio/kenney/impact/impactWood_light_002.ogg", "audio/kenney/impact/impactWood_light_004.ogg" }
local SNAPS = { "audio/kenney/impact/impactWood_heavy_001.ogg", "audio/kenney/impact/impactWood_heavy_003.ogg" }
local WOOD_COL = { 0.42, 0.30, 0.19 }

local ST_ = {}           -- "sid:uid" → { sid, uid, over, hp, r, next (creak time), tick, cur, tgt, base }
local LAST = {}          -- sid → { t, res, loads }
local GC = {}            -- "sid:uid:ex" → { t, ivs } terrain samples under a piece
local BOUNDS = {}        -- sid → { key, cx, cy, cz (structure frame), R }
local SHAKE = {}         -- sid → { t (until), uids = { [uid] = true } }: looked at after a break
local vlist, vlist_t = {}, -10
local next_t = 0
local sagging = 0
local PROF = { evals = 0, ms = 0, broke = 0, creaks = 0, walker = 0, walkerOn = 0, crafts = 0 }

-- (probes) a craft weighed as if it carried `t` more tonnes: a hopper's load on a test bike
local EXTRA = {}
function addMass(nodeId, t) EXTRA[nodeId] = (t and t ~= 0) and t or nil end
function lastResult(sid) local L = LAST[sid]; return L and L.res or nil, L end
function stateOf(sid, uid) return ST_[tostring(sid) .. ":" .. tostring(uid)] end
function stats() return PROF end

local function key(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
-- kit_snap with its graph kept per structure until structures.version moves
-- (graphOf signs every part each call: a big base walked over at 2 Hz should
-- not pay that while nothing changes)
local GV = setmetatable({}, { __mode = "k" })
local KSP = nil
local function ks()
  local KS = ref("kit_snap")
  if not KS then return nil end
  if not KSP or KSP.base ~= KS then
    KSP = setmetatable({ base = KS }, { __index = KS })
    KSP.graphOf = function(rec, d)
      local ST = ref("structures")
      local v = ST and ST.version
      local c = GV[rec]
      if c and c.v == v and v ~= nil then return c.g end
      local g = KS.graphOf(rec, d)
      GV[rec] = { v = v, g = g }
      return g
    end
  end
  return KSP
end
local function frame_of(rec) local KS = ref("kit_snap"); return KS and KS.frameOf(rec) end
local function to_local(fr, bx, by, bz)
  local dx, dy, dz = bx - fr.O.x, by - fr.O.y, bz - fr.O.z
  return dx * fr.R.x + dy * fr.R.y + dz * fr.R.z, dx * fr.U.x + dy * fr.U.y + dz * fr.U.z, dx * fr.F.x + dy * fr.F.y + dz * fr.F.z
end
local function to_body(fr, lx, ly, lz)
  return fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz, fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
         fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
end

-- a structure's reach (its parts' ground points' sphere, structure frame), kept until its parts change
local function bounds(rec)
  local bp = rec.bp or {}
  local last = bp[#bp]
  local k = #bp .. ":" .. tostring(last and last.uid)
  local b = BOUNDS[rec.id]
  if b and b.key == k and b.rec == rec then return b end
  local sx, sy, sz, n = 0, 0, 0, 0
  for _, p in ipairs(bp) do sx, sy, sz, n = sx + (p.x or 0), sy + (p.y or 0), sz + (p.z or 0), n + 1 end
  n = max(1, n)
  local cx, cy, cz = sx / n, sy / n, sz / n
  local R = 0
  for _, p in ipairs(bp) do R = max(R, sqrt(((p.x or 0) - cx) ^ 2 + ((p.y or 0) - cy) ^ 2 + ((p.z or 0) - cz) ^ 2)) end
  b = { key = k, rec = rec, cx = cx, cy = cy, cz = cz, R = R + 6 }
  BOUNDS[rec.id] = b
  return b
end

-- the terrain under a piece the kit counts as on the ground, sampled along an axis (s from its centre)
local function ground_of(rec, fr, body)
  return function(e, ex, ez, hl)
    local k = key(rec.id, e.p.uid) .. string.format(":%.2f:%.2f", ex, ez)
    local c = GC[k]
    if c and now() - c.t < 2.0 then return c.ivs end
    if not (terrain and terrain.query and body) then return nil end
    local a = e.a
    local n = max(2, math.ceil(2 * hl / GROUND_STEP))
    local step = 2 * hl / n
    local ivs, open = {}, nil
    for i = 0, n do
      local s = -hl + i * step
      local lx, lz = a.x + ex * s, a.z + ez * s
      local bx, by, bz = to_body(fr, lx, a.y0 - 0.02, lz)
      local d = terrain.query(body.x + bx, body.y + by, body.z + bz)
      local held = d == nil or d < 0.12
      if held then
        local s0, s1 = max(-hl, s - step / 2), min(hl, s + step / 2)
        if open and open[2] >= s0 - 1e-6 then open[2] = s1 else open = { s0, s1 }; ivs[#ivs + 1] = open end
      else open = nil end
    end
    GC[k] = { t = now(), ivs = ivs }
    return ivs
  end
end

-- is there ground anywhere under a piece's footprint, within UNHELD_DROP of its underside (a 3 x
-- 3 grid of samples)? (a floor the kit counts as on the ground that stands a little over a slope
-- is not falling: woodprobe's hut floor, 0.3 m over the ground, broke as `unheld` at 0.12)
UNHELD_DROP = 0.5
local function ground_any(rec, fr, body)
  return function(e)
    local k = key(rec.id, e.p.uid) .. ":any"
    local c = GC[k]
    if c and now() - c.t < 2.0 then return c.any end
    if not (terrain and terrain.query and body) then return true end
    local a = e.a
    local Xx, Xz, Zx, Zz = rect_axes(a)
    local any = false
    for _, u in ipairs({ -0.85, 0, 0.85 }) do
      for _, v in ipairs({ -0.85, 0, 0.85 }) do
        local lx, lz = a.x + Xx * u * a.hx + Zx * v * a.hz, a.z + Xz * u * a.hx + Zz * v * a.hz
        local bx, by, bz = to_body(fr, lx, a.y0 - 0.02, lz)
        local d = terrain.query(body.x + bx, body.y + by, body.z + bz)
        if d == nil or d < UNHELD_DROP then any = true break end
      end
      if any then break end
    end
    GC[k] = { t = now(), any = any }
    return any
  end
end

local function hp_of(sid, uid)
  local LZ = ref("lasers")
  if LZ and LZ.hpOf then return LZ.hpOf(sid, uid) end
  local ST = ref("structures")
  local st = ST and ST.partState and ST.partState(sid, uid) or {}
  return tonumber(st.hp) or 1.0
end
local function hp_write(sid, uid, hp)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return end
  local t = {}
  for a, b in pairs(ST.partState(sid, uid) or {}) do t[a] = b end
  t.hp = floor(hp * 1e4 + 0.5) / 1e4
  ST.setPartState(sid, uid, t)
end

local function play(list, x, y, z, vol, pitch, maxd)
  if not (audio and audio.play) then return end
  local clip = list[math.random(#list)]
  pcall(audio.play, clip, x, y, z, { track = "SFX", volume = vol or 1, pitch = pitch or 1, mode = "Spatial", falloff = "Inverse",
                                     minDistance = 4, maxDistance = maxd or 70 })
end
-- a piece's centre, this frame's world point
local function world_of(rec, e)
  local fr = frame_of(rec)
  local b = space and space.body and space.body(rec.b)
  if not (fr and b) then return nil end
  local bx, by, bz = to_body(fr, e.a.x, (e.a.y0 + e.a.y1) / 2, e.a.z)
  return b.x + bx, b.y + by, b.z + bz, fr
end

-- the piece breaks: what it held comes down with it
local function break_piece(rec, e)
  local ST, KS, SN = ref("structures"), ref("kit_snap"), ref("base_snap")
  if not (ST and KS) then return end
  local uid = e.p.uid
  local uids = { uid }
  if SN and SN.dependents then
    local ok, list = pcall(SN.dependents, rec, defs, uid)
    if ok then for _, u in ipairs(list or {}) do uids[#uids + 1] = u end end
  end
  local ok, more = pcall(KS.fallsWith, rec, defs, uids)
  if ok then for _, u in ipairs(more or {}) do uids[#uids + 1] = u end end
  local x, y, z, fr = world_of(rec, e)
  -- (what rested on it is looked at for the next few seconds with no load of
  -- its own: a deck laid on the ground by the kit's rule, over a gap, falls)
  local gone = {}
  for _, u in ipairs(uids) do gone[u] = true end
  local sh = SHAKE[rec.id] or { uids = {} }
  sh.t = now() + 3.0
  local function near_of(n) for _, m in ipairs(n.dep) do if not gone[m.p.uid] then sh.uids[m.p.uid] = true end end end
  near_of(e)
  for _, s2 in ipairs(e.sup) do if not gone[s2.p.uid] then sh.uids[s2.p.uid] = true end; near_of(s2) end
  SHAKE[rec.id] = sh
  ST.removeParts(rec.id, uids)
  for _, u in ipairs(uids) do ST_[key(rec.id, u)] = nil end
  PROF.broke = PROF.broke + 1
  if x then
    local wood = e.d.mat == "wood"
    play(SNAPS, x, y, z, 1.0, wood and 0.85 or 0.55, 220)
    play(wood and CREAKS or GROANS, x, y, z, 0.9, wood and 0.5 or 0.6, 160)
    local LZ = ref("lasers")
    if LZ and LZ.throwChunks then
      local n = max(4, min(12, floor((e.d.mass or 0.1) * 30)))
      pcall(LZ.throwChunks, x, y, z, fr.U.x, fr.U.y, fr.U.z, n, wood and WOOD_COL or nil)
    end
  end
  if log then log(string.format("kit_load: %s (%s:%s) broke under its load; %d piece(s) down", tostring(e.d.label), tostring(rec.id), tostring(uid), #uids)) end
end

-- the live loads now: walkers on foot and craft, on the structures near them
local function gather(recs)
  local out = {}      -- sid → { rec, loads = { … }, fr, body }
  local bodies = {}
  local function body_of(name)
    local b = bodies[name]
    if b == nil then b = space and space.body and space.body(name) or false; bodies[name] = b end
    return b or nil
  end
  local KS = ks()
  local function drop(w, F, reach)
    for _, R in ipairs(recs) do
      local b = body_of(R.rec.b)
      if b then
        local bx, by, bz = w.x - b.x, w.y - b.y, w.z - b.z
        local lx, ly, lz = to_local(R.fr, bx, by, bz)
        if (lx - R.bd.cx) ^ 2 + (ly - R.bd.cy) ^ 2 + (lz - R.bd.cz) ^ 2 <= R.bd.R * R.bd.R then
          local e, hit = pieceUnder(R.rec, defs, KS, lx, ly, lz, reach)
          if hit then
            if e and loadable(e) then
              local o = out[R.rec.id]
              if not o then o = { rec = R.rec, fr = R.fr, body = b, loads = {} }; out[R.rec.id] = o end
              o.loads[#o.loads + 1] = { uid = e.p.uid, F = F, x = lx, z = lz }
            end
            return true
          end
        end
      end
    end
    return false
  end
  -- the walker on foot (a fresh handle: its drawn place, against this pass's body)
  local pw = ref("planet_walker")
  if pw and pw.onFoot and find then
    local a = find("Astronaut")
    if valid(a) then
      local hit = drop(a.worldPos or { x = a.x, y = a.y, z = a.z }, WALKER_KN, 1.6)
      PROF.walker = PROF.walker + 1
      if hit then PROF.walkerOn = PROF.walkerOn + 1 end
    end
  end
  -- craft: their weight over the tyres down (or their lowest parts)
  if now() - vlist_t > 2.0 then vlist_t = now(); vlist = findScripts and findScripts("vessel_controller") or {} end
  for _, v in ipairs(vlist) do
    local vn = v.node
    if valid(vn) and not v.structureMode and not v.standHeld and not v.destroyed then
      local w0 = vn.worldPos
      local near = false
      for _, R in ipairs(recs) do
        local b = body_of(R.rec.b)
        if b and w0 then
          local lx, ly, lz = to_local(R.fr, w0.x - b.x, w0.y - b.y, w0.z - b.z)
          if (lx - R.bd.cx) ^ 2 + (ly - R.bd.cy) ^ 2 + (lz - R.bd.cz) ^ 2 <= (R.bd.R + 12) ^ 2 then near = true break end
        end
      end
      local info = near and assembly and assembly.info and assembly.info(vn)
      if info and not info.anchored then
        local mass = info.mass or 0
        if v.trueMass then local ok, _, wet = pcall(v.trueMass); if ok and wet then mass = wet end end
        mass = mass + (EXTRA[vn.id] or 0)
        local pts, reach = {}, 1.2
        local wheels = v.R2 and v.R2.wheels or {}
        for _, wh in ipairs(wheels) do
          if wh.down and valid(wh.tyre) then pts[#pts + 1] = wh.tyre:toWorld(vec3(0, 0, 0)) end
        end
        if #pts == 0 and v.aboardRecs and v.partPointNow then
          -- (legs and skids, or tyres stowed on a parked craft: the parts lowest along the local
          -- up, each a short reach over a piece's top; a craft in the air is over nothing that near)
          reach = 1.2
          local b = body_of(recs[1].rec.b)
          local all, lo = {}, 1e18
          local n = 0
          for u in pairs(v.aboardRecs() or {}) do
            n = n + 1
            if n > 120 then break end
            local x, y, z = v.partPointNow(u, 0, 0, 0, true)
            if x and b then
              local dx, dy, dz = x - b.x, y - b.y, z - b.z
              local h = sqrt(dx * dx + dy * dy + dz * dz)
              all[#all + 1] = { x = x, y = y, z = z, h = h }
              lo = min(lo, h)
            end
          end
          for _, q in ipairs(all) do if q.h <= lo + 0.4 then pts[#pts + 1] = q end end
        end
        local F = G * mass / max(1, #pts)
        local on = false
        for _, w in ipairs(pts) do if drop(w, F, reach) then on = true end end
        if on then PROF.crafts = PROF.crafts + 1; PROF.craftT = mass; PROF.craftPts = #pts end
      end
    end
  end
  return out
end

SAG_KIDS = { "Mesh", "Door", "Door2" }
local function sag_apply(dt)
  local ST, PB = ref("structures"), ref("parts_base")
  if not ST then return end
  local live = 0
  local k = 1 - math.exp(-6 * (dt or 0.016))
  for kk, s in pairs(ST_) do
    local tgt = s.tgt or 0
    local cur = s.cur or 0
    if abs(cur - tgt) > 1e-4 or (cur ~= 0 and tgt == 0) then
      cur = cur + (tgt - cur) * k
      if tgt == 0 and abs(cur) < 5e-4 then cur = 0 end
      s.cur = cur
      -- (only what is DRAWN drops: the piece's Mesh (and a door's leaves) inside its node,
      -- along the node's own up. Its colliders stay where they are: moving a static body
      -- each frame under a rolling tyre threw the probe's motorcycle off the bridge's end.)
      local n = ST.nodeOf(s.sid, s.uid)
      if valid(n) then
        if s.node ~= n then s.node, s.vis = n, {} end
        for _, nm in ipairs(SAG_KIDS) do
          local okc, c = pcall(n.getChild, n, nm)
          if okc and valid(c) then
            local y0 = s.vis[nm]
            if y0 == nil then y0 = c.y; s.vis[nm] = y0 end
            c.y = y0 - cur
          end
        end
      end
      live = live + 1
    end
    if cur == 0 and tgt == 0 and (s.over or 0) == 0 and not s.r then ST_[kk] = nil end
  end
  sagging = live
end

function evaluateNow()
  local ST, KS = ref("structures"), ks()
  if not (ST and KS and ST.count and ST.count() > 0) then return end
  local t0 = os and os.clock and os.clock() or 0
  local recs = {}
  for _, rec in ipairs(ST.list()) do
    if not ST.suspended or not ST.suspended(rec.id) then
      local fr = KS.frameOf(rec)
      recs[#recs + 1] = { rec = rec, fr = fr, bd = bounds(rec) }
    end
  end
  if #recs == 0 then return end
  local loaded = gather(recs)
  -- (after a break: what was round it, with no load of its own)
  for sid, sh in pairs(SHAKE) do
    local rec = ST.get(sid)
    if not rec or now() > sh.t then SHAKE[sid] = nil
    else
      local o = loaded[sid]
      if not o then
        local b = space and space.body and space.body(rec.b)
        o = { rec = rec, fr = KS.frameOf(rec), body = b, loads = {} }
        loaded[sid] = o
      end
      local M = model(rec, defs, KS)
      for u in pairs(sh.uids) do
        local e = M.by[u]
        if e and loadable(e) then o.loads[#o.loads + 1] = { uid = u, F = 0, x = e.a.x, z = e.a.z } end
      end
    end
  end
  local seen = {}
  local t = now()
  for sid, o in pairs(loaded) do
    PROF.evals = PROF.evals + 1
    local rec = o.rec
    local res = evaluate(rec, defs, KS, o.loads, { ground = ground_of(rec, o.fr, o.body), groundAny = ground_any(rec, o.fr, o.body),
                                                  hp = function(u) return hp_of(sid, u) end })
    LAST[sid] = { t = t, res = res, loads = o.loads }
    local snd = 0
    local broke = {}
    -- (the loudest few creak: sorted by r)
    local order = {}
    for uid, R in pairs(res) do order[#order + 1] = R end
    table.sort(order, function(a, b) return (a.r or 0) > (b.r or 0) end)
    for _, R in ipairs(order) do
      local uid = R.uid
      local kk = key(sid, uid)
      seen[kk] = true
      local s = ST_[kk]
      if not s and ((R.r or 0) > CREAK_R or (R.off or 0) > 1e-4) then s = { sid = sid, uid = uid }; ST_[kk] = s end
      if s then
        s.r = R.r
        s.tgt = R.off or 0
        if R.unheld then
          broke[#broke + 1] = R.e
        elseif R.r then
          local hp0 = hp_of(sid, uid)
          s.hp = hp0
          local hp, gone = stepHp(s, R.r, EVERY)
          if hp < hp0 - 1e-6 then
            if gone then broke[#broke + 1] = R.e
            elseif floor(hp * 50) ~= floor((s.hpw or hp0) * 50) then hp_write(sid, uid, hp); s.hpw = hp end
          end
          local iv, vol = creakOf(R.r)
          if iv and snd < 3 and t >= (s.next or 0) then
            local x, y, z = world_of(rec, R.e)
            if x then
              local wood = R.e.d.mat == "wood"
              play(wood and CREAKS or GROANS, x, y, z, vol, (wood and 0.62 or 0.5) + math.random() * 0.12, 70)
              PROF.creaks = PROF.creaks + 1
              if (s.over or 0) >= BREAK_HOLD then play(TICKS, x, y, z, 0.5 + 0.3 * math.random(), 0.8 + math.random() * 0.3, 40) end
            end
            snd = snd + 1
            s.next = t + iv * (0.8 + 0.4 * math.random())
          end
        end
      end
    end
    for _, e in ipairs(broke) do
      local cur = ST.get(sid)
      if cur and ST.getPart(sid, e.p.uid) then break_piece(cur, e) end
    end
  end
  -- what nothing is on any more: back up (a piece that held keeps what hp it lost)
  for kk, s in pairs(ST_) do
    -- (a tick with nothing on it — a parked craft's tyres stowing, a walker's hop — runs the
    -- 2 s down rather than restarting it)
    if not seen[kk] then s.r = nil; s.tgt = 0; s.over = max(0, (s.over or 0) - EVERY) end
  end
  local dt_ms = ((os and os.clock and os.clock() or 0) - t0) * 1000
  PROF.ms = PROF.ms + dt_ms
end

function start(node)
  next_t = 0
end

function update(node, dt)
  local t = now()
  if next(ST_) ~= nil then sag_apply(dt) end
  if t < next_t then return end
  next_t = t + EVERY
  local ok, err = pcall(evaluateNow)
  if not ok then
    PROF.errors = (PROF.errors or 0) + 1
    PROF.lastError = tostring(err)
    if t - (PROF.errT or -1e9) > 10 then
      PROF.errT = t
      if log then log("kit_load: " .. tostring(err)) end
      if print then print("kit_load: " .. tostring(err)) end
    end
  end
end
