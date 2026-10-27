-- ── feel probe (tools/perf/feelprobe.sh): the playtest's "feel" items ──────
-- Spliced into a copy of perfbench.lua before its main (like ctrlprobe).
--   feelscope  the TL-5 Surveyor's scope: RMB held in first person for 4 s;
--              the main camera's fovY every frame (writes, flips back to the
--              unzoomed value = the old jitter), the sway's angles, pictures
--              of the scope coming up, settled, and the kick after a shot.
--   feelswim   the crew in the home world's sea: the swim's speed, the
--              stroke's play rate, sprint, and the glide after letting go.
--   feelpush   a rover (light) released on the runway, the crew walked into
--              it at a run for 6 s, A (the old unlimited shove, pushOff) and
--              B (the capped push); then the gravity gun on it at the old and
--              the new power budget.
--   feelheavy  a two-stage rocket (heavy) released on the pad, the crew run
--              into it for 6 s, A and B.
--   feelplants the rare plants' orbs and the glow motes after the load:
--              visible / alpha against time, with the flora patch applied
--              (PATCHES=flora_marks_until_loaded.patch).
-- Lines "FEEL ...", one "FEEL RESULT" a check; pictures in user://feelshots/.

local function F(fmt, ...) P("FEEL " .. fmt, ...) end
local function fshot(nm, red)
  local done = false
  -- (a red square top-left: whether draw.rect lands in camera.capture at all)
  if red then draw.rect(0, 0, 60, 60, 1, 0, 0, 1) end
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://feelshots/" .. nm .. ".png", bytes); F("SHOT %s", nm)
    else F("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then F("capture error %s", tostring(err)); return end
  wait_for(function() if red then draw.rect(0, 0, 60, 60, 1, 0, 0, 1) end; return done end, 5, "shot " .. nm)
end
local function rel(b, p) return { x = p.x - b.x, y = p.y - b.y, z = p.z - b.z } end

-- ── the scope ───────────────────────────────────────────────────────────────
local function run_feelscope()
  wait_ready(90)
  wait(2)
  local inv, H = findScript("inventory"), findScript("item_hand")
  local TB, SV, pc = findScript("tool_belt"), findScript("surveyor"), findScript("planet_camera")
  local co = findScript("company")
  if co and co.earn then co.earn(20000, "probe") end
  local ok, why = inv.buyItem("crew:1", "surveyor", 1)
  F("bought %s %s", tostring(ok), tostring(why))
  wait(0.5)
  H.hold("surveyor")
  wait(1.2)
  F("in hand %s gate %s", tostring(TB.toolId()), tostring(TB.gate))
  -- walk 40 m out from the base so no roof is overhead, facing away from it
  local A = astro()
  local b = home()
  local u = unit(rel(b, A))
  local u0, _, _, R = base_frame()
  local away = sub(u, scl(u0, dot(u, u0)))
  if len(away.x, away.y, away.z) < 1e-3 then away = cross(u, { x = 0, y = 0, z = 1 }) end
  away = unit(away)
  pc.face(away.x, away.y, away.z, 0.0)
  local pw = findScript("planet_walker")
  pw.steer(1, 0, true)
  wait(5)
  pw.steer(nil)
  wait(1)
  pc.firstPerson = true
  wait(1.0)
  local cn = pc.node
  local cc = cn:getcomponent("Camera")
  input.simulate { mouse = { 640, 360 } }
  -- A: the old lens's behaviour is in git; here the new one, sampled per frame
  local fov0 = cc.fovY
  F("fov before %.4f (settings %s°) blocked %s", fov0, tostring(findScript("settings").get("fov")), tostring(SV.blocked))
  F("sens before %.4f", pc.params.sensitivity)
  input.simulate { button = 1, down = true }
  local t0, n, flips, writes0 = time, 0, 0, (SV.lens and SV.lens.writes) or 0
  local minf, maxf, settled_t = 9, 0, nil
  local shots = { [0.12] = "1_scope_rising", [1.6] = "2_scope_settled" }
  local taken = {}
  local maxyaw, maxpitch = 0, 0
  local last_fov
  while time - t0 < 4.0 do
    yield()
    n = n + 1
    local f = cc.fovY or -1
    local t = time - t0
    if SV.scopeK >= 1 and not settled_t then settled_t = t end
    if settled_t and t > settled_t + 0.05 then
      minf, maxf = math.min(minf, f), math.max(maxf, f)
      if last_fov and math.abs(f - last_fov) > 0.01 then flips = flips + 1 end
      last_fov = f
      maxyaw = math.max(maxyaw, math.abs(SV.sway.yaw)); maxpitch = math.max(maxpitch, math.abs(SV.sway.pitch))
    end
    if n % 15 == 0 then
      F("t %.2f scoped %s K %.3f fov %.4f sens %.4f blocked %s sway yaw %.2f pitch %.2f mrad eye %.1f,%.1f mrad hook %s",
        t, tostring(SV.scoped), SV.scopeK, f, pc.params.sensitivity, tostring(SV.blocked),
        SV.sway.yaw * 1000, SV.sway.pitch * 1000, SV.sway.ex * 1000, SV.sway.ey * 1000, tostring(SV.sway.hook))
    end
    for at, nm in pairs(shots) do if t >= at and not taken[nm] then taken[nm] = true; fshot(nm) end end
  end
  F("scope draws %s, reticle hook: cinematic %s", tostring(SV.stats.scope_draws), tostring(pc.cinematic))
  fshot("2b_scope_red", true)
  local want = 2 * math.atan(math.tan(fov0 * 0.5) / 4)
  F("RESULT scope stable: %s — settled at %.2f s, fov %.4f..%.4f (want %.4f), %d jumps > 0.01 rad after settling, %d frames, lens writes %d, sway max yaw %.2f pitch %.2f mrad",
    (settled_t and flips == 0 and math.abs(minf - want) < 2e-3 and math.abs(maxf - want) < 2e-3) and "PASS" or "FAIL",
    settled_t or -1, minf, maxf, want, flips, n, ((SV.lens and SV.lens.writes) or 0) - writes0, maxyaw * 1000, maxpitch * 1000)
  -- the kick: a full-charge shot through the scope
  TB.sim = { btn = { [0] = true } }
  wait(1.0)
  TB.sim.btn[0] = false
  local tk, kmax = time, 0
  local kshot = false
  local function elev()
    local f = cn:worldForward()
    local up = unit(rel(home(), astro()))
    local pf = { x = pc.fwd_x or 0, y = pc.fwd_y or 0, z = pc.fwd_z or 0 }
    return math.asin(math.max(-1, math.min(1, dot(f, up)))) * 1000, math.asin(math.max(-1, math.min(1, dot(pf, up)))) * 1000
  end
  local e0, p0 = elev()
  F("kick: view elevation %.1f mrad, planet_camera's %.1f mrad before", e0, p0)
  while time - tk < 0.8 do
    yield()
    local e1, p1 = elev()
    if math.floor((time - tk) * 20) ~= math.floor((time - tk - 0.017) * 20) then
      F("kick t %.2f view %.1f pc %.1f sway pitch %.1f mrad", time - tk, e1, p1, SV.sway.pitch * 1000)
    end
    kmax = math.max(kmax, SV.sway.kick)
    if not kshot and time - tk > 0.07 then kshot = true; fshot("3_scope_kick") end
  end
  F("kick: peak %.2f mrad, now %.2f mrad; shots %d", kmax * 1000, SV.sway.kick * 1000, SV.stats.shots)
  TB.sim = nil
  wait(1.5)
  fshot("4_scope_after")
  input.simulate { button = 1, down = false }
  wait(1.0)
  for _ = 1, 3 do yield(); F("sens now %.4f, lens sens0 %s sens_w %s applied %s K %.4f", pc.params.sensitivity, tostring(SV.lens.sens0), tostring(SV.lens.sens_w), tostring(SV.lens.applied), SV.scopeK) end
  F("RESULT scope out: %s — fov %.4f back to %.4f, sens %.4f",
    math.abs(cc.fovY - fov0) < 1e-3 and "PASS" or "FAIL", cc.fovY, fov0, pc.params.sensitivity)
  -- third person: the 2x shoulder zoom, stable too
  pc.firstPerson = false
  wait(1.0)
  input.simulate { button = 1, down = true }
  wait(1.2)
  local a1 = cc.fovY
  local fl = 0
  for _ = 1, 90 do yield(); if math.abs(cc.fovY - a1) > 0.01 then fl = fl + 1 end end
  fshot("5_tp_shoulder")
  input.simulate { button = 1, down = false }
  F("RESULT shoulder zoom stable: %s — fov %.4f (want %.4f), %d off-frames in 90",
    (fl == 0 and math.abs(a1 - 2 * math.atan(math.tan(fov0 * 0.5) / 2)) < 2e-3) and "PASS" or "FAIL", a1,
    2 * math.atan(math.tan(fov0 * 0.5) / 2), fl)
end

-- ── the swim ────────────────────────────────────────────────────────────────
local function find_sea(b, R)
  -- open water: 3 m under the sea's surface, the nearest rock more than 2 m
  -- off (terrain.query), at the spot and 15 m round it; the candidates are
  -- then made exactly (terrain.prepare) and asked again (a stand-in's sea was
  -- land once the real ground streamed in: a swimmer walked out at 3 s)
  local function open_at(u)
    local bb = home()
    local t1 = unit(cross(u, { x = 0, y = 1, z = 0 }))
    local t2 = unit(cross(u, t1))
    local worst = 1e9
    for _, o in ipairs({ { 0, 0 }, { 15, 0 }, { -15, 0 }, { 0, 15 }, { 0, -15 } }) do
      local r = R - 3
      local q = terrain.query(bb.x + u.x * r + t1.x * o[1] + t2.x * o[2], bb.y + u.y * r + t1.y * o[1] + t2.y * o[2],
        bb.z + u.z * r + t1.z * o[1] + t2.z * o[2])
      if not q then return -1 end
      worst = math.min(worst, q)
    end
    return worst
  end
  local cand = {}
  local N = 2000
  for i = 0, N - 1 do
    local y = 1 - (i + 0.5) / N * 2
    local rr = math.sqrt(1 - y * y)
    local th = i * 2.399963
    local u = { x = math.cos(th) * rr, y = y, z = math.sin(th) * rr }
    local q = open_at(u)
    if q > 2 then cand[#cand + 1] = { u = u, d = q } end
    if i % 50 == 0 then yield() end
  end
  table.sort(cand, function(a, c) return a.d > c.d end)
  F("sea: %d open-water candidates of %d", #cand, N)
  for k = 1, math.min(8, #cand) do
    local u = cand[k].u
    b = home()
    local px, py, pz = b.x + u.x * R, b.y + u.y * R, b.z + u.z * R
    if terrain.prepare then pcall(terrain.prepare, px, py, pz, 96) end
    wait_for(function() return not terrain.ready or terrain.ready(px, py, pz, 40) end, 20, "the sea's ground")
    local q = open_at(u)
    F("sea candidate %d: clearance %.1f m (stand-in), %.1f m (exact)", k, cand[k].d, q)
    if q > 2 then return u, q end
  end
  return nil
end
local function run_feelswim()
  wait_ready(90)
  local b = home()
  local cl = findScript("climate")
  local R = cl and cl.seaRadius(b.name) or 0
  if R <= 0 then F("RESULT swim: no sea on the home world"); return end
  local u, deep = find_sea(b, R)
  if not u then F("RESULT swim: no open sea"); return end
  F("sea %.1f m deep", deep)
  local A = astro()
  b = home()
  A.x, A.y, A.z = b.x + u.x * (R + 0.2), b.y + u.y * (R + 0.2), b.z + u.z * (R + 0.2)
  A.vx, A.vy, A.vz = 0, 0, 0
  wait(4)
  local pw, pc = findScript("planet_walker"), findScript("planet_camera")
  local t = cross(u, { x = 0, y = 1, z = 0 })
  if len(t.x, t.y, t.z) < 1e-3 then t = cross(u, { x = 1, y = 0, z = 0 }) end
  t = unit(t)
  pc.face(t.x, t.y, t.z, 0.2)
  local function spd()
    local up = unit(rel(home(), A))
    local v = { x = A.vx, y = A.vy, z = A.vz }
    local h = sub(v, scl(up, dot(v, up)))
    return len(h.x, h.y, h.z), dot(v, up)
  end
  local function leg(tag, secs, f, sprint, climb)
    pw.steer(f, 0, sprint, false, climb or 0)
    local t0 = time
    local reach = nil
    local top = 0
    while time - t0 < secs do
      wait(0.5)
      local s, vu = spd()
      top = math.max(top, s)
      local ss = pw.swimState
      F("%s t %.1f speed %.2f vup %.2f swimming %s rate %.2f f %.2f", tag, time - t0, s, vu, tostring(pw.swimming), ss.rate or -1, ss.f or -1)
    end
    return top
  end
  local a = leg("crawl", 7, 1, false)
  fshot("swim_crawl")
  local sp = leg("sprint", 4, 1, true)
  -- let go: the glide
  pw.steer(0, 0, false)
  local t0 = time
  local s0 = spd()
  local half
  while time - t0 < 4 do
    yield()
    local s = spd()
    if not half and s < s0 * 0.5 then half = time - t0 end
  end
  F("glide: from %.2f m/s, half speed after %s s, %.2f m/s after 4 s", s0, tostring(half and string.format("%.2f", half)), spd())
  local dv = leg("dive", 3, 0, false, -1)
  pw.steer(nil)
  F("RESULT swim: %s — crawl top %.2f m/s (param %.2f), sprint %.2f (param %.2f), stroke rate at the crawl %.2f",
    (a < 1.6 and sp < 2.2 and a > 0.8) and "PASS" or "FAIL", a, pw.params.swim, sp, pw.params.swim_fast, pw.swimState.rate or -1)
end

-- ── pushing ────────────────────────────────────────────────────────────────
local function exit_craft()
  tap("f")
  local pw = findScript("planet_walker")
  wait_for(function() return pw.onFoot end, 20, "on foot")
  wait(2.0)
end
local function shove(vn, tag, secs)
  local pw, pc = findScript("planet_walker"), findScript("planet_camera")
  local A = astro()
  local function frame()
    local b = home()
    local i = assembly.info(vn)
    return b, i, rel(b, i.com)
  end
  local b, i0, c0 = frame()
  local up = unit(c0)
  local mass = i0.mass
  -- stand 3.5 m off its side (planet frame), facing it
  local me = rel(b, A)
  local d = sub(me, c0)
  d = sub(d, scl(up, dot(d, up)))
  if len(d.x, d.y, d.z) < 0.1 then d = cross(up, { x = 0, y = 0, z = 1 }) end
  d = unit(d)
  local g = ground_r(b, up.x, up.y, up.z, b.radius * 1.3)
  local base = scl(up, dot(c0, up))
  local spot = { x = c0.x + d.x * 4.0, y = c0.y + d.y * 4.0, z = c0.z + d.z * 4.0 }
  local su = unit(spot)
  local gr = ground_r(b, su.x, su.y, su.z, b.radius * 1.3) or len(spot.x, spot.y, spot.z)
  A.x, A.y, A.z = b.x + su.x * (gr + 1.1), b.y + su.y * (gr + 1.1), b.z + su.z * (gr + 1.1)
  A.vx, A.vy, A.vz = 0, 0, 0
  wait(1.5)
  b, i0, c0 = frame()
  pc.firstPerson = true
  pc.face(-d.x, -d.y, -d.z, 0.0)
  wait(0.3)
  pw.steer(1, 0, true)
  local t0 = time
  local maxv, maxw, nmax, fmax = 0, 0, 0, 0
  local lc, lt = c0, time
  while time - t0 < secs do
    yield()
    local bb, ii, cc = frame()
    -- keep heading at it (planet frame, so the moving world can't steer us off)
    local me2 = rel(bb, A)
    local to = sub(cc, me2)
    to = sub(to, scl(up, dot(to, up)))
    if len(to.x, to.y, to.z) > 0.05 then to = unit(to); pc.face(to.x, to.y, to.z, 0.0) end
    if time - lt > 0.2 then
      local dd = sub(cc, lc)
      maxv = math.max(maxv, len(dd.x, dd.y, dd.z) / (time - lt))
      lc, lt = cc, time
    end
    local w = ii.angVel and len(ii.angVel.x, ii.angVel.y, ii.angVel.z) or 0
    maxw = math.max(maxw, w)
    local ps = pw.pushState
    nmax = math.max(nmax, ps.n or 0)
    fmax = math.max(fmax, ps.force or 0)
  end
  pw.steer(nil)
  pc.firstPerson = false
  local A2 = rel(home(), A)
  local dd = sub(A2, c0)
  dd = sub(dd, scl(up, dot(dd, up)))
  F("%s: walker on foot %s, %.2f m off the craft's axis at the end (from 4.0), craft anchored %s gripped %s",
    tag, tostring(pw.onFoot), len(dd.x, dd.y, dd.z), tostring(i0.anchored), tostring(i0.gripped))
  wait(0.5)
  local b1, i1, c1 = frame()
  local moved = sub(c1, c0)
  F("%s: mass %.2f t, %.0f s of running into it: moved %.3f m, top speed %.2f m/s, top spin %.2f rad/s; contacts %d, push force %.2f kN; parts %d → %d",
    tag, mass, secs, len(moved.x, moved.y, moved.z), maxv, maxw, nmax, fmax, #i0.parts, #i1.parts)
  return len(moved.x, moved.y, moved.z), maxv, mass
end
local function grav_on(vn, force, secs)
  local TB = findScript("tool_belt")
  do -- 7 m off its side, on the ground
    local b = home()
    local A = astro()
    local c = rel(b, assembly.info(vn).com)
    local up = unit(c)
    local d = sub(rel(b, A), c)
    d = sub(d, scl(up, dot(d, up)))
    if len(d.x, d.y, d.z) < 0.1 then d = cross(up, { x = 0, y = 0, z = 1 }) end
    d = unit(d)
    local su = unit({ x = c.x + d.x * 7, y = c.y + d.y * 7, z = c.z + d.z * 7 })
    local gr = ground_r(b, su.x, su.y, su.z, b.radius * 1.3) or len(c.x, c.y, c.z)
    A.x, A.y, A.z = b.x + su.x * (gr + 1.1), b.y + su.y * (gr + 1.1), b.z + su.z * (gr + 1.1)
    A.vx, A.vy, A.vz = 0, 0, 0
    wait(1.5)
  end
  local H = findScript("item_hand")
  local okh, why = H.hold("gravgun")
  wait(1.0)
  F("gravity gun in hand: %s %s tool %s gate %s", tostring(okh), tostring(why), tostring(TB.toolId()), tostring(TB.gate))
  TB.params.grav_force = force
  local function aim()
    local A = astro()
    local up = unit(rel(home(), A))
    local ox, oy, oz = A.x + up.x * 1.4, A.y + up.y * 1.4, A.z + up.z * 1.4
    local c = assembly.info(vn).com
    return ox, oy, oz, c.x - ox, c.y - oy, c.z - oz
  end
  TB.sim = { btn = { [0] = true }, aim = aim }
  local b = home()
  local c0 = rel(b, assembly.info(vn).com)
  local up = unit(c0)
  local t0, smax, rise = time, 0, 0
  while time - t0 < secs do
    yield()
    smax = math.max(smax, TB.strain or 0)
    local c = rel(home(), assembly.info(vn).com)
    rise = math.max(rise, dot(sub(c, c0), up))
  end
  local c1 = rel(home(), assembly.info(vn).com)
  local mv = sub(c1, c0)
  TB.sim = nil
  wait(1.5)
  F("gravity gun at %.1f: strain peak %.2f, rose %.2f m, moved %.2f m in %.0f s", force, smax, rise, len(mv.x, mv.y, mv.z), secs)
  return rise, len(mv.x, mv.y, mv.z)
end

local function run_feelpush()
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then F("RESULT push light: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  exit_craft()
  local pw = findScript("planet_walker")
  F("walker mass %s (param %s)", tostring(astro():getcomponent("RigidBody").mass), tostring(pw.params.mass))
  local dB, vB, m = shove(vn, "light B (capped push)", 6)
  wait(3)
  pw.pushOff = true
  astro():getcomponent("RigidBody").mass = 1.0
  local dA, vA = shove(vn, "light A (old: 1 t, unlimited)", 6)
  pw.pushOff = false
  astro():getcomponent("RigidBody").mass = pw.params.mass
  F("RESULT push light: %s — %.2f t rover moved %.2f m (top %.2f m/s) before, %.2f m (top %.2f m/s) now",
    (dB > 0.05 and dB < dA * 0.3) and "PASS" or "FAIL", m, dA, vA, dB, vB)
  local r0, m0 = grav_on(vn, 4.0, 4)
  wait(2)
  local r1, m1 = grav_on(vn, 5.2, 4)
  F("RESULT gravity gun: rover rose %.2f / moved %.2f m at 4.0, rose %.2f / moved %.2f m at 5.2", r0, m0, r1, m1)
end

local function run_feelheavy()
  local vc = launch_via_builder(rocket_2stage(), "runway", 9)
  if not vc then F("RESULT push heavy: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(3)
  exit_craft()
  local pw = findScript("planet_walker")
  pw.pushOff = true
  astro():getcomponent("RigidBody").mass = 1.0
  local dA, vA = shove(vn, "heavy A (old: 1 t, unlimited)", 6)
  pw.pushOff = false
  astro():getcomponent("RigidBody").mass = pw.params.mass
  wait(3)
  local dB, vB, m = shove(vn, "heavy B (capped push)", 6)
  F("RESULT push heavy: %s — %.1f t rocket moved %.3f m (top %.3f m/s) before, %.3f m (top %.3f m/s) now",
    (dB < 0.1 and vB < 0.1) and "PASS" or "FAIL", m, dA, vA, dB, vB)
end

-- ── the plant marks ─────────────────────────────────────────────────────────
local function run_feelplants()
  local ff = findScript("flora_field")
  local t0 = time
  local seen = {}
  while time - t0 < 40 do
    wait(1.0)
    local orbs, vis, alpha = 0, 0, 0
    for _, n in ipairs(findAll and findAll("Rare Orb") or {}) do
      orbs = orbs + 1
      if n.visible ~= false then vis = vis + 1 end
      local ok, m = pcall(n.material, n)
      if ok and m and m.alpha then alpha = math.max(alpha, m.alpha) end
    end
    local motes, mvis = 0, 0
    for _, n in ipairs(findAll and findAll("Flora Mote") or {}) do
      motes = motes + 1
      if n.visible ~= false then mvis = mvis + 1 end
    end
    F("plants t %.0f: rare orbs %d (%d visible, alpha max %.2f), motes %d (%d visible), markAlpha %s",
      time - t0, orbs, vis, alpha, motes, mvis, tostring(ff and ff.markAlpha ~= nil))
    seen[#seen + 1] = { orbs = orbs, vis = vis, mvis = mvis }
  end
  local last = seen[#seen]
  F("RESULT plant marks: %s — after 40 s %d of %d rare orbs and %d motes still shown",
    (last.orbs > 0 and last.vis == 0 and last.mvis == 0) and "PASS" or ((last.orbs == 0) and "INCONCLUSIVE" or "FAIL"),
    last.vis, last.orbs, last.mvis)
end

