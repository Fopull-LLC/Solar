-- MISSIONS — the contracts that turn a sandbox into a company.
--
-- One accepted contract at a time. Its goals are watched live against the craft
-- you're actually flying; every goal that latches stays latched for the flight,
-- so "reach 2,000 m AND land intact" is a thing you do in one trip rather than
-- two states that can never be true at once. Complete them all and Ops pays out
-- the moment you're home.
--
-- Two sources of work:
--
--   THE LADDER (`CATALOGUE`) — eight fixed contracts that teach the game, from
--   a first hop to docking in orbit. Rewards rise with difficulty and are paced
--   against research prices (research.lua), so each rung pays for the rocket it
--   needs and the next unlock or two.
--
--   THE GENERATOR (`gen_*` below) — contracts rolled from the system you
--   actually got: survey, orbit, land on, plant a beacon on, haul a material
--   home from, recover a probe from, or deliver cargo into orbit of a REAL body
--   named on the system generator's roster. They open in tiers by standing
--   (company.lua) and are priced by the trip — Δv, distance, landing gravity.
--   Over all of it sits the CHARTER: set foot on every world in the system.
--
-- Goals are declarative and the tracker knows a handful of kinds, so a new
-- contract is a table entry — no new code:
--
--   altitude  frac       climb this far toward the edge of home's influence
--   speed     value      hit this surface speed (m/s)
--   orbit     frac body? periapsis above that height — a real orbit, not a lob
--                        (around home, or around a NAMED body)
--   soi       body       fly into that body's sphere of influence (a flyby)
--   land      body?      touch down intact (optionally on a NAMED body)
--   flag      body       stand on that body's surface on foot — plants the
--                        company beacon; counts once you've done it
--   cargo     body kg    be in orbit of that body with this much in the hold
--   dock                 latch onto another craft in flight
--   recover              bring the craft home and recover it at the base
--   deliver   mat/class  have this much of a material in the base WAREHOUSE
--             kg?        (units, or kilograms when `kg` is given)
--   sample    mat        have HELD this material at all — the discovery set
--
--   after = i            this goal only counts once goal i is met (so "land on
--                        Nami, THEN recover the craft" can't be met backwards)
--
-- `deliver`, `sample`, `recover` and `flag` latch PERMANENTLY (they're things
-- you did, not states of a flight); every other kind latches for the current
-- flight only, so a multi-goal trip has to be one trip.
--
-- Cross-script:  local m = findScript("missions")
--                m.offers()  m.accept(id)  m.abandon()  m.activeLine()
--                m.upcoming()  m.charter()  m.charterLine()  m.tierLine()

-- ── FLIGHT GOALS ARE SIZED TO THE SYSTEM YOU GOT ────────────────────────────
--
-- These used to name their altitudes in metres: 2,000 for a first flight,
-- 25,000 for the next, a 20 km periapsis for an orbit. Those are Earth numbers,
-- and the system is GENERATED. Planets come out 100–230 m in radius with a
-- sphere of influence of about a dozen body radii, so on the save this was
-- reported from — Umunquo, 185 m body radius, 1,422 m SOI — the highest
-- altitude that EXISTS above the home planet is 1,237 m, and the first contract
-- asked for two thousand. "The High Road" wanted twenty-five kilometres and
-- "Made Orbit" a periapsis four times beyond the SOI: impossible on every seed,
-- not just this one.
--
-- So a flight goal names a FRACTION of the room it actually has — ground to the
-- edge of that world's influence — and the metres are resolved from the body
-- at read time. The LABEL is generated from the same number as the check, so
-- the card and the tracker can never quote different targets.
--
-- ── THE LADDER IS PRICED BY DIFFICULTY ──────────────────────────────────────
--
-- "Bring It Home" (land near the base and recover) used to pay $12,000 against
-- "The High Road"'s $9,000, and the first rung alone ($4,500) bought half the
-- research catalogue. Now:
--
--   Bring It Home $1,800 < Field Botany $2,200 < First Flight $2,500
--     < Prospector $2,800 < The High Road $5,000 < Deep Core $6,500
--     < Made Orbit $9,000 < Rendezvous $16,000
--
-- …and the generated work after it runs from about $6k (a flyby of your own
-- moon) to six figures (bring a probe home from the far planet).
local CATALOGUE = {
  {
    id = "firstflight", title = "First Flight",
    brief = "Get something off the pad and bring the pod back in one piece.\n" ..
            "Ops isn't asking for elegance.",
    reward = 2500, rep = 1,
    goals = {
      { kind = "altitude", frac = 0.15, label = "Reach %s" },
      { kind = "land", label = "Land with the pod intact" },
    },
  },
  {
    id = "recovery", title = "Bring It Home",
    brief = "Ops is tired of writing off hulls. Land near the base and RECOVER\n" ..
            "the craft — you get most of the hardware's value back.",
    reward = 1800, rep = 1, requires = "firstflight",
    goals = {
      { kind = "recover", label = "Recover a craft at the base" },
    },
  },
  {
    id = "botany", title = "Field Botany",
    brief = "Cut samples of whatever grows down there — the labs will take any\n" ..
            "plant matter, and the stranger it is the better they like it.",
    reward = 2200, rep = 1, requires = "firstflight",
    goals = {
      { kind = "deliver", class = "flora", value = 20,
        label = "20 units of plant matter in the warehouse" },
    },
  },
  {
    id = "prospect", title = "Prospector",
    brief = "The board wants to know the rock is worth landing on. Mine ore,\n" ..
            "fly it home and put 30 units through the depot.",
    reward = 2800, rep = 1, requires = "firstflight",
    goals = {
      { kind = "deliver", class = "ore", value = 30,
        label = "30 units of ore in the warehouse" },
    },
  },
  {
    id = "highroad", title = "The High Road",
    brief = "Most of the way to the edge of this world's pull. The air is thin\n" ..
            "enough up there that the board wants to see the telemetry before\n" ..
            "they sign anything bigger.",
    reward = 5000, rep = 2, requires = "firstflight",
    goals = {
      { kind = "altitude", frac = 0.55, label = "Reach %s" },
      { kind = "land", label = "Land intact" },
    },
  },
  {
    id = "deepcore", title = "Deep Core",
    brief = "Resonant crystal only forms twenty metres down and it does not\n" ..
            "come up with a shovel. Take the laser and dig.",
    reward = 6500, rep = 2, requires = "prospect",
    goals = {
      { kind = "sample", mat = "crystal", label = "Find resonant crystal" },
      { kind = "deliver", mat = "crystal", value = 5,
        label = "5 crystal in the warehouse" },
    },
  },
  {
    id = "orbit", title = "Made Orbit",
    brief = "Not a lob — an ORBIT. Get your periapsis clear of the atmosphere\n" ..
            "so the craft comes back around on its own.",
    reward = 9000, rep = 2, requires = "highroad",
    goals = {
      { kind = "orbit", frac = 0.10, label = "Periapsis above %s" },
    },
  },
  {
    id = "rendezvous", title = "Rendezvous",
    brief = "Two craft, one seam. Undock a module in flight and latch it back\n" ..
            "on — the manoeuvre every station and every return trip is built of.",
    reward = 16000, rep = 3, requires = "orbit",
    goals = {
      { kind = "dock", label = "Dock two craft in flight" },
      { kind = "land", label = "Bring the stack home intact" },
    },
  },
}

-- ════════════════════════════════════════════════════════════════════════════
-- THE PROGRAMME — the company's milestones, KSP-career style
-- ════════════════════════════════════════════════════════════════════════════
--
-- Contracts are work you SIGN, one at a time. The programme is the company's
-- own direction, and it runs alongside whatever is on the books: nothing to
-- sign, nothing to abandon, it counts as it happens. One arc:
--
--   1  First Steps     cut a plant, mine some ore                     (home)
--   2  Rare Finds      a plant from a ravine floor, one from a peak,
--                      a Star Geode from an underground pocket         (home)
--   3  Relay Network   ground relays until 25 / 50 / 80 % of the home
--                      planet's ground has a link home                 → Relay Dish
--   4  Eyes in the Sky relay satellites in orbit; 95 % sky coverage   → Deep Space Dish
--   5  Beyond          link a moon, then another planet
--
-- Each goal can pay on its own (`pay`, `grant`) — a staged goal is a reward
-- per stage — and the milestone pays its own reward when the last goal ticks.
-- Every programme goal LATCHES: coverage that dips after a beacon is picked up
-- never takes a paid stage back.
--
-- Goal kinds (on top of the contract kinds `sample` and friends):
--
--   sample   class=     have held ANY material of this class (flora, ore)
--   rare     niche=     a rare plant from that niche cut ON THE HOME WORLD
--            alt={…}    (`rare.cut.<home>`). If the home world has none in that
--                       niche, the first `alt` niche it does have stands in.
--   sample   home=true  (mat = "geode") a Star Geode out of one of the home
--                       world's pockets (`rare.ore.<home>`), not just held.
--   groundcov frac      comms.coverage(home).ground ≥ frac
--   skycov   frac       comms.coverage(home).sky ≥ frac
--   orbitrelay n        comms.relayStats().orbit[home] ≥ n
--   linked   class=     a body of that class (moon / planet) is in
--                       comms.linkedBodies()
--
-- The comms numbers come from the relay network (comms.lua); they are polled
-- once a second, guarded, and a network that does not report yet is a goal
-- that waits, never an error.
--
-- State: `prog.done` (milestone → true), `prog.perm` (milestone → goal index →
-- true), `prog.paidAt` (the last announcement, for the card).

PROGRAMME = {
  {
    id = "first_steps", title = "First Steps",
    brief = "Before the board signs off anything that flies, it wants to know the\n" ..
            "colony can feed itself: something cut, something mined.",
    reward = 400, rep = 0,
    goals = {
      { kind = "sample", class = "flora", label = "Cut a plant (Harvest Cutter, key 2)" },
      { kind = "sample", class = "ore", label = "Mine some ore (Mining Laser, key 1)" },
    },
  },
  {
    id = "rare_finds", title = "Rare Finds", requires = "first_steps",
    brief = "The survey flagged plants that grow in one kind of place only, and a\n" ..
            "ringing in the rock that means geodes. The labs want a specimen of each.\n" ..
            "Each rare plant stands under a beam of light. Open the Tracking Station\n" ..
            "at the base to survey the planet: it maps them all.",
    reward = 1200, rep = 1, grants = { "battery" },
    goals = {
      { kind = "rare", niche = "ravine", alt = { "river", "lake", "cave" }, pay = 500 },
      { kind = "rare", niche = "peak", alt = { "cave", "lake", "river" }, pay = 500 },
      { kind = "sample", mat = "geode", home = true, pay = 700, label = "A Star Geode from an underground pocket" },
    },
  },
  {
    id = "relay_net", title = "Relay Network", requires = "first_steps",
    brief = "A craft past the horizon is a craft nobody can talk to. Ring the planet\n" ..
            "with Relay Beacons — cheap, and each one only has to see the last —\n" ..
            "until most of the ground has a link home.",
    reward = 3000, rep = 2, grants = { "dish" },
    goals = {
      { kind = "groundcov", frac = 0.25, pay = 1200, label = "25% of the ground covered" },
      { kind = "groundcov", frac = 0.50, pay = 2000, grant = "probe", label = "50% of the ground covered" },
      { kind = "groundcov", frac = 0.80, pay = 3500, label = "80% of the ground covered" },
    },
  },
  {
    id = "sky", title = "Eyes in the Sky", requires = "relay_net",
    brief = "Ground relays need hills and line of sight. Satellites don't: put relays\n" ..
            "in orbit until every point of the sky over home can reach the network.",
    reward = 12000, rep = 3, grants = { "dishL" },
    goals = {
      { kind = "orbitrelay", n = 1, pay = 3000, label = "A relay satellite in orbit" },
      { kind = "skycov", frac = 0.60, pay = 3000, label = "60% sky coverage" },
      { kind = "skycov", frac = 0.95, pay = 5000, label = "95% sky coverage" },
    },
  },
  {
    id = "beyond", title = "Beyond", requires = "sky",
    brief = "A network that ends at home's sky is a local one. Put a relay on or\n" ..
            "around another world and close the link back.",
    reward = 30000, rep = 4,
    goals = {
      { kind = "linked", class = "moon", pay = 8000, label = "Link a moon to the network" },
      { kind = "linked", class = "planet", pay = 15000, label = "Link another planet to the network" },
    },
  },
}

-- Published for the card and the board: the network numbers as last polled.
-- { api = bool, ground = 0..1, sky = 0..1, orbit = n, linked = { names }, t }
progNet = { api = false, ground = 0, sky = 0, orbit = 0, linked = {}, t = -1 }

-- Published for the panels.
active = nil       -- the accepted contract's id
progress = ""      -- one-line summary of the active contract

-- The contract that just paid, for the card to announce. `log` writes to the
-- Console and the Console is not on screen, so a contract that pays itself
-- silently is a contract nobody can tell they finished.
lastPaid = nil

local co = nil
local flight_seen = {}   -- goal index → true once met on THIS flight
local perm = {}          -- goal index → true once done, for good (see PERMANENT)
local best = {}          -- goal index → the closest this flight has come
local last_piloting = false

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063). `goalLines` is now read every frame by the objectives
-- card AND ten times a second by the flight HUD, and a delivery goal asks the
-- warehouse what is in it — so an uncached lookup here is a scene scan per goal
-- per frame, which is exactly the shape this project spent a release removing.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- ── the scale of the world you live on ──────────────────────────────────────

