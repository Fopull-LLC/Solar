-- OBJECTIVES — the card in the corner that answers "what am I supposed to be
-- doing?", and, just as importantly, "where is the thing I'm supposed to do it
-- at?".
--
-- The game already had every piece of a career — contracts, a builder, a depot
-- that pays for rock — and no thread connecting them. A new save dropped you on
-- an unfamiliar planet next to five unlabelled buildings with no reason to walk
-- into any of them. This is that thread: one step at a time, read off the same
-- state the rest of the game runs on, so it can never disagree with the world.
--
-- The step is DERIVED, never stored. There is no tutorial progress counter to
-- get out of sync with a save that was edited, a contract abandoned, or a
-- rocket that blew up — ask the ledger and the mission board what is true right
-- now and the answer is the next thing to do.
--
-- The screen is described with `ui.make` rather than authored into the scene:
-- the card is a different SHAPE at each step (a bearing line here, a list of
-- contract goals there), and a scene file can only hold one shape. The scene
-- holds an empty node saying where the card sits.
--
--   O          hide/show the card
--
-- Cross-script:  local ob = findScript("objectives")
--                ob.headline   ob.targetName

defaults = {
  --@header Card
  --@range 0 1
  enabled = 1,        -- 0 hides the card entirely (it also has a hotkey)
  --@range 1 60 --@units m
  arrived = 24.0,     -- inside this range the card stops giving directions
}

-- Published for anything that wants the current step without recomputing it.
headline = ""
targetName = nil

local FAC_LABEL = {
  FacCommand  = "Command Centre",
  FacHangar   = "Vehicle Assembly",
  FacDepot    = "Commerce Depot",
  FacTracking = "Tracking Station",
  FacPower    = "Power Plant",
}

local shown = true
-- The facility the card is sending you to, while the card is up on foot: the
-- world-space waypoint is drawn over it (see `lateUpdate`).
local marker_at = nil

-- IS THE CREW OUT AND ABOUT? Deliberately NOT `astro.visible`: planet_camera
-- hides the body whenever the camera lands within 0.7 m of it, which includes
-- every time the wall-clip ray finds a wall behind you — i.e. constantly, while
-- you are inside one of the base buildings or standing beside your own rocket.
-- Gating on visibility switched this off exactly where it was wanted.
-- planet_walker publishes the question that was meant; the scan is the fallback.
-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- `planet_walker.onFoot` is always published (declared at load), so the
-- three-scan fallback chain that used to sit under this could never run.
local function crew_afoot()
  local pw = ref("planet_walker")
  return pw ~= nil and pw.onFoot == true
end

-- ── where things are ────────────────────────────────────────────────────────

-- Metres between two nodes in WORLD space. `distanceTo` composes both parent
-- chains in the engine — the facilities are parented to their (orbiting) planet
-- and the astronaut is not, so anything that compares raw .x is comparing two
-- different frames and is wrong by the planet's orbital position.
local function apart(a, b)
  if a.distanceTo then return a:distanceTo(b) end
  local x, y, z = b.x, b.y, b.z
  local p, guard = b.parent, 0
  while p and guard < 8 do
    x, y, z = x + p.x, y + p.y, z + p.z
    p, guard = p.parent, guard + 1
  end
  local dx, dy, dz = x - a.x, y - a.y, z - a.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function world_of(n)
  if n.worldX then return n.worldX, n.worldY, n.worldZ end
  local x, y, z = n.x, n.y, n.z
  local p, guard = n.parent, 0
  while p and guard < 8 do
    x, y, z = x + p.x, y + p.y, z + p.z
    p, guard = p.parent, guard + 1
  end
  return x, y, z
end

