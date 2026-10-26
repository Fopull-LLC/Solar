-- SMOKE: the builder never keeps the cursor (playtest 2026-10-26: "the vab
-- frequently steals my mouse making it unmovable or invisible").
--
-- builder_camera.lua owns the mouse lock while the builder is up and asserts
-- its wish every frame: locked ONLY during an RMB fly-look whose button is
-- still down. Driven here through its real update() with a scripted input:
--
--   * a lock inherited from the on-foot first-person look is let go on the
--     builder's first frame;
--   * a plain RMB orbit drag and an RMB tap (the context menu) never lock;
--   * RMB + W flies, locked; released over a panel → free;
--   * alt-tab mid-fly (the engine zeroes the buttons while unfocused) → free;
--   * a text field taking focus mid-fly → free, the drag dropped;
--   * the builder going away (onDestroy) and releaseCursor() → free;
--   * build_host.lua lets go on enter and on teardown.
--
--   luajit solar/tests/smoke_builder_cursor.lua   (from the Floptle repo root)

local failures, checks = {}, 0
local function check(c, what) checks = checks + 1; if not c then failures[#failures + 1] = what end end

local I = { buttons = {}, keys = {}, mx = 400, my = 300, dx = 0, dy = 0, hovered = false, focused = nil }
local locks = {}
local env = setmetatable({}, { __index = _G })
env.params = { look = 0.0032, speed = 8.0, wheel = 1.2 }
env.time = 0
env.findScript = function() return nil end
env.ui = { hovered = function() return I.hovered end, focused = function() return I.focused end }
env.input = {
  mouse = function() return I.mx, I.my end,
  mouse_delta = function() return I.dx, I.dy end,
  button = function(b) return I.buttons[b] == true end,
  key = function(k) return I.keys[k] == true end,
  pressed = function() return false end,
  scroll = function() return 0 end,
  setMouseLocked = function(on) locks[#locks + 1] = on end,
  lockMouse = function() locks[#locks + 1] = true end,
  unlockMouse = function() locks[#locks + 1] = false end,
}
env.camera = { screenSize = function() return 1920, 1080 end,
               screenToRay = function() return 0, 4, 14, 0, -0.2, -1 end }
local f = assert(loadfile("solar/scripts/builder_camera.lua"))
setfenv(f, env)
f()
local C = env
local node = { getcomponent = function() return nil end }
C.start(node)
local function frame(n)
  for _ = 1, n or 1 do
    env.time = env.time + 1 / 60
    C.update(node, 1 / 60)
  end
end
local function last() return locks[#locks] end

-- 1. the first-person lock came in with the player: the first frame frees it
locks[#locks + 1] = true
frame()
check(last() == false, "the builder's first frame lets go of an inherited lock")
local n0 = #locks
frame(3)
check(#locks == n0 + 3, "the wish is asserted every frame (" .. (#locks - n0) .. " of 3)")

-- 2. an RMB tap: the context menu, never a lock
local seq = C.rmbClick.seq
I.buttons[1] = true; frame()
I.buttons[1] = false; frame()
check(C.rmbClick.seq == seq + 1, "an RMB tap is published for the context menu")
check(last() == false and not C.mouseLocked, "an RMB tap never locks")

-- 3. a plain RMB orbit drag: the cursor stays (orbit reads the deltas)
I.buttons[1] = true; frame()
I.mx, I.dx = I.mx + 40, 40; frame(); I.dx = 0
frame(5)
check(last() == false, "an RMB orbit drag does not lock")
I.buttons[1] = false; frame()
check(last() == false, "after the orbit: free")

-- 4. RMB + W: fly, locked while the button is down; released over a panel → free
local function fly()
  I.buttons[1] = true; frame()
  I.keys.w = true; frame(); frame()
end
fly()
check(last() == true and C.mouseLocked, "RMB + W flies with the mouse locked")
I.hovered = true
I.buttons[1] = false; I.keys.w = false; frame()
check(last() == false and not C.mouseLocked, "RMB released over a panel: free")
I.hovered = false
frame(2)
check(last() == false, "and it stays free")

-- 5. alt-tab mid-fly: the engine zeroes the mouse buttons while unfocused
fly()
check(last() == true, "flying again: locked")
I.buttons[1] = false; frame()   -- the window lost focus: no buttons reach the game
I.keys.w = false; frame()
check(last() == false, "alt-tab mid-fly: free")
-- back in: the W key still held from before must not re-lock without RMB
I.keys.w = true; frame(3); I.keys.w = false
check(last() == false, "W alone (no RMB) never locks")

-- 6. a text field takes focus mid-fly → free, and the drag is dropped
fly()
I.focused = { name = "FieldSearch" }; frame()
check(last() == false, "a text field taking focus mid-fly: free")
I.focused = nil
frame()
check(last() == false, "after typing, the still-held RMB + W does not fly again without a new press")
I.buttons[1] = false; I.keys.w = false; frame()
check(last() == false, "released after typing: free")

-- 6b. RMB pressed over a panel, then dragged into the view: no drag, no lock
I.hovered = true; I.buttons[1] = true; frame()
I.hovered = false; I.keys.w = true; I.mx = I.mx + 50; frame(3)
check(last() == false, "an RMB pressed over a panel and dragged out never locks")
I.buttons[1] = false; I.keys.w = false; frame()

-- 7. the builder goes away mid-fly → free
fly()
check(last() == true, "flying: locked")
C.onDestroy(node)
check(last() == false, "onDestroy lets go")
fly()
C.releaseCursor()
check(last() == false, "releaseCursor lets go")
I.buttons[1] = false; I.keys.w = false; frame()

-- 8. the pure rule
check(C.cursorWant({ fly = true }, true, false) == true, "want: fly + RMB")
check(C.cursorWant({ fly = true }, false, false) == false, "want: RMB up")
check(C.cursorWant({ fly = false }, true, false) == false, "want: orbit, not fly")
check(C.cursorWant(nil, true, false) == false, "want: no drag")
check(C.cursorWant({ fly = true }, true, true) == false, "want: typing")

-- 9. build_host lets go on enter and on teardown (source check: the engine
-- half of build_host is not stubbable here)
local bh = io.open("solar/scripts/build_host.lua"):read("*a")
local enter = bh:match("function enter%(%).-\nend")
local teardown = bh:match("local function teardown%(.-\nend")
check(enter and enter:find("setMouseLocked%(false%)") ~= nil, "build_host.enter frees the cursor")
check(teardown and teardown:find("setMouseLocked%(false%)") ~= nil, "build_host teardown frees the cursor")
-- and nothing in the builder uses the raw lockMouse any more (it bypassed the per-frame wish)
for _, k in ipairs({ "builder", "builder_camera", "build_host", "catalog_panel", "builder_context",
                     "builder_toolbar", "builder_inspector", "builder_statusbar" }) do
  local src = io.open("solar/scripts/" .. k .. ".lua"):read("*a")
  check(not src:find("input%.lockMouse%("), k .. ".lua does not call input.lockMouse")
end

if #failures > 0 then
  print(("smoke_builder_cursor: %d/%d FAILED"):format(#failures, checks))
  for _, m in ipairs(failures) do print("  FAIL " .. m) end
  os.exit(1)
end
print(("smoke_builder_cursor: all %d checks passed"):format(checks))
