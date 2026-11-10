-- ── refinery probe (tools/perf/refineryprobe.sh; expansion X6, "Refineries and
-- the RP sink"; docs/base-building.md §24)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam),
-- buildkitprobe_modes.lua, standeditprobe_modes.lua and runprobe_modes.lua.
--   refinery  RP: the refinery's research refused short of RP, then bought
--             (money and RP spent), the others after it; the lab's WHAT RP
--             BUYS list. On flat ground, one structure: a Hopper of Hematite
--             Earth → belt → Crusher → belt → Furnace → belt → Fabricator,
--             the crusher's spoil → belt → Hopper; a Kiln and a Regocrete
--             Mixer (water from a tank) fed by hand; an Electrolyser between a
--             Water Tank and a Fuel Tank. The furnace at 20 % (no cooling),
--             two Jacket Radiators on its heat port: 100 %. Steel into the
--             Fabricator's store; a Transfer Tube 1 m queued, made, in an
--             Engineer's reach (field_builder.cratedInReach); the RECIPE
--             panel; the LOGISTICS overlay's machine labels; propellant in the
--             Fuel Tank; Regocrete and Glass; a machine switched off (LIMITED
--             BY); costs idle and running. machines.SPEED is raised for the
--             production part (it is logged), so a crate comes in minutes.
-- `RX PASS|FAIL <check>`, `RX …` lines and `RX RESULT`. Pictures: save/user/refineryshots/.
RX = { fails = 0, passed = 0 }
function RX.check(name, okc, fmt, ...)
  P("RX %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then RX.passed = RX.passed + 1 else RX.fails = RX.fails + 1 end
  return okc
end
function RX.result() P("RX RESULT %d passed, %d failed", RX.passed, RX.fails) end
function RX.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://refineryshots/" .. nm .. ".png", bytes); P("RX SHOT %s", nm)
    else P("RX SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function RX.view(nm, rec, e, t, ui)
  local KS = findScript("kit_snap")
  local fr = KS.frameOf(rec)
  local function B(v) return { x = fr.O.x + fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], y = fr.O.y + fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                               z = fr.O.z + fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3] } end
  VP.cam_fixed(B(e), B(t))
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(true) end
  wait(1.2)
  RX.shot(nm, ui)
  RX.lastLabels = findScript("logistics").drawn.labels
  VP.cam_off()
  wait(0.3)
end
function RX.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  local LX, RF = findScript("logistics"), findScript("refinery")
  P("RX COST %s: logistics %.4f ms/frame, refinery %.4f, machines %.4f, item_net %.4f, fluid_net %.4f, base_grid %.4f, inventory %.4f, fab_panel %.4f · step %s ms (advance %s, segs %s), prepare %.3f ms, after %.3f ms, cool %.3f ms, overlay %.3f ms, settled skips %d",
    tag, ms("logistics"), ms("refinery"), ms("machines"), ms("item_net"), ms("fluid_net"), ms("base_grid"), ms("inventory"), ms("fab_panel"),
    tostring(LX.PROF.step_ms), tostring(LX.PROF.adv_ms), tostring(LX.PROF.segs), RF.PROF.prep_ms or 0, RF.PROF.after_ms or 0, RF.PROF.cool_ms or 0, LX.PROF.overlay_ms or 0, LX.PROF.skips or 0)
  return ms("logistics") + ms("refinery") + ms("machines")
end
local function items(cid)
  local inv = findScript("inventory")
  local t = {}
  for _, it in ipairs(inv.items(cid) or {}) do t[#t + 1] = it.n .. " " .. it.mat end
  for _, g in ipairs(inv.itemList and inv.itemList(cid) or {}) do if type(g.id) == "string" and g.id:sub(1, 5) == "part:" then t[#t + 1] = g.n .. " " .. g.id end end
  return string.format("%.0f kg [%s]", inv.mass(cid) or 0, table.concat(t, ", "))
end
function RX.state(tag, sid, U)
  local RF = findScript("refinery")
  local key = function(u) return sid .. "." .. u end
  local function m(u)
    local o = RF.readout(sid, u)
    if not o then return "—" end
    return string.format("%d%% q %.4f %s why %s", math.floor((o.duty or 0) * 100 + 0.5), o.q or 0, tostring(o.qmat), tostring(o.why))
  end
  P("RX STATE %s: crusher %s · furnace %s · kiln %s · mixer %s · electro %s · fab %s", tag, m(U.crusher), m(U.furnace), m(U.kiln), m(U.mixer), m(U.electro), m(U.fab))
  P("RX STATE %s: hopper %s · crusher in %s out %s · furnace in %s out %s · fab %s · spoil %s", tag,
    items("hopper:" .. key(U.hopper)), items("mach:" .. key(U.crusher) .. ".in"), items("mach:" .. key(U.crusher) .. ".out"),
    items("mach:" .. key(U.furnace) .. ".in"), items("mach:" .. key(U.furnace) .. ".out"), items("fab:" .. key(U.fab)), items("hopper:" .. key(U.spoil)))
  P("RX STATE %s: kiln out %s · mixer out %s · fuel tank %s kg · water tanks %s / %s kg", tag, items("mach:" .. key(U.kiln) .. ".out"), items("mach:" .. key(U.mixer) .. ".out"),
    tostring(findScript("fluid_net").content(sid, U.fuel)), tostring(findScript("fluid_net").content(sid, U.water1)), tostring(findScript("fluid_net").content(sid, U.water2)))
end

function RX.run()
  wait_ready(120)
  wait(2)
  local ST, LX, RF, MC, N, inv, rs, FN, co, C = findScript("structures"), findScript("logistics"), findScript("refinery"), findScript("machines"),
    findScript("item_net"), findScript("inventory"), findScript("research"), findScript("fluid_net"), findScript("company"), findScript("crew")
  if not RX.check("scene", ST and LX and RF and MC and N and inv and rs and FN, "logistics %s refinery %s machines %s item_net %s fluid_net %s",
    tostring(LX ~= nil), tostring(RF ~= nil), tostring(MC ~= nil), tostring(N ~= nil), tostring(FN ~= nil)) then RX.result() return end
  if perf.enable then perf.enable(true) end
  local idle0 = RX.cost("idle: no refinery pieces anywhere", 3)
  if co and co.earn then co.earn(500000, "probe") end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  -- 1. RP as a currency
  inv.add("astro", "iron", 1); inv.add("astro", "silica", 1)
  save.set("res.pts", 30)
  local m0 = co.balance and co.balance() or save.get("co.money") or 0
  local ok0, why0 = rs.unlock("refinery")
  RX.check("rp_short", not ok0 and tostring(why0):find("40 RP"), "short of RP the refinery is refused: %s · lock line: %s", tostring(why0), tostring(rs.lockLine("refinery")))
  save.set("res.pts", 400)
  local ok1 = rs.unlock("refinery")
  RX.check("rp_spent", ok1 and rs.points() == 360 and rs.rpSpent() == 40, "researched: %d RP left, %d spent (money %s → %s)", rs.points(), rs.rpSpent(), tostring(m0), tostring(co.balance and co.balance() or save.get("co.money")))
  local okc, oke, okf = rs.unlock("ceramics"), rs.unlock("electrolysis"), rs.unlock("fabrication")
  RX.check("rp_all", okc and oke and okf and rs.points() == 60, "Kiln and Mixer, Electrolyser, Fabricator: %d RP left", rs.points())
  local tree = rs.rpTree()
  local tl = {}
  for _, t in ipairs(tree) do tl[#tl + 1] = string.format("%s %d RP %s", t.label, t.rp, t.done and "done" or (t.why or "open")) end
  RX.check("rp_tree", #tree >= 6, "WHAT RP BUYS: %s", table.concat(tl, " · "))
  -- 2. the site
  local spot = BK.flat_spot()
  if not RX.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then RX.result() return end
  stand_at(spot)
  wait(4)
  local b = home()
  local a = astro()
  local U = unit(sub(a, b))
  local Fw = unit(sub(spot.t, scl(U, dot(spot.t, U))))
  local R = unit(cross(U, Fw))
  local A = sub(a, b)
  local O = { x = A.x + Fw.x * 5 - R.x * 2, y = A.y + Fw.y * 5 - R.y * 2, z = A.z + Fw.z * 5 - R.z * 2 }
  local function ground_local(lx, lz)
    local bb = home()
    local wx, wy, wz = bb.x + O.x + R.x * lx + Fw.x * lz + U.x * 30, bb.y + O.y + R.y * lx + Fw.y * lz + U.y * 30, bb.z + O.z + R.z * lx + Fw.z * lz + U.z * 30
    local h = terrain.raycast(vec3(wx, wy, wz), vec3(-U.x, -U.y, -U.z), 80)
    if not (h and h.pos) then return 0 end
    return dot(sub(h.pos, bb), U) - dot(O, U)
  end
  local y0 = ground_local(2, 8)
  O = { x = O.x + U.x * y0, y = O.y + U.y * y0, z = O.z + U.z * y0 }
  local rec = ST.newRecord(nil, b.name, O.x, O.y, O.z, U, Fw, "lgHopper.steel", { name = "Refinery", t = 0 })
  local sid = ST.add(rec)
  rec = ST.get(sid)
  local hy = 0
  for _, c in ipairs({ { 0, 0 }, { 0, 12 }, { 6, 8 }, { 6, 16 }, { -4, 8 } }) do hy = math.max(hy, ground_local(c[1], c[2])) end
  hy = hy + 0.05
  rec.bp[1].y = hy
  local Ux = { hopper = 1 }
  local function add(id, x, z, yaw) return ST.addPart(sid, { id = id, x = x, y = hy, z = z, yaw = yaw or 0 }) end
  local Q = math.pi / 2
  add("cvBelt2.steel", 0, 2)
  Ux.crusher = add("mcCrusher.steel", 0, 4)
  add("cvBelt2.steel", 0, 6)
  Ux.furnace = add("mcFurnace.steel", 0, 8)
  Ux.belt3 = add("cvBelt2.steel", 0, 10)
  Ux.fab = add("mcFab.steel", 0, 12)
  add("cvBelt2.steel", 2, 4, Q)                -- the crusher's spoil (+X) → the spoil hopper
  Ux.spoil = add("lgHopper.steel", 4, 4, Q)
  Ux.kiln = add("mcKiln.steel", 7, 9)
  Ux.mixer = add("mcMixer.steel", 7, 13)
  Ux.water1 = add("flTankWater.steel", 5, 13, -Q)   -- its port at (6, 13) facing +X: the mixer's water nozzle
  Ux.electro = add("mcElectro.steel", 7, 17)
  Ux.water2 = add("flTankWater.steel", 5.25, 17, -Q)
  Ux.fuel = add("flTankFuel.steel", 8.75, 17, Q)
  -- the power: the six machines are ~50 kW, so 26 Isotope Skids (2 kW each, day and night)
  for k = 0, 25 do
    local row, col = math.floor(k / 9), k % 9
    ST.addPart(sid, { id = "isotopeSkid", x = -8 + col * 1.9, y = hy, z = -4 - row * 1.5, yaw = 0 })
  end
  ST.spawnNow(sid)
  wait(2.0)
  -- the feed: Hematite Earth and Rust Rock in the hopper; silica in the kiln, regolith in the mixer
  local hop = "hopper:" .. sid .. "." .. Ux.hopper
  local nh = inv.add(hop, "hematite", 600, b.name)
  local nr = inv.add(hop, "rustrock", 100, b.name)
  local w = wait_for(function() local ww = LX.worldOf(b.name); return ww and ww.net and #ww.net.lines >= 4 and #(ww.machines or {}) >= 6 and ww end, 15, "the network")
  if not RX.check("net", w ~= nil, "logistics built the world's network with its machines") then RX.result() return end
  P("RX NET: %d nodes, %d lines, %d machines", #w.net.nodes, #w.net.lines, #w.machines)
  for li, L in ipairs(w.net.lines) do
    local ups, downs = {}, {}
    for _, i in ipairs(L.ups) do ups[#ups + 1] = w.net.nodes[i].key end
    for _, i in ipairs(L.downs) do downs[#downs + 1] = w.net.nodes[i].key end
    P("RX LINE %d: %s cap %.0f ok %s why %s · %s → %s (%d pieces)", li, L.kind, L.cap, tostring(L.ok), tostring(L.why), table.concat(ups, ","), table.concat(downs, ","), #L.pieces)
  end
  RX.check("lines", #w.net.lines == 4, "four lines: hopper → crusher → furnace → Fabricator, crusher → spoil (%d)", #w.net.lines)
  inv.add("mach:" .. sid .. "." .. Ux.kiln .. ".in", "silica", 70, b.name)
  inv.add("mach:" .. sid .. "." .. Ux.mixer .. ".in", "regolith", 150, b.name)
  wait_for(function() return FN.nets(sid) ~= nil end, 10, "the fluid networks")
  FN.setContent(sid, Ux.water1, 1500)
  FN.setContent(sid, Ux.water2, 1500)
  P("RX FEED: hopper +%d Hematite Earth +%d Rust Rock (%s)", nh, nr, items(hop))
  -- 3. live: the crusher works, the furnace runs at 20 % with no cooling
  wait(3)
  RX.state("start", sid, Ux)
  local run1 = RX.cost("running: crusher, furnace (no cooling), kiln, mixer, electrolyser", 8)
  RX.state("live 11 s", sid, Ux)
  local oc = RF.readout(sid, Ux.crusher) or {}
  RX.check("crusher", (oc.q or 0) > 0.5 or (inv.mass("mach:" .. sid .. "." .. Ux.crusher .. ".out") or 0) > 0 or (inv.mass("hopper:" .. sid .. "." .. Ux.spoil) or 0) > 0,
    "the crusher works %.2f kg/s (%s); spoil %s", oc.q or 0, tostring(oc.why), items("hopper:" .. sid .. "." .. Ux.spoil))
  local of = RF.readout(sid, Ux.furnace) or {}
  RX.check("cool20", math.abs((of.duty or 0) - 0.2) < 1e-6 and tostring(of.why):find("cooling"), "the furnace with nothing on its heat port: %d %% · %s", math.floor((of.duty or 0) * 100 + 0.5), tostring(of.why))
  local om = RF.readout(sid, Ux.mixer) or {}
  RX.check("mixer", (om.q or 0) > 0.1 or (inv.mass("mach:" .. sid .. "." .. Ux.mixer .. ".out") or 0) > 0, "the mixer works %.2f kg/s of regolith (%s), cell %s kg", om.q or 0, tostring(om.why), tostring(om.cell))
  local oe = RF.readout(sid, Ux.electro) or {}
  RX.check("electro", (oe.duty or 0) > 0.99, "the electrolyser at %d %% (%s), %.4f kg/s of water", math.floor((oe.duty or 0) * 100), tostring(oe.why), oe.q or 0)
  RX.view("r1_line_furnace_hot", rec, { -4.5, 3.2, -2.5 }, { 0, 1.0, 6 })
  RX.view("r2_line_crusher_side", rec, { -3.6, 2.4, 2.6 }, { 0.5, 1.0, 6.0 })
  -- 4. three Jacket Radiators on the furnace's heat port (−X at z 8.5): 100 %
  Ux.jk1 = add("mcJacket.steel", -2, 8.5)
  Ux.jk2 = add("mcJacket.steel", -4, 8.5)
  Ux.jk3 = add("mcJacket.steel", -6, 8.5)
  ST.spawnNow(sid)
  wait(2.5)
  local L = RF.coolOf(sid, Ux.furnace)
  of = RF.readout(sid, Ux.furnace) or {}
  RX.check("cool100", (of.duty or 0) > 0.999 and L and L.sinks == 3, "three Jacket Radiators: %.1f kW of sinks for %.1f kW → %d %% (%s)", L and L.C or -1, L and L.H or -1,
    math.floor((of.duty or 0) * 100 + 0.5), tostring(of.why))
  RX.view("r3_furnace_radiators", rec, { -9, 4, 2.5 }, { -3, 1.5, 8.5 })
  -- 5. production: the furnace's Steel to the Fabricator; a part queued and made
  local speed = 40
  MC.SPEED = speed
  P("RX SPEED: machines.SPEED = %d for the production part (one knob on every machine's rate)", speed)
  local fab = "fab:" .. sid .. "." .. Ux.fab
  local okq, wq = RF.queue(sid, Ux.fab, "tbTube1.steel", 1)
  RX.check("queue", okq, "a Transfer Tube 1 m queued at the Fabricator (%s)", tostring(wq))
  space.warp(20)
  local t0 = time
  while time - t0 < 80 and inv.itemCount(fab, "part:tbTube1.steel") < 1 do
    if space.warpFactor and space.warpFactor() < 20 then space.warp(20) end
    wait(1)
  end
  space.warp(1)
  wait(1)
  RX.state("after production", sid, Ux)
  RX.check("steel", (inv.count(fab, "steel") or 0) > 0 or inv.itemCount(fab, "part:tbTube1.steel") >= 1, "Steel reached the Fabricator's store: %s", items(fab))
  RX.check("crate", inv.itemCount(fab, "part:tbTube1.steel") >= 1, "the Fabricator made a crated Transfer Tube 1 m (%d) in %.0f s of warp", inv.itemCount(fab, "part:tbTube1.steel"), time - t0)
  MC.SPEED = 1
  -- the crate in an Engineer's reach (the X4 rule)
  do
    local fx, fy, fz = ST.partPose(rec, ST.getPart(sid, Ux.fab), 0)
    local bb = home()
    local a2 = astro()
    a2.x, a2.y, a2.z = bb.x + fx + R.x * 3 + U.x * 1.2, bb.y + fy + R.y * 3 + U.y * 1.2, bb.z + fz + R.z * 3 + U.z * 1.2
    a2.vx, a2.vy, a2.vz = 0, 0, 0
    wait(2)
    local fb = findScript("field_builder")
    if fb and fb.reachScan then fb.reachScan(true) end
    local n, from = 0, nil
    if fb and fb.cratedInReach then n, from = fb.cratedInReach("tbTube1.steel") end
    RX.check("reach", n >= 1, "the crate is in the Engineer's reach: %d from %s", n, tostring(from))
  end
  -- the other machines' products
  local fuel = FN.content(sid, Ux.fuel) or 0
  RX.check("fuel", fuel > 0, "the electrolyser's propellant in the Fuel Tank: %.2f kg", fuel)
  RX.check("regocrete", inv.count("mach:" .. sid .. "." .. Ux.mixer .. ".out", "regocrete") > 0, "Regocrete in the mixer's outlet: %s", items("mach:" .. sid .. "." .. Ux.mixer .. ".out"))
  RX.check("glass", inv.count("mach:" .. sid .. "." .. Ux.kiln .. ".out", "glass") > 0, "Glass in the kiln's outlet: %s", items("mach:" .. sid .. "." .. Ux.kiln .. ".out"))
  -- 6. the RECIPE panel
  local FP = findScript("fab_panel")
  RF.queue(sid, Ux.fab, "tbTube2.steel", 2)
  if FP and FP.open then
    FP.open(sid, Ux.fab)
    FP.pick("tbTube1.steel")
    wait(1.0)
    RX.check("panel", FP.isOpen(), "the RECIPE panel is open")
    -- (the player's own camera: the freecam hides the HUD layers)
    wait(1.0)
    RX.shot("r4_recipe_panel", true)
    FP.pick("mcJacket.steel")
    wait(1.0)
    RX.shot("r4b_recipe_panel_jacket", true)
    FP.close()
  end
  -- 7. the overlay
  LX.overlay, LX.overlayAlways = true, true
  RX.view("r5_overlay", rec, { -5, 12, -4 }, { 2, 0, 9 }, true)
  local dl5 = RX.lastLabels or 0
  RX.view("r6_overlay_other_angle", rec, { 14, 6, 20 }, { 3, 0.5, 9 }, true)
  local dl6 = RX.lastLabels or 0
  local ov = RX.cost("overlay on", 3)
  RX.check("overlay", math.max(dl5, dl6) >= 8, "the overlay draws %d and %d labels in its two pictures (machines, stores, lines)", dl5, dl6)
  LX.overlay, LX.overlayAlways = false, false
  -- 8. a machine switched off: LIMITED BY
  RF.setRun(sid, Ux.crusher, false)
  wait(1.5)
  local o3 = RF.readout(sid, Ux.crusher) or {}
  RX.check("off", (o3.duty or 1) == 0 and tostring(o3.why):find("switched off"), "crusher off: %s", tostring(o3.why))
  RF.setRun(sid, Ux.crusher, true)
  -- 9. costs: everything running, then idle (all switched off)
  local run2 = RX.cost("running (after production)", 4)
  for _, k in ipairs({ "crusher", "furnace", "kiln", "mixer", "electro", "fab" }) do RF.setRun(sid, Ux[k], false) end
  wait(2)
  local idle1 = RX.cost("idle: six machines built, all switched off", 4)
  -- (the lines carry on until the stores they feed are full; then nothing can move)
  inv.clear(hop)
  wait(25)
  local idle2 = RX.cost("idle settled: machines off, lines dry", 4)
  P("RX COSTS: nothing built %.4f · running %.4f · after production %.4f · overlay on %.4f · machines off %.4f · settled %.4f (logistics + refinery + machines ms/frame)", idle0, run1, run2, ov, idle1, idle2)
  RX.result()
end
