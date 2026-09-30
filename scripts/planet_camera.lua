-- Planet-aware third-person orbit camera (pairs with planet_walker.lua).
--
-- An ordinary orbit camera works in WORLD yaw/pitch — on a radial-gravity
-- planet that frame stops matching "up" the moment you leave the pole, and the view
-- fights you. This one orbits in the CHARACTER'S local frame: up = the body's
-- −gravity up, and the yaw reference is parallel-transported as you walk around the
-- sphere, so the horizon stays level all the way around the planet.
--
--   RIGHT MOUSE (hold)  orbit    SCROLL  zoom    MIDDLE MOUSE / ALT  toggle lock
--
-- Exposes its view basis (env globals) for the walker and the tool belt:
--   fwd_x/fwd_y/fwd_z     the exact view direction (world space)
--   flat_x/flat_y/flat_z  that direction projected onto the tangent plane
--   cam_x/cam_y/cam_z     the camera position
--
-- ATTACH to a TOP-LEVEL Camera node (NOT parented to the player: script node
-- coordinates are parent-local, so a moving parent would double-apply).

defaults = {
  distance = 7.0,
  min_distance = 1.5,
  max_distance = 14.0,
  height = 1.2,        -- look-at point above the character's origin, along up
  -- FIRST PERSON: where the eyes are, along up. The astronaut's capsule is
  -- 2.0 m TIP TO TIP about its origin (`Body::capsule` — "total standing
  -- height"), so the crown is at +1.0 and the eyes sit just under it. Reusing
  -- `height` here would have put the camera 0.2 m ABOVE the head: fine as an
  -- orbit pivot, which is what it is for, and a floating drone in first person.
  eye_height = 0.85,
  -- Indoors (a roof within `ceiling_probe` over the crew) the orbit comes in to
  -- this, and the view may not look down from above the head: a building's
  -- ceiling is lower than a third-person camera's normal perch.
  indoor_distance = 3.5,
  ceiling_probe = 4.5,
  -- How quickly the pivot follows the crew UP AND DOWN while walking. A kerb
  -- pops the capsule up a few centimetres in one frame; followed exactly, the
  -- whole view jolts. In the air it follows tightly.
  pivot_follow = 12.0,
  -- While walking without holding the view, the orbit drifts round behind the
  -- direction of travel at this rate (rad/s at full speed; 0 = never).
  follow_yaw = 0.5,
  sensitivity = 0.3,
  zoom_speed = 1.0,
  start_pitch = -0.3,
}

shiftlock = false
-- Are we behind the eyes? Published, because it changes what other scripts mean:
-- the tool belt aims down the middle of the view, and nothing should be drawing
-- a body we are standing inside.
--
-- This used to be inferred, by everyone, from "is the camera within 0.7 m of the
-- character" — which is ALSO true every time the wall-clip ray finds something
-- behind you. So walking through a doorway, standing beside your own rocket or
-- backing into a tunnel snapped the view to the eyes and back out again, and the
-- game read as broken in exactly the places you spend the most time. First
-- person is now a MODE you scroll into, not a distance that happens to you.
firstPerson = false
-- Is the camera the reason the body isn't drawing? The walker self-heals the
-- astronaut's visibility (a vessel that seated the crew and then died leaves it
-- hidden with nobody to undo it) and that heal used to run every frame, against
-- this camera — so first person turned the node off and the walker turned the
-- MODEL CHILD, the part you actually see, straight back on. You spent first
-- person inside your own head. One owner: the camera decides, the walker asks.
hidesBody = false
-- View basis for other scripts (world space; set every frame).
fwd_x, fwd_y, fwd_z = 0.0, 0.0, -1.0
flat_x, flat_y, flat_z = 0.0, 0.0, -1.0
cam_x, cam_y, cam_z = 0.0, 0.0, 0.0

