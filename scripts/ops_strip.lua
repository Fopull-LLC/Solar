-- OPS STRIP — the comms line: Ops (and the crew) talking to you in a
-- scenario (work/scenarios PLAN §1.5; docs/scenarios.md).
--
-- A CRT display in a bezel at the bottom of the screen ("hud/instrument"),
-- the line printed across it in phosphor at about 40 characters a second
-- with a radio chirp at each end of the transmission (sfx "card" / "chime",
-- the Apollo Quindar tones), the speaker's name in dim phosphor ahead of it,
-- and the last three lines above it, dimmer. Lines wait their turn in a
-- queue. Click the strip to finish the line (and again to move on); Space
-- does the same while a scenario panel holds the keys, so it never jumps
-- the crew or stages a craft.
--
--   local os = findScript("ops_strip")
--   if os then os.say("Sealed. Now split it.") end        -- Ops
--   if os then os.say("Breathing.", "Okafor") end          -- a crew member
--
-- scenario_run's `ops` and `say` beats come here through
-- scenario_ui.lua (scenario_run.listen("ops", …)).
--
-- COST. Described with ui.make only when a line starts, ends or the strip
-- fades; while a line types, one text node's text is set at the typing rate.
-- Idle (no line, nothing queued) the update is a few comparisons.
--
-- Pure (luajit, tests/smoke_menu_scenarios.lua): typed(text, n),
-- charsAt(t, cps), holdFor(text), and the queue (newQueue, push, tick, skip).

CPS = 40            -- characters a second
HOLD_MIN = 4.0      -- s a finished line stays up …
HOLD_PER_CHAR = 0.045 -- … plus this a character (a long line is read slower)
GAP = 0.6           -- s between a finished line and the next queued one
FADE = 0.5          -- s the strip takes to fade once the last line is done
HISTORY = 3         -- earlier lines kept above the current one
OPS = "OPS"         -- the speaker when none is named
-- THE FRAME (2026-11-11: a third wrapped line spilled under it). Every text
-- has a fixed width, so it is measured where it wraps (a `grow` text was
-- measured at the whole row's width and drew more lines than its frame
-- held); an earlier line takes at most HIST_LINES lines (ellipsised), and the
-- oldest scroll away while the lines would pass LINES_MAX (CPL: the
-- characters a line holds, the readout's mono cut at TEXT_W, measured).
W = 640             -- the strip's width
PAD, GAP_X = 10, 8  -- its padding; the speaker-to-text gap
WHO_W = 92          -- the speaker's column
TEXT_W = W - 2 * PAD - WHO_W - GAP_X
CPL = 68
HIST_LINES = 2
LINES_MAX = 7

-- ── pure ────────────────────────────────────────────────────────────────────

-- The number of characters (not bytes) in a string.
local function ulen(s)
  if utf8 and utf8.len then
    local n = utf8.len(s)
    if n then return n end
  end
  -- luajit has no utf8: count the bytes that start a character
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end
charCount = ulen

-- The first `n` characters of `text` (never cut inside a character).
function typed(text, n)
  text = tostring(text or "")
  if n <= 0 then return "" end
  local i, c = 1, 0
  while i <= #text do
    local b = text:byte(i)
    local w = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or (b >= 0xC0 and 2 or 1)))
    c = c + 1
    if c > n then return text:sub(1, i - 1) end
    i = i + w
  end
  return text
end

-- Characters shown `t` seconds into a line.
function charsAt(t, cps) return math.max(0, math.floor((t or 0) * (cps or CPS))) end

-- Seconds a finished line stays up.
function holdFor(text) return HOLD_MIN + HOLD_PER_CHAR * ulen(tostring(text or "")) end

-- THE QUEUE. q.cur = { who, text, n (chars), t (s since it started),
-- typed (all shown), left (s of hold left) } or nil; q.waiting = the lines
-- after it; q.hist = the last HISTORY finished lines (oldest first);
-- q.gap = s before the next line may start; q.fade = 0..1 while fading out.
function newQueue() return { cur = nil, waiting = {}, hist = {}, gap = 0, fade = 0, said = 0 } end

