-- INVENTORY — every container in the game: the suit you carry ore home in, the
-- cargo hold you fly it back in, and the warehouse it gets sold out of.
--
-- A container is a bare id and two bags of counts: MATERIALS (`inv.<cid>`)
-- and ITEMS (`inv.gear.<cid>`, the things a crew member carries and uses —
-- scripts/items.lua is their registry). The kinds:
--
--   "crew:<id>"    a crew member's suit pack — mass- and bulk-limited; this
--                  is the one that makes a full load a DECISION
--   "astro"        an ALIAS: the pack of the crew member you control on foot
--                  (or, with nobody on foot, the commander of the craft you
--                  fly). Before the crew roster exists it is its own pack.
--   "locker:<n>"   a Stowage Locker part (its number rides the part's state)
--   "hold:<ship>"  a vessel's cargo holds, pooled (capacity = its Cargo Bay
--                  parts; the vessel registers it when it spawns)
--   "base"         the home warehouse = the VAB's stock; effectively unlimited
--   "salvage:<id>" a dropped pack lying in the world (scripts/salvage.lua)
--   "crate:<n>"    a supply crate round the base (scripts/supply_crates.lua):
--                  400 kg, 480 L (items.CRATE_KG, VOL.crate)
--
-- TWO LIMITS. Kilograms bind everything (materials weigh what materials.lua
-- says, items what items.lua says). Litres bind ITEMS only: a pack is 60 L, a
-- locker 120 L, a hold 1000 L per Cargo Bay — without bulk a pack fits nine
-- beacons and a 2.4 m flag pole. `add`/`addItem` are allowed to accept PART
-- of an offer and say why the rest didn't go: silently voiding it, or letting
-- the pack go over, are both worse than an honest partial.
--
-- All state lives in `save.*`: containers survive the builder → system scene
-- hop, ride the save slot, and are what a "bring it home" loop is measured
-- against. EVERY public function resolves "astro" first (`resolve`), so the
-- objectives, salvage, the depot and the mining code that say "astro" keep
-- meaning "the pack of whoever is out there".
--
--     local inv = findScript("inventory")
--     inv.add("astro", "iron", 6)                    -- → units actually taken
--     inv.moveItem("locker:3", "astro", "repairkit", 1)  -- → n moved, why
--     inv.mass("astro"), inv.cap("astro"), inv.volume("astro"), inv.volCap("astro")

defaults = {
  -- What an astronaut can carry in the suit pack. This number and the laser's
  -- `yield` are one decision, not two: a pack should be about one good tunnel's
  -- work. The tools weigh in it (6 + 8 kg) and every hire is issued both, so
  -- a crew member who carries both mines 76 kg a trip and one who leaves them
  -- to a crewmate carries the full 90: who carries the tools is a choice.
  suit_kg = 90.0,
  base_kg = 1000000,  -- the home warehouse: a number, but not one you'll hit
}

local function mats()
  return findScript("materials")
end

local function kg_of(mat)
  local m = mats()
  return (m and m.kg(mat)) or 1.0
end

-- ── the item registry (scripts/items.lua) ──────────────────────────────────
-- Found as a script (the scene's Items node, or the ItemsLib this spawns when
-- the scene has none). A luajit test that loads this file alone gets the
-- registry from disk, so every harness that weighs a pack keeps working.
GEAR = {}            -- the old name of items.ITEMS, kept as an alias for one release
local I_ref, I_spawned, I_disk = nil, false, nil
PENDING_ISSUE = {}
local function registry()
  if I_ref and I_ref.valid ~= false then return I_ref end
  I_ref = findScript and findScript("items") or nil
  if I_ref then
    GEAR = I_ref.ITEMS or GEAR
    -- an issue asked for before the registry was in the scene is done now
    local p = PENDING_ISSUE
    PENDING_ISSUE = {}
    for cid in pairs(p) do issueKit(cid) end
    return I_ref
  end
  if I_disk then return I_disk end
  if loadfile and setfenv then
    for _, p in ipairs({ "solar/scripts/items.lua", "scripts/items.lua", "../Solar/scripts/items.lua" }) do
      local f = loadfile(p)
      if f then
        local env = setmetatable({}, { __index = _G })
        setfenv(f, env)
        if pcall(f) and env.ITEMS then
          I_disk = env
          GEAR = env.ITEMS
          return I_disk
        end
      end
    end
  end
  if spawn and vec3 and not I_spawned then
    I_spawned = true
    pcall(spawn, "ItemsLib", vec3(0, 0, 0))
  end
  return nil
