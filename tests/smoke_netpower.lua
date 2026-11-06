-- SMOKE: power networks II (sandbox plan S5, work/sandbox/PLAN.md §3.2, §12;
-- docs/base-building.md §16): cables with real losses and ratings, breakers
-- that trip, transformers, the network's flow, against the real base_power /
-- base_grid / base_cable / structures / bases / parts_base / parts_kit.
--
--   * the cables: R = ρL/A, P²R/V² (1 km of 16 mm² at 400 V carrying 20 kW
--     loses ~13 %; the same at 11 kV a few watts), ratings, the next gauge;
--   * the flow: a tree pushes the loads up to the store; a cycle splits by
--     conductance (the direct line carries two thirds); every bus balances;
--   * protection: a guarded cable over its breaker's rating trips it; an
--     unguarded one past 125 % burns through; a main breaker trips on its
--     structure's loads; the "limited by" line;
--   * the closed form: a year of losses on the battery step, one big step =
--     many small to 1e-6, and a breaker that trips at noon trips at the same
--     moment either way;
--   * the scene: two bases 1.2 km apart on a 400 V cable (a quarter of the
--     power lost), then on an 11 kV line between two transformers (under a
--     kilowatt), a breaker at the far end tripped by the overload (the grid
--     splits), reset (trips again), the load cut and reset (holds), a main
--     breaker, a cable burnt through and spliced, the record saved;
--   * the cost: three networks, 40 cables and 10 breakers rebuilt and stepped.
--
--   luajit solar/tests/smoke_netpower.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
  return ok
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local BP = load_script("base_power.lua", env({}, {}))

-- ── the cables ──────────────────────────────────────────────────────────────
do
  local R = BP.resistance("lv16", 1000)
  check(near(R, 1.72e-8 * 1000 / 16e-6, 1e-9), string.format("1 km of 16 mm² copper: %.3f Ω", R))
  local sh = BP.lossShare(20, "lv16", 1000)
  check(sh > 0.12 and sh < 0.15, string.format("20 kW over 1 km at 400 V loses %.1f %% (plan: ~14 %%)", sh * 100))
  local shh = BP.lossShare(20, "hv35", 1000)
  check(shh < 1e-4 and shh * 20000 < 5, string.format("...at 11 kV on the HV cable: %.2f W", shh * 20000))
  check(near(BP.capacityKW("lv16"), 32) and near(BP.capacityKW("lv95"), 92) and BP.capacityKW("hv35") > 1500,
    "ratings: 16 mm² 32 kW, 95 mm² 92 kW, the 11 kV cable 1.5 MW")
  check(BP.nextGauge("lv16") == "lv35" and BP.nextGauge("lv35") == "lv95" and BP.nextGauge("lv95") == nil and BP.nextGauge("hv35") == nil,
    "the next gauge up: 16 → 35 → 95 mm²")
  check(near(BP.breakerKW({ amps = 63 }), 25.2) and near(BP.xfmrLossKW({ kva = 100, p0 = 0.25, pk = 1.6 }, 100), 1.85),
    "a 63 A breaker trips past 25.2 kW; a transformer loses 0.25 kW idle, 1.85 kW at its full 100 kVA")
end

-- ── the flow ────────────────────────────────────────────────────────────────
-- (KCL at every bus: what goes in comes out, the losses drawn at the loads)
local function balanced(net, F, k)
  local n = net.nb
  local flow = {}
  for b = 1, n do flow[b] = 0 end
  for i, e in ipairs(net.edges) do flow[e.a] = flow[e.a] - F.P[i]; flow[e.z] = flow[e.z] + F.P[i] end
  -- the injections the solve used (store, gen, loads + their share of losses)
  local L = 0
  for _, d in ipairs(net.loads) do L = L + d.kW end
  local inj = {}
  for b = 1, n do inj[b] = net.gen[b] or 0 end
  for _, d in ipairs(net.loads) do inj[d.bus] = inj[d.bus] - d.kW * (1 + F.loss / L) end
  local G = 0
  for b = 1, n do G = G + (net.gen[b] or 0) end
  local C = 0
  for _, s in ipairs(net.stores) do C = C + s.cap end
  for _, s in ipairs(net.stores) do inj[s.bus] = inj[s.bus] - (G - L - F.loss) * s.cap / C end
  local worst = 0
  for b = 1, n do worst = math.max(worst, math.abs(inj[b] + flow[b])) end
  return worst
