-- ── vfx probe (tools/perf/vfxprobe.sh): the vehicle feedback effects ────────
-- (scripts/vehicle_fx.lua, docs/vfx-feedback.md). Spliced into a copy of
-- perfbench.lua before its main; one table of functions (perfbench's main
-- chunk is near Lua's 200-locals ceiling).
--   vfxjet     the 27-part jet: cold on the runway, the take-off roll at full
--              throttle (plume, shimmer, soot, nozzle heat), low flight, the
--              throttle cut and the nozzle cooling
--   vfxrover   the 6-part rover: a slide on the runway (rubber, smoke), out
--              onto loose ground (tread prints, dust), a hard stop, a slide
--   vfxrocket  the starter rocket under power (bell heat, ignition), the cut
--              (cooling, shimmer), then put into a fast fall through the air
--              (reentry: plasma, wake, hull glow lingering after it)
--   vfxdamage  the rover beaten up: shorting sparks and smoke, scuffs
-- Pictures: 1280x720, save/user/vfxshots/<mode>_<name>.png in the scratch
-- project. Each phase is a perfbench scenario (PB RESULT lines: scripts,
-- particles, effects, decals, GPU passes) and VFX lines from vehicle_fx.stats().
local VP = { cam = nil, shots = 0 }
VP.TAG = "vfx"

function VP.shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://vfxshots/" .. VP.TAG .. "_" .. nm .. ".png", bytes); P("VFX SHOT %s_%s", VP.TAG, nm)
    else P("VFX SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("VFX capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
  VP.shots = VP.shots + 1
end

function VP.stats(tag)
  local vf = findScript("vehicle_fx")
  local s = vf and vf.stats and vf.stats() or {}
  local c = perf.counts() or {}
  P("VFX STATS %s: tier %s jets %s heat %s hot %s writes %s marks %s quads %s decalsLaid %s quadsLaid %s dust %s smoke %s sparks %s shorts %s skid_m %.1f wake %s | particles %s effects %s effectsDropped %s decals %s decalTris %s lights %s draws %s",
    tag, tostring(s.tier), tostring(s.jets), tostring(s.heat), tostring(s.hot), tostring(s.writes), tostring(s.marks), tostring(s.quads),
    tostring(s.decals), tostring(s.laidQuads), tostring(s.dust), tostring(s.smoke), tostring(s.sparks), tostring(s.shorts), s.skid_m or 0,
    tostring(s.wake), tostring(c.particles), tostring(c.effects), tostring(c.effectsDropped), tostring(c.decals), tostring(c.decalTris),
    tostring(c.lights), tostring(c.draws))
  local ms = perf.scriptMs and perf.scriptMs("vehicle_fx") or -1
  P("VFX COST %s: vehicle_fx %.3f ms, vfx %.3f ms (smoothed)", tag, ms, perf.scriptMs and perf.scriptMs("vfx") or -1)
end

-- THE CAMERA: a function giving the eye and the target in the world every
-- frame (the planet moves; nothing is kept across frames), applied through
-- planet_camera's freecam in lateUpdate.
function lateUpdate(node, dt)
  local f = VP.cam
  if not f then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt = f()
  if not eye then return end
  local name = space.dominant(eye.x, eye.y, eye.z)
  local b = name and space.body(name)
  if not b then return end
  pc.setFreecam(true)
  local fc = pc.freecamState and pc.freecamState()
  if not fc then return end
  local bp = vec3(b.x, b.y, b.z)
  local pos = vec3(eye.x, eye.y, eye.z) - bp
  local u = pos:normalized()
  fc.body = name
  fc.rel = pos
  local d = vec3(tgt.x - eye.x, tgt.y - eye.y, tgt.z - eye.z)
  local h = d:flatten(u)
  fc.ref = h:normalized()
  fc.pitch = math.atan2(d:dot(u), h:length())
end
function VP.cam_off()
  VP.cam = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end

-- A camera held in a node's own frame: eye and target given in its local axes.
function VP.cam_local(n, ex, ey, ez, tx, ty, tz)
  VP.cam = function()
    if not n.valid then return nil end
    local e, t = n:toWorld(vec3(ex, ey, ez)), n:toWorld(vec3(tx, ty, tz))
    return e, t
  end
end
-- A camera off a craft along the planet's frame: `back` m behind its motion
-- (or along `fwd` when still), `side` to its right, `up` over it, looking at
-- a point `ahead` m along the motion from its centre.
function VP.cam_chase(vn, back, side, upm, ahead, fixdir)
  VP.cam = function()
    if not vn.valid then return nil end
    local i = assembly.info(vn)
    local b = home()
    local name = space.dominant(i.com.x, i.com.y, i.com.z)
    local bb = name and space.body(name) or b
    local U = unit(sub(i.com, bb))
    local v = i.vel  -- (planet-relative already)
    local vh = sub(v, scl(U, dot(v, U)))
    local F
    if fixdir then F = fixdir() elseif len(vh.x, vh.y, vh.z) > 1.5 then F = unit(vh) else F = VP.lastF or unit(cross(U, { x = 0.3, y = 0.9, z = 0.1 })) end
    VP.lastF = F
    local Rt = unit(cross(F, U))
    local e = { x = i.com.x - F.x * back + Rt.x * side + U.x * upm, y = i.com.y - F.y * back + Rt.y * side + U.y * upm,
                z = i.com.z - F.z * back + Rt.z * side + U.z * upm }
    local t = { x = i.com.x + F.x * ahead, y = i.com.y + F.y * ahead, z = i.com.z + F.z * ahead }
    return e, t
  end
end
-- A fixed point on the planet (kept planet-relative) looking at a moving craft.
function VP.cam_fixed_at(rel, vn)
  VP.cam = function()
    local b = home()
    if not (b and vn.valid) then return nil end
    local i = assembly.info(vn)
    return { x = b.x + rel.x, y = b.y + rel.y, z = b.z + rel.z }, i.com
  end
end
-- A fixed point on the planet looking at a planet-relative point.
function VP.cam_fixed(rel, trel)
  VP.cam = function()
    local b = home()
    if not b then return nil end
    return { x = b.x + rel.x, y = b.y + rel.y, z = b.z + rel.z }, { x = b.x + trel.x, y = b.y + trel.y, z = b.z + trel.z }
  end
end

function VP.launch_plane()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local list = {}
  for _, r in ipairs(plane()) do
    local def = pa and pa.PARTS[r.id]
    if def then list[#list + 1] = full(r, def, k) end
  end
  save.set("shipyard.blueprint", { parts = list, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#list, 150)
  wait_regrade()
  return vc
end

-- The jet's nose in the world (its control frame: AERO.frame.n, vessel frame).
function VP.nose(vc)
  return function()
    local vn = vc.node
    local F = vc.AERO and vc.AERO.frame
    -- (before the first aero tick there is no frame yet: perfbench's jet is
    -- built nose along the blueprint's +X)
    local n = F and F.n or { x = 1, y = 0, z = 0 }
    local o = vn:toWorld(vec3(0, 0, 0))
    local w = vn:toWorld(vec3(n.x, n.y, n.z))
    return unit({ x = w.x - o.x, y = w.y - o.y, z = w.z - o.z })
  end
end
-- ── vfxjet ─────────────────────────────────────────────────────────────────
function VP.run_jet()
  VP.TAG = "jet"
  local vc = VP.launch_plane()
  if not vc then P("VFX RESULT jet: no craft"); return end
  local vn = vc.node
  clear_weather()
  -- behind and to the side of the jet, along its nose (the nozzle ~3 m aft)
  local nose = VP.nose(vc)
  VP.cam_chase(vn, 13, 7, 2.5, -2, nose)
  wait(1.5)
  VP.shot("1cold")
  vc.releaseClamps()
  vc.setSAS("stability")
  -- spool up on the runway: a few seconds at 0.35, then full, held on the brakes
  -- by the stick's neutral (it rolls; the camera rides along)
  sc_begin("vfx_jet_spool")
  vc.setThrottle(0.35)
  for k = 1, 3 do wait(1) end
  VP.stats("spool35")
  VP.shot("2spool35")
  sc_end("vfx_jet_spool")
  sc_begin("vfx_jet_full")
  local t0, shot3, shot4, shot5 = time, false, false, false
  local air = 0
  while vn.valid and time - t0 < 30 do
    yield()
    vc.setThrottle(1)
    local i = assembly.info(vn)
    local V = len(i.vel.x, i.vel.y, i.vel.z)
    vc.AERO.cmd = { p = V > 32 and -0.5 or 0, y = 0, r = 0 }
    local t = time - t0
    if t > 2.0 and not shot3 then shot3 = true; VP.stats("full2s"); VP.shot("3full_side") end
    if t > 3.5 and not shot4 then shot4 = true; VP.cam_chase(vn, 16, 1.2, 1.0, 0, nose); wait(0.3); VP.shot("4full_rear") end
    if t > 5.5 and not shot5 then shot5 = true; VP.cam_chase(vn, 7.5, 3.0, 0.6, -3, nose); wait(0.3); VP.shot("5nozzle_close"); VP.cam_chase(vn, 13, 7, 2.5, -2, nose) end
    if math.floor(t) ~= math.floor(t - dt) then VP.wheels_line(string.format("roll%.0f V%.0f", t, V)) end
    if not vc.R2.onWheels and i.grounded == false then air = air + dt else air = 0 end
    if air > 1.5 and t > 8 then break end
  end
  VP.stats("roll_end")
  sc_end("vfx_jet_full")
  -- low flight at full power: soot trail and (if cold enough up here) a contrail
  sc_begin("vfx_jet_flight")
  VP.cam_chase(vn, 22, 9, 4, 0, nose)
  t0 = time
  while vn.valid and time - t0 < 10 do
    yield()
    vc.setThrottle(1)
    vc.AERO.cmd = { p = -0.25, y = 0, r = 0 }
    if time - t0 > 6 and not VP.f1 then VP.f1 = true; VP.stats("flight6s"); VP.shot("6flight") end
  end
  sc_end("vfx_jet_flight")
  -- the cut: the plume goes, the nozzle glows on and cools
  vc.setThrottle(0)
  VP.cam_chase(vn, 7.5, 3.0, 0.6, -3, nose)
  wait(1.0)
  VP.stats("cut1s")
  VP.shot("7cut1s")
  wait(4.0)
  VP.stats("cut5s")
  VP.shot("8cut5s")
  local vf = findScript("vehicle_fx")
  P("VFX RESULT jet: jets %s, hot parts %s after the cut", tostring(vf and vf.stats().jets), tostring(vf and vf.stats().hot))
end

-- ── vfxrover ───────────────────────────────────────────────────────────────
function VP.away_key(vn, u)
  local i1 = assembly.info(vn)
  local Rh = unit(sub(i1.com, home()))
  local away = sub(Rh, scl(u, dot(Rh, u)))
  local v = i1.vel
  local vh = sub(v, scl(Rh, dot(v, Rh)))
  if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
    away = unit(away)
    local sn = dot(cross(unit(vh), away), Rh)
    local cs = dot(unit(vh), away)
    if cs < 0.97 then return sn >= 0 and "a" or "d" end
  end
  return nil
end
-- Drive through the controller's probe command (a headless run cannot
-- press keys): drive -1..1, steer +1 = A (left).
function VP.drive(vc, d, st) vc.R2.cmd = { drive = d or 0, steer = st or 0 } end
function VP.steer_of(want) return want == "a" and 1 or (want == "d" and -1 or 0) end
-- A sideways shove at the centre of mass: the rover slides on its tyres.
function VP.shove(vn, dv)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local v = i.vel
  local vh = sub(v, scl(U, dot(v, U)))
  local F = len(vh.x, vh.y, vh.z) > 0.5 and unit(vh) or unit(cross(U, { x = 0, y = 0, z = 1 }))
  local Rt = unit(cross(F, U))
  assembly.impulseAt(vn, vec3(Rt.x * dv * i.mass, Rt.y * dv * i.mass, Rt.z * dv * i.mass), vec3(i.com.x, i.com.y, i.com.z))
  P("VFX shove %.1f m/s sideways at %.1f m/s", dv, len(vh.x, vh.y, vh.z))
end
function VP.wheels_line(tag)
  local vf = findScript("vehicle_fx")
  local out = {}
  for _, w in ipairs(vf and vf.wheelStats and vf.wheelStats() or {}) do
    out[#out + 1] = string.format("%s%s slip %.1f spd %.1f", w.ground and "G" or "a", w.paved and "P" or (w.hard and "H" or "L"), w.slip, w.spd)
  end
  P("VFX WHEELS %s: %s", tag, table.concat(out, " | "))
end
function VP.run_rover()
  VP.TAG = "rover"
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then P("VFX RESULT rover: no craft"); return end
  local vn = vc.node
  clear_weather()
  vc.releaseClamps()
  vc.setSAS("stability")
  wait(2)
  local u = base_frame()
  do  -- the velocity frame, at rest: physics velocities are planet-relative
    local i, b = assembly.info(vn), home()
    P("VFX FRAME parked: |info.vel| %.2f m/s, the planet's |v| %.1f m/s", len(i.vel.x, i.vel.y, i.vel.z), len(b.vx or 0, b.vy or 0, b.vz or 0))
  end
  local function look_back(h, back, ahead)
    local i = assembly.info(vn)
    local b = home()
    local U = unit(sub(i.com, b))
    local F = VP.lastF or unit(cross(U, { x = 0, y = 0, z = 1 }))
    local eye = sub({ x = i.com.x + U.x * h + F.x * ahead, y = i.com.y + U.y * h + F.y * ahead, z = i.com.z + U.z * h + F.z * ahead }, b)
    local tgt = sub({ x = i.com.x - F.x * back, y = i.com.y - F.y * back, z = i.com.z - F.z * back }, b)
    VP.cam_fixed(eye, tgt)
  end
  -- 1) on the runway: up to speed, a shove sideways (a slide on the paving)
  sc_begin("vfx_rover_paved")
  VP.cam_chase(vn, 9, 4, 3.2, 2)
  VP.drive(vc, 1, 0)
  wait(6)
  VP.wheels_line("paved_run")
  VP.shove(vn, 6)
  for k = 1, 12 do wait(0.1); if k % 4 == 0 then VP.wheels_line("slide" .. k) end end
  VP.stats("paved_slide")
  VP.shot("1paved_slide")
  VP.shove(vn, -6)
  wait(1.2)
  -- a hard stop: full reverse at speed
  VP.drive(vc, -1, 0)
  for k = 1, 10 do wait(0.15); if k % 5 == 0 then VP.wheels_line("pstop" .. k) end end
  VP.drive(vc, 0, 0)
  wait(2.0)
  VP.stats("paved_after")
  look_back(6, 14, 6)
  wait(0.5)
  VP.shot("2paved_marks")
  sc_end("vfx_rover_paved")
  -- 2) out over loose ground: tread prints and dust
  sc_begin("vfx_rover_loose")
  VP.cam_chase(vn, 9, 4, 3.2, 2)
  local t0 = time
  while time - t0 < 40 do
    yield()
    VP.drive(vc, 1, VP.steer_of(VP.away_key(vn, u)))
    local vf = findScript("vehicle_fx")
    local loose = 0
    for _, w in ipairs(vf and vf.wheelStats and vf.wheelStats() or {}) do if w.ground and not w.hard then loose = loose + 1 end end
    if loose >= 3 and time - t0 > 6 and not VP.l1 then VP.l1 = time end
    if VP.l1 and time - VP.l1 > 5 then break end
  end
  VP.wheels_line("loose_run")
  VP.stats("loose_run")
  VP.shot("3loose_drive")
  -- a hard stop on loose ground, then a slide
  VP.drive(vc, -1, 0)
  wait(1.5)
  VP.stats("loose_stop")
  VP.drive(vc, 1, 0)
  wait(4)
  VP.shove(vn, 6)
  for k = 1, 10 do wait(0.1); if k % 5 == 0 then VP.wheels_line("lslide" .. k) end end
  VP.stats("loose_slide")
  VP.shot("4loose_slide")
  VP.drive(vc, 0, 0)
  wait(2.0)
  look_back(7, 16, 5)
  wait(0.6)
  VP.shot("5loose_tracks")
  VP.stats("loose_end")
  sc_end("vfx_rover_loose")
  -- 3) a drift sequence: a shove every 1.5 s, a picture every 0.5 s
  sc_begin("vfx_rover_drift")
  VP.cam_chase(vn, 10, 6, 4, 0)
  VP.drive(vc, 1, 0)
  wait(3)
  for k = 1, 6 do
    if k % 3 == 1 then VP.shove(vn, (k % 2 == 1) and 5 or -5) end
    VP.drive(vc, 1, (k % 2 == 1) and 1 or -1)
    wait(0.5)
    VP.shot(string.format("6drift_%d", k))
  end
  VP.stats("drift")
  VP.drive(vc, 0, 0)
  wait(1.5)
  look_back(7, 14, 4)
  wait(0.5)
  VP.shot("7drift_marks")
  sc_end("vfx_rover_drift")
  vc.R2.cmd = nil
  P("VFX RESULT rover: done")
  return vc
end

-- ── vfxrocket: engine heat, then reentry ───────────────────────────────────
function VP.run_rocket()
  VP.TAG = "rocket"
  local vc = launch_via_builder(rocket_bp(2), "pad", 5)
  if not vc then P("VFX RESULT rocket: no craft"); return end
  local vn = vc.node
  clear_weather()
  local b = home()
  -- the engine is at the stack's foot: look at it from the side, low
  VP.cam_local(vn, 6.5, 0.6, 3.5, 0, 0.6, 0)
  wait(1)
  VP.shot("1pad")
  sc_begin("vfx_rocket_burn")
  vc.setThrottle(1)
  tap("space")
  wait(0.5)
  if assembly.info(vn).anchored then vc.releaseClamps() end
  vc.setSAS("stability")
  wait(0.4)
  VP.shot("2ignition")
  for k = 1, 6 do wait(1) end
  VP.stats("burn7s")
  VP.shot("3burn7s")
  sc_end("vfx_rocket_burn")
  vc.setThrottle(0)
  wait(1.0)
  VP.stats("cut1s")
  VP.shot("4cut1s")
  wait(3.0)
  VP.shot("5cut4s")
  -- REENTRY: put it high in the air, falling fast and shallow
  local wd = save.get("world." .. b.name) or {}
  local H = (type(wd) == "table" and wd.atmoHeight) or b.radius * 0.35
  local i = assembly.info(vn)
  b = home()
  local U = unit(sub(i.com, b))
  local alt = (params.ralt or 0.35) * H
  local Rt = unit(cross(U, { x = 0, y = 1, z = 0 }))
  local to = { x = b.x + U.x * (b.radius + alt), y = b.y + U.y * (b.radius + alt), z = b.z + U.z * (b.radius + alt) }
  assembly.teleport(vn, vec3(to.x, to.y, to.z))
  for _ = 1, 4 do yield() end
  i = assembly.info(vn)
  b = home()
  local sp = params.rspeed or 150
  local ang = math.rad(params.rangle or 25)
  local want = { x = (Rt.x * math.cos(ang) - U.x * math.sin(ang)) * sp,
                 y = (Rt.y * math.cos(ang) - U.y * math.sin(ang)) * sp,
                 z = (Rt.z * math.cos(ang) - U.z * math.sin(ang)) * sp }
  -- The controller's safety net takes back a one-tick gain over KICK_TOL
  -- (6 m/s) and a sum over KICK_SUM in ~0.5 s that nothing aboard explains:
  -- the kick is given 5 m/s a frame with KICK_SUM (a global) lifted for it.
  local ks = vc.KICK_SUM
  vc.KICK_SUM = 1e9
  for _ = 1, 200 do
    i = assembly.info(vn)
    local dv = sub(want, i.vel)
    local m = len(dv.x, dv.y, dv.z)
    if m < 3 then break end
    local k = math.min(1, 5 / m)
    assembly.impulseAt(vn, vec3(dv.x * k * i.mass, dv.y * k * i.mass, dv.z * k * i.mass), vec3(i.com.x, i.com.y, i.com.z))
    yield()
  end
  vc.KICK_SUM = ks or 4.0
  for _ = 1, 3 do yield() end
  i = assembly.info(vn)
  P("VFX reentry kick: |v| %.0f after the impulse (asleep %s, anchored %s)", len(i.vel.x, i.vel.y, i.vel.z), tostring(i.asleep), tostring(i.anchored))
  P("VFX reentry: alt %.0f of air %.0f, %.0f m/s at %.0f deg down", alt, H, sp, params.rangle or 25)
  vc.setSAS("retrograde")
  sc_begin("vfx_reentry")
  -- in the rocket's own frame (its +Y is the stack's axis): from the side
  -- A camera standing in the air beside where the craft will be in ~1.5 s
  -- (planet-relative, so it holds still while the craft streaks past it).
  do
    local i0, b0 = assembly.info(vn), home()
    local v0 = i0.vel
    local U0 = unit(sub(i0.com, b0))
    local side = unit(cross(unit(v0), U0))
    local at = { x = i0.com.x + v0.x * 1.5, y = i0.com.y + v0.y * 1.5, z = i0.com.z + v0.z * 1.5 }
    local eye = { x = at.x + side.x * 28 + U0.x * 4, y = at.y + side.y * 28 + U0.y * 4, z = at.z + side.z * 28 + U0.z * 4 }
    VP.cam_fixed_at(sub(eye, b0), vn)
  end
  P("VFX reentry state: heating %.3f, |v| %.0f", vc.heating or -1, len(assembly.info(vn).vel.x, assembly.info(vn).vel.y, assembly.info(vn).vel.z))
  wait(0.6)
  for k = 1, 8 do
    wait(0.22)
    VP.shot(string.format("6reentry_%d", k))
    if k == 3 then VP.stats("reentry1s") end
  end
  -- from behind and above, riding along
  VP.cam_chase(vn, 30, 6, 8, 0)
  wait(0.4)
  VP.shot("7reentry_behind")
  VP.stats("reentry")
  local tr = time
  while vn.valid and time - tr < 20 do
    yield()
    local S = body_state(vn)
    if S and S.V < 60 then break end
  end
  sc_end("vfx_reentry")
  -- the afterglow: a camera held beside the craft where it slowed
  do
    local i0, b0 = assembly.info(vn), home()
    local U0 = unit(sub(i0.com, b0))
    local side = unit(cross(U0, { x = 0.3, y = 0.8, z = 0.5 }))
    VP.cam_fixed_at(sub({ x = i0.com.x + side.x * 7 + U0.x * 2, y = i0.com.y + side.y * 7 + U0.y * 2, z = i0.com.z + side.z * 7 + U0.z * 2 }, b0), vn)
  end
  wait(0.3)
  VP.stats("slowed")
  VP.shot("8afterglow")
  wait(2)
  VP.shot("9afterglow2s")
  local vf = findScript("vehicle_fx")
  P("VFX RESULT rocket: hot parts %s", tostring(vf and vf.stats().hot))
end

-- ── vfxdamage ──────────────────────────────────────────────────────────────
function VP.run_damage()
  VP.TAG = "damage"
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then P("VFX RESULT damage: no craft"); return end
  local vn = vc.node
  clear_weather()
  vc.releaseClamps()
  wait(2)
  for _, d in ipairs({ 1, 2, 3, 6 }) do if vc.wearPart then vc.wearPart(d, d == 1 and 0.15 or 0.3) end end
  VP.cam_chase(vn, 4.5, 3.0, 2.2, 0)
  sc_begin("vfx_damage")
  for k = 1, 6 do wait(0.5); VP.shot(string.format("1damaged_%d", k)) end
  VP.stats("damaged")
  sc_end("vfx_damage")
  P("VFX RESULT damage: %d damaged parts", #(vc.damagedParts and vc.damagedParts() or {}))
end
