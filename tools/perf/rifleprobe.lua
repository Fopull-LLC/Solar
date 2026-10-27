-- RIFLEPROBE: the TL-5 Surveyor plasma rifle in the real game, on a NEW save
-- (tools/perf/rifleshots.sh; scripts/surveyor.lua).
--
--   1. the item: on the depot's shop list; bought into member #1's pack
--      (the price comes off, the cell is full); taken in hand
--   2. a craft part: a lander (locker + Pod Mk1) rolled out to the runway,
--      the crew steps out and walks 30 m off; one full-charge bolt at the
--      pod → its hp drops, the hull scorches, a burn mark rides the craft
--   3. a CrewBody (member #2) 150 m off: a bolt from the hip (first person:
--      the charge, the bolt in flight, the impact), hp down, the HIT alert;
--      a second through the scope (first person); member #2 then walked to
--      30 m and shot from the shoulder (third person: the scope, the bolt,
--      the impact): dead — cause "shot", the shooter and the range in the
--      memorial, the caption, the remains
--   4. the avatar shot by a "hostile" bolt from 30 m (fireFrom): the HIT
--      and HP chips on the HUD
--   5. death off: member #3 shot twice → rescued to the base, whole, no
--      memorial row
--   6. the cell: drained by the shots, recharged at the base; no firing
--      inside a building (the hangar)
--   7. cost: the script's own time a shot (fire, hit, a frame of flight),
--      perf.scriptMs and the GPU's passes with three bolts in flight
--
-- Pictures (1280×720) to user://rifleshots/, lines "RFL ", one RESULT line a
-- check.
defaults = { quit = 1, slot = 16, seed = 4242, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RFL %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local NODE, CO, pending = nil, nil, 0
local LEFT_B = false
local FAILS = 0
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
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://rifleshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false }; yield() end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

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
  perf.enable(true)
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- ── the lander (itemprobe's) ───────────────────────────────────────────────
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
  B.doLaunch()
  hold(0.6)
  if BH.state == "building" then B.doLaunch() end
  LEFT_B = false
  local vc = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting and v.node and v.node.valid then
        local i = assembly.info(v.node)
        if i and #i.parts >= #bp then return v end
      end
    end
    local bh = findScript("build_host")
    if bh and bh.state == "rollout" then LEFT_B = W()
    elseif LEFT_B and bh and bh.state == "idle" and W() - LEFT_B > 45 and #findScripts("vessel_controller") == 0 then return "retry" end
  end, 120, "the craft on the " .. site)
  if vc == "retry" then return nil end
  return vc
end
local function launch()
  hold(15)
  for attempt = 1, 3 do
    local vc = launch_once(attempt == 1 and "runway" or "pad")
    if vc then
      wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150, "the regrade")
      hold(4)
      return vc
    end
    P("launch attempt %d didn't fly; again", attempt)
    hold(8)
  end
end

-- ── places on the home world (planet frame) ────────────────────────────────
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function base_frame()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local l = len(bx, by, bz)
  local u = { x = bx / l, y = by / l, z = bz / l }
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, a))
  local t2 = unit(cross(u, t1))
  return u, t1, t2, l
