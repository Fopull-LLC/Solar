-- ── FACE probe (tools/perf/faceprobe.sh): the crew's faces in the game ──────
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua (it uses IV
-- and iv_launch). Modes:
--   facepod   a Pod Mk2 rocket, three aboard, the strip LARGE: on the pad
--             (calm), the launch (strain / excitement), the coast after
--             burnout (weightless), an alarm (the cabin failing and heat,
--             forced through crew.alerts: scared), the chute and the landing
--             (relief, joy). A picture each, every member's mood logged; the
--             faces' script cost (perf.scriptMs) and the strip's GPU with the
--             faces shown and hidden.
--   facefoot  on foot by the base: the helmet on with the visor down, the
--             visor up, the helmet off; close, from in front.
-- `FP MOOD`, `FP COST` lines; pictures in $WORK/proj/save/user/ivashots/face_*.png.
local function fp_moods(tag)
  local C, F = findScript("crew"), findScript("crew_faces")
  local out = {}
  for _, r in ipairs(C.roster() or {}) do
    local d = F.drives(r.id) or {}
    out[#out + 1] = string.format("#%d %s %s [str %.2f fear %.2f exc %.2f joy %.2f rel %.2f dl %.2f bor %.2f out %.2f]",
      r.id, r.name, F.moodOf(r.id), d.strain or 0, d.fear or 0, d.excite or 0, d.joy or 0, d.relief or 0,
      d.delight or 0, d.bored or 0, d.out or 0)
  end
  P("FP MOOD %-8s %s", tag, table.concat(out, " | "))
end

local function fp_faces(on)
  local n = 0
  for _, f in ipairs(findScripts("face")) do
    if f.node and f.node.valid ~= false then f.node.visible = on; n = n + 1 end
  end
  return n
end

local function fp_cost(tag)
  local F = findScript("crew_faces")
  local live = 0
  for _, f in ipairs(findScripts("face")) do if f.live then live = live + 1 end end
  P("FP COST %-8s face %.4f ms (worst %.4f) crew_faces %.4f ms (worst %.4f); faces live %d", tag,
    perf.scriptMs("face"), perf.scriptWorstMs("face"), perf.scriptMs("crew_faces"), perf.scriptWorstMs("crew_faces"), live)
  return F
end

