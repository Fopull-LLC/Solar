-- ── the playtest 2026-11-06 visual probe (visual6probe.sh) ───────────────────
-- Spliced after buildkitprobe_modes.lua and gridprobe_modes.lua (BK.*), into a
-- copy of perfbench.lua. On the home world, a fresh save:
--   1. GRASS (meadow ground, find_meadow): the camera held still over the
--      grass, eight frames shot on eight consecutive frames, in daylight and
--      after dark, then again with each suspect switched off in turn (ambient
--      occlusion, sun shadows, the flora's appear dissolve, the plants bent
--      round the crew); the pictures go to visual6/ for a frame-to-frame diff
--      (tools/perf/flicker_diff.py).
--   2. CABLE (rolling ground 150-270 m out): a Battery Bank, a Pad Plate 7 m
--      on and a Solar Array 7 m past it on one line; a Power Cable laid from the
--      bank to the array over the plate; its settled path checked against the
--      terrain at every point (never under, lying on it where it touches, on
--      the plate's top where it crosses); pictures from the side, along it and
--      at the plate, in a high sun and a low one.
-- Lines: `V6 ...`, `BK PASS|FAIL`, `BK RESULT visual6`.

function BK.v6_burst(tag, n)
  n = n or 8
  local got = 0
  for k = 1, n do
    local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes)
      if bytes then assets.writeBytes(string.format("user://visual6/%s_f%d.png", tag, k), bytes) end
      got = got + 1
    end)
    if not ok then got = got + 1 end
    yield()
  end
  wait_for(function() return got >= n end, 10, "burst " .. tag)
  P("V6 BURST %s (%d frames) t=%.2f", tag, n, time)
end

function BK.v6_shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes)
    if bytes then assets.writeBytes("user://visual6/" .. nm .. ".png", bytes); P("V6 SHOT %s t=%.2f", nm, time) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end

-- the sun's height over a body-relative direction (sin of its elevation)
function BK.v6_sun(dir)
  local E = findScript("electronics")
  local b = home()
  local sun = E and E.sunOf and E.sunOf(b.x, b.y, b.z, space.bodies() or {})
  return sun and dot(dir, unit(sub(sun, b))) or 1
end
-- warp until the sun over `dir` is in [lo, hi] (rising or setting, whichever comes)
function BK.v6_sun_to(dir, lo, hi, tmo)
  local s0 = BK.v6_sun(dir)
  if s0 >= lo and s0 <= hi then return s0 end
  local t0 = W()
  space.warp(tonumber(params.daywarp) or 200)
  local s = s0
  while W() - t0 < (tmo or 120) do
    s = BK.v6_sun(dir)
    if s >= lo and s <= hi then break end
    yield()
  end
  space.warp(1)
  wait(1.5)
  P("V6 SUN %.2f -> %.2f (%.0f s of warp)", s0, BK.v6_sun(dir), W() - t0)
  return BK.v6_sun(dir)
end

