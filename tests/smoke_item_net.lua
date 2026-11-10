-- SMOKE: conveyors and tubes as an inventory network (expansion X5;
-- scripts/item_net.lua, quarry.lua; docs/base-building.md §23).
--
--   * the pieces into lines: belts that meet are one line, its capacity its
--     weakest piece's; where it meets a store, upstream or downstream by the
--     belt's direction; head-on belts jam; a tube line needs a blower; a line
--     back into its own store, and a loop, stall;
--   * the flow: a quarry → its drive's buffer → belt → hopper → belt → silo
--     chain; the silo takes one material; the drain order; a T merge capped
--     at one belt; an unpowered line stalls and the buffer fills, then the
--     quarry stops (LIMITED BY says why); a chute fills a craft's hold until
--     it is full;
--   * closed form: a day in one call = 86,400 one-second calls (the stores,
--     the quarry's progress, what moved), to 1e-6;
--   * cost: a 30-belt base stepped.
--
--   luajit solar/tests/smoke_item_net.lua

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
local N = load("item_net.lua")
local Q = load("quarry.lua")
local M = load("materials.lua")

local Y = 0.8
local function belt(key, x0, x1, opts)
  opts = opts or {}
  local a, b = { x = x0, y = Y, z = opts.z or 0 }, { x = x1, y = Y, z = opts.z1 or opts.z or 0 }
  return { key = key, kind = opts.kind or "belt", cap = opts.cap or N.CAP.belt, ok = opts.ok ~= false, why = opts.why, len = math.abs(x1 - x0),
           ports = { { x = a.x, y = a.y, z = a.z, bore = opts.bore or "BELT", role = "in" }, { x = b.x, y = b.y, z = b.z, bore = opts.bore or "BELT", role = "out" } } }
end
local function store(key, x, cap, opts)
  opts = opts or {}
  local ports = {}
  for _, dx in ipairs(opts.ports or { -1, 1 }) do ports[#ports + 1] = { x = x + dx, y = Y, z = opts.z or 0, bore = opts.bore or "BELT", role = "any" } end
  for _, pt in ipairs(opts.extra or {}) do ports[#ports + 1] = pt end
  return { key = key, kind = opts.kind or "store", cap = cap, one = opts.one, mat = opts.mat, label = key, ports = ports }
end
local function sum(x) local s = 0; for _, v in pairs(x or {}) do s = s + v end return s end

-- ── 1. the lines ────────────────────────────────────────────────────────────
do
  -- drive (x=0, ports at ±1) → belts 1..5 → hopper (x=7) → belt → silo (x=11)
  local P = { store("drive", 0, 500), belt("b1", 1, 3), belt("b2", 3, 5, { cap = N.CAP.ramp }), belt("b3", 5, 6), store("hopper", 7, 4000),
              belt("b4", 8, 10), store("silo", 11, 8000, { one = true }) }
  local net = N.build(P)
  check(#net.lines == 2, "two lines: " .. #net.lines)
  local L1 = net.lines[net.lineOf.b1]
  check(net.lineOf.b1 == net.lineOf.b3, "b1–b3 are one line")
  check(L1.cap == N.CAP.ramp, "its capacity is the ramp's: " .. L1.cap)
  check(#L1.ups == 1 and net.nodes[L1.ups[1]].key == "drive" and #L1.downs == 1 and net.nodes[L1.downs[1]].key == "hopper", "drive → line 1 → hopper")
  check(net.order[1] == N.nodeOf(net, "drive") and net.order[3] == N.nodeOf(net, "silo"), "the stores in feed order")
  -- reversed belt: head on
  local P2 = { store("drive", 0, 500), belt("b1", 1, 3), belt("b2", 5, 3), store("hopper", 6, 4000) }
  local n2 = N.build(P2)
  check(not n2.lines[1].ok and n2.lines[1].why:find("head on"), "two belts head on jam: " .. tostring(n2.lines[1].why))
  -- a tube line without a blower; with one
  local P3 = { store("drive", 0, 500, { bore = "DN150" }), belt("t1", 1, 3, { kind = "tube", bore = "DN150", cap = N.CAP.tube }), store("st", 4, 1000, { bore = "DN150" }) }
  local n3 = N.build(P3)
  check(not n3.lines[1].ok and n3.lines[1].why:find("Blower"), "a tube line needs a blower: " .. tostring(n3.lines[1].why))
  P3[2] = belt("t1", 1, 2, { kind = "tube", bore = "DN150", cap = N.CAP.tube })
  P3[#P3 + 1] = belt("tb", 2, 2.5, { kind = "blower", bore = "DN150", cap = N.CAP.tube })
  P3[#P3 + 1] = belt("t2", 2.5, 3, { kind = "tube", bore = "DN150", cap = N.CAP.tube })
  local n3b = N.build(P3)
  check(n3b.lines[1].ok and n3b.lines[1].kind == "tube" and n3b.lines[1].cap == 2, "with a blower it runs at 2 kg/s")
  -- a belt doesn't meet a tube port (bores)
  local P4 = { store("drive", 0, 500, { bore = "DN150" }), belt("b1", 1, 3), store("h", 4, 1000) }
  local n4 = N.build(P4)
  check(#n4.lines[1].ups == 0, "a belt doesn't take from a tube port")
  -- a loop: hopper A → B → A
  local P5 = { store("A", 0, 1000), belt("ab", 1, 3), store("B", 4, 1000, { ports = { -1, 1, 0 } }),
               { key = "ba", kind = "belt", cap = 8, ok = true, ports = { { x = 5, y = Y, z = 0, role = "in" }, { x = -1, y = Y, z = 0, role = "out" } } } }
  local n5 = N.build(P5)
  local stalled = false
  for _, L in ipairs(n5.lines) do if not L.ok and L.why and L.why:find("loops") then stalled = true end end
  check(stalled, "a loop stalls with its reason")
end

-- ── 2. the flow ─────────────────────────────────────────────────────────────
local function chain(opts)
  opts = opts or {}
  local P = { store("drive", 0, 500), belt("b1", 1, 3), belt("b2", 3, 6, { ok = opts.b2 ~= false, why = "no power" }), store("hopper", 7, 4000),
              belt("b4", 8, 10), store("silo", 11, 8000, { one = true, mat = opts.siloMat }) }
  if opts.chute then
    P[#P + 1] = { key = "c1", kind = "belt", cap = 8, ok = true, ports = { { x = 7, y = Y, z = 1, role = "in" }, { x = 7, y = Y, z = 3, role = "out" } } }
    P[#P + 1] = { key = "chute", kind = "chute", label = "chute", ports = { { x = 7, y = Y, z = 3, role = "any" } } }
    P[5].ports[1] = { x = 8, y = Y, z = 0, role = "in" }
    P[4].ports[#P[4].ports + 1] = { x = 7, y = Y, z = 1, role = "any" }
  end
  return N.build(P)
end
-- a quarry profile: 0.01 cells/s of regolith (and a vein layer of iron)
local qq = Q.fromPosts({ { x = 10, y = 600000, z = 10 }, { x = -10, y = 600000, z = 10 }, { x = -10, y = 600000, z = -10 }, { x = 10, y = 600000, z = -10 } })
Q.survey(qq, function(lx, ly, lz) if ly < -3 and ly > -4.2 then return lz > 0 and "iron" or "regolith" end return "regolith" end, nil, M.hardness)
local saveK = Q.YIELD_K
Q.YIELD_K = 60        -- (a fast quarry for the test: 1.8 kg/s of regolith)
local function prof(prog) return Q.profile(qq, prog, M) end
local qr = Q.fromPosts({ { x = 10, y = 600000, z = 10 }, { x = -10, y = 600000, z = 10 }, { x = -10, y = 600000, z = -10 }, { x = 10, y = 600000, z = -10 } })
Q.survey(qr, function() return "regolith" end, nil, M.hardness)
local function profR(prog) return Q.profile(qr, prog, M) end

do
  local net = chain()
  local d, h, s = N.nodeOf(net, "drive"), N.nodeOf(net, "hopper"), N.nodeOf(net, "silo")
  net.nodes[d].profile = profR
  local st = N.newState(net)
  local R = N.rates(net, st)
  check(R.f[d] == 1, "an empty buffer: the quarry runs at its pace")
  local made = 0
  for _, v in pairs(R.prod[d]) do made = made + v end
  check(made > 0, string.format("it makes %.3f kg/s", made))
  -- one hour: the drive passes it on, the hopper → silo
  local rep = N.advance(net, st, 3600)
  check(sum(st.x[d]) < 1e-6, "the buffer passes everything on (the belt is faster than the quarry)")
  check(sum(st.x[h]) < 1e-6 and sum(st.x[s]) > 0, string.format("…and the hopper on to the silo: %.1f kg", sum(st.x[s])))
  check(st.prog[d] > 0, string.format("progress %.1f cells", st.prog[d]))
  -- what moved drive→hopper equals what the quarry made
  local mk = 0; for _, v in pairs(rep.made[d] or {}) do mk = mk + v end
  local mv = 0; for k, v in pairs(rep.moved) do if k:match("^" .. d .. "|" .. h .. "|") then mv = mv + v end end
  check(near(mk, mv, 1e-9), string.format("made %.3f = moved %.3f", mk, mv))
end

-- the silo takes one material; the hopper keeps the rest
do
  local net = chain()
  local h, s = N.nodeOf(net, "hopper"), N.nodeOf(net, "silo")
  local st = N.newState(net, { [h] = { iron = 100, regolith = 300 } })
  N.advance(net, st, 600)
  check(near(st.x[s].iron or 0, 100) and (st.x[s].regolith or 0) == 0, string.format("the silo took the iron (%.1f) and no regolith", st.x[s].iron or 0))
  check(near(st.x[h].regolith or 0, 300), "the regolith waits in the hopper")
  local lw = N.lineWhy(net, st, nil, net.lineOf.b4)
  check(lw and lw:find("takes only iron"), "the idle line says why: " .. tostring(lw))
  -- a silo set to regolith takes only regolith
  local n2 = chain({ siloMat = "regolith" })
  local st2 = N.newState(n2, { [h] = { iron = 100, regolith = 300 } })
  N.advance(n2, st2, 600)
  check(near(st2.x[s].regolith or 0, 300) and (st2.x[s].iron or 0) == 0, "a silo set to regolith takes the regolith")
end

-- the drain order: iron (by name) first, at the belt's 8 kg/s
do
  local P = { store("A", 0, 4000), belt("b", 1, 3), store("B", 4, 4000) }
  local net = N.build(P)
  local st = N.newState(net, { [1] = { iron = 40, regolith = 40 } })
  N.advance(net, st, 4)
  check(near(st.x[2].iron or 0, 32) and (st.x[2].regolith or 0) == 0, "iron goes first: 4 s × 8 kg/s")
  local rep = N.advance(net, st, 6)
  check(near(st.x[2].iron or 0, 40) and near(st.x[2].regolith or 0, 40), "then the regolith")
  check(rep.events[1] and rep.events[1].what == "empty", "the event: iron ran out")
end

-- a T merge: two lines into one belt
do
  local P = { store("A", 0, 4000, { ports = { 1 } }), store("B", 0, 4000, { ports = { 1 }, z = 4 }),
              { key = "a1", kind = "belt", cap = 8, ok = true, ports = { { x = 1, y = Y, z = 0, role = "in" }, { x = 3, y = Y, z = 0, role = "out" } } },
              { key = "t", kind = "belt", cap = 8, ok = true, ports = { { x = 3, y = Y, z = 0, role = "in" }, { x = 3, y = Y, z = 2, role = "in" }, { x = 5, y = Y, z = 0, role = "out" } } },
              { key = "b1", kind = "belt", cap = 8, ok = true, ports = { { x = 1, y = Y, z = 4, role = "in" }, { x = 3, y = Y, z = 2, role = "out" } } },
              store("C", 6, 4000, { ports = { -1 } }) }
  local net = N.build(P)
  check(#net.lines == 1 and #net.lines[1].ups == 2, "a T joins both into one line")
  local st = N.newState(net, { [1] = { iron = 1000 }, [2] = { silica = 1000 } })
  local R = N.rates(net, st)
  local q = 0
  for _, f in ipairs(R.flows) do q = q + f.q end
  check(near(q, 8), string.format("the merged line carries 8 kg/s, not 16 (%.2f)", q))
end

-- an unpowered line: the buffer fills, then the quarry stops, and says why
do
  local net = chain({ b2 = false })
  local d = N.nodeOf(net, "drive")
  net.nodes[d].profile = prof
  local st = N.newState(net)
  N.advance(net, st, 86400)
  check(near(sum(st.x[d]), 500, 1e-6), string.format("the buffer filled: %.2f kg", sum(st.x[d])))
  local p1 = st.prog[d]
  N.advance(net, st, 3600)
  check(near(st.prog[d], p1, 1e-9), "and the quarry stopped")
  local why = N.limitedBy(net, st, nil, d)
  check(why and why:find("no power"), "LIMITED BY: " .. tostring(why))
end

-- a chute fills a craft's hold, until it's full
do
  local net = chain({ chute = true })
  local h, c = N.nodeOf(net, "hopper"), N.nodeOf(net, "chute")
  local st = N.newState(net, { [h] = { regolith = 300 } })
  -- no craft under it: nothing goes that way
  N.advance(net, st, 10)
  local why = N.limitedBy(net, st, nil, c)
  check(why and why:find("no craft"), "no craft: " .. tostring(why))
  net.nodes[c].target = "hold:Probe"
  st.room[c] = 50
  local st0 = sum(st.x[h])
  local rep = N.advance(net, st, 60)
  local into = 0
  for k, v in pairs(rep.moved) do if k:match("|" .. c .. "|") then into = into + v end end
  check(near(into, 50), string.format("50 kg into the hold (%.2f)", into))
  check(st.room[c] == 0, "its room is 0")
  check((N.limitedBy(net, st, nil, c) or ""):find("full"), "LIMITED BY: the hold is full")
end

-- ── 3. closed form: a day in one call = 86,400 one-second calls ─────────────
do
  local function run(stepper)
    local net = chain({ chute = true })
    local d, h, c = N.nodeOf(net, "drive"), N.nodeOf(net, "hopper"), N.nodeOf(net, "chute")
    net.nodes[d].profile = prof
    net.nodes[c].target = "hold:X"
    local st = N.newState(net, { [h] = { silica = 120 } })
    st.room[c] = 900
    local moved = {}
    stepper(function(dt)
      local rep = N.advance(net, st, dt)
      for k, v in pairs(rep.moved) do moved[k] = (moved[k] or 0) + v end
    end)
    return st, moved, net
  end
  local A, mA, net = run(function(f) f(86400) end)
  local B, mB = run(function(f) for _ = 1, 86400 do f(1) end end)
  local ok, worst = true, 0
  for i in ipairs(net.nodes) do
    local ms = {}
    for m in pairs(A.x[i]) do ms[m] = true end
    for m in pairs(B.x[i]) do ms[m] = true end
    for m in pairs(ms) do
      local a, b = A.x[i][m] or 0, B.x[i][m] or 0
      worst = math.max(worst, math.abs(a - b))
      if not near(a, b, 1e-6) then ok = false end
    end
  end
  check(ok, string.format("the stores after a day: one call = 86,400 calls (worst %.2e kg)", worst))
  check(near(A.prog[1], B.prog[1], 1e-6), string.format("the quarry's progress (%.4f vs %.4f cells)", A.prog[1], B.prog[1]))
  local okm = true
  for k, v in pairs(mA) do if not near(v, mB[k] or 0, 1e-6) then okm = false end end
  check(okm, "what moved, line by line")
  check(near(A.room[N.nodeOf(net, "chute")], B.room[N.nodeOf(net, "chute")], 1e-6), "the hold's room")
end

-- ── 4. cost: 30 belts, 4 stores, stepped ────────────────────────────────────
do
  local P = { store("drive", 0, 500) }
  for k = 1, 30 do P[#P + 1] = belt("b" .. k, 1 + (k - 1) * 2, 1 + k * 2) end
  P[#P + 1] = store("hopper", 62, 4000)
  P[#P + 1] = belt("x1", 63, 65)
  P[#P + 1] = store("silo", 66, 8000, { one = true })
  local t0 = os.clock()
  local net
  for _ = 1, 20 do net = N.build(P) end
  local tb = (os.clock() - t0) / 20 * 1000
  net.nodes[1].profile = prof
  local st = N.newState(net)
  t0 = os.clock()
  for _ = 1, 500 do N.advance(net, st, 0.2) end
  local ts = (os.clock() - t0) / 500 * 1000
  check(tb < 5, string.format("building a 30-belt network: %.3f ms", tb))
  check(ts < 0.05, string.format("a 5 Hz step: %.4f ms", ts))
  print(string.format("  cost: build %.3f ms, step %.4f ms (30 belts, 3 stores, a quarry)", tb, ts))
end
Q.YIELD_K = saveK

-- ── 5. a run loads from the silo a chute filled from (routes.lua, X3) ──────
-- The chute moves units silo → hold with inventory.transfer, so the flight
-- log's ledger records the silo as the load's store: a PROBE run may load
-- there, and each cycle draws from the silo.
do
  local RT = load("routes.lua")
  local got = {}
  local led = {}
  RT.ledger(led, { from = "silo:4.9", to = "hold:Mule", mat = "soil", n = 25 }, function(c) return c == "hold:Mule" end,
    function(c) return c:sub(1, 5) == "crew:" end, function(mat, n, peer) got[#got + 1] = string.format("%+d %s %s", n, mat, peer) end)
  check(got[1] == "+25 soil silo:4.9", "the chute's transfer is a load from the silo: " .. tostring(got[1]))
  local L = RT.newLog({ sid = 7, uid = 1, body = "Home", name = "Mule", n = 7, fuel = 400, hold = {}, t = 0, home = true,
    intake = true, stand = { body = "Home", x = 1000, y = 0, z = 0 } })
  RT.addXfer(L, "dep", "soil", 25, "silo:4.9")
  L.tDep = 100
  RT.addStop(L, { body = "Home", x = 1000, y = 400, z = 0, t = 200, fuel = 380, home = true })
  L.stops[1].tL, L.stops[1].fuelL = 260, 380
  RT.addXfer(L, 1, "soil", -25, "crate:2")
  L.ended = { t = 500, fuel = 330, n = 7, cmd = true, hold = {}, sid = 7, uid = 1 }
  local run, why = RT.fromLog(L)
  check(run ~= nil, "a probe flight loaded by a chute from a silo is a run: " .. tostring(why))
  if run then
    local a = run.acts[1] and run.acts[1][1]
    check(a and a.op == "load" and a.src == "silo:4.9" and a.n == 25, "each cycle loads 25 from the silo as the dwell ends")
    local store = { ["silo:4.9"] = { soil = 10 }, ["hold:Mule"] = {} }
    local W = { count = function(c, m) return (store[c] or {})[m] or 0 end, room = function() return 1e9 end, label = function(m) return m end,
                storeName = function(c) return c == "silo:4.9" and "Silo 1" or c end }
    local ok, w = RT.guardAct(run, W, a)
    check(not ok and w:find("Silo 1") and w:find("10 of 25"), "a short silo makes it wait, and says so: " .. tostring(w))
  end
end

if #failures == 0 then
  print(string.format("smoke_item_net: %d checks passed", passed))
else
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_item_net: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