end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
-- The ground `d` metres from the base along bearing `ang`: { dir (unit, planet
-- frame), r } — a point is b + dir * (r + h).
local function spot(d, ang)
  local b = home()
  local u, t1, t2, R = base_frame()
  local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                   z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  local a = d / R
  local dir = unit({ x = u.x * math.cos(a) + t.x * math.sin(a), y = u.y * math.cos(a) + t.y * math.sin(a),
                     z = u.z * math.cos(a) + t.z * math.sin(a) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
  if not gr then return nil end
  return { dir = dir, r = gr, d = d, ang = ang }
end
local function at(s, h)
  local b = home()
  return b.x + s.dir.x * (s.r + h), b.y + s.dir.y * (s.r + h), b.z + s.dir.z * (s.r + h)
end
-- The ground `d` metres from a spot along a heading `ang` in its own
-- tangent plane (any spot, not only the base's radials).
local function move(s0, d, ang)
  local b = home()
  local u = s0.dir
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, a))
  local t2 = unit(cross(u, t1))
  local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                   z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  local R0 = s0.r
  local k = d / R0
  local dir = unit({ x = u.x * math.cos(k) + t.x * math.sin(k), y = u.y * math.cos(k) + t.y * math.sin(k),
                     z = u.z * math.cos(k) + t.z * math.sin(k) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 150)
  if not gr then return nil end
  return { dir = dir, r = gr, d = d, ang = ang }
end
-- How high the sun stands over a spot (the sine of its elevation).
local function sun_at(s0)
  local b = home()
  local star = nil
  for _, x in ipairs(space.bodies()) do if (x.soi or 0) < 0 then star = x end end
  if not star then return 0 end
  local d = unit({ x = star.x - b.x, y = star.y - b.y, z = star.z - b.z })
  return s0.dir.x * d.x + s0.dir.y * d.y + s0.dir.z * d.z
end
local function up_of(n)
  local b = home()
  return unit({ x = n.x - b.x, y = n.y - b.y, z = n.z - b.z })
end
local function put_astro(s)
  local a = find("Astronaut")
  a.x, a.y, a.z = at(s, 1.1)
  a.vx, a.vy, a.vz = 0, 0, 0
end
-- Point the view at a world point (from the eye), level with it.
local function face(tx, ty, tz)
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local u = up_of(a)
  local ex, ey, ez = a.x + u.x * 1.5, a.y + u.y * 1.5, a.z + u.z * 1.5
  local dx, dy, dz = tx - ex, ty - ey, tz - ez
  local v = dx * u.x + dy * u.y + dz * u.z
  local hx, hy, hz = dx - u.x * v, dy - u.y * v, dz - u.z * v
  local hl = len(hx, hy, hz)
  cam.face(hx / hl, hy / hl, hz / hl, math.atan2(v, hl))
end

-- ── the trigger, driven through tool_belt's own test hook ─────────────────
local TB, SV, C
-- An aim worked out the moment it is used: from the eye to a target point
-- given by `getT` (also read then).
local function aim_at(getT)
  return function()
    local a = find("Astronaut")
    if not a then return nil end
    local u = up_of(a)
    local cam = findScript("planet_camera")
    local eh = cam.firstPerson and ((cam.params and cam.params.eye_height) or 0.85) or 1.4
    local ox, oy, oz = a.x + u.x * eh, a.y + u.y * eh, a.z + u.z * eh
    local tx, ty, tz = getT()
    if not tx then return nil end
    return ox, oy, oz, tx - ox, ty - oy, tz - oz
  end
end
local function body_chest(id)
  return function()
    local n = C.bodyOf(id)
    if not (n and n.valid ~= false) then return nil end
    local u = up_of(n)
    return n.x + u.x * 0.3, n.y + u.y * 0.3, n.z + u.z * 0.3
  end
end
-- One bolt: optional scope, `secs` of charge, pictures on the way.
--   o = { scope, shot_scope, shot_charge, shot_bolt, bolt_frames, shot_hit, hit_frames }
local function rmb(down) input.simulate { button = 1, down = down } end
local function fire(getT, secs, o)
  o = o or {}
  -- the scope through the REAL right button (the camera's look and the
  -- context menu see it as a player's held press); the trigger and the aim
  -- through tool_belt's hook
  input.simulate { mouse = { 640, 360 } }
  TB.sim = { btn = { [0] = false }, aim = aim_at(getT) }
  if o.scope then rmb(true) end
  hold(o.scope and 0.7 or 0.3)
  if o.shot_scope then shot(o.shot_scope); frames(2) end
  local hits0, shots0 = SV.stats.hits, SV.stats.shots
  TB.sim.btn[0] = true
  hold(secs * 0.6)
  if o.shot_charge then shot(o.shot_charge); frames(1) end
  hold(secs * 0.4)
  local ch = SV.charge
  TB.sim.btn[0] = false
  wait_for(function() return SV.stats.shots > shots0 end, 2, "the shot")
  if o.shot_bolt then frames(o.bolt_frames or 3); shot(o.shot_bolt) end
  wait_for(function() return SV.stats.hits > hits0 end, 4, "the hit")
  if o.shot_hit then frames(o.hit_frames or 1); shot(o.shot_hit) end
  hold(0.3)
  if o.scope then rmb(false) end
  return SV.lastHit, ch
end

local function scope_line(tag)
  local d = SV._debug and SV._debug()
  P("%s: scoped %s scopeK %.2f lens %s fov0 %s charge %.2f cell %s blocked %s aimDist %s", tag, tostring(SV.scoped),
    SV.scopeK or -1, tostring(d and d.lens.applied), tostring(findScript("planet_camera").params.fov_y), SV.charge or -1,
    tostring(SV.cell), tostring(SV.blocked), tostring(SV.aimDist))
end

local function main()
  boot()
  hold(3.0)
  local cam = findScript("planet_camera")
  local inv, H, I = findScript("inventory"), findScript("item_hand"), findScript("items")
  TB, SV, C = findScript("tool_belt"), findScript("surveyor"), findScript("crew")
  P("scripts: surveyor %s tool_belt %s crew %s items %s", tostring(SV ~= nil), tostring(TB ~= nil), tostring(C ~= nil), tostring(I ~= nil))
  if not (SV and TB and C) then R("scripts", false, "missing"); return end
  C.setDeath(true)
  -- 1. the item at the BUY counter
  local onshop = false
  for _, e in ipairs(inv.shopList()) do if e.id == "surveyor" then onshop = e.cost end end
  local co = findScript("company")
  if co and co.earn then co.earn(20000, "probe") end
  local cash0 = co and co.balance and co.balance() or nil
  local ok, why = inv.buyItem("crew:1", "surveyor", 1)
  local cash1 = co and co.balance and co.balance() or nil
  local fl = inv.fills("crew:1", "surveyor")
  R("buy", onshop and ok and #fl == 1 and fl[1] == 100, "on the shop list at $%s; bought %s (%s); cash %s → %s; cell %s; pack %s",
    tostring(onshop), tostring(ok), tostring(why), tostring(cash0), tostring(cash1), tostring(fl[1]), inv.lineFull("crew:1"))
  -- 2. a craft part
  local vc = launch()
  if not vc then R("craft", false, "no craft"); return end
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  tap("f")
  local pw = findScript("planet_walker")
  wait_for(function() return pw.onFoot end, 20, "on foot")
  hold(1.5)
  H.hold("surveyor")
  hold(1.0)
  R("in hand", TB.toolId() == "surveyor" and TB.gate == "in hand", "tool %s gate %s", tostring(TB.toolId()), tostring(TB.gate))
  local function pod_pt()
    for _, ch in ipairs(vc.node:children()) do
      if vc.uidOfNode(ch) == by.pod then return ch.worldPos.x, ch.worldPos.y, ch.worldPos.z end
    end
    return vc.node.x, vc.node.y, vc.node.z
  end
  -- walk off 30 m from the pod (on the ground, in the base frame's plane)
  do
    local b = home()
    local px, py, pz = pod_pt()
    local pr = { x = px - b.x, y = py - b.y, z = pz - b.z }
    local u = unit(pr)
    local _, t1 = base_frame()
    local R0 = len(pr.x, pr.y, pr.z)
    local best = nil
    for k = 0, 7 do
      local ang = k * math.pi / 4
      local _, ta, tb2 = base_frame()
      local t = unit({ x = ta.x * math.cos(ang) + tb2.x * math.sin(ang), y = ta.y * math.cos(ang) + tb2.y * math.sin(ang),
                       z = ta.z * math.cos(ang) + tb2.z * math.sin(ang) })
      local a = 30 / R0
      local dir = unit({ x = u.x * math.cos(a) + t.x * math.sin(a), y = u.y * math.cos(a) + t.y * math.sin(a), z = u.z * math.cos(a) + t.z * math.sin(a) })
      local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 60)
      if gr then
        local sx, sy, sz = b.x + dir.x * (gr + 1.5), b.y + dir.y * (gr + 1.5), b.z + dir.z * (gr + 1.5)
        local h = raycast(sx, sy, sz, px - sx, py - sy, pz - sz, 40, find("Astronaut"))
        local clear = h and h.node and vc.uidOfNode(h.node) ~= nil
        if clear and not best then best = { dir = dir, r = gr } end
      end
    end
    if best then put_astro(best) else P("no clear spot 30 m from the pod") end
  end
  hold(1.5)
  local px, py, pz = pod_pt()
  do
    local a0 = find("Astronaut")
    P("stood %.1f m from the pod; in hand %s", len(px - a0.x, py - a0.y, pz - a0.z), tostring(TB.toolId()))
  end
  if TB.toolId() ~= "surveyor" then H.hold("surveyor"); hold(0.8) end
  face(px, py, pz)
  cam.firstPerson = false
  hold(1.0)
  local hp0 = vc.partHp(by.pod)
  local h1 = fire(pod_pt, 1.0, { scope = true, shot_scope = "part_tp_scope", shot_hit = "part_tp_impact", hit_frames = 2 })
  hold(1.0)
  local hp1 = vc.partHp(by.pod)
  shot("part_tp_scorch")
  local ms = SV.markList and nil
  R("part", h1 and h1.kind == "part" and h1.uid == by.pod and hp1 and hp1 < hp0 - 0.1,
    "hit %s uid %s (pod %s) at %.1f m: hp %.2f → %.2f (dmg %.3f); hitPart %s; fire %.3f ms hit %.3f ms",
    tostring(h1 and h1.kind), tostring(h1 and h1.uid), tostring(by.pod), h1 and h1.d or -1, hp0 or -1, hp1 or -1,
    h1 and h1.dmg or -1, tostring(vc.hitPart ~= nil), SV.stats.fire_ms, SV.stats.hit_ms)
  local cnt = perf.counts and perf.counts() or {}
  P("decals now %s", tostring(cnt.decals))
  -- up close while it is still light: the burn mark on the hull where the
  -- bolt struck and the hull's own wear (first person, 3.5 m off the line of
  -- fire, a little to the side)
  local back30 = nil
  do
    local a0 = find("Astronaut")
    local b0 = home()
    back30 = { x = a0.x - b0.x, y = a0.y - b0.y, z = a0.z - b0.z }
    local qx, qy, qz = pod_pt()
    local dx, dy, dz = a0.x - qx, a0.y - qy, a0.z - qz
    local dl = len(dx, dy, dz)
    local u0 = up_of(a0)
    local sd = unit(cross({ x = dx, y = dy, z = dz }, u0))
    a0.x, a0.y, a0.z = qx + dx / dl * 3.2 + sd.x * 1.0, qy + dy / dl * 3.2 + sd.y * 1.0, qz + dz / dl * 3.2 + sd.z * 1.0
    a0.vx, a0.vy, a0.vz = 0, 0, 0
    hold(1.0)
    cam.firstPerson = true
    qx, qy, qz = pod_pt()
    face(qx, qy, qz)
    hold(1.2)
    shot("part_scorch_close")
    frames(2)
    cam.firstPerson = false
    -- back to the 30 m line
    local b1 = home()
    a0.x, a0.y, a0.z = b1.x + back30.x, b1.y + back30.y, b1.z + back30.z
    a0.vx, a0.vy, a0.vz = 0, 0, 0
    hold(1.0)
    qx, qy, qz = pod_pt()
    face(qx, qy, qz)
    hold(0.5)
  end
  -- a second and a third bolt
  hold(0.3)
  fire(pod_pt, 1.0, {})
  hold(0.5)
  local hp2 = vc.partHp(by.pod)
  hold(0.8)
  fire(pod_pt, 1.0, {})
  hold(0.5)
  do
    P("pod after three bolts: hp %.2f; damaged parts %d", vc.partHp(by.pod) or -1, #vc.damagedParts())
    if vc.hitPart then
      -- (with vessel_controller.hitPart a part can be shot to pieces)
      local a1 = find("Astronaut")
      local q1, q2, q3 = pod_pt()
      local ex, ey, ez = a1.x - q1, a1.y - q2, a1.z - q3
      local el = len(ex, ey, ez)
      a1.x, a1.y, a1.z = q1 + ex / el * 30, q2 + ey / el * 30, q3 + ez / el * 30
      a1.vx, a1.vy, a1.vz = 0, 0, 0
      hold(1.0)
      local hb4 = fire(pod_pt, 1.0, { shot_hit = "part_break", hit_frames = 6 })
      hold(1.0)
      local hp4 = vc.partHp(by.pod)
      R("part breaks", hb4 and hb4.hp == 0 and (hp4 == nil or hp4 <= 0), "a fourth bolt: hp → %s (partHp now %s: broken)",
        tostring(hb4 and hb4.hp), tostring(hp4))
    end
  end
  R("part2", hp2 and hp1 and hp2 < hp1 - 0.1, "a second bolt: hp %.2f → %.2f", hp1 or -1, hp2 or -1)

  -- 3. a CrewBody 150 m off, then 30 m
  -- (on a world this small the ground curves away 0.9 m under a 150 m
  -- chord, so a clear line wants a valley or a crest: search for one, the
  -- target further out or nearer in along each bearing)
  local S, T150, T30 = nil, nil, nil
  local tried, nearest = 0, 0
  local cands = {}
  for _, d0 in ipairs({ 120, 160, 200, 240, 280, 320, 360, 400 }) do
    for k = 0, 15 do
      local ang = k * math.pi / 8
      local s0 = spot(d0, ang)
      for j = 0, 15 do
        local hd = j * math.pi / 8
        local s1, s2 = s0 and move(s0, 150, hd), s0 and move(s0, 30, hd)
        if s0 and s1 and s2 then
          tried = tried + 1
          if tried % 48 == 0 then yield() end
          local sx, sy, sz = at(s0, 1.6)
          local tx, ty, tz = at(s1, 1.0)
          local ux, uy, uz = at(s2, 1.0)
          local d1 = len(tx - sx, ty - sy, tz - sz)
          local h = raycast(sx, sy, sz, tx - sx, ty - sy, tz - sz, d1, find("Astronaut"))
          local h2 = raycast(sx, sy, sz, ux - sx, uy - sy, uz - sz, 30, find("Astronaut"))
          if h then nearest = math.max(nearest, h.distance / d1) end
          if not h and not h2 then cands[#cands + 1] = { s0, s1, s2, sun = sun_at(s0) }; break end
        end
      end
      if #cands >= 40 then break end
    end
    if #cands >= 40 then break end
  end
  -- daylight for the pictures: the sunniest lines first
  table.sort(cands, function(x, y) return x.sun > y.sun end)
  if cands[1] then P("candidates: %d, sun from %.2f to %.2f", #cands, cands[1].sun, cands[#cands].sun) end
  -- the plants' and rocks' colliders stream in round the crew: stand there
  -- and look again before taking a line
  for i, c in ipairs(cands) do
    put_astro(c[1])
    hold(2.0)
    local a0 = find("Astronaut")
    local sx, sy, sz = at(c[1], 1.6)
    local ok1 = true
    for _, t in ipairs({ c[2], c[3] }) do
      local tx, ty, tz = at(t, 1.3)
      local dd = len(tx - sx, ty - sy, tz - sz)
      local h = raycast(sx, sy, sz, tx - sx, ty - sy, tz - sz, dd, { ignore = { a0 } })
      if h then ok1 = false; P("candidate %d blocked at %.0f of %.0f m by %s", i, h.distance, dd, tostring(h.node and h.node.name)) end
    end
    if ok1 then S, T150, T30 = c[1], c[2], c[3] break end
  end
  if S then P("range: shooter %.0f m out on bearing %.2f; %d lines tried, %d candidates", S.d, S.ang, tried, #cands) end
  if not S then R("range", false, "no clear 150 m line near the base (%d lines tried, %d candidates, the best clear to %.0f%%)", tried, #cands, nearest * 100); return end
  put_astro(S)
  -- member #2 out at 150 m, facing the shooter
  local x2, y2, z2 = at(T150, 1.02)
  C.setDown(2, x2, y2, z2)
  wait_for(function() local n = C.bodyOf(2); return n and n.valid ~= false end, 10, "#2's body")
  hold(1.5)
  local sxw, syw, szw = at(S, 1.0)
  local n2 = C.bodyOf(2)
  if n2 then
    local u = up_of(n2)
    local fx, fy, fz = sxw - n2.x, syw - n2.y, szw - n2.z
    local v = fx * u.x + fy * u.y + fz * u.z
    fx, fy, fz = fx - u.x * v, fy - u.y * v, fz - u.z * v
    local fl2 = len(fx, fy, fz)
    C.patch(2, { face = { x = fx / fl2, y = fy / fl2, z = fz / fl2 } })
  end
  -- the capsules against the models: where the head bone is
  local function head_of(n)
    for _, ch in ipairs(n:children()) do
      if ch.name == "AstroModel" and ch.animator then
        local an = ch:animator()
        local hb = an and an:boneWorld("Head")
        if hb then local u = up_of(n); return (hb.x - n.x) * u.x + (hb.y - n.y) * u.y + (hb.z - n.z) * u.z end
      end
    end
  end
  local a = find("Astronaut")
  P("head bone over the centre: avatar %s, body #2 %s (the capsule's head zone starts at %.2f)",
    tostring(head_of(a)), tostring(n2 and head_of(n2)), -0.98 + 0.84 * 1.9)
  local d = SV._debug()
  for _, t in ipairs(d.targets) do P("target #%d %s seated %s r %.2f", t.id, t.name, tostring(t.seated), t.r) end
  -- holding: third person from the front quarter (idle, then charging: the
  -- shouldered aim), then first person
  cam.firstPerson = false
  input.simulate { mouse = { 640, 360 } }
  TB.sim = { btn = { [0] = false }, aim = aim_at(body_chest(2)) }
  do
    local tx, ty, tz = body_chest(2)()
    local a0 = find("Astronaut")
    local u = up_of(a0)
    local g = { x = tx - a0.x, y = ty - a0.y, z = tz - a0.z }
    local v = g.x * u.x + g.y * u.y + g.z * u.z
    g = unit({ x = g.x - u.x * v, y = g.y - u.y * v, z = g.z - u.z * v })
    local rt = cross(g, u)
    local f = unit({ x = -g.x * 0.55 - rt.x * 0.85, y = -g.y * 0.55 - rt.y * 0.85, z = -g.z * 0.55 - rt.z * 0.85 })
    -- turn the body to the target first (a moment's charge), then let go of it
    face(tx, ty, tz)
    TB.sim.btn[0] = true
    hold(0.08)        -- (under the minimum charge: no bolt, but the body turns to the aim)
    TB.sim.btn[0] = false
    hold(1.6)
    cam.face(f.x, f.y, f.z, -0.12)
    hold(1.0)
    shot("tp_hold")
    frames(2)
    TB.sim.btn[0] = true
    hold(0.7)
    shot("tp_charge")
    frames(2)
    -- let go with the aim on the ground 8 m ahead and 3 m right: a ground hit
    local gh0 = SV.stats.ground_hits
    TB.sim.aim = aim_at(function()
      local a1 = find("Astronaut")
      local u1 = up_of(a1)
      return a1.x + g.x * 8 + rt.x * 3 - u1.x * 1.0, a1.y + g.y * 8 + rt.y * 3 - u1.y * 1.0, a1.z + g.z * 8 + rt.z * 3 - u1.z * 1.0
    end)
    frames(2)
    TB.sim.btn[0] = false
    wait_for(function() return SV.stats.ground_hits > gh0 end, 3, "the ground hit")
    frames(2)
    shot("tp_ground_hit")
    R("ground", SV.lastHit and SV.lastHit.kind == "ground", "%s at %.1f m (a burn mark and a %.2f m bite); hit %.3f ms",
      tostring(SV.lastHit and SV.lastHit.kind), SV.lastHit and SV.lastHit.d or -1, SV.params.crater_r, SV.stats.hit_ms)
    TB.sim = { btn = { [0] = false }, aim = aim_at(body_chest(2)) }
    hold(1.5)
  end
  face(body_chest(2)())
  cam.firstPerson = true
  hold(1.2)
  shot("fp_hold")
  frames(2)
  local cell0 = SV.cell
  -- shot 1, 150 m, from the hip (first person): the charge, the bolt, the hit
  local hA = fire(body_chest(2), 1.0, { shot_charge = "fp_charge", shot_bolt = "fp_bolt", bolt_frames = 1,
                                         shot_hit = "fp_impact150", hit_frames = 1 })
  local r2 = C.get(2)
  local al = C.alerts(2)
  R("hit150", hA and hA.kind == "crew" and hA.id == 2 and r2.hp < 0.6 and r2.status == "afoot" and al.hit ~= nil,
    "%s #%s %s at %.1f m: -%.3f → hp %.3f; HIT alert %s; fire %.3f ms, hit %.3f ms, a frame of flight %.3f ms",
    tostring(hA and hA.kind), tostring(hA and hA.id), tostring(hA and hA.zone), hA and hA.d or -1, hA and hA.dmg or -1,
    r2.hp or -1, tostring(al.hit ~= nil), SV.stats.fire_ms, SV.stats.hit_ms, SV.stats.step_ms)
  hold(1.0)
  -- shot 2, 150 m, through the scope
  local hB = fire(body_chest(2), 1.0, { scope = true, shot_scope = "fp_scope", shot_hit = "fp_scope_impact", hit_frames = 2 })
  scope_line("after the scoped shot")
  r2 = C.get(2)
  R("hit150b", hB and hB.kind == "crew" and hB.id == 2 and r2.status == "afoot" and r2.hp < 0.2,
    "#%s %s -%.3f → hp %.3f (alive: two hits at 150 m are not enough)", tostring(hB and hB.id), tostring(hB and hB.zone),
    hB and hB.dmg or -1, r2.hp or -1)
  hold(1.0)
  -- member #2 walks in to 30 m; shot 3 from the shoulder (third person)
  x2, y2, z2 = at(T30, 1.02)
  local b = home()
  C.patch(2, { x = x2 - b.x, y = y2 - b.y, z = z2 - b.z })
  hold(1.0)
  cam.firstPerson = false
  face(body_chest(2)())
  hold(1.0)
  local hC = fire(body_chest(2), 1.0, { scope = true, shot_scope = "tp_scope", shot_bolt = "tp_bolt", bolt_frames = 1,
                                         shot_hit = "tp_impact", hit_frames = 1 })
  r2 = C.get(2)
  local mem = C.memorial()
  R("kill30", hC and hC.kind == "crew" and r2.status == "dead" and r2.died and r2.died.cause == "shot",
    "#2 %s: cause %s, detail %q; memorial %d row(s): %s; caption %q", tostring(r2.status), tostring(r2.died and r2.died.cause),
    tostring(r2.died and r2.died.detail), #mem, mem[1] and (mem[1].name .. ": " .. tostring(mem[1].died.cause) .. " " .. tostring(mem[1].died.detail)) or "-",
    tostring(C.lastDeath and C.lastDeath.text))
  local rp = findScript("crew_roster_panel")
  if rp and rp.causeText and mem[1] then P("the memorial wall reads: %s", rp.causeText(mem[1].died)) end
  hold(1.5)
  shot("death_remains")
  -- 4. the avatar hit by a hostile bolt from 30 m: the HUD's chips
  do
    a = find("Astronaut")
    local u = up_of(a)
    local cx, cy, cz = a.x + u.x * 0.3, a.y + u.y * 0.3, a.z + u.z * 0.3
    -- from 30 m out (where #2 stood: a line known to be clear), chest high
    local ox, oy, oz = at(T30, 1.3)
    local dd0 = len(cx - ox, cy - oy, cz - oz)
    ox, oy, oz = ox + (cx - ox) / dd0 * 2.5, oy + (cy - oy) / dd0 * 2.5, oz + (cz - oz) / dd0 * 2.5
    local hp_a = C.get(C.activeId()).hp
    local n0 = SV.stats.hits
    SV.fireFrom(ox, oy, oz, cx - ox, cy - oy, cz - oz, { charge = 1.0, by = "a probe's hostile" })
    wait_for(function() return SV.stats.hits > n0 end, 2, "the hostile bolt")
    frames(3)
    shot("avatar_hit_hud")
    local al2 = C.alerts()
    local chips = findScript("crew_alerts_hud") and findScript("crew_alerts_hud").chipsOf(al2) or {}
    local ct = {}
    for _, c2 in ipairs(chips) do ct[#ct + 1] = c2[1] end
    R("avatar", SV.lastHit and SV.lastHit.kind == "crew" and SV.lastHit.id == C.activeId() and C.get(C.activeId()).hp < hp_a,
      "hostile bolt: %s #%s -%.3f, hp %.2f → %.2f; chips: %s", tostring(SV.lastHit and SV.lastHit.kind),
      tostring(SV.lastHit and SV.lastHit.id), SV.lastHit and SV.lastHit.dmg or -1, hp_a or -1, C.get(C.activeId()).hp or -1,
      table.concat(ct, " | "))
  end
  -- 5. death off: #3 shot twice at 30 m → rescued
  C.setDeath(false)
  local m0 = #C.memorial()
  local x3, y3, z3 = at(T30, 1.02)
  C.setDown(3, x3, y3, z3)
  wait_for(function() local n = C.bodyOf(3); return n and n.valid ~= false end, 10, "#3's body")
  hold(1.5)
  cam.firstPerson = true
  face(body_chest(3)())
  hold(0.6)
  fire(body_chest(3), 1.0, {})
  hold(0.9)
  fire(body_chest(3), 1.0, {})
  hold(1.0)
  local r3 = C.get(3)
  R("rescue", r3.status == "base" and (r3.hp or 0) >= 0.99 and #C.memorial() == m0,
    "death off: #3 %s hp %.2f; memorial %d → %d", tostring(r3.status), r3.hp or -1, m0, #C.memorial())
  C.setDeath(true)
  -- 6. the cell: drained, then recharged at the base; no firing indoors
  local cell1 = SV.cell
  R("cell drained", cell0 and cell1 and cell1 < cell0 - 25, "cell %.0f → %.0f after five full bolts", cell0 or -1, cell1 or -1)
  -- 7. cost: three bolts in flight (into the sky) vs none
  local function gpu_avg(n)
    local tot, pt, k = 0, 0, 0
    local scr = 0
    for _ = 1, n do
      yield()
      local okg, g = pcall(perf.gpu)
      if okg and g and g.total then
        tot = tot + g.total
        for _, p in ipairs(g.passes or {}) do if p.name == "particles" then pt = pt + p.ms end end
        k = k + 1
      end
      scr = scr + (perf.scriptMs and perf.scriptMs("surveyor") or 0)
    end
    return k > 0 and tot / k or -1, k > 0 and pt / k or -1, scr / n
  end
  cam.firstPerson = false
  hold(1.0)
  local g0, p0, s0 = gpu_avg(40)
  a = find("Astronaut")
  local u = up_of(a)
  local f = { x = cam.fwd_x, y = cam.fwd_y, z = cam.fwd_z }
  -- three bolts across the view, 20 m out, climbing a little (side on, so
  -- each tracer's streak shows)
  local rt = unit(cross(f, u))
  for k2 = 1, 3 do
    local o = { x = a.x + f.x * 20 - rt.x * 14 + u.x * (2 + k2 * 1.2), y = a.y + f.y * 20 - rt.y * 14 + u.y * (2 + k2 * 1.2),
                z = a.z + f.z * 20 - rt.z * 14 + u.z * (2 + k2 * 1.2) }
    -- (slowed to 40 m/s so a picture can catch them side on)
    SV.fireFrom(o.x, o.y, o.z, rt.x + u.x * 0.15, rt.y + u.y * 0.15, rt.z + u.z * 0.15, { charge = 1.0, by = "probe", speed = 40 })
    frames(3)
  end
  frames(2)
  do
    local d = SV._debug()
    for k2 = 1, 4 do
      local n = d.pool[k2]
      local bb = d.bolts[k2]
      local ok2, info = pcall(function()
        if type(n) ~= "table" and type(n) ~= "userdata" then return tostring(n) end
        local ps = n.particles and n:particles()
        local L = n:getcomponent("PointLight")
        return string.format("valid %s at %.1f,%.1f,%.1f visible %s ps %s playing %s light %s", tostring(n.valid), n.x, n.y, n.z,
          tostring(n.visible), tostring(ps ~= nil), tostring(ps and ps:isPlaying()), tostring(L and L.intensity))
      end)
      local bw = ""
      if bb then local hb = space.body(bb.body); bw = string.format(" bolt at %.1f,%.1f,%.1f flown %.1f", hb.x + bb.x, hb.y + bb.y, hb.z + bb.z, bb.flown) end
      P("POOL %d: %s%s", k2, ok2 and info or ("err " .. tostring(info)), bw)
    end
  end
  shot("tp_three_bolts")
  local g1, p1, s1 = gpu_avg(40)
  P("COST GPU total %.3f → %.3f ms with three bolts (particles pass %.3f → %.3f ms); surveyor script %.3f → %.3f ms/frame",
    g0, g1, p0, p1, s0, s1)
  hold(1.5)
  -- recharge at the base
  local fo = findScript("flight_ops")
  local hx, hy, hz = fo.crewHome()
  -- (the probe's teleports can drop the crew a few metres: whole again first)
  C.patch(C.activeId(), { hp = 1.0 })
  a = find("Astronaut")
  a.x, a.y, a.z = hx, hy, hz
  a.vx, a.vy, a.vz = 0, 0, 0
  local cl0 = SV.cell
  hold(3.0)
  R("recharge", SV.cell and cl0 and SV.cell > cl0 + 5, "at the base: cell %.1f → %.1f in 3 s", cl0 or -1, SV.cell or -1)
  -- indoors: in the hangar
  local hg = find("FacHangar")
  if hg then
    local p = hg:toWorld(vec3(0, 1.3, 0))
    a.x, a.y, a.z = p.x, p.y, p.z
    a.vx, a.vy, a.vz = 0, 0, 0
    hold(1.5)
    local n0 = SV.stats.shots
    TB.sim = { btn = { [0] = true, [1] = false } }
    hold(1.0)
    TB.sim.btn[0] = false
    hold(0.5)
    R("indoors", SV.stats.shots == n0 and SV.blocked ~= nil, "in the hangar: blocked %s, shots %d → %d", tostring(SV.blocked), n0, SV.stats.shots)
    shot("indoors")
  else
    P("no FacHangar node to stand in")
  end
  TB.sim = nil
  P("STATS shots %d hits %d crew %d parts %d ground %d", SV.stats.shots, SV.stats.hits, SV.stats.crew_hits, SV.stats.part_hits, SV.stats.ground_hits)
end

function update(node, dt)
  if not CO then
    NODE = node
    CO = coroutine.create(function()
      local ok, err = pcall(main)
      if not ok then P("ERROR %s", tostring(err)); FAILS = FAILS + 1 end
      wait_for(function() return pending == 0 end, 10, "the pictures")
      P("RESULT rifle: %s (%d failed)", FAILS == 0 and "PASS" or "FAIL", FAILS)
      if params.quit > 0 then app.quit() end
    end)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
