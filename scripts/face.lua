-- FACE — a crew member's head: who they are and how they feel, drawn.
--
-- Rides the "Face" node: a skinned head (models/astronaut/faces/head_<n>.glb,
-- tools/gen_faces.py) hung on the suit's Head bone as an attachment, with
-- two children, "Hair" (the style's shell) and "Cap" (the comm cap, worn
-- only under a helmet). The node is in every body a member has: the
-- Astronaut (scenes/system.ron), prefabs/CrewBody, prefabs/CrewDoll and
-- prefabs/Remains.
--
-- WHO. The member is the Astronaut's active one, or the CrewBody/CrewDoll's
-- bound id (crew_body.lua); their LOOK comes from crew_faces.lua (stored on
-- the crew record). Applying a look swaps the head model (the structure), the
-- hair model, and the shader knobs: skin, hair, lips, eyes, stubble,
-- freckles, age, scar (shaders/face_skin.flsl, face_eye.flsl; the hair's tint);
-- the suit's neck (SuitHead) takes the skin tone.
--
-- HOW THEY FEEL. crew_faces.lua turns what the member lives through into
-- named CHANNELS, weights 0..1 (CHANNELS below: jaw_open, smile_L, blink_R,
-- brow_in_up_L, …, and colour: flush, pale, pupil). This script adds the life
-- of a face — blinks, saccades, a little idle drift, the eyes and the head
-- turning to what is worth a look — and maps the channels onto the face's
-- bones in ONE adapter (`pose`). When the engine imports blend shapes (card
-- 0572) a morph-target adapter replaces `pose` and nothing else changes: the
-- channel names are the shape-key names.
--
-- COST. Only a face being seen moves: a portrait filming it (the crew strip's
-- aboard list), or the main camera within `near_m` and on screen (full rate),
-- or within `far_m` (at `far_hz`). Otherwise the last pose is held
-- (anim:holdPose) and nothing runs. One setBones call a frame per face; the
-- shader knobs are written only when they move.
--
-- API (probes, the context menu):
--   face.memberId                  who this is (nil: no member: a neutral face)
--   face.setLook(look)             wear this look (probes; nil: back to the member's)
--   face.override                  { channel = weight } laid over everything (probes)
--   face.still                     true: no blinks, saccades or drift (probes)
--   face.mood                      the expression's name, for probes
--   face.live                      true while the face is animating

defaults = {
  near_m = 30.0,
  far_m = 120.0,
  far_hz = 8.0,
  portrait_hz = 15.0,    -- a face seen only by a crew-strip portrait (4–6 redraws a second)
  look_m = 4.0,          -- the main camera this close: the member looks at it
}
local function P(k) return (params and params[k]) or defaults[k] end

-- @face-rig BEGIN (tools/gen_faces.py writes this block; don't edit it by hand)
RIG = {
  bones = { "FaceRoot", "Jaw", "LipLower", "LipUpper", "MouthL", "MouthR", "CheekL", "CheekR", "BrowInL", "BrowInR", "BrowOutL", "BrowOutR", "LidUpL", "LidUpR", "LidLoL", "LidLoR", "EyeL", "EyeR" },
  heads = {
    { name = "square", fem = 0.0, model = "models/astronaut/faces/head_1.glb", lidUp = 0.6291, lidLo = 0.1774,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.01918, -0.01200, 0.00000, -0.05300, 0.10359, 0.00000, -0.05618, 0.09388, 0.02852, -0.06318, 0.08270, -0.02852, -0.06318, 0.08270, 0.03600, -0.03418, 0.07441, -0.03600, -0.03418, 0.07438, 0.01500, 0.03124, 0.08594, -0.01500, 0.03124, 0.08592, 0.04200, 0.02924, 0.07857, -0.04200, 0.02924, 0.07857, 0.03364, 0.00924, 0.06630, -0.03373, 0.00924, 0.06630, 0.03364, 0.00924, 0.06630, -0.03373, 0.00924, 0.06630, 0.03364, 0.00924, 0.06630, -0.03373, 0.00924, 0.06630 } },
    { name = "long", fem = 0.0, model = "models/astronaut/faces/head_2.glb", lidUp = 0.6378, lidLo = 0.1799,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.02614, -0.01200, 0.00000, -0.05300, 0.10462, 0.00000, -0.06314, 0.09436, 0.02376, -0.07014, 0.08288, -0.02376, -0.07014, 0.08288, 0.03600, -0.04114, 0.07316, -0.03600, -0.04114, 0.07314, 0.01500, 0.03124, 0.08533, -0.01500, 0.03124, 0.08531, 0.04200, 0.02924, 0.07630, -0.04200, 0.02924, 0.07680, 0.03064, 0.00924, 0.06630, -0.03072, 0.00924, 0.06630, 0.03064, 0.00924, 0.06630, -0.03072, 0.00924, 0.06630, 0.03064, 0.00924, 0.06630, -0.03072, 0.00924, 0.06630 } },
    { name = "round", fem = 0.0, model = "models/astronaut/faces/head_3.glb", lidUp = 0.6278, lidLo = 0.1771,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.01539, -0.01200, 0.00000, -0.05300, 0.10392, 0.00000, -0.05239, 0.09530, 0.03015, -0.05939, 0.08298, -0.03015, -0.05939, 0.08298, 0.03600, -0.03039, 0.07482, -0.03600, -0.03039, 0.07481, 0.01500, 0.03124, 0.08471, -0.01500, 0.03124, 0.08469, 0.04200, 0.02924, 0.07715, -0.04200, 0.02924, 0.07716, 0.03503, 0.00924, 0.06630, -0.03512, 0.00924, 0.06630, 0.03503, 0.00924, 0.06630, -0.03512, 0.00924, 0.06630, 0.03503, 0.00924, 0.06630, -0.03512, 0.00924, 0.06630 } },
    { name = "craggy", fem = 0.0, model = "models/astronaut/faces/head_4.glb", lidUp = 0.6320, lidLo = 0.1782,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.02147, -0.01200, 0.00000, -0.05300, 0.10406, 0.00000, -0.05847, 0.09348, 0.02639, -0.06547, 0.08265, -0.02639, -0.06547, 0.08265, 0.03600, -0.03647, 0.07441, -0.03600, -0.03647, 0.07438, 0.01500, 0.03124, 0.08697, -0.01500, 0.03124, 0.08696, 0.04200, 0.02924, 0.07805, -0.04200, 0.02924, 0.07806, 0.03226, 0.00924, 0.06631, -0.03234, 0.00924, 0.06631, 0.03226, 0.00924, 0.06631, -0.03234, 0.00924, 0.06631, 0.03226, 0.00924, 0.06631, -0.03234, 0.00924, 0.06631 } },
    { name = "oval", fem = 1.0, model = "models/astronaut/faces/head_5.glb", lidUp = 0.6294, lidLo = 0.1775,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.01886, -0.01200, 0.00000, -0.05300, 0.10392, 0.00000, -0.05586, 0.09530, 0.02271, -0.06286, 0.08298, -0.02271, -0.06286, 0.08298, 0.03600, -0.03386, 0.07386, -0.03600, -0.03386, 0.07382, 0.01500, 0.03124, 0.08338, -0.01500, 0.03124, 0.08335, 0.04200, 0.02924, 0.07500, -0.04200, 0.02924, 0.07505, 0.03133, 0.00924, 0.06629, -0.03141, 0.00924, 0.06629, 0.03133, 0.00924, 0.06629, -0.03141, 0.00924, 0.06629, 0.03133, 0.00924, 0.06629, -0.03141, 0.00924, 0.06629 } },
    { name = "wide", fem = 1.0, model = "models/astronaut/faces/head_6.glb", lidUp = 0.6294, lidLo = 0.1775,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.01644, -0.01200, 0.00000, -0.05300, 0.10504, 0.00000, -0.05344, 0.09603, 0.02800, -0.06044, 0.08320, -0.02800, -0.06044, 0.08320, 0.03600, -0.03144, 0.07504, -0.03600, -0.03144, 0.07502, 0.01500, 0.03124, 0.08349, -0.01500, 0.03124, 0.08346, 0.04200, 0.02924, 0.07572, -0.04200, 0.02924, 0.07575, 0.03674, 0.00924, 0.06629, -0.03682, 0.00924, 0.06629, 0.03674, 0.00924, 0.06629, -0.03682, 0.00924, 0.06629, 0.03674, 0.00924, 0.06629, -0.03682, 0.00924, 0.06629 } },
    { name = "angular", fem = 1.0, model = "models/astronaut/faces/head_7.glb", lidUp = 0.6337, lidLo = 0.1787,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.02243, -0.01200, 0.00000, -0.05300, 0.10465, 0.00000, -0.05943, 0.09479, 0.02550, -0.06643, 0.08297, -0.02550, -0.06643, 0.08297, 0.03600, -0.03743, 0.07441, -0.03600, -0.03743, 0.07438, 0.01500, 0.03124, 0.08380, -0.01500, 0.03124, 0.08377, 0.04200, 0.02924, 0.07550, -0.04200, 0.02924, 0.07554, 0.03226, 0.00924, 0.06629, -0.03234, 0.00924, 0.06629, 0.03226, 0.00924, 0.06629, -0.03234, 0.00924, 0.06629, 0.03226, 0.00924, 0.06629, -0.03234, 0.00924, 0.06629 } },
    { name = "heart", fem = 1.0, model = "models/astronaut/faces/head_8.glb", lidUp = 0.6280, lidLo = 0.1771,
      rest = { -0.49989, 1.72475, -0.01310, 0.00000, -0.01775, -0.01200, 0.00000, -0.05300, 0.10517, 0.00000, -0.05475, 0.09565, 0.02307, -0.06175, 0.08317, -0.02307, -0.06175, 0.08317, 0.03600, -0.03275, 0.07441, -0.03600, -0.03275, 0.07438, 0.01500, 0.03124, 0.08347, -0.01500, 0.03124, 0.08345, 0.04200, 0.02924, 0.07501, -0.04200, 0.02924, 0.07506, 0.03295, 0.00924, 0.06629, -0.03303, 0.00924, 0.06629, 0.03295, 0.00924, 0.06629, -0.03303, 0.00924, 0.06629, 0.03295, 0.00924, 0.06629, -0.03303, 0.00924, 0.06629 } },
  },
  hair = { "buzz", "crop", "side", "swept", "bun", "tail", "curls", "receding" },
  -- channel = { { bone, dx, dy, dz, yaw, pitch [, scale] } … } (see CHANNEL_MAP)
  map = {
    jaw_open = { { "Jaw", 0, 0, 0, 0, 0.26 } },
    lip_down = { { "LipLower", 0, -0.0045, 0.0012, 0, 0 } },
    lip_up = { { "LipUpper", 0, 0.0045, 0.001, 0, 0 } },
    smile_L = { { "MouthL", 0.006, 0.0085, -0.0035, 0, 0 }, { "LipUpper", 0, 0.0008, 0, 0, 0 } },
    smile_R = { { "MouthR", -0.006, 0.0085, -0.0035, 0, 0 }, { "LipUpper", 0, 0.0008, 0, 0, 0 } },
    frown_L = { { "MouthL", 0.0008, -0.006, -0.0004, 0, 0 } },
    frown_R = { { "MouthR", -0.0008, -0.006, -0.0004, 0, 0 } },
    stretch_L = { { "MouthL", 0.0065, -0.0025, -0.0025, 0, 0 } },
    stretch_R = { { "MouthR", -0.0065, -0.0025, -0.0025, 0, 0 } },
    cheek_L = { { "CheekL", 0.0012, 0.0055, 0.0018, 0, 0 }, { "LidLoL", 0, 0, 0, 0, -0.06 } },
    cheek_R = { { "CheekR", -0.0012, 0.0055, 0.0018, 0, 0 }, { "LidLoR", 0, 0, 0, 0, -0.06 } },
    brow_in_up_L = { { "BrowInL", 0, 0.0085, 0, 0, 0 }, { "BrowOutL", 0, 0.0015, 0, 0, 0 }, { "LidUpL", 0, 0, 0, 0, -0.04 } },
    brow_in_up_R = { { "BrowInR", 0, 0.0085, 0, 0, 0 }, { "BrowOutR", 0, 0.0015, 0, 0, 0 }, { "LidUpR", 0, 0, 0, 0, -0.04 } },
    brow_out_up_L = { { "BrowOutL", 0, 0.0078, 0, 0, 0 } },
    brow_out_up_R = { { "BrowOutR", 0, 0.0078, 0, 0, 0 } },
    brow_down_L = { { "BrowInL", -0.0024, -0.0058, 0.0008, 0, 0 }, { "BrowOutL", 0, -0.0028, 0, 0, 0 }, { "LidUpL", 0, 0, 0, 0, 0.08 } },
    brow_down_R = { { "BrowInR", 0.0024, -0.0058, 0.0008, 0, 0 }, { "BrowOutR", 0, -0.0028, 0, 0, 0 }, { "LidUpR", 0, 0, 0, 0, 0.08 } },
    blink_L = { { "LidUpL", 0, 0, 0, 0, 1.06, "up" }, { "LidLoL", 0, 0, 0, 0, -0.5, "lo" } },
    blink_R = { { "LidUpR", 0, 0, 0, 0, 1.06, "up" }, { "LidLoR", 0, 0, 0, 0, -0.5, "lo" } },
    wide_L = { { "LidUpL", 0, 0, 0, 0, -0.2 } },
    wide_R = { { "LidUpR", 0, 0, 0, 0, -0.2 } },
    squint_L = { { "LidUpL", 0, 0, 0, 0, 0.1 }, { "LidLoL", 0, 0, 0, 0, -0.75, "lo" } },
    squint_R = { { "LidUpR", 0, 0, 0, 0, 0.1 }, { "LidLoR", 0, 0, 0, 0, -0.75, "lo" } },
    look_x = { { "EyeL", 0, 0, 0, 0.45, 0 }, { "EyeR", 0, 0, 0, 0.45, 0 } },
    look_y = { { "EyeL", 0, 0, 0, 0, -0.45 }, { "EyeR", 0, 0, 0, 0, -0.45 } },
  },
  scars = { { 0.3827, 0.4072, 0.4055, 0.4616 }, { 0.6890, 0.5755, 0.7660, 0.5438 }, { 0.4979, 0.7560, 0.5273, 0.7112 } },
}
-- @face-rig END

