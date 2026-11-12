-- ── airlock (playtest 2026-11-11): the airlock from every side, its sight and
-- sound, a breach, the alarms ────────────────────────────────────────────────
-- kitprobe.sh <engine> airlock. On flat ground 150+ m out, kitprobe's rooms
-- hab: an airlock chamber (Airlock Wall out, Door Wall in), a 4 x 2 m hab, a
-- far door to the outside, an Air Tank Rack, an Isotope Cell, a ceiling light
-- in the hab; the outside made vacuum. Then, walking as a player does:
--   * from OUTSIDE: the outer door opens; in the chamber the outer door shuts,
--     it fills, the inner door opens (timed; never both open); pictures of
--     the panel from outside and of the chamber's vapour mid-cycle;
--   * from the HAB: the inner door, the pump-down, the outer door (timed);
--     pictures of the frost out of the vent from outside, mid-cycle;
--   * from the CHAMBER: put in it with every door shut after coming in from
--     outside, it cycles on to the hab; the panel's Cycle key from inside;
--   * a BREACH: the far door forced: DEPRESSURISATION, plant_av's klaxon at
--     the door, the hab's light a red beacon, the roar, grit drawn to the
--     hole; SILENCE; pictures;
--   * the cost with a cycle running and with the alarm up.
-- One `BK PASS|FAIL <check>` a check, `BK RESULT airlock`. Pictures land in
-- $WORK/proj/save/user/buildshots/al_*.png.
ALP = {}
local function shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time)
    else P("BK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("BK capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end
local function view(nm, rec, eye, tgt, hold)
  local b = home()
  local e, t = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(e, b), sub(t, b))
  wait(hold or 0.6)
  shot(nm)
  VP.cam_off()
