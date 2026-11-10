-- ── first-person hands probe (tools/perf/fphandprobe.sh) ────────────────────
-- Spliced into a copy of perfbench.lua before its main (like jitterprobe).
-- Playtest 2026-11-09d: "the fast walking arm jitter in first person" and
-- "the first person hands should be more immersive and use things like ik".
--
-- fpjit: a yard of static slabs 130 m out (a flat floor and a 10° ramp), the
-- crew in first person with the Terrain Laser, then the Medkit, in hand:
-- stand, walk and sprint on the floor, sprint and walk up the ramp. EVERY
-- FRAME (in update, after the yield: the pose the last frame drew), against
-- the camera's own axes read in the same pass:
--   hx hy hz   the right hand (or the view model) in the camera's frame (m)
--   sx sy      where that lands on a 1080-line screen (px), with the field of
--              view it is drawn at (the view-model camera's or the main one's)
--   eye        the camera's distance from the body's centre (the view's bob)
-- Each series' frame-to-frame jerk is its second difference
-- d2 = x[i+1] - 2 x[i] + x[i-1] (mm, px): `FH RESULT <tool> <phase> <series>`
-- gives its rms, p95 and max, and `bounce` the hand's vertical travel (mm,
-- p95 - p5) and its rate (crossings of its mean a second / 2 = Hz).
--
-- fpshots: picture sequences (user://fpshots/, 1280x720, no UI) of every
-- first-person action, several frames each: each tool idle, aimed and
-- working, each item, the self-treat, a reach to press something, the kit
-- ladder, looking down at the body, sprinting.
FH = {}
local FH = FH
FH.Y = {}
function FH.L(fmt, ...) P("FH " .. fmt, ...) end

-- the yard (walkprobe's way: static PaveSlab boxes on a raised floor)
function FH.W_(p) local b = home(); return { x = b.x + p.x, y = b.y + p.y, z = b.z + p.z } end
function FH.yard(f, l, u)
  local Y = FH.Y
  return { x = Y.O.x + Y.F.x * f + Y.L.x * l + Y.U.x * u, y = Y.O.y + Y.F.y * f + Y.L.y * l + Y.U.y * u,
           z = Y.O.z + Y.F.z * f + Y.L.z * l + Y.U.z * u }
end
function FH.box(name, f, l, u, sl, su, sf, tilt, col, prefab)
  local Y = FH.Y
  tilt = tilt or 0
  local c = FH.yard(f, l, u)
  local up = unit(sub(scl(Y.U, math.cos(tilt)), scl(Y.F, math.sin(tilt))))
  local fw = unit({ x = Y.F.x * math.cos(tilt) + Y.U.x * math.sin(tilt), y = Y.F.y * math.cos(tilt) + Y.U.y * math.sin(tilt),
                    z = Y.F.z * math.cos(tilt) + Y.U.z * math.sin(tilt) })
  local w = FH.W_(c)
  spawn(prefab or "PaveSlab", vec3(w.x, w.y, w.z), function(inst)
    inst:setUp(vec3(up.x, up.y, up.z), vec3(fw.x, fw.y, fw.z))
    if not prefab then
      inst.scale = vec3(sl, su, sf)
      if inst.setPrimitive then pcall(inst.setPrimitive, inst, "Cube", col or { 0.42, 0.41, 0.38 }) end
    end
    inst.x, inst.y, inst.z = c.x, c.y, c.z
    inst.name = "FH " .. name
  end, Y.pn)
end
function FH.build_yard()
  local Y = FH.Y
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local best
  for k = 0, 11 do
    local ang = k * math.pi / 6
    local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
    local dir = dir_at(u, t, 130, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 200)
    local wet = gr and cl and cl.seaDepth and cl.seaDepth(b.x + dir.x * (gr + 1), b.y + dir.y * (gr + 1), b.z + dir.z * (gr + 1))
    if gr and not (wet and wet > 0) then best = { dir = dir, t = t, gr = gr }; break end
  end
  if not best then FH.L("no dry site"); return false end
  local U = best.dir
  local F = unit(sub(best.t, scl(U, dot(best.t, U))))
  local L = unit(cross(U, F))
  local top = best.gr
  for fi = -16, 80, 8 do
    for li = -16, 16, 8 do
      local d = unit({ x = U.x * best.gr + F.x * fi + L.x * li, y = U.y * best.gr + F.y * fi + L.y * li, z = U.z * best.gr + F.z * fi + L.z * li })
      local g = ground_r(b, d.x, d.y, d.z, best.gr + 120)
      if g then
        local h = g * dot(d, U) - best.gr
        if h > top - best.gr then top = best.gr + h end
      end
    end
  end
  Y.U, Y.F, Y.L = U, F, L
  Y.O = scl(U, top + 1.2)
  local V = findScript("vessel_spawner")
  Y.pn = V and V.planetNode and V.planetNode() or find(b.name)
  -- the floor (0.6 m thick, its top at u = 0), f -16..80, l -16..16
  FH.box("floor", 32, 0, -0.3, 32, 0.6, 96, 0, { 0.36, 0.36, 0.34 })
  -- the ramp: 10°, 50 m long, 6 m wide, its foot at f = 0 on lane l = 10
  local a, Ls = math.rad(10), 50
  FH.box("ramp", Ls / 2 * math.cos(a) + 0.25 * math.sin(a), 10, Ls / 2 * math.sin(a) - 0.25 * math.cos(a), 6, 0.5, Ls, a,
    { 0.48, 0.44, 0.38 })
  -- a wall to press against (the reach), lane l = -10, at f = 6
  FH.box("wall", 6.25, -10, 1.5, 4, 3.0, 0.5, 0, { 0.5, 0.46, 0.4 })
  FH.L("yard on %s, floor %.2f m over the ground", b.name, top + 1.2 - best.gr)
  return true
end
function FH.put(f, l, u)
  local A = astro()
  local p = FH.W_(FH.yard(f, l, u))
  A.x, A.y, A.z = p.x, p.y, p.z
  A.vx, A.vy, A.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(0.25) end
end
function FH.face(f, l, u, pitch)
  local Y = FH.Y
  local d = unit({ x = Y.F.x * f + Y.L.x * l + Y.U.x * u, y = Y.F.y * f + Y.L.y * l + Y.U.y * u, z = Y.F.z * f + Y.L.z * l + Y.U.z * u })
  findScript("planet_camera").face(d.x, d.y, d.z, pitch or -0.1)
end

-- one frame's sample: the hand in the camera's frame and on the screen
FH.VM = { laser = "ToolLaserFP", gravgun = "ToolGravGunFP", surveyor = "ToolSurveyorFP", medkit = "ItemMedkitFP" }
function FH.sample(id)
  local pc = findScript("planet_camera")
  local cn = pc and pc.node
  if not (cn and cn.valid) then return nil end
  local r, u, f = cn:worldRight(), cn:worldUp(), cn:worldForward()
  local hx, hy, hz, fov, src
  local fb = findScript("fp_body", { quiet = true })
  local pr = fb and fb.probe
  if pr and pr.on and pr.t and math.abs(pr.t - time) < 0.2 then
    -- the IK'd hand of the body (fp_body publishes it in the camera's frame,
    -- read after its own reach, in the pass that placed the camera)
    hx, hy, hz, fov, src = pr.hx or pr.rx, pr.hy or pr.ry, pr.hz or pr.rz, pr.fov, "ik"
  else
    local vm = find(FH.VM[id] or "")
    if vm and vm.valid and vm.visible then
      local w = vm.worldPos
      local ox, oy, oz = w.x - cn.x, w.y - cn.y, w.z - cn.z
      hx, hy, hz = ox * r.x + oy * r.y + oz * r.z, ox * u.x + oy * u.y + oz * u.z, ox * f.x + oy * f.y + oz * f.z
      fov, src = 0.95, "vm"
    end
  end
  if not hx then return nil end
  local foc = 540 / math.tan(fov * 0.5)
  local A, b = astro(), home()
  local eye = len(cn.x - b.x, cn.y - b.y, cn.z - b.z)
  return { t = time, hx = hx, hy = hy, hz = hz, sx = hx / math.max(hz, 0.05) * foc, sy = hy / math.max(hz, 0.05) * foc,
           eye = eye, src = src, spd = len(A.vx or 0, A.vy or 0, A.vz or 0) }
end
function FH.d2(list, key, k)
  local v = {}
  for i = 2, #list - 1 do v[#v + 1] = math.abs(list[i + 1][key] - 2 * list[i][key] + list[i - 1][key]) * k end
  table.sort(v)
  if #v == 0 then return 0, 0, 0 end
  local s = 0
  for _, x in ipairs(v) do s = s + x * x end
  return math.sqrt(s / #v), v[math.max(1, math.floor(#v * 0.95))], v[#v]
end
function FH.bounce(list)
  local ys = {}
  local m = 0
  for _, s in ipairs(list) do ys[#ys + 1] = s.hy; m = m + s.hy end
  if #ys < 4 then return 0, 0 end
  m = m / #ys
  local cross = 0
  for i = 2, #list do if (list[i].hy - m) * (list[i - 1].hy - m) < 0 then cross = cross + 1 end end
  table.sort(ys)
  local secs = math.max(1e-3, list[#list].t - list[1].t)
  return (ys[math.max(1, math.floor(#ys * 0.95))] - ys[math.max(1, math.floor(#ys * 0.05))]) * 1000, cross / secs / 2
end
function FH.record(id, phase, secs, steer)
  local list = {}
  local t0 = time
  local lt, dts = time, {}
  while time - t0 < secs do
    if steer then steer(time - t0) end
    yield()
    dts[#dts + 1] = time - lt
    lt = time
    local s = FH.sample(id)
    if s then list[#list + 1] = s end
  end
  table.sort(dts)
  local sp = 0
  for _, s in ipairs(list) do sp = sp + s.spd end
  FH.L("phase %s %s: %d frames (%s), dt median %.2f ms, speed %.2f m/s", id, phase, #list, list[1] and list[1].src or "-",
    (dts[math.max(1, math.floor(#dts / 2))] or 0) * 1000, sp / math.max(1, #list))
  if (params.fp_frames or 0) > 0 then
    local t1 = list[1] and list[1].t or 0
    for i, s in ipairs(list) do
      if s.t - t1 > 1.5 then break end
      FH.L("F %s %s %3d t %.4f hx %.4f hy %.4f hz %.4f sx %.1f sy %.1f eye %.4f", id, phase, i, s.t - t1, s.hx, s.hy, s.hz, s.sx, s.sy,
        s.eye - list[1].eye)
    end
  end
  local fb = findScript("fp_body", { quiet = true })
  if fb then
    local sm = perf and perf.scriptMs or function() return -1 end
    FH.L("COST %s %-8s fp_body.afterCamera %.3f ms a frame (eased, wall) | perf.scriptMs fp_body %.3f tool_belt %.3f item_hand %.3f planet_camera %.3f",
      id, phase, fb.ms or -1, sm("fp_body"), sm("tool_belt"), sm("item_hand"), sm("planet_camera"))
  end
  if #list < 4 then FH.L("RESULT %s %s: no frames", id, phase); return end
  for _, key in ipairs({ "hx", "hy", "hz", "sx", "sy", "eye" }) do
    local k = (key == "sx" or key == "sy") and 1 or 1000
    local rms, p95, mx = FH.d2(list, key, k)
    FH.L("RESULT %s %-8s %-3s d2 rms %.3f p95 %.3f max %.3f %s", id, phase, key, rms, p95, mx, k == 1 and "px" or "mm")
  end
  local amp, hz = FH.bounce(list)
  FH.L("RESULT %s %-8s bounce %.1f mm at %.2f Hz", id, phase, amp, hz)
end

function FH.setup()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C, inv = findScript("crew"), findScript("inventory")
  if C and C.setSafety then C.setSafety("invincible") end
  if C and inv then
    inv.addItem("crew:" .. C.activeId(), "medkit", 2)
    for _, id in ipairs({ "laser", "gravgun", "surveyor", "repairkit", "gascan", "beacon" }) do
      local ok, n, why = pcall(inv.addItem, "crew:" .. C.activeId(), id, 1, { force = true })
      FH.L("add %s: %s %s", id, tostring(n), tostring(why))
    end
  end
  if not FH.build_yard() then return false end
  wait(1.5)
  local fb = findScript("fp_body", { quiet = true })
  if fb and fb.setEnabled then fb.setEnabled((params.fp_body or 1) > 0) end
  if fb and fb.probe then fb.probe.want = (params.fp_cost or 0) == 0 end
  FH.L("fp_body script %s, on %s", tostring(fb ~= nil), tostring(fb and fb.enabled))
  return true
end
function FH.hold(id)
  local H = findScript("item_hand")
  local ok, why = H.hold(id)
  FH.L("hold %s: %s %s", tostring(id), tostring(ok), tostring(why))
  wait(1.0)
end

function FH.run_jit()
  if not FH.setup() then return end
  local pc, pw = findScript("planet_camera"), findScript("planet_walker")
  for _, id in ipairs({ "laser", "medkit" }) do
    FH.put(-12, 0, 1.0)
    pc.firstPerson = true
    FH.face(1, 0, 0, -0.08)
    wait(0.6)
    FH.hold(id)
    FH.face(1, 0, 0, -0.08)
    wait(1.0)
    FH.record(id, "stand", 2.0, function() pw.steer(0, 0, false) end)
    FH.record(id, "walk", 4.0, function() pw.steer(1, 0, false) end)
    FH.put(-12, 0, 1.0)
    FH.face(1, 0, 0, -0.08)
    pw.steer(1, 0, true)
    wait(1.2)
    FH.record(id, "sprint", 5.0, function() pw.steer(1, 0, true) end)
    pw.steer(0, 0, false)
    wait(0.5)
    -- up the ramp
    FH.put(-6, 10, 1.0)
    FH.face(1, 0, 0, -0.08)
    wait(0.6)
    pw.steer(1, 0, true)
    wait(0.7)
    FH.record(id, "rampspr", 4.0, function() pw.steer(1, 0, true) end)
    pw.steer(0, 0, false)
    wait(0.4)
    FH.put(-6, 10, 1.0)
    FH.face(1, 0, 0, -0.08)
    wait(0.6)
    FH.record(id, "rampwalk", 5.0, function() pw.steer(1, 0, false) end)
    pw.steer(0, 0, false)
    wait(0.5)
  end
  pw.steer(nil)
  FH.L("DONE fpjit")
end

-- ── pictures ────────────────────────────────────────────────────────────────
function FH.shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = (params.fp_ui or 0) > 0, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://fpshots/" .. nm .. ".png", bytes); FH.L("SHOT %s", nm)
    else FH.L("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then FH.L("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end
-- n pictures `gap` s apart, `fn(i)` before each
function FH.seq(nm, n, gap, fn)
  for i = 1, n do
    if fn then fn(i) end
    wait(gap)
    FH.shot(string.format("%s_%d", nm, i))
  end
end
function FH.hands_line(tag)
  local fb = findScript("fp_body", { quiet = true })
  local pr = fb and fb.probe
  local vs = findScript("tool_belt").viewState or {}
  if vs.lreach then FH.L("REACH %s: shoulder to target r %.3f l %.3f m, twist %s", tag, vs.rreach or -1, vs.lreach, tostring(vs.twist_sign)) end
  if pr and pr.on then
    FH.L("HANDS %s: right (%.3f, %.3f, %.3f) left (%.3f, %.3f, %.3f) cam frame; err r %.3f l %.3f m; eye clear %.3f m; action %s; under %s",
      tag, pr.rx, pr.ry, pr.rz, pr.lx or 0, pr.ly or 0, pr.lz or 0, pr.rerr or -1, pr.lerr or -1, pr.clear or -1, tostring(pr.action), tostring(pr.under))
  end
end

function FH.run_shots()
  if not FH.setup() then return end
  local pc, pw, tb = findScript("planet_camera"), findScript("planet_walker"), findScript("tool_belt")
  local C = findScript("crew")
  -- fp_only: the sections to run, as digits (125 = sections 1, 2 and 5); 0 = all
  local only = tostring(math.floor(params.fp_only or 0))
  function FH.want(k) return only == "0" or only:find(tostring(k), 1, true) ~= nil end
  pc.firstPerson = true
  FH.put(-12, 0, 1.0)
  FH.face(1, 0, 0, -0.08)
  wait(1.0)
  -- 1. empty hands: ahead, looking down at the body, walking, sprinting
  if FH.want(1) then
    FH.hold(nil)
    FH.seq("empty_ahead", 1, 0.4)
    FH.face(1, 0, 0, -1.2)
    FH.seq("empty_down", 2, 0.5)
    FH.face(1, 0, 0, -0.75)
    FH.seq("empty_walkdown", 3, 0.15, function() pw.steer(1, 0, false) end)
    FH.face(1, 0, 0, -0.1)
    FH.seq("empty_sprint", 3, 0.13, function() pw.steer(1, 0, true) end)
    pw.steer(0, 0, false)
    wait(0.8)
  end
  -- 2. each tool: idle, looking down, firing at the floor, sprinting
  if FH.want(2) then
    for _, id in ipairs({ "laser", "gravgun", "surveyor" }) do
      FH.put(-12, 0, 1.0)
      FH.face(1, 0, 0, -0.08)
      FH.hold(id)
      FH.seq(id .. "_idle", 2, 0.3)
      FH.hands_line(id .. " idle")
      FH.face(1, 0, 0, -0.9)
      FH.seq(id .. "_down", 1, 0.5)
      FH.hands_line(id .. " down")
      FH.face(1, 0, 0, 0.6)
      FH.seq(id .. "_up", 1, 0.5)
      FH.face(1, 0, 0, -0.35)
      wait(0.3)
      tb.sim = { btn = { [0] = true } }
      FH.seq(id .. "_use", 3, 0.25, function() tb.sim = { btn = { [0] = true } } end)
      FH.hands_line(id .. " use")
      tb.sim = nil
      wait(0.5)
      FH.face(1, 0, 0, -0.08)
      FH.seq(id .. "_sprint", 3, 0.13, function() pw.steer(1, 0, true) end)
      pw.steer(0, 0, false)
      wait(0.6)
      -- against the wall: the hold pulls in instead of going through it
      FH.put(5.3, -10, 1.0)
      FH.face(1, 0, 0, -0.05)
      wait(0.6)
      FH.seq(id .. "_wall", 1, 0.4)
      FH.hands_line(id .. " wall")
    end
  end
  -- 3. items: each held, then the medkit on yourself
  if FH.want(3) then
    for _, id in ipairs({ "medkit", "repairkit", "gascan", "beacon" }) do
      FH.put(-12, 0, 1.0)
      FH.face(1, 0, 0, -0.1)
      FH.hold(id)
      FH.seq(id .. "_held", 2, 0.3)
      FH.face(1, 0, 0, -0.8)
      FH.seq(id .. "_down", 1, 0.4)
      FH.face(1, 0, 0, -0.1)
      FH.seq(id .. "_walk", 2, 0.2, function() pw.steer(1, 0, false) end)
      pw.steer(0, 0, false)
      FH.hands_line(id)
      wait(0.5)
    end
    FH.hold("medkit")
    if C and C.setSafety then C.setSafety("rescue") end
    if C and C.hurt then C.hurt(C.activeId(), 0.4, "impact", "a probe's fall") end
    if C and C.setSafety then C.setSafety("invincible") end
    wait(0.3)
    local ok, why = C.treat(C.activeId())
    FH.L("self treat %s %s", tostring(ok), tostring(why))
    FH.face(1, 0, 0, -0.5)
    FH.seq("medkit_self", 3, 0.5)
    FH.hands_line("medkit self")
    wait_for(function() return C.treating() == nil end, 10, "the self-treat")
  end
  -- 4. a reach: pressing the wall (E at what the crosshair is on)
  if FH.want(4) then
    FH.hold(nil)
    FH.put(5.45, -10, 1.0)
    FH.face(1, 0, 0, -0.15)
    wait(0.6)
    local fb = findScript("fp_body", { quiet = true })
    if fb and fb.press then FH.L("press: %s", tostring(fb.press())) end
    FH.seq("press", 4, 0.12)
    FH.hands_line("press")
    wait(0.8)
    FH.hold("laser")
    FH.face(1, 0, 0, -0.15)
    wait(0.4)
    if fb and fb.press then fb.press() end
    FH.seq("press_laser", 3, 0.14)
  end
  -- 5. looking round: hard turn, the hands stay with the view
  if FH.want(5) then
    FH.put(-12, 0, 1.0)
    FH.hold("laser")
    for i = 1, 4 do
      local a = i * 0.5
      FH.face(math.cos(a), math.sin(a), 0, -0.1)
      yield()
      yield()
      FH.shot("turn_" .. i)
    end
  end
  -- 6. the kit ladder: up it, empty-handed (hands on the rails)
  if FH.want(6) then
    FH.hold(nil)
    FH.box("KitLadder", 30, -4, 0, 1, 1, 1, 0, nil, "KitLadder_steel")
    wait(1.0)
    local L = find("FH KitLadder")
    local w1
    for _, c in ipairs((L and L:children()) or {}) do if c.name == "Wall 1" then w1 = c end end
    if w1 then
      local b = home()
      local function rel(p) return { x = p.x - b.x - FH.Y.O.x, y = p.y - b.y - FH.Y.O.y, z = p.z - b.z - FH.Y.O.z } end
      local pa, pb = rel(w1:toWorld(vec3(0, 0, -1.6))), rel(w1:toWorld(vec3(0, 0, 1.6)))
      local lo, hi = pa, pb
      if dot(pa, FH.Y.U) > dot(pb, FH.Y.U) then lo, hi = pb, pa end
      local d = unit(sub(hi, lo))
      local df, dl = dot(d, FH.Y.F), dot(d, FH.Y.L)
      local f0, l0 = dot(lo, FH.Y.F) - df * 1.6, dot(lo, FH.Y.L) - dl * 1.6
      FH.L("ladder: foot at f %.2f l %.2f, up along (%.2f, %.2f)", f0, l0, df, dl)
      FH.put(f0, l0, 1.0)
      FH.face(df, dl, 0, -0.45)
      wait(0.8)
      FH.seq("ladder", 6, 0.35, function(i) FH.hands_line("ladder " .. i); FH.face(df, dl, 0, -0.45); pw.steer(0.6, 0, false) end)
      FH.hands_line("ladder")
      pw.steer(0, 0, false)
    else
      FH.L("ladder: no Wall 1 (%s)", tostring(L))
    end
  end
  pw.steer(nil)
  FH.L("DONE fpshots")
end
