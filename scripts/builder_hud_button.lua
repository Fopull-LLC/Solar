-- SAVE / LAUNCH / LEAVE buttons in the builder HUD. `params.action`:
--   1 = save the blueprint
--   2 = save + buy the hull + roll out to the pad
--   3 = save and go back to the base, having bought nothing
--
-- Hover and press looks come from the buttons' styles ("menu/secondary",
-- "menu/primary"); hovering puts what the button does on the hint line,
-- which is where the labels' longer explanations live.

defaults = { action = 1 }

local builder

local HOVER = {
  "save the blueprint   ·   CTRL+S",
  "buy the hull and roll it out to the pad   ·   the cost is in the header",
  "leave the Assembly   ·   keeps the blueprint, buys nothing   ·   ESC",
}

local function b()
  if not builder or not builder.valid then builder = findScript("builder") end
  return builder
end

function clicked(node)
  local bb = b()
  if not bb then return end
  local a = math.floor(params.action)
  if a == 1 and bb.doSave then bb.doSave() end
  if a == 2 and bb.doLaunch then bb.doLaunch() end
  if a == 3 and bb.doLeave then bb.doLeave() end
end

function hoverStart(node)
  local bb = b()
  local line = HOVER[math.floor(params.action)]
  if bb and bb.hintNow and line then bb.hintNow(line, 3.0) end
end
