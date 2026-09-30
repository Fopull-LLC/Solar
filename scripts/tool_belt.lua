-- TOOL BELT — what the astronaut is holding, and what it does to the world.
--
--   1  MINING LASER    hold LMB: cuts rock and streams the material into
--                      your pack. See the whole section below.
--   2  HARVEST CUTTER  hold LMB: takes down the plant you're facing
--   3  TERRAIN SPADE   hold LMB to lower ground, Q to raise it — shaping
--                      only, it yields nothing (that's the laser's job now)
--
--   TAB / I  inventory   (the panel; it also handles ship/warehouse transfers)
--
-- ── AIMING: IT GOES WHERE YOU LOOK ─────────────────────────────────────────
--
-- One ray, cast through the MIDDLE OF THE VIEW. Where you are looking is what
-- gets cut, which is the only rule a player should ever have to hold in their
-- head, and the ring on the ground shows exactly where and how wide the cut
-- will be before you commit to it.
--
-- Three earlier versions got this wrong and all three are worth remembering:
--
--   * Casting through the FREE CURSOR. That is the honest reading of "it goes
--     where you point" and it is wrong, because the pointer is not where you
--     are pointing — you walk with WASD and only grab the mouse to turn, so
--     after any menu, any panel, any alt-tab the cursor is in a corner of the
--     screen: at the sky. Nothing hit, no ring, no beam, and a HUD still
--     cheerfully reporting your cargo. "I cannot use my tools for digging."
--
--   * Casting once from the CAMERA along its forward. The reach was then
--     measured from the camera, which on a third-person orbit sits up to 14 m
--     behind you — a 26 m ray left as little as 12 m in front of the player, and
--     silently less the further you scrolled out. The beam was DRAWN from there
--     too, so its first metres sat behind the near plane: on screen, nothing.
--   * "Fixing" it with the textbook two-stage cast — camera to an aim point,
--     then MUZZLE to that point, taking the second ray's hit. That is right for
--     a bullet, which has to respect the geometry it actually travels through,
--     and wrong for a beam you aim by eye. The two rays are parallel but offset
--     by the width of a shoulder, and on ground seen at a grazing angle — a
--     hillside, which is most of a planet — that offset slides the hit metres
--     along the slope and jitters it as you move. The beam went somewhere near
--     where you pointed, differently every frame.
--
-- So the aim is the ray through the centre of the view, full stop, and the
-- muzzle is only where the beam is drawn FROM. Range is measured from the
-- player, not the camera, so zooming changes nothing.
--
-- ── AND IT BORES: THE CUT POINT IS DRIVEN, NOT RE-DERIVED ───────────────────
--
-- A later version got the aim right and still barely dug, and still shook. Both
-- came from the same line: taking the raycast's hit as the cut point EVERY frame.
--
--   * `terrain.dig` subtracts an analytic ball — CSG, not accumulation, so that
--     a held brush can't dig to infinity and wreck the distance field. The
--     consequence for a mining laser is that the second dab at the same point
--     does NOTHING. Holding the trigger on one spot got you one ball-deep dish
--     and then silence: "its still actually barely even mining anything".
--   * The collider the raycast answers from is remeshed a few frames behind the
--     edit, so between dabs the hit flips between the old face and the new one.
--     The beam's end snapped back and forth by about a metre every frame — the
--     hole and the ray disagreeing about where the rock is.
--
-- So the cut point is ours now. It lives ON the aim ray, and while the trigger
-- is down it EATS FORWARD along it at `bore_speed`. Every dab lands somewhere
-- new, so the balls union into a tunnel you can walk into; and it moves at a
-- speed we picked, so nothing snaps. The raycast's job shrank to two things:
-- deciding where a fresh cut starts, and confirming there is still rock in front
-- of the beam.
--
-- The bore re-seats when you aim somewhere else (`regrip` metres off the ray) —
-- otherwise it would drag your tunnel sideways through the mountain. And it
-- stops advancing at `laser_reach` FROM THE PLAYER, which is not a limitation to
-- work around: it's why a tunnel is somewhere you walk into rather than a button
-- you hold down.
--
-- The tool itself is a real object bone-attached to `Hand.Right` (see the Laser
-- Tool node in the scene): the beam leaves its barrel, and it swings with the
-- walk cycle because the rig is carrying it.
--
-- ── THE FEEL ────────────────────────────────────────────────────────────────
--
-- Holding the trigger runs one state machine, and every part of it is on screen:
--
--   SPIN-UP   charge climbs to 1 over `spin`; the beam widens, the hum rises.
--   CUTTING   `yield` seconds of full-power beam = one unit of material. The
--             progress is the reticle's inner arc, so a unit never arrives as
--             a surprise. Cutting is CONTINUOUS — the terrain bite is still
--             spaced (it is the expensive part) but the feedback isn't.
--   FOCUS     hold the beam within `focus_radius` of where it already is and
--             the cut rate climbs to +60% over `focus_time`. Sweeping it around
--             resets that. Standing on a seam and working it is the skill.
--   HEAT      climbs while firing, bleeds off while not, and THROTTLES the cut
--             rate as it rises (down to ~55% at glowing hot). It never stops
--             you. A lockout was written and thrown away: the complaint this
--             rewrite exists to fix is "I can hardly mine anything", and a tool
--             that answers a held trigger with a cooldown bar is that complaint
--             with extra steps. Short bursts are simply faster than one long
--             one, which is all a heat mechanic ever needed to say.
--
-- WHAT YOU SEE BEFORE YOU CUT: the reticle names the material and the depth it
-- would come from, read through the SAME `survey()` the yield uses. What the
-- crosshair promises is what the beam delivers, because it is one function.
--
-- The spade and the cutter aim the same way; the laser just does the most with
-- it.

