-- ── split-mode probe (tools/perf/splitprobe.sh): crafts made of crafts ─────
-- "a ship that deploys a rover: is the rover going to switch to rover control
-- when you pilot the detached craft? a jet that detaches a ship?" (2026-11).
-- The control mode is read per SECTION (scripts/craft_mode.lua: a craft cut
-- at its decouplers and docking ports), from the command part flown. Modes:
--   splitrover  a probe rocket (Probe Core, two FT-S, a Sputter) with a rover
--               (Rover Body, four Wheel M) on a radial decoupler at its flank,
--               on the runway. In the VAB: two sections, "Probe Core: Auto
--               (Rocket) · Rover Body: Auto (Rover)"; Rocket chosen on the
--               ship's section only (shot). In flight: the ship flies as a
--               Rocket (chosen), the rover's body still Auto (Rover) and its
--               record carries no choice; the rover separates; the new craft
--               reads Rover at once, the ship still Rocket; switched to the
--               rover, W drives it (keys, shots). A crewed seat on the rover:
--               the probe core in the root section commands at launch and the
--               crew ride the seat as passengers; their side stays at the split
--   splitjet    the 27-part jet with a small rocket (Probe Core, FT-S, a
--               Sputter) on a radial decoupler on its back: the jet reads
--               Aircraft, the rocket section Rocket; released, the rocket
--               is its own craft and a Rocket, the jet still an Aircraft
-- Needs ctrlprobe_modes.lua spliced in first (CP helpers). One `CP PASS|FAIL`
-- line a check and `CP RESULT <mode>`. Pictures in $WORK/proj/save/user/ctrlshots/.
-- (one table: perfbench's main chunk is near Lua's 200-local limit)
local SP = {}

function SP.bp_rover()
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  -- the ship, from its probe core down (the core is the tree's root, as a
  -- craft built in the VAB from its command part is)
  add(rec(1, "probe", 0, 3.51, 0))
  add(rec(2, "tankS", 0, 2.80, 0, { parent = 1, att = "bottom" }))
  add(rec(3, "tankS", 0, 1.80, 0, { parent = 2, att = "bottom" }))
  add(rec(4, "engineS", 0, 0.65, 0, { parent = 3, att = "bottom" }))
  -- the rover on the lower tank's flank (+X), its wheels ~1 m off the ground
  add(rec(5, "radialDec", 0.625, 1.80, 0, { parent = 3, att = "surface", stage = 1 }))
  add(rec(6, "roverBody", 1.55, 1.80, 0, { parent = 5, att = "surface" }))
  add(rec(7, "wheelM", 2.21, 1.60, 0.7, { yaw = -HP, parent = 6, att = "surface", sym = 1, mir = "z" }))
  add(rec(8, "wheelM", 2.21, 1.60, -0.7, { yaw = HP, parent = 6, att = "surface", sym = 1, mir = "z" }))
  add(rec(9, "wheelM", 0.89, 1.60, 0.7, { yaw = -HP, parent = 6, att = "surface", sym = 2, mir = "z" }))
  add(rec(10, "wheelM", 0.89, 1.60, -0.7, { yaw = HP, parent = 6, att = "surface", sym = 2, mir = "z" }))
  -- a crewed seat on the rover: the crew ride it as passengers (the probe
  -- core in the root section commands the ship)
  add(rec(11, "seat", 1.55, 1.80 + 0.15 + 0.65, 0, { parent = 6, att = "top" }))
  return L
end

-- into the standalone builder with a blueprint, the craft on the stand
function SP.builder(bp, minparts)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", bp)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= minparts and B end, 90, "the builder")
  if not B then return nil end
  wait_for(function() local c = B.ctrlMode(); return c and c.ready end, 10, "the craft mode library")
  wait(1.5)
  return B
end
function SP.launch(B, minparts)
  save.set("shipyard.site", "runway")
  B.doLaunch()
  if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
  local vc = wait_craft(minparts, 150)
  wait_regrade()
  return vc
end
-- straight onto the runway: the records filled from the registries
function SP.direct(R)
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  local reg = findScript("parts_registry")
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local list = {}
  for _, r in ipairs(R) do
    local def = (pa and pa.PARTS[r.id]) or (reg and reg.REG[r.id])
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
  return vc
