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
--     the first-person tools' gloves name, exists;
--   * the soft suit is SKINNED, not pieces: the gloves are weighted to the
--     finger chain and the thumb bones, every limb joint blends its two bones
--     somewhere (no rigid piece per bone), and the suit keeps its budget
--     (at most 16,500 triangles, five materials);
--   * the HELMET that comes off: helmet / visor / lamps are plain (unskinned)
--     models, the scene hangs the Helmet on the AstroModel's Back bone (an
--     attachment) with the Visor and the Lamps under it, each dressed for the
--     materials it names, and the Astronaut runs scripts/suit.lua after the
--     tool belt (its hands go to the neck ring over the tool's hold).
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
    -- the skin itself: read JOINTS_0 / WEIGHTS_0 out of the binary chunk
    local _, raw = glb_json(path)
    local bin0 = 20 + u32(raw, 13) + 8          -- 0-based offset of the BIN chunk's data
    local acc, views = {}, {}
    for a in (js:match('"accessors":(%b[])') or ""):gmatch("%b{}") do
      acc[#acc + 1] = { view = tonumber(a:match('"bufferView":(%d+)')), count = tonumber(a:match('"count":(%d+)')),
                        off = tonumber(a:match('"byteOffset":(%d+)')) or 0 }
    end
    for v in (js:match('"bufferViews":(%b[])') or ""):gmatch("%b{}") do
      views[#views + 1] = tonumber(v:match('"byteOffset":(%d+)')) or 0
    end
    local tris, prims = 0, 0
    local used = {}                              -- bone name → vertices weighted to it
    local pair = {}                              -- "a|b" → vertices blending both
    for attrs, ind in (js:match('"meshes":(%b[])') or ""):gmatch('"attributes":(%b{}),"indices":(%d+)') do
      prims = prims + 1
      tris = tris + acc[tonumber(ind) + 1].count / 3
      local ja, wa = tonumber(attrs:match('"JOINTS_0":(%d+)')), tonumber(attrs:match('"WEIGHTS_0":(%d+)'))
      if ja and wa then
        local A, W = acc[ja + 1], acc[wa + 1]
        local po, pw = bin0 + views[A.view + 1] + A.off, bin0 + views[W.view + 1] + W.off
        for v = 0, A.count - 1 do
          local bs = {}
          for q = 0, 3 do
            local w = raw:byte(pw + v * 4 + q + 1)
            if w > 12 then bs[#bs + 1] = BONES[raw:byte(po + v * 4 + q + 1) + 1] end
          end
          for i = 1, #bs do
            used[bs[i]] = (used[bs[i]] or 0) + 1
            for j = 1, #bs do if i ~= j then pair[bs[i] .. "|" .. bs[j]] = (pair[bs[i] .. "|" .. bs[j]] or 0) + 1 end end
          end
        end
      end
    end
    ok(tris > 0 and tris <= 16500, string.format("%s: %d triangles, the budget is 16,500", path, tris))
    ok(prims <= 5, string.format("%s: %d materials, the budget is five", path, prims))
    for _, sd in ipairs({ "Left", "Right" }) do
      for _, b in ipairs({ "Fingers1", "Fingers2", "Thumb1", "Thumb2" }) do
        ok((used[b .. "." .. sd] or 0) > 40, string.format("%s: the glove isn't skinned to %s.%s", path, b, sd))
      end
      for _, pj in ipairs({ { "Upperarm", "Forearm" }, { "Forearm", "Hand" }, { "Hand", "Fingers1" },
                            { "Fingers1", "Fingers2" }, { "Thigh", "Shin" }, { "Shin", "Foot" } }) do
        local a, b = pj[1] .. "." .. sd, pj[2] .. "." .. sd
        ok((pair[a .. "|" .. b] or 0) > 20, string.format("%s: nothing blends %s into %s (a joint of rigid pieces)", path, a, b))
      end
      ok((pair["Hip|Thigh." .. sd] or 0) > 20, path .. ": nothing blends the hip into Thigh." .. sd)
    end
    ok((pair["Back|Hip"] or 0) > 20, path .. ": nothing blends the waist (Back into Hip)")
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

-- the helmet's three models: plain models, written by the suit's generator
local HELMET = { { "helmet", "Helmet" }, { "visor", "Helmet Visor" }, { "lamps", "Helmet Lamps" } }
local HMATS = {}
for _, h in ipairs(HELMET) do
  local path = "models/astronaut/" .. h[1] .. "_male.glb"
  local js = glb_json(path)
  ok(js ~= nil, path .. ": not a glb")
  if js then
    ok(js:find('"generator":"Solar tools/gen_suit.py"', 1, true) ~= nil, path .. ": not written by tools/gen_suit.py")
    ok(js:find('"skins"', 1, true) == nil, path .. ": a helmet part must be a plain model (it rides a bone)")
    HMATS[h[1]] = {}
    for m in (js:match('"materials":(%b[])') or ""):gmatch('"name":"([^"]+)"') do HMATS[h[1]][m] = true end
    ok(next(HMATS[h[1]]) ~= nil, path .. ": names no materials")
  end
  ok(exists("models/astronaut/" .. h[1] .. "_female.glb"), h[1] .. "_female.glb missing")
end
local f2 = open("scenes/system.ron")
if f2 then
  local ron = f2:read("*a")
  f2:close()
  local function block(name)
    local s = ron:find('\n        (\n            name: "' .. name .. '",', 1, true)
    if not s then return nil end
    local e = ron:find('\n        ),', s + 10, true)
    return ron:sub(s, e)
  end
  local astro = block("AstroModel")
  local astro_id = astro and tonumber(astro:match("            id: Some%((%d+)%)"))
  local ids = {}
  for _, h in ipairs(HELMET) do
    local b = block(h[2])
    ok(b ~= nil, "system.ron: no " .. h[2] .. " node")
    if b then
      ids[h[1]] = tonumber(b:match("            id: Some%((%d+)%)"))
      ok(b:find('asset_path: "models/astronaut/' .. h[1] .. '_male.glb"', 1, true) ~= nil,
         "system.ron: " .. h[2] .. " doesn't wear " .. h[1] .. "_male.glb")
      local om = b:match("object_materials: (%b{})") or ""
      for m in pairs(HMATS[h[1]] or {}) do
        ok(om:find('"' .. m .. '":', 1, true) ~= nil, "system.ron: " .. h[2] .. "'s object_materials miss " .. m)
      end
      for tex in om:gmatch('Some%("([^"]+%.png)"%)') do ok(exists(tex), "system.ron: helmet texture missing: " .. tex) end
    end
  end
  local hb = block("Helmet")
  if hb then
    ok(tonumber(hb:match("parent_id: Some%((%d+)%)")) == astro_id, "system.ron: the Helmet isn't under the AstroModel")
    ok(hb:find('attachment: Some((\n                bone: "Back",', 1, true) ~= nil,
       "system.ron: the Helmet doesn't ride the Back bone")
    local sc = hb:match("scale: %(([%d%.]+), [%d%.]+, [%d%.]+%),\n                %),\n            %)%)")
    ok(sc and math.abs(tonumber(sc) - 2.0) < 1e-3, "system.ron: the Helmet's offset must undo the armature's ½ scale")
  end
  for _, part in ipairs({ "visor", "lamps" }) do
    local b = block(part == "visor" and "Helmet Visor" or "Helmet Lamps")
    ok(b and tonumber(b:match("parent_id: Some%((%d+)%)")) == ids.helmet, "system.ron: the " .. part .. " isn't under the Helmet")
  end
  local an = block("Astronaut") or ""
  local tb, su = an:find('kind: "tool_belt",', 1, true), an:find('kind: "suit",', 1, true)
  ok(su ~= nil, "system.ron: the Astronaut doesn't run scripts/suit.lua")
  ok(tb and su and su > tb, "system.ron: suit.lua must come after tool_belt on the Astronaut")
end
ok(exists("scripts/suit.lua"), "scripts/suit.lua missing")

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
