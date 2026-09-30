-- Planet-surface character controller (pairs with planet_camera.lua).
--
-- Movement happens in the tangent plane of the body's LOCAL up (−gravity), with
-- the forward direction taken from the planet camera's published view basis — so
-- W always walks "away from the camera" no matter where on the planet you stand.
-- The body's Rigidbody should have "align to gravity" ON so the capsule (and any
-- children) tilt with the surface.
--
--   W A S D   move (camera-relative)      SPACE  jump (when grounded)
--   SHIFT     hold to sprint

defaults = {
  --@header Movement
  -- Ground speed with no modifier held.
  --@range 0 20 --@units m/s
  walk = 4.5,
  -- Ground speed while SHIFT is held.
  --@range 0 30 --@units m/s
  run = 8.0,
  -- How hard the feet chase the speed you ask for: the share of the gap closed
  -- each second, exponentially. High is snappy, low is icy.
  --@range 1 40 --@units 1/s
  accel = 14.0,
  -- The same, with nothing under you. Low, so a jump commits you to it but
  -- you can still steer a landing.
  --@range 0 20 --@units 1/s
  air_accel = 2.5,
  -- Upward speed SPACE gives you, along the surface's up.
  --@range 0 20 --@units m/s
  jump = 7.0,
  -- How far down to look for ground (a capsule's feet plus slack).
  --@range 0.2 5 --@units m
  ground_ray = 1.6,
  -- The most upward speed a CONTACT may give you while your feet are down —
  -- enough to walk up a kerb, not enough to launch. See the up-axis block in
  -- `update`: this number is the whole fix for "constantly flinging up into the
  -- air". Zero pins you to the ground and you will catch on every seam.
  --@range 0 8 --@units m/s
  step_pop = 1.6,
  -- Terminal velocity. A long fall that outruns the collider goes through it.
  --@range 5 200 --@units m/s
  fall_max = 60.0,

  --@header Character model
  -- Facing offset (radians) added to the character's yaw — flip by π if the
  -- model faces backwards.
  --@slider -3.15 3.15 --@step 0.01 --@units rad
  face_offset = 0.0,
  -- How fast the body turns to face where it is going (exponential, 1/s).
  --@range 1 40 --@units 1/s
  turn = 12.0,

  --@header Swimming
  -- Slower than walking (see the water block in update).
  --@range 0 20 --@units m/s
  swim = 3.0,
  --@range 0 20 --@units m/s
  swim_fast = 4.6,
  -- The climb rate SPACE / CTRL give you against the buoyant bob.
  --@range 0 20 --@units m/s
  swim_climb = 3.2,
}

-- IS THE CREW OUT AND ABOUT? Published, and the answer every interaction gate in
-- the game should be asking for.
--
-- The question they used to ask was `astronaut.visible`, which is a DIFFERENT
-- question wearing the same clothes. planet_camera hides the body whenever the
-- camera ends up within 0.7 m of it — scrolled into first person, yes, but also
-- any time the wall-clip ray finds a wall behind you. Walking INSIDE one of the
-- base buildings does that constantly, and so does standing beside your own
-- rocket. So the facility prompt switched itself off as you stepped through the
-- door, and the mining laser died in any tight space: "sometimes they work other
-- times completely broken."
--
-- This flag means what those gates meant: the crew is out of the pod, the world
-- is running, and they are under their own control.
onFoot = false
-- Feet on something (contact, or the ground probe). Published for the camera,
-- which smooths a step up while you are walking and follows tightly in the air.
grounded = false

local cam
local rig
-- When we last left the ground under our own power. The ground probe reaches
-- 1.6 m down, so for the first fraction of a second of a jump we are still
-- "grounded" by it — and the up-axis rule below would take the jump straight
-- back off us. Held for exactly as long as it takes to clear the probe.
local jump_t = -10.0
local JUMP_LOCKOUT = 0.28
-- The swim float's own radial speed (see the WATER block in update).
local swim_vup = 0
-- The tangent velocity we are steering, eased toward what the keys ask for.
-- Kept here rather than read back off the body: a contact's sideways shove is
-- the solver's business for one frame, not a speed to hold.
local mvx, mvy, mvz = 0.0, 0.0, 0.0
-- The slope's share of last frame's up speed, so this frame can tell the climb
-- we asked for from the push a contact gave us.
local slope_vup = 0.0
local was_contact = false
local air_t = 0.0          -- seconds since the feet were last down
local flying = false       -- a jump or a real fall is under way

-- Animated character (the "AstroModel" child).
local model = nil          -- nil = unresolved, else the node
local model_y = nil        -- its authored height under the capsule
local anim = nil
local face_yaw = 0.0       -- model yaw, in the Astronaut node's frame
local yaw_rate = 0.0
local FOOTSTEPS = "audio/kenney/impact/footstep_concrete_00"

-- Scripted steering, for test rigs and cutscenes: while set, it replaces the
-- keys. `f`/`s` are forward and right (−1..1) in the camera's frame; `jump`
-- jumps once, the next time the feet are down.
local steer_f, steer_s, steer_sprint, steer_jump = nil, 0.0, false, false
function steer(f, s, sprint, jump)
  steer_f, steer_s, steer_sprint, steer_jump = f, s or 0.0, sprint == true, jump == true
end

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

local function resolve_model(node)
  -- Keep looking until we actually have a LIVE model child: on frame 1 the
  -- "AstroModel" child may not be spawned yet, and giving up then left the
  -- character in its bind pose forever. The animator binds a frame or two
  -- after that (its clip list is empty until it has), so it is re-asked for
  -- until it answers with clips.
  if not (model and model.valid) then
    model, anim, model_y = nil, nil, nil
    for _, c in ipairs(node:children()) do
      if c.name == "AstroModel" then model = c end
    end
    if model then model_y = model.y or 0.0 end
  end
  if model and not anim then
    local a = model:animator()
    if a and #a:clips() > 0 then anim = a end
  end
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

-- The signed shortest turn from angle a to angle b.
local function wrap(d)
  return (d + math.pi) % (2 * math.pi) - math.pi
end

local function smoothstep(a, b, x)
  local t = math.clamp((x - a) / (b - a), 0.0, 1.0)
  return t * t * (3 - 2 * t)
end

-- ── the animation rig ────────────────────────────────────────────────────────
-- animation_controllers/character.actl.ron (generated by
-- tools/gen_astronaut_anims.py) has a Base layer of ordinary states — idle,
-- jump, fall, land — and above it a Gait layer: ONE blend state mixing walk,
-- run and sprint by the `gait` parameter (0, 1, 2), frozen and scrubbed from
-- here to a phase. Every clip in a blend plays at the same normalised time, so
-- a walk blending into a run keeps both sets of feet in step. The strides are
-- the generator's: the ground one full cycle covers at the speed it was
-- authored for. Playing phase at speed / stride per second is what keeps a foot
-- that is down from sliding.
local STRIDE = { walk = 1.6, run = 3.312, sprint = 5.58 }
local phase = 0.0          -- 0 = left heel strike, 0.5 = right
local gait_amt = 0.0       -- 0 = standing (Base shows), 1 = a gait owns the body
local gait_sent = nil      -- the last `gait` written, so an unchanged one isn't re-sent
local layer_w = {}         -- last weights written, so unchanged ones aren't re-sent
local land_dip = 0.0

local function set_weight(layer, w)
  if math.abs((layer_w[layer] or -1) - w) > 0.004 then
    anim:setLayerWeight(layer, w)
    layer_w[layer] = w
  end
end

-- Where a ground speed sits on the Gait blend: 0 walk, 1 run, 2 sprint. The
-- two ramps never overlap, so at most two clips are ever mixed.
local function gait_at(spd)
  return smoothstep(2.4, 4.2, spd) + smoothstep(5.8, 8.2, spd)
end

-- Footstep at each heel strike: the phase crossing 0 (left) or 0.5 (right).
local function footstep(node, from, to)
  local crossed = math.floor(to * 2) ~= math.floor(from * 2) or to < from
  if not crossed then return end
  local n = math.floor(time * 137.0) % 5
  audio.play(FOOTSTEPS .. n .. ".ogg", node,
    { track = "SFX", volume = 0.5, mode = "spatial", falloff = "inverse",
      minDistance = 3.0, maxDistance = 60.0 })
end

-- Drive the layers from what the body is actually doing.
local function animate(node, dt, spd, on_ground, jumped, swimming, landed_at)
  if anim then
    -- Base: a jump the moment it's asked for; FALL only after a moment with
    -- nothing underfoot (a kerb or a crest is not a fall); LAND on touchdown.
    local st = anim:state("Base")
    if jumped then
      anim:restart("jump", 0.06, "Base")
    elseif not on_ground and not swimming then
      if st == "jump" then
        local d = anim:duration("jump") or 0.5
        if (anim:time("Base") or 0) > d - 0.12 then anim:crossfade("fall", 0.25, "Base") end
      elseif st ~= "fall" and air_t > 0.15 then
        anim:crossfade("fall", 0.2, "Base")
      end
    elseif landed_at then
      if st == "fall" or st == "jump" then anim:restart("land", 0.05, "Base") end
    elseif st == "fall" or st == "jump" then
      anim:crossfade("idle", 0.2, "Base")
    end
  end

  -- Gaits: in on the ground (or in the water) as soon as the body moves, out
  -- quickly when it leaves the ground.
  local want_amt = ((on_ground or swimming) and smoothstep(0.15, 0.6, spd)) or 0.0
  gait_amt = gait_amt + (want_amt - gait_amt) * (1 - math.exp(-(want_amt < gait_amt and 14 or 8) * dt))
  local g = gait_at(spd)
  local stride = g < 1 and STRIDE.walk + (STRIDE.run - STRIDE.walk) * g
    or STRIDE.run + (STRIDE.sprint - STRIDE.run) * (g - 1)
  local before = phase
  if gait_amt > 0.01 then phase = (phase + dt * spd / stride) % 1.0 end
  if on_ground and not swimming and gait_amt > 0.5 then footstep(node, before, phase) end
  if not anim then return end

  set_weight("Gait", math.clamp(gait_amt, 0, 1))
  if gait_amt > 0 then
    if not gait_sent or math.abs(gait_sent - g) > 0.002 then
      anim:setParam("gait", g)
      gait_sent = g
    end
    -- The run clip is the blend's clock; the other two follow it by phase.
    anim:seek(phase * (anim:duration("run") or 1.0), "Gait")
  end
end

function start(node)
  rig = node:getcomponent("RigidBody")
  cam = ref("planet_camera")
end

-- The yaw, in the Astronaut node's own frame, that faces a WORLD direction.
-- The node is kept upright by the engine (align to gravity) with a shortest-arc
-- turn, so its heading drifts against the world as you walk round the planet;
-- a yaw worked out from world axes was right only near the spawn and spun the
-- character when the view ran along world ±Y.
local function local_yaw(node, dx, dy, dz)
  local l = node:toLocal(node.pos + vec3(dx, dy, dz))
  local p = node:toLocal(node.pos)
  local lx, lz = l.x - p.x, l.z - p.z
  if lx * lx + lz * lz < 1e-8 then return nil end
  return math.atan2(lx, lz) + params.face_offset
end

-- ── the pose on top of the clips ─────────────────────────────────────────────
-- Leaning, looking and planting the feet are written onto the bones each frame
-- (anim:addBoneRot / reach / lookAt). They last one frame, run after the clips
-- in the order they are called, and hand the bone back the frame we stop.
--
-- WHEN matters on a planet that moves. The animation pass runs straight after
-- `update`, before the physics ticks and the rails move the planets; a write
-- from `lateUpdate` would wait for the NEXT frame's pass. So all of it is
-- issued from `update`, and every world point in it (a ray hit, a look target,
-- a knee's pole) comes from the same world the pass converts it out of —
-- nothing moves in between. The pose is kept relative to the model, and the
-- planet then carries body, ground and pose along together.
--
-- The rig (models/astronaut/astronaut_male.glb) is Blender's, hung upside
-- down: `MaleArm` is the armature root, and no clip keys it, so it is ours;
-- `Back` is the torso hanging from the chest; `Hip` — with both legs — is a
-- CHILD of Back. Skeleton space faces +Z with +Y up and +X on the left, and
-- MaleArm's own axes are it turned 90° about X, so a bank about the skeleton's
-- forward is a YAW of MaleArm. Back and Hip sit near 180° about X: pitch keeps
-- its sign on them, yaw and roll flip. The numbers are the rest pose's, from
-- tools/gen_astronaut_anims.py.
local MA_UP = 1.61496       -- MaleArm's origin over the soles (skeleton space)
local HIP_Y, HIP_Z = -0.30701, 0.01622   -- the Hip joint from Back's origin
local ANKLE = 0.0722        -- the ankle over the sole, standing flat
local TOE = vec3(0.0, -0.2546, 0.9671)   -- a foot's rest heel-to-toe, skeleton space
local HIP_DROP_MAX = 0.3    -- under a bent leg's reach, or the low foot can't get there
local REACH_UP, REACH_DOWN = 0.5, 0.6    -- how far above / below the soles a foot looks

local bank_s, pitch_s, twist_s = 0.0, 0.0, 0.0
local accel_s, last_spd = 0.0, 0.0
local look_w, look_dir = 0.0, nil
local plant_w, plant_drop = 0.0, 0.0
local ma_dy, ma_dy_last = 0.0, 0.0   -- how far this / last frame's writes moved MaleArm up

-- The model's forward (+Z, the way the rig faces), as a world vector.
local function model_forward(node)
  return node:toWorld(vec3(math.sin(face_yaw), 0, math.cos(face_yaw))) - node:toWorld(vec3(0, 0, 0))
end

-- LOOK. The head follows the view — or, with the trigger held, the spot the
-- tool is working — and the chest takes a share of the turn so one neck bone
-- isn't doing it all. The view's pitch is halved and capped: an orbit camera
-- looks DOWN at the crew, and a head copying it stares at its boots. A view
-- behind the back lets go rather than wringing the neck round.
local function look(node, dt, up)
  local head = anim:boneWorld("Head")
  local want, dir = 0.0, nil
  if head and cam and cam.fwd_x then
    local f = vec3(cam.fwd_x, cam.fwd_y, cam.fwd_z)
    local tb = ref("tool_belt")
    if tb and tb.inUse == true and tb.aimDist and cam.cam_x then
      dir = (vec3(cam.cam_x, cam.cam_y, cam.cam_z) + f * tb.aimDist - head):normalized()
    else
      local fu = f:dot(up)
      local flat = (f - up * fu):normalized()
      local pitch = math.clamp(math.asin(math.clamp(fu, -1, 1)) * 0.5, -0.35, 0.45)
      dir = flat * math.cos(pitch) + up * math.sin(pitch)
    end
    local yaw = local_yaw(node, dir.x, dir.y, dir.z)
    local off = yaw and wrap(yaw - face_yaw) or 0.0
    want = 1 - smoothstep(math.rad(95), math.rad(120), math.abs(off))
    twist_s = twist_s + (math.clamp(off * 0.25, -0.35, 0.35) * want - twist_s) * (1 - math.exp(-5 * dt))
  else
    twist_s = twist_s * math.exp(-5 * dt)
  end
  look_w = look_w + (want - look_w) * (1 - math.exp(-5 * dt))
  if dir then
    look_dir = look_dir and (look_dir + (dir - look_dir) * (1 - math.exp(-8 * dt))):normalized() or dir
  end
  return head
end

-- LEAN. A runner banks into a turn as far as the speed and the turn rate
-- would tip them (half of it — a full bank reads as a stunt), leans into a
-- speed-up and sits back out of a stop. The whole body banks about the feet;
-- the chest adds its share of the bank, all of the pitch and the look's twist,
-- turning about the Hip joint with the legs turned back, so the stride under
-- it is the clip's.
local function lean(dt, spd, on_ground)
  local bank, pitch = 0.0, 0.0
  if on_ground then
    local a = (spd - last_spd) / math.max(dt, 1e-4)
    accel_s = accel_s + (math.clamp(a, -30, 30) - accel_s) * (1 - math.exp(-6 * dt))
    bank = -math.atan(spd * yaw_rate / 9.8) * 0.5     -- + yaw is a LEFT turn; + roll tips right
    pitch = math.atan(accel_s / 9.8) * 0.8
  else
    accel_s = 0.0
  end
  last_spd = spd
  local k = 1 - math.exp(-8 * dt)
  bank_s = bank_s + (math.clamp(bank, -0.3, 0.3) - bank_s) * k
  pitch_s = pitch_s + (math.clamp(pitch, -0.2, 0.25) - pitch_s) * k

  local b = bank_s * 0.7
  if math.abs(b) > 1e-4 then
    anim:addBoneRot("MaleArm", b, 0, 0)
    anim:addBonePos("MaleArm", vec3(-MA_UP * math.sin(b), MA_UP * (math.cos(b) - 1), 0))
    ma_dy = ma_dy + MA_UP * (math.cos(b) - 1)
  end
  local r, p, y = bank_s * 0.3, pitch_s, twist_s
  if math.abs(r) + math.abs(p) + math.abs(y) > 1e-4 then
    anim:addBoneRot("Back", -y, p, -r)
    anim:addBoneRot("Hip", y, -p, r)
    -- Where that swung the Hip joint (skeleton space, small angles), undone by
    -- moving Back the other way — in MaleArm's axes and half-scale.
    local dx = -HIP_Y * math.sin(r) + HIP_Z * math.sin(y)
    local dy = HIP_Y * (math.cos(p) * math.cos(r) - 1) - HIP_Z * math.sin(p)
    local dz = HIP_Y * math.sin(p) + HIP_Z * (math.cos(p) - 1)
    anim:addBonePos("Back", vec3(-dx, -dz, dy) * 2)
  end
end

-- FEET ON UNEVEN GROUND. The capsule rests on its lowest point, so on a slope
-- or a rock one foot hangs in the air and the other is buried. Each foot looks
-- down the body's up for the ground under it; the hips drop to the lower one
-- and both legs reach for their own, knees bending forward, soles turned to
-- the slope. Only while standing — a stride owns its own feet — and faded,
-- never snapped.
--
-- Where the feet ARE is not read off the foot bones: `boneWorld` answers last
-- frame's pose, which this already bent, and reading it back walks the feet
-- down a slope a little further every frame. The idle stance is fixed in the
-- rig's space (tools/gen_astronaut_anims.py), so the feet are placed from
-- MaleArm, which no clip moves, less what we moved it by last frame; the soles'
-- plane is found the same way. (The constant that guessed it was 8 cm out, and
-- a straight leg can't stretch 8 cm.)

local STANCE = { Left = vec3(0.1389, -1.5428, -0.0858), Right = vec3(-0.1389, -1.5428, -0.0858) }
local function plant(node, dt, up, want)
  plant_w = plant_w + (want - plant_w) * (1 - math.exp(-(want < plant_w and 12 or 6) * dt))
  if plant_w < 0.01 then plant_drop = 0.0 return end
  local fwd = model_forward(node)
  local left = up:cross(fwd)
  local ma = anim:boneWorld("MaleArm")
  if not ma then return end
  ma = ma - up * ma_dy_last                     -- where the clips alone put it
  local base = node.pos + up * ((ma - node.pos):dot(up) - MA_UP)
  local hits, low = {}, 0.0
  for side, st in pairs(STANCE) do
    local p = ma + left * st.x + fwd * st.z
    local over = base + (p - base) - up * (p - base):dot(up)
    local hit = raycast(over + up * REACH_UP, -up, REACH_UP + REACH_DOWN, node)
    if hit then
      local n = vec3(hit.nx or 0, hit.ny or 0, hit.nz or 0)
      if n:dot(up) < 0.5 then n = up end
      local gap = math.clamp(REACH_UP - hit.distance, -HIP_DROP_MAX, HIP_DROP_MAX)
      hits[side] = { pos = over + up * gap, n = n }
      low = math.min(low, gap)
    end
  end
  plant_drop = plant_drop + (-low - plant_drop) * (1 - math.exp(-10 * dt))
  anim:addBonePos("MaleArm", vec3(0, -plant_drop * plant_w, 0))
  ma_dy = ma_dy - plant_drop * plant_w
  for side, h in pairs(hits) do
    local ankle = h.pos + h.n * ANKLE
    anim:reach("Foot." .. side, ankle, { pole = ankle + fwd * 0.5 + up * 0.5, weight = plant_w })
    local along = (fwd - h.n * fwd:dot(h.n)):normalized()
    anim:lookAt({ "Foot." .. side }, ankle + along * TOE.z + h.n * TOE.y,
      { axis = TOE, limit = 35, weight = plant_w })
  end
end

-- The whole pose, in the order the engine applies it: bone writes (the lean,
-- the hips' drop), then the legs' reach, then the head's look.
local function pose(node, dt, up, spd, on_ground, standing)
  ma_dy_last, ma_dy = ma_dy, 0.0
  local head = look(node, dt, up)
  lean(dt, spd, on_ground)
  plant(node, dt, up, standing)
  if head and look_dir and look_w > 0.01 then
    anim:lookAt({ "Head" }, head + look_dir * 10, { limit = 75, weight = 0.9 * look_w })
  end
end

function update(node, dt)
  if not cam then cam = ref("planet_camera") end
  -- The character model rides as a child; keep its visibility mirrored to us so
  -- boarding/EVA (which toggle node.visible) hide/show the whole astronaut even
  -- though a child's visibility isn't auto-inherited.
  resolve_model(node)
  if model then model.visible = node.visible end
  -- Hands off while a craft is flying us: it parks and carries this body
  -- itself. Fetched fresh with EVERY instance scanned, because several craft
  -- can be alive and only one of them has a pilot in it.
  for _, vessel in ipairs(findScripts("vessel_controller")) do
    if vessel.piloting then onFoot = false return end
  end
  if (save.get("shipyard.pilot") or 0) == 1 then onFoot = false return end
  -- Nor while the world is still streaming in: the crew is parked in the sky
  -- over the spawn planet then, not standing anywhere they could interact with.
  local gm = ref("game_manager")
  if gm and gm.loading then onFoot = false return end
  -- Nothing is piloting us anywhere: we must be walkable, and visible unless
  -- the CAMERA is deliberately hiding us.
  --
  -- The self-heal (a destroyed vessel can't un-hide the astronaut it seated) was
  -- unconditional, and it ran against planet_camera every single frame: the
  -- camera turned the astronaut node off for first person, and this turned the
  -- AstroModel child — the part you actually see, which does not inherit its
  -- parent's visibility — straight back on. First person put you inside your own
  -- head. The camera owns the decision now; this only asks, and only heals the
  -- case the camera isn't responsible for.
  onFoot = true
  local cam_hides = cam ~= nil and cam.hidesBody == true
  if not node.visible and not cam_hides then node.visible = true end
  if model then model.visible = node.visible end

  -- Local up: the body's −gravity axis (fallback: radially out from origin).
  local ux, uy, uz = node.up_x, node.up_y, node.up_z
  if not ux or (ux == 0 and uy == 0 and uz == 0) then
    ux, uy, uz = norm(node.x, node.y, node.z)
    if ux == 0 and uy == 0 and uz == 0 then ux, uy, uz = 0, 1, 0 end
  end

  -- Forward = the camera's view, flattened against THIS BODY's up. The camera
  -- publishes a flat view too, but against its own slewed up, which trails the
  -- body's on a fast walk round a small world — and a forward that isn't in our
  -- tangent plane walks us into the ground or off it.
  local fx, fy, fz
  if cam and cam.fwd_x then
    fx, fy, fz = cam.fwd_x, cam.fwd_y, cam.fwd_z
  else
    local yaw = input.aimYaw() or 0.0
    fx, fy, fz = -math.sin(yaw), 0.0, -math.cos(yaw)
  end
  local fd = fx * ux + fy * uy + fz * uz
  fx, fy, fz = norm(fx - ux * fd, fy - uy * fd, fz - uz * fd)
  if fx == 0 and fy == 0 and fz == 0 and cam and cam.flat_x then
    -- Looking straight down: the published flat view already chose a heading.
    fx, fy, fz = cam.flat_x, cam.flat_y, cam.flat_z
    fd = fx * ux + fy * uy + fz * uz
    fx, fy, fz = norm(fx - ux * fd, fy - uy * fd, fz - uz * fd)
  end
  if fx == 0 and fy == 0 and fz == 0 then return end
  -- right = forward × up (tangent, ⊥ forward).
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux

  local f, s, sprint = 0, 0, false
  if steer_f then
    f, s, sprint = steer_f, steer_s, steer_sprint
  else
    if input.key("w") then f = f + 1 end
    if input.key("s") then f = f - 1 end
    if input.key("d") then s = s + 1 end
    if input.key("a") then s = s - 1 end
    sprint = input.key("shift")
  end
  local il = math.sqrt(f * f + s * s)
  if il > 1 then f, s = f / il, s / il end
  local speed = sprint and params.run or params.walk

  -- Grounding with forgiveness: contact flag OR a short probe along −up.
  local contact = node.grounded == true
  local ground_hit = nil
  if not contact and params.ground_ray > 0 then
    ground_hit = raycast(node.x, node.y, node.z, -ux, -uy, -uz, params.ground_ray, node)
  end
  local on_ground = contact or ground_hit ~= nil
  grounded = on_ground

  -- WATER. A world's sea is a sphere at a fixed radius (climate owns the rule),
  -- and inside it you swim: slower, no jump, and buoyant — you rise to the
  -- surface on your own and bob there. SPACE climbs, CTRL dives. The water has
  -- no collider (it's drawn, not simulated — floptle/0038), so this controller
  -- IS the swimming physics, which is why the drag and the bob live here.
  local cl = ref("climate")
  local depth = cl and cl.seaDepth(node.x, node.y, node.z) or nil
  local swimming = depth ~= nil and depth > 0.7
  if swimming then
    speed = sprint and params.swim_fast or params.swim
  end

  -- ── the tangent velocity ────────────────────────────────────────────────────
  -- Eased toward what the keys ask for rather than set to it, so a start has a
  -- step or two of pick-up and a stop a step of run-out — and in the air far
  -- more gently, so a jump is committed but a landing can still be steered.
  -- Re-flattened every frame: the tangent plane turns under you as you walk.
  local tx, ty, tz = (fx * f + rx * s) * speed, (fy * f + ry * s) * speed, (fz * f + rz * s) * speed
  local md = mvx * ux + mvy * uy + mvz * uz
  mvx, mvy, mvz = mvx - ux * md, mvy - uy * md, mvz - uz * md
  local rate = (on_ground or swimming) and params.accel or params.air_accel
  local k = 1 - math.exp(-rate * dt)
  mvx, mvy, mvz = mvx + (tx - mvx) * k, mvy + (ty - mvy) * k, mvz + (tz - mvz) * k

  -- ── the up axis ─────────────────────────────────────────────────────────────
  -- WHATEVER THE SOLVER DID TO US THIS FRAME arrives here as `vup`, and this
  -- used to write it straight back out. So the controller did not merely
  -- tolerate an ejection impulse — it MAINTAINED one. Terrain is a surface-nets
  -- mesh whose faces meet at angles; being pushed out of a seam, off a crest or
  -- out of the wall of a tunnel you just bored hands you a few metres per second
  -- along the local up, and the next frame took that as the velocity to hold.
  -- Cross a ridge at a run and the capsule left the planet. That is "constantly
  -- flinging up into the air", and it is also how you end up in the void.
  --
  -- So while the feet are down the up axis is OURS. It is a jump, or the climb
  -- the slope asks for plus at most a kerb's worth of pop — enough to walk up a
  -- step, not enough to launch. Only in the air does physics get the axis back,
  -- and even there a contact cannot hand out more climb than a jump would.
  local vup = node.vx * ux + node.vy * uy + node.vz * uz
  local impact = -vup
  local airborne = (not on_ground) or (time - jump_t) < JUMP_LOCKOUT
  local jumped = false
  if swimming then
    -- Buoyancy pulls you toward the surface, hard when you're deep and gently
    -- as you reach it, so floating is the resting state rather than a fight.
    local want = math.min(2.2, math.max(0.0, depth - 0.7) * 1.1)
    if input.key("space") then want = params.swim_climb end
    if input.key("ctrl") then want = -params.swim_climb end
    -- Eased from THIS controller's own last value, not from the body's: the
    -- sea is an engine Water Volume now, and its Archimedes push lands on the
    -- capsule between frames. Easing from the body's velocity folded that push
    -- in every frame on top of the swim float, and a swimmer let go three
    -- metres down came out of the water four metres into the air.
    swim_vup = swim_vup + (want - swim_vup) * math.min(1.0, dt * 4.0)
    vup = swim_vup
    slope_vup = 0.0
  elseif not airborne then
    -- SLOPES: the move is along the ground, not the tangent plane, so a hill
    -- is climbed at the speed you asked for instead of being shoved up it by
    -- the solver one contact at a time — and walking down it keeps the feet on
    -- it instead of skipping off in little ballistic hops.
    local slope = 0.0
    local n = node.groundNormal
    if n then
      local nu = n.x * ux + n.y * uy + n.z * uz
      if nu > 0.35 then slope = -(mvx * n.x + mvy * n.y + mvz * n.z) / nu end
    end
    -- SNAP DOWN. Walking off a crest or down a step, the contact goes a frame
    -- before the probe does; the body would sail on at its old height and come
    -- down a moment later. Pulled back onto the ground the probe still sees.
    if not contact and was_contact and ground_hit then
      local gap = ground_hit.distance - (node.height or 2.0) * 0.5
      if gap > 0.02 then slope = math.min(slope, -math.min(8.0, gap / math.max(dt, 1e-3))) end
    end
    swim_vup = vup
    if input.pressed("space") or (steer_f and steer_jump) then
      steer_jump = false
      vup = params.jump
      jump_t = time
      jumped = true
      slope = 0.0
    else
      vup = slope + math.min(vup - slope_vup, params.step_pop)
    end
    slope_vup = slope
  else
    vup = math.max(-params.fall_max, math.min(vup, params.jump))
    swim_vup = vup
    slope_vup = 0.0
  end
  was_contact = contact
  node.vx = mvx + ux * vup
  node.vy = mvy + uy * vup
  node.vz = mvz + uz * vup

  -- Standing still on a slope: max friction so you don't slide downhill.
  if rig then
    if f == 0 and s == 0 and on_ground then
      rig.friction = 1
    else
      rig.friction = 0
    end
  end

  -- ── the character: facing, then the animation layers ──────────────────────
  -- What the body is ACTUALLY doing, not what the keys say: run into a wall
  -- and you stand; get shoved and your legs catch up.
  local bvx, bvy, bvz = node.vx, node.vy, node.vz
  local bu = bvx * ux + bvy * uy + bvz * uz
  bvx, bvy, bvz = bvx - ux * bu, bvy - uy * bu, bvz - uz * bu
  local spd = math.sqrt(bvx * bvx + bvy * bvy + bvz * bvz)

  -- Face the way you are going; while AIMING — behind the eyes, shift-locked,
  -- or the tool in your hand is running — face the view instead, so the body
  -- is behind the tool and a strafe is a strafe. (No model, nothing to turn.)
  if model then
    local tb = ref("tool_belt")
    local aiming = cam ~= nil and (cam.firstPerson == true or cam.shiftlock == true)
      or (tb ~= nil and tb.inUse == true)
    local want
    if aiming then
      want = local_yaw(node, fx, fy, fz)
    elseif spd > 0.3 then
      want = local_yaw(node, bvx, bvy, bvz)
    end
    local before = face_yaw
    if want then
      face_yaw = face_yaw + wrap(want - face_yaw) * (1 - math.exp(-params.turn * dt))
    end
    yaw_rate = yaw_rate + (wrap(face_yaw - before) / math.max(dt, 1e-4) - yaw_rate) * math.min(1, dt * 10)
  end

  if airborne then air_t = air_t + dt else air_t = 0.0 end
  -- In the air for real: a jump, or long enough off the ground that it wasn't
  -- a kerb. Coming down from that is a landing.
  if jumped or (airborne and not swimming and air_t > 0.15) then flying = true end
  local landed = flying and not airborne
  if landed or swimming then flying = false end
  if landed then
    -- The knees take the landing: a dip of the whole model, deeper for a
    -- harder landing, springing back. The land clip does the same while you
    -- stand; this is what shows it while a gait owns the legs.
    land_dip = math.min(0.12, math.max(0.0, impact) * 0.012 + 0.03)
  end
  land_dip = land_dip * math.exp(-9 * dt)
  animate(node, dt, spd, not airborne, jumped, swimming, landed)
  if anim then
    pose(node, dt, vec3(ux, uy, uz), spd, not airborne and not swimming,
      (not (airborne or jumped or swimming or flying)) and (1 - gait_amt) or 0.0)
  end

  if model then
    model.yaw = face_yaw
    if model_y then model.y = model_y - land_dip * gait_amt end
  end
end
