-- BIG CAPTION — the few moments that deserve the middle of the screen.
--
-- Losing a vessel used to be one line in the log: the pod failed, the crew was
-- put down beside the wreck, and the game carried on as if a panel had closed.
-- It is the single biggest thing that can happen on a flight, and nothing on
-- screen said it had.
--
-- One title and one line under it, upper third, fading in and out. Drawn into
-- its own UI layer (the node this rides on), so it never shares a container
-- with a HUD script that reconciles its own children. A second `show` replaces
-- the first rather than stacking.
--
--   local bc = findScript("big_caption")
--   if bc then bc.show("VESSEL LOST", "The craft is gone.", 5, "alarm") end
--
-- Under reduced motion it still fades — a fade is not motion — but does not
-- drift.

-- FEWER, AND ONLY WHAT MATTERS (Ty 2026-11-11: "I don't like all the popup
-- messages, they happen too much, especially with certain things like
-- caving. Why does it tell me when there's a cave-in? It should just happen
-- and I have to find out."). Every caption says what KIND it is, the fourth
-- argument:
--   "alarm"   the player must act now (suit O2, a room venting, a reactor
--             trip, someone down): always shown, and it replaces what is up.
--   "story"   a scenario's own words: always shown.
--   "result"  the answer to something the player just did (a repair done, a
--             pack recovered, a door refused): shown, a repeat of the same
--             title within RESULT_REPEAT s is dropped.
--   "info"    (the default) news that may be worth a look: rate-limited and
--             merged: never over another caption, never within INFO_GAP s of
--             the last one, never the same title twice within INFO_REPEAT s.
--   "quiet"   what just happens (a cave-in, a hazard met, a survey filed, a
--             machine finishing): never shown; it goes to the log and the
--             history below, and codex lines go to the codex silently.
-- Whatever is not shown is kept in `history` (newest last) for a log page.

local title, sub = nil, nil
local shown_at, life = -1, 0
local cur_kind = nil
local clock = 0.0
local drawn = false

-- Published for probes: what is up right now, or nil.
current = nil
-- (probes) how many were shown and how many were kept back, by kind
counts = { shown = 0, held = 0, byKind = {} }
history = {}          -- { t, title, sub, kind, shown }
HISTORY_N = 60
INFO_GAP, INFO_REPEAT, RESULT_REPEAT = 30.0, 120.0, 15.0
local last_info_t, last_title_t = -1e9, {}

local function remember(t, s, kind, shown)
  history[#history + 1] = { t = clock, title = t, sub = s, kind = kind, shown = shown }
  if #history > HISTORY_N then table.remove(history, 1) end
  counts.byKind[kind] = (counts.byKind[kind] or 0) + 1
  if shown then counts.shown = counts.shown + 1 else counts.held = counts.held + 1 end
  if not shown and log then log("caption (held, " .. kind .. "): " .. tostring(t) .. " · " .. tostring(s or "")) end
end

-- → true if it went up
function show(t, s, secs, kind)
  kind = kind or "info"
  local up = title ~= nil and (clock - shown_at) <= life
  local key = tostring(t)
  local ok = true
  if kind == "quiet" then ok = false
  elseif kind == "info" then
    if up or clock - last_info_t < INFO_GAP or (last_title_t[key] and clock - last_title_t[key] < INFO_REPEAT) then ok = false end
  elseif kind == "result" then
    if last_title_t[key] and clock - last_title_t[key] < RESULT_REPEAT then ok = false end
    -- (an answer never covers an alarm still up)
    if up and cur_kind == "alarm" then ok = false end
  end
  remember(t, s, kind, ok)
  if not ok then return false end
  last_title_t[key] = clock
  if kind == "info" then last_info_t = clock end
  title, sub, cur_kind = t, s, kind
  shown_at, life = clock, secs or 4.0
  current = t
  return true
end

-- what just happens: the log and the history, never the screen
function note(t, s) return show(t, s, nil, "quiet") end

function hide()
  life = 0
end

-- The caption up now keeps its place and its fade, with a new line under it
-- (a count-down that follows a reading: cabin_air's DEPRESSURISATION).
-- Nothing when another title is up. → true when it changed the line
function retext(t, s)
  if current ~= t or clock - shown_at > life then return false end
  sub = s
  return true
end

local FADE_IN, FADE_OUT = 0.35, 0.9

-- A full panel the player stopped to read (the pause menu, a facility's, the
-- Ops Board, the map) owns the screen: the caption waits under it, and its
-- clock with it, so it is still seen when the panel closes.
local function panel_up()
  for _, k in ipairs({ "pause_menu", "facility_menu", "ops_board", "orbit_map", "tracking_station" }) do
    local s = findScript and findScript(k)
    if s then
      if k == "pause_menu" then if s.open then return true end
      elseif s.isOpen and s.isOpen() then return true end
    end
  end
  return false
end

function update(node, dt)
  if title and panel_up() then
    if drawn then ui.make(node, {}); drawn = false end
    return
  end
  clock = clock + (dt or 0)
  local age = clock - shown_at
  if not title or age > life + FADE_OUT then
    if drawn then ui.make(node, {}); drawn = false end
    title, current, cur_kind = nil, nil, nil
    return
  end
  local a = math.min(1, age / FADE_IN)
  if age > life then a = math.max(0, 1 - (age - life) / FADE_OUT) end
  local still = access and access.reducedMotion and access.reducedMotion()
  local lift = still and 0 or math.floor((1 - math.min(1, age / FADE_IN)) * 10)
  ui.make(node, {
    -- A warning placard: riveted enamel with a red rim, the word stencilled
    -- ("hud/caption*" styles).
    { "col", key = "big", style = "hud/caption", pin = "top", y = 150 + lift, w = 680, h = "fit",
      pad = 18, gap = 6, align = "center", opacity = a,
      { "text", key = "t", style = "hud/captionTitle", w = "100%", h = "fit", textAlign = "center",
        text = title },
      sub and { "text", key = "s", style = "hud/captionSub", w = "100%", h = "fit", textAlign = "center",
        wrap = true, text = sub } or nil,
    },
  })
  drawn = true
end
