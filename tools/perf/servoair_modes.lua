-- ── robotics on flying craft (servoprobe.sh, mode sair) ──
-- Spliced after servomid_modes.lua (SM.*), servoprobe (SP.*), jumpprobe (JP.*),
-- verifyprobe (V.*) and ivaprobe (IV.*). `rig` (strs) picks the craft:
--   gimbal  a probe-core rocket, its Sputter on a Servo Hinge (pitch axis):
--           thrust vectored ±10° with the SAS off (the turn follows the
--           engine's real axis), then the SAS on: the hinge moved by itself,
--           then bound to the pitch stick (W) with the SAS on
--   tilt    a VTOL: two Sputters on Servo Hinges on a tank's flanks, lifting
--           straight up, then tilted 30° forward: the push follows the engines
--   plane   the probe jet (perfbench plane) with its gear on hinges, its wing
--           tips on hinges and a pair of hinge-driven canards: take-off on
--           the jointed gear, gear up and down in flight, the tips folded
--           (one, then both), the canards swung (their pitching moment), and
--           a landing and roll-out on the jointed gear
--   stage   pod → twist hinge → decoupler → probe core → tank → hinge → Sputter:
--           staged while the twist hinge moves; both crafts' joints after
--   keep    the tilt VTOL posed (engines 30°), put in orbit through the fleet
--           and a reload, then warped, then moved again
-- `SA` lines, `VP PASS|FAIL`, `VP RESULT`.
-- (in a function of its own: the spliced perfbench is at its 200 locals)
do (function()
local AIR = {}
local UPV, NOSE = { x = 0, y = 1, z = 0 }, { x = 1, y = 0, z = 0 }
local function V3(x, y, z) return { x = x, y = y, z = z } end
local function deg(r) return math.deg(r) end
local function vlen(a) return len(a.x, a.y, a.z) end
local function add3(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
-- a record from its +X and +Y axes (vessel frame)
local function AR(uid, id, x, y, z, X, Y, o)
  o = o or {}
  local Z = cross(X, Y)
  local yaw, pitch, roll = eulerOf(X, Y, Z)
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll,
           parent = o.parent or 0, att = o.att or "surface", sym = 0, mir = "", stage = o.stage or 0 }
end

-- ── the crafts ──────────────────────────────────────────────────────────────
function AIR.bp(rig)
  local P_ = {}
  local function add(r) P_[#P_ + 1] = r; return r.uid end
  local cmd, note
  if rig == "gimbal" then
    -- engine 0–1.3, hinge 1.3–1.7 (its axis the vessel's X: pitch), tank 1.7–3.2, probe 3.2–3.62
    add(AR(1, "probe", 0, 3.41, 0, V3(1, 0, 0), UPV, { att = "" }))
    add(AR(2, "tankM", 0, 2.45, 0, V3(1, 0, 0), UPV, { parent = 1, att = "bottom" }))
    add(AR(3, "hinge", 0, 1.5, 0, V3(0, 0, -1), UPV, { parent = 2, att = "bottom" }))
    add(AR(4, "engineS", 0, 0.65, 0, V3(1, 0, 0), UPV, { parent = 3, att = "bottom" }))
    cmd, note = 1, "a Sputter on a Servo Hinge under a tank (hinge axis = pitch)"
  elseif rig == "tilt" or rig == "keep" then
    -- a tank standing (0.25–1.75), the pod on it; a hinge on each flank, its
    -- axis across the craft (z), an engine on it whose centre is on that axis
    add(AR(1, "tankM", 0, 1.0, 0, V3(1, 0, 0), UPV, { att = "" }))
    add(AR(2, "pod", 0, 2.15, 0, V3(1, 0, 0), UPV, { parent = 1, att = "top" }))
    for i, s in ipairs({ 1, -1 }) do
      local h = 1 + 2 * i
      add(AR(h, "hinge", 0, 1.0, s * 0.7, V3(0, -1, 0), V3(1, 0, 0), { parent = 1 }))
      add(AR(h + 1, "engineS", 0, 1.0, s * 1.8, V3(1, 0, 0), UPV, { parent = h }))
    end
    cmd, note = 2, "two Sputters on Servo Hinges on a tank's flanks (axis across)"
  elseif rig == "stage" then
    -- engine 0–1.3, hinge B 1.3–1.7, tank 1.7–3.2, probe 3.2–3.62, decoupler
    -- 3.62–3.87, twist hinge A 3.87–4.27 (its axis the stack), pod 4.27–5.07
    add(AR(1, "pod", 0, 4.67, 0, V3(1, 0, 0), UPV, { att = "" }))
    add(AR(2, "hinge", 0, 4.07, 0, V3(1, 0, 0), V3(0, 0, -1), { parent = 1, att = "bottom" }))   -- axis (its Z) = up
    add(AR(3, "decoupler", 0, 3.745, 0, V3(1, 0, 0), UPV, { parent = 2, att = "bottom", stage = 1 }))
    add(AR(4, "probe", 0, 3.41, 0, V3(1, 0, 0), UPV, { parent = 3, att = "bottom" }))
    add(AR(5, "tankM", 0, 2.45, 0, V3(1, 0, 0), UPV, { parent = 4, att = "bottom" }))
    add(AR(6, "hinge", 0, 1.5, 0, V3(0, 0, -1), UPV, { parent = 5, att = "bottom" }))
    add(AR(7, "engineS", 0, 0.65, 0, V3(1, 0, 0), UPV, { parent = 6, att = "bottom" }))
    cmd, note = 1, "pod, twist hinge, decoupler, probe core, tank, hinge, Sputter"
  elseif rig == "stage2" then
    -- the joint leaves with the stage, its command part on the far side of
    -- it: pod 3.87–4.67, decoupler 3.62–3.87, tank 2.12–3.62, hinge
    -- 1.72–2.12, probe core 1.3–1.72, engine 0–1.3. Here the hinge moves the
    -- probe and the engine (the side away from the pod); on the stage it
    -- leaves as, the side away from ITS command part is the tank.
    add(AR(1, "pod", 0, 4.27, 0, V3(1, 0, 0), UPV, { att = "" }))
    add(AR(2, "decoupler", 0, 3.745, 0, V3(1, 0, 0), UPV, { parent = 1, att = "bottom", stage = 1 }))
    add(AR(3, "tankM", 0, 2.87, 0, V3(1, 0, 0), UPV, { parent = 2, att = "bottom" }))
    add(AR(4, "hinge", 0, 1.92, 0, V3(0, 0, -1), UPV, { parent = 3, att = "bottom" }))
    add(AR(5, "probe", 0, 1.51, 0, V3(1, 0, 0), UPV, { parent = 4, att = "bottom" }))
    add(AR(6, "engineS", 0, 0.65, 0, V3(1, 0, 0), UPV, { parent = 5, att = "bottom" }))
    cmd, note = 1, "pod, decoupler, tank, hinge, probe core, Sputter (the stage's command part beyond its joint)"
  elseif rig == "plane" then
    -- perfbench's plane, with hinges: main gear (axis the nose: folds
    -- sideways), nose gear (axis across: folds back), wing tips (axis the
    -- nose: fold up), two canards (axis across: their incidence)
    local Y0 = 1.5
    local cZ = V3(0, -1, 0)
    local cX = cross(NOSE, cZ)
    local u = 0
    local function nx() u = u + 1; return u end
    local ck = add(AR(nx(), "cockpit", 1.9, Y0, 0, cX, NOSE, { att = "" }))
    local ft = add(AR(nx(), "fuseTank", -0.2, Y0, 0, cX, NOSE, { parent = ck, att = "bottom" }))
    local jt = add(AR(nx(), "jet", -2.1, Y0, 0, cX, NOSE, { parent = ft, att = "bottom" }))
    AIR.ids = { gear = {}, tips = {}, canards = {} }
    for _, s in ipairs({ 1, -1 }) do
      local out = V3(0, 0, s)
      local w = add(AR(nx(), "wingL", -0.6, Y0, s * (0.5 + 1.75), out, NOSE, { parent = ft }))
      -- the tip on a hinge at the panel's end (the hinge's Y out, its axis the nose)
      local th = add(AR(nx(), "hinge", -0.6, Y0, s * (0.5 + 3.5 + 0.2), V3(0, s, 0), out, { parent = w }))
      local tp = add(AR(nx(), "wingTip", -0.6, Y0, s * (0.5 + 3.5 + 0.4 + 0.6), out, NOSE, { parent = th }))
      AIR.ids.tips[#AIR.ids.tips + 1] = { hinge = th, part = tp, s = s }
      add(AR(nx(), "elevon", -2.35, Y0, s * (0.5 + 0.8), out, NOSE, { parent = jt }))
      local ia = unit(V3(0, 0.707, s * 0.707))
      add(AR(nx(), "intake", 0.5, Y0 + ia.y * 0.7, ia.z * 0.7, ia, NOSE, { parent = ft }))
      -- the main gear on a hinge in the wing's root (the hinge's Y down, its axis the nose)
      local gh = add(AR(nx(), "hinge", -0.45, 1.7, s * 1.4, V3(0, 0, 1), cZ, { parent = w }))
      local g = add(AR(nx(), "gearM", -0.45, 0.75, s * 1.4, cZ, NOSE, { parent = gh }))
      AIR.ids.gear[#AIR.ids.gear + 1] = { hinge = gh, part = g, s = s }
      -- a canard on a hinge on the cockpit's flank (the hinge's Y the nose, its axis z)
      local chg = add(AR(nx(), "hinge", 1.2, Y0, s * 0.7, V3(0, -1, 0), NOSE, { parent = ck }))
      local cn = add(AR(nx(), "wingTip", 1.2, Y0, s * (0.9 + 0.6), out, NOSE, { parent = chg }))
      AIR.ids.canards[#AIR.ids.canards + 1] = { hinge = chg, part = cn, s = s }
    end
    add(AR(nx(), "tailFin", -2.3, Y0 + 0.5 + 0.75, 0, UPV, NOSE, { parent = jt }))
    local nh = add(AR(nx(), "hinge", 2.3, 1.2, 0, V3(-1, 0, 0), cZ, { parent = ck }))
    local ng = add(AR(nx(), "gearS", 2.3, 0.5, 0, cZ, NOSE, { parent = nh }))
    AIR.ids.gear[#AIR.ids.gear + 1] = { hinge = nh, part = ng, s = 0 }
    cmd, note = 1, "the probe jet, its gear, wing tips and two canards on Servo Hinges"
  else
    return nil, "unknown air rig " .. tostring(rig)
  end
  return { parts = P_, name = "Air " .. rig, cmd = cmd }, note
end

-- ── launch through the VAB ──────────────────────────────────────────────────
function AIR.launch(rig)
  V.tag = "air_" .. rig
  local bp, note = AIR.bp(rig)
  if not bp then V.check("rig", false, "%s", tostring(note)); return end
  P("SA rig %s: %s, %d parts", rig, note, #bp.parts)
  IV.medium()
  local co = findScript("company"); if co and co.earn then co.earn(200000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(bp.parts) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("launch_enter")
  if not BH then V.check("vab", false, "no VAB"); return end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "launch_bp", bp.parts, { name = bp.name })
  wait(0.5)
  local warn = {}
  for _, f in ipairs({ "roboLoopChecks", "roboTowChecks", "chainJointChecks" }) do
    local fn = B[f]
    if fn then for _, w in ipairs(fn({}) or {}) do warn[#warn + 1] = w end end
  end
  local chk = B.launchCheck and B.launchCheck() or {}
  P("SA builder: %d warning(s)%s; launch %s", #warn, #warn > 0 and (": " .. table.concat(warn, " | ")) or "", chk.block and ("BLOCKED: " .. chk.block) or "allowed")
  local BC = findScript("builder_crew")
  local cd = bp.parts[bp.cmd]
  if BC and cd and (cd.id == "pod" or cd.id == "cockpit") then
    if BC.unseatMember then BC.unseatMember(1) end
    local ok, why = BC.seatMember(1, cd.uid, 1)
    P("SA crew -> %d: %s %s", cd.uid, tostring(ok), tostring(why))
  end
  local site = (rig == "plane") and "runway" or "pad"
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#bp.parts, 150)
  if not vc then V.check("rollout", false, "no craft"); return end
  wait(2)
  return vc
end

-- ── measures ────────────────────────────────────────────────────────────────
-- the robotic part on `uid`
function AIR.joint(vc, uid)
  for _, r in ipairs(vc.R2.robo or {}) do if r.uid == uid then return r end end
end
function AIR.set(vc, uid, key, v)
  local r = AIR.joint(vc, uid)
  if not r then P("SA no joint %s", tostring(uid)); return end
  if type(r.d.st) ~= "table" then r.d.st = {} end
  r.d.st[key] = v
end
function AIR.cur(vc, uid) local r = AIR.joint(vc, uid); return r and r.cur or 0 end
-- the hull frame (this tick's, assembly.info) and vessel → world
function AIR.frame(vc)
  local i = assembly.info(vc.node)
  if not i then return nil end
  local R, U = i.right, i.up
  local Z = cross(R, U)
  local function W(v) return V3(R.x * v.x + U.x * v.y + Z.x * v.z, R.y * v.x + U.y * v.y + Z.y * v.z, R.z * v.x + U.z * v.y + Z.z * v.z) end
  local function L(v) return V3(dot(v, R), dot(v, U), dot(v, Z)) end
  return { i = i, R = R, U = U, Z = Z, W = W, L = L, o = i.origin }
end
-- an engine as the thrust loop has it, against its part node as posed
-- (vessel frame): the axis error (deg) and the place error (m)
function AIR.engine(vc, uid)
  -- (a tree before engineAxes: the blueprint's pose is what its thrust loop used)
  local list = vc.engineAxes and vc.engineAxes()
  if not list then
    list = {}
    for u, r in pairs(vc.R2.rest or {}) do
      if u == uid then list[1] = { uid = u, x = r.x, y = r.y, z = r.z, dx = r.Y[1], dy = r.Y[2], dz = r.Y[3] } end
    end
  end
  for _, e in ipairs(list) do
    if e.uid == uid then
      local n = vc.r2NodeOf(vc.node, uid)
      if not n then return e, -1, -1 end
      local _, Y = basis(n)
      local c = clamp(Y.x * e.dx + Y.y * e.dy + Y.z * e.dz, -1, 1)
      return e, deg(math.acos(c)), len(n.x - e.x, n.y - e.y, n.z - e.z), Y
    end
  end
end
-- every part's pose by the controller's joints against its live node: the
-- worst place (m) and axis (deg) error (a record that disagrees with where
-- the part really is)
function AIR.poseErr(vc)
  local wp, wa, who = 0, 0, nil
  AIR.perr = ""
  for u, rest in pairs(vc.R2.rest or {}) do
    local n = vc.r2NodeOf(vc.node, u)
    if n then
      local p = vc.roboPoint(u, { rest.x, rest.y, rest.z })
      local Yr = vc.roboTurn(u, rest.Y)
      local _, Y = basis(n)
      local dp = len(n.x - p[1], n.y - p[2], n.z - p[3])
      local da = deg(math.acos(clamp(Y.x * Yr[1] + Y.y * Yr[2] + Y.z * Yr[3], -1, 1)))
      if dp > wp then wp, who = dp, u end
      if da > wa then wa = da end
      if dp > 0.01 or da > 0.5 then AIR.perr = (AIR.perr or "") .. string.format(" %d:%s %.3fm(%.2f,%.2f,%.2f) %.1fd", u, tostring(vc.JP_ID and "" or ""), dp, n.x - p[1], n.y - p[2], n.z - p[3], da) end
    end
  end
  return wp, wa, who
end
-- the aero model's element for a part
function AIR.surf(vc, uid)
  local M = vc.AERO and vc.AERO.model
  for _, s in ipairs(M and M.surfs or {}) do if s.uid == uid then return s end end
end
function AIR.body(vc, uid)
  local M = vc.AERO and vc.AERO.model
  for _, b in ipairs(M and M.bodies or {}) do if b.uid == uid then return b end end
end
-- the surface's normal in the model against the part node's own Z (deg)
function AIR.surfErr(vc, uid)
  local s = AIR.surf(vc, uid)
  local n = vc.r2NodeOf(vc.node, uid)
  if not (s and n) then return -1 end
  local _, _, Z = basis(n)
  return deg(math.acos(clamp(math.abs(Z.x * s.Z.x + Z.y * s.Z.y + Z.z * s.Z.z), -1, 1)))
end
-- the lifting surfaces' centre (area-weighted, vessel frame; control surfaces left out)
function AIR.col(vc)
  local M = vc.AERO and vc.AERO.model
  local sx, sy, sz, S = 0, 0, 0, 0
  for _, s in ipairs(M and M.surfs or {}) do
    if not s.ctl then sx, sy, sz, S = sx + s.x * s.S, sy + s.y * s.S, sz + s.z * s.S, S + s.S end
  end
  if S <= 0 then return V3(0, 0, 0) end
  return V3(sx / S, sy / S, sz / S)
end
-- a surface's force (model, craft frame) and its moment about the centre of mass
function AIR.moment(vc, uid)
  local s = AIR.surf(vc, uid)
  local F = AIR.frame(vc)
  if not (s and F and s.fx) then return V3(0, 0, 0), V3(0, 0, 0) end
  local c = vc.r2HullCom(F.i)
  local r = V3(s.x - c[1], s.y - c[2], s.z - c[3])
  local f = V3(s.fx, s.fy, s.fz)
  return f, cross(r, f)
end
function AIR.com(vc)
  local F = AIR.frame(vc)
  local c = F and vc.r2HullCom(F.i)
  return c and V3(c[1], c[2], c[3]) or V3(0, 0, 0)
end
function AIR.fmt(v) return string.format("(%.3f, %.3f, %.3f)", v.x, v.y, v.z) end
-- hold the throttle (and run fn) for secs; the fuel topped up (a probe's tank)
function AIR.hold(vc, secs, thr, fn)
  local t0 = time
  while time - t0 < secs do
    if thr then vc.setThrottle(thr) end
    if vc.fuelFill then vc.fuelFill(1e6) end
    if fn and fn(time - t0) then break end
    yield()
    if not (vc.node and vc.node.valid) or not vc.setThrottle then P("SA the craft is gone"); return false end
  end
end
function AIR.alt(vc)
  local i = assembly.info(vc.node)
  local b = home()
  local rel = sub(i.com, b)
  local r = vlen(rel)
  local U = scl(rel, 1 / r)
  local h = raycast(i.com.x, i.com.y, i.com.z, -U.x, -U.y, -U.z, 600, vc.r2Own and { ignore = vc.r2Own(vc.node) } or vc.node)
  return r - b.radius, h and h.distance or 999, U, dot(i.vel, U)
end

-- ── the tests ───────────────────────────────────────────────────────────────
local T = {}

-- 1. ENGINE GIMBAL BY SERVO
T.gimbal = function(vc)
  local H, E = 3, 4
  vc.releaseClamps()
  vc.setSAS("stability")
  AIR.hold(vc, 2.5, 1)
  vc.setSAS("off")
  local felt = vc.R2.felt
  P("SA felt under thrust: %.2f m/s2 (g %.2f)", felt and len(felt[1], felt[2], felt[3]) or -1, vc.R2.gl or -1)
  local res = {}
  for _, ang in ipairs({ 3, -3 }) do
    local F0 = AIR.frame(vc)
    local w0 = F0.i.angVel
    AIR.set(vc, H, "angle", ang)
    AIR.hold(vc, 0.5, 1)
    local e, aerr, perr = AIR.engine(vc, E)
    -- the torque this engine makes about the centre of mass, from its axis as the thrust loop has it
    local F1 = AIR.frame(vc)
    local c = vc.r2HullCom(F1.i)
    local lever = V3(e.x - c[1], e.y - c[2], e.z - c[3])
    local tq = F1.W(cross(lever, V3(e.dx, e.dy, e.dz)))
    AIR.hold(vc, 0.4, 1)
    local F2 = AIR.frame(vc)
    local w2 = F2.i.angVel
    local dw = sub(w2, w0)
    local along = dot(dw, unit(tq))
    P("SA gimbal %+d: joint %.2f%s, thrust axis vs the engine node %.2f deg, place %.3f m; spin change %.3f rad/s, %.3f along the vectored torque; stalled %s",
      ang, AIR.cur(vc, H), AIR.joint(vc, H).stalled and "!" or "", aerr, perr, vlen(dw), along, tostring(AIR.joint(vc, H).stalled))
    res[#res + 1] = { ang = ang, aerr = aerr, perr = perr, along = along, dw = vlen(dw), tqx = cross(lever, V3(e.dx, e.dy, e.dz)).x }
    AIR.set(vc, H, "angle", 0)
    vc.setSAS("stability")
    AIR.hold(vc, 1.5, 1)
    vc.setSAS("off")
  end
  V.check("thrust_follows_engine", res[1].aerr < 1 and res[2].aerr < 1 and res[1].perr < 0.02 and res[2].perr < 0.02,
    "the thrust axis on the engine's posed axis: %.2f / %.2f deg, place %.3f / %.3f m", res[1].aerr, res[2].aerr, res[1].perr, res[2].perr)
  V.check("vectoring_turns", res[1].along > 0.05 and res[2].along > 0.05,
    "±3 deg of gimbal turned the rocket the way its thrust says: %.3f / %.3f rad/s along the torque (of %.3f / %.3f)", res[1].along, res[2].along, res[1].dw, res[2].dw)
  -- the SAS on: first the hinge moved by itself (the SAS holds the heading)
  vc.setSAS("stability")
  AIR.hold(vc, 1.0, 1)
  local F0 = AIR.frame(vc)
  local pax = F0.R          -- pitch axis (the rocket's right)
  AIR.set(vc, H, "angle", 3)
  local wmax = 0
  AIR.hold(vc, 1.5, 1, function() local w = dot(assembly.info(vc.node).angVel, pax); if math.abs(w) > math.abs(wmax) then wmax = w end end)
  local gu = vc.GIMBAL and vc.GIMBAL.used or -1
  P("SA sas+hinge alone: peak pitch rate %.3f rad/s (the SAS holding against the hinge; virtual gimbal used %.1f kN m)", wmax, gu)
  AIR.set(vc, H, "angle", 0)
  AIR.hold(vc, 1.0, 1)
  -- the hinge bound to the pitch stick (position mode, gain set so W tilts it
  -- the way that pitches the nose the way W does), the stick held, SAS on
  local C = findScript("controls")
  -- (the sign that turns the nose the way W does: + about the vessel's X)
  local plus = res[1].tqx > 0
  local g = (plus and 1 or -1) * (3 / 90)
  vc.ctlAxes = C.live({ v = 1, axes = { string.format("%d|angle|pitch|%.4f|0|position|0|0", H, g) } })
  local function stick(on)
    vc.CTL_PROBE = on and { pitch = 1 } or nil
    vc.AERO.cmd = on and { p = 1, y = 0, r = 0 } or nil
  end
  -- (the rate W reaches without the gimbal first, for comparison)
  local function w_run(tag, bound)
    vc.ctlAxes = bound and C.live({ v = 1, axes = { string.format("%d|angle|pitch|%.4f|0|position|0|0", H, g) } }) or nil
    stick(true)
    local F1 = AIR.frame(vc)
    local pa = F1.R
    local w0 = dot(F1.i.angVel, pa)
    local t_half = nil
    AIR.hold(vc, 0.8, 1, function(t)
      local w = dot(assembly.info(vc.node).angVel, pa) - w0
      if not t_half and w > 0.1 then t_half = t end
    end)
    local w1 = dot(assembly.info(vc.node).angVel, pa) - w0
    local jc = AIR.cur(vc, H)
    stick(false)
    vc.ctlAxes = nil
    AIR.set(vc, H, "angle", 0)
    AIR.hold(vc, 1.5, 1)
    P("SA stick W %s: pitch rate +%.3f rad/s after 0.8 s, 0.1 rad/s at %s s, joint %.2f", tag, w1, t_half and string.format("%.2f", t_half) or "never", jc)
    return w1, jc, t_half
  end
  local wa = w_run("alone (wheels + virtual gimbal)", false)
  local wb, jb, tb = w_run("with the hinge bound to pitch", true)
  V.check("stick_drives_gimbal", math.abs(jb - 3) < 0.3 and wb > 0.05,
    "W with the SAS on drove the bound hinge to %.2f deg and the nose came round (+%.3f rad/s; %.3f without the hinge)", jb, wb, wa)
  V.check("sas_lets_stick_gimbal_work", wb >= 0.75 * wa and math.abs(jb - 3) < 0.3, "the SAS does not take the hinge's turn back while W is held (both capped at the stick's max rate): %.3f vs %.3f rad/s", wb, wa)
  vc.setThrottle(0)
  return true
end

-- 4. TILT ENGINES (VTOL → forward)
T.tilt = function(vc)
  vc.releaseClamps()
  vc.setSAS("stability")
  AIR.hold(vc, 2.5, 1)
  local a0, agl0 = AIR.alt(vc)
  P("SA tilt lift-off: %.1f m above the ground", agl0)
  local F = AIR.frame(vc)
  local v0 = F.i.vel
  local t0 = time
  for _, h in ipairs({ 3, 5 }) do AIR.set(vc, h, "angle", 30) end
  AIR.hold(vc, 1.2, 1)
  local errs, worst = {}, 0
  local sumd = V3(0, 0, 0)
  for _, uid in ipairs({ 4, 6 }) do
    local e, aerr, perr = AIR.engine(vc, uid)
    errs[#errs + 1] = string.format("%d: %.2f deg %.3f m", uid, aerr, perr)
    worst = math.max(worst, aerr)
    sumd = add3(sumd, V3(e.dx, e.dy, e.dz))
  end
  -- the horizontal push: the velocity's change across the craft's up, against the engines' mean axis
  local F1 = AIR.frame(vc)
  local v1 = F1.i.vel
  AIR.hold(vc, 1.0, 1)
  local F2 = AIR.frame(vc)
  local v2 = F2.i.vel
  local dt = 1.0
  local acc = scl(sub(v2, v1), 1 / dt)
  local Uw = V.up(F2.i.com)
  local accH = sub(acc, scl(Uw, dot(acc, Uw)))
  local dW = F2.W(unit(sumd))
  local dH = sub(dW, scl(Uw, dot(dW, Uw)))
  local cosang = vlen(accH) > 0.05 and vlen(dH) > 0.05 and dot(unit(accH), unit(dH)) or 0
  P("SA tilt 30: joints %.2f / %.2f; engines %s; horizontal accel %.2f m/s2, along the engines' tilt %.2f (cos); engines' horizontal share %.2f",
    AIR.cur(vc, 3), AIR.cur(vc, 5), table.concat(errs, ", "), vlen(accH), cosang, vlen(dH))
  V.check("tilt_axes", worst < 1, "both engines' thrust axes on their posed axes (%s)", table.concat(errs, ", "))
  V.check("tilt_pushes", vlen(accH) > 1.5 and cosang > 0.9, "tilted 30 deg the push went forward: %.2f m/s2 at cos %.2f", vlen(accH), cosang)
  for _, h in ipairs({ 3, 5 }) do AIR.set(vc, h, "angle", 0) end
  AIR.hold(vc, 1.5, 0.6)
  local e3 = AIR.engine(vc, 4)
  P("SA tilt back: engine axis (%.3f, %.3f, %.3f)", e3.dx, e3.dy, e3.dz)
  V.check("tilt_back", e3.dy > 0.999, "back at 0 the engines push straight up (%.4f)", e3.dy)
  vc.setThrottle(0)
  return true
end

-- 7. PERSISTENCE: posed, into orbit through the fleet and a reload, warped
T.keep = function(vc)
  vc.releaseClamps()
  wait(1)
  for _, h in ipairs({ 3, 5 }) do AIR.set(vc, h, "angle", 30) end
  wait(2)
  local function snap(v)
    local t = {}
    for _, uid in ipairs({ 3, 5 }) do t[#t + 1] = string.format("h%d %.2f", uid, AIR.cur(v, uid)) end
    for _, uid in ipairs({ 4, 6 }) do
      local e, aerr = AIR.engine(v, uid)
      t[#t + 1] = string.format("e%d (%.3f,%.3f,%.3f)/%.1f", uid, e and e.dx or 0, e and e.dy or 0, e and e.dz or 0, aerr or -1)
    end
    return table.concat(t, " ")
  end
  local s0 = snap(vc)
  P("SA keep posed: %s", s0)
  -- into orbit through the fleet record, and the world loaded again
  local fo = findScript("flight_ops")
  fo.fleetSync(true)
  local f = save.get("fleet.craft") or {}
  local fid, rec = nil, nil
  for k, r in pairs(f) do if r.name == vc.craftName then fid, rec = k, r end end
  if not rec then V.check("fleet", false, "no fleet record for %s", tostring(vc.craftName)); return true end
  local hb = save.get("base.body")
  local b = space.body(hb)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local l = len(bx, by, bz)
  local ux, uy, uz = bx / l, by / l, bz / l
  local r = b.radius * 1.6 + 200
  local tx, ty, tz = -uz, 0, ux
  local tl = len(tx, ty, tz)
  if tl < 0.1 then tx, ty, tz, tl = 1, 0, 0, 1 end
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local vcirc = math.sqrt(b.mu / r)
  rec.body = hb
  rec.x, rec.y, rec.z = ux * r, uy * r, uz * r
  rec.vx, rec.vy, rec.vz = tx * vcirc, ty * vcirc, tz * vcirc
  rec.landed, rec.splashed, rec.crew, rec.stime = false, nil, true, space.time()
  f[fid] = rec
  save.set("fleet.craft", f)
  save.set("p_body", hb); save.set("p_x", rec.x); save.set("p_y", rec.y); save.set("p_z", rec.z)
  save.flush({ wait = true })
  local R0 = vc.R2
  scene.load("system")
  yield()
  f = save.get("fleet.craft") or {}
  if f[fid] then
    f[fid].x, f[fid].y, f[fid].z, f[fid].vx, f[fid].vy, f[fid].vz = rec.x, rec.y, rec.z, rec.vx, rec.vy, rec.vz
    f[fid].landed, f[fid].body = false, hb
    save.set("fleet.craft", f)
  end
  wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do if v.R2 == R0 then return nil end end
    return true
  end, 60, "the old world gone")
  wait_for(function()
    local gm = findScript("game_manager")
    return gm and not gm.loading and not gm.curtain
  end, 240, "the reload")
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid and v.R2 and v.R2 ~= R0 and #(v.R2.robo or {}) == 2 and v.R2.posed then return v end
    end
  end, 150, "the craft from the fleet")
  if not v2 then V.check("reload", false, "no craft after the reload"); return true end
  wait(3)
  local alt = AIR.alt(v2)
  local s1 = snap(v2)
  P("SA keep reload: alt %.0f m; %s -> %s", alt, s0, s1)
  V.check("orbit_reload_keeps", s0 == s1, "the joints and the thrust axes through a save, an orbit and a load: %s / %s", s0, s1)
  local fl = v2.R2.felt
  local fm = fl and len(fl[1], fl[2], fl[3]) or -1
  P("SA keep felt in orbit: %.3f m/s2", fm)
  V.check("weightless_in_orbit", fm >= 0 and fm < 0.5, "a joint feels %.3f m/s2 in orbit (nothing to lift)", fm)
  -- warp
  local w0 = space.warp()
  space.warp(10)
  wait(4)
  local wq = space.warp()
  space.warp(1)
  wait(2)
  local s2 = snap(v2)
  P("SA keep warp (x%.0f, from x%.0f): %s", wq, w0, s2)
  V.check("warp_keeps", s2 == s1, "through %.0fx warp: %s / %s", wq, s2, s1)
  -- moved again, in orbit
  for _, h in ipairs({ 3, 5 }) do AIR.set(v2, h, "angle", -20) end
  wait(3)
  local e = AIR.engine(v2, 4)
  local _, aerr = AIR.engine(v2, 4)
  P("SA keep moved in orbit: joints %.2f / %.2f, engine axis err %.2f, stalled %s", AIR.cur(v2, 3), AIR.cur(v2, 5), aerr, tostring(AIR.joint(v2, 3).stalled))
  V.check("moves_after", math.abs(AIR.cur(v2, 3) + 20) < 0.6 and aerr < 1, "the joints move in orbit after the reload and warp (%.2f, axis %.2f deg)", AIR.cur(v2, 3), aerr)
  -- a burn with them tilted: the push is the engines'
  v2.setSAS("off")
  local F1 = AIR.frame(v2)
  local v1 = F1.i.vel
  -- (the engines' axis in the world each tick, averaged: the tilted thrust
  -- turns the craft while it burns)
  local dW = V3(0, 0, 0)
  local t1 = time
  AIR.hold(v2, 1.0, 1, function()
    local Fk = AIR.frame(v2)
    local sumd = V3(0, 0, 0)
    for _, uid in ipairs({ 4, 6 }) do local ee = AIR.engine(v2, uid); sumd = add3(sumd, V3(ee.dx, ee.dy, ee.dz)) end
    dW = add3(dW, Fk.W(unit(sumd)))
  end)
  local F2 = AIR.frame(v2)
  local acc = scl(sub(F2.i.vel, F1.i.vel), 1 / math.max(time - t1, 1e-3))
  dW = unit(dW)
  -- (gravity's share over 1 s taken out)
  local gx, gy, gz = space.gravity(F2.i.com.x, F2.i.com.y, F2.i.com.z)
  local accT = sub(acc, V3(gx, gy, gz))
  local c = dot(unit(accT), dW)
  P("SA keep burn in orbit: %.2f m/s2 (gravity out), along the engines' axis cos %.3f", vlen(accT), c)
  V.check("orbit_burn_follows", vlen(accT) > 2 and c > 0.98, "the burn pushed along the tilted engines (cos %.3f)", c)
  v2.setThrottle(0)
  return true, v2
end

-- 5. STAGING WITH ROBOTICS
T.stage = function(vc)
  local HA, HB, EN = 2, 6, 7
  vc.releaseClamps()
  vc.setSAS("stability")
  AIR.set(vc, HB, "angle", 5)
  AIR.hold(vc, 4.0, 1)
  local wq = AIR.poseErr(vc)
  P("SA stage main before: parts vs records %.3f m:%s", wq, AIR.perr)
  P("SA stage before: hinge A %.2f, hinge B %.2f", AIR.cur(vc, HA), AIR.cur(vc, HB))
  -- the twist hinge on its way to 60, staged a third of the way there
  AIR.set(vc, HA, "angle", 60)
  AIR.hold(vc, 0.6, 1)
  local mid = AIR.cur(vc, HA)
  local n0 = {}
  for _, v in ipairs(findScripts("vessel_controller")) do if v.R2 then n0[v.R2] = true end end
  local ok = vc.stageNext()
  P("SA staged at hinge A %.2f: %s", mid, tostring(ok))
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.R2 and not n0[v.R2] and v.node and v.node.valid and v.R2 and #(v.R2.robo or {}) >= 1 and v.R2.posed then return v end
    end
  end, 20, "the lower stage as a craft")
  if not v2 then V.check("stage_craft", false, "no lower-stage craft"); return true end
  wait(0.5)
  local wp, wa, who = AIR.poseErr(v2)
  local e, aerr, perr = AIR.engine(v2, EN)
  P("SA stage new craft: %d robo, hinge B %.2f; parts vs their records: %.3f m / %.2f deg (worst part %s); engine axis %.2f deg %.3f m;%s",
    #(v2.R2.robo or {}), AIR.cur(v2, HB), wp, wa, tostring(who), aerr or -1, perr or -1, AIR.perr)
  V.check("separated_pose", wp < 0.03 and wa < 1.0, "the separated craft's parts are where its records say: %.3f m, %.2f deg (part %s)", wp, wa, tostring(who))
  V.check("separated_joint_state", math.abs(AIR.cur(v2, HB) - 5) < 0.3, "its hinge kept its angle (%.2f)", AIR.cur(v2, HB))
  -- both crafts' joints after: the upper's twist goes back, the lower's hinge moves and its thrust follows
  AIR.set(vc, HA, "angle", 0)
  AIR.set(v2, HB, "angle", -10)
  local t0 = time
  while time - t0 < 2.0 do
    v2.setThrottle(1)
    if v2.fuelFill then v2.fuelFill(1e6) end
    yield()
  end
  local e2, aerr2, perr2 = AIR.engine(v2, EN)
  local wp2, wa2 = AIR.poseErr(v2)
  P("SA stage after: upper twist %.2f, lower hinge %.2f%s; lower engine axis %.2f deg %.3f m; parts %.3f m %.2f deg",
    AIR.cur(vc, HA), AIR.cur(v2, HB), (AIR.joint(v2, HB) or {}).stalled and " STALLED" or "", aerr2 or -1, perr2 or -1, wp2, wa2)
  V.check("upper_joint_works", math.abs(AIR.cur(vc, HA)) < 0.6, "the upper craft's twist came back to 0 (%.2f)", AIR.cur(vc, HA))
  V.check("lower_joint_works", math.abs(AIR.cur(v2, HB) + 10) < 0.6 and (aerr2 or 99) < 1, "the lower craft's hinge went to %.2f and its thrust follows (%.2f deg)", AIR.cur(v2, HB), aerr2 or -1)
  return true
end

-- 5b. the joint leaves, its new craft's command part beyond it
T.stage2 = function(vc)
  local HB, EN = 4, 6
  vc.releaseClamps()
  vc.setSAS("stability")
  AIR.set(vc, HB, "angle", 8)
  AIR.hold(vc, 4.0, 1)
  local n0 = {}
  for _, v in ipairs(findScripts("vessel_controller")) do if v.R2 then n0[v.R2] = true end end
  local wp0, wa0 = AIR.poseErr(vc)
  local ok = vc.stageNext()
  P("SA stage2 staged at hinge %.2f: %s (main's parts vs records before %.3f m %.2f deg)", AIR.cur(vc, HB), tostring(ok), wp0, wa0)
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.R2 and not n0[v.R2] and v.node and v.node.valid and #(v.R2.robo or {}) >= 1 and v.R2.posed then return v end
    end
  end, 20, "the lower stage as a craft")
  if not v2 then V.check("stage_craft", false, "no lower-stage craft"); return true end
  wait(0.5)
  local r = AIR.joint(v2, HB)
  local wp, wa, who = AIR.poseErr(v2)
  local e, aerr = AIR.engine(v2, EN)
  P("SA stage2 new craft: hinge %.2f head %s; parts vs records %.3f m %.2f deg (worst %s); engine axis %.2f deg;%s",
    AIR.cur(v2, HB), tostring(r and r.head), wp, wa, tostring(who), aerr or -1, AIR.perr)
  V.check("separated_pose_inverted", wp < 0.03 and wa < 1.0, "the stage whose command part is beyond its joint: parts where its records say (%.3f m, %.2f deg)", wp, wa)
  AIR.set(v2, HB, "angle", 0)
  local t0 = time
  while time - t0 < 2.0 do
    if v2.setThrottle then v2.setThrottle(1) end
    if v2.fuelFill then v2.fuelFill(1e6) end
    yield()
  end
  local wp2, wa2 = AIR.poseErr(v2)
  local _, aerr2 = AIR.engine(v2, EN)
  P("SA stage2 after: hinge %.2f, parts %.3f m %.2f deg, engine axis %.2f deg", AIR.cur(v2, HB), wp2, wa2, aerr2 or -1)
  V.check("inverted_joint_works", math.abs(AIR.cur(v2, HB)) < 0.6 and wp2 < 0.03 and (aerr2 or 99) < 1, "its joint moves and the parts follow (%.2f, %.3f m)", AIR.cur(v2, HB), wp2)
  return true
end

-- 2/3/6. THE PLANE: jointed gear, folding tips, hinge canards, landing
T.plane = function(vc)
  local ids = AIR.ids
  local vn = vc.node
  local bf = findScript("base_facilities")
  local site = bf and bf.launchSite and bf.launchSite("runway")
  local function st()
    local i = assembly.info(vn)
    local b = home()
    if not (i and b) then return nil end
    local rx, up, rz = basis(vn)
    local Fa = vc.AERO and vc.AERO.frame
    local fn = Fa and Fa.n or { x = 0, y = 1, z = 0 }
    local ff = Fa and Fa.f or { x = 0, y = 0, z = -1 }
    local function w(v) return { x = rx.x * v.x + up.x * v.y + rz.x * v.z, y = rx.y * v.x + up.y * v.y + rz.y * v.z, z = rx.z * v.x + up.z * v.y + rz.z * v.z } end
    local n, t = w(fn), w(ff)
    local r = cross(n, t)
    local rel = sub(i.com, b)
    local rr = vlen(rel)
    local U = scl(rel, 1 / rr)
    local Vv = vlen(i.vel)
    local S = { i = i, b = b, n = n, t = t, r = r, U = U, V = Vv, alt = rr - b.radius,
      theta = math.asin(clamp(dot(n, U), -1, 1)), bank = math.asin(clamp(-dot(r, U), -1, 1)),
      vs = dot(i.vel, U), qn = -dot(i.angVel, cross(t, n)), pr = dot(i.angVel, n), hud = vc.tele and vc.tele.aero or nil }
    -- (from 2.5 m under the centre of mass, past its own tyres: bodies of their own)
    local o0 = sub(i.com, scl(U, 2.5))
    local h = raycast(o0.x, o0.y, o0.z, -U.x, -U.y, -U.z, 2500, vc.r2Own and { ignore = vc.r2Own(vn) } or vn)
    S.agl = h and (h.distance + 2.5) or 999
    if site then
      local Ng = unit(cross({ x = site.x, y = site.y, z = site.z }, site.fwd))
      local trk = unit(cross(Ng, U))
      local hn = unit(sub(n, scl(U, dot(n, U))))
      S.herr = math.atan2(dot(cross(hn, trk), U), dot(hn, trk))
    end
    return S
  end
  local function fly(S, theta_t, bank_t, yaw_extra)
    local p = -clamp(4.0 * (theta_t - S.theta) - 1.6 * S.qn, -1, 1)
    local r = clamp(2.5 * (bank_t - S.bank) - 0.8 * S.pr, -1, 1)
    local slip = S.hud and S.hud.slip or 0
    vc.AERO.cmd = { p = p, y = clamp(-0.02 * slip + (yaw_extra or 0), -1, 1), r = r }
  end
  local S
  local function cruise(secs, h_t, fn, thr)
    local t0 = time
    while time - t0 < secs do
      yield()
      if not vn.valid then return false end
      S = st()
      vc.setThrottle(thr or 1)
      local hud = S.hud or {}
      -- (h_t over the highest ground in the next 300 m along the nose, as
      -- perfbench's plane holds it: the ground straight down is not enough)
      local ga2 = S.alt - S.agl
      local fw = unit(sub(S.n, scl(S.U, dot(S.n, S.U))))
      for k2 = 1, 6 do
        local a = (k2 * 50) / S.b.radius
        local dir = unit(add3(scl(S.U, math.cos(a)), scl(fw, math.sin(a))))
        local o = add3(S.b, scl(dir, S.b.radius + S.alt + 200))
        local h = raycast(o.x, o.y, o.z, -dir.x, -dir.y, -dir.z, 900, vc.r2Own and { ignore = vc.r2Own(vn) } or vn)
        if h then ga2 = math.max(ga2, S.alt + 200 - h.distance) end
      end
      local gam_t = clamp(0.04 * (h_t - (S.alt - ga2)), D(-6), D(10))
      fly(S, gam_t + D(hud.aoa or 3), clamp(-1.4 * (S.herr or 0), D(-25), D(25)))
      if fn then fn(S, time - t0) end
      if S.V < 20 then V.check("flying", false, "the plane fell out of the sky (V %.1f, agl %.1f)", S.V, S.agl); return false end
      if time >= (AIR.tl or 0) then
        AIR.tl = time + 1.0
        P("SA T V %.1f agl %.1f theta %.1f bank %.1f aoa %.1f lift %.2f drag %.3f | joints %s", S.V, S.agl, deg(S.theta), deg(S.bank), hud.aoa or 0, hud.lift or 0, hud.drag or 0, SM.curs(vc))
      end
    end
    return true
  end
  -- the roll on the jointed gear
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0, air, phase = time, 0, "roll"
  local ga
  local tyres0 = 0
  for _, w in ipairs(vc.R2.wheels or {}) do if w.jointed then tyres0 = tyres0 + 1 end end
  P("SA plane: %d wheels, %d on joints, %d tyres out", #(vc.R2.wheels or {}), (function() local n = 0 for _, w in ipairs(vc.R2.wheels or {}) do if w.onRobo then n = n + 1 end end return n end)(), tyres0)
  while true do
    yield()
    if not vn.valid then V.check("takeoff", false, "the plane is gone"); return true end
    S = st()
    vc.setThrottle(1)
    local yaw = clamp(3.0 * (S.herr or 0), -1, 1)
    if S.V < 40 then
      local p = (S.V > 15) and -clamp(3.0 * (D(1) - S.theta) - 1.0 * S.qn, -1, 1) or 0
      vc.AERO.cmd = { p = p, y = yaw, r = clamp(-2.5 * S.bank, -1, 1) }
    else fly(S, D(11), 0, yaw) end
    ga = ga or S.alt
    if not vc.R2.onWheels and S.alt > ga + 1.5 and S.V > 30 then air = air + 1 / 60 else air = 0 end
    if air > 0.6 then break end
    if time - t0 > 45 then break end
  end
  local tko = time - t0
  V.check("takeoff_on_jointed_gear", air > 0.6, "airborne after %.1f s at %.1f m/s, rolling on hinge-mounted gear", tko, S.V)
  if air <= 0.6 then return true end
  if not cruise(14, 100) then return true end
  -- ── 3. the gear up, by its hinges ──
  local com0, col0 = AIR.com(vc), AIR.col(vc)
  local drag0, lift0 = (S.hud or {}).drag or 0, (S.hud or {}).lift or 0
  local gb0 = {}
  for _, g in ipairs(ids.gear) do
    local b = AIR.body(vc, g.part)
    gb0[#gb0 + 1] = b and string.format("%.2f,%.2f,%.2f", b.x, b.y, b.z) or "-"
    -- (main gear: fold inward, the leg toward the fuselage; nose: back)
    AIR.set(vc, g.hinge, "angle", g.s == 0 and 85 or 85 * g.s)
  end
  if not cruise(5, 100) then return true end
  local com1 = AIR.com(vc)
  local gb1, gerr = {}, 0
  for _, g in ipairs(ids.gear) do
    local b = AIR.body(vc, g.part)
    local n = vc.r2NodeOf(vc.node, g.part)
    gb1[#gb1 + 1] = b and string.format("%.2f,%.2f,%.2f", b.x, b.y, b.z) or "-"
    if b and n then gerr = math.max(gerr, len(b.x - n.x, b.y - n.y, b.z - n.z)) end
  end
  local tl = {}
  for _, w in ipairs(vc.R2.wheels or {}) do
    local lx, ly, lz = SP.tyreLocal(vc, w)
    tl[#tl + 1] = string.format("w%d %s (%.2f,%.2f,%.2f)", w.uid, w.jointed and "out" or "in", lx or 0, ly or 0, lz or 0)
  end
  P("SA gear up: joints %s; gear bodies %s -> %s (model vs node %.3f m); tyres %s; CoM %s -> %s; drag %.3f -> %.3f",
    SM.curs(vc), table.concat(gb0, " "), table.concat(gb1, " "), gerr, table.concat(tl, " "), AIR.fmt(com0), AIR.fmt(com1), drag0, (S.hud or {}).drag or 0)
  V.check("gear_body_follows", gerr < 0.05, "the gear legs' drag bodies are where the hinges put them (%.3f m)", gerr)
  V.check("com_follows_gear", vlen(sub(com1, com0)) > 0.01, "the centre of mass moved %.3f m with the gear", vlen(sub(com1, com0)))
  -- ── 2. the tips folded: one, then both ──
  local tip = ids.tips[1]
  local s0 = AIR.surf(vc, tip.part)
  local tz0 = s0 and V3(s0.Z.x, s0.Z.y, s0.Z.z) or V3(0, 0, 0)
  local col1 = AIR.col(vc)
  local tq0 = vc.AERO.tq
  local roll_ax = st().n
  local function tip_lift(t) local f = AIR.moment(vc, t.part); local F = AIR.frame(vc); return dot(F.W(f), st().U) end
  local l0 = tip_lift(tip)
  AIR.set(vc, tip.hinge, "angle", 80 * tip.s)
  local ail = 0
  if not cruise(4, 100, function(S2) ail = math.max(ail, math.abs((vc.AERO.cmd or {}).r or 0)) end) then return true end
  local s1 = AIR.surf(vc, tip.part)
  local serr = AIR.surfErr(vc, tip.part)
  local l1 = tip_lift(tip)
  local col2 = AIR.col(vc)
  P("SA one tip up: joint %.2f; its surface's normal %s -> %s (model vs node %.2f deg); its lift up %.3f -> %.3f kN; CoL %s -> %s; peak roll stick %.2f",
    AIR.cur(vc, tip.hinge), AIR.fmt(tz0), s1 and AIR.fmt(s1.Z) or "-", serr, l0, l1, AIR.fmt(col1), AIR.fmt(col2), ail)
  V.check("folded_surface_follows", serr >= 0 and serr < 1, "the folded tip's lifting plane is the part's (%.2f deg)", serr)
  V.check("folded_lift_drops", math.abs(l1) < 0.35 * math.abs(l0) + 0.02, "the folded tip lifts %.3f kN of %.3f flat", l1, l0)
  V.check("col_follows", vlen(sub(col2, col1)) > 0.02, "the centre of lift moved %.3f m", vlen(sub(col2, col1)))
  local tip2 = ids.tips[2]
  AIR.set(vc, tip2.hinge, "angle", 80 * tip2.s)
  if not cruise(4, 100) then return true end
  P("SA both tips up: joints %s; CoL %s; lift %.2f", SM.curs(vc), AIR.fmt(AIR.col(vc)), (S.hud or {}).lift or 0)
  for _, t in ipairs(ids.tips) do AIR.set(vc, t.hinge, "angle", 0) end
  if not cruise(4, 100) then return true end
  local col3 = AIR.col(vc)
  V.check("unfold_back", vlen(sub(col3, col1)) < 0.01, "unfolded, the centre of lift is back (%.3f m off)", vlen(sub(col3, col1)))
  -- ── 6. the hinge canards: their pitching moment by their angle ──
  local pitch_ax = V3(0, 0, 1)   -- the plane's pitch axis in the vessel frame: across (z)
  local function canard_m()
    local m = 0
    for _, c in ipairs(ids.canards) do local _, mm = AIR.moment(vc, c.part); m = m + dot(mm, pitch_ax) end
    return m
  end
  local m0 = canard_m()
  local mres = {}
  for _, ang in ipairs({ 10, -10 }) do
    for _, c in ipairs(ids.canards) do AIR.set(vc, c.hinge, "angle", ang) end
    local ok = cruise(2.5, 100)
    if not ok then return true end
    local m = canard_m()
    local se = AIR.surfErr(vc, ids.canards[1].part)
    mres[#mres + 1] = m
    P("SA canards %+d: joints %.2f / %.2f, pitching moment %.3f kN m (at 0: %.3f), surface vs node %.2f deg, elevon stick %.2f",
      ang, AIR.cur(vc, ids.canards[1].hinge), AIR.cur(vc, ids.canards[2].hinge), m, m0, se, (vc.AERO.cmd or {}).p or 0)
  end
  for _, c in ipairs(ids.canards) do AIR.set(vc, c.hinge, "angle", 0) end
  V.check("hinge_surface_acts", mres[1] * mres[2] < 0 and math.abs(mres[1] - mres[2]) > 0.2,
    "the hinge canards' pitching moment follows their angle: %+.3f at +10, %+.3f at -10 kN m", mres[1], mres[2])
  if not cruise(3, 100) then return true end
  -- ── 3. the gear down, and a landing on it ──
  for _, g in ipairs(ids.gear) do AIR.set(vc, g.hinge, "angle", 0) end
  if not cruise(4, 100) then return true end
  local wout = 0
  for _, w in ipairs(vc.R2.wheels or {}) do if w.jointed then wout = wout + 1 end end
  P("SA gear down: joints %s, tyres out %d", SM.curs(vc), wout)
  -- the approach: idle-ish, a shallow sink to the ground ahead, a flare
  local touch, tv, t_land, maxv = nil, 0, time, 0
  while time - t_land < 150 do
    yield()
    if not vn.valid then break end
    S = st()
    local hud = S.hud or {}
    local sink_t = (S.agl > 40) and -7 or ((S.agl > 8) and -2.5 or -0.6)
    local thr = clamp(0.35 + 0.08 * (S.V < 38 and (38 - S.V) or 0) + 0.15 * (sink_t - S.vs), 0, 1)
    if touch then thr = 0 end
    vc.setThrottle(thr)
    local gam_t = clamp(sink_t / math.max(S.V, 10), D(-9), D(3))
    if touch then
      fly(S, D(1), 0, clamp(3.0 * (S.herr or 0), -1, 1))
    else
      fly(S, gam_t + D(hud.aoa or 3), 0, 0)
    end
    if not touch and vc.R2.onWheels then
      touch, tv = time, S.vs
      P("SA touchdown at %.1f m/s, sink %.2f m/s, agl %.2f", S.V, S.vs, S.agl)
      tap("b")
    end
    if touch and S.V < 1.0 then break end
    maxv = math.max(maxv, S.V)
    if time >= (AIR.tl or 0) then AIR.tl = time + 1.0; P("SA L V %.1f agl %.1f vs %.2f thr %.2f onWheels %s", S.V, S.agl, S.vs, thr, tostring(vc.R2.onWheels)) end
  end
  local up = V.upness(vn)
  local alive = vn.valid and not vc.destroyed
  local outN = 0
  for _, w in ipairs(vc.R2.wheels or {}) do if w.jointed then outN = outN + 1 end end
  P("SA landed: %s, upness %.2f, V %.2f, tyres out %d, rolled %.1f s", touch and "touched down" or "never touched", up, S and S.V or -1, outN, touch and (time - touch) or 0)
  V.check("lands_on_jointed_gear", touch ~= nil and alive and up > 0.8 and (S and S.V or 9) < 3, "touched down at %.2f m/s sink on hinge-mounted gear and rolled out upright (upness %.2f, %.2f m/s, %d tyres)", tv or 0, up, S and S.V or -1, outN)
  return true
end

local function run_sair()
  local rig = params.rig or "gimbal"
  local brig = (rig == "keep") and "keep" or rig
  local vc = AIR.launch(brig)
  if not vc then V.result(); return end
  local R2 = vc.R2
  P("SA craft: %d robo, %d wheels, %d engines, mode %s", #(R2.robo or {}), #(R2.wheels or {}), #(vc.engineAxes and vc.engineAxes() or {}), tostring(R2.mode))
  local fn = T[rig]
  if fn then fn(vc) end
  V.result()
end
SP_RUN.sair = run_sair
end)() end
