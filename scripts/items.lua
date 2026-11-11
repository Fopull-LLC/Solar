-- ITEMS — every physical thing a crew member can carry, as data.
--
-- One registry for the tools, the consumables, the deployables and the worn
-- gear (docs/crew-and-items.md §5.1). `inventory.GEAR` was this table's first
-- draft and is now an alias of `ITEMS`; the counts still live in inventory's
-- `inv.gear.<container>` bags, so no save key changes.
--
-- Every item has MASS (kg, against the container's kilograms) and BULK (L,
-- litres, a second limit that applies to items only — materials stay
-- mass-only). Without litres a suit pack fits nine beacons and a 2.4 m flag
-- pole, which reads wrong.
--
--   kind        "tool"        held in both hands, used with the trigger
--               "consumable"  held, used up by what it does (the Repair Kit)
--               "deployable"  held, then placed in the world (deploy mode)
--               "worn"        never in the hand: having it in the pack is
--                             enough (the RCS Pack, drawn on the back)
--   hold        how it is carried in the hand: { prefab, fp?, grip }
--               grip "two"      both hands, a tool (tool_belt's own hold)
--                    "left"     a case by its handle, the right hand free
--                    "shoulder" over the right shoulder (beacon, furled flag)
--   use         { target = "part", provider = "repair" } — the right-click
--               verb the item brings while it is in hand (§6.4)
--   deploy      { store = "comms" | "deployables", kind?, ghost, bad, slope,
--               spacing, pick, secs } — the generic deploy mode (§5.5)
--   issue       part of the standard issue every new crew member gets
--   shop        sold at the depot's BUY counter (and the VAB's stock)
--
-- A pure rulebook: no scene access, no input. Its globals are its API and it
-- loads from disk in a luajit test (tests/smoke_items.lua).
--
--     local I = findScript("items")
--     I.def("repairkit").kg            I.belt(function(id) return n end)
--     I.repairSecs(0.4)  --> 15.6

version = 1

