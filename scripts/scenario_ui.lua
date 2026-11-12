-- SCENARIO UI — what a scenario puts on the screen around the play
-- (work/scenarios PLAN §1.6, §1.10; docs/scenarios.md). It reads
-- scenario_run.state() (scripts/scenario_run.lua, FW-A) and draws:
--
--   THE CURTAIN LINE  over the loading screen: SCENARIO, the title and what
--                     it teaches, so the wait says what is coming.
--   BRIEFING          once the start is staged: the world frozen
--                     (physics.pause), Ops' brief typed out, the first step
--                     named, par, and one key: GO (Enter). Space or a click
--                     on the brief prints it whole. One click, never more.
--   THE CHIP          during play, top centre beside the warp chip: the step
--                     count and the time against par, for a player chasing
--                     gold. Redrawn only when the second it shows changes.
--   DEBRIEF           at the end: the medal, the numbers against par, Ops'
--                     line for the outcome, and RETRY · RESTART · CONTINUE ·
--                     MENU. The world is held still behind it.
--
-- It also hands scenario_run's `ops` beat to ops_strip.lua
-- (scenario_run.listen("ops", …)) and claims the briefing
-- (scenario_run.wantBriefing(true)), so the runner waits for GO.
--
-- Outside slot `scn` (no `g_scenario` in the slot) it does nothing at all.
-- In a scenario it polls state() at 4 Hz and describes a panel only when the
-- state's `version` moves, or a shown number changes.
--
-- Pure (luajit, tests/smoke_menu_scenarios.lua): clock(secs), chipText(st),
-- medalOf(st), buttonsFor(st), briefText(lines, n), briefLen(lines).

POLL = 0.25          -- s between state() reads
CPS = 40             -- the brief types at the Ops strip's rate
-- Top centre, in the status chips' row (FUNDS … PACK on the left, the
-- objectives card and MENU on the right; 1080p shots 2026-11-10): the warp
-- chip sits under it at y 60 while it shows.
CHIP_X, CHIP_Y = 0, 16

-- ── pure ────────────────────────────────────────────────────────────────────

-- 754 → "12:34"; 3725 → "1:02:05"; nil → "--:--"
function clock(s)
  if type(s) ~= "number" or s ~= s then return "--:--" end
  s = math.max(0, math.floor(s + 0.5))
  local h, m, sec = math.floor(s / 3600), math.floor(s / 60) % 60, s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%d:%02d", m, sec)
end

-- The chip's three pieces: "3 / 7", "4:12 / 20:00", and an over-par note
-- ("+1:05 over par") or nil.
function chipText(st, elapsed)
  local steps = string.format("%d / %d", math.min(st.step or 1, st.steps or 1), st.steps or 1)
  local t = elapsed or st.elapsed or 0
  local time = st.par and (clock(t) .. " / " .. clock(st.par)) or clock(t)
  local over = (st.par and t > st.par) and ("+" .. clock(t - st.par) .. " over par") or nil
  return steps, time, over
end

MEDAL_STYLE = { gold = "scn/medalGold", silver = "scn/medalSilver", bronze = "scn/medalBronze" }
MEDAL_WORD = { gold = "GOLD", silver = "SILVER", bronze = "BRONZE" }

-- → "gold" | "silver" | "bronze" | "fail"
function medalOf(st)
  if st.phase == "failed" or st.outcome == "fail" then return "fail" end
  return st.medal or "bronze"
end

