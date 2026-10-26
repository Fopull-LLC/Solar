-- TOOLSTAND: the hand tools on a bench, no world. Spawns the third-person and
-- first-person tool prefabs (tools/gen_tools.py) under a fixed key light and
-- photographs each from a few sides, the view models framed as tool_belt
-- frames them (VIEW_AT, VM_FOV), then poses the articulated parts (claws,
-- heat sink) if the model has them and photographs that too.
-- Run by tools/perf/toolstand.sh; pictures land in user://toolstand/.
defaults = { quit = 1, pose = 1, toe = 7.0, cant = 0.0, sweep = 0, vax = 0.21, vay = -0.265, vaz = -0.6, vmfov = 0.95,
  ggx = 0, ggy = 0, ggz = 0, lgx = 0, lgy = 0, lgz = 0 }

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

local function main()
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
