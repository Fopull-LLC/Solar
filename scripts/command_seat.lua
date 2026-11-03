-- COMMAND SEAT — the rider's pose in an open seat (prefabs/PartSeat), and
-- astride the Moto Saddle (prefabs/PartSaddle): the pose is the params.
--
-- A pod swallows its crew: the astronaut is hidden while they fly it. An open
-- seat doesn't — the rider stays in view, sitting. The vessel already parks the
-- crew at its command part every physics tick (vessel_controller's seated
-- passenger); this script, on the seat part, turns that into SITTING, once per
-- frame in the camera pass so it matches what is drawn:
--
--   * the rider sits where the seat is drawn, facing its +X (a rover's front),
--     upright along the seat's +Y however the craft is tipped;
--   * the legs fold onto the footrest and the hands go to the armrest and the
--     stick (two-bone IK, anim:reach), so the clips' standing idle reads as a
--     seated one without a sitting clip.
--
-- Nothing happens anywhere else: in the builder the seat has no vessel above
-- it, and in flight it acts only while the craft is crewed FROM this seat (the
-- vessel publishes podSeat and the crew position's offset, podLX/Y/Z: the
-- station they boarded, which on a craft with a pod as well is not always the
-- command part — vessel_controller `setStation`).
--
-- The numbers are the astronaut rig's (measured on foot under 0.117: hip
-- joints 0.04 m below the capsule origin, knees 0.40 m below them, ankles 0.48
-- m below the knees) against the seat's own geometry (tools/gen_seat.py:
-- cushion top 0.16 m below the seat centre, footrest 0.56 m below, 0.38 out).
--
-- THE MOTO SADDLE (tools/gen_auto_parts.py moto_saddle writes its params):
-- the rider sits up on the cushion's dip (sit_up, sit_forward), leans
-- forward over the tank (lean_fwd, about the hips), knees out (knee_out) and
-- feet on the pegs, and with `grips` on, the hands go to the bar grips of the
-- craft's fork (its ForkSteer node, the point grip_x/y/z in that node's
-- frame, so they turn with the steering); with no fork, the fixed reach
-- (hand_out/up/side). Everything follows the part, so the bike's lean (A/D)
-- tips the rider with it.

defaults = {
  -- the model's facing in its capsule's frame (rad): the rig faces +Z of its
  -- node, so π turns it to face where the node's −Z (the seat's +X) points
  model_yaw = 3.14159265,
  foot_out = 0.42,     -- footrest: forward of the seat centre (m)
  foot_down = 0.55,    -- … and below it
  foot_side = 0.12,
  hand_out = 0.12,     -- armrests / stick: forward of the centre
  hand_up = 0.0,
  hand_side = 0.26,
  -- The EVA suit's backpack is 0.23 m deep: the rider sits forward on the
  -- cushion by about that, so the PLSS rests against the backrest instead
  -- of passing through it (tools/gen_suit.py).
  sit_forward = 0.20,
  sit_up = 0.0,        -- the capsule origin above the part's centre (m)
  lean_fwd = 0.0,      -- the body pitched forward about the hips (rad)
  knee_out = 0.0,      -- the knees' pole out to the side (m; 0: straight ahead)
  hand_lift = 0.1,     -- the right hand raised onto the stick
  grips = 0,           -- 1: hands on a fork's grips when the craft has one
  grip_x = -0.0835,    -- …the grip in the fork's ForkSteer frame (±z)
  grip_y = 0.303,
  grip_z = 0.3125,
}

local astro, model, anim
local vessel = nil

local function find_rider()
  if not (astro and astro.valid) then
    astro = find("Astronaut")
    model, anim = nil, nil
  end
  if astro and not (model and model.valid) then
    for _, c in ipairs(astro:children()) do
      if c.name == "AstroModel" then model = c end
    end
    anim = nil
  end
  if model and not anim then anim = model:animator() end
  return astro
end

-- Is the craft above us being flown with its crew in THIS seat?
local function vessel_of(node)
  local p = node.parent
  if not (p and p.valid) then return nil end
  if not (vessel and vessel.valid and vessel.node and vessel.node.id == p.id) then
    vessel = p.getScript and p:getScript("vessel_controller") or nil
  end
  return vessel
end
local function seated_here(node)
  local v = vessel_of(node)
  if not (v and v.crewAboard and v.podSeat) then return false end
  local dx, dy, dz = (node.x or 0) - (v.podLX or 0), (node.y or 0) - (v.podLY or 0), (node.z or 0) - (v.podLZ or 0)
  return dx * dx + dy * dy + dz * dz < 0.01
end

