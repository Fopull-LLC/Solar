-- ── nuclear probe (tools/perf/nukeprobe.sh): deep-space step 3 ─────────────
-- (B1 B2 B3 B5 B6 A4 A6: the isotope cell, the heat loop, radiators, fuel
-- rods, fabrication, the radiation cone, the scram and the restart). Spliced
-- into a copy of perfbench.lua after vfxprobe_modes.lua (its cameras); one
-- table of functions (perfbench's main chunk is near Lua's 200-locals ceiling).
--   nukevab   the VAB: an Anvil, an FT-M, the Ember with two Radiator Panels,
--             a Shadow Shield, an FT-S with an Isotope Cell and a Radiator
--             Fin, a Pod Mk1, a chute. The cone drawn, the seat amber
--             (shielded); the inspector's heat budget; the same craft with
--             no shield: the seat red. Every number from builder.thermalBudget
--             checked against the rule.
--   nukefly   that craft launched with two rods in stores: the rods loaded at
--             rollout, the heat gauge on the HUD, the radiators deployed, the
--             reactor started (6 EC/s), the loop settling under the scram
--             line; the radiators folded at full output: a SCRAM, once, and
--             the restart refused while it cools; the pod's crew dosed only
--             through the shield; the rod menus on the Ember's right-click;
--             fuel fabrication at the Intake; the thermal tick's own cost.
-- One `NP PASS|FAIL <check>` line a check and `NP RESULT <mode>: PASS/FAIL`.
-- Pictures: 1280x720, save/user/nukeshots/<mode>_<name>.png in the scratch project.
NP = { fails = 0, tag = "nuke" }
function NP.check(name, ok, fmt, ...)
  P("NP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then NP.fails = NP.fails + 1 end
  return ok
end
function NP.result() P("NP RESULT %s: %s (%d failed check(s))", NP.tag, NP.fails == 0 and "PASS" or "FAIL", NP.fails) end
function NP.shot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://nukeshots/" .. NP.tag .. "_" .. nm .. ".png", bytes); P("NP SHOT %s_%s t=%.3f", NP.tag, nm, time)
    else P("NP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("NP capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- THE CRAFT, bottom up in the builder's frame.
function NP.craft(B, shield)
  local function def(id) local pr = findScript("parts_registry"); return (pr and pr.REG and pr.REG[id]) or B.partInfo(id) end
  local up, X = { x = 0, y = 1, z = 0 }, { x = 1, y = 0, z = 0 }
  local R, y, prev = {}, 0, nil
  local function add(r) R[#R + 1] = r return r end
  puid = 0
  local function stack(id)
    local h = def(id).h
    local r = add(prec(id, 0, y + h / 2, 0, X, up, prev and { parent = prev.uid, att = "top" } or nil))
    y = y + h
    prev = r
    return r
  end
  local eng = stack("engineM")
  local t1 = stack("tankM")
  local em = stack("ember")
  local sh = shield ~= false and stack("shadowShield") or nil
  local t2 = stack("tankS")
  local pod = stack("pod")
  stack("chute")
  -- two radiator panels on the Ember's flanks (±X), a symmetry pair
  local rp = def("radPanel")
  for _, s in ipairs({ 1, -1 }) do
    add(prec("radPanel", s * (0.5 + rp.rx), em.y, 0, { x = s, y = 0, z = 0 }, up,
      { parent = em.uid, att = "surface", sym = 1, mir = "x" }))
  end
  -- an isotope cell and a fin on the upper tank (±Z)
  local rt, rf = def("rtg"), def("radFin")
  local cell = add(prec("rtg", 0, t2.y, 0.5 + rt.rx, { x = 0, y = 0, z = 1 }, up, { parent = t2.uid, att = "surface" }))
  local fin = add(prec("radFin", 0, t2.y, -(0.5 + rf.rx), { x = 0, y = 0, z = -1 }, up, { parent = t2.uid, att = "surface" }))
  NP.uids = { engine = eng.uid, ember = em.uid, shield = sh and sh.uid, pod = pod.uid, cell = cell.uid, fin = fin.uid, t2 = t2.uid }
  NP.list = R
  return R
end

function NP.unlock()
  local co = findScript("company")
  if co and co.earn then co.earn(120000, "probe") end
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "engineM", "battery", "rtg", "radFin", "radPanel", "radTruss", "ember", "shadowShield" }) do
    if rs and rs.grant then rs.grant(id, "probe") end
  end
end

-- ── nukevab ─────────────────────────────────────────────────────────────────
function NP.run_vab()
  NP.tag = params.tag or "vab"
  local BH = enter_vab("np_enter")
  if not BH then NP.check("vab", false, "no builder"); NP.result(); return end
  local B = findScript("builder")
  NP.unlock()
  wait(1)
  local pr = findScript("parts_registry")
  local cat = B.catalogue and B.catalogue() or (pr and pr.catalogue()) or {}
  local nuke = nil
  for _, s in ipairs(cat) do if s.title == "NUCLEAR" then nuke = s end end
  NP.check("catalogue", nuke and #nuke.ids == 6, "the NUCLEAR section: %s", nuke and table.concat(nuke.ids, ", ") or "missing")
  local list = NP.craft(B, true)
  load_bp(B, "np_craft", list, { name = "Ember Probe" })
  wait(1)
  local tb = B.thermalBudget and B.thermalBudget()
  NP.check("budget", tb ~= nil and #tb.cores == 1, "the heat budget: settles %d %% at full output, in %.1f / sheds %.1f, %d core(s)",
    tb and math.floor(tb.eq * 100 + 0.5) or -1, tb and tb.Q or -1, tb and tb.S or -1, tb and #tb.cores or -1)
  NP.check("budget_cool", tb and tb.eq < 0.9, "…two deployed panels hold the Ember under the scram line in full sun")
  local seat = tb and tb.seats and tb.seats[1]
  NP.check("seat_shaded", seat and seat.inside and seat.rate * 7200 < 1 and (seat.blocked or 0) >= 2,
    "the pod is in the cone but behind the shield and a full tank: %.2e dose/s, %d blockers (lethal in %.0f h)",
    seat and seat.rate or -1, seat and seat.blocked or -1, seat and seat.rate > 0 and 1 / seat.rate / 3600 or -1)
  local bc = findScript("builder_camera")
  B.select({ NP.uids.ember }, "set")
  if bc and bc.frameCraft then bc.frameCraft() elseif bc and bc.frameSelection then bc.frameSelection() end
  wait(1.5)
  NP.shot("1shielded")
  B.select({}, "set")
  wait(0.5)
  NP.shot("2craft_budget")
  -- the same craft with no shield
  local list2 = NP.craft(B, false)
  load_bp(B, "np_craft2", list2, { name = "Ember Bare" })
  wait(1)
  local tb2 = B.thermalBudget and B.thermalBudget()
  local s2 = tb2 and tb2.seats and tb2.seats[1]
  NP.check("seat_bare", s2 and s2.inside and s2.rate * 7200 >= 1,
    "with no shield the pod is behind one full tank only: %.2e dose/s (lethal in %.1f h): red", s2 and s2.rate or -1,
    s2 and s2.rate > 0 and 1 / s2.rate / 3600 or -1)
  -- (the bare stack is 0.18 m shorter: the pod nearer the core, by the inverse square)
  local function dz(l) local a, b for _, r in ipairs(l) do if r.id == "ember" then a = r.y elseif r.id == "pod" then b = r.y end end return b - a end
  local k = (seat and s2 and s2.rate > 0) and seat.rate / s2.rate * (dz(list) / dz(list2)) ^ 2 or -1
  NP.check("ratio", math.abs(k - 0.02) < 1e-4, "the shield's share of it, distance taken out: %.4f (the rule says 0.02)", k)
  B.select({ NP.uids.ember }, "set")
  wait(1.0)
  NP.shot("3bare")
  -- the VAB's own cost of the cone and the budget (cached on craftVersion)
  local snap, f0 = LP_SNAP(), FRAME
  wait(2)
  P("NP vab: frames %d, builder %.2f ms a frame", FRAME - f0, B.frameMs and B.frameMs() or -1)
  NP.result()
end

-- ── nukefly ─────────────────────────────────────────────────────────────────
function NP.warp(vc, w)
  vc.setThrottle(0)
  wait(0.3)
  space.warp(w)
  wait(0.5)
  P("NP warp asked %d, now %.0f", w, space.warp())
end
function NP.tele(vc) return vc.tele and vc.tele.heat end
function NP.run_fly()
  NP.tag = params.tag or "fly"
  local inv = findScript("inventory")
  local BH = enter_vab("np_enter")
  if not BH then NP.check("vab", false, "no builder"); NP.result(); return end
  local B = findScript("builder")
  NP.unlock()
  if inv then inv.addItem("base", "fuelRod", 2, { force = true }) end
  local rods0 = inv and inv.itemCount("base", "fuelRod") or -1
  wait(1)
  local list = NP.craft(B, true)
  load_bp(B, "np_craft", list, { name = "Ember Probe" })
  wait(0.5)
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not vc then NP.check("rollout", false, "no craft"); NP.result(); return end
  local vn = vc.node
  local rods1 = inv and inv.itemCount("base", "fuelRod") or -1
  NP.check("rods_rollout", rods0 - rods1 == 1, "the Ember's rack took one rod from stores at rollout (%d → %d)", rods0, rods1)
  wait(1.5)
  -- the heat loop's own cost: a wrapper on the controller's thermalTick
  -- (the global power_tick calls; lua_prof has wrapped this handle already)
  NP.cost = { ms = 0, n = 0 }
  do
    local f = vc.thermalTick
    local wc = app.wallClock
    vc.thermalTick = function(...)
      local t = wc()
      local a = f(...)
      NP.cost.ms = NP.cost.ms + (wc() - t) * 1000
      NP.cost.n = NP.cost.n + 1
      return a
    end
  end
  local h0 = NP.tele(vc)
  NP.check("gauge", h0 ~= nil, "the HEAT gauge is on the HUD (a heat source aboard): loop %d %%", h0 and math.floor(h0.T * 100) or -1)
  NP.check("cold", h0 and (h0.live or 0) == 0, "the reactor rolls out cold (critical: %s)", h0 and tostring(h0.live) or "?")
  local em = NP.uids.ember
  local function st() return vc.partSt and { critical = vc.partSt(em, "critical"), life = vc.partSt(em, "life"),
    rods = vc.partSt(em, "rods"), scram = vc.partSt(em, "scram"), output = vc.partSt(em, "output") } or {} end
  NP.check("rods_aboard", (st().rods or 0) == 1 and (st().life or 0) > 3000, "one rod in the rack: %s rods, %s s of life",
    tostring(st().rods), tostring(st().life))
  -- the camera beside the craft
  VP.cam_local(vn, 6.5, 4.5, 6.5, 0, 3.8, 0)
  -- deploy (U) and start
  local rad = {}
  for _, r in ipairs(NP.list) do if r.id == "radPanel" then rad[#rad + 1] = r.uid end end
  for _, u in ipairs(rad) do vc.partAction(u, "deployed.on") end
  vc.partAction(em, "critical.on")
  wait(3)
  local h1 = NP.tele(vc)
  NP.check("critical", h1 and (h1.live or 0) == 1 and st().critical == true, "the Ember is critical: %d %% output, makes %.2f EC/s",
    h1 and math.floor((h1.out or 0) * 100) or -1, h1 and h1.gen or -1)
  NP.check("start_cost", (st().life or 0) < 3600 - 80, "the start cost rod life: %.0f s left", st().life or -1)
  NP.shot("1critical")
  -- warp a while: the loop settles (game time)
  local g0 = space.time()
  local tw = time
  NP.warp(vc, 10)
  while time - tw < 25 do yield() end
  NP.warp(vc, 1)
  local gs = space.time() - g0
  local h2 = NP.tele(vc)
  NP.check("settles", h2 and h2.T < 0.9 and math.abs(h2.T - h2.eq) < 0.08,
    "after %.0f game s the loop is at %d %%, settling at %d %% (scram %d %%)", gs, h2 and math.floor(h2.T * 100) or -1,
    h2 and math.floor(h2.eq * 100) or -1, 90)
  local cl = findScript("crew")
  local ids = vc.crewIds and vc.crewIds() or {}
  local d1 = (ids[1] and cl and cl.doseOf) and cl.doseOf(ids[1]) or -1
  NP.check("dose_shielded", d1 > 0 and d1 < 0.05, "the pod's crew behind the shield: dose %.5f after %.0f game s (some, through the shield; far from lethal)", d1, gs)
  NP.shot("2settled")
  -- from straight above: the panels out square to the hull
  VP.cam_local(vn, 0.3, 12, 0.01, 0, 3.8, 0)
  wait(0.5)
  NP.shot("2top_out", false)
  -- the pilot's own view: the HEAT row on the fuel and charge instrument
  VP.cam_off()
  wait(1.5)
  NP.shot("2hud")
  VP.cam_local(vn, 6.5, 4.5, 6.5, 0, 3.8, 0)
  -- fold the radiators at full output: the loop climbs past 90 % → SCRAM, once
  for _, u in ipairs(rad) do vc.partAction(u, "deployed.off") end
  local sc0 = (NP.tele(vc) or {}).scrams or 0
  g0 = space.time()
  tw = time
  VP.cam_local(vn, 0.3, 12, 0.01, 0, 3.8, 0)
  wait(2.5)
  NP.shot("3top_folded", false)
  VP.cam_local(vn, 6.5, 4.5, 6.5, 0, 3.8, 0)
  NP.warp(vc, 50)
  local scram_seen = nil
  while time - tw < 40 and not scram_seen do
    yield()
    local h = NP.tele(vc)
    if h and h.scrammed then scram_seen = space.time() - g0 end
  end
  -- straight down to 1x: the restart is refused while it cools (60 game s)
  NP.warp(vc, 1)
  vc.partAction(em, "critical.on")
  wait(0.5)
  local h4 = NP.tele(vc)
  NP.check("restart_refused", st().critical ~= true and h4 and h4.msg and h4.msg:find("won't start") ~= nil,
    "a restart while it cools is refused: %s", h4 and tostring(h4.msg) or "?")
  NP.shot("3scram")
  VP.cam_off()
  wait(1.0)
  NP.shot("3scram_hud")
  -- … and with nobody restarting it, it stays down through another stretch of warp
  NP.warp(vc, 50)
  wait(10)
  NP.warp(vc, 1)
  local h3 = NP.tele(vc)
  local scrams = ((h3 or {}).scrams or 0) - sc0
  NP.check("scram", scram_seen ~= nil, "radiators folded at full output: SCRAM after %.0f game s", scram_seen or -1)
  NP.check("scram_once", scrams == 1 and st().critical ~= true, "…exactly once (%d) in %.0f game s, and it stays down (loop now %d %%)",
    scrams, space.time() - g0, h3 and math.floor(h3.T * 100) or -1)
  -- the right-click rows on the Ember
  local reg = findScript("context_registry")
  local rows = {}
  if reg and reg.entriesFor then
    local ok, list2 = pcall(reg.entriesFor, { kind = "part", vessel = vc, uid = em, rec = vc.partRec and vc.partRec(em) or nil,
      label = "Ember" }, { actor = { kind = "craft", vessel = vc, node = vn }, ref = function(k) return findScript(k) end })
    if ok then for _, e in ipairs(list2 or {}) do rows[#rows + 1] = (e.label or e.id or "?") end
    else P("NP entriesFor error %s", tostring(list2)) end
  end
  local joined = table.concat(rows, " | ")
  NP.check("menu", joined:find("CORE") and joined:find("RODS") and joined:find("Load fuel rod"),
    "the Ember's right-click: %s", joined)
  -- the thermal tick's own cost (10 Hz; per frame = its share over the frames)
  vc.partAction(em, "critical.on")
  for _, u in ipairs(rad) do vc.partAction(u, "deployed.on") end
  local VT = findScript("vessel_thermal")
  if VT then VT.PROF_ON = true end
  local c0, n0, f0 = NP.cost.ms, NP.cost.n, FRAME
  wait(5)
  if VT then
    VT.PROF_ON = false
    local pr = VT.PROF or {}
    P("NP PROF over %d ticks: entries %.3f model %.3f advance %.3f radiation %.3f (%d passes) hud %.3f ms total",
      pr.n or 0, pr.entries or 0, pr.model or 0, pr.advance or 0, pr.radiation or 0, pr.rad_n or 0, pr.hud or 0)
  end
  local dms, dn, df = NP.cost.ms - c0, NP.cost.n - n0, FRAME - f0
  P("NP COST thermalTick %.4f ms a call over %d calls, %.4f ms a frame over %d frames (whole run: %d calls, %.3f ms each)",
    dn > 0 and dms / dn or -1, dn, df > 0 and dms / df or -1, df, NP.cost.n, NP.cost.n > 0 and NP.cost.ms / NP.cost.n or -1)
  NP.check("cost", dn > 0 and dms / dn < 0.25, "the heat loop costs %.3f ms a 10 Hz tick (%.4f ms a frame)",
    dn > 0 and dms / dn or -1, df > 0 and dms / df or -1)
  -- fuel fabrication at the Intake (the press on the game clock)
  local mi = findScript("material_intake")
  local TH = findScript("thermal")
  if mi and TH and inv then
    inv.add("base", "uranium", 25)
    local q = save.get("fab.rods") or {}
    TH.fabQueue(q, space.time() - TH.FUEL_FAB.secs - 1, nil)
    save.set("fab.rods", q)
    local r0 = inv.itemCount("base", "fuelRod")
    wait(2.5)
    local r1 = inv.itemCount("base", "fuelRod")
    NP.check("fab", r1 == r0 + 1, "a rod out of the Intake's press on the game clock: stores %d → %d", r0, r1)
  end
  VP.cam_off()
  NP.result()
end
