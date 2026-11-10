-- RESEARCH — what the catalogue is still holding back, and what it costs to
-- open it.
--
-- The company starts able to build a rocket that reaches the sky and comes back
-- down. Everything past that — bigger tanks, real engines, power, comms, docking
-- ports, cargo bays — is LOCKED, and each lock names its own price:
--
--   money        research is paid for out of the same account as hulls
--   a material   you must have HELD the stuff (see it in the inventory's
--                discovery set) before anyone will develop it
--   standing     some things nobody sells to a company with a bad record
--   another tech the obvious ladders (docking before cargo)
--
-- That is the whole point of the material economy: mining and harvesting are
-- how you pay for, and qualify for, the next part. There is no separate research
-- screen — a locked card in the builder tells you exactly what it wants and
-- unlocks on the spot when you click it, which is where you're standing when you
-- want it.
--
--     local rs = findScript("research")
--     rs.isUnlocked("dockPort")      false
--     rs.lockLine("dockPort")        "LOCKED · $900 · needs Copper Ore"
--     rs.unlock("dockPort")          → true, or false + the reason
--
-- RP AS A CURRENCY (expansion X6, PLAN §7.4; Ty 11-09: "RP is a currency on
-- the expansion TECH"). A TECH entry with `rp` costs research points beside
-- its money: the lab's points (below) are spent when it is researched, and a
-- lock short of them says how many more ("needs 40 RP: the lab has 12").
-- Nothing already researched changes; entries without `rp` cost money only.

defaults = {}

-- Anything NOT in this table ships unlocked. Keep the starter set (pod, nose,
-- chute, small tank, small engine, fins, decoupler, legs) out of it on purpose:
-- the first flight must be buildable with no research at all.
--
-- PRICED AGAINST THE CONTRACT LADDER. These used to cost $260–$1,250 against
-- contracts paying $4,500–$30,000, so one contract bought most of the catalogue
-- and research paced nothing. Now each rung of the ladder pays for the rocket it
-- needs plus roughly the next one or two unlocks, in the order you want them:
--
--   First Flight $2,500 ……… FT-M Tank $600 (the High Road wants the fuel)
--   High Road / Prospector … Anvil $1,400, Comms Dish
--   Made Orbit $11,000 ………… Radial Tank / Decoupler, Solar Panel, RCS
--   Trusted / Prime standing  Skipper, Docking Port (Rendezvous)
--
-- The GROUND game's two unlocks are cheap on purpose (2026-10-26): the Battery
-- ($300) and the Cargo Bay ($500) are what turn a rover into a hauler, and a
-- rover hauling ore is how a company that lost a rocket earns its way back
-- (missions.lua GROUND work, the depot's freight rate).
--
-- `rep` is a STANDING gate (company.lua): the parts that open interplanetary
-- work are not sold to a company nobody has heard of.
TECH = {
  tankM      = { cost = 600,  label = "FT-M Tank" },
  battery    = { cost = 300,  label = "Battery",        mat = "copper" },
  -- The bike's tank-shaped Battery Pack: the small cells. The ground network
  -- earns it (playtest 2026-11-04): the Relay Network's 25 % goal grants it
  -- (missions.lua), no copper needed; the big Battery still wants a sample of
  -- copper. `progGrant`: a save that already finished the milestone has it.
  packB      = { cost = 150,  label = "Battery Pack",   prog = "relay_net", progGrant = true,
                 progLabel = "Relay Network (25% of the ground linked)" },
  engineM    = { cost = 1400, label = "Anvil" },
  -- The relay dish is what a SATELLITE relay is made of: it opens once the
  -- ground network is up (the Relay Network milestone grants it outright), so
  -- the order is ground first, then the sky (missions.lua PROGRAMME).
  dish       = { cost = 1100, label = "Relay Dish",     mat = "copper", prog = "relay_net", progLabel = "Relay Network" },
  probe      = { cost = 800,  label = "Probe Core",     mat = "copper" },
  dishL      = { cost = 5200, label = "Deep Space Dish", mat = "silica", after = "dish", rep = 6,
                 prog = "sky", progLabel = "Eyes in the Sky" },
  radialDec  = { cost = 900,  label = "Radial Decoupler" },
  radialTank = { cost = 1200, label = "Radial Tank",    after = "tankM" },
  solar      = { cost = 2200, label = "Solar Panel",    mat = "silica",  after = "battery" },
  cargo      = { cost = 500,  label = "Cargo Bay",      mat = "iron" },
  rcs        = { cost = 2600, label = "RCS Block",      after = "engineM", rep = 3 },
  skipper    = { cost = 4500, label = "Skipper",        mat = "iron",    after = "engineM", rep = 8 },
  dockPort   = { cost = 3800, label = "Docking Port",   mat = "copper",  rep = 6, after = "rcs" },
  -- THE NUCLEAR TIER (deep-space G1; scripts/parts_nuclear.lua). The Isotope
  -- Cell wants uranium ore held: the deep band the Deep Core contract sends
  -- you to. Radiators come with it; the Ember wants standing and the panel
  -- radiators it can't run without. (G2's "Critical" milestone will grant
  -- the Pile NTR and the fuel chain later; until then the Ember's research
  -- also opens Fuel Fabrication at the Materials Intake.)
  rtg          = { cost = 2000, label = "Isotope Cell",   mat = "uranium" },
  radFin       = { cost = 300,  label = "Radiator Fin",   after = "rtg" },
  radPanel     = { cost = 1200, label = "Radiator Panel", after = "rtg" },
  radTruss     = { cost = 3200, label = "Truss Radiator", after = "radPanel", rep = 6 },
  ember        = { cost = 9000, label = "Ember Reactor",  mat = "uranium", after = "radPanel", rep = 6 },
  shadowShield = { cost = 1800, label = "Shadow Shield",  after = "ember" },
  -- THE SURVEY PARTS (expansion X1; scripts/parts_survey.lua): the scanner
  -- after the probe core (it rides a satellite), the telescope wants silica
  -- (its mirror). RP prices join in X6.
  telescopeS   = { cost = 3200, label = "Space Telescope", mat = "silica", rp = 200 },
  scanner      = { cost = 4500, label = "Orbital Scanner", after = "probe", rp = 80 },
  -- (X7) the field from orbit, after the scanner
  gravimeter   = { cost = 5200, label = "Gravimeter", after = "scanner", rp = 60 },
  -- THE REFINERIES (expansion X6; scripts/machines.lua, parts_kit REFINERY):
  -- money and research points. The crusher, the furnace and its radiators
  -- first; the kiln and the mixer want a silica sample; the electrolyser and
  -- the Fabricator come after the refinery.
  refinery     = { cost = 6000,  label = "Refinery (Crusher, Furnace)", mat = "iron", rp = 40 },
  ceramics     = { cost = 3500,  label = "Kiln and Mixer", mat = "silica", after = "refinery", rp = 30 },
  electrolysis = { cost = 9000,  label = "Electrolyser", after = "refinery", rp = 120 },
  fabrication  = { cost = 12000, label = "Fabricator", after = "refinery", rp = 150 },
  -- THE BUILD KIT (deep-space M3): not bought, GIVEN: the Relay Network's
  -- first goal (10 % of the ground linked) grants it (missions.lua), and from
  -- then the Depot stocks it and every Engineer is issued one at the base
  -- (field_builder). `grantOnly`: no price, no click; `permGrant`: a save
  -- that already passed that goal has it.
  buildkit     = { cost = 0, label = "Build Kit", grantOnly = true, permGrant = { "relay_net", 1 },
                   grantLabel = "10% of the ground linked (Relay Network)" },
}

-- BASE parts behind a craft part's research (the BASE section's ids are not
-- tech ids): the Isotope Skid is four Isotope Cells.
ALIAS = { isotopeSkid = "rtg" }
local function tid(id) return ALIAS[id] or id end

