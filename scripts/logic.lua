-- LOGIC — the rulebook of a base's signals: sensors, gates, timers, latches,
-- counters, the ladder controller and the radio channels (sandbox plan S8,
-- work/sandbox/PLAN.md §3.4; docs/base-building.md §18). Pure: it loads in a
-- luajit test (tests/smoke_logic.lua); logic_net.lua is the scene half.
--
-- ── SIGNALS ─────────────────────────────────────────────────────────────────
-- Every output pin carries a boolean `b` and a value `v` (a sensor's reading,
-- a counter's count; a gate's v is 1 or 0). An input pin fed by several wires
-- is their OR (wired-OR, as redstone dust is), its value the largest.
--
-- ── THE NETWORK ─────────────────────────────────────────────────────────────
--   build(spec) → net    spec = { nodes = { { key, kind, p = params, ins,
--                        outs } … }, wires = { { a = key, ap = pin, z = key,
--                        zp = pin } … } }. The nodes are sorted by key, the
--                        strongly connected parts found (Tarjan), and the
--                        nodes ranked in topological order of the parts:
--                        one pass in rank order settles anything without a
--                        loop.
--   newState() → st      { a (agency time last stepped), n = { [key] = node
--                        state } }: everything that persists (a latch's q, a
--                        counter's count, a lever, a timer's clock, the
--                        ladder's relays). Kept across a rebuild by key.
--
-- ── EVALUATION (on change, never per frame) ─────────────────────────────────
--   mark(net, key)        a node's inputs or reading changed
--   evaluate(net, st, t)  the dirty nodes in rank order, their fan-out after
--                        them; a node's outputs that change dirty what it
--                        feeds. A LOOP (a part with a cycle) is iterated: a
--                        node is evaluated at most MAX_VISITS times a call,
--                        so a loop that never settles (a NOT fed back into
--                        itself) stops there, is flagged `osc`, and goes on at
--                        the next call: deterministic and bounded, like a
--                        redstone clock. Never an infinite loop.
--   advance(net, st, a)   the timed nodes' events (a timer's delay, a button's
--                        pulse, a ladder rung's delay) up to agency time a, in
--                        time order, each evaluated AT its own time: one call
--                        of any length equals any number of short ones (warp,
--                        a load's catch-up). At most MAX_EVENTS events a call;
--                        past that the clocks jump to their phase at a (a
--                        counter on a fast clock under heavy warp misses the
--                        edges beyond that, and says so in rep.ff).
--   takeCommands(net)     what the evaluation asked of the devices: { { key,
--                        pin, b, v } … } in order (a door held open, a pump
--                        run, a breaker opened), drained
--
-- ── NODE KINDS ──────────────────────────────────────────────────────────────
--   sensor    out Q: the reading against its setpoint (p.set, p.mode "above"
--             | "below", hysteresis p.hys); v the reading. Fed by setValue.
--   and or xor not   A, B → Q
--   timer     IN → Q: p.mode "on" (on-delay: Q after IN has been on T s),
--             "off" (off-delay: Q holds T s after IN goes off), "pulse" (a T s
--             pulse on IN's rising edge), "clock" (Q toggles every T/2 s while
--             IN is on); v the seconds left
--   latch     S, R → Q (R wins), held
--   cmp       A (its value) against B's value, or p.set with nothing on B:
--             p.mode "above" | "below", hysteresis p.hys
--   counter   IN's rising edges counted, R clears: Q while count ≥ p.n
--   button / keypad   Q a p.T s pulse when pressed (press), lever Q its
--             position (setLever)
--   tx / rx   a radio: rx's Q is the OR of every tx on its channel (the scene
--             adds the "air" wires between them)
--   plc       the LADDER CONTROLLER: X1–X8 in, Y1–Y8 out, M1–M8 relays,
--             16 rungs `IF a [AND|OR b] THEN coil [after d s]`, each contact
--             normally open or closed (NC), each coil OUT, SET or RST. A scan
--             runs the rungs top to bottom on the registers as they change
--             (a real PLC's scan); scans repeat until nothing changes (at
--             most PLC_SCANS a call, else flagged `osc`). A rung's delay is an
--             on-delay on its condition.
--   device    an existing piece's pins: its inputs are commands (queued for
--             the scene on change), its outputs its state (setOut)
--   lamp alarm   inputs only: commands
--
-- SAVE: pack(st) → a list of flat records (no table deeper than the save
-- holds), unpack(list, a) → st.

