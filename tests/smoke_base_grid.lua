-- SMOKE: the base grid, its storage and its cables (deep-space addendum step 8:
-- M6, B9b; docs/base-building.md §12), against a stub save and a small solar
-- system on a real two-body orbit, with the real parts_base / structures /
-- bases / base_grid / base_cable / base_tower / base_economy / electronics.
--
--   * the parts: the Battery Bank (a store), the Shield Wall (a shield by
--     record), the Power Cable (a run: length limit, mass and price a metre),
--     their prefabs;
--   * the grids: every structure within 150 m of a tower on its base's grid,
--     one 200 m off on its own, a cable joining it, two bases joined by a
--     cable into one grid with both towers as loads;
--   * the year's light: the world's period from its conic, an array's output
--     slot by slot (day and night), the slots anchored on the agency clock;
--   * the store, exactly: one big step lands where thousands of small ones do
--     (to 1e-6), over hours and over weeks (whole years skipped), with the
--     battery clamping full and running empty;
--   * night storage: a solar tower with a Battery Bank stays a ground station
--     through the night; without one it is a mast after dusk;
--   * the scene half: base_grid keeps the grids in step with the records,
--     base_tower.power reads them, bases() carries grid power, storage and
--     crew; the catch-up on the save clock when it loads; the charge saved;
--   * cables: the ends on the parts' sides, the hang to the ground, the run
--     on the ground, the length limit, the bill, the undo ring's step, a part
--     taken down taking its cable up.
--
--   luajit solar/tests/smoke_base_grid.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
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
local function slurp(p) local f = io.open(p); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- ── the parts ───────────────────────────────────────────────────────────────
local PB = load_script("parts_base.lua", env({}, {}))
local BB, SW, PC = PB.partInfo("batteryBank"), PB.partInfo("shieldWall"), PB.partInfo("powerCable")
check(BB and BB.power and BB.power.kind == "store" and BB.power.cap == 4000 and BB.power.eff < 1 and BB.onDeck and near(BB.mass, 2.6),
  "the Battery Bank: a 4,000 EC store, charged at " .. tostring(BB and BB.power.eff) .. ", 2.6 t, stands on a deck")
check(SW and SW.shield and near(SW.shield.k, 0.05) and near(SW.half.x, 1.0) and near(SW.half.y, 1.0) and near(SW.half.z, 0.25) and near(SW.mass, 4.6),
  "the Shield Wall: 2 x 2 x 0.5 m, 4.6 t (2.3 t/m3), lets 5 % through")
check(PC and PC.cable and PC.cable.max == 1500 and near(PC.cable.kgm, 1.4) and near(PC.cable.perm, 3.0),
  "the Power Cable: up to 1.5 km a run, 1.4 kg and $3 a metre")
check(slurp("solar/prefabs/BaseBattery.prefab.ron") and slurp("solar/prefabs/BaseShieldWall.prefab.ron") and slurp("solar/prefabs/BaseCableDrum.prefab.ron"),
  "...their prefabs on disk")
check((slurp("solar/prefabs/BaseShieldWall.prefab.ron") or ""):find('name: "Wall 1"', 1, true) ~= nil, "the wall's collider box")
local cat = PB.catalogue()[1].ids
check(#cat == 14 and cat[5] == "baseHub" and cat[9] == "batteryBank" and cat[10] == "shieldWall" and cat[11] == "powerCable" and cat[14] == "hvCable",
  "the BASE column: ten parts, S5's three more cable drums and the Base Hub (playtest 11-09)")

-- ── a small solar system on a real conic ────────────────────────────────────
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
local E = load_script("electronics.lua", env({}, {}))
local BG0 = load_script("base_grid.lua", env({}, {}))
local Y = BG0.yearOf(bodies[2], bodies[1])
check(Y and near(Y, 2 * math.pi * math.sqrt(RS ^ 3 / MU), 1e-6), string.format("the world's year from its conic: %.1f s", Y or -1))