-- The debrief's keys, in order, the first one lit. RETRY only after a
-- failure (from the last checkpoint, or the start); CONTINUE only after a
-- finish that leaves the world to play in.
function buttonsFor(st)
  if medalOf(st) == "fail" then
    return { { "retry", "Retry" }, { "restart", "Restart" }, { "menu", "Menu" } }
  end
  local out = {}
  if st.after ~= "menu" then out[#out + 1] = { "continue", "Continue" } end
  out[#out + 1] = { "restart", "Restart" }
  out[#out + 1] = { "menu", "Menu" }
  return out
end

-- The brief, `n` characters in: each line's shown text (a line not reached
-- yet is ""). Characters, not bytes. → { text… }, all typed (bool)
local function ulen(s)
  if utf8 and utf8.len then local n = utf8.len(s); if n then return n end end
  local n = 0
  for i = 1, #s do local b = s:byte(i); if b < 0x80 or b >= 0xC0 then n = n + 1 end end
  return n
end
local function usub(s, n)
  if n <= 0 then return "" end
  local i, c = 1, 0
  while i <= #s do
    local b = s:byte(i)
    local w = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or (b >= 0xC0 and 2 or 1)))
    c = c + 1
    if c > n then return s:sub(1, i - 1) end
    i = i + w
  end
  return s
end
function briefLen(lines)
  local n = 0
  for _, l in ipairs(lines or {}) do n = n + ulen(tostring(l)) end
  return n
end
function briefText(lines, n)
  local out, left = {}, n
  for i, l in ipairs(lines or {}) do
    l = tostring(l)
    local k = ulen(l)
    out[i] = usub(l, left)
    left = left - k
  end
  return out, n >= briefLen(lines)
end