-- The channels, in a fixed order (the morph-target names to come).
CHANNELS = {
  "jaw_open", "smile_L", "smile_R", "frown_L", "frown_R", "stretch_L", "stretch_R", "lip_up", "lip_down",
  "brow_in_up_L", "brow_in_up_R", "brow_out_up_L", "brow_out_up_R", "brow_down_L", "brow_down_R",
  "blink_L", "blink_R", "wide_L", "wide_R", "squint_L", "squint_R", "cheek_L", "cheek_R",
  "look_x", "look_y",
  -- colour, not shape
  "flush", "pale", "pupil",
}

-- ── the adapter: channels → bones ───────────────────────────────────────────
-- The map is data (RIG.map, written by tools/gen_faces.py from its
-- CHANNEL_MAP; the same data bakes the morph targets for card 0572): per
-- channel, bone offsets in the head's frame (metres: x the crew's left, y up,
-- z forward) and turns (radians), summed by weight over the rest pose.
-- Signs measured on the heads in tools/perf/facestudio.lua.
LID_SIGN = 1.0        -- +pitch on a lid bone shuts it
JAW_SIGN = 1.0        -- +pitch on the jaw opens it
LID_BONES = { LidUpL = true, LidUpR = true, LidLoL = true, LidLoR = true }

-- pose(ch, head) → positions (flat x,y,z per bone, parent space), rotations
-- (flat yaw,pitch,roll per bone). Pure: tests/smoke_faces.lua calls it.
function pose(ch, head)
  local rest = head.rest
  local nb = #RIG.bones
  local pos, rot = {}, {}
  for i = 1, nb * 3 do pos[i], rot[i] = rest[i], 0 end
  for name, w in pairs(ch) do
    local ents = RIG.map[name]
    if ents and w ~= 0 then
      if name:sub(1, 6) == "blink_" and w > 1 then w = 1 end
      for _, e in ipairs(ents) do
        local i = BI[e[1]]
        local k = w
        if e[7] == "up" then k = k * head.lidUp elseif e[7] == "lo" then k = k * head.lidLo end
        pos[i * 3 - 2] = pos[i * 3 - 2] + e[2] * w
        pos[i * 3 - 1] = pos[i * 3 - 1] + e[3] * w
        pos[i * 3] = pos[i * 3] + e[4] * w
        local sg = (LID_BONES[e[1]] and LID_SIGN) or (e[1] == "Jaw" and JAW_SIGN) or 1
        rot[i * 3 - 2] = rot[i * 3 - 2] + e[5] * w
        rot[i * 3 - 1] = rot[i * 3 - 1] + e[6] * k * sg
      end
    end
  end
  -- a lid never turns past shut, nor further open than wide
  for _, n in ipairs({ "L", "R" }) do
    local i = BI["LidUp" .. n]
    local lim = head.lidUp * 1.1
    rot[i * 3 - 1] = LID_SIGN * math.max(-0.3, math.min(lim, rot[i * 3 - 1] * LID_SIGN))
  end
  return pos, rot
