-- EVAPROBE: EVA in orbit, the RCS Pack, and the held repair lock on a
-- tumbling station (docs/crew-and-items.md §10 WS1, "In-engine probe, space").
-- Run by tools/perf/evashot.sh; one `EVA RESULT <step>: PASS|FAIL …` line a step.
--
--   1. a fresh save; a station (engine, tanks, locker, pod) rolled out of the
--      VAB, its clamps let go, written to the fleet in a circular orbit and
--      the scene reloaded: flight_ops brings it back in orbit, crew aboard
--   2. no RCS Pack: F asks first (the confirm; Cancel keeps them aboard)
--   3. a pack in the crew's pack: EVA, out at rest relative to the craft
--   4. 20 m out and back on the pack: propellant falls by the Δv used, HOLD
--      brings the relative speed under 0.05 m/s within 3 s
--   5. the station tumbles (0.1 rad/s); a worn pod part (hp 0.4); Repair:
--      every tick of the job the suit stays within 0.05 m of the work spot,
--      WASD and the RCS keys mid-job move nothing, the job runs on
--   6. Cancel: released under 0.1 m/s relative to the part, progress kept
--   7. Repair again: resumes from the kept progress and finishes, hp 1.0
--   8. board: the pack refills from the craft's propellant
--   9. no pack again: "EVA anyway" lets them out at rest relative to the craft
--
-- strs: stop = warn | orbit | repair | (none: all steps, then quit)
-- params: slot (14), seed
defaults = { slot = 14, seed = 1911564384, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("EVA %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local function R(step, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), step, ok and "PASS" or "FAIL", ...) end
local STOP = nil
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

local function station()
  local l, y, u = {}, 0, 0
  local function add(id, h, st)
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = st or 0 }
    y = y + h
  end
  add("engineM", 1.6); add("tankM", 1.5); add("tankS", 1.0); add("locker", 0.5); add("pod", 0.8)
  return l
end

local function piloted()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end

-- Roll the station out, let the clamps go, and put its fleet record in orbit.
local function to_orbit()
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
  local bp = station()
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
  if not vc then return false end
  wait(3)
  vc.releaseClamps()
  wait(2)
  local fo = findScript("flight_ops")
  fo.fleetSync()
  local f = save.get("fleet.craft") or {}
  local fid, rec = nil, nil
  for k, r in pairs(f) do if r.name == vc.craftName then fid, rec = k, r end end
  if not rec then P("no fleet record for %s", tostring(vc.craftName)); return false end
  local home = save.get("base.body")
  local b = space.body(home)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local l = len(bx, by, bz)
  local ux, uy, uz = bx / l, by / l, bz / l
  local r = b.radius * 1.6 + 200
  -- tangent: up × some axis
  local tx, ty, tz = uy * 0 - uz * 1, uz * 0 - ux * 0, ux * 1 - uy * 0
  local tl = len(tx, ty, tz)
  if tl < 0.1 then tx, ty, tz, tl = 1, 0, 0, 1 end
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local vcirc = math.sqrt(b.mu / r)
  rec.body = home
  rec.x, rec.y, rec.z = ux * r, uy * r, uz * r
  rec.vx, rec.vy, rec.vz = tx * vcirc, ty * vcirc, tz * vcirc
  rec.landed = false
  rec.splashed = nil
  rec.crew = true
  rec.stime = space.time()
  f[fid] = rec
  save.set("fleet.craft", f)
  P("station %s: orbit r %.0f (alt %.0f), v %.1f m/s, mu %.0f", tostring(rec.name), r, r - b.radius, vcirc, b.mu)
  -- the crew is aboard it: the game saves where they stand as the pod
  save.set("p_body", home)
  save.set("p_x", rec.x); save.set("p_y", rec.y); save.set("p_z", rec.z)
  local gm = findScript("game_manager")
  if gm and gm.saveGame then end
  save.flush({ wait = true })
  scene.load("system")
  yield()
  -- written again in the new scene, before the fleet is restored: the old
  -- scene's fleetSync may have run after us in that last frame and put the
  -- craft back on the pad
  for _ = 1, 3 do
    local f2 = save.get("fleet.craft") or {}
    f2[fid] = rec
    save.set("fleet.craft", f2)
    yield()
  end
  wait_for(world_ready, 300, "the world again")
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid and v.crewAboard then return v end
    end
  end, 120, "the station back in orbit with its crew")
  return v2
