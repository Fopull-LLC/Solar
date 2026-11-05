-- SMOKE HARNESS for the maneuver node's click-and-drag gizmo (orbit_map.lua:
-- MNV, mnvFrame, the node's menu actions and warp to node; deep-space
-- proposal §7, F1–F6, F8).
--
-- The rules as numbers — the drag's sensitivity ramp, the wheel, the slide's
-- clamp, ±1 orbit, the warp's landing — and then the real per-frame input code
-- driven through a stub camera (screen = world x, y) over a circular path:
-- a click places the node on the line, the disc slides it (never behind now +
-- 1 s, its Δv components kept and turned with the new frame), a handle drag
-- adds Δv along its axis, and warp to node lands on time without overshooting.
--
--   luajit solar/tests/smoke_mnvnode.lua

local failures, passed = {}, 0
local function ok(c, msg)
  if c then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return a and b and math.abs(a - b) <= tol end

-- ── a stub engine ───────────────────────────────────────────────────────────
local NOW, WARP, WARP_REQ = 5000.0, 1, nil
local function WARP_TICK() if WARP_REQ then WARP, WARP_REQ = WARP_REQ, nil end end
local MX, MY, BTN, KEYS, SCROLL = 0, 0, {}, {}, 0
local SCRIPTS = {}
local said = {}
local env = setmetatable({}, { __index = _G })
env.time = 0
env.params = { gizmo_size = 1.0, gizmo_stroke = 1, recompute = 0.15, segments = 140 }
env.space = {
  time = function() return NOW end,
  -- a request lands on the next tick (WARP_TICK applies it), as the engine's does
  warp = function(w) if w then WARP_REQ = w end return WARP end,
}
env.camera = {
  exists = function() return true end,
  worldToScreen = function(x, y, z) return x, y, z, true end,
  screenRect = function() return 0, 0, 4000, 4000 end,
}
env.input = {
  mouse = function() return MX, MY end,
  button = function(b) return BTN[b] == true end,
  key = function(k) return KEYS[k] == true end,
  pressed = function() return false end,
  scroll = function() return SCROLL end,
  mouse_delta = function() return 0, 0 end,
}
local function stub() end
env.draw = setmetatable({}, { __index = function() return stub end })
env.findScript = function(kind) return SCRIPTS[kind] end
env.findScripts = function(kind) return SCRIPTS[kind] and { SCRIPTS[kind] } or {} end
env.log = function(m) said[#said + 1] = m end
local chunk = assert(loadfile("solar/scripts/orbit_map.lua"))
setfenv(chunk, env)
chunk()
local M = env.MNV
env.map_view = true
ok(type(M) == "table" and type(env.mnvFrame) == "function", "orbit_map publishes MNV and mnvFrame")

-- ── 1. THE DRAG'S SENSITIVITY RAMP (F3) ─────────────────────────────────────
ok(M.ramp(0) == 1 and M.ramp(0.5) == 1, "×1 for the first half second of a drag")
ok(near(M.ramp(1.0), 3, 1e-9), "×3 at one second (got " .. M.ramp(1.0) .. ")")
ok(near(M.ramp(2.0), 8, 1e-9) and M.ramp(30) == 8, "×8 from two seconds on")
local mono, prev = true, 0
for i = 0, 300 do
  local r = M.ramp(i / 100)
  if r < prev - 1e-12 then mono = false end
  prev = r
end
ok(mono, "the ramp never falls back while a drag goes on")
ok(M.ramp(0.75) > 1 and M.ramp(0.75) < 3, "…and eases between its steps rather than jumping")
-- k = 0.6 % of orbital speed per pixel at the start
ok(near(M.dragDv(1, 0, 1000), 6.0, 1e-9), "a pixel at the start is 0.6 % of a 1000 m/s orbit: 6 m/s")
ok(near(M.dragDv(1, 2.5, 1000), 48.0, 1e-9), "…×8 deep into the drag")
ok(near(M.dragDv(-10, 0, 1000), -60.0, 1e-9), "dragging back along the handle takes Δv off")
ok(near(M.dragDv(1, 0, 1000, M.mods(true, false)), 3.0, 1e-9), "SHIFT halves")
ok(near(M.dragDv(1, 0, 1000, M.mods(false, true)), 30.0, 1e-9), "CTRL ×5")
ok(M.dragDv(1, 0, 0) > 0, "a craft barely moving still edits (the speed floor)")
-- a 3,000 m/s plan does not need a metre of mouse: 3 s of steady drag at 60 fps
do
  local px_per_frame, dv, px, t = 2, 0, 0, 0
  while dv < 3000 and t < 10 do
    dv = dv + M.dragDv(px_per_frame, t, 2200)
    px, t = px + px_per_frame, t + 1 / 60
  end
  ok(dv >= 3000 and px < 600, string.format("3,000 m/s on a 2,200 m/s orbit in %d px of drag (%.1f s)", px, t))
end
ok(near(M.scrollDv(1, 1000), 10.0, 1e-9) and near(M.scrollDv(-2, 1000), -20.0, 1e-9),
  "a wheel notch over a handle is ±1 % of orbital speed")

-- ── 2. THE SLIDE'S CLAMP (F4) ───────────────────────────────────────────────
ok(M.clampT(NOW - 50, NOW) == NOW + 1, "a node slid behind you stops at now + 1 s")
ok(M.clampT(NOW + 0.2, NOW) == NOW + 1, "…and so does one slid to just ahead")
ok(M.clampT(NOW + 300, NOW, NOW + 1000) == NOW + 300, "inside the path it goes where it was put")
ok(M.clampT(NOW + 5000, NOW, NOW + 1000) == NOW + 1000, "…and not past the path's end")
ok(M.clampT(NOW - 5, NOW, NOW - 10) == NOW + 1, "never behind now + 1 s, even past a stale path's end")

-- ── 3. ±1 ORBIT (F6) ────────────────────────────────────────────────────────
ok(M.shiftOrbits(NOW + 300, 1000, 1, NOW) == NOW + 1300, "+1 orbit is one period later")
ok(M.shiftOrbits(NOW + 1300, 1000, -1, NOW) == NOW + 300, "−1 orbit is one period earlier")
local t_no, why = M.shiftOrbits(NOW + 300, 1000, -1, NOW)
ok(t_no == nil and why ~= nil, "−1 orbit is refused when that would be behind you (" .. tostring(why) .. ")")
ok(M.shiftOrbits(NOW + 300, nil, 1, NOW) == nil, "…and ±1 orbit on an escape (no period)")

-- ── 4. THE BURN FRAME AND ITS RE-EXPRESSION ─────────────────────────────────
do
  local B = M.basis(1000, 0, 0, 0, 30, 0)  -- on +x, moving +y: normal +z, radial out +x
  ok(near(B.px, 0, 1e-9) and near(B.py, 1, 1e-9), "prograde is along the motion")
  ok(near(B.nz, 1, 1e-9), "normal is along r × v")
  ok(near(B.rx, 1, 1e-9), "radial out points away from the body")
  local x, y, z = M.burnWorld(B, 10, 2, -3)
  local a, b, c = M.components(B, x, y, z)
  ok(near(a, 10, 1e-9) and near(b, 2, 1e-9) and near(c, -3, 1e-9), "components → world → components round-trips")
  local pe, ap, per = M.conic(1000, 0, 0, 0, math.sqrt(4e6 / 1000), 0, 4e6)
  ok(near(pe, 1000, 1e-3) and near(ap, 1000, 1e-3) and per > 0, "a circular orbit: Pe = Ap = r, with a period")
  local pe2, ap2 = M.conic(1000, 0, 0, 0, math.sqrt(2 * 4e6 / 1000) * 1.01, 0, 4e6)
  ok(near(pe2, 1000, 1e-6) and ap2 == nil, "past escape speed: a periapsis and no apoapsis")
end

-- ── 5. THE GIZMO, DRIVEN FRAME BY FRAME ─────────────────────────────────────
-- A circular path of radius 1000 about a body at the origin, in the screen
-- plane: point k at angle k·2π/100, time ta + 10k (a period of 1000 s).
local R, STEP, NPT = 1000.0, 10.0, 141
local function path()
  local rpts, anch = {}, {}
  for k = 0, NPT - 1 do
    local a = k * 2 * math.pi / 100
    rpts[#rpts + 1] = R * math.cos(a)
    rpts[#rpts + 1] = R * math.sin(a)
    rpts[#rpts + 1] = 0
    anch[#anch + 1] = 1
  end
  return { rpts = rpts, anch = anch, enc = {}, t0 = -10, ta = NOW - 10, step = STEP }
end
local function at_time(t)          -- the path's screen point at sim time t
  local a = (t - (NOW - 10)) / STEP * 2 * math.pi / 100
  return R * math.cos(a), R * math.sin(a)
end
local bodies = { { name = "P", x = 0, y = 0, z = 0, mu = 4e6, radius = 500 } }
local function px_at(_, _, _, px) return px end   -- 1 world unit = 1 pixel
local function frame(dt)
  env.time = env.time + (dt or 1 / 60)
  env.mnvFrame(bodies, px_at, 1.0, { period = 1000 }, 63.2)
end
env.mnvPaths(path(), nil)
env.mnvSet(nil)

-- F1: hover the line, click it: a node there, at that time, 0 Δv
MX, MY = at_time(NOW + 300)
MX, MY = MX + 6, MY + 3       -- a few pixels off the line
frame()
local G = env.mnvGizmo()
ok(env.GZ.hover ~= nil and near(env.GZ.hover.t, NOW + 300, 2.0), "hovering the orbit shows where a click would plan (t "
  .. tostring(env.GZ.hover and env.GZ.hover.t - NOW) .. ")")
BTN[0] = true; frame(); BTN[0] = false; frame()
local S = env.mnvState()
ok(S and near(S.lead, 300, 2.0) and S.dv == 0, "a click on the orbit places a node there with 0 Δv (lead "
  .. tostring(S and S.lead) .. ")")
ok(S and S.n == 1, "…one node, kept in the node list")
G = env.mnvGizmo()
local wx, wy = at_time(S.t0)
ok(G and near(G.sx, wx, 3) and near(G.sy, wy, 3), "the disc is drawn on the line where it was clicked")

-- F4: drag the disc behind the craft → it stops at now + 1 s
env.MNV.nodes[1].pro = 10.0
local B0 = env.MNV.nodes[1].mark and env.MNV.nodes[1].mark.B
MX, MY = G.sx, G.sy
BTN[0] = true; frame()
ok(env.GZ.drag and env.GZ.drag.kind == "slide", "pressing on the disc starts a slide")
MX, MY = at_time(NOW - 8)      -- a point of the path in the past
frame()
S = env.mnvState()
ok(S and S.t0 >= NOW + 1 - 1e-9 and S.t0 <= NOW + 1.5, "slid behind the craft, the node stops at now + 1 s (lead "
  .. tostring(S and S.lead) .. ")")
-- …then forward to +120 s: it follows the cursor, Δv kept, turned with the frame
MX, MY = at_time(NOW + 120)
frame()
S = env.mnvState()
ok(S and near(S.lead, 120, 2.0), "the slide follows the cursor along the orbit (lead " .. tostring(S and S.lead) .. ")")
ok(S and S.pro == 10.0 and S.nor == 0 and S.rad == 0, "the slide keeps the Δv components")
local B1 = env.MNV.nodes[1].mark and env.MNV.nodes[1].mark.B
if B0 and B1 then
  local x0, y0 = M.burnWorld(B0, 10, 0, 0)
  local x1, y1 = M.burnWorld(B1, 10, 0, 0)
  local ang = math.deg(math.acos(math.max(-1, math.min(1, (x0 * x1 + y0 * y1) / 100))))
  -- 300 s → 120 s on a 1000 s orbit is 180 s of arc: 64.8°
  ok(near(ang, 64.8, 4.0), string.format("…re-expressed in the new frame: the burn turned %.1f° with the orbit (64.8)", ang))
else
  ok(false, "the slide left a burn frame on the node")
end
MX, MY = at_time(NOW + 99999)  -- off the end of the path
frame()
S = env.mnvState()
ok(S and S.t0 <= NOW - 10 + (NPT - 1) * STEP + 1e-6, "the slide never goes past the path's end")
BTN[0] = false; frame()
ok(env.GZ.drag == nil, "letting go ends the slide")

-- F3: drag the prograde handle outward along its stalk
MX, MY = at_time(NOW + 300)
BTN[0] = true; frame(); BTN[0] = false; frame()   -- re-place at +300 (Δv kept)
env.MNV.nodes[1].pro, env.MNV.nodes[1].nor, env.MNV.nodes[1].rad = 0, 0, 0
frame()
G = env.mnvGizmo()
local h = G and G.handles["pro+"]
ok(h and h.on, "the prograde handle is on screen")
if h then
  local dx, dy = h.x - G.sx, h.y - G.sy
  local l = math.sqrt(dx * dx + dy * dy)
  ok(near(l, 36, 0.5), string.format("its stalk is 36 px (%.1f)", l))
  dx, dy = dx / l, dy / l
  MX, MY = h.x, h.y
  BTN[0] = true; frame()
  ok(env.GZ.drag and env.GZ.drag.kind == "dv", "pressing on a handle starts a Δv drag")
  -- 4 px a frame along the stalk for half a second at 60 fps: ×1 the whole way
  for _ = 1, 29 do MX, MY = MX + dx * 4, MY + dy * 4; frame() end
  S = env.mnvState()
  local want = 29 * 4 * 0.006 * 63.2
  ok(S and near(S.pro, want, 0.05 * want) and near(S.nor, 0, 1e-9) and near(S.rad, 0, 1e-9),
    string.format("dragging prograde adds prograde only: %.2f m/s (want %.2f)", S and S.pro or -1, want))
  BTN[0] = false; frame()
  -- the retrograde handle dragged outward takes prograde off
  G = env.mnvGizmo()
  local r = G.handles["pro-"]
  MX, MY = r.x, r.y
  local rdx, rdy = (r.x - G.sx) / 36, (r.y - G.sy) / 36
  local before = env.mnvState().pro
  BTN[0] = true; frame()
  for _ = 1, 10 do MX, MY = MX + rdx * 4, MY + rdy * 4; frame() end
  BTN[0] = false; frame()
  ok(env.mnvState().pro < before - 1, "dragging retrograde outward lowers prograde")
  ok(env.gizmoBusy == false or env.GZ.hot ~= nil, "gizmoBusy only while the cursor is on the node")
end

-- WHERE THE LOOPS OVERLAP (the path runs 1.4 orbits here): a spiral whose
-- second loop lies 1 px outside the first. Hovering ON the second loop still
-- picks the next orbit, not the one after it; and a slide along the first
-- loop stays on it across the overlap.
do
  local sp = path()
  for k = 0, NPT - 1 do
    local a = k * 2 * math.pi / 100
    local rr = R + k / 100
    sp.rpts[k * 3 + 1], sp.rpts[k * 3 + 2] = rr * math.cos(a), rr * math.sin(a)
  end
  env.mnvPaths(sp, nil)
  env.mnvSet(nil)
  local a = (NOW + 1250 - (NOW - 10)) / STEP * 2 * math.pi / 100
  local rr = R + (1260 / STEP) / 100
  MX, MY = rr * math.cos(a), rr * math.sin(a)   -- exactly on the +1250 s point
  frame()
  ok(env.GZ.hover and near(env.GZ.hover.t, NOW + 250, 2.0), string.format(
    "on overlapping loops the hover picks the next orbit (+%.0f s, not +1250)", env.GZ.hover and env.GZ.hover.t - NOW or -1))
  BTN[0] = true; frame(); BTN[0] = false; frame()
  G = env.mnvGizmo()
  MX, MY = G.sx, G.sy
  BTN[0] = true; frame()
  local lead_max = 0
  for f = 1, 40 do   -- slide forward 250 → 450 s along the first loop
    local tt = NOW + 250 + 5 * f
    local aa = (tt - (NOW - 10)) / STEP * 2 * math.pi / 100
    local r2 = R + ((tt - (NOW - 10)) / STEP) / 100
    MX, MY = r2 * math.cos(aa), r2 * math.sin(aa)
    frame()
    lead_max = math.max(lead_max, env.mnvState().lead)
  end
  BTN[0] = false; frame()
  ok(near(env.mnvState().lead, 450, 3.0) and lead_max < 460, string.format(
    "a slide stays on its loop (ended at +%.0f s, never past +%.0f)", env.mnvState().lead, lead_max))
  env.mnvPaths(path(), nil)
  MX, MY = at_time(NOW + 300)
  frame(); BTN[0] = true; frame(); BTN[0] = false; frame()
end

-- the wheel over the disc moves the node 1 % of the period a notch
G = env.mnvGizmo()
MX, MY = G.sx, G.sy
frame()
local t_before = env.mnvState().t0
SCROLL = 1; frame(); SCROLL = 0; frame()
ok(near(env.mnvState().t0 - t_before, 10.0, 1e-6), "a wheel notch over the disc is 1 % of the period")

-- F6: ±1 orbit from the walk's period, lock, zero, delete
env.mnvPaths(path(), { node = env.MNV.nodes[1], period = 1000.0, tabs = -1 })
local t1 = env.mnvState().t0
ok(env.mnvOrbits(1) == true and near(env.mnvState().t0, t1 + 1000, 1e-6), "+1 orbit adds the node's period")
ok(env.mnvOrbits(-1) == true and near(env.mnvState().t0, t1, 1e-6), "−1 orbit takes it back")
ok(env.mnvOrbits(-1) == false, "…and refuses to put it behind you")
-- (±1 orbit leaves the node for the next walk to place: put it back by a click)
env.mnvPaths(path(), nil)
MX, MY = at_time(NOW + 300)
frame(); BTN[0] = true; frame(); BTN[0] = false; frame()
env.mnvLock(true)
G = env.mnvGizmo()
local pro0 = env.mnvState().pro
h = G.handles["pro+"]
MX, MY = h.x, h.y
BTN[0] = true; frame()
for _ = 1, 10 do MX = MX + 4; MY = MY + 4; frame() end
BTN[0] = false; frame()
ok(env.mnvState().pro == pro0 and env.mnvState().locked, "a locked node ignores handle drags")
ok(env.mnvZero() == false, "…and won't zero")
env.mnvLock(false)
ok(env.mnvZero() == true and env.mnvState().dv == 0, "Zero ΔV zeroes it, unlocked")

-- ── 6. WARP TO NODE (F8) ────────────────────────────────────────────────────
ok(M.landing(1000, 40) == 970, "warp lands half the burn and 10 s before the node")
ok(M.warpStep(1e6, { 1, 5, 10, 50, 100, 1000, 10000 }, math.huge, 1 / 60) == 10000, "far out, the top of the ladder")
ok(M.warpStep(1e6, { 1, 5, 10, 50, 100, 1000, 10000 }, 100, 1 / 60) == 100, "…under the galaxy's ceiling")
ok(M.warpStep(1.0, { 1, 5, 10, 50, 100, 1000, 10000 }, math.huge, 1 / 60) == 1, "close in, ×1: arrived")
local VC = { piloting = true, valid = true, throttle = 0, node = { valid = true },
             tele = { thrust = 50, mass = 5, fuel_t = 2, burn_s = 100 },
             evaBlocksWarp = function() return false end, warpSay = function(m) said[#said + 1] = m end }
SCRIPTS.vessel_controller = VC
local m = env.mnvSet({ t0 = NOW + 200000, pro = 300, nor = 0, rad = 0, burned = 0 })
local tb = M.burnSecs(VC.tele, 300)
local land = M.landing(m.t0, tb)
VC.throttle = 0.5
ok(env.warpToNode() == false and env.WARPTO == nil, "warp to node is refused with the throttle open")
VC.throttle = 0
VC.evaBlocksWarp = function() return true end
ok(env.warpToNode() == false, "…and with crew on EVA in space")
VC.evaBlocksWarp = function() return false end
ok(env.warpToNode() == true and env.warpingToNode(), "…and runs on a coast with everyone aboard")
-- frames outrun ticks two to one: a warp request shows up a frame or two late
local top, frames, over, lies = 1, 0, false, 0
local seen = WARP
local chip_said = false
SCRIPTS.warp_chip = { say = function() chip_said = true end }
while env.WARPTO and frames < 100000 do
  local dt = 1 / 60
  if frames % 2 == 0 then
    NOW = NOW + WARP * dt * 2
    WARP_TICK()
  end
  -- warp_chip's rule: a drop nobody said in the frame it shows up is "the physics"
  if WARP < seen - 0.001 and not chip_said then lies = lies + 1 end
  seen = WARP
  chip_said = false
  frames = frames + 1
  env.warpDrive(dt)
  top = math.max(top, WARP)
  if NOW > land + 1e-6 then over = true end
end
ok(top == 10000, "it climbed the ladder to ×" .. top)
ok(not over and WARP == 1, "it never warps past the landing, and ends at ×1")
ok(lies == 0, "every step down was said as it showed up (" .. lies .. " unexplained drops)")
print(string.format("  warp to node: 200,000 s out, top ×%d, %d frames, landed %.2f s before the mark (burn %.1f s)",
  top, frames, land - NOW, tb))
ok(NOW <= land and land - NOW < 3.0, string.format("it lands %.2f s before node − burn/2 − 10 s (burn %.1f s)", land - NOW, tb))
ok(m.t0 - tb / 2 - NOW >= 10 and m.t0 - tb / 2 - NOW < 13.0, string.format("the burn starts %.1f s after the warp ends", m.t0 - tb / 2 - NOW))
local function settle() for _ = 1, 4 do WARP_TICK(); env.warpDrive(1 / 60) end end
-- the stick drops the warp: warp to node lets go (it is theirs now)
m.t0 = NOW + 200000
env.warpToNode()
NOW = NOW + 1; env.warpDrive(1 / 60); WARP_TICK(); NOW = NOW + 1; env.warpDrive(1 / 60); WARP_TICK()
env.warpDrive(1 / 60)
ok(WARP == 10000, "(at the top of the ladder: ×" .. WARP .. ")")
WARP = 1
env.warpDrive(1 / 60)
ok(not env.warpingToNode() and env.WARPTO == nil, "a warp dropped by the controls ends warp to node")
env.warpToNode()
env.warpDrive(1 / 60); WARP_TICK()
VC.throttle = 1
env.warpDrive(1 / 60)
ok(not env.warpingToNode(), "opening the throttle stops it")
settle()
ok(env.WARPTO == nil and WARP == 1, "…and the warp goes back to ×1")
VC.throttle = 0
env.warpToNode()
env.warpDrive(1 / 60); WARP_TICK()
env.mnvDelete()
settle()
ok(env.WARPTO == nil and WARP == 1 and env.mnvState() == nil, "deleting the node stops the warp to it")

-- ── 7. the draw pass runs without a fault ───────────────────────────────────
env.mnvPaths(path(), nil)
env.mnvSet(nil)
MX, MY = at_time(NOW + 300)
frame(); BTN[0] = true; frame(); BTN[0] = false; frame()
local okd, err = pcall(env.mnvDraw, bodies, px_at, 1.0, VC)
ok(okd, "mnvDraw runs (" .. tostring(err) .. ")")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("MNVNODE SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print(string.format("MNVNODE SMOKE FAILURES (%d passed):", passed))
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