-- Which way to turn, in words. A distance alone sends you walking in circles on
-- a round planet; a bearing relative to WHERE YOU ARE LOOKING is the thing a
-- person can act on without a compass rose.
-- The signed angle, in degrees, from where you are looking to the target, in
-- the ground plane: positive is to your right. nil if there is no camera or no
-- world under you.
local function bearing_angle(astro, target)
  local cam = ref("planet_camera")
  if not (cam and cam.fwd_x) then return nil end
  local d = space.dominant(astro.x, astro.y, astro.z)
  local b = d and space.body(d)
  if not b then return nil end
  -- Local up, and the two vectors flattened into the ground plane under it.
  local ux, uy, uz = astro.x - b.x, astro.y - b.y, astro.z - b.z
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  if ul < 1e-3 then return nil end
  ux, uy, uz = ux / ul, uy / ul, uz / ul

  local function flat(x, y, z)
    local k = x * ux + y * uy + z * uz
    x, y, z = x - ux * k, y - uy * k, z - uz * k
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-4 then return nil end
    return x / l, y / l, z / l
  end

  local tx, ty, tz = world_of(target)
  local ax, ay, az = world_of(astro)
  local gx, gy, gz = flat(tx - ax, ty - ay, tz - az)
  local fx, fy, fz = flat(cam.fwd_x, cam.fwd_y, cam.fwd_z)
  if not (gx and fx) then return nil end
  -- Screen-right is FORWARD × UP. (It was up × forward, which is screen-LEFT
  -- in this engine's right-handed frame: the card said the Command Centre was
  -- "ahead and to your left" while it stood on the right of the screen.)
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux
  return math.deg(math.atan2(gx * rx + gy * ry + gz * rz,
                             gx * fx + gy * fy + gz * fz))
end

local function bearing_to(astro, target)
  local ang = bearing_angle(astro, target)
  if not ang then return nil end
  local side = ang < 0 and "left" or "right"
  local a = math.abs(ang)
  if a < 22 then return "straight ahead" end
  if a < 68 then return "ahead and to your " .. side end
  if a < 112 then return "to your " .. side end
  if a < 158 then return "behind you, to the " .. side end
  return "directly behind you"
end

local function fmt_m(d)
  if d >= 1000 then return string.format("%.1f km", d / 1000) end
  return string.format("%.0f m", d)
end

-- ── what the next step is ───────────────────────────────────────────────────

-- Does this contract need a flight, or can it be finished on foot? A delivery
-- contract sends you mining; an altitude contract sends you to the hangar.
local function needs_flight(m)
  for _, g in ipairs(m.goals or {}) do
    if g.kind ~= "deliver" and g.kind ~= "sample" then return true end
  end
  return false
end

-- Is there a craft of ours we could actually WALK TO? Not "does a craft exist" —
-- ending a flight leaves the craft parked wherever it came down, which can be
-- another planet, and a fleet entry five thousand kilometres away is not a
-- rocket you can get into. Counting it made the card go quiet at exactly the
-- moment it needed to say "go and build another one".
local REACHABLE = 2000.0

local function has_vessel(astro)
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid then
      -- No position to compare (a craft still assembling) counts as reachable:
      -- the failure worth avoiding is telling someone to build a second rocket
      -- while they're standing next to their first one.
      if not (astro and n.x and astro.x) then return true end
      local dx, dy, dz = n.x - astro.x, n.y - astro.y, n.z - astro.z
      if math.sqrt(dx * dx + dy * dy + dz * dz) <= REACHABLE then return true end
    end
  end
  return false
end

-- The cheapest thing that flies: pod, small tank, small engine, parachute.
-- Below this the next step is money, not a rocket.
local ROCKET_MIN = 750

-- How to get the stuff a delivery contract wants, in one sentence: plants
-- come off with the cutter, everything else out of the rock with the laser.
local MINE_HINT = "Press 1 for the Mining Laser and hold LEFT MOUSE on a rock."
local CUT_HINT = "Press 2 for the Harvest Cutter and hold LEFT MOUSE on a plant."

-- A contract's brief is a paragraph for the Ops Board; the card gets its first
-- sentence. (The brief is hard-wrapped, so its first LINE can stop mid-clause.)
local function first_sentence(text)
  text = (text or ""):gsub("\n", " ")
  return text:match("^(.-[%.!?])%s") or text
end

-- The first delivery/sample goal on the contract that isn't ticked yet.
local function open_delivery(m, lines)
  for i, g in ipairs(m.goals or {}) do
    if (g.kind == "deliver" or g.kind == "sample") and (lines[i] or ""):sub(1, 3) ~= "✓" then
      return g
    end
  end
  return nil
end

-- ── contracts that name another world ──────────────────────────────────────
--
-- Generated contracts (missions.lua `genSpec`) send you somewhere: a flyby, an
-- orbit, a landing, a beacon, a haul, a recovery, a supply run. Each goal names
-- its `body`. The card's generic "mine ore for the contract" was wrong for every
-- one of them — the crystal a haul wants is on Nami, not under your feet — so
-- these get a step of their own, read off the first goal not yet ticked.

