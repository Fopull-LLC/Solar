-- ── interaction points on parts a joint has moved (servoprobe.sh, mode sjf) ──
-- Spliced after servoair_modes.lua (and SM, SP, JP, V, IV before it). On the
-- pad, clamped: a tank with a pod on top; on one flank a Servo Hinge (axis
-- the craft's X) carrying a Command Seat, on the other a Servo Hinge
-- carrying a Docking Port. The hinges swing (40°, -35°), and against each
-- part's node as robo_write posed it the probe reads:
--   * partFrameNow (the crew's repair lock, a doll's place, an item set
--     down): origin and up axis, in the tick frame;
--   * the same against the drawn pose, relative to the unjointed pod (the
--     relative vector does not depend on which pose it is read in);
--   * the port's face (dockFaces, the capture's own read) and its axis;
--   * the crew position on the seat (setStation): podLX against the seat
--     node (command_seat's test) and the seated passenger's point
--     (focusX: pod_world);
--   * iva.partFrame;
--   * what the bug was: the blueprint point's distance from the part;
--   * the cost of partFrameNow on a jointed and an unjointed part, and the
--     crew's mass on the craft (crewMassScan).
-- `JF` lines, `VP PASS|FAIL`, `VP RESULT`.
do (function()
local JF = {}
local function V3(x, y, z) return { x = x, y = y, z = z } end
local UPV = V3(0, 1, 0)
local function AR(uid, id, x, y, z, X, Y, o)
  o = o or {}
  local Z = cross(X, Y)
  local yaw, pitch, roll = eulerOf(X, Y, Z)
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll,
           parent = o.parent or 0, att = o.att or "surface", sym = 0, mir = "", stage = o.stage or 0 }
end
local SEAT, PORT, H1, H2, POD = 4, 6, 3, 5, 2

function JF.bp()
  local P_ = {}
  local function add(r) P_[#P_ + 1] = r end
  add(AR(1, "tankM", 0, 1.0, 0, V3(1, 0, 0), UPV, { att = "" }))
  add(AR(POD, "pod", 0, 2.15, 0, V3(1, 0, 0), UPV, { parent = 1, att = "top" }))
  -- hinge on the +Z flank, its Y out (+Z), its axis (Z) the craft's X; the seat beyond it
  add(AR(H1, "hinge", 0, 1.0, 0.7, V3(0, 1, 0), V3(0, 0, 1), { parent = 1 }))
  add(AR(SEAT, "seat", 0, 1.0, 1.2, V3(1, 0, 0), UPV, { parent = H1 }))
  -- hinge on the −Z flank, its Y out (−Z), its axis the craft's X; a port on its head, facing out
  add(AR(H2, "hinge", 0, 1.0, -0.7, V3(0, -1, 0), V3(0, 0, -1), { parent = 1 }))
  add(AR(PORT, "dockPort", 0, 1.0, -1.04, V3(1, 0, 0), V3(0, 0, -1), { parent = H2 }))
  return { parts = P_, name = "Joint frames" }
end

function JF.launch()
  V.tag = "jointframes"
  local bp = JF.bp()
  P("JF rig: pod on a tank, a Command Seat on a hinge, a Docking Port on a hinge, %d parts", #bp.parts)
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
  local chk = B.launchCheck and B.launchCheck() or {}
  P("JF builder: launch %s", chk.block and ("BLOCKED: " .. chk.block) or "allowed")
  local BC = findScript("builder_crew")
  if BC then
    if BC.unseatMember then BC.unseatMember(1) end
    local ok, why = BC.seatMember(1, POD, 1)
    P("JF crew -> %d: %s %s", POD, tostring(ok), tostring(why))
  end
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#bp.parts, 150)
  if not vc then V.check("rollout", false, "no craft"); return end
  wait(3)
  return vc
end

local function joint(vc, uid) for _, r in ipairs(vc.R2.robo or {}) do if r.uid == uid then return r end end end
local function set(vc, uid, a)
  local r = joint(vc, uid)
  if not r then P("JF no joint %d", uid); return end
  if type(r.d.st) ~= "table" then r.d.st = {} end
  r.d.st.angle = a
end
-- the tick frame (assembly.info) and vessel → world
local function frame(vc)
  local i = assembly.info(vc.node)
  local R, U = i.right, i.up
  local Z = cross(R, U)
  return i, function(v) return V3(R.x * v.x + U.x * v.y + Z.x * v.z, R.y * v.x + U.y * v.y + Z.y * v.z, R.z * v.x + U.z * v.y + Z.z * v.z) end
end
local function dist(a, b) return len(a.x - b.x, a.y - b.y, a.z - b.z) end
local function ang(a, b) return math.deg(math.acos(clamp(dot(unit(a), unit(b)), -1, 1))) end

-- every measure in one pass (one read of the frame) → table
function JF.measure(vc, tag)
  local i, W = frame(vc)
  local o = i.origin
  local m = { tag = tag }
  for _, u in ipairs({ SEAT, PORT, POD }) do
    local n = vc.r2NodeOf(vc.node, u)
    local F = vc.partFrameNow(u)
    local d = vc.partRec(u)
    if n and F and d then
      local _, Yn = basis(n)
      local want = V3(o.x, o.y, o.z)
      local wn = W(V3(n.x, n.y, n.z))
      want = V3(want.x + wn.x, want.y + wn.y, want.z + wn.z)
      local wb = W(V3(d.x, d.y, d.z))
      local blue = V3(o.x + wb.x, o.y + wb.y, o.z + wb.z)
      -- the part's up as posed, against the frame's up turned by the
      -- part's own blueprint rotation (iva.partFrame's convention)
      local Xb, Yb, Zb = basis(d)
      local Fy = V3(F.rx * Yb.x + F.ux * Yb.y + F.zx * Yb.z, F.ry * Yb.x + F.uy * Yb.y + F.zy * Yb.z, F.rz * Yb.x + F.uz * Yb.y + F.zz * Yb.z)
      m[u] = { perr = dist(V3(F.ox, F.oy, F.oz), want), aerr = ang(Fy, W(Yn)), blue = dist(blue, want), F = F, n = n, want = want }
    end
  end
  -- drawn, relative to the pod: (F_u − F_pod) against (worldPos_u − worldPos_pod)
  for _, u in ipairs({ SEAT, PORT }) do
    local a, b = m[u], m[POD]
    if a and b and a.n.worldPos and b.n.worldPos then
      local wa, wb = a.n.worldPos, b.n.worldPos
      a.rel = len((a.F.ox - b.F.ox) - (wa.x - wb.x), (a.F.oy - b.F.oy) - (wa.y - wb.y), (a.F.oz - b.F.oz) - (wa.z - wb.z))
    end
  end
  -- the port's face (the capture's own read)
  for _, f in ipairs(vc.dockFaces() or {}) do
    if f.uid == PORT and m[PORT] then
      local _, Yn = basis(m[PORT].n)
      m.face = { perr = dist(V3(f.x, f.y, f.z), m[PORT].want), aerr = ang(V3(f.ax, f.ay, f.az), W(Yn)) }
    end
  end
  -- iva.partFrame (the IVA rooms, the dolls inside them)
  local I = findScript("iva")
  if I and I.partFrame and m[SEAT] then
    local ok, oo, X, Y = pcall(I.partFrame, vc, SEAT)
    if ok and oo then
      local _, Yn = basis(m[SEAT].n)
      m.iva = { perr = dist(V3(oo.x, oo.y, oo.z), m[SEAT].want), aerr = ang(V3(Y.x, Y.y, Y.z), W(Yn)) }
    end
  end
  P("JF M %s | joints %s | seat frame %.4f m %.2f° (blueprint %.3f m) rel-drawn %.4f | port frame %.4f m %.2f° (blueprint %.3f m) rel-drawn %.4f | face %.4f m %.2f° | iva %.4f m %.2f°",
    tag, SM.curs(vc), m[SEAT] and m[SEAT].perr or -1, m[SEAT] and m[SEAT].aerr or -1, m[SEAT] and m[SEAT].blue or -1, m[SEAT] and m[SEAT].rel or -1,
    m[PORT] and m[PORT].perr or -1, m[PORT] and m[PORT].aerr or -1, m[PORT] and m[PORT].blue or -1, m[PORT] and m[PORT].rel or -1,
    m.face and m.face.perr or -1, m.face and m.face.aerr or -1, m.iva and m.iva.perr or -1, m.iva and m.iva.aerr or -1)
  return m
end
local function ok_m(m, tol)
  tol = tol or 0.01
  local function g(t) return t and t.perr < tol and t.aerr < 0.5 end
  return g(m[SEAT]) and g(m[PORT]) and g(m.face) and (m.iva == nil or g(m.iva)) and (m[SEAT].rel or 0) < tol and (m[PORT].rel or 0) < tol
end

-- the crew position on the seat: podLX against the seat node, the seated
-- passenger's point (focusX, pod_world) against the seat's tick pose
function JF.station(vc, tag)
  local n = vc.r2NodeOf(vc.node, SEAT)
  local i, W = frame(vc)
  local o = i.origin
  local wn = W(V3(n.x, n.y, n.z))
  local want = V3(o.x + wn.x, o.y + wn.y, o.z + wn.z)
  local pl = len((vc.podLX or 0) - n.x, (vc.podLY or 0) - n.y, (vc.podLZ or 0) - n.z)
  local fe = dist(V3(vc.focusX or 0, vc.focusY or 0, vc.focusZ or 0), want)
  P("JF S %s | station %s podSeat %s | podL off the seat node %.4f m | the seated point (focus) off the seat %.4f m", tag, tostring(vc.crewStation()), tostring(vc.podSeat), pl, fe)
  return pl, fe
end

-- the cost of partFrameNow: a jointed part, an unjointed one (µs a call)
function JF.cost(vc)
  local N = 20000
  local function t(u)
    local w0 = W()
    for _ = 1, N do vc.partFrameNow(u) end
    return (W() - w0) / N * 1e6
  end
  local tj, tu, tp = t(SEAT), t(POD), -1
  if vc.partPosed then
    local w0 = W()
    for _ = 1, N do vc.partPosed(POD) end
    tp = (W() - w0) / N * 1e6
  end
  P("JF COST partFrameNow: jointed part %.2f µs, unjointed %.2f µs; partPosed on an unjointed part %.3f µs (%d calls each)", tj, tu, tp, N)
end

local T = {}
T.frames = function(vc)
  local i = assembly.info(vc.node)
  P("JF MASS info %.4f t, trueMass %.4f t, crew %.4f t on %s (aboard %s)", i.mass or -1, (vc.trueMass and vc.trueMass()) or -1, vc.CREW_TT or -1,
    (function() local s = {} for u, m in pairs(vc.CREW_TU or {}) do s[#s + 1] = u .. "=" .. m end return table.concat(s, ",") end)(), tostring(vc.crewAboard))
  -- (the suit and wearer, CREW_T, and what their pack holds: crewSeatT)
  local want = vc.crewSeatT and vc.crewSeatT(findScript("crew") and findScript("crew").activeId and findScript("crew").activeId() or nil) or 0.1
  V.check("crew_mass", math.abs((vc.CREW_TT or 0) - want) < 1e-6 and want >= 0.1 - 1e-9, "the crew in the pod weighs on the craft with their pack (%.3f t, want %.3f)", vc.CREW_TT or -1, want)
  local m0 = JF.measure(vc, "rest")
  V.check("rest", ok_m(m0, 0.005), "at rest every read is the part's blueprint pose")
  set(vc, H1, 40); set(vc, H2, -35)
  -- while they swing: every frame, the worst
  local t0, worst = time, 0
  while time - t0 < 2.5 do
    yield()
    local m = JF.measure(vc, string.format("swing+%.2f", time - t0))
    for _, u in ipairs({ SEAT, PORT }) do if m[u] then worst = math.max(worst, m[u].perr, m[u].rel or 0) end end
  end
  local m1 = JF.measure(vc, "swung")
  V.check("swing_tracks", worst < 0.01, "while the hinges swing, the frames stay on the parts (worst %.4f m)", worst)
  V.check("swung", ok_m(m1), "at 40° / -35°: the seat's and the port's frames, the port's face and the IVA frame are on the posed parts")
  V.check("was_off", (m1[SEAT] and m1[SEAT].blue or 0) > 0.1 and (m1[PORT] and m1[PORT].blue or 0) > 0.1,
    "the blueprint points are well off the parts there (seat %.3f m, port %.3f m): what the bug was", m1[SEAT] and m1[SEAT].blue or -1, m1[PORT] and m1[PORT].blue or -1)
  -- the crew to the seat (podLX: command_seat's test; focus: the seated point)
  vc.setStation(SEAT)
  wait(0.5)
  local pl, fe = JF.station(vc, "seat")
  V.check("station_on_seat", pl < 0.01 and fe < 0.01, "the crew position on the swung seat: podL %.4f m, seated point %.4f m", pl, fe)
  -- moved again with the crew there
  set(vc, H1, -25)
  wait(3)
  pl, fe = JF.station(vc, "seat_moved")
  V.check("station_follows", pl < 0.01 and fe < 0.01, "the seat swung again with the crew in it: podL %.4f m, seated point %.4f m", pl, fe)
  local i2 = assembly.info(vc.node)
  P("JF MASS seated %.4f t, crew %s", i2.mass or -1,
    (function() local s = {} for u, m in pairs(vc.CREW_TU or {}) do s[#s + 1] = u .. "=" .. m end return table.concat(s, ",") end)())
  V.check("crew_mass_moves", (vc.CREW_TU or {})[SEAT] ~= nil or (vc.CREW_TU or {})[POD] ~= nil, "the crew's mass is on the craft at its seat")
  JF.cost(vc)
  set(vc, H1, 0); set(vc, H2, 0)
  wait(4)
  local m2 = JF.measure(vc, "back")
  V.check("back", ok_m(m2, 0.005) and (m2[SEAT].blue or 1) < 0.005, "back at rest: the blueprint pose again (seat %.4f m off it)", m2[SEAT] and m2[SEAT].blue or -1)
  vc.setStation(POD)
  return true
end

local function run_sjf()
  local vc = JF.launch()
  if not vc then V.result(); return end
  P("JF craft: %d robo, chain %s", #(vc.R2.robo or {}),
    (function() local s = {} for u, c in pairs(vc.R2.chain or {}) do s[#s + 1] = u .. ":" .. #c end return table.concat(s, ",") end)())
  T[params.rig or "frames"](vc)
  V.result()
end
SP_RUN.sjf = run_sjf
end)() end
