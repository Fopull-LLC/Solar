-- THE PARTS PANEL — the left plate of the Vehicle Assembly (docs/builder-design.md
-- §4.4; WP2): every part you can bolt on, found three ways.
--
--   SEARCH    / or CTRL+F focuses it (the builder calls focusSearch); typing
--             filters every section at once; ENTER puts the first match in
--             your hand
--   TABS      ALL · ★ (your favourites) · RECENT (the last 8 picked) ·
--             SUB-ASSY (saved sub-assemblies) · one keycap per section
--   ★         on each row: keep a part in your favourites (saved in the slot)
--
-- Clicking a card hands its id to the builder (`hold`), which spawns the ghost
-- on your cursor. A card for a part R&D hasn't opened is dimmed and priced at
-- its unlock cost, and clicking it BUYS the unlock (twice: arm, confirm) — the
-- catalogue is the research screen, so a locked card looks available-but-not-
-- yet rather than disabled.
--
-- COST: the plate is described only when something on it changed — the search,
-- the tab, a favourite, a pick, an unlock, the layer's size — and otherwise
-- once a second for the money and lock state. It used to re-describe every
-- frame (1.4–1.8 ms); now an idle frame is one signature compare.

local el
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

-- What a part is FOR, in a few words under its name: its own `desc` when it
-- has one, otherwise read off the registry's numbers.
local function role(def)
  if def.desc then return def.desc end
  if def.thrust then
    return def.ve and string.format("engine · %.0f kN · ve %.0f m/s · %.2f t", def.thrust, def.ve, def.mass)
      or string.format("engine · %.0f kN · %.2f t", def.thrust, def.mass)
  end
  if def.fuel then
    local ft = def.fuel_t or 0.01
    return string.format("fuel tank · %d fuel · %.2f t full, %.2f empty", def.fuel, def.mass + def.fuel * ft, def.mass)
  end
  if def.kind == "crewed" then return "crew pod — flies anywhere, with you in it" end
  if def.kind == "probe" then return "probe core — flies with power + a link home" end
  if def.chute then return "parachute — slows the landing" end
  if def.cargo then return string.format("cargo hold · carries %d kg", def.cargo) end
  if def.legs then return string.format("landing legs · %.0f kg", def.mass * 1000) end
  if def.decouple then return def.radial and "radial decoupler — drops side boosters" or "decoupler — separates a stage" end
  return string.format("%.2f t", def.mass or 0)
end

-- Short keycap legends for the sections (§4.4: CMD PROP AERO STR FRM ELEC ROV ROBO PAY).
local SHORT = { COMMAND = "CMD", PROPULSION = "PROP", AIRCRAFT = "AERO", STRUCTURE = "STR", FRAME = "FRM",
                ELECTRICAL = "ELEC", ROVER = "ROV", ROBOTICS = "ROBO", PAYLOAD = "PAY" }
local function short(title) return SHORT[title] or title:sub(1, 4) end

-- ── state (favourites and recents ride in the save slot) ────────────────────
local st = { tab = "ALL", query = "", favs = nil, recent = nil, dirty = true, sig = nil, t = 0 }
local MAX_RECENT = 8

