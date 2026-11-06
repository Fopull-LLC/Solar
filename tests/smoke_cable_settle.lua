-- SMOKE: how a Power Cable settles (playtest 2026-11-06; base_cable.lua
-- settle / thin / polyline): the one-time relaxation that hangs a heavy cable
-- as a catenary between supports and lays it on the ground and over what it
-- crosses.
--
--   * a free span matches the analytic catenary y = a (cosh(x/a) - 1);
--   * a cable dropped from a part's side to flat ground meets it where the
--     catenary of its pull and weight says (a acosh(1 + d/a)), tangentially;
--   * it never goes under a support (bumpy ground, a box, a ridge), and lies
--     on the ground wherever it touches;
--   * draped over a 1 m box, it hangs off both sides to the ground;
--   * the pull sets the sag: half the pull, a deeper sag;
--   * the longest run (2,000 stations) settles in a few ms, once;
--   * on a world (polyline): the run follows a bumpy ground sample by sample,
--     ends on the parts, and a box under its line holds it up; the thinned
--     mesh points keep the shape to 4 mm.
--
--   luajit solar/tests/smoke_cable_settle.lua

local failures, passed = {}, 0
local VERB = os.getenv("V")
local function check(ok, msg)
  if VERB then print((ok and "ok   " or "FAIL ") .. msg) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local E = setmetatable({ time = 0, save = { get = function() return nil end, set = function() end },
  findScript = function() return nil end, findScripts = function() return {} end, find = function() return nil end,
  log = function() end }, { __index = _G })
local f = assert(loadfile("solar/scripts/base_cable.lua"))
setfenv(f, E)
f()
E.params = { step = 0.5 }
local CB = E

local function cosh(x) return (math.exp(x) + math.exp(-x)) / 2 end
local function acosh(x) return math.log(x + math.sqrt(x * x - 1)) end

-- ── a free span ─────────────────────────────────────────────────────────────
do
  local a, span, ds = 10.0, 20.0, 0.25
  local n = math.floor(span / ds) + 1
  local S = {}
  for i = 1, n do S[i] = -100 end
  local y, sweeps = CB.settle(S, ds, 0, 0, a)
  local mid = y[math.floor((n + 1) / 2)]
  local want = -a * (cosh((span / 2) / a) - 1)
  check(near(mid, want, 0.01), string.format("a free 20 m span sags %.3f m (the catenary: %.3f)", -mid, -want))
  local worst = 0
  for i = 1, n do
    local x = (i - 1) * ds - span / 2
    local c = -a * (cosh((span / 2) / a) - cosh(x / a))
    worst = math.max(worst, math.abs(y[i] - c))
  end
  check(worst < 0.01, string.format("...and follows it all along (worst %.4f m, %d sweeps)", worst, sweeps))
  -- the pull sets the sag
  local y2 = CB.settle(S, ds, 0, 0, a / 2)
  check(y2[math.floor((n + 1) / 2)] < mid - 0.5, string.format("half the pull: a deeper sag (%.2f m against %.2f m)",
    -y2[math.floor((n + 1) / 2)], -mid))
end

-- ── dropped from a part's side to flat ground ───────────────────────────────
do
  local a, ds, L = 3.6, 0.25, 30
  local n = math.floor(L / ds) + 1
  local S = {}
  for i = 1, n do S[i] = 0 end
  local y = CB.settle(S, ds, 0.6, 0.6, a)
  local touch
  for i = 1, n do if y[i] <= 1e-6 then touch = (i - 1) * ds break end end
  local want = a * acosh(1 + 0.6 / a)
  check(touch and math.abs(touch - want) <= 0.3, string.format("from 0.6 m up it meets the ground %.2f m out (the catenary: %.2f m)", touch or -1, want))
  local mid = y[math.floor((n + 1) / 2)]
  check(near(mid, 0, 1e-9), "and lies on the ground between")
  -- tangential: the slope into the touchdown is nearly flat
  local i0 = math.floor(touch / ds) + 1
  local slope = (y[i0 - 1] - y[i0]) / ds
  check(slope < 0.12, string.format("meeting it tangentially (slope %.3f a station before)", slope))
end

-- ── never under a support: bumpy ground, a box ──────────────────────────────
do
  local ds, n = 0.25, 401
  local S = {}
  for i = 1, n do
    local x = (i - 1) * ds
    S[i] = (x > 40 and x < 44) and 1.6 or (0.4 * math.sin(x * 0.7) + 0.15 * math.sin(x * 2.3 + 1))
  end
  local y = CB.settle(S, ds, 1.2, 1.0, 3.6)
  local under, onground, onbox = 0, 0, 0
  for i = 2, n - 1 do
    if y[i] < S[i] - 1e-9 then under = under + 1 end
    if y[i] - S[i] < 1e-6 then onground = onground + 1 end
  end
  for i = 1, n do local x = (i - 1) * ds; if x > 40.5 and x < 43.5 and y[i] - S[i] < 1e-6 then onbox = onbox + 1 end end
  check(under == 0, string.format("over bumpy ground and a box 1 m over it it never goes under (%d stations under)", under))
  check(onground > n * 0.3, string.format("it lies on the ground where it touches (%d of %d stations)", onground, n))
  check(onbox > 5, string.format("it rests on the box's top (%d stations)", onbox))
  -- off the box's edges it hangs: free stations just past each edge
  local freeL, freeR = 0, 0
  for i = 1, n do
    local x = (i - 1) * ds
    if x > 38.5 and x < 40 and y[i] - S[i] > 0.05 then freeL = freeL + 1 end
    if x > 44 and x < 45.5 and y[i] - S[i] > 0.05 then freeR = freeR + 1 end
  end
  check(freeL > 0 and freeR > 0, string.format("and hangs off both its sides to the ground (%d and %d stations free)", freeL, freeR))