-- the site: on Vever's equator facing the sun now (body-relative −X), the
-- array's tracking axis square to the orbit's plane
local s = { ["base.body"] = "Vever" }
local clock = { a = 1000 }
local scripts = {}
scripts.parts_base = PB
scripts.electronics = E
scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
local money = { bal = 1e6, log = {} }
scripts.company = { spend = function(v, why) if v > money.bal then return false end money.bal = money.bal - v; money.log[#money.log + 1] = { -v, why }; return true end,
                    refund = function(v, why) money.bal = money.bal + v; money.log[#money.log + 1] = { v, why } end,
                    earn = function(v) money.bal = money.bal + v end, afford = function(v) return v <= money.bal end }
local credits = {}
scripts.crew = { activeId = function() return 2 end, credit = function(id, k, n) credits[#credits + 1] = { id, k, n } end,
                 roster = function() return { { id = 2, status = "afoot", body = "Vever", x = -R - 5, y = 3, z = 0 },
                                              { id = 3, status = "base" }, { id = 4, status = "afoot", body = "Vever", x = R, y = 0, z = 0 } } end }
local hist = {}
scripts.field_builder = { pushHistory = function(e) hist[#hist + 1] = e end }
local terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - R end }
local X = { space = SPACE, terrain = terrain }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, X))
scripts.structures = ST
local CB = load_script("base_cable.lua", env(s, scripts, X))
scripts.base_cable = CB
local BG = load_script("base_grid.lua", env(s, scripts, X))
scripts.base_grid = BG
scripts.base_facilities = { setGuards = function() end }
local BT = load_script("base_tower.lua", env(s, scripts, X))
scripts.base_tower = BT
BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 })

-- each structure stands square to its own ground: up radial, front along the
-- equator (so a part's +X, the arrays' tracking axis, is −Z: square to the orbit)
local function struct(id, x, y, z, part, opts)
  local l = math.sqrt(x * x + y * y + z * z)
  local U = { x = x / l, y = y / l, z = z / l }
  local F = { x = -U.y, y = U.x, z = 0 }
  local rec = ST.newRecord(nil, "Vever", x, y, z, U, F, part, opts)
  return ST.add(rec)
end
-- along the equator: a point `d` m round from the site
local function at(d) local th = d / R return -R * math.cos(th), R * math.sin(th), 0 end
-- the base: a tower; 40 m off two Solar Arrays and a Battery Bank; 200 m off an Isotope Skid
local tsid = struct(nil, -R, 0, 0, "tower")
BT.update({}, 0.016)
local bid = ST.getPart(tsid, 1).base
check(bid ~= nil, "the tower founds its base")
local ax1, ay1, az1 = at(40)
local s_arr = struct(nil, ax1, ay1, az1, "solarArray")
ST.addPart(s_arr, { id = "solarArray", x = 3, y = 0, z = 0 })
local ax2, ay2, az2 = at(46)
local s_bat = struct(nil, ax2, ay2, az2, "batteryBank")
local ax3, ay3, az3 = at(200)
local s_far = struct(nil, ax3, ay3, az3, "isotopeSkid")
local ax4, ay4, az4 = at(260)
local s_bare = struct(nil, ax4, ay4, az4, "padPlate")

