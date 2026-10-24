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
-- ABORT FLIGHT (ESC ▸ pause menu) is the fourth, and it is the one that is
-- ALWAYS there. END FLIGHT needs the craft down and stopped, so a craft that
-- will never be down — out of fuel in an orbit, or leaving the world entirely —
-- had no way to end at all. Abort brings the crew home from anywhere for a fee
-- (pay what you can, like the pickup), and the craft stays where it is: still
-- flying its orbit, still on the Tracking Station's board.
--
-- THE FLEET. A craft you leave behind is written to the save (`fleet.craft`)
-- and rebuilt where you left it the next time the world loads — which is what
-- makes "fly back out to it whenever you like" true. Before this, any parked
-- craft was gone the moment the scene changed: one trip to the Vehicle Assembly
-- and the board was empty. The Tracking Station lists the fleet and TAKES
-- CONTROL of any crewed craft on it (`takeControlOf`).
--
-- THE LAUNCH WORLD. The builder has no planets in its scene, so the base
-- world's radius, gravity and sphere of influence are published from here
-- (`launch.world`) for it to rate the engines and quote TWR against.
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

  --@header Abort flight
  -- Bringing the crew home from a flight that cannot end on its own: the
  -- call-out, plus the same per-km as a pickup, capped. Charged as far as the
  -- account goes — the rest is written off, never refused.
  --@range 0 5000
  abort_base = 400.0,
  --@range 0 100000
  abort_max = 2500.0,
  -- Taking control of a craft with no live comms link means flying a crew out
  -- to it: this much per km from the base, on top of the call-out.
  --@range 0 5000
  transfer_base = 150.0,
}

-- Published for the HUD / smoke harness.
mode = nil        -- nil | "prelaunch" | "flying" | "recover" | "leave" | "pickup"
value = 0         -- what a recovery would pay, right now
fee = 0           -- what a pickup would cost, right now
abortArmedAt = nil  -- the first press of Abort flight, waiting for its confirm
ABORT_CONFIRM = 5.0

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
    -- A rover driven off its spot (`leftPad`) is past the pad even though
    -- it never flew.
    if v.hasFlown == false and v.leftPad ~= true then
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
  -- A probe flown from the ground: there's nobody to bring home. Letting go of
  -- it is all END FLIGHT means; the controls go back to the crew.
  if st.v.crewAboard == false and st.v.releaseControl then
    st.v.releaseControl()
    switchToCrew()
    log("FLIGHT ENDED — " .. tostring(st.v.craftName or "the probe") .. " stays where it is")
    msg, msg_t = "", -100
    return true
  end
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

-- ── ABORT FLIGHT ────────────────────────────────────────────────────────────

-- The craft's distance from the base, or nil when it is not on the base's world
-- (a solar orbit, a moon) — which prices at the cap.
local function craft_distance(v)
  local cx, cy, cz, body = base_world()
  if not (cx and v and v.node and v.node.valid) then return nil end
  local n = v.node
  if space.dominant and space.dominant(n.x, n.y, n.z) ~= body.name then return nil end
  return len(n.x - cx, n.y - cy, n.z - cz)
end

function abortFee(dist)
  if not dist then return math.floor(params.abort_max) end
  return math.floor(math.min(params.abort_max,
    params.abort_base + (dist / 1000.0) * params.pickup_per_km))
end

-- What Abort would do right now, or nil when there is nothing to abort (no
-- craft in flight and nobody stranded, or no base to come home to).
--   { kind = "abort", v, fee, dist }   a crewed flight, anywhere
--   { kind = "pickup", fee, dist }     on foot, far from home (same as the card)
function abortQuote()
  if not base_world() then return nil end
  local v = piloted()
  if v then
    -- Never flown: you are standing on your own pad. F gets you out.
    if v.hasFlown == false and v.leftPad ~= true then return nil end
    -- A probe flown from the ground has no crew to fetch: [ ] goes back to them.
    if v.crewAboard == false then return nil end
    local d = craft_distance(v)
    return { kind = "abort", v = v, dist = d, fee = abortFee(d) }
  end
  local st = survey()
  if st and st.mode == "pickup" then return { kind = "pickup", dist = st.dist, fee = st.fee } end
  return nil
end

-- Charge what can be charged; never refuse. Returns what was taken.
local function bill(amount, why)
  local co = ref("company")
  if not co or amount <= 0 then return 0 end
  if co.spend(amount, why) then return amount end
  local b = co.balance and co.balance() or 0
  if b > 0 and co.spend(b, why .. " (part paid)") then return b end
  return 0
end

function abortFlight()
  local q = abortQuote()
  abortArmedAt = nil
  if not q then return false end
  if q.kind == "pickup" then return endFlight() end
  local hx, hy, hz = crew_home()
  if not hx then
    msg, msg_t = "no base to return to yet", time
    return false
  end
  local name = (q.v.craftName ~= "" and q.v.craftName) or "the craft"
  -- Throttle off and out of the seat; the craft keeps flying whatever it was
  -- flying. The fleet sync below keeps it on the board.
  q.v.standDown(q.v.node, hx, hy, hz, 0, 0, 0)
  local paid = bill(q.fee, "flight abort — crew recovery")
  local co = ref("company")
  log(string.format("FLIGHT ABORTED — crew home at the base; %s left where it is. Billed %s%s",
    name, co and co.money(paid) or paid,
    paid < q.fee and string.format(" of %s (the rest written off)", co and co.money(q.fee) or q.fee) or ""))
  msg, msg_t = "", -100
  return true