ITEMS = {
  gravgun   = { name = "Gravity Gun",   kind = "tool",       kg = 6.0,  L = 10, cost = 600,  shop = true, issue = true,
                hold = { prefab = "ToolGravGun", fp = "ToolGravGunFP", grip = "two" },
                about = "grabs anything loose and throws it; uproots plants" },
  laser     = { name = "Terrain Laser", kind = "tool",       kg = 8.0,  L = 12, cost = 900,  shop = true, issue = true,
                hold = { prefab = "ToolLaser", fp = "ToolLaserFP", grip = "two" },
                about = "digs rock into the pack, or lays it back down (Q)" },
  repairkit = { name = "Repair Kit",    kind = "consumable", kg = 4.0,  L = 6,  cost = 120,  shop = true,
                hold = { prefab = "ItemRepairKit", grip = "left" },
                use = { target = "part", provider = "repair" },
                about = "patches, fasteners and a welder cartridge: one field repair of a damaged part" },
  -- THE MEDKIT (crew.lua's treat): a trauma pouch. Light enough to always
  -- carry one (1.5 kg, 2 L), dear enough not to carry ten ($150, a third of
  -- a starter's pay-out), and slow and partial on purpose: +50 % hp over 4 s
  -- of held work, or a member who is DOWN back on their feet at 25 % after 6
  -- s. One use. It can't help the dead, nor give air to the suffocating.
  medkit    = { name = "Medkit",        kind = "consumable", kg = 1.5,  L = 2,  cost = 150,  shop = true,
                hold = { prefab = "ItemMedkit", grip = "left" },
                use = { target = "crew", provider = "medkit" },
                about = "a trauma pouch: dressings, a tourniquet and a stimulant. One use: +50% hp, or revive someone who is down" },
  beacon    = { name = "Relay Beacon",  kind = "deployable", kg = 6.0,  L = 18, cost = 80,   shop = true,
                hold = { prefab = "ItemBeaconStowed", grip = "shoulder" },
                deploy = { store = "comms", ghost = "RelayBeaconGhost", bad = "RelayBeaconGhostBad",
                           slope = 0.74, spacing = 4.0, pick = 3.5, secs = 1.2 },
                about = "a cheap ground relay: carries the ground station's signal a few hundred metres further" },
  flag      = { name = "Company Flag",  kind = "deployable", kg = 3.0,  L = 12, cost = 50,   shop = true,
                hold = { prefab = "ItemFlagFurled", grip = "shoulder" },
                deploy = { store = "deployables", kind = "flag", ghost = "FlagGhost", bad = "FlagGhostBad",
                           slope = 0.6, spacing = 2.0, pick = 2.0, secs = 2.5 },
                about = "the agency's flag on a 2.4 m pole: plant it where nobody has stood" },
  rcspack   = { name = "RCS Pack",      kind = "worn",       kg = 22.0, L = 30, cost = 1400, shop = true,
                -- drawn on the back over the PLSS; never in hand (eva_pack.lua, WS1)
                worn = { prefab = "ItemRcsPack", bone = "Back" },
                rcs = { thrust = 90, burst = 1.6, prop = 4.0, isp_dv = 30, g_max = 2.0 },
                about = "cold-gas thrusters on the back: fly on EVA where there is no ground to walk on" },
  -- THE TL-5 SURVEYOR (scripts/surveyor.lua): a plasma rifle, the crew's
  -- first weapon. Heavy and bulky on purpose — 9 kg and 16 L of a 60 L suit
  -- pack is a choice against ore, tanks and beacons. Its energy cell is a
  -- FILL (energy units, the pieces' levels kept by inventory like a tank's
  -- air): a shot draws 6–10, it recharges aboard a craft and at the base.
  surveyor  = { name = "TL-5 Surveyor", kind = "tool",       kg = 9.0,  L = 16, cost = 2400, shop = true,
                hold = { prefab = "ToolSurveyor", fp = "ToolSurveyorFP", grip = "two" },
                fill = { cap = 100, what = "cell" },
                weapon = true,
                about = "a plasma rifle with a survey scope: hold LMB to charge a bolt, release to fire; RMB to aim down the scope" },
  o2tank    = { name = "Oxygen Tank",   kind = "worn",       kg = 8.0,  L = 5,  cost = 350,  shop = true,
                -- clipped to the PLSS; never in hand. Each tank is its own reserve of suit
                -- air (`fill`, seconds), kept per tank as item state (inventory.fills).
                worn = { prefab = "ItemO2Tank", bone = "Back" },
                fill = { cap = 900, what = "o2" },     -- 15 minutes of suit air, full
                about = "a spare bottle of breathing oxygen for the suit: +15 min of air on a long EVA or a dive" },
  -- THE O2 MASK (expansion X2; scripts/atmo.lua): a nasal cannula and a soft
  -- mask on a hose to the suit's own oxygen. Bare-headed in THIN air (O2
  -- between 0.10 and 0.16 bar) it keeps the crew from hypoxia at a sixth of
  -- the suit's draw; without it they lose a little health a minute there.
  -- Having it in the pack is wearing it (no model: it rides inside the neck ring).
  o2mask    = { name = "O2 Mask",       kind = "worn",       kg = 0.4,  L = 1,  cost = 120,  shop = true, show = "ItemO2Mask",
                about = "a cannula and soft mask on a hose to the suit's oxygen: breathe bare-headed in thin air (a sixth of the suit's draw)" },
  -- THE FLASHLIGHT (scripts/flashlight.lua): a clamp-on torch strapped to the
  -- helmet's side while it is in the pack; L switches it, on foot, whatever
  -- is in the hands. Light and cheap on purpose (0.3 kg, $35): a thing you
  -- simply carry. Its battery is a FILL (% kept per torch, like the rifle's
  -- cell): 4 h of light, a brown-out under 10 %, charged aboard or at the base.
  -- THE GAS CAN (playtest 2026-11-03c): a 10 L steel jerry can of petrol
  -- for the gas engines. Held by its handle (grip "left"); beside a craft
  -- with a gas tank, hold LMB to pour (item_hand: `pour.rate` L/s, from
  -- `pour.reach` m of the craft). Its petrol is a FILL in litres, kept per
  -- can like an oxygen tank's air; it comes full, and refills only at the
  -- Repair Bay's gas pump, paid by the litre (`keep`: the warehouse keeps
  -- a can's level as it is, where it tops other fills up for free). It
  -- weighs what it holds: 3 kg of empty steel can (a 20 L jerry can is 4)
  -- and 0.74 kg a litre of petrol (`fill.kg`), 10.4 kg full; the pack's
  -- room is checked against a full one. (A fixed 7 kg before: a can half full.)
  gascan    = { name = "Gas Can",       kind = "device",     kg = 3.0,  L = 13, cost = 25,   shop = true,
                hold = { prefab = "ItemGasCan", grip = "left" },
                fill = { cap = 10, what = "gas", keep = true, kg = 0.74 },
                pour = { rate = 2.5, reach = 2.6 },
                about = "a 10 L steel jerry can of petrol: beside a craft's gas tank, hold LMB to pour it in; refill it at the Repair Bay's pump" },
  flashlight = { name = "Flashlight",   kind = "worn",       kg = 0.3,  L = 1,  cost = 35,   shop = true,
                worn = { prefab = "ItemFlashlight", bone = "Helmet" },
                fill = { cap = 100, what = "cell" },
                lamp = { key = "L", cone = 40, range = 30, hours = 4.0 },
                about = "a clamp-on LED torch for the helmet: L lights the way after dark, in caves and in dust" },
  -- THE ROPE KIT (scripts/rope_climb.lua, rope.lua): 30 m of 11 mm static
  -- line (2.1 kg), a collapsible aluminium edge davit with its sheave and
  -- brake drum (5.5 kg), four rock stakes, and a battery rope ascender with
  -- its descender (3.4 kg): 12 kg and 22 L in its canvas bag. Planted at an
  -- edge, its line drops up to 30 m; E clips on, W and S climb and lower.
  rope      = { name = "Rope Kit",      kind = "deployable", kg = 12.0, L = 22, cost = 180,  shop = true,
                hold = { prefab = "ItemRopeKit", grip = "shoulder" },
                deploy = { store = "deployables", kind = "rope", ghost = "RopePylonGhost", bad = "RopePylonGhostBad",
                           slope = 0.6, spacing = 3.0, pick = 2.2, secs = 3.0, faceOut = true },
                about = "an edge davit, 30 m of static line and a powered ascender: set it at a drop, clip on (E), climb with W and S" },
}

-- FUEL RODS (deep-space B5; scripts/thermal.lua): a reactor's fuel, made at
-- the Materials Intake's radiological wing (FUEL_FAB) from 20 units of
-- uranium ore. A rod is a 1.1 m zirconium-clad cartridge in its carry frame,
-- 40 kg: over the shoulder, and a 90 kg pack takes two. Held, it brings
-- "Load fuel rod" to a reactor's right-click (vessel_thermal's provider).
-- A fresh rod is barely radioactive (unburnt uranium); the SPENT rod that
-- comes out of a core is hot — carried in a pack it doses its carrier
-- (thermal SPENT_DOSE), so it goes into a locker or the Intake's return.
-- `body` is the loose physics prefab (a 40 kg box collider, ready for the
-- gravity gun to lift once rods can be dropped in the world).
ITEMS.fuelRod = { name = "Fuel Rod", kind = "consumable", kg = 40.0, L = 14, cost = 0,
                  hold = { prefab = "ItemFuelRod", grip = "shoulder" }, body = "FuelRodBody",
                  use = { target = "part", provider = "rods" },
                  about = "a reactor fuel rod in its carry frame: hold it at a reactor and right-click to load it" }
