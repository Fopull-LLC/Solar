-- ── kit probe, mode "reactor" (sandbox plan S6: reactors built from components) ──
-- Spliced after powerprobe_modes.lua (KIT / BK / PW helpers) by tools/perf/kitprobe.sh.
--   1. a slab floor; a tower, battery banks and arrays (the black start); the
--      plant of tests/lib/reactor_fixture.lua (lagged pipes), its vessel's
--      outlet pipe placed through the kit's own port snap, a console, a
--      heavy shield wall on the west of the core;
--   2. the fuel: half LEU, half natural rods (a lean core), the refuelling rule;
--   3. start-up on the automatic controller to 100 %, real time warp: critical,
--      the heat-up, the turbine on the base grid; pictures with the NUCLEAR
--      overlay (two angles), the console, the dose field from above;
--   4. ten days at power (xenon to equilibrium, the long decay heat built), SCRAM by hand;
--   5. four hours on: the xenon pit: the forecast, a restart that can't reach
--      critical ("limited by xenon");
--   6. every pump and the tower's fan cut on the tripped plant: decay heat
--      takes the primary toward boiling: the overheat alarms;
--   7. save and reload: the trip, the xenon, the rods, the alarms.
-- `BK PASS|FAIL`, `RX …` lines, `BK RESULT reactor: PASS/FAIL`.
RXP = {}
local Q = math.pi / 2
-- the fixture's plant (tests/lib/reactor_fixture.lua with insulated = true,
-- sink = tower), as { id, x, z, yaw } in its own frame
RXP.LAYOUT = {
  { "reactorBase.steel", 0, 0, 0, "vessel" },
  { "pipe1.steel", 0, 2.0, 0, "snap" },                 -- (placed through the kit's port snap)
  { "steamGen.steel", 0.5, 3.5, 0, "sg" },
  { "pipeElbow.steel", 1.0, 2.0, -Q },
  { "pipeIns2.steel", 2.5, 2.0, Q },
  { "pipeElbow.steel", 4.0, 2.0, Q },
  { "coolantPump.steel", 4.0, 0.5, math.pi, "pump" },
  { "pipeIns2.steel", 4.0, -1.5, 0 },
  { "pipeElbow.steel", 4.0, -3.0, math.pi },
  { "pipeIns2.steel", 2.5, -3.0, Q },
  { "pipeTee.steel", 1.0, -3.0, Q },
  { "pressuriser.steel", 1.0, -4.5, math.pi, "press" },
  { "pipeElbow.steel", 0, -3.0, -Q },
  { "pipe1.steel", 0, -2.0, 0 },
  { "pipeIns2.steel", 0, 5.5, 0 },
  { "turbineSet.steel", 1.0, 7.5, 0, "turbine" },
  { "pipeElbow.steel", 2.0, 6.0, -Q },
  { "pipeIns2.steel", 3.5, 6.0, Q },
  { "pipeElbow.steel", 5.0, 6.0, math.pi },
  { "coolingTower.steel", 5.5, 8.5, 0, "tower" },
  { "pipeElbow.steel", 6.0, 6.0, -Q },
  { "pipeIns2.steel", 7.5, 6.0, Q },
  { "pipeElbow.steel", 9.0, 6.0, Q },
  { "pipeElbow.steel", 9.0, 5.0, math.pi },
  { "coolantPump.steel", 7.5, 5.0, -Q, "feed" },
  { "pipeIns2.steel", 5.5, 5.0, Q },
  { "pipeIns2.steel", 3.5, 5.0, Q },
  { "pipe1.steel", 2.0, 5.0, Q },
  { "pipeElbow.steel", 1.0, 5.0, 0 },
}
RXP.CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
local KIND = { F = "fuelChannel.steel", W = "modWater.steel", R = "controlRod.steel", G = "modGraphite.graphite", H = "modHeavy.steel" }

-- warp the game clock on by `secs` game seconds (the real warp keys), then back to 1×
-- a fixed picture with the world's draw shapes in it (the vessel's gauges)
function RXP.dview(nm, rec, eye, tgt)
  local b = home()
  local e, t = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(e, b), sub(t, b))
  wait(1.0)
  local done = false
  pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time) end
    done = true
  end)
  wait_for(function() return done end, 5, "shot " .. nm)
  VP.cam_off()
  wait(0.3)