end

-- For the pause menu: its row text, or nil when there is nothing to abort.
function abortLabel()
  local q = abortQuote()
  if not q then abortArmedAt = nil return nil end
  local co = ref("company")
  local fee = co and co.money(q.fee) or ("$" .. q.fee)
  local armed = abortArmedAt and time - abortArmedAt <= ABORT_CONFIRM
  if q.kind == "pickup" then
    return armed and ("Confirm: call the shuttle home — " .. fee)
      or ("Call for pickup — return the crew to base (" .. fee .. ")")
  end
  return armed and ("Confirm abort — the craft stays where it is, crew home — " .. fee)
    or ("Abort flight — return the crew to base (" .. fee .. ")")
end

-- The pause menu's click: the first arms, the second (within ABORT_CONFIRM s)
-- fires. Returns true when the crew is home.
function abortClick()
  if not abortQuote() then return false end
  if abortArmedAt and time - abortArmedAt <= ABORT_CONFIRM then
    return abortFlight()
  end
  abortArmedAt = time
  return false
end

-- ── THE FLEET ───────────────────────────────────────────────────────────────
--
-- save `fleet.craft` = { [fid] = record }, one per craft that has flown:
--   name, body, x y z (origin, body-relative), vx vy vz (body-relative),
--   pitch yaw roll, landed, fuel, charge, parts = { blueprint records }
--
-- Kept current once a second from the live craft; a craft that disappears
-- while the scene is running (recovered, destroyed, docked into another) leaves
-- the record with it. A record with no live craft at scene start is a craft to
-- rebuild.
local FLEET_KEY = "fleet.craft"
local fleet_live = {}      -- node id → fid, for craft alive in this scene
local fleet_born = {}      -- node id → when we rebuilt it (its controller starts later)
local fleet_t = -100
local restore = nil        -- fid → { tries, wait } while rebuilding
restore_t0 = nil           -- when this scene's restore began (bounds the wait for the base)

local function fleet()
  local f = save.get(FLEET_KEY)
  return type(f) == "table" and f or {}
end

local function next_fid()
  local n = (save.get("fleet.next") or 0) + 1
  save.set("fleet.next", n)
  return "c" .. n
end

