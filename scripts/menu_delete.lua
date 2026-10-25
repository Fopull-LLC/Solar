-- The ✕ button beside a save slot: deletes that save FROM DISK — both stores,
-- paired (save.deleteSlot wipes the key→value file, terrain.deleteSaveDir the
-- slot's persisted terrain) — so the slot is immediately reusable. Two-click
-- confirm: the first click arms it ("sure?" — the "menu/delete" style's
-- `selected` state paints it red); it disarms by itself.
-- Hidden while the slot is empty (nothing to delete).

defaults = { slot = 1 }

local el, me
local armed_until = 0

-- Since floptle 0.117.0-rc22 (card 0524) terrain.deleteSaveDir called from a
-- scene with no terrain deletes the ACTIVE slot's folder and releases it; an
-- older engine refuses the active one and has to be told terrain.saveDir("")
-- first. (The same test as flora_field's engine_at_least.)
local function engine_at_least(maj, min, pat, rc)
  local v = app and app.version and app.version()
  if type(v) ~= "string" then return false end
  local a, b, c, r = v:match("^(%d+)%.(%d+)%.(%d+)%-rc(%d+)")
  if not a then a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)") end
  if not a then return false end
  local have = { tonumber(a), tonumber(b), tonumber(c), r and tonumber(r) or math.huge }
  local want = { maj, min, pat, rc or math.huge }
  for i = 1, 4 do
    if have[i] ~= want[i] then return have[i] > want[i] end
  end
  return true
end
SAVEDIR_RELEASES_ITSELF = engine_at_least(0, 117, 0, 22)

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
    -- Straight after ☰ MENU the slot just played is still terrain's ACTIVE
    -- saveDir (scene.load has finished its writes). Since floptle 0.117.0-rc22
    -- (card 0524) deleteSaveDir from a scene with no terrain — this menu —
    -- deletes that folder and releases it itself (terrain.saveDir() reads nil
    -- after; measured: 2 files removed, the folder gone). An older engine
    -- refuses the active one, so there it is let go of first.
    local tdir = "saves/" .. slot_name() .. "/terrain"
    if not SAVEDIR_RELEASES_ITSELF and terrain.saveDir and terrain.saveDir() == tdir then terrain.saveDir("") end
    terrain.deleteSaveDir(tdir)
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
