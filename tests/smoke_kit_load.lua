-- SMOKE: what a Build Kit piece carries (progression W2; work/progression/
-- PLAN.md §3.4; docs/base-building.md §37). Ty 11-11 on wood: "on the home
-- planet they'll last forever essentially, just not handle crazy heavy
-- weights."
--
--   * the capacity formula: cap = S × sec × (2/L)² (a 6 m span a ninth of a
--     2 m one), posts, walls;
--   * a 4 m timber beam on two posts: 500 kg at its middle holds, 600 kg is
--     about its limit, 1.5 t breaks it; steel holds 6 t; cap × hp;
--   * load sums: a deck on two beams hands half of a central load to each;
--     a post under a beam carries half the beam and half the load;
--   * the probe's bridge: two 6 m beams laid across a 5.2 m gap (the terrain
--     sampled), three decks, fences: the motorcycle (0.3 t) loads it well up
--     and holds, a 450 kg quad creaks, an 850 kg rover and a 1.5 t hopper break it; the empty bridge is quiet; at the bank the
--     load goes to the ground;
--   * sag and break thresholds: sag from r 0.7 to its most at 1.3, creaks,
--     2 s over 1.0 before hp falls 0.15/s;
--   * steel never sags in a normal base: slabs, walls, a second storey with a
--     cantilevered floor, crew at the worst places and a rover upstairs;
--   * founded pieces (on the ground) carry anything; only pieces under a
--     live load are worked out.
--
--   luajit solar/tests/smoke_kit_load.lua

local failures, passed = {}, 0
local VERBOSE = os.getenv("SMOKE_VERBOSE") ~= nil
local function check(ok, msg)
  if VERBOSE then print((ok and "  ok   " or "  FAIL ") .. msg) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local S = {}