-- The first goal not ticked yet, with its index.
local function next_goal(m, lines)
  for i, g in ipairs(m.goals or {}) do
    if (lines[i] or ""):sub(1, 3) ~= "✓" then return g, i end
  end
  return nil
end

local function names_a_world(m)
  if m.gen then return true end
  for _, g in ipairs(m.goals or {}) do if g.body then return true end end
  return false
end

local function mat_label(mat)
  local mats = ref("materials")
  return (mats and mat and mats.label(mat)) or mat or "it"
end

-- Which world the crew is on (or in the grip of) right now.
local function world_here(astro)
  return astro and space.dominant(astro.x, astro.y, astro.z) or nil
end

local function offworld_step(m, goals, astro, label, pays)
  local g = next_goal(m, goals)
  if not g then return nil end
  local X = g.body or m.body
  local here = world_here(astro)
  local inv = ref("inventory")
  local function step(t)
    t.label, t.goals, t.pay = label, goals, pays
    return t
  end
  if g.kind == "deliver" or g.kind == "sample" then
    local from = X or m.body
    local carried = inv and g.mat and inv.count and inv.count("astro", g.mat) or 0
    if carried > 0 and here and here ~= from then
      return step({ key = "haulhome", at = "FacDepot",
        task = string.format("Sell the %s at the depot.", mat_label(g.mat)),
        hint = "The depot stores what the contract needs in the warehouse." })
    end
    if from and here == from then
      return step({ key = "haulget",
        task = string.format("Collect %s here on %s.", mat_label(g.mat), from),
        hint = MINE_HINT .. " A Cargo Bay holds more than the suit." })
    end
    return step({ key = "haul", at = has_vessel(astro) and nil or "FacHangar",
      task = string.format("Bring %s%s from %s.",
        g.kg and string.format("%d kg of ", g.kg) or "", mat_label(g.mat), from or "another world"),
      hint = "Fly there, dig or cut it, and fly it home to the depot." })
  end
  if g.kind == "recover" then
    return step({ key = "recover", task = "Fly it home and recover it at the base.",
      hint = "Land near the base and hold ENTER." })
  end
  -- Everything else is a flight to X.
  if not has_vessel(astro) and here ~= X then
    return step({ key = "build", at = "FacHangar",
      task = string.format("Build a craft that can reach %s.", X or "it"),
      hint = "The orbit map (M) shows where it is and plans the burn." })
  end
  local task = ({
    soi = "Fly to %s.",
    orbit = "Put a craft in orbit of %s.",
    land = "Land on %s.",
    flag = "Land on %s and step out.",
    cargo = "Orbit %s with the cargo aboard.",
  })[g.kind] or "Fly to %s."
  local hint = ({
    soi = "A flyby is enough — enter its sphere of influence. M opens the map.",
    orbit = "Keep the periapsis clear of the ground.",
    land = "Intact and stopped counts.",
    flag = "Standing on it plants the company beacon.",
    cargo = "Load the Cargo Bay from your suit pack at the craft.",
  })[g.kind] or "M opens the orbit map."
  if g.kind == "flag" and here == X then
    task, hint = "Step out onto " .. X .. ".", "F gets you out of the craft."
  end
  return step({ key = "go", task = string.format(task, X or "the target"), hint = hint })
end

-- ── the programme ──────────────────────────────────────────────────────────
--
-- The company's milestones (missions.lua PROGRAMME): First Steps, Rare Finds,
-- the Relay Network, Eyes in the Sky, Beyond. Nothing to sign — they count as
-- they happen — so the card shows the next one whenever no contract is on the
-- books, and a short line of it under a contract when one is.

-- "about 350 m, ahead and to your left" — rough on purpose: a survey report,
-- not a waypoint. nil without a position.
local function rough_way(astro, wx, wy, wz)
  if not (astro and wx) then return nil end
  local t = { worldX = wx, worldY = wy, worldZ = wz }
  local ax, ay, az = world_of(astro)
  local d = math.sqrt((wx - ax) ^ 2 + (wy - ay) ^ 2 + (wz - az) ^ 2)
  local way = bearing_to(astro, t)
  if d < 60 then return "close by — look for the glow" end
  local r = math.floor(d / 50 + 0.5) * 50
  return string.format("about %s%s", fmt_m(r), way and (", " .. way) or "")
end

