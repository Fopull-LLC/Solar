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
--   N2 Compressor  (expansion X2) pulls the OUTSIDE air through a membrane and
--                  feeds the room its inert gas, up to 1 atm, as the makeup a
--                  bottle rack would: what the outside holds besides O2 comes
--                  in with it, so on a CO2 world it brings CO2 and the room
--                  needs its scrubbers running (`n2`, atm·m³/s; powered;
--                  nothing to pull under N2_PMIN of outside air)
--   O2 Concentrator (X2) a pressure-swing unit: it makes O2 from the outside
--                  air like the O2 Generator does from water, holding the
--                  room at 21 %, wherever the outside holds O2C_MIN of O2
--                  (`o2c`, atm·m³/s; powered; no water)
-- THE OUTSIDE (X2): a world's rolled air (world.<name>.air, scripts/atmo.lua)
-- gives the outside's pressure, O2 and CO2 (`c` counts CO2 and the acid gases
-- a scrubber also takes, SO2); a room that closes round it starts as it is,
-- and a vent relaxes every amount to it. An OLD save's worlds (no air, or
-- `legacy`) keep the yes/no outside they had: O2N or none, no CO2.
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
-- come in by (the side it was last open to, if they are found in it with
-- every door shut). While the pressures differ the chamber CYCLES: a pump
-- moves air between the chamber and the hab (PUMP_S; a 9 m³ chamber in ~5 s
-- down, ~6 s up), with the air's hiss, the pump's motor, vapour in the
-- chamber, frost out of the vent, and the latch and a bell when it is done.
-- (Playtest 11-11.) The door the crew came in by never shuts on them while
-- they stand in it. A door's panel and menu show its state (airlockStatus:
-- READY, CYCLING, EQUALISING, VENTING, CLOSING, HELMET, NO POWER, OVERRIDE,
-- STANDBY), "Cycle to this door" (cycleTo) works from inside, outside and
-- the chamber, and the MANUAL OVERRIDE (overrideDoor) opens a door against
-- the pressure, warned, never refused.
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
-- ── THE ROOM PURGE (an Air Tank Rack's purge pump) ──────────────────────────
-- A room that closes round a world's air holds that air: on a CO2 or N2 world
-- at 1.2 atm it is unbreathable, and the regulator never opens (it feeds only
-- under 97 % of an atmosphere). PURGE (the rack's menu, the terminal's AIR
-- page) is what a real habitat does: pump-down and backfill. Every rack in
-- the room runs its purge pump (RP_S m³/s at the room's pressure each, RP_KW
-- from the base grid) and dumps the gas overboard, down to RP_P; the purge is
-- then done and the racks' regulator refills the room to 1 atm with air
-- (an 18 m³ hut from 1.2 atm: ~4.8 min of pumping with one rack, ~1.2 min of
-- refill, 18 m³ of the rack's 60). The regulator stays shut while a purge
-- is under way, and the pump stops without power (the room holds as it is).
-- It needs the racks to hold the refill, a sealed room and the power; it never
-- refuses because crew are inside: they are warned (helmets on) and it runs.
-- The pump-down is the closed form's venting branch, to a vacuum, with an
-- event at RP_P (exact in one step, like the rest).
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
-- (S7) electrolysis, 2 H2O → 2 H2 + O2: kg of water an atm·m³ of O2 takes
-- (1.429 kg of O2 × 36.03 / 32.00), and the kg of hydrogen it makes
KW = 1.429 * 36.031 / 31.999
KH = 1.429 * 4.032 / 31.999
-- (S7) pressure mechanics
G_OPEN = 1 / VENT_S          -- m³/s per atm through an open door or a gap (τ = V / G)
EQ_DOOR = 0.1                -- a door's own equalising valve, m³/s per atm (a bulkhead names its own)
SEAL_C = 0.03                -- a fully failed seal's leak, m³/s per atm
-- (playtest 11-11: "sometimes it just takes forever to open": a 9 m³ lock took ~55 s
-- out and ~30 s in. A small lock's cycle is a few seconds now: a bigger pump,
-- valves sized to it; a bigger chamber still takes longer, in proportion)
PUMP_S = 4.0                 -- an airlock pump's speed, m³/s at the chamber's pressure (a 9 m³ chamber: ~5 s to 0.1 atm)
P_RESID = 0.1                -- it pumps down to this; the rest is vented
P_PURGE = 0.01               -- (scn_dust) coming in, foreign gas is pumped overboard to this first
PURGE_S = 4.0                -- …at this many m³/s at the chamber's pressure (a 9 m³ chamber, 0.8 → 0.01 atm in ~10 s)
PURGE_CO2, PURGE_O2 = 0.01, 0.15   -- foreign: CO2 over this share of the gas, or O2 under this one
REC_C = 4.0                  -- the receiver's return valve, m³/s per atm
CYC_C = 5.0                  -- the chamber's equalising valve to the hab (or the room ahead), m³/s per atm (9 m³: ~6 s)
VENT_C = 4.0                 -- the chamber's vent valve, m³/s per atm (no pump: the air is lost)
FORCE_S = 3.0                -- forcing a door: s, plus FORCE_K s per atm across it
FORCE_K = 6.0
WARN_S = 5.0                 -- the warning crew in a room get before it vents (a forced or failing door)
FAIL_DP = 0.5                -- a badly damaged seal (FAIL_DMG) blows out with this much across it
FAIL_DMG = 0.6
REPAIR_S = 24.0              -- re-seating a seal (an Engineer halves it)
BLOWN_C = 1.0                -- a seal that has blown out: a breach (m³/s per atm)
-- the room purge (an Air Tank Rack's `purge`, m³/s; its draw RP_KW while it pumps)
RP_S = 0.3                   -- a rack's purge pump, m³/s at the room's pressure (when a rack names none)
RP_KW = 2.0                  -- its draw on the base grid while it pumps
RP_P = 0.01                  -- pumped down to this (atm), then the regulator refills the room

local min, max, abs, exp, sqrt, ln = math.min, math.max, math.abs, math.exp, math.sqrt, math.log

-- ── pure: one network's air ─────────────────────────────────────────────────
-- st = { N, x, c, q (the tanks' store), feed (the regulator open) }
-- M  = { V, crew, G (O2 a second), S (CO2 a second), F (the regulator's flow),
--        tau (nil = sealed), pout, xout, cout (the outside's pressure, O2 and
--        CO2 shares), Jc (X2: CO2 a compressor brings in with the inert gas) }
-- → st, rep = { segs, events = { name … } }
-- (S7) M also carries: W (the generators' water cells hold st.w kg: O2 is
-- made only while there is water, KW kg an atm·m³, and st.h2 gathers the
-- hydrogen), Jx, JN (gas a Room Gas Outlet brings, atm·m³/s, while the room
-- is under 1 atm: st.jon), and with tau, slow (a leak slow enough that the
-- regulator keeps feeding it, an excess-flow valve shutting it on a breach).
-- (roompurge) with tau, pT: the pump-down stops at pT atm: rep.purged, and
-- rep.left the s of dt not stepped (the caller carries on without the pump).
function advance(st, M, dt, rep)
  rep = rep or { segs = 0, events = {} }
  rep.segs = rep.segs or 0
  rep.events = rep.events or {}
  if not dt or dt <= 0 then return st, rep end
  local V = M.V
  local Jx, JN = M.Jx or 0, M.JN or 0
  local Jc = M.Jc or 0
  if M.tau then
    local co = M.cout or 0
    local Nt, xt = V * (M.pout or 0) * (1 - (M.xout or 0) - co), V * (M.pout or 0) * (M.xout or 0)
    local ct = V * (M.pout or 0) * co
    local F = M.slow and (M.F or 0) or 0
    if not M.slow then st.feed = false end
    local left, guard = dt, 0
    while left > 0 do
      guard = guard + 1
      if guard > 20000 then break end
      local n = st.N + st.x + st.c
      if not st.feed and st.q > EPS and F > 0 and n < FEED_ON * V - EPS then st.feed = true; rep.events[#rep.events + 1] = "feed_on" end
      if st.jon == false and n < 0.99 * V then st.jon = true end
      local f = (st.feed and st.q > EPS) and F or 0
      local jon = st.jon ~= false
      local sN = (1 - O2N) * f + (jon and JN or 0)
      local sx = O2N * f + (jon and Jx or 0)
      local tau = M.tau
      -- dA/dt = -(A - A_out)/τ + s_A: A(t) = A_eq + (A - A_eq) e^(-t/τ), A_eq = A_out + s_A τ
      local Neq, xeq = Nt + sN * tau, xt + sx * tau
      local ceq = ct + (jon and Jc or 0) * tau
      local neq = Neq + xeq + ceq
      local te, ev = left, nil
      local function at(t, e) if t >= 0 and t < te then te, ev = t, e end end
      if f > 0 then at(st.q / f, "tank_empty") end
      if (f > 0 or (jon and (Jx + JN + Jc) > 0)) and neq > V and n < V then
        at(-tau * ln((V - neq) / (n - neq)), "full")
      end
      if not st.feed and st.q > EPS and F > 0 and neq < FEED_ON * V and n > FEED_ON * V then
        at(-tau * ln((FEED_ON * V - neq) / (n - neq)), "feed_on")
      end
      if M.pT then
        if n <= M.pT * V + EPS then rep.purged, rep.left = true, left; rep.events[#rep.events + 1] = "purged"; break end
        if neq < M.pT * V then at(-tau * ln((M.pT * V - neq) / (n - neq)), "purged") end
      end
      local k = exp(-te / tau)
      st.N = Neq + (st.N - Neq) * k
      st.x = xeq + (st.x - xeq) * k
      st.c = ceq + (st.c - ceq) * k
      st.q = max(0, st.q - f * te)
      left = left - te
      rep.segs = rep.segs + 1
      if not ev then break end
      rep.events[#rep.events + 1] = ev
      if ev == "tank_empty" then st.q = 0
      elseif ev == "full" then st.feed = false; st.jon = false
      elseif ev == "feed_on" then st.feed = true
      elseif ev == "purged" then rep.purged, rep.left = true, left; break end
    end
    return st, rep
  end
  local G, S, F = M.G or 0, M.S or 0, M.F or 0
  local water = M.W ~= nil
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
    if st.jon == false and n < 0.99 * V then st.jon = true end
    local crew = (st.x > EPS) and (M.crew or 0) or 0
    local use, make = crew * USE, crew * MAKE
    local g, xr = 0, nil
    local Gw = (water and (st.w or 0) <= EPS) and 0 or G
    if Gw > 0 then
      if st.x < xs - EPS then g, xr = Gw, -1
      elseif st.x <= xh + EPS then g, xr = min(Gw, use), 0
      else g, xr = 0, 1 end
    end
    local f = (st.feed and st.q > EPS and F > 0) and F or 0
    local jon = st.jon ~= false
    local jx, jN, jc = jon and Jx or 0, jon and JN or 0, jon and Jc or 0
    local dx = g - use + O2N * f + jx
    local s = 0
    if S > 0 then if st.c > EPS then s = S else s = min(S, make + jc) end end
    local dc = make + jc - s
    local dN = (1 - O2N) * f + jN
    local dn = dN + dx + dc
    local te, ev = left, nil
    local function at(t, e) if t >= 0 and t < te then te, ev = t, e end end
    if xr == -1 and dx > 0 then at((xs - st.x) / dx, "o2_at") end
    if xr == 0 and dx > 0 then at((xh - st.x) / dx, "o2_high") end
    if xr == 1 and dx < 0 then at((st.x - xh) / -dx, "o2_band") end
    if dx < 0 and st.x > EPS then at(st.x / -dx, "o2_out") end
    if st.c > EPS and dc < 0 then at(st.c / -dc, "co2_clear") end
    if water and g > 0 then at(st.w / (g * KW), "water_out") end
    if f > 0 or jx + jN + jc > 0 then
      if dn > 0 then at((V - n) / dn, "full") end
      if f > 0 then at(st.q / f, "tank_empty") end
    end
    if not st.feed and st.q > EPS and F > 0 and dn < 0 then
      at((n - FEED_ON * V) / -dn, "feed_on")
    end
    if st.jon == false and dn < 0 and (Jx + JN + Jc) > 0 then at((n - 0.99 * V) / -dn, "inj_on") end
    st.N = max(0, st.N + dN * te)
    st.x = max(0, st.x + dx * te)
    st.c = max(0, st.c + dc * te)
    st.q = max(0, st.q - f * te)
    if water then
      st.w = max(0, (st.w or 0) - g * KW * te)
      st.h2 = (st.h2 or 0) + g * KH * te
      st.made = (st.made or 0) + g * te
    end
    left = left - te
    rep.segs = rep.segs + 1
    if ev then
      rep.events[#rep.events + 1] = ev
      if ev == "o2_at" then st.x = xs
      elseif ev == "o2_high" then st.x = xh + 2 * EPS
      elseif ev == "o2_band" then st.x = xh
      elseif ev == "o2_out" then st.x = 0
      elseif ev == "co2_clear" then st.c = 0
      elseif ev == "full" then st.feed = false; if jx + jN + jc > 0 then st.jon = false end
      elseif ev == "tank_empty" then st.q = 0
      elseif ev == "water_out" then st.w = 0
      elseif ev == "inj_on" then st.jon = true
      elseif ev == "feed_on" then st.feed = true end
    else
      break
    end
  end
  return st, rep
end

-- (S7) Two sides joined by a valve of conductance C (m³/s per atm): their
-- pressures meet as e^(-k t), k = C (1/Va + 1/Vb) (Vb nil: the outside, held).
-- The gas goes from the high side with that side's mix (an outflow does not
-- change a well-mixed room's mix), so the amounts are exact. → the amount moved
function equalise(A, Va, B, Vb, C, dt, pout, xout, cout)
  if C <= 0 or dt <= 0 then return 0 end
  local pa = (A.N + A.x + A.c) / Va
  local pb = B and ((B.N + B.x + B.c) / Vb) or (pout or 0)
  local k = C * (1 / Va + (B and 1 / Vb or 0))
  local d = (pa - pb) * (1 - exp(-k * dt))
  -- the high side loses Δn = d · Va·Vb/(Va+Vb) (to the outside: d · Va)
  local dn = B and d * Va * Vb / (Va + Vb) or d * Va
  if dn > 0 then
    local tot = A.N + A.x + A.c
    local f = (tot > EPS) and math.min(1, dn / tot) or 0
    local mN, mx, mc = A.N * f, A.x * f, A.c * f
    A.N, A.x, A.c = A.N - mN, A.x - mx, A.c - mc
    if B then B.N, B.x, B.c = B.N + mN, B.x + mx, B.c + mc end
  elseif dn < 0 then
    if B then
      local tot = B.N + B.x + B.c
      local f = (tot > EPS) and math.min(1, -dn / tot) or 0
      local mN, mx, mc = B.N * f, B.x * f, B.c * f
      B.N, B.x, B.c = B.N - mN, B.x - mx, B.c - mc
      A.N, A.x, A.c = A.N + mN, A.x + mx, A.c + mc
    else
      local o = -dn
      A.N, A.x, A.c = A.N + o * (1 - (xout or 0) - (cout or 0)), A.x + o * (xout or 0), A.c + o * (cout or 0)
    end
  end
  return dn
end
-- How long a valve of C takes to bring Δp0 down to `to` (atm): → s
function equaliseTime(Va, Vb, C, dp0, to)
  if dp0 <= to then return 0 end
  local k = C * (1 / Va + (Vb and 1 / Vb or 0))
  return math.log(dp0 / to) / k
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

-- (roompurge) A purge's plan for V m³ holding n atm·m³ of gas: Sp the racks'
-- purge pumps (m³/s), F their regulators' flow (atm·m³/s), q their air.
-- → { pump (s down to RP_P; nil with no pump), fill (s back to 1 atm; nil
-- with no flow), need (atm·m³ of air the refill takes), short (q < need) }
function purgePlan(V, n, Sp, F, q)
  local nT = RP_P * V
  local pump = nil
  if (Sp or 0) > 0 then pump = (n > nT) and (V / Sp) * ln(n / nT) or 0 end
  local need = V * (1 - RP_P)
  local fill = ((F or 0) > 0) and need / F or nil
  return { pump = pump, fill = fill, need = need, short = (q or 0) < need - 1e-6 }
end
-- Is this air foreign (the outside's, not a habitat's): CO2 over PURGE_CO2 of
-- the gas or O2 under PURGE_O2 (the airlock's purge rule). → bool
function foulAir(A)
  local tot = A.N + A.x + A.c
  return tot > EPS and ((A.c / tot) > PURGE_CO2 or (A.x / tot) < PURGE_O2)
end

-- A room's air as the outside's (a room closed round air that was there).
function outsideAir(V, pout, xout, cout)
  cout = cout or 0
  return { N = V * pout * (1 - xout - cout), x = V * pout * xout, c = V * pout * cout }
end

-- (X2) The outside's pressure (atm), O2 and CO2 shares from a world's rolled
-- air at `share` of its datum density (pure; atmo.lua's record). CO2 counts
-- the acid gases too (a scrubber's amine takes SO2 as well).
N2_PMIN = 0.05                   -- atm of outside air a compressor needs
O2C_MIN = 0.05                   -- the O2 share of the outside a concentrator needs
function outsideOf(air, share)
  if type(air) ~= "table" then return 0, 0, 0 end
  local p = math.max(0, math.min(1.5, (air.p0 or 0) * math.max(0, share or 1)))
  local g = air.gases or {}
  return p, g.O2 or 0, (g.CO2 or 0) + (g.SO2 or 0)
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

-- The outside where structure `rec` stands: p (atm), O2 share, CO2 share.
-- (suit.lua's rules: a world's air, its oxygen, how thick it is here.)
local function outside_of(rec)
  if forceVacuum then return 0, 0, 0 end
  local cl, ae = ref("climate"), ref("aero")
  local w = cl and cl.worldOf and cl.worldOf(rec.b)
  if not w or (w.atmo or 0) < 0.05 then return 0, 0, 0 end
  if type(w.air) == "table" and not w.air.legacy then
    local b = space and space.body and space.body(rec.b)
    local share = 1
    if b and ae and ae.airShare then
      local alt = sqrt(rec.x * rec.x + rec.y * rec.y + rec.z * rec.z) - (w.radius or b.radius or 0)
      local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or b.radius or 800)
      local ok, sh = pcall(ae.airShare, math.max(alt, -0.25 * H), H, w.atmoScaleH)
      share = ok and sh or 1
    end
    return outsideOf(w.air, share)
  end
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
  return p, (oxy >= 0.5) and O2N or 0, 0
end
local function out_of(s, rec)
  if not s.out then local p, xo, co = outside_of(rec); s.out = { p = p, x = xo, c = co or 0 } end
  return s.out.p, s.out.x, s.out.c
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

-- A piece's own axis ("y" | "z") in its structure's frame (the engine's
-- order: yaw, then pitch, then roll; reactor.lua's yaw sense).
function piece_axis(p, ax)
  local vx, vy, vz = 0, 0, 1
  if ax == "y" then vx, vy, vz = 0, 1, 0 end
  local r, pt, y = p.roll or 0, p.pitch or 0, p.yaw or 0
  local cr, sr, cp, sp, cy, sy = math.cos(r), math.sin(r), math.cos(pt), math.sin(pt), math.cos(y), math.sin(y)
  local x1, y1, z1 = vx * cr - vy * sr, vx * sr + vy * cr, vz
  local y2, z2 = y1 * cp - z1 * sp, y1 * sp + z1 * cp
  return x1 * cy + z2 * sy, y2, -x1 * sy + z2 * cy
end

local function part_state(sid, uid)
  local ST = ref("structures")
  return ST and ST.partState and ST.partState(sid, uid) or nil
end
local function set_part_state(sid, uid, k, v)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for a, b in pairs(st) do t[a] = b end
  t[k] = v
  ST.setPartState(sid, uid, next(t) and t or nil)
end
-- A door's seal damage (0 whole … 1 blown), kept in its part state
function sealOf(sid, uid) local st = part_state(sid, uid); return st and tonumber(st.seal) or 0 end

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
              forced = old and old.forced or {}, held = {},
              -- (S7) the O2 Generators' water cells (kg), the airlock receivers'
              -- air ({ N, x, c }), what the outlets bring each room, the H2 made
              cells = {}, recv = {}, inject = old and old.inject or {}, h2 = old and old.h2 or {}, made = old and old.made or {},
              fail = old and old.fail or {}, warn = old and old.warn or {},
              -- (roompurge) the rooms a purge is pumping down: rid → { t0 (agency) }
              purge = {} }
  local pout, xout, cout = out_of(s, rec)
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
        else N, x, c = N + v * pout * (1 - xout - cout), x + v * pout * xout, c + v * pout * cout end
      end
    end
    s.air[r.id] = { N = N, x = x, c = c, f = f }
    if (N + x + c) / math.max(r.m3, 1e-6) >= 0.8 then s.pres[r.id] = true end
    -- (roompurge) a purge under way carries on in the room of the same key
    if old and old.purge and old.R then
      for rid0, e in pairs(old.purge) do
        local r0 = old.R.byId[rid0]
        if r0 and r0.key == r.key then s.purge[r.id] = e end
      end
    end
    for _, k in ipairs(saved and type(saved.purge) == "table" and saved.purge or {}) do
      if tonumber(k) == r.key then s.purge[r.id] = { t0 = s.a or 0 } end
    end
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
      local pst = part_state(sid, p.uid)
      s.life[#s.life + 1] = { uid = p.uid, rid = r and r.id or nil, life = L, label = d.label, off = (pst and pst.off) and true or nil }
      if L.store then
        local q = old and old.tanks and old.tanks[p.uid]
        for _, e in ipairs(q == nil and saved and type(saved.tanks) == "table" and saved.tanks or {}) do
          if type(e) == "table" and tonumber(e.u) == p.uid then q = tonumber(e.q) end
        end
        if q == nil then q = L.store end   -- (a rack comes charged)
        s.tanks[p.uid] = math.max(0, math.min(L.store, q))
      end
      -- (S7) a generator's water cell (it comes filled), a receiver's air (empty)
      if L.water then
        local w = old and old.cells and old.cells[p.uid]
        for _, e in ipairs(w == nil and saved and type(saved.cells) == "table" and saved.cells or {}) do
          if type(e) == "table" and tonumber(e.u) == p.uid then w = tonumber(e.w) end
        end
        if w == nil then w = L.water end
        s.cells[p.uid] = math.max(0, math.min(L.water, w))
      end
      if L.receiver then
        local a = old and old.recv and old.recv[p.uid]
        for _, e in ipairs(a == nil and saved and type(saved.recv) == "table" and saved.recv or {}) do
          if type(e) == "table" and tonumber(e.u) == p.uid then a = { N = tonumber(e.N) or 0, x = tonumber(e.x) or 0, c = tonumber(e.c) or 0 } end
        end
        s.recv[p.uid] = a or { N = 0, x = 0, c = 0 }
      end
    end
  end
  -- (S7) the doors' sides: which room is on each door's front (+Z of a wall,
  -- +Y of a hatch), for the gust a forced door throws and the crew it pulls
  s.dside = {}
  for uid, d in pairs(R.doors) do
    for _, p in ipairs(rec.bp or {}) do
      if p.uid == uid then
        local df = defs(p.id)
        local nx, ny, nz = piece_axis(p, (df and df.door and df.door.vertical) and "y" or "z")
        local cx, cy, cz = d.x or p.x or 0, d.y or ((p.y or 0) + 1.0), d.z or p.z or 0
        if not d.x then
          -- (rooms.lua gives no centre: the door's own leaf, a metre up its wall)
          cx, cy, cz = p.x or 0, (p.y or 0) + ((df and df.door and df.door.vertical) and 0.1 or 1.0), p.z or 0
        end
        local r = R_.roomAt(R, cx + nx * 0.7, cy + ny * 0.7, cz + nz * 0.7)
        s.dside[uid] = { nx = nx, ny = ny, nz = nz, x = cx, y = cy, z = cz, front = r and r.id or 0, def = df }
      end
    end
  end
  -- (S7) the Equalise Valves: the rooms either side of the wall each is on
  s.eqv = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.eqv then
      local nx, ny, nz = piece_axis(p, "y")
      local x, y, z = p.x or 0, (p.y or 0), p.z or 0
      local ra = R_.roomAt(R, x + nx * 0.5, y + ny * 0.5, z + nz * 0.5)
      local rb = R_.roomAt(R, x - nx * 0.75, y - ny * 0.75, z - nz * 0.75)
      s.eqv[p.uid] = { a = ra and ra.id or 0, b = rb and rb.id or 0, C = d.eqv.C or 0.25, label = d.label }
    end
  end
  S[sid] = s
  local FT = ref("feats"); if FT and FT.roomsSolved then pcall(FT.roomsSolved, sid, s) end   -- (progression P2: room_sealed)
  if w0 then PROF.solve_ms = (wall() - w0) * 1000 end
end

-- (S7) The valves open now: { { uid, a, b, C, kind, label } } — the Equalise
-- Valves, the doors' own equalising valves, and the leaks of damaged seals
-- (a shut door with a damaged seal leaks SEAL_C × its damage).
function valvesOf(sid, s)
  s = s or S[sid]
  local out = {}
  if not (s and s.R) then return out end
  for uid, e in pairs(s.eqv or {}) do
    local st = part_state(sid, uid)
    if st and st.open and e.a ~= e.b then out[#out + 1] = { uid = uid, a = e.a, b = e.b, C = e.C, kind = "eqv", label = "the " .. (e.label or "Equalise Valve") .. " is open" } end
  end
  for uid, d in pairs(s.R.doors) do
    if not s.dch[uid] and not door_open(sid, uid) then
      local st = part_state(sid, uid)
      local ds = s.dside and s.dside[uid]
      local dd = ds and ds.def and ds.def.door or {}
      if st and st.eq then out[#out + 1] = { uid = uid, a = d.a, b = d.b, C = dd.eq or EQ_DOOR, kind = "door", label = string.format("the %s's equalising valve is open", d.label or "door") } end
      local dmg = st and tonumber(st.seal) or 0
      if st and st.blown then out[#out + 1] = { uid = uid, a = d.a, b = d.b, C = BLOWN_C, kind = "seal", label = string.format("the %s's seal has BLOWN", d.label or "door") }
      elseif dmg > 0 then out[#out + 1] = { uid = uid, a = d.a, b = d.b, C = SEAL_C * dmg, kind = "seal", label = string.format("the %s's seal leaks", d.label or "door") } end
    end
  end
  return out
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
      -- (S8: a machine switched off by its run terminal makes nothing)
      if L.life.o2 and pow and not L.off then n.G = n.G + L.life.o2 end
      if L.life.o2 and L.life.water and not L.off then n.gens = n.gens or {}; n.gens[#n.gens + 1] = L end
      if L.life.scrub and pow and not L.off then n.S = n.S + L.life.scrub end
      if L.life.store then
        n.F = n.F + (L.life.flow or 0); n.tanks[#n.tanks + 1] = L
        -- (roompurge) each rack's purge pump, on the base grid
        if pow and not L.off then n.Sp = (n.Sp or 0) + (L.life.purge or RP_S) end
      end
      -- (X2) the compressor's makeup is the outside's mix less its O2; the
      -- concentrator makes O2 where the outside has it
      if (L.life.n2 or L.life.o2c) and pow then
        local po, xo, co = out_of(s, s.rec)
        if L.life.n2 and po >= N2_PMIN and xo < 1 then
          local q = L.life.n2
          n.JN = (n.JN or 0) + q * math.max(0, 1 - xo - co) / (1 - xo)
          n.Jc = (n.Jc or 0) + q * co / (1 - xo)
        end
        if L.life.o2c and xo >= O2C_MIN and po * xo >= 0.01 then n.G = n.G + L.life.o2c end
      end
    end
  end
  -- (S7) the valves: to the outside (or a leaky room) they vent the network
  -- slowly; between two networks they are LINKS, stepped apart (below)
  local n_links = {}
  for _, v in ipairs(valvesOf(sid, s)) do
    local na = v.a ~= 0 and byRoom[v.a] or nil
    local nb = v.b ~= 0 and byRoom[v.b] or nil
    local ra, rb = s.R.byId[v.a], s.R.byId[v.b]
    if na and ra and ra.leaky then na = nil end
    if nb and rb and rb.leaky then nb = nil end
    if na and nb then
      if na ~= nb then n_links[#n_links + 1] = { a = na, b = nb, C = v.C, v = v } end
    elseif na or nb then
      local n = na or nb
      n.Gv = (n.Gv or 0) + v.C
      n.causes[#n.causes + 1] = v.label
      -- (a valve opened on purpose to bleed the room: its regulators stand
      -- down, or they would fight it; a seal's leak they feed)
      if v.kind ~= "seal" then n.bleed = true end
    end
  end
  -- (roompurge) a network with a room being purged is purged whole
  for rid in pairs(s.purge or {}) do
    local n = byRoom[rid]
    if n then n.purge = true end
  end
  -- what the Room Gas Outlets bring (fluid_net sets it, kg/s → atm·m³/s)
  for rid, j in pairs(s.inject or {}) do
    local n = byRoom[rid]
    if n then n.Jx = (n.Jx or 0) + (j.o2 or 0) / 1.429; n.JN = (n.JN or 0) + (j.n2 or 0) / 1.251 end
  end
  for _, n in ipairs(out) do
    local G = n.openings * G_OPEN + (n.Gv or 0)
    if G > 0 then
      n.tau = math.max(1.0, n.V / G)
      -- (only valves and leaks the regulators can match at 1 atm: they keep
      -- feeding; a breach, or a leak bigger than they can make up, trips
      -- their excess-flow valves and they shut)
      n.slow = n.openings == 0 and not n.bleed and (n.Gv or 0) <= n.F + 1e-12
    end
  end
  s.links = n_links
  return out, byRoom
end

local function nets(sid, s)
  if s.netsDirty or not s.nets then s.nets, s.byRoom = nets_of(sid, s); s.netsDirty = false end
  return s.nets, s.byRoom
end

-- (roompurge) A purge over (done: pumped down; open: the room opened to the
-- outside; stop: by hand): the network's rooms let go, the grid told (the
-- pumps' draw), said in the base log and, with the crew there, a caption.
lastPurge = nil
local function purge_end(sid, s, n, why)
  local first = nil
  for _, id in ipairs(n.rooms) do
    if s.purge[id] then s.purge[id] = nil; first = first or id end
  end
  n.purge = nil
  s.netsDirty = true
  lastPurge = { sid = sid, rid = first, why = why, t = now(), a = s.a }
  local BG = ref("base_grid"); if BG and BG.markDirty then BG.markDirty() end
  local msg = (why == "done" and string.format("Room %s purged to %.2f atm: the racks are refilling it with air", tostring(first), RP_P))
              or (why == "open" and string.format("Room %s's purge stopped: the room is open to the outside", tostring(first)))
              or string.format("Room %s's purge stopped", tostring(first))
  local BL = ref("base_log")
  if BL and BL.add then pcall(BL.add, sid, why == "open" and "warn" or "air", msg) end
  if crew.sid == sid then
    local fx = ref("sfx"); if fx and fx.caption then pcall(fx.caption, msg) end
  end
  if log then log("room_air: " .. msg .. " (structure " .. tostring(sid) .. ")") end
end

-- Step structure sid's air to agency time a (exact, capped for a catch-up).
local function advance_struct(sid, s, a)
  if not s.a then s.a = a end
  local dt = math.min(a - s.a, CATCH_MAX)
  s.a = a
  if dt <= 0 then return end
  if dt > 60 then PROF.catch = dt end
  local pout, xout, cout = out_of(s, s.rec)
  local all = nets(sid, s)
  local sts = {}
  for _, n in ipairs(all) do
    local st = { N = 0, x = 0, c = 0, q = 0, feed = false, jon = n.jon }
    for _, id in ipairs(n.rooms) do
      local A = s.air[id]
      st.N, st.x, st.c = st.N + A.N, st.x + A.x, st.c + A.c
      st.feed = st.feed or A.f == true
    end
    local cap = 0
    for _, L in ipairs(n.tanks) do st.q = st.q + (s.tanks[L.uid] or 0); cap = cap + L.life.store end
    -- (S7) the generators' water: their cells together
    local wcap, W = 0, nil
    for _, L in ipairs(n.gens or {}) do W = (W or 0) + (s.cells[L.uid] or 0); wcap = wcap + L.life.water end
    st.w, st.h2 = W, 0
    if n.V > 0 then
      local M = { V = n.V, crew = n.crew, G = n.G, S = n.S, F = (st.q > EPS) and n.F or 0, tau = n.tau, slow = n.slow, pout = pout, xout = xout,
                  cout = cout, W = W, Jx = n.Jx, JN = n.JN, Jc = n.Jc }
      if n.purge and n.openings > 0 then
        purge_end(sid, s, n, "open")
        advance(st, M, dt)
      elseif n.purge then
        -- (roompurge) the regulator waits for the pump-down; the pumps draw
        -- the network to a vacuum alongside whatever valves it has open
        -- (conductances add: τ = V / (Gv + Sp), the outside weighted Gv / (Gv + Sp))
        local F = M.F
        M.F, st.feed = 0, false
        if (n.Sp or 0) > 0 then
          local Gv = n.Gv or 0
          local Gt = Gv + n.Sp
          local _, rep = advance(st, { V = n.V, tau = n.V / Gt, slow = false, pout = pout * Gv / Gt, xout = xout, cout = cout, F = 0,
                                       pT = RP_P, Jx = n.Jx, JN = n.JN, Jc = n.Jc }, dt)
          if rep.purged then
            purge_end(sid, s, n, "done")
            M.F = (st.q > EPS) and n.F or 0
            advance(st, M, rep.left or 0)
          end
        else
          advance(st, M, dt)   -- (no power: the pump stops, the room holds as it is)
        end
        M.F = F
      else
        advance(st, M, dt)
      end
    end
    n.jon = st.jon
    sts[#sts + 1] = st
    for _, L in ipairs(n.tanks) do s.tanks[L.uid] = (cap > 0) and st.q * L.life.store / cap or 0 end
    if W then
      local ng = #n.gens
      for _, L in ipairs(n.gens) do
        s.cells[L.uid] = (wcap > 0) and (st.w or 0) * L.life.water / wcap or 0
        s.h2[L.uid] = (s.h2[L.uid] or 0) + (st.h2 or 0) / ng
        s.made[L.uid] = (s.made[L.uid] or 0) + (st.made or 0) / ng
      end
    end
  end
  -- (S7) the links: a valve between two networks lets their pressures meet
  -- (exact for the valve alone; stepped after the networks' own closed forms)
  for _, L in ipairs(s.links or {}) do
    local ia, ib
    for i, n in ipairs(all) do if n == L.a then ia = i end if n == L.b then ib = i end end
    if ia and ib then equalise(sts[ia], L.a.V, sts[ib], L.b.V, L.C, dt) end
  end
  for i, n in ipairs(all) do
    local st = sts[i]
    for _, id in ipairs(n.rooms) do
      local r = s.R.byId[id]
      local k = (n.V > 0) and r.m3 / n.V or 0
      s.air[id] = { N = st.N * k, x = st.x * k, c = st.c * k, f = st.feed }
    end
  end
  local FT = ref("feats"); if FT and FT.airStep then pcall(FT.airStep, sid, s, all, dt, statusOf) end   -- (progression P2: room_breathable)
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
  st.purging = n ~= nil and n.purge == true
  st.foul = foulAir(A)
  return st
end

-- ── (roompurge) the room purge ──────────────────────────────────────────────
-- "45 s" | "4.8 min"
function fmtSecs(t)
  if not t then return "—" end
  if t < 90 then return string.format("%.0f s", t) end
  return string.format("%.1f min", t / 60)
end
-- A purge plan in a line (purgeInfo's): what it takes and why you'd want it
function purgeLine(pi)
  if not pi then return "—" end
  local pl = pi.plan
  local cost = string.format("%s to pump down (%.1f kW), %s to refill · %.0f of %.0f m³ of air", fmtSecs(pl.pump), pi.kw, fmtSecs(pl.fill), pl.need, pi.q)
  if pi.foul then return "the room holds the outside's gas: purge it · " .. cost end
  return cost
end
-- Room rid's network and the air its racks hold: → n, q | nil
local function purge_net(sid, rid)
  local s = S[sid]
  if not (s and s.R and s.R.byId[rid]) then return nil end
  local _, byRoom = nets(sid, s)
  local n = byRoom and byRoom[rid]
  if not n then return nil end
  local q = 0
  for _, L in ipairs(n.tanks) do q = q + (s.tanks[L.uid] or 0) end
  return n, q, s
end
function purging(sid, rid) local n = purge_net(sid, rid); return n ~= nil and n.purge == true end
-- Why a purge of room rid can't start now, or nil. (Never the crew in it:
-- they are warned, not refused.)
function purgeWhy(sid, rid)
  local n, q, s = purge_net(sid, rid)
  if not n then return "no such room" end
  local r = s.R.byId[rid]
  if n.purge then return string.format("Room %s is already being purged", tostring(rid)) end
  if r.airlock then return "an airlock purges its own chamber as it cycles" end
  if r.leaky or not r.sealed then return string.format("Room %s isn't sealed: a purge would only pull the outside in", tostring(rid)) end
  if #n.tanks == 0 then return string.format("no Air Tank Rack in Room %s: the purge pump and the air to refill it are on a rack", tostring(rid)) end
  if n.openings > 0 then return string.format("Room %s is open to the outside: shut it first", tostring(rid)) end
  if not s.pow then return "no power: the racks' purge pumps run on the base grid" end
  local A = { N = 0, x = 0, c = 0 }
  for _, id in ipairs(n.rooms) do local a = s.air[id]; A.N, A.x, A.c = A.N + a.N, A.x + a.x, A.c + a.c end
  local pl = purgePlan(n.V, A.N + A.x + A.c, n.Sp or 0, n.F, q)
  if pl.short then
    return string.format("the racks hold %.0f m³ of air; refilling Room %s takes %.0f m³: refill them or add a rack", q, tostring(rid), pl.need)
  end
  return nil
end
-- What a purge of room rid would take, or is doing (worked out when asked:
-- the menu asks once when it opens). → { purging, foul, p, V, rooms, crew,
-- racks, q, plan = purgePlan's, kw } | nil
function purgeInfo(sid, rid)
  local n, q, s = purge_net(sid, rid)
  if not n then return nil end
  local A = { N = 0, x = 0, c = 0 }
  for _, id in ipairs(n.rooms) do local a = s.air[id]; A.N, A.x, A.c = A.N + a.N, A.x + a.x, A.c + a.c end
  local tot = A.N + A.x + A.c
  local Sp = 0
  for _, L in ipairs(n.tanks) do if not L.off then Sp = Sp + (L.life.purge or RP_S) end end
  local kw = 0
  for _, L in ipairs(n.tanks) do if not L.off then kw = kw + (L.life.purgeKW or RP_KW) end end
  return { purging = n.purge == true, foul = foulAir(A), p = tot / math.max(n.V, 1e-9), V = n.V, rooms = #n.rooms,
           crew = n.crew or 0, racks = #n.tanks, q = q, plan = purgePlan(n.V, tot, Sp, n.F, q), kw = kw, pow = s.pow == true }
end
-- Start purging room rid (its whole network). → ok, why | ok, warning
function startPurge(sid, rid, by)
  local w = purgeWhy(sid, rid)
  if w then return false, w end
  local s = S[sid]
  advance_struct(sid, s, agency_now())
  local n = purge_net(sid, rid)
  for _, id in ipairs(n.rooms) do s.purge[id] = { t0 = s.a } end
  s.netsDirty = true
  local BG = ref("base_grid"); if BG and BG.markDirty then BG.markDirty() end
  -- the crew in it are warned, never refused (Ty's sandbox: danger is allowed)
  local warn = nil
  if (n.crew or 0) > 0 then
    warn = string.format("Room %s has crew in it: the purge pumps their air out. Helmets on.", tostring(rid))
    local inRoom = false
    for _, id in ipairs(n.rooms) do if crew.sid == sid and crew.rid == id then inRoom = true end end
    if inRoom then
      local bc = ref("big_caption")
      if bc and bc.show then bc.show("PURGE", warn, 4.0, helmetOff() and "alarm" or "result") end
    end
  end
  local BL = ref("base_log")
  local pi = purgeInfo(sid, rid)
  if BL and BL.add then
    pcall(BL.add, sid, warn and "warn" or "air", string.format("Room %s purge started (~%.0f s to pump down, ~%.0f s to refill)%s", tostring(rid),
      pi and pi.plan.pump or 0, pi and pi.plan.fill or 0, warn and (": " .. warn) or ""))
  end
  if audio and audio.play then pcall(audio.play, "audio/foley/servo_run.ogg", { track = "SFX", volume = 0.35 }) end
  lastPurge = { sid = sid, rid = rid, why = "start", t = now(), a = s.a, warn = warn, by = by }
  return true, warn
end
-- Stop room rid's purge by hand (the regulator then fills what is there).
function stopPurge(sid, rid)
  local n, _, s = purge_net(sid, rid)
  if not (n and n.purge) then return false, "no purge under way" end
  advance_struct(sid, s, agency_now())
  n = purge_net(sid, rid)
  if n and n.purge then purge_end(sid, s, n, "stop") end
  return true
end

function solveNow(sid) solve(sid) end
-- (S7) step structure sid's air to agency time a (fluid_net's catch-up, piece by piece)
function advanceTo(sid, a) local s = S[sid]; if s then advance_struct(sid, s, a) end end
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
-- the pressure on side `id` of a door (0 = the outside; a leaky room is the outside's)
local function side_pressure(s, id)
  if id == 0 then return (out_of(s, s.rec)) end
  local r, A = s.R.byId[id], s.air[id]
  if not (r and A) then return 0 end
  if r.leaky then return (out_of(s, s.rec)) end
  return (A.N + A.x + A.c) / r.m3
end
-- (S7) THE SUIT RULE: crew on foot with the helmet off (no sealed suit) never
-- pass a door to low pressure; they are told to put it on.
function helmetOff()
  local su = ref("suit")
  if not (su and su.helmetOn) then return false end
  local ok, on = pcall(su.helmetOn)
  return ok and on == false
end
local suit_say = -10
lastSuitRefusal = nil
local function suit_refuses(s, sid, uid, farP)
  if farP >= P_MIN or not helmetOff() then return false end
  s.suitHeld = s.suitHeld or {}
  s.suitHeld[uid] = now()
  lastSuitRefusal = { sid = sid, uid = uid, p = farP, t = now() }
  if now() - suit_say > 4.0 then
    suit_say = now()
    local d = s.R.doors[uid]
    local msg = string.format("Helmet off: the far side of the %s is at %.2f atm. Put your helmet on first.", d and d.label or "door", farP)
    local bc = ref("big_caption")
    if bc and bc.show then bc.show("SUIT", msg, 3.0, "result") end
    local fx = ref("sfx")
    if fx and fx.caption then fx.caption(msg) end
    if audio and audio.play then pcall(audio.play, "audio/sfx/crew_chime.ogg", { track = "UI", volume = 0.4 }) end
  end
  return true
end
-- the far side of a door from the active crew (both sides' lower if they're on neither)
local function far_side(s, sid, uid)
  local d = s.R.doors[uid]
  if not d then return nil end
  local here = (crew.sid == sid) and crew.rid or 0
  if d.a == here then return d.b elseif d.b == here then return d.a end
  return (side_pressure(s, d.a) < side_pressure(s, d.b)) and d.a or d.b
end
function gate(sid, uid, want)
  local s = S[sid]
  if not s then return want end
  local rid = s.dch[uid]
  if rid then
    local C = s.cham[rid]
    if not C then return want end
    if want and want > 0 then C.wants[uid] = now() end
    -- (playtest 11-11) a hand's override: it opens to the crew whatever the
    -- pressures, until it shuts again (doorMoved), warned, never refused
    if s.forced[uid] then return want end
    return (C.allow == uid) and 1 or 0
  end
  if not (want and want > 0) then return want end
  if not door_open(sid, uid) then
    local far = far_side(s, sid, uid)
    if far and suit_refuses(s, sid, uid, side_pressure(s, far)) then return 0 end
  end
  if s.forced[uid] then return want end
  local dp, pa, pb = door_dp(s, uid)
  if dp and dp > HOLD_DP and not door_open(sid, uid) then
    s.held[uid] = now()
    if now() - held_say > 4.0 then
      held_say = now()
      local fx = ref("sfx")
      if fx and fx.caption then fx.caption(string.format("held shut: %.2f atm against %.2f · its menu equalises or forces it", math.max(pa, pb), math.min(pa, pb))) end
    end
    return 0
  end
  return want
end
-- A door's pressure difference: → dp, pa, pb | nil (not a door of a room)
function door_dp(s, uid)
  local d = s.R and s.R.doors[uid]
  if not d then return nil end
  local pa, pb = side_pressure(s, d.a), side_pressure(s, d.b)
  return math.abs(pa - pb), pa, pb
end
function forceOpen(sid, uid) local s = S[sid]; if s then s.forced[uid] = true end end
-- (S8, logic_net) an airlock asked to cycle to door uid: as a crew member at
-- that door asks (kept alive while the signal is on: the chamber forgets a
-- request 0.3 s old)
function requestDoor(sid, uid)
  local s = S[sid]
  local rid = s and s.dch and s.dch[uid]
  local C = rid and s.cham[rid]
  if not C then return false end
  C.wants[uid] = now()
  return true
end
-- Is door uid's airlock ready for it: every other door of the chamber shut and
-- the chamber at the pressure beyond it (the door may open)? → bool | nil (no airlock)
function airlockReady(sid, uid)
  local s = S[sid]
  local rid = s and s.dch and s.dch[uid]
  local C = rid and s.cham[rid]
  if not (C and s.R and s.R.byId[C.rid] and s.air[C.rid]) then return nil end
  if C.allow == uid then return true end
  for _, u in ipairs(C.doors) do if u ~= uid and door_open(sid, u) then return false end end
  local r, A = s.R.byId[C.rid], s.air[C.rid]
  local pc = (A.N + A.x + A.c) / r.m3
  local d = s.R.doors[uid]
  if not d then return false end
  local other = (d.a == C.rid) and d.b or d.a
  local pT = side_pressure(s, other)
  return math.abs(pc - pT) <= 0.04
end
-- (S8, logic_net) a life-support machine's run terminal: off, it makes nothing
-- and draws nothing (its part state `off`)
-- (the interaction plan §3) the life machines' switch: a scrubber, an O2
-- Generator (a rack and a receiver are vessels, not machines: no switch).
local function machine_def(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  return p, d
end
local function is_machine(d) return d and d.life and not d.life.store and not d.life.receiver end
local function called(sid, uid, d)
  local PI = ref("part_info")
  if PI and PI.called then local ok, n = pcall(PI.called, sid, uid); if ok and n then return n end end
  return "the " .. tostring(d and d.label or "machine")
end
-- WHY NOT: would a hand on machine (sid, uid)'s switch be refused making it
-- `want` (true = running)? Knocked askew it won't start; a Signal Cable on its
-- RUN terminal has it (logic_net's authority). → nil | sentence
function whyNot(sid, uid, want)
  local p, d = machine_def(sid, uid)
  if not p then return "that piece is gone" end
  if not is_machine(d) then return called(sid, uid, d) .. " has no switch" end
  if want and p.wr then return called(sid, uid, d) .. " is knocked askew: repair it first (a Repair Kit, 4 s)" end
  local LN = ref("logic_net")
  if LN and LN.whyNot then
    local ok, w = pcall(LN.whyNot, sid, uid, want)
    if ok and w then return w end
  end
  return nil
end
-- Why machine (sid, uid) is not doing its job now, though switched on, or
-- nil: no power, no sealed room, a dry water cell. (part_info's WHY line.)
function runWhy(sid, uid)
  local p, d = machine_def(sid, uid)
  if not (p and is_machine(d)) then return nil end
  if not machineOn(sid, uid) then return "switched off" end
  local s = S[sid]
  if not s then return "not in a sealed room: it does nothing here" end
  local rid = nil
  for _, l in ipairs(s.life) do if l.uid == uid then rid = l.rid end end
  if not rid then return "not in a sealed room: it does nothing here" end
  if not s.pow then return "no power: it runs on the base grid" end
  if d.life.water and (s.cells[uid] or 0) <= 0.001 then return "its water cell is dry: pipe water to its back" end
  return nil
end
-- WARN: what switching machine (sid, uid) off does to its room, or nil
function warnOf(sid, uid, want)
  if want then return nil end
  local p, d = machine_def(sid, uid)
  local s = S[sid]
  if not (p and is_machine(d) and s) then return nil end
  local rid = nil
  for _, l in ipairs(s.life) do if l.uid == uid then rid = l.rid end end
  if not rid then return nil end
  if d.life.o2 then return string.format("Room %s loses %s's oxygen: O2 falls while anyone breathes", tostring(rid), called(sid, uid, d)) end
  return string.format("Room %s loses %s: CO2 climbs while anyone breathes", tostring(rid), called(sid, uid, d))
end
function setMachine(sid, uid, on, by)
  local wn = nil
  if by == "hand" then
    local w = whyNot(sid, uid, on)
    if w then return false, w end
    wn = warnOf(sid, uid, on)
  end
  local s = S[sid]
  if s then advance_struct(sid, s, agency_now()) end
  if by == "hand" and machineOn(sid, uid) ~= (on and true or false) then
    local BL = ref("base_log")
    if BL and BL.add then pcall(BL.add, sid, wn and "warn" or "air", string.format("%s %s%s", tostring(called(sid, uid)):gsub("^the ", ""), on and "started" or "stopped", wn and (": " .. wn) or "")) end
  end
  set_part_state(sid, uid, "off", (not on) or nil)
  if s then
    for _, L in ipairs(s.life) do if L.uid == uid then L.off = (not on) or nil end end
    s.netsDirty = true
  end
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
  return true, wn
end
function machineOn(sid, uid) local st = part_state(sid, uid); return not (st and st.off) end
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

-- ── THE AIRLOCK'S SIGHT AND SOUND (playtest 11-11: "there's no particles or
-- sound effects in depressurization, so it's hard to tell what's going on") ──
-- While a chamber cycles, near the crew (AV_R): the air's hiss (a loop at the
-- chamber, loud while the pressures are far apart), the pump's motor while it
-- pumps (a recorded electric pump), vapour in the chamber as its air thins or
-- rushes back in (the cold of expansion), a puff of frost out of the lock's
-- vent while gas goes overboard (dust kicked up off the ground under it on a
-- world with air), and when it is done the latch and a struck bell. The door
-- leaves' motors are kit_live's. Nothing is kept in the world: every point is
-- placed from the structure's frame and this frame's body read when it is
-- used (frames doc rule 1).
AV_R = 25.0
PUFF_EVERY = 0.3
SND = { hiss = "audio/foley/hiss_cylinder.ogg", pump = "audio/plant/pump_motor.ogg", chime = "audio/plant/airlock_chime.ogg",
        clunk = "audio/foley/latch_clunk.ogg", servo = "audio/foley/servo_run.ogg" }
lastPuff = nil
local function frame_pt(s, lx, ly, lz)
  local KS = ref("kit_snap")
  local b = space and space.body and space.body(s.rec.b)
  if not (KS and b) then return nil end
  local fr = KS.frameOf(s.rec)
  return b.x + fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz,
         b.y + fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
         b.z + fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz, fr
end
-- A point `off` m off door uid's middle, `up` m up, on the side of room
-- `toward` (0: the outside), and the normal pointing that way: x, y, z, nx, ny, nz
local function door_pt(s, uid, toward, off, up)
  local ds = s.dside and s.dside[uid]
  if not ds then return nil end
  local sg = (ds.front == toward) and 1 or -1
  local x, y, z, fr = frame_pt(s, ds.x + ds.nx * sg * off, ds.y + (up or 0) + ds.ny * sg * off, ds.z + ds.nz * sg * off)
  if not x then return nil end
  local nx, ny, nz = ds.nx * sg, ds.ny * sg, ds.nz * sg
  return x, y, z, fr.R.x * nx + fr.U.x * ny + fr.F.x * nz, fr.R.y * nx + fr.U.y * ny + fr.F.y * nz, fr.R.z * nx + fr.U.z * ny + fr.F.z * nz
end
doorPoint = function(sid, uid, toward, off, up) local s = S[sid]; if s then return door_pt(s, uid, toward, off, up) end end
local function crew_near(x, y, z, r)
  local a = find and find("Astronaut")
  if not (valid(a) and x) then return false end
  return (a.x - x) ^ 2 + (a.y - y) ^ 2 + (a.z - z) ^ 2 < r * r
end
local function V3(x, y, z) if vec3 then return vec3(x, y, z) end return { x = x, y = y, z = z } end
local function snd_stop(h) if type(h) == "table" or type(h) == "userdata" then pcall(function() h:stop() end) end end
local function puff(key, x, y, z, nx, ny, nz, sc, inten, dust, vel)
  local V = ref("vfx")
  if V and V.emit then pcall(V.emit, key, x, y, z, { normal = V3(nx, ny, nz), scale = sc, intensity = inten, dust = dust, vel = vel })
  elseif spawnEffect then pcall(spawnEffect, key, V3(x, y, z), { normal = V3(nx, ny, nz), scale = sc }) end
  lastPuff = { key = key, x = x, y = y, z = z, t = now() }
  PROF.puffs = (PROF.puffs or 0) + 1
end
-- the outside's door of a chamber (nil: it opens only onto rooms)
local function outer_of(s, C)
  for _, u in ipairs(C.doors) do
    local d = s.R.doors[u]
    local o = d and ((d.a == C.rid) and d.b or d.a)
    if d and (o == 0 or (s.R.byId[o] and s.R.byId[o].leaky)) then return u end
  end
  return nil
end
local function cycle_sound(s, C, on)
  local x, y, z = ch_world(s, C)
  if on and not C.snd then
    if x and audio and audio.play then
      local ok, h = pcall(audio.play, SND.hiss, x, y, z, { loop = true, maxDistance = AV_R, track = "SFX", volume = 0.5 })
      C.snd = ok and h or true
      pcall(audio.play, SND.servo, x, y, z, { maxDistance = 20, track = "SFX", volume = 0.35 })
    else C.snd = true end
    C.puff_t = -10
    local fx = ref("sfx")
    if fx and fx.caption then fx.caption(C.dir == "down" and "airlock: depressurising" or "airlock: pressurising") end
  elseif not on and C.snd then
    snd_stop(C.snd); C.snd = nil
    snd_stop(C.pump); C.pump = nil
    if x and audio and audio.play then
      pcall(audio.play, SND.clunk, x, y, z, { maxDistance = 20, track = "SFX", volume = 0.55 })
      pcall(audio.play, SND.chime, x, y, z, { maxDistance = 22, track = "SFX", volume = 0.5 })
    end
  end
  if not (on and x) then return end
  -- the pump's motor: on while it pumps, its note rising a little as the chamber thins
  if C.pumping and not C.pump and audio and audio.play then
    local ok, h = pcall(audio.play, SND.pump, x, y, z, { loop = true, maxDistance = AV_R, track = "SFX", volume = 0.55 })
    C.pump = ok and h or nil
  elseif not C.pumping and C.pump then snd_stop(C.pump); C.pump = nil end
  local pc = ch_p(s, C)
  if C.pump and C.pump.setPitch then pcall(C.pump.setPitch, C.pump, 0.92 + 0.16 * math.max(0, math.min(1, 1 - pc))) end
  -- the hiss follows the flow: loud while the pressures are far apart
  local gap = math.abs(pc - (C.pT or pc))
  if type(C.snd) ~= "boolean" and C.snd.setVolume then pcall(C.snd.setVolume, C.snd, 0.15 + 0.5 * math.min(1, gap)) end
  -- the vapour and the vent, near the crew only
  local t = now()
  if t - (C.puff_t or -10) < PUFF_EVERY or not crew_near(x, y, z, AV_R) then return end
  C.puff_t = t
  local r = s.R.byId[C.rid]
  local inten = math.min(1, 0.25 + gap)
  local cx, cy, cz, fr = frame_pt(s, r and r.cx or 0, (r and r.cy or 1.2) + 0.7, r and r.cz or 0)
  if cx and gap > 0.03 then
    -- (in the chamber: a fog of condensing moisture under its vent, down or up)
    puff("LockFog", cx, cy, cz, -fr.U.x, -fr.U.y, -fr.U.z, 0.7, inten)
  end
  local out = outer_of(s, C)
  local overboard = C.dir == "down" and (not C.pumping or C.purging)
  if out and overboard and fr then
    local vx, vy, vz, nx, ny, nz = door_pt(s, out, 0, 0.35, 0.9)
    if vx then
      puff("LockVent", vx, vy, vz, nx, ny, nz, 0.6 + 0.6 * math.min(1, pc), inten)
      -- (a world with air: the jet kicks up the ground's dust under the vent)
      if out_of(s, s.rec) > 0.05 then
        local gx, gy, gz = door_pt(s, out, 0, 0.9, -0.9)
        if gx then puff("LockDust", gx, gy, gz, fr.U.x, fr.U.y, fr.U.z, 0.8, inten, true) end
      end
    end
  end
end

-- The airlock's state as its door panel shows it, for door uid:
--   label   READY · CYCLING · EQUALISING · VENTING · CLOSING · HELMET ·
--           NO POWER · OVERRIDE · STANDBY
--   col     "go" (green), "busy" (amber), "stop" (red), "idle" (dim)
--   pc, pT  the chamber's pressure and the pressure beyond this door
-- → { label, col, pc, pT, secs (the cycle's time so far) } | nil (no airlock)
function airlockStatus(sid, uid)
  local s = S[sid]
  local rid = s and s.dch and s.dch[uid]
  local C = rid and s.cham[rid]
  if not (C and s.R and s.R.byId[C.rid] and s.air[C.rid]) then return nil end
  local pc = ch_p(s, C)
  local pT = side_p(s, C, uid)
  local t = now()
  local o = { pc = pc, pT = pT, secs = C.cyc and (t - (C.cyc_t or t)) or nil }
  if s.forced[uid] then o.label, o.col = "OVERRIDE", "stop"
  elseif C.allow == uid then o.label, o.col = "READY", "go"
  elseif C.target == uid and C.state == "helmet" then o.label, o.col = "HELMET", "stop"
  elseif C.target == uid and C.state == "closing" then o.label, o.col = "CLOSING", "busy"
  elseif C.target == uid and C.cyc then
    if C.dir == "down" then
      if C.pumping then o.label, o.col = "CYCLING", "busy"
      elseif not s.pow then o.label, o.col = "NO POWER", "stop"
      else o.label, o.col = "VENTING", "busy" end
    else o.label, o.col = "EQUALISING", "busy" end
  elseif C.cyc then o.label, o.col = "CYCLING", "busy"
  else o.label, o.col = "STANDBY", "idle" end
  return o
end

-- Is the crew (in the chamber) standing in door uid's doorway? (structure frame)
local function in_doorway(s, uid)
  local ds = s.dside and s.dside[uid]
  if not (ds and crew.lx) then return false end
  local dx, dz = crew.lx - ds.x, crew.lz - ds.z
  local along = math.abs(dx * ds.nx + dz * ds.nz)
  local side = math.abs(dx * ds.nz - dz * ds.nx)
  return along < 0.7 and side < 0.9
end
REQ_S = 20.0      -- a panel's "Cycle to this door" holds this long
local function chamber_tick(sid, s, C, dt)
  local t = now()
  local inside = crew.sid == sid and crew.rid == C.rid
  local target = nil
  -- (a door that is open now is the side the chamber is at: remembered, so a
  -- crew member found in it with every door shut came in by that one)
  for _, u in ipairs(C.doors) do if door_open(sid, u) then C.home = u end end
  local req = C.req and t - C.req.t < REQ_S and C.req.uid or nil
  if not req then C.req = nil end
  if inside then
    if not C.entered then
      for _, u in ipairs(C.doors) do if door_open(sid, u) then C.entered = u end end
      -- (playtest 11-11, Graveyard: "the first door opened and the second one
      -- wouldn't". In the chamber with every door shut, the entry was guessed
      -- by the nearest room's middle, and the outside has none: it always
      -- picked the hab's door and cycled back out. Now: the side the chamber
      -- was last open to, else the side whose pressure it holds)
      if not C.entered and C.home then
        for _, u in ipairs(C.doors) do if u == C.home then C.entered = u end end
      end
      if not C.entered then
        local pc0 = ch_p(s, C)
        local best, bd = nil, 1e18
        for _, u in ipairs(C.doors) do
          local d = math.abs(side_p(s, C, u) - pc0)
          if d < bd then best, bd = u, d end
        end
        C.entered = best
      end
    end
    for _, u in ipairs(C.doors) do if u ~= C.entered then target = target or u end end
    if req then target = req end
  else
    C.entered = nil
    local bt = -1
    for u, w in pairs(C.wants) do if t - w < 0.3 and w > bt then target, bt = u, w end end
    if not target and req then target = req end
  end
  C.target = target
  C.allow = nil
  C.state = nil
  if not target then
    if C.cyc then C.cyc = nil; cycle_sound(s, C, false) end
    return
  end
  -- (the door they came in by stays open while they stand in it: it never
  -- shuts on a crew member mid-step)
  if inside and C.entered and C.entered ~= target and door_open(sid, C.entered) and in_doorway(s, C.entered) then
    C.allow = C.entered
    C.state = "closing"
    return
  end
  for _, u in ipairs(C.doors) do if u ~= target and door_open(sid, u) then C.state = "closing" return end end
  local pT = side_p(s, C, target)
  local pc, Vc = ch_p(s, C)
  C.pT = pT
  -- (S7) the suit rule: inside with the helmet off, it won't cycle to low pressure
  if inside and pT < P_MIN and pc > pT + 0.04 and suit_refuses(s, sid, target, pT) then
    if C.cyc then C.cyc = nil; cycle_sound(s, C, false) end
    C.state = "helmet"
    return
  end
  if math.abs(pc - pT) <= 0.04 then
    C.allow = target
    if C.req and C.req.uid == target then
      -- (asked from inside: the chamber now faces that door, so the crew in it
      -- are taken to be going out by it, not back the way they came)
      if inside then for _, u in ipairs(C.doors) do if u ~= target then C.entered = u end end end
      C.req = nil
    end
    if C.cyc then
      C.cyc = nil; C.done_t = t; cycle_sound(s, C, false); C.mode = nil
      if C.pumping then C.pumping = false; local BG = ref("base_grid"); if BG and BG.markDirty then BG.markDirty() end end
      lastCycleSecs = t - (C.cyc_t or t)
    end
    return
  end
  if not C.cyc then C.cyc = target; C.cyc_t = t; C.saved, C.vented, C.back, C.said = 0, 0, 0, nil; C.purged = nil end
  local was = C.pumping
  C.purging = nil
  cycleStep(sid, s, C, target, pT, dt)
  if was ~= C.pumping then local BG = ref("base_grid"); if BG and BG.markDirty then BG.markDirty() end end
  cycle_sound(s, C, true)
  s.netsDirty = true
end
lastCycleSecs = nil
-- (playtest 11-11) an airlock door's MANUAL OVERRIDE (its panel, its menu):
-- it opens to the crew now whatever the chamber holds, the other door's
-- interlock kept. Never refused: what it does is said. → true, warning | false, why
function overrideDoor(sid, uid)
  local s = S[sid]
  local rid = s and s.dch and s.dch[uid]
  local C = rid and s.cham[rid]
  if not C then return false, "not an airlock's door" end
  advance_struct(sid, s, agency_now())
  local pc, pT = ch_p(s, C), side_p(s, C, uid)
  s.forced[uid] = true
  local warn = nil
  if math.abs(pc - pT) > 0.04 then
    warn = string.format("OVERRIDE: %.2f atm in the chamber against %.2f beyond: it %s as the door opens", pc, pT,
      pc > pT and "vents" or "floods")
    local x, y, z = door_pt(s, uid, (pc > pT) and ((s.R.doors[uid].a == C.rid) and s.R.doors[uid].b or s.R.doors[uid].a) or C.rid, 0.3, 0.2)
    if x and audio and audio.play then pcall(audio.play, "audio/foley/buzz_denied.ogg", x, y, z, { maxDistance = 15, track = "SFX", volume = 0.5 }) end
  end
  local BL = ref("base_log")
  if BL and BL.add then pcall(BL.add, sid, warn and "warn" or "door", string.format("airlock door overridden by hand%s", warn and (": " .. warn) or "")) end
  return true, warn
end
-- (a panel's key, the menu's "Cycle to this door") the chamber cycles to door
-- uid and holds it there for REQ_S, from inside or out. → ok, why
function cycleTo(sid, uid)
  local s = S[sid]
  local rid = s and s.dch and s.dch[uid]
  local C = rid and s.cham[rid]
  if not C then return false, "not an airlock's door" end
  C.req = { uid = uid, t = now() }
  return true
end

-- (S7) THE CYCLE, exact for any dt:
--   DOWN  the pump (grid power) draws the chamber at PUMP_S m³/s at its own
--         pressure, so it falls as e^(-PUMP_S t / V) (a bigger chamber takes
--         longer), into the chamber's RECEIVERS (an Airlock Receiver in the
--         chamber or the room behind it) while they have room; with none, into
--         the hab behind it (the S3 way). Down to P_RESID: the rest is vented.
--         No power, or the receivers full: the vent valve dumps it (VENT_C)
--         and the airlock says so.
--   UP    the receivers bleed back through their valve (REC_C) and the hab
--         (or the room ahead) tops it up through the door's valve: pressures
--         meeting, no power needed.
local function receivers_of(s, C, inner)
  local out = {}
  for _, L in ipairs(s.life) do
    if L.life.receiver and (L.rid == C.rid or (inner and L.rid == inner)) then out[#out + 1] = L end
  end
  return out
end
local function cyc_say(C, msg)
  if C.said == msg then return end
  C.said = msg
  local fx = ref("sfx")
  if fx and fx.caption then fx.caption(msg) end
  local bc = ref("big_caption")
  if bc and bc.show and msg:find("vent", 1, true) then bc.show("AIRLOCK", msg, 3.5, "result") end
  lastCycle = msg
end
lastCycle = nil
-- (playtest 11-11) the Air Tank Racks an airlock's chamber can fill from or
-- pump back into: the racks (on, with the base's power: their valves) in the
-- network of room `rid`
local function racks_of(sid, s, rid)
  if not rid then return {} end
  local _, byRoom = nets(sid, s)
  local n = byRoom and byRoom[rid]
  local out = {}
  for _, L in ipairs(s.life) do
    if L.life.store and L.rid and not L.off and byRoom and n and byRoom[L.rid] == n then out[#out + 1] = L end
  end
  return out
end
-- take up to `amt` atm·m³ of the racks' air → taken
function rack_take(sid, s, rid, amt)
  if not (amt and amt > EPS) then return 0 end
  local got = 0
  for _, L in ipairs(racks_of(sid, s, rid)) do
    local q = s.tanks[L.uid] or 0
    local k = math.min(q, amt - got)
    if k > 0 then s.tanks[L.uid] = q - k; got = got + k end
    if got >= amt - EPS then break end
  end
  return got
end
-- put `amt` atm·m³ of air A's gas into the racks while they have room → put
function rack_put(sid, s, rid, A, amt)
  if not (amt and amt > EPS) then return 0 end
  local put = 0
  for _, L in ipairs(racks_of(sid, s, rid)) do
    local q = s.tanks[L.uid] or 0
    local k = math.min(math.max(0, L.life.store - q), amt - put)
    if k > 0 then s.tanks[L.uid] = q + k; put = put + k end
    if put >= amt - EPS then break end
  end
  if put > 0 then move_air(A, nil, put) end
  return put
end
function cycleStep(sid, s, C, target, pT, dt)
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
  local pc, Vc = ch_p(s, C)
  local recs = receivers_of(s, C, inner)
  if pc > pT then
    C.dir = "down"
    local floor_ = math.max(pT, P_RESID)
    local cap, have = 0, 0
    for _, L in ipairs(recs) do
      local q = s.recv[L.uid]
      cap = cap + L.life.receiver
      have = have + (q.N + q.x + q.c)
    end
    local sink, mode = nil, nil
    if not s.pow then mode = "vent_power"
    elseif #recs > 0 then mode = (have < cap - 1e-6) and "receiver" or "vent_full"
    elseif inner then mode = "hab"; sink = s.air[inner]
    else mode = "vent_none" end
    C.pumping = (mode == "receiver" or mode == "hab") and pc > floor_ + 1e-6
    if C.pumping then
      -- the exponential pump-down, to the floor at most
      local n0 = A.N + A.x + A.c
      local n1 = math.max(floor_ * Vc, n0 * math.exp(-PUMP_S * dt / Vc))
      local amt = n0 - n1
      if mode == "receiver" then
        amt = math.min(amt, cap - have)
        -- into the receivers, by their room left
        local tot = A.N + A.x + A.c
        local f = (tot > EPS) and amt / tot or 0
        local mN, mx, mc = A.N * f, A.x * f, A.c * f
        A.N, A.x, A.c = A.N - mN, A.x - mx, A.c - mc
        local room = 0
        for _, L in ipairs(recs) do local q = s.recv[L.uid]; room = room + math.max(0, L.life.receiver - (q.N + q.x + q.c)) end
        for _, L in ipairs(recs) do
          local q = s.recv[L.uid]
          local k = (room > 0) and math.max(0, L.life.receiver - (q.N + q.x + q.c)) / room or 0
          q.N, q.x, q.c = q.N + mN * k, q.x + mx * k, q.c + mc * k
        end
        C.saved = (C.saved or 0) + amt
        cyc_say(C, "airlock: pumping the chamber's air into its receiver")
      else
        -- (playtest 11-11: a lock cycles in seconds now, so its air goes back
        -- into the hab's Air Tank Racks while they have room, as a station's
        -- does: a 9 m³ chamber dumped into an 18 m³ hab put it at 1.5 atm)
        local into = rack_put(sid, s, inner, A, amt)
        if amt - into > EPS then move_air(A, sink, amt - into) end
        C.saved = (C.saved or 0) + amt
        cyc_say(C, into > 0.5 * amt and "airlock: pumping the chamber's air back into the racks" or "airlock: pumping the chamber's air back into the hab")
      end
    else
      -- the vent valve: what's left (under the pump's floor), or all of it
      local why = (mode == "vent_power" and "airlock: NO POWER for its pump: venting the chamber, its air is lost")
                  or (mode == "vent_full" and "airlock: the receiver is FULL: venting the rest of the chamber")
                  or (mode == "vent_none" and "airlock: nowhere to pump its air: venting the chamber")
                  or "airlock: venting the last of the chamber"
      local before = A.N + A.x + A.c
      equalise(A, Vc, nil, nil, VENT_C, dt, pT, 0)
      C.vented = (C.vented or 0) + math.max(0, before - (A.N + A.x + A.c))
      cyc_say(C, why)
    end
  else
    -- (scn_dust) THE PURGE: coming in, the chamber is full of the outside's
    -- gas. Pressurised as it is, it would be pumped into the hab with the
    -- door (on a CO2 world one entry poisons a room no scrubber can save).
    -- A real lock pumps it overboard first: while the chamber's gas is
    -- foreign (CO2 over PURGE_CO2 of it, or O2 under PURGE_O2) and the far
    -- side is a sealed room, the pump draws it down to P_PURGE and dumps it
    -- outside (powered; without power it pressurises as it is, and says so)
    local tot = A.N + A.x + A.c
    local foreign = tot > EPS and ((A.c / tot) > PURGE_CO2 or (A.x / tot) < PURGE_O2)
    -- (playtest 11-13, Dust Season: the airlock hung at CYCLING 0.01 atm. The
    -- hab it fills from held 3 % CO2 (scrubbers behind), so the refill itself
    -- read as foreign and was purged again, forever. A cycle purges ONCE: down
    -- to P_PURGE, then it pressurises with whatever the room ahead holds)
    if foreign and not C.purged and pc <= P_PURGE + 1e-6 then C.purged = true end
    if foreign and not C.purged and tr and tr.sealed and pc > P_PURGE + 1e-6 and s.pow then
      C.dir = "down"
      C.pumping = true
      C.purging = true
      local n1 = math.max(P_PURGE * Vc, tot * math.exp(-PURGE_S * dt / Vc))
      local f = (tot > EPS) and (n1 / tot) or 0
      C.vented = (C.vented or 0) + (tot - n1)
      A.N, A.x, A.c = A.N * f, A.x * f, A.c * f
      cyc_say(C, "airlock: purging the outside's gas overboard")
      return
    end
    if foreign and tr and tr.sealed and not s.pow then cyc_say(C, "airlock: NO POWER to purge: pressurising with the outside's gas in it") end
    C.dir = "up"
    C.pumping = false
    -- the receivers first (their valve), then the room ahead or the hab
    local need = (pT - pc) * Vc
    for _, L in ipairs(recs) do
      local q = s.recv[L.uid]
      local Vr = L.life.receiver / 20      -- (its volume: the store at 20 bar)
      local before = A.N + A.x + A.c
      -- (its return valve is a check: the receiver only gives)
      if (q.N + q.x + q.c) / Vr > (A.N + A.x + A.c) / Vc then equalise(q, Vr, A, Vc, REC_C, dt) end
      local got = (A.N + A.x + A.c) - before
      -- (never past the far side's pressure)
      local over = (A.N + A.x + A.c) - pT * Vc
      if over > 0 then move_air(A, q, over) end
      C.back = (C.back or 0) + math.max(0, got - math.max(0, over))
    end
    pc = ch_p(s, C)
    -- (playtest 11-11) then the hab's Air Tank Racks through the chamber's
    -- fill valve: a lock that fills in seconds would otherwise take a third
    -- of a small hab's air at once (18 m³ at 1 atm to 0.67: under the 0.16
    -- atm of O2 a crew breathes) faster than its regulator makes it up
    local racked = false
    if pc < pT - 0.04 then
      local want = (pT * Vc - (A.N + A.x + A.c)) * (1 - math.exp(-CYC_C * dt / Vc))
      local got = rack_take(sid, s, (tr and tr.sealed and tside) or inner, want)
      if got > 0 then
        A.N, A.x = A.N + got * (1 - O2N), A.x + got * O2N
        C.racked = (C.racked or 0) + got
        racked = got >= want - 1e-9
      end
      pc = ch_p(s, C)
    end
    -- (the room's own air only for what the racks could not give)
    if pc < pT - 0.04 and not racked then
      local src = (tr and tr.sealed and s.air[tside]) or (inner and s.air[inner]) or nil
      local sV = src and ((tr and tr.sealed and s.air[tside] == src) and tr.m3 or (inner and s.R.byId[inner].m3)) or nil
      if src and sV then
        equalise(src, sV, A, Vc, CYC_C, dt)
      end
    end
    cyc_say(C, #recs > 0 and "airlock: pressurising from its receiver" or "airlock: pressurising")
  end
end
-- (S7) the airlock pumps as grid loads: kW an Airlock Wall's pump draws now
function gridAux(sid, uid)
  local s = S[sid]
  -- (roompurge) an Air Tank Rack's purge pump while its room is purged
  if s and s.purge and next(s.purge) and s.R then
    local _, byRoom = nets(sid, s)
    for _, L in ipairs(s.life) do
      if L.uid == uid and L.life.store and L.rid and not L.off then
        local n = byRoom and byRoom[L.rid]
        return (n and n.purge and s.pow) and (L.life.purgeKW or RP_KW) or 0
      end
    end
  end
  if not (s and s.dch and s.dch[uid]) then return 0 end
  local C = s.cham[s.dch[uid]]
  local d = s.R.doors[uid]
  if C and C.pumping and d and d.airlock then return 2.5 end
  return 0
end

-- ── alarms ──────────────────────────────────────────────────────────────────
local function alarm_tick(sid, s)
  local pout = out_of(s, s.rec)
  -- (S7) a badly damaged seal under pressure FAILS: WARN_S s of warning, then it blows
  for uid, d in pairs(s.R.doors) do
    if not s.dch[uid] then
      local st = part_state(sid, uid)
      local dmg = st and tonumber(st.seal) or 0
      local dp = door_dp(s, uid) or 0
      if dmg >= FAIL_DMG and dp >= FAIL_DP and not (st and st.blown) and not door_open(sid, uid) then
        if not s.fail[uid] then
          s.fail[uid] = now() + WARN_S
          warnVent(sid, uid, string.format("the %s's seal is failing", d.label or "door"), WARN_S)
        elseif now() >= s.fail[uid] then
          s.fail[uid] = nil
          advance_struct(sid, s, agency_now())
          set_part_state(sid, uid, "seal", 1)
          set_part_state(sid, uid, "blown", true)
          ventBurst(sid, s, uid)
          s.netsDirty = true
          lastForce = { sid = sid, uid = uid, dp = dp, seal = 1, blown = true, t = now() }
        end
      elseif s.fail[uid] and dp < FAIL_DP then s.fail[uid] = nil end
    end
  end
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
        if bc and bc.show and near then bc.show("DEPRESSURISATION", string.format("Room %d (%.0f m³) is losing its air: %s.", r.id, r.m3, cause), 4.0, "alarm") end
        local fx = ref("sfx")
        if fx and fx.caption then fx.caption("DEPRESSURISATION: " .. cause) end
        if log then log(string.format("room_air: DEPRESSURISATION in structure %s room %d (%.1f m³): %s", tostring(sid), r.id, r.m3, cause)) end
      elseif al and not venting then
        for _, h in pairs(al.roar or {}) do snd_stop(h) end
        alarms_[k] = nil
        if a.p < 0.8 then s.pres[r.id] = false end
      end
      -- the air going bad in a sealed room with the crew in it: said once
      -- (an airlock's chamber is thin by design while it cycles)
      if r.sealed and not r.airlock and not a.venting and (s.crewIn[r.id] or 0) > 0 and not a.breathable and a.p >= P_MIN then
        if not s.badSaid then
          s.badSaid = true
          local bc = ref("big_caption")
          if bc and bc.show then bc.show("AIR", "Room " .. r.id .. ": " .. tostring(a.why) .. ".", 4.0, "alarm") end
          lastAlarm = { sid = sid, rid = r.id, cause = a.why, t = now(), kind = "air" }
        end
      elseif r.sealed and a.breathable and (s.crewIn[r.id] or 0) > 0 then s.badSaid = nil end
    end
  end
end

-- THE ALARM'S SOUND is plant_av's (a recorded klaxon at the room's door, the
-- structure's lights as beacons, a silence key); without it, the old one-shot.
-- THE BREACH (playtest 11-11: "the same for any depressurisation"): while a
-- room vents through a door open to the outside or a blown seal, near the
-- crew, the hole roars (a recorded compressor blow-off, louder with the
-- pressure behind it), grit, dust and flecks are drawn toward it from the
-- room, and frost and vapour jet out of it. Points are placed from the door's
-- side and this frame's body read when each puff is fired; the roar rides the
-- door's node.
BREACH_R = 30.0
BREACH_EVERY = 0.25
lastBreach = nil
local function breach_av(t, a)
  local ST = ref("structures")
  for k, al in pairs(alarms_) do
    local s = S[al.sid]
    al.roar = al.roar or {}
    local live = {}
    if s and s.R and valid(a) then
      local _, byRoom = nets(al.sid, s)
      local mine = byRoom and byRoom[al.rid]
      local x0, y0, z0 = ch_world(s, { rid = al.rid })
      local near = x0 and (x0 - a.x) ^ 2 + (y0 - a.y) ^ 2 + (z0 - a.z) ^ 2 < (BREACH_R + 10) ^ 2
      if near and mine then
        local n = 0
        for uid, d in pairs(s.R.doors) do
          local st = part_state(al.sid, uid)
          local open_out = (d.a == 0 or d.b == 0) and door_open(al.sid, uid)
          local inner = (d.a == 0) and d.b or d.a
          if (open_out or (st and st.blown)) and inner ~= 0 and byRoom[inner] == mine and n < 2 then
            n = n + 1
            live[uid] = true
            local p_in = side_pressure(s, inner)
            local dp = math.max(0, p_in - out_of(s, s.rec))
            local node = ST and ST.nodeOf and ST.nodeOf(al.sid, uid)
            if not al.roar[uid] and valid(node) and audio and audio.play then
              local ok, h = pcall(audio.play, "audio/plant/vent_roar.ogg", node, { loop = true, minDistance = 2, maxDistance = BREACH_R + 10, track = "SFX", volume = 0.3 + 0.7 * math.min(1, dp) })
              al.roar[uid] = ok and h or true
            elseif type(al.roar[uid]) ~= "boolean" and al.roar[uid] and al.roar[uid].setVolume then
              pcall(al.roar[uid].setVolume, al.roar[uid], 0.15 + 0.85 * math.min(1, dp))
            end
            if dp > 0.03 and t - (al.puff_t or -10) >= BREACH_EVERY then
              -- (drawn toward the hole from the room; frost out of it)
              local ix, iy, iz, inx, iny, inz = door_pt(s, uid, inner, 1.4, -0.5)
              if ix then
                -- (the effect's +Y is its normal: pointed at the hole)
                puff("BreachDraw", ix, iy, iz, -inx, -iny, -inz, 0.6 + 0.4 * math.min(1, dp), math.min(1, 0.3 + dp), true)
              end
              local ox, oy, oz, onx, ony, onz = door_pt(s, uid, 0, 0.3, 0.2)
              if ox then puff("LockVent", ox, oy, oz, onx, ony, onz, 0.8 + math.min(1, dp), math.min(1, 0.3 + dp)) end
              lastBreach = { sid = al.sid, rid = al.rid, uid = uid, dp = dp, t = t }
            end
          end
        end
        if n > 0 and t - (al.puff_t or -10) >= BREACH_EVERY then al.puff_t = t end
      end
    end
    for uid, h in pairs(al.roar) do if not live[uid] then snd_stop(h); al.roar[uid] = nil end end
  end
end
local function alarm_sound()
  local a = find and find("Astronaut")
  if not valid(a) then return end
  local t = now()
  breach_av(t, a)
  if ref("plant_av") then return end
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
-- (plant_av) the sealed rooms whose air has gone bad, that held good air: →
-- { { sid, rid, why } … } (an airlock's chamber is thin by design; a venting
-- room is the depressurisation alarm's)
function airAlarms()
  local out = {}
  for sid, s in pairs(S) do
    for _, r in ipairs(s.R and s.R.rooms or {}) do
      if r.sealed and not r.airlock and s.pres[r.id] then
        local q = airOf(sid, r.id)
        if q and not q.venting and not q.purging and not q.breathable and q.p >= P_MIN then out[#out + 1] = { sid = sid, rid = r.id, why = q.why } end
      end
    end
  end
  return out
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
  -- (S7) the water cells and the receivers
  local cells, recv = {}, {}
  for u, w in pairs(s.cells or {}) do cells[#cells + 1] = { u = u, w = w } end
  for u, q in pairs(s.recv or {}) do recv[#recv + 1] = { u = u, N = q.N, x = q.x, c = q.c } end
  local purge = nil
  for rid in pairs(s.purge or {}) do
    local r = s.R.byId[rid]
    if r then purge = purge or {}; purge[#purge + 1] = r.key end
  end
  save.set("air." .. tostring(sid), { a = s.a, rooms = rooms, tanks = tanks, cells = cells, recv = recv, purge = purge })
end
function saveNow() for sid, s in pairs(S) do if s.R then save_struct(sid, s) end end end
-- (scenarios) a start state already lived in: every sealed room of sid at
-- `p` atm (1) of normal air. → rooms filled | nil (the rooms not solved yet)
function pressurise(sid, p)
  local s = S[sid]
  if not (s and s.R) then return nil end
  p = p or 1.0
  local n = 0
  for _, r in ipairs(s.R.rooms) do
    if r.sealed and not r.leaky then
      local f = s.air[r.id] and s.air[r.id].f
      s.air[r.id] = { N = r.m3 * p * (1 - O2N), x = r.m3 * p * O2N, c = 0, f = f }
      n = n + 1
    end
  end
  s.netsDirty = true
  save_struct(sid, s)
  return n
end

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
        value = function() local q = airOf(sid, rid); return q and string.format("%.2f atm · O2 %.0f %% · CO2 %.1f %%%s", q.p, 100 * q.o2 / math.max(q.p, 1e-6), 100 * q.co2 / math.max(q.p, 1e-6), q.venting and " · VENTING" or (q.purging and " · PURGING" or "")) or "—" end }
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
        -- (roompurge) the purge: its plan worked out once, as the menu opens
        local pi, why0 = purgeInfo(sid, rid), purgeWhy(sid, rid)
        if pi then
          out[#out + 1] = { id = "ra_purge_i", type = "info", label = "Purge", group = "Life support",
            value = function()
              local q = airOf(sid, rid)
              if q and q.purging then
                return string.format("PUMPING DOWN %.2f atm → %.2f overboard · then the regulator refills it", q.p, RP_P)
              end
              return purgeLine(pi)
            end,
            warn = function() local q = airOf(sid, rid); return q ~= nil and (q.purging or (pi.foul and not q.breathable)) end }
          out[#out + 1] = { id = "ra_purge", type = "toggle", label = string.format("Purge Room %s", tostring(rid)), group = "Life support", keep = true,
            hint = pi.plan.pump and pi.plan.fill and fmtSecs(pi.plan.pump + pi.plan.fill) or nil,
            on = function() return purging(sid, rid) end,
            act = function(want) if want then return startPurge(sid, rid, "hand") end return stopPurge(sid, rid) end,
            enabled = function() return purging(sid, rid) or why0 == nil end,
            why = function() return why0 end }
        end
      elseif L.receiver then
        out[#out + 1] = { id = "ra_recv", type = "info", label = "Receiver", group = "Life support",
          value = function() local q = s.recv[uid] or { N = 0, x = 0, c = 0 }; local n = q.N + q.x + q.c
            return string.format("%.1f of %.0f atm·m³ (%.1f bar)", n, L.receiver, n / (L.receiver / 20)) end }
      else
        out[#out + 1] = { id = "ra_run", type = "toggle", label = "Running", group = "Life support", keep = true,
          on = function() return machineOn(sid, uid) end,
          act = function(want) return setMachine(sid, uid, want, "hand") end,
          enabled = function() return whyNot(sid, uid, not machineOn(sid, uid)) == nil end,
          why = function() return whyNot(sid, uid, not machineOn(sid, uid)) end }
        out[#out + 1] = { id = "ra_state", type = "info", label = L.o2 and "O2" or "Scrubber", group = "Life support",
          value = function()
            if not machineOn(sid, uid) then return "switched off" end
            return s.pow and "running on the base grid" or "NO POWER (it runs on the base grid)" end }
        if L.water then
          out[#out + 1] = { id = "ra_water", type = "info", label = "Water cell", group = "Life support",
            value = function() local w = s.cells[uid] or 0
              return string.format("%.1f of %.0f L%s", w, L.water, w <= 0.001 and " · DRY: no O2 (pipe water to its back)" or "") end }
        end
      end
    end
  end
  -- (S7) an Equalise Valve
  if d.eqv and s.eqv and s.eqv[uid] then
    local e = s.eqv[uid]
    out[#out + 1] = { id = "ra_eqv", type = "toggle", label = "Valve open", group = "Equalise valve", keep = true,
      on = function() return equaliseOpen(sid, uid) end, act = function(want) setEqualise(sid, uid, want) end }
    out[#out + 1] = { id = "ra_eqv_i", type = "info", label = "Across it", group = "Equalise valve",
      value = function()
        if e.a == e.b then return "the same room both sides: it does nothing here" end
        local pa, pb = side_pressure(s, e.a), side_pressure(s, e.b)
        local eta = equaliseEta(sid, uid)
        return string.format("%s %.2f atm · %s %.2f atm%s", e.a == 0 and "outside" or ("Room " .. e.a), pa, e.b == 0 and "outside" or ("Room " .. e.b), pb,
          (eta and eta > 0) and string.format(" · within 0.1 atm in ~%.0f s open", eta) or "")
      end }
  end
  if s.R and s.R.doors[uid] and not s.dch[uid] then
    local dp, pa, pb = door_dp(s, uid)
    local d = s.R.doors[uid]
    local cl = ref("crew")
    local a = ctx and ctx.actor
    if (dp and dp > HOLD_DP and not s.forced[uid]) or equaliseOpen(sid, uid) then
      local hi = (pa >= pb) and d.a or d.b
      out[#out + 1] = { id = "ra_held", type = "info", label = "Door", group = "Fitting",
        value = function() local q, a1, b1 = door_dp(s, uid); return string.format("held shut: %.2f atm against %.2f", math.max(a1 or 0, b1 or 0), math.min(a1 or 0, b1 or 0)) end }
      -- (S7) the safe way: its equalising valve, slow
      out[#out + 1] = { id = "ra_eq", type = "toggle", label = "Equalising valve", group = "Fitting", keep = true,
        hint = function() local eta = equaliseEta(sid, uid); return (eta and eta > 0) and string.format("~%.0f s", eta) or nil end,
        on = function() return equaliseOpen(sid, uid) end, act = function(want) setEqualise(sid, uid, want) end }
      -- the fast way: force it, with a warning to the room it vents, the gust and a damaged seal
      if dp and dp > HOLD_DP and not s.forced[uid] then
        local secs = forceSecs(sid, uid)
        local warned = false
        out[#out + 1] = { id = "ra_force", type = "action", group = "Fitting",
          label = hi == 0 and "Force it open (the outside comes in)" or string.format("Force it open (vents Room %d)", hi),
          hint = string.format("%.0f s · damages the seal", secs),
          act = function() return true end,
          job = { secs = secs, label = string.format("Forcing the door against %.2f atm", dp),
            tick = function(_, f)
              if not warned then warned = true; warnVent(sid, uid, string.format("the %s is being forced", d.label or "door"), secs) end
              if audio and audio.play and math.random() < 0.05 then pcall(audio.play, "audio/foley/latch_clunk.ogg", { track = "SFX", volume = 0.3 }) end
            end,
            check = function() local q = door_dp(s, uid); return q ~= nil and not door_open(sid, uid), "the door moved" end,
            done = function() forceDoor(sid, uid); return true end } }
      end
    end
    -- (S7) the seal: damaged by forcing, it leaks until it is re-seated
    local dmg = sealOf(sid, uid)
    if dmg > 0 then
      local st = part_state(sid, uid)
      out[#out + 1] = { id = "ra_seal", type = "info", label = "Seal", group = "Fitting",
        value = function() return (st and st.blown) and "BLOWN: it vents like an open door" or string.format("damaged %.0f %% · leaks %.3f m³/s per atm", 100 * sealOf(sid, uid), SEAL_C * sealOf(sid, uid)) end }
      local function secs()
        local k = 1
        if a and a.id and cl then
          if cl.hasRole and cl.hasRole(a.id, "engineer") then k = 0.5 end
          if cl.perk then k = k * (tonumber(cl.perk(a.id, "repair_time")) or 1) end
        end
        return REPAIR_S * k
      end
      out[#out + 1] = { id = "ra_repair", type = "action", group = "Fitting", label = "Re-seat the seal",
        hint = string.format("%.0f s%s", secs(), (a and a.id and cl and cl.hasRole and cl.hasRole(a.id, "engineer")) and " (Engineer)" or ""),
        act = function() return true end,
        job = { secs = secs(), label = "Re-seating the door's seal", check = function() return not door_open(sid, uid), "the door is open" end,
          done = function() repairSeal(sid, uid); return true end } }
    end
  end
  if s.dch[uid] then
    local C = s.cham[s.dch[uid]]
    out[#out + 1] = { id = "ra_lock", type = "info", label = "Airlock", group = "Fitting",
      value = function()
        local o = airlockStatus(sid, uid)
        if not o then return "—" end
        return string.format("%s · chamber %.2f atm · beyond %.2f atm", o.label, o.pc, o.pT)
      end,
      warn = function() local o = airlockStatus(sid, uid); return o ~= nil and o.col == "stop" end }
    -- (playtest 11-11: it works from either side and from inside: the panel's
    -- key cycles the chamber to this door and holds it there a while)
    out[#out + 1] = { id = "ra_cycle", type = "action", label = "Cycle to this door", group = "Fitting",
      hint = function() local o = airlockStatus(sid, uid); return o and o.label or nil end,
      act = function() return cycleTo(sid, uid) end }
    -- the manual override: allowed, with what it does said
    if not s.forced[uid] then
      out[#out + 1] = { id = "ra_override", type = "action", group = "Fitting",
        label = function()
          local o = airlockStatus(sid, uid)
          if o and math.abs(o.pc - o.pT) > 0.04 then return string.format("Override: open now (%.2f atm against %.2f)", o.pc, o.pT) end
          return "Override: open now"
        end,
        act = function() return overrideDoor(sid, uid) end }
    end
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
  -- (a forced door, shut again, holds again; its equalising valve shuts with it)
  if s.forced[uid] and not door_open(sid, uid) then s.forced[uid] = nil end
  if not door_open(sid, uid) then
    local st = part_state(sid, uid)
    if st and st.eq then set_part_state(sid, uid, "eq", nil) end
    -- (a blown seal leaves the door shut but leaking: S7)
  end
end

-- ── (S7) PRESSURE MECHANICS: equalise, force, seals ─────────────────────────
-- The world point and the gust's direction of door uid: x, y, z, the flow's
-- direction (from the high side), the high side's room, dp
local function door_world(s, uid)
  local KS = ref("kit_snap")
  local ds = s.dside and s.dside[uid]
  local b = space and space.body and space.body(s.rec.b)
  if not (KS and ds and b) then return nil end
  local fr = KS.frameOf(s.rec)
  local function W(x, y, z) return b.x + fr.O.x + fr.R.x * x + fr.U.x * y + fr.F.x * z, b.y + fr.O.y + fr.R.y * x + fr.U.y * y + fr.F.y * z,
                                   b.z + fr.O.z + fr.R.z * x + fr.U.z * y + fr.F.z * z end
  local function Wd(x, y, z) return fr.R.x * x + fr.U.x * y + fr.F.x * z, fr.R.y * x + fr.U.y * y + fr.F.y * z, fr.R.z * x + fr.U.z * y + fr.F.z * z end
  local d = s.R.doors[uid]
  local back = (d.a == ds.front) and d.b or d.a
  local pf, pb = side_pressure(s, ds.front), side_pressure(s, back)
  local sgn = (pf >= pb) and -1 or 1          -- the gust leaves the high side
  local x, y, z = W(ds.x, ds.y, ds.z)
  local dx, dy, dz = Wd(ds.nx * sgn, ds.ny * sgn, ds.nz * sgn)
  return x, y, z, dx, dy, dz, (pf >= pb) and ds.front or back, math.abs(pf - pb)
end
-- The gust: dust, grit and a burst of air through the doorway (vfx, carried by
-- the planet), its roar, and every crew member on foot within 8 m pulled
-- toward the opening (a gentle shove: 2.5 m/s per atm across it, 0.8 s).
lastBurst = nil
function ventBurst(sid, s, uid)
  local x, y, z, dx, dy, dz, hi, dp = door_world(s, uid)
  if not x or dp < 0.05 then return end
  local V = ref("vfx")
  local scale = 0.5 + math.min(1.5, dp)
  if V and V.emit then pcall(V.emit, "VentBurst", x, y, z, { normal = vec3(dx, dy, dz), scale = scale, intensity = math.min(1, dp) })
  elseif spawnEffect then pcall(spawnEffect, "VentBurst", vec3(x, y, z), { normal = vec3(dx, dy, dz), scale = scale }) end
  -- A room's air going at once through a seal that failed or a door forced
  -- against it is a hull breach (sfx: a plate bursting under a blast of air),
  -- not a pneumatic cylinder; a small difference stays a hiss and a clunk.
  local fx = ref("sfx")
  if fx and fx.fail and dp >= 0.3 then
    pcall(fx.fail, "hull_breach", { x = x, y = y, z = z, vol = math.min(1, 0.55 + 0.45 * dp) })
  elseif audio and audio.play then
    pcall(audio.play, "audio/foley/hiss_cylinder.ogg", x, y, z, { maxDistance = 40, track = "SFX", volume = math.min(1, 0.5 + dp) })
    pcall(audio.play, "audio/foley/latch_clunk.ogg", x, y, z, { maxDistance = 25, track = "SFX", volume = 0.7 })
  end
  local a = find and find("Astronaut")
  local pw = ref("planet_walker")
  local pulled = nil
  if valid(a) and pw and pw.pull and pw.onFoot ~= false then
    local ax, ay, az = a.x - x, a.y - y, a.z - z
    local dist = math.sqrt(ax * ax + ay * ay + az * az)
    if dist < 8 then
      -- (on the high side: toward the door; past it: along the gust)
      local side = ax * dx + ay * dy + az * dz
      local vx, vy, vz
      if side < 0 then vx, vy, vz = -ax / math.max(dist, 0.3), -ay / math.max(dist, 0.3), -az / math.max(dist, 0.3) else vx, vy, vz = dx, dy, dz end
      local k = 2.5 * math.min(1.2, dp) * (1 - dist / 8)
      pcall(pw.pull, vx * k, vy * k, vz * k, 0.8)
      pulled = k
    end
  end
  lastBurst = { sid = sid, uid = uid, dp = dp, x = x, y = y, z = z, dx = dx, dy = dy, dz = dz, pull = pulled, t = now() }
end
-- Warn the crew in the rooms about to vent (a forced or failing door): WARN_S
-- before it opens, the caption and the alarm, once.
lastWarning = nil
function warnVent(sid, uid, why, secs)
  local s = S[sid]
  if not s then return end
  local _, _, _, _, _, _, hi = door_world(s, uid)
  local d = s.R.doors[uid]
  hi = hi or (d and (side_pressure(s, d.a) >= side_pressure(s, d.b) and d.a or d.b))
  lastWarning = { sid = sid, uid = uid, rid = hi, why = why, t = now(), secs = secs }
  local _, byRoom = nets(sid, s)
  local inRoom = crew.sid == sid and hi and byRoom and byRoom[hi] and byRoom[crew.rid or -1] == byRoom[hi]
  if inRoom then
    local bc = ref("big_caption")
    if bc and bc.show then bc.show("VENTING IN " .. math.floor((secs or WARN_S) + 0.5) .. " s", string.format("Room %d: %s. Helmets on.", hi, why), math.min(4.5, secs or WARN_S), "alarm") end
    lastWarning.crew = true
  end
  local x, y, z = door_world(s, uid)
  -- (the warning sounds as an alarm at the door: plant_av's klaxon and beacons, till it vents)
  local PA = ref("plant_av")
  if PA and PA.raise then
    pcall(PA.raise, "vent:" .. tostring(sid) .. ":" .. tostring(uid), { sid = sid, kind = "depress", level = 2, uid = uid,
      text = string.format("VENTING IN %d s: %s", math.floor((secs or WARN_S) + 0.5), tostring(why)) })
  elseif x and audio and audio.play then pcall(audio.play, "audio/sfx/crew_alarm.ogg", x, y, z, { maxDistance = 45, track = "SFX", volume = 0.6 }) end
end
-- Force door uid open now (the menu's job, when it is through): it opens and
-- the rooms vent, the gust and the pull, and its seal is damaged by the
-- pressure across it (a stronger seal less). → true, the seal's damage
lastForce = nil
local rng_state = 12345
local function rng() rng_state = (rng_state * 1103515245 + 12345) % 2147483648; return rng_state / 2147483648 end
function seedRandom(n) rng_state = n end
function forceDoor(sid, uid)
  local s = S[sid]
  if not (s and s.R and s.R.doors[uid]) then return false end
  advance_struct(sid, s, agency_now())
  local dp = door_dp(s, uid) or 0
  local ds = s.dside and s.dside[uid]
  local k = ds and ds.def and ds.def.door and ds.def.door.seal or 0
  local dmg = sealOf(sid, uid)
  if dp > HOLD_DP then
    -- (a door forced once against 1 atm leaks; forced again, it fails)
    dmg = math.min(1, dmg + dp * (1 - k) * (0.25 + 0.3 * rng()))
    set_part_state(sid, uid, "seal", dmg)
  end
  s.forced[uid] = true
  ventBurst(sid, s, uid)
  s.netsDirty = true
  lastForce = { sid = sid, uid = uid, dp = dp, seal = dmg, t = now() }
  if log then log(string.format("room_air: forced door %s of structure %s against %.2f atm · seal %.0f %%", tostring(uid), tostring(sid), dp, dmg * 100)) end
  local BL = ref("base_log")
  if BL and BL.add then pcall(BL.add, sid, "forced", string.format("%s FORCED against %.2f atm · seal %.0f %%", tostring(called(sid, uid)):gsub("^the ", ""), dp, dmg * 100)) end
  return true, dmg
end
-- How long forcing door uid takes now (s): longer the more pressure it holds
function forceSecs(sid, uid)
  local s = S[sid]
  local dp = s and door_dp(s, uid) or 0
  return math.max(WARN_S, FORCE_S + FORCE_K * (dp or 0))
end
-- Open (or shut) a door's own equalising valve, or an Equalise Valve piece
function setEqualise(sid, uid, open)
  local s = S[sid]
  if not s then return false end
  advance_struct(sid, s, agency_now())
  if s.eqv and s.eqv[uid] then set_part_state(sid, uid, "open", open and true or nil)
  else set_part_state(sid, uid, "eq", open and true or nil) end
  s.netsDirty = true
  if audio and audio.play then pcall(audio.play, open and "audio/foley/hiss_cylinder.ogg" or "audio/foley/latch_clunk.ogg", { track = "SFX", volume = 0.35 }) end
  return true
end
function equaliseOpen(sid, uid)
  local st = part_state(sid, uid)
  return st ~= nil and (st.eq == true or st.open == true)
end
-- The time a door's valve (or a valve piece) takes to bring its two sides
-- within HOLD_DP of each other from now: → s | 0 | nil
function equaliseEta(sid, uid)
  local s = S[sid]
  if not (s and s.R) then return nil end
  local a, b, C
  if s.eqv and s.eqv[uid] then a, b, C = s.eqv[uid].a, s.eqv[uid].b, s.eqv[uid].C
  else
    local d = s.R.doors[uid]
    if not d then return nil end
    local ds = s.dside and s.dside[uid]
    a, b, C = d.a, d.b, (ds and ds.def and ds.def.door and ds.def.door.eq) or EQ_DOOR
  end
  local _, byRoom = nets(sid, s)
  local function V_of(id)
    if id == 0 then return nil end
    local r = s.R.byId[id]
    if r and r.leaky then return nil end
    local n = byRoom[id]
    return n and n.V or (r and r.m3)
  end
  local dp = math.abs(side_pressure(s, a) - side_pressure(s, b))
  local Va, Vb = V_of(a), V_of(b)
  if not Va then Va, Vb = Vb, nil end
  if not Va then return nil end
  return equaliseTime(Va, Vb, C, dp, HOLD_DP)
end
-- Re-seat a damaged seal (the menu's job)
function repairSeal(sid, uid)
  local s = S[sid]
  if s then advance_struct(sid, s, agency_now()); s.netsDirty = true; s.forced[uid] = nil; s.fail[uid] = nil end
  set_part_state(sid, uid, "seal", nil)
  set_part_state(sid, uid, "blown", nil)
  return true
end
-- (fluid_net) the gas a room's outlets bring, kg/s: { o2, n2 }
function setInject(sid, rid, o2, n2)
  local s = S[sid]
  if not s then return end
  local cur = s.inject[rid]
  if (cur and math.abs((cur.o2 or 0) - (o2 or 0)) < 1e-12 and math.abs((cur.n2 or 0) - (n2 or 0)) < 1e-12) or (not cur and (o2 or 0) == 0 and (n2 or 0) == 0) then return end
  advance_struct(sid, s, agency_now())
  s.inject[rid] = ((o2 or 0) > 0 or (n2 or 0) > 0) and { o2 = o2, n2 = n2 } or nil
  s.netsDirty = true
end
-- (fluid_net) a generator's water cell: → kg, capacity; and the fluid
-- network topping it up (kg added); the hydrogen it made since asked
function cellOf(sid, uid)
  local s = S[sid]
  if not (s and s.cells[uid] ~= nil) then return nil end
  for _, L in ipairs(s.life) do if L.uid == uid then return s.cells[uid], L.life.water end end
  return s.cells[uid], 20
end
function fillCell(sid, uid, kg)
  local s = S[sid]
  if not (s and s.cells[uid] ~= nil) then return 0 end
  advance_struct(sid, s, agency_now())
  local w, cap = cellOf(sid, uid)
  local put = math.max(0, math.min(kg, cap - w))
  s.cells[uid] = w + put
  return put
end
function takeH2(sid, uid)
  local s = S[sid]
  if not s then return 0 end
  local h = s.h2[uid] or 0
  s.h2[uid] = 0
  return h
end
-- what a generator has made (atm·m³ of O2) and the water it draws now (kg/s)
function genDraw(sid, uid)
  local s = S[sid]
  if not s then return 0 end
  local _, byRoom = nets(sid, s)
  for _, L in ipairs(s.life) do
    if L.uid == uid and L.rid then
      local n = byRoom[L.rid]
      local A = s.air[L.rid]
      if not (n and A and s.pow and (s.cells[uid] or 0) > 0) or L.off then return 0 end
      local r = s.R.byId[L.rid]
      local x = A.x * n.V / math.max(r.m3, 1e-9)
      local xs = O2N * n.V
      local g = (x < xs) and n.G or math.min(n.G, n.crew * USE)
      local share = (n.G > 0) and L.life.o2 / n.G or 0
      return g * share * KW
    end
  end
  return 0
end

-- Drawn over the world: after the camera has placed this frame's view
-- (planet_camera.deferLate; docs/positions-and-frames.md rule 2)
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
local function late_overlay() if overlay_on() then drawOverlay() end end
function lateUpdate(node, dt)
  after_camera(node, dt, late_overlay)
end
