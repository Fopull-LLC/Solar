-- MISSIONS — the contracts that turn a sandbox into a company.
--
-- One accepted contract at a time. Its goals are watched live against the craft
-- you're actually flying; every goal that latches stays latched for the flight,
-- so "reach 2,000 m AND land intact" is a thing you do in one trip rather than
-- two states that can never be true at once. Complete them all and Ops pays out
-- the moment you're home.
--
-- The CATALOGUE below is the data. Goals are declarative and the tracker knows
-- a handful of kinds, so a new contract is a table entry — no new code:
--
--   altitude  frac       climb this far toward the edge of home's influence
--   speed     value      hit this surface speed (m/s)
--   orbit     frac       periapsis above that height — a real orbit, not a lob
--   land      body?      touch down intact (optionally on a NAMED body)
--   dock                 latch onto another craft in flight
--   recover              bring the craft home and recover it at the base
--   deliver   mat/class  have this much of a material in the base WAREHOUSE
--                        (mined or harvested, flown home, unloaded at the depot)
--   sample    mat        have HELD this material at all — the discovery set
--
-- `deliver`, `sample` and `recover` latch PERMANENTLY (they're things you did,
-- not states of a flight); every other kind latches for the current flight
-- only, so a multi-goal trip has to be one trip.
--
-- Cross-script:  local m = findScript("missions")
--                m.offers()  m.accept(id)  m.abandon()  m.activeLine()

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
-- Nothing failed. You could fly the mission perfectly, land the pod intact, walk
-- home, and the goal would sit there unticked with no way to find out why. "I
-- flew up then landed with the pod intact then came back and nothing indicated
-- anywhere where to claim my reward."
--
-- So a flight goal names a FRACTION of the room it actually has — ground to the
-- edge of home's influence — and the metres are resolved from the body at read
-- time. The LABEL is generated from the same number as the check, so the card
-- and the tracker can never quote different targets.
local CATALOGUE = {
  {
    id = "firstflight", title = "First Flight",
    brief = "Get something off the pad and bring the pod back in one piece.\n" ..
            "Ops isn't asking for elegance.",
    reward = 4500, rep = 1,
    goals = {
      { kind = "altitude", frac = 0.15, label = "Reach %s" },
      { kind = "land", label = "Land with the pod intact" },
    },
  },
  {
    id = "highroad", title = "The High Road",
    brief = "Most of the way to the edge of this world's pull. The air is thin\n" ..
            "enough up there that the board wants to see the telemetry before\n" ..
            "they sign anything bigger.",
    reward = 9000, rep = 1, requires = "firstflight",
    goals = {
      { kind = "altitude", frac = 0.55, label = "Reach %s" },
      { kind = "land", label = "Land intact" },
    },
  },
  {
    id = "orbit", title = "Made Orbit",
    brief = "Not a lob — an ORBIT. Get your periapsis clear of the atmosphere\n" ..
            "so the craft comes back around on its own.",
    reward = 22000, rep = 2, requires = "highroad",
    goals = {
      { kind = "orbit", frac = 0.10, label = "Periapsis above %s" },
    },
  },
  {
    id = "rendezvous", title = "Rendezvous",
    brief = "Two craft, one seam. Undock a module in flight and latch it back\n" ..
            "on — the manoeuvre every station and every return trip is built of.",
    reward = 30000, rep = 2, requires = "orbit",
    goals = {
      { kind = "dock", label = "Dock two craft in flight" },
      { kind = "land", label = "Bring the stack home intact" },
    },
  },
  {
    id = "prospect", title = "Prospector",
    brief = "The board wants to know the rock is worth landing on. Mine ore,\n" ..
            "fly it home and put 30 units through the depot.",
    reward = 8000, rep = 1, requires = "firstflight",
    goals = {
      { kind = "deliver", class = "ore", value = 30,
        label = "30 units of ore in the warehouse" },
    },
  },
  {
    id = "botany", title = "Field Botany",
    brief = "Cut samples of whatever grows down there — the labs will take any\n" ..
            "plant matter, and the stranger it is the better they like it.",
    reward = 7000, rep = 1, requires = "firstflight",
    goals = {
      { kind = "deliver", class = "flora", value = 20,
        label = "20 units of plant matter in the warehouse" },
    },
  },
  {
    id = "deepcore", title = "Deep Core",
    brief = "Resonant crystal only forms twenty metres down and it does not\n" ..
            "come up with a shovel. Take the laser and dig.",
    reward = 26000, rep = 2, requires = "prospect",
    goals = {
      { kind = "sample", mat = "crystal", label = "Find resonant crystal" },
      { kind = "deliver", mat = "crystal", value = 5,
        label = "5 crystal in the warehouse" },
    },
  },
  {
    id = "recovery", title = "Bring It Home",
    brief = "Ops is tired of writing off hulls. Land near the base and RECOVER\n" ..
            "the craft — you get most of the hardware's value back.",
    reward = 12000, rep = 1, requires = "firstflight",
    goals = {
      { kind = "recover", label = "Recover a craft at the base" },
    },
  },
}

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