end
do
  -- a tree: the store at bus 1; 10 kW at bus 2 (500 m of 16 mm²), 5 kW at bus 3 (300 m of 35 mm² on from bus 2)
  local net = BP.network({ buses = { "a", "b", "c" }, gen = { 0, 0, 0 }, arrays = {},
    loads = { { bus = 2, kW = 10 }, { bus = 3, kW = 5 } }, stores = { { bus = 1, cap = 4000 } },
    edges = { { id = 1, a = 1, z = 2, ty = "lv16", len = 500 }, { id = 2, a = 2, z = 3, ty = "lv35", len = 300 } }, mains = {}, xfmrs = {} })
  local F = BP.flowsAt(net, 1)
  local l1, l2 = BP.lossKW(F.P[1], net.R[1], 400), BP.lossKW(F.P[2], net.R[2], 400)
  check(F.P[1] > 15 and F.P[2] > 5 and F.P[2] < F.P[1], string.format("a tree: the loads pushed up to the store (%.3f kW from the store, %.3f on to the far load)", F.P[1], F.P[2]))
  check(near(F.loss, l1 + l2, 1e-6), string.format("its losses are P²R/V² of each line: %.3f kW", F.loss))
  check(balanced(net, F) < 1e-6, string.format("every bus balances (worst %.2e kW)", balanced(net, F)))
  -- a cycle: the load at bus 2, a direct line from the store and a two-hop one through bus 3
  local cyc = BP.network({ buses = { "a", "b", "c" }, gen = { 0, 0, 0 }, arrays = {},
    loads = { { bus = 2, kW = 12 } }, stores = { { bus = 1, cap = 4000 } },
    edges = { { id = 1, a = 1, z = 2, ty = "lv16", len = 400 }, { id = 2, a = 1, z = 3, ty = "lv16", len = 400 },
              { id = 3, a = 3, z = 2, ty = "lv16", len = 400 } }, mains = {}, xfmrs = {} })
  local Fc = BP.flowsAt(cyc, 1)
  check(near(Fc.P[1] / Fc.P[2], 2.0, 1e-6) and near(Fc.P[2], Fc.P[3], 1e-9),
    string.format("a cycle splits by conductance: the direct line %.3f kW, the long way %.3f kW (2 : 1)", Fc.P[1], Fc.P[2]))
  check(balanced(cyc, Fc) < 1e-6, "...and every bus balances")
end