-- A live craft as a record. nil when it can't be described (no manifest, no
-- body under it, mid-assembly).
local function describe_craft(v)
  local n = v.node
  if not (n and n.valid and (v.fleetParts or v.dockManifest)) then return nil end
  -- fleetParts is the controller's own part list; dockManifest (matched by
  -- child position, for docking) is the fallback for an older controller.
  local man
  if v.fleetParts then
    local fp = v.fleetParts()
    if fp then
      man = { name = n.name, parts = {}, fuel = fp.fuel, charge = fp.charge, groups = fp.groups, controls = fp.controls,
              probe = fp.probe, crew = fp.crew, station = fp.station, flown = fp.flown }
      for i, d in ipairs(fp.parts) do man.parts[i] = { rec = d } end
    end
  else
    man = v.dockManifest(nil)
  end
  if not (man and man.parts and #man.parts > 0) then return nil end
  local info = assembly and assembly.info and assembly.info(n)
  local ox, oy, oz = n.x, n.y, n.z
  if info and info.origin then ox, oy, oz = info.origin.x, info.origin.y, info.origin.z end
  local bname = space.dominant(ox, oy, oz)
  local b = bname and space.body(bname)
  if not b then return nil end
  -- Deep copies: a part's live state (`st` — a battery's charge, a panel's
  -- fold) must be the record's own, not shared with the craft still flying.
  local function dcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, val in pairs(t) do o[k] = dcopy(val) end
    return o
  end
  -- ...and save.set holds four tables deep at most, which a fleet record
  -- already is at a part's fields: modules and state go in as strings.
  local E = ref("electronics")
  local recs = {}
  for i, p in ipairs(man.parts) do
    if E and E.packRecord then recs[i] = E.packRecord(p.rec or {})
    else
      local r = {}
      for k, val in pairs(p.rec or {}) do if type(val) ~= "table" then r[k] = val end end
      recs[i] = r
    end
  end
  -- Velocity in the dominant body's frame (what the HUD and space.elements
  -- read). For a craft coasting in the distant-craft LOD the node reads its
  -- rails velocity, the same as assembly.info (floptle/0402, 0.117.0-rc3).
  local vx, vy, vz = n.vx or 0, n.vy or 0, n.vz or 0
  -- LANDED means down and stopped. `grounded` alone is not enough: a craft
  -- coasting unpiloted in orbit was reported grounded once nobody was flying
  -- it, and a record that says "landed" is rebuilt on the ground.
  -- So "landed" also needs the ground to be near: within the world's relief
  -- band of its surface, on a body that has a surface. (A craft in the
  -- engine's distant-craft LOD reports its real rails state since 0.117,
  -- floptle/0402: coasting, not grounded, at its orbital velocity.)
  local ralt = len(ox - b.x, oy - b.y, oz - b.z) - b.radius
  -- (a rover stands on its tyre bodies, not its hull: r2OnWheels)
  local on_ground = info and (info.grounded or (v.r2OnWheels and v.r2OnWheels()))
  -- A craft the distant-craft LOD holds is frozen where it stood and never
  -- reports grounded: stopped, with the ground right under its base, it is down.
  if info and not on_ground and len(vx, vy, vz) < 0.2 and (b.soi or -1) > 0 then
    local ux, uy, uz = ox - b.x, oy - b.y, oz - b.z
    local ul = len(ux, uy, uz)
    if ul > 1e-3 then
      ux, uy, uz = ux / ul, uy / ul, uz / ul
      local h = raycast(ox + ux, oy + uy, oz + uz, -ux, -uy, -uz, 3.0, n)
      on_ground = h ~= nil and h.distance <= 2.0
    end
  end
  local landed = on_ground and math.sqrt(vx * vx + vy * vy + vz * vz) < 1.5
    and (b.soi or -1) > 0 and ralt < math.max(30, b.radius * 0.25)
  if landed and space.elements then
    local o = space.elements(ox, oy, oz, vx, vy, vz)
    if o and o.periapsis and o.periapsis > b.radius then landed = false end
  end
  -- SPLASHED: floating, and as good as stopped. Kept like a landed craft
  -- (where it is, not along a conic from the sea's surface, which runs into
  -- the planet), and brought back at the surface it floated on, not set down
  -- on the seabed.
  local splashed = info ~= nil and v.isSplashed ~= nil and v.isSplashed() == true
    and len(vx, vy, vz) < 1.5
  if splashed then landed = true end
  return {
    -- (the craft's own name: node names can't be written from Lua)
    name = (v.craftName ~= nil and v.craftName ~= "Vessel" and v.craftName) or man.name or "Vessel", body = bname,
    x = ox - b.x, y = oy - b.y, z = oz - b.z,
    vx = vx, vy = vy, vz = vz,
    pitch = n.pitch or 0, yaw = n.yaw or 0, roll = n.roll or 0,
    landed = landed and true or false, splashed = splashed or nil,
    fuel = man.fuel or 0, charge = man.charge or 0,
    groups = dcopy(man.groups), controls = dcopy(man.controls), probe = man.probe == true, crew = man.crew == true,
    -- the crew position they sit in (a pod or a seat), and whether it ever flew
    station = man.station, flown = man.flown ~= false,
    stime = space.time and space.time() or 0,
    pod = (function()
      for _, r in ipairs(recs) do if r.kind == "crewed" or r.id == "pod" then return true end end
      return false
    end)(),
    comms = (function()
      for _, r in ipairs(recs) do if (r.comms or 0) == 1 then return true end end
      return false
    end)(),
    parts = recs, t = time,
  }
end

