-- SMOKE: the thermal rulebook (scripts/thermal.lua) — pure logic, no engine.
-- The heat model's closed form (one big step equals many small ones), the
-- SCRAM latch and the restart (A6), a Furnace warped an hour at 60 % (it
-- settles) and at 100 % (it scrams ONCE and doesn't flap), old craft with
-- only engines staying cool, radiators (deploy, sun, pump, wear), the
-- isotope cell's decay, fuel rods (burn, spend, load, unload), an NTR's
-- governor, the radiation cone (dot product, inverse square, shielding by
-- part record), dose and its healing, and fuel fabrication.
--
--   luajit solar/tests/smoke_thermal.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/thermal.lua"))
setfenv(chunk, env)
chunk()
local T = env
local TH = T.THERMAL

local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = type(v) == "table" and copy(v) or v end
  return o
end

-- ── the closed form ─────────────────────────────────────────────────────────
check(near(T.approach(0, 1, 0.5, 1e9), 1), "approach reaches the balance point")
check(near(T.approach(0.2, 0.8, 0, 100), 0.2), "k = 0 leaves it")
local x = 0.1
for _ = 1, 1000 do x = T.approach(x, 0.7, 0.01, 0.1) end
check(near(x, T.approach(0.1, 0.7, 0.01, 100), 1e-9), "approach: 1000 small steps = one big one")
local tt = T.timeTo(0.1, 1.2, 0.02, 0.9)
check(tt and near(T.approach(0.1, 1.2, 0.02, tt), 0.9, 1e-9), "timeTo lands on the level")
check(T.timeTo(0.1, 0.8, 0.02, 0.9) == nil, "a level past the balance point is never reached")

-- ── the models ─────────────────────────────────────────────────────────────
local FURNACE = { type = "reactor", core = "furnace" }
local EMBER = { type = "reactor", core = "ember" }
local TRUSS = { type = "radiator", sink = 20, draw = 0.2, cap = 120 }
local PANEL = { type = "radiator", sink = 5, draw = 0.05, cap = 40 }
local FIN = { type = "radiator", sink = 1, cap = 10 }
local function furnace_model(out, st)
  st = st or { critical = true, output = out, rods = 4, life = 4 * 3600 }
  return T.vesselModel({ { m = FURNACE, st = st }, { m = TRUSS, deploy = 1, hp = 1, pump = 1 } }, 0), st
end

-- E's warp test: a Furnace for an hour at 60 % and at 100 %.
do
  local M, st = furnace_model(60)
  local S = { T = 0.05 }
  local rep = T.advance(S, M, 3600, 0)
  local eq = 25 * 0.6 / M.S
  check(rep.scram == nil and st.critical == true, "a Furnace at 60 % doesn't scram in an hour")
  check(near(S.T, eq, 1e-3), string.format("…it settles at Q/S (%.3f vs %.3f)", S.T, eq))
  check(S.T < TH.scram, "…below the scram line")
  check(near(st.life, 4 * 3600 - 0.6 * 3600, 1e-6), "…and burns rod life at its output")
end
do
  local M, st = furnace_model(100)
  local S = { T = 0.05 }
  -- at 1000× warp the electrical tick is 100 s of game time
  local scrams, n_on = 0, 0
  local was = true
  for i = 1, 36 do
    local rep = T.advance(S, M, 100, (i - 1) * 100)
    if rep.scram then scrams = scrams + 1 end
    if st.critical ~= was then n_on = n_on + 1; was = st.critical end
  end
  check(scrams == 1, "a Furnace at 100 % scrams exactly once in an hour (" .. scrams .. ")")
  check(n_on == 1 and st.critical == false, "…and stays down: no flapping")
  check(S.T < 0.2, string.format("…and cools to its decay heat (%.3f)", S.T))
  -- the same hour in one step
  local M2, st2 = furnace_model(100)
  local S2 = { T = 0.05 }
  local rep2 = T.advance(S2, M2, 3600, 0)
  check(rep2.scram ~= nil and near(rep2.scram, st.scram, 1e-6), "one 3600 s step scrams at the same instant")
  check(near(S2.T, S.T, 1e-9), "…and ends at the same temperature")
  check(near(st2.life, st.life, 1e-6), "…with the same rod life")
end

-- ONE FUNCTION, ONE TEST: a single big dt equals many small ones, across
-- every event at once (scram, an NTR's governor band, rods running out).
do
  local function setup()
    local a = { critical = true, output = 100, rods = 1, life = 900 }       -- an Ember that runs dry
    local b = { critical = true, output = 80, rods = 1, life = 3600 }       -- a Pile NTR on its governor
    local M = T.vesselModel({ { m = EMBER, st = a }, { m = { type = "reactor", core = "pile" }, st = b },
      { m = PANEL, deploy = 1 }, { m = { type = "rtg" } }, { m = { type = "engine" }, throttle = 0.7 } }, 0.5)
    return M, a, b
  end
  local Mb, ab, bb = setup()
  local Sb = { T = 0.0 }
  local rb = T.advance(Sb, Mb, 5000, 1000)
  local Ms, as, bs = setup()
  local Ss = { T = 0.0 }
  local over, sc = 0, nil
  for i = 1, 50000 do
    local r = T.advance(Ss, Ms, 0.1, 1000 + (i - 1) * 0.1)
    over = over + r.over
    sc = sc or r.scram
  end
  check(near(Sb.T, Ss.T, 1e-7), string.format("big step = small steps: T %.9f vs %.9f", Sb.T, Ss.T))
  check(near(ab.life, as.life, 1e-6) and near(bb.life, bs.life, 1e-5),
    string.format("…rod life (%.6f/%.6f, %.6f/%.6f)", ab.life, as.life, bb.life, bs.life))
  check(ab.critical == as.critical and bb.critical == bs.critical, "…which cores are running")
  check((rb.scram == nil) == (sc == nil) and (not sc or near(rb.scram, sc, 1e-6)), "…the scram time")
  check(near(rb.over, over, 1e-6), "…the time spent over 100 %")
end

-- An NTR's governor holds it under the scram line at full throttle (A6).
do
  local st = { critical = true, output = 100, rods = 1, life = 3600 }
  local M = T.vesselModel({ { m = { type = "reactor", core = "pile" }, st = st }, { m = FIN } }, 0)
  local S = { T = 0 }
  local rep = T.advance(S, M, 1200, 0)
  check(rep.scram == nil and st.critical, "an NTR never scrams on heat: its governor throttles it")
  check(S.T > TH.derate_lo and S.T < TH.derate_hi, string.format("…it settles in the governor band (%.3f)", S.T))
  local share = T.coreShare(M.cores[1], S.T)
  check(share > 0 and share < 1, string.format("…its thrust fades (%.2f of throttle)", share))
end

-- OLD SAVES: engines make a little heat, and a craft with no radiators
-- settles well below the scram line however many engines it has.
do
  for _, n in ipairs({ 1, 3, 9, 40 }) do
    local es = {}
    for i = 1, n do es[i] = { m = { type = "engine" }, throttle = 1 } end
    local M = T.vesselModel(es, 1)
    local eq = T.settle(M, 0)
    check(eq <= 0.45, string.format("%d engines at full throttle settle at %d %% (≤ 45 %%)", n, T.pct(eq)))
  end
  local M = T.vesselModel({ { m = { type = "rtg" } } }, 1)
  check(T.settle(M, 0) < 0.3, "an isotope cell alone runs cool")
end

-- THE EMBER needs its radiators: alone it scrams at full output, one panel
-- isn't quite enough, two are.
do
  local function eq(np)
    local es = { { m = EMBER, st = { critical = true, output = 100, rods = 1, life = 3600 } } }
    for i = 1, np do es[#es + 1] = { m = PANEL, deploy = 1, hp = 1, pump = 1 } end
    return T.settle(T.vesselModel(es, 0), 0)
  end
  check(eq(0) > TH.scram, "an Ember with no radiators scrams at full output")
  check(eq(1) > TH.scram and eq(1) < 1.0, string.format("…one radiator panel: just over (%d %%)", T.pct(eq(1))))
  check(eq(2) < 0.6, string.format("…two: comfortable (%d %%)", T.pct(eq(2))))
end

-- ── radiators (B3) ──────────────────────────────────────────────────────────
check(near(T.radiatorSink(PANEL, 1, 1, 1, 0), 5), "a deployed panel sheds its 5 hu")
check(T.radiatorSink(PANEL, 0, 1, 1, 0) < 1, "folded it sheds little")
check(near(T.radiatorSink(PANEL, 1, 1, 1, 1), 5 * (1 - TH.sun_k)), "in full sun it sheds less")
check(T.radiatorSink(PANEL, 1, 1, 0, 0) < 2, "with no power for its pump: conduction only")
check(T.radiatorSink(FIN, 1, 1, 0, 0) == 1, "a passive fin needs no pump")
check(T.radiatorSink(PANEL, 1, 0.2, 1, 0) == 0, "a wrecked radiator sheds nothing")
check(near(T.radiatorSink(PANEL, 1, 0.6, 1, 0), 3), "a worn one sheds by its health")

-- ── the isotope cell (B1) ───────────────────────────────────────────────────
local cell = { type = "rtg", gen = 0.5 }
check(near(T.rtgOutput(cell, 0), 0.5), "a new isotope cell gives 0.5 EC/s")
check(near(T.rtgOutput(cell, T.RTG.half), 0.25), "half after one half-life")
check(T.rtgOutput(cell, 10 * 3600) > 0.49, "it barely notices a ten-hour flight")
check(near(T.rtgOutput(cell, 3 * T.RTG.half), 0.0625), "an eighth after three")

-- ── rods (B5) and starting (A6) ─────────────────────────────────────────────
do
  local c = T.coreOf(EMBER)
  local st = {}
  check(T.startWhyNot(st, 0, 0) ~= nil, "an empty core won't start")
  check(T.loadRod(st, c), "a rod goes in")
  check(not T.loadRod(st, c), "…the Ember's rack holds one")
  check(T.startWhyNot(st, 0.2, 0) == nil, "a fuelled, cold core starts")
  T.startCost(st)
  check(near(st.life, 3600 - TH.restart_rod), "a start costs rod life")
  st.critical, st.output = true, 100
  local M = T.vesselModel({ { m = EMBER, st = st }, { m = PANEL, deploy = 1 }, { m = PANEL, deploy = 1 } }, 0)
  local S = { T = 0.2 }
  local rep = T.advance(S, M, 7200, 0)
  check(rep.spent[1] and st.life == 0 and st.critical == false, "the rod burns out and the core goes quiet")
  check(T.rodsSpent(st, c) == 1 and T.rodsLive(st, c) == 0, "…one spent rod in the rack")
  check(T.startWhyNot(st, 0.1, 9999):find("spent"), "…it won't start on a spent rod")
  check(T.unloadSpent(st, c) and T.st_rods(st) == 0, "the spent rod comes out")
  -- the scram latch and the cool-down
  local st2 = { rods = 1, life = 3000, scram = 100 }
  check(T.startWhyNot(st2, 0.3, 130):find("cooling"), "a scrammed core waits out its cool-down")
  check(T.startWhyNot(st2, 0.7, 200):find("hot"), "…and for its core to cool")
  check(T.startWhyNot(st2, 0.4, 200) == nil, "…then it restarts")
  local st3 = { rods = 1, life = 10, critical = true }
  check(not T.unloadSpent(st3, c), "no spent rod comes out of a running core")
end

-- ── the radiation cone (A4) ─────────────────────────────────────────────────
do
  local core = { x = 0, y = 0, z = 0, ax = 0, ay = 1, az = 0, rad = 0.5, share = 1 }
  local inside, r5 = T.coneAt(core, 0, 5, 0)
  check(inside and near(r5, 0.5 / 3600, 1e-12), "on the axis 5 m up: rad an hour")
  local _, r10 = T.coneAt(core, 0, 10, 0)
  check(near(r10, r5 / 4, 1e-12), "twice as far: a quarter (inverse square)")
  check(not T.coneAt(core, 5, 1, 0), "beside the core: outside the 30° cone")
  check(not T.coneAt(core, 0, -5, 0), "below it: outside")
  check(T.coneAt(core, math.tan(math.rad(28)) * 5, 5, 0), "28° off the axis: inside")
  check(not T.coneAt(core, math.tan(math.rad(32)) * 5, 5, 0), "32° off: outside")
  -- shielding, counted by part record
  local shield = { uid = 2, x = 0, y = 1.0, z = 0, hx = 0.5, hy = 0.05, hz = 0.5, k = T.blockerK({ { type = "shield" } }) }
  local tank1 = { uid = 3, x = 0, y = 2.0, z = 0, hx = 0.5, hy = 0.5, hz = 0.5,
    k = T.blockerK({}, { kind = "tank", fuel = 80 }, 1.0) }
  local tank2 = { uid = 4, x = 0, y = 3.0, z = 0, hx = 0.5, hy = 0.5, hz = 0.5,
    k = T.blockerK({}, { kind = "tank", fuel = 80 }, 1.0) }
  local emptyT = T.blockerK({}, { kind = "tank", fuel = 80 }, 0.3)
  check(shield.k == TH.shield_k, "a Shadow Shield is a blocker by its module")
  check(tank1.k == TH.tank_k and emptyT == nil, "a full tank shields, an emptied one doesn't")
  local d0 = T.doseRate(core, 0, 5, 0, {})
  local d1, _, n1 = T.doseRate(core, 0, 5, 0, { shield })
  local d2, _, n2 = T.doseRate(core, 0, 5, 0, { tank1, tank2 })
  check(n1 == 1 and near(d1, d0 * TH.shield_k, 1e-15), "the shield between: 2 % gets through")
  check(n2 == 2 and near(d2, d0 * TH.tank_k ^ 2, 1e-15), "two full tanks between: 9 %")
  local d3, _, n3 = T.doseRate(core, 0, 5, 2.8, { shield })
  check(n3 == 0 and d3 > 0, "a crew member off to the side of the shield's disc is not behind it")
  local d4 = T.doseRate(core, 0, 5, 0, { shield }, { [2] = true })
  check(near(d4, d0), "a skipped blocker (the seat itself) doesn't count")
  -- a turned box
  local turned = { x = 0, y = 2, z = 0, hx = 2, hy = 0.05, hz = 0.05, k = 0.5,
    X = { x = 0, y = 1, z = 0 }, Y = { x = -1, y = 0, z = 0 }, Z = { x = 0, y = 0, z = 1 } }
  check(T.segHitsBox(0, 0, 0, 0, 5, 0, turned), "the slab test turns with the box")
  check(not T.segHitsBox(0.2, 0, 0, 0.2, 5, 0, turned), "…and misses beside it")
  -- shut down with fuel in: its decay heat still glows
  local st = { critical = false, rods = 1, life = 1000 }
  local M = T.vesselModel({ { m = EMBER, st = st } }, 0)
  check(near(T.radShare(M.cores[1], 0.1), TH.decay), "a shut-down fuelled core still gives its decay share")
  st.rods = 0
  check(T.radShare(M.cores[1], 0.1) == 0, "an empty one gives nothing")
end

-- ── dose ───────────────────────────────────────────────────────────────────
do
  local d = T.doseStep(0, 1 / 7200, false, 3600)
  check(near(d, 0.5), "an hour at half a lethal dose a… (linear while exposed)")
  local d2 = T.doseStep(0.5, 0, true, TH.dose_heal_half)
  check(near(d2, 0.25, 1e-9), "it heals by half in two days at the base")
  local s = 0.5
  for _ = 1, 100 do s = T.doseStep(s, 0, true, TH.dose_heal_half / 100) end
  check(near(s, d2, 1e-9), "…healing in small steps = one big one")
  check(T.doseStep(0, 0, false, 100) == 0, "nobody exposed: no dose")
end

-- ── B6: fuel fabrication ────────────────────────────────────────────────────
do
  local F = T.FUEL_FAB
  local q = {}
  check(T.fabWhyNot(25, 5000, q, false) and T.fabWhyNot(25, 5000, q, false):find("Engineer"),
    "fabrication needs an Engineer")
  check(T.fabWhyNot(10, 5000, q, true):find("uranium"), "…and 20 units of uranium ore")
  check(T.fabWhyNot(25, 100, q, true) == "not enough funds", "…and the money")
  check(T.fabWhyNot(25, 5000, q, true, false):find("research"), "…and the research")
  check(T.fabWhyNot(25, 5000, q, true) == nil, "with all of it, the press starts")
  local j1 = T.fabQueue(q, 100)
  local j2 = T.fabQueue(q, 150)
  check(j1.t1 == 100 + F.secs and j2.t0 == j1.t1, "a second rod waits for the first")
  check(T.fabWhyNot(99, 9999, q, true):find("full"), "two in the press at most")
  check(#T.fabTake(q, 100 + F.secs - 1) == 0, "nothing comes out early")
  check(near(T.fabProgress(q, 100 + F.secs / 2), 0.5), "half way after five minutes")
  local done = T.fabTake(q, 100 + 2 * F.secs + 5)
  check(#done == 2 and #q == 0, "catching up on the save clock: both rods out at once")
end

-- ── the result ─────────────────────────────────────────────────────────────
if #failures > 0 then
  print(string.format("SMOKE thermal: %d passed, %d FAILED", passed, #failures))
  for _, f in ipairs(failures) do print("  FAIL: " .. f) end
  os.exit(1)
end
print(string.format("SMOKE thermal: all %d checks passed", passed))
