-- COMMAND SEAT — the rider's pose in an open seat (prefabs/PartSeat).
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
local function seated_here(node)
  local p = node.parent
  if not (p and p.valid) then return false end
  if not (vessel and vessel.valid and vessel.node and vessel.node.id == p.id) then
    vessel = p.getScript and p:getScript("vessel_controller") or nil
  end
  local v = vessel
  if not (v and v.crewAboard and v.podSeat) then return false end
  local dx, dy, dz = (node.x or 0) - (v.podLX or 0), (node.y or 0) - (v.podLY or 0), (node.z or 0) - (v.podLZ or 0)
  return dx * dx + dy * dy + dz * dz < 0.01
end

-- Published for probes: is the rider being seated by this script right now?
riding = false

function lateUpdate(node, dt)
  riding = false
  if not seated_here(node) then return end
  local a = find_rider()
  if not a then return end
  riding = true
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
  local sf = params.sit_forward or 0
  a.x, a.y, a.z = P.x + fwd.x * sf, P.y + fwd.y * sf, P.z + fwd.z * sf
  a:setUp(up, fwd)
  if model and model.valid then
    model.yaw, model.pitch, model.roll = params.model_yaw, 0, 0
  end
  if not anim then return end
  local function at(o, u, s)
    return vec3(P.x + fwd.x * o + up.x * u + right.x * s, P.y + fwd.y * o + up.y * u + right.y * s,
                P.z + fwd.z * o + up.z * u + right.z * s)
  end
  for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
    local nm, sg = side[1], side[2]
    anim:reach("Foot." .. nm, at(params.foot_out, -params.foot_down, sg * params.foot_side),
      { pole = at(1.2, 0.0, sg * params.foot_side) })
    anim:reach("Hand." .. nm, at(params.hand_out, params.hand_up + (sg > 0 and 0.1 or 0.0), sg * params.hand_side),
      { pole = at(-0.3, -0.1, sg * 0.6) })
  end
end