end
function ALP.run()
  BK.tag = "airlock"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local KL, RA, PA = findScript("kit_live"), findScript("room_air"), findScript("plant_av")
  if not BK.check("scene", fb and ST and KL and RA and PA, "kit_live, room_air and plant_av are in the scene") then BK.result() return end
  RA.setVacuum(true)
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local sid, why
  for _, o in ipairs({ { 8, -2 }, { 7, 0 }, { 9, 2 }, { 6, -4 }, { 10, 0 }, { 8, 3 }, { 11, -3 } }) do
    fb.hold("slab2.concrete")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  for _, x in ipairs({ 2, 4 }) do
    fb.hold("slab2.concrete")
    yield()
    local h = KIT.ray(rec, { x, 4, 0 }, { x, -4, 0 })
    if h then fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node) end
    rec = ST.get(sid)
  end
  fb.dropHeld()
  local T = 0.2
  local function put(id, x, y, z, yaw, pitch)
    local p = { body = rec.b, mode = "face", sid = sid, lx = x, ly = y, lz = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }
    local s2, w2, q, uid = fb.place(sid, id, p, "money")
    if not s2 then P("AL %s refused: %s", id, tostring(w2)) end
    return uid
  end
  local H = math.pi / 2
  local U = {}
  U.outer = put("airlockWall.steel", -1, T, 0, H)
  U.inner = put("doorWall.steel", 1, T, 0, H)
  put("wall.steel", 0, T, -1, 0); put("wall.steel", 0, T, 1, 0)
  put("wall.steel", 2, T, -1, 0); put("wall.steel", 4, T, -1, 0)
  put("windowWall.steel", 2, T, 1, 0); put("wall.steel", 4, T, 1, 0)
  U.far = put("doorWall.steel", 5, T, 0, H)
  for _, x in ipairs({ 0, 2, 4 }) do put("floor.steel", x, T + 2.2, 0) end
  U.rtg = put("vab.rtg", 2.4, T, -0.55, 0)
  U.tank = put("airTank.steel", 4.35, T, -0.62, 0)
  U.light = put("lightFitting.steel", 3.0, T + 2.2 - 0.001, 0, 0, math.pi)
  rec = ST.get(sid)
  P("AL built: %d pieces · outer %s inner %s far %s", #rec.bp, tostring(U.outer), tostring(U.inner), tostring(U.far))
  KIT.close(fb)
  wait(2.0)
  local st = RA.state(sid)
  local RL = findScript("rooms")
  local ch = st and st.R and RL.roomAt(st.R, 0, 1.2, 0)
  local hab = st and st.R and RL.roomAt(st.R, 3, 1.2, 0)
  if not BK.check("rooms", ch and ch.airlock and hab and not hab.airlock, "the chamber an airlock (%.1f m³), the hab (%.1f m³)", ch and ch.m3 or -1, hab and hab.m3 or -1) then BK.result() return end
  wait_for(function() local a = RA.airOf(sid, hab.id); return a and a.p > 0.97 end, 90, "the hab pressurised")
  local both = false
  local function watch()
    local o, i = KL.doorOpen(sid, U.outer) or 0, KL.doorOpen(sid, U.inner) or 0
    if o > 0.02 and i > 0.02 then both = true end
  end
  local DZ = 0.46
  -- ── 1. FROM OUTSIDE ──
  KIT.tp(rec, -4, DZ)
  view("al1_panel_outside_standby", rec, { -2.6, 1.6, -0.9 }, { -1.1, 1.45, -0.28 })
  KIT.walk(rec, -1.9, DZ, 8, 0.3, watch)
  local t0 = time
  local op = wait_for(function() watch(); return (KL.doorOpen(sid, U.outer) or 0) > 0.95 end, 30, "the outer door")
  local t_outer = time - t0
  BK.check("outside_open", op, "from outside the outer door opens in %.1f s (the chamber at %.2f atm)", t_outer, RA.airOf(sid, ch.id).p)
  KIT.walk(rec, 0.0, DZ, 8, 0.3, watch)
  t0 = time
  local mid_shot = false
  local labels = {}
  local inn = wait_for(function()
    watch()
    local o = RA.airlockStatus(sid, U.inner)
    if o then labels[o.label] = true end
    if not mid_shot and o and o.label == "EQUALISING" and time - t0 > 0.5 then
      mid_shot = true
      view("al2_chamber_filling_vapour", rec, { 0.7, 1.9, 0.75 }, { -0.4, 1.2, -0.3 }, 0.3)
    end
    return (KL.doorOpen(sid, U.inner) or 0) > 0.95
  end, 60, "the inner door")
  local t_in = time - t0
  local ls = {}
  for k in pairs(labels) do ls[#ls + 1] = k end
  table.sort(ls)
  BK.check("in_cycle", inn and t_in < 15, "in the chamber: outer shut, filled, inner open in %.1f s (panel: %s)", t_in, table.concat(ls, ", "))
  BK.check("interlock_in", not both, "never both doors open on the way in")
  P("AL TIMES in: outer %.1f s, chamber to inner %.1f s · last cycle %.1f s", t_outer, t_in, RA.lastCycleSecs or -1)
  KIT.walk(rec, 2.6, DZ, 8, 0.3, watch)
  wait(8)
  -- ── 2. FROM THE HAB, out ──
  KIT.walk(rec, 1.7, DZ, 8, 0.3, watch)
  t0 = time
  local io = wait_for(function() watch(); return (KL.doorOpen(sid, U.inner) or 0) > 0.95 end, 30, "the inner door from the hab")
  local t_inner = time - t0
  BK.check("hab_open", io, "from the hab the inner door opens in %.1f s", t_inner)
  KIT.walk(rec, 0.0, DZ, 8, 0.3, watch)
  t0 = time
  local vent_shot = false
  local costed = false
  local outd = wait_for(function()
    watch()
    local o = RA.airlockStatus(sid, U.outer)
    if not costed and o and o.label == "CYCLING" then
      costed = true
      local fr0 = FRAME
      sc_begin("airlock_cycle"); wait(1.0); sc_end("airlock_cycle")
      P("AL PERF cycling: room_air %.4f, kit_live %.4f, plant_av %.4f ms/frame (%d frames) · puffs %d",
        perf.scriptMs("room_air") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("plant_av") or -1, FRAME - fr0, RA.PROF.puffs or 0)
    end
    if not vent_shot and o and (o.label == "VENTING" or (RA.lastPuff and RA.lastPuff.key == "LockVent")) then
      vent_shot = true
      view("al3_vent_frost_outside", rec, { -3.4, 1.5, 1.6 }, { -1.3, 1.6, 0.3 }, 0.5)
      view("al3b_vent_frost_outside", rec, { -3.4, 1.5, 1.6 }, { -1.3, 1.6, 0.3 }, 0.5)
    end
    return (KL.doorOpen(sid, U.outer) or 0) > 0.95
  end, 60, "the outer door from the chamber")
  local t_out = time - t0
  BK.check("out_cycle", outd and t_out < 15, "from the chamber: inner shut, pumped down, outer open in %.1f s", t_out)
  BK.check("interlock_out", not both, "never both doors open on the way out")
  BK.check("av_seen", (RA.PROF.puffs or 0) > 4 and vent_shot, "the cycles puffed vapour and frost (%d puffs, the vent seen %s)", RA.PROF.puffs or 0, tostring(vent_shot))
  P("AL TIMES out: inner %.1f s, chamber to outer %.1f s", t_inner, t_out)
  -- ── 3. FROM THE CHAMBER, every door shut ──
  KIT.walk(rec, -3.0, DZ, 8, 0.3, watch)
  wait_for(function() return (KL.doorOpen(sid, U.outer) or 0) < 0.02 end, 10, "the outer door shut behind")
  wait(1.0)
  KIT.tp(rec, 0.0, -0.2)
  t0 = time
  local on = wait_for(function() watch(); return (KL.doorOpen(sid, U.inner) or 0) > 0.95 or (KL.doorOpen(sid, U.outer) or 0) > 0.5 end, 30, "a door from the chamber")
  BK.check("chamber_on", on and (KL.doorOpen(sid, U.inner) or 0) > 0.95, "found in the chamber with both doors shut, having come from outside: it cycles on to the hab (%.1f s)", time - t0)
  -- the panel's key from inside: back out
  RA.cycleTo(sid, U.outer)
  t0 = time
  local back = wait_for(function() watch(); return (KL.doorOpen(sid, U.outer) or 0) > 0.95 end, 30, "the outer door on the key")
  BK.check("panel_key", back, "the outer panel's Cycle key from inside the chamber takes it back out (%.1f s)", time - t0)
  view("al4_panel_inside_ready", rec, { 0.3, 1.6, -0.5 }, { -0.9, 1.45, -0.28 })
  -- ── 4. A BREACH ──
  KIT.walk(rec, 0.2, DZ, 6, 0.3, watch)
  RA.cycleTo(sid, U.inner)
  wait_for(function() return (KL.doorOpen(sid, U.inner) or 0) > 0.95 end, 30, "the inner door")
  KIT.walk(rec, 3.0, DZ, 8, 0.3, watch)
  wait(6)
  RA.forceDoor(sid, U.far)
  wait(1.5)
  local al = nil
  for _, a in pairs(PA.alarms()) do if a.sid == sid and a.kind == "depress" then al = a end end
  local beac = false
  for k in pairs(KL.lit()) do local e = KL.entries()[k]; if e and e.lit == "alarm" then beac = true end end
  BK.check("breach_alarm", al ~= nil and al.snd ~= nil and (PA.alarmLevel(sid) or 0) >= 2,
    "the far door forced: DEPRESSURISATION, the klaxon at its door (%s)", al and tostring(al.text) or "no alarm")
  BK.check("beacon", beac, "the hab's ceiling light turns a red beacon")
  view("al5_breach_beacon_inside", rec, { 1.4, 1.7, 0.6 }, { 4.6, 1.0, 0.0 }, 0.2)
  view("al5b_breach_beacon_inside_2", rec, { 1.4, 1.7, 0.6 }, { 4.6, 1.0, 0.0 }, 0.35)
  view("al6_breach_outside", rec, { 7.6, 1.6, 2.2 }, { 5.0, 1.1, 0.4 }, 0.4)
  view("al6b_breach_outside", rec, { 7.6, 1.6, 2.2 }, { 5.0, 1.1, 0.4 }, 0.5)
  BK.check("breach_av", RA.lastBreach ~= nil, "the breach roars and draws grit to the hole (dp %.2f atm)", RA.lastBreach and RA.lastBreach.dp or -1)
  local fr0 = FRAME
  sc_begin("breach"); wait(1.5); sc_end("breach")
  P("AL PERF breach: room_air %.4f, kit_live %.4f, plant_av %.4f ms/frame (%d frames)", perf.scriptMs("room_air") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("plant_av") or -1, FRAME - fr0)
  local n = PA.silence(sid, "hand")
  wait(1.0)
  local quiet = true
  for _, a in pairs(PA.alarms()) do if a.sid == sid and a.snd then quiet = false end end
  BK.check("silence", n > 0 and quiet and (PA.alarmLevel(sid) or 0) >= 2, "SILENCE: %d silenced, the beacons stay", n)
  BK.result()
end