-- ── protection ──────────────────────────────────────────────────────────────
do
  local function one(kW, guarded, ty)
    local net = BP.network({ buses = { "a", "b" }, gen = { 0, 0 }, arrays = {}, loads = { { bus = 2, kW = kW } },
      stores = { { bus = 1, cap = 4000 } }, mains = {}, xfmrs = {},
      edges = { { id = 7, a = 1, z = 2, ty = ty or "lv16", len = 50, guard = guarded and { { key = "5:2", kW = 25.2 } } or {} } } })
    local F = BP.flowsAt(net, 1)
    return BP.eventsIn(net, F), net, F
  end
  local ev = one(30, true)
  check(ev and #ev == 1 and ev[1].kind == "trip" and ev[1].key == "5:2" and ev[1].kW > 25.2, "30 kW through a 63 A breaker trips it")
  check(one(24, true) == nil, "24 kW doesn't")
  local evb = one(41, false)
  check(evb and evb[1].kind == "burn" and evb[1].id == 7, "41 kW on a bare 16 mm² cable (128 % of its 32 kW) burns it through")
  check(one(36, false) == nil, "36 kW (113 %) only runs it hot")
  local _, net, F = one(36, false)
  local line = BP.limitedBy(net, F)
  check(line and line:find("cable 7 at 11%d %%") and line:find("35 mm²", 1, true), "limited by: " .. tostring(line))
  local _, net2, F2 = one(36, true)
  check((BP.limitedBy(net2, F2) or ""):find("breaker", 1, true), "...or the breaker that will trip: " .. tostring(BP.limitedBy(net2, F2)))
  -- a main breaker over its structure's loads
  local nm = BP.network({ buses = { "a" }, gen = { 0 }, arrays = {}, loads = { { bus = 1, kW = 30 } }, stores = { { bus = 1, cap = 10 } },
    edges = {}, mains = { { key = "9:4", kW = 25.2, sid = 9, load = 30 } }, xfmrs = {} })
  local evm = BP.eventsIn(nm, BP.flowsAt(nm, 1))
  check(evm and evm[1].kind == "trip" and evm[1].main and evm[1].key == "9:4", "a main breaker trips when its structure draws 30 kW of its 25 kW")
  -- a long low-voltage line with nothing near its limit: the loss line
  local nl = BP.network({ buses = { "a", "b" }, gen = { 0, 0 }, arrays = {}, loads = { { bus = 2, kW = 20 } },
    stores = { { bus = 1, cap = 4000 } }, mains = {}, xfmrs = {}, edges = { { id = 3, a = 1, z = 2, ty = "lv95", len = 1400, guard = {} } } })
  local ll = BP.limitedBy(nl, BP.flowsAt(nl, 1))
  check(ll == nil or ll:find("transformer", 1, true), "a long 400 V line names the cure: " .. tostring(ll))
end

-- ── the closed form, with losses and a noon trip ────────────────────────────
local BG0 = load_script("base_grid.lua", env({}, {}))
do
  local N, L = 96, 100.0
  local prof = {}
  for j = 1, N do local x = math.sin((j - 0.5) / N * 2 * math.pi); prof[j] = math.max(0, x) * 40 end
  -- an array at bus 1 (40 kW peak), the store at bus 1, 12 kW at bus 2 over 900 m of 16 mm²
  local spec = { buses = { "a", "b" }, gen = { 0, 0 }, arrays = { { bus = 1, prof = prof } }, loads = { { bus = 2, kW = 12 } },
    stores = { { bus = 1, cap = 5000 } }, mains = {}, xfmrs = {}, edges = { { id = 1, a = 1, z = 2, ty = "lv16", len = 900, guard = {} } } }
  local net = BP.network(spec)
  local lossP, trip = BP.yearOf(net, N)
  check(trip == nil and lossP[1] > 0.5, string.format("a year of losses: %.2f kW at every slot (the load's line: the battery feeds it at night)", lossP[1]))
  local function model(lp, tr)
    return { base = 0, need = 12, C = 5000, eff = 0.92, loads = { { need = 12 } }, prof = prof, N = N, L = L, A0 = 0, lossP = lp, trip = tr }
  end
  local M = model(lossP, nil)
  local function small(M2, e0, a0, a1)
    local st, rep, a, k = { e = e0 }, { short = 0, slots = 0, years = 0 }, a0, 0
    while a < a1 do
      k = k + 1
      local b = math.min(a1, a + 7.3 * (0.6 + 0.8 * ((k * 7919) % 13) / 13))
      BG0.advance(st, M2, a, b, rep)
      if rep.trip then return st.e, rep.short, rep.stopAt end
      a = b
    end
    return st.e, rep.short, nil
  end
  local function big(M2, e0, a0, a1)
    local st = { e = e0 }
    local _, rep = BG0.advance(st, M2, a0, a1)
    return st.e, rep.short, rep.stopAt
  end
  local eS, sS = small(M, 2500, 13, 13 + 37 * N * L)
  local eB, sB = big(M, 2500, 13, 13 + 37 * N * L)
  check(near(eS, eB, 1e-6) and near(sS, sB, 1e-6), string.format("37 years with the line's losses: one step = uneven small ones (%.6f / %.6f EC)", eB, eS))
  local Mn = model(nil, nil)
  local eN = big(Mn, 5000, 0.5 * N * L, 0.5 * N * L + 250)
  local eL = big(M, 5000, 0.5 * N * L, 0.5 * N * L + 250)
  check(eL < eN, string.format("...and the losses cost charge: %.0f EC with them, %.0f without", eL, eN))
  -- the same line guarded by a 63 A breaker, the load now 22 kW: the array's
  -- surplus at noon runs the other way… so guard the array's own feed instead:
  -- the array at bus 2 (the far end), the store at bus 1: its noon output
  -- pushed down the guarded line past 25 kW trips it
  local spec2 = { buses = { "a", "b" }, gen = { 0, 0 }, arrays = { { bus = 2, prof = prof } }, loads = { { bus = 1, kW = 4 } },
    stores = { { bus = 1, cap = 5000 } }, mains = {}, xfmrs = {}, edges = { { id = 1, a = 1, z = 2, ty = "lv16", len = 200, guard = { { key = "3:1", kW = 25.2 } } } } }
  local net2 = BP.network(spec2)
  local lp2, tr2 = BP.yearOf(net2, N)
  local first = nil
  for k = 1, N do if tr2 and tr2[k] then first = k break end end
  check(first and prof[first] > 25 and prof[first - 1] <= 25.5, string.format("the array's feed trips in the first slot it passes 25 kW (slot %s, %.1f kW)", tostring(first), first and prof[first] or -1))
  local M2 = { base = 0, need = 4, C = 5000, eff = 0.92, loads = { { need = 4 } }, prof = prof, N = N, L = L, A0 = 0, lossP = lp2, trip = tr2 }
  local _, _, tS = small(M2, 1000, 3, 3 + 2 * N * L)
  local _, _, tB = big(M2, 1000, 3, 3 + 2 * N * L)
  check(tS and tB and near(tS, tB, 1e-9) and near(tB, (first - 1) * L, 1e-9),
    string.format("a long step and many short ones trip at the same moment: %.3f / %.3f s (the slot's start, %.1f)", tB or -1, tS or -1, (first - 1) * L))
  local _, rep0 = BG0.advance({ e = 10 }, M2, (first - 1) * L + 5, (first - 1) * L + 5)
  check(rep0.trip ~= nil and near(rep0.stopAt, (first - 1) * L + 5), "a grid already in a tripping slot trips the moment it is asked")
end

-- ── the scene: two bases on a long line ─────────────────────────────────────
local MU, RS = 9.75e10, 2.0e5
local V = math.sqrt(MU / RS)
local R = 800
local bodies = {
  { name = "Sun", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 1.0e4, mu = MU, soi = -1, star = true },
  { name = "Vever", x = RS, y = 0, z = 0, vx = 0, vy = V, vz = 0, radius = R, mu = 1e5, soi = 5e4 },
}
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
  dominant = function() return "Vever" end,
}
local s = { ["base.body"] = "Vever" }
local clock = { a = 1000 }
local scripts = {}
local PB = load_script("parts_base.lua", env({}, {}))
local PK = load_script("parts_kit.lua", env({}, {}))
-- (two loads and a generator the size a real base would grow to; the kit's
-- breaker and transformer as they are)
local EXTRA = {
  heater = { label = "Furnace", h = 2, rx = 1, rz = 1, half = { x = 1, y = 1, z = 1 }, power = { kind = "load", use = 30 } },
  heaterS = { label = "Heater", h = 2, rx = 1, rz = 1, half = { x = 1, y = 1, z = 1 }, power = { kind = "load", use = 20 } },
  bigGen = { label = "Generator", h = 2, rx = 1, rz = 1, half = { x = 1, y = 1, z = 1 }, power = { kind = "rtg", gen = 60 } },
}
local function defs(id) return EXTRA[id] or PB.partInfo(id) or PK.partInfo(id) end
scripts.parts_base = { partInfo = defs }
scripts.parts_kit = PK
scripts.electronics = load_script("electronics.lua", env({}, {}))
scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
local money = { bal = 1e7 }
scripts.company = { spend = function(v) if v > money.bal then return false end money.bal = money.bal - v; return true end,
                    refund = function(v) money.bal = money.bal + v end, earn = function(v) money.bal = money.bal + v end,
                    afford = function(v) return v <= money.bal end }
