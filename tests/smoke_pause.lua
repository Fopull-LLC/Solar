-- SMOKE HARNESS: Esc, the pause menu, and the controls card.
--
-- Two things are being held down here.
--
-- THE ESC LADDER. Esc has five consumers in this project and had no order. The
-- failure this prevents is the one that makes a game feel unfinished: a single
-- press answered twice, so backing out of the depot also opened the pause menu,
-- or leaving first person also closed the bag. Each rung is exclusive, and this
-- drives every rung.
--
-- THE CONTROLS CARD IS TRUE. The card lists every key the game has, and a card
-- that advertises a key nothing reads is worse than no card — it is the game
-- telling you to press G and then ignoring you. So every key named on it is
-- checked against what the scripts actually poll, straight out of the sources.
--
--   luajit solar/tests/smoke_pause.lua

local T, TICK = 0.0, 1 / 60
local API = {}

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine ──────────────────────────────────────────────────────────────────
local presses = {}
local mouse_locked = true
API.input = {
  key = function() return false end,
  pressed = function(k) return presses[k] == true end,
  button = function() return false end,
  setMouseLocked = function(v) mouse_locked = v end,
}
local sim_paused = false
API.physics = {
  pause = function(on) sim_paused = on end,
  isPaused = function() return sim_paused end,
}
local slot = "save1"
API.save = { get = function() return nil end, set = function() end,
             slot = function() return slot end }
API.log = function() end

local drawn = nil
API.ui = { make = function(_, tree) drawn = tree end }