-- (S6) the same cartridge at two more enrichments, for reactors built from
-- components (scripts/reactor.lua RODS): natural uranium (0.72 % U-235: only
-- heavy water or a big graphite pile takes it critical) and HALEU (19.75 %:
-- a compact core). The Fuel Rod above is LEU at 3 %. The Depot sells both
-- once the Ember's research is done; the press makes the 3 % rod.
ITEMS.fuelRodNU = { name = "Fuel Rod (natural U)", kind = "consumable", kg = 40.0, L = 14, cost = 900, shop = true, tech = "ember",
                    hold = { prefab = "ItemFuelRod", grip = "shoulder" }, body = "FuelRodBody",
                    use = { target = "prop", provider = "reactor_plant" },
                    about = "natural uranium, 0.72 % U-235 · goes critical only with heavy water, or in a big graphite pile · load it into a Fuel Channel" }
ITEMS.fuelRodHALEU = { name = "Fuel Rod (HALEU 19.75 %)", kind = "consumable", kg = 40.0, L = 14, cost = 7500, shop = true, tech = "ember",
                       hold = { prefab = "ItemFuelRod", grip = "shoulder" }, body = "FuelRodBody",
                       use = { target = "prop", provider = "reactor_plant" },
                       about = "high-assay low-enriched uranium · a small core goes critical on little moderator, and its fuel lasts · load it into a Fuel Channel" }
ITEMS.spentRod = { name = "Spent Rod", kind = "consumable", kg = 40.0, L = 14, cost = 0, hot = true,
                   hold = { prefab = "ItemSpentRod", grip = "shoulder" }, body = "SpentRodBody",
                   about = "a burnt-out fuel rod, hot with fission products: don't carry it in a pack for long. The Materials Intake takes it back" }

-- THE DATA CORE (expansion X8; scripts/ruins.lua): the solid-state log of an
-- abandoned base, pulled from its terminal. Not sold, not held: carried in a
-- pack (or a locker) back to the home Research Lab, where it is read (RP, the
-- site's last log, its blueprint). 6 kg in a shock case.
ITEMS.datacore = { name = "Data Core", kind = "device", kg = 6.0, L = 4, cost = 0,
                   about = "an abandoned base's log in a shock case: carry it into the Research Lab to have it read" }

-- LOOT (the interaction plan S5; scripts/loot.lua): what a ruin's crates,
-- shelves and lockers hold besides the crew's own kit. Not held (no `hold`:
-- never on the belt); carried, stowed, sold.
--   ration      a sealed meal pack: worth carrying, worth selling
--   rustytools  a roll of tools gone orange: their steel at the depot
--   datalog     a log card; each one is its own item `datalog:<key>` (below)
ITEMS.ration = { name = "Ration Pack", kind = "supply", kg = 0.8, L = 1.2, cost = 14,
                 about = "a sealed meal pack, years past its date and still sealed: worth its weight to someone" }
