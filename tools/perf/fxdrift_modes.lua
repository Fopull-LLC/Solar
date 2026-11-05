-- ── fx drift probe (tools/perf/fxdrift.sh): do a craft's effects stay with ──
-- the ground? The home world moves ~90 m/s on its rails; a World-track
-- particle that does not ride it streaks off along the orbit. Spliced into a
-- copy of perfbench.lua after vfxprobe_modes.lua (it uses VP's cameras).
--   fxjet     the 27-part jet: held on the clamps at full throttle (soot,
--             plume, haze, light-off puff) seen from a camera fixed to the
--             ground, a burst of frames 0.1 s apart; the take-off roll past
--             a fixed camera; in flight from a chase camera and from a fixed
--             camera it flies past
--   fxrocket  the starter rocket on the pad at full throttle (flame, exhaust
--             puffs, pad blast, ignition) from a fixed camera, then the climb
--             from the ground
-- Each burst prints FD lines: the planet's speed, the craft's
-- (planet-relative) speed, the dominant body at the nozzle, and the FxJet
-- node's carry.
local FD = {}

-- Markers in the pictures (drawn poses, this frame): a red ball on A's
-- emitter, a green one on B's, and a yellow line 3 m along the planet's
-- orbital velocity from A (the direction a particle left in the star's
-- frame would go, relative to the ground: against it).
local vp_late = lateUpdate
function lateUpdate(node, dt)
  vp_late(node, dt)
  if not FD.marks then return end
  local A, B = FD.A, FD.B
  if A and A.valid then
    local w = A.worldPos
    draw.sphere(w.x, w.y, w.z, 0.35, 1, 0.1, 0.1)
    local b = home()
    local vx, vy, vz = b.vx or 0, b.vy or 0, b.vz or 0
    local l = len(vx, vy, vz)
    if l > 1 then draw.line(w.x, w.y, w.z, w.x - vx / l * 3, w.y - vy / l * 3, w.z - vz / l * 3, 1, 0.9, 0.1) end
  end
  if B and B.valid then
    local w = B.worldPos
    draw.sphere(w.x, w.y, w.z, 0.35, 0.1, 1, 0.1)
  end
  if FD.bike then
    local b = home()
    local r = FD.bike.rel
    draw.sphere(b.x + r.x, b.y + r.y, b.z + r.z, 0.3, 0.2, 0.6, 1)
  end
  if FD.spots then
    local b = home()
    for _, sp in ipairs(FD.spots) do
      draw.sphere(b.x + sp.rel.x, b.y + sp.rel.y, b.z + sp.rel.z, 0.25, 1, 1, 1)
    end
  end
end


function FD.frame_line(tag, vn, at)
  local b = home()
  local i = assembly.info(vn)
  local w = at and at.valid and at.worldPos or i.com
  local name = space.dominant(w.x, w.y, w.z)
  local bb = name and space.body(name)
  local c = at and at.valid and at.carry
  P("FD %s: planet |v| %.1f m/s, craft |vel| %.1f m/s, dominant %s (soi %s), node.carry %s",
    tag, len(b.vx or 0, b.vy or 0, b.vz or 0), len(i.vel.x, i.vel.y, i.vel.z), tostring(name),
    tostring(bb and bb.soi), c and string.format("(%.2f %.2f %.2f)", c.x, c.y, c.z) or "-")
end

-- A camera fixed on the ground, placed from the craft's own frame NOW:
-- eye and target given in the craft node's local axes (drawn pose), then
-- kept planet-relative so it holds still while the world moves.
function FD.cam_pin(vn, ex, ey, ez, tx, ty, tz)
  local b = home()
  local e, t = vn:toWorld(vec3(ex, ey, ez)), vn:toWorld(vec3(tx, ty, tz))
  VP.cam_fixed(sub(e, b), sub(t, b))
end

-- Where the camera really is: its centre ray against the craft and the
-- intended eye (planet-relative, read in one pass).
function FD.camdbg(tag, vn)
  local ok, w, h = pcall(camera.screenSize)
  if not (ok and w) then return end
  local ok2, ox, oy, oz, dx, dy, dz = pcall(camera.screenToRay, w * 0.5, h * 0.5)
  if not (ok2 and ox) then return end
  local b = home()
  local c = vn:toWorld(vec3(0, 0, 0))
  local U = unit(sub(c, b))
  local want = VP.cam and { VP.cam() } or {}
  local e = want[1]
  P("FD CAM %s: cam-craft %.1f m, cam height over craft %.1f m, view dot up %.2f, eye error %s",
    tag, len(ox - c.x, oy - c.y, oz - c.z), dot(sub({ x = ox, y = oy, z = oz }, c), U), dot({ x = dx, y = dy, z = dz }, U),
    e and string.format("%.1f m", len(ox - e.x, oy - e.y, oz - e.z)) or "-")
end

-- A ground camera from drawn poses read in one pass: the craft's centre,
-- its nose flattened onto the local horizontal, the planet's up there.
-- side m to the right, upm up, back m behind the centre (negative: ahead),
-- looking at a point `look` m along the nose, `lookup` up.
function FD.cam_world(vn, F, side, upm, back, look, lookup)
  local b = home()
  local c = vn:toWorld(vec3(0, 0, 0))
  local U = unit(sub(c, b))
  local f = F()
  local Fh = sub(f, scl(U, dot(f, U)))
  P("FD CAMSET: nose dot up %.2f", dot(f, U))
  Fh = unit(Fh)
  local Rt = unit(cross(Fh, U))
  local function at(r, u, fw) return { x = c.x + Rt.x * r + U.x * u + Fh.x * fw, y = c.y + Rt.y * r + U.y * u + Fh.y * fw, z = c.z + Rt.z * r + U.z * u + Fh.z * fw } end
  VP.cam_fixed(sub(at(side, upm, -back), b), sub(at(0, lookup or 0, look), b))
end

function FD.burst(name, n, dtw)
  if FD.vn then FD.camdbg(name, FD.vn) end
  for k = 1, n do
    VP.shot(string.format("%s_%d", name, k))
    wait(dtw)
  end
end

function FD.find_under(n, name, depth)
  for _, c in ipairs(n:children()) do
    if c.name == name then return c end
    if depth > 0 then
      local r = FD.find_under(c, name, depth - 1)
      if r then return r end
    end
  end
  return nil
end
function FD.jet_fx_node(vc) return FD.find_under(vc.node, "FxJet", 4) end

-- THE A/B: two copies of prefabs/FxJet, only their "Jet Smoke" (a World
-- track) running, at full intensity, pointing up:
--   A under the craft's root node (a carried node: the case in question),
--     `upm` m over its centre
--   B under the planet's node (rides it by ancestry), `side` m off A
-- On a moving world a track that rides it leaves a column standing on the
-- ground; one that does not is gone along the orbit in a frame.
function FD.smoke_on(n)
  local sm = n and FD.find_under(n, "Jet Smoke", 1)
  local ps = sm and sm:particles()
  if ps then ps:play(); ps:setIntensity(1.2) end
  return ps ~= nil
end
function FD.ab(vn, upm, side, F)
  local b = home()
  local name = space.dominant(b.x, b.y, b.z)
  local bn = find(save.get("base.body"))
  local c = vn:toWorld(vec3(0, 0, 0))
  local U = unit(sub(c, b))
  local f = F()
  local Fh = unit(sub(f, scl(U, dot(f, U))))
  local Rt = unit(cross(Fh, U))
  local pa = { x = c.x + U.x * upm, y = c.y + U.y * upm, z = c.z + U.z * upm }
  local pb = { x = pa.x + Rt.x * side, y = pa.y + Rt.y * side, z = pa.z + Rt.z * side }
  local la = vn:toLocal(vec3(pa.x, pa.y, pa.z))
  spawn("FxJet", vec3(pa.x, pa.y, pa.z), function(n)
    n.x, n.y, n.z = la.x, la.y, la.z
    n:setUp(vec3(U.x, U.y, U.z))
    FD.A = n
    P("FD AB: A under the craft, smoke %s", tostring(FD.smoke_on(n)))
  end, vn)
  if bn then
    local lb = bn:toLocal(vec3(pb.x, pb.y, pb.z))
    spawn("FxJet", vec3(pb.x, pb.y, pb.z), function(n)
      n.x, n.y, n.z = lb.x, lb.y, lb.z
      n:setUp(vec3(U.x, U.y, U.z))
      FD.B = n
      P("FD AB: B under the planet %s, smoke %s", tostring(bn.name), tostring(FD.smoke_on(n)))
    end, bn)
  else
    P("FD AB: no planet node %s", tostring(save.get("base.body")))
  end
  -- one-shots beside them, through vfx.lua's emit (the game's path), 4 m
  -- the other side of A, every 0.5 s while the burst runs (FD.oneshots)
  FD.os_at = { x = pa.x - Rt.x * 4 - U.x * upm, y = pa.y - Rt.y * 4 - U.y * upm, z = pa.z - Rt.z * 4 - U.z * upm }
