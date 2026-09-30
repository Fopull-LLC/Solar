-- FPS PROBE — what a real save costs to play, measured from inside it.
--
-- `floptle run` steps on a fixed clock and draws nothing, and `floptle shot`
-- times one frame's GPU passes; neither says how many frames a second a player
-- gets in a window. This rides the game's own new-save path (the same moves as
-- `loop_probe`: wipe the slot's terrain, pick the slot, store the seed, load the
-- system) and then reports, every few seconds, the real frame rate, the engine's
-- cost buckets and the counts that explain them.
--
-- It is a TEST FIXTURE. `scenes/fps_probe.ron` is the only thing that names it,
-- and it only reports under `floptle play` / the editor, where frames are real.

defaults = {
  --- Which slot to run in. NOT slot1 — the rig wipes the slot's terrain.
  slot = 9,
  --- Galaxy seed. 1911564384 rolls a home world with a sea and flora.
  seed = 1911564384,
  --- Seconds between reports.
  --@range 1 30
  every = 5.0,
  --- Quit after this many seconds (0 = never).
  quitAfter = 0,
  --- Turn vsync off, so the report is the frame's real cost rather than the
  --- nearest multiple of the display's refresh interval.
  noVsync = 0,
  --- Seconds of play before the A/B experiments start (0 = no experiments).
  --- Each experiment holds for `every` seconds and is reported by name, so a
  --- report line says what one feature costs on this world, in this window.
  experimentsAt = 0,
  --- 1 = once the world is ready, stand the crew a few metres inland of the
  --- nearest beach (so a `shot --frames --turn` sequence sees the water).
  shore = 0,
  --- Sets every sea's `debugView` shader knob (1 = red shore, green depth).
  oceanDebug = 0,
  --- 1 = hide every sea SURFACE node (diagnostics: what else is drawing?).
  hideSea = 0,
  --- 1 = after the beach move, drop the crew into the sea and log how they
  --- float (depth and radial speed, once a second for 10 s).
  swimTest = 0,
  --- 1 = once the world is ready, walk the crew through a fixed routine with no
  --- input (forward, strafe right, sprint, stop, back-left diagonal, stand) and
  --- log, four times a second, where the body faces against where it moves,
  --- the Base animation state and how high the camera sits over the crew.
  walkTest = 0,
  --- 1 = once the world is ready, stand the crew on the nearest slope of 15° to
  --- 32°, walk them a step along it (so they face across it, feet up and down
  --- the fall line) and stand; log, four times a second, the slope and how far
  --- each sole is off the ground under it.
  slopeTest = 0,
}

-- Each entry is applied in lateUpdate — after atmosphere.lua has written its
-- fog for the frame — and undone by the next one, so each row is baseline plus
-- exactly one change unless it says otherwise.
local EXPERIMENTS = {
  -- Engine card 0299: a runtime render-scale switch from 1.0 must not stall.
  { "scale 1.0",      nil, function(on) if on then app.setRenderScale(1.0) end end },
  { "switch to 0.6",  nil, function(on) if on then app.setRenderScale(0.6) end end },
  { "back to 1.0",    nil, function(on) if on then app.setRenderScale(1.0) end end },
  { "switch to 0.8",  nil, function(on) if on then app.setRenderScale(0.8) end end },
}
local exp_i, exp_t0 = 0, nil
local lit, snap


local jumped = false
local frames, acc, worst = 0, 0, 0
local t_report = 0