defaults = {
  --@header Mining laser
  --@range 4 60 --@units m
  laser_reach = 24.0,      -- from the PLAYER, so zoom never changes it
  -- CUT RADIUS, and it has to be read against the VOXEL. Planets generate at
  -- `PlanetFill::voxel` = 1.5 units, and `terrain.dig` subtracts a ball of
  -- radius × strength — so at the old 1.6 × 0.85 the whole bite was 1.36 units,
  -- SMALLER THAN ONE VOXEL. Surface nets cannot represent a hole that size: you
  -- get a lumpy pocket that only roughly agrees with where you pointed, which is
  -- the other half of "the digging location alignment is incredibly glitchy and
  -- kind of offset". At 2.4 × 0.85 the ball is 2.0 units — a bit over a voxel in
  -- radius, nearly three across — which the grid can actually round-trip.
  --@range 0.2 4 --@units m
  laser_radius = 2.4,
  --@range 0.05 1
  laser_strength = 0.85,   -- × radius = the ball each bite subtracts
  -- Seconds between terrain bites. EVERY bite remeshes the chunks it touches, so
  -- this is the tool's whole cost to the frame budget. At `bore_speed` it still
  -- steps only ~0.22 m between bites against a 2.0 m ball — an order of magnitude
  -- more overlap than a clean bore needs — so halving the rate from 0.06 halves
  -- the terrain churn while mining and changes nothing you can see.
  --@range 0.02 0.5 --@units s
  laser_rate = 0.12,
  --@range 0.2 6 --@units m/s
  bore_speed = 1.8,        -- how fast the cut eats forward into rock
  --@range 0.3 4 --@units m
  regrip = 1.6,            -- aim drift that re-seats the bore somewhere new
  --@range 0 2 --@units s
  spin = 0.35,             -- trigger → full power
  --@range 0.1 3 --@units s
  -- Seconds of full-power beam per unit of material. Paced against the SUIT: a
  -- pack has to be roughly one good tunnel's work, and at the old 0.18 s it was
  -- three seconds of trigger — you hit PACK FULL before the hole was deep enough
  -- to stand in, which is most of what "it barely mines anything" was.
  yield = 0.42,
  --@range 0.5 10 --@units s
  focus_time = 3.0,        -- how long on one spot for the full bonus
  --@range 0.2 6 --@units m
  focus_radius = 1.6,      -- how far the beam can wander and keep the bonus
  --@range 2 40 --@units s
  heat_time = 9.0,         -- seconds of unbroken fire to reach full heat
  --@range 0.5 12 --@units s
  cool_time = 4.0,         -- seconds from full heat back to cold, trigger up

  --@header Other tools
  --@range 0.2 4 --@units m
  spade_radius = 1.4,
  --@range 0.02 0.5 --@units s
  spade_rate = 0.14,
  --@range 0.05 1
  spade_strength = 0.6,
  --@range 1 12 --@units m
  cut_reach = 7.0,         -- from the PLAYER to the plant's base
  --@range 0.1 1.5 --@units rad
  cut_cone = 0.55,         -- the old "roughly ahead of me" floor
  --@range 0.3 4 --@units m
  cut_grab = 1.5,          -- how near the aim line has to pass the trunk
}

-- Published: the HUD, the reticle and the smoke harness read these.
tool = 1
prompt = ""
progress = 0.0
-- Laser state, published so anything can draw it without recomputing.
charge = 0.0     -- 0..1 spin-up
heat = 0.0       -- 0..1; throttles the cut rate, never stops it
focus = 0.0      -- 0..1 how long the beam has stayed on one spot
aimMat = nil     -- what the crosshair is over, if it's rock
aimDepth = 0.0
aimDist = nil    -- metres to the aim point (nil = nothing in reach)
bored = 0.0      -- metres the current bore has eaten into the rock
inUse = false    -- the trigger is held on a tool in hand (any of the three): the walker faces the aim
atReach = false  -- the bore has run out to arm's length: walk in to go deeper

TOOLS = {
  { id = "laser", label = "Mining Laser", hint = "hold LMB to cut rock" },
  { id = "cutter", label = "Harvest Cutter", hint = "hold LMB to harvest" },
  { id = "spade", label = "Terrain Spade", hint = "LMB lower · Q raise" },
}

-- Sounds. The hum is a LOOP started when the trigger goes down and stopped when
-- it comes up, with its pitch driven by charge — one voice, not a stutter of
-- one-shots.
local SFX = {
  hum    = "audio/kenney/sci-fi/forceField_004.ogg",
  ore    = "audio/kenney/impact/impactMining_00",   -- + 0..4
  denied = "audio/kenney/interface/error_003.ogg",
  swap   = "audio/kenney/interface/pluck_001.ogg",
}

local cam
local last_x, last_y, last_z, last_t = nil, nil, nil, -10
local cut_target, cut_work = nil, 0.0
local msg, msg_t = "", -10

-- Laser internals.
local cut_progress = 0.0     -- 0..1 toward the next unit
local hum = nil              -- the looping voice while firing
local last_hit = nil         -- where the beam landed last frame (focus test)
-- THE BORE. Held BODY-RELATIVE, because the planet it is cut into is orbiting a
-- star: a world-space point stops being the same piece of rock within a second.
local bore = nil             -- { body, x, y, z } — the live cut point
local denied_t = -10         -- rate-limits the "pack full" cue
local shake_pub = false      -- did WE last write cam.shake? (so we can clear it)
local muzzle_n, impact_n     -- the two effect nodes
local tool_n                 -- the model in the astronaut's hand

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

local function say(s)
  msg, msg_t = s, time
end

function toolId()
  return (TOOLS[tool] or TOOLS[1]).id
end

-- Are we the one driving? Only the on-foot astronaut carries tools, and never
-- while a facility panel, the ops board or the inventory panel owns the keys.
-- WHY are the tools off? One Console line, only when the answer CHANGES.
--
-- "I still wasn't able to use my tools after launching and landing and exiting
-- my pod" is a report with four possible causes and no way to tell them apart
-- from inside the game: the walker is parked, or one of three panels is holding
-- the keys — and two of those panels can be holding them while invisible. This
-- is the same trick `facility_menu.diag` plays, for the same reason: a silent
-- refusal is a bug report nobody can act on, including the person who wrote it.
--
-- And the Console is not on screen. `gate` is the same sentence, kept, so the
-- HUD can say it where the player is actually looking — because the HUD used to
-- HIDE ITSELF along with the belt, which meant a gated player saw no tools, no
-- belt, and no reason: the most confusing of the three possible screens.
local last_why = ""
gate = "starting up"
-- The one reason that means "say nothing": there is a flight HUD in front of
-- them and a tool belt would be noise.
local GATE_ABOARD = "the crew is aboard a craft, or the world is still loading"

local function why(reason)
  gate = reason
  if reason ~= last_why then
    last_why = reason
    log("tools: " .. reason)
  end
end

local function on_foot(node)
  -- NOT `node.visible`. planet_camera hides the astronaut whenever the camera
  -- ends up within 0.7 m of them — first person, yes, but also every time the
  -- wall-clip ray finds a wall behind you. So the laser switched itself off
  -- inside any building, in any tunnel you had just dug, and beside your own
  -- rocket: all the places you most want a tool. planet_walker publishes the
  -- question this was always trying to ask.
  local pw = ref("planet_walker")
  if not pw then why("no planet_walker in the scene — the belt can't tell who's driving") return false end
  if pw.onFoot ~= true then
    why(GATE_ABOARD)
    return false
  end
  local pm = ref("pause_menu")
  if pm and pm.open then why("the game is paused") return false end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then why("a facility panel has the keys") return false end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then why("the ops board has the keys") return false end
  -- The suit pack too, now that the trigger is LMB: clicking a row to move a
  -- stack must not also fire a mining laser through the floor.
  local ip = ref("inventory_panel")
  if ip and ip.open then why("the suit pack has the keys") return false end
  why("in hand")
  return true
end

-- The world position of the surface directly above a point, and therefore how
-- far under the crust that point is.
local function depth_at(body, x, y, z)
  local dx, dy, dz = x - body.x, y - body.y, z - body.z
  local r = math.sqrt(dx * dx + dy * dy + dz * dz)
  if r < 1e-3 then return 0 end
  local ux, uy, uz = dx / r, dy / r, dz / r
  local top = 120.0
  local hit = raycast(x + ux * top, y + uy * top, z + uz * top, -ux, -uy, -uz, top + 4.0)
  if not hit then return 0 end
  local hr = math.sqrt((hit.x - body.x) ^ 2 + (hit.y - body.y) ^ 2 + (hit.z - body.z) ^ 2)
  return math.max(0, hr - r)