end

BI = {}
if RIG then for i, b in ipairs(RIG.bones) do BI[b] = i end end

-- ── state ───────────────────────────────────────────────────────────────────
memberId = nil
override = nil
still = false          -- probes: no blinks, saccades or drift
forceHelmet = nil      -- probes: true/false wears the cap (and the visor light) whatever the suit says
mood = "neutral"
live = false
local self_node, model_node, root_node
local hair_node, cap_node
local anim, suit_anim, idx
local look, look_key, forced_look = nil, nil, nil
local bound_id = nil       -- a CrewBody's / CrewDoll's member (fixed for the node's life)
local reapply_t, reapply_gap = nil, 0.5
local warned = false
local chbuf = {}
local head = nil
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

-- the face's own life: blinks, saccades, drift
local life = { blink_t = 1.5, blink = 0, sacc_t = 0.8, gx = 0, gy = 0, tx = 0, ty = 0, t = 0, seed = 0,
               glance_t = 5, gl_x = 0, gl_y = 0, gl_left = 0 }
local last_write = -10
local knobs = {}           -- the shader values last written

function setLook(l)
  forced_look = l
  look_key = nil
end

local function find_kids(node)
  for _, k in ipairs(node:children() or {}) do
    if k.name == "Hair" then hair_node = k end
    if k.name == "Cap" then cap_node = k end
  end
end

-- Who is this? The Astronaut is the active member; a CrewBody/CrewDoll its
-- bound one; Remains nobody (a neutral, still face).
local function owner()
  if not root_node then return nil end
  local C = ref("crew")
  if root_node.name == "Astronaut" then return C and C.activeId and C.activeId() or nil end
  if bound_id then return bound_id end
  if root_node.name ~= "CrewBody" and root_node.name ~= "CrewDoll" then return nil end
  local cb = root_node.getScript and root_node:getScript("crew_body")
  if cb and cb.memberId then bound_id = cb.memberId return bound_id end
  if C and C.memberOfNode then bound_id = C.memberOfNode(root_node) end
  if bound_id then return bound_id end
  -- iva.lua's stand-in: an unbound doll that sits in for the avatar aboard
  local I = ref("iva")
  local si = I and I.standIn and I.standIn()
  if si and si.valid ~= false and si.id == root_node.id then return C and C.activeId and C.activeId() or nil end
  return nil
end

local mats = {}             -- material handles, kept per look
local function mat(n, name)
  if not (n and n.valid ~= false and n.material) then return nil end
  local key = tostring(n.id) .. name
  local m = mats[key]
  if m then return m end
  local ok, h = pcall(n.material, n, name)
  m = ok and h or nil
  mats[key] = m
  return m
end

local function knob(m, key, name, a, b, c3, eps)
  local prev = knobs[key]
  eps = eps or 0.004
  if prev and math.abs(prev[1] - a) < eps and math.abs(prev[2] - (b or 0)) < eps and math.abs(prev[3] - (c3 or 0)) < eps then
    return
  end
  knobs[key] = { a, b or 0, c3 or 0 }
  if m and m.setShaderParam then
    if b then pcall(m.setShaderParam, m, name, a, b, c3 or 0) else pcall(m.setShaderParam, m, name, a) end
  end
end

-- Wear look `l`: the structure, the hair, the colours.
local function apply_look(l)
  if not (l and RIG) then return end
  head = RIG.heads[l.head or 1] or RIG.heads[1]
  if self_node.model ~= head.model then
    self_node.model = head.model
    idx = nil           -- a new model: bone numbers again
  end
  knobs = {}
  mats = {}
  local hs = "models/astronaut/faces/hair_" .. tostring(l.hairStyle or "crop") .. ".glb"
  if hair_node and hair_node.model ~= hs then hair_node.model = hs end
  local sk = mat(self_node, "FaceSkin")
  local s, h, lp = l.skin or { 0.72, 0.54, 0.43 }, l.hair or { 0.2, 0.15, 0.1 }, l.lip or { 0.6, 0.36, 0.33 }
  -- the looks are sRGB; a shader's colour uniform is linear light
  local function lin(x) return x ^ 2.2 end
  knob(sk, "skin", "skin", lin(s[1]), lin(s[2]), lin(s[3]))
  knob(sk, "hair", "hair", lin(h[1]), lin(h[2]), lin(h[3]))
  knob(sk, "lip", "lip", lin(lp[1]), lin(lp[2]), lin(lp[3]))
  knob(sk, "stubble", "stubble", l.stubble or 0)
  knob(sk, "freckles", "freckles", l.freckles or 0)
  knob(sk, "age", "age", l.age or 0.3)
  knob(sk, "brow", "brow", l.brow or 0.5)
  local sc = RIG.scars and RIG.scars[l.scar or 0]
  if sc then
    knob(sk, "scarA", "scarA", sc[1], sc[2], 0.0035)
    knob(sk, "scarB", "scarB", sc[3], sc[4], 0.85)
  else
    knob(sk, "scarB", "scarB", 0, 0, 0)
  end
  -- the scalp's shading under the hair, by style: where the line sits, how
  -- much shows, how coarse (coily hair throws more shadow at its sections)
  local SCALP = { buzz = { 0, 0.9, 0 }, crop = { 0, 0.85, 0 }, side = { 0, 0.8, 0 }, swept = { 0.35, 0.8, 0 },
                  bun = { -0.12, 0.8, 0 }, tail = { -0.12, 0.8, 0 }, curls = { 0, 0.95, 1 }, receding = { 0.35, 0.75, 0 } }
  local sc_ = SCALP[l.hairStyle or "crop"] or SCALP.crop
  knob(sk, "scalp", "scalp", sc_[1], sc_[2], sc_[3])
  local ey = mat(self_node, "FaceEye")
  local e = l.eye or { 0.35, 0.25, 0.15 }
  knob(ey, "iris", "iris", e[1] ^ 2.2, e[2] ^ 2.2, e[3] ^ 2.2)
  -- the hair cards' material is a plain one: its tint is the colour (the
  -- atlas is grey strands), grey coming in with age
  local hm = mat(hair_node, "Hair")
  if hm then
    local g = (l.grey or 0) * 0.6
    local function ch(x) return math.min(1, x * (1 - g) + 0.42 * g) end
    pcall(function() hm.color = { ch(h[1]), ch(h[2]), ch(h[3]) } end)
  end
  -- the suit's neck: the same skin
  local nk = mat(model_node, "SuitHead")
  if nk then
    local ok, err = pcall(function() nk.color = { s[1], s[2], s[3] } end)
    if not ok and not warned then warned = true; print("face: neck colour: " .. tostring(err)) end
    pcall(function() nk.texture = "" end)
    pcall(function() nk.roughness = 0.6 end)
  end
  life.seed = (l.seed or 0) % 1000
