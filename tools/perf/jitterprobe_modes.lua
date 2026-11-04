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
  local pw = findScript("planet_walker")
  local vs = pw and pw.vertState or {}
  local vu = (A.vx or 0) * u.x + (A.vy or 0) * u.y + (A.vz or 0) * u.z
  return { t = time, dt = DT or 0, hA = hA, hT = hT, cam = cam, head = head, sy = sy, rel = cam - head, mh = mh, tag = tag,
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
      J("F %s %3d t %.4f hA %.4f hT %.4f cam %.4f head %.4f sy %.1f | contact %d ray %d slope %.3f pop %.3f snap %.3f vu %.3f",
        phase, i, s.t - t1, s.hA - upd[1].hA, s.hT - upd[1].hA, s.cam - upd[1].cam, s.head - upd[1].head, s.sy,
        s.c, s.ray, s.slope, s.pop, s.snap, s.vu)
    end
  end
  for _, set in ipairs({ { "late", late }, { "update", upd } }) do
    for _, key in ipairs({ "hA", "hT", "mh", "cam", "head", "rel", "sy" }) do
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