scripts.crew = { activeId = function() return 2 end, credit = function() end, roster = function() return {} end,
                 hasRole = function() return true end }
scripts.field_builder = { pushHistory = function() end }
local terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - R end }
local X = { space = SPACE, terrain = terrain }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, X))
scripts.structures = ST
local CB = load_script("base_cable.lua", env(s, scripts, X))
scripts.base_cable = CB
local BPs = load_script("base_power.lua", env(s, scripts, X))
scripts.base_power = BPs
local BG = load_script("base_grid.lua", env(s, scripts, X))
scripts.base_grid = BG
scripts.base_facilities = { setGuards = function() end }
local BT = load_script("base_tower.lua", env(s, scripts, X))
scripts.base_tower = BT
BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 }); BPs.start({ id = 4 })

local function struct(x, y, z, part)
  local l = math.sqrt(x * x + y * y + z * z)
  local U = { x = x / l, y = y / l, z = z / l }
  local F = { x = -U.y, y = U.x, z = 0 }
  return ST.add(ST.newRecord(nil, "Vever", x, y, z, U, F, part))
end
-- a point `d` m round the equator from the site, on the night side's edge
local function at(d) local th = d / R return -R * math.cos(th), R * math.sin(th), 0 end
local function tick(dt_real) local e = getfenv(BG.update); e.time = e.time + dt_real; BG.update({}, 0.016) end