-- The nearest of a list of body-relative points on `bname`, as a world point.
local function nearest_of(astro, bname, list, skip)
  local b = bname and space.body(bname)
  if not (astro and b) then return nil end
  local ax, ay, az = world_of(astro)
  local best, bd = nil, math.huge
  for _, p in ipairs(list or {}) do
    if not skip(p) then
      local x, y, z = b.x + p.x, b.y + p.y, b.z + p.z
      local d = (x - ax) ^ 2 + (y - ay) ^ 2 + (z - az) ^ 2
      if d < bd then best, bd = { x, y, z }, d end
    end
  end
  return best
end

local RARE_HINT = {
  cave = "They grow in the dark under rock shelves, where a cliff leans out over the ground, in grottoes at the foot of ravine walls and cliffs, and in hollows just under the ground — the Terrain Spade (3) opens a way in.",
  peak = "They grow on the highest ground, above the snow line where there is one.",
  ravine = "They grow on the floors of the deep cuts in the ground — walk the bottom, not the rim.",
  lake = "They grow right at the water's edge, never in it.",
  river = "They grow on the banks, a step up from the water.",
}

-- What to do about one programme goal: task, hint.
local function prog_guidance(mi, astro, m, g, niche)
  local home = mi.homeName and mi.homeName() or nil
  -- Rare Finds are the HOME world's (missions progHome): that is where the
  -- goals count, and where every niche and the geodes are guaranteed.
  local rhome = (mi.progHome and mi.progHome()) or home
  local net = mi.progNet or {}
  local pct = function(v) return string.format("%d%%", math.floor((v or 0) * 100 + 1e-6)) end
  if g.kind == "sample" and g.class == "flora" then
    return "Cut a plant.", CUT_HINT
  elseif g.kind == "sample" and g.class == "ore" then
    return "Mine some ore.", MINE_HINT
  elseif g.kind == "sample" and g.mat == "geode" then
    local hint = "Geode pockets sit 7–14 m down. With the Mining Laser out, a pulsing ring on the ground marks one within 35 m."
    local mf = ref("mineral_field")
    local list = (mf and mf.pockets and rhome) and mf.pockets(rhome) or nil
    local at = list and nearest_of(astro, rhome, list, function(p) return (p.left or 1) <= 0 end)
    local way = at and rough_way(astro, at[1], at[2], at[3])
    if way then hint = hint .. " Nearest signal: " .. way .. "." end
    return rhome and ("Dig out a Star Geode on " .. rhome .. ".") or "Dig out a Star Geode.", hint
  elseif g.kind == "rare" then
    local where = (mi.PROG_NICHE_WHERE or {})[niche] or "somewhere hard to reach"
    local hint = (RARE_HINT[niche] or "") .. " Rare plants glow, so look for the light."
    local ff = ref("flora_field")
    local list = (ff and ff.rarePlants and rhome) and ff.rarePlants(rhome) or {}
    if #list == 0 then
      hint = hint .. " The survey is still mapping " .. (rhome or "the planet") .. "."
    else
      local at = nearest_of(astro, rhome, list, function(p) return p.cut or p.niche ~= niche end)
      local way = at and rough_way(astro, at[1], at[2], at[3])
      if way then hint = hint .. " Nearest report: " .. way .. "." end
    end
    return "Find a rare plant " .. where .. (rhome and (" on " .. rhome) or "") .. ".", hint .. " " .. CUT_HINT
  elseif g.kind == "groundcov" then
    local hint = "Each Relay Beacon only has to see one that is already linked: put them on high ground, a few hundred metres apart."
    if net.api then
      hint = string.format("%s of the ground has a link home. %s", pct(net.ground), hint)
    end
    return string.format("Spread Relay Beacons across %s.", home or "the planet"), hint
  elseif g.kind == "orbitrelay" then
    return "Put a relay satellite in orbit.",
      string.format("A probe core, a Relay Dish and power, in any stable orbit of %s.", home or "home")
  elseif g.kind == "skycov" then
    return "Close the gaps in the sky.", string.format(
      "%sSatellites spaced evenly round the orbit cover the sky between them; three in one plane cover most of it.",
      net.api and (pct(net.sky) .. " of the sky is covered. ") or "")
  elseif g.kind == "linked" and g.class == "moon" then
    return "Link a moon to the network.", "A relay on or around a moon, in sight of one of yours."
  elseif g.kind == "linked" then
    return "Link another planet to the network.", "Across the system it takes a Deep Space Dish at one end at least."
  end
  return m.title, first_sentence(m.brief)
