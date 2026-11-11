-- SMOKE: CABIN AIR on craft (scenarios2 PLAN §2 G1; scripts/cabin_air.lua),
-- against the real room_air chemistry, crew.lua's seats, damage.lua's holes,
-- scenario.lua's kinds, and a stub craft shaped like vessel_controller's
-- published API (aboardRecs, dockPorts, partsGen, partHp, partSt, seatsOf,
-- memberSlot, lostParts):
--
--   * the graph: a Pod Mk1 on a Crew Cabin is ONE module (9 m³, two side
--     hatches); a tank between two pods makes two modules and no door; an open
--     seat is no cabin; two craft docked port to port are two modules and one
--     docking hatch, sealed until opened; a port on a cabin with nothing mated
--     opens to the outside; a lost cabin part leaves a breach;
--   * leaks: none at hp 0.5, damage.holeArea at 0.45 / 0.3 / 0.05 (the same
--     rule in both scripts), a 1 cm² class hole drains a pod as e^(-t/τ) with
--     τ = V / (LEAK_K A); a breach shuts the regulator (the reserve is kept);
--   * hatches: open to vacuum vents the module in seconds (and says so);
--     shut (the valve) bleeds it at τ = V / EQV_G; sealed holds;
--   * docking: a module at 1 atm and one at vacuum, the docking hatch shut
--     (valve) meet in the middle; open, they are one network and their
--     O2 / CO2 mix;
--   * breathing: one crew in a pod with no charge (no scrubber) reaches
--     CO2 0.02 atm at 0.04 / MAKE s and the air is unbreathable; with charge
--     the scrubber holds it at 0; one 3,600 s step lands where 3,600 1 s
--     steps do;
--   * the scene half on a stub engine: fresh air on a new craft, the avatar's
--     module breathable ("cabin"), the suit refill takes O2 from it, a
--     puncture vents it and the helmet may not come off, the regulator
--     repressurises from the reserve once patched, the setting off stands it
--     all down, the state rides the parts' `st`;
--   * scenarios: the `cabin` goal and the `craft_pressure` fail evaluate and
--     validate.
--
--   luajit solar/tests/smoke_cabin_air.lua   (from the Floptle checkout)

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
      delete = function(k) store[k] = nil end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return scripts["__all_" .. k] or {} end,
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

local store = { ["agency.clock"] = 1000 }
local S = {}
local RA = load_script("room_air.lua", env(store, S))
S.room_air = RA
local CR = load_script("crew.lua", env(store, S))
local DM = load_script("damage.lua", env(store, S))
S.damage = DM
local CA = load_script("cabin_air.lua", env(store, S))
local seatDef = CR.seatDef

-- a craft as vessel_controller publishes it
local function P(uid, id, parent, extra)
  local d = { uid = uid, id = id, parent = parent or 0, label = id }
  if id == "pod" then d.kind, d.label = "crewed", "Pod Mk1"
  elseif id == "podMk2" then d.kind, d.label = "crewed", "Pod Mk2"
  elseif id == "cabin" then d.kind, d.label = "structural", "Crew Cabin"
  elseif id == "seat" then d.kind, d.seat, d.label = "crewed", true, "Command Seat"
  elseif id == "dockPort" then d.kind, d.dock, d.label = "structural", 1, "Docking Port"
  elseif id == "tankS" then d.kind, d.fuel, d.label = "tank", 80, "FT-S Tank"
  elseif id == "battery" then d.kind, d.label = "structural", "Battery" end
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end
local nid = 100
local function craft(parts, ports)
  nid = nid + 1
  local V = { recs = {}, hp = {}, gen = 1, ports = ports or {}, seats = {}, lost = {}, crewAboard = false, leftAt = -100, leftPad = true }
  for _, p in ipairs(parts) do V.recs[p.uid] = p end
  V.aboardRecs = function() local o = {}; for u, d in pairs(V.recs) do o[u] = d end return o end
  V.dockPorts = function() return V.ports end
  V.partsGen = function() return V.gen end
  V.partHp = function(u) if not V.recs[u] then return nil end return V.hp[u] or 1 end
  V.partRec = function(u) return V.recs[u] end
  V.partSt = function(u, k, v, write)
    local d = V.recs[u]
    if not d then return nil end
    if write then d.st = type(d.st) == "table" and d.st or {}; if v == false then d.st[k] = nil else d.st[k] = v end end
    return type(d.st) == "table" and d.st[k] or nil
  end
  V.seatsOf = function() return V.seats end
  V.memberSlot = function(id) for _, s in ipairs(V.seats) do if s.taken == id then return s.uid, s.slot end end return nil end
  V.lostParts = function() return V.lost, 0 end
  V.node = { id = nid, x = 0, y = 0, z = 0, valid = true, children = function() return {} end }
  return V
