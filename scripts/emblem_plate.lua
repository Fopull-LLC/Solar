-- EMBLEM PLATE — the agency's emblem on a bezelled plate (docs/crew-and-items.md
-- §2.5). On the plate node of every crewed part (PartPod, PartSeat,
-- PartCockpit; tools/gen_flag.py adds them) and on prefabs/EmblemPlate.
--
-- The plate's face (its child "… Face") wears emblem.tex(), the agency's
-- emblem built at load by scripts/emblem.lua. It looks twice a second for
-- emblem.version to change, so a rename or a new emblem in Settings repaints
-- every plate live. Until the texture exists the face shows the prefab's own
-- textures/parts/emblem_default.png.

local face = nil
local seen = -1
local t_next = 0

local function find_face(node)
  for _, c in ipairs((node.children and node:children()) or {}) do
    if c.name and c.name:sub(-5) == " Face" then return c end
  end
  return nil
end

local em = nil
local function emblem()
  if not (em and em.valid) then em = findScript and findScript("emblem") or nil end
  return em
end

function start(node)
  face = find_face(node)
  -- The agency's textures live on the AgencyLib node: make one if this scene
  -- has none (it stands down itself if two arrive in the same frame).
  if not emblem() and spawn then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
end

function update(node, dt)
  local t = time or 0
  if t < t_next then return end
  t_next = t + 0.5
  if not (face and face.valid) then face = find_face(node) if not face then return end end
  local e = emblem()
  if not e then return end
  local v = e.version or 0
  if v == seen then return end
  local tex = e.tex and e.tex()
  if tex then
    face:setMaterial({ texture = tex })
    seen = v
  end
end

-- For probes: what the face wears now.
function painted() return seen end
