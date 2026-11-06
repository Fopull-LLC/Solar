-- ── the editor at a Build Stand (tools/perf/buildkitprobe.sh <engine> standedit) ──
-- work/standeditor/PLAN.md §12.2. Spliced after buildkitprobe_modes.lua (its
-- BK table and helpers). Build here opens the real VAB on a stand (one
-- BuildFrame on the planet, held to the deck within 2 cm while the planet
-- moves), the camera clipped by the world, a rover built there (the deck
-- rising to what it needs), the stand's CHECK rows, ESC back to the Engineer
-- (the diff charged, the craft drawn on the deck, the VAB's keys untouched),
-- the idle cost, a second session's $0 and a refund, OPEN of a rover saved on
-- its side (turned wheels down; Ctrl+Z keeps it as saved), the ORIENT keys,
-- COMMISSION (refused while the Engineer stands in its box, then held on the
-- deck), Release / drive / Return / Build here on the returned craft, and the
-- VAB beside it for comparison. Pictures se1..se12; `BK PASS|FAIL`,
-- `BK RESULT standedit`.

-- Drive a rover at a crawl until its centre is within `reach` of a point
-- (target() → this frame's world point), braking against its roll when it
-- gets there and turning back if it overshoots. → true when it stopped in reach
function BK.approach(vc, vn, target, reach, tmo)
  local t0 = time
  local sgn, away_t = nil, nil
  while time - t0 < (tmo or 40) do
    local ii = assembly.info(vn)
    local tp = target()
    if not (ii and tp) then return false end
    local d = sub(tp, ii.com)
    local U = unit(sub(ii.com, home()))
    d = sub(d, scl(U, dot(d, U)))
    local dist = len(d.x, d.y, d.z)
    local sp = len(ii.vel.x, ii.vel.y, ii.vel.z)
    -- (the closing speed: + toward the target)
    local vt = dist > 1e-3 and dot(ii.vel, d) / dist or 0
    if dist < reach then
      BK.stop_rover(vc, vn)
      local i2 = assembly.info(vn)
      local d2 = sub(target(), i2.com)
      d2 = sub(d2, scl(U, dot(d2, U)))
      if len(d2.x, d2.y, d2.z) < reach then return true end
    elseif sp > ((dist > 8) and 3.0 or 1.0) and vt > 0 then
      vc.R2.cmd = { drive = 0, steer = 0 }
      BK.stop_rover(vc, vn, 2)
    else
      if not sgn then
        local f = vn:worldRight()
        sgn = dot(d, f) >= 0 and 1 or -1
      end
      -- driving away from it for half a second: the other way
      if vt < -0.3 then
        away_t = away_t or time
        if time - away_t > 0.5 then BK.stop_rover(vc, vn, 4); sgn, away_t = -sgn, nil end
      else
        away_t = nil
      end
      vc.R2.cmd = { drive = sgn * ((dist > 8) and 0.5 or 0.2), steer = 0 }
      yield()
    end
  end
  BK.stop_rover(vc, vn)
  return false
end

-- the session's frame vs where it should be on the planet (m), worst over secs
function BK.frame_drift(BH, secs)
  local worst, n = 0, 0
  local t_end = time + secs
  local b0 = home()
  local p0 = { x = b0.x, y = b0.y, z = b0.z }
  while time < t_end do
    yield()
    local fr = find("BuildFrame")
    local want = BH.standFrameWant and BH.standFrameWant()
    local b = want and space.body(want.body)
    if fr and want and b then
      local w = fr.worldPos
      worst = math.max(worst, len(w.x - b.x - want.x, w.y - b.y - want.y, w.z - b.z - want.z))
      n = n + 1
    end
  end
  local b1 = home()
  return worst, n, len(b1.x - p0.x, b1.y - p0.y, b1.z - p0.z)
end
function BK.count(name)
  local n = 0
  for _, x in ipairs(findAll and findAll(name) or {}) do if x.valid ~= false then n = n + 1 end end
  return n
end
-- the parked astronaut's offset from its park point (m)
function BK.park_err(BH)
  local pk = BH.parkPoint and BH.parkPoint()
  local a, b = astro(), home()
  if not (pk and a and b) then return -1 end
  return len(a.x - b.x - pk.x, a.y - b.y - pk.y, a.z - b.z - pk.z)
end
function BK.wait_building(BH, tmo)
  return wait_for(function() return BH.state == "building" and BH.hostKind == "stand" and findScript("builder") end, tmo or 20, "the editor at the stand")
end
function BK.ups(CO, B)
  local list = {}
  for _, r in pairs(B.orientRecs()) do list[#list + 1] = r end
  return CO.upAxis(list, CO.kindOf(list, nil, findScript("craft_mode"))), list
end
-- move the parked Engineer into the craft's box (on) or back (off)
function BK.park_in(BH, CS, sid, on)
  local pk = BH.parkPoint and BH.parkPoint()
  if not pk then return end
  if on then
    BK.pk_saved = { x = pk.x, y = pk.y, z = pk.z }
    local fp = CS.framePose(sid, 1)
    pk.x, pk.y, pk.z = fp.G.x + fp.U.x * (fp.h + 0.9), fp.G.y + fp.U.y * (fp.h + 0.9), fp.G.z + fp.U.z * (fp.h + 0.9)
  elseif BK.pk_saved then
    pk.x, pk.y, pk.z = BK.pk_saved.x, BK.pk_saved.y, BK.pk_saved.z
  end
end

function BK.run_standedit()
  BK.tag = params.tag or "standedit"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C, CS = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew"), findScript("craft_stand")
  local BH, CO, FO = findScript("build_host"), findScript("craft_orient"), findScript("flight_ops")
  if not BK.check("scene", fb and ST and co and C and CS and BH and CO, "kit, structures, craft_stand, build_host, craft_orient") then BK.result() return end
  C.patch(C.activeId(), { role = "engineer" })
  -- the library: the rover, and the same rover saved lying on its side
  local VBH = enter_vab("se_vab")
  local B = findScript("builder")
  if VBH and B then
    wait(1.0)
    load_bp(B, "se_rover_bp", ROVER)
    B.craftSave("Stand Rover")
    wait(0.5)
    B.cmd("orient", { axis = "x", sign = 1, quiet = true })
    wait(0.5)
    B.craftSave("Side Rover")
    wait(0.5)
    load_bp(B, "se_vab_bp", ROVER)
    B.craftSave("VAB Craft")
    wait(0.5)
    VBH.leave(); wait(3)
  end
  local vab_cur = save.get("shipyard.current")
  local vab_n = #((save.get("shipyard.blueprint") or {}).parts or {})
  P("BK the VAB's own craft: %s (%d parts)", tostring(vab_cur), vab_n)
  -- out to flat ground, a stand, its deck down at 0.5 m
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
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
  tap("b"); wait(1.5)
  local cp = findScript("catalog_panel")
  cp.pickPart("stand")
  BK.aim_at(7, 0)
  BK.settle(30)
  BK.click(false)
  wait(1.5)
  local sid = fb.lastPlace and fb.lastPlace.sid
  fb.heldPart = nil
  tap("escape"); wait(0.5)
  if not BK.check("stand", sid ~= nil and ST.nodeOf(sid, 1) ~= nil, "a Build Stand placed (struct.%s)", tostring(sid)) then BK.result() return end
  for _ = 1, 6 do BK.run_entry(BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_dn")); yield() end
  -- (the Engineer stands 3 m off the deck)
  do
    local top, U = BK.stand_top(ST, CS, sid)
    local a = astro()
    local d = sub(a, top)
    d = unit(sub(d, scl(U, dot(d, U))))
    local p = { x = top.x + d.x * 3 + U.x * 2, y = top.y + d.y * 3 + U.y * 2, z = top.z + d.z * 3 + U.z * 2 }
    local h = raycast(p.x, p.y, p.z, -U.x, -U.y, -U.z, 10, { ignore = a })
    if h then a.x, a.y, a.z = h.x + U.x * 1.0, h.y + U.y * 1.0, h.z + U.z * 1.0 end
    wait(1.5)
  end
  local top, U = BK.stand_top(ST, CS, sid)
  BK.view("se1_stand", top, U, BK.F, 7.0, 4.0, 2.5)
  -- 1. BUILD HERE
  local eb = BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_build")
  local reg = findScript("context_registry")
  BK.check("menu", eb ~= nil and reg.usable(eb), "RMB on the stand: Build here, usable")
  BK.run_entry(eb)
  B = BK.wait_building(BH)
  local gm = findScript("game_manager")
  BK.check("enter", B ~= nil and find("Builder") ~= nil and BK.count("BuildFrame") == 1 and gm.inputOwner == "builder" and astro().visible ~= false,
    "the VAB at the stand: Builder up, %d BuildFrame, keys %s, the Engineer in view %s (%.0f ms)", BK.count("BuildFrame"), tostring(gm.inputOwner),
    tostring(astro().visible), BH.enterMs or -1)
  if not B then BK.result() return end
  wait(1.0)
  local drift, nf, moved = BK.frame_drift(BH, 5.0)
  BK.check("frame_held", nf > 60 and drift < 0.02, "the BuildFrame held to the deck: worst %.4f m over %d frames while the planet moved %.0f m", drift, nf, moved)
  BK.check("park", BK.park_err(BH) < 0.01, "the Engineer pinned where they stood (%.4f m)", BK.park_err(BH))
  BK.shot("se2_entered")
  -- 2. THE CAMERA, clipped by the world: a low orbit
  local bc = findScript("builder_camera")
  local qmin, under, frames = 99, 0, 0
  local st0 = bc.camState()
  for k = 0, 360, 2 do
    bc.setCamState({ P = { x = 0, y = 1.0, z = 0 }, yaw = st0.yaw + math.rad(k), pitch = -0.05, d = 18 })
    yield()
    local c = bc.camPos
    if c and terrain.query then
      local q = terrain.query(c.x, c.y, c.z)
      if q then qmin = math.min(qmin, q) end
      frames = frames + 1
      local fp = CS.framePose(sid, 1)
      local b = home()
      local hgt = dot(sub(c, { x = b.x + fp.G.x, y = b.y + fp.G.y, z = b.z + fp.G.z }), fp.U)
      if hgt < 0.15 then under = under + 1 end
    end
  end
  BK.check("camera", frames > 150 and qmin > 0.15 and under == 0,
    "a low 360° orbit at 18 m: never in the rock (terrain.query ≥ %.2f), never under the stand's ground (%d frames), clip %.1f m",
    qmin, under, bc.clipD or -1)
  bc.setCamState({ P = { x = 0, y = 1.0, z = 0 }, yaw = st0.yaw + 0.6, pitch = -0.02, d = 40 })
  wait(0.6)
  BK.shot("se3_camera_low")
  -- 3. A ROVER BUILT HERE: the deck rises to what it needs
  local h0 = CS.framePose(sid, 1).h
  load_bp(B, "se_build", ROVER)
  wait(2.5)
  local h1 = CS.framePose(sid, 1).h
  local ss = BH.standState()
  local want = BH.standFrameWant()
  local fr = find("BuildFrame")
  local b = home()
  local ferr = (fr and want) and len(fr.worldPos.x - b.x - want.x, fr.worldPos.y - b.y - want.y, fr.worldPos.z - b.z - want.z) or 99
  BK.check("deck_rise", h0 < 0.55 and math.abs(h1 - 0.6) < 1e-6 and ss and (ss.fo or 0) > 0.3 and ferr < 0.02,
    "the rover on the deck: the deck rose %.1f → %.1f m, its belly %.2f m over its tyres (the floor), the frame with it (%.4f m)",
    h0, h1, ss and ss.fo or -1, ferr)
  bc.setCamState({ P = { x = 0, y = 0.8, z = 0 }, yaw = st0.yaw + 0.5, pitch = -0.25, d = 6 })
  wait(0.8)
  BK.shot("se4_rover_built")
  -- 4. THE STAND'S CHECK ROWS: S5 while the Engineer is in its box
  BK.park_in(BH, CS, sid, true)
  local s5 = wait_for(function() return B.checkRow("S5") end, 6, "S5")
  BK.check("s5", s5 ~= nil, "S5 while the Engineer stands in the craft's box: %s", s5 and s5.text or "none")
  local ins = findScript("builder_inspector")
  if ins and ins.setTab then ins.setTab("INSPECT") end
  wait(0.5)
  BK.shot("se5_check")
  BK.park_in(BH, CS, sid, false)
  local gone5 = wait_for(function() return B.checkRow("S5") == nil end, 6, "S5 clears")
  BK.check("s5_clear", gone5 ~= nil, "...and clears when they step back")
  -- 5. ESC: back to the Engineer, the diff charged, the craft on the deck
  local fE = co.balance()
  for _ = 1, 4 do if BH.state == "building" then tap("escape"); wait(0.4) end end
  wait(1.0)
  local stE = CS.stateOf(sid, 1)
  local paidE = fE - co.balance()
  BK.check("esc", BH.state == "idle" and find("Builder") == nil and BK.count("BuildFrame") == 0 and gm.inputOwner == nil
    and stE and stE.s == "built" and stE.n == 6 and find("StandCraft") ~= nil and paidE > 0 and BK.park_err(BH) <= 0.01,
    "ESC: the overlay gone, no BuildFrame, keys back, the rover on the deck (%s, %d parts, drawn %s), %s charged — %s",
    stE and stE.s or "-", stE and stE.n or -1, tostring(find("StandCraft") ~= nil), tostring(paidE),
    tostring(BH.lastStandExit and BH.lastStandExit.quote and BH.lastStandExit.quote.total))
  BK.check("vab_keys", save.get("shipyard.current") == vab_cur and #((save.get("shipyard.blueprint") or {}).parts or {}) == vab_n,
    "the VAB's own craft untouched (%s)", tostring(save.get("shipyard.current")))
  top, U = BK.stand_top(ST, CS, sid)
  BK.view("se6_after_esc", top, U, BK.F, 6.0, 3.5, 1.8)
  BK.cost("a craft built at a stand, not commissioned", 10)
  -- 6. BUILD HERE AGAIN: $0, then a part off (a refund in the minute)
  BK.run_entry(BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_build"))
  B = BK.wait_building(BH)
  wait(2.0)
  local st6 = B and B.stats()
  BK.check("again", B and B.partCount == 6 and st6 and (st6.cost or -1) == 0, "Build here again: %d parts, COST %s",
    B and B.partCount or -1, tostring(st6 and st6.cost))
  if B then B.cmd("delete", { uids = { 6 }, only = true }) end
  wait(0.5)
  local f6 = co.balance()
  if B then B.doLeave() end
  wait(1.0)
  local back6 = co.balance() - f6
  BK.check("refund", back6 > 0 and CS.stateOf(sid, 1).n == 5, "the seat taken off and LEAVE: %s back", tostring(back6))
  -- 7. OPEN A ROVER SAVED ON ITS SIDE: turned wheels down
  BK.run_entry(BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_build"))
  B = BK.wait_building(BH)
  wait(1.5)
  if not B then BK.result() return end
  B.craftOpen("Side Rover")
  wait(2.5)
  local upA = BK.ups(CO, B)
  BK.check("auto_orient", upA.y > 0.99, "OPEN “Side Rover”: turned wheels down (up %.3f) — %s", upA.y, tostring(B.hintText and B.hintText()))
  findScript("builder_camera").setCamState({ P = { x = 0, y = 0.8, z = 0 }, yaw = st0.yaw + 0.5, pitch = -0.25, d = 6 })
  B.undoStep()
  wait(1.0)
  local upS = BK.ups(CO, B)
  BK.check("undo_orient", math.abs(upS.y) < 0.1, "Ctrl+Z keeps it as saved: on its side (up %.2f, %.2f, %.2f)", upS.x, upS.y, upS.z)
  BK.shot("se7_as_saved")
  B.redoStep()
  wait(1.0)
  BK.shot("se8_turned")
  -- 8. THE ORIENT KEYS: ↻Y ×4 is where it started
  local _, l0 = BK.ups(CO, B)
  local p0 = {}
  for _, r in ipairs(l0) do p0[r.uid] = { r.x, r.y, r.z } end
  for _ = 1, 4 do B.cmd("orient", { axis = "y", sign = 1, quiet = true }); yield() end
  local _, l1 = BK.ups(CO, B)
  local werr = 0
  for _, r in ipairs(l1) do local q0 = p0[r.uid]; if q0 then werr = math.max(werr, len(r.x - q0[1], r.y - q0[2], r.z - q0[3])) end end
  BK.check("orient4", werr < 1e-3, "↻Y ×4: back where it was (%.6f m)", werr)
  B.cmd("orient", { axis = "x", sign = 1, quiet = true })
  wait(0.5)
  BK.shot("se9_orient_x")
  B.cmd("orient", { auto = true, quiet = true })
  wait(1.0)
  local upB = BK.ups(CO, B)
  BK.check("orient_auto", upB.y > 0.99, "AUTO stands it wheels down again (%.3f)", upB.y)
  -- 9. COMMISSION: refused while the Engineer is in its box, then held
  BK.park_in(BH, CS, sid, true)
  wait_for(function() return B.checkRow("S5") end, 6, "S5 again")
  B.doLaunch(); wait(0.3); B.doLaunch(); wait(0.5)
  BK.check("commission_refused", BH.state == "building", "COMMISSION refused while the Engineer stands where it goes (%s)", tostring(B.hintText and B.hintText()))
  BK.park_in(BH, CS, sid, false)
  wait_for(function() return B.checkRow("S5") == nil end, 6, "S5 clears again")
  wait(0.5)
  local fC = co.balance()
  B.doLaunch(); wait(0.3)
  if BH.state == "building" then B.doLaunch() end
  local E = wait_for(function() local e = CS.heldOf(sid, 1); return e and e.phase == "held" and e end, 10, "commissioned")
  wait(1.0)
  local vc = E and BK.ctl_of(E.node)
  local dC, nC = BK.held_drift(CS, sid, 3.0)
  if FO and FO.fleetSync then FO.fleetSync(true) end
  BK.check("commission", BH.state == "idle" and E and vc and vc.standHeld == true and dC < 0.02 and not BK.fleet_has("Side Rover"),
    "COMMISSION: the overlay down, a live craft held on the deck (worst %.4f m over %d frames), off the board; %s charged",
    dC, nC, tostring(fC - co.balance()))
  top, U = BK.stand_top(ST, CS, sid)
  BK.view("se10_commissioned", top, U, BK.F, 6.0, -3.5, 1.8)
  -- 10. RELEASE, DRIVE, RETURN, BUILD HERE ON THE RETURNED CRAFT
  BK.run_entry(BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_rel"))
  wait_for(function() return CS.heldOf(sid, 1) == nil end, 30, "the release")
  wait(1.5)
  local vn = E and E.node
  local boarded = vc and vc.boardNow and vc.boardNow()
  for _ = 1, 120 do
    if boarded or not (vc and vn and vn.valid) then break end
    local ii = assembly.info(vn)
    local aa = astro()
    aa.x, aa.y, aa.z = ii.com.x, ii.com.y, ii.com.z
    yield()
    boarded = vc.boardNow()
  end
  local far = 0
  if boarded then
    local t0 = time
    while time - t0 < 15 do
      vc.R2.cmd = { drive = 0.6, steer = 0 }
      yield()
      local t2 = BK.stand_top(ST, CS, sid)
      local ii = assembly.info(vn)
      far = math.max(far, len(ii.com.x - t2.x, ii.com.y - t2.y, ii.com.z - t2.z))
      if far >= 10 then break end
    end
    BK.stop_rover(vc, vn)
    BK.approach(vc, vn, function() return BK.stand_top(ST, CS, sid) end, 2.5, 60)
    vc.R2.cmd = nil
    tap("f"); yield(); yield()
    if vc.crewAboard and vc.evaNow then vc.evaNow() end
    wait(2)
  end
  local kids = (vn and vn.valid) and vn:children() or {}
  local okr = BK.run_entry(BK.entry(BK.menu(kids[1]), "cs_ret"), 1.0)
  wait(1.0)
  BK.run_entry(BK.entry(BK.menu(ST.nodeOf(sid, 1)), "cs_build"))
  B = BK.wait_building(BH)
  wait(2.0)
  BK.check("returned_edit", okr and B and B.partCount == 6, "driven %.0f m and back, Return to stand, Build here on it: %d parts in the editor",
    far, B and B.partCount or -1)
  bc = findScript("builder_camera")
  if bc then bc.setCamState({ P = { x = 0, y = 0.8, z = 0 }, yaw = st0.yaw - 0.4, pitch = -0.28, d = 6.5 }) end
  wait(0.8)
  BK.shot("se11_returned_in_editor")
  local frS, wS = FRAME, W()
  wait(3)
  local msS = (W() - wS) * 1000 / math.max(1, FRAME - frS)
  local function edscripts()
    local t = 0
    for _, k in ipairs({ "builder", "builder_camera", "build_host", "builder_toolbar", "builder_inspector", "builder_statusbar", "catalog_panel" }) do
      t = t + math.max(0, perf.scriptMs and perf.scriptMs(k) or 0)
    end
    return t
  end
  local scS = edscripts()
  if B then B.doLeave() end
  wait(1.0)
  -- 11. THE VAB, for comparison (the same craft)
  local VB2 = enter_vab("se_vab2")
  local B2 = findScript("builder")
  local msV = -1
  if VB2 and B2 then
    wait(1.0)
    load_bp(B2, "se_vab_rover", ROVER)
    wait(1.0)
    local frV, wV = FRAME, W()
    wait(3)
    msV = (W() - wV) * 1000 / math.max(1, FRAME - frV)
    BK.scV = edscripts()
    BK.shot("se12_vab")
    VB2.leave(); wait(2)
  end
  P("BK COST the editor at a stand %.2f ms/frame vs the VAB %.2f ms/frame (same 6-part rover; the VAB hides the world outside)", msS, msV)
  BK.check("script_cost", scS > 0 and (BK.scV or 0) > 0 and scS <= BK.scV + 0.3,
    "the builder's scripts at a stand %.3f ms a frame, in the VAB %.3f (budget +0.3)", scS, BK.scV or -1)
  BK.result()
end
