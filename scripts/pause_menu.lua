-- PAUSE — Esc, and the one screen that answers "what are the keys?"
--
-- The game had neither. Esc meant four different things depending on what
-- happened to be open and nothing when nothing was, there was no way to stop the
-- world, and the complete list of controls existed only in the README — so a
-- player who did not already know that `2` is the harvester, that scroll goes to
-- first person, or that `M` is the map, had no way in the game to find out. That
-- is most of what "hard to do things and interact with things" is: not that the
-- verbs are bad, but that nothing ever names them.
--
-- Three things, then:
--
--   * ESC BACKS OUT ONE LEVEL, everywhere, in a fixed order. A panel closes
--     first, then first person, then this. Nothing else in the game may open on
--     an Esc that something else has already answered, which is why the ladder
--     is written down here rather than implied by five scripts each polling the
--     key and hoping.
--   * THE WORLD ACTUALLY STOPS. `physics.pause(true)` freezes the gameplay tick
--     while scripts keep running, so a menu is a menu and not a place your
--     rocket keeps falling while you read.
--   * THE KEYS ARE ON SCREEN. Every one of them, grouped by what you are doing,
--     read from the table below — which `tests/smoke_controls.lua` holds against
--     the scripts, so a key this card advertises is a key something reads.
--
--   ESC        open / back out
--   ↑ ↓ ⏎      the rows are focusable, so it works without a mouse
--
-- SETTINGS is settings.lua's screen (display, camera, controls, audio, accessibility),
-- framed here; this script also shows graphics.lua's `notice` as a toast when
-- the game lowers the quality by itself.

-- Published: everything that owns the pointer asks this.
open = false

local el
local page = "menu"          -- "menu" | "controls" | "settings"
local paused_by_us = false

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

