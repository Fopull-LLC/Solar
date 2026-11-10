-- SCENARIOS on the main menu (work/scenarios PLAN §1.8–1.9; docs/scenarios.md).
--
-- Rides the "Scenarios Row" node: the fourth row of the menu card, under the
-- three save slots, a CRT listing like theirs ("SCENARIOS · showcase
-- missions, a medal each", or "CONTINUE · Two Rooms · step 5/7" when the
-- scenario slot holds one in progress). Clicking it turns the page to the
-- SCENARIOS panel (the "Scenarios Panel" node, described here with ui.make),
-- the way the New Galaxy and Settings pages swap in for the title page:
--
--   the list    every scenario in scenarios/ (scenario.listAll): title,
--               what it teaches, par, and the best medal from
--               user://scenarios/profile.json. One locked behind another
--               scenario's medal is greyed with "after Flag Day".
--   the detail  its picture (scenarios/<id>/card.png), title, what it
--               teaches, the blurb, the best run, and PLAY · RESET.
--   CONTINUE    bottom left, when slot `scn` holds an unfinished run.
--
--   ↑ ↓         move through the rows (they are focusable; focus selects)
--   Enter       on a row: to its PLAY key; on a key: press it
--   Esc         disarm a "sure?" key, then back to the title page
--
-- PLAY writes the scenario's world into slot `scn` (scenario.prepareSlot: wipe
-- the slot and its terrain, write the generator's g_* keys and g_scenario)
-- and loads the system. Never a career slot: the slot name is the
-- rulebook's SLOT constant, and the career rows never list it. Replacing an
-- unfinished run asks first (the key arms, a second press acts), and so does
-- RESET, which clears the scenario's profile entry.

open = false        -- published: the other menu pages leave Esc alone while up

local SLOT_FALLBACK = "scn"
PANEL_W, PANEL_H = 960, 600
local LIST_W, SIDE_W = 494, 376   -- 494 + 20 + 1 + 20 + 376 = 911 inside the 916 the frame leaves
PIC_W, PIC_H = 376, 212   -- 384 × 216 pictures, drawn at the column's width

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function sfx(key) local f = ref("sfx"); if f and f.play then f.play(key) end end

-- ── the rulebook (scripts/scenario.lua, pure) ───────────────────────────────
-- In the game it rides the ScenarioLib node (prefabs/ScenarioLib.prefab.ron):
-- the menu scene carries none, so the first ask spawns one and the answer
-- comes a frame later. (The game's VM is Luau, with no loadfile: the disk
-- path below is for luajit, the tests.) A test can hand one in with useLib(t).
local LIB = nil
local lib_spawned = false
function useLib(t) LIB = t end
function lib()
  if LIB then return LIB end
  local h = findScript and findScript("scenario", { quiet = true }) or nil
  if h and h.valid == false then h = nil end
  if not h and spawn and vec3 and not lib_spawned then
    lib_spawned = true
    pcall(spawn, "ScenarioLib", vec3(0, 0, 0))
  end
  if not h and loadfile and setfenv then
    for _, p in ipairs({ "scripts/scenario.lua", "solar/scripts/scenario.lua" }) do
      local f = loadfile(p)
      if f then
        local e = setmetatable({}, { __index = _G })
        setfenv(f, e)
        if pcall(f) then h = e break end
      end
    end
  end
  LIB = h
  return h
end
local function slot_name() local L = lib(); return (L and L.SLOT) or SLOT_FALLBACK end

-- ── pure ────────────────────────────────────────────────────────────────────

MEDAL_RANK = { gold = 3, silver = 2, bronze = 1 }
MEDAL_STYLE = { gold = "scn/medalGold", silver = "scn/medalSilver", bronze = "scn/medalBronze" }

-- The profile entry for a scenario (profile[id], or profile.scenarios[id]).
function entryOf(profile, id)
  if type(profile) ~= "table" then return nil end
  local e = profile[id]
  if type(e) ~= "table" and type(profile.scenarios) == "table" then e = profile.scenarios[id] end
  return type(e) == "table" and e or nil
end

-- RESET: the entry gone, the rest of the profile kept.
function withoutEntry(profile, id)
  if type(profile) ~= "table" then return {} end
  profile[id] = nil
  if type(profile.scenarios) == "table" then profile.scenarios[id] = nil end
  return profile
end

