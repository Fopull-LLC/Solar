-- ── kit probe, modes "interior" and "power" (sandbox plan S5) ────────────────
-- Spliced after charprobe_modes.lua (the KIT / CH helpers) by tools/perf/kitprobe.sh.
--   interior  a diagnostic of a hab's inside light (S5 polish): the hab built
--             and painted light, pictured inside with its lamp on, with it
--             off, and with every interior surface's sky reflection taken away;
--             each picture's mean colour logged (PW INSIDE …)
--   power     (below)
PW = {}

-- every node a structure's pieces draw (their Mesh, MeshIn, Door…)
function PW.nodesOf(ST, sid)
  local out = {}
  local rec = ST.get(sid)
  for _, p in ipairs(rec and rec.bp or {}) do
    local n = ST.nodeOf(sid, p.uid)
    if n then
      for _, nm in ipairs({ "Mesh", "MeshIn", "Door", "Door2" }) do
        local ok, c = pcall(n.getChild, n, nm)
        if ok and c then out[#out + 1] = c end
      end
    end
  end
  return out
end

function PW.lighting()
  local ln = find("Lighting")
  local l = ln and ln:getcomponent("Light")
  if not l then return "no Lighting" end
  return string.format("ambient %.3f %.3f %.3f · key %.2f %.2f %.2f ×%.2f", l.ambientR or -1, l.ambientG or -1, l.ambientB or -1,
    l.colorR or -1, l.colorG or -1, l.colorB or -1, l.intensity or -1)
end

function PW.run_interior()
  BK.tag = "interior"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local KL, KP = findScript("kit_live"), findScript("kit_paint")
  local spot = BK.flat_spot()
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local sid
  for _, o in ipairs({ { 7, 0 }, { 8, -2 }, { 9, 2 }, { 6, -4 }, { 10, 0 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab") then BK.result() return end
  local rec = ST.get(sid)
  CH.build(fb, ST, rec, sid)
  rec = ST.get(sid)
  KIT.tp(rec, 1, 9)
  paint_ray(fb, rec, { 1.6, 1.0, -4 }, { 1.6, 1.0, 0 }, "hull", "kind")
  for _, a in ipairs({ { { 0, 1.2, 1 }, { 0, 1.2, -3 } }, { { 2, 1.2, 1 }, { 2, 1.2, -3 } }, { { 0.5, 1.2, 1 }, { 0.5, 1.2, 5 } },
                       { { 2, 0.6, 1 }, { 2, 0.6, 5 } }, { { 1, 0.6, 0 }, { -3, 0.6, 0 } }, { { 1, 1.2, 2 }, { -3, 1.2, 2 } },
                       { { 1, 1.2, 0 }, { 5, 1.2, 0 } }, { { 1, 1.2, 2 }, { 5, 1.2, 2 } } }) do
    paint_ray(fb, rec, a[1], a[2], "hull", nil)
  end
  paint_ray(fb, rec, { 0, 5, 0 }, { 0, 1, 0 }, "lightgrey", "kind")
  KIT.close(fb); wait(1.0)
  local FL = findScript("flora_field")
  if FL and FL.params then FL.params.enabled = 0 end
  wait(2)
  rec = ST.get(sid)
  P("PW INSIDE lighting: %s", PW.lighting())
  for _, e in pairs(KL.entries()) do
    if e.sid == sid and e.def.light then P("PW INSIDE lamp %s colour %.2f %.2f %.2f ×%.1f r %.0f", tostring(e.uid), e.def.light.color[1], e.def.light.color[2], e.def.light.color[3], e.def.light.intensity, e.def.light.range) end
  end
  CH.palette(fb, ST, rec)
  local eye, tgt = { 0.35, 1.65, 2.55 }, { 1.8, 0.9, -0.6 }
  KIT.view("i0_lamp_on", rec, eye, tgt)
  KL.setLights(sid, false); wait(1.0)
  KIT.view("i1_lamp_off", rec, eye, tgt)
  KL.setLights(sid, true); wait(1.0)
  local nodes = PW.nodesOf(ST, sid)
  for _, n in ipairs(nodes) do pcall(n.setMaterial, n, { reflectivity = 0 }) end
  wait(1.0)
  KIT.view("i2_no_sky_reflection", rec, eye, tgt)
  local c = perf.counts and perf.counts() or {}
  P("PW INSIDE counts with reflectivity 0 on %d nodes: draws %s unbatched %s", #nodes, tostring(c.draws), tostring(c.unbatched))
  for _, n in ipairs(nodes) do pcall(n.setTint, n, { ambient = 0 }) end
  wait(1.0)
  KIT.view("i3_no_ambient_either", rec, eye, tgt)
  KL.setLights(sid, false); wait(1.0)
  KIT.view("i4_dark", rec, eye, tgt)
  BK.result()
end

-- ── mode "power" (S5: power networks II and the polish) ─────────────────────
--   1. base A: the S4 hab, built through the kit's own path and painted in
--      the new light swatches (hull white out, cream in, a safety-yellow door
--      wall, a light-grey roof), its name board and a plate by the door, a
--      wall screen inside, a tower (Kestrel Flats), two Solar Arrays and a
--      Battery Bank beside it, a Transformer;
--   2. two Power Poles 40 and 80 m out; base B 1.1 km on (a tower, a
--      Transformer); an 11 kV line laid Transformer → pole → pole →
--      Transformer through base_cable.lay (the real settle); at base B a
--      plant 170 m from its tower (outside its 150 m), fed by a 35 mm² cable
--      through a 63 A Breaker Panel, O2 generators added until the breaker
--      trips; reset (it trips again); the load cut and reset (it holds);
--   3. the POWER overlay at both bases and over the line, two angles each;
--      the cable menu's load line; the wall screen's and the station card's
--      network lines;
--   4. the hab's inside (the neutral lamp, the cream paint) and the plate and
--      the board read from 8 m; the palette board in sun;
--   5. three networks, 40 cables and 10 breakers by records 400 m off: the
--      rebuild, the 2 s step, the scripts' ms with the overlay off and on;
--   6. save and reload: the breaker's trip, the cables' types, the losses.
-- `BK PASS|FAIL`, `PW …` lines, `BK RESULT power: PASS/FAIL`.

-- a picture with the draws (the overlay's lines and labels) and the UI
function PW.shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time)
    else P("BK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("BK capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end
-- a fixed picture, eye and target structure-local, with the overlay drawn
function PW.view(nm, rec, eye, tgt)
  local b = home()
  local e, t = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(e, b), sub(t, b))
  wait(1.4)
  PW.shot(nm)
  VP.cam_off()
  wait(0.3)
end
-- a ground point `d` m along the spot's forward and `side` m right (body-relative), its up and forward
function PW.ground(spot, d, side)
  local b = home()
  local R = spot.r
  local dir = dir_at(spot.dir, unit(sub(spot.t, scl(spot.dir, dot(spot.t, spot.dir)))), d, R)
  local tt = unit(sub(spot.t, scl(dir, dot(spot.t, dir))))
  if side and side ~= 0 then
    local s = unit(cross(dir, tt))
    dir = unit({ x = dir.x * R + s.x * side, y = dir.y * R + s.y * side, z = dir.z * R + s.z * side })
    tt = unit(sub(tt, scl(dir, dot(tt, dir))))
  end
  local g = ground_r(b, dir.x, dir.y, dir.z, R + 200) or R
  return { x = dir.x * g, y = dir.y * g, z = dir.z * g }, dir, tt
end
-- a structure founded by records at a ground point
function PW.found(ST, spot, d, side, partId, name)
  local p, U, F = PW.ground(spot, d, side)
  local rec = ST.newRecord(nil, home().name, p.x, p.y, p.z, U, F, partId, { name = name })
  local id = ST.add(rec)
  ST.spawnNow(id)
  return id
end
-- a cable by records, settled on the real ground (base_cable.lay's own steps, no bill)
function PW.cable(CB, a, z, ty)
  local b = home()
  local rec0 = { b = b.name, a = a, z = z, ty = ty }
  local E = CB.ends(rec0)
  if not E then return nil end
  local _, _, d = CB.span({ x = E.tax, y = E.tay, z = E.taz }, { x = E.tzx, y = E.tzy, z = E.tzz }, b.radius, 1)
  local L = d + 2 * CB.HANG + 1.2
  local h = CB.sampleGround(b, E, b.radius, CB.groundStep(L))
  return CB.add({ b = b.name, a = a, z = z, ty = ty, len = L, h = h, v = 2, paid = { cost = 1, ship = 0, total = 1, t = 0 } })
end

function PW.run()
  BK.tag = "power"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  local KP, KL, BS, BT = findScript("kit_paint"), findScript("kit_live"), findScript("bases"), findScript("base_tower")
  local BG, CB, BPw = findScript("base_grid"), findScript("base_cable"), findScript("base_power")
  if not BK.check("scene", fb and ST and BG and CB and BPw and BPw.network and BG.cableFlow, "base_grid, base_cable and base_power in the scene") then BK.result() return end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local Uu = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(Uu, dot(f, Uu))))
    spot.t = BK.F
    local a, b = astro(), home()
    spot.dir = unit(sub(a, b))
    spot.r = len(a.x - b.x, a.y - b.y, a.z - b.z) - 1.0
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local cp = findScript("catalog_panel")
  local pl = cp and cp.listFor and cp.listFor(fb, "POWER", "") or {}
  P("PW the POWER tab: %d cards", #pl)
  -- ── 1. base A ──
  local sid, why
  for _, o in ipairs({ { 7, 0 }, { 8, -2 }, { 9, 2 }, { 6, -4 }, { 10, 0 }, { 8, 3 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  local walls = CH.build(fb, ST, rec, sid)
  rec = ST.get(sid)
  local bidA
  do
    ST.addPart(sid, { id = "tower", x = 6.5, y = 0, z = -1.5, yaw = 0 })
    ST.addPart(sid, { id = "batteryBank", x = -3.2, y = 0, z = -1.0, yaw = 0 })
    ST.addPart(sid, { id = "solarArray", x = 9.5, y = 0, z = 4.0, yaw = 0 })
    ST.addPart(sid, { id = "solarArray", x = 9.5, y = 0, z = 9.0, yaw = 0 })
    ST.spawnNow(sid)
    wait(2.5)
    local b = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
    if b then BS.rename(b.id, "Kestrel Flats"); bidA = b.id end
    if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
    BK.check("baseA", bidA ~= nil, "base A is %s", b and tostring(b.n) or "none")
  end
  KIT.tp(rec, 1, 9)
  -- the new light swatches through the paint tool's own functions
  paint_ray(fb, rec, { 1.6, 1.0, -4 }, { 1.6, 1.0, 0 }, "hull", "kind")
  paint_ray(fb, rec, { 2.0, 1.2, 6 }, { 2.0, 1.2, 0 }, "hull", nil)
  paint_ray(fb, rec, { -3.5, 0.6, 0 }, { 0, 0.6, 0 }, "hull", nil)
  paint_ray(fb, rec, { 0.6, 1.2, 6 }, { 0.6, 1.2, 0 }, "safety", nil)
  for _, a in ipairs({ { { 0, 1.2, 1 }, { 0, 1.2, -3 } }, { { 2, 1.2, 1 }, { 2, 1.2, -3 } }, { { 0.5, 1.2, 1 }, { 0.5, 1.2, 5 } },
                       { { 2, 0.6, 1 }, { 2, 0.6, 5 } }, { { 1, 0.6, 0 }, { -3, 0.6, 0 } }, { { 1, 1.2, 2 }, { -3, 1.2, 2 } },
                       { { 1, 1.2, 0 }, { 5, 1.2, 0 } }, { { 1, 1.2, 2 }, { 5, 1.2, 2 } } }) do
    paint_ray(fb, rec, a[1], a[2], "bone", nil)
  end
  paint_ray(fb, rec, { 0, 5, 0 }, { 0, 1, 0 }, "lightgrey", "kind")
  rec = ST.get(sid)
  local np, nin = 0, 0
  for _, p in ipairs(rec.bp) do if p.paint then np = np + 1 end if p.paintIn then nin = nin + 1 end end
  BK.check("painted", np >= 12 and nin >= 6, "painted in the light swatches: %d pieces outside, %d insides", np, nin)
  -- signs, the screen, the power gear
  local sgB = put(fb, rec, "signBoard.steel", { 4.2, 1.85, 0.9 }, { 2.0, 1.85, 0.9 }, "the base's name board", 0)
  local sgP = put(fb, rec, "signPlate.steel", { 0.55, 1.5, 5 }, { 0.55, 1.5, 0 }, "a plate by the door", 0)
  if sgP then KL.setSignWords(sid, sgP, "HAB 1 · CREW 2") end
  local scr = put(fb, rec, "wallScreen.steel", { 1.0, 1.45, 1 }, { 1.0, 1.45, -3 }, "a wall screen inside", 0)
  local brkA = put(fb, rec, "breaker63.steel", { 4.2, 1.3, 2.0 }, { 2.0, 1.3, 2.0 }, "a breaker on the side wall", 0)
  local xA = ST.addPart(sid, { id = "transformer.steel", x = -3.4, y = 0, z = 2.6, yaw = 0 })
  ST.spawnNow(sid)
  fb.dropHeld()
  wait(1.5)
  rec = ST.get(sid)
  BK.check("gearA", xA ~= nil and sgB and sgP and scr, "base A: the transformer (uid %s), the signs, the screen, the breaker (%s)", tostring(xA), tostring(brkA))
  -- ── 2. the line ──
  -- (the hab's frame: the poles stand on along its +Z, out of its front, 40 and 80 m)
  local fr = findScript("kit_snap").frameOf(rec)
  local spotA = { dir = unit(fr.O), r = len(fr.O.x, fr.O.y, fr.O.z), t = fr.F }
  spotA.dir = unit(fr.O)
  local p1 = PW.found(ST, spotA, 40, -3.4, "powerPole.steel", "pole 1")
  local p2 = PW.found(ST, spotA, 80, -3.4, "powerPole.concrete", "pole 2")
  local tB = PW.found(ST, spotA, 1100, 0, "tower", "Leeward tower")
  wait(2.5)
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  local recB = ST.get(tB)
  local bB = BS.baseAt(recB.b, recB.x, recB.y, recB.z)
  if bB then BS.rename(bB.id, "Leeward") end
  local xB = ST.addPart(tB, { id = "transformer.steel", x = -3, y = 0, z = -2, yaw = 0 })
  ST.spawnNow(tB)
  BK.check("baseB", bB ~= nil and xB ~= nil, "base B 1.1 km on: %s, its transformer uid %s", bB and tostring(bB.n) or "none", tostring(xB))
  -- the 11 kV line: transformer A → pole 1 → pole 2 → transformer B, through lay() (validity, bill, settle)
  local f0 = co.balance()
  local c1, w1 = CB.lay({ sid = sid, uid = xA }, { sid = p1, uid = 1 }, { ty = "hv35", noHistory = true })
  local c2, w2 = CB.lay({ sid = p1, uid = 1 }, { sid = p2, uid = 1 }, { ty = "hv35", noHistory = true })
  local c3, w3 = CB.lay({ sid = p2, uid = 1 }, { sid = tB, uid = xB }, { ty = "hv35", noHistory = true })
  P("PW the 11 kV line: %s (%s) · %s (%s) · %s (%s) · $%d", tostring(c1), tostring(w1), tostring(c2), tostring(w2), tostring(c3), tostring(w3), f0 - co.balance())
  BK.check("hv_laid", c1 and c2 and c3, "the 11 kV line laid in three runs (%.0f + %.0f + %.0f m)", c1 and CB.get(c1).len or -1, c2 and CB.get(c2).len or -1, c3 and CB.get(c3).len or -1)
  -- a 400 V cable refused on a transformer, an 11 kV one onto a battery
  do
    local v = CB.validity({ sid = p1, uid = 1, ty = "lv16" }, { rec = ST.get(sid), part = ST.getPart(sid, xA) }, rec.b, "lv16")
    BK.check("rule_xf", v.bad and v.bad:find("HV Cable", 1, true), "a 400 V cable on a transformer: %s", tostring(v.bad))
  end
  -- the plant at base B, 170 m past its tower: twelve O2 generators on a slab, a breaker on a wall
  KIT.tp(recB, 0, 168)
  wait(2.0)
  BK.F = unit(fr.F)
  tap("b"); wait(1.0)
  if not fb.isOpen() then tap("b"); wait(1.0) end
  local sP
  for _, o in ipairs({ { 4, 0 }, { 5, -2 }, { 6, 2 }, { 7, 0 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sP = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sP then break end
  end
  if not BK.check("plant", sP ~= nil, "the plant's slab at base B (structure %s)", tostring(sP)) then BK.result() return end
  local recP = ST.get(sP)
  KIT.put(fb, recP, "wall.steel", { 0, 3, -0.7 }, { 0, -2, -0.7 }, "the plant's wall")
  recP = ST.get(sP)
  local brkP = KIT.put(fb, recP, "breaker63.steel", { 0.2, 1.2, 1.5 }, { 0.2, 1.2, -3 }, "the plant's breaker")
  fb.dropHeld()
  local function gens(n)
    local r2 = ST.get(sP)
    local have = 0
    for _, p in ipairs(r2.bp) do if p.id == "o2gen.steel" then have = have + 1 end end
    for k = have + 1, n do
      local i, j = (k - 1) % 6, math.floor((k - 1) / 6)
      ST.addPart(sP, { id = "o2gen.steel", x = -2.5 + i * 1.0, y = 0, z = 2.5 + j * 0.9, yaw = 0 })
    end
    for k = have, n + 1, -1 do
      local r3 = ST.get(sP)
      for q = #r3.bp, 1, -1 do if r3.bp[q].id == "o2gen.steel" then ST.removeParts(sP, { r3.bp[q].uid }) break end end
    end
    ST.spawnNow(sP)
  end
  gens(12)
  local c4 = CB.lay({ sid = tB, uid = 1 }, { sid = sP, uid = brkP }, { ty = "lv35", noHistory = true })
  BK.check("lv_laid", c4 ~= nil, "the plant fed by a 35 mm² cable through its breaker (%s)", tostring(c4))
  wait(2.5)
  local pA = BT.power(bidA)
  local pB = BT.power(bB.id)
  local fl3, fl4 = BG.cableFlow(c3), BG.cableFlow(c4)
  P("PW GRID A: in %.2f out %.2f loss %.3f kW · stored %.0f/%.0f · limited %s · grid %s", pA.supply, pA.need, pA.loss or 0, pA.stored, pA.cap, tostring(pA.limited), tostring(pA.grid))
  P("PW line: c3 %.2f kW (%.0f %%, loss %.4f kW) · plant feed %.2f kW (%.0f %%)", fl3 and fl3.P or -1, (fl3 and fl3.share or 0) * 100, fl3 and fl3.loss or -1,
    fl4 and fl4.P or -1, (fl4 and fl4.share or 0) * 100)
  BK.check("one_grid", pA.grid == pB.grid and fl3 and not fl3.dead and math.abs(fl3.P) > 15, "one grid over 1.1 km of 11 kV: %.1f kW down the line", fl3 and math.abs(fl3.P) or -1)
  local xfl = BG.partFlow(sid, xA)
  BK.check("hv_loss", (pA.loss or 0) < 1.5 and (fl3.loss or 1) < 0.01, "the line loses %.1f W; the two transformers %.2f kW in all", (fl3.loss or 0) * 1000, (pA.loss or 0))
  -- what the same would lose at 400 V (the cure the transformers are)
  P("PW the same %.1f kW over the same %.0f m at 400 V on 95 mm² would lose %.1f %%", math.abs(fl3.P), CB.get(c3).len, 100 * BPw.lossShare(math.abs(fl3.P), "lv95", CB.get(c3).len))
  -- ── 3. overload: six more generators, the breaker trips ──
  BPw.overlay, BPw.overlayAlways = true, true
  local trips0 = BG.trips
  gens(18)
  wait(2.5)
  BT.power(bidA)
  local stP = BPw.breakerState(sP, brkP)
  local ff = BG.cableFlow(c4)
  local lt = BPw.lastTrips[#BPw.lastTrips]
  BK.check("trip", stP == "tripped" and BG.trips > trips0 and ff and ff.dead, "18 O2 generators (27 kW + the plant): the 63 A breaker trips (%s; %s), the feed dead",
    stP, lt and string.format("%.1f kW of %.1f", lt.kW, lt.rating) or "-")
  BK.check("split", BG.gridOfStruct(sP) ~= BG.gridOfStruct(tB), "...and the plant is off base B's grid")
  KIT.close(fb); wait(1.0)
  local FL = findScript("flora_field")
  if FL and FL.params then FL.params.enabled = 0 end
  wait(1.0)
  recP = ST.get(sP)
  PW.view("p3_plant_tripped", recP, { 6, 4.5, 9 }, { 0, 0.8, 1.5 })
  PW.view("p3b_plant_tripped_side", recP, { -8, 3.5, 4 }, { 0, 0.8, 0.5 })
  -- the menu on the breaker: its state and the reset
  local bn = ST.nodeOf(sP, brkP)
  local items = KIT.menu(bn)
  local hasReset = false
  for _, it in ipairs(items) do if tostring(it.id):find("bp_reset", 1, true) then hasReset = true end P("PW menu: %s %s", tostring(it.id), tostring(it.label)) end
  BK.check("menu", hasReset, "the breaker's menu offers the reset")
  BPw.setBreaker(sP, brkP, true, "hand"); wait(2.5); BT.power(bidA)
  BK.check("retrip", BPw.breakerState(sP, brkP) == "tripped", "reset with the load still on: it trips again")
  gens(13)
  BPw.setBreaker(sP, brkP, true, "hand"); wait(2.5); BT.power(bidA)
  local ff2 = BG.cableFlow(c4)
  BK.check("holds", BPw.breakerState(sP, brkP) == "closed" and ff2 and not ff2.dead, "thirteen generators, reset: it holds (%.1f kW, %d %%)", ff2 and ff2.P or -1, math.floor((ff2 and ff2.share or 0) * 100))
  PW.view("p4_plant_holding", recP, { 6, 4.5, 9 }, { 0, 0.8, 1.5 })
  -- the overlay at base A and along the line, two angles (the crew back
  -- home: the lamps and the overlay's labels are pooled near them)
  rec = ST.get(sid)
  KIT.tp(rec, 1, 9)
  wait(2.0)
  local pole1 = ST.get(p1)
  PW.view("p1_baseA_overlay", rec, { -14, 9, -10 }, { -2, 2, 30 })
  PW.view("p1b_baseA_overlay_side", rec, { 18, 7, 24 }, { -3, 3, 40 })
  PW.view("p2_poles", pole1, { 12, 5, -8 }, { 0, 6, 20 })
  PW.view("p2b_poles_under", pole1, { -6, 1.7, 6 }, { 0, 7.5, 30 })
  PW.view("p5_line_high", rec, { -60, 120, -40 }, { 0, 0, 450 })
  KIT.cost("power, overlay on", 3)
  local d0 = BPw.drawn
  P("PW overlay drew %d lines, %d arrows, %d labels", d0.lines or 0, d0.arrows or 0, d0.labels or 0)
  BK.check("overlay", (d0.lines or 0) > 20 and (d0.labels or 0) >= 3, "the overlay draws the runs (%d lines, %d arrows, %d labels)", d0.lines or 0, d0.arrows or 0, d0.labels or 0)
  -- the screen and the station card's lines
  local sl = KL.screenLines(sid)
  local st = {}
  for _, l in ipairs(sl.lines) do st[#st + 1] = l[1] end
  P("PW SCREEN %s | %s", sl.title, table.concat(st, " | "))
  BK.check("screen", table.concat(st, " "):find("LOSSES", 1, true) ~= nil, "the wall screen shows the network's losses")
  -- ── 4. inside, the signs, the palette ──
  BPw.overlayAlways = false
  wait(0.5)
  KIT.view("p6_inside", rec, { 0.35, 1.65, 2.55 }, { 1.8, 0.9, -0.6 })
  KIT.view("p6b_inside_screen", rec, { 1.6, 1.6, 2.4 }, { 1.0, 1.4, -0.6 })
  -- the plate on the front wall, read from 8 m straight on, and the board from 8 m
  if sgP then
    local p = ST.getPart(sid, sgP)
    local ly = (p.y or 1.45)
    KIT.view("p7_plate_8m", rec, { p.x, ly + 0.1, p.z + 8 }, { p.x, ly, p.z })
    local e = KL.entries()[tostring(sid) .. ":" .. tostring(sgP)]
    local L = e and e.layout
    if L then
      local capm = L.size * 0.7 / L.H * 0.4
      P("PW plate: %d line(s) %q, size %.0f px of %d → capitals %.3f m; plate %.0f %% of its width", #L.lines, table.concat(L.lines, " / "), L.size, L.H, capm, L.f * 100)
      BK.check("plate_big", capm >= 0.1, "the plate's capitals %.0f mm tall (8 m: about %.1f° of view)", capm * 1000, math.deg(capm / 8))
    end
  end
  if sgB then
    local p = ST.getPart(sid, sgB)
    KIT.view("p7b_board_8m", rec, { p.x + 8, (p.y or 1.85) + 0.2, p.z }, { p.x, p.y or 1.85, p.z })
  end
  tap("b"); wait(1.0)
  if not fb.isOpen() then tap("b"); wait(1.0) end
  CH.palette(fb, ST, rec)
  KIT.close(fb); wait(0.5)
  -- ── 5. 3 networks, 40 cables, 10 breakers ──
  do
    local w0 = app and app.wallClock and app.wallClock()
    local nb, nc = 0, 0
    local ids = {}
    for n = 1, 3 do
      local prev
      for k = 1, 13 do
        local part = (k == 1) and "isotopeSkid" or ((k == 2) and "batteryBank" or "o2gen.steel")
        local s2 = PW.found(ST, spotA, 300 + k * 22, -120 + n * 60, part, "perf " .. n .. "." .. k)
        ids[#ids + 1] = s2
        local uid = 1
        if k % 4 == 0 and nb < 9 then uid = ST.addPart(s2, { id = "breaker160.steel", x = 1, y = 0.2, z = 0, pitch = -math.pi / 2 }); nb = nb + 1 end
        if prev then if PW.cable(CB, { sid = prev, uid = 1 }, { sid = s2, uid = uid }, "lv95") then nc = nc + 1 end end
        prev = s2
      end
    end
    -- four ties between the networks, each through an open breaker (they stay three)
    for k = 1, 4 do
      local a, z = ids[13 * ((k - 1) % 2) + 13], ids[13 * ((k - 1) % 2) + 14]
      local bk = ST.addPart(z, { id = "breaker63.steel", x = -1, y = 0.2, z = 0, pitch = -math.pi / 2 })
      if k == 1 then nb = nb + 1 end
      BPw.setBreaker(z, bk, false, "hand")
      if PW.cable(CB, { sid = a, uid = 1 }, { sid = z, uid = bk }, "lv35") then nc = nc + 1 end
    end
    wait(3)
    BG.rebuildNow()
    local P0 = BG.PROF
    local nets = 0
    for _, g in ipairs(BG.grids()) do local M = BG.model(g.id); if M.net and #M.net.edges >= 10 then nets = nets + 1 end end
    P("PW PERF the perf base: %d networks of 10+ cables, %d cables, %d breakers · rebuild %.2f ms (topology %.2f) · advance %.3f ms",
      nets, nc, nb, P0.rebuild_ms or -1, P0.topo_ms or -1, P0.advance_ms or -1)
    BK.check("perf_nets", nets >= 3 and nc >= 40 and nb >= 10, "%d networks, %d cables, %d breakers", nets, nc, nb)
    -- the scripts' cost with it idle, the overlay off and on (camera over it)
    local eye, tgt = KIT.w(rec, -170, 110, 330), KIT.w(rec, 0, 0, 440)
    local b = home()
    VP.cam_fixed(sub(eye, b), sub(tgt, b))
    local function ms(tag)
      wait(1)
      local fr0 = FRAME
      sc_begin(tag); wait(5); sc_end(tag)
      P("PW PERF %s: base_grid %.4f, base_power %.4f, base_cable %.4f, kit_live %.4f ms/frame (%d frames) · grid rebuilds %d advances %d",
        tag, perf.scriptMs("base_grid") or -1, perf.scriptMs("base_power") or -1, perf.scriptMs("base_cable") or -1, perf.scriptMs("kit_live") or -1,
        FRAME - fr0, BG.PROF.n_rebuild or -1, BG.PROF.n_advance or -1)
      return perf.scriptMs("base_grid") or 0, perf.scriptMs("base_power") or 0
    end
    BPw.overlayAlways = false
    local g1, p1ms = ms("power_idle")
    BPw.overlayAlways = true
    local g2, p2ms = ms("power_overlay")
    PW.shot("p8_perf_overlay")
    VP.cam_off()
    BPw.overlayAlways = false
    BK.check("perf_ms", g1 + p1ms < 0.25, "idle: base_grid + base_power %.3f ms a frame (solves on change and the 2 s clock only); with the overlay %.3f", g1 + p1ms, g2 + p2ms)
    for _, id in ipairs(ids) do for _, c in ipairs(CB.at(id)) do CB.remove(c.id) end end
    for _, id in ipairs(ids) do ST.remove(id) end
    wait(2)
  end
  -- ── 6. save and reload (one breaker tripped to carry over) ──
  gens(18); wait(2.5); BT.power(bidA)
  local lossA = BT.power(bidA).loss or 0
  BK.check("tripped_again", BPw.breakerState(sP, brkP) == "tripped", "the plant's breaker tripped for the save")
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(5)
  ST, BG, CB, BPw, BT = findScript("structures"), findScript("base_grid"), findScript("base_cable"), findScript("base_power"), findScript("base_tower")
  local pA2 = BT.power(bidA)
  BK.check("reload", BPw.breakerState(sP, brkP) == "tripped" and CB.get(c1) and CB.get(c1).ty == "hv35" and CB.get(c4).ty == "lv35"
    and math.abs((pA2.loss or 0) - lossA) < 0.05,
    "after a reload: the breaker still tripped, the line 11 kV and the feed 35 mm², losses %.3f kW (were %.3f)", pA2.loss or 0, lossA)
  if FL and FL.params then FL.params.enabled = 0 end
  BPw.overlay, BPw.overlayAlways = true, true
  wait(2)
  rec = ST.get(sid)
  PW.view("p9_after_reload", rec, { -14, 9, -10 }, { -2, 2, 30 })
  BK.result()
end
