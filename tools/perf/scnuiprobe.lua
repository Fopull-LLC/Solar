-- SCNUIPROBE: the scenario screens in the real game (tools/perf/scnuishots.sh;
-- scripts/menu_scenarios.lua, scenario_ui.lua, scenario_stage.lua,
-- ops_strip.lua). Each picture is taken at 1920×1080 and 2560×1440.
--
--   1. the menu: the card with its SCENARIOS row; the SCENARIOS page (a run
--      selected, then a locked one)
--   2. PLAY on a scenario exactly as the key does (menu_scenarios.playScenario
--      → scenario.prepareSlot → the system scene); the curtain line
--   3. BRIEFING (typing, then whole), GO; the Ops strip with its history and
--      the SCENARIO chip; a dialogue line, a choice; a cutscene with its
--      caption and a line in the letterbox; DEBRIEF (silver, then failed);
--      the controls page with the Scenarios keys
--
-- With FW-A's scenario_run in the build the panels follow its state; without
-- it they are shown through scenario_ui.preview(state), and the stage through
-- its own entry points (onSay / onChoice / onCutscene), as the runner calls them.
--
-- Pictures to user://scnuishots/, lines "SCNUI ", one "RESULT" a check.
defaults = { quit = 1, id = "fx_two_rooms" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("SCNUI %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function frames(n) for _ = 1, n do yield() end end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  for _, sz in ipairs({ { 1920, 1080 }, { 2560, 1440 } }) do
    pending = pending + 1
    local nm = string.format("%s_%d", name, sz[2])
    local ok, err = pcall(camera.capture, { w = sz[1], h = sz[2], ui = true, draws = true }, function(bytes, why)
      pending = pending - 1
      if bytes then assets.writeBytes("user://scnuishots/" .. nm .. ".png", bytes); P("SHOT %s", nm)
      else P("SHOT %s failed %s", nm, tostring(why)) end
    end)
    if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  end
  wait_for(function() return pending == 0 end, 10, "shot " .. name)
end

local SCORE = {
  { label = "Time", value = "21:40", par = "20:00", ok = false },
  { label = "Funds spent", value = "$6,120", par = "$9,000", ok = true },
  { label = "Pieces placed", value = "38", par = "40", ok = true },
  { label = "Hints", value = "1" },
  { label = "Crew", value = "safe", ok = true },
}

-- With FW-A's runner: the scenario plays itself (its brief, cutscenes, lines,
-- a choice, an alarm); the probe answers as a player would (Enter on a read
-- line, 1 on a choice), takes each screen the first time it shows, then
-- completes the steps (F11's completeStep) to reach the debrief.
function real_flow(run, ui_, gm)
  local seen = {}
  local function once(name, cond) if cond and not seen[name] then seen[name] = true; shot("real_" .. name) end end
  hold(1.0)
  once("curtain", gm and gm.curtain)
  wait_for(function() return ui_.showing() == "brief" end, 300, "the briefing")
  hold(7.0)
  R("brief", ui_.showing() == "brief" and physics.isPaused(), "the runner's briefing up, paused %s", tostring(physics.isPaused()))
  shot("real_briefing")
  input.simulate({ key = "enter", down = true }); frames(2); input.simulate({ key = "enter", down = false })
  wait_for(function() local st = run.state(); return st and st.phase == "running" end, 10, "running")
  R("go", run.state().phase == "running", "phase %s", tostring(run.state().phase))
  local sg, os_ = findScript("scenario_stage"), findScript("ops_strip")
  local t_end = W() + 90
  local read_t = nil
  local chose = false
  while W() < t_end do
    local cur = sg.current()
    once("cutscene", sg.cutsceneOn() and cur ~= nil and cur.typed)
    once("dialogue", (not sg.cutsceneOn()) and cur ~= nil and cur.typed and #(cur.choices or {}) == 0)
    once("alarm", sg.alarmOn and sg.alarmOn())
    once("ops_strip", os_.current ~= nil and os_.queue().cur and os_.queue().cur.typed)
    once("chip", ui_.showing() == "chip" and not sg.busy())
    if cur and cur.typed then
      if #(cur.choices or {}) > 0 then
        hold(0.5); once("choice", true)
        sg.choose(1); chose = true
      else
        read_t = read_t or W()
        if W() - read_t > 1.0 then input.simulate({ key = "enter", down = true }); frames(2); input.simulate({ key = "enter", down = false }); read_t = nil end
      end
    end
    if seen.cutscene and seen.choice and seen.alarm and seen.chip and W() - (t_end - 90) > 40 then break end
    yield()
  end
  R("story", seen.cutscene and seen.dialogue ~= nil, "seen: cutscene %s dialogue %s choice %s alarm %s strip %s chip %s",
    tostring(seen.cutscene), tostring(seen.dialogue), tostring(seen.choice), tostring(seen.alarm), tostring(seen.ops_strip), tostring(seen.chip))
  -- to the end: complete the steps by hand
  for _ = 1, 20 do
    local st = run.state()
    if st.phase == "done" or st.phase == "failed" then break end
    if sg.current() then if #(sg.current().choices or {}) > 0 then sg.choose(1) else sg.advance(); sg.advance() end end
    if sg.cutsceneOn() then sg.skipCutscene() end
    run.completeStep()
    hold(1.0)
  end
  wait_for(function() return ui_.showing() == "debrief" end, 20, "the debrief")
  hold(1.0)
  R("debrief", ui_.showing() == "debrief", "phase %s medal %s", tostring(run.state().phase), tostring(run.state().medal))
  shot("real_debrief")
  P("DONE fails %d", FAILS)
end

local function main()
  NODE.persistent = true
  -- 1. the menu
  scene.load("menu")
  yield()
  local ms = wait_for(function() return findScript("menu_scenarios") end, 30, "the menu")
  if not ms then R("menu", false, "no menu_scenarios"); return end
  hold(1.5)
  shot("menu_card")
  ms.openPanel()
  hold(1.0)
  local list = ms.scenarios() or {}
  R("panel", ms.open and #list >= 1, "%d scenarios listed, selected %s", #list, tostring(ms.selected()))
  shot("panel")
  for _, sc in ipairs(list) do
    if sc.requires then
      local row = find("Scn Row " .. sc.id)
      if row and ui.focus then ui.focus(row) end
      hold(0.5)
      shot("panel_locked")
      break
    end
  end
  -- 2. PLAY
  ms.playScenario(params.id)
  yield()
  local gm = wait_for(function() local g = findScript("game_manager"); return g and g.curtain and g end, 60, "the curtain")
  R("slot", save.slot() == "scn" and save.get("g_scenario") == params.id, "slot %s g_scenario %s", tostring(save.slot()), tostring(save.get("g_scenario")))
  local ui_ = wait_for(function() return findScript("scenario_ui") end, 30, "scenario_ui")
  if not findScript("scenario", { quiet = true }) then pcall(spawn, "ScenarioLib", vec3(0, 0, 0)); frames(3) end
  local run = findScript("scenario_run")
  P("scenario_run present: %s", tostring(run ~= nil))
  local sc = nil
  do
    local L = findScript("scenario")
    if L and L.load then sc = L.load(params.id) end
    if not sc then
      local ms2 = findScript("menu_scenarios")
      P("no rulebook in the system scene to load %s from", params.id)
    end
  end
  sc = sc or { title = params.id, brief = { "…" }, steps = { { text = "…" } } }
  if run then return real_flow(run, ui_, gm) end
  local ST = { active = true, id = params.id, title = sc.title, teaches = sc.teaches, brief = sc.brief, step = 1,
               steps = #(sc.steps or {}), stepText = sc.steps and sc.steps[1] and sc.steps[1].text, elapsed = 0,
               par = sc.score and sc.score.par, after = sc.after or "freeplay", phase = "loading", version = 1 }
  if not run and ui_ then ui_.preview(ST) end
  hold(2.0)
  if gm and gm.curtain then shot("curtain") end
  R("curtain", ui_ and ui_.showing() == "curtain", "showing %s", tostring(ui_ and ui_.showing()))
  wait_for(function()
    local pw, g, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and g and bf and bf.sited and not g.loading and not g.curtain and not (bf.grading and bf.grading())
  end, 300, "the reveal")
  local wx = findScript("weather"); if wx and wx.force then wx.force("clear") end
  hold(2.0)
  -- 3. BRIEFING
  if not run then ST.phase, ST.version = "briefing", 2 end
  wait_for(function() return ui_.showing() == "brief" end, 120, "the briefing")
  hold(1.2)
  shot("brief_typing")
  hold(6.0)
  R("brief", ui_.showing() == "brief" and physics.isPaused(), "briefing up, physics paused %s", tostring(physics.isPaused()))
  shot("briefing")
  local go = find("Scenario Go")
  input.simulate({ key = "enter", down = true }); frames(2); input.simulate({ key = "enter", down = false })
  hold(1.0)
  R("go", ui_.lastAction == "go" or (run and run.state and run.state().phase == "running"), "after Enter: %s", tostring(ui_.lastAction))
  if not run then ST.phase, ST.elapsed, ST.version = "running", 252, 3 end
  -- the Ops strip and the chip
  local os_ = findScript("ops_strip")
  os_.say("Sealed. Now split it.")
  os_.say("Good wall. The door goes on the side away from the wind.", "Okafor")
  os_.say("Ops copies. The scrubber crate is on the pallet by the pad plate, second from the left.")
  for i = 1, 3 do
    wait_for(function() return os_.queue().cur and os_.queue().cur.typed end, 15, "typed")
    if i < 3 then os_.skipLine(); hold(0.7) end
  end
  hold(0.3)
  R("strip", #os_.history() >= 2 and os_.current ~= nil, "history %d, now: %s", #os_.history(), tostring(os_.current and os_.current.shown))
  R("chip", ui_.showing() == "chip", "showing %s", tostring(ui_.showing()))
  shot("ops_strip_chip")
  os_.skipLine(); os_.skipLine()
  -- the stage: a line, a choice
  local sg = findScript("scenario_stage")
  sg.onSay({ who = "okafor", name = "Dele Okafor", tag = "ENGINEER",
             text = "Number two loop is cold. Give me ten minutes with the pumps and I can bring it up without tripping anything." })
  hold(1.0)
  shot("dialogue_typing")
  wait_for(function() return sg.current() and sg.current().typed end, 10, "the line typed")
  sg.advance()
  sg.onChoice({ who = "hale", name = "Dr. Hale", tag = "PLANT CHIEF", color = { 1.0, 0.8, 0.5 }, prompt = "Your call, chief. By the book, or do we push it?",
                options = { "By the book. Pumps first, rods at ten percent.", "We are behind. Push it to forty.", "Ask Okafor what he thinks." }, t0 = 1 })
  wait_for(function() return find("Scenario Choice 1") ~= nil end, 10, "the choices")
  hold(0.4)
  R("choice", sg.dialogueOpen() and physics.isPaused(), "choice up, world held %s", tostring(physics.isPaused()))
  shot("choice")
  sg.choose(1)
  hold(0.5)
  -- a cutscene
  sg.onCutscene(true)
  hold(0.8)
  sg.caption("HALDANE STATION", "Reactor hall, night shift, 0400")
  hold(0.5)
  R("cutscene", sg.cutsceneOn() and sg.holdsEsc(), "bars up, Esc held to skip")
  shot("cutscene")
  sg.onSay({ who = "hale", name = "Dr. Hale", tag = "PLANT CHIEF", text = "Pump two just sheared its coupling." })
  wait_for(function() return sg.current() and sg.current().typed end, 10, "the line typed")
  shot("cutscene_line")
  sg.advance()
  sg.skipCutscene()
  hold(1.0)
  R("cut_out", not sg.cutsceneOn(), "bars down")
  shot("after_dialogue_log")
  R("log", #os_.history() >= 3, "the Ops log holds %d lines after the dialogue", #os_.history())
  hold(4.0)
  -- DEBRIEF
  if not run then
    ST.phase, ST.outcome, ST.medal, ST.version = "done", "done", "silver", 5
    ST.debrief = (sc.debrief and sc.debrief.silver) or "Sealed and breathing."
    ST.score = SCORE
  end
  wait_for(function() return ui_.showing() == "debrief" end, 20, "the debrief")
  hold(0.8)
  shot("debrief")
  if not run then
    ST.phase, ST.outcome, ST.medal, ST.failText, ST.version = "failed", "fail", nil, "Okafor did not make it.", 6
    ST.debrief = (sc.debrief and sc.debrief.fail) or "It ends here."
    hold(1.0)
    shot("debrief_fail")
    ui_.preview(nil)
  end
  -- the controls page
  local pm = findScript("pause_menu")
  if pm then pm.openMenu(); pm.showPage("controls"); frames(60); shot("controls"); pm.close() end
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
