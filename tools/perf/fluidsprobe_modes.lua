-- ── kit probe, mode "fluids" (sandbox plan S7: fluids and pressure mechanics) ──
-- Spliced after reactorprobe_modes.lua (KIT / BK / PW / RXP helpers) by tools/perf/kitprobe.sh.
-- On the home world with the outside forced to vacuum (room_air.setVacuum):
--   1. a hab of pieces: an airlock chamber (an Airlock Wall out, a Door Wall
--      in, an Airlock Receiver in it), a 6 × 4 m hab with a Pressure Bulkhead
--      to the outside at its far end, two Air Tank Racks, a scrubber, a light;
--      the base grid (tower, banks, arrays) powers it; inside, a Water Tank,
--      a pipe and a Process Pump to an O2 Generator's water nozzle;
--   2. WATER → O2: the tank filled from the stores, the generator's cell
--      refilled by the pump, the O2 it makes, the hydrogen vented; the FLUIDS
--      overlay (flow chevrons, the tank's level, the pump, LIMITED BY);
--   3. THE AIRLOCK KEEPS ITS AIR: in from outside, out again: its pump puts
--      the chamber's air into its receiver (and draws on the grid), the rest
--      under its floor vented; back in, the receiver gives it back;
--   4. THE SUIT RULE: helmet off in the hab, the bulkhead to the outside
--      refuses, and says to put it on;
--   5. EQUALISE: the bulkhead's own valve bleeds the hab until it can open
--      (the time against the formula, on 10× warp);
--   6. FORCE: refilled, the bulkhead forced from its menu (a timed job): the
--      warning first, the gust (VentBurst), the pull on the crew, the seal
--      damaged and leaking once shut; re-seated by the Engineer;
--   7. LOCA: a reactor of components beside the hab (the S6 fixture) at
--      power by the plant's own catch-up, a Coolant Tank and a Process Pump
--      on the pressuriser's makeup nozzle: the pump STALLS against 15.5 MPa;
--      a primary pipe cut from its menu: the trip, the blowdown, the
--      inventory falling, the BREAK on the FLUIDS overlay; depressurised, the
--      same pump refills the loop; the console read at 1.5 m (its pages);
--   8. save and reload: the tank, the receiver, the seal, the break, the inventory.
-- `BK PASS|FAIL`, `FL …` lines, `BK RESULT fluids: PASS/FAIL`.
FLP = {}

-- run a menu entry the way the menu does: its job ticked each frame, then done
function FLP.job(e, secs)
  if not e then return false, "no entry" end
  local reg = findScript("context_registry")
  local ok, why, job = reg.press(e)
  if not job then return ok, why end
  local t0, T = time, math.min(secs or job.secs or 1, job.secs or 1)
  while time - t0 < T do
    if job.check then local c, w = job.check(); if c == false then return false, w end end
    if job.tick then pcall(job.tick, 1 / 60, (time - t0) / math.max(T, 0.1)) end
    yield()
  end
  return job.done()
end
-- a picture now, from the camera already set (a short-lived effect: no wait)
function FLP.snap(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time)
    else P("BK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("BK capture error %s", tostring(err)) end
  wait_for(function() return done end, 5, "shot " .. nm)
end
-- wait for cond on 20× warp (the air and the fluids run on the agency clock)
function FLP.fast(cond, tmo, tag)
  space.warp(20)
  local ok = wait_for(cond, tmo, tag)
  space.warp(1)
  wait(0.3)
  return ok
end
local function menu(ST, sid, uid) return BK.menu(ST.nodeOf(sid, uid)) end
local function fline(FN, sid, uid, tag)
  local o = FN.readout(sid, uid)
  if not o then P("FL %s: no readout", tag) return nil end
  P("FL %s: x %s / %s · p %s bar · q %s kg/s · mode %s · in %s out %s · lim %s", tag, tostring(o.x and string.format("%.2f", o.x)), tostring(o.cap and string.format("%.1f", o.cap)),
    tostring(o.p and string.format("%.3f", o.p / 1e5)), tostring(o.q and string.format("%.4f", o.q)), tostring(o.mode),
    tostring(o.pu and string.format("%.2f", o.pu / 1e5)), tostring(o.pv and string.format("%.2f", o.pv / 1e5)), tostring(o.lim))
  return o
end

function FLP.run()
  BK.tag = "fluids"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local KL, RA, FN, FLs = findScript("kit_live"), findScript("room_air"), findScript("fluid_net"), findScript("fluids")
  local RP, RX, BG = findScript("reactor_plant"), findScript("reactor"), findScript("base_grid")
  if not BK.check("scene", fb and ST and KL and RA and FN and FLs and RP and BG, "room_air, fluids, fluid_net and reactor_plant are in the scene") then BK.result() return end
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
  do local rs = findScript("research"); if rs and rs.grant then for _, t in ipairs({ "rtg", "radPanel", "ember" }) do pcall(rs.grant, t, "probe") end end end
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local cp = findScript("catalog_panel")
  local nl = cp and cp.listFor and cp.listFor(fb, "FLUID", "") or {}
  P("FL the FLUID tab: %d cards", #nl)
  BK.check("tab", #nl >= 18, "the FLUID section lists the pieces (%d)", #nl)
  -- ── 1. the hab ──
  local sid, why
  for _, o in ipairs({ { 9, -3 }, { 8, 0 }, { 10, 2 }, { 7, -5 }, { 11, 0 }, { 9, 3 }, { 12, -3 } }) do
    fb.hold("slab2.concrete")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  fb.dropHeld()
  local rec = ST.get(sid)
  for _, s in ipairs({ { 2, 0 }, { 4, 0 }, { 6, 0 }, { 2, 2 }, { 4, 2 }, { 6, 2 } }) do ST.addPart(sid, { id = "slab2.concrete", x = s[1], y = 0, z = s[2], yaw = 0 }) end
  ST.spawnNow(sid)
  wait(1.0)
  rec = ST.get(sid)
  local T = 0.2
  local H = math.pi / 2
  local function put(id, x, y, z, yaw, pitch)
    local p = { body = rec.b, mode = "face", sid = sid, lx = x, ly = y, lz = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }
    local s2, w2, q, uid = fb.place(sid, id, p, "money")
    if not s2 then P("FL %s refused: %s · added as a record", id, tostring(w2)); uid = ST.addPart(sid, { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }) end
    return uid
  end
  local U = {}
  U.outer = put("airlockWall.steel", -1, T, 0, H)
  U.inner = put("doorWall.steel", 1, T, 0, H)
  put("wall.steel", 0, T, -1, 0); put("wall.steel", 0, T, 1, 0)
  for _, x in ipairs({ 2, 4, 6 }) do put(x == 4 and "windowWall.steel" or "wall.steel", x, T, -1, 0); put("wall.steel", x, T, 3, 0) end
  put("wall.steel", 1, T, 2, H)
  U.far = put("bulkhead.steel", 7, T, 0, H)
  put("wall.steel", 7, T, 2, H)
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 4, 0 }, { 6, 0 }, { 2, 2 }, { 4, 2 }, { 6, 2 } }) do put("floor.steel", s[1], T + 2.2, s[2]) end
  U.recv = put("airReceiver.steel", 0, T, -0.45, 0)
  U.scrub = put("scrubber.steel", 2.0, T, -0.65, 0)
  U.tankA = put("airTank.steel", 5.4, T, -0.66, 0)
  U.tankB = put("airTank.steel", 3.6, T, -0.66, 0)
  U.light = put("lightFitting.steel", 4.0, T + 2.2 - 0.001, 1.0, 0, math.pi)
  -- the water line, along +X at z 2.2: tank → pipe → pump → the generator's water nozzle
  U.wtank = put("flTankWater.steel", 2.2, T, 2.2, -H)
  U.wpipe = put("flPipe1.steel", 3.7, T, 2.2, H)
  U.wpump = put("flPump.steel", 4.7, T, 2.2, H)
  U.gen = put("o2gen.steel", 5.5, T, 2.4, H)
  -- the base grid: a tower, banks, arrays
  ST.addPart(sid, { id = "tower", x = -8, y = 0, z = 12, yaw = 0 })
  for k = 1, 4 do ST.addPart(sid, { id = "batteryBank", x = -8 + 3 * (k - 1), y = 0, z = 17, yaw = 0 }) end
  ST.addPart(sid, { id = "solarArray", x = -14, y = 0, z = 4, yaw = 0 })
  ST.addPart(sid, { id = "solarArray", x = -14, y = 0, z = 9, yaw = 0 })
  ST.spawnNow(sid)
  wait(2.5)
  local BT = findScript("base_tower")
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  rec = ST.get(sid)
  P("FL built: %d pieces · outer %s inner %s far %s recv %s tank %s pump %s gen %s", #rec.bp, tostring(U.outer), tostring(U.inner), tostring(U.far), tostring(U.recv), tostring(U.wtank), tostring(U.wpump), tostring(U.gen))
  KIT.close(fb)
  wait(2.5)
  local st = RA.state(sid)
  local R = st and st.R
  local RL = findScript("rooms")
  local ch = R and RL.roomAt(R, 0, 1.2, 0)
  local hab = R and RL.roomAt(R, 4, 1.2, 1)
  local nsealed = 0
  for _, r in ipairs(R and R.rooms or {}) do if r.sealed then nsealed = nsealed + 1 end end
  BK.check("rooms", R and nsealed == 2 and ch and ch.airlock and hab and not hab.airlock,
    "two sealed rooms: the chamber an airlock (%.1f m³) and the hab (%.1f m³)", ch and ch.m3 or -1, hab and hab.m3 or -1)
  if not (ch and hab) then BK.result() return end
  BK.check("powered", st.pow == true, "the hab is on a live base grid")
  -- (the hab up to 1 atm from its racks; refilled on the way)
  local function refill()
    for _, u in ipairs({ U.tankA, U.tankB }) do
      local e = BK.entry(menu(ST, sid, u), "ra_refill")
      if e and e.act then e.act() end
    end
  end
  local t0 = time
  FLP.fast(function() local a = RA.airOf(sid, hab.id); return a and a.p > 0.97 end, 60, "the hab pressurised")
  P("FL hab pressurised in %.0f s: %.3f atm", time - t0, RA.airOf(sid, hab.id).p)
  refill()
  -- ── 2. water → O2 ──
  FN.stepNow()
  local tf = BK.entry(menu(ST, sid, U.wtank), "fl_fill")
  if tf and tf.act then tf.act() end
  wait(1.0)
  local x0 = FN.content(sid, U.wtank)
  BK.check("tank_fill", x0 and x0 > 1990, "the Water Tank filled from the base stores: %.0f kg", x0 or -1)
  -- the cell drawn down, so the line has work to do; the hab's O2 thinned, so the generator runs
  st = RA.state(sid)
  st.cells[U.gen] = 4.0
  local Ah = st.air[hab.id]
  Ah.x = Ah.x * 0.8
  st.netsDirty = true
  local made0 = st.made[U.gen] or 0
  wait(8)
  FN.stepNow()
  local w1 = RA.cellOf(sid, U.gen)
  local op = fline(FN, sid, U.wpump, "the pump")
  local ot = fline(FN, sid, U.wtank, "the tank")
  local oc = FN.readout(sid, U.gen)
  BK.check("feed", w1 and w1 > 19 and op and (op.q or 0) >= 0 and ot and ot.x < x0, "the pump refilled the O2 Generator's water cell from the tank: %.1f L (was 4), the tank %.2f kg", w1 or -1, ot and ot.x or -1)
  RA.advanceNow()
  local made = (st.made[U.gen] or 0) - made0
  P("FL O2 made %.5f atm·m³ in the window, water cell %.2f L, H2 vented %.4f kg kept %.4f kg", made, RA.cellOf(sid, U.gen) or -1, FN.entry(sid).h2vented or 0, FN.entry(sid).h2kept or 0)
  BK.check("o2", made > 0, "the generator made O2 from the water (%.5f atm·m³)", made)
  -- the overlay, inside the hab (two angles)
  FN.overlay, FN.overlayAlways = true, true
  RA.overlay, RA.overlayAlways = false, false
  wait(1.0)
  KIT.oview("f1_fluids_overlay_inside", rec, { 2.2, 2.05, 0.2 }, { 4.6, 0.9, 2.3 })
  KIT.oview("f1b_fluids_overlay_inside_east", rec, { 6.5, 1.95, 0.0 }, { 3.5, 0.8, 2.3 })
  BK.check("overlay", (FN.drawn.lines or 0) >= 3 and (FN.drawn.labels or 0) >= 3, "the FLUIDS overlay: %d lines, %d labels", FN.drawn.lines or 0, FN.drawn.labels or 0)
  FN.overlayAlways = false
  -- ── 3. the airlock keeps its air ──
  local both = false
  local function watch() if (KL.doorOpen(sid, U.outer) or 0) > 0.02 and (KL.doorOpen(sid, U.inner) or 0) > 0.02 then both = true end end
  local DZ = 0.46
  -- (inside: KIT.tp's ray from 4 m would land on the roof)
  do
    local a = astro()
    local w = KIT.w(rec, 2.6, T + 1.0, DZ)
    a.x, a.y, a.z = w.x, w.y, w.z
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(2.0)
  end
  BK.check("in", select(2, RA.crewRoom()) == hab.id, "the crew in the hab")
  -- and out: the pump into the receiver
  KIT.walk(rec, 1.6, DZ, 6, 0.3, watch)
  wait_for(function() watch(); return (KL.doorOpen(sid, U.inner) or 0) > 0.95 end, 60, "the inner door again")
  KIT.walk(rec, 0.0, DZ, 6, 0.3, watch)
  local q0 = st.recv[U.recv]; local r0 = q0.N + q0.x + q0.c
  local pumping_kw, cyc_t0 = 0, time
  RA.overlay, RA.overlayAlways = true, true
  local shot_mid = false
  local outer = wait_for(function()
    watch()
    pumping_kw = math.max(pumping_kw, RA.gridAux(sid, U.outer))
    local c = RA.chamberOf(sid, ch.id)
    if c and c.pumping and not shot_mid and time - cyc_t0 > 8 then shot_mid = true end
    return (KL.doorOpen(sid, U.outer) or 0) > 0.95
  end, 180, "the outer door, cycled out")
  local C1 = RA.chamberOf(sid, ch.id)
  st = RA.state(sid)
  local q1 = st.recv[U.recv]; local r1 = q1.N + q1.x + q1.c
  local n0 = (C1.saved or 0) + (C1.vented or 0) + RA.airOf(sid, ch.id).p * ch.m3
  P("FL CYCLE out: %.0f s · saved %.2f vented %.2f atm·m³ · receiver %.2f → %.2f · pump %.1f kW · %s", time - cyc_t0, C1.saved or 0, C1.vented or 0, r0, r1, pumping_kw, tostring(RA.lastCycle))
  BK.check("receiver", outer and not both and (r1 - r0) / math.max(n0, 1e-6) > 0.85 and pumping_kw >= 2.4,
    "cycled out: the pump put %.0f %% of the chamber's air into its receiver (%.1f atm·m³), drawing %.1f kW from the grid; never both doors open", 100 * (r1 - r0) / math.max(n0, 1e-6), r1 - r0, pumping_kw)
  KIT.oview("f2_airlock_receiver", rec, { -3.2, 2.0, 2.4 }, { 0.0, 1.0, -0.3 })
  RA.overlayAlways = false
  -- back in: the receiver gives it back
  KIT.walk(rec, -2.0, DZ, 6, 0.3, watch)
  KIT.walk(rec, 0.0, DZ, 6, 0.3, watch)
  wait_for(function() watch(); return (KL.doorOpen(sid, U.inner) or 0) > 0.95 end, 120, "the inner door, cycled in")
  local q2 = st.recv[U.recv]; local r2 = q2.N + q2.x + q2.c
  BK.check("receiver_back", r1 - r2 > 0.5 * (r1 - r0) and not both, "cycled in: the receiver gave %.1f atm·m³ back (%.1f left)", r1 - r2, r2)
  KIT.walk(rec, 2.4, DZ, 8, 0.3)
  wait(1.5)
  refill()
  FLP.fast(function() local a = RA.airOf(sid, hab.id); return a and a.p > 0.97 end, 30, "the hab back up")
  -- ── 4. the suit rule ──
  local su = findScript("suit")
  local okh = su.canRemoveHelmet()
  if okh then su.setHelmet(false, { instant = true }) end
  wait(0.5)
  RA.lastSuitRefusal = nil
  -- (the camera set first: the SUIT caption lasts 3 s)
  do local b0 = home(); VP.cam_fixed(sub(KIT.w(rec, 4.4, 1.7, 0.9), b0), sub(KIT.w(rec, 6.8, 1.2, 0.2), b0)) end
  KIT.walk(rec, 6.2, DZ, 8, 0.3)
  wait(0.6)
  FLP.snap("f3_suit_refusal")
  VP.cam_off()
  wait(1.5)
  local ref = RA.lastSuitRefusal
  BK.check("suit", okh and not su.helmetOn() and ref and ref.uid == U.far and (KL.doorOpen(sid, U.far) or 1) < 0.02,
    "helmet off by the bulkhead to the outside: it refuses (%.2f atm beyond) and says to put the helmet on", ref and ref.p or -1)
  su.setHelmet(true, { instant = true })
  wait(1.0)
  -- ── 5. equalise: the bulkhead's own valve ──
  local held = (KL.doorOpen(sid, U.far) or 1) < 0.02
  local ents = menu(ST, sid, U.far)
  local eq = BK.entry(ents, "ra_eq")
  local eta = RA.equaliseEta(sid, U.far)
  P("FL bulkhead menu: %s · eq row %s · eta %.0f s", tostring(BK.entry(ents, "ra_held") and "held" or "?"), tostring(eq and eq.label), eta or -1)
  if eq and eq.act then eq.act(true) end
  local a0 = findScript("deployables").agencyClock()
  space.warp(10)
  local opened = wait_for(function() return (KL.doorOpen(sid, U.far) or 0) > 0.5 end, 120, "the bulkhead equalised")
  local took = findScript("deployables").agencyClock() - a0
  space.warp(1)
  P("FL EQUALISE: the bulkhead opened after %.0f s of game time (the formula %.0f s; warp 10)", took, eta or -1)
  BK.check("equalise", held and eq and opened and eta and math.abs(took - eta) < 0.15 * eta + 6,
    "the bulkhead's equalising valve bled the hab to the outside until it opened: %.0f s (its menu said ~%.0f s)", took, eta or -1)
  KIT.walk(rec, 4.0, DZ, 6, 0.3)
  wait_for(function() return (KL.doorOpen(sid, U.far) or 1) < 0.02 end, 20, "the bulkhead shut")
  refill()
  FLP.fast(function() local a = RA.airOf(sid, hab.id); if a and a.p < 0.6 then refill() end return a and a.p > 0.97 and not a.venting end, 60, "the hab refilled")
  refill()
  -- ── 6. force: the bulkhead again, 1 atm against the vacuum ──
  -- (the flora off for the outdoor pictures: a tree or a cap in front of the camera otherwise)
  do local FLr = findScript("flora_field"); if FLr and FLr.params then FLr.params.enabled = 0 end end
  KIT.walk(rec, 6.2, DZ, 6, 0.3)
  wait(1.0)
  local dpf = RA.door_dp(RA.state(sid), U.far)
  local fe = BK.entry(menu(ST, sid, U.far), "ra_force")
  P("FL force row: %s · %.2f atm across", fe and tostring(fe.label) or "none", dpf or -1)
  RA.lastWarning, RA.lastBurst = nil, nil
  local pw = findScript("planet_walker")
  pw.lastPull = nil
  -- (the camera outside the bulkhead first: the gust lasts two seconds)
  do local b0 = home(); VP.cam_fixed(sub(KIT.w(rec, 10.0, 1.9, -2.6), b0), sub(KIT.w(rec, 7.3, 1.0, 0.4), b0)) end
  local ok_f = FLP.job(fe)
  local warned = RA.lastWarning
  wait(0.35)
  FLP.snap("f4_forced_gust")
  wait(0.5)
  FLP.snap("f4b_forced_gust_later")
  VP.cam_off()
  local b = RA.lastBurst
  local seal = RA.sealOf(sid, U.far)
  P("FL FORCE: ok %s · warning %s (crew %s) · burst dp %.2f dir (%.2f %.2f %.2f) · pull %s · seal %.0f %%", tostring(ok_f), tostring(warned and warned.why), tostring(warned and warned.crew),
    b and b.dp or -1, b and b.dx or 0, b and b.dy or 0, b and b.dz or 0, pw.lastPull and string.format("%.2f m/s", math.sqrt(pw.lastPull.x ^ 2 + pw.lastPull.y ^ 2 + pw.lastPull.z ^ 2)) or "none", seal * 100)
  BK.check("force", ok_f and warned and warned.crew and b and b.dp > 0.8 and pw.lastPull ~= nil and seal > 0,
    "forced: the hab warned first, then the gust through the doorway, the crew pulled toward it, the seal damaged (%.0f %%)", seal * 100)
  wait(6)
  KIT.walk(rec, 4.0, DZ, 6, 0.3)
  wait_for(function() return (KL.doorOpen(sid, U.far) or 1) < 0.02 end, 20, "the bulkhead shut")
  refill()
  FLP.fast(function() local a = RA.airOf(sid, hab.id); if a and a.p < 0.6 then refill() end return a and a.p > 0.9 end, 60, "the hab refilled with the seal leaking")
  local qh = RA.airOf(sid, hab.id)
  local leak = false
  for _, c in ipairs(qh.causes or {}) do if c:find("seal", 1, true) then leak = true end end
  RA.overlay, RA.overlayAlways = true, true
  KIT.oview("f5_seal_leak_overlay", rec, { 5.0, 2.0, 2.5 }, { 7.0, 1.0, 0.2 })
  RA.overlayAlways = false
  BK.check("leak", leak, "shut again, its damaged seal leaks: %s (%.2f atm)", tostring(qh.causes and qh.causes[1]), qh.p)
  local rp = BK.entry(menu(ST, sid, U.far), "ra_repair")
  local ok_r = FLP.job(rp)
  BK.check("repair", ok_r and RA.sealOf(sid, U.far) == 0, "the Engineer re-seated the seal (%s)", rp and tostring(rp.hint) or "no row")
  -- ── 7. LOCA ──
  -- the reactor, on its own floor 30 m east of the hab
  local OX, OZ, Y = 30, 0, 0.2
  for x = -6, 14, 2 do for z = -8, 12, 2 do ST.addPart(sid, { id = "slab2.concrete", x = OX + x, y = 0, z = OZ + z, yaw = 0 }) end end
  local RU = {}
  for _, L in ipairs(RXP.LAYOUT) do
    local u = ST.addPart(sid, { id = L[1], x = L[2] + OX, y = Y, z = L[3] + OZ, yaw = L[4], pitch = 0, roll = 0 })
    if L[5] then RU[L[5]] = u end
  end
  local KIND = { F = "fuelChannel.steel", W = "modWater.steel", R = "controlRod.steel" }
  local cells = {}
  for r = 1, 5 do
    local j = 3 - r
    for i = -2, 2 do
      local c = RXP.CORE[r]:sub(i + 3, i + 3)
      if KIND[c] then cells[#cells + 1] = { uid = ST.addPart(sid, { id = KIND[c], x = i * 0.5 + OX, y = Y + 1.0, z = j * 0.5 + OZ, yaw = 0 }), ch = c } end
    end
  end
  -- the makeup: a Coolant Tank, a pipe and a Process Pump onto the pressuriser's makeup nozzle (+X turned: −X at (OX+0.5, OZ−4.5))
  RU.ctank = ST.addPart(sid, { id = "flTankCool.steel", x = OX - 2.5, y = Y, z = OZ - 4.5, yaw = -H })
  RU.cpipe = ST.addPart(sid, { id = "flPipe1.steel", x = OX - 1.0, y = Y, z = OZ - 4.5, yaw = H })
  RU.cpump = ST.addPart(sid, { id = "flPump.steel", x = OX + 0.0, y = Y, z = OZ - 4.5, yaw = H })
  RU.console = ST.addPart(sid, { id = "reactorConsole.steel", x = OX + 11.5, y = Y, z = OZ - 1.0, yaw = H })
  ST.spawnNow(sid)
  wait(3.0)
  rec = ST.get(sid)
  RP.stepNow()
  local key = RP.keyOf(sid, RU.vessel)
  local e = RP.plant(key)
  if not BK.check("plant", e ~= nil and e.pl.pri.closed, "the plant beside the hab: %s, primary closed %s", key, tostring(e and e.pl.pri.closed)) then BK.result() return end
  for _, c in ipairs(cells) do if c.ch == "F" then RP.loadRods(sid, c.uid, "fuelRod", 4); RP.loadRods(sid, c.uid, "fuelRodNU", 4) end end
  wait(1.0)
  FN.stepNow()
  FN.setContent(sid, RU.ctank, 2000)
  RP.startUp(key, 1.0)
  RXP.skip(5400, "start-up")
  e = RP.plant(key)
  P("FL plant at power: P %.3f Tp %.0f inv %.3f Mw %.0f kg tsat %.0f", e.o.P or -1, e.o.Tp or -1, e.o.inv or -1, e.M.Mw or -1, e.M.tsat or -1)
  wait(1.5)
  FN.stepNow()
  local o_stall = fline(FN, sid, RU.cpump, "makeup pump at 15.5 MPa")
  BK.check("stall", e.o.P > 0.9 and o_stall and o_stall.mode == "stall" and (o_stall.lim or ""):find("can't beat", 1, true),
    "at power: the makeup pump stalls against the pressurised primary (%s)", tostring(o_stall and o_stall.lim))
  -- the pipe cut (the menu's job): the 2 m pipe on the cold leg
  local cutUid = nil
  for _, p in ipairs(rec.bp) do if p.id == "pipeIns2.steel" and math.abs(p.x - (OX + 4.0)) < 0.01 and math.abs(p.z - (OZ - 1.5)) < 0.01 then cutUid = p.uid end end
  local ce = cutUid and BK.entry(menu(ST, sid, cutUid), "rx_cut")
  local ok_c = FLP.job(ce)
  local tc = findScript("deployables").agencyClock()
  wait(3.0)
  e = RP.plant(key)
  local inv3 = e.o.inv or 1
  P("FL LOCA +3 s: %s · tripped %s (%s) · inv %.3f · break %.1f kg/s · Tp %.0f · tsat %.0f", tostring(ok_c), tostring(e.S.scram), tostring(e.S.cause), inv3, e.o.brk or -1, e.o.Tp or -1, e.M.tsat or -1)
  BK.check("loca", ok_c and e.S.scram and e.M.broken and inv3 < 0.95 and (e.o.brk or 0) > 1, "a primary pipe cut: the plant trips (%s), the loop depressurises, the coolant blows down (%.1f kg/s, %.0f %% left)", tostring(e.S.cause), e.o.brk or -1, inv3 * 100)
  FN.overlay, FN.overlayAlways = true, true
  KIT.tp(rec, OX + 9, OZ - 7)
  wait(1.5)
  KIT.oview("f6_loca_overlay", rec, { OX + 10, 6.5, OZ - 10 }, { OX + 2.5, 1.0, OZ - 2.0 })
  KIT.oview("f6b_loca_overlay_west", rec, { OX - 7, 5.0, OZ - 9 }, { OX + 2.0, 1.0, OZ - 2.5 })
  local RPd = RP.drawnFluids or {}
  BK.check("loca_overlay", (RPd.breaks or 0) >= 1, "the FLUIDS overlay rings the break and reads the inventory (%d breaks, %d plants)", RPd.breaks or 0, RPd.plants or 0)
  -- depressurised, the same pump gets in: the loop refills
  wait(15)
  FN.stepNow()
  local o_mk = fline(FN, sid, RU.cpump, "makeup pump, the loop broken")
  e = RP.plant(key)
  P("FL makeup: %.3f kg/s · inv %.3f · break %.1f kg/s", (e.o.mk or 0), e.o.inv or -1, e.o.brk or -1)
  BK.check("makeup", o_mk and o_mk.mode ~= "stall" and (o_mk.q or 0) > 1.0 and (e.o.mk or 0) > 1.0, "depressurised, the process pump pushes %.2f kg/s of coolant in through the pressuriser's nozzle", o_mk and o_mk.q or -1)
  KIT.oview("f7_makeup_overlay", rec, { OX - 4.5, 3.0, OZ - 8.0 }, { OX - 0.5, 0.8, OZ - 4.5 })
  FN.overlayAlways = false
  -- the console, read at 1.5 m, its pages
  local cpart = ST.getPart(sid, RU.console)
  KIT.tp(rec, OX + 13.5, OZ - 1.0)
  for k, nm in ipairs({ "f8_console_core_1p5m", "f8a_console_poisons_1p5m", "f8b_console_loops_1p5m", "f8c_console_power_1p5m" }) do
    RP.consolePage(sid, RU.console, k)
    wait(0.6)
    KIT.view(nm, rec, { cpart.x + 1.5, Y + 1.3, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  end
  RP.consolePage(sid, RU.console, 0)
  local ctext = RP.consoleText(sid, RU.console) or ""
  BK.check("console", ctext:find("INVENTORY", 1, true) and ctext:find("BROKEN", 1, true), "the console's LOOPS page reads the inventory and the broken loop")
  -- the cost
  do
    local fr0 = FRAME
    sc_begin("fluids_idle"); wait(4); sc_end("fluids_idle")
    P("FL PERF fluid_net %.4f, fluids %.4f, room_air %.4f, reactor_plant %.4f ms/frame (%d frames) · step %.3f ms, %d nets",
      perf.scriptMs("fluid_net") or -1, perf.scriptMs("fluids") or -1, perf.scriptMs("room_air") or -1, perf.scriptMs("reactor_plant") or -1,
      FRAME - fr0, FN.PROF.step_ms or -1, FN.PROF.nets or -1)
    BK.check("perf", (perf.scriptMs("fluid_net") or 0) < 0.25, "the fluid networks cost %.4f ms a frame", perf.scriptMs("fluid_net") or -1)
  end
  -- ── 8. save and reload ──
  FN.saveNow(); RA.saveNow(); RP.saveNow()
  local xs0 = FN.content(sid, U.wtank)
  local rs0 = st.recv[U.recv]; rs0 = rs0.N + rs0.x + rs0.c
  local inv0 = RP.plant(key).S.y[RX.IDX.inv]
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(5)
  RA, FN, RP, ST, RX = findScript("room_air"), findScript("fluid_net"), findScript("reactor_plant"), findScript("structures"), findScript("reactor")
  RA.setVacuum(true)
  wait(2)
  FN.stepNow(); RP.stepNow()
  local xs1 = FN.content(sid, U.wtank)
  local st2 = RA.state(sid)
  local rq = st2 and st2.recv[U.recv]
  local rs1 = rq and (rq.N + rq.x + rq.c) or -1
  local e2 = RP.plant(key)
  local brk = ST.partState(sid, cutUid)
  BK.check("reload", xs1 and math.abs(xs1 - xs0) < 1 and math.abs(rs1 - rs0) < 0.05 and e2 and e2.M.broken and brk and brk.brk,
    "after a reload: the water tank %.1f kg (was %.1f), the receiver %.2f atm·m³ (was %.2f), the break and the plant's inventory %.3f (was %.3f)",
    xs1 or -1, xs0 or -1, rs1, rs0, e2 and e2.S.y[RX.IDX.inv] or -1, inv0 or -1)
  BK.result()
end
