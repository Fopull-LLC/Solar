-- GHOST — the one place Solar turns a node into a placement hologram
-- (deep-space addendum K4; docs/base-building.md).
--
--   ghost.apply(node, color, alpha)   color = { r, g, b } (0..1)
--
-- Every ghost in the game goes through this one function, so the engine's
-- own ghost mechanism (EN10) is a change here and nowhere else. Today it is
-- the Lua fallback: ONE hologram material (materials/hologram.ron, wearing
-- shaders/hologram.flsl: an additive rim and fill, order-independent, no
-- textures) assigned to the node and every mesh below it, then tinted with
-- two shader parameters. The material is assigned ONCE per node (a weak
-- set remembers which); a later call with a new colour is only the
-- uniform writes, and a call with the same colour and alpha writes nothing,
-- so a ghost that turns red for a frame costs two GPU uniform writes, never
-- a mesh or a material rebuild.
--
-- If the material can't be assigned (an engine without .flsl materials on
-- nodes), it falls back to setMaterial{ unlit, emissive, alpha }: the
-- textures stay and the part reads as a tinted glass copy.
--
-- On the Build Kit node (scenes/system.ron); reach it with findScript("ghost").

MATERIAL = "materials/hologram.ron"
DEPTH = 4

local applied = setmetatable({}, { __mode = "k" })   -- node handle → { r, g, b, a, mode }
local said = false

local function kids(n)
  local ok, k = pcall(function() return n:children() end)
  return ok and type(k) == "table" and k or {}
end

local function tint(n, st, c, a)
  if st.r == c[1] and st.g == c[2] and st.b == c[3] and st.a == a then return end
  st.r, st.g, st.b, st.a = c[1], c[2], c[3], a
  if st.mode == "shader" then
    pcall(n.setShaderParam, n, "tint", c[1], c[2], c[3])
    pcall(n.setShaderParam, n, "alpha", a)
  else
    pcall(n.setMaterial, n, { color = { c[1], c[2], c[3] }, emissive = { c[1], c[2], c[3] }, emissiveStrength = 0.6,
                              unlit = true, alpha = a, blend = "blend" })
  end
end

local function one(n, c, a)
  local st = applied[n]
  if not st then
    st = {}
    local ok = pcall(function() n.material = MATERIAL end)
    st.mode = ok and "shader" or "flat"
    if not ok and not said and log then said = true; log("ghost: no hologram material, using a tinted copy") end
    pcall(function() n.castShadow = false end)
    applied[n] = st
  end
  tint(n, st, c, a)
end

local function walk(n, c, a, depth)
  if not (n and n.valid ~= false) then return end
  one(n, c, a)
  if depth < DEPTH then
    for _, k in ipairs(kids(n)) do walk(k, c, a, depth + 1) end
  end
end

function apply(node, color, alpha)
  color = color or { 0.3, 0.95, 0.75 }
  walk(node, color, alpha or 0.6, 0)
end

-- (probes) the mode a node was given: "shader" | "flat" | nil
function modeOf(node) local st = node and applied[node]; return st and st.mode or nil end