end
local function idef(id)
  local I = registry()
  return I and I.ITEMS[id] or nil
end
local function ikg(id) local d = idef(id); return d and d.kg or 1.0 end
local function iL(id) local d = idef(id); return d and d.L or 1.0 end

-- ── the "astro" alias ──────────────────────────────────────────────────────
-- crew.lua (the roster) is asked who is on foot; with nobody bound to the
-- avatar, the commander of the craft being flown — so a pod's E-to-load-cargo
-- still finds a pack. No roster in the scene: "astro" is its own container.
local crew_ref, crew_miss = nil, -1e9
local function crew()
  if crew_ref and crew_ref.valid ~= false then return crew_ref end
  local now = time or 0
  if now - crew_miss < 2.0 and now >= crew_miss then return nil end
  crew_ref = findScript and findScript("crew") or nil
  if not crew_ref then crew_miss = now end
  return crew_ref
end

function packOf(id)
  local c = crew()
  if c and c.packOf then
    local ok, p = pcall(c.packOf, id)
    if ok and p then return p end
  end
  return "crew:" .. tostring(id)
end

function resolve(cid)
  if cid ~= "astro" then return cid end
  local c = crew()
  if not (c and c.activeId) then return "astro" end
  local ok, id = pcall(c.activeId)
  id = ok and id or nil
  if not id then
    for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
      if v.piloting and v.commander then
        local okc, cmd = pcall(v.commander)
        if okc and cmd then id = cmd break end
      end
    end
  end
  if not id then return "astro" end
  return packOf(id)
end
local R = resolve

local function is_pack(cid) return cid == "astro" or cid:sub(1, 5) == "crew:" end

local function bag(cid)
  return save.get("inv." .. cid) or {}
end

local function put(cid, b)
  -- Empty slots are removed rather than kept at zero: a bag is a small save
  -- value (≤1 KB), and zero rows would pad both the file and every panel.
  local out = {}
  for k, v in pairs(b) do
    if (v or 0) > 0 then out[k] = math.floor(v) end
  end
  -- An emptied bag is written as `{}`, not nil: the save store takes VALUES
  -- (numbers, strings, bools, small tables) — the rest of the project writes
  -- `false`/`{}` for "cleared" and nothing deletes a key.
  save.set("inv." .. cid, out)
end

-- ── capacity ────────────────────────────────────────────────────────────────
-- Suit and warehouse are fixed by the params; a vessel registers its hold when
-- it spawns (the sum of its Cargo Bay parts), so capacity follows the craft you
-- actually built rather than a number kept in two places.

function setCap(cid, kilos)
  cid = R(cid)
  local caps = save.get("inv.cap") or {}
  caps[cid] = math.max(0, kilos or 0)
  save.set("inv.cap", caps)
end

function cap(cid)
  cid = R(cid)
  if is_pack(cid) then return params.suit_kg end
  if cid == "base" then return params.base_kg end
  local caps = save.get("inv.cap") or {}
  if caps[cid] then return caps[cid] end
  -- a base supply crate (scripts/supply_crates.lua): the registry's size
  if cid:sub(1, 6) == "crate:" then
    local I = registry()
    return (I and I.CRATE_KG) or 400
  end
  return 0
end

function mass(cid)
  cid = R(cid)
  local total = 0
  for mat, n in pairs(bag(cid)) do total = total + kg_of(mat) * n end
  return total + itemMass(cid)
end

function free(cid)
  cid = R(cid)
  return math.max(0, cap(cid) - mass(cid))
end

-- ── contents ────────────────────────────────────────────────────────────────

function count(cid, mat)
  return bag(R(cid))[mat] or 0
end

-- No materials in it. (Items are asked about with `itemList`.)
function isEmpty(cid)
  return next(bag(R(cid))) == nil
end

