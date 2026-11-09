-- ── kit probe, mode "logic" (sandbox plan S8: logic and automation) ─────────
-- Spliced after fluidsprobe_modes.lua (KIT / BK / RXP / FLP helpers) by tools/perf/kitprobe.sh.
-- On the home world with the outside forced to vacuum (room_air.setVacuum):
--   1. a hab of pieces: an airlock chamber (an Airlock Wall out, a Door Wall
--      in), a 6 × 4 m hab, two Air Tank Racks, a scrubber, an O2 Generator, a
--      light, on a live base grid;
--   2. THE AUTO-AIRLOCK on a Ladder Controller: a Push Button and an
--      Indicator Lamp outside by the outer door, the PLC inside; the cables
--      laid (the first through the Signal Cable's own aim and clicks, at real
--      raycasts), the six rungs programmed; pressed: the chamber pumps down,
--      the lamp lights READY, the crew walks to the outer door and it opens,
--      the inner door LOCKED by the ladder meanwhile, never both open; the
--      LOGIC overlay from outside (two angles), the PLC's screen read at
--      1.5 m, the ladder editor open;
--   3. LOW O2 → the O2 Generator and a beacon; DAY/NIGHT → the light; LOAD
--      SHEDDING → the hab's main breaker;
--   4. REACTOR PROTECTION beside the hab (the S6 fixture with a standby
--      coolant pump in series): a Flow Switch and a Temperature Transmitter;
--      the duty pump stopped → the flow falls → the standby pump started by
--      logic, the beacon; the temperature over its setpoint → SCRAM by logic;
--      the overlay at the plant (two angles);
--   5. the cost: logic_net idle, and 200 gates switching;
--   6. save and reload: the cables, the ladder, its relays, the holds.
-- `BK PASS|FAIL`, `LG …` lines, `BK RESULT logic: PASS/FAIL`.
LGP = {}

