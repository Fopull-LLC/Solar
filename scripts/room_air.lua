-- ROOM_AIR — the air in the rooms a structure's pieces close (sandbox plan S3,
-- PLAN §1.5; docs/base-building.md §14). On the Build Kit node beside
-- rooms.lua (the flood fill). The rulebook half is pure and loads in a luajit
-- test (tests/smoke_rooms.lua); the scene half keeps each structure's rooms,
-- their air, the airlocks and the ROOMS overlay.
--
-- ── THE AIR (per room; a NETWORK is rooms joined by open doors) ─────────────
-- Amounts in atm·m³ (1 m³ of gas at 1 atm): N (nitrogen and the rest), x
-- (oxygen), c (carbon dioxide); p = (N + x + c) / V. A crew member breathes
-- USE of O2 a second and breathes out MAKE of CO2 (0.84 kg and 1.0 kg a day).
-- The room's life support (live pieces on the base grid, parts_kit `life`):
--   O2 Generator   makes O2 up to its rate while the room is under 21 % of an
--                  atmosphere of it, holds it there (making what the crew
--                  breathe), and idles over 105 %
--   CO2 Scrubber   takes CO2 out up to its rate, down to none
--   Air Tank Rack  compressed air on a regulator: it feeds air at its flow
--                  from FEED_ON (97 %) of an atmosphere up to 1 atm. It is a
--                  valve, not a pump: it needs no power. (A leak shuts it.)
-- A network open to the outside (an open door to it, a leaky room, a gap)
-- VENTS: every amount relaxes to the outside's, e^(-t/τ), τ = VENT_S · V /
-- openings (a 9 m³ room loses 95 % in about 13 s through one door: PLAN D6's
-- "60 s × m³/40"). The regulator and the machines stand down while it does.
--
-- ── THE CLOSED FORM ─────────────────────────────────────────────────────────
-- Between events every rate is constant, so the state is a straight line (and
-- venting is the exponential, also exact). `advance(st, M, dt)` steps to the
-- next event (the O2 reaching 21 % or 105 %, the CO2 clearing, the O2 running
-- out, the regulator opening at 97 % or closing at 1 atm, a tank emptying),
-- applies it and carries on, so ONE call of any dt lands where any number of
-- small calls do (smoke_rooms checks an hour in one step against 3,600 steps
-- to 1e-6), and a structure is caught up on the save clock when it loads in
-- one call per network (capped at CATCH_MAX). This is base_grid's `seg`
-- pattern and thermal.advance's: never forward Euler.
--
-- BREATHABLE: p ≥ 0.5 atm, O2 ≥ 0.16 atm, CO2 ≤ 0.02 atm. A crew member in a
-- breathable room breathes it, not the suit (suit.breathableAt asks airAt
-- first: the helmet may come off there and planet_walker draws no suit air).
--
-- ── THE AIRLOCK (rooms.lua marks a small sealed room with an Airlock Wall and
-- a second door as one) ──────────────────────────────────────────────────────
-- Its doors are INTERLOCKED: kit_live asks gate(sid, uid, want) and only the
-- chamber's chosen door may open, only with every other door of it shut and
-- the chamber at the pressure on that door's far side. A crew member outside
-- by a door asks for that door; inside the chamber, for the door they did not
-- come in by. While the pressures differ the chamber CYCLES: a pump moves air
-- between the chamber and the hab (PUMP atm·m³/s; a 9 m³ chamber in ~25 s),
-- with the pump's hiss, and a chime when it is done.
--
-- Every OTHER door is held shut by a pressure difference across it (HOLD_DP)
-- until its menu forces it ("Force it open (vents Room 2)").
--
-- ── WHEN THINGS RUN (never per frame) ───────────────────────────────────────
--   rooms      solved when a structure's sealing pieces change (rooms.signatureOf,
--              compared when structures.version moves; debounced SOLVE_WAIT)
--   air        advanced every AIR_EVERY s on the agency clock, and at once when
--              a door opens or shuts, the crew moves room, or the power goes
--   airlocks   the chamber's want and pump while the crew is within 30 m of it
--   the crew   which room, every CREW_EVERY s
-- An alarm sounds while a room that held air vents (DEPRESSURISATION, with
-- the cause: the door left open, the gap), and the air going bad is said once.
--
-- SAVE: air.<sid> = { a (agency clock), rooms = { { k (the room's key), N, x, c, V, f } … },
-- tanks = { { u (uid), q } … } } — lists, not tables keyed by number: the
-- save hands keys like a room's 12-digit key back as it pleases
--
-- Probes: state(sid), solveNow(sid), roomsOf(sid), airOf(sid, rid), crewRoom(),
-- alarms(), lastAlarm, setVacuum(on), advanceNow(), chamberOf(sid, rid),
-- overlay, overlayAlways, PROF.

O2N = 0.21                       -- O2's share of normal air
USE = 0.84 / 1.429 / 86400       -- O2 a crew member breathes, atm·m³/s
MAKE = 1.0 / 1.977 / 86400       -- CO2 they breathe out, atm·m³/s
FEED_ON = 0.97                   -- the regulator opens under this (× 1 atm)
VENT_S = 0.5                     -- τ per m³ per opening (s)
O2_HIGH = 1.05                   -- the generator idles over this × 21 %
PUMP = 0.35                      -- an airlock's pump, atm·m³/s
CATCH_MAX = 30 * 86400
EPS = 1e-9
-- breathable
P_MIN, O2_MIN, CO2_MAX = 0.5, 0.16, 0.02

local min, max, abs, exp, sqrt = math.min, math.max, math.abs, math.exp, math.sqrt

-- ── pure: one network's air ─────────────────────────────────────────────────
-- st = { N, x, c, q (the tanks' store), feed (the regulator open) }
-- M  = { V, crew, G (O2 a second), S (CO2 a second), F (the regulator's flow),
--        tau (nil = sealed), pout, xout (the outside's pressure and O2 share) }
-- → st, rep = { segs, events = { name … } }
function advance(st, M, dt, rep)
  rep = rep or { segs = 0, events = {} }
  rep.segs = rep.segs or 0
  rep.events = rep.events or {}
  if not dt or dt <= 0 then return st, rep end
  local V = M.V
  if M.tau then
    local k = exp(-dt / M.tau)
    local Nt, xt = V * (M.pout or 0) * (1 - (M.xout or 0)), V * (M.pout or 0) * (M.xout or 0)
    st.N = Nt + (st.N - Nt) * k
    st.x = xt + (st.x - xt) * k
    st.c = st.c * k
    st.feed = false
    rep.segs = rep.segs + 1
    return st, rep
  end
  local G, S, F = M.G or 0, M.S or 0, M.F or 0
  local xs = O2N * V
  local xh = O2_HIGH * xs
  local left = dt
  local guard = 0
  while left > 0 do
    guard = guard + 1
    if guard > 20000 then break end
    -- the regulator opens under FEED_ON (an instant: no time passes)
    local n = st.N + st.x + st.c
    if not st.feed and st.q > EPS and F > 0 and n < FEED_ON * V - EPS then
      st.feed = true
      rep.events[#rep.events + 1] = "feed_on"
    end
    local crew = (st.x > EPS) and (M.crew or 0) or 0
    local use, make = crew * USE, crew * MAKE
    local g, xr = 0, nil
    if G > 0 then
      if st.x < xs - EPS then g, xr = G, -1
      elseif st.x <= xh + EPS then g, xr = min(G, use), 0
      else g, xr = 0, 1 end
    end
    local f = (st.feed and st.q > EPS and F > 0) and F or 0
    local dx = g - use + O2N * f
    local s = 0
    if S > 0 then if st.c > EPS then s = S else s = min(S, make) end end
    local dc = make - s
    local dN = (1 - O2N) * f
    local dn = dN + dx + dc
    local te, ev = left, nil
    local function at(t, e) if t >= 0 and t < te then te, ev = t, e end end
    if xr == -1 and dx > 0 then at((xs - st.x) / dx, "o2_at") end
    if xr == 0 and dx > 0 then at((xh - st.x) / dx, "o2_high") end
    if xr == 1 and dx < 0 then at((st.x - xh) / -dx, "o2_band") end
    if dx < 0 and st.x > EPS then at(st.x / -dx, "o2_out") end
    if st.c > EPS and dc < 0 then at(st.c / -dc, "co2_clear") end
    if f > 0 then
      if dn > 0 then at((V - n) / dn, "full") end
      at(st.q / f, "tank_empty")
    elseif not st.feed and st.q > EPS and F > 0 and dn < 0 then
      at((n - FEED_ON * V) / -dn, "feed_on")
    end
    st.N = max(0, st.N + dN * te)
    st.x = max(0, st.x + dx * te)
    st.c = max(0, st.c + dc * te)
    st.q = max(0, st.q - f * te)
    left = left - te
    rep.segs = rep.segs + 1
    if ev then
      rep.events[#rep.events + 1] = ev
      if ev == "o2_at" then st.x = xs
      elseif ev == "o2_high" then st.x = xh + 2 * EPS
      elseif ev == "o2_band" then st.x = xh
      elseif ev == "o2_out" then st.x = 0
      elseif ev == "co2_clear" then st.c = 0
      elseif ev == "full" then st.feed = false
      elseif ev == "tank_empty" then st.q = 0
      elseif ev == "feed_on" then st.feed = true end
    else
      break
    end
  end
  return st, rep
end

-- What the air is: → { p, o2 (atm of O2), co2 (atm), share (O2 of normal),
-- breathable, why }
function statusOf(st, V)
  if not V or V <= 0 then return { p = 0, o2 = 0, co2 = 0, share = 0, breathable = false, why = "no room" } end
  local p = (st.N + st.x + st.c) / V
  local o2, co2 = st.x / V, st.c / V
  local why = nil
  if p < P_MIN then why = string.format("%.2f atm: too thin to breathe", p)
  elseif o2 < O2_MIN then why = string.format("O2 %.2f atm: too little oxygen", o2)
  elseif co2 > CO2_MAX then why = string.format("CO2 %.3f atm: the scrubbers aren't keeping up", co2) end
  return { p = p, o2 = o2, co2 = co2, share = o2 / O2N, breathable = why == nil, why = why }
end

-- How long the O2 lasts `crew` with generators making G: → s | nil (as long as the power)
function o2Left(st, V, crew, G)
  local need = (crew or 0) * USE - (G or 0)
  if need <= 0 then return nil end
  return max(0, st.x - O2_MIN * V) / need
end

-- A room's air as the outside's (a room closed round air that was there).
function outsideAir(V, pout, xout)
  return { N = V * pout * (1 - xout), x = V * pout * xout, c = 0 }
end

-- ── the scene half ──────────────────────────────────────────────────────────

AIR_EVERY = 1.0
SOLVE_WAIT = 0.5
CREW_EVERY = 0.1
SAVE_EVERY = 5.0
ALARM_EVERY = 2.5
OPEN_T = 0.02          -- a door open past this leaks
HOLD_DP = 0.1          -- a door with this much pressure across it is held shut
CYCLE_R = 30.0         -- airlocks are worked while the crew is this near
CHAM_EVERY = 0.095     -- how often (s): the interlock answers kit_live from this
PROF = { solve_ms = 0, n_solve = 0, air_ms = 0, n_air = 0, cells = 0 }

overlay = false        -- the ROOMS overlay (F1 with the kit open)
overlayAlways = false  -- (probes: drawn with the kit shut)
lastAlarm = nil
forceVacuum = false    -- (probes: the outside is vacuum whatever the world)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function RL() return ref("rooms") end
local function valid(n) return n ~= nil and n.valid ~= false end

local S = {}           -- sid → structure state (below)
local ver = -1
local sigs = {}        -- sid → seal signature as last solved
local pending = {}     -- sid → time a re-solve was asked
local air_t, crew_t, save_t, cham_t = -10, -10, -10, -10
local crew = { sid = nil, rid = nil, t = -10 }
local alarms_ = {}     -- "sid:rid" → { sid, rid, t0, cause, snd_t }

function state(sid) return S[sid] end
function roomsOf(sid) local s = S[sid]; return s and s.R or nil end
function alarms() return alarms_ end
function crewRoom() return crew.sid, crew.rid end
function setVacuum(on) forceVacuum = on == true; for _, s in pairs(S) do s.out = nil end end

-- The outside where structure `rec` stands: p (atm), O2 share. (suit.lua's
-- rules: a world's air, its oxygen, how thick it is here.)
local function outside_of(rec)
  if forceVacuum then return 0, 0 end
  local cl, ae = ref("climate"), ref("aero")
  local w = cl and cl.worldOf and cl.worldOf(rec.b)
  if not w or (w.atmo or 0) < 0.05 then return 0, 0 end
  local oxy = 0
  if ae and ae.oxygen then local ok, o = pcall(ae.oxygen, w); oxy = ok and (o or 0) or 0 end
  local b = space and space.body and space.body(rec.b)
  local share = 1
  if b then
    local alt = sqrt(rec.x * rec.x + rec.y * rec.y + rec.z * rec.z) - (w.radius or b.radius or 0)
    local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or b.radius or 800)
    if ae and ae.airShare then
      local ok, sh = pcall(ae.airShare, math.max(alt, -0.25 * H), H, w.atmoScaleH)
      share = ok and sh or 1
    else
      local f = math.max(0, 1 - math.max(alt, 0) / H)
      share = f * f
    end
  end
  local p = math.max(0, math.min(1.2, share * math.min(1.5, (w.atmo or 0) / 0.45)))
  return p, (oxy >= 0.5) and O2N or 0
end
local function out_of(s, rec)
  if not s.out then local p, xo = outside_of(rec); s.out = { p = p, x = xo } end
  return s.out.p, s.out.x
end

-- Is structure sid's base grid up? (a real grid, not short with its battery flat)
local function powered(sid)
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  if not g then return false end
  local M = BG.model and BG.model(g.id)
  local real = #(g.bases or {}) > 0 or (M and ((M.sources or 0) > 0 or (M.C or 0) > 0))
  if not real then return false end
  local s = BG.status and BG.status(g.id)
  return not (s and (s.short or 0) > 0 and (s.stored or 0) <= 0)
end

local function door_open(sid, uid)
  local KL = ref("kit_live")
  local o = KL and KL.doorOpen and KL.doorOpen(sid, uid)
  return (o or 0) > OPEN_T, o or 0
end

-- ── a structure's rooms and their air ───────────────────────────────────────
-- s = { R, rec, air = { [rid] = { N, x, c, f } }, tanks = { [uid] = q }, life = { … },
--       a (agency time advanced to), nets, netsDirty, cham = { [rid] = chamber },
--       dch = { [uid] = rid }, pres = { [rid] = bool }, pow, crewIn = { [rid] = n } }

local function solve(sid)
  local ST, R_ = ref("structures"), RL()
  local rec = ST and ST.get(sid)
  if not (rec and R_) then S[sid] = nil return end
  local w0 = wall()
  local old = S[sid]
  local R = R_.solve(rec, defs, wall)
  PROF.n_solve = PROF.n_solve + 1
  PROF.solve_ms = R.ms or 0
  PROF.cells = R.cells or 0
  local s = { R = R, rec = rec, air = {}, tanks = {}, life = {}, a = old and old.a or nil, cham = {}, dch = {}, pres = {},
              crewIn = {}, netsDirty = true, out = old and old.out, pow = old and old.pow,
              forced = old and old.forced or {}, held = {} }
  local pout, xout = out_of(s, rec)
  -- the air the new rooms hold: the old rooms' by the cells they share, the
  -- outside's in a cell no room held (a wall closed round open air)
  local conc = {}
  if old and old.R and old.R.rooms then
    for _, r in ipairs(old.R.rooms) do
      local a = old.air[r.id]
      if a and r.m3 > 0 then
        local k = { a.N / r.m3, a.x / r.m3, a.c / r.m3, a.f }
        for _, c in ipairs(r.cells) do conc[R_.cellKey(old.R, c)] = k end
      end
    end
  end
  local saved = nil
  if not old then
    saved = save and save.get and save.get("air." .. tostring(sid))
    if type(saved) ~= "table" then saved = nil end
    if saved and tonumber(saved.a) then s.a = tonumber(saved.a) end
  end
  for _, r in ipairs(R.rooms) do
    local N, x, c, f = 0, 0, 0, false
    local sv = nil
    for _, e in ipairs(saved and type(saved.rooms) == "table" and saved.rooms or {}) do
      if type(e) == "table" and tonumber(e.k) == r.key then sv = e end
    end
    if type(sv) == "table" and tonumber(sv.V) and tonumber(sv.V) > 0 then
      local k = r.m3 / tonumber(sv.V)
      N, x, c, f = (tonumber(sv.N) or 0) * k, (tonumber(sv.x) or 0) * k, (tonumber(sv.c) or 0) * k, sv.f == true
    else
      for _, cl in ipairs(r.cells) do
        local v = R_.cellV(R, cl)
        local k = conc[R_.cellKey(R, cl)]
        if k then N, x, c = N + k[1] * v, x + k[2] * v, c + k[3] * v; f = f or k[4]
        else N, x, c = N + v * pout * (1 - xout), x + v * pout * xout, c end
      end
    end
    s.air[r.id] = { N = N, x = x, c = c, f = f }
    if (N + x + c) / math.max(r.m3, 1e-6) >= 0.8 then s.pres[r.id] = true end
    if r.airlock then
      local C = { rid = r.id, doors = r.doors, wants = {}, entered = nil, target = nil, allow = nil, cyc = nil }
      if old and old.cham then for _, oc in pairs(old.cham) do if oc.key == r.key then C.entered = oc.entered end end end
      C.key = r.key
      s.cham[r.id] = C
      for _, u in ipairs(r.doors) do s.dch[u] = r.id end
    end
  end
  -- the life support: each live piece in the room its middle is in
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.life then
      local b = d.box or { 0, 0, 0, 0, 0, 0 }
      local cy = (p.y or 0) + (b[3] + b[4]) / 2
      local r = R_.roomAt(R, p.x or 0, cy, p.z or 0)
      local L = d.life
      s.life[#s.life + 1] = { uid = p.uid, rid = r and r.id or nil, life = L, label = d.label }
      if L.store then
        local q = old and old.tanks and old.tanks[p.uid]
        for _, e in ipairs(q == nil and saved and type(saved.tanks) == "table" and saved.tanks or {}) do
          if type(e) == "table" and tonumber(e.u) == p.uid then q = tonumber(e.q) end
        end
        if q == nil then q = L.store end   -- (a rack comes charged)
        s.tanks[p.uid] = math.max(0, math.min(L.store, q))
      end
    end
  end
  S[sid] = s
  if w0 then PROF.solve_ms = (wall() - w0) * 1000 end
end

-- The networks: rooms joined by open doors. → { { rooms = { rid … }, V, tau,
-- G, S, F, tanks, crew, openings, causes } … }, byRoom
local function nets_of(sid, s)
  local R = s.R
  local up = {}
  local function find_(a) while up[a] ~= a do a = up[a] end return a end
  for _, r in ipairs(R.rooms) do up[r.id] = r.id end
  local outDoors = {}
  for uid, d in pairs(R.doors) do
    if door_open(sid, uid) then
      if d.a == 0 or d.b == 0 then outDoors[#outDoors + 1] = d
      elseif up[d.a] and up[d.b] then
        local a, b = find_(d.a), find_(d.b)
        if a ~= b then up[math.max(a, b)] = math.min(a, b) end
      end
    end
  end
  local pow = s.pow
  local byRoot, out, byRoom = {}, {}, {}
  for _, r in ipairs(R.rooms) do
    local root = find_(r.id)
    local n = byRoot[root]
    if not n then
      n = { rooms = {}, V = 0, G = 0, S = 0, F = 0, tanks = {}, crew = 0, openings = 0, causes = {} }
      byRoot[root] = n
      out[#out + 1] = n
    end
    n.rooms[#n.rooms + 1] = r.id
    n.V = n.V + r.m3
    n.crew = n.crew + (s.crewIn[r.id] or 0)
    byRoom[r.id] = n
    if r.leaky then
      n.openings = n.openings + math.max(1, #r.leaks)
      for _, l in ipairs(r.leaks) do n.causes[#n.causes + 1] = l.label end
    end
  end
  -- (a door open to the outside: one opening)
  for _, d in ipairs(outDoors) do
    local n = byRoom[d.a == 0 and d.b or d.a]
    if n then n.openings = n.openings + 1; table.insert(n.causes, 1, string.format("the %s is open", d.label or "door")) end
  end
  for _, L in ipairs(s.life) do
    local n = L.rid and byRoom[L.rid]
    if n then
      if L.life.o2 and pow then n.G = n.G + L.life.o2 end
      if L.life.scrub and pow then n.S = n.S + L.life.scrub end
      if L.life.store then n.F = n.F + (L.life.flow or 0); n.tanks[#n.tanks + 1] = L end
    end
  end
  for _, n in ipairs(out) do
    if n.openings > 0 then n.tau = math.max(1.0, VENT_S * n.V / n.openings) end
  end
  return out, byRoom
end

local function nets(sid, s)
  if s.netsDirty or not s.nets then s.nets, s.byRoom = nets_of(sid, s); s.netsDirty = false end
  return s.nets, s.byRoom
end

-- Step structure sid's air to agency time a (exact, capped for a catch-up).
local function advance_struct(sid, s, a)
  if not s.a then s.a = a end
  local dt = math.min(a - s.a, CATCH_MAX)
  s.a = a
  if dt <= 0 then return end
  if dt > 60 then PROF.catch = dt end
  local pout, xout = out_of(s, s.rec)
  for _, n in ipairs(nets(sid, s)) do
    local st = { N = 0, x = 0, c = 0, q = 0, feed = false }
    for _, id in ipairs(n.rooms) do
      local A = s.air[id]
      st.N, st.x, st.c = st.N + A.N, st.x + A.x, st.c + A.c
      st.feed = st.feed or A.f == true
    end
    local cap = 0
    for _, L in ipairs(n.tanks) do st.q = st.q + (s.tanks[L.uid] or 0); cap = cap + L.life.store end
    if n.V > 0 then
      advance(st, { V = n.V, crew = n.crew, G = n.G, S = n.S, F = (st.q > EPS) and n.F or 0, tau = n.tau, pout = pout, xout = xout }, dt)
    end
    for _, id in ipairs(n.rooms) do
      local r = s.R.byId[id]
      local k = (n.V > 0) and r.m3 / n.V or 0
      s.air[id] = { N = st.N * k, x = st.x * k, c = st.c * k, f = st.feed }
    end
    for _, L in ipairs(n.tanks) do s.tanks[L.uid] = (cap > 0) and st.q * L.life.store / cap or 0 end
  end
end

-- The air in room rid of structure sid: → status (statusOf) + { V, sealed, venting, net }
function airOf(sid, rid)
  local s = S[sid]
  local r = s and s.R and s.R.byId[rid]
  if not r then return nil end
  local A = s.air[rid]
  local st = statusOf({ N = A.N, x = A.x, c = A.c }, r.m3)
  st.V, st.sealed, st.leaky, st.airlock = r.m3, r.sealed, r.leaky, r.airlock
  local _, byRoom = nets(sid, s)
  local n = byRoom and byRoom[rid]
  st.venting = n ~= nil and n.tau ~= nil
  st.causes = n and n.causes or {}
  st.crew = s.crewIn[rid] or 0
  st.G, st.S = n and n.G or 0, n and n.S or 0
  st.left = o2Left(A, r.m3, n and n.crew or 0, n and n.G or 0)
  return st
end

function solveNow(sid) solve(sid) end
function advanceNow()
  local a = agency_now()
  for sid, s in pairs(S) do advance_struct(sid, s, a) end
end
function chamberOf(sid, rid) local s = S[sid]; return s and s.cham[rid] or nil end

-- A structure's rooms in one line (the wall screen; the structure card).
function summary(sid)
  local s = S[sid]
  if not (s and s.R) then return nil end
  local n, sealed, m3, pmin, bad = 0, 0, 0, nil, 0
  for _, r in ipairs(s.R.rooms) do
    n = n + 1
    if r.sealed then sealed = sealed + 1 end
    m3 = m3 + r.m3
    local a = airOf(sid, r.id)
    if a then
      if r.sealed and (not pmin or a.p < pmin) then pmin = a.p end
      if not a.breathable then bad = bad + 1 end
    end
  end
  local L = { n = n, sealed = sealed, m3 = m3, pmin = pmin, bad = bad, powered = s.pow == true, life = #s.life }
  return L
end

-- ── the crew in the rooms ───────────────────────────────────────────────────
-- A world point → structure sid, room (this frame's body read).
local function locate(x, y, z)
  if not (space and space.dominant) then return nil end
  local dom = space.dominant(x, y, z)
  local b = dom and space.body(dom)
  if not b then return nil end
  local bx, by_, bz = x - b.x, y - b.y, z - b.z
  local KS = ref("kit_snap")
  local R_ = RL()
  if not (KS and R_) then return nil end
  for sid, s in pairs(S) do
    local rec = s.rec
    if rec.b == dom and s.R and #s.R.rooms > 0 then
      local dx, dy, dz = bx - rec.x, by_ - rec.y, bz - rec.z
      if dx * dx + dy * dy + dz * dz < 250 * 250 then
        local fr = KS.frameOf(rec)
        local lx = dx * fr.R.x + dy * fr.R.y + dz * fr.R.z
        local ly = dx * fr.U.x + dy * fr.U.y + dz * fr.U.z
        local lz = dx * fr.F.x + dy * fr.F.y + dz * fr.F.z
        local r = R_.roomAt(s.R, lx, ly, lz)
        if r then return sid, r, lx, ly, lz end
      end
    end
  end
  return nil
end

-- The air at a world point: → breathable, why, room | nil (in no room).
function airAt(x, y, z)
  local sid, r = locate(x, y, z)
  if not sid then return nil end
  local a = airOf(sid, r.id)
  if not a then return nil end
  if a.breathable then return true, nil, r, sid end
  return false, "The room's air: " .. tostring(a.why) .. ". The helmet stays on.", r, sid
end

local function crew_points()
  local out = {}
  local a = find and find("Astronaut")
  local pw = ref("planet_walker")
  if valid(a) and (not pw or pw.onFoot ~= false) then out[#out + 1] = { x = a.x, y = a.y, z = a.z, active = true } end
  local C = ref("crew")
  if C and C.roster and C.activeId then
    local act = C.activeId()
    for _, r in ipairs(C.roster()) do
      if r.status == "afoot" and r.id ~= act and r.body and r.x then
        local b = space.body(r.body)
        if b then out[#out + 1] = { x = b.x + r.x, y = b.y + r.y, z = b.z + r.z } end
      end
    end
  end
  return out
end

-- ── airlocks ────────────────────────────────────────────────────────────────
-- kit_live asks for every door of a chamber, every frame it steps it.
-- Any other door is HELD SHUT by a pressure difference across it (HOLD_DP:
-- 0.1 atm on a 0.9 x 2 m leaf is 19 kN; a room at 1 atm against vacuum,
-- 190 kN): walking up to it doesn't open it. Its menu's "Force it open"
-- does, venting the room; it stays free until it shuts again.
local held_say = -10
function gate(sid, uid, want)
  local s = S[sid]
  if not s then return want end
  local rid = s.dch[uid]
  if rid then
    local C = s.cham[rid]
    if not C then return want end
    if want and want > 0 then C.wants[uid] = now() end
    return (C.allow == uid) and 1 or 0
  end
  if not (want and want > 0) or s.forced[uid] then return want end
  local dp, pa, pb = door_dp(s, uid)
  if dp and dp > HOLD_DP and not door_open(sid, uid) then
    s.held[uid] = now()
    if now() - held_say > 4.0 then
      held_say = now()
      local fx = ref("sfx")
      if fx and fx.caption then fx.caption(string.format("held shut: %.2f atm against %.2f · its menu forces it", math.max(pa, pb), math.min(pa, pb))) end
    end
    return 0
  end
  return want
end
-- A door's pressure difference: → dp, pa, pb | nil (not a door of a room)
function door_dp(s, uid)
  local d = s.R and s.R.doors[uid]
  if not d then return nil end
  local function p_of(id)
    if id == 0 then return (out_of(s, s.rec)) end
    local r, A = s.R.byId[id], s.air[id]
    if not (r and A) then return 0 end
    if r.leaky then return (out_of(s, s.rec)) end
    return (A.N + A.x + A.c) / r.m3
  end
  local pa, pb = p_of(d.a), p_of(d.b)
  return math.abs(pa - pb), pa, pb
end
function forceOpen(sid, uid) local s = S[sid]; if s then s.forced[uid] = true end end
function isInterlocked(sid, uid) local s = S[sid]; return s ~= nil and s.dch[uid] ~= nil end

local function side_p(s, C, uid)
  local d = s.R.doors[uid]
  if not d then return 0 end
  local other = (d.a == C.rid) and d.b or d.a
  if other == 0 then return (out_of(s, s.rec)), 0 end
  local r = s.R.byId[other]
  local A = s.air[other]
  if not (r and A) then return 0, other end
  if r.leaky then return (out_of(s, s.rec)), other end
  return (A.N + A.x + A.c) / r.m3, other
end
local function ch_p(s, C)
  local r, A = s.R.byId[C.rid], s.air[C.rid]
  return (A.N + A.x + A.c) / r.m3, r.m3
end
local function move_air(from, to, amt)
  local tot = from.N + from.x + from.c
  if tot <= EPS or amt <= 0 then return 0 end
  local k = math.min(1, amt / tot)
  local dN, dx, dc = from.N * k, from.x * k, from.c * k
  from.N, from.x, from.c = from.N - dN, from.x - dx, from.c - dc
  if to then to.N, to.x, to.c = to.N + dN, to.x + dx, to.c + dc end
  return dN + dx + dc
end

local function ch_world(s, C)
  local KS = ref("kit_snap")
  local r = s.R.byId[C.rid]
  local b = space.body(s.rec.b)
  if not (KS and r and b) then return nil end
  local fr = KS.frameOf(s.rec)
  return b.x + fr.O.x + fr.R.x * r.cx + fr.U.x * r.cy + fr.F.x * r.cz,
         b.y + fr.O.y + fr.R.y * r.cx + fr.U.y * r.cy + fr.F.y * r.cz,
         b.z + fr.O.z + fr.R.z * r.cx + fr.U.z * r.cy + fr.F.z * r.cz
end

local function cycle_sound(s, C, on)
  if on and not C.snd then
    local x, y, z = ch_world(s, C)
    if x and audio and audio.play then
      local ok, h = pcall(audio.play, "audio/foley/hiss_cylinder.ogg", x, y, z, { loop = true, maxDistance = 25, track = "SFX", volume = 0.45 })
      C.snd = ok and h or true
      pcall(audio.play, "audio/foley/servo_run.ogg", x, y, z, { maxDistance = 25, track = "SFX", volume = 0.35 })
    end
    local fx = ref("sfx")
    if fx and fx.caption then fx.caption(C.dir == "down" and "airlock: depressurising" or "airlock: pressurising") end
  elseif not on and C.snd then
    if type(C.snd) == "table" or type(C.snd) == "userdata" then pcall(function() C.snd:stop() end) end
    C.snd = nil
    local x, y, z = ch_world(s, C)
    if x and audio and audio.play then
      pcall(audio.play, "audio/foley/hiss_seal.ogg", x, y, z, { maxDistance = 20, track = "SFX", volume = 0.4 })
      pcall(audio.play, "audio/sfx/crew_chime.ogg", x, y, z, { maxDistance = 20, track = "SFX", volume = 0.35 })
    end
  end
end

local function chamber_tick(sid, s, C, dt)
  local t = now()
  local inside = crew.sid == sid and crew.rid == C.rid
  local target = nil
  if inside then
    if not C.entered then
      for _, u in ipairs(C.doors) do if door_open(sid, u) then C.entered = u end end
      if not C.entered then
        -- (in the chamber with every door shut: they came in by the one nearest them)
        local best, bd = nil, 1e18
        for _, u in ipairs(C.doors) do
          local _, o = side_p(s, C, u)
          local r = o and s.R.byId[o]
          local d = r and ((r.cx - (crew.lx or 0)) ^ 2 + (r.cz - (crew.lz or 0)) ^ 2) or 1e17
          if d < bd then best, bd = u, d end
        end
        C.entered = best
      end
    end
    for _, u in ipairs(C.doors) do if u ~= C.entered then target = target or u end end
  else
    C.entered = nil
    local bt = -1
    for u, w in pairs(C.wants) do if t - w < 0.3 and w > bt then target, bt = u, w end end
  end
  C.target = target
  C.allow = nil
  if not target then
    if C.cyc then C.cyc = nil; cycle_sound(s, C, false) end
    return
  end
  for _, u in ipairs(C.doors) do if u ~= target and door_open(sid, u) then return end end
  local pT = side_p(s, C, target)
  local pc, Vc = ch_p(s, C)
  if math.abs(pc - pT) <= 0.04 then
    C.allow = target
    if C.cyc then C.cyc = nil; C.done_t = t; cycle_sound(s, C, false) end
    return
  end
  -- cycle: the pump moves air between the chamber and the hab behind it
  local inner = nil
  for _, u in ipairs(C.doors) do
    local d = s.R.doors[u]
    local o = d and ((d.a == C.rid) and d.b or d.a)
    local r = o and o > 0 and s.R.byId[o]
    if r and r.sealed and u ~= target then inner = o end
  end
  local _, tside = side_p(s, C, target)
  local tr = tside and tside > 0 and s.R.byId[tside]
  local A = s.air[C.rid]
  local amt = PUMP * dt
  if pc > pT then
    C.dir = "down"
    local sink = inner and s.air[inner] or (tr and tr.sealed and s.air[tside]) or nil
    move_air(A, sink, math.min(amt, (pc - pT) * Vc))
  else
    C.dir = "up"
    local src = (tr and tr.sealed and s.air[tside]) or (inner and s.air[inner]) or nil
    if src then move_air(src, A, math.min(amt, (pT - pc) * Vc)) end
  end
  if not C.cyc then C.cyc = target; C.cyc_t = t end
  cycle_sound(s, C, true)
  s.netsDirty = true
end

-- ── alarms ──────────────────────────────────────────────────────────────────
local function alarm_tick(sid, s)
  local pout = out_of(s, s.rec)
  for _, r in ipairs(s.R.rooms) do
    local a = airOf(sid, r.id)
    local k = tostring(sid) .. ":" .. tostring(r.id)
    if a then
      if a.p >= 0.8 then s.pres[r.id] = true end
      local venting = a.venting and a.p > pout + 0.05
      local al = alarms_[k]
      if venting and s.pres[r.id] and not al then
        local cause = a.causes[1] or "a leak"
        al = { sid = sid, rid = r.id, t0 = now(), cause = cause, snd_t = -10, kind = "depress", key = r.key }
        alarms_[k] = al
        lastAlarm = { sid = sid, rid = r.id, cause = cause, t = now(), kind = "depress" }
        local bc = ref("big_caption")
        local near = crew.sid == sid
        if bc and bc.show and near then bc.show("DEPRESSURISATION", string.format("Room %d (%.0f m³) is losing its air: %s.", r.id, r.m3, cause), 4.0) end
        local fx = ref("sfx")
        if fx and fx.caption then fx.caption("DEPRESSURISATION: " .. cause) end
        if log then log(string.format("room_air: DEPRESSURISATION in structure %s room %d (%.1f m³): %s", tostring(sid), r.id, r.m3, cause)) end
      elseif al and not venting then
        alarms_[k] = nil
        if a.p < 0.8 then s.pres[r.id] = false end
      end
      -- the air going bad in a sealed room with the crew in it: said once
      -- (an airlock's chamber is thin by design while it cycles)
      if r.sealed and not r.airlock and not a.venting and (s.crewIn[r.id] or 0) > 0 and not a.breathable and a.p >= P_MIN then
        if not s.badSaid then
          s.badSaid = true
          local bc = ref("big_caption")
          if bc and bc.show then bc.show("AIR", "Room " .. r.id .. ": " .. tostring(a.why) .. ".", 4.0) end
          lastAlarm = { sid = sid, rid = r.id, cause = a.why, t = now(), kind = "air" }
        end
      elseif r.sealed and a.breathable and (s.crewIn[r.id] or 0) > 0 then s.badSaid = nil end
    end
  end
end

local function alarm_sound()
  local a = find and find("Astronaut")
  if not valid(a) then return end
  local t = now()
  for _, al in pairs(alarms_) do
    local s = S[al.sid]
    if s and t - al.snd_t >= ALARM_EVERY then
      local C = { rid = al.rid }
      local x, y, z = ch_world(s, C)
      if x and (x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2 < 45 * 45 then
        al.snd_t = t
        if audio and audio.play then pcall(audio.play, "audio/sfx/crew_alarm.ogg", x, y, z, { maxDistance = 45, track = "SFX", volume = 0.55 }) end
      end
    end
  end
end

-- ── save ────────────────────────────────────────────────────────────────────
local function save_struct(sid, s)
  if not (save and save.set) then return end
  local rooms = {}
  for _, r in ipairs(s.R.rooms) do
    local A = s.air[r.id]
    rooms[#rooms + 1] = { k = r.key, N = A.N, x = A.x, c = A.c, V = r.m3, f = A.f == true or nil }
  end
  local tanks = {}
  for u, q in pairs(s.tanks) do tanks[#tanks + 1] = { u = u, q = q } end
  save.set("air." .. tostring(sid), { a = s.a, rooms = rooms, tanks = tanks })
end
function saveNow() for sid, s in pairs(S) do if s.R then save_struct(sid, s) end end end

-- ── the menu: life support, an airlock's door ───────────────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local s = S[rec.id]
  if not s then return {} end
  local d = defs(part.id) or {}
  local out = {}
  local sid, uid = rec.id, part.uid
  if d.life then
    local L = d.life
    local rid = nil
    for _, l in ipairs(s.life) do if l.uid == uid then rid = l.rid end end
    if not rid then
      out[#out + 1] = { id = "ra_room", type = "info", label = "Room", value = "not in a sealed room: it does nothing here", group = "Life support" }
    else
      local a = airOf(sid, rid)
      out[#out + 1] = { id = "ra_room", type = "info", label = "Room " .. rid, group = "Life support",
        value = function() local q = airOf(sid, rid); return q and string.format("%.2f atm · O2 %.0f %% · CO2 %.1f %%%s", q.p, 100 * q.o2 / math.max(q.p, 1e-6), 100 * q.co2 / math.max(q.p, 1e-6), q.venting and " · VENTING" or "") or "—" end }
      if L.store then
        out[#out + 1] = { id = "ra_tank", type = "info", label = "Air", group = "Life support",
          value = function() return string.format("%.1f of %.0f m³ at 1 atm", s.tanks[uid] or 0, L.store) end }
        local co = ref("company")
        local need = L.store - (s.tanks[uid] or 0)
        local cost = math.floor(need * (L.price or 4) + 0.5)
        out[#out + 1] = { id = "ra_refill", type = "action", label = need < 0.05 and "Full" or string.format("Refill from the base stores ($%d)", cost), group = "Life support",
          act = function()
            if need < 0.05 then return false, "already full" end
            if co and co.spend and not co.spend(cost, "air tank refill") then return false, "can't afford it" end
            advance_struct(sid, s, agency_now())
            s.tanks[uid] = L.store
            s.netsDirty = true
            if audio and audio.play then pcall(audio.play, "audio/foley/hiss_cylinder.ogg", { track = "SFX", volume = 0.4 }) end
            return true
          end }
      else
        out[#out + 1] = { id = "ra_state", type = "info", label = L.o2 and "O2" or "Scrubber", group = "Life support",
          value = function() return s.pow and "running on the base grid" or "NO POWER (it runs on the base grid)" end }
      end
    end
  end
  if s.R and s.R.doors[uid] and not s.dch[uid] then
    local dp, pa, pb = door_dp(s, uid)
    if dp and dp > HOLD_DP and not s.forced[uid] then
      local d = s.R.doors[uid]
      local hi = (pa >= pb) and d.a or d.b
      out[#out + 1] = { id = "ra_held", type = "info", label = "Door", group = "Fitting",
        value = function() local q, a1, b1 = door_dp(s, uid); return string.format("held shut: %.2f atm against %.2f", math.max(a1 or 0, b1 or 0), math.min(a1 or 0, b1 or 0)) end }
      out[#out + 1] = { id = "ra_force", type = "action", group = "Fitting",
        label = hi == 0 and "Force it open (the outside comes in)" or string.format("Force it open (vents Room %d)", hi),
        act = function()
          s.forced[uid] = true
          if audio and audio.play then pcall(audio.play, "audio/foley/latch_clunk.ogg", { track = "SFX", volume = 0.5 }) end
          return true
        end }
    end
  end
  if s.dch[uid] then
    local C = s.cham[s.dch[uid]]
    out[#out + 1] = { id = "ra_lock", type = "info", label = "Airlock", group = "Fitting",
      value = function()
        local pc = ch_p(s, C)
        if C.cyc then return string.format("%s · %.2f atm", C.dir == "down" and "depressurising" or "pressurising", pc) end
        return string.format("interlocked · chamber %.2f atm", pc)
      end }
  end
  return out, (#out > 0) and d.label or nil
end
local reg_on = false

-- ── the ROOMS overlay (lateUpdate: drawn poses, this frame's body read) ─────
local COL = { ok = { 0.45, 1.0, 0.6 }, thin = { 1.0, 0.75, 0.3 }, leak = { 1.0, 0.35, 0.3 } }
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
function drawOverlay()
  if not (draw and draw.line) then return 0 end
  local KS = ref("kit_snap")
  local a = find and find("Astronaut")
  if not (KS and valid(a)) then return 0 end
  local lines = 0
  local placed = {}
  for sid, s in pairs(S) do
    local rec = s.rec
    local b = space.body(rec.b)
    if b and s.R and #s.R.rooms > 0 then
      local fr = KS.frameOf(rec)
      local ox, oy, oz = b.x + fr.O.x, b.y + fr.O.y, b.z + fr.O.z
      local R, U, F = fr.R, fr.U, fr.F
      local function W(x, y, z) return ox + R.x * x + U.x * y + F.x * z, oy + R.y * x + U.y * y + F.y * z, oz + R.z * x + U.z * y + F.z * z end
      local cx, cy, cz = W(0, 0, 0)
      if (cx - a.x) ^ 2 + (cy - a.y) ^ 2 + (cz - a.z) ^ 2 < 150 * 150 then
        -- an open door a room vents through: a red ring on it
        for uid, d in pairs(s.R.doors) do
          if d.x and door_open(sid, uid) then
            local out_ = d.a == 0 or d.b == 0 or (s.R.byId[d.a] and s.R.byId[d.a].leaky) or (s.R.byId[d.b] and s.R.byId[d.b].leaky)
            if out_ then
              local x, y, z = W(d.x, d.y, d.z)
              if draw.ring then draw.ring(x, y, z, U.x, U.y, U.z, 0.5, COL.leak[1], COL.leak[2], COL.leak[3], 1.0) end
              if camera and camera.worldToScreen and draw.text then
                local sx, sy, _, on = camera.worldToScreen(x, y, z)
                if on then draw.text(sx, sy - 24, "OPEN · the " .. tostring(d.label or "door"), 15, COL.leak[1], COL.leak[2], COL.leak[3], 1, "center") end
              end
            end
          end
        end
        for _, r in ipairs(s.R.rooms) do
          local q = airOf(sid, r.id)
          local col = (r.leaky or (q and q.venting)) and COL.leak or ((q and q.breathable) and COL.ok or COL.thin)
          local sg = r.seg
          for i = 1, #sg, 6 do
            if lines < 6000 then
              local x1, y1, z1 = W(sg[i], sg[i + 1], sg[i + 2])
              local x2, y2, z2 = W(sg[i + 3], sg[i + 4], sg[i + 5])
              draw.line(x1, y1, z1, x2, y2, z2, col[1], col[2], col[3], 0.95)
              lines = lines + 1
            end
          end
          for _, l in ipairs(r.leaks) do
            local x, y, z = W(l.x, l.y, l.z)
            if draw.ring then draw.ring(x, y, z, U.x, U.y, U.z, 0.35, COL.leak[1], COL.leak[2], COL.leak[3], 1.0) end
            if draw.sphere then pcall(draw.sphere, x, y, z, 0.12, COL.leak[1], COL.leak[2], COL.leak[3], 1.0) end
            if camera and camera.worldToScreen and draw.text then
              local sx, sy, _, on = camera.worldToScreen(x, y, z)
              if on then draw.text(sx, sy - 22, "GAP · " .. l.label, 15, COL.leak[1], COL.leak[2], COL.leak[3], 1, "center") end
            end
          end
          if camera and camera.worldToScreen and draw.text and q then
            local x, y, z = W(r.cx, r.y0 + 1.5, r.cz)
            local sx, sy, _, on = camera.worldToScreen(x, y, z)
            if on then
              local st = r.leaky and "UNSEALED" or (q.venting and "VENTING" or (q.breathable and "SEALED · AIR" or "SEALED · NO AIR"))
              if r.airlock then st = "AIRLOCK · " .. st end
              local t1 = string.format("ROOM %d  %s", r.id, st)
              local t2 = string.format("%.1f m³ · %.2f atm · O2 %.0f %% · CO2 %.1f %%", r.m3, q.p, 100 * q.o2 / math.max(q.p, 1e-6), 100 * q.co2 / math.max(q.p, 1e-6))
              local w = math.max(#t1 * 9.5, #t2 * 7.6) + 16
              -- (two rooms' labels never on top of each other: the later one steps down)
              for _ = 1, 6 do
                local hit = false
                for _, b in ipairs(placed) do
                  if math.abs(b[1] - sx) < (b[3] + w) / 2 and math.abs(b[2] - sy) < 42 then hit = true end
                end
                if not hit then break end
                sy = sy + 44
              end
              placed[#placed + 1] = { sx, sy, w }
              if draw.rect then draw.rect(sx - w / 2, sy - 4, w, 42, 0.02, 0.03, 0.04, 0.62, 4) end
              draw.text(sx, sy, t1, 17, col[1], col[2], col[3], 1, "center")
              draw.text(sx, sy + 20, t2, 14, col[1], col[2], col[3], 0.9, "center")
            end
          end
        end
      end
    end
  end
  return lines
end

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("room_air")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  S, ver, sigs, pending, alarms_ = {}, -1, {}, {}, {}
  air_t, crew_t, save_t, cham_t = -10, -10, -10, -10
  crew = { sid = nil, rid = nil, t = -10 }
end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "room_air", order = 7 }); reg_on = true end
  end
  local ST, R_ = ref("structures"), RL()
  if not (ST and R_) then return end
  local t = now()
  -- what changed: the seal signatures, worked out only when the records move
  if ST.version ~= ver then
    ver = ST.version
    local seen = {}
    for _, rec in ipairs(ST.list()) do
      seen[rec.id] = true
      local sg = R_.signatureOf(rec, defs)
      if sg ~= sigs[rec.id] then sigs[rec.id] = sg; pending[rec.id] = t end
      if S[rec.id] then S[rec.id].rec = rec end
    end
    for sid in pairs(S) do
      if not seen[sid] then
        S[sid] = nil; sigs[sid] = nil
        if save and save.set then save.set("air." .. tostring(sid), false) end
        for k, al in pairs(alarms_) do if al.sid == sid then alarms_[k] = nil end end
      end
    end
  end
  for sid, t0 in pairs(pending) do
    if t - t0 >= SOLVE_WAIT or not S[sid] then
      pending[sid] = nil
      local old = S[sid]
      if old then advance_struct(sid, old, agency_now()) end
      if sigs[sid] == "" then
        if old then S[sid] = nil end
        if save and save.set and old then save.set("air." .. tostring(sid), false) end
      else
        solve(sid)
        local s = S[sid]
        if s then s.pow = powered(sid); advance_struct(sid, s, agency_now()); save_struct(sid, s) end
      end
    end
  end
  if next(S) == nil then return end
  -- the crew: which room (a change re-forms the networks: the air first)
  if t - crew_t >= CREW_EVERY then
    crew_t = t
    local pts = crew_points()
    local counts = {}
    local was_sid, was_rid = crew.sid, crew.rid
    crew.sid, crew.rid = nil, nil
    for i, p in ipairs(pts) do
      local sid, r, lx, ly, lz = locate(p.x, p.y, p.z)
      if sid then
        counts[sid] = counts[sid] or {}
        counts[sid][r.id] = (counts[sid][r.id] or 0) + 1
        if p.active then crew.sid, crew.rid, crew.lx, crew.ly, crew.lz = sid, r.id, lx, ly, lz end
      end
    end
    local a = agency_now()
    for sid, s in pairs(S) do
      local c = counts[sid] or {}
      local diff = false
      for rid, n in pairs(c) do if s.crewIn[rid] ~= n then diff = true end end
      for rid, n in pairs(s.crewIn) do if (c[rid] or 0) ~= n then diff = true end end
      if diff then advance_struct(sid, s, a); s.crewIn = c; s.netsDirty = true end
    end
    if was_sid ~= crew.sid or was_rid ~= crew.rid then
      -- (a room's air for the suit, now: planet_walker caches the air half a second)
    end
  end
  -- the airlocks near the crew: the interlock and the pump, ten times a second
  if t - cham_t >= CHAM_EVERY then
    local dtc = math.min(0.5, t - cham_t)
    cham_t = t
    local a = find and find("Astronaut")
    for sid, s in pairs(S) do
      if next(s.cham) and valid(a) then
        local b = space.body(s.rec.b)
        if b then
          local dx, dy, dz = b.x + s.rec.x - a.x, b.y + s.rec.y - a.y, b.z + s.rec.z - a.z
          if dx * dx + dy * dy + dz * dz < (CYCLE_R + 30) ^ 2 then
            for _, C in pairs(s.cham) do chamber_tick(sid, s, C, dtc) end
          end
        end
      end
    end
  end
  -- the air: on the slow clock, on the agency clock
  if t - air_t >= AIR_EVERY then
    air_t = t
    local w0 = wall()
    local an = agency_now()
    for sid, s in pairs(S) do
      local p = powered(sid)
      if p ~= s.pow then advance_struct(sid, s, an); s.pow = p; s.netsDirty = true end
      advance_struct(sid, s, an)
      alarm_tick(sid, s)
    end
    if w0 then PROF.air_ms = (wall() - w0) * 1000 end
    PROF.n_air = PROF.n_air + 1
  end
  if next(alarms_) then alarm_sound() end
  if t - save_t >= SAVE_EVERY then save_t = t; saveNow() end
end

-- kit_live: a door opened or shut (past OPEN_T): the air first, then the networks
function doorMoved(sid, uid)
  local s = S[sid]
  if not s then return end
  advance_struct(sid, s, agency_now())
  s.netsDirty = true
  -- (a forced door, shut again, holds again)
  if s.forced[uid] and not door_open(sid, uid) then s.forced[uid] = nil end
end

function lateUpdate(node, dt)
  if overlay_on() then drawOverlay() end
end
