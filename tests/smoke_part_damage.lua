-- SMOKE HARNESS: painting wear on a part (vessel_controller.lua, set_part_damage).
--
-- The textured parts (tools/gen_part_meshes.py) carry NO node Material — their
-- look is per-part `object_materials` — and the engine's node:material() raises
-- on such a node. Called on a scrape, that error took the whole vessel
-- controller down at touchdown: the crew thrown out, the chutes reset. This
-- holds that wear on every kind of part is painted without an error:
--
--   * a part with no Material component darkens with a tint and never calls
--     node:material();
--   * a part wearing the hullPanels shader (the chute) gets the `damage` uniform;
--   * a part whose every method raises still cannot take the controller down.
--
--   luajit solar/tests/smoke_part_damage.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

-- Load the controller in an environment where every engine global is a
-- harmless stub; only the published paintDamage is exercised.
local stub = setmetatable({}, { __index = function() return function() end end,
                                __call = function() return nil end })
local env = setmetatable({}, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
check("vessel_controller loads in a stub world", ok, tostring(err))
env.log = function() end
check("...and publishes paintDamage", type(env.paintDamage) == "function")

-- A textured part: no Material component; material() RAISES like the engine.
local material_called = false
local tinted = nil
local textured = { valid = true, name = "PartTankS" }
function textured:getcomponent(k) return nil end
function textured:material() material_called = true; error("node has no Material") end
function textured:setTint(t) tinted = t or "cleared" end
function textured:setShaderParam() error("no shader to land on") end

local ok1, e1 = pcall(env.paintDamage, textured, 0.4)
check("wear on a part with no Material does not error", ok1, tostring(e1))
check("...it never asks for the missing material", material_called == false)
check("...and it darkens with a tint", type(tinted) == "table" and tinted[1] < 1 and tinted[3] < tinted[1],
  tostring(tinted))
pcall(env.paintDamage, textured, 1.0)
check("a mended part loses its tint", (function() tinted = nil; env.paintDamage(textured, 1.0); return tinted == "cleared" end)())

-- The chute: a node Material wearing a shader takes the uniform.
local got = nil
local chute = { valid = true, name = "PartChute" }
function chute:getcomponent(k) return (k == "Material") and {} or nil end
function chute:material() return { shader = "shaders/hullPanels.flsl" } end
function chute:setShaderParam(n, v) got = { n, v } end
function chute:setTint() error("a shader part should not be tinted") end
local ok2, e2 = pcall(env.paintDamage, chute, 0.25)
check("a hullPanels part takes the damage uniform", ok2 and got and got[1] == "damage"
  and math.abs(got[2] - 0.75) < 1e-6, tostring(e2))

-- A textured part on the restored hullPanels materials: no node Material, but
-- setShaderParam fans out to its children — it takes the `damage` param (the
-- shader draws scorch, gouges and dents) and is not tinted on top.
local got2, tint2 = nil, nil
local panels = { valid = true, name = "PartPod" }
function panels:getcomponent(k) return nil end
function panels:material() error("node has no Material") end
function panels:setShaderParam(n, v) got2 = { n, v } end
function panels:setTint(t) tint2 = t or "cleared" end
local ok4, e4 = pcall(env.paintDamage, panels, 0.4)
check("a part with no own Material takes `damage` through setShaderParam", ok4 and got2
  and got2[1] == "damage" and math.abs(got2[2] - 0.6) < 1e-6, tostring(e4))
check("...and is not darkened with a tint on top", tint2 == nil, tostring(tint2))

-- A part whose every engine call raises: still no error out of the controller.
local hostile = { valid = true, name = "PartWeird" }
function hostile:getcomponent() error("boom") end
function hostile:material() error("boom") end
function hostile:setTint() error("boom") end
function hostile:setShaderParam() error("boom") end
local ok3, e3 = pcall(env.paintDamage, hostile, 0.5)
check("a part whose calls all raise cannot take the controller down", ok3, tostring(e3))
check("a nil or dead part is ignored", pcall(env.paintDamage, nil, 0.5)
  and pcall(env.paintDamage, { valid = false }, 0.5))

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_part_damage: %d checks passed", passes))
