-- SMOKE: the Rope Kit's line, offline (scripts/rope_climb.lua's pure rules).
--
--   * THE DRAPE: a 10 m vertical cliff (the line falls free beside the face
--     and lies on the floor), a 65° slab (the line runs down the rock, never
--     inside it), a 50 m drop (it hangs free, 30 m, a stopper knot), a meadow
--     (it lies under the boom: nothing to climb), ground not made yet
--   * THE ENDS: the top under the sheave, the bottom with the soles on the
--     floor, what E does at each (top / bottom / fall) and the drop under
--     the feet
--   * SPEEDS: the ascender's watts against the weight, capped at its line
--     speed; the descender's steady rate; up is slower than down at 1 g
--   * THE CLIMB: the stroke-pulsed move from the bottom to the top and back,
--     its time, its bites, the ends clamp
--   * nearest point, the hang offset, the facing, the save round trip
--
--   luajit solar/tests/smoke_rope.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-6) end

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile(here .. "../scripts/rope_climb.lua"))
setfenv(chunk, env)
chunk()
local R = env
local ROPE = R.ROPE

-- A 2D world in y (up) and z (out is −z): ground height h(z); x is ignored.
-- cast marches the ray in 1 cm steps and answers the first point under the
-- ground, its normal from the slope.
local function world(h)
  local function below(y, z) return y < h(z) end
  local function normal(z)
    local e = 0.01
    local dh = (h(z + e) - h(z - e)) / (2 * e)
    local l = math.sqrt(1 + dh * dh)
    return 0, 1 / l, -dh / l
  end
  local calls = 0
  local function cast(x, y, z, dx, dy, dz, mx)
    calls = calls + 1
    if below(y, z) then return { x = x, y = y, z = z, nx = 0, ny = 1, nz = 0, d = 0 } end
    local t = 0
    while t < mx do
      t = math.min(mx, t + 0.01)
      local px, py, pz = x + dx * t, y + dy * t, z + dz * t
      if below(py, pz) then
        -- refine the crossing
        local lo, hi = t - 0.01, t
        for _ = 1, 20 do
          local m = (lo + hi) / 2
          if below(y + dy * m, z + dz * m) then hi = m else lo = m end
        end
        local nx, ny, nz = normal(z + dz * hi)
        return { x = x + dx * hi, y = y + dy * hi, z = z + dz * hi, nx = nx, ny = ny, nz = nz, d = hi }
      end
    end
    return nil, "air"
  end
  return cast, h, function() return calls end
end

local U, OUT = { 0, 1, 0 }, { 0, 0, -1 }

-- 1. a 10 m vertical cliff: the ledge at y = 10 for z > 0, the floor at 0
local cast, h = world(function(z) return z > 0 and 10 or 0 end)
local G = { 0, 10, 0.4 }               -- the davit 0.4 m back from the edge
local L = R.buildLayout(G, U, OUT, ROPE.length, cast)
check(L ~= nil, "a layout over a vertical cliff")
local drop_y = 10 + ROPE.drop_y
check(L.g == true, "the line lies on the floor")
check(near(L.total, drop_y - (ROPE.radius + ROPE.gap), 0.02), string.format("it falls the cliff and the davit: %.3f", L.total))
check(near(L.p[1], 0) and near(L.p[2], drop_y) and near(L.p[3], 0.4 - ROPE.drop_out),
  "it leaves the sheave out over the drop")
