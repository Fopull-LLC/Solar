-- ── quarry probe (tools/perf/quarryprobe.sh; expansion X5, "Quarry, belts,
-- tubes, chutes, silos, LOGISTICS overlay"; docs/base-building.md §23)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam),
-- buildkitprobe_modes.lua, standeditprobe_modes.lua and runprobe_modes.lua
-- (the stand and rover helpers).
--   logistics  a Build Stand on flat ground (the kit's path); beside it, one
--              structure: four Quarry Posts on a 12 × 12 m rectangle, a
--              Quarry Drive, conveyors to a Hopper, on to a Silo, on to a
--              Loading Chute whose spout hangs over the stand; the rover with
--              its Cargo Bay put on the stand and commissioned (its hold
--              "hold:Chute Mule"); the survey, the live digs (terrain.yields
--              into the drive's bin), the belts' load, the silo, the hold
--              filling through the chute (the move ring: silo → hold); ×20
--              warp: the pit going down, fieldEdited; the LOGISTICS overlay;
--              AWAY 2 km: the closed form's estimate, then back: the
--              catch-up digs; costs idle and running; a belt switched off
--              (its line stalls, LIMITED BY).
-- `QX PASS|FAIL <check>`, `QX …` lines and `QX RESULT`. Pictures: save/user/quarryshots/.
QX = { fails = 0, passed = 0 }
function QX.check(name, okc, fmt, ...)
  P("QX %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then QX.passed = QX.passed + 1 else QX.fails = QX.fails + 1 end
  return okc
end
function QX.result() P("QX RESULT %d passed, %d failed", QX.passed, QX.fails) end
function QX.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://quarryshots/" .. nm .. ".png", bytes); P("QX SHOT %s", nm)
    else P("QX SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- a fixed camera at a structure-local eye looking at a structure-local point
-- (body-relative each frame: the planet moves metres a tick)
function QX.view(nm, rec, e, t, ui)
  local KS = findScript("kit_snap")
  local fr = KS.frameOf(rec)
  local function B(v) return { x = fr.O.x + fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], y = fr.O.y + fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                               z = fr.O.z + fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3] } end
  VP.cam_fixed(B(e), B(t))
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(true) end
  wait(1.2)
  QX.shot(nm, ui)
  VP.cam_off()
  wait(0.3)
end
function QX.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  local LX = findScript("logistics")
  local c = perf.counts() or {}
  P("QX COST %s: logistics %.4f ms/frame, item_net %.4f, quarry %.4f, base_grid %.4f, inventory %.4f, mineral_field %.4f · step %s ms, late %.3f ms, overlay %.3f ms, digs %d, catch %d · fieldEdited %s, drawCalls %s",
    tag, ms("logistics"), ms("item_net"), ms("quarry"), ms("base_grid"), ms("inventory"), ms("mineral_field"),
    LX.PROF.step_ms .. " (advance " .. tostring(LX.PROF.adv_ms) .. " segs " .. tostring(LX.PROF.segs) .. " ev " .. tostring(LX.PROF.ev) .. ")", LX.PROF.late_ms, LX.PROF.overlay_ms, LX.PROF.digs, LX.PROF.catch, tostring(c.fieldEdited), tostring(c.drawCalls or c.draws))
  return ms("logistics")
end
function QX.state(tag, LX, ST, sid, uids, hold)
  local inv = findScript("inventory")
  local e = LX.quarryOf(sid, uids.drive)
  local function kg(cid) return inv.mass(cid) or 0 end
  local function list(cid) local t = {}; for _, it in ipairs(inv.items(cid) or {}) do t[#t + 1] = it.n .. " " .. it.mat end return table.concat(t, ", ") end
  local o = LX.readout(sid, uids.drive) or {}
  local oc = LX.readout(sid, uids.chute) or {}
  P("QX STATE %s: chute %s · tracked %d, last rid %s, yields %s reports %d", tag, tostring(oc.chute and oc.chute.craft), LX.PROF.tracked, tostring(e and e.lastRid),
    tostring(terrain.yields ~= nil), findScript("mineral_field").yieldStats.reports)
  P("QX STATE %s: att %s · removed %.1f over %d reports · dist %s", tag, tostring(LX.PROF.att), findScript("mineral_field").yieldStats.removed, findScript("mineral_field").yieldStats.reports, tostring(e and e.dist))
  P("QX STATE %s: quarry prog %.2f dug %s paid %s live %s layer %s depth %.1f m · bin %.0f kg [%s] · hopper %.0f kg [%s] · silo %.0f kg [%s] · hold %.0f kg [%s] · lim %s",
    tag, e and e.prog or -1, tostring(e and e.dug), tostring(e and e.paid), tostring(e and e.live), tostring(o.quarry and o.quarry.layer), o.quarry and o.quarry.depth or -1,
    kg("hopper:" .. sid .. "." .. uids.drive), list("hopper:" .. sid .. "." .. uids.drive), kg("hopper:" .. sid .. "." .. uids.hopper), list("hopper:" .. sid .. "." .. uids.hopper),
    kg("silo:" .. sid .. "." .. uids.silo), list("silo:" .. sid .. "." .. uids.silo), hold and kg(hold) or -1, hold and list(hold) or "", tostring(o.lim))
  return e
end

function QX.run()
  wait_ready(120)
  wait(2)
  local ST, CS, C, co, inv = findScript("structures"), findScript("craft_stand"), findScript("crew"), findScript("company"), findScript("inventory")
  local LX, Q, N, MF = findScript("logistics"), findScript("quarry"), findScript("item_net"), findScript("mineral_field")
  if not QX.check("scene", ST and CS and LX and Q and N and MF and inv, "logistics %s quarry %s item_net %s", tostring(LX ~= nil), tostring(Q ~= nil), tostring(N ~= nil)) then QX.result() return end
  if perf.enable then perf.enable(true) end
  local idle0 = QX.cost("idle: no logistics pieces anywhere", 3)
  if co and co.earn then co.earn(200000, "probe") end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  -- 1. the rover with a Cargo Bay into the library (the VAB's path)
  local BH = enter_vab("qx_vab")
  local B = findScript("builder")
  if BH and B then
    wait(1.0)
    load_bp(B, "qx_rover_bp", RN.rover_bp())
    B.craftSave("Chute Mule")
    wait(1.0)
    BH.leave(); wait(3)
  end
  local des
  for _, d in ipairs(CS.designs()) do if d.name == "Chute Mule" then des = d end end
  QX.check("library", des ~= nil, "the rover with its Cargo Bay is in the (probe's) library")
  -- 2. a Build Stand on flat ground
  local spot = BK.flat_spot()
  if not QX.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then QX.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local Ua = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(Ua, dot(f, Ua))))
  end
  local fb = findScript("field_builder")
  tap("b"); wait(1.5)
  local cp = findScript("catalog_panel")
  local nl = cp and cp.listFor and cp.listFor(fb, "LOGISTICS", "") or {}
  QX.check("tab", #nl >= 14, "the LOGISTICS section lists the pieces (%d)", #nl)
  if cp then cp.pickPart("stand") end
  BK.aim_at(8, 0); BK.settle(30)
  BK.click(false); wait(1.5)
  local ssid = fb and fb.lastPlace and fb.lastPlace.sid
  if fb then fb.heldPart = nil end
  tap("escape"); wait(0.5)
  if not QX.check("stand", ssid ~= nil and ST.getPart(ssid, 1) ~= nil, "a Build Stand placed (sid %s)", tostring(ssid)) then QX.result() return end
  local fp = CS.framePose(ssid, 1)
  local b = home()
  -- 3. the chain, one structure in the stand's frame: the chute's spout over
  -- the deck. Local frame (x right, z front): the spout at (8, 1.85, 16) is
  -- the stand's centre, so the origin is the stand's ground − 16 F − 8 R.
  local U, F = fp.U, fp.F
  local R = unit(cross(U, F))
  local G = fp.G
  local O = { x = G.x - F.x * 16 - R.x * 8, y = G.y - F.y * 16 - R.y * 8, z = G.z - F.z * 16 - R.z * 8 }
  -- (the ground under the origin, along the radial)
  local function ground_local(lx, lz)
    local b = home()   -- (this frame's read: the planet moves metres a tick)
    local wx, wy, wz = b.x + O.x + R.x * lx + F.x * lz + U.x * 30, b.y + O.y + R.y * lx + F.y * lz + U.y * 30, b.z + O.z + R.z * lx + F.z * lz + U.z * 30
    local h = terrain.raycast(vec3(wx, wy, wz), vec3(-U.x, -U.y, -U.z), 80)
    if not (h and h.pos) then return 0 end
    return dot(sub(h.pos, b), U) - dot(O, U)
  end
  local y0 = ground_local(8, 6)
  O = { x = O.x + U.x * y0, y = O.y + U.y * y0, z = O.z + U.z * y0 }
  local rec = ST.newRecord(nil, b.name, O.x, O.y, O.z, U, F, "qPost.steel", { name = "Quarry", t = 0 })
  local sid = ST.add(rec)
  rec = ST.get(sid)
  -- the posts: a 12 × 12 rectangle with the origin post at (−6, −6) from its centre (0, 0) → posts at local (−6..6)
  rec.bp[1].x, rec.bp[1].y, rec.bp[1].z = -6, ground_local(-6, -6), -6
  local uids = {}
  for _, c in ipairs({ { 6, -6 }, { 6, 6 }, { -6, 6 } }) do ST.addPart(sid, { id = "qPost.steel", x = c[1], y = ground_local(c[1], c[2]), z = c[2], yaw = 0 }) end
  local function add(id, x, z, yaw) return ST.addPart(sid, { id = id, x = x, y = 0, z = z, yaw = yaw or 0 }) end
  uids.drive = add("qDrive.steel", 8, 0)        -- its discharge at (8, 0.8, 1)
  add("cvBelt2.steel", 8, 2)
  add("cvBelt2.steel", 8, 4)
  uids.hopper = add("lgHopper.steel", 8, 6)    -- in at z 5, out at z 7
  uids.belt3 = add("cvBelt2.steel", 8, 8)
  uids.silo = add("lgSilo.steel", 8, 10.1)     -- in at 9, out at 11.2
  add("cvBelt2.steel", 8, 12.2)                -- 11.2 .. 13.2
  uids.chute = add("lgChute.steel", 8, 13.8)   -- in at 13.2; spout at (8, 1.85, 16)
  -- the quarry's power: four Isotope Skids (2 kW each, day and night) on the same structure
  for k = 0, 3 do ST.addPart(sid, { id = "isotopeSkid", x = -4 + k * 2.2, y = ground_local(-4 + k * 2.2, 18), z = 18, yaw = 0 }) end
  ST.spawnNow(sid)
  wait(2.0)
  -- the network
  local w = wait_for(function() local ww = LX.worldOf(b.name); return ww and ww.net and #ww.net.lines >= 3 and ww end, 15, "the network")
  if not QX.check("net", w ~= nil, "logistics built the world's network") then QX.result() return end
  P("QX NET: %d nodes, %d lines", #w.net.nodes, #w.net.lines)
  for li, L in ipairs(w.net.lines) do
    local ups, downs = {}, {}
    for _, i in ipairs(L.ups) do ups[#ups + 1] = w.net.nodes[i].key end
    for _, i in ipairs(L.downs) do downs[#downs + 1] = w.net.nodes[i].key end
    P("QX LINE %d: %s cap %.0f ok %s why %s · %s → %s (%d pieces)", li, L.kind, L.cap, tostring(L.ok), tostring(L.why), table.concat(ups, ","), table.concat(downs, ","), #L.pieces)
  end
  QX.check("lines", #w.net.lines == 3, "three lines: drive → hopper → silo → chute")
  -- the survey
  local e = wait_for(function() local q = LX.quarryOf(sid, uids.drive); return q and q.q and q end, 30, "the survey")
  if not QX.check("survey", e ~= nil, "the quarry is surveyed (guard %s, refused %s)", tostring(LX.quarryOf(sid, uids.drive) and LX.quarryOf(sid, uids.drive).guard), tostring(LX.quarryOf(sid, uids.drive) and LX.quarryOf(sid, uids.drive).refused)) then
    QX.state("nosurvey", LX, ST, sid, uids)
    QX.result() return
  end
  do
    local nx, nz, per, layers, total = Q.cells(e.q)
    local m = {}
    for k = 1, math.min(6, #e.q.mix) do
      local L = e.q.mix[k]
      local parts = {}
      for mt, s in pairs(L.comp) do parts[#parts + 1] = string.format("%s %.2f", mt, s) end
      m[#m + 1] = string.format("L%d air %.2f hard %.2f [%s]", k, L.air, L.hard, table.concat(parts, " "))
    end
    P("QX SURVEY: %d × %d cells, %d layers, %d cells, ytop %.2f · %s", nx, nz, layers, total, e.q.ytop or 0, table.concat(m, " · "))
  end
  -- 4. the rover on the stand, commissioned
  local hold = nil
  if des then
    local bp = CS.readDesign(des.slug)
    bp.name = "Chute Mule"
    local okp, wp = CS.putOn(ssid, 1, bp, { name = "Chute Mule" })
    wait(1.0)
    QX.check("put", okp, "the rover trucked onto the stand (%s)", tostring(wp))
    local okc, wc = CS.commission(ssid, 1)
    local E = wait_for(function() local x = CS.heldOf(ssid, 1); return x and x.phase == "held" and x end, 25, "commissioned")
    QX.check("commission", okc and E ~= nil, "commissioned (%s)", tostring(wc))
    hold = "hold:Chute Mule"
  end
  -- 5. live: the first digs and their yields (YIELD_K, measured)
  local ys0 = { removed = MF.yieldStats.removed, reports = MF.yieldStats.reports }
  local c0 = perf.counts() or {}
  local seq0 = inv.moveSeq or 0
  QX.state("start", LX, ST, sid, uids, hold)
  local run1 = QX.cost("running: the quarry digging live, three lines", 6)
  wait(14)
  QX.state("live 20 s", LX, ST, sid, uids, hold)
  QX.check("live", e.live == true and (e.dug or 0) >= 4, "the head digs live (%s cells dug)", tostring(e.dug))
  do
    local n = MF.yieldStats.reports - ys0.reports
    local rem = MF.yieldStats.removed - ys0.removed
    local cells = math.max(1, e.dug or 1)
    P("QX YIELD: %d reports, %.3f removed (yield units) over %d cells = %.3f a cell (a cell is %.3f m³; the ball %.3f m³) → YIELD_K ≈ %.3f",
      n, rem, cells, rem / cells, Q.CELL_VOL, 4 / 3 * math.pi * Q.DIG_R ^ 3, rem / cells / Q.CELL_VOL)
    local vs = {}
    for m, v in pairs(MF.yieldStats.units) do vs[#vs + 1] = m .. " " .. v end
    P("QX YIELD units so far: %s", table.concat(vs, ", "))
  end
  -- shots: the gantry and the pit's start, the belts, the chute over the stand
  QX.view("q1_quarry_live", rec, { -12, 9, -14 }, { 0, -1, 0 })
  QX.view("q2_belts_hopper", rec, { 12.5, 2.6, 1.5 }, { 8, 0.9, 6 })
  QX.view("q3_silo_chute_stand", rec, { 14, 4.5, 9 }, { 8, 1.5, 15 })
  QX.state("belt shot", LX, ST, sid, uids, hold)
  QX.view("q2b_belt_load_close", rec, { 9.6, 1.6, 2.6 }, { 8, 0.8, 4.4 })
  -- 6. ×20: the pit goes down, the lines carry
  space.warp(20)
  local t0 = time
  while time - t0 < 40 do
    if space.warpFactor and space.warpFactor() < 20 then space.warp(20) end
    wait(1)
  end
  space.warp(1)
  wait(1.5)
  local s1 = QX.state("after ×20 for 40 s", LX, ST, sid, uids, hold)
  local c1 = perf.counts() or {}
  P("QX FIELD: fieldEdited %s → %s, fieldChunks %s → %s", tostring(c0.fieldEdited), tostring(c1.fieldEdited), tostring(c0.fieldChunks), tostring(c1.fieldChunks))
  QX.check("deeper", (e.prog or 0) > 64 and (e.dug or 0) >= math.floor(e.prog) - 3, "progress %.1f cells (> a layer), dug %s keeps up", e.prog or 0, tostring(e.dug))
  local moved = { bin2hop = 0, hop2silo = 0, silo2hold = 0 }
  for _, mv in ipairs(inv.movesSince(seq0) or {}) do
    if mv.from == "hopper:" .. sid .. "." .. uids.drive and mv.to == "hopper:" .. sid .. "." .. uids.hopper then moved.bin2hop = moved.bin2hop + mv.n end
    if mv.from == "hopper:" .. sid .. "." .. uids.hopper and mv.to == "silo:" .. sid .. "." .. uids.silo then moved.hop2silo = moved.hop2silo + mv.n end
    if hold and mv.from == "silo:" .. sid .. "." .. uids.silo and mv.to == hold then moved.silo2hold = moved.silo2hold + mv.n end
  end
  P("QX MOVES (the ring): bin → hopper %d, hopper → silo %d, silo → hold %d", moved.bin2hop, moved.hop2silo, moved.silo2hold)
  QX.check("carried", moved.bin2hop > 0 and moved.hop2silo > 0, "the belts carried units bin → hopper → silo")
  QX.check("chute", hold == nil or moved.silo2hold > 0 or (inv.mass(hold) or 0) > 0, "the chute filled the stand's craft from the silo (%d units, hold %.0f kg)", moved.silo2hold, hold and inv.mass(hold) or 0)
  local run2 = QX.cost("running after ×20", 4)
  -- (back to daylight for the pictures: the quarry digs on through the warp)
  BK.daylight(unit(O), 120)
  QX.state("daylight", LX, ST, sid, uids, hold)
  QX.view("q4_pit_after_warp", rec, { -13, 8, -13 }, { 0, -3, 0 })
  QX.view("q5_pit_other_side", rec, { -15, 10, 3 }, { 0, -4, 0 })
  -- 7. the overlay
  LX.overlay, LX.overlayAlways = true, true
  QX.view("q7_logistics_overlay", rec, { 4, 24, -12 }, { 5, 0, 6 }, true)
  QX.view("q8_overlay_other_angle", rec, { -4, 10, 22 }, { 6, 0, 6 }, true)
  local ov = QX.cost("overlay on", 3)
  QX.check("overlay", LX.drawn.lines >= 8 and LX.drawn.labels >= 3, "the overlay draws %d lines and %d labels", LX.drawn.lines, LX.drawn.labels)
  LX.overlay, LX.overlayAlways = false, false
  -- 8. a belt switched off: its line stalls, with its reason
  LX.setRun(sid, uids.belt3, false)
  wait(1.5)
  local o3 = LX.readout(sid, uids.belt3) or {}
  QX.check("off", o3.line and not o3.line.ok and tostring(o3.lim):find("switched off"), "belt off: %s", tostring(o3.lim))
  LX.setRun(sid, uids.belt3, true)
  wait(1.0)
  -- 9. away: 2 km off, ×20: the estimate; back: the catch-up
  -- (the hopper and the bin emptied first: the silo takes only the first
  -- material, so the rest has filled the hopper and stopped the quarry)
  inv.clear("hopper:" .. sid .. "." .. uids.hopper)
  inv.clear("hopper:" .. sid .. "." .. uids.drive)
  wait(1.0)
  -- ("away": the live radius shrunk under the crew's distance, so the same
  -- code path runs as for a crew 2 km off; teleports drop the walker into its
  -- recovery and land it back by the quarry)
  local liveR = LX.LIVE_R
  LX.LIVE_R = 10
  wait_for(function() return e.live == false end, 20, "away from the quarry"); wait(1)
  local pAway, dugAway = e.prog, e.dug
  QX.check("away", e.live == false, "out of reach (LIVE_R shrunk to 10 m) the quarry is not live (dist %.0f m)", e.dist or -1)
  space.warp(20)
  local t1 = time
  while time - t1 < 25 do if space.warpFactor and space.warpFactor() < 20 then space.warp(20) end wait(1) end
  space.warp(1)
  wait(1)
  QX.state("away ×20", LX, ST, sid, uids, hold)
  QX.check("estimate", (e.prog or 0) > pAway and e.dug == dugAway and (e.paid or 0) >= math.floor(e.prog) - 1, "away: progress %.1f → %.1f by the estimate, nothing dug (%s), paid %s", pAway, e.prog or 0, tostring(e.dug), tostring(e.paid))
  local idleAway = QX.cost("away 2 km (the network steps, nothing drawn)", 3)
  local c2 = LX.PROF.catch
  LX.LIVE_R = liveR
  wait_for(function() return e.live == true end, 40, "back at the quarry")
  wait(8)
  QX.state("back, catching up", LX, ST, sid, uids, hold)
  QX.check("catchup", LX.PROF.catch > c2 and e.live, "back: the catch-up digs the claimed cells (%d catch-up digs in 8 s, dug %s of %.1f)", LX.PROF.catch - c2, tostring(e.dug), e.prog or 0)
  -- 10. idle: the quarry paused, the lines run dry
  LX.setPaused(sid, uids.drive, true)
  wait(20)
  local idle1 = QX.cost("quarry paused, lines dry", 4)
  LX.setPaused(sid, uids.drive, false)
  P("QX COSTS: no pieces %.4f · running live %.4f · after warp %.4f · overlay on %.4f · away %.4f · paused/dry %.4f (logistics ms/frame)", idle0, run1, run2, ov, idleAway, idle1)
  QX.result()
end
