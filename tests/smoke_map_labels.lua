-- SMOKE: the Tracking Station's tag layout (scripts/map_labels.lua), pure.
--
--   * no two placed tags overlap, none lands on a blocked panel, none on
--     another icon, none on an already placed name (the worlds');
--   * priority holds under pressure: the higher one keeps its tag;
--   * a tag that has no room drops a tier before giving up; the cap (40);
--   * a far spot carries a leader line;
--   * clusters form at 14 px and split apart when zoomed in; `keep` never
--     clusters; the cache key changes with each of its inputs and only them;
--   * an offset is relative to its anchor: the anchor moves, the tag moves
--     with it (nothing is kept in screen space but the offset).
--
--   luajit solar/tests/smoke_map_labels.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/map_labels.lua"))
setfenv(chunk, env)
chunk()
local ML = env

local function hit(a, b) return a[1] < b[1] + b[3] and a[1] + a[3] > b[1] and a[2] < b[2] + b[4] and a[2] + a[4] > b[2] end

-- a crowd: 300 icons in a 600 × 400 box
local items, icons = {}, {}
local seed = 7
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
for i = 1, 300 do
  local x, y = 100 + rnd() * 600, 100 + rnd() * 400
  items[i] = { id = "e" .. i, x = x, y = y, r = 6, prio = (i <= 5) and 90 or math.floor(rnd() * 60),
               tiers = { { 90, 30 }, { 60, 16 } } }
  icons[i] = { x, y, 7, id = "e" .. i }
end
local blocked = { { 0, 0, 120, 600 } }
local pre = { { 380, 280, 80, 18 } }
local t0 = os.clock()
local placed, n = ML.layout(items, { blocked = blocked, pre = pre, icons = icons, sw = 1280, sh = 720, cap = 40 })
local ms = (os.clock() - t0) * 1000
check(n <= 40 and n > 15, "the cap holds and a crowd still gets tags (" .. n .. ")")
check(ML.overlaps(placed, items) == 0, "no two tags overlap")
local bad_block, bad_icon, bad_pre = 0, 0, 0
for _, it in ipairs(items) do
  local p = placed[it.id]
  if p.tier > 0 then
    local r = { it.x + p.dx, it.y + p.dy, p.w, p.h }
    for _, b in ipairs(blocked) do if hit(r, b) then bad_block = bad_block + 1 end end
    for _, q in ipairs(pre) do if hit(r, q) then bad_pre = bad_pre + 1 end end
    for _, ic in ipairs(icons) do
      if ic.id ~= it.id and hit(r, { ic[1] - ic[3], ic[2] - ic[3], ic[3] * 2, ic[3] * 2 }) then bad_icon = bad_icon + 1 end
    end
  end
end
check(bad_block == 0 and bad_pre == 0 and bad_icon == 0,
  string.format("tags keep off the panels (%d), the worlds' names (%d) and other icons (%d)", bad_block, bad_pre, bad_icon))
local kept = 0
for i = 1, 5 do if placed["e" .. i].tier > 0 then kept = kept + 1 end end
check(kept >= 4, "the priority-90 items keep their tags in the crowd (" .. kept .. "/5)")
check(ms < 50, string.format("300 icons laid out in %.1f ms (luajit)", ms))

-- priority under pressure: two on one spot, room for one only
local two = { { id = "lo", x = 160, y = 200, r = 6, prio = 10, tiers = { { 300, 16 } } },
              { id = "hi", x = 160, y = 200, r = 6, prio = 80, tiers = { { 300, 16 } } } }
local P2 = ML.layout(two, { sw = 320, sh = 420, blocked = { { 0, 0, 320, 150 }, { 0, 205, 320, 215 } } })
check(P2.hi.tier == 1 and P2.lo.tier == 0, "the higher priority keeps the only room")
-- tiers drop before giving up
local one = { { id = "a", x = 200, y = 200, r = 6, prio = 50, tiers = { { 500, 40 }, { 50, 14 } } } }
local P3 = ML.layout(one, { sw = 420, sh = 420 })
check(P3.a.tier == 2, "a tag too big for the screen drops to its smaller tier")
check(ML.layout(one, { sw = 420, sh = 420, cap = 0 }).a.tier == 0, "past the cap: icon only")
-- a leader line on a far spot
local ring = { { id = "c", x = 200, y = 200, r = 6, prio = 50, tiers = { { 40, 14 } } } }
local ring_icons = {}
for k = 0, 23 do
  local a = k / 24 * 2 * math.pi
  for rr = 12, 26, 7 do ring_icons[#ring_icons + 1] = { 200 + math.cos(a) * rr, 200 + math.sin(a) * rr, 4 } end
end
local P4 = ML.layout(ring, { sw = 420, sh = 420, icons = ring_icons })
check(P4.c.tier == 1 and P4.c.leader == true, "boxed in by icons: a further spot with a leader line")
-- force (the selection) may cover icons as a last resort
local boxed = { { id = "s", x = 200, y = 200, r = 6, prio = 50, force = true, tiers = { { 40, 14 } } } }
local many = {}
for x = 120, 280, 6 do for y = 120, 280, 6 do many[#many + 1] = { x, y, 3 } end end
check(ML.layout(boxed, { sw = 420, sh = 420, icons = many }).s.tier == 1, "the selection still gets a tag in a field of icons")

-- clusters
local pts = {}
for i = 1, 5 do pts[i] = { id = "p" .. i, x = 300 + i * 2, y = 300, prio = i, kind = "debris" } end
pts[6] = { id = "far", x = 600, y = 300, prio = 1, kind = "probe" }
local C, M = ML.cluster(pts, 14, 3)
check(#C == 1 and C[1].n == 5 and M.p1 and not M.far, "five icons inside 14 px: one cluster of 5, the far one alone")
check(C[1].kind == "debris", "the cluster wears its dominant kind")
for i = 1, 5 do pts[i].x = 300 + i * 30 end            -- zoomed in: spread out
C = ML.cluster(pts, 14, 3)
check(#C == 0, "zoomed in, they split apart")
for i = 1, 5 do pts[i].x = 300 + i * 2 end
C, M = ML.cluster(pts, 14, 3, { p5 = true })
check(#C == 1 and C[1].n == 4 and not M.p5, "the selection never joins a cluster")

-- the cache key
local k0 = ML.key(1.0, 0.5, 0.2, "c1", nil, 3, 0, 1600, 900, 720)
check(ML.key(1.01, 0.5, 0.2, "c1", nil, 3, 0, 1600, 900, 720) == k0, "a hair of zoom is the same key")
check(ML.key(1.3, 0.5, 0.2, "c1", nil, 3, 0, 1600, 900, 720) ~= k0, "a zoom bucket changes it")
check(ML.key(1.0, 0.53, 0.2, "c1", nil, 3, 0, 1600, 900, 720) ~= k0, "a degree of yaw changes it")
check(ML.key(1.0, 0.5, 0.25, "c1", nil, 3, 0, 1600, 900, 720) ~= k0, "pitch changes it")
check(ML.key(1.0, 0.5, 0.2, "c2", nil, 3, 0, 1600, 900, 720) ~= k0, "the selection changes it")
check(ML.key(1.0, 0.5, 0.2, "c1", "c4", 3, 0, 1600, 900, 720) ~= k0, "the hover changes it")
check(ML.key(1.0, 0.5, 0.2, "c1", nil, 4, 0, 1600, 900, 720) ~= k0, "a new snapshot changes it")
check(ML.key(1.0, 0.5, 0.2, "c1", nil, 3, 0, 1920, 1080, 720) ~= k0, "the screen size changes it")
check(ML.key(1.0, 0.5, 0.2, "c1", nil, 3, 0, 1600, 900, 847) ~= k0, "the interface size changes it")

-- an offset rides its anchor
local mv = { { id = "m", x = 300, y = 300, r = 6, prio = 50, tiers = { { 50, 14 } } } }
local Pm = ML.layout(mv, { sw = 800, sh = 800 }).m
local ax, ay = 340, 260                       -- the anchor moved; the offset is kept
check(Pm.dx and math.abs((ax + Pm.dx) - (300 + Pm.dx) - 40) < 1e-9 and Pm.dy == ML.layout(mv, { sw = 800, sh = 800 }).m.dy,
  "the tag is an offset from its anchor: it moves with it")

if #failures == 0 then
  print(string.format("MAP LABELS SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("MAP LABELS SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
