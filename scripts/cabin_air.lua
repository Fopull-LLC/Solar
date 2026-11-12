-- CABIN AIR — the air in a craft's closed crew parts (scenarios2 PLAN §2 G1;
-- docs/crew-and-items.md §13). Ty 2026-11-10: wanted for Hard Vacuum, long
-- flights, and the walkable interiors that come later.
--
-- room_air's chemistry, on rooms taken from the ASSEMBLY GRAPH instead of a
-- flood fill. The rulebook half is pure and loads in luajit
-- (tests/smoke_cabin_air.lua) against vessel_controller's published API; the
-- scene half rides its own UI node ("Cabin Air", scenes/system.ron) and draws
-- the IVA gauge.
--
-- ── MODULES ─────────────────────────────────────────────────────────────────
-- A CABIN PART is a closed crew part (Pod Mk1, Pod Mk2, Crew Cabin, Swift
-- Cockpit; a modded crewed part with a hatch; any record with `cabinV`).
-- Cabin parts bolted straight to each other share one pressure hull: one
-- MODULE. Two modules meet only through DOORS:
--   hatch    a cabin part's own side hatch (crew.lua SEATS `hatch`), to the
--            outside: the one the crew goes EVA through
--   port     a Docking Port on a cabin part: a mated pair joins two modules
--            (docked craft are one assembly, so their modules merge through
--            it); an unmated port opens to the outside
--   breach   a cabin part lost to damage (vessel_controller.lostParts) that
--            was bolted to one still aboard: its socket is open, always
-- Every door is OPEN, SHUT (closed, its equalising valve open: slow) or
-- SEALED (closed and dogged: tight), in the part state `hatch` (side hatch)
-- or `ph` (a port's; a mated pair is the less open of its two). New doors are
-- sealed. A NETWORK is modules joined by open doors: one well-mixed volume.
--
-- ── THE AIR ─────────────────────────────────────────────────────────────────
-- Amounts in atm·m³ (room_air): N, x (O2), c (CO2), kept per cabin part in
-- its state `cab` ({ N, x, c, t }), so it rides docking, undocking, the fleet
-- record and revert, and a module's air is the sum of its parts'. Each cabin
-- part carries a compressed-air RESERVE (state `cq`, atm·m³) on a regulator
-- (room_air's FEED: it feeds air under 97 % of 1 atm, up to 1 atm), and a
-- command part or cabin a CO2 scrubber that runs while the craft has charge.
-- The crew breathe it (room_air USE / MAKE). room_air.advance steps each
-- network in closed form; the leaks and open doors are room_air.equalise to
-- the outside (exact exponentials), shut valves equalise between networks.
--
-- A LEAK: every cabin part under hp 0.5 has a hole, damage.holeArea(hp) m²
-- (none at 0.5, damage.A_HOLE, 10 cm, at 0.05), and passes LEAK_K m³/s per
-- atm per m² (choked air through an orifice, Cd 0.6, 293 K: τ = V / (LEAK_K
-- A); a 2 m³ pod through 1 cm² loses 63 % in 2.8 min). A breach (τ under
-- BREACH_TAU) shuts the regulator's excess-flow valve. The hole hisses
-- (audio/foley/leak_hiss.ogg, a 3D loop on the part) while air goes out of
-- it. A Repair Kit patches it ("Patch the leak", hp back to PATCH_HP) or a
-- full repair mends it.
--
-- ── THE CREW ────────────────────────────────────────────────────────────────
--   helmets   off aboard only when the module is breathable (suit.lua asks
--             helmetAboard()); a bare head in air that goes bad: on at once
--   suit air  refills from the module's air (planet_walker asks avatarAir()
--             and takes the O2 with takeO2), never from nothing; in a module
--             that cannot be breathed the suit is breathed. An open seat
--             breathes the outside.
--   others    seated crew breathe the module too (crew.recordStep with the
--             helmet on), and die of it on Permadeath
--   EVA       stepping out opens the hatch: the module vents to the outside
--             (warned, never refused). Crew left inside shut it after
--             CLOSE_BEHIND s, the last one out after SELF_CLOSE s (a hatch
--             opened by hand from its menu is propped and stays open);
--             boarding seals it and the regulator repressurises from the
--             reserve.
--
-- ── WHEN THINGS RUN (never per frame per part) ──────────────────────────────
--   graph     rebuilt when vessel_controller.partsGen() moves, or a door changes
--   air       every AIR_EVERY s of real time, stepped by the agency clock (a
--             warp lands where 1x would; caught up on load, CATCH_MAX)
--   events    EVENT_EVERY s: who sits where, boarding, EVA (O(craft))
--   outside   OUT_EVERY s per craft
-- SETTING: save "craft.cabin_air" = "realistic" (default) | "off" (the
-- settings' Agency tab): off, nothing here runs and the crew breathes aboard
-- any craft as before.
--
-- API: enabled(), setMode(m), modulesOf(v) → G, statusOf(v, i), cabinOf(v,
-- which) (scenarios), avatarAir(), takeO2(amt), helmetAboard(), setDoor(v,
-- door, state), doorsOf(v), infoRows(t), gaugeOf(), probes: tickNow(), PROF,
-- lastAlarm, lastHatch, lastLeakSound.

-- ── PURE ────────────────────────────────────────────────────────────────────
LEAK_K = 120.0           -- m³/s per atm per m² of hole
HATCH_G = 6.0            -- an open side hatch or port to the outside, m³/s per atm
EQV_G = 0.05             -- a shut door's equalising valve, m³/s per atm
VENT_G = 0.4             -- a cabin's own vent valve (the "Vent the cabin" row)
BREACH_G = 6.0           -- a lost part's open socket
BREACH_TAU = 60.0        -- s: a network venting faster than this shuts its regulator
PATCH_HP = 0.55          -- what a patch leaves the part at (no hole over 0.5)
P_ALARM = 0.8            -- a module that held this much and vents: the alarm
SCRUB_K = 2.0            -- a scrubber clears this many crew's CO2
CLOSE_BEHIND = 3.0       -- s: the crew left inside shut the hatch behind an EVA
SELF_CLOSE = 2.0         -- s: the last one out pulls it shut from outside
STEP_MAX = 30.0          -- s: a long step is cut into these (the leak and the chemistry are split)
CATCH_MAX = 30 * 86400
O2N_ = 0.21

-- Per part id: V (m³ of cabin), q (atm·m³ of air in the reserve bottles), F
-- (the regulator's flow, atm·m³/s), S (the scrubber, crews), and whether it
-- commands (a scrubber needs the craft's charge either way).
CABIN = {
  pod     = { V = 2.0, q = 8.0,  F = 0.04, S = 1 },
  podMk2  = { V = 4.5, q = 16.0, F = 0.05, S = 3 },
  cabin   = { V = 7.0, q = 20.0, F = 0.05, S = 4 },
  cockpit = { V = 2.5, q = 8.0,  F = 0.04, S = 1 },
}
DOOR_RANK = { sealed = 0, shut = 1, open = 2 }
DOOR_NAMES = { "sealed", "shut", "open" }

local min, max, exp, sqrt, ln = math.min, math.max, math.exp, math.sqrt, math.log

-- The hole a part under hp 0.5 has (m²): damage.holeArea's rule (damage.lua
-- has the same; this copy runs where the Damage script is not in the scene).
A_HOLE_ = 0.01
function holeArea(hp)
  hp = tonumber(hp) or 1
  if hp >= 0.5 then return 0 end
  local s = max(0.02, min(1, (0.5 - hp) / 0.45))
  return A_HOLE_ * s * s
end

-- A record → its cabin definition, or nil. `seatDef` is crew.seatDef (a
-- modded crewed part counts when it has a hatch: an open seat is no cabin).
function cabinDef(rec, seatDef)
  if type(rec) ~= "table" then return nil end
  local d = CABIN[rec.id or ""]
  if d then return d end
  if tonumber(rec.cabinV) then
    local V = tonumber(rec.cabinV)
    return { V = V, q = tonumber(rec.cabinQ) or 4 * V, F = 0.04, S = tonumber(rec.cabinS) or 0 }
  end
  if rec.kind == "crewed" and not (rec.seat == true or rec.seat == 1) then
    local sd = seatDef and seatDef(rec)
    if sd and not sd.open and sd.hatch then
      local r, h = rec.rx or 0.5, rec.h or 1.0
      local V = max(1.0, 3.0 * math.pi * r * r * h)
      return { V = V, q = 4 * V, F = 0.04, S = #(sd.seats or {}) }
    end
  end
  return nil
end

local function door_state(s)
  if s == "open" or s == "shut" then return s end
  return "sealed"
end
local function less_open(a, b) return (DOOR_RANK[a] or 0) <= (DOOR_RANK[b] or 0) and a or b end

-- THE GRAPH. recs: uid → record (vessel_controller.aboardRecs); ports: {
-- {uid, mate, buried} } (dockPorts); opts.seatDef, opts.lost (lostParts: the
-- records lost to damage), opts.hatchPart(rec) (a door part between two
-- cabins: none ships yet).
-- → G = { mods = { { id, uids, V, qcap, F, S, label } }, modOf = uid → i,
--         doors = { { kind, uid | uids, a, b (0 = the outside) } }, cabins = uid → def }
function buildModules(recs, ports, opts)
  opts = opts or {}
  local G = { mods = {}, modOf = {}, doors = {}, cabins = {} }
  local kids = {}
  local any = false
  for u, d in pairs(recs) do
    local pu = d.parent or 0
    if pu ~= 0 and recs[pu] then kids[pu] = kids[pu] or {}; kids[pu][#kids[pu] + 1] = u end
    local cd = cabinDef(d, opts.seatDef)
    if cd then G.cabins[u] = cd; any = true end
  end
  if not any then return G end
  local function nbrs(u)
    local out = {}
    local pu = recs[u] and recs[u].parent or 0
    if pu ~= 0 and recs[pu] then out[#out + 1] = pu end
    for _, k in ipairs(kids[u] or {}) do out[#out + 1] = k end
    return out
  end
  -- modules: cabin parts bolted to cabin parts (uid order: stable ids)
  local order = {}
  for u in pairs(G.cabins) do order[#order + 1] = u end
  table.sort(order)
  for _, u0 in ipairs(order) do
    if not G.modOf[u0] then
      local m = { uids = {}, V = 0, qcap = 0, F = 0, S = 0 }
      G.mods[#G.mods + 1] = m
      local i = #G.mods
      local stack = { u0 }
      G.modOf[u0] = i
      while #stack > 0 do
        local u = table.remove(stack)
        m.uids[#m.uids + 1] = u
        local cd = G.cabins[u]
        m.V, m.qcap, m.F, m.S = m.V + cd.V, m.qcap + cd.q, m.F + cd.F, m.S + (cd.S or 0)
        for _, n in ipairs(nbrs(u)) do
          if G.cabins[n] and not G.modOf[n] then G.modOf[n] = i; stack[#stack + 1] = n end
        end
      end
      table.sort(m.uids)
      m.id = m.uids[1]
      -- (scn_vacuum) "Crew Cabin ×2": two cans of one kind are not the one
      -- can next door (Hard Vacuum's stores and hab read the same)
      local names, seen = {}, {}
      for _, u in ipairs(m.uids) do
        local l = recs[u].label or recs[u].id or "cabin"
        if not seen[l] then seen[l] = 0; names[#names + 1] = l end
        seen[l] = seen[l] + 1
      end
      for j, l in ipairs(names) do if seen[l] > 1 then names[j] = l .. " ×" .. seen[l] end end
      m.label = table.concat(names, " + ")
    end
  end
  -- side hatches
  for _, u in ipairs(order) do
    local sd = opts.seatDef and opts.seatDef(recs[u])
    if (sd and sd.hatch) or recs[u].hatch then G.doors[#G.doors + 1] = { kind = "hatch", uid = u, a = G.modOf[u], b = 0 } end
  end
  -- ports on cabin parts: which module each port opens from
  local portMod = {}
  local mate = {}
  for _, p in ipairs(ports or {}) do
    mate[p.uid] = p.mate
    if recs[p.uid] then
      for _, n in ipairs(nbrs(p.uid)) do
        if G.cabins[n] then portMod[p.uid] = G.modOf[n]; break end
      end
    end
  end
  local done = {}
  for _, p in ipairs(ports or {}) do
    local u = p.uid
    local a = portMod[u]
    if a and not done[u] then
      done[u] = true
      local q = p.mate
      if q and recs[q] then
        done[q] = true
        local b = portMod[q]
        -- (a mate with no cabin behind it: a blind tunnel — no door at all)
        if b and b ~= a then G.doors[#G.doors + 1] = { kind = "port", uids = { u, q }, uid = u, a = a, b = b } end
      elseif not p.buried then
        G.doors[#G.doors + 1] = { kind = "port", uids = { u }, uid = u, a = a, b = 0 }
      end
    end
  end
  -- hatch parts (a door part between cabins)
  if opts.hatchPart then
    for u, d in pairs(recs) do
      if not G.cabins[u] and opts.hatchPart(d) then
        local sides = {}
        for _, n in ipairs(nbrs(u)) do if G.cabins[n] then sides[#sides + 1] = G.modOf[n] end end
        if #sides >= 1 then G.doors[#G.doors + 1] = { kind = "hpart", uid = u, uids = { u }, a = sides[1], b = sides[2] or 0 } end
      end
    end
  end
  -- breaches: a lost cabin part that was bolted to one aboard
  for _, d in ipairs(opts.lost or {}) do
    if cabinDef(d, opts.seatDef) then
      local hit = nil
      local pu = d.parent or 0
      if G.cabins[pu] then hit = pu end
      if not hit then
        for _, u in ipairs(order) do if (recs[u].parent or 0) == d.uid then hit = u; break end end
      end
      if hit then G.doors[#G.doors + 1] = { kind = "breach", uid = d.uid, a = G.modOf[hit], b = 0, at = hit } end
    end
  end
  return G
end

-- A door's state from the parts' state: st(uid, key) → value
function doorStateOf(door, st)
  if door.kind == "breach" then return "open" end
  if door.kind == "hatch" then return door_state(st(door.uid, "hatch")) end
  local s = nil
  for _, u in ipairs(door.uids or { door.uid }) do
    local k = door_state(st(u, door.kind == "hpart" and "hatch" or "ph"))
    s = s and less_open(s, k) or k
  end
  return s or "sealed"
end

-- The networks for states `S` (door index → state): → nets = { { mods = {i…},
-- V, Gout, causes = { … }, open (an open door to the outside) } }, netOf = i → n,
-- valves = { { a = net, b = net, G } }
function networksOf(G, S, opts)
  opts = opts or {}
  local par = {}
  for i = 1, #G.mods do par[i] = i end
  local function root(i) while par[i] ~= i do par[i] = par[par[i]]; i = par[i] end return i end
  for k, d in ipairs(G.doors) do
    if d.b and d.b > 0 and S[k] == "open" then
      local ra, rb = root(d.a), root(d.b)
      if ra ~= rb then par[rb] = ra end
    end
  end
  local nets, netOf, byRoot = {}, {}, {}
  for i = 1, #G.mods do
    local r = root(i)
    local j = byRoot[r]
    if not j then nets[#nets + 1] = { mods = {}, V = 0, qcap = 0, F = 0, S = 0, Gout = 0, causes = {}, leaks = {} }; j = #nets; byRoot[r] = j end
    local n = nets[j]
    n.mods[#n.mods + 1] = i
    local m = G.mods[i]
    n.V, n.qcap, n.F, n.S = n.V + m.V, n.qcap + m.qcap, n.F + m.F, n.S + m.S
    netOf[i] = j
  end
  local valves = {}
  for k, d in ipairs(G.doors) do
    local na = netOf[d.a]
    local s = S[k]
    if na then
      if d.b == 0 then
        local g = 0
        if d.kind == "breach" then g = BREACH_G
        elseif s == "open" then g = HATCH_G
        elseif s == "shut" then g = EQV_G end
        if g > 0 then
          local n = nets[na]
          n.Gout = n.Gout + g
          if s == "open" or d.kind == "breach" then n.open = true end
          n.causes[#n.causes + 1] = { kind = d.kind, uid = d.uid, state = s, G = g }
        end
      elseif s == "shut" then
        local nb = netOf[d.b]
        if nb and nb ~= na then valves[#valves + 1] = { a = na, b = nb, G = EQV_G, door = k } end
      end
    end
  end
  -- leaks and vent valves (opts.hp(uid), opts.vent(uid))
  for i, m in ipairs(G.mods) do
    local n = nets[netOf[i]]
    for _, u in ipairs(m.uids) do
      local A = opts.hp and holeArea(opts.hp(u)) or 0
      if A > 0 then
        local g = LEAK_K * A
        n.Gout = n.Gout + g
        n.leaks[#n.leaks + 1] = { uid = u, A = A, G = g }
        n.causes[#n.causes + 1] = { kind = "leak", uid = u, G = g }
      end
      if opts.vent and opts.vent(u) then
        n.Gout = n.Gout + VENT_G
        n.causes[#n.causes + 1] = { kind = "vent", uid = u, G = VENT_G }
      end
      if opts.regOff and opts.regOff(u) then n.regOff = (n.regOff or 0) + 1 end
    end
  end
  return nets, netOf, valves
end

-- One step of a craft's air. A = { [i] = { N, x, c, feed } } (per module), Q =
-- { [i] = q }, env = { RA (room_air's rulebook), pout, xout, cout, crew = { [i]
-- = n }, powered, nets, netOf, valves } → nothing (A, Q stepped in place);
-- env.flow[n] = what left net n to the outside (atm·m³) this step.
function stepAir(G, A, Q, env, dt)
  local RA = env.RA
  if not RA or dt <= 0 then return end
  local nets, netOf, valves = env.nets, env.netOf, env.valves
  local left = min(dt, CATCH_MAX)
  local guard = 0
  env.flow = env.flow or {}
  for k in ipairs(nets) do env.flow[k] = 0 end
  while left > 1e-9 and guard < 400 do
    guard = guard + 1
    local h = min(left, STEP_MAX)
    if guard == 400 then h = left end
    for k, n in ipairs(nets) do
      local P = { N = 0, x = 0, c = 0, q = 0, feed = false }
      local crew = 0
      for _, i in ipairs(n.mods) do
        local a = A[i]
        P.N, P.x, P.c = P.N + a.N, P.x + a.x, P.c + a.c
        P.q = P.q + (Q[i] or 0)
        if a.feed then P.feed = true end
        crew = crew + ((env.crew and env.crew[i]) or 0)
      end
      local breach = n.Gout > 0 and (n.V / n.Gout) < BREACH_TAU
      local F = (breach or n.open or (n.regOff or 0) >= #n.mods) and 0 or n.F
      if F == 0 then P.feed = false end
      local M = { V = n.V, crew = crew, G = 0, S = env.powered and (n.S * SCRUB_K * RA.MAKE) or 0, F = F }
      RA.advance(P, M, h)
      if n.Gout > 0 then
        local moved = RA.equalise(P, n.V, nil, nil, n.Gout, h, env.pout or 0, env.xout or 0, env.cout or 0)
        env.flow[k] = env.flow[k] + max(0, moved or 0)
      end
      -- back to the modules by volume, the reserve by capacity
      for _, i in ipairs(n.mods) do
        local m = G.mods[i]
        local f = m.V / n.V
        local a = A[i]
        a.N, a.x, a.c, a.feed = P.N * f, P.x * f, P.c * f, P.feed
        Q[i] = n.qcap > 0 and P.q * (m.qcap / n.qcap) or 0
      end
    end
    for _, vl in ipairs(valves) do
      local na, nb = nets[vl.a], nets[vl.b]
      local PA, PB = { N = 0, x = 0, c = 0 }, { N = 0, x = 0, c = 0 }
      for _, i in ipairs(na.mods) do PA.N, PA.x, PA.c = PA.N + A[i].N, PA.x + A[i].x, PA.c + A[i].c end
      for _, i in ipairs(nb.mods) do PB.N, PB.x, PB.c = PB.N + A[i].N, PB.x + A[i].x, PB.c + A[i].c end
      RA.equalise(PA, na.V, PB, nb.V, vl.G, h)
      for _, i in ipairs(na.mods) do local f = G.mods[i].V / na.V; A[i].N, A[i].x, A[i].c = PA.N * f, PA.x * f, PA.c * f end
      for _, i in ipairs(nb.mods) do local f = G.mods[i].V / nb.V; A[i].N, A[i].x, A[i].c = PB.N * f, PB.x * f, PB.c * f end
    end
    left = left - h
  end
end

-- A network's reading: → { p, o2, co2, share, breathable, why, V, venting,
-- tau, rate (atm·m³/s out now), leaks, causes, reserve, qcap, untilBad (s to
-- under P_MIN, venting) }
function netStatus(RA, G, n, A, Q, env)
  local P = { N = 0, x = 0, c = 0 }
  local q = 0
  for _, i in ipairs(n.mods) do P.N, P.x, P.c = P.N + A[i].N, P.x + A[i].x, P.c + A[i].c; q = q + (Q[i] or 0) end
  local s = RA.statusOf(P, n.V)
  local pout = env.pout or 0
  s.V, s.reserve, s.qcap = n.V, q, n.qcap
  s.leaks, s.causes = n.leaks, n.causes
  s.rate = n.Gout * max(0, s.p - pout)
  s.venting = n.Gout > 0 and s.p > pout + 0.02
  s.tau = n.Gout > 0 and n.V / n.Gout or nil
  -- how long until it can't be breathed, venting: the pressure to P_MIN or
  -- the O2 to O2_MIN, whichever first (both relax to the outside's with τ;
  -- in normal air the O2 goes first, at 0.76 atm)
  if s.venting and s.breathable then
    local t = nil
    if s.p > RA.P_MIN and pout < RA.P_MIN then t = s.tau * ln((s.p - pout) / (RA.P_MIN - pout)) end
    local xo = (env.xout or 0) * pout
    if s.o2 > RA.O2_MIN and xo < RA.O2_MIN then
      local t2 = s.tau * ln((s.o2 - xo) / (RA.O2_MIN - xo))
      t = t and math.min(t, t2) or t2
    end
    -- (scn_vacuum) a regulator that can feed the hole (no breach, no open
    -- hatch, not all off: stepAir's rule) holds the module where its feed
    -- meets the outflow; if that is breathable, the air lasts as long as the
    -- reserve does, and only then bleeds down (the banner said "unbreathable
    -- in 42 s" over a can holding 0.98 atm on its bottles for eight minutes)
    local F = ((n.Gout > 0 and n.V / n.Gout < BREACH_TAU) or n.open or (n.regOff or 0) >= #n.mods) and 0 or (n.F or 0)
    if t and F > 0 and q > 0 then
      local hold = min(1.0, pout + F / n.Gout)
      local share = s.p > 0 and s.o2 / s.p or 0.21
      if hold > RA.P_MIN and hold * share > RA.O2_MIN then
        local drain = min(F, n.Gout * max(0, min(s.p, 0.985) - pout))
        if drain > 1e-9 then t = t + q / drain end
        s.holding = true
      end
    end
    s.untilBad = t
  end
  s.mods = n.mods
  return s
end

-- A fresh module's air: 1 atm of normal air.
function freshAir(V) return { N = V * (1 - O2N_), x = V * O2N_, c = 0 } end

-- The less open → more open order of a door's states, and what a press asks.
function nextState(s, want)
  if want then return want end
  return s == "open" and "sealed" or "open"
end

-- ── the scene half ──────────────────────────────────────────────────────────
AIR_EVERY = 1.0
EVENT_EVERY = 0.25
OUT_EVERY = 5.0
ALARM_EVERY = 2.5
PROF = { ms = 0, n = 0, crafts = 0, mods = 0 }
lastAlarm = nil
lastHatch = nil
lastLeakSound = nil
gauge = nil          -- (probes) what the IVA gauge shows: { label, p, o2, co2, … }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function valid(n) return n ~= nil and n.valid ~= false end

function enabled()
  local m = save and save.get and save.get("craft.cabin_air")
  return m ~= "off"
end
function mode() return enabled() and "realistic" or "off" end
function setMode(m)
  if save and save.set then save.set("craft.cabin_air", m == "off" and "off" or "realistic") end
end

local C = {}            -- vessel node id → craft state
local vlist, vlist_t = {}, -10
local air_t, ev_t = -10, -10
local avatar = { v = nil, vid = nil, uid = nil, mod = nil, status = nil, open = false }
local sounds = {}       -- "vid:uid" → { h, t }
local alarms_ = {}      -- "vid:mod id" → { t0, snd_t }
local drawn = false

local function vid_of(v) return v and valid(v.node) and v.node.id or nil end
local function vessels()
  if now() - vlist_t > 1.0 or #vlist == 0 then
    vlist_t = now()
    vlist = findScripts and findScripts("vessel_controller") or {}
  end
  return vlist
end
local function seat_def()
  local cr = ref("crew")
  return cr and cr.seatDef or nil
end
local function st_of(v)
  return function(u, k) return v.partSt and v.partSt(u, k) or nil end
end

-- The outside where craft v is: p (atm), O2 share, CO2 share (room_air's
-- rule for a structure, at the craft's height).
local function outside_of(v)
  local RA = ref("room_air")
  if RA and RA.forceVacuum then return 0, 0, 0 end
  local n = v.node
  if not (valid(n) and space and space.dominant) then return 0, 0, 0 end
  local dom = space.dominant(n.x, n.y, n.z)
  local cl, ae = ref("climate"), ref("aero")
  local w = dom and cl and cl.worldOf and cl.worldOf(dom)
  if not w or (w.atmo or 0) < 0.05 then return 0, 0, 0 end
  local b = space.body and space.body(dom)
  local share = 1
  if b then
    local dx, dy, dz = n.x - b.x, n.y - b.y, n.z - b.z
    local alt = sqrt(dx * dx + dy * dy + dz * dz) - (w.radius or b.radius or 0)
    local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or b.radius or 800)
    if ae and ae.airShare then
      local ok, sh = pcall(ae.airShare, math.max(alt, -0.25 * H), H, w.atmoScaleH)
      share = ok and sh or 1
    else
      local f = math.max(0, 1 - math.max(alt, 0) / H); share = f * f
    end
  end
  if type(w.air) == "table" and not w.air.legacy and RA and RA.outsideOf then
    return RA.outsideOf(w.air, share)
  end
  local oxy = 0
  if ae and ae.oxygen then local ok, o = pcall(ae.oxygen, w); oxy = ok and (o or 0) or 0 end
  local p = math.max(0, math.min(1.2, share * math.min(1.5, (w.atmo or 0) / 0.45)))
  return p, (oxy >= 0.5) and O2N_ or 0, 0
end

-- the craft's charge: any battery aboard holding some (the scrubbers' fans)
local function powered(v, c)
  local E = ref("electronics")
  if not (E and E.stateOf and E.modOf) then return true end
  for _, u in ipairs(c.batts or {}) do
    local d = v.partRec and v.partRec(u)
    if d then local st = E.stateOf(d); if (st.charge or 0) > 0.05 then return true end end
  end
  return false
end

local function door_states(v, c)
  local S = {}
  local st = st_of(v)
  for k, d in ipairs(c.G.doors) do S[k] = doorStateOf(d, st) end
  return S
end

local function nets_of(v, c)
  c.stat = nil      -- (doors, vents or regulators read again: the readings with them)
  c.S = door_states(v, c)
  c.nets, c.netOf, c.valves = networksOf(c.G, c.S, {
    hp = function(u) return v.partHp and v.partHp(u) or 1 end,
    vent = function(u) return v.partSt and v.partSt(u, "cvent") == true end,
    regOff = function(u) return v.partSt and v.partSt(u, "creg") == "off" end,
  })
end

-- Read the modules' air out of the parts' state (a part never seen: fresh
-- air, a full reserve). → the oldest stamp among them
local function read_air(v, c)
  local a0 = nil
  c.A, c.Q = {}, {}
  local tnow = agency_now()
  for i, m in ipairs(c.G.mods) do
    local A = { N = 0, x = 0, c = 0, feed = false }
    local q = 0
    for _, u in ipairs(m.uids) do
      local cd = c.G.cabins[u]
      local s = v.partSt and v.partSt(u, "cab")
      if type(s) ~= "table" or not tonumber(s.N) then
        s = freshAir(cd.V); s.t = tnow
        if v.partSt then v.partSt(u, "cab", s, true) end
      end
      A.N, A.x, A.c = A.N + (tonumber(s.N) or 0), A.x + (tonumber(s.x) or 0), A.c + (tonumber(s.c) or 0)
      if s.f then A.feed = true end
      local t = tonumber(s.t)
      if t and (not a0 or t < a0) then a0 = t end
      local cq = v.partSt and v.partSt(u, "cq")
      if not tonumber(cq) then cq = cd.q; if v.partSt then v.partSt(u, "cq", cq, true) end end
      q = q + tonumber(cq)
    end
    c.A[i], c.Q[i] = A, q
  end
  return a0 or tnow
end

local function write_air(v, c, t)
  if not v.partSt then return end
  for i, m in ipairs(c.G.mods) do
    local A, q = c.A[i], c.Q[i] or 0
    for _, u in ipairs(m.uids) do
      local cd = c.G.cabins[u]
      local f = cd.V / m.V
      local s = v.partSt(u, "cab")
      if type(s) ~= "table" then s = {}; v.partSt(u, "cab", s, true) end
      s.N, s.x, s.c, s.t, s.f = A.N * f, A.x * f, A.c * f, t, A.feed or nil
      v.partSt(u, "cq", m.qcap > 0 and q * cd.q / m.qcap or 0, true)
    end
  end
end

local function rebuild(v, c)
  local recs = v.aboardRecs and v.aboardRecs() or {}
  local ports = v.dockPorts and v.dockPorts() or {}
  local lost = v.lostParts and select(1, v.lostParts()) or {}
  c.G = buildModules(recs, ports, { seatDef = seat_def(), lost = lost })
  c.gen = v.partsGen and v.partsGen() or 0
  c.batts = {}
  local E = ref("electronics")
  if #c.G.mods > 0 and E and E.modOf then
    for u, d in pairs(recs) do local m = E.modOf(d, "battery"); if m and (m.ec or 0) > 0 then c.batts[#c.batts + 1] = u end end
  end
  if #c.G.mods > 0 then
    local a0 = read_air(v, c)
    c.a = math.max(a0, agency_now() - CATCH_MAX)
  else
    c.A, c.Q, c.a = {}, {}, agency_now()
  end
  nets_of(v, c)
  c.dirty = false
end

local function craft(v)
  local id = vid_of(v)
  if not id then return nil end
  local c = C[id]
  if not c then c = { id = id, pres = {}, out = nil, out_t = -10, crew = {}, said = {} }; C[id] = c end
  c.v = v
  if not c.G or c.dirty or (v.partsGen and v.partsGen() ~= c.gen) then rebuild(v, c) end
  return c
end

function modulesOf(v) local c = craft(v); return c and c.G or nil end
-- A part's state was written from outside (a scenario's `state` beat on a
-- hatch or a regulator): the doors and the readings again, now.
function touch(v)
  local c = craft(v)
  if c and c.G and #c.G.mods > 0 and c.A then nets_of(v, c) end
end

-- module i's status on craft v (its network's air). Worked out ONCE per
-- air tick (or door change) and kept: the DEPRESSURISATION banner, the IVA
-- gauge, the part's menu and the scenario reads all show the same reading,
-- so one "unbreathable in" (scn_vacuum: the banner said 5 s while the gauge
-- said 2 s, the banner's text frozen when the alarm went off).
function statusOf(v, i)
  local c = craft(v)
  if not (c and c.G.mods[i] and c.nets) then return nil end
  local cs = c.stat
  if cs and cs[i] then return cs[i] end
  local RA = ref("room_air")
  if not RA then return nil end
  local n = c.nets[c.netOf[i]]
  local s = netStatus(RA, c.G, n, c.A, c.Q, { pout = c.out and c.out.p or 0, xout = c.out and c.out.x or 0 })
  s.label = c.G.mods[i].label
  s.module = i
  s.crew = c.crew[i] or 0
  s.net = c.netOf[i]
  s.at = now()
  if not cs then cs = {}; c.stat = cs end
  cs[i] = s
  return s
end

local function crew_of(v, c)
  local by = {}
  for _, s in ipairs(v.seatsOf and v.seatsOf() or {}) do
    local i = c.G.modOf[s.uid]
    if i and s.taken then by[i] = (by[i] or 0) + 1 end
  end
  c.crew = by
  return by
end

local function step(v, c, a)
  if #c.G.mods == 0 then c.a = a return end
  local dt = a - (c.a or a)
  if dt <= 0 then return end
  local RA = ref("room_air")
  if not RA then return end
  if not c.out or now() - c.out_t > OUT_EVERY then
    local p, x, cc = outside_of(v)
    c.out, c.out_t = { p = p, x = x, c = cc }, now()
  end
  -- the leaks follow the parts' health: the nets again when it changes
  -- (the networks again each step: O(doors + cabin parts), and every door,
  -- hole, vent and regulator state is read fresh — no cache to go stale)
  nets_of(v, c)
  local env = { RA = RA, pout = c.out.p, xout = c.out.x, cout = c.out.c, crew = crew_of(v, c), powered = powered(v, c),
                nets = c.nets, netOf = c.netOf, valves = c.valves }
  stepAir(c.G, c.A, c.Q, env, dt)
  -- the reserve fills on the pad (or a Build Stand), as the tanks do
  if v.leftPad == false or v.standHeld then
    for i, m in ipairs(c.G.mods) do c.Q[i] = m.qcap end
  end
  c.a = a
  c.flow = env.flow
  write_air(v, c, a)
  c.stat = nil      -- (the air moved: one fresh reading per module, on first ask)
end

-- ── doors ───────────────────────────────────────────────────────────────────
-- The doors of craft v: { { k, kind, uid, uids, a, b, state, label } }
function doorsOf(v)
  local c = craft(v)
  if not c then return {} end
  local out = {}
  local S = door_states(v, c)
  for k, d in ipairs(c.G.doors) do
    out[#out + 1] = { k = k, kind = d.kind, uid = d.uid, uids = d.uids, a = d.a, b = d.b, state = S[k] }
  end
  return out
end
local function door_at(c, uid, kind)
  for k, d in ipairs(c.G.doors) do
    if d.uid == uid and (not kind or d.kind == kind) then return k, d end
    if d.uids then for _, u in ipairs(d.uids) do if u == uid and (not kind or d.kind == kind) then return k, d end end end
  end
  return nil
end
function doorOf(v, uid, kind) local c = craft(v); if not c then return nil end local k, d = door_at(c, uid, kind); return k, d end

local function door_label(c, d)
  if d.kind == "hatch" then return "the " .. tostring(c.G.mods[d.a] and c.G.mods[d.a].label or "cabin") .. "'s hatch" end
  if d.kind == "port" then return d.b == 0 and "the docking port's hatch" or "the docking hatch" end
  return "the hatch"
end

-- What opening (or cracking) door k would do: → the warning, or nil
function warnOfDoor(v, k, want)
  local c = craft(v)
  if not c then return nil end
  local d = c.G.doors[k]
  if not d or want == "sealed" then return nil end
  local sa = statusOf(v, d.a)
  if not sa then return nil end
  local pb, lbl
  if d.b == 0 then pb = c.out and c.out.p or 0; lbl = pb < 0.05 and "vacuum" or string.format("the outside (%.2f atm)", pb)
  else local sb = statusOf(v, d.b); pb = sb and sb.p or 0; lbl = sb and sb.label or "the next module" end
  local dp = math.abs((sa.p or 0) - pb)
  if dp < 0.05 then return nil end
  local hi = (sa.p or 0) > pb
  local crew = (c.crew[d.a] or 0) + (d.b > 0 and (c.crew[d.b] or 0) or 0)
  if want == "shut" then
    return string.format("The equalising valve bleeds the %.2f atm between them %s %s%s.", dp, hi and ("from the " .. tostring(sa.label) .. " into") or "into the " .. tostring(sa.label) .. " from", lbl,
      d.b == 0 and hi and string.format(" (the %s loses its air in about %s)", sa.label, (function()
        local t = sa.V / EQV_G * ln(math.max(1.01, dp / 0.05)); return t > 120 and string.format("%.0f min", t / 60) or string.format("%.0f s", t) end)()) or "")
  end
  if d.b == 0 and hi then
    return string.format("Opening it vents the %s to %s: %.2f atm gone in seconds%s.", sa.label, lbl, dp,
      crew > 0 and string.format(", %d crew aboard on suit air", crew) or "")
  end
  return string.format("%.2f atm across it: the air slams through when it opens. Crack it first (Shut, valve open) to equalise.", dp)
end
function warnOf(v, uid, want)
  local c = craft(v)
  if not c then return nil end
  local k = door_at(c, uid)
  return k and warnOfDoor(v, k, want) or nil
end
-- Doors are refused only for physical reasons: a breach cannot be shut.
function whyNot(v, uid, want)
  local c = craft(v)
  if not c then return "no cabin" end
  local k, d = door_at(c, uid)
  if not k then return "no hatch here" end
  if d.kind == "breach" then return "nothing left to close: the part is gone" end
  return nil
end

local function vent_fx(v, uid, dp)
  if dp < 0.08 then return end
  local F = v.partFrameNow and v.partFrameNow(uid, true)
  if not F then return end
  local cr = ref("crew")
  local d = v.partRec and v.partRec(uid)
  local sd = cr and cr.seatDef and d and cr.seatDef(d)
  local h = sd and sd.hatch or { x = 0, y = 0.5, z = 0, nx = 0, ny = 1, nz = 0 }
  local x = F.ox + F.rx * h.x + F.ux * h.y + F.zx * h.z
  local y = F.oy + F.ry * h.x + F.uy * h.y + F.zy * h.z
  local z = F.oz + F.rz * h.x + F.uz * h.y + F.zz * h.z
  local nx = F.rx * h.nx + F.ux * h.ny + F.zx * h.nz
  local ny = F.ry * h.nx + F.uy * h.ny + F.zy * h.nz
  local nz = F.rz * h.nx + F.uz * h.ny + F.zz * h.nz
  local V = ref("vfx")
  local scale = 0.4 + math.min(1.2, dp)
  if V and V.emit and vec3 then pcall(V.emit, "VentBurst", x, y, z, { normal = vec3(nx, ny, nz), scale = scale, intensity = math.min(1, dp) }) end
  if audio and audio.play then
    pcall(audio.play, "audio/foley/hiss_cylinder.ogg", x, y, z, { maxDistance = 30, track = "SFX", volume = math.min(1, 0.4 + dp) })
  end
end

-- Set door k (or the door at uid) to "open" | "shut" | "sealed". Never
-- refused but for a breach. → ok, warning
local function set_door(v, c, k, state, by)
  local d = c.G.doors[k]
  if not d then return false, "no hatch here" end
  if d.kind == "breach" then return false, "nothing left to close: the part is gone" end
  state = door_state(state)
  -- catch the air up to now first, so the change starts here
  step(v, c, agency_now())
  local warn = warnOfDoor(v, k, state)
  local before = c.S and c.S[k] or "sealed"
  local key = (d.kind == "hatch" or d.kind == "hpart") and "hatch" or "ph"
  for _, u in ipairs(d.uids or { d.uid }) do
    if v.partSt then v.partSt(u, key, state ~= "sealed" and state or false, true) end
  end
  nets_of(v, c)
  local sa = statusOf(v, d.a)
  local pb = d.b == 0 and (c.out and c.out.p or 0) or ((statusOf(v, d.b) or {}).p or 0)
  if state == "open" and before ~= "open" and sa then vent_fx(v, d.uid, math.abs((sa.p or 0) - pb)) end
  if audio and audio.play and state ~= before then
    local F = v.partFrameNow and v.partFrameNow(d.uid, true)
    local clip = state == "open" and "audio/foley/latch_clunk.ogg" or (state == "sealed" and "audio/foley/clamp_clunk.ogg" or "audio/foley/hiss_seal.ogg")
    if F then pcall(audio.play, clip, F.ox, F.oy, F.oz, { maxDistance = 20, track = "SFX", volume = 0.5 })
    else pcall(audio.play, clip, { track = "SFX", volume = 0.4 }) end
  end
  -- (a hand on the door overrides the close-behind: propped open stays open)
  if by == "hand" and c.closeAt and c.closeAt.k == k then c.closeAt = nil end
  lastHatch = { vid = c.id, k = k, uid = d.uid, kind = d.kind, from = before, to = state, by = by, warn = warn, t = now() }
  if log then log(string.format("cabin_air: %s %s → %s%s", door_label(c, d), before, state, warn and (" (" .. warn .. ")") or "")) end
  return true, warn
end
-- by the uid of a part on the door (a cabin part's side hatch first, then a port)
function setDoor(v, uid, state, by)
  local c = craft(v)
  if not c then return false, "no cabin" end
  local k = door_at(c, uid, "hatch") or door_at(c, uid)
  if not k then return false, "no hatch here" end
  return set_door(v, c, k, state, by)
end
function setDoorIndex(v, k, state, by)
  local c = craft(v)
  if not c then return false, "no cabin" end
  return set_door(v, c, k, state, by)
end

-- ── the crew ────────────────────────────────────────────────────────────────
-- Where the avatar sits: craft, cabin part, module (refreshed each event tick)
local function avatar_tick()
  avatar.v, avatar.vid, avatar.uid, avatar.mod, avatar.status, avatar.open = nil, nil, nil, nil, nil, false
  local cr = ref("crew")
  local id = cr and cr.activeId and cr.activeId()
  for _, v in ipairs(vessels()) do
    if v.crewAboard and not v.structureMode then
      local u = id and v.memberSlot and v.memberSlot(id) or nil
      local c = craft(v)
      avatar.v, avatar.vid = v, c and c.id
      if u and c then
        avatar.uid = u
        avatar.mod = c.G.modOf[u]
        if avatar.mod then avatar.status = statusOf(v, avatar.mod) else avatar.open = true end
      else
        avatar.open = true
      end
      if avatar.open then
        -- an open seat: the outside's air where the crew sits (suit.lua's rule)
        local su, a = ref("suit"), find and find("Astronaut")
        avatar.openOk, avatar.openWhy = false, "An open seat in air that can't be breathed. The helmet stays on."
        if su and su.breathableAt and valid(a) then
          local ok, b, why = pcall(su.breathableAt, a.x, a.y, a.z)
          if ok then avatar.openOk, avatar.openWhy = b == true, why end
        end
      end
      return
    end
  end
end

-- What the avatar aboard breathes (planet_walker, every frame: a cached
-- answer): nil (cabin air off, or not aboard) | "cabin" (a breathable module:
-- the suit refills from it) | "suit" (a module that can't be breathed) |
-- "open" (an open seat: the outside's air decides)
function avatarAir()
  if not enabled() or not avatar.v then return nil end
  if avatar.mod then return (avatar.status and avatar.status.breathable) and "cabin" or "suit", avatar.status end
  if avatar.open then return "open" end
  return nil
end
-- Take `amt` atm·m³ of O2 from the avatar's module (the suit refilling). → taken
function takeO2(amt)
  local v, i = avatar.v, avatar.mod
  if not (v and i and amt and amt > 0) then return 0 end
  local c = craft(v)
  if not (c and c.A[i]) then return 0 end
  local a = c.A[i]
  local t = math.min(amt, math.max(0, a.x))
  a.x = a.x - t
  return t
end
-- May the helmet come off aboard? → ok, why | nil (cabin air off, or not aboard:
-- the suit's own rules)
function helmetAboard()
  if not enabled() then return nil end
  if not avatar.v then return nil end
  if avatar.open then return avatar.openOk == true, (not avatar.openOk) and avatar.openWhy or nil end
  local s = avatar.status
  if not s then return false, "The cabin's air isn't read yet." end
  if s.breathable then return true, nil end
  return false, string.format("The %s's air: %s. The helmet stays on.", s.label or "cabin", tostring(s.why))
end

-- The other crew in their seats breathe the module (or the outside in an
-- open seat): crew.recordStep with the helmet on where it can't be breathed,
-- a death on Permadeath when the suit runs dry.
local function crew_records(v, c, dt)
  local cr = ref("crew")
  if not (cr and cr.get and cr.patch and cr.recordStep) or dt <= 0 then return end
  local act = cr.activeId and cr.activeId()
  local RA = ref("room_air")
  local outB = nil
  for _, s in ipairs(v.seatsOf and v.seatsOf() or {}) do
    local id = s.taken
    if id and not (id == act and v.crewAboard) then
      local i = c.G.modOf[s.uid]
      local b
      if i then local st = statusOf(v, i); b = st and st.breathable
      else
        if outB == nil and RA and c.out then outB = RA.statusOf(RA.outsideAir(1, c.out.p, c.out.x, c.out.c), 1).breathable == true end
        b = outB
      end
      local r = cr.get(id)
      if r and r.status ~= "dead" then
        if b then
          if (r.o2 or 1) < 1 then
            local add = math.min(1 - (r.o2 or 1), dt / 120)
            if i then local a = c.A[i]; a.x = math.max(0, a.x - add * (cr.SUIT_AIR_SECS or 1200) * (RA and RA.USE or 0)) end
            cr.patch(id, { o2 = (r.o2 or 1) + add, blackout = false })
          end
        else
          local out = cr.recordStep(r, dt, { breathable = false, helmet = true, tanks = 0 })
          cr.patch(id, { o2 = out.o2, blackout = out.blackout or false })
          if out.dead and cr.kill then pcall(cr.kill, id, "air", i and "the cabin lost its air" or "the suit ran dry in an open seat") end
        end
      end
    end
  end
end

-- ── alarms and the hiss ─────────────────────────────────────────────────────
local function fmt_s(t)
  if not t then return "—" end
  if t > 5400 then return string.format("%.1f h", t / 3600) end
  if t > 90 then return string.format("%.0f min", t / 60) end
  return string.format("%.0f s", t)
end
-- How long the module can still be breathed, in words, from its one reading:
-- "unbreathable in 40 s" | "unbreathable now" | nil (holding). The banner
-- and the gauge both say this.
local function eta_text(s)
  if not s then return nil end
  if not s.breathable or (s.untilBad and s.untilBad < 1.5) then return "unbreathable now" end
  if s.untilBad then return "unbreathable in " .. fmt_s(s.untilBad) end
  return nil
end
etaText = eta_text
-- The DEPRESSURISATION banner's line, from the module's reading
local function alarm_line(label, why, s)
  local e = eta_text(s)
  return string.format("The %s is losing its air: %s.%s", label, why, e and (" " .. e:sub(1, 1):upper() .. e:sub(2) .. ".") or "")
end
alarmLine = alarm_line

local function near_avatar(v)
  if avatar.v and vid_of(avatar.v) == vid_of(v) then return true, 0 end
  local a = find and find("Astronaut")
  if not (valid(a) and valid(v.node)) then return false end
  local dx, dy, dz = a.x - v.node.x, a.y - v.node.y, a.z - v.node.z
  local d = sqrt(dx * dx + dy * dy + dz * dz)
  return d < 60, d
end

local function part_node(v, uid)
  if not (valid(v.node) and v.uidOfNode) then return nil end
  for _, ch in ipairs(v.node:children()) do
    if v.uidOfNode(ch) == uid then return ch end
  end
  return nil
end

local function hiss_tick(v, c, near)
  local want = {}
  if near and c.nets then
    local pout = c.out and c.out.p or 0
    for k, n in ipairs(c.nets) do
      local s = netStatus(ref("room_air"), c.G, n, c.A, c.Q, { pout = pout })
      local dp = (s.p or 0) - pout
      if dp > 0.02 then
        table.sort(n.leaks, function(a, b) return a.G > b.G end)
        for j = 1, math.min(3, #n.leaks) do
          local L = n.leaks[j]
          local flow = L.G * dp
          want[c.id .. ":" .. L.uid] = { uid = L.uid, vol = math.min(0.9, 0.22 + 0.7 * sqrt(math.min(1, flow / 0.05))) }
        end
      end
    end
  end
  for key, s in pairs(sounds) do
    if key:sub(1, #tostring(c.id) + 1) == tostring(c.id) .. ":" and not want[key] then
      if s.h and type(s.h) ~= "boolean" then pcall(function() s.h:stop() end) end
      sounds[key] = nil
    end
  end
  for key, w in pairs(want) do
    local s = sounds[key]
    if not s then
      local pn = part_node(v, w.uid)
      if pn and audio and audio.play then
        local ok, h = pcall(audio.play, "audio/foley/leak_hiss.ogg", pn, { loop = true, track = "SFX", volume = w.vol, minDistance = 1.5, maxDistance = 30 })
        sounds[key] = { h = ok and h or true, vol = w.vol }
        lastLeakSound = { vid = c.id, uid = w.uid, vol = w.vol, t = now() }
      end
    elseif math.abs((s.vol or 0) - w.vol) > 0.05 and s.h and type(s.h) ~= "boolean" then
      pcall(function() s.h:setVolume(w.vol) end)
      s.vol = w.vol
    end
  end
end

local function alarm_tick(v, c, near)
  local pout = c.out and c.out.p or 0
  -- (scn_vacuum) one alarm a NETWORK: three modules open to one hole are one
  -- air, so one banner and one klaxon, naming the module the hole is in (it
  -- was three banners overwriting each other, the last one "the Pod Mk2")
  local lead = {}
  for _, al2 in pairs(alarms_) do if al2.vid == c.id and al2.net then lead[al2.net] = true end end
  for i, m in ipairs(c.G.mods) do
    local s = statusOf(v, i)
    if s then
      local key = c.id .. ":" .. m.id
      if s.p >= P_ALARM then c.pres[m.id] = true end
      local venting = s.venting and s.p > pout + 0.05 and (s.rate or 0) > 1e-5
      local al = alarms_[key]
      if venting and c.pres[m.id] and not al then
        local cause = s.causes and s.causes[1]
        local why = cause and (cause.kind == "leak" and "a hole in the hull" or (cause.kind == "breach" and "a part torn away"
          or (cause.kind == "vent" and "the vent valve open" or (cause.state == "shut" and "a hatch's valve open" or "a hatch open")))) or "a leak"
        local where = (cause and cause.uid and c.G.modOf[cause.uid]) and c.G.mods[c.G.modOf[cause.uid]].label or m.label
        local first = not lead[s.net]
        lead[s.net] = true
        al = { t0 = now(), snd_t = first and -10 or math.huge, vid = c.id, mod = i, cause = why, net = s.net, label = where }
        alarms_[key] = al
        if first then lastAlarm = { vid = c.id, mod = i, label = where, cause = why, t = now(), p = s.p } end
        if near and first then
          local bc = ref("big_caption")
          al.line = alarm_line(where, why, s)
          if bc and bc.show then bc.show("DEPRESSURISATION", al.line, 4.5, "alarm"); al.banner = true end
          local fx = ref("sfx")
          if fx and fx.caption then pcall(fx.caption, "DEPRESSURISATION: " .. why) end
        end
        if log then log(string.format("cabin_air: DEPRESSURISATION %s (%s) %.2f atm: %s", m.label, tostring(c.id), s.p, why)) end
      elseif al and not venting then
        alarms_[key] = nil
        if s.p < P_ALARM then c.pres[m.id] = false end
      elseif al and al.banner then
        -- the banner still up: its time-left follows the reading, as the gauge does
        local bc = ref("big_caption")
        if bc and bc.current == "DEPRESSURISATION" and bc.retext then
          al.line = alarm_line(al.label or m.label, al.cause, s)
          bc.retext("DEPRESSURISATION", al.line)
        else al.banner = nil end
      end
      if al and near and now() - al.snd_t >= ALARM_EVERY and audio and audio.play then
        al.snd_t = now()
        if avatar.v and vid_of(avatar.v) == c.id then pcall(audio.play, "audio/sfx/crew_alarm.ogg", { track = "SFX", volume = 0.5 })
        elseif valid(v.node) then pcall(audio.play, "audio/sfx/crew_alarm.ogg", v.node, { maxDistance = 45, track = "SFX", volume = 0.5 }) end
      end
      -- the air going bad round the crew, said once
      if (c.crew[i] or 0) > 0 and not s.breathable and not s.venting then
        if not c.said[m.id] and near then
          c.said[m.id] = true
          local bc = ref("big_caption")
          if bc and bc.show then bc.show("CABIN AIR", string.format("The %s: %s.", m.label, tostring(s.why)), 4.0, "alarm") end
          lastAlarm = { vid = c.id, mod = i, label = m.label, cause = s.why, t = now(), kind = "air" }
        end
      elseif s.breathable then c.said[m.id] = nil end
    end
  end
end
function alarms() return alarms_ end

-- ── events: who sits where, boarding, EVA ───────────────────────────────────
local function events(v, c)
  local cr = ref("crew")
  local id = cr and cr.activeId and cr.activeId()
  local aboard = v.crewAboard == true
  local u = (aboard and id and v.memberSlot) and v.memberSlot(id) or nil
  -- stepped out: the hatch of the part they left opens (and the air goes)
  if c.wasAboard and not aboard and (v.leftAt or -1) ~= c.leftAt then
    local from = v.lastExitUid or c.seat
    local i = from and c.G.modOf[from]
    local k = from and door_at(c, from, "hatch")
    if i and k then
      local ok, warn = set_door(v, c, k, "open", "eva")
      c.evaK = k
      -- (who is left inside now: the seats as they are, the one who left not among them)
      local left = 0
      for _, s in ipairs(v.seatsOf and v.seatsOf() or {}) do if s.taken and s.taken ~= id and c.G.modOf[s.uid] == i then left = left + 1 end end
      c.crew[i] = left
      -- The hatch shuts behind them (Ty 11-12: "hatches don't auto-close, so
      -- all the air leaks out"): the crew left inside close it, and the last
      -- one out pulls it to from outside once clear of it. A hatch opened
      -- by hand (its menu) is propped and stays open: that clears this.
      c.closeAt = { k = k, t = now() + (left > 0 and CLOSE_BEHIND or SELF_CLOSE) }
    end
  end
  -- boarded: the hatch they came in by is sealed, the regulator refills
  if aboard and not c.wasAboard and u then
    local k = door_at(c, u, "hatch")
    if k and c.S and c.S[k] ~= "sealed" then
      set_door(v, c, k, "sealed", "board")
    end
    -- (scn_vacuum) and the hatch they went out by, if it is still open: the
    -- crew position boarding picks can be the next can along, and the hab
    -- they left stayed open to vacuum for good (its bottles never fed it)
    local ke = c.evaK
    c.evaK = nil
    if ke and ke ~= k and c.S and c.S[ke] == "open" then set_door(v, c, ke, "sealed", "board") end
  end
  if c.closeAt and now() >= c.closeAt.t then
    local k = c.closeAt.k
    c.closeAt = nil
    if c.S and c.S[k] == "open" then set_door(v, c, k, "sealed", "crew") end
  end
  c.wasAboard, c.leftAt = aboard, v.leftAt
  if u then c.seat = u end
end

-- ── context rows (the part's menu) ──────────────────────────────────────────
local function air_line(s)
  if not s then return "—" end
  local t = string.format("%.2f atm · O2 %.0f %% · CO2 %.2f %%", s.p or 0, 100 * (s.o2 or 0) / math.max(s.p or 0, 1e-6), 100 * (s.co2 or 0) / math.max(s.p or 0, 1e-6))
  if s.venting then t = t .. " · VENTING" end
  return t
end
airLine = air_line

-- part_info's CABIN section for a craft part (readings): { rows } | nil
function infoRows(t)
  if not enabled() then return nil end
  local v, uid = t and t.vessel, t and t.uid
  if not (v and uid) then return nil end
  local c = craft(v)
  if not c then return nil end
  local i = c.G.modOf[uid]
  local k = (not i) and door_at(c, uid, "port") or nil
  if k then i = c.G.doors[k].a end
  if not i then return nil end
  local G = "Cabin"
  local out = {}
  out[#out + 1] = { type = "info", id = "ca_mod", group = G, label = "MODULE",
    value = function() local s = statusOf(v, i); return s and string.format("%s · %.1f m³%s", s.label, s.V or 0, (s.crew or 0) > 0 and string.format(" · %d crew", s.crew) or "") or "—" end }
  out[#out + 1] = { type = "info", id = "ca_air", group = G, label = "AIR", value = function() return air_line(statusOf(v, i)) end,
    warn = function() local s = statusOf(v, i); return s ~= nil and (not s.breathable or s.venting) end }
  out[#out + 1] = { type = "meter", id = "ca_res", group = G, label = "RESERVE",
    frac = function() local s = statusOf(v, i); return s and (s.qcap or 0) > 0 and (s.reserve or 0) / s.qcap or 0 end,
    value = function() local s = statusOf(v, i); return s and string.format("%.1f / %.0f atm·m³", s.reserve or 0, s.qcap or 0) or "—" end }
  local hp = v.partHp and v.partHp(uid)
  if c.G.modOf[uid] and hp and hp < 0.5 then
    out[#out + 1] = { type = "info", id = "ca_leak", group = G, label = "LEAK", warn = true,
      value = function()
        local h = v.partHp(uid) or 1
        local A = holeArea(h)
        if A <= 0 then return "patched" end
        local s = statusOf(v, i)
        return string.format("%.1f cm² hole · %.3f atm·m³/s out%s", A * 1e4, (s and s.rate) or 0, (s and s.untilBad) and (" · unbreathable in " .. fmt_s(s.untilBad)) or "")
      end }
  end
  local s = statusOf(v, i)
  if s and s.untilBad and not (hp and hp < 0.5) then
    out[#out + 1] = { type = "info", id = "ca_eta", group = G, label = "VENTING", warn = true, value = function() local s2 = statusOf(v, i); return s2 and s2.untilBad and ("unbreathable in " .. fmt_s(s2.untilBad)) or "holding" end }
  end
  return out
end

local function door_rows(v, c, uid, out, ctx)
  local k, d = door_at(c, uid)
  if not k or d.kind == "breach" then return end
  local G = d.kind == "port" and "Docking hatch" or "Hatch"
  out[#out + 1] = { type = "info", id = "ca_hs", group = G, label = "HATCH",
    value = function() local S = door_states(v, c); return ({ open = "OPEN", shut = "shut · valve open", sealed = "sealed" })[S[k]] or "sealed" end,
    warn = function() local S = door_states(v, c); return S[k] == "open" end }
  local labels = { open = "Open the hatch", shut = "Shut it, valve open (equalise)", sealed = "Seal the hatch" }
  for _, st in ipairs({ "open", "shut", "sealed" }) do
    out[#out + 1] = { type = "action", id = "ca_h_" .. st, group = G, keep = true, label = labels[st], danger = (st == "open") or nil,
      enabled = function() local S = door_states(v, c); return S[k] ~= st and whyNot(v, uid, st) == nil end,
      why = function() local S = door_states(v, c); if S[k] == st then return "it is " .. st end return whyNot(v, uid, st) end,
      tip = function() return warnOfDoor(v, k, st) end,
      act = function()
        local ok, w = set_door(v, c, k, st, "hand")
        if not ok then return false, w end
        if ctx and ctx.toast then ctx.toast(w or ("hatch " .. st), w ~= nil) end
        return true, w
      end }
  end
end

local function provider(t, ctx)
  if not enabled() then return {} end
  local v, uid = t and t.vessel, t and t.uid
  if not (v and uid) or v.structureMode then return {} end
  local c = craft(v)
  if not c or #c.G.mods == 0 then return {} end
  local out = {}
  local i = c.G.modOf[uid]
  door_rows(v, c, uid, out, ctx)
  if i then
    local G = "Life support"
    out[#out + 1] = { type = "toggle", id = "ca_reg", group = G, label = "Air regulator", keep = true,
      on = function() return v.partSt(uid, "creg") ~= "off" end, onText = "AUTO", offText = "OFF",
      tip = "Feeds the reserve's air into the cabin under 0.97 atm",
      act = function(want)
        step(v, c, agency_now())
        v.partSt(uid, "creg", (not want) and "off" or false, true)
        nets_of(v, c)
        return true, (not want) and "The regulator is off: nothing refills the cabin." or nil
      end }
    out[#out + 1] = { type = "toggle", id = "ca_vent", group = G, label = "Vent valve", keep = true, danger = true,
      on = function() return v.partSt(uid, "cvent") == true end, onText = "OPEN", offText = "SHUT",
      act = function(want)
        step(v, c, agency_now())
        v.partSt(uid, "cvent", want and true or false, true)
        nets_of(v, c)
        local s = statusOf(v, i)
        if want and s and s.p > (c.out and c.out.p or 0) + 0.05 then
          return true, string.format("The %s vents through its valve: unbreathable in %s.", s.label, fmt_s(s.untilBad))
        end
        return true
      end }
    -- the patch: a Repair Kit over the hole (item_hand's timed job, to PATCH_HP)
    local hp = v.partHp and v.partHp(uid)
    local H = ref("item_hand")
    if hp and hp > 0 and hp < 0.5 and H and H.startRepair then
      out[#out + 1] = { type = "action", id = "ca_patch", group = G, label = "Patch the leak",
        hint = function() local I = ref("items"); return I and I.repairSecs and string.format("%.0f s", I.repairSecs(v.partHp(uid) or hp) * 0.4) or nil end,
        enabled = function() return H.repairWhyNot(t, ctx) == nil end,
        why = function() return H.repairWhyNot(t, ctx) end,
        act = function() return H.startRepair(t, ctx, { patch = true }) end }
    end
    -- the helmet, from the seat (the avatar in this module)
    local su = ref("suit")
    if su and su.setHelmet and avatar.v and vid_of(avatar.v) == c.id and avatar.mod == i then
      local on = su.helmetOn and su.helmetOn()
      out[#out + 1] = { type = "action", id = "ca_helmet", group = "Suit", keep = true, label = on and "Remove helmet" or "Put on helmet",
        enabled = function() if not su.helmetOn() then return true end local ok = helmetAboard(); return ok == true end,
        why = function() local _, w = helmetAboard(); return w end,
        act = function() local ok2, w = su.setHelmet(not su.helmetOn()); return ok2 ~= false, w end }
    end
  end
  return out
end
providerFn = provider

-- ── the IVA gauge ───────────────────────────────────────────────────────────
local PHOS, WARN, DANGER = { 0.55, 0.86, 0.48 }, { 1.0, 0.80, 0.28 }, { 0.97, 0.34, 0.25 }
local TONE = { warn = "hud/valueWarn", danger = "hud/valueDanger" }
local function iva_view()
  local iv = ref("iva")
  local w = iv and iv.view
  if type(w) == "table" and w.v and w.uid then return w.v, w.uid end
  return nil
end

function gaugeOf()
  local v, uid = iva_view()
  local alarm_only = false
  if not v then
    -- outside the seat view: only while the avatar's module is in trouble
    if not (avatar.v and avatar.mod and avatar.status and (avatar.status.venting or not avatar.status.breathable)) then return nil end
    v, uid, alarm_only = avatar.v, avatar.uid, true
  end
  local c = craft(v)
  local i = c and c.G.modOf[uid]
  if not i then return nil end
  local s = statusOf(v, i)
  if not s then return nil end
  local hole = 0
  for _, L in ipairs(s.leaks or {}) do hole = hole + L.A end
  return { label = s.label, p = s.p, o2 = s.o2, co2 = s.co2, share = s.p > 0 and s.o2 / s.p or 0, breathable = s.breathable, why = s.why,
           venting = s.venting, untilBad = s.untilBad, eta = eta_text(s), at = s.at, reserve = s.reserve, qcap = s.qcap, hole = hole, crew = s.crew,
           alarm_only = alarm_only, outside = c.out and c.out.p or 0 }
end

-- the node's UiElement (its `visible` is the layer's: the scene starts it hidden)
local ui_el = nil
local function show_el(node, on)
  if not ui_el then ui_el = node.getcomponent and node:getcomponent("UiElement") or nil end
  if ui_el and ui_el.visible ~= on then ui_el.visible = on end
end
local function draw(node)
  local g = enabled() and gaugeOf() or nil
  gauge = g
  -- (cinematic mode hides the interface: the gauge with it)
  local pc = ref("planet_camera")
  local cine = pc and (pc.cinematic or pc.freecam)
  if not g or cine then
    if drawn then ui.make(node, {}); drawn = false end
    show_el(node, false)
    return
  end
  show_el(node, true)
  local BAR = 120
  local function row(key, label, frac, value, tone, color)
    local len = math.floor(math.max(0, math.min(1, frac)) * (BAR - 2) + 0.5)
    return { "row", key = key, w = "100%", h = 18, pad = 0, gap = 6, align = "center",
      { "text", key = "l", style = "hud/micro", w = 44, h = 12, text = label, textAlign = "start" },
      { "box", key = "t", style = "hud/track", w = BAR, h = 8,
        { "box", key = "f", x = 1, y = 1, w = len, h = 6, radius = 1, fill = color } },
      { "text", key = "v", style = TONE[tone] or "hud/value", w = 70, h = 16, text = value, textAlign = "end" } }
  end
  local pt = g.p < 0.5 and "danger" or (g.p < 0.9 and "warn" or nil)
  local ot = (g.o2 or 0) < 0.16 and "danger" or ((g.o2 or 0) < 0.18 and "warn" or nil)
  local ct = (g.co2 or 0) > 0.02 and "danger" or ((g.co2 or 0) > 0.01 and "warn" or nil)
  local rf = (g.qcap or 0) > 0 and (g.reserve or 0) / g.qcap or 0
  local rt = rf <= 0.02 and "danger" or (rf < 0.2 and "warn" or nil)
  local col = function(t) return t == "danger" and DANGER or (t == "warn" and WARN or PHOS) end
  local items = {
    { "text", key = "h", style = "hud/micro", w = "100%", h = 12, text = "CABIN · " .. string.upper(g.label or "") },
    row("p", "PRESS", math.min(1, g.p / 1.0), string.format("%.2f atm", g.p), pt, col(pt)),
    row("o", "O2", math.min(1, (g.o2 or 0) / 0.30), string.format("%.0f kPa", (g.o2 or 0) * 101.325), ot, col(ot)),
    row("c", "CO2", math.min(1, (g.co2 or 0) / 0.03), string.format("%.2f kPa", (g.co2 or 0) * 101.325), ct, col(ct)),
    row("r", "RESERVE", rf, string.format("%.1f/%.0f", g.reserve or 0, g.qcap or 0), rt, col(rt)),
  }
  local warn = nil
  if g.venting then
    local e = g.eta
    warn = (g.hole > 0 and string.format("LEAK %.1f cm²", g.hole * 1e4) or "VENTING")
      .. ((e == "unbreathable now" and " · AIR UNBREATHABLE") or (e and (" · " .. e)) or "")
  elseif not g.breathable then warn = "AIR: " .. tostring(g.why or "unbreathable")
  end
  if warn then items[#items + 1] = { "text", key = "w", style = "hud/valueDanger", w = "100%", h = "fit", wrap = true, text = warn } end
  ui.make(node, {
    { "col", key = "cabin", style = "hud/instrument", pin = "right", x = -16, y = 40, w = 264, h = "fit", pad = 10, gap = 5, items = items,
      function(it) return it end },
  })
  drawn = true
end

-- ── the frame ───────────────────────────────────────────────────────────────
local reg_on, reg_t = false, -10
local function register()
  if reg_on or now() - reg_t < 1.0 then return end
  reg_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then reg.register("part", provider, { id = "cabin_air", order = 36 }); reg_on = true end
end

-- Step every craft's air now (probes).
function tickNow()
  local a = agency_now()
  for _, v in ipairs(vessels()) do
    if valid(v.node) and not v.structureMode then local c = craft(v); if c then step(v, c, a) end end
  end
  avatar_tick()
end

-- The event pass now (probes): boarding, EVA, the hatch closed behind.
function eventsNow()
  for _, v in ipairs(vessels()) do
    if valid(v.node) and not v.structureMode then local c = craft(v); if c and #c.G.mods > 0 then events(v, c) end end
  end
  avatar_tick()
end

function start(node) end

function update(node, dt)
  register()
  if not enabled() then
    if drawn then ui.make(node, {}); drawn = false end
    show_el(node, false)
    for key, s in pairs(sounds) do if s.h and type(s.h) ~= "boolean" then pcall(function() s.h:stop() end) end sounds[key] = nil end
    avatar.v = nil
    return
  end
  local t = now()
  if t - ev_t >= EVENT_EVERY then
    ev_t = t
    for _, v in ipairs(vessels()) do
      if valid(v.node) and not v.structureMode then
        local c = craft(v)
        if c and #c.G.mods > 0 then events(v, c) end
      end
    end
    avatar_tick()
  end
  if t - air_t >= AIR_EVERY then
    local real = t - air_t
    air_t = t
    local t0 = os and os.clock and os.clock() or 0
    local a = agency_now()
    local seen, n, nm = {}, 0, 0
    for _, v in ipairs(vessels()) do
      if valid(v.node) and not v.structureMode then
        local c = craft(v)
        if c then
          seen[c.id] = true
          if #c.G.mods > 0 then
            local a0 = c.a or a
            step(v, c, a)
            crew_records(v, c, math.max(0, a - a0))
            local near = near_avatar(v)
            alarm_tick(v, c, near)
            hiss_tick(v, c, near)
            n, nm = n + 1, nm + #c.G.mods
          end
        end
      end
    end
    for id in pairs(C) do
      if not seen[id] then
        for key, s in pairs(sounds) do
          if key:sub(1, #tostring(id) + 1) == tostring(id) .. ":" then if s.h and type(s.h) ~= "boolean" then pcall(function() s.h:stop() end) end sounds[key] = nil end
        end
        C[id] = nil
      end
    end
    avatar_tick()
    PROF.ms = ((os and os.clock and os.clock() or 0) - t0) * 1000
    PROF.n, PROF.crafts, PROF.mods = PROF.n + 1, n, nm
  end
  draw(node)
end

-- vessel_controller.undock asks before it lets go of port `uid` on craft
-- node `vid`: → the warning when the docking hatch is not sealed, else nil
function undockWarn(vid, uid)
  if not enabled() then return nil end
  local c = C[vid]
  if not (c and c.v and c.G) then return nil end
  local k, d = door_at(c, uid, "port")
  if not k then return nil end
  local S = door_states(c.v, c)
  if S[k] == "sealed" then return nil end
  local sa, sb = statusOf(c.v, d.a), d.b > 0 and statusOf(c.v, d.b) or nil
  return string.format("Undocking with the docking hatch %s: the %s%s vent%s to the outside.", S[k] == "open" and "open" or "unsealed",
    sa and sa.label or "module", sb and (" and the " .. sb.label) or "", sb and "" or "s")
end

-- Scenarios: craft v's module `which` ("crew" | "worst" | nil | index | a part
-- id prefix) → status | nil
function cabinOf(v, which)
  local c = craft(v)
  if not (c and #c.G.mods > 0) then return nil end
  if type(which) == "number" then return statusOf(v, which) end
  -- (scn_vacuum) "#<uid>": the module that part belongs to (a craft JSON's uids are fixed)
  local pu = type(which) == "string" and tonumber(which:match("^#(%d+)$"))
  if pu then local i = c.G.modOf[pu]; return i and statusOf(v, i) or nil end
  if type(which) == "string" and which ~= "crew" and which ~= "worst" then
    local recs = v.aboardRecs and v.aboardRecs() or {}
    for i, m in ipairs(c.G.mods) do
      for _, u in ipairs(m.uids) do local d = recs[u]; if d and tostring(d.id or ""):sub(1, #which) == which then return statusOf(v, i) end end
    end
    return nil
  end
  if which == "crew" then
    local best, bc = nil, -1
    for i in ipairs(c.G.mods) do if (c.crew[i] or 0) > bc then best, bc = i, c.crew[i] or 0 end end
    return statusOf(v, best or 1)
  end
  local worst = nil
  for i in ipairs(c.G.mods) do local s = statusOf(v, i); if s and (not worst or s.p < worst.p) then worst = s end end
  return worst
end
