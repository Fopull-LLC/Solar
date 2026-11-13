-- ── the hands-on base loop, in the kit probe (work/baseloop/DESIGN.md) ───────
-- Spliced after the other kit modes by tools/perf/baseloopkit.sh.
--   wired   (W2, playtest 11-12b: "nothing should be part of the grid
--           automatically") a hab built through the kit, a tower, a Battery
--           Bank and two Solar Arrays set beside it: nothing has power (the
--           tower dark, the lights dark, every terminal tagged NO CABLE with a
--           drum in hand); then cabled one run at a time through
--           base_cable.lay (array → bank, bank → tower, bank → the hab's
--           wall, a second array 45 m out): what comes alive at each step,
--           the POWER overlay from two angles, a part's own line, the
--           refusals; save and reload.
-- `BK PASS|FAIL`, `BL …` lines, `BK RESULT wired: PASS/FAIL`.
BL = {}

function BL.setup()
  wait_ready(120)
  wait(2)
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then return nil end
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
  local C = findScript("crew")
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  return spot
end

function BL.run_wired()
  BK.tag = "wired"
  local spot = BL.setup()
  if not spot then BK.result() return end
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  local KL, BS, BT = findScript("kit_live"), findScript("bases"), findScript("base_tower")
  local BG, CB, BPw, PI = findScript("base_grid"), findScript("base_cable"), findScript("base_power"), findScript("part_info")
  if not BK.check("scene", fb and ST and BG and CB and BPw and BG.wiring and BG.WIRED == true, "the wiring rule is in the scene (grid.wv %s)", tostring(save.get("grid.wv"))) then BK.result() return end
  tap("b"); wait(1.5)
  -- ── 1. the hab, the tower, the bank and an array, set down and NOT cabled ──
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
  CH.build(fb, ST, rec, sid)
  rec = ST.get(sid)
  local uT = ST.addPart(sid, { id = "tower", x = 6.5, y = 0, z = -1.5, yaw = 0 })
  local uB = ST.addPart(sid, { id = "batteryBank", x = -3.4, y = 0, z = 3.0, yaw = 0 })
  local uA = ST.addPart(sid, { id = "solarArray", x = -4.0, y = 0, z = 9.0, yaw = 0 })
  ST.spawnNow(sid)
  wait(2.5)
  local base = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  if not BK.check("base", base ~= nil and not rec.aw, "the tower founds a base (%s); the structure is under the wiring rule (aw %s)", base and tostring(base.n) or "none", tostring(rec.aw)) then BK.result() return end
  local bid = base.id
  fb.dropHeld()
  BG.rebuildNow(); wait(1.0)
  rec = ST.get(sid)
  local lamp, wallU = nil, nil
  for _, p in ipairs(rec.bp) do
    local d = fb.partInfo(p.id)
    if d and d.light and not lamp then lamp = p.uid end
    if d and d.snap == "wall" and not wallU then wallU = p.uid end
  end
  local tp = BT.power(bid)
  local lit0 = 0
  for k in pairs(KL.lit()) do lit0 = lit0 + 1 end
  P("BL unwired: tower powered %s (supply %.2f), lamp %s served %s, lights lit %d, circuit dead %s", tostring(tp.powered), tp.supply or -1,
    tostring(lamp), tostring(lamp and BG.partServed(sid, lamp)), lit0, tostring(BG.circuitDead(sid)))
  BK.check("dark", tp.powered == false and BG.circuitDead(sid) == true and lit0 == 0 and (lamp == nil or BG.partServed(sid, lamp) ~= true),
    "an array, a bank and a tower beside the hab, no cables: the tower has no power and the hab's lights are dark")
  local wA, wB, wT = BG.wiring(sid, uA), BG.wiring(sid, uB), BG.wiring(sid, uT)
  BK.check("islands", wA.cables == 0 and wB.cables == 0 and wT.cables == 0 and BG.gridOfStruct(sid, uA) ~= BG.gridOfStruct(sid, uB),
    "the array, the bank and the tower are three islands")
  P("BL lines: array '%s' · bank '%s' · tower '%s' · lamp '%s'", tostring(BG.wireWhy(sid, uA)), tostring(BG.wireWhy(sid, uB)), tostring(BG.wireWhy(sid, uT)),
    tostring(lamp and BG.powerWhy(sid, lamp)))
  BK.check("why", (BG.wireWhy(sid, uA) or ""):find("NOT WIRED", 1, true) ~= nil and (lamp == nil or (BG.powerWhy(sid, lamp) or ""):find("no cable reaches this building", 1, true) ~= nil),
    "each says why in its own line")
  -- the drum in hand: the terminals tag themselves
  KIT.tp(rec, -9, 14)
  wait(1.0)
  if not fb.isOpen() then tap("b"); wait(1.0) end
  fb.hold("flexLead"); wait(0.8)
  PW.view("w0_drum_in_hand_no_cables", rec, { -11, 5.5, 17 }, { 0, 0.8, 2 })
  local tags0 = BPw.drawn and BPw.drawn.tags or 0
  BK.check("tags", tags0 >= 4, "with a drum in hand the terminals are tagged (%d tags: the array, the bank, the tower, the building)", tags0)
  PW.view("w0b_other_side", rec, { 13, 5.0, -8 }, { 0, 0.8, 3 })
  -- ── 2. cabled, one run at a time ──
  local f0 = co.balance()
  local v = CB.validity({ sid = sid, uid = uA, ty = "lv2" }, { rec = rec, part = ST.getPart(sid, uB) }, rec.b, "lv2")
  P("BL hint: %s · %.1f m · $%s", tostring(v.joins), v.len or -1, tostring(v.quote and v.quote.total))
  BK.check("joins", v.bad == nil and (v.joins or ""):find("Solar Array", 1, true) ~= nil and (v.quote and v.quote.ship) == 0, "the hint names what the run joins, a flex lead has no shipping: %s", tostring(v.joins))
  local c1, w1 = CB.lay({ sid = sid, uid = uA }, { sid = sid, uid = uB }, { ty = "lv2" })
  BG.rebuildNow(); wait(1.2)
  BK.check("c1", c1 ~= nil and BG.gridOfStruct(sid, uA) == BG.gridOfStruct(sid, uB) and BT.power(bid).powered == false,
    "array → bank on a flex lead (%s, %.1f m, $%d): one grid of two, the tower still dark", tostring(w1 or c1), c1 and CB.get(c1).len or -1, f0 - co.balance())
  local c2, w2 = CB.lay({ sid = sid, uid = uB }, { sid = sid, uid = uT }, { ty = "lv16" })
  BG.rebuildNow(); wait(1.2)
  tp = BT.power(bid)
  BK.check("c2", c2 ~= nil and tp.powered == true and (tp.sources or 0) == 1, "bank → tower (%s): the tower is served (%.2f kW in, %d source)", tostring(w2 or c2), tp.supply or -1, tp.sources or -1)
  BK.check("still_dark", BG.circuitDead(sid) == true, "...and the hab is still dark: nobody cabled the building")
  PW.view("w1_tower_live_hab_dark", rec, { -11, 5.5, 17 }, { 0, 0.8, 2 })
  local same = CB.validity({ sid = sid, uid = lamp or wallU, ty = "lv2" }, { rec = rec, part = ST.getPart(sid, wallU) }, rec.b, "lv2")
  local loop = CB.validity({ sid = sid, uid = uA, ty = "lv2" }, { rec = rec, part = ST.getPart(sid, uT) }, rec.b, "lv2")
  BK.check("refusals", (same.bad or ""):find("same", 1, true) ~= nil and (loop.bad or ""):find("already on one grid", 1, true) ~= nil,
    "refused: two pieces of one building (%s); a second path with no gear (%s)", tostring(same.bad), tostring(loop.bad))
  local c3, w3 = CB.lay({ sid = sid, uid = uB }, { sid = sid, uid = wallU }, { ty = "lv16" })
  BG.rebuildNow(); wait(2.5)
  local lit1 = 0
  for k in pairs(KL.lit()) do lit1 = lit1 + 1 end
  BK.check("c3", c3 ~= nil and BG.circuitDead(sid) == false and (lamp == nil or BG.partServed(sid, lamp) == true) and lit1 > 0,
    "bank → a wall of the hab (%s): the building is live, %d light(s) on", tostring(w3 or c3), lit1)
  -- a second array 45 m out, its own structure, cabled back: the 40 m run has a use
  local sA2 = PW.found(ST, { dir = spot.dir, r = spot.r, t = spot.t }, 52, -8, "solarArray", "far array")
  wait(1.5)
  BG.rebuildNow(); wait(0.6)
  local sup0 = BT.power(bid).supply or 0
  local c4, w4 = CB.lay({ sid = sA2, uid = 1 }, { sid = sid, uid = uB }, { ty = "lv16" })
  BG.rebuildNow(); wait(1.5)
  local L4 = c4 and CB.get(c4).len or -1
  tp = BT.power(bid)
  local FT = findScript("feats")
  BK.check("c4", c4 ~= nil and L4 >= 40 and (tp.sources or 0) == 2 and FT.has("cable_laid") and FT.has("source_wired"),
    "an array %.0f m out cabled back (%s): %d sources on the grid (%.2f → %.2f kW), the 40 m feat and the source feat marked", L4, tostring(w4 or c4), tp.sources or -1, sup0, tp.supply or -1)
  P("BL grid: in %.2f out %.2f loss %.3f kW · stored %.0f/%.0f · %d cables · spent $%d", tp.supply, tp.need, tp.loss or 0, tp.stored, tp.cap, tp.cables or -1, f0 - co.balance())
  -- ── 3. the readouts ──
  fb.hold("flexLead"); wait(0.8)
  PW.view("w2_all_cabled_drum", rec, { -11, 5.5, 17 }, { 0, 0.8, 2 })
  BPw.overlay = true; BPw.overlayAlways = true
  wait(0.5)
  PW.view("w3_overlay", rec, { -11, 6.5, 19 }, { 0, 0.8, 2 })
  PW.view("w3b_overlay_other_side", rec, { 13, 5.0, -8 }, { 0, 0.8, 3 })
  local d = BPw.drawn or {}
  BK.check("overlay", (d.lines or 0) > 10 and (d.labels or 0) >= 4, "the POWER overlay: %d line segments, %d labels, %d arrows, %d tags", d.lines or 0, d.labels or 0, d.arrows or 0, d.tags or 0)
  BPw.overlay = false; BPw.overlayAlways = false
  fb.dropHeld()
  KIT.close(fb); wait(0.8)
  -- inside, the lamp on
  KIT.view("w4_inside_lit", rec, { 0.35, 1.65, 2.55 }, { 1.8, 0.9, -0.6 })
  -- the feed taken up: dark again
  CB.remove(c3)
  BG.rebuildNow(); wait(2.0)
  local lit2 = 0
  for k in pairs(KL.lit()) do lit2 = lit2 + 1 end
  KIT.view("w5_inside_feed_taken_up", rec, { 0.35, 1.65, 2.55 }, { 1.8, 0.9, -0.6 })
  BK.check("feed_up", BG.circuitDead(sid) == true and lit2 == 0 and BT.power(bid).powered == true, "the building's feed taken up: dark again (%d lit), the tower keeps its power", lit2)
  c3 = CB.lay({ sid = sid, uid = uB }, { sid = sid, uid = wallU }, { ty = "lv16" })
  BG.rebuildNow(); wait(1.0)
  -- ── 4. save and reload ──
  local n0 = #CB.list()
  if save.flush then save.flush() end
  CB.reloadFromSave(); wait(0.5)
  BG.rebuildNow(); wait(1.0)
  tp = BT.power(bid)
  BK.check("reload", #CB.list() == n0 and tp.powered == true and BG.circuitDead(sid) == false and tonumber(save.get("grid.wv")) == BG.WIRE_VERSION and ST.get(sid).aw == nil,
    "the records read back: %d cables, the tower served, the hab live, grid.wv %s", #CB.list(), tostring(save.get("grid.wv")))
  P("BL cost: rebuild %.2f ms, advance %.3f ms, %d grids", BG.PROF.rebuild_ms or -1, BG.PROF.advance_ms or -1, #BG.grids())
  BK.result()
end

--   ruin    (phases 3 and 4, playtest 11-12b: "no more Restore roof buttons …
--           repair the roof however you want, with any material. The game
--           only checks that the room is actually enclosed"; "pre-built and
--           abandoned bases must be built on the same grid") the ruin near
--           home, claimed by an Engineer: the tower's menu (Rooms, Take a
--           Build Kit, Build the base, no Restore), the kit taken, every gap
--           closed THROUGH THE KIT'S OWN AIM (a ray through the gap, the
--           vacant slot under it: field_builder.placeAt with this frame's
--           ray), roof panels in concrete on a steel camp; each new piece
--           measured against the design's own pose; the enclosure before
--           and after and the feat; then its power cabled (bank → tower,
--           arrays → bank, bank → the building); the builder opened on the
--           site from the tower and left with nothing changed.
function BL.aim_slot(fb, rec, s)
  -- this frame's ray from the crew's eyes to the slot's middle; the hit a
  -- little beyond it (the ground past the gap, the sky)
  local a, b = astro(), home()
  local up = unit(sub(a, b))
  local eye = { x = a.x + up.x * 1.6, y = a.y + up.y * 1.6, z = a.z + up.z * 1.6 }
  local c = KIT.w(rec, s.cx, s.cy, s.cz)
  local d = sub(c, eye)
  local L = len(d.x, d.y, d.z)
  d = scl(d, 1 / L)
  fb.aimRay = { ox = eye.x, oy = eye.y, oz = eye.z, dx = d.x, dy = d.y, dz = d.z, t = time, range = 60 }
  return { x = c.x + d.x * 0.5, y = c.y + d.y * 0.5, z = c.z + d.z * 0.5, nx = -d.x, ny = -d.y, nz = -d.z }, L
end

function BL.run_ruin()
  BK.tag = "ruin"
  wait_ready(120)
  wait(2)
  local RU, ST, C, inv, F, co = findScript("ruins"), findScript("structures"), findScript("crew"), findScript("inventory"), findScript("feats"), findScript("company")
  local fb, KS, BG, CB, BT, BS, RA = findScript("field_builder"), findScript("kit_snap"), findScript("base_grid"), findScript("base_cable"),
    findScript("base_tower"), findScript("bases"), findScript("room_air")
  if not BK.check("scene", RU and ST and fb and KS and KS.slots and RU.enclosure and BG and BG.wiring, "ruins.enclosure, kit_snap.slots and the wiring rule are in the scene") then BK.result() return end
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  local b = home()
  local s = RU.nearOf(b.name)
  if not BK.check("site", s ~= nil, "the ruin near home: %s (%s)", s and s.name or "none", s and s.kind or "-") then BK.result() return end
  wait_for(function() local e = RU.state(s.id); return e.g ~= nil end, 60, "the near site sited")
  wait_for(function() return RU.state(s.id).sid ~= nil end, 60, "the near site stamped")
  local e = RU.state(s.id)
  if not BK.check("stamped", e.sid ~= nil, "stamped as structure %s (%d pieces)", tostring(e.sid), e.n or 0) then BK.result() return end
  local sid = e.sid
  local rec = ST.get(sid)
  C.patch(C.activeId(), { role = "engineer" })
  KIT.tp(rec, 1, 7)
  wait(3.0)
  rec = ST.get(sid)
  BK.F = unit(sub(KIT.w(rec, 1, 0, 0), KIT.w(rec, 1, 0, 7)))
  BK.check("strict", rec.aw == nil, "a ruin stamped in a new game is under the wiring rule (aw %s)", tostring(rec.aw))
  local tower, bank, arrays, wallU = nil, nil, {}, nil
  for _, p in ipairs(rec.bp) do
    local d = fb.partInfo(p.id)
    if p.id == "tower" then tower = p end
    if p.id == "batteryBank" then bank = p end
    if p.id == "solarArray" then arrays[#arrays + 1] = p end
    if d and d.kit and d.snap == "wall" and not p.wr and not wallU then wallU = p.uid end
  end
  if not BK.check("yard", tower and bank and #arrays >= 1 and wallU, "its tower, its Battery Bank, %d Solar Arrays", #arrays) then BK.result() return end
  KIT.view("r0_ruin_as_found", rec, { 12, 9, 15 }, { 1.5, 1, -2 })
  KIT.view("r0b_as_found_other_side", rec, { -11, 8, -14 }, { 2, 1, -1 })
  -- ── 1. claimed: the menu ──
  local okc, whyc = RU.claim(s.id, { actor = { kind = "crew", id = "astro", pack = "astro" } })
  wait(2.0)
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  BK.check("claim", okc == true, "an Engineer claims it (%s)", tostring(whyc))
  local tn = ST.nodeOf(sid, tower.uid)
  local rows = tn and RU.providerFn({ node = tn }, { actor = { kind = "crew", id = "astro", pack = "astro" } }) or {}
  local has, restore = {}, 0
  for _, r in ipairs(rows) do has[r.id] = r; if tostring(r.id):find("ru_restore", 1, true) then restore = restore + 1 end end
  local rooms0 = has.ru_rooms and (type(has.ru_rooms.value) == "function" and has.ru_rooms.value() or has.ru_rooms.value) or "?"
  P("BL tower menu: %d rows · Rooms '%s' · kit row %s · build row %s · restore rows %d", #rows, tostring(rooms0), tostring(has.ru_kit ~= nil), tostring(has.ru_build ~= nil), restore)
  for i = 1, 3 do local r = has["ru_leak" .. i]; if r then P("BL   open room %d: %s", i, tostring(r.value)) end end
  BK.check("menu", has.ru_rooms and has.ru_build and has.ru_kit and restore == 0, "the claimed tower's menu: Rooms, Take a Build Kit, Build the base; no Restore row")
  local en0 = RU.enclosure(s.id)
  BK.check("open", en0 ~= nil and en0.need >= 1 and not en0.ok, "as found: %d of %d rooms hold air (%d rooms, %d leaking)", en0 and en0.sealed or -1, en0 and en0.need or -1, en0 and en0.rooms or -1, en0 and #en0.open or -1)
  -- ── 2. the kit, from the tower ──
  local kit0 = inv.itemCount("astro", "buildkit")
  local okk = has.ru_kit and has.ru_kit.act and has.ru_kit.act()
  wait(0.5)
  BK.check("kit", kit0 == 0 and okk and inv.itemCount("astro", "buildkit") == 1 and fb.kitUnlocked(), "no kit before (%d); the tower hands one over, and its research is open", kit0)
  tap("b"); wait(1.5)
  if not fb.isOpen() then tap("b"); wait(1.5) end
  BK.check("kit_open", fb.isOpen(), "B opens the kit at the ruin (gate %s)", tostring(fb.gate))
  -- ── 3. every gap closed through the kit's aim ──
  local full = RU.blueprintOf(s)
  local miss0 = RU.missing(full, rec.bp)
  local f0 = co.balance()
  -- what leans is righted first (the Repair Kit's job; a leaning wall seals nothing)
  local righted = 0
  for _, p in ipairs(ST.get(sid).bp) do
    local d = fb.partInfo(p.id)
    if p.wr and d and d.kit and (d.snap == "wall" or d.snap == "floor") then if RU.repairPiece(sid, p.uid) then righted = righted + 1 end end
  end
  wait(1.0)
  -- a window broken to an open frame lets the air through: taken down with the
  -- kit (deconstruct), its place is a vacant slot like any other gap
  local frames = 0
  for _, p in ipairs(ST.get(sid).bp) do
    if p.id == "openFrame.steel" then
      miss0[#miss0 + 1] = { ri = 0, piece = { id = "wall.steel", x = p.x, y = p.y, z = p.z, yaw = p.yaw } }
      local okd = fb.deconstruct(sid, p.uid)
      if okd then frames = frames + 1 end
    end
  end
  wait(1.0)
  P("BL open frames taken down with the kit: %d", frames)
  local placed, worst, tried, whyLast = { wall = 0, floor = 0 }, 0, 0, nil
  local function design_err(kind, lx, ly, lz)
    -- (against the whole design: a roof panel that came down with a frame
    -- goes back where the design had one, like a piece the decay took)
    local best = 1e9
    for _, pc in ipairs(full) do
      local dd = fb.partInfo(pc.id)
      if dd and dd.snap == kind then
        local d = math.sqrt((pc.x - lx) ^ 2 + (pc.y - ly) ^ 2 + (pc.z - lz) ^ 2)
        if d < best then best = d end
      end
    end
    return best
  end
  local offgrid = 0
  for pass = 1, 40 do
    local did = false
    for _, job in ipairs({ { "wall.steel", "wall" }, { "floor.concrete", "floor" } }) do
      rec = ST.get(sid)
      local list = KS.slots(rec, fb.partInfo, fb.partInfo(job[1]))
      -- (only where the design had a piece: a camp's open edges stay open)
      local pick = nil
      for _, sl in ipairs(list) do if design_err(job[2], sl.lx, sl.ly, sl.lz) < 0.02 then pick = sl break end end
      if pick then
        tried = tried + 1
        fb.hold(job[1]); yield()
        local hit = BL.aim_slot(fb, rec, pick)
        local n0 = #rec.bp
        local got, why = fb.placeAt(hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz, nil)
        yield()
        rec = ST.get(sid)
        if got and #rec.bp == n0 + 1 then
          local np = rec.bp[#rec.bp]
          local err = design_err(job[2], np.x, np.y, np.z)
          worst = math.max(worst, err)
          if err > 0.005 then offgrid = offgrid + 1 end
          placed[job[2]] = placed[job[2]] + 1
          did = true
        else
          whyLast = why
          P("BL   a %s at (%.1f, %.1f, %.1f) refused: %s", job[1], pick.lx, pick.ly, pick.lz, tostring(why))
        end
      end
    end
    if not did then break end
    local en = RU.enclosure(s.id)
    if en and en.ok and pass > 2 then
      -- (go on only while a design slot is still open)
    end
  end
  fb.dropHeld()
  wait(1.5)
  if RA and RA.solveNow then pcall(RA.solveNow, sid) end
  wait(1.0)
  rec = ST.get(sid)
  local en1 = RU.enclosure(s.id)
  P("BL repair: %d righted, %d walls and %d roof panels (concrete) placed through the aim in %d tries, worst %.4f m from the design's pose, %d off the grid, $%d spent; last refusal %s",
    righted, placed.wall, placed.floor, tried, worst, offgrid, f0 - co.balance(), tostring(whyLast))
  BK.check("aligned", placed.wall + placed.floor >= 2 and offgrid == 0 and worst < 0.005,
    "%d pieces set into the ruin's gaps by the player's own snap: every one within %.1f mm of where the design had it", placed.wall + placed.floor, worst * 1000)
  BK.check("holds_air", en1 ~= nil and en1.ok, "the rooms now: %d of %d hold air (steel walls, concrete roof panels: any material)", en1 and en1.sealed or -1, en1 and en1.need or -1)
  for i, o in ipairs(en1 and en1.open or {}) do P("BL   still open %d: %.0f m³ · %s", i, o.m3 or 0, table.concat(o.leaks, "; ")) end
  wait(2.5)
  BK.check("feat", F.has("ruin_repaired") and RU.state(s.id).enc ~= nil, "the feat: a claimed ruin whose rooms hold air again (enc %s)", tostring(RU.state(s.id).enc))
  KIT.close(fb); wait(0.8)
  KIT.view("r1_repaired", rec, { 12, 9, 15 }, { 1.5, 1, -2 })
  KIT.view("r1b_repaired_other_side", rec, { -11, 8, -14 }, { 2, 1, -1 })
  KIT.view("r1c_roof_close", rec, { 5, 6.5, 6 }, { 1, 2.4, 0 })
  -- ── 4. its power, by cable ──
  local base = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
  local bid = base and base.id
  BG.rebuildNow(); wait(1.0)
  local tp = bid and BT.power(bid) or {}
  BK.check("unpowered", bid ~= nil and tp.powered == false, "claimed and closed, but nothing is cabled: the tower has no power (base %s)", base and tostring(base.n) or "none")
  for _, p in ipairs(arrays) do if ST.getPart(sid, p.uid).wr then RU.repairPiece(sid, p.uid) end end
  wait(1.0)
  local laid, whys = 0, {}
  local function lay(a, z, ty)
    local id, why = CB.lay({ sid = sid, uid = a }, { sid = sid, uid = z }, { ty = ty })
    if id then laid = laid + 1 else whys[#whys + 1] = tostring(why) end
    return id
  end
  lay(bank.uid, tower.uid, "lv16")
  for _, p in ipairs(arrays) do lay(p.uid, bank.uid, "lv2") end
  lay(bank.uid, wallU, "lv16")
  BG.rebuildNow(); wait(2.0)
  tp = BT.power(bid)
  BK.check("cabled", laid == 2 + #arrays and tp.powered == true and (tp.sources or 0) == #arrays and BG.circuitDead(sid) == false,
    "%d cables (bank → tower, %d arrays → bank, bank → the building): the tower served by %d source(s), the building live (%s)", laid, #arrays, tp.sources or -1, table.concat(whys, "; "))
  local BPw = findScript("base_power")
  tap("b"); wait(1.0)
  BPw.overlay = true; BPw.overlayAlways = true
  PW.view("r2_cabled_overlay", rec, { 14, 10, 17 }, { 1.5, 1, -2 })
  BPw.overlay = false; BPw.overlayAlways = false
  KIT.close(fb); wait(0.8)
  -- ── 5. the builder from the tower, left with nothing changed ──
  local bh = findScript("build_host")
  local n0 = #ST.get(sid).bp
  local keep = {}
  for _, p in ipairs(ST.get(sid).bp) do keep[p.uid] = string.format("%s|%.3f|%.3f|%.3f|%.3f|%s|%s", p.id, p.x, p.y, p.z, p.yaw or 0, tostring(p.ri), tostring(p.rl)) end
  local okb, whyb = has.ru_build.act()
  local opened = wait_for(function() return bh.state == "building" end, 60, "the builder on the ruin")
  wait(3.0)
  BK.shot("r3_builder_on_the_ruin", true)
  BK.check("builder", okb ~= false and opened, "Build the base on the tower opens the builder on the site (%s, state %s)", tostring(whyb), tostring(bh.state))
  if opened then
    local okl, whyl = bh.leave()
    wait_for(function() return bh.state == "idle" end, 60, "back from the builder")
    wait(3.0)
    local r2 = ST.get(sid)
    local same, lost = 0, 0
    for _, p in ipairs(r2 and r2.bp or {}) do
      if keep[p.uid] == string.format("%s|%.3f|%.3f|%.3f|%.3f|%s|%s", p.id, p.x, p.y, p.z, p.yaw or 0, tostring(p.ri), tostring(p.rl)) then same = same + 1 end
    end
    lost = n0 - same
    local en2 = RU.enclosure(s.id)
    BK.check("builder_keeps", r2 ~= nil and #r2.bp == n0 and lost == 0 and #CB.list() == laid and en2 and en2.ok,
      "left with nothing changed (%s): %d of %d pieces as they were, %d cables, the rooms still hold air", tostring(whyl or okl), same, n0, #CB.list())
  end
  BK.result()
end

--   craft   (phases 5 and 6, playtest 11-12b: "craft parts out of materials
--           at workbenches, drawing on a material storage, plus part shipping
--           between bases") a slab with a Workbench and a Locker; steel,
--           wiring and glass in the locker; the bench's menu, its RECIPE
--           panel (the Fabricator's, hosted by the bench); a wall queued:
--           nothing happens with nobody at the bench, then an Engineer stands
--           at it and the wall is made into its drawers; the kit places it
--           from the crate for no money; a Repair Kit made. Then a second
--           base 600 m off: its tower's Courier rows, a manifest from the
--           spaceport's warehouse, the bill, the pod in flight, set down by
--           the tower (the clock run forward), its crate opened.
function BL.run_craft()
  BK.tag = "craft"
  local spot = BL.setup()
  if not spot then BK.result() return end
  local fb, ST, co, C, inv = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew"), findScript("inventory")
  local WB, FP, CR, R, F, sv, BS, BT = findScript("workbench"), findScript("fab_panel"), findScript("courier"), findScript("recipes"), findScript("feats"),
    findScript("salvage"), findScript("bases"), findScript("base_tower")
  if not BK.check("scene", WB and FP and CR and R and sv, "workbench %s, fab_panel %s, courier %s in the scene", tostring(WB ~= nil), tostring(FP ~= nil), tostring(CR ~= nil)) then BK.result() return end
  tap("b"); wait(1.5)
  local sid, why
  for _, o in ipairs({ { 7, 0 }, { 8, -2 }, { 9, 2 }, { 6, -4 }, { 10, 0 }, { 8, 3 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab", sid ~= nil, "a slab (%s)", tostring(why)) then BK.result() return end
  fb.dropHeld()
  local T = 0.2
  ST.addPart(sid, { id = "slab2.concrete", x = 2, y = 0, z = 0, yaw = 0 })
  ST.addPart(sid, { id = "slab2.concrete", x = 0, y = 0, z = 2, yaw = 0 })
  ST.addPart(sid, { id = "slab2.concrete", x = 2, y = 0, z = 2, yaw = 0 })
  local ub = ST.addPart(sid, { id = "workbench.steel", x = 0, y = T, z = -0.4, yaw = 0 })
  local ul = ST.addPart(sid, { id = "locker.steel", x = 2.4, y = T, z = -0.5, yaw = 0 })
  ST.spawnNow(sid)
  wait(2.5)
  local rec = ST.get(sid)
  local lcid, bcid = "piece:" .. sid .. ":" .. ul, "piece:" .. sid .. ":" .. ub
  inv.add(lcid, "steel", 60); inv.add("base", "steel", 0)
  local put = inv.count(lcid, "steel")
  -- (a locker holds what it holds: the rest of the stock goes in a second one)
  local ul2 = ST.addPart(sid, { id = "locker.steel", x = 2.4, y = T, z = 1.2, yaw = 0 })
  ST.spawnNow(sid); wait(1.0)
  local lcid2 = "piece:" .. sid .. ":" .. ul2
  inv.add(lcid2, "steel", 60); inv.add(lcid2, "wiring", 6); inv.add(lcid, "glass", 4)
  inv.add("astro", "steel", 40)
  P("BL stock: locker 1 steel %d (cap %.0f kg), locker 2 steel %d wiring %d, pack steel %d", put, inv.cap(lcid), inv.count(lcid2, "steel"), inv.count(lcid2, "wiring"), inv.count("astro", "steel"))
  -- ── 1. the bench's menu and the panel ──
  KIT.tp(rec, 0.2, 0.9, T)
  wait(1.0)
  local bn = ST.nodeOf(sid, ub)
  local rows = bn and WB.providerFn({ node = bn }, { actor = { kind = "crew", id = "astro", pack = "astro" } }) or {}
  local has = {}
  for _, r in ipairs(rows) do has[r.id] = r end
  local stockLine = has.wb_stock and has.wb_stock.value() or "?"
  P("BL bench menu: %d rows · stock '%s'", #rows, tostring(stockLine))
  BK.check("menu", has.wb_job and has.wb_stock and has.wb_work and stockLine:find("Steel", 1, true) ~= nil, "the Workbench's menu: On the bench, Stock in reach, Work at the bench")
  local rw = WB.recipeOf("wall.steel")
  BK.check("recipe", rw ~= nil, "a steel wall is bench work: %s, %.0f s by hand", rw and R.lineOf(rw) or "none", rw and WB.secsOf(rw) or -1)
  local okw = has.wb_work.act()
  wait(1.0)
  FP.pick("wall.steel")
  wait(1.2)
  BK.shot("c0_bench_panel_wall", true)
  BK.check("panel", okw and FP.isOpen() and FP.view.host == "bench", "Work at the bench opens the RECIPE panel on the bench (host %s)", tostring(FP.view.host))
  -- ── 2. queued with nobody at the bench ──
  local f0 = co.balance()
  local okq, whyq = FP.queueSel(1)
  FP.close()
  KIT.tp(rec, 0.2, 9.0, T)       -- (9 m off)
  wait(3.0)
  local B, _, s = WB.benchOf(sid, ub)
  BK.check("nobody", okq and #B.q == 1 and not B.q[1].started and (s.fwhy or ""):find("nobody at the bench", 1, true) ~= nil,
    "queued (%s); the Engineer 9 m off: '%s', nothing taken (steel in reach %d)", tostring(whyq), tostring(s.fwhy), WB.have(sid, ub, "steel"))
  -- ── 3. an Engineer stands at it ──
  -- (the stock with the worker's pack in it, read before walking up: the job
  -- starts the moment someone is at the bench)
  local steel0 = WB.have(sid, ub, "steel") + inv.count("astro", "steel")
  local t0 = time
  KIT.tp(rec, 0.2, 0.9, T)
  wait(1.0)
  B, _, s = WB.benchOf(sid, ub)
  local needSteel = 0
  for _, m in ipairs(rw.mats) do if m.mat == "steel" then needSteel = math.ceil(m.kg - 1e-9) end end
  BK.check("started", B.q[1] and B.q[1].started and math.abs((s.duty or 0) - 2.0) < 0.01 and steel0 - WB.have(sid, ub, "steel") == needSteel,
    "at the bench: pace ×%.1f, %d kg of steel taken from the stock (the recipe's %d, nothing wasted)", s.duty or -1, steel0 - WB.have(sid, ub, "steel"), needSteel)
  has.wb_work.act(); wait(0.8)
  BK.shot("c1_bench_at_work", true)
  FP.close()
  local crate = R.partItemId("wall.steel")
  local made = wait_for(function() return inv.itemCount(bcid, crate) >= 1 end, 90, "the wall made")
  local took = time - t0
  BK.check("made", made and F.has("part_crafted"), "the wall is made in %.0f s of standing there (%.0f s by hand at ×2 = %.0f s): a crate in the bench's drawers, the feat marked; fittings $%d",
    took, WB.secsOf(rw), WB.secsOf(rw) / 2, f0 - co.balance())
  -- ── 4. the kit places it from the crate, for no money ──
  tap("b"); wait(1.0)
  if not fb.isOpen() then tap("b"); wait(1.0) end
  local st = fb.reachScan(true)
  local f1 = co.balance()
  fb.hold("wall.steel"); yield()
  rec = ST.get(sid)
  local hit = KIT.w(rec, 2.0, T, 2.75)      -- (the far slab's top, by its +Z edge)
  local up = unit(sub(hit, home()))
  local n0 = #rec.bp
  local okp, whyp = fb.placeAt(hit.x, hit.y, hit.z, up.x, up.y, up.z, ST.nodeOf(sid, 4))
  wait(1.0)
  rec = ST.get(sid)
  BK.check("placed", (st.crated[crate] or 0) >= 1 and okp and #rec.bp == n0 + 1 and inv.itemCount(bcid, crate) == 0 and f1 - co.balance() == 0,
    "the kit's reach sees the crate (%d); the wall is placed from it for $%d (%s)", st.crated[crate] or 0, f1 - co.balance(), tostring(whyp))
  fb.dropHeld(); KIT.close(fb); wait(0.5)
  KIT.view("c2_wall_from_the_bench", rec, { -4, 3.2, 6 }, { 1, 1, 0.5 })
  -- ── 5. a tool ──
  local okt = WB.queue(sid, ub, "tool:repairkit", 1)
  KIT.tp(rec, 0.2, 0.9, T)
  local k0 = inv.itemCount(bcid, "repairkit")
  local kit = wait_for(function() return inv.itemCount(bcid, "repairkit") > k0 end, 90, "the Repair Kit made")
  BK.check("tool", okt and kit, "a Repair Kit made at the bench, in its drawers (%d)", inv.itemCount(bcid, "repairkit"))
  -- ── 6. a second base, and the courier ──
  local s2 = PW.found(ST, { dir = spot.dir, r = spot.r, t = spot.t }, 600, 0, "tower", "Far tower")
  wait(3.0)
  if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
  local rec2 = ST.get(s2)
  local base2 = BS.baseAt(rec2.b, rec2.x, rec2.y, rec2.z)
  if not BK.check("base2", base2 ~= nil, "a second base 600 m on: %s", base2 and tostring(base2.n) or "none") then BK.result() return end
  inv.add("base", "steel", 300)
  inv.addItem("base", crate, 2, { force = true })
  KIT.tp(rec2, 3, 3, 0)
  wait(3.0)
  local tn = wait_for(function() return ST.nodeOf(s2, 1) end, 20, "the far tower's node")
  local crows = tn and CR.providerFn({ node = tn }, { actor = { kind = "crew", id = "astro", pack = "astro" } }) or {}
  local chas = {}
  for _, r in ipairs(crows) do chas[r.id] = r end
  local subrows = chas.cr_req and chas.cr_req.sub() or {}
  local fromHome = nil
  for _, r in ipairs(subrows) do if r.id == "cr_s_home" then fromHome = r end end
  local lines = fromHome and fromHome.sub() or {}
  P("BL courier menu: %d rows on the tower, %d sources, %d lines in the warehouse", #crows, #subrows, #lines)
  BK.check("courier_menu", chas.cr_req ~= nil and fromHome ~= nil and #lines >= 2, "the tower's Courier: Request a shipment → From the spaceport's warehouse → its stock")
  CR.addLine(base2.id, "home", "i:" .. crate, 2)
  CR.addLine(base2.id, "home", "m:steel", 100)
  local Bq, whyb = CR.bill(base2.id, "home", CR.manifest(base2.id))
  if not BK.check("bill", Bq ~= nil, "the bill: %s", Bq and string.format("%.0f kg over %.0f m · $%d · %s", Bq.kg, Bq.dist, Bq.fee, CR.etaLine(Bq.secs)) or tostring(whyb)) then BK.result() return end
  crows = CR.providerFn({ node = tn }, { actor = { kind = "crew", id = "astro", pack = "astro" } })
  chas = {}
  for _, r in ipairs(crows) do chas[r.id] = r end
  P("BL manifest row: '%s' · send row: '%s' (%s)", chas.cr_man and chas.cr_man.value() or "?", chas.cr_send and chas.cr_send.label() or "?", chas.cr_send and chas.cr_send.hint() or "?")
  local f2 = co.balance()
  local oks = chas.cr_send and chas.cr_send.act()
  wait(0.5)
  local fl = CR.inFlight(base2.id)
  BK.check("sent", oks and fl ~= nil and f2 - co.balance() == Bq.fee and inv.itemCount("base", crate) == 0,
    "sent: $%d paid, the goods out of the warehouse at once, the pod in flight (arrives in %s)", f2 - co.balance(), fl and CR.etaLine(fl.eta - fl.t0) or "?")
  CR.tick()
  BK.check("not_early", CR.inFlight(base2.id) ~= nil and #sv.list() == 0, "before its time nothing lands")
  -- (the clock run forward: the pod's hour comes)
  local n0s = #sv.list()
  local okd, whyd = CR.deliverNow(fl.id)
  wait(2.5)
  local L = sv.list()
  local pod = L[#L]
  local tw = KIT.w(rec2, 0, 0, 0)
  local dpod = pod and len(pod.x - tw.x, pod.y - tw.y, pod.z - tw.z) or -1
  BK.check("landed", okd and #L == n0s + 1 and CR.inFlight(base2.id) == nil and dpod > 4 and dpod < 14 and F.has("shipment_received"),
    "the pod is down %.1f m from the tower (%s): %.0f kg in its crate, the feat marked", dpod, tostring(whyd), pod and pod.kg or -1)
  KIT.view("c3_pod_by_the_tower", rec2, { 12, 5, 12 }, { 4, 0.5, 2 })
  tap("b"); wait(1.0)
  if pod then
    -- walk up to it: the kit's reach reads its crated parts where it stands
    -- (the crate's place read again now: a world point is stale a frame on)
    local a = astro()
    local Ln = sv.list()
    pod = Ln[#Ln]
    local up2 = unit(sub(pod, home()))
    a.x, a.y, a.z = pod.x + up2.x * 1.2 + 1.2, pod.y + up2.y * 1.2, pod.z + up2.z * 1.2
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(2.0)
    local st2 = fb.reachScan(true)
    BK.check("pod_in_reach", (st2.crated[crate] or 0) == 2, "standing by the pod, the Build Kit's reach has its %d crated walls (materials in reach: steel %d kg)", st2.crated[crate] or 0, st2.mats.steel or 0)
    BK.shot("c4_at_the_pod", true)
  end
  BK.result()
end
