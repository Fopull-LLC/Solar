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
  if def.store then return string.format("stowage locker · %d kg of its own", def.store) end
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
  -- A fresh part already in hand: its own card puts it back, another card
  -- swaps it (a lifted or pasted craft piece is never dropped from here).
  local cur = B.heldId and B.heldId() or nil
  if cur and B.holding and B.holding() == "part" and B.dropHeld then
    B.dropHeld()
    st.dirty = true
    if cur == id then return false end
  end
  local ok
  if B.hold then ok = B.hold(id) elseif B.pick then B.pick(id); ok = true end
  if ok then push_recent(id) end
  st.dirty = true
  return ok
end

-- A new section (or a new search) starts at the TOP of its list (playtest:
-- "selecting a new part category list should scroll you to the top instead
-- of keeping you where u are"). The list keeps its scroll otherwise — the
-- once-a-second refresh and a pick never move it. `scroll_top` counts the
-- frames left to write it (the list node may arrive a frame after the make).
function setQuery(q)
  q = q or ""
  if q ~= st.query then st.scroll_top = 2 end
  st.query = q; st.dirty = true
end
function setTab(t)
  if t ~= st.tab or st.query ~= "" then st.scroll_top = 2 end
  st.tab = t; st.dirty = true
end
LIST_NODE = "CatalogList"
local function scroll_top_tick()
  if not (st.scroll_top and st.scroll_top > 0) then return end
  st.scroll_top = st.scroll_top - 1
  local n = find and find(LIST_NODE)
  local e = n and n.getcomponent and n:getcomponent("UiElement")
  if e then e.scrollY = 0 end
end
function tab() return st.tab end

function focusSearch()
  local f = find and find("FieldPartSearch")
  if f and ui and ui.focus then ui.focus(f) end
end

-- ── THE PREVIEW (playtest 2026-10-26: "show a viewport of the part spinning
-- so you can see what each part in the catalogue looks like") ──────────────
-- ONE render-target camera, never one per card: the part under the cursor
-- (or, with none hovered, the part in your hand) spins on a little stand of
-- its own, 2.4 km up the builder's frame where nothing else is, on the
-- "viewmodel" render layer (bit 3: Default 0, entity 1, level 2, viewmodel 3
-- — the first-person tools' layer, which stands down in the builder), and the
-- camera's cullMask is that layer alone, so its render is the part over the
-- sky. 256² at 30 Hz, and the camera node is switched OFF whenever no plate
-- shows, so an idle catalogue pays nothing for it. The plate floats beside
-- the parts panel's top corner; the list itself never moves.
PREVIEW_TARGET = "partpreview"
local PV = { alt = 2400.0, fov = 0.5, px = 256, bit = 3, layer = "viewmodel" }
local pv = { cam = nil, making = false, part = nil, id = nil, want = nil, spin = 0, ready = false, on = false, dist = 4 }
previewId = nil       -- the part the plate shows (probes)

local function pv_parent(B) return B.frameNodeOrNil and B.frameNodeOrNil() or nil end
local function pv_valid(n) return n ~= nil and n.valid ~= false end
local function pv_layer(n, depth)
  depth = depth or 0
  pcall(function() n.layer = PV.layer end)
  if depth < 4 and n.children then
    local ok, kids = pcall(function() return n:children() end)
    if ok and type(kids) == "table" then for _, c in ipairs(kids) do pv_layer(c, depth + 1) end end
  end
end
local function pv_camera(B)
  if pv_valid(pv.cam) then return pv.cam end
  if pv.making or not createNode then return nil end
  pv.making = true
  createNode("PartPreviewCam", pv_parent(B), function(n)
    pv.making, pv.cam = false, n
    n.x, n.y, n.z = 0, PV.alt, pv.dist
    if n.setAngles then n:setAngles(0, 0, 0) end
    local ok, err = pcall(function()
      n:setCamera { target = PREVIEW_TARGET, width = PV.px, height = PV.px, hz = 30, fovY = PV.fov, active = false,
                    cullMask = 2 ^ PV.bit }
    end)
    if not ok and log then log("catalog preview: no render target (" .. tostring(err) .. ")") end
    n.enabled = pv.on
  end)
  return nil
end
local function pv_show(on)
  pv.on = on
  if pv_valid(pv.cam) and pv.cam.enabled ~= on then pv.cam.enabled = on end
  if pv_valid(pv.part) and pv.part.enabled ~= on then pv.part.enabled = on end
end
-- Put part `id` on the stand (a fresh spawn when it changes).
local function stage_want(B, id)
  if id == pv.id then return end
  pv.id, pv.ready = id, false
  if pv_valid(pv.part) then pv.part:destroy() end
  pv.part = nil
  local prefab = B.previewPrefab and B.previewPrefab(id)
  local def = B.partInfo(id) or {}
  local size = math.max(def.h or 1, 2 * (def.rx or 0.5), 2 * (def.rz or def.rx or 0.5), 0.3)
  pv.dist = size * 0.62 / math.tan(PV.fov * 0.5)
  if prefab and spawn then
    spawn(prefab, vec3 and vec3(0, PV.alt, 0) or nil, function(n)
      if pv.id ~= id or not pv_valid(n) then if pv_valid(n) then n:destroy() end return end
      local par = pv_parent(B)
      if par and n.setParent then n:setParent(par, { keepWorld = false }) end
      n.x, n.y, n.z = 0, PV.alt, 0
      pv_layer(n)
      pv.part, pv.ready, pv.ready_t = n, true, time or 0
      n.enabled = pv.on
    end, { body = false })
  end
end
local function stage_pose(yaw)
  if pv_valid(pv.cam) then
    pv.cam.x, pv.cam.y, pv.cam.z = 0, PV.alt + pv.dist * 0.18, pv.dist
    if pv.cam.setAngles then pv.cam:setAngles(0, -0.18, 0) end
  end
  if pv_valid(pv.part) and pv.part.setAngles then pv.part:setAngles(yaw, 0, 0) end
end

-- THE TILE ICONS: each part photographed ONCE from the same stand
-- (camera.captureTexture through the preview camera, 64², kept as an img:
-- texture for the session), one at a time while nothing is hovered or held,
-- the first time the catalogue opens. The cards show them as they arrive.
ICONS = {}            -- id → "img:N"
local icq = { busy = false, failed = {}, n = 0, cam = nil, making = false }
-- The icon camera: a plain off-screen camera beside the preview's (the
-- render-target camera itself photographed nothing but its sky on rc33).
local function icon_camera(B)
  if pv_valid(icq.cam) then return icq.cam end
  if icq.making or not createNode then return nil end
  icq.making = true
  createNode("PartIconCam", pv_parent(B), function(n)
    icq.making, icq.cam = false, n
    pcall(function() n:setCamera { fovY = PV.fov, active = false, cullMask = 2 ^ PV.bit } end)
  end)
  return nil
end
local function icon_tick(B)
  if icq.done or icq.busy or not (camera and camera.captureTexture) then return false end
  local id = nil
  for _, sec in ipairs(B.catalogue and B.catalogue() or {}) do
    for _, x in ipairs(sec.ids) do
      if not ICONS[x] and not icq.failed[x] and B.previewPrefab and B.previewPrefab(x) then id = x break end
    end
    if id then break end
  end
  if not id then
    icq.done = true
    st.dirty = true
    return false
  end
  local ic = icon_camera(B)
  if not ic then return true end
  stage_want(B, id)
  -- the live preview's render target stays OFF while icons are taken: only
  -- the part on the stand and the one-shot captures draw
  pv.on = false
  if pv_valid(pv.cam) and pv.cam.enabled ~= false then pv.cam.enabled = false end
  if pv_valid(pv.part) then
    if pv.part.enabled ~= true then pv.part.enabled = true end
    if pv.part.setAngles then pv.part:setAngles(0.65, 0, 0) end
  end
  ic.x, ic.y, ic.z = 0, PV.alt + pv.dist * 0.18, pv.dist
  if ic.setAngles then ic:setAngles(0, -0.18, 0) end
  -- a moment on the stand before the picture (the model streams in, the pose lands)
  if not (pv.ready and pv.id == id and (time or 0) - (pv.ready_t or 0) > 0.35) then
    icq.wait = (icq.wait or 0) + 1
    if icq.wait > 240 then icq.failed[id] = true; icq.wait = 0 end
    return true
  end
  icq.wait = 0
  icq.busy = true
  local ok = pcall(camera.captureTexture, ic, { w = 64, h = 64 }, function(tex, err)
    icq.busy = false
    if tex then ICONS[id] = tex; icq.n = icq.n + 1 else icq.failed[id] = true end
    if icq.n % 8 == 0 then st.dirty = true end
  end)
  if not ok then icq.busy = false; icq.failed[id] = true end
  return true
end
function iconCount() return icq.n end

-- Each frame: what should spin, and spin it (or, with nothing to show, the
-- next tile icon).
local function preview_tick(B, dt)
  local want = st.hover or st.held
  previewId = want
  if not want then
    if not icon_tick(B) then pv_show(false) end
    return
  end
  pv_camera(B)
  stage_want(B, want)
  pv_show(true)
  pv.spin = (pv.spin + (dt or 0.016) * 0.9) % (2 * math.pi)
  stage_pose(pv.spin)
end
function previewReady() return pv.ready and pv_valid(pv.cam) and pv.on end

-- The floating plate: the part's picture, its name, its role.
local function preview_plate(B, L)
  local id = st.hover or st.held
  if not (id and pv.ready) then return nil end
  local def = B.partInfo(id) or {}
  local r = L.left
  return { "col", key = "pv", style = "panel/frame", pin = "topLeft", x = r.x + r.w + 8, y = r.y, w = 196, h = "fit",
    gap = 4, pad = 8, align = "stretch",
    { "image", key = "img", texture = "rt:" .. PREVIEW_TARGET, w = 180, h = 180 },
    { "text", key = "n", style = "cat/name", w = "100%", h = 16, text = (st.held == id and "IN HAND  ·  " or "") .. (def.label or id),
      maxLines = 1, overflow = "ellipsis" },
    { "text", key = "r", style = "cat/role", w = "100%", h = "fit", text = role(def), wrap = true, maxLines = 3 } }
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
  -- the card of the part in your hand is latched in, orange-rimmed, "IN HAND"
  local inhand = st.held == id
  if inhand then price_text = "IN HAND" end
  local icon = ICONS[id]
  return { "row", key = id, w = "100%", h = 40, gap = 3, pad = 0, align = "center",
    icon and { "image", key = "ic", texture = icon, w = 36, h = 36, opacity = locked and 0.55 or 1.0 }
      or { "box", key = "ic", style = "panel/rule", w = 36, h = 36, opacity = 0.35 },
    { "button", key = "c", style = inhand and "panel/rowActive" or "panel/row", selected = inhand or nil,
      w = "grow", h = 40, dir = "column", align = "stretch", gap = 2,
      opacity = locked and 0.7 or 1.0,
      onClicked = function() pickPart(id) end,
      onHoverEnd = function() if st.hover == id then st.hover = nil end end,
      onHoverStart = function()
        st.hover = id
        if locked and rs and B.hint and rs.lockLine then B.hint((rs.labelOf and rs.labelOf(id) or id) .. "  —  " .. (rs.lockLine(id) or ""), 4.0) end
      end,
      { "row", key = "top", w = "100%", h = 16, gap = 4, pad = 0, align = "center",
        { "text", key = "n", style = locked and "cat/nameLocked" or "cat/name", w = "grow", h = 16,
          text = def.label or id, maxLines = 1, overflow = "ellipsis" },
        { "text", key = "p", style = inhand and "cat/inHand" or armed and "cat/priceArmed" or (locked and "cat/priceLocked" or "cat/price"),
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
    { "scroll", key = "list", name = LIST_NODE, w = "100%", h = "grow", dir = "column", gap = 3, pad = 0, align = "stretch",
      scrollSpeed = 48, items = rows, function(x) return x end },
    { "text", key = "foot", style = "panel/hint", w = "100%", h = 14, maxLines = 1, overflow = "ellipsis",
      text = st.held and "IN HAND — click it again to put it back · ESC drops" or "click to hold · ENTER picks the first match" },
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
  st.held = B.heldId and B.heldId() or nil
  -- (no card hovered while the pointer is off the panel: the plate goes)
  if st.hover and not ownsMouse() then st.hover = nil end
  preview_tick(B, dt)
  local sig = table.concat({ math.floor(W), math.floor(H), st.tab, st.query, tostring(st.held), tostring(st.hover),
    tostring(pv.ready) }, "|")
  if not st.dirty and sig == st.sig and st.t < 1.0 then scroll_top_tick() return end
  st.dirty, st.sig, st.t = false, sig, 0
  local tree = { describe(B, L) }
  local plate = preview_plate(B, L)
  if plate then tree[#tree + 1] = plate end
  ui.make(node, tree)
  scroll_top_tick()
end