end
-- the other craft (not `vc`) with at least n parts
function SP.other(vc, n, tmo)
  return wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v ~= vc and v.node and v.node.valid and v.node.id ~= vc.node.id then
        local i = assembly.info(v.node)
        if i and #i.parts >= n and v.ctrlModeInfo and CP.info(v).mode ~= nil then return v end
      end
    end
  end, tmo or 20, "the separated craft")
end
function SP.secs(c)
  local o = {}
  for _, s in ipairs(c.sections or {}) do
    o[#o + 1] = string.format("[%s cmd %s set %s auto %s (%s)]", tostring(s.name), tostring(s.cmd), tostring(s.set), tostring(s.auto), tostring(s.why))
  end
  return table.concat(o, " ")
end

function SP.run_rover()
  CP.tag = params.tag or "splitrover"
  local list = SP.bp_rover()
  local B = SP.builder({ parts = list }, #list)
  if not B then CP.check("builder", false, "no builder"); CP.result(); return end
  B.select({}, "set")
  local ins = findScript("builder_inspector")
  if ins and ins.setTab then ins.setTab("CRAFT") end
  wait(1)
  local c = B.ctrlMode()
  P("CP builder sections: %s | summary %s", SP.secs(c), tostring(c.summary))
  local s1, s2 = (c.sections or {})[1], (c.sections or {})[2]
  CP.check("vab_sections", #(c.sections or {}) == 2 and s1.auto == "rocket" and s2.auto == "rover",
    "two sections: %s", tostring(c.summary))
  CP.shot("1vab_two_sections")
  B.cmd("setCtrl", { mode = "rocket", cmd = s1 and s1.cmd })
  wait(1)
  c = B.ctrlMode()
  s1, s2 = (c.sections or {})[1], (c.sections or {})[2]
  CP.check("vab_one_section", s1 and s1.set == "rocket" and s2 and s2.set == nil and s2.auto == "rover",
    "Rocket on the ship only: %s", tostring(c.summary))
  CP.shot("2vab_ship_rocket")
  if ins and ins.setTab then ins.setTab("INSPECT") end
  local vc = SP.launch(B, #list)
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2)
  local i = CP.state(vc, "ship on the runway")
  local rv6 = vc.partRec and vc.partRec(6) or {}
  local iv = vc.ctrlModeInfo(6) or {}
  local st = vc.crewStation and vc.crewStation()
  CP.check("ship_rocket", i.mode == "rocket" and i.set == "rocket" and i.from == 1 and vc.commandUid() == 1,
    "the ship flies as %s from %s (command part %s)", tostring(i.label), tostring(i.from), tostring(vc.commandUid()))
  CP.check("crew_passengers", vc.crewAboard and st == 11, "crew aboard %s, riding part %s (the rover's seat)", tostring(vc.crewAboard), tostring(st))
  CP.check("rover_section_untouched", rv6.ctrl == nil and iv.mode == "rover" and iv.set == nil,
    "the rover's body: ctrl %s, its section reads %s", tostring(rv6.ctrl), tostring(iv.label))
  CP.shot("3ship_hud")
  -- CONTROL FROM HERE on the rover's seat while it is aboard: Rover; and
  -- back on the probe core: Rocket again
  vc.commandFrom(11)
  wait(1)
  local ia = CP.state(vc, "control from the rover's seat")
  vc.commandFrom(1)
  wait(1)
  local ib = CP.state(vc, "control from the probe core")
  CP.check("control_from_here", ia.mode == "rover" and ia.from == 11 and ib.mode == "rocket" and ib.from == 1,
    "from the seat: %s; from the core: %s", tostring(ia.label), tostring(ib.label))
  vc.releaseClamps()
  wait(0.5)
  local ok = vc.fireSeparation(5)
  P("CP separation fired: %s", tostring(ok))
  local other = SP.other(vc, 4, 20)
  if not other then CP.check("separated", false, "no second craft"); CP.result(); return end
  wait(0.3)
  -- the crew's side stays (splitKeeper): whichever controller holds the
  -- rover's body is the rover now
  local rv, sh = vc, other
  if not (vc.partRec and vc.partRec(6)) then rv, sh = other, vc end
  local ir = CP.state(rv, "rover after the split")
  CP.check("rover_reads_rover", ir.mode == "rover" and ir.set == nil and rv.partRec(1) == nil,
    "the rover reads %s (%s), commanded from %s", tostring(ir.label), tostring(ir.why), tostring(rv.commandUid()))
  i = CP.state(sh, "ship after the split")
  CP.check("ship_still_rocket", i.mode == "rocket" and i.set == "rocket", "the ship: %s", tostring(i.label))
  -- let it settle on its wheels, then fly it
  wait(4)
  if not rv.piloting then rv.remoteControl(); wait(2) end
  ir = CP.state(rv, "flying the rover")
  CP.check("switched", rv.piloting and ir.mode == "rover", "piloting the rover: %s, mode %s, crew aboard %s", tostring(rv.piloting), tostring(ir.label), tostring(rv.crewAboard))
  CP.shot("4flying_the_rover")
  local vn = rv.node
  local p0 = sub(assembly.info(vn).com, home())
  key_down("w")
  local t0 = time
  while time - t0 < 6 do yield() end
  local d = from_point(vn, p0)
  local iv2 = assembly.info(vn)
  CP.state(rv, "W held 6 s")
  CP.shot("5rover_driving")
  release_all()
  CP.check("w_drives", d > 4, "W 6 s: %.1f m, %.1f m/s", d, len(iv2.vel.x, iv2.vel.y, iv2.vel.z))
  CP.result()
end

function SP.run_jet()
  CP.tag = params.tag or "splitjet"
  -- the jet (perfbench plane) and a small rocket on its back, along the
  -- fuselage: a radial decoupler on the tank's top, then a Probe Core at the
  -- front, an FT-S, a Sputter at the back, lying nose forward (+X)
  local R = plane()
  local function add(r) R[#R + 1] = r return r end
  local dec = add(prec("radialDec", 0.6, 2.125, 0, NOSE, TOP, { parent = 2, att = "radial", stage = 1 }))
  local pr = add(prec("probe", 1.55, 3.0, 0, { x = 0, y = 0, z = 1 }, NOSE, { parent = dec.uid, att = "surface" }))
  local tk = add(prec("tankS", 0.84, 3.0, 0, { x = 0, y = 0, z = 1 }, NOSE, { parent = pr.uid, att = "bottom" }))
  add(prec("engineS", -0.31, 3.0, 0, { x = 0, y = 0, z = 1 }, NOSE, { parent = tk.uid, att = "bottom" }))
  local B = SP.builder({ parts = R }, #R)
  if not B then CP.check("builder", false, "no builder"); CP.result(); return end
  B.select({}, "set")
  local ins = findScript("builder_inspector")
  if ins and ins.setTab then ins.setTab("CRAFT") end
  wait(1)
  local c = B.ctrlMode()
  P("CP builder sections: %s | summary %s", SP.secs(c), tostring(c.summary))
  local s1, s2 = (c.sections or {})[1], (c.sections or {})[2]
  CP.check("vab_sections", #(c.sections or {}) == 2 and s1.auto == "aircraft" and s2.auto == "rocket",
    "two sections: %s", tostring(c.summary))
  CP.shot("1vab_jet_rocket")
  if ins and ins.setTab then ins.setTab("INSPECT") end
  -- (the aero parts are still research-locked in a probe save, so the VAB
  -- won't launch it: rolled out the way ctrlprobe's CP.launchJet does)
  local vc = SP.direct(R)
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2)
  local i = CP.state(vc, "jet on the runway")
  local ir = vc.ctrlModeInfo(pr.uid) or {}
  CP.check("jet_aircraft", i.mode == "aircraft" and i.set == nil, "the jet: %s (%s)", tostring(i.label), tostring(i.why))
  CP.check("rocket_section", ir.mode == "rocket", "its rocket's section: %s (%s)", tostring(ir.label), tostring(ir.why))
  CP.shot("2jet_hud")
  vc.releaseClamps()
  wait(0.5)
  P("CP separation fired: %s", tostring(vc.fireSeparation(dec.uid)))
  local rk = SP.other(vc, 3, 20)
  if not rk then CP.check("separated", false, "no rocket craft"); CP.result(); return end
  wait(0.3)
  local ik = CP.state(rk, "rocket away")
  CP.check("rocket_reads_rocket", ik.mode == "rocket" and ik.set == nil, "the released rocket: %s (%s)", tostring(ik.label), tostring(ik.why))
  i = CP.state(vc, "jet after the release")
  CP.check("jet_still_aircraft", i.mode == "aircraft", "the jet: %s (%s)", tostring(i.label), tostring(i.why))
  wait(1)
  rk.remoteControl()
  wait(1.5)
  CP.state(rk, "switched to the rocket")
  CP.shot("3switched_to_rocket")
  CP.result()
end
