-- SMOKE: logic and automation (sandbox S8; docs/base-building.md §18),
-- against the real logic, parts_kit, parts_base, kit_snap, base_cable,
-- base_power and logic_net on a stub engine.
--
--   * THE GATES: AND, OR, XOR, NOT, a pin with two cables ORs them, the
--     comparator on a sensor's value with hysteresis, the counter;
--   * TIMERS on game time: on-delay, off-delay, pulse, clock; an hour of warp
--     in one step equals 3,600 one-second steps (a counter on a clock counts
--     the same), and a delay that ends inside a long step ends at its time;
--   * PERSISTENCE: a latch, a counter, a lever and a timer half way through
--     its delay survive pack → unpack and a rebuild, and the timer ends when
--     it would have;
--   * LOOPS: a NOT fed back into itself is bounded (MAX_VISITS a call), flagged
--     and ticks once a call; a latch made of two gates settles; nothing hangs;
--     the order nodes are given in changes nothing;
--   * THE LADDER: rungs from text and back, NO/NC contacts, AND/OR, SET/RST,
--     an on-delay rung, the scan order, the editor's clicks, the screen text;
--   * RADIO: a receiver hears a transmitter on its channel, not another
--     channel, not past 2 km;
--   * THE SIGNAL CABLE: laid pin to pin, it starts and ends on its pins, hangs
--     and lies on the floor between, costs by the metre, comes up with its piece;
--   * THE EXAMPLES (the scene half on stubs): an auto-airlock run by a ladder
--     (a button starts the cycle, the doors interlocked, a lamp shows ready,
--     never both doors open), a low-O2 alarm that runs the O2 Generator,
--     reactor protection (SCRAM over temperature, the standby pump on low
--     flow, the beacon), day/night lights, load shedding on a low battery;
--     save and reload in the middle of it;
--   * COST: 200 gates switching under 0.2 ms; idle costs nothing.
--
--   luajit solar/tests/smoke_logic.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return a ~= nil and b ~= nil and math.abs(a - b) <= (e or 1e-6) end

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
local L = load_script("logic.lua", env({}, {}))

-- ── a pure network from a small description ─────────────────────────────────
local function N(key, kind, p, ins, outs) return { key = key, kind = kind, p = p or {}, ins = ins or {}, outs = outs or { "Q" } } end
local function Wr(a, ap, z, zp) return { a = a, ap = ap or "Q", z = z, zp = zp } end
local function make(nodes, wires)
  local net = L.build({ nodes = nodes, wires = wires })
  local st = L.newState()
  L.markAll(net)
  L.advance(net, st, 0)
  return net, st
end
local function q(st, k, pin) return (L.outOf(st, k, pin or "Q")) end

