-- SCENARIO STAGE — the story side of a scenario: DIALOGUE with named crew,
-- and CUTSCENE presentation (work/scn_fwb/UI_API.md; docs/scenarios.md).
--
-- Rides its own UI layer ("Scenario Stage", z 130, above the Ship HUD), so
-- it stays up while a cutscene hides the HUD.
--
--   DIALOGUE  a lower-third plate: the speaker's portrait (a picture the beat
--             names, a live render target, or a stencilled role glyph), the
--             name and role, the line typed at 40 characters a second, then
--             click / Space / Enter for the next line. A line with choices
--             shows 2–4 keys (1–4, or ↑ ↓ and Enter; a pad navigates them)
--             and holds the world still until one is picked. Every line is
--             written to the Ops strip's history too.
--   CUTSCENE  black bars ease in from top and bottom, the Ship HUD layer is
--             switched off, captions sit in the lower bar, and "Hold Esc to
--             skip" with a small meter fills over one second.
--
--   local st = findScript("scenario_stage")
--   st.dialogue({ who = "Okafor", role = "engineer", text = "Coolant pump two is down." ,
--                 choices = { { id = "scram", text = "Scram it" }, { id = "hold", text = "Hold power" } } },
--               function(choice) … end)
--   st.cutscene(true, { caption = { "HALDANE", "Night side, 0400" } }, function() skipped() end)
--
-- Idle it costs one comparison a frame. Described with ui.make only when a
-- line starts, its choices appear, or the bars move (0.45 s each way); the
-- typewriter writes one text node.
--
-- Pure (luajit): normChoices(c), barH(t, on, from), queue (newQ, add, cur).

CPS = 40
BAR_H = 76            -- design units at 720 (about 10 % of the screen)
BAR_SECS = 0.45
SKIP_HOLD = 1.0       -- s of Esc to skip a cutscene
PANEL_W = 720
local GLYPH = { pilot = "P", engineer = "E", scientist = "S", ops = "◎" }
local ROLE_NAME = { pilot = "Pilot", engineer = "Engineer", scientist = "Scientist", ops = "Mission Control" }

-- ── pure ────────────────────────────────────────────────────────────────────

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
typedText = usub