end
function FD.oneshots()
  local o = FD.os_at
  if not o then return end
  local b = home()
  local U = unit(sub(o, b))
  local v = findScript("vfx")
  if not (v and v.emit) then return end
  v.emit("TyreDust", o.x, o.y, o.z, { intensity = 1.5, dust = true })
  v.emit("IgnitionPuff", o.x + U.x * 2, o.y + U.y * 2, o.z + U.z * 2, { normal = vec3(U.x, U.y, U.z), intensity = 1 })
  v.emit("ShortSpark", o.x + U.x * 1, o.y + U.y * 1, o.z + U.z * 1, { intensity = 1 })
end
-- A picture every `dtw` s, one-shots fired at each.
function FD.burst_os(name, n, dtw)
  if FD.vn then FD.camdbg(name, FD.vn) end
  for k = 1, n do
    FD.oneshots()
    wait(dtw * 0.5)
    VP.shot(string.format("%s_%d", name, k))
    wait(dtw * 0.5)
  end
end

function FD.puffs_on(n)
  local sm = n and FD.find_under(n, "Contrail Puffs", 1)
  local ps = sm and sm:particles()
  if ps then ps:play(); ps:setIntensity(1.0) end
  return ps ~= nil
end

-- What the player sees: the weather left as it is, the game's own camera,
-- the jet spooling up from idle on the runway. And the emitter test: slow,
-- long-lived World puffs (ContrailPuffs) from A (on the craft) and B (on the
-- planet, 6 m ahead along the nose), marked, from a camera on the ground.
function FD.run_game()
  VP.TAG = "fdgame"
  VP.level()
  local vc = VP.launch_plane()
  if not vc then P("FD RESULT game: no craft"); return end
  local vn = vc.node
  FD.vn = vn
  local wx = findScript("weather")
  local cur = wx and wx.current and wx.current()
  P("FD weather: %s wind %.1f m/s (now %.1f)", tostring(cur and cur.type), cur and cur.wind or -1, cur and cur.windNow or -1)
  local nose = VP.nose(vc)
  vc.releaseClamps()
  vc.setThrottle(0)
  wait(2)
  -- the emitter test, B ahead along the nose so the two stand side by side
  local b = home()
  local c = vn:toWorld(vec3(0, 0, 0))
  local U = unit(sub(c, b))
  local f = nose()
  local Fh = unit(sub(f, scl(U, dot(f, U))))
  local pa = { x = c.x + U.x * 1.5, y = c.y + U.y * 1.5, z = c.z + U.z * 1.5 }
  local pb = { x = pa.x + Fh.x * 6, y = pa.y + Fh.y * 6, z = pa.z + Fh.z * 6 }
  local la = vn:toLocal(vec3(pa.x, pa.y, pa.z))
  local bn = find(save.get("base.body"))
  spawn("FxJet", vec3(pa.x, pa.y, pa.z), function(n)
    n.x, n.y, n.z = la.x, la.y, la.z; n:setUp(vec3(U.x, U.y, U.z)); FD.A = n
    P("FD EMIT: A puffs %s", tostring(FD.puffs_on(n)))
  end, vn)
  local lb = bn:toLocal(vec3(pb.x, pb.y, pb.z))
  spawn("FxJet", vec3(pb.x, pb.y, pb.z), function(n)
    n.x, n.y, n.z = lb.x, lb.y, lb.z; n:setUp(vec3(U.x, U.y, U.z)); FD.B = n
    P("FD EMIT: B puffs %s", tostring(FD.puffs_on(n)))
  end, bn)
  FD.marks = true
  FD.cam_world(vn, nose, 12, 1.5, -3, 3, 3)
  wait(2.5)
  FD.burst("1emit", 4, 0.3)
  FD.cam_world(vn, nose, 0, 14, 0, 3, 0)   -- straight over: where do the puffs sit?
  wait(0.3)
  FD.burst("2emit_top", 2, 0.3)
  -- the same under time warp: the rails run `w` times faster while local
  -- physics and the particles keep 1x, so any frame the effect does not
  -- ride is `w` times the metres
  local w = params.fdwarp or 20
  pcall(space.warp, w)
  wait(1.5)
  P("FD warp: asked %s, space.warp() %s", tostring(w), tostring(space.warp()))
  FD.cam_world(vn, nose, 12, 1.5, -3, 3, 3)
  wait(0.5)
  FD.burst("2w_emit", 3, 0.3)
  FD.cam_world(vn, nose, 0, 14, 0, 3, 0)
  wait(0.3)
  FD.burst("2w_emit_top", 2, 0.3)
  pcall(space.warp, 1)
  wait(0.5)
  -- stop the test emitters (their puffs finish) and spool the jet up from idle
  for _, n in ipairs({ FD.A, FD.B }) do
    local sm = n and n.valid and FD.find_under(n, "Contrail Puffs", 1)
    if sm then sm:particles():stop() end
  end
  FD.marks = false
  VP.cam_off()
  wait(1)
  vc.setThrottle(1)
  local t0 = time
  local k = 0
  while vn.valid and time - t0 < 4.2 do
    yield()
    vc.setThrottle(1)
    vc.AERO.cmd = { p = 0, y = 0, r = 0 }
    if time - t0 > 0.6 + k * 0.6 and k < 6 then
      k = k + 1
      VP.shot(string.format("3spool_game_%d", k))
      if k == 1 then FD.frame_line("spool", vn, FD.jet_fx_node(vc)); VP.stats("spool") end
    end
  end
  -- from the ground beside the runway, as it rolls away
  FD.cam_world(vn, nose, 14, 2, 10, 10, 0)
  wait(0.2)
  FD.burst("4roll_side", 4, 0.3)
  P("FD RESULT game: done")