end

-- WHAT IS THIS ROCK? The one function that decides, asked by the reticle to
-- preview a shot and by the beam to resolve one. Two callers, one answer — a
-- crosshair that promised something the cut didn't deliver would be worse than
-- no crosshair at all.
--
-- The roll comes from a smooth noise field seeded per world, so a seam is a
-- PLACE you can follow rather than a slot machine you can stand still and pull.
-- Wrapped rather than clamped: a sum of noise octaves piles up in the middle of
-- its range, and a middle-heavy roll makes the FIRST and LAST bands of a yield
-- table (the filler and the rare seam) nearly unreachable. The fractional part
-- keeps veins contiguous while covering the table evenly.
function survey(x, y, z)
  local mats = ref("materials")
  local cl = ref("climate")
  local body = space.body(space.dominant(x, y, z) or "")
  if not (body and mats) then return nil, 0 end
  local w = cl and cl.worldOf(body.name)
  local depth = depth_at(body, x, y, z)
  local seed = (w and w.seed or 1) % 4096
  local n1 = math.noise(x * 0.035, y * 0.035, z * 0.035, seed)
  local n2 = math.noise(x * 0.19, y * 0.19, z * 0.19, seed + 3)
  local mix = (n1 * 0.62 + n2 * 0.38) * 2.5 + 0.5
  local roll = mix - math.floor(mix)
  -- The rich-pocket bonus rides the same fine octave the vein does, so a
  -- pocket is somewhere you can stand rather than a per-bite coin flip.
  return mats.pickOre(w and w.kind or "barren", depth, roll), depth, (n2 > 0.45)
end

-- ── aiming ──────────────────────────────────────────────────────────────────

-- The two effect nodes, looked up once.
local function nodes()
  if not muzzle_n then muzzle_n = find("Laser Muzzle") end
  if not impact_n then impact_n = find("Laser Impact") end
end

-- THE PIXEL THE TOOL SHOOTS THROUGH: the middle of the view. Always.
--
-- It used to be the OS cursor whenever the mouse was free — and the mouse is
-- free almost all the time, because you walk with WASD and only grab it to
-- turn. So the belt fired through wherever the pointer had last been left,
-- which after any menu, any panel, any alt-tab is a corner of the screen: at
-- the sky. `ray_hit` found nothing, `fire_laser` set no target, `draw_ring`
-- drew no ring, and the HUD went on saying what was in your pack. Every part of
-- the tool worked and the tool did nothing, with no crosshair anywhere on
-- screen to show you where it thought you were pointing. "I cannot use my tools
-- for digging."
--
-- A game with a beam weapon aims down the middle of the view. The panels take
-- the belt's keys away while they are up (see `on_foot`), so there is no case
-- where the cursor is the aim and the tool is live at the same time.
local function aim_pixel()
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return nil end   -- no live view: caller falls back
  return vx + vw * 0.5, vy + vh * 0.5
end

-- THE AIM RAY — origin and unit direction through the pixel the player is
-- pointing at. Everything downstream (the preview, the bore, the beam, the ring)
-- is a point on this one ray, which is the whole reason the tool lands where you
-- clicked.
local function aim_ray(node)
  local sx, sy = nil, nil
  if camera and camera.screenToRay and camera.screenRect then sx, sy = aim_pixel() end
  if sx then
    local ox, oy, oz, dx, dy, dz = camera.screenToRay(sx, sy)
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l > 1e-6 then return ox, oy, oz, dx / l, dy / l, dz / l end
  end
  -- No live view (headless, a paused editor, the smoke harness): aim down the
  -- published camera basis instead. Same ray, coarser source.
  if not (cam and cam.cam_x and cam.fwd_x) then return nil end
  return cam.cam_x, cam.cam_y, cam.cam_z, cam.fwd_x, cam.fwd_y, cam.fwd_z
end

-- The first solid along that ray. Range is measured from the PLAYER: the ray
-- starts at the near plane (that is what a screen pixel means), so the cast has
-- to run past the reach by however far back the camera has been scrolled, and
-- anything landing beyond the reach FROM THE ASTRONAUT is out of range.
--
-- `slack` lets a bore that has eaten out to arm's length keep seeing the face it
-- is cutting: without it the beam flickers off at exactly the moment the tunnel
-- gets interesting.
local function ray_hit(node, ox, oy, oz, dx, dy, dz, slack)
  local reach = params.laser_reach + (slack or 0)
  local back = math.sqrt((node.x - ox) ^ 2 + (node.y - oy) ^ 2 + (node.z - oz) ^ 2)
  local h = raycast(ox, oy, oz, dx, dy, dz, back + reach, node)
  if not h then return nil end
  local d = math.sqrt((h.x - node.x) ^ 2 + (h.y - node.y) ^ 2 + (h.z - node.z) ^ 2)
  if d > reach then return nil end
  h.range = d
  return h
end

-- What the cursor is over right now. The spade and the cutter aim with this; the
-- laser uses it to START a bore and then drives its own point forward.
local function laser_shot(node)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then return nil end
  return ray_hit(node, ox, oy, oz, dx, dy, dz, 0)
end

-- ── the bore ────────────────────────────────────────────────────────────────

local function bore_world()
  if not bore then return nil end
  local b = bore.body and space.body(bore.body)
  if not b then return bore.x, bore.y, bore.z end
  return b.x + bore.x, b.y + bore.y, b.z + bore.z
end

local function bore_hold(x, y, z)
  local b = space.body(space.dominant(x, y, z) or "")
  if b then
    bore = { body = b.name, x = x - b.x, y = y - b.y, z = z - b.z }
  else
    bore = { body = nil, x = x, y = y, z = z }
  end
  return bore
end

local function bore_drop()
  bore, bored, atReach = nil, 0.0, false
end

