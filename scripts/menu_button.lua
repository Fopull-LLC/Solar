-- The HUD's ☰ button. It opens the PAUSE MENU, which is where quitting lives now
-- along with the controls — and it wears the key that does the same thing, so a
-- player who clicks it once knows Esc from then on. An affordance whose only job
-- is to teach itself out of existence is a good affordance.
--
-- It used to quit straight to the main menu with no confirmation and no pause,
-- one stray click from the end of your session, and it was pinned to the same
-- corner as the objectives card — drawn straight over its title.
--
-- Hidden during direct editor play (no slot active — nothing to save, nowhere to
-- go back to).

local el, mgr

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The look, hover included, is the "hud/button" style (ui/solar.uistyle.ron);
-- it used to be a fill recomputed in Lua on every hover.
function start(node)
  el = node:getcomponent("UiElement")
  node.style = "hud/button"
end

function update(node, dt)
  if not el then return end
  if not mgr then mgr = ref("game_manager") end
  -- Shown in direct editor play too, which it never used to be: it opened a
  -- main menu that was not there, and now it opens the controls, which are
  -- exactly as useful whether or not there is a save slot behind you.
  --
  -- Not over the menu it opens.
  local pm = ref("pause_menu")
  local show = (mgr and not mgr.loading and not (pm and pm.open)) or false
  el.visible = show
end

function clicked(node)
  local fx = ref("sfx")
  if fx then fx.play("click") end
  local pm = ref("pause_menu")
  if pm and pm.openMenu then pm.openMenu() end
end
