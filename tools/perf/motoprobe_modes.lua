-- ── moto probe (tools/perf/motoprobe.sh): the auto-engineering parts in flight (docs/auto-engineering.md) ──
-- Modes:
--   bike       a motorcycle (fork, swing arm, two moto wheels, a seat, a battery
--              pack): driven out past 95 m from the base, then a straight, a
--              left and a right turn, a slalom and a stop. Every half second:
--              speed, lean and the lean asked for, the bars, the forks.
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

-- THE MOTORCYCLE (front +X; numbers from scripts/parts_auto.lua's frames)
local function mp_bike(gyro)
  puid = 0
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local H = add(prec("hub", 0.18, 1.068, 0, X1, Y1))                                    -- 1 the steering head block
  local F = add(prec("forkT", 0.7416, 0.7564, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  add(prec("wheelB", 0.8022, 0.3497, 0, Z1, Y1, { parent = F.uid, att = "surface" }))
  add(prec("packB", -0.25, 1.068, 0, X1, Y1, { parent = H.uid, att = "surface" }))      -- the tank
  local hp, rp = { x = 0.18, y = 1.068, z = 0 }, { x = -0.03, y = 0.48, z = 0 }
  local sp = add(member("beamP", hp, rp, { parent = H.uid, att = "surface" }))          -- the down tube
  local R = add(prec("hub", rp.x, rp.y, 0, X1, Y1, { parent = sp.uid, att = "surface" }))
  local A = add(prec("swingArm", -0.485, 0.4826, 0, neg(X1), Y1, { parent = R.uid, att = "surface" }))
  add(prec("wheelB", -0.75, 0.35, 0, neg(Z1), Y1, { parent = A.uid, att = "surface" }))
  local sh = { x = -0.80, y = 0.90, z = 0 }
  local sf = add(member("beamP", rp, sh, { parent = R.uid, att = "surface" }))          -- the seat stay
  local S = add(prec("hub", sh.x, sh.y, 0, X1, Y1, { parent = sf.uid, att = "surface" }))
  add(prec("seat", sh.x, sh.y + 0.12 + 0.65, 0, X1, Y1, { parent = S.uid, att = "top" }))
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
      td[#td + 1] = string.format("t%d gr %s v(%.1f,%.1f,%.1f) j st %.1f pos %.2f f %.1f k %.1f z %.2f mot %s %.0f spin %.0f", w.uid, tostring(w.tyre.grounded), tv and tv.x or 0, tv and tv.y or 0, tv and tv.z or 0,
        j and j.steer or -1, j and j.position or -1, j and j.force or -1, j and j.stiffness or -1, j and j.damping or -1, tostring(j and j.motor), j and j.motorSpeed or 0, j and j.speed or 0)
    end
  end
  if (params.fine or 0) > 0 then P("MP %s tyres %s", MP_TAG, table.concat(td, " | ")) end
  P("MP %s [%s] g %.2f tmax %.2f share %.2f v %.1f lean %.1f° (asked %.1f°) bars %.1f° torque %.2f alat %.2f yaw %.2f up %.3f on %d why %s | %s", MP_TAG, tag,
    s.g or 0, s.tmax or 0, s.share or 0, len(i.vel.x, i.vel.y, i.vel.z), math.deg(s.lean or 0), math.deg(s.leanT or 0), s.steer or 0, s.torque or 0, s.alat or 0, s.yaw or 0,
    mp_upness(vc.node), gr, tostring(vc.R2.why), table.concat(sp, " | "))
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
    if fine or time - t0 >= nextl then nextl = nextl + (fine and 0 or 0.5); mp_line(vc, string.format("%s+%.2f", tag, time - t0)) end
    if shot and not shot_done and time - t0 > secs * 0.6 then shot_done = true; mp_shot(tag) end
  end
  st.meanlean = st.n > 0 and st.sumlean / st.n or 0
  P("MP %s %s: %.1f m in %.1f s, top %.1f m/s, lean max %.1f° mean %.1f° (late), min up %.3f%s", MP_TAG, tag, st.dist, secs, st.vmax,
    st.maxlean, st.meanlean, st.minup, st.fell and " FELL" or "")
  return st
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
  vc.R2.motoOff = nil
  local ok, from_base = mp_out(vc, 95, 0.7)
  if not ok then P("MP RESULT %s: FAIL (fell on the way out)", MP_TAG); return end
  local total = 0
  local a = mp_hold(vc, 1, 0, 8, "straight", true); total = total + a.dist
  local l = mp_hold(vc, 0.6, 1, 5, "left", true); total = total + l.dist
  local r = mp_hold(vc, 0.6, -1, 5, "right", true); total = total + r.dist
  local fell = s0.fell or a.fell or l.fell or r.fell
  local sl = { dist = 0 }
  for n = 1, 4 do
    local x = mp_hold(vc, 0.7, (n % 2 == 1) and 0.6 or -0.6, 2.0, "slalom" .. n, n == 2); total = total + x.dist
    fell = fell or x.fell
  end
  local st = mp_hold(vc, 0, 0, 6, "stop", true)
  fell = fell or st.fell
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
  end
  -- the parts sheet: each part on its own, side by side
  puid = 0
  local sheet = {}
  local xs = 0
  for _, id in ipairs({ "wheelB", "forkT", "swingArm", "strutS", "gyro", "packB" }) do
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