check(near(L.s_top, ROPE.top), "the top is under the sheave")
check(near(L.s_max, L.total - ROPE.hang - ROPE.foot, 0.06), string.format("the bottom: soles on the floor (%.2f of %.2f)", L.s_max, L.total))
check(R.climbable(L), "climbable")
check(R.unclipKind(L, L.s_top) == "top", "E at the top steps off")
check(R.unclipKind(L, L.s_max) == "bottom", "E at the bottom unclips onto the ground")
check(R.unclipKind(L, 5) == "fall", "E halfway lets go")
local d5 = R.dropAt(L, 5)
local x5, y5 = R.at(L, 5)
check(near(d5, y5 - ROPE.hang - ROPE.foot - L.p[#L.p - 1], 1e-6) and d5 > 3, string.format("the drop under the feet at 5 m: %.2f", d5 or -1))
check(near(R.dropAt(L, L.s_max), 0, 0.06), "no drop at the bottom")
local wd = R.wallAt(L, 5)
check(near(wd, ROPE.drop_out - 0.4, 0.02), string.format("the face is %.2f m from the line (%.3f)", ROPE.drop_out - 0.4, wd or -1))
check(R.wallAt(L, 0.2) == nil, "no wall beside the sheave, above the ledge")
-- the hang offset and the facing
local bx, by, bz = R.bodyAt(L, 5)
local rx, ry, rz = R.at(L, 5)
check(near(by, ry - ROPE.hang) and near(bz, rz - ROPE.away), "the suit hangs below the hands and out from the line, away from the wall")
local s, d = R.nearestS(L, bx + 0.1, by, bz)
check(near(s, 5, 0.02) and d < 0.15, string.format("the nearest climbable point (%.3f, %.3f m)", s or -1, d or -1))
local _, _, _, ax, ay, az = R.at(L, 5)
check(near(az, -1) and near(ay, 0), "away from the wall is out over the drop")
-- facing as deployables stands it
local fu1, fu2, fu3, f1, f2, f3 = R.facing(0, 100, 0, 3, 5, 4)
check(near(fu2, 1) and near(f2, 0) and near(f1 * f1 + f3 * f3, 1), "the facing is flattened onto the ground")

-- the save round trip
local T = R.toSave(L)
local L2 = R.fromSave(T)
check(L2 ~= nil and near(L2.total, L.total, 1e-3) and near(L2.s_max, L.s_max, 0.06) and L2.g == true
  and #L2.wd == #L.wd, "a layout survives the save")
check(R.fromSave({ p = { 1, 2 } }) == nil and R.fromSave(nil) == nil and R.fromSave(false) == nil, "a broken save entry is no layout")
local depth = 0
local function deep(t, n) for _, v in pairs(t) do if type(v) == "table" then deep(v, n + 1) end end if n > depth then depth = n end end
deep(T, 1)
check(depth <= 2, "the save entry is two tables deep (save.set keeps four)")

-- 2. a 65° slab from the edge down 12 m to the floor
local tan65 = math.tan(math.rad(65))
local cast2, h2 = world(function(z)
  if z > 0 then return 12 end
  return math.max(0, 12 + z * tan65)    -- falls 12 m over 5.6 m out
end)
local L3 = R.buildLayout({ 0, 12, 0.5 }, U, OUT, ROPE.length, cast2)
check(L3 and L3.g == true, "a slab: the line reaches the floor")
local inside = 0
for i = 1, #L3.p, 3 do
  if L3.p[i + 1] < h2(L3.p[i + 2]) - 0.003 then inside = inside + 1 end
end
check(inside == 0, string.format("the line never runs inside the rock (%d points)", inside))
local straight = 12 + ROPE.drop_y
check(L3.total > straight - 0.05, string.format("draped, it is longer than the straight drop (%.2f ≥ %.2f)", L3.total, straight))
local on_rock = 0
for k = 3, math.floor(L3.total) - 3 do if (R.wallAt(L3, k) or 9) < 0.1 then on_rock = on_rock + 1 end end
check(on_rock >= 3, string.format("lying on the slab, the feet find the rock (%d metres)", on_rock))
check(L3.s_max > L3.s_top + 5, "and it climbs")
-- the feet's wall distance blends between the metres
check(near(R.wallSmooth({ wd = { 0.2, 0.4 } }, 0.25), 0.25, 1e-9) and R.wallSmooth({ wd = { -1, -1 } }, 0.5) == nil
  and near(R.wallSmooth(L3, 4.5), ((R.wallAt(L3, 4) or 0) + (R.wallAt(L3, 5) or 0)) / 2, 1e-9),
  "the wall's distance blends between the metres")

-- 3. a 50 m drop: the line hangs free and ends in the air
local cast3 = world(function(z) return z > 0 and 50 or 0 end)
local L4 = R.buildLayout({ 0, 50, 0.4 }, U, OUT, ROPE.length, cast3)
check(L4 and L4.g == false and near(L4.total, 30, 1e-6), "a 50 m drop: 30 m hanging free")
check(near(L4.s_max, 30 - ROPE.knot), "a free end's bottom is the stopper knot")
check(R.dropAt(L4, 10) == nil, "no ground known under a free end")
check(R.unclipKind(L4, L4.s_max) == "fall", "E at a free end lets go")

-- 4. a meadow: the line lies under the boom
local cast4 = world(function() return 0 end)
local L5 = R.buildLayout({ 0, 0, 0 }, U, OUT, ROPE.length, cast4)
check(L5 and L5.g and near(L5.total, ROPE.drop_y - ROPE.radius - ROPE.gap, 0.02) and not R.climbable(L5),
  "on flat ground the line lies under the boom: nothing to climb")
check(R.nearestS(L5, 0, 0, 0) == nil, "and nowhere to clip on")

-- 5. ground not made yet: ask again later
local L6, why6 = R.buildLayout(G, U, OUT, 30, function() return nil, "unknown" end)
check(L6 == nil and why6 == "unknown", "ground not made yet: no layout, ask again")

-- 6. A ROUNDED FACE (playtest 2026-11-11: "ropes can clip through walls"):
-- a convex face, 50° at the lip to 82° 3 m out. The drape's 1 m steps down
-- it are chords across a curve, and a chord across a convex curve runs
-- inside the rock (8 cm at the lip) unless the chords are cleared.
local function under(Lx, hf, skin)
  -- samples every 2 cm along every segment (the tail too) under the ground by more than `skin`
  local pts = {}
  for i = 1, #Lx.p, 3 do pts[#pts + 1] = { Lx.p[i], Lx.p[i + 1], Lx.p[i + 2] } end
  for i = 1, #(Lx.tail or {}), 3 do pts[#pts + 1] = { Lx.tail[i], Lx.tail[i + 1], Lx.tail[i + 2] } end
  local bad, worst = 0, 0
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local l = math.sqrt((b[2] - a[2]) ^ 2 + (b[3] - a[3]) ^ 2)
    local k = math.max(1, math.ceil(l / 0.02))
    for j = 0, k do
      local f = j / k
      local y, z = a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
      local d = hf(z) - y
      if d > skin then bad = bad + 1 end
      if d > worst then worst = d end
    end
  end
  return bad, worst
end
local function hround(z)
  if z > 0 then return 12 end
  return math.max(0, 12 - 1.19 * z * z)
end
local castR = world(hround)
local most = R.CLEAR.most
R.CLEAR.most = 0
local Lr0 = R.buildLayout({ 0, 12, 0.4 }, U, OUT, ROPE.length, castR)
R.CLEAR.most = most
local bad0, worst0 = under(Lr0, hround, 0.003)
local Lr = R.buildLayout({ 0, 12, 0.4 }, U, OUT, ROPE.length, castR)
local bad1, worst1 = under(Lr, hround, 0.003)
check(bad0 > 0 and worst0 > 0.03, string.format("rounded face: uncleared, the chords cut %.3f m into the rock (%d samples)", worst0, bad0))
check(Lr and Lr.g and bad1 == 0 and (Lr.cleared or 0) > 0,
  string.format("rounded face: cleared, nothing inside (%d samples, worst %.4f m) with %d points put in", bad1, worst1, Lr and Lr.cleared or -1))
check(Lr.total >= Lr0.total - 1e-6 and Lr.total < Lr0.total + 0.5, string.format("rounded face: the wrapped line is a touch longer (%.3f vs %.3f)", Lr.total, Lr0.total))
check(R.climbable(Lr), "rounded face: still climbable")
-- a boulder the straight drop misses but a chord clips: clearPath alone
do
  local function hb(z) local dz = z + 1.0; return (math.abs(dz) < 0.8) and (4 + math.sqrt(0.64 - dz * dz)) or 0 end
  local cb = world(hb)
  local Pp, A = { 0, 5, 0, 0, 4, -2.2 }, { 0, 0, -1, 0, 0, -1 }
  local n = R.clearPath(Pp, A, cb, ROPE.radius + ROPE.gap, U)
  local Lb = { p = Pp, a = A }
  local bb = under(Lb, hb, 0.003)
  check(n > 0 and bb == 0 and #Pp == #A, string.format("a boulder across a chord: %d points put in round it, %d samples inside", n, bb))
  local Pq, Aq = { 0, 8, 0, 0, 7, 0 }, { 0, 0, -1, 0, 0, -1 }
  check(R.clearPath(Pq, Aq, cb, 0.02, U) == 0 and #Pq == 6, "a clear chord is left as it is")
end
-- the tail lies on the ground, on a floor that rises away from the wall
do
  local function hs(z) if z > 0 then return 10 end return math.max(0, -z * 0.3 - 0.6) end   -- the floor rises 0.3 per m out from 2 m out
  local cs = world(hs)
  local Ls = R.buildLayout({ 0, 10, 0.4 }, U, OUT, ROPE.length, cs)
  local bt = Ls and under(Ls, hs, 0.003) or -1
  check(Ls and Ls.g and Ls.tail and #Ls.tail >= 3 and bt == 0, string.format("the tail lies on a rising floor (%d samples inside, %d tail points)",
    bt, Ls and Ls.tail and #Ls.tail / 3 or 0))
  local T2 = R.fromSave(R.toSave(Ls))
  check(T2 and T2.tail and #T2.tail == #Ls.tail, "the tail survives the save")
end

-- a narrow ledge half way down a cliff does not hold the line; a wide one does
do
  local function hl(w) return function(z) if z > 0 then return 10 end if z > -w then return 5 end return 0 end end
  local Ln = R.buildLayout({ 0, 10, 0.6 }, U, OUT, ROPE.length, world(hl(0.35)))
  check(Ln and Ln.g and Ln.p[#Ln.p - 1] < 0.1, string.format("a 0.35 m ledge: the line runs over its lip to the floor (ends %.2f m up)", Ln and Ln.p[#Ln.p - 1] or -1))
  local bn = Ln and under(Ln, hl(0.35), 0.003) or -1
  check(bn == 0, string.format("…and nothing of it inside the ledge (%d samples)", bn))
  local Lw = R.buildLayout({ 0, 10, 0.6 }, U, OUT, ROPE.length, world(hl(1.5)))
  check(Lw and Lw.g and math.abs(Lw.p[#Lw.p - 1] - 5) < 0.1, string.format("a 1.5 m ledge holds it (ends %.2f m up)", Lw and Lw.p[#Lw.p - 1] or -1))
end

-- THE LINE SETTLES AGAIN: its signature, how far two layouts are apart
do
  local pts = R.sigPoints(L, G, U)
  local nline = math.floor(L.total / R.SETTLE.step) + 1
  check(#pts == nline + 2, string.format("signature: a point every %.1f m and two under the plate (%d)", R.SETTLE.step, #pts))
  check(near(pts[#pts][2], G[2] - 0.6) and near(pts[#pts - 1][2], G[2] - 0.2), "signature: the plate's two points are under it")
  local q0 = {}
  for i = 1, #pts do q0[i] = 0.02 end
  local q1 = {}
  for i = 1, #pts do q1[i] = q0[i] end
  check(not R.sigMoved(q1, q0), "signature: the same ground has not moved")
  q1[5] = 0.02 + R.SETTLE.eps * 2
  check(R.sigMoved(q1, q0), "signature: a dig beside the line moves it")
  check(R.sigMoved(nil, q0) and R.sigMoved({ 1 }, q0), "signature: a missing read counts as moved")
  check(near(R.layoutGap(L, L), 0, 1e-9), "gap: a layout is no distance from itself")
  -- the floor under the cliff dug 3 m deeper: the line falls further
  local castD = world(function(z) return z > 0 and 10 or -3 end)
  local LD = R.buildLayout(G, U, OUT, ROPE.length, castD)
  local gap = R.layoutGap(L, LD)
  check(LD.g and near(LD.total - L.total, 3, 0.03) and gap > 2.9, string.format("gap: the floor dug 3 m, the line moves %.2f m", gap))
  check(R.layoutGap(L, L4) >= 1, "gap: grounded against hanging free is a move")
end
-- the sway: a free line never swings its foot into the wall beside it
do
  local renv = setmetatable({}, { __index = _G })
  local rchunk = assert(loadfile(here .. "../scripts/rope.lua"))
  setfenv(rchunk, renv)
  rchunk()
  local cap = renv.swing_cap({ wd = { -1, 0.3, 0.25, -1 }, total = 30 })
  check(cap > 0 and 30 * math.tan(cap) <= 0.25 - 0.0075 + 1e-9, string.format("sway: a wall 0.25 m off, the foot swings at most %.3f m", 30 * math.tan(cap)))
  check(renv.swing_cap({ wd = { -1, -1 }, total = 30 }) == math.huge, "sway: no wall found, the sway's own amplitude")
  check(renv.swing_cap({ wd = { 0.05 }, total = 10 }) == 0, "sway: a wall at the line, no sway")
end

-- SPEEDS
local up1, dn1 = R.speeds(9.8, 135, false)
check(near(up1, 1100 / (135 * 9.8), 1e-9) and near(dn1, 1.6), string.format("1 g: up %.2f, down %.2f m/s", up1, dn1))
check(up1 < dn1, "up is slower than down at 1 g")
local upm = R.speeds(1.6, 135, false)
check(near(upm, ROPE.line_max), "a light moon: the ascender's line speed")
local up0, dn0 = R.speeds(0, 135, true)
check(near(up0, ROPE.line_max) and near(dn0, ROPE.down_fast), "no gravity: line speed; SHIFT: a fast rappel")
local uph = R.speeds(9.8, 200, false)
check(uph < up1, "a heavier pack climbs slower")
check(near(R.speeds(9.8, 135, false, { power = 2200, line_max = 5 }), 2200 / (135 * 9.8), 1e-9), "the params' watts")

-- THE CLIMB: bottom to top at 1 g, then back down
local st = { s = L.s_max, v = 0, phase = 0 }
local t, bites, ended = 0, 0, nil
local vmin, vmax = 1e9, -1e9
while t < 60 do
  local _, e, bit = R.move(st, 1, 1 / 60, up1, dn1, L)
  t = t + 1 / 60
  if bit then bites = bites + 1 end
  if e then ended = e break end
end
local dist = L.s_max - L.s_top
check(ended == "top" and near(st.s, L.s_top), string.format("W climbs to the top (%s)", tostring(ended)))
check(t > dist / up1 and t < dist / up1 + 1.5, string.format("%.1f m in %.1f s at %.2f m/s", dist, t, up1))
check(math.abs(bites - dist / ROPE.stroke) <= 2, string.format("the ascender bites once a stroke (%d for %.1f m)", bites, dist))
local up_t = t
-- held at the top, nothing moves
local _, e0 = R.move(st, 0, 0.5, up1, dn1, L)
st.v = 0
R.move(st, 0, 1 / 60, up1, dn1, L)
check(near(st.s, L.s_top) and st.v == 0 and e0 == nil, "no keys: it holds")
t, ended = 0, nil
local bites_down = 0
while t < 60 do
  local _, e, bit = R.move(st, -1, 1 / 60, up1, dn1, L)
  t = t + 1 / 60
  if bit then bites_down = bites_down + 1 end
  if e then ended = e break end
end
check(ended == "bottom" and near(st.s, L.s_max), "S lowers to the bottom")
check(t < up_t, string.format("down (%.1f s) is quicker than up (%.1f s)", t, up_t))
check(bites_down == 0, "no ascender bites on the way down")
-- a stroke pulses the speed
st = { s = 6, v = -up1, phase = 0 }
local s_a = st.s
R.move(st, 1, 0.02, up1, dn1, L)
local slow = s_a - st.s
st.phase = 0.5
s_a = st.s
R.move(st, 1, 0.02, up1, dn1, L)
local fast = s_a - st.s
check(fast > 2 * slow, string.format("the stroke: slow as the cam bites, fast as it pulls (%.4f vs %.4f)", slow, fast))


-- THE DIG GUARD: a box round the davit's plate and staked stays, under the
-- ground, in the body's frame (base_facilities.guard_dist's measure)
local function gdist(g, q)
  local rx, ry, rz = q[1] - g.c.x, q[2] - g.c.y, q[3] - g.c.z
  local a = rx * g.t.x + ry * g.t.y + rz * g.t.z
  local b = rx * g.up.x + ry * g.up.y + rz * g.up.z
  local s = rx * g.n.x + ry * g.n.y + rz * g.n.z
  local ea, es = math.max(0, math.abs(a) - g.ht), math.max(0, math.abs(s) - g.hn)
  local eb = b < g.lo and g.lo - b or (b > g.hi and b - g.hi or 0)
  return math.sqrt(ea * ea + es * es + eb * eb)
end
do
  -- a davit on a 600 m world at its north pole, planted from +z (its boom −z)
  local e = { b = "Rock", x = 0, y = 600, z = 0, fx = 0, fy = 0, fz = 3 }
  local g = R.guardBox(e)
  local function dt(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
  check(near(dt(g.t, g.up), 0, 1e-9) and near(dt(g.t, g.n), 0, 1e-9) and near(dt(g.up, g.n), 0, 1e-9)
    and near(g.up.y, 1, 1e-9) and near(g.n.z, 1, 1e-9), "guard: its axes are the davit's (up, toward the planter, side)")
  check(gdist(g, { 0, 599.5, 0 }) == 0, "guard: the ground under the plate is guarded")
  check(gdist(g, { 0.42, 599.7, 0.52 }) == 0 and gdist(g, { -0.42, 599.7, 0.52 }) == 0, "guard: under both stakes")
  check(gdist(g, { 0, 599.0, 0.2 }) == 0, "guard: 1 m down")
  check(gdist(g, { 0, 598.4, 0 }) > 0.25, "guard: but not 1.6 m down")
  check(gdist(g, { 0, 599.5, -2.0 }) > 1.4, "guard: the drop in front of the boom can be dug")
  check(gdist(g, { 2.0, 599.5, 0 }) > 1.3, "guard: and 2 m to the side")
  check(gdist(g, { 0, 599.0, -1.3 }) > 0.6, "guard: a laser's 0.6 m ball 1.3 m out in front is clear of it")
  -- groups: near davits (one grid cell) share an owner, far ones and other worlds get their own
  local recs = {
    e, { b = "Rock", x = 20, y = 599.6, z = 5, fx = 1, fy = 0, fz = 0 }, { b = "Rock", x = 30, y = 599.1, z = 10, fx = 0, fy = 0, fz = -1 },
    { b = "Rock", x = 0, y = 0, z = 600, fx = 1, fy = 0, fz = 0 }, { b = "Moon", x = 0, y = 300, z = 0, fx = 1, fy = 0, fz = 0 },
  }
  local G = R.guardGroups(recs)
  local owners, boxes, biggest = 0, 0, 0
  for k, o in pairs(G) do
    owners = owners + 1
    boxes = boxes + #o.list
    biggest = math.max(biggest, #o.list)
    check(k:sub(1, 5) == "rope:" and (o.body == "Rock" or o.body == "Moon"), "guard: owner " .. k)
  end
  check(owners == 3 and boxes == 5 and biggest == 3, string.format("guard: 5 davits in 3 owners (%d owners, %d boxes)", owners, boxes))
  -- many davits stay cheap: 400 across a world, a dig tests few boxes
  local many = {}
  for i = 1, 400 do
    local a, z = i * 2.39996, 1 - 2 * (i - 0.5) / 400
    local r = math.sqrt(1 - z * z)
    many[i] = { b = "Rock", x = 600 * r * math.cos(a), y = 600 * r * math.sin(a), z = 600 * z, fx = 0, fy = 0, fz = 1 }
  end
  local M = R.guardGroups(many)
  local n, mx = 0, 0
  for _, o in pairs(M) do n = n + 1; mx = math.max(mx, #o.list) end
  check(n > 20 and mx < 40, string.format("guard: 400 davits spread over %d owners, at most %d in one", n, mx))
  check(next(R.guardGroups({})) == nil, "guard: no davits, no owners")
end

for _, f in ipairs(failures) do print("FAIL " .. f) end
print(string.format("smoke_rope: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
