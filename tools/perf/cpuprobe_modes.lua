-- ── cpu probe (tools/perf/cpuprobe.sh; Ty's 2026-11-12b playtest) ──────────
-- Spliced into a copy of perfbench.lua after soakprobe_modes.lua (its RT
-- sampler: a row every soak_every s of frame times, script ms, counts, Lua
-- memory). cpuprobe.sh samples the engine's threads from outside (thrmon.py).
--   bikesoak  the player's save (cpuprobe.sh USERSRC=dir) or a new one: the
--             craft with a saddle (the bike) nearest the crew, the crew put
--             beside it and boarded (F), driven away from the base, a turn
--             every 40 s so the line wanders, `cp_secs` s; a new save without
--             a bike drives the 6-part rover off the runway instead
--   sprint    (Ty: "running at the base, the animation and the FOV jitter")
--             the crew sprints across the base in 6 headings, 4 s each and
--             back; every update frame: moveSpeed, the camera's fovKick, the
--             walker's contact/snap/pop/slope, wall cut, push clamp, bumps,
--             steps, wading depth, impacts. `CP SPRINT` rows per heading.
--   idle      stand where the save left the crew, `cp_secs` s (RT rows).
CP = {}
-- after each RT row: the bodies the engine timed in that window (ms/frame),
-- and the physics ticks a frame (a slow frame steps more ticks: the spiral)
function CP.bodies_tick()
  local w = RT.win - 1
  if w < 0 or CP.bw == w then return end
  CP.bw = w
  local r = RECS[string.format("rt_w%02d", w)]
  if not r then return end
  local n = math.max(#r.dts, 1)
  P("CP bodies w%02d: %s | ticks/frame %.2f max %d dropped %d", w, fmtk(topk(r.bod or {}, 8, n)), (r.tk or 0) / math.max(r.tf or 1, 1), r.tkmax or 0, (CP_DROP or 0) - (CP.drop0 or 0))
  CP.drop0 = CP_DROP or 0
end
function CP.bike_find()
  local best, bd = nil, 1e18
  local a = astro()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid then
      local nm = tostring(v.craftName)
      local saddle = false
      for _, n in ipairs(v.node:children() or {}) do
        if tostring(n.name):find("Saddle") then saddle = true break end
      end
      local d = a and len(v.node.x - a.x, v.node.y - a.y, v.node.z - a.z) or 0
      P("CP craft %s saddle %s %.0f m", nm, tostring(saddle), d)
      if saddle and d < bd then best, bd = v, d end
    end
  end
  return best, bd
end
-- what a stuck craft is up against: its pose, its wheels, the ground under
-- it (made yet?), and the named nodes within 12 m; a picture (first 3 times)
function CP.stuck_dump(vc, i1)
  CP.nstuck = (CP.nstuck or 0) + 1
  local b = home()
  local c = i1.com
  local up = unit(sub(c, b))
  local cu = i1.up and dot(i1.up, up) or -9
  local q = terrain.query(c.x, c.y, c.z)
  local rd = terrain.ready and terrain.ready(c.x, c.y, c.z, 6) or "?"
  local R2 = vc.R2 or {}
  P("CP stuck at body %s rel (%.2f, %.2f, %.2f) world (%.2f, %.2f, %.2f) body at (%.2f, %.2f, %.2f) game time %.1f", tostring(b.name), c.x - b.x, c.y - b.y, c.z - b.z, c.x, c.y, c.z, b.x, b.y, b.z, space.time and space.time() or -1)
  P("CP stuck dump: up.dot %.2f, ground d %.2f ready %s, why %s onWheels %s driving %s, parts %s", cu, q or -99, tostring(rd),
    tostring(R2.why), tostring(R2.onWheels), tostring(R2.driving), tostring(vc.partUids and #vc.partUids() or "?"))
  local near = {}
  local root = find(space.dominant(c.x, c.y, c.z))
  for _, n in ipairs((root and root:children()) or {}) do
    if n.valid ~= false and n.name and n.name ~= vc.node.name then
      local d = len(n.x - c.x, n.y - c.y, n.z - c.z)
      if d < 12 then near[#near + 1] = string.format("%s %.1f", tostring(n.name), d) end
    end
  end
  P("CP stuck near (%d): %s", #near, table.concat(near, ", ", 1, math.min(#near, 20)))
  if CP.nstuck <= 3 and CP.shot then CP.shot(string.format("stuck%d", CP.nstuck)) end
end
function CP.drive(vc, secs)
  local vn = vc.node
  local u = base_frame()
  local t0 = time
  RT.phase = "drive"
  key_down("w")
  while time - t0 < secs do
    yield()
    CP.bodies_tick()
    if not vn.valid then P("CP craft gone"); break end
    local t = time - t0
    local i1 = assembly.info(vn)
    if i1 then
      local Rh = unit(sub(i1.com, home()))
      local away = sub(Rh, scl(u, dot(Rh, u)))
      local v = i1.vel
      local vh = sub(v, scl(Rh, dot(v, Rh)))
      local want = nil
      if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
        away = unit(away)
        -- the way out, turned ±50° slowly so the line wanders over new ground
        local th = math.rad(50) * math.sin(t / 40)
        local sd = cross(Rh, away)
        local aim = { x = away.x * math.cos(th) + sd.x * math.sin(th), y = away.y * math.cos(th) + sd.y * math.sin(th), z = away.z * math.cos(th) + sd.z * math.sin(th) }
        local sn = dot(cross(unit(vh), aim), Rh)
        local cs = dot(unit(vh), aim)
        if cs < 0.97 then want = sn >= 0 and "a" or "d" end
      end
      for _, k in ipairs({ "a", "d" }) do
        if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
      end
      -- stuck (a cliff, the sea): back up and turn
      if math.floor(t / 15) ~= math.floor((t - dt) / 15) then
        CP.track = CP.track or {}
        local p = sub(i1.com, home())
        local last = CP.track.p
        if last and len(p.x - last.x, p.y - last.y, p.z - last.z) < 15 then
          P("CP stuck at t=%.0f: reversing", t)
          CP.stuck_dump(vc, i1)
          release_all(); key_down("s"); key_down("a"); wait(3); release_all(); key_down("w")
        end
        CP.track.p = p
        P("CP track t=%.0f speed %.1f from base %.0f m", t, len(v.x, v.y, v.z), rt_from_base and rt_from_base(p) or -1)
      end
    end
  end
  release_all()
end
function CP.bikesoak()
  wait_ready(150)
  sk_quiet()
  sk_wrap()
  RT.w0 = W()
  RT.next_t = W() + params.soak_every
  sc_begin("rt_w00")
  RT.phase = "start"
  wait(3)
  local vc, d = CP.bike_find()
  if vc then
    P("CP bike %s at %.0f m: boarding", tostring(vc.craftName), d)
    local a = astro()
    local vn = vc.node
    local b = home()
    local up = unit(sub(vn, b))
    local i0 = assembly.info(vn)
    local side = i0 and i0.right or cross(up, { x = 0, y = 0, z = 1 })
    a.x, a.y, a.z = vn.x + side.x * 1.6 + up.x * 0.8, vn.y + side.y * 1.6 + up.y * 0.8, vn.z + side.z * 1.6 + up.z * 0.8
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(2)
    tap("f"); wait(1.0)
    wait_for(function() return vc.piloting end, 6, "aboard the bike")
    P("CP aboard %s piloting %s", tostring(vc.crewAboard), tostring(vc.piloting))
    if not vc.piloting then vc = nil end
  end
  if not vc then
    P("CP no bike: the 6-part rover from the runway")
    vc = launch_via_builder(ROVER, "runway", 6)
    sk_quiet()
    if vc then vc.releaseClamps(); wait(1) end
  end
  if vc then CP.drive(vc, params.cp_secs) end
  RT.phase = "end"
  rt_sample()
  RT.next_t = nil
  P("CP end")
end
function CP.idle(ready)
  if not ready then wait_ready(150) end
  sk_quiet()
  sk_wrap()
  RT.w0 = W()
  RT.next_t = W() + params.soak_every
  sc_begin("rt_w00")
  RT.phase = "idle"
  local t0 = time
  while time - t0 < params.cp_secs do yield(); CP.bodies_tick() end
  rt_sample()
  RT.next_t = nil
  P("CP end")
end

-- ── sprint ──────────────────────────────────────────────────────────────────
function CP.sp_sample(list, pw, pc, A, b)
  local ws, ps, vs, st = pw.wallState or {}, pw.pushState or {}, pw.vertState or {}, pw.stepState or {}
  local cn = pc.node
  local camd = (cn and A) and len(cn.worldPos.x - A.x, cn.worldPos.y - A.y, cn.worldPos.z - A.z) or 0
  list[#list + 1] = { t = time, dt = dt, spd = pw.moveSpeed or 0, fov = math.deg(pc.fovKick or 0), c = vs.contact and 1 or 0, snap = vs.snap or 0,
    pop = vs.pop or 0, slope = vs.slope or 0, cut = ws.cut or 0, pressed = ws.pressed and 1 or 0, clamp = ps.clamp or 0, bump = pw.bumped or 0,
    steps = st.n or 0, wade = pw.wadeDepth or -1, wadeE = pw.wadeEased or 0, imp = pw.impactSeq or 0, impv = pw.impactSpeed or 0, fall = pw.fallSpeed or 0,
    gr = pw.grounded and 1 or 0, ck = vs.climbk or 1, slide = pw.sliding and 1 or 0, enc = pw.encumbrance or 0, camd = camd, ff = pw.fieldFloor and 1 or 0 }
end
function CP.sp_summary(tag, list, run)
  local n, sum, sum2, mn, under, cutf, clampf, bumpf, snapf, popf, wadef, ncf, fallf = 0, 0, 0, 1e9, 0, 0, 0, 0, 0, 0, 0, 0, 0
  local fd2, fmax, cd2 = 0, 0, 0
  local imp0, steps0 = list[1] and list[1].imp or 0, list[1] and list[1].steps or 0
  for i, s in ipairs(list) do
    n = n + 1
    sum, sum2 = sum + s.spd, sum2 + s.spd * s.spd
    mn = math.min(mn, s.spd)
    if s.spd < run * 0.95 then under = under + 1 end
    if s.cut > 0.01 then cutf = cutf + 1 end
    if s.clamp > 0.01 then clampf = clampf + 1 end
    if s.bump > 0 then bumpf = bumpf + 1 end
    if s.snap > 0 then snapf = snapf + 1 end
    if s.pop > 0.01 then popf = popf + 1 end
    if s.wade > 0 then wadef = wadef + 1 end
    if i > 1 and ((s.wade > 0.12) ~= (list[i - 1].wade > 0.12)) then CP.flips = (CP.flips or 0) + 1 end
    if s.c == 0 then ncf = ncf + 1 end
    if s.fall > 0.3 then fallf = fallf + 1 end
    if s.ck < 0.999 then CP.climbf = (CP.climbf or 0) + 1 end
    if i > 1 and i < #list then
      local d2 = math.abs(list[i + 1].fov - 2 * s.fov + list[i - 1].fov)
      fd2 = fd2 + d2 * d2
      fmax = math.max(fmax, d2)
      local c2 = math.abs(list[i + 1].camd - 2 * s.camd + list[i - 1].camd)
      cd2 = cd2 + c2 * c2
    end
  end
  if n == 0 then P("CP SPRINT %s: no frames", tag) return end
  local flips = CP.flips or 0; CP.flips = 0
  local climbf = CP.climbf or 0; CP.climbf = 0
  local mean = sum / n
  local sd = math.sqrt(math.max(0, sum2 / n - mean * mean))
  local fovs = {}
  for _, s in ipairs(list) do fovs[#fovs + 1] = s.fov end
  table.sort(fovs)
  P("CP SPRINT %s: %d fr | speed mean %.2f sd %.3f min %.2f, under 95%% of %.1f on %d | fov %.2f-%.2f deg, d2 rms %.4f max %.4f | camd d2 rms %.4f | frames with: wall cut %d, push clamp %d, bump %d, snap %d, pop %d, climb cut %d, wade %d (flips %d, eased max %.2f), no contact %d, falling %d | impacts %d steps %d | enc %.2f",
    tag, n, mean, sd, mn, run, under, fovs[1], fovs[#fovs], math.sqrt(fd2 / math.max(1, n - 2)), fmax, math.sqrt(cd2 / math.max(1, n - 2)),
    cutf, clampf, bumpf, snapf, popf, climbf, wadef, flips, (function() local m = 0; for _, x in ipairs(list) do m = math.max(m, x.wadeE) end; return m end)(), ncf, fallf, (list[#list].imp - imp0), (list[#list].steps - steps0), list[1].enc)
  if (params.cp_frames or 0) > 0 then
    for i, s in ipairs(list) do
      if i > 90 then break end
      P("CP F %s %3d dt %.1f spd %.3f ck %.2f fov %.3f c %d gr %d snap %.2f pop %.2f slope %.2f cut %.2f clamp %.2f bump %d wade %.2f fall %.2f imp %d %.2f camd %.3f ff %d",
        tag, i, s.dt * 1000, s.spd, s.ck, s.fov, s.c, s.gr, s.snap, s.pop, s.slope, s.cut, s.clamp, s.bump, s.wade, s.fall, s.imp, s.impv, s.camd, s.ff)
    end
  end
end
function CP.to_base(tag)
  -- on the base's own graded ground near its centre, in the open (no roof
  -- over it, nothing within 6 m at chest height in four directions, the
  -- ground within 1.5 m of the base's sphere): a player's save can leave the
  -- crew anywhere (Ty's slot1 has them in a pit 27 m under the sea)
  if (params.cp_atbase or 1) <= 0 then return end
  local u, t1b, t2b = base_frame()
  local R = len(save.get("base.x"), save.get("base.y"), save.get("base.z"))
  local bb = home()
  for _, d in ipairs({ 40, 55, 70, 30, 85 }) do
    for k = 0, 11 do
      local ang = math.rad(k * 30 + 15)
      local t = unit({ x = t1b.x * math.cos(ang) + t2b.x * math.sin(ang), y = t1b.y * math.cos(ang) + t2b.y * math.sin(ang), z = t1b.z * math.cos(ang) + t2b.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local g = ground_r(bb, dir.x, dir.y, dir.z, R + 60)
      if g and math.abs(g - R) < 1.5 then
        local p = { x = bb.x + dir.x * (g + 1.2), y = bb.y + dir.y * (g + 1.2), z = bb.z + dir.z * (g + 1.2) }
        local open = raycast(p.x, p.y, p.z, dir.x, dir.y, dir.z, 25) == nil
        local s2 = cross(dir, t)
        for _, h in ipairs({ t, s2, scl(t, -1), scl(s2, -1) }) do
          if open and raycast(p.x, p.y, p.z, h.x, h.y, h.z, 6) ~= nil then open = false end
        end
        if open then
          local a = astro()
          a.x, a.y, a.z = p.x, p.y, p.z
          a.vx, a.vy, a.vz = 0, 0, 0
          P("CP %s put in the open on the base ground: %d m out, bearing %d, r %.1f (sea %s)", tag, d, k * 30 + 15, g,
            tostring(findScript("climate") and findScript("climate").seaRadius and findScript("climate").seaRadius(bb.name) or "?"))
          wait(2.0)
          return
        end
      end
    end
  end
  P("CP %s: no open spot on the base ground", tag)
end
function CP.sprint()
  wait_ready(150)
  wait(3)
  clear_weather()
  local pw, pc = findScript("planet_walker"), findScript("planet_camera")
  pc.firstPerson = false
  CP.to_base("SPRINT")
  local A = astro()
  local b = home()
  local start = sub(A, b)
  P("CP SPRINT crew at r %.1f", len(start.x, start.y, start.z))
  local run = (pw.params and pw.params.run) or 8
  local u0 = unit(start)
  local t1 = unit(cross(u0, { x = 0, y = 0, z = 1 }))
  local t2 = cross(u0, t1)
  P("CP SPRINT start %.0f m from the base centre", rt_from_base and rt_from_base(start) or -1)
  for k = 0, (params.cp_heads or 6) - 1 do
    for leg = 0, 1 do
      local bb = home()
      local Ac = astro()
      local up = unit(sub(Ac, bb))
      local ang = math.rad(k * 60 + leg * 180)
      local d = { x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) }
      d = unit(sub(d, scl(up, dot(d, up))))
      pc.face(d.x, d.y, d.z, -0.2)
      wait(0.6)
      pw.steer(1, 0, true)
      wait(1.2)
      local list = {}
      local t0 = time
      while time - t0 < (params.cp_runsecs or 4) do
        yield()
        local a2, b2 = astro(), home()
        if a2 and b2 then CP.sp_sample(list, pw, pc, a2, b2) end
      end
      pw.steer(0, 0, false)
      CP.sp_summary(string.format("h%d%s", k, leg == 0 and "out" or "back"), list, run)
      wait(0.8)
    end
  end
  pw.steer(nil)
  P("CP SPRINT done")
end

-- ── shadow (Ty 11-12b: "odd shadow patterns on astronauts at certain sun
-- angles"): the crew standing in the open, the key light held (env.keyOverride)
-- at elevations 8-60 deg from two sides, a close shot from the side; each with
-- the sun map at the game's own size and at cp_map (4096). Pictures:
-- save/user/shadowshots/<map>_<elev>_<az>.png ──────────────────────────────
function CP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://shadowshots/" .. nm .. ".png", bytes); P("CP SHOT %s", nm) else P("CP SHOT %s failed %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function CP.shadow()
  wait_ready(150)
  wait(4)
  clear_weather()
  local pc, pw = findScript("planet_camera"), findScript("planet_walker")
  pc.firstPerson = false
  CP.to_base("SHADOW")
  local A = astro()
  local b = home()
  local up = unit(sub(A, b))
  local t1 = unit(cross(up, { x = 0, y = 0, z = 1 }))
  local t2 = cross(up, t1)
  -- the crew faces t1; the camera stands off to its side and a little front
  pc.face(t1.x, t1.y, t1.z, 0)
  wait(1.0)
  pc.setShot(function()
    local a, bb = astro(), home()
    local u = unit(sub(a, bb))
    local c = { x = a.x + t2.x * 2.6 + t1.x * 1.2 + u.x * 0.5, y = a.y + t2.y * 2.6 + t1.y * 1.2 + u.y * 0.5, z = a.z + t2.z * 2.6 + t1.z * 1.2 + u.z * 0.5 }
    return c.x, c.y, c.z, a.x + u.x * 0.2, a.y + u.y * 0.2, a.z + u.z * 0.2, u.x, u.y, u.z
  end, 0.01, { clear = true })
  wait(1.0)
  local L = find("Lighting"):getcomponent("Light")
  local E = env or L
  local gmap = E.shadowMapSize
  P("CP shadow: map %s dist %s soft %s", tostring(gmap), tostring(L.shadowDistance), tostring(E.shadowSoftness))
  for _, map in ipairs({ gmap, params.cp_map or 4096 }) do
    E.shadowMapSize = map
    wait(0.5)
    for _, el in ipairs({ 8, 18, 35, 60 }) do
      for _, az in ipairs({ 30, 150, 260 }) do
        local e, z = math.rad(el), math.rad(az)
        -- direction the light travels (toward the ground)
        local hx = t1.x * math.cos(z) + t2.x * math.sin(z)
        local hy = t1.y * math.cos(z) + t2.y * math.sin(z)
        local hz = t1.z * math.cos(z) + t2.z * math.sin(z)
        local tx, ty, tz = hx * math.cos(e) + up.x * math.sin(e), hy * math.cos(e) + up.y * math.sin(e), hz * math.cos(e) + up.z * math.sin(e)
        -- a held directional sun, as scenario_run's time hold does (Stars
        -- mode off; the direction points TOWARD the sun)
        L.stars = false
        L.directionX, L.directionY, L.directionZ = tx, ty, tz
        L.intensity, L.colorR, L.colorG, L.colorB = 3.0, 1.0, 0.97, 0.92
        local AT = findScript("atmosphere")
        if AT then AT.sunUpOverride = math.sin(e) end
        wait(0.4)
        CP.shot(string.format("m%d_e%02d_a%03d", map, el, az))
      end
    end
  end
  L.stars = true
  E.shadowMapSize = gmap
  pc.clearShot(0.1)
  P("CP shadow done")
end

-- ── ruinidle: the player's claimed ruin (bases.1, the save's first claimed
-- base), the crew put down at it and left standing `cp_secs` s (RT rows) ───
function CP.ruinidle()
  wait_ready(150)
  local rec = save.get("bases.1")
  local b = rec and space.body(rec.b or "")
  local a = astro()
  if b and a and rec.x then
    local l = len(rec.x, rec.y, rec.z)
    local u = { x = rec.x / l, y = rec.y / l, z = rec.z / l }
    local g = ground_r(b, u.x, u.y, u.z, l + 200) or l
    a.x, a.y, a.z = b.x + u.x * (g + 2.0) + 6, b.y + u.y * (g + 2.0), b.z + u.z * (g + 2.0)
    a.vx, a.vy, a.vz = 0, 0, 0
    P("CP ruin %s: put down (r %.0f ground %.0f)", tostring(rec.n), l, g)
  else
    P("CP ruin: no bases.1 in this save")
  end
  return CP.idle(true)
end
