-- SMOKE: the refineries and the Fabricator (expansion X6; scripts/machines.lua,
-- item_net.lua's machine nodes; docs/base-building.md §24).
--
--   * the physics: each machine's rate from its energy a kg (crusher 2 kg/s,
--     furnace 8 g/s of Steel, kiln, mixer 1 kg/s, electrolyser 1 g/s of
--     water), the crusher's split conserves mass;
--   * cooling: a radiator's kW in vacuum and air, a tower only in air; a
--     furnace alone runs at 20 %, with radiators at 100 %; a kiln on the
--     same row shares them; a reactor's loop keeps its sinks;
--   * duty: off, no power, cooling, water, a full fuel tank, in that order;
--   * the chain: hopper → crusher → furnace (duty by cooling) → a Fabricator's
--     store (it takes only refined solids), spoil to a hopper; the outlet
--     full stops the machine with LIMITED BY; a day in one call = 86,400
--     one-second calls to 1e-6;
--   * the Fabricator's queue: waits for materials, takes them, makes the
--     crate in recipes' time at its duty, waits for room;
--   * cost: the chain stepped.
--
--   luajit solar/tests/smoke_machines.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) * math.max(1, math.abs(a), math.abs(b)) end

local function load(path)
  local E = setmetatable({ save = { get = function() end, set = function() end }, findScript = function() end, log = function() end },
                         { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  return E
end
local MC = load("machines.lua")
local N = load("item_net.lua")
local R = load("recipes.lua")

-- ── 1. the physics ──────────────────────────────────────────────────────────
do
  local c = MC.convOf("crusher")
  check(near(c.hematite.rate, 2.0), "crusher 2 kg/s: " .. c.hematite.rate)
  local s = 0
  for _, v in pairs(c.hematite.outs) do s = s + v end
  check(near(s, 1), "the crusher's split conserves mass")
  check(near(c.hematite.outs.iron, 0.45) and near(c.hematite.outs.regolith, 0.55), "Hematite Earth → 45 % iron ore, 55 % regolith")
  check(c.iron and near(c.iron.outs.iron, 1), "ore passes the crusher 1:1")
  local f = MC.convOf("furnace")
  local steel = f.iron.rate * f.iron.outs.steel
  check(near(steel, 12 / 1500), string.format("furnace: Steel at %.4f kg/s (12 kW / 1.5 MJ a kg)", steel))
  check(near(steel * 3600, 28.8, 1e-3), "about 29 kg of Steel an hour")
  local k = MC.convOf("kiln")
  check(near(k.silica.rate * k.silica.outs.glass, 9 / 2800), "kiln: Glass at 9 kW / 2.8 MJ a kg")
  local m = MC.convOf("mixer")
  check(near(m.regolith.rate, 1.0) and near(m.regolith.outs.regocrete, 1.2), "mixer: 1 kg/s of regolith → 1.2 kg/s of Regocrete")
  check(near(MC.waterFor("mixer", 5), 1.0), "the mixer's water: 5:1")
  local qw, qp = MC.electrolysis()
  check(near(qw, 0.001) and near(qp, 0.00078), string.format("electrolyser: %.4f kg/s water → %.5f kg/s propellant", qw, qp))
end

-- ── 2. cooling ──────────────────────────────────────────────────────────────
do
  local rad = { kind = "rad", area = 16, eps = 0.88 }
  local vac = MC.rejectKW(rad, { air = false, sun = 0 })
  local vacSun = MC.rejectKW(rad, { air = false, sun = 1 })
  local air = MC.rejectKW(rad, { air = true, tamb = 288, sun = 0.5 })
  check(vac > 3.5 and vac < 4.0, string.format("a 16 m² panel sheds %.2f kW in vacuum, dark", vac))
  check(vacSun > 2.3 and vacSun < 2.6, string.format("%.2f kW in full sun (the plan's ~2.5)", vacSun))
  check(air > 4.5 and air < 5.5, string.format("%.2f kW in air (the plan's ~4)", air))
  check(MC.rejectKW({ kind = "tower", g = 14 }, { air = false }) == 0, "a tower sheds nothing in vacuum")
  check(MC.rejectKW({ kind = "tower", g = 14 }, { air = true, tamb = 288 }) > 500, "a tower in air sheds hundreds of kW")
  local function port(x, nx) return { x = x, y = 0.6, z = 0, nx = nx, nz = 0 } end
  -- a furnace (heat port at x=1 facing +x), alone
  local L = MC.coolLoops({ { key = "f", heat = 10, ports = { port(1, 1) } } })
  check(near(L.f.cool, 0.2), "a furnace with nothing on its heat port: 20 %")
  -- three panels chained: 1..4, 4..7, 7..10 (each in at −x, out at +x)
  local function panel(k, x0, kw) return { key = k, sink = kw, ports = { port(x0, -1), port(x0 + 3, 1) } } end
  L = MC.coolLoops({ { key = "f", heat = 10, ports = { port(1, 1) } }, panel("r1", 1, 3), panel("r2", 4, 3), panel("r3", 7, 3) })
  check(near(L.f.cool, 1) and L.f.sinks == 3, string.format("three 3 kW panels on it: %.2f", L.f.cool))
  L = MC.coolLoops({ { key = "f", heat = 10, ports = { port(1, 1) } }, panel("r1", 1, 3) })
  check(near(L.f.cool, 0.5), string.format("one panel: 0.2 + 3/10 = %.2f", L.f.cool))
  -- a kiln on the same row (its port at the row's far end, facing back)
  L = MC.coolLoops({ { key = "f", heat = 10, ports = { port(1, 1) } }, panel("r1", 1, 3), panel("r2", 4, 3), panel("r3", 7, 3),
                     { key = "k", heat = 6, ports = { port(10, -1) } } })
  check(near(L.f.cool, 0.2 + 9 / 16) and near(L.k.cool, L.f.cool), string.format("a kiln on the row: both at %.2f", L.f.cool))
  -- a reactor's loop: its sinks are the plant's
  L = MC.coolLoops({ { key = "f", heat = 10, ports = { port(1, 1) } }, panel("r1", 1, 3), { key = "sg", reactor = true, ports = { port(4, -1) } } })
  check(near(L.f.cool, 0.2) and L.f.reactor, "a radiator on a reactor's loop is the reactor's")
end

-- ── 3. duty ─────────────────────────────────────────────────────────────────
do
  local d, w = MC.duty("furnace", { on = false })
  check(d == 0 and w:find("switched off"), "off: " .. tostring(w))
  d, w = MC.duty("furnace", { served = false, cool = 1 })
  check(d == 0 and w:find("no power"), "no power: " .. tostring(w))
  d, w = MC.duty("furnace", { cool = 0.2 })
  check(near(d, 0.2) and w:find("cooling"), "cooling: " .. tostring(w))
  d, w = MC.duty("furnace", { cool = 1 })
  check(d == 1 and w == nil, "full duty")
  d, w = MC.duty("mixer", { water = 0 })
  check(d == 0 and w:find("no water"), "mixer, no water: " .. tostring(w))
  d, w = MC.duty("electrolyser", { room = false })
  check(d == 0 and w:find("Fuel Tank"), "electrolyser, no tank room: " .. tostring(w))
  d = MC.duty("crusher", {})
  check(d == 1, "a crusher needs no cooling")
end

-- ── 4. the chain in item_net ────────────────────────────────────────────────
local Y = 0.8
local function belt(key, x0, x1, opts)
  opts = opts or {}
  return { key = key, kind = "belt", cap = opts.cap or 8, ok = opts.ok ~= false, why = opts.why, len = math.abs(x1 - x0),
           ports = { { x = x0, y = Y, z = opts.z or 0, bore = "BELT", role = "in" }, { x = x1, y = Y, z = opts.z1 or opts.z or 0, bore = "BELT", role = "out" } } }
end
local function store(key, x, cap, opts)
  opts = opts or {}
  local ports = {}
  for _, dx in ipairs(opts.ports or { -1, 1 }) do ports[#ports + 1] = { x = x + dx, y = Y, z = opts.z or 0, bore = "BELT", role = "any" } end
  return { key = key, kind = "store", cap = cap, label = key, ports = ports, accept = opts.accept }
end
local function machine(key, kind, x, kw, opts)
  opts = opts or {}
  local M = MC.MACH[kind]
  local ports = { { x = x - 1, y = Y, z = 0, bore = "BELT", role = "any", side = "in" }, { x = x + 1, y = Y, z = 0, bore = "BELT", role = "any", side = "out" },
                  { x = x, y = Y, z = 1, bore = "BELT", role = "any", side = "out" } }
  for _, p in ipairs(opts.extra or {}) do ports[#ports + 1] = p end
  local conv = MC.convOf(kind)
  return { key = key, kind = "machine", label = M.label, capIn = M.capIn, capOut = M.capOut, conv = conv, accept = MC.acceptOf(kind),
           kw = kw, ports = ports }
end
local function sum(x) local s = 0; for _, v in pairs(x or {}) do s = s + v end return s end
local function chain(furnaceDuty)
  -- hopper(0) → b1 → crusher(4) → b2 → furnace(8) → b3 → fab(12); crusher's outlet also → spoil (z = 3)
  local cr = MC.MACH.crusher.kw
  local fu = MC.MACH.furnace.kw * furnaceDuty
  local P = { store("hopper", 0, 4000), belt("b1", 1, 3), machine("crusher", "crusher", 4, cr), belt("b2", 5, 7), machine("furnace", "furnace", 8, fu),
              belt("b3", 9, 11), store("fab", 12, 2000, { accept = MC.FAB_TAKES }),
              belt("b4", 4, 4, { z = 1, z1 = 3 }), store("spoil", 4, 4000, { ports = { 0 }, z = 3 }) }
  local net = N.build(P)
  return net
end
do
  local net = chain(1)
  local i = N.nodeOf(net, "crusher")
  local o = N.nodeOf(net, "crusher>")
  check(i and o and net.nodes[i].out == o, "a machine is two nodes, its inlet and its outlet")
  local fi = N.nodeOf(net, "furnace")
  check(#net.lines == 4, "four lines: " .. #net.lines)
  local st = N.newState(net, { [N.nodeOf(net, "hopper")] = { hematite = 3000 } })
  local rep = N.advance(net, st, 600)
  local fab = N.nodeOf(net, "fab")
  local steel = st.x[fab].steel or 0
  local spoil = st.x[N.nodeOf(net, "spoil")] or {}
  check(steel > 0 and (st.x[fab].regolith or 0) == 0, string.format("Steel in the Fabricator's store after 10 min: %.2f kg (it takes no regolith)", steel))
  check((spoil.regolith or 0) > 0, string.format("regolith to the spoil hopper: %.1f kg", spoil.regolith or 0))
  -- mass: what left the hopper = in the crusher + its outlet + furnace inlet/outlet as ore-equivalent + spoil
  local left = 3000 - (st.x[N.nodeOf(net, "hopper")].hematite or 0)
  check(left > 0, "the hopper drained " .. left)
  -- steel rate at full duty once the furnace's inlet is stocked
  local q = N.convFlow(rep, fi)
  check(near(q, MC.convOf("furnace").iron.rate, 1e-6), string.format("the furnace works %.5f kg/s of ore at full duty", q))
  -- 20 % duty: a fifth of it
  local net2 = chain(0.2)
  local st2 = N.newState(net2, { [N.nodeOf(net2, "hopper")] = { hematite = 3000 } })
  local rep2 = N.advance(net2, st2, 600)
  local q2 = N.convFlow(rep2, N.nodeOf(net2, "furnace"))
  check(near(q2, q * 0.2, 1e-6), string.format("at 20 %% duty: %.5f kg/s", q2))
  -- the picky line first: the crusher's iron ore waits for the furnace, the spoil line takes the regolith
  local net6 = chain(1)
  local st6 = N.newState(net6, { [N.nodeOf(net6, "hopper")] = { hematite = 3000 } })
  N.advance(net6, st6, 20)
  local sp6 = st6.x[N.nodeOf(net6, "spoil")] or {}
  local fi6 = st6.x[N.nodeOf(net6, "furnace")] or {}
  check((sp6.iron or 0) == 0 and (sp6.regolith or 0) > 0 and (fi6.iron or 0) > 0, string.format("20 s: iron ore to the furnace (%.1f kg), none to the spoil (%.1f kg regolith)", fi6.iron or 0, sp6.regolith or 0))
  N.advance(net6, st6, 600)
  sp6 = st6.x[N.nodeOf(net6, "spoil")] or {}
  check((sp6.iron or 0) > 0, "the furnace's inlet full, the spare iron ore goes to the spoil")
  -- a day in one call vs 86,400 one-second calls
  local A = chain(1)
  local sA = N.newState(A, { [N.nodeOf(A, "hopper")] = { hematite = 3500, rustrock = 400 } })
  local Bn = chain(1)
  local sB = N.newState(Bn, { [N.nodeOf(Bn, "hopper")] = { hematite = 3500, rustrock = 400 } })
  local t0 = os.clock()
  local rA = N.advance(A, sA, 86400)
  local one_ms = (os.clock() - t0) * 1000
  for _ = 1, 86400 do N.advance(Bn, sB, 1) end
  local worst = 0
  for k, n in ipairs(A.nodes) do
    for m, v in pairs(sA.x[k]) do worst = math.max(worst, math.abs(v - (sB.x[k][m] or 0)) / math.max(1, math.abs(v))) end
    for m, v in pairs(sB.x[k]) do worst = math.max(worst, math.abs(v - (sA.x[k][m] or 0)) / math.max(1, math.abs(v))) end
  end
  check(worst < 1e-6, string.format("a day in one call = 86,400 calls (worst %.2e)", worst))
  check(not rA.ff, "the day's events fit one call (" .. rA.segs .. " segments)")
  print(string.format("  a day of the chain in one call: %.3f ms, %d segments; Steel %.1f kg, spoil %.0f kg", one_ms, rA.segs,
    sA.x[N.nodeOf(A, "fab")].steel or 0, sum(sA.x[N.nodeOf(A, "spoil")])))
  -- the outlet full: with no spoil line, the crusher's outlet fills with regolith and it stops
  local P = { store("hopper", 0, 4000), belt("b1", 1, 3), machine("crusher", "crusher", 4, 4), belt("b2", 5, 7), machine("furnace", "furnace", 8, 12) }
  local net3 = N.build(P)
  local st3 = N.newState(net3, { [N.nodeOf(net3, "hopper")] = { hematite = 3000 } })
  local rep3 = N.advance(net3, st3, 3600)
  local ci = N.nodeOf(net3, "crusher")
  local why = N.machineWhy(net3, st3, rep3, ci)
  check(why and why:find("outlet is full"), "LIMITED BY: " .. tostring(why))
  -- nothing feeds it
  local net4 = N.build({ machine("crusher", "crusher", 4, 4) })
  local st4 = N.newState(net4)
  local rep4 = N.advance(net4, st4, 1)
  check(tostring(N.machineWhy(net4, st4, rep4, 1)):find("nothing feeds"), "a lone crusher: " .. tostring(N.machineWhy(net4, st4, rep4, 1)))
  -- the inlet takes only what it works: a furnace refuses regolith
  local net5 = N.build({ store("h", 0, 4000), belt("b", 1, 3), machine("furnace", "furnace", 4, 12) })
  local st5 = N.newState(net5, { [1] = { regolith = 100 } })
  N.advance(net5, st5, 60)
  check(sum(st5.x[N.nodeOf(net5, "furnace")]) == 0 and near(st5.x[1].regolith, 100), "a furnace's inlet takes no regolith")
end

-- ── 5. the Fabricator's queue ───────────────────────────────────────────────
do
  local store = { steel = 0 }
  local made = {}
  local paid = 0
  local r = { mats = { { mat = "steel", kg = 100 } }, fittings = 50, secs = 12 }
  local env = {
    recipe = function(id) return id == "wall" and r or nil end,
    have = function(m) return store[m] or 0 end,
    take = function(mats) for _, e in ipairs(mats) do store[e.mat] = store[e.mat] - e.kg end return true end,
    pay = function(f) paid = paid + f; return true end,
    put = function(id) if #made >= 3 then return false end made[#made + 1] = id; return true end,
  }
  local F = { q = { { id = "wall", n = 2, t = 0 } } }
  local why = MC.fabAdvance(F, 10, 1, env)
  check(why and why:find("waiting for"), "empty store: " .. tostring(why))
  store.steel = 250
  why = MC.fabAdvance(F, 6, 1, env)
  check(F.q[1].started and near(F.q[1].t, 6) and near(store.steel, 150) and paid == 50, "the job starts: steel taken, fittings paid, 6 s in")
  why = MC.fabAdvance(F, 6, 0.5, env)
  check(near(F.q[1].t, 9), "at 50 % duty: 3 s more")
  local w2, n = MC.fabAdvance(F, 100, 1, env)
  check(#made == 2 and #F.q == 0 and near(store.steel, 50), string.format("both made in one call (%d), steel left %.0f", #made, store.steel))
  F.q = { { id = "wall", n = 3, t = 0 } }
  store.steel = 1000
  MC.fabAdvance(F, 1000, 1, env)
  check(#made == 3 and F.q[1] and F.q[1].done, "the store full: the crate waits (" .. tostring(F.q[1] and F.q[1].done) .. ")")
  check(MC.queued(F) == 2, "two left in the queue")
  -- the recipe's time: 10 s + 20 s a tonne
  local rr = R.recipeFor({ mass = 0.5, cost = 1000, kind = "structural" }, "FRAME", "x")
  check(near(rr.secs, 20), "a 500 kg part: 20 s")
end

-- ── 6. cost ─────────────────────────────────────────────────────────────────
do
  local net = chain(1)
  local st = N.newState(net, { [N.nodeOf(net, "hopper")] = { hematite = 3000 } })
  local t0 = os.clock()
  for _ = 1, 200 do N.advance(net, st, 0.2) end
  local ms = (os.clock() - t0) * 1000 / 200
  local t1 = os.clock()
  for _ = 1, 50 do N.build((function() local P = {}; for k = 1, 1 do end return { store("h", 0, 10) } end)()) end
  print(string.format("  a 5 Hz step of the crusher → furnace → Fabricator chain: %.4f ms (luajit)", ms))
  check(ms < 1.0, "a step costs under a millisecond")
end

for _, f in ipairs(failures) do print("FAIL: " .. f) end
print(string.format("smoke_machines: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