MAX_VISITS = 8
MAX_EVENTS = 2000
PLC_SCANS = 4
RUNGS = 16
REGS = 8
EPS = 1e-9

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- ── the network ─────────────────────────────────────────────────────────────
local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

function build(spec)
  local net = { N = {}, idx = {}, src = {}, fan = {}, rank = {}, order = {}, timed = {}, dirty = {}, ndirty = 0,
                cmd = {}, osc = {}, cyc = {}, analog = {}, wires = {} }
  local nodes = {}
  for _, n in ipairs(spec.nodes or {}) do nodes[#nodes + 1] = n end
  table.sort(nodes, function(a, b) return tostring(a.key) < tostring(b.key) end)
  for i, n in ipairs(nodes) do
    local node = { key = n.key, kind = n.kind, p = n.p or {}, ins = n.ins or {}, outs = n.outs or {}, label = n.label, prog = n.prog }
    if node.kind == "plc" and type(n.prog) == "table" then node.rungs = parseProgram(n.prog) end
    net.N[i] = node
    net.idx[n.key] = i
    net.src[i] = {}
    net.fan[i] = {}
    if TIMED[node.kind] then net.timed[#net.timed + 1] = i end
  end
  -- wires: a source pin feeds an input pin (both must exist; anything else is ignored and counted)
  local fanset = {}
  net.bad = 0
  for _, w in ipairs(spec.wires or {}) do
    local i, j = net.idx[w.a], net.idx[w.z]
    if i and j then
      local s = net.src[j][w.zp]
      if not s then s = {}; net.src[j][w.zp] = s end
      s[#s + 1] = { i, w.ap }
      fanset[i] = fanset[i] or {}
      if not fanset[i][j] then fanset[i][j] = true; net.fan[i][#net.fan[i] + 1] = j end
      net.wires[#net.wires + 1] = { a = i, ap = w.ap, z = j, zp = w.zp, id = w.id, air = w.air }
      local zk = net.N[j].kind
      if zk == "cmp" then net.analog[i] = true end
    else
      net.bad = net.bad + 1
    end
  end
  for i = 1, #net.N do table.sort(net.fan[i]) end
  -- the strongly connected parts (Tarjan), then their topological order
  local index, low, onstack, stack, comp = {}, {}, {}, {}, {}
  local nextIndex, ncomp = 0, 0
  local function strong(v)
    nextIndex = nextIndex + 1
    index[v], low[v] = nextIndex, nextIndex
    stack[#stack + 1] = v
    onstack[v] = true
    for _, w in ipairs(net.fan[v]) do
      if not index[w] then strong(w); if low[w] < low[v] then low[v] = low[w] end
      elseif onstack[w] and index[w] < low[v] then low[v] = index[w] end
    end
    if low[v] == index[v] then
      ncomp = ncomp + 1
      local size = 0
      while true do
        local w = table.remove(stack)
        onstack[w] = false
        comp[w] = ncomp
        size = size + 1
        if w == v then break end
      end
      net.compSize = net.compSize or {}
      net.compSize[ncomp] = size
    end
  end
  for v = 1, #net.N do if not index[v] then strong(v) end end
  -- Tarjan numbers the parts in reverse topological order
  for v = 1, #net.N do
    net.rank[v] = ncomp - comp[v] + 1
    local self = false
    for _, w in ipairs(net.fan[v]) do if w == v then self = true end end
    if (net.compSize[comp[v]] or 1) > 1 or self then net.cyc[v] = true end
  end
  for v = 1, #net.N do net.order[v] = v end
  table.sort(net.order, function(a, b) if net.rank[a] ~= net.rank[b] then return net.rank[a] < net.rank[b] end return a < b end)
  net.pos = {}
  for k, v in ipairs(net.order) do net.pos[v] = k end
  net.loops = 0
  for v = 1, #net.N do if net.cyc[v] then net.loops = net.loops + 1 end end
  return net
end

function newState() return { a = nil, n = {} } end
function nodeState(st, key)
  local s = st.n[key]
  if not s then s = { o = {}, v = {}, ib = {} }; st.n[key] = s end
  s.o, s.v, s.ib = s.o or {}, s.v or {}, s.ib or {}
  return s
end

function mark(net, key)
  local i = net.idx[key]
  if i and not net.dirty[i] then net.dirty[i] = true; net.ndirty = net.ndirty + 1 end
  return i ~= nil
end
function markAll(net) for i = 1, #net.N do if not net.dirty[i] then net.dirty[i] = true; net.ndirty = net.ndirty + 1 end end end

-- an input pin now: b (OR of its sources), v (their largest value), n (wired?)
local function input(net, st, i, pin)
  local s = net.src[i][pin]
  if not s then return false, nil, 0 end
  local b, v = false, nil
  for _, e in ipairs(s) do
    local ns = st.n[net.N[e[1]].key]
    if ns then
      if ns.o[e[2]] then b = true end
      local x = ns.v[e[2]]
      if x ~= nil and (v == nil or x > v) then v = x end
    end
  end
  return b, v, #s
end
inputOf = function(net, st, key, pin) local i = net.idx[key]; if not i then return nil end return input(net, st, i, pin) end

-- ── the kinds ───────────────────────────────────────────────────────────────
TIMED = { timer = true, button = true, keypad = true, plc = true }

local function set_out(S, pin, b, v)
  local ch = (S.o[pin] or false) ~= b or S.v[pin] ~= v
  S.o[pin], S.v[pin] = b, v
  return ch
end

-- a reading against a setpoint, with hysteresis (state q)
function compare(v, q, set, mode, hys)
  if v == nil then return false end
  hys = math.abs(hys or 0)
  if mode == "below" then
    if q then return v < set + hys end
    return v < set
  end
  if q then return v > set - hys end
  return v > set
end

local EV = {}
EV.sensor = function(net, st, i, S, t)
  local N = net.N[i]
  local q = compare(S.raw, S.o.Q, tonumber(N.p.set) or 0, N.p.mode, N.p.hys)
  return set_out(S, "Q", q, S.raw)
end
EV.device = function(net, st, i, S, t)
  local N = net.N[i]
  local ch = false
  for _, pin in ipairs(N.ins) do
    local b, v, n = input(net, st, i, pin)
    if n > 0 and (S.ib[pin] == nil or S.ib[pin] ~= b) then
      S.ib[pin] = b
      net.cmd[#net.cmd + 1] = { key = N.key, pin = pin, b = b, v = v }
    elseif n == 0 and S.ib[pin] ~= nil then
      -- (the wire taken up: the command lets go)
      S.ib[pin] = nil
      net.cmd[#net.cmd + 1] = { key = N.key, pin = pin, b = nil, free = true }
    end
  end
  for _, pin in ipairs(N.outs) do
    local d = S.dev and S.dev[pin]
    if d ~= nil then if set_out(S, pin, d == true, d == true and 1 or 0) then ch = true end end
  end
  return ch
end
EV.lamp = EV.device
EV.alarm = EV.device
local function gate2(f)
  return function(net, st, i, S, t)
    local a = input(net, st, i, "A")
    local b = input(net, st, i, "B")
    local q = f(a, b)
    return set_out(S, "Q", q, q and 1 or 0)
  end
end
EV["and"] = gate2(function(a, b) return a and b end)
EV["or"] = gate2(function(a, b) return a or b end)
EV.xor = gate2(function(a, b) return a ~= b end)
EV["not"] = function(net, st, i, S, t)
  local a = input(net, st, i, "A")
  return set_out(S, "Q", not a, a and 0 or 1)
end
EV.latch = function(net, st, i, S, t)
  local s, r = input(net, st, i, "S"), input(net, st, i, "R")
  if r then S.q = false elseif s then S.q = true end
  local q = S.q == true
  return set_out(S, "Q", q, q and 1 or 0)
end
EV.cmp = function(net, st, i, S, t)
  local N = net.N[i]
  local _, va = input(net, st, i, "A")
  local _, vb, nb = input(net, st, i, "B")
  local set = (nb > 0 and vb ~= nil) and vb or (tonumber(N.p.set) or 0)
  local q = compare(va, S.o.Q, set, N.p.mode, N.p.hys)
  return set_out(S, "Q", q, va or 0)
end
EV.counter = function(net, st, i, S, t)
  local N = net.N[i]
  local x = input(net, st, i, "IN")
  local r = input(net, st, i, "R")
  if r then S.c = 0
  elseif x and not S.pin then S.c = (S.c or 0) + 1 end
  S.pin = x
  local n = S.c or 0
  local q = n >= (tonumber(N.p.n) or 1)
  return set_out(S, "Q", q, n)
end
EV.timer = function(net, st, i, S, t)
  local N = net.N[i]
  local T = math.max(0, tonumber(N.p.T) or 1)
  local x = input(net, st, i, "IN")
  local mode = N.p.mode or "on"
  local q, left = false, 0
  S.due = nil
  if mode == "on" then
    if x then
      S.since = S.since or t
      q = t - S.since >= T - EPS
      if not q then S.due = S.since + T; left = S.due - t end
    else S.since = nil end
  elseif mode == "off" then
    if x then S.since = nil; q = true
    else
      if S.o.Q and not S.since then S.since = t end
      if S.since then
        q = t - S.since < T - EPS
        if q then S.due = S.since + T; left = S.due - t else S.since = nil end
      end
    end
  elseif mode == "pulse" then
    if x and not S.pin then S.till = t + T end
    if S.till and t < S.till - EPS then q = true; S.due = S.till; left = S.till - t else S.till = nil end
  elseif mode == "clock" then
    local h = math.max(T / 2, 0.05)
    if x then
      S.since = S.since or t
      local k = math.floor((t - S.since) / h + EPS)
      q = k % 2 == 0
      S.due = S.since + (k + 1) * h
      left = S.due - t
    else S.since = nil end
  end
  S.pin = x
  return set_out(S, "Q", q, left)
end
local function pulse(net, st, i, S, t)
  local q = S.till ~= nil and t < S.till - EPS
  S.due = q and S.till or nil
  if not q then S.till = nil end
  return set_out(S, "Q", q, q and 1 or 0)
end
EV.button = pulse
EV.keypad = pulse
EV.lever = function(net, st, i, S, t)
  local q = S.lev == true
  return set_out(S, "Q", q, q and 1 or 0)
end
EV.tx = function(net, st, i, S, t)
  local b, v = input(net, st, i, "IN")
  return set_out(S, "air", b, v or (b and 1 or 0))
end
EV.rx = function(net, st, i, S, t)
  local b, v = input(net, st, i, "air")
  return set_out(S, "Q", b, v or (b and 1 or 0))
end

-- ── the ladder (PLC) ────────────────────────────────────────────────────────
-- A rung as text: "a,na,op,b,nb,k,c,d" (contact a, NC?, AND|OR|"", contact b,
-- NC?, the coil's kind OUT|SET|RST, the coil, its delay s). "" = blank.
REFS = {}
for _, p in ipairs({ "X", "Y", "M" }) do for k = 1, REGS do REFS[#REFS + 1] = p .. k end end
COILS = {}
for _, p in ipairs({ "Y", "M" }) do for k = 1, REGS do COILS[#COILS + 1] = p .. k end end
KINDS = { "OUT", "SET", "RST" }
OPS = { "", "AND", "OR" }
DELAYS = { 0, 1, 2, 5, 10, 30, 60, 300 }
local function is_ref(s) return type(s) == "string" and s:match("^[XYM][1-8]$") ~= nil end
local function is_coil(s) return type(s) == "string" and s:match("^[YM][1-8]$") ~= nil end
function parseRung(s)
  local r = { a = nil, na = false, op = "", b = nil, nb = false, k = "OUT", c = nil, d = 0 }
  if type(s) ~= "string" or s == "" then return r end
  local f = {}
  for x in (s .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  r.a = is_ref(f[1]) and f[1] or nil
  r.na = f[2] == "1"
  r.op = (f[3] == "AND" or f[3] == "OR") and f[3] or ""
  r.b = is_ref(f[4]) and f[4] or nil
  r.nb = f[5] == "1"
  r.k = (f[6] == "SET" or f[6] == "RST") and f[6] or "OUT"
  r.c = is_coil(f[7]) and f[7] or nil
  r.d = math.max(0, tonumber(f[8]) or 0)
  return r
end
function rungString(r)
  if not r or (not r.a and not r.c) then return "" end
  return table.concat({ r.a or "", r.na and "1" or "0", r.op or "", r.b or "", r.nb and "1" or "0", r.k or "OUT", r.c or "", tostring(r.d or 0) }, ",")
end
function parseProgram(list)
  local out = {}
  for k = 1, RUNGS do out[k] = parseRung(list and list[k]) end
  return out
end
function programStrings(rungs)
  local out = {}
  for k = 1, RUNGS do out[k] = rungString(rungs[k]) end
  return out
end
function rungActive(r) return r ~= nil and r.a ~= nil and r.c ~= nil end

local function reg(S, X, ref)
  local p, k = ref:sub(1, 1), tonumber(ref:sub(2))
  if p == "X" then return X[k] == true end
  local t = (p == "Y") and S.Y or S.M
  return t[k] == true
end
local function contact(S, X, ref, nc)
  if not ref then return nil end
  local v = reg(S, X, ref)
  if nc then return not v end
  return v
end
-- one scan of the rungs. → changed (a register moved)
local function scan(rungs, S, X, t)
  local changed = false
  S.re = S.re or {}
  for k = 1, RUNGS do
    local r = rungs[k]
    if rungActive(r) then
      local a = contact(S, X, r.a, r.na)
      local cond = a
      if r.op ~= "" and r.b then
        local b = contact(S, X, r.b, r.nb)
        if r.op == "AND" then cond = a and b else cond = a or b end
      end
      -- the rung's on-delay
      local live = cond
      if r.d and r.d > 0 then
        S.rt = S.rt or {}
        if cond then
          S.rt[k] = S.rt[k] or t
          live = t - S.rt[k] >= r.d - EPS
        else S.rt[k] = nil; live = false end
      elseif S.rt then S.rt[k] = nil end
      S.re[k] = live
      local p, n = r.c:sub(1, 1), tonumber(r.c:sub(2))
      local tab = (p == "Y") and S.Y or S.M
      local was = tab[n] == true
      local now_
      if r.k == "SET" then now_ = was or live
      elseif r.k == "RST" then now_ = was and not live
      else now_ = live end
      if now_ ~= was then tab[n] = now_ or nil; changed = true end
    else
      S.re[k] = nil
    end
  end
  return changed
end
EV.plc = function(net, st, i, S, t)
  local N = net.N[i]
  S.Y, S.M = S.Y or {}, S.M or {}
  local X = {}
  for k = 1, REGS do X[k] = (input(net, st, i, "X" .. k)) end
  S.X = X
  local rungs = N.rungs or parseProgram(nil)
  if S.stop then
    for k = 1, REGS do S.Y[k] = nil end
  else
    local n = 0
    while n < PLC_SCANS do
      n = n + 1
      if not scan(rungs, S, X, t) then break end
      if n == PLC_SCANS then S.unsettled = true end
    end
  end
  -- the next rung delay that will come due
  S.due = nil
  for k = 1, RUNGS do
    local r = rungs[k]
    if rungActive(r) and r.d > 0 and S.rt and S.rt[k] and not S.re[k] then
      local d = S.rt[k] + r.d
      if d > t + EPS and (not S.due or d < S.due) then S.due = d end
    end
  end
  local ch = false
  for k = 1, REGS do if set_out(S, "Y" .. k, S.Y[k] == true, S.Y[k] and 1 or 0) then ch = true end end
  return ch
end

-- ── evaluation ──────────────────────────────────────────────────────────────
-- → rep { evals, passes, osc (nodes stopped at MAX_VISITS) }
function evaluate(net, st, t, rep)
  rep = rep or { evals = 0, passes = 0, osc = 0 }
  if net.ndirty <= 0 then return rep end
  local visits = {}
  local deferred = {}
  local guard = 0
  while net.ndirty > 0 and guard < MAX_VISITS + 2 do
    guard = guard + 1
    rep.passes = rep.passes + 1
    for k = 1, #net.order do
      local i = net.order[k]
      if net.dirty[i] then
        net.dirty[i] = nil
        net.ndirty = net.ndirty - 1
        local v = (visits[i] or 0) + 1
        visits[i] = v
        if v > MAX_VISITS then
          deferred[#deferred + 1] = i
        else
          local N = net.N[i]
          local S = nodeState(st, N.key)
          local f = EV[N.kind]
          local ch = f and f(net, st, i, S, t) or false
          rep.evals = rep.evals + 1
          if N.kind == "plc" and S.unsettled then S.unsettled = nil; deferred[#deferred + 1] = i; net.osc[i] = true end
          if ch then
            for _, j in ipairs(net.fan[i]) do
              if not net.dirty[j] then net.dirty[j] = true; net.ndirty = net.ndirty + 1 end
            end
          end
        end
      end
    end
  end
  -- what didn't settle goes on at the next call (bounded: an oscillator ticks
  -- once a call, as a redstone clock does)
  for _, i in ipairs(deferred) do
    net.osc[i] = true
    if not net.dirty[i] then net.dirty[i] = true; net.ndirty = net.ndirty + 1 end
  end
  if #deferred == 0 then
    for i in pairs(net.osc) do if visits[i] then net.osc[i] = nil end end
  end
  rep.osc = #deferred
  return rep
end

-- the earliest timed event: → t, i | nil
function nextDue(net, st)
  local best, bi = nil, nil
  for _, i in ipairs(net.timed) do
    local S = st.n[net.N[i].key]
    local d = S and S.due
    if d and (not best or d < best or (d == best and i < bi)) then best, bi = d, i end
  end
  return best, bi
end

-- Step to agency time a: every timed event in order, evaluated at its own
-- time, then whatever is dirty at a. → rep
function advance(net, st, a, rep)
  rep = rep or { evals = 0, passes = 0, osc = 0, events = 0, ff = false }
  local t0 = st.a or a
  if a < t0 then a = t0 end
  evaluate(net, st, t0, rep)
  while true do
    local tn, i = nextDue(net, st)
    if not tn or tn > a + EPS then break end
    if rep.events >= MAX_EVENTS then
      -- (fast-forward: the clocks and pulses jump to their state at a)
      rep.ff = true
      for _, j in ipairs(net.timed) do
        local S = st.n[net.N[j].key]
        if S and S.due and S.due <= a + EPS then mark(net, net.N[j].key) end
      end
      evaluate(net, st, a, rep)
      break
    end
    rep.events = rep.events + 1
    mark(net, net.N[i].key)
    evaluate(net, st, math.max(tn, t0), rep)
  end
  evaluate(net, st, a, rep)
  st.a = a
  return rep
end

function takeCommands(net)
  local c = net.cmd
  net.cmd = {}
  return c
end

-- ── inputs from the scene ───────────────────────────────────────────────────
-- A sensor's reading (or nil: nothing to read). Marks the node only when its
-- output would change, or its value feeds a comparator. → changed?
function setValue(net, st, key, v)
  local i = net.idx[key]
  if not i then return false end
  local N = net.N[i]
  local S = nodeState(st, key)
  local was = S.raw
  S.raw = v
  local q = compare(v, S.o.Q, tonumber(N.p.set) or 0, N.p.mode, N.p.hys)
  if q ~= (S.o.Q or false) then mark(net, key) return true end
  if net.analog[i] and v ~= was and (v == nil or was == nil or math.abs(v - was) > 1e-6 * math.max(1, math.abs(v))) then
    mark(net, key)
    return true
  end
  S.v.Q = v
  return false
end
-- A device's state pin (a door open, a breaker tripped). → changed?
function setOut(net, st, key, pin, b)
  local S = nodeState(st, key)
  S.dev = S.dev or {}
  if S.dev[pin] == b then return false end
  S.dev[pin] = b
  return mark(net, key)
end
-- A button or keypad pressed at agency time t (its pulse p.T s).
function press(net, st, key, t)
  local i = net.idx[key]
  if not i then return false end
  local S = nodeState(st, key)
  S.till = t + math.max(0.05, tonumber(net.N[i].p.T) or 1.0)
  S.due = S.till
  mark(net, key)
  return true
end
function setLever(net, st, key, on)
  local S = nodeState(st, key)
  if (S.lev == true) == (on == true) then return false end
  S.lev = on == true or nil
  return mark(net, key)
end
function resetLatch(net, st, key)
  local S = nodeState(st, key)
  S.q, S.c = nil, nil
  return mark(net, key)
end
-- the value on an output pin now: b, v
function outOf(st, key, pin)
  local S = st.n[key]
  if not S then return false, nil end
  return S.o[pin or "Q"] == true, S.v[pin or "Q"]
end

-- ── the save: flat records, lists only ──────────────────────────────────────
local function bits(t)
  if not t then return "" end
  local s = {}
  for k = 1, REGS do s[k] = t[k] and "1" or "0" end
  return table.concat(s)
end
local function unbits(s)
  local t = {}
  if type(s) ~= "string" then return t end
  for k = 1, math.min(REGS, #s) do if s:sub(k, k) == "1" then t[k] = true end end
  return t
end
local function pins_str(o)
  local s = {}
  for _, k in ipairs(sorted_keys(o or {})) do if o[k] then s[#s + 1] = k end end
  return table.concat(s, " ")
end
local function str_pins(s)
  local o = {}
  if type(s) == "string" then for k in s:gmatch("%S+") do o[k] = true end end
  return o
end
function pack(st)
  local out = {}
  for _, key in ipairs(sorted_keys(st.n)) do
    local S = st.n[key]
    local r = { k = key, o = pins_str(S.o), q = S.q and true or nil, c = S.c, since = S.since, till = S.till, pin = S.pin and true or nil,
                lev = S.lev and true or nil, raw = S.raw, Y = S.Y and bits(S.Y) or nil, M = S.M and bits(S.M) or nil,
                ib = (S.ib and next(S.ib)) and pins_str(S.ib) or nil, ibf = nil, dev = (S.dev and next(S.dev)) and pins_str(S.dev) or nil, stop = S.stop }
    -- (an input pin applied low is remembered too: "pin=0")
    if S.ib then
      local lows = {}
      for _, k in ipairs(sorted_keys(S.ib)) do if S.ib[k] == false then lows[#lows + 1] = k end end
      if #lows > 0 then r.ibf = table.concat(lows, " ") end
    end
    if S.rt then
      local rt = {}
      for k = 1, RUNGS do rt[k] = S.rt[k] or -1 end
      r.rt = rt
    end
    out[#out + 1] = r
  end
  return out
end
function unpack(list, a)
  local st = newState()
  st.a = tonumber(a)
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if type(r) == "table" and r.k then
      local S = { o = str_pins(r.o), v = {}, ib = {} }
      for k in pairs(S.o) do S.v[k] = 1 end
      S.q, S.c, S.since, S.till, S.pin, S.lev, S.raw = r.q or nil, tonumber(r.c), tonumber(r.since), tonumber(r.till), r.pin or nil, r.lev or nil, tonumber(r.raw)
      if r.raw ~= nil then S.v.Q = tonumber(r.raw) end
      if r.Y then S.Y = unbits(r.Y) end
      if r.M then S.M = unbits(r.M) end
      for k in pairs(str_pins(r.ib)) do S.ib[k] = true end
      for k in pairs(str_pins(r.ibf)) do S.ib[k] = false end
      if r.dev then S.dev = {}; for k in pairs(str_pins(r.dev)) do S.dev[k] = true end end
      S.stop = r.stop or nil
      if type(r.rt) == "table" then
        S.rt = {}
        for k = 1, RUNGS do local x = tonumber(r.rt[k]); if x and x >= 0 then S.rt[k] = x end end
      end
      -- (a timed node's next event, worked out again from its clock at the first evaluation)
      if S.till then S.due = S.till end
      st.n[r.k] = S
    end
  end
  return st
end

-- ── the ladder as text (the console's screen, the editor) ──────────────────
local function cell(ref, nc, lit)
  if not ref then return "--------" end
  local s = nc and ("[/" .. ref .. "]") or ("[ " .. ref .. "]")
  return "-" .. s .. "-" .. ((#s < 6) and "-" or "")
end
-- one rung: "01 -[ X1]---AND-[/M2]-----(SET Y1) 5s"
function rungText(k, r)
  local n = string.format("%02d ", k)
  if not rungActive(r) then return n .. "-----------------------------------" end
  local s = n .. cell(r.a, r.na)
  if r.op ~= "" and r.b then s = s .. (r.op == "AND" and "AND" or "OR-") .. cell(r.b, r.nb)
  else s = s .. "-----------" end
  local coil = (r.k == "OUT") and string.format("( %s )", r.c) or string.format("(%s %s)", r.k, r.c)
  s = s .. "---" .. coil
  if (r.d or 0) > 0 then s = s .. string.format(" %ds", r.d) end
  return s
end
function explain(r)
  if not rungActive(r) then return "blank" end
  local function c(ref, nc) return (nc and "NOT " or "") .. ref end
  local cond = c(r.a, r.na)
  if r.op ~= "" and r.b then cond = cond .. " " .. r.op .. " " .. c(r.b, r.nb) end
  local verb = (r.k == "SET") and "SET" or ((r.k == "RST") and "RESET" or "ENERGISE")
  return string.format("IF %s THEN %s %s%s", cond, verb, r.c, (r.d or 0) > 0 and string.format(" AFTER %d s", r.d) or "")
end

-- step a value through a list (the editor's clicks): → the next (or previous)
function cycle(list, v, back)
  local n = #list
  local at = 0
  for k, x in ipairs(list) do if x == v then at = k end end
  if back then at = at - 1; if at < 1 then at = n end
  else at = at + 1; if at > n then at = 1 end end
  return list[at]
end
-- the editor's cells: what a click on field f of rung r does. → the rung, changed
function editRung(r, f, back)
  r = r or parseRung(nil)
  local refs = { false }
  for _, x in ipairs(REFS) do refs[#refs + 1] = x end
  if f == "a" then
    local v = cycle(refs, r.a or false, back); r.a = v or nil
    if r.a and not r.c then r.c = "Y1" end
  elseif f == "na" then r.na = not r.na
  elseif f == "op" then r.op = cycle(OPS, r.op or "", back); if r.op ~= "" and not r.b then r.b = "X2" end
  elseif f == "b" then local v = cycle(refs, r.b or false, back); r.b = v or nil; if not r.b then r.op = "" elseif r.op == "" then r.op = "AND" end
  elseif f == "nb" then r.nb = not r.nb
  elseif f == "k" then r.k = cycle(KINDS, r.k or "OUT", back)
  elseif f == "c" then
    local coils = { false }
    for _, x in ipairs(COILS) do coils[#coils + 1] = x end
    local v = cycle(coils, r.c or false, back); r.c = v or nil
  elseif f == "d" then r.d = cycle(DELAYS, r.d or 0, back)
  elseif f == "clear" then r = parseRung(nil)
  end
  return r
end