-- base A: a tower, a 60 kW generator and a Battery Bank; base B 1.2 km round: its tower and a 30 kW furnace
local tA = struct(-R, 0, 0, "tower")
BT.update({}, 0.016)
local bA = ST.getPart(tA, 1).base
local gx, gy, gz = at(30)
local sGen = struct(gx, gy, gz, "bigGen")
ST.addPart(sGen, { id = "batteryBank", x = 4, y = 0, z = 0 })
local bxx, byy, bzz = at(1200)
local tB = struct(bxx, byy, bzz, "tower")
BT.update({}, 0.016)
local bB = ST.getPart(tB, 1).base
local fx, fy, fz = at(1220)
local sB = struct(fx, fy, fz, "heater")
tick(0.6)
check(BG.gridOf(bA) ~= BG.gridOf(bB), "two bases 1.2 km apart: two grids")
-- a 35 mm² cable from the generator's structure to the furnace's, 1.2 km
local c1 = CB.add({ b = "Vever", a = { sid = sGen, uid = 1 }, z = { sid = sB, uid = 1 }, len = 1200, h = { R, R }, ty = "lv35",
                    paid = { cost = 3600, ship = 100, total = 3700, t = clock.a } })
tick(0.6)
local pA = BT.power(bA)
local f1 = BG.cableFlow(c1)
check(BG.gridOf(bA) == BG.gridOf(bB) and f1 and f1.P > 31, string.format("one grid on the cable: %.1f kW down it to base B", f1 and f1.P or -1))
local want = BP.lossKW(f1.P, BP.resistance("lv35", 1200), 400)
check(near(pA.loss, want, 1e-6) and pA.loss > 3, string.format("400 V over 1.2 km: %.2f kW lost (%.0f %% of what it carries) on base A's card", pA.loss, 100 * pA.loss / f1.P))
check((pA.limited or ""):find("cable " .. c1, 1, true) and (pA.limited or ""):find("transformer", 1, true),
  string.format("the cable runs at %d %% of its rating; limited by: %s", math.floor(f1.share * 100), tostring(pA.limited)))
check(f1.share < 1 and not CB.get(c1).burnt, "...under its rating: not burnt")
-- the same run at 11 kV: a transformer at each end and the HV cable between
CB.remove(c1)
local xA = ST.addPart(sGen, { id = "transformer.steel", x = -4, y = 0, z = 0 })
local xB = ST.addPart(sB, { id = "transformer.steel", x = -4, y = 0, z = 0 })
local c2 = CB.add({ b = "Vever", a = { sid = sGen, uid = xA }, z = { sid = sB, uid = xB }, len = 1200, h = { R, R }, ty = "hv35",
                    paid = { cost = 10800, ship = 100, total = 10900, t = clock.a } })
