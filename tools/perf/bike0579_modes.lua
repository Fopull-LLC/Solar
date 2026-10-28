-- ── bike0579 probe (tools/perf/bike0579.sh): floptle card 0579 dumps ──
-- Spliced after verifyprobe_modes.lua (uses its local V). Mode vb79: the
-- player's dirt bike out past 95 m, a flattened strip, full W then full S
-- from a standstill (5 s each), with
--   * a static dump of every wheel joint, tyre and the chassis at the start
--     of each run (`VB79S {json}`),
--   * a 10 Hz sample of every wheel and the controller (`VB79T {json}`),
--   * the run's summary (`VB79R {json}`).
-- Switches (BENCH_PARAMS): tcoff=1 the traction control's lead unbounded
-- (the rim runs at the stick's top speed, the motor at its full torque);
-- nobal=1 the balance (motoBike) off. The raked axes are bike0579.sh's RAKED=1
-- (a copy of the snapshot's auto_drive.lua without jointAxis).
local B79 = {}
local function J(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.6g", v)
  elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local o = {}
      for i = 1, #v do o[i] = J(v[i]) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local o, ks = {}, {}
    for k in pairs(v) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    for _, k in ipairs(ks) do o[#o + 1] = J(k) .. ":" .. J(v[k] == nil and v[tonumber(k)] or v[k]) end
    return "{" .. table.concat(o, ",") .. "}"
  end
  return "null"
end
local function wv(vn, a) -- a vessel-frame direction into the world
  local o = vn:toWorld(vec3(0, 0, 0))
  local p = vn:toWorld(vec3(a[1] or a.x, a[2] or a.y, a[3] or a.z))
  return { x = p.x - o.x, y = p.y - o.y, z = p.z - o.z }
end
local function lv(vn, p) -- a world point into the vessel frame
  local q = vn:toLocal(vec3(p.x, p.y, p.z))
  return { q.x, q.y, q.z }
end
local function r3(v) return { math.floor(v.x * 1e4 + 0.5) / 1e4, math.floor(v.y * 1e4 + 0.5) / 1e4, math.floor(v.z * 1e4 + 0.5) / 1e4 } end
function B79.static(vc, tag)
  local vn = vc.node
  local info = assembly.info(vn)
  local com = info.com
  local comL = lv(vn, com)
  local R2 = vc.R2
  local gl = 9.8
  if space.gravity then local gx, gy, gz = space.gravity(com.x, com.y, com.z); if gx then gl = math.sqrt(gx * gx + gy * gy + gz * gz) end end
  local out = { tag = tag, mass = info.mass, comL = comL, g = gl, fwdL = { (R2.fwd or {}).x or 0, 0, (R2.fwd or {}).z or 0 },
    upW = r3(V.up(com)), fwdW = r3(V.fwdW(vc)),
    R2_TC = vc.R2_TC, R2_LK_MAX = vc.R2_LK_MAX, R2_TYRE_MU = vc.R2_TYRE_MU, TYRE_SHARE = vc.TYRE_SHARE, R2_TYRE_RATIO = vc.R2_TYRE_RATIO,
    wheelieK = R2.wheelieK, hcg = R2.plan and R2.plan.hcg, wheelbase = R2.wheelbase, bike = R2.bike, rk = R2.rk,
    wheels = {} }
  for _, w in ipairs(R2.wheels or {}) do
    local t = w.tyre
    local j = t and t.valid and t:getcomponent("Joint")
    local rb = t and t.valid and t:getcomponent("RigidBody")
    local s = w.susp or {}
    local e = { uid = w.uid, kind = s.m and s.m.kind, r = w.r, rs = w.rs, steer0 = w.steer0, a = w.a, l = w.l, mountL = { w.cx, w.cy, w.cz },
      axisL = s.axis, partAxisL = s.partAxis, raked = s.raked, spring_k = s.k, spring_c = s.c, ke = s.ke, ce = s.ce, load = s.load, travel = s.travel, mt = s.mt,
      fullTorque = vc.r2FullTorque and vc.r2FullTorque(w, R2.rk), vmax = vc.r2TopSpeed and vc.r2TopSpeed(w, gl), cfg = w.cfg }
    if j then
      local ax = { j.axisX, j.axisY, j.axisZ }
      e.joint = { axis_jointfield = ax, axisW = r3(wv(vn, ax)), stiffness = j.stiffness, damping = j.damping, maxForce = j.maxForce, motorSpeed = j.motorSpeed,
        motor = j.motor, steer = j.steer, limit = j.limit, min = j.min, max = j.max, anchor = { j.anchorX, j.anchorY, j.anchorZ },
        otherAnchor = { j.otherAnchorX, j.otherAnchorY, j.otherAnchorZ }, position_m = (j.position or 0) / 57.29578, force = j.force }
      local mw = vn:toWorld(vec3(j.otherAnchorX, j.otherAnchorY, j.otherAnchorZ))
      local mL = lv(vn, mw)
      e.mountRelCom = { mL[1] - comL[1], mL[2] - comL[2], mL[3] - comL[3] }
    end
    if t and t.valid then
      local tL = lv(vn, t:toWorld(vec3(0, 0, 0)))
      e.tyreRelCom = { tL[1] - comL[1], tL[2] - comL[2], tL[3] - comL[3] }
    end
    if rb then e.tyre = { mass = rb.mass, radius = rb.radius, friction = rb.friction, shape = rb.shape } end
    out.wheels[#out.wheels + 1] = e
  end
  P("VB79S %s", J(out))
end
function B79.sample(vc, tag, t, F, U)
  local R2 = vc.R2
  local vn = vc.node
  local info = assembly.info(vn)
  local s = vc.motoState and vc.motoState() or {}
  local o = { tag = tag, t = math.floor(t * 100 + 0.5) / 100, vf = R2.vf, a_s = R2.a_s, lk = R2.lk, want_a = R2.want_a, drive = R2.drive,
    wheelieK = R2.wheelieK, lean = math.deg(s.lean or 0), bars = s.steer, pitchup = dot(F, V.up(info.com)), w = {} }
  for _, w in ipairs(R2.wheels or {}) do
    local tn = w.tyre
    local j = tn and tn.valid and tn:getcomponent("Joint")
    local rb = tn and tn.valid and tn:getcomponent("RigidBody")
    if j then
      local k = (w.r or 0.3) * (w.rs or 1) / 57.29578
      local tv = 0
      local ok, vel = pcall(function() return tn.vel end)
      if ok and vel then tv = dot(vel, F) end
      local rim = (j.speed or 0) * k
      local comp = (j.position or 0) / 57.29578
      local mt = rb and rb.mass or 0
      local keng = mt * (2 * math.pi * (j.stiffness or 0)) ^ 2
      local gn = tn.groundNormal
      o.w[#o.w + 1] = { uid = w.uid, gr = tn.grounded, tgt = (j.motorSpeed or 0) * k, rim = rim, tv = tv, slip = rim - tv,
        ms = j.motorSpeed, mF = j.maxForce, force = j.force, motor = j.motor, comp = comp, keng = keng, Nspring = keng * comp,
        gnUp = gn and dot(gn, U) or nil, steer = j.steer }
    end
  end
  P("VB79T %s", J(o))
end
function B79.run(vc, dir, secs, tag)
  local vn = vc.node
  B79.static(vc, tag)
  local F = V.fwdW(vc)
  local U = V.up(assembly.info(vn).com)
  F = unit(sub(F, scl(U, dot(F, U))))
  local t0, nexts = time, 0
  local s15, s45, vmax = nil, nil, 0
  local c0 = sub(assembly.info(vn).com, home())
  local fell = false
  while time - t0 < secs do
    vc.R2.cmd = { drive = dir, steer = 0 }
    if (params.tcoff or 0) > 0 then vc.R2.lk = 1e4 end
    yield()
    if (params.tcoff or 0) > 0 then vc.R2.lk = 1e4 end
    local sp = V.speed(vc) * dir
    vmax = math.max(vmax, sp)
    if not s15 and time - t0 >= 1.5 then s15 = { sp, time } end
    if not s45 and time - t0 >= 4.5 then s45 = { sp, time } end
    if time - t0 >= nexts then nexts = nexts + 0.1; B79.sample(vc, tag, time - t0, F, U) end
    if V.upness(vn) < 0.3 then fell = true; break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  local acc = (s15 and s45) and (s45[1] - s15[1]) / (s45[2] - s15[2]) or 0
  local along = dot(sub(sub(assembly.info(vn).com, home()), c0), F) * dir
  local r = { tag = tag, dir = dir, acc15_45 = acc, vmax = vmax, along = along, fell = fell, v15 = s15 and s15[1], v45 = s45 and s45[1] }
  P("VB79R %s", J(r))
  return r
end
local function run_vb79()
  V.tag = "b79"
  local bp = V.dirtbike()
  if not bp then V.check("craft", false, "no craft file"); V.result(); return end
  local seat
  for _, d in ipairs(bp.parts) do if (d.seat == 1 or d.seat == true) then seat = d.uid end end
  P("VB79P %s", J(bp))
  local vc = iv_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = "Dirt Bike", controls = bp.controls, groups = bp.groups, turned = bp.turned },
    "runway", seat and { { uid = seat, slot = 1, id = 1 } } or nil)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  local vn = vc.node
  wait(2)
  vc.releaseClamps()
  wait(2)
  for _, w in ipairs(vc.R2.wheels or {}) do
    local s = w.susp
    P("VP wheel %d: susp %s joint axis %s part axis %s raked %s", w.uid, s and s.m and s.m.kind or "-",
      s and s.axis and string.format("%.3f %.3f %.3f", s.axis[1], s.axis[2], s.axis[3]) or "-",
      s and s.partAxis and string.format("%.3f %.3f %.3f", s.partAxis[1], s.partAxis[2], s.partAxis[3]) or "-", tostring(s and s.raked))
  end
  if (params.nobal or 0) > 0 then vc.R2.motoOff = true; P("VP A/B: the balance (motoBike) off") end
  if (params.tcoff or 0) > 0 then vc.R2_LK_MAX = 1e4; P("VP A/B: the traction control's lead unbounded") end
  local okout = V.out(vc, 95)
  V.stop(vc)
  if not okout then V.check("out", false, "fell on the way out"); V.result(); return end
  local U = V.up(assembly.info(vn).com)
  local F = V.fwdW(vc)
  F = unit(sub(F, scl(U, dot(F, U))))
  local rel0, made = V.ground(vc, F, U, -60, 110, 0)
  V.strip = { rel0 = rel0, F = F }
  P("VP flat strip: %d sculpts", made)
  V.stop(vc)
  local fw = B79.run(vc, 1, 5, "W")
  V.stop(vc)
  local bw = B79.run(vc, -1, 5, "S")
  V.stop(vc)
  V.check("bike_flat_accel", true, "acceleration 1.5–4.5 s W %.2f / S %.2f m/s² (top %.2f / %.2f)", fw.acc15_45, bw.acc15_45, fw.vmax, bw.vmax)
  V.result()
end
