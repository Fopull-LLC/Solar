-- ── control-mode probe (tools/perf/ctrlprobe.sh): "landing gear as a rover wheel, rover wheels as a plane's gear" (playtest 2026-10-26) ──
-- The craft's MODE (scripts/craft_mode.lua) says what its wheels do, not the
-- wheels' part type. Modes:
--   ctrlrover      the stock rover with a Landing Gear S added at its nose:
--                  Auto must read a rover; it drives out past 95 m steering
--                  away from the base; then straight, a turn, the gear folded
--                  (the rover drives on its four), the gear down (its tyre is
--                  back), Aircraft forced (W no longer drives), Rocket, Auto
--                  again; Rocket chosen, the fleet saved and the world loaded
--                  again: the restored rover still says Rocket
--   ctrljet        the 27-part jet on its landing gear: Auto reads Aircraft;
--                  Rover forced drives it on its gear with the throttle shut
--                  and steers it; Aircraft forced holds it again
--   ctrljetwheels  the jet with its three landing gears swapped for rover
--                  wheels (two Wheel M, a Wheel S nose): Auto must still read
--                  Aircraft, and it takes off
--   ctrlrevert     in the VAB: the rover on the stand (Auto: Rover, shot),
--                  Aircraft chosen (shot), the craft saved to the library, a
--                  new craft, the saved one opened (the choice comes back),
--                  launched (flies as Aircraft, HUD shot), reverted to launch
--                  (still Aircraft)
-- One `CP PASS|FAIL <check>` line a check and `CP RESULT <mode>: PASS/FAIL`.
-- Pictures (1280×720) in $WORK/proj/save/user/ctrlshots/.
local CP = { fails = 0, tag = "ctrl" }
function CP.check(name, ok, fmt, ...)
  P("CP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then CP.fails = CP.fails + 1 end
  return ok
end
function CP.result()
  P("CP RESULT %s: %s (%d failed check(s))", CP.tag, CP.fails == 0 and "PASS" or "FAIL", CP.fails)
end
function CP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = false }, function(bytes)
    if bytes then assets.writeBytes("user://ctrlshots/" .. CP.tag .. "_" .. nm .. ".png", bytes); P("CP SHOT %s_%s", CP.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function CP.info(vc)
  local ok, i = pcall(vc.ctrlModeInfo)
  return ok and i or {}
end
function CP.state(vc, tag)
  local i, o = CP.info(vc), {}
  for k, w in ipairs(vc.R2.wheels or {}) do
    o[#o + 1] = string.format("#%d%s rs %d out %s tyre %s gnd %s a %.2f steers %s now %.1f", k, w.gear and "g" or "", w.rs or 0, tostring(w.out),
      tostring(w.tyre and w.tyre.valid or false), tostring(w.tyre and w.tyre.valid and w.tyre.grounded or false), w.a or 0,
      tostring(w.steers), w.steerNow or 0)
  end
  P("CP [%s] mode %s set %s auto %s (%s) label %s | live %s why %s driving %s onWheels %s gear %s passive %s | %s", tag, tostring(i.mode),
    tostring(i.set), tostring(i.auto), tostring(i.why), tostring(i.label), tostring(vc.R2.live), tostring(vc.R2.why), tostring(vc.R2.driving),
    tostring(vc.R2.onWheels), tostring(vc.R2.gear), tostring(vc.R2.passive), table.concat(o, " | "))
  return i
end
function CP.up(vn)
  local i = assembly.info(vn)
  return unit(sub(i.com, home()))
end
-- drive with the probe's command (R2.cmd: what W/S A/D press) for `secs`:
-- the planet-frame distance, the end speed and the turn (deg, + left)
function CP.drive(vc, vn, drive, steer, secs)
  local i0 = assembly.info(vn)
  local p0 = sub(i0.com, home())
  local yaw, t0, vmax, tl = 0, time, 0, time
  while time - t0 < secs do
    vc.R2.cmd = { drive = drive, steer = steer }
    yield()
    local i = assembly.info(vn)
    if not i then break end
    yaw = yaw + dot(i.angVel, CP.up(vn)) * (time - tl)
    tl = time
    vmax = math.max(vmax, len(i.vel.x, i.vel.y, i.vel.z))
  end
  local i = assembly.info(vn)
  return from_point(vn, p0), i and len(i.vel.x, i.vel.y, i.vel.z) or -1, math.deg(yaw), vmax
end
function CP.stop(vc, vn)
  local t0 = time
  while time - t0 < 6 do
    vc.R2.cmd = { drive = 0, steer = 0 }
    yield()
    local i = assembly.info(vn)
    if i and len(i.vel.x, i.vel.y, i.vel.z) < 0.4 and time - t0 > 1 then break end
  end
end
function CP.gearWheel(vc)
  for _, w in ipairs(vc.R2.wheels or {}) do if w.gear then return w end end
end
function CP.set(vc, m, tag)
  vc.setCtrlMode(m)
  wait(1.5)
  return CP.state(vc, tag or ("set " .. m))
end

-- ── a: the rover with a landing gear at its nose ────────────────────────────
local function run_ctrlrover()
  CP.tag = params.tag or "rover"
  -- a Landing Gear S hung under the rover body's nose, its leg down (+X), its
  -- tyre on the ground with the rover's (the foot at y ≈ 0.27, r 0.25)
  local g = prec("gearS", 1.0, 0.52, 0, { x = 0, y = -1, z = 0 }, NOSE, { parent = 1, att = "surface" })
  g.uid = 7
  ROVER[#ROVER + 1] = g
  local vc, from_base = run_rover({ name = "cp_out", out = 95, secs = 90, stop = true })
  if not vc then CP.check("rollout", false, "no rover"); CP.result(); return end
  local vn = vc.node
  release_all()
  local i = CP.state(vc, "out")
  CP.check("auto_rover", i.mode == "rover" and i.set == nil and i.auto == "rover", "a rover with a landing gear reads %s (%s)", tostring(i.label), tostring(i.why))
  CP.check("drove_out", from_base() > 90, "%.0f m from the base, steered away from it by A/D", from_base())
  local gw = CP.gearWheel(vc)
  CP.check("gear_driven", gw and (gw.rs or 0) ~= 0 and gw.out == true and gw.tyre and gw.tyre.valid,
    "the gear is a driven wheel (rs %s, out %s)", tostring(gw and gw.rs), tostring(gw and gw.out))
  CP.stop(vc, vn)
  local d, v, yaw = CP.drive(vc, vn, 1, 0, 4)
  CP.check("drive", d > 8, "W 4 s: %.1f m, %.1f m/s, turned %.1f deg", d, v, yaw)
  d, v, yaw = CP.drive(vc, vn, 1, 1, 3)
  CP.check("steer", yaw > 20, "W+A 3 s: %.1f m, turned %.1f deg left", d, yaw)
  CP.shot("1gear_down_turning")
  CP.stop(vc, vn)
  -- the gear folds: the rover drives on its four wheels
  vc.partAction(gw.uid, "deployed.off")
  wait(3)
  i = CP.state(vc, "gear folded")
  gw = CP.gearWheel(vc)
  local others = 0
  for _, w in ipairs(vc.R2.wheels) do if not w.gear and w.tyre and w.tyre.valid then others = others + 1 end end
  CP.check("gear_folds", gw and not (gw.tyre and gw.tyre.valid) and not gw.out and vc.R2.live and others == 4,
    "folded: its tyre gone (%s), the rover on its other %d tyres, live %s", tostring(gw and gw.tyre and gw.tyre.valid), others, tostring(vc.R2.live))
  d, v, yaw = CP.drive(vc, vn, 1, 0, 4)
  CP.check("drive_gear_up", d > 8, "W 4 s with the gear up: %.1f m, %.1f m/s", d, v)
  CP.stop(vc, vn)
  d, v, yaw = CP.drive(vc, vn, 1, -1, 3)
  CP.state(vc, "gear up, turning right")
  CP.check("steer_gear_up", yaw < -20, "W+D 3 s with the gear up: %.1f m, turned %.1f deg", d, yaw)
  CP.shot("2gear_up_driving")
  CP.stop(vc, vn)
  d, v, yaw = CP.drive(vc, vn, 1, 1, 3)
  CP.check("steer_gear_up_left", yaw > 20, "W+A 3 s with the gear up: %.1f m, turned %.1f deg", d, yaw)
  CP.stop(vc, vn)
  -- …and comes down: its tyre is back and drives
  vc.partAction(gw.uid, "deployed.on")
  wait(3)
  CP.state(vc, "gear down")
  gw = CP.gearWheel(vc)
  CP.check("gear_deploys", gw and gw.out and gw.tyre and gw.tyre.valid and (gw.rs or 0) ~= 0, "down: its tyre is back and driven")
  d, v = CP.drive(vc, vn, 1, 0, 4)
  CP.check("drive_gear_down", d > 8, "W 4 s with the gear down again: %.1f m, %.1f m/s", d, v)
  CP.stop(vc, vn)
  d, v, yaw = CP.drive(vc, vn, 1, -1, 3)
  CP.check("steer_gear_down_right", yaw < -20, "W+D 3 s with the gear down: %.1f m, turned %.1f deg", d, yaw)
  CP.stop(vc, vn)
  -- AIRCRAFT forced on the rover: free-rolling gear, W is the stick's
  i = CP.set(vc, "aircraft", "forced aircraft")
  CP.shot("3forced_aircraft_hud")
  local allfree = true
  for _, w in ipairs(vc.R2.wheels) do if (w.rs or 0) ~= 0 then allfree = false end end
  d, v = CP.drive(vc, vn, 1, 0, 4)
  CP.check("aircraft_no_drive", i.mode == "aircraft" and i.set == "aircraft" and allfree and not vc.R2.driving and d < 1.5,
    "Aircraft: every wheel free (%s), W drove %.2f m, driving %s", tostring(allfree), d, tostring(vc.R2.driving))
  -- ROCKET: passive wheels, the stick turns it
  i = CP.set(vc, "rocket", "forced rocket")
  d = CP.drive(vc, vn, 1, 1, 3)
  CP.check("rocket_no_drive", i.mode == "rocket" and vc.R2.passive and not vc.R2.driving and d < 1.5, "Rocket: W+A drove %.2f m", d)
  -- AUTO again: a rover
  i = CP.set(vc, "auto", "auto again")
  d, v = CP.drive(vc, vn, 1, 0, 4)
  CP.check("auto_again", i.mode == "rover" and i.set == nil and d > 8, "%s, W 4 s %.1f m", tostring(i.label), d)
  CP.stop(vc, vn)
  -- SAVE AND LOAD: Rocket chosen, the fleet written, the world loaded again
  CP.set(vc, "rocket", "chosen for the save")
  local recs = vc.fleetParts() or { parts = {} }
  local stamped = 0
  for _, r in ipairs(recs.parts) do if r.ctrl == "rocket" then stamped = stamped + 1 end end
  CP.check("records_carry_it", stamped == 2, "%d command part record(s) carry ctrl=rocket (the body and the seat)", stamped)
  local fo = findScript("flight_ops")
  fo.fleetSync()
  save.flush()
  P("CP fleet saved; loading the world again")
  scene.load("system")
  yield()
  local vc2 = wait_for(function()
    for _, v2 in ipairs(findScripts("vessel_controller")) do
      local ii = v2.node and v2.node.valid and assembly.info(v2.node)
      if ii and #ii.parts >= 7 and v2.ctrlModeInfo and CP.info(v2).mode ~= nil then return v2 end
    end
  end, 150, "the rover rebuilt from the fleet")
  if vc2 then
    i = CP.state(vc2, "restored")
    CP.check("save_load", i.set == "rocket" and i.mode == "rocket", "restored from the save: %s", tostring(i.label))
  else
    CP.check("save_load", false, "no restored rover")
  end
  CP.result()
end

-- ── the jet ─────────────────────────────────────────────────────────────────
function CP.launchJet(wheels)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local list = {}
  for _, r in ipairs(plane()) do
    if wheels and (r.id == "gearM" or r.id == "gearS") then
      -- the rover wheel in the gear's place: its axle (+X) across the
      -- craft, its tyre on the ground where the gear's was
      local big = r.id == "gearM"
      local zs = (r.z or 0) >= 0 and 1 or -1
      local nr = prec(big and "wheelM" or "wheelS", r.x, big and 0.4 or 0.25, r.z, { x = 0, y = 0, z = zs }, { x = 0, y = 1, z = 0 },
        { parent = r.parent, att = r.att, sym = r.sym, mir = r.mir })
      nr.uid = r.uid
      r = nr
    end
    local def = pa and pa.PARTS[r.id] or (findScript("parts_registry") and findScript("parts_registry").REG[r.id])
    if def then list[#list + 1] = full(r, def, k) else P("CP NO DEF %s", r.id) end
  end
  save.set("shipyard.blueprint", { parts = list, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#list, 150)
  wait_regrade()
  return vc, #list
end

local function run_ctrljet()
  CP.tag = params.tag or "jet"
  local vc = CP.launchJet(false)
  if not vc then CP.check("rollout", false, "no jet"); CP.result(); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(3)
  local i = CP.state(vc, "on the runway")
  CP.check("auto_aircraft", i.mode == "aircraft" and i.set == nil, "the jet reads %s (%s)", tostring(i.label), tostring(i.why))
  -- ROVER forced: the landing gear drives it, throttle shut
  vc.setThrottle(0)
  i = CP.set(vc, "rover", "forced rover")
  local driven = 0
  for _, w in ipairs(vc.R2.wheels) do if w.gear and (w.rs or 0) ~= 0 then driven = driven + 1 end end
  local d, v = CP.drive(vc, vn, 1, 0, 6)
  CP.check("rover_drives_jet", i.mode == "rover" and driven == 3 and d > 6, "Rover on the jet: %d driven gear, W 6 s with the throttle shut %.1f m, %.1f m/s", driven, d, v)
  local d2, _, yaw = CP.drive(vc, vn, 1, 1, 3)
  CP.check("rover_steers_jet", yaw > 8, "W+A 3 s: %.1f m, turned %.1f deg left", d2, yaw)
  CP.shot("1jet_as_rover")
  CP.stop(vc, vn)
  -- AIRCRAFT forced back: W is the elevator again, nothing drives
  i = CP.set(vc, "aircraft", "forced aircraft")
  d = CP.drive(vc, vn, 1, 0, 4)
  CP.check("aircraft_holds_jet", i.mode == "aircraft" and not vc.R2.driving and d < 1.5, "Aircraft: W 4 s %.2f m (the brakes hold, the jets push it)", d)
  i = CP.set(vc, "auto", "auto")
  CP.check("auto_jet", i.mode == "aircraft" and i.set == nil, "Auto again: %s", tostring(i.label))
  vc.R2.cmd = nil
  CP.result()
end

-- the take-off (perfbench run_plane, trimmed): full throttle, the rudder on
-- the runway's heading, rotate at 40 m/s
local function run_ctrljetwheels()
  CP.tag = params.tag or "jetwheels"
  local vc = CP.launchJet(true)
  if not vc then CP.check("rollout", false, "no jet"); CP.result(); return end
  local vn = vc.node
  local i = CP.state(vc, "on the stand")
  local nwheel, ngear = 0, 0
  for _, w in ipairs(vc.R2.wheels) do if w.gear then ngear = ngear + 1 else nwheel = nwheel + 1 end end
  CP.check("auto_aircraft", i.mode == "aircraft" and i.set == nil and nwheel == 3 and ngear == 0,
    "the jet on %d rover wheels reads %s (%s)", nwheel, tostring(i.label), tostring(i.why))
  local bf = findScript("base_facilities")
  local site = bf and bf.launchSite and bf.launchSite("runway")
  vc.releaseClamps()
  vc.setSAS("stability")
  wait(1)
  CP.state(vc, "released")
  local function st()
    local ii = assembly.info(vn)
    local b = home()
    local rx, up, rz = basis(vn)
    local F = vc.AERO and vc.AERO.frame
    local fn = F and F.n or { x = 0, y = 1, z = 0 }
    local ff = F and F.f or { x = 0, y = 0, z = -1 }
    local function w(v) return { x = rx.x * v.x + up.x * v.y + rz.x * v.z, y = rx.y * v.x + up.y * v.y + rz.y * v.z, z = rx.z * v.x + up.z * v.y + rz.z * v.z } end
    local n, t = w(fn), w(ff)
    local r = cross(n, t)
    local rel = sub(ii.com, b)
    local rr = len(rel.x, rel.y, rel.z)
    local U = scl(rel, 1 / rr)
    local S = { i = ii, U = U, V = len(ii.vel.x, ii.vel.y, ii.vel.z), alt = rr - b.radius,
      theta = math.asin(clamp(dot(n, U), -1, 1)), bank = math.asin(clamp(-dot(r, U), -1, 1)),
      qn = -dot(ii.angVel, cross(t, n)), pr = dot(ii.angVel, n), herr = 0 }
    if site then
      local Ng = unit(cross({ x = site.x, y = site.y, z = site.z }, site.fwd))
      local trk = unit(cross(Ng, U))
      local hn = unit(sub(n, scl(U, dot(n, U))))
      S.herr = math.atan2(dot(cross(hn, trk), U), dot(hn, trk))
    end
    return S
  end
  local t0, ga, air, shot, tl = time, nil, 0, false, time
  local lift = nil
  while time - t0 < 45 do
    yield()
    local dt = time - tl
    tl = time
    if not vn.valid then break end
    local S = st()
    ga = ga or S.alt
    vc.setThrottle(1)
    local yaw = clamp(3.0 * S.herr, -1, 1)
    if S.V < 40 then
      local p = (S.V > 15) and -clamp(3.0 * (D(1) - S.theta) - 1.0 * S.qn, -1, 1) or 0
      vc.AERO.cmd = { p = p, y = yaw, r = clamp(-2.5 * S.bank, -1, 1) }
    else
      vc.AERO.cmd = { p = -clamp(4.0 * (D(11) - S.theta) - 1.6 * S.qn, -1, 1), y = yaw, r = clamp(-2.5 * S.bank - 0.8 * S.pr, -1, 1) }
    end
    if not shot and S.V > 20 then shot = true; CP.state(vc, "rolling 20 m/s"); CP.shot("1rolling") end
    if not vc.R2.onWheels and S.alt > ga + 1.5 and S.V > 30 then air = air + dt else air = 0 end
    if air > 0.6 then lift = { t = time - t0, V = S.V }; break end
  end
  CP.check("takeoff", lift ~= nil, "on rover wheels: airborne after %s s at %s m/s", lift and string.format("%.1f", lift.t) or "-",
    lift and string.format("%.1f", lift.V) or "-")
  if lift then wait(3); CP.state(vc, "climbing"); CP.shot("2airborne") end
  vc.AERO.cmd = nil
  CP.result()
end

-- ── d: the builder's choice, the library, the rollout and the revert ────────
local function run_ctrlrevert()
  CP.tag = params.tag or "revert"
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local BH = enter_vab("cp_enter")
  if not BH then CP.check("vab", false, "no builder"); CP.result(); return end
  local B = findScript("builder")
  wait(1)
  load_bp(B, "cp_bp", ROVER)
  B.select({}, "set")
  local ins = findScript("builder_inspector")
  wait_for(function() local c = B.ctrlMode(); return c and c.ready end, 10, "the craft mode library")
  wait(1.2)
  local c = B.ctrlMode()
  P("CP builder: set %s auto %s (%s) label %s", tostring(c.set), tostring(c.auto), tostring(c.why), tostring(c.label))
  CP.check("builder_auto", c.set == nil and c.auto == "rover" and c.label == "Auto: Rover", "the stand says %s", tostring(c.label))
  CP.shot("1builder_auto")
  B.cmd("setCtrl", { mode = "aircraft" })
  if ins and ins.setTab then ins.setTab("CRAFT") end
  wait(1.2)
  c = B.ctrlMode()
  CP.check("builder_choice", c.set == "aircraft" and c.label == "Aircraft", "chosen: %s", tostring(c.label))
  CP.shot("2builder_chosen_craft_tab")
  -- undo / redo carry it
  B.undoStep()
  local u = B.ctrlMode().set
  B.redoStep()
  CP.check("builder_undo", u == nil and B.ctrlMode().set == "aircraft", "undo: %s, redo: %s", tostring(u), tostring(B.ctrlMode().set))
  -- the craft library: saved, a new craft, the saved one opened again
  B.craftSave("CP Mode Rover")
  wait(1)
  B.craftNew()
  wait(1)
  local cleared = B.ctrlMode().set
  B.craftOpen("CP Mode Rover", "replace")
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #ROVER end, 30, "the saved rover")
  wait(0.5)
  CP.check("library", cleared == nil and B.ctrlMode().set == "aircraft", "new craft: %s; opened again: %s", tostring(cleared), tostring(B.ctrlMode().set))
  if ins and ins.setTab then ins.setTab("INSPECT") end
  -- the rollout
  if B.launchSite and B.launchSite() ~= "runway" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#ROVER, 150)
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2)
  local i = CP.state(vc, "rolled out")
  CP.check("rollout", i.set == "aircraft" and i.mode == "aircraft", "rolled out as %s (Auto would say %s)", tostring(i.label), tostring(i.auto))
  vc.releaseClamps()
  wait(2)
  local d = CP.drive(vc, vc.node, 1, 0, 3)
  CP.check("rollout_controls", not vc.R2.driving and d < 1.5, "the rover as an aircraft: W drove %.2f m", d)
  CP.shot("3flight_hud")
  local vs = findScript("vessel_spawner")
  local okr, why = vs.revertToLaunch()
  P("CP revert: %s %s", tostring(okr), tostring(why))
  local vc2 = wait_craft(#ROVER, 120)
  if vc2 then
    wait(2)
    i = CP.state(vc2, "reverted")
    CP.check("revert", okr and i.set == "aircraft" and i.mode == "aircraft", "after the revert: %s", tostring(i.label))
  else
    CP.check("revert", false, "no craft after the revert (%s)", tostring(why))
  end
  CP.result()
end