-- Published for panels.
spent = 0

-- ── rare samples ────────────────────────────────────────────────────────────
-- What the rare finds are, as materials: one specimen per niche (flora_gen
-- `rareFor`, flora_field cuts them) and the geode the ore pockets hold
-- (mineral_field). They are registered into the materials table at start, from
-- here because this script is mounted in every scene that weighs, lists or
-- prices a material (the system scene and the builder). Their first sight is
-- what the programme's Rare Finds milestone asks for (`sample`), and the depot
-- pays the tier-3 discovery premium on each.
RARE_MATS = {
  rare_cave   = { name = "Gloamcap Spores",   kg = 0.3, value = 40,  tier = 3, class = "flora" },
  rare_peak   = { name = "Frostbloom Petals", kg = 0.2, value = 40,  tier = 3, class = "flora" },
  rare_ravine = { name = "Ravine Ember Pods", kg = 0.4, value = 40,  tier = 3, class = "flora" },
  rare_lake   = { name = "Shore Pearls",      kg = 0.3, value = 40,  tier = 3, class = "flora" },
  rare_river  = { name = "Silkspire Fronds",  kg = 0.3, value = 40,  tier = 3, class = "flora" },
  geode       = { name = "Star Geode",        kg = 1.4, value = 120, tier = 3, class = "ore" },
}