-- Ground → the edge of that world's influence, in metres. Everything a flight
-- above home can do fits inside this number. nil until a base is sited.
local function ceiling()
  local b = home_body()
  if not b then return nil end
  return math.max(1.0, b.soi - b.radius)
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

local function target_of(g)
  if g.value then return g.value end
  if not g.frac then return nil end
  local c = ceiling()
  if not c then return nil end
  return nice(c * g.frac)
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


local function done_set()
  return save.get("mission.done") or {}
end

function byId(id)
  for _, m in ipairs(CATALOGUE) do
    if m.id == id then return m end
  end
  return nil
end

-- Every contract you could take right now: not already flown, prerequisite met,
-- and not the one already on the books.
function offers()
  local done = done_set()
  local out = {}
  for _, m in ipairs(CATALOGUE) do
    if not done[m.id] and m.id ~= active
      and (not m.requires or done[m.requires]) then
      out[#out + 1] = m
    end
  end
  return out
end

-- The contracts you CAN'T sign yet, each with what it is waiting for. The board
-- shows them greyed, because "none right now" says the company has run out of
-- work when really it has a ladder you haven't climbed.
function upcoming()
  local done = done_set()
  local out = {}
  for _, m in ipairs(CATALOGUE) do
    if not done[m.id] and m.id ~= active and m.requires and not done[m.requires] then
      local r = byId(m.requires)
      out[#out + 1] = { m = m, needs = r and r.title or m.requires }
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

function accept(id)
  local m = byId(id)
  if not m or active == id then return false end
  active = id
  flight_seen, perm, best = {}, {}, {}
  save.set("mission.active", id)
  save.set("mission.seen", {})
  save.set("mission.perm", {})
  log("CONTRACT ACCEPTED — " .. m.title)
  return true
end

function abandon()
  if not active then return false end
  local m = byId(active)
  active = nil
  flight_seen, perm, best = {}, {}, {}
  save.set("mission.active", false)
  save.set("mission.seen", {})
  save.set("mission.perm", {})
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
  elseif g.kind == "orbit" then
    local n = v.node
    local _, body = alt_of(v)
    local oe = n and space.elements and space.elements(n.x, n.y, n.z, n.vx, n.vy, n.vz)
    if not (oe and oe.periapsis and body) then return nil end
    if (oe.e or 1.0) >= 1.0 then return nil end   -- an escape has no periapsis to beat
    return oe.periapsis - body.radius
  end
  return nil
end

-- Is this goal satisfied RIGHT NOW? (Latching is the caller's job — a goal that
-- was true a moment ago stays true for the rest of the flight.)
local function goal_now(g, v, info)
  local a, body = alt_of(v)
  if g.kind == "altitude" then
    local t = target_of(g)
    return t ~= nil and a ~= nil and a >= t
  elseif g.kind == "speed" then
    if not info then return false end
    local s = info.vel
    return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) >= g.value
  elseif g.kind == "orbit" then
    -- A real orbit: the periapsis has to clear the value, which is exactly the
    -- thing a lob can't fake. `space.elements` is the engine's own conic.
    local n = v.node
    local oe = n and space.elements and space.elements(n.x, n.y, n.z, n.vx, n.vy, n.vz)
    local t = target_of(g)
    if not (oe and oe.periapsis and body and t) then return false end
    -- `periapsis` is a RADIUS from the body centre, and `e` (not `ecc`) is the
    -- eccentricity — an escape trajectory is not an orbit however high it goes.
    return (oe.e or 1.0) < 1.0 and (oe.periapsis - body.radius) >= t
  elseif g.kind == "land" then
    -- A rocket clamped to the pad is grounded and stopped, which is all a
    -- landing looks like — so the goal ticked (and RECOVER CRAFT was offered)
    -- before the engines had ever lit. vessel_controller's `hasFlown` is true
    -- once the clamps are off and the craft has been airborne.
    if v.hasFlown ~= true then return false end
    if not info or not info.grounded then return false end
    if g.body and body and body.name ~= g.body then return false end
    -- "Intact" means the pod is still aboard and the craft has stopped.
    local s = info.vel
    return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) < 1.5
  elseif g.kind == "dock" then
    return (v.dock and (v.dock.latched or 0) > 0) or false
  elseif g.kind == "recover" then
    return save.get("mission.recovered") == true
  elseif g.kind == "deliver" then
    -- What's actually in the warehouse at home: mined or cut, flown back and
    -- put through the depot's crane. Selling it afterwards can't un-do the
    -- delivery, because these goals latch permanently.
    local inv, mats = ref("inventory"), ref("materials")
    if not inv then return false end
    if g.mat then return inv.count("base", g.mat) >= (g.value or 1) end
    local n = 0
    for _, it in ipairs(inv.items("base")) do
      if not g.class or (mats and mats.class(it.mat) == g.class) then n = n + it.n end
    end
    return n >= (g.value or 1)
  elseif g.kind == "sample" then
    local inv = ref("inventory")
    return inv ~= nil and inv.seen(g.mat) == true
  end
  return false
