-- The ✕ button beside a save slot: deletes that save FROM DISK — both stores,
-- paired (save.deleteSlot wipes the key→value file, terrain.deleteSaveDir the
-- slot's persisted terrain) — so the slot is immediately reusable. Two-click
-- confirm: the first click arms it ("sure?" — the "menu/delete" style's
-- `selected` state paints it red); it disarms by itself.
-- Hidden while the slot is empty (nothing to delete).

defaults = { slot = 1 }

local el, me
local armed_until = 0

local function peek(name, key)
  local cur = save.slot()
  save.slot(name)
  local v = save.get(key)
  save.slot(cur)
  return v
end

local function slot_name()
  return "slot" .. math.floor(params.slot)
end

local function arm(on)
  if el then el.selected = on and 1 or 0 end
end

local function refresh(node)
  local occupied = peek(slot_name(), "g_seed") ~= nil
  if el then el.visible = occupied end
  node.text = "✕"
  armed_until = 0
  arm(false)
end

function start(node)
  el = node:getcomponent("UiElement")
  me = node
  refresh(node)
end

function clicked(node)
  local fx = findScript("sfx")
  if fx then fx.play(time < armed_until and "close" or "arm") end
  if time < armed_until then
    -- Confirmed: wipe both stores, relabel the slot button, hide ourselves.
    save.deleteSlot(slot_name())
    terrain.deleteSaveDir("saves/" .. slot_name() .. "/terrain")
    -- ...and the craft library's files (builder.lua keeps each craft in
    -- user://library/<slot>/, the save only its index).
    if assets and assets.getContents and assets.remove then
      local ok, list = pcall(assets.getContents, "user://library/" .. slot_name():gsub("[^%w_%-]", "_"))
      if ok and type(list) == "table" then
        for _, p in ipairs(list) do pcall(assets.remove, p) end
      end
    end
    local btn = find("Slot " .. math.floor(params.slot))
    if btn then
      local s = btn:getscript("menu_slot")
      if s then s.relabel() end
    end
    refresh(node)
    print(string.format("save %s deleted", slot_name()))
  else
    armed_until = time + 3.0
    node.text = "sure?"
    arm(true)
  end
end

function update(node, dt)
  if armed_until > 0 and time >= armed_until then
    armed_until = 0
    node.text = "✕"
    arm(false)
  end
end
