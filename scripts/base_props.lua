-- BASE PROPS — the loose things lying round the base, so the gravity gun
-- always has something to play with.
--
-- Playtest 2026-10-24: "I can't hardly find anything to use it on". The base
-- was buildings and pads and nothing loose. Now there are cargo cans and
-- crates stacked in front of the Commerce Depot (prefabs/PropCan, PropCrate:
-- one-part assemblies, so a grab torques them and the strain gauge reads
-- their mass) and traffic cones on the launch pad's corners (PropCone, light
-- enough to fling). They are laid out in the base's own frame
-- (base_facilities frameOf / dirAt: layout metres east and north of the
-- centre), dropped onto the real ground, once per session, as soon as the
-- base is sited and the home world is in the scene. Where they end up after
-- a session of throwing is not saved: the yard is tidied every load.
--
-- Rides the Astronaut (scenes/system.ron) beside tool_belt.

defaults = {
  --- 0 lays out nothing.
  --@range 0 1
  enabled = 1,
}

-- Layout positions: (u east, v north) in the base frame, the prefab, and a
-- yaw. The depot stands at (-50, 12) facing south with an 18 m deep lot, so
-- its front edge is at v = 3; the pad is a 42 × 50 m lot at (0, 125).
local LAYOUT = {
  { -56.0, -1.5, "PropCan", 0.3 }, { -54.6, -1.3, "PropCan", 1.1 }, { -55.3, -0.2, "PropCan", 2.0 },
  { -46.0, -2.0, "PropCrate", 0.2 }, { -44.6, -1.4, "PropCrate", 1.3 }, { -45.4, -1.7, "PropCan", 0.9 },
  { -36.5, -3.0, "PropCan", 2.4 },
  { -17.0, 104.0, "PropCone", 0 }, { 17.0, 104.0, "PropCone", 0 }, { -17.0, 146.0, "PropCone", 0 }, { 17.0, 146.0, "PropCone", 0 },
  { 24.0, 110.0, "PropCrate", 0.6 },
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

placed = 0          -- props standing (probes read it)
local todo = nil    -- the layout still to place this session
local next_t = 0
local body_name = nil

-- The base frame from the save (what base_facilities.saved_frame reads).
local function base_frame()
  local bf = ref("base_facilities")
  if not (bf and bf.sited and bf.frameOf and bf.dirAt) then return nil end
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (type(name) == "string" and bx and by and bz) then return nil end
  local R = save.get("base.r") or len(bx, by, bz)
  return bf.frameOf({ x = bx, y = by, z = bz }, save.get("base.heading") or 0, R), name, R, bf
end

-- Lay one prop: the ground under its layout point, then the body on it.
local function place(item, Fr, body, R, bf)
  local d = bf.dirAt(Fr, item[1], item[2])
  local top = R + 60.0
  local h = raycast(body.x + d.x * top, body.y + d.y * top, body.z + d.z * top, -d.x, -d.y, -d.z, 120.0)
  if not h then return false end
  local lift = item[3] == "PropCone" and 0.42 or 0.45
  spawn(item[3], vec3(h.x + d.x * lift, h.y + d.y * lift, h.z + d.z * lift), function(n)
    -- stood up on the ground, turned a little each
    local fx, fy, fz = 1 - d.x * d.x, -d.x * d.y, -d.x * d.z
    local c, s = math.cos(item[4] or 0), math.sin(item[4] or 0)
    -- rotate the tangent about d by the yaw
    local tx, ty, tz = d.y * fz - d.z * fy, d.z * fx - d.x * fz, d.x * fy - d.y * fx
    fx, fy, fz = fx * c + tx * s, fy * c + ty * s, fz * c + tz * s
    if n.setUp then n:setUp(vec3(d.x, d.y, d.z), vec3(fx, fy, fz)) end
    if assembly and assembly.rebuild then assembly.rebuild(n) end
    placed = placed + 1
  end)
  return true
end

function update(node, dt)
  if params.enabled <= 0 or not spawn then return end
  if time < next_t then return end
  next_t = time + 1.0
  local Fr, name, R, bf = base_frame()
  if not Fr then return end
  if body_name ~= name then body_name, todo = name, nil end
  local body = space.body(name)
  if not body then return end
  -- Only once the crew is at the base (the ground there is resident).
  if len(node.x - (body.x + Fr.c.x * R), node.y - (body.y + Fr.c.y * R), node.z - (body.z + Fr.c.z * R)) > 600 then return end
  if todo == nil then
    todo = {}
    for i, it in ipairs(LAYOUT) do todo[i] = it end
  end
  if #todo == 0 then return end
  -- a few a second, so a load is never a hitch
  for _ = 1, 3 do
    local it = table.remove(todo, 1)
    if not it then break end
    if not place(it, Fr, body, R, bf) then
      -- no ground yet under it: back of the queue, try later (a minute's worth)
      it.tries = (it.tries or 0) + 1
      if it.tries < 60 then todo[#todo + 1] = it end
      break
    end
  end
end
