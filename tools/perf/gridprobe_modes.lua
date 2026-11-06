-- ── the base grid probe (buildkitprobe.sh grid): deep-space step 8 ──────────
-- (M6 the shared grid, B9b cables, M6c the Shield Wall). Spliced after
-- buildkitprobe_modes.lua (BK.*). On the home world's far side:
--   1. a tower on the ground, two Solar Arrays and a Battery Bank within
--      150 m: one grid, a ground station in daylight, the bank charging;
--   2. the night under warp: the arrays go dark, the bank carries the
--      tower's 2 EC/s, the tower stays a ground station till dawn;
--   3. the station's base card at night: grid power and the battery;
--   4. an Isotope Skid beside the crew: its dose in the open, then a Shield
--      Wall set between: the dose cut to 5 % by its record, the kit's field
--      draw marking them red, then amber;
--   5. a second base 1.05 km on, a mast; a Power Cable from its tower walked
--      back to the first base's bank: one grid, both towers ground stations;
--   6. the costs; save and reload: the grid, its charge, the cable's mesh,
--      the wall's shielding, the two bases on one grid.
-- Run with PATCHES=funds.patch.

-- a picture with the frame's debug draws (the field rings, the markers, the preview line)
function BK.shotd(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end

function BK.put(id, wfn, tag, node_fn)
  local fb, cp = findScript("field_builder"), findScript("catalog_panel")
  cp.pickPart(id)
  BK.aimfn = function()
    local w = wfn()
    if not w then return end
    local sx, sy, _, on = camera.worldToScreen(w.x, w.y, w.z)
    if sx and on ~= false then fb.sim = fb.sim or {}; fb.sim.mouse = { sx, sy } end
  end
  BK.settle(40)
  local before = fb.lastPlace
  local rq = fb.req
  if rq and rq.pose and not rq.bad then
    BK.click(false)
  else
    P("BK %s: the cursor gave %s %s: placed the probe's way", tag or id, rq and rq.pose and tostring(rq.pose.mode) or "-", rq and tostring(rq.bad or "valid") or "no req")
    local w = wfn()
    local U = unit(sub(w, home()))
    local h = raycast(w.x + U.x * 4, w.y + U.y * 4, w.z + U.z * 4, -U.x, -U.y, -U.z, 10, { ignore = astro() })
    local ok, why = fb.placeAt(h and h.x or w.x, h and h.y or w.y, h and h.z or w.z, U.x, U.y, U.z, node_fn and node_fn() or (h and h.node) or nil)
    P("BK %s placed the probe's way: %s %s", tag or id, tostring(ok), tostring(why))
  end
  wait(1.0)
  fb.heldPart = nil
  local lp = fb.lastPlace
  return (lp and lp ~= before and lp.id == id) and lp or nil
end

-- Teleport the Engineer onto the ground at a body-relative direction, facing a world point.
function BK.stand_dir(dir, look)
  local b = home()
  local gr = ground_r(b, dir.x, dir.y, dir.z, b.radius + 150)
  if not gr then return false end
  local a = astro()
  a.x, a.y, a.z = b.x + dir.x * (gr + 1.1), b.y + dir.y * (gr + 1.1), b.z + dir.z * (gr + 1.1)
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(0.3)
  if look then
    local pc = findScript("planet_camera")
    local a2 = astro()
    local U = unit(sub(a2, home()))
    local d = sub(look(), a2)
    local h = sub(d, scl(U, dot(d, U)))
    if pc and pc.face and len(h.x, h.y, h.z) > 1e-3 then local hu = unit(h); pc.face(hu.x, hu.y, hu.z, -0.25); BK.F = hu end
  end
  return true
end
-- a body-relative direction `d` m along the ground from `u` toward `t`
function BK.along(u, t, d, R)
  local tt = unit(sub(t, scl(u, dot(t, u))))
  return dir_at(u, tt, d, R)
end

function BK.gridline(BT, bid, tag)
  local pw = BT.power(bid)
  P("BK GRID %s: base %s grid %s · in %.2f (solar %.2f, rtg %.2f) out %.2f · stored %.1f / %.0f EC · powered %s · %d structures, %d towers, %d cables",
    tag, tostring(bid), tostring(pw.grid), pw.supply or 0, pw.solar or 0, pw.rtg or 0, pw.need or 0, pw.stored or 0, pw.cap or 0, tostring(pw.powered),
    pw.structures or 0, pw.towers or 0, pw.cables or 0)
  return pw
end

function BK.run_grid()
  BK.tag = params.tag or "grid"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C, net = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew"), findScript("comms")
  local BT, BS, BG, CB, SH = findScript("base_tower"), findScript("bases"), findScript("base_grid"), findScript("base_cable"), findScript("base_shield")
  local cp = nil
  if not BK.check("scene", fb and ST and co and C and BT and BS and BG and CB and SH,
    "field_builder, structures, base_tower, bases, base_grid, base_cable, base_shield") then BK.result() return end
  C.patch(C.activeId(), { role = "engineer" })
  BK.unlock()
  findScript("research").grant("rtg", "probe")
  wait(3.5)
  local me = C.activeId()
  -- 1. THE FAR SIDE, IN DAYLIGHT
  local spot = BK.far_spot()
  if not BK.check("spot", spot ~= nil, "far-side ground %.0f m round, roughness %.2f m, sun %.2f", spot and spot.d or -1, spot and spot.score or -1, spot and spot.lit or -1) then BK.result() return end
  BK.daylight(spot.dir)
  stand_at(spot)
  BK.F = spot.t
  wait(6)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  local F0 = BK.F
  local u0 = unit(sub(astro(), home()))
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "the kit open (gate %s)", tostring(fb.gate))
  cp = findScript("catalog_panel")
  local list = cp.listFor and cp.listFor(fb, "ALL", "") or {}
  local has = {}
  for _, e in ipairs(list) do has[e.id] = true end
  BK.check("cards", #list == 10 and has.batteryBank and has.shieldWall and has.powerCable, "the BASE column: %d cards with the bank, the wall and the cable", #list)
  local cl1, cl2 = fb.cardLines("powerCable", fb.partInfo("powerCable"), false)
  P("BK cable card: %s / %s", tostring(cl1), tostring(cl2))
  -- the tower on the ground, 12 m ahead
  local tw = BK.put("tower", function() local h = BK.ground_ahead(12, 0); return h end, "tower")
  if not BK.check("tower", tw ~= nil, "a tower on the ground (structure %s)", tw and tostring(tw.sid) or "-") then BK.result() return end
  wait(0.5)
  if BT.prompting() then BT.commitName("Sunward") end
  wait(0.5)
  local bidA = ST.getPart(tw.sid, tw.uid).base
  BK.check("founded", bidA and BS.get(bidA) and BS.get(bidA).n == "Sunward", "Sunward founded (base %s)", tostring(bidA))
  local pw0 = BK.gridline(BT, bidA, "tower alone")
  BK.check("mast", not pw0.powered and pw0.cap == 0, "the tower alone: a mast, nothing on its grid")
  -- two Solar Arrays and a Battery Bank to the left
  local a1 = BK.put("solarArray", function() return BK.ground_ahead(7, -7) end, "array 1")
  local a2 = BK.put("solarArray", function() return BK.ground_ahead(11, -9) end, "array 2")
  local bb = BK.put("batteryBank", function() return BK.ground_ahead(14, 8) end, "battery")
  BK.check("parts", a1 and a2 and bb, "two Solar Arrays and a Battery Bank placed (%s, %s, %s)", tostring(a1 and a1.sid), tostring(a2 and a2.sid), tostring(bb and bb.sid))
  wait(2.5)
  local pw1 = BK.gridline(BT, bidA, "day")
  BK.check("grid_day", pw1.structures == 4 and pw1.cap == 4000 and pw1.powered and (pw1.solar or 0) > 0.5,
    "one grid of 4 structures within 150 m: %.2f EC/s of sun, the tower a ground station, the bank at %.0f EC", pw1.solar or 0, pw1.stored or 0)
  local si = BG.slotInfo()
  P("BK the year: %.1f s (%d slots of %.1f s), anchored at agency %.1f", si and si.Y or -1, si and si.N or 0, si and si.L or -1, si and si.A0 or -1)
  -- the live light against the profile's slot
  do
    local E = findScript("electronics")
    local M = BG.model(pw1.grid)
    local rec = ST.get(a1.sid)
    local p = ST.getPart(a1.sid, a1.uid)
    local gx, gy, gz, U, Fp = ST.partPose(rec, p, 1.35)
    local ax, ay, az = U.y * Fp.z - U.z * Fp.y, U.z * Fp.x - U.x * Fp.z, U.x * Fp.y - U.y * Fp.x
    local bodies = space.bodies()
    local hb = home()
    local live = E.solarOutput(3.0, hb.x + gx, hb.y + gy, hb.z + gz, ax, ay, az, bodies, si and si.ref)
    local rec2, p2 = ST.get(a2.sid), ST.getPart(a2.sid, a2.uid)
    local gx2, gy2, gz2, U2, F2 = ST.partPose(rec2, p2, 1.35)
    local live2 = E.solarOutput(3.0, hb.x + gx2, hb.y + gy2, hb.z + gz2, U2.y * F2.z - U2.z * F2.y, U2.z * F2.x - U2.x * F2.z, U2.x * F2.y - U2.y * F2.x, bodies, si and si.ref)
    local sum = (live or 0) + (live2 or 0)
    P("BK light: the arrays live %.3f + %.3f EC/s, the grid's slot says %.3f", live or -1, live2 or -1, pw1.solar or 0)
    BK.check("light_agrees", math.abs(sum - (pw1.solar or 0)) < 0.1 * math.max(sum, 0.5), "the profile's slot agrees with solarOutput now (%.2f vs %.2f)", sum, pw1.solar or 0)
  end
  -- the outpost in daylight
  do
    local n = ST.nodeOf(tw.sid, tw.uid)
    if n then BK.view("g1_outpost_day", n.worldPos, u0, F0, 24, -12, 7) end
  end
  -- 2. THE NIGHT, UNDER WARP
  fb.close()
  wait(1.0)
  local E = findScript("electronics")
  local function sun_dot()
    local b = home()
    local sun = E.sunOf(b.x, b.y, b.z, space.bodies() or {})
    return sun and dot(u0, unit(sub(sun, b))) or 1
  end
  local N = { dark = 0, dark_unpowered = 0, min = 1e9, e_dusk = nil, e_dawn = nil, t_dusk = nil, t_dawn = nil, frames = 0, shot = false }
  local dp = findScript("deployables")
  local warp = tonumber(params.nightwarp) or 50
  local t0 = W()
  P("BK night: sun %.2f over the outpost; warping %dx", sun_dot(), warp)
  space.warp(warp)
  local phase = "day"
  while W() - t0 < (tonumber(params.nighttmo) or 240) do
    yield()
    local pw = BT.power(bidA)
    N.frames = N.frames + 1
    local dark = (pw.solar or 0) <= 1e-6
    if phase == "day" and dark then phase = "night"; N.e_dusk, N.t_dusk = pw.stored, dp.agencyClock() end
    if dark then
      local gs = BG.status(pw.grid)
      if gs then
        if not N.s1 then N.s1 = { t = gs.t, e = gs.stored } end
        N.s2 = { t = gs.t, e = gs.stored }
      end
    end
    if phase == "night" then
      N.dark = N.dark + 1
      if not pw.powered then N.dark_unpowered = N.dark_unpowered + 1 end
      N.min = math.min(N.min, pw.stored or 0)
      if not N.shot and N.t_dusk and dp.agencyClock() - N.t_dusk > 120 then
        -- 3. the station's base card at night (warp held at 1x for the picture)
        space.warp(1)
        wait(1.0)
        local ts = findScript("tracking_station")
        local fv = findScript("fleet_view")
        local snap = fv and fv.snapshot and fv.snapshot(true)
        local e = snap and snap.byId and snap.byId["o:" .. tostring(bidA)]
        if ts and ts.open and e then
          ts.open(); wait(1.5)
          if ts.selectCraft then ts.selectCraft(e.id) end
          wait(1.5)
          local pwn = BK.gridline(BT, bidA, "night (station)")
          BK.check("station_night", ts.isOpen() and ts.selectedId() == e.id and (pwn.solar or 0) <= 1e-6 and pwn.powered,
            "the station's card at night: Sunward selected, the arrays dark, the tower on the battery (%.0f EC)", pwn.stored or 0)
          BK.shot("g3_station_night")
          ts.close(); wait(1.0)
        end
        N.shot = true
        space.warp(warp)
      end
      if not dark then phase = "dawn"; N.e_dawn, N.t_dawn = pw.stored, dp.agencyClock(); break end
    end
  end
  space.warp(1)
  wait(1.0)
  local night = (N.t_dawn and N.t_dusk) and (N.t_dawn - N.t_dusk) or 0
  P("BK night: dusk %.0f EC, dawn %.0f EC, lowest %.0f, %.0f game s dark, %d of %d dark frames unpowered (%.0f s real)",
    N.e_dusk or -1, N.e_dawn or -1, N.min, night, N.dark_unpowered, N.dark, W() - t0)
  BK.check("night", phase == "dawn" and N.dark > 10 and N.dark_unpowered == 0 and (N.e_dawn or 0) > 0,
    "through the night under %dx warp: a ground station every dark frame, %.0f EC left at dawn", warp, N.e_dawn or -1)
  -- (the draw between two solves both inside the night: their own clock stamps)
  local dt = (N.s1 and N.s2) and (N.s2.t - N.s1.t) or 0
  local rate = dt > 0 and (N.s1.e - N.s2.e) / dt or 0
  BK.check("night_draw", dt > 200 and math.abs(rate - 2.0) < 0.01,
    "the bank gave the tower's 2 EC/s in the dark: %.1f EC over %.0f game s between solves (%.3f EC/s)", dt > 0 and (N.s1.e - N.s2.e) or 0, dt, rate)
  local bp = BG.PROF
  P("BK COST grid solve: advance %.3f ms (%d slots) · rebuild %.3f ms · %d advances, %d rebuilds", bp.advance_ms or -1, bp.slots or 0, bp.rebuild_ms or -1, bp.n_advance or 0, bp.n_rebuild or 0)
  -- 4. THE SHIELD WALL: an Isotope Skid beside the crew
  BK.F = F0
  tap("b"); wait(1.2)
  local sk = BK.put("isotopeSkid", function() return BK.ground_ahead(5, 14) end, "skid")
  BK.check("skid", sk ~= nil, "an Isotope Skid placed (structure %s)", tostring(sk and sk.sid))
  if not sk then BK.result() return end
  wait(1.0)
  -- stand 4 m in front of the skid (its +Z), facing it
  local srec = ST.get(sk.sid)
  local spart = ST.getPart(sk.sid, sk.uid)
  local sgx, sgy, sgz, sU, sF = ST.partPose(srec, spart, 0)
  local hb = home()
  local spot_w = { x = hb.x + sgx + sF.x * 4.0, y = hb.y + sgy + sF.y * 4.0, z = hb.z + sgz + sF.z * 4.0 }
  BK.stand_dir(unit(sub(spot_w, hb)), function() local b = home(); return { x = b.x + sgx, y = b.y + sgy, z = b.z + sgz } end)
  wait(2.5)
  local r_open, b_open = SH.doseNow(me)
  local nt = SH.noted(me)
  P("BK dose in the open: %.4f %% of a lethal dose an hour (bare %.4f), shield factor %.3f", r_open * 100, b_open * 100, nt and nt.f or -1)
  BK.check("dose_open", r_open > 0 and nt and nt.f > 0.99, "4 m from the skid in the open: %.3f %% an hour", r_open * 100)
  BK.shotd("g4a_skid_open")
  -- the wall 2 m in front of the skid, between it and the crew
  local wl = BK.put("shieldWall", function() return BK.lw(ST, ST.get(sk.sid), 0, 0, 2.0) end, "wall")
  BK.check("wall", wl ~= nil, "a Shield Wall placed between (%s, %s)", tostring(wl and wl.sid), tostring(wl and wl.mode))
  wait(2.5)
  local r_wall, b_wall = SH.doseNow(me)
  local nt2 = SH.noted(me)
  P("BK dose behind the wall: %.5f %% an hour (bare %.4f), factor %.3f; walls %d", r_wall * 100, b_wall * 100, nt2 and nt2.f or -1, #SH.walls())
  BK.check("dose_wall", r_open > 0 and math.abs(r_wall / r_open - 0.05) < 0.02, "behind the wall: %.4f %% an hour, %.1f %% of the open dose (by its record: k 0.05)",
    r_wall * 100, r_open > 0 and r_wall / r_open * 100 or -1)
  BK.check("draw_agrees", nt2 and nt2.f < 0.1, "the kit's field draw is told the same factor (%.3f): the marker amber", nt2 and nt2.f or -1)
  BK.shotd("g4b_wall_dose")
  do
    local b = home()
    local w = { x = sgx + sF.x * 2.0, y = sgy + sF.y * 2.0, z = sgz + sF.z * 2.0 }
    local R = unit(cross(sF, sU))
    VP.cam_fixed({ x = w.x + R.x * 7 + sF.x * 5 + sU.x * 3.5, y = w.y + R.y * 7 + sF.y * 5 + sU.y * 3.5, z = w.z + R.z * 7 + sF.z * 5 + sU.z * 3.5 },
      { x = w.x + sU.x * 0.8, y = w.y + sU.y * 0.8, z = w.z + sU.z * 0.8 })
    wait(1.3)
    BK.shot("g4c_wall_side")
    VP.cam_off()
    wait(0.3)
  end
  -- 5. A SECOND BASE 1.05 km ON, AND A CABLE BACK
  local twA = ST.get(tw.sid)
  local tgx, tgy, tgz = ST.partPose(twA, ST.getPart(tw.sid, tw.uid), 0)
  local uA = unit({ x = tgx, y = tgy, z = tgz })
  local dirB = BK.along(uA, F0, 1050 + 14, home().radius)
  BK.stand_dir(dirB, nil)
  wait(4.0)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or F0.x, y = pc0.fwd_y or F0.y, z = pc0.fwd_z or F0.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  local twB = BK.put("tower", function() return BK.ground_ahead(10, 0) end, "tower B")
  wait(0.5)
  if BT.prompting() then BT.commitName("Leeward") end
  wait(0.5)
  local bidB = twB and ST.getPart(twB.sid, twB.uid) and ST.getPart(twB.sid, twB.uid).base
  local pwB0 = bidB and BK.gridline(BT, bidB, "Leeward alone")
  BK.check("base_b", bidB and BS.get(bidB).n == "Leeward" and pwB0 and not pwB0.powered and pwB0.grid ~= BT.power(bidA).grid,
    "Leeward founded %.0f m on: a mast on a grid of its own", bidB and BS.groundDist(home().radius, tgx, tgy, tgz, BS.get(bidB).x, BS.get(bidB).y, BS.get(bidB).z) or -1)
  if not bidB then BK.result() return end
  -- the cable: made off at Leeward's tower, walked back to Sunward's bank
  findScript("catalog_panel").pickPart("powerCable")
  BK.aim_local(ST, twB.sid, 0, 1.0, 0)
  BK.settle(40)
  local rq = fb.req
  P("BK cable at the tower: %s", rq and tostring(rq.bad or ("ok · " .. tostring(rq.label))) or "no req")
  if rq and rq.cable and not rq.bad then BK.click(false) else
    local r2 = ST.get(twB.sid); CB.makeOff(r2, ST.getPart(twB.sid, twB.uid)); P("BK cable made off the probe's way")
  end
  wait(0.5)
  BK.check("made_off", CB.pending and CB.pending.sid == twB.sid, "the cable made off at Leeward's tower (%s)", tostring(CB.pending and CB.pending.label))
  BK.shot("g5a_cable_made_off")
  -- walk it back (a teleport) to 7 m from the bank
  local brec = ST.get(bb.sid)
  local bgx, bgy, bgz, bU, bF = ST.partPose(brec, ST.getPart(bb.sid, bb.uid), 0)
  local hb2 = home()
  local back = unit(sub({ x = hb2.x + bgx, y = hb2.y + bgy, z = hb2.z + bgz }, { x = hb2.x + dirB.x * home().radius, y = hb2.y + dirB.y * home().radius, z = hb2.z + dirB.z * home().radius }))
  local sp = { x = hb2.x + bgx - back.x * 7, y = hb2.y + bgy - back.y * 7, z = hb2.z + bgz - back.z * 7 }
  BK.stand_dir(unit(sub(sp, hb2)), function() local b = home(); return { x = b.x + bgx, y = b.y + bgy, z = b.z + bgz } end)
  wait(2.0)
  BK.check("still_pending", CB.pending ~= nil and fb.heldPart == "powerCable", "...still in hand after the walk (%s)", tostring(fb.heldPart))
  if not CB.pending then findScript("catalog_panel").pickPart("powerCable"); local r2 = ST.get(twB.sid); CB.makeOff(r2, ST.getPart(twB.sid, twB.uid)) end
  BK.aim_local(ST, bb.sid, 0, 1.2, 0)
  BK.settle(40)
  rq = fb.req
  P("BK cable at the bank: %s · %.0f m · %s", rq and tostring(rq.bad or "valid") or "no req", rq and rq.len or -1, rq and rq.quote and tostring(rq.quote.total) or "-")
  BK.shotd("g5b_cable_preview")
  local f0 = co.balance()
  local cid
  if rq and rq.cable and not rq.bad then BK.click(false); wait(1.0); cid = CB.lastLay and CB.lastLay.id
  else
    local id = CB.lay(CB.pending, { sid = bb.sid, uid = bb.uid }); cid = id; P("BK cable laid the probe's way: %s", tostring(id))
  end
  wait(1.5)
  local cr = cid and CB.get(cid)
  BK.check("laid", cr and CB.lastLay and math.abs((f0 - co.balance()) - CB.lastLay.total) < 1, "laid: %.0f m, %.2f t, $%s charged (%d heights)",
    cr and cr.len or -1, CB.lastLay and CB.lastLay.mass or -1, tostring(f0 - co.balance()), cr and #cr.h or 0)
  local pa, pb = BK.gridline(BT, bidA, "Sunward cabled"), BK.gridline(BT, bidB, "Leeward cabled")
  BK.check("one_grid", pa.grid == pb.grid and pa.towers == 2 and math.abs(pa.need - 4.0) < 1e-6 and pb.powered and pa.powered and pa.cables == 1,
    "two bases on one grid: both towers ground stations, %.1f EC/s drawn, %.2f in", pa.need, pa.supply)
  -- the cable on the ground: by the bank, and out along the run
  wait(1.5)
  BK.check("mesh", CB.nodeOf(cid) ~= nil, "its mesh is drawn (%s)", tostring(CB.nodeOf(cid) and CB.nodeOf(cid).name))
  do
    local pts = CB.path(cr)
    local b = home()
    local pB = pts and pts[#pts]
    -- (the bank's end is `z`: the polyline's last point)
    if pB then
      local w = pB
      local Uw = unit(w)
      local o = unit(sub(pts[#pts - 10] or pts[1], pB))
      local Rr = unit(cross(o, Uw))
      VP.cam_fixed({ x = w.x + o.x * 6 + Rr.x * 4 + Uw.x * 2.2, y = w.y + o.y * 6 + Rr.y * 4 + Uw.y * 2.2, z = w.z + o.z * 6 + Rr.z * 4 + Uw.z * 2.2 },
        { x = w.x + o.x * 1.2, y = w.y + o.y * 1.2, z = w.z + o.z * 1.2 })
      wait(1.4)
      BK.shot("g5c_cable_at_bank", false)
      local m = pts[math.floor(#pts * 0.97)]
      local Um = unit(m)
      VP.cam_fixed({ x = m.x + Rr.x * 3 + Um.x * 1.6, y = m.y + Rr.y * 3 + Um.y * 1.6, z = m.z + Rr.z * 3 + Um.z * 1.6 }, { x = m.x - o.x * 2, y = m.y - o.y * 2, z = m.z - o.z * 2 })
      wait(1.4)
      BK.shot("g5d_cable_run", false)
      VP.cam_off()
      wait(0.3)
    end
  end
  -- the station's card: two towers on one grid
  fb.close()
  wait(0.8)
  do
    local ts = findScript("tracking_station")
    local fv = findScript("fleet_view")
    local snap = fv and fv.snapshot and fv.snapshot(true)
    local e = snap and snap.byId and snap.byId["o:" .. tostring(bidA)]
    if ts and ts.open and e then
      ts.open(); wait(1.5)
      if ts.selectCraft then ts.selectCraft(e.id) end
      wait(1.5)
      BK.check("station_grid", ts.isOpen() and ts.selectedId() == e.id and e.outpost and e.outpost.grid == pa.grid,
        "the station's card on the shared grid: %s", tostring(e.outpost and e.outpost.gridLine))
      BK.shot("g6_station_grid")
      ts.close(); wait(1.0)
    end
  end
  -- 6. THE COSTS (the kit closed)
  local fr0 = FRAME
  wait(3)
  P("BK COST grid idle (kit closed): base_grid %.4f ms/frame, base_cable %.4f, base_shield %.4f, base_tower %.4f, structures %.4f (%d frames)",
    perf.scriptMs and perf.scriptMs("base_grid") or -1, perf.scriptMs and perf.scriptMs("base_cable") or -1,
    perf.scriptMs and perf.scriptMs("base_shield") or -1, perf.scriptMs and perf.scriptMs("base_tower") or -1,
    perf.scriptMs and perf.scriptMs("structures") or -1, FRAME - fr0)
  tap("b"); wait(1.0)
  fr0 = FRAME
  wait(3)
  P("BK COST grid (kit open, the field drawn): base_shield %.4f ms/frame, base_grid %.4f, field_builder %.4f (%d frames)",
    perf.scriptMs and perf.scriptMs("base_shield") or -1, perf.scriptMs and perf.scriptMs("base_grid") or -1,
    perf.scriptMs and perf.scriptMs("field_builder") or -1, FRAME - fr0)
  fb.close()
  -- 7. SAVE AND RELOAD
  local e0 = BT.power(bidA).stored
  local wf0 = SH.wallFactor(home().name, sgx + sU.x * 0.5, sgy + sU.y * 0.5, sgz + sU.z * 0.5, sgx + sF.x * 4 + sU.x * 1.4, sgy + sF.y * 4 + sU.y * 1.4, sgz + sF.z * 4 + sU.z * 1.4)
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf2 = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf2 and bf2.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(4)
  ST, BT, BG, CB, SH = findScript("structures"), findScript("base_tower"), findScript("base_grid"), findScript("base_cable"), findScript("base_shield")
  local qa, qb = BK.gridline(BT, bidA, "reload A"), BK.gridline(BT, bidB, "reload B")
  local cg = BG.lastCatchUp()
  P("BK reload: the bank %.1f EC before, %.1f after (catch-up %s)", e0, qa.stored or -1, cg and string.format("%.0f s", cg.dt) or "none")
  BK.check("reload_grid", qa.grid == qb.grid and qa.towers == 2 and qa.powered and qb.powered and math.abs((qa.stored or 0) - e0) < 200,
    "after a reload: one grid again, both ground stations, the bank at %.0f EC (was %.0f)", qa.stored or -1, e0)
  wait(1.5)
  BK.check("reload_cable", CB.get(cid) and CB.nodeOf(cid) ~= nil, "the cable's record and its mesh again")
  local wf1 = SH.wallFactor(home().name, sgx + sU.x * 0.5, sgy + sU.y * 0.5, sgz + sU.z * 0.5, sgx + sF.x * 4 + sU.x * 1.4, sgy + sF.y * 4 + sU.y * 1.4, sgz + sF.z * 4 + sU.z * 1.4)
  BK.check("reload_wall", #SH.walls() == 1 and math.abs(wf1 - 0.05) < 1e-9 and math.abs(wf0 - 0.05) < 1e-9, "the wall still shields by its record (%.3f, was %.3f)", wf1, wf0)
  do
    local n = ST.nodeOf(tw.sid, tw.uid)
    if n then BK.view("g7_after_reload", n.worldPos, unit(sub(n.worldPos, home())), F0, 26, 14, 8) end
  end
  BK.result()
end