-- done(): called once the line has been shown and retired (scenario_run's
-- `ops` beat holds its queue until then: lineDone).
function push(q, text, who, done)
  text = tostring(text or "")
  if text == "" then return false end
  q.waiting[#q.waiting + 1] = { who = (who and who ~= "") and who or OPS, text = text, done = done }
  return true
end

local function retire(q)
  local c = q.cur
  if not c then return end
  q.hist[#q.hist + 1] = { who = c.who, text = c.text }
  while #q.hist > HISTORY do table.remove(q.hist, 1) end
  q.cur = nil
  q.gap = GAP
  if c.done then pcall(c.done) end
end

-- Advance by dt seconds. → what changed: "start" (a line began: chirp),
-- "typed" (the last character just went up: chirp), "chars" (more characters),
-- "end" (a line retired), "idle" (the strip just emptied), or nil.
function tick(q, dt, cps)
  dt = dt or 0
  local c = q.cur
  if c then
    c.t = c.t + dt
    if not c.typed then
      local n = math.min(c.len, charsAt(c.t, cps))
      if n >= c.len then
        c.n, c.typed, c.left = c.len, true, holdFor(c.text)
        return "typed"
      end
      if n ~= c.n then c.n = n; return "chars" end
      return nil
    end
    c.left = c.left - dt
    -- a queued line cuts the hold short (it has been read by now)
    if c.left <= 0 or (#q.waiting > 0 and c.left <= holdFor(c.text) - 1.5) then
      retire(q)
      return "end"
    end
    return nil
  end
  if q.gap > 0 then q.gap = math.max(0, q.gap - dt) end
  if #q.waiting > 0 and q.gap <= 0 then
    local nx = table.remove(q.waiting, 1)
    q.cur = { who = nx.who, text = nx.text, len = ulen(nx.text), n = 0, t = 0, typed = false, left = 0, done = nx.done }
    q.fade = 0
    q.said = q.said + 1
    return "start"
  end
  if (q.linger or 0) > 0 then
    q.linger = q.linger - dt
    return nil
  end
  if #q.hist > 0 and q.fade < 1 then
    q.fade = math.min(1, q.fade + dt / FADE)
    if q.fade >= 1 then return "idle" end
    return "fade"
  end
  return nil
end

-- Click / Space: finish the typing; on a finished line, move on.
-- → "typed" | "end" | nil
function skip(q)
  local c = q.cur
  if not c then return nil end
  if not c.typed then
    c.n, c.typed, c.left = c.len, true, holdFor(c.text)
    return "typed"
  end
  retire(q)
  q.gap = 0
  return "end"
end

function busyQ(q) return q.cur ~= nil or #q.waiting > 0 end

-- The lines a text takes at CPL characters a line (word wrap, estimated).
function linesOf(text, cpl)
  cpl = cpl or CPL
  local n, col = 1, 0
  for w in tostring(text or ""):gmatch("%S+") do
    local l = ulen(w)
    if col == 0 then col = l
    elseif col + 1 + l <= cpl then col = col + 1 + l
    else n = n + 1; col = l end
    while col > cpl do n = n + 1; col = col - cpl end
  end
  return n
end
-- The earlier lines that fit above the current text: the newest first kept,
-- each HIST_LINES at most, all within LINES_MAX with the current line's.
-- → the first index of hist to show (#hist + 1: none)
function histFrom(hist, curText)
  local used = curText and linesOf(curText) or 0
  local from = #hist + 1
  for i = #hist, 1, -1 do
    local l = math.min(HIST_LINES, linesOf(hist[i].text))
    if used + l > LINES_MAX then break end
    used = used + l
    from = i
  end
  return from
end

-- A line said elsewhere (the dialogue panel): straight into the history, no
-- typing, no chirp; the strip shows it for a few seconds when it is next up.
function logQ(q, text, who)
  text = tostring(text or "")
  if text == "" then return false end
  q.hist[#q.hist + 1] = { who = (who and who ~= "") and who or OPS, text = text }
  while #q.hist > HISTORY do table.remove(q.hist, 1) end
  q.fade, q.linger = 0, HOLD_MIN
  return true
end

-- ── the strip in the scene ──────────────────────────────────────────────────

local Q = newQueue()
local el, me = nil, nil
local drawn = false       -- a tree is up
local line_node = nil     -- the made text node the typewriter writes into
local last_n = -1

-- Published for probes and scenario_ui: the line up now and the history.
current = nil             -- { who, text, shown } or nil
function history() return Q.hist end
function queue() return Q end
function busy() return busyQ(Q) end
lastChirp = nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function chirp(key)
  lastChirp = key
  local fx = ref("sfx")
  if fx and fx.play then fx.play(key) end
end

-- (gy3, Ty 2026-11-11: "Logged. The Depot ships Battery Bank and Solar
-- Array now." during Graveyard Shift) while a scenario runs, only its own
-- lines speak (`opts.scenario`, scenario_ui's): the game's progression,
-- feats, milestones and ruin pointers stay silent (logged, never shown).
-- After the run (freeplay) the game speaks again.
function inScenario()
  local sr = findScript and findScript("scenario_run") or nil
  if not (sr and sr.isActive and sr.isActive()) then return false end
  local ph = sr.phaseNow and sr.phaseNow() or nil
  return ph ~= "freeplay" and ph ~= nil
end
silenced = 0      -- (probes) lines kept quiet in a scenario
function say(text, who, done, opts)
  if not (opts and opts.scenario) and inScenario() then
    silenced = silenced + 1
    if log then log("ops_strip: quiet in a scenario: " .. tostring(text)) end
    return false
  end
  return push(Q, text, who, done)
end

function logLine(text, who)
  local ok = logQ(Q, text, who)
  if ok then logged = true end
  return ok
end
logged = false

function clear()
  Q = newQueue()
  current = nil
end

-- A finished line, or move on. scenario_ui calls this for Space while one of
-- its panels holds the keys; a click on the strip calls it too.
function skipLine()
  local r = skip(Q)
  if r == "typed" then chirp("chime") end
  -- (the whole line up now: the next update redraws it, or the typewriter's
  -- half line stayed up through the hold)
  if r then logged = true end
  return r
end

-- Where the strip sits: above the flight console when flying (flight_hud's
-- layout), above the tool belt on foot.
-- (on foot: above the walk-up prompt and the tool hint, which reach up to
-- about 130 from the bottom)
local FOOT_Y = -168
local function strip_y()
  local fh = ref("flight_hud")
  local vc = nil
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting then vc = v break end
  end
  if vc and fh and fh.layout and fh.layout.consoleRise then return -(fh.layout.consoleRise + 12) end
  return FOOT_Y
end

local function speaker(who) return string.upper(tostring(who or OPS)) .. "  ›" end

local function describe()
  local c = Q.cur
  local a = 1 - Q.fade
  local rows = {}
  -- (fixed text widths: a wrapped text is measured at the width it draws at;
  -- the oldest lines scroll away before the strip passes LINES_MAX)
  for i = histFrom(Q.hist, c and c.text), #Q.hist do
    local h = Q.hist[i]
    rows[#rows + 1] = { "row", key = "h" .. i, w = "100%", h = "fit", pad = 0, gap = GAP_X, align = "start",
      { "text", key = "w", style = "menu/slotTag", w = WHO_W, h = "fit", text = speaker(h.who), textAlign = "end" },
      { "text", key = "t", style = "hud/readout", w = TEXT_W, h = "fit", wrap = true, maxLines = HIST_LINES, overflow = "ellipsis",
        opacity = 0.55, text = h.text } }
  end
  if c then
    -- (the current line is sized for all of it from its first character: the
    -- typewriter fills a frame already tall enough, it never grows under it)
    rows[#rows + 1] = { "row", key = "cur", w = "100%", h = "fit", pad = 0, gap = GAP_X, align = "start",
      { "text", key = "w", style = "hud/micro", w = WHO_W, h = "fit", text = speaker(c.who), textAlign = "end" },
      -- (a box with no stack: its two texts lie one over the other, and it
      -- fits the larger, the whole line, invisible)
      { "box", key = "tc", w = TEXT_W, h = "fit",
        { "text", key = "full", style = "hud/readout", w = TEXT_W, h = "fit", wrap = true, opacity = 0, text = c.text .. "▌" },
        { "text", key = "t", name = "Ops Strip Line", style = "hud/readout", w = TEXT_W, h = "fit", wrap = true,
          text = typed(c.text, c.n) .. (c.typed and "" or "▌") } } }
  end
  return {
    { "button", key = "strip", style = "hud/instrument", pin = "bottom", y = strip_y(), w = W, h = "fit",
      dir = "column", pad = PAD, gap = 3, align = "stretch", opacity = a, focusable = false,
      tooltip = c and "Click (or Space in a briefing) to finish the line" or nil,
      onClicked = function() skipLine() end,
      items = rows, function(r) return r end },
  }
end

local function redraw(node)
  if not (ui and ui.make) then return end
  if (not Q.cur and #Q.hist == 0) or (Q.cur == nil and Q.fade >= 1) then
    if drawn then ui.make(node, {}); drawn = false end
    line_node, current = nil, nil
    Q.hist = {}   -- the history goes with the strip
    -- (an empty full-screen element must not sit over the world's clicks)
    if el and el.visible then el.visible = false end
    return
  end
  ui.make(node, describe())
  drawn = true
  line_node = Q.cur and find and find("Ops Strip Line") or nil
  if Q.cur then current = { who = Q.cur.who, text = Q.cur.text, shown = typed(Q.cur.text, Q.cur.n) } else current = nil end
  last_n = Q.cur and Q.cur.n or -1
end

function start(node)
  me = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  Q = newQueue()
end

-- Hidden while the world loads, a full panel is up, or the interface is off
-- (cinematic, the free camera).
local function hidden()
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.curtain or gm.inputOwner == "builder") then return true end
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local om = ref("orbit_map")
  if om and om.map_view then return true end
  -- the dialogue plate says it (and logs it here); a cutscene hides the HUD
  local sg = ref("scenario_stage")
  if sg and sg.busy and sg.busy() then return true end
  return false
end

local was_hidden = false
local last_wall = nil
function update(node, dt)
  if not Q.cur and #Q.waiting == 0 and #Q.hist == 0 and not drawn then return end
  local hide = hidden()
  if hide then
    if drawn then ui.make(node, {}); drawn = false; line_node = nil end
    if el and el.visible then el.visible = false end
    was_hidden = true
    return   -- the line waits: nothing is said to nobody
  end
  -- (gy3) the wall clock, not the frame's dt: a choice or a brief pauses the
  -- world, and a paused frame's dt froze the typewriter at its first letter
  local wc = app and app.wallClock and app.wallClock() or nil
  local wdt = (wc and last_wall) and math.max(0, math.min(0.1, wc - last_wall)) or (dt or 0)
  last_wall = wc
  local ev = tick(Q, wdt)
  if ev == "start" then chirp("card") end
  if ev == "typed" then chirp("chime") end
  if el and not el.visible then el.visible = true end
  if ev == "start" or ev == "end" or ev == "idle" or ev == "fade" or ev == "typed" or was_hidden or logged
     or (not drawn and (Q.cur or #Q.hist > 0)) then
    logged = false
    redraw(node)
    was_hidden = false
    return
  end
  if ev == "chars" and Q.cur then
    -- the typewriter: one text node, no re-describe
    if line_node and line_node.valid ~= false and Q.cur.n ~= last_n then
      local s = typed(Q.cur.text, Q.cur.n) .. "▌"
      line_node.text = s
      if current then current.shown = s end
      last_n = Q.cur.n
    elseif not line_node then
      redraw(node)
    end
  end
end
