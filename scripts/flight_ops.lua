-- FLIGHT OPS — how a flight ENDS.
--
-- The game had a launch and it had a crash. What it did not have was a way to
-- be finished flying: you took off, you came down somewhere that was not your
-- launchpad, and then you were a person standing in a desert next to a rocket
-- with no route back into the rest of the game. Ty, after the first contract:
-- "there was no way for me to complete the mission or exit back to the normal
-- state — i couldnt interact with any buildings or even use my lazer."
--
-- So: the moment a craft is DOWN AND STOPPED, this card comes up and says what
-- the two ways out are. It is one key either way, and which one you get depends
-- on where you parked:
--
--   RECOVER CRAFT   you're home — near the base, on the world the base is on.
--                   The crane takes the hull apart and pays back most of what
--                   it cost, the hold is emptied into the warehouse, and you're
--                   standing at the colony. This is the money loop closing.
--
--   END FLIGHT      you're not. The craft stays EXACTLY where it is — parked,
--                   still loaded, still on the Tracking Station's board — and
--                   Mission Control brings the crew home to the tracking dish.
--                   You can fly back out to it whenever you like.
--
--   CALL PICKUP     you are ON FOOT, away from the base, with nothing to fly.
--                   Mission Control sends a shuttle. This is the one that stops
--                   a bad landing from ending the save: the ship broke up, or
--                   you stepped out and walked over the horizon, and the
--                   alternative was a person standing in a desert forever. It
--                   bills you for the trip, and it bills you what you can
--                   afford — a fee that can REFUSE is a fee that softlocks,
--                   which is the thing this exists to prevent.
--
-- None of these is `F`. F still steps out at the hatch, because getting out
-- to walk around your landing site is a different intention from being done.
--
-- Before the craft has flown at all (still on the pad, clamps on or just let
-- go) the card says how to LAUNCH instead: a rocket that has never left the pad
-- was being offered RECOVER CRAFT, and nothing else on screen said what SPACE
-- would do. While flying, the card is down — the cockpit owns the screen and
-- the contract's goals are on the objectives card.
--
--   ENTER      the end-of-flight action (whichever one applies). Not R: R is
--              the RCS toggle, and a key that arms thrusters half the time is
--              not a key you press to finish. RECOVER is a HOLD: it scraps the
--              craft, and a single press can't be taken back.
--   F          step out at the hatch (vessel_controller owns that)

defaults = {
  --@header Card
  --@range 0 1
  enabled = 1,
  -- How far from the base a craft can be parked and still be RECOVERED there.
  -- Matches vessel_controller's own recovery range; a craft further out is one
  -- you leave behind rather than one the crane can reach.
  --@range 20 2000 --@units m
  home_range = 260.0,
  -- Where the crew is put down when a flight ends away from home: this far
  -- short of the Tracking Station, walking in. Standing them ON the dish is how
  -- you end up inside its collider.
  --@range 2 40 --@units m
  standoff = 11.0,

  --@header Crew pickup
  -- How far from the base the crew has to be, on foot, before a pickup is
  -- offered. Inside this you can walk, and being offered a taxi for a stroll
  -- across the colony reads as the game not trusting you.
  --@range 20 2000 --@units m
  pickup_range = 300.0,
  -- What the shuttle charges to come and get you, per kilometre travelled.
  --@range 0 500
  pickup_per_km = 40.0,
  -- The call-out fee, before distance. A pickup should sting a little even from
  -- just over the hill.
  --@range 0 5000
  pickup_base = 250.0,
  -- The most a pickup can ever cost, however far away you managed to get. A
  -- fee proportional to a solar system is a fee nobody can pay.
  --@range 0 100000
  pickup_max = 6000.0,
}

-- Published for the HUD / smoke harness.
mode = nil        -- nil | "prelaunch" | "flying" | "recover" | "leave" | "pickup"
value = 0         -- what a recovery would pay, right now
fee = 0           -- what a pickup would cost, right now

