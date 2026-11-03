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
--   * the head drifts between the work and a glance up; when the crew comes
--     within a few metres (in front of them or to the side) the head turns to
--     the crew's head, smoothly and within a neck's reach, and the eyes follow
--     (face.lua's `gaze` hook); walk off and they go back to the work. While
--     lab_talk.lua has them talking they look at the camera (you);
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
  --@range 1 6 --@units m
  look_near = 3.0,     -- the crew this near: they look up at you (leave at +0.6 m)
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
  -- (out of the lab the model is switched off: lab.lua)
  if model and model.enabled == false then gz.init = false return end
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
  stance(node, t, o, rx, ry, rz, fx, fy, fz, ux, uy, uz)
  relax_hands()
  if holds then
    hold_board(node, t, o, rx, ry, rz, fx, fy, fz, ux, uy, uz)
    look_head(node, t, dt, rx, ry, rz, fx, fy, fz, ux, uy, uz)
    return
  end
  for _, side in ipairs({ { "Left", 1, 0.0 }, { "Right", -1, 1.9 } }) do
    local nm, sg, ph = side[1], side[2], side[3]
    local a = t * (0.9 + 0.13 * sg) + ph
    local dx = math.sin(a) * w * 0.8 + math.sin(a * 0.37 + ph) * w * 0.4
    local dz = math.cos(a * 1.3) * w * 0.5
    local dy = math.max(0, math.sin(a * 0.7 + ph)) * w * 0.6
    -- the model's left is its root's +x when it faces +z
    local s = sg * faceSign * 0.13
    local tx = h.x + rx * (s + dx) + fx * dz + ux * dy
    local ty = h.y + ry * (s + dx) + fy * dz + uy * dy
    local tz = h.z + rz * (s + dx) + fz * dz + uz * dy
    -- the elbows down by the sides and a little back, as a person working at
    -- a bench holds them (out and level read as a mannequin's)
    local px = o.x + rx * sg * faceSign * 0.30 - fx * 0.22 - ux * 0.55
    local py = o.y + ry * sg * faceSign * 0.30 - fy * 0.22 - uy * 0.55
    local pz = o.z + rz * sg * faceSign * 0.30 - fz * 0.22 - uz * 0.55
    pcall(anim.reach, anim, "Hand." .. nm, vec3(tx, ty, tz), { pole = vec3(px, py, pz) })
  end
  look_head(node, t, dt, rx, ry, rz, fx, fy, fz, ux, uy, uz)
end

-- ── the stance: knees soft, the weight shifting, a breath of sway ───────────
-- The root bone (Back) moves in the armature's space: x = 2·model x,
-- y = 2·model z, z = −2·model y (the rig's ½-scale, Z-up MaleArm; read from
-- models/lab/scientist.glb). Lowering it with the feet held planted by IK
-- bends the knees.
local feet = nil              -- the feet's planted points, kept in the root's frame
local function bone_w(name)
  local ok, p = pcall(model.bonePos, model, name)
  return ok and p or nil
end
function stance(node, t, o, rx, ry, rz, fx, fy, fz, ux, uy, uz)
  -- the feet, planted where the clip first put them (kept in the root's frame)
  if not feet then
    local l, r = bone_w("Foot.Left"), bone_w("Foot.Right")
    if not (l and r) then return end
    local function rel(p) return node:toLocal(p) end
    feet = { L = rel(l), R = rel(r) }
  end
  local sway = math.sin(t * 0.31) * 0.5 + math.sin(t * 0.13 + 1.1) * 0.5
  local drop = 0.016 + 0.003 * math.sin(t * 1.1)               -- soft knees, a breath
  local side = 0.016 * sway                                     -- the weight going over
  -- (in the model's own axes: side along +x, drop down -y)
  pcall(anim.addBonePos, anim, "Back", vec3(2 * side * faceSign, 0, 2 * drop))
  pcall(anim.addBoneRot, anim, "Back", 0, 0, -0.03 * sway)
  for _, k in ipairs({ { "Left", 1 }, { "Right", -1 } }) do
    local lp = feet[k[1] == "Left" and "L" or "R"]
    local wp = node:toWorld(lp)
    local pole = vec3(wp.x + fx * 1.0 + ux * 0.5 + rx * k[2] * 0.15, wp.y + fy * 1.0 + uy * 0.5 + ry * k[2] * 0.15,
                      wp.z + fz * 1.0 + uz * 0.5 + rz * k[2] * 0.15)
    pcall(anim.reach, anim, "Foot." .. k[1], wp, { pole = pole })
  end
end

-- ── the hands: fingers softly curled, as a hand at rest or at work is (the
-- rig's rest pose spreads them flat, which read as a glove blown up) ──────
CURL = -0.45                  -- radians at the knuckle (roll in the bones' frame)
function relax_hands()
  for _, sd in ipairs({ "Left", "Right" }) do
    pcall(anim.addBoneRot, anim, "Fingers1." .. sd, 0, 0, CURL * (holds and 1.3 or 1.0))
    pcall(anim.addBoneRot, anim, "Fingers2." .. sd, 0, 0, CURL * 0.8)
    pcall(anim.addBoneRot, anim, "Thumb1." .. sd, 0, 0, CURL * 0.35)
  end
end

-- ── holding a clipboard (lab.lua gives one to a scientist or two) ───────────
holds = false
board = nil                   -- the clipboard node (top level, placed each frame)
function hold_board(node, t, o, rx, ry, rz, fx, fy, fz, ux, uy, uz)
  -- the board at the chest, tipped up to the eyes, the left hand under it and
  -- the right with a pen on it
  local c = vec3(o.x + fx * 0.30 + ux * 0.26 + rx * faceSign * 0.04, o.y + fy * 0.30 + uy * 0.26 + ry * faceSign * 0.04,
                 o.z + fz * 0.30 + uz * 0.26 + rz * faceSign * 0.04)
  local bob = 0.006 * math.sin(t * 0.9)
  c = vec3(c.x + ux * bob, c.y + uy * bob, c.z + uz * bob)
  -- the board's normal: toward the face, tipped 40° up from the horizontal
  local tip = 0.75
  local nx, ny, nz = -fx * math.cos(tip) + ux * math.sin(tip), -fy * math.cos(tip) + uy * math.sin(tip),
    -fz * math.cos(tip) + uz * math.sin(tip)
  -- up the board (away from the body, tipped)
  local ax, ay, az = fx * math.sin(tip) + ux * math.cos(tip), fy * math.sin(tip) + uy * math.cos(tip),
    fz * math.sin(tip) + uz * math.cos(tip)
  if board and board.valid ~= false then
    board.x, board.y, board.z = c.x, c.y, c.z
    -- its +Y up the board (away from the body, tipped), its -Z the normal
    pcall(board.setUp, board, vec3(ax, ay, az), vec3(-nx, -ny, -nz))
  end
  -- (the model's left is +x·faceSign: the left hand holds the board's left
  -- edge from under it, the right writes on its right half. Swapped, the
  -- forearms crossed through the coat: playtest 2026-11-03)
  local lh = vec3(c.x + rx * faceSign * 0.10 - ax * 0.07 - nx * 0.035, c.y + ry * faceSign * 0.10 - ay * 0.07 - ny * 0.035,
                  c.z + rz * faceSign * 0.10 - az * 0.07 - nz * 0.035)
  local wr = 0.025 * math.sin(t * 2.3)
  local rh = vec3(c.x - rx * faceSign * (0.03 + wr) - ax * 0.03 + nx * 0.035, c.y - ry * faceSign * (0.03 + wr) - ay * 0.03 + ny * 0.035,
                  c.z - rz * faceSign * (0.03 + wr) - az * 0.03 + nz * 0.035)
  for _, k in ipairs({ { "Left", lh, 1 }, { "Right", rh, -1 } }) do
    local pole = vec3(o.x + rx * k[3] * faceSign * 0.35 - fx * 0.15 - ux * 0.5, o.y + ry * k[3] * faceSign * 0.35 - fy * 0.15 - uy * 0.5,
                      o.z + rz * k[3] * faceSign * 0.35 - fz * 0.15 - uz * 0.5)
    pcall(anim.reach, anim, "Hand." .. k[1], k[2], { pole = pole })
  end
end

-- ── where the head looks ─────────────────────────────────────────────────────
-- Every frame, from what is live now (drawn poses, docs/positions-and-frames):
-- the idle point (the work, a glance up; or the clipboard) and, when the crew
-- is near, the crew's head (the camera while they talk to you). The two are
-- blended as yaw and pitch in the scientist's own frame, clamped to a neck's
-- reach, and smoothed there (never as a world point); the engagement eases in
-- and out with hysteresis so it doesn't flicker at the edge.
NECK_YAW, NECK_UP, NECK_DOWN = 1.15, 0.35, 0.55     -- radians
gz = { eng = 0, yaw = 0, pitch = 0, init = false, on = false }
looking = false              -- (published, probes) engaged with the crew
local astro, astro_head = nil, nil
local function crew_head()
  if not valid(astro) then astro, astro_head = find and find("Astronaut") or nil, nil end
  if not valid(astro) then return nil end
  if not valid(astro_head) then
    for _, c in ipairs(astro:children() or {}) do
      if c.name == "AstroModel" then
        for _, k in ipairs(c:children() or {}) do if k.name == "Face" then astro_head = k end end
      end
    end
  end
  if valid(astro_head) then return astro_head.worldPos end
  return astro:toWorld(vec3(0, 0.62, 0))
end
local function talking_to_me()
  local lt = findScript and findScript("lab_talk")
  return lt and lt.isOpen and lt.isOpen() and lt.talkingTo and lt.talkingTo() == idx
end
-- This frame's world point to look at (or nil): the camera while talking, else
-- the crew's head.
local function target_now()
  if talking_to_me() then
    local pc = findScript and findScript("planet_camera")
    local n = pc and pc.node
    if valid(n) then return n.worldPos end
  end
  return crew_head()
end
local function head_now(node)
  local h = model and bone_w("Head")
  return h or node:toWorld(vec3(0, 0.72, 0))
end
local function yaw_pitch(dx, dy, dz, rx, ry, rz, fx, fy, fz, ux, uy, uz)
  local a = dx * rx + dy * ry + dz * rz
  local b = dx * fx + dy * fy + dz * fz
  local c = dx * ux + dy * uy + dz * uz
  return math.atan2(a, b), math.atan2(c, math.sqrt(a * a + b * b)), math.sqrt(a * a + b * b + c * c)
end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- (pure, tests) engaged next frame? d metres off, at yaw (rad), was engaged
function wantsLook(d, yaw, was, near)
  near = near or 3.0
  local ay = math.abs(yaw)
  if was then return d < near + 0.6 and ay < 2.85 end
  return d < near and ay < 2.65
end

-- face.lua asks this each frame it poses the eyes: this frame's point and how
-- much (nil: the face's own business).
local self_node = nil
local function gaze()
  if gz.eng < 0.02 or not valid(self_node) then return nil end
  local p = target_now()
  if not p then return nil end
  return p.x, p.y, p.z, gz.eng
end

function look_head(node, t, dt, rx, ry, rz, fx, fy, fz, ux, uy, uz)
  self_node = node
  if face_s and face_s.gaze ~= gaze then face_s.gaze = gaze end
  local h = head_now(node)
  -- the idle point: the clipboard, or the work and now and then a glance up
  local ip = nil
  local iw = 0.55
  if holds and board and board.valid ~= false then
    ip, iw = board.worldPos, 0.7
  elseif look_m and valid(look_m) then
    local lk = to_world(look_m.x, look_m.y, look_m.z)
    if lk then
      local g = math.max(0, math.sin(t * 0.21) - 0.75) * 4
      ip = vec3(lk.x + ux * g * 0.5 + rx * math.sin(t * 0.13) * 0.3, lk.y + uy * g * 0.5 + ry * math.sin(t * 0.13) * 0.3,
                lk.z + uz * g * 0.5 + rz * math.sin(t * 0.13) * 0.3)
    end
  end
  local iyaw, ipitch = 0, -0.3
  if ip then iyaw, ipitch = yaw_pitch(ip.x - h.x, ip.y - h.y, ip.z - h.z, rx, ry, rz, fx, fy, fz, ux, uy, uz) end
  -- the crew
  local cp = target_now()
  local cyaw, cpitch, cd = 0, 0, 1e9
  if cp then cyaw, cpitch, cd = yaw_pitch(cp.x - h.x, cp.y - h.y, cp.z - h.z, rx, ry, rz, fx, fy, fz, ux, uy, uz) end
  gz.on = cp ~= nil and (talking_to_me() or wantsLook(cd, cyaw, gz.on, params.look_near))
  looking = gz.on
  dt = math.min(0.1, dt or 0.016)
  gz.eng = gz.eng + ((gz.on and 1 or 0) - gz.eng) * (1 - math.exp(-3.5 * dt))
  -- blend in the scientist's frame, within the neck's reach
  iyaw, ipitch = clamp(iyaw, -NECK_YAW, NECK_YAW), clamp(ipitch, -NECK_DOWN, NECK_UP)
  cyaw, cpitch = clamp(cyaw, -NECK_YAW, NECK_YAW), clamp(cpitch, -NECK_DOWN, NECK_UP)
  local e = gz.eng * gz.eng * (3 - 2 * gz.eng)
  local ty = iyaw + wrap(cyaw - iyaw) * e
  local tp = ipitch + (cpitch - ipitch) * e
  if not gz.init then
    gz.yaw, gz.pitch, gz.init = ty, tp, true
  else
    local k = 1 - math.exp(-7 * dt)
    gz.yaw = gz.yaw + wrap(ty - gz.yaw) * k
    gz.pitch = gz.pitch + (tp - gz.pitch) * k
  end
  local cy, sy, cpt, spt = math.cos(gz.yaw), math.sin(gz.yaw), math.cos(gz.pitch), math.sin(gz.pitch)
  local dx = fx * cpt * cy + rx * cpt * sy + ux * spt
  local dy = fy * cpt * cy + ry * cpt * sy + uy * spt
  local dz = fz * cpt * cy + rz * cpt * sy + uz * spt
  local w = iw + (0.92 - iw) * e
  pcall(anim.lookAt, anim, { "Head" }, vec3(h.x + dx * 1.5, h.y + dy * 1.5, h.z + dz * 1.5), { limit = 70, weight = w })
  -- (probes) where the hands went after the IK, in the root's frame
  if debugHands then
    local function at(b) local p = bone_w(b); return p and node:toLocal(p) or nil end
    handsAt = { L = at("Hand.Left"), R = at("Hand.Right"), SL = at("Upperarm.Left"), SR = at("Upperarm.Right") }
  end
end
debugHands = false
handsAt = nil

function onDestroy()
  if board and board.valid ~= false then board:destroy() end
end
