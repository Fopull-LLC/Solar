-- ── laser probe (tools/perf/laserprobe.sh; expansion X9, "Energy weapons I";
-- docs/base-building.md §27)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam)
-- and buildkitprobe_modes.lua (BK helpers).
--   laser   On flat ground: laser A (10 Capacitor Banks on a line → Laser
--           Emitter → Lens Group → Beam Director, a Jacket Radiator on its heat
--           port), laser B (an emitter and an Amplifier Stage on a bank each →
--           director), a Fire Control Console, 30 Isotope Skids and three
--           Battery Banks. A row of walls 40 m out (steel, concrete, glass,
--           regocrete, concrete, steel). Charging from the grid at 50 kW a
--           bank (B armed, warp); A's banks set full (logged) and pulses at
--           each wall through the targeting feature (Laser target here): the
--           hp each takes against damage.lua's prediction; B's stage adds its
--           banks; a crater in the ground; a CW burn; logic fire; the
--           cinematic rule invoked directly at X11 scale (no such build yet);
--           costs idle, armed, firing, GPU with the beam on and off.
--   turret  A derelict rocket (pod, tank, engine) teleported 30 m out, then a
--           craft with a Laser Turret on its tank: charged from its batteries,
--           it tracks the targeting selection (the derelict's tank) and its
--           pulse breaks the tank; AUTO fires by itself on the pod; a kit laser
--           finishes the wreck. Costs.
-- `LZ PASS|FAIL <check>`, `LZ …` lines and `LZ RESULT`. Pictures: save/user/lasershots/.
LZP = { fails = 0, passed = 0, tag = "laser" }
function LZP.check(name, okc, fmt, ...)
  P("LZ %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then LZP.passed = LZP.passed + 1 else LZP.fails = LZP.fails + 1 end
  return okc
end
function LZP.result() P("LZ RESULT %s: %d passed, %d failed", LZP.tag, LZP.passed, LZP.fails) end
function LZP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://lasershots/" .. nm .. ".png", bytes); P("LZ SHOT %s", nm)
    else P("LZ SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- a camera fixed in a structure's frame (body-relative: the planet moves)
function LZP.cam(rec, e, t)
  local KS = findScript("kit_snap")
  local fr = KS.frameOf(rec)
  local function B(v) return { x = fr.O.x + fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], y = fr.O.y + fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                               z = fr.O.z + fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3] } end
  VP.cam_fixed(B(e), B(t))
end
function LZP.gpu(n)
  local tot, k = 0, 0
  for _ = 1, n or 60 do
    yield()
    local g = perf.gpu and perf.gpu()
    if g and g.total then tot, k = tot + g.total, k + 1 end
  end
  return k > 0 and tot / k or -1
end
function LZP.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  local LZ, LT = findScript("lasers"), findScript("laser_turret")
  local c = perf.counts and perf.counts() or {}
  P("LZ COST %s: lasers %.4f ms/frame, laser_turret %.4f, beam %.4f, damage %.4f, base_grid %.4f, vfx %.4f · fixed %.3f ms, late %.3f ms, scan %.3f ms, fire %.3f ms, ray %.3f ms · rays %d · particles %s effects %s",
    tag, ms("lasers"), ms("laser_turret"), ms("beam"), ms("damage"), ms("base_grid"), ms("vfx"), LZ.PROF.fix_ms or 0, LZ.PROF.late_ms or 0, LZ.PROF.scan_ms or 0,
    LZ.PROF.fire_ms or 0, LZ.PROF.ray_ms or 0, LZ.PROF.rays or 0, tostring(c.particles), tostring(c.effects))
  return ms("lasers") + ms("laser_turret")
end

-- the site: the crew on the flattest ground near the base, a frame facing out
function LZP.site()
  local spot = BK.flat_spot()
  if not spot then return nil end
  stand_at(spot)
  wait(4)
  local b = home()
  local a = astro()
  local U = unit(sub(a, b))
  local Fw = unit(sub(spot.t, scl(U, dot(spot.t, U))))
  local R = unit(cross(U, Fw))
  local A = sub(a, b)
  local O = { x = A.x + Fw.x * 5 - R.x * 2, y = A.y + Fw.y * 5 - R.y * 2, z = A.z + Fw.z * 5 - R.z * 2 }
  local S = { b = b.name, U = U, Fw = Fw, R = R, O = O, d = spot.d }
  function S.ground(lx, lz)
    local bb = home()
    local wx, wy, wz = bb.x + O.x + R.x * lx + Fw.x * lz + U.x * 30, bb.y + O.y + R.y * lx + Fw.y * lz + U.y * 30, bb.z + O.z + R.z * lx + Fw.z * lz + U.z * 30
    local h = terrain.raycast(vec3(wx, wy, wz), vec3(-U.x, -U.y, -U.z), 80)
    if not (h and h.pos) then return 0 end
    return dot(sub(h.pos, bb), U) - dot(O, U)
  end
  -- body-relative point of local (lx, ly, lz)
  function S.at(lx, ly, lz) return { x = O.x + R.x * lx + U.x * ly + Fw.x * lz, y = O.y + R.y * lx + U.y * ly + Fw.y * lz, z = O.z + R.z * lx + U.z * ly + Fw.z * lz } end
  return S
end
-- a structure at local (lx, lz) on the ground, its pieces at a common height
function LZP.structure(S, name, lx, lz, first, corners)
  local ST = findScript("structures")
  local y0 = S.ground(lx, lz)
  local P0 = S.at(lx, y0, lz)
  local rec = ST.newRecord(nil, S.b, P0.x, P0.y, P0.z, S.U, S.Fw, first, { name = name, t = 0 })
  local sid = ST.add(rec)
  rec = ST.get(sid)
  local hy = 0
  for _, c in ipairs(corners or { { 0, 0 } }) do hy = math.max(hy, S.ground(lx + c[1], lz + c[2]) - y0) end
  hy = hy + 0.05
  rec.bp[1].y = hy
  return sid, rec, hy
end
-- a piece's body-relative point at height h over its ground point
function LZP.pieceAt(sid, uid, h)
  local ST = findScript("structures")
  local rec = ST.get(sid)
  local p = ST.getPart(sid, uid)
  if not (rec and p) then return nil end
  local x, y, z, U = ST.partPose(rec, p, 0)
  return { x = x + U.x * h, y = y + U.y * h, z = z + U.z * h }
end
local function hp_of(sid, uid)
  local ST = findScript("structures")
  if not ST.getPart(sid, uid) then return 0 end
  return findScript("lasers").hpOf(sid, uid)
end
function LZP.aim(LZ, w, tmo)
  wait(0.1)
  return wait_for(function() return w.onT and w end, tmo or 25, "on target")
end

-- ═══════════════════════════════════ laser ═══════════════════════════════════
function LZP.run()
  LZP.tag = "laser"
  wait_ready(120)
  wait(2)
  local ST, LZ, BEAM, DM, BG, rs, co, TG = findScript("structures"), findScript("lasers"), findScript("beam"), findScript("damage"), findScript("base_grid"),
    findScript("research"), findScript("company"), findScript("targeting")
  if not LZP.check("scene", ST and LZ and BEAM and DM and BG and TG, "lasers %s beam %s damage %s targeting %s", tostring(LZ ~= nil), tostring(BEAM ~= nil), tostring(DM ~= nil), tostring(TG ~= nil)) then LZP.result() return end
  if perf.enable then perf.enable(true) end
  local idle0 = LZP.cost("idle: no laser anywhere", 3)
  if co and co.earn then co.earn(3000000, "probe") end
  BK.unlock()
  for _, id in ipairs({ "lasers", "laserAmp", "laserTurret", "refinery" }) do rs.grant(id, "probe") end
  local S = LZP.site()
  if not LZP.check("spot", S ~= nil, "flat ground %s m out", S and S.d or -1) then LZP.result() return end
  -- laser A along +Z at x 0; ten banks on its pulse port, out along −X
  local corners = { { -21, -1 }, { -21, 1 }, { 7, -12 }, { 7, 4 }, { -18, -10 }, { 3, 4 } }
  local sid, rec, hy = LZP.structure(S, "Laser Site", 0, 0, "lzEmitter.steel", corners)
  local U = { emA = rec.bp[1].uid }
  local function add(id, x, z, yaw, extra)
    local p = { id = id, x = x, y = hy, z = z, yaw = yaw or 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    return ST.addPart(sid, p)
  end
  U.lensA = add("lzLens.steel", 0, 1.25)
  U.dirA = add("lzDirector.steel", 0, 2.5)
  U.banksA = {}
  for k = 0, 9 do U.banksA[#U.banksA + 1] = add("lzCap.steel", -1.5 - 2 * k, 0) end
  U.jacket = add("mcJacket.steel", 1.5, 0)
  -- laser B at x 6: emitter → amplifier → director, a bank on each
  U.emB = add("lzEmitter.steel", 6, 0)
  U.ampB = add("lzAmp.steel", 6, 1.75)
  U.dirB = add("lzDirector.steel", 6, 3.5)
  U.bankB1 = add("lzCap.steel", 4.5, 0)
  U.bankB2 = add("lzCap.steel", 4.5, 1.75)
  U.console = add("lzConsole.steel", 3.0, -2.2)
  -- the power: 50 Isotope Skids (100 kW) and five Battery Banks (full: 20 MJ)
  for k = 0, 49 do
    local row, col = math.floor(k / 10), k % 10
    add("isotopeSkid", -18 + col * 1.9, -4 - row * 1.4)
  end
  for k = 0, 4 do add("batteryBank", -6 + k * 3, -12, 0, { fill = 1.0 }) end
  ST.spawnNow(sid)
  wait(2.5)
  -- the targets: a row of walls 40 m out
  local tid, trec, thy = LZP.structure(S, "Targets", 0, 40, "wall.steel", { { -8, 0 }, { 8, 0 } })
  local T = { steel = trec.bp[1].uid }
  trec.bp[1].x = -7.5
  local function tadd(id, x) return ST.addPart(tid, { id = id, x = x, y = thy, z = 0, yaw = 0 }) end
  T.concrete = tadd("wall.concrete", -4.5)
  T.glass = tadd("wall.glass", -1.5)
  T.rego = tadd("wall.regocrete", 1.5)
  T.concrete2 = tadd("wall.concrete", 4.5)
  T.steel2 = tadd("wall.steel", 7.5)
  ST.spawnNow(tid)
  wait(2)
  -- 1. the layout
  local wA = wait_for(function() local w = LZ.weaponOf(sid, U.dirA); return w and w end, 10, "laser A")
  local wB = LZ.weaponOf(sid, U.dirB)
  if not LZP.check("layout", wA and wB and wA ~= wB, "%d weapons on the site", #LZ.weapons()) then LZP.result() return end
  LZP.check("chainA", wA.why == nil and #wA.stages == 0 and #wA.lenses == 1 and #wA.feedE.banks == 10,
    "A: emitter → lens → director, %d banks, %d stage(s), %d lens(es), why %s, cooling %.2f", #wA.feedE.banks, #wA.stages, #wA.lenses, tostring(wA.why), wA.cool or -1)
  LZP.check("chainB", wB.why == nil and #wB.stages == 1 and #wB.feedS[1].banks == 1 and #wB.feedE.banks == 1,
    "B: emitter → amplifier → director, a bank each (%d + %d), why %s, cooling %.2f", #wB.feedE.banks, #(wB.feedS[1] and wB.feedS[1].banks or {}), tostring(wB.why), wB.cool or -1)
  LZP.check("cooling", (wA.cool or 0) > (wB.cool or 0) + 0.05, "A's Jacket Radiator: cooling %.2f against B's bare %.2f", wA.cool or -1, wB.cool or -1)
  local idle1 = LZP.cost("idle: two lasers built, disarmed", 3)
  -- 2. charging from the grid (B: two banks, 100 kW, against 60 kW of skids and the Battery Banks)
  LZ.setArm(sid, U.dirB, true)
  wait(2.5)
  local served = { BG.partServed(sid, U.bankB1), BG.partServed(sid, U.bankB2) }
  local dp = findScript("deployables")
  local e0, a0 = LZ.charge(sid, U.dirB), dp.agencyClock()
  space.warp(10)
  wait(3)
  space.warp(1)
  wait(0.6)
  local e1, a1 = LZ.charge(sid, U.dirB), dp.agencyClock()
  local nserved = (served[1] and 1 or 0) + (served[2] and 1 or 0)
  local rate = (e1 - e0) / math.max(1e-6, a1 - a0) / math.max(1, nserved) / 1000
  local gs = BG.status and BG.status((BG.gridOfStruct(sid) or {}).id) or {}
  LZP.check("charge", nserved >= 1 and rate > 40 and rate < 52, "B's banks: served %s/%s, %.1f MJ in %.1f s of agency clock → %.1f kW a served bank (50 kW), grid supply %.1f kW need %.1f stored %.0f EC",
    tostring(served[1]), tostring(served[2]), (e1 - e0) / 1e6, a1 - a0, rate, gs.supply or -1, gs.need or -1, gs.stored or -1)
  -- 3. A full (the probe sets its banks: 20 MJ each, logged) and armed
  LZ.setArm(sid, U.dirB, false)
  LZ.setCharge(sid, U.dirA, 1)
  LZ.setArm(sid, U.dirA, true)
  do
    local se = save.get("lz.e")
    local nb = 0
    if type(se) == "table" then for _ in pairs(se) do nb = nb + 1 end end
    LZP.check("save", nb >= 10 and save.get("lz.a") ~= nil, "lz.e holds %d bank charges (A full, B's charge), lz.a %s", nb, tostring(save.get("lz.a")))
  end
  LZ.PULSE_SHOW = 2.5
  P("LZ NOTE: A's ten banks set full by the probe (200 MJ); a pulse's beam is held 2.5 s for the pictures (PULSE_SHOW, 0.15 s in play)")
  local function target_piece(tsid, tuid, name)
    local p = LZP.pieceAt(tsid, tuid, 1.1)
    TG.targetSpot(S.b, p.x, p.y, p.z, name)
  end
  local function pulse(w, sidd, uidd, tag, expectKind)
    local n0 = LZ.PROF.shots
    local ok, why = LZ.fire(sidd, uidd)
    if not ok then P("LZ fire %s refused: %s", tag, tostring(why)); return nil end
    wait_for(function() return LZ.PROF.shots > n0 end, 3, "the pulse")
    local r = LZ.lastShot
    if r then
      P("LZ SHOT %s: %s at %.1f m → %s %s · spot %.3f m · F %.3g J/m² · T %.4f · E on %.2f MJ · c %.3g · amount %s hp %s → %s%s · cooldown %.1f s",
        tag, LZ.fmtEnergy(r.E), r.R, r.kind, tostring(r.hit and (r.hit.label or r.hit.kind)), r.d, r.F, r.T, r.Eon / 1e6, r.c,
        tostring(r.hit and r.hit.amount and string.format("%.4f", r.hit.amount)), tostring(r.hit and r.hit.hp0), tostring(r.hit and r.hit.hp),
        r.hit and r.hit.removed and " (REMOVED)" or "", r.cooldown or -1)
    end
    return r
  end
  local function recharge(w, sidd, uidd)
    LZ.setCharge(sidd, uidd, 1)
    w.cd = 0
  end
  -- (the probe's own camera for the steel wall: from the side, laser and walls in frame)
  target_piece(tid, T.steel, "steel wall")
  local onA = LZP.aim(LZ, wA, 30)
  local ro = LZ.readout(sid, U.dirA) or {}
  P("LZ READOUT A: pulse %s, target %s at %.1f m, spot %.3f m, F %.3g, tank %s, pod %s, steel %s, concrete %s, crater %.3f m, c %.3g",
    LZ.fmtEnergy(ro.E or 0), tostring(ro.target), ro.range or -1, ro.d or -1, ro.F or -1, ro.verdict and ro.verdict.tank or "-", ro.verdict and ro.verdict.pod or "-",
    ro.verdict and ro.verdict.steel or "-", ro.verdict and ro.verdict.concrete or "-", ro.crater or -1, ro.c or -1)
  LZP.check("track", onA ~= nil, "A slewed onto the steel wall via the targeting selection (err %.4f°, range %.1f m)", math.deg(wA.err or 9), wA.range or -1)
  LZP.check("pulseE", math.abs((ro.E or 0) - 55.2e6) < 0.01e6, "A's pulse from ten full banks: %s (0.92 × 0.30 × 200 MJ = 55.2 MJ)", LZ.fmtEnergy(ro.E or 0))
  local armed = LZP.cost("armed, two directors tracking", 3)
  -- the muzzle the beam is drawn from vs the head as drawn (one pass)
  do
    local n = ST.nodeOf(sid, U.dirA)
    local h = n and n:find("Head")
    local mx, my, mz = LZ.muzzleOf(wA)
    if h and mx then
      local hw = h:toWorld(vec3(0, 0, wA.L.muzzle or 0.55))
      local dd = math.sqrt((hw.x - mx) ^ 2 + (hw.y - my) ^ 2 + (hw.z - mz) ^ 2)
      LZP.check("muzzle", dd < 0.05, "the beam's origin (the record against this pass's body) vs the drawn head's muzzle: %.3f m", dd)
    else LZP.check("muzzle", false, "no head node") end
  end
  LZP.cam(rec, { 12, 6, -6 }, { 0, 2, 22 })
  wait(1.2)
  local r1 = pulse(wA, sid, U.dirA, "steel", "piece")
  wait(0.3)
  LZP.shot("l1_pulse_steel_side")
  LZP.check("steel", r1 and r1.kind == "piece" and r1.hit.mat == "steel" and r1.hit.removed and r1.d <= 0.021,
    "a 55 MJ pulse fells a steel sandwich wall (cut %.2f MJ): amount %s, removed %s", (r1 and r1.hit.cut or 0) / 1e6, tostring(r1 and r1.hit.amount), tostring(r1 and r1.hit.removed))
  -- the plan's table at this range: the fluence on the 2 cm spot
  if r1 then
    LZP.check("fluence", math.abs(r1.F - BEAM.fluence(r1.Eon, 0.02)) / r1.F < 1e-6 and r1.F > 1e11, "F = E/(π d²/4) on the 2 cm floor: %.3g J/m² (plan rule)", r1.F)
  end
  wait(2.6)
  -- concrete: armour (two pulses)
  recharge(wA, sid, U.dirA)
  target_piece(tid, T.concrete, "concrete wall")
  LZP.aim(LZ, wA, 20)
  LZP.cam(rec, { 0.8, 3.2, -3.5 }, { -3, 1.2, 40 })
  wait(1.0)
  local r2 = pulse(wA, sid, U.dirA, "concrete 1", "piece")
  wait(0.3)
  LZP.shot("l2_pulse_concrete_behind")
  local pred2 = DM.pieceAmount(r2 and r2.F or 0, r2 and r2.Eon or 0, "concrete", 2.02, 2.2)
  LZP.check("concrete1", r2 and r2.hit.mat == "concrete" and not r2.hit.removed and math.abs((r2.hit.hp or -1) - (1 - pred2)) < 0.002 and r2.hit.hp > 0.03 and r2.hit.hp < 0.15,
    "one pulse wears a concrete wall to %.3f (predicted %.3f, cut %.1f MJ)", r2 and r2.hit.hp or -1, 1 - pred2, (r2 and r2.hit.cut or 0) / 1e6)
  wait(2.6)
  recharge(wA, sid, U.dirA)
  local r3 = pulse(wA, sid, U.dirA, "concrete 2", "piece")
  LZP.check("concrete2", r3 and r3.hit.removed, "the second pulse fells it (hp %s → 0)", tostring(r3 and r3.hit.hp0))
  wait(2.6)
  -- glass and regocrete
  recharge(wA, sid, U.dirA)
  target_piece(tid, T.glass, "glass wall")
  LZP.aim(LZ, wA, 20)
  local r4 = pulse(wA, sid, U.dirA, "glass", "piece")
  LZP.check("glass", r4 and r4.hit.mat == "glass" and r4.hit.removed, "a glass wall (cut %.1f MJ, F_th 5e5): removed %s", (r4 and r4.hit.cut or 0) / 1e6, tostring(r4 and r4.hit.removed))
  wait(2.6)
  recharge(wA, sid, U.dirA)
  target_piece(tid, T.rego, "regocrete wall")
  LZP.aim(LZ, wA, 20)
  local r5 = pulse(wA, sid, U.dirA, "regocrete", "piece")
  local pred5 = DM.pieceAmount(r5 and r5.F or 0, r5 and r5.Eon or 0, "regocrete", 1.76, 2.2)
  LZP.check("regocrete", r5 and r5.hit.mat == "regocrete" and math.abs((r5.hit.amount or -1) - pred5) < 1e-6, "a regocrete wall: amount %.3f (predicted %.3f, cut %.1f MJ)%s",
    r5 and r5.hit.amount or -1, pred5, (r5 and r5.hit.cut or 0) / 1e6, r5 and r5.hit.removed and ", removed" or "")
  wait(2.6)
  -- the row of walls after A's pulses: gaps, a scorched stump of hp, chunks
  LZP.cam(rec, { 3, 3.5, 27 }, { 0, 1.0, 40 })
  wait(1.5)
  LZP.shot("l2b_walls_after")
  -- 4. B: the stage adds its own bank
  LZ.setArm(sid, U.dirB, true)
  LZ.setCharge(sid, U.dirB, 1)
  wB.cd = 0
  target_piece(tid, T.concrete2, "concrete wall 2")
  LZP.aim(LZ, wB, 25)
  local EB = LZ.pulseOf(wB)
  local r6 = pulse(wB, sid, U.dirB, "B on concrete", "piece")
  LZ.setArm(sid, U.dirB, false)
  LZP.check("amp", math.abs(EB - 0.92 * (0.30 + 0.45) * 20e6) < 1e3 and r6 and r6.stages == 1 and (r6.hit.amount or 0) > 0.2 and (r6.hit.amount or 0) < 0.25,
    "B's pulse %s = 0.92 × (0.30 + 0.45) × 20 MJ: the amplifier adds its own bank; concrete wears %.3f", LZ.fmtEnergy(EB), r6 and r6.hit.amount or -1)
  wait(2.6)
  -- 5. the ground: one 55 MJ pulse is a 0.26 m crater
  local gy = S.ground(-4, 25)
  local gp = S.at(-4, gy, 25)
  local bb = home()
  local sd0 = terrain.query(bb.x + gp.x - S.U.x * 0.15, bb.y + gp.y - S.U.y * 0.15, bb.z + gp.z - S.U.z * 0.15)
  local fe0 = (perf.counts() or {}).fieldEdited or -1
  TG.targetSpot(S.b, gp.x, gp.y, gp.z, "the ground")
  recharge(wA, sid, U.dirA)
  LZP.aim(LZ, wA, 20)
  -- (a 55 MJ pulse melts a 0.26 m pit, under the smallest dig the ground takes (~1 m): the
  -- energy waits on the spot until it makes a 1 m pit, damage.CRATER_MIN: 3 GJ, 55 pulses)
  local r7, npulse = nil, 0
  for k = 1, 64 do
    recharge(wA, sid, U.dirA)
    r7 = pulse(wA, sid, U.dirA, "ground " .. k, "ground")
    npulse = k
    if r7 and r7.hit and r7.hit.dug then break end
    wait(0.05)
  end
  wait(2.0)
  bb = home()
  if r7 and r7.hit and r7.hit.cx then
    local q0 = terrain.query(bb.x + r7.hit.cx, bb.y + r7.hit.cy, bb.z + r7.hit.cz)
    P("LZ PIT: the dig's centre %.2f m from the probe's spot; SDF there now %.3f; terrain.pending %s",
      math.sqrt((r7.hit.cx - gp.x + S.U.x * 0.15) ^ 2 + (r7.hit.cy - gp.y + S.U.y * 0.15) ^ 2 + (r7.hit.cz - gp.z + S.U.z * 0.15) ^ 2), q0 or -9, tostring(terrain.pending and terrain.pending()))
  end
  -- the control: the engine's own dig of the same size, and of 1 m, 3 m to the side
  do
    local cg = S.ground(-7, 25)
    local cp = S.at(-7, cg, 25)
    local function q(dd) return terrain.query(bb.x + cp.x - S.U.x * dd, bb.y + cp.y - S.U.y * dd, bb.z + cp.z - S.U.z * dd) end
    local a0 = q(0.15)
    pcall(terrain.dig, bb.x + cp.x - S.U.x * 0.15, bb.y + cp.y - S.U.y * 0.15, bb.z + cp.z - S.U.z * 0.15, 0.505, 1.0, { hardness = 1.0, falloff = "linear" })
    wait(1.0)
    bb = home()
    local a1 = q(0.15)
    local cg2 = S.ground(-10, 25)
    local cp2 = S.at(-10, cg2, 25)
    local b0 = terrain.query(bb.x + cp2.x - S.U.x * 0.3, bb.y + cp2.y - S.U.y * 0.3, bb.z + cp2.z - S.U.z * 0.3)
    pcall(terrain.dig, bb.x + cp2.x - S.U.x * 0.3, bb.y + cp2.y - S.U.y * 0.3, bb.z + cp2.z - S.U.z * 0.3, 1.0, 1.0, { hardness = 1.0, falloff = "linear" })
    wait(1.0)
    bb = home()
    local b1 = terrain.query(bb.x + cp2.x - S.U.x * 0.3, bb.y + cp2.y - S.U.y * 0.3, bb.z + cp2.z - S.U.z * 0.3)
    P("LZ DIG CONTROL: terrain.dig 0.505 m hard: SDF %.3f → %.3f; 1.0 m hard: %.3f → %.3f", a0 or -9, a1 or -9, b0 or -9, b1 or -9)
  end
  local sd1 = terrain.query(bb.x + gp.x - S.U.x * 0.15, bb.y + gp.y - S.U.y * 0.15, bb.z + gp.z - S.U.z * 0.15)
  local fe1 = (perf.counts() or {}).fieldEdited or -1
  LZP.check("crater", r7 and r7.kind == "ground" and r7.hit.dug and r7.hit.dug >= DM.CRATER_MIN and (sd1 or -9) > (sd0 or -9) + 0.1,
    "the ground: %d pulses of %.1f MJ on one spot → a %.3f m pit (crater(E) = (E / 3 GJ/m³)^⅓; one pulse alone %.3f m, plan 60 MJ → 0.27 m); the SDF 15 cm under the spot (the dig's centre) %.3f → %.3f; edited fields %s → %s",
    npulse, r7 and r7.Eon / 1e6 or -1, r7 and r7.hit.dug or -1, DM.crater(r7 and r7.Eon or 0, 0), sd0 or -9, sd1 or -9, tostring(fe0), tostring(fe1))
  LZP.cam(rec, { -4.5, 7.5, 20.0 }, { -4, 0.0, 25 })
  wait(1.2)
  LZP.shot("l3_crater")
  -- 6. CW: 30 kW, a ray every 0.1 s, on the second steel wall (the banks full first: an armed
  -- laser's empty banks pull 500 kW and the grid would shed the emitter)
  LZ.setCharge(sid, U.dirA, 1)
  wait(2.5)
  target_piece(tid, T.steel2, "steel wall 2")
  LZP.aim(LZ, wA, 20)
  local hp0 = hp_of(tid, T.steel2)
  local cam = { 13, 5, 14 }
  LZP.cam(rec, cam, { 4, 1.5, 30 })
  wait(1.0)
  local gOff = LZP.gpu(90)
  LZ.setCw(sid, U.dirA, true)
  local t0 = time
  wait(0.8)
  local gOn = LZP.gpu(90)
  LZ.setCw(sid, U.dirA, false)
  wait(0.5)
  local gOff2 = LZP.gpu(90)
  LZ.setCw(sid, U.dirA, true)
  wait(0.5)
  local gOn2 = LZP.gpu(90)
  P("LZ GPU A/B: off %.3f, on %.3f, off %.3f, on %.3f ms", gOff, gOn, gOff2, gOn2)
  gOff, gOn = (gOff + gOff2) / 2, (gOn + gOn2) / 2
  LZP.shot("l4_cw_side")
  local cw = LZP.cost("CW burning (30 kW, a ray every 0.1 s)", 2)
  LZP.cam(rec, { -1.5, 3.6, -2 }, { 7, 1.2, 40 })
  wait(1.0)
  LZP.shot("l5_cw_behind")
  wait(math.max(0, 6 - (time - t0)))
  LZ.setCw(sid, U.dirA, false)
  local burnt = time - t0
  wait(0.5)
  local hp1 = hp_of(tid, T.steel2)
  local lc = wA.lastCw
  local perTick = lc and lc.hit and lc.hit.amount or 0
  LZP.check("cw", hp1 < hp0 and hp1 > 0 and perTick > 0, "CW %.1f s on a steel wall: hp %.3f → %.3f (%.4f a 0.1 s tick, %.0f kJ a tick at cooling %.2f; %.0f s to cut through)",
    burnt, hp0, hp1, perTick, lc and lc.Eon / 1e3 or -1, wA.cool or -1, perTick > 0 and 0.1 / perTick or -1)
  P("LZ GPU: beam off %.3f ms, CW beam on %.3f ms (Δ %.3f ms) from the same camera", gOff, gOn, gOn - gOff)
  -- 7. logic: fire on the console's terminal
  recharge(wA, sid, U.dirA)
  local lo = LZ.logicOut(sid, U.console)
  local n0 = LZ.PROF.shots
  LZ.logicIn(sid, U.console, "fire", true)
  wait_for(function() return LZ.PROF.shots > n0 end, 3, "the logic pulse")
  LZP.check("logic", lo.ready == true and LZ.PROF.shots > n0, "the console's terminals: ready %s, on target %s; a fire edge fired (%d → %d shots)", tostring(lo.ready), tostring(lo.ontgt), n0, LZ.PROF.shots)
  wait(1)
  local pulseMs, rayMs = LZ.PROF.fire_ms, LZ.PROF.ray_ms
  -- 8. the cinematic rule, invoked directly at X11 scale: an 8 m dish, six stages, 22 GJ on a 0.3 m spot
  do
    local Ebig = 22e9
    local F = BEAM.fluence(Ebig, 0.3)
    local c = BEAM.regime(Ebig, F, 6, 8)
    local cNow = BEAM.regime(LZ.pulseOf(wA) > 0 and 55.2e6 or 55.2e6, BEAM.fluence(55.2e6, 0.02), 0, 0.5)
    P("LZ REGIME: laser A c = %.6f (the physics); the largest X9 build (0.5 m, six stages, 30 banks a bus, 1.66 GJ) c = %.4f; X11's 8 m dish at 22 GJ c = %.3f",
      cNow, BEAM.regime(1.66e9, BEAM.fluence(1.66e9, 0.02), 6, 0.5), c)
    local gy2 = S.ground(14, 34)
    local p2 = S.at(14, gy2, 34)
    -- three spare walls round it, to show the blast's reach
    local cid, crec, chy = LZP.structure(S, "Blast walls", 14, 40, "wall.steel", { { -3, 0 }, { 3, 0 } })
    ST.addPart(cid, { id = "wall.concrete", x = -3, y = chy, z = 0, yaw = 0 })
    ST.addPart(cid, { id = "wall.steel", x = 3, y = chy, z = 0, yaw = 0 })
    ST.spawnNow(cid)
    wait(1.5)
    local n1 = #(ST.get(cid) or { bp = {} }).bp
    LZP.cam(rec, { 2, 28, 6 }, { 14, 0, 36 })
    wait(1.0)
    bb = home()
    local hit = { kind = "ground", x = bb.x + p2.x, y = bb.y + p2.y, z = bb.z + p2.z, nx = S.U.x, ny = S.U.y, nz = S.U.z, d = 0 }
    local rr = LZ.applyHit(hit, Ebig, { D = 8, theta = BEAM.divergence(8, 6, BEAM.JIT_LARGE), focus = 0, stages = 6, body = S.b, tag = "cinematic rule", airRho = 0 })
    wait(0.25)
    LZP.shot("l6_cinematic_rule")
    wait(2.0)
    local n2 = ST.get(cid) and #ST.get(cid).bp or 0
    LZP.check("regime", c > 0.9 and rr.c > 0.9 and rr.blast and rr.blast.rb > 20 and n2 < n1,
      "at c = %.2f: %.0f kg TNT, blast radius %.1f m, %d pieces and %d parts hit, the walls %d → %d; crater %.2f m (physics alone: %.2f m)",
      rr.c, rr.blast and rr.blast.W or -1, rr.blast and rr.blast.rb or -1, rr.blast and rr.blast.pieces or -1, rr.blast and rr.blast.parts or -1, n1, n2,
      rr.hit and (rr.hit.dug or rr.hit.r) or -1, DM.crater(Ebig, 0))
  end
  VP.cam_off()
  -- 10. costs: disarmed again
  LZ.setArm(sid, U.dirA, false)
  LZ.setArm(sid, U.dirB, false)
  local idle2 = LZP.cost("idle: lasers built, disarmed (after firing)", 3)
  P("LZ COSTS: nothing built %.4f · built, disarmed %.4f · armed tracking %.4f · CW %.4f · after %.4f ms/frame (lasers + laser_turret) · a pulse %.3f ms (its ray %.3f ms) · GPU beam Δ %.3f ms",
    idle0, idle1, armed, cw, idle2, pulseMs or -1, rayMs or -1, gOn - gOff)
  LZP.result()
end

-- ═══════════════════════════════════ turret ═════════════════════════════════
function LZP.run_turret()
  LZP.tag = "turret"
  wait_ready(120)
  wait(2)
  local ST, LZ, LT, BEAM, DM, rs, co, TG = findScript("structures"), findScript("lasers"), findScript("laser_turret"), findScript("beam"), findScript("damage"),
    findScript("research"), findScript("company"), findScript("targeting")
  if not LZP.check("scene", ST and LZ and LT and TG, "lasers %s laser_turret %s", tostring(LZ ~= nil), tostring(LT ~= nil)) then LZP.result() return end
  if perf.enable then perf.enable(true) end
  local idle0 = LZP.cost("idle: no turret", 3)
  if co and co.earn then co.earn(3000000, "probe") end
  BK.unlock()
  for _, id in ipairs({ "lasers", "laserAmp", "laserTurret", "tankS", "engineS", "battery", "pod", "chute" }) do rs.grant(id, "probe") end
  local S = LZP.site()
  if not LZP.check("spot", S ~= nil, "flat ground %s m out", S and S.d or -1) then LZP.result() return end
  -- a small kit laser to finish the wreck: two banks, emitter, director, skids
  local sid, srec, hy = LZP.structure(S, "Laser Post", 0, 0, "lzEmitter.steel", { { -5, 0 }, { 2, 3 }, { 2, -4 } })
  local U = { em = srec.bp[1].uid }
  local function add(id, x, z, yaw, extra)
    local p = { id = id, x = x, y = hy, z = z, yaw = yaw or 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    return ST.addPart(sid, p)
  end
  U.dir = add("lzDirector.steel", 0, 1.5)
  U.b1 = add("lzCap.steel", -1.5, 0)
  U.b2 = add("lzCap.steel", -3.5, 0)
  for k = 0, 9 do add("isotopeSkid", -6 + k * 1.9, -3) end
  ST.spawnNow(sid)
  wait(2)
  -- the derelict: pod, tank, engine (launched, then set down 30 m out)
  local function bp_rocket(turret)
    local l = { rec(1, "engineS", 0, 0.65, 0), rec(2, "tankS", 0, 1.8, 0, { parent = 1, att = "top" }) }
    local y, last = 2.3, 2
    if turret then
      for k = 1, 3 do l[#l + 1] = rec(2 + k, "battery", 0, y + 0.5, 0, { parent = last, att = "top" }); last = 2 + k; y = y + 1.0 end
    end
    l[#l + 1] = rec(#l + 1, "pod", 0, y + 0.4, 0, { parent = last, att = "top" })
    if turret then l[#l + 1] = rec(#l + 1, "laserTurret", 0.5 + 0.42, 1.8, 0, { parent = 2, att = "surface" }) end
    return l
  end
  local function set_down(vc, lx, lz)
    vc.releaseClamps()
    wait(1.0)
    local gy = S.ground(lx, lz)
    local p = S.at(lx, gy + 2.0, lz)
    for _ = 1, 2 do
      local b = home()
      assembly.teleport(vc.node, vec3(b.x + p.x, b.y + p.y, b.z + p.z))
      wait(1.5)
    end
    wait(3.0)
  end
  local D = launch_in_vab(bp_rocket(false), "pad", 3, { name = "Derelict" })
  if not LZP.check("derelict", D ~= nil, "the derelict rolled out") then LZP.result() return end
  set_down(D, -5, 30)
  -- (the crew out of the derelict and back on foot for the second launch)
  do
    local gy = S.ground(0, -6)
    local p = S.at(0, gy + 1.2, -6)
    local b = home()
    if D.standDown then pcall(D.standDown, D.node, b.x + p.x, b.y + p.y, b.z + p.z, 0, 0, 0) end
    wait(2.0)
  end
  local Tc = launch_in_vab(bp_rocket(true), "pad", 7, { name = "Sentry" })
  if not LZP.check("sentry", Tc ~= nil, "the turret craft rolled out") then LZP.result() return end
  set_down(Tc, 6, 20)
  wait(1)
  local tl = wait_for(function() local l = LT.turrets(); return #l >= 1 and l end, 5, "the turret")
  if not LZP.check("found", tl ~= nil, "laser_turret found %d turret(s)", tl and #tl or 0) then LZP.result() return end
  local s = tl[1]
  -- 1. charging from the batteries at 10 kW
  local cs0 = Tc.controlState and Tc.controlState() or {}
  if Tc.elecSetCharge then Tc.elecSetCharge(1e9) end
  wait(0.6)
  cs0 = Tc.controlState and Tc.controlState() or {}
  LT.arm(Tc, s.uid, true)
  local e0 = s.e
  wait(3.0)
  local cs1 = Tc.controlState and Tc.controlState() or {}
  local de = s.e - e0
  LZP.check("tcharge", de > 0 and (cs0.charge or 0) > (cs1.charge or 0), "armed, its capacitor drew %.0f kJ in ~3 s (10 kW) and the batteries went %.1f → %.1f EC (cap %.0f EC)",
    de / 1e3, cs0.charge or -1, cs1.charge or -1, cs1.cap or -1)
  LT.setTurretCharge(Tc, s.uid, 1)
  LT.SHOW = 2.5
  -- 2. the derelict's tank through the targeting feature
  local tankUid = nil
  for u, d in pairs(D.aboardRecs()) do if d.id == "tankS" then tankUid = u end end
  local okT, whyT = TG.targetPart(D, tankUid)
  P("LZ target the derelict's tank (uid %s): %s %s", tostring(tankUid), tostring(okT), tostring(whyT))
  local on = wait_for(function() return s.onT and s end, 20, "turret on target")
  LZP.check("ttrack", on ~= nil, "the turret slewed onto the derelict's tank: yaw %.1f° el %.1f°, err %.3f°, %.1f m", math.deg(s.yaw), math.deg(s.el), math.deg(s.err or 9), s.range or -1)
  local armedC = LZP.cost("turret armed, tracking", 2)
  local function vcam(vc, ex, ey, ez)
    VP.cam = function()
      if not (vc.node and vc.node.valid) then return nil end
      local i = assembly.info(vc.node)
      local o = i and i.com or vc.node.worldPos
      local b = home()
      local up = unit(sub(o, b))
      return { x = o.x + S.R.x * ex + up.x * ey + S.Fw.x * ez, y = o.y + S.R.y * ex + up.y * ey + S.Fw.y * ez, z = o.z + S.R.z * ex + up.z * ey + S.Fw.z * ez }, o
    end
  end
  -- (cameras on the line between the two craft: behind the shooter looking at the target, the
  -- one way through a forest that is clear by construction)
  local function line_cam(fromV, toV, back, upk, side)
    VP.cam = function()
      if not (fromV.node and fromV.node.valid and toV.node and toV.node.valid) then return nil end
      local i1, i2 = assembly.info(fromV.node), assembly.info(toV.node)
      local a, c = i1 and i1.com or fromV.node.worldPos, i2 and i2.com or toV.node.worldPos
      local b = home()
      local up = unit(sub(a, b))
      local d = unit(sub(c, a))
      local sd = unit(cross(d, up))
      return { x = a.x - d.x * back + up.x * upk + sd.x * side, y = a.y - d.y * back + up.y * upk + sd.y * side,
               z = a.z - d.z * back + up.z * upk + sd.z * side }, c
    end
  end
  line_cam(Tc, D, 4.0, 2.2, 1.6)
  wait(1.2)
  local hp0 = D.partHp and D.partHp(tankUid)
  local ok, why = LT.fireTurret(Tc, s.uid)
  wait_for(function() return LT.lastShot ~= nil end, 3, "the turret's pulse")
  wait(0.25)
  LZP.shot("t1_turret_pulse_side")
  local r = LT.lastShot
  P("LZ TURRET SHOT: %s · %.0f kJ at %.1f m → %s %s · spot %.3f m · F %.3g · amount %s hp %s → %s", tostring(ok and "fired" or why), r and r.E / 1e3 or -1, r and r.R or -1,
    r and r.kind or "-", r and r.hit and tostring(r.hit.label) or "-", r and r.d or -1, r and r.F or -1, tostring(r and r.hit and r.hit.amount), tostring(hp0), tostring(r and r.hit and r.hit.hp))
  LZP.check("tbreak", r and r.kind == "part" and r.hit.cls == "tank" and (r.hit.amount or 0) >= 0.999, "the turret's %.0f kJ pulse (0.92 × 0.30 × 0.5 MJ) burns through the tank: class %s, amount %s",
    r and r.E / 1e3 or -1, r and r.hit and r.hit.cls or "-", tostring(r and r.hit and r.hit.amount))
  line_cam(D, Tc, -3.0, 2.0, 3.0)
  wait(0.8)
  LZP.shot("t2_derelict_after")
  -- 3. AUTO on the derelict's pod: it fires by itself once on target and charged
  local podUid = nil
  for u, d in pairs(D.aboardRecs and D.aboardRecs() or {}) do if d.kind == "crewed" or d.id == "pod" then podUid = u end end
  -- (the tank's chain reaction may have taken the pod: then whatever is left of the derelict)
  if not podUid then for u in pairs(D.aboardRecs and D.node and D.node.valid and D.aboardRecs() or {}) do podUid = podUid or u end end
  if podUid then
    TG.targetPart(D, podUid)
    LT.setTurretCharge(Tc, s.uid, 1)
    s.cd = 0
    local before = LT.PROF.shots
    LT.auto(Tc, s.uid, true)
    local fired = wait_for(function() return LT.PROF.shots > before end, 15, "AUTO")
    local r2 = LT.lastShot
    LZP.check("auto", fired ~= nil, "AUTO fired by itself on the pod: %s %s amount %s", r2 and r2.kind or "-", r2 and r2.hit and tostring(r2.hit.label) or "-", tostring(r2 and r2.hit and r2.hit.amount))
    line_cam(Tc, D, 3.0, 1.2, -2.0)
    wait(0.3)
    LZP.shot("t3_auto_other_angle")
    LT.auto(Tc, s.uid, false)
  else
    LZP.check("auto", false, "the derelict has no pod left to aim at")
  end
  -- 4. the kit laser on what is left of the derelict
  local engUid = nil
  for u, d in pairs(D.aboardRecs and D.aboardRecs() or {}) do if d.id == "engineS" then engUid = u end end
  local w = LZ.weaponOf(sid, U.dir)
  if w and engUid and D.node and D.node.valid then
    TG.targetPart(D, engUid)
    LZ.setCharge(sid, U.dir, 1)
    LZ.setArm(sid, U.dir, true)
    LZ.PULSE_SHOW = 2.5
    local onw = LZP.aim(LZ, w, 25)
    LZP.cam(srec, { 5, 4, -4 }, { -3, 1, 28 })
    wait(1.0)
    local n0 = LZ.PROF.shots
    LZ.fire(sid, U.dir)
    wait_for(function() return LZ.PROF.shots > n0 end, 3, "the post's pulse")
    wait(0.25)
    LZP.shot("t4_kit_laser_on_wreck")
    local r3 = LZ.lastShot
    LZP.check("kitcraft", onw and r3 and r3.kind == "part", "the kit laser on the wreck's engine: %s %s amount %s (class %s)", r3 and r3.kind or "-", r3 and r3.hit and tostring(r3.hit.label) or "-",
      tostring(r3 and r3.hit and r3.hit.amount), r3 and r3.hit and tostring(r3.hit.cls) or "-")
  else
    P("LZ NOTE: no engine left on the derelict for the kit laser (%s)", tostring(engUid))
  end
  VP.cam_off()
  LT.arm(Tc, s.uid, false)
  local idle1 = LZP.cost("turret built, disarmed", 3)
  P("LZ COSTS turret: nothing %.4f · armed tracking %.4f · disarmed %.4f ms/frame (lasers + laser_turret)", idle0, armedC, idle1)
  LZP.result()
end