end

-- ── the longest run, once ───────────────────────────────────────────────────
do
  local ds, n = 0.75, 2001
  local S = {}
  for i = 1, n do local x = (i - 1) * ds; S[i] = 3 * math.sin(x / 40) + 0.3 * math.sin(x / 3) end
  local t0 = os.clock()
  local y, sweeps = CB.settle(S, ds, S[1] + 0.6, S[n] + 0.6, 3.6)
  local ms = (os.clock() - t0) * 1000
  local under = 0
  for i = 1, n do if y[i] < S[i] - 1e-9 then under = under + 1 end end
  check(under == 0 and ms < 120, string.format("1.5 km, 2,001 stations: settled once in %.1f ms (%d sweeps), never under", ms, sweeps))
  local keep = CB.thin(y, ds, 0.004)
  local worst = 0
  for k = 2, #keep do
    local i0, i1 = keep[k - 1], keep[k]
    for i = i0 + 1, i1 - 1 do
      local fr = (i - i0) / (i1 - i0)
      worst = math.max(worst, math.abs(y[i] - (y[i0] + (y[i1] - y[i0]) * fr)))
    end
  end
  check(worst <= 0.0045 and #keep < n, string.format("thinned to %d points, the shape kept to %.1f mm", #keep, worst * 1000))
end

-- ── on a world: polyline ────────────────────────────────────────────────────
do
  local R = 1000
  -- two ends 40 m apart along +x at 0.6 m up; the ground a bump of 0.5 m between
  local th = 40 / R
  local function at(t, r) return math.sin(t) * r, math.cos(t) * r, 0 end
  local ax, ay, az = at(0, R + 0.6)
  local zx, zy, zz = at(th, R + 0.6)
  local tax, tay, taz = at(1.6 / R, R)
  local tzx, tzy, tzz = at(th - 1.6 / R, R)
  local Ee = { ax = ax, ay = ay, az = az, zx = zx, zy = zy, zz = zz, tax = tax, tay = tay, taz = taz, tzx = tzx, tzy = tzy, tzz = tzz }
  local function ground(t) local x = t * R; return R + 0.5 * math.exp(-((x - 20) / 3) ^ 2) end
  local h = {}
  local step = 0.5
  local nh = math.ceil(40 / step)
  for i = 0, nh do h[i + 1] = ground(th * i / nh) end
  local pts, L, info = CB.polyline(Ee, h, R, { a = 3.6 })
  local p1 = pts[1]
  local r1 = math.sqrt(p1.x ^ 2 + p1.y ^ 2 + p1.z ^ 2)
  check(near(r1, R + 0.6, 1e-6), "it leaves the part 0.6 m up")
  local under, worst_on = 0, 0
  for i, yv in ipairs(info.y) do
    local t = th * (i - 1) / info.n
    if yv < ground(t) + 0.016 - 1e-6 then under = under + 1 end
  end
  -- over the bump: lying on it (the bump is gentle, the cable slack)
  local im = math.floor(info.n / 2) + 1
  local onbump = info.y[im] - ground(th * (im - 1) / info.n)
  check(under == 0 and onbump < 0.03, string.format("it follows the ground's 0.5 m bump, sample by sample (%.3f m over its top), never under", onbump))
  check(L > 40 and L < 41.5, string.format("%.2f m of cable for a 40 m run", L))
  -- a box (a 2 x 2 m Pad Plate, 0.6 m tall) under its line at 10 m
  local bxg = { at(10 / R, R) }
  local ux, uy = bxg[1] / R, bxg[2] / R
  local box = { gx = bxg[1], gy = bxg[2], gz = 0, ux = ux, uy = uy, uz = 0, rx = uy, ry = -ux, rz = 0, fx = 0, fy = 0, fz = 1,
                hx = 1.0, hz = 1.0, top = 0.6, key = "1:1" }
  local _, _, info2 = CB.polyline(Ee, h, R, { a = 3.6, boxes = { box } })
  local i10 = math.floor(10 / 40 * info2.n) + 1
  local y10 = info2.y[i10] - R
  check(y10 >= 0.6 and y10 < 0.65, string.format("a box under its line holds it up (%.3f m at the box's middle, its top 0.6 m)", y10))
  local i6 = math.floor(6 / 40 * info2.n) + 1
  check(info2.y[i6] - ground(6 / R) < 0.03, "and it is back on the ground 4 m away")
end

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL " .. m) end
  print(string.format("smoke_cable_settle: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_cable_settle: %d passed", passed))