end

-- ── the frame ───────────────────────────────────────────────────────────────

function start(node)
  self_node = node
  model_node = node.parent
  root_node = model_node and model_node.parent or nil
  find_kids(node)
end

local function rnd()
  return math.random()
end

-- blinks, saccades, idle drift: added to the channels
local function face_life(ch, dt, scared, dead, hover)
  if dead then return end
  life.t = life.t + dt
  life.blink_t = life.blink_t - dt
  if life.blink_t <= 0 then
    life.blink = 0.16
    life.blink_t = (scared and 1.2 or 2.2) + rnd() * (scared and 1.5 or 4.0)
  end
  local b = 0
  if life.blink > 0 then
    life.blink = life.blink - dt
    local u = 1 - math.max(0, life.blink) / 0.16
    b = math.sin(math.min(1, u) * math.pi)
  end
  ch.blink_L = math.min(1, (ch.blink_L or 0) + b)
  ch.blink_R = math.min(1, (ch.blink_R or 0) + b)
  life.sacc_t = life.sacc_t - dt
  if life.sacc_t <= 0 then
    local amp = scared and 0.55 or 0.22
    life.tx = (rnd() * 2 - 1) * amp
    life.ty = (rnd() * 2 - 1) * amp * 0.5
    if rnd() < 0.45 then life.tx, life.ty = 0, 0 end      -- back to what they were looking at
    life.sacc_t = (scared and 0.25 or 0.6) + rnd() * (scared and 0.6 or 2.6)
  end
  -- now and then a longer look somewhere else (out of a window, at the
  -- panel), then back to what is in front of them
  life.glance_t = life.glance_t - dt
  if life.glance_t <= 0 and not scared then
    life.gl_x, life.gl_y = (rnd() * 2 - 1) * 0.8, (rnd() * 2 - 1) * 0.3
    life.gl_left = 1.0 + rnd() * 1.8
    life.glance_t = 6 + rnd() * 9
  end
  if life.gl_left > 0 then
    life.gl_left = life.gl_left - dt
    if life.gl_left <= 0 then life.gl_x, life.gl_y = 0, 0 end
  end
  if hover then life.gl_x, life.gl_y, life.gl_left = 0, 0, 0 end    -- looked at: they look back
  local k = math.min(1, dt * 30)                             -- saccades are fast
  life.gx = life.gx + (life.tx + life.gl_x - life.gx) * k
  life.gy = life.gy + (life.ty + life.gl_y - life.gy) * k
  ch.look_x = (ch.look_x or 0) + life.gx
  ch.look_y = (ch.look_y or 0) + life.gy
  -- idle drift: the brows and the mouth never quite still
  local t, s = life.t, life.seed
  local d1 = math.sin(t * 0.37 + s) * 0.5 + math.sin(t * 0.91 + s * 2.1) * 0.5
  local d2 = math.sin(t * 0.23 + s * 1.7) * 0.5 + math.sin(t * 0.61 + s * 0.3) * 0.5
  ch.brow_out_up_L = math.max(0, (ch.brow_out_up_L or 0) + 0.06 * d1)
  ch.brow_out_up_R = math.max(0, (ch.brow_out_up_R or 0) + 0.06 * d1)
  ch.smile_L = math.max(0, (ch.smile_L or 0) + 0.04 * d2)
  ch.frown_R = math.max(0, (ch.frown_R or 0) + 0.03 * d2)