-- ── the grids (pure) ────────────────────────────────────────────────────────
local grids, bySid = BG.buildGrids(ST.list(), scripts.bases.list(), {}, PB.partInfo, ST.partPose)
local g1 = bySid[tsid]
check(#grids == 2 and g1 and bySid[s_arr] == g1 and bySid[s_bat] == g1 and #g1.bases == 1 and g1.bases[1] == bid,
  "within 150 m: the tower, the arrays and the bank share one grid (" .. #grids .. " grids)")
check(bySid[s_far] and bySid[s_far] ~= g1, "the skid 200 m off is a grid of its own")
check(bySid[s_bare] == nil, "a bare plate on its own is no grid at all")
local M1 = BG.gridModel(g1, ST.partPose, 2.0)
check(#M1.arrays == 2 and M1.need == 2.0 and M1.C == 4000 and M1.base == 0 and #M1.loads == 1 and M1.loads[1].bid == bid,
  "the base's model: two arrays, the tower's 2 EC/s, 4,000 EC of storage")
local g2, bys2 = BG.buildGrids(ST.list(), scripts.bases.list(), { { a = { sid = s_bat, uid = 1 }, z = { sid = s_far, uid = 1 } } }, PB.partInfo, ST.partPose)
check(#g2 == 1 and bys2[s_far] == bys2[tsid] and bys2[tsid].cables == 1, "a cable from the bank to the skid: one grid")
check(BG.gridModel(bys2[tsid], ST.partPose, 2.0).base == 2.0, "...and the skid's 2 EC/s is on it")
-- J6 (step 9): a bank set up by a level-2 Engineer carries `effk` and charges better
local beff = PB.partInfo("batteryBank").power.eff
check(math.abs(M1.eff - beff) < 1e-9, string.format("the bank charges at its own %.2f", beff))
ST.getPart(s_bat, 1).effk = 0.03
local M1e = BG.gridModel(g1, ST.partPose, 2.0)
check(math.abs(M1e.eff - (beff + 0.03)) < 1e-9 and math.abs(M1e.stores[1].eff - (beff + 0.03)) < 1e-9,
  string.format("set up by a level-2 Engineer: %.2f", M1e.eff))
ST.getPart(s_bat, 1).effk = 0.5
check(math.abs(BG.gridModel(g1, ST.partPose, 2.0).eff - 0.99) < 1e-9, "...capped at 0.99")
ST.getPart(s_bat, 1).effk = nil

-- ── the year's light (pure) ─────────────────────────────────────────────────
local L = Y / BG.SLOTS
local ref = MU / RS ^ 2
local prof = BG.slotLight(M1.arrays[1], { E = E, body = bodies[2], sun = bodies[1], ref = ref, L = L, N = BG.SLOTS, lead = 0 })
local lit, peak = 0, 0
for _, v in ipairs(prof) do if v > 0 then lit = lit + 1 end; peak = math.max(peak, v) end
check(#prof == BG.SLOTS and lit >= 40 and lit <= 56 and near(peak, 3.0, 0.05),
  string.format("an array's year: lit in %d of %d slots (half, the night side the rest), %.2f EC/s at noon", lit, BG.SLOTS, peak))
check(prof[1] > 2.9 and prof[BG.SLOTS / 2 + 1] == 0, "...noon now, midnight half a year on")
local now_out = E.solarOutput(3.0, bodies[2].x + M1.arrays[1].x, M1.arrays[1].y, M1.arrays[1].z, M1.arrays[1].ax, M1.arrays[1].ay, M1.arrays[1].az, bodies, ref)
check(near(prof[1], now_out, 0.02), string.format("slot 0 agrees with solarOutput now (%.3f vs %.3f)", prof[1], now_out))

-- ── the store, exactly ──────────────────────────────────────────────────────
local function model(prof2, base, need, C, eff)
  return { base = base or 0, prof = prof2, need = need or 2, C = C or 4000, eff = eff or 0.92, A0 = 0, L = L, N = BG.SLOTS,
           loads = { { kind = "tower", bid = 1, need = need or 2 } } }
end
local twice = {}
for j = 1, BG.SLOTS do twice[j] = prof[j] * 2 end
local Mx = model(twice, 0, 2.0, 4000, 0.92)
local function run_small(M, e0, a0, a1, step)
  local st = { e = e0 }
  local rep = { short = 0, slots = 0, years = 0 }
  local a, k = a0, 0
  while a < a1 do
    k = k + 1
    local d = step * (0.6 + 0.8 * ((k * 7919) % 13) / 13)   -- uneven steps
    local b = math.min(a + d, a1)
    BG.advance(st, M, a, b, rep)
    a = b
  end
  return st.e, rep.short
end
local function run_big(M, e0, a0, a1)
  local st = { e = e0 }
  local _, rep = BG.advance(st, M, a0, a1)
  return st.e, rep.short, rep.years
end
local eS, sS = run_small(Mx, 2000, 37.3, 37.3 + 3.7 * Y, 2.0)
local eB, sB = run_big(Mx, 2000, 37.3, 37.3 + 3.7 * Y)
check(near(eS, eB, 1e-6) and near(sS, sB, 1e-6), string.format("3.7 years in one step = in uneven 2 s steps: %.6f / %.6f EC, shed %.6f / %.6f s", eB, eS, sB, sS))
-- a grid short of power: it runs empty and sheds, and still agrees
local thin = {}
for j = 1, BG.SLOTS do thin[j] = prof[j] * 1.1 end
local Mt = model(thin, 0, 2.0, 4000, 0.92)
local eS2, sS2 = run_small(Mt, 500, 5, 5 + 2.3 * Y, 3.0)
local eB2, sB2 = run_big(Mt, 500, 5, 5 + 2.3 * Y)
check(sB2 > 0 and near(eS2, eB2, 1e-6) and near(sS2, sB2, 1e-6), string.format("a short grid runs dry (shed %.0f s) and one step still agrees (%.6f / %.6f)", sB2, eB2, eS2))
-- weeks: whole years skipped, the same answer as stepping it
local W1 = 20 * 86400
local eS3, sS3 = run_small(Mx, 1000, 11, 11 + W1, 300)
local eB3, sB3, yrs = run_big(Mx, 1000, 11, 11 + W1)
check(yrs and yrs > 100 and near(eS3, eB3, 1e-6) and near(sS3, sB3, 1e-4), string.format("20 days: %d years skipped, %.6f / %.6f EC, shed %.3f / %.3f s", yrs or 0, eB3, eS3, sB3, sS3))
local eS4, sS4 = run_small(Mt, 1000, 11, 11 + W1, 300)
local eB4, sB4, yrs4 = run_big(Mt, 1000, 11, 11 + W1)
check(yrs4 > 100 and near(eS4, eB4, 1e-6) and near(sS4, sB4, 1e-3), string.format("...and the short grid's 20 days: %.6f / %.6f EC, shed %.1f / %.1f s", eB4, eS4, sB4, sS4))
-- a straight year (never full, never empty): the linear skip
local flat = model(nil, 2.0005, 2.0, 1e9, 1.0)
flat.prof = nil
local eS5 = run_small(flat, 100, 0, 30 * Y, 50)
local eB5 = run_big(flat, 100, 0, 30 * Y)
check(near(eS5, eB5, 1e-6) and near(eB5, 100 + 0.0005 * 30 * Y, 1e-6), "a store that only fills: the same line either way")

-- ── night storage ───────────────────────────────────────────────────────────
-- dusk: the first dark slot after noon; a night is about half a year
local dusk = nil
for j = 2, BG.SLOTS do if prof[j] == 0 and prof[j - 1] > 0 then dusk = j - 1 break end end
local dawn = nil
for j = dusk + 1, BG.SLOTS do if prof[j] > 0 then dawn = j break end end
local night = (dawn - dusk - 1) * L
check(dusk and dawn and night > 0.4 * Y and night < 0.6 * Y, string.format("the night: %.0f s of a %.0f s year", night, Y))
do
  local st = { e = 2000 }
  local _, rep = BG.advance(st, Mx, dusk * L, (dawn - 1) * L)
  check(rep.short == 0 and st.e > 0 and near(st.e, 2000 - 2.0 * night, 1e-6),
    string.format("a solar tower with a half-full Battery Bank: a ground station all night (%.0f EC left at dawn, none shed)", st.e))
  local _, _, served, all = BG.statusAt(Mx, st, (dawn - 1.5) * L)
  check(all and served[1], "...still served just before dawn")
  local nb = model(twice, 0, 2.0, 0, 1)
  local st2 = { e = 0 }
  local _, rep2 = BG.advance(st2, nb, dusk * L, (dawn - 1) * L)
  local _, _, served2, all2 = BG.statusAt(nb, st2, (dawn - 1.5) * L)
  check(near(rep2.short, night, 1e-6) and not all2 and not served2[1], string.format("without one: a mast from dusk to dawn (%.0f s shed)", rep2.short))
end

-- ── the scene half: base_grid with the records ──────────────────────────────
s["grid.a"] = nil
BG.update({}, 0.016)
local tp = BT.power(bid)
check(tp.grid and tp.cap == 4000 and near(tp.stored, 2000, 1e-6) and tp.need == 2.0 and tp.structures == 3,
  string.format("base_grid: the base's grid (%s, %d structures), a new bank half full (%.0f EC)", tostring(tp.grid), tp.structures or -1, tp.stored or -1))
check(tp.powered and tp.supply > 5.5, string.format("noon: the arrays give %.2f EC/s, the tower is a ground station", tp.supply))
check(s["grid.e"] and s["grid.e"][tostring(s_bat) .. ":1"] and s["grid.a"] == clock.a and s["grid.a0"] == clock.a, "the charge is saved by the bank, with the clocks")
-- time passes: the grid advances on its own clock, every couple of seconds
local E0 = tp.stored
clock.a = clock.a + 100
local env_bg = getfenv and nil
BG.update({}, 0.016)           -- (under the 2 s: no solve)
check(near(BT.power(bid).stored, E0, 1e-9), "not solved again inside two seconds")
-- (the real clock: time is the script env's own)
local function tick(dt_real) local e = getfenv(BG.update); e.time = e.time + dt_real; BG.update({}, 0.016) end
tick(2.1)
local tp2 = BT.power(bid)
check(tp2.stored > E0 and near(tp2.stored, math.min(4000, E0 + (tp.supply - 2) * 0.92 * 100), 1.0),
  string.format("100 s of noon later: %.1f EC (charging at %.2f EC/s)", tp2.stored, (tp.supply - 2) * 0.92))
-- bases(): grid power, storage, crew
local list = BT.bases({ brief = true })
local ob = nil
for _, e in ipairs(list) do if e.id == bid then ob = e end end
check(ob and ob.grid == tp.grid and ob.cap == 4000 and ob.stored and ob.supply and ob.crew == 1 and ob.gridLine and ob.gridLine:find("battery", 1, true),
  string.format("bases(): grid %s, %s, %d crew on foot there", tostring(ob and ob.grid), tostring(ob and ob.gridLine), ob and ob.crew or -1))
-- a cable to the far skid joins it
local cid = CB.add({ b = "Vever", a = { sid = s_bat, uid = 1 }, z = { sid = s_far, uid = 1 }, len = 160, h = { R, R },
                     paid = { cost = 480, ship = 98, total = 578, t = clock.a } })
tick(0.6)
local tp3 = BT.power(bid)
check(tp3.structures == 4 and tp3.cables == 1 and tp3.supply > tp2.supply + 1.9, string.format("a cable to the skid 200 m off: 4 structures, %.2f EC/s", tp3.supply))
-- the catch-up when it loads: the save clock 5,000 s behind
local stored0 = BT.power(bid).stored
s["grid.a"] = clock.a - 5000
local BGr = load_script("base_grid.lua", env(s, scripts, X))
local sc2 = setmetatable({ base_grid = BGr }, { __index = scripts })
local BTr = load_script("base_tower.lua", env(s, sc2, X))
BGr.start({ id = 9 }); BTr.start({ id = 10 })
BTr.update({}, 0.016)
BGr.update({}, 0.016)
local cu = BGr.lastCatchUp()
local tp4 = BTr.power(bid)
local Mr = BGr.model(tp4.grid)
local st_ref = { e = stored0 }
BGr.advance(st_ref, Mr, clock.a - 5000, clock.a)
check(cu and near(cu.dt, 5000, 1e-6) and near(tp4.stored, st_ref.e, 1e-6),
  string.format("a load 5,000 s after the save: caught up in one step (%.1f EC, as the closed form says)", tp4.stored))
check(near(s["grid.e"][tostring(s_bat) .. ":1"], tp4.stored, 1e-9), "...and the bank's charge saved")
-- idle: nothing changed, inside two seconds, nothing solved
local n0 = BGr.PROF.n_advance + BGr.PROF.n_rebuild
for _ = 1, 50 do BGr.update({}, 0.016) end
check(BGr.PROF.n_advance + BGr.PROF.n_rebuild == n0, "an idle frame solves nothing")
-- (the rest goes on with the first instance, its clock where the reload left it)
s["grid.a"] = clock.a

-- ── two bases on one cable ──────────────────────────────────────────────────
local bx5, by5, bz5 = at(1150)
local t2 = struct(nil, bx5, by5, bz5, "tower")
BT.update({}, 0.016)
local bid2 = ST.getPart(t2, 1).base
tick(0.6)
check(bid2 and BT.power(bid2).grid ~= BT.power(bid).grid and not BT.power(bid2).powered, "a second base 1.15 km on: a grid of its own, a mast")
CB.add({ b = "Vever", a = { sid = s_far, uid = 1 }, z = { sid = t2, uid = 1 }, len = 950, h = { R, R }, paid = { total = 0, t = clock.a } })
tick(0.6)
local pa, pb2 = BT.power(bid), BT.power(bid2)
check(pa.grid == pb2.grid and pa.towers == 2 and pa.need == 4.0 and pb2.powered, string.format("cabled: one grid, two towers drawing %.1f EC/s, both ground stations", pa.need))

-- ── cables: geometry, rules, the bill ───────────────────────────────────────
local rc = { a = { sid = s_bat, uid = 1 }, z = { sid = s_far, uid = 1 } }
local EN = CB.ends(rc)
local rbat = ST.get(s_bat)
local gx, gy, gz = ST.partPose(rbat, rbat.bp[1], 0)
local dside = math.sqrt((EN.ax - gx) ^ 2 + (EN.ay - gy) ^ 2 + (EN.az - gz) ^ 2)
check(EN and dside > 0.5 and dside < 1.6, string.format("the end leaves the bank's side %.2f m from its centre, 0.6 m up", dside))
local h = CB.sampleGround(bodies[2], EN, R, 3.0)
local okh = true
for _, r in ipairs(h) do if not near(r, R, 0.05) then okh = false end end
check(#h > 40 and okh, string.format("the run on the ground: %d samples on the distance field's ground", #h))
local pts, len = CB.polyline(EN, h, R)
local r1 = math.sqrt(pts[1].x ^ 2 + pts[1].y ^ 2 + pts[1].z ^ 2)
local rmid = math.sqrt(pts[math.floor(#pts / 2)].x ^ 2 + pts[math.floor(#pts / 2)].y ^ 2 + pts[math.floor(#pts / 2)].z ^ 2)
check(near(r1 - R, 0.6, 0.01) and near(rmid - R, 0.03, 0.01) and len > 150 and len < 170,
  string.format("it hangs from 0.6 m to the ground and lies on it (%.2f m up mid-run), %.0f m long", rmid - R, len))
local q = CB.quote(len)
check(q.cost == math.ceil(len * 3) and q.ship == scripts.base_economy.shipping(q.cost) and q.total == q.cost + q.ship, string.format("billed by the metre: $%d + $%d shipping", q.cost, q.ship))
check(near(q.mass, len * 1.4 / 1000, 1e-9), string.format("...%.2f t of cable", q.mass))
-- the rules
local vr = CB.validity({ sid = s_bat, uid = 1 }, { rec = ST.get(s_bat), part = ST.get(s_bat).bp[1] }, "Vever")
check(vr.bad and vr.bad:find("same structure", 1, true), "not to the same structure: " .. tostring(vr.bad))
local vr2 = CB.validity({ sid = s_bat, uid = 1 }, { rec = ST.get(s_arr), part = ST.get(s_arr).bp[1] }, "Vever")
check(vr2.bad and vr2.bad:find("one grid", 1, true), "not between two already on one grid: " .. tostring(vr2.bad))
local fx, fy, fz = at(2000)
local s_long = struct(nil, fx, fy, fz, "isotopeSkid")
tick(0.6)
local vr3 = CB.validity({ sid = t2, uid = 1 }, { rec = ST.get(s_long), part = ST.get(s_long).bp[1] }, "Vever")
check(vr3.bad == nil and vr3.len and vr3.len < 1500, string.format("850 m on from the second tower: allowed (%.0f m)", vr3.len or -1))
local vr4 = CB.validity({ sid = s_bat, uid = 1 }, { rec = ST.get(s_long), part = ST.get(s_long).bp[1] }, "Vever")
check(vr4.bad and vr4.bad:find("at most 1.5 km", 1, true), "past 1.5 km refused: " .. tostring(vr4.bad))
local vr5 = CB.validity(nil, { rec = ST.get(s_long), part = ST.get(s_long).bp[1] }, "Elsewhere")
check(vr5.bad and vr5.bad:find("home world", 1, true), "off the home world refused")
-- laying it: the bill, the record, the ring's step
local bal0, nc0 = money.bal, CB.count()
local id, why, q2, L2 = CB.lay({ sid = t2, uid = 1 }, { sid = s_long, uid = 1 })
local rr = id and CB.get(id)
check(id and rr and CB.count() == nc0 + 1 and near(bal0 - money.bal, q2.total, 1e-9) and #rr.h > 100 and rr.paid.total == q2.total and #hist == 1,
  string.format("laid: %.0f m, %s charged, the heights kept (%d), one step in the ring (%s)", L2 or -1, tostring(q2 and q2.total), rr and #rr.h or -1, tostring(why)))
tick(0.6)
check(BT.power(bid).structures == 6, "...and the skid at its far end is on the grid")
hist[1].undo()
check(CB.get(id) == nil and near(money.bal, bal0, 1e-9) and hist[1].res == q2.total, "Ctrl+Z within the minute: taken up, every dollar back")
hist[1].redo()
check(CB.get(id) ~= nil and near(bal0 - money.bal, q2.total, 1e-9), "Ctrl+Shift+Z: laid again")
-- a part taken down takes its cable up (the deconstruct rule)
clock.a = clock.a + 120
local bal1 = money.bal
ST.removeParts(s_long, { 1 })
CB.update({}, 0.016)
check(CB.get(id) == nil and money.bal - bal1 == q2.cost, string.format("its end taken down: the cable comes up, its price back past the minute ($%d)", money.bal - bal1))
-- the records in the save
local CB2 = load_script("base_cable.lua", env(s, scripts, X))
CB2.start({ id = 4 })
check(CB2.count() == CB.count() and CB2.get(cid) and CB2.get(cid).a.sid == s_bat, "a reload reads the same cables")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_base_grid: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_base_grid: %d passed", passed))
