-- ── verify probe (tools/perf/verifyprobe.sh): the 2026-10-27 playtest fixes (62e8dca) in the engine ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua (iv_launch,
-- iv_bike, enter_seat, IV.*). Modes:
--   vbike     the player's dirt bike (user://probe_dirtbike.json, the library
--             file): out past 95 m, a flattened strip, full W and full S from a
--             standstill (speed each second, metres run), a ramp climbed
--             forwards; the seat view on its Moto Saddle swept through pitch
--             70→80° at yaw ±120° (camera roll each step); shift lock on foot
--             → board → off; the bike destroyed under its rider, then a walk
--             up and down the ramp: the capsule's size and the camera against
--             the ground every frame.
--   vvab      a Pod Mk2 rocket: the VAB walked into (picture), launched in
--             place, the seat-view roll sweep in the pod, Revert to the builder
--             through the pause menu (picture, the scrim), then the gizmo:
--             rotate and offset, a press 25–35 px off a ring/arrow over a part
--             and a drag.
--   vflora    (USERSAVE) one stand at the base edge watched from a fixed
--             camera every 0.25 s while the crew walks the base edge, makes
--             ~20 laser digs near grass and a pad is laid (a launch): props
--             that appear, vanish or slide; groundBusy; floating props.
--   vplants   (USERSAVE) out at a meadow: a plant 3 m to the left grabbed with
--             the gravity gun and a tree cut with the laser (body facing),
--             the aim ring at 1.5/3/8/20 m, 10 plants pulled and 3 trees cut
--             (gone?), a felled tree's look.
--   vobj      (USERSAVE) a contract taken, the objective switcher (/), the
--             pack marker from a rover's seat; the Floodlight at night; the
--             settings' window sizes and render scale.
--   vjitter   (USERSAVE) 20 s walking near the base and 20 s away: frame times
--             and the model against the capsule each frame.
-- `VP PASS|FAIL <check>` lines and `VP RESULT <mode>`; pictures in
-- $WORK/proj/save/user/vshots/.
local V = { fails = 0, tag = "v" }
function V.check(name, ok, fmt, ...)
  P("VP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then V.fails = V.fails + 1 end
  return ok
end
function V.result() P("VP RESULT %s: %s (%d failed)", V.tag, V.fails == 0 and "PASS" or "FAIL", V.fails) end
function V.shot(nm, ui, cam, w, h)
  local done = false
  local opt = { w = w or 1280, h = h or 720, ui = ui == true }
  local ok, err
  if cam then ok, err = pcall(camera.capture, cam, opt, function(bytes) if bytes then assets.writeBytes("user://vshots/" .. V.tag .. "_" .. nm .. ".png", bytes) end done = true end)
  else ok, err = pcall(camera.capture, opt, function(bytes) if bytes then assets.writeBytes("user://vshots/" .. V.tag .. "_" .. nm .. ".png", bytes) end done = true end) end
  if not ok then P("VP shot %s refused: %s", nm, tostring(err)); return end
  if not cam then wait_for(function() return done end, 6, "shot " .. nm) end
  P("VP SHOT %s_%s", V.tag, nm)
end
function V.pc() return findScript("planet_camera") end
function V.up(p) return unit(sub(p, home())) end
function V.decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[V.decode(k)] = V.decode(x) end
  return out
end
function V.upness(vn)
  local i = assembly.info(vn)
  if not i then return 1 end
  local up = i.up or vn:worldUp()
  return dot(unit({ x = up.x, y = up.y, z = up.z }), V.up(i.com))
end
-- the craft's front (R2.fwd, vessel frame) in the world, level
function V.fwdW(vc)
  local F = vc.R2.fwd or { x = 1, z = 0 }
  local vn = vc.node
  local rx, fw = vn:worldRight(), vn:worldForward()
  return unit({ x = rx.x * F.x - fw.x * F.z, y = rx.y * F.x - fw.y * F.z, z = rx.z * F.x - fw.z * F.z })
end
function V.speed(vc) return dot(assembly.info(vc.node).vel, V.fwdW(vc)) end
function V.stop(vc)
  -- to a standstill AND the eased stick back at 0 (R2.drive eases at 0.8/s up
  -- and 3/s down: a test begun with it still pushing gets a head start)
  local t0, still = time, 0
  while time - t0 < 10 do
    local sp = V.speed(vc)
    local d = 0
    if math.abs(sp) > 0.06 then d = -clamp(sp / 1.0, -1, 1) end
    vc.R2.cmd = { drive = d, steer = 0 }
    yield()
    if math.abs(sp) < 0.08 and math.abs(vc.R2.drive or 0) < 0.02 then still = still + 1 else still = 0 end
    if still > 30 then break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  P("VP stopped: %.2f m/s, stick %.2f after %.1f s", V.speed(vc), vc.R2.drive or 0, time - t0)
end
-- drive out past `out` m from the base, steering away from it
function V.out(vc, out)
  local vn = vc.node
  local u, _, _, R = base_frame()
  local function from_base() return math.acos(clamp(dot(V.up(assembly.info(vn).com), u), -1, 1)) * R end
  local t0 = time
  while time - t0 < 90 do
    local i1 = assembly.info(vn)
    local Rh = V.up(i1.com)
    local away = sub(Rh, scl(u, dot(Rh, u)))
    local vh = sub(i1.vel, scl(Rh, dot(i1.vel, Rh)))
    local st = 0
    if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
      away = unit(away)
      local sn = dot(cross(unit(vh), away), Rh)
      if dot(unit(vh), away) < 0.97 then st = (sn >= 0) and 0.5 or -0.5 end
    end
    vc.R2.cmd = { drive = 0.7, steer = st }
    yield()
    if from_base() > out then break end
    if V.upness(vn) < 0.3 then P("VP FELL on the way out"); return false, from_base end
  end
  P("VP out: %.0f m from the base after %.1f s", from_base(), time - t0)
  return true, from_base
end
-- sculpt a strip (grade 0: flat) or a ramp along F from the craft's ground
function V.ground(vc, F, U, from_d, to_d, grade, rel0)
  local i = assembly.info(vc.node)
  local b = home()
  if not rel0 then
    local base = i.com
    local h0 = raycast(base.x + U.x * 3, base.y + U.y * 3, base.z + U.z * 3, -U.x, -U.y, -U.z, 10, { ignore = { vc.node } })
    local g0 = h0 and { x = h0.x, y = h0.y, z = h0.z } or sub(base, scl(U, 0.65))
    rel0 = sub(g0, b)
  end
  local n = unit(sub(U, scl(F, grade)))
  local L = unit(cross(U, F))
  local made = 0
  local d = from_d
  while d <= to_d do
    local bb = home()
    local up = (grade ~= 0) and math.max(0, d - from_d) * grade or 0
    local p = { x = bb.x + rel0.x + F.x * d + U.x * up, y = bb.y + rel0.y + F.y * d + U.y * up, z = bb.z + rel0.z + F.z * d + U.z * up }
    for _, lat in ipairs({ -1.4, 0, 1.4 }) do
      local q = { x = p.x + L.x * lat, y = p.y + L.y * lat, z = p.z + L.z * lat }
      if grade ~= 0 then terrain.sculpt(q.x, q.y, q.z, 1.6, 1.0, "raise") end
      terrain.sculpt(q.x, q.y, q.z, 1.9, 1.0, "flatten", { normal = vec3(n.x, n.y, n.z) })
      made = made + 1
    end
    d = d + 0.9
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "sculpt")
  wait(0.8)
  return rel0, made
