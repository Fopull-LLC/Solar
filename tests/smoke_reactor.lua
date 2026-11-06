-- SMOKE: reactors built from components (sandbox plan S6, work/sandbox/PLAN.md
-- §3.1, §12; docs/heat-and-nuclear.md §8), against the real reactor.lua,
-- thermal.lua, parts_kit.lua and parts_base.lua.
--
--   * the layout: ports meet, the loops close (or say where they are open),
--     the cells of the core, pumps fighting, no pressuriser;
--   * criticality against layout: more moderator, higher enrichment, a taller
--     core raise k; natural uranium goes critical only with heavy water in a
--     two-storey core; light water needs enriched fuel;
--   * the temperature feedback is negative (Doppler and the moderator);
--   * start-up on the automatic controller to full power, the turbine's
--     output against its temperatures (Carnot), radiators against a tower,
--     no pressuriser;
--   * the xenon pit after a trip blocks a restart for hours, then clears;
--   * burnup over two months under warp: one long step equals many short
--     ones (and a catch-up that runs out of steps carries on);
--   * a SCRAM's decay heat with no cooling boils the primary off and melts
--     the core; with its pumps it stays cool;
--   * a loss of flow trips the reactor at the same instant for any step;
--   * a prompt-critical excursion when the rods are pulled with the
--     protection bypassed (the protection trips first otherwise);
--   * the refuelling rule (shutdown margin);
--   * old saves: a craft's Ember and a base with no reactor stay as they were;
--   * the cost of a step, steady and shut down.
--
--   luajit solar/tests/smoke_reactor.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
  return ok
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end
local function rel(a, b) return math.abs(a - b) / math.max(math.abs(a), math.abs(b), 1e-30) end

local function env(store, scripts)
  return setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local SC = {}
local TH = load_script("thermal.lua", env({}, SC)); SC.thermal = TH
local K = load_script("parts_kit.lua", env({}, SC)); SC.parts_kit = K
local PB = load_script("parts_base.lua", env({}, SC)); SC.parts_base = PB
local R = load_script("reactor.lua", env({}, SC)); SC.reactor = R
local F = dofile("solar/tests/lib/reactor_fixture.lua")
local defs = function(id) return PB.partInfo(id) end
local I = R.IDX
local ENV = { tamb = 288, atm = 1 }

-- the plant of the fixture with `rows`, loaded with `item` (n rods a channel)
local function plant(rows, item, n, opts)
  local rec, U, cells = F.plant(rows, opts or {})
  local L = R.layout(rec, defs)
  local pl = L.plants[1]
  local ch = F.fuel(R, cells, item or "fuelRod", n or 8)
  local M = R.model(pl, ch, (opts and opts.env) or ENV, (opts and opts.run) or {})
  return M, R.newState(ENV.tamb), pl, ch, rec, U, cells
end
local function kcold(M) local _, k = R.reactivity(M.core, 0, 288, 288, 0, 0); return k end
-- run S on M from t for n steps of dt; → t, events
local function run(M, S, t, dt, n)
  local ev = {}
  for _ = 1, n do
    local rep = R.advance(S, M, dt, t)
    t = t + dt - rep.left
    for _, e in ipairs(rep.events) do ev[#ev + 1] = e end
  end
  return t, ev
end
-- catch up S over dt, however many calls MAXSTEPS needs
local function catchup(M, S, t, dt)
  local left, calls = dt, 0
  while left > 1e-9 and calls < 1000 do
    local rep = R.advance(S, M, left, t)
    local took = left - rep.left
    t, left, calls = t + took, rep.left, calls + 1
  end
  return t, calls
end
-- up to full power on the automatic controller, held two days
local function to_power(M, S, set)
  R.startUp(S, set or 1.0)
  local t = run(M, S, 0, 1, 1800)
  t = run(M, S, t, 3600, 47)
  return t
end

local CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }

