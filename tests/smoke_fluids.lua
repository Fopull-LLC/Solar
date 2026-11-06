-- SMOKE: the fluid network (sandbox plan S7, work/sandbox/PLAN.md §3.3, §12;
-- docs/base-building.md §17), against the real fluids, parts_kit, parts_base
-- and reactor rulebooks.
--
--   * the solver: flow by pressure difference over each pipe's conductance,
--     pumps on their straight-line curves (free delivery, shut-off head, a
--     stall against a pressure over it), check valves, valves, regulators;
--   * the closed form: a day in one step equals 86,400 one-second steps (two
--     tanks levelling through a pipe, a pump emptying one into another with
--     its events), to 1e-6;
--   * electrolysis: the O2 Generator's water cell filled from a tank by a
--     pump, starved when the tank runs dry (the "limited by" line says so),
--     and its O2 / H2 / water in the 2:1 ratio of 2 H2O → 2 H2 + O2;
--   * the reactor's coolant inventory: a guillotine break (LOCA) blows the
--     primary down, trips it and uncovers the core; a charging pump can't
--     beat 15.5 MPa but a low-head pump refills a depressurised loop;
--   * the pieces and their networks built from records (risers between
--     storeys, open ends named, two substances refused).
--
--   luajit solar/tests/smoke_fluids.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end
local function rel(a, b, e) return math.abs(a - b) <= (e or 1e-6) * math.max(1, math.abs(a), math.abs(b)) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
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

local S = {}
local FL = load_script("fluids.lua", env({}, S))
S.fluids = FL

local function copy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = copy(v) end return o end
local function finish(net)
  for _, e in ipairs(net.els) do
    if not e.g then
      local g = FL.pipeG(e.bore or "DN25", e.len or 1, net.sub)
      if e.kind == "pump" then local gp = e.q0 / e.H0; e.g = 1 / (1 / gp + 1 / g); e.H = e.H0 else e.g = g end
    end
  end
  return net
end
local function liquid(x0, cap, area, r) local a, c = FL.liquidAC("water", area); return { kind = "tank", a = a, c = c, cap = cap, x0 = x0, r = r or 0 } end

-- ── the closed form: two tanks levelling through 6 m of DN25 ───────────────
do
  local net = finish({ sub = "water", nodes = { liquid(1800, 2000, 1.13), liquid(200, 2000, 1.13), { kind = "junction" } },
    els = { { kind = "cond", u = 1, v = 3, len = 3 }, { kind = "cond", u = 3, v = 2, len = 3 } } })
  local A = FL.newState(net)
  local B = copy(A)
  FL.advance(net, A, 86400)
  for _ = 1, 86400 do FL.advance(net, B, 1) end
  check(rel(A.x[1], B.x[1], 1e-6) and rel(A.x[2], B.x[2], 1e-6), string.format("two tanks level out: a day in one step = 86,400 steps (%.6f / %.6f kg)", A.x[1], B.x[1]))
  check(near(A.x[1], 1000, 1e-3) and near(A.x[2], 1000, 1e-3), string.format("…to the same level (%.3f, %.3f kg)", A.x[1], A.x[2]))
  local C = FL.newState(net)
  local rep = FL.advance(net, C, 60)
  local q = rep.q[1]
  -- the first minute: q = g Δp, Δp = ρ g Δh = 9.81 · 1600 / 1.13
  local g = FL.pipeG("DN25", 6, "water")
  check(rel(q, g * 9.81 * (C.x[1] - C.x[2]) / 1.13, 1e-6), string.format("flow is the conductance times the pressure difference (%.4f kg/s)", q))
end