-- rolling ground: the spot 150-270 m out whose 4-8 m relief is nearest 0.35 m
function BK.v6_rolling()
  local b = home()
  local u, t1, t2, R = base_frame()
  local best
  for _, d in ipairs({ 150, 180, 210, 240, 270 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if g0 then
        local rough, n = 0, 0
        for _, e in ipairs({ 4, 8, 12, 16, 20 }) do
          local dd = unit({ x = dir.x * R + t.x * e, y = dir.y * R + t.y * e, z = dir.z * R + t.z * e })
          local g = ground_r(b, dd.x, dd.y, dd.z, R + 150)
          if g then rough = rough + math.abs(g - g0); n = n + 1 end
        end
        local cl = findScript("climate")
        local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        local bf = findScript("base_facilities")
        local kept = bf and bf.keepClear and bf.keepClear(b.name, dir.x * g0, dir.y * g0, dir.z * g0)
        if n >= 4 and not wet and not kept then
          local score = math.abs(rough / n - 0.35)
          if not best or score < best.score then best = { dir = dir, r = g0, t = t, d = d, score = score, relief = rough / n } end
        end
      end
    end
  end
  return best
end

-- the camera held at the crew's eye, looking down at the ground `ahead` m on
function BK.v6_cam_down(ahead, height, side)
  local a, b = astro(), home()
  local U = unit(sub(a, b))
  local F = BK.F
  local Rt = unit(cross(F, U))
  local rel = sub(a, b)
  -- (a metre in front of the crew, so the body is behind the camera)
  local eye = { x = rel.x + F.x + U.x * (height - 1.0) + Rt.x * (side or 0), y = rel.y + F.y + U.y * (height - 1.0) + Rt.y * (side or 0), z = rel.z + F.z + U.z * (height - 1.0) + Rt.z * (side or 0) }
  local at = { x = rel.x + F.x * ahead - U.x * 1.0, y = rel.y + F.y * ahead - U.y * 1.0, z = rel.z + F.z * ahead - U.z * 1.0 }
  VP.cam_fixed(eye, at)
end
-- the camera beside the crew, watching them walk ahead through the grass
function BK.v6_cam_side()
  local a, b = astro(), home()
  local U = unit(sub(a, b))
  local F = BK.F
  local Rt = unit(cross(F, U))
  local rel = sub(a, b)
  VP.cam_fixed({ x = rel.x + Rt.x * 4 + F.x * 2 + U.x * 0.4, y = rel.y + Rt.y * 4 + F.y * 2 + U.y * 0.4, z = rel.z + Rt.z * 4 + F.z * 2 + U.z * 0.4 },
    { x = rel.x + F.x * 2 - U.x * 0.6, y = rel.y + F.y * 2 - U.y * 0.6, z = rel.z + F.z * 2 - U.z * 0.6 })
end

function BK.v6_grass(tag)
  local S = findScript("settings")
  local FF = findScript("flora_field")
  BK.v6_cam_down(5, 1.7)
  wait(2.5)
  BK.v6_burst(tag .. "_default")
  if S and S.set then
    S.set("ao", 0.0); wait(1.5); BK.v6_burst(tag .. "_ao0"); S.set("ao", 1.0)
    S.set("shadows", false); wait(1.5); BK.v6_burst(tag .. "_shadows0"); S.set("shadows", true)
  end
  if FF and FF.params then
    local tr = FF.params.touch
    FF.params.touch = 0; wait(1.5); BK.v6_burst(tag .. "_touch0"); FF.params.touch = tr
  end
  -- the plants round the crew, and how many of them are swapped for nodes
  P("V6 FLORA %s: bent %s obstacles %s", tag, tostring(FF and FF.touchStats and FF.touchStats.bent), tostring(FF and FF.touchStats and FF.touchStats.obstacles))
  -- the crew stepping through the grass (the bend swaps): a burst while walking
  VP.cam_off(); wait(0.5)
  BK.v6_cam_side()
  wait(1.0)
  key_down("w"); wait(0.4)
  BK.v6_burst(tag .. "_walking", 12)
  key_up("w"); wait(1.0)
  P("V6 FLORA %s walking: bent %s", tag, tostring(FF and FF.touchStats and FF.touchStats.bent))
  VP.cam_off()
end

function BK.v6_cable_shots(CB, cr, tag)
  local pts = CB.path(cr)
  if not pts then return end
  local A, Z = pts[1], pts[#pts]
  local mid = pts[math.floor(#pts / 2)]
  local U = unit(mid)
  local o = unit(sub(Z, A))
  local Rr = unit(cross(o, U))
  local function at(p, a, s, u) return { x = p.x + o.x * a + Rr.x * s + U.x * u, y = p.y + o.y * a + Rr.y * s + U.y * u, z = p.z + o.z * a + Rr.z * s + U.z * u } end
  -- the whole run from the side, low
  VP.cam_fixed(at(mid, 0, 8, 2.6), at(mid, 0, 0, 0.0)); wait(1.2); BK.v6_shot(tag .. "_side")
  -- the bank's end: leaving its side and down to the ground
  VP.cam_fixed(at(A, 1.6, 2.6, 1.7), at(A, 1.2, 0, 0.0)); wait(1.2); BK.v6_shot(tag .. "_from_bank")
  -- the drape over the plate, close
  VP.cam_fixed(at(BK.v6_plate or mid, -0.8, 3.0, 1.8), at(BK.v6_plate or mid, 0, 0, 0.4)); wait(1.2); BK.v6_shot(tag .. "_plate")
  -- the array's end
  VP.cam_fixed(at(Z, -1.6, -2.6, 1.7), at(Z, -1.2, 0, 0.0)); wait(1.2); BK.v6_shot(tag .. "_at_array")
  VP.cam_off()
  wait(0.3)
end

function BK.run_visual6()
  BK.tag = params.tag or "visual6"
  wait_ready(120)
  wait(2)
  local fb, ST, C, CB = findScript("field_builder"), findScript("structures"), findScript("crew"), findScript("base_cable")
  if not BK.check("scene", fb and ST and C and CB, "field_builder, structures, crew, base_cable") then BK.result() return end
  C.patch(C.activeId(), { role = "engineer" })
  BK.unlock()
  wait(3)
  -- 1. GRASS
  local spawn_rel = sub(astro(), home())
  local spawn_F = nil
  do
    local pc0 = findScript("planet_camera")
    local U = unit(spawn_rel)
    local f = { x = pc0.fwd_x or 1, y = pc0.fwd_y or 0, z = pc0.fwd_z or 0 }
    spawn_F = unit(sub(f, scl(U, dot(f, U))))
  end
  if (params.grass or 1) > 0 then
    local spot = find_meadow(params.meadow_m)
    if spot then
      P("V6 MEADOW %s (flora %.2f) %d m out", tostring(spot.biome), spot.flora, spot.d)
      stand_at(spot); BK.F = spot.t
      wait(8)
      BK.v6_sun_to(spot.dir, 0.45, 1.0)
      BK.v6_grass("grass_day")
      BK.v6_sun_to(spot.dir, -1.0, -0.25, 150)
      BK.v6_grass("grass_night")
      -- by the base at night (the playtest's 9.png: the spaceport's lights on the grass)
      local b = home()
      local a = astro()
      local u = unit(spawn_rel)
      local g = ground_r(b, u.x, u.y, u.z, len(spawn_rel.x, spawn_rel.y, spawn_rel.z) + 20) or len(spawn_rel.x, spawn_rel.y, spawn_rel.z)
      a.x, a.y, a.z = b.x + u.x * (g + 1.0), b.y + u.y * (g + 1.0), b.z + u.z * (g + 1.0)
      a.vx, a.vy, a.vz = 0, 0, 0
      BK.F = spawn_F
      wait(6)
      BK.v6_grass("grass_base_night")
    else
      P("V6 MEADOW none")
    end
  end
  -- 2. CABLE
  local spot = BK.v6_rolling()
  if not BK.check("spot", spot ~= nil, "rolling ground %.0f m out, relief %.2f m", spot and spot.d or -1, spot and spot.relief or -1) then BK.result() return end
  stand_at(spot); BK.F = spot.t
  wait(6)
  BK.v6_sun_to(spot.dir, 0.55, 1.0)
  tap("b"); wait(1.0)
  local bank = BK.put("batteryBank", function() return BK.ground_ahead(5, 0) end, "bank")
  local plate = BK.put("padPlate", function() return BK.ground_ahead(12, 0) end, "plate")
  local arr = BK.put("solarArray", function() return BK.ground_ahead(19, 0) end, "array")
  if not BK.check("parts", bank and plate and arr, "a bank, a plate and an array on one line (%s %s %s)", tostring(bank ~= nil), tostring(plate ~= nil), tostring(arr ~= nil)) then BK.result() return end
  do
    local pr = ST.get(plate.sid)
    local gx, gy, gz = ST.partPose(pr, ST.getPart(plate.sid, plate.uid), 0)
    BK.v6_plate = { x = gx, y = gy, z = gz }
  end
  findScript("catalog_panel").pickPart("powerCable")
  CB.makeOff(ST.get(bank.sid), ST.getPart(bank.sid, bank.uid))
  local t0 = os.clock()
  local cid, why = CB.lay(CB.pending, { sid = arr.sid, uid = arr.uid })
  local ms = (os.clock() - t0) * 1000
  local cr = cid and CB.get(cid)
  if not BK.check("laid", cr ~= nil, "laid %s m in %.1f ms (%s), %d ground samples", cr and string.format("%.1f", cr.len) or "-", ms, tostring(why), cr and #cr.h or 0) then BK.result() return end
  fb.heldPart = nil
  fb.close()
  wait(2.0)
  BK.check("mesh", CB.nodeOf(cid) ~= nil, "its mesh is drawn")
  -- the settled path against the ground and the plate
  do
    local b = home()
    local pts, L, info = CB.path(cr)
    local under, onground, worst, n = 0, 0, 1e9, 0
    local maxgap = 0
    for i, p in ipairs(pts) do
      local r = len(p.x, p.y, p.z)
      local u = unit(p)
      local g = ground_r(b, u.x, u.y, u.z, r + 3)
      if g then
        local c = r - g
        n = n + 1
        if c < worst then worst = c end
        if c < 0.0 then under = under + 1 end
        if c < 0.10 then onground = onground + 1 end
        if c > maxgap then maxgap = c end
      end
    end
    -- the plate's top under the cable
    local pp = BK.v6_plate
    local best_d, top_c = 1e9, nil
    local prec = ST.get(plate.sid)
    local _, _, _, PU = ST.partPose(prec, ST.getPart(plate.sid, plate.uid), 0)
    for _, p in ipairs(pts) do
      local d = len(p.x - pp.x, p.y - pp.y, p.z - pp.z)
      if d < best_d then best_d = d; top_c = dot(sub(p, pp), PU) end
    end
    P("V6 CABLE %d mesh points, %.2f m long (%d stations at %.2f m), clearance min %.3f m max %.2f m, %d of %d points under, %d lying (<10 cm)",
      #pts, L, info and info.n or -1, info and info.ds or -1, worst, maxgap, under, n, onground)
    BK.check("not_under", under == 0, "no mesh point under the ground (%d)", under)
    BK.check("lies", onground >= n * 0.3, "it lies on the ground where it touches (%d of %d points within 10 cm: the probe's ground ray stops 5 cm short)", onground, n)
    BK.check("over_plate", top_c and top_c > 0.55 and top_c < 0.75, "over the plate it rests on its top (%.3f m over the plate's ground point)", top_c or -1)
  end
  -- the plants off for the pictures (tall grass hides a 32 mm cable)
  local FF = findScript("flora_field")
  if FF and FF.params then FF.params.enabled = 0; wait(2.0) end
  BK.v6_cable_shots(CB, cr, "cable_hi")
  BK.v6_sun_to(spot.dir, 0.08, 0.22, 150)
  BK.v6_cable_shots(CB, cr, "cable_lo")
  -- the ground dug beside the run: the cable settles again on the new ground
  do
    local pts = CB.path(cr)
    local m = pts[math.floor(#pts * 0.8)]
    local b = home()
    local u = unit(m)
    local r0 = CB.resettled or 0
    terrain.dig(b.x + m.x - u.x * 0.9, b.y + m.y - u.y * 0.9, b.z + m.z - u.z * 0.9, 1.4, 1.0)
    local ff = findScript("flora_field")
    if ff and ff.groundChanged then ff.groundChanged(b.x + m.x, b.y + m.y, b.z + m.z, 1.4) end
    wait(4.0)
    BK.check("resettle", (CB.resettled or 0) > r0, "a hole dug under it: it settles into it (%d -> %d)", r0, CB.resettled or 0)
    BK.v6_cable_shots(CB, CB.get(cid), "cable_dug")
  end
  BK.result()
end