-- The craft's steering fork (its ForkSteer node), nearest this part.
local steerNode, steerOf, steerT = nil, nil, -1
local function find_named(n, name, depth)
  if n.name == name then return n end
  if depth >= 4 then return nil end
  for _, c in ipairs(n:children()) do
    local f = find_named(c, name, depth + 1)
    if f then return f end
  end
  return nil
end
local function fork_steer(node)
  local p = node.parent
  if not (p and p.valid) then return nil end
  if steerNode and steerNode.valid and steerOf == p.id then return steerNode end
  -- (looked for again at most once a second: a craft without one)
  if steerOf == p.id and time - steerT < 1 then return nil end
  steerOf, steerT, steerNode = p.id, time, nil
  local P, best = node.worldPos, nil
  for _, c in ipairs(p:children()) do
    if c.id ~= node.id then
      local f = find_named(c, "ForkSteer", 0)
      if f then
        local q = f.worldPos
        local d = (q.x - P.x) ^ 2 + (q.y - P.y) ^ 2 + (q.z - P.z) ^ 2
        if d < 9 and (not best or d < best) then steerNode, best = f, d end
      end
    end
  end
  return steerNode
end

-- The rider's capsule, the craft's hull and its own live tyres pass through each other
-- while they ride (physics.ignorePair). The crew is parked at the seat as a
-- kinematic body, 2 m tall: low on a saddle its feet reach the tyres, and a
-- kinematic body in a tyre shoves it every tick (a parked bike drove itself
-- off at 20 m/s and fell). Lifted when they get off, so on foot they meet
-- the wheels again.
local ghosted = {}
local function ghost_tyres(a, v)
  if not (physics and physics.ignorePair) then return end
  local seen = {}
  local vn = v and v.node
  if vn and vn.valid then
    -- (and the hull itself: low in a saddle the capsule is deep in the frame)
    seen[vn.id] = true
    if not ghosted[vn.id] then physics.ignorePair(a, vn); ghosted[vn.id] = vn end
  end
  for _, w in ipairs((v and v.R2 and v.R2.wheels) or {}) do
    local t = w.tyre
    if t and t.valid then
      seen[t.id] = true
      if not ghosted[t.id] then physics.ignorePair(a, t); ghosted[t.id] = t end
    end
  end
  for id, t in pairs(ghosted) do
    if not seen[id] then ghosted[id] = nil end
  end
end
local function unghost(a)
  if not next(ghosted) then return end
  for id, t in pairs(ghosted) do
    if a and a.valid and t.valid and physics and physics.ignorePair then physics.ignorePair(a, t, 0) end
    ghosted[id] = nil
  end
end

-- A SECOND RIDER (crew slice 2): a crew member seated here who is not the
-- one you control is a CrewDoll (crew.lua). It gets the same pose as the
-- Astronaut would: → the doll node, its model and animator, or nil.
local crewlib, doll_t = nil, -10
local dollNode, dollModel, dollAnim = nil, nil, nil
local function doll_here(node)
  local v = vessel_of(node)
  if not (v and v.node and v.uidOfNode) then return nil end
  if not (crewlib and crewlib.valid ~= false) and time - doll_t > 1 then
    doll_t = time
    crewlib = findScript("crew")
  end
  if not (crewlib and crewlib.dollAt) then return nil end
  local uid = v.uidOfNode(node)
  local d = uid and crewlib.dollAt(v.node.id, uid)
  if not d then return nil end
  if dollNode ~= d then
    dollNode, dollModel, dollAnim = d, nil, nil
    for _, c in ipairs(d:children()) do if c.name == "AstroModel" then dollModel = c end end
    dollAnim = dollModel and dollModel:animator() or nil
  end
  return d
end