local function lmenu(ST, sid, uid) return BK.menu(ST.nodeOf(sid, uid)) end
local function lgline(LN, sid, uid, tag)
  local o = LN.readout(sid, uid)
  if not o then P("LG %s: no readout", tag) return nil end
  local pins = {}
  for _, q in ipairs(o.pins or {}) do pins[#pins + 1] = string.format("%s%s=%s", q.io == "in" and ">" or "<", q.n, q.b and "1" or "0") end
  P("LG %s: q %s v %s · %s%s", tag, tostring(o.q), tostring(o.v and string.format("%.3f", o.v)), table.concat(pins, " "), o.osc and " · OSC" or "")
  return o
end

function LGP.run()
  BK.tag = "logic"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local KL, RA, LN, LGc = findScript("kit_live"), findScript("room_air"), findScript("logic_net"), findScript("logic")
  local RP, BG, BP = findScript("reactor_plant"), findScript("base_grid"), findScript("base_power")
  if not BK.check("scene", fb and ST and KL and RA and LN and LGc and RP and BG and BP, "logic, logic_net, room_air and reactor_plant are in the scene") then BK.result() return end
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
  local nl = cp and cp.listFor and cp.listFor(fb, "LOGIC", "") or {}
  P("LG the LOGIC tab: %d cards", #nl)
  BK.check("tab", #nl >= 25, "the LOGIC section lists the pieces (%d)", #nl)
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
  for _, s in ipairs({ { 2, 0 }, { 4, 0 }, { 6, 0 }, { 2, 2 }, { 4, 2 }, { 6, 2 }, { -2, 0 }, { -2, -2 }, { 0, -2 } }) do ST.addPart(sid, { id = "slab2.concrete", x = s[1], y = 0, z = s[2], yaw = 0 }) end
  ST.spawnNow(sid)
  wait(1.0)
  rec = ST.get(sid)
  local T = 0.2
  local H = math.pi / 2
  local function put(id, x, y, z, yaw, pitch)
    local p = { body = rec.b, mode = "face", sid = sid, lx = x, ly = y, lz = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }
    local s2, w2, q, uid = fb.place(sid, id, p, "money")
    if not s2 then uid = ST.addPart(sid, { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }) end
    return uid
  end
  local U = {}
  U.outer = put("airlockWall.steel", -1, T, 0, H)
  U.inner = put("doorWall.steel", 1, T, 0, H)
  put("wall.steel", 0, T, -1, 0); put("wall.steel", 0, T, 1, 0)
  for _, x in ipairs({ 2, 4, 6 }) do put(x == 4 and "windowWall.steel" or "wall.steel", x, T, -1, 0); put("wall.steel", x, T, 3, 0) end
  put("wall.steel", 1, T, 2, H)
  put("wall.steel", 7, T, 0, H); put("wall.steel", 7, T, 2, H)
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 4, 0 }, { 6, 0 }, { 2, 2 }, { 4, 2 }, { 6, 2 } }) do put("floor.steel", s[1], T + 2.2, s[2]) end
  U.scrub = put("scrubber.steel", 2.0, T, -0.65, 0)
  U.tankA = put("airTank.steel", 5.4, T, -0.66, 0)
  U.tankB = put("airTank.steel", 3.6, T, -0.66, 0)
  U.gen = put("o2gen.steel", 6.4, T, 2.4, H)
  U.light = put("lightFitting.steel", 4.0, T + 2.2 - 0.001, 1.0, 0, math.pi)
  -- the logic: outside by the outer door a button and a lamp on the airlock
  -- wall's outside face (its −X); the controller in the hab; a gas analyser,
  -- a beacon, a battery monitor and the main breaker on the hab's walls; a
  -- photocell on the roof
  U.button = put("liButton.steel", -1.1, T + 1.15, -0.78, -H, H)
  U.lamp = put("loLamp.steel", -1.1, T + 1.5, -0.78, -H, H)
  U.plc = put("lgPlc.steel", 2.6, T, 2.25, math.pi)
  U.gas = put("lsGas.steel", 4.6, T + 1.45, 2.9, math.pi, H)
  U.beacon = put("loAlarm.steel", 4.6, T + 1.95, 2.9, math.pi, H)
  U.batt = put("lsPower.steel", 6.9, T + 1.3, 0.6, -H, H)
  U.main = put("breaker63.steel", 6.9, T + 1.3, 1.2, -H, H)
  U.day = put("lsDay.steel", 2.0, T + 2.4, 0.0, 0, 0)
  -- the base grid
  ST.addPart(sid, { id = "tower", x = -8, y = 0, z = 12, yaw = 0 })
  for k = 1, 4 do ST.addPart(sid, { id = "batteryBank", x = -8 + 3 * (k - 1), y = 0, z = 17, yaw = 0 }) end
  ST.addPart(sid, { id = "solarArray", x = -14, y = 0, z = 4, yaw = 0 })
  ST.addPart(sid, { id = "solarArray", x = -14, y = 0, z = 9, yaw = 0 })
  ST.spawnNow(sid)
  wait(2.5)
  local BT = findScript("base_tower")
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  rec = ST.get(sid)
  P("LG built: %d pieces · outer %s inner %s button %s lamp %s plc %s gas %s gen %s", #rec.bp, tostring(U.outer), tostring(U.inner), tostring(U.button), tostring(U.lamp), tostring(U.plc), tostring(U.gas), tostring(U.gen))
  wait(1.5)
  local st = RA.state(sid)
  local R = st and st.R
  local RL = findScript("rooms")
  local ch = R and RL.roomAt(R, 0, 1.2, 0)
  local hab = R and RL.roomAt(R, 4, 1.2, 1)
  BK.check("rooms", ch and ch.airlock and hab and hab.sealed, "the chamber an airlock (%.1f m³), the hab sealed (%.1f m³)", ch and ch.m3 or -1, hab and hab.m3 or -1)
  if not (ch and hab) then BK.result() return end
  local function refill()
    for _, u in ipairs({ U.tankA, U.tankB }) do
      local e = BK.entry(lmenu(ST, sid, u), "ra_refill")
      if e and e.act then e.act() end
    end
  end
  FLP.fast(function() local a = RA.airOf(sid, hab.id); return a and a.p > 0.97 end, 60, "the hab pressurised")
  refill()
  -- (the chamber at the hab's air, as if the crew had last come in through it)
  do
    st = RA.state(sid)
    local A, Hh = st.air[ch.id], st.air[hab.id]
    local rh = (Hh.N + Hh.x + Hh.c) / hab.m3
    local k = ch.m3 / hab.m3
    A.N, A.x, A.c = Hh.N * k / rh, Hh.x * k / rh, Hh.c * k / rh
    st.netsDirty = true
  end
  P("LG air: hab %.3f atm, chamber %.3f atm", RA.airOf(sid, hab.id).p, RA.airOf(sid, ch.id).p)
  -- ── 2. the cables: the first through the drum's own aim and clicks ──
  local function bw(lx, ly, lz) return KIT.w(rec, lx, ly, lz) end
  fb.hold("sigCable.steel")
  yield()
  local hd = findScript("parts_base").partInfo("sigCable.steel")
  local function aim_click(at, from, tag)
    local h = KIT.ray(rec, from, at)
    if not h then P("LG %s: the ray found nothing", tag) return false end
    local req = LN.aimTick(h)
    req.cable, req.id, req.def = true, "sigCable.steel", hd
    local ok, msg = LN.click(req)
    P("LG drum %s: %s · %s (pin %s %s)", tag, tostring(ok), tostring(msg), tostring(req.pin), tostring(req.io))
    return ok, req
  end
  -- the button's face, from 0.6 m out (−X of the wall); then the PLC's X1 terminal, from behind it
  local bx, by, bz = LN.pinLocal(sid, U.button, "Q")
  -- (a mount has no collider: the ray goes on to the wall behind it, and the mount is found at the hit point)
  local okA = aim_click({ bx + 0.15, by, bz }, { bx - 0.8, by + 0.05, bz }, "button")
  local xx, xy, xz = LN.pinLocal(sid, U.plc, "X1")
  local okB, reqB = aim_click({ xx, xy, xz - 0.03 }, { xx, xy + 0.4, xz - 0.9 }, "plc X1")
  local w1 = LN.wires()[1]
  BK.check("drum", okA and okB and w1 and w1.a.uid == U.button and w1.z.uid == U.plc and w1.z.pin == "X1",
    "the Signal Cable laid through its own aim and clicks: the button's Q to the controller's X1 (%.1f m)", w1 and w1.len or -1)
  fb.dropHeld()
  local function wire(a, ap, z, zp)
    local id, w = LN.layWire({ sid = sid, uid = a, pin = ap }, { sid = sid, uid = z, pin = zp })
    if not id then P("LG wire %s.%s → %s.%s refused: %s", tostring(a), ap, tostring(z), zp, tostring(w)) end
    return id
  end
  if not w1 then wire(U.button, "Q", U.plc, "X1") end
  wire(U.outer, "state", U.plc, "X2"); wire(U.outer, "ready", U.plc, "X3"); wire(U.inner, "state", U.plc, "X4")
  wire(U.plc, "Y1", U.outer, "cycle"); wire(U.plc, "Y2", U.lamp, "IN"); wire(U.plc, "Y3", U.inner, "lock"); wire(U.plc, "Y4", U.outer, "lock")
  LN.setProgram(sid, U.plc, {
    "X1,0,,,0,SET,M1,0",          -- 01 the button asks for a cycle out
    "X2,0,,,0,RST,M1,0",          -- 02 the outer door opened: served
    "M1,0,,,0,OUT,Y1,0",          -- 03 the cycle to the outer door while asked
    "X3,0,,,0,OUT,Y2,0",          -- 04 READY lamp: the chamber at the outside's pressure
    "X2,0,,,0,OUT,Y3,0",          -- 05 outer open: the inner door locked
    "X4,0,,,0,OUT,Y4,0",          -- 06 inner open: the outer door locked
  })
  -- low O2 → the generator and the beacon; dark → the light; the battery → the main breaker
  wire(U.gas, "Q", U.gen, "run"); wire(U.gas, "Q", U.beacon, "IN")
  LN.setParam(sid, U.batt, "mode", "above"); LN.setParam(sid, U.batt, "set", 30)
  wire(U.batt, "Q", U.main, "close")
  KIT.close(fb)
  wait(2.0)
  LN.stepNow()
  local net = LN.net()
  P("LG network: %d nodes, %d cables, %d loops · build %.2f ms", net and #net.N or -1, #LN.wires(), net and net.loops or -1, LN.PROF.build_ms or -1)
  BK.check("net", net and #LN.wires() == 11 and #net.N >= 12, "%d cables on a network of %d nodes", #LN.wires(), net and #net.N or -1)
  -- every cable ends on its pins (the record's first and last points, this frame's body read)
  local worst = 0
  for _, w in ipairs(LN.wires()) do
    local pts = LN.pathOf(w.id)
    local ax, ay, az = LN.pinLocal(w.a.sid, w.a.uid, w.a.pin)
    local zx, zy, zz = LN.pinLocal(w.z.sid, w.z.uid, w.z.pin)
    local e1 = len(pts[1][1] - ax, pts[1][2] - ay, pts[1][3] - az)
    local e2 = len(pts[#pts][1] - zx, pts[#pts][2] - zy, pts[#pts][3] - zz)
    worst = math.max(worst, e1, e2)
  end
  BK.check("ends", worst < 0.005, "every cable starts and ends on its pins (worst %.4f m)", worst)
  -- ── the auto-airlock ──
  local both = false
  local function watch() if (KL.doorOpen(sid, U.outer) or 0) > 0.02 and (KL.doorOpen(sid, U.inner) or 0) > 0.02 then both = true end end
  local DZ = 0.46
  -- (4.5 m out: a door opens by itself for crew within 3 m, and that would serve the request before the lamp is seen)
  KIT.tp(rec, -5.5, -0.3)
  wait(1.0)
  local lamp0 = LN.lampOn(sid, U.lamp)
  local pc0 = RA.airOf(sid, ch.id).p
  local pe = BK.entry(lmenu(ST, sid, U.button), "lg_press")
  BK.check("menu", pe ~= nil, "the button's menu has Press (%s)", pe and pe.label or "none")
  if pe and pe.act then pe.act() end
  local t0 = time
  wait(1.0)
  local m1 = (LN.readout(sid, U.plc) or {}).M
  BK.check("press", not lamp0 and m1 and m1[1] and LN.cycling(sid, U.outer), "pressed: the ladder's M1 set, the airlock asked to cycle to the outer door; the lamp dark (the chamber at %.2f atm)", pc0)
  local ready = wait_for(function() watch(); return LN.lampOn(sid, U.lamp) end, 120, "the READY lamp")
  local pc1 = RA.airOf(sid, ch.id).p
  P("LG READY after %.1f s: chamber %.3f atm · %s", time - t0, pc1, tostring(RA.lastCycle))
  BK.check("ready", ready and pc1 < 0.05, "the chamber pumped down to %.3f atm in %.0f s, then the lamp lit READY", pc1, time - t0)
  -- the lamp and the overlay, from outside
  LN.overlay, LN.overlayAlways = true, true
  wait(0.5)
  KIT.oview("l1_airlock_overlay_outside", rec, { -4.2, 2.2, -2.6 }, { -1.1, 1.3, -0.4 })
  KIT.oview("l1b_airlock_overlay_side", rec, { -3.4, 1.7, 1.4 }, { -1.1, 1.4, -0.8 })
  local dr = LN.drawn
  BK.check("overlay", (dr.lines or 0) >= 6 and (dr.labels or 0) >= 2 and (dr.rings or 0) >= 4, "the LOGIC overlay: %d lines (%d lit), %d labels, %d pin lamps", dr.lines or 0, dr.lit or 0, dr.labels or 0, dr.rings or 0)
  LN.overlayAlways = false
  do
    local lv, shown = LN.lensOf(sid, U.lamp)
    BK.check("lens", lv and shown == "0.351.000.45" and LN.lampOn(sid, U.lamp), "the READY lamp still lit, its lens found and green (%s, %s)", tostring(lv), tostring(shown))
  end
  KIT.view("l2_ready_lamp", rec, { -2.1, T + 1.5, -1.0 }, { -1.1, T + 1.3, -0.78 })
  -- the crew to the outer door: it opens; the ladder locks the inner one meanwhile
  KIT.walk(rec, -1.6, DZ, 8, 0.3, watch)
  local opened = wait_for(function() watch(); return (KL.doorOpen(sid, U.outer) or 0) > 0.95 end, 20, "the outer door")
  wait(0.6)
  local lk = LN.doorCmd(sid, U.inner)
  local m1b = (LN.readout(sid, U.plc) or {}).M
  BK.check("outer", opened and lk and lk.lock and not (m1b and m1b[1]), "the outer door opens for the crew; the inner door LOCKED by the ladder while it is open; M1 reset (the request served)")
  -- in, and on through the inner door
  KIT.walk(rec, 0.0, DZ, 6, 0.3, watch)
  local inn = wait_for(function() watch(); return (KL.doorOpen(sid, U.inner) or 0) > 0.95 end, 120, "the inner door, cycled in")
  BK.check("inner", inn and not both, "in, the chamber repressurised and the inner door opened; never both doors open")
  KIT.walk(rec, 2.6, 0.9, 8, 0.3, watch)
  wait(1.5)
  -- the controller's screen at 1.5 m, and its editor
  local pp = ST.getPart(sid, U.plc)
  KIT.tp(rec, pp.x, pp.z - 1.6)
  wait(1.0)
  local stext = LN.screenText(sid, U.plc) or ""
  P("LG screen: %s", stext:sub(1, 200))
  KIT.view("l3_plc_screen_1p5m", rec, { pp.x, T + 1.4, pp.z - 1.5 }, { pp.x, T + 1.1, pp.z + 0.3 })
  BK.check("screen", stext:find("SET M1", 1, true) and stext:find("Y1", 1, true), "the controller's CRT shows its rungs")
  LN.editorOpen(sid, U.plc)
  wait(1.5)
  BK.shot("l4_ladder_editor", true)
  BK.check("editor", LN.editor.node ~= nil and LN.editor.node.valid ~= false, "the ladder editor opens on its CRT panel")
  -- a click in it: rung 07's first contact stepped, then cleared again
  LN.editCell(7, "a"); wait(0.3)
  local r7 = LN.program(sid, U.plc)[7]
  LN.editCell(7, "clear"); wait(0.3)
  BK.check("edit", r7 and r7.a == "X1" and not LGc.rungActive(LN.program(sid, U.plc)[7]), "a click on rung 07 sets its contact to X1, its ✕ clears it")
  LN.editorClose()
  wait(0.5)
  -- ── 3. low O2, day and night, load shedding ──
  st = RA.state(sid)
  local Ah = st.air[hab.id]
  local x0 = Ah.x
  Ah.x = Ah.x * 0.85
  st.netsDirty = true
  wait(1.5)
  local gen_on = RA.machineOn(sid, U.gen)
  local bea = LN.lampOn(sid, U.beacon)
  lgline(LN, sid, U.gas, "gas analyser")
  KIT.view("l5_low_o2_beacon", rec, { 4.2, T + 1.5, 0.3 }, { 4.9, T + 1.6, 2.9 })
  BK.check("o2", gen_on and bea, "O2 at %.1f %%: the O2 Generator runs and the beacon sounds", 100 * Ah.x / hab.m3)
  -- (room_air may have made new air tables meanwhile: the hab's air read again)
  st = RA.state(sid)
  st.air[hab.id].x = x0
  st.netsDirty = true
  wait(1.5)
  BK.check("o2_off", not RA.machineOn(sid, U.gen) and not LN.lampOn(sid, U.beacon), "back at 21 %%: the generator stands by, the beacon stops")
  wire(U.day, "Q", U.light, "on")
  wait(1.5)
  local day = LN.readout(sid, U.day)
  local lit0 = KL.lightsOf and select(2, KL.lightsOf(sid))
  LN.setParam(sid, U.day, "set", 101)       -- (its threshold over full sun: "dark" now)
  wait(1.5)
  local lit1 = select(2, KL.lightsOf(sid))
  LN.setParam(sid, U.day, "set", 5)
  wait(1.5)
  local lit2 = select(2, KL.lightsOf(sid))
  BK.check("daylight", day and day.v ~= nil and lit1 == 1 and lit2 == 0, "the photocell reads %.0f %% light; under its threshold the light is on, over it off (%s → %s → %s)",
    day and day.v or -1, tostring(lit0), tostring(lit1), tostring(lit2))
  local bat = LN.readout(sid, U.batt)
  LN.setParam(sid, U.batt, "set", 99)
  wait(1.5)
  local shed = BP.breakerState(sid, U.main)
  LN.setParam(sid, U.batt, "set", 0)
  wait(1.5)
  local back = BP.breakerState(sid, U.main)
  LN.setParam(sid, U.batt, "set", 30)
  BK.check("shed", bat and bat.v and shed == "open" and back == "closed", "the battery at %.0f %%: under the monitor's setpoint the main breaker is opened by logic (%s), over it closed (%s)",
    bat and bat.v or -1, tostring(shed), tostring(back))
  -- ── 4. reactor protection ──
  local OX, OZ, Y = 30, 0, 0.2
  for x = -6, 14, 2 do for z = -8, 12, 2 do ST.addPart(sid, { id = "slab2.concrete", x = OX + x, y = 0, z = OZ + z, yaw = 0 }) end end
  local RU = {}
  for _, L in ipairs(RXP.LAYOUT) do
    local id, lx, lz, yaw, tag = L[1], L[2], L[3], L[4], L[5]
    -- (a standby pump in series on the cold leg, where the fixture has a 2 m pipe)
    if id == "pipeIns2.steel" and lx == 4.0 and lz == -1.5 then id, yaw, tag = "coolantPump.steel", math.pi, "standby" end
    local u = ST.addPart(sid, { id = id, x = lx + OX, y = Y, z = lz + OZ, yaw = yaw, pitch = 0, roll = 0 })
    if tag then RU[tag] = u end
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
  RU.console = ST.addPart(sid, { id = "reactorConsole.steel", x = OX + 6.5, y = Y, z = OZ - 1.5, yaw = H })
  RU.flow = ST.addPart(sid, { id = "lsFlow.steel", x = OX + 4.9, y = Y, z = OZ + 0.5, yaw = 0, pitch = 0 })
  RU.temp = ST.addPart(sid, { id = "lsTemp.steel", x = OX + 4.9, y = Y, z = OZ - 0.3, yaw = 0, pitch = 0 })
  RU.orr = ST.addPart(sid, { id = "lgOr.steel", x = OX + 5.4, y = Y, z = OZ + 0.1, yaw = 0, pitch = 0 })
  RU.latch = ST.addPart(sid, { id = "lgLatch.steel", x = OX + 5.4, y = Y, z = OZ - 0.5, yaw = 0, pitch = 0 })
  RU.post = ST.addPart(sid, { id = "pillar2.steel", x = OX + 6.0, y = Y, z = OZ + 1.0, yaw = 0 })
  RU.beacon = ST.addPart(sid, { id = "loAlarm.steel", x = OX + 6.0, y = Y + 2.2, z = OZ + 1.0, yaw = 0, pitch = 0 })
  ST.spawnNow(sid)
  wait(3.0)
  rec = ST.get(sid)
  RP.stepNow()
  local key = RP.keyOf(sid, RU.vessel)
  local e = RP.plant(key)
  if not BK.check("plant", e ~= nil and e.pl.pri.closed, "the plant beside the hab: %s, primary closed %s, %d pumps", key, tostring(e and e.pl.pri.closed), e and #(e.pl.pri.pumps or {}) or -1) then BK.result() return end
  for _, c in ipairs(cells) do if c.ch == "F" then RP.loadRods(sid, c.uid, "fuelRod", 4); RP.loadRods(sid, c.uid, "fuelRodNU", 4) end end
  -- the standby pump stands by; the plant's own trips off, so the logic layer is what acts
  RP.setPump(sid, RU.standby, false)
  RP.setProtection(key, false)
  LN.setParam(sid, RU.temp, "set", 700)
  -- (latched: the switch sees the flow the standby pump restores, so wired
  -- straight it would stop the pump again and hunt round its hysteresis)
  wire(RU.flow, "Q", RU.latch, "S"); wire(RU.latch, "Q", RU.standby, "run")
  wire(RU.temp, "Q", RU.console, "scram")
  wire(RU.flow, "Q", RU.orr, "A"); wire(RU.temp, "Q", RU.orr, "B"); wire(RU.orr, "Q", RU.beacon, "IN")
  wait(1.0)
  RP.startUp(key, 1.0)
  RXP.skip(5400, "start-up")
  wait(2.0)
  LN.stepNow()
  e = RP.plant(key)
  local fl0, tp0 = LN.readout(sid, RU.flow), LN.readout(sid, RU.temp)
  P("LG plant at power: P %.3f Tp %.0f Tf %.0f flow %.2f kg/s · the flow switch reads %s, the transmitter %s", e.o.P or -1, e.o.Tp or -1, e.o.Tf or -1, e.o.mpe or -1,
    tostring(fl0 and fl0.v), tostring(tp0 and tp0.v))
  BK.check("rx_read", fl0 and fl0.v and fl0.v > 2 and tp0 and tp0.v and tp0.v > 400 and not fl0.q and not tp0.q, "at power the sensors read the loop: %.2f kg/s, %.0f K, both clear", fl0 and fl0.v or -1, tp0 and tp0.v or -1)
  -- the duty pump stopped: the flow falls, the standby pump starts by logic
  RP.setPump(sid, RU.pump, false)
  local started = wait_for(function() return RP.pumpOn(sid, RU.standby) end, 30, "the standby pump")
  wait(3.0)
  RP.stepNow(); LN.stepNow()
  e = RP.plant(key)
  local fl1 = LN.readout(sid, RU.flow)
  P("LG duty pump stopped: standby on %s · flow %.2f kg/s · tripped %s · beacon %s", tostring(RP.pumpOn(sid, RU.standby)), e.o.mpe or -1, tostring(e.S.scram), tostring(LN.lampOn(sid, RU.beacon)))
  BK.check("standby", started and RP.pumpOn(sid, RU.standby) and not e.S.scram, "the duty pump stopped: the flow switch started the standby pump through a latch, still running with the flow back at %.2f kg/s, no trip", e.o.mpe or -1)
  LN.overlay, LN.overlayAlways = true, true
  KIT.oview("l6_reactor_overlay", rec, { OX + 9.5, 4.2, OZ - 4.5 }, { OX + 5.2, 0.6, OZ + 0.3 })
  -- the temperature over its setpoint: SCRAM by logic
  local tp1 = LN.readout(sid, RU.temp)
  LN.setParam(sid, RU.temp, "set", math.floor((tp1 and tp1.v or 550) - 20))
  local scr = wait_for(function() local e2 = RP.plant(key); return e2 and e2.S.scram end, 20, "the SCRAM")
  wait(1.0)
  e = RP.plant(key)
  P("LG SCRAM: %s · cause %s · beacon %s · console tripped terminal %s", tostring(e.S.scram), tostring(e.S.cause), tostring(LN.lampOn(sid, RU.beacon)), tostring(LN.out(sid, RU.console, "tripped")))
  BK.check("scram", scr and LN.lampOn(sid, RU.beacon), "the primary over the transmitter's setpoint (%d K): SCRAM by logic, the beacon on", math.floor((tp1 and tp1.v or 550) - 20))
  KIT.oview("l6b_reactor_overlay_beacon", rec, { OX + 2.0, 3.2, OZ + 5.5 }, { OX + 5.6, 1.2, OZ + 0.5 })
  LN.overlayAlways = false
  -- ── 5. the cost ──
  do
    LN.overlay, LN.overlayAlways = false, false
    wait(1.0)
    local fr0 = FRAME
    local function snap() local q = LN.PROF; return { q.ticks or 0, q.evsum or 0, q.tsum or 0, q.sensesum or 0, q.paints or 0, q.paintsum or 0, q.lampsum or 0 } end
    local s0 = snap()
    sc_begin("logic_idle"); wait(4); sc_end("logic_idle")
    local s1 = snap()
    P("LG PERF idle: logic_net %.4f, logic %.4f ms/frame (%d frames) · in 4 s: %d ticks (%d evals, %.2f ms), sensing %.2f ms, %d CRT paints (%.2f ms), lamps %.2f ms",
      perf.scriptMs("logic_net") or -1, perf.scriptMs("logic") or -1, FRAME - fr0, s1[1] - s0[1], s1[2] - s0[2], s1[3] - s0[3], s1[4] - s0[4], s1[5] - s0[5], s1[6] - s0[6], s1[7] - s0[7])
    BK.check("perf_idle", (perf.scriptMs("logic_net") or 0) < 0.1, "the logic network idle: %.4f ms a frame", perf.scriptMs("logic_net") or -1)
    -- 200 gates, far off on their own slab: a lever and a chain of 200 modules
    local s2 = ST.addPart(sid, { id = "slab2.concrete", x = OX + 40, y = 0, z = 0, yaw = 0 })
    local lev = ST.addPart(sid, { id = "liLever.steel", x = OX + 40, y = T, z = -0.8, yaw = 0, pitch = 0 })
    local prev, pin = lev, "Q"
    local gates = {}
    for k = 1, 200 do
      local kind = ({ "lgOr.steel", "lgAnd.steel", "lgXor.steel", "lgNot.steel" })[(k - 1) % 4 + 1]
      local u = ST.addPart(sid, { id = kind, x = OX + 40 + ((k - 1) % 10) * 0.2 - 0.9, y = T, z = math.floor((k - 1) / 10) * 0.25 - 2.5, yaw = 0, pitch = 0 })
      gates[#gates + 1] = { u = u, kind = kind }
    end
    LN.rebuildNow()
    for k, g in ipairs(gates) do
      LN.layWire({ sid = sid, uid = prev, pin = pin }, { sid = sid, uid = g.u, pin = "A" }, { ground = false, free = true, noHistory = true })
      if g.kind ~= "lgNot.steel" then LN.layWire({ sid = sid, uid = lev, pin = "Q" }, { sid = sid, uid = g.u, pin = "B" }, { ground = false, free = true, noHistory = true }) end
      prev = g.u
    end
    wait(1.5)
    LN.stepNow()
    local worst, sum, n, ev = 0, 0, 0, 0
    local fr1 = FRAME
    sc_begin("logic_200");
    for k = 1, 20 do
      local t0, e0, s0 = LN.PROF.ticks, LN.PROF.evsum, LN.PROF.tsum
      LN.setLever(sid, lev, k % 2 == 1)
      wait(0.2)
      -- (the tick that took the change: the sums' difference over the ticks since)
      local dt_ = LN.PROF.tsum - s0
      sum = sum + dt_; n = n + 1
      worst = math.max(worst, dt_)
      ev = math.max(ev, LN.PROF.evsum - e0)
    end
    sc_end("logic_200")
    P("LG PERF 200 gates: a lever thrown 20 times · %.3f ms of ticks a change (worst %.3f ms) · up to %d evals a change · logic_net %.4f ms/frame (%d frames) · %d nodes %d cables",
      sum / math.max(n, 1), worst, ev, perf.scriptMs("logic_net") or -1, FRAME - fr1, LN.PROF.nodes or -1, LN.PROF.wires or -1)
    BK.check("perf_200", sum / math.max(n, 1) < 1.0 and ev >= 150, "200 gates switching: %.3f ms a change on average (%d evaluated)", sum / math.max(n, 1), ev)
    -- (taken away again: the reload below is the examples')
    local gone = {}
    for _, g in ipairs(gates) do gone[#gone + 1] = g.u end
    gone[#gone + 1] = lev
    gone[#gone + 1] = s2
    ST.removeParts(sid, gone)
    wait(2.0)
  end
  -- ── 6. save and reload ──
  -- (the cycle asked again from outside, so the reload has a hold and a relay set to keep)
  KIT.tp(rec, -5.5, -0.3)
  wait(1.0)
  local pe2 = BK.entry(lmenu(ST, sid, U.button), "lg_press")
  if pe2 and pe2.act then pe2.act() end
  wait(1.0)
  local nw0 = #LN.wires()
  local prog0 = LGc.programStrings(LN.program(sid, U.plc))
  local m10 = (LN.readout(sid, U.plc) or {}).M
  local cyc0 = LN.cycling(sid, U.outer)
  local p0 = LN.pathOf(LN.wires()[1].id)
  LN.saveNow(); RA.saveNow(); RP.saveNow()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(5)
  LN, ST, RA, LGc = findScript("logic_net"), findScript("structures"), findScript("room_air"), findScript("logic")
  RA.setVacuum(true)
  wait(2)
  LN.stepNow()
  local prog1 = LGc.programStrings(LN.program(sid, U.plc))
  local m11 = (LN.readout(sid, U.plc) or {}).M
  local p1 = LN.wires()[1] and LN.pathOf(LN.wires()[1].id)
  local same = #prog0 == #prog1
  for k = 1, #prog0 do if prog0[k] ~= prog1[k] then same = false end end
  BK.check("reload", #LN.wires() == nw0 and same and m10 and m10[1] and m11 and m11[1] and cyc0 and LN.cycling(sid, U.outer) and p1 and #p1 == #p0,
    "after a reload: %d cables (were %d) where they lay (%s points, were %d), the ladder's rungs (%s), its M1 still set (%s → %s) and the airlock still asked to cycle (%s → %s)",
    #LN.wires(), nw0, tostring(p1 and #p1), #p0, tostring(same), tostring(m10 and m10[1]), tostring(m11 and m11[1]), tostring(cyc0), tostring(LN.cycling(sid, U.outer)))
  rec = ST.get(sid)
  LN.overlay, LN.overlayAlways = true, true
  wait(1.0)
  KIT.oview("l7_reload_overlay", rec, { -4.2, 2.2, -2.6 }, { -1.1, 1.3, -0.4 })
  LN.overlayAlways = false
  BK.result()
end
