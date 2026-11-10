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
SOLVERS._story = function()
  local sr = SP.run_()
  wait(1.5)
  local st = sr.state()
  SP.check("cutscene", st.cutscene == true, "the intro is a cutscene (inputOwner %s)", tostring((findScript("game_manager") or {}).inputOwner))
  SP.shot("02_cutscene_orbit", true)
  wait(2.0)
  SP.shot("03_cutscene_dolly", true)
  -- Esc held a second skips the rest
  key_down("escape"); wait(1.3); key_up("escape")
  SP.check("skip", not sr.state().cutscene and sr.lastSkipped ~= nil, "Esc held skipped the intro (at %s)", tostring(sr.lastSkipped))
  wait_for(function() return sr.state().choice end, 30, "the choice")
  SP.shot("04_choice", true)
  SP.check("choice", sr.state().choice ~= nil, "the choice is up")
  tap("1")
  wait(0.5)
  SP.check("choice_var", sr.var("trust") == 1, "trust = %s", tostring(sr.var("trust")))
  SP.stand("mark:door", 30)
  SP.wait_step("walk", 15)
  wait_for(function() return sr.var("faulted") end, 30, "the fault")
  wait(0.8)
  SP.shot("05_fault", true)
  SP.check("knock", sr.var("faulted") == true, "the fault cutscene ran its knock")
  wait_for(function() return not sr.state().cutscene end, 20, "the fault's end")
  local ST, RU = findScript("structures"), findScript("ruins")
  local sid, uid = sr.pieceOf({ struct = "Story Hut", part = "lightFitting" })
  local p = sid and ST.getPart(sid, uid)
  SP.check("knocked", p and p.wr == true, "the light reads as knocked")
  if RU and RU.repairPiece then RU.repairPiece(sid, uid) end
  SP.wait_step("fix", 20)
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
  local solve = SOLVE or SOLVERS[id]
  if solve then
    local okS, e = pcall(solve, SP)
    if not okS then SP.check("solve", false, "error %s", tostring(e)) end
  else SP.generic() end
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