end

-- One-shots fired with a velocity (spawnEffect's vel), the way the game
-- fires a gas engine's tailpipe puff (vel = the craft's), a separation puff,
-- a small explosion: at fixed spots on the runway, `fdv` m/s along the nose
-- (default 15), next to the same effect fired with no velocity, from a
-- camera fixed on the ground. Markers: white = where each was fired.
function FD.run_puff()
  VP.TAG = "fdpuff"
  VP.level()
  local vc = VP.launch_plane()
  if not vc then P("FD RESULT puff: no craft"); return end
  local vn = vc.node
  FD.vn = vn
  clear_weather()
  local nose = VP.nose(vc)
  wait(1)
  local b = home()
  local c = vn:toWorld(vec3(0, 0, 0))
  local U = unit(sub(c, b))
  local f = nose()
  local Fh = unit(sub(f, scl(U, dot(f, U))))
  local Rt = unit(cross(Fh, U))
  local V = params.fdv or 15
  -- spots 25 m to the side of the jet, 6 m apart across the view
  local spots = {}
  local keys = { "TailpipePuff", "SepPuff", "ExplosionSmall" }
  for i, key in ipairs(keys) do
    for j = 0, 1 do
      local off = (i - 2) * 9 + j * 3
      local p = { x = c.x + Rt.x * 25 + Fh.x * off + U.x * 1.2, y = c.y + Rt.y * 25 + Fh.y * off + U.y * 1.2,
                  z = c.z + Rt.z * 25 + Fh.z * off + U.z * 1.2 }
      spots[#spots + 1] = { key = key, rel = sub(p, b), vel = j == 1 }
    end
  end
  FD.spots = spots
  FD.marks = true
  -- the camera 22 m further out, looking back at the row
  FD.cam_world(vn, nose, 44, 2.5, 0, 0, 1.5)
  wait(1)
  local v = findScript("vfx")
  -- the game's paths: vfx.explode / vfx.separate (vfx.lua decides what of
  -- the velocity to pass), the tailpipe puff the way vessel_controller
  -- fires it (spawnEffect, vel = the craft's velocity)
  local function fire_all()
    local bb = home()
    for _, sp in ipairs(spots) do
      local x, y, z = bb.x + sp.rel.x, bb.y + sp.rel.y, bb.z + sp.rel.z
      local vx, vy, vz = nil, nil, nil
      if sp.vel then vx, vy, vz = Fh.x * V, Fh.y * V, Fh.z * V end
      if sp.key == "TailpipePuff" then
        local o = { normal = vec3(-Fh.x, -Fh.y, -Fh.z), scale = 2.5 }
        if vx then o.vel = vec3(vx, vy, vz) end
        spawnEffect("TailpipePuff", vec3(x, y, z), o)
      elseif sp.key == "SepPuff" and v and v.separate then
        v.separate(x, y, z, vx, vy, vz)
      elseif v and v.explode then
        v.explode(x, y, z, vx or 0, vy or 0, vz or 0, false)
      end
    end
  end
  fire_all()
  FD.camdbg("puffs", vn)
  for k = 1, 6 do
    wait(0.3)
    VP.shot(string.format("1puffs_%.1fs", 0.3 * k))
  end
  -- 2) a bike's exhaust: a point moving at V along the nose, 1.2 m up,
  -- on the runway's shoulder 10 m off the jet, firing a tailpipe puff (vel = V along the
  -- nose, pointing back) every 0.12 s as vessel_controller does; after
  -- 1.2 s it stops dead (brakes) and fires on with no velocity
  wait(4)
  FD.spots = nil
  local bb0 = home()
  c = vn:toWorld(vec3(0, 0, 0))   -- read again: the world point of 5 s ago is a km down the orbit
  local p0 = sub({ x = c.x + Rt.x * 10 - Fh.x * 8 + U.x * 1.2, y = c.y + Rt.y * 10 - Fh.y * 8 + U.y * 1.2,
                   z = c.z + Rt.z * 10 - Fh.z * 8 + U.z * 1.2 }, bb0)
  FD.bike = { rel = p0 }
  FD.cam_world(vn, nose, 24, 4, 0, 0, 1.2)
  wait(0.5)
  local t0 = time
  local last, k = -1, 0
  local shots = { 0.6, 1.2, 1.6, 2.0, 2.4 }
  local si = 1
  while time - t0 < 2.5 do
    yield()
    local t = time - t0
    local run = math.min(t, 1.2)
    FD.bike.rel = { x = p0.x + Fh.x * V * run, y = p0.y + Fh.y * V * run, z = p0.z + Fh.z * V * run }
    if t - last >= 0.12 then
      last = t
      local bb = home()
      local o = { normal = vec3(-Fh.x, -Fh.y, -Fh.z), scale = 6.0 }   -- (6x: readable at 14 m)
      if t < 1.2 then o.vel = vec3(Fh.x * V, Fh.y * V, Fh.z * V) end
      spawnEffect("TailpipePuff", vec3(bb.x + FD.bike.rel.x, bb.y + FD.bike.rel.y, bb.z + FD.bike.rel.z), o)
    end
    if si <= #shots and t >= shots[si] then VP.shot(string.format("2bike_%.1fs", shots[si])); si = si + 1 end
  end
  P("FD RESULT puff: done")
