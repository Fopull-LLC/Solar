-- ── staging probe (tools/perf/stageprobe.sh): multi-stage and multi-type craft (playtest 2026-10-26) ──
-- "the stage menu is totally broken … i tried making a rocket with a jet
-- attached on a radial decoupler … it detached the entire jet except the
-- cockpit which stayed floating stuck to my main rocket". Modes:
--   stagejet     the player's own craft (tools/perf/crafts/rocketjet.json: a
--                rocket with a nose cone, a jet on a radial decoupler, the crew
--                in the jet's cockpit): rolled out in the VAB, flown up on the
--                rocket, the decoupler fired. The jet must leave WITH its
--                cockpit and the crew and the controls, the rocket fall as
--                debris; the jet then flies on its own engine; revert to launch
--   stage3       a three-stage rocket built from the engine up (Skipper | probe
--                core | Anvil | Sputter, pod, chute): SPACE three times. The
--                spent first stage carries a probe core, so it leaves as a craft
--                of its own: [ ] switches to it and back
--   stagelander  a lander with two radial boosters: the ring leaves as a pair;
--                in the VAB the chutes are put in the boosters' stage, so one
--                SPACE drops both boosters AND opens the chutes
--   stagevab     the builder's STAGE tab (1280×720 shots): the player's craft,
--                the three-stage rocket in the default order, two stages
--                swapped, the chutes moved into stage 1, a row hovered
-- One `SP PASS|FAIL <check>` line a check and `SP RESULT <mode>: PASS/FAIL`.
-- Pictures in $WORK/proj/save/user/stageshots/.
local SP = { fails = 0, tag = "stage" }
function SP.check(name, ok, fmt, ...)
  P("SP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then SP.fails = SP.fails + 1 end
  return ok
end
function SP.result()
  P("SP RESULT %s: %s (%d failed check(s))", SP.tag, SP.fails == 0 and "PASS" or "FAIL", SP.fails)
end
function SP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://stageshots/" .. SP.tag .. "_" .. nm .. ".png", bytes); P("SP SHOT %s_%s", SP.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function SP.decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = SP.decode(x) end
  return out
end
-- the uids aboard a controller's craft (its fleet records)
function SP.uids(vc)
  local fp = vc.fleetParts and vc.fleetParts()
  local set, n = {}, 0
  for _, r in ipairs(fp and fp.parts or {}) do set[r.uid] = true; n = n + 1 end
  return set, n
end
function SP.list(set)
  local o = {}
  for u in pairs(set) do o[#o + 1] = u end
  table.sort(o)
  return table.concat(o, ",")
end
function SP.controllers()
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid then out[#out + 1] = v end
  end
  return out
end
function SP.alt(vn)
  local S = vn.valid and body_state(vn)
  return S and S.alt or 0, S and S.V or 0
end
function SP.state(vc, tag)
  local i = vc.node.valid and assembly.info(vc.node)
  local st, seat = vc.crewStation and vc.crewStation()
  local t = vc.tele or {}
  P("SP [%s] %s: parts %d, piloting %s, crew %s (station %s), command %s, fuel %.1f, eng %s thrust %.0f kN, alt %.1f, v %.1f, events %s",
    tag, tostring(vc.craftName), i and #i.parts or -1, tostring(vc.piloting), tostring(vc.crewAboard), tostring(st),
    tostring(vc.commandUid and vc.commandUid()), vc.fuel or -1, tostring(t.eng), t.thrust or 0, SP.alt(vc.node),
    select(2, SP.alt(vc.node)), tostring(t.stages and #t.stages))
end
-- up on the pad's engines: release, full throttle, hold attitude until
-- `climb` m up or `secs` s
function SP.climb(vc, climb, secs)
  local vn = vc.node
  local a0 = SP.alt(vn)
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0, tl = time, -1
  while time - t0 < secs do
    vc.setThrottle(1)
    yield()
    if not vn.valid then break end
    local a, V = SP.alt(vn)
    if time - tl >= 0.5 then tl = time; P("SP climb +%.1f s: %.1f m up, %.1f m/s", time - t0, a - a0, V) end
    if a - a0 > climb then break end
  end
  return SP.alt(vn) - a0, time - t0
end

local function launch(list, extra, site)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  return launch_in_vab(list, site or "pad", #list, extra)
end

-- ── the player's rocket + jet ───────────────────────────────────────────────
local function rocketjet()
  local ok, raw = pcall(assets.readJson, "user://probe_rocketjet.json")
  if not ok or type(raw) ~= "table" then P("SP no user://probe_rocketjet.json: %s", tostring(raw)); return nil end
  return SP.decode(raw.bp)
end
local JET = { 29, 30, 31, 32, 33, 34, 38, 39, 40, 41, 42, 43 }
local ROCKET = { 46, 47, 48, 53 }

local function run_stagejet()
  SP.tag = params.tag or "jet"
  local bp = rocketjet()
  if not bp then SP.check("craft", false, "no craft file"); SP.result(); return end
  P("SP the player's craft: %d parts, %d links, root %s", #bp.parts, #(bp.links or {}), tostring(bp.root))
  -- (the jet's engine and fins stand level with the rocket's engine bell: on
  -- release they settle onto the ground with the rocket and the contact
  -- shatters the craft on HEAD as well — the probe hangs the jet `lift` m
  -- higher on its decoupler, which is the craft the player flew off)
  local lift = tonumber(params.lift) or 0
  if lift > 0 then
    local jet = { [49] = true }
    for _, u in ipairs(JET) do jet[u] = true end
    for _, d in ipairs(bp.parts) do if jet[d.uid] then d.y = d.y + lift end end
  end
  local vc = launch(bp.parts, { links = bp.links, root = bp.root, v = 2, name = "Rocket Jet" }, params.site or "runway")
  if not vc then SP.check("rollout", false, "no craft"); SP.result(); return end
  local vn = vc.node
  wait(2)
  SP.state(vc, "on the pad")
  local st = vc.crewStation and vc.crewStation()
  SP.check("crew_in_cockpit", vc.crewAboard and st == 29 and vc.commandUid() == 29, "the crew sit in the cockpit (station %s, command %s)", tostring(st), tostring(vc.commandUid()))
  SP.shot("1pad")
  -- a vertical launch: flown as a ROCKET (the player picks the craft's mode
  -- in flight; Aircraft would fly the stack as a plane off the pad), then as
  -- an AIRCRAFT once the jet is on its own
  if vc.setCtrlMode then vc.setCtrlMode(params.ascent or "rocket") end
  -- the jet's own engine stays shut on the way up (off its axis it tumbles
  -- the stack off the pad); it is lit once the jet is on its own
  if (params.jetoff or 0) > 0 and vc.partAction then P("SP jet engine off: %s", tostring(vc.partAction(31, "running.off"))) end
  -- THE PLAYER'S STACK CANNOT CLIMB OFF THE GROUND: TWR 1.09 with the jet
  -- spooled up, and the jet hangs 1.25 m off the rocket's axis, so it rises
  -- for a moment and topples (it shatters ~3 s after the clamps let go, on
  -- HEAD as on this build). So the probe starts it in the air: the clamps
  -- let go and the stack is put `airstart` m up, engines burning, and the
  -- decoupler fires `sepat` s later — the moment the player pressed SPACE.
  local air = tonumber(params.airstart) or 500
  if air > 0 then
    vc.releaseClamps()
    yield()
    local S0 = body_state(vn)
    local io = assembly.info(vn)
    if S0 and io and io.origin then
      assembly.teleport(vn, vec3(io.origin.x + S0.U.x * air, io.origin.y + S0.U.y * air, io.origin.z + S0.U.z * air))
    end
    yield(); yield()
  end
  local a_pad = SP.alt(vn)
  local up, secs = SP.climb(vc, 1e9, tonumber(params.sepat) or 2.0)
  SP.state(vc, "burning in the air")
  SP.check("airborne", air <= 0 or up > -60, "%.1f s on both engines, %.0f m from where it started", secs, up)
  SP.shot("2climbing")
  local n0 = #SP.controllers()
  local fired = vc.stageNext()
  wait(0.6)
  SP.state(vc, "after the radial decoupler")
  local set, n = SP.uids(vc)
  local jet_ok, rocket_gone = true, true
  for _, u in ipairs(JET) do if not set[u] then jet_ok = false end end
  for _, u in ipairs(ROCKET) do if set[u] then rocket_gone = false end end
  SP.check("split_fired", fired == true, "SPACE fired the radial decoupler")
  SP.check("jet_keeps_cockpit", jet_ok and set[29] == true, "the craft we fly holds the whole jet, cockpit included (%s)", SP.list(set))
  SP.check("rocket_left", rocket_gone, "the rocket is no longer part of it")
  local i = assembly.info(vn)
  SP.check("parts_match", i and #i.parts == n, "%d parts in the flying assembly, %d records", i and #i.parts or -1, n)
  SP.check("control_with_crew", vc.piloting and vc.crewAboard and vc.commandUid() == 29,
    "controls and crew stay with the jet (piloting %s, crew %s, command %s)", tostring(vc.piloting), tostring(vc.crewAboard), tostring(vc.commandUid()))
  SP.check("rocket_is_debris", #SP.controllers() == n0, "the rocket (no command part) left as debris, not a craft (%d controllers, was %d)", #SP.controllers(), n0)
  local cam = findScript("planet_camera")
  local pv = pilot()
  SP.check("camera_follows", pv and pv.node.id == vn.id, "the camera's craft is the jet (pilot %s, %s parts)", tostring(pv and pv.craftName),
    tostring(pv and #assembly.info(pv.node).parts))
  SP.shot("3split")
  if vc.setCtrlMode then vc.setCtrlMode("aircraft") end
  if vc.partAction then P("SP jet engine on: %s", tostring(vc.partAction(31, "running.on"))) end
  -- the jet flies on: full throttle on its own engine, the stick a touch back
  -- the jet flies on: full throttle on its own engine; it stood on its tail,
  -- so the nose comes over (stick forward) to gain speed, then the pull-out
  local a0, t0 = SP.alt(vn), time
  local maxv, amin = 0, a0
  -- (the attitude hold of perfbench's take-off: the nose's pitch over the
  -- horizon `theta`, its rate `qn`, the bank and roll rate)
  local function att()
    local F = vc.AERO and vc.AERO.frame
    if not F then return nil end
    local rx, upv, rz = basis(vn)
    local function w(v) return { x = rx.x * v.x + upv.x * v.y + rz.x * v.z, y = rx.y * v.x + upv.y * v.y + rz.y * v.z, z = rx.z * v.x + upv.z * v.y + rz.z * v.z } end
    local n, t = w(F.n), w(F.f)
    local S = body_state(vn)
    local ii = assembly.info(vn)
    if not (S and ii) then return nil end
    local r = cross(n, t)
    return math.asin(clamp(dot(n, S.U), -1, 1)), -dot(ii.angVel, cross(t, n)), math.asin(clamp(-dot(r, S.U), -1, 1)), dot(ii.angVel, n)
  end
  local dived = false
  while time - t0 < 12 and vn.valid do
    vc.setThrottle(1)
    local a, V = SP.alt(vn)
    local theta, qn, bank, pr = att()
    if theta then
      -- over the top into a shallow dive for speed, then level
      if V > 35 then dived = true end
      local want = dived and D(4) or D(-35)
      vc.AERO.cmd = { p = -clamp(3.0 * (want - theta) - 1.2 * qn, -1, 1), y = 0, r = clamp(-2.5 * bank - 0.8 * pr, -1, 1) }
      if time - (SP.tl or 0) >= 0.5 then
        SP.tl = time
        P("SP jet +%.1f s: %.0f m, %.1f m/s, pitch %.0f deg (want %.0f), bank %.0f, stick %.2f", time - t0, a, V, math.deg(theta), math.deg(want), math.deg(bank), vc.AERO.cmd.p)
      end
    end
    yield()
    maxv = math.max(maxv, V)
    amin = math.min(amin, a)
    if not SH_J and time - t0 > 4 then SH_J = true; SP.shot("4jet_flying") end
  end
  P("SP jet: top speed %.1f m/s, lowest %.0f m (from %.0f), now %.0f m", maxv, amin, a0, SP.alt(vn))
  if vc.AERO then vc.AERO.cmd = nil end
  SP.state(vc, "jet flying 8 s")
  local t = vc.tele or {}
  local iend = vn.valid and assembly.info(vn)
  SP.check("jet_engine", (t.thrust_now or 0) > 0 and not vc.destroyed and maxv > 20 and iend and #iend.parts == 13 and SP.alt(vn) > 20, "the jet flies on its own engine (%.1f kN now), destroyed %s, top speed %.1f m/s",
    t.thrust_now or 0, tostring(vc.destroyed), maxv)
  -- the revert: the whole craft back on the pad
  local vs = findScript("vessel_spawner")
  local okr, why = vs.revertToLaunch()
  P("SP revert: %s %s", tostring(okr), tostring(why))
  local vc2 = wait_craft(#bp.parts, 120)
  local i2 = vc2 and assembly.info(vc2.node)
  SP.check("revert", okr and vc2 and i2 and #i2.parts == #bp.parts and i2.anchored, "after the revert: %s parts on the pad, anchored %s (%s)",
    tostring(i2 and #i2.parts), tostring(i2 and i2.anchored), tostring(why))
  if vc2 then SP.state(vc2, "reverted") end
  SP.result()
end

-- ── a three-stage rocket, built from the engine up ──────────────────────────
local function rocket3()
  local l, y, u = {}, 0, 0
  local function add(id, h, o)
    u = u + 1
    o = o or {}
    l[#l + 1] = rec(u, id, 0, y + h / 2, 0, { parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "" })
    y = y + h
  end
  add("skipper", 1.6); add("tankM", 1.5); add("tankM", 1.5); add("probe", 0.42); add("decoupler", 0.25)
  add("engineM", 1.6); add("tankM", 1.5); add("decoupler", 0.25)
  add("engineS", 1.3); add("tankS", 1.0); add("pod", 0.8); add("chute", 0.34)
  return l
end

local function run_stage3()
  SP.tag = params.tag or "r3"
  local list = rocket3()
  local vc = launch(list, { name = "Three Stage" }, "pad")
  if not vc then SP.check("rollout", false, "no craft"); SP.result(); return end
  local vn = vc.node
  wait(2)
  SP.state(vc, "on the pad")
  local t = vc.tele or {}
  SP.check("three_cards", t.stages and #t.stages == 3, "the HUD's stack: %s cards (decouple, decouple, chutes)", tostring(t.stages and #t.stages))
  SP.shot("1pad")
  local up = SP.climb(vc, 60, 20)
  SP.state(vc, "stage 1 burning")
  local n0 = #SP.controllers()
  -- SPACE 1: the first stage (Skipper, two FT-M, the probe core) leaves as a craft
  vc.stageNext()
  wait(0.8)
  SP.state(vc, "after SPACE 1")
  local set, n = SP.uids(vc)
  SP.check("stage1_split", n == 8 and set[5] and set[11] and not set[4] and not set[1], "8 parts fly on (%s), the decoupler stays with the upper stack", SP.list(set))
  local cs = SP.controllers()
  local probe = nil
  for _, v in ipairs(cs) do if v.node.id ~= vn.id then probe = v end end
  SP.check("stage1_is_craft", #cs == n0 + 1 and probe ~= nil, "the spent stage has a probe core: it is a craft (%d controllers, name %s)", #cs, tostring(probe and probe.craftName))
  SP.check("control_stays", vc.piloting and vc.crewAboard, "the crew's stack keeps the controls")
  -- the new craft joins the fleet records under its own name
  local fo = findScript("flight_ops")
  if fo and fo.fleetSync and fo.fleetList then
    fo.fleetSync()
    local names, hit = {}, false
    for _, e in ipairs(fo.fleetList()) do
      names[#names + 1] = tostring(e.name)
      if probe and e.nodeId == probe.node.id then hit = true end
    end
    SP.check("fleet_record", hit, "the fleet: %s", table.concat(names, " | "))
  end
  SP.shot("2after_space1")
  -- [ ] : switch to the probe stage and back
  local sw = findScript("vessel_switcher")
  if sw and probe then
    wait(0.5)
    local tl = sw.targets()
    local names = {}
    for _, x in ipairs(tl) do names[#names + 1] = x.name end
    P("SP switch list: %s", table.concat(names, " | "))
    local got = sw.step(1)
    wait(1.0)
    local p1 = pilot()
    SP.check("switch_to_stage", p1 and probe and p1.node.id == probe.node.id, "] switched to %s (piloting %s)", tostring(got), tostring(p1 and p1.craftName))
    if p1 and p1.node.id == probe.node.id then SP.shot("3switched_to_probe_stage") end
    sw.step(-1)
    wait(1.0)
    local p2 = pilot()
    if not (p2 and p2.node.id == vn.id) then sw.step(1); wait(1.0); p2 = pilot() end
    SP.check("switch_back", p2 and p2.node.id == vn.id and vc.crewAboard, "[ switched back to the crew's stack (%s)", tostring(p2 and p2.craftName))
  else
    SP.check("switch_to_stage", false, "no switcher or no probe stage")
  end
  -- SPACE 2: the Anvil stage drops as debris, the Sputter lights
  local t1 = time
  while time - t1 < 3 and vn.valid do vc.setThrottle(1); yield() end
  vc.stageNext()
  wait(0.8)
  SP.state(vc, "after SPACE 2")
  set, n = SP.uids(vc)
  SP.check("stage2_split", n == 5 and set[8] and set[11] and not set[7], "5 parts fly on (%s)", SP.list(set))
  t = vc.tele or {}
  SP.check("stage3_burns", (t.eng or 0) == 1, "the Sputter is the engine lit now (%s)", tostring(t.eng))
  t1 = time
  while time - t1 < 2 and vn.valid do vc.setThrottle(1); yield() end
  SP.shot("4upper_stage")
  vc.setThrottle(0)
  -- SPACE 3: the chutes
  vc.stageNext()
  wait(0.5)
  SP.check("chutes", vc.chutes_deployed == true, "the chutes are out")
  SP.result()
end

-- ── a lander with two radial boosters ──────────────────────────────────────
local function lander()
  puid = 0
  local R, up, out = {}, { x = 0, y = 1, z = 0 }, nil
  local function add(r) R[#R + 1] = r return r end
  local pod = add(prec("pod", 0, 3.4, 0, { x = 1, y = 0, z = 0 }, up))
  local tank = add(prec("tankM", 0, 2.25, 0, { x = 1, y = 0, z = 0 }, up, { parent = pod.uid, att = "bottom" }))
  add(prec("engineS", 0, 0.85, 0, { x = 1, y = 0, z = 0 }, up, { parent = tank.uid, att = "bottom" }))
  for _, s in ipairs({ 1, -1 }) do
    out = { x = s, y = 0, z = 0 }
    local dec = add(prec("radialDec", s * 0.625, 2.25, 0, { x = 0, y = 0, z = 1 }, out, { parent = tank.uid, att = "surface", sym = 1, mir = "x" }))
    local bt = add(prec("tankS", s * 1.25, 2.4, 0, { x = 1, y = 0, z = 0 }, up, { parent = dec.uid, att = "surface", sym = 2, mir = "x" }))
    add(prec("engineS", s * 1.25, 1.25, 0, { x = 1, y = 0, z = 0 }, up, { parent = bt.uid, att = "bottom", sym = 3, mir = "x" }))
  end
  add(prec("chute", 0, 3.97, 0, { x = 1, y = 0, z = 0 }, up, { parent = pod.uid, att = "top" }))
  return R
end

local function run_stagelander()
  SP.tag = params.tag or "lander"
  local list = lander()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local BH = enter_vab("sp_enter")
  if not BH then SP.check("vab", false, "no builder"); SP.result(); return end
  local B = findScript("builder")
  wait(1)
  load_bp(B, "sp_lander", list, { name = "Lander" })
  wait(0.5)
  local v = B.stageView()
  local kinds = {}
  for n, sg in ipairs(v.stages) do
    local ks = {}
    for _, e in ipairs(sg.items) do ks[#ks + 1] = e.kind end
    kinds[n] = table.concat(ks, "+")
  end
  SP.check("vab_default", table.concat(kinds, " ") == "ring chute", "the stack: %s", table.concat(kinds, " "))
  -- the chutes into the boosters' stage: one SPACE fires both
  B.cmd("stage", { op = "item", key = "c", to = 1 })
  v = B.stageView()
  SP.check("vab_grouped", #v.stages == 1 and #v.stages[1].items == 2, "after the move: %d stage(s), %d events in stage 1", #v.stages, #v.stages[1].items)
  -- (the runway: on the pad the lander's chute caught the tower's arm)
  local site = params.site or "runway"
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not vc then SP.check("rollout", false, "no craft"); SP.result(); return end
  wait(2)
  SP.state(vc, "on the pad")
  local t = vc.tele or {}
  SP.check("lit_at_launch", (t.eng or 0) == 3, "three engines burn from lift-off (core + two boosters): %s", tostring(t.eng))
  SP.check("hud_one_card", t.stages and #t.stages == 1 and t.stages[1].also ~= nil, "the HUD shows one card for the grouped stage")
  SP.shot("1pad")
  local up = SP.climb(vc, 30, 12)
  SP.state(vc, "climbed")
  SP.check("lander_climb", up > 20, "%.0f m up on three engines", up)
  local n0 = #SP.controllers()
  vc.stageNext()
  wait(0.8)
  SP.state(vc, "after SPACE")
  local set, n = SP.uids(vc)
  SP.check("ring_left", n == 4 and set[1] and set[2] and set[3] and set[10], "both boosters left together, the lander flies on (%s)", SP.list(set))
  SP.check("ring_debris", #SP.controllers() == n0, "boosters are debris (no command part)")
  SP.check("grouped_chutes", vc.chutes_deployed == true, "the same SPACE opened the chutes")
  t = vc.tele or {}
  SP.check("lander_engine", (t.eng or 0) == 1, "the lander's own engine is the one lit (%s)", tostring(t.eng))
  SP.shot("2boosters_away")
  SP.result()
end

-- ── the builder's STAGE tab ────────────────────────────────────────────────
local function run_stagevab()
  SP.tag = params.tag or "vab"
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local BH = enter_vab("sp_enter")
  if not BH then SP.check("vab", false, "no builder"); SP.result(); return end
  local B = findScript("builder")
  local ins = findScript("builder_inspector")
  wait(1)
  local bc = findScript("builder_camera")
  local bp = rocketjet()
  if bp then
    load_bp(B, "sp_jet", bp.parts, { links = bp.links, root = bp.root, v = 2 })
    if ins and ins.setTab then ins.setTab("STAGE") end
    if bc and bc.frameCraft then bc.frameCraft() end
    wait(2)
    SP.shot("1player_craft_stage_tab")
    if B.stageView then
      local v = B.stageView()
      SP.check("jet_view", #v.stages == 1 and v.stages[1].items[1].kind == "ring", "the player's craft: %d stage(s), the radial decoupler", #v.stages)
    end
  end
  load_bp(B, "sp_r3", rocket3(), {})
  if ins and ins.setTab then ins.setTab("STAGE") end
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(2)
  SP.shot("2rocket3_default")
  if not B.stageView then SP.check("api", false, "no stageView (the old builder)"); SP.result(); return end
  local v = B.stageView()
  SP.check("r3_default", #v.stages == 3 and v.stages[1].items[1].kind == "axial" and v.stages[3].items[1].kind == "chute",
    "three stages: decouple, decouple, chutes")
  B.cmd("stage", { op = "swap", i = 1, j = 2 })
  wait(0.8)
  SP.shot("3swapped")
  v = B.stageView()
  B.cmd("stage", { op = "item", key = "c", to = 1 })
  wait(0.8)
  v = B.stageView()
  SP.check("r3_grouped", #v.stages == 2 and #v.stages[1].items == 2, "chutes joined stage 1: %d stages", #v.stages)
  -- hover the first event: its parts light in the view
  B.stageHover(v.stages[1].items[1].key)
  for _ = 1, 10 do B.stageHover(v.stages[1].items[1].key); yield() end
  SP.shot("4grouped_hover")
  B.undoStep(); B.undoStep()
  wait(0.8)
  v = B.stageView()
  SP.check("undo", #v.stages == 3 and v.stages[1].items[1].key == "u5", "two undos: back to the default (stage 1 = %s)", tostring(v.stages[1] and v.stages[1].items[1].key))
  SP.shot("5undone")
  SP.result()
end