local el
local msg, msg_t = "", -100
-- RECOVER is held, not pressed: how long ENTER has been down, and whether this
-- hold already fired (so keeping it down doesn't fire again).
local HOLD = 1.0
local held, held_spent = 0.0, false

-- ── geometry ────────────────────────────────────────────────────────────────
-- The facilities are parented to their (orbiting) planet, so their .x/.y/.z are
-- body-relative and only become world coordinates through the parent. Anything
-- that compares them against a top-level node's raw .x is comparing two frames
-- and is wrong by the planet's orbital position — thousands of units.

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

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- Cross-script singletons, resolved once and kept. This card is rebuilt every
-- frame it is up, and `findScript` walks the scene; asking four times a frame is
-- how this project ended up doing a hundred scans a frame in the first place.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The colony's centre, in WORLD space, on the body it was sited on. nil when
-- there is no base yet (a brand-new save mid-siting) or it's on another world.
--
-- ⚠ `baseX/baseY/baseZ` ARE ALREADY WORLD. `base_facilities` re-derives them
-- from the body's live position every frame precisely so that they can be — the
-- save holds the body-relative offset, the published fields hold the answer.
-- This used to add the body position on top, which put the colony a whole
-- orbital radius away: standing in the middle of the base, the flight card
-- reported "5.4 km from the base" and offered a shuttle home.
--
-- It was wrong for everything that asks, not just the pickup — RECOVER CRAFT
-- could never trigger (you were never "within 260 m" of a point 5 km off), and
-- END FLIGHT set the crew down at that same phantom spot. `cheats.lua` has read
-- these as world all along, which is the tell.
local function base_world()
  local bf = ref("base_facilities")
  if not (bf and bf.sited and bf.baseBody) then return nil end
  local b = space.body(bf.baseBody)
  if not b then return nil end
  return bf.baseX, bf.baseY, bf.baseZ, b
end

-- Where the crew is set down when a flight ends: on the ground, `standoff`
-- metres short of the Tracking Station, facing into the colony. Falls back to
-- the base centre, and then to the dish itself, so a missing building is a
-- worse landing spot rather than a broken button.
local function crew_home()
  local cx, cy, cz, body = base_world()
  if not cx then return nil end
  local tx, ty, tz = cx, cy, cz
  local dish = find("FacTracking") or find("FacCommand")
  if dish then
    local dx, dy, dz = world_of(dish)
    local vx, vy, vz = dx - cx, dy - cy, dz - cz
    local l = len(vx, vy, vz)
    if l > params.standoff then
      local k = (l - params.standoff) / l
      tx, ty, tz = cx + vx * k, cy + vy * k, cz + vz * k
    end
  end
  -- Drop them onto the actual ground: the colony sits on relief, and a point
  -- computed from three building positions is only approximately on it.
  local ux, uy, uz = tx - body.x, ty - body.y, tz - body.z
  local ul = len(ux, uy, uz)
  if ul < 1e-3 then return tx, ty + 2.0, tz end
  ux, uy, uz = ux / ul, uy / ul, uz / ul
  local h = raycast(tx + ux * 60, ty + uy * 60, tz + uz * 60, -ux, -uy, -uz, 130.0)
  if h then return h.x + ux * 1.6, h.y + uy * 1.6, h.z + uz * 1.6 end
  return tx + ux * 1.6, ty + uy * 1.6, tz + uz * 1.6
end

-- ── what the flight is ──────────────────────────────────────────────────────

local function piloted()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting then return v end
  end
  return nil
end

-- How far the craft is from home, or nil when there is no base to be near.
local function home_distance(v)
  local cx, cy, cz = base_world()
  if not (cx and v.node and v.node.valid) then return nil end
  local n = v.node
  return len(n.x - cx, n.y - cy, n.z - cz)
end

-- How far the CREW is from home, on foot. nil when there is no base yet.
--
-- Deliberately not `home_distance`: that one measures a craft, and the whole
-- point of the pickup is that there may not be a craft any more.
local function crew_distance()
  local cx, cy, cz = base_world()
  local astro = find("Astronaut")
  if not (cx and astro and astro.valid) then return nil end
  return len(astro.x - cx, astro.y - cy, astro.z - cz)
end

-- What the shuttle charges. Distance-scaled, floored at the call-out and capped
-- — a crew that has managed to end up on the far side of the system still gets
-- a bill they could conceivably pay.
function pickupFee(dist)
  local d = dist or crew_distance() or 0
  return math.floor(math.min(params.pickup_max,
    params.pickup_base + (d / 1000.0) * params.pickup_per_km))
end

-- The state the card is describing. Global so the harness can drive it.
function survey()
  local v = piloted()
  if v then
    -- `hasFlown` is false only for a craft rolled out this session that has
    -- not yet left the pad; anything else got where it is by flying.
    if v.hasFlown == false then
      local t = v.tele
      return { v = v, mode = "prelaunch", clamped = t == nil or t.anchored,
               ready = t ~= nil and t.ready }
    end
    local down = v.parked and v.parked()
    if not down then return { v = v, mode = "flying" } end
    local d = home_distance(v)
    if d and d <= params.home_range then
      return { v = v, mode = "recover", dist = d,
               value = (v.recoverValue and v.recoverValue()) or 0 }
    end
    return { v = v, mode = "leave", dist = d }
  end

  -- NOBODY IS FLYING. That used to be the end of it — the card went away and so
  -- did every route home. If the crew is out there on foot, far from the base,
  -- the shuttle is the route.
  --
  -- `dist` is nil when the crew is nowhere near a body at all (thrown clear of a
  -- breakup, off into the void). That is the case that most needs the offer, so
  -- a missing distance ENABLES the pickup rather than suppressing it — the fee
  -- just falls back to the cap.
  local walker = ref("planet_walker")
  if not (walker and walker.onFoot) then return nil end
  if not base_world() then return nil end
  local d = crew_distance()
  if d and d <= params.pickup_range then return nil end
  -- No distance at all → the cap, directly. `pickup_max` is a FEE, not a range,
  -- and feeding it to `pickupFee` as one quotes a 40 km trip for a crew who are
  -- nowhere measurable at all.
  return { mode = "pickup", dist = d,
           fee = d and pickupFee(d) or math.floor(params.pickup_max) }
end

-- ── the actions ─────────────────────────────────────────────────────────────

-- Land at home → the crane. Everything about this already existed in
-- vessel_controller (it was reachable only from a row buried in the peripherals
-- console); all this does is put it one key from where you actually are.
local function do_recover(st)
  local ok, why = st.v.recoverReady()
  if not ok then
    msg, msg_t = "can't recover here — " .. (why or "?"), time
    return false
  end
  st.v.recoverCraft()
  msg, msg_t = "", -100
  return true
end

-- Land anywhere else → leave it. The craft is NOT destroyed, NOT unloaded and
-- NOT written off: it stays a parked craft you can fly home later, which is the
-- difference between "I left it there" and "I lost it".
local function do_leave(st)
  local hx, hy, hz = crew_home()
  if not hx then
    msg, msg_t = "no base to return to yet", time
    return false
  end
  local name = (st.v.craftName ~= "" and st.v.craftName) or "the craft"
  st.v.standDown(st.v.node, hx, hy, hz, 0, 0, 0)
  log(string.format("FLIGHT ENDED — %s stays parked where you left it; crew home at the base",
    name))
  msg, msg_t = "", -100
  return true
end

-- Stranded on foot → the shuttle comes and gets you.
--
-- The fee is charged if it can be, and the pickup happens either way. That
-- asymmetry is deliberate and is the whole design: this exists because a player
-- lost a ship and a save to a landing, and a rescue that can be declined for
-- want of funds recreates exactly the state it was written to end. Being broke
-- is a setback; being broke AND stranded forever is not a difficulty setting.
local function do_pickup(st)
  local hx, hy, hz = crew_home()
  if not hx then
    msg, msg_t = "no base to return to yet", time
    return false
  end
  local astro = find("Astronaut")
  if not (astro and astro.valid) then return false end

  local co = ref("company")
  local charged = 0
  if co and st.fee > 0 then
    if co.spend(st.fee, "crew pickup") then
      charged = st.fee
    else
      -- Short. `spend` is all-or-nothing on purpose ("a half-applied purchase
      -- is worse than a refusal"), so don't fight it — ask it for exactly the
      -- balance and write the remainder off.
      local b = co.balance()
      if b > 0 and co.spend(b, "crew pickup (part paid)") then charged = b end
    end
  end

  astro.x, astro.y, astro.z = hx, hy, hz
  -- AT REST, and this matters more than it looks: the crew reaching this
  -- function is often on a trajectory (thrown clear of a breakup), and arriving
  -- at the colony still carrying it just strands them again, from home.
  astro.vx, astro.vy, astro.vz = 0, 0, 0
  astro.visible = true

  if charged >= st.fee then
    log(string.format("PICKUP — shuttle inbound; crew home at the base (%s)",
      co and co.money(st.fee) or st.fee))
  else
    log(string.format(
      "PICKUP — shuttle inbound; crew home at the base. Billed %s of %s: "
      .. "the rest is written off.",
      co and co.money(charged) or charged, co and co.money(st.fee) or st.fee))
  end
  msg, msg_t = "", -100
  return true
end

-- Global so a button (or the harness) can fire it as well as the key.
function endFlight()
  local st = survey()
  if not st or st.mode == "flying" or st.mode == "prelaunch" then return false end
  if st.mode == "recover" then return do_recover(st) end
  if st.mode == "pickup" then return do_pickup(st) end
  return do_leave(st)
end

-- ── the card ────────────────────────────────────────────────────────────────

local function describe(st)
  local co = ref("company")
  local rows = {}
  -- ⚠ A WRAPPED ROW MUST NOT ALSO CARRY ITS OWN LINE BREAKS.
  --
  -- These hints used to be hand-wrapped with `\n` AND flagged `wrap = true`. In a
  -- card wide enough for the authored line length that is harmless — which is why
  -- the objectives card, top-right and wider, has always looked right. This one
  -- sits bottom-left and is narrower, so every hand-wrapped line wrapped AGAIN,
  -- and the row's `h = "fit"` came out a line or two short of what was drawn. The
  -- result is rows sitting on top of each other, which is what the card was doing
  -- in the screenshot.
  --
  -- So: one flowing sentence per row, and `wrap` decides where it breaks. The
  -- text no longer has an opinion about how wide the card is, which is the right
  -- division of labour anyway. Every row is "fit" tall, so it grows by the
  -- lines it wraps to at whatever width status_hud gives the card (it narrows,
  -- or moves above the navball, on a narrow screen).
  local function row(key, style, text, wrap)
    if wrap then text = tostring(text):gsub("%s*\n%s*", " ") end
    rows[#rows + 1] = { "text", key = key, style = style, w = "100%", h = "fit",
                        wrap = true, text = text }
  end

  if st.mode == "prelaunch" then
    row("label", "hud/label", "ON THE PAD")
    if st.clamped then
      row("task", "hud/task", st.ready and "[SPACE]   RELEASE CLAMPS" or "Assembling on the pad…")
      row("hint", "hud/hint",
        "Hold SHIFT to throttle up (Z for full, X to cut). SPACE again fires the next stage.",
        true)
    else
      row("task", "hud/task", "[SHIFT]   THROTTLE UP")
      row("hint", "hud/hint", "Z for full throttle, X to cut. W A S D Q E steer.", true)
    end
  elseif st.mode == "recover" then
    row("label", "hud/label", "DOWN AT THE BASE")
    row("task", "hud/task", "Hold [ENTER]   RECOVER CRAFT")
    -- The hold's progress, so a held key visibly does something.
    rows[#rows + 1] = { "box", key = "hold", style = "hud/track", w = "100%", h = 6,
      { "box", key = "f", x = 1, y = 1, w = string.format("%d%%", math.floor(math.min(1, held / HOLD) * 99)),
        h = 4, radius = 1, fill = { 0.28, 0.86, 0.74 } } }
    row("hint", "hud/hint",
      "The crane strips the hull and refunds most of what it cost, and\n" ..
      "everything in the hold goes straight into the warehouse.", true)
    if co and st.value and st.value > 0 then
      row("pay", "hud/pay", "Hardware refund " .. co.money(st.value))
    end
  elseif st.mode == "pickup" then
    row("label", "hud/label", "STRANDED")
    row("task", "hud/task", "[ENTER]   CALL FOR PICKUP")
    row("hint", "hud/hint",
      "Mission Control sends a shuttle and brings you back to the colony.\n" ..
      "Anything you left out here stays where it is.", true)
    local short = co and not co.afford(st.fee)
    row("pay", "hud/pay", "Shuttle fee " .. (co and co.money(st.fee) or st.fee)
      .. (short and "  (more than you have — the rest is written off)" or ""))
    if st.dist then
      row("where", "hud/where", string.format("› %.1f km from the base", st.dist / 1000))
    else
      -- No dominant body under the crew at all. Say so plainly rather than
      -- printing a distance of nil: this is the thrown-clear-of-a-breakup case.
      row("where", "hud/where", "› off the map — no world beneath you")
    end
  else
    row("label", "hud/label", "DOWN")
    row("task", "hud/task", "[ENTER]   END FLIGHT — leave the craft here")
    row("hint", "hud/hint",
      "It stays exactly where it is, still loaded and still transmitting\n" ..
      "to the Tracking Station. The crew comes home to the base.", true)
    if st.dist then
      row("where", "hud/where", string.format("› %.1f km from the base",
        st.dist / 1000))
    end
  end

  if msg ~= "" and time - msg_t < 5.0 then
    row("msg", "hud/where", "» " .. msg, true)
  end
  if st.mode == "recover" or st.mode == "leave" then
    row("eva", "hud/hint", "[F] step out and walk around instead")
  end

  return { "col", key = "flight", style = "hud/card", w = "100%",
           dir = "col", gap = 6, pad = 14, align = "start",
           items = rows, function(r) return r end }
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local st = (params.enabled >= 0.5) and survey() or nil
  mode = st and st.mode or nil
  value = (st and st.value) or 0
  fee = (st and st.fee) or 0
  -- A panel the player opened is in front of it (the pause menu, a facility,
  -- the ops board, the pack); the card waits behind it rather than under it.
  local pm, fm, ob, ip = ref("pause_menu"), ref("facility_menu"), ref("ops_board"),
    ref("inventory_panel")
  local covered = (pm and pm.open) or (ip and ip.open)
    or (fm and fm.isOpen and fm.isOpen()) or (ob and ob.isOpen and ob.isOpen())
  -- In flight the cockpit owns the screen; the card comes back when you're down.
  if not st or covered or st.mode == "flying" then
    if el then el.visible = false end
    held, held_spent = 0.0, false
    return
  end
  if el then el.visible = true end
  if st.mode == "recover" then
    if input.key("enter") then
      held = held + dt
      if held >= HOLD and not held_spent then
        held_spent = true
        endFlight()
      end
    else
      held, held_spent = 0.0, false
    end
  elseif (st.mode == "leave" or st.mode == "pickup") and input.pressed("enter") then
    endFlight()
  end
  ui.make(node, describe(st))
end
