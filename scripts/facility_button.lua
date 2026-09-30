-- A button inside the facilities panel. `params.action`: 1 = the context action
-- (Open Builder / Ops Board / Sell…), 2 = close the panel. Routes into
-- facility_menu.
--
-- The look is a style ("panel/action" / "panel/secondary", set by
-- facility_menu), hover and press included; this only routes the click.

defaults = { action = 1 }

local menu

function clicked(node)
  if not menu or not menu.valid then menu = findScript("facility_menu") end
  if not menu then return end
  local a = math.floor(params.action)
  if a == 1 and menu.action then menu.action() end
  if a == 2 and menu.close then menu.close() end
end