end
-- the grade along the centreline (mean, steepest 3 m) between d0 and d1
function V.profile(vc, F, U, rel0, d0, d1)
  local prof, bb = {}, home()
  for k = 0, math.floor((d1 - d0) / 0.5) do
    local dd = d0 + k * 0.5
    local p = { x = bb.x + rel0.x + F.x * dd + U.x * 8, y = bb.y + rel0.y + F.y * dd + U.y * 8, z = bb.z + rel0.z + F.z * dd + U.z * 8 }
    local h = raycast(p.x, p.y, p.z, -U.x, -U.y, -U.z, 20, { ignore = { vc.node } })
    prof[#prof + 1] = h and (8 - h.distance) or 0 / 0
  end
  local steep, mx, mn = 0, -1e9, 1e9
  for k = 1, #prof - 6 do local s = (prof[k + 6] - prof[k]) / 3; if s == s then steep = math.max(steep, math.abs(s)) end end
  for _, h in ipairs(prof) do if h == h then mx = math.max(mx, h); mn = math.min(mn, h) end end
  return steep, mx - mn, prof
end
function V.planetNode() local b = home(); return b and find(b.name) end

-- ── the seat view's roll: pitch stepped 70→80° at yaw ±120°, one step a frame ──
function V.rollsweep(tag, vc)
  local pc = V.pc()
  local cn = pc.node
  local ok = enter_seat(vc, 1)
  if not ok then V.check(tag .. "_seat", false, "no seat view"); return end
  wait(0.8)
  local worst_jump, worst_roll = 0, 0
  for _, yd in ipairs({ 120, -120 }) do
    local prev, line = nil, {}
    for k = 0, 40 do
      local pd = 70 + k * 0.25
      pc.setSeatLook(math.rad(yd), math.rad(pd))
      yield(); yield()
      local U = V.up(cn.pos)
      local R = cn:worldRight()
      local Fw = cn:worldForward()
      local roll = math.deg(math.asin(clamp(R.x * U.x + R.y * U.y + R.z * U.z, -1, 1)))
      local elev = math.deg(math.asin(clamp(Fw.x * U.x + Fw.y * U.y + Fw.z * U.z, -1, 1)))
      if prev then worst_jump = math.max(worst_jump, math.abs(roll - prev)) end
      worst_roll = math.max(worst_roll, math.abs(roll))
      prev = roll
      if k % 4 == 0 then line[#line + 1] = string.format("%.2f:%.2f/%.1f", pd, roll, math.abs(elev)) end
    end
    P("VP %s roll yaw %d (pitch:roll/|elev|): %s", tag, yd, table.concat(line, " "))
    V.shot(tag .. "_y" .. yd .. "_p80", false)
  end
  V.check(tag .. "_roll", worst_jump < 1.0, "yaw ±120°, pitch 70→80° in 0.25° steps: biggest frame-to-frame roll change %.2f°, biggest |roll| %.2f° (vs the planet's horizon)", worst_jump, worst_roll)
  pc.setSeatLook(0, -0.08)
  pc.setCockpit(false)
  wait(0.5)
end

-- ── vbike ───────────────────────────────────────────────────────────────────
function V.dirtbike()
  local ok, raw = pcall(assets.readJson, "user://probe_dirtbike.json")
  if not ok or type(raw) ~= "table" then P("VP no user://probe_dirtbike.json: %s", tostring(raw)); return nil end
  return V.decode(raw.bp)
end
function V.tyres(vc, tag)
  local td = {}
  for _, w in ipairs(vc.R2.wheels or {}) do
    local t = w.tyre
    local j = t and t.valid and t:getcomponent("Joint")
    if j then
      local rim = (j.speed or 0) / 57.29578 * (w.r or 0.3) * (w.rs or 1)
      td[#td + 1] = string.format("w%d gr %s rim %.2f tgt %.2f mF %.0f pos %.3f st %.1f", w.uid, tostring(t.grounded), rim,
        (j.motorSpeed or 0) / 57.29578 * (w.r or 0.3) * (w.rs or 1), j.maxForce or -1, j.position or -1, j.steer or 0)
    end
  end
  local s = vc.motoState and vc.motoState() or {}
  P("VP T %s vf %.2f lk %.2f a_s %.2f lean %.1f bars %.1f pitch-up %.3f | %s", tag, vc.R2.vf or 0, vc.R2.lk or 0, vc.R2.a_s or 0, math.deg(s.lean or 0), s.steer or 0,
    dot(V.fwdW(vc), V.up(assembly.info(vc.node).com)), table.concat(td, " | "))
end
function V.run_bike_test(vc, dir, secs, tag)
  local vn = vc.node
  local b0, c0 = home(), assembly.info(vn).com
  local F = V.fwdW(vc)
  local t0, sp, marks, nextm, vmax = time, {}, {}, 1, 0
  local s15, s45
  local fell = false
  while time - t0 < secs do
    vc.R2.cmd = { drive = dir, steer = 0 }
    yield()
    local s = V.speed(vc) * dir
    vmax = math.max(vmax, s)
    if not s15 and time - t0 >= 1.5 then s15 = { s, time } end
    if not s45 and time - t0 >= 4.5 then s45 = { s, time } end
    if time - t0 >= nextm then marks[#marks + 1] = string.format("%.1f", s); nextm = nextm + 1 end
    if (params.diag or 0) > 0 and time - (V.td or 0) > 0.25 then V.td = time; V.tyres(vc, string.format("%s+%.2f", tag, time - t0)) end
    if V.upness(vn) < 0.3 then fell = true; break end
  end
  local b1, c1 = home(), assembly.info(vn).com
  local along = dot(sub(sub(c1, b1), sub(c0, b0)), F) * dir
  vc.R2.cmd = { drive = 0, steer = 0 }
  P("VP bike %s: speed each second %s m/s, top %.2f m/s, %.1f m run%s", tag, table.concat(marks, " "), vmax, along, fell and " FELL" or "")
  local acc = (s15 and s45) and (s45[1] - s15[1]) / (s45[2] - s15[2]) or 0
  P("VP bike %s: acceleration 1.5–4.5 s %.2f m/s²", tag, acc)
  return { vmax = vmax, along = along, v2 = tonumber(marks[2]) or 0, v1 = tonumber(marks[1]) or 0, fell = fell, acc = acc }
end
-- the walker on the ramp: the capsule, the body's depth, the camera against the ground, every frame
function V.walk_ground(tag, frames, steer)
  local a = astro()
  local wk = findScript("planet_walker")
  local pc = V.pc()
  local cn = pc.node
  local rb = a and a:getcomponent("RigidBody")
  local under, minq, minc, worst_r = 0, 1e9, 1e9, 1e9
  for f = 1, frames do
    if steer then steer(f) end
    yield()
    local q = terrain.query(cn.x, cn.y, cn.z)
    if q then minq = math.min(minq, q); if q < 0 then under = under + 1 end end
    -- the body's height over the ground straight below it (the nearest
    -- surface can be a ramp's side wall beside the crew)
    local Ud = V.up(a)
    local hd = raycast(vec3(a.x, a.y, a.z), vec3(-Ud.x, -Ud.y, -Ud.z), 20, a)
    local qc = hd and hd.distance
    if qc then minc = math.min(minc, qc) end
    if rb then worst_r = math.min(worst_r, rb.radius or 0) end
    if f % 60 == 0 then
      local U = V.up(a)
      local h = raycast(vec3(a.x, a.y, a.z), vec3(-U.x, -U.y, -U.z), 60, a)
      local hc = raycast(vec3(cn.x, cn.y, cn.z), vec3(-U.x, -U.y, -U.z), 60, a)
      P("VP %s f%d cam q %.2f (ground %.2f below) crew centre q %.2f (ground %.2f below, node %s) radius %.2f", tag, f, q or -99, hc and hc.distance or -1, qc or -99,
        h and h.distance or -1, tostring(h and h.node and h.node.name), rb and rb.radius or -1)
    end
  end
  wk.steer(nil)
  return under, minq, minc, worst_r
end
local function run_vbike()
  V.tag = "bike"
  local bp = V.dirtbike()
  if not bp then V.check("craft", false, "no craft file"); V.result(); return end
  local seat
  for _, d in ipairs(bp.parts) do if (d.seat == 1 or d.seat == true) then seat = d.uid end end
  P("VP the player's dirt bike: %d parts, %d links, root %s, saddle uid %s", #bp.parts, #(bp.links or {}), tostring(bp.root), tostring(seat))
  for _, d in ipairs(bp.parts) do P("VP  part %s %s parent %s att %s at %.2f %.2f %.2f ypr %.0f %.0f %.0f", tostring(d.uid), tostring(d.id), tostring(d.parent), tostring(d.att),
    d.x or 0, d.y or 0, d.z or 0, math.deg(d.yaw or 0), math.deg(d.pitch or 0), math.deg(d.roll or 0)) end
  local vc = iv_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = "Dirt Bike", controls = bp.controls, groups = bp.groups, turned = bp.turned },
    "runway", seat and { { uid = seat, slot = 1, id = 1 } } or nil)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  local vn = vc.node
  wait(2)
  vc.releaseClamps()
  wait(2)
  P("VP released: front %.2f %.2f (%s), bike %s, crew aboard %s", (vc.R2.fwd or {}).x or 0, (vc.R2.fwd or {}).z or 0, tostring(vc.R2.fwdWhy), tostring(vc.R2.bike), tostring(vc.crewAboard))
  local ms = vc.motoState and vc.motoState() or {}
  for _, q in ipairs(ms.susp or {}) do P("VP susp %s raked %s comp %.3f k %.0f", tostring(q.kind), tostring(q.raked), q.comp or -1, q.k or -1) end
  for _, w in ipairs(vc.R2.wheels or {}) do
    local s = w.susp
    P("VP wheel %d: steers %s susp %s joint axis %s part axis %s", w.uid, tostring(w.steers), s and s.m and s.m.kind or "-",
      s and s.axis and string.format("%.2f %.2f %.2f", s.axis[1], s.axis[2], s.axis[3]) or "-",
      s and s.partAxis and string.format("%.2f %.2f %.2f", s.partAxis[1], s.partAxis[2], s.partAxis[3]) or "-")
  end
  if (params.aerooff or 0) > 0 and vc.AERO then vc.AERO.scale = 0; P("VP A/B: aero off") end
  if (params.nobal or 0) > 0 then vc.R2.motoOff = true; P("VP A/B: the balance (motoBike) off") end
  local okout = V.out(vc, 95)
  V.stop(vc)
  if not okout then V.check("out", false, "fell on the way out"); V.result(); return end
  -- 1. flat: a strip flattened 50 m each way along the bike's line
  local U = V.up(assembly.info(vn).com)
  local F = V.fwdW(vc)
  F = unit(sub(F, scl(U, dot(F, U))))
  local rel0, made = V.ground(vc, F, U, -48, 48, 0)
  local steep, rise = V.profile(vc, F, U, rel0, -45, 45)
  P("VP flat strip: %d sculpts, steepest 3 m %.1f%%, rise over 90 m %.2f m", made, steep * 100, rise)
  V.stop(vc)
  local fw = V.run_bike_test(vc, 1, 5, "full W")
  V.stop(vc)
  -- back to the start, then S from a standstill the other way
  local bw = V.run_bike_test(vc, -1, 5, "full S")
  V.stop(vc)
  local top_r = (bw.vmax > 0.1) and fw.vmax / bw.vmax or 0
  local acc_r = (bw.acc > 0.1) and fw.acc / bw.acc or 0
  V.check("bike_flat_top", top_r > 0.9 and top_r < 1.1, "speed after 5 s from a standstill W %.2f / S %.2f m/s = %.2f", fw.vmax, bw.vmax, top_r)
  if (params.bikeonly or 0) > 0 then
    V.check("bike_flat_accel", acc_r > 0.9 and acc_r < 1.1, "acceleration 1.5–4.5 s W %.2f / S %.2f m/s² = %.2f (speed after 1 s %.2f / %.2f, 2 s %.2f / %.2f)", fw.acc, bw.acc, acc_r, fw.v1, bw.v1, fw.v2, bw.v2)
    V.result(); return
  end
  V.check("bike_flat_accel", acc_r > 0.9 and acc_r < 1.1, "acceleration 1.5–4.5 s W %.2f / S %.2f m/s² = %.2f (speed after 1 s %.2f / %.2f, 2 s %.2f / %.2f)", fw.acc, bw.acc, acc_r, fw.v1, bw.v1, fw.v2, bw.v2)
  -- 2. the seat view on the Moto Saddle
  V.rollsweep("saddle", vc)
  -- 3. a steep ramp, climbed forwards
  U = V.up(assembly.info(vn).com)
  F = V.fwdW(vc); F = unit(sub(F, scl(U, dot(F, U))))
  local grade = params.grade or 0.45
  local rr = V.ground(vc, F, U, 5, 19, grade)
  V.ground(vc, F, U, 19.9, 23, 0.0001, { x = rr.x + U.x * 14 * grade, y = rr.y + U.y * 14 * grade, z = rr.z + U.z * 14 * grade })
  local st2, _, prof = V.profile(vc, F, U, rr, 0, 24)
  local pts = {}
  for k = 1, #prof, 4 do pts[#pts + 1] = string.format("%.1f", prof[k]) end
  P("VP ramp: grade asked %.0f%%, steepest 3 m %.0f%%, profile %s", grade * 100, st2 * 100, table.concat(pts, " "))
  local t0, best, top = time, 0, nil
  local nextl = 0
  while time - t0 < 25 do
    vc.R2.cmd = { drive = 1, steer = 0 }
    yield()
    local along = dot(sub(sub(assembly.info(vn).com, home()), rr), F)
    best = math.max(best, along)
    if time - t0 >= nextl then nextl = nextl + 1; P("VP hill+%.0f: %.1f m along, %.1f m/s", time - t0, along, V.speed(vc)) end
    if V.upness(vn) < 0.3 then P("VP FELL on the hill"); break end
    if along > 20 then top = time - t0; break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.check("bike_hill", top ~= nil, "%.0f%% ramp (steepest 3 m %.0f%%) climbed forwards: %s, best %.1f m along (top at 19 m)", grade * 100, st2 * 100,
    top and string.format("over the top in %.1f s", top) or "did not make it", best)
  V.stop(vc)
  -- 4. shift lock: on foot → aboard → off
  local pc = V.pc()
  local function eva_toggle(want)
    for _ = 1, 3 do
      tap("f")
      wait_for(function() return vc.crewAboard == want end, 3, "f")
      if vc.crewAboard == want then break end
      wait(0.5)
    end
    wait(0.8)
  end
  eva_toggle(false)
  pc.shiftlock = true
  wait(0.5)
  local foot1, ab1 = pc.mouseLooking, vc.crewAboard
  eva_toggle(true)
  local seated, ab2 = pc.mouseLooking, vc.crewAboard
  local kept = pc.shiftlock
  wait(1.0)
  eva_toggle(false)
  local foot2, ab3 = pc.mouseLooking, vc.crewAboard
  V.check("shiftlock", foot1 == true and seated == false and foot2 == true and ab1 == false and ab2 == true and ab3 == false,
    "on foot (aboard %s) locked %s; aboard (aboard %s, no button) locked %s, the walker's lock kept %s; off again (aboard %s) locked %s",
    tostring(ab1), tostring(foot1), tostring(ab2), tostring(seated), tostring(kept), tostring(ab3), tostring(foot2))
  pc.shiftlock = false
  wait(0.3)
  -- 5. the bike destroyed under its rider, then a walk on the ramp
  eva_toggle(true)
  local a = astro()
  local rb = a and a:getcomponent("RigidBody")
  P("VP aboard: crew capsule r %.3f h %.3f", rb and rb.radius or -1, rb and rb.height or -1)
  local id = vn.id
  vn:destroy()
  wait(2.5)
  a = astro()
  rb = a and a:getcomponent("RigidBody")
  local wk = findScript("planet_walker")
  P("VP the bike destroyed: walker onFoot %s, visible %s, capsule r %.3f h %.3f", tostring(wk and wk.onFoot), tostring(a and a.visible), rb and rb.radius or -1, rb and rb.height or -1)
  V.check("capsule_after_despawn", rb and math.abs((rb.radius or 0) - 0.33) < 0.01 and math.abs((rb.height or 0) - 2.0) < 0.01,
    "radius %.3f height %.3f (want 0.33 / 2.0)", rb and rb.radius or -1, rb and rb.height or -1)
  -- onto the ramp's foot, facing up it; then up and down, the view low and looking up
  local bb = home()
  local p0 = { x = bb.x + rr.x + F.x * 3 + U.x * 1.2, y = bb.y + rr.y + F.y * 3 + U.y * 1.2, z = bb.z + rr.z + F.z * 3 + U.z * 1.2 }
  local function alt(tag)
    local bb2 = home()
    local Ud = V.up(a)
    local gr = ground_r(bb2, Ud.x, Ud.y, Ud.z, len(a.x - bb2.x, a.y - bb2.y, a.z - bb2.z) + 40)
    P("VP crew %s: %.2f m from the planet's centre, ground there %s, so %.2f m up; to the ramp's foot %.1f m; q %s",
      tag, len(a.x - bb2.x, a.y - bb2.y, a.z - bb2.z), tostring(gr), gr and (len(a.x - bb2.x, a.y - bb2.y, a.z - bb2.z) - gr) or -1,
      len(a.x - (bb2.x + rr.x), a.y - (bb2.y + rr.y), a.z - (bb2.z + rr.z)), tostring(terrain.query(a.x, a.y, a.z)))
  end
  alt("after the bike went")
  a.x, a.y, a.z = p0.x, p0.y, p0.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(1.5)
  alt("put at the ramp's foot")
  local under, minq, minc, wr = V.walk_ground("ramp walk", 600, function(f)
    local ph = math.floor(f / 150) % 4
    local pitch = (ph % 2 == 0) and 0.55 or -0.25
    local d = (ph < 2) and F or scl(F, -1)
    pc.face(d.x, d.y, d.z, pitch)
    wk.steer(1, (f % 100 < 30) and 0.6 or 0)
  end)
  V.shot("ramp_walk_end", false)
  V.check("camera_above_ground", under == 0, "600 frames on the %.0f%% ramp: camera inside the ground on %d frames (lowest q %.2f m)", grade * 100, under, minq)
  V.check("walker_not_sunk", minc > 0.6 and wr > 0.3, "crew centre lowest %.2f m over the ground below it, capsule radius lowest %.3f", minc, wr)
  V.result()
end

-- ── vvab ────────────────────────────────────────────────────────────────────
function V.scrim()
  local n = find("panelScrim")
  return n ~= nil and n.valid ~= false and n.visible ~= false
end
function V.ui_click(key)
  local n = find(key)
  if not (n and n.uiRect) then return false end
  local x, y, w, h = n:uiRect()
  if not x then return false end
  mouse_to(x + w / 2, y + h / 2)
  lmb_click()
  return true
end
function V.gizmo(B, uid, tool, off_px, outward)
  B.select({ uid }, "set")
  B.setTool(tool)
  wait(0.4)
  local r = B.partRec(uid)
  local fr = B.frame and B.frame()
  local function W3(x, y, z)
    if fr and fr.toWorld and not fr.identity then local a, b2, c = fr.toWorld(x, y, z); return { x = a, y = b2, z = c } end
    return { x = x, y = y, z = z }
  end
  local function S(p3) local sx, sy, _, on = camera.worldToScreen(p3.x, p3.y, p3.z); return sx, sy, on ~= false end
  local ok, len_, rad = pcall(B.gizmo_dims, r)
  if not ok then len_, rad = 1.6, 1.3 end
  local c = W3(r.x, r.y, r.z)
  local cx, cy = S(c)
  local best = nil
  local axes = B.gizmoAxes(r, tool)
  for ai, a in ipairs(axes) do
    if tool == "rotate" then
      local ux, uy, uz, vx2, vy2, vz2 = B.ring_basis(a)
      for k = 0, 47 do
        local t = k * math.pi / 24
        local lp = { x = r.x + (ux * math.cos(t) + vx2 * math.sin(t)) * rad, y = r.y + (uy * math.cos(t) + vy2 * math.sin(t)) * rad, z = r.z + (uz * math.cos(t) + vz2 * math.sin(t)) * rad }
        local sx, sy, on = S(W3(lp.x, lp.y, lp.z))
        if on then
          -- the press: off the ring by off_px, toward the centre (inward) or away
          local dx, dy = sx - cx, sy - cy
          local l = math.sqrt(dx * dx + dy * dy)
          if l > 20 then
            local s = outward and 1 or -1
            local px, py = sx + dx / l * off_px * s, sy + dy / l * off_px * s
            mouse_to(px, py)
            local hv = B.hovered and B.hovered()
            if hv and (not best or (hv ~= uid) == (outward == true)) then best = { ai = ai, x = px, y = py, hv = hv, tx = -dy / l, ty = dx / l } end
          end
        end
      end
    else
      local a0 = W3(r.x + a.x * len_ * 0.6, r.y + a.y * len_ * 0.6, r.z + a.z * len_ * 0.6)
      local a1 = W3(r.x + a.x * len_, r.y + a.y * len_, r.z + a.z * len_)
      local x0, y0, on0 = S(a0)
      local x1, y1, on1 = S(a1)
      if on0 and on1 then
        local dx, dy = x1 - x0, y1 - y0
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 5 then
          for _, s in ipairs({ 1, -1 }) do
            local px, py = x0 - dy / l * off_px * s, y0 + dx / l * off_px * s
            mouse_to(px, py)
            local hv = B.hovered and B.hovered()
            if hv and not best then best = { ai = ai, x = px, y = py, hv = hv, tx = dx / l, ty = dy / l } end
          end
        end
      end
    end
  end
  if not best then P("VP gizmo %s: no press point %d px off a handle over a part", tool, off_px); return nil end
  local r0 = B.partRec(uid)
  local hv0 = B.partRec(best.hv)
  mouse_to(best.x, best.y)
  wait(0.2)
  input.simulate { button = 0, down = true }; yield(); yield()
  for k = 1, 10 do mouse_to(best.x + best.tx * 6 * k, best.y + best.ty * 6 * k) end
  local held_mid = B.held and B.held()
  input.simulate { button = 0, down = false }; yield(); yield()
  wait(0.3)
  local r1 = B.partRec(uid)
  local hv1 = B.partRec(best.hv)
  local moved = len(r1.x - r0.x, r1.y - r0.y, r1.z - r0.z)
  local turned = math.abs(r1.yaw - r0.yaw) + math.abs(r1.pitch - r0.pitch) + math.abs(r1.roll - r0.roll)
  local hmoved = hv1 and hv0 and len(hv1.x - hv0.x, hv1.y - hv0.y, hv1.z - hv0.z) or -1
  P("VP gizmo %s %s %d px: pressed over uid %s (%s), axis %d; selected part moved %.3f m turned %.1f°; part under the press moved %.3f m; held mid-drag %s",
    tool, outward and "outside" or "inside", off_px, tostring(best.hv), tostring(hv0 and hv0.id), best.ai, moved, math.deg(turned), hmoved, tostring(held_mid and #held_mid))
  if B.undoStep and (moved > 1e-4 or turned > 1e-4 or hmoved > 1e-4) then B.undoStep(); wait(0.2) end
  return { moved = moved, turned = turned, hmoved = hmoved, held = held_mid ~= nil, over = best.hv, sel = uid }
end
local function run_vvab()
  V.tag = "vab"
  IV.medium()
  local list = stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "tankS", 1.0 }, { "podMk2", 1.15 }, { "chute", 0.34, 1 } })
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("v_enter")
  if not BH then V.check("vab", false, "no builder"); V.result(); return end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "v_bp", list, { name = "Kestrel" })
  wait(2.0)
  mouse_to(20, 20)
  V.shot("1_walked_in", true)
  P("VP walked in: scrim %s", tostring(V.scrim()))
  local BC = findScript("builder_crew")
  if BC then BC.unseatMember(1); P("VP seat: %s", tostring(BC.seatMember(1, 4, 1))) end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  wait(3)
  V.rollsweep("pod2", vc)
  -- Revert to the builder through the pause menu, as a player clicks it
  local pm = findScript("pause_menu")
  local vs = findScript("vessel_spawner")
  local rq = vs.revertQuote()
  P("VP revert quote ok %s builder %s why %s", tostring(rq and rq.ok), tostring(rq and rq.builder), tostring(rq and rq.why))
  tap("escape")
  wait(0.8)
  P("VP pause menu open %s, scrim %s", tostring(pm.open), tostring(V.scrim()))
  local c1 = V.ui_click("revertvab")
  wait(0.4)
  local c2 = V.ui_click("revertvab")
  if not (c1 and c2) then P("VP revert row not clickable (%s %s): the row's own sequence", tostring(c1), tostring(c2)); pm.close(); vs.revertClick("builder"); vs.revertClick("builder") end
  local BH2 = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder after revert")
  wait(3.0)
  mouse_to(20, 20)
  wait(0.5)
  local sc = V.scrim()
  V.shot("2_reverted", true)
  V.check("revert_scrim", BH2 ~= nil and not sc and not pm.open, "back in the builder %s, pause menu open %s, panelScrim up %s", tostring(BH2 ~= nil), tostring(pm.open), tostring(sc))
  -- the gizmo: presses 25–35 px off a handle, over a part, and a drag
  B = findScript("builder")
  local uids = B.partUids()
  local tank
  for _, u in ipairs(uids) do local r = B.partRec(u); if r and r.id == "tankS" and not tank then tank = u end end
  local bc = findScript("builder_camera")
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(1.5)
  local res = {}
  for _, c in ipairs({ { "rotate", 30, false }, { "rotate", 25, false }, { "rotate", 35, false }, { "rotate", 30, true }, { "offset", 30 }, { "offset", 25 }, { "offset", 35 } }) do
    local g = V.gizmo(B, tank, c[1], c[2], c[3])
    if g then
      local okg = (not g.held) and g.hmoved < 1e-3 and (g.over == g.sel or g.hmoved < 1e-3) and (g.turned > 1e-3 or g.moved > 1e-3)
      local nm = string.format("gizmo_%s_%s%d", c[1], c[3] and "out" or "", c[2])
      res[#res + 1] = V.check(nm, okg, "lifted %s, the part under the press moved %.3f m, the gizmo %s (turned %.1f°, moved %.3f m)",
        tostring(g.held), g.hmoved, (g.turned > 1e-3 or g.moved > 1e-3) and "dragged" or "did NOT drag", math.deg(g.turned), g.moved)
    end
  end
  B.setTool("select")
  V.result()