-- THE HEAD LOOKS WHERE YOU LOOK (playtest 2026-11: "the astronaut turns to
-- look where my camera is looking, but when riding a vehicle … they don't").
-- On foot planet_walker `look` turns the head to the view; seated, this does,
-- for the rider you control: the camera's direction (planet_camera fwd_x…),
-- this frame, as a yaw and a pitch in THE SEAT'S frame (so the bike's lean and
-- the craft's turning carry the look with them), smoothed there (rule 7:
-- frame-rate independent, never a world point), the pitch halved and capped
-- as on foot (a chase camera looks down at the rider), the yaw held inside
-- the neck's reach and let go as the view swings round behind. The eyes follow
-- through face.lua's `gaze` hook, asked for this frame's point when the face
-- poses (rule 1). Snaps on a new seat or rider.
local LOOK_YAW, LOOK_UP, LOOK_DOWN = math.rad(75), 0.45, -0.35
local LOOK_TWIST = 0.45            -- rad: the most the chest turns with the look
local HIP_Z = 0.01622              -- the Hip joint from Back's origin (planet_walker HIP_Y, HIP_Z)
local look = { on = false, yaw = 0, pitch = 0, w = 0, t = -1, seat = nil }
local look_face, look_face_of = nil, nil
local look_anim, look_node = nil, nil
local function smooth01(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
-- the look as a world direction, from the seat's frame as it is drawn now
local function look_world(node)
  local fwd, up, f2 = node:worldRight(), node:worldUp(), node:worldForward()
  local cp = math.cos(look.pitch)
  local a, b, c = cp * math.cos(look.yaw), -cp * math.sin(look.yaw), math.sin(look.pitch)
  -- (right = −forward: a + yaw turns to the rider's right)
  return vec3(fwd.x * a + f2.x * b + up.x * c, fwd.y * a + f2.y * b + up.y * c, fwd.z * a + f2.z * b + up.z * c)
end
-- face.lua's gaze hook: this frame's point and weight
local function gaze()
  if not (look.on and look_node and look_node.valid and look_anim) or (time or 0) - look.t > 0.1 then return nil end
  if look.w < 0.02 then return nil end
  local h = look_anim:boneWorld("Head")
  if not h then return nil end
  local d = look_world(look_node)
  return h.x + d.x * 10, h.y + d.y * 10, h.z + d.z * 10, 0.9 * look.w
end
local function face_of(model)
  if not (model and model.valid) then return nil end
  if look_face_of == model.id and look_face then return look_face end
  look_face_of, look_face = model.id, nil
  for _, k in ipairs(model:children() or {}) do
    if k.name == "Face" then look_face = k.getScript and k:getScript("face") or nil end
  end
  return look_face
end
local function look_off()
  if look_face and look_face.gaze == gaze then look_face.gaze = nil end
  look.on = false
end
local look_pc = nil
local function head_look(node, dt, model, anim)
  if not (look_pc and look_pc.valid ~= false) then look_pc = findScript and findScript("planet_camera") or nil end
  local pc = look_pc
  if not (pc and pc.fwd_x) then look_off(); return end
  local fwd, up, f2 = node:worldRight(), node:worldUp(), node:worldForward()
  local fx, fy, fz = pc.fwd_x, pc.fwd_y, pc.fwd_z
  -- (a probe's stand-in for the view: a function giving this frame's world
  -- direction, so a camera can film the rider from the side)
  if lookFrom then
    local ok, x, y, z = pcall(lookFrom)
    if ok and x then fx, fy, fz = x, y, z end
  end
  local a = fx * fwd.x + fy * fwd.y + fz * fwd.z
  local r = -(fx * f2.x + fy * f2.y + fz * f2.z)
  local u = fx * up.x + fy * up.y + fz * up.z
  local yaw = math.atan2(r, a)
  local pitch = math.max(LOOK_DOWN, math.min(LOOK_UP, math.asin(math.max(-1, math.min(1, u))) * 0.5))
  local want = 1 - smooth01(math.rad(100), math.rad(130), math.abs(yaw))
  yaw = math.max(-LOOK_YAW, math.min(LOOK_YAW, yaw))
  local snap = not look.on or look.seat ~= node.id or (time or 0) - look.t > 0.5
  if snap then
    look.yaw, look.pitch, look.w = yaw, pitch, want
  else
    local k = 1 - math.exp(-8 * dt)
    look.yaw = look.yaw + wrap(yaw - look.yaw) * k
    look.pitch = look.pitch + (pitch - look.pitch) * k
    look.w = look.w + (want - look.w) * (1 - math.exp(-5 * dt))
  end
  look.on, look.seat, look.t = true, node.id, time or 0
  look_anim, look_node = anim, node
  local fs = face_of(model)
  if fs and fs.gaze ~= gaze then fs.gaze = gaze end
  -- THE CHEST TAKES A SHARE (as planet_walker `lean` does on foot): the
  -- helmet rides the Back bone, a hard suit's torso, so a head turning inside
  -- it shows nothing; the rider twists at the waist toward the look, the
  -- legs turned back so the feet stay on the pegs (the reaches below the
  -- bone writes put them there anyway). Walker's convention: + y turns left.
  local y = -math.max(-LOOK_TWIST, math.min(LOOK_TWIST, look.yaw * 0.4)) * look.w
  if math.abs(y) > 1e-4 then
    anim:addBoneRot("Back", -y, 0, 0)
    anim:addBoneRot("Hip", y, 0, 0)
    anim:addBonePos("Back", vec3(-2 * HIP_Z * math.sin(y), 0, 0))
  end
  local h = anim:boneWorld("Head")
  look.head, look.twist = h ~= nil, -y
  if h and look.w > 0.01 then
    local d = look_world(node)
    anim:lookAt({ "Head" }, vec3(h.x + d.x * 10, h.y + d.y * 10, h.z + d.z * 10), { limit = 75, weight = 0.9 * look.w })
  end
end

-- Published for probes: is the rider being seated by this script right now?
riding = false
-- …and the head's look in the seat's frame: { yaw, pitch, w } (rad; + right, + up)
lookState = nil
-- (probes: a function → x, y, z, the direction the head follows instead of the view's)
lookFrom = nil
-- …and is it a doll (a crew member you are not controlling)?
ridingDoll = false
-- …and where the hands went: "grips" (a fork's bars) or "reach"
hands = nil

function lateUpdate(node, dt)
  riding = false
  ridingDoll = false
  hands = nil
  lookState = nil
  local a, rmodel, ranim
  if seated_here(node) then
    a = find_rider()
    if not a then return end
    rmodel, ranim = model, anim
    ghost_tyres(a, vessel)
  else
    if next(ghosted) then unghost(astro) end
    if look.on and look.seat == node.id then look_off() end
    a = doll_here(node)
    if not a then return end
    rmodel, ranim = dollModel, dollAnim
    ridingDoll = true
  end
  riding = true
  local model, anim = rmodel, ranim
  -- In view: whatever hid the crew on the way in (the launch handoff parks
  -- them hidden, a transfer hides them for a pod) doesn't know this is a seat.
  if not a.visible then a.visible = true end
  if model and model.valid and not model.visible then model.visible = true end
  local P = node.worldPos
  local up = node:worldUp()
  local fwd = node:worldRight()          -- the seat faces its +X
  local f2 = node:worldForward()
  local right = vec3(-f2.x, -f2.y, -f2.z) -- +Z: the pilot's right
  -- sit where the seat is drawn (forward of its centre by the backpack),
  -- upright in it, facing out over the footrest
  local sf, su = params.sit_forward or 0, params.sit_up or 0
  a.x, a.y, a.z = P.x + fwd.x * sf + up.x * su, P.y + fwd.y * sf + up.y * su, P.z + fwd.z * sf + up.z * su
  local lf = params.lean_fwd or 0
  if lf ~= 0 then
    -- leaning forward over the tank: the body pitched about the hips
    local c, s = math.cos(lf), math.sin(lf)
    a:setUp(vec3(up.x * c + fwd.x * s, up.y * c + fwd.y * s, up.z * c + fwd.z * s),
            vec3(fwd.x * c - up.x * s, fwd.y * c - up.y * s, fwd.z * c - up.z * s))
  else
    a:setUp(up, fwd)
  end
  if model and model.valid then
    model.yaw, model.pitch, model.roll = params.model_yaw, 0, 0
  end
  if not anim then return end
  local function at(o, u, s)
    return vec3(P.x + fwd.x * o + up.x * u + right.x * s, P.y + fwd.y * o + up.y * u + right.y * s,
                P.z + fwd.z * o + up.z * u + right.z * s)
  end
  -- the bars: a fork's two grips, sorted onto the rider's left and right
  local grip = nil
  if (params.grips or 0) > 0 then
    local S = fork_steer(node)
    if S then
      local gx, gy, gz = params.grip_x, params.grip_y, params.grip_z
      local g1, g2 = S:toWorld(vec3(gx, gy, gz)), S:toWorld(vec3(gx, gy, -gz))
      local s1 = (g1.x - P.x) * right.x + (g1.y - P.y) * right.y + (g1.z - P.z) * right.z
      grip = s1 >= 0 and { [1] = g1, [-1] = g2 } or { [1] = g2, [-1] = g1 }
    end
  end
  hands = grip and "grips" or "reach"
  local ko = params.knee_out or 0
  for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
    local nm, sg = side[1], side[2]
    anim:reach("Foot." .. nm, at(params.foot_out, -params.foot_down, sg * params.foot_side),
      { pole = at(1.2, 0.0, sg * (params.foot_side + ko)) })
    local h = grip and grip[sg] or at(params.hand_out, params.hand_up + (sg > 0 and (params.hand_lift or 0) or 0.0), sg * params.hand_side)
    anim:reach("Hand." .. nm, h, { pole = at(-0.3, -0.1, sg * 0.6) })
  end
  -- the head (and eyes) to where you look: the rider you control only
  if not ridingDoll then
    head_look(node, dt, model, anim)
    lookState = { yaw = look.yaw, pitch = look.pitch, w = look.w, head = look.head, twist = look.twist }
  end
end