end
function RXP.warp(secs, tag)
  local DP = findScript("deployables")
  local a0 = DP.agencyClock()
  -- (the warp set straight, as BK.daylight does; 1000× and lower for the last stretch)
  space.warp(1000)
  wait(0.3)
  P("RX warp %s: %.0f× for %.1f h", tag or "", space.warp(), secs / 3600)
  local t0 = time
  while DP.agencyClock() - a0 < secs and time - t0 < 240 do
    local left = secs - (DP.agencyClock() - a0)
    if left < 300 and space.warp() > 11 then space.warp(10) elseif left < 3000 and space.warp() > 101 then space.warp(100) end
    if space.warp() < 2 and left > 600 then space.warp(1000) end
    yield()
  end
  space.warp(1)
  wait(0.5)
  P("RX warp %s done: %.2f h on (asked %.2f), warp %.0f", tag or "", (DP.agencyClock() - a0) / 3600, secs / 3600, space.warp())
end

-- the long stretches: the plants' own catch-up (the load path): each
-- plant's clock set `secs` back, the 5 Hz ticks take it up 300 solver steps
-- at a time, exactly as a save loaded after a long absence is caught up
function RXP.skip(secs, tag)
  local RP = findScript("reactor_plant")
  local t0 = time
  for _, e in pairs(RP.plants()) do e.t = e.t - secs end
  local function behind()
    local DP = findScript("deployables")
    local a, m = DP.agencyClock(), 0
    for _, e in pairs(RP.plants()) do m = math.max(m, a - e.t) end
    return m
  end
  while behind() > 1 and time - t0 < 120 do yield() end
  P("RX catch-up %s: %.1f h in %.1f s real (%.2f s left behind)", tag or "", secs / 3600, time - t0, behind())
end

local function line(RP, e, tag)
  local o = e.o or {}
  P("RX %s: P %.4f k %.5f x %.3f · Tf %.0f Tp %.0f Ts %.0f Tk %.0f · %.1f kW th %.1f kW(e) · Xe %.3f b · mp %.2f · %s · %s",
    tag, o.P or -1, o.k or -1, o.x or -1, o.Tf or 0, o.Tp or 0, o.Ts or 0, o.Tk or 0, (o.Qcore or 0) / 1000, (o.Pe or 0) / 1000,
    e.S.y[9] or -1, o.mpe or -1, e.S.scram and ("TRIPPED " .. tostring(e.S.cause)) or e.S.mode, tostring(findScript("reactor").limitedBy(e.M, e.S, o)))
