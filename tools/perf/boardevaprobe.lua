-- BOARDEVAPROBE: boarding and EVA in the player's hands (Ty, playtest
-- 2026-11-11), in the real game. Run by tools/perf/boardevaprobe.sh; one
-- `BE RESULT <step>: PASS|FAIL …` line a step.
--
-- strs: stop =
--   jitter  — a station in orbit; EVA; Repair the pod through item_hand (the
--             menu's own path), and every frame, in the camera pass, the suit
--             and the camera in the pod's DRAWN frame: the frame-to-frame
--             motion relative to the craft (mm, deg). First person and third,
--             the station still and tumbling. `JIT` lines.
--   orbit   — the same station with three aboard (a Pod Mk2): F opens the
--             picker, 2 picks the second member, they go out; the portrait
--             EVA button sends the third out; boarding by the hatch handrail.
--   ground  — a pod on the pad: walk to it, E on its ladder, climb, the
--             "Enter hatch" prompt, E boards; F back out onto the ladder.
--   (shot names: <stop>_<tag> holds at a step for `floptle shot`)
-- params: slot (14), seed, quit
defaults = { slot = 14, seed = 1911564384, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("BE %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local function R(step, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), step, ok and "PASS" or "FAIL", ...) end
local STOP, HOLDAT = nil, nil
local NODE, CO
local function yield() coroutine.yield() end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false } end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function hold_here(tag)
  P("HOLD %s", tag)
  while true do yield() end
end
local function shot_at(tag)
  if HOLDAT == tag then hold_here(tag) end
end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

local SLOT
local function boot()
  SLOT = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. SLOT .. "/terrain")
  if save.deleteSlot then save.deleteSlot(SLOT) end
  save.slot(SLOT)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  local ns = findScript("menu_newsave")
  save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  P("world ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function stack(ids)
  local l, y, u = {}, 0, 0
  local H = { engineM = 1.6, tankM = 1.5, tankS = 1.0, locker = 0.5, pod = 0.8, podMk2 = 1.0, cabin = 1.4 }
  for _, id in ipairs(ids) do
    local h = H[id] or 1.0
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = 0 }
    y = y + h
  end
  return l
end

local function piloted()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end

-- Roll a blueprint out of the VAB onto the pad. → vc
local function rollout(bp)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  local a = find("Astronaut")
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  local B = findScript("builder")
  wait(1)
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_for(function()
    local v = piloted()
    if v then local i = assembly.info(v.node); if i and #i.parts >= #bp then return v end end
  end, 200, "the craft on the pad")
  return vc
end

-- Put the pad's craft in a circular orbit through its fleet record. → vc
local function to_orbit(vc)
  wait(3)
  vc.releaseClamps()
  wait(2)
  local fo = findScript("flight_ops")
  fo.fleetSync()
  local f = save.get("fleet.craft") or {}
  local fid, rec = nil, nil
  for k, r in pairs(f) do if r.name == vc.craftName then fid, rec = k, r end end
  if not rec then P("no fleet record for %s", tostring(vc.craftName)); return nil end
  local home = save.get("base.body")
  local b = space.body(home)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local l = len(bx, by, bz)
  local ux, uy, uz = bx / l, by / l, bz / l
  local r = b.radius * 1.6 + 200
  local tx, ty, tz = -uz, 0, ux
  local tl = len(tx, ty, tz)
  if tl < 0.1 then tx, ty, tz, tl = 1, 0, 0, 1 end
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local vcirc = math.sqrt(b.mu / r)
  rec.body = home
  rec.x, rec.y, rec.z = ux * r, uy * r, uz * r
  rec.vx, rec.vy, rec.vz = tx * vcirc, ty * vcirc, tz * vcirc
  rec.landed, rec.splashed, rec.crew, rec.stime = false, nil, true, space.time()
  f[fid] = rec
  save.set("fleet.craft", f)
  P("station %s: orbit r %.0f (alt %.0f), v %.1f m/s", tostring(rec.name), r, r - b.radius, vcirc)
  save.set("p_body", home)
  save.set("p_x", rec.x); save.set("p_y", rec.y); save.set("p_z", rec.z)
  save.flush({ wait = true })
  scene.load("system")
  yield()
  for _ = 1, 3 do
    local f2 = save.get("fleet.craft") or {}
    f2[fid] = rec
    save.set("fleet.craft", f2)
    yield()
  end
  wait_for(world_ready, 300, "the world again")
  return wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid and v.crewAboard then return v end
    end
  end, 120, "the station back in orbit with its crew")
