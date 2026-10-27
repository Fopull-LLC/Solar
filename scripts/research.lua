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
}

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
  if not TECH[id] then return true end
  if save.get("game.mode") == "sandbox" then return true end
  return done()[id] == true
end

function costOf(id)
  local t = TECH[id]
  return t and t.cost or 0
end

function labelOf(id)
  local t = TECH[id]
  return t and t.label or id
end

-- What's standing in the way, as a sentence — or nil when nothing is.
function blockedBy(id)
  local t = TECH[id]
  if not t or isUnlocked(id) then return nil end
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
  return nil
end

-- The one line a locked catalogue card shows. Reads as an instruction, never as
-- a "no": either what to go and find, or what to click.
function lockLine(id)
  if isUnlocked(id) then return nil end
  local co = findScript("company")
  local money = co and co.money(costOf(id)) or ("$" .. costOf(id))
  local why = blockedBy(id)
  if why then return "LOCKED · " .. why end
  local afford = (not co) or co.afford(costOf(id))
  return string.format("LOCKED · research %s%s", money, afford and "  (click)" or "  — not enough funds")
end

-- Buy the unlock. Returns ok, reason.
function unlock(id)
  if isUnlocked(id) then return true, "already unlocked" end
  local why = blockedBy(id)
  if why then return false, why end
  local co = findScript("company")
  local cost = costOf(id)
  if co and not co.spend(cost, "research: " .. labelOf(id)) then
    return false, "not enough funds"
  end
  local d = done()
  d[id] = true
  save.set("res.done", d)
  save.set("res.spent", (save.get("res.spent") or 0) + cost)
  spent = save.get("res.spent")
  log("RESEARCH COMPLETE: " .. labelOf(id))
  -- No reputation for research any more: standing that money can buy is a
  -- price, and it would let a rich company skip the contract tiers.
  return true, labelOf(id)
end

-- Given, not bought: a programme milestone's reward (missions.lua). No money,
-- no gates — the milestone was the gate. Returns true if it was new.
function grant(id, why)
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