tick(0.6)
local pA2 = BT.power(bA)
local f2 = BG.cableFlow(c2)
check(f2 and f2.P > 31 and f2.loss < 0.01, string.format("on the 11 kV line: %.1f kW carried, %.1f W lost in the cable", f2 and f2.P or -1, (f2 and f2.loss or 0) * 1000))
check(pA2.loss < 1.5 and pA2.loss > 0.5, string.format("...the two transformers' own losses are most of it: %.2f kW in all (was %.2f)", pA2.loss, pA.loss))
local xf = BG.partFlow(sGen, xA)
check(xf.kW and near(xf.kW, f2.P, 1e-9) and xf.share > 0.3 and xf.loss > 0.25, string.format("the transformer carries %.1f kW, %d %% of 100 kVA", xf.kW or -1, math.floor((xf.share or 0) * 100)))
-- over a Power Pole 60 m from tower A (inside its 150 m): the pole is on the
-- line, not on the tower's ring, so both spans carry the power
do
  CB.remove(c2)
  local ppx, ppy, ppz = at(60)
  local pole = struct(ppx, ppy, ppz, "powerPole.steel")
  local h1 = CB.add({ b = "Vever", a = { sid = sGen, uid = xA }, z = { sid = pole, uid = 1 }, len = 30, h = { R, R }, ty = "hv35", paid = { cost = 1, ship = 0, total = 1, t = clock.a } })
  local h2 = CB.add({ b = "Vever", a = { sid = pole, uid = 1 }, z = { sid = sB, uid = xB }, len = 1170, h = { R, R }, ty = "hv35", paid = { cost = 1, ship = 0, total = 1, t = clock.a } })
  tick(0.6); BT.power(bA)
  local q1, q2 = BG.cableFlow(h1), BG.cableFlow(h2)
  check(q1 and q2 and q1.P > 31 and near(q1.P, q2.P, 1e-6), string.format("over a pole inside the tower's 150 m: both spans carry it (%.2f / %.2f kW)", q1 and q1.P or -1, q2 and q2.P or -1))
  CB.remove(h1); CB.remove(h2); ST.remove(pole)
  c2 = CB.add({ b = "Vever", a = { sid = sGen, uid = xA }, z = { sid = sB, uid = xB }, len = 1200, h = { R, R }, ty = "hv35",
                paid = { cost = 10800, ship = 100, total = 10900, t = clock.a } })
  tick(0.6); BT.power(bA)
end
-- validity: an 11 kV cable only between two transformers
do
  local v = CB.validity({ sid = sGen, uid = xA, ty = "hv35" }, { rec = ST.get(sB), part = ST.getPart(sB, 1) }, "Vever", "hv35")
  check(v.bad and v.bad:find("between Transformers", 1, true), "an HV cable onto a furnace is refused: " .. tostring(v.bad))
  local v2 = CB.validity({ sid = sGen, uid = 1, ty = "lv16" }, { rec = ST.get(sB), part = ST.getPart(sB, xB) }, "Vever", "lv16")
  check(v2.bad and v2.bad:find("HV Cable", 1, true), "a 400 V cable onto a transformer is refused: " .. tostring(v2.bad))
end
-- a breaker at the far end on a 400 V line: the overload trips it
CB.remove(c2)
local brk = ST.addPart(sB, { id = "breaker63.steel", x = 2, y = 1, z = 1 })
local c3 = CB.add({ b = "Vever", a = { sid = sGen, uid = 1 }, z = { sid = sB, uid = brk }, len = 1200, h = { R, R }, ty = "lv35",
                    paid = { cost = 7200, ship = 100, total = 7300, t = clock.a } })