-- ── a pump: its curve, its stall, its events ───────────────────────────────
do
  local H0, q0 = 6e5, 2.0
  local function pumpnet(pout, on)
    return finish({ sub = "water",
      nodes = { liquid(1500, 2000, 1.13), { kind = "junction" }, { kind = "junction" }, { kind = "fixed", p = pout } },
      els = { { kind = "cond", u = 1, v = 2, len = 0.3 }, { kind = "pump", u = 2, v = 3, q0 = q0, H0 = H0, len = 0.4, on = on ~= false }, { kind = "cond", u = 3, v = 4, len = 0.3 } } })
  end
  local n1 = pumpnet(FL.P_ATM)
  local s1 = FL.newState(n1)
  local r1 = FL.advance(n1, s1, 0)
  local qa = r1.q[2]
  local n2 = pumpnet(FL.P_ATM + 3e5)
  local r2 = FL.advance(n2, FL.newState(n2), 0)
  local qb = r2.q[2]
  check(qa > 1.5 and qa < q0 * 1.05 and qb < qa and qb > 0, string.format("a pump on its curve: %.2f kg/s at no lift, %.2f against 3 bar", qa, qb))
  -- the curve is straight: half the head left at half the flow
  check(near((qa - qb) / qa, 3e5 / (6e5 + (qa / q0 < 1 and 0 or 0)) * (qa / qa), 0.12), "flow falls in a straight line toward its shut-off head")
  local n3 = pumpnet(15.5e6)
  local s3 = FL.newState(n3)
  local r3 = FL.advance(n3, s3, 10)
  check(s3.em[2] == "stall" and near(r3.q[2], 0, 1e-12) and near(s3.x[1], 1500, 1e-9), string.format("against 15.5 MPa a 6 bar pump stalls: nothing flows (%s)", tostring(s3.em[2])))
  local n4 = pumpnet(FL.P_ATM, false)
  local r4 = FL.advance(n4, FL.newState(n4), 10)
  check(near(r4.q[2], 0, 1e-12), "a pump switched off blocks its line")
  -- pumped dry: one long step and many short ones meet the 'empty' event alike
  local nA = pumpnet(FL.P_ATM)
  local sA, sB = FL.newState(nA), FL.newState(nA)
  local rA = FL.advance(nA, sA, 3600)
  for _ = 1, 3600 do FL.advance(nA, sB, 1) end
  local ev = false
  for _, e in ipairs(rA.events) do if e == "empty" then ev = true end end
  check(ev and sA.x[1] == 0 and sB.x[1] == 0, "pumped dry within the hour: the tank's EMPTY event, in one step and in 3,600")
  check(sA.tm[1] ~= "N" and sB.tm[1] ~= "N", "an empty tank gives nothing (dry)")
  -- and where it ran dry: the same moment either way
  local nC = pumpnet(FL.P_ATM)
  local sC = FL.newState(nC)
  local t, step = 0, 0.5
  while sC.x[1] > 0 and t < 3600 do FL.advance(nC, sC, step); t = t + step end
  local sD = FL.newState(nC)
  local lo, hi = 0, 3600
  for _ = 1, 50 do local mid = (lo + hi) / 2; local s = FL.newState(nC); FL.advance(nC, s, mid); if s.x[1] > 0 then lo = mid else hi = mid end end
  check(hi <= t and t - hi < step + 1e-6, string.format("it runs dry at %.3f s (the half-second steps saw it by %.1f s)", hi, t))
end

