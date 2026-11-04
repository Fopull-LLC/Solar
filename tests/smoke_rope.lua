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
check(near(L.total, drop_y - (ROPE.radius + 0.01), 0.02), string.format("it falls the cliff and the davit: %.3f", L.total))
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
check(L5 and L5.g and near(L5.total, ROPE.drop_y - ROPE.radius - 0.01, 0.02) and not R.climbable(L5),
  "on flat ground the line lies under the boom: nothing to climb")
check(R.nearestS(L5, 0, 0, 0) == nil, "and nowhere to clip on")

-- 5. ground not made yet: ask again later
local L6, why6 = R.buildLayout(G, U, OUT, 30, function() return nil, "unknown" end)
check(L6 == nil and why6 == "unknown", "ground not made yet: no layout, ask again")

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

for _, f in ipairs(failures) do print("FAIL " .. f) end
print(string.format("smoke_rope: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