-- Walk the crew to the nearest beach once the world is up.
local shored, ready_at = false, nil
local dumped = false
local jump_last = nil
local swim_body, swim_sea, swim_t0, swim_next = nil, 0, nil, 0
function to_shore()
  if shored then return end
  local gm = findScript("game_manager")
  if not gm or gm.loading ~= false then return end
  ready_at = ready_at or time
  if time - ready_at < 4 then return end
  shored = true
  local a = find("Astronaut")
  local cl = findScript("climate")
  local d = a and space.dominant(a.x, a.y, a.z)
  local b = d and space.body(d)
  local sea = cl and d and cl.seaRadius(d) or 0
  if not (a and b and sea > 0) then print("fps probe: no sea here"); return end
  local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  ux, uy, uz = ux / ul, uy / ul, uz / ul
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = math.sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  local t2x, t2y, t2z = uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
  local function dir(arc, ang)
    local k = math.tan(arc / sea)
    local x = ux + (t1x * math.cos(ang) + t2x * math.sin(ang)) * k
    local y = uy + (t1y * math.cos(ang) + t2y * math.sin(ang)) * k
    local z = uz + (t1z * math.cos(ang) + t2z * math.sin(ang)) * k
    local m = math.sqrt(x * x + y * y + z * z)
    return x / m, y / m, z / m
  end
  local best_arc, best_ang = 1e9, nil
  for i = 0, 23 do
    local ang = i * math.pi / 12
    for arc = 6, 240, 3 do
      if arc >= best_arc then break end
      local x, y, z = dir(arc, ang)
      local q = terrain.query(b.x + x * sea, b.y + y * sea, b.z + z * sea)
      if q and q > 0.3 then best_arc, best_ang = arc, ang; break end
    end
  end
  if not best_ang then print("fps probe: no beach within 240 m"); return end
  local x, y, z = dir(math.max(0, best_arc - 7), best_ang)
  a.x, a.y, a.z = b.x + x * (sea + 6), b.y + y * (sea + 6), b.z + z * (sea + 6)
  a.vx, a.vy, a.vz = 0, 0, 0
  -- Face the water: from the new spot toward the beach point.
  local bx, by, bz = dir(best_arc + 10, best_ang)
  local pc = findScript("planet_camera")
  if pc and pc.face then pc.face(bx - x, by - y, bz - z, -0.12) end
  print(string.format("fps probe: crew moved to a beach %d m away", best_arc))
  if (params.swimTest or 0) > 0 then
    local wx, wy, wz
    for arc = best_arc + 6, best_arc + 200, 2 do
      local x2, y2, z2 = dir(arc, best_ang)
      local q = terrain.query(b.x + x2 * (sea - 1.2), b.y + y2 * (sea - 1.2), b.z + z2 * (sea - 1.2))
      if q and q > 0.8 then wx, wy, wz = x2, y2, z2; break end
    end
    if not wx then print("fps probe: no swimmable water on that bearing"); return end
    a.x, a.y, a.z = b.x + wx * (sea - 1.2), b.y + wy * (sea - 1.2), b.z + wz * (sea - 1.2)
    local fl = terrain.query(a.x, a.y, a.z)
    print(string.format("fps probe: swim drop point is %.1f m from the seabed", fl or -1))
    swim_body, swim_sea, swim_t0 = b, sea, time
  end
end

-- The walk routine: { from, to, forward, right, sprint, name, jump } in seconds
-- after the world is ready; past the end the keys are handed back.
local ROUTINE = {
  { 0, 3, 1, 0, false, "forward" },
  { 3, 6, 0, 1, false, "strafe right" },
  { 6, 9, 0, 1, true, "sprint right" },
  { 9, 10.5, 0, 0, false, "stop" },
  { 10.5, 12, 0, 0, false, "jump", true },
  { 12, 15, -0.7, -0.7, false, "back-left" },
  { 15, 18, 0, 0, false, "stand" },
}
local walk_t0, walk_next, walk_leg = nil, 0, nil
local function walk_test()
  local gm = findScript("game_manager")
  if not gm or gm.loading ~= false then return end
  ready_at = ready_at or time
  if time - ready_at < 4 then return end
  if not walk_t0 then
    walk_t0 = time
    -- Close and held still, so a picture shows the gait rather than a speck:
    -- the strafes are then profiles.
    local pc = findScript("planet_camera")
    if pc then pc.params.distance, pc.params.follow_yaw = 4.5, 0 end
  end
  local t = time - walk_t0
  local w = findScript("planet_walker")
  local a = find("Astronaut")
  if not (w and a) then return end
  local leg
  for _, r in ipairs(ROUTINE) do if t >= r[1] and t < r[2] then leg = r end end
  if leg ~= walk_leg then
    walk_leg = leg
    if leg then
      w.steer(leg[3], leg[4], leg[5], leg[7])
      print(string.format("walk test @%.1f: %s", t, leg[6]))
    else
      w.steer(nil)
      print("walk test: done")
      if (params.quitAfter or 0) > 0 then app.quit() end
    end
  end
  if not leg or time < walk_next then return end
  walk_next = time + 0.25
  local up = a.up
  local v = a.vel
  local tv = v - up * v:dot(up)
  local m
  for _, c in ipairs(a:children()) do if c.name == "AstroModel" then m = c end end
  -- The model faces its own +Z; `pos` is parent-local, so both ends by toWorld.
  local face = m and (m:toWorld(vec3(0, 0, 1)) - m:toWorld(vec3(0, 0, 0))) or vec3(0, 0, 0)
  face = face - up * face:dot(up)
  local err = 0
  if tv:length() > 1 and face:length() > 0 then
    err = math.deg(math.atan2(face:cross(tv):dot(up), face:dot(tv)))
  end
  local pc = findScript("planet_camera")
  local off = pc and (vec3(pc.cam_x, pc.cam_y, pc.cam_z) - a.pos) or vec3(0, 0, 0)
  local ch, cd = off:dot(up), off:length()
  local an = m and m:animator()
  print(string.format("walk test @%5.2f %-12s speed %5.2f facing-vs-motion %6.1f deg  base %-5s cam up %.3f away %.2f look-up %.2f grounded %s",
    t, leg[6], tv:length(), err, tostring(an and an:state("Base")), ch, cd, find("Camera 1").forward:dot(up), tostring(w.grounded)))