-- "rooms, air, airlock" from a teaches list
function teachesLine(t)
  if type(t) ~= "table" then return t and tostring(t) or "" end
  local o = {}
  for _, k in ipairs(t) do o[#o + 1] = string.upper(tostring(k)) end
  return table.concat(o, "  ·  ")
end

-- A described element whose children were written `cond and {…} or nil`
-- has holes. ui.make copes (it walks to the largest key), but ipairs and `#`
-- stop at one, and the luajit tests walk the trees that way. Close them up,
-- all the way down the positional children, before ui.make sees the tree.
function tidy(t)
  if type(t) ~= "table" then return t end
  local idx = {}
  for k, v in pairs(t) do
    if type(k) == "number" then idx[#idx + 1] = k end
  end
  table.sort(idx)
  local vals = {}
  for _, k in ipairs(idx) do
    local v = t[k]
    t[k] = nil
    if v ~= false then vals[#vals + 1] = v end
  end
  for i, v in ipairs(vals) do t[i] = tidy(v) end
  return t
end

-- ── the scene ───────────────────────────────────────────────────────────────

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function sfx(key) local f = ref("sfx"); if f and f.play then f.play(key) end end

local off = true          -- not a scenario slot: stand down entirely
local me, el = nil, nil
local run = nil           -- scenario_run's handle once found
local hooked = false
local st = nil            -- the last state() read
local seen_version = nil
local poll_t = 0
local shown = nil         -- what is described now: "curtain" | "brief" | "debrief" | "chip" | nil
local chip_key = nil
local brief_t, brief_all = 0, false
local brief_wall = nil      -- (gy3) the wall clock at the last typed frame
-- (probes) characters of the brief typed so far (9999: all of it)
function briefTyped() return brief_all and 9999 or math.floor(brief_t * CPS) end
local brief_nodes = {}    -- made text nodes of the brief's lines (the typewriter writes them)
local brief_n = -1
local paused_by_us = false

-- Published for probes: what is up ("curtain" | "brief" | "debrief" | "chip" | nil).
function showing() return shown end
function stateNow() return st end

-- A probe or an author can show the panels from a made-up state, with no
-- runner (tools/perf/scnuiprobe.lua): preview(state) / preview(nil) to end.
local preview_st = nil
function preview(s)
  preview_st = s
  off = false
  seen_version = nil
  poll_t = POLL
end

local function act(what)
  sfx(what == "go" and "sign" or "click")
  local r = run
  if preview_st then
    -- the preview has no runner: the keys only move its phase along
    if what == "go" then preview_st.phase = "running" end
    if what == "continue" then preview_st.phase = "freeplay" end
    preview_st.version = (preview_st.version or 0) + 1
    lastAction = what
    return
  end
  lastAction = what
  if not r then return end
  if what == "go" and r.go then r.go()
  elseif what == "retry" and r.retry then r.retry()
  elseif what == "restart" and r.restart then r.restart()
  elseif what == "continue" and r.continueFreeplay then r.continueFreeplay()
  elseif what == "hint" and r.hint then
    -- (S7: the press always answers: the hint itself as a toast, or why not)
    local ok, why, txt = r.hint()
    -- the toast: under the chip for HINT_TOAST s (our own, so it shows
    -- whatever the captions setting, and never under the dialogue plate)
    lastHint = { ok = ok, why = why, text = txt, t = time or 0 }
    hintToast = { text = ok and tostring(txt or "") or (string.upper(tostring(why or "no hint")) .. (txt and (" · " .. tostring(txt)) or "")),
                  ok = ok, t = time or 0 }
  elseif what == "menu" then
    if r.toMenu then r.toMenu() else local gm = ref("game_manager"); if gm and gm.exitToMenu then gm.exitToMenu() end end
  end
end
lastAction = nil
lastHint = nil
-- the hint key (S7): F1, or ? (Shift + /). F1 is the Build Kit's ROOMS overlay
-- while the builder is open, so there it is left to the builder.
function hintKey()
  if not (input and input.pressed) then return false end
  if input.pressed("f1") then
    local fb = ref("field_builder")
    if not (fb and fb.isOpen and fb.isOpen()) then return true end
  end
  if input.pressed("/") and input.key and (input.key("shift") or input.key("lshift") or input.key("rshift")) then return true end
  return false
end

local function hold_world(on)
  if on == paused_by_us then return end
  paused_by_us = on
  if physics and physics.pause then physics.pause(on) end
end

-- ── the trees ───────────────────────────────────────────────────────────────

local function curtain_tree(s)
  return {
    -- (above the loading screen's headline, which sits about 140 down)
    { "col", key = "cur", pin = "top", y = 34, w = 720, h = "fit", pad = 0, gap = 2, align = "center",
      { "text", key = "k", style = "panel/label", w = "100%", h = "fit", textAlign = "center", text = "SCENARIO" },
      { "text", key = "t", style = "panel/heading", w = "100%", h = "fit", textAlign = "center", textSize = 28,
        text = s.title or s.id or "" },
      (s.teaches and #s.teaches > 0) and { "text", key = "w", style = "panel/cellMuted", w = "100%", h = "fit",
        textAlign = "center", text = "teaches  " .. teachesLine(s.teaches) } or nil },
  }
end

-- (gy3) the brief's paragraphs as plain children: made through an `items`
-- list their names never reached the nodes, find() came back empty and the
-- typewriter wrote nowhere (the brief stayed at what the first make typed)
local function lines_col(paras)
  local c = { "col", key = "lines", w = "100%", h = "fit", pad = 0, gap = 8 }
  for _, p in ipairs(paras) do c[#c + 1] = p end
  return c
end
local function brief_tree(s)
  local lines = s.brief or {}
  local shownL = briefText(lines, brief_all and math.huge or math.floor(brief_t * CPS))
  local paras = {}
  for i, l in ipairs(lines) do
    paras[#paras + 1] = { "text", key = "b" .. i, name = "Scenario Brief " .. i, style = "panel/body", w = "100%", h = "fit",
      wrap = true, text = shownL[i] ~= "" and shownL[i] or " " }
  end
  local par = s.par and ("Par " .. clock(s.par) .. ".  Finishing is bronze; silver and gold are for pace.") or
    "Finishing is bronze; silver and gold are for pace."
  return {
    { "box", key = "scrim", style = "panel/scrim", inset = 0 },
    { "col", key = "brief", style = "panel/frame", pin = "top", y = 120, w = 600, h = "fit", pad = 20, gap = 8, align = "start",
      { "text", key = "k", style = "panel/label", w = "100%", h = "fit", text = "BRIEFING" },
      { "text", key = "t", style = "panel/heading", w = "100%", h = "fit", text = s.title or s.id or "Scenario" },
      (s.teaches and #s.teaches > 0) and { "text", key = "tch", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
        text = "teaches  " .. teachesLine(s.teaches) } or nil,
      { "box", key = "r1", style = "panel/rule", w = "100%", h = 1 },
      { "button", key = "ops", w = "100%", h = "fit", pad = 0, gap = 6, dir = "column", align = "start", focusable = false,
        onClicked = function() brief_all = true; seen_version = nil end,
        { "text", key = "who", style = "panel/label", w = "100%", h = "fit", text = "OPS  ›" },
        lines_col(paras) },
      { "box", key = "r2", style = "panel/rule", w = "100%", h = 1 },
      s.stepText and { "row", key = "first", w = "100%", h = "fit", pad = 0, gap = 10, align = "start",
        { "text", key = "l", style = "panel/label", w = 64, h = "fit", text = "FIRST" },
        { "text", key = "x", style = "panel/cellStrong", w = "grow", h = "fit", wrap = true, text = s.stepText } } or nil,
      { "text", key = "par", style = "panel/hint", w = "100%", h = "fit", wrap = true, text = par },
      { "row", key = "go", w = "100%", h = 34, pad = 0, gap = 12, align = "center",
        { "button", key = "go", name = "Scenario Go", style = "panel/action", w = 150, h = 34, text = "GO",
          textAlign = "center", textValign = "center", onClicked = function() act("go") end },
        { "text", key = "h", style = "panel/hint", w = "grow", h = "fit", wrap = true,
          text = "Enter: GO  ·  Space or a click on the brief prints it whole" } } },
  }
end

local function debrief_tree(s)
  local m = medalOf(s)
  local failed = m == "fail"
  local rows = {}
  for i, r in ipairs(s.score or {}) do
    rows[#rows + 1] = { "row", key = "s" .. i, w = "100%", h = 22, pad = 0, gap = 8, align = "center",
      { "text", key = "l", style = "panel/label", w = 150, h = "fit", text = string.upper(tostring(r.label or r[1] or "")) },
      { "text", key = "v", style = "panel/cellStrong", w = "grow", h = "fit", text = tostring(r.value or r[2] or "") },
      { "text", key = "p", style = "panel/cellMuted", w = 150, h = "fit", textAlign = "end",
        text = (r.par or r[3]) and ("par " .. tostring(r.par or r[3])) or "" },
      { "text", key = "o", style = (r.ok == false) and "panel/hintWarn" or "scn/ok", w = 18, h = "fit", textAlign = "center",
        text = (r.ok == nil) and "" or (r.ok and "✓" or "✕") } }
  end
  local keys = {}
  for i, b in ipairs(buttonsFor(s)) do
    keys[#keys + 1] = { "button", key = b[1], name = "Scenario " .. b[2], style = i == 1 and "panel/action" or "panel/secondary",
      w = "grow", h = 34, text = b[2], textAlign = "center", textValign = "center",
      onClicked = function() act(b[1]) end }
  end
  return {
    { "box", key = "scrim", style = "panel/scrim", inset = 0 },
    { "col", key = "debrief", style = "panel/frame", pin = "top", y = 110, w = 560, h = "fit", pad = 20, gap = 8, align = "start",
      { "text", key = "k", style = "panel/label", w = "100%", h = "fit", text = failed and "SCENARIO FAILED" or "SCENARIO COMPLETE" },
      { "text", key = "t", style = "panel/heading", w = "100%", h = "fit", text = s.title or s.id or "Scenario" },
      { "row", key = "medal", w = "100%", h = 44, pad = 0, gap = 12, align = "center",
        { "text", key = "g", style = failed and "scn/medalFail" or MEDAL_STYLE[m], w = 36, h = 40, textAlign = "center",
          textValign = "center", text = failed and "✕" or "●" },
        { "col", key = "w", w = "grow", h = "fit", pad = 0, gap = 0, align = "start",
          { "text", key = "a", style = "panel/figure", w = "100%", h = "fit", text = failed and "NO MEDAL" or MEDAL_WORD[m] },
          { "text", key = "b", style = failed and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit", wrap = true,
            text = failed and (s.failText or "The run ended.") or
              (m == "gold" and "Inside every par." or (m == "silver" and "Inside the silver par." or "Done. Pace earns silver and gold.")) } } },
      #rows > 0 and { "box", key = "r1", style = "panel/rule", w = "100%", h = 1 } or nil,
      #rows > 0 and { "col", key = "score", w = "100%", h = "fit", pad = 0, gap = 2, items = rows, function(r) return r end } or nil,
      { "box", key = "r2", style = "panel/rule", w = "100%", h = 1 },
      (s.debrief and s.debrief ~= "") and { "row", key = "ops", w = "100%", h = "fit", pad = 0, gap = 10, align = "start",
        { "text", key = "l", style = "panel/label", w = 64, h = "fit", text = "OPS  ›" },
        { "text", key = "x", style = "panel/body", w = "grow", h = "fit", wrap = true, text = s.debrief } } or nil,
      { "row", key = "keys", w = "100%", h = 34, pad = 0, gap = 8, align = "center", items = keys, function(k) return k end } },
  }
end

local el_raw, el_base, el_since = nil, 0, 0   -- the clock between state reads
local function elapsed_now() return el_base + el_since end

-- the chip's tooltip
function hintTip(s)
  return "F1 or ?: the hint for this step, as a toast and on the objectives card (the debrief counts them)"
end
HINT_TOAST = 8.0
hintToast = nil
local function toast_up() return hintToast ~= nil and ((time or 0) - hintToast.t) < HINT_TOAST end
local function chip_tree(s)
  local steps, time, over = chipText(s, elapsed_now())
  return {
    { "row", key = "chip", style = "hud/chip", pin = "top", x = CHIP_X, y = CHIP_Y, w = "fit", h = 22, pad = 6, gap = 6,
      align = "center",
      { "text", key = "k", style = "hud/chipLabel", w = "fit", h = "fit", text = "SCENARIO" },
      { "text", key = "s", style = "hud/chipValue", w = "fit", h = "fit", text = steps },
      { "text", key = "d", style = "hud/chipLabel", w = "fit", h = "fit", text = "·" },
      { "text", key = "t", style = "hud/chipValue", w = "fit", h = "fit", text = time },
      over and { "text", key = "o", style = "hud/chipLabel", w = "fit", h = "fit", text = over } or nil,
      -- (H holsters the tool, so the hint is a key here: scenario_run.hint)
      -- (S7: a key, F1 or ?, works in first person where the pointer is
      -- locked; the chip is focusable for the keys of a menu, and lit while
      -- a hint has just been shown)
      { "button", key = "hint", name = "Scenario Hint", style = "hud/button", w = 64, h = 18,
        text = s.hintFlash and "HINT  ✓" or "HINT  F1", textAlign = "center", textValign = "center", focusable = true,
        opacity = (s.hasHint ~= true) and 0.55 or nil,
        tooltip = hintTip(s),
        onClicked = function() act("hint"); if ui and ui.focus then pcall(ui.focus, nil) end end } },
    toast_up() and { "row", key = "htoast", style = "hud/chip", pin = "top", x = CHIP_X, y = CHIP_Y + 30, w = "fit", h = "fit",
      pad = 8, gap = 8, align = "start",
      { "text", key = "hk", style = "hud/chipLabel", w = "fit", h = "fit", text = "HINT" },
      { "text", key = "ht", style = "hud/chipValue", w = "fit", maxW = 430, h = "fit", wrap = true, text = hintToast.text } } or nil,
  }
end

-- ── the driver ──────────────────────────────────────────────────────────────

local function hook(r)
  if hooked or not r then return end
  hooked = true
  if r.wantBriefing then pcall(r.wantBriefing, true) end
  if r.listen then
    pcall(r.listen, "ops", function(text, who)
      local s = ref("ops_strip")
      if s and s.say then s.say(text, who, function() if r.lineDone then pcall(r.lineDone) end end, { scenario = true }) end
    end)
    pcall(r.listen, "phase", function() seen_version = nil; poll_t = POLL end)
    -- the story (scenario_stage.lua): dialogue lines, choices, cutscenes
    local function stage() return ref("scenario_stage") end
    -- Ops talks on the comms strip; the cast (named people) on the plate.
    -- (scenario_run sends `ops` beats through "say" too, who = "ops".)
    pcall(r.listen, "say", function(line)
      if type(line) == "table" and (line.who == "ops" or line.who == nil) and not (stage() and stage().cutsceneOn and stage().cutsceneOn()) then
        local os_ = ref("ops_strip")
        if os_ and os_.say then
          os_.say(line.text, line.name or "Ops", function() if r.lineDone then pcall(r.lineDone) end end, { scenario = true })
          return
        end
      end
      local s = stage(); if s and s.onSay then s.onSay(line) end
    end)
    pcall(r.listen, "choice", function(c) local s = stage(); if s and s.onChoice then s.onChoice(c) end end)
    pcall(r.listen, "cutscene", function(on) local s = stage(); if s and s.onCutscene then s.onCutscene(on) end end)
    pcall(r.listen, "alarm", function(on) local s = stage(); if s and s.alarm then s.alarm(on) end end)
  end
end

function start(node)
  me = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  off = not (save and save.get and save.get("g_scenario"))
  if el then el.visible = false end
end

local function clear(node)
  if shown then ui.make(node, {}) end
  shown, chip_key = nil, nil
  -- (an empty full-screen element must not sit over the world's clicks)
  if el and el.visible then el.visible = false end
  brief_nodes, brief_n = {}, -1
end

-- The panel the state asks for: "curtain" | "brief" | "debrief" | "chip" | nil
local function want(s, gm, pm)
  if not s then return nil end
  if gm and (gm.loading or gm.curtain) then return "curtain" end
  if pm and pm.open then return nil end
  local ph = s.phase
  if ph == "briefing" then return "brief" end
  if ph == "done" or ph == "failed" then return "debrief" end
  if ph == "running" then
    if s.cutscene then return nil end
    local pc = ref("planet_camera")
    if pc and (pc.cinematic or pc.freecam) then return nil end
    return "chip"
  end
  return nil
end
wantFor = want   -- (pure enough for the tests: gm / pm are plain tables)

function update(node, dt)
  if off then return end
  dt = dt or 0
  if not run or run.valid == false then
    run = ref("scenario_run")
    if run then hooked = false end
  end
  hook(run)
  poll_t = poll_t + dt
  local gm, pm = ref("game_manager"), ref("pause_menu")
  if poll_t >= POLL then
    poll_t = 0
    local s = preview_st
    if not s and run and run.state then
      local ok, v = pcall(run.state)
      if ok then s = v end
    end
    if s and s.active == false and not preview_st then s = nil end
    st = s
    local sg = st and not preview_st and ref("scenario_stage")
    if sg and sg.sync then sg.sync(st) end
    if st and st.elapsed ~= el_raw then el_raw, el_base, el_since = st.elapsed, st.elapsed or 0, 0 end
  end
  -- (the runner's clock is game time: warp counts, a pause does not)
  if st and st.phase == "running" and not (physics and physics.isPaused and physics.isPaused()) then
    el_since = math.min(el_since + dt * ((space and space.warp and space.warp()) or 1), POLL * 10000)
  end
  local w = want(st, gm, pm)
  -- the world holds still behind a briefing or a debrief (re-asserted: the
  -- pause menu's close lets it go)
  local modal = (w == "brief" or w == "debrief") or ((pm and pm.open) and st and
    (st.phase == "briefing" or st.phase == "done" or st.phase == "failed"))
  if modal then
    if not paused_by_us or (physics and physics.isPaused and not physics.isPaused()) then
      paused_by_us = false
      hold_world(true)
    end
  elseif paused_by_us then
    hold_world(false)
  end
  if w ~= shown then
    if w == "brief" and shown ~= "brief" then brief_t, brief_all, brief_wall = 0, false, nil end
    if w == "debrief" or w == "brief" then sfx("card") end
    clear(node)
    seen_version = nil
  end
  if not w then return end
  if el and not el.visible then el.visible = true end
  if w == "brief" or w == "debrief" then
    if input and input.setMouseLocked then input.setMouseLocked(false) end
  end
  if w == "brief" then
    local total = briefLen(st.brief)
    -- (gy3, Ty 2026-11-11: the brief's OPS text showed only "K") the world
    -- is paused behind the brief, and a paused frame's dt is 0: the
    -- typewriter runs on the wall clock, as the dialogue plate's does (FW-C)
    local wc = app and app.wallClock and app.wallClock() or nil
    local wdt = (wc and brief_wall) and math.max(0, math.min(0.1, wc - brief_wall)) or (dt or 0)
    brief_wall = wc
    if not brief_all then
      brief_t = brief_t + wdt
      if brief_t * CPS >= total then brief_all = true; seen_version = nil end
    end
    local typing = (math.floor(brief_t * CPS) < total) and not brief_all
    if input and input.pressed then
      if input.pressed("enter") then act("go") return end
      if input.pressed("space") then
        if typing then brief_all = true; seen_version = nil end
        local os_ = ref("ops_strip"); if os_ and os_.skipLine then os_.skipLine() end
      end
    end
    if seen_version ~= st.version or shown ~= "brief" then
      ui.make(node, tidy(brief_tree(st)))
      shown, seen_version = "brief", st.version
      brief_nodes = {}
      for i = 1, #(st.brief or {}) do brief_nodes[i] = find and find("Scenario Brief " .. i) or nil end
      brief_n = brief_all and total or math.floor(brief_t * CPS)
    elseif typing then
      -- the typewriter: write only the lines that changed
      local n = math.floor(brief_t * CPS)
      if n ~= brief_n then
        local a = briefText(st.brief, brief_n)
        local b = briefText(st.brief, n)
        for i = 1, #b do
          -- (gy3) a node not found right after the make is looked for again
          if a[i] ~= b[i] and not (brief_nodes[i] and brief_nodes[i].valid ~= false) and find then brief_nodes[i] = find("Scenario Brief " .. i) end
          if a[i] ~= b[i] and brief_nodes[i] and brief_nodes[i].valid ~= false then brief_nodes[i].text = b[i] ~= "" and b[i] or " " end
        end
        brief_n = n
      end
    end
    return
  end
  if w == "debrief" then
    if input and input.pressed then
      if input.pressed("enter") then act(buttonsFor(st)[1][1]) return end
      if input.pressed("space") then local os_ = ref("ops_strip"); if os_ and os_.skipLine then os_.skipLine() end end
    end
    if seen_version ~= st.version or shown ~= "debrief" then
      ui.make(node, tidy(debrief_tree(st)))
      shown, seen_version = "debrief", st.version
    end
    return
  end
  if w == "curtain" then
    if shown ~= "curtain" or seen_version ~= st.version then
      ui.make(node, tidy(curtain_tree(st)))
      shown, seen_version = "curtain", st.version
    end
    return
  end
  if w == "chip" then
    if hintKey() then act("hint") end
    local a, b, c = chipText(st, elapsed_now())
    local k = a .. b .. (c or "") .. (st.hintFlash and "H" or "") .. (st.hasHint and "h" or "") .. (toast_up() and tostring(hintToast.t) or "")
    if k ~= chip_key or shown ~= "chip" then
      ui.make(node, tidy(chip_tree(st)))
      shown, chip_key = "chip", k
    end
  end
end
