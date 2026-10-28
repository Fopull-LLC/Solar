-- QUITPROBE: does an EXPORTED build close when the player quits?
-- (tools/perf/quitprobe.sh; engine card 0564; menu_ng_button.lua "quit",
-- pause_menu.lua quitToDesktop). Rides in the build's own menu scene.
--   mode "title": a real click (input.simulate) on the title page's Quit.
--   mode "pause": CONTINUE on slot 1 (a copy), ESC, then a real click on
--                 "Save and quit to desktop" (or its handler if the row
--                 can't be found on screen).
-- `QP` lines carry the wall clock; the runner times the process's exit
-- against the CLICK line. After the click it keeps saying it is alive, so a
-- build that does not exit shows whether its scripts still run.
defaults = { mode = "title" }
local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("QP %7.2f " .. fmt, W() - W0, ...)) end
local CO
local function yield() coroutine.yield() end
local function hold(s) local t = W() + s; while W() < t do yield() end end
local function wait_for(fn, tmo) local t = W() + tmo; while W() < t do local r = fn(); if r then return r end; yield() end end

local function click_node(n, what)
  local x, y, w, h = n:uiRect()
  if not x then P("%s: no rect", what) return false end
  local cx, cy = x + w / 2, y + h / 2
  input.simulate { mouse = { cx, cy } }; yield(); yield(); yield()
  P("CLICK %s at (%.0f, %.0f) rect %.0fx%.0f", what, cx, cy, w, h)
  input.simulate { button = 0, down = true }; yield(); yield()
  input.simulate { button = 0, down = false }
  -- did the button fire? (ui.clicked polls this frame's events)
  local fired = false
  for _ = 1, 6 do yield(); if ui and ui.clicked and ui.clicked(n) then fired = true end end
  P("%s fired clicked: %s", what, tostring(fired))
  return true
end

local function find_key(root, key, depth)
  if not root or depth > 12 then return nil end
  for _, c in ipairs(root.children or {}) do
    if c.name == key then return c end
    local r = find_key(c, key, depth + 1)
    if r then return r end
  end
  return nil
end

local function main(node)
  node.persistent = true
  local mode = params.mode or "title"
  P("mode %s", mode)
  if mode == "title" then
    local q = wait_for(function() local n = find("Menu Quit"); return n and n:uiRect() and n end, 60)
    P("title ready %s", tostring(q ~= nil))
    hold(2)
    if q then click_node(q, "Menu Quit") end
  else
    save.slot("slot1")
    scene.load("system")
    yield()
    local ok = wait_for(function()
      local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
      return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
    end, 200)
    P("world ready %s", tostring(ok ~= nil))
    hold(3)
    input.simulate { key = "escape", down = true }; yield(); yield()
    input.simulate { key = "escape", down = false }
    hold(1.5)
    local pm = findScript("pause_menu")
    P("pause menu open %s", tostring(pm and pm.isOpen and pm.isOpen()))
    local row = find("desktop") or (pm and find_key(pm.node, "desktop", 0))
    if not (row and click_node(row, "Save and quit to desktop")) then
      P("CLICK quitToDesktop() (the row's handler; no rect)")
      if pm and pm.close then pm.close() end
      if pm and pm.quitToDesktop then pm.quitToDesktop() end
    end
  end
  for k = 1, 10 do hold(0.5); P("alive %.1f s after the click", k * 0.5) end
  -- still here: the button's own handler, called directly…
  if mode == "title" then
    for _, s in ipairs(findScripts("menu_ng_button") or {}) do
      if s.params and s.params.role == "quit" and s.clicked then
        P("CALL menu_ng_button.clicked (role quit) directly")
        s.clicked(s.node)
      end
    end
  end
  for k = 1, 6 do hold(0.5); P("alive %.1f s after the direct call", k * 0.5) end
  -- …and app.quit() itself
  P("CALL app.quit() directly (app.quit is %s)", type(app and app.quit))
  app.quit()
  for k = 1, 20 do hold(0.5); P("alive %.1f s after app.quit()", k * 0.5) end
  P("STILL RUNNING 10 s after app.quit()")
end

function start(node)
  CO = coroutine.create(main)
end

function update(node, dt)
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO, node)
    if not ok then P("ERROR %s", tostring(err)); CO = nil end
  end
end