local registered = nil
-- Idempotent; safe to call every frame (it does the work once per materials
-- script). Returns true once the materials table holds them.
function registerMaterials()
  local m = findScript and findScript("materials")
  if not (m and m.REG) then return false end
  if registered == m and m.REG.geode then return true end
  for id, def in pairs(RARE_MATS) do
    if not m.REG[id] then
      m.REG[id] = { name = def.name, kg = def.kg, value = def.value, tier = def.tier, class = def.class }
    end
  end
  registered = m
  return m.REG.geode ~= nil
end

function start(node)
  registerMaterials()
end

function update(node, dt)
  if registered == nil or not registered.valid then registerMaterials() end
end

local function done()
  return save.get("res.done") or {}
end

-- A SANDBOX save (company.lua, `game.mode`) has the whole catalogue open from
-- the start: money is no object there, so a research price is only a click.
function isUnlocked(id)
  id = tid(id)
  if not TECH[id] then return true end
  if save.get("game.mode") == "sandbox" then return true end
  if TECH[id].progGrant and (save.get("prog.done") or {})[TECH[id].prog] then return true end
  local pg = TECH[id].permGrant
  if pg then
    local pm = (save.get("prog.perm") or {})[pg[1]]
    if (save.get("prog.done") or {})[pg[1]] or (type(pm) == "table" and (pm[pg[2]] or pm[tostring(pg[2])])) then return true end
  end
  return done()[id] == true
end

function costOf(id)
  local t = TECH[tid(id)]
  return t and t.cost or 0
end

-- (X6) research points it costs (0: money only)
function rpOf(id)
  local t = TECH[tid(id)]
  return t and t.rp or 0
end

function labelOf(id)
  local t = TECH[tid(id)]
  return t and t.label or id
end

-- What's standing in the way, as a sentence — or nil when nothing is.
function blockedBy(id)
  id = tid(id)
  local t = TECH[id]
  if not t or isUnlocked(id) then return nil end
  if t.grantOnly then return "needs " .. (t.grantLabel or "a milestone") end
  if t.after and not isUnlocked(t.after) then
    return "needs " .. labelOf(t.after)
  end
  -- A programme milestone (missions.lua PROGRAMME). Read from the save, not
  -- from missions: the builder has no missions script, and the answer must be
  -- the same in both scenes.
  if t.prog and not (save.get("prog.done") or {})[t.prog] then
    return "needs the " .. (t.progLabel or t.prog) .. " milestone"
  end
  if t.mat then
    local inv, mats = findScript("inventory"), findScript("materials")
    if inv and not inv.seen(t.mat) then
      return "needs a sample of " .. ((mats and mats.label(t.mat)) or t.mat)
    end
  end
  if t.rep then
    local co = findScript("company")
    if co and co.rep() < t.rep then
      local st = co.standing and co.standing(t.rep)
      return string.format("needs reputation %+d%s", t.rep,
        st and (" (" .. st.name .. ")") or "")
    end
  end
  -- (X6) research points: spent, so the lab must hold them
  if (t.rp or 0) > 0 and points() < t.rp then
    return string.format("needs %d RP (the lab has %d: study samples at the Research Lab)", t.rp, points())
  end
  return nil