end

local function inv() return findScript("inventory") end
local function give(item, n)
  local I = inv()
  local have = I.itemCount("astro", item)
  if have < n then I.addItem("astro", item, n - have, { force = true }) end
end

-- ── JITTER: the suit and the camera against the part, frame by frame ──────
-- In the camera pass (planet_camera.deferLate), drawn poses only: the suit's
-- node (a fresh find handle) and the camera's published place, both put in
-- the pod's DRAWN frame (partFrameNow(uid, true)) read in the same pass.
J = { on = false }
local function jit_reset(vc, uid, tag)
  J = { on = true, vc = vc, uid = uid, tag = tag, n = 0, prev = nil,
        ds = {}, dc = {}, da = {}, df = {} }
end
local function stats(t)
  local n = #t
  if n == 0 then return 0, 0, 0, 0 end
  local s, s2, mx = 0, 0, 0
  local c = {}
  for i = 1, n do s = s + t[i]; s2 = s2 + t[i] * t[i]; if t[i] > mx then mx = t[i] end; c[i] = t[i] end
  table.sort(c)
  return s / n, math.sqrt(s2 / n), c[math.max(1, math.floor(n * 0.95))], mx
end
local function jit_report()
  J.on = false
  local m1, r1, p1, x1 = stats(J.ds)
  local m2, r2, p2, x2 = stats(J.dc)
  local m3, r3, p3, x3 = stats(J.da)
  local m4, r4, p4, x4 = stats(J.df)
  P("JIT %s frames %d | suit vs part mm: mean %.1f rms %.1f p95 %.1f max %.1f | cam vs part mm: mean %.1f rms %.1f p95 %.1f max %.1f | cam turn deg: mean %.3f p95 %.3f max %.3f | suit turn deg: mean %.3f p95 %.3f max %.3f",
    J.tag, J.n, m1 * 1000, r1 * 1000, p1 * 1000, x1 * 1000, m2 * 1000, r2 * 1000, p2 * 1000, x2 * 1000, m3, p3, x3, m4, p4, x4)
  return { suit_rms = r1 * 1000, suit_p95 = p1 * 1000, suit_max = x1 * 1000, cam_rms = r2 * 1000, cam_p95 = p2 * 1000, cam_max = x2 * 1000,
           cam_deg95 = p3, suit_deg95 = p4, n = J.n }
end
local function ang(ax, ay, az, bx, by, bz)
  local d = ax * bx + ay * by + az * bz
  return math.deg(math.acos(math.max(-1, math.min(1, d))))
