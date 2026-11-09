-- SUIT LOOK — on every model that wears the crew's EVA suit (the player's
-- AstroModel in scenes/system.ron; prefabs/CrewDoll, CrewBody and Remains).
-- The suit itself is tools/gen_suit.py's (models/astronaut/astronaut_male*.glb).
--
--   1. THE AGENCY EMBLEM. The left shoulder patch is a material of its own,
--      "SuitEmblem"; it wears emblem.tex(), the agency's emblem built by
--      scripts/emblem.lua, and is repainted when emblem.version changes (a
--      new name or emblem in Settings ▸ Agency), as every emblem plate is.
--      Until that texture exists it shows textures/suit/emblem.png.
--   2. ITS LEVEL OF DETAIL (params lod = 1; the player's own suit leaves it
--      off and always draws LOD 0). The suit comes in three builds on the same
--      rig, the same weights and the same box centre (gen_suit.py LODS): LOD 0
--      within `near` metres of the camera, LOD 1 out to `far`, LOD 2 beyond.
--      A band is left only `hyst` metres past its edge, so a crew member
--      standing on the line doesn't flicker between two. Looked at four times
--      a second; nothing is swapped while the model is off screen.
--
-- Distances are measured afresh at each look (the node's world position and
-- the camera's, both read in the same call), never kept across frames.

defaults = { lod = 0, near = 9, far = 24, hyst = 1.5 }

local BASE = "models/astronaut/astronaut_male"
local MODELS = { [0] = BASE .. ".glb", [1] = BASE .. "_lod1.glb", [2] = BASE .. "_lod2.glb" }

local node_ = nil
local seen = -1            -- the emblem.version painted
local t_em, t_lod = 0, 0
local cur = nil            -- the LOD drawn now (nil: not known yet)
local em = nil

local function emblem()
  if not (em and em.valid) then em = findScript and findScript("emblem") or nil end
  return em
end

local function lod_of(model)
  for k, m in pairs(MODELS) do if m == model then return k end end
  return nil
end

function start(node)
  node_ = node
  cur = lod_of(node.model)
end

local function paint_emblem(node)
  local e = emblem()
  if not e then return end
  local v = e.version or 0
  if v == seen then return end
  local tex = e.tex and e.tex()
  if not tex then return end
  local ok, m = pcall(node.material, node, "SuitEmblem")
  if ok and m then
    pcall(function() m.texture = tex end)
    seen = v
  end
end

local function pick_lod(node)
  if not (camera and camera.exists and camera.exists()) then return end
  local ok, p = pcall(function() return node.worldPos end)
  if not (ok and p) then return end
  local _, _, depth, onscreen = camera.worldToScreen(p.x, p.y, p.z)
  if not onscreen or not depth then return end
  local d = math.abs(depth)
  local near, far, h = params.near, params.far, params.hyst
  local want
  if cur == nil then
    want = (d < near) and 0 or ((d < far) and 1 or 2)
  elseif cur == 0 then
    want = (d > near + h) and ((d > far) and 2 or 1) or 0
  elseif cur == 1 then
    want = (d < near - h) and 0 or ((d > far + h) and 2 or 1)
  else
    want = (d < near - h) and 0 or ((d < far - h) and 1 or 2)
  end
  if want ~= cur then
    node.model = MODELS[want]
    cur = want
    seen = -1              -- a new model: its SuitEmblem override is new too
  end
end

function update(node, dt)
  local t = time or 0
  if t >= t_em then
    t_em = t + 0.5
    paint_emblem(node)
  end
  if (params.lod or 0) > 0 and t >= t_lod then
    t_lod = t + 0.25
    pick_lod(node)
  end
end

-- For probes: the LOD drawn now, and the emblem version painted.
function lodNow() return cur end
function emblemPainted() return seen end
