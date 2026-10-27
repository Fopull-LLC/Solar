-- NEW GALAXY panel (attached to the "NG Panel" node): shown when the player
-- clicks an EMPTY save slot. Every system-generator knob is exposed on a
-- draggable slider inside the "NG Params" box (all eleven fit on the page;
-- it stays a scroll view so a twelfth knob would scroll rather than spill),
-- plus a galaxy seed typed on the keyboard (digits; backspace erases;
-- blank = random; ESC backs out). CREATE stores the whole parameter set in
-- the fresh slot and enters the game — game_manager reads it back and hands
-- it to the generator, so the same save always regenerates the same galaxy. The
-- panel's buttons carry menu_ng_button, which routes clicks here (press).
--
-- YOUR AGENCY (docs/crew-and-items.md §2.5): the panel grows a column on the
-- right, built here with ui.make, where the player names the agency and sees
-- its emblem generated from the name as they type — regenerate it, step its
-- shape, motif, colours and letters, repaint any of its four colours, or use
-- a picture of their own (scripts/emblem.lua's editor). Nothing there has to
-- be touched: a new save made straight away is the "Solar Exploration
-- Agency" under a finished emblem. Two switches sit under it:
--   GAME MODE    Career (today's rules) / Sandbox (unlimited funds, top
--                reputation, every part unlocked: company.lua, `game.mode`)
--   CREW SAFETY  Permadeath / Rescue / Invincible (crew.lua's `crew.safety`)

open = false -- published: menu_slot opens the panel, buttons check it

-- One row per generator knob: the scroll-view node names, the slot key it
-- saves under, the generator opt it overrides, and how its value reads.
local PARAMS = {
  { node = "NG Planets",  save = "g_planets",    opt = "planets",    fmt = "int" },
  { node = "NG Moons",    save = "g_moonchance", opt = "moonChance", fmt = "pct" },
  { node = "NG Atmo",     save = "g_atmo",       opt = "atmoChance", fmt = "pct" },
  { node = "NG Caves",    save = "g_caves",      opt = "caveScale",  fmt = "x" },
  { node = "NG MinOrbit", save = "g_minorbit",   opt = "minOrbit",   fmt = "int" },
  { node = "NG Spacing",  save = "g_spacing",    opt = "spacing",    fmt = "x" },
  { node = "NG RadMin",   save = "g_radmin",     opt = "radiusMin",  fmt = "int" },
  { node = "NG RadMax",   save = "g_radmax",     opt = "radiusMax",  fmt = "int" },
  { node = "NG GravMin",  save = "g_gravmin",    opt = "gravityMin", fmt = "g" },
  { node = "NG GravMax",  save = "g_gravmax",    opt = "gravityMax", fmt = "g" },
  { node = "NG Star",     save = "g_star",       opt = "starScale",  fmt = "x" },
}

-- The world scale a new save is created at — system_generator's CURRENT_SCALE
-- (the menu scene has no generator to ask). Bump the two together.
WORLD_SCALE = 4

local slot_n = 1
local seed_str = ""

-- The agency column.
local AG_X, AG_W, PANEL_W, GAL_W = 604, 336, 960, 600
local ed = nil             -- scripts/emblem.lua's editor state
local mode = "career"      -- GAME MODE: "career" | "sandbox"
local safety = "death"     -- CREW SAFETY: "death" | "rescue" | "invincible"

local MODES = {
  { "career", "Career", "Earn every dollar and build a name: contracts, research and standing gate the way up" },
  { "sandbox", "Sandbox", "Unlimited funds, top reputation and every part unlocked; contracts still run" },
}
local SAFETIES = {
  { "death", "Permadeath", "Astronauts can be lost: every danger is warned of first, and the roster keeps a memorial" },
  { "rescue", "Rescue", "A crew member who would die is brought home instead, for a fee" },
  { "invincible", "Invincible", "Nothing hurts the crew: no falls, shots, crushes, heat or running out of air" },
}
local function blurb(list, v)
  for _, o in ipairs(list) do if o[1] == v then return o[3] end end
  return ""
end
-- For probes: what CREATE will store, and a way to pick (as the buttons do).
function options() return mode, safety end
function setOptions(m, s)
  if m == "career" or m == "sandbox" then mode = m end
  if s == "death" or s == "rescue" or s == "invincible" then safety = s end
end
local panel_node = nil

local function emblem_lib()
  local e = findScript and findScript("emblem")
  if not e and spawn then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
  return e
end

local function sfx(key)
  local f = findScript and findScript("sfx")
  if f and f.play then f.play(key) end
end

-- What the new save will be called and wear (for probes and the create).
function agency()
  local e = emblem_lib()
  if not (e and ed) then return nil end
  return e.editorResult(ed)
end
function editor() return ed end

local function ui_of(name)
  local n = find(name)
  return n, n and n:getcomponent("UiElement")
end

local function slider_of(p)
  local n = find(p.node .. " Track")
  local s = n and n:getcomponent("UiSlider")
  return s and s.value
end

local function value_of(p)
  local v = slider_of(p)
  if not v then return nil end
  if p.fmt == "int" then v = math.floor(v + 0.5) end
  return v
end

local function seed_label()
  local n = find("NG Seed")
  if not n then return end
  if #seed_str > 0 then
    n.text = "SEED   " .. seed_str
  else
    n.text = "SEED   random"
  end
end

-- The two panels sit centered in the same layer: exactly ONE is ever visible.
-- Hiding a panel's root prunes its whole subtree from layout + hit-testing,
-- so the swap is a clean page turn, never an overlay.
local function show(panel_open)
  local _, ng = ui_of("NG Panel")
  if ng then ng.visible = panel_open end
  local _, main = ui_of("Menu Panel")
  if main then main.visible = not panel_open end
end

function openFor(n)
  slot_n = n
  seed_str = ""
  open = true
  mode, safety = "career", "death"
  local e = emblem_lib()
  ed = e and e.newEditor and e.newEditor(nil, nil) or nil
  local lbl = find("NG Slot Label")
  if lbl then lbl.text = string.format("SAVE SLOT %d", n) end
  seed_label()
  local _, sc = ui_of("NG Params")
  if sc then sc.scrollY = 0 end
  show(true)
end

local function close()
  open = false
  show(false)
  if panel_node then pcall(ui.make, panel_node, {}) end
end

-- Button router (menu_ng_button forwards its role here).
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

function press(role)
  if role == "cancel" then
    close()
  elseif role == "seed" then
    seed_str = "" -- click the seed row to clear back to random
    seed_label()
  elseif role == "create" then
    -- A NEW galaxy must never inherit terrain files from whatever lived in
    -- this slot before (same terrain ids, different worlds — a stale file
    -- would stream in as the "wrong planet"). Straight after ☰ MENU the slot
    -- just played is still terrain's ACTIVE saveDir. Since floptle
    -- 0.117.0-rc22 (card 0524) deleteSaveDir from this terrainless menu
    -- deletes and releases it itself; an older engine refuses the active one,
    -- so there it is let go of first (game_manager sets it again on entry).
    local tdir = "saves/slot" .. slot_n .. "/terrain"
    if not SAVEDIR_RELEASES_ITSELF and terrain.saveDir and terrain.saveDir() == tdir then terrain.saveDir("") end
    terrain.deleteSaveDir(tdir)
    save.slot("slot" .. slot_n)
    local v = {}
    for _, p in ipairs(PARAMS) do v[p.save] = value_of(p) end
    -- A min above its max would corrupt the generator's ranges — the max wins
    -- up to the min (silently: the sliders still show what was dragged).
    if v.g_radmax and v.g_radmin and v.g_radmax < v.g_radmin then v.g_radmax = v.g_radmin end
    if v.g_gravmax and v.g_gravmin and v.g_gravmax < v.g_gravmin then v.g_gravmax = v.g_gravmin end
    for _, p in ipairs(PARAMS) do
      if v[p.save] then save.set(p.save, v[p.save]) end
    end
    if #seed_str > 0 then save.set("g_seed", tonumber(seed_str)) end
    -- The agency: its name and the emblem's spec (never its pixels).
    local e = emblem_lib()
    local aname, aspec = nil, nil
    if e and ed then aname, aspec = e.editorResult(ed) end
    if aname then
      save.set("agency.name", aname)
      save.set("agency.emblem", aspec)
    end
    save.set("game.mode", mode)
    save.set("crew.safety", safety)
    save.set("crew.death", safety == "death")
    -- A new galaxy is made at the CURRENT world scale, and keeps it for life
    -- (system_generator SCALES; game_manager reads it back). The sliders above
    -- are already in that scale's units.
    save.set("g_scale", WORLD_SCALE)
    scene.load("system")
  end
end

-- The agency column, described.
local function describe_agency(e)
  local rows = e.editorRows(ed, AG_W, sfx)
  rows[#rows + 1] = { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 }
  -- a labelled segmented choice and, under it, one line on what is picked
  local function pick(key, text, list, cur, set)
    local row = { "row", key = key, w = "100%", h = 28, gap = 6, pad = 0, align = "center",
      { "text", key = "l", style = "panel/label", w = 74, h = "fit", text = text } }
    for _, o in ipairs(list) do
      row[#row + 1] = { "button", key = o[1], style = "panel/choice", w = "grow", h = 26, text = o[2],
        selected = (o[1] == cur), textAlign = "center", textValign = "center", tooltip = o[3],
        onClicked = function() if o[1] ~= cur then sfx("click") end; set(o[1]) end }
    end
    rows[#rows + 1] = row
    rows[#rows + 1] = { "text", key = key .. "_h", style = "panel/hint", w = "100%", h = "fit", wrap = true,
                        text = blurb(list, cur) }
  end
  pick("mode", "Mode", MODES, mode, function(v) mode = v end)
  pick("safety", "Crew", SAFETIES, safety, function(v) safety = v end)
  return {
    { "box", key = "vr", pin = "topLeft", x = GAL_W - 2, y = 24, w = 1, h = 564, style = "panel/rule" },
    { "col", key = "agency", pin = "topLeft", x = AG_X, y = 22, w = AG_W, h = "fit", gap = 7, pad = 0,
      align = "start", items = rows, function(x) return x end },
  }
end

-- The panel grows to hold the agency column; the galaxy half keeps its place.
local function widen(node)
  local _, ng = ui_of("NG Panel")
  if ng and ng.width ~= PANEL_W then ng.width = PANEL_W end
  -- (the title, slot label and seed hint are GAL_W wide in the scene: they
  -- stay centred over the galaxy half, clear of the agency column)
end

local function name_focused()
  local f = ui and ui.focused and ui.focused()
  return f ~= nil and f.name == "FieldAgencyName"
end

function update(node, dt)
  if not open then return end
  panel_node = node
  local e = emblem_lib()
  if e and not ed and e.newEditor then ed = e.newEditor(nil, nil) end
  if e and ed then
    widen(node)
    e.editorTick(ed)
    ui.make(node, describe_agency(e))
  end
  local typing = name_focused()
  -- Seed entry: bare digit keys type into the seed (unless the agency's
  -- name field has the keyboard). 9 digits max keeps seeds in the
  -- generator's range.
  for d = 0, 9 do
    if not typing and input.pressed(tostring(d)) and #seed_str < 9 then
      seed_str = seed_str .. d
      seed_label()
    end
  end
  if input.pressed("escape") then
    if typing and ui.focus then ui.focus(nil) return end
    close()
    return
  end
  if not typing and input.pressed("backspace") and #seed_str > 0 then
    seed_str = seed_str:sub(1, -2)
    seed_label()
  end
  -- Live value readouts beside each slider.
  for _, p in ipairs(PARAMS) do
    local v = slider_of(p)
    local out = find(p.node .. " Val")
    if v and out then
      if p.fmt == "int" then
        out.text = string.format("%d", math.floor(v + 0.5))
      elseif p.fmt == "pct" then
        out.text = string.format("%d%%", math.floor(v * 100 + 0.5))
      elseif p.fmt == "g" then
        out.text = string.format("%.1f", v)
      else -- "x"
        out.text = string.format("×%.2f", v)
      end
    end
  end
end
