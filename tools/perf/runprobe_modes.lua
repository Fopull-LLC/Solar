-- ── runs probe (tools/perf/runprobe.sh; expansion X3, "Runs I") ─────────────
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam),
-- buildkitprobe_modes.lua and standeditprobe_modes.lua (the stand helpers).
--   runs   the VAB's rover with a Cargo Bay saved to the library; a Build
--          Stand 150+ m out; the rover trucked onto it and commissioned;
--          FLIGHT 1: released, driven off over the comms link (no crew
--          aboard: a probe run), stopped 40 m out, 20 iron dug by hand put in
--          its hold, back to the stand, Return → REFUSED with the reason
--          (the stand's menu: "Why it can't be automated"); FLIGHT 2:
--          commissioned again, released, out to the Depot's supply crate (a
--          stop), 25 iron from the crate through the pack into the hold,
--          back, Return → automatable (the discovery hint), Automate from
--          the stand's menu: the Intake takes what it brought, the craft is
--          drawn on its stand for the dwell and gone on the legs; ×100 warp
--          for cycles (the crate down 25 a cycle, the warehouse up 25, RP);
--          the Tracking Station's RUNS entry, card and NEXT events (shots);
--          the cost per frame (route_ops, fleet_view, craft_stand) idle and
--          with a run; pause / resume; save and reload mid-run (it carries
--          on from the agency clock); the flight record's `at` (the respawn
--          clock fix); cancel.
-- `RN PASS|FAIL <check>` lines and `RN RESULT`. Pictures: save/user/runshots/.
RN = { fails = 0, passed = 0 }
function RN.check(name, okc, fmt, ...)
  P("RN %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then RN.passed = RN.passed + 1 else RN.fails = RN.fails + 1 end
  return okc
end
function RN.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://runshots/" .. nm .. ".png", bytes); P("RN SHOT %s", nm)
    else P("RN SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- warp ×w for `secs` real seconds, asking again whenever the engine drops it
-- (a body settling near the ground puts it to ×1)
function RN.warp_for(secs, w, stop)
  local t0 = time
  local held, n, ag0 = 0, 0, findScript("route_ops") and findScript("route_ops").agencyNow() or 0
  space.warp(w)
  while time - t0 < secs do
    yield()
    n = n + 1
    if space.warp() >= w then held = held + 1 end
    if stop and stop() then break end
    if space.warp() < w then space.warp(w) end
  end
  space.warp(1)
  local ag1 = findScript("route_ops") and findScript("route_ops").agencyNow() or 0
  P("RN warp x%d for %.1f s: held %d of %d frames, the agency clock +%.0f s", w, time - t0, held, n, ag1 - ag0)
end
function RN.result() P("RN RESULT %d passed, %d failed", RN.passed, RN.fails) end

-- a fixed camera off a planet-relative point (the stand), `back` along -F
function RN.view(nm, w, U, F, back, side, up, ui)
  -- (w is body-relative: a world point kept from an earlier frame is metres
  -- off by now — docs/positions-and-frames.md rule 1)
  local Rr = unit(cross(F, U))
  local eye = { x = w.x - F.x * back + Rr.x * side + U.x * up, y = w.y - F.y * back + Rr.y * side + U.y * up, z = w.z - F.z * back + Rr.z * side + U.z * up }
  VP.cam_fixed(eye, { x = w.x + U.x * 0.6, y = w.y + U.y * 0.6, z = w.z + U.z * 0.6 })
  wait(1.0)
  RN.shot(nm, ui)
  VP.cam_off()
  wait(0.2)
end

-- the player's camera framed on the stand (planet_camera's framed shot: not
-- the free camera, which hides the interface and closes menus), placed each
-- frame from the body-relative deck top against this frame's body
function RN.menu_cam(TR, U, F)
  local pc = findScript("planet_camera")
  if not (pc and pc.setShot) then return end
  local Rr = unit(cross(F, U))
  pc.setShot(function()
    local b = home()
    local e = { x = TR.x - F.x * 6 + Rr.x * 3 + U.x * 2.2, y = TR.y - F.y * 6 + Rr.y * 3 + U.y * 2.2, z = TR.z - F.z * 6 + Rr.z * 3 + U.z * 2.2 }
    return b.x + e.x, b.y + e.y, b.z + e.z, b.x + TR.x, b.y + TR.y, b.z + TR.z, U.x, U.y, U.z
  end, 0.05)
  wait(1.0)
end
function RN.menu_cam_off() local pc = findScript("planet_camera"); if pc and pc.clearShot then pc.clearShot(0.05) end; wait(0.3) end

-- the rover's controller and node on the stand once commissioned
function RN.held(CS, sid)
  local E = wait_for(function() local e = CS.heldOf(sid, 1); return e and e.phase == "held" and e end, 25, "commissioned")
  wait(1.0)
  return E, E and BK.ctl_of(E.node), E and E.node
end
-- put the rover down at a body-relative point `rel` (+1 m up), still
function RN.hop(vn, rel)
  local b = home()
  local U = unit(rel)
  assembly.teleport(vn, vec3(b.x + rel.x + U.x * 1.2, b.y + rel.y + U.y * 1.2, b.z + rel.z + U.z * 1.2))
  wait(0.5)
  wait_for(function()
    local i = assembly.info(vn)
    return i and len(i.vel.x, i.vel.y, i.vel.z) < 0.15
  end, 15, "the rover to settle")
end
-- a ground point `d` m from planet-relative `p` along `F` (on the ground)
function RN.ground_at(p, F, d)
  local b = home()
  local q = { x = p.x + F.x * d, y = p.y + F.y * d, z = p.z + F.z * d }
  local U = unit(q)
  local o = { x = b.x + q.x + U.x * 20, y = b.y + q.y + U.y * 20, z = b.z + q.z + U.z * 20 }
  local h = raycast(o.x, o.y, o.z, -U.x, -U.y, -U.z, 60, { ignore = astro() })
  if h then return { x = h.x - b.x, y = h.y - b.y, z = h.z - b.z } end
  return q
end
-- the astronaut to a body-relative point (+1 m)
function RN.walk_to(rel)
  local a, b = astro(), home()
  local U = unit(rel)
  a.x, a.y, a.z = b.x + rel.x + U.x * 1.0, b.y + rel.y + U.y * 1.0, b.z + rel.z + U.z * 1.0
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(1.0)
end
-- the stand's menu entries (BK.menu), and the menu opened on screen
function RN.menu_open(ST, sid)
  local cm = findScript("context_menu")
  local ents, tgt = BK.menu(ST.nodeOf(sid, 1))
  if cm and tgt then cm.openFor(tgt, cm.actorNow(), 760, 300) end
  wait(0.8)
  return ents, tgt, cm
end
function RN.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  P("RN COST %s: route_ops %.4f ms/frame, routes %.4f, fleet_view %.4f, tracking_station %.4f, craft_stand %.4f, inventory %.4f", tag,
    ms("route_ops"), ms("routes"), ms("fleet_view"), ms("tracking_station"), ms("craft_stand"), ms("inventory"))
  return ms("route_ops")
end

local RUN_ROVER = nil
function RN.rover_bp()
  if RUN_ROVER then return RUN_ROVER end
  local l = {}
  for i, d in ipairs(ROVER) do l[i] = d end
  -- a Cargo Bay behind the seat (250 kg)
  l[#l + 1] = rec(7, "cargo", -0.85, 0.62 + 0.15 + 0.6, 0, { parent = 1, att = "top" })
  RUN_ROVER = l
  return l
end

-- one flight from the stand: commission, release, out to `stop` (a
-- body-relative ground point), `load()` there, back beside the stand, Return.
function RN.fly(CS, ST, sid, stop, load, tag)
  local okc, wc = CS.commission(sid, 1)
  local E, vc, vn = RN.held(CS, sid)
  RN.check(tag .. "_commission", okc and E and vc ~= nil, "commissioned (%s)", tostring(wc))
  if not (E and vc) then return false end
  CS.release(sid, 1)
  local gone = wait_for(function() return CS.heldOf(sid, 1) == nil end, 30, "the release")
  wait(1.5)
  RN.check(tag .. "_release", gone ~= nil and vn.valid, "released onto its wheels")
  -- over the comms link: nobody aboard (a probe run)
  local remote = vc.remoteControl and vc.remoteControl()
  P("RN remote control: %s (piloting %s, crew aboard %s)", tostring(remote), tostring(vc.piloting), tostring(vc.crewAboard))
  if remote and vc.R2 then
    local t0 = time
    while time - t0 < 6 do vc.R2.cmd = { drive = 1, steer = 0 }; yield() end
    BK.stop_rover(vc, vn)
    vc.R2.cmd = nil
  end
  -- (the rest of the drive out is a hop: the log sees a craft that moved
  -- and came to rest; the probe's clock is short)
  RN.hop(vn, stop)
  wait(STOP_WAIT or 7)
  local RO = findScript("route_ops")
  local L = RO.liveLog(vc.craftName)
  RN.check(tag .. "_stop", L and #L.stops >= 1, "a stop logged where it came to rest (%d stops, open %s)", L and #L.stops or -1, tostring(L and L.open))
  load(vc, vn)
  wait(1.0)
  -- back beside the stand
  local top, U, n, fp = BK.stand_top(ST, CS, sid)
  local G = fp.G
  local side = { x = G.x + fp.F.x * 2.6, y = G.y + fp.F.y * 2.6, z = G.z + fp.F.z * 2.6 }
  RN.hop(vn, side)
  wait(2.0)
  if vc.releaseControl then pcall(vc.releaseControl) end
  local s2, u2 = CS.standFor(vc)
  local okr, wr = CS.returnTo(vc, sid, 1)
  wait(1.5)
  RN.check(tag .. "_return", okr, "returned to its stand (standFor %s, %s)", tostring(s2), tostring(wr))
  return okr
end

function RN.run()
  wait_ready(120)
  wait(2)
  local ST, CS, C, co, inv = findScript("structures"), findScript("craft_stand"), findScript("crew"), findScript("company"), findScript("inventory")
  local RO, RT = findScript("route_ops"), findScript("routes")
  if not RN.check("scene", ST and CS and C and RO and RT and inv, "route_ops %s routes %s", tostring(RO ~= nil), tostring(RT ~= nil)) then RN.result() return end
  local idle0 = RN.cost("idle, no runs, nothing logged", 3)
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  -- 1. the rover into the library
  local BH = enter_vab("run_vab")
  local B = findScript("builder")
  if BH and B then
    wait(1.0)
    load_bp(B, "run_rover_bp", RN.rover_bp())
    B.craftSave("Run Mule")
    wait(1.0)
    BH.leave(); wait(3)
  end
  local des
  for _, d in ipairs(CS.designs()) do if d.name == "Run Mule" then des = d end end
  if not RN.check("library", des ~= nil, "the rover with its Cargo Bay is in the library") then RN.result() return end
  -- 2. a stand out on flat ground (placed as the kit places it)
  local spot = BK.flat_spot()
  if not RN.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then RN.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  local b = home()
  local G = { x = spot.dir.x * spot.r, y = spot.dir.y * spot.r, z = spot.dir.z * spot.r }
  -- (the kit's placement path, as buildkitprobe's stand mode: face along the
  -- bearing, B, the stand's card, aim, click)
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
  if cp then cp.pickPart("stand") end
  BK.aim_at(8, 0); BK.settle(30)
  BK.click(false); wait(1.5)
  local sid = fb and fb.lastPlace and fb.lastPlace.sid
  if fb then fb.heldPart = nil end
  tap("escape"); wait(0.5)
  if not RN.check("stand", sid ~= nil and ST.getPart(sid, 1) ~= nil, "a Build Stand placed (sid %s)", tostring(sid)) then RN.result() return end
  local bp = CS.readDesign(des.slug)
  bp.name = "Run Mule"
  local okp, wp = CS.putOn(sid, 1, bp, { name = "Run Mule" })
  wait(1.0)
  RN.check("put", okp, "the rover trucked onto the stand (%s)", tostring(wp))
  local _, U, _, fp = BK.stand_top(ST, CS, sid)
  local F = fp.F
  local TR = fp.top      -- the deck's top, body-relative
  local hold = "hold:Run Mule"
  -- FLIGHT 1: the ore dug by hand → refused for a probe run
  local stop1 = RN.ground_at(fp.G, F, 70)
  RN.fly(CS, ST, sid, stop1, function(vc, vn)
    RN.walk_to(RN.ground_at(stop1, unit(cross(F, U)), 3))
    inv.add("astro", "iron", 20)                     -- (dug by hand: a pack load with no store behind it)
    local n = inv.transfer("astro", hold, "iron", 20)
    if vc.holdApplyMass then vc.holdApplyMass(vn) end
    P("RN flight 1: %d iron dug and put in the hold", n)
  end, "f1")
  local lr = CS.lastReturn
  RN.check("f1_refused", lr and lr.auto == false and tostring(lr.why):find("crew's pack") ~= nil, "refused: %s", tostring(lr and lr.why))
  RN.walk_to(RN.ground_at(fp.G, unit(cross(F, U)), -4)); wait(2.0)
  RN.menu_cam(TR, U, F)
  local ents, tgt, cm = RN.menu_open(ST, sid)
  local auto, why = BK.entry(ents, "rn_auto"), BK.entry(ents, "rn_why")
  local reg = findScript("context_registry")
  RN.check("f1_menu", auto ~= nil and not reg.usable(auto) and why ~= nil, "the stand's menu: Automate greyed, 'Why it can't be automated' (%d rows)", #ents)
    RN.shot("r1_menu_refused")
  if why and cm then cm.handle(why); wait(0.6); RN.shot("r2_why_refused") end
  if cm then cm.close() end
  RN.menu_cam_off()
  -- the hold back to empty for flight 2 (to the warehouse by hand)
  inv.transfer(hold, "base", "iron", 1000)
  -- FLIGHT 2: from the Depot's supply crate
  local sc = findScript("supply_crates")
  local crate = nil
  for _, c in ipairs(sc and sc.list() or {}) do if c.id == 1 then crate = c end end
  local cw = crate and crate.node and crate.node.valid and crate.node.worldPos
  RN.check("crate", cw ~= nil, "Depot crate A in the scene")
  if not cw then RN.result() return end
  inv.add("crate:1", "iron", 400)        -- (the crate holds 400 kg)
  local crel = sub(cw, home())
  local cU = unit(crel)
  local away = unit(sub(sub(G, crel), scl(cU, dot(sub(G, crel), cU))))
  local stop2 = RN.ground_at(crel, away, 6)
  RN.fly(CS, ST, sid, stop2, function(vc, vn)
    RN.walk_to(RN.ground_at(crel, away, 2.0))
    local a1 = inv.transfer("crate:1", "astro", "iron", 25)
    local a2 = inv.transfer("astro", hold, "iron", 25)
    RN.loaded = a2
    if vc.holdApplyMass then vc.holdApplyMass(vn) end
    P("RN flight 2: %d iron from the crate into the pack, %d into the hold", a1, a2)
    local vU = unit(crel)
    VP.cam_fixed({ x = crel.x + away.x * 12 + vU.x * 4, y = crel.y + away.y * 12 + vU.y * 4, z = crel.z + away.z * 12 + vU.z * 4 }, crel)
    wait(1.0)
    RN.shot("r3_stop_at_crate")
    VP.cam_off()
  end, "f2")
  lr = CS.lastReturn
  RN.check("f2_automatable", lr and lr.auto == true, "automatable (%s)", tostring(lr and lr.why))
  RN.walk_to(RN.ground_at(fp.G, unit(cross(F, U)), -4)); wait(2.0)
  RN.menu_cam(TR, U, F)
  ents, tgt, cm = RN.menu_open(ST, sid)
  auto = BK.entry(ents, "rn_auto")
  local can = BK.entry(ents, "rn_can")
  RN.check("f2_menu", auto ~= nil and reg.usable(auto) and can ~= nil, "Automate enabled: %s", auto and tostring(auto.value and (type(auto.value) == "function" and auto.value() or auto.value)) or "-")
    RN.shot("r4_menu_automate")
  local rp0 = findScript("research") and findScript("research").points and findScript("research").points() or 0
  local base0 = inv.count("base", "iron")
  local crate0 = inv.count("crate:1", "iron")
  local okA = cm and cm.handle(auto)
  wait(1.0)
  if cm then cm.close() end
  RN.menu_cam_off()
  local runs = RO.list()
  local r = runs[1]
  RN.check("automate", okA and r ~= nil and CS.stateOf(sid, 1).s == "run", "Automate: %s (%s)", r and r.name or "-", r and RO.summaryOf(r) or "-")
  if not r then RN.result() return end
  local K = RN.loaded or 25
  RN.check("intake_first", inv.count("base", "iron") == base0 + K and inv.count(hold, "iron") == 0,
    "the Intake took the " .. K .. " it brought (warehouse %d → %d, RP +%d)", base0, inv.count("base", "iron"),
    (findScript("research").points() or 0) - rp0)
  wait(1.0)
  RN.check("dwell_drawn", find("StandCraft") ~= nil, "drawn on its stand for the dwell")
  RN.view("r5_dwell_on_stand", TR, U, F, 5.5, 3.0, 1.6, false)
  local cost1 = RN.cost("one run, on the stand", 4)
  -- 3. cycles under warp
  -- (x10 until a leg is seen: at x100 a leg passes between two of the
  -- run's 1 Hz steps; then x100)
  space.warp(10)
  local away_seen, t0 = false, time
  local wlog = -10
  while time - t0 < 60 do
    yield()
    local want = away_seen and 100 or 10
    if space.warp() < want then
      space.warp(want)
      if time - wlog > 3 then wlog = time; local wc = findScript("warp_chip"); P("RN warp re-asked (%s)", tostring(wc and wc.lastWhy)) end
    end
    local rr = RO.get(r.id)
    if rr and rr.phases[rr.ph].k == "leg" and not away_seen and find("StandCraft") == nil then
      away_seen = true
      space.warp(1); wait(0.5)
      RN.view("r6_stand_empty_on_leg", TR, U, F, 5.5, -3.0, 1.6, false)
    end
    if rr and (rr.cycles or 0) >= 3 then break end
  end
  space.warp(1); wait(1.0)
  r = RO.get(r.id)
  RN.check("away_on_leg", away_seen, "the stand empty while the run is out on a leg")
  RN.check("cycles", (r.cycles or 0) >= 2, "%d cycles in %.0f s of ×100 (%.0f s a cycle)", r.cycles or 0, time - t0, r.dur or 0)
  local crate1, base1 = inv.count("crate:1", "iron"), inv.count("base", "iron")
  local loads = r.cycles + ((r.ph > 3) and 1 or 0)
  RN.check("exact", crate0 - crate1 == K * loads and base1 - (base0 + K) == K * r.cycles,
    "each cycle exactly as flown: crate −%d (%d loads), warehouse +%d (%d cycles), %d RP from the runs", crate0 - crate1, loads,
    base1 - base0 - K, r.cycles, math.floor(r.rp or 0))
  -- 4. the Tracking Station
  local ts, fv, om = findScript("tracking_station"), findScript("fleet_view"), findScript("orbit_map")
  tap("f2"); wait(1.5)
  local S = fv.snapshot(true)
  local e = S.byId["R:" .. r.id]
  RN.check("station_entry", e ~= nil and e.group == "RUNS" and e.kind == "route", "the RUNS entry: %s · %s", e and e.name or "-", e and e.sub or "-")
  ts.selectCraft("R:" .. r.id)
  if om and om.setZoom then
    om.focusOn(function() local bb = home(); return bb.x + TR.x, bb.y + TR.y, bb.z + TR.z, "stand" end)
    om.setZoom(1500)
  end
  space.warp(10)
  wait(3.0)
  RN.shot("r7_station_card")
  local evs = RO.events()
  RN.check("next_events", #evs >= 2 and evs[1].id == "R:" .. r.id, "NEXT: %s in %.0f s", evs[1] and evs[1].what or "-", evs[1] and evs[1].t or -1)
  local cost2 = RN.cost("one run, the station open", 3)
  -- on a leg: the icon along its path and the dashed track (two zooms)
  RN.warp_for(40, 5, function()
    local x = RO.get(r.id)
    local ph = x and x.phases[x.ph]
    return ph and ph.k == "leg" and ph.dur > 20 and (x.t0 + ph.dur - RO.agencyNow()) > ph.dur * 0.5
  end)
  wait(1.0)
  local el = RO.get(r.id)
  RN.check("station_leg", el and el.phases[el.ph].k == "leg", "on a leg in the station: %s", el and RO.situationOf(el) or "-")
  RN.shot("r8_station_leg")
  if om and om.setZoom then om.setZoom(400) end
  wait(1.5)
  RN.shot("r9_station_leg_close")
  space.warp(1)
  tap("f2"); wait(1.0)
  -- 5. pause / resume
  RO.pauseRun(r.id)
  local ph0 = RO.get(r.id).ph
  RN.warp_for(3, 100)
  RN.check("pause", RO.get(r.id).state == "paused" and RO.get(r.id).ph == ph0, "paused: nothing moves under warp")
  RO.resumeRun(r.id)
  RN.check("resume", RO.get(r.id).state ~= "paused", "resumed")
  local cost3 = RN.cost("one run, in play (station shut)", 4)
  -- 6. the respawn clock fix: the craft's last fleet record carries `at`
  local f = save.get("fleet.craft") or {}
  local with_at = 0
  for _, rc in pairs(f) do if type(rc) == "table" and type(rc.at) == "number" then with_at = with_at + 1 end end
  P("RN fleet records with the agency clock: %d", with_at)
  -- a store run dry: the run WAITS and says so; the player refills the
  -- crate and it goes on (never a failure)
  local tank = inv.count("crate:1", "iron")
  RN.warp_for(40, 100, function() local x = RO.get(r.id); return x and x.state == "waiting" end)
  local wr = RO.get(r.id)
  RN.check("waiting", wr.state == "waiting" and tostring(wr.why):find("Depot crate A") ~= nil,
    "the crate ran dry (%d left before): %s", tank, tostring(wr.why))
  tap("f2"); wait(1.0)
  ts.selectCraft("R:" .. r.id); wait(1.5)
  RN.shot("r10_station_waiting")
  tap("f2"); wait(0.5)
  inv.add("crate:1", "iron", 400)
  wait(2.5)
  RN.check("refilled", RO.get(r.id).state == "run", "refilled: the run goes on (%s)", RO.situationOf(RO.get(r.id)))
  -- 7. save and reload mid-run
  local c_before = RO.get(r.id).cycles
  local ag0 = RO.agencyNow()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(10)
  RO = findScript("route_ops")
  local r2 = RO and RO.get(r.id)
  RN.check("reload", r2 ~= nil and r2.cycles >= c_before and CS and findScript("craft_stand").stateOf(sid, 1).s == "run",
    "after a reload the run carries on: cycle %s (was %d), agency clock %.0f → %.0f", r2 and tostring(r2.cycles) or "-", c_before, ag0, RO and RO.agencyNow() or -1)
  RN.warp_for(45, 100, function() local x = RO.get(r.id); return x and x.cycles > c_before end); wait(1)
  r2 = RO.get(r.id)
  if r2 then
    P("RN after reload: state %s why %s ph %s/%d t0 %.0f now %.0f dur %.0f tick %.4f ms runs %s", tostring(r2.state), tostring(r2.why),
      tostring(r2.ph), #r2.phases, r2.t0 or -1, RO.agencyNow(), r2.phases[r2.ph] and r2.phases[r2.ph].dur or -1,
      RO.stats.tick_ms or -1, tostring(RO.stats.runs))
  end
  RN.check("after_reload_cycles", r2 and r2.cycles > c_before, "…and cycles on: %d", r2 and r2.cycles or -1)
  -- 8. cancel (on the stand: at once; on the way: when it is back)
  local okc, how = RO.cancelRun(r.id)
  if how ~= "now" then
    RN.warp_for(45, 100, function() return RO.get(r.id) == nil end)
  end
  wait(1.0)
  local st = findScript("craft_stand").stateOf(sid, 1)
  RN.check("cancel", RO.get(r.id) == nil and st and st.s == "built", "cancelled (%s): the craft is the stand's again (%s)", tostring(how), st and st.s or "-")
  P("RN COSTS: idle %.4f ms, a run on the stand %.4f, the station open %.4f, in play %.4f (route_ops ms/frame)", idle0, cost1, cost2, cost3)
  RN.result()
end