-- Advance (or seat) the cut point for this frame, and return it in world space.
-- `entry` is the raycast's first solid — needed to start a cut, and needed every
-- frame after it as proof there is still rock in front of the beam (aim at the
-- sky, or break through the far side of a ridge, and the beam goes out).
local function bore_step(node, dt, ox, oy, oz, dx, dy, dz, entry)
  if not entry then
    bore_drop()
    return nil
  end
  local t, t0 = nil, nil
  local wx, wy, wz = bore_world()
  if wx then
    -- Where the live bore sits along THIS frame's ray. Aiming somewhere else
    -- pushes it off the ray, and past `regrip` we start a new cut there rather
    -- than dragging the old hole sideways through the mountain.
    t = (wx - ox) * dx + (wy - oy) * dy + (wz - oz) * dz
    local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
    local perp = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2 + (wz - pz) ^ 2)
    if t <= 0 or perp > params.regrip then bore, t = nil, nil end
  end
  if t then
    -- Eat forward. Charge gates it so the first instant of a trigger pull seats
    -- the beam instead of lurching it a metre into the rock.
    t0 = t
    t = t + params.bore_speed * dt * charge
  else
    t = math.sqrt((entry.x - ox) ^ 2 + (entry.y - oy) ^ 2 + (entry.z - oz) ^ 2)
  end

  -- Arm's length, measured from the PLAYER. The point is walked back onto the
  -- reach sphere rather than frozen, so the beam stays lit and steady while you
  -- stand at the face and decide to step in.
  local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
  local far = math.sqrt((px - node.x) ^ 2 + (py - node.y) ^ 2 + (pz - node.z) ^ 2)
  atReach = far > params.laser_reach
  if atReach then
    t = math.max(0.0, t - (far - params.laser_reach))
    px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
  end

  bore_hold(px, py, pz)
  -- HOW DEEP THE HOLE IS, accumulated a frame at a time rather than measured
  -- back to where the cut started. The obvious version keeps the entry point and
  -- subtracts — and the entry point is on a planet that is ORBITING A STAR, so
  -- after ten seconds of holding the trigger it is several kilometres behind the
  -- hole and the readout is nonsense. Distance travelled needs no memory of
  -- where it began, which is the only kind of measurement this scale is safe for.
  bored = t0 and (bored + math.max(0.0, t - t0)) or 0.0
  return px, py, pz
end

-- ── the beam's presentation ─────────────────────────────────────────────────

-- Show or hide the beam, and aim it. `hit` nil = the beam is off.
--
-- NOTHING HERE MOVES THE MUZZLE, and that is load-bearing. It used to, from when
-- it was a free-floating world node: `muzzle_n.x = mx` with mx in WORLD metres.
-- The muzzle is now the barrel tip of a rifle bone-attached to the hand, so its
-- `.x/.y/.z` are PARENT-LOCAL — and writing a world coordinate into a local one
-- put the beam's origin at roughly TWICE the astronaut's world position. On a
-- planet five thousand units from its star that is a point kilometres away in
-- the sky, which is why the beam appeared to come from nowhere, why it swung
-- with the planet's orbit, and why tiny movements threw it around: the emitter
-- was a lever arm the length of the solar system.
--
-- THE RULE, for everything in this project: a node the script positions in world
-- coordinates must be TOP-LEVEL. A parented node is positioned by its parent, or
-- in its parent's frame — never both. `Laser Impact` below is top-level and so
-- IS placed here; the muzzle is parented and so is not.
local function apply_beam(hit, power)
  nodes()
  if muzzle_n then
    local ps = muzzle_n:particles()
    if hit then
      if not ps:isPlaying() then ps:play() end
      ps:setIntensity(0.45 + power * 0.75)
      ps:setBeamEnd(hit.x, hit.y, hit.z)
    elseif ps:isPlaying() then
      ps:stop()
    end
  end
  if impact_n then
    local ps = impact_n:particles()
    local light = impact_n:getcomponent("PointLight")
    if hit then
      impact_n.x, impact_n.y, impact_n.z = hit.x, hit.y, hit.z
      if not ps:isPlaying() then ps:play() end
      ps:setIntensity(0.3 + power)
      -- The ground actually lights up. This is most of why the cut reads as
      -- hot rather than as a decal.
      if light then light.intensity = 2.0 + power * 7.0 end
    else
      if ps:isPlaying() then ps:stop() end
      if light then light.intensity = 0.0 end
    end
  end
end

-- Put the tool in the hand, or take it away. The mesh is bone-attached to the
-- rig, so "holstered" is just hidden — visibility does not propagate to
-- children in this engine, so the muzzle's effect is stopped separately (it
-- already is, by `show_beam`).
local function holster(away)
  if not tool_n then tool_n = find("Laser Tool") end
  if tool_n and tool_n.valid then tool_n.visible = not away end
end

-- cam.shake is shared with the vessel (planet_camera reads one key), so we only
-- ever write while WE are shaking and clear it once when we stop — the same
-- contract vessel_controller keeps.
local function publish_shake(v)
  if v > 0.002 then
    save.set("cam.shake", math.min(1.0, v))
    shake_pub = true
  elseif shake_pub then
    save.set("cam.shake", 0.0)
    shake_pub = false
  end
end

local function hum_off()
  if hum then
    hum:stop()
    hum = nil
  end
end

-- ── the aiming ring ─────────────────────────────────────────────────────────

-- The crosshair is drawn IN THE WORLD, on the ground, at the point the cursor
-- is over — not as a mark in the middle of the screen. Three reasons, and the
-- first one is the whole point:
--
--   * with a free cursor the middle of the screen is not where you are aiming,
--     so a centre crosshair is a lie;
--   * a ring at the hit shows the CUT RADIUS, so you can see how much rock the
--     next bite takes and whether the vein you want is inside it;
--   * it sits on the surface and shrinks with distance for free, which is a
--     depth cue no screen-space mark can give you.
--
-- Immediate mode: the segments are queued every frame and the engine replaces
-- the list, so releasing the trigger or holstering the tool clears it by simply
-- not drawing.
local RING = {
  idle = { 0.55, 0.70, 0.78 },
  ok   = { 0.30, 0.88, 0.76 },
  hot  = { 1.00, 0.78, 0.35 },
  full = { 1.00, 0.45, 0.30 },
}

local tick_x, tick_y, tick_z = 1, 0, 0 -- the ring's tick direction, kept frame to frame
local function paint_ring(hit, firing, full)
  if not hit then return end
  local c = RING.idle
  if full then c = RING.full
  elseif firing then c = RING.hot
  elseif aimMat then c = RING.ok end

  -- The surface normal the raycast came back with; fall back to the local up so
  -- a hit on something without one still lies flat.
  local nx, ny, nz = hit.nx, hit.ny, hit.nz
  if not nx then nx, ny, nz = 0, 1, 0 end
  local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
  if nl < 1e-4 then nx, ny, nz, nl = 0, 1, 0, 1 end
  nx, ny, nz = nx / nl, ny / nl, nz / nl
  -- Lifted a few centimetres off the surface so it doesn't z-fight the ground.
  local cx, cy, cz = hit.x + nx * 0.08, hit.y + ny * 0.08, hit.z + nz * 0.08
  -- The ring is the ball the bite ACTUALLY subtracts — radius × strength — not
  -- the radius param. A sight that draws 15% wider than the hole it makes is a
  -- sight that lies, and the whole point of this crosshair is that it can't.
  local r = params.laser_radius * params.laser_strength

  draw.ring(cx, cy, cz, nx, ny, nz, r, c[1], c[2], c[3], 0.9)
  -- The inner ring is the cut counting out the next unit: it grows from the
  -- middle to the rim, so a unit never arrives as a surprise.
  if firing and cut_progress > 0.02 then
    draw.ring(cx, cy, cz, nx, ny, nz, r * cut_progress,
      RING.hot[1], RING.hot[2], RING.hot[3], 0.85)
  end
  -- Four ticks around it, in the surface plane, so the ring reads as a sight
  -- rather than as a puddle. The tick direction is carried over from last
  -- frame (projected onto the new plane) rather than rebuilt from a world
  -- axis, so the ticks don't spin as the normal wanders over the ground.
  local sx, sy, sz = tick_x, tick_y, tick_z
  local sd = sx * nx + sy * ny + sz * nz
  sx, sy, sz = sx - nx * sd, sy - ny * sd, sz - nz * sd
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl < 0.2 then
    sx, sy, sz = 1 - nx * nx, -nx * ny, -nx * nz
    sl = math.sqrt(sx * sx + sy * sy + sz * sz)
    if sl < 1e-3 then sx, sy, sz, sl = 0, 0, 1, 1 end
  end
  sx, sy, sz = sx / sl, sy / sl, sz / sl
  tick_x, tick_y, tick_z = sx, sy, sz
  local tx = ny * sz - nz * sy
  local ty = nz * sx - nx * sz
  local tz = nx * sy - ny * sx
  local inner, outer = r * 1.12, r * 1.55
  for _, d in ipairs({ { sx, sy, sz }, { -sx, -sy, -sz }, { tx, ty, tz }, { -tx, -ty, -tz } }) do
    draw.line(cx + d[1] * inner, cy + d[2] * inner, cz + d[3] * inner,
              cx + d[1] * outer, cy + d[2] * outer, cz + d[3] * outer,
              c[1], c[2], c[3], 0.9)
  end
