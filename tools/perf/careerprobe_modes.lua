-- ── career probe (tools/perf/careerprobe.sh; career missions E1) ────────────
-- Spliced into a copy of perfbench.lua. The economy fix of
-- work/missions/PLAN.md §6 in the real game:
--   career     a fresh career at Contractor with the High Road flown signs two
--              contracts (Made Orbit and a bulk haul) and takes both advances;
--              a second flight contract is refused; the Ops Board (both
--              contracts, an offer whose place is taken) and the objectives
--              card (both contracts, the switcher) are pictured; Made Orbit
--              is abandoned (its advance clawed back, 1 reputation); the
--              bulk haul is delivered (paid less its advance, +1 reputation).
--   careerold  the player's save (USERSAVE=1, SOLAR=<a copy holding it>):
--              its funds, its owed advance and its contract stand (slot one,
--              no advance, pays in full); a ground job signs beside it and is
--              abandoned again; the board and the card are pictured.
-- `CP PASS|FAIL <check>`, `CP …` lines and `CP RESULT`. Pictures: save/user/careershots/.
CP = { fails = 0, passed = 0 }
function CP.check(name, okc, fmt, ...)
  P("CP %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then CP.passed = CP.passed + 1 else CP.fails = CP.fails + 1 end
  return okc
end
function CP.result() P("CP RESULT %s (%d passed, %d failed)", CP.fails == 0 and "PASS" or "FAIL", CP.passed, CP.fails) end
function CP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1600, h = 900, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://careershots/" .. nm .. ".png", bytes); P("CP SHOT %s", nm)
    else P("CP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- the Ops Board open on contract `id`, pictured
function CP.board(id, nm)
  local OB = findScript("ops_board")
  if not (OB and OB.openBoard) then P("CP BOARD: no board") return end
  -- the board is the Command Centre's console: stand in the building (econprobe)
  local cc = find("FacCommand")
  local a = find("Astronaut")
  if cc and a then
    local p = cc:toWorld(vec3(0, 1.5, 5))
    a.x, a.y, a.z = p.x, p.y, p.z
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  -- (something closes it while the crew settles: keep it up for the picture)
  local function keep() if not OB.isOpen() then OB.openBoard() end; if OB.selectedId() ~= id then OB.selectContract(id) end end
  local t0 = W()
  while W() - t0 < 1.5 do keep(); yield() end
  P("CP BOARD %s: open %s selected %s", nm, tostring(OB.isOpen()), tostring(OB.selectedId and OB.selectedId()))
  local done = false
  local ok = pcall(camera.capture, { w = 1600, h = 900, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://careershots/" .. nm .. ".png", bytes); P("CP SHOT %s", nm)
    else P("CP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  local t1 = W()
  while ok and not done and W() - t1 < 6 do keep(); yield() end
end
function CP.close_board()
  local OB = findScript("ops_board")
  if OB and OB.closeBoard then OB.closeBoard() end
  wait(0.4)
end
-- the objectives card made to follow contract `id` (as the player's / would)
function CP.card(id, nm)
  local OBJ = findScript("objectives")
  -- (an older save meets its agency once: that prompt outranks the contract)
  local em = findScript("emblem")
  if em and em.clearPrompt then pcall(em.clearPrompt) end
  if OBJ and OBJ.cycle then
    for _ = 1, 8 do
      if OBJ.selected() == "contract:" .. id then break end
      OBJ.cycle(1)
      yield()
    end
  end
  wait(0.8)
  P("CP CARD %s: picked %s · headline '%s'", nm, tostring(OBJ and OBJ.selected and OBJ.selected()), tostring(OBJ and OBJ.headline))
  CP.shot(nm)
end
function CP.offer(MI, fn)
  for _, m in ipairs(MI.offers()) do if fn(m) then return m end end
  return nil
end

function CP.career()
  wait_ready(120)
  wait(2)
  local MI, CO, inv, mats = findScript("missions"), findScript("company"), findScript("inventory"), findScript("materials")
  if not CP.check("scene", MI and CO and inv and mats and MI.actives and MI.advanceFor and CO.clawBack,
    "missions %s company %s (E1 %s)", tostring(MI ~= nil), tostring(CO ~= nil), tostring(MI and MI.actives ~= nil)) then CP.result() return end
  -- a career at Contractor that has flown the High Road, ground work open
  save.set("mission.done", { firstflight = true, highroad = true, prospect = true })
  save.set("prog.done", { first_steps = true })
  save.set("co.rep", 3)
  save.set("co.funds", 6000)
  save.set("co.loan", 0)
  save.set("debug.rich", false)
  wait(2.5)   -- (the board refills once a second)
  local orbit = MI.byId("orbit")
  local bulk = CP.offer(MI, function(m) return m.ground and m.kind == "bulk" end)
  local fl2 = CP.offer(MI, function(m) return m.gen and not m.ground end)
  CP.check("offers", orbit and bulk, "Made Orbit %s · bulk haul %s · a generated flight %s", tostring(orbit ~= nil),
    tostring(bulk and bulk.title), tostring(fl2 and fl2.title))
  if not (orbit and bulk) then CP.result() return end
  -- 1. sign the flight: the advance
  local b0 = CO.balance()
  local adv1 = MI.advanceFor(orbit)
  CP.check("sign_flight", MI.accept("orbit") == true and CO.balance() == b0 + adv1 and adv1 == 3300,
    "Made Orbit signed · advance $%d · balance $%d → $%d", adv1, b0, CO.balance())
  -- 2. sign the ground job beside it
  local b1 = CO.balance()
  local adv2 = MI.advanceFor(bulk)
  CP.check("sign_ground", MI.accept(bulk.id) == true and CO.balance() == b1 + adv2 and #MI.actives() == 2 and MI.active == "orbit",
    "%s signed beside it · advance $%d · on the books %s", bulk.title, adv2, table.concat(MI.actives(), ", "))
  local blocked = fl2 and MI.signBlock(fl2) or MI.signBlock(MI.byId("botany") or {})
  CP.check("third_refused", blocked ~= nil and (fl2 == nil or MI.accept(fl2.id) == false), "a third: %s", tostring(blocked))
  -- pictures: the board on each contract and on a blocked offer; the card
  CP.board("orbit", "career_board_flight")
  CP.board(bulk.id, "career_board_ground")
  if fl2 then CP.board(fl2.id, "career_board_blocked") end
  CP.close_board()
  CP.card("orbit", "career_card_flight")
  CP.card(bulk.id, "career_card_ground")
  -- 3. abandon the flight: the advance goes back
  local r0, b2 = CO.rep(), CO.balance()
  MI.abandon("orbit")
  CP.check("abandon", CO.balance() == b2 - adv1 and CO.rep() == r0 - 1 and MI.active == bulk.id and #MI.actives() == 1,
    "Made Orbit abandoned · balance $%d → $%d · rep %d → %d · on the books %s", b2, CO.balance(), r0, CO.rep(), table.concat(MI.actives(), ", "))
  -- 4. deliver the bulk haul: paid less its advance, a point of standing
  local g = bulk.goals[1]
  local mat = g.mat or "iron"
  local r1, b3 = CO.rep(), CO.balance()
  inv.add("base", mat, math.ceil(g.kg / math.max(mats.kg(mat) or 1, 0.01)) + 2)
  wait_for(function() return not MI.isActive(bulk.id) end, 8, "the haul to pay")
  CP.check("haul_paid", not MI.isActive(bulk.id) and CO.balance() == b3 + bulk.reward - adv2,
    "%s delivered · paid $%d (reward $%d less the $%d advance)", bulk.title, CO.balance() - b3, bulk.reward, adv2)
  CP.check("haul_rep", CO.rep() == r1 + 1, "rep %d → %d (ground work earns standing, to Trusted)", r1, CO.rep())
  wait(1.0)
  CP.shot("career_paid")
  CP.result()
end

function CP.old()
  wait_ready(150)
  wait(4)
  local MI, CO = findScript("missions"), findScript("company")
  if not CP.check("scene", MI and CO and MI.actives, "") then CP.result() return end
  local f0, l0, r0 = CO.balance(), CO.owed(), CO.rep()
  local act = MI.actives()
  P("CP OLD: mode %s · funds $%d · owed $%d · rep %d · on the books %s · slot2 %s", tostring(save.get("game.mode")), f0, l0, r0,
    table.concat(act, ", "), tostring(save.get("mission.active2")))
  CP.check("old_contract", #act == 1 and act[1] == save.get("mission.active") and MI.active == act[1],
    "its contract %s is slot one", tostring(act[1]))
  CP.check("old_advance", MI.advancePaid(act[1]) == 0, "signed before the advance: pays in full ($%d)", (MI.byId(act[1]) or {}).reward or -1)
  -- BENCH_PARAMS='("cpfunds", 1706.0), ("cploan", 1500.0)': the save's own
  -- figures. The programme may pay stages as the save loads (a milestone goal
  -- the save already meets), 25 % of it to the loan, so nothing LOST is the
  -- check: funds no lower, owed no higher.
  local exp_f, exp_l = params.cpfunds, params.cploan
  CP.check("old_funds", (exp_f == nil or f0 >= exp_f) and (exp_l == nil or l0 <= exp_l),
    "funds $%d (save %s) · owed $%d (save %s)", f0, tostring(exp_f), l0, tostring(exp_l))
  CP.board(act[1], "careerold_board")
  CP.close_board()
  CP.card(act[1], "careerold_card")
  -- a ground job beside it, and walking away from it again
  local gj = nil
  for _, m in ipairs(MI.offers()) do if MI.slotGroup(m) == "ground" and not MI.signBlock(m) then gj = m break end end
  if gj then
    -- (net worth: the advance credited pays 25 % to an owed loan, and the
    -- claw-back takes the whole advance back, so funds − owed is what holds)
    local w0 = CO.balance() - CO.owed()
    local ok = MI.accept(gj.id)
    CP.check("old_second", ok == true and #MI.actives() == 2 and MI.active == act[1], "%s signed beside it (advance $%d)", gj.title, MI.advancePaid(gj.id))
    CP.board(gj.id, "careerold_board_two")
    CP.close_board()
    MI.abandon(gj.id)
    CP.check("old_clawback", CO.balance() - CO.owed() == w0 and #MI.actives() == 1, "abandoned: funds − owed $%d → $%d", w0, CO.balance() - CO.owed())
  else
    P("CP OLD: no ground job on its board to sign beside it")
  end
  CP.result()
end