-- ── gates ───────────────────────────────────────────────────────────────────
do
  local nodes = { N("a", "lever"), N("b", "lever"), N("and", "and", {}, { "A", "B" }), N("or", "or", {}, { "A", "B" }),
                  N("xor", "xor", {}, { "A", "B" }), N("not", "not", {}, { "A" }) }
  local wires = { Wr("a", "Q", "and", "A"), Wr("b", "Q", "and", "B"), Wr("a", "Q", "or", "A"), Wr("b", "Q", "or", "B"),
                  Wr("a", "Q", "xor", "A"), Wr("b", "Q", "xor", "B"), Wr("a", "Q", "not", "A") }
  local net, st = make(nodes, wires)
  local ok = true
  for _, c in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
    L.setLever(net, st, "a", c[1]); L.setLever(net, st, "b", c[2]); L.evaluate(net, st, 1)
    ok = ok and q(st, "and") == (c[1] and c[2]) and q(st, "or") == (c[1] or c[2]) and q(st, "xor") == (c[1] ~= c[2]) and q(st, "not") == (not c[1])
  end
  check(ok, "AND, OR, XOR and NOT: their truth tables")
  -- two cables into one pin OR them
  local net2, st2 = make({ N("a", "lever"), N("b", "lever"), N("lamp", "lamp", {}, { "IN" }, {}) }, { Wr("a", "Q", "lamp", "IN"), Wr("b", "Q", "lamp", "IN") })
  L.setLever(net2, st2, "b", true); L.evaluate(net2, st2, 1)
  local b = L.inputOf(net2, st2, "lamp", "IN")
  local cmds = L.takeCommands(net2)
  check(b == true and #cmds >= 1 and cmds[#cmds].b == true, "a pin with two cables is their OR, and an output's change is queued as a command")
  -- comparator on a sensor's value, with hysteresis
  local net3, st3 = make({ N("s", "sensor", { set = 100, mode = "above" }), N("c", "cmp", { set = 0.9, mode = "below", hys = 0.05 }, { "A", "B" }) }, { Wr("s", "Q", "c", "A") })
  L.setValue(net3, st3, "s", 1.0); L.evaluate(net3, st3, 1); local c1 = q(st3, "c")
  L.setValue(net3, st3, "s", 0.85); L.evaluate(net3, st3, 2); local c2 = q(st3, "c")
  L.setValue(net3, st3, "s", 0.93); L.evaluate(net3, st3, 3); local c3 = q(st3, "c")
  L.setValue(net3, st3, "s", 0.96); L.evaluate(net3, st3, 4); local c4 = q(st3, "c")
  check(not c1 and c2 and c3 and not c4, "the comparator: on under 0.90, held on to 0.95 (hysteresis), off past it")
  -- a sensor's own setpoint
  local net4, st4 = make({ N("s", "sensor", { set = 19, mode = "below", hys = 0.3 }) }, {})
  L.setValue(net4, st4, "s", 21); L.evaluate(net4, st4, 1); local s1 = q(st4, "s")
  L.setValue(net4, st4, "s", 18.9); L.evaluate(net4, st4, 2); local s2 = q(st4, "s")
  L.setValue(net4, st4, "s", 19.2); L.evaluate(net4, st4, 3); local s3 = q(st4, "s")
  L.setValue(net4, st4, "s", 19.4); L.evaluate(net4, st4, 4); local s4 = q(st4, "s")
  local marked = L.setValue(net4, st4, "s", 19.5)
  check(not s1 and s2 and s3 and not s4 and not marked, "a sensor below 19 % with 0.3 of hysteresis; a reading that crosses nothing marks nothing")
  -- the counter
  local net5, st5 = make({ N("b", "button", { T = 1 }), N("r", "lever"), N("n", "counter", { n = 3 }, { "IN", "R" }) }, { Wr("b", "Q", "n", "IN"), Wr("r", "Q", "n", "R") })
  for k = 1, 3 do L.press(net5, st5, "b", k * 10); L.advance(net5, st5, k * 10 + 5) end
  local n3 = q(st5, "n")
  L.setLever(net5, st5, "r", true); L.evaluate(net5, st5, 40)
  check(n3 and not q(st5, "n") and select(2, L.outOf(st5, "n")) == 0, "the counter: three presses reach its preset of 3; R clears it")
end

-- ── timers on game time, across warp ────────────────────────────────────────
do
  local function timer_net(mode, T)
    return make({ N("i", "lever"), N("t", "timer", { mode = mode, T = T }, { "IN" }) }, { Wr("i", "Q", "t", "IN") })
  end
  local net, st = timer_net("on", 5)
  L.advance(net, st, 100); L.setLever(net, st, "i", true); L.evaluate(net, st, 100)
  L.advance(net, st, 104.9); local a = q(st, "t")
  L.advance(net, st, 105.0); local b = q(st, "t")
  check(not a and b, "on-delay: Q 5 s after IN, not before")
  net, st = timer_net("off", 5)
  L.setLever(net, st, "i", true); L.advance(net, st, 10); L.setLever(net, st, "i", false); L.evaluate(net, st, 10)
  L.advance(net, st, 14.9); a = q(st, "t"); L.advance(net, st, 15.1); b = q(st, "t")
  check(a and not b, "off-delay: Q holds 5 s after IN goes off")
  net, st = timer_net("pulse", 3)
  L.advance(net, st, 20); L.setLever(net, st, "i", true); L.evaluate(net, st, 20)
  L.advance(net, st, 22.9); a = q(st, "t"); L.advance(net, st, 23.1); b = q(st, "t")
  check(a and not b, "pulse: a 3 s pulse on IN's rising edge, even with IN held")
  -- a delay that ends inside a long warp step ends at its time: a latch it
  -- sets is set, and a second timer it starts runs from that moment
  local net2, st2 = make({ N("i", "lever"), N("t1", "timer", { mode = "on", T = 600 }, { "IN" }), N("t2", "timer", { mode = "on", T = 300 }, { "IN" }),
                           N("l", "latch", {}, { "S", "R" }) }, { Wr("i", "Q", "t1", "IN"), Wr("t1", "Q", "t2", "IN"), Wr("t2", "Q", "l", "S") })
  L.advance(net2, st2, 1000); L.setLever(net2, st2, "i", true); L.evaluate(net2, st2, 1000)
  L.advance(net2, st2, 1000 + 899); local l1 = q(st2, "l")
  L.advance(net2, st2, 1000 + 3600 * 5); local l2 = q(st2, "l")
  local net3, st3 = make({ N("i", "lever"), N("t1", "timer", { mode = "on", T = 600 }, { "IN" }), N("t2", "timer", { mode = "on", T = 300 }, { "IN" }),
                           N("l", "latch", {}, { "S", "R" }) }, { Wr("i", "Q", "t1", "IN"), Wr("t1", "Q", "t2", "IN"), Wr("t2", "Q", "l", "S") })
  L.advance(net3, st3, 1000); L.setLever(net3, st3, "i", true); L.evaluate(net3, st3, 1000)
  L.advance(net3, st3, 1000 + 901)
  check(not l1 and l2 and q(st3, "l"), "two delays in a chain under warp: 600 s + 300 s, the latch set at +900 s and not before, in one 5 h step")
  -- a clock and a counter: an hour in one step = 3,600 one-second steps
  local function clock_net()
    return make({ N("en", "lever"), N("clk", "timer", { mode = "clock", T = 10 }, { "IN" }), N("n", "counter", { n = 1000 }, { "IN", "R" }) },
      { Wr("en", "Q", "clk", "IN"), Wr("clk", "Q", "n", "IN") })
  end
  local na, sa = clock_net()
  L.setLever(na, sa, "en", true); L.advance(na, sa, 0)
  local rep = L.advance(na, sa, 3600)
  local nb, sb = clock_net()
  L.setLever(nb, sb, "en", true); L.advance(nb, sb, 0)
  for k = 1, 3600 do L.advance(nb, sb, k) end
  local ca, cb = select(2, L.outOf(sa, "n")), select(2, L.outOf(sb, "n"))
  check(ca == cb and ca == 361 and not rep.ff, string.format("a 10 s clock into a counter: an hour in one step counts %s, 3,600 steps %s (a rising edge at 0, 10 … 3,600 s)", tostring(ca), tostring(cb)))
  check(rep.events == 720, string.format("…in %d events, each evaluated at its own time", rep.events))
  -- past MAX_EVENTS a step fast-forwards and says so (bounded under any warp)
  local nc, sc = clock_net()
  L.setLever(nc, sc, "en", true); L.advance(nc, sc, 0)
  local rep2 = L.advance(nc, sc, 86400 * 30)
  check(rep2.ff and rep2.events <= L.MAX_EVENTS, string.format("30 days of a 10 s clock in one step: bounded (%d events) and flagged fast-forward", rep2.events))
end

-- ── persistence: pack → unpack, a rebuild ───────────────────────────────────
do
  local nodes = { N("s", "button", { T = 1 }), N("r", "lever"), N("l", "latch", {}, { "S", "R" }), N("lv", "lever"),
                  N("t", "timer", { mode = "on", T = 100 }, { "IN" }), N("n", "counter", { n = 9 }, { "IN", "R" }) }
  local wires = { Wr("s", "Q", "l", "S"), Wr("r", "Q", "l", "R"), Wr("lv", "Q", "t", "IN"), Wr("s", "Q", "n", "IN") }
  local net, st = make(nodes, wires)
  L.press(net, st, "s", 10); L.advance(net, st, 12)
  L.press(net, st, "s", 20); L.advance(net, st, 22)
  L.setLever(net, st, "lv", true); L.evaluate(net, st, 22)
  L.advance(net, st, 60)
  local packed = L.pack(st)
  -- (the save holds plain values a few tables deep: check none is deeper than a list of numbers)
  local deep = false
  for _, r in ipairs(packed) do for _, v in pairs(r) do if type(v) == "table" then for _, x in pairs(v) do if type(x) == "table" then deep = true end end end end end
  local st2 = L.unpack(packed, st.a)
  -- the nodes given in another order: the same network
  local rev = {}
  for k = #nodes, 1, -1 do rev[#rev + 1] = nodes[k] end
  local net2 = L.build({ nodes = rev, wires = wires })
  L.markAll(net2)
  L.advance(net2, st2, 60)
  local l, c, lv, t0 = q(st2, "l"), select(2, L.outOf(st2, "n")), st2.n.lv.lev, q(st2, "t")
  L.advance(net2, st2, 121.9); local t1 = q(st2, "t")
  L.advance(net2, st2, 122.1); local t2 = q(st2, "t")
  check(not deep and l and c == 2 and lv and not t0, "save and load: the latch still set, the counter at 2, the lever thrown, the timer still timing")
  check(not t1 and t2, "the 100 s delay begun at 22 s ends at 122 s across the reload")
end

-- ── loops: bounded, flagged, deterministic ──────────────────────────────────
do
  local net, st = make({ N("n", "not", {}, { "A" }) }, { Wr("n", "Q", "n", "A") })
  local rep = L.evaluate(net, st, 1)
  check(net.cyc[1] and net.loops == 1, "a NOT fed into itself is found as a loop")
  L.mark(net, "n")
  local rep2 = L.evaluate(net, st, 2)
  check(rep2.evals <= L.MAX_VISITS and net.osc[1] and net.ndirty == 1, string.format("it never settles: stopped at %d evaluations, flagged, carried to the next call", rep2.evals))
  local seen = {}
  for k = 1, 6 do L.evaluate(net, st, 2 + k); seen[#seen + 1] = q(st, "n") end
  check(#seen == 6, "…and every call returns (an oscillator ticks, as a redstone clock does)")
  -- an SR latch of two NOR gates (OR + NOT each) settles
  local nodes = { N("s", "lever"), N("r", "lever"), N("o1", "or", {}, { "A", "B" }), N("n1", "not", {}, { "A" }), N("o2", "or", {}, { "A", "B" }), N("n2", "not", {}, { "A" }) }
  local wires = { Wr("r", "Q", "o1", "A"), Wr("n2", "Q", "o1", "B"), Wr("o1", "Q", "n1", "A"), Wr("s", "Q", "o2", "A"), Wr("n1", "Q", "o2", "B"), Wr("o2", "Q", "n2", "A") }
  local n2, s2 = make(nodes, wires)
  L.setLever(n2, s2, "s", true); L.evaluate(n2, s2, 1); L.setLever(n2, s2, "s", false); local r = L.evaluate(n2, s2, 2)
  local set = q(s2, "n1")
  L.setLever(n2, s2, "r", true); L.evaluate(n2, s2, 3); L.setLever(n2, s2, "r", false); L.evaluate(n2, s2, 4)
  check(set and not q(s2, "n1") and r.osc == 0 and n2.loops == 4 and not next(n2.osc), "a latch of two NOR gates: a loop that settles, set by S, cleared by R")
  -- the same network in another order: the same answer
  local rev = {}
  for k = #nodes, 1, -1 do rev[#rev + 1] = nodes[k] end
  local n3 = L.build({ nodes = rev, wires = wires })
  local s3 = L.newState()
  L.markAll(n3); L.advance(n3, s3, 0)
  L.setLever(n3, s3, "s", true); L.evaluate(n3, s3, 1); L.setLever(n3, s3, "s", false); L.evaluate(n3, s3, 2)
  check(q(s3, "n1") == set and table.concat(n3.order, ",") == table.concat(n2.order, ","), "deterministic: the nodes sorted by key, the same order and result whatever order they came in")
end

-- ── the ladder ──────────────────────────────────────────────────────────────
do
  local r = L.parseRung("X1,0,AND,M2,1,SET,Y3,5")
  check(r.a == "X1" and not r.na and r.op == "AND" and r.b == "M2" and r.nb and r.k == "SET" and r.c == "Y3" and r.d == 5
        and L.rungString(r) == "X1,0,AND,M2,1,SET,Y3,5", "a rung from its text and back")
  check(L.explain(r) == "IF X1 AND NOT M2 THEN SET Y3 AFTER 5 s", "…explained: " .. L.explain(r))
  check(L.rungText(1, r):find("%[/M2%]") ~= nil and L.rungText(1, r):find("SET Y3") ~= nil, "…drawn: " .. L.rungText(1, r))
  local prog = { "X1,0,,,0,SET,M1,0", "X2,0,,,0,RST,M1,0", "M1,0,,,0,OUT,Y1,0", "X3,0,AND,M1,0,OUT,Y2,0", "X2,0,,,0,OUT,Y3,0", "X4,0,OR,X5,0,OUT,Y4,0",
                 "X6,0,,,0,OUT,Y5,10", "X7,1,,,0,OUT,Y6,0" }
  local plc = N("p", "plc", {}, { "X1", "X2", "X3", "X4", "X5", "X6", "X7", "X8" }, { "Y1", "Y2", "Y3", "Y4", "Y5", "Y6", "Y7", "Y8" })
  plc.prog = prog
  local nodes = { plc }
  local wires = {}
  for k = 1, 7 do nodes[#nodes + 1] = N("x" .. k, "lever"); wires[#wires + 1] = Wr("x" .. k, "Q", "p", "X" .. k) end
  local net, st = make(nodes, wires)
  local function y(k) return q(st, "p", "Y" .. k) end
  local y6 = y(6)
  L.setLever(net, st, "x1", true); L.evaluate(net, st, 1); L.setLever(net, st, "x1", false); L.evaluate(net, st, 2)
  local held = y(1) and not y(2)
  L.setLever(net, st, "x3", true); L.evaluate(net, st, 3)
  local both = y(2)
  L.setLever(net, st, "x2", true); L.evaluate(net, st, 4)
  check(y6 and held and both and not y(1) and y(3), "the ladder: X1 SETs M1 (Y1 follows and holds), X3 AND M1 → Y2, X2 RSTs it, an NC contact X7 is on with X7 off")
  L.setLever(net, st, "x5", true); L.evaluate(net, st, 5)
  check(y(4), "an OR rung")
  L.setLever(net, st, "x6", true); L.evaluate(net, st, 10)
  L.advance(net, st, 19.9); local d1 = y(5)
  L.advance(net, st, 20.05); local d2 = y(5)
  check(not d1 and d2, "a rung's 10 s delay on its condition, on game time")
  -- the editor's clicks
  local e = L.editRung(nil, "a")
  e = L.editRung(e, "a"); e = L.editRung(e, "na"); e = L.editRung(e, "op"); e = L.editRung(e, "k"); e = L.editRung(e, "d"); e = L.editRung(e, "c", true)
  check(e.a == "X2" and e.na and e.op == "AND" and e.b == "X2" and e.k == "SET" and e.d == 1 and e.c == nil,
    "the editor: a click steps a cell, Shift+click steps it back (a coil back to blank)")
  -- the PLC stopped: its outputs drop
  st.n.p.stop = true; L.mark(net, "p"); L.evaluate(net, st, 30)
  check(not y(4) and not y(5), "a stopped PLC drops its outputs")
end

-- ── the scene: logic_net on stubs ───────────────────────────────────────────
local function scene()
  local store = {}
  local SS = {}
  local agency = 5000.0
  local KITE = env({}, SS)
  SS.parts_kit = load_script("parts_kit.lua", KITE)
  SS.parts_base = load_script("parts_base.lua", env({}, SS))
  SS.kit_snap = load_script("kit_snap.lua", env({}, SS))
  SS.logic = L
  SS.base_cable = load_script("base_cable.lua", env({}, SS))
  SS.deployables = { agencyClock = function() return agency end }
  local money = { spent = 0 }
  SS.company = { spend = function(c) money.spent = money.spent + c; return true end, afford = function() return true end,
                 refund = function(c) money.spent = money.spent - c end }
  local recs, ver = {}, 1
  local function rec_of(id) for _, r in ipairs(recs) do if r.id == id then return r end end end
  SS.structures = {
    list = function() return recs end, get = rec_of,
    getPart = function(sid, uid) local r = rec_of(sid); for _, p in ipairs(r and r.bp or {}) do if p.uid == uid then return p end end end,
    partState = function(sid, uid) local r = rec_of(sid); return r and r.st and r.st[tostring(uid)] end,
    setPartState = function(sid, uid, t) local r = rec_of(sid); r.st = r.st or {}; r.st[tostring(uid)] = t; SS.structures.version = SS.structures.version + 1 end,
    version = 1,
  }
  SS.base_power = load_script("base_power.lua", env(store, SS))
  local E = env(store, SS, {
    space = { body = function(n)
                for _, b in ipairs(SS.__bodies or {}) do if b.name == n then return b end end
                return { x = 0, y = 0, z = 0, radius = 600000, mu = 9.81 * 600000 ^ 2, name = n } end,
              bodies = function() return SS.__bodies or {} end, dominant = function() return "Home" end },
  })
  local LN = load_script("logic_net.lua", E)
  SS.logic_net = LN
  local S = { E = E, LN = LN, SS = SS, store = store, recs = recs, money = money }
  function S.adv(dt, n)
    for _ = 1, (n or 1) do
      E.time = E.time + dt
      agency = agency + dt * (S.warp or 1)
      if S.pre then S.pre(dt) end
      LN.update(nil, dt)
    end
  end
  function S.agency() return agency end
  function S.setAgency(a) agency = a end
  return S
end
local function P(uid, id, x, y, z, yaw, pitch, roll) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0 } end
local H, Q = math.pi / 2, math.pi

-- ── the Signal Cable ────────────────────────────────────────────────────────
do
  local S = scene()
  -- a hab floor 6 x 2 m, a wall at each end, a button on one, a lamp on the other
  local bp = { P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0), P(3, "floor.steel", 4, 0, 0),
    P(4, "wall.steel", -1, 0.2, 0, H), P(5, "wall.steel", 5, 0.2, 0, H),
    -- (mounts on a wall face: pitch 90°; the button faces +X out of the west wall, the lamp −X out of the east)
    P(6, "liButton.steel", -0.9, 1.3, 0, H, H), P(7, "loLamp.steel", 4.9, 1.3, 0, -H, H) }
  S.recs[1] = { id = 1, b = "Home", x = 0, y = 600000, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp }
  S.adv(0.1, 5)
  local v = S.LN.validity(nil, { rec = S.recs[1], part = bp[6] }, "Home", { -0.85, 1.3, 0.05 })
  check(v.pin == "Q" and v.io == "out" and not v.bad, "the drum aimed at the button: its output pin Q")
  local pend = S.LN.makeOff(S.recs[1], bp[6], v.pin, v.io)
  local v2 = S.LN.validity(pend, { rec = S.recs[1], part = bp[7] }, "Home", { 4.85, 1.3, 0 })
  check(v2.pin == "IN" and not v2.bad and v2.len > 5.5 and v2.len < 7.5, string.format("…then the lamp's input IN: %.1f m quoted", v2.len or -1))
  local bad = S.LN.validity(pend, { rec = S.recs[1], part = bp[2] }, "Home")
  check(bad.bad ~= nil, "a floor has no terminals: " .. tostring(bad.bad))
  local id, why, q, len = S.LN.layWire(v2.a, v2.z, { ground = false })
  check(id ~= nil and q.total == math.ceil(len * 1.2) and S.money.spent == q.total, string.format("laid: %.2f m, $%d by the metre (%s)", len or -1, q and q.total or -1, tostring(why)))
  local pts = S.LN.pathOf(id)
  local ax, ay, az = S.LN.pinLocal(1, 6, "Q")
  local zx, zy, zz = S.LN.pinLocal(1, 7, "IN")
  local first, last = pts[1], pts[#pts]
  local lo = 9
  for _, p in ipairs(pts) do if p[2] < lo then lo = p[2] end end
  check(near(first[1], ax, 1e-3) and near(first[2], ay, 1e-3) and near(first[3], az, 1e-3) and near(last[1], zx, 1e-3) and near(last[2], zy, 1e-3) and near(last[3], zz, 1e-3),
    "the cable starts on the button's pin and ends on the lamp's, in the structure's frame")
  check(near(lo, 0.2 + 0.0045 + 0.004, 0.003) and #pts >= 4 and len > 6.0, string.format("it hangs from both and lies on the floor between (lowest %.3f m over the 0.2 m deck, %d points, %.2f m long)", lo, #pts, len))
  -- the network sees it: pressing the button lights the lamp
  S.adv(0.1, 5)
  S.LN.press(1, 6)
  S.adv(0.1, 2)
  local lit = S.LN.inp(1, 7, "IN")
  S.adv(0.1, 12)
  check(lit and not S.LN.inp(1, 7, "IN"), "pressed, the button's 1 s pulse reaches the lamp, then it's dark again")
  -- taken up with its piece; the money back within the minute
  for k, p in ipairs(bp) do if p.uid == 7 then table.remove(bp, k) end end
  S.SS.structures.version = S.SS.structures.version + 1
  S.adv(0.1, 5)
  check(#S.LN.wires() == 0 and S.money.spent == 0, "the lamp taken down takes its cable up, refunded within the minute")
end

-- ── the examples ────────────────────────────────────────────────────────────
-- One structure with every example on it, on stub rooms, doors, plant and grid.
local function examples(S0)
  local S = S0 or scene()
  local SS = S.SS
  local bp = {
    -- the airlock: outer Airlock Wall (3), inner Door Wall (9); a button outside, a lamp, the PLC
    P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0), P(3, "airlockWall.steel", -1, 0.2, 0, H), P(9, "doorWall.steel", 1, 0.2, 0, H),
    P(10, "liButton.steel", -1.2, 1.2, -0.8, -H, H), P(11, "loLamp.steel", -1.2, 1.6, -0.8, -H, H), P(12, "lgPlc.steel", 2.4, 0.2, 0.3, Q),
    -- the low-O2 alarm: a gas analyser, the O2 Generator, a beacon
    P(20, "lsGas.steel", 3.0, 1.5, -0.9, 0, H), P(21, "o2gen.steel", 3.5, 0.2, -0.5), P(22, "loAlarm.steel", 3.0, 2.0, -0.9, 0, H),
    -- reactor protection: by the plant's console and its pumps
    P(30, "reactorConsole.steel", 10, 0, 0), P(31, "coolantPump.steel", 12, 0, 0), P(32, "coolantPump.steel", 12, 0, 3),
    P(33, "lsTemp.steel", 11, 1.2, 1, 0, H), P(34, "lsFlow.steel", 12.5, 1.2, 1, 0, H), P(35, "lgOr.steel", 11, 1.5, 1.5, 0, H), P(36, "loAlarm.steel", 11, 2.2, 1.5, 0, H),
    -- day/night lights: a daylight sensor on the roof, two strip lights
    P(40, "lsDay.steel", 0, 2.6, 0), P(41, "lightFitting.steel", 0, 2.39, 0.5, 0, Q), P(42, "lightFitting.steel", 2, 2.39, 0.5, 0, Q),
    -- load shedding: a battery monitor, a breaker panel
    P(50, "lsPower.steel", 3.0, 1.2, 0.9, Q, H), P(51, "breaker63.steel", 3.4, 1.2, 0.9, Q, H),
  }
  local rec = { id = 1, b = "Home", x = 0, y = 600000, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp, st = {} }
  S.recs[1] = rec
  -- ── stubs ──
  local W = { doors = { [3] = 0, [9] = 0 }, want = {}, pc = 1.0, cycle = {}, machine = {}, lights = {}, pumps = { [31] = true, [32] = false }, scrams = 0, setp = {} }
  S.W = W
  SS.kit_live = { doorOpen = function(sid, uid) return W.doors[uid] or 0 end,
    setLight = function(sid, uid, on) W.lights[uid] = on; return true end }
  SS.room_air = {
    requestDoor = function(sid, uid) W.cycle[uid] = S.agency(); return true end,
    airlockReady = function(sid, uid)
      local other = (uid == 3) and 9 or 3
      if W.doors[other] > 0.02 then return false end
      local pT = (uid == 3) and 0.0 or 1.0
      return math.abs(W.pc - pT) <= 0.04
    end,
    setMachine = function(sid, uid, on) W.machine[uid] = on; return true end,
    state = function() return W.roomstate end, airOf = function() return W.air end,
  }
  -- (the gas analyser's room: room_air.state(sid).R and rooms.roomAt)
  W.air = { p = 1.0, o2 = 0.21, co2 = 0.0004 }
  W.roomstate = { R = {}, out = { p = 0, x = 0 } }
  SS.rooms = { roomAt = function(R, x, y, z) return { id = 1 } end }
  local plant = { sid = 1, uid = 30, o = { Tp = 557, Tf = 900, mpe = 4.0, P = 1.0, k = 1.0 }, S = { set = 1.0 } }
  S.plant = plant
  SS.reactor_plant = {
    plantOfPart = function() return plant end, keyOf = function(a, b) return a .. ":" .. b end,
    scram = function() W.scrams = W.scrams + 1; plant.S.scram = true; return true end,
    setPump = function(sid, uid, on) W.pumps[uid] = on; return true end,
    setPoint = function(k, s) W.setp[#W.setp + 1] = s; return true end,
  }
  local grid = { C = 100, stored = 80 }
  S.grid = grid
  SS.base_grid = { gridOfStruct = function() return { id = 1 } end, model = function() return { C = grid.C } end,
    status = function() return { stored = grid.stored } end, markDirty = function() end }
  SS.__bodies = { { name = "Sun", star = true, x = 0, y = 1e11, z = 0 } }
  -- the doors, as kit_live steps them: a crew member's wish, the logic's lock or hold, the airlock's gate
  function S.pre(dt)
    -- the chamber: pumped toward the door the airlock was last asked for (0.35 s a 0.1 atm, as a small one is)
    local tgt = nil
    for uid, t in pairs(W.cycle) do if S.agency() - t < 0.3 then tgt = uid end end
    if W.want[3] then tgt = 3 elseif W.want[9] then tgt = 9 end
    if tgt then
      local pT = (tgt == 3) and 0.0 or 1.0
      if W.doors[3] < 0.02 and W.doors[9] < 0.02 then W.pc = W.pc + math.max(-0.05, math.min(0.05, pT - W.pc)) end
    end
    for _, uid in ipairs({ 3, 9 }) do
      local want = W.want[uid] and 1 or 0
      local c = S.LN.doorCmd(1, uid)
      if c then if c.lock then want = 0 elseif c.open then want = 1 end end
      if want > 0 and not SS.room_air.airlockReady(1, uid) then want = 0 end
      if want > W.doors[uid] then W.doors[uid] = math.min(1, W.doors[uid] + dt) elseif want < W.doors[uid] then W.doors[uid] = math.max(0, W.doors[uid] - dt) end
      if W.doors[3] > 0.02 and W.doors[9] > 0.02 then W.both = true end
    end
  end
  S.adv(0.1, 4)
  -- ── the cables ──
  local LN = S.LN
  local function wire(a, ap, z, zp)
    local id, why = LN.layWire({ sid = 1, uid = a, pin = ap }, { sid = 1, uid = z, pin = zp }, { ground = false, free = true, noHistory = true })
    if not id then print("wire", a, ap, z, zp, why) end
    return id
  end
  -- airlock: the button → X1, the outer door's state → X2, its ready → X3, the inner door's state → X4;
  -- Y1 → the outer door's cycle, Y2 → the lamp, Y3 → the inner door's lock, Y4 → the outer door's lock
  wire(10, "Q", 12, "X1"); wire(3, "state", 12, "X2"); wire(3, "ready", 12, "X3"); wire(9, "state", 12, "X4")
  wire(12, "Y1", 3, "cycle"); wire(12, "Y2", 11, "IN"); wire(12, "Y3", 9, "lock"); wire(12, "Y4", 3, "lock")
  LN.setProgram(1, 12, {
    "X1,0,,,0,SET,M1,0",          -- 01 the button asks for a cycle out
    "X2,0,,,0,RST,M1,0",          -- 02 the outer door opened: served
    "M1,0,,,0,OUT,Y1,0",          -- 03 the cycle to the outer door while asked
    "X3,0,,,0,OUT,Y2,0",          -- 04 READY lamp: the chamber at the outside's pressure
    "X2,0,,,0,OUT,Y3,0",          -- 05 the outer door open: the inner one locked
    "X4,0,,,0,OUT,Y4,0",          -- 06 the inner door open: the outer one locked
  })
  -- low O2: the analyser (below 19 %) runs the generator and the beacon
  wire(20, "Q", 21, "run"); wire(20, "Q", 22, "IN")
  -- reactor protection: the primary over 600 K → SCRAM; its flow under 2 kg/s → the standby pump; either → the beacon
  LN.setParam(1, 33, "set", 600)
  wire(33, "Q", 30, "scram"); wire(34, "Q", 32, "run"); wire(33, "Q", 35, "A"); wire(34, "Q", 35, "B"); wire(35, "Q", 36, "IN")
  -- day/night: dark (under 5 %) → both lights on
  wire(40, "Q", 41, "on"); wire(40, "Q", 42, "on")
  -- load shedding: the battery's charge holds the breaker closed: on above
  -- 30 %, off under 25 % (its 5 % of hysteresis), so it sheds at 25 and recloses at 30
  LN.setParam(1, 50, "mode", "above")
  LN.setParam(1, 50, "set", 30)
  wire(50, "Q", 51, "close")
  S.adv(0.1, 6)
  return S
end

do
  local S = examples()
  local LN, W = S.LN, S.W
  check(#LN.wires() == 18 and LN.net() and #LN.net().N >= 18, string.format("the examples: %d cables, %d nodes on the network", #LN.wires(), LN.net() and #LN.net().N or -1))
  -- ── 1. the auto-airlock ──
  check(not LN.inp(1, 11, "IN") and not W.cycle[3], "the airlock at rest: the hab's air in the chamber, no cycle asked, the READY lamp dark")
  LN.press(1, 10)
  S.adv(0.1, 3)
  local asked = W.cycle[3] ~= nil and (S.agency() - W.cycle[3]) < 0.3
  local dark = not LN.inp(1, 11, "IN")
  S.adv(0.1, 30)
  local ready = LN.inp(1, 11, "IN")
  check(asked and dark and ready and W.pc < 0.05, string.format("the button starts the cycle: the chamber pumped down (%.2f atm), then the READY lamp lights", W.pc))
  -- the crew outside asks for the outer door: it opens; the inner one is locked meanwhile
  W.want[3] = true
  S.adv(0.1, 15)
  local innerLocked = LN.doorCmd(1, 9) and LN.doorCmd(1, 9).lock
  check(W.doors[3] > 0.99 and innerLocked, "the outer door opens for the crew; the ladder locks the inner door while it is open")
  -- the outer door open: the request served (M1 reset), the cycle no longer asked
  local m1 = LN.readout(1, 12).M[1]
  check(not m1 and not LN.out(1, 12, "Y1"), "the door opened: M1 reset by rung 02, the cycle no longer asked")
  -- they come in and the door shuts; then they ask for the inner one: the chamber pressurises, it opens
  W.want[3] = nil
  S.adv(0.1, 15)
  W.want[9] = true
  -- (the crew in the chamber asks the inner door: try it while the inner one is still locked? it's unlocked once the outer is shut)
  S.adv(0.1, 40)
  check(W.doors[9] > 0.99 and W.pc > 0.96 and not W.both, string.format("in, the outer door shut, the inner one opens once the chamber is back at %.2f atm · never both doors open", W.pc))
  -- the crew wants out again while the inner door is open: the outer one is locked by logic
  W.want[3] = true
  S.adv(0.1, 10)
  check(W.doors[3] < 0.02 and LN.doorCmd(1, 3) and LN.doorCmd(1, 3).lock, "with the inner door open the ladder locks the outer one (and room_air's interlock would too)")
  W.want = {}
  S.adv(0.1, 15)
  -- ── 2. low O2 ──
  W.air.o2 = 0.185
  S.adv(0.1, 5)
  local on = W.machine[21] == true and LN.inp(1, 22, "IN")
  W.air.o2 = 0.192
  S.adv(0.1, 5)
  local still = W.machine[21] == true
  W.air.o2 = 0.21
  S.adv(0.1, 5)
  check(on and still and W.machine[21] == false and not LN.inp(1, 22, "IN"), "low O2 (18.5 %): the O2 Generator runs and the beacon sounds; held to 19.3 %, off at 21 %")
  -- ── 3. reactor protection ──
  S.plant.o.mpe = 1.2
  S.adv(0.1, 5)
  check(W.pumps[32] == true and LN.inp(1, 36, "IN") and W.scrams == 0, "the primary's flow under 2 kg/s: the standby pump starts and the beacon sounds; no SCRAM for flow alone")
  S.plant.o.mpe = 4.0
  S.adv(0.1, 5)
  S.plant.o.Tp = 615
  S.adv(0.1, 5)
  S.adv(0.1, 5)
  check(W.scrams == 1 and LN.inp(1, 36, "IN"), "the primary over 600 K: SCRAM by logic, once (an edge), the beacon on")
  S.plant.o.Tp = 520
  S.adv(0.1, 5)
  check(W.scrams == 1 and not LN.inp(1, 36, "IN") and LN.out(1, 30, "tripped"), "cooled: the beacon stops; the console's tripped terminal reads the trip")
  -- ── 4. day and night ──
  local lnight = W.lights[41] == nil and W.lights[42] == nil
  S.SS.__bodies[1].y = -1e11            -- the sun under the horizon
  S.adv(0.1, 5)
  local dark2 = W.lights[41] == true and W.lights[42] == true
  S.SS.__bodies[1].y = 1e11
  S.adv(0.1, 5)
  check(dark2 and W.lights[41] == false and W.lights[42] == false, "the sun sets: both lights on; it rises: both off")
  -- ── 5. load shedding ──
  local BP = S.SS.base_power
  S.grid.stored = 20
  S.adv(0.1, 5)
  local shed = BP.breakerState(1, 51)
  S.grid.stored = 28
  S.adv(0.1, 5)
  local held = BP.breakerState(1, 51)
  S.grid.stored = 35
  S.adv(0.1, 5)
  local back = BP.breakerState(1, 51)
  check(shed == "open" and held == "open" and back == "closed", "the battery under 25 %: the breaker opened by logic; held open at 28 % (on above 30, off under 25), closed again at 35 %")
  BP.setBreaker(1, 51, false, "trip")
  S.grid.stored = 10
  S.adv(0.1, 5)
  S.grid.stored = 60
  S.adv(0.1, 5)
  check(BP.breakerState(1, 51) == "tripped", "a breaker that TRIPPED waits for a hand: logic never recloses it into a fault")
  BP.setBreaker(1, 51, true, "hand")
  S.adv(0.1, 5)

  -- ── timers under warp, in the scene ──
  do
    local bp = S.recs[1].bp
    bp[#bp + 1] = P(60, "liLever.steel", 6, 1.2, -0.9, 0, H)
    bp[#bp + 1] = P(61, "lgTimer.steel", 6.5, 1.2, -0.9, 0, H)
    bp[#bp + 1] = P(62, "lgLatch.steel", 7.0, 1.2, -0.9, 0, H)
    S.SS.structures.version = S.SS.structures.version + 1
    S.adv(0.1, 5)
    S.LN.setParam(1, 61, "T", 3600)
    S.LN.layWire({ sid = 1, uid = 60, pin = "Q" }, { sid = 1, uid = 61, pin = "IN" }, { ground = false, free = true, noHistory = true })
    S.LN.layWire({ sid = 1, uid = 61, pin = "Q" }, { sid = 1, uid = 62, pin = "S" }, { ground = false, free = true, noHistory = true })
    S.adv(0.1, 5)
    S.LN.setLever(1, 60, true)
    local t0 = S.agency()
    S.warp = 1000
    S.adv(0.1, 30)                    -- 3,000 s of game time
    local early = S.LN.out(1, 62, "Q")
    S.adv(0.1, 10)                    -- past 3,600
    S.warp = 1
    check(not early and S.LN.out(1, 62, "Q") and S.agency() - t0 > 3600, "an hour's on-delay under 1,000× warp: not at 3,000 s, done past 3,600 s, its latch set")
  end
  -- ── save and reload in the middle of it ──
  do
    -- the cycle asked (the PLC's M1 set), the latch set, a second hour's delay half run: saved
    LN.press(1, 10)
    S.adv(0.1, 3)
    LN.setLever(1, 60, false); S.adv(0.1, 2)
    LN.resetNode(1, 62)
    LN.setLever(1, 60, true); S.adv(0.1, 2)
    local t0 = S.agency()
    S.warp = 100
    S.adv(0.1, 180)                   -- 1,800 s of the 3,600
    S.warp = 1
    LN.saveNow()
    local tsave = S.agency()
    -- a new scene from the save alone: the same records and stub world
    local S3 = scene()
    for k, v in pairs(S.store) do S3.store[k] = v end
    S3.recs[1] = S.recs[1]
    S3.SS.kit_live, S3.SS.room_air, S3.SS.reactor_plant, S3.SS.base_grid, S3.SS.rooms = S.SS.kit_live, S.SS.room_air, S.SS.reactor_plant, S.SS.base_grid, S.SS.rooms
    S3.SS.__bodies = S.SS.__bodies
    S3.setAgency(tsave + 1000)        -- away for 1,000 s: 2,800 of the delay run
    S3.pre = S.pre
    S3.adv(0.1, 6)
    local L3 = S3.LN
    check(#L3.wires() == #LN.wires() and L3.readout(1, 12).M[1] == true and L3.cycling(1, 3),
      string.format("reloaded: %d cables; the PLC's M1 still set, so the airlock is still asked to cycle", #L3.wires()))
    local early = L3.out(1, 62, "Q")
    S3.setAgency(tsave + 1900)        -- past t0 + 3,600
    S3.adv(0.1, 3)
    check(L3.lever(1, 60) == true and not early and L3.out(1, 62, "Q") and S3.agency() - t0 > 3600,
      "…the lever where it was thrown, and the delay half run before the save ends at its time after it (caught up on load)")
    local p1, p2 = LN.pathOf(1), L3.pathOf(1)
    check(p1 and p2 and #p1 == #p2 and near(p1[2][2], p2[2][2], 1e-6), "…and every cable lies where it was laid")
  end
end

-- ── radio channels (the scene: range and channel) ───────────────────────────
do
  local S = scene()
  local bp = { P(1, "floor.steel", 0, 0, 0), P(2, "liLever.steel", 0, 1, 0, 0, H), P(3, "lwTx.steel", 0.5, 1, 0, 0, H) }
  S.recs[1] = { id = 1, b = "Home", x = 0, y = 600000, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp }
  S.recs[2] = { id = 2, b = "Home", x = 900, y = 600000, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = { P(1, "lwRx.steel", 0, 1, 0, 0, H) } }
  S.recs[3] = { id = 3, b = "Home", x = 0, y = 600000, z = 300, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = { P(1, "lwRx.steel", 0, 1, 0, 0, H) } }
  S.recs[4] = { id = 4, b = "Home", x = 2600, y = 600000, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = { P(1, "lwRx.steel", 0, 1, 0, 0, H) } }
  S.SS.structures.setPartState(3, 1, { lp = { ch = 2 } })
  S.adv(0.1, 5)
  S.LN.layWire({ sid = 1, uid = 2, pin = "Q" }, { sid = 1, uid = 3, pin = "IN" }, { ground = false, free = true, noHistory = true })
  S.adv(0.1, 5)
  S.LN.setLever(1, 2, true)
  S.adv(0.1, 3)
  check(S.LN.out(2, 1, "Q") == true and S.LN.out(3, 1, "Q") == false and S.LN.out(4, 1, "Q") == false,
    "radio: a receiver 900 m off on channel 1 hears it; one on channel 2 doesn't; one 2.6 km off doesn't")
  S.LN.setLever(1, 2, false)
  S.adv(0.1, 3)
  check(S.LN.out(2, 1, "Q") == false, "…and goes dark with it")
end

-- ── cost: 200 gates switching, and idle ─────────────────────────────────────
do
  local nodes, wires = { N("src", "lever") }, {}
  local prev = "src"
  for k = 1, 200 do
    local kind = (k % 4 == 0) and "not" or ((k % 4 == 1) and "or" or ((k % 4 == 2) and "and" or "xor"))
    local key = string.format("g%03d", k)
    nodes[#nodes + 1] = N(key, kind, {}, { "A", "B" })
    wires[#wires + 1] = Wr(prev, "Q", key, "A")
    if kind ~= "not" then wires[#wires + 1] = Wr("src", "Q", key, "B") end
    prev = key
  end
  local net, st = make(nodes, wires)
  local n, t0 = 200, os.clock()
  local evals = 0
  for k = 1, n do
    L.setLever(net, st, "src", k % 2 == 1)
    local rep = L.evaluate(net, st, k)
    evals = evals + rep.evals
  end
  local ms = (os.clock() - t0) * 1000 / n
  check(ms < 0.2 and evals / n > 150, string.format("200 gates switching: %.3f ms a change (%.0f gates evaluated each)", ms, evals / n))
  local t1 = os.clock()
  for k = 1, 10000 do L.evaluate(net, st, 1000 + k) end
  local idle = (os.clock() - t1) * 1000 / 10000
  check(idle < 0.002, string.format("idle: an evaluation with nothing changed costs %.5f ms", idle))
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_logic: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_logic: %d checks passed", passed))