end

-- ── drawn after the rails ───────────────────────────────────────────────────
--
-- The planet you stand on moves along its orbit INSIDE the frame, after
-- `update` and before the picture: the rails step it by a metre or two per
-- physics tick, and a frame runs zero, one or two ticks. A sight worked out
-- and drawn in `update` was drawn where the ground WAS, off by a different
-- amount every frame — the ring and the beam's end jittered across the
-- ground. So `update` only decides what to show and records it in the
-- planet's own frame; `lateUpdate`, after the rails, turns it back into world
-- space and draws it. Planets only translate, so the planet-frame offset is
-- exact.
local beam_req, ring_req, plant_req = nil, nil, nil
local paint_plant                       -- the cutter's marker, defined with the cutter
local ring_s = nil                      -- the smoothed sight, planet frame

local function to_body(hit)
  local t = {}
  for k, v in pairs(hit) do t[k] = v end
  local name = space.dominant(hit.x, hit.y, hit.z)
  local b = name and space.body(name)
  if b then t.body, t.x, t.y, t.z = name, hit.x - b.x, hit.y - b.y, hit.z - b.z end
  return t
end

local function to_world(t)
  local w = {}
  for k, v in pairs(t) do w[k] = v end
  local b = t.body and space.body(t.body)
  if b then w.x, w.y, w.z = b.x + t.x, b.y + t.y, b.z + t.z end
  return w
end

-- `hit` == nil turns the beam off; not calling this this frame leaves it be.
local function show_beam(hit, power)
  beam_req = hit and { h = to_body(hit), p = power } or false
end

local function draw_ring(hit, firing, full)
  ring_req = hit and { h = to_body(hit), firing = firing, full = full } or nil
end

local function draw_plant(hit, ready)
  plant_req = hit and { h = to_body(hit), ready = ready } or nil
end

-- The ground's own normal at a point: the terrain field's gradient, which is
-- smooth, where the collider's triangle normal steps from facet to facet.
local function field_normal(x, y, z)
  if not (terrain and terrain.query) then return nil end
  local q = terrain.query(x, y, z)
  if not q or math.abs(q) > 1.0 then return nil end
  local e = 0.4
  local gx = (terrain.query(x + e, y, z) or q) - (terrain.query(x - e, y, z) or q)
  local gy = (terrain.query(x, y + e, z) or q) - (terrain.query(x, y - e, z) or q)
  local gz = (terrain.query(x, y, z + e) or q) - (terrain.query(x, y, z - e) or q)
  local l = math.sqrt(gx * gx + gy * gy + gz * gz)
  if l < 1e-6 then return nil end
  return gx / l, gy / l, gz / l
end

function lateUpdate(node, dt)
  if beam_req ~= nil then
    if beam_req then apply_beam(to_world(beam_req.h), beam_req.p) else apply_beam(nil, 0) end
    beam_req = nil
  end

  if ring_req then
    local h = ring_req.h
    local w = to_world(h)
    local nx, ny, nz = field_normal(w.x, w.y, w.z)
    if nx then h.nx, h.ny, h.nz = nx, ny, nz end
    -- Follow the aim quickly but not instantly: a hand on a mouse is never
    -- perfectly still and the sight shouldn't buzz with it. A real re-aim (a
    -- jump of more than a stride) snaps, so moving the sight stays crisp.
    local s = ring_s
    local d2 = s and s.body == h.body and ((h.x - s.x) ^ 2 + (h.y - s.y) ^ 2 + (h.z - s.z) ^ 2)
    if d2 and d2 < 1.6 * 1.6 then
      local k = 1 - math.exp(-25 * dt)
      local kn = 1 - math.exp(-12 * dt)
      s.x, s.y, s.z = s.x + (h.x - s.x) * k, s.y + (h.y - s.y) * k, s.z + (h.z - s.z) * k
      local ax, ay, az = s.nx or 0, s.ny or 1, s.nz or 0
      local bx, by, bz = h.nx or ax, h.ny or ay, h.nz or az
      ax, ay, az = ax + (bx - ax) * kn, ay + (by - ay) * kn, az + (bz - az) * kn
      local l = math.sqrt(ax * ax + ay * ay + az * az)
      if l > 1e-6 then s.nx, s.ny, s.nz = ax / l, ay / l, az / l end
    else
      ring_s = { body = h.body, x = h.x, y = h.y, z = h.z, nx = h.nx, ny = h.ny, nz = h.nz }
    end
    paint_ring(to_world(ring_s), ring_req.firing, ring_req.full)
  else
    ring_s = nil
  end
  ring_req = nil -- immediate mode, like draw.*: update asks again every frame

  if plant_req then paint_plant(to_world(plant_req.h), plant_req.ready) end
  plant_req = nil
end

-- ── the laser ───────────────────────────────────────────────────────────────

