-- SMOKE: the HUD's ☰ MENU · ESC button (scripts/menu_button.lua) — shown in
-- play, hidden while loading, under the pause menu it opens, and in the VAB
-- builder, whose toolbar runs to the same corner (QA 2026-10-26: the button
-- sat on the builder's LAUNCH).
--
--   luajit solar/tests/smoke_menu_button.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end

local gm = { valid = true, loading = false, inputOwner = nil }
local pm = { valid = true, open = false }
_G.findScript = function(k)
  if k == "game_manager" then return gm end
  if k == "pause_menu" then return pm end
  return nil
end
local el = { visible = false }
local node = { getcomponent = function(_, k) if k == "UiElement" then return el end end }

assert(loadfile("solar/scripts/menu_button.lua"))()
start(node)

update(node, 1 / 60)
check(el.visible == true, "shown in play")
gm.loading = true; update(node, 1 / 60)
check(el.visible == false, "hidden while the world loads")
gm.loading = false; pm.open = true; update(node, 1 / 60)
check(el.visible == false, "hidden under the pause menu")
pm.open = false; gm.inputOwner = "builder"; update(node, 1 / 60)
check(el.visible == false, "hidden in the VAB builder (its toolbar owns the corner)")
gm.inputOwner = nil; update(node, 1 / 60)
check(el.visible == true, "back when the builder is left")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_menu_button OK — %d checks", passed))