-- choices → { { id, text } … } (at most 4; strings get their index as id)
function normChoices(c)
  local out = {}
  if type(c) ~= "table" then return out end
  for i, x in ipairs(c) do
    if #out >= 4 then break end
    if type(x) == "string" then out[#out + 1] = { id = i, text = x }
    elseif type(x) == "table" then out[#out + 1] = { id = x.id or i, text = tostring(x.text or x[1] or ("Choice " .. i)) } end
  end
  return out
end

-- a beat → its lines
function linesOf(b)
  if type(b.lines) == "table" and #b.lines > 0 then
    local o = {}
    for _, l in ipairs(b.lines) do o[#o + 1] = tostring(l) end
    return o
  end
  return { tostring(b.text or "") }
end

-- The bars' height `t` s after they were told to move (smoothstep, no bounce).
function barH(t, on, from)
  local u = math.max(0, math.min(1, (t or 0) / BAR_SECS))
  u = u * u * (3 - 2 * u)
  local target = on and BAR_H or 0
  from = from or (on and 0 or BAR_H)
  return from + (target - from) * u
end

function glyphOf(role)
  role = tostring(role or ""):lower()
  return GLYPH[role] or (role ~= "" and role:sub(1, 1):upper()) or "◎"
end
function roleName(role)
  if not role then return nil end
  return ROLE_NAME[tostring(role):lower()] or tostring(role)
end

-- ── state ───────────────────────────────────────────────────────────────────

local Q = {}            -- dialogue beats waiting: { beat, reply }
local D = nil           -- the open one: { beat, reply, lines, i, t, n, typed, choices, paused }
local cut = { on = false, t = 99, from = 0, h = 0, skippable = true, onSkip = nil, caption = nil, esc = 0 }
local cap = nil         -- { title, sub, left }
local alarm_on = false  -- a red edge round the screen while an alarm sounds
local me, el = nil, nil
local drawn_key = nil
local text_node = nil
local last_n = -1
local hud_layer = nil
local paused_by_us = false
local clock = 0

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function sfx(k) local f = ref("sfx"); if f and f.play then f.play(k) end end

-- Published for probes / scenario_ui / pause_menu.
function dialogueOpen() return D ~= nil end
function cutsceneOn() return cut.on or cut.h > 0.5 end
function busy() return D ~= nil or #Q > 0 or cutsceneOn() or cap ~= nil end
function holdsEsc() return cut.on and cut.skippable ~= false end
-- (planet_camera: a panel that needs the pointer) — only a CHOICE takes it:
-- while a plain line is up the camera still turns (Ty 2026-11-10); only a
-- cutscene takes the camera, and that is scenario_run's
function isOpen() return D ~= nil and #D.choices > 0 end
function current() return D and { who = D.beat.who, text = D.lines[D.i], choices = D.choices, typed = D.typed } or nil end
lastChoice = nil

local function hold_world(on)
  if on == paused_by_us then return end
  paused_by_us = on
  if physics and physics.pause then physics.pause(on) end
end

local function log_line(who, text)
  local os_ = ref("ops_strip")
  if os_ and os_.logLine then os_.logLine(text, who) end
end

local function open_next()
  local nx = table.remove(Q, 1)
  if not nx then D = nil return end
  local b = nx.beat
  local ch = normChoices(b.choices)
  D = { beat = b, reply = nx.reply, lines = linesOf(b), i = 1, t = 0, n = 0, typed = false, choices = ch }
  local want_pause = b.pause
  if want_pause == nil then want_pause = #ch > 0 end
  D.pause = want_pause
  drawn_key = nil
  sfx("card")
end

function dialogue(beat, reply)
  if type(beat) == "string" then beat = { text = beat } end
  if type(beat) ~= "table" then return false end
  Q[#Q + 1] = { beat = beat, reply = reply }
  if not D then open_next() end
  return true
end

local function finish(choice, idx)
  local d = D
  if not d then return end
  log_line(d.beat.who, d.lines[d.i])
  if choice ~= nil then
    local c = d.choices[idx]
    log_line("›", c and c.text or tostring(choice))
    lastChoice = choice
  end
  D = nil
  drawn_key = nil
  if d.reply then pcall(d.reply, choice, idx) end
  open_next()
end

-- Click / Space / Enter: finish the typing, then the next line, then close.
function advance()
  local d = D
  if not d then return false end
  if not d.typed then d.typed, d.n = true, ulen(d.lines[d.i]); drawn_key = nil; return true end
  if d.i < #d.lines then
    log_line(d.beat.who, d.lines[d.i])
    d.i, d.t, d.n, d.typed = d.i + 1, 0, 0, false
    drawn_key = nil
    sfx("click")
    return true
  end
  if #d.choices > 0 then return false end     -- a choice must be made
  finish(nil)
  return true
end

function choose(idx)
  local d = D
  -- a number pressed while the last line still types finishes it and takes
  -- the choice (an early press must never be lost)
  if not (d and d.i == #d.lines and d.choices[idx]) then return false end
  sfx("sign")
  finish(d.choices[idx].id, idx)
  return true
end

-- The HUD goes off while the bars are up, through planet_camera's cinematic
-- mode: the same switch scenario_run throws for a cutscene and F4 throws for
-- a picture, so the HUD layers are saved and restored in ONE place (two
-- scripts each switching the Ship HUD layer and restoring "what it was"
-- left it off for good: 2026-11-10 probe). This layer is not among them.
-- Without a planet_camera (a test scene) the Ship HUD layer is switched here.
local hud_ours = false
local function set_hud(off)
  if off == hud_ours then return end
  hud_ours = off
  local pc = ref("planet_camera")
  if pc and pc.setCinematic then pcall(pc.setCinematic, off) return end
  if not hud_layer then
    local n = find and find("Ship HUD")
    hud_layer = n and n:getcomponent("UiLayer") or nil
  end
  if hud_layer then hud_layer.enabled = not off end
end

function cutscene(on, beat, onSkip)
  on = on ~= false
  beat = type(beat) == "table" and beat or {}
  if on == cut.on then
    if beat.caption then caption(beat.caption[1] or beat.caption.title, beat.caption[2] or beat.caption.sub, beat.caption.secs) end
    return true
  end
  cut.from, cut.t, cut.on = cut.h, 0, on
  cut.esc = 0
  if on then
    cut.skippable = beat.skippable ~= false
    cut.onSkip = onSkip or beat.onSkip
    if beat.caption then caption(beat.caption[1] or beat.caption.title, beat.caption[2] or beat.caption.sub, beat.caption.secs) end
  else
    cut.onSkip = nil
  end
  drawn_key = nil
  return true
end

-- scenario_run's `alarm` beat: a static red edge (no pulsing: docs/ui-style.md
-- §7) and the buzzer once as it comes on.
function alarm(on)
  on = on == true
  if on and not alarm_on then sfx("denied") end
  alarm_on = on
  drawn_key = nil
end
function alarmOn() return alarm_on end

function caption(title, sub, secs)
  cap = { title = title and tostring(title) or nil, sub = sub and tostring(sub) or nil, left = secs or 5 }
  drawn_key = nil
end

function skipCutscene()
  if not cut.on then return false end
  local fn = cut.onSkip
  sfx("close")
  cutscene(false)
  cap = nil
  dropSays()
  local run = ref("scenario_run")
  if fn then pcall(fn) elseif run and run.skipCutscene then pcall(run.skipCutscene) end
  lastSkip = clock
  return true
end
lastSkip = nil

-- ── scenario_run's shapes (work/scn_fwa/API.md v2) ─────────────────────────
-- scenario_ui registers these with run.listen("say" / "choice" / "cutscene").
--   line   = { who, name, tag, color, portrait, text, t0, secs }
--   choice = { who, name, prompt, options = { "text"… }, t0, timeout }
-- A portrait path is relative to the scenario's folder ("reactor/okafor.png"):
-- a game scenario's sits under scenarios/, a mod's under user://scenarios/.
local user_tex = {}
function portraitPath(p)
  if type(p) ~= "string" or p == "" then return nil end
  if p:sub(1, 3) == "rt:" or p:sub(1, 4) == "img:" then return p end
  local function has(q) return assets and assets.getFile and assets.getFile(q) ~= nil end
  if has(p) then return p end
  if has("scenarios/" .. p) then return "scenarios/" .. p end
  -- a mod's picture: read once, kept as a texture
  local u = p:sub(1, 7) == "user://" and p or ("user://scenarios/" .. p)
  if user_tex[u] ~= nil then return user_tex[u] or nil end
  user_tex[u] = false
  if assets and assets.readBytes and assets.textureFromBytes then
    local ok, bytes = pcall(assets.readBytes, u)
    if ok and bytes then
      local ok2, tex = pcall(assets.textureFromBytes, bytes)
      if ok2 and tex then user_tex[u] = tex end
    end
  end
  return user_tex[u] or nil
end

local function run_ref() return ref("scenario_run") end

-- drop the says on screen and waiting, WITHOUT answering them (the runner
-- has moved on: their reply would end the line it shows now)
local function drop_stale_says()
  local keep = {}
  for _, q in ipairs(Q) do if q.beat.src ~= "say" then keep[#keep + 1] = q end end
  Q = keep
  if D and D.beat.src == "say" and #D.choices == 0 then
    log_line(D.beat.who, D.lines[D.i])
    D = nil
    drawn_key = nil
  end
end
function onSay(line)
  if type(line) ~= "table" then return false end
  -- THE PLATE FOLLOWS THE RUNNER (Ty 2026-11-10: lines left half-typed, the
  -- plate lagging the story): the runner's line is the one shown
  drop_stale_says()
  local w = type(line.with) == "table" and line.with or nil
  return dialogue({ who = line.name or line.who, role = line.tag, color = line.color, portrait = line.portrait,
                    text = line.text, src = "say", radio = line.radio, garbled = line.garbled,
                    with = w and { who = w.name or w.who, role = w.tag, portrait = w.portrait, radio = w.radio } or nil },
    function() local r = run_ref(); if r and r.lineDone then pcall(r.lineDone) end end)
end

function onChoice(c)
  if type(c) ~= "table" then return false end
  return dialogue({ who = c.name or c.who, role = c.tag, color = c.color, portrait = c.portrait, radio = c.radio, text = c.prompt or "",
                    choices = c.options, src = "choice", timeout = c.timeout, pause = c.pause },
    function(_, idx) local r = run_ref(); if r and r.choose and idx then pcall(r.choose, idx) end end)
end

function onCutscene(on)
  return cutscene(on ~= false, {}, function() local r = run_ref(); if r and r.skipCutscene then pcall(r.skipCutscene) end end)
end

-- The runner moved on without us (a choice timed out): close the panel
-- without answering. scenario_ui calls this with the state it polls.
function sync(st)
  if not (D and st) then return false end
  -- the runner's line is over (its time ran out, or it was skipped): close it
  if D.beat.src == "say" and #D.choices == 0 and (st.line == nil or st.line.text ~= D.beat.text) then
    log_line(D.beat.who, D.lines[D.i])
    D = nil
    drawn_key = nil
    open_next()
    return true
  end
  if D.beat.src == "choice" and st.choice == nil then
    log_line(D.beat.who, D.lines[D.i])
    D = nil
    drawn_key = nil
    open_next()
    return true
  end
  return false
end

-- A skip drops what is still to be said.
function dropSays()
  local keep = {}
  for _, q in ipairs(Q) do if q.beat.src ~= "say" then keep[#keep + 1] = q end end
  Q = keep
  if D and D.beat.src == "say" then D = nil; drawn_key = nil; open_next() end
end

-- ── the trees ───────────────────────────────────────────────────────────────

-- The speaker's picture (or role letter). A radio voice (cast `radio`) is
-- seen through the set: the picture in phosphor green, and RADIO (or LINK
-- LOST, a `link` with no path) by the name. `side` "with" is the
-- listener's, smaller and dimmed on the right (say.with).
local function portrait_tree(b, side)
  local p = portraitPath(b.portrait)
  local size = side == "with" and 64 or 92
  local key = side == "with" and "pw" or "pt"
  local kid
  if p then
    kid = { "image", key = "img", inset = 4, texture = p, imageFit = "cover",
            tintR = (b.radio or b.garbled) and 0.62 or nil, tintB = (b.radio or b.garbled) and 0.72 or nil,
            tintA = side == "with" and 0.55 or nil }
  else
    kid = { "text", key = "g", style = "scn/glyph", inset = 0, textAlign = "center", textValign = "center",
            text = glyphOf(b.role), textSize = side == "with" and 30 or nil,
            textColor = side == "with" and { 0.30, 0.42, 0.34, 1.0 } or nil }
  end
  return { "box", key = key, style = "hud/instrument", w = size, h = size, pad = p and 4 or 0, opacity = side == "with" and 0.5 or nil, kid }
end
-- the listener, on the right: the picture and the name under it, dimmed
local function listener_tree(w)
  return { "col", key = "lst", w = 72, h = "fit", pad = 0, gap = 4, align = "center",
    portrait_tree(w, "with"),
    { "text", key = "ln", style = "hud/micro", w = "100%", h = "fit", textAlign = "center", wrap = true, opacity = 0.6,
      text = string.upper(tostring(w.who or "")) } }
end

local function dialogue_tree(d, y)
  -- (on foot the plate sits above the walk-up prompt and tool hint)
  local b = d.beat
  local line = d.lines[d.i] or ""
  local shown = d.typed and line or (usub(line, d.n) .. "▌")
  local kids = {
    { "row", key = "who", w = "100%", h = "fit", pad = 0, gap = 10, align = "end",
      { "text", key = "n", style = "panel/heading", w = "fit", h = "fit", text = string.upper(tostring(b.who or "Ops")),
        textColor = type(b.color) == "table" and b.color or nil },
      b.role and { "text", key = "r", style = "panel/label", w = "grow", h = "fit", text = string.upper(roleName(b.role)) } or nil,
      (b.radio or b.garbled) and { "text", key = "rad", style = "hud/micro", w = "fit", h = "fit", text = b.garbled and "◉ LINK LOST" or "◉ RADIO" } or nil },
    { "text", key = "t", name = "Scenario Dialogue Line", style = "panel/body", w = "100%", h = "fit", wrap = true, text = shown },
  }
  local last = d.i == #d.lines
  if d.typed and last and #d.choices > 0 then
    local row = { "col", key = "ch", w = "100%", h = "fit", pad = 0, gap = 4, align = "stretch" }
    for i, c in ipairs(d.choices) do
      row[#row + 1] = { "button", key = "c" .. i, name = "Scenario Choice " .. i, style = "panel/secondary", w = "100%", h = "fit",
        minH = 30, dir = "row", pad = 6, gap = 10, align = "center", onClicked = function() choose(i) end,
        { "text", key = "k", style = "panel/title", w = 16, h = "fit", textAlign = "center", text = tostring(i) },
        { "text", key = "t", style = "panel/body", w = "grow", h = "fit", wrap = true, text = c.text } }
    end
    kids[#kids + 1] = row
  else
    kids[#kids + 1] = { "text", key = "h", style = "panel/hint", w = "100%", h = "fit", textAlign = "end",
      text = d.typed and (last and "Click, Space or Enter: close" or "Click, Space or Enter: next") or "Click: the whole line" }
  end
  return { "button", key = "dlg", name = "Scenario Dialogue", style = "panel/frame", pin = "bottom", y = y, w = PANEL_W, h = "fit",
    dir = "row", pad = 14, gap = 14, align = "start", focusable = false,
    onClicked = function() if not (d.typed and last and #d.choices > 0) then advance() end end,
    portrait_tree(b),
    { "col", key = "txt", w = "grow", h = "fit", pad = 0, gap = 6, align = "start", items = kids, function(k) return k end },
    b.with and listener_tree(b.with) or nil }
end

local function stage_tree()
  local out = {}
  if alarm_on then out[#out + 1] = { "box", key = "alarm", style = "scn/alarm", inset = 0 } end
  local h = math.floor(cut.h + 0.5)
  if h > 0 then
    out[#out + 1] = { "box", key = "top", style = "scn/letterbox", pin = "top", w = "100%", h = h }
    out[#out + 1] = { "box", key = "bot", style = "scn/letterbox", pin = "bottom", w = "100%", h = h }
    if cut.on and cut.skippable ~= false and h >= BAR_H - 1 then
      local frac = math.min(1, cut.esc / SKIP_HOLD)
      out[#out + 1] = { "row", key = "skip", pin = "bottomRight", x = -28, y = -(BAR_H - 22) / 2 - 4, w = "fit", h = 22, pad = 0, gap = 8, align = "center",
        { "text", key = "t", style = "panel/hint", w = "fit", h = "fit", text = "Hold Esc to skip" },
        { "box", key = "m", style = "ctl/track", w = 60, h = 6, pad = 0,
          { "box", key = "f", style = "ctl/fill", pin = "left", w = math.max(0, math.floor(60 * frac)), h = 6 } } }
    end
  end
  if cap then
    local in_bar = h >= BAR_H - 1
    out[#out + 1] = { "col", key = "cap", pin = "bottom", y = in_bar and -(BAR_H - 46) / 2 or -150, w = 820, h = "fit", pad = 0, gap = 2, align = "center",
      cap.title and { "text", key = "a", style = "scn/capTitle", w = "100%", h = "fit", textAlign = "center", text = cap.title } or nil,
      cap.sub and { "text", key = "b", style = "scn/capSub", w = "100%", h = "fit", textAlign = "center", wrap = true, text = cap.sub } or nil }
  end
  if D then
    local y = (h >= BAR_H - 1) and -(BAR_H + 10) or -150
    if cap and h < BAR_H - 1 then y = -210 end
    out[#out + 1] = dialogue_tree(D, y)
  end
  return out
end

local function tidy(t)
  if type(t) ~= "table" then return t end
  local idx = {}
  for k in pairs(t) do if type(k) == "number" then idx[#idx + 1] = k end end
  table.sort(idx)
  local vals = {}
  for _, k in ipairs(idx) do local v = t[k]; t[k] = nil; if v ~= false then vals[#vals + 1] = v end end
  for i, v in ipairs(vals) do t[i] = tidy(v) end
  return t
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  me = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
end

local function redraw(node)
  local tree = tidy(stage_tree())
  if #tree == 0 then
    ui.make(node, {})
    if el and el.visible then el.visible = false end
    text_node = nil
    return
  end
  if el and not el.visible then el.visible = true end
  ui.make(node, tree)
  text_node = D and find and find("Scenario Dialogue Line") or nil
  last_n = D and D.n or -1
  if D and D.typed and D.i == #D.lines and #D.choices > 0 and ui and ui.focus then
    local f = find and find("Scenario Choice 1")
    if f then ui.focus(f) end
  end
end

local idle_drawn = false
local last_wall = nil
function update(node, dt)
  -- (the wall clock, not the frame's dt: a choice pauses the world, and a
  -- paused world's dt left a prompt typed to its first letter, Ty 2026-11-10)
  local w = app and app.wallClock and app.wallClock() or nil
  if w then dt = last_wall and math.max(0, math.min(0.1, w - last_wall)) or (dt or 0); last_wall = w end
  dt = dt or 0
  if not D and #Q == 0 and not cut.on and cut.h <= 0 and not cap and not alarm_on then
    if idle_drawn then redraw(node); idle_drawn = false; set_hud(false); hold_world(false) end
    return
  end
  idle_drawn = true
  clock = clock + dt
  local key_parts = {}
  -- the bars
  if cut.t < BAR_SECS + dt then
    cut.t = cut.t + dt
    cut.h = barH(cut.t, cut.on, cut.from)
    key_parts[#key_parts + 1] = string.format("h%d", math.floor(cut.h + 0.5))
  end
  set_hud(cut.on)
  -- hold Esc to skip
  if cut.on and cut.skippable ~= false and input and input.key then
    local was = cut.esc
    if input.key("escape") then cut.esc = cut.esc + dt else cut.esc = 0 end
    if cut.esc >= SKIP_HOLD then skipCutscene() end
    if math.floor(was * 10) ~= math.floor(cut.esc * 10) then key_parts[#key_parts + 1] = "e" .. math.floor(cut.esc * 10) end
  end
  -- the caption
  if cap then
    cap.left = cap.left - dt
    if cap.left <= 0 then cap = nil; drawn_key = nil end
  end
  -- the dialogue
  -- a plain line already read, with more waiting behind it, moves on by
  -- itself (the runner does not wait on a `say` with wait = false)
  if D and D.typed and #Q > 0 and #D.choices == 0 and D.i == #D.lines then
    D.read = (D.read or 0) + dt
    if D.read > 1.5 + 0.03 * ulen(D.lines[D.i] or "") then finish(nil) end
  end
  if D then
    hold_world(D.pause == true)
    if #D.choices > 0 and input and input.setMouseLocked then input.setMouseLocked(false) end
    local line = D.lines[D.i] or ""
    if not D.typed then
      D.t = D.t + dt
      local n = math.floor(D.t * CPS)
      if n >= ulen(line) then D.typed, D.n = true, ulen(line); drawn_key = nil; sfx("chime")
      else D.n = n end
    end
    if input and input.pressed then
      local last = D.i == #D.lines
      local picked = false
      if last and #D.choices > 0 then
        for i = 1, #D.choices do if input.pressed(tostring(i)) then picked = choose(i) break end end
      end
      if not picked and not (D and D.typed and last and #D.choices > 0)
        and (input.pressed("space") or input.pressed("enter")) then
        advance()   -- finishes the typing; never skips a choice that is up
      end
    end
  else
    hold_world(false)
  end
  local key = table.concat(key_parts, ",") .. (D and string.format("d%d.%d.%s.%d.%s", D.i, #Q, tostring(D.typed), #D.choices,
    tostring(D.beat.with and D.beat.with.who or "")) or "") ..
    (cap and ("c" .. tostring(cap.title) .. tostring(cap.sub)) or "") .. (cut.on and "on" or "off") .. (alarm_on and "A" or "")
  if key ~= drawn_key or drawn_key == nil then
    redraw(node)
    drawn_key = key
  elseif D and not D.typed and D.n ~= last_n then
    if text_node and text_node.valid ~= false then
      text_node.text = usub(D.lines[D.i], D.n) .. "▌"
      last_n = D.n
    end
  end
end