end

function FD.run_jet()
  VP.TAG = "fdjet"
  VP.level()
  local vc = VP.launch_plane()
  if not vc then P("FD RESULT jet: no craft"); return end
  local vn = vc.node
  FD.vn = vn
  clear_weather()
  local nose = VP.nose(vc)
  -- 1) on the clamps at full throttle, a camera on the ground beside the tail
  vc.setThrottle(1)
  vc.setSAS("stability")
  for _ = 1, 4 do wait(1) end
  local fxn = FD.jet_fx_node(vc)
  FD.frame_line("clamped", vn, fxn)
  P("FD clamped: anchored %s", tostring(assembly.info(vn).anchored))
  FD.cam_world(vn, nose, 14, 2.0, 4, -12, 0)
  wait(0.4)
  FD.burst("1clamped", 4, 0.1)
  -- the A/B, parked on the clamps: a camera 30 m off on the ground
  FD.ab(vn, 3, 8, nose)
  wait(0.5)
  FD.cam_world(vn, nose, 30, 3, 0, 0, 6)
  wait(1.5)
  FD.burst_os("0ab_parked", 4, 0.5)
  FD.cam_world(vn, nose, 32, 5, 8, -18, 0)
  wait(0.3)
  VP.shot("2clamped_wide")
  VP.stats("clamped")
  -- 2) the roll: released at full throttle, past a camera standing 60 m ahead
  FD.cam_world(vn, nose, 14, 3, -60, -20, 0)
  vc.releaseClamps()
  local t0, shot = time, 0
  local air = 0
  while vn.valid and time - t0 < 30 do
    yield()
    vc.setThrottle(1)
    local i = assembly.info(vn)
    local V = len(i.vel.x, i.vel.y, i.vel.z)
    vc.AERO.cmd = { p = V > 32 and -0.5 or 0, y = 0, r = 0 }
    local t = time - t0
    if shot == 0 and t > 1.5 then shot = 1; FD.frame_line("roll", vn, fxn); FD.burst("3roll", 3, 0.15) end
    if shot == 1 and t > 4 then shot = 2; VP.cam_chase(vn, 16, 4, 2.0, 0, nose); wait(0.3); FD.frame_line("roll4", vn, fxn); FD.burst("4roll_chase", 3, 0.15) end
    if not vc.R2.onWheels and i.grounded == false then air = air + dt else air = 0 end
    if air > 1.5 and t > 8 then break end
  end
  -- 3) in flight: chase camera, then a camera left standing in the air
  VP.cam_chase(vn, 24, 8, 4, 0, nose)
  t0 = time
  local fixed = false
  while vn.valid and time - t0 < 9 do
    yield()
    vc.setThrottle(1)
    vc.AERO.cmd = { p = -0.25, y = 0, r = 0 }
    if time - t0 > 4 and not FD.f1 then FD.f1 = true; FD.frame_line("flight", vn, fxn); FD.burst("5flight_chase", 3, 0.15) end
    if time - t0 > 6 and not fixed then
      fixed = true
      -- standing in the air, 40 m to the side of where the jet is now, looking back along its path
      FD.cam_world(vn, nose, 40, 3, -10, -30, 0)
      wait(0.2)
      FD.burst("6flight_fixed", 4, 0.25)
    end
  end
  VP.stats("flight")
  P("FD RESULT jet: done")
