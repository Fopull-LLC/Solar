-- TOOLSTAND: the hand tools on a bench, no world. Spawns the third-person and
-- first-person tool prefabs (tools/gen_tools.py) under a fixed key light and
-- photographs each from a few sides, the view models framed as tool_belt
-- frames them (VIEW_AT, VM_FOV), then poses the articulated parts (claws,
-- heat sink) if the model has them and photographs that too.
-- Run by tools/perf/toolstand.sh; pictures land in user://toolstand/.
--
-- protos = 1 (toolstand.sh PROTOS=DIR): the LASER DESIGN SHEET instead — the
-- gravity gun and each laser design (ToolLaser<V>, V in TL7 A B C) from the
-- 3/4 front, the left side and first person, under one light; the energy
-- parts idle in the 3/4 view and working (charge, heat) in the others.
-- charge / heat: the energy uniforms the ordinary stand's tools wear.
defaults = { quit = 1, pose = 1, toe = 7.0, cant = 0.0, sweep = 0, vax = 0.21, vay = -0.265, vaz = -0.6, vmfov = 0.95,
  ggx = 0, ggy = 0, ggz = 0, lgx = 0, lgy = 0, lgz = 0, protos = 0, charge = 0.3, heat = 0.0, wcharge = 0.9,
  wheat = 0.7,
  -- the held items' FP_ITEMS (toolstand.sh reads them from tool_belt.lua)
  kitx = 0, kity = 0, kitz = 0, kitgx = 0, kitgy = 0, kitgz = 0, medx = 0, medy = 0, medz = 0, medgx = 0, medgy = 0, medgz = 0, gasx = 0, gasy = 0, gasz = 0, gasgx = 0, gasgy = 0, gasgz = 0, beax = 0, beay = 0, beaz = 0, beagx = 0, beagy = 0, beagz = 0, flgx = 0, flgy = 0, flgz = 0, flggx = 0, flggy = 0, flggz = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("TS %7.2f " .. fmt, W() - W0, ...)) end
local CO, pending = nil, 0
local function yield() coroutine.yield() end
local function frames(n) for _ = 1, n do yield() end end

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 960, h = 640, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://toolstand/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

-- tool_belt's VIEW_AT, VM_FOV and RIG_FP grips: toolstand.sh reads them out of
-- scripts/tool_belt.lua and passes them in as params.
local VIEW_AT, VM_FOV

local made = {}
local function put(prefab, x, fn)
  spawn(prefab, vec3(x, 0, 0), function(n) made[prefab] = n; if fn then fn(n) end end)
end

local function energy(n, c, h)
  pcall(function() n:setShaderParam("charge", c); n:setShaderParam("heat", h) end)
end

local function light()
  local L = find("Lighting"):getcomponent("Light")
  L.directionX, L.directionY, L.directionZ = -0.45, -0.75, -0.5
  L.colorR, L.colorG, L.colorB = 1.0, 0.95, 0.88
  L.intensity = 2.6
  L.ambientR, L.ambientG, L.ambientB = 0.32, 0.33, 0.36
  pcall(function() L.fog = false end)
  createNode("Floor", nil, function(n) n:setPrimitive("Cube", { 0.42, 0.41, 0.39 }); n.x, n.y, n.z = 30, -0.35, 0; n.scale_x, n.scale_y, n.scale_z = 400, 0.1, 400 end)
end

-- yaw about Y, then pitch about X, then roll about Z (node:setAngles)
local function rot(yw, pt, rl, v)
  local x, y, z = v[1], v[2], v[3]
  x, y = x * math.cos(rl) - y * math.sin(rl), x * math.sin(rl) + y * math.cos(rl)
  y, z = y * math.cos(pt) - z * math.sin(pt), y * math.sin(pt) + z * math.cos(pt)
  x, z = x * math.cos(yw) + z * math.sin(yw), -x * math.sin(yw) + z * math.cos(yw)
  return { x, y, z }
end

