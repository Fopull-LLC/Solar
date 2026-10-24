-- SMOKE HARNESS for THE EVA SUIT — the crew's model (tools/gen_suit.py).
--
-- The suit is a new mesh on the OLD rig, and everything that moves the crew
-- (the clips, the walker's leg and look IK, the tool belt's arm IK, the
-- command seat) is written against that rig's bone names and rest pose. So:
--
--   * both suits carry the 25 bones by name, the armature root at its scale, and the
--     skin lists them in the order the clips were authored against;
--   * the rest-pose box (the engine places a rig by its centre) is the old
--     body's, so the AstroModel's −0.05 offset and the walker's MA_UP still hold;
--   * every material the suit names is dressed by the AstroModel's
--     object_materials in scenes/system.ron, and every texture those name, and
--     the first-person tools' gloves name, exists.
--
--   luajit solar/tests/smoke_suit.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local function open(p)
  return io.open("solar/" .. p, "rb") or io.open(p, "rb")
end
local function exists(p)
  local f = open(p)
  if f then f:close() end
  return f ~= nil
end

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

-- The glb's JSON chunk.
local function glb_json(p)
  local f = open(p)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if s:sub(1, 4) ~= "glTF" then return nil end
  local len = u32(s, 13)
  return s:sub(21, 20 + len), s
end

local BONES = { "Back", "Hip", "Thigh.Right", "Shin.Right", "Foot.Right", "Toes.Right", "Thigh.Left", "Shin.Left",
                "Foot.Left", "Toes.Left", "Upperarm.Right", "Forearm.Right", "Hand.Right", "Fingers1.Right",
                "Fingers2.Right", "Thumb1.Right", "Thumb2.Right", "Head", "Upperarm.Left", "Forearm.Left",
                "Hand.Left", "Fingers1.Left", "Fingers2.Left", "Thumb1.Left", "Thumb2.Left" }
-- the old Blender bodies' rest boxes (centre), which the engine places by
local CENTRE = { male = { -0.5, 0.93782, -0.00412 }, female = { 0.50126, 0.89694, -0.02316 } }

local MATS = {}
for _, sex in ipairs({ "male", "female" }) do
  local path = "models/astronaut/astronaut_" .. sex .. ".glb"
  local js = glb_json(path)
  ok(js ~= nil, path .. ": not a glb")
  if js then
    ok(js:find('"generator":"Solar tools/gen_suit.py"', 1, true) ~= nil, path .. ": not written by tools/gen_suit.py")
    -- node names in file order
    local nodes_s = js:match('"nodes":(%[{.-}%])')
    local names = {}
    for n in (nodes_s or ""):gmatch('"name":"([^"]+)"') do names[#names + 1] = n end
    local have = {}
    for _, n in ipairs(names) do have[n] = true end
    for _, b in ipairs(BONES) do ok(have[b], path .. ": bone " .. b .. " missing") end
    -- the armature root and its scale (the male's is ½, the female's 0.45)
    local root = sex == "male" and "MaleArm" or "FemaleArm"
    local sc = sex == "male" and "0%.5" or "0%.45000001788139343"
    ok(have[root], path .. ": the armature root " .. root .. " is missing")
    ok(nodes_s and nodes_s:find('"name":"' .. root .. '","rotation":%[[^%]]+%],"scale":%[' .. sc .. ',' .. sc .. ',' .. sc .. '%]') ~= nil,
       path .. ": " .. root .. " lost its rest scale")
    -- the skin's joints, by index into the node list, in the clips' order
    local joints = js:match('"skins":%[{.-"joints":(%b[])')
    local k = 0
    for idx in (joints or ""):gmatch("%d+") do
      k = k + 1
      ok(names[tonumber(idx) + 1] == BONES[k], string.format("%s: skin joint %d is %s, want %s", path, k,
         tostring(names[tonumber(idx) + 1]), tostring(BONES[k])))
    end
    ok(k == #BONES, path .. ": the skin has " .. k .. " joints, want " .. #BONES)
    -- the rest-pose box: every primitive's POSITION min/max together
    local lo, hi = { 1e9, 1e9, 1e9 }, { -1e9, -1e9, -1e9 }
    for mn, mx in js:gmatch('"min":%[([^%]]+)%],"max":%[([^%]]+)%]') do
      local a, b = {}, {}
      for v in mn:gmatch("[^,]+") do a[#a + 1] = tonumber(v) end
      for v in mx:gmatch("[^,]+") do b[#b + 1] = tonumber(v) end
      for i = 1, 3 do lo[i] = math.min(lo[i], a[i]); hi[i] = math.max(hi[i], b[i]) end
    end
    for i = 1, 3 do
      local c = (lo[i] + hi[i]) / 2
      ok(math.abs(c - CENTRE[sex][i]) < 2e-4, string.format("%s: rest box centre axis %d is %.5f, want %.5f (the crew would float or sink)",
         path, i, c, CENTRE[sex][i]))
    end
    for m in (js:match('"materials":(%b[])') or ""):gmatch('"name":"([^"]+)"') do MATS[m] = true end
  end
end
ok(next(MATS) ~= nil, "the suits name no materials")

-- the AstroModel's object_materials in scenes/system.ron
local f = open("scenes/system.ron")
ok(f ~= nil, "scenes/system.ron missing")
if f then
  local ron = f:read("*a")
  f:close()
  local s = ron:find('name: "AstroModel"', 1, true)
  ok(s ~= nil, "system.ron: no AstroModel")
  local block = s and ron:sub(s, (ron:find('name: "', s + 20, true) or #ron))
  ok(block and block:find('asset_path: "models/astronaut/astronaut_male.glb"', 1, true) ~= nil,
     "system.ron: the AstroModel doesn't wear the male suit")
  local om = block and block:match("object_materials: (%b{})") or ""
  for m in pairs(MATS) do
    ok(om:find('"' .. m .. '":', 1, true) ~= nil, "system.ron: the AstroModel's object_materials miss " .. m)
  end
  for tex in om:gmatch('Some%("([^"]+%.png)"%)') do ok(exists(tex), "system.ron: suit texture missing: " .. tex) end
end

-- the first-person tools' gloves and sleeves wear the suit's textures
for _, pf in ipairs({ "prefabs/ToolGravGunFP.prefab.ron", "prefabs/ToolLaserFP.prefab.ron" }) do
  local g = open(pf)
  ok(g ~= nil, pf .. " missing")
  if g then
    local t = g:read("*a")
    g:close()
    for _, m in ipairs({ "Glove", "Palm", "Suit", "SuitMetal" }) do
      ok(t:find('"' .. m .. '":', 1, true) ~= nil, pf .. ": no " .. m .. " material")
    end
    ok(t:find("textures/suit/fabric_albedo.png", 1, true) ~= nil, pf .. ": the sleeves aren't the suit's cloth")
    for tex in t:gmatch('Some%("([^"]+%.png)"%)') do ok(exists(tex), pf .. ": texture missing: " .. tex) end
  end
end

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL " .. m) end
  print(string.format("smoke_suit: %d of %d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_suit: all %d checks passed", checks))
