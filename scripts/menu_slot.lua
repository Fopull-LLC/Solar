-- One SAVE-SLOT button on the main menu. Shows what lives in the slot (the
-- seed of a started galaxy, or "empty"); clicking an OCCUPIED slot enters the
-- game (game_manager takes it from there — loading screen, regeneration from
-- the slot's seed + creation parameters, saved-position restore); clicking an
-- EMPTY slot opens the NEW GALAXY panel (menu_newsave) to pick the seed and
-- generation parameters first.

defaults = { slot = 1 }

local el, me
local tag, name, go -- the slot's three labels (children, looked up by name)

-- Peek at another slot's store without losing the current one: save.slot()
-- switches the active store (flushing first), so read and switch back.
local function peek(name, key)
  local cur = save.slot()
  save.slot(name)
  local v = save.get(key)
  save.slot(cur)
  return v
end

-- An occupied slot leaves room on its right for the ✕ beside it (menu.ron
-- lays the card out as 412 + 8 + 52); an empty one spans the whole row, so a
-- hidden ✕ never leaves a hole.
local W_FULL, W_WITH_DELETE = 472, 412

local function refresh(node)
  local n = math.floor(params.slot)
  local seed = peek("slot" .. n, "g_seed")
  local used = seed ~= nil -- the same test menu_delete shows the ✕ on
  if name then name.text = used and string.format("Galaxy %d", seed) or "Empty" end
  if go then go.text = used and "CONTINUE  ▸" or "NEW GALAXY  +" end
  if tag then tag.text = string.format("SLOT %d", n) end
  if el then el.width = used and W_WITH_DELETE or W_FULL end
end

function start(node)
  el = node:getcomponent("UiElement")
  me = node
  local n = math.floor(params.slot)
  tag = find(string.format("Slot %d Tag", n))
  name = find(string.format("Slot %d Name", n))
  go = find(string.format("Slot %d Go", n))
  refresh(node)
end

function clicked(node)
  local fx = findScript("sfx")
  if fx then fx.play("click") end
  local name = "slot" .. math.floor(params.slot)
  if peek(name, "g_seed") then
    save.slot(name)
    scene.load("system")
  else
    local panel = findScript("menu_newsave")
    if panel then panel.openFor(math.floor(params.slot)) end
  end
end

-- menu_delete calls this (node:getscript handle) after wiping the slot so the
-- label flips back to "empty" without a scene reload. Hover/press looks are
-- the "menu/slot" style's.
function relabel()
  if me then refresh(me) end
end