local function run_facepod()
  IV.tag = "face"
  perf.enable(true)
  local C = findScript("crew")
  -- three distinct people: crew_faces gives them their looks on first sight
  local plan = { { uid = 3, slot = 1, id = 1 }, { uid = 3, slot = 2, id = 2 }, { uid = 3, slot = 3, id = 3 } }
  local vc = iv_launch(stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "podMk2", 1.15 }, { "chute", 0.34, 1 } }), { name = "Kestrel" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  for _, r in ipairs(C.roster()) do
    local l = r.look or {}
    P("FP LOOK #%d %s head %s %s hair %s/%s eyes %s skin %.2f age %.2f courage %.2f thrill %.2f", r.id, r.name, tostring(l.head),
      l.fem and "F" or "M", tostring(l.hairName), tostring(l.hairStyle), tostring(l.eyeName), l.skinX or -1, l.age or -1,
      l.courage or -1, l.thrill or -1)
  end
  local S = findScript("crew_strip")
  S.setMode("large")
  wait(8)
  fp_moods("pad")
  fp_cost("pad")
  IV.shot("pad")
  -- the strip's GPU with the faces, and without (the heads hidden)
  local res = {}
  for i, on in ipairs({ true, false, true, false }) do
    fp_faces(on)
    wait(0.8)
    res[i] = gpu_avg(90)
  end
  fp_faces(true)
  P("FP COST gpu strip large: faces on %.3f / %.3f ms, off %.3f / %.3f ms: faces cost %.3f ms", res[1], res[3], res[2], res[4],
    ((res[1] - res[2]) + (res[3] - res[4])) / 2)
  -- the launch
  tap("z")
  wait(0.3)
  tap("space")
  wait(1.0)
  if assembly.info(vc.node).anchored then vc.releaseClamps() end
  wait(3.0)
  fp_moods("launch")
  IV.shot("launch")
  wait(2.5)
  fp_moods("launch2")
  fp_cost("launch")
  IV.shot("launch2")
  -- burnout (or cut), then the coast
  local t0 = time
  while time - t0 < 40 do
    yield()
    local tl = vc.tele
    if tl and (tl.thrust_now or 0) <= 0 and time - t0 > 2 then break end
  end
  tap("x")
  wait(4.0)
  fp_moods("coast")
  IV.shot("coast")
  -- an alarm: the cabin failing and heat on everyone aboard
  local real = C.alerts
  C.alerts = function(id)
    local a = real(id)
    a.cabin, a.cabin_tol, a.heat = 0.22, 9, 0.7
    return a
  end
  wait(2.5)
  fp_moods("alarm")
  IV.shot("alarm")
  C.alerts = real
  -- down under the chute
  local fell = false
  t0 = time
  while time - t0 < 90 do
    yield()
    local st = body_state(vc.node)
    if st and st.vr < -3 and not fell then fell = true; tap("space"); P("FP chute at alt %.0f", st.alt) end
    local F = findScript("crew_faces")
    if F.moodOf(1) == "relief" or F.moodOf(1) == "happy" then break end
  end
  wait(1.5)
  fp_moods("landed")
  IV.shot("landed")
  wait(3)
  fp_moods("landed2")
  IV.shot("landed2")
  IV.result()
end

local function run_facefoot()
  IV.tag = "face"
  IV.medium()
  local cam, su = findScript("planet_camera"), findScript("suit")
  local b = space.body(save.get("base.body"))
  local function crew() return find("Astronaut") end
  local function model() for _, c in ipairs(crew():children()) do if c.name == "AstroModel" then return c end end end
  local function bone(n) return model():bonePos(n) end
  local function frame()
    local l = (bone("Upperarm.Left") - bone("Upperarm.Right")):normalized()
    local u = (bone("Head") - bone("Hip")):normalized()
    return l, u, l:cross(u):normalized()
  end
  local function cam_at(pos, tgt)
    local bn = find(b.name)
    local a = crew()
    local uu = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z):normalized()
    cam.setFreecam(true)
    local fc = cam.freecamState()
    fc.body = b.name
    fc.rel = pos - vec3(bn.x, bn.y, bn.z)
    local d = tgt - pos
    local h = d:flatten(uu)
    fc.ref = h:normalized()
    fc.pitch = math.atan2(d:dot(uu), h:length())
  end
  local function view(name, side, fwd, up, lift)
    for _ = 1, 30 do
      local l, u, f = frame()
      local t = bone("Head") + u * lift
      cam_at(t + l * side + f * fwd + u * up, t)
      yield()
    end
    IV.shot(name, false)
  end
  wait(3)
  local F = findScript("crew_faces")
  local C = findScript("crew")
  P("FP foot: active #%s look head %s hair %s", tostring(C.activeId()), tostring((F.lookOf(C.activeId()) or {}).head),
    tostring((F.lookOf(C.activeId()) or {}).hairStyle))
  su.setHelmet(true, { instant = true }); su.setVisor(true)
  view("foot_visor", 0.25, 1.1, 0.05, 0.14)
  view("foot_visor_wide", 0.9, 2.6, 0.3, -0.1)
  su.setVisor(false)
  view("foot_open", 0.25, 1.1, 0.05, 0.14)
  local ok, why = su.setHelmet(false, { instant = true })
  P("FP helmet off: %s %s", tostring(ok), tostring(why))
  view("foot_bare", 0.25, 1.0, 0.05, 0.14)
  view("foot_bare_side", 0.8, 0.6, 0.05, 0.14)
  fp_cost("foot")
  cam.setFreecam(false)
  IV.result()
end

-- facestrip: the strip's square portraits in their frames, at interface
-- sizes Auto, 70 % and 100 %, small and large (strip_<size>_<mode>.png)
local function run_facestrip()
  IV.tag = "face"
  local plan = { { uid = 3, slot = 1, id = 1 }, { uid = 3, slot = 2, id = 2 }, { uid = 3, slot = 3, id = 3 } }
  local vc = iv_launch(stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "podMk2", 1.15 }, { "chute", 0.34, 1 } }), { name = "Kestrel" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  local S, st = findScript("crew_strip"), findScript("settings")
  wait(3)
  for _, sz in ipairs({ { "auto", nil }, { "70", 0.7 }, { "100", 1.0 } }) do
    st.set("ui_scale", sz[2])
    for _, m in ipairs({ "small", "large" }) do
      S.setMode(m)
      wait(1.5)
      P("FP STRIP ui %s (scale %.2f) %s: shown %d live %d", sz[1], (ui.scale and ui.scale()) or -1, m, S.strip.shown, S.strip.live)
      IV.shot("strip_" .. sz[1] .. "_" .. m)
    end
  end
  st.set("ui_scale", nil)
  S.setMode("small")
  IV.result()
end