end

-- ── vflora: one stand at the base edge, watched while the ground is edited ──
function V.stand_list(S, r)
  local ff = findScript("flora_field")
  local A = ff.groundAudit(S.x, S.y, S.z, r, 0.3)
  local b = home()
  local out = {}
  for _, p in ipairs(A.props or {}) do
    out[#out + 1] = { k = tostring(p.kind), id = p.id, src = p.src, x = p.x - b.x, y = p.y - b.y, z = p.z - b.z }
  end
  return out, A
end
-- a prop is the same prop if one of its kind stood within 0.3 m of it (planet
-- frame): what the eye sees, whatever source or id draws it
function V.watch(S, r, state)
  local cur0 = V.stand_list(S, r)
  local cur = {}
  for _, p in ipairs(cur0) do if not (state.excl and state.excl(p)) then cur[#cur + 1] = p end end
  local prev = state.prev
  local ids_changed = 0
  local function match(p, list)
    for _, q in ipairs(list) do
      if q.k == p.k and len(p.x - q.x, p.y - q.y, p.z - q.z) < 0.3 then return q end
    end
  end
  if prev then
    for _, p in ipairs(cur) do
      local q = match(p, prev)
      if not q then
        state.appear = state.appear + 1
        if #state.ex < 6 then state.ex[#state.ex + 1] = string.format("+%s#%s src %s at %.0f s", p.k, tostring(p.id), tostring(p.src), time) end
      elseif q.id ~= p.id or q.src ~= p.src then ids_changed = ids_changed + 1 end
    end
    for _, q in ipairs(prev) do
      if not match(q, cur) then
        state.vanish = state.vanish + 1
        if #state.ex < 12 then state.ex[#state.ex + 1] = string.format("-%s#%s src %s at %.0f s", q.k, tostring(q.id), tostring(q.src), time) end
      end
    end
  end
  state.redeclared = (state.redeclared or 0) + ids_changed
  state.n = #cur
  state.prev = cur
end
-- a photo camera that stays where it was put on the planet: placed again, in
-- the world, every frame it is asked (unparented)
function V.fixed_cam(S, U, T, dist, h)
  local cam = nil
  local b = home()
  local rel_eye = sub({ x = S.x - T.x * dist + U.x * h, y = S.y - T.y * dist + U.y * h, z = S.z - T.z * dist + U.z * h }, b)
  local rel_s = sub(S, b)
  spawn("FlagPhotoCam", vec3(S.x, S.y, S.z), function(n) cam = n end)
  wait_for(function() return cam end, 5, "photo cam")
  V.place_cam = function()
    if not (cam and cam.valid) then return end
    local bb = home()
    cam.pos = vec3(bb.x + rel_eye.x, bb.y + rel_eye.y, bb.z + rel_eye.z)
    cam:lookAt(vec3(bb.x + rel_s.x, bb.y + rel_s.y, bb.z + rel_s.z), vec3(U.x, U.y, U.z))
  end
  V.place_cam()
  return cam
end
local function run_vflora()
  V.tag = "flora"
  local ff = findScript("flora_field")
  local bf = findScript("base_facilities")
  local tb = findScript("tool_belt")
  local wk = findScript("planet_walker")
  wait(6)
  local u, t1, t2, R = base_frame()
  local b = home()
  -- the base's edge: the first ring out from the base (20–140 m) where a
  -- 10 m patch holds 15+ plants, the bearing with the most there
  local best, bestn, edge = nil, -1, nil
  for _, dist in ipairs({ 20, 30, 40, 50, 60, 70, 80, 90, 100, 120, 140 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if gr then
        local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
        local A = ff.groundAudit(p.x, p.y, p.z, 10, 0.3)
        if A.checked > bestn then bestn, best = A.checked, { p = p, t = t, ang = ang, dir = dir } end
      end
    end
    if bestn >= 15 then edge = dist; break end
  end
  edge = edge or 140
  if not best then V.check("stand", false, "no stand found"); V.result(); return end
  local brel = sub(best.p, b)
  local function S() local bb = home(); return { x = bb.x + brel.x, y = bb.y + brel.y, z = bb.z + brel.z } end
  P("VP stand at the base edge (%.0f m out, bearing %.0f°): %d props within 12 m", edge, math.deg(best.ang), bestn)
  -- the crew there, 10 m off the stand toward the base
  local a = astro()
  local function put(p) a.x, a.y, a.z = p.x, p.y, p.z; a.vx, a.vy, a.vz = 0, 0, 0 end
  local s0 = S()
  local U = V.up(s0)
  local T = unit(sub(best.dir, scl(U, dot(best.dir, U))))
  put({ x = s0.x - T.x * 10 + U.x * 1.5, y = s0.y - T.y * 10 + U.y * 1.5, z = s0.z - T.z * 10 + U.z * 1.5 })
  wait(3)
  local cam = nil   -- (the player's own view is photographed: a spawned photo camera drew fog)
  local snap = false
  local st = { appear = 0, vanish = 0, slide = 0, n = 0, ex = {} }
  local shots, busy_max, phase = 0, 0, "walk"
  local log_t = 0
  local function tick(tag)
    V.watch(S(), 12, st)
    local gb = ff.groundBusy and ff.groundBusy() or -1
    busy_max = math.max(busy_max, gb)
    if V.place_cam then V.place_cam() end
    if snap and (params.shots or 1) > 0 then
      shots = shots + 1
      V.shot(string.format("stand_%03d", shots), false, nil, 640, 360)
    end
    if time - log_t > 2 then
      log_t = time
      P("VP stand [%s]: %d props, appeared %d vanished %d (same plant, new source/id %d); groundBusy %d; audit redropped %s removed %s", tag, st.n, st.appear, st.vanish, st.redeclared or 0, gb,
        tostring(ff.auditRedropped), tostring(ff.auditRemoved))
    end
  end
  local function run_for(secs, tag, each)
    local t0, nextw = time, time
    while time - t0 < secs do
      if each then each(time - t0) end
      yield()
      if V.place_cam then V.place_cam() end
      if time >= nextw then nextw = nextw + 0.25; tick(tag) end
    end
  end
  -- A. walk the base edge for 60 s (a circle about the base at the stand's distance)
  local pc = V.pc()
  -- (a prop the crew walks through bends — touch swaps it for a node and back
  -- — and a dug one goes: neither is churn. Props within 3 m of the crew or
  -- 2.5 m of a bite are left out of the count.)
  local digs = {}
  st.excl = function(p)
    local bb = home()
    local q = { x = bb.x + p.x, y = bb.y + p.y, z = bb.z + p.z }
    if len(q.x - a.x, q.y - a.y, q.z - a.z) < 3 then return true end
    for _, d in ipairs(digs) do if len(p.x - d.x, p.y - d.y, p.z - d.z) < 2.5 then return true end end
    return false
  end
  run_for(params.walk or 60, "walk", function(t)
    local p = sub(a, home())
    local up = unit(p)
    local tang = unit(cross(u, up))     -- round the base, back and forth
    if math.floor(t / 6) % 2 == 1 then tang = scl(tang, -1) end
    pc.face(tang.x, tang.y, tang.z, -0.2)
    -- keep to the edge: steer in or out
    local rr = math.acos(clamp(dot(up, u), -1, 1)) * R
    wk.steer(1, clamp((rr - (edge - 15)) * 0.15, -0.6, 0.6))
  end)
  wk.steer(nil)
  local A0 = { appear = st.appear, vanish = st.vanish, slide = st.slide }
  -- B. ~20 laser bites in the grass beside the stand
  put({ x = S().x - T.x * 9 + U.x * 1.5, y = S().y - T.y * 9 + U.y * 1.5, z = S().z - T.z * 9 + U.z * 1.5 })
  pc.face(T.x, T.y, T.z, -0.35)
  wait(1.5)
  snap = true
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  local slot
  for i, s in ipairs(tb.belt()) do if s.id == "laser" then slot = i end end
  tb.sim = { pressed = { [tostring(slot or 2)] = true } }
  wait(0.5)
  local L = unit(cross(U, T))
  run_for(0.1, "dig")
  for i = 1, (params.digs or 20) do
    local bb = home()
    local up = V.up(a)
    local eye = { x = a.x + up.x * 0.6, y = a.y + up.y * 0.6, z = a.z + up.z * 0.6 }
    local lat = ((i % 5) - 2) * 1.2
    local k = 3.0 + math.floor((i - 1) / 5) * 0.8
    local tgt = { x = a.x + T.x * k + L.x * lat - up.x * 1.6, y = a.y + T.y * k + L.y * lat - up.y * 1.6, z = a.z + T.z * k + L.z * lat - up.z * 1.6 }
    digs[#digs + 1] = sub(tgt, bb)
    local d = sub(tgt, eye)
    tb.sim = { btn = { [0] = true }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    run_for(0.5, "dig")
    tb.sim = { btn = { [0] = false }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    run_for(0.3, "dig")
  end
  tb.sim = nil
  run_for(6, "after digs")
  snap = false
  local busy_after = ff.groundBusy and ff.groundBusy() or -1
  local A1 = { appear = st.appear - A0.appear, vanish = st.vanish - A0.vanish, slide = st.slide - A0.slide }
  -- floating props over the digs
  local fl, bu, ck, worst = 0, 0, 0, 0
  local mf = findScript("mineral_field")
  for _, d in ipairs(digs) do
    local bb = home()
    local q = ff.groundAudit(bb.x + d.x, bb.y + d.y, bb.z + d.z, 2.5, 0.3)
    fl, bu, ck = fl + q.floating, bu + q.buried, ck + q.checked
    if math.abs(q.worst) > math.abs(worst) then worst = q.worst end
    if mf and mf.groundAudit then local m = mf.groundAudit(bb.x + d.x, bb.y + d.y, bb.z + d.z, 2.5, 0.3); fl, bu, ck = fl + m.floating, bu + m.buried, ck + m.checked end
  end
  V.shot("digs", false)
  -- C. a pad laid: a launch to the pad (vessel_spawner flattens its ground)
  local list = stack({ { "pod", 0.8 }, { "chute", 0.34, 1 } })
  local vc = nil
  if (params.pad or 1) > 0 then
    local rs = findScript("research")
    for _, dd in ipairs(list) do if rs and rs.grant then rs.grant(dd.id, "probe") end end
    vc = launch_in_vab(list, "pad", #list, { name = "Pad Test" })
    -- the crew is in the pod: the photo cam keeps watching the stand
    run_for(10, "pad")
  end
  local A2 = { appear = st.appear - A0.appear - A1.appear, vanish = st.vanish - A0.vanish - A1.vanish, slide = st.slide - A0.slide - A1.slide }
  local pfl, pck = 0, 0
  if vc and vc.node and vc.node.valid then
    local i = assembly.info(vc.node)
    local q = ff.groundAudit(i.com.x, i.com.y, i.com.z, 16, 0.3)
    pfl, pck = q.floating, q.checked
  end
  local busy_end = ff.groundBusy and ff.groundBusy() or -1
  P("VP stand totals: walk %d/%d/%d, digs %d/%d/%d, pad %d/%d/%d (appeared/vanished/slid); %d pictures", A0.appear, A0.vanish, A0.slide, A1.appear, A1.vanish, A1.slide, A2.appear, A2.vanish, A2.slide, shots)
  P("VP stand examples: %s", table.concat(st.ex, "; "))
  V.check("stand_walk", A0.appear + A0.vanish + A0.slide == 0, "60 s walking the edge: appeared %d vanished %d slid %d", A0.appear, A0.vanish, A0.slide)
  V.check("stand_digs", A1.appear + A1.slide == 0, "20 digs beside it: appeared %d vanished %d (the dug ones may go) slid %d", A1.appear, A1.vanish, A1.slide)
  V.check("stand_pad", A2.appear + A2.vanish + A2.slide == 0, "the pad laid: appeared %d vanished %d slid %d", A2.appear, A2.vanish, A2.slide)
  V.check("ground_busy", busy_after <= 1 and busy_end <= 1, "groundBusy after the digs %d, at the end %d (most %d)", busy_after, busy_end, busy_max)
  V.check("no_floating_digs", fl == 0, "over the %d digs: %d props checked, %d floating, %d buried, worst %.2f m", #digs, ck, fl, bu, worst)
  V.check("no_floating_pad", pfl == 0, "round the pad: %d checked, %d floating", pck, pfl)
  if cam and cam.valid then cam:destroy() end
  V.result()
end

-- ── vplants ─────────────────────────────────────────────────────────────────
function V.model_yaw_err(target)
  -- the body's facing (AstroModel's +Z, level) against the way to `target`, degrees
  local a = astro()
  local m
  for _, c in ipairs(a:children()) do if c.name == "AstroModel" then m = c end end
  if not m then return nil end
  local U = V.up(a)
  local o = m:toWorld(vec3(0, 0, 0))
  local f = sub(m:toWorld(vec3(0, 0, 1)), o)
  f = unit(sub(f, scl(U, dot(f, U))))
  local d = sub(target, a)
  d = unit(sub(d, scl(U, dot(d, U))))
  local ang = math.deg(math.atan2(dot(cross(f, d), U), dot(f, d)))
  return ang
end
function V.select_tool(id)
  local tb = findScript("tool_belt")
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", id) < 1 then inv.addGear("astro", id, 1) end
  local slot
  for i, s in ipairs(tb.belt()) do if s.id == id then slot = i end end
  local okh, why = tb.hold(id)
  wait(0.5)
  P("VP tool %s (slot %s): hold %s %s, now %s", id, tostring(slot), tostring(okh), tostring(why), tostring(tb.toolId()))
  return tb.toolId() == id
end
V.TREES = { broadleaf = true, conifer = true, palm = true, fungus = true }
function V.plants_near(p, r, kinds)
  local ff = findScript("flora_field")
  local A = ff.groundAudit(p.x, p.y, p.z, r, 5)
  local out = {}
  local b = home()
  for _, q in ipairs(A.props or {}) do
    if not kinds or kinds[q.kind] then q.rel = { x = q.x - b.x, y = q.y - b.y, z = q.z - b.z }; out[#out + 1] = q end
  end
  return out
end
-- a plant's (or any planet-held point's) world place NOW: the planet moves 1.5–6 m a tick
function V.w(q)
  if not q.rel then return q end
  local b = home()
  return { x = b.x + q.rel.x, y = b.y + q.rel.y, z = b.z + q.rel.z, kind = q.kind, id = q.id, rel = q.rel }
end
function V.gone(q0)
  local q = V.w(q0)
  -- is the plant still in any source near its spot?
  local ff = findScript("flora_field")
  local A = ff.groundAudit(q.x, q.y, q.z, 3.0, 5)
  for _, p in ipairs(A.props or {}) do
    if p.id == q.id and p.kind == q.kind and len(p.x - q.x, p.y - q.y, p.z - q.z) < 0.5 then return false end
  end
  return true
end
local function run_vplants()
  V.tag = "plants"
  -- (the crew is put about the world by teleports: a drop onto ground not
  -- streamed in yet killed them in one run — the save's copy is invincible)
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible"); P("VP crew safety %s", tostring(Cc.safety and Cc.safety())) end
  local ff = findScript("flora_field")
  local tb = findScript("tool_belt")
  local wk = findScript("planet_walker")
  local pc = V.pc()
  wait(4)
  local meadow = find_meadow and find_meadow(params.out or 160) or nil
  if not meadow then local m = find_spots(); meadow = m end
  if not meadow then V.check("meadow", false, "no meadow"); V.result(); return end
  stand_at(meadow)
  wait(4)
  local a = astro()
  -- kinds about
  local kinds = {}
  for _, q in ipairs(V.plants_near(a, 25)) do kinds[q.kind] = (kinds[q.kind] or 0) + 1 end
  local kl = {}
  for k, n in pairs(kinds) do kl[#kl + 1] = k .. " " .. n end
  P("VP at the meadow (%s): plants within 25 m: %s", tostring(meadow.biome), table.concat(kl, ", "))
  local function eye_dir(target)
    local up = V.up(a)
    local eye = { x = a.x + up.x * 0.6, y = a.y + up.y * 0.6, z = a.z + up.z * 0.6 }
    return eye, sub(target, eye)
  end
  local function put_by(q0, side, dist)
    local q = V.w(q0)
    -- stand `dist` m off the plant with it on our `side` (-1 left): facing the view's forward
    local U = V.up(q)
    local fwd = unit(sub({ x = 1, y = 0, z = 0 }, scl(U, U.x)))
    local right = unit(cross(fwd, U))
    local p = { x = q.x - right.x * dist * side + U.x * 1.2, y = q.y - right.y * dist * side + U.y * 1.2, z = q.z - right.z * dist * side + U.z * 1.2 }
    a.x, a.y, a.z = p.x, p.y, p.z
    a.vx, a.vy, a.vz = 0, 0, 0
    pc.face(fwd.x, fwd.y, fwd.z, -0.15)
    return fwd
  end
  -- 1. the gravity gun on a plant 3 m to the left: the body's facing each frame of the hold
  local small = {}
  for _, q in ipairs(V.plants_near(a, 25)) do if not V.TREES[q.kind] and (q.kind == "grass" or q.kind == "fern" or q.kind == "bush" or q.kind == "shrub" or q.kind == "reed") then small[#small + 1] = q end end
  local trees = {}
  for _, q in ipairs(V.plants_near(a, 40, V.TREES)) do trees[#trees + 1] = q end
  V.find_trees = function()
    -- out to where trees stand: a forest's bearings, the crew put there until 4+ trees are near
    local b = home()
    local u, t1, t2, R = base_frame()
    local cl = findScript("climate")
    for _, dist in ipairs({ 80, 140, 220, 320 }) do
      for k = 0, 11 do
        local ang = k * math.pi / 6
        local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
        local dir = dir_at(u, t, dist, R)
        local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
        local smp = gr and cl and cl.sampleAt and cl.sampleAt(b.name, b.x + dir.x * gr, b.y + dir.y * gr, b.z + dir.z * gr)
        if smp and (smp.biome == "forest" or smp.biome == "jungle" or smp.biome == "taiga") and (smp.density or 0) > 0.3 then
          stand_at({ dir = dir, r = gr })
          wait(3)
          local tr = V.plants_near(a, 30, V.TREES)
          P("VP tree search: %s %d m bearing %d: %d trees", smp.biome, dist, k * 30, #tr)
          if #tr >= 4 then return tr end
        end
      end
    end
    return {}
  end
  P("VP %d small plants, %d trees", #small, #trees)
  local function face_test(tool, q, tag, secs)
    V.select_tool(tool)
    put_by(q, -1, 3)
    wait(1.0)
    local errs, flips, prev = {}, 0, nil
    local t0 = time
    local worst_after = 0
    while time - t0 < secs do
      local e, d = eye_dir(V.w(q))
      tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, d.x, d.y, d.z } }
      yield()
      local ang = V.model_yaw_err(V.w(q))
      local ax, ay, az = nil, nil, nil
      if tb.aimNow then ax, ay, az = tb.aimNow() end
      local ang2 = ax and V.model_yaw_err({ x = ax, y = ay, z = az }) or nil
      if ang2 and #errs % 10 == 0 then P("VP %s f%d: facing vs the plant's spot %.0f°, vs the gun's aim point %.0f° (aim %.1f m from the spot)", tag, #errs, ang or 0, ang2,
        len(ax - V.w(q).x, ay - V.w(q).y, az - V.w(q).z)) end
      if ang then
        if prev and math.abs(ang - prev) > 60 then flips = flips + 1 end
        prev = ang
        if time - t0 > 0.8 then worst_after = math.max(worst_after, math.abs(ang)) end
        if #errs < 400 then errs[#errs + 1] = ang end
      end
    end
    local line = {}
    for k = 1, #errs, 10 do line[#line + 1] = string.format("%.0f", errs[k]) end
    P("VP %s facing error every 10 frames: %s", tag, table.concat(line, " "))
    return worst_after, flips
  end
  if small[1] then
    local w, f = face_test("gravgun", small[1], "grab_left", 2.5)
    tb.sim = { btn = { [0] = false } }
    wait(0.5)
    V.check("face_grab", w <= 15 and f == 0, "a plant 3 m to the left held with the gravity gun: worst facing error after 0.8 s %.1f°, flips %d", w, f)
  end
  tb.sim = nil
  wait(0.5)
  -- 2. the laser cut on a tree 3 m to the left (a cut of a few seconds fells it)
  local felled_q = nil
  if #trees < 4 then trees = V.find_trees(); a = astro() end
  if trees[1] then
    local q = trees[1]
    local qu = V.up(V.w(q))
    local w, f = face_test("laser", { rel = { x = q.rel.x + qu.x, y = q.rel.y + qu.y, z = q.rel.z + qu.z }, kind = q.kind, id = q.id }, "cut_left", 6)
    tb.sim = nil
    V.check("face_cut", w <= 15 and f == 0, "a tree 3 m to the left cut with the laser: worst facing error after 0.8 s %.1f°, flips %d", w, f)
    wait(1.5)
    P("VP felling now %s, logs %s", tostring(ff.felling()), tostring(ff.logCount()))
    V.shot("felled_tree", false)
    felled_q = q
  end
  -- 3. the aim ring at 1.5, 3, 8 and 20 m (laser, aimed at bare ground ahead)
  V.select_tool("laser")
  local sizes = {}
  local fwd = put_by(a, 1, 0)
  wait(1)
  local fxu = findScript("vfx")
  local sw0, sh0 = camera.screenSize()
  local pcm = V.pc()
  for _, d in ipairs({ 1.5, 3, 8, 20 }) do
    local up = V.up(a)
    pcm.face(fwd.x, fwd.y, fwd.z, d < 5 and -0.6 or -0.25)
    wait(0.6)
    up = V.up(a)
    local f2 = unit(sub(fwd, scl(up, dot(fwd, up))))
    local top = { x = a.x + f2.x * d + up.x * 4, y = a.y + f2.y * d + up.y * 4, z = a.z + f2.z * d + up.z * 4 }
    local h = raycast(vec3(top.x, top.y, top.z), vec3(-up.x, -up.y, -up.z), 12, a)
    if h and h.distance then
      local g = { x = top.x - up.x * h.distance, y = top.y - up.y * h.distance, z = top.z - up.z * h.distance }
      local e, dd = eye_dir(g)
      tb.sim = { aim = { e.x, e.y, e.z, dd.x, dd.y, dd.z } }
      wait(0.4)
      local R0 = math.max(0.4, (tb.params and tb.params.laser_radius) or 1.2)
      local r, dim = tb.ring_on_screen(g.x, g.y, g.z, up.x, up.y, up.z, R0, tb.RING_CAP.laser)
      -- its radius on screen as drawn: the widest of two tangents (ring_on_screen's own measure)
      local sx, sy = camera.worldToScreen(g.x, g.y, g.z)
      local rt = unit(cross(f2, up))
      local px = 0
      for _, t in ipairs({ f2, rt }) do
        local qx, qy = camera.worldToScreen(g.x + t.x * r, g.y + t.y * r, g.z + t.z * r)
        if sx and qx then px = math.max(px, math.sqrt((qx - sx) ^ 2 + (qy - sy) ^ 2)) end
      end
      sizes[#sizes + 1] = { d = d, r = r, dim = dim, px = px, R0 = R0 }
      P("VP aim ring on the ground %.1f m ahead of the crew: radius %.2f m (full %.2f), %.0f px on screen (%.1f%% of the height), dim %.2f", d, r, R0, px, 100 * px / sh0, dim)
      V.shot(string.format("ring_%03.0f", d * 10), true)
    else
      P("VP aim ring at %.1f m: no ground found", d)
    end
  end
  tb.sim = nil
  local sw, sh = camera.screenSize()
  local near_ok = sizes[1] and sizes[1].px <= sh * 0.05 + 2 and sizes[1].r < sizes[1].R0
  local far_ok = sizes[4] and math.abs(sizes[4].r - sizes[4].R0) < 1e-3
  V.check("aim_ring", near_ok and far_ok, "1.5 m: %.0f px (cap %.0f); 3 m %.0f px; 8 m %.0f px; 20 m %.0f px at the full %.2f m", sizes[1] and sizes[1].px or -1, sh * 0.05,
    sizes[2] and sizes[2].px or -1, sizes[3] and sizes[3].px or -1, sizes[4] and sizes[4].px or -1, sizes[4] and sizes[4].r or -1)
  -- 4. 10 small plants pulled (the gravity gun's uproot), 3 trees cut
  V.select_tool("gravgun")
  local pulled, gone = 0, 0
  local left = {}
  for i = 2, math.min(#small, 30) do
    if pulled >= 10 then break end
    local q = small[i]
    put_by(q, 1, 2.2)
    wait(1.2)
    if not V.gone(q) then
      local t0 = time
      while time - t0 < 4 do
        local e, d = eye_dir(V.w(q))
        tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, d.x, d.y, d.z } }
        yield()
      end
      tb.sim = { btn = { [0] = false } }
      wait(1.0)
      pulled = pulled + 1
      if V.gone(q) then gone = gone + 1 else left[#left + 1] = q.kind .. ":" .. q.id end
    end
  end
  tb.sim = nil
  V.check("pulled_gone", pulled >= 5 and gone == pulled, "%d plants pulled, %d gone from the field (still standing: %s)", pulled, gone, table.concat(left, " "))
  V.select_tool("laser")
  local cut, cgone = 0, 0
  local cleft = {}
  for i = 2, #trees do
    if cut >= 3 then break end
    local q = trees[i]
    put_by(q, 1, 2.5)
    wait(1.2)
    if not V.gone(q) then
      local qu = V.up(V.w(q))
      local tq = { rel = { x = q.rel.x + qu.x, y = q.rel.y + qu.y, z = q.rel.z + qu.z } }
      local t0 = time
      while time - t0 < 6 do
        local e, d = eye_dir(V.w(tq))
        tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, d.x, d.y, d.z } }
        yield()
      end
      tb.sim = nil
      wait(2.0)
      cut = cut + 1
      if V.gone(q) then cgone = cgone + 1 else cleft[#cleft + 1] = q.kind .. ":" .. q.id end
    end
  end
  V.check("cut_gone", cut >= 2 and cgone == cut, "%d trees cut, %d gone from the field (still standing: %s)", cut, cgone, table.concat(cleft, " "))
  if felled_q then
    -- the felled tree's parts, by look
    local n = 0
    for _, nd in ipairs(findTagged and findTagged("flora") or {}) do
      if nd.valid ~= false and len(nd.x - a.x, nd.y - a.y, nd.z - a.z) < 60 then
        local ok, m = pcall(function() return nd:material() end)
        if n < 8 then P("VP flora node %s: material texture %s colour %s", tostring(nd.name), ok and m and tostring(m.texture) or "-",
          ok and m and m.color and string.format("%.2f %.2f %.2f", m.color[1] or m.color.r or 0, m.color[2] or m.color.g or 0, m.color[3] or m.color.b or 0) or "-") end
        n = n + 1
      end
    end
    P("VP %d flora nodes near (felled parts, bent plants)", n)
  end
  V.result()
end

-- ── vobj: the switcher, the pack marker from a seat, the Floodlight at night, settings ──
local function run_vobj()
  V.tag = "obj"
  wait(4)
  local ob = findScript("objectives")
  local mi = findScript("missions")
  local sv = findScript("salvage")
  local a = astro()
  -- a death pack: whatever the crew carries, dropped 30 m off
  local inv = findScript("inventory")
  if inv and inv.add then pcall(inv.add, "astro", "iron", 5) end
  local packs = sv.list()
  P("VP salvage crates %d, salvage instances %d", #packs, #(findScripts("salvage") or {}))
  local b = home()
  local U = V.up(a)
  local T = unit(cross(U, { x = 0, y = 0, z = 1 }))
  local id, kg = sv.drop(b.name, a.x + T.x * 30, a.y + T.y * 30, a.z + T.z * 30, nil, { items = true, label = "Probe's suit pack" })
  P("VP dropped pack %s (%.1f kg)", tostring(id), kg or 0)
  -- a contract
  local offers = mi.offers and mi.offers() or {}
  if not mi.active and offers[1] then P("VP accept %s: %s", tostring(offers[1].id), tostring(mi.accept(offers[1].id))) end
  wait(1)
  local list = ob.objectiveList()
  local names = {}
  for _, o in ipairs(list) do names[#names + 1] = o.key end
  P("VP objectives (%d): %s; selected %s", #list, table.concat(names, " "), tostring(ob.selected()))
  local seen, keys = {}, {}
  for k = 1, #list + 1 do
    tap("/")
    wait(0.4)
    local s = ob.selected()
    keys[#keys + 1] = tostring(s)
    seen[s or "nil"] = true
  end
  local nseen = 0
  for _ in pairs(seen) do nseen = nseen + 1 end
  V.check("switcher", #list >= 3 and nseen == #list, "/ stepped %s (%d of %d)", table.concat(keys, " → "), nseen, #list)
  -- pick the probe's pack and look from the crew
  for _ = 1, #list do if ob.selected() == "pack:" .. tostring(id) then break end tap("/"); wait(0.3) end
  P("VP picked %s, selectedPack %s", tostring(ob.selected()), tostring(ob.selectedPack()))
  local pc = V.pc()
  pc.face(T.x, T.y, T.z, -0.1)
  wait(1.0)
  V.shot("1_pack_on_foot", true)
  -- a rover with a Floodlight on its nose
  local l = {}
  for _, r in ipairs(ROVER) do local c = {}; for k, v in pairs(r) do c[k] = v end; l[#l + 1] = c end
  puid = #l
  l[#l + 1] = prec("light", 0.95, 0.62, 0, { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { parent = 1, att = "surface" })
  local vc = iv_launch(l, { name = "Lamp Rover" }, "runway", { { uid = 6, slot = 1, id = 1 } })
  if not vc then V.check("rollout", false, "no rover"); V.result(); return end
  vc.releaseClamps()
  wait(3)
  for _ = 1, #list + 2 do if ob.selected() == "pack:" .. tostring(id) then break end tap("/"); wait(0.3) end
  wait(1)
  local i = assembly.info(vc.node)
  local groups = sv.markerGroups(sv.list(), i.com.x, i.com.y, i.com.z, home().name, ob.selectedPack(), 3000, nil)
  local dup = 0
  for x = 1, #groups do for y = x + 1, #groups do
    local p, q = groups[x].at, groups[y].at
    if len(p.x - q.x, p.y - q.y, p.z - q.z) < 25 then dup = dup + 1 end
  end end
  local goal = groups[1] and groups[1].goal
  local el = find("Objectives") or nil
  P("VP from the seat: selected %s, %d marker groups, first is the goal %s, salvage instances %d", tostring(ob.selected()), #groups, tostring(goal), #(findScripts("salvage") or {}))
  V.check("pack_marker_seat", ob.selectedPack() == id and goal == true and dup == 0 and #(findScripts("salvage") or {}) == 1,
    "the pack picked from a seat: goal marker %s, groups %d, overlapping %d, salvage libraries %d", tostring(goal), #groups, dup, #(findScripts("salvage") or {}))
  V.shot("2_pack_from_seat", true)
  -- the Floodlight at night: the sun off, lights on (Y), a picture from beside the rover
  local ln = find("Lighting")
  local lc = ln and ln:getcomponent("Light")
  local sun0 = lc and lc.intensity
  if lc then lc.intensity = 0 end
  tap("y")
  wait(1.0)
  local lamp
  local function scan(n, depth)
    for _, c in ipairs(n:children()) do
      if c.name == "Lamp" then
        local l = c:getcomponent("PointLight")
        P("VP a Lamp under %s: range %s spotAngle %s intensity %s", tostring(n.name), tostring(l and l.range), tostring(l and l.spotAngle), tostring(l and l.intensity))
        if l and (l.range or 0) > 25 then lamp = c end
      end
      if depth < 3 then scan(c, depth + 1) end
    end
  end
  scan(vc.node, 0)
  local pl = lamp and lamp:getcomponent("PointLight")
  P("VP lamp %s intensity %s range %s spot %s", tostring(lamp ~= nil), tostring(pl and pl.intensity), tostring(pl and pl.range), tostring(pl and (pl.spotAngle or pl.spot)))
  if lamp then
    local o = lamp:toWorld(vec3(0, 0, 0))
    local f = sub(lamp:toWorld(vec3(0, 0, -1)), o)
    local fwd = V.fwdW(vc)
    P("VP the lamp's beam (−Z) against the rover's front: %.2f (1 = straight ahead)", dot(unit(f), fwd))
  end
  local fw = V.fwdW(vc)
  local up = V.up(i.com)
  local right = unit(cross(fw, up))
  local cam
  local c0 = assembly.info(vc.node).com
  local bb0 = home()
  local reye = sub({ x = c0.x + right.x * 7 + fw.x * 3 + up.x * 3, y = c0.y + right.y * 7 + fw.y * 3 + up.y * 3, z = c0.z + right.z * 7 + fw.z * 3 + up.z * 3 }, bb0)
  local rtgt = sub({ x = c0.x + fw.x * 6, y = c0.y + fw.y * 6, z = c0.z + fw.z * 6 }, bb0)
  spawn("FlagPhotoCam", vec3(c0.x, c0.y, c0.z), function(n) cam = n end)
  wait_for(function() return cam end, 5, "cam")
  V.place_cam = function()
    if not (cam and cam.valid) then return end
    local bb = home()
    cam.pos = vec3(bb.x + reye.x, bb.y + reye.y, bb.z + reye.z)
    cam:lookAt(vec3(bb.x + rtgt.x, bb.y + rtgt.y, bb.z + rtgt.z), vec3(up.x, up.y, up.z))
  end
  local function hold_cam(secs) local t0 = time; while time - t0 < secs do V.place_cam(); yield() end end
  hold_cam(0.3)
  V.shot("3_floodlight_night", false, cam)
  hold_cam(1.0)
  tap("y")
  hold_cam(0.5)
  V.shot("4_floodlight_off", false, cam)
  hold_cam(1.0)
  V.place_cam = nil
  if lc and sun0 then lc.intensity = sun0 end
  if cam and cam.valid then cam:destroy() end
  -- settings: the window sizes, the render scale
  local st = findScript("settings")
  local mons = app.monitors and app.monitors() or {}
  local m1 = mons[1]
  local ws = st.windowSizes(m1 and m1.width or 1920, m1 and m1.height or 1080, {})
  local wl = {}
  for _, z in ipairs(ws) do wl[#wl + 1] = z.w .. "x" .. z.h end
  local rs0 = app.renderScale and app.renderScale()
  st.set("render_scale", 0.5)
  wait(0.5)
  local rs1 = app.renderScale and app.renderScale()
  st.set("render_scale", nil)
  wait(0.5)
  local rs2 = app.renderScale and app.renderScale()
  V.check("settings", #ws >= 4 and math.abs((rs1 or 0) - 0.5) < 0.01, "window sizes on a %sx%s monitor: %s; render scale %.2f → set 50%% %.2f → Auto %.2f",
    tostring(m1 and m1.width), tostring(m1 and m1.height), table.concat(wl, " "), rs0 or -1, rs1 or -1, rs2 or -1)
  V.result()
end

-- ── vjitter: frame times and the model against the capsule ──────────────────
function V.jitter(tag, secs, steer)
  local a = astro()
  local wk = findScript("planet_walker")
  local cn = V.pc().node
  local m
  for _, c in ipairs(a:children()) do if c.name == "AstroModel" then m = c end end
  local dts, offs, hist = {}, {}, {}
  local t0, lastw = time, W()
  while time - t0 < secs do
    if steer then steer(time - t0) end
    yield()
    local w = W()
    dts[#dts + 1] = (w - lastw) * 1000
    lastw = w
    -- the model's place against the capsule (node frame) and in the camera's view
    local mo = m and m:toWorld(vec3(0, 0, 0))
    if mo then
      local lo = a:toLocal(mo)
      local o = a:toLocal(a.pos)
      offs[#offs + 1] = { lo.x - o.x, lo.y - o.y, lo.z - o.z }
      local cl = cn:toLocal(mo)
      hist[#hist + 1] = { cl.x, cl.y, cl.z }
    end
  end
  wk.steer(nil)
  table.sort(dts)
  local sum = 0
  for _, d in ipairs(dts) do sum = sum + d end
  local mean = sum / math.max(#dts, 1)
  local p95 = dts[math.floor(#dts * 0.95)] or 0
  -- model-vs-capsule: frame-to-frame change of the offset (mm)
  local dmax, dsum = 0, 0
  for k = 2, #offs do
    local d = len(offs[k][1] - offs[k - 1][1], offs[k][2] - offs[k - 1][2], offs[k][3] - offs[k - 1][3]) * 1000
    dmax = math.max(dmax, d); dsum = dsum + d
  end
  -- jitter in the view: the model's camera-frame place off its 5-frame mean (mm)
  local jmax, jsum, jn, big = 0, 0, 0, {}
  for k = 3, #hist - 2 do
    local mx, my, mz = 0, 0, 0
    for j = k - 2, k + 2 do mx, my, mz = mx + hist[j][1], my + hist[j][2], mz + hist[j][3] end
    local d = len(hist[k][1] - mx / 5, hist[k][2] - my / 5, hist[k][3] - mz / 5) * 1000
    jmax = math.max(jmax, d); jsum = jsum + d; jn = jn + 1
    if d > 5 then big[#big + 1] = string.format("f%d %.0fmm", k, d) end
  end
  P("VP JITTER %s: %d frames off their 5-frame mean by > 5 mm: %s", tag, #big, table.concat(big, " ", 1, math.min(#big, 20)))
  P("VP JITTER %s: %d frames, frame ms mean %.2f p95 %.2f max %.2f; model-vs-capsule offset change mean %.2f max %.2f mm; model in the view off its 5-frame mean: mean %.2f max %.2f mm",
    tag, #dts, mean, p95, dts[#dts] or 0, dsum / math.max(#offs - 1, 1), dmax, jsum / math.max(jn, 1), jmax)
  return { mean = mean, p95 = p95, max = dts[#dts] or 0, jmean = jsum / math.max(jn, 1), jmax = jmax, omax = dmax }
end
local function run_vjitter()
  V.tag = "jitter"
  wait(5)
  local wk = findScript("planet_walker")
  local pc = V.pc()
  local u = base_frame()
  local function circle(t)
    local a = astro()
    local up = V.up(a)
    local tang = unit(cross(u, up))
    if len(tang.x, tang.y, tang.z) < 0.5 then tang = unit(cross(up, { x = 1, y = 0, z = 0 })) end
    pc.face(tang.x, tang.y, tang.z, -0.25)
    wk.steer(1, 0)
  end
  local near = V.jitter("near the base", 20, circle)
  local m = find_meadow and find_meadow(params.out or 220) or nil
  if m then stand_at(m); wait(4) end
  local far = V.jitter("away from the base", 20, function(t)
    local a = astro()
    local up = V.up(a)
    local f = unit(cross(up, { x = 0, y = 0, z = 1 }))
    pc.face(f.x, f.y, f.z, -0.25)
    wk.steer(1, 0)
  end)
  V.check("jitter", near.jmean < 2 and far.jmean < 2, "model in the view off its 5-frame mean: near max %.1f mm, away max %.1f mm (frame p95 %.1f / %.1f ms)", near.jmax, far.jmax, near.p95, far.p95)
  V.result()
end
