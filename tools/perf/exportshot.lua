-- EXPORTSHOT: pictures from an EXPORTED build's player (tools/perf/exportshot.sh):
-- a COPY of the player's save loaded as CONTINUE does, then 1280x720 pictures of
-- the ground at the crew's feet (the free camera looking down from 1.6 m and from
-- 6 m) and the view out, for an A/B of the build's texture sampling with and
-- without .floptle/textures.ron (engine card 0550). `XS` lines.
defaults = { quit = 1 }
local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("XS %7.2f " .. fmt, W() - W0, ...)) end
local CO
local pending = 0
local function yield() coroutine.yield() end
local function hold(s) local t = W() + s; while W() < t do yield() end end
local function wait_for(fn, tmo) local t = W() + tmo; while W() < t do local r = fn(); if r then return r end; yield() end end
local function shot(name)
  pending = pending + 1
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://exportshot/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1 end
  hold(0.4)
end
local function main(node)
  node.persistent = true
  save.slot("slot1")
  if app.setDisplayMode then pcall(app.setDisplayMode, { width = 1280, height = 720, fullscreen = false }) end
  scene.load("system")
  yield()
  local ok = wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 200)
  P("ready %s", tostring(ok ~= nil))
  local wx = findScript("weather"); if wx and wx.force then wx.force("clear") end
  hold(4)
  shot("1_view")
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local b = space.body(save.get("base.body"))
  if cam and cam.setFreecam and a and b then
    cam.setFreecam(true); hold(0.3)
    if cam.setTimeFreeze then cam.setTimeFreeze(true) end
    local u = vec3(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
    local r = vec3(a.x - b.x, a.y - b.y, a.z - b.z):length()
    for _, e in ipairs({ { "2_feet", 1.6, -1.2 }, { "3_ground6m", 6, -0.9 } }) do
      local fc = cam.freecamState()
      fc.body = b.name
      fc.rel = u * (r + e[2])
      fc.pitch = e[3]
      local f = u:cross(vec3(1, 0, 0))
      fc.ref = f:normalized()
      hold(3)
      shot(e[1])
    end
  end
  wait_for(function() return pending <= 0 end, 20)
  P("DONE")
  if params.quit > 0 then app.quit() end
end
function update(node, dt)
  if not CO then CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO, node)
    if not ok then P("ERROR %s", tostring(err)); app.quit() end
  end
end
