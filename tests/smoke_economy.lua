-- SMOKE HARNESS: THE ECONOMY RULES (playtest 2026-10-26).
--
-- "It's still quite hard to get money and hard to recover when you've spent a
-- lot and wasted it … bike parts should be the cheapest and rover parts
-- shouldn't be too pricey, to encourage building exploration vehicles; space
-- exploration should be the real pricey thing."
--
-- This drives the REAL company, missions, materials, inventory, research and
-- part registries (through tools/perf/econ_sim.lua's stubbed world) and holds
-- the economy to that:
--   * parts are priced by what they are for: bike < rover < aircraft < space;
--   * GROUND WORK — supply orders, bulk hauls and survey drives — opens with
--     the First Steps milestone, pays well over the depot, takes the goods it
--     buys, counts a drive on the odometer and pays when the vehicle is parked;
--   * Mission Control's ADVANCE steps in when a company that has flown is
--     broke, is repaid from a quarter of income, and is never stacked;
--   * a landed craft refunds 85%;
--   * the economy simulation: the opening still ends in a first launch about
--     five minutes in, and a company that crashed three rockets is back where
--     it was in minutes, not an hour.
--
--   luajit solar/tests/smoke_economy.lua
--   SOLAR_ECON_TABLE=1 luajit solar/tests/smoke_economy.lua   # print the sim

local ROOT = "solar"
local sim = dofile(ROOT .. "/tools/perf/econ_sim.lua")

local fails, passes = {}, 0
local function check(ok, desc, detail)
  if ok then passes = passes + 1
  else fails[#fails + 1] = desc .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or "") end
end

-- ── 1. parts priced by what they're for ────────────────────────────────────
do
  local W = sim.world(ROOT)
  local cost = W.cost
  local maxAuto = 0
  for id, d in pairs(W.auto.PARTS) do maxAuto = math.max(maxAuto, d.cost) end
  check(maxAuto <= 60, "every bike part costs tens of dollars", maxAuto)
  for _, id in ipairs({ "roverBody", "wheelS", "wheelM", "wheelL", "seat", "locker", "cargo" }) do
    check(cost(id) <= 150, "rover part " .. id .. " is cheap", cost(id))
  end
  for _, id in ipairs({ "engineM", "skipper", "probe", "dish", "dishL", "dockPort" }) do
    check(cost(id) >= 900, "space part " .. id .. " is the expensive tier", cost(id))
  end
  local minAero, maxAero = math.huge, 0
  for _, d in pairs(W.aero.PARTS) do
    minAero, maxAero = math.min(minAero, d.cost), math.max(maxAero, d.cost)
  end
  check(minAero >= 50 and maxAero <= 1000, "aircraft parts are the moderate tier",
    minAero .. "–" .. maxAero)
  check(cost("jet") < cost("engineM"), "a turbojet costs less than an orbital engine")
  check(cost("tankS") < cost("tankM") and cost("engineS") < cost("engineM")
    and cost("engineM") < cost("skipper") and cost("dish") < cost("dishL"),
    "the order inside the space tier still reads small → big")
  local c = {}
  for n in pairs(sim.CRAFT) do c[n] = W.craft(n) end
  check(c.bike < 300, "a whole bike is a couple of hundred dollars", c.bike)
  check(c.rover < 600, "a rover with a hold is a few hundred", c.rover)
  check(c.bike < c.rover and c.rover < c.starter and c.starter < c.plane
    and c.plane < c.orbiter and c.orbiter < c.probe,
    "craft: bike < rover < starter rocket < plane < orbiter < probe",
    string.format("%d %d %d %d %d %d", c.bike, c.rover, c.starter, c.plane, c.orbiter, c.probe))
  check(c.starter > W.co.defaults.start_funds, "the opening balance still isn't a rocket",
    c.starter)
  check(W.rs.costOf("cargo") <= 600 and W.rs.costOf("battery") <= 400,
    "the rover's unlocks (Cargo Bay, Battery) are cheap research")
end

-- ── 2. recovery ────────────────────────────────────────────────────────────
do
  local W = sim.world(ROOT)
  check(math.abs(W.recover - 0.85) < 1e-9, "a landed craft refunds 85%", W.recover)
  local f = io.open(ROOT .. "/scripts/tracking_station.lua"):read("*a")
  check(f:find("local RECOVER_RATE = 0%.85") ~= nil, "the tracking station refunds at the same rate")
  check(W.freight > 0, "the depot pays a freight rate on goods off a craft", W.freight)
end

-- ── 3. ground work ─────────────────────────────────────────────────────────
do
  local W = sim.world(ROOT)
  local mi, co, inv, mats, store = W.mi, W.co, W.inv, W.mats, W.store
  local function offers_ground()
    local out = {}
    for _, s in ipairs(mi.offers()) do if s.ground then out[s.kind] = s end end
    return out
  end
  W.tick(120)
  check(next(offers_ground()) == nil, "no ground work before the First Steps milestone")
  local up = mi.upcoming()
  local shown = false
  for _, u in ipairs(up) do if u.m.id == "tier0" then shown = true end end
  check(shown, "...and the board says what opens it")
  store["prog.done"] = { first_steps = true }
  W.tick(120)
  local g = offers_ground()
  check(g.order and g.bulk, "First Steps opens supply orders and bulk hauls (two slots at Unknown)")
  check(mi.tierLine():find("Ground work") ~= nil, "the tier line names ground work", mi.tierLine())
  local order, bulk = g.order, g.bulk
  -- the order pays well over what the depot would give for the same goods
  local og, bg = order.goals[1], bulk.goals[1]
  local function depot_worth(goal)
    local ppk = goal.mat and (mats.value(goal.mat) / mats.kg(goal.mat)) or 3.3
    return goal.kg * ppk
  end
  check(order.reward >= 2.5 * depot_worth(og), "a supply order pays ≥2.5× the depot",
    order.reward .. " vs " .. depot_worth(og))
  check(bg.kg > 90, "a bulk haul is more than a suit carries", bg.kg)
  check(bulk.reward / bg.kg > order.reward / og.kg * 0.9 and bulk.reward > 3 * depot_worth(bg),
    "a bulk haul pays a rover's worth", bulk.reward)
  check(order.rep == 0 and bulk.rep == 0, "ground work pays money, not standing")
  -- sign the bulk haul; deliver it; the buyer TAKES the goods
  local mat = bg.mat or "iron"
  local units = math.ceil(bg.kg / mats.kg(mat)) + 5
  inv.add("base", mat, units)
  store["depot.freight"] = { [mat] = units }
  local bal = co.balance()
  check(mi.accept(bulk.id), "a bulk haul can be signed")
  W.tick(120)
  check(mi.active == nil, "delivering it completes the haul", tostring(mi.active))
  check(co.balance() == bal + bulk.reward, "...and pays", co.balance() - bal)
  local left = inv.count("base", mat)
  check(left >= 1 and left <= 6, "...and the buyer takes the goods (only the spare is left)", left)
  check((store["depot.freight"] or {})[mat] == left, "...and the freight tally goes with them",
    tostring((store["depot.freight"] or {})[mat]))
  W.tick(120)
  local g2, n2 = offers_ground(), 0
  for _, s in pairs(g2) do n2 = n2 + 1; check(s.id ~= bulk.id, "the finished job is gone") end
  check(n2 == 2, "a finished ground job is replaced by a fresh one", n2)
  -- standing grows the work
  store["co.rep"] = 8
  local hi = mi.genSpec("bulk", "Home", 99)
  local lo
  store["co.rep"] = 0
  lo = mi.genSpec("bulk", "Home", 99)
  check(hi.goals[1].kg > lo.goals[1].kg and hi.reward > lo.reward,
    "a Trusted company gets bigger, better-paid ground work", lo.reward .. " → " .. hi.reward)
  check(mi.genSpec("order", "Moon", 1) == nil, "ground work is only ever on the home world")

  -- A SURVEY DRIVE: the odometer, then park at the base.
  store["co.rep"] = 0
  local trek = mi.genSpec("trek", "Home", 5)
  check(trek and trek.goals[1].kind == "drive" and trek.goals[2].kind == "home",
    "a survey drive is a distance and a parking spot")
  local board = store["mission.board"] or {}
  board[#board + 1] = trek
  store["mission.board"] = board
  check(mi.accept(trek.id), "a survey drive can be signed")
  local H = W.BODIES.Home
  store["base.x"], store["base.y"], store["base.z"] = 0, H.radius, 0
  local ASM = { grounded = false, vel = { x = 0, y = 0, z = 0 } }
  W.API.assembly = { info = function() return ASM end }
  local node = { id = 77, valid = true, x = H.x, y = H.y + H.radius, z = H.z }
  local onWheels = true
  local rover = { node = node, piloting = true, hasFlown = true,
                  r2OnWheels = function() return onWheels end }
  W.scripts.vessel_controller = { rover }
  local function at(theta, r)
    node.x, node.y, node.z = H.x + r * math.cos(theta), H.y + H.radius, H.z + r * math.sin(theta)
  end
  -- drive circles 60 m round the base at 12 m/s
  local theta, R, dt = 0, 60, 1 / 60
  local function drive(metres)
    local steps = math.floor(metres / (12 * dt))
    ASM.vel.x = 12
    for _ = 1, steps do
      theta = theta + 12 * dt / R
      at(theta, R)
      mi.update(node, dt)
    end
  end
  drive(400)
  check(math.abs(mi.odometer() - 400) < 15, "the odometer counts the ground covered",
    string.format("%.0f", mi.odometer()))
  check(mi.goalLines()[1]:find("this trip") ~= nil, "...and the card shows it", mi.goalLines()[1])
  -- getting out resets the trip
  rover.piloting = false
  mi.update(node, dt)
  rover.piloting = true
  check(mi.odometer() == 0, "getting out resets the trip", mi.odometer())
  -- a hop through the air doesn't count
  onWheels = false
  drive(200)
  check(mi.odometer() < 1, "the odometer only counts on the ground", mi.odometer())
  onWheels = true
  -- a teleport doesn't count
  at(theta + 2, 500); mi.update(node, dt)
  check(mi.odometer() < 1, "a jump isn't driving", mi.odometer())
  drive(trek.goals[1].value + 20)
  check(mi.goalLines()[1]:find("✓") ~= nil, "the distance goal latches", mi.goalLines()[1])
  check(mi.active == trek.id, "...but the job isn't done until it's parked")
  local bal2 = co.balance()
  -- park: stop next to the base
  ASM.vel.x = 0
  at(0, 30)
  mi.update(node, dt)
  mi.update(node, dt)
  check(mi.active == nil and co.balance() == bal2 + trek.reward,
    "parking at the base pays the survey drive", co.balance() - bal2)
  W.scripts.vessel_controller = nil
end

-- ── 4. the advance ─────────────────────────────────────────────────────────
do
  local W = sim.world(ROOT)
  local co, store = W.co, W.store
  co.spend(co.balance() - 100, "broke")
  W.tick(600)
  check(co.balance() == 100 and co.owed() == 0, "no advance before the First Flight (the opening is the player's)")
  store["mission.done"] = { firstflight = true }
  W.tick(60)
  check(co.balance() == 100, "...nor in the first seconds of being broke")
  W.tick(300)
  local A = co.ADVANCE
  check(co.balance() == 100 + A.amount and co.owed() == A.amount,
    "Mission Control advances money to a broke company that has flown", co.balance())
  check(co.rep() == 0, "...at no cost in standing")
  check(store["co.loans"] == 1, "...and counts it")
  co.spend(co.balance() - 50, "broke again")
  W.tick(600)
  check(co.balance() == 50, "never a second advance while the first is owed", co.balance())
  co.earn(1000, "a sale")
  check(co.balance() == 50 + 1000 - math.floor(1000 * A.share) and co.owed() == A.amount - math.floor(1000 * A.share),
    "a quarter of income goes to repaying it", co.balance() .. " owed " .. co.owed())
  co.earn(100000, "a windfall")
  check(co.owed() == 0, "...until it is paid off, and no more", co.owed())
  local led = co.ledgerLines(3)
  check(led[1]:find("advance repaid") ~= nil, "the ledger says so", led[1])
  -- the testing account never borrows
  store["debug.rich"] = true
  check(co.advanceReady() == false, "debug funds never take an advance")
end

-- ── 5. the simulation ──────────────────────────────────────────────────────
do
  local A = sim.scenarioA(ROOT)
  check(A.first_launch and A.first_launch >= 3 and A.first_launch <= 8,
    "the opening: the first launch is paid for with earned money, ~5 min in", A.first_launch)
  check(A.bal > 8000, "a new player is well into the ladder at 30 minutes", A.bal)
  local B = sim.scenarioB(ROOT, 15000)
  check(B.minutes <= 15, "three crashed orbiters: back to $15,000 in minutes", B.minutes)
  local E = sim.scenarioB2(ROOT, 5000, true)
  check(E.minutes <= 12, "an early company that crashed three rockets earns it back on the ground", E.minutes)
  check(E.loans == 1, "...with Mission Control's advance when it was broke", E.loans)
  local C = sim.scenarioC(ROOT)
  check(C.bal > 6000 and C.jobs >= 4, "a rover player who never flies still progresses", C.bal)
  if os.getenv("SOLAR_ECON_TABLE") then
    sim.report({ ROOT }, { "this tree" })
  end
end

if #fails > 0 then
  print("ECONOMY SMOKE FAILURES:")
  for _, f in ipairs(fails) do print("  ✗ " .. f) end
  print(string.format("smoke_economy: %d passed, %d FAILED", passes, #fails))
  os.exit(1)
end
print(string.format("smoke_economy: all %d checks passed", passes))