end
-- "$6,000 + 40 RP" (or the money alone)
function priceText(id, money)
  local c = costOf(id)
  local m = money and money(c) or ("$" .. tostring(c))
  local rp = rpOf(id)
  if rp > 0 then return m .. " + " .. rp .. " RP" end
  return m
end

-- The one line a locked catalogue card shows. Reads as an instruction, never as
-- a "no": either what to go and find, or what to click.
function lockLine(id)
  id = tid(id)
  if isUnlocked(id) then return nil end
  local co = findScript("company")
  local money = priceText(id, co and co.money)
  local why = blockedBy(id)
  if why then return "LOCKED · " .. why end
  local afford = (not co) or co.afford(costOf(id))
  return string.format("LOCKED · research %s%s", money, afford and "  (click)" or "  — not enough funds")
end

-- Buy the unlock. Returns ok, reason.
function unlock(id)
  id = tid(id)
  if isUnlocked(id) then return true, "already unlocked" end
  local why = blockedBy(id)
  if why then return false, why end
  local co = findScript("company")
  local cost = costOf(id)
  local rp = rpOf(id)
  if rp > 0 and points() < rp then return false, string.format("needs %d RP", rp) end
  if co and not co.spend(cost, "research: " .. labelOf(id)) then
    return false, "not enough funds"
  end
  if rp > 0 then
    -- (X6) the points are spent: the lab's tally goes down, the spend is kept
    save.set("res.pts", points() - rp)
    save.set("res.rpSpent", (save.get("res.rpSpent") or 0) + rp)
  end
  local d = done()
  d[id] = true
  save.set("res.done", d)
  save.set("res.spent", (save.get("res.spent") or 0) + cost)
  spent = save.get("res.spent")
  log("RESEARCH COMPLETE: " .. labelOf(id) .. (rp > 0 and string.format(" (%d RP spent, %d left)", rp, points()) or ""))
  -- No reputation for research any more: standing that money can buy is a
  -- price, and it would let a rich company skip the contract tiers.
  return true, labelOf(id)
end

-- Given, not bought: a programme milestone's reward (missions.lua). No money,
-- no gates — the milestone was the gate. Returns true if it was new.
function grant(id, why)
  id = tid(id)
  if not TECH[id] or isUnlocked(id) then return false end
  local d = done()
  d[id] = true
  save.set("res.done", d)
  log("RESEARCH GRANTED: " .. labelOf(id) .. (why and ("  (" .. why .. ")") or ""))
  return true
end

