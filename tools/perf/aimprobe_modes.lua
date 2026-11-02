-- ── aim probe (tools/perf/aimprobe.sh): the laser's aim ring and the flashlight ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua and
-- verifyprobe_modes.lua (V.*). Modes:
--   vaim    the aim ring at 1.5, 3, 8 and 20 m (camera distance logged too) on
--           flat ground, a 30° slope and a sculpted wall: its radius (m and px,
--           % of the view), the ring node's up against the surface normal at
--           the hit, and at 8 m on the slope one second of frames: the ring's
--           place in the planet's frame against the hit (lag, jitter).
--   vtorch  the flashlight: bought into the pack, L pressed (sim), its model on
--           the helmet (a close picture by day), the beam at night in third
--           and first person, and the battery at 5 % (the brown-out).
-- `VP PASS|FAIL`, `VP RESULT`; pictures in $WORK/proj/save/user/vshots/.
local A = {}
function A.eye(a)
  local up = V.up(a)
  return { x = a.x + up.x * 0.6, y = a.y + up.y * 0.6, z = a.z + up.z * 0.6 }
end
-- the ground under a planet-frame point: ray down from 6 m over it
function A.ground(p, U)
  local h = raycast(vec3(p.x + U.x * 6, p.y + U.y * 6, p.z + U.z * 6), vec3(-U.x, -U.y, -U.z), 14, astro())
  if not (h and h.distance) then return nil end
  return { x = p.x + U.x * (6 - h.distance), y = p.y + U.y * (6 - h.distance), z = p.z + U.z * (6 - h.distance) }
end
function A.fxnode(name)
  local n = find(name)
  return n and n.valid ~= false and n or nil
end
-- stand the crew at a planet-frame point (rel), facing `F` with the view pitched `p`
function A.put(rel, F, p)
  local a, b = astro(), home()
  local U = unit(rel)
  a.x, a.y, a.z = b.x + rel.x + U.x * 1.2, b.y + rel.y + U.y * 1.2, b.z + rel.z + U.z * 1.2
  a.vx, a.vy, a.vz = 0, 0, 0
  V.pc().face(F.x, F.y, F.z, p or -0.2)
end

-- sculpt a strip (grade 0: level) or a ramp along F from rel0 (planet frame):
-- V.ground's strokes without its craft
function A.strip(F, U, from_d, to_d, grade, rel0)
  local n = unit(sub(U, scl(F, grade)))
  local L = unit(cross(U, F))
  local d = from_d
  while d <= to_d do
    local bb = home()
    local up = (grade ~= 0) and math.max(0, d - math.max(0, from_d)) * grade or 0
    local p = { x = bb.x + rel0.x + F.x * d + U.x * up, y = bb.y + rel0.y + F.y * d + U.y * up, z = bb.z + rel0.z + F.z * d + U.z * up }
    for _, lat in ipairs({ -1.4, 0, 1.4 }) do
      local q = { x = p.x + L.x * lat, y = p.y + L.y * lat, z = p.z + L.z * lat }
      if grade ~= 0 then terrain.sculpt(q.x, q.y, q.z, 1.6, 1.0, "raise") end
      terrain.sculpt(q.x, q.y, q.z, 1.9, 1.0, "flatten", { normal = vec3(n.x, n.y, n.z) })
    end
    d = d + 0.9
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "sculpt")
  wait(0.8)
end

-- the ring on one surface, aimed as a player aims: in first person, the view
-- pitched at `target(d)` (planet-frame point) from a crew stood at the foot
-- `target` gives. The tool's own aim (the crosshair) puts the ring; the ring's
-- radius, its size on screen, its up against the surface normal at the aim
-- and its distance from the aim point are read back.
function A.cam_eye()
  local cn = V.pc().node
  local o = cn:toWorld(vec3(0, 0, 0))
  return { x = o.x, y = o.y, z = o.z }
end
function A.look_at(F, U, tw)
  local e = A.cam_eye()
  local v = sub(tw, e)
  local up = dot(v, U)
  local h = len(v.x - U.x * up, v.y - U.y * up, v.z - U.z * up)
  V.pc().face(F.x, F.y, F.z, math.atan2(up, h))