end

-- Kinds that are things you DID rather than states of the flight you're on:
-- they latch for the whole contract and survive stepping out of the pod.
local PERMANENT = { deliver = true, sample = true, recover = true }

-- How far along an unmet goal is, as a tail for its line. A number you can
-- watch move is the difference between a contract you are flying and a contract
-- you suspect is broken.
local function tail(i, g)
  if met(i) then return "" end
  if g.kind == "deliver" then
    local inv, mats = ref("inventory"), ref("materials")
    if not inv then return "" end
    local have = 0
    if g.mat then
      have = inv.count("base", g.mat)
    else
      for _, it in ipairs(inv.items("base")) do
        if not g.class or (mats and mats.class(it.mat) == g.class) then have = have + it.n end
      end
    end
    return string.format("   (%d / %d in the warehouse)", have, g.value or 1)
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

local function payout(m)
  -- The jingle goes first: the ledger's cash clink under it is swallowed.
  local fx = ref("sfx")
  if fx and fx.play then fx.play("jingle") end
  local c = company()
  if c then
    if c.earn then c.earn(m.reward, "contract: " .. m.title) end
    if c.addRep then c.addRep(m.rep or 0, "completed " .. m.title) end
  end
  local done = done_set()
  done[m.id] = true
  save.set("mission.done", done)
  active = nil
  flight_seen, perm, best = {}, {}, {}
  save.set("mission.active", false)
  save.set("mission.seen", {})
  save.set("mission.perm", {})
  -- SAY IT ON SCREEN. The money moves the instant the last goal ticks — there
  -- is no counter to walk to, no Ops clerk to see — and the only announcement
  -- was this Console line, which the player is not looking at. The objectives
  -- card picks `lastPaid` up and holds a banner for a few seconds, including
  -- mid-flight, because the last goal of a flight contract ticks while you are
  -- still in the seat.
  lastPaid = { id = m.id, title = m.title, reward = m.reward, at = time }
  log(string.format("CONTRACT COMPLETE — %s   +$%d", m.title, m.reward))
end

-- DEBUG: pay the contract on the books as though every goal had been met.
-- `cheats.lua` (F11) calls it. It goes through `payout` rather than editing the
-- save directly, so the ledger entry, the reputation and the done-set all move
-- exactly the way a real completion moves them — a cheat that took a different
-- code path would be testing the cheat instead of the game.
function forceComplete()
  local m = active and byId(active)
  if not m then return false end
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
end

function update(node, dt)
  here_name = space.dominant(node.x, node.y, node.z) or here_name
  local m = active and byId(active)
  if not m then
    progress = ""
    return
  end
  -- The goals you can meet with both feet on the ground — a warehouse delivery,
  -- a discovery, a recovery — are checked every tick whether or not anyone is
  -- flying, and once true they stay true for the rest of the contract.
  for i, g in ipairs(m.goals) do
    if PERMANENT[g.kind] and not perm[i] and goal_now(g, { node = node }, nil) then
      perm[i] = true
      save.set("mission.perm", perm)
      log("  ✓ " .. goalLabel(g))
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
      if not PERMANENT[g.kind] and not flight_seen[i] and goal_now(g, v, info) then
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