-- THE DESIGN SHEET: row by row, the gravity gun then each laser design.
local function protos_main()
  light()
  local rows = { { "GG", "ToolGravGun", "ToolGravGunFP", { params.ggx, params.ggy, params.ggz } } }
  for _, v in ipairs({ "TL7", "A", "B", "C" }) do
    rows[#rows + 1] = { v, "ToolLaser" .. v, "ToolLaser" .. v .. "FP", { params.lgx, params.lgy, params.lgz } }
  end
  for i, r in ipairs(rows) do
    put(r[2], (i - 1) * 10)
    put(r[3], (i - 1) * 10 + 100)
  end
  frames(40)
  local cam = find("Camera")
  local VA = { params.vax, params.vay, params.vaz }
  for _, r in ipairs(rows) do
    local n, f = made[r[2]], made[r[3]]
    if not (n and f) then P("MISSING %s", r[1]) else
      local t = vec3(n.x, n.y, n.z)
      local function at(dist, yaw, pitch, name)
        cam.x = t.x + dist * math.cos(pitch) * math.sin(yaw)
        cam.y = t.y + dist * math.sin(pitch)
        cam.z = t.z + dist * math.cos(pitch) * math.cos(yaw)
        cam:lookAt(t, vec3(0, 1, 0))
        cam:setCamera { fovY = 0.6 }
        frames(8)
        shot(r[1] .. "_" .. name)
        frames(4)
      end
      energy(n, params.charge, params.heat)
      at(1.45, math.rad(-128), math.rad(16), "q")          -- 3/4 front, from the left
      energy(n, params.wcharge, params.wheat)
      at(1.45, math.rad(-90), math.rad(3), "side")          -- the left side, working
      -- first person, framed as tool_belt frames the view model (VIEW_AT, the
      -- toe-in and cant, VM_FOV), working
      energy(f, params.wcharge, params.wheat)
      local ox = f.x
      local yw, pt, rl = math.atan(VA[1] / params.toe), math.atan(-VA[2] / params.toe), params.cant
      local rg = rot(yw, pt, rl, r[4])
      f.x, f.y, f.z = ox + VA[1] - rg[1], VA[2] - rg[2], VA[3] - rg[3]
      f:setAngles(yw, pt, rl)
      cam.x, cam.y, cam.z = ox, 0, 0
      cam:setAngles(0, 0, 0)
      cam:setCamera { fovY = params.vmfov }
      frames(8)
      shot(r[1] .. "_fp")
      frames(4)
    end
  end
  local t = W() + 15
  while pending > 0 and W() < t do yield() end
  P("DONE")
  if params.quit > 0 then app.quit() end
end

local function main()
  if params.protos > 0 then return protos_main() end
  local L = find("Lighting"):getcomponent("Light")
  L.directionX, L.directionY, L.directionZ = -0.45, -0.75, -0.5
  L.colorR, L.colorG, L.colorB = 1.0, 0.95, 0.88
  L.intensity = 2.6
  L.ambientR, L.ambientG, L.ambientB = 0.32, 0.33, 0.36
  pcall(function() L.fog = false end)
  -- a backdrop: a grey floor and wall far behind
  createNode("Floor", nil, function(n) n:setPrimitive("Cube", { 0.42, 0.41, 0.39 }); n.x, n.y, n.z = 30, -0.35, 0; n.scale_x, n.scale_y, n.scale_z = 200, 0.1, 200 end)
  VIEW_AT = { params.vax, params.vay, params.vaz }
  VM_FOV = params.vmfov
  put("ToolGravGun", 0)
  put("ToolLaser", 10)
  put("ToolGravGunFP", 20)
  put("ToolLaserFP", 30)
  frames(30)
  for _, n in pairs(made) do energy(n, params.charge, params.heat) end
  for k, n in pairs(made) do
    local bones = n.bones and n:bones() or {}
    local names = {}
    for _, b in ipairs(bones) do names[#names + 1] = type(b) == "table" and tostring(b.name or b[1]) or tostring(b) end
    P("MODEL %s bones %d [%s] materials %d", k, #bones, table.concat(names, ","), #(n.materials and n:materials() or {}))
  end
  local cam = find("Camera")
  local function view(target, dist, yaw, pitch, name, fov)
    local cx = target.x + dist * math.cos(pitch) * math.sin(yaw)
    local cy = target.y + dist * math.sin(pitch)
    local cz = target.z + dist * math.cos(pitch) * math.cos(yaw)
    cam.x, cam.y, cam.z = cx, cy, cz
    cam:lookAt(target, vec3(0, 1, 0))
    cam:setCamera { fovY = fov or 0.6 }
    frames(6)
    shot(name)
    frames(4)
  end
  local function tp_set(tag, n)
    local t = vec3(n.x, n.y, n.z)
    view(t, 1.5, math.rad(-60), math.rad(18), tag .. "_q_left")
    view(t, 1.5, math.rad(-90), math.rad(4), tag .. "_side_left")
    view(t, 1.5, math.rad(90), math.rad(4), tag .. "_side_right")
    view(t, 1.5, math.rad(140), math.rad(30), tag .. "_q_rear_right")
    view(t, 1.2, math.rad(-170), math.rad(8), tag .. "_front")
    view(t, 1.5, math.rad(-90), math.rad(80), tag .. "_top")
  end
  tp_set("grav", made.ToolGravGun)
  tp_set("laser", made.ToolLaser)
  -- the view models, framed as tool_belt frames them: the camera at the origin
  -- of a frame 20/30 m along X, looking down -Z
  -- yaw about Y, then pitch about X, then roll about Z (node:setAngles)
  local function rot(yw, pt, rl, v)
    local x, y, z = v[1], v[2], v[3]
    x, y = x * math.cos(rl) - y * math.sin(rl), x * math.sin(rl) + y * math.cos(rl)
    y, z = y * math.cos(pt) - z * math.sin(pt), y * math.sin(pt) + z * math.cos(pt)
    x, z = x * math.cos(yw) + z * math.sin(yw), -x * math.sin(yw) + z * math.cos(yw)
    return { x, y, z }
  end
  local function fp_shot(tag, n, grip)
    local ox = n.x
    -- variants: toe-in distance (m), cant (rad), VIEW_AT
    local variants = {
      { "", params.toe, params.cant, VIEW_AT },
    }
    if params.sweep > 0 then
      variants = {
        { "_A", 2.0, -0.20, VIEW_AT },
        { "_B", 2.0, -0.30, { 0.23, -0.235, -0.60 } },
        { "_C", 2.5, -0.35, { 0.25, -0.22, -0.62 } },
        { "_D", 1.6, -0.25, { 0.22, -0.25, -0.58 } },
      }
    end
    for _, v in ipairs(variants) do
      local va = v[4]
      local yw, pt, rl = math.atan(va[1] / v[2]), math.atan(-va[2] / v[2]), v[3]
      local rg = rot(yw, pt, rl, grip)
      n.x, n.y, n.z = ox + va[1] - rg[1], va[2] - rg[2], va[3] - rg[3]
      n:setAngles(yw, pt, rl)
      cam.x, cam.y, cam.z = ox, 0, 0
      cam:setAngles(0, 0, 0)
      cam:setCamera { fovY = VM_FOV }
      frames(6)
      shot(tag .. "_fp" .. v[1])
      frames(4)
    end
    n.x = ox
    local t = vec3(n.x, n.y, n.z)
    view(t, 1.4, math.rad(-60), math.rad(20), tag .. "_fp_q_left")
    view(t, 1.4, math.rad(60), math.rad(10), tag .. "_fp_q_right")
  end
  fp_shot("grav", made.ToolGravGunFP, { params.ggx, params.ggy, params.ggz })
  fp_shot("laser", made.ToolLaserFP, { params.lgx, params.lgy, params.lgz })
  -- the gloves up close (playtest 2026-11-04: the hands), the model square on
  local function hands_close(tag, n, grip, fore)
    n:setAngles(0, 0, 0)
    local g = vec3(n.x + grip[1], n.y + grip[2], n.z + grip[3])
    view(g, 0.45, math.rad(-35), math.rad(25), tag .. "_hand_r_back")
    view(g, 0.45, math.rad(150), math.rad(10), tag .. "_hand_r_front")
    view(g, 0.45, math.rad(-110), math.rad(5), tag .. "_hand_r_thumb")
    local f = vec3(n.x + fore[1], n.y + fore[2], n.z + fore[3])
    view(f, 0.45, math.rad(-80), math.rad(20), tag .. "_hand_l_back")
    view(f, 0.45, math.rad(100), math.rad(10), tag .. "_hand_l_inside")
  end
  hands_close("grav", made.ToolGravGunFP, { params.ggx, params.ggy, params.ggz }, { params.ggx, 0.091, -0.251 })
  hands_close("laser", made.ToolLaserFP, { params.lgx, params.lgy, params.lgz }, { params.lgx, 0.078, -0.189 })
  -- THE HELD ITEMS' view models (tool_belt FP_ITEMS: each built in the view's
  -- frame, placed at its centre `at`), framed as the game frames them, then
  -- from beside and up close
  for i, it in ipairs({ { "kit", "ItemRepairKitFP", "kit" }, { "med", "ItemMedkitFP", "med" }, { "gas", "ItemGasCanFP", "gas" },
                        { "beacon", "ItemBeaconStowedFP", "bea" }, { "flag", "ItemFlagFurledFP", "flg" } }) do
    local ox = 60 + i * 10
    local n
    spawn(it[2], vec3(ox, 0, 0), function(x) n = x end)
    frames(20)
    if not n then P("MISSING %s", it[2]) else
      local at = { params[it[3] .. "x"] or 0, params[it[3] .. "y"] or 0, params[it[3] .. "z"] or 0 }
      local gp = { params[it[3] .. "gx"] or 0, params[it[3] .. "gy"] or 0, params[it[3] .. "gz"] or 0 }
      n.x, n.y, n.z = ox + at[1], at[2], at[3]
      n:setAngles(0, 0, 0)
      cam.x, cam.y, cam.z = ox, 0, 0
      cam:setAngles(0, 0, 0)
      cam:setCamera { fovY = VM_FOV }
      frames(6)
      shot("item_" .. it[1] .. "_fp")
      frames(4)
      local g = vec3(n.x + gp[1], n.y + gp[2], n.z + gp[3])
      local s = at[1] < 0 and -1 or 1
      view(g, 0.5, math.rad(s * 70), math.rad(20), "item_" .. it[1] .. "_side")
      view(g, 0.32, math.rad(s * 25 + 180), math.rad(35), "item_" .. it[1] .. "_hand")
    end
  end
  -- the articulation
  if params.pose > 0 then
    for _, k in ipairs({ "ToolGravGun", "ToolLaser", "ToolGravGunFP", "ToolLaserFP" }) do
      local n = made[k]
      local an = n.animator and n:animator()
      local ids = {}
      for _, b in ipairs({ "ClawTop", "ClawLeft", "ClawRight", "Focus" }) do
        local ok, i = pcall(function() return an:boneIndex(b) end)
        ids[b] = ok and i or "-"
      end
      local s = {}
      for b, i in pairs(ids) do s[#s + 1] = b .. "=" .. tostring(i) end
      P("POSE %s animator %s bones {%s}", k, tostring(an ~= nil), table.concat(s, " "))
    end
    local g = made.ToolGravGun
    local an = g:animator()
    local function open(a)
      if not (an and an.setBoneRot) then return end
      an:holdPose(true)
      for _, b in ipairs({ "ClawTop", "ClawLeft", "ClawRight" }) do an:setBoneRot(b, 0, a, 0) end
    end
    for f = 1, 12 do open(0.55); yield() end
    view(vec3(g.x, g.y, g.z), 1.2, math.rad(-140), math.rad(15), "grav_claws_open")
    for f = 1, 12 do open(-0.2); yield() end
    view(vec3(g.x, g.y, g.z), 1.2, math.rad(-140), math.rad(15), "grav_claws_closed")
    local lz = made.ToolLaser
    local ok, err = pcall(function()
      local m = lz:material("HeatGlow")
      m.emissive = { 1.0, 0.35, 0.08 }
      m.emissiveStrength = 3.0
    end)
    P("heat material write %s %s", tostring(ok), tostring(err))
    view(vec3(lz.x, lz.y, lz.z), 1.5, math.rad(-60), math.rad(18), "laser_hot")
  end
  local t = W() + 15
  while pending > 0 and W() < t do yield() end
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  if not CO then CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