-- ── a check valve, a valve, a regulator ────────────────────────────────────
do
  local net = finish({ sub = "water", nodes = { liquid(200, 2000, 1.13), liquid(1800, 2000, 1.13) },
    els = { { kind = "check", u = 1, v = 2, len = 2 } } })
  local s = FL.newState(net)
  FL.advance(net, s, 3600)
  check(near(s.x[1], 200, 1e-9) and s.em[1] == "shut", "a check valve holds the higher tank back (no flow backwards)")
  local net2 = finish({ sub = "water", nodes = { liquid(1800, 2000, 1.13), liquid(200, 2000, 1.13) },
    els = { { kind = "valve", u = 1, v = 2, len = 2, on = false } } })
  local s2 = FL.newState(net2)
  FL.advance(net2, s2, 3600)
  check(near(s2.x[1], 1800, 1e-9), "a shut valve holds")
  net2.els[1].on = true
  FL.advance(net2, s2, 3600)
  check(s2.x[1] < 1700, "opened, it passes")
  -- an O2 bottle rack at 200 bar through a 5 bar regulator into a line to a room
  local Vb = 0.15
  local a = FL.gasA("o2", Vb)
  local x0 = 200e5 / a
  local gnet = { sub = "o2", nodes = { { kind = "tank", a = a, c = 0, cap = x0, x0 = x0 }, { kind = "junction" }, { kind = "fixed", p = FL.P_ATM } },
    els = { { kind = "reg", u = 1, v = 2, pset = 5e5, len = 0.3 }, { kind = "cond", u = 2, v = 3, len = 4 } } }
  finish(gnet)
  local gs = FL.newState(gnet)
  local gr = FL.advance(gnet, gs, 1)
  check(gs.em[1] == "T" and near(gr.p[2], 5e5, 1), string.format("the regulator holds its outlet at 5.0 bar (%.3f bar) from a 200 bar bottle", gr.p[2] / 1e5))
  check(rel(gr.q[2], gnet.els[2].g * (5e5 - FL.P_ATM), 1e-6), string.format("…and passes what the line takes at that (%.4f kg/s O2)", gr.q[2]))
  local gs2 = copy(FL.newState(gnet))
  local gr2 = FL.advance(gnet, gs2, 30 * 86400)
  check(gs2.em[1] == "O" or gs2.em[1] == "X", string.format("as the bottles run down past 5 bar it opens wide (%s, %.2f bar left)", tostring(gs2.em[1]), a * gs2.x[1] / 1e5))
  local gs3 = FL.newState(gnet)
  for _ = 1, 30 do FL.advance(gnet, gs3, 86400) end
  check(rel(gs2.x[1], gs3.x[1], 1e-6), string.format("30 days in one step = thirty days of one-day steps, across the regulator's change (%.6f / %.6f kg)", gs2.x[1], gs3.x[1]))
end

-- ── electrolysis: the O2 Generator's water ──────────────────────────────────
do
  -- 2 H2O → 2 H2 + O2: per kg of O2, 1.126 kg of water in, 0.126 kg of H2 out
  local w, h = FL.electrolysis(1.0)
  check(near(w, 36.031 / 31.999, 1e-3) and near(h, 4.032 / 31.999, 1e-3), string.format("electrolysis: 1 kg O2 takes %.3f kg water and makes %.3f kg H2", w, h))
  -- a 2 m³ tank, a pump and the generator's 20 L cell, drained at its full O2 rate
  local o2 = 2.8e-5 * FL.ATM_M3.o2
  local r = FL.electrolysis(o2)
  local net = finish({ sub = "water", nodes = { liquid(30, 2000, 1.13), { kind = "junction" }, { kind = "junction" }, liquid(20, 20, 0.05, r) },
    els = { { kind = "cond", u = 1, v = 2, len = 1 }, { kind = "pump", u = 2, v = 3, q0 = 2, H0 = 6e5, len = 0.4, on = true }, { kind = "cond", u = 3, v = 4, len = 10 } } })
  local s = FL.newState(net)
  s.x[4] = 0
  local rep = FL.advance(net, s, 60)
  check(s.tm[4] == "F", string.format("the cell fills from the tank and stays full while the pump runs (%s, %.2f kg)", tostring(s.tm[4]), s.x[4]))
  local rep2 = FL.advance(net, s, 7 * 86400)
  check(s.x[1] == 0 and (s.tm[4] == "S" or s.tm[4] == "D" or s.x[4] < 20), string.format("a week on, the 30 kg in the tank are gone (%.2f kg, cell %s)", s.x[1], tostring(s.tm[4])))
  local rep3 = FL.advance(net, s, 3 * 86400)
  local lim = FL.limitedBy(net, s, rep3)
  check(s.x[4] == 0 and lim and lim:find("starved", 1, true) and lim:find("empty", 1, true), "then the cell runs dry and the generator is starved: " .. tostring(lim))
end

