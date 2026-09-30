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
local function bearing_to(astro, target)
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
  -- Right-handed screen-right, so a positive angle really is to your right.
  local rx = uy * fz - uz * fy
  local ry = uz * fx - ux * fz
  local rz = ux * fy - uy * fx
  local ang = math.deg(math.atan2(gx * rx + gy * ry + gz * rz,
                                  gx * fx + gy * fy + gz * fz))
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

-- The step, as a table the card renders. `at` is the facility to walk to.
-- Hints are ONE short sentence: the card is read at a glance while walking.
local function current_step(astro)
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
  if carried > 0.05 and (not m or carried >= cap * 0.6) then
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

  -- No contract on the books. The first one is the whole point of the game's
  -- opening; every later one is just "go and sign the next".
  local first = not (mi and #mi.completed() > 0)
  return { key = first and "first" or "next", label = "Ops", at = "FacCommand",
           task = first and "Sign your first contract."
                        or  "Sign your next contract.",
           hint = first
             and "Press E at the Command Centre and pick one on the Ops Board."
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
  return {
    key = "paid", label = "CONTRACT COMPLETE",
    task = p.title or "Contract",
    pay = co and ("+" .. co.money(p.reward or 0) .. " paid into the company account")
      or string.format("+$%d paid into the company account", p.reward or 0),
    hint = "Sign the next one at the Ops Board.",
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
      local way = bearing_to(astro, target)
      rows[#rows + 1] = row("where", "hud/where",
        string.format("› %s — %s%s", name, fmt_m(d), way and ("  ·  " .. way) or ""))
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
    if not (in_cockpit() and mi and mi.active) then return false end
  end
  return not panel_up()
end

-- The flying version of the card: which contract, its goals ticking, what it
-- pays. No directions and no brief — you are already doing it.
local function flight_step()
  local mi, co = ref("missions"), ref("company")
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
    return
  end

  local step = paid or (crew_afoot() and current_step(astro) or flight_step())
  headline, targetName = step.task, step.at
  if el then el.visible = true end

  -- Described every frame on purpose: the bearing line changes with every step
  -- you take, and `ui.make` RECONCILES rather than rebuilds — the cost is one
  -- table walk, not a screen that flickers and forgets. Every row carries a
  -- `key`, so a row that stays is the same entity from frame to frame.
  ui.make(node, describe(step, astro))
end
