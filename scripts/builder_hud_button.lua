-- SAVE / LAUNCH / LEAVE buttons in the builder HUD (the scene's SaveBtn,
-- LaunchBtn and LeaveBtn). `params.action`:
--   1 = save the blueprint
--   2 = save + buy the hull + roll out to the pad
--   3 = save and go back to the base, having bought nothing
--
-- The toolbar (builder_toolbar.lua, docs/builder-design.md §4.4) carries all
-- three now, so while it is in the scene these keys stand down and hide; they
-- stay working for a scene without it.

defaults = { action = 1 }

local builder, toolbar
local HOVER = {
  "save the blueprint   ·   CTRL+S",
  "buy the hull and roll it out to the pad   ·   the cost is in the header",
  "leave the Vehicle Assembly   ·   keeps the blueprint, buys nothing",
}

local function b()
  if not builder or builder.valid == false then builder = findScript("builder") end
  return builder
end

local checked = false
function update(node, dt)
  if checked then return end
  checked = true
  toolbar = findScript and findScript("builder_toolbar") or nil
  if toolbar then
    local el = node:getcomponent("UiElement")
    if el then el.visible = false end
  end
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
  if bb and bb.hint and line then bb.hint(line, 3.0) end
end