-- ── the pieces: a network from records, a riser up a storey ────────────────
local SC = {}
local TH = load_script("thermal.lua", env({}, SC)); SC.thermal = TH
local K = load_script("parts_kit.lua", env({}, SC)); SC.parts_kit = K
local PB = load_script("parts_base.lua", env({}, SC)); SC.parts_base = PB
local R = load_script("reactor.lua", env({}, SC)); SC.reactor = R
SC.fluids = FL
local defs = function(id) return PB.partInfo(id) end
local PI = math.pi
do
  -- a water tank, 2 m of pipe, a pump (turned to push away from the tank), a
  -- riser up a storey, and an O2 Generator upstairs on its water nozzle
  local function P(uid, id, x, y, z, yaw) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0 } end
  local bp = { P(1, "flTankWater.steel", 0, 0, 0), P(2, "flPipe2.steel", 0, 0, -2), P(3, "flPump.steel", 0, 0, -3.5, PI),
               P(4, "flRiser.steel", 0, 0, -4.5, PI), P(5, "o2gen.steel", -0.2, 2.4, -3.7) }
  local rec = { id = 3, b = "Home", x = 0, y = 600, z = 0, bp = bp }
  local B = FL.build(rec, defs, function(kind, p, d)
    if kind == "tank" then return { x = 1500 } end
    if kind == "consumer" then return { x = 0, cap = 20, r = 4.5e-5 } end
    return {}
  end)
  local wnet = nil
  for _, n in ipairs(B.nets) do if n.sub == "water" then wnet = n end end
  check(wnet and #wnet.open == 0, string.format("the pieces join port to port into one water network, no open end (%d networks, %d open)", #B.nets, wnet and #wnet.open or -1))
  local ent = B.byPort and B.byPort["5:water"]
  check(ent and ent.kind == "consumer" and ent.net == wnet, "the O2 Generator's water nozzle is its consumer; its H2 nozzle is apart")
  local st = FL.newState(wnet)
  local rep = FL.advance(wnet, st, 120)
  local ci = ent.node
  check(st.x[ci] > 19.9 and (st.tm[ci] == "F" or st.x[ci] >= 19.99), string.format("the pump lifts water 2.4 m up the riser into the cell (%.2f kg in 2 min)", st.x[ci]))
  -- the lift: with the pump off, nothing climbs the riser by itself
  local B2 = FL.build(rec, defs, function(kind, p, d)
    if kind == "tank" then return { x = 1500 } end
    if kind == "consumer" then return { x = 0, cap = 20, r = 0 } end
    if kind == "element" and d.fl and d.fl.kind == "pump" then return { on = false } end
    return {}
  end)
  local n2 = nil
  for _, n in ipairs(B2.nets) do if n.sub == "water" then n2 = n end end
  local s2 = FL.newState(n2)
  FL.advance(n2, s2, 600)
  local e2 = B2.byPort["5:water"]
  check(s2.x[e2.node] == 0, "pump off: nothing flows up a storey on its own")
  -- the tank upstairs feeds down, by gravity, through the riser (pump left out)
  local bp3 = { P(1, "flTankWater.steel", 0, 2.4, 0), P(2, "flPipe2.steel", 0, 2.4, -2), P(4, "flRiser.steel", 0, 0, -3.5, PI), P(6, "flPipe2.steel", 0, 0, -2), P(7, "flGauge.steel", 0, 0, -0.75) }
  local B3 = FL.build({ id = 4, b = "Home", x = 0, y = 600, z = 0, bp = bp3 }, defs, function(kind) if kind == "tank" then return { x = 1000 } end return {} end)
  local n3 = B3.nets[1]
  local s3 = FL.newState(n3)
  local r3 = FL.advance(n3, s3, 0)
  local gi = B3.byUid[7].el and n3.els[B3.byUid[7].el].u
  local pg = r3.p[gi] - n3.nodes[gi].zh
  -- static at the gauge = 1 atm + ρ g (tank's surface over it): 2.4 m storey + 0.884 m of water − 0.6 m port height
  local want = FL.P_ATM + 998 * 9.81 * (2.4 + 1000 / (998 * 1.131) - 0.6)
  check(rel(pg, want, 1e-6) and #n3.open == 1, string.format("a tank a storey up: the dead end below reads 1 atm + ρgh (%.3f bar, the formula %.3f)", pg / 1e5, want / 1e5))
  -- two substances in one network: refused, named
  local bp4 = { P(1, "flTankWater.steel", 0, 0, 0), P(2, "flPipe2.steel", 0, 0, -2), P(3, "flTankFuel.steel", 0, 0, -4, PI) }
  local B4 = FL.build({ id = 5, b = "Home", x = 0, y = 600, z = 0, bp = bp4 }, defs, function(kind) if kind == "tank" then return { x = 1000 } end return {} end)
  local n4 = B4.nets[1]
  local s4 = FL.newState(n4)
  local r4 = FL.advance(n4, s4, 600)
  check(n4.mixed and FL.limitedBy(n4, s4, r4):find("fuel and water", 1, true) and s4.x[B4.byUid[1].node] == 1000, "water and fuel piped together: nothing flows and it says so: " .. tostring(FL.limitedBy(n4, s4, r4)))
  -- the reactor's coolant pipes are never the fluid network's (DN100 vs DN25)
  local KS = load_script("kit_snap.lua", env({}, SC))
  check(KS.boreOf(defs("pipe2.steel"), defs("pipe2.steel").ports[1]) == "DN100" and KS.boreOf(defs("flPipe2.steel"), defs("flPipe2.steel").ports[1]) == "DN25"
        and KS.boreOf(defs("pressuriser.steel"), defs("pressuriser.steel").ports[2]) == "DN25", "the port snap joins bore to bore: DN100 coolant, DN25 process (the pressuriser's makeup nozzle is DN25)")
end

-- ── LOSS OF COOLANT: a guillotine break in the primary ─────────────────────
do
  local F = dofile("solar/tests/lib/reactor_fixture.lua")
  local CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
  local rec, U, cells = F.plant(CORE, {})
  local L = R.layout(rec, defs)
  local pl = L.plants[1]
  local ch = F.fuel(R, cells, "fuelRod", 8)
  local ENV = { tamb = 288, atm = 1 }
  local M = R.model(pl, ch, ENV, {})
  local S = R.newState(288)
  check(M.Mw > 800 and M.Mw < 3000 and #M.why == 0, string.format("the primary's coolant inventory from its parts: %.0f kg (pipes, plenum, channels, steam generator, pressuriser)", M.Mw))
  R.startUp(S, 1.0)
  local t = 0
  for _ = 1, 1800 do local rep = R.advance(S, M, 1, t); t = t + 1 - rep.left end
  for _ = 1, 12 do local rep = R.advance(S, M, 3600, t); t = t + 3600 - rep.left end
  local o0 = R.derive(M, S, S.y, nil, {})
  check(o0.P > 0.9 and not S.scram, string.format("at power: %.0f %%", o0.P * 100))
  -- the break: both ends of a 2 m coolant pipe
  local MB = R.model(pl, ch, ENV, { brkA = 2 * R.PIPE_A })
  check(MB.tsat < 380 and MB.broken, "the break loses the pressuriser: the primary now boils at 373 K")
  local S2 = { y = {} }
  for k, v in pairs(S) do S2[k] = v end
  S2.y = {}
  for i = 1, R.NY do S2.y[i] = S.y[i] end
  S2.ev = {}
  local trip_t, inv5, tu
  local t2 = t
  for k = 1, 600 do
    local rep = R.advance(S2, MB, 0.5, t2)
    t2 = t2 + 0.5 - rep.left
    for _, e in ipairs(rep.events) do if e.kind == "trip" and not trip_t then trip_t = e.t - t end end
    if k == 10 then inv5 = S2.y[R.IDX.inv] end
  end
  local o2 = R.derive(MB, S2, S2.y, nil, {})
  check(trip_t and trip_t < 2 and S2.scram, string.format("LOCA: the plant trips at once (+%.2f s, %s)", trip_t or -1, tostring(S2.cause)))
  check(inv5 and inv5 < 0.85 and inv5 > 0.3 and o2.inv < 0.2, string.format("…and blows down to the break's level: inventory %.0f %% at 5 s, %.0f %% at 5 min (the core stands above the pipes: uncovered)", 100 * (inv5 or 1), 100 * o2.inv))
  -- with no makeup the core uncovers on its decay heat and is damaged
  local t3 = t2
  local tf_max, tf_t = 0, 0
  for _ = 1, 48 do
    local rep = R.advance(S2, MB, 600, t3)
    t3 = t3 + 600 - rep.left
    local o = R.derive(MB, S2, S2.y, nil, {})
    if o.Tf > tf_max then tf_max, tf_t = o.Tf, (t3 - t) / 60 end
  end
  local o4 = R.derive(MB, S2, S2.y, nil, {})
  -- (a 320 kW core after 12 h at power: its decay heat, uncovered, is shed by
  -- the steam and its own glow just under the cladding's 1,300 K)
  check(o4.inv < 0.16 and tf_max > 1000, string.format("no makeup: the core stays uncovered and the fuel climbs to %.0f K on its decay heat (at +%.0f min)", tf_max, tf_t))
  -- a SMALL break (5 % of the bore) with a low-head pump refilling the
  -- depressurised loop (LPSI): 2 kg/s keeps ahead of what it loses
  local S3 = { y = {} }
  for k, v in pairs(S) do S3[k] = v end
  S3.y = {}
  for i = 1, R.NY do S3.y[i] = S.y[i] end
  S3.ev = {}
  local MK = R.model(pl, ch, ENV, { brkA = 2 * 0.05 * R.PIPE_A, mk = 0 })
  local t4 = t
  for _ = 1, 120 do local rep = R.advance(S3, MK, 0.5, t4); t4 = t4 + 0.5 - rep.left end
  -- (the break has drained the loop to its level; a process pump's 2 kg/s
  -- through the pressuriser keeps up with the boil-off and the spill)
  MK.mk = 2.0
  for _ = 1, 48 do local rep = R.advance(S3, MK, 600, t4); t4 = t4 + 600 - rep.left end
  local o3 = R.derive(MK, S3, S3.y, nil, {})
  check(MK.broken and S3.y[R.IDX.dmg] < 0.01 and o3.inv > 0.6, string.format("a 5 %% break with 2 kg/s of makeup: depressurised, but the core stays covered (inventory %.0f %%, damage %.3f)", 100 * o3.inv, S3.y[R.IDX.dmg]))
  -- the fluid network's side: a 6 bar pump stalls against the pressurised
  -- primary, the charging pump gets in; after the break the 6 bar pump does
  local function into(pri_p, q0, H0)
    local net = finish({ sub = "water", nodes = { liquid(1500, 2000, 1.13), { kind = "junction" }, { kind = "junction" }, { kind = "tank", a = 0, c = pri_p, cap = 1700, x0 = 1000, r = 0 } },
      els = { { kind = "cond", u = 1, v = 2, len = 0.3 }, { kind = "pump", u = 2, v = 3, q0 = q0, H0 = H0, len = 0.4, on = true }, { kind = "check", u = 3, v = 4, len = 4 } } })
    local s = FL.newState(net)
    local r = FL.advance(net, s, 1)
    return r.q[2], s.em[2]
  end
  local qa, ma = into(15.5e6, 2.0, 6e5)
  local qb = into(15.5e6, 0.5, 18e6)
  local qc = into(1.1e5, 2.0, 6e5)
  check(qa == 0 and ma == "stall" and qb > 0.05 and qb < 0.5 and qc > 1.5, string.format("makeup: a process pump stalls against 15.5 MPa, the charging pump gives %.2f kg/s; after the break the process pump gives %.2f", qb, qc))
end

if #failures > 0 then
  print("FAIL smoke_fluids: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_fluids: %d checks passed", passed))