local function pop_unit(node, hit)
  local inv, mats = ref("inventory"), ref("materials")
  if not (inv and mats) then return end

  -- SURFACE ROCK FIRST. A boulder standing where the beam is cutting is the
  -- thing the player is pointing at, and it pays better than the dirt behind
  -- it. Scattered props have no colliders, so the raycast that found `hit`
  -- went straight through this rock — `scatter.near` is how you aim at one
  -- (mineral_field wraps it).
  local mf = ref("mineral_field")
  if mf and mf.nearest then
    local rock = mf.nearest(hit.x, hit.y, hit.z)
    if rock then
      local rmat, rtook = mf.breakAt(rock, "astro")
      if rtook and rtook > 0 then
        spawnEffect("OreBreak", hit.x, hit.y, hit.z)
        audio.play(SFX.ore .. tostring(math.floor(math.random() * 5)) .. ".ogg",
          hit.x, hit.y, hit.z,
          { track = "SFX", volume = 0.7, pitch = 0.75 + math.random() * 0.25,
            mode = "spatial", falloff = "inverse" })
        say(string.format("%s ×%d", mats.label(rmat), rtook))
        return
      elseif rmat then
        -- The rock is still standing, because a break that pays nothing must
        -- not also destroy it. Fall through to the terrain, which will say
        -- "pack full" in the usual way.
      end
    end
  end

  local mat, _, rich = survey(hit.x, hit.y, hit.z)
  if not mat then return end
  local units = rich and 2 or 1
  local took = inv.add("astro", mat, units)
  if took <= 0 then
    if time - denied_t > 2.5 then
      denied_t = time
      audio.play(SFX.denied, { track = "UI", volume = 0.5 })
      say("pack full — " .. inv.line("astro"))
    end
    return
  end
  spawnEffect("OreBreak", hit.x, hit.y, hit.z)
  audio.play(SFX.ore .. tostring(math.floor(math.random() * 5)) .. ".ogg",
    hit.x, hit.y, hit.z,
    { track = "SFX", volume = 0.55, pitch = 0.9 + math.random() * 0.3,
      mode = "spatial", falloff = "inverse" })
  say(string.format("%s ×%d", mats.label(mat), took))
end

local function fire_laser(node, dt, firing)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then
    bore_drop()
    show_beam(nil, 0)
    hum_off()
    aimDist, aimMat, aimDepth = nil, nil, 0
    return nil
  end
  -- A little slack past the reach so a bore that has eaten out to arm's length
  -- can still SEE the face it's cutting (see `ray_hit`).
  local entry = ray_hit(node, ox, oy, oz, dx, dy, dz, firing and 3.0 or 0.0)
  if entry and entry.range > params.laser_reach and not bore then entry = nil end

  -- The cut point: the bore while you're firing, the surface under the cursor
  -- while you aren't. Wrapped as a hit-shaped table so the beam, the ring and
  -- the survey all take the same thing.
  local hit = entry
  if firing then
    charge = math.min(1.0, charge + dt / math.max(0.01, params.spin))
    local bx, by, bz = bore_step(node, dt, ox, oy, oz, dx, dy, dz, entry)
    if bx then
      -- Inside the rock there is no surface to lie flat on, so the ring faces
      -- back down the beam — which is also the only orientation that reads as
      -- a target rather than a puddle once you're in a tunnel.
      hit = { x = bx, y = by, z = bz, nx = -dx, ny = -dy, nz = -dz,
              range = math.sqrt((bx - node.x) ^ 2 + (by - node.y) ^ 2 + (bz - node.z) ^ 2) }
      if bored < 0.35 and entry then hit.nx, hit.ny, hit.nz = entry.nx, entry.ny, entry.nz end
    else
      hit = nil
    end
  else
    bore_drop()
  end

  -- The crosshair reads the world whether or not the trigger is down: knowing
  -- what is under it BEFORE committing is what makes prospecting a thing you
  -- do rather than a thing that happens to you.
  if hit then
    -- From the PLAYER, not from the ray's origin: the ray starts at the camera,
    -- and "14 m" has to mean fourteen metres from where you are standing.
    aimDist = hit.range
      or math.sqrt((hit.x - node.x) ^ 2 + (hit.y - node.y) ^ 2 + (hit.z - node.z) ^ 2)
    aimMat, aimDepth = survey(hit.x, hit.y, hit.z)
  else
    aimDist, aimMat, aimDepth = nil, nil, 0
  end

  if firing and hit then
    heat = math.min(1.0, heat + dt / math.max(0.5, params.heat_time))
    -- Hot optics cut slower. This is the whole heat mechanic: a bar that costs
    -- you time, not a bar that takes the tool away.
    local throttle = 1.0 - 0.45 * heat
    -- Focus: reward for keeping the beam where it already is.
    if last_hit then
      local d = math.sqrt((hit.x - last_hit[1]) ^ 2 + (hit.y - last_hit[2]) ^ 2
                        + (hit.z - last_hit[3]) ^ 2)
      if d <= params.focus_radius then
        focus = math.min(1.0, focus + dt / math.max(0.1, params.focus_time))
      else
        focus = 0.0
      end
    end
    last_hit = { hit.x, hit.y, hit.z }

    -- Cutting is continuous; the terrain BITE is spaced because it's the
    -- expensive half. The player feels the first, the frame budget feels the
    -- second, and neither has to know about the other.
    cut_progress = cut_progress
      + dt * charge * throttle * (1.0 + 0.6 * focus) / math.max(0.05, params.yield)
    while cut_progress >= 1.0 do
      cut_progress = cut_progress - 1.0
      pop_unit(node, hit)
    end
    -- The bite. `terrain.dig` subtracts a ball of radius × strength at this
    -- point — so what carves a tunnel is not this call, it's that the point
    -- MOVED since the last one. Spaced by `laser_rate` because remeshing is the
    -- expensive half; at `bore_speed` that leaves consecutive balls about a
    -- tenth of a metre apart, which unions into a clean bore with no ridges.
    if time - last_t >= params.laser_rate then
      last_t = time
      terrain.dig(hit.x, hit.y, hit.z, params.laser_radius,
        params.laser_strength * (0.55 + 0.45 * charge))
    end

    -- Presentation.
    show_beam(hit, charge)
    publish_shake(0.05 + charge * 0.09)
    if not hum then
      hum = audio.play(SFX.hum, { track = "SFX", loop = true, volume = 0.0 })
    end
    if hum then
      hum:setVolume(0.10 + charge * 0.30)
      hum:setPitch(0.72 + charge * 0.36 + focus * 0.10)
    end
  else
    -- Released (or nothing in reach): the beam drops fast, the barrel cools.
    charge = math.max(0.0, charge - dt * 4.0)
    heat = math.max(0.0, heat - dt / math.max(0.5, params.cool_time))
    if not firing then focus = math.max(0.0, focus - dt * 0.8) end
    cut_progress = math.max(0.0, cut_progress - dt * 0.25)
    last_hit = nil
    show_beam(nil, 0)
    publish_shake(0)
    hum_off()
  end

  -- The one-line readout under the tool name. It carries the whole state of the
  -- shot, because the ring on the ground carries the aim and nothing else has
  -- to: what you're about to get, how deep it is, how close the next unit is,
  -- and — loudly — when the pack has no room for it, which is the one condition
  -- that makes a working laser look broken.
  local inv = ref("inventory")
  local mats = ref("materials")
  local full = (inv and aimMat and inv.roomFor("astro", aimMat, 1) < 1) or false
  local pack = (inv and inv.line("astro")) or ""
  if not hit then
    -- "no target" alone is a diagnosis with no instruction attached. Say the
    -- number: pointed at the sky, over a cliff edge, or at a ridge across the
    -- valley all land here, and all of them look exactly like a broken tool.
    prompt = string.format("no target  ·  nothing within %.0f m of the crosshair  ·  %s",
      params.laser_reach, pack)
  else
    -- What the beam is doing, in the order a player needs it. `atReach` outranks
    -- the material readout because it is the one state that otherwise reads as
    -- "the tool stopped working" — the bore is as far in as an arm reaches, and
    -- the answer is to walk into the hole you just made.
    local head = ""
    if atReach then
      head = string.format("%.1f m in  ·  AT ARM'S LENGTH — step into the tunnel to cut deeper",
        bored)
    elseif aimMat then
      local bar = string.rep("▮", math.floor(cut_progress * 6 + 0.5))
        .. string.rep("▯", 6 - math.floor(cut_progress * 6 + 0.5))
      local where = aimDepth >= 1.0 and string.format("%.0f m down", aimDepth)
        or string.format("%.0f m out", aimDist or 0)
      head = string.format("%s  ·  %s  ·  %s%s%s",
        mats and mats.label(aimMat) or aimMat, where, bar,
        bored > 0.5 and string.format("  bore %.1f m", bored) or "",
        focus > 0.05 and string.format("  focus +%d%%", math.floor(focus * 60 + 0.5)) or "")
    end
    -- A full pack shouts, but it never HIDES the rest: the two things a stuck
    -- player needs to know — "you have no room" and "you have run out of arm" —
    -- can both be true at once, and showing only the first is how a working
    -- laser gets reported as broken twice in a row.
    if full then
      prompt = "PACK FULL — " .. pack .. "  ·  sell at the depot"
        .. (head ~= "" and ("  ·  " .. head) or "")
    elseif head ~= "" then
      prompt = head .. "  ·  " .. pack
    else
      prompt = pack
    end
  end
  progress = cut_progress
  return hit