-- Called by the depot when a first sale lands: a discovery can turn a "needs a
-- sample of…" lock into a purchasable one, and the player should hear about it
-- rather than find out by walking back to the builder.
function noteDiscovery()
  local ready = {}
  for id in pairs(TECH) do
    if not isUnlocked(id) and not blockedBy(id) then ready[#ready + 1] = labelOf(id) end
  end
  table.sort(ready)
  if #ready > 0 then
    log("R&D: ready to research — " .. table.concat(ready, ", "))
  end
  return ready
end

-- Everything still locked, with its reason — the "what should I do next" list.
function pendingLines()
  local out = {}
  local ids = {}
  for id in pairs(TECH) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return TECH[a].cost < TECH[b].cost end)
  for _, id in ipairs(ids) do
    if not isUnlocked(id) then
      out[#out + 1] = string.format("%-18s %s", labelOf(id), lockLine(id))
    end
  end
  return out
end

-- ── RESEARCH POINTS (the Research Lab, 2026-11-03) ──────────────────────────
-- What the lab has learned, as one number you play for: points are earned
-- when a material goes in at the Materials Intake (material_intake.lua) and a
-- sample of it is sent up the tube to the lab (lab.lua) to be studied. More
-- for a kind the lab has never seen. The research tree that will SPEND them is
-- still to come; for now they are a stat on the HUD and in the save.
--
--   res.pts        the points
--   res.studied    { [mat] = { n = units studied, rp = points from it,
--                    t = game time first studied, from = { [body] = true } } }
--
-- What a unit is worth comes from materials.researchValue(mat, origin,
-- firstTime) when that exists (the per-planet ores); otherwise from the
-- placeholder below. A kind's first study is worth at least FIRST_MIN, so
-- even bulk rock (worth nothing per unit) is worth characterising once.
FIRST_MIN = 5
-- the placeholder: points per unit by grade / class, and for scrap per kg
RP_PLACEHOLDER = { bulk = 0.05, ore = 1.0, flora = 0.6, ice = 0.6, liquid = 0.2, refined = 1.5, scrap_kg = 0.004 }
RP_TIER = { [0] = 0.5, [1] = 1.0, [2] = 2.5, [3] = 6.0, [4] = 14.0 }

local function mats_ref()
  return findScript and findScript("materials") or nil
end

function points() return save.get("res.pts") or 0 end
-- (X6) points spent on research, and the list of what RP buys:
-- { { id, label, cost, rp, done, why } } by RP
function rpSpent() return save.get("res.rpSpent") or 0 end
function rpTree()
  local out = {}
  for id, t in pairs(TECH) do
    if (t.rp or 0) > 0 then
      out[#out + 1] = { id = id, label = t.label, cost = t.cost, rp = t.rp, done = isUnlocked(id), why = blockedBy(id) }
    end
  end
  table.sort(out, function(a, b) if a.rp ~= b.rp then return a.rp < b.rp end return a.id < b.id end)
  return out
end
function studied() return save.get("res.studied") or {} end

-- (pure, for tests: m = the materials script or nil)
function valueOf(m, mat, qty, origin, first)
  qty = qty or 1
  if mat == "scrap" then
    return (qty * RP_PLACEHOLDER.scrap_kg) * (first and 5 or 1)
  end
  if m and m.researchValue then
    local ok, v = pcall(m.researchValue, mat, origin, first)
    if ok and type(v) == "number" then return v * qty end
  end
  local g = (m and m.grade and m.grade(mat)) or "ore"
  local per = RP_PLACEHOLDER[g] or RP_PLACEHOLDER.ore
  local t = (m and m.tier and m.tier(mat)) or 1
  per = per * (RP_TIER[t] or 1)
  return per * qty * (first and 5 or 1)
end

-- Study `qty` units of `mat` (or, for wreckage, mat = "scrap" and qty in kg).
-- Returns the points gained (whole), and true when the kind is new to the lab.
function study(mat, qty, origin)
  if not mat then return 0, false end
  local st = studied()
  local rec = st[mat]
  local first = rec == nil
  local m = mats_ref()
  local v = valueOf(m, mat, qty, origin, first)
  if first then v = math.max(v, FIRST_MIN) end
  local carry = save.get("res.frac") or 0
  local total = v + carry
  local gained = math.floor(total)
  save.set("res.frac", total - gained)
  rec = rec or { n = 0, rp = 0, t = space and space.time and space.time() or (time or 0), from = {} }
  rec.n = rec.n + (qty or 1)
  rec.rp = rec.rp + v
  if origin then rec.from = rec.from or {}; rec.from[origin] = true end
  st[mat] = rec
  save.set("res.studied", st)
  save.set("res.pts", points() + gained)
  if log then log(string.format("research: studied %s ×%s → +%d RP%s (total %d)", tostring(mat), tostring(qty),
    gained, first and " (a new kind)" or "", points())) end
  return gained, first
end

-- (expansion X1) Points earned by NEW SURVEY DATA (scripts/survey.lua): a
-- layer of a world's record filled for the first time. Whole points onto
-- the lab's tally; `why` goes to the log. → the points added.
function addPoints(n, why)
  n = math.floor((n or 0) + 0.5)
  if n <= 0 then return 0 end
  save.set("res.pts", points() + n)
  save.set("res.survey", (save.get("res.survey") or 0) + n)
  if log then log(string.format("research: +%d RP (%s), total %d", n, tostring(why or "survey"), points())) end
  return n
end

-- The studied kinds as a list, most recent first: { mat, n, rp, t }.
function studiedList()
  local out = {}
  for mat, r in pairs(studied()) do out[#out + 1] = { mat = mat, n = r.n or 0, rp = r.rp or 0, t = r.t or 0 } end
  table.sort(out, function(a, b) if a.t ~= b.t then return a.t > b.t end return a.mat < b.mat end)
  return out
end