end

-- The slope routine (see `slopeTest`).
local slope_t0, slope_next, slope_dir = nil, 0, nil
local function slope_test()
  local gm = findScript("game_manager")
  if not gm or gm.loading ~= false then return end
  ready_at = ready_at or time
  if time - ready_at < 4 then return end
  local a = find("Astronaut")
  local w = findScript("planet_walker")
  local pc = findScript("planet_camera")
  if not (a and w) then return end
  local up = a.up
  if not slope_t0 then
    slope_t0 = time
    -- Rings round the crew, looking down from 40 m up for ground of the right tilt.
    local t1 = up:cross(math.abs(up.y) < 0.9 and vec3(0, 1, 0) or vec3(1, 0, 0)):normalized()
    local t2 = up:cross(t1)
    local found
    for r = 4, 120, 4 do
      for i = 0, 23 do
        local ang = i * math.pi / 12
        local o = a.pos + (t1 * math.cos(ang) + t2 * math.sin(ang)) * r + up * 40
        local hit = raycast(o, -up, 90, a)
        if hit then
          local n = vec3(hit.nx, hit.ny, hit.nz)
          local tilt = math.deg(math.acos(math.clamp(n:dot(up), -1, 1)))
          if tilt > 15 and tilt < 32 then found = { hit = hit, n = n, tilt = tilt, r = r }; break end
        end
      end
      if found then break end
    end
    if not found then print("slope test: no slope within 120 m"); return end
    local h = found.hit
    a.pos = vec3(h.x, h.y, h.z) + up * 1.3
    a.vx, a.vy, a.vz = 0, 0, 0
    -- Along the contour: across the fall line, so the feet sit up and down it.
    local fall = (found.n - up * found.n:dot(up)):normalized()
    slope_dir = up:cross(fall)
    if pc then
      pc.params.distance, pc.params.follow_yaw = 4.0, 0
      pc.face(slope_dir.x, slope_dir.y, slope_dir.z, -0.15)
    end
    print(string.format("slope test: a %.0f° slope %d m away", found.tilt, found.r))
    return
  end
  local t = time - slope_t0
  if t < 1.5 then w.steer(0, 0) elseif t < 2.0 then w.steer(0.4, 0) elseif t < 12 then w.steer(0, 0)
  else w.steer(nil) end
  if time < slope_next or t > 12 then return end
  slope_next = time + 0.25
  local m
  for _, c in ipairs(a:children()) do if c.name == "AstroModel" then m = c end end
  local an = m and m:animator()
  if not an then return end
  local out = {}
  for _, side in ipairs({ "Left", "Right" }) do
    local p = an:boneWorld("Foot." .. side)
    local hit = p and raycast(p + up * 0.6, -up, 2.0, a)
    out[#out + 1] = hit and string.format("%s sole %+.3f", side, hit.distance - 0.6 - 0.072) or (side .. " ?")
  end
  local hit = raycast(a.pos, -up, 3.0, a)
  local tilt = hit and math.deg(math.acos(math.clamp(vec3(hit.nx, hit.ny, hit.nz):dot(up), -1, 1))) or -1
  print(string.format("slope test @%5.2f tilt %4.1f  %s  grounded %s", t, tilt, table.concat(out, "  "),
    tostring(w.grounded)))
end

function update(node, dt)
  if not jumped then
    jumped = true
    local s = "slot" .. math.floor(params.slot or 9)
    terrain.deleteSaveDir("saves/" .. s .. "/terrain")
    -- A clean slot every run: a saved position would skip the new-save spawn.
    save.deleteSlot(s)
    save.slot(s)
    save.set("g_seed", math.floor(params.seed or 1911564384))
    node.persistent = true
    perf.enable(true)
    if (params.noVsync or 0) > 0 then app.setVsync("Off") end
    print("fps probe: created " .. s .. ", loading the system…")
    scene.load("system")
    return
  end

  if (params.experimentsAt or 0) > 0 and time > params.experimentsAt then
    if not exp_t0 or time - exp_t0 >= (params.every or 5.0) then
      local prev = EXPERIMENTS[exp_i]
      if prev then
        local sw, sh = camera.screenSize()
        print(string.format("fps probe [%s] %sx%s scale %.2f: %.1f fps (mean %.1f ms, worst %.1f ms)", prev[1],
          tostring(sw), tostring(sh), app.renderScale(),
          frames / math.max(acc, 1e-6), acc / math.max(frames, 1) * 1000, worst * 1000))
        if prev[3] then prev[3](false) end
      end
      exp_i = exp_i + 1
      exp_t0 = time
      local cur = EXPERIMENTS[exp_i]
      if not cur then
        print("fps probe: experiments done")
        app.quit()
        return
      end
      if cur[3] then cur[3](true) end
      frames, acc, worst, t_report = 0, 0, 0, time
      return
    end
  end

  if (params.shore or 0) > 0 then to_shore() end
  if (params.walkTest or 0) > 0 then walk_test() end
  if (params.slopeTest or 0) > 0 then slope_test() end
  -- Jump detector: the crew moving 50 m+ in one frame is a teleport.
  local ja = find("Astronaut")
  if ja then
    if jump_last then
      local dx, dy, dz = ja.x - jump_last[1], ja.y - jump_last[2], ja.z - jump_last[3]
      local dj = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dj > 50 then
        print(string.format("fps probe: JUMP %.0f m at t=%.2f by (%.0f, %.0f, %.0f); vel (%.1f, %.1f, %.1f); parent=%s",
          dj, time, dx, dy, dz, ja.vx or 0, ja.vy or 0, ja.vz or 0, tostring(ja.parent and ja.parent.name)))
        for _, nm in ipairs({ "Bryolru", "Bryil" }) do
          local b = space.body(nm)
          if b then print(string.format("   %s at (%.0f, %.0f, %.0f)", nm, b.x, b.y, b.z)) end
        end
        local pc = findScript("planet_camera")
        print("   camera " .. tostring(pc and pc.cam_x) .. " " .. tostring(pc and pc.cam_y) .. " " .. tostring(pc and pc.cam_z))
      end
    end
    jump_last = { ja.x, ja.y, ja.z }
  end
  if not dumped and time > 3 then
    dumped = true
    for _, n in ipairs(findTagged("sea") or {}) do
      local m = n:material()
      print(string.format("fps probe: sea %s model=%s visible=%s scale=%s shader=%s parent=%s",
        n.name, tostring(n.model), tostring(n.visible), tostring(n.scale),
        tostring(m and m.shader), tostring(n.parent and n.parent.name)))
    end
    print("fps probe: water volumes " .. #(water.volumes() or {}))
  end
  if swim_t0 and time - swim_t0 < 10 and time >= swim_next then
    swim_next = time + 1
    local a = find("Astronaut")
    local bb = space.body(swim_body.name) or swim_body
    local rx, ry, rz = a.x - bb.x, a.y - bb.y, a.z - bb.z
    local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
    local vr = (a.vx * rx + a.vy * ry + a.vz * rz) / rl
    print(string.format("fps probe: swim t+%.0f depth %.2f m, radial %.2f m/s, engine depth %.2f",
      time - swim_t0, swim_sea - rl, vr, water.depthAt(a.x, a.y, a.z) or -1))
  end
  if (params.hideSea or 0) > 0 then
    for _, n in ipairs(findTagged("sea") or {}) do n.visible = false end
  end
  if (params.oceanDebug or 0) > 0 then
    for _, n in ipairs(findTagged("sea") or {}) do n:setShaderParam("debugView", params.oceanDebug) end
  end

  frames = frames + 1
  acc = acc + dt
  if dt > worst then worst = dt end
  if time - t_report < (params.every or 5.0) then return end
  t_report = time

  local b = {}
  for _, k in ipairs(perf.buckets()) do
    local v = perf.ms(k)
    if v > 0.05 then b[#b + 1] = string.format("%s=%.1f/%.1f", k, v, perf.worstMs(k)) end
  end
  local top = {}
  for i, s in ipairs(perf.scripts()) do
    if i > 5 then break end
    top[#top + 1] = string.format("%s=%.2f", s.name, s.ms)
  end
  local c = perf.counts()
  print(string.format(
    "fps probe @%.0fs%s: %.1f fps (mean %.1f ms, worst %.1f ms) accounted %.1f ms%s | %s | %s",
    time, EXPERIMENTS[exp_i] and (" [" .. EXPERIMENTS[exp_i][1] .. "]") or "", frames / math.max(acc, 1e-6), acc / math.max(frames, 1) * 1000, worst * 1000,
    perf.accountedMs(), perf.overloaded() and " OVERLOADED" or "",
    table.concat(b, " "), table.concat(top, " ")))
  print(string.format(
    "   counts: nodes=%s culled=%s draws=%s instances=%s chunks=%s props=%s lights=%s particles=%s mirrorRebuilds=%s",
    tostring(c.nodes), tostring(c.culled), tostring(c.draws), tostring(c.instances), tostring(c.chunks),
    tostring(c.props), tostring(c.lights), tostring(c.particles), tostring(c.mirrorRebuilds)))
  if (c.mirrorRebuilds or 0) > 0 then print("   mirror: " .. tostring(perf.mirrorCause())) end
  local a = find("Astronaut")
  local d = a and space.dominant(a.x, a.y, a.z)
  local b = d and space.body(d)
  if b then
    local rr = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    local bf = findScript("base_facilities")
    local db = (bf and bf.baseX) and math.sqrt((a.x - bf.baseX) ^ 2 + (a.y - bf.baseY) ^ 2 + (a.z - bf.baseZ) ^ 2) or -1
    print(string.format("   crew: on %s, %.1f m from its centre (radius %s), %.0f m from base, visible=%s",
      d, rr, tostring(b.radius), db, tostring(a.visible)))
    for _, bb in ipairs(space.bodies() or {}) do
      if (bb.radius or 0) > 400 or bb.name == "Bryolru" then
        print(string.format("   body %s at (%.0f, %.0f, %.0f) parent=%s soi=%s", bb.name, bb.x, bb.y, bb.z,
          tostring(bb.parent), tostring(bb.soi)))
      end
    end
  end
  frames, acc, worst = 0, 0, 0
  if (params.quitAfter or 0) > 0 and time > params.quitAfter then app.quit() end
end

function lateUpdate(node, dt)
  local cur = EXPERIMENTS[exp_i]
  if not cur then return end
  if not (lit and lit.valid ~= false) then
    local ln = find("Lighting")
    lit = ln and ln:getcomponent("Light") or nil
  end
  if not lit then return end
  if not cur[2] then cur = { cur[1], function() end } end
  -- Put back what the previous row changed before this row changes anything.
  local keep = { "shadows", "shadowDistance", "shadowSoftness", "contactShadows", "fogSteps" }
  if not snap then
    snap = {}
    for _, k in ipairs(keep) do snap[k] = lit[k] end
    print("fps probe: lighting snapshot " .. table.concat((function()
      local t = {}; for _, k in ipairs(keep) do t[#t + 1] = k .. "=" .. tostring(snap[k]) end; return t end)(), " "))
  end
  for _, k in ipairs(keep) do lit[k] = snap[k] end
  cur[2](lit)
end
