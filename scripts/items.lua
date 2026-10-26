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
  o2tank    = { name = "Oxygen Tank",   kind = "worn",       kg = 8.0,  L = 5,  cost = 350,  shop = true,
                -- clipped to the PLSS; never in hand. Each tank is its own reserve of suit
                -- air (`fill`, seconds), kept per tank as item state (inventory.fills).
                worn = { prefab = "ItemO2Tank", bone = "Back" },
                fill = { cap = 900, what = "o2" },     -- 15 minutes of suit air, full
                about = "a spare bottle of breathing oxygen for the suit: +15 min of air on a long EVA or a dive" },
}

-- The belt's order: tools first, then devices and deployables, then
-- consumables with a hold. (Worn items are never on the belt.)
ORDER = { "gravgun", "laser", "beacon", "flag", "repairkit", "rcspack", "o2tank" }
local KIND_RANK = { tool = 1, device = 2, deployable = 3, consumable = 4, worn = 9 }

-- Litres by container family (docs §5.1). A cargo hold's litres come from its
-- Cargo Bays (1000 L each, set by the vessel); the base and a salvage crate
-- are unlimited.
VOL = { pack = 60, locker = 120, bay = 1000 }

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
function shopList()
  local out = {}
  for _, id in ipairs(ids()) do
    local d = ITEMS[id]
    if d.shop and d.cost then
      out[#out + 1] = { id = id, name = d.name, cost = d.cost, kg = d.kg, L = d.L, kind = d.kind, about = d.about }
    end
  end
  table.sort(out, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.id < b.id end)
  return out
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

function repairSecs(hp)
  hp = math.max(0, math.min(1, hp or 1))
  return REPAIR.secs0 + REPAIR.secs_k * (1 - hp)
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