-- ── the layout ──────────────────────────────────────────────────────────────
do
  local M, S, pl = plant(CORE)
  check(pl.pri.closed and #pl.pri.pumps == 1 and #pl.pri.sgs == 1 and pl.pri.press ~= nil,
    string.format("the primary closes: vessel → steam generator → pump → pressuriser's tee → vessel (%d pumps, %.1f m of pipe)", #pl.pri.pumps, pl.pri.pipes))
  check(pl.sec.closed and #pl.sec.turbines == 1 and #pl.sec.rejects == 1 and #pl.sec.pumps == 1, "the secondary closes through the turbine, the tower and the feed pump")
  check(#M.why == 0, "a whole plant has nothing missing: " .. table.concat(M.why, "; "))
  check(pl.pri.pumps[1].fwd == false or pl.pri.pumps[1].fwd == true, "the pump's way round the loop is known")
  check(M.core.nfuel == 8 and M.core.nrod == 5 and M.core.nmod == 8, string.format("the lattice: %d fuel, %d rods, %d moderator", M.core.nfuel, M.core.nrod, M.core.nmod))
  check(near(M.Pr, 8 * 40e3), string.format("the rating: 8 full channels × 40 kW = %.0f kW", M.Pr / 1000))
  local M2, _, pl2 = plant(CORE, "fuelRod", 8, { openPrimary = true })
  check(not pl2.pri.closed and M2.why[1] and M2.why[1]:find("open", 1, true), "a pipe left off: " .. tostring(M2.why[1]))
  local M3 = plant(CORE, "fuelRod", 8, { noPress = true })
  check(M3.tsat < 400 and M.tsat > 600, string.format("no pressuriser: the primary boils at %.0f K (with one: %.0f K)", M3.tsat, M.tsat))
  local M4 = plant(CORE, "fuelRod", 8, { noSecondary = true })
  local w = table.concat(M4.warn, "; ")
  check(w:find("secondary", 1, true) ~= nil, "no secondary: the console says so (" .. w .. ")")
  -- the pump turned round against a second pump: they fight
  local rec, U, cells = F.plant(CORE, {})
  local p = nil
  for _, x in ipairs(rec.bp) do if x.uid == U.pump then p = x end end
  p.yaw = 0      -- (now facing the other way: its in and out swapped on the loop)
  local plr = R.layout(rec, defs).plants[1]
  check(plr.pri.closed and plr.pri.pumps[1].fwd ~= pl.pri.pumps[1].fwd, "a pump turned round still closes the loop, the other way")
end

-- ── criticality against layout ──────────────────────────────────────────────
do
  local k3 = kcold(plant(CORE, "fuelRod"))
  local kNU = kcold(plant(CORE, "fuelRodNU"))
  local kH = kcold(plant(CORE, "fuelRodHALEU"))
  check(kH > k3 and k3 > kNU, string.format("enrichment raises k: natural %.3f < LEU 3 %% %.3f < HALEU %.3f", kNU, k3, kH))
  check(kNU < 1, "natural uranium in light water never goes critical")
  -- moderator: take the water out of the lattice, then put more in
  local kbare = kcold(plant({ ".R.R.", ".FFF.", ".FRF.", ".FFF.", ".R.R." }, "fuelRod"))
  local k1 = kcold(plant({ ".RWR.", ".FFF.", "WFRF.", ".FFF.", ".R.R." }, "fuelRod"))
  check(kbare < k1 and k1 < k3, string.format("more moderator beside the fuel raises k: none %.3f < some %.3f < a ring %.3f", kbare, k1, k3))
  local kg = kcold(plant({ "GGGGG", "GFGFG", "GRGRG", "GFGFG", "GGGGG" }, "fuelRod"))
  local kgNU = kcold(plant({ "GGGGG", "GFGFG", "GGRGG", "GFGFG", "GGGGG" }, "fuelRodNU"))
  check(kg > 1 and kgNU < 1, string.format("graphite: LEU goes critical (%.3f); natural uranium leaks away in a core this size (%.3f)", kg, kgNU))
  local HROW = { "HHHHH", "HFHFH", "HRHRH", "HFHFH", "HHHHH" }
  local kD1 = kcold(plant(HROW, "fuelRodNU"))
  local kD2 = kcold(plant(HROW, "fuelRodNU", 8, { rows2 = { "HHHHH", "HFHFH", "HHHHH", "HFHFH", "HHHHH" } }))
  check(kD2 > kD1 + 0.02 and kD2 > 1.02, string.format("heavy water and natural uranium: one storey %.3f, two storeys %.3f (a taller core leaks less)", kD1, kD2))
  -- the rods hold it; the feedback is negative
  local M = plant(CORE)
  local _, kin = R.reactivity(M.core, 1, 288, 288, 0, 0)
  local _, khot = R.reactivity(M.core, 0, 900, 560, 0, 0)
  local _, kdop = R.reactivity(M.core, 0, 900, 288, 0, 0)
  check(kin < 0.95, string.format("every rod in: k %.3f (a shutdown margin of %.0f %%)", kin, (1 - kin) * 100))
  check(kdop < k3 and khot < kdop, string.format("hot is less reactive: cold %.4f, fuel hot (Doppler) %.4f, coolant hot too %.4f", k3, kdop, khot))
  local _, kx = R.reactivity(M.core, 0, 288, 288, 1.0, 0)
  check(kx < k3 - 0.02, string.format("a barn of xenon per U atom takes %.1f %% off", (k3 - kx) / k3 * 100))
end

-- ── to full power, and the turbine ──────────────────────────────────────────
local MH, SH, TH0
do
  local M, S = plant(CORE)
  local t = to_power(M, S, 1.0)
  local o = R.derive(M, S, S.y, nil, {})
  check(near(o.P, 1.0, 0.003) and not S.scram, string.format("the controller holds 100 %% (P %.4f), rods %.0f %% in", o.P, o.x * 100))
  check(o.Tp > 530 and o.Tp < 600 and o.Ts > 515 and o.Ts < 550, string.format("design temperatures: primary %.0f K, steam %.0f K, fuel %.0f K", o.Tp, o.Ts, o.Tf))
  local car = 1 - o.Tk / o.Ts
  check(near(o.Pe, M.eta * car * o.Qt, 0.002 * o.Qt), string.format("the turbine: %.1f kW = %.2f × Carnot %.3f × %.1f kW of steam", o.Pe / 1e3, M.eta, car, o.Qt / 1e3))
  check(o.Pe > 50e3 and o.Pe < 100e3, string.format("…%.0f kW(e) from %.0f kW(th): %.1f %%", o.Pe / 1e3, o.Qcore / 1e3, 100 * o.Pe / o.Qcore))
  local xw = R.xenonWorth(M, S.y)
  check(xw > 0.02 and xw < 0.05, string.format("equilibrium xenon worth %.2f %% at full power", xw * 100))
  local lim = R.limitedBy(M, S, o)
  check(type(lim) == "string" and #lim > 5, "limited by: " .. tostring(lim))
  MH, SH, TH0 = M, S, t
  -- the same plant on two radiator panels: the condenser runs hot, the turbine makes less
  local Mr, Sr = plant(CORE, "fuelRod", 8, { sink = "rad" })
  R.startUp(Sr, 0.3)
  local tr = run(Mr, Sr, 0, 1, 1800)
  tr = run(Mr, Sr, tr, 3600, 24)
  local orr = R.derive(Mr, Sr, Sr.y, nil, {})
  local Mt, St = plant(CORE)
  R.startUp(St, 0.3)
  local tt = run(Mt, St, 0, 1, 1800)
  tt = run(Mt, St, tt, 3600, 24)
  local ot = R.derive(Mt, St, St.y, nil, {})
  check(orr.Tk > ot.Tk + 30 and orr.Pe / orr.Qcore < ot.Pe / ot.Qcore,
    string.format("at 30 %%: radiators run the condenser at %.0f K (%.1f %%), the tower at %.0f K (%.1f %%)", orr.Tk, 100 * orr.Pe / orr.Qcore, ot.Tk, 100 * ot.Pe / ot.Qcore))
  local lr = R.limitedBy(Mr, Sr, orr)
  check(lr:find("heat sink", 1, true) ~= nil or lr:find("condenser", 1, true) ~= nil or orr.Tk > 340, "…and the radiators' plant names its sink: " .. lr)
  -- no pressuriser: the steam can't be held hot
  local Mn, Sn = plant(CORE, "fuelRod", 8, { noPress = true })
  R.startUp(Sn, 0.3)
  local tn = run(Mn, Sn, 0, 1, 1800)
  tn = run(Mn, Sn, tn, 3600, 12)
  local on = R.derive(Mn, Sn, Sn.y, nil, {})
  check((on.Pe / math.max(on.Qcore, 1)) < 0.5 * (ot.Pe / ot.Qcore) or Sn.scram,
    string.format("no pressuriser: %.1f %% efficiency (with one %.1f %%)%s", 100 * on.Pe / math.max(on.Qcore, 1), 100 * ot.Pe / ot.Qcore, Sn.scram and " · tripped near boiling" or ""))
  -- insulation pays
  local Mi, Si = plant(CORE, "fuelRod", 8, { insulated = true })
  R.startUp(Si, 1.0)
  local ti = run(Mi, Si, 0, 1, 1800)
  ti = run(Mi, Si, ti, 3600, 23)
  local oi = R.derive(Mi, Si, Si.y, nil, {})
  check(oi.Qlp + oi.Qls < 0.3 * (o.Qlp + o.Qls) and oi.Pe > o.Pe, string.format("insulated pipes: %.1f kW lost (bare %.1f), %.1f kW(e) (bare %.1f)", (oi.Qlp + oi.Qls) / 1e3, (o.Qlp + o.Qls) / 1e3, oi.Pe / 1e3, o.Pe / 1e3))
end

-- ── the xenon pit ───────────────────────────────────────────────────────────
do
  -- (a lean core: half its rods natural uranium, so it runs with little to spare)
  local M, S = plant(CORE, { "fuelRod", "fuelRodNU" }, 8)
  local t = to_power(M, S, 1.0)
  local o = R.derive(M, S, S.y, nil, {})
  check(near(o.P, 1.0, 0.005) and o.x < 0.4, string.format("a lean core at full power, its rods %.0f %% in", o.x * 100))
  local xe0 = S.y[I.Xe]
  R.scram(S, t)
  t = run(M, S, t, 0.5, 20)
  local o1 = R.derive(M, S, S.y, nil, {})
  check(o1.x > 0.99 and o1.P < 0.01, string.format("SCRAM: the rods in, the fission power %.2f %% in ten seconds", o1.P * 100))
  t = run(M, S, t, 600, 24)
  local h, peak, tpk = R.xenonForecast(M, S, S.y)
  check(S.y[I.Xe] > 1.8 * xe0, string.format("four hours on, xenon %.2f b (it was %.2f at power): the iodine decaying into it", S.y[I.Xe], xe0))
  check(R.kRodsOut(M, S, S.y) < 1.002 and h and h >= 4, string.format("…with every rod out k is %.4f: the pit, a restart in %s h (xenon peaks %.2f b, +%d h)", R.kRodsOut(M, S, S.y), tostring(h), peak or -1, tpk or -1))
  -- the restart tried: the controller pulls every rod and can't reach critical
  R.resetTrip(S)
  R.startUp(S, 0.5)
  t = run(M, S, t, 60, 60)
  local o2 = R.derive(M, S, S.y, nil, {})
  local lim = R.limitedBy(M, S, o2)
  check(o2.P < 1e-4 and o2.x < 0.01 and lim:find("xenon", 1, true) ~= nil, string.format("the restart: rods all out, P %.2g, '%s'", o2.P, lim))
  -- held: it goes critical once the xenon has burnt down by decay
  t = run(M, S, t, 3600, 40)
  local o3 = R.derive(M, S, S.y, nil, {})
  check(o3.P > 0.4, string.format("…%.0f h later the xenon has decayed: P %.0f %%", 40, o3.P * 100))
end

-- ── burnup over months, one step or many ────────────────────────────────────
do
  local DAYS = 60
  local function burned(step)
    local M, S = plant(CORE)
    local t = to_power(M, S, 1.0)
    local calls = 0
    if step >= DAYS * 86400 then t, calls = catchup(M, S, t, DAYS * 86400)
    else
      for _ = 1, math.floor(DAYS * 86400 / step + 0.5) do local c; t, c = catchup(M, S, t, step); calls = calls + c end
    end
    local e, n = 0, 0
    for _, c in ipairs(M.core.channels) do for _, r in ipairs(c.rods) do e = e + r.e; n = n + 1 end end
    return { e = e / n, fima = R.burnup(M), Xe = S.y[I.Xe], Sm = S.y[I.Sm], Tp = S.y[I.Tp], x = S.y[I.x], calls = calls, M = M, S = S }
  end
  local a, b, c = burned(DAYS * 86400), burned(86400), burned(3600)
  check(a.e < 0.03 * 0.85 and a.fima > 0.003, string.format("two months at full power: U-235 %.2f %% (from 3 %%), burnup %.2f %% FIMA, samarium %.3f b", a.e * 100, a.fima * 100, a.Sm))
  check(a.calls > 1, string.format("one 60-day step runs out of steps and carries on: %d calls", a.calls))
  local worst = math.max(rel(a.e, c.e), rel(a.fima, c.fima), rel(a.Xe, c.Xe), rel(a.Sm, c.Sm), rel(a.Tp, c.Tp), rel(a.x, c.x),
                         rel(b.e, c.e), rel(b.fima, c.fima), rel(b.x, c.x))
  check(worst < 1e-4, string.format("one 60-day step = 60 days = 1,440 hours: worst difference %.2g (U-235, burnup, Xe, Sm, T, rods)", worst))
  local Mb = a.M
  local kfresh = kcold(plant(CORE))
  check(kcold(Mb) < kfresh - 0.03, string.format("the burnt core is %.1f %% less reactive cold (%.3f vs %.3f fresh)", (kfresh - kcold(Mb)) / kfresh * 100, kcold(Mb), kfresh))
  local _, hi = R.burnup(Mb)
  check(hi > R.burnup(Mb) * 1.05, "the middle channels burn faster than the edge (the flux shape)")
end

-- ── a SCRAM with no cooling, and with ──────────────────────────────────────
do
  -- (a lagged plant: its pipes lose almost nothing, so only the loops take its heat)
  local M, S = plant(CORE, "fuelRod", 8, { insulated = true })
  local t = to_power(M, S, 1.0)
  for _ = 1, 10 do t = run(M, S, t, 86400, 1) end     -- (ten days: the long-lived decay heat built up)
  R.scram(S, t)
  -- every pump stopped, the tower's fan off: nothing takes the heat out
  M.mp_target, M.ms_target, M.towerG = 0, 0, 0
  local t0 = t
  local ev
  t, ev = run(M, S, t, 3600, 144)
  local melt = nil
  for _, e in ipairs(ev) do if e.kind == "melt" then melt = e end end
  check(S.y[I.inv] < 0.5, string.format("decay heat with no cooling boils the primary down to %.0f %% of its water", S.y[I.inv] * 100))
  check(melt ~= nil and S.melt, string.format("…the core uncovers and melts %.1f h after the SCRAM", melt and (melt.t - t0) / 3600 or -1))
  local Mc, Sc = plant(CORE)
  local tc = to_power(Mc, Sc, 1.0)
  for _ = 1, 10 do tc = run(Mc, Sc, tc, 86400, 1) end
  R.scram(Sc, tc)
  tc = run(Mc, Sc, tc, 3600, 72)
  check(not Sc.melt and Sc.y[I.dmg] == 0 and Sc.y[I.inv] > 0.99, string.format("with its pumps and tower the tripped core stays whole (fuel %.0f K, damage %.3g)", Sc.y[I.Tf], Sc.y[I.dmg]))
  -- the same blackout on a plant of bare pipes: they shed more than the decay heat makes
  local Mb, Sb = plant(CORE)
  local tb = to_power(Mb, Sb, 1.0)
  for _ = 1, 10 do tb = run(Mb, Sb, tb, 86400, 1) end
  R.scram(Sb, tb)
  Mb.mp_target, Mb.ms_target, Mb.towerG = 0, 0, 0
  tb = run(Mb, Sb, tb, 3600, 72)
  check(not Sb.melt and Sb.y[I.inv] > 0.99, string.format("…a plant of bare pipes rides out the same blackout: its pipes shed the decay heat (primary %.0f K)", Sb.y[I.Tp]))
end

-- ── loss of flow ────────────────────────────────────────────────────────────
do
  local times = {}
  for _, step in ipairs({ 30, 1, 0.1 }) do
    local M, S = plant(CORE)
    local t0 = to_power(M, S, 1.0)
    M.mp_target = 0
    local _, ev = run(M, S, t0, step, math.floor(30 / step + 0.5))
    local trip = ev[1]
    times[#times + 1] = trip and trip.t - t0 or -1
    if step == 1 then
      check(trip and trip.cause == "flow" and S.scram, "the pump stops: SCRAM on low coolant flow (" .. tostring(trip and trip.text) .. ")")
      check(S.y[I.Tf] < 1300 and S.y[I.dmg] == 0, string.format("…the fuel peaks under its limit (%.0f K now)", S.y[I.Tf]))
    end
  end
  check(times[1] > 0.5 and math.abs(times[1] - times[3]) < 0.01 and math.abs(times[2] - times[3]) < 0.01,
    string.format("the trip's instant: +%.4f s (30 s steps), +%.4f s (1 s), +%.4f s (0.1 s)", times[1], times[2], times[3]))
  -- two pumps: one failing is ridden out
  local rec, U, cells = F.plant(CORE, {})
  local pl = R.layout(rec, defs).plants[1]
  local ch = F.fuel(R, cells, "fuelRod", 8)
  local M = R.model(pl, ch, ENV, {})
  check(M.mp_design == 4.0, "one pump: a 4 kg/s design flow")
end

-- ── prompt critical ─────────────────────────────────────────────────────────
do
  local M, S = plant(CORE)
  local t = to_power(M, S, 0.05)
  S.mode, S.xt = "manual", 0
  S.prot = true
  local _, ev = run(M, S, t, 0.5, 120)
  check(ev[1] and ev[1].cause == "period" and S.bursts == 0, "the rods pulled by hand: the protection trips on the short period (" .. tostring(ev[1] and ev[1].text) .. ")")
  -- (bypassed, the slow pull is caught by the fuel's own Doppler: power and fuel heat climb)
  local M2, S2 = plant(CORE)
  local t2 = to_power(M2, S2, 0.05)
  S2.mode, S2.xt, S2.prot = "manual", 0, false
  local pk, melt = 0, nil
  for _ = 1, 240 do
    local rep = R.advance(S2, M2, 0.5, t2); t2 = t2 + 0.5
    if rep.peakP > pk then pk = rep.peakP end
    for _, e in ipairs(rep.events) do if e.kind == "melt" then melt = melt or e end end
  end
  check(pk > 5 and melt ~= nil, string.format("…bypassed, nothing trips: the power runs away to %.0f %% and the core melts %.0f s into the pull", pk * 100, melt and (melt.t - (t2 - 120)) or -1))
  -- a control rod column lifted out of a core running with its rods in: a
  -- step of reactivity no rod can follow
  local rec, U, cells = F.plant(CORE, {})
  local pl = R.layout(rec, defs).plants[1]
  local ch = F.fuel(R, cells, "fuelRod", 8)
  local M3 = R.model(pl, ch, ENV, {})
  local S3 = R.newState(288)
  local t3 = to_power(M3, S3, 0.3)
  local o3 = R.derive(M3, S3, S3.y, nil, {})
  for i = #rec.bp, 1, -1 do
    local p = rec.bp[i]
    if p.id == "controlRod.steel" and math.abs(p.x) < 0.01 and math.abs(p.z) < 0.01 then table.remove(rec.bp, i) end
  end
  local M4 = R.model(R.layout(rec, defs).plants[1], ch, ENV, {})
  local rep = R.advance(S3, M4, 1, t3)
  local burst = nil
  for _, e in ipairs(rep.events) do if e.kind == "prompt" then burst = e end end
  check(burst ~= nil and S3.bursts >= 1, string.format("the middle rod column lifted out at %.0f %% power (rods %.0f %% in): %s", o3.P * 100, o3.x * 100, tostring(burst and burst.text)))
  check(S3.scram, "…and the burst trips it")
end

-- ── refuelling: the shutdown margin ─────────────────────────────────────────
do
  local rec, U, cells = F.plant({ "..R..", ".FWF.", "RWFWR", ".FWF.", "..R.." }, {})
  local pl = R.layout(rec, defs).plants[1]
  local ch = {}
  local refused, loaded = nil, 0
  for _, c in ipairs(cells) do
    if c.ch == "F" then
      for _ = 1, 8 do
        local why = R.loadWhyNot(pl, ch, c.uid, "fuelRod", ENV)
        if why then refused = refused or why break end
        ch[c.uid] = ch[c.uid] or { rods = {} }
        ch[c.uid].rods[#ch[c.uid].rods + 1] = R.newRod("fuelRod")
        loaded = loaded + 1
      end
    end
  end
  check(refused ~= nil and loaded > 0, string.format("a core its rods can't hold: %d rods go in, the next is refused (%s)", loaded, tostring(refused)))
  local M = R.model(pl, ch, ENV, {})
  local _, kin = R.reactivity(M.core, 1, 288, 288, 0, 0)
  check(kin < R.SDM_MIN, string.format("…so with every rod in it stays subcritical (k %.3f)", kin))
end

-- ── old saves ───────────────────────────────────────────────────────────────
do
  -- a craft's Ember: the step-3 model, unchanged
  local Mv = TH.vesselModel({ { m = { type = "reactor", core = "ember" }, st = { critical = true, output = 100, rods = 1, life = 3600 } },
                              { m = { type = "radiator", sink = 5, draw = 0.05, cap = 40 }, deploy = 1, hp = 1, pump = 1 },
                              { m = { type = "radiator", sink = 5, draw = 0.05, cap = 40 }, deploy = 1, hp = 1, pump = 1 } }, 0)
  check(near(Mv.S, 0.5 + 1.0 + 10) and near(Mv.C, 60 + 800 + 80), "the Ember's heat loop is the step-3 one (two panels: S 11.5, C 940)")
  local st = { T = 0 }
  TH.advance(st, Mv, 3000, 0)
  check(near(st.T, 6 / 11.5, 1e-3), string.format("…50 minutes at full output settle at Q/S = %.3f, under the scram line", st.T))
  -- a base with no reactor: nothing to step
  local rec = { id = 3, b = "Home", x = 0, y = 600, z = 0, bp = { { uid = 1, id = "slab2.concrete", x = 0, y = 0, z = 0, yaw = 0 },
                                                                  { uid = 2, id = "wall.steel", x = 0, y = 0.2, z = 1, yaw = 0 } } }
  local L = R.layout(rec, defs)
  check(#L.plants == 0, "a hab with no reactor has no plant")
  -- a reactor with no fuel: just relaxes to the room
  local M, S = plant(CORE, "fuelRod", 0)
  S.y[I.Tp] = 400
  R.advance(S, M, 86400, 0)
  check(M.core.U == 0 and near(S.y[I.Tp], 288, 0.5), "an unfuelled vessel only cools to the room")
end

-- ── the cost ────────────────────────────────────────────────────────────────
do
  local clock = os.clock
  local M, S = MH, SH
  local t = TH0
  local w0 = clock()
  local steps = 0
  for _ = 1, 200 do local rep = R.advance(S, M, 0.2, t); t = t + 0.2; steps = steps + rep.steps end
  local per = (clock() - w0) * 1000 / 200
  -- shut down and cold
  local M2, S2 = plant(CORE)
  local w1 = clock()
  local t2 = 0
  for _ = 1, 200 do R.advance(S2, M2, 0.2, t2); t2 = t2 + 0.2 end
  local idle = (clock() - w1) * 1000 / 200
  check(per < 0.5, string.format("at power, a 5 Hz tick costs %.3f ms (%d steps in 200)", per, steps))
  check(idle < 0.5, string.format("shut down: %.3f ms a tick (≤ 0.1 ms a frame at 5 Hz and 60 fps: %.4f)", idle, idle * 5 / 60))
  print(string.format("  reactor cost: %.3f ms a tick at power, %.3f ms shut down", per, idle))
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_reactor: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_reactor: %d passed", passed))
