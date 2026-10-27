-- ── moto probe (tools/perf/motoprobe.sh): the auto-engineering parts in flight (docs/auto-engineering.md) ──
-- Modes:
--   bike       a motorcycle (fork, swing arm, two moto wheels, a Moto Saddle, a
--              battery pack in the frame): a close-up of the rider astride it,
--              then driven out past 95 m from the base, a straight, a left and
--              a right turn, a slalom and a stop; then F to step off (EVA) and
--              F to get back on. Every half second: speed, lean and the lean
--              asked for, the bars, the forks, the rider's pose.
--              params gyro=1 adds a Balance Gyro.
--   car        a rover body on four coil-over struts with M wheels, out past
--              95 m, then a field of raised bumps (terrain.sculpt) driven
--              straight at ~10 m/s: the chassis's vertical acceleration (RMS,
--              peak) and each strut's travel. car_rigid: the same drive on the
--              stock rover (wheels straight on the body) for comparison.
--   trike      a fork and moto wheel in front, two moto wheels on struts
--              behind with floodlights on their outer axle ends: out, turns.
--   motoshop   each craft in the builder, and a parts sheet: pictures only.
-- Pictures land in $WORK/proj/save/user/motoshots/. Look for `MP RESULT`.
local MP_TAG = "moto"
local function mp_shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui == true, draws = false }, function(bytes)
    if bytes then assets.writeBytes("user://motoshots/" .. MP_TAG .. "_" .. nm .. ".png", bytes); P("MP SHOT %s_%s", MP_TAG, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end

-- the parts: the registry's and the auto library's
local function mp_defs()
  local R = findScript("parts_registry")
  local A = findScript("parts_auto")
  if not A then spawn("AutoLib", vec3(0, 0, 0)); A = wait_for(function() return findScript("parts_auto") end, 10, "parts_auto") end
  return function(id) return (A and A.PARTS and A.PARTS[id]) or (R and R.REG and R.REG[id]) end
end
local X1, Y1, Z1 = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
local function neg(a) return { x = -a.x, y = -a.y, z = -a.z } end
local function member(id, a, b, o)
  -- a drawn member from point a to point b (vessel frame), lying in the X–Y plane
  local d = { x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }
  local L = len(d.x, d.y, d.z)
  local Y = unit(d)
  local X = unit(cross(Y, Z1))
  if len(X.x, X.y, X.z) < 0.5 then X = X1 end
  local r = prec(id, (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, X, Y, o)
  r.size = { len = L, prof = "box" }
  r.proc, r.prof = "member", "box"
  return r
end

-- THE MOTORCYCLE (front +X; numbers from scripts/parts_auto.lua's frames):
-- the Moto Saddle's shroud butts the steering head, the battery pack hangs in
-- the frame under it (an electric bike's), the saddle stacks on a block at
-- the top of the seat stay, its pegs either side of that block.
local function mp_bike(gyro)
  puid = 0
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local H = add(prec("hub", 0.18, 1.068, 0, X1, Y1))                                    -- 1 the steering head block
  local F = add(prec("forkT", 0.7416, 0.7564, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  add(prec("wheelB", 0.8022, 0.3497, 0, Z1, Y1, { parent = F.uid, att = "surface" }))
  add(prec("packB", 0.12, 0.77, 0, X1, Y1, { parent = H.uid, att = "surface" }))        -- the battery, in the frame
  local hp, rp = { x = 0.18, y = 1.068, z = 0 }, { x = -0.03, y = 0.48, z = 0 }
  local sp = add(member("beamP", hp, rp, { parent = H.uid, att = "surface" }))          -- the down tube
  local R = add(prec("hub", rp.x, rp.y, 0, X1, Y1, { parent = sp.uid, att = "surface" }))
  local A = add(prec("swingArm", -0.485, 0.4826, 0, neg(X1), Y1, { parent = R.uid, att = "surface" }))
  add(prec("wheelB", -0.75, 0.35, 0, neg(Z1), Y1, { parent = A.uid, att = "surface" }))
  local sh = { x = -0.30, y = 0.79, z = 0 }
  local sf = add(member("beamP", rp, sh, { parent = R.uid, att = "surface" }))          -- the seat stay
  local S = add(prec("hub", sh.x, sh.y, 0, X1, Y1, { parent = sf.uid, att = "surface" }))
  if (params.oldseat or 0) > 0 then   -- A/B: the Command Seat on the same block
    add(prec("seat", sh.x, sh.y + 0.12 + 0.65, 0, X1, Y1, { parent = S.uid, att = "top" }))
  else
    add(prec("saddle", sh.x, sh.y + 0.12 + 0.65, 0, X1, Y1, { parent = S.uid, att = "top" }))
  end
  -- the gyro where an engine would be: on the rear block's front face, low
  if gyro then add(prec("gyro", rp.x + 0.12 + 0.2, rp.y, 0, X1, Y1, { parent = R.uid, att = "surface" })) end
  return L
end

-- THE CAR: a rover body on four struts, M wheels on their flanges
local function mp_car()
  puid = 0
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local B = add(prec("roverBody", 0, 0.68, 0, X1, Y1))
  local k = 0
  for _, sx in ipairs({ 0.55, -0.55 }) do
    k = k + 1
    for _, sz in ipairs({ 1, -1 }) do
      local X = { x = 0, y = 0, z = sz }
      local s = add(prec("strutS", sx, 0.65, sz * (0.5 + 0.1235), X, Y1, { parent = B.uid, att = "surface", sym = k, mir = "z" }))
      add(prec("wheelM", sx, 0.65 - 0.2275, sz * (0.5 + 0.247 + 0.2), X, Y1, { parent = s.uid, att = "surface", sym = 10 + k, mir = "z" }))
    end
  end
  add(prec("seat", 0, 0.68 + 0.15 + 0.65, 0, X1, Y1, { parent = B.uid, att = "top" }))
  return L
end

-- THE TRIKE: the bike's front end; behind, an axle beam with a strut each
-- end, a moto wheel on each strut's flange, and a floodlight on each wheel's
-- OUTER axle end (the through-axle: parts on both sides of a wheel)
local function mp_trike()
  puid = 0
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local H = add(prec("hub", 0.18, 1.068, 0, X1, Y1))
  local F = add(prec("forkT", 0.7416, 0.7564, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  add(prec("wheelB", 0.8022, 0.3497, 0, Z1, Y1, { parent = F.uid, att = "surface" }))
  add(prec("packB", -0.25, 1.068, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  local ax = { x = -0.85, y = 0.61, z = 0 }
  local sp = add(member("beamP", { x = 0.18, y = 1.068, z = 0 }, ax, { parent = H.uid, att = "surface" }))
  local AB = add(prec("beam1", ax.x, ax.y, 0, X1, Z1, { parent = sp.uid, att = "surface" }))   -- the axle beam, across
  for _, sz in ipairs({ 1, -1 }) do
    local X = { x = 0, y = 0, z = sz }
    local s = add(prec("strutS", ax.x, 0.5775, sz * (0.5 + 0.1235), X, Y1, { parent = AB.uid, att = "surface", sym = 1, mir = "z" }))
    local w = add(prec("wheelB", ax.x, 0.35, sz * (0.5 + 0.247 + 0.11), X, Y1, { parent = s.uid, att = "surface", sym = 2, mir = "z" }))
    add(prec("light", ax.x, 0.35, sz * (0.5 + 0.247 + 0.22 + 0.15), X, Y1, { parent = w.uid, att = "surface", sym = 3, mir = "z" }))
  end
  add(prec("seat", ax.x + 0.1, ax.y + 0.07 + 0.65, 0, X1, Y1, { parent = AB.uid, att = "top" }))
  return L
end

local function mp_full(list)
  local def = mp_defs()
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local out = {}
  for _, r in ipairs(list) do
    local d = def(r.id)
    if not d then P("MP NO DEF %s", r.id) else
      local f = full(r, d, k)
      if r.size then
        local R = findScript("parts_registry")
        local sz = R and R.sizeOf and R.sizeOf(d, r.size)
        f.size, f.proc, f.prof = r.size, r.proc, r.prof
        if sz then f.mass, f.cost, f.strength, f.rx, f.rz, f.h = sz.mass, sz.cost, sz.strength, sz.rx, sz.rz, sz.h end
      end
      out[#out + 1] = f
    end
  end
  return out, k
end

local function mp_builder_scene()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
end

local function mp_launch(list)
  mp_builder_scene()
  local recs, k = mp_full(list)
  save.set("shipyard.blueprint", { parts = recs, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#recs, 150)
  wait_regrade()
  return vc
end

-- the craft's state each tick: speed, distance run, the lean, the world up
local function mp_upness(vn)
  local i = assembly.info(vn)
  local b = home()
  if not (i and b) then return 1 end
  local U = unit(sub(i.com, b))
  local up = i.up or vn:worldUp()
  return dot(unit({ x = up.x, y = up.y, z = up.z }), U)
end

-- drive out past `out` m from the base, steering away from it (a bike leans)
local function mp_out(vc, out, drive)
  local vn = vc.node
  local u, _, _, R = base_frame()
  local function from_base()
    local p = sub(assembly.info(vn).com, home())
    return math.acos(clamp(dot(unit(p), u), -1, 1)) * R
  end
  local t0 = time
  while time - t0 < 90 do
    local i1 = assembly.info(vn)
    local Rh = unit(sub(i1.com, home()))
    local away = sub(Rh, scl(u, dot(Rh, u)))
    local v = i1.vel
    local vh = sub(v, scl(Rh, dot(v, Rh)))
    local st = 0
    if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
      away = unit(away)
      local sn = dot(cross(unit(vh), away), Rh)
      local cs = dot(unit(vh), away)
      if cs < 0.97 then st = (sn >= 0) and 0.5 or -0.5 end
    end
    vc.R2.cmd = { drive = drive or 0.7, steer = st }
    yield()
    if from_base() > out then break end
    if mp_upness(vn) < 0.3 then P("MP %s FELL on the way out", MP_TAG); return false, from_base end
  end
  P("MP %s out: %.0f m from the base after %.1f s", MP_TAG, from_base(), time - t0)
  return true, from_base
end

local function mp_line(vc, tag)
  local i = assembly.info(vc.node)
  local s = vc.motoState and vc.motoState() or {}
  local sp = {}
  for _, q in ipairs(s.susp or {}) do
    sp[#sp + 1] = string.format("%s comp %.3f peak %.3f/%.2f k %.0f→%.0f c %.2f→%.2f load %.2f%s", q.kind, q.comp or -1, q.peak or -1,
      q.travel or -1, q.k or -1, q.ke or -1, q.c or -1, q.ce or -1, q.load or -1, q.raked and " raked" or "")
  end
  local gr = 0
  local td = {}
  for _, w in ipairs(vc.R2.wheels or {}) do
    if w.tyre and w.tyre.valid then
      if w.tyre.grounded then gr = gr + 1 end
      local j = w.tyre:getcomponent("Joint")
      local tv = w.tyre.vel
      local dg = w.dbg or {}
      td[#td + 1] = string.format("t%d gr %s v(%.1f,%.1f,%.1f) j st %.1f pos %.2f f %.1f k %.1f z %.2f mot %s %.0f spin %.0f rs %d cur %.2f tgt %.2f lead %.2f mf %.2f", w.uid, tostring(w.tyre.grounded), tv and tv.x or 0, tv and tv.y or 0, tv and tv.z or 0,
        j and j.steer or -1, j and j.position or -1, j and j.force or -1, j and j.stiffness or -1, j and j.damping or -1, tostring(j and j.motor), j and j.motorSpeed or 0, j and j.speed or 0,
        w.rs or 0, dg.cur or 0, dg.tgt or 0, dg.lead or 0, j and j.maxForce or -1)
    end
  end
  if (params.fine or 0) > 0 then P("MP %s tyres vf %.2f fwd %.2f,%.2f (%s) lk %.2f | %s", MP_TAG, vc.R2.vf or 0, (vc.R2.fwd or {}).x or 0, (vc.R2.fwd or {}).z or 0, tostring(vc.R2.fwdWhy), vc.R2.lk or 0, table.concat(td, " | ")) end
  P("MP %s [%s] g %.2f tmax %.2f share %.2f v %.1f lean %.1f° (asked %.1f°) bars %.1f° torque %.2f alat %.2f yaw %.2f up %.3f on %d why %s | %s", MP_TAG, tag,
    s.g or 0, s.tmax or 0, s.share or 0, len(i.vel.x, i.vel.y, i.vel.z), math.deg(s.lean or 0), math.deg(s.leanT or 0), s.steer or 0, s.torque or 0, s.alat or 0, s.yaw or 0,
    mp_upness(vc.node), gr, tostring(vc.R2.why) .. (i.asleep and " ASLEEP" or "") .. " wake " .. tostring(i.wake), table.concat(sp, " | "))
end

-- what of the craft touches the ground: every part's collider box (world
-- extents along the local up) against the ground under it
local function mp_clear(vc, tag)
  local vn = vc.node
  local b = home()
  local i = assembly.info(vn)
  local U = unit(sub(i.com, b))
  local out = {}
  for _, ch in ipairs(vn:children()) do
    local rb = ch:getcomponent("RigidBody")
    if rb and rb.half_x then
      local p = ch:toWorld(vec3(0, 0, 0))
      if p then
        local rx, up, rz = ch:worldRight(), ch:worldUp(), ch:worldForward()
        local ext = math.abs(dot(rx, U)) * rb.half_x + math.abs(dot(up, U)) * rb.half_y + math.abs(dot(rz, U)) * rb.half_z
        local h = raycast(p.x + U.x * 3, p.y + U.y * 3, p.z + U.z * 3, -U.x, -U.y, -U.z, 8, { ignore = { vn } })
        if h then
          local gap = (3 - h.distance) - ext
          if gap < 0.08 then out[#out + 1] = string.format("%s gap %.3f (ext %.2f)", ch.name or "?", gap, ext) end
        end
      end
    end
  end
  for _, w in ipairs(vc.R2.wheels or {}) do
    local t = w.tyre
    if t and t.valid then
      local p = t:toWorld(vec3(0, 0, 0))
      local h = raycast(p.x + U.x * 3, p.y + U.y * 3, p.z + U.z * 3, -U.x, -U.y, -U.z, 8, { ignore = { vn, t } })
      if h then out[#out + 1] = string.format("tyre%d centre %.3f over ground (r %.2f)", w.uid, 3 - h.distance, w.r or 0) end
    end
  end
  P("MP %s CLEAR [%s] %s", MP_TAG, tag, table.concat(out, " | "))
end

-- one manoeuvre: R2.cmd held for `secs`; returns stats
local function mp_hold(vc, drive, steer, secs, tag, shot)
  local vn = vc.node
  local t0, nextl, shot_done = time, 0, false
  local st = { dist = 0, maxlean = 0, sumlean = 0, n = 0, minup = 1, vmax = 0, yaw = 0, fell = false }
  local last = assembly.info(vn).com
  local lastb = home()
  while time - t0 < secs do
    vc.R2.cmd = { drive = drive, steer = steer }
    if (params.ghostall or 0) > 0 then
      local a = find("Astronaut")
      if a then physics.ignorePair(a, vc.node) end
      for _, w in ipairs(vc.R2.wheels or {}) do
        if a and w.tyre and w.tyre.valid then physics.ignorePair(a, w.tyre) end
      end
    end
    yield()
    local i = assembly.info(vn)
    local b = home()
    local d = sub(sub(i.com, b), sub(last, lastb))
    st.dist = st.dist + len(d.x, d.y, d.z)
    last, lastb = i.com, b
    local s = vc.motoState and vc.motoState() or {}
    local ln = math.deg(s.lean or 0)
    st.maxlean = math.max(st.maxlean, math.abs(ln))
    if time - t0 > secs * 0.4 then st.sumlean, st.n = st.sumlean + ln, st.n + 1 end
    st.vmax = math.max(st.vmax, len(i.vel.x, i.vel.y, i.vel.z))
    local up = mp_upness(vn)
    st.minup = math.min(st.minup, up)
    if up < 0.3 then st.fell = true; P("MP %s FELL during %s", MP_TAG, tag); break end
    -- (params fine = s: every tick for the first s seconds of the stand, to see the tyres come out)
    local fine = tag == "stand" and time - t0 < (params.fine or 0)
    if fine or time - t0 >= nextl then
      nextl = nextl + (fine and 0 or 0.5); mp_line(vc, string.format("%s+%.2f", tag, time - t0))
      if (params.clear or 0) > 0 then mp_clear(vc, string.format("%s+%.2f", tag, time - t0)) end
    end
    if shot and not shot_done and time - t0 > secs * 0.6 then shot_done = true; mp_shot(tag) end
  end
  st.meanlean = st.n > 0 and st.sumlean / st.n or 0
  P("MP %s %s: %.1f m in %.1f s, top %.1f m/s, lean max %.1f° mean %.1f° (late), min up %.3f%s", MP_TAG, tag, st.dist, secs, st.vmax,
    st.maxlean, st.meanlean, st.minup, st.fell and " FELL" or "")
  return st
end

-- THE PROBE CAMERA (as vfxprobe's): eye and target from a function each
-- frame, applied through planet_camera's freecam in lateUpdate.
local MPC = {}
function lateUpdate(node, dt)
  local f = MPC.cam
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
  local pos = vec3(eye.x - b.x, eye.y - b.y, eye.z - b.z)
  local u = pos:normalized()
  fc.body, fc.rel = name, pos
  local d = vec3(tgt.x - eye.x, tgt.y - eye.y, tgt.z - eye.z)
  local h = d:flatten(u)
  fc.ref = h:normalized()
  fc.pitch = math.atan2(d:dot(u), h:length())
end
local function mp_cam_off()
  MPC.cam = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
-- a camera held in a node's frame (eye and target in its local axes)
local function mp_cam_local(n, ex, ey, ez, tx, ty, tz)
  MPC.cam = function()
    if not n.valid then return nil end
    return n:toWorld(vec3(ex, ey, ez)), n:toWorld(vec3(tx, ty, tz))
  end
end
-- the rider's seat script on this craft (command_seat on the saddle)
local function mp_seat(vc)
  for _, s in ipairs(findScripts("command_seat")) do
    if s.node and s.node.valid and s.node.parent and s.node.parent.id == vc.node.id then return s end
  end
end
local function mp_rider_line(vc, tag)
  local s = mp_seat(vc)
  local a = find("Astronaut")
  local ms = vc.motoState and vc.motoState() or {}
  P("MP %s rider [%s]: aboard %s seatpart %s riding %s hands %s visible %s bike %s rider %s", MP_TAG, tag, tostring(vc.crewAboard),
    tostring(s ~= nil), tostring(s and s.riding), tostring(s and s.hands), tostring(a and a.visible), tostring(ms.bike), tostring(ms.rider))
end

local function run_bike()
  local gy = (params.gyro or 0) > 0
  MP_TAG = gy and "bikegyro" or "bike"
  local vc = mp_launch(mp_bike(gy))
  if not vc then P("MP RESULT %s: no craft", MP_TAG); return end
  local vn = vc.node
  vc.releaseClamps()
  P("MP %s released: %d parts, mass %.3f t, rider %s", MP_TAG, #assembly.info(vn).parts, assembly.info(vn).mass, tostring(vc.crewAboard))
  -- stand still on the runway first: does it stay up?
  if (params.nobal or 0) > 0 then vc.R2.motoOff = true end
  local s0 = mp_hold(vc, 0, 0, 4, "stand", true)
  mp_rider_line(vc, "launch")
  -- the rider astride it, close: from the front-left and from the side
  -- (the stick held at rest meanwhile, as mp_hold does)
  local function still(secs)
    local t0 = time
    while time - t0 < secs do vc.R2.cmd = { drive = 0, steer = 0 }; yield() end
  end
  local seat = mp_seat(vc)
  if seat then
    mp_cam_local(seat.node, 1.5, 0.05, -1.3, -0.05, -0.4, 0.0)
    still(0.5); mp_shot("rider_close")
    mp_cam_local(seat.node, 0.1, -0.25, -2.3, 0.1, -0.6, 0.0)
    still(0.5); mp_shot("rider_side")
    mp_cam_off()
    still(0.3)
  end
  vc.R2.motoOff = nil
  local ok, from_base = mp_out(vc, 95, 0.7)
  if not ok then P("MP RESULT %s: FAIL (fell on the way out)", MP_TAG); return end
  local total = 0
  local a = mp_hold(vc, 1, 0, 8, "straight", true); total = total + a.dist
  if (params.short or 0) > 0 then P("MP RESULT %s short: straight %.1f m, top %.1f m/s", MP_TAG, a.dist, a.vmax); return end
  local l = mp_hold(vc, 0.6, 1, 5, "left", true); total = total + l.dist
  mp_rider_line(vc, "left")
  local r = mp_hold(vc, 0.6, -1, 5, "right", true); total = total + r.dist
  local fell = s0.fell or a.fell or l.fell or r.fell
  local sl = { dist = 0 }
  for n = 1, 4 do
    local x = mp_hold(vc, 0.7, (n % 2 == 1) and 0.6 or -0.6, 2.0, "slalom" .. n, n == 2); total = total + x.dist
    fell = fell or x.fell
  end
  local st = mp_hold(vc, 0, 0, 6, "stop", true)
  fell = fell or st.fell
  -- F: step off (EVA), then F: back on
  mp_rider_line(vc, "stopped")
  vc.R2.cmd = nil
  local function press_f() input.simulate { key = "f", down = true }; wait(0.2); input.simulate { key = "f", down = false }; wait(0.2) end
  press_f()
  wait_for(function() return not vc.crewAboard end, 5, "EVA")
  wait(1.5)
  mp_rider_line(vc, "eva")
  local seat2 = mp_seat(vc)
  if seat2 then mp_cam_local(seat2.node, 2.2, 0.5, -2.2, 0.0, -0.5, 0.0); wait(0.5); mp_shot("eva"); mp_cam_off() end
  local eva_ok = not vc.crewAboard
  press_f()
  wait_for(function() return vc.crewAboard end, 5, "board")
  wait(1.0)
  mp_rider_line(vc, "reboard")
  local s3 = mp_seat(vc)
  local board_ok = vc.crewAboard and s3 and s3.riding
  if s3 then mp_cam_local(s3.node, 1.5, 0.05, 1.3, -0.05, -0.4, 0.0); wait(0.5); mp_shot("reboard_close"); mp_cam_off() end
  P("MP RESULT %s seat: EVA %s, board %s", MP_TAG, eva_ok and "PASS" or "FAIL", board_ok and "PASS" or "FAIL")
  P("MP RESULT %s: %s — %.0f m ridden after the run-out (straight %.0f m at up to %.1f m/s), turns lean L %.1f° R %.1f°, standing lean max %.1f°, %.0f m from the base",
    MP_TAG, (not fell and total > 100 and l.meanlean > 3 and r.meanlean < -3) and "PASS" or "FAIL", total, a.dist, a.vmax,
    l.meanlean, r.meanlean, st.maxlean, from_base())
end

-- the bump field: raised mounds across the track every 3 m, from 8 m ahead
local function mp_bumps(vc, F, U, n)
  local i = assembly.info(vc.node)
  local Lt = unit(cross(U, F))
  local made, hsum, hn = 0, 0, 0
  for k = 0, n - 1 do
    local dd = 8 + 3 * k
    for _, lat in ipairs({ -1.0, 0.0, 1.0 }) do
      local p = { x = i.com.x + F.x * dd + Lt.x * lat, y = i.com.y + F.y * dd + Lt.y * lat, z = i.com.z + F.z * dd + Lt.z * lat }
      local h0 = raycast(p.x + U.x * 4, p.y + U.y * 4, p.z + U.z * 4, -U.x, -U.y, -U.z, 12, { ignore = { vc.node } })
      if h0 then
        terrain.sculpt(h0.x, h0.y, h0.z, params.bumpr or 0.55, params.bumps or 0.6, "raise")
        made = made + 1
      end
    end
  end
  wait(1.0)
  -- how high they came out (the ground at the first row's centre, before and after: 4 m up the ray)
  P("MP %s bumps: %d mounds in %d rows", MP_TAG, made, n)
  return made
end

local function run_car(rigid)
  MP_TAG = rigid and "car_rigid" or "car"
  local list = rigid and ROVER or mp_car()
  local vc
  if rigid then vc = launch_via_builder(ROVER, "runway", 6) else vc = mp_launch(list) end
  if not vc then P("MP RESULT %s: no craft", MP_TAG); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  local ok, from_base = mp_out(vc, 95, 0.6)
  if not ok then P("MP RESULT %s: FAIL (out)", MP_TAG); return end
  -- stop, square up, lay the bumps ahead
  mp_hold(vc, 0, 0, 3, "stop0", false)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local rx, up, rz = vn:worldRight(), vn:worldUp(), vn:worldForward()
  local Fv = vc.R2.fwd or { x = 1, z = 0 }
  local fw = { x = rx.x * Fv.x - rz.x * Fv.z, y = rx.y * Fv.x - rz.y * Fv.z, z = rx.z * Fv.x - rz.z * Fv.z }
  -- (worldForward is −Z: the vessel's +Z is −forward)
  fw = unit(sub(fw, scl(U, dot(fw, U))))
  local ground_h = {}
  local nrow = params.rows or 10
  mp_bumps(vc, fw, U, nrow)
  mp_shot("bumps", false)
  -- measure the bumps: the ground height along the line, every 0.25 m
  do
    -- (fresh: the planet has moved metres since the bumps were laid)
    i, b = assembly.info(vn), home()
    U = unit(sub(i.com, b))
    local prof, hmax, hmin = {}, -1e9, 1e9
    for k = 0, math.floor((8 + 3 * nrow) / 0.25) do
      local dd = k * 0.25
      local p = { x = i.com.x + fw.x * dd, y = i.com.y + fw.y * dd, z = i.com.z + fw.z * dd }
      local h = raycast(p.x + U.x * 4, p.y + U.y * 4, p.z + U.z * 4, -U.x, -U.y, -U.z, 12, { ignore = { vn } })
      if h then
        local hh = dot(sub({ x = h.x, y = h.y, z = h.z }, b), U)
        prof[#prof + 1] = hh
      end
    end
    -- the bumps' height: the profile minus a running mean over 2 m
    local amp = 0
    for k = 5, #prof - 4 do
      local m = 0
      for j = k - 4, k + 4 do m = m + prof[j] end
      amp = math.max(amp, prof[k] - m / 9)
    end
    P("MP %s ground profile along the track: %d samples, bump height over a 2 m mean up to %.3f m", MP_TAG, #prof, amp)
  end
  -- drive the field straight at a steady speed
  local t0 = time
  local start = sub(assembly.info(vn).com, home())
  local prev_vu, prev_t = nil, nil
  local acc, sum, sum2, n, peak = {}, 0, 0, 0, 0
  local speed_sum, speed_n = 0, 0
  local maxroll = 0
  while time - t0 < 14 do
    vc.R2.cmd = { drive = params.carv or 0.45, steer = 0 }
    yield()
    local ii = assembly.info(vn)
    local bb = home()
    local pr = sub(ii.com, bb)
    local Uh = unit(pr)
    local along = dot(sub(pr, start), fw)
    local vu = dot(ii.vel, Uh)
    if prev_vu and dt > 0 then
      local a = (vu - prev_vu) / dt
      if along > 6 and along < 8 + 3 * nrow + 2 then
        sum, sum2, n = sum + a, sum2 + a * a, n + 1
        peak = math.max(peak, math.abs(a))
        speed_sum, speed_n = speed_sum + len(ii.vel.x, ii.vel.y, ii.vel.z), speed_n + 1
      end
    end
    prev_vu = vu
    if math.floor((time - t0) / 0.5) ~= math.floor((time - t0 - dt) / 0.5) then mp_line(vc, string.format("bumps+%.1f (%.1f m)", time - t0, along)) end
    if along > 8 + 3 * nrow + 4 then break end
    if math.abs(time - t0 - 3.0) < dt * 0.6 then mp_shot("over_bumps", false) end
  end
  local mean = n > 0 and sum / n or 0
  local rms = n > 0 and math.sqrt(math.max(0, sum2 / n - mean * mean)) or -1
  local s = vc.motoState and vc.motoState() or { susp = {} }
  local peaks = {}
  for _, q in ipairs(s.susp or {}) do peaks[#peaks + 1] = string.format("%.3f", q.peak or 0) end
  P("MP RESULT %s: chassis vertical acceleration over the bumps RMS %.2f m/s² peak %.1f m/s² (%d ticks at %.1f m/s); strut peaks %s; %.0f m from the base",
    MP_TAG, rms, peak, n, speed_n > 0 and speed_sum / speed_n or 0, table.concat(peaks, " "), from_base())
end

local function run_trike()
  MP_TAG = "trike"
  local vc = mp_launch(mp_trike())
  if not vc then P("MP RESULT trike: no craft"); return end
  vc.releaseClamps()
  wait(2)
  local ok, from_base = mp_out(vc, 95, 0.6)
  if not ok then P("MP RESULT trike: FAIL (out)"); return end
  local a = mp_hold(vc, 0.8, 0, 6, "straight", true)
  local l = mp_hold(vc, 0.5, 1, 4, "left", true)
  local r = mp_hold(vc, 0.5, -1, 4, "right", false)
  mp_hold(vc, 0, 0, 3, "stop", true)
  local s = vc.motoState and vc.motoState() or {}
  P("MP RESULT trike: %s — bike %s, %d suspended wheels, %.0f m in the manoeuvres, %.0f m from the base",
    (not (a.fell or l.fell or r.fell) and a.dist + l.dist + r.dist > 50) and "PASS" or "FAIL", tostring(s.bike), #(s.susp or {}),
    a.dist + l.dist + r.dist, from_base())
end

-- each craft in the builder, and the parts laid out for a sheet
local function run_motoshop()
  MP_TAG = "shop"
  mp_builder_scene()
  local B = findScript("builder")
  local crafts = { { "bike", mp_bike(true) }, { "car", mp_car() }, { "trike", mp_trike() } }
  for _, c in ipairs(crafts) do
    local recs = mp_full(c[2])
    save.set("shipyard.blueprint", { parts = recs })
    B.reload()
    wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #recs end, 60, c[1])
    wait(2.5)
    P("MP shop %s: %d parts in the builder", c[1], B.partCount or -1)
    mp_shot("builder_" .. c[1], params.ui == 1)
    -- …and close: the craft framed, then turned a little
    local BC = findScript("builder_camera")
    if BC and BC.frameCraft and c[1] == "bike" then
      BC.frameCraft(); if BC.settle then BC.settle() end
      wait(0.5); mp_shot("builder_bike_framed", false)
      local st = BC.camState()
      BC.setCamState({ yaw = (st.yaw or 0) + 0.7, pitch = (st.pitch or 0), d = (st.d or 3) * 0.8 })
      wait(0.5); mp_shot("builder_bike_quarter", false)
    end
  end
  -- the parts sheet: each part on its own, side by side
  puid = 0
  local sheet = {}
  local xs = 0
  for _, id in ipairs({ "wheelB", "forkT", "swingArm", "strutS", "gyro", "packB", "saddle" }) do
    sheet[#sheet + 1] = prec(id, xs, 0.8, 0, X1, Y1)
    xs = xs + 1.15
  end
  local recs = mp_full(sheet)
  save.set("shipyard.blueprint", { parts = recs })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #recs end, 60, "sheet")
  wait(2.5)
  P("MP shop sheet: %d parts", B.partCount or -1)
  mp_shot("parts_sheet", params.ui == 1)
end

-- ── JETGEAR: the 27-part jet on landing gear placed every way the builder allows ──
-- (playtest 2026-10-26: "sometimes the jet / aircraft's landing gear points in
-- the wrong direction or is like fighting and it makes the aircraft jump
-- around crazily"). strs/params gearv:
--   0 stock · 1 every gear turned 90° on its leg (Y across: a gear hung from a
--   hub block or a plate) · 2 turned 180° (Y aft) · 3 the mains' legs splayed
--   25° out, the nose gear turned 90° · 4 the gear swapped for Rover Wheel M on
--   the belly (axle upright) and flanks · 5 the left main turned 90°, the right
--   one 180° (a symmetry pair placed by hand)
-- Phases: stand (brakes), taxi straight then rudder left and right at a
-- third throttle, take-off roll at full throttle, climb to ~12 m, throttle
-- cut and a gliding landing, the roll-out. On every tick on the wheels: the
-- CoM's vertical acceleration (radial, |Δv|/dt), the pitch and roll rates and
-- the tyres' contact flicker. One `MP RESULT jetgear` line.
local function jg_defs()
  local R = findScript("parts_registry")
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  return function(id) return (pa and pa.PARTS and pa.PARTS[id]) or (R and R.REG and R.REG[id]) end
end
local function jg_turn(r, X, Y)
  local Z = cross(X, Y)
  r.yaw, r.pitch, r.roll = eulerOf(X, Y, Z)
end
local function jg_bp(v)
  local L = plane()
  local leftDone = false
  for _, r in ipairs(L) do
    if r.id == "gearS" or r.id == "gearM" then
      local X, Y = basis(r)
      local Z = cross(X, Y)
      local main = r.id == "gearM"
      if v == 1 then jg_turn(r, X, Z)
      elseif v == 2 then jg_turn(r, X, { x = -Y.x, y = -Y.y, z = -Y.z })
      elseif v == 3 then
        if main then
          local s = r.z >= 0 and 1 or -1
          local a = math.rad(25)
          local Xn = unit({ x = 0, y = -math.cos(a), z = s * math.sin(a) })
          jg_turn(r, Xn, Y)
        else jg_turn(r, X, Z) end
      elseif v == 5 and main then
        if r.z >= 0 then jg_turn(r, X, Z) else jg_turn(r, X, { x = -Y.x, y = -Y.y, z = -Y.z }) end
      elseif v == 4 then
        -- a Rover Wheel M where each gear was, hung straight down (+X down:
        -- its axle upright, the case the flight lays across the nose)
        r.id = "wheelM"
        jg_turn(r, { x = 0, y = -1, z = 0 }, { x = 1, y = 0, z = 0 })
        r.y = 0.4 + (0.20 - 0.13)
      end
    end
  end
  return L
end

local function run_jetgear()
  local v = params.gearv or 0
  MP_TAG = "jetgear" .. v
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  mp_builder_scene()
  local def = jg_defs()
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local recs = {}
  for _, r in ipairs(jg_bp(v)) do
    local d = def(r.id)
    if d then recs[#recs + 1] = full(r, d, k) else P("MP NO DEF %s", r.id) end
  end
  save.set("shipyard.blueprint", { parts = recs, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#recs, 150)
  wait_regrade()
  if not vc then P("MP RESULT %s: no craft", MP_TAG); return end
  local vn = vc.node
  local bf = findScript("base_facilities")
  local site = bf and bf.launchSite and bf.launchSite("runway")
  local function W(vv)
    local rx, up, fw = vn:worldRight(), vn:worldUp(), vn:worldForward()
    return { x = rx.x * vv.x + up.x * vv.y - fw.x * vv.z, y = rx.y * vv.x + up.y * vv.y - fw.y * vv.z, z = rx.z * vv.x + up.z * vv.y - fw.z * vv.z }
  end
  local function st()
    local i = assembly.info(vn)
    local b = home()
    if not (i and b) then return nil end
    local F = vc.AERO and vc.AERO.frame
    local n = W(F and F.n or { x = 1, y = 0, z = 0 })
    local U = unit(sub(i.com, b))
    local r = unit(cross(n, U))
    local S = { i = i, U = U, n = n, r = r, V = len(i.vel.x, i.vel.y, i.vel.z), vu = dot(i.vel, U),
      theta = math.asin(clamp(dot(n, U), -1, 1)), bank = math.asin(clamp(dot(r, unit(W({ x = 0, y = 1, z = 0 }))), -1, 1)),
      q = dot(i.angVel, r), p = dot(i.angVel, n) }
    local h = raycast(i.com.x, i.com.y, i.com.z, -U.x, -U.y, -U.z, 400, { ignore = { vn } })
    S.agl = h and h.distance or 999
    if site then
      local Ng = unit(cross({ x = site.x, y = site.y, z = site.z }, site.fwd))
      local trk = unit(cross(Ng, U))
      local hn = unit(sub(n, scl(U, dot(n, U))))
      S.herr = math.atan2(dot(cross(hn, trk), U), dot(hn, trk))
    end
    return S
  end
  for _, w in ipairs(vc.R2.wheels or {}) do
    P("MP %s wheel %d %s gear %s steer0 %.1f realigned %s axle %.2f %.2f %.2f", MP_TAG, w.uid, w.d.id or "?", tostring(w.gear), w.steer0 or 0, tostring(w.realigned),
      w.axle[1], w.axle[2], w.axle[3])
  end
  vc.releaseClamps()
  vc.setSAS("stability")
  local M = {}
  local function phase(tag) M[tag] = M[tag] or { acc = 0, q = 0, p = 0, n = 0, flick = 0, vmax = 0, slip = 0 }; return M[tag] end
  local prev_vu, prev_g
  local function sample(tag, S)
    local m = phase(tag)
    local on = 0
    for _, w in ipairs(vc.R2.wheels or {}) do if w.tyre and w.tyre.valid and w.tyre.grounded then on = on + 1 end end
    if prev_vu and dt > 0 and on > 0 then
      m.acc = math.max(m.acc, math.abs(S.vu - prev_vu) / dt)
      m.q = math.max(m.q, math.abs(S.q))
      m.p = math.max(m.p, math.abs(S.p))
      m.n = m.n + 1
      -- sideways speed over the ground (along the right axis)
      m.slip = math.max(m.slip, math.abs(dot(S.i.vel, S.r)))
    end
    if prev_g and prev_g ~= on then m.flick = m.flick + 1 end
    prev_vu, prev_g = S.vu, on
    m.vmax = math.max(m.vmax, S.V)
  end
  local function run(tag, secs, ctl)
    local t0 = time
    local nextl = 0
    while time - t0 < secs do
      local S = st()
      if not S then break end
      local stop = ctl(S, time - t0)
      yield()
      local S2 = st()
      if S2 then sample(tag, S2) end
      if time - t0 >= nextl then
        nextl = nextl + 0.5
        P("MP %s [%s+%.1f] V %.1f agl %.2f vu %.2f theta %.1f bank %.1f q %.2f p %.2f herr %.1f on %s", MP_TAG, tag, time - t0, S.V, S.agl, S.vu,
          math.deg(S.theta), math.deg(S.bank), S.q, S.p, math.deg(S.herr or 0), tostring(vc.R2.onWheels))
      end
      if stop then break end
    end
  end
  local function hold_head(S, extra)
    return clamp(3.0 * (S.herr or 0) + (extra or 0), -1, 1)
  end
  -- (fine logging: every tick on the wheels from 25 m/s, the lift-off and the touchdown)
  local fine_on = false
  local base_run = run
  run = function(tag, secs, ctl)
    return base_run(tag, secs, function(S, t)
      local r = ctl(S, t)
      if fine_on and (params.finelog or 1) > 0 then
        local on = 0
        local td = {}
        for _, w in ipairs(vc.R2.wheels or {}) do
          local t = w.tyre
          if t and t.valid then
            if t.grounded then on = on + 1 end
            local j = t:getcomponent("Joint")
            local rb = t:getcomponent("RigidBody")
            local tv = t.vel
            td[#td + 1] = string.format("%d:%s pos %.3f f %.0f k %.1f z %.2f m %.3f tvu %.2f", w.uid, t.grounded and "G" or "-", j and (j.position or 0) / 57.29578 or -1,
              j and j.force or -1, j and j.stiffness or -1, j and j.damping or -1, rb and rb.mass or -1, tv and dot(tv, S.U) - dot(S.i.vel, S.U) or 0)
          end
        end
        P("MP %s tick %s+%.2f V %.1f agl %.2f vu %.2f theta %.1f q %.2f tyres down %d | %s", MP_TAG, tag, t, S.V, S.agl, S.vu, math.deg(S.theta), S.q, on, table.concat(td, " "))
      end
      return r
    end)
  end
  vc.setThrottle(0)
  run("stand", 3, function(S) vc.AERO.cmd = { p = 0, y = 0, r = 0 } end)
  local air, lift = 0, nil
  local D = math.rad
  run("roll", 45, function(S, t)
    vc.setThrottle(1)
    fine_on = S.V > 25 and t < 30
    local yaw = hold_head(S)
    if S.V < 40 then
      local p = (S.V > 15) and -clamp(3.0 * (D(1) - S.theta) - 1.0 * S.q, -1, 1) or 0
      vc.AERO.cmd = { p = p, y = yaw, r = clamp(-2.5 * S.bank, -1, 1) }
    else
      vc.AERO.cmd = { p = -clamp(4.0 * (D(9) - S.theta) - 1.6 * S.q, -1, 1), y = yaw, r = clamp(-2.5 * S.bank, -1, 1) }
    end
    if not vc.R2.onWheels and S.agl > 2.5 and S.V > 30 then air = air + dt else air = 0 end
    if air > 0.4 then lift = t; return true end
  end)
  fine_on = false
  P("MP %s takeoff: %s", MP_TAG, lift and string.format("airborne after %.1f s", lift) or "NO LIFT-OFF")
  local landed = nil
  if lift then
    -- a HOP: no higher than ~6 m, then straight back down onto the runway ahead
    run("hop", 3, function(S) vc.setThrottle(0.6); vc.AERO.cmd = { p = -clamp(4.0 * (D(4) - S.theta) - 1.6 * S.q, -1, 1), y = hold_head(S), r = clamp(-2.5 * S.bank, -1, 1) }
      return S.agl > 6 end)
    local first
    run("approach", 30, function(S, t)
      vc.setThrottle(0)
      local vt = S.agl > 3 and -2.0 or -1.0
      local th = clamp(D(3) + 0.08 * (vt - S.vu), D(-4), D(9))
      vc.AERO.cmd = { p = -clamp(4.0 * (th - S.theta) - 1.6 * S.q, -1, 1), y = hold_head(S), r = clamp(-2.5 * S.bank, -1, 1) }
      fine_on = S.agl < 3
      if vc.R2.onWheels then first = t; landed = true; return true end
    end)
    if landed then
      local touch_agl, bounce = nil, 0
      local t_on = 0
      run("land", 10, function(S, t)
        vc.setThrottle(0)
        fine_on = t < 2.5
        vc.AERO.cmd = { p = -clamp(4.0 * (D(1) - S.theta) - 1.6 * S.q, -1, 1), y = hold_head(S), r = clamp(-2.5 * S.bank, -1, 1) }
        touch_agl = touch_agl or S.agl
        bounce = math.max(bounce, S.agl - touch_agl)
        if t > 3 then vc.R2.cmd = nil; if vc.partAction then for _, w in ipairs(vc.R2.wheels or {}) do end end end
        if S.V < 8 then return true end
      end)
      fine_on = false
      P("MP %s touchdown: bounce %.2f m above the touchdown height", MP_TAG, bounce)
    end
  end
  -- the TAXI, after the roll-out: ~7 m/s straight, 30° off the heading each
  -- way and back (the nose gear steering with the rudder)
  local function taxi(S, tgt)
    vc.setThrottle(S.V < 7 and 0.3 or 0)
    vc.AERO.cmd = { p = 0, y = clamp(3.0 * ((S.herr or 0) - math.rad(tgt)), -1, 1), r = 0 }
  end
  if not lift or landed then
    run("taxi", 6, function(S) taxi(S, 0) end)
    run("taxiL", 5, function(S) taxi(S, -30) end)
    run("taxiR", 6, function(S) taxi(S, 30) end)
    run("square", 5, function(S) taxi(S, 0) end)
  end
  local fails = {}
  for _, tag in ipairs({ "stand", "roll", "land", "taxi", "taxiL", "taxiR", "square" }) do
    local m = M[tag]
    if m then
      P("MP %s %s: max vertical accel %.1f m/s², pitch rate %.2f rad/s, roll rate %.2f, side slip %.2f m/s, contact changes %d, top %.1f m/s (%d ticks on wheels)",
        MP_TAG, tag, m.acc, m.q, m.p, m.slip, m.flick, m.vmax, m.n)
      if m.acc > 30 or m.q > 1.0 then fails[#fails + 1] = tag end
    end
  end
  P("MP RESULT %s: %s — take-off %s, landing %s%s", MP_TAG, (#fails == 0 and lift and landed) and "PASS" or "FAIL",
    lift and "yes" or "NO", landed and "yes" or "no", #fails > 0 and (" | bouncing in " .. table.concat(fails, ",")) or "")
end

-- ── BIKELAB: a motorcycle built several ways, driven, climbed, slalomed, parked ──
-- params bikev (the build):
--   0 the probe bike · 1 its saddle on backwards (faces the swing arm) ·
--   2 the front wheel on a Coil-over Strut on the head's front face, not a
--   fork · 3 the battery on top of the steering head, not in the frame ·
--   4 the whole bike built facing +Z · 5 the whole bike built facing −X
--   (saddle, fork and arm turned with it)
-- params: hill=g (a ramp of grade g, e.g. 0.3, sculpted ahead and climbed),
--   slalom=n (n slalom runs of 6 gates), park=1 (stop, step off, 12 s parked).
-- Lines: `MP bikelab<v> …`, one `MP RESULT bikelab<v> <test>: PASS/FAIL …` a test.
local function bl_rot(L, yawq)
  -- turn a whole build about the vertical through the origin by yawq × 90°
  for _, r in ipairs(L) do
    local X, Y = basis(r)
    local function ry(v)
      local c, s = math.cos(yawq * math.pi / 2), math.sin(yawq * math.pi / 2)
      return { x = c * v.x + s * v.z, y = v.y, z = -s * v.x + c * v.z }
    end
    local p = ry({ x = r.x, y = r.y, z = r.z })
    r.x, r.y, r.z = p.x, p.y, p.z
    jg_turn(r, ry(X), ry(Y))
  end
  return L
end
local function bl_build(v)
  if v == 4 then return bl_rot(mp_bike(false), 1) end
  if v == 5 then return bl_rot(mp_bike(false), 2) end
  local L = mp_bike(v == 6)
  if v == 6 then
    -- no rider: a Probe Core where the saddle was, a Balance Gyro holding it up
    for _, r in ipairs(L) do
      if r.id == "saddle" then r.id = "probe"; r.y = 0.79 + 0.12 + 0.21 end
    end
  end
  for i, r in ipairs(L) do
    if v == 1 and r.id == "saddle" then
      local X, Y = basis(r)
      jg_turn(r, { x = -X.x, y = -X.y, z = -X.z }, Y)
    elseif v == 3 and r.id == "packB" then
      -- on top of the steering head block
      r.x, r.y, r.z = 0.18, 1.068 + 0.12 + 0.175, 0
      r.att = "top"
    elseif v == 2 and r.id == "forkT" then
      -- a strut on the head's front face (+X out), the wheel on its flange
      r.id = "strutS"
      r.x, r.y, r.z = 0.18 + 0.12 + 0.1235, 0.35 + 0.2275, 0
    elseif v == 2 and r.id == "wheelB" and r.parent == 2 then
      -- (the flange's "end" node: the wheel by its axle end, axle along +X)
      r.x, r.y, r.z = 0.18 + 0.12 + 0.247 + 0.11, 0.35, 0
      jg_turn(r, X1, Y1)
    end
  end
  return L
end

-- where the player sees the front: the fork's (or front strut's) wheel ahead
-- of the swing arm's, world, level
local function bl_seen_front(vc, recs)
  local f, a
  for _, r in ipairs(recs) do
    if r.id == "forkT" or r.id == "strutS" then f = r.uid elseif r.id == "swingArm" then a = r.uid end
  end
  local nf, na = f and vc.R2.node[f], a and vc.R2.node[a]
  if not (nf and na and nf.valid and na.valid) then return nil end
  local pf, pa = nf:toWorld(vec3(0, 0, 0)), na:toWorld(vec3(0, 0, 0))
  return unit(sub(pf, pa))
end

local function bl_ramp(vc, F, U, grade, len_m)
  local i = assembly.info(vc.node)
  local b = home()
  local base = i.com
  local h0 = raycast(base.x + U.x * 3, base.y + U.y * 3, base.z + U.z * 3, -U.x, -U.y, -U.z, 10, { ignore = { vc.node } })
  local g0 = h0 and { x = h0.x, y = h0.y, z = h0.z } or sub(base, scl(U, 0.65))
  local n = unit(sub(U, scl(F, grade)))
  local made = 0
  -- (in the planet's frame: the ramp is laid in one go, the planet moves meanwhile)
  local rel0 = sub(g0, b)
  local d = 5.0
  while d <= 5.0 + len_m + 2.5 do
    local up = math.max(0, d - 5.0) * grade
    if d > 5.0 + len_m then up = len_m * grade end
    local bb = home()
    local p = { x = bb.x + rel0.x + F.x * d + U.x * up, y = bb.y + rel0.y + F.y * d + U.y * up, z = bb.z + rel0.z + F.z * d + U.z * up }
    for _, lat in ipairs({ -1.2, 0, 1.2 }) do
      local L = unit(cross(U, F))
      local q = { x = p.x + L.x * lat, y = p.y + L.y * lat, z = p.z + L.z * lat }
      terrain.sculpt(q.x, q.y, q.z, 1.6, 1.0, "raise")
      terrain.sculpt(q.x, q.y, q.z, 1.8, 1.0, "flatten", { normal = vec3(n.x, n.y, n.z) })
      made = made + 1
    end
    d = d + 0.8
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20, "ramp")
  wait(0.5)
  -- the profile along the centreline
  local prof = {}
  local bb = home()
  for k = 0, math.floor((len_m + 9) / 0.5) do
    local dd = k * 0.5
    local p = { x = bb.x + rel0.x + F.x * dd + U.x * 6, y = bb.y + rel0.y + F.y * dd + U.y * 6, z = bb.z + rel0.z + F.z * dd + U.z * 6 }
    local h = raycast(p.x, p.y, p.z, -U.x, -U.y, -U.z, 14, { ignore = { vc.node } })
    prof[#prof + 1] = h and (6 - h.distance) or 0 / 0
  end
  -- the steepest 3 m stretch and the mean over the ramp
  local steep = 0
  for k = 1, #prof - 6 do
    local s = (prof[k + 6] - prof[k]) / 3
    if s == s then steep = math.max(steep, s) end
  end
  local a, z = prof[math.floor(5.5 / 0.5) + 1], prof[math.floor((5 + len_m - 0.5) / 0.5) + 1]
  local mean = (z and a) and (z - a) / (len_m - 1) or 0
  P("MP %s ramp: %d sculpts, mean grade %.0f%% over %.0f m, steepest 3 m %.0f%%, profile %s", MP_TAG, made, mean * 100, len_m, steep * 100,
    (function() local t = {} for k = 1, #prof, 2 do t[#t + 1] = string.format("%.2f", prof[k]) end return table.concat(t, " ") end)())
  return rel0, mean
end

local function run_bikelab()
  local v = params.bikev or 0
  MP_TAG = "bikelab" .. v
  local recs = bl_build(v)
  local vc = mp_launch(recs)
  if not vc then P("MP RESULT %s: no craft", MP_TAG); return end
  local vn = vc.node
  vc.releaseClamps()
  if (params.aerooff or 0) > 0 then vc.AERO.scale = 0 end
  if (params.tinyrider or 0) > 0 then
    -- A/B: the rider's capsule shrunk to nothing while they ride
    local a = find("Astronaut")
    local rb = a and a:getcomponent("RigidBody")
    if rb then P("MP %s rider capsule r %.2f h %.2f kinematic %s → tiny", MP_TAG, rb.radius or -1, rb.height or -1, tostring(rb.kinematic)); rb.radius = 0.01; rb.height = 0.02 end
  end
  if (params.norake or 0) > 0 then
    -- A/B: the fork steers and slides about the vertical, not its raked head
    local AD = findScript("auto_drive")
    if AD then AD.FALLBACK_DEG = -1; vc.R2.gen = -1; wait(0.5) end
  end
  do
    local c = assembly.info(vn).com
    local ok, wv = pcall(function() return weather and weather.windAt and weather.windAt(vec3(c.x, c.y, c.z)) end)
    P("MP %s wind %s aero scale %s", MP_TAG, (ok and wv) and string.format("%.1f %.1f %.1f (|%.1f| m/s)", wv.x, wv.y, wv.z, len(wv.x, wv.y, wv.z)) or "none", tostring(vc.AERO.scale))
  end
  P("MP %s released: %d parts, mass %.3f t, rider %s, front %.2f %.2f (%s), bike %s", MP_TAG, #assembly.info(vn).parts, assembly.info(vn).mass,
    tostring(vc.crewAboard), (vc.R2.fwd or {}).x or 0, (vc.R2.fwd or {}).z or 0, tostring(vc.R2.fwdWhy), tostring(vc.R2.bike))
  for _, w in ipairs(vc.R2.wheels or {}) do
    P("MP %s wheel %d: rs %d steer0 %.1f steers %s susp %s realigned %s", MP_TAG, w.uid, w.rs or 0, w.steer0 or 0, tostring(w.steers), w.susp and w.susp.m.kind or "-", tostring(w.realigned))
  end
  local st = mp_hold(vc, 0, 0, 3, "stand", false)
  local ok = not st.fell
  P("MP RESULT %s stand: %s (min up %.3f)", MP_TAG, ok and "PASS" or "FAIL", st.minup)
  -- W: which way does it go, against the front the player sees?
  local function seen() return bl_seen_front(vc, recs) end
  local function run_dir(drive, secs, tag)
    local b0, c0 = home(), assembly.info(vn).com
    local F = seen()
    local s = mp_hold(vc, drive, 0, secs, tag, false)
    local b1, c1 = home(), assembly.info(vn).com
    local d = sub(sub(c1, b1), sub(c0, b0))
    local along = F and dot(d, F) or 0
    return along, s
  end
  local function fwdW()
    local F = vc.R2.fwd or { x = 1, z = 0 }
    local rx, fw = vn:worldRight(), vn:worldForward()
    return unit({ x = rx.x * F.x - fw.x * F.z, y = rx.y * F.x - fw.y * F.z, z = rx.z * F.x - fw.z * F.z })
  end
  local function stop_it(tag)
    local t0 = time
    local fell = false
    while time - t0 < 6 do
      local v = assembly.info(vn).vel
      local sp = dot(v, fwdW())
      vc.R2.cmd = { drive = sp > 0.5 and -1 or (sp < -0.5 and 1 or 0), steer = 0 }
      yield()
      if mp_upness(vn) < 0.3 then fell = true break end
      if assembly.info(vn) and len(v.x, v.y, v.z) < 0.6 and time - t0 > 0.5 then break end
    end
    return fell
  end
  local fwd, s1 = run_dir(1, 4, "forward")
  P("MP RESULT %s forward: %s (%.1f m toward the front the player sees in 4 s, top %.1f m/s)", MP_TAG, (fwd > 10 and not s1.fell) and "PASS" or "FAIL", fwd, s1.vmax)
  stop_it("brake")
  local back, s2 = run_dir(-1, 3, "reverse")
  P("MP RESULT %s reverse: %s (%.1f m, top %.1f m/s)", MP_TAG, (back < -2 and not s2.fell) and "PASS" or "FAIL", back, s2.vmax)
  stop_it("stop")
  -- each run: up to ~8 m/s, four gates (lean left, right, left, right),
  -- then a U-turn and a stop, so the runs stay on the runway's apron
  if (params.slalom or 0) > 0 then
    local pass = 0
    for k = 1, params.slalom do
      local fell = mp_hold(vc, 0.5, 0, 2.5, "sl_run" .. k, false).fell
      for g = 1, 4 do
        if fell then break end
        fell = mp_hold(vc, 0.5, (g % 2 == 1) and 0.8 or -0.8, 1.5, "sl" .. k .. "_" .. g, false).fell
      end
      if not fell then
        -- the U-turn: full lean one way at a crawl until it faces back
        local f0 = fwdW()
        local t0 = time
        while time - t0 < 10 do
          vc.R2.cmd = { drive = 0.35, steer = 1 }
          yield()
          if mp_upness(vn) < 0.3 then fell = true break end
          if dot(fwdW(), f0) < -0.9 then break end
        end
      end
      if not fell then fell = stop_it("sl_stop" .. k) end
      if not fell then pass = pass + 1 end
      P("MP %s slalom run %d: %s", MP_TAG, k, fell and "FELL" or "upright")
      if fell then break end   -- (a fallen bike stays down)
    end
    P("MP RESULT %s slalom: %d / %d runs without a fall", MP_TAG, pass, params.slalom)
  end
  if (params.park or 0) > 0 then
    for _ = 1, 4 do
      stop_it("park_stop")
      input.simulate { key = "f", down = true }; wait(0.1); input.simulate { key = "f", down = false }
      wait_for(function() return not vc.crewAboard end, 1.5, "EVA")
      if not vc.crewAboard then break end
    end
    local a = find("Astronaut")
    local t0, minup = time, 1
    local nextl = 0
    while time - t0 < 12 do
      yield()
      minup = math.min(minup, mp_upness(vn))
      if time - t0 >= nextl then nextl = nextl + 1; P("MP %s parked+%.0f up %.3f aboard %s live %s", MP_TAG, time - t0, mp_upness(vn), tostring(vc.crewAboard), tostring(vc.R2.live)) end
    end
    P("MP RESULT %s park: %s (unridden 12 s, min up %.3f)", MP_TAG, (minup > 0.9 and not vc.crewAboard) and "PASS" or "FAIL", minup)
    -- back on for what follows
    input.simulate { key = "f", down = true }; wait(0.2); input.simulate { key = "f", down = false }
    wait_for(function() return vc.crewAboard end, 5, "board")
    wait(1.5)
  end
  if (params.hill or 0) > 0 then
    local g = params.hill
    local i = assembly.info(vn)
    local U = unit(sub(i.com, home()))
    local F = seen()
    F = unit(sub(F, scl(U, dot(F, U))))
    local lenm = params.hilllen or 14
    local rel0, mean = bl_ramp(vc, F, U, g, lenm)
    -- back up a little first: a run-up of 4 m at most, then W
    local t0, top, best = time, 0, 0
    local nextl = 0
    while time - t0 < 30 do
      vc.R2.cmd = { drive = 1, steer = 0 }
      yield()
      local ii = assembly.info(vn)
      local bb = home()
      local rel = sub(ii.com, bb)
      local along = dot(sub(rel, rel0), F)
      best = math.max(best, along)
      if time - t0 >= nextl then
        nextl = nextl + 0.5
        mp_line(vc, string.format("hill+%.1f (%.1f m along)", time - t0, along))
      end
      if mp_upness(vn) < 0.3 then P("MP %s FELL on the hill", MP_TAG); break end
      if along > 5 + lenm - 1.5 then top = time - t0; break end
    end
    P("MP RESULT %s hill: %s — %s, ramp mean grade %.0f%%, got %.1f m along (ramp %.0f–%.0f m)", MP_TAG, top > 0 and "PASS" or "FAIL",
      top > 0 and string.format("over the top in %.1f s", top) or "did not make the top", mean * 100, best, 5, 5 + lenm)
  end
end

-- ── SNAPBUILD: the bike and a strut car built IN THE BUILDER by its own snap ──
-- (playtest 2026-10-26: "hard to snap the parts together without turning the
-- grid off … it makes stuff slightly offset"). The builder's grid at 5 cm (the
-- hull grid 25 cm); each part is aimed through the builder's own query
-- (builder.attachQuery → builder_attach.best) at a point a few centimetres
-- off where it belongs, the cursor far from every node, and placed with the
-- builder's `place` command. Each joint is then measured: a wheel's centre
-- against its fork's / arm's hub or its strut's flange, a part's centre line
-- against the face it sits on. `MP SNAP` lines, one `MP RESULT snapbuild`,
-- and 1280×720 builder pictures.
local function run_snapbuild()
  MP_TAG = "snap"
  mp_builder_scene()
  local B = findScript("builder")
  local A = findScript("builder_attach")
  local R = findScript("parts_registry")
  if not (B and A and R and B.attachQuery) then P("MP RESULT snapbuild: FAIL (no builder API)"); return end
  B.setSnapGrid(0.05)
  P("MP SNAP grid %.2f m", B.snapGrid())
  local worst, n = 0, 0
  local function v3(x, y, z) return { x = x, y = y, z = z } end
  local function ap(Bb, p) return v3(Bb.X.x * p.x + Bb.Y.x * p.y + Bb.Z.x * p.z, Bb.X.y * p.x + Bb.Y.y * p.y + Bb.Z.y * p.z, Bb.X.z * p.x + Bb.Y.z * p.y + Bb.Z.z * p.z) end
  local function tw(r, p) local q = ap(r.B, p); return v3(r.x + q.x, r.y + q.y, r.z + q.z) end
  local function newcraft(id, x, y, z)
    save.set("shipyard.blueprint", { parts = {} })
    B.reload()
    wait(0.5)
    if #B.partUids() > 0 then B.cmd("delete", B.partUids()) end
    local u = B.cmd("place", { id = id, x = x, y = y, z = z })
    wait(0.3)
    return u
  end
  -- aim `id` at host's face point (host frame) with that face's normal (host frame)
  local function snap(id, host, off, nl, what)
    local hr = B.partRec(host)
    local P0 = tw(hr, off)
    local N = ap(hr.B, nl)
    local def = R.REG[id]
    local q = B.attachQuery({ def = def, id = id, off = A.IDENT }, {}, B.partUids(), { host, 0, P0, N })
    q.mouse = { x = -5000, y = -5000 }
    local c = A.best(q)
    if not c then P("MP SNAP %s: no candidate", what); worst = math.huge; return nil end
    local yaw, pitch, roll = B.basisEuler(c.B)
    local att = (c.kind == "stack") and c.side or "surface"
    local u = B.cmd("place", { id = id, x = c.x, y = c.y, z = c.z, yaw = yaw, pitch = pitch, roll = roll, parent = host, att = att })
    wait(0.2)
    return u, c
  end
  local function report(what, err)
    n = n + 1
    worst = math.max(worst, err)
    P("MP SNAP %-34s off by %.2e m %s", what, err, err < 1e-4 and "EXACT" or "OFFSET")
  end
  -- the in-face offset of a part's centre (or a given point) from the host face's centre
  local function centred(host, u, nl, pt)
    local hr, pr = B.partRec(host), B.partRec(u)
    local p = pt or v3(pr.x, pr.y, pr.z)
    local d = v3(p.x - hr.x, p.y - hr.y, p.z - hr.z)
    local l = v3(d.x * hr.B.X.x + d.y * hr.B.X.y + d.z * hr.B.X.z, d.x * hr.B.Y.x + d.y * hr.B.Y.y + d.z * hr.B.Y.z, d.x * hr.B.Z.x + d.y * hr.B.Z.y + d.z * hr.B.Z.z)
    if math.abs(nl.x) > 0.5 then return len(0, l.y, l.z) elseif math.abs(nl.y) > 0.5 then return len(l.x, 0, l.z) end
    return len(l.x, l.y, 0)
  end
  local function at_hub(wu, hu, hp)
    local wr, hr = B.partRec(wu), B.partRec(hu)
    local h = tw(hr, v3(hp[1], hp[2], hp[3]))
    return len(wr.x - h.x, wr.y - h.y, wr.z - h.z)
  end
  local function shot(nm)
    local BC = findScript("builder_camera")
    if BC and BC.frameCraft then BC.frameCraft(); if BC.settle then BC.settle() end end
    wait(1.0)
    mp_shot(nm, false)
    if BC and BC.camState then
      local st = BC.camState()
      BC.setCamState({ yaw = (st.yaw or 0) + 0.9, pitch = (st.pitch or 0) + 0.15, d = (st.d or 3) * 0.75 })
      wait(0.6)
      mp_shot(nm .. "_close", false)
    end
  end
  -- THE BIKE
  local H = newcraft("hub", 0, 1.068, 0)
  local F, cf = snap("forkT", H, v3(0.12, 0.04, -0.035), v3(1, 0, 0), "fork on the head's front face")
  if F then
    local mp = R.REG.forkT.mountpt
    report("fork head bracket on the face centre", centred(H, F, v3(1, 0, 0), cf.at))
    local W1 = snap("wheelB", F, v3(0.12, 0.25, 0.3), v3(0, 0, 1), "front wheel aimed at the fork's leg")
    if W1 then report("front wheel centre on the fork hub", at_hub(W1, F, R.REG.forkT.hubpt)) end
  end
  local K = snap("packB", H, v3(0.03, -0.12, 0.04), v3(0, -1, 0), "battery under the head")
  if K then report("battery centred under the head block", centred(H, K, v3(0, -1, 0))) end
  local Rr = B.cmd("place", { id = "hub", x = -0.03, y = 0.48, z = 0, parent = H, att = "surface" })
  wait(0.2)
  local Ar, ca = snap("swingArm", Rr, v3(-0.12, -0.03, 0.04), v3(-1, 0, 0), "swing arm on the rear block")
  if Ar then
    report("swing arm on the rear face centre", centred(Rr, Ar, v3(-1, 0, 0), ca.at))
    local W2 = snap("wheelB", Ar, v3(0.1, 0.05, 0.12), v3(0, 0, 1), "rear wheel aimed at the arm")
    if W2 then report("rear wheel centre in the arm's jaws", at_hub(W2, Ar, R.REG.swingArm.hubpt)) end
  end
  local S = snap("hub", Rr, v3(0.04, 0.12, -0.03), v3(0, 1, 0), "seat block on the rear block")
  if S then
    report("seat block centred on the rear block", centred(Rr, S, v3(0, 1, 0)))
    local Sd = snap("saddle", S, v3(0.035, 0.12, 0.025), v3(0, 1, 0), "saddle on the seat block")
    if Sd then report("saddle centred on its block", centred(S, Sd, v3(0, 1, 0))) end
  end
  P("MP SNAP bike: %d parts", #B.partUids())
  shot("snap_bike")
  -- THE STRUT CAR
  local Bd = newcraft("roverBody", 0, 0.68, 0)
  for _, sx in ipairs({ 0.53, -0.47 }) do
    for _, sz in ipairs({ 1, -1 }) do
      local St, cs = snap("strutS", Bd, v3(sx, 0.03, sz * 0.5), v3(0, 0, sz), string.format("strut %.2f %d", sx, sz))
      if St then
        local hr = B.partRec(Bd)
        report(string.format("strut %+.1f %+d on the body's centre line", sx, sz), math.abs(cs.at.y - hr.y))
        local Wm = snap("wheelM", St, v3(0.05, 0.2, 0.1), v3(0, 0, 1), "wheel aimed at the strut")
        if Wm then
          local sr, wr = B.partRec(St), B.partRec(Wm)
          local fl = tw(sr, v3(R.REG.strutS.hubs[1].p[1], R.REG.strutS.hubs[1].p[2], R.REG.strutS.hubs[1].p[3]))
          -- the wheel's own inner face (−X, its mount) on the flange
          local dW = R.REG.wheelM.rx or 0.2
          local inner = v3(wr.x - wr.B.X.x * dW, wr.y - wr.B.X.y * dW, wr.z - wr.B.X.z * dW)
          report(string.format("wheel %+.1f %+d on its strut's flange", sx, sz), len(inner.x - fl.x, inner.y - fl.y, inner.z - fl.z))
        end
      end
    end
  end
  local Se = snap("seat", Bd, v3(0.06, 0.15, -0.04), v3(0, 1, 0), "seat on the body")
  if Se then report("seat centred on the body", centred(Bd, Se, v3(0, 1, 0))) end
  P("MP SNAP car: %d parts", #B.partUids())
  shot("snap_car")
  P("MP RESULT snapbuild: %s — %d joints, worst offset %.2e m (grid %.2f m on)", worst < 1e-4 and "PASS" or "FAIL", n, worst, B.snapGrid())
end