end

-- Goals met from a cockpit (a satellite, a link to another world).
local FLOWN = { orbitrelay = true, skycov = true, linked = true }

-- The programme's step for the card, or nil when it has nothing open. In
-- flight, only a goal you meet by flying.
local function prog_step(astro, flying)
  local mi = ref("missions")
  if not (mi and mi.progActive) then return nil end
  local act = mi.progActive()
  for _, m in ipairs(act) do
    local g, i, niche = mi.progNextGoal(m.id)
    if g and (not flying or FLOWN[g.kind]) then
      local task, hint = prog_guidance(mi, astro, m, g, niche)
      local others = {}
      for _, o in ipairs(act) do if o ~= m then others[#others + 1] = o.title end end
      local foot = nil
      if not flying then
        foot = (#others > 0 and ("Also open: " .. table.concat(others, ", ") .. ".  ") or "")
          .. "Paid contracts: the Ops Board at the Command Centre."
      end
      return { key = "prog:" .. m.id .. ":" .. i, label = "Programme · " .. m.title,
               task = task, hint = hint, goals = mi.progGoalLines(m.id),
               pay = "Completes for " .. mi.progRewardLine(m), foot = foot, prog = m.id }
    end
  end
  return nil
end

-- The short form under a contract: the milestone and its open goals.
local function prog_brief()
  local mi = ref("missions")
  if not (mi and mi.progActive) then return nil end
  local m = mi.progActive()[1]
  if not m then return nil end
  local open = {}
  for _, l in ipairs(mi.progGoalLines(m.id)) do
    if l:sub(1, 3) ~= "✓" and #open < 2 then open[#open + 1] = l end
  end
  return { label = "Programme · " .. m.title, lines = open }
end

-- The step, as a table the card renders. `at` is the facility to walk to.
-- Hints are ONE short sentence: the card is read at a glance while walking.
local current_step_inner
local function current_step(astro)
  local st = current_step_inner(astro)
  if st and not st.prog and st.key ~= "siting" then st.progBrief = prog_brief() end
  return st
end

current_step_inner = function(astro)
  local bf = ref("base_facilities")
  local mi = ref("missions")
  local co = ref("company")
  local inv = ref("inventory")

  if bf and not bf.sited then
    -- THE FIRST THING ANYONE READS, so it is also the only place the game gets
    -- to say how to move before you try.
    return { key = "siting", label = "Colony",
             task = "Your base is going up around you.",
             hint = "W A S D to walk, hold RIGHT MOUSE to look — ESC lists every control." }
  end

  local m = mi and mi.active and mi.byId(mi.active) or nil

  -- Something in the pack the depot would pay for. It takes the card over
  -- only when there is no contract to follow, or the pack is most of the way
  -- full: a handful of rock picked up on the way to the hangar used to replace
  -- the contract's guidance outright with "sell what you're carrying".
  local carried = inv and inv.mass("astro") or 0
  local cap = (inv and inv.cap and inv.cap("astro")) or 90
  -- …and the programme is something to follow too: a pack with a plant and a
  -- rock in it from First Steps is not a reason to drop the next milestone.
  local follow = m or prog_step(astro)
  if carried > 0.05 and (not follow or carried >= cap * 0.6) then
    local worth = co and co.money(inv.totalValue("astro")) or ""
    return { key = "sell", label = "Cargo", at = "FacDepot",
             task = "Sell what you're carrying.",
             hint = "The Commerce Depot buys it all — a first sale of anything pays a bonus.",
             pay = worth ~= "" and ("Pack is worth about " .. worth) or nil }
  end

  if m then
    local goals = mi.goalLines()
    local pays = co and ("Pays " .. co.money(m.reward)) or nil
    local label = "Contract · " .. m.title
    if names_a_world(m) then
      local st = offworld_step(m, goals, astro, label, pays)
      if st then return st end
    end
    if needs_flight(m) and not has_vessel(astro) then
      -- No rocket, and not the money for one: the ground game is the way back.
      if co and co.balance and co.balance() < ROCKET_MIN then
        return { key = "funds", label = label, at = "FacDepot",
                 task = "Raise money for a rocket.",
                 hint = MINE_HINT .. " Sell it at the depot.",
                 goals = goals, pay = pays }
      end
      return { key = "build", label = label, at = "FacHangar",
               task = "Build a craft that can do the job.",
               hint = "A pod, a tank, an engine and a parachute make a rocket.",
               goals = goals, pay = pays }
    end
    local want = open_delivery(m, goals)
    if want then
      if carried > 0.05 then
        return { key = "deliver", label = label, at = "FacDepot",
                 task = "Bring it to the depot.",
                 hint = "The depot stores what the contract needs and sells the rest.",
                 goals = goals, pay = pays }
      end
      local flora = want.class == "flora"
      return { key = "mine", label = label,
               task = flora and "Harvest plants for the contract." or "Mine ore for the contract.",
               hint = flora and CUT_HINT or MINE_HINT,
               goals = goals, pay = pays }
    end
    return { key = "fly", label = label, task = m.title,
             hint = first_sentence(m.brief),
             goals = goals, pay = pays }
  end

  -- No contract on the books: the programme's next milestone, if it has one.
  local ps = prog_step(astro)
  if ps then return ps end

  -- No contract and no milestone open. The first contract is the whole point
  -- of the game's opening; every later one is just "go and sign the next".
  local first = not (mi and #mi.completed() > 0)
  return { key = first and "first" or "next", label = "Ops", at = "FacCommand",
           task = first and "Sign your first contract."
                        or  "Sign your next contract.",
           hint = first
             and "Press E at the Command Centre to open the Ops Board."
             or  "The Ops Board in the Command Centre has more work." }
end

-- ── the contract that just paid ─────────────────────────────────────────────
--
-- The money moves the instant the last goal ticks. There is no counter to walk
-- to and no Ops clerk to see, and the only announcement was a Console line the
-- player is not looking at — so a contract flown correctly and paid in full
-- looked exactly like a contract that had quietly failed. "Nothing indicated
-- anywhere where to claim my reward."
--
-- This shows for a few seconds, and it shows MID-FLIGHT: the last goal of a
-- flight contract is "land intact", which ticks while you are still in the seat
-- with the card otherwise hidden.
local BANNER_TIME = 9.0

local function banner()
  local mi = ref("missions")
  local p = mi and mi.lastPaid
  if type(p) ~= "table" or not p.at then return nil end
  if time - p.at > BANNER_TIME then return nil end
  local co = ref("company")
  local prog = p.id == "prog"
  return {
    key = "paid", label = p.label or "CONTRACT COMPLETE",
    task = p.title or "Contract",
    pay = co and ("+" .. co.money(p.reward or 0) .. " paid into the company account")
      or string.format("+$%d paid into the company account", p.reward or 0),
    hint = prog and "The programme's next step is on this card." or "Sign the next one at the Ops Board.",
  }
end

-- ── the card ────────────────────────────────────────────────────────────────

-- Every row is full width and "fit" tall, so a hint that wraps to three lines
-- gets three lines of room. Sizes are the `hud/*` styles' (ui/solar.uistyle.ron).
local function row(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function describe(step, astro)
  local rows = {
    row("label", "hud/label", step.label or "Next"),
    row("task", "hud/task", step.task or ""),
  }

  -- Where it is. Only while you're not already standing at it — a direction you
  -- have already followed is noise.
  local target = step.at and find(step.at)
  if target and astro then
    local d = apart(astro, target)
    local name = FAC_LABEL[step.at] or step.at
    if d > params.arrived then
      -- Name and distance on one line, the bearing on its own: run together
      -- they wrapped at the card's width and left "right" alone on a line.
      rows[#rows + 1] = row("where", "hud/where", string.format("› %s — %s", name, fmt_m(d)))
      local way = bearing_to(astro, target)
      if way then
        rows[#rows + 1] = row("way", "hud/where", "   " .. way)
      end
    else
      rows[#rows + 1] = row("where", "hud/where",
        string.format("› You're at the %s — press E", name))
    end
  end

  if step.hint and step.hint ~= "" then
    rows[#rows + 1] = row("hint", "hud/hint", step.hint)
  end

  for i, line in ipairs(step.goals or {}) do
    local ticked = line:sub(1, 3) == "✓"
    rows[#rows + 1] = row("goal" .. i, ticked and "hud/goalDone" or "hud/goal", line)
  end

  if step.pay then
    rows[#rows + 1] = row("pay", "hud/pay", step.pay)
  end

  if step.progBrief then
    rows[#rows + 1] = row("plabel", "hud/label", step.progBrief.label)
    for i, l in ipairs(step.progBrief.lines) do
      rows[#rows + 1] = row("pgoal" .. i, "hud/goal", l)
    end
  end

  if step.foot then
    rows[#rows + 1] = row("foot", "hud/hint", step.foot)
  end

  -- `items` + a passthrough function is how a container takes a LIST of
  -- children: a bare array as a positional child would be read as one nameless
  -- element wrapping the lot, and the rows would stack on top of each other.
  return { "col", key = "card", style = "hud/card", w = "100%",
           dir = "col", gap = 6, pad = 14, align = "start",
           items = rows, function(row) return row end }
end

-- ── driver ──────────────────────────────────────────────────────────────────

local el

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

-- Is a panel the player opened in front of us? A card behind a panel is noise.
local function panel_up()
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return true end
  -- The map owns the whole screen, its readout included.
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  return false
end

-- Is the cockpit up? flight_hud publishes its layout only while it is drawing
-- (a craft is piloted, the map is shut, the world is loaded).
local function in_cockpit()
  local fh = ref("flight_hud")
  return fh ~= nil and fh.layout ~= nil
end

-- Is the programme's open goal one you meet from a cockpit (a satellite, a
-- link to another world)? Then the card stays up in flight.
local function prog_flown(mi)
  if not mi.progActive then return false end
  for _, m in ipairs(mi.progActive()) do
    local g = mi.progNextGoal(m.id)
    if g and FLOWN[g.kind] then return true end
  end
  return false
end

-- Nothing is up while the world is loading or while a panel you opened is in
-- front of you. In flight the card is the CONTRACT and nothing else: it used to
-- stand down entirely, and the flight HUD printed the goals into its text dump
-- instead — so the one thing you were up there to do was the one thing drawn
-- as fine print.
local function should_show(astro)
  if params.enabled < 0.5 or not shown then return false end
  -- `onFoot` is already false while the world loads, so there is no separate
  -- loading check to make here.
  if not crew_afoot() then
    local mi = ref("missions")
    if not (in_cockpit() and mi and (mi.active or prog_flown(mi))) then return false end
  end
  return not panel_up()
end

-- The flying version of the card: which contract, its goals ticking, what it
-- pays. No directions and no brief — you are already doing it.
local function flight_step()
  local mi, co = ref("missions"), ref("company")
  if mi and not mi.active then
    local ps = prog_step(find("Astronaut"), true)
    if ps then ps.hint = nil; return ps end
  end
  local m = mi and mi.byId and mi.byId(mi.active)
  return { key = "flight", label = "Contract",
           task = m and m.title or (mi and mi.activeLine and mi.activeLine()) or "",
           goals = mi and mi.goalLines() or {},
           pay = (m and co) and ("Pays " .. co.money(m.reward)) or nil }
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if input.pressed("o") then shown = not shown end

  local astro = find("Astronaut")
  -- The completion banner outranks everything except a panel: it is the game's
  -- one answer to "did that count?", and the moment it has to be given is
  -- usually the moment the card would otherwise be hidden.
  local paid = (params.enabled >= 0.5 and shown and not panel_up()) and banner() or nil
  if not paid and not should_show(astro) then
    if el then el.visible = false end
    marker_at = nil
    return
  end

  local step = paid or (crew_afoot() and current_step(astro) or flight_step())
  headline, targetName = step.task, step.at
  marker_at = crew_afoot() and step.at or nil
  if el then el.visible = true end

  -- Described every frame on purpose: the bearing line changes with every step
  -- you take, and `ui.make` RECONCILES rather than rebuilds — the cost is one
  -- table walk, not a screen that flickers and forgets. Every row carries a
  -- `key`, so a row that stays is the same entity from frame to frame.
  ui.make(node, describe(step, astro))
end

-- ── in the world ────────────────────────────────────────────────────────────
--
-- The card says "Vehicle Assembly — 73 m, behind you", which is a sentence to
-- act on; a marker over the building is the same answer you can steer by. The
-- objective's facility carries a small diamond with its name and distance, and
-- when it is off screen or behind you it sits on the screen edge on the side to
-- turn to. Every building also names itself once you are close enough to read
-- it, because five grey sheds look like five grey sheds.

-- How close a building has to be before it names itself.
local LABEL_NEAR = 48.0
-- How far above a building's origin its marker floats (clears the roofs).
local MARK_UP = { FacCommand = 9.0, FacHangar = 12.0, FacDepot = 7.0,
                  FacTracking = 10.0, FacPower = 8.0 }

-- The screen the HUD already uses: a label that would land on the card, the
-- status chips, the menu button or the tool belt is not drawn there.
local BLOCKERS = { "Objectives", "Menu Btn", "Status HUD", "Tool HUD" }
local function blocked_rects()
  local out = {}
  for _, nm in ipairs(BLOCKERS) do
    local n = find(nm)
    local e = n and n.getcomponent and n:getcomponent("UiElement")
    if n and n.uiRect and (not e or e.visible ~= false) then
      local x, y, w, h = n:uiRect()
      if x and w > 0 then out[#out + 1] = { x - 8, y - 8, w + 16, h + 16 } end
    end
  end
  return out
end
local function hits(rects, x, y, w, h)
  for _, r in ipairs(rects) do
    if x < r[1] + r[3] and x + w > r[1] and y < r[2] + r[4] and y + h > r[2] then return true end
  end
  return false
end

-- A UTF-8 string's length in characters, for sizing the backing behind it.
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- Text on a dark backing, so it reads over a white wall or a bright sky.
local function tag(x, y, text, size, r, g, b, a, rects)
  local w = chars(text) * size * 0.5 + size
  local h = size * 1.5
  if rects and hits(rects, x - w / 2, y - h / 2, w, h) then return false end
  draw.rect(x - w / 2, y - h / 2, w, h, 0.02, 0.04, 0.06, 0.62 * a, size * 0.35)
  draw.text(x, y - size * 0.62, text, size, r, g, b, a, "center")
  return true
end

local function up_at(x, y, z)
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return 0, 1, 0 end
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-6 then return 0, 1, 0 end
  return ux / l, uy / l, uz / l
end

-- Drawn in the camera pass, after the camera has moved, so a marker sits on
-- the building the frame shows rather than a frame behind it. worldToScreen
-- projects through the camera as it stands now (0.117), so a planet-fixed
-- point holds still on screen while the planet moves along its rails.
function lateUpdate(node, dt)
  if not (camera and camera.worldToScreen and camera.screenRect and draw and draw.text) then return end
  local astro = find("Astronaut")
  if not astro then return end
  if params.enabled < 0.5 or not crew_afoot() or panel_up() then return end
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / 720
  local rects = blocked_rects()
  for name, label in pairs(FAC_LABEL) do
    local f = find(name)
    if f then
      local d = apart(astro, f)
      local target = shown and name == marker_at and d > params.arrived
      if target or d < LABEL_NEAR then
        local wx, wy, wz = world_of(f)
        local ux, uy, uz = up_at(wx, wy, wz)
        local h = MARK_UP[name] or 12.0
        local sx, sy, dep, on = camera.worldToScreen(wx + ux * h, wy + uy * h, wz + uz * h)
        if target then
          local text = string.format("%s  ·  %s", label, fmt_m(d))
          -- In front of you and across the view, but above its top edge (a
          -- tall building close up): held just inside the top rather than
          -- called off screen.
          local front = sx and ((dep and dep > 0) or on)
          if front and sx >= vx + 40 * k and sx <= vx + vw - 40 * k then
            sy = math.max(vy + 70 * k, math.min(sy, vy + vh - 130 * k))
            on = true
          end
          if on and sx and sy >= vy + 40 * k and sy <= vy + vh - 120 * k then
            if tag(sx, sy - 26 * k, text, 14 * k, 0.82, 0.95, 0.90, 1.0, rects) then
              draw.circle(sx, sy, 5 * k, 0.28, 0.86, 0.74, 0.95)
              draw.circleOutline(sx, sy, 10 * k, 0.28, 0.86, 0.74, 0.8, 2 * k)
            end
          else
            -- Off screen: pinned to the edge on the side to turn to.
            local ang = bearing_angle(astro, f) or 0
            local right = ang >= 0
            local ex = right and (vx + vw - 150 * k) or (vx + 150 * k)
            local ey = vy + vh * 0.5
            tag(ex, ey, right and (text .. "  ›") or ("‹  " .. text), 14 * k,
                0.82, 0.95, 0.90, 1.0)
          end
        elseif on and sx then
          -- Fades in as you approach, so the base does not shout its names
          -- from across the plain.
          local a = math.max(0, math.min(1, (LABEL_NEAR - d) / 12))
          tag(sx, sy, label, 13 * k, 0.82, 0.91, 0.98, 0.9 * a, rects)
        end
      end
    end
  end
end
