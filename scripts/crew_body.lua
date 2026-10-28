-- CREW BODY / CREW DOLL — the crew members you are not controlling
-- (docs/crew-and-items.md §3.4, §4.1). One script, two prefabs:
--
--   prefabs/CrewBody   a member ON FOOT in range: the Astronaut's capsule and
--                      suit, KINEMATIC. It stands where it was left, held in
--                      its planet's frame every physics tick (the planet
--                      moves 1.5–6 m a tick: the position lives body-relative
--                      in the crew record, never as a world point), upright
--                      along the local vertical, breathing the idle clip.
--                      In space beside a craft it rides that craft's part
--                      frame instead (the record's `anchor`).
--   prefabs/CrewDoll   a member SEATED in a craft: no body, no collider.
--                      Placed every lateUpdate at its seat from the part's
--                      pose this frame (crew.dollPose), legs folded onto the
--                      footrest by IK. In an open seat command_seat.lua poses
--                      it (the same pose the Astronaut gets there).
--
-- crew.lua spawns and despawns both, and binds them: bind(id) for a body,
-- bindDoll(id) for a doll. They take no input.

defaults = {
  half_h = 1.0,        -- the capsule's half height (planet_walker's 2 m suit)
  model_yaw = 3.14159265,
  down_roll = 0.35,    -- downed: rad rolled from flat on the back onto a side
  down_lift = 0.38,    -- downed: the capsule's centre this far off the ground (the pack under them)
  foot_out = 0.42,     -- a seated doll's feet: forward of the hips…
  foot_down = 0.55,    -- …and below them
  foot_side = 0.12,
  hand_out = 0.18,
  hand_side = 0.26,
}

local function P(k) return (params and params[k]) or defaults[k] end

memberId = nil
doll = false
local model, anim = nil, nil
local settled = false
local vel = { x = 0, y = 0, z = 0 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function find_model(node)
  if model and model.valid then return model end
  for _, c in ipairs(node:children()) do
    if c.name == "AstroModel" then model = c end
  end
  anim = model and model.animator and model:animator() or nil
  return model
end

function bind(id)
  memberId, doll = id, false
  settled = false
end

function bindDoll(id)
  memberId, doll = id, true
end

-- The body's velocity this tick (0 standing on a planet: the rails frame;
-- a craft part's velocity when anchored beside one): the Astronaut takes it
-- over on a switch.
function velocityNow() return vel.x, vel.y, vel.z end

function start(node)
  find_model(node)
end

-- Feet on the ground: a ray down the local vertical from a little above the
-- record's point; the record moves to stand on what it finds.
local function settle(node, c, r, b)
  if settled or not raycast then settled = true return end
  settled = true
  local x, y, z = b.x + (r.x or 0), b.y + (r.y or 0), b.z + (r.z or 0)
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-6 then return end
  ux, uy, uz = ux / l, uy / l, uz / l
  local ok, h = pcall(raycast, x + ux * 1.5, y + uy * 1.5, z + uz * 1.5, -ux, -uy, -uz, 30.0, node)
  if ok and h and h.x and h.distance and h.distance < 29 then
    local hh = P("half_h") + 0.02
    c.patch(memberId, { x = h.x + ux * hh - b.x, y = h.y + uy * hh - b.y, z = h.z + uz * hh - b.z })
  end
end

-- Who am I? (crew.lua spawned this node; its spawn callback runs before
-- this script does, so the binding is asked for here.)
local function bound(node)
  if memberId then return true end
  local c = ref("crew")
  if not (c and c.memberOfNode) then return false end
  local id, kind = c.memberOfNode(node)
  if not id then return false end
  memberId, doll = id, kind == "doll"
  return true
end

function fixedUpdate(node, dt)
  if not bound(node) then return end
  if doll then return end
  local c = ref("crew")
  local r = c and c.get and c.get(memberId)
  if not (r and r.status == "afoot") then return end
  -- beside a craft in space: ride its part frame
  local an = r.anchor
  if type(an) == "table" and an.vid then
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid ~= false and v.node.id == an.vid and v.partPointNow then
        local x, y, z, vx, vy, vz = v.partPointNow(an.uid, an.x, an.y, an.z)
        if x then
          node.x, node.y, node.z = x, y, z
          node.vx, node.vy, node.vz = vx, vy, vz
          vel.x, vel.y, vel.z = vx, vy, vz
          return
        end
      end
    end
  end
  local b = r.body and space.body(r.body)
  if not b then return end
  settle(node, c, r, b)
  r = c.get(memberId)
  local x, y, z = b.x + (r.x or 0), b.y + (r.y or 0), b.z + (r.z or 0)
  -- at rest on the ground: velocities are in the planet's rails frame (the
  -- engine carries everything near it), so standing still is 0
  vel.x, vel.y, vel.z = 0, 0, 0
  node.x, node.y, node.z = x, y, z
  node.vx, node.vy, node.vz = 0, 0, 0
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l > 1e-6 and r.downed then
    -- DOWN (crew.lua): lying on their back where they fell, the capsule laid
    -- along the ground, the head the way they faced
    ux, uy, uz = ux / l, uy / l, uz / l
    local f = type(r.face) == "table" and r.face or nil
    local fx, fy, fz = 1, 0, 0
    if f then fx, fy, fz = f.x, f.y, f.z end
    local d = fx * ux + fy * uy + fz * uz
    fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 1e-3 then
      fx, fy, fz = uy, -ux, 0
      if math.abs(uz) > 0.9 then fx, fy, fz = 0, uz, -uy end
      fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    -- On the back, rolled a little onto one side: the suit's front (the
    -- model faces the node's +Z) turned to the sky. Forward = the planet's up
    -- laid them face-down, which reads as dead. The side follows the member,
    -- so two downed side by side don't mirror each other.
    local sx, sy, sz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local roll = ((tonumber(memberId) or 0) % 2 == 0 and 1 or -1) * P("down_roll")
    local c, s = math.cos(roll), math.sin(roll)
    local drop = P("half_h") - P("down_lift")
    node.x, node.y, node.z = x - ux * drop, y - uy * drop, z - uz * drop
    node:setUp(vec3(fx, fy, fz), vec3(-ux * c + sx * s, -uy * c + sy * s, -uz * c + sz * s))
    return
  end
  if l > 1e-6 then
    local f = r.face
    if type(f) == "table" and f.x then
      node:setUp(vec3(ux / l, uy / l, uz / l), vec3(f.x, f.y, f.z))
    else
      node:setUp(vec3(ux / l, uy / l, uz / l))
    end
  end
