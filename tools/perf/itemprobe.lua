-- ITEMPROBE: the items, the hand and the repair job in the real game, on a NEW
-- save (tools/perf/itemshots.sh; docs/crew-and-items.md §5, §6, WS3).
--
--   1. a two-part lander (a Stowage Locker under a Pod Mk1) rolled out to the
--      pad; the pod worn to 0.4 (wearPart); two Repair Kits, a Relay Beacon
--      and an Oxygen Tank in the locker
--   2. F: the crew steps out; right tap on the locker → Take… → Repair Kit
--   3. the kit taken in hand (its belt key), carried by its handle
--   4. right tap on the pod → Repair: the crew is held at the hull, hands on
--      the hit point, sparks, the kit clamped beside them; WASD does nothing
--   5. right tap on the crew → Cancel repair: released, the progress kept
--   6. right tap on the pod → Resume repair → done: hp 1.0, one kit used
--   7. the beacon taken from the locker, in hand over the shoulder; deploy
--      mode's ghost on the ground; LMB sets it down (comms has one more
--      relay, the pack one fewer); right tap on it → Pick up
--   8. the Oxygen Tank: carried (on the PLSS), the pack panel's line, drawn
--      and refilled at the locker
--
-- Pictures to user://itemshots/ (the scratch project's save/user), lines "ITM ".
-- One RESULT line per check.
defaults = { quit = 1, slot = 15, seed = 4242, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("ITM %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local NODE, CO, pending = nil, nil, 0
local OPEN_PART = nil
local LEFT_B = false
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function R(name, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...) end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://itemshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false }; yield() end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function cm() return findScript("context_menu") end
local function dump(tag)
  local c = cm()
  local list = c and c.entries() or {}
  local reg = findScript("context_registry")
  local out = {}
  for _, e in ipairs(list) do
    local v = reg and reg.live(e.value)
    local u, why = true, nil
    if reg then u, why = reg.usable(e) end
    out[#out + 1] = string.format("%s%s%s%s", e.id, e.label ~= "" and (" " .. e.label) or "",
      v and (" = " .. tostring(v)) or "", u and "" or (" (dim: " .. tostring(why) .. ")"))
  end
  P("MENU %s: open %s target %s | %s", tag, tostring(c and c.isOpen()), tostring(c and c.target and c.target.kind),
    table.concat(out, " ; "))
end
local function rtap(sx, sy)
  input.simulate { mouse = { sx, sy } }
  yield(); yield()
  input.simulate { button = 1, down = true }
  yield(); yield()
  input.simulate { button = 1, down = false }
  yield(); yield(); yield()
end
-- open the menu on a world point the way a player does (a right tap there);
-- the pick's fallback keeps the run going if the tap's ray slips past
-- (`wx` may be a function → vec3: the point is read again the frame it is
-- used, since the planet carries everything metres a tick)
local function open_on(wx, wy, wz, kind, uid, tag)
  local c = cm()
  local ptf = type(wx) == "function" and wx or nil
  if ptf then local p0 = ptf(); wx, wy, wz = p0.x, p0.y, p0.z end
  local sx, sy, _, on = camera.worldToScreen(wx, wy, wz)
  rtap(sx, sy)
  local good = c.isOpen() and c.target and c.target.kind == kind and (uid == nil or c.target.uid == uid)
  P("open %s by a right tap at %.0f,%.0f (on %s): %s", tag, sx or -1, sy or -1, tostring(on), good and "yes" or "no")
  if not good and kind == "astro" then
    local a0 = find("Astronaut")
    c.openFor({ kind = "astro", node = a0, pack = "astro", label = "Crew", wx = wx, wy = wy, wz = wz }, nil)
    P("…opened by the probe instead: astro")
    return c.isOpen()
  end
  if ptf then local p1 = ptf(); wx, wy, wz = p1.x, p1.y, p1.z end
  if not good then
    local t = c.pick(sx, sy)
    if t and t.kind == kind and (uid == nil or t.uid == uid) then c.openFor(t, nil, sx, sy)
    elseif kind == "part" and OPEN_PART then c.openFor(OPEN_PART(uid, wx, wy, wz), nil, sx, sy) end
    P("…opened by the probe instead: %s", tostring(c.target and c.target.uid))
  end
  return c.isOpen()
end

local function lander()
  local function rec(uid, id, y, parent)
    return { uid = uid, id = id, x = 0, y = y, z = 0, yaw = 0, pitch = 0, roll = 0,
             parent = parent or 0, att = parent and "top" or "", sym = 0, mir = "", stage = 0 }
  end
  return { rec(1, "locker", 0.25), rec(2, "pod", 0.5 + 0.4, 1) }
end

local function launch_once(site)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  local a = find("Astronaut")
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  hold(2.5)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  local B = findScript("builder")
  if not (BH and B) then return nil end
  hold(1)
  local bp = lander()
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  P("launching from the %s", B.launchSite and B.launchSite() or "?")
  B.doLaunch()
  hold(0.6)
  if BH.state == "building" then B.doLaunch() end
  LEFT_B = false
  local vc = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting and v.node and v.node.valid and v.lockerOf then
        local i = assembly.info(v.node)
        local has_locker = false
        for u, d in pairs(v.aboardRecs()) do if d.id == "locker" and v.lockerOf(u) then has_locker = true end end
        if i and #i.parts >= #bp and has_locker then return v end
      end
    end
    -- refused and refunded: the builder comes back
    local bh = findScript("build_host")
    if bh and bh.state == "rollout" then LEFT_B = W()
    elseif LEFT_B and bh and bh.state == "idle" and W() - LEFT_B > 45 and #findScripts("vessel_controller") == 0 then return "retry" end
  end, 120, "the craft on the " .. site)
  if vc == "retry" then return nil end
  return vc
end

-- (a busy machine can leave the pad's collider late: the spawner then
-- refuses and refunds — try again as a player would, then the runway)
local function launch()
  -- the launch site's collider streams in after the reveal: give it time
  hold(15)
  for attempt = 1, 3 do
    -- the runway: the lander stands on the ground, at hand height (on the
    -- pad's 2.5 m deck the crew would be working from under it)
    local vc = launch_once(attempt == 1 and "pad" or "runway")
    if vc then
      wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150, "the regrade")
      hold(4)
      return vc
    end
    P("launch attempt %d didn't fly; again", attempt)
    hold(8)
  end
end

local function main()
  boot()
  hold(3.0)
  local cam = findScript("planet_camera")
  local inv, H, I = findScript("inventory"), findScript("item_hand"), findScript("items")
  P("scripts: inventory %s item_hand %s items %s crew %s crew_task %s", tostring(inv ~= nil), tostring(H ~= nil),
    tostring(I ~= nil), tostring(findScript("crew") ~= nil), tostring(findScript("crew_task") ~= nil))
  R("standard issue", inv.itemCount("astro", "gravgun") == 1 and inv.itemCount("astro", "laser") == 1, "(pack %s → %s, %s)",
    "astro", inv.resolve("astro"), inv.lineFull("astro"))
  local vc = launch()
  if not vc then P("no craft"); return end
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local cid = vc.lockerOf(by.locker)
  inv.addItem(cid, "repairkit", 2)
  inv.addItem(cid, "beacon", 1)
  inv.addItem(cid, "o2tank", 1, { force = true, fills = { 240 } })
  vc.holdApplyMass(vc.node)
  vc.wearPart(by.pod, 0.4)
  P("craft %s: locker %s = %s; pod hp %.2f", tostring(vc.craftName), tostring(cid), inv.lineFull(cid), vc.partHp(by.pod))
  -- out of the pod
  tap("f")
  local pw = findScript("planet_walker")
  wait_for(function() return pw.onFoot end, 20, "on foot")
  hold(2)
  -- stand beside the stack, facing it
  -- a part's live node (its own transform: the blueprint's numbers are the
  -- builder's frame, not the flying root's)
  local function part_node(id)
    for _, ch in ipairs(vc.node:children()) do
      if vc.uidOfNode and vc.uidOfNode(ch) == by[id] then return ch end
    end
  end
  local function at(id, lx, ly, lz)
    local n = part_node(id)
    if n then
      local o = n.worldPos or vec3(n.worldX, n.worldY, n.worldZ)
      return o + vc.node:toWorld(vec3(lx or 0, ly or 0, lz or 0)) - vc.node:toWorld(vec3(0, 0, 0))
    end
    local d = vc.aboardRecs()[by[id]]
    return vc.node:toWorld(vec3(d.x + (lx or 0), d.y + (ly or 0), d.z + (lz or 0)))
  end
  local a = find("Astronaut")
  local b = space.body(save.get("base.body"))
  local function stand(dx)
    local L, Pd = at("locker"), at("pod")
    local upv = (Pd - L):normalized()
    local side = (vc.node:toWorld(vec3(1, 0, 0)) - vc.node:toWorld(vec3(0, 0, 0))):flatten(upv):normalized()
    local p = L + side * dx + upv * 0.8
    a.x, a.y, a.z = p.x, p.y, p.z
    a.vx, a.vy, a.vz = 0, 0, 0
    hold(1.5)
    local c = at("pod")
    cam.face(c.x - a.x, c.y - a.y, c.z - a.z, -0.25)
    hold(1.2)
    local d = (vec3(a.x, a.y, a.z) - at("locker")):length()
    P("stand: %.2f m from the locker (crew held %s)", d, tostring(findScript("crew") and findScript("crew").held and findScript("crew").held()))
    if d > 2.6 then
      p = at("locker") + side * dx + upv * 0.8
      a.x, a.y, a.z = p.x, p.y, p.z
      a.vx, a.vy, a.vz = 0, 0, 0
      for _ = 1, 40 do local c2 = at("pod"); cam.face(c2.x - a.x, c2.y - a.y, c2.z - a.z, -0.25); yield() end
      P("stand again: %.2f m", (vec3(a.x, a.y, a.z) - at("locker")):length())
    end
  end
  OPEN_PART = function(uid, wx, wy, wz)
    local n
    for _, ch in ipairs(vc.node:children()) do if vc.uidOfNode(ch) == uid then n = ch end end
    local rec = vc.partRec(uid)
    return { kind = "part", vessel = vc, uid = uid, rec = rec, node = n, label = rec and rec.label, wx = wx, wy = wy, wz = wz }
  end
  stand(1.55)
  -- ── 2. take a kit from the locker ──
  local lp = at("locker")
  open_on(function() return at("locker") end, nil, nil, "part", by.locker, "locker")
  dump("locker")
  local c = cm()
  c.press("take_" .. cid)
  hold(0.4)
  dump("locker-take")
  shot("01_locker_take")
  hold(0.3)
  local k0 = inv.itemCount("astro", "repairkit")
  c.press("take_repairkit")
  hold(0.3)
  R("take a kit from the locker", inv.itemCount("astro", "repairkit") == k0 + 1 and inv.itemCount(cid, "repairkit") == 1,
    "(pack %d, locker %d)", inv.itemCount("astro", "repairkit"), inv.itemCount(cid, "repairkit"))
  c.close()
  hold(0.4)
  -- ── 3. the kit in hand by its belt key ──
  local slot
  for i, e in ipairs(H.belt()) do if e.id == "repairkit" then slot = i end end
  tap(tostring(slot or 3))
  hold(1.0)
  R("hold the kit", H.held() == "repairkit", "(key %s, in hand %s)", tostring(slot), tostring(H.held()))
  -- a walk with it, seen from the side
  input.simulate { key = "w", down = true }
  hold(0.8)
  input.simulate { key = "w", down = false }
  local function frame()
    local m
    for _, ch in ipairs(a:children()) do if ch.name == "AstroModel" then m = ch end end
    local o = m:toWorld(vec3(0, 0, 0))
    return (m:toWorld(vec3(0, 1, 0)) - o):normalized(), (m:toWorld(vec3(0, 0, 1)) - o):normalized(), (m:toWorld(vec3(1, 0, 0)) - o):normalized()
  end
  local function cam_at(pos, tgt)
    local bn = find(b.name)
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
  local function view(name, side, fwd, up, n, tgt_fn)
    for _ = 1, (n or 20) do
      local U, F, L = frame()
      local t = tgt_fn and tgt_fn() or (vec3(a.x, a.y, a.z) - U * 0.2)
      cam_at(t + L * side + F * fwd + U * up, t)
      yield()
    end
    shot(name)
    for _ = 1, 3 do yield() end
  end
  view("02_kit_carry", 2.0, 0.8, 0.8)
  cam.setFreecam(false)
  stand(1.55)
  -- ── 4. right tap on the pod → Repair ──
  local pp = at("pod", 0.0, -0.15, 0.0)
  -- the hit: on the pod's skin toward the crew
  local dir = (vec3(a.x, a.y, a.z) - pp):normalized()
  local function hit_fn()
    local q = at("pod", 0.0, -0.15, 0.0)
    return q + (vec3(a.x, a.y, a.z) - q):normalized() * 0.45
  end
  open_on(hit_fn, nil, nil, "part", by.pod, "pod")
  dump("pod")
  shot("03_repair_menu")
  hold(0.3)
  local secs = I.repairSecs(vc.partHp(by.pod))
  c.press("repair")
  hold(0.3)
  local tk = H.task()
  R("repair started", tk ~= nil, "(secs %.1f, expected %.1f; lock %s)", tk and tk.secs or -1, secs,
    findScript("crew_task") and "crew_task" or "item_hand fallback")
  hold(3.0)
  -- the work, close: the hands on the hull
  local function hit_now()
    if H.workX then return vec3(H.workX, H.workY, H.workZ) end
    local t2 = H.task()
    if not t2 then return nil end
    local d = vc.aboardRecs()[t2.uid]
    if vc.partPointNow and t2.frame ~= "craft" then local x, y, z = vc.partPointNow(t2.uid, t2.lx, t2.ly, t2.lz, true); return vec3(x, y, z) end
    return vc.node:toWorld(vec3(t2.lx, t2.ly, t2.lz))
  end
  view("04_repair_work", 1.2, 0.6, 0.9, 16, function() local h = hit_now(); return h or vec3(a.x, a.y, a.z) end)
  local m
  for _, ch in ipairs(a:children()) do if ch.name == "AstroModel" then m = ch end end
  local hd = H.handToHit or -1
  R("hands on the hit point", hd >= 0 and hd < 0.25, "(right hand %.2f m from the hit, %.2f m from its IK target; read in item_hand's lateUpdate)",
    hd, H.handErr or -1)
  view("04b_repair_work_wide", 2.6, 1.6, 1.8, 10, function() local h2 = hit_now(); return h2 or vec3(a.x, a.y, a.z) end)
  cam.setFreecam(false)
  hold(0.3)
  -- WASD mid-job: nothing moves, the job runs on
  local d0 = H.task() and H.task().done or 0
  local a0 = vec3(a.x, a.y, a.z) - at("pod")
  input.simulate { key = "w", down = true }; input.simulate { key = "a", down = true }
  hold(2.0)
  shot("05_repair_wasd")
  input.simulate { key = "w", down = false }; input.simulate { key = "a", down = false }
  local a1 = vec3(a.x, a.y, a.z) - at("pod")
  local d1 = H.task() and H.task().done or 0
  R("WASD doesn't stop or move the work", H.task() ~= nil and d1 > d0 + 1.5 and (a1 - a0):length() < 0.15,
    "(done %.1f → %.1f s, body moved %.3f m relative to the pod)", d0, d1, (a1 - a0):length())
  -- ── 5. cancel, from the crew's own menu ──
  local up = a.up or vec3(0, 1, 0)
  open_on(a.worldX + up.x * 0.3, a.worldY + up.y * 0.3, a.worldZ + up.z * 0.3, "astro", nil, "crew")
  dump("crew")
  shot("06_cancel_menu")
  local kept_at = H.task() and H.task().done or 0
  c.press("cancel")
  hold(0.5)
  local rb = a:getcomponent("RigidBody")
  local rp = vc.partSt and vc.partSt(by.pod, "rprog")
  R("cancel releases and keeps the progress", H.task() == nil and (rb.kinematic == 0 or rb.kinematic == false) and inv.itemCount("astro", "repairkit") == 1,
    "(kinematic %s, kept %s s of %.1f, kits %d, hp %.2f)", tostring(rb.kinematic), tostring(rp and rp.s), kept_at,
    inv.itemCount("astro", "repairkit"), vc.partHp(by.pod))
  hold(1.0)
  view("07_released", 2.0, 1.6, 0.5, 10)
  cam.setFreecam(false)
  stand(1.55)
  -- ── 6. resume and finish ──
  pp = at("pod", 0.0, -0.15, 0.0)
  dir = (vec3(a.x, a.y, a.z) - pp):normalized()
  open_on(hit_fn, nil, nil, "part", by.pod, "pod-resume")
  dump("pod-resume")
  local e = findScript("context_registry").byId(c.entries(), "repair")
  local lab = e and e.label
  c.press("repair")
  hold(0.3)
  local t2 = H.task()
  R("resume from the kept progress", lab == "Resume repair" and t2 ~= nil and (t2.done or 0) > 3, "(row %s, start %.1f s)", tostring(lab), t2 and t2.done or -1)
  wait_for(function() return H.task() == nil end, 40, "the repair")
  hold(0.5)
  R("repaired, one kit used", vc.partHp(by.pod) >= 0.999 and inv.itemCount("astro", "repairkit") == 0 and H.lastStop == "done",
    "(hp %.3f, kits %d, lastRepair %s)", vc.partHp(by.pod), inv.itemCount("astro", "repairkit"),
    H.lastRepair and string.format("%d→%d", H.lastRepair.kit_before, H.lastRepair.kit_after) or "-")
  view("08_repaired", 2.0, 1.6, 0.6, 10, function() return at("pod") end)
  cam.setFreecam(false)
  -- ── 8. the oxygen tank and the beacon, from the locker ──
  stand(1.55)
  lp = at("locker")
  open_on(function() return at("locker") end, nil, nil, "part", by.locker, "locker2")
  c.press("take_" .. cid)
  hold(0.3)
  c.press("take_o2tank")
  hold(0.2)
  c.press("take_beacon")
  hold(0.3)
  R("take a tank and a beacon", inv.itemCount("astro", "o2tank") == 1 and inv.itemCount("astro", "beacon") == 1,
    "(tanks %d, beacons %d, %s)", inv.itemCount("astro", "o2tank"), inv.itemCount("astro", "beacon"), inv.lineFull("astro"))
  c.close()
  hold(0.3)
  open_on(function() return at("locker") end, nil, nil, "part", by.locker, "locker3")
  dump("locker-refill")
  local before = (I.o2Reserve("astro"))
  c.press("refill")
  hold(0.3)
  local after = (I.o2Reserve("astro"))
  R("refill the tank at the locker", before < 300 and after >= 899, "(%.0f → %.0f s)", before, after)
  c.close()
  hold(0.3)
  I.drawO2("astro", 200)
  local up2 = a.up or vec3(0, 1, 0)
  open_on(a.worldX + up2.x * 0.3, a.worldY + up2.y * 0.3, a.worldZ + up2.z * 0.3, "astro", nil, "crew-air")
  dump("crew-air")
  shot("09_crew_air_menu")
  c.close()
  hold(0.3)
  -- out onto open ground, 30 m off, the beacon over the shoulder
  local bn = find(b.name)
  local upw = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z):normalized()
  local away = vc.node:toWorld(vec3(30, 0, 0)) - vc.node:toWorld(vec3(0, 0, 0))
  away = away:flatten(upw):normalized()
  local spot = vec3(a.x, a.y, a.z) + away * 30 + upw * 3
  a.x, a.y, a.z = spot.x, spot.y, spot.z
  a.vx, a.vy, a.vz = 0, 0, 0
  hold(3)
  for i, e2 in ipairs(H.belt()) do if e2.id == "beacon" then slot = i end end
  tap(tostring(slot))
  hold(0.8)
  R("the beacon in hand", H.held() == "beacon", "(in hand %s)", tostring(H.held()))
  view("10_beacon_carry", 1.6, 1.6, 0.3)
  view("10b_o2tanks_back", -0.4, -2.0, 0.4)
  cam.setFreecam(false)
  -- look down at the ground ahead: deploy mode's ghost
  local fwd = away
  for _ = 1, 90 do cam.face(fwd.x, fwd.y, fwd.z, -0.75); yield() end
  local net = findScript("comms")
  local n0 = #(net.beaconList and net.beaconList() or {})
  P("deploy prompt: %s", tostring(H.prompt))
  shot("11_beacon_ghost")
  hold(0.3)
  H.sim = { lmb = true }
  hold(0.2)
  H.sim = { lmb = false }
  wait_for(function() return inv.itemCount("astro", "beacon") == 0 end, 6, "the plant")
  hold(1.0)
  local n1 = #(net.beaconList and net.beaconList() or {})
  R("the beacon set down by deploy mode", n1 == n0 + 1 and inv.itemCount("astro", "beacon") == 0 and H.lastDeploy ~= nil,
    "(relays %d → %d, pack %d, id %s)", n0, n1, inv.itemCount("astro", "beacon"), tostring(H.lastDeploy and H.lastDeploy.id))
  for _ = 1, 30 do cam.face(fwd.x, fwd.y, fwd.z, -0.35); yield() end
  shot("12_beacon_planted")
  -- pick it back up from its menu
  local bl = net.beaconList and net.beaconList() or {}
  local last = bl[#bl]
  if last and last.gx then
    local mast = vec3(last.gx, last.gy, last.gz) + upw * 1.2
    local st_ = vec3(last.gx, last.gy, last.gz) - away * 2.2 + upw * 1.0
    a.x, a.y, a.z = st_.x, st_.y, st_.z
    a.vx, a.vy, a.vz = 0, 0, 0
    for _ = 1, 60 do cam.face(away.x, away.y, away.z, -0.15); yield() end
    local function mast_fn() local e = net.beaconList()[#net.beaconList()]; return vec3(e.x, e.y, e.z) end
    open_on(mast_fn, nil, nil, "prop", nil, "beacon")
    if not (c.target and c.target.kind == "prop" and c.target.node == last.node) and last.node then
      c.openFor({ kind = "prop", node = last.node, label = last.name, wx = mast.x, wy = mast.y, wz = mast.z }, nil)
      P("…beacon menu opened by the probe on its node")
    end
    dump("beacon")
    shot("13_beacon_menu")
    c.press("pickup")
    hold(0.5)
    local n2 = #(net.beaconList and net.beaconList() or {})
    R("pick the beacon up from its menu", n2 == n0 and inv.itemCount("astro", "beacon") == 1, "(relays %d, pack %d)", n2, inv.itemCount("astro", "beacon"))
  else
    P("no beacon record with a ground point: %s", tostring(last and next(last)))
  end
  -- the pack panel: the tank's air
  c.close()
  hold(0.3)
  tap("tab")
  hold(1.0)
  shot("14_pack_panel")
  tap("tab")
  hold(0.5)
end

function update(node, dt)
  if not CO then
    NODE = node
    CO = coroutine.create(function()
      main()
      wait_for(function() return pending <= 0 end, 10, "the pictures")
      P("DONE")
      -- the probe's own slot goes (the scratch project's; Solar's are never touched)
      if save.deleteSlot then pcall(save.deleteSlot, "slot" .. math.floor(params.slot)) end
      if (params.quit or 0) > 0 then app.quit() end
    end)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
