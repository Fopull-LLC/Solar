-- SMOKE: the scenario screens (work/scenarios PLAN §1.5, §1.9, §1.10) —
-- scripts/ops_strip.lua (the comms line), scripts/scenario_ui.lua (the curtain
-- line, BRIEFING, the chip, DEBRIEF) and scripts/menu_scenarios.lua (the
-- SCENARIOS page on the main menu), against stubs of the engine and of the
-- framework's surface (scenario.listAll / slotSummary / prepareSlot /
-- profile*, scenario_run.state / go / listen / wantBriefing …).
--
-- The engine half (the panel opened, photographed, a scenario started to its
-- briefing) is tools/perf/scnuiprobe.lua (scnuishots.sh).
--
--   luajit solar/tests/smoke_menu_scenarios.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end

local function load(path, env)
  env = env or {}
  setmetatable(env, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end

local function readall(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

-- Every element of a described tree, flattened (items run through their builder).
local function walk(t, out)
  out = out or {}
  if type(t) ~= "table" then return out end
  if type(t[1]) == "string" then out[#out + 1] = t end
  for _, c in ipairs(t) do if type(c) == "table" then walk(c, out) end end
  local fn
  for _, c in ipairs(t) do if type(c) == "function" then fn = c end end
  if t.items and fn then for i, it in ipairs(t.items) do walk(fn(it, i), out) end end
  return out
end
local function by(tree, field, value)
  for _, e in ipairs(walk(tree)) do if e[field] == value then return e end end
  return nil
end
local function texts(tree)
  local o = {}
  for _, e in ipairs(walk(tree)) do if e.text then o[#o + 1] = tostring(e.text) end end
  return table.concat(o, " | ")
end

-- ── 1. THE OPS STRIP, pure ──────────────────────────────────────────────────
local O = load("solar/scripts/ops_strip.lua")
check(O.typed("Hello", 3) == "Hel" and O.typed("Hello", 0) == "" and O.typed("Hello", 99) == "Hello", "typed cuts by characters")
check(O.typed("N₂ and O₂", 2) == "N₂" and O.charCount("N₂") == 2, "typed never cuts inside a character")
check(O.charsAt(0.5, 40) == 20 and O.charsAt(0, 40) == 0, "40 characters a second")
do
  local q = O.newQueue()
  check(O.push(q, "Sealed. Now split it.") and not O.push(q, ""), "a line queues; an empty one is refused")
  O.push(q, "Second line.", "Okafor")
  check(O.tick(q, 1 / 60) == "start" and q.cur.who == "OPS", "the first line starts, spoken by OPS")
  local evs, t = {}, 0
  while q.cur and not q.cur.typed do local e = O.tick(q, 1 / 60); t = t + 1 / 60; if e then evs[e] = (evs[e] or 0) + 1 end end
  local n = O.charCount("Sealed. Now split it.")
  check(evs.typed == 1 and math.abs(t - n / 40) < 0.05, string.format("typed out in %.2f s (%d chars at 40/s)", t, n))
  -- a queued line cuts the hold after 1.5 s
  local held = 0
  while q.cur and q.cur.text:find("Sealed") do O.tick(q, 1 / 60); held = held + 1 / 60 end
  check(held > 1.4 and held < 1.7 and #q.hist == 1, string.format("a waiting line cuts the hold at 1.5 s (%.2f)", held))
  while not q.cur do O.tick(q, 1 / 60) end
  check(q.cur.who == "Okafor", "the next line is the crew member's")
  check(O.skip(q) == "typed" and q.cur.typed, "a click finishes the typing")
  check(O.skip(q) == "end" and q.cur == nil and #q.hist == 2, "a second click moves on")
  for i = 1, 5 do O.push(q, "line " .. i) end
  for _ = 1, 5 do while not q.cur do O.tick(q, 1 / 60) end O.skip(q); O.skip(q) end
  check(#q.hist == O.HISTORY and q.hist[O.HISTORY].text == "line 5", "three lines of history, oldest dropped")
  local idle = nil
  for _ = 1, 120 do local e = O.tick(q, 1 / 60); if e == "idle" then idle = true end end
  check(idle and q.fade == 1, "the strip fades once the last line is done")
end

-- ── 2. THE OPS STRIP, in a scene ────────────────────────────────────────────
do
  local played, made, scripts = {}, 0, {}
  local gm = { loading = false, curtain = false }
  scripts.sfx = { play = function(k) played[#played + 1] = k end }
  scripts.game_manager = gm
  local last_tree
  local env = {
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return { text = "", valid = true } end,
    ui = { make = function(_, t) made = made + 1; last_tree = t end },
  }
  local S = load("solar/scripts/ops_strip.lua", env)
  local el = { visible = false }
  local node = { getcomponent = function() return el end }
  S.start(node)
  S.update(node, 1 / 60)
  check(made == 0, "idle: nothing described")
  S.say("We need a shelter we can take a helmet off in.")
  gm.curtain = true
  for _ = 1, 30 do S.update(node, 1 / 60) end
  check(made == 0 and #played == 0, "behind the loading curtain the line waits")
  gm.curtain = false
  S.update(node, 1 / 60)
  check(played[1] == "card" and el.visible and made == 1, "a line starts with the Quindar chirp")
  local m0 = made
  for _ = 1, 40 do S.update(node, 1 / 60) end
  check(made == m0, "typing writes one text node, no re-describe (" .. (made - m0) .. ")")
  check(S.current and #S.current.shown > 5, "the line is typing: " .. tostring(S.current and S.current.shown))
  local strip = by(last_tree, "key", "strip")
  check(strip and strip.style == "hud/instrument" and strip.pin == "bottom", "a CRT display in a bezel, bottom of the screen")
  strip.onClicked()
  S.update(node, 1 / 60)
  check(played[#played] == "chime" and S.queue().cur.typed, "a click finishes the line, with the closing chirp")
  for _ = 1, 60 * 8 do S.update(node, 1 / 60) end
  check(not el.visible and S.current == nil, "the strip goes away when it is done")
end

-- ── 3. SCENARIO UI, pure ────────────────────────────────────────────────────
local U = load("solar/scripts/scenario_ui.lua")
check(U.clock(754) == "12:34" and U.clock(3725) == "1:02:05" and U.clock(nil) == "--:--", "clock")
do
  local a, b, c = U.chipText({ step = 3, steps = 7, elapsed = 252, par = 1200 })
  check(a == "3 / 7" and b == "4:12 / 20:00" and c == nil, "the chip: " .. a .. " · " .. b)
  a, b, c = U.chipText({ step = 7, steps = 7, elapsed = 1265, par = 1200 })
  check(c == "+1:05 over par", "over par: " .. tostring(c))
end
check(U.medalOf({ phase = "done", medal = "gold" }) == "gold" and U.medalOf({ phase = "failed" }) == "fail"
  and U.medalOf({ phase = "done" }) == "bronze", "medalOf")
do
  local b = U.buttonsFor({ phase = "failed", outcome = "fail" })
  check(b[1][1] == "retry" and b[2][1] == "restart" and b[3][1] == "menu", "after a failure: RETRY · RESTART · MENU")
  b = U.buttonsFor({ phase = "done", medal = "silver", after = "freeplay" })
  check(b[1][1] == "continue" and #b == 3, "after a finish: CONTINUE · RESTART · MENU")
  b = U.buttonsFor({ phase = "done", medal = "silver", after = "menu" })
  check(b[1][1] == "restart" and #b == 2, "after = menu: no CONTINUE")
end
do
  local L = { "Okafor, you are on Haldane.", "We need a shelter." }
  local t, all = U.briefText(L, 10)
  check(t[1] == "Okafor, yo" and t[2] == "" and not all, "the brief types line by line")
  t, all = U.briefText(L, 1000)
  check(t[2] == L[2] and all, "and ends whole")
end

-- ── 4. SCENARIO UI, in a scene ──────────────────────────────────────────────
do
  local paused, made, last, focused = false, 0, nil, nil
  local presses = {}
  local calls = {}
  local listeners = {}
  local said = {}
  local S = {
    active = true, id = "two_rooms", title = "Two Rooms", teaches = { "buildkit", "rooms" }, phase = "loading",
    brief = { "Okafor, you are on the night side of Haldane.", "Two rooms, one airlock." },
    step = 1, steps = 7, stepText = "Close the shell.", elapsed = 0, par = 1200, version = 1, after = "freeplay",
  }
  local run = {
    state = function() return S end,
    wantBriefing = function(on) calls.want = on end,
    listen = function(k, fn) listeners[k] = fn end,
    go = function() calls.go = (calls.go or 0) + 1; S.phase = "running"; S.version = S.version + 1 end,
    retry = function() calls.retry = true end, restart = function() calls.restart = true end,
    continueFreeplay = function() calls.cont = true end, toMenu = function() calls.menu = true end,
    hint = function() calls.hint = true end, lineDone = function() calls.lineDone = (calls.lineDone or 0) + 1 end,
  }
  local gm = { loading = true, curtain = true }
  local pm = { open = false }
  local scripts = { scenario_run = run, game_manager = gm, pause_menu = pm,
                    ops_strip = { say = function(t, w, d) said[#said + 1] = { t, w, d } end, skipLine = function() calls.skip = true end },
                    sfx = { play = function() end } }
  local env = {
    findScript = function(k) return scripts[k] end,
    find = function() return { text = "", valid = true } end,
    save = { get = function(k) if k == "g_scenario" then return "two_rooms" end end },
    physics = { pause = function(on) paused = on end, isPaused = function() return paused end },
    input = { pressed = function(k) return presses[k] == true end, setMouseLocked = function() end },
    ui = { make = function(_, t) made = made + 1; last = t end },
    space = { warp = function() return 1 end },
  }
  local UI = load("solar/scripts/scenario_ui.lua", env)
  local el = { visible = false }
  local node = { getcomponent = function() return el end }
  UI.start(node)
  local function frames(n) for _ = 1, n do UI.update(node, 1 / 60) end end
  frames(20)
  check(calls.want == true and listeners.ops and listeners.phase, "claims the briefing and listens for ops and phase")
  check(UI.showing() == "curtain" and texts(last):find("Two Rooms") and texts(last):find("BUILDKIT"), "the curtain line names it: " .. texts(last))
  listeners.ops("Sealed. Now split it.", nil)
  check(said[1] and said[1][1] == "Sealed. Now split it.", "an ops beat goes to the strip")
  said[1][3]()
  check(calls.lineDone == 1, "the strip answers lineDone when the ops line retires")
  gm.loading, gm.curtain = false, false
  S.phase, S.version = "briefing", 2
  frames(20)
  check(UI.showing() == "brief" and paused, "BRIEFING: up, and the world held")
  check(texts(last):find("FIRST") and texts(last):find("Close the shell"), "the first step is named")
  local m0 = made
  frames(30)
  check(made == m0, "the brief types without re-describing")
  presses.space = true; frames(1); presses.space = nil
  frames(20)
  check(by(last, "name", "Scenario Brief 2") and by(last, "name", "Scenario Brief 2").text == S.brief[2], "Space prints the brief whole")
  -- the pause menu over it lets the world go on close; the briefing takes it back
  pm.open = true; frames(5); paused = false; pm.open = false; frames(20)
  check(paused and UI.showing() == "brief", "the hold is re-asserted after the pause menu")
  local go = by(last, "name", "Scenario Go")
  check(go and go.style == "panel/action", "one GO key, lit")
  presses.enter = true; frames(1); presses.enter = nil
  check(calls.go == 1, "Enter is GO")
  frames(20)
  check(not paused and UI.showing() == "chip", "running: the world goes, the chip shows")
  check(texts(last):find("SCENARIO") and texts(last):find("1 / 7"), "the chip: " .. texts(last))
  by(last, "name", "Scenario Hint").onClicked()
  check(calls.hint, "the HINT key asks the runner (H holsters the tool)")
  local chip = by(last, "key", "chip")
  check(chip and chip.pin == "top" and chip.y == UI.CHIP_Y, "beside the warp chip, top centre")
  local mc = made
  frames(10)
  check(made == mc, "the chip redraws only when its second changes")
  S.phase, S.outcome, S.medal, S.version = "done", "done", "silver", 9
  S.debrief = "Sealed and breathing. The budget went on the roof."
  S.score = { { label = "Time", value = "21:40", par = "20:00", ok = false }, { label = "Funds spent", value = "$6,120", par = "$9,000", ok = true } }
  frames(20)
  check(UI.showing() == "debrief" and paused, "DEBRIEF: up, the world held")
  local tx = texts(last)
  check(tx:find("SILVER") and tx:find("Sealed and breathing") and tx:find("21:40") and tx:find("par 20:00"), "the medal, the copy and the numbers against par: " .. tx)
  local cont = by(last, "name", "Scenario Continue")
  check(cont and cont.style == "panel/action" and by(last, "name", "Scenario Restart") and by(last, "name", "Scenario Menu"), "CONTINUE lit, RESTART, MENU")
  cont.onClicked()
  check(calls.cont, "CONTINUE → continueFreeplay")
  S.phase, S.outcome, S.medal, S.failText, S.version = "failed", "fail", nil, "Okafor did not make it.", 10
  frames(20)
  tx = texts(last)
  check(tx:find("SCENARIO FAILED") and tx:find("Okafor did not make it"), "a failure says why")
  by(last, "name", "Scenario Retry").onClicked()
  by(last, "name", "Scenario Restart").onClicked()
  by(last, "name", "Scenario Menu").onClicked()
  check(calls.retry and calls.restart and calls.menu, "RETRY, RESTART and MENU reach the runner")
end
-- outside the scenario slot: nothing at all
do
  local touched = false
  local env = {
    findScript = function() touched = true end,
    save = { get = function() return nil end },
    ui = { make = function() touched = true end },
  }
  local UI = load("solar/scripts/scenario_ui.lua", env)
  local node = { getcomponent = function() return { visible = false } end }
  UI.start(node)
  for _ = 1, 30 do UI.update(node, 1 / 60) end
  check(not touched, "a career slot: scenario_ui does nothing")
end

-- ── 5. THE SCENARIOS PAGE ───────────────────────────────────────────────────
do
  local M = load("solar/scripts/menu_scenarios.lua")
  check(M.rowNote({ teaches = { "Rooms", "air", "airlock" }, par = 1200 }) == "rooms, air  ·  20 min", "a row's note")
  check(M.rowNote({ par = 0 }) == "—", "no par: a dash")
  check(M.continueLine({ id = "two_rooms", title = "Two Rooms", step = 5, steps = 7 }) == "Continue  ·  Two Rooms  ·  step 5/7", "the CONTINUE line")
  check(M.continueLine({ id = "x", step = 7, steps = 7, outcome = "done" }) == nil and M.continueLine(nil) == nil, "a finished run has no CONTINUE")
  local byId = { flag_day = { id = "flag_day", title = "Flag Day" } }
  local ok, why = M.unlocked({ requires = "flag_day" }, {}, byId)
  check(not ok and why == "after Flag Day", "locked behind another scenario's medal: " .. tostring(why))
  check(M.unlocked({ requires = "flag_day" }, { flag_day = { best = "bronze" } }, byId), "any medal opens it")
  ok, why = M.unlocked({ requires = { id = "flag_day", medal = "gold" } }, { flag_day = { best = "silver" } }, byId)
  check(not ok and why:find("gold"), "a gold requirement wants gold")
  check(M.entryOf({ scenarios = { a = { best = "gold" } } }, "a").best == "gold", "a profile nested under `scenarios` reads too")
  check(M.bestLine({ best = "gold", bestTime = 872, plays = 3 }) == "Best: gold in 14:32  ·  3 plays", M.bestLine({ best = "gold", bestTime = 872, plays = 3 }))
  check(M.bestLine(nil) == "Not played yet", "never played")
end
do
  -- the page in the menu scene, against a stub rulebook
  local slots = { scn = { g_scenario = "two_rooms" }, slot1 = { g_seed = 5 } }
  local cur = "slot1"
  local slot_calls, writes = {}, {}
  local loaded, prepared, saved_profile = nil, nil, nil
  local LIB = {
    SLOT = "scn",
    listAll = function() return {
      { id = "first_light", title = "First Light", teaches = { "vab", "staging" }, par = 360, blurb = "Orbit and back." },
      { id = "flag_day", title = "Flag Day", teaches = { "moon" }, par = 540, requires = "first_light", blurb = "A flag." },
      { id = "two_rooms", title = "Two Rooms", teaches = { "kit", "air" }, par = 1200, blurb = "Two rooms." },
    } end,
    slotSummary = function(get) local id = get("g_scenario"); if id then return { id = id, title = "Two Rooms", step = 5, steps = 7 } end end,
    prepareSlot = function(id) prepared = id; save.slot("scn"); save.set("g_scenario", id); return true end,
    profileLoad = function() return { first_light = { best = "gold", bestTime = 300, plays = 2 }, two_rooms = { best = "bronze", plays = 1 } } end,
    profileSave = function(p) saved_profile = p end,
  }
  local scripts = { sfx = { play = function() end } }
  local panel_el, menu_el = { visible = true }, { visible = true }
  local made_panel, made_row = nil, nil
  local nodes = {
    ["Scenarios Panel"] = { valid = true, getcomponent = function() return panel_el end, tag = "panel" },
    ["Menu Panel"] = { valid = true, getcomponent = function() return menu_el end },
  }
  local presses = {}
  local env = {
    findScript = function(k) return scripts[k] end,
    find = function(n) return nodes[n] or { valid = true } end,
    save = {
      slot = function(n) if n then slot_calls[#slot_calls + 1] = n; cur = n end return cur end,
      get = function(k) return (slots[cur] or {})[k] end,
      set = function(k, v) writes[#writes + 1] = { cur, k }; slots[cur] = slots[cur] or {}; slots[cur][k] = v end,
    },
    scene = { load = function(s) loaded = s end },
    input = { pressed = function(k) return presses[k] == true end },
    ui = { make = function(n, t) if n.tag == "panel" then made_panel = t else made_row = t end end, focus = function() end },
    assets = { getFile = function() return nil end },
  }
  _G.save = env.save   -- (the stub rulebook's prepareSlot writes through the global)
  local M = load("solar/scripts/menu_scenarios.lua", env)
  M.useLib(LIB)
  local row = { valid = true, tag = "row" }
  M.start(row)
  check(not panel_el.visible and made_row and texts(made_row):find("SCENARIOS") and texts(made_row):find("CONTINUE"),
    "the menu row: SCENARIOS, and CONTINUE with a run in progress: " .. texts(made_row or {}))
  check(cur == "slot1", "peeking the scenario slot switches back")
  M.clicked(row)
  M.update(row, 1 / 60)
  check(M.open and panel_el.visible and not menu_el.visible, "the page turns: the panel up, the title page down")
  check(M.selected() == "two_rooms", "the run in progress is selected first")
  local tx = texts(made_panel)
  check(tx:find("FIRST LIGHT") and tx:find("FLAG DAY") and tx:find("TWO ROOMS") and tx:find("after First Light") == nil,
    "the list (Flag Day opens: First Light has a medal): " .. tx)
  check(tx:find("Continue  ·  Two Rooms  ·  step 5/7"), "CONTINUE · Two Rooms · step 5/7")
  check(tx:find("NO PICTURE YET"), "a scenario with no card.png says so")
  check(by(made_panel, "name", "Scn Row first_light") and by(made_panel, "name", "Scn Row first_light").style == "panel/row"
    and by(made_panel, "name", "Scn Row two_rooms").style == "panel/rowActive", "rows: the selected one lit")
  -- choose First Light, PLAY: a run in progress → asks first
  by(made_panel, "name", "Scn Row first_light").onFocusEnter()
  M.update(row, 1 / 60)
  check(M.selected() == "first_light" and texts(made_panel):find("Best: gold in 5:00"), "focus selects; the best run shows")
  by(made_panel, "name", "Scn Play").onClicked()
  M.update(row, 1 / 60)
  check(prepared == nil and texts(made_panel):find("Replace Two Rooms%?"), "replacing a run in progress asks first")
  presses.escape = true; M.update(row, 1 / 60); presses.escape = nil; M.update(row, 1 / 60)
  check(M.open and not texts(made_panel):find("Replace"), "Esc disarms before it closes")
  by(made_panel, "name", "Scn Play").onClicked(); M.update(row, 1 / 60)
  by(made_panel, "name", "Scn Play").onClicked()
  check(prepared == "first_light" and loaded == "system", "the second press plays it: prepareSlot, then the system scene")
  local career = 0
  for _, s in ipairs(slot_calls) do if s:match("^slot%d") and s ~= "slot1" then career = career + 1 end end
  for _, w in ipairs(writes) do if w[1]:match("^slot%d") then career = career + 1 end end
  check(career == 0, "no career slot written or opened")
  -- RESET: arms, then clears the entry only
  loaded, prepared = nil, nil
  M.openPanel(); M.update(row, 1 / 60)
  by(made_panel, "name", "Scn Reset").onClicked(); M.update(row, 1 / 60)
  check(saved_profile == nil and texts(made_panel):find("Sure%?"), "RESET arms first")
  by(made_panel, "name", "Scn Reset").onClicked(); M.update(row, 1 / 60)
  check(saved_profile and saved_profile.first_light == nil and saved_profile.two_rooms, "RESET clears that scenario's entry only")
  -- CONTINUE enters the scenario slot
  by(made_panel, "name", "Scn Continue").onClicked()
  check(cur == "scn" and loaded == "system", "CONTINUE: slot scn, the system scene")
  presses.escape = true; M.update(row, 1 / 60); presses.escape = nil
  check(not M.open and menu_el.visible, "Esc goes back to the title page")
  _G.save = nil
end
-- a locked one refuses PLAY
do
  local env = {
    findScript = function() return nil end, find = function() return { valid = true, getcomponent = function() return {} end } end,
    save = { slot = function(n) return n or "slot1" end, get = function() return nil end },
    scene = { load = function() error("must not load") end },
    input = { pressed = function() return false end },
    ui = { make = function(n, t) if n.tag == "panel" then _G.__scn_panel = t end end },
    assets = { getFile = function() return nil end },
  }
  local M = load("solar/scripts/menu_scenarios.lua", env)
  local prepared = nil
  M.useLib({ SLOT = "scn", listAll = function() return { { id = "b", title = "B", requires = "a" }, { id = "a", title = "A" } } end,
             slotSummary = function() return nil end, prepareSlot = function(id) prepared = id return true end,
             profileLoad = function() return {} end })
  local panel = { valid = true, tag = "panel", getcomponent = function() return {} end }
  env.find = function(n) if n == "Scenarios Panel" then return panel end return { valid = true, getcomponent = function() return {} end } end
  M.start({ valid = true })
  M.openPanel(); M.update({}, 1 / 60)
  local t = _G.__scn_panel
  check(texts(t):find("after A"), "a locked row says what opens it")
  by(t, "name", "Scn Play").onClicked()
  check(prepared == nil, "a locked scenario does not start")
  _G.__scn_panel = nil
end

-- ── 5b. THE STAGE: dialogue and cutscenes ────────────────────────────────────
do
  local G = load("solar/scripts/scenario_stage.lua")
  local c = G.normChoices({ "Vent it", { id = "hold", text = "Hold" }, "c", "d", "e" })
  check(#c == 4 and c[1].id == 1 and c[2].id == "hold" and c[2].text == "Hold", "choices: at most four, strings get their index")
  check(G.barH(0, true) == 0 and G.barH(G.BAR_SECS, true) == G.BAR_H and G.barH(G.BAR_SECS, false) == 0, "the bars ease in and out")
  check(G.glyphOf("engineer") == "E" and G.glyphOf("PLANT CHIEF") == "P" and G.glyphOf(nil) == "◎", "role glyphs")
end
do
  local paused, made, last = false, 0, nil
  local presses, keys = {}, {}
  local logged, played = {}, {}
  local runc = {}
  local layer = { enabled = true }
  local scripts = {
    ops_strip = { logLine = function(t, w) logged[#logged + 1] = { w, t } end },
    sfx = { play = function(k) played[#played + 1] = k end },
    scenario_run = { lineDone = function() runc.done = (runc.done or 0) + 1 end, choose = function(i) runc.chose = i end,
                     skipCutscene = function() runc.skip = (runc.skip or 0) + 1 end },
  }
  local env = {
    findScript = function(k) return scripts[k] end,
    find = function(n) if n == "Ship HUD" then return { getcomponent = function() return layer end } end return { valid = true, text = "" } end,
    physics = { pause = function(on) paused = on end, isPaused = function() return paused end },
    input = { pressed = function(k) return presses[k] == true end, key = function(k) return keys[k] == true end,
              setMouseLocked = function() end },
    ui = { make = function(_, t) made = made + 1; last = t end, focus = function() end },
    assets = { getFile = function() return nil end },
  }
  local G = load("solar/scripts/scenario_stage.lua", env)
  local el = { visible = false }
  local node = { getcomponent = function() return el end }
  G.start(node)
  local function frames(n) for _ = 1, n do G.update(node, 1 / 60) end end
  frames(5)
  check(made == 0, "idle: nothing described")
  -- a line from scenario_run's `say`
  G.onSay({ who = "okafor", name = "Dele Okafor", tag = "ENGINEER", text = "Pump two is cold. We bring it up tonight." })
  frames(1)
  check(el.visible and G.dialogueOpen() and texts(last):find("DELE OKAFOR") and texts(last):find("ENGINEER"), "the plate: name and role: " .. texts(last))
  check(by(last, "key", "g") and by(last, "key", "g").text == "E", "no picture: the role glyph")
  check(not paused, "a plain line does not stop the world")
  local m0 = made
  frames(20)
  check(made == m0, "the line types into one text node")
  presses.space = true; frames(1); presses.space = nil
  check(G.current().typed, "Space finishes the typing")
  presses.enter = true; frames(1); presses.enter = nil
  check(runc.done == 1 and not G.dialogueOpen() and logged[1][1] == "Dele Okafor", "Enter closes it: lineDone, and the Ops log has it")
  -- several lines in one beat
  G.dialogue({ who = "Hale", lines = { "One.", "Two." } })
  frames(30); G.advance(); frames(1)
  check(G.current().text == "Two." and logged[#logged][2] == "One.", "lines advance one by one, each logged")
  G.advance(); G.advance(); frames(1)
  check(not G.dialogueOpen(), "the last advance closes")
  -- a choice
  G.onChoice({ who = "hale", name = "Dr. Hale", prompt = "Your call, chief?", options = { "By the book.", "Push it." }, t0 = 5 })
  frames(1)
  check(paused, "a choice holds the world")
  check(not G.advance() or G.current().typed, "")
  frames(60)
  check(by(last, "name", "Scenario Choice 2") and texts(by(last, "name", "Scenario Choice 2")):find("Push it"), "the choices show once typed")
  check(not G.advance(), "a choice cannot be clicked past")
  presses["2"] = true; frames(1); presses["2"] = nil
  frames(1)
  check(runc.chose == 2 and not G.dialogueOpen() and not paused, "2 picks the second; the world goes on")
  check(logged[#logged][1] == "›" and logged[#logged][2] == "Push it.", "the answer is logged")
  -- a choice the runner timed out
  G.onChoice({ name = "Hale", prompt = "Well?", options = { "A", "B" }, t0 = 9 })
  frames(2)
  check(G.sync({ choice = nil }) and not G.dialogueOpen(), "a timed-out choice closes without answering")
  -- a cutscene
  G.onCutscene(true)
  frames(math.ceil(G.BAR_SECS * 60) + 2)
  local top = by(last, "key", "top")
  check(top and top.h == G.BAR_H and layer.enabled == false, "letterbox in, the HUD off")
  check(texts(last):find("Hold Esc to skip") and G.holdsEsc(), "hold Esc to skip")
  G.caption("Haldane", "Night side, 0400", 3)
  frames(1)
  check(texts(last):find("Haldane") and texts(last):find("0400"), "a caption in the lower bar")
  keys.escape = true; frames(30); keys.escape = nil; frames(1)
  check(runc.skip == nil and G.cutsceneOn(), "a short Esc does not skip")
  keys.escape = true; frames(64); keys.escape = nil
  check(runc.skip == 1, "Esc held a second skips (skipCutscene)")
  frames(math.ceil(G.BAR_SECS * 60) + 4)
  check(not G.cutsceneOn() and layer.enabled == true, "bars out, the HUD back")
  frames(200)
  check(not el.visible, "idle again: nothing up")
  G.alarm(true); frames(1)
  check(by(last, "key", "alarm") and by(last, "key", "alarm").style == "scn/alarm" and played[#played] == "denied", "an alarm: a red edge and the buzzer")
  G.alarm(false); frames(1)
  check(not el.visible, "the alarm off: nothing up")
end

-- ── 6. STATIC: slots, styles, scenes ────────────────────────────────────────
for _, f in ipairs({ "ops_strip", "scenario_ui", "menu_scenarios", "scenario_stage" }) do
  local src = readall("solar/scripts/" .. f .. ".lua")
  check(not src:find('"slot%%d"') and not src:find('"slot[0-9]"') and not src:find("save%.deleteSlot"),
    f .. ": never names a career slot, never deletes a slot itself")
  local sheet = readall("solar/ui/solar.uistyle.ron")
  for st in src:gmatch('style%s*=%s*"([^"]+)"') do
    check(sheet:find('"' .. st .. '"', 1, true) ~= nil, f .. ": the style " .. st .. " exists")
  end
  for _, tbl in ipairs({ "MEDAL_STYLE" }) do
    for st in src:gmatch('"(scn/[%w]+)"') do
      check(sheet:find('"' .. st .. '"', 1, true) ~= nil, f .. ": the style " .. st .. " exists")
    end
  end
end
do
  local menu = readall("solar/scenes/menu.ron")
  check(menu:find('name: "Scenarios Row"', 1, true) and menu:find('kind: "menu_scenarios"', 1, true)
    and menu:find('name: "Scenarios Panel"', 1, true), "menu.ron: the Scenarios row and page")
  check(menu:find("Fixed(520.0), Fixed(324.0)", 1, true), "menu.ron: the card grew 44 for the fourth row")
  check(select(2, menu:gsub("offset: %(%-?98%.0, 604%.0%)", "")) == 2, "menu.ron: QUIT and SETTINGS moved down with it")
  local sys = readall("solar/scenes/system.ron")
  check(sys:find('kind: "ops_strip"', 1, true) and sys:find('kind: "scenario_ui"', 1, true), "system.ron: the strip and the panels ride the Ship HUD")
  check(sys:find('kind: "scenario_stage"', 1, true) and sys:find("z: 130", 1, true), "system.ron: the story layer above the HUD")
  local ids = {}
  local dup = nil
  for id in sys:gmatch("\n            id: Some%((%d+)%)") do if ids[id] then dup = id end ids[id] = true end
  check(dup == nil, "system.ron: node ids are unique (" .. tostring(dup) .. ")")
end
-- the controls card lists the scenario keys
do
  local src = readall("solar/scripts/pause_menu.lua")
  check(src:find('group = "Scenarios"', 1, true) and src:find("CLICK THE STRIP", 1, true), "the controls card has the Scenarios keys")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_menu_scenarios: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_menu_scenarios OK — %d checks", passed))