-- What a `requires` names: "flag_day" (any medal) or { id =, medal = }
-- (that medal or better). → id, medal
local function req_of(r)
  if type(r) == "string" then return r, "bronze" end
  if type(r) == "table" then return r.id or r[1], r.medal or r[2] or "bronze" end
  return nil
end

-- Is the scenario open? → true, or false and "after Flag Day"
function unlocked(sc, profile, byId)
  local rid, medal = req_of(sc.requires)
  if not rid then return true end
  local e = entryOf(profile, rid)
  local have = e and MEDAL_RANK[e.best or ""] or 0
  if have >= (MEDAL_RANK[medal] or 1) then return true end
  local other = byId and byId[rid]
  local name = other and other.title or rid
  if medal ~= "bronze" then return false, string.format("after %s with %s", name, medal) end
  return false, "after " .. name
end

-- "kit, air · 20 min" for a list row
function rowNote(sc)
  local t = {}
  for i, k in ipairs(type(sc.teaches) == "table" and sc.teaches or {}) do
    if i > 2 then break end
    t[#t + 1] = tostring(k):lower()
  end
  local par = (type(sc.par) == "number" and sc.par > 0) and string.format("%d min", math.max(1, math.floor(sc.par / 60 + 0.5)))
    or ((type(sc.minutes) == "number" and sc.minutes > 0) and string.format("%d min", math.floor(sc.minutes + 0.5)) or "—")
  if #t == 0 then return par end
  return table.concat(t, ", ") .. "  ·  " .. par
end

-- "Best: gold in 14:32 · 3 plays" (or "Not played yet")
local function clock(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  if s >= 3600 then return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60) end
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
function bestLine(e)
  if not e or (not e.best and (e.plays or 0) == 0) then return "Not played yet" end
  local parts = {}
  if e.best then
    parts[#parts + 1] = "Best: " .. e.best .. (e.bestTime and (" in " .. clock(e.bestTime)) or "")
  elseif e.lastOutcome then
    parts[#parts + 1] = "Last: " .. tostring(e.lastOutcome)
  end
  if (e.plays or 0) > 0 then parts[#parts + 1] = string.format("%d play%s", e.plays, e.plays == 1 and "" or "s") end
  return table.concat(parts, "  ·  ")
end

-- The card's long text: `story` (a string, or paragraphs as a list) when
-- the author wrote one, else the blurb.
function storyText(sc, full)
  local s = full and full.story or sc.story
  if type(s) == "table" then
    local o = {}
    for _, p in ipairs(s) do o[#o + 1] = tostring(p) end
    s = table.concat(o, "\n\n")
  end
  if type(s) == "string" and s ~= "" then return s, true end
  return tostring((full and full.blurb) or sc.blurb or ""), false
end

-- "by Ty · mod" / "by Ty" / "mod" / nil
function authorLine(sc, full)
  local a = (full and full.author) or sc.author
  local mod = sc.user == true or sc.mod == true or sc.source == "user"
  if a and a ~= "" then return "by " .. tostring(a) .. (mod and "  ·  mod" or "") end
  return mod and "a mod (user scenarios folder)" or nil
end

-- The CONTINUE line for a run in progress, or nil when there is none (or
-- it is finished). summary = scenario.slotSummary(get)
function continueLine(summary)
  if type(summary) ~= "table" or not summary.id then return nil end
  if summary.outcome and summary.outcome ~= "" then return nil end
  local steps = summary.steps or 0
  local step = math.min(summary.step or 1, math.max(steps, 1))
  return string.format("Continue  ·  %s  ·  step %d/%d", summary.title or summary.id, step, steps)
end

-- A described element whose children were written `cond and {…} or nil`
-- has holes. ui.make copes (it walks to the largest key), but ipairs and `#`
-- stop at one, and the luajit tests walk the trees that way. Close them up,
-- all the way down the positional children, before ui.make sees the tree.
function tidy(t)
  if type(t) ~= "table" then return t end
  local idx = {}
  for k, v in pairs(t) do
    if type(k) == "number" then idx[#idx + 1] = k end
  end
  table.sort(idx)
  local vals = {}
  for _, k in ipairs(idx) do
    local v = t[k]
    t[k] = nil
    if v ~= false then vals[#vals + 1] = v end
  end
  for i, v in ipairs(vals) do t[i] = tidy(v) end
  return t
end

-- ── slot peeks (save.slot switches the store: read and switch back) ─────────

local function summary_now()
  local L = lib()
  if not (L and L.slotSummary and save and save.slot) then return nil end
  local cur = save.slot()
  local ok, s = pcall(function()
    save.slot(slot_name())
    return L.slotSummary(function(k) return save.get(k) end)
  end)
  save.slot(cur)
  return ok and s or nil
end

-- ── state ───────────────────────────────────────────────────────────────────

local list = {}           -- listAll()
local byId = {}
local profile = {}
local summary = nil
local sel = nil           -- the selected id
local armed = nil         -- "play" | "reset" while a key asks "sure?"
local err = nil           -- a line to show under the keys (a refused PLAY)
local dirty = true
local panel_node, row_node = nil, nil
local focus_want = nil    -- a node name to focus after the next describe

-- Published for probes: the list, the selection, the continue summary.
function scenarios() return list end
function selected() return sel end
function continueSummary() return summary end

local full_cache = {}   -- id → the whole scenario table (for story / author), loaded on first view
local function full_of(id)
  if full_cache[id] ~= nil then return full_cache[id] or nil end
  full_cache[id] = false
  local L = lib()
  if L and L.load then
    local ok, t = pcall(L.load, id)
    if ok and type(t) == "table" then full_cache[id] = t end
  end
  return full_cache[id] or nil
end

local function reload()
  full_cache = {}
  local L = lib()
  list, byId = {}, {}
  if L and L.listAll then
    local ok, l = pcall(L.listAll)
    if ok and type(l) == "table" then list = l end
  end
  for _, sc in ipairs(list) do byId[sc.id] = sc end
  profile = {}
  if L and L.profileLoad then
    local ok, p = pcall(L.profileLoad)
    if ok and type(p) == "table" then profile = p end
  end
  summary = summary_now()
  if not (sel and byId[sel]) then
    sel = (summary and summary.id and byId[summary.id]) and summary.id or (list[1] and list[1].id) or nil
  end
  dirty = true
end

-- ── the row on the menu card ────────────────────────────────────────────────

local function draw_row()
  if not (row_node and ui and ui.make) then return end
  local c = continueLine(summary_now())
  pcall(ui.make, row_node, {
    { "text", key = "tag", style = "menu/slotTag", pin = "left", x = 18, w = 120, h = 14, text = "SCENARIOS" },
    { "text", key = "what", style = "menu/slotTag", pin = "left", x = 130, w = 190, h = 14,
      text = "showcase missions · a medal each" },
    { "text", key = "go", style = "menu/slotGo", pin = "right", x = -18, w = 200, h = 20, textAlign = "end",
      text = c and "CONTINUE  ▸" or "OPEN  ▸" },
  })
end

-- ── the panel ───────────────────────────────────────────────────────────────

local function show(on)
  open = on
  local p = find and find("Scenarios Panel")
  local pe = p and p:getcomponent("UiElement")
  if pe then pe.visible = on end
  local m = find and find("Menu Panel")
  local me = m and m:getcomponent("UiElement")
  if me then me.visible = not on end
end

function openPanel()
  armed, err = nil, nil
  reload()
  show(true)
  sfx("open")
  if sel then focus_want = "Scn Row " .. sel end
end

function closePanel()
  show(false)
  armed = nil
  if panel_node and ui and ui.make then pcall(ui.make, panel_node, {}) end
  draw_row()
end

local function do_play(id)
  local L = lib()
  if not (L and L.prepareSlot) then err = "Scenarios are not available in this build." dirty = true return end
  local ok, why = L.prepareSlot(id)
  if not ok then err = "Could not start it: " .. tostring(why) dirty = true return end
  sfx("sign")
  if scene and scene.load then scene.load("system") end
end
playScenario = do_play   -- (probes: exactly what the PLAY key does once it is sure)

local function press_play()
  if not sel then return end
  local sc = byId[sel]
  local ok, why = unlocked(sc, profile, byId)
  if not ok then sfx("denied"); err = "Locked: " .. why .. "." dirty = true return end
  local c = continueLine(summary)
  if c and armed ~= "play" then
    armed = "play"; err = nil; dirty = true
    sfx("arm")
    return
  end
  do_play(sel)
end

local function press_continue()
  if not (summary and save and save.slot) then return end
  sfx("click")
  save.slot(slot_name())
  if scene and scene.load then scene.load("system") end
end

local function press_reset()
  if not sel then return end
  if armed ~= "reset" then armed = "reset"; dirty = true; sfx("arm") return end
  local L = lib()
  profile = withoutEntry(profile, sel)
  if L and L.profileSave then pcall(L.profileSave, profile) end
  armed = nil
  dirty = true
  sfx("close")
end

local function select_id(id)
  if id == sel then return end
  sel = id
  armed, err = nil, nil
  dirty = true
end

local function row_tree(sc)
  local e = entryOf(profile, sc.id)
  local ok, why = unlocked(sc, profile, byId)
  local active = sc.id == sel
  local best = e and e.best
  return { "button", key = sc.id, name = "Scn Row " .. sc.id, style = active and "panel/rowActive" or "panel/row",
    w = "100%", h = 34, dir = "row", pad = 8, gap = 10, align = "center",
    tooltip = (not ok) and why or nil,
    onClicked = function()
      if sel == sc.id then focus_want = "Scn Play" else sfx("click") end
      select_id(sc.id)
    end,
    onFocusEnter = function() select_id(sc.id) end,
    { "text", key = "c", style = ok and "panel/title" or "panel/cellMuted", w = 14, h = "fit", text = active and "▸" or " " },
    { "text", key = "t", style = ok and "panel/cellStrong" or "panel/cellMuted", w = 190, h = "fit",
      text = string.upper(sc.title or sc.id) .. ((sc.user or sc.mod or sc.source == "user") and "  · MOD" or "") },
    { "text", key = "n", style = "panel/cellMuted", w = "grow", h = "fit", text = ok and rowNote(sc) or why },
    { "text", key = "m", style = best and MEDAL_STYLE[best] or "panel/cellMuted", w = 14, h = "fit", textSize = 13,
      text = best and "●" or "·" },
    { "text", key = "w", style = best and "panel/cell" or "panel/cellMuted", w = 52, h = "fit", text = best or "—" },
  }
end

local function side_tree(sc)
  if not sc then
    return { "col", key = "side", w = SIDE_W, h = "100%", pad = 0, gap = 8, align = "start",
      { "text", key = "none", style = "panel/body", w = "100%", h = "fit", wrap = true,
        text = "No scenarios are installed. They live in the scenarios folder, one file each." } }
  end
  local e = entryOf(profile, sc.id)
  local ok, why = unlocked(sc, profile, byId)
  local pic = "scenarios/" .. sc.id .. "/card.png"
  local has_pic = assets and assets.getFile and assets.getFile(pic) ~= nil
  local c = continueLine(summary)
  local play_text = "Play"
  if armed == "play" and c then
    play_text = (summary.id == sc.id) and "Start over?" or ("Replace " .. (summary.title or summary.id) .. "?")
  end
  return { "col", key = "side", w = SIDE_W, h = "100%", pad = 0, gap = 8, align = "start",
    { "box", key = "pic", style = "hud/instrument", w = PIC_W, h = PIC_H, pad = 4,
      has_pic and { "image", key = "img", inset = 4, texture = pic, imageFit = "cover" } or
        { "text", key = "np", style = "menu/slotTag", inset = 0, textAlign = "center", textValign = "center", text = "NO PICTURE YET" } },
    { "text", key = "t", style = "panel/heading", w = "100%", h = "fit", text = sc.title or sc.id },
    (type(sc.teaches) == "table" and #sc.teaches > 0) and { "text", key = "tch", style = "panel/label", w = "100%", h = "fit", wrap = true,
      text = "teaches  " .. table.concat((function() local o = {} for _, k in ipairs(sc.teaches) do o[#o + 1] = string.upper(tostring(k)) end return o end)(), "  ·  ") } or nil,
    authorLine(sc, full_of(sc.id)) and { "text", key = "by", style = "panel/hint", w = "100%", h = "fit",
      text = authorLine(sc, full_of(sc.id)) } or nil,
    { "scroll", key = "story", name = "Scn Story", w = "100%", h = "grow", scrollFade = 10,
      { "text", key = "b", style = "panel/body", w = "100%", h = "fit", wrap = true, text = (storyText(sc, full_of(sc.id))) } },
    sc.err and { "text", key = "err", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = "This scenario has an error: " .. tostring(sc.err) } or nil,
    { "text", key = "best", style = "panel/hint", w = "100%", h = "fit", text = bestLine(e) },
    (not ok) and { "text", key = "lock", style = "panel/hintWarn", w = "100%", h = "fit", text = "Locked: " .. why .. "." } or nil,
    err and { "text", key = "e", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = err } or nil,
    { "row", key = "keys", w = "100%", h = 34, pad = 0, gap = 8, align = "center",
      { "button", key = "play", name = "Scn Play", style = "panel/action", w = "grow", h = 34, text = play_text,
        textAlign = "center", textValign = "center", disabled = (not ok) or (sc.err ~= nil) or nil,
        tooltip = "Starts it from the beginning in the scenario slot. Your galaxies are not touched.",
        onClicked = function() press_play() end },
      { "button", key = "reset", name = "Scn Reset", style = "panel/danger", w = 108, h = 34,
        text = armed == "reset" and "Sure?" or "Reset", selected = armed == "reset" or nil,
        textAlign = "center", textValign = "center", disabled = (e == nil) or nil,
        tooltip = "Forget this scenario's best medal and time",
        onClicked = function() press_reset() end } } }
end

local function panel_tree()
  local c = continueLine(summary)
  return {
    { "col", key = "scn", style = "panel/frame", inset = 0, pad = 22, gap = 10, align = "start",
      { "row", key = "head", w = "100%", h = "fit", pad = 0, gap = 12, align = "end",
        { "text", key = "h", style = "panel/heading", w = "fit", h = "fit", text = "SCENARIOS" },
        { "text", key = "s", style = "panel/hint", w = "grow", h = "fit",
          text = "Set pieces that show one part of the game each. Played in their own slot: nothing here touches your galaxies." } },
      { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
      { "row", key = "body", w = "100%", h = "grow", pad = 0, gap = 20, align = "stretch",
        { "scroll", key = "list", name = "Scn List", w = LIST_W, h = "100%", scrollFade = 12,
          { "col", key = "rows", w = "100%", h = "fit", pad = 0, gap = 4, align = "stretch",
            items = list, function(sc) return row_tree(sc) end } },
        { "box", key = "vr", style = "panel/rule", w = 1, h = "100%" },
        side_tree(byId[sel]) },
      { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 },
      { "row", key = "foot", w = "100%", h = 32, pad = 0, gap = 12, align = "center",
        { "button", key = "back", name = "Scn Back", style = "panel/secondary", w = 110, h = 32, text = "Back",
          textAlign = "center", textValign = "center",
          onClicked = function() sfx("close"); closePanel() end },
        c and { "button", key = "cont", name = "Scn Continue", style = "panel/secondary", w = "fit", h = 32, pad = 12,
          text = c, textAlign = "center", textValign = "center",
          tooltip = "Back into the scenario you left, where you left it",
          onClicked = function() press_continue() end } or nil,
        { "text", key = "hint", style = "panel/hint", w = "grow", h = "fit", textAlign = "end",
          text = "↑ ↓ choose  ·  Enter play  ·  Esc back" } } },
  }
end

-- ── engine hooks ────────────────────────────────────────────────────────────

function start(node)
  row_node = node
  panel_node = find and find("Scenarios Panel") or nil
  show(false)
  draw_row()
end

function clicked(node)
  sfx("click")
  openPanel()
end

local lib_wait = 0
function update(node, dt)
  -- the rulebook arrives a frame or two after it is spawned: then the row
  -- (its CONTINUE) and an open page are drawn again with it
  if not LIB and lib_wait < 10 then
    lib_wait = lib_wait + (dt or 0)
    if lib() then
      draw_row()
      if open then reload() end
    end
  end
  if not open then return end
  if not panel_node or panel_node.valid == false then panel_node = find and find("Scenarios Panel") or nil end
  if not panel_node then return end
  if input and input.pressed and input.pressed("escape") then
    if armed then armed = nil; dirty = true
    else sfx("close"); closePanel(); return end
  end
  local pe = panel_node:getcomponent("UiElement")
  if pe and (pe.width ~= PANEL_W or pe.height ~= PANEL_H) then pe.width, pe.height = PANEL_W, PANEL_H end
  if dirty then
    dirty = false
    ui.make(panel_node, tidy(panel_tree()))
  end
  if focus_want and ui and ui.focus then
    local n = find(focus_want)
    if n then ui.focus(n) end
    focus_want = nil
  end
end
