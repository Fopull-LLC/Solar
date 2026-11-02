-- EXPORTTOOLS: in an EXPORTED build's player (tools/perf/exporttools.sh), does
-- the crew hold a tool you can see? A COPY of the player's save loaded as
-- CONTINUE does; each gear prefab's model read from the build (assets.readBytes);
-- each tool taken in hand (tool_belt.hold) and its third-person model node
-- checked (spawned, a model, shown) and photographed over the shoulder; the
-- flashlight added to the pack and lit. `XT` lines, `XT RESULT PASS|FAIL`.
defaults = { quit = 1 }
local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("XT %7.2f " .. fmt, W() - W0, ...)) end
local CO
local fails = 0
local function yield() coroutine.yield() end
local function hold(s) local t = W() + s; while W() < t do yield() end end
local function wait_for(fn, tmo) local t = W() + tmo; while W() < t do local r = fn(); if r then return r end; yield() end end
local function check(name, ok, fmt, ...)
  P("%s %s: " .. fmt, ok and "PASS" or "FAIL", name, ...)
  if not ok then fails = fails + 1 end
end
local pending = 0
local function shot(name)
  pending = pending + 1
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true }, function(bytes)
    pending = pending - 1
    if bytes then assets.writeBytes("user://exporttools/" .. name .. ".png", bytes); P("SHOT %s", name) end
  end)
  if not ok then pending = pending - 1 end
  hold(0.5)
end
-- a picture from a photo camera beside the crew (the tool in the hands faces
-- it), parented to the AstroModel: a world position written here would be a
-- tick of the planet's travel stale (metres) by the time it renders
local pcam
local function side_shot(name)
  local a = find("Astronaut")
  if not a then return end
  local m
  for _, c in ipairs(a:children()) do if c.name == "AstroModel" then m = c end end
  if not m then return end
  if not (pcam and pcam.valid) then
    spawn("FlagPhotoCam", vec3(a.x, a.y, a.z), function(n) pcam = n end)
    wait_for(function() return pcam end, 5)
  end
  if pcam:getParent() ~= m then pcam:setParent(m, { keepWorld = false }) end
  -- in front and to the crew's right (+X is its left), chest height, looking back
  local ox, oy, oz = -1.2, 1.25, 1.6
  pcam.x, pcam.y, pcam.z = ox, oy, oz
  pcam:setAngles(math.atan2(ox, oz), -0.12, 0)
  hold(0.6)
  pending = pending + 1
  local ok = pcall(camera.capture, pcam, { w = 1280, h = 720, ui = false }, function(bytes)
    pending = pending - 1
    if bytes then assets.writeBytes("user://exporttools/" .. name .. ".png", bytes); P("SHOT %s", name) end
  end)
  if not ok then pending = pending - 1 end
  hold(0.6)
end
local function has(path)
  local ok, b = pcall(assets.readBytes, path)
  return ok and b ~= nil and #b > 0
end
local function prefab_models(name)
  local ok, t = pcall(assets.readText, "prefabs/" .. name .. ".prefab.ron")
  if not (ok and t) then return nil end
  local out = {}
  for p in t:gmatch('"([%w_/%-%.]+%.glb)"') do out[#out + 1] = p end
  for p in t:gmatch('"(textures/[%w_/%-%.]+%.png)"') do out[#out + 1] = p end
  return out
end
local function main(node)
  node.persistent = true
  save.slot("slot1")
  if app.setDisplayMode then pcall(app.setDisplayMode, { width = 1280, height = 720, fullscreen = false }) end
  scene.load("system")
  yield()
  local ok = wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and pw.onFoot
  end, 200)
  P("ready %s", tostring(ok ~= nil))
  local wx = findScript("weather"); if wx and wx.force then pcall(wx.force, "clear") end
  local tb = findScript("tool_belt")
  local inv = findScript("inventory")
  local I = findScript("items")
  -- 1. the files, read through the build's own asset loader
  local names = {}
  for _, id in ipairs(tb.HELD_MODELS or {}) do
    local d = tb.TOOLDEF[id]
    names[#names + 1] = d.prefab; names[#names + 1] = d.fp_prefab
  end
  for _, id in ipairs(I.ids()) do
    local d = I.def(id)
    if d.hold and d.hold.prefab then names[#names + 1] = d.hold.prefab end
    if d.worn and d.worn.prefab then names[#names + 1] = d.worn.prefab end
  end
  local missing, n = {}, 0
  for _, nm in ipairs(names) do
    local list = prefab_models(nm)
    if not list then missing[#missing + 1] = "prefabs/" .. nm .. ".prefab.ron"
    else for _, p in ipairs(list) do n = n + 1; if not has(p) then missing[#missing + 1] = p end end end
  end
  check("files", #missing == 0, "%d gear prefabs, %d model/texture files they load, missing: %s", #names, n, table.concat(missing, " "))
  -- 2. each tool in hand, its model shown, over the shoulder
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  for _, id in ipairs(tb.HELD_MODELS or {}) do
    if inv.gearCount and inv.gearCount("astro", id) < 1 then inv.addGear("astro", id, 1) end
    pcall(tb.hold, id)
    hold(2.0)
    local d = tb.TOOLDEF[id]
    local m = find(d.prefab)
    local mp = m and m.model
    local shown = m and m.visible
    if cam and cam.face and a then
      local u = vec3(a.up_x or 0, a.up_y or 1, a.up_z or 0)
      local f = u:cross(vec3(1, 0, 0)):normalized()
      cam.face(f.x, f.y, f.z, -0.15)
    end
    hold(1.0)
    check("held_" .. id, tb.toolId() == id and m ~= nil and mp ~= nil and has(mp) and shown == true,
      "in hand %s; model node %s, model %s (in the build: %s), visible %s", tostring(tb.toolId()), tostring(m ~= nil),
      tostring(mp), tostring(mp and has(mp)), tostring(shown))
    shot("held_" .. id)
    side_shot("side_" .. id)
  end
  -- 3. the flashlight
  local fl = findScript("flashlight")
  if fl then
    inv.addGear("astro", "flashlight", 1)
    hold(1.0)
    fl.sim = { pressed = true }
    hold(1.5)
    local fm = find("ItemFlashlight")
    check("flashlight", fl.on == true and (fl.lit or 0) > 0 and fm ~= nil and fm.model ~= nil and has(fm.model),
      "on %s, light %.2f, model %s", tostring(fl.on), fl.lit or -1, tostring(fm and fm.model))
    local ln = find("Lighting")
    local lc = ln and ln:getcomponent("Light")
    if lc then lc.intensity = 0 end
    hold(0.5)
    shot("flashlight_night")
    side_shot("side_flashlight_night")
  else
    check("flashlight", false, "no flashlight script in the build")
  end
  wait_for(function() return pending <= 0 end, 20)
  P("RESULT %s (%d failed)", fails == 0 and "PASS" or "FAIL", fails)
  if params.quit > 0 then app.quit() end
end
function update(node, dt)
  if not CO then CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO, node)
    if not ok then P("ERROR %s", tostring(err)); P("RESULT FAIL (error)"); app.quit() end
  end
end