local function load_prefs()
  if st.favs then return end
  st.favs, st.recent = {}, {}
  if save and save.get then
    for _, id in ipairs(save.get("builder.favourites", {}) or {}) do st.favs[id] = true end
    for _, id in ipairs(save.get("builder.recent", {}) or {}) do st.recent[#st.recent + 1] = id end
  end
end
local function save_prefs()
  if not (save and save.set) then return end
  local f = {}
  for id in pairs(st.favs) do f[#f + 1] = id end
  table.sort(f)
  save.set("builder.favourites", f)
  save.set("builder.recent", st.recent)
end

function isFavourite(id) load_prefs() return st.favs[id] == true end
function toggleFavourite(id)
  load_prefs()
  st.favs[id] = (not st.favs[id]) or nil
  st.dirty = true
  save_prefs()
end
function recent() load_prefs() return st.recent end
local function push_recent(id)
  load_prefs()
  for i = #st.recent, 1, -1 do if st.recent[i] == id then table.remove(st.recent, i) end end
  table.insert(st.recent, 1, id)
  while #st.recent > MAX_RECENT do table.remove(st.recent) end
  st.dirty = true
  save_prefs()
end

-- ── search ──────────────────────────────────────────────────────────────────
-- Every token must hit the label, the id, the description or the section.
-- Rank: a word of the label starts with the query (0), the id does (1), the
-- label contains it (2), anything else (3); ties keep the catalogue's order.
local function rank(q, id, def, section)
  if q == "" then return 0 end
  local label = (def.label or id):lower()
  local hay = label .. " " .. id:lower() .. " " .. (def.desc or ""):lower() .. " " .. (section or ""):lower()
  for tok in q:gmatch("%S+") do
    if not hay:find(tok, 1, true) then return nil end
  end
  local first = q:match("%S+") or q
  if label:find(first, 1, true) == 1 or label:find(" " .. first, 1, true) then return 0 end
  if id:lower():find(first, 1, true) == 1 then return 1 end
  if label:find(first, 1, true) then return 2 end
  return 3
end

-- The ids a tab and a query show, in order: { { id, section } … }.
function listFor(B, tab, query)
  load_prefs()
  local q = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local out = {}
  local sections = B.catalogue and B.catalogue() or {}
  local where = {}
  for _, sec in ipairs(sections) do for _, id in ipairs(sec.ids) do where[id] = sec.title end end
  local function want(id)
    if q ~= "" then return true end           -- a search looks everywhere
    if tab == "ALL" then return true end
    if tab == "FAV" then return st.favs[id] == true end
    return where[id] == tab
  end
  if tab == "RECENT" and q == "" then
    for _, id in ipairs(st.recent) do
      if B.partInfo(id) then out[#out + 1] = { id = id, section = where[id], r = 0, i = #out } end
    end
    return out
  end
  local i = 0
  for _, sec in ipairs(sections) do
    for _, id in ipairs(sec.ids) do
      i = i + 1
      local def = B.partInfo(id)
      if def and want(id) then
        local r = rank(q, id, def, sec.title)
        if r then out[#out + 1] = { id = id, section = sec.title, r = r, i = i } end
      end
    end
  end
  if q ~= "" then table.sort(out, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.i < b.i end) end
  return out
end

function firstMatch(B, query)
  local l = listFor(B, "ALL", query)
  return l[1] and l[1].id or nil
end

-- Put a part in the hand (the builder's research gate included).
function pickPart(id)
  local B = ref("builder")
  if not (B and id) then return false end
  local ok
  if B.hold then ok = B.hold(id) elseif B.pick then B.pick(id); ok = true end
  if ok then push_recent(id) end
  st.dirty = true
  return ok
end

function setQuery(q) st.query = q or ""; st.dirty = true end
function setTab(t) st.tab = t; st.dirty = true end
function tab() return st.tab end

function focusSearch()
  local f = find and find("FieldPartSearch")
  if f and ui and ui.focus then ui.focus(f) end
end

-- ── the plate ───────────────────────────────────────────────────────────────
local function layout(W, H)
  local tb = ref("builder_toolbar")
  if tb and tb.builderLayout then return tb.builderLayout(W, H) end
  return { W = W, H = H, left = { x = 8, y = 80, w = 228, h = H - 138 } }
end

local function card(B, rs, co, it)
  local id = it.id
  local def = B.partInfo(id)
  def = (B.liveDef and B.liveDef(id)) or def
  local locked = (rs and rs.isUnlocked and not rs.isUnlocked(id)) or false
  local function money(v) return (co and co.money) and co.money(v) or ("$" .. tostring(v or 0)) end
  local price = locked and ((rs and rs.costOf and rs.costOf(id)) or 0) or def.cost
  local needs = locked and rs and rs.blockedBy and rs.blockedBy(id) or nil
  local armed = locked and B.researchPending and B.researchPending(id) or false
  local price_text = locked and ("unlock " .. money(price)) or money(price)
  if armed then price_text = "confirm " .. money(price) .. "?" end
  local role_text = needs and ("locked · " .. needs) or role(def)
  local fav = st.favs[id] == true
  return { "row", key = id, w = "100%", h = 40, gap = 3, pad = 0, align = "center",
    { "button", key = "c", style = "panel/row", w = "grow", h = 40, dir = "column", align = "stretch", gap = 2,
      opacity = locked and 0.7 or 1.0,
      onClicked = function() pickPart(id) end,
      onHoverStart = function()
        if locked and rs and B.hint and rs.lockLine then B.hint((rs.labelOf and rs.labelOf(id) or id) .. "  —  " .. (rs.lockLine(id) or ""), 4.0) end
      end,
      { "row", key = "top", w = "100%", h = 16, gap = 4, pad = 0, align = "center",
        { "text", key = "n", style = locked and "cat/nameLocked" or "cat/name", w = "grow", h = 16,
          text = def.label or id, maxLines = 1, overflow = "ellipsis" },
        { "text", key = "p", style = armed and "cat/priceArmed" or (locked and "cat/priceLocked" or "cat/price"),
          w = "fit", h = 16, text = price_text, textAlign = "end" } },
      { "text", key = "r", style = needs and "cat/roleNeeds" or "cat/role", w = "100%", h = 14, text = role_text,
        maxLines = 1, overflow = "ellipsis" } },
    { "button", key = "f", style = "panel/choice", selected = fav, w = 22, h = 40, text = fav and "★" or "☆",
      textAlign = "center", textValign = "center", tooltip = fav and "Take it out of your favourites" or "Keep it in ★ favourites",
      onClicked = function() toggleFavourite(id) end },
  }
end

local function tabs(B)
  local list = { { "ALL", "ALL" }, { "FAV", "★" }, { "RECENT", "RECENT" }, { "SUB", "SUB-ASSY" } }
  for _, sec in ipairs(B.catalogue and B.catalogue() or {}) do list[#list + 1] = { sec.title, short(sec.title) } end
  return { "row", key = "tabs", w = "100%", h = "fit", wrap = true, gap = 3, pad = 0,
    items = list, function(t)
      local w = (t[1] == "RECENT" or t[1] == "SUB") and 70 or 48
      return { "button", key = "t" .. t[1], style = "panel/choice", selected = st.tab == t[1] and st.query == "",
        w = w, h = 22, text = t[2], textAlign = "center", textValign = "center",
        tooltip = t[1] == "FAV" and "Your favourites" or (SHORT[t[1]] and t[1]:sub(1, 1) .. t[1]:sub(2):lower() or nil),
        onClicked = function() setTab(t[1]) end }
    end }
end

local function sub_rows(B)
  local rows = {}
  for i, nm in ipairs(B.subAssemblies and B.subAssemblies() or {}) do
    rows[#rows + 1] = { "button", key = "sa" .. i, style = "panel/row", w = "100%", h = 30, text = nm,
      textValign = "center", tooltip = "Put this sub-assembly in your hand",
      onClicked = function() if B.hold then B.hold(nm) end end }
  end
  if #rows == 0 then
    rows[1] = { "text", key = "none", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = B.subAssemblies and "No sub-assemblies yet. Select parts, then SUB-ASSY on the toolbar or Make sub-assembly in a part's menu."
        or "Sub-assemblies arrive with the craft library." }
  end
  return rows
end

function describe(B, L)
  load_prefs()
  local rs, co = ref("research"), ref("company")
  local r = L.left
  local rows
  if st.tab == "SUB" and st.query == "" then
    rows = sub_rows(B)
  else
    rows = {}
    local list = listFor(B, st.tab, st.query)
    for _, it in ipairs(list) do rows[#rows + 1] = card(B, rs, co, it) end
    if #rows == 0 then
      rows[1] = { "text", key = "none", style = "panel/body", w = "100%", h = "fit", wrap = true,
        text = st.query ~= "" and ("Nothing matches “" .. st.query .. "”.")
          or (st.tab == "FAV" and "No favourites yet — ☆ on a part keeps it here."
          or (st.tab == "RECENT" and "Parts you pick show up here." or "Nothing here.")) }
    end
  end
  st.count = #rows
  return { "col", key = "parts", style = "panel/frame", pin = "topLeft", x = r.x, y = r.y, w = r.w, h = r.h,
    gap = 6, pad = 10, align = "stretch",
    { "row", key = "hd", w = "100%", h = 20, gap = 4, pad = 0, align = "center",
      { "text", key = "t", style = "panel/heading", w = "grow", h = 20, text = "Parts" },
      { "text", key = "n", style = "panel/label", w = "fit", h = 20, textValign = "center",
        text = st.query ~= "" and (st.count .. " found") or "" } },
    { "field", key = "q", name = "FieldPartSearch", style = "menu/field", w = "100%", h = 26, textSize = 13,
      placeholder = "/ search parts…", maxLen = 32,
      onChanged = function(n) if n then setQuery(n.text) end end,
      onSubmitted = function(n)
        local id = firstMatch(B, n and n.text or st.query)
        if id then pickPart(id) end
        if ui and ui.focus then ui.focus(nil) end
      end },
    tabs(B),
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "scroll", key = "list", w = "100%", h = "grow", dir = "column", gap = 3, pad = 0, align = "stretch",
      scrollSpeed = 48, items = rows, function(x) return x end },
    { "text", key = "foot", style = "panel/hint", w = "100%", h = 14, maxLines = 1, overflow = "ellipsis",
      text = "click to hold · ENTER picks the first match" },
  }
end


-- ── panel plumbing ──────────────────────────────────────────────────────────
local LAST = { L = nil }
local function mouse_du(H)
  if not (camera and camera.screenSize) then return nil end
  local sw, sh = camera.screenSize()
  if not (sh and sh > 0) then return nil end
  local mx, my = input.mouse()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  return (mx - (ox or 0)) * H / sh, (my - (oy or 0)) * H / sh
end
function ownsMouse()
  local L = LAST.L
  if not L then return false end
  local x, y = mouse_du(L.H)
  local r = L.left
  return x ~= nil and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end
function ownsKeys()
  local f = ui and ui.focused and ui.focused()
  return f ~= nil and f.name == "FieldPartSearch"
end

local registered = false
function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
end

function update(node, dt)
  local B = ref("builder")
  if not (B and B.catalogue and B.partInfo) then return end
  if not registered and B.registerPanel then registered = B.registerPanel(findScript("catalog_panel")) end
  if not el then el = node:getcomponent("UiElement") end
  local tb = ref("builder_toolbar")
  local W, H = 1280, 720
  if tb and tb.layerSize then W, H = tb.layerSize() end
  if tb and tb.fitHost then tb.fitHost(el, W, H) end
  local L = layout(W, H)
  LAST.L = L
  st.t = st.t + (dt or 0)
  local sig = table.concat({ math.floor(W), math.floor(H), st.tab, st.query }, "|")
  if not st.dirty and sig == st.sig and st.t < 1.0 then return end
  st.dirty, st.sig, st.t = false, sig, 0
  ui.make(node, { describe(B, L) })
end