end
local function jit_frame()
  if not J.on then return end
  local vc, uid = J.vc, J.uid
  local F = vc.partFrameNow(uid, true)
  local a = find("Astronaut")
  local pc = findScript("planet_camera")
  if not (F and a and pc) then return end
  local function loc(x, y, z)
    local qx, qy, qz = x - F.ox, y - F.oy, z - F.oz
    return qx * F.rx + qy * F.ry + qz * F.rz, qx * F.ux + qy * F.uy + qz * F.uz, qx * F.zx + qy * F.zy + qz * F.zz
  end
  local function dir(x, y, z) return x * F.rx + y * F.ry + z * F.rz, x * F.ux + y * F.uy + z * F.uz, x * F.zx + y * F.zy + z * F.zz end
  local sx, sy, sz = loc(a.x, a.y, a.z)
  local cx, cy, cz = loc(pc.cam_x or 0, pc.cam_y or 0, pc.cam_z or 0)
  local fx, fy, fz = dir(pc.fwd_x or 0, pc.fwd_y or 0, pc.fwd_z or -1)
  local wf = a:worldForward()
  local gx, gy, gz = dir(wf.x, wf.y, wf.z)
  local p = J.prev
  if p then
    J.n = J.n + 1
    J.ds[#J.ds + 1] = len(sx - p[1], sy - p[2], sz - p[3])
    J.dc[#J.dc + 1] = len(cx - p[4], cy - p[5], cz - p[6])
    J.da[#J.da + 1] = ang(fx, fy, fz, p[7], p[8], p[9])
    J.df[#J.df + 1] = ang(gx, gy, gz, p[10], p[11], p[12])
    if J.n <= 12 or J.n % 60 == 0 or J.dc[#J.dc] > 0.02 and J.n % 7 == 0 then
      P("JF %s #%d suit (%.3f %.3f %.3f) d %.1f mm | cam d %.1f mm turn %.3f° | suit turn %.3f° | fp %s hold %s shot %s ho %s cam (%.2f %.2f %.2f)", J.tag, J.n, sx, sy, sz,
        J.ds[#J.ds] * 1000, J.dc[#J.dc] * 1000, J.da[#J.da], J.df[#J.df], tostring(pc.firstPerson), tostring(pc.holding and pc.holding()), tostring(pc.shotOn and pc.shotOn()), tostring(pc.handingOff and pc.handingOff()), cx, cy, cz)
    end
  end
  J.prev = { sx, sy, sz, cx, cy, cz, fx, fy, fz, gx, gy, gz }
end

-- A repair on part `uid` the way the menu starts one: the Repair Kit in hand,
-- the hit from a ray at it, the target the context menu would resolve.
local function start_repair(vc, uid)
  give("repairkit", 2)
  local H = findScript("item_hand")
  H.hold("repairkit")
  wait(0.3)
  local a = find("Astronaut")
  local px, py, pz = vc.partPointNow(uid, 0, 0, 0, true)
  local dx, dy, dz = px - a.x, py - a.y, pz - a.z
  local dl = len(dx, dy, dz)
  local hit = raycast(a.x, a.y, a.z, dx / dl, dy / dl, dz / dl, dl + 2, { ignore = a })
  local cm = findScript("context_menu")
  local t = hit and cm.resolve(hit, a)
  if not (t and t.kind == "part" and t.uid == uid) then
    P("repair: the ray found %s; the target as the menu builds one for a point on the pod", hit and tostring(hit.node and hit.node.name) or "nothing")
    local F = vc.partFrameNow(uid, true)
    local qx, qy, qz = a.x - F.ox, a.y - F.oy, a.z - F.oz
    local lx, lz = qx * F.rx + qy * F.ry + qz * F.rz, qx * F.zx + qy * F.zy + qz * F.zz
    local l2 = math.sqrt(lx * lx + lz * lz)
    local wx, wy, wz = vc.partPointNow(uid, lx / l2 * 0.6, 0, lz / l2 * 0.6, true)
    t = { kind = "part", vessel = vc, uid = uid, rec = vc.aboardRecs()[uid], label = "pod", wx = wx, wy = wy, wz = wz }
  end
  local ok, why = H.startRepair(t, nil)
  P("repair start: %s %s on %s #%s", tostring(ok), tostring(why), tostring(t.rec and t.rec.id), tostring(t.uid))
  return ok
end

local function view_third()
  local pc = findScript("planet_camera")
  for _ = 1, 3 do
    if not pc.firstPerson then break end
    input.simulate { scroll = -1 }
    wait(0.2)
  end
  return not pc.firstPerson
end

local function climb_state() local ct = findScript("crew_task"); return ct and ct.climbState end
local function jitter_run(vc)
  local c = findScript("crew")
  local a = find("Astronaut")
  if vc.setSAS then vc.setSAS("off") end
  give("rcspack", 1)
  wait(0.3)
  local okE = c.eva(c.activeId())
  wait(1.5)
  R("eva", okE and not vc.crewAboard, "out on EVA %s", tostring(okE))
  -- out on the hatch handrail (climbOut): measured there too, then let go
  do
    local by0 = {}
    for u, d in pairs(vc.aboardRecs()) do by0[d.id] = u end
    if climb_state() then
      jit_reset(vc, by0.pod or by0.podMk2, "handrail_fp")
      wait(3.0)
      HR = jit_report()
      c.cancelTask(c.activeId(), "let go")
      wait(0.5)
    end
  end
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local uid = by.pod or by.podMk2
  -- beside the pod, at rest relative to it
  local px, py, pz, pvx, pvy, pvz = vc.partPointNow(uid, 1.9, 0, 0)
  do local kx, ky, kz = vc.nodeLag(true); px, py, pz = px - kx, py - ky, pz - kz end
  a.x, a.y, a.z = px, py, pz
  a.vx, a.vy, a.vz = pvx, pvy, pvz
  local ep = findScript("eva_pack")
  ep.holdFor(1.5, vc.node)
  wait(1.5)
  -- floating beside it first (the baseline: no job)
  jit_reset(vc, uid, "float_fp")
  wait(3.0)
  local base = jit_report()
  vc.wearPart(uid, 0.4)
  wait(0.2)
  local ok = start_repair(vc, uid)
  R("repair_start", ok, "")
  wait(1.0)
  jit_reset(vc, uid, "repair_fp_still")
  wait(4.0)
  local fp = jit_report()
  shot_at("jitter_fp")
  view_third()
  wait(0.8)
  jit_reset(vc, uid, "repair_3p_still")
  wait(4.0)
  local tp = jit_report()
  shot_at("jitter_3p")
  -- tumbling at ~0.1 rad/s
  local info = assembly.info(vc.node)
  local I = info.inertia
  local Rr, U = info.right, info.up
  local Iax = (Rr.x * (I[1].x * Rr.x + I[1].y * Rr.y + I[1].z * Rr.z) + Rr.y * (I[2].x * Rr.x + I[2].y * Rr.y + I[2].z * Rr.z)
    + Rr.z * (I[3].x * Rr.x + I[3].y * Rr.y + I[3].z * Rr.z))
  local Fm = Iax * 0.1 / 2
  local Fw, com = info.forward, info.com
  assembly.impulseAt(vc.node, vec3(Fw.x * Fm, Fw.y * Fm, Fw.z * Fm), vec3(com.x + U.x, com.y + U.y, com.z + U.z))
  assembly.impulseAt(vc.node, vec3(-Fw.x * Fm, -Fw.y * Fm, -Fw.z * Fm), vec3(com.x - U.x, com.y - U.y, com.z - U.z))
  wait(0.5)
  jit_reset(vc, uid, "repair_3p_tumble")
  wait(4.0)
  local tt = jit_report()
  local ct = findScript("crew_task")
  local held = c.held and c.held()
  if HR then P("handrail FP: suit p95 %.1f mm, cam p95 %.1f mm", HR.suit_p95, HR.cam_p95) end
  R("jitter", held and fp.suit_p95 < 5 and tp.suit_p95 < 5 and tp.cam_p95 < 8 and tt.suit_p95 < 5,
    "held %s; suit vs part p95/max mm: float %.1f/%.1f, FP %.1f/%.1f, 3P %.1f/%.1f, tumble %.1f/%.1f; cam p95 mm: FP %.1f 3P %.1f tumble %.1f",
    tostring(held), base.suit_p95, base.suit_max, fp.suit_p95, fp.suit_max, tp.suit_p95, tp.suit_max, tt.suit_p95, tt.suit_max,
    fp.cam_p95, tp.cam_p95, tt.cam_p95)
  if c.cancelTask then c.cancelTask(c.activeId(), "cancelled") end
  wait(0.5)
end

-- a key held for `secs` (W/S on a ladder)
local function hold_key(k, secs)
  input.simulate { key = k, down = true }
  wait(secs)
  input.simulate { key = k, down = false }
  yield(); yield()
end

-- A camera off to the side of part `uid`, riding the craft's drawn pose
-- (the free camera, its body-relative spot rewritten every frame).
SIDE = nil
local function side_cam(vc, uid, ox, oy, oz, lx, ly, lz)
  local cam = findScript("planet_camera")
  if not SIDE then cam.setFreecam(true) end
  SIDE = { vc = vc, uid = uid, o = { ox, oy, oz }, l = { lx or 0, ly or 0, lz or 0 } }
end
local function side_off()
  if SIDE then findScript("planet_camera").setFreecam(false) end
  SIDE = nil
end
local function side_frame()
  local S = SIDE
  if not S then return end
  local cam = findScript("planet_camera")
  local fc = cam and cam.freecamState and cam.freecamState()
  if not fc then return end
  local F = S.vc.partFrameNow(S.uid, true)
  if not F then return end
  local function W(p) return F.ox + F.rx * p[1] + F.ux * p[2] + F.zx * p[3], F.oy + F.ry * p[1] + F.uy * p[2] + F.zy * p[3], F.oz + F.rz * p[1] + F.uz * p[2] + F.zz * p[3] end
  local px, py, pz = W(S.o)
  local hx, hy, hz = W(S.l)
  local d = space.dominant(px, py, pz)
  local b = d and space.body(d)
  if not b then return end
  local rel = vec3(px - b.x, py - b.y, pz - b.z)
  local up = rel:normalized()
  local dir = vec3(hx - px, hy - py, hz - pz):normalized()
  fc.body = d
  fc.rel = rel
  fc.ref = dir:flatten(up):normalized()
  fc.pitch = math.asin(math.max(-1, math.min(1, dir:dot(up))))
end

local function prompt_of(vc) return tostring(vc.promptText or "") end
local function dbg(vc, tag)
  local c = findScript("crew")
  local t = c.task(c.activeId())
  local cs = climb_state()
  local ok, ch = pcall(vc.boardChoice, vc.node, assembly.info(vc.node))
  if not ok then ch = { why = tostring(ch) } end
  local a = find("Astronaut")
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local u = by.pod or by.podMk2
  local lx, ly, lz = vc.partLocalNow(u, vc.physPosOf(a))
  P("DBG %s held %s task %s s %s | cs %s | choice %s uid %s why %s d %s | suit local (%.2f %.2f %.2f) | prompt '%s'", tag,
    tostring(c.held()), tostring(t and t.kind), tostring(t and t.s), tostring(cs ~= nil),
    tostring(ch and ch.act), tostring(ch and ch.uid), tostring(ch and ch.why), tostring(ch and ch.d), lx or 0, ly or 0, lz or 0, prompt_of(vc))
end

-- GROUND: a tall stack on the pad; out of the hatch onto the ladder's top,
-- down it, off it, back on, up it, in by the hatch.
local function ground_run()
  local vc = rollout(stack({ "tankM", "tankM", "tankS", "pod" }))
  if not vc then R("pad", false, "no craft") return end
  wait(3)
  local c = findScript("crew")
  local a = find("Astronaut")
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local uid = by.pod
  local L = vc.ladderOf(uid)
  R("ladder", L ~= nil and L.ylow ~= nil, "pod ladder a.y %.2f b.y %.2f ylow %s ext %d", L and L.a.y or -1, L and L.b.y or -1,
    tostring(L and L.ylow), L and L.ext and #L.ext.off or 0)
  shot_at("ladder_pad")
  side_cam(vc, uid, 2.6, -0.4, 2.2, 0.35, -0.2, 0.35)
  wait(1.0)
  shot_at("ladder_close")
  side_off()
  -- 1. F with one aboard: out onto the ladder's top
  tap("f")
  wait(1.2)
  local cs = climb_state()
  R("out_ladder", not vc.crewAboard and cs ~= nil and cs.top, "out %s; on the ladder %s at the top %s (prompt '%s')",
    tostring(not vc.crewAboard), tostring(cs ~= nil), tostring(cs and cs.top), prompt_of(vc))
  side_cam(vc, uid, 2.4, -0.6, 2.6, 0.35, -0.5, 0.35)
  wait(0.8)
  shot_at("climb_top")
  side_off()
  -- 2. down to the foot
  dbg(vc, "before S")
  input.simulate { key = "s", down = true }
  wait_for(function() local q = climb_state(); return q == nil or q.bottom end, 8, "the foot")
  input.simulate { key = "s", down = false }
  yield(); yield()
  dbg(vc, "after S")
  cs = climb_state()
  R("climb_down", cs ~= nil and cs.bottom, "at the foot %s (s %.2f lo %.2f) prompt '%s'", tostring(cs and cs.bottom), cs and cs.s or -1, cs and cs.lo or -1, prompt_of(vc))
  -- 3. off it
  tap("e")
  wait(0.8)
  local pw = findScript("planet_walker")
  R("step_off", climb_state() == nil and not c.held() and pw.onFoot, "off the ladder: held %s, on foot %s", tostring(c.held()), tostring(pw.onFoot))
  -- 4. F away from the ladder does nothing (no boarding from anywhere)
  wait(1.0)
  local F = vc.partFrameNow(uid)
  tap("f")
  wait(0.5)
  dbg(vc, "after F at foot")
  R("no_board_from_ground", not vc.crewAboard and climb_state() ~= nil, "F at the foot of a 4 m stack: not aboard, it grabbed the ladder instead (%s)", prompt_of(vc))
  wait(0.5)
  tap("e")
  wait(0.8)
  R("step_off2", climb_state() == nil, "E at the foot: off again")
  -- 5. back on: E by the ladder
  tap("e")
  wait(0.8)
  cs = climb_state()
  R("grab", cs ~= nil, "E: on the ladder %s (s %.2f)", tostring(cs ~= nil), cs and cs.s or -1)
  shot_at("grab")
  dbg(vc, "before W")
  hold_key("w", 6.0)
  dbg(vc, "after W")
  cs = climb_state()
  local pr = prompt_of(vc)
  R("climb_up", cs ~= nil and cs.top and pr:find("enter") ~= nil, "at the top %s, by the hatch %s; prompt '%s'",
    tostring(cs and cs.top), tostring(cs and cs.atHatch), pr)
  side_cam(vc, uid, 2.4, 0.1, 2.0, 0.4, -0.05, 0.2)
  wait(0.8)
  shot_at("enter_prompt")
  side_off()
  tap("e")
  wait(1.0)
  R("enter", vc.crewAboard and not c.held(), "in by the hatch: aboard %s", tostring(vc.crewAboard))
end

-- ORBIT: three aboard a Pod Mk2; the portrait's EVA button (SHIFT: they go,
-- you stay); F's picker picks the second; the hatch handrail in space.
local function orbit_run()
  local vc = rollout(stack({ "engineM", "tankM", "tankS", "locker", "podMk2" }))
  vc = vc and to_orbit(vc)
  if not vc then R("orbit", false, "no station") return end
  wait(4)
  if vc.setSAS then vc.setSAS("off") end
  local c = findScript("crew")
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local uid = by.podMk2
  local act = c.activeId()
  local n = 1
  for _, r in ipairs(c.roster()) do
    local id = type(r) == "table" and r.id or r
    local rec = c.get(id)
    if id ~= act and rec and rec.status ~= "dead" and n < 3 then
      n = n + 1
      local ok, why = vc.seatMember(uid, n, id)
      if ok then c.patch(id, { status = "aboard", craft = vc.craftName or false, body = false, x = false, y = false, z = false }) end
      P("seated #%s in slot %d: %s %s", tostring(id), n, tostring(ok), tostring(why))
    end
  end
  -- every member gets a pack (no confirm in the way)
  local inv = inv()
  for _, m in ipairs(c.aboard(vc)) do inv.addItem(c.packOf(m.id), "rcspack", 1, { force = true }) end
  wait(1.5)
  local list = c.aboard(vc)
  R("three", #list == 3, "%d aboard", #list)
  local S = findScript("crew_strip")
  local third = list[3] and list[3].id
  S.forceHover(third)
  wait(1.0)
  shot_at("portrait_hover")
  -- the button's own path, SHIFT held: they go, you stay
  local okB = S.evaMember(third, true, false)
  S.forceHover(nil)
  wait(2.0)
  local r3 = c.get(third)
  R("portrait_eva", okB and r3 and r3.status == "afoot" and vc.crewAboard and c.activeId() == act,
    "#%s out by the portrait button: %s (status %s), you still aboard %s", tostring(third), tostring(okB), tostring(r3 and r3.status), tostring(vc.crewAboard))
  -- F: the picker
  tap("f")
  wait(0.6)
  local X = findScript("exit_picker")
  local open = X.isOpen()
  local rows = X.rowsNow() or {}
  R("picker", open and #rows == 3, "F with %d aboard: picker open %s, %d rows (2 members + everyone)", #c.aboard(vc), tostring(open), #rows)
  shot_at("picker")
  local second = rows[2] and rows[2].id
  tap("2")
  wait(2.0)
  R("pick_second", c.activeId() == second and not vc.crewAboard, "picked row 2 (#%s): now controlling #%s, out %s",
    tostring(second), tostring(c.activeId()), tostring(not vc.crewAboard))
  local cs = climb_state()
  R("handrail", cs ~= nil, "out on the hatch handrail in space: %s", tostring(cs ~= nil))
  local pr = prompt_of(vc)
  R("enter_prompt_space", pr:find("enter") ~= nil, "prompt '%s'", pr)
  shot_at("space_handrail")
  tap("e")
  wait(1.0)
  R("enter_space", vc.crewAboard, "back in by the hatch: %s", tostring(vc.crewAboard))
end

local MAIN = function()
  boot()
  wait(3)
  if STOP == "jitter" then
    local vc = rollout(stack({ "engineM", "tankM", "tankS", "locker", "pod" }))
    vc = vc and to_orbit(vc)
    if not vc then R("orbit", false, "no station") return end
    wait(4)
    jitter_run(vc)
  elseif STOP == "ground" then
    ground_run()
  elseif STOP == "orbit" then
    orbit_run()
  end
  P("DONE")
  if (params.quit or 0) > 0 then app.quit() end
  hold_here("end")
end

function lateUpdate(node, dt)
  side_frame()
  if not J.on then return end
  local pc = findScript("planet_camera")
  if pc and pc.deferLate then pc.deferLate(node, dt, jit_frame) else jit_frame() end
end

function update(node, dt)
  if not CO then
    NODE = node
    STOP = params.stop
    HOLDAT = params.at
    if HOLDAT == "" or HOLDAT == "none" then HOLDAT = nil end
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