local function env()
  return setmetatable({
    time = 1.0,
    save = { get = function() return nil end, set = function() end, delete = function() end },
    findScript = function(k) return S[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
end
local function load(path)
  local E = env()
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end
S.materials = load("materials.lua")
S.parts_kit = load("parts_kit.lua")
local PB = load("parts_base.lua"); S.parts_base = PB
local KS = load("kit_snap.lua"); S.kit_snap = KS
local KL = load("kit_load.lua")
local defs = function(id) return PB.partInfo(id) end

local uid = 0
local function part(id, x, y, z, yaw, extra)
  uid = uid + 1
  local p = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0 }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end
local function rec_of(bp) return { id = 1, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp } end
local function find_uid(rec, id, n)
  local k = 0
  for _, p in ipairs(rec.bp) do if p.id == id then k = k + 1; if k == (n or 1) then return p.uid end end end
end
local G = 9.81

-- ── the formula ─────────────────────────────────────────────────────────────
local b4w, b4s, b6w = defs("beam4.wood"), defs("beam4.steel"), defs("beam6w.wood")
check(b4w and b4s and b6w, "beam4.wood, beam4.steel and beam6w.wood resolve")
check(math.abs(KL.capAt(b4w, 4) - 6.0) < 1e-9, string.format("a 4 m timber beam's mid-span cap is 6 kN (%.2f)", KL.capAt(b4w, 4)))
check(math.abs(KL.capAt(b6w, 6) * 9 - KL.capAt(b6w, 2)) < 1e-9, "a 6 m span carries a ninth of a 2 m one")
check(math.abs(KL.capAt(b4w, 4, 0.5) - 3.0) < 1e-9, "cap × hp: a half-cracked beam carries half")
check(KL.capAt(b4s, 4) >= 10 * KL.capAt(b4w, 4), string.format("steel's beam is 10x+ timber's (%.0f vs %.0f kN)", KL.capAt(b4s, 4), KL.capAt(b4w, 4)))
check(KL.kindOf({ pitch = 0 }, defs("post3.wood")) == "post" and KL.kindOf({ pitch = 0 }, defs("wall.wood")) == "wall"
  and KL.kindOf({ pitch = 0 }, b4w) == "bend" and KL.kindOf({ pitch = math.pi / 2 }, defs("pillar2.steel")) == "bend",
  "kinds: a post, a wall, a beam bends, a post laid flat bends")

-- ── a 4 m timber beam on two log posts ───────────────────────────────────────
-- (the posts are piles: founded; the beam rests on their tops, 0.3 m bearings at its ends)
local function beam_on_posts(beam)
  uid = 0
  return rec_of({
    part("post3.wood", -1.85, 0, 0, 0, { gnd = true }),
    part("post3.wood", 1.85, 0, 0, 0, { gnd = true }),
    part(beam, 0, 3.0, 0, 0),
  })
end
local function r_at(rec, id, kg, x)
  local u = find_uid(rec, id)
  local res = KL.evaluate(rec, defs, KS, { { uid = u, F = G * kg / 1000, x = x or 0, z = 0 } })
  return res[u] and res[u].r or -1, res
end
do
  local R = beam_on_posts("beam4.wood")
  local r150, r500, r600, r1500 = r_at(R, "beam4.wood", 150), r_at(R, "beam4.wood", 500), r_at(R, "beam4.wood", 600), r_at(R, "beam4.wood", 1500)
  check(r150 < KL.CREAK_R, string.format("a 4 m timber beam: a 150 kg bike at mid-span is quiet (r %.2f)", r150))
  check(r500 > 0.6 and r500 < 1.0, string.format("500 kg at mid-span holds (r %.2f)", r500))
  check(r600 > 0.9 and r600 < 1.15, string.format("600 kg is about its limit (r %.2f)", r600))
  check(r1500 > 1.8, string.format("1.5 t breaks it (r %.2f)", r1500))
  local rEnd = r_at(R, "beam4.wood", 1500, 1.85)
  check(rEnd < 0.3, string.format("1.5 t right over a post bends nothing (r %.2f)", rEnd))
  local _, res = r_at(R, "beam4.wood", 500)
  local u = find_uid(R, "beam4.wood")
  check(res[u].span and math.abs(res[u].span - 3.7) < 0.05, string.format("its span is bearing to bearing (%.2f m)", res[u].span or -1))
  check(math.abs(res[u].cap - KL.capAt(b4w, res[u].span)) < 1e-9 and math.abs(res[u].load - res[u].r * res[u].cap) < 1e-9, "LOAD and CAP read r × cap / cap")
  check(res[find_uid(R, "post3.wood")] == nil, "the founded posts are not worked out (they carry anything)")
  -- cap × hp in the evaluation
  local res2 = KL.evaluate(R, defs, KS, { { uid = u, F = G * 0.5, x = 0, z = 0 } }, { hp = function() return 0.5 end })
  check(math.abs(res2[u].r - 2 * res[u].r) < 1e-9, string.format("hp 0.5 doubles r (%.2f → %.2f)", res[u].r, res2[u].r))
  local RS = beam_on_posts("beam4.steel")
  local r6t = r_at(RS, "beam4.steel", 6000)
  check(r6t < 1.0, string.format("a 4 m steel beam holds 6 t at mid-span (r %.2f)", r6t))
end

-- ── load sums: a deck on two beams, the beams on posts on a slab ─────────────
do
  uid = 0
  local bp = {
    part("slab2.concrete", -1.85, 0, -0.8), part("slab2.concrete", 1.85, 0, -0.8),
    part("slab2.concrete", -1.85, 0, 0.8), part("slab2.concrete", 1.85, 0, 0.8),
  }
  -- posts standing on the slabs (not piles: they carry by their own cap)
  for _, x in ipairs({ -1.85, 1.85 }) do
    for _, z in ipairs({ -0.8, 0.8 }) do bp[#bp + 1] = part("post3.wood", x, 0.2, z) end
  end
  bp[#bp + 1] = part("beam4.wood", 0, 3.2, -0.8)
  bp[#bp + 1] = part("beam4.wood", 0, 3.2, 0.8)
  bp[#bp + 1] = part("deck24.wood", 0, 3.6, 0, 0)     -- 2 wide (x), 4 long (z): across both beams
  local R = rec_of(bp)
  local deck = find_uid(R, "deck24.wood")
  local F = 4.0
  local res = KL.evaluate(R, defs, KS, { { uid = deck, F = F, x = 0, z = 0 } })
  local b1, b2 = find_uid(R, "beam4.wood", 1), find_uid(R, "beam4.wood", 2)
  check(res[b1] and res[b2] and math.abs(res[b1].r - res[b2].r) < 1e-9, "a central load on the deck: both beams alike")
  local Wb, Wd, Wp = G * defs("beam4.wood").mass, G * defs("deck24.wood").mass, G * defs("post3.wood").mass
  local postSum = 0
  for _, p in ipairs(R.bp) do if p.id == "post3.wood" then postSum = postSum + ((res[p.uid] and res[p.uid].load) or 0) end end
  local want = F + Wd + 2 * Wb + 4 * Wp
  check(math.abs(postSum - want) < 1e-6, string.format("the four posts carry the load, the deck, the beams and themselves (%.3f of %.3f kN)", postSum, want))
  local p1 = res[find_uid(R, "post3.wood", 1)]
  check(p1 and math.abs(p1.load - want / 4) < 1e-6, string.format("each post a quarter (%.3f kN)", p1 and p1.load or -1))
  check(res[find_uid(R, "slab2.concrete")] == nil, "the slabs on the ground are founded")
  -- off to one side: the near beam takes more
  local res2 = KL.evaluate(R, defs, KS, { { uid = deck, F = F, x = 0, z = 0.6 } })
  check(res2[b2].r > res2[b1].r, string.format("a load over the +z beam loads it more (%.2f > %.2f)", res2[b2].r, res2[b1].r))
end

-- ── the probe's bridge: 6 m beams across a 5.2 m gap ────────────────────────
local function bridge()
  uid = 0
  local bp = {}
  for _, x in ipairs({ -0.8, 0.8 }) do bp[#bp + 1] = part("beam6w.wood", x, -0.3, 0, math.pi / 2) end
  for _, z in ipairs({ -2, 0, 2 }) do bp[#bp + 1] = part("deck24.wood", 0, 0, z, math.pi / 2) end
  for _, x in ipairs({ -1.95, 1.95 }) do
    for _, z in ipairs({ -2, 0, 2 }) do bp[#bp + 1] = part("fence.wood", x, 0.1, z, x < 0 and -math.pi / 2 or math.pi / 2) end
  end
  for _, c in ipairs({ { -2.25, -3.1 }, { 2.25, -3.1 }, { -2.25, 3.1 }, { 2.25, 3.1 } }) do bp[#bp + 1] = part("post3.wood", c[1], 0, c[2], 0, { gnd = true }) end
  return rec_of(bp)
end
-- the terrain: ground everywhere but the gap |z| < GAP (sampled every 0.5 m, as the driver does)
-- (the gap: the probe digs it 5.2 m across at the surface, wider than the 4.4 m of its dig plan)
GAP = 2.4
local function gap_ground(e, ex, ez, hl)
  local a = e.a
  local n = math.max(2, math.ceil(2 * hl / 0.5))
  local step = 2 * hl / n
  local ivs, open = {}, nil
  for i = 0, n do
    local s = -hl + i * step
    local z = a.z + ez * s
    if math.abs(z) >= GAP then
      local s0, s1 = math.max(-hl, s - step / 2), math.min(hl, s + step / 2)
      if open and open[2] >= s0 - 1e-6 then open[2] = s1 else open = { s0, s1 }; ivs[#ivs + 1] = open end
    else open = nil end
  end
  return ivs
end
do
  local R = bridge()
  local deck = find_uid(R, "deck24.wood", 2)
  local b1, b2 = find_uid(R, "beam6w.wood", 1), find_uid(R, "beam6w.wood", 2)
  local function ride(kg, z)
    local F = G * kg / 1000 / 2
    local loads = {}
    for _, wz in ipairs({ z - 0.78, z + 0.78 }) do
      local dk = math.abs(wz) < 1 and deck or find_uid(R, "deck24.wood", wz < 0 and 1 or 3)
      loads[#loads + 1] = { uid = dk, F = F, x = 0, z = wz }
    end
    return KL.evaluate(R, defs, KS, loads, { ground = gap_ground })
  end
  local walker = KL.evaluate(R, defs, KS, { { uid = deck, F = KL.WALKER_KN, x = 0.3, z = 0 } }, { ground = gap_ground })
  check(walker[b1].r < KL.CREAK_R and walker[b2].r < KL.CREAK_R, string.format("a walker at mid-span: quiet (r %.2f / %.2f)", walker[b1].r, walker[b2].r))
  local bike = ride(300, 0)
  local rb = math.max(bike[b1].r, bike[b2].r)
  check(rb > 0.55 and rb < KL.BREAK_R and rb > walker[b1].r + 0.1, string.format("the motorcycle (0.3 t) at mid-span loads it well up and holds (r %.2f; in the probe's wider dug gap it creaks: woodprobe)", rb))
  check(math.abs(bike[b1].span - 4.8) < 0.3, string.format("the beam spans the gap, bank to bank (%.2f m)", bike[b1].span))
  check(bike[deck].r < 0.3, string.format("the deck under it carries it easily (r %.2f)", bike[deck].r))
  local heavy = ride(450, 0)
  local rh = math.max(heavy[b1].r, heavy[b2].r)
  check(rh > KL.CREAK_R and rh < KL.BREAK_R, string.format("a 450 kg quad: it creaks and holds (r %.2f)", rh))
  check(heavy[b1].off > 0 and heavy[deck].off >= heavy[b1].off * 0.99, string.format("the beam sags (%.1f cm) and the deck rides down with it (%.1f cm)", heavy[b1].off * 100, heavy[deck].off * 100))
  local hop = ride(1500, 0)
  check(math.max(hop[b1].r, hop[b2].r) > 1.4, string.format("a fuelled hopper (1.5 t) at mid-span breaks it (r %.2f)", math.max(hop[b1].r, hop[b2].r)))
  local rover = ride(850, 0)
  check(math.max(rover[b1].r, rover[b2].r) > KL.BREAK_R, string.format("an 850 kg rover is over it (r %.2f)", math.max(rover[b1].r, rover[b2].r)))
  -- on the bank: the ground takes it
  local bank = KL.evaluate(R, defs, KS, { { uid = find_uid(R, "deck24.wood", 3), F = G * 1.5, x = 0, z = 2.6 } }, { ground = gap_ground })
  check(bank[b1].r < KL.CREAK_R, string.format("1.5 t over the far bank bends nothing much (r %.2f)", bank[b1].r))
  -- with no terrain function the kit's ground rule stands: the beams on the ground carry anything
  local flat = KL.evaluate(R, defs, KS, { { uid = deck, F = G * 1.5, x = 0, z = 0 } })
  check(flat[b1].r < 0.05, string.format("on unbroken ground (no gap) nothing bends (r %.3f)", flat[b1].r))
  -- one beam gone: what it held falls only if nothing else holds it (kit_snap.fallsWith)
  local falls = KS.fallsWith(R, defs, { b1, b2 })
  check(#falls == 0, string.format("the decks also lie on the banks: both beams gone, %d fall (the ground rule)", #falls))
  -- …so the load model drops them: with the beams gone, the middle deck has nothing under it
  local R2 = bridge()
  local keep = {}
  for _, p in ipairs(R2.bp) do if p.id ~= "beam6w.wood" then keep[#keep + 1] = p end end
  R2.bp = keep
  local mid = find_uid(R2, "deck24.wood", 2)
  local function any_ground(e) return math.abs(e.a.z) + e.a.hx >= GAP end   -- (the deck's footprint reaches a bank?)
  local un = KL.evaluate(R2, defs, KS, { { uid = mid, F = 0, x = 0, z = 0 } }, { ground = gap_ground, groundAny = any_ground })
  check(un[mid] and un[mid].unheld, "the beams gone, the middle deck over the gap is unheld: it falls")
  local side = find_uid(R2, "deck24.wood", 3)
  local un2 = KL.evaluate(R2, defs, KS, { { uid = side, F = 0, x = 0, z = 2 } }, { ground = gap_ground, groundAny = any_ground })
  check(un2[side] and not un2[side].unheld, "a deck with an end on the bank stays")
end

-- ── sag, creak, break ───────────────────────────────────────────────────────
check(KL.sagOf(0.69, 6) == 0 and KL.sagOf(0.7, 6) == 0, "no sag up to r 0.7")
check(math.abs(KL.sagOf(1.3, 6) - 0.12) < 1e-9 and math.abs(KL.sagOf(1.0, 6) - 0.06) < 1e-9, "sag 6 cm at r 1.0 on 6 m, 12 cm (its most) at 1.3")
check(math.abs(KL.sagOf(2.0, 3) - 0.06) < 1e-9, "a short span sags less (2 % of it)")
check(KL.creakOf(0.69) == nil and KL.creakOf(0.75) ~= nil, "a creak above r 0.7")
do
  local i1, v1 = KL.creakOf(0.75)
  local i2, v2 = KL.creakOf(1.2)
  check(i2 < i1 and v2 > v1, "creaks come faster and louder as r rises")
end
do
  local st = {}
  local t, hp, broke = 0, 1, false
  while t < 1.4 do hp, broke = KL.stepHp(st, 1.2, 0.5); t = t + 0.5 end
  check(hp == 1 and not broke, "under 2 s over r 1.0: nothing yet")
  local _ = KL.stepHp(st, 1.2, 0.5)
  hp = KL.stepHp(st, 1.2, 1.0)
  check(math.abs(hp - 0.85) < 1e-9 or math.abs(hp - 0.775) < 1e-9, string.format("then hp falls 0.15/s (%.3f)", hp))
  local st2 = { hp = 0.6 }
  KL.stepHp(st2, 1.2, 1.5)
  KL.stepHp(st2, 0.9, 0.5)
  hp = KL.stepHp(st2, 1.2, 1.5)
  check(hp == 0.6, "dropping under 1.0 resets the 2 s (and keeps what was lost)")
  local st3, n = {}, 0
  repeat hp, broke = KL.stepHp(st3, 1.5, 0.5); n = n + 1 until broke or n > 100
  check(broke and n * 0.5 > 8 and n * 0.5 < 9.5, string.format("held over 1.0, it breaks in ~8.7 s (%.1f)", n * 0.5))
end

-- ── steel never sags in a normal base ───────────────────────────────────────
do
  uid = 0
  local bp = {}
  for i = -2, 2 do
    for k = -1, 1 do bp[#bp + 1] = part("slab2.steel" == "" and "" or "slab2.concrete", i * 2, 0, k * 2) end
  end
  -- two long walls (z = ±1 on the slab edges) and an end wall, a second floor on them,
  -- and floors cantilevered 2 m out past the z = +1 wall (the kit's MAX_HANG)
  for i = -2, 2 do
    bp[#bp + 1] = part("wall.steel", i * 2, 0.2, -1, 0)
    bp[#bp + 1] = part("wall.steel", i * 2, 0.2, 1, 0)
  end
  for i = -2, 2 do bp[#bp + 1] = part("floor.steel", i * 2, 0.2 + 2.2, 0, 0) end
  for i = -2, 2 do bp[#bp + 1] = part("floor.steel", i * 2, 0.2 + 2.2, 2, 0) end
  -- a pillar-and-beam porch: steel pillars on the slabs, a 4 m beam across them
  bp[#bp + 1] = part("pillar2.steel", -1.85, 0.2, -3)
  bp[#bp + 1] = part("pillar2.steel", 1.85, 0.2, -3)
  bp[#bp + 1] = part("beam4.steel", 0, 2.4, -3)
  local R = rec_of(bp)
  local loads = {}
  local function on(id, n, F, x, z) loads[#loads + 1] = { uid = find_uid(R, id, n), F = F, x = x, z = z } end
  for n = 1, 5 do on("floor.steel", n, 1.0, (n - 3) * 2, 0) end            -- a walker mid-room upstairs
  for n = 6, 10 do on("floor.steel", n, 1.0, (n - 8) * 2, 2.9) end         -- one at each cantilever's tip
  on("floor.steel", 3, G * 0.6, 0, 0.1)                                    -- a 600 kg rover upstairs
  on("beam4.steel", 1, G * 1.0, 0, -3)                                     -- a tonne on the porch beam
  local res = KL.evaluate(R, defs, KS, loads)
  local worst, wid = 0, "-"
  for _, Rr in pairs(res) do if (Rr.r or 0) > worst then worst, wid = Rr.r, Rr.e.d.piece end end
  check(worst < 0.5, string.format("a steel base under crew, a rover and a tonne: worst r %.2f (%s) — never sags", worst, wid))
  local sag = 0
  for _, Rr in pairs(res) do sag = math.max(sag, Rr.off or 0) end
  check(sag == 0, "nothing in it sags")
  -- the empty structure: nothing worked out
  local res0, st0 = KL.evaluate(R, defs, KS, {})
  check(next(res0) == nil and st0.nodes == 0, "no live load: no piece is worked out")
end

-- ── timber hut on the ground: a walker inside is on founded floors ──────────
do
  uid = 0
  local bp = {}
  for _, s in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do bp[#bp + 1] = part("plankFloor.wood", s[1], 0, s[2]) end
  bp[#bp + 1] = part("wall.wood", -1, 0.08, -2, math.pi)
  bp[#bp + 1] = part("wall.wood", 1, 0.08, -2, math.pi)
  local R = rec_of(bp)
  local M = KL.model(R, defs, KS)
  local fl = M.by[find_uid(R, "plankFloor.wood")]
  check(fl and fl.ygnd and not fl.found, "a plank floor laid on the ground bends only where the ground is not under it")
  local res = KL.evaluate(R, defs, KS, { { uid = fl.p.uid, F = 1, x = -1, z = -1 } })
  check(res[fl.p.uid].r < 0.01, "a walker on it (the ground all under it): r 0")
  local e = KL.pieceUnder(R, defs, KS, -1, 1.0, -1, 1.6)
  check(e == fl, "pieceUnder: the walker's centre 1 m over the floor finds the floor")
  local w = KL.pieceUnder(R, defs, KS, -1, 3.2, -2, 1.6)
  check(w and w.p.id == "wall.wood", "a point 0.9 m over a wall's top finds the wall")
  check(KL.pieceUnder(R, defs, KS, -1, 4.0, -1, 1.6) == nil, "out of reach: nothing")
  check(w and #w.sup >= 1 and w.sup[1].p.id == "plankFloor.wood", "the wall stands on the floor (what it rests on)")
  local res2 = KL.evaluate(R, defs, KS, { { uid = w.p.uid, F = 1, x = -1, z = -2 } })
  check(res2[w.p.uid].r < 0.05 and res2[fl.p.uid] ~= nil, "a load on the wall goes down into the floor, then the ground")
end

if #failures > 0 then
  print(string.format("smoke_kit_load: %d passed, %d FAILED", passed, #failures))
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_kit_load: %d passed", passed))