end

function FD.run_rocket()
  VP.TAG = "fdrocket"
  VP.level()
  local vc = launch_via_builder(rocket_bp(2), "pad", 5)
  if not vc then P("FD RESULT rocket: no craft"); return end
  local vn = vc.node
  clear_weather()
  FD.vn = vn
  -- the rocket's "nose" for the cameras: any horizontal direction, fixed
  local b0 = home()
  local c0 = vn:toWorld(vec3(0, 0, 0))
  local U0 = unit(sub(c0, b0))
  local Fx = unit(cross(U0, { x = 0.3, y = 0.8, z = 0.5 }))
  local F = function() return Fx end
  -- a camera on the ground `dist` m off, `h` up, looking `lookup` m up the stack
  local function ground_cam(dist, h, lookup) FD.cam_world(vn, F, dist, h, 0, 0, lookup) end
  ground_cam(16, 1.5, -1)
  wait(1)
  VP.shot("1pad_cold")
  FD.ab(vn, 2, 7, F)
  wait(0.5)
  ground_cam(30, 3, 5)
  wait(1.5)
  FD.burst_os("0ab_pad", 4, 0.5)
  ground_cam(16, 1.5, -1)
  vc.setThrottle(1)
  tap("space")
  wait(0.25)
  VP.shot("2ignition")
  wait(1.5)
  local fl = nil
  for _, c in ipairs(vn:children()) do
    for _, g in ipairs(c:children()) do if g.name == "Engine Flame" then fl = g end end
  end
  P("FD rocket: anchored %s, flame node %s playing %s", tostring(assembly.info(vn).anchored), tostring(fl ~= nil),
    tostring(fl and fl:particles() and fl:particles():isPlaying()))
  FD.frame_line("pad", vn, fl)
  FD.burst("3pad_burn", 4, 0.1)
  ground_cam(40, 4, 4)
  wait(0.2)
  VP.shot("4pad_wide")
  VP.stats("pad")
  -- the climb, from the ground where the camera stands
  if assembly.info(vn).anchored then vc.releaseClamps() end
  vc.setSAS("stability")
  wait(0.3)
  FD.burst("4b_liftoff", 4, 0.2)
  wait(1.5)
  FD.frame_line("climb", vn, fl)
  -- from the ground 45 m off, looking up at it
  do
    local b1 = home()
    local c1 = vn:toWorld(vec3(0, 0, 0))
    local U1 = unit(sub(c1, b1))
    local Rt = unit(cross(Fx, U1))
    local e = { x = c1.x + Rt.x * 45 - U1.x * 6, y = c1.y + Rt.y * 45 - U1.y * 6, z = c1.z + Rt.z * 45 - U1.z * 6 }
    -- (6 m below the craft's centre, which is >10 m up by now)
    VP.cam_fixed_at(sub(e, b1), vn)
  end
  wait(0.3)
  FD.burst("5climb", 4, 0.25)
  -- riding along beside it
  VP.cam_chase(vn, 12, 0, -4, 0, function() return Fx end)
  wait(0.3)
  FD.frame_line("climb2", vn, fl)
  FD.burst("6climb_chase", 3, 0.15)
  P("FD RESULT rocket: done")
end