-- The world the base is on. Every flight goal is measured against it, and it
-- does not change mid-flight, so a target quoted on the card at the pad is the
-- same target the tracker checks over the far side of the planet.
--
-- THREE ANSWERS, in order, because there must never be a state where no world
-- can be named: an unresolvable target is a goal that can never tick, and that
-- is precisely the bug this whole block exists to fix. `base.body` is only
-- written once the colony is sited, so the first minutes of a save have none —
-- and the last resort is simply the world we are standing on.
local here_name = nil   -- refreshed by `update` from the tracker's own node

local function usable(b)
  return (b and (b.soi or -1) > b.radius) and b or nil
end

local function home_body()
  local bf = ref("base_facilities")
  if bf and bf.baseBody then
    local b = usable(space.body(bf.baseBody))
    if b then return b end
  end
  local name = save.get("base.body")
  if type(name) == "string" then
    local b = usable(space.body(name))
    if b then return b end
  end
  return here_name and usable(space.body(here_name)) or nil
end

-- Ground → the edge of a world's influence, in metres. Everything a flight
-- above that world can do fits inside this number. With no name it is HOME
-- (nil until a base is sited). A moon's influence is small and is the engine's
-- own (Laplace) radius; a body reporting none gets four of its radii.
local function ceiling(name)
  local b
  if name then b = space.body(name) else b = home_body() end
  if not b then return nil end
  local soi = b.soi or -1
  if soi <= b.radius then soi = b.radius * 5 end
  return math.max(1.0, soi - b.radius)
end

local function fmt_m(v)
  if v >= 1000 then return string.format("%.1f km", v / 1000) end
  return string.format("%.0f m", v)
end

