-- SMOKE: every rotation in every prefab is a unit quaternion.
--
-- A generator handed quat_from_basis a MIRRORED basis (det -1), which has no
-- quaternion, and wrote (0, 0, 0, 0.707) for the kit stairs' ramp, rails and
-- the hab rings' wall boxes: the engine normalises that to "no turn", so the
-- stairs' walking surface was a flat slab 1.15 m up and the rails a pair of
-- level planks (playtest 2026-11-09: "i cant go up stairs ... i just get
-- pushed off to the side"). tools/base_models.py now flips a mirrored basis;
-- this catches the next generator that writes a non-unit rotation.
--
--   luajit solar/tests/smoke_prefab_rotations.lua

local failures, checked, files = {}, 0, 0
local p = io.popen('ls solar/prefabs/*.ron 2>/dev/null')
for path in p:lines() do
  local f = io.open(path)
  if f then
    files = files + 1
    local s = f:read("*a")
    f:close()
    for a, b, c, d in s:gmatch("rotation:%s*%(%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*%)") do
      local x, y, z, w = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
      if x and y and z and w then
        checked = checked + 1
        local n = math.sqrt(x * x + y * y + z * z + w * w)
        if math.abs(n - 1) > 0.01 then
          failures[#failures + 1] = string.format("%s: rotation (%s, %s, %s, %s) has length %.3f", path:match("[^/]+$"), a, b, c, d, n)
        end
      end
    end
  end
end
p:close()

if files == 0 then
  print("FAIL smoke_prefab_rotations: no prefabs found (run from the folder holding solar/)")
  os.exit(1)
end
if #failures > 0 then
  for i = 1, math.min(#failures, 20) do print("FAIL " .. failures[i]) end
  print(string.format("smoke_prefab_rotations: %d of %d rotations in %d prefabs are not unit", #failures, checked, files))
  os.exit(1)
end
print(string.format("smoke_prefab_rotations: OK (%d rotations in %d prefabs)", checked, files))
