-- SCNACT — one act of a scenario, started at its checkpoint, for frame timing
-- (perfmap 2026-11-11). Spliced after framemon.lua by scnprobe.sh:
--   EXTRA_LUA="tools/perf/framemon.lua tools/perf/scnact.lua" \
--   BENCH_STRS='("cp", "home"), ("fm_steps", "home"), ("fm_map", "1"), ("fm_warp1", "1")' \
--   scnprobe.sh <engine> dust_season
-- The slot is prepared as PLAY does, then marked as a retry from checkpoint
-- `cp` (the steps before it latched, scn.retryFrom: staging puts the
-- checkpoint's stage table on top, as scenario_run.checkpoint_restore does,
-- without the first staging), and the act is played for act_secs (default
-- 150): lines clicked through, choices answered 1, cutscenes left to run.
-- framemon files every frame under its step, the map open or shut, the warp.
local SP_run_full = SP.run
function SP.run()
  local cp = params.cp and tostring(params.cp) or nil
  if not cp then return SP_run_full() end
  NODE.persistent = true
  perf.enable(true)
  local id = tostring(params.scn or "_probe")
  if not find("ScenarioLib") then spawn("ScenarioLib", vec3(0, 0, 0)) end
  local R = wait_for(function() return findScript("scenario") end, 10, "the rulebook")
  if not SP.check("rulebook", R ~= nil, "ScenarioLib in the probe scene") then SP.result() return end
  local sc = R.load(id)
  if not SP.check("load", sc ~= nil, "%s", id) then SP.result() return end
  local ok, err = R.prepareSlot(id)
  if not SP.check("prepare", ok, "slot %s: %s", tostring(save.slot()), tostring(err)) then SP.result() return end
  local d = {}
  for _, sid in ipairs(R.beforeCheckpoint(sc, cp)) do d[sid] = 0 end
  save.set("scn.done", d)
  save.set("scn.retryFrom", cp)
  save.set("scn.cp", cp)
  save.set("scn.started", true)
  local t0 = W()
  scene.load("system")
  yield()
  local sr = wait_for(function() local s = findScript("scenario_run"); return s and s.isActive and s.isActive() and s end, 120, "the runner")
  if not SP.check("runner", sr ~= nil, "active") then SP.result() return end
  local ph = SP.wait_phase({ "running", "briefing" }, 240)
  SP.check("staged", ph ~= nil, "at checkpoint %s in %.1f s (staging %.0f ms)", cp, W() - t0, sr.lastStage and sr.lastStage.ms or -1)
  if ph == "briefing" then sr.go() end
  local gm = findScript("game_manager")
  wait_for(function() return gm and not gm.curtain end, 60, "the reveal")
  local gx = findScript("graphics")
  if gx and gx.set then gx.set(tostring(params.gfx or "High")) end
  SP.readings("at " .. cp)
  local secs = tonumber(params.act_secs or 150) or 150
  local ts = W()
  while W() - ts < secs do
    sr = SP.run_() or sr
    local st = sr.state()
    if st.phase ~= "running" then break end
    if st.choice then sr.choose(1)
    elseif st.line and st.line.t0 and (time - st.line.t0) > 0.8 then sr.lineDone() end
    yield()
  end
  SP.readings("after " .. cp)
  if space.warp then space.warp(1) end
  local idle = SP.cost("the act", 3)
  SP.result()
end