-- What this goal is asking for, in metres. `value` is still honoured (speed
-- goals are in m/s and don't scale); `frac` is a share of the ceiling above.
-- nil means "not answerable yet" — no base, so no home world to measure from.
--
-- Rounded DOWN to a number a person would say — "Reach 150 m", not "Reach
-- 217 m", which reads like a bug. Down, so the rounding can only make a target
-- easier, never push it past the room the world has.
local function nice(v)
  local step = v < 100 and 10 or (v < 500 and 50 or 100)
  return math.max(step, math.floor(v / step) * step)
end

-- The top of a world's air (m over its radius), 0 if it has none. An ORBIT
-- goal is "periapsis clear of the atmosphere": on a deep-air world (scale 4,
-- air up to a radius high) 10 % of the room to the SOI can sit only just
-- above the top, so the target is never under the top plus a margin.
local function air_top(name)
  local b = name and space.body(name) or (not name and home_body()) or nil
  local w = b and save.get("world." .. b.name)
  if not (w and (w.atmo or 0) > 0.01) then return 0 end
  return w.atmoHeight or 0
end

local function target_of(g)
  if g.value then return g.value end
  if not g.frac then return nil end
  local c = ceiling(g.body)
  if not c then return nil end
  local t = nice(c * g.frac)
  if g.kind == "orbit" or g.kind == "cargo" then
    local top = air_top(g.body)
    if top > 0 and t < top * 1.08 then
      -- rounded UP here: the target must clear the air, not just reach it
      local step = top < 500 and 50 or 100
      t = math.ceil(top * 1.08 / step) * step
    end
  end
  return t
end

-- The goal's text with its resolved target in it. A label with no `%s` is a
-- goal with nothing to fill in (landing, docking, a delivery).
function goalLabel(g)
  if not g.label or not g.label:find("%%s") then return g.label or "" end
  local t = target_of(g)
  return string.format(g.label, t and fmt_m(t) or "…")
end

-- Is goal `i` met? Either it latched on this flight, or it's one of the ones
-- you can't un-do.
local function met(i)
  return flight_seen[i] or perm[i] or false
end

local function company()
  if not co or not co.node or not co.node.valid then co = findScript("company") end
  return co
end

local function rep_now()
  local c = company()
  return (c and c.rep and c.rep()) or 0
end

local function done_set()
  return save.get("mission.done") or {}
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE CONTRACT GENERATOR
-- ════════════════════════════════════════════════════════════════════════════
--
-- What it reads: `save.system.home`, the roster system_generator publishes when
-- it rolls the save's own system — every body with its archetype, radius, µ and
-- what it orbits at what distance. (An older save without one is rebuilt from
-- `space.bodies()` plus the per-world records: a body's parent is the smallest
-- sphere of influence that holds it.) Neighbour systems are never on it.
--
-- What it plans: for each body X, a trip from the base — climb to a low orbit
-- at home, transfer to X, capture into orbit of X, land, and the way back —
-- as Δv, by Hohmann transfers and patched conics. Δv alone undersells distance
-- in this system (escaping a 185 m planet costs about 18 m/s, so the next
-- planet looks barely harder than your own moon), so distance is its own term,
-- and landing gravity and airlessness (no parachutes) are a third.
--
--   reward = base[kind] × (Δv / Δv_to_orbit_at_home)^1.3 × distance^0.8 × gravity
--            × standing   (company.rewardMult: +2% a point)
--   rep    = 1 … 5 by the same difficulty
--
-- What it offers: the Ops Board holds a few generated contracts at once — more
-- as your standing grows — rolled deterministically from the save's system and
-- a sequence number, so a reload shows the same board. One-shot work (survey,
-- orbit, first landing, the beacon) is never offered twice for the same body;
-- hauls, probe recoveries and supply runs come round again.

-- Kinds, their base pay at "one orbit's worth of Δv", and what each asks for.
-- `once` = one contract of this kind per body, ever.
local GEN_KINDS = {
  survey = { base = 2600, once = true },
  orbit  = { base = 3000, once = true },
  land   = { base = 3400, once = true },
  flag   = { base = 3800, once = true },
  haul   = { base = 3400 },
  rescue = { base = 3800 },
  cargo  = { base = 6000 },
}
local KIND_ORDER = { "survey", "orbit", "land", "flag", "haul", "rescue", "cargo" }

-- Which kinds open where, by standing level (company.standing: 2 Contractor,
-- 3 Trusted, 4 Prime) and the ladder rung you need to have flown. `moon` is a
-- moon of the home world, `planet` another planet, `far` a moon of another
-- planet, `home` the home world itself (supply runs to your own orbit).
TIERS = {
  { level = 2, needs = "highroad", name = "Local space",
    what = "surveys, landings and beacons close to home (your moons, or the nearest planet)",
    kinds = { moon = { "survey", "orbit", "land", "flag", "haul", "rescue" } } },
  { level = 3, needs = "orbit", name = "Interplanetary",
    what = "flybys, orbits and landings on the other planets; supply runs",
    kinds = { planet = { "survey", "orbit", "land" },
              home = { "cargo" }, moon = { "cargo" } } },
  { level = 4, needs = "orbit", name = "Deep field",
    what = "beacons, hauls and recoveries across the whole system",
    kinds = { planet = { "flag", "haul", "rescue", "cargo" },
              far = { "survey", "orbit", "land", "flag", "haul", "rescue" } } },
}

-- How many generated contracts the board holds, by standing level.
local SLOTS = { [0] = 0, [1] = 0, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }

-- The long-term goal: a beacon of the company's on every world in the system.
local CHARTER_REWARD, CHARTER_REP = 250000, 5

-- ── the roster ──────────────────────────────────────────────────────────────

local function world_kind(name)
  local w = save.get("world." .. name)
  return (type(w) == "table" and w.kind) or "barren", w
end

-- Older saves (and harnesses) have no published roster: rebuild one from what
-- the rails know. A body's parent is the smallest sphere of influence holding
-- it; the home system is whatever hangs off the one infinite-SOI root.
local function derive_roster()
  if not space.bodies then return nil end
  local all = space.bodies() or {}
  local star = nil
  for _, b in ipairs(all) do if (b.soi or 0) < 0 then star = b end end
  if not star then return nil end
  local function parent_of(b)
    local best, bs = nil, math.huge
    for _, p in ipairs(all) do
      if p ~= b and p.radius > b.radius then
        local s = (p.soi or 0) < 0 and math.huge or (p.soi or 0)
        local d = math.sqrt((b.x - p.x) ^ 2 + (b.y - p.y) ^ 2 + (b.z - p.z) ^ 2)
        if s > 0 and d < s and (not best or s < bs) then best, bs = p, s end
      end
    end
    return best
  end
  local out = {}
  for _, b in ipairs(all) do
    local kind, w = world_kind(b.name)
    if b ~= star and w then
      local p = parent_of(b)
      if p and (p == star or parent_of(p) == star) then
        out[#out + 1] = { name = b.name, kind = kind, parent = p.name,
          a = math.sqrt((b.x - p.x) ^ 2 + (b.y - p.y) ^ 2 + (b.z - p.z) ^ 2),
          radius = (w and w.radius) or b.radius, relief = (w and w.relief) or 0,
          mu = b.mu, atmo = (w and w.atmo) or 0, sea = (w and w.sea) or 0 }
      end
    end
  end
  if #out == 0 then return nil end
  return { star = star.name, mu = star.mu, bodies = out }
end

-- The roster, indexed. Cached by the published table's identity, so it costs
-- nothing per frame.
local roster_cache, roster_src = nil, nil
local function roster()
  local s = save.get("system.home")
  if type(s) ~= "table" or type(s.bodies) ~= "table" or #s.bodies == 0 then
    s = nil
  end
  if s and s == roster_src and roster_cache then return roster_cache end
  local src = s or derive_roster()
  if not src then return nil end
  local by = {}
  for _, b in ipairs(src.bodies) do by[b.name] = b end
  roster_cache = { star = src.star, mu = src.mu, bodies = src.bodies, by = by }
  roster_src = s
  return roster_cache
end

-- Which world is home for planning: the base's, else the roster's first planet
-- (the spawn world), else nothing.
local function home_entry(R)
  local hb = home_body()
  if hb and R.by[hb.name] then return R.by[hb.name] end
  local name = save.get("base.body")
  if type(name) == "string" and R.by[name] then return R.by[name] end
  for _, b in ipairs(R.bodies) do
    if b.parent == R.star then return b end
  end
  return nil
end

-- What X is, seen from home: "home", "moon" (of home), "planet", "far".
local function class_of(R, home, b)
  if b.name == home.name then return "home" end
  if b.parent == home.name then return "moon" end
  if b.parent == R.star then return "planet" end
  return "far"
end

-- ── trip planning: Δv by Hohmann + patched conics ───────────────────────────

local function vcirc(mu, r) return math.sqrt(mu / math.max(r, 1e-6)) end
local function low_r(b) return b.radius + (b.relief or b.radius * 0.06) * 2 + 5 end
local function grav(b) return b.mu / (b.radius * b.radius) end

local function hohmann(mu, r1, r2)
  local a = (r1 + r2) / 2
  local dv1 = math.abs(math.sqrt(mu * (2 / r1 - 1 / a)) - vcirc(mu, r1))
  local dv2 = math.abs(vcirc(mu, r2) - math.sqrt(mu * (2 / r2 - 1 / a)))
  return dv1, dv2
end

-- From a low orbit of `b` to a hyperbolic excess speed `vinf` (or back down
-- into one): the Oberth burn at periapsis.
local function eject(b, vinf)
  local r = low_r(b)
  return math.sqrt(vinf * vinf + 2 * b.mu / r) - vcirc(b.mu, r)
end

-- A world with air lets parachutes do most of a landing; an airless one is
-- powered all the way down.
local function descent(b)
  local v = vcirc(b.mu, low_r(b))
  return ((b.atmo or 0) > 0.15) and v * 0.45 or v * 1.15
end

-- The trip from home to X: each leg in m/s, plus the distance factor.
--   ascent   home surface to low orbit (losses included)
--   out      leaving home orbit toward X (a flyby needs only this)
--   capture  slowing into a low orbit of X
--   down     landing on X
--   up       climbing back off X to low orbit
--   back     from X's orbit to home's atmosphere (aerobraking does the rest)
function plan(R, home, b)
  local p = { ascent = vcirc(home.mu, low_r(home)) * 1.25, out = 0, capture = 0, flyby = 0,
              down = descent(b), up = vcirc(b.mu, low_r(b)) * 1.2, back = 0, dist = 1.0 }
  local cls = class_of(R, home, b)
  if cls == "home" then
    p.down, p.up = descent(home), p.ascent
  elseif cls == "moon" then
    local d1, d2 = hohmann(home.mu, low_r(home), b.a)
    p.out = d1
    p.capture = eject(b, d2)
    p.back = eject(b, d2) + d1 * 0.5
  else
    -- Out to the planet (X itself, or the planet X is a moon of).
    local P = (cls == "planet") and b or R.by[b.parent]
    if not P then return nil end
    local v1, v2 = hohmann(R.mu, home.a, P.a)
    p.out = eject(home, v1)
    local capP = eject(P, v2)
    if cls == "planet" then
      p.capture = capP
    else
      local d1, d2 = hohmann(P.mu, low_r(P), b.a)
      p.capture = capP + d1 + eject(b, d2)
      -- A flyby of a moon of another planet still has to get into that
      -- planet's grip and out to the moon's orbit.
      p.flyby = capP + d1
    end
    p.back = p.capture + v1 * 0.5
    local ratio = math.max(P.a / home.a, home.a / P.a)
    p.dist = 1.0 + 1.5 * math.log(ratio) / math.log(2)
  end
  return p
end

-- Δv a kind of job needs, by its legs.
local function need(p, kind)
  if kind == "survey" then return p.ascent + p.out + p.flyby end
  if kind == "orbit" or kind == "cargo" then return p.ascent + p.out + p.capture end
  if kind == "land" or kind == "flag" then return p.ascent + p.out + p.capture + p.down end
  -- a round trip: there, down, up again, and home
  return p.ascent + p.out + p.capture + p.down + p.up + p.back
end

-- Materials an archetype can yield that the home world's cannot: what a haul
-- contract asks for, because hauling home what you can dig at home is not a
-- trip. Ice from a frost moon to a canyon world, obsidian and sulfur from a
-- lava planet. nil when X has nothing home lacks.
local function unique_mat(home, b)
  local mats = ref("materials")
  if not (mats and mats.oresOf) then return nil end
  local have = {}
  for _, m in ipairs(mats.oresOf(home.kind)) do have[m] = true end
  local best = nil
  for _, m in ipairs(mats.oresOf(b.kind)) do
    if not have[m] and (not best or (mats.value(m) > mats.value(best))) then best = m end
  end
  return best
end

-- Round a reward to a number that reads like a price.
local function price(v)
  local step = v < 10000 and 100 or (v < 100000 and 500 or 1000)
  return math.max(step, math.floor(v / step + 0.5) * step)
end

-- Build one contract spec for (kind, body). Pure data — it goes in the save.
-- nil when the kind can't be done there (nothing to haul, no plan).
function genSpec(kind, bname, seq)
  local R = roster()
  if not R then return nil end
  local home, b = home_entry(R), R.by[bname]
  if not (home and b) then return nil end
  local p = plan(R, home, b)
  if not p then return nil end
  local K = GEN_KINDS[kind]
  local dv = need(p, kind)
  local ratio = dv / math.max(p.ascent, 1e-3)
  local lands = (kind == "land" or kind == "flag" or kind == "haul" or kind == "rescue")
  local gfac = 1.0
  if lands then
    gfac = 1.0 + 0.35 * math.min(2.0, grav(b) / math.max(grav(home), 1e-3))
    if (b.atmo or 0) <= 0.15 then gfac = gfac + 0.25 end
  end
  local diff = ratio ^ 1.3 * p.dist ^ 0.8 * gfac
  local X = b.name
  local g, title, brief = nil, nil, nil
  local extra = 0
  local cls = class_of(R, home, b)
  local what = (cls == "moon" or cls == "far") and "moon" or "world"
  if kind == "survey" then
    title = "Survey: " .. X
    brief = string.format("The board wants eyes on %s. Fly close enough that its gravity\n" ..
      "takes over from %s's — a flyby is enough; nobody needs you to stop.", X, home.name)
    g = { { kind = "soi", body = X, label = "Enter " .. X .. "'s sphere of influence" } }
  elseif kind == "orbit" then
    title = "Orbital survey: " .. X
    brief = string.format("Mapping %s needs a full pass from a stable orbit. Capture, and\n" ..
      "keep the periapsis clear of the ground.", X)
    g = { { kind = "orbit", body = X, frac = 0.10, label = "Orbit " .. X .. ", periapsis above %s" } }
  elseif kind == "land" then
    title = "First landing: " .. X
    brief = string.format("Nobody has touched down on %s. Put a craft on the surface,\n" ..
      "intact and stopped.%s", X,
      (b.atmo or 0) <= 0.15 and " There's no air: the chutes won't help." or "")
    g = { { kind = "land", body = X, label = "Land intact on " .. X } }
  elseif kind == "flag" then
    title = "Plant a beacon: " .. X
    brief = string.format("Stake the claim. Land on %s, step out, and stand on it — the\n" ..
      "suit plants the company beacon. It counts toward the Charter.", X)
    g = { { kind = "flag", body = X, label = "Set foot on " .. X .. " (plants the beacon)" } }
  elseif kind == "haul" then
    local mat = unique_mat(home, b)
    if not mat then return nil end
    local mats = ref("materials")
    local kg = (cls == "moon") and 30 or 80
    extra = (mats and mats.value(mat) or 0) / math.max((mats and mats.kg(mat)) or 1, 0.1) * kg * 3
    local mname = (mats and mats.label(mat)) or mat
    title = string.format("Haul: %s from %s", mname, X)
    brief = string.format("%s has %s and %s does not. Land, cut or dig it, fly it home\n" ..
      "and put %d kg through the depot.%s", X, mname, home.name, kg,
      kg > 60 and " That is more than a suit carries — bring a Cargo Bay." or "")
    g = { { kind = "flag", body = X, label = "Set foot on " .. X },
          { kind = "deliver", mat = mat, kg = kg, after = 1,
            label = string.format("%d kg of %s in the warehouse", kg, mname) } }
  elseif kind == "rescue" then
    title = "Recovery: the " .. X .. " probe"
    brief = string.format("A survey lander on %s stopped answering. Land there, take its\n" ..
      "logger aboard, and bring the craft home to be RECOVERED at the base.", X)
    g = { { kind = "land", body = X, label = "Land on " .. X .. " and collect the logger" },
          { kind = "recover", after = 1, label = "Fly it home and recover the craft at the base" } }
  elseif kind == "cargo" then
    local kg = (cls == "home") and 150 or 200
    title = string.format("Supply run: %s orbit", X)
    brief = string.format("A relay in orbit of %s needs %d kg of anything heavy. Fill a\n" ..
      "Cargo Bay (load it from your suit pack at the craft) and make orbit with it aboard.", X, kg)
    g = { { kind = "cargo", body = X, kg = kg, frac = 0.10,
            label = string.format("Orbit %s with %d kg in the hold, periapsis above %%s", X, kg) } }
  end
  if not g then return nil end
  local reward = price((K.base * diff + extra) * (company() and company().rewardMult
    and company().rewardMult() or 1.0))
  local rp = math.max(1, math.min(5, math.floor(0.5 + math.log(diff * 2) / math.log(2))))
  return { id = string.format("g%d-%s-%s", seq or 0, kind, X), gen = true,
           key = kind .. ":" .. X, kind = kind, body = X,
           title = title, brief = brief, reward = reward, rep = rp,
           goals = g, dv = math.floor(dv + 0.5), diff = diff }
end

-- ── the board ───────────────────────────────────────────────────────────────

local function standing_level()
  local c = company()
  if c and c.standing then return c.standing().level end
  local r = rep_now()
  return (r >= 25 and 5) or (r >= 15 and 4) or (r >= 8 and 3) or (r >= 3 and 2) or 1
end

-- The tiers you have opened, as a set of index → true.
local function open_tiers()
  local lvl, done = standing_level(), done_set()
  local out = {}
  for i, t in ipairs(TIERS) do
    if lvl >= t.level and done[t.needs] then out[i] = true end
  end
  return out
end

-- Every (kind, body) the opened tiers allow, in a stable order.
local function candidates()
  local R = roster()
  if not R then return {} end
  local home = home_entry(R)
  if not home then return {} end
  local open = open_tiers()
  local allow = {}   -- class → kind → true
  for i, t in ipairs(TIERS) do
    if open[i] then
      for cls, ks in pairs(t.kinds) do
        allow[cls] = allow[cls] or {}
        for _, k in ipairs(ks) do allow[cls][k] = true end
      end
    end
  end
  -- A home world with NO moon would leave Local space empty, and a Contractor
  -- with nothing on the board. Then the nearest planet stands in for the moon:
  -- a flyby and an orbit of it are the local work.
  local stand_in = nil
  if open[1] then
    local has_moon = false
    for _, b in ipairs(R.bodies) do if b.parent == home.name then has_moon = true end end
    if not has_moon then
      local bd = math.huge
      for _, b in ipairs(R.bodies) do
        if b.parent == R.star and b.name ~= home.name and b.a and home.a then
          local d = math.abs(math.log(b.a / home.a))
          if d < bd then stand_in, bd = b.name, d end
        end
      end
    end
  end
  local gdone = save.get("mission.gdone") or {}
  local out = {}
  for _, b in ipairs(R.bodies) do
    local cls = class_of(R, home, b)
    for _, k in ipairs(KIND_ORDER) do
      if (allow[cls] and allow[cls][k])
         or (b.name == stand_in and (k == "survey" or k == "orbit")) then
        local key = k .. ":" .. b.name
        if not (GEN_KINDS[k].once and gdone[key]) then
          -- A beacon is planted once per world, whichever contract planted it.
          if not (k == "flag" and (save.get("mission.flags") or {})[b.name]) then
            out[#out + 1] = { kind = k, body = b.name, key = key }
          end
        end
      end
    end
  end
  return out
end

-- A tiny deterministic generator, so the same save rolls the same board on any
-- machine and in the harness (which has no engine `rng`).
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

local function name_hash(str)
  local h = 5381
  for i = 1, #(str or "") do h = (h * 33 + str:byte(i)) % 2147483647 end
  return h
end

local function board()
  local b = save.get("mission.board")
  return (type(b) == "table") and b or {}
end

local function active_spec()
  local s = save.get("mission.activeSpec")
  return (type(s) == "table") and s or nil
end

-- Bring the board up to its slot count; drop anything that no longer applies.
-- Cheap and idempotent, so `update` calls it once a second.
local function refill()
  local R = roster()
  if not R then return end
  local slots = SLOTS[standing_level()] or 0
  local cands = candidates()
  local ok = {}
  for _, c in ipairs(cands) do ok[c.key] = true end
  local cur, keep, used = board(), {}, {}
  local act = active_spec()
  if act then used[act.key] = true end
  local changed = false
  for _, s in ipairs(cur) do
    -- Repeatable kinds stay; a one-shot whose body is done (or now beaconed)
    -- does not. A board from another system (a re-rolled save) is cleared.
    if R.by[s.body] and (ok[s.key] or not GEN_KINDS[s.kind].once) and not used[s.key]
       and #keep < math.max(slots, 0) then
      keep[#keep + 1] = s
      used[s.key] = true
    else
      changed = true
    end
  end
  local seq = save.get("mission.genSeq") or 0
  local he = home_entry(R)
  local base = name_hash((R.star or "") .. ((he and he.name) or ""))
  local guard = 0
  while #keep < slots and guard < 8 do
    guard = guard + 1
    local free = {}
    for _, c in ipairs(cands) do if not used[c.key] then free[#free + 1] = c end end
    if #free == 0 then break end
    seq = seq + 1
    local rnd = lcg(base + seq * 7919)
    -- Lean toward the nearer, cheaper work: a weight of 1/difficulty, so the
    -- board always has something you can fly now next to something to aim at.
    local specs, total = {}, 0
    for _, c in ipairs(free) do
      local sp = genSpec(c.kind, c.body, seq)
      if sp then
        local w = 1.0 / math.max(sp.diff, 0.5)
        specs[#specs + 1] = { sp = sp, w = w }
        total = total + w
      else
        used[c.key] = true
      end
    end
    if #specs == 0 then break end
    local pick = rnd() * total
    local chosen = specs[#specs].sp
    for _, e in ipairs(specs) do
      pick = pick - e.w
      if pick <= 0 then chosen = e.sp break end
    end
    keep[#keep + 1] = chosen
    used[chosen.key] = true
    changed = true
  end
  if changed then
    save.set("mission.board", keep)
    save.set("mission.genSeq", seq)
  end
end

-- ── the charter: every world in the system ──────────────────────────────────

-- { done, total, left = {names}, reward, paid }
function charter()
  local R = roster()
  local v = save.get("mission.visited") or {}
  local out = { done = 0, total = 0, left = {}, reward = CHARTER_REWARD,
                paid = save.get("mission.charterPaid") == true }
  if not R then return out end
  for _, b in ipairs(R.bodies) do
    out.total = out.total + 1
    if v[b.name] then out.done = out.done + 1 else out.left[#out.left + 1] = b.name end
  end
  return out
end

function charterLine()
  local c = charter()
  if c.total == 0 then return nil end
  if c.paid then return string.format("Charter complete — all %d worlds", c.total) end
  return string.format("Charter: set foot on every world  %d/%d", c.done, c.total)
end

-- The standing ladder in one line, for a panel: what is open and what's next.
function tierLine()
  local open, lvl = open_tiers(), standing_level()
  local names = {}
  for i, t in ipairs(TIERS) do if open[i] then names[#names + 1] = t.name end end
  local nxt = nil
  for i, t in ipairs(TIERS) do
    if not open[i] then nxt = t break end
  end
  local s = (#names > 0) and ("Open: " .. table.concat(names, ", ")) or "Ladder contracts only"
  if nxt then
    local c = company()
    local need = c and c.STANDING and c.STANDING[nxt.level + 1]
    s = s .. string.format("  ·  next: %s at %s", nxt.name,
      need and string.format("%s (%d)", need.name, need.at) or ("level " .. nxt.level))
  end
  return s
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE PROGRAMME, running (the table is at the top of the file)
-- ════════════════════════════════════════════════════════════════════════════

local NICHE_WHERE = {
  cave = "under an overhang", peak = "on a high peak", ravine = "on a ravine floor",
  lake = "on a lake shore", river = "on a riverbank",
}
PROG_NICHE_WHERE = NICHE_WHERE

local function prog_done() return save.get("prog.done") or {} end
local function prog_perm() return save.get("prog.perm") or {} end

function progById(id)
  for _, m in ipairs(PROGRAMME) do if m.id == id then return m end end
  return nil
end

-- The world the programme's home goals are about: the base's.
function homeName()
  local hb = home_body()
  if hb then return hb.name end
  local b = save.get("base.body")
  if type(b) == "string" then return b end
  return here_name
end

-- ── the network, polled ─────────────────────────────────────────────────────
-- comms.lua (the relay network) answers three questions; each is asked
-- through a guard, so a comms script that does not have them yet — or throws —
-- leaves `progNet.api` false and the relay goals waiting.
local net_hooked = nil
local net_dirty = false
local function net_poll()
  local net = ref("comms")
  local out = { api = false, ground = 0, sky = 0, orbit = 0, groundN = 0, total = 0, linked = {}, t = time or 0 }
  local home = homeName()
  if net and net.coverage then
    out.api = true
    if home then
      local ok, c = pcall(net.coverage, home)
      if ok and type(c) == "table" then
        out.ground, out.sky = tonumber(c.ground) or 0, tonumber(c.sky) or 0
      end
    end
  end
  if net and net.relayStats then
    local ok, st = pcall(net.relayStats)
    if ok and type(st) == "table" then
      out.orbit = (home and type(st.orbit) == "table" and st.orbit[home]) or 0
      out.groundN = (home and type(st.ground) == "table" and st.ground[home]) or 0
      out.total = st.total or 0
    end
  end
  if net and net.linkedBodies then
    local ok, l = pcall(net.linkedBodies)
    if ok and type(l) == "table" then out.linked = l end
  end
  -- Hear about changes as they happen, where the network offers it.
  if net and net.onNetworkChanged and net_hooked ~= net then
    net_hooked = net
    pcall(net.onNetworkChanged, function() net_dirty = true end)
  end
  progNet = out
end

-- ── rare niches on the home world ───────────────────────────────────────────
-- The programme's Rare Finds are the HOME world's: the save's own first planet
-- (the generator's roster), where every niche and the geodes are guaranteed
-- (climate RARE_HOME_V). A find on another world is a discovery — it pays as
-- one — but it does not tick a programme goal.
function progHome()
  local h = save.get("system.home")
  local b1 = type(h) == "table" and type(h.bodies) == "table" and h.bodies[1]
  if type(b1) == "table" and type(b1.name) == "string" then return b1.name end
  return homeName()
end

-- Has a rare plant of this niche been cut on the home world? (`rare.cut.<home>`
-- keys are niche .. n, flora_field rarePlants.)
local function home_cut(niche)
  local home = progHome()
  if not home then return false end
  for k, v in pairs(save.get("rare.cut." .. home) or {}) do
    if v and type(k) == "string" and k:sub(1, #niche) == niche and tonumber(k:sub(#niche + 1)) then return true end
  end
  return false
end

-- Has a Star Geode come out of one of the home world's pockets?
local function home_geode()
  local home = progHome()
  if not home then return false end
  for _, n in pairs(save.get("rare.ore." .. home) or {}) do
    if (tonumber(n) or 0) > 0 then return true end
  end
  return false
end

-- Which niches the home world has rare plants in, read from the save
-- (flora_field writes `rare.<home>` once the world has been scanned). nil
-- before the scan; an empty set on an airless home.
local function home_niches()
  local home = progHome()
  if not home then return nil end
  local d = save.get("rare." .. home)
  if type(d) ~= "table" or type(d.plants) ~= "table" then return nil end
  local w = save.get("world." .. home)
  if type(w) == "table" and (w.atmo or 0) <= 0.15 then return {} end
  local set = {}
  for _, p in ipairs(d.plants) do set[p.niche] = true end
  return set
end

-- The niche each `rare` goal of a milestone resolves to on this home world:
-- its own, else the first alternative the world has that no earlier goal
-- took. false = the world has none of them (the goal is waived).
local function rare_niches(m)
  local set = home_niches()
  local out, taken = {}, {}
  for i, g in ipairs(m.goals) do
    if g.kind == "rare" then
      local pick = nil
      if not set then
        pick = g.niche
      else
        local tries = { g.niche }
        for _, a in ipairs(g.alt or {}) do tries[#tries + 1] = a end
        for _, n in ipairs(tries) do
          if set[n] and not taken[n] then pick = n break end
        end
        pick = pick or false
      end
      if pick then taken[pick] = true end
      out[i] = pick
    end
  end
  return out
end

function progNiche(id, i)
  local m = progById(id)
  if not m then return nil end
  return rare_niches(m)[i]
end

local function body_class(name)
  local R = roster()
  local home = R and home_entry(R)
  local b = R and R.by[name]
  if not (home and b) then return nil end
  local c = class_of(R, home, b)
  if c == "far" then return "moon" end
  return c
end

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 1e-6)) end

-- Is goal i of milestone m met right now? (The tick latches it.)
local function prog_goal_now(m, i, g, niches)
  if g.kind == "sample" then
    -- A home goal counts the home world's pockets, not the discovery set.
    if g.home and g.mat == "geode" then return home_geode() end
    local inv = ref("inventory")
    if not inv then return false end
    if g.mat then return inv.seen(g.mat) == true end
    local mats = ref("materials")
    for mat, yes in pairs(save.get("inv.seen") or {}) do
      if yes and (not g.class or (mats and mats.class(mat) == g.class)) then return true end
    end
    return false
  elseif g.kind == "rare" then
    local n = (niches or rare_niches(m))[i]
    if n == false then return true end
    return home_cut(n)
  elseif g.kind == "groundcov" then
    return progNet.api and (progNet.ground or 0) >= g.frac - 1e-6
  elseif g.kind == "skycov" then
    return progNet.api and (progNet.sky or 0) >= g.frac - 1e-6
  elseif g.kind == "orbitrelay" then
    return (progNet.orbit or 0) >= (g.n or 1)
  elseif g.kind == "linked" then
    local home = homeName()
    for _, name in ipairs(progNet.linked or {}) do
      if name ~= home and body_class(name) == g.class then return true end
    end
    return false
  end
  return false
end

function progGoalLabel(m, i, g, niches)
  if g.kind == "rare" then
    local n = (niches or rare_niches(m))[i]
    if n == false then return "No rare plants of that kind here (waived)" end
    return "A rare plant " .. (NICHE_WHERE[n] or "from somewhere hard to reach")
  end
  return g.label or g.kind
end

-- The live tail of an unmet goal: how close the network is.
local function prog_tail(g)
  if g.kind == "groundcov" or g.kind == "skycov" then
    if not progNet.api then return "   (network not reporting yet)" end
    return "   (now " .. pct(g.kind == "groundcov" and progNet.ground or progNet.sky) .. ")"
  elseif g.kind == "orbitrelay" then
    return string.format("   (%d in orbit)", progNet.orbit or 0)
  end
  return ""
end

local function money_s(v)
  local c = company()
  return (c and c.money) and c.money(v) or ("$" .. tostring(v))
end

-- One line per goal, ✓ once met, with what it pays while it is still open.
function progGoalLines(id)
  local m = progById(id)
  if not m then return {} end
  local pm = prog_perm()[id] or {}
  local niches = rare_niches(m)
  local out = {}
  for i, g in ipairs(m.goals) do
    local ok = pm[i] or pm[tostring(i)]
    local pay = (not ok and g.pay) and ("  · " .. money_s(g.pay)) or ""
    out[#out + 1] = string.format("%s %s%s%s", ok and "✓" or "○", progGoalLabel(m, i, g, niches),
      ok and "" or prog_tail(g), pay)
  end
  return out
end

-- The first goal of a milestone not met yet: g, i, the niche (rare goals).
function progNextGoal(id)
  local m = progById(id)
  if not m then return nil end
  local pm = prog_perm()[id] or {}
  local niches = rare_niches(m)
  for i, g in ipairs(m.goals) do
    if not (pm[i] or pm[tostring(i)]) then return g, i, niches[i] end
  end
  return nil
end

-- What finishing it pays, in words: "$1,200 · +1 rep · unlocks Battery".
function progRewardLine(m)
  if type(m) == "string" then m = progById(m) end
  if not m then return "" end
  local parts = { money_s(m.reward or 0) }
  if (m.rep or 0) > 0 then parts[#parts + 1] = string.format("%+d reputation", m.rep) end
  local rs = ref("research")
  for _, t in ipairs(m.grants or {}) do
    parts[#parts + 1] = "unlocks " .. ((rs and rs.labelOf and rs.labelOf(t)) or t)
  end
  return table.concat(parts, " · ")
end

-- Every milestone with its state: { m, state = "done"|"active"|"locked", needs }.
function programme()
  local done = prog_done()
  local out = {}
  for _, m in ipairs(PROGRAMME) do
    local st = done[m.id] and "done" or ((not m.requires or done[m.requires]) and "active" or "locked")
    local r = m.requires and progById(m.requires)
    out[#out + 1] = { m = m, state = st, needs = r and r.title or nil }
  end
  return out
end

-- The milestones in progress, in programme order.
function progActive()
  local out = {}
  for _, e in ipairs(programme()) do
    if e.state == "active" then out[#out + 1] = e.m end
  end
  return out
end

function progLine()
  local a = progActive()[1]
  if not a then return nil end
  local pm = prog_perm()[a.id] or {}
  local n = 0
  for i = 1, #a.goals do if pm[i] or pm[tostring(i)] then n = n + 1 end end
  return string.format("%s  %d/%d", a.title, n, #a.goals)
end

local function prog_announce(title, reward, label)
  lastPaid = { id = "prog", title = title, reward = reward, at = time, label = label }
  log(string.format("%s — %s   +$%d", label or "MILESTONE", title, reward or 0))
end

local function prog_grant(id, why)
  local rs = ref("research")
  if rs and rs.grant then return rs.grant(id, why) end
  -- No research script in this scene: the save is the truth either way.
  local d = save.get("res.done") or {}
  d[id] = true
  save.set("res.done", d)
  return true
end

local function prog_tick()
  net_poll()
  net_dirty = false
  local done, perm = prog_done(), prog_perm()
  for _, m in ipairs(PROGRAMME) do
    if not done[m.id] and (not m.requires or done[m.requires]) then
      local pm = perm[m.id] or {}
      local niches = rare_niches(m)
      local all = true
      for i, g in ipairs(m.goals) do
        if not (pm[i] or pm[tostring(i)]) then
          if prog_goal_now(m, i, g, niches) then
            pm[i] = true
            perm[m.id] = pm
            -- Written before anything is paid: a payout can never repeat.
            save.set("prog.perm", perm)
            local label = progGoalLabel(m, i, g, niches)
            log("  ✓ " .. m.title .. ": " .. label)
            -- A waived goal (no such place on this world) pays nothing.
            local pay = (g.kind == "rare" and niches[i] == false) and 0 or (g.pay or 0)
            local c = company()
            if pay > 0 and c and c.earn then c.earn(pay, m.title .. ": " .. label) end
            if g.grant then prog_grant(g.grant, m.title) end
            if pay > 0 then prog_announce(label, pay, m.title:upper()) end
          else
            all = false
          end
        end
      end
      if all then
        done[m.id] = true
        save.set("prog.done", done)
        local fx = ref("sfx")
        if fx and fx.play then fx.play("jingle") end
        local c = company()
        if c then
          if c.earn and (m.reward or 0) > 0 then c.earn(m.reward, "milestone: " .. m.title) end
          if c.addRep and (m.rep or 0) > 0 then c.addRep(m.rep, "milestone: " .. m.title) end
        end
        for _, t in ipairs(m.grants or {}) do prog_grant(t, m.title) end
        prog_announce(m.title, m.reward or 0, "MILESTONE")
      end
    end
  end
end

-- Tick the programme now (harness, probes); the game ticks it once a second.
function progTick() prog_tick() end

-- ════════════════════════════════════════════════════════════════════════════
-- THE API
-- ════════════════════════════════════════════════════════════════════════════

function byId(id)
  for _, m in ipairs(CATALOGUE) do
    if m.id == id then return m end
  end
  local a = active_spec()
  if a and a.id == id then return a end
  for _, s in ipairs(board()) do
    if s.id == id then return s end
  end
  return nil
end

-- Every contract you could take right now: not already flown, prerequisite met,
-- and not the one already on the books — the ladder first, then the generated
-- board.
function offers()
  local done = done_set()
  local out = {}
  for _, m in ipairs(CATALOGUE) do
    if not done[m.id] and m.id ~= active
      and (not m.requires or done[m.requires]) then
      out[#out + 1] = m
    end
  end
  for _, s in ipairs(board()) do
    if s.id ~= active then out[#out + 1] = s end
  end
  return out
end

-- The contracts you CAN'T sign yet, each with what it is waiting for. The board
-- shows them greyed, because "none right now" says the company has run out of
-- work when really it has a ladder you haven't climbed. After the ladder rungs
-- come the generated tiers you haven't opened, and last the Charter — the
-- long-term goal, always visible, with the worlds it is still waiting for.
local tier_from_cache = {}
function upcoming()
  local done = done_set()
  local out = {}
  for _, m in ipairs(CATALOGUE) do
    if not done[m.id] and m.id ~= active and m.requires and not done[m.requires] then
      local r = byId(m.requires)
      out[#out + 1] = { m = m, needs = r and r.title or m.requires }
    end
  end
  local R = roster()
  if R then
    local open = open_tiers()
    local c = company()
    for i, t in ipairs(TIERS) do
      if not open[i] then
        local st = c and c.STANDING and c.STANDING[t.level + 1]
        local rung = byId(t.needs)
        local needs = {}
        if standing_level() < t.level then
          needs[#needs + 1] = st and string.format("%s standing (rep %d)", st.name, st.at)
            or ("standing level " .. t.level)
        end
        if not done[t.needs] then needs[#needs + 1] = rung and rung.title or t.needs end
        -- What the tier's work starts at, so the row has a real price on it.
        local from = nil
        local home = home_entry(R)
        -- (Cached a few seconds: the board asks every frame it is open.)
        local ck = tier_from_cache[i]
        if ck and (time or 0) - ck.t < 5 then from, home = ck.v, nil end
        if home then
          for _, b in ipairs(R.bodies) do
            local ks = t.kinds[class_of(R, home, b)]
            for _, k in ipairs(ks or {}) do
              local sp = genSpec(k, b.name, 0)
              if sp and (not from or sp.reward < from) then from = sp.reward end
            end
          end
        end
        if home then tier_from_cache[i] = { v = from, t = time or 0 } end
        out[#out + 1] = { m = { id = "tier" .. i, title = t.name .. " contracts",
                                reward = from or 0, rep = 0, tier = true,
                                brief = "Opens " .. t.what .. "." },
                          needs = table.concat(needs, " + ") }
        break   -- the NEXT tier only: a list of everything locked is a wall
      end
    end
    local ch = charter()
    if not ch.paid and ch.total > 0 then
      local left = ch.left
      local shown = {}
      for i = 1, math.min(3, #left) do shown[i] = left[i] end
      local tail = (#left > 3) and string.format(" and %d more", #left - 3) or ""
      out[#out + 1] = { m = { id = "charter",
          title = string.format("CHARTER — set foot on every world (%d/%d)", ch.done, ch.total),
          reward = ch.reward, rep = CHARTER_REP, charter = true,
          brief = "The company's founding charter: a beacon on every world in the system." },
        needs = (#left > 0) and (table.concat(shown, ", ") .. tail) or "nothing" }
    end
  end
  return out
end

-- Does the contract on the books still need this material in the warehouse?
-- The depot keeps it back instead of selling it: selling the ore a Prospector
-- contract is waiting for is a sale that quietly un-does the job.
function reserves(mat)
  local m = active and byId(active)
  if not m then return false end
  local mats = ref("materials")
  for i, g in ipairs(m.goals) do
    if g.kind == "deliver" and not met(i) then
      if g.mat == mat then return true end
      if not g.mat and (not g.class or (mats and mats.class(mat) == g.class)) then return true end
    end
  end
  return false
end

function completed()
  local done, out = done_set(), {}
  for _, m in ipairs(CATALOGUE) do
    if done[m.id] then out[#out + 1] = m end
  end
  return out
end

-- How many generated contracts this company has flown.
function generatedFlown()
  return save.get("mission.gcount") or 0
end

local function clear_progress()
  flight_seen, perm, best = {}, {}, {}
  save.set("mission.seen", {})
  save.set("mission.perm", {})
end

function accept(id)
  local m = byId(id)
  if not m or active == id or m.tier or m.charter then return false end
  -- Signing a generated contract takes it off the board (the board refills).
  if m.gen then
    local keep = {}
    for _, s in ipairs(board()) do if s.id ~= id then keep[#keep + 1] = s end end
    save.set("mission.board", keep)
    save.set("mission.activeSpec", m)
  else
    save.set("mission.activeSpec", false)
  end
  active = id
  clear_progress()
  save.set("mission.active", id)
  -- A recovery done BEFORE signing is not this contract's recovery. The flag
  -- was set by vessel_controller and never cleared, so "Bring It Home" paid on
  -- the spot for anyone who had ever recovered a craft.
  save.set("mission.recovered", false)
  log("CONTRACT ACCEPTED — " .. m.title)
  return true
end

function abandon()
  if not active then return false end
  local m = byId(active)
  active = nil
  clear_progress()
  save.set("mission.active", false)
  save.set("mission.activeSpec", false)
  -- Walking away from a signed contract costs standing, not money.
  local c = company()
  if c and c.addRep then c.addRep(-1, "abandoned " .. ((m and m.title) or "contract")) end
  return true
end

-- The craft the player is actually flying, if any.
local function piloted()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting then return v end
  end
  return nil
end

-- Altitude above the HOME world's surface — not above whichever body currently
-- dominates. Dominance is patched-conic: cross the sphere of influence and it
-- flips to the star in one frame, and the altitude a contract is watching jumps
-- by thousands of metres without the craft having climbed a single one. A goal
-- that ticks on a frame of arithmetic is worse than one that never ticks.
--
-- The home world is the frame the contract was written in. Stay in it, and fall
-- back to dominance only before there is a base to measure from.
local function alt_of(v)
  local n = v.node
  if not n or not n.valid then return nil end
  local b = home_body()
  if not b then
    local d = space.dominant(n.x, n.y, n.z)
    b = d and space.body(d)
  end
  if not b then return nil end
  local dx, dy, dz = n.x - b.x, n.y - b.y, n.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz) - b.radius, b
end

-- The body a craft is actually in the grip of — what a NAMED-body goal asks.
local function dominant_of(n)
  if not (n and n.valid ~= false and n.x) then return nil end
  return space.dominant(n.x, n.y, n.z)
end

-- The orbit around the body a goal names (home if none): periapsis altitude,
-- or nil when it isn't an orbit of that body.
local function peri_alt(g, v)
  local n = v.node
  local oe = n and space.elements and space.elements(n.x, n.y, n.z, n.vx, n.vy, n.vz)
  if not (oe and oe.periapsis) then return nil end
  if (oe.e or 1.0) >= 1.0 then return nil end   -- an escape has no periapsis to beat
  local body
  if g.body then
    if oe.body and oe.body ~= g.body then return nil end
    body = space.body(g.body)
  else
    local _, b = alt_of(v)
    body = b
  end
  if not body then return nil end
  return oe.periapsis - body.radius
end

-- The crew, on foot, standing on the body this goal names?
local function on_foot_at(name)
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot) then return false end
  local a = find("Astronaut")
  if not (a and a.valid ~= false) then return false end
  if space.dominant(a.x, a.y, a.z) ~= name then return false end
  local b = space.body(name)
  if not b then return false end
  local w = save.get("world." .. name)
  local relief = (type(w) == "table" and w.relief) or (b.radius * 0.08)
  local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
  return d - b.radius < relief * 2 + 15
end

-- How close this flight has come to a numeric goal, and how to say it. Used for
-- the live "(best …)" tail on an unmet goal — a target you cannot see yourself
-- approaching is indistinguishable from a target that is broken, which is
-- exactly the mistake the metre values above were making.
local function fmt_speed(x) return string.format("%.0f m/s", x) end

local function fmt_of(g)
  if g.kind == "speed" then return fmt_speed end
  return fmt_m
end

local function measure(g, v, info)
  if g.kind == "altitude" then
    return (alt_of(v))
  elseif g.kind == "speed" then
    if not info then return nil end
    local s = info.vel
    return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
  elseif g.kind == "orbit" or g.kind == "cargo" then
    return peri_alt(g, v)
  end
  return nil
end

-- What's in the warehouse toward a delivery goal: units, or kilograms.
local function delivered(g)
  local inv, mats = ref("inventory"), ref("materials")
  if not inv then return 0 end
  if g.mat then
    local n = inv.count("base", g.mat)
    if g.kg then return n * ((mats and mats.kg(g.mat)) or 1) end
    return n
  end
  local n = 0
  for _, it in ipairs(inv.items("base")) do
    if not g.class or (mats and mats.class(it.mat) == g.class) then
      n = n + (g.kg and it.kg or it.n)
    end
  end
  return n
end

-- Is this goal satisfied RIGHT NOW? (Latching is the caller's job — a goal that
-- was true a moment ago stays true for the rest of the flight.)
local function goal_now(g, v, info)
  if g.kind == "altitude" then
    local a = alt_of(v)
    local t = target_of(g)
    return t ~= nil and a ~= nil and a >= t
  elseif g.kind == "speed" then
    if not info then return false end
    local s = info.vel
    return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) >= g.value
  elseif g.kind == "orbit" then
    -- A real orbit: the periapsis has to clear the value, which is exactly the
    -- thing a lob can't fake. `space.elements` is the engine's own conic;
    -- `periapsis` is a RADIUS from the body centre, and `e` (not `ecc`) is the
    -- eccentricity — an escape trajectory is not an orbit however high it goes.
    local t, pa = target_of(g), peri_alt(g, v)
    return t ~= nil and pa ~= nil and pa >= t
  elseif g.kind == "cargo" then
    local t, pa = target_of(g), peri_alt(g, v)
    if not (t and pa and pa >= t) then return false end
    local inv = ref("inventory")
    return inv ~= nil and v.holdId ~= nil and inv.mass(v.holdId) >= (g.kg or 0)
  elseif g.kind == "soi" then
    return dominant_of(v.node) == g.body
  elseif g.kind == "land" then
    -- A rocket clamped to the pad is grounded and stopped, which is all a
    -- landing looks like — so the goal ticked (and RECOVER CRAFT was offered)
    -- before the engines had ever lit. vessel_controller's `hasFlown` is true
    -- once the clamps are off and the craft has been airborne.
    if v.hasFlown ~= true then return false end
    -- A rover stands on its tyre bodies, not its hull, so its hull never
    -- reads grounded: vessel_controller's r2OnWheels says it is down.
    local on_wheels = v.r2OnWheels and v.r2OnWheels()
    if not info or not (info.grounded or on_wheels) then return false end
    -- A NAMED body is the one the craft is actually sitting on — not the home
    -- world the altitude goals measure from, which is what this used to compare
    -- (so "land on X" could never tick anywhere but home).
    if g.body and dominant_of(v.node) ~= g.body then return false end
    -- "Intact" means the pod is still aboard and the craft has stopped.
    local s = info.vel
    return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) < 1.5
  elseif g.kind == "flag" then
    return on_foot_at(g.body)
  elseif g.kind == "dock" then
    return (v.dock and (v.dock.latched or 0) > 0) or false
  elseif g.kind == "recover" then
    return save.get("mission.recovered") == true
  elseif g.kind == "deliver" then
    -- What's actually in the warehouse at home: mined or cut, flown back and
    -- put through the depot's crane. Selling it afterwards can't un-do the
    -- delivery, because these goals latch permanently.
    if not ref("inventory") then return false end
    return delivered(g) >= (g.kg or g.value or 1)
  elseif g.kind == "sample" then
    local inv = ref("inventory")
    if not inv then return false end
    if g.mat then return inv.seen(g.mat) == true end
    -- Any material of a class: the discovery set, read through the registry.
    local mats = ref("materials")
    local seen = save.get("inv.seen") or {}
    for mat, yes in pairs(seen) do
      if yes and (not g.class or (mats and mats.class(mat) == g.class)) then return true end
    end
    return false
  end
  return false
end

-- Kinds that are things you DID rather than states of the flight you're on:
-- they latch for the whole contract and survive stepping out of the pod.
local PERMANENT = { deliver = true, sample = true, recover = true, flag = true }

-- How far along an unmet goal is, as a tail for its line. A number you can
-- watch move is the difference between a contract you are flying and a contract
-- you suspect is broken.
local function tail(i, g)
  if met(i) then return "" end
  if g.kind == "deliver" then
    if not ref("inventory") then return "" end
    if g.kg then
      return string.format("   (%.0f / %d kg in the warehouse)", delivered(g), g.kg)
    end
    return string.format("   (%d / %d in the warehouse)", delivered(g), g.value or 1)
  end
  local b = best[i]
  if not b then return "" end
  return string.format("   (best this flight %s)", fmt_of(g)(b))
end

-- One line per goal, ✓ once met.
function goalLines()
  local m = active and byId(active)
  if not m then return {} end
  local out = {}
  for i, g in ipairs(m.goals) do
    out[#out + 1] = string.format("%s %s%s", met(i) and "✓" or "○",
      goalLabel(g), tail(i, g))
  end
  return out
end

function activeLine()
  local m = active and byId(active)
  if not m then return nil end
  local n, total = 0, #m.goals
  for i = 1, total do
    if met(i) then n = n + 1 end
  end
  return string.format("%s  %d/%d", m.title, n, total)
end

local function announce(id, title, reward)
  -- SAY IT ON SCREEN. The money moves the instant the last goal ticks — there
  -- is no counter to walk to, no Ops clerk to see — and the only announcement
  -- was a Console line, which the player is not looking at. The objectives
  -- card picks `lastPaid` up and holds a banner for a few seconds, including
  -- mid-flight, because the last goal of a flight contract ticks while you are
  -- still in the seat.
  lastPaid = { id = id, title = title, reward = reward, at = time }
  log(string.format("CONTRACT COMPLETE — %s   +$%d", title, reward))
end

local function payout(m)
  -- The jingle goes first: the ledger's cash clink under it is swallowed.
  local fx = ref("sfx")
  if fx and fx.play then fx.play("jingle") end
  local c = company()
  if c then
    if c.earn then c.earn(m.reward, "contract: " .. m.title) end
    if c.addRep then c.addRep(m.rep or 0, "completed " .. m.title) end
  end
  if m.gen then
    local gd = save.get("mission.gdone") or {}
    if GEN_KINDS[m.kind] and GEN_KINDS[m.kind].once then
      gd[m.key] = true
      save.set("mission.gdone", gd)
    end
    save.set("mission.gcount", (save.get("mission.gcount") or 0) + 1)
  else
    local done = done_set()
    done[m.id] = true
    save.set("mission.done", done)
  end
  active = nil
  clear_progress()
  save.set("mission.active", false)
  save.set("mission.activeSpec", false)
  announce(m.id, m.title, m.reward)
  refill()
end

-- DEBUG: pay the contract on the books as though every goal had been met.
-- `cheats.lua` (F11) calls it. It goes through `payout` rather than editing the
-- save directly, so the ledger entry, the reputation and the done-set all move
-- exactly the way a real completion moves them — a cheat that took a different
-- code path would be testing the cheat instead of the game.
function forceComplete()
  local m = active and byId(active)
  if not m then return false end
  -- A forced beacon is still a beacon: the charter counts it.
  for _, g in ipairs(m.goals) do
    if g.kind == "flag" and g.body then
      local f = save.get("mission.flags") or {}
      f[g.body] = true
      save.set("mission.flags", f)
      local v = save.get("mission.visited") or {}
      v[g.body] = true
      save.set("mission.visited", v)
    end
  end
  payout(m)
  return true
end

function start(node)
  local a = save.get("mission.active")
  active = (type(a) == "string") and a or nil
  local seen = save.get("mission.seen")
  flight_seen = (type(seen) == "table") and seen or {}
  local pm = save.get("mission.perm")
  perm = (type(pm) == "table") and pm or {}
  -- A generated contract on the books whose spec went missing (a save from
  -- before the generator) can't be tracked: let it go rather than strand it.
  if active and not byId(active) then
    active = nil
    save.set("mission.active", false)
  end
end

-- Read the contract state again from the save: a revert to launch
-- (vessel_spawner) has put mission.* back as they were at the launch. The
-- flight's high-water marks go with the flight.
function reloadFromSave()
  start(nil)
  best, last_piloting = {}, false
  lastPaid = nil
end

-- Record where the crew has stood, for the charter, and pay it when it's whole.
local function charter_tick()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot) then return end
  local a = find("Astronaut")
  if not a then return end
  local R = roster()
  if not R then return end
  local d = space.dominant(a.x, a.y, a.z)
  if not (d and R.by[d]) then return end
  local v = save.get("mission.visited") or {}
  if not v[d] and on_foot_at(d) then
    v[d] = true
    save.set("mission.visited", v)
    log("CHARTER — set foot on " .. d)
  end
  if save.get("mission.charterPaid") ~= true then
    local ch = charter()
    if ch.total > 0 and ch.done >= ch.total then
      save.set("mission.charterPaid", true)
      local c = company()
      if c then
        if c.earn then c.earn(CHARTER_REWARD, "the Charter: every world") end
        if c.addRep then c.addRep(CHARTER_REP, "the Charter") end
      end
      announce("charter", "The Charter — every world in the system", CHARTER_REWARD)
    end
  end
end

local refill_t = -1
function update(node, dt)
  here_name = space.dominant(node.x, node.y, node.z) or here_name
  -- The board and the charter, once a second: neither changes faster.
  if (time or 0) - refill_t >= 1.0 or refill_t < 0 or net_dirty then
    refill_t = time or 0
    refill()
    charter_tick()
    prog_tick()
  end
  local m = active and byId(active)
  if not m then
    progress = ""
    return
  end
  -- The goals you can meet with both feet on the ground — a warehouse delivery,
  -- a discovery, a recovery, a beacon — are checked every tick whether or not
  -- anyone is flying, and once true they stay true for the rest of the contract.
  for i, g in ipairs(m.goals) do
    if PERMANENT[g.kind] and not perm[i] and (not g.after or met(g.after))
       and goal_now(g, { node = node }, nil) then
      perm[i] = true
      save.set("mission.perm", perm)
      log("  ✓ " .. goalLabel(g))
      if g.kind == "flag" and g.body then
        local f = save.get("mission.flags") or {}
        f[g.body] = true
        save.set("mission.flags", f)
      end
    end
  end

  local v = piloted()
  -- Leaving the craft (or losing it) ends the flight's latches: goals have to
  -- be met on ONE trip, which is what makes "get high AND land intact" a flight
  -- plan instead of two unrelated afternoons.
  if not v then
    if last_piloting and not save.get("mission.recovered") then
      flight_seen, best = {}, {}
      save.set("mission.seen", {})
    end
    last_piloting = false
    progress = activeLine() or ""
  else
    last_piloting = true
    local info = assembly.info(v.node)
    for i, g in ipairs(m.goals) do
      if not PERMANENT[g.kind] and not flight_seen[i] and (not g.after or met(g.after))
         and goal_now(g, v, info) then
        flight_seen[i] = true
        save.set("mission.seen", flight_seen)
        log("  ✓ " .. goalLabel(g))
      end
      -- The high-water mark, whether or not the goal is met, so the card can
      -- show the flight closing on its target instead of an unlit circle.
      local now = measure(g, v, info)
      if now and (not best[i] or now > best[i]) then best[i] = now end
    end
    progress = activeLine() or ""
  end
  -- All goals met → pay out.
  local all = true
  for i = 1, #m.goals do
    if not met(i) then all = false end
  end
  if all then payout(m) end
end
