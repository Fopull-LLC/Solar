-- One SAVE-SLOT button on the main menu. Shows what lives in the slot (the
-- seed of a started galaxy, or "empty"); clicking an OCCUPIED slot enters the
-- game (game_manager takes it from there — loading screen, regeneration from
-- the slot's seed + creation parameters, saved-position restore); clicking an
-- EMPTY slot opens the NEW GALAXY panel (menu_newsave) to pick the seed and
-- generation parameters first.
--
-- An occupied slot is the AGENCY's card: its emblem (a small one built by
-- scripts/emblem.lua from the slot's own spec), its name, and the galaxy it
-- flies in. A save from before agencies reads as the Solar Exploration
-- Agency, as it will once loaded.

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

local EMBLEM_X, TEXT_X, TEXT_X0 = 10, 68, 18

local function shift(n, x, w)
  local e = n and n.getcomponent and n:getcomponent("UiElement")
  if e then
    if e.posX ~= x then e.posX = x end
    if w and e.width ~= w then e.width = w end
  end
end

-- Peek at several keys of a slot in one switch.
local function peek_all(slot, keys)
  local cur = save.slot()
  save.slot(slot)
  local out = {}
  for _, k in ipairs(keys) do out[k] = save.get(k) end
  save.slot(cur)
  return out
end

local function emblem_lib()
  local e = findScript and findScript("emblem")
  if not e and spawn then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
  return e
end

local shown = nil   -- the emblem texture on the card (nil: none yet)

-- THE AGENCY'S NAME ON THE CARD fits the 200 units between the emblem and
-- CONTINUE (QA 2026-10-26: "Solar Exploration Agency" at 18 ran right up to
-- CONTINUE, and a longer name ran under it). The slot font is about 0.46 of
-- its size a letter, in design units (measured: 24 letters at 18 span 205):
-- the largest of SIZES that fits, and past the smallest the name is cut with
-- an ellipsis (the new-save field takes 32 letters, which fit at 12). Each size is a style (ui/solar.uistyle.ron
-- "menu/slotName", "menu/slotName15" …): the style sets the text size, so an
-- element's own textSize would not hold. Globals for the tests.
-- → text, size, style
NAME_W, NAME_SIZE, CHAR_W = 196, 18, 0.46
SIZES = { 18, 15, 12 }
SIZE_MIN = SIZES[#SIZES]
local function style_of(size) return size == 18 and "menu/slotName" or ("menu/slotName" .. size) end
function fitName(s)
  s = tostring(s or "")
  local n = utf8 and utf8.len and utf8.len(s) or #s
  if not n or n < 1 then return s, NAME_SIZE, style_of(NAME_SIZE) end
  for _, size in ipairs(SIZES) do
    if n * CHAR_W * size <= NAME_W then return s, size, style_of(size) end
  end
  local keep = math.max(1, math.floor(NAME_W / (CHAR_W * SIZE_MIN)) - 1)
  -- (cut on a character, not a byte: names may carry accents)
  local cut = s
  if utf8 and utf8.offset then
    local b = utf8.offset(s, keep + 1)
    if b then cut = s:sub(1, b - 1) end
  else
    cut = s:sub(1, keep)
  end
  return (cut:gsub("%s+$", "")) .. "…", SIZE_MIN, style_of(SIZE_MIN)
end

local function refresh(node)
  local n = math.floor(params.slot)
  local v = peek_all("slot" .. n, { "g_seed", "agency.name", "agency.emblem" })
  local seed = v.g_seed
  local used = seed ~= nil -- the same test menu_delete shows the ✕ on
  local agency = (type(v["agency.name"]) == "string" and v["agency.name"] ~= "") and v["agency.name"] or nil
  local tex = nil
  if used then
    local e = emblem_lib()
    if e and e.smallTex then
      local ok, t = pcall(e.smallTex, "slot" .. n, agency or (e.DEFAULT_NAME or "Solar Exploration Agency"), v["agency.emblem"])
      if ok then tex = t end
    end
  end
  if name then
    local txt, size, style = "Empty", NAME_SIZE, "menu/slotName"
    if used then txt, size, style = fitName(agency or "Solar Exploration Agency") end
    name.text = txt
    if name.style ~= style then name.style = style end
  end
  if go then go.text = used and "CONTINUE  ▸" or "NEW GALAXY  +" end
  if tag then tag.text = used and string.format("SLOT %d  ·  GALAXY %d", n, seed) or string.format("SLOT %d", n) end
  if el then el.width = used and W_WITH_DELETE or W_FULL end
  local x = used and TEXT_X or TEXT_X0
  shift(tag, x, nil)
  shift(name, x, used and 200 or 290)
  if me and ui and ui.make then
    shown = tex
    pcall(ui.make, me, used and {
      { "image", key = "emblem", pin = "left", x = EMBLEM_X, w = 48, h = 48,
        texture = tex or "textures/parts/emblem_default.png", imageFit = "contain" },
    } or {})
  end
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

-- The emblem is built a frame after the library arrives: try again until
-- the card wears it.
local retry_t = 0
function update(node, dt)
  if shown ~= nil then return end
  retry_t = retry_t + (dt or 0)
  if retry_t < 0.25 then return end
  retry_t = 0
  local n = math.floor(params.slot)
  if peek("slot" .. n, "g_seed") ~= nil then refresh(node) else shown = false end
end
