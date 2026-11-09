-- RECIPES — what a part is made of, and the part as a thing you carry
-- (deep-space addendum N2, N3, N5, N6, N8; expansion X4; docs/base-building.md
-- §22, docs/resources.md §7).
--
-- A pure rulebook on the Build Kit node: no scene access, its globals are its
-- API, and it loads from disk in a luajit test (tests/smoke_recipes.lua).
--
-- THE ONE SENTENCE: a part is its dry mass in refined materials by what it is
-- (N5), plus FITTINGS bought for money (Q22); and a part you carry is an item
-- of kind "part" that weighs what the part weighs (N2).
--
--   recipeFor(def, section, id)   → { id, kg, mats = { { mat, kg } … },
--                                    fittings ($), secs, perMetre, shipOnly }
--   lineOf(r)                     "780 kg Steel · 130 kg Wiring · 130 kg Glass + $100"
--   needHave(r, have)             → { { mat, need, have, short } … }, all
--   partItemId(partId)            "part:" .. partId (the item a crated part is)
--   partIdOf(itemId)              its part id (nil for any other item)
--   partItemDef(partId, def)      → the item registry's entry for it
--   crateLitres(def)              the litres a crated part takes
--   CONTAINERS                    the container kinds N8 adds (fab:, silo:, hopper:)
--
-- THE RULE (N5), in kilograms of the part's dry mass m:
--   structure  STRUCT_SHARE (60 %) of m as Steel; Alloy instead for AIRCRAFT,
--              ROVER and AUTO section parts and for engines; tanks are thin
--              walls round a lot of volume: TANK_SHARE (40 %); Regocrete in
--              place of Steel, all of m, for the BASE section's slabs and
--              blocks (the Pad Plate, the Shield Wall)
--   Wiring     WIRE_SHARE (10 %) of m for anything with a command, battery,
--              antenna, solar, light, drive, hinge, piston, rotor, claw or
--              drill module, a power source or store, and for engines (their
--              ignition and gimbal: N6's Anvil carries 90 kg)
--   Glass      GLASS_SHARE (10 %) of m for crewed parts (windows; not a bare
--              seat), kit pieces with a window or a porthole, solar
--              panels (cover glass) and the Surface Hab and the Base Hub
--   fittings   FITTINGS_RATE (20 %) of the part's price in money: the valves,
--              seals and chips no outpost makes (Q22); 10 % for structural
--              kit pieces and the BASE section's concrete
-- A KIT PIECE ("wall.steel": its mass IS its material, parts_kit.massOf) is
-- all its own material: steel → Steel, concrete and regocrete → Regocrete
-- (concrete off the home world is regolith concrete), glass → Glass; a piece
-- that switches, lights, pumps or signals gives WIRE_SHARE of it to Wiring.
-- A VAB part placed live ("vab.pod") follows the VAB rule on its registry
-- entry. Overrides (RECIPE_OVERRIDE) for the few that need them.
--
-- WHAT IS NOT MADE OFF-WORLD (`shipOnly`, the reason): the Isotope Skid and
-- the Isotope Cell (their plutonium), reactor-grade graphite, and paint.

STRUCT_SHARE = 0.60
TANK_SHARE   = 0.40
WIRE_SHARE   = 0.10
GLASS_SHARE  = 0.10
FITTINGS_RATE = 0.20
FITTINGS_PLAIN = 0.10     -- structural kit pieces and BASE concrete (Q22)
FAB_SECS0, FAB_SECS_T = 10, 20   -- a Fabricator's time: 10 s + 20 s a tonne (N4)

-- the order materials are named in (materials.REFINED)
ORDER = { "steel", "alloy", "wiring", "glass", "regocrete", "propellant", "gas" }
LABEL = { steel = "Steel", alloy = "Alloy Steel", wiring = "Copper Wire", glass = "Glass", regocrete = "Regocrete",
          propellant = "Propellant", gas = "Propellant Gas" }
local SHORT = { steel = "Steel", alloy = "Alloy", wiring = "Wiring", glass = "Glass", regocrete = "Regocrete",
                propellant = "Propellant", gas = "Gas" }

ALLOY_SECTIONS = { AIRCRAFT = true, ROVER = true, AUTO = true }
WIRED_MODS = { command = true, battery = true, antenna = true, solar = true, light = true, drive = true, hinge = true,
               piston = true, rotor = true, claw = true, drill = true, rtg = true, wheel = true }
-- kit piece material → refined material (nil: not made off-world)
KIT_MAT = { steel = "steel", concrete = "regocrete", regocrete = "regocrete", glass = "glass" }
STRUCTURAL_KIT = { FOUNDATION = true, FLOOR = true, WALL = true, ROOF = true, FRAME = true, HAB = true, SHIELD = true,
                   PROPS = true }

-- Overrides by part id: { mats = { mat = share of m … }, fittings = rate,
-- shipOnly = why }. A share table replaces the rule's materials outright.
RECIPE_OVERRIDE = {
  padPlate    = { mats = { regocrete = 1.0 }, fittings = FITTINGS_PLAIN },
  shieldWall  = { mats = { regocrete = 1.0 }, fittings = FITTINGS_PLAIN },
  tower       = { mats = { steel = 0.60, wiring = 0.10 } },
  isotopeSkid = { mats = { steel = 0.60, wiring = 0.10 }, shipOnly = "its Isotope Cells are made at home (plutonium-238)" },
  ["vab.rtg"] = { mats = { steel = 0.60, wiring = 0.10 }, shipOnly = "an Isotope Cell is made at home (plutonium-238)" },
  rtg         = { mats = { steel = 0.60, wiring = 0.10 }, shipOnly = "an Isotope Cell is made at home (plutonium-238)" },
}

local function round(x) return math.floor((x or 0) + 0.5) end

local function has_wired_mod(d)
  for _, m in ipairs(d.mods or {}) do if WIRED_MODS[m.type] then return true end end
  return false
end
local function has_mod(d, t)
  for _, m in ipairs(d.mods or {}) do if m.type == t then return true end end
  return false
end

-- (a kit piece that switches, lights, pumps, signals or powers: wired)
local function kit_wired(def)
  if def.light or def.screen or def.switch or def.door or def.lg or def.power or def.life or def.console or def.turbine
    or def.pump or def.press or def.survey then return true end
  if def.fl and (def.fl.kind == "pump" or def.fl.kind == "valve" or def.fl.kind == "gauge" or def.fl.kind == "reg") then return true end
  return false
end

-- THE RECIPE of a part record `def` (parts_registry / parts_base / parts_kit
-- shape: mass in TONNES, cost in $), in `section` (the catalogue's title, or
-- nil), with id `id` (for the override table; nil is fine).
-- → { id, kg, mats = { { mat, kg } … } in ORDER, fittings, secs, perMetre?, shipOnly? }
-- or nil for a tool (paint, a blueprint card) or nothing.
function recipeFor(def, section, id)
  if type(def) ~= "table" then return nil end
  if def.tool then return nil end
  id = id or def.id
  section = section or def.section
  local r = { id = id, mats = {}, fittings = 0 }
  local shares = {}
  local frate = FITTINGS_RATE
  local cost = def.cost or 0
  local m
  -- CABLES are laid by the metre: a recipe a metre of run
  if def.cable then
    r.perMetre = true
    m = def.cable.kgm or 1.4
    shares = { wiring = 0.5, steel = 0.5 }      -- copper cores, steel-wire armour
    cost = def.cable.perm or cost
  elseif def.wire then
    r.perMetre = true
    m = def.wire.kgm or 0.045
    shares = { wiring = 1.0 }
    cost = def.wire.perm or cost
  else
    m = (def.mass or 0) * 1000
  end
  local ov = id and RECIPE_OVERRIDE[id] or nil
  -- a VAB part placed live: its registry entry, by the VAB rule
  local reg = def
  if def.live and type(def.reg) == "table" then reg = def.reg; section = "FITTINGS" end
  if r.perMetre then
    -- (shares set above)
  elseif ov and ov.mats then
    for k, v in pairs(ov.mats) do shares[k] = v end
    frate = ov.fittings or frate
  elseif def.kit and not def.live then
    local mat = KIT_MAT[def.mat or ""]
    if def.mat == "graphite" then r.shipOnly = "reactor-grade graphite is made at home" end
    local base = mat and 1.0 or 0
    if mat and kit_wired(def) then shares.wiring = WIRE_SHARE; base = 1.0 - WIRE_SHARE end
    -- (a steel piece with a window in it: its pane)
    if mat and mat ~= "glass" and type(def.piece) == "string" and (def.piece:find("[Ww]indow") or def.piece:find("porthole")) then
      shares.glass = GLASS_SHARE; base = base - GLASS_SHARE
    end
    if mat then shares[mat] = (shares[mat] or 0) + base end
    if def.mat == "film" or def.film then frate = 1.0 end    -- a decal: paint, bought
    if STRUCTURAL_KIT[section or ""] and not kit_wired(def) then frate = FITTINGS_PLAIN end
  else
    local kind = reg.kind
    local struct = "steel"
    if ALLOY_SECTIONS[section or ""] or kind == "engine" then struct = "alloy" end
    local share = (kind == "tank") and TANK_SHARE or STRUCT_SHARE
    shares[struct] = share
    if has_wired_mod(reg) or kind == "engine" or reg.solar or reg.comms or reg.power or reg.robo or reg.claw
      or reg.tower or reg.light or reg.door or reg.hub then
      shares.wiring = WIRE_SHARE
    end
    if (kind == "crewed" and not reg.seat) or reg.solar or has_mod(reg, "solar") or (type(reg.power) == "table" and reg.power.kind == "solar")
      or reg.hull == "shell" or reg.hub then
      shares.glass = GLASS_SHARE
    end
  end
  if ov and ov.shipOnly then r.shipOnly = ov.shipOnly end
  local total = 0
  for _, mat in ipairs(ORDER) do
    local s = shares[mat]
    if s and s > 0 and m > 0 then
      local kg = r.perMetre and (math.floor(m * s * 1000 + 0.5) / 1000) or round(m * s)
      if kg > 0 then r.mats[#r.mats + 1] = { mat = mat, kg = kg }; total = total + kg end
    end
  end
  r.kg = r.perMetre and m or round(m)
  r.total = total
  r.fittings = r.perMetre and 0 or round(cost * frate)
  r.secs = FAB_SECS0 + FAB_SECS_T * (r.perMetre and 0 or m / 1000)
  return r
end

-- The kg of `mat` a recipe asks (0 when none).
function kgOf(r, mat)
  for _, e in ipairs((r and r.mats) or {}) do if e.mat == mat then return e.kg end end
  return 0
end

local function kgText(kg)
  if kg >= 10000 then return string.format("%.1f t", kg / 1000) end
  if kg < 1 then return string.format("%.0f g", kg * 1000) end
  if kg < 10 and kg % 1 ~= 0 then return string.format("%.1f kg", kg) end
  return string.format("%d kg", round(kg))
end
kgString = kgText

local function money(v)
  v = round(v)
  local s, out = tostring(math.abs(v)), ""
  while #s > 3 do out = "," .. s:sub(-3) .. out; s = s:sub(1, -4) end
  return "$" .. s .. out
end

-- "780 kg Steel · 130 kg Wiring · 130 kg Glass + $100" (short names, the
-- card's width); "a metre: 0.7 kg Wiring · 0.7 kg Steel" for a cable.
function lineOf(r, long)
  if not r then return "" end
  local parts = {}
  for _, e in ipairs(r.mats) do parts[#parts + 1] = kgText(e.kg) .. " " .. ((long and LABEL[e.mat]) or SHORT[e.mat] or e.mat) end
  local s = #parts > 0 and table.concat(parts, " · ") or "no materials"
  if r.perMetre then return "a metre: " .. s end
  if (r.fittings or 0) > 0 then s = s .. " + " .. money(r.fittings) end
  return s
end

-- Need against have: `have(mat)` → kg on hand (any function). → rows
-- { { mat, label, need, have, short } … }, all (true when nothing is short).
function needHave(r, have)
  local rows, all = {}, true
  for _, e in ipairs((r and r.mats) or {}) do
    local h = (have and have(e.mat)) or 0
    local short = math.max(0, e.kg - h)
    if short > 0 then all = false end
    rows[#rows + 1] = { mat = e.mat, label = LABEL[e.mat] or e.mat, need = e.kg, have = h, short = short }
  end
  return rows, all
end

-- ── PART ITEMS (N2): a crated part is an item of kind "part" ───────────────
PREFIX = "part:"
function partItemId(partId) return PREFIX .. tostring(partId) end
function partIdOf(itemId)
  if type(itemId) ~= "string" or itemId:sub(1, #PREFIX) ~= PREFIX then return nil end
  local p = itemId:sub(#PREFIX + 1)
  return p ~= "" and p or nil
end
function isPartItem(itemId) return partIdOf(itemId) ~= nil end

-- CRATED BULK: a part ships knocked down to about a quarter of the box it
-- stands in (N2: "L from h·rx·rz", rx and rz the half-widths), but never
-- lighter than CRATE_MIN_KGL kg a litre of crate (a lattice tower or a frame
-- packs flat) and never under a litre.
CRATE_MIN_KGL = 0.25
function crateLitres(def)
  if type(def) ~= "table" then return 1 end
  local box = 1000 * (def.h or 1) * (def.rx or 0.5) * (def.rz or def.rx or 0.5)
  local kg = (def.mass or 0) * 1000
  local L = math.min(box, kg / CRATE_MIN_KGL)
  return math.max(1, math.floor(L + 0.5))
end

-- The item registry's entry for a crated `partId` with part record `def`.
function partItemDef(partId, def)
  if type(def) ~= "table" or def.tool or def.cable or def.wire then return nil end
  local name = def.label or tostring(partId)
  if def.kit and not def.live and def.matLabel then name = name .. " · " .. def.matLabel end
  local kg = (def.mass or 0) * 1000
  return { name = name .. " (crated)", kind = "part", part = partId, kg = math.floor(kg * 10 + 0.5) / 10,
           L = crateLitres(def), cost = math.floor(def.cost or 0),
           about = string.format("a %s knocked down in its crate · placed with the Build Kit off the home world", def.label or "part") }
end

-- ── CONTAINERS (N8) ─────────────────────────────────────────────────────────
-- The containers the material chain adds beside pack, locker, hold, crate and
-- base: a Fabricator's store, a silo (one material), a hopper. kg and litres
-- (math.huge: bulk only); `one` = a single material at a time.
CONTAINERS = {
  fab    = { kg = 2000, L = 4000, label = "Fabricator store" },
  silo   = { kg = 8000, L = math.huge, one = true, label = "Silo" },
  hopper = { kg = 4000, L = math.huge, label = "Hopper" },
}
-- The kind of a container id ("silo:3.2" → "silo"), nil for the others.
function containerKind(cid)
  if type(cid) ~= "string" then return nil end
  local k = cid:match("^(%a+):")
  return (k and CONTAINERS[k]) and k or nil
end

-- THE REACH RULE (N8, Q16): placing draws from any container within REACH m
-- of the Engineer, nearest first, the pack last. `list` = { { id, d } … } or
-- { { id, x, y, z } … } with the Engineer at (x, y, z); `pack` = true marks
-- the pack. Mirrors base_economy.containersInReach (kept there for step 4's
-- callers); runs (X5) use it for a stand without a chute.
REACH = 30.0
function reachOrder(list, x, y, z, reach)
  reach = reach or REACH
  local near, pack = {}, {}
  for _, c in ipairs(list or {}) do
    if c.pack then pack[#pack + 1] = c.id
    else
      local d = c.d
      if d == nil and c.x then d = math.sqrt((c.x - (x or 0)) ^ 2 + (c.y - (y or 0)) ^ 2 + (c.z - (z or 0)) ^ 2) end
      if d and d <= reach then near[#near + 1] = { id = c.id, d = d } end
    end
  end
  table.sort(near, function(a, b) if a.d ~= b.d then return a.d < b.d end return tostring(a.id) < tostring(b.id) end)
  local out = {}
  for _, e in ipairs(near) do out[#out + 1] = e.id end
  for _, id in ipairs(pack) do out[#out + 1] = id end
  return out
end

-- Draw `n` of `item` from the ordered containers through `count(cid, item)`
-- and `take(cid, item, k)` (→ taken). → taken, { { cid, n } … } (the plan
-- of what came from where, so an undo can put each back).
function drawFrom(order, item, n, count, take)
  local got, from = 0, {}
  for _, cid in ipairs(order or {}) do
    if got >= n then break end
    local have = count(cid, item) or 0
    if have > 0 then
      local k = take(cid, item, math.min(have, n - got)) or 0
      if k > 0 then got = got + k; from[#from + 1] = { cid = cid, n = k } end
    end
  end
  return got, from
end