-- ── the controls ────────────────────────────────────────────────────────────
--
-- Data, not prose, because `smoke_controls.lua` reads it: every `keys` entry is
-- checked against what the scripts actually poll. A card that advertises a key
-- nobody reads is worse than no card — it is the game telling you to press G and
-- then ignoring you, which is precisely the flavour of jank this pass exists to
-- remove.
--
-- `keys` is what the test checks. `shown` is what the player reads, when the two
-- differ (a range, a mouse button, a chord).
local CONTROLS = {
  { group = "On foot", col = 1, rows = {
    { keys = { "w", "a", "s", "d" }, shown = "W A S D", what = "walk" },
    { keys = { "shift" }, shown = "SHIFT", what = "hold to sprint" },
    { keys = { "space" }, shown = "SPACE", what = "jump  ·  swim up in water" },
    { keys = { "ctrl" }, shown = "CTRL", what = "dive, in water" },
    { keys = {}, shown = "RIGHT MOUSE", what = "hold to look around" },
    { keys = { "alt" }, shown = "MMB / ALT", what = "keep looking without holding a button" },
    { keys = {}, shown = "SCROLL", what = "zoom  ·  all the way in is first person" },
    { keys = { "e" }, shown = "E  or  ⏎", what = "go into the building you are at" },
  } },
  { group = "Tools", col = 1, rows = {
    { keys = { "1", "2", "3" }, shown = "1  2  3", what = "the tool belt: gravity gun  ·  terrain laser  ·  anything you carry (a beacon)" },
    { keys = {}, shown = "LEFT MOUSE", what = "hold to use the tool on what the crosshair is over" },
    { keys = {}, shown = "SCROLL", what = "gravity gun: hold what you grabbed nearer / further" },
    { keys = { "r" }, shown = "R", what = "gravity gun: throw what you are holding" },
    { keys = { "e" }, shown = "E", what = "gravity gun: stow what you are holding (a rock as its ore, a log as timber)  ·  let go of it in the Commerce Depot's intake to deposit it, or recycle a wreck" },
    { keys = { "q" }, shown = "Q", what = "terrain laser: DIG / FILL  ·  relay beacon: pick one up" },
    { keys = { "e" }, shown = "hold E", what = "terrain laser: CUT — a short cutting beam that saws through plants" },
    { keys = { "tab", "i" }, shown = "TAB  or  I", what = "the suit pack  ·  at the depot, its buy and sell counters" },
  } },
  { group = "Everywhere", col = 1, rows = {
    { keys = { "m" }, shown = "M", what = "the orbit map" },
    { keys = { "o" }, shown = "O", what = "hide the objectives card" },
    { keys = { "/" }, shown = "/", what = "the next objective: the contract, a milestone, a suit pack to recover  ·  or ◂ ▸ on the card" },
    { keys = { "escape" }, shown = "ESC", what = "back out of whatever is in front of you" },
    { keys = {}, shown = "RIGHT CLICK", what = "tap (don't drag) on your crew, a part of a craft or a crate: what you can do with it  ·  pad Y at the crosshair" },
  } },
  { group = "Flying", col = 2, rows = {
    { keys = { "shift", "ctrl" }, shown = "SHIFT / CTRL", what = "throttle up / down" },
    { keys = { "z", "x" }, shown = "Z  /  X", what = "full throttle  /  cut" },
    { keys = { "w", "a", "s", "d" }, shown = "W A S D", what = "pitch and yaw" },
    { keys = { "q", "e" }, shown = "Q  /  E", what = "roll" },
    { keys = { "h", "j", "k", "l", "i", "n" }, shown = "H J K L I N", what = "RCS translation" },
    { keys = { "space" }, shown = "SPACE", what = "next stage  ·  release the launch clamps" },
    { keys = { "t", "alt" }, shown = "T  ·  ALT 1–9", what = "SAS on / off  ·  pick a hold" },
    { keys = { "g", "u", "y", "b" }, shown = "G  U  Y  B", what = "gear  ·  deploy (panels, antennas)  ·  lights  ·  brakes" },
    { keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }, shown = "1 … 0", what = "your action groups (builder, tool 5)" },
    { keys = { "backspace" }, shown = "⌫", what = "abort: cut the throttle, fire the Abort group" },
    { keys = { "r" }, shown = "R", what = "RCS thrusters" },
    { keys = { "[", "]" }, shown = "[  /  ]", what = "switch to the next craft nearby, or the crew" },
    { keys = { "p" }, shown = "P", what = "peripherals and docking console" },
    { keys = { ",", "." }, shown = ",  /  .", what = "time warp down / up" },
    { keys = { "v" }, shown = "V", what = "first person in the seat  ·  V again: the next crew seat, then out" },
    { keys = { "c" }, shown = "C", what = "camera: auto  ·  free orbit  ·  chase  ·  horizon" },
    { keys = { "home" }, shown = "MIDDLE DRAG  ·  HOME", what = "slide the view's pivot over the craft  ·  back to its middle" },
    { keys = { "alt" }, shown = "ALT + SCROLL", what = "slide the pivot along the craft" },
    { keys = { "f" }, shown = "F", what = "get out and stand on the ground" },
    { keys = { "enter" }, shown = "⏎", what = "end the flight, once down and stopped" },
  } },
  { group = "Crew", col = 2, rows = {
    { keys = { "`" }, shown = "`", what = "quick swap: back to the craft or crew member you had before" },
    { keys = { "[", "]" }, shown = "[  /  ]", what = "step through the crew on foot nearby and the craft" },
    { keys = { "f" }, shown = "F", what = "flying: the commander steps out  ·  on foot: board the nearest free seat" },
    { keys = {}, shown = "PORTRAIT", what = "hover a crew portrait (bottom left): EVA steps them out, ⇄ moves them to a free seat; SHIFT-click EVA keeps you on the craft" },
    -- (keys: the source spelling crew_strip polls, `"\\"`, as smoke_pause reads it)
    { keys = { "\\\\" }, shown = "\\", what = "crew portraits: small  ·  large  ·  hidden" },
  } },
  { group = "Orbit map", col = 3, rows = {
    { keys = {}, shown = "RIGHT DRAG", what = "orbit the view  ·  with CTRL, pan" },
    { keys = { "up", "down" }, shown = "SCROLL  ↑ ↓", what = "zoom" },
    { keys = { "tab" }, shown = "TAB", what = "focus the next world" },
    { keys = { "1", "2", "3", "4" }, shown = "1  2  3  4", what = "orbits  ·  SOI rings  ·  labels  ·  comms links" },
    { keys = { "n" }, shown = "N", what = "plan a burn (in flight)  ·  N again to fly" },
    { keys = { "w", "s", "a", "d", "q", "e" }, shown = "W S  A D  Q E", what = "in plan: prograde  ·  radial  ·  normal" },
    { keys = { "left", "right" }, shown = "← →", what = "in plan: slide the burn along the orbit" },
    { keys = { "x", "backspace" }, shown = "X  /  ⌫", what = "in plan: zero the burn  /  delete it" },
  } },
  { group = "Pictures", col = 3, rows = {
    { keys = { "f4" }, shown = "F4", what = "hide the interface (cinematic mode)" },
    { keys = { "f5" }, shown = "F5", what = "free camera  ·  W A S D, SPACE / CTRL, SHIFT, SCROLL speed" },
    { keys = { "f6" }, shown = "F6", what = "photo orbit: circle slowly round the craft or crew" },
    { keys = { "t" }, shown = "T", what = "in the free camera: freeze time" },
    { keys = { "f12" }, shown = "F12", what = "screenshot, to the screenshots folder" },
  } },
  { group = "Builder", col = 3, rows = {
    { keys = {}, shown = "CLICK", what = "select a part, or add one" },
    { keys = {}, shown = "1  2  3  4  5", what = "move  ·  rotate  ·  stage  ·  grab  ·  action groups" },
    { keys = { "r", "t", "y" }, shown = "R  T  Y", what = "turn the held part" },
    { keys = { "x" }, shown = "X", what = "symmetry" },
    { keys = { "g" }, shown = "G", what = "move the whole ship" },
    { keys = { "del" }, shown = "DEL", what = "scrap the selected part" },
    { keys = { "ctrl", "z", "s" }, shown = "CTRL Z  /  S", what = "undo  /  save the blueprint" },
    { keys = {}, shown = "RMB + W A S D", what = "fly the view" },
  } },
}

