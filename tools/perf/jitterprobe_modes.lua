-- ── jitter probe (tools/perf/jitterprobe.sh): third-person walking jitter ──
-- Spliced into a copy of perfbench.lua before its main (like feelprobe).
-- Playtest 2026-11-04: "When walking around I will jitter up and down in third
-- person." The crew walks (then sprints) away from the base in third person,
-- and EVERY FRAME, in lateUpdate after the camera has placed the view (and
-- again at the next update), this records against the home body read in the
-- same pass:
--   hA   the Astronaut node's drawn height (|pos - body|)
--   hT   its tick height (|tickPos - body|)
--   cam  the camera's height along the crew's up
--   head the Head bone's height along up (what the eye follows)
--   sy   the Head bone's screen y (px) — the jitter the player sees
--   rel  camera height minus head height (both drawn)
-- Each series' frame-to-frame jitter is its second difference
-- d2 = x[i+1] - 2 x[i] + x[i-1]; `JIT RESULT <phase> <series>` gives its rms,
-- p95 and max (mm, or px for sy). A smooth walk bob (~2 Hz, a few cm) has a
-- d2 of a fraction of a mm at 60+ fps; a jitter has d2 of its own amplitude.
-- jit_frames=1 prints every frame of the first second of each phase.

local function J(fmt, ...) P("JIT " .. fmt, ...) end
local REC = nil          -- { list = {...} } while recording
LATE = nil
local function sample(tag)
  local A = astro()
  local b = home()
  local pc = findScript("planet_camera")
  if not (A and b and pc and pc.node) then return nil end
  local ax, ay, az = A.x - b.x, A.y - b.y, A.z - b.z
  local hA = len(ax, ay, az)
  local u = { x = ax / hA, y = ay / hA, z = az / hA }
  local tp = A.tickPos
  local hT = tp and len(tp.x - b.x, tp.y - b.y, tp.z - b.z) or 0
  local cn = pc.node
  local cam = (cn.x - b.x) * u.x + (cn.y - b.y) * u.y + (cn.z - b.z) * u.z
  local head, sy = 0, 0
  local m
  for _, c in ipairs(A:children() or {}) do if c.name == "AstroModel" then m = c end end
  local an = m and m.animator and m:animator()
  local H = an and an.boneWorld and an:boneWorld("Head")
  if H then
    head = (H.x - b.x) * u.x + (H.y - b.y) * u.y + (H.z - b.z) * u.z
    if camera and camera.worldToScreen then
      local _, y = camera.worldToScreen(H.x, H.y, H.z)
      sy = y or 0
    end
  end
  local mh = m and ((m.worldPos.x - b.x) * u.x + (m.worldPos.y - b.y) * u.y + (m.worldPos.z - b.z) * u.z) or 0
  -- (builderperf) the skeleton under the model node, in the model's own frame:
  -- the Back bone (the hips' carrier) and the Head, across (x), up (y), along (z)
  local bx_, by_, bz_, hx_, hy_ = 0, 0, 0, 0, 0
  local Bk = an and an.boneWorld and an:boneWorld("Back")
  if m and Bk then local l = m:toLocal(Bk); bx_, by_, bz_ = l.x, l.y, l.z end
  if m and H then local l = m:toLocal(H); hx_, hy_ = l.x, l.y end
  local pw = findScript("planet_walker")
  local vs = pw and pw.vertState or {}
  local vu = (A.vx or 0) * u.x + (A.vy or 0) * u.y + (A.vz or 0) * u.z
  return { t = time, dt = DT or 0, hA = hA, hT = hT, cam = cam, head = head, sy = sy, rel = cam - head, mh = mh, tag = tag,
           bkx = bx_, bky = by_, bkz = bz_, hdx = hx_, hdy = hy_,
           drop = (pw and pw.feet and pw.feet.drop) or 0, gph = (pw and pw.gaitPhase) or 0,
           c = vs.contact and 1 or 0, ray = vs.ray and 1 or 0, slope = vs.slope or 0, pop = vs.pop or 0, snap = vs.snap or 0, vu = vu }
end
function lateUpdate(node, dt)
  if LATE then LATE(node, dt) end
end
local function d2stats(list, key, k)
  local v = {}
  for i = 2, #list - 1 do
    v[#v + 1] = math.abs(list[i + 1][key] - 2 * list[i][key] + list[i - 1][key]) * k
  end
  table.sort(v)
  if #v == 0 then return 0, 0, 0 end
  local s = 0
  for _, x in ipairs(v) do s = s + x * x end
  return math.sqrt(s / #v), v[math.max(1, math.floor(#v * 0.95))], v[#v]
end
local function record(phase, secs)
  local late, upd = {}, {}
  LATE = function(node, dt)
    DT = dt
    local s = sample("L")
    if s then late[#late + 1] = s end
  end
  local t0 = time
  while time - t0 < secs do
    yield()
    local s = sample("U")
    if s then upd[#upd + 1] = s end
  end
  LATE = nil
  local dts = {}
  for _, s in ipairs(late) do dts[#dts + 1] = s.dt end
  table.sort(dts)
  J("phase %s: %d late frames, %d update frames, dt median %.2f ms p95 %.2f ms", phase, #late, #upd,
    (dts[math.max(1, math.floor(#dts / 2))] or 0) * 1000, (dts[math.max(1, math.floor(#dts * 0.95))] or 0) * 1000)
  if (params.jit_frames or 0) > 0 then
    local t1 = upd[1] and upd[1].t or 0
    for i, s in ipairs(upd) do
      if s.t - t1 > 1.0 then break end
      J("F %s %3d t %.4f hA %.4f hT %.4f cam %.4f head %.4f sy %.1f | contact %d ray %d slope %.3f pop %.3f snap %.3f vu %.3f | bky %.4f drop %.4f ph %.3f",
        phase, i, s.t - t1, s.hA - upd[1].hA, s.hT - upd[1].hA, s.cam - upd[1].cam, s.head - upd[1].head, s.sy,
        s.c, s.ray, s.slope, s.pop, s.snap, s.vu, s.bky, s.drop, s.gph)
    end
  end
  for _, set in ipairs({ { "late", late }, { "update", upd } }) do
    for _, key in ipairs({ "hA", "hT", "mh", "cam", "head", "rel", "sy", "bkx", "bky", "bkz", "hdx", "hdy", "drop" }) do
      local k = key == "sy" and 1 or 1000
      local rms, p95, mx = d2stats(set[2], key, k)
      J("RESULT %s %s %-4s d2 rms %.3f p95 %.3f max %.3f %s", phase, set[1], key, rms, p95, mx, key == "sy" and "px" or "mm")
    end
  end
end

local function run_jitter()
  wait_ready(90)
  wait(2)
  clear_weather()
  local A = astro()
  local b = home()
  local pc = findScript("planet_camera")
  local pw = findScript("planet_walker")
  pc.firstPerson = false
  local u0 = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local bu = base_frame()
  -- away from the base's centre, along the ground
  local away = sub(u0, scl(bu, dot(u0, bu)))
  if len(away.x, away.y, away.z) < 1e-4 then away = cross(u0, { x = 0, y = 0, z = 1 }) end
  away = unit(away)
  if params.jit_side and params.jit_side ~= 0 then away = unit(cross(u0, away)) end
  pc.face(away.x, away.y, away.z, -0.25)
  wait(1.0)
  record("stand", 2.0)
  pw.steer(1, 0, false)
  wait(1.5)
  -- A/B in the same run and the same ground: the slope off the contact's
  -- normal (slope_ray 0, the old rule), then off the down ray (the fix)
  if (params.jit_ab or 0) > 0 then
    -- the old rules: the slope off the contact's normal, every contact's
    -- climb kept up to step_pop
    pw.params.slope_ray, pw.params.kerb_pop = 0, 0
    record("walk_old", 5.0)
    pw.params.slope_ray, pw.params.kerb_pop = 1, 1
  end
  record("walk", 6.0)
  pw.steer(1, 0, true)
  wait(1.0)
  if (params.jit_ab or 0) > 0 then
    pw.params.slope_ray, pw.params.kerb_pop = 0, 0
    record("sprint_old", 4.0)
    pw.params.slope_ray, pw.params.kerb_pop = 1, 1
  end
  record("sprint", 5.0)
  pw.steer(nil)
  wait(1.5)
  record("stop", 2.0)
  -- (builderperf) LANDINGS: a standing jump, then a running one. Every frame
  -- in lateUpdate: the head's height over the crew's drawn centre (the
  -- skeleton and the model's dip together); the steepest fall of it over any
  -- 3 frames and over 0.1 s, and its range.
  for _, run in ipairs({ { "land_stand", nil }, { "land_run", 1 } }) do
    local list = {}
    LATE = function(node, dt)
      local s2 = sample("L")
      if s2 then s2.hd = s2.head - s2.hA; list[#list + 1] = s2 end
    end
    if run[2] then pw.steer(1, 0, false); wait(1.2) end
    pw.steer(run[2] or 0, 0, false, true)
    wait(2.2)
    pw.steer(nil)
    LATE = nil
    local worst3, worst01, low, top = 0, 0, 1e9, -1e9
    for i = 1, #list do
      local h = list[i].hd
      if h < low then low = h end
      if h > top then top = h end
      if i > 3 then worst3 = math.max(worst3, list[i - 3].hd - h) end
      local j = i
      while j > 1 and list[i].t - list[j - 1].t <= 0.1 do j = j - 1 end
      worst01 = math.max(worst01, list[j].hd - h)
    end
    J("RESULT %s head over centre: range %.3f m, steepest drop %.3f m in 3 frames, %.3f m in 0.1 s (%d frames)",
      run[1], top - low, worst3, worst01, #list)
    if (params.jit_frames or 0) > 0 then
      for i, s2 in ipairs(list) do J("L %s %3d t %.3f hd %.4f mh %.4f", run[1], i, s2.t - list[1].t, s2.hd, s2.mh - s2.hA) end
    end
    wait(1.0)
  end
end

-- ── medself: the Medkit used on yourself, from the front and the side ──────
-- (playtest 2026-11-04: "using the medkit animation has your arms inside your
-- body"). The active crew member is hurt, given a Medkit and treats
-- themselves; pictures mid-treatment in third person (user://jitshots/), and
-- the hands' distance in front of the capsule's centre along the body's
-- forward, both read in lateUpdate's pass.
local function jshot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://jitshots/" .. nm .. ".png", bytes); J("SHOT %s", nm)
    else J("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then J("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end
local function run_medself()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C, inv, H = findScript("crew"), findScript("inventory"), findScript("item_hand")
  local pc = findScript("planet_camera")
  local id = C.activeId()
  inv.addItem("crew:" .. id, "medkit", 2)
  C.hurt(id, 0.4, "impact", "a probe's fall")
  wait(0.5)
  H.hold("medkit")
  wait(1.0)
  pc.firstPerson = false
  local A = astro()
  local m
  for _, c in ipairs(A:children() or {}) do if c.name == "AstroModel" then m = c end end
  local ok, why = C.treat(id)
  J("self treat %s %s", tostring(ok), tostring(why))
  local worst = { r = 9, l = 9 }
  LATE = function()
    local an = m and m:animator()
    if not (an and C.treating()) then return end
    local o = m:toWorld(vec3(0, 0, 0))
    local F = (m:toWorld(vec3(0, 0, 1)) - o):normalized()
    for side, bone in pairs({ r = "Hand.Right", l = "Hand.Left" }) do
      local h = an:boneWorld(bone)
      if h then
        local f = (h - vec3(A.x, A.y, A.z)):dot(F)
        if f < worst[side] then worst[side] = f end
      end
    end
  end
  wait(0.8)
  local o = m:toWorld(vec3(0, 0, 0))
  local F = (m:toWorld(vec3(0, 0, 1)) - o):normalized()
  local Rt = (m:toWorld(vec3(-1, 0, 0)) - o):normalized()
  pc.face(-F.x + Rt.x * 0.5, -F.y + Rt.y * 0.5, -F.z + Rt.z * 0.5, -0.15)
  wait(0.4)
  jshot("medself_front")
  pc.face(-Rt.x, -Rt.y, -Rt.z, -0.1)
  wait(0.4)
  jshot("medself_side")
  pc.face(F.x - Rt.x * 0.6, F.y - Rt.y * 0.6, F.z - Rt.z * 0.6, -0.35)
  wait(0.3)
  jshot("medself_back")
  LATE = nil
  J("RESULT medself hands in front of the capsule's centre (min along forward): right %.3f m, left %.3f m (suit front ~0.17)",
    worst.r, worst.l)
  wait_for(function() return C.treating() == nil end, 8, "the self-treat")
end

-- ── fpsoak: first-person jitter over a long session (playtest 2026-11-09) ──
-- "first person models jitter, worse the longer you play, and push the player
-- around slightly." First person, the Medkit in hand (a view model on the
-- camera), cycles of standing `fp_stand` s and walking `fp_walk` s (out and
-- back, so the crew stays near the base) for `fp_secs` s; `fp_warp` > 0 adds a
-- time warp of that many real seconds between cycles, so game time (the
-- planet's place on its rails) ages far faster than the wall clock. Every
-- frame, in lateUpdate (after the camera placed the view), against the home
-- body read in the same pass:
--   eye   the camera's height over the crew's drawn centre, along up (m)
--   eyeh  the camera's offset from the crew across up (m)
--   vmx/vmy/vmz  the view model's world offset from the camera, in the
--         camera's own right/up/forward axes (what the player sees it do)
--   vml   the view model's local x (tool_belt writes it: sway, bob)
--   turn  the view direction's turn this frame (mrad; the probe never turns it)
--   hA    the crew's drawn distance from the body's centre
-- and per window: d2 jitter (rms / max), the crew's drift over the ground
-- (body-relative, drawn AND tick), |world| of the crew, the body and the
-- camera, the gap between space.body() and the planet node's drawn place, how
-- far the crew's tick pose is from its drawn pose, and how many floating-
-- origin recentres happened (a frame jump > 50 m of the crew's world position
-- that its body-relative position did not make).
local FPS = { rebases = 0 }
local function fp_sample(vmn)
  local A, b, pc = astro(), home(), findScript("planet_camera")
  if not (A and b and pc and pc.node and pc.node.valid) then return nil end
  local cn = pc.node
  local ax, ay, az = A.x - b.x, A.y - b.y, A.z - b.z
  local hA = len(ax, ay, az)
  local u = { x = ax / hA, y = ay / hA, z = az / hA }
  local dx, dy, dz = cn.x - A.x, cn.y - A.y, cn.z - A.z
  local eye = dx * u.x + dy * u.y + dz * u.z
  local ex, ey, ez = dx - u.x * eye, dy - u.y * eye, dz - u.z * eye
  local s = { t = time, hA = hA, eye = eye, eyeh = len(ex, ey, ez), ax = ax, ay = ay, az = az,
              fx = pc.fwd_x or 0, fy = pc.fwd_y or 0, fz = pc.fwd_z or 0,
              wA = len(A.x, A.y, A.z), wB = len(b.x, b.y, b.z), wC = len(cn.x, cn.y, cn.z), Ax = A.x, Ay = A.y, Az = A.z }
  local tp = A.tickPos
  if tp then s.tx, s.ty, s.tz = tp.x - b.x, tp.y - b.y, tp.z - b.z; s.tgap = len(tp.x - A.x, tp.y - A.y, tp.z - A.z) end
  local pn = find(b.name)
  if pn and pn.valid then s.bgap = len(pn.x - b.x, pn.y - b.y, pn.z - b.z) end
  if vmn and vmn.valid then
    local w = vmn.worldPos
    local r, up = cn:worldRight(), cn:worldUp()
    local f = cn:worldForward()
    local ox, oy, oz = w.x - cn.x, w.y - cn.y, w.z - cn.z
    s.vmx = ox * r.x + oy * r.y + oz * r.z
    s.vmy = ox * up.x + oy * up.y + oz * up.z
    s.vmz = ox * f.x + oy * f.y + oz * f.z
    s.vml = vmn.x
    s.vis = vmn.visible
  end
  return s
end
local function fp_stats(list, key, k)
  local v = {}
  for i = 2, #list - 1 do
    local a, m, c = list[i - 1][key], list[i][key], list[i + 1][key]
    if a and m and c then v[#v + 1] = math.abs(c - 2 * m + a) * k end
  end
  table.sort(v)
  if #v == 0 then return 0, 0 end
  local s = 0
  for _, x in ipairs(v) do s = s + x * x end
  return math.sqrt(s / #v), v[#v]
end
local function fp_report(tag, list, src)
  if #list < 3 then J("FPS %s %s: no frames", tag, src); return end
  local a, z = list[1], list[#list]
  local drift = len(z.ax - a.ax, z.ay - a.ay, z.az - a.az)
  local tdrift = (a.tx and z.tx) and len(z.tx - a.tx, z.ty - a.ty, z.tz - a.tz) or -1
  local tg, bg, eyemin, eyemax, turnmax = 0, 0, 1e9, -1e9, 0
  for i, s in ipairs(list) do
    tg = math.max(tg, s.tgap or 0); bg = math.max(bg, s.bgap or 0)
    eyemin, eyemax = math.min(eyemin, s.eye), math.max(eyemax, s.eye)
    if i > 1 then
      local l = list[i - 1]
      turnmax = math.max(turnmax, math.acos(math.max(-1, math.min(1, s.fx * l.fx + s.fy * l.fy + s.fz * l.fz))) * 1000)
    end
  end
  local r = {}
  for _, key in ipairs({ "eye", "eyeh", "hA", "vmx", "vmy", "vmz", "vml" }) do
    local rms, mx = fp_stats(list, key, 1000)
    r[#r + 1] = string.format("%s %.2f/%.2f", key, rms, mx)
  end
  J("FPS %-8s %s t %6.0f game %10.0f n %4d | d2 rms/max mm: %s | turn max %.2f mrad | eye %.3f..%.3f | drift %.3f m (tick %.3f) | |crew| %.3e |body| %.3e | tick-drawn max %.2f m | body-node gap max %.3f m | vm %s",
    tag, src, time, space.time and space.time() or -1, #list, table.concat(r, " "), turnmax, eyemin, eyemax, drift, tdrift,
    z.wA, z.wB, tg, bg, tostring(z.vis))
end
local function fp_window(tag, secs, steer)
  local ul = {}
  local vmn = find("ItemMedkitFP")
  local t0, last_t, dtmax, slow = time, time, 0, 0
  local vmax = 0
  while time - t0 < secs do
    if steer then steer(time - t0) end
    yield()
    local d = time - last_t
    last_t = time
    dtmax = math.max(dtmax, d)
    if d > 0.09 then slow = slow + 1 end
    local s = fp_sample(vmn)
    if s then
      ul[#ul + 1] = s
      if s.vmx and ul[1].vmx then vmax = math.max(vmax, len(s.vmx - ul[1].vmx, s.vmy - ul[1].vmy, s.vmz - ul[1].vmz)) end
    end
  end
  fp_report(tag, ul, "upd")
  J("FPS %-8s frames %.1f fps, longest frame %.0f ms, %d frames over 90 ms | the view model's most travel from its first place %.1f mm",
    tag, #ul / math.max(secs, 1e-3), dtmax * 1000, slow, vmax * 1000)
end
local function run_fpsoak()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C, inv, H = findScript("crew"), findScript("inventory"), findScript("item_hand")
  local pc = findScript("planet_camera")
  local pw = findScript("planet_walker")
  if C and C.setSafety then C.setSafety("invincible") end
  if C and inv then inv.addItem("crew:" .. C.activeId(), "medkit", 1) end
  local A, b = astro(), home()
  local u0 = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local bu = base_frame()
  local away = sub(u0, scl(bu, dot(u0, bu)))
  if len(away.x, away.y, away.z) < 1e-4 then away = cross(u0, { x = 0, y = 0, z = 1 }) end
  away = unit(away)
  pc.firstPerson = true
  wait(0.5)
  local ok, why = false, "no item_hand"
  if H and H.hold then ok, why = H.hold("medkit") end
  J("fpsoak: hold medkit %s %s", tostring(ok), tostring(why))
  local secs, stand, walk, warp = params.fp_secs or 300, params.fp_stand or 20, params.fp_walk or 12, params.fp_warp or 0
  local t0 = time
  local k = 0
  while time - t0 < secs do
    k = k + 1
    local A2, b2 = astro(), home()
    local uu = unit(sub({ x = A2.x, y = A2.y, z = A2.z }, { x = b2.x, y = b2.y, z = b2.z }))
    local dir = (k % 2 == 1) and away or scl(away, -1)
    dir = unit(sub(dir, scl(uu, dot(dir, uu))))
    pc.firstPerson = true
    pc.face(dir.x, dir.y, dir.z, -0.05)
    pw.steer(0, 0, false)
    wait(1.0)
    fp_window("stand" .. k, stand, function() pw.steer(0, 0, false) end)
    fp_window("walk" .. k, walk, function() pw.steer(1, 0, false) end)
    pw.steer(0, 0, false)
    -- looking round (the mouse): the view swings ±20° at 0.5 Hz, standing
    -- (after the walk's run-out has settled: its 0.3 m is not a drift)
    wait(1.5)
    local lu = unit(sub({ x = astro().x, y = astro().y, z = astro().z }, { x = home().x, y = home().y, z = home().z }))
    local d0 = unit(sub(dir, scl(lu, dot(dir, lu))))
    local sd = unit(cross(lu, d0))
    fp_window("look" .. k, 8, function(t)
      local a = 0.35 * math.sin(t * math.pi)
      pw.steer(0, 0, false)
      pc.face(d0.x * math.cos(a) + sd.x * math.sin(a), d0.y * math.cos(a) + sd.y * math.sin(a), d0.z * math.cos(a) + sd.z * math.sin(a), -0.05)
    end)
    if warp > 0 then
      for _ = 1, 6 do tap("."); wait(0.3) end
      local top = space.warp()
      wait(warp)
      for _ = 1, 8 do if space.warp() <= 1.001 then break end; tap(","); wait(0.3) end
      if space.warp() > 1.001 and space.setWarp then pcall(space.setWarp, 1) end
      J("fpsoak: warped at %.0fx for %.0f s", top, warp)
    end
  end
  pw.steer(nil)
  J("DONE fpsoak")
end
