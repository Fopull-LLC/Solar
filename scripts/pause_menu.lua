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
-- SETTINGS holds the graphics quality (graphics.lua), and this script also
-- shows graphics.lua's `notice` as a toast when the game lowers it by itself.

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
  { group = "On foot", rows = {
    { keys = { "w", "a", "s", "d" }, shown = "W A S D", what = "walk" },
    { keys = { "shift" }, shown = "SHIFT", what = "hold to sprint" },
    { keys = { "space" }, shown = "SPACE", what = "jump  ·  swim up in water" },
    { keys = { "ctrl" }, shown = "CTRL", what = "dive, in water" },
    { keys = {}, shown = "RIGHT MOUSE", what = "hold to look around" },
    { keys = { "alt" }, shown = "MIDDLE MOUSE  or  ALT", what = "keep the mouse looking without holding it" },
    { keys = {}, shown = "SCROLL", what = "zoom  ·  all the way in is first person" },
    { keys = { "e" }, shown = "E  or  ⏎", what = "enter the building you are standing at" },
  } },
  { group = "Tools", rows = {
    { keys = { "1", "2", "3" }, shown = "1  2  3", what = "mining laser  ·  harvest cutter  ·  terrain spade" },
    { keys = {}, shown = "LEFT MOUSE", what = "use the tool in your hand, on what the crosshair is over" },
    { keys = { "q" }, shown = "Q", what = "raise ground (the spade lowers it)" },
    { keys = { "tab", "i" }, shown = "TAB  or  I", what = "the suit pack" },
  } },
  { group = "Flying", rows = {
    { keys = { "shift", "ctrl" }, shown = "SHIFT / CTRL", what = "throttle up / down" },
    { keys = { "z", "x" }, shown = "Z  /  X", what = "full throttle  /  cut" },
    { keys = { "w", "a", "s", "d" }, shown = "W A S D", what = "pitch and yaw" },
    { keys = { "q", "e" }, shown = "Q  /  E", what = "roll" },
    { keys = { "h", "j", "k", "l", "i", "n" }, shown = "H J K L I N", what = "RCS translation" },
    { keys = { "space" }, shown = "SPACE", what = "fire the next stage  ·  release the launch clamps" },
    { keys = { "t" }, shown = "T", what = "SAS on / off  ·  1–9 pick a hold" },
    { keys = { "g" }, shown = "G", what = "landing gear" },
    { keys = { "r" }, shown = "R", what = "RCS thrusters" },
    { keys = { "u" }, shown = "U", what = "comms dish and solar panels" },
    { keys = { "p" }, shown = "P", what = "peripherals and docking console" },
    { keys = { ",", "." }, shown = ",  /  .", what = "time warp down / up" },
    { keys = { "f" }, shown = "F", what = "get out and stand on the ground" },
    { keys = { "enter" }, shown = "⏎", what = "end the flight, when you are down and stopped" },
  } },
  { group = "Everywhere", rows = {
    { keys = { "m" }, shown = "M", what = "the orbit map" },
    { keys = { "o" }, shown = "O", what = "hide the objectives card" },
    { keys = { "escape" }, shown = "ESC", what = "back out of whatever is in front of you" },
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
  -- First person is a level too: the first Esc puts you back on the shoulder,
  -- the second opens this. Backing out one thing at a time is the whole
  -- convention, and skipping a rung is how a menu ambushes you.
  local pc = ref("planet_camera")
  if pc and pc.firstPerson then return true end
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
local KEY_W = 118                              -- the key column on the controls page

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return 720 * w / h end
  end
  return 1280
end

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
      { "text", key = "k", style = "panel/keys", w = KEY_W, h = 18, text = r.shown },
      { "text", key = "d", style = "panel/body", w = desc_w, h = "fit", wrap = true, text = r.what },
    }, function(x) return x end }
end

-- The controls in two columns: on foot and tools on the left, flying and the
-- rest on the right. One column of thirty rows was taller than the screen.
local function controls_page(w)
  local col_w = math.floor((w - PAD * 2 - 24) / 2)
  local desc_w = col_w - KEY_W - 10
  local cols = { {}, {} }
  for gi, g in ipairs(CONTROLS) do
    local c = cols[(gi <= 2) and 1 or 2]
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
    { "row", key = "cols", w = "100%", h = "fit", gap = 24, pad = 0, align = "start",
      items = { column("c1", cols[1]), column("c2", cols[2]) }, function(x) return x end },
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

-- Graphics quality: four levels, the one in force lit, and what it means.
local function settings_page()
  local gx = ref("graphics")
  local rows = { heading("SETTINGS"), rule(),
    { "text", key = "gl", style = "panel/label", w = "100%", h = "fit", text = "Graphics quality" } }
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
    local d = gx.describe(cur) or ""
    rows[#rows + 1] = { "text", key = "desc", style = "panel/body", w = "100%",
                        h = "fit", wrap = true, text = d }
  else
    rows[#rows + 1] = { "text", key = "desc", style = "panel/body", w = "100%", h = "fit",
                        text = "Graphics settings are not available in this scene." }
  end
  rows[#rows + 1] = rule("rule2")
  rows[#rows + 1] = hint("Remembered across every save. If the game stutters it steps down one level on its own and says so.")
  rows[#rows + 1] = { "button", key = "back", style = "panel/secondary", w = 120, h = 32,
                      textAlign = "center", text = "Back", onClicked = function() page = "menu" end }
  return rows
end

local function page_width()
  if page == "controls" then return math.min(880, design_width() - M * 2) end
  return NARROW_W
end

local function describe(w)
  local rows
  if page == "controls" then rows = controls_page(w)
  elseif page == "settings" then rows = settings_page()
  else rows = menu_page() end
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
  local y = -(720 - M - TOAST_H)
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
  if mgr and mgr.loading then
    if open then close() end
    return
  end

  toast()

  if input.pressed("escape") then
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
