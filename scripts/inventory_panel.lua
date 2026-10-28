-- INVENTORY PANEL — what's in the suit pack, and where it can go from here.
--
-- Opened with I on foot. It lists the pack's contents and, when you're standing
-- next to something that can hold cargo, offers to move it:
--
--   next to a landed craft with a Cargo Bay  → its hold
--   next to the Commerce Depot               → the warehouse
--
-- Click a row to move that one stack; the button moves everything that fits.
--
-- GEAR (inventory.GEAR) is listed under the cargo: the tools you carry and the
-- consumables (a Relay Beacon) that ride the tool belt until they are used.
--
-- THE DEPOT'S COUNTERS. Gear is bought in one place: standing at the Commerce
-- Depot, the panel is its two counters — BUY (the gear the depot stocks:
-- company money, into the pack, onto the belt) and SELL (the pack, the
-- warehouse and any landed hold, a row per material, through the depot's own
-- sale so prices, standing and discovery premiums are its). There is no buy
-- button anywhere else: a beacon is something you walk home for.
-- Whatever doesn't fit stays in the pack — a transfer never destroys anything,
-- and a full hold says so rather than silently eating the rest.
--
-- Moving cargo into a craft re-applies its mass (vessel_controller.holdApplyMass),
-- so the ship you just loaded actually flies like a loaded ship.
--
-- THE SCREEN IS DESCRIBED, NOT AUTHORED. It used to be eight fixed row nodes in
-- `system.ron`, each carrying its own `inv_row` script, each hiding itself when
-- the pack held fewer than eight stacks. That is a list pretending to be a
-- layout: it could never show a ninth material, it cost eight scripts' worth of
-- per-frame work whether the panel was open or not, and the hover states were
-- nine lines of Lua per row that a stylesheet does for nothing. `ui.make`
-- reconciles, so a row that stays is the same entity frame to frame and keeps
-- its hover and its keyboard focus.
--
--   I / Esc    open / close
--   ↑ ↓ Enter  the rows are focusable, so the panel works without a mouse

defaults = {
  reach = 11.0,   -- how close a craft has to be to load it from the ground
  counter_reach = 15.0, -- how close to the Commerce Depot its counters serve you
}

-- Published.
open = false
targetId = nil
targetLabel = nil

local el

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- THE CREW, if they're out and about — otherwise nil.
--
-- Deliberately NOT `astro.visible`: planet_camera hides the body whenever the
-- camera lands within 0.7 m of it, which includes every time the wall-clip ray
-- finds a wall behind you — i.e. constantly, while you are inside one of the
-- base buildings or standing beside your own rocket. Gating on visibility
-- switched this panel off exactly where it was wanted.
--
-- `planet_walker.onFoot` is the question that was meant, and it is the ONE
-- place in the game that decides.
local function on_foot()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  return find("Astronaut")
end

-- What's in reach that can take cargo. A craft wins over the warehouse if both
-- are close — you walked to the ship for a reason.
local function find_target(astro)
  if not ref("inventory") then return nil, nil end
  -- A SUPPLY CRATE at arm's length wins: you walked up to it to use it.
  local sc = ref("supply_crates")
  if sc and sc.nearAstro then
    local c = sc.nearAstro(astro, (sc.params and sc.params.reach or 2.4) + 1.0)
    if c then return c.cid, c.name end
  end
  local best, bestd, label = nil, params.reach, nil
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.holdId then
      local d = astro:distanceTo(n)
      if d < bestd then
        best, bestd, label = v.holdId, d, (v.craftName or "craft") .. " hold"
      end
    end
  end
  if best then return best, label end
  -- The depot: planet-parented, so its own coordinates are body-relative and
  -- only become world space through its parent chain. `node:distanceTo` composes
  -- that chain in the engine; a raw .x comparison is off by the planet's orbital
  -- position and never fires (see facility_menu). The reach matches the depot's
  -- own prompt, so the row you can click is the row the building answers to.
  local dep = find("FacDepot")
  if dep and astro:distanceTo(dep) < params.counter_reach then
    return "base", "warehouse"
  end
  return nil, nil
end

-- The vessel script owning a hold id (so a transfer can re-apply its mass).
local function vessel_of(hold)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.holdId == hold then return v end
  end
  return nil
end

-- The bottom line: what just happened, for a few seconds, then back to advice.
local msg, msg_t, msg_bad = "", -100, false
local function say(text, bad)
  msg, msg_t, msg_bad = text, time, bad or false
  -- Every line here is the result of a move: a stack landing, or a refusal.
  local fx = ref("sfx")
  if fx and fx.play then fx.play(bad and "denied" or "bag_move") end
end

-- Buy one piece of gear at the depot's BUY counter. Refused anywhere else:
-- the counter is the only place gear is sold.
atCounter = false
counter = "buy"     -- the counter the depot panel shows: "buy" | "sell"
function buyGear(id)
  local inv = ref("inventory")
  if not (inv and inv.buyGear) then return end
  if not atCounter then
    say("gear is sold at the Commerce Depot's BUY counter", true)
    return false
  end
  local g = inv.GEAR and inv.GEAR[id]
  local ok, why = inv.buyGear("astro", id, 1)
  if ok then
    say(string.format("bought a %s — %d in the pack, on the tool belt", g and g.name or id, inv.gearCount("astro", id)))
  else
    say(string.format("can't buy a %s: %s", g and g.name or id, why or "?"), true)
  end
  return ok
end

-- Sell at the SELL counter: the depot's own sale (facility_menu), so prices,
-- standing, contracts kept back and discovery premiums are the depot's.
function sellOne(mat)
  local fm = ref("facility_menu")
  if not (atCounter and fm and fm.depotSellOne) then return end
  fm.depotSellOne(mat)
  local mats = ref("materials")
  say(string.format("%s sold", (mats and mats.label(mat)) or mat))