local trips0 = BG.trips
tick(0.6)
BT.power(bA)
check(BPs.breakerState(sB, brk) == "tripped" and BG.trips == trips0 + 1, string.format("~33 kW through the 63 A breaker trips it the moment the line is up (%s)", BPs.breakerState(sB, brk)))
check(BG.gridOf(bA) ~= BG.gridOf(bB), "...and the grid splits back into two")
local fd = BG.cableFlow(c3)
check(fd and fd.dead and fd.why == "breaker tripped", "the cable reads dead: " .. tostring(fd and fd.why))
local lt = BPs.lastTrips[#BPs.lastTrips]
check(lt and lt.kind == "trip" and lt.rating == 25.2 and lt.kW > 25.2, string.format("the trip is logged: %.1f kW through %.1f kW", lt and lt.kW or -1, lt and lt.rating or -1))
-- reset by hand: still overloaded, it trips again
BPs.setBreaker(sB, brk, true, "hand")
tick(0.6); BT.power(bA)
check(BPs.breakerState(sB, brk) == "tripped" and BG.trips == trips0 + 2, "reset with the furnace still on: it trips again at once")
-- the furnace swapped for a 20 kW heater, reset: it holds
ST.removeParts(sB, { 1 })
local hS = ST.addPart(sB, { id = "heaterS", x = 0, y = 0, z = -3 })
BPs.setBreaker(sB, brk, true, "hand")
tick(0.6)
local pA3 = BT.power(bA)
local f3 = BG.cableFlow(c3)
check(BPs.breakerState(sB, brk) == "closed" and f3 and not f3.dead and f3.P > 20 and f3.P < 25.2 and BG.gridOf(bA) == BG.gridOf(bB),
  string.format("a 20 kW load, reset: it holds (%.1f kW of 25.2), one grid again", f3 and f3.P or -1))
local pf = BG.partFlow(sB, brk)
check(pf.state == "closed" and not pf.main and pf.cables == 1 and near(pf.kW, f3.P, 1e-9), string.format("the breaker reads %.1f kW, guarding 1 cable", pf.kW or -1))
-- switched off by hand (the logic seam): the line goes dead; the hook hears it
local heard = nil
BPs.onBreaker[#BPs.onBreaker + 1] = function(sid, uid, state, by) heard = { sid, uid, state, by } end
BPs.setBreaker(sB, brk, false, "logic")
tick(0.6); BT.power(bA)
check(BG.cableFlow(c3).dead and BG.cableFlow(c3).why == "breaker open" and heard and heard[3] == "open" and heard[4] == "logic",
  "a breaker opened by logic (S8's seam): the line dead, the hook told")
BPs.setBreaker(sB, brk, true, "hand")
tick(0.6); BT.power(bA)
-- a main breaker: one with no cable on base B's tower structure; the tower + a 30 kW furnace there
local mainB = ST.addPart(tB, { id = "breaker63.steel", x = 1, y = 1, z = 1 })
ST.addPart(tB, { id = "heater", x = 3, y = 0, z = 0 })
tick(0.6); BT.power(bA)
check(BPs.breakerState(tB, mainB) == "tripped", "a main breaker on a structure drawing 32 kW trips")
local pB = BT.power(bB)
check(pB.need < 20 + 0.001 + 1e-6, string.format("...and its structure's loads are off the grid (base B's draw %.1f kW)", pB.need))
check(BG.partFlow(tB, mainB).main, "the menu knows it as that structure's main")
-- a bare 16 mm² cable driven past 125 %: it burns through
ST.removeParts(tB, { mainB })
local c4 = CB.add({ b = "Vever", a = { sid = sGen, uid = 1 }, z = { sid = tB, uid = 1 }, len = 300, h = { R, R }, ty = "lv16",
                    paid = { cost = 900, ship = 50, total = 950, t = clock.a } })
tick(0.6); BT.power(bA)
local r4 = CB.get(c4)
check(r4.burnt ~= nil and BG.cableFlow(c4).burnt, string.format("an unguarded 16 mm² cable carrying the furnace burns through (burnt at %s)", tostring(r4.burnt)))
local bal = money.bal
local okS = CB.splice(c4)
check(okS and CB.get(c4).burnt == nil and bal - money.bal == CB.spliceCost(r4), string.format("spliced for %d (a quarter of its price)", bal - money.bal))
tick(0.6); BT.power(bA)
check(CB.get(c4).burnt ~= nil, "...and with the furnace still on it, it burns again")
-- the record: type and state saved
check(s["cable." .. c3].ty == "lv35" and s["cable." .. c4].burnt ~= nil, "the cable's type and its burn are in the save")
-- (the furnace on base B's tower structure shares the far bus: the line's
-- breaker tripped again with it, and that trip is in the structure's record)
local stB = ST.partState(sB, brk)
check(stB and stB.trip ~= nil and BPs.breakerState(sB, brk) == "tripped", "the far breaker's trip is kept in its structure's record (saved)")
ST.removeParts(tB, { 2 })

-- ── the cost: 3 networks, 40 cables, 10 breakers ────────────────────────────
do
  -- three bases 1.2 km apart, each 13-14 structures on a chain of cables and
  -- a few breakers, plus two lines between them → one big grid; then cut
  local t0 = os.clock()
  local sids, ncab, nbrk = {}, 0, 0
  for n = 1, 3 do
    local base = 2000 + n * 1300
    local x, y, z = at(base)
    local t = struct(x, y, z, "tower")
    local prev = nil
    for k = 1, 13 do
      local px, py, pz = at(base + 160 + k * 25)
      local sid = struct(px, py, pz, (k == 1) and "bigGen" or ((k == 2) and "solarArray" or "heaterS"))
      if k % 4 == 0 and nbrk < 10 then ST.addPart(sid, { id = "breaker160.steel", x = 1, y = 1, z = 0 }); nbrk = nbrk + 1 end
      if prev then
        local ruid = ST.get(sid).bp[#ST.get(sid).bp].uid
        CB.add({ b = "Vever", a = { sid = prev, uid = 1 }, z = { sid = sid, uid = ruid }, len = 25, h = { R, R }, ty = "lv95",
                 paid = { cost = 1, ship = 0, total = 1, t = clock.a } })
        ncab = ncab + 1
      end
      prev = sid
      sids[#sids + 1] = sid
    end
    if n < 3 then
      -- (the 40th cable comes after)
    end
  end
  -- 36 chain cables + 4 more: two lines from each base's chain end to the next (making 3 networks of 13 each joined... kept apart: guard them open)
  for k = 1, 4 do
    local a, z = sids[13 * ((k - 1) % 2) + 13], sids[13 * ((k - 1) % 2) + 14]
    local bk = ST.addPart(z, { id = "breaker63.steel", x = -1, y = 1, z = 0 })
    BPs.setBreaker(z, bk, false, "hand")
    CB.add({ b = "Vever", a = { sid = a, uid = 1 }, z = { sid = z, uid = bk }, len = 1300, h = { R, R }, ty = "lv35",
             paid = { cost = 1, ship = 0, total = 1, t = clock.a } })
    ncab = ncab + 1
  end
  local build = os.clock() - t0
  t0 = os.clock()
  BG.rebuildNow()
  local reb = os.clock() - t0
  t0 = os.clock()
  for _ = 1, 50 do clock.a = clock.a + 2; BG.advanceNow() end
  local adv = (os.clock() - t0) / 50
  local nets = 0
  for _, g in ipairs(BG.grids()) do if BG.model(g.id).net and #BG.model(g.id).net.edges >= 10 then nets = nets + 1 end end
  check(nets >= 3 and ncab >= 40, string.format("%d networks of 10+ cables, %d cables, %d breakers on the grids", nets, ncab, nbrk))
  check(reb < 0.25 and adv < 0.01, string.format("the cost: a rebuild (topology, 96 slots of flows for each network) %.1f ms; a 2 s step %.3f ms", reb * 1000, adv * 1000))
  print(string.format("  netpower cost: rebuild %.2f ms, advance %.4f ms, (records %.1f ms)", reb * 1000, adv * 1000, build * 1000))
end

-- ── done ────────────────────────────────────────────────────────────────────
if #failures > 0 then
  print(string.format("FAIL smoke_netpower: %d of %d", #failures, #failures + passed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print(string.format("smoke_netpower: %d passed", passed))