-- Every text and button the card is showing, flattened.
local function lines()
  local out = {}
  local function walk(t)
    if type(t) ~= "table" then return end
    if t.text then out[#out + 1] = tostring(t.text) end
    for _, item in ipairs(t.items or {}) do
      -- `items` + a passthrough builder: the builder is the last positional
      -- entry, so run it to get the row it would draw.
      local build = t[1] and t[#t]
      if type(build) == "function" then walk(build(item)) else walk(item) end
    end
  end
  walk(drawn)
  return out
end
local function says(needle)
  for _, l in ipairs(lines()) do if l:find(needle, 1, true) then return true end end
  return false
end
-- The button with this label, so the test clicks what a player clicks.
local function button(needle)
  local found = nil
  local function walk(t)
    if type(t) ~= "table" or found then return end
    if t[1] == "button" and tostring(t.text or ""):find(needle, 1, true) then
      found = t
      return
    end
    for _, item in ipairs(t.items or {}) do
      local build = t[1] and t[#t]
      if type(build) == "function" then walk(build(item)) else walk(item) end
    end
  end
  walk(drawn)
  return found
end

-- ── the other rungs of the ladder ───────────────────────────────────────────
local fac_open, ops_open, bag_open, map_open, periph_open, first_person = false, false, false, false, false, false
local exited = false
local envs = {}
envs.facility_menu   = { isOpen = function() return fac_open end, node = { valid = true } }
envs.ops_board       = { isOpen = function() return ops_open end, node = { valid = true } }
envs.inventory_panel = { open = false, node = { valid = true } }
envs.orbit_map       = { isOpen = function() return map_open end, node = { valid = true } }
envs.peripheral_panel = { isOpen = function() return periph_open end, node = { valid = true } }
envs.planet_camera   = { firstPerson = false, node = { valid = true } }
envs.game_manager    = { loading = false, exitToMenu = function() exited = true end,
                         node = { valid = true } }
API.findScript = function(kind) return envs[kind] end
API.findScripts = function(kind) return envs[kind] and { envs[kind] } or {} end

local NODE = { name = "Pause Menu", valid = true, els = {} }
function NODE:getcomponent(k)
  if k ~= "UiElement" then return nil end
  self.els.ui = self.els.ui or { visible = true }
  return self.els.ui
end

local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  return env
end

local pause = load_script("solar/scripts/pause_menu.lua", "pause_menu")
pause.start(NODE)

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    pause.update(NODE, TICK)
    presses = {}
  end
end
local function esc() presses["escape"] = true end

-- ── 1. THE WORLD STOPS ──────────────────────────────────────────────────────
ok(pause.open == false, "the menu starts closed")
ok(sim_paused == false, "...and the world is running")

esc(); tick(1)
ok(pause.open == true, "Esc opens the menu")
-- `physics.pause` has existed since the sim controls landed and this project had
-- never called it. A "pause menu" that leaves your rocket falling while you read
-- is not a pause menu.
ok(sim_paused == true, "...and the world actually stops")
ok(mouse_locked == false, "...and the pointer comes back")
ok(says("PAUSED"), "...and it says so: " .. table.concat(lines(), " | "))

esc(); tick(1)
ok(pause.open == false, "Esc closes it again")
ok(sim_paused == false, "...and the world starts")

-- ── 2. THE ESC LADDER ───────────────────────────────────────────────────────
-- Each of these owns Esc while it is up. The menu is the LAST rung and must not
-- open on a press something else has already answered — the bug being prevented
-- is walking out of the depot and finding the pause menu underneath it.
local rungs = {
  { "a facility panel", function(v) fac_open = v end },
  { "the ops board", function(v) ops_open = v end },
  { "the suit pack", function(v) envs.inventory_panel.open = v end },
  { "the orbit map", function(v) map_open = v end },
  { "the peripherals console", function(v) periph_open = v end },
  { "first person", function(v) envs.planet_camera.firstPerson = v end },
}
for _, r in ipairs(rungs) do
  -- Explicitly closed before each rung. Without this the loop passes for the
  -- wrong reason: a rung that wrongly OPENED the menu leaves it open, and the
  -- next rung's Esc closes it again — so a broken ladder reads as half a pass,
  -- alternating. (It did. That is why this line is here.)
  pause.close()
  tick(1)
  r[2](true)
  esc(); tick(1)
  ok(pause.open == false, "the menu does not open on the Esc that leaves " .. r[1])
  r[2](false)
  tick(1)
end
-- The same rungs when THEY run first: the panel has already shut on this Esc
-- by the time the pause menu looks, so "is anything open?" says no. The panel
-- publishes the frame it spent the Esc on, and that frame's Esc is not ours.
for _, kind in ipairs({ "facility_menu", "ops_board" }) do
  pause.close()
  tick(1)
  envs[kind].escTakenAt = T + TICK   -- closed on the frame about to run
  esc(); tick(1)
  ok(pause.open == false, "the menu does not open on the Esc " .. kind .. " already closed on")
  envs[kind].escTakenAt = nil
end
pause.close()
tick(1)
esc(); tick(1)
ok(pause.open == true, "...and it does open when nothing else is in front of you")

-- ── 3. THE CONTROLS PAGE ────────────────────────────────────────────────────
local b = button("Controls")
ok(b ~= nil, "the menu has a Controls button")
if b then b.onClicked() end
tick(1)
ok(says("CONTROLS"), "clicking it opens the controls page")
ok(says("W A S D"), "...which names how to walk")
ok(says("first person"), "...and how to get to first person, which nothing else says")
ok(says("harvest cutter"), "...and what the number keys are")
ok(says("TAB"), "...and how to open the bag")

-- Esc backs out of the page before it backs out of the menu. One level at a
-- time is the whole convention; skipping one is how a menu feels like it is
-- getting away from you.
esc(); tick(1)
ok(pause.open == true and says("PAUSED"),
  "Esc leaves the controls page without closing the menu")
esc(); tick(1)
ok(pause.open == false, "...and the next one closes the menu")

-- ── 4. QUITTING ─────────────────────────────────────────────────────────────
esc(); tick(1)
local q = button("main menu")
ok(q ~= nil, "there is a way back to the main menu")
if q then q.onClicked() end
tick(1)
ok(exited, "...and it takes it")
ok(sim_paused == false, "...leaving the sim un-paused, not frozen for the next scene")

-- Playing straight out of the editor there is no slot and nowhere to go back
-- to, and a button that lies is worse than a button that is missing.
slot = "main"
esc(); tick(1)
ok(button("main menu") == nil, "no quit button when there is no save slot to quit to")
slot = "save1"
pause.close()
tick(1)

-- ── 5. LOADING ──────────────────────────────────────────────────────────────
-- Nothing to pause yet, and a menu over a loading screen is a menu you cannot
-- leave.
envs.game_manager.loading = true
esc(); tick(1)
ok(pause.open == false, "the menu does not open while the world is streaming in")
envs.game_manager.loading = false

-- ── 6. THE CARD IS TRUE ─────────────────────────────────────────────────────
-- Every key the controls page advertises, against every key the scripts poll.
-- This is the check that stops the card rotting into a list of lies.
local polled = {}
do
  local p = assert(io.popen("cat solar/scripts/*.lua 2>/dev/null"))
  local src = p:read("*a")
  p:close()
  for k in src:gmatch('input%.key%("([^"]*)"%)') do polled[k] = true end
  for k in src:gmatch('input%.pressed%("([^"]*)"%)') do polled[k] = true end
  -- Keys held in a table and polled through a variable — the SAS ladder's
  -- `SAS_KEYS`, and the peripherals' `key = "g"` device registry — are read as
  -- `input.pressed(k)`, so they have to be gathered from where they are DEFINED.
  for k in src:gmatch('%["([1-9])"%]%s*=%s*"') do polled[k] = true end
  -- A table FIELD — `key = "g", label = "GEAR"` — hence the trailing comma. The
  -- looser `key%s*=%s*"(%a)"` also matched `local key = "v" .. node.id`, a
  -- save-key prefix in the vessel controller, which quietly made `v` a bound key
  -- and let this whole lint pass a card that advertised one.
  for k in src:gmatch('[^%w_]key%s*=%s*"([a-z])",') do polled[k] = true end
end
ok(polled["w"] and polled["escape"], "found the keys the scripts poll")

local missing = {}
for _, g in ipairs(pause.controlsTable()) do
  for _, r in ipairs(g.rows) do
    for _, k in ipairs(r.keys) do
      if not polled[k] then
        missing[#missing + 1] = string.format("%s / %s → `%s`", g.group, r.shown, k)
      end
    end
  end
end
ok(#missing == 0, "every key on the controls card is a key some script reads: "
  .. table.concat(missing, ", "))

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("PAUSE SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("PAUSE SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