end

-- Is this face being looked at, and how closely? "full" | "far" | nil
local function seen()
  if not (self_node.visible ~= false and model_node and model_node.visible ~= false
          and (not root_node or root_node.visible ~= false)) then
    return nil
  end
  local F = ref("crew_faces")
  local filmed = memberId and F and F.featured and F.featured(memberId)
  if not (camera and camera.worldToScreen and camera.exists and camera.exists()) then return "full" end
  local ok, _, _, depth, on = pcall(camera.worldToScreen, self_node.x, self_node.y, self_node.z)
  if ok and depth then
    if depth < 1.5 then return "full" end       -- right by the lens (first person in the IVA)
    if on and depth < P("near_m") then return "full" end
  end
  -- a portrait redraws a few times a second: the face need not move faster
  if filmed then return "portrait" end
  if ok and depth and on and depth < P("far_m") then return "far" end
  return nil
end

local function cam_point()
  local pc = ref("planet_camera")
  local n = pc and pc.node
  if n and n.valid ~= false then return n.x, n.y, n.z end
  return nil
end

function lateUpdate(node, dt)
  if not RIG then return end
  self_node = node
  if not model_node then start(node) end
  if not (hair_node and cap_node) then find_kids(node) end
  memberId = owner()
  local F = ref("crew_faces")
  -- the look
  local l = forced_look
  if not l and memberId and F and F.lookOf then l = F.lookOf(memberId) end
  if not l and F and F.lookFor then l = F.lookFor(0, 0, "Nobody") end
  local key = l and (tostring(l.key or "") .. ":" .. tostring(l.head) .. tostring(l.hairStyle)) or nil
  if l and key ~= look_key then
    look, look_key = l, key
    apply_look(l)
    reapply_t, reapply_gap = (time or 0) + 0.5, 0.5
  elseif look and reapply_t and (time or 0) >= reapply_t then
    -- a swapped model loads in the background: say it all again a few
    -- times so no knob lands on a model that wasn't there yet
    knobs = {}
    apply_look(look)
    reapply_gap = reapply_gap * 2
    reapply_t = reapply_gap < 9 and (time or 0) + reapply_gap or nil
  end
  if not head then return end
  -- cap under a helmet, hair otherwise
  local helmet = false
  if root_node and root_node.name == "Astronaut" then
    local su = ref("suit")
    helmet = su and su.helmet == true or false
  end
  if forceHelmet ~= nil then helmet = forceHelmet end
  if cap_node and cap_node.visible ~= helmet then cap_node.visible = helmet end
  if hair_node and hair_node.visible ~= (not helmet) then hair_node.visible = not helmet end
  -- seen?
  local how = seen()
  live = how ~= nil
  if not how then return end
  local hz = (how == "far" and P("far_hz")) or (how == "portrait" and P("portrait_hz")) or nil
  if hz and time and (time - last_write) < 1 / hz then return end
  local wdt = time and math.min(0.25, math.max(dt or 0, time - last_write)) or (dt or 0)
  last_write = time or 0
  -- the channels
  local ch = chbuf
  for k in pairs(ch) do ch[k] = nil end
  local st = memberId and F and F.channels and F.channels(memberId) or nil
  local dead = false
  if st then
    for k, v in pairs(st) do ch[k] = v end
    mood = (F.moodOf and F.moodOf(memberId)) or mood
    dead = mood == "dead"
  elseif root_node and root_node.name == "Remains" then
    dead, mood = true, "dead"
    ch.blink_L, ch.blink_R, ch.jaw_open, ch.pale = 0.8, 0.85, 0.12, 1.0
  end
  if look and look.rest then
    local r = look.rest
    ch.brow_in_up_L = (ch.brow_in_up_L or 0) + math.max(0, r.brow or 0) * 0.3
    ch.brow_in_up_R = (ch.brow_in_up_R or 0) + math.max(0, r.brow or 0) * 0.3
    ch.brow_down_L = (ch.brow_down_L or 0) + math.max(0, -(r.brow or 0)) * 0.3
    ch.brow_down_R = (ch.brow_down_R or 0) + math.max(0, -(r.brow or 0)) * 0.3
    ch.frown_L = (ch.frown_L or 0) + math.max(0, -(r.mouth or 0)) * 0.3
    ch.frown_R = (ch.frown_R or 0) + math.max(0, -(r.mouth or 0)) * 0.3
    ch.smile_L = (ch.smile_L or 0) + math.max(0, r.mouth or 0) * 0.2
    ch.smile_R = (ch.smile_R or 0) + math.max(0, r.mouth or 0) * 0.2
    -- a resting upper lid sits a little over the iris (a face that is not
    -- staring), heavier for some
    ch.blink_L = (ch.blink_L or 0) + 0.10 + (r.lid or 0) * 0.22
    ch.blink_R = (ch.blink_R or 0) + 0.10 + (r.lid or 0) * 0.22
  end
  local S = ref("crew_strip")
  local hovered = memberId ~= nil and S ~= nil and S.hoverId == memberId
  if not still then face_life(ch, wdt, (ch.wide_L or 0) > 0.4, dead, hovered) end
  if override then for k, v in pairs(override) do ch[k] = v end end
  -- the bones
  anim = anim or (node.animator and node:animator()) or nil
  if not anim then return end
  if not idx then
    local ok, list = pcall(function()
      local out = {}
      for i, b in ipairs(RIG.bones) do out[i] = anim:boneIndex(b) end
      return out
    end)
    if not ok or not list[1] then return end
    idx = list
    pcall(anim.holdPose, anim, true)
  end
  local pos, rot = pose(ch, head)
  anim:setBones(idx, pos, rot)
  -- the head and the eyes turn to the camera when it is close
  local cx, cy, cz = cam_point()
  if cx and not dead and model_node then
    local dx, dy, dz = cx - node.x, cy - node.y, cz - node.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < P("look_m") and d > 0.6 then
      suit_anim = suit_anim or (model_node.animator and model_node:animator()) or nil
      local w = math.min(1, (P("look_m") - d) / 1.5)
      if suit_anim then pcall(suit_anim.lookAt, suit_anim, { "Head" }, vec3(cx, cy, cz), { limit = 28, weight = 0.6 * w }) end
      pcall(anim.lookAt, anim, { "EyeL" }, vec3(cx, cy, cz), { limit = 30, weight = w })
      pcall(anim.lookAt, anim, { "EyeR" }, vec3(cx, cy, cz), { limit = 30, weight = w })
    end
  end
  -- the colour knobs
  local sk = mat(node, "FaceSkin")
  -- a little light on the face where the world gives it little: inside a
  -- helmet (behind the visor), and in a cabin (the portraits film dolls by
  -- the instrument light)
  local glow = helmet and 0.6 or ((root_node and root_node.name == "CrewDoll") and 0.7 or 0.0)
  knob(sk, "flush", "flush", math.min(1, ch.flush or 0), nil, nil, 0.02)
  knob(sk, "pale", "pale", math.min(1, ch.pale or 0), nil, nil, 0.02)
  knob(sk, "glow", "glow", glow, nil, nil, 0.02)
  local ey = mat(node, "FaceEye")
  knob(ey, "pupil", "pupil", 0.32 + 0.30 * math.min(1, ch.pupil or 0), nil, nil, 0.02)
  knob(ey, "eglow", "glow", glow, nil, nil, 0.02)
end
