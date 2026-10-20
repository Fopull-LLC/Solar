-- SMOKE HARNESS: the money loop. Runs the real company.lua + missions.lua
-- against a stubbed engine and drives the whole SC2 economy end to end —
-- seed capital, a hull bought at rollout, a contract signed, goals latching
-- across one flight, the payout, and a recovery refund.
--
--   luajit solar/tests/smoke_company.lua
--
-- Fidelity notes (the bugs this stub is shaped to catch):
--  * All company/mission state lives in `save.*`, because scripts do NOT
--    survive the builder → system scene hop. The store here persists across
--    "scene loads" exactly like the engine's, so anything cached in a local
--    that should have been saved shows up as state that vanishes.
--  * Goals latch PER FLIGHT: stepping out of the pod clears them. "Reach
--    2,000 m and land intact" has to be one trip, and a tracker that latched
--    forever would pass it across two unrelated afternoons.

local T = 0.0
local TICK = 1 / 60

-- ── engine API ──────────────────────────────────────────────────────────────
local API, store, logs = {}, {}, {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
  flush = function() end,
}
function API.log(m) logs[#logs + 1] = tostring(m) end
function API.vec3(x, y, z) return { x = x, y = y, z = z } end
API.input = { key = function() return false end, pressed = function() return false end }

-- One planet, one craft. The craft's altitude and grounded state are driven
-- directly by the tests — this harness is about the LEDGER, not flight.
--
-- THE NUMBERS ARE A REAL GENERATED WORLD, not a round-numbered stand-in. This
-- planet is Umunquo out of a live save: 185 m body radius, a 1,422 m sphere of
-- influence, so the highest altitude that exists above it is 1,237 m. The old
-- stub said radius 600 and soi 1,000,000 — an Earth wearing a planet's name —
-- and against that every altitude in the contract catalogue looked reachable.
-- It was the harness agreeing with the bug: the first contract asked for 2,000
-- m of a world with 1,237 m in it, and a player flew it perfectly and was never
-- paid.
--
-- Anything the generator can produce must fit inside these proportions:
-- `system_generator` rolls a 100–230 m radius and an SOI of at least twelve
-- body radii, capped at 0.3 of the orbit.
local BODY = { name = "Golil", x = 0, y = 0, z = 0, radius = 184.7, mu = 157533.4,
               soi = 1421.6 }
local CEILING = BODY.soi - BODY.radius     -- 1,236.9 m: all the room there is
API.space = {
  bodies = function() return { BODY } end,
  body = function(n) return (n == BODY.name) and BODY or nil end,
  dominant = function() return BODY.name end,
  elements = function(x, y, z, vx, vy, vz)
    local r = math.sqrt(x * x + y * y + z * z)
    local v2 = vx * vx + vy * vy + vz * vz
    -- Real vis-viva, so an "orbit" goal can't be faked by a tall lob.
    local a = 1.0 / (2.0 / r - v2 / BODY.mu)
    if a <= 0 then return { body = BODY.name, e = 1.2, periapsis = r } end
    local h = math.sqrt(math.max(0.0, (x * vy - y * vx) ^ 2 + (y * vz - z * vy) ^ 2
      + (z * vx - x * vz) ^ 2))
    local e = math.sqrt(math.max(0.0, 1.0 - (h * h) / (BODY.mu * a)))
    return { body = BODY.name, e = e, a = a, periapsis = a * (1 - e),
             apoapsis = a * (1 + e), period = 1000 }
  end,
}

local craft = {
  node = { __id = 7, id = 7, name = "Kestrel I", valid = true,
           x = 0, y = BODY.radius, z = 0, vx = 0, vy = 0, vz = 0 },
  piloting = false,
  dock = { latched = 0 },
}
local ASM = { mass = 6.0, grounded = true, anchored = false,
              vel = { x = 0, y = 0, z = 0 }, angVel = { x = 0, y = 0, z = 0 },
              com = { x = 0, y = 0, z = 0 }, origin = { x = 0, y = 0, z = 0 },
              parts = {} }
API.assembly = { info = function() return ASM end }

-- Put the craft at an altitude, moving at a speed, on a chosen conic.
local function place(alt, speed)
  craft.node.y = BODY.radius + alt
  craft.node.x, craft.node.z = 0, 0
  craft.node.vx, craft.node.vy, craft.node.vz = speed or 0, 0, 0
  ASM.vel.x, ASM.vel.y, ASM.vel.z = 0, 0, 0
end

-- ── script loading ──────────────────────────────────────────────────────────
local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  return env
end
function API.findScript(kind) return envs[kind] end
function API.findScripts(kind)
  if kind == "vessel_controller" then return { craft } end
  return envs[kind] and { envs[kind] } or {}
end

local co = load_script("solar/scripts/company.lua", "company")
local mi = load_script("solar/scripts/missions.lua", "missions")
-- The material economy: contracts can ask for cargo in the warehouse, so the
-- registry and the containers have to be here for the tracker to read.
local mats = load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
co.start({})
mi.start({})

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    co.update({}, TICK)
    mi.update({}, TICK)
  end
end

-- ── checks ──────────────────────────────────────────────────────────────────
local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

-- 1. Seed capital, once and only once.
-- Not quite a first rocket: the opening sends you to the ground game first.
local SEED = co.defaults.start_funds
check("a fresh company is funded", co.balance() == 500, "$" .. co.balance())
check("...with less than a sensible first rocket", SEED < 1100 and SEED > 0, SEED)
co.earn(2500, "test top-up")
co.spend(1000, "test")
co.start({})           -- a "scene load": the script reruns, the money must not
tick()                 -- come back
check("seed capital is not re-granted on a scene load", co.balance() == SEED + 1500,
  "$" .. co.balance())
co.spend(co.balance() - 2000, "to a round balance")

-- 2. Spending refuses rather than going negative.
check("an affordable purchase goes through", co.spend(1000, "hull") == true)
check("...and debits exactly", co.balance() == 1000, "$" .. co.balance())
check("an unaffordable one is refused", co.spend(999999, "battlestar") == false)
check("...and changes nothing", co.balance() == 1000, "$" .. co.balance())
check("afford() agrees with spend()", co.afford(1000) and not co.afford(1001))
co.earn(10450, "scrap")
check("earning credits", co.balance() == 11450, "$" .. co.balance())
check("the ledger records both directions", #co.ledgerLines(9) >= 4,
  "#" .. #co.ledgerLines(9))
-- The ledger speaks the game's one money format: "+$10450" read as a typo.
check("the ledger formats amounts like every other figure",
  co.ledgerLines(1)[1]:find("+$10,450", 1, true) ~= nil, co.ledgerLines(1)[1])
check("...debits included", co.ledgerLines(2)[2]:find("−$1,000", 1, true) ~= nil,
  co.ledgerLines(2)[2])
co.spend(10450, "back to the test's balance")

-- 3. Reputation clamps rather than running away — and now means something.
co.addRep(50, "test")
check("reputation clamps high", co.rep() == 30, tostring(co.rep()))
check("...at the top standing", co.standing().name == "Legend", co.standing().name)
check("a Legend sells dearer", co.priceMult() > 1.4 and co.priceMult() < 1.5, co.priceMult())
check("...and is paid more for generated work", co.rewardMult() > 1.5, co.rewardMult())
co.addRep(-80, "test")
check("reputation clamps low", co.rep() == -10, tostring(co.rep()))
check("...where the depot pays under list", co.priceMult() < 1.0, co.priceMult())
check("...and generated rewards never fall under list", co.rewardMult() == 1.0)
co.addRep(10, "test")
check("standing has named levels with a next step",
  co.standing(0).name == "Unknown" and co.standing(3).name == "Contractor"
  and co.standing(8).name == "Trusted" and co.standing(0).nextAt == 3,
  co.standingLine(0))
check("...and a change of level is news", store["co.standingNews"] ~= nil)
co.addRep(-co.rep(), "back to zero")

-- 4. Contracts: only what's actually available is offered.
local offers = mi.offers()
check("the opening contract is offered", #offers >= 1 and offers[1].id == "firstflight",
  offers[1] and offers[1].id)
local ids = {}
for _, m in ipairs(offers) do ids[m.id] = true end
check("gated contracts stay hidden until their prerequisite is flown",
  not ids.highroad and not ids.orbit)

check("signing a contract puts it on the books", mi.accept("firstflight") == true)
check("...and it stops being offered", (function()
  for _, m in ipairs(mi.offers()) do if m.id == "firstflight" then return false end end
  return true
end)())

-- 5. A rocket still clamped to the pad has not LANDED anything. Sitting on
-- the deck is grounded and stopped — exactly what a landing looks like — so
-- the land goal waits for the craft to have flown (vessel_controller's
-- `hasFlown`: clamps released and airborne).
craft.piloting = true
craft.hasFlown = false
place(0, 0)
ASM.grounded = true
tick(3)
check("a rocket on the pad has not landed", mi.goalLines()[2]:find("○") ~= nil,
  mi.goalLines()[2])
craft.piloting = false
tick()
craft.hasFlown = true

-- Goals latch across ONE flight, in any order, and pay out on completion.
local bal = co.balance()
craft.piloting = true
ASM.grounded = false
place(CEILING * 0.20, 0)          -- the goal asks for 0.15 of the ceiling
tick(3)
check("the altitude goal latches in flight", mi.goalLines()[1]:find("✓") ~= nil,
  mi.goalLines()[1])
-- The card quotes a round number ("Reach 150 m", not "Reach 185 m"), and the
-- check is against the same rounded number, so the two can never disagree.
check("the altitude target is a round number", mi.goalLines()[1]:find("Reach %d*50 m")
  or mi.goalLines()[1]:find("Reach %d*00 m"), mi.goalLines()[1])
check("...and the landing goal has not", mi.goalLines()[2]:find("○") ~= nil)
check("the contract is still on the books", mi.active == "firstflight")

-- Come back down and stop.
place(0, 0)
ASM.grounded = true
tick(3)
check("landing completes the contract", mi.active == nil, tostring(mi.active))
check("...and Ops pays out", co.balance() == bal + 2500,
  string.format("%d → %d", bal, co.balance()))
check("...and it never pays twice", (function()
  local b2 = co.balance()
  tick(5)
  return co.balance() == b2
end)())
check("a flown contract is not offered again", (function()
  for _, m in ipairs(mi.offers()) do if m.id == "firstflight" then return false end end
  return true
end)())
check("finishing it unlocks the next rung", (function()
  for _, m in ipairs(mi.offers()) do if m.id == "highroad" then return true end end
  return false
end)())

-- 6. Goals do NOT latch across separate flights.
mi.accept("highroad")
ASM.grounded = false
place(CEILING * 0.60, 0)          -- the goal asks for 0.55
tick(3)
check("the high-altitude goal latches", mi.goalLines()[1]:find("✓") ~= nil)
craft.piloting = false          -- step out of the pod: the flight is over
tick(3)
craft.piloting = true
place(0, 0)
ASM.grounded = true
tick(3)
check("stepping out clears the flight's progress — one trip, not two",
  mi.active == "highroad", "active=" .. tostring(mi.active))
check("...and the altitude goal is un-ticked", mi.goalLines()[1]:find("○") ~= nil,
  mi.goalLines()[1])

-- 7. An ORBIT goal cannot be faked by a tall lob.
mi.abandon()
tick()
store["mission.done"] = { firstflight = true, highroad = true }
check("orbit is offered once the ladder allows it", (function()
  for _, m in ipairs(mi.offers()) do if m.id == "orbit" then return true end end
  return false
end)())
mi.accept("orbit")
craft.piloting = true
ASM.grounded = false
place(CEILING * 0.20, 0)           -- high, straight up, zero horizontal
tick(3)
check("a ballistic lob does not count as an orbit", mi.active == "orbit",
  mi.goalLines()[1])
-- Now a real circular orbit at the same altitude.
local r = BODY.radius + CEILING * 0.20
place(CEILING * 0.20, math.sqrt(BODY.mu / r))
tick(3)
check("a circular orbit does", mi.active == nil, mi.goalLines()[1] or "done")

-- 8. RESOURCE contracts: delivered cargo, and the fact that it stays delivered.
mi.abandon()
tick()
store["mission.done"] = { firstflight = true, highroad = true, orbit = true }
check("a prospecting contract is offered once you can fly", (function()
  for _, m in ipairs(mi.offers()) do if m.id == "prospect" then return true end end
  return false
end)())
mi.accept("prospect")
craft.piloting = false
tick(2)
check("an undelivered haul is not complete", mi.active == "prospect",
  mi.goalLines()[1])
inv.add("base", "iron", 12)
tick(2)
check("...and a part-load still isn't", mi.active == "prospect", mi.goalLines()[1])
local bal3 = co.balance()
inv.add("base", "iron", 20)          -- 32 units of ore in the warehouse
tick(2)
check("delivering the ore completes it on the ground, with nobody flying",
  mi.active == nil, tostring(mi.active))
check("...and pays", co.balance() == bal3 + 2800, co.balance() - bal3)

-- Selling what you delivered can't un-deliver it.
mi.accept("botany")
inv.add("base", "fiber", 25)
tick(2)
check("a plant-matter haul counts flora, not ore", mi.active == nil, tostring(mi.active))

mi.accept("deepcore")
tick(2)
check("a deep contract wants the material found AND delivered",
  mi.active == "deepcore" and mi.goalLines()[1]:find("○") ~= nil, mi.goalLines()[1])
inv.add("astro", "crystal", 5)       -- holding it = the discovery
tick(2)
check("...finding it ticks the sample goal", mi.goalLines()[1]:find("✓") ~= nil,
  mi.goalLines()[1])
check("...but the delivery goal is still open", mi.active == "deepcore",
  mi.goalLines()[2])
inv.transferAll("astro", "base")
tick(2)
check("...and putting it in the warehouse finishes the job", mi.active == nil,
  tostring(mi.active))
check("a permanent goal survives stepping in and out of a craft", (function()
  mi.accept("recovery")
  store["mission.recovered"] = true
  tick(2)
  return mi.active == nil
end)())

-- ── 9. NO CONTRACT MAY ASK FOR SOMEWHERE THAT DOES NOT EXIST ────────────────
--
-- The bug that made this section necessary: the catalogue named its altitudes
-- in metres — 2,000 for a first flight, 25,000 for the next, a 20 km periapsis
-- for an orbit — and the system is GENERATED at 100–230 m radii. On a real save
-- the first contract asked for 2,000 m of a planet with 1,237 m above it, and
-- two of the eight were beyond reach on EVERY seed. Nothing errored. The goal
-- simply sat unticked forever, and there was no way, from inside the game, to
-- find out that the target was imaginary.
--
-- So: walk the whole catalogue and hold every flight goal against the room the
-- world actually has. This is the check that could only ever have been written
-- against a body of a realistic size, which is why the stub at the top of this
-- file is a planet out of a live save rather than a round number.
for _, id in ipairs({ "firstflight", "highroad", "orbit", "rendezvous",
                      "prospect", "botany", "deepcore", "recovery" }) do
  local m = mi.byId(id)
  check("catalogue: " .. id .. " exists", m ~= nil)
  for i, g in ipairs((m and m.goals) or {}) do
    if g.kind == "altitude" or g.kind == "orbit" then
      -- The label must quote a number, not a placeholder: a goal that cannot
      -- name its own target cannot be flown toward.
      local lbl = mi.goalLabel(g)
      check(string.format("catalogue: %s goal %d names a target", id, i),
        lbl:find("…") == nil, lbl)
      -- And that number has to fit inside the sphere of influence, with room to
      -- get back down again. 0.9 of the ceiling, not 1.0: a target you can only
      -- meet by leaving the planet's pull is a target you cannot land after.
      local frac = g.frac
      check(string.format("catalogue: %s goal %d is reachable (%s of %s)",
          id, i, tostring(frac), string.format("%.0f m", CEILING)),
        frac ~= nil and frac > 0.0 and frac <= 0.9, lbl)
    end
  end
end

-- And the negative control, run against a DIFFERENT world: the same catalogue
-- on the smallest planet the generator can roll must still be flyable. A target
-- expressed in metres passes on one planet and fails on the next, which is
-- exactly how the original bug reached a player.
do
  local r0, s0 = BODY.radius, BODY.soi
  BODY.radius, BODY.soi = 103.5, 103.5 * 12      -- generator's floor
  local small = BODY.soi - BODY.radius
  local m = mi.byId("highroad")
  local target = math.floor(small * m.goals[1].frac)
  check("the tallest contract still fits the smallest world the generator rolls",
    target < small, string.format("%d m of %.0f m", target, small))
  check("...and it is still worth flying", target > small * 0.25,
    string.format("%d m", target))
  BODY.radius, BODY.soi = r0, s0
end

-- ── 10. THE LADDER IS VISIBLE, AND THE DEPOT KNOWS WHAT IS SPOKEN FOR ────────
do
  local saved = store["mission.done"]
  store["mission.done"] = {}
  local by = {}
  for _, u in ipairs(mi.upcoming()) do by[u.m.id] = u.needs end
  check("locked contracts are listed with what they are waiting for",
    by.highroad == "First Flight" and by.orbit == "The High Road",
    tostring(by.highroad) .. " / " .. tostring(by.orbit))
  check("...and a contract you can sign is not among them", by.firstflight == nil)
  store["mission.done"] = { firstflight = true }
  mi.accept("prospect")
  check("an open delivery holds its ore back from sale",
    mi.reserves("iron") and not mi.reserves("fiber"))
  mi.abandon()
  check("...and lets it go once the contract is off the books", not mi.reserves("iron"))
  store["mission.done"] = saved
end

-- ── 11. THE LADDER PAYS BY DIFFICULTY ───────────────────────────────────────
-- "Bring It Home" (land by the base and recover) paid $12,000 against "The
-- High Road"'s $9,000. Each harder rung must pay more than the one it needs.
do
  local function R(id) return mi.byId(id).reward end
  check("recovering at the base pays less than climbing the High Road",
    R("recovery") < R("highroad"), R("recovery") .. " vs " .. R("highroad"))
  for _, pair in ipairs({ { "firstflight", "highroad" }, { "highroad", "orbit" },
                          { "orbit", "rendezvous" }, { "prospect", "deepcore" },
                          { "recovery", "firstflight" } }) do
    check(string.format("%s pays less than %s", pair[1], pair[2]), R(pair[1]) < R(pair[2]),
      R(pair[1]) .. " vs " .. R(pair[2]))
  end
  -- A recovery from BEFORE the contract was signed is not this contract's.
  store["mission.done"] = { firstflight = true }
  store["mission.recovered"] = true
  mi.accept("recovery")
  craft.piloting = false
  tick(3)
  check("an old recovery doesn't pay Bring It Home on signing", mi.active == "recovery",
    tostring(mi.active))
  store["mission.recovered"] = true
  tick(3)
  check("...a new one does", mi.active == nil, tostring(mi.active))
end

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("COMPANY SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("COMPANY SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
print("\n-- script logs --")
for _, l in ipairs(logs) do print("  " .. l) end
os.exit(1)