end

function sellAll()
  local fm = ref("facility_menu")
  if not (atCounter and fm and fm.depotSell) then return end
  if fm.depotUnload then fm.depotUnload() end
  say(fm.depotSell() or "sold")
end

-- Sell one piece of gear back (the SELL counter's GEAR rows): from the pack
-- or the warehouse, at items.sellPrice. The item in hand goes back to the belt
-- first (item_hand notices it is gone and stows the hand).
function sellGear(cid, id)
  local inv = ref("inventory")
  if not (atCounter and inv and inv.sellItem) then return 0 end
  local n, paid, why = inv.sellItem(cid, id, 1)
  local g = inv.GEAR and inv.GEAR[id]
  if n > 0 then
    local co = ref("company")
    say(string.format("sold a %s for %s", g and g.name or id, (co and co.money and co.money(paid)) or ("$" .. paid)))
  else
    say(string.format("can't sell the %s: %s", g and g.name or id, why or "?"), true)
  end
  return n
end

-- ── moving cargo ────────────────────────────────────────────────────────────

-- Move one stack. Called by a row's click.
function moveStack(mat)
  local inv = ref("inventory")
  if not (inv and targetId) then return end
  local have = inv.count("astro", mat)
  local moved = inv.transfer("astro", targetId, mat, have)
  local mats = ref("materials")
  local nm = (mats and mats.label(mat)) or mat
  if moved == 0 then
    say(string.format("%s won't fit in the %s", nm, targetLabel or "hold"), true)
  elseif moved < have then
    say(string.format("%d of %d %s moved — %s full", moved, have, nm, targetLabel or "hold"), true)
  else
    say(string.format("%d × %s → %s", moved, nm, targetLabel or "hold"))
  end
  local v = vessel_of(targetId)
  if v and v.holdApplyMass then v.holdApplyMass(v.node) end
end

function moveAll()
  local inv = ref("inventory")
  if not (inv and targetId) then return end
  local before = inv.mass("astro")
  local n = inv.transferAll("astro", targetId)
  if n == 0 then
    say((before > 0.05) and ("nothing fits in the " .. (targetLabel or "hold"))
      or "the pack is empty", true)
  else
    local rest = inv.mass("astro") > 0.05
    say(string.format("%d unit(s) → %s%s", n, targetLabel or "hold",
      rest and "  (the rest didn't fit)" or ""), rest)
  end
  local v = vessel_of(targetId)
  if v and v.holdApplyMass then v.holdApplyMass(v.node) end
end

-- ── a supply crate (scripts/supply_crates.lua) ──────────────────────────────
-- At a crate the panel is the crate beside the pack: a click on a pack row
-- puts it in, a click on a crate row takes it out. Items one at a time,
-- materials a stack at a time; what doesn't fit stays where it was.
local function is_crate(cid) return type(cid) == "string" and cid:sub(1, 6) == "crate:" end
local function item_name(inv, id)
  local g = inv and inv.GEAR and inv.GEAR[id]
  return g and g.name or id
end
function putItem(id)
  local inv = ref("inventory")
  if not (inv and targetId and inv.moveItem) then return 0 end
  local n, why = inv.moveItem("astro", targetId, id, 1)
  if n > 0 then say(string.format("%s → %s", item_name(inv, id), targetLabel or "crate"))
  else say(string.format("the %s won't go in: %s", item_name(inv, id), why or "no room"), true) end
  local v = vessel_of(targetId)
  if v and v.holdApplyMass then v.holdApplyMass(v.node) end
  return n
end
function takeItem(id)
  local inv = ref("inventory")
  if not (inv and is_crate(targetId) and inv.moveItem) then return 0 end
  local n, why = inv.moveItem(targetId, "astro", id, 1)
  if n > 0 then say(string.format("took the %s — %s", item_name(inv, id), inv.line("astro")))
  else say(string.format("can't take the %s: %s", item_name(inv, id), why or "no room in the pack"), true) end
  return n
end
function takeStack(mat)
  local inv, mats = ref("inventory"), ref("materials")
  if not (inv and is_crate(targetId)) then return 0 end
  local have = inv.count(targetId, mat)
  local moved = inv.transfer(targetId, "astro", mat, have)
  local nm = (mats and mats.label(mat)) or mat
  if moved == 0 then say(string.format("no room in the pack for %s", nm), true)
  elseif moved < have then say(string.format("%d of %d %s taken — the pack is full", moved, have, nm), true)
  else say(string.format("%d × %s → the pack", moved, nm)) end
  return moved
end
function takeAll()
  local inv = ref("inventory")
  if not (inv and is_crate(targetId)) then return 0 end
  local n, why = inv.moveAllItems(targetId, "astro")
  local m = inv.transferAll(targetId, "astro")
  if n + m == 0 then say(why or "nothing fits in the pack", true)
  else say(string.format("%d item(s), %d unit(s) into the pack%s", n, m, why and ("  ·  " .. why) or ""), why ~= nil) end
  return n + m
end

-- Open on a crate (facility_menu's E prompt, the crate's right-click menu).
crateId = nil
function openCrate(cid)
  open = true
  crateId = cid
  return true
end
function closePanel()
  open = false
  crateId = nil
end

-- ── the screen ──────────────────────────────────────────────────────────────

-- Tier tints the row: the drab stuff reads drab, the good stuff doesn't. These
-- are set on the element rather than in the stylesheet on purpose — a style
-- that named `text_color` would overwrite them every frame (ui-styles.md).
local TIER_INK = {
  [3] = { 1.00, 0.86, 0.55 },
  [2] = { 0.72, 0.96, 0.80 },
}
local TIER_DEFAULT = { 0.78, 0.86, 0.94 }

local function hint_line(inv)
  if time - msg_t < 4.0 and msg ~= "" then return msg, msg_bad end
  -- An EMPTY pack wins over a target in reach. Standing at the depot with
  -- nothing on your back, the panel used to say "click a row to move that
  -- stack" above no rows at all.
  if is_crate(targetId) then
    return "Click a pack row to put it in the crate, a crate row to take it out. E closes.", false
  end
  if inv and inv.isEmpty("astro") and #(inv.gearItems and inv.gearItems("astro") or {}) == 0 then
    return "Empty — dig rock with the Terrain Laser, uproot plants with the Gravity Gun.", false
  end
  if atCounter then
    return counter == "buy" and "Bought gear goes in the pack and onto the tool belt."
      or "Click a row to sell that material; the button sells the lot.", false
  end
  if targetId then
    return "Click a row to move that stack.", false
  end
  return "Unload at a craft's Cargo Bay or the Commerce Depot.", false
end

-- Sizes are the styles' (ui/solar.uistyle.ron); the one row that can wrap —
-- the hint — is full width and "fit" tall.
local W, PAD = 440, 16                       -- the Inventory Panel node's width; the pad
local METER_W = W - (PAD + 2) * 2

local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function stack_row(entry, mats, co)
  local ink = TIER_INK[mats and mats.tier(entry.mat) or 1] or TIER_DEFAULT
  local money = (co and co.money) and co.money(entry.value) or ("$" .. entry.value)
  return {
    "button", key = entry.mat, style = "panel/row", w = "100%", h = 32,
    dir = "row", gap = 10, align = "center",
    -- The tint rides the row and its cells inherit it (they set no colour).
    textR = ink[1], textG = ink[2], textB = ink[3],
    { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end",
      text = string.format("%d ×", entry.n) },
    { "text", key = "name", style = "panel/cell", w = "grow", h = "fit",
      text = mats and mats.label(entry.mat) or entry.mat },
    { "text", key = "kg", style = "panel/cell", w = 64, h = "fit", textAlign = "end",
      text = string.format("%.1f kg", entry.kg) },
    { "text", key = "val", style = "panel/cell", w = 64, h = "fit", textAlign = "end",
      text = money },
    onClicked = function() moveStack(entry.mat) end,
  }
end

-- ── THE ITEM PREVIEW (the BUY counter's detail card, playtest 2026-10-27:
-- "no way to read about or see an item before buying it") ────────────────────
-- The catalogue's method (catalog_panel.lua): ONE render-target camera and the
-- item's own prefab (the model the crew carries) turning on a stand of its
-- own, both on the "viewmodel" render layer, the camera's cullMask that layer
-- alone and no sky, terrain, fog or shadows — the item over a dark ground,
-- 256² at 30 Hz, the camera switched OFF whenever no card shows.
--
-- WHERE THE STAND IS: parented to the home planet (it moves; the planet's
-- frame doesn't rotate, so a planet-local offset is a world direction),
-- 1.5 km over the point straight under the star — always in daylight, so the
-- item is lit by the real sun whatever the hour at the depot — with the
-- camera on the star's side of it, the light over its shoulder.
PREVIEW_TARGET = "itempreview"
local PV = { px = 256, fov = 0.40, bit = 3, layer = "viewmodel", up = 1500 }
-- Each model's largest extent (m), for the framing.
PREVIEW_SIZE = { gravgun = 0.95, laser = 1.05, surveyor = 1.15, repairkit = 0.40, medkit = 0.26,
                 beacon = 1.30, flag = 1.30, rcspack = 0.75, o2tank = 0.70 }
local pv = { cam = nil, making = false, item = nil, id = nil, want = nil, ready = false, spin = 0,
             on = false, dist = 2, planet = nil, frame = nil, frame_t = -10 }
previewId = nil   -- the item on the stand (probes)
shownId = nil     -- the item whose card is up

local function pv_valid(n) return n ~= nil and n.valid ~= false end
local function v3len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function v3unit(x, y, z)
  local l = v3len(x, y, z)
  if l < 1e-9 then return 0, 1, 0 end
  return x / l, y / l, z / l
end
local function v3cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function pv_layer(n, depth)
  depth = depth or 0
  pcall(function() n.layer = PV.layer end)
  if depth < 4 and n.children then
    local ok, kids = pcall(function() return n:children() end)
    if ok and type(kids) == "table" then for _, c in ipairs(kids) do pv_layer(c, depth + 1) end end
  end
end
-- The star (the body with an infinite sphere of influence; sun_flare's rule).
local function star_body()
  local best, bk = nil, -1
  for _, b in ipairs(space.bodies() or {}) do
    local k = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
    if k > bk then best, bk = b, k end
  end
  return best
end
-- The stand's frame (planet-local): its centre, the sun's way, an up and a
-- side. Re-read every few seconds (the planet's orbit turns the sun slowly).
local function pv_frame(astro)
  if pv.frame and (time or 0) - pv.frame_t < 3.0 and pv_valid(pv.planet) then return pv.frame end
  if not (space and space.bodies and astro) then return nil end
  local bn = astro and space.dominant(astro.x, astro.y, astro.z)
  local body = bn and space.body(bn)
  local st = star_body()
  if not (body and st and st.name ~= body.name) then return nil end
  local planet = find(body.name)
  if not planet then return nil end
  local sx, sy, sz = v3unit(st.x - body.x, st.y - body.y, st.z - body.z)
  local s = { sx, sy, sz }
  local t = v3cross(s, { 0, 1, 0 })
  if v3len(t[1], t[2], t[3]) < 0.1 then t = v3cross(s, { 1, 0, 0 }) end
  t = { v3unit(t[1], t[2], t[3]) }
  local up = v3cross(t, s)
  local r = (body.radius or 800) + PV.up
  if pv.planet ~= planet then
    -- a new world: the old stand goes
    if pv_valid(pv.cam) then pv.cam:destroy() end
    if pv_valid(pv.item) then pv.item:destroy() end
    pv.cam, pv.item, pv.id, pv.ready, pv.making = nil, nil, nil, false, false
  end
  pv.planet = planet
  pv.frame = { s = s, t = t, up = up, c = { s[1] * r, s[2] * r, s[3] * r }, body = body.name }
  pv.frame_t = time or 0
  return pv.frame
end
local function pv_camera(F)
  if pv_valid(pv.cam) then return pv.cam end
  if pv.making or not createNode then return nil end
  pv.making = true
  createNode("ItemPreviewCam", pv.planet, function(n)
    pv.making, pv.cam = false, n
    local ok, err = pcall(function()
      n:setCamera { target = PREVIEW_TARGET, width = PV.px, height = PV.px, hz = 30, fovY = PV.fov, active = false,
                    cullMask = 2 ^ PV.bit, sky = false, terrain = false, fog = false, shadows = false }
    end)
    if not ok and log then log("item preview: no render target (" .. tostring(err) .. ")") end
    n.enabled = pv.on
  end)
  return nil
end
local function pv_show(on)
  pv.on = on
  if pv_valid(pv.cam) and pv.cam.enabled ~= on then pv.cam.enabled = on end
  if pv_valid(pv.item) and pv.item.enabled ~= on then pv.item.enabled = on end
end
local function pv_want(id, F)
  if id == pv.id then return end
  pv.id, pv.ready = id, false
  if pv_valid(pv.item) then pv.item:destroy() end
  pv.item = nil
  local I = ref("items")
  local c = I and I.card and I.card(id)
  local prefab = c and c.prefab
  local size = PREVIEW_SIZE[id] or 0.8
  pv.dist = size * 0.62 / math.tan(PV.fov * 0.5)
  if not (prefab and spawn and pv_valid(pv.planet)) then return end
  local body = space.body(F.body)
  if not body then return end
  spawn(prefab, vec3(body.x + F.c[1], body.y + F.c[2], body.z + F.c[3]), function(n)
    if pv.id ~= id or not pv_valid(n) then if pv_valid(n) then n:destroy() end return end
    n.x, n.y, n.z = F.c[1], F.c[2], F.c[3]
    pv_layer(n)
    pv.item, pv.ready, pv.ready_t = n, true, time or 0
    n.enabled = pv.on
  end, { parent = pv.planet, body = false })
end
-- Each frame the card is up: the item turns, the camera holds on it.
local function pv_tick(id, astro, dt)
  previewId = id
  if not id then pv_show(false) return end
  local F = pv_frame(astro)
  if not F then pv_show(false) return end
  pv_camera(F)
  pv_want(id, F)
  pv_show(true)
  pv.spin = (pv.spin + (dt or 0.016) * 0.8) % (2 * math.pi)
  local body = space.body(F.body)
  if not body then return end
  local cx, cy, cz = F.c[1], F.c[2], F.c[3]
  if pv_valid(pv.item) and pv.item.setUp then
    local a = pv.spin
    local w = v3cross(F.up, F.t)
    local fx = F.t[1] * math.cos(a) + w[1] * math.sin(a)
    local fy = F.t[2] * math.cos(a) + w[2] * math.sin(a)
    local fz = F.t[3] * math.cos(a) + w[3] * math.sin(a)
    pv.item.x, pv.item.y, pv.item.z = cx, cy, cz
    pv.item:setUp(vec3(F.up[1], F.up[2], F.up[3]), vec3(fx, fy, fz))
  end
  if pv_valid(pv.cam) then
    -- on the sun's side, a little to one side and above: the light over its shoulder
    local dx, dy, dz = v3unit(F.s[1] * 0.78 + F.t[1] * 0.45 + F.up[1] * 0.32,
                              F.s[2] * 0.78 + F.t[2] * 0.45 + F.up[2] * 0.32,
                              F.s[3] * 0.78 + F.t[3] * 0.45 + F.up[3] * 0.32)
    pv.cam.x, pv.cam.y, pv.cam.z = cx + dx * pv.dist, cy + dy * pv.dist, cz + dz * pv.dist
    if pv.cam.lookAt then
      pcall(pv.cam.lookAt, pv.cam, vec3(body.x + cx, body.y + cy, body.z + cz), vec3(F.up[1], F.up[2], F.up[3]))
    end
  end
end
function previewReady() return pv.ready and pv_valid(pv.cam) and pv.on end
function previewSpin() return pv.spin end

-- The card: the picture, the name and kind, what it is, and its numbers.
detailId = nil      -- the BUY counter row picked (click)
hoverId = nil       -- the BUY counter row under the pointer
local function live_numbers()
  local live = {}
  local sv = ref("surveyor")
  if sv and sv.crewDamage and sv.hitsToKill then
    pcall(function()
      live.dmg30, live.dmg150 = sv.crewDamage(1, 30, "body"), sv.crewDamage(1, 150, "body")
      live.hits30, live.hits150 = sv.hitsToKill(30), sv.hitsToKill(150)
      if sv.partDamage then live.part_dmg = sv.partDamage(1, 30) end
    end)
  end
  local tb = ref("tool_belt")
  local tp = tb and tb.params
  if type(tp) == "table" then
    live.laser_reach, live.grav_reach, live.yield = tp.laser_reach, tp.grav_reach, tp.yield
  end
  return live
end
local function detail_card(inv, co, id)
  local I = ref("items")
  local c = I and I.card and I.card(id, live_numbers())
  if not c then return nil end
  local function money(v) return (co and co.money) and co.money(v) or ("$" .. v) end
  local g = inv.GEAR and inv.GEAR[id] or {}
  local fit, room_why = 1, nil
  if inv.roomForItem then fit, room_why = inv.roomForItem("astro", id, 1) end
  local bal = (co and co.balance) and co.balance() or nil
  local why = (bal and bal < (g.cost or 0) and "not enough money") or (fit < 1 and (room_why or "no room in the pack")) or nil
  local rows = {
    { "row", key = "top", w = "100%", h = "fit", gap = 10, pad = 0, align = "start",
      previewReady() and pv.id == id
        and { "image", key = "img", texture = "rt:" .. PREVIEW_TARGET, w = 168, h = 168 }
        or { "box", key = "img", style = "panel/rule", w = 168, h = 168, opacity = 0.35 },
      { "col", key = "id", w = "grow", h = "fit", gap = 4, pad = 0, align = "stretch",
        { "text", key = "n", style = "panel/heading", w = "100%", h = "fit", wrap = true, text = c.name },
        { "text", key = "k", style = "panel/label", w = "100%", h = "fit", text = string.upper(c.kind or "") },
        { "text", key = "a", style = "panel/body", w = "100%", h = "fit", wrap = true, text = c.about },
        { "text", key = "own", style = "panel/cellMuted", w = "100%", h = "fit",
          text = string.format("%d in the pack  ·  %d at the base", inv.gearCount("astro", id), inv.gearCount("base", id)) } } },
    { "box", key = "r0", style = "panel/rule", w = "100%", h = 1 },
  }
  for i, r in ipairs(c.rows) do
    rows[#rows + 1] = { "row", key = "s" .. i, w = "100%", h = "fit", gap = 10, pad = 0, align = "start",
      { "text", key = "l", style = "panel/label", w = 86, h = "fit", text = string.upper(r[1]) },
      { "text", key = "v", style = "panel/cell", w = "grow", h = "fit", wrap = true, text = r[2] } }
  end
  rows[#rows + 1] = { "button", key = "buy", style = "panel/action", w = "100%", h = 34,
    disabled = why and true or nil, opacity = why and 0.55 or nil,
    text = why and ("Can't buy: " .. why) or string.format("Buy the %s  ·  %s", c.name, money(g.cost or 0)),
    onClicked = function() if not why then buyGear(id) end end }
  return { "col", key = "detail", style = "panel/frame", w = "100%", h = "fit",
           gap = 6, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

-- The card's own screen slot (prefabs/ItemCardHost: pinned just right of
-- this panel, under the same parent), spawned the first time it is needed.
local card_host, card_host_making, card_shown = nil, false, false
local function show_card(node, tree)
  if not (card_host and card_host.valid ~= false) then
    card_host = nil
    if tree and not card_host_making and spawn then
      card_host_making = true
      spawn("ItemCardHost", vec3 and vec3(0, 0, 0) or nil, function(n)
        card_host_making = false
        card_host = n
      end, { parent = node and node.parent or nil })
    end
    return
  end
  local e = card_host:getcomponent("UiElement")
  if tree then
    ui.make(card_host, tree)
    if e then e.visible = true end
    card_shown = true
  elseif card_shown then
    ui.make(card_host, {})
    if e then e.visible = false end
    card_shown = false
  end
end

-- THE COUNTERS, at the depot. Two keys pick the counter; the one in force is
-- latched. BUY lists what the depot stocks; SELL lists everything one press
-- could sell (the depot's own stock list: pack, warehouse, landed holds).
local function counter_rows(inv, co, mats)
  local out = {}
  local function money(v) return (co and co.money) and co.money(v) or ("$" .. v) end
  out[#out + 1] = { "box", key = "crule", style = "panel/rule", w = "100%", h = 1 }
  out[#out + 1] = { "row", key = "counters", w = "100%", h = "fit", gap = 6, pad = 0, align = "center",
    { "text", key = "at", style = "panel/label", w = "grow", h = "fit", text = "COMMERCE DEPOT" },
    { "button", key = "buy", style = "panel/choice", w = 120, h = 28, selected = counter == "buy",
      textAlign = "center", textValign = "center", text = "Buy counter",
      onClicked = function() counter = "buy" end },
    { "button", key = "sell", style = "panel/choice", w = 120, h = 28, selected = counter == "sell",
      textAlign = "center", textValign = "center", text = "Sell counter",
      onClicked = function() counter = "sell" end } }
  if counter == "buy" then
    local bal = (co and co.balance) and co.balance() or nil
    for _, g in ipairs(inv and inv.shopList and inv.shopList() or {}) do
      local fit, room_why = 1, nil
      if inv.roomForItem then fit, room_why = inv.roomForItem("astro", g.id, 1)
      elseif inv.free("astro") + 1e-6 < g.kg then fit = 0 end
      local room = fit >= 1
      local cash = not bal or bal >= g.cost
      local why = (not cash and "not enough money") or (not room and (room_why or "no room in the pack")) or nil
      local picked = (detailId == g.id)
      -- the row reads the card (click, or hover); the small button buys
      out[#out + 1] = { "row", key = "buy_" .. g.id, w = "100%", h = 34, gap = 4, pad = 0, align = "center",
        { "button", key = "pick", style = picked and "panel/rowActive" or "panel/row", selected = picked or nil,
          w = "grow", h = 34, dir = "row", gap = 10, align = "center", opacity = why and 0.7 or nil,
          onClicked = function() detailId = (detailId == g.id) and nil or g.id end,
          onHoverStart = function() hoverId = g.id end,
          onHoverEnd = function() if hoverId == g.id then hoverId = nil end end,
          { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", text = g.name },
          { "text", key = "have", style = "panel/cellMuted", w = "fit", h = "fit",
            text = why or string.format("%d carried", inv.gearCount("astro", g.id)) },
          { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end",
            -- (whole masses as "6 kg", the rest to a decimal: the medkit is 1.5 kg, not "2 kg")
            text = string.format(g.kg % 1 == 0 and "%.0f kg" or "%.1f kg", g.kg) .. (g.L and string.format(" · %.0f L", g.L) or "") },
          { "text", key = "pay", style = "panel/cellStrong", w = 60, h = "fit", textAlign = "end", text = money(g.cost) } },
        { "button", key = "go", style = "panel/secondary", w = 46, h = 34, textAlign = "center", textValign = "center",
          disabled = why and true or nil, opacity = why and 0.45 or nil, text = "buy", tooltip = why,
          onClicked = function() if not why then buyGear(g.id) end end } }
    end
    out[#out + 1] = { "text", key = "buyhint", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = "Point at or click an item to read its card before you buy." }
  else
    local fm = ref("facility_menu")
    local stock = (fm and fm.depotStock) and fm.depotStock() or {}
    if #stock == 0 then
      out[#out + 1] = { "text", key = "nosell", style = "panel/cellMuted", w = "100%", h = 34,
        textAlign = "center", text = "— no materials to sell: not in the pack, the warehouse or a landed hold —" }
    end
    for _, e in ipairs(stock) do
      local tail = e.kept and "for the contract" or (e.first and string.format("NEW · +%s", money(e.bonus)) or "")
      out[#out + 1] = { "button", key = "sell_" .. e.mat, style = "panel/row", w = "100%", h = 30,
        dir = "row", gap = 10, align = "center", disabled = e.kept or nil, opacity = e.kept and 0.55 or nil,
        { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", e.n) },
        { "text", key = "name", style = "panel/cell", w = "grow", h = "fit",
          text = (mats and mats.label(e.mat)) or e.mat },
        { "text", key = "first", style = e.first and "panel/cellStrong" or "panel/cellMuted", w = "fit", h = "fit", text = tail },
        { "text", key = "pay", style = "panel/cellStrong", w = 64, h = "fit", textAlign = "end",
          text = e.kept and "" or money(e.value) },
        { "text", key = "go", style = "panel/cellMuted", w = 30, h = "fit", textAlign = "end", text = e.kept and "" or "sell" },
        onClicked = function() if not e.kept then sellOne(e.mat) end end }
    end
    if #stock > 0 and fm and fm.depotAction then
      out[#out + 1] = { "button", key = "sellall", style = "panel/action", w = "100%", h = 34,
        text = fm.depotAction() or "Sell everything", onClicked = function() sellAll() end }
    end
    -- GEAR, sold back one piece a click at the used-goods price (items
    -- SELL_BACK): the pack's, then the warehouse's spares. Never in "Sell
    -- everything": a tool is sold on purpose or not at all.
    local I = ref("items")
    local gear_rows = {}
    for _, where in ipairs({ { "astro", "pack" }, { "base", "warehouse" } }) do
      for _, g in ipairs(inv.itemList and inv.itemList(where[1]) or {}) do
        local each = I and I.sellPrice and I.sellPrice(g.id) or 0
        if each > 0 then
          gear_rows[#gear_rows + 1] = { "button", key = "sg_" .. where[1] .. "_" .. g.id, style = "panel/row", w = "100%", h = 30,
            dir = "row", gap = 10, align = "center", tooltip = "Sell one back to the depot",
            onClicked = function() sellGear(where[1], g.id) end,
            { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", g.n) },
            { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = g.name },
            { "text", key = "w", style = "panel/cellMuted", w = "fit", h = "fit", text = "in the " .. where[2] },
            { "text", key = "pay", style = "panel/cellStrong", w = 64, h = "fit", textAlign = "end", text = money(each) },
            { "text", key = "go", style = "panel/cellMuted", w = 30, h = "fit", textAlign = "end", text = "sell" } }
        end
      end
    end
    if #gear_rows > 0 then
      out[#out + 1] = { "text", key = "sgH", style = "panel/label", w = "100%", h = "fit",
        text = string.format("GEAR  ·  BOUGHT BACK AT %d%% OF LIST", math.floor(((I and I.SELL_BACK) or 0.6) * 100 + 0.5)) }
      for _, r in ipairs(gear_rows) do out[#out + 1] = r end
    end
  end
  return out
end

-- THE CRATE: its load as a gauge, then what is in it — the gear one row an
-- item, the materials a row a stack — each a button that takes it out.
function crate_rows(inv, mats, co)
  local out = {}
  local cid = targetId
  out[#out + 1] = { "box", key = "xrule", style = "panel/rule", w = "100%", h = 1 }
  out[#out + 1] = { "row", key = "xhead", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
    { "text", key = "t", style = "panel/label", w = "grow", h = "fit", text = string.upper(targetLabel or "supply crate") },
    { "text", key = "m", style = "panel/cellMuted", w = "fit", h = "fit", text = (inv.lineFull or inv.line)(cid) } }
  local cap = inv.cap(cid)
  local frac = cap > 0 and math.max(0, math.min(1, inv.mass(cid) / cap)) or 0
  local vc = inv.volCap and inv.volCap(cid) or math.huge
  if vc < math.huge and vc > 0 then frac = math.max(frac, math.min(1, inv.volume(cid) / vc)) end
  out[#out + 1] = { "row", key = "xmeter", w = "100%", h = 6, radius = 1, pad = 0, gap = 0,
    fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
    { "box", key = "f", w = math.max(2, math.floor(METER_W * frac + 0.5)), h = 6, radius = 1,
      fill = frac > 0.85 and { 1.0, 0.80, 0.28 } or { 0.55, 0.60, 0.42 } } }
  local gear = inv.itemList and inv.itemList(cid) or {}
  local stuff = inv.items(cid)
  if #gear == 0 and #stuff == 0 then
    out[#out + 1] = { "text", key = "xempty", style = "panel/cellMuted", w = "100%", h = 30, textAlign = "center",
      text = "— empty: click a row of the pack above to stow it —" }
  end
  for _, g in ipairs(gear) do
    out[#out + 1] = { "button", key = "xg_" .. g.id, style = "panel/row", w = "100%", h = 30,
      dir = "row", gap = 10, align = "center", tooltip = "Take one into the pack",
      onClicked = function() takeItem(g.id) end,
      { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", g.n) },
      { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = g.name },
      { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end",
        text = string.format("%.1f kg · %.0f L", g.kg, g.L or 0) },
      { "text", key = "go", style = "panel/cellMuted", w = 40, h = "fit", textAlign = "end", text = "take" } }
  end
  for _, e in ipairs(stuff) do
    local ink = TIER_INK[mats and mats.tier(e.mat) or 1] or TIER_DEFAULT
    out[#out + 1] = { "button", key = "xm_" .. e.mat, style = "panel/row", w = "100%", h = 30,
      dir = "row", gap = 10, align = "center", textR = ink[1], textG = ink[2], textB = ink[3],
      tooltip = "Take the stack into the pack (what fits)",
      onClicked = function() takeStack(e.mat) end,
      { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", e.n) },
      { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", text = mats and mats.label(e.mat) or e.mat },
      { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end", text = string.format("%.1f kg", e.kg) },
      { "text", key = "go", style = "panel/cellMuted", w = 40, h = "fit", textAlign = "end", text = "take" } }
  end
  if #gear + #stuff > 0 then
    out[#out + 1] = { "button", key = "xall", style = "panel/secondary", w = "100%", h = 30,
      textAlign = "center", textValign = "center", text = "Take everything that fits",
      onClicked = function() takeAll() end }
  end
  return out
end

local function describe(astro)
  local inv, mats, co, cl = ref("inventory"), ref("materials"), ref("company"), ref("climate")
  local items = inv and inv.items("astro") or {}
  local hint, bad = hint_line(inv)

  local rows = {
    { "row", key = "head", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Inventory" },
      { "text", key = "mass", style = "panel/cellMuted", w = "fit", h = "fit",
        text = "suit pack  " .. (inv and (inv.lineFull or inv.line)("astro") or "") } },
  }
  -- How full, as a shape: the bar goes amber in the last 15 %.
  if inv and inv.cap then
    local cap = inv.cap("astro")
    local frac = cap > 0 and math.max(0, math.min(1, inv.mass("astro") / cap)) or 0
    -- A gauge: a dark groove with an ink bar, caution yellow
    -- when nearly full.
    rows[#rows + 1] = { "row", key = "meter", w = "100%", h = 6, radius = 1, pad = 0, gap = 0,
      fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(2, math.floor(METER_W * frac + 0.5)), h = 6, radius = 1,
        fill = frac > 0.85 and { 1.0, 0.80, 0.28 } or { 0.77, 0.75, 0.68 } } }
  end
  -- Where you are, and what the load would fetch.
  local facts = {}
  local where = cl and cl.surveyLine and cl.surveyLine(astro.x, astro.y, astro.z)
  if where then facts[#facts + 1] = where end
  local worth = inv and inv.totalValue("astro") or 0
  if worth > 0 then
    facts[#facts + 1] = string.format("worth %s at the depot",
      (co and co.money(worth)) or ("$" .. worth))
  end
  if #facts > 0 then
    rows[#rows + 1] = { "text", key = "facts", style = "panel/title", w = "100%", h = "fit",
                        text = table.concat(facts, "   ·   ") }
  end

  if #items == 0 then
    rows[#rows + 1] = { "text", key = "empty", style = "panel/cellMuted", w = "100%",
      h = 40, textAlign = "center", text = "— nothing in the pack —" }
  else
    rows[#rows + 1] = { "row", key = "cols", w = "100%", h = "fit", gap = 10, pad = 0,
      { "box", key = "p", w = 42, h = 1 },
      { "text", key = "a", style = "panel/label", w = "grow", h = "fit", text = "Material" },
      { "text", key = "b", style = "panel/label", w = 64, h = "fit", textAlign = "end", text = "Mass" },
      { "text", key = "c", style = "panel/label", w = 72, h = "fit", textAlign = "end", text = "Value" } }
  end

  -- One row per stack, however many there are. `key` is the material id, so a
  -- stack that survives a transfer keeps its element — and with it the row you
  -- were hovering or had focused.
  rows[#rows + 1] = { "col", key = "stacks", w = "100%", h = "fit", gap = 4, pad = 0,
    items = items, function(entry) return stack_row(entry, mats, co) end }

  -- GEAR: what the crew carries to use, not to sell — the belt's slots, and
  -- what is worn (the RCS Pack, Oxygen Tanks: carried is enough).
  local gear = (inv and inv.gearItems) and inv.gearItems("astro") or {}
  if #gear > 0 then
    local vol = (inv.volume and inv.volCap) and string.format("  ·  %.0f / %.0f L", inv.volume("astro"), inv.volCap("astro")) or ""
    rows[#rows + 1] = { "text", key = "gearH", style = "panel/label", w = "100%", h = "fit", text = "GEAR  ·  ON THE BELT OR WORN" .. vol }
    for _, g in ipairs(gear) do
      local about = inv.GEAR[g.id] and inv.GEAR[g.id].about or ""
      local what = g.kind == "worn" and "worn" or (g.tool and "tool" or "")
      local into = is_crate(targetId)
      rows[#rows + 1] = { into and "button" or "row", key = "gear_" .. g.id, style = "panel/row", w = "100%", h = 32,
        dir = "row", gap = 10, align = "center",
        onClicked = into and function() putItem(g.id) end or nil,
        tooltip = into and ("Put one in the " .. (targetLabel or "crate")) or nil,
        { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end",
          text = (g.tool and g.n == 1) and "" or string.format("%d ×", g.n) },
        { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = g.name .. "  ·  " .. about },
        { "text", key = "w", style = "panel/cellMuted", w = 40, h = "fit", textAlign = "end", text = into and "→ in" or what },
        { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end",
          text = g.L and string.format("%.1f kg · %.0f L", g.kg, g.L) or string.format("%.1f kg", g.kg) } }
      -- each Oxygen Tank's air (each rifle's cell), fullest first
      local I = ref("items")
      local cellish = I and I.def and I.def(g.id) and I.def(g.id).fill and I.def(g.id).fill.what == "cell"
      if g.fills and g.fillCap and cellish then
        local lv = {}
        for i = #g.fills, 1, -1 do lv[#lv + 1] = string.format("%.0f%%", 100 * g.fills[i] / g.fillCap) end
        rows[#rows + 1] = { "row", key = "fill_" .. g.id, w = "100%", h = 22, gap = 10, pad = 0, align = "center",
          { "box", key = "p", w = 34, h = 1 },
          { "text", key = "t", style = "panel/cellMuted", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
            text = string.format("cell  ·  %s  ·  recharges aboard a craft and at the base", table.concat(lv, " · ")) } }
      elseif g.fills and g.fillCap then
        local lv = {}
        for i = #g.fills, 1, -1 do
          local f = g.fills[i]
          lv[#lv + 1] = f <= 0 and "empty" or string.format("%.0f min", f / 60)
        end
        rows[#rows + 1] = { "row", key = "fill_" .. g.id, w = "100%", h = 22, gap = 10, pad = 0, align = "center",
          { "box", key = "p", w = 34, h = 1 },
          { "text", key = "t", style = "panel/cellMuted", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
            text = string.format("air  ·  %s  ·  %.0f of %.0f min  ·  refill aboard, at a locker or at the base",
              table.concat(lv, " · "), (g.fill or 0) / 60, #g.fills * g.fillCap / 60) } }
      end
    end
  end

  if is_crate(targetId) then
    for _, r in ipairs(crate_rows(inv, mats, co)) do rows[#rows + 1] = r end
  end

  if atCounter then
    for _, r in ipairs(counter_rows(inv, co, mats)) do rows[#rows + 1] = r end
    -- the item card, floating beside the panel while a BUY row is read
    local id = (counter == "buy") and (hoverId or detailId) or nil
    shownId = id
    shownCard = id and detail_card(inv, co, id) or nil
  else
    shownId, shownCard = nil, nil
  end

  -- The one primary action, and only when there is somewhere for it to go.
  if targetId and not atCounter then
    rows[#rows + 1] = { "button", key = "all", style = "panel/action", w = "100%",
      h = 34, text = string.format(is_crate(targetId) and "Stow all materials  →  %s" or "Transfer all  →  %s", targetLabel or "hold"),
      onClicked = function() moveAll() end }
  end

  rows[#rows + 1] = { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 }
  -- The hint wraps in its own column and the way out sits beside it, so the
  -- close keys never end up as a stray "close." on a line of their own.
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = "fit", gap = 12, pad = 0, align = "start",
    { "text", key = "hint", style = bad and "panel/hintWarn" or "panel/hint", w = "grow", h = "fit",
      wrap = true, text = hint },
    { "text", key = "close", style = "panel/hint", w = "fit", h = "fit", text = "I / Esc  close" } }

  return { "col", key = "panel", style = "panel/frame", w = "100%",
           dir = "col", gap = 8, pad = PAD + 2, align = "start",
           items = rows, function(row) return row end }
end

-- ── driver ──────────────────────────────────────────────────────────────────

-- Open the pack at a counter (the depot panel's "Buy & sell counters" key).
function openCounters(which)
  open = true
  if which == "sell" or which == "buy" then counter = which end
end

-- The time this panel last closed on Esc (see pause_menu's Esc ladder).
escTakenAt = -1

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
  open = false
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local astro = on_foot()
  if not astro then
    -- (No separate loading check: `onFoot` is already false while the world
    -- streams in.)
    open = false
    el.visible = false
    pv_tick(nil)
    shownCard = nil
    pcall(show_card, node, nil)
    return
  end
  -- TAB, because Tab is what a player reaches for to open a bag — Minecraft,
  -- Terraria, Valheim, Don't Starve. This game shipped on `I` only because the
  -- editor was swallowing Tab before the game ever saw it (floptle/0084), so
  -- `input.pressed("tab")` had been false for the life of the project and there
  -- was nothing to detect. v0.33.0 hands it back. `I` still works.
  if input.pressed("i") or input.pressed("tab") then open = not open end
  if input.pressed("escape") and open then
    open = false
    escTakenAt = time -- pause_menu reads this: the same Esc must not also pause
  end
  -- Not while the game is paused: the menu owns Esc and the pointer, and a bag
  -- opening behind it is a bag you cannot see or close.
  local pm = ref("pause_menu")
  if pm and pm.open then open = false end
  el.visible = open
  if not open then
    targetId, targetLabel, atCounter = nil, nil, false
    crateId, hoverId, shownId = nil, nil, nil
    pv_tick(nil)
    shownCard = nil
    pcall(show_card, node, nil)
    -- A closed panel costs nothing: no target search, no screen described.
    return
  end
  -- The pointer belongs to the panel while the panel is up — v0.26.0 made the
  -- editor's cursor trap re-evaluate every frame, so asking here is enough.
  input.setMouseLocked(false)

  targetId, targetLabel = find_target(astro)
  atCounter = targetId == "base"
  -- Described every frame: the heading carries a live mass and a live valuation
  -- and both change as you mine. `ui.make` RECONCILES rather than rebuilds, so
  -- the cost is one table walk and the rows keep their hover and focus.
  ui.make(node, describe(astro))
  pcall(show_card, node, shownCard)
  -- (a preview that fails must never take the panel with it)
  local okp, perr = pcall(pv_tick, shownId, astro, dt)
  if not okp and not pv.err then pv.err = true; if log then log("item preview: " .. tostring(perr)) end end
end