ITEMS.rustytools = { name = "Rusted Tool Roll", kind = "supply", kg = 3.5, L = 4, cost = 20,
                     about = "spanners, a pry bar and a hacksaw gone orange in their canvas roll: worth their steel" }
ITEMS.datalog = { name = "Data Log", kind = "data", kg = 0.2, L = 0.3, cost = 0,
                  about = "a log card from an abandoned base: read it in the pack, or at a terminal" }

-- THE BUILD KIT (deep-space addendum K1; scripts/field_builder.lua): the
-- Engineer's field tablet in its hard carry frame. Every Engineer is issued
-- one (field_builder, once per member: an Engineers-only issue, so not
-- `issue`); in hand it opens build mode, the parts column and the ghost.
-- Carried by its top handle like the Repair Kit. `hintFrom`: the line under
-- the belt is that script's (hintLine), as live as the ghost it describes.
-- The Depot stocks it (a spare, or one for a kit left behind) once the
-- Relay Network's 10 % stage has granted it (M3, research `buildkit`; `tech`:
-- shopList leaves it off the counter until then).
ITEMS.buildkit = { name = "Build Kit", kind = "device", kg = 1.6, L = 3, cost = 400, shop = true, tech = "buildkit",
                   hold = { prefab = "ItemBuildKit", grip = "left" }, hintFrom = "field_builder", role = "engineer",
                   about = "an Engineer's field tablet: pick a part, see its ghost on the ground, click to buy and ship it out (B)" }