function controlsTable() return CONTROLS end

-- ── the Esc ladder ──────────────────────────────────────────────────────────
--
-- One place, in order, so that a single press can never be answered twice. Each
-- of these already owns Esc while it is up; this menu is the last rung, and it
-- only opens when every rung above it is empty.
local function something_else_is_up()
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return true end
  local ip = ref("inventory_panel")
  if ip and ip.open then return true end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  local pp = ref("peripheral_panel")
  if pp and pp.isOpen and pp.isOpen() then return true end
  -- A right-click menu is a rung too: Esc backs out of it (context_menu.lua).
  local cm = ref("context_menu")
  if cm and cm.isOpen and (cm.isOpen() or cm.escTakenAt == time) then return true end
  -- First person is a level too: the first Esc puts you back on the shoulder,
  -- the second opens this. Backing out one thing at a time is the whole
  -- convention, and skipping a rung is how a menu ambushes you.
  -- So is the pilot's seat (V while flying): Esc leaves it first.
  local pc = ref("planet_camera")
  if pc and (pc.firstPerson or pc.cockpit) then return true end
  -- Cinematic mode and the free camera (F4 / F5): Esc leaves them first,
  -- and an Esc they took this frame was theirs.
  if pc and (pc.cinematic or pc.escTakenAt == time) then return true end
  -- A panel that shut on THIS frame's Esc before we ran: it is closed now, but
  -- the press was its, not ours. (Otherwise leaving the depot on Esc opened the
  -- pause menu underneath whenever the depot's script happened to run first.)
  for _, panel in ipairs({ fm, ob, ip, pp }) do
    if panel and panel.escTakenAt == time then return true end
  end
  return false
end

local function set_paused(on)
  if on == paused_by_us then return end
  paused_by_us = on
  if physics and physics.pause then physics.pause(on) end
end

function close()
  open, page = false, "menu"
  if el then el.visible = false end
  set_paused(false)
  -- The dim behind this menu is facility_menu's scrim, which it re-syncs on
  -- its own update — but not while the VAB builder has the screen, and
  -- Revert to the builder hands it the screen in this same click: the scrim
  -- stayed over the whole builder ("it's darker, as if a fade never
  -- finished", playtest 2026-10-27). Lifted here, the moment the menu goes.
  local fm = ref("facility_menu")
  if fm and fm.sync_scrim then pcall(fm.sync_scrim) end
end

function openMenu()
  open, page = true, "menu"
  if el then el.visible = true end
  set_paused(true)
end

-- ── the card ────────────────────────────────────────────────────────────────
--
-- Sizes are the styles' (ui/solar.uistyle.ron). Anything that can wrap is
-- "fit" tall, so it grows by the lines it wraps to.

local M = 16                                  -- screen margin
local PAD = 18                                -- the frame's pad
local NARROW_W = 460                          -- the menu and settings pages
local KEY_W = 112                              -- the key column on the controls page
local COLS = 3                                 -- the controls page's columns

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return uiDesignH() * w / h end
  end
  return 1280 * uiDesignH() / 720
end

-- The armed danger key (panel/danger `selected`): red fill, a light edge on
-- the frame, ink legend.
local ARMED_FILL = { 0.62, 0.15, 0.10, 1.0 }
local ARMED_EDGE = { 1.0, 0.8, 0.7, 1.0 }
local ARMED_TEXT = { 0.92, 0.89, 0.81, 1.0 }

local function row_button(key, text, onClicked)
  return { "button", key = key, style = "panel/row", w = "100%", h = 36,
           textAlign = "center", text = text, onClicked = onClicked }
end

local function heading(text)
  return { "text", key = "title", style = "panel/heading", w = "100%", h = "fit", text = text }
end

local function rule(key)
  return { "box", key = key or "rule", style = "panel/rule", w = "100%", h = 1 }
end

local function hint(text)
  return { "text", key = "hint", style = "panel/hint", w = "100%", h = "fit",
           wrap = true, text = text }
end

local function menu_page()
  local mgr = ref("game_manager")
  local rows = {
    heading("PAUSED"),
    rule(),
    row_button("resume", "Resume", function() close() end),
    row_button("settings", "Settings", function() page = "settings" end),
    row_button("controls", "Controls", function() page = "controls" end),
  }
  -- REVERT (KSP's): back to the launch, or to the builder, while the flight is
  -- still the one you launched (vessel_spawner owns the snapshot, the
  -- freshness rule and the two-click confirm). The armed row is the danger key.
  local vs = ref("vessel_spawner")
  local rq = vs and vs.revertQuote and vs.revertQuote()
  if rq and rq.ok then
    local function revert_row(key, kind)
      local armed = vs.revertArmed and vs.revertArmed(kind)
      -- Armed, the key turns red (docs/ui-style.md, the danger button). Said
      -- inline as well as by `selected`: the style's hover fill outranks
      -- `selected`, and the pointer is on the row it has just clicked, so
      -- the red never showed. Unarmed, the lines go and the style is back.
      return { "button", key = key, style = armed and "panel/danger" or "panel/row", selected = armed or nil,
               fill = armed and ARMED_FILL or nil, borderColor = armed and ARMED_EDGE or nil,
               textColor = armed and ARMED_TEXT or nil,
               w = "100%", h = 36, textAlign = "center", text = vs.revertLabel(kind),
               onClicked = function()
                 if vs.revertArmed(kind) then close() end
                 vs.revertClick(kind)
               end }
    end
    rows[#rows + 1] = revert_row("revert", "launch")
    if rq.builder then rows[#rows + 1] = revert_row("revertvab", "builder") end
  elseif rq and rq.why then
    rows[#rows + 1] = hint("Revert to launch is unavailable: " .. rq.why .. ".")
    rows[#rows].key = "revertwhy"
  end
  -- ABORT FLIGHT — the way home that is always there (flight_ops owns it: the
  -- fee, the two-click confirm, and leaving the craft on the fleet board).
  local fo = ref("flight_ops")
  local abort = fo and fo.abortLabel and fo.abortLabel()
  if abort then
    rows[#rows + 1] = row_button("abort", abort, function()
      if fo.abortClick() then close() end
    end)
  end
  -- Only when there is a slot to go back to. Playing straight out of the editor
  -- there is no main menu and nothing to save, which is exactly when a "Save and
  -- quit" button would be a button that lies.
  if save.slot and save.slot() ~= "main" then
    rows[#rows + 1] = row_button("menu", "Save and quit to the main menu",
      function()
        close()
        if mgr and mgr.exitToMenu then mgr.exitToMenu() end
      end)
  end
  rows[#rows + 1] = rule("rule2")
  rows[#rows + 1] = hint("The world is stopped while this is up.   Esc closes it.")
  return rows
end

-- One key and what it does. The description wraps inside its column and the
-- row takes the height of whichever side is taller.
local function control_row(key, r, desc_w)
  return { "row", key = key, w = "100%", h = "fit", gap = 10, pad = 0, align = "start",
    items = {
      -- Wraps rather than running under the description: "MIDDLE MOUSE or
      -- ALT" overflowed a fixed one-line key cell at every resolution.
      { "text", key = "k", style = "panel/keys", w = KEY_W, h = "fit", wrap = true, text = r.shown },
      { "text", key = "d", style = "panel/body", w = desc_w, h = "fit", wrap = true, text = r.what },
    }, function(x) return x end }
end

-- The controls in three columns: walking and tools, flying, and the two
-- screens with keys of their own (the map and the builder). One column of
-- thirty rows was taller than the screen.
local function controls_page(w)
  local col_w = math.floor((w - PAD * 2 - 24 * (COLS - 1)) / COLS)
  local desc_w = col_w - KEY_W - 10
  local cols = {}
  for i = 1, COLS do cols[i] = {} end
  for gi, g in ipairs(CONTROLS) do
    local c = cols[math.min(COLS, g.col or 1)]
    if #c > 0 then c[#c + 1] = { "box", key = "sp" .. gi, w = 1, h = 6 } end
    c[#c + 1] = { "text", key = "g" .. gi, style = "panel/label", w = "100%", h = "fit",
                  text = g.group }
    for ri, r in ipairs(g.rows) do
      c[#c + 1] = control_row("g" .. gi .. "r" .. ri, r, desc_w)
    end
  end
  local function column(key, list)
    return { "col", key = key, w = col_w, h = "fit", gap = 5, pad = 0, align = "start",
             items = list, function(x) return x end }
  end
  return {
    heading("CONTROLS"),
    rule(),
    -- In a scroll: at a large interface size (Settings ▸ Display) the three
    -- columns are taller than the screen.
    { "scroll", key = "colsS", w = "100%", h = "fit", maxH = uiDesignH() - 2 * M - 150, gap = 0, pad = 0,
      dir = "col",
      { "row", key = "cols", w = "100%", h = "fit", gap = 24, pad = 0, align = "start",
        items = { column("c1", cols[1]), column("c2", cols[2]), column("c3", cols[3]) },
        function(x) return x end } },
    rule("rule2"),
    { "row", key = "foot", w = "100%", h = "fit", gap = 12, pad = 0, align = "center",
      items = {
        { "button", key = "back", style = "panel/secondary", w = 120, h = 32,
          textAlign = "center", text = "Back", onClicked = function() page = "menu" end },
        { "text", key = "hint", style = "panel/hint", w = "grow", h = "fit",
          text = "Esc goes back." },
      }, function(x) return x end },
  }
end

-- SETTINGS: settings.lua describes the whole screen (display, camera, controls, audio,
-- accessibility — the same rows the main menu shows); this frames it. Without
-- a settings node in the scene it falls back to the graphics level alone.
local SETTINGS_W = 580

local function back_to_menu()
  local st = ref("settings")
  if st and st.flush then st.flush() end
  page = "menu"
end

local function settings_page(w)
  local st = ref("settings")
  local rows = { heading("SETTINGS"), rule() }
  if st and st.rows then
    for _, r in ipairs(st.rows(w)) do rows[#rows + 1] = r end
  else
    local gx = ref("graphics")
    rows[#rows + 1] = { "text", key = "gl", style = "panel/label", w = "100%", h = "fit",
                        text = "Graphics quality" }
    if gx and gx.LEVELS then
      local cur = gx.level()
      local opts = {}
      for _, name in ipairs(gx.LEVELS) do
        opts[#opts + 1] = { "button", key = name, style = "panel/choice", w = "grow", h = 34,
          textAlign = "center", selected = (name == cur), text = name,
          onClicked = function() gx.set(name) end }
      end
      rows[#rows + 1] = { "row", key = "levels", w = "100%", h = "fit", gap = 6, pad = 0,
                          items = opts, function(x) return x end }
      rows[#rows + 1] = { "text", key = "desc", style = "panel/body", w = "100%",
                          h = "fit", wrap = true, text = gx.describe(cur) or "" }
    end
  end
  rows[#rows + 1] = rule("rule2")
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = "fit", gap = 12, pad = 0, align = "center",
    items = {
      { "button", key = "back", style = "panel/secondary", w = 120, h = 32,
        textAlign = "center", text = "Back", onClicked = back_to_menu },
      { "text", key = "hint", style = "panel/hint", w = "grow", h = "fit",
        text = "Esc goes back." },
    }, function(x) return x end }
  return rows
end

local function page_width()
  if page == "controls" then return math.min(1200, design_width() - M * 2) end
  if page == "settings" then return math.min(SETTINGS_W, design_width() - M * 2) end
  return NARROW_W
end

local function describe(w)
  local rows
  if page == "controls" then rows = controls_page(w)
  elseif page == "settings" then rows = settings_page(w)
  else rows = menu_page() end
  -- (The world behind is dimmed by facility_menu's scrim, which every
  -- reading panel shares.)
  return { "col", key = "pause", style = "panel/frame", w = "100%",
           dir = "col", gap = 8, pad = PAD, align = "start",
           items = rows, function(row) return row end }
end

-- Published for the UI probe and anything else that wants a page open.
function showPage(name)
  if name == "controls" or name == "settings" or name == "menu" then page = name end
end

-- ── the notice toast ────────────────────────────────────────────────────────
--
-- graphics.lua lowers the quality on its own when frames run long, and says so
-- in `notice`. It used to be a card in the middle of the screen with a warning
-- sign on it for eight seconds, which read as an error the player had caused.
-- It is a footnote: one line, top right beside the ☰ button, for a few
-- seconds — the first sentence only (Settings is where the rest lives).
local TOAST_TIME, TOAST_W, TOAST_H = 5.0, 450, 28
local MENU_BTN_W = 112          -- the ☰ button this sits to the left of
local toast_n, toast_el

local function toast()
  if not toast_n or toast_n.valid == false then
    toast_n = find and find("Notice Toast") or nil
    toast_el = toast_n and toast_n:getcomponent("UiElement") or nil
  end
  if not toast_el then return end
  local gx = ref("graphics")
  local note = gx and gx.notice
  local up = type(note) == "string" and note ~= "" and (time - (gx.noticeAt or -1e9)) < TOAST_TIME
  if toast_el.visible ~= up then toast_el.visible = up end
  if not up then return end
  -- The node is pinned bottom-centre in the scene; placed from there.
  local x = design_width() / 2 - M - MENU_BTN_W - 10 - TOAST_W / 2
  local y = -(uiDesignH() - M - TOAST_H)
  if toast_el.posX ~= x then toast_el.posX = x end
  if toast_el.posY ~= y then toast_el.posY = y end
  if toast_el.width ~= TOAST_W then toast_el.width = TOAST_W end
  local short = note:match("^(.-%.)%s") or note
  ui.make(toast_n, { "row", key = "toast", style = "hud/toast", w = "100%", h = TOAST_H,
    pad = 8, gap = 0, align = "center",
    items = {
      { "text", key = "t", style = "panel/cellMuted", w = "grow", h = "fit",
        textSize = 12, textAlign = "end", text = short },
    }, function(x) return x end })
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
  open, page, paused_by_us = false, "menu", false
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local mgr = ref("game_manager")
  -- Not while the world is streaming in: there is nothing to pause yet, and a
  -- menu over a loading screen is a menu you cannot leave.
  -- Nor while the VAB builder has the keys: its Esc backs out of its own
  -- levels and never pauses (LEAVE is a button there).
  if mgr and (mgr.loading or mgr.inputOwner == "builder") then
    if open then close() end
    return
  end

  toast()

  -- (an Esc that calls off a rebind on the Controls tab is the rebind's)
  local st = open and page == "settings" and ref("settings") or nil
  if input.pressed("escape") and not (st and st.rebinding and st.rebinding()) then
    if open then
      -- Esc backs out of a page first, then out of the menu.
      if page ~= "menu" then page = "menu" else close() end
    elseif not something_else_is_up() then
      openMenu()
    end
  end

  if not open then return end
  -- The pointer belongs to the menu while the menu is up. planet_camera asks
  -- `open` and stands down, so nothing is fighting over this.
  input.setMouseLocked(false)
  local w = page_width()
  if el and el.width ~= w then el.width = w end
  ui.make(node, describe(w))
end
