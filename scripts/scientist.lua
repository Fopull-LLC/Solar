-- SCIENTIST — one of the Research Lab's staff at their station
-- (prefabs/LabScientist, spawned by lab.lua). The crew's own body rig in a
-- lab coat (tools/gen_labwear.py), the crew's own heads and hair
-- (scripts/face.lua, crew_faces.lua: the face is made from the scientist's
-- name like a crew member's), standing at a bench with their hands at the
-- work:
--
--   * the idle clip breathes under it; both hands are placed by IK on the
--     station's "Hands" point and move about it in small working loops (a
--     sample turned over, a focus knob, a pipette), never in step;
--   * the head drifts between the work and a glance up; face.lua turns the
--     head and eyes to the camera when it comes near (so they look at you
--     when you walk up);
--   * while lab_talk.lua has them talking, face.lua's jaw and lip channels
--     carry a talking rhythm (lab_talk.visemes).
--
-- FRAMES: the root is parented to the planet (body-relative, never moves);
-- the hands' point is the interior's marker, placed through the lab's frame
-- each frame against the planet's drawn position (lateUpdate, drawn poses).

defaults = {
  --@range 0 0.2 --@units m
  work = 0.045,        -- how far the hands move about their point
  --@range 10 60 --@units m
  near = 22.0,         -- the IK runs while the camera is this near
}

idx = nil
staff = nil
faceSign = 1             -- the model looks along its root's +Z
local F, hands_m, look_m = nil, nil, nil
local model, anim, face_s = nil, nil, nil
local seed = 0

local function valid(n) return n ~= nil and n.valid ~= false end

local function find_parts(node)
  for _, c in ipairs(node:children() or {}) do
    if c.name == "LabModel" then
      model = c
      for _, k in ipairs(c:children() or {}) do
        if k.name == "Face" then face_s = k.getScript and k:getScript("face") or nil end
      end
    end
  end
  anim = model and model.animator and model:animator() or nil
end

function bind(i, st, frame, hands, look)
  idx, staff, F, hands_m, look_m = i, st, frame, hands, look
  seed = (st and st.seed) or i
end

local look_set = false
local function set_look(node)
  if look_set or not staff then return end
  -- (the Face node's script can start after ours: ask again until it has)
  if not face_s then find_parts(node) end
  if not face_s then return end
  local cf = findScript and findScript("crew_faces")
  if cf and cf.lookFor and face_s.setLook then
    local l = cf.lookFor(staff.seed or 1, 9000 + (idx or 0), staff.name)
    face_s.setLook(l)
    look_set = true
  end
end

function start(node)
  find_parts(node)
end

local function to_world(lx, ly, lz)
  local root = nil
  local lab = findScript and findScript("lab")
  root = lab and lab.ROOT
  if not (valid(root) and F) then return nil end
  local pw = root.parent and root.parent.worldPos
  if not pw then return nil end
  return vec3(pw.x + F.o.x + F.ex.x * lx + F.ey.x * ly + F.ez.x * lz,
              pw.y + F.o.y + F.ex.y * lx + F.ey.y * ly + F.ez.y * lz,
              pw.z + F.o.z + F.ex.z * lx + F.ey.z * ly + F.ez.z * lz)
end

function lateUpdate(node, dt)
  if not (model and anim) then find_parts(node) end
  set_look(node)
  if not (anim and hands_m and valid(hands_m)) then return end
  if not (camera and camera.worldToScreen) then return end
  local wp = node.worldPos
  local ok, _, _, depth = pcall(camera.worldToScreen, wp.x, wp.y, wp.z)
  if ok and depth and depth > (params.near or 22) then return end
  local t = (time or 0) + seed * 3.7
  local h = to_world(hands_m.x, hands_m.y, hands_m.z)
  if not h then return end
  local o = node.worldPos
  local r = node:toWorld(vec3(1, 0, 0))
  local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
  local f = node:toWorld(vec3(0, 0, faceSign))
  local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
  local u = node:toWorld(vec3(0, 1, 0))
  local ux, uy, uz = u.x - o.x, u.y - o.y, u.z - o.z
  local w = params.work or 0.045
  for _, side in ipairs({ { "Left", 1, 0.0 }, { "Right", -1, 1.9 } }) do
    local nm, sg, ph = side[1], side[2], side[3]
    local a = t * (0.9 + 0.13 * sg) + ph
    local dx = math.sin(a) * w * 0.8 + math.sin(a * 0.37 + ph) * w * 0.4
    local dz = math.cos(a * 1.3) * w * 0.5
    local dy = math.max(0, math.sin(a * 0.7 + ph)) * w * 0.6
    -- the model's left is its root's +x when it faces +z
    local s = sg * faceSign * 0.16
    local tx = h.x + rx * (s + dx) + fx * dz + ux * dy
    local ty = h.y + ry * (s + dx) + fy * dz + uy * dy
    local tz = h.z + rz * (s + dx) + fz * dz + uz * dy
    -- the elbows out and back, a little down
    local px = o.x + rx * sg * faceSign * 0.55 - fx * 0.35 - ux * 0.1
    local py = o.y + ry * sg * faceSign * 0.55 - fy * 0.35 - uy * 0.1
    local pz = o.z + rz * sg * faceSign * 0.55 - fz * 0.35 - uz * 0.1
    pcall(anim.reach, anim, "Hand." .. nm, vec3(tx, ty, tz), { pole = vec3(px, py, pz) })
  end
  -- the head: down at the work, now and then a glance up and across
  if look_m and valid(look_m) then
    local lk = to_world(look_m.x, look_m.y, look_m.z)
    if lk then
      local g = math.max(0, math.sin(t * 0.21) - 0.75) * 4
      local gx = lk.x + ux * g * 0.5 + rx * math.sin(t * 0.13) * 0.3
      local gy = lk.y + uy * g * 0.5 + ry * math.sin(t * 0.13) * 0.3
      local gz = lk.z + uz * g * 0.5 + rz * math.sin(t * 0.13) * 0.3
      pcall(anim.lookAt, anim, { "Head" }, vec3(gx, gy, gz), { limit = 25, weight = 0.55 })
    end
  end
end