-- ── CRATED PARTS (deep-space addendum N2; expansion X4; scripts/recipes.lua) ──
-- A part in its crate is an item of kind "part", id "part:<part id>"
-- ("part:wall.steel", "part:padPlate", "part:vab.locker"): it weighs the part's
-- dry mass and takes recipes.crateLitres of room, so a suit pack carries a
-- light fitting and a hold carries walls. It is never on the belt (no hold);
-- the Build Kit places it off the home world from any container within 30 m
-- (field_builder, the reach rule N8). The entries are not in ITEMS' own keys:
-- `ITEMS["part:…"]` resolves through the part's record (parts_base.partInfo)
-- and recipes.partItemDef, and what was resolved is kept in the save
-- (`items.partdefs`), so a scene without the Build Kit's scripts (the VAB)
-- still weighs a crated part in a hold. `pairs(ITEMS)`, the shop and the belt
-- never see them.
PART_PREFIX = "part:"
local part_cache = {}
local part_source = nil        -- (tests) function(partId) → def, itemDef
function setPartSource(fn) part_source = fn; part_cache = {} end
function isPart(id) return type(id) == "string" and id:sub(1, #PART_PREFIX) == PART_PREFIX end
function partOf(id) if isPart(id) then return id:sub(#PART_PREFIX + 1) end return nil end
function partItemId(partId) return PART_PREFIX .. tostring(partId) end
local function resolve_part(id)
  local c = part_cache[id]
  if c ~= nil then return c or nil end
  local pid = id:sub(#PART_PREFIX + 1)
  local d
  if part_source then
    local _, it = part_source(pid)
    d = it
  else
    local R = findScript and findScript("recipes") or nil
    local PB = findScript and findScript("parts_base") or nil
    local pd = PB and PB.partInfo and PB.partInfo(pid) or nil
    if R and R.partItemDef and pd then d = R.partItemDef(pid, pd) end
    local all = save and save.get and save.get("items.partdefs")
    all = type(all) == "table" and all or {}
    if d then
      local had = all[id]
      if type(had) ~= "table" or had.kg ~= d.kg or had.L ~= d.L or had.name ~= d.name then
        all[id] = { name = d.name, kind = "part", part = pid, kg = d.kg, L = d.L, cost = d.cost, about = d.about }
        if save and save.set then pcall(save.set, "items.partdefs", all) end
      end
    elseif type(all[id]) == "table" then
      d = all[id]
      d.kind, d.part = "part", pid
    end
  end
  -- (a miss is not cached: the Build Kit's scripts may arrive a frame later)
  if d then part_cache[id] = d end
  return d
end
-- ── DATA LOGS (the interaction plan S5) ──────────────────────────────────────
-- A log card is an item `datalog:<key>`; its words are a record in the save
-- (`loot.logs[key]`: title, who, when, lines, codes, coords; scripts/loot.lua
-- rolls a ruin's, a scenario's start.datalogs names its own). 0.2 kg, 0.3 L.
-- The name carries the title ("Data Log: Shift note"). Never in pairs(ITEMS).
LOG_PREFIX = "datalog:"
local log_cache = {}
function isLog(id) return type(id) == "string" and id:sub(1, #LOG_PREFIX) == LOG_PREFIX end
function forgetLogs() log_cache = {} end
local function resolve_log(id)
  local c = log_cache[id]
  if c then return c end
  local key = id:sub(#LOG_PREFIX + 1)
  local all = save and save.get and save.get("loot.logs")
  local rec = type(all) == "table" and all[key] or nil
  local title = type(rec) == "table" and rec.title or nil
  local d = { name = title and ("Data Log: " .. tostring(title)) or "Data Log", kind = "data", kg = 0.2, L = 0.3, cost = 0, log = key,
              about = "a log card" .. (type(rec) == "table" and rec.who and (" signed " .. tostring(rec.who)) or "") .. ": read it in the pack or at a terminal" }
  if rec then log_cache[id] = d end
  return d
end
setmetatable(ITEMS, { __index = function(_, k)
  if type(k) == "string" and k:sub(1, #PART_PREFIX) == PART_PREFIX then return resolve_part(k) end
  if type(k) == "string" and k:sub(1, #LOG_PREFIX) == LOG_PREFIX then return resolve_log(k) end
  return nil
end })

-- The belt's order: tools first, then devices and deployables, then
-- consumables with a hold. (Worn items are never on the belt.)
ORDER = { "gravgun", "laser", "surveyor", "buildkit", "beacon", "flag", "rope", "repairkit", "medkit", "gascan", "fuelRod", "fuelRodNU", "fuelRodHALEU", "spentRod", "rcspack", "o2tank", "o2mask", "flashlight" }

-- The Medkit's work (crew.lua runs it): seconds held at it, what it gives,
-- and the reach from the medic to the patient (m).
MEDKIT = { heal = 0.5, heal_secs = 4.0, revive_hp = 0.25, revive_secs = 6.0, reach = 2.6 }
local KIND_RANK = { tool = 1, device = 2, deployable = 3, consumable = 4, part = 6, worn = 9 }

-- Litres by container family (docs §5.1). A cargo hold's litres come from its
-- Cargo Bays (1000 L each, set by the vessel); the base and a salvage crate
-- are unlimited. A base SUPPLY CRATE (scripts/supply_crates.lua) is a
-- 1.2 m steel field crate: 480 L and 400 kg.
VOL = { pack = 60, locker = 120, bay = 1000, crate = 480 }
CRATE_KG = 400

function def(id) return id and ITEMS[id] or nil end
function known(id) return id ~= nil and ITEMS[id] ~= nil end
function nameOf(id) local d = ITEMS[id]; return d and d.name or tostring(id) end
function isTool(id) local d = ITEMS[id]; return d ~= nil and d.kind == "tool" end
function isWorn(id) local d = ITEMS[id]; return d ~= nil and d.kind == "worn" end
-- Can it go in the hand? (Has a `hold`, and isn't worn.)
function holdable(id)
  local d = ITEMS[id]
  return d ~= nil and d.kind ~= "worn" and d.hold ~= nil
end
function gripOf(id) local d = ITEMS[id]; return d and d.hold and d.hold.grip or nil end
function deployOf(id) local d = ITEMS[id]; return d and d.deploy or nil end
function useOf(id) local d = ITEMS[id]; return d and d.use or nil end

-- Every id in belt order (ORDER first, then anything added later, by kind
-- then name) — the one ordering everything that lists items uses.
function ids()
  local out, seen = {}, {}
  for _, id in ipairs(ORDER) do if ITEMS[id] then out[#out + 1] = id; seen[id] = true end end
  local extra = {}
  for id in pairs(ITEMS) do if not seen[id] then extra[#extra + 1] = id end end
  table.sort(extra, function(a, b)
    local ra, rb = KIND_RANK[ITEMS[a].kind] or 5, KIND_RANK[ITEMS[b].kind] or 5
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  for _, id in ipairs(extra) do out[#out + 1] = id end
  return out
end

-- THE BELT: the pack's holdables, in order. `count(id)` says how many the
-- pack holds. → { { id, label, n, consumable, grip, kind } … }
function belt(count)
  local list = {}
  for _, id in ipairs(ids()) do
    local d = ITEMS[id]
    local n = count and count(id) or 0
    if n > 0 and holdable(id) then
      list[#list + 1] = { id = id, label = d.name, n = n, consumable = d.kind ~= "tool", grip = d.hold.grip,
                          kind = d.kind, rank = KIND_RANK[d.kind] or 5 }
    end
  end
  -- tools, then devices and deployables, then consumables (stable within a rank)
  for i, e in ipairs(list) do e.i = i end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.i < b.i
  end)
  for _, e in ipairs(list) do e.rank, e.i = nil, nil end
  return list
end

-- The standard issue: what every new crew member gets (the tools today).
function issueList()
  local out = {}
  for _, id in ipairs(ids()) do if ITEMS[id].issue then out[#out + 1] = id end end
  return out
end

-- What the depot's BUY counter and the VAB's stock sell, cheapest first.
-- An item with a `tech` is on the counter only once that research is open.
function tech_open(id)
  if not id then return true end
  local rs = findScript and findScript("research")
  if not (rs and rs.isUnlocked) then return true end
  return rs.isUnlocked(id) == true
end
function shopList()
  local out = {}
  for _, id in ipairs(ids()) do
    local d = ITEMS[id]
    if d.shop and d.cost and tech_open(d.tech) then
      out[#out + 1] = { id = id, name = d.name, cost = d.cost, kg = d.kg, L = d.L, kind = d.kind, about = d.about }
    end
  end
  table.sort(out, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.id < b.id end)
  return out
end

-- ── SELLING BACK (the depot's SELL counter, playtest 2026-10-27) ───────────
-- The depot buys gear back at SELL_BACK of its list price, whatever its state:
-- a spare tool, a medkit nobody used, a second rifle. It is a used-goods
-- price on purpose — buying and selling back costs 40 %, so the counter is a
-- way to turn kit you don't need into a launch, never a way to make money.
-- (A part-used Oxygen Tank or a flat rifle cell sells at the same price: the
-- depot refills them before they go back on the shelf.)
SELL_BACK = 0.6
function sellPrice(id)
  local d = ITEMS[id]
  if not (d and d.cost) then return 0 end
  return math.floor(d.cost * SELL_BACK + 1e-9)
end
function sellable(id)
  local d = ITEMS[id]
  return d ~= nil and (d.cost or 0) > 0
end

-- ── THE ITEM CARD (the depot's detail view) ────────────────────────────────
-- What a buyer reads before paying: the name, a kind line, the description,
-- and the numbers that matter for THIS item, as { { label, value } … }. Pure
-- data; `live` (optional) lends the scripts that own the real numbers — the
-- rifle's damage model (surveyor), the tools' reach (tool_belt params) — so
-- the card never quotes a number the game doesn't use. Without them the
-- figures below are those scripts' defaults.
KIND_WORD = { tool = "Tool · two hands", consumable = "Consumable · one use", deployable = "Deployable · planted",
              worn = "Worn · on the suit", device = "Device · in one hand", part = "Part · in its crate" }
local LIVE_DEFAULT = {
  laser_reach = 24, grav_reach = 16, yield = 1.0,
  bolt_speed = 380, bolt_range = 450, full_range = 60, cell_cost = { 5, 10 }, recharge = 4,
  zoom = 4, hits30 = 2, hits150 = 3, dmg30 = 0.51, dmg150 = 0.45, part_dmg = 0.25,
  beacon_power = 1500,
}
local function pct(x) return string.format("%d%%", math.floor((x or 0) * 100 + 0.5)) end
function card(id, live)
  local d = ITEMS[id]
  if not d then return nil end
  live = live or {}
  local function L(k) local v = live[k]; if v == nil then v = LIVE_DEFAULT[k] end return v end
  local rows = {}
  local function row(a, b) rows[#rows + 1] = { a, b } end
  if d.fill and d.fill.kg then
    row("Mass", string.format("%.1f kg empty, %.1f kg full", d.kg or 0, (d.kg or 0) + (d.fill.cap or 0) * d.fill.kg))
  else
    row("Mass", string.format("%.1f kg", d.kg or 0))
  end
  row("Bulk", string.format("%.0f L of a %d L suit pack", d.L or 0, VOL.pack))
  if id == "medkit" then
    row("Treats", string.format("+%s health over %.0f s of held work", pct(MEDKIT.heal), MEDKIT.heal_secs))
    row("Revives", string.format("a downed member, back up at %s, after %.0f s", pct(MEDKIT.revive_hp), MEDKIT.revive_secs))
    row("Reach", string.format("%.1f m from the patient", MEDKIT.reach))
    row("Can't", "help the dead, or give air to the suffocating")
  elseif id == "surveyor" then
    row("Bolt", string.format("%.0f m/s, no drop, gone at %.0f m", L("bolt_speed"), L("bolt_range")))
    row("Damage", string.format("full charge, body: %s at 30 m (%d hits), %s at 150 m (%d hits)",
      pct(L("dmg30")), L("hits30"), pct(L("dmg150")), L("hits150")))
    row("Head shot", "×1.6 through the visor")
    row("Craft", string.format("%s of a part's hull a full bolt", pct(L("part_dmg"))))
    local cc = L("cell_cost")
    row("Cell", string.format("100 units; %d–%d a shot; +%d/s aboard or at the base", cc[1], cc[2], L("recharge")))
    row("Scope", string.format("%.0f× in first person (RMB)", L("zoom")))
  elseif id == "laser" then
    row("Reach", string.format("%.0f m", L("laser_reach")))
    row("Cuts", string.format("about a unit of rock a %.1f s of full beam, into the pack", L("yield")))
    row("Also", "lays rock back down (Q), fells and cuts plants")
  elseif id == "gravgun" then
    row("Reach", string.format("%.0f m", L("grav_reach")))
    row("Moves", "loose rock, crates, felled logs and light craft; strains at anything heavy")
    row("Also", "uproots plants whole")
  elseif id == "repairkit" then
    row("Repairs", string.format("one damaged part: %.0f s for a scuff, %.0f s for a failing part",
      REPAIR.secs0 + REPAIR.secs_k * 0.06, REPAIR.secs0 + REPAIR.secs_k * 0.95))
    row("Needs", "the craft at rest and its engines off; a wrecked part is beyond it")
  elseif id == "beacon" then
    row("Relays", "a low-power omni relay on a 4 m mast, always on")
    row("Reach", "a few hundred metres of ground; each one only has to see the last")
    row("Counts", "toward the Relay Network milestone's ground coverage")
  elseif id == "flag" then
    row("Pole", "2.4 m, planted in 2.5 s")
  elseif id == "rcspack" and d.rcs then
    row("Thrust", string.format("%.0f N; SHIFT burst ×%.1f", d.rcs.thrust, d.rcs.burst))
    row("Δv", string.format("about %.0f m/s from a full pack", d.rcs.isp_dv))
    row("Refills", "from the craft's own RCS propellant")
  elseif id == "o2tank" and d.fill then
    row("Air", string.format("+%.0f min of suit air, breathed before the suit's own", d.fill.cap / 60))
    row("Refills", "aboard, at a locker or at the base")
  elseif id == "gascan" and d.fill then
    row("Holds", string.format("%.0f L of petrol; it comes full", d.fill.cap))
    row("Pours", string.format("%.1f L/s into a craft's gas tanks, held LMB within %.1f m", d.pour.rate, d.pour.reach))
    row("Refills", "at the Repair Bay's gas pump, by the litre")
  elseif id == "flashlight" and d.lamp then
    row("Beam", string.format("a %.0f° warm-white spot, about %.0f m of throw", d.lamp.cone, d.lamp.range))
    row("Switch", string.format("%s, on foot; it rides strapped to the helmet", d.lamp.key))
    row("Battery", string.format("%.0f h of light; dims under 10%%; charges aboard or at the base", d.lamp.hours))
  elseif d.kind == "part" then
    row("Part", tostring(d.part or partOf(id)))
    row("Placed", "with the Build Kit, off the home world, from any container within 30 m (the pack last)")
    row("Made", "at home, crated by its supplier (K with the part in hand); a Fabricator makes it on site later")
  elseif id == "rope" then
    row("Line", "30 m of 11 mm static line over a sheave on a 1.4 m edge davit")
    row("Climb", "a powered ascender: about 0.8 m/s up at 1 g with a full pack, faster on light worlds")
    row("Lower", "1.6 m/s through the descender (SHIFT 2.8)")
    row("Set", "at a ledge or cliff edge, boom out over the drop; 3 s to stake it; hold E at it to take it down")
  end
  row("Price", string.format("$%d", d.cost or 0))
  row("Sells back", string.format("$%d (%s)", sellPrice(id), pct(SELL_BACK)))
  return { id = id, name = d.name, kind = KIND_WORD[d.kind] or d.kind, about = d.about or "", rows = rows,
           prefab = d.hold and d.hold.prefab or (d.worn and d.worn.prefab) or d.show or nil }
end

-- ── repair (docs §6.2) ──────────────────────────────────────────────────────
REPAIR = {
  secs0 = 6.0, secs_k = 16.0,  -- secs = 6 + 16 × (1 − hp): a scuff is 7 s, a failing part 18 s
  reach = 2.6,                 -- the context menu's reach (+ the part's half-size)
  max_rel_speed = 1.0,         -- m/s relative to the part to start
  keep = 120.0,                -- s that cancelled progress is kept on the part (st.rprog)
  standoff = 0.7,              -- m: the work spot off the surface
  slide = 0.4,                 -- s: sliding in to the work spot
  max_throttle = 0.0,          -- the craft must not be under power
  max_accel = 0.5,             -- m/s² of thrust that pushes the crew off
}

-- `mult`: the worker's perk (crew.perk(id, "repair_time"): an Engineer 0.5,
-- 0.35 from level 2; anyone else 1).
function repairSecs(hp, mult)
  hp = math.max(0, math.min(1, hp or 1))
  return (REPAIR.secs0 + REPAIR.secs_k * (1 - hp)) * (tonumber(mult) or 1)
end

-- Is a part repairable at this health? → ok, why
function repairable(hp)
  if hp == nil then return false, "that part isn't on this craft" end
  if hp <= 0 then return false, "it is wrecked — beyond a field repair" end
  if hp >= 0.999 then return false, "it is sound" end
  return true, nil
end

-- A forced stop: what makes the work impossible this tick. `s` is a plain
-- snapshot { hp (nil = gone), craft = bool (the craft still exists),
-- throttle, accel, o2 (0..1, nil = fine) }. → why | nil
-- MOVEMENT IS NOT HERE ON PURPOSE: keys never end a job (§6.2).
function repairStop(s)
  if not s.craft then return "the craft is gone" end
  if s.hp == nil then return "the part left the craft" end
  if s.hp <= 0 then return "the part broke" end
  if (s.throttle or 0) > REPAIR.max_throttle + 1e-6 or (s.accel or 0) > REPAIR.max_accel then
    return "the engines fired — pushed off the hull"
  end
  if s.o2 ~= nil and s.o2 <= 0 then return "out of air" end
  return nil
end

-- Progress kept on the part (st.rprog = { s = seconds done, t = when }):
-- how many seconds of work count toward a new start at `now`.
function keptProgress(rprog, now, secs)
  if type(rprog) ~= "table" or not rprog.s then return 0 end
  if now - (rprog.t or -1e9) > REPAIR.keep then return 0 end
  return math.max(0, math.min(secs or rprog.s, rprog.s))
end

-- ── item state: a FILL per item (the Oxygen Tank) ──────────────────────────
-- An item with `fill = { cap }` carries a level per piece (seconds of air for
-- a tank). The stacks stay plain counts; inventory keeps the levels beside
-- them (`inv.fill.<cid>`, one number per piece) and moves them with the
-- pieces. These are the pure rules; the wrappers below ask inventory.
function fillCap(id) local d = ITEMS[id]; return d and d.fill and d.fill.cap or nil end
function hasFill(id) return fillCap(id) ~= nil end
function isWeapon(id) local d = ITEMS[id]; return d ~= nil and d.weapon == true end
-- One piece's level as the panels write it: an oxygen tank's minutes of air
-- ("12"), an energy cell's percent ("84%"). `unit` → the unit word for the
-- whole stack's total ("min" | "%").
function fillText(id, level)
  local d = ITEMS[id]
  local what = d and d.fill and d.fill.what or "o2"
  if what == "cell" then return string.format("%.0f%%", 100 * (level or 0) / (d.fill.cap or 100)), "%" end
  if what == "gas" then return string.format("%.1f", level or 0), "L" end
  return string.format("%.0f", (level or 0) / 60), "min"
end

-- THE DRAW ORDER: the EMPTIEST tank that still has air first, so a partly
-- used bottle is finished before a full one is opened (and the full ones stay
-- full to hand over or leave in a locker). Returns the seconds drawn (≤ secs)
-- and changes `fills` in place.
function drawFrom(fills, secs)
  local want = math.max(0, secs or 0)
  local got = 0
  while want - got > 1e-9 do
    local best = nil
    for i, f in ipairs(fills) do
      if f > 1e-9 and (not best or f < fills[best]) then best = i end
    end
    if not best then break end
    local take = math.min(fills[best], want - got)
    fills[best] = fills[best] - take
    if fills[best] < 1e-9 then fills[best] = 0 end
    got = got + take
  end
  return got
end

-- ── the suit's interface to the tanks (planet_walker / crew, WS1) ──────────
-- THE RULE (docs §5.8): the suit breathes from the carried tanks FIRST,
-- emptiest first, and only when every tank is dry from its own built-in
-- supply — so the suit's own O2 figure and its alarms keep meaning "the last
-- reserve". With the helmet ON the suit air is what is breathed, under water
-- too; held breath applies only bare-headed.
local function inv() return findScript and findScript("inventory") or nil end
-- → seconds of air in the pack's tanks, { per-tank seconds } (emptiest first)
function o2Reserve(pack)
  local I = inv()
  if not (I and I.fills) then return 0, {} end
  local f = I.fills(pack, "o2tank")
  local t, list = 0, {}
  for _, v in ipairs(f) do t = t + v; list[#list + 1] = v end
  table.sort(list)
  return t, list
end
-- Draw `secs` of air from the pack's tanks → seconds actually drawn (the
-- caller breathes the rest from the suit's own supply).
function drawO2(pack, secs)
  local I = inv()
  if not (I and I.drawFill) then return 0 end
  return I.drawFill(pack, "o2tank", secs)
end
-- Fill every tank in a container (boarding, a locker's menu, the base) →
-- seconds added.
function refillO2(cid)
  local I = inv()
  if not (I and I.refill) then return 0 end
  return I.refill(cid, "o2tank")
end
