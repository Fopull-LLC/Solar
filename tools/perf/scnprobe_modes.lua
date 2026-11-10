-- ── scenario probe (tools/perf/scnprobe.sh; docs/scenarios.md §8) ──────────
-- Spliced into a copy of perfbench.lua. Mode "scn": the scenario named by
-- strs.scn is started as PLAY starts it, staged, and solved: SOLVE(SP) from
-- scenarios/<id>/solve.lua (spliced after this file) or the built-in solvers
-- below (_probe, _story), else the generic one (F11's completeStep a step).
-- `SP PASS|FAIL <check>`, `SP COST`, `SP RESULT`. Pictures: save/user/scnshots/.
SP = { fails = 0, passed = 0 }
function SP.check(name, okc, fmt, ...)
  P("SP %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then SP.passed = SP.passed + 1 else SP.fails = SP.fails + 1 end
  return okc
end
function SP.result() P("SP RESULT %s (%d passed, %d failed)", SP.fails == 0 and "PASS" or "FAIL", SP.passed, SP.fails) end
function SP.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://scnshots/" .. nm .. ".png", bytes); P("SP SHOT %s", nm)
    else P("SP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function SP.run_() return findScript("scenario_run") end
function SP.cost(tag, secs)
  local t0 = W()
  local f0 = FRAME
  wait(secs or 4)
  local ms = perf.scriptMs and perf.scriptMs("scenario_run") or -1
  local ms2 = perf.scriptMs and perf.scriptMs("scenario") or -1
  local sr = SP.run_()
  P("SP COST %s: scenario_run %.4f ms/frame, scenario %.4f · last eval %.3f ms · %d evals · %d frames", tag, ms, ms2,
    sr and sr.PROF.eval_ms or -1, sr and sr.PROF.evals or -1, FRAME - f0)
  return ms
end
function SP.readings(tag)
  local sr = SP.run_()
  local st = sr and sr.state()
  if not st then return end
  P("SP STATE %s: phase %s step %s/%s %s · %s", tag, tostring(st.phase), tostring(st.step), tostring(st.steps), tostring(st.stepId), tostring(st.stepText))
  for i, g in ipairs(st.goals or {}) do P("SP   goal %d %s %s: %s", i, g.met and "✓" or "·", tostring(g.label), tostring(g.reading)) end
end
-- the controlled crew, on a ref (body-relative → world now), held a few frames
function SP.stand(ref, frames_)
  local sr = SP.run_()
  local a = astro()
  for _ = 1, frames_ or 20 do
    local x, y, z = sr.pointOf(ref)
    if x and a then
      local p = sr.posOf(ref)
      local l = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
      local b = space.body(p.body)
      a.x, a.y, a.z = b.x + p.x * (l + 1) / l, b.y + p.y * (l + 1) / l, b.z + p.z * (l + 1) / l
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    yield()
  end
end
function SP.wait_step(id, tmo)
  local sr = SP.run_()
  local ok = wait_for(function() return (save.get("scn.done") or {})[id] ~= nil end, tmo or 30, "step " .. id)
  if not ok then SP.readings("stalled at " .. id) end
  return SP.check("step_" .. id, ok ~= nil, "%s latched", id)
end
function SP.wait_phase(want, tmo)
  local sr = SP.run_()
  return wait_for(function() local p = sr.phaseNow(); for _, w in ipairs(want) do if p == w then return p end end end, tmo or 60, "phase " .. table.concat(want, "|"))
end

-- built-in solvers ----------------------------------------------------------
SOLVERS = SOLVERS or {}
SOLVERS._probe = function()
  local sr = SP.run_()
  SP.stand("mark:post", 30)
  SP.wait_step("walk", 15)
  for _ = 1, 8 do SP.stand("mark:post", 40) if (save.get("scn.done") or {}).wait then break end end
  SP.wait_step("wait", 20)
  -- the camera beat on the hut
  wait(2.0)
  local pc = findScript("planet_camera")
  SP.check("camera_beat", pc and pc.cinematic == true, "the camera beat is up (cinematic %s)", tostring(pc and pc.cinematic))
  SP.shot("02_camera_beat", true)
  wait(1.5)
  SP.shot("03_camera_beat_late", true)
  SP.wait_step("flag", 30)
end
-- the story probe: the v2 story features and the FW-C pack (work/scenarios2
-- PLAN §2): a walk that steers, look and face, two speakers on the plate, a
-- radio voice 3 s away, the time held at evening, a light beat, meters, a
-- model, runtime portraits, and a SETBACK back to the fix checkpoint
local function body_of(name)
  local C = findScript("crew")
  local id = (save.get("scn.crew") or {})[name]
  for _, s in ipairs(findScripts("crew_body")) do if s.memberId == id and not s.doll then return s, id end end
  return nil, id
end
local function frame_watch()
  -- the worst frame while something runs (the portrait captures)
  local w = { t = W(), worst = 0, n = 0, sum = 0 }
  function w.tick() local t = W(); local d = t - w.t; w.t = t; w.n = w.n + 1; w.sum = w.sum + d; if d > w.worst then w.worst = d end end
  return w
end
SOLVERS._story = function()
  local sr = SP.run_()
  local fw = frame_watch()
  wait(1.2)
  local st = sr.state()
  SP.check("cutscene", st.cutscene == true, "the intro is a cutscene (inputOwner %s)", tostring((findScript("game_manager") or {}).inputOwner))
  -- (the reveal can take a while: wait for a line with a listener, the intro has two)
  local wl = wait_for(function() local l = sr.state().line; return l and l.with and l end, 10, "a two-speaker line")
  st = sr.state()
  SP.check("two_speakers", wl ~= nil and (wl.with.name == "Dele Okafor" or wl.with.name == "Dr. Hale"), "a line with a listener: %s with %s",
    tostring(wl and wl.name), tostring(wl and wl.with and wl.with.name))
  SP.shot("02_cutscene_two_speakers", true)
  -- the time held at evening: the Lighting node on its directional sun
  local ln = find("Lighting"); local lit = ln and ln:getcomponent("Light")
  local LT = sr.lightState
  SP.check("time_hold", LT and LT.hold and lit and lit.stars == false, "world.time held (el %s, stars %s, intensity %.3f, dir %.2f %.2f %.2f)",
    tostring(LT and LT.el), tostring(lit and lit.stars), lit and lit.intensity or -1, lit and lit.directionX or 0, lit and lit.directionY or 0, lit and lit.directionZ or 0)
  -- Reyes walks to the ridge: her body moves a bit at a time, along the ground
  local cb = wait_for(function() local b = body_of("Reyes"); return b and b.walking and b.walking() and b end, 20, "Reyes walking")
  local _, d0, h0 = nil, nil, nil
  if cb and cb.walkDist then local rr = sr.posOf("mark:ridge"); _, d0, h0 = cb.walkDist(rr.body, rr.x, rr.y, rr.z) end
  local gt0 = time
  local cost_cut = SP.cost("intro cutscene (shot, walk, look)", 2.0)
  local cb_ms = perf.scriptMs and perf.scriptMs("crew_body") or -1
  local r = sr.posOf("mark:ridge")
  local _, d1, h1 = nil, nil, nil
  if cb and cb.walkDist then _, d1, h1 = cb.walkDist(r.body, r.x, r.y, r.z) end
  P("SP WALK height over the ridge mark %.2f → %.2f m", h0 or -1, h1 or -1)
  if cb and cb.walkStats then P("SP WALK ticks %d stops %d metres %.2f game %.2f s", cb.walkStats.ticks, cb.walkStats.stops, cb.walkStats.metres, cb.walkStats.game) end
  SP.check("walk_steers", cb ~= nil and d0 and d1 and d1 < d0 - 1.0 and d1 > 0.5, "Reyes walked %.1f m → %.1f m from the ridge in %.2f game s (%.2f m/s; steered, not set down)",
    d0 or -1, d1 or -1, time - gt0, ((d0 or 0) - (d1 or 0)) / math.max(time - gt0, 1e-3))
  SP.check("cutscene_cost", cost_cut >= 0 and cost_cut < 0.1 + 0.05, "scenario_run %.4f ms a frame in the cutscene (crew_body %.4f ms, all bodies)", cost_cut, cb_ms)
  SP.shot("03_reyes_walking", true)
  wait(1.5)
  SP.shot("03b_cutscene_dolly", true)
  -- Esc held a second skips the rest
  if sr.state().cutscene then
    -- (held until a skip lands: the intro may end during the hold and the
    -- fault's cutscene begin, which the same hold then skips)
    key_down("escape"); wait_for(function() return sr.lastSkipped ~= nil end, 4, "a skip"); wait(0.1); key_up("escape")
    SP.check("skip", sr.lastSkipped ~= nil, "Esc held skipped a cutscene (at %s)", tostring(sr.lastSkipped))
  else
    SP.check("skip", true, "the intro had already ended (the plate follows the runner): nothing to skip")
  end
  wait_for(function() return sr.state().choice end, 30, "the choice")
  SP.shot("04_choice", true)
  SP.check("choice", sr.state().choice ~= nil, "the choice is up")
  tap("1")
  wait(0.5)
  SP.check("choice_var", sr.var("trust") == 1, "trust = %s", tostring(sr.var("trust")))
  -- the radio voice, 3 s after its beat (held behind the intro)
  local vline = wait_for(function() local l = sr.state().line; return l and l.name == "Mara Vance" and l end, 30, "the radio voice")
  SP.check("radio_delay", vline and vline.radio == true, "Mara Vance on the radio (radio %s)", tostring(vline and vline.radio))
  -- (the plate runs its own queue: wait for her line on it, not only in the runner)
  local stg = findScript("scenario_stage")
  wait_for(function() local c = stg and stg.current and stg.current(); if c and c.who ~= "Mara Vance" and stg.advance then stg.advance() end
                      return c and c.who == "Mara Vance" end, 30, "the radio plate")
  wait(1.2)
  SP.shot("05_radio_plate", true)
  -- runtime portraits: the faces this playthrough generated
  -- (graveyard2: the member you control, Okafor, keeps the booth picture; the others are taken live)
  wait_for(function() return (sr.PROF.portraits or 0) >= 1 and sr.portraitTex("reyes") ~= nil end, 20, "portraits")
  SP.check("portraits", sr.portraitTex("okafor") == nil and sr.portraitTex("reyes") ~= nil, "captured %d (okafor %s, reyes %s) in %.1f ms of capture waits; the longest frame while one ran %.1f ms",
    sr.PROF.portraits or 0, tostring(sr.portraitTex("okafor")), tostring(sr.portraitTex("reyes")), sr.PROF.portrait_ms or -1, sr.PROF.portrait_worst_ms or -1)
  SP.stand("mark:door", 30)
  SP.wait_step("walk", 15)
  wait_for(function() return sr.var("faulted") end, 30, "the fault")
  wait(2.4)
  SP.shot("06_fault_two_speakers", true)
  SP.check("knock", sr.var("faulted") == true, "the fault cutscene ran its knock")
  wait_for(function() return not sr.state().cutscene end, 20, "the fault's end")
  local UG = findScript("underground")
  SP.check("light_beat", UG and UG.scriptAmbient and math.abs(UG.scriptAmbient - 0.5) < 0.05, "the hut's ambient at %s", tostring(UG and UG.scriptAmbient))
  wait(4)
  SP.check("meter", (sr.var("dark_secs") or 0) > 2, "dark_secs %s, hut_c %s, hut_o2 %s", tostring(sr.var("dark_secs")), tostring(sr.var("hut_c")), tostring(sr.var("hut_o2")))
  -- a SETBACK: fail, the card, back to the fix with the story kept
  local trust, faulted = sr.var("trust"), sr.var("faulted")
  sr.fail("Probe setback.")
  wait(1.0)
  SP.check("setback_card", sr.phaseNow() == "setback", "a fail is a setback (phase %s)", tostring(sr.phaseNow()))
  SP.shot("07_setback_card", true)
  local sr2 = wait_for(function()
    local s = findScript("scenario_run")
    return s and s ~= sr and s.isActive and s.isActive() and s.phaseNow and s.phaseNow() == "running" and s
  end, 240, "the restore")
  SP.check("setback_restore", sr2 ~= nil and (save.get("scn.done") or {}).walk ~= nil and sr2.var("trust") == trust and sr2.var("faulted") == faulted
    and (tonumber(save.get("scn.setbacks")) or 0) == 1, "back at the fix: walk latched %s, trust %s, faulted %s, setbacks %s",
    tostring((save.get("scn.done") or {}).walk ~= nil), tostring(sr2 and sr2.var("trust")), tostring(sr2 and sr2.var("faulted")), tostring(save.get("scn.setbacks")))
  sr = sr2 or SP.run_()
  local gm = findScript("game_manager")
  wait_for(function() return gm and not gm.curtain end, 60, "the reveal")
  wait(2.0)
  local ST, RU = findScript("structures"), findScript("ruins")
  local sid, uid
  wait_for(function() sid, uid = sr.pieceOf({ struct = "Story Hut", part = "lightFitting" }); local p = sid and ST.getPart(sid, uid); return p and p.wr end, 20, "knocked again")
  local p = sid and ST.getPart(sid, uid)
  SP.check("knocked", p and p.wr == true, "the light reads as knocked again after the setback")
  if RU and RU.repairPiece and sid then RU.repairPiece(sid, uid) end
  SP.wait_step("fix", 30)
end
-- PORTRAIT BOOTH (tools/perf/portraitbooth.sh): every `portrait = "auto"`
-- cast member photographed with the runtime rig to user://booth/<key>.png;
-- one with only a `look` seed borrows another body's face for the shot
function SP.booth()
  local sr = SP.run_()
  local sc = sr.scenario()
  wait(1.0)
  if sr.state().cutscene then sr.skipCutscene() end
  wait(3.0)
  local donor = nil
  for _, c in pairs(sc.cast or {}) do
    local id = c.crew and (save.get("scn.crew") or {})[c.crew]
    local C = findScript("crew")
    if id and C and id ~= C.activeId() then donor = id end
  end
  local keys = {}
  for k, c in pairs(sc.cast or {}) do if c.portrait == "auto" then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local c = sc.cast[k]
    local id = c.crew and (save.get("scn.crew") or {})[c.crew] or donor
    local look = (not c.crew) and c.look or nil
    -- (graveyard2) the member you control is pictured from their own body:
    -- control goes to someone else for the picture (in first person the
    -- Astronaut's head is not drawn), and comes back after
    local C = findScript("crew")
    local back = nil
    if id and C and id == C.activeId() and donor then
      back = id
      C.control(donor)
      wait_for(function() return C.activeId() == donor end, 5, "control to the donor")
      wait(1.5)
    end
    local got = nil
    wait_for(function() return sr.capturePortrait(id, { bytes = true, look = look, expression = c.expression }, function(bytes, why) got = bytes or false; if not bytes then P("SP booth %s: %s", k, tostring(why)) end end) end, 10, "the rig")
    wait_for(function() return got ~= nil end, 10, "portrait " .. k)
    if got then assets.writeBytes("user://booth/" .. k .. ".png", got) end
    if tostring(params.wide or "") == "1" then
      local g2 = nil
      wait_for(function() return sr.capturePortrait(id, { bytes = true, look = look, dist = 2.5 }, function(b) g2 = b or false end) end, 10, "the rig")
      wait_for(function() return g2 ~= nil end, 10, "wide " .. k)
      if g2 then assets.writeBytes("user://booth/" .. k .. "_wide.png", g2) end
    end
    if back then C.control(back); wait_for(function() return C.activeId() == back end, 5, "control back"); wait(1.0) end
    SP.check("booth_" .. k, got ~= nil and got ~= false, "%s → booth/%s.png (%s)", tostring(c.name), k, look and ("look " .. look) or ("crew " .. tostring(c.crew)))
    wait(0.5)
  end
end
-- the generic solver: every step completed by hand, its readings first
function SP.generic()
  local sr = SP.run_()
  for _ = 1, 40 do
    local st = sr.state()
    if st.phase ~= "running" then break end
    SP.readings("before F11")
    if sr.state().cutscene then sr.skipCutscene() end
    if sr.state().choice then sr.choose(1) end
    local id = sr.completeStep()
    if id then SP.wait_step(id, 10) end
    wait(1.0)
  end
end

function SP.run()
  NODE.persistent = true
  perf.enable(true)
  local id = tostring(params.scn or "_probe")
  -- the rulebook from a ScenarioLib (as the menu does: the engine's Luau has no loadfile)
  if not find("ScenarioLib") then spawn("ScenarioLib", vec3(0, 0, 0)) end
  local R = wait_for(function() return findScript("scenario") end, 10, "the rulebook")
  if not SP.check("rulebook", R ~= nil, "ScenarioLib in the probe scene") then SP.result() return end
  local sc, err = R.load(id)
  if not SP.check("load", sc ~= nil, "%s: %s", id, tostring(err or sc.title)) then SP.result() return end
  local ok, errs = R.validate(sc, { techExists = nil })
  SP.check("validate", ok, "%s", table.concat(errs or {}, " | "))
  local t0 = W()
  ok, err = R.prepareSlot(id)
  if not SP.check("prepare", ok, "slot %s: %s", tostring(save.slot()), tostring(err)) then SP.result() return end
  scene.load("system")
  yield()
  local sr = wait_for(function() local s = findScript("scenario_run"); return s and s.isActive and s.isActive() and s end, 120, "the runner")
  if not SP.check("runner", sr ~= nil, "ScenarioLib spawned and active in slot %s", tostring(save.slot())) then SP.result() return end
  local ph = SP.wait_phase({ "running", "briefing" }, 240)
  SP.check("staged", ph ~= nil, "staged in %.1f s from PLAY (staging %.0f ms): %s", W() - t0, sr.lastStage and sr.lastStage.ms or -1,
    table.concat((sr.lastStage or {}).records or { tostring((sr.lastStage or {}).error) }, "; "))
  if ph == "briefing" then sr.go() end
  local gm = findScript("game_manager")
  wait_for(function() return gm and not gm.curtain end, 60, "the reveal")
  clear_weather()
  local gx = findScript("graphics")
  if gx and gx.set then gx.set(tostring(params.gfx or "High")) end
  wait(1.0)
  SP.shot("01_start", true)
  SP.readings("start")
  if id == "_probe" then SP.cost("running, the first step open", 5) end
  if tostring(params.booth or "") == "1" then SP.booth(); SP.result(); return end
  local solve = SOLVE or SOLVERS[id]
  if solve then
    local okS, e = pcall(solve, SP)
    if not okS then SP.check("solve", false, "error %s", tostring(e)) end
  else SP.generic() end
  sr = SP.run_()        -- (a setback reloads the scene: the runner is a new script)
  local fin = SP.wait_phase({ "done", "freeplay", "failed" }, 60)
  local st = sr.state()
  SP.check("finished", fin == "done" or fin == "freeplay", "phase %s outcome %s medal %s (%s)", tostring(fin), tostring(st.outcome), tostring(st.medal), tostring(st.failText))
  for _, r in ipairs(st.score or {}) do P("SP SCORE %s %s (par %s)", tostring(r.label), tostring(r.value), tostring(r.par)) end
  R = findScript("scenario") or R    -- (the probe scene's ScenarioLib went with the scene change)
  local prof = R.profileLoad()
  local e = R.profileEntry(prof, id)
  SP.check("profile", e and e.best ~= nil, "profile: best %s, %s plays", tostring(e and e.best), tostring(e and e.plays))
  SP.shot("09_end", true)
  local idle = SP.cost("freeplay (stood down)", 4)
  SP.check("cost", idle >= 0 and idle < 0.05, "scenario_run %.4f ms a frame stood down", idle)
  SP.result()
end