end

local function pack_count()
  local inv = findScript("inventory")
  return inv.itemCount("astro", "rcspack")
end
local function set_pack(n)
  local inv = findScript("inventory")
  local have = pack_count()
  if have < n then inv.addItem("astro", "rcspack", n - have, { force = true }) end
  if have > n then inv.removeItem("astro", "rcspack", have - n) end
  return pack_count()
end

local function rel_to(vc, a)
  local i = assembly.info(vc.node)
  local w, c = i.angVel, i.com
  local ax, ay, az = vc.physPosOf(a)
  local qx, qy, qz = ax - c.x, ay - c.y, az - c.z
  local px = i.vel.x + w.y * qz - w.z * qy
  local py = i.vel.y + w.z * qx - w.x * qz
  local pz = i.vel.z + w.x * qy - w.y * qx
  return len(a.vx - px, a.vy - py, a.vz - pz), len(a.x - c.x, a.y - c.y, a.z - c.z)
end

-- per-tick measurement of the lock (fixedUpdate) and per-frame (lateUpdate)
local M = { on = false, n = 0, maxp = 0, maxr = 0, nr = 0 }

local function hold_here(tag)
  P("HOLD %s", tag)
  while true do yield() end
end

local MAIN = function()
  boot()
  wait(3)
  local vc = to_orbit()
  if not vc then R("orbit", false, "no station"); return end
  wait(4)
  local i = assembly.info(vc.node)
  local d0 = space.dominant(vc.node.x, vc.node.y, vc.node.z)
  local b = space.body(d0)
  local alt = len(vc.node.x - b.x, vc.node.y - b.y, vc.node.z - b.z) - b.radius
  R("orbit", vc.crewAboard and alt > 100, "craft %s aboard %s alt %.0f m speed %.1f", tostring(vc.craftName), tostring(vc.crewAboard), alt, len(i.vel.x, i.vel.y, i.vel.z))
  if vc.setSAS then vc.setSAS("off") end
  local c, ep, ct = findScript("crew"), findScript("eva_pack"), findScript("crew_task")
  local a = find("Astronaut")
  local inv = findScript("inventory")
  local cid = c.packOf(c.activeId())
  P("crew #%s %s, pack %s (%s)", tostring(c.activeId()), tostring(c.get(c.activeId()).name), cid, inv.lineFull and inv.lineFull("astro") or "")

  -- 2. no pack: F asks first
  set_pack(0)
  wait(0.5)
  tap("f")
  wait(0.5)
  local asked = ep.asking == true
  if STOP == "warn" then
    R("warn", asked and vc.crewAboard, "confirm open %s, still aboard %s", tostring(asked), tostring(vc.crewAboard))
    hold_here("warn")
  end
  ep.answer(false)
  wait(0.5)
  R("warn", asked and vc.crewAboard, "F without a pack asked first (%s); Cancel kept them aboard (%s)", tostring(asked), tostring(vc.crewAboard))

  -- 3. with a pack: out
  set_pack(1)
  local ok3, why3, warn3 = c.evaCheck(c.activeId())
  EV.vc, EV.n, EV.on = vc, 0, true
  local okE = c.eva(c.activeId())
  wait(0.5)
  EV.on = false
  local rel, dist = rel_to(vc, a)
  R("eva", okE and not vc.crewAboard and warn3 == nil and rel < 0.3, "out %s (check %s %s warn %s), %.2f m/s relative, %.1f m from the CoM",
    tostring(okE), tostring(ok3), tostring(why3), tostring(warn3 ~= nil), rel, dist)
  wait(2.5)
  rel = rel_to(vc, a)
  local warp_ok = not c.onEvaInSpace() and "no" or "yes"
  R("warp", c.onEvaInSpace() == true, "rails warp refused while on EVA in space (onEvaInSpace %s, inSpace %s)", warp_ok, tostring(ep.inSpace()))

  -- 3b. suit air: an Oxygen Tank is breathed first, the built-in supply kept
  do
    local I, pw = findScript("items"), findScript("planet_walker")
    inv.addItem("astro", "o2tank", 1, { force = true })
    wait(1.2)
    local r0 = I.o2Reserve(cid)
    local s0 = pw.suitO2
    wait(5.0)
    local r1 = I.o2Reserve(cid)
    local s1 = pw.suitO2
    R("o2tank", pw.airSource == "suit" and r0 - r1 > 4.0 and r0 - r1 < 6.5 and math.abs(s1 - s0) < 1e-6,
      "breathing %s: tank %.1f → %.1f s, built-in %.4f → %.4f; air left %.0f of %.0f s",
      tostring(pw.airSource), r0, r1, s0, s1, pw.airLeft or -1, pw.airCap or -1)
  end

  -- 4. 20 m out and back
  local left0 = ep.rcsLeft()
  local i0 = assembly.info(vc.node)
  local _, d_start = rel_to(vc, a)
  ep.steerCmd(0, 1, 0, false)   -- strafe right: a 1 s burn, ~0.75 m/s
  wait(1.0)
  ep.steerCmd(0, 0, 0)
  local t_out = 0
  local _, dd = rel_to(vc, a)
  while dd < d_start + 18 and t_out < 60 do wait(0.5); t_out = t_out + 0.5; _, dd = rel_to(vc, a) end
  local relmid = rel_to(vc, a)
  ep.steerCmd(nil)
  ep.hold(true)
  local th = 0
  local rr = rel_to(vc, a)
  local trace = {}
  while rr > 0.05 and th < 6 do
    wait(0.1); th = th + 0.1; rr = rel_to(vc, a)
    if #trace < 40 then trace[#trace + 1] = string.format("%.2f", rr) end
  end
  P("hold trace: %s (holdOn %s firing %s live %s)", table.concat(trace, " "), tostring(ep.holdOn), tostring(ep.firing), tostring(ep.live))
  local _, dfar = rel_to(vc, a)
  local used_out = left0 - ep.rcsLeft()
  R("hold", rr < 0.05 and th <= 3.05, "%.1f m out (drifted at %.2f m/s); HOLD to %.3f m/s in %.1f s", dfar, relmid, rr, th)
  if STOP == "orbit" then
    ep.hold(true)
    hold_here("orbit")
  end
  -- back: strafe left until near, then hold
  ep.hold(false)
  -- home on the craft: close at 1 m/s, 0.3 m/s inside 8 m, as a pilot would
  local tb = 0
  _, dd = rel_to(vc, a)
  while dd > d_start + 2.0 and tb < 90 do
    local i2 = assembly.info(vc.node)
    local ax, ay, az = vc.physPosOf(a)
    local c2, w = i2.com, i2.angVel
    local dx, dy, dz = c2.x - ax, c2.y - ay, c2.z - az
    local dl = len(dx, dy, dz)
    local qx, qy, qz = ax - c2.x, ay - c2.y, az - c2.z
    local rvx = a.vx - (i2.vel.x + w.y * qz - w.z * qy)
    local rvy = a.vy - (i2.vel.y + w.z * qx - w.x * qz)
    local rvz = a.vz - (i2.vel.z + w.x * qy - w.y * qx)
    local want = dl > 8 and 1.0 or 0.3
    local ex, ey, ez = dx / dl * want - rvx, dy / dl * want - rvy, dz / dl * want - rvz
    if len(ex, ey, ez) > 0.08 then ep.steerWorld(ex, ey, ez) else ep.steerWorld(nil) end
    wait(0.1); tb = tb + 0.1
    _, dd = rel_to(vc, a)
  end
  ep.steerWorld(nil)
  ep.steerCmd(nil)
  ep.hold(true)
  wait(3.0)
  local used = left0 - ep.rcsLeft()
  local cap = select(2, ep.rcsLeft())
  -- Δv used: four 3 s burns plus the holds; the propellant's own book
  local dv_est = used / cap * 30
  R("propellant", used > 0 and used < cap, "used %.3f of %.1f units (≈ %.1f m/s of Δv), back at %.1f m", used, cap, dv_est, dd)
  ep.hold(false)

  -- 5. tumble and repair
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local uid = by.pod
  vc.wearPart(uid, 0.4)
  local info = assembly.info(vc.node)
  -- spin up to ~0.1 rad/s about the craft's right axis: a pair of opposite
  -- impulses at ±1 m along up, sized from the inertia (I·Δω / 2 m)
  local I = info.inertia
  local Rr, U = info.right, info.up
  local Iax = (Rr.x * (I[1].x * Rr.x + I[1].y * Rr.y + I[1].z * Rr.z) + Rr.y * (I[2].x * Rr.x + I[2].y * Rr.y + I[2].z * Rr.z)
    + Rr.z * (I[3].x * Rr.x + I[3].y * Rr.y + I[3].z * Rr.z))
  local F = Iax * 0.1 / 2
  local Fw = info.forward
  local com = info.com
  assembly.impulseAt(vc.node, vec3(Fw.x * F, Fw.y * F, Fw.z * F), vec3(com.x + U.x, com.y + U.y, com.z + U.z))
  assembly.impulseAt(vc.node, vec3(-Fw.x * F, -Fw.y * F, -Fw.z * F), vec3(com.x - U.x, com.y - U.y, com.z - U.z))
  wait(1.0)
  info = assembly.info(vc.node)
  local spin = len(info.angVel.x, info.angVel.y, info.angVel.z)
  P("tumble: %.3f rad/s (I %.1f)", spin, Iax)
  -- put the crew beside the pod, at rest relative to it (a flight there is step 4)
  local F0 = vc.partFrameNow(uid)
  P("pod uid %s hp %s frame %s lost %s", tostring(uid), tostring(vc.partHp(uid)), tostring(F0 ~= nil), tostring(vc.isLost()))
  if not F0 then R("lock", false, "no frame for the pod"); return end
  local nx, ny, nz = F0.rx, F0.ry, F0.rz
  local hx, hy, hz = F0.ox + nx * 0.62, F0.oy + ny * 0.62, F0.oz + nz * 0.62
  local px, py, pz, pvx, pvy, pvz = vc.partPointNow(uid, 0.62 + 1.4, 0, 0)
  do local kx, ky, kz = vc.nodeLag(true); px, py, pz = px - kx, py - ky, pz - kz end
  a.x, a.y, a.z = px, py, pz
  a.vx, a.vy, a.vz = pvx, pvy, pvz
  ep.holdFor(1.0, vc.node)
  wait(0.3)
  -- the hit point and normal, this tick
  F0 = vc.partFrameNow(uid)
  hx, hy, hz = F0.ox + F0.rx * 0.62, F0.oy + F0.ry * 0.62, F0.oz + F0.rz * 0.62
  local task, whyT = ct.repairTask(vc, uid, hx, hy, hz, F0.rx, F0.ry, F0.rz)
  local okT, whyS = false, whyT
  if task then okT, whyS = c.setTask(c.activeId(), task) end
  P("repair task: %s %s (secs %.1f, spot %.2f %.2f %.2f)", tostring(okT), tostring(whyS), task and task.secs or -1,
    task and task.sx or 0, task and task.sy or 0, task and task.sz or 0)
  M.on, M.n, M.maxp, M.maxr, M.nr, M.uid, M.hits, M.miss = true, 0, 0, 0, 0, uid, 0, 0
  wait(1.0)
  local done0 = ct.progress(c.activeId())
  local pos0 = vc.partLocalNow(uid, a.x, a.y, a.z)
  -- WASD and the RCS keys mid-job
  for _, k in ipairs({ "w", "a", "space", "shift" }) do input.simulate { key = k, down = true } end
  wait(1.5)
  for _, k in ipairs({ "w", "a", "space", "shift" }) do input.simulate { key = k, down = false } end
  yield(); yield()
  P("keys after release: w %s a %s space %s shift %s", tostring(input.key("w")), tostring(input.key("a")), tostring(input.key("space")), tostring(input.key("shift")))
  local done1 = ct.progress(c.activeId())
  local held = c.held()
  R("keys", held and done1 and done0 and done1 > done0, "held %s through WASD/SPACE/SHIFT, progress %.1f → %.1f s",
    tostring(held), done0 or -1, done1 or -1)
  if STOP == "repair" then
    -- a camera off to the side of the work, riding the station's drawn pose
    -- (the free camera, its body-relative spot rewritten every frame)
    if (params.sidecam or 0) > 0 then
      local cam = findScript("planet_camera")
      cam.setFreecam(true)
      SIDECAM = { vc = vc, uid = uid, task = task }
    end
    hold_here("repair")
  end
  wait(2.0)
  -- facing: the body's front against the way to the hit point (1 = square on).
  -- Both ends in the PHYSICS frame (physPosOf, partPointNow): the suit node's
  -- x/y/z against the RENDERED part point mixed two frames, and read the
  -- 1.12 m way to the work as 1.6–2.0 m at the wrong angle (28° on every run,
  -- 45–113° where the hull lies under the crew; measured right: 0°).
  do
    local a = astro and astro() or find("Astronaut")
    local hx, hy, hz = vc.partPointNow(uid, task.lx, task.ly, task.lz)
    if a and hx then
      local f = a:worldForward()
      local ax, ay, az = vc.physPosOf(a)
      local dx, dy, dz = hx - ax, hy - ay, hz - az
      local l = math.sqrt(dx * dx + dy * dy + dz * dz)
      local d = l > 1e-4 and (f.x * dx + f.y * dy + f.z * dz) / l or 0
      R("facing", d > 0.8, "front · way to the work %.2f (%.0f°), %.2f m off", d, math.deg(math.acos(math.max(-1, math.min(1, d)))), l)
    end
  end
  R("lock", M.n > 30, "%d ticks held at the work spot on a station tumbling at %.3f rad/s (position checked at the release below)", M.n, spin)
  -- 6. cancel
  local before = ct.progress(c.activeId())
  c.cancelTask(c.activeId(), "cancelled")
  local ctr, cpos = {}, 0
  for k = 1, 4 do
    wait(0.1)
    local qx, qy, qz, qvx, qvy, qvz = vc.partPointNow(uid, task.sx, task.sy, task.sz)
    local ax, ay, az = vc.physPosOf(a)
    ctr[#ctr + 1] = string.format("%.3f m/s %.3f m", len(a.vx - qvx, a.vy - qvy, a.vz - qvz), len(ax - qx, ay - qy, az - qz))
    if k == 1 then cpos = len(ax - qx, ay - qy, az - qz) end
  end
  M.cpos = cpos
  P("after cancel: %s (holdOn %s live %s firing %s held %s)", table.concat(ctr, " "), tostring(ep.holdOn), tostring(ep.live), tostring(ep.firing), tostring(c.held()))
  local relc = 0
  do
    local _, _, _, qvx, qvy, qvz = vc.partPointNow(uid, task.sx, task.sy, task.sz)
    relc = len(a.vx - qvx, a.vy - qvy, a.vz - qvz)
  end
  local kept = vc.partSt(uid, "rprog")
  R("cancel", not c.held() and relc < 0.1 and M.cpos < 0.05 and kept and kept.s and kept.s > 0,
    "released at %.3f m/s relative to the part, %.3f m from the work spot 0.1 s later (a body again, carried like the hull); kept %.1f s of %.1f",
    relc, M.cpos, kept and kept.s or -1, before or -1)
  M.on = false
  wait(1.0)
  -- 7. again: resume and finish
  F0 = vc.partFrameNow(uid)
  hx, hy, hz = F0.ox + F0.rx * 0.62, F0.oy + F0.ry * 0.62, F0.oz + F0.rz * 0.62
  local task2 = ct.repairTask(vc, uid, hx, hy, hz, F0.rx, F0.ry, F0.rz)
  local ok2, why2 = c.setTask(c.activeId(), task2)
  local resumed = ct.progress(c.activeId())
  M.on, M.n, M.maxp, M.maxr, M.nr, M.hits, M.miss = true, 0, 0, 0, 0, 0, 0
  local secs = task2 and task2.secs or 20
  wait(secs - (resumed or 0) + 1.0)
  M.on = false
  local hp = vc.partHp(uid)
  R("finish", ok2 and (resumed or 0) > 0 and hp and hp > 0.999 and not c.held(), "resumed at %.1f s (%s %s); hp %.3f; held %d ticks",
    resumed or -1, tostring(ok2), tostring(why2), hp or -1, M.n)
  -- 8. board: the pack refills from the craft
  local left1 = ep.rcsLeft()
  local fuel0 = vc.fuel
  local hp2x, hp2y, hp2z, h2vx, h2vy, h2vz = vc.partPointNow(uid, 1.2, 0, 0)
  do local kx, ky, kz = vc.nodeLag(true); hp2x, hp2y, hp2z = hp2x - kx, hp2y - ky, hp2z - kz end
  a.x, a.y, a.z, a.vx, a.vy, a.vz = hp2x, hp2y, hp2z, h2vx, h2vy, h2vz
  wait(0.2)
  local boarded = vc.boardNow()
  wait(0.5)
  local left2, cap2 = ep.rcsLeft()
  R("refill", boarded and left2 >= cap2 - 1e-6 and left1 < cap2, "boarded %s: pack %.3f → %.3f / %.1f; craft fuel %.2f → %.2f",
    tostring(boarded), left1, left2, cap2, fuel0 or -1, vc.fuel or -1)
  -- 9. EVA anyway without a pack
  set_pack(0)
  wait(0.3)
  tap("f")
  wait(0.3)
  local asked2 = ep.asking
  ep.answer(true)
  wait(0.5)
  local rel9 = rel_to(vc, a)
  R("eva_anyway", asked2 and not vc.crewAboard and rel9 < 0.3, "asked %s, out %s, %.3f m/s relative", tostring(asked2), tostring(not vc.crewAboard), rel9)
  wait(2)
  rel9 = rel_to(vc, a)
  P("adrift without a pack: %.3f m/s relative after 2 s", rel9)
  P("DONE")
  if (params.quit or 0) > 0 then app.quit() end
  hold_here("end")
end

-- THE STEP-OUT, tick by tick (EVA DIAG lines): where the suit is against the
-- craft's centre of mass in the physics frame, how fast relative to the hull
-- at that point, kinematic or not, its capsule radius, and what it overlaps.
EV = { on = false, n = 0 }
local function eva_diag(tag)
  local vc = EV.vc
  if not (EV.on and vc and vc.node and vc.node.valid) or EV.n > 45 then return end
  EV.n = EV.n + 1
  local a = find("Astronaut")
  local i = assembly.info(vc.node)
  if not (a and i) then return end
  local rb = a:getcomponent("RigidBody")
  local ax, ay, az = vc.physPosOf(a)
  local c, w = i.com, i.angVel
  local qx, qy, qz = ax - c.x, ay - c.y, az - c.z
  local rvx = a.vx - (i.vel.x + w.y * qz - w.z * qy)
  local rvy = a.vy - (i.vel.y + w.z * qx - w.x * qz)
  local rvz = a.vz - (i.vel.z + w.x * qy - w.y * qx)
  local hits = overlapSphere and overlapSphere(vec3(ax, ay, az), 0.33, { ignore = a }) or {}
  local kx, ky, kz = vc.nodeLag()
  local pw, ep = findScript("planet_walker"), findScript("eva_pack")
  P("DIAG %s #%d aboard %s kin %s r %.2f | d %.2f m (%.2f %.2f %.2f) rel %.2f m/s (%.1f %.1f %.1f) | hits %d | lag %.2f | |v| %.1f | walker foot %s ground %s float %s pack live %s",
    tag, EV.n, tostring(vc.crewAboard), tostring(rb and rb.kinematic), rb and rb.radius or -1,
    len(qx, qy, qz), qx, qy, qz, len(rvx, rvy, rvz), rvx, rvy, rvz, #hits, len(kx, ky, kz), len(a.vx, a.vy, a.vz),
    tostring(pw and pw.onFoot), tostring(pw and pw.grounded), tostring(pw and pw.floating), tostring(ep and ep.live))
end

-- Ticks the lock held after the slide-in (crew_task.lastTick: the body was
-- placed at the work spot in that tick's physics frame).
function fixedUpdate(node, dt)
  if EV.on then eva_diag("tick") end
  if not M.on then return end
  local c, ct = findScript("crew"), findScript("crew_task")
  local id = c and c.activeId()
  if not (id and ct.isHeld(id)) then return end
  local lt = ct.lastTick
  if lt and lt.k and lt.k >= 1 then M.n = M.n + 1 end
end

-- (see STOP == "repair")
local diag_n = 0
function lateUpdate(node, dt)
  if EV.on then eva_diag("frame") end
  if STOP == "repair" and M.on and diag_n < 3 then
    local c = findScript("crew")
    local h = c and c.task(c.activeId())
    local v = nil
    for _, s2 in ipairs(findScripts("vessel_controller")) do if s2.node and s2.node.valid then v = s2 end end
    if h and v then
      diag_n = diag_n + 1
      local d = v.aboardRecs()[h.uid]
      local tw = v.node:toWorld(vec3(d.x, d.y, d.z))
      local rx, ry, rz = v.partPointNow(h.uid, 0, 0, 0, true)
      local px, py, pz = v.partPointNow(h.uid, 0, 0, 0)
      local a = find("Astronaut")
      local sx, sy, sz = v.partPointNow(h.uid, h.sx, h.sy, h.sz, true)
      P("FRAMES pod toWorld (%.2f %.2f %.2f) | rendered %.3f off | physics %.3f off | suit node - spot(rendered) %.3f, - spot(physics) %.3f",
        tw.x, tw.y, tw.z, len(rx - tw.x, ry - tw.y, rz - tw.z), len(px - tw.x, py - tw.y, pz - tw.z),
        len(a.x - sx, a.y - sy, a.z - sz), (function() local qx, qy, qz = v.partPointNow(h.uid, h.sx, h.sy, h.sz); return len(a.x - qx, a.y - qy, a.z - qz) end)())
    end
  end
  local S = SIDECAM
  if not S then return end
  local cam = findScript("planet_camera")
  local fc = cam and cam.freecamState and cam.freecamState()
  if not fc then return end
  local F = S.vc.partFrameNow(S.uid, true)
  if not F then return end
  local t = S.task
  local hx, hy, hz = S.vc.partPointNow(S.uid, (t.lx + t.sx) / 2, (t.ly + t.sy) / 2, (t.lz + t.sz) / 2, true)
  -- from the craft's forward side and a little behind the work, looking at it
  local px, py, pz = hx + F.zx * 3.2 + F.rx * 1.6 + F.ux * 0.8, hy + F.zy * 3.2 + F.ry * 1.6 + F.uy * 0.8, hz + F.zz * 3.2 + F.rz * 1.6 + F.uz * 0.8
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

function update(node, dt)
  if not CO then
    NODE = node
    STOP = params.stop
    if STOP == "" or STOP == "none" then STOP = nil end
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
