-- INPUT_GUARD — while a text field has the keyboard, the game hears none of
-- it (playtest 11-09: "typing in the build search bar opens the inventory,
-- jumps, and picks the parts I picked before").
--
-- Every script reads the shared `input` table, raw keys (input.key /
-- pressed / released) and actions (input.action / justPressed / axis2 …)
-- alike. The step-7 fix asked each reader whether a "Field…" node had focus,
-- and the readers that forgot (the inventory's Tab, the jump action, the
-- belt's Q and R, the kit's number keys and M, B, G, X, R, T…) still fired.
-- This guard is the one place: on start it wraps the shared table's readers
-- once, and while a text field is focused (ui.focused(): a node named
-- "Field…", the project's rule for its fields) they answer as if nothing
-- were pressed:
--   * every key but Escape (it drops the field, closes the panel) and Enter
--     (the field's own submit);
--   * every keyboard action (Jump, Interact, Sprint, Crouch, Move, Fly,
--     Turn, ShiftLock, Context …); the mouse's (Look, LookEnable, LookFree,
--     Zoom, Fire) and Pause still answer;
--   * input.typed is already empty while a field has focus (the engine's).
-- The focus is read once a frame (time moves), not once a call.
--
-- A script that must read a key while typing calls input.rawKey / rawPressed
-- / rawReleased (the unwrapped readers). Probes drive keys through
-- input.simulate, which the guard sees the same way.
--
-- On the Build Kit node (scenes/system.ron) and the builder's scene
-- (scenes/builder.ron); installed once per `input` table (the flag rides on
-- it), so a scene reload or a second node changes nothing.
--
-- A PANEL MAY HOLD THE KEYBOARD the same way (a console's terminal: the crew
-- stands at the desk and its 1–9, Tab and arrows are the screen's, not the
-- belt's or the walker's): hold(owner, true) while it is up, hold(owner,
-- false) when it closes. While anything holds it the game hears no keys but
-- Escape and Enter, exactly as for a focused field; the holder reads its own
-- keys with input.rawKey / rawPressed and a pad with input.padButton.
--
-- Probes / tests: typing(), held(), hold(owner, on), PASS_KEYS, PASS_ACTIONS, install(tbl).

PASS_KEYS = { escape = true, enter = true }
PASS_ACTIONS = { Pause = true, Look = true, LookEnable = true, LookFree = true, Zoom = true, Fire = true }

-- owner → true: the panels holding the keyboard. Kept ON the shared input
-- table (like the install flag), so the wrappers a previous scene installed
-- and this script's hold() always mean the same set.
local function holds(tbl)
  tbl = tbl or input
  if type(tbl) ~= "table" then return {} end
  local h = rawget(tbl, "__hold")
  if not h then h = {}; rawset(tbl, "__hold", h) end
  return h
end
function hold(owner, on, tbl)
  if owner == nil then return end
  holds(tbl)[owner] = on and true or nil
end
function held(tbl) return next(holds(tbl)) ~= nil end

local seen_t, seen = nil, false
-- Is a text field focused now? (once a frame)
function typing()
  local t = time
  if t ~= nil and t == seen_t then return seen end
  seen_t = t
  local f = nil
  if ui and ui.focused then
    local ok, r = pcall(ui.focused)
    if ok then f = r end
  end
  local nm = nil
  if f ~= nil then
    local ok, n = pcall(function() return f.name end)
    nm = ok and n or nil
  end
  seen = type(nm) == "string" and nm:sub(1, 5) == "Field"
  return seen
end
-- (a test steps the frame without `time`)
function forget() seen_t = nil end

-- Wrap `tbl`'s readers (the shared `input`). → true if it wrapped them now
function install(tbl)
  tbl = tbl or input
  if type(tbl) ~= "table" or rawget(tbl, "__guarded") then return false end
  local H = holds(tbl)
  local function key_wrap(f)
    if type(f) ~= "function" then return f end
    return function(k, ...)
      if (typing() or next(H) ~= nil) and not PASS_KEYS[k] then return false end
      return f(k, ...)
    end
  end
  local function act_wrap(f, none)
    if type(f) ~= "function" then return f end
    return function(n, ...)
      if (typing() or next(H) ~= nil) and not PASS_ACTIONS[n] then return none() end
      return f(n, ...)
    end
  end
  local function no() return false end
  local function zero() return 0 end
  local function zero2() return 0, 0 end
  tbl.rawKey, tbl.rawPressed, tbl.rawReleased = tbl.key, tbl.pressed, tbl.released
  tbl.key = key_wrap(tbl.key)
  tbl.pressed = key_wrap(tbl.pressed)
  tbl.released = key_wrap(tbl.released)
  tbl.action = act_wrap(tbl.action, no)
  tbl.justPressed = act_wrap(tbl.justPressed, no)
  tbl.justReleased = act_wrap(tbl.justReleased, no)
  tbl.heldSecs = act_wrap(tbl.heldSecs, zero)
  tbl.axis1 = act_wrap(tbl.axis1, zero)
  tbl.axis2 = act_wrap(tbl.axis2, zero2)
  tbl.buffered = act_wrap(tbl.buffered, no)
  tbl.consume = act_wrap(tbl.consume, no)
  -- A field's "submitted" that SPACE fired, not Enter (the engine's UI nav
  -- fallback counts Space as submit even in a focused text field: a space
  -- typed in the part search picked the first card and dropped the focus, so
  -- the next letters drove the game — playtest 11-09's "selects previously
  -- selected parts", then the inventory and the jump). → true: ignore it
  -- (the field keeps the focus).
  tbl.spaceSubmit = function(node)
    local raw_key, raw_pressed = tbl.rawKey, tbl.rawPressed
    local sp = (raw_key and raw_key("space")) or (raw_pressed and raw_pressed("space"))
    local en = (raw_key and raw_key("enter")) or (raw_pressed and raw_pressed("enter"))
    if sp and not en then
      if node and ui and ui.focus then pcall(ui.focus, node) end
      return true
    end
    return false
  end
  rawset(tbl, "__guarded", true)
  return true
end

function start(node)
  install(input)
  -- (a new scene: nothing holds the keyboard any more)
  local h = holds(input)
  for k in pairs(h) do h[k] = nil end
end