end
local function page_line(RP, e, tag)
  local pg = RP.page(e)
  local t = {}
  for _, l in ipairs(pg.lines) do t[#t + 1] = l[1] end
  local a = {}
  for _, x in ipairs(pg.alarms or {}) do a[#a + 1] = x[1] end
  P("RX PAGE %s: %s | %s | ALARMS %s", tag, pg.title, table.concat(t, " | "), table.concat(a, " · "))
  return pg
end

function RXP.run()
  BK.tag = "reactor"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local BG, BS, BT, BSs = findScript("base_grid"), findScript("base_shield"), findScript("base_tower"), findScript("bases")
  local RP, RX = findScript("reactor_plant"), findScript("reactor")
  if not BK.check("scene", fb and ST and BG and RP and RX and RX.layout, "reactor, reactor_plant and the base grid in the scene") then BK.result() return end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  BK.unlock()
  do local rs = findScript("research"); if rs and rs.grant then for _, t in ipairs({ "rtg", "radPanel", "ember" }) do pcall(rs.grant, t, "probe") end end end
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local cp = findScript("catalog_panel")
  local nl = cp and cp.listFor and cp.listFor(fb, "NUCLEAR", "") or {}
  P("RX the NUCLEAR tab: %d cards", #nl)
  BK.check("tab", #nl >= 15, "the NUCLEAR section lists the components (%d)", #nl)
  -- ── 1. the floor, the base, the plant ──
  local sid, why
  for _, o in ipairs({ { 8, 0 }, { 9, -2 }, { 10, 2 }, { 7, -4 }, { 11, 0 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab", sid ~= nil, "the first slab founds the plant's structure (%s)", tostring(why)) then BK.result() return end
  fb.dropHeld()
  local OX, OZ, Y = 2, 0, 0.2      -- the plant's offset on the floor; its pieces stand on the slabs' deck
  local n = 0
  for x = -4, 14, 2 do
    for z = -8, 12, 2 do
      if not (x == 0 and z == 0) then ST.addPart(sid, { id = "slab2.concrete", x = x, y = 0, z = z, yaw = 0 }); n = n + 1 end
    end
  end
  -- the base: a tower 22 m off, banks for the black start, two arrays
  ST.addPart(sid, { id = "tower", x = -14, y = 0, z = 14, yaw = 0 })
  for k = 1, 8 do ST.addPart(sid, { id = "batteryBank", x = -14 + 3 * (k - 1), y = 0, z = 20, yaw = 0 }) end
  ST.addPart(sid, { id = "solarArray", x = -20, y = 0, z = 4, yaw = 0 })
  ST.addPart(sid, { id = "solarArray", x = -20, y = 0, z = 9, yaw = 0 })
  ST.spawnNow(sid)
  wait(2.5)
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  local rec = ST.get(sid)
  local b = BSs.baseAt(rec.b, rec.x, rec.y, rec.z)
  if b then BSs.rename(b.id, "Halden Works") end
  local U = {}
  for _, L in ipairs(RXP.LAYOUT) do
    if L[5] ~= "snap" then
      local u = ST.addPart(sid, { id = L[1], x = L[2] + OX, y = Y, z = L[3] + OZ, yaw = L[4], pitch = 0, roll = 0 })
      if L[5] then U[L[5]] = u end
    end
  end
  -- the core on the vessel's lattice
  local cells = {}
  for r = 1, 5 do
    local j = 3 - r
    for i = -2, 2 do
      local ch = RXP.CORE[r]:sub(i + 3, i + 3)
      if KIND[ch] then
        local u = ST.addPart(sid, { id = KIND[ch], x = i * 0.5 + OX, y = Y + 1.0, z = j * 0.5 + OZ, yaw = 0, pitch = 0, roll = 0 })
        cells[#cells + 1] = { uid = u, ch = ch }
      end
    end
  end
  -- a heavy shield wall west of the core, two blocks high, and the console east of the plant
  for z = -2, 2 do for lv = 0, 3 do ST.addPart(sid, { id = "shieldHeavy.concrete", x = OX - 3.0, y = Y + lv, z = OZ + z, yaw = 0 }) end end
  U.console = ST.addPart(sid, { id = "reactorConsole.steel", x = OX + 11.5, y = Y, z = OZ - 1.0, yaw = Q })   -- (its screen faces east, the operator's side)
  ST.spawnNow(sid)
  wait(2.0)
  rec = ST.get(sid)
  -- the outlet's pipe through the kit's own port snap: aimed at the vessel's +Z nozzle
  local vp = ST.getPart(sid, U.vessel)
  KIT.tp(rec, OX + 3.5, OZ + 1.5)
  local uidSnap, ps = KIT.put(fb, rec, "pipe1.steel", { OX + 0.3, Y + 0.7, OZ + 2.4 }, { OX + 0.3, Y + 0.7, OZ + 0.5 }, "the outlet pipe on its nozzle")
  fb.dropHeld()
  if type(ps) ~= "table" then ps = nil end
  BK.check("portsnap", ps and math.abs(ps.x - OX) < 0.01 and math.abs(ps.z - (OZ + 2.0)) < 0.01 and math.abs((ps.y or 0) - Y) < 0.01,
    "the pipe snapped nozzle to nozzle: (%.2f, %.2f, %.2f), wanted (%.2f, %.2f, %.2f)", ps and ps.x or -1, ps and ps.y or -1, ps and ps.z or -1, OX, Y, OZ + 2.0)
  if not ps then
    ST.addPart(sid, { id = "pipe1.steel", x = OX, y = Y, z = OZ + 2.0, yaw = 0, pitch = 0, roll = 0 }); ST.spawnNow(sid)
  end
  wait(1.5)
  RP.stepNow()
  local key = RP.keyOf(sid, U.vessel)
  local e = RP.plant(key)
  if not BK.check("plant", e ~= nil and e.M ~= nil, "the plant is found: %s", key) then BK.result() return end
  P("RX layout: primary closed %s (%d pumps, %.1f m, lagged %.1f m, loss %.4f), secondary closed %s (turbine %d, sinks %d, pumps %d) · why %s · warn %s",
    tostring(e.pl.pri.closed), #e.pl.pri.pumps, e.pl.pri.pipes or 0, e.pl.pri.lagged or 0, e.pl.pri.loss or 0, tostring(e.pl.sec.closed),
    #e.pl.sec.turbines, #e.pl.sec.rejects, #e.pl.sec.pumps, table.concat(e.M.why, "; "), table.concat(e.M.warn, "; "))
  BK.check("loops", e.pl.pri.closed and e.pl.sec.closed and #e.pl.sec.turbines == 1, "both loops close through the pieces' ports")
  -- ── 2. the fuel ──
  local nrod = 0
  for _, c in ipairs(cells) do
    if c.ch == "F" then
      nrod = nrod + RP.loadRods(sid, c.uid, "fuelRod", 4) + RP.loadRods(sid, c.uid, "fuelRodNU", 4)
    end
  end
  e = RP.plant(key)
  BK.check("fuel", nrod == 64 and #e.M.why == 0, "64 rods in eight channels (half natural uranium) · rated %.0f kW · shutdown margin %.1f %%", e.M.Pr / 1000, RX.shutdownMargin(e.M) * 100)
  -- ── 3. to power ──
  KIT.close(fb)
  local FL = findScript("flora_field")
  if FL and FL.params then FL.params.enabled = 0 end
  KIT.tp(rec, OX + 13.5, OZ - 1.0)
  BK.daylight(unit(sub(astro(), home())), 120)
  local ok, w = RP.startUp(key, 1.0)
  BK.check("start", ok, "start-up on the automatic controller: %s", tostring(w))
  wait(3)
  line(RP, e, "start +3 s")
  RXP.warp(5400, "start-up")
  e = RP.plant(key)
  line(RP, e, "at power")
  local o = e.o
  local pw = BT.power(b.id)
  P("RX GRID: in %.1f kW (plant %.1f) need %.1f kW stored %.0f/%.0f", pw.supply or -1, pw.plant or -1, pw.need or -1, pw.stored or -1, pw.cap or -1)
  BK.check("power", o.P > 0.95 and (o.Pe or 0) > 30e3 and (pw.plant or 0) > 25, "critical at %.0f %%: %.1f kW(e) on the base grid (%.1f kW there)", o.P * 100, (o.Pe or 0) / 1000, pw.plant or -1)
  RP.overlay, RP.overlayAlways = true, true
  RP.paintConsoles()
  wait(1.5)
  PW.view("rx1_plant_overlay", rec, { OX + 16, 9, OZ - 12 }, { OX + 3, 1.0, OZ + 2 })
  PW.view("rx1b_plant_overlay_west", rec, { OX - 12, 7, OZ + 14 }, { OX + 3, 1.0, OZ + 1 })
  PW.view("rx1c_dose_field_top", rec, { OX + 1, 42, OZ - 8 }, { OX + 1, 0, OZ + 1 })
  BK.check("overlay", (RP.drawn.lines or 0) > 30 and (RP.drawn.labels or 0) >= 5 and (RP.drawn.rings or 0) >= 3,
    "the NUCLEAR overlay: %d lines, %d labels, %d dose rings", RP.drawn.lines or 0, RP.drawn.labels or 0, RP.drawn.rings or 0)
  RP.overlayAlways = false
  wait(0.5)
  RP.paintConsoles()
  wait(1.0)
  local cn = U.console
  local cpart = ST.getPart(sid, cn)
  KIT.view("rx2_console_at_power", rec, { cpart.x + 0.62, Y + 1.14, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  KIT.view("rx2a_console_wide", rec, { cpart.x + 2.2, Y + 1.7, cpart.z + 0.8 }, { cpart.x, Y + 1.0, cpart.z })
  KIT.view("rx2b_plant_daylight", rec, { OX + 15, 3.5, OZ - 9 }, { OX + 3, 2.0, OZ + 2 })
  local pg = page_line(RP, e, "at power")
  BK.check("console", (RP.consoleText(sid, cn) or ""):find("TURBINE", 1, true) ~= nil, "the console's screen shows the plant")
  -- (playtest 11-11) the reactor room heard and seen at power: plant_av's
  -- loops on the vessel, pumps and turbine, the vessel's gauges, the cost
  local PA = findScript("plant_av")
  local function av_loops(tag)
    local names, has = {}, {}
    for k, L in pairs(PA and PA.loops() or {}) do
      local nm = tostring(L.path):match("([%w_]+)%.ogg") or "?"
      names[#names + 1] = k .. "=" .. nm; has[nm] = true
    end
    table.sort(names)
    P("RX AV %s: %d loops (%s) · emitters %d · scan %.3f ms", tag, #names, table.concat(names, " "), PA and PA.PROF.emitters or -1, PA and PA.PROF.scan_ms or -1)
    return has, #names
  end
  if PA then
    KIT.tp(rec, OX + 2.6, OZ - 1.6)
    wait(2.0)
    local has, nl = av_loops("at power by the vessel")
    BK.check("av_loops", has.transformer_hum and has.pump_whine and has.turbine_whine and nl <= PA.MAX_LOOPS,
      "at power by the vessel: the core's hum, the coolant pump's whine and the turbine's whine play on their pieces (%d loops)", nl)
    local fr0 = FRAME
    sc_begin("reactor_room"); wait(4); sc_end("reactor_room")
    local ms = (perf.scriptMs("plant_av") or 0) + (perf.scriptMs("room_air") or 0) + (perf.scriptMs("kit_live") or 0)
    P("RX PERF reactor room at power: plant_av %.4f, room_air %.4f, kit_live %.4f, reactor_plant %.4f ms/frame (%d frames)",
      perf.scriptMs("plant_av") or -1, perf.scriptMs("room_air") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("reactor_plant") or -1, FRAME - fr0)
    BK.check("av_cost", (perf.scriptMs("plant_av") or 0) < 0.2, "the loud reactor room costs plant_av %.4f ms a frame (≤ 0.2; with room_air and kit_live %.4f)", perf.scriptMs("plant_av") or -1, ms)
    RXP.dview("rx2c_vessel_gauges", rec, { OX + 2.9, Y + 1.15, OZ - 0.4 }, { OX + 1.2, Y + 0.62, OZ + 0.0 })
    BK.check("gauges", PA.lastGauge and math.abs((PA.lastGauge.P or 0) - o.P) < 0.1, "the vessel's gauges read %.0f %% and %.0f K", (PA.lastGauge and PA.lastGauge.P or 0) * 100, PA.lastGauge and PA.lastGauge.Tp or -1)
  end
  -- (playtest 11-11) a setpoint change rebalances in WARPED time, with the
  -- console's terminal open and the warp asked by its . key (read raw)
  do
    local TM, WC, DP = findScript("terminal"), findScript("warp_chip"), findScript("deployables")
    KIT.tp(rec, cpart.x + 0.9, cpart.z)
    local pc0 = findScript("planet_camera")
    wait(1.0)
    local okT = TM and TM.openAt and TM.openAt(sid, cn)
    wait(1.0)
    RP.setPoint(key, 0.6, "hand")
    local a0, t0 = DP.agencyClock(), time
    for _ = 1, 3 do
      if input.simulate then input.simulate({ key = ".", down = true }); yield(); yield(); input.simulate({ key = ".", down = false }) end
      wait(0.4)
    end
    local wk = space.warp()
    P("RX TERMINAL WARP: terminal open %s, warp ×%.0f after three . presses (%s)", tostring(TM and TM.isOpen()), wk, tostring(WC and WC.lastNotice))
    BK.check("term_warp", okT and TM.isOpen() and wk >= 9, "with the console's terminal open, . warps (×%.0f) and the terminal stays open", wk)
    while DP.agencyClock() - a0 < 900 and time - t0 < 120 do
      if space.warp() < 50 then space.warp(100) end
      yield()
    end
    space.warp(1)
    wait(0.5)
    e = RP.plant(key)
    local game, real = DP.agencyClock() - a0, time - t0
    BK.check("warp_setpoint", math.abs((e.o.P or 0) - 0.6) < 0.05 and game > 5 * real,
      "setpoint 100 → 60 %% under warp: %.0f %% after %.0f game s in %.0f real s", (e.o.P or 0) * 100, game, real)
    if TM and TM.close then TM.close() end
    RP.setPoint(key, 1.0, "hand")
    RXP.warp(1800, "back to 100 %")
    e = RP.plant(key)
    o = e.o
  end
  -- the dose: the shield wall's side against the open side, 6 m out
  local TH = findScript("thermal")
  local rad = RP.radOf(sid, U.vessel)
  P("RX DOSE source %.1f lethal shares an hour at 5 m", rad)
  -- ── 4. a day at power, then SCRAM ──
  RXP.skip(10 * 86400, "ten days at power")
  e = RP.plant(key)
  line(RP, e, "ten days on")
  local xe0 = e.S.y[9]
  BK.check("xenon_eq", xe0 > 0.5, "xenon at equilibrium: %.2f b (%.1f %%)", xe0, RX.xenonWorth(e.M, e.S.y) * 100)
  RP.scram(key)
  wait(4)
  e = RP.plant(key)
  line(RP, e, "scram +4 s")
  BK.check("scram", e.S.scram and (e.o.x or 0) > 0.95 and (e.o.P or 1) < 0.05, "SCRAM: rods %.0f %% in, fission power %.1f %%", (e.o.x or 0) * 100, (e.o.P or 0) * 100)
  RP.paintConsoles(); wait(1.0)
  KIT.view("rx3_console_scram", rec, { cpart.x + 0.62, Y + 1.14, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  -- ── 5. the xenon pit ──
  RXP.skip(4 * 3600, "into the pit")
  e = RP.plant(key)
  local h, pk, tpk = RX.xenonForecast(e.M, e.S, e.S.y)
  line(RP, e, "+4 h")
  P("RX PIT xenon %.2f b (was %.2f) · k rods out %.4f · forecast: restart in %s h, peak %.2f b at +%s h", e.S.y[9], xe0, RX.kRodsOut(e.M, e.S, e.S.y), tostring(h), pk or -1, tostring(tpk))
  local rok, rw = RP.resetTrip(key)
  P("RX reset: %s %s", tostring(rok), tostring(rw))
  local sok, sw = RP.startUp(key, 0.5)
  P("RX restart: %s %s", tostring(sok), tostring(sw))
  RXP.skip(3600, "restart attempt")
  e = RP.plant(key)
  line(RP, e, "restart +1 h")
  local lim = tostring(RX.limitedBy(e.M, e.S, e.o))
  BK.check("pit", (e.o.P or 1) < 1e-3 and lim:find("xenon", 1, true) ~= nil, "the xenon pit: the rods all out, P %.2g, '%s'", e.o.P or -1, lim)
  RP.paintConsoles(); wait(1.0)
  KIT.view("rx4_console_xenon_pit", rec, { cpart.x + 0.62, Y + 1.14, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  page_line(RP, e, "the pit")
  -- ── 6. the pumps cut on the tripped plant ──
  RP.scram(key)
  RP.setPump(sid, U.pump, false)
  RP.setPump(sid, U.feed, false)
  e = RP.plant(key)
  e.towerOn = false
  RP.stepNow()
  RXP.skip(48 * 3600, "no cooling")
  e = RP.plant(key)
  line(RP, e, "no cooling +48 h")
  local pg6 = page_line(RP, e, "no cooling")
  local hot = false
  for _, a in ipairs(pg6.alarms or {}) do if a[1]:find("PRIMARY", 1, true) or a[1]:find("RELIEF", 1, true) then hot = true end end
  BK.check("overheat", hot and (e.o.Tp or 0) > e.M.tsat - 25, "decay heat with nothing cooling it: the primary at %.0f K (boils at %.0f): the overheat alarm", e.o.Tp or -1, e.M.tsat)
  RP.paintConsoles(); wait(1.0)
  KIT.view("rx5_console_overheat", rec, { cpart.x + 0.62, Y + 1.14, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  if PA then
    -- (playtest 11-11) stressed: steam off the pressuriser, the alarm sounding
    local pp = ST.getPart(sid, U.press)
    KIT.tp(rec, pp.x + 3.0, pp.z - 1.5)
    wait(3.0)
    local has = av_loops("overheated by the pressuriser")
    local al = 0
    for _, a in pairs(PA.alarms()) do if a.kind == "reactor" then al = al + 1 end end
    BK.check("av_stress", has.steam_leak and al > 0 and (PA.alarmLevel(sid) or 0) >= 1,
      "overheated: steam leaks off the pressuriser (%s), the reactor alarm sounds (%d, level %s)", tostring(has.steam_leak), al, tostring(PA.alarmLevel(sid)))
    for i = 1, 3 do RXP.dview("rx5c_pressuriser_steam_" .. i, rec, { pp.x + 3.2, Y + 3.0, pp.z - 3.0 }, { pp.x, Y + 3.8, pp.z }) end
    RXP.dview("rx5d_vessel_gauges_hot", rec, { OX + 2.9, Y + 1.15, OZ - 0.4 }, { OX + 1.2, Y + 0.62, OZ + 0.0 })
    local n = PA.silence(sid, "hand")
    wait(1.0)
    local loud = 0
    for _, a in pairs(PA.alarms()) do if a.sid == sid and not a.silenced then loud = loud + 1 end end
    BK.check("silence", n > 0 and loud == 0 and (PA.alarmLevel(sid) or 0) >= 1, "SILENCE: %d alarm(s) silenced, still standing", n)
  end
  RP.overlay, RP.overlayAlways = true, true
  PW.view("rx5b_overlay_overheat", rec, { OX + 16, 9, OZ - 12 }, { OX + 3, 1.0, OZ + 2 })
  RP.overlayAlways = false
  -- the cooling back: pumps and fan on
  RP.setPump(sid, U.pump, true)
  RP.setPump(sid, U.feed, true)
  e.towerOn = true
  RP.stepNow()
  RXP.skip(1800, "cooling back")
  e = RP.plant(key)
  line(RP, e, "cooled")
  -- the cost: the plant tripped and at hot standby, scripts' ms a frame
  do
    local fr0 = FRAME
    sc_begin("reactor_idle"); wait(5); sc_end("reactor_idle")
    P("RX PERF tripped plant: reactor_plant %.4f, reactor %.4f, base_shield %.4f, base_grid %.4f ms/frame (%d frames) · tick %.3f ms, %d steps",
      perf.scriptMs("reactor_plant") or -1, perf.scriptMs("reactor") or -1, perf.scriptMs("base_shield") or -1, perf.scriptMs("base_grid") or -1,
      FRAME - fr0, RP.PROF.tick_ms or -1, RP.PROF.steps or -1)
    BK.check("perf", (perf.scriptMs("reactor_plant") or 0) < 0.1, "a tripped plant costs %.4f ms a frame (≤ 0.1)", perf.scriptMs("reactor_plant") or -1)
  end
  -- ── 7. save and reload ──
  RP.saveNow()
  local xe1, scr1, Tp1 = e.S.y[9], e.S.scram, e.o.Tp
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(6)
  ST, RP, RX = findScript("structures"), findScript("reactor_plant"), findScript("reactor")
  RP.stepNow()
  local e2 = RP.plant(key)
  local rods = 0
  for _, c in ipairs(cells) do if c.ch == "F" then rods = rods + #RP.channelRods(sid, c.uid) end end
  BK.check("reload", e2 and e2.S.scram == scr1 and math.abs(e2.S.y[9] - xe1) < 0.05 * math.max(xe1, 0.1) + 0.02 and rods == 64,
    "after a reload: tripped %s, xenon %.3f b (was %.3f), %d rods, primary %.0f K (was %.0f)", tostring(e2 and e2.S.scram), e2 and e2.S.y[9] or -1, xe1, rods, e2 and e2.o.Tp or -1, Tp1 or -1)
  if FL and FL.params then FL.params.enabled = 0 end
  rec = ST.get(sid)
  KIT.tp(rec, OX + 13.5, OZ - 1.0)
  wait(2)
  RP.paintConsoles(); wait(1.0)
  KIT.view("rx6_console_after_reload", rec, { cpart.x + 0.62, Y + 1.14, cpart.z }, { cpart.x - 0.35, Y + 1.12, cpart.z })
  BK.result()
end
