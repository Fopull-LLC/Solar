-- CRAFT_CHECK — the Vehicle Assembly's craft check: what the flight will do
-- with the craft on the stand, read off the flight's own rules
-- (/mnt/disks/3tb/.floptle-shared/solar/work/vabcheck/PLAN.md; docs/builder-design.md §7.2).
--
-- A pure library (no update): it rides the CraftCheckLib node the builder
-- spawns, and loads under luajit with nothing of the engine around it. It
-- never reads the builder's parts itself: builder.launchCheck() hands it a
-- context (checkContext) and gets back rows.
--
-- THE RULE OF THIS FILE: a warning is a number the flight will produce, read
-- off the same function the flight reads it from (aero.step, aero.staticMargin,
-- auto_drive.gasWheel, craft_mode.autoOf …) or off the flight's own constant
-- (FLIGHT below, each checked against vessel_controller.lua by
-- tests/smoke_craft_check.lua). A rule that can't be computed that way is a
-- NOTE, never a warning, and an estimate says "about".
--
-- run(ctx) → { rows = { row… }, kind, site, ms }
--   row = { id, sev = "block"|"warn"|"note", rank = 0|1|2, kind,
--           head (≤ 60 chars), text (the sentence with the numbers),
--           uids = { … } (the parts to outline and select),
--           fix = { label, cmd, args } | { label, hold } | nil }
--   rank 0: it won't do what it is for (won't lift, won't light, breaks)
--   rank 1: it flies but fights you (tips, ground-loops, rolls over)
--   rank 2: advice with a number
--
-- ctx (builder.checkContext):
--   parts     uid → { uid, id, def (the save's liveDef), x,y,z, yaw,pitch,roll,
--                     parent, att, sym, size, cfg (wheel settings, filled) }
--   world     launchWorld() { name, g, r }   worldRec  save "world.<name>" or nil
--   sigma     padAir()   site  "pad"|"runway"   fuel_t  FUEL_T_PER_UNIT   rk  rating().thrust
--   stages    stageStats()   stageIdx  uid → stage n (0 = lit at launch)
--   drops     function(uid) → set of what firing that decoupler throws off
--   fairings  uid → fairingFit(uid)
--   power     function() → powerStats() (electronics.summary; asked only for a probe)
--   rec       function(uid) → the part's electronics record { mods } (wheels, mounts)
--   mode      ctrlMode() { set, auto, why, mode }
--   front     { x, z }  the craft's front (builder craftFront)
--   crew      uid → t of crew seated there (the rider counts)
--   def       function(id) → a registry entry (for the parts a fix suggests)
--   gasEngines function() → { { id, label, mod } … } the catalogue's gas engines
--   chains    wheel uid → { e = engine uid, teeth }
--   libs      { aero, craft_mode, auto_drive, electronics }
--   flight    vessel_controller's handle when one is running (else nil)
--   hooks     name → fn(ctx, out, k): rules added by builder.checkHook. The
--             builder registers phase 4's (heatRules, crewRules) with:
--   thermal   function() → builder.thermalBudget() (thermal.lua's settle and
--             doseRate at full output, every radiator out, full sun) or nil
--   rods      function() → fuel rods in the base store (math.huge: sandbox)
--   seated    function() → { { id, uid, role, name, level } … } the CREW plan

-- ── THE FLIGHT'S CONSTANTS ──────────────────────────────────────────────────
-- Read through flight(name): the running vessel_controller's own global when
-- there is one, else these, which tests/smoke_craft_check.lua holds equal to
-- vessel_controller.lua (and base_facilities.lua) line by line — a tuning
-- there fails the test until it is mirrored here.
FLIGHT = {
  R2_TYRE_MU = 0.9,          -- the tyre's friction (× the wheel's Grip)
  R2_GRIP_K = 1.0,           -- a bike's push cap: of the driven tyre's grip × load
  R2_LAT_MU = 0.47,          -- r2Lateral: the turn's share of the grip …
  R2_LAT_SSF = 0.45,         -- … and of the rollover threshold
  R2_WHEEL_TORQUE = { S = 0.35, M = 0.9, L = 2.0 },   -- r2FullTorque's floors (× rating)
  R2_WHEEL_TOP = { S = 14.0, M = 22.0, L = 28.0 },    -- r2TopSpeed's floors
  R2_BIKE_TORQUE = 0.8,      -- R2_BIKE.torque: a bike's driven wheel (× rating)
  R2_BIKE_TOP = 18.0,        -- R2_BIKE.top
  R2_BIKE_LEAN = 0.12,       -- R2_BIKE.lean: the rider's weight forward under power (m of the bike's)
  R2_BIKE_LEANMAX = 0.6,     -- R2_BIKE.leanMax: how far forward the rider's own weight goes up a climb (m)
  R2_LIFT_MAX = 0.97,        -- the most of the front's lift a bike's push uses on a steep climb
  R2_G_REF = 9.8,
  CREW_T = 0.100,            -- a seated crew member (t), crewSeatT with an empty pack
  CHUTE_K = 1.3,             -- the canopy drag: 1.3 · #chutes (parachute drag block)
  CHUTE_SAFE_KPA = 6.5,      -- a canopy opened past this tears
  TOLERANCE = { crewed = 9, tank = 3.5, engine = 7.0, structural = 6, canvas = 2.5, probe = 12 },
  TOL_WHEEL = 20, TOL_FRONT = 20, TOL_LEGS = 9, TOL_LEGS_UP = 3, TOL_OTHER = 5,   -- part_tolerance
  DAMAGE_FLOOR = 0.35,       -- damage starts at this share of the tolerance
  NOSE_UP = 0.7,             -- R2.noseUp: |nose.y| over this (aircraft or cockpit)
  FRAME_TILT = 0.866,        -- aeroScan: a command part flies nose-first under this +Y
  TYRE_W = { S = 0.18, M = 0.26, L = 0.38 },          -- the tyre's width by size (wheel setup)
  RUNWAY_LEN = 262.0,        -- base_facilities RUNWAY: u1 − u0
  ROD_SECS = 8.0,            -- vessel_thermal: an EVA fuel-rod swap (an Engineer's takes half)
}
local FLIGHT_GLOBAL = { R2_BIKE_TORQUE = { "R2_BIKE", "torque" }, R2_BIKE_TOP = { "R2_BIKE", "top" },
  R2_BIKE_LEAN = { "R2_BIKE", "lean" }, R2_BIKE_LEANMAX = { "R2_BIKE", "leanMax" } }
local CTX = nil
function flight(name)
  local vc = CTX and CTX.flight
  if vc then
    local path = FLIGHT_GLOBAL[name]
    local v
    if path then
      local t = vc[path[1]]
      v = type(t) == "table" and t[path[2]] or nil
    else
      v = vc[name]
    end
    if v ~= nil and type(v) == type(FLIGHT[name]) then return v end
  end
  return FLIGHT[name]
end

-- The flight's section rule (vessel_controller feedSec): the axial cut a
-- height stands over. Kept identical; the smoke test compares the two.
function feedSec(y, cuts)
  local s = 0
  for i = 1, #cuts do if y >= cuts[i] - 0.01 then s = i end end
  return s
end

-- The flight's turn cap (vessel_controller r2Lateral), same arguments.
function lateral(g, plan, mu)
  g = g or flight("R2_G_REF")
  local grip = flight("R2_LAT_MU") * (mu or 1)
  local ssf = 1.0
  if plan and (plan.hcg or 0) > 0.05 and (plan.track or 0) > 0.05 then ssf = 0.5 * plan.track / plan.hcg end
  return g * math.max(0.15, math.min(grip, flight("R2_LAT_SSF") * ssf))
end

-- How fast a craft of m tonnes comes down under n full canopies on gravity g
-- at the ground (the flight's canopy drag, K · n · v² · air, the air's band
-- density 1 at the surface): the speed where the drag holds the weight.
function chuteSpeed(m, g, n)
  return math.sqrt(math.max(0, m) * g / (flight("CHUTE_K") * math.max(n, 1e-9)))
end

-- A part's crash tolerance as the flight rates it at full health
-- (vessel_controller part_tolerance; legs deployed).
function tolerance(d)
  if (d.wheel or "") ~= "" then return flight("TOL_WHEEL") end
  if d.front == true or d.front == 1 then return flight("TOL_FRONT") end
  if d.legs then return flight("TOL_LEGS") end
  return flight("TOLERANCE")[d.kind or "structural"] or flight("TOL_OTHER")
end

-- ── small helpers ───────────────────────────────────────────────────────────
local sqrt, abs, max, min, deg, rad = math.sqrt, math.abs, math.max, math.min, math.deg, math.rad
local fmt = string.format
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function s_(n) return n == 1 and "" or "s" end
local function label(p) return (p and p.def and (p.def.label or p.id)) or "part" end
local function Cap(t) return (t:gsub("^%l", string.upper)) end
local function N(x) return (abs(x - math.floor(x + 0.5)) < 1e-9) and fmt("%d", math.floor(x + 0.5)) or fmt("%.1f", x) end