end

function lateUpdate(node, dt)
  if not bound(node) then return end
  if not doll then return end
  local c = ref("crew")
  local p = c and c.dollPose and c.dollPose(memberId)
  local m = find_model(node)
  if not p then
    if node.visible then node.visible = false end
    return
  end
  if p.open then
    -- command_seat.lua sits them in the seat, in view
    if not node.visible then node.visible = true end
    return
  end
  if node.visible ~= p.visible then node.visible = p.visible end
  if m and m.visible ~= p.visible then m.visible = p.visible end
  node.x, node.y, node.z = p.x, p.y, p.z
  node:setUp(vec3(p.ux, p.uy, p.uz), vec3(p.fx, p.fy, p.fz))
  if m then m.yaw, m.pitch, m.roll = P("model_yaw"), 0, 0 end
  if not (p.visible and anim) then return end
  -- seated: feet forward and down, hands on the knees
  local rx, ry, rz = p.fy * p.uz - p.fz * p.uy, p.fz * p.ux - p.fx * p.uz, p.fx * p.uy - p.fy * p.ux
  local function at(o, u, s)
    return vec3(p.x + p.fx * o + p.ux * u + rx * s, p.y + p.fy * o + p.uy * u + ry * s, p.z + p.fz * o + p.uz * u + rz * s)
  end
  for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
    local nm, sg = side[1], side[2]
    anim:reach("Foot." .. nm, at(P("foot_out"), -P("foot_down"), sg * P("foot_side")), { pole = at(1.2, 0.0, sg * P("foot_side")) })
    anim:reach("Hand." .. nm, at(P("hand_out"), -0.15, sg * P("hand_side")), { pole = at(-0.3, -0.1, sg * 0.6) })
  end
end