end

-- ── the cutter ──────────────────────────────────────────────────────────────

-- Highlight the plant under the cursor: a ring round its base and a stem up its
-- axis, filling as the cut goes in. Without this the cutter was a tool with NO
-- crosshair at all — the laser's ground ring is meaningless for something you
-- aim at a tree, and "nothing in reach" was the only feedback there had ever
-- been about what you were pointed at.
paint_plant = function(hit, ready)
  local c = ready and RING.ok or RING.idle
  local ux, uy, uz = hit.ux or 0, hit.uy or 1, hit.uz or 0
  draw.ring(hit.x + ux * 0.1, hit.y + uy * 0.1, hit.z + uz * 0.1,
    ux, uy, uz, 0.75, c[1], c[2], c[3], 0.9)
  local h = (hit.height or 1.5) * math.max(0.08, progress)
  draw.line(hit.x, hit.y, hit.z, hit.x + ux * h, hit.y + uy * h, hit.z + uz * h,
    RING.hot[1], RING.hot[2], RING.hot[3], 0.95)
end

local function fire_cutter(node, dt, firing)
  local ff = ref("flora_field")
  if not ff then
    prompt = "no flora here"
    return
  end
  -- The cutter aims down the SAME cursor ray the laser bores along — and it
  -- hands that ray to `nearestPlant` whole, rather than collapsing it into a
  -- direction from the player's navel, so the test is "does the line go through
  -- the tree" and not "is the tree's root roughly ahead of me".
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then return end
  local hit = ff.nearestPlant(ox, oy, oz, dx, dy, dz,
    params.cut_reach + math.sqrt((node.x - ox) ^ 2 + (node.y - oy) ^ 2 + (node.z - oz) ^ 2),
    params.cut_cone, params.cut_grab)
  -- Reach is from the PLAYER, exactly like the laser's: the ray starts back at
  -- the camera, so the range test has to be re-made here.
  if hit and hit.rec then
    local rx, ry, rz = hit.x - node.x, hit.y - node.y, hit.z - node.z
    if math.sqrt(rx * rx + ry * ry + rz * rz) > params.cut_reach then hit = nil end
  end
  if not hit then
    cut_target, cut_work, progress = nil, 0, 0
    show_beam(nil, 0)
    prompt = "no plant in reach  ·  walk up to something growing and hold LMB"
    return
  end
  local sp = hit.rec.sp
  if cut_target ~= hit.pid then
    cut_target, cut_work = hit.pid, 0.0
  end
  local tip = { x = hit.ax or hit.x, y = hit.ay or hit.y, z = hit.az or hit.z }
  if firing then
    cut_work = cut_work + dt
    show_beam(tip, 0.5)
  else
    show_beam(nil, 0)
  end
  progress = math.min(1.0, cut_work / math.max(0.1, sp.work))
  draw_plant(hit, firing)
  local inv = ref("inventory")
  prompt = string.format("%s   %d%%   ·   %s", sp.name,
    math.floor(progress * 100 + 0.5), inv and inv.line("astro") or "")
  if cut_work >= sp.work then
    local got, dropped = ff.harvest(hit, "astro")
    local mats = ref("materials")
    local parts = {}
    for _, g in ipairs(got) do
      parts[#parts + 1] = string.format("%s ×%d", (mats and mats.label(g.mat)) or g.mat, g.n)
    end
    say(#parts > 0 and table.concat(parts, ", ") .. (dropped > 0 and "  (pack full)" or "")
      or "pack full — nothing taken")
    spawnEffect("ScrapeDust", hit.x, hit.y, hit.z)
    cut_target, cut_work, progress = nil, 0, 0
  end
end

-- ── the spade ───────────────────────────────────────────────────────────────

local function fire_spade(node, mode)
  local h = laser_shot(node)
  if not h then return end
  local moved = true
  if last_x then
    local ddx, ddy, ddz = h.x - last_x, h.y - last_y, h.z - last_z
    moved = (ddx * ddx + ddy * ddy + ddz * ddz) >= (params.spade_radius * 0.45) ^ 2
  end
  if not moved and (time - last_t) < params.spade_rate then return end
  last_x, last_y, last_z, last_t = h.x, h.y, h.z, time
  terrain.sculpt(h.x, h.y, h.z, params.spade_radius, params.spade_strength, mode)
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  cam = ref("planet_camera")
  tool = save.get("tool.equipped") or 1
end

local hud

-- The trigger: LMB, and only LMB. E used to fire as well, but E is the door,
-- the console and "close" — one key doing three things meant a crater at the
-- front step of every facility and a beam across the screen as a panel opened.
local function trigger_down()
  return input.button(0) == true
end

function update(node, dt)
  inUse = false
  prompt = ""
  if not hud then hud = find("Tool HUD") end
  local carrying = on_foot(node)
  if hud then
    -- The HUD line lives here rather than in its own script: the belt already
    -- knows everything it says, and one writer means one place to change it.
    --
    -- It stays up when the belt is gated, and says what is holding it. Hiding
    -- it was the worst of the options: a player whose tools had been taken saw
    -- no tools, no belt, and no reason — and the belt is also the only place the
    -- game ever mentions that a harvester and a spade exist.
    local el = hud:getcomponent("UiElement")
    -- Not while paused, and not over the map: both own the whole screen.
    local pm, om = ref("pause_menu"), ref("orbit_map")
    local up = (carrying or gate ~= GATE_ABOARD) and not (pm and pm.open)
      and not (om and om.isOpen and om.isOpen())
    if el then el.visible = up end
    hudText = carrying and hudLine() or ("tools stowed  ·  " .. gate)
    if up and ui and ui.make then ui.make(hud, hotbar(carrying)) end
  end
  if not carrying then
    cut_target, cut_work, progress = nil, 0, 0
    charge, focus = 0.0, 0.0
    cut_progress = 0.0
    bore_drop()
    show_beam(nil, 0)
    publish_shake(0)
    hum_off()
    holster(true)
    return
  end
  -- THE AIM. Everything below fires along the camera's published view ray, and
  -- both of these bail-outs used to be silent — with the HUD already shown,
  -- because that is written above this line. So the belt looked completely
  -- normal, said it was ready, and did nothing at all when you pulled the
  -- trigger: "i still wasnt able to use my tools".
  --
  -- `planet_camera` stands down entirely while the orbit map is open, and it
  -- publishes DEFAULTS at load — a position of (0,0,0) and a forward of −Z,
  -- which are perfectly non-nil and aim from the middle of the solar system.
  -- So the interesting failure is not a missing camera, it is a camera that
  -- never started following anyone, and that has to be checked by whether the
  -- eye is anywhere near the crew rather than by whether the field exists.
  if not cam then
    cam = ref("planet_camera")
    if not cam then
      why("no planet_camera — nothing to aim along")
      return
    end
  end
  if not (cam.cam_x and cam.fwd_x) then
    why("the camera has not published a view yet")
    return
  end
  local eye_dx, eye_dy, eye_dz = cam.cam_x - node.x, cam.cam_y - node.y, cam.cam_z - node.z
  if (eye_dx * eye_dx + eye_dy * eye_dy + eye_dz * eye_dz) > 4000.0 then
    why(string.format(
      "the camera is %.0f m from the crew — it is following something else "
      .. "(orbit map open?), so a shot would fire from there",
      math.sqrt(eye_dx * eye_dx + eye_dy * eye_dy + eye_dz * eye_dz)))
    return
  end

  for i = 1, #TOOLS do
    if input.pressed(tostring(i)) and tool ~= i then
      tool = i
      save.set("tool.equipped", i)
      audio.play(SFX.swap, { track = "UI", volume = 0.45 })
      say(TOOLS[i].label .. " — " .. TOOLS[i].hint)
      cut_target, cut_work, progress = nil, 0, 0
      charge, cut_progress, focus = 0.0, 0.0, 0.0
      bore_drop()
      hum_off()
    end
  end

  local id = toolId()
  local firing = trigger_down()
  inUse = firing
  -- The tool is only in your hand when it's the tool you picked.
  holster(id ~= "laser")
  local inv = ref("inventory")
  if id == "laser" then
    local hit = fire_laser(node, dt, firing)
    local full = (inv and aimMat and inv.roomFor("astro", aimMat, 1) < 1) or false
    draw_ring(hit, firing, full)
  elseif id == "cutter" then
    fire_cutter(node, dt, firing)
    aimMat, aimDist = nil, nil
  else
    hum_off()
    show_beam(nil, 0)
    local h = laser_shot(node)
    if firing then
      fire_spade(node, "lower")
    elseif input.key("q") then
      fire_spade(node, "raise")
    else
      last_x, last_t = nil, -10
    end
    aimMat, aimDist = nil, nil
    -- The spade had no failure line at all: aim it past its reach and it read
    -- as a tool that had stopped working.
    prompt = h and TOOLS[3].hint
      or string.format("no target  ·  nothing within %.0f m of the crosshair",
        params.laser_reach)
    -- The spade gets the same ring: you are shaping ground, so seeing the brush
    -- footprint on it matters even more than it does for the laser.
    draw_ring(h, firing, false)
  end
end

-- ── the hotbar ──────────────────────────────────────────────────────────────
--
-- Drawn, not written: three slots with their keys, the one in your hand lit,
-- and one line above them for the hint, the aim readout or the last thing that
-- happened. It used to be one line of plain text floating over the ground,
-- which read as a debug print rather than as the belt. `hudText` keeps that
-- line as text for anything that reads it back.
hudText = ""

-- What the line above the slots says: the last thing that happened, else what
-- the tool is pointed at, else how to use it.
local function hint_line()
  local t = TOOLS[tool] or TOOLS[1]
  if time - msg_t < 3.0 and msg ~= "" then return msg end
  if prompt ~= "" then return prompt end
  return t.hint
end

-- The line above the slots, on its own strip of glass so it reads over a bright
-- sky as well as over dark ground.
local function pill(key, text)
  return { "row", key = key, style = "hud/toolHint", w = "fit", h = 26, align = "center",
           pad = 0, gap = 0,
           { "box", key = "l", w = 12, h = 1 },
           { "text", key = "t", w = "fit", h = "fit", textSize = 13, text = text },
           { "box", key = "r", w = 12, h = 1 } }
end

function hotbar(carrying)
  -- Put away, the belt draws nothing: whatever put it away (a panel, the pause
  -- menu, the pilot's seat) is already on screen and says so. The reason is
  -- still in `hudText` and `gate` for anyone debugging.
  if not carrying then
    return { "col", key = "belt", w = "fit", h = "fit", gap = 0, pad = 0 }
  end
  local slots = {}
  for i, tl in ipairs(TOOLS) do
    local on = i == tool
    slots[#slots + 1] = { "row", key = tl.id, style = on and "hud/slotActive" or "hud/slot",
      w = "fit", h = 34, gap = 8, align = "center",
      { "text", key = "k", style = on and "hud/keyActive" or "hud/key", w = 20, h = 20,
        textAlign = "center", textValign = "center", text = tostring(i) },
      { "text", key = "l", w = "fit", h = "fit", textSize = 13, text = tl.label } }
  end
  return { "col", key = "belt", w = "fit", h = "fit", gap = 6, pad = 0, align = "center",
    pill("hint", hint_line()),
    { "row", key = "slots", w = "fit", h = "fit", gap = 6, pad = 0, align = "center",
      items = slots, function(x) return x end } }
end

-- The HUD line: what's equipped, what it's pointed at, and the last thing that
-- happened. One line, because the crosshair is where you're looking.
function hudLine()
  local t = TOOLS[tool] or TOOLS[1]
  local inv = ref("inventory")
  -- The WHOLE belt, always, with the one you're holding marked. It used to show
  -- only the equipped tool, which meant a player who started on the laser had
  -- nothing anywhere on screen telling them a harvester existed — "i still cant
  -- even harvest the plants" was partly never finding out that [2] was a key.
  local belt = {}
  for i, tl in ipairs(TOOLS) do
    belt[#belt + 1] = string.format("%s%d %s", i == tool and "▸" or " ", i, tl.label)
  end
  local head = table.concat(belt, "   ")
  if time - msg_t < 3.0 and msg ~= "" then
    return head .. "   ·   " .. msg
  end
  if prompt ~= "" then return head .. "   ·   " .. prompt end
  return head .. "   ·   " .. (inv and inv.line("astro") or t.hint)
end