-- "the Wasp Turbojet", "the 2 Wasp Turbojets", "the Ram Intake and 2 more"
function nameOf(ctx, uids)
  local by, order = {}, {}
  for _, u in ipairs(uids or {}) do
    local l = label(ctx.parts[u])
    if not by[l] then by[l] = 0; order[#order + 1] = l end
    by[l] = by[l] + 1
  end
  if #order == 0 then return "the craft" end
  local first = order[1]
  local n = by[first]
  local s = n == 1 and ("the " .. first) or fmt("the %d %ss", n, first)
  local rest = #(uids or {}) - n
  if rest > 0 then s = s .. fmt(" and %d more", rest) end
  return s
end

local function sorted_uids(set)
  local out = {}
  for u in pairs(set) do out[#out + 1] = u end
  table.sort(out)
  return out
end

-- The aero records: the builder parts as they are (aero.build and the
-- readouts take { def, x, y, z, yaw, pitch, roll, uid, id } and read the def
-- under the pose), plus the crew where they sit (the flight's CoM carries
-- them: CREW_TU) when `crew`; `dry` empties the tanks.
local function aero_recs(ctx, dry, crew)
  local out = {}
  for u, p in pairs(ctx.parts) do
    if dry and (p.def.fuel or 0) > 0 then
      out[#out + 1] = { uid = u, id = p.id, def = setmetatable({ fuel = 0 }, { __index = p.def }), x = p.x, y = p.y, z = p.z,
                        yaw = p.yaw, pitch = p.pitch, roll = p.roll }
    else
      out[#out + 1] = p
    end
  end
  for u, t in pairs(crew and ctx.crew or {}) do
    local p = ctx.parts[u]
    if p and t > 0 then out[#out + 1] = { uid = -u, id = "crew", def = { mass = t, kind = "crew" }, x = p.x, y = p.y, z = p.z } end
  end
  return out
end

-- What the flight makes of the craft's command part (aeroScan): its nose and
-- top, or nil when it flies as a rocket (an upright, non-cockpit pod).
local function nose_frame(ctx, A)
  local cu, pu
  for u, p in pairs(ctx.parts) do
    local a = A.parse(p.def.af)
    if a and a.cockpit and (not cu or u < cu) then cu = u end
    if p.def.kind == "crewed" and (not pu or u < pu) then pu = u end
  end
  local u = cu or pu
  if not u then return nil end
  local p = ctx.parts[u]
  local _, Y, Z = A.axes(p.yaw, p.pitch, p.roll)
  if cu or Y.y < flight("FRAME_TILT") then
    return { n = Y, t = { x = -Z.x, y = -Z.y, z = -Z.z }, uid = u, cockpit = cu ~= nil }
  end
  return nil
end

-- Each wheel's tyre as the flight hangs it (vessel_controller's wheel setup):
-- the tyre's centre out along the part's +X (a landing gear's at the foot of
-- its leg), its radius, and its drive.
function tyres(ctx)
  local E = ctx.libs.electronics
  local out = {}
  for u, p in pairs(ctx.parts) do
    local d = p.def
    local dm = E and (d.wheel or "") ~= "" and ctx.rec and E.modOf(ctx.rec(u), "drive") or nil
    if dm then
      local r = dm.r or 0.4
      local size = d.wheel or "M"
      local X = ctx.libs.aero.axes(p.yaw, p.pitch, p.roll)
      local tx = (d.rx or 0.2) - (flight("TYRE_W")[size] or 0.26) / 2
      if dm.centred then tx = 0 end
      local a = ctx.libs.aero.parse(d.af)
      local gear = a and a.gear or false
      if gear then tx = (d.rx or 0.5) - r end
      out[#out + 1] = { uid = u, p = p, m = dm, r = r, size = size, gear = gear, cfg = p.cfg or {},
                        cx = p.x + X.x * tx, cy = p.y + X.y * tx, cz = p.z + X.z * tx }
    end
  end
  table.sort(out, function(a, b) return a.uid < b.uid end)
  return out
end

-- The craft's centre of mass with the crew aboard (the flight's: CREW_TU).
local function com(ctx, dry)
  local m, x, y, z = 0, 0, 0, 0
  for u, p in pairs(ctx.parts) do
    local d = p.def
    local dm = max(0.001, d.mass or 0.1) + (dry and 0 or (d.fuel or 0) * ctx.fuel_t) + (ctx.crew[u] or 0)
    m, x, y, z = m + dm, x + p.x * dm, y + p.y * dm, z + p.z * dm
  end
  if m <= 0 then return nil end
  return { x = x / m, y = y / m, z = z / m }, m
end

-- r2SteerPlan's figures for these tyres: each one's a (along the front) and
-- l (to the left) about the CoM, the track and the CoM's height over the
-- lowest tyre's contact — on the parts' own masses and the crew's, as
-- r2SteerPlan weighs them (no propellant); `mass` is the craft's full weight.
function steerPlan(ctx, ws)
  local F = ctx.front or { x = 1, z = 0 }
  local c = com(ctx, true)
  local _, m = com(ctx)
  if not c then return nil end
  local Lx, Lz = F.z, -F.x
  local lmin, lmax, gy = math.huge, -math.huge, math.huge
  for _, w in ipairs(ws) do
    local dx, dz = w.cx - c.x, w.cz - c.z
    w.a = dx * F.x + dz * F.z
    w.l = dx * Lx + dz * Lz
    lmin, lmax = min(lmin, w.l), max(lmax, w.l)
    gy = min(gy, w.cy - w.r)
  end
  return { track = lmax - lmin, hcg = c.y - gy, gy = gy, com = c, mass = m }
end

-- ── the rows ────────────────────────────────────────────────────────────────
local function row(out, t)
  t.sev = t.sev or "warn"
  t.rank = t.rank or 2
  t.uids = t.uids or {}
  out[#out + 1] = t
  return t
end

-- C1: what the flight thinks this is (craft_mode.autoOf, the verdict the
-- flight resolves R2.mode from).
local KIND_WORD = { aircraft = "AIRCRAFT", rover = "ROVER", rocket = "ROCKET" }
local function rule_kind(ctx, out, k)
  local mode = ctx.mode or {}
  local site = ctx.site == "runway" and "rolls out to the RUNWAY" or "stands on the PAD"
  -- (at a Build Stand: what the release does there)
  if ctx.atStand then site = ctx.release == "roll" and "let down off the STAND onto its wheels" or "lifts off the STAND" end
  local word = KIND_WORD[k.kind] or tostring(k.kind):upper()
  local pinned = mode.set ~= nil
  row(out, { id = "C1", sev = "note", rank = 2, kind = "any",
    head = fmt("Flies as %s · %s", word, site),
    text = pinned and fmt("Chosen in CONTROL MODE%s.", (mode.auto and mode.auto ~= mode.set)
      and fmt(" (Auto would make it %s: %s)", KIND_WORD[mode.auto] or mode.auto, mode.why or "") or "")
      or fmt("Auto reads it as %s: %s.", word:lower(), mode.why or "") })
  -- wings and jets that the flight will NOT fly as a plane
  local CM = ctx.libs.craft_mode
  local fig = k.fig
  if not pinned and k.kind == "rocket" and fig and (fig.jets or 0) > 0 and (fig.area or 0) > 0 and CM then
    local need = CM.AUTO_LIFT_JET or CM.AUTO_LIFT
    row(out, { id = "C1w", rank = 1, kind = "aircraft", uids = k.wings,
      head = "Too little wing: it will fly as a rocket",
      text = fmt("Its %.1f m² of wing carry %.1f m²/t of the %.2f t it lifts; Auto flies a jet as an aircraft from %.1f m²/t (craft_mode). As a rocket it has no landing gear, no brakes and no aero control. Add %.1f m² of wing, lose mass, or pick Aircraft in CONTROL MODE.",
        fig.area, fig.lift, fig.carried, need, max(0, need * fig.carried - fig.area)) })
  end
end

-- A1 / A2: the jets and their air (aero.step at a standstill, full throttle,
-- spooled: the thrust the roll starts on).
local function rule_jets(ctx, out, k)
  local A, M = ctx.libs.aero, k.model
  if #M.jets == 0 then return end
  local jets = {}
  for _, j in ipairs(M.jets) do jets[#jets + 1] = j.uid end
  local o2 = ctx.worldRec and A.oxygen(ctx.worldRec) or 1
  local sigma = ctx.sigma or 1
  local rho = A.RHO0 * sigma
  local g, R = ctx.world.g, ctx.world.r
  A.step(M, { rho = rho, a = A.soundSpeed(g, R), o2 = o2, throttle = 1, dt = 100 })
  local airf = M.diag.air
  local _, supply, demand = A.airShareOf(M, 0, 0, 0, 0)
  local T, T0 = 0, 0
  for _, j in ipairs(M.jets) do
    local th = ctx.parts[j.uid] and ctx.parts[j.uid].def.thrust or 0
    T, T0 = T + th, T0 + th * (j.jk or 0)
  end
  k.jetT, k.jetT0, k.airf = T, T0, airf
  local intake = ctx.def and ctx.def("intake")
  local cone = ctx.def and ctx.def("intakeCone")
  local ai = intake and tonumber(A.parse(intake.af).intake) or 0.06
  local ac = cone and tonumber(A.parse(cone.af).intake) or 0.14
  local nj = #jets
  local who = nameOf(ctx, jets)
  local fixI = { label = "ADD INTAKE", hold = "intake" }
  if o2 <= 0.05 then
    row(out, { id = "A2", rank = 0, kind = "aircraft", uids = jets,
      head = "This world's air won't light a jet",
      text = fmt("%s's air has no oxygen in it (aero.oxygen): %s give 0 kN here. Only rocket engines work on this world.",
        ctx.world.name or "The launch world", who) })
    return
  end
  if sigma <= 0.03 then
    row(out, { id = "A2", rank = 0, kind = "aircraft", uids = jets,
      head = "No air at the launch site: jets give 0 kN",
      text = fmt("The air at the %s is %.0f %% of sea level; a jet lights only above 3 %% (aero step). Rocket engines only.",
        ctx.site == "runway" and "runway" or "pad", sigma * 100) })
    return
  end
  if supply <= 0 then
    row(out, { id = "A1", rank = 0, kind = "aircraft", uids = jets, fix = fixI,
      head = "Jets have no intake: they will not light",
      text = fmt("%s need%s %.2f m² of intake air and the craft has none. A jet lights only on more than 15 %% of its air (aero step): 0 of %.1f kN. Add a Ram Intake (%.2f m²) or a Shock Cone Intake (%.2f m²) facing the nose.",
        Cap(who), nj == 1 and "s" or "", demand, T, ai, ac) })
  elseif airf <= 0.15 then
    row(out, { id = "A1", rank = 0, kind = "aircraft", uids = jets, fix = fixI,
      head = fmt("Jets need %.2f m² of intake, have %.2f: no light", demand, supply),
      text = fmt("%s get%s %.0f %% of %s air; a jet needs more than 15 %% to light at all (aero step). Add %d more Ram Intake%s (%.2f m² each).",
        Cap(who), nj == 1 and "s" or "", airf * 100, nj == 1 and "its" or "their", math.ceil((demand - supply) / ai - 1e-9), s_(math.ceil((demand - supply) / ai - 1e-9)), ai) })
  elseif airf < 1 - 1e-6 then
    local nmore = math.ceil((demand - supply) / ai - 1e-9)
    row(out, { id = "A1", rank = 2, kind = "aircraft", uids = jets, fix = fixI,
      head = fmt("Jets need %.2f m² of intake, have %.2f: %.0f %% thrust", demand, supply, T0 / max(T, 1e-9) * 100),
      text = fmt("Standing still %s get%s %.0f %% of %s air: %.1f of %.1f kN at the start of the roll. Ram air makes up the rest only with speed (+80 %% at Mach 1, aero step). Add %d more Ram Intake%s.",
        who, nj == 1 and "s" or "", airf * 100, nj == 1 and "its" or "their", T0, T, nmore, s_(nmore)) })
  end
  -- an intake facing away from the nose takes less in flight (aero intakeFace)
  local fr = k.frame
  if fr and supply > 0 then
    local n = fr.n
    local _, sfly = A.airShareOf(M, n.x, n.y, n.z, 0)
    if sfly < demand - 1e-6 then
      local bad, worst = {}, nil
      for _, it in ipairs(M.intakes) do
        local f = A.intakeFace(it, n.x, n.y, n.z)
        if f < 0.8 then
          bad[#bad + 1] = it.uid
          local ang = deg(math.acos(max(-1, min(1, dot(it.Y, n)))))
          if not worst or ang > worst.ang then worst = { ang = ang, f = f, uid = it.uid } end
        end
      end
      if worst then
        row(out, { id = "A1f", rank = 2, kind = "aircraft", uids = bad,
          head = fmt("%s faces %.0f° off the nose", Cap(nameOf(ctx, { worst.uid })), worst.ang),
          text = fmt("Flying nose-first it takes %.0f %% of its area (aero intakeFace): the jets get %.2f of the %.2f m² they need in flight. Turn its mouth (+Y) toward the nose.",
            worst.f * 100, sfly, demand) })
      end
    end
  end
end

-- A9: jets with nothing to burn in their section (vessel_controller feedSec).
-- R7: a stage whose engine has no tank, or whose tanks have no engine.
local function sections(ctx, branch)
  local cuts = {}
  for u, p in pairs(ctx.parts) do
    if p.def.decouple and not p.def.radial then cuts[#cuts + 1] = p.y end
  end
  table.sort(cuts)
  local sec = {}
  for k = 0, #cuts do sec[k] = { fuel = 0, tanks = {}, engines = {}, jets = {}, parts = {} } end
  for u, p in pairs(ctx.parts) do
    local s = branch[u] and 0 or feedSec(p.y, cuts)
    local S = sec[s]
    S.parts[#S.parts + 1] = u
    if (p.def.fuel or 0) > 0 and not p.def.rcs then S.fuel = S.fuel + p.def.fuel; S.tanks[#S.tanks + 1] = u end
    if (p.def.thrust or 0) > 0 then
      local a = ctx.libs.aero.parse(p.def.af)
      if a and a.jet then S.jets[#S.jets + 1] = u else S.engines[#S.engines + 1] = u end
    end
  end
  return sec, cuts
end

local function rule_feed(ctx, out, k)
  local sec, cuts = k.sec, k.cuts
  local dryjets = {}
  for s = 0, #cuts do
    local S = sec[s]
    if #S.jets > 0 and S.fuel <= 0 then for _, u in ipairs(S.jets) do dryjets[#dryjets + 1] = u end end
  end
  if #dryjets > 0 then
    table.sort(dryjets)
    row(out, { id = "A9", rank = 0, kind = "aircraft", uids = dryjets,
      head = "The jets have no fuel: add a Fuselage Tank",
      text = fmt("An engine drinks its own section's tanks only (vessel_controller feedSec), and %s's section has none. Add a Fuselage Tank on the same side of any decoupler.",
        nameOf(ctx, dryjets)) })
  end
  -- R7b (2026-11-11): a radial decoupler walls its booster's fuel off unless
  -- its crossfeed is on (electronics fuelGroups), so a booster engine with no
  -- tank of its own on the booster, and no fuel line into it, never burns
  if ctx.drops then
    local fedTo = {}
    for _, p in pairs(ctx.parts) do
      if p.def.fline and type(p.size) == "table" and p.size.to then fedTo[p.size.to] = true end
    end
    local dry, seen = {}, {}
    for u, p in pairs(ctx.parts) do
      if p.def.radial and p.def.decouple and not (type(p.size) == "table" and p.size.xfeed) then
        local set = ctx.drops(u) or {}
        local fuel, eng, fed = 0, {}, false
        for v in pairs(set) do
          local q = ctx.parts[v]
          if q then
            if (q.def.fuel or 0) > 0 and not q.def.rcs then fuel = fuel + q.def.fuel end
            if (q.def.thrust or 0) > 0 then eng[#eng + 1] = v end
            if fedTo[v] then fed = true end
          end
        end
        if #eng > 0 and fuel <= 0 and not fed then
          for _, v in ipairs(eng) do if not seen[v] then seen[v] = true; dry[#dry + 1] = v end end
        end
      end
    end
    if #dry > 0 then
      table.sort(dry)
      row(out, { id = "R7b", rank = 0, kind = "rocket", uids = dry,
        head = "A booster's engine has no tank: it never burns",
        text = fmt("A radial decoupler stops fuel (unless its Crossfeed is on), and %s %s no tank on its own side of it. Put a tank on the booster, turn the decoupler's Crossfeed on, or run a Fuel Line into it.",
          nameOf(ctx, dry), #dry == 1 and "has" or "have") })
    end
  end
  for s = 0, #cuts do
    local S = sec[s]
    if #S.engines > 0 and S.fuel <= 0 then
      table.sort(S.engines)
      row(out, { id = "R7e" .. s, rank = 0, kind = "rocket", uids = S.engines,
        head = fmt("Stage %d's engine has no tank: it never burns", s + 1),
        text = fmt("Fuel does not cross a decoupler (vessel_controller feedSec), and %s %s nothing to drink in its section. Put a tank between it and the decoupler above, or move the decoupler.",
          nameOf(ctx, S.engines), #S.engines == 1 and "has" or "have") })
    elseif #S.engines == 0 and #S.jets == 0 and S.fuel > 0 and s < #cuts then
      -- (a top section with only an RCS pool is a capsule's: not counted)
      table.sort(S.tanks)
      row(out, { id = "R7t" .. s, rank = 2, kind = "rocket", uids = S.tanks,
        head = fmt("Stage %d carries %.2f t of fuel and no engine", s + 1, S.fuel * ctx.fuel_t),
        text = fmt("%s %s %d fuel that no engine can reach (feedSec: an engine drinks its own section only): it is dead weight until the stage drops. Add an engine under it, or take the tank off.",
          Cap(nameOf(ctx, S.tanks)), #S.tanks == 1 and "holds" or "hold", S.fuel) })
    end
  end
end

-- A3: built standing up (vessel_controller R2.noseUp, then r2UprightGear).
local function rule_upright(ctx, out, k)
  local fr = k.frame
  if not (fr and abs(fr.n.y) > flight("NOSE_UP") and (k.kind == "aircraft" or fr.cockpit)) then return end
  k.noseUp = true
  local ang = deg(math.asin(min(1, abs(fr.n.y))))
  local uids = { fr.uid }
  for _, u in ipairs(k.gear) do uids[#uids + 1] = u end
  if #k.gear > 0 then
    row(out, { id = "A3", rank = 1, kind = "aircraft", uids = uids, fix = { label = "LAY IT LEVEL", cmd = "orient", args = { auto = true } },
      head = "Built standing up: the gear can't spring or steer",
      text = fmt("The nose points %.0f° up at the roof. Laid on the runway, each tyre is turned so it can roll (r2UprightGear), but the leg stays stiff along the nose and does not steer: a one-leg touchdown kicks hard. Build runway planes lying down: select everything (Ctrl+A) and turn the nose along the floor (W/S). (Until engine card 0562 gives wheels their own axle.)", ang) })
  elseif ctx.site == "runway" then
    row(out, { id = "A3", rank = 1, kind = "aircraft", uids = uids, fix = { label = "LAY IT LEVEL", cmd = "orient", args = { auto = true } },
      head = "Built standing up, no gear: it rolls out on its tail",
      text = fmt("The nose points %.0f° up, and the runway sets a craft on its lowest parts. Lay it along the floor (Ctrl+A, then W/S) and give it landing gear.", ang) })
  end
  if ctx.site == "pad" then
    row(out, { id = "A3n", sev = "note", kind = "aircraft", uids = { fr.uid },
      head = "Standing up on the pad: it flies as a spaceplane",
      text = "The flight flies it nose-up off the pad; its gear springs only once it is built lying level." })
  end
end

-- A4: the centre of lift against the centre of mass (aero.staticMargin), full
-- and with the tanks dry. Plus the STALL and MARGIN figures.
local function rule_margin(ctx, out, k)
  local A = ctx.libs.aero
  local wet = k.recs
  local lx, ly, lz = A.centerOfLift(wet, { model = k.model })
  if not lx then
    if (k.cockpit or #k.jetsAll > 0) and ctx.site == "runway" then
      row(out, { id = "A4", rank = 0, kind = "aircraft", uids = k.cockpit and { k.cockpit } or k.jetsAll,
        head = "No wing: nothing lifts it",
        text = "There is no lifting surface aboard (aero.centerOfLift), so it can't leave the runway. Add Wing Panels on both flanks (M mirrors them)." })
    end
    return
  end
  local d, mac = A.staticMargin(wet, { model = k.model })
  local fuel = false
  for _, p in pairs(ctx.parts) do if (p.def.fuel or 0) > 0 then fuel = true break end end
  local dd, dmac = nil, nil
  if fuel then dd, dmac = A.staticMargin(aero_recs(ctx, true, true), { model = k.model }) end
  k.margin = mac
  local wings = k.wings
  if mac and mac <= 0 then
    row(out, { id = "A4", rank = 1, kind = "aircraft", uids = wings,
      head = fmt("Lift %.2f m ahead of the mass: it flips", -d),
      text = fmt("The wings' lift acts %.2f m (%.2f chords) in front of the centre of mass at 5° nose-up (aero.staticMargin): any pitch grows by itself. Move the wings back, or the tanks and battery forward.", -d, -mac) })
  elseif mac and mac < 0.03 then
    row(out, { id = "A4", rank = 2, kind = "aircraft", uids = wings,
      head = fmt("Static margin +%.2f chords: twitchy", mac),
      text = fmt("The lift acts only %.2f m behind the centre of mass (aero.staticMargin): it holds its nose, barely. A margin of 0.05 to 0.15 chords flies steadily; move the wings a little aft.", d) })
  elseif mac and dmac and dmac <= 0 then
    row(out, { id = "A4d", rank = 1, kind = "aircraft", uids = wings,
      head = "Stable full, flips once the tanks run dry",
      text = fmt("Static margin %+.2f chords with the tanks full, %+.2f dry (aero.staticMargin): as the fuel burns the centre of mass moves %.2f m and the nose comes up by itself. Put the tanks over the wing's quarter chord.", mac, dmac, abs(d - dd)) })
  end
end

-- A5: control on each axis (aero step's mixing: a surface answers an axis by
-- its moment (r × Z)·axis about the centre of mass).
local AXIS_WORD = { p = "pitch", y = "yaw", r = "roll" }
local function mask_words(c)
  local t = {}
  for _, a in ipairs({ "p", "y", "r" }) do if c[a] == 1 then t[#t + 1] = AXIS_WORD[a] end end
  return table.concat(t, " and ")
end
local function rule_controls(ctx, out, k)
  local fr, M, c = k.frame, k.model, k.com
  if not (fr and c) then return end
  local n, t = fr.n, fr.t
  local ap, ay, ar = cross(t, n), t, n
  local P, Y, R, Pfar = 0, 0, 0, 0
  local psurf, near = {}, {}
  -- (surfaces placed where they WOULD turn an axis, but whose part is made
  -- for another: a Tail Fin, ctl=y, laid flat as a tailplane)
  local pmask, rmask = {}, {}
  for _, s in ipairs(M.surfs) do
    if s.ctl then
      local r = { x = s.x - c.x, y = s.y - c.y, z = s.z - c.z }
      local m = cross(r, s.Z)
      local qp, qy, qr = abs(dot(m, ap)) * s.S, abs(dot(m, ay)) * s.S, abs(dot(m, ar)) * s.S
      local gp, gy, gr = qp * s.ctl.p, qy * s.ctl.y, qr * s.ctl.r
      P, Y, R = P + gp, Y + gy, R + gr
      if s.ctl.p == 0 and qp > 0.05 and qp >= max(qy, qr) then pmask[#pmask + 1] = s end
      if s.ctl.r == 0 and qr > 0.05 and qr >= max(qp, qy) then rmask[#rmask + 1] = s end
      if gp > 1e-3 then
        psurf[#psurf + 1] = s.uid
        local arm = abs(dot(r, n))
        if arm > 0.3 then Pfar = Pfar + gp else near[#near + 1] = { uid = s.uid, arm = arm, S = s.S } end
      end
    end
  end
  local function masked(list)
    local u = {}
    for _, s in ipairs(list) do u[#u + 1] = s.uid end
    table.sort(u)
    return u, mask_words(list[1].ctl)
  end
  local who = fr.uid and { fr.uid } or {}
  -- the reaction wheels aboard (electronics `wheel` modules, kN·m): with no
  -- surface for an axis they are all that turns it
  local rw = 0
  local E = ctx.libs.electronics
  for u, p in pairs(ctx.parts) do
    if E and ctx.rec and (p.def.kind == "crewed" or p.def.kind == "probe" or p.def.mods) then
      for _, m in ipairs(E.modsOf(ctx.rec(u)) or {}) do if m.type == "wheel" then rw = rw + (tonumber(m.torque) or 1) end end
    end
  end
  local only = rw > 0 and fmt(" Only %.2f kN·m of reaction wheel turns it that way.", rw) or ""
  if P < 1e-3 then
    if #pmask > 0 then
      local u, w = masked(pmask)
      row(out, { id = "A5p", rank = rw > 0 and 1 or 0, kind = "aircraft", uids = u,
        head = "No pitch control: the tailplane can't pitch",
        text = fmt("%s lie%s where an elevator would, but %s made to answer %s only (the part's control mask, aero step): no surface moves the nose up or down.%s Put Elevon Panels there instead, or add a Canard at the nose.",
          Cap(nameOf(ctx, u)), #u == 1 and "s" or "", #u == 1 and "it is" or "they are", w, only) })
    else
      row(out, { id = "A5p", rank = rw > 0 and 1 or 0, kind = "aircraft", uids = who,
        head = "No pitch control: it can't rotate to take off",
        text = "No control surface aboard moves the nose up or down (aero step mixes each surface by its moment about the centre of mass)." .. only .. " Add an Elevon Panel at the tail or a Canard at the nose." })
    end
  elseif Pfar < 1e-3 and #near > 0 then
    local S, arm = 0, 0
    for _, q in ipairs(near) do S = S + q.S; arm = max(arm, q.arm) end
    row(out, { id = "A5a", rank = 2, kind = "aircraft", uids = psurf,
      head = "The pitch surfaces sit at the centre of mass",
      text = fmt("%s: %.1f m² of pitch surface with at most a %.2f m arm along the nose barely turns it. Put elevons at the tail, well behind the wing.", Cap(nameOf(ctx, psurf)), S, arm) })
  end
  if R < 1e-3 then
    if #rmask > 0 then
      local u, w = masked(rmask)
      row(out, { id = "A5r", rank = 1, kind = "aircraft", uids = u,
        head = "No roll control",
        text = fmt("%s could roll it, but %s made to answer %s only (the part's control mask): no surface banks it into a turn or levels its wings.%s Use Aileron or Elevon Panels out on the wings.",
          Cap(nameOf(ctx, u)), #u == 1 and "it is" or "they are", w, only) })
    else
      row(out, { id = "A5r", rank = 1, kind = "aircraft", uids = who,
        head = "No roll control",
        text = "No surface aboard rolls it: it can't bank into a turn or level its wings." .. only .. " Add Aileron or Elevon Panels out on the wings." })
    end
  end
  if Y < 1e-3 then
    row(out, { id = "A5y", sev = "note", kind = "aircraft", uids = who,
      head = "No rudder: it yaws with roll only",
      text = "Nothing aboard yaws it; a plane flies without, turning by banking. A Tail Fin gives it a rudder." })
  end
end

-- A6 + A7: the gear against the centre of mass, and the tail at rotation.
local function rule_gear(ctx, out, k)
  local fr, c = k.frame, k.com
  if k.noseUp or not (fr and c) then return end
  local n, t = fr.n, fr.t
  local side = cross(n, t)
  local gt = {}
  for _, w in ipairs(k.tyres) do if w.gear or k.kind == "aircraft" then gt[#gt + 1] = w end end
  if #gt == 0 then
    if ctx.site == "runway" and k.kind == "aircraft" then
      row(out, { id = "A6", rank = 0, kind = "aircraft", uids = k.jetsAll,
        head = "No landing gear: it rolls out on its belly",
        text = fmt("Nothing aboard rolls. On the runway it sits on its lowest parts and drags there; an engine bell breaks at %.0f m/s (vessel_controller TOLERANCE). Add Landing Gear: two behind the centre of mass, one at the nose.",
          flight("TOLERANCE").engine) })
    end
    return
  end
  local uids = {}
  local ground = math.huge
  for _, w in ipairs(gt) do
    local r = { x = w.cx - c.x, y = w.cy - c.y, z = w.cz - c.z }
    w.ga, w.gl = dot(r, n), dot(r, side)
    w.gh = dot({ x = w.cx, y = w.cy, z = w.cz }, t) - w.r
    ground = min(ground, w.gh)
    uids[#uids + 1] = w.uid
  end
  table.sort(gt, function(a, b) return a.ga < b.ga end)
  local amin = gt[1].ga
  local mains, front = {}, {}
  for _, w in ipairs(gt) do
    if w.ga <= amin + 0.3 then mains[#mains + 1] = w else front[#front + 1] = w end
  end
  local lmin, lmax = math.huge, -math.huge
  for _, w in ipairs(gt) do lmin, lmax = min(lmin, w.gl), max(lmax, w.gl) end
  if lmax - lmin < 0.3 then
    if k.kind == "aircraft" then
      row(out, { id = "A6l", rank = 1, kind = "aircraft", uids = uids,
        head = "Gear in one line: it falls on a wing",
        text = fmt("The landing gear stands within %.2f m side to side: on the runway nothing holds the wings level. Put the main gear on both flanks (M mirrors them).", lmax - lmin) })
    end
    return
  end
  if #mains < 2 then
    -- a tail-dragger (one tyre aft): the check below is for tricycle gear
    row(out, { id = "A6t", sev = "note", kind = "aircraft", uids = uids,
      head = "A tail-dragger: the gear check covers tricycle gear",
      text = "One tyre stands behind the others. The nose-load and tail-strike checks are written for a tricycle (two mains behind the centre of mass, one at the nose)." })
    return
  end
  local am = 0
  for _, w in ipairs(mains) do am = am + w.ga end
  am = am / #mains
  local mu = {}
  for _, w in ipairs(mains) do mu[#mu + 1] = w.uid end
  if am >= 0 then
    local L = (#front > 0) and (front[#front].ga - am) or 0
    row(out, { id = "A6m", rank = 1, kind = "aircraft", uids = mu,
      head = fmt("Main gear %.2f m ahead of the mass: sits on its tail", am),
      text = fmt("The main gear stands %.2f m ahead of the centre of mass along the nose, so the tail goes down and the nose gear lifts off the runway. Move the mains behind the centre of mass by 5-15 %% of the wheelbase%s.",
        am, L > 0 and fmt(" (%.2f-%.2f m behind it)", 0.05 * L, 0.15 * L) or "") })
    return
  end
  if #front > 0 then
    local an = 0
    for _, w in ipairs(front) do an = an + w.ga end
    an = an / #front
    local L = an - am
    local kn = -am / L
    local nu = {}
    for _, w in ipairs(front) do nu[#nu + 1] = w.uid end
    if kn < 0.05 then
      row(out, { id = "A6n", rank = 1, kind = "aircraft", uids = mu,
        head = fmt("Nose gear carries %.0f %% of the weight: ground-loops", kn * 100),
        text = fmt("The mains stand only %.2f m behind the centre of mass on a %.2f m wheelbase, so the nose tyre carries %.0f %% of the weight (statics): it can't steer and under the brakes the plane swings round (jetland probe: a ground loop above 15 m/s). Move the mains back to %.2f-%.2f m behind it.",
          -am, L, kn * 100, 0.05 * L, 0.15 * L) })
    elseif kn > 0.20 then
      row(out, { id = "A6n", rank = 2, kind = "aircraft", uids = mu,
        head = fmt("Nose gear carries %.0f %%: hard to rotate", kn * 100),
        text = fmt("The mains stand %.2f m behind the centre of mass on a %.2f m wheelbase: the elevators must lift %.0f %% of the weight off the nose to rotate. Move the mains forward to %.2f-%.2f m behind it.",
          -am, L, kn * 100, 0.05 * L, 0.15 * L) })
    end
  end
  -- A7: TAIL STRIKE. The lowest point aft of the mains against the angle the
  -- wing needs to lift the craft at 1.15 × its stall speed (aero's own lift,
  -- body angle stepped up from level): an estimate, so it says "about".
  local A = ctx.libs.aero
  local best = nil
  for u, p in pairs(ctx.parts) do
    local d = p.def
    local X, Y, Z = A.axes(p.yaw, p.pitch, p.roll)
    local hx, hy, hz = d.rx or 0.25, (d.h or 0.5) / 2, d.rz or 0.25
    -- (the gear's own legs and tyres are what it stands on)
    if (d.wheel or "") ~= "" then hx = -1 end
    if hx >= 0 then
    for sx = -1, 1, 2 do for sy = -1, 1, 2 do for sz = -1, 1, 2 do
      local q = { x = p.x + X.x * hx * sx + Y.x * hy * sy + Z.x * hz * sz,
                  y = p.y + X.y * hx * sx + Y.y * hy * sy + Z.y * hz * sz,
                  z = p.z + X.z * hx * sx + Y.z * hy * sy + Z.z * hz * sz }
      local a = dot({ x = q.x - c.x, y = q.y - c.y, z = q.z - c.z }, n)
      local x = am - a
      if x > 0.3 then
        local h = max(0, dot(q, t) - ground)
        local th = math.atan(h / x)
        if not best or th < best.th then best = { th = th, uid = u } end
      end
    end end end
    end
  end
  if best and k.stall and ctx.sigma > 0 then
    local v = 1.15 * k.stall.v
    local rho = A.RHO0 * ctx.sigma
    local W = k.mass * ctx.world.g
    local need = nil
    for i = 0, 40 do
      local al = rad(i * 0.5)
      local ca, sa = math.cos(al), math.sin(al)
      local vx, vy, vz = (n.x * ca - t.x * sa) * v, (n.y * ca - t.y * sa) * v, (n.z * ca - t.z * sa) * v
      local L = 0
      for _, s in ipairs(k.model.surfs) do
        local fx, fy, fz = A.surfaceForce(s, vx, vy, vz, rho, 0, 0)
        L = L + fx * t.x + fy * t.y + fz * t.z
      end
      if L >= W then need = al break end
    end
    if need and best.th < need then
      row(out, { id = "A7", rank = 2, kind = "aircraft", uids = { best.uid },
        head = fmt("Tail strikes at %.0f° of rotation; needs about %.0f°", deg(best.th), deg(need)),
        text = fmt("%s touches the runway when the nose is %.0f° up, and lifting %.2f t at %.0f m/s (1.15 × the stall) takes about %.0f° (aero's lift at that speed). Move the main gear back, or the tail up.",
          Cap(nameOf(ctx, { best.uid })), deg(best.th), k.mass, v, deg(need)) })
    end
  end
end

-- A8: the stall speed and the runway (aero.stallSpeed at the pad's air).
local function rule_stall(ctx, out, k)
  local A = ctx.libs.aero
  if not k.frame or ctx.sigma <= 0 then return end
  local rho = A.RHO0 * ctx.sigma
  local v, S, CL = A.stallSpeed(k.recs, k.mass, ctx.world.g, rho, { model = k.model })
  if not v then return end
  k.stall = { v = v, S = S, CL = CL }
  if not (k.jetT0 and k.jetT0 > 0) or ctx.site ~= "runway" then return end
  local vto = 1.15 * v
  local a = k.jetT0 / k.mass
  local roll = vto * vto / (2 * a)
  local L = flight("RUNWAY_LEN")
  if roll > L then
    row(out, { id = "A8", rank = 2, kind = "aircraft", uids = k.wings,
      head = fmt("Needs about %.0f m of runway; it has %.0f", roll, L),
      text = fmt("It stalls at %.0f m/s on %.1f m² of wing for %.2f t (aero.stallSpeed) and lifts off at about %.0f m/s. On %.1f kN of standing thrust (T/W %.2f) that takes about %.0f m of roll, before drag: more wing, more thrust or less weight.",
        v, S, k.mass, vto, k.jetT0, k.jetT0 / (k.mass * ctx.world.g), roll) })
  else
    row(out, { id = "A8n", sev = "note", kind = "aircraft", uids = {},
      head = fmt("Stalls at %.0f m/s; lifts off in about %.0f m", v, roll),
      text = fmt("%.1f m² of wing for %.2f t (aero.stallSpeed); %.1f kN standing thrust, T/W %.2f. The runway is %.0f m.",
        S, k.mass, k.jetT0, k.jetT0 / (k.mass * ctx.world.g), L) })
  end
end

-- V2 / V3 / V9: what the wheels can do (the flight's push, grip and turn cap).
-- A wheel's full torque (kN·m) as r2WheelSource gives it, and its top speed.
local function wheel_source(ctx, w, bike)
  local AD = ctx.libs.auto_drive
  local rk = ctx.rk or 1
  local ch = ctx.chains and ctx.chains[w.uid]
  if ch and ch.mod and AD and AD.gasWheel then
    local q = AD.gasWheel(ch.mod, 0, w.r, ch.teeth, 1)
    return q.torque * rk, q.top, ch
  end
  local m = w.m or {}
  -- (the record's torque is rated at save: finishBlueprint × rating)
  local full = max((tonumber(m.torque) or 0.6) * rk, (flight("R2_WHEEL_TORQUE")[w.size] or 0) * rk)
  local top = max(tonumber(m.speed) or 0, flight("R2_WHEEL_TOP")[w.size] or 0)
  if bike then
    full = max(full, flight("R2_BIKE_TORQUE") * rk)
    top = max(top, flight("R2_BIKE_TOP"))
  end
  local vk = max(0.6, min(1.0, sqrt(max(ctx.world.g, 0) / flight("R2_G_REF"))))
  return full, top * vk, nil
end

-- THE STEEPEST HILL IT DRIVES STRAIGHT UP, three limits (rigid-body statics
-- on a slope θ, the flight's push and grip):
--   torque  the push F (Σ torque / r, r2WheelSource) against the weight's
--           pull down the slope: sin θ = F / W
--   grip    the driven tyres' friction μ (R2_TYRE_MU × Grip) on their load,
--           which on a slope moves toward the rear by W·sin θ·h/L: for the
--           rear axle driven tan θ = μ·s / (1 − μ·h/L), the front
--           tan θ = μ·s / (1 + μ·h/L), all wheels tan θ = μ (s = the driven
--           axle's static share, h = the CoM's height, L = the wheelbase)
--   tip     it goes over backwards once the CoM is behind the rear contact:
--           tan θ = (CoM ahead of the rear axle) / h
--   lift    a BIKE (ax.lean set): the push that climbs lifts the front first
--           (drive_tick's bike block): F h ≤ k (W cos θ · a + W · lean), k
--           R2_LIFT_MAX, lean the rider's weight forward in the attack
--           position (R2_BIKE.lean, up to crew weight × leanMax / mass), so
--           h sin θ − k a cos θ = k lean. The tall saddles of 2026-11-05 put
--           the 500's at 34°: the climb's real limit, not its torque.
-- → θ, and which limit it is ("torque" | "grip" | "tip" | "lift"), and each.
function climbLimits(F, W, mu, ax, h)
  local lim = {}
  lim.torque = math.asin(min(1, F / max(W, 1e-9)))
  if ax.all then
    lim.grip = math.atan(mu)
  elseif ax.L and ax.L > 0.05 then
    local den = ax.rear and (1 - mu * h / ax.L) or (1 + mu * h / ax.L)
    lim.grip = den > 1e-6 and math.atan(mu * ax.s / den) or rad(90)
  end
  if ax.back and ax.back > 0 and h > 0.05 then lim.tip = math.atan(ax.back / h) end
  if ax.lean and ax.back and h > 0.05 then
    local k = flight("R2_LIFT_MAX")
    local R = math.sqrt(h * h + (k * ax.back) ^ 2)
    lim.lift = math.atan2(k * ax.back, h) + math.asin(min(1, k * ax.lean / R))
    lim.tip = nil   -- (the lift comes first: it is the tip under power)
  end
  local best, why = rad(90), "torque"
  for _, k in ipairs({ "torque", "grip", "tip", "lift" }) do
    if lim[k] and lim[k] < best - 1e-9 then best, why = lim[k], k end
  end
  return best, why, lim
end

local function rule_wheels(ctx, out, k)
  if k.kind ~= "rover" then return end
  local ws = k.tyres
  if #ws < 2 then return end
  local plan = steerPlan(ctx, ws)
  if not plan then return end
  local AD = ctx.libs.auto_drive
  local E = ctx.libs.electronics
  local bike = AD and AD.isBike and AD.isBike(ws) or false
  local amax, amin = -math.huge, math.huge
  for _, w in ipairs(ws) do amax, amin = max(amax, w.a), min(amin, w.a) end
  local g = ctx.world.g
  local W = plan.mass * g
  -- V9: a wheel that hangs off the ground on the stand, past what its own
  -- travel and a suspension mount's (a fork, a swing arm) let it drop
  local hang = {}
  for _, w in ipairs(ws) do
    local h = (w.cy - w.r) - plan.gy
    local drop = tonumber(w.p.def.travel) or 0
    local par = w.p.parent and ctx.parts[w.p.parent] and ctx.rec and ctx.rec(w.p.parent)
    local sm = par and E and E.modOf(par, "susp")
    if sm then drop = drop + (tonumber(sm.travel) or 0) end
    if h > 0.05 + drop then hang[#hang + 1] = { uid = w.uid, h = h, drop = drop } end
  end
  -- the driven wheels and their push
  local F, drv, mu_s, nmu, src, top = 0, {}, 0, 0, nil, math.huge
  for _, w in ipairs(ws) do
    local c = w.cfg or {}
    local chain = ctx.chains and ctx.chains[w.uid]
    -- (a wheel with no motor coasts; a bike's front on Auto rolls, motoPlan)
    local coast = (w.m.motor == false and not chain)
      or (bike and (c.drive or "auto") == "auto" and w.a >= amax - 1e-6 and not chain)
    if c.drive ~= "off" and not coast then
      local full, tp, ch = wheel_source(ctx, w, bike)
      F = F + full * (c.motor or 1) / max(0.05, w.r)
      drv[#drv + 1] = w
      w.full, w.top = full, tp
      top = min(top, tp)
      if ch then src = ch end
      mu_s, nmu = mu_s + flight("R2_TYRE_MU") * (c.friction or 1), nmu + 1
    end
  end
  for _, hw in ipairs(hang) do
    for _, w in ipairs(drv) do
      if w.uid == hw.uid then
        row(out, { id = "V9", rank = 1, kind = "rover", uids = { w.uid },
          head = fmt("%s hangs %.2f m off the ground", Cap(nameOf(ctx, { w.uid })), hw.h),
          text = fmt("Its tyre stands %.2f m above the lowest tyre's contact and its suspension drops only %.2f m: it drives nothing until the frame tips onto it. Lower it, or raise the others.", hw.h, hw.drop) })
        break
      end
    end
  end
  if #drv == 0 then return end
  local mu = mu_s / max(1, nmu)
  if bike then mu = mu * flight("R2_GRIP_K") end
  -- the axles along the front: the driven group against the rest
  local ax = { back = -amin }
  -- (a bike: the rider leans as far forward as their weight reaches, r2AttackLean)
  if bike then
    local crewT = 0
    for _, t in pairs(ctx.crew or {}) do crewT = crewT + t end
    ax.lean = max(flight("R2_BIKE_LEAN"), crewT * flight("R2_BIKE_LEANMAX") / max(plan.mass, 1e-3))
  end
  local dset = {}
  for _, w in ipairs(drv) do dset[w.uid] = true end
  if #drv == #ws then ax.all = true
  else
    local da, oa, nd, no, spread = 0, 0, 0, 0, 0
    for _, w in ipairs(ws) do
      if dset[w.uid] then da, nd = da + w.a, nd + 1 else oa, no = oa + w.a, no + 1 end
    end
    da, oa = da / nd, oa / no
    for _, w in ipairs(ws) do spread = max(spread, abs(w.a - (dset[w.uid] and da or oa))) end
    -- (two axles: the lever rule holds; more, and the grip is not judged)
    if spread < 0.15 and abs(da - oa) > 0.2 then
      ax.L, ax.rear = abs(da - oa), da < oa
      ax.s = max(0, min(1, oa / (oa - da)))
    end
  end
  local th, why, lim = climbLimits(F, W, mu, ax, plan.hcg)
  local uids = {}
  for _, w in ipairs(drv) do uids[#uids + 1] = w.uid end
  if src and src.e then uids[#uids + 1] = src.e end
  local rider = 0
  for _, t in pairs(ctx.crew or {}) do rider = rider + t end
  local mass_s = rider > 0 and fmt("%.2f t with the rider", plan.mass) or fmt("%.2f t", plan.mass)
  local ref_r = drv[1].r
  local tq = 0
  for _, w in ipairs(drv) do tq = tq + w.full end
  local what = src and label(ctx.parts[src.e]) or (#drv == 1 and "Its motor" or fmt("Its %d motors", #drv))
  local push = fmt("%s push%s %.2f kN (%.2f kN·m on %.2f m tyres) against %s on %s (g %.1f)",
    what, what:match("^Its %d") and "" or "es", F, tq, ref_r, mass_s, ctx.world.name or "this world", g)
  if deg(th) < 30 then
    local fixes = {}
    local because
    if why == "grip" then
      because = fmt("the driven tyre%s spin%s first: %s carr%s %.0f %% of the weight standing level (μ %.2f)",
        s_(#drv), #drv == 1 and "s" or "", #drv == 1 and "it" or "they", #drv == 1 and "ies" or "y", (ax.s or 1) * 100, mu)
      fixes[#fixes + 1] = fmt("the battery and tanks over the driven wheel%s", s_(#drv))
      if #drv < #ws then fixes[#fixes + 1] = fmt("every wheel driving (%.0f°)", deg((climbLimits(F, W, mu, { all = true, back = ax.back, lean = ax.lean }, plan.hcg)))) end
    elseif why == "lift" then
      because = fmt("its front lifts first: the centre of mass stands %.2f m up and %.2f m ahead of the rear wheel, and the rider can lean only so far over the bars", plan.hcg, ax.back)
      fixes[#fixes + 1] = "a lower saddle and the heavy parts low and forward"
      fixes[#fixes + 1] = "a longer wheelbase"
    elseif why == "tip" then
      because = fmt("its centre of mass stands %.2f m up and only %.2f m ahead of the rear wheel, so it goes over backwards", plan.hcg, ax.back)
      fixes[#fixes + 1] = "the heavy parts lower down or further forward"
    else
      because = fmt("the push is all its torque gives (the slope's pull is %.2f kN at %.0f°)", W * math.sin(th), deg(th))
      if src and src.mod and AD then
        -- a bigger rear sprocket (auto_drive TEETH_MAX), and the next engine up
        local best_t = nil
        for teeth = (src.teeth or 48) + 4, AD.TEETH_MAX or 62, 4 do
          local q = AD.gasWheel(src.mod, 0, ref_r, teeth, 1)
          local th2 = climbLimits(F * q.torque * (ctx.rk or 1) / max(1e-9, tq), W, mu, ax, plan.hcg)
          best_t = { teeth = teeth, th = th2 }
          if deg(th2) >= 30 then break end
        end
        if best_t and best_t.th > th + rad(0.5) then fixes[#fixes + 1] = fmt("a %d-tooth rear sprocket (%.0f°)", best_t.teeth, deg(best_t.th)) end
        if ctx.gasEngines then
          for _, e in ipairs(ctx.gasEngines()) do
            if (e.mod.nm or 0) > (src.mod.nm or 0) then
              local q = AD.gasWheel(e.mod, 0, ref_r, src.teeth, 1)
              local dm = (e.mass or 0) - (ctx.parts[src.e] and ctx.parts[src.e].def.mass or 0)
              local th2 = climbLimits(F * q.torque * (ctx.rk or 1) / max(1e-9, tq), (plan.mass + dm) * g, mu, ax, plan.hcg)
              if deg(th2) >= 30 then fixes[#fixes + 1] = fmt("a %s (%.0f°)", e.label, deg(th2)) break end
            end
          end
        end
      elseif #drv < #ws then
        local Fall = 0
        for _, w in ipairs(ws) do
          local full = wheel_source(ctx, w, bike)
          Fall = Fall + full * ((w.cfg or {}).motor or 1) / max(0.05, w.r)
        end
        fixes[#fixes + 1] = fmt("all %d wheels driving (%.0f°)", #ws, deg((climbLimits(Fall, W, mu, { all = true, back = ax.back, lean = ax.lean }, plan.hcg))))
      end
      fixes[#fixes + 1] = "less weight"
    end
    row(out, { id = "V2", rank = 1, kind = "rover", uids = uids,
      head = fmt("Climbs %.0f° at most: the hills run 15-40°", deg(th)),
      text = fmt("%s: it stalls on a %.0f° slope, because %s. Try %s.", push, deg(th), because,
        #fixes > 1 and (table.concat(fixes, ", ", 1, #fixes - 1) .. " or " .. fixes[#fixes]) or fixes[1]) })
  else
    row(out, { id = "V2n", sev = "note", kind = "rover", uids = uids,
      head = fmt("Climbs up to %.0f° · top %.0f m/s", deg(th), top),
      text = fmt("%s; the %s sets the limit.", push, why == "tip" and "tip-over backwards" or (why == "lift" and "front lifting" or (why == "grip" and "tyres' grip" or "torque"))) })
  end
  k.climb, k.climbWhy = th, why
  -- V3: how tall it stands on its track (r2Lateral; three wheels or more)
  if not bike and #ws >= 3 and plan.track > 0.05 and plan.hcg > 0.05 then
    local ssf = 0.5 * plan.track / plan.hcg
    k.ssf = ssf
    if ssf < 1.0 then
      local heavy, hm = nil, -1
      for u, p in pairs(ctx.parts) do
        local v = ((p.def.mass or 0) + (p.def.fuel or 0) * ctx.fuel_t) * (p.y - plan.gy)
        if v > hm then heavy, hm = u, v end
      end
      local cap = lateral(g, plan, mu)
      row(out, { id = "V3", rank = 1, kind = "rover", uids = heavy and { heavy } or {},
        head = fmt("Mass %.2f m up on a %.2f m track: tips easily", plan.hcg, plan.track),
        text = fmt("Stability factor %.2f (half the track over the centre of mass's height): it tips over on a %.0f° side slope, and the flight holds its turns to %.1f m/s² where the tyres could take %.1f (r2Lateral). Widen the wheels, or lower %s.",
          ssf, deg(math.atan(ssf)), cap, flight("R2_LAT_MU") * mu * g, nameOf(ctx, { heavy })) })
    end
  end
end

-- R6: how fast it comes down under its chutes (the flight's canopy drag:
-- 1.3 · #chutes · v² · air, so v = √(m·g / (1.3·n·air)); the air at the
-- ground is the band's full 1). Mass: the stage the chutes ride, dry, crew in.
local function rule_chutes(ctx, out, k)
  local chutes = {}
  for u, p in pairs(ctx.parts) do if p.def.chute then chutes[#chutes + 1] = u end end
  if #chutes == 0 or k.kind == "rover" then return end
  table.sort(chutes)
  local sec, cuts = k.sec, k.cuts
  local s0 = math.huge
  for _, u in ipairs(chutes) do s0 = min(s0, feedSec(ctx.parts[u].y, cuts)) end
  local m, low, lowy = 0, nil, math.huge
  local branch = k.branch or {}
  local n = 0
  for u, p in pairs(ctx.parts) do
    if not branch[u] and feedSec(p.y, cuts) >= s0 then
      m = m + (p.def.mass or 0) + (ctx.crew[u] or 0)
      if p.def.chute then n = n + 1 end
      local bottom = p.y - (p.def.h or 0.5) / 2
      if bottom < lowy then low, lowy = u, bottom end
    end
  end
  if n == 0 or m <= 0 then return end
  local g = ctx.world.g
  local v = chuteSpeed(m, g, n)
  local lp = ctx.parts[low]
  local tol = tolerance(lp.def)
  local floor = tol * flight("DAMAGE_FLOOR")
  local v1 = chuteSpeed(m, g, n + 1)
  local stage = (s0 == 0) and "whole" or fmt("top %d", #cuts + 1 - s0)
  if v >= tol then
    row(out, { id = "R6", rank = 0, kind = "rocket", uids = chutes, fix = { label = "ADD CHUTE", hold = "chute" },
      head = fmt("Lands at %.1f m/s under %d chute%s: the %s breaks at %s", v, n, s_(n), label(lp), N(tol)),
      text = fmt("The landing stage weighs %.2f t dry; %d canop%s hold it to %.1f m/s on %s (g %.1f; the flight's canopy drag, 1.3 per chute). The %s touches first: it breaks at %s m/s and takes damage from %.1f. One more chute gives %.1f m/s.",
        m, n, n == 1 and "y" or "ies", v, ctx.world.name or "this world", g, label(lp), N(tol), floor, v1) })
  else
    row(out, { id = "R6n", sev = "note", kind = "rocket", uids = chutes,
      head = fmt("Lands at %.1f m/s under %d chute%s", v, n, s_(n)),
      text = fmt("%.2f t dry under %d canop%s on %s (g %.1f). The %s touches first: it breaks at %s m/s, scuffs from %.1f.",
        m, n, n == 1 and "y" or "ies", ctx.world.name or "this world", g, label(lp), N(tol), floor) })
  end
  k.chute_v = v
end

-- R8: the staging order (the STAGE tab's stack: uid → stage, and what each
-- decoupler throws off, the flight's separation).
local function rule_staging(ctx, out, k)
  local idx, drops = ctx.stageIdx, ctx.drops
  if not (idx and drops) then return end
  local decs, engines, chutes, fairs = {}, {}, {}, {}
  for u, p in pairs(ctx.parts) do
    if p.def.decouple then decs[#decs + 1] = u
    elseif p.def.chute then chutes[#chutes + 1] = u
    elseif p.def.fairing then fairs[#fairs + 1] = u end
    if (p.def.thrust or 0) > 0 then engines[#engines + 1] = u end
  end
  if #decs == 0 then return end
  table.sort(decs)
  local fixD = { label = "DEFAULT ORDER", cmd = "stage", args = { op = "reset" } }
  local dset = {}
  for _, d in ipairs(decs) do dset[d] = drops(d) or {} end
  -- an upper decoupler fired before the one under it
  local function order_row()
    for _, du in ipairs(decs) do
      local nu = idx[du]
      if nu and nu > 0 then
        for _, dl in ipairs(decs) do
          local nl = idx[dl]
          if dl ~= du and nl and nl > nu and dset[du][dl] and not ctx.parts[dl].def.radial then
            return row(out, { id = "R8o", rank = 1, kind = "rocket", uids = { du, dl }, fix = fixD,
              head = fmt("Stage %d drops a stage still to fire", nu),
              text = fmt("Stage %d fires %s, which throws off %s with the stage under it still attached: that stage goes before it ever lights. DEFAULT ORDER in the STAGE tab puts the decouplers bottom-up.",
                nu, nameOf(ctx, { du }), nameOf(ctx, { dl })) })
          end
        end
      end
    end
  end
  order_row()
  -- an engine lit after the stage that throws it away
  local function engine_row()
    for _, e in ipairs(engines) do
      local ne = idx[e]
      if ne then
        for _, d in ipairs(decs) do
          local nd = idx[d]
          if nd and nd > 0 and nd < ne and dset[d][e] then
            return row(out, { id = "R8e", rank = 0, kind = "rocket", uids = { e, d }, fix = fixD,
              head = fmt("The %s lights in stage %d; stage %d drops it", label(ctx.parts[e]), ne, nd),
              text = fmt("%s is set to ignite in stage %d, but %s fires in stage %d and throws it away first: it never burns. Move the engine's row up in the STAGE tab, or DEFAULT ORDER.",
                Cap(nameOf(ctx, { e })), ne, nameOf(ctx, { d }), nd) })
          end
        end
      end
    end
  end
  table.sort(engines)
  engine_row()
  -- chutes before an engine still to fire
  local nc = math.huge
  for _, c in ipairs(chutes) do if idx[c] then nc = min(nc, idx[c]) end end
  if nc < math.huge then
    local late = nil
    for _, e in ipairs(engines) do
      local ne = idx[e]
      if ne and ne > nc and not (late and idx[late] <= ne) then late = e end
    end
    if late then
      local q = flight("CHUTE_SAFE_KPA")
      local vq = sqrt(2 * q * 1000 / (1.225 * max(ctx.sigma, 1e-3)))
      table.sort(chutes)
      row(out, { id = "R8c", rank = 1, kind = "rocket", uids = chutes, fix = fixD,
        head = fmt("Chutes open in stage %d, before stage %d's engine", nc, idx[late]),
        text = fmt("The parachutes are set to open in stage %d while %s still has to fire in stage %d. A canopy opened past %.1f kPa tears (about %.0f m/s in the pad's air). Put the chutes last in the STAGE tab.",
          nc, nameOf(ctx, { late }), idx[late], q, vq) })
    end
  end
end

-- R11: a fairing that doesn't hold its payload (fairingFit).
local function rule_fairings(ctx, out, k)
  for u, fit in pairs(ctx.fairings or {}) do
    if fit and (fit.nout or 0) > 0 then
      local outs = sorted_uids(fit.out or {})
      local wide = 0
      for _, v in ipairs(outs) do
        local pl = fit.pls and fit.pls[v]
        if pl then wide = max(wide, pl.rad) end
      end
      row(out, { id = "R11." .. u, rank = 2, kind = "rocket", uids = outs,
        fix = { label = "FIT", cmd = "fairing", args = { uid = u, op = "fit" } },
        head = fmt("%d part%s stick%s out of the fairing", #outs, s_(#outs), #outs == 1 and "s" or ""),
        text = fmt("%s poke%s through the %.2f m shell%s: they take full drag, and the pieces hit them at jettison (fairprobe: a 0.29 m clip). FIT grows the shell just enough.",
          Cap(nameOf(ctx, outs)), #outs == 1 and "s" or "", (fit.rmax or 0) * 2,
          wide > 0 and fmt(" (the widest reaches %.2f m from its axis)", wide) or "") })
    elseif fit and fit.closed and fit.load and next(fit.load) == nil and (fit.mass or 0) > 0 then
      row(out, { id = "R11e." .. u, sev = "note", kind = "rocket", uids = { u },
        head = "An empty fairing",
        text = fmt("%.0f kg of shell over nothing: stack the payload on the base.", fit.mass * 1000) })
    end
  end
end

-- C3: a probe that can't be flown (electronics.summary).
local function rule_probe(ctx, out, k)
  local probe, crewed = false, false
  for _, p in pairs(ctx.parts) do
    if p.def.kind == "probe" then probe = true elseif p.def.kind == "crewed" then crewed = true end
  end
  if not probe or crewed then return end
  local pw = type(ctx.power) == "function" and ctx.power() or ctx.power
  if not (pw and (pw.probe or 0) > 0 and (pw.crew or 0) == 0) then return end
  local probes = {}
  for u, p in pairs(ctx.parts) do if p.def.kind == "probe" then probes[#probes + 1] = u end end
  table.sort(probes)
  if (pw.antenna and pw.antenna.any or 0) <= 0 then
    row(out, { id = "C3a", rank = 0, kind = "any", uids = probes,
      head = "No antenna: the probe can't be flown",
      text = fmt("A probe core flies only with power and a link home (electronics). Nothing aboard has a radio: add an antenna (the craft idles at %.2f EC/s).", pw.idle or 0) })
  end
  if (pw.store or 0) <= 0 and (pw.solar or 0) <= 0 and (pw.rtg or 0) <= 0 then
    row(out, { id = "C3p", rank = 0, kind = "any", uids = probes,
      head = "No power: the probe is dark on the pad",
      text = fmt("It draws %.2f EC/s idle and has no battery, panel or RTG: add a Battery Pack.", pw.idle or 0) })
  end
end

-- ── PHASE 4: HEAT, RADIATION, RODS (thermal.lua) AND CREW ROLES ───────────
-- Registered by the builder through checkHook("heat") / checkHook("crew");
-- every number is thermal.lua's (via builder.thermalBudget: the same settle
-- and doseRate the flight runs) or the crew script's.
local function hu(x) return fmt("%.1f hu", x) end
function heatRules(ctx, out, k)
  local tb = ctx.thermal and ctx.thermal()
  local TH = ctx.libs.thermal
  if not (tb and TH) then return end
  local T = TH.THERMAL
  local cores = {}
  for _, c in ipairs(tb.cores or {}) do cores[#cores + 1] = c.uid end
  table.sort(cores)
  local pct = math.floor(tb.eq * 100 + 0.5)
  if #cores > 0 and tb.eq >= T.scram then
    -- the radiator it needs to settle under the scram line: S' = Q / scram
    local need = tb.Q / T.scram - tb.S
    local panel = ctx.def and ctx.def("radPanel")
    local pm
    for _, m in ipairs(panel and panel.mods or {}) do if m.type == "radiator" then pm = m end end
    local each = pm and TH.radiatorSink(pm, 1, 1, 1, 1) or nil
    local n = each and each > 0 and math.ceil(need / each - 1e-9) or nil
    local cook = tb.eq >= T.damage
    row(out, { id = "H1", rank = cook and 0 or 1, kind = "any", uids = cores,
      fix = each and { label = "ADD RADIATOR", hold = "radPanel" } or nil,
      head = fmt("Heat settles at %d %%: the reactor scrams at %d %%", pct, math.floor(T.scram * 100 + 0.5)),
      text = fmt("At full output, every radiator out and the sun full on them (thermal.settle), it makes %s and sheds %s at 100 %%: the loop settles at %d %%. %s SCRAMs at %d %% and stays down until it cools under %d %%%s. Add %s of radiator%s.",
        hu(tb.Q), hu(tb.S), pct, Cap(nameOf(ctx, cores)), math.floor(T.scram * 100 + 0.5), math.floor(T.restart_T * 100 + 0.5),
        cook and fmt("; past %d %% the hot parts take damage", math.floor(T.damage * 100 + 0.5)) or "",
        hu(need), n and fmt(": %d Radiator Panel%s (%.2f hu each in sunlight)", n, s_(n), each) or "") })
  elseif #cores > 0 or tb.n > 0 then
    row(out, { id = "H1n", sev = "note", kind = "any", uids = cores,
      head = fmt("Heat settles at %d %% at full output", pct),
      text = fmt("%s in, %s out at 100 %%, radiators out in full sun (thermal.settle); reactors scram at %d %%.",
        hu(tb.Q), hu(tb.S), math.floor(T.scram * 100 + 0.5)) })
  end
  -- crew in a reactor's cone (thermal.doseRate, at full output)
  local red, amber = {}, {}
  for _, st in ipairs(tb.seats or {}) do
    if st.inside and (st.rate or 0) > 0 then
      local hrs = 1 / (st.rate * 3600)
      if st.rate * 7200 >= 1 then red[#red + 1] = { uid = st.uid, h = hrs, n = st.blocked or 0 }
      else amber[#amber + 1] = { uid = st.uid, h = hrs, n = st.blocked or 0 } end
    end
  end
  local function worst(list) table.sort(list, function(a, b) return a.h < b.h end) return list[1] end
  if #red > 0 then
    local w = worst(red)
    local u = {}
    for _, r in ipairs(red) do u[#u + 1] = r.uid end
    for _, c in ipairs(cores) do u[#u + 1] = c end
    row(out, { id = "H2", rank = 0, kind = "any", uids = u, fix = { label = "ADD SHIELD", hold = "shadowShield" },
      head = fmt("Crew in the reactor's cone: a lethal dose in %s", w.h >= 1 and fmt("%.1f h", w.h) or fmt("%.0f min", w.h * 60)),
      text = fmt("%s sits %s the %d° radiation cone (thermal.doseRate, full output%s): a lethal dose in %s. Put a Shadow Shield between the core and the crew (it lets through %d %%), or full tanks (%d %% each).",
        Cap(nameOf(ctx, { w.uid })), w.n > 0 and "inside" or "unshielded inside", ctx.libs.thermal.THERMAL.cone_deg,
        w.n > 0 and fmt(", %d part%s in the way", w.n, s_(w.n)) or "",
        w.h >= 1 and fmt("%.1f hours", w.h) or fmt("%.0f minutes", w.h * 60),
        math.floor(T.shield_k * 100 + 0.5), math.floor(T.tank_k * 100 + 0.5)) })
  end
  if #amber > 0 then
    local w = worst(amber)
    row(out, { id = "H2n", sev = "note", kind = "any", uids = { w.uid },
      head = fmt("Shielded crew in the cone: lethal in %.0f h", w.h),
      text = fmt("%s sits in a reactor's cone behind %d part%s: at full output a lethal dose takes %.0f hours (thermal.doseRate). The dose heals at the base.",
        Cap(nameOf(ctx, { w.uid })), w.n, s_(w.n), w.h) })
  end
  -- no rods to fuel the reactors at rollout (rodsAtLaunch fills from the base store)
  if #cores > 0 and ctx.rods then
    local want = 0
    for _, c in ipairs(cores) do
      local p = ctx.parts[c]
      for _, m in ipairs((p and ctx.rec and ctx.libs.electronics and ctx.libs.electronics.modsOf(ctx.rec(c))) or {}) do
        if m.type == "reactor" then want = want + TH.coreOf(m).rack end
      end
    end
    local have = ctx.rods() or 0
    if want > 0 and have < want then
      local F = TH.FUEL_FAB
      row(out, { id = "H3", rank = 1, kind = "any", uids = cores,
        head = have <= 0 and "No fuel rods at the base: the reactor rolls out cold"
          or fmt("%d fuel rod%s at the base for %d slots", have, s_(have), want),
        text = fmt("%s hold%s %d rod%s and the base store has %d: the rack fills from it at rollout (rodsAtLaunch), and an empty core makes nothing. The Materials Intake presses a rod from %d %s ore and $%d in %d game minutes (an Engineer's job).",
          Cap(nameOf(ctx, cores)), #cores == 1 and "s" or "", want, s_(want), have, F.units, F.ore, F.cost, math.floor(F.secs / 60 + 0.5)) })
    end
  end
end

-- Crew roles (docs/crew-and-items.md §2.6): only what a role does today.
function crewRules(ctx, out, k)
  local seated = ctx.seated and ctx.seated() or nil
  if not seated or #seated == 0 then return end
  local names, eng = {}, false
  for _, m in ipairs(seated) do
    names[#names + 1] = fmt("%s (%s%s)", m.name or "crew", m.roleName or "no role", m.level and fmt(" L%d", m.level) or "")
    if m.role == "engineer" then eng = true end
  end
  row(out, { id = "C4", sev = "note", kind = "any", uids = {},
    head = fmt("Crew: %d aboard", #seated),
    text = table.concat(names, ", ") .. "." })
  local reactor = false
  for u, p in pairs(ctx.parts) do
    for _, m in ipairs((ctx.rec and ctx.libs.electronics and ctx.libs.electronics.modsOf(ctx.rec(u))) or {}) do
      if m.type == "reactor" then reactor = true end
    end
  end
  if reactor and not eng then
    local s = flight("ROD_SECS")
    row(out, { id = "C4e", sev = "note", kind = "any", uids = {},
      head = "No Engineer aboard to swap fuel rods",
      text = fmt("A rod swap on EVA takes %.0f s; an Engineer does it in %.0f (vessel_thermal). Seat one in the CREW tab.", s, s * 0.5) })
  end
end

-- ── RUN ─────────────────────────────────────────────────────────────────────
local SEV = { block = 0, warn = 1, note = 2 }
-- wall-clock seconds (the engine's: os.clock counts every thread's CPU there)
function clock() return (app and app.wallClock and app.wallClock()) or (os and os.clock and os.clock()) or 0 end
function sortRows(rows)
  for i, r in ipairs(rows) do r._i = r._i or i end
  table.sort(rows, function(a, b)
    local sa, sb = SEV[a.sev] or 1, SEV[b.sev] or 1
    if sa ~= sb then return sa < sb end
    if (a.rank or 2) ~= (b.rank or 2) then return (a.rank or 2) < (b.rank or 2) end
    return a._i < b._i
  end)
  return rows
end

function run(ctx)
  local t0 = clock()
  CTX = ctx
  ctx.crew = ctx.crew or {}
  local A = ctx.libs.aero
  local out = {}
  if not (A and ctx.parts and next(ctx.parts)) then CTX = nil return { rows = out } end
  local k = { kind = (ctx.mode and ctx.mode.mode) or "rocket" }
  -- one model and one set of records for every aero rule
  k.frame = nose_frame(ctx, A)
  k.com, k.mass = com(ctx)
  k.tyres = tyres(ctx)
  k.gear, k.wings, k.jetsAll = {}, {}, {}
  for u, p in pairs(ctx.parts) do
    local a = A.parse(p.def.af)
    if a and a.gear then k.gear[#k.gear + 1] = u end
    if a and a.cockpit and (not k.cockpit or u < k.cockpit) then k.cockpit = u end
    if a and a.jet then k.jetsAll[#k.jetsAll + 1] = u end
  end
  table.sort(k.gear); table.sort(k.jetsAll)
  -- one aero model for every aero rule (aircraft only: a rocket's fins and a
  -- rover's body are the flight's business, not the check's)
  local plane = k.kind == "aircraft" or k.cockpit ~= nil or #k.jetsAll > 0
  if plane then
    k.recs = aero_recs(ctx, false, true)
    k.model = A.build(aero_recs(ctx, false, false))
    for _, s in ipairs(k.model.surfs) do if not s.ctl then k.wings[#k.wings + 1] = s.uid end end
    table.sort(k.wings)
  end
  local CM = ctx.libs.craft_mode
  -- (Auto's figures, for C1's "too little wing": only a jet Auto calls a rocket)
  if CM and CM.autoOf and k.kind == "rocket" and #k.jetsAll > 0 and not (ctx.mode and ctx.mode.set) then
    local recs = {}
    for u, p in pairs(ctx.parts) do
      local d = p.def
      recs[u] = { uid = u, af = d.af, wheel = d.wheel, mass = d.mass, fuel = d.fuel, fuel_t = ctx.fuel_t, kind = d.kind,
                  seat = d.seat, front = d.front, thrust = d.thrust or 0, decouple = d.decouple, dock = d.dock, parent = p.parent or 0 }
    end
    local _, _, fig = CM.autoOf(recs)
    k.fig = fig
  end
  k.branch = {}
  for u, p in pairs(ctx.parts) do
    if p.def.radial and p.def.decouple and ctx.drops then for v in pairs(ctx.drops(u) or {}) do k.branch[v] = true end end
  end
  k.sec, k.cuts = sections(ctx, k.branch)
  -- (ctx.prof: a table to time each rule into, for the perf probe)
  local prof, tl = ctx.prof, clock
  local function R(name, f)
    if prof and tl then local t = tl(); f(ctx, out, k); prof[name] = (prof[name] or 0) + (tl() - t) * 1000
    else f(ctx, out, k) end
  end
  R("kind", rule_kind)
  R("probe", rule_probe)
  if plane then R("jets", rule_jets) end
  R("feed", rule_feed)
  R("upright", rule_upright)
  if plane then
    R("margin", rule_margin)
    R("stall", rule_stall)
    R("controls", rule_controls)
    R("gear", rule_gear)
  end
  R("wheels", rule_wheels)
  R("chutes", rule_chutes)
  R("staging", rule_staging)
  R("fairings", rule_fairings)
  -- PHASE 4 hooks: crew roles (§3.4) and heat / RTG (§3.5) add their rows here
  for _, h in pairs(ctx.hooks or {}) do
    if type(h) == "function" then pcall(h, ctx, out, k) end
  end
  CTX = nil
  local res = { rows = out, kind = k.kind, site = ctx.site, frame = k.frame, margin = k.margin, stall = k.stall,
                airf = k.airf, jetT0 = k.jetT0, ssf = k.ssf, chute_v = k.chute_v }
  res.ms = (clock() - t0) * 1000
  return res
end