end
function A.measure(tag, d, surf_n)
  local tb = findScript("tool_belt")
  local sh = select(2, camera.screenSize())
  local mk = A.fxnode("FxAimMark")
  local r = tb.ringR
  local ax, ay, az = tb.aimNow()
  if not (mk and r and ax and mk.visible ~= false) then
    P("VP %s ring at %.1f m: no mark (node %s, ringR %s, aim %s)", tag, d, tostring(mk ~= nil), tostring(r), tostring(ax))
    return nil
  end
  local c = mk:toWorld(vec3(0, 0, 0))
  local up = unit(sub(mk:toWorld(vec3(0, 1, 0)), c))
  local sx, sy = camera.worldToScreen(c.x, c.y, c.z)
  local t1 = unit(cross(up, (math.abs(up.x) < 0.9) and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
  local t2 = cross(up, t1)
  local px = 0
  for _, t in ipairs({ t1, t2 }) do
    local qx, qy = camera.worldToScreen(c.x + t.x * r, c.y + t.y * r, c.z + t.z * r)
    if sx and qx then px = math.max(px, math.sqrt((qx - sx) ^ 2 + (qy - sy) ^ 2)) end
  end
  local e = A.cam_eye()
  local dd = unit(sub({ x = ax, y = ay, z = az }, e))
  local h = raycast(e.x, e.y, e.z, dd.x, dd.y, dd.z, 60, astro())
  local n = (h and h.nx) and unit({ x = h.nx, y = h.ny, z = h.nz }) or surf_n
  local ang = n and math.deg(math.acos(math.max(-1, math.min(1, dot(up, n))))) or -1
  local off = len(c.x - ax, c.y - ay, c.z - az)
  local a = astro()
  local dcrew = len(ax - a.x, ay - a.y, az - a.z)
  local dcam = len(ax - e.x, ay - e.y, az - e.z)
  P("VP %s ring at %.1f m (aim %.1f m from the crew, %.1f m from the camera): radius %.3f m, %.0f px (%.1f%% of the view), its up %.1f° off the surface normal, centre %.2f m from the aim point",
    tag, d, dcrew, dcam, r, px, 100 * px / sh, ang, off)
  return { d = d, r = r, px = px, frac = px / sh, ang = ang, off = off, dcam = dcam }
end
function A.ring_series(tag, target, dists, surf_n, U)
  local rows = {}
  local pc = V.pc()
  for _, d in ipairs(dists) do
    local tgt, foot, F = target(d)
    A.put(foot, F, 0)
    pc.firstPerson = true
    wait(0.8)
    local b = home()
    A.look_at(F, U, { x = b.x + tgt.x, y = b.y + tgt.y, z = b.z + tgt.z })
    wait(0.6)
    b = home()
    A.look_at(F, U, { x = b.x + tgt.x, y = b.y + tgt.y, z = b.z + tgt.z })
    wait(0.8)
    local row = A.measure(tag, d, surf_n)
    if row then rows[#rows + 1] = row end
    V.shot(string.format("%s_%03.0f_fp", tag, d * 10), true)
  end
  return rows
end

local function run_vaim()
  V.tag = "aim"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  local wx = findScript("weather"); if wx and wx.force then pcall(wx.force, "clear") end
  wait(3)
  -- open ground 150 m out from the base (no buildings in the pictures)
  do
    local u, t1, t2, R = base_frame()
    local dir = dir_at(u, t2, 150, R)
    local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 150)
    if not gr then V.check("spot", false, "no ground 150 m out"); V.result(); return end
    stand_at({ dir = dir, r = gr })
  end
  wait(5)
  V.select_tool("laser")
  local a, b = astro(), home()
  local U = V.up(a)
  local F = unit(sub({ x = 1, y = 0, z = 0 }, scl(U, U.x)))
  local Rt = unit(cross(F, U))
  local g0 = A.ground(sub(a, b), U) or sub(a, b)
  local dists = { 1.5, 3, 8, 20 }
  -- FLAT: level ground flattened 24 m ahead
  A.strip(F, U, -2, 24, 0, g0)
  local flat = A.ring_series("flat", function(d)
    local t = { x = g0.x + F.x * 4, y = g0.y + F.y * 4, z = g0.z + F.z * 4 }
    t = A.ground(t, U) or t
    return t, { x = t.x - F.x * d, y = t.y - F.y * d, z = t.z - F.z * d }, F
  end, dists, U, U)
  -- SLOPE: 30 m to the right, a 0.6 grade (31°) ramp rising away along F
  local s0 = A.ground({ x = g0.x + Rt.x * 30, y = g0.y + Rt.y * 30, z = g0.z + Rt.z * 30 }, U) or g0
  A.strip(F, U, -22, -0.5, 0, s0)
  A.strip(F, U, 0, 9, 0.6, s0)
  local sn = unit(sub(U, scl(F, 0.6)))
  local slope = A.ring_series("slope", function(d)
    local t = { x = s0.x + F.x * 4 + U.x * 2.4, y = s0.y + F.y * 4 + U.y * 2.4, z = s0.z + F.z * 4 + U.z * 2.4 }
    t = A.ground(t, U) or t
    local foot = { x = s0.x + F.x * (4 - d), y = s0.y + F.y * (4 - d), z = s0.z + F.z * (4 - d) }
    foot = A.ground(foot, U) or foot
    return t, foot, F
  end, dists, sn, U)
  -- the ring held on the slope at 8 m while the planet carries everything: its
  -- place in the planet's frame against the tool's own aim point, every frame
  -- for 1.5 s, the view held on the spot (first person)
  do
    local tb = findScript("tool_belt")
    local t0p = { x = s0.x + F.x * 4 + U.x * 2.4, y = s0.y + F.y * 4 + U.y * 2.4, z = s0.z + F.z * 4 + U.z * 2.4 }
    local t = A.ground(t0p, U) or t0p
    A.put(A.ground({ x = s0.x - F.x * 4, y = s0.y - F.y * 4, z = s0.z - F.z * 4 }, U) or s0, F, 0)
    V.pc().firstPerson = true
    wait(1.0)
    local errs, prev, jit = {}, nil, 0
    local t0 = time
    P("VP ring_rides: target %s, mark %s, aim %s", tostring(t ~= nil), tostring(A.fxnode("FxAimMark") ~= nil), tostring((tb.aimNow())))
    while t and time - t0 < 1.5 do
      local bb = home()
      A.look_at(F, U, { x = bb.x + t.x, y = bb.y + t.y, z = bb.z + t.z })
      yield()
      local mk = A.fxnode("FxAimMark")
      local ax, ay, az = tb.aimNow()
      bb = home()
      if mk and ax then
        local c = mk:toWorld(vec3(0, 0, 0))
        local rel = { x = c.x - bb.x, y = c.y - bb.y, z = c.z - bb.z }
        errs[#errs + 1] = len(c.x - ax, c.y - ay, c.z - az)
        if prev then jit = math.max(jit, len(rel.x - prev.x, rel.y - prev.y, rel.z - prev.z)) end
        prev = rel
      end
    end
    local mx, sum = 0, 0
    for k = 10, #errs do mx = math.max(mx, errs[k]); sum = sum + errs[k] end
    local n = math.max(1, #errs - 9)
    V.check("ring_rides", #errs > 10 and mx < 0.2 and jit < 0.08,
      "held 1.5 s at 8 m on the slope: %d frames, the ring %.3f m off the tool's aim point on average, worst %.3f m (its 0.06 m lift included), largest frame-to-frame step %.3f m in the planet's frame",
      #errs, sum / n, mx, jit)
  end
  -- third person: the same ring as the player usually sees it, 3 views on the flat
  do
    V.pc().firstPerson = false
    A.put(A.ground({ x = g0.x - F.x * 2, y = g0.y - F.y * 2, z = g0.z - F.z * 2 }, U) or g0, F, -0.2)
    for k, pitch in ipairs({ -0.95, -0.65, -0.4 }) do
      V.pc().face(F.x, F.y, F.z, pitch)
      wait(1.4)
      A.measure("tp" .. k, 0, U)
      V.shot(string.format("tp_%d", k), true)
    end
  end
  -- WALL: 30 m to the left, raised spheres stacked into a 4.5 m face across F
  local w0 = A.ground({ x = g0.x - Rt.x * 30, y = g0.y - Rt.y * 30, z = g0.z - Rt.z * 30 }, U) or g0
  A.strip(F, U, -22, -1, 0, w0)
  local bb = home()
  for _, hgt in ipairs({ 0.6, 1.8, 3.0, 4.2 }) do
    for lat = -4, 4, 1.2 do
      local q = { x = bb.x + w0.x + F.x * 2.2 + Rt.x * lat + U.x * hgt, y = bb.y + w0.y + F.y * 2.2 + Rt.y * lat + U.y * hgt,
                  z = bb.z + w0.z + F.z * 2.2 + Rt.z * lat + U.z * hgt }
      terrain.sculpt(q.x, q.y, q.z, 1.5, 1.0, "raise")
    end
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "sculpt")
  wait(1.0)
  -- the face: a ray along F at 1.6 m up finds it
  local wf
  do
    bb = home()
    local o = { x = bb.x + w0.x + U.x * 2.4, y = bb.y + w0.y + U.y * 2.4, z = bb.z + w0.z + U.z * 2.4 }
    local h = raycast(vec3(o.x, o.y, o.z), vec3(F.x, F.y, F.z), 10, astro())
    if h and h.distance then
      wf = { x = o.x + F.x * h.distance - bb.x, y = o.y + F.y * h.distance - bb.y, z = o.z + F.z * h.distance - bb.z }
      P("VP the wall's face %.2f m ahead, its normal %.2f against level (0 = vertical)", h.distance, h.nx and dot(unit({ x = h.nx, y = h.ny, z = h.nz }), U) or -9)
    end
  end
  local wall = {}
  if wf then
    wall = A.ring_series("wall", function(d)
      local foot = { x = w0.x + F.x * (dot(sub(wf, w0), F) - d), y = w0.y + F.y * (dot(sub(wf, w0), F) - d), z = w0.z + F.z * (dot(sub(wf, w0), F) - d) }
      foot = A.ground(foot, U) or foot
      return wf, foot, F
    end, dists, scl(F, -1), U)
  else
    V.check("wall", false, "no wall face found")
  end
  -- the checks: small near, a little bigger (on screen) far, flush everywhere
  local function series_ok(tag, rows)
    if #rows < 4 then return V.check("ring_" .. tag, false, "%d of 4 distances measured", #rows) end
    local flush = true
    -- (a grazing or far aim reads the mesh's facet normal off a bump: 25° there)
    for _, r in ipairs(rows) do if r.ang < 0 or r.ang > ((r.dcam or 0) > 15 and 25 or 12) then flush = false end end
    local near, far = rows[1], rows[#rows]
    local grows = far.frac >= near.frac * 0.95
    return V.check("ring_" .. tag, near.frac <= 0.035 and far.frac >= 0.015 and grows and flush,
      "%s: 1.5 m %.1f%% of the view, 3 m %.1f%%, 8 m %.1f%%, 20 m %.1f%%; worst tilt off the surface %.1f°", tag,
      100 * rows[1].frac, 100 * rows[2].frac, 100 * rows[3].frac, 100 * rows[4].frac,
      math.max(rows[1].ang, rows[2].ang, rows[3].ang, rows[4].ang))
  end
  series_ok("flat", flat)
  series_ok("slope", slope)
  if wf then series_ok("wall", wall) end
  V.result()
end

-- the sun's height over the crew (1 overhead, <0 below the horizon)
function A.sun_up()
  local bb, a = home(), astro()
  local best, bmu = nil, -1
  for _, o in ipairs(space.bodies() or {}) do
    local key = ((o.soi or 0) < 0 and 1e30 or 0) + (o.mu or 0)
    if key > bmu then best, bmu = o, key end
  end
  if not (bb and a and best) then return 0 end
  local up = unit(sub(a, bb))
  return dot(up, unit(sub(best, a)))
end
-- warp the clock until the sun is well down (real night, not the sun switched off)
function A.night(warp)
  local t0 = time
  local s = A.sun_up()
  P("VP sun %.2f before the warp", s)
  while s > -0.35 and time - t0 < 150 do
    space.warp(warp)
    yield()
    s = A.sun_up()
  end
  space.warp(1)
  wait(2)
  P("VP night: sun %.2f after %.0f s of warp %d", A.sun_up(), time - t0, warp)
  return A.sun_up() < -0.2
end
function A.helmet()
  local a = astro()
  for _, c in ipairs(a:children()) do
    if c.name == "AstroModel" then
      for _, h in ipairs(c:children()) do if h.name == "Helmet" then return h, c end end
    end
  end
end

local function run_vtorch()
  V.tag = "torch"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  local wx = findScript("weather"); if wx and wx.force then pcall(wx.force, "clear") end
  wait(3)
  do
    local u, t1, t2, R = base_frame()
    local dir = dir_at(u, t2, 150, R)
    local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 150)
    if gr then stand_at({ dir = dir, r = gr }) end
  end
  wait(5)
  local inv = findScript("inventory")
  local fl = findScript("flashlight")
  local I = findScript("items")
  if not (inv and fl and I) then V.check("torch_scripts", false, "inventory %s flashlight %s items %s", tostring(inv ~= nil), tostring(fl ~= nil), tostring(I ~= nil)); V.result(); return end
  local c = I.card("flashlight")
  P("VP the depot card: %s (%s) — %s", c.name, c.kind, c.about)
  for _, r in ipairs(c.rows) do P("VP   %s: %s", r[1], r[2]) end
  local shop = false
  for _, e in ipairs(I.shopList()) do if e.id == "flashlight" then shop = true; P("VP on the BUY counter: $%d, %.1f kg, %s L", e.cost, e.kg, tostring(e.L)) end end
  V.check("torch_shop", shop and I.def("flashlight").kg <= 0.35, "sold at the depot: %s, %.2f kg", tostring(shop), I.def("flashlight").kg)
  -- pressed with none in the pack: refused
  fl.sim = { pressed = true }
  wait(0.3)
  V.check("torch_needs_one", fl.on == false, "L with no torch in the pack: on = %s", tostring(fl.on))
  inv.addGear("astro", "flashlight", 1)
  wait(1.0)
  -- a close picture of the helmet by day (a photo camera beside the head)
  local a = astro()
  local U = V.up(a)
  local F = unit(sub({ x = 1, y = 0, z = 0 }, scl(U, U.x)))
  local pc = V.pc()
  pc.face(F.x, F.y, F.z, -0.1)
  wait(1.5)
  local _, m = A.helmet()
  local cam
  spawn("FlagPhotoCam", vec3(a.x, a.y, a.z), function(n) cam = n end)
  wait_for(function() return cam end, 5, "cam")
  -- The photo camera rides the AstroModel (parented, a local offset): a world
  -- position written from the probe's update is a tick of the planet's travel
  -- stale by the time it renders (metres), which lost the helmet at 1 m.
  local function hold_cam(eye_f, eye_r, eye_u, secs, tag)
    local hn, am = A.helmet()
    if not (hn and am and cam) then return end
    local hl = am:toLocal(hn:toWorld(vec3(0, 0, 0)))
    if cam:getParent() ~= am then cam:setParent(am, { keepWorld = false }) end
    -- the AstroModel's +X is the crew's left (frame_of: right = -X)
    local ox, oy, oz = -eye_r, eye_u, eye_f
    cam.x, cam.y, cam.z = hl.x + ox, hl.y + oy, hl.z + oz
    local rr = math.sqrt(ox * ox + oz * oz)
    cam:setAngles(math.atan2(ox, oz), -math.atan2(oy, rr), 0)
    wait(math.max(0.2, secs - 0.5))
    if tag then V.shot(tag, false, cam) end
    wait(0.5)
  end
  -- (perfbench's own camera list: cam is a FlagPhotoCam, captured explicitly)
  hold_cam(0.9, 0.7, 0.15, 1.2, "1_helmet_right_day")
  hold_cam(0.9, -0.7, 0.15, 1.2, "2_helmet_left_day")
  local tn = fl and fl.on
  -- night: the clock warped on until the sun is down
  V.select_tool("gravgun")
  V.check("night", A.night(400), "the sun %.2f over the horizon", A.sun_up())
  local lc, sun0
  a = astro(); U = V.up(a)
  F = unit(sub({ x = 1, y = 0, z = 0 }, scl(U, U.x)))
  pc.face(F.x, F.y, F.z, -0.25)
  wait(1.0)
  V.shot("3_night_off", true)
  fl.sim = { pressed = true }
  wait(1.0)
  V.check("torch_on", fl.on == true and (fl.lit or 0) > 1.0 and (fl.spot or 180) < 60, "L with a torch: on %s, light %.2f, cone %s°, battery %.1f%%", tostring(fl.on), fl.lit or -1, tostring(fl.spot), fl.level or -1)
  if fl.lensX and m then
    local aa = astro()
    local head = { x = aa.x + U.x * 0.95, y = aa.y + U.y * 0.95, z = aa.z + U.z * 0.95 }
    P("VP the beam starts %.2f m from the head, aimed %.1f° off the view", len(fl.lensX - head.x, fl.lensY - head.y, fl.lensZ - head.z),
      math.deg(math.acos(math.max(-1, math.min(1, fl.dirX * pc.fwd_x + fl.dirY * pc.fwd_y + fl.dirZ * pc.fwd_z)))))
  end
  pc.face(F.x, F.y, F.z, -0.25)
  wait(1.0)
  V.shot("4_night_on_3p", true)
  hold_cam(0.9, 0.7, 0.15, 1.2, "5_helmet_right_night")
  -- a wall of rock 6 m ahead, lit at night
  local b = home()
  local g = { x = a.x - b.x + F.x * 6, y = a.y - b.y + F.y * 6, z = a.z - b.z + F.z * 6 }
  for _, hgt in ipairs({ -0.5, 0.7, 1.9 }) do
    for lat = -3, 3, 1.5 do
      local Rt = unit(cross(F, U))
      local q = { x = b.x + g.x + Rt.x * lat + U.x * hgt, y = b.y + g.y + Rt.y * lat + U.y * hgt, z = b.z + g.z + Rt.z * lat + U.z * hgt }
      terrain.sculpt(q.x, q.y, q.z, 1.4, 1.0, "raise")
    end
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "sculpt")
  wait(1.0)
  pc.face(F.x, F.y, F.z, -0.1)
  wait(0.8)
  V.shot("6_night_wall_3p", true)
  -- first person
  pc.firstPerson = true
  wait(1.2)
  V.shot("7_night_wall_fp", true)
  pc.face(F.x, F.y, F.z, -0.6)
  wait(0.8)
  V.shot("8_night_ground_fp", true)
  -- the battery at 5 %: the brown-out
  inv.drawFill("astro", "flashlight", 95)
  wait(1.5)
  P("VP battery now %.1f%%", fl.level or -1)
  local lo, hi = 99, 0
  local t0 = time
  while time - t0 < 2 do lo = math.min(lo, fl.lit or 0); hi = math.max(hi, fl.lit or 0); yield() end
  V.check("torch_brownout", hi < 2.2 * 0.75 and lo < hi, "at 5%%: the light between %.2f and %.2f (full %.1f)", lo, hi, 2.2)
  V.shot("9_night_5pct_fp", true)
  pc.firstPerson = false
  inv.refill("astro", "flashlight")
  fl.sim = { pressed = true }
  wait(0.5)
  V.check("torch_off", fl.on == false and (fl.lit or 0) == 0, "L again: on %s, light %.2f", tostring(fl.on), fl.lit or -1)
  if lc and sun0 then lc.intensity = sun0 end
  V.result()
end