end
local function G_of(v) return CA.buildModules(v.aboardRecs(), v.dockPorts(), { seatDef = seatDef, lost = v.lost }) end

-- ── the graph ───────────────────────────────────────────────────────────────
do
  local v = craft({ P(1, "pod"), P(2, "cabin", 1), P(3, "tankS", 2) })
  local G = G_of(v)
  check(#G.mods == 1 and #G.mods[1].uids == 2, string.format("a pod on a cabin: one module (%d)", #G.mods))
  check(G.mods[1] and near(G.mods[1].V, 9.0), string.format("its volume 2 + 7 m³ (%.2f)", G.mods[1] and G.mods[1].V or -1))
  local hatches = 0
  for _, d in ipairs(G.doors) do if d.kind == "hatch" and d.b == 0 then hatches = hatches + 1 end end
  check(hatches == 2, "two side hatches to the outside (" .. hatches .. ")")
  check(G.mods[1] and G.mods[1].label == "Pod Mk1 + Crew Cabin", "named by its parts: " .. tostring(G.mods[1] and G.mods[1].label))

  local v2 = craft({ P(1, "pod"), P(2, "tankS", 1), P(3, "podMk2", 2), P(4, "seat", 3, { att = "radial" }) })
  local G2 = G_of(v2)
  check(#G2.mods == 2, "a tank between two pods: two modules (" .. #G2.mods .. ")")
  local inner = 0
  for _, d in ipairs(G2.doors) do if d.b and d.b > 0 then inner = inner + 1 end end
  check(inner == 0, "and no door between them")
  check(G2.modOf[4] == nil, "an open seat is no cabin")

  -- docked: pod(1)-port(2) ⟷ port(12)-cabin(11) (merged records, a mated pair)
  local v3 = craft({ P(1, "pod"), P(2, "dockPort", 1), P(12, "dockPort", 2), P(11, "cabin", 12) },
    { { uid = 2, mate = 12 }, { uid = 12, mate = 2 } })
  local G3 = G_of(v3)
  local port = nil
  for _, d in ipairs(G3.doors) do if d.kind == "port" then port = d end end
  check(#G3.mods == 2 and port and port.b > 0 and port.a ~= port.b, "docked craft: two modules and one docking hatch between them")
  local st = function(u, k) return v3.partSt(u, k) end
  local S = {}
  for k, d in ipairs(G3.doors) do S[k] = CA.doorStateOf(d, st) end
  local nets = CA.networksOf(G3, S, {})
  check(#nets == 2, "sealed by default: two networks (" .. #nets .. ")")
  v3.partSt(2, "ph", "open", true)
  for k, d in ipairs(G3.doors) do S[k] = CA.doorStateOf(d, st) end
  check(#CA.networksOf(G3, S, {}) == 2, "one side's hatch open, the other sealed: still apart")
  v3.partSt(12, "ph", "open", true)
  for k, d in ipairs(G3.doors) do S[k] = CA.doorStateOf(d, st) end
  local n3 = CA.networksOf(G3, S, {})
  check(#n3 == 1 and near(n3[1].V, 9.0), "both open: one network of 9 m³")

  local v4 = craft({ P(1, "pod"), P(2, "dockPort", 1) }, { { uid = 2 } })
  local G4 = G_of(v4)
  local free = nil
  for _, d in ipairs(G4.doors) do if d.kind == "port" then free = d end end
  check(free and free.b == 0, "an unmated port on a cabin opens to the outside")

  local v5 = craft({ P(1, "pod"), P(3, "tankS", 1) })
  v5.lost = { P(2, "cabin", 1) }
  local G5 = G_of(v5)
  local br = nil
  for _, d in ipairs(G5.doors) do if d.kind == "breach" then br = d end end
  check(br and br.a == G5.modOf[1], "a cabin torn off the pod leaves a breach in the pod's module")
end

-- ── leaks ───────────────────────────────────────────────────────────────────
do
  check(CA.holeArea(0.5) == 0 and CA.holeArea(0.9) == 0, "no hole at hp 0.5 and over")
  check(near(CA.holeArea(0.05), DM.A_HOLE), "a 10 cm hole (A_HOLE) at hp 0.05")
  local same = true
  for _, h in ipairs({ 0.49, 0.45, 0.3, 0.1, 0.05, 0.01 }) do if not near(CA.holeArea(h), DM.holeArea(h), 1e-12) then same = false end end
  check(same, "cabin_air and damage.lua keep the same hole rule")

  local v = craft({ P(1, "pod") })
  local G = G_of(v)
  local A = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }
  local Q = { 8 }
  v.hp[1] = 0.45
  v.partSt(1, "creg", "off", true)
  local S = {}
  for k, d in ipairs(G.doors) do S[k] = CA.doorStateOf(d, function(u, k2) return v.partSt(u, k2) end) end
  local nets, netOf, valves = CA.networksOf(G, S, { hp = v.partHp, regOff = function(u) return v.partSt(u, "creg") == "off" end })
  local Ah = CA.holeArea(0.45)
  local tau = 2.0 / (CA.LEAK_K * Ah)
  check(#nets[1].leaks == 1 and near(nets[1].Gout, CA.LEAK_K * Ah), string.format("hp 0.45: a %.2f cm² hole, τ %.0f s", Ah * 1e4, tau))
  local st0 = CA.netStatus(RA, G, nets[1], A, Q, { pout = 0, xout = 0 })
  check(st0.untilBad and near(st0.untilBad, tau * math.log(0.21 / RA.O2_MIN), 1e-6),
    string.format("time to unbreathable: the O2 goes first (%.0f s = τ ln(0.21/0.16))", st0.untilBad or -1))
  local e = { RA = RA, pout = 0, xout = 0, cout = 0, crew = {}, powered = false, nets = nets, netOf = netOf, valves = valves }
  CA.stepAir(G, A, Q, e, 60)
  local p = (A[1].N + A[1].x + A[1].c) / 2
  check(near(p, math.exp(-60 / tau), 1e-6), string.format("after 60 s: %.4f atm (e^(-t/τ) %.4f)", p, math.exp(-60 / tau)))
  check(near(Q[1], 8), "the regulator off: the reserve untouched")

  -- with the regulator on, a slow leak is fed from the reserve
  local A2, Q2 = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }, { 8 }
  local nets2, netOf2, valves2 = CA.networksOf(G, S, { hp = function() return 0.49 end })
  CA.stepAir(G, A2, Q2, { RA = RA, pout = 0, crew = {}, powered = false, nets = nets2, netOf = netOf2, valves = valves2 }, 3600)
  local p2 = (A2[1].N + A2[1].x + A2[1].c) / 2
  check(p2 > 0.95 and Q2[1] < 8, string.format("a pinhole with the regulator on: held at %.3f atm, the reserve down to %.2f", p2, Q2[1]))

  -- a breach (hp 0.05) shuts the regulator's excess-flow valve
  local A3, Q3 = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }, { 8 }
  local nets3, netOf3, valves3 = CA.networksOf(G, S, { hp = function() return 0.05 end })
  CA.stepAir(G, A3, Q3, { RA = RA, pout = 0, crew = {}, powered = false, nets = nets3, netOf = netOf3, valves = valves3 }, 30)
  local p3 = (A3[1].N + A3[1].x + A3[1].c) / 2
  check(p3 < 1e-6 and near(Q3[1], 8), string.format("a breach: the pod empties (%.2e atm) and the reserve is kept (%.2f)", p3, Q3[1]))
end

-- ── hatches ─────────────────────────────────────────────────────────────────
do
  local v = craft({ P(1, "pod") })
  local G = G_of(v)
  local function run(state, secs)
    local A, Q = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }, { 8 }
    v.partSt(1, "hatch", state ~= "sealed" and state or false, true)
    local S = {}
    for k, d in ipairs(G.doors) do S[k] = CA.doorStateOf(d, function(u, k2) return v.partSt(u, k2) end) end
    local nets, netOf, valves = CA.networksOf(G, S, { regOff = function() return true end })
    CA.stepAir(G, A, Q, { RA = RA, pout = 0, crew = {}, nets = nets, netOf = netOf, valves = valves }, secs)
    return (A[1].N + A[1].x + A[1].c) / 2
  end
  check(run("open", 5) < 1e-6, "the hatch open to vacuum: the pod empties in seconds")
  check(near(run("shut", 40), math.exp(-40 * CA.EQV_G / 2), 1e-6), "shut, the valve open: τ = V / EQV_G (40 s)")
  check(near(run("sealed", 3600), 1.0, 1e-9), "sealed: an hour and not a breath lost")
end

-- ── docking: equalise through the valve, mix when open ──────────────────────
do
  local v = craft({ P(1, "pod"), P(2, "dockPort", 1), P(12, "dockPort", 2), P(11, "pod", 12) },
    { { uid = 2, mate = 12 }, { uid = 12, mate = 2 } })
  local G = G_of(v)
  local function nets_for(state)
    v.partSt(2, "ph", state, true); v.partSt(12, "ph", state, true)
    local S = {}
    for k, d in ipairs(G.doors) do S[k] = CA.doorStateOf(d, function(u, k2) return v.partSt(u, k2) end) end
    return CA.networksOf(G, S, { regOff = function() return true end })
  end
  local a, b = G.modOf[1], G.modOf[11]
  local A = {}
  A[a] = { N = 2 * 0.79, x = 2 * 0.21, c = 0 }
  A[b] = { N = 0, x = 0, c = 0 }
  local Q = { 0, 0 }
  local nets, netOf, valves = nets_for("shut")
  check(#valves == 1, "the docking hatch shut: one valve between the modules")
  CA.stepAir(G, A, Q, { RA = RA, pout = 0, crew = {}, nets = nets, netOf = netOf, valves = valves }, 600)
  local pa, pb = (A[a].N + A[a].x + A[a].c) / 2, (A[b].N + A[b].x + A[b].c) / 2
  check(near(pa, 0.5, 1e-3) and near(pb, 0.5, 1e-3), string.format("ten minutes through the valve: %.3f / %.3f atm", pa, pb))
  -- open: one network, the CO2 of one side shared
  A[a] = { N = 2 * 0.79, x = 2 * 0.21 - 0.02, c = 0.02 }
  A[b] = { N = 2 * 0.79, x = 2 * 0.21, c = 0 }
  nets, netOf, valves = nets_for("open")
  CA.stepAir(G, A, Q, { RA = RA, pout = 0, crew = {}, nets = nets, netOf = netOf, valves = valves }, 1)
  check(#nets == 1 and near(A[a].c, 0.01, 1e-9) and near(A[b].c, 0.01, 1e-9), "the hatch open: one network, the CO2 shared")
end

-- ── breathing ───────────────────────────────────────────────────────────────
do
  local v = craft({ P(1, "pod") })
  local G = G_of(v)
  local S = {}
  for k, d in ipairs(G.doors) do S[k] = "sealed" end
  local nets, netOf, valves = CA.networksOf(G, S, { regOff = function() return true end })
  local tbad = 0.02 * 2 / RA.MAKE
  local A, Q = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }, { 0 }
  CA.stepAir(G, A, Q, { RA = RA, pout = 0, crew = { 1 }, powered = false, nets = nets, netOf = netOf, valves = valves }, tbad * 0.99)
  local s1 = RA.statusOf(A[1], 2)
  CA.stepAir(G, A, Q, { RA = RA, pout = 0, crew = { 1 }, powered = false, nets = nets, netOf = netOf, valves = valves }, tbad * 0.02)
  local s2 = RA.statusOf(A[1], 2)
  check(s1.breathable and not s2.breathable and s2.why:find("CO2"), string.format("one crew, no scrubber: CO2 bad after %.1f h (%s)", tbad / 3600, tostring(s2.why)))
  local Ap = { { N = 2 * 0.79, x = 2 * 0.21, c = 0 } }
  CA.stepAir(G, Ap, Q, { RA = RA, pout = 0, crew = { 1 }, powered = true, nets = nets, netOf = netOf, valves = valves }, 86400)
  check(Ap[1].c < 1e-9, "with charge the scrubber holds the CO2 at none for a day")
  -- one step against many: sealed (regulator, scrubber, crew of 2) the closed
  -- form is exact; with a pinhole the leak is split from the chemistry each
  -- STEP_MAX, so the two land at different points of the regulator's
  -- 0.97–1.0 atm band, never further apart than the band
  local function versus(hp, pw)
    local nets2, netOf2, valves2 = CA.networksOf(G, S, { hp = function() return hp end })
    local A1, Q1 = { { N = 1.5, x = 0.4, c = 0.01 } }, { 8 }
    local A2, Q2 = { { N = 1.5, x = 0.4, c = 0.01 } }, { 8 }
    local ee = function() return { RA = RA, pout = 0, crew = { 2 }, powered = pw, nets = nets2, netOf = netOf2, valves = valves2 } end
    CA.stepAir(G, A1, Q1, ee(), 3600)
    local e2 = ee()
    for _ = 1, 3600 do CA.stepAir(G, A2, Q2, e2, 1) end
    return A1[1], Q1[1], A2[1], Q2[1]
  end
  local a1, q1, a2, q2 = versus(1.0, false)
  check(near(a1.x, a2.x, 1e-6) and near(a1.N, a2.N, 1e-6) and near(a1.c, a2.c, 1e-6) and near(q1, q2, 1e-6),
    string.format("sealed: an hour in one call lands where 3,600 one-second calls do (O2 %.6f / %.6f, CO2 %.6f / %.6f)", a1.x, a2.x, a1.c, a2.c))
  a1, q1, a2, q2 = versus(0.49, true)
  local p1, p2 = (a1.N + a1.x + a1.c) / 2, (a2.N + a2.x + a2.c) / 2
  check(math.abs(p1 - p2) <= 0.031 and math.abs(q1 - q2) <= 0.07 and math.abs(a1.x / (2 * p1) - a2.x / (2 * p2)) < 0.002,
    string.format("a pinhole: one call and 3,600 within the regulator's band (%.3f / %.3f atm, reserve %.3f / %.3f)", p1, p2, q1, q2))
end

-- ── the scene half ──────────────────────────────────────────────────────────
do
  local v = craft({ P(1, "pod"), P(2, "battery", 1), P(3, "tankS", 2) })
  v.recs[1].st = nil
  v.seats = { { uid = 1, slot = 1, taken = 7 } }
  v.crewAboard = true
  local crewStub = {
    activeId = function() return 7 end, seatDef = seatDef, get = function() return { id = 7, o2 = 1 } end,
    patch = function() end, recordStep = CR.recordStep, SUIT_AIR_SECS = 1200,
  }
  S.crew = crewStub
  S["__all_vessel_controller"] = { v }
  S.electronics = { modOf = function(d, k) return (d.id == "battery" and k == "battery") and { ec = 150 } or nil end,
                    stateOf = function(d) d._e = d._e or { charge = 100 }; return d._e end }
  local E = getfenv(CA.tickNow)
  E.time = 10
  CA.tickNow()
  local a = v.partSt(1, "cab")
  check(type(a) == "table" and near((a.N + a.x + a.c) / 2, 1.0, 1e-6), "a craft never seen: its pod holds 1 atm of normal air")
  check(near(v.partSt(1, "cq") or -1, CA.CABIN.pod.q), "and a full reserve")
  check(CA.avatarAir() == "cabin" and CA.helmetAboard() == true, "the avatar's module is breathable: the helmet may come off")
  local x0 = v.partSt(1, "cab").x
  local took = CA.takeO2(0.01)
  store["agency.clock"] = 1001; E.time = 11
  CA.tickNow()
  check(near(took, 0.01) and v.partSt(1, "cab").x < x0 - 0.0099, "the suit's refill takes its O2 from the module")
  -- puncture: hp 0.3, ten seconds
  v.hp[1] = 0.3
  store["agency.clock"] = 1011; E.time = 21
  CA.tickNow()
  local s = CA.statusOf(v, 1)
  check(s and s.venting and #s.leaks == 1 and s.p < 0.9, string.format("punctured: venting through %d hole, %.2f atm after 10 s", s and #s.leaks or -1, s and s.p or -1))
  -- (scn_vacuum) one reading per air tick: the banner and the gauge say the
  -- same time left (the shot had "Unbreathable in 5 s" over "unbreathable in 2 s")
  do
    E.time = 21.7
    local s2 = CA.statusOf(v, 1)
    local eta = CA.etaText(s2)
    local line = CA.alarmLine(s2.label, "a hole in the hull", s2)
    check(s2 == s and eta and line:lower():find(eta, 1, true) ~= nil,
      string.format("one reading a tick: the banner \"%s\" carries the gauge's \"%s\"", line, tostring(eta)))
    store["agency.clock"] = 1012; E.time = 22
    CA.tickNow()
    local s3 = CA.statusOf(v, 1)
    check(s3 ~= s2 and s3.p < s2.p, string.format("the next tick reads again: %.3f → %.3f atm", s2.p, s3.p))
    check(CA.cabinOf(v, "#1") == s3 and CA.cabinOf(v, "#99") == nil, "cabinOf(v, \"#<uid>\"): the module that part is in")
    local BC = load_script("big_caption.lua", env({}, {}))
    BC.show("DEPRESSURISATION", CA.alarmLine(s2.label, "a hole in the hull", s2), 4.5)
    local ok1 = BC.retext("DEPRESSURISATION", CA.alarmLine(s3.label, "a hole in the hull", s3))
    local ok2 = BC.retext("VESSEL LOST", "x")
    check(ok1 and not ok2, "big_caption.retext: the banner's line follows the reading, another title is left alone")
  end
  store["agency.clock"] = 1100; E.time = 110
  CA.tickNow()
  local ok, why = CA.helmetAboard()
  check(CA.avatarAir() == "suit" and ok == false and tostring(why):find("helmet stays on"), "the air gone: the suit is breathed, the helmet stays on (" .. tostring(why) .. ")")
  -- patched: the regulator brings it back from the reserve
  v.hp[1] = CA.PATCH_HP
  store["agency.clock"] = 1400; E.time = 400
  CA.tickNow()
  s = CA.statusOf(v, 1)
  check(s and s.p > 0.96 and s.breathable and (v.partSt(1, "cq") or 99) < CA.CABIN.pod.q - 1.5,
    string.format("patched: repressurised to %.2f atm from the reserve (%.1f left)", s and s.p or -1, v.partSt(1, "cq") or -1))
  -- the side hatch from the menu: warned, never refused
  local okd, warn = CA.setDoor(v, 1, "open", "probe")
  check(okd and warn and warn:find("vents"), "opening the hatch to vacuum: done, with the warning (" .. tostring(warn) .. ")")
  check(CA.whyNot(v, 1, "open") == nil, "and never refused")
  store["agency.clock"] = 1410; E.time = 410
  CA.tickNow()
  check(CA.statusOf(v, 1).p < 0.01, "the hatch open: the pod is at vacuum")
  CA.setDoor(v, 1, "sealed")
  store["agency.clock"] = 1700; E.time = 700
  CA.tickNow()
  check(CA.statusOf(v, 1).p > 0.96, "sealed again: the regulator refills it")
  -- EVA: the hatch of the part left opens; nobody inside, it stays open
  CA.eventsNow()
  v.crewAboard, v.leftAt, v.lastExitUid, v.seats = false, 701, 1, {}
  CA.eventsNow()
  check(CA.lastHatch and CA.lastHatch.by == "eva" and CA.lastHatch.to == "open", "an EVA opens the hatch it went out by")
  E.time = 706
  CA.eventsNow()
  check(CA.doorsOf(v)[1].state == "open", "nobody left inside: it stays open")
  -- boarding seals it; then an EVA with a crewmate left inside: closed behind
  v.crewAboard, v.seats = true, { { uid = 1, slot = 1, taken = 7 } }
  CA.eventsNow()
  check(CA.lastHatch.by == "board" and CA.doorsOf(v)[1].state == "sealed", "boarding seals the hatch")
  v.recs[4] = P(4, "podMk2", 0); v.gen = v.gen + 1
  v.recs[1].parent = 4
  v.seats = { { uid = 4, slot = 1, taken = 7 }, { uid = 4, slot = 2, taken = 8 } }
  CA.eventsNow()
  v.crewAboard, v.leftAt, v.lastExitUid, v.seats = false, 720, 4, { { uid = 4, slot = 2, taken = 8 } }
  CA.eventsNow()
  local hk = CA.doorOf(v, 4, "hatch")
  check(CA.doorsOf(v)[hk].state == "open", "an EVA from the Mk2 with a crewmate inside: open")
  E.time = 710
  CA.eventsNow()
  check(CA.doorsOf(v)[hk].state == "sealed" and CA.lastHatch.by == "crew", "and the crewmate closes it behind")
  v.recs[1].parent = 0; v.recs[4] = nil; v.gen = v.gen + 1
  v.crewAboard, v.seats = true, { { uid = 1, slot = 1, taken = 7 } }
  CA.eventsNow()
  E.time = 711
  -- the scenario read
  local cab = CA.cabinOf(v, "crew")
  check(cab and cab.breathable and cab.label == "Pod Mk1", "cabinOf(v, \"crew\"): the crew's module")
  -- the setting off
  store["craft.cabin_air"] = "off"
  check(CA.avatarAir() == nil and CA.helmetAboard() == nil and CA.infoRows({ vessel = v, uid = 1 }) == nil, "cabin air off: no answers, the old rules")
  store["craft.cabin_air"] = nil
  -- (scn_vacuum) out of one can, back in through the next: the hatch they
  -- left by is sealed behind them too (Hard Vacuum: the hab stayed open)
  do
    local w = craft({ P(31, "pod"), P(32, "cabin", 31) })
    w.seats = { { uid = 32, slot = 1, taken = 7 } }
    w.crewAboard = true
    S["__all_vessel_controller"] = { v, w }
    E.time = E.time + 1.5          -- (cabin_air reads the craft list once a second)
    CA.eventsNow()
    w.crewAboard, w.leftAt, w.lastExitUid, w.seats = false, 730, 32, {}
    CA.eventsNow()
    local k32 = CA.doorOf(w, 32, "hatch")
    local open1 = CA.doorsOf(w)[k32].state == "open"
    w.crewAboard, w.seats = true, { { uid = 31, slot = 1, taken = 7 } }
    CA.eventsNow()
    check(open1 and CA.doorsOf(w)[k32].state == "sealed", "boarding by the pod seals the cabin's hatch they went out by")
    S["__all_vessel_controller"] = { v }
  end
  -- the state rides the part: a new script instance reads it back
  local CA2 = load_script("cabin_air.lua", env(store, S))
  getfenv(CA2.tickNow).time = 701
  CA2.tickNow()
  local s2 = CA2.statusOf(v, 1)
  check(s2 and near(s2.p, CA.statusOf(v, 1).p, 1e-3), "a reload reads the module's air back from the parts' state")
end

-- ── scenarios ───────────────────────────────────────────────────────────────
do
  local SC = load_script("scenario.lua", env({}, {}))
  local reading = { p = 0.42, o2 = 0.09, co2 = 0.001, breathable = false, why = "thin", venting = true }
  local W = { cabin = function(name, which) return name == "Ansel" and reading or nil end }
  local ok, txt = SC.evalGoal({ kind = "cabin", craft = "craft:Ansel", p = 0.9 }, W, {}, { now = 0 })
  check(ok == false and txt:find("0.42"), "cabin goal: 0.42 of 0.90 atm, not met (" .. tostring(txt) .. ")")
  local mem = {}
  local f1 = SC.evalGoal({ kind = "craft_pressure", craft = "craft:Ansel", below = 0.5, secs = 30 }, W, mem, { now = 10 })
  local f2 = SC.evalGoal({ kind = "craft_pressure", craft = "craft:Ansel", below = 0.5, secs = 30 }, W, mem, { now = 45 })
  check(f1 == false and f2 == true, "craft_pressure: under 0.5 atm for 30 s fails the scenario")
  reading = { p = 1.0, o2 = 0.21, co2 = 0, breathable = true, venting = false }
  check(SC.evalGoal({ kind = "cabin", craft = "craft:Ansel", sealed = true, breathable = true }, W, {}, {}) == true, "cabin goal: sealed and breathable, met")
  local sc = { id = "g1", title = "G1", world = "any", steps = { { id = "a", goals = { { kind = "cabin", craft = "craft:Ansel", module = "crew", p = 0.9 } } } },
               fail = { { kind = "craft_pressure", craft = "craft:Ansel", below = 0.5, secs = 20 } } }
  local okv, errs = SC.validate(sc, {})
  local bad = {}
  for _, e in ipairs(errs or {}) do if e:find("cabin") or e:find("craft_pressure") or e:find("module") or e:find("below") then bad[#bad + 1] = e end end
  check(#bad == 0, "a scenario with a cabin goal and a craft_pressure fail validates: " .. table.concat(bad, "; "))
  local sc2 = { id = "g1b", title = "G1", world = "any", steps = { { id = "a", goals = { { kind = "cabin", craft = "craft:Ansel", module = {}, below = 0.3 } } } },
                fail = { { kind = "craft_pressure", craft = "craft:Ansel", p = 0.2, secs = -1 } } }
  local _, errs2 = SC.validate(sc2, {})
  local hits = 0
  for _, e in ipairs(errs2 or {}) do if e:find("module") or e:find("below and secs") or e:find("belong to the cabin") or e:find("secs") then hits = hits + 1 end end
  check(hits >= 3, "a bad module, below on a goal, p on the fail and a negative secs are each named (" .. hits .. ")")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL  " .. f) end
  print(string.format("smoke_cabin_air: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_cabin_air: all %d checks passed", passed))