-- Contents in the registry's stable order, with the numbers a panel wants.
function items(cid)
  cid = R(cid)
  local b, m = bag(cid), mats()
  local out = {}
  local order = m and m.list() or nil
  if order then
    for _, mat in ipairs(order) do
      local n = b[mat]
      if n and n > 0 then
        out[#out + 1] = { mat = mat, n = n, kg = kg_of(mat) * n,
                          value = (m and m.valueOf(mat, n)) or 0 }
      end
    end
  else
    for mat, n in pairs(b) do
      out[#out + 1] = { mat = mat, n = n, kg = kg_of(mat) * n, value = 0 }
    end
    table.sort(out, function(a, c) return a.mat < c.mat end)
  end
  return out
end

function totalValue(cid)
  cid = R(cid)
  local m = mats()
  if not m then return 0 end
  local v = 0
  for mat, n in pairs(bag(cid)) do v = v + m.valueOf(mat, n) end
  return math.floor(v)
end

-- ── moving things ───────────────────────────────────────────────────────────

-- How many units of `mat` would fit right now. Zero-mass materials would divide
-- by nothing, so they're treated as weightless-but-finite (the offer, whole).
function roomFor(cid, mat, want)
  cid = R(cid)
  local k = kg_of(mat)
  if k <= 0 then return want or 0 end
  return math.min(want or 0, math.floor(free(cid) / k + 1e-9))
end

-- Add up to `n` units. Returns how many actually went in — callers are expected
-- to use it (a mining tool reports the shortfall; a transfer leaves the rest
-- where it was).
function add(cid, mat, n)
  cid = R(cid)
  n = math.floor(n or 0)
  if n <= 0 or not mat then return 0 end
  local take = roomFor(cid, mat, n)
  if take <= 0 then return 0 end
  local b = bag(cid)
  b[mat] = (b[mat] or 0) + take
  put(cid, b)
  -- First sight of a material anywhere is a discovery; research reads this set.
  local seen = save.get("inv.seen") or {}
  if not seen[mat] then
    seen[mat] = true
    save.set("inv.seen", seen)
    local m = mats()
    log("NEW MATERIAL: " .. ((m and m.label(mat)) or mat))
  end
  return take
end

-- Remove up to `n`. Returns how many came out.
function remove(cid, mat, n)
  cid = R(cid)
  n = math.floor(n or 0)
  if n <= 0 then return 0 end
  local b = bag(cid)
  local have = b[mat] or 0
  local took = math.min(have, n)
  if took <= 0 then return 0 end
  b[mat] = have - took
  put(cid, b)
  return took
end

-- Move what fits. Nothing is destroyed in transit: whatever the destination
-- can't take stays in the source.
function transfer(from, to, mat, n)
  from, to = R(from), R(to)
  n = math.min(math.floor(n or 0), count(from, mat))
  if n <= 0 then return 0 end
  local moved = add(to, mat, n)
  if moved > 0 then remove(from, mat, moved) end
  return moved
end

-- Every MATERIAL that fits (items stay: a "transfer all" never posts the
-- crew's kit into a cargo hold — `moveAllItems` is the deliberate version).
function transferAll(from, to)
  from, to = R(from), R(to)
  local moved = 0
  for _, it in ipairs(items(from)) do
    moved = moved + transfer(from, to, it.mat, it.n)
  end
  return moved
end

function clear(cid)
  save.set("inv." .. R(cid), {})
end

-- Have we ever held this material? (The discovery set — research + the depot's
-- "first sale" bonus read it.)
function seen(mat)
  local s = save.get("inv.seen") or {}
  return s[mat] == true
end

function seenList()
  local s = save.get("inv.seen") or {}
  local m = mats()
  local out = {}
  for _, id in ipairs(m and m.list() or {}) do
    if s[id] then out[#out + 1] = id end
  end
  return out
end

-- ── items ───────────────────────────────────────────────────────────────────
-- EQUIPMENT, not cargo: what the crew carries to USE, kept apart from the
-- material bag so the depot never sells it and a "transfer all" never posts
-- it into a cargo hold. THE TOOL BELT IS BUILT FROM THIS: every holdable item
-- in the pack is a slot on the hotbar (items.belt), so a beacon is on the belt
-- while you carry one and gone when the last is planted. Tools have mass now
-- and can be left in a locker; the standard issue gives every crew member
-- both, once.

local function gear_bag(cid)
  return save.get("inv.gear." .. cid) or {}
end

local function gear_put(cid, b)
  local out = {}
  for k, v in pairs(b) do if (v or 0) > 0 then out[k] = math.floor(v) end end
  save.set("inv.gear." .. cid, out)
end

-- ── item state: a level per piece (the Oxygen Tank's air) ──────────────────
-- `inv.fill.<cid>` = { [id] = { level, level, … } }, one number per piece of
-- an item whose registry entry has `fill = { cap }`. Kept beside the counts
-- and moved with the pieces; a list that disagrees with its count (an old
-- save, a cheat) is squared up: missing pieces are full, extras dropped.
local function fill_cap(id) local d = idef(id); return d and d.fill and d.fill.cap or nil end
local function fill_all(cid) local t = save.get("inv.fill." .. cid); return type(t) == "table" and t or {} end
local function fill_put(cid, id, list)
  local t = fill_all(cid)
  t[id] = (#list > 0) and list or nil
  save.set("inv.fill." .. cid, t)
end
function fills(cid, id)
  cid = R(cid)
  local fc = fill_cap(id)
  if not fc then return {} end
  local n = (gear_bag(cid))[id] or 0
  local src = fill_all(cid)[id] or {}
  local out = {}
  for i = 1, n do out[i] = tonumber(src[i]) or fc end
  return out
end
-- Draw `amount` from the pieces' levels (the registry's draw order) → drawn.
function drawFill(cid, id, amount)
  cid = R(cid)
  local list = fills(cid, id)
  if #list == 0 then return 0 end
  local reg = registry()
  local got
  if reg and reg.drawFrom then got = reg.drawFrom(list, amount)
  else
    got = 0
    table.sort(list)
    for i = 1, #list do
      local t = math.min(list[i], amount - got); list[i] = list[i] - t; got = got + t
    end
  end
  fill_put(cid, id, list)
  return got
end
-- Every piece full → the amount added.
function refill(cid, id)
  cid = R(cid)
  local fc = fill_cap(id)
  if not fc then return 0 end
  local list = fills(cid, id)
  local add = 0
  for i = 1, #list do add = add + (fc - list[i]); list[i] = fc end
  fill_put(cid, id, list)
  return add
end

-- Bulk capacity in litres (items only).
function setVolCap(cid, litres)
  cid = R(cid)
  local caps = save.get("inv.vcap") or {}
  caps[cid] = litres and math.max(0, litres) or nil
  save.set("inv.vcap", caps)
end

function volCap(cid)
  cid = R(cid)
  local I = registry()
  local V = (I and I.VOL) or { pack = 60, locker = 120, bay = 1000 }
  if is_pack(cid) then return V.pack end
  if cid == "base" or cid:sub(1, 8) == "salvage:" then return math.huge end
  local caps = save.get("inv.vcap") or {}
  if caps[cid] then return caps[cid] end
  if cid:sub(1, 7) == "locker:" then return V.locker end
  if cid:sub(1, 6) == "crate:" then return V.crate or 480 end
  if cid:sub(1, 5) == "hold:" then
    -- a hold's litres follow its Cargo Bays (250 kg each): 1000 L a bay
    return math.max(1, math.ceil(cap(cid) / 250 - 1e-9)) * V.bay
  end
  return math.huge
end

function volume(cid)
  cid = R(cid)
  local v = 0
  for id, n in pairs(gear_bag(cid)) do v = v + iL(id) * n end
  return v
end

function itemMass(cid)
  cid = R(cid)
  local t = 0
  for id, n in pairs(gear_bag(cid)) do t = t + ikg(id) * n end
  return t
end
gearMass = itemMass

function itemCount(cid, id)
  if not I_ref then registry() end
  return gear_bag(R(cid))[id] or 0
end
gearCount = itemCount

-- How many of `id` fit now (up to `want`, default as many as fit), and why
-- not more. → n, why
function roomForItem(cid, id, want)
  cid = R(cid)
  if not idef(id) and registry() then return 0, "no such item" end
  local k, L = ikg(id), iL(id)
  local by_kg = k > 0 and math.floor(free(cid) / k + 1e-9) or math.huge
  local vc = volCap(cid)
  local by_L = (L > 0 and vc < math.huge) and math.floor((vc - volume(cid)) / L + 1e-9) or math.huge
  by_L = math.max(0, by_L)
  local fit = math.min(by_kg, by_L)
  want = want or fit
  if fit >= want then return want, nil end
  local why
  -- the reason is the room LEFT once what fits has gone in
  fit = math.max(0, fit)
  if by_kg <= by_L then why = string.format("no room: %.0f kg free", math.max(0, free(cid) - fit * k))
  else why = string.format("no room: %.0f L free", math.max(0, vc - volume(cid) - fit * L)) end
  return math.max(0, fit), why
end

-- Add up to n (mass and litres permitting). → n_in, why (the shortfall's
-- reason). opts.force skips the limits (the standard issue, a salvage drop,
-- a migration: things that already exist and must go somewhere).
function addItem(cid, id, n, opts)
  cid = R(cid)
  n = math.floor(n or 1)
  if n <= 0 then return 0, "nothing to add" end
  if not idef(id) and registry() then return 0, "no such item" end
  local fit, why = n, nil
  if not (opts and opts.force) then fit, why = roomForItem(cid, id, n) end
  if fit <= 0 then return 0, why end
  local fc = fill_cap(id)
  local list = fc and fills(cid, id) or nil
  local b = gear_bag(cid)
  b[id] = (b[id] or 0) + fit
  gear_put(cid, b)
  if fc then
    -- each new piece brings its own level (a move hands them over); a new
    -- one is full, and the warehouse fills whatever arrives there
    local given = opts and opts.fills or {}
    for i = 1, fit do
      local f = given[i] or fc
      if cid == "base" then f = fc end
      list[#list + 1] = math.max(0, math.min(fc, f))
    end
    fill_put(cid, id, list)
  end
  return fit, why
end
-- (the old name answered only the count)
function addGear(cid, id, n) return (addItem(cid, id, n)) end

-- Remove up to n. → n removed, { the removed pieces' levels } (for items with
-- a fill: the FULLEST pieces leave first — you take the best tank out of a
-- locker, and the suit draws the emptiest, see items.drawFrom).
function removeItem(cid, id, n)
  cid = R(cid)
  n = math.floor(n or 1)
  local fc = fill_cap(id)
  local list = fc and fills(cid, id) or nil
  local b = gear_bag(cid)
  local took = math.min(b[id] or 0, n)
  if took <= 0 then return 0, {} end
  b[id] = b[id] - took
  gear_put(cid, b)
  local out = {}
  if fc then
    table.sort(list)
    for _ = 1, took do out[#out + 1] = table.remove(list) end
    fill_put(cid, id, list)
  end
  return took, out
end
removeGear = removeItem

-- MOVE n of an item from one container to another: what fits goes, the rest
-- stays where it was, and the reason comes back. → n_moved, why
function moveItem(from, to, id, n, opts)
  from, to = R(from), R(to)
  n = math.floor(n or 1)
  if from == to then return 0, "it's already there" end
  if not idef(id) and registry() then return 0, "no such item" end
  local have = itemCount(from, id)
  if have <= 0 then return 0, "none to move" end
  if to:sub(1, 8) == "salvage:" and not (opts and opts.force) then
    return 0, "a salvage crate only gives things back"
  end
  local want = math.min(n, have)
  local fit, why = want, nil
  if not (opts and opts.force) then fit, why = roomForItem(to, id, want) end
  if fit <= 0 then return 0, why end
  local took, levels = removeItem(from, id, fit)
  local moved = addItem(to, id, took, { force = true, fills = levels })
  if moved < n and not why then why = string.format("only %d to move", have) end
  return moved, why
end

-- Every item that fits (a death drop, a recovery, a locker emptied at the
-- warehouse). → n moved, why (the first shortfall)
function moveAllItems(from, to, opts)
  from, to = R(from), R(to)
  local total, first_why = 0, nil
  for id, n in pairs(gear_bag(from)) do
    local m, why = moveItem(from, to, id, n, opts)
    total = total + m
    if m < n and not first_why then first_why = why end
  end
  return total, first_why
end

-- { { id, name, n, kg, L, kind, tool } } in the registry's (belt) order.
function itemList(cid)
  cid = R(cid)
  local b, out = gear_bag(cid), {}
  local I = registry()
  local order = I and I.ids() or {}
  local seen_ = {}
  for _, id in ipairs(order) do seen_[id] = true end
  local extra = {}
  for id in pairs(b) do if not seen_[id] then extra[#extra + 1] = id end end
  table.sort(extra)
  for _, id in ipairs(extra) do order[#order + 1] = id end
  for _, id in ipairs(order) do
    local n = b[id] or 0
    if n > 0 then
      local d = idef(id) or {}
      local e = { id = id, name = d.name or id, n = n, kg = ikg(id) * n, L = iL(id) * n,
                  kind = d.kind or "item", tool = d.kind == "tool" }
      local fc = fill_cap(id)
      if fc then
        e.fills, e.fillCap = fills(cid, id), fc
        table.sort(e.fills)
        local t = 0
        for _, f in ipairs(e.fills) do t = t + f end
        e.fill = t
      end
      out[#out + 1] = e
    end
  end
  return out
end
gearItems = itemList

-- What the depot's BUY counter stocks, in a stable order.
function shopList()
  local I = registry()
  return I and I.shopList() or {}
end

-- Buy n of an item into a container: all or nothing. → ok, why
function buyItem(cid, id, n)
  cid = R(cid)
  local g = idef(id)
  n = math.floor(n or 1)
  if not g or n <= 0 or not g.cost then return false, "nothing to buy" end
  local fit, why = roomForItem(cid, id, n)
  if fit < n then return false, why or "no room in the pack" end
  local co = findScript and findScript("company")
  local price = g.cost * n
  if co and co.spend then
    if not co.spend(price, "gear: " .. g.name) then return false, "not enough money" end
  end
  addItem(cid, id, n, { force = true })
  return true, nil
end
buyGear = buyItem

-- SELL n of an item from a container back to the depot, at the registry's
-- used-goods price (items.sellPrice: 60 % of list). → n sold, $ paid, why
function sellItem(cid, id, n)
  cid = R(cid)
  local g = idef(id)
  n = math.floor(n or 1)
  if not g or n <= 0 then return 0, 0, "nothing to sell" end
  local I = registry()
  local each = (I and I.sellPrice) and I.sellPrice(id) or math.floor((g.cost or 0) * 0.6)
  if each <= 0 then return 0, 0, "the depot won't buy that" end
  local took = removeItem(cid, id, math.min(n, itemCount(cid, id)))
  if took <= 0 then return 0, 0, "none to sell" end
  local paid = each * took
  local co = findScript and findScript("company")
  if co and co.earn then co.earn(paid, string.format("sold %s%s", took > 1 and (took .. " × ") or "", g.name)) end
  return took, paid, nil
end

-- THE STANDARD ISSUE (items with `issue`, the two tools today), free and
-- once: a new crew member is issued it when hired; an old save's pack is
-- topped up the first time it is asked (and from then on a tool left in a
-- locker stays in the locker). → the ids issued
function issueKit(cid, opts)
  cid = R(cid)
  local I = registry()
  if not I then PENDING_ISSUE[cid] = true return {} end
  local key = "inv.issued." .. cid
  if save.get(key) == true and not (opts and opts.again) then return {} end
  local got = {}
  for _, id in ipairs(I.issueList()) do
    if itemCount(cid, id) < 1 then
      addItem(cid, id, 1, { force = true })
      got[#got + 1] = id
    end
  end
  save.set(key, true)
  return got
end
-- (the old name: every scene start asked it; it is the once-only issue now)
function ensureKit(cid) return #issueKit(cid) > 0 end

-- A pack changing owner (the crew migration: the old "astro" pack becomes
-- crew member #1's). Both bags and the issue stamp move; the old keys are
-- written empty (the store has no delete for them). → true if anything moved
function adoptPack(from, to)
  if from == to then return false end
  local m, g = save.get("inv." .. from), save.get("inv.gear." .. from)
  local moved = false
  if type(m) == "table" and next(m) then
    local b = bag(to)
    for k, v in pairs(m) do b[k] = (b[k] or 0) + v end
    put(to, b); moved = true
  end
  if type(g) == "table" and next(g) then
    local b = gear_bag(to)
    for k, v in pairs(g) do b[k] = (b[k] or 0) + v end
    gear_put(to, b); moved = true
  end
  local f = save.get("inv.fill." .. from)
  if type(f) == "table" and next(f) then
    local t = fill_all(to)
    for id, list in pairs(f) do
      local cur = t[id] or {}
      for _, v in ipairs(list) do cur[#cur + 1] = v end
      t[id] = cur
    end
    save.set("inv.fill." .. to, t)
    save.set("inv.fill." .. from, {})
  end
  if save.get("inv.issued." .. from) == true then save.set("inv.issued." .. to, true) end
  save.set("inv." .. from, {})
  save.set("inv.gear." .. from, {})
  return moved
end

-- A one-line summary for HUDs: "12.4 / 90 kg".
function line(cid)
  cid = R(cid)
  return string.format("%.1f / %.0f kg", mass(cid), cap(cid))
end

-- …and with the bulk, for the pack panel and the menus: "12.4 / 90 kg · 22 / 60 L".
function lineFull(cid)
  cid = R(cid)
  local vc = volCap(cid)
  if vc == math.huge then return line(cid) end
  return string.format("%s  ·  %.0f / %.0f L", line(cid), volume(cid), vc)
end

function start(node)
  registry()
end