function fleetSync()
  local f = fleet()
  local alive = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    -- (a lost craft — its pod gone — is a wreck, not a craft to fly or recover;
    -- `v.destroyed` is the controller's local and always read nil)
    -- A craft is kept once it has LEFT ITS LAUNCH SPOT (`leftPad`: the clamps
    -- let go, or it moved off), not only once it has flown: a rover never
    -- leaves the ground, so `hasFlown` alone dropped every rover driven off the
    -- pad from the save. Only a rollout still standing in its clamps is skipped.
    if n and n.valid and (v.hasFlown ~= false or v.leftPad == true) and not (v.isLost and v.isLost()) then
      local fid = fleet_live[n.id]
      local rec = describe_craft(v)
      if rec then
        if not fid then fid = next_fid(); fleet_live[n.id] = fid end
        rec.fid = fid
        f[fid] = rec
      end
      if fid then alive[fid] = true end
    end
  end
  -- A craft that was alive in this scene and isn't now is gone for good.
  for id, fid in pairs(fleet_live) do
    if not alive[fid] and time - (fleet_born[id] or -100) > 10.0 then
      f[fid] = nil
      fleet_live[id] = nil
    end
  end
  save.set(FLEET_KEY, f)
  return f
end

-- Is this record's craft alive in the scene? → its controller handle.
local function live_of(fid)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and fleet_live[v.node.id] == fid then return v end
  end
  return nil
end

-- The vessel frame from Euler angles (YXZ — the same as vessel_controller).
local function basis_of(pitch, yaw, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cx, sx = math.cos(pitch), math.sin(pitch)
  local cz, sz = math.cos(roll), math.sin(roll)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end

-- The parachute canister was redrawn to sit on the pod's collar: 0.61 → 0.34 m
-- tall, 0.28 → 0.22 m half-wide (builder.lua refit_chutes does the same for a
-- saved build). A craft recorded before keeps the old centre, which would
-- leave the new canister floating above its mount: sit it back down.
local CHUTE_H, CHUTE_R = 0.34, 0.22
local function refit_chutes(list)
  local by, kids = {}, {}
  for _, d in pairs(list) do
    by[d.uid] = d
    local pu = d.parent or 0
    if pu ~= 0 then kids[pu] = kids[pu] or {}; kids[pu][#kids[pu] + 1] = d end
  end
  local function move(d, dx, dy, dz, root)
    d.x, d.y, d.z = (d.x or 0) + dx, (d.y or 0) + dy, (d.z or 0) + dz
    for _, k in ipairs(kids[d.uid] or {}) do
      if not (root and k.att == "bottom") then move(k, dx, dy, dz, false) end
    end
  end
  for _, d in pairs(list) do
    if (d.chute or 0) == 1 and d.prefab == "PartChute" and d.h and math.abs(d.h - CHUTE_H) > 1e-3 then
      local par = by[d.parent or 0]
      if d.att == "radial" and par then
        local ox, oz = (d.x or 0) - (par.x or 0), (d.z or 0) - (par.z or 0)
        local l = math.sqrt(ox * ox + oz * oz)
        local pull = (d.rx or 0.28) - CHUTE_R
        if l > 1e-3 then move(d, -ox / l * pull, 0, -oz / l * pull, true) end
      else
        -- down along the part's own up (YXZ, as everywhere in this project)
        local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
        local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
        local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
        local dh = (d.h - CHUTE_H) * 0.5
        move(d, -(-cy * sz + sy * sx * cz) * dh, -(cx * cz) * dh, -(sy * sz + cy * sx * cz) * dh, true)
      end
      d.h, d.rx, d.rz = CHUTE_H, CHUTE_R, CHUTE_R
    end
  end
end

-- The surface a landed craft stood on, under its record's base point (world
-- wx, wy, wz; u = the body's up there): the pad's deck, a hardstand, a roof or
-- the ground — whatever is THERE, static colliders and meshes as well as the
-- terrain (raycast answers all of them). Rays come down from 40 m up; a hit
-- more than 1.5 m above the record (a service tower's arm, a mast, a roof the
-- craft was parked beside) is something overhead, so the next ray starts just
-- under it. The first surface at or below the record's height + 1.5 m wins.
-- Global so tests and probes can ask it.
function landing_surface(wx, wy, wz, ux, uy, uz)
  local ox, oy, oz = wx + ux * 40, wy + uy * 40, wz + uz * 40
  for _ = 1, 8 do
    local hit = raycast(ox, oy, oz, -ux, -uy, -uz, 160.0)
    if not hit then return nil end
    local above = (hit.x - wx) * ux + (hit.y - wy) * uy + (hit.z - wz) * uz
    if above <= 1.5 then return hit end
    ox, oy, oz = hit.x - ux * 0.05, hit.y - uy * 0.05, hit.z - uz * 0.05
  end
  return nil
end

-- Rebuild one record as a live craft. Returns true once the spawn is under way.
local function respawn(fid, rec)
  local b = space.body(rec.body)
  if not (b and spawn and assembly) then return false end
  if rec.parts then refit_chutes(rec.parts) end
  local wx, wy, wz = b.x + rec.x, b.y + rec.y, b.z + rec.z
  if rec.landed and not rec.splashed then
    -- The ground has to be there first, or a landed craft falls through a
    -- world that hasn't streamed in yet (the launch pad waits the same way).
    local ux, uy, uz = rec.x, rec.y, rec.z
    local ul = len(ux, uy, uz)
    if ul < 1e-3 then return false end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    if terrain and terrain.warm then terrain.warm(rec.body) end
    -- A craft left at the base stands on what the base built (the pad's
    -- deck, an apron): wait for the base to be standing before looking for
    -- it, or the ray finds the bare ground under the pad and the craft is
    -- rebuilt INSIDE the pad when it goes up round it. (Bounded: a base that
    -- never finishes doesn't hold the fleet back for good.)
    local bf = ref("base_facilities")
    if bf and not bf.sited and (restore_t0 or 0) > 0 and time - restore_t0 < 30.0 then
      local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
      if save.get("base.body") == rec.body and bx
        and len(rec.x - bx, rec.y - by, rec.z - bz) < (bf.FOOTPRINT_RADIUS or 175.0) + 50.0 then
        return false
      end
    end
    local hit = landing_surface(wx, wy, wz, ux, uy, uz)
    if not hit then return false end
    -- Set down a hand's width above where it stood, on the surface as it is
    -- NOW. The record's height and the streamed ground can disagree by metres;
    -- a craft left hanging is frozen in the air by the distant-craft LOD and
    -- drops when it wakes (a crew sent to it found a wreck), and a buried one
    -- is thrown out of the ground.
    local above = (wx - hit.x) * ux + (wy - hit.y) * uy + (wz - hit.z) * uz
    if above > 1.0 or above < -0.05 then
      wx, wy, wz = wx - ux * above, wy - uy * above, wz - uz * above
    end
    wx, wy, wz = wx + ux * 0.25, wy + uy * 0.25, wz + uz * 0.25
  end
  -- In flight, the record is carried along its conic to NOW: where the craft
  -- has got to since it was written, and how fast it is going there.
  local fvx, fvy, fvz = rec.vx or 0, rec.vy or 0, rec.vz or 0
  if not rec.landed and space.propagate and space.time and rec.stime and (b.mu or 0) > 0 then
    local dt = space.time() - rec.stime
    if dt > 0 and dt < 1e7 then
      local px, py, pz, pvx, pvy, pvz = space.propagate(rec.x, rec.y, rec.z, fvx, fvy, fvz, b.mu, dt)
      if pvx then
        wx, wy, wz = b.x + px, b.y + py, b.z + pz
        fvx, fvy, fvz = pvx, pvy, pvz
      end
    end
  end
  local rx, up, rz = basis_of(rec.pitch or 0, rec.yaw or 0, rec.roll or 0)
  local total, landed = #rec.parts, 0
  spawn("Vessel", vec3(wx, wy, wz), function(v)
    v:setAngles(rec.yaw or 0, rec.pitch or 0, rec.roll or 0)
    v.name = rec.name
    fleet_live[v.id] = fid
    fleet_born[v.id] = time
    -- vessel_controller's start reads this (the undock handoff): the craft
    -- wakes with these parts, this fuel and this charge, not the shipyard's.
    -- In flight, the velocity rides in the handoff too: the craft's controller
    -- gives it once its parts weigh what they carry (vessel_controller
    -- massSync). Pushed any earlier, the push is sized for the prefabs' dry
    -- masses and lands on the fuelled craft — a 44 m/s orbit restored at 32,
    -- and spun up, because the centre of mass moved under it.
    save.set("dock.handoff." .. tostring(v.id or 0),
      { parts = rec.parts, fuel = rec.fuel, charge = rec.charge, lockout = 2.0, groups = rec.groups, controls = rec.controls,
        crew = rec.crew, name = rec.name, station = rec.station, flown = rec.flown,
        vel = (not rec.landed) and { x = fvx, y = fvy, z = fvz } or nil })
    for _, d in ipairs(rec.parts) do
      local px = wx + rx[1] * d.x + up[1] * d.y + rz[1] * d.z
      local py = wy + rx[2] * d.x + up[2] * d.y + rz[2] * d.z
      local pz = wz + rx[3] * d.x + up[3] * d.y + rz[3] * d.z
      spawn(d.prefab, vec3(px, py, pz), function(part)
        part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
        landed = landed + 1
        if landed == total then
          -- Back on its orbit: a spawned compound starts at rest in its body's
          -- frame, and the record's velocity (in that frame) is the handoff's
          -- `vel`, which the controller pushes once (see above). A push also
          -- wakes a craft the distant-craft LOD had taken, and the LOD then
          -- carries it on its rails at its real velocity (floptle/0402): no
          -- keep-alive hold, no top-up over frames.
          assembly.rebuild(v)
          log(string.format("fleet: %s is back where you left it (%s, %s)", rec.name,
            rec.body, rec.landed and "landed" or "in flight"))
        end
      end, v)
    end
  end)
  return true
end

local function fleet_restore()
  local gm = ref("game_manager")
  if gm and gm.loading then return end
  -- A launch is waiting to seat the crew: the FIRST vessel_controller to start
  -- takes that handoff, so nothing of ours may start before the new rocket.
  if (save.get("shipyard.pilot") or 0) == 1 or (save.get("shipyard.launch") or 0) == 1 then return end
  if not restore then
    restore = {}
    restore_t0 = time
    local alive = {}
    for _, fid in pairs(fleet_live) do alive[fid] = true end
    for fid, rec in pairs(fleet()) do
      if not alive[fid] and type(rec) == "table" and rec.parts then
        restore[fid] = { tries = 0 }
      end
    end
  end
  local f = fleet()
  for fid, st in pairs(restore) do
    local rec = f[fid]
    if not rec then
      restore[fid] = nil
    elseif respawn(fid, rec) then
      restore[fid] = nil
    else
      st.tries = st.tries + 1
      if st.tries > 3600 then
        restore[fid] = nil
        log("fleet: " .. tostring(rec.name) .. " could not be put back — its ground never loaded")
      end
    end
  end
end

-- One restore pass (update runs it every frame); global for tests and probes.
function fleetRestore() fleet_restore() end

-- Does this craft have a live link home? (the comms.ships heartbeat a powered,
-- deployed dish posts; vessel_controller's tracker_heartbeat)
local function linked(v)
  -- The comms network's answer (scripts/comms.lua): a powered antenna with a
  -- path home, relays included.
  local net = ref("comms")
  if net and net.statusOf and v and v.node then
    local s = net.statusOf(v.node.id)
    return s ~= nil and s.connected == true, s
  end
  local ships = save.get("comms.ships")
  if not (v and v.node and type(ships) == "table") then return false end
  local s = ships["v" .. tostring(v.node.id or 0)]
  -- (the registry outlives the scene; an entry from an earlier session can
  -- carry a node id that has since been reused)
  return type(s) == "table" and s.name == v.node.name
end

-- Fleet records with no live craft in the scene (not rebuilt yet, or waiting
-- for their ground): where they are in the world now, for the comms network.
function fleetOffline()
  local out = {}
  for fid, rec in pairs(fleet()) do
    if type(rec) == "table" and not live_of(fid) then
      local b = rec.body and space.body(rec.body)
      if b then
        out[#out + 1] = { fid = fid, name = rec.name, parts = rec.parts, charge = rec.charge,
                          wx = b.x + (rec.x or 0), wy = b.y + (rec.y or 0), wz = b.z + (rec.z or 0) }
      end
    end
  end
  return out
end

-- What the Tracking Station shows: every craft in the fleet, live or waiting
-- to be rebuilt. Sorted by name so rows don't jump between refreshes.
function fleetList()
  local out = {}
  local E = ref("electronics")
  for fid, rec in pairs(fleet()) do
    if type(rec) == "table" then
      local v = live_of(fid)
      local link, ls = linked(v)
      if not v then
        -- off the scene: the network solved it from its record
        local net = ref("comms")
        ls = net and net.statusOf and net.statusOf("f:" .. tostring(fid)) or nil
        link = ls ~= nil and ls.connected == true
      end
      local e = { fid = fid, name = rec.name or "Vessel", body = rec.body, pod = rec.pod,
                  comms = rec.comms, live = v ~= nil, piloted = v and v.piloting or false,
                  landed = rec.landed, link = link,
                  probe = rec.probe == true, crew = (v and v.crewAboard) or false,
                  nodeId = v and v.node and v.node.id or nil,
                  signal = ls and ls.strength or 0, hops = ls and ls.hops or 0,
                  path = ls and ls.names or nil }
      -- POWER: the batteries' charge as the records hold it (each battery's
      -- own, synced once a second), or the live bus for a craft in the scene.
      -- (a saved record holds each part's state as a string: decode it, never
      -- index it — `("…").charge` is nil, which once read as "full")
      local cap, charge, core_off = 0, 0, false
      if E then
        for _, d in ipairs(rec.parts or {}) do
          local st = (type(d.st) == "string" and E.decodeState(d.st)) or (type(d.st) == "table" and d.st) or {}
          local m = E.modOf(d, "battery")
          if m then
            cap = cap + (m.ec or 0)
            charge = charge + math.max(0, math.min(m.ec or 0, st.charge or (m.ec or 0)))
          end
          if E.modOf(d, "command") and st.hibernate then core_off = true end
        end
      end
      e.linkWhy = ls and ls.why or nil
      if v and v.controlState then
        -- a craft in the scene answers for itself, live
        local cs = v.controlState()
        e.control, e.why, e.crew = cs.can, cs.why, cs.crew
        if cs.cap then cap, charge = cs.cap, cs.charge or charge end
        e.linkWhy = cs.linkWhy or e.linkWhy
      elseif e.probe then
        -- a saved craft off the scene: the same rules, from its record
        if core_off then e.control, e.why = false, "PROBE CORE OFF — hibernating"
        elseif cap > 0 and charge <= 0 then e.control, e.why = false, "NO POWER — the batteries are flat"
        elseif not link then e.control, e.why = false, "NO SIGNAL — " .. (e.linkWhy or "no path home")
        else e.control = true end
      end
      e.cap, e.charge = cap, charge
      local b = rec.body and space.body(rec.body)
      if b then
        e.alt = len(rec.x, rec.y, rec.z) - b.radius
        if not rec.landed and space.elements then
          local o = space.elements(b.x + rec.x, b.y + rec.y, b.z + rec.z, rec.vx, rec.vy, rec.vz)
          if o then
            e.pe = o.periapsis and (o.periapsis - b.radius) or nil
            e.ap = o.apoapsis and (o.apoapsis - b.radius) or nil
            e.escaping = o.apoapsis == nil
          end
        end
      end
      if e.piloted then e.status = e.crew and "flying — you're aboard" or "flying — remote"
      elseif rec.splashed then e.status = "splashed"
      elseif rec.landed then e.status = "landed"
      elseif e.escaping then e.status = "escaping"
      elseif e.pe and e.pe > 0 then e.status = "in orbit"
      else e.status = "in flight" end
      e.dist = (function()
        local cx, cy, cz, hb = base_world()
        if not (cx and b and hb.name == b.name) then return nil end
        return len(b.x + rec.x - cx, b.y + rec.y - cy, b.z + rec.z - cz)
      end)()
      e.home = e.landed and e.dist ~= nil and e.dist <= params.home_range
      -- No shuttle for a crew already standing near the craft: they walk over.
      local afoot = (function()
        local astro = find and find("Astronaut")
        local pw = ref("planet_walker")
        if not (v and v.node and v.node.valid and astro and pw and pw.onFoot) then return false end
        return len(astro.x - v.node.x, astro.y - v.node.y, astro.z - v.node.z) <= params.pickup_range
      end)()
      e.fee = (e.link or not e.pod or e.crew or afoot) and 0
        or math.floor(math.min(params.abort_max, params.transfer_base
          + ((e.dist or 1e6) / 1000.0) * params.pickup_per_km))
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b) return a.name < b.name or (a.name == b.name and a.fid < b.fid) end)
  return out
end

local function entry(fid)
  for _, x in ipairs(fleetList()) do if x.fid == fid then return x end end
  return nil
end

-- SWITCHING. A craft nobody was flying has been coasting in the engine's
-- distant-craft LOD, which carries it on its rails and reports that state
-- (floptle/0402), so taking its controls needs nothing more than taking them:
-- the first push (throttle, SAS, RCS) wakes it at the velocity it has.

-- TAKE CONTROL from the Tracking Station.
--   a PROBE (no crew pod): flown from here, over its link — free; whether it
--     answers is its link and power (it can still be selected to look at)
--   a CREWED craft: the crew goes to it. Free over a live comms link (the dish
--     is the remote control); otherwise a shuttle flies them out, and that is
--     billed — and refused if the account can't cover it.
function takeControlOf(fid)
  local e = entry(fid)
  if not e then return false, "no such craft" end
  local v = live_of(fid)
  if not v then return false, "still being put back on " .. tostring(e.body) end
  if v.piloting then return false, "you're already flying it" end
  fleetSync()   -- the record is the truth we fall back on: make it current first
  if not e.pod or e.crew then
    if not (e.probe or e.crew) then return false, "no command part aboard — it can't be flown" end
    if not (v.remoteControl and v.remoteControl()) then return false, "it would not answer" end
    log(string.format("TAKE CONTROL — %s (%s)", e.name, e.crew and "crew aboard" or "remote, over the comms network"))
    return true, e.name
  end
  local co = ref("company")
  if e.fee > 0 then
    if co and co.afford and not co.afford(e.fee) then
      return false, "the shuttle out costs " .. co.money(e.fee) .. " — more than the balance"
    end
  end
  if not (v.takeControl and v.takeControl()) then return false, "it would not accept a pilot" end
  if e.fee > 0 then bill(e.fee, "crew transfer to " .. e.name) end
  log(string.format("TAKE CONTROL — %s%s", e.name,
    e.fee > 0 and (" (crew transfer " .. (co and co.money(e.fee) or e.fee) .. ")")
      or " (remote, over the comms link)"))
  return true, e.name
end

-- Switch to a LIVE craft by its controller (the in-flight [ ] switcher): the
-- crew stay where they are; a crewed craft whose crew is elsewhere is looked
-- at, not flown (its controls read NO CREW).
function switchToVessel(v)
  if not (v and v.node and v.node.valid and v.remoteControl) then return false end
  fleetSync()
  if not v.remoteControl() then return false end
  return true
end

-- Back to the crew: whatever you're flying is let go (it keeps coasting or
-- sitting where it is). If the crew is in a craft's seat, that craft is it.
function switchToCrew()
  fleetSync()
  local seat = nil
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.crewAboard and v.node and v.node.valid then seat = v end
  end
  if seat then
    if not seat.piloting and seat.remoteControl then seat.remoteControl() end
    return true, seat
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.releaseControl then v.releaseControl() end
  end
  local astro = find("Astronaut")
  if astro then astro.visible = true end
  return true, nil
end

-- RECOVER from the Tracking Station: a craft landed at home goes to the crane
-- (the same recovery as landing and holding ENTER). Anywhere else, no.
function recoverFleet(fid)
  local e = entry(fid)
  if not e then return false, "no such craft" end
  local v = live_of(fid)
  if not v then return false, "not back in the scene yet" end
  if not (v.recoverReady and v.recoverCraft) then return false, "it can't be recovered" end
  local ok, why = v.recoverReady()
  if not ok then return false, why end
  v.recoverCraft()
  local fx = ref("sfx"); if fx and fx.flightEnded then fx.flightEnded("recover") end
  return true
end

-- END FLIGHT from the Tracking Station: the craft is written off — gone from
-- the world and from the board, no refund (KSP's "terminate"). Never the one
-- the crew is sitting in.
function terminateFleet(fid)
  local e = entry(fid)
  if not e then return false, "no such craft" end
  if e.crew then return false, "the crew is aboard — bring them home first" end
  local v = live_of(fid)
  local f = fleet()
  f[fid] = nil
  save.set(FLEET_KEY, f)
  if v and v.node and v.node.valid then
    if v.piloting and v.releaseControl then v.releaseControl() end
    for id, x in pairs(fleet_live) do if x == fid then fleet_live[id] = nil end end
    destroy(v.node)
  end
  if restore then restore[fid] = nil end
  log("FLIGHT ENDED — " .. tostring(e.name) .. " written off")
  return true
end

-- RENAME: the craft's node and its record.
function renameFleet(fid, name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return false, "a craft needs a name" end
  if #name > 32 then name = name:sub(1, 32) end
  local f = fleet()
  if not f[fid] then return false, "no such craft" end
  f[fid].name = name
  save.set(FLEET_KEY, f)
  local v = live_of(fid)
  if v and v.renamed then v.renamed(name) end
  return true
end

-- The controller of a fleet craft that's in the scene (for the map's focus).
function liveOf(fid) return live_of(fid) end

-- Look at the saved fleet again and rebuild anything not in the scene (the
-- restore list is otherwise drawn up once per scene load). For a record
-- written from outside the flight: a probe, a future "rescue" contract.
function fleetRescan() restore = nil end

-- Global so a button (or the harness) can fire it as well as the key.
-- The way out that worked gets its sound (sfx.lua): only once it has.
local function sounded(how, ok, ...)
  if ok then local fx = ref("sfx"); if fx and fx.flightEnded then fx.flightEnded(how) end end
  return ok, ...
end

function endFlight()
  local st = survey()
  if not st or st.mode == "flying" or st.mode == "prelaunch" then return false end
  if st.mode == "recover" then return sounded("recover", do_recover(st)) end
  if st.mode == "pickup" then return sounded("pickup", do_pickup(st)) end
  return sounded("leave", do_leave(st))
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
  elseif st.v and st.v.crewAboard == false then
    row("label", "hud/label", "DOWN")
    row("task", "hud/task", "[ENTER]   END FLIGHT — leave the probe here")
    row("hint", "hud/hint",
      "It stays exactly where it is, on the Tracking Station's board, and you can fly it\n" ..
      "again from there while it has a link. The controls go back to the crew.", true)
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
  if (st.mode == "recover" or st.mode == "leave") and not (st.v and st.v.crewAboard == false) then
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

-- ── THE PAD NO LONGER RE-RATES ──────────────────────────────────────────────
--
-- This used to re-solve a blueprint's burn rate at the pad so the starter hopped
-- exactly to a target from wherever the pad stood — a hidden per-launch tweak
-- of the engines. The catalogue is now built ONCE per save for the home world
-- (builder.lua, BALANCE) and flies exactly as the builder quotes it, so all the
-- pad does is remember its true radius: the builder's predictions (TWR, apex)
-- are quoted for the ground the rocket actually stands on.
--
-- Returns nil: the blueprint is never changed. (vessel_spawner still calls it.)
function rerateAtPad(bp, bodyName, px, py, pz)
  local b = bodyName and space.body(bodyName)
  if not (b and (b.mu or 0) > 0) then return nil end
  local R = len(px - b.x, py - b.y, pz - b.z)
  if R < 1 then return nil end
  save.set("launch.pad", { body = b.name or bodyName, r = R })
  return nil
end

-- The base world, for the builder (see the header). Written only on change.
local world_said = nil
local function publish_world()
  local bf = ref("base_facilities")
  local name = (bf and bf.baseBody) or save.get("base.body")
  local b = type(name) == "string" and space.body(name) or nil
  if not (b and (b.radius or 0) > 0 and (b.mu or 0) > 0) then return end
  -- The radius is the PAD's, not the body's nominal one: `radius` is the
  -- terrain radius plus a margin for relief (about 3.5 %), and gravity at the
  -- ground the rocket actually stands on is 7 % stronger than at that sphere —
  -- the builder quoted TWR 1.34 for a rocket the pad read as 1.27.
  --
  -- And it is the GROUND's radius, found by a ray: the colony's published centre
  -- is not on the surface (on the review seeds it sat 3–5 m under the pad), and
  -- on a 130 m world that 4 % of radius is 8 % of gravity — the hop the
  -- builder promised at 330 m went to 1,400.
  local r = b.radius
  local cx, cy, cz, hb = base_world()
  if cx and hb.name == b.name then
    local ux, uy, uz = cx - b.x, cy - b.y, cz - b.z
    local d = len(ux, uy, uz)
    if d > b.radius * 0.5 and d < b.radius * 1.5 then
      r = d
      ux, uy, uz = ux / d, uy / d, uz / d
      local h = raycast(cx + ux * 60, cy + uy * 60, cz + uz * 60, -ux, -uy, -uz, 160.0)
      if h then
        local gr = len(h.x - b.x, h.y - b.y, h.z - b.z)
        -- A rocket starts from its centre of mass on the pad's deck, ~3.5 m
        -- above the ground (deck 2.5 m + the stack's CoM): on a 200 m world
        -- that is 3.5 % of gravity and a 15 % taller hop, so quote from there
        -- until the pad itself has been measured (below).
        if gr > b.radius * 0.5 and gr < b.radius * 1.5 then r = gr + 3.5 end
      end
    end
  end
  -- Best of all is the pad itself: a craft sitting in the clamps stands at
  -- exactly the radius every launch starts from. Remembered per body.
  local v = piloted()
  if v and v.hasFlown == false and v.tele and v.tele.anchored and v.node and v.node.valid then
    local pr = len(v.node.x - b.x, v.node.y - b.y, v.node.z - b.z)
    if pr > b.radius * 0.5 and pr < b.radius * 1.5 then
      save.set("launch.pad", { body = b.name or name, r = pr })
    end
  end
  local pad = save.get("launch.pad")
  if type(pad) == "table" and pad.body == (b.name or name) and (pad.r or 0) > 0 then r = pad.r end
  local g = b.mu / (r * r)
  local key = string.format("%s/%.3f/%.1f/%.1f", b.name or name, g, r, b.soi or -1)
  if key == world_said then return end
  world_said = key
  save.set("launch.world", { name = b.name or name, g = g, r = r,
                             soi = (b.soi or -1) > r and b.soi or nil })
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if time - fleet_t >= 1.0 then
    fleet_t = time
    publish_world()
    fleetSync()
  end
  fleet_restore()
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