local target
local pitch = nil
-- The yaw reference direction, parallel-transported across the planet surface.
local ref = vec3(0, 0, -1)
-- The camera's up, SLEW-LIMITED toward −gravity. On foot it tracks fast (level
-- horizon as you walk); while FLYING it tracks GENTLY, so it follows the planet's
-- local vertical as you fly around the body (no more "upside-down on the far
-- side") yet spreads the discontinuous −gravity flip at an SOI hand-off into an
-- easy reorient instead of a jarring snap — see the up-slew below.
local cup = nil
-- The wall clip's distance, eased. See the clip block in lateUpdate.
local clip_back = nil
-- The pivot's height above the planet's centre, eased (see `pivot_follow`),
-- and the most the orbit may pull out to, eased toward the indoor limit.
local pivot_r = nil
local room_cap = nil

local PITCH_LIMIT = math.pi * 0.5 - 0.08

-- Point the view along a world direction (and optionally set its pitch). For
-- scripted views — test rigs, a cutscene, "look at the thing you just built".
-- The direction is flattened onto the local ground plane on the next frame.
function face(dx, dy, dz, p)
  ref = vec3(dx, dy, dz)
  if p then pitch = p end
end

local was_piloting = false

-- Cross-script singletons, resolved once and kept (floptle/0063 — findScript is
-- a scene walk).
-- NOT `ref`: that name is already taken, six lines up, by the yaw reference
-- vector this whole camera is built around. Shadowing it turns `ref:flatten(up)`
-- into an attempt to index a function.
local refs = {}
local function script_ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function map()
  return script_ref("orbit_map")
end

-- Is one of the game's panels in front of the player? First person grabs the
-- mouse, and a grabbed mouse cannot click a Sell button — so the grab has to
-- know about the panels. The panels each already publish this for the tool belt.
local function panel_open()
  local pm = script_ref("pause_menu")
  if pm and pm.open then return true end
  local fm = script_ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ob = script_ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return true end
  local ip = script_ref("inventory_panel")
  if ip and ip.open then return true end
  return false
end

local function acquire()
  for _, s in ipairs(findScripts("planet_walker")) do
    if net.isMine(s.node) then return s.node end
  end
  local w = findScript("planet_walker")
  return (w and w.node) or find("Astronaut") or find("Player")
end

function lateUpdate(node, dt)
  -- Map mode: the orbit map owns the camera while it's open — orbiting the
  -- focused body, not the player. Stand down entirely.
  local m = map()
  if m and m.map_view then return end
  -- Built vessels spawn/despawn at runtime — fetch fresh, never cache, and
  -- scan EVERY instance (several craft can be alive; the piloted one is the
  -- camera's subject, not whichever findScript happens to return first).
  local vessel = nil
  for _, s in ipairs(findScripts("vessel_controller")) do
    if s.piloting then vessel = s break end
  end
  local piloting = vessel ~= nil
  -- Swap on the TRANSITION, not by handle comparison (handles are fresh tables
  -- per access — equality never matches, which stuck the camera on the craft
  -- after exit).
  if piloting ~= was_piloting then
    was_piloting = piloting
    target = (piloting and vessel.node) or acquire()
  end
  if not (target and target.valid) then
    target = acquire()
    if not target then return end
  end
  if pitch == nil then pitch = params.start_pitch end

  -- NOT SHIFT: on foot that is sprint, and a key that both sprints and
  -- toggles the mouse grab did both every time you ran.
  if (input.clicked(2) or input.pressed("alt")) and not piloting then shiftlock = not shiftlock end

  -- ── zoom, and the line between third person and first ───────────────────────
  -- The old rule was one continuous range from `max_distance` down to zero, so
  -- between about 1.5 m and 0 the camera sat INSIDE the character: half a metre
  -- of view that is neither one thing nor the other, and which you had to scroll
  -- through in both directions. First person is a mode now. You scroll in to the
  -- closest orbit, one more click drops you behind the eyes, and one click out
  -- puts you straight back on the shoulder — no mush in between.
  local blocked = panel_open()
  local dz = input.scroll() * params.zoom_speed   -- + is toward the character
  local maxd = piloting and math.max(params.max_distance, 40.0) or params.max_distance
  -- Flying: never zoom INSIDE the hull (the ship visual spans ~2 units), and
  -- there is no first person in a cockpit this game does not model.
  local mind = piloting and math.max(params.min_distance, 5.0) or params.min_distance
  if piloting then
    firstPerson = false
    params.distance = math.clamp(params.distance - dz, mind, maxd)
  elseif firstPerson then
    if dz < -0.01 then
      firstPerson = false
      params.distance = mind
      clip_back = nil   -- an explicit scroll arrives NOW; the ease is for walls
    end
  else
    local want = math.clamp(params.distance - dz, mind, maxd)
    if dz > 0.01 and params.distance <= mind + 0.001 then
      firstPerson = true
      clip_back = nil
    end
    params.distance = want
  end

  -- ESC LEAVES FIRST PERSON. First person grabs the mouse, and the HUD's ☰
  -- button — the only way back to the main menu — needs a pointer. A mode you
  -- can only leave if you happen to know about the scroll wheel is a trap, and
  -- Esc is the key everybody tries first.
  if firstPerson and not blocked and input.pressed("escape") then
    firstPerson = false
    params.distance = mind
    clip_back = nil
  end

  -- Desired local up from the body (−gravity). Fallback: away from the origin
  -- (the planet sits at 0,0,0) if the body state isn't available yet.
  local want_up = target.up
  if not want_up or want_up:length() == 0 then
    want_up = target.pos:normalized()
    if want_up:length() == 0 then want_up = vec3(0, 1, 0) end
  end
  -- Slew-limit the up so a gravity/SOI transfer can't SNAP the view. Crossing an
  -- SOI boundary flips −gravity to point at a DIFFERENT body (the field is
  -- patched-conic — only the dominant body pulls), a discontinuous jump. FLYING
  -- uses a GENTLE rate: flying around a planet turns the local vertical only
  -- slowly (the orbital rate), so the camera tracks it near-perfectly and never
  -- ends up upside-down on the far side — but the instantaneous SOI flip is spread
  -- over ~a second into a smooth reorient instead of a snap. ON FOOT it tracks
  -- fast so the horizon stays level as you walk around the planet.
  if not cup then cup = want_up end
  if cup:angleTo(want_up) > 1e-4 then
    cup = ease(cup, want_up, piloting and 1.5 or 8.0, dt):normalized()
  end
  local up = cup

  -- Parallel-transport the yaw reference: project the previous reference onto
  -- the new tangent plane. Walking around the planet turns the frame WITH the
  -- surface, so the camera never rolls wildly or flips at the equator.
  ref = ref:flatten(up)
  if ref:length() == 0 then
    -- Degenerate (reference was parallel to up): pick any tangent.
    ref = up:cross(vec3(1, 0, 0)):normalized()
    if ref:length() == 0 then ref = up:cross(vec3(0, 0, 1)):normalized() end
  end

  -- Mouse steers while looking (RMB / shift lock); yaw rotates the reference
  -- around up (Rodrigues, u ⊥ r so it's just cos/sin), pitch is clamped.
  --
  -- IN FIRST PERSON THE MOUSE ALWAYS STEERS. Requiring a held right button to
  -- turn your own head is the single thing most responsible for first person
  -- "just not feeling right" here: the view is the aim, and a view you have to
  -- hold a button to move is a view you are fighting. The one exception is a
  -- panel — the depot's Sell button needs a pointer, and a grabbed mouse has
  -- none, so the panels take the cursor back for as long as they are up.
  local looking = (not blocked) and (firstPerson or shiftlock or input.button(1))
  input.setMouseLocked(looking)
  if looking then
    local dx, dy = input.mouse_delta()
    local sens = params.sensitivity * 0.01
    -- Yaw spins the reference about the LOCAL up, not about world +Y — which
    -- is the whole reason this camera exists.
    ref = ref:rotatedAround(up, -dx * sens)
    pitch = math.clamp(pitch - dy * sens, -PITCH_LIMIT, PITCH_LIMIT)
  end

  -- FOLLOW. Walking without holding the view, the orbit drifts round behind
  -- where you are going, so a long walk sideways turns into a walk away from
  -- the camera instead of a circle round it. Never while you back toward the
  -- camera — following that would spin the view round to face you.
  if not looking and not piloting and params.follow_yaw > 0 then
    local vel = vec3(target.vx or 0, target.vy or 0, target.vz or 0)
    local tv = vel - up * vel:dot(up)
    local sp = tv:length()
    if sp > 0.5 then
      local dir = tv * (1 / sp)
      local ang = math.atan2(ref:cross(dir):dot(up), ref:dot(dir))
      if math.abs(ang) < math.rad(100) then
        ref = ref:rotatedAround(up, ang * math.min(1, params.follow_yaw * math.min(1, sp / 8) * dt))
      end
    end
  end

  -- INDOORS: a roof over the crew brings the orbit in and stops it looking
  -- down from above the head, where it would sit in the ceiling. A raycast
  -- straight up is the whole test — every building is a roof, and so is a
  -- tunnel you have bored.
  -- The roof sets a CEILING on the zoom, eased, rather than a zoom: your own
  -- scroll setting is untouched and comes back when you step outside.
  local roof = (not piloting) and raycast(target.pos, up, params.ceiling_probe, target) or nil
  local cap = roof and params.indoor_distance or maxd
  if room_cap == nil or piloting then room_cap = cap end
  room_cap = room_cap + (cap - room_cap) * (1 - math.exp(-4 * dt))
  local room_d = math.min(params.distance, room_cap)
  if roof and not firstPerson and pitch < -0.3 then
    pitch = pitch + (-0.3 - pitch) * (1 - math.exp(-6 * dt))
  end

  -- View direction in the local frame: reference tilted by pitch toward up.
  local fwd = (ref * math.cos(pitch) + up * math.sin(pitch)):normalized()

  -- Look-at point: the character's head (along LOCAL up, not world Y). A
  -- piloted VESSEL's center is its CAPSULE, composed HERE from the node's
  -- rendered pose + the published pod-local offset: computed in the camera
  -- pass it sits exactly on the ship this frame draws — a fixedUpdate world
  -- position lags the rails carry (offset + jitter), and a gravity-up height
  -- guess slides off the hull the moment the vessel pitches.
  local head
  if piloting and vessel and vessel.podLY and target then
    -- `toWorld` composes the vessel's own rotation for us — the nine-term
    -- YXZ expansion this used to spell out by hand.
    head = target:toWorld(vec3(vessel.podLX or 0, vessel.podLY, vessel.podLZ or 0))
  else
    -- Third person orbits a point at chest height; first person sits at the
    -- EYES, which is higher. Pivoting first person around the chest is what
    -- makes a camera feel like it is mounted to a trolley rather than a head.
    --
    -- The pivot's height is EASED along up (see `pivot_follow`), measured from
    -- the planet's centre: the planet moves on rails, so the crew's world
    -- position is racing along its orbit and only the distance from the
    -- centre says whether they stepped up.
    local base = target.pos
    local d = space and space.dominant(base.x, base.y, base.z)
    local b = d and space.body(d)
    if b then
      local r = (base - vec3(b.x, b.y, b.z)):length()
      local walker = script_ref("planet_walker")
      local rate = (walker and walker.grounded) and params.pivot_follow or 40.0
      if not pivot_r or math.abs(r - pivot_r) > 1.5 then pivot_r = r end
      pivot_r = pivot_r + (r - pivot_r) * (1 - math.exp(-rate * dt))
      base = base + up * (pivot_r - r)
    end
    head = base + up * (firstPerson and params.eye_height or params.height)
  end

  -- Wall clip: sweep a ball from the head back toward the camera, ignoring the
  -- player. A ball, not a ray: the view is a volume, and a ray slips through
  -- the gap at a door frame or a rock's edge that the near plane then cuts.
  local back = firstPerson and 0.0 or room_d
  local hit = (not firstPerson) and spherecast(head, -fwd, 0.25, room_d + 0.3, target) or nil
  -- The wall clip must see WALLS only. The astronaut is not a wall — parked
  -- inside a pod while flying, it is directly between the camera and the
  -- craft, and clipping on it glued the view to the hull.
  if hit and hit.node then
    local astro = find("Astronaut")
    if astro and hit.node.id == astro.id then hit = nil end
  end
  if hit and hit.distance then
    back = math.max(0.3, hit.distance - 0.05)
  end

  -- SNAP IN, EASE OUT. A camera may never spend a frame inside a wall, so a
  -- closer answer is taken immediately — but popping back to full orbit the
  -- instant a doorway clears is what made walking around the base feel like the
  -- view was flinching. Coming out is a glide.
  if clip_back == nil or back <= clip_back then
    clip_back = back
  else
    clip_back = clip_back + (back - clip_back) * math.min(1.0, dt * 6.0)
  end
  back = firstPerson and 0.0 or clip_back

  -- Don't draw a body we are standing inside — first person, or a wall that has
  -- pushed the view into the character's shoulders. (While piloting, the vessel
  -- owns the astronaut's visibility — leave it alone.)
  hidesBody = firstPerson or back < 0.7
  if not piloting then
    target.visible = not hidesBody
  end

  local place = head - fwd * back
  -- SCREEN SHAKE: the vessel publishes cam.shake (liftoff rumble, buffeting,
  -- crashes). Jitter the camera position along its right/up so the view rattles
  -- while the look target holds steady. Squared for an ease-in (small = subtle).
  -- REDUCED MOTION. The engine snaps its own UI transitions when a player asks
  -- for it, but it cannot tell which of a game's movement is the game — so the
  -- shake is ours to switch off, and this is the only place in the project that
  -- moves the view for effect. (v0.33.0, ⚙ Settings → ♿ Accessibility.)
  local sh = save.get("cam.shake") or 0.0
  if access.reducedMotion() then sh = 0.0 end
  if sh > 0.002 then
    local amp = sh * sh * 0.5
    place = place
      + ref * ((math.random() * 2 - 1) * amp)
      + up * ((math.random() * 2 - 1) * amp)
  end
  node.pos = place

  -- Point the camera down `fwd` with the LOCAL up overhead, so the horizon
  -- reads level all the way around the planet. `lookAt` with an `up` sets the
  -- roll too — that is the entire twenty-line undo-yaw-then-pitch dance.
  node:lookAt(place + fwd, up)

  -- Publish the basis for the walker + dig tool.
  fwd_x, fwd_y, fwd_z = fwd.x, fwd.y, fwd.z
  cam_x, cam_y, cam_z = place.x, place.y, place.z
  -- Flat against the BODY's up, not the camera's slewed one: this is the
  -- walker's forward, and it has to lie in the plane the crew walks on.
  local flat = fwd:flatten(want_up)
  if flat:length() == 0 then flat = ref end
  flat_x, flat_y, flat_z = flat.x, flat.y, flat.z
end
