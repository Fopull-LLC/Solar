-- RAINPROBE: the weather's look (the haze under each weather, the morning
-- mist), the rain on the ground (rain_fx.lua: wet ground, puddles, ripples,
-- splashes) and the depth of field, on a COPY of the player's save
-- (tools/perf/rain.sh). Pictures land in user://rain/*.png; numbers as `RX`
-- lines. strs `only` = comma list of parts:
--   info    the world's numbers (radius, air, sea, the base, the sun)
--   wx      clear / overcast / rain / storm at the base and over a valley, at
--           Medium and High (+ the valley in morning mist)
--   splash  heavy rain close up: open ground, the pad, the crew, at Medium and High
--   dof     on foot, third person: the old depth of field (HEAD) and the new,
--           at Medium and High
--   gpu     perf.gpu + script ms in heavy rain at the base, Medium and High:
--           rain_fx on / off interleaved; and clear on foot, old / new DOF
--   rover   a 6-part rover rolled out on the runway: DOF old / new from its
--           chase camera (loads the builder scene; run it last)
-- w, h: the window and the pictures (1280×720 by default: the GPU-safety rule
-- after the 2026-10-26 lockup; pass ("w", 1920.0), ("h", 1080.0) for full size)
defaults = { quit = 1, gpusecs = 3.0, valleyMin = 140, valleyMax = 420, w = 1280, h = 720 }
strs = { only = "info,wx,splash,dof,gpu" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RX %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local NODE, CO
local pending = 0
local OLDDOF = nil         -- { px, taps } the HEAD depth of field, forced every lateUpdate
local GPU = nil            -- sampling
local HELD = {}

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = math.floor(params.w), h = math.floor(params.h), ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://rain/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  hold(0.35)
end

local function post() local n = find("Post Processing"); return n and n:getcomponent("PostProcess") end
local function light() local n = find("Lighting"); return n and n:getcomponent("Light") end

local gx, at, cam, wx, rf
local B
local function body() B = space.body(save.get("base.body")); return B end
local function V(x, y, z) return vec3(x, y, z) end
local function star()
  local best, bk = nil, -1
  for _, b in ipairs(space.bodies() or {}) do
    local k = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
    if k > bk then best, bk = b, k end
  end
  return best
end
local function ground_r(up)
  local b = body()
  local top = V(b.x, b.y, b.z) + up * (b.radius + 400)
  local hit = terrain.raycast(top, up * -1, 900)
  if not hit then return b.radius end
  local dx, dy, dz = hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- the free camera at radius r along `up` (body frame), looking along `fwd`
local function place(up, r, fwd)
  local fc = cam.freecamState()
  fc.body = body().name
  fc.rel = up * r
  local s = math.max(-1, math.min(1, fwd:dot(up)))
  fc.pitch = math.asin(s)
  local f = (fwd - up * s)
  if f:length() < 1e-4 then f = up:cross(V(1, 0, 0)) end
  fc.ref = f:normalized()
end
local function settle(maxs)
  hold(1.0)
  wait_for(function() return not (terrain.busy and terrain.busy()) end, maxs or 15)
  hold(1.0)
end
local function look_from(up_eye, r_eye, target_dir, target_r)
  -- a camera at up_eye·r_eye looking at the point target_dir·target_r (body frame)
  local e = up_eye * r_eye
  local t = target_dir * target_r
  place(up_eye, r_eye, (t - e):normalized())
end

local function weather(name, k, wet, puddles)
  if name == "clear" then wx.force("clear") else wx.force(name, k or 1) end
  wx.forceMist(nil)
  if rf then rf.setWet(wet or 0, puddles or 0) end
  hold(1.2)                       -- the forced weather eases in at 3/s
  if at.snapWeather then at.snapWeather() end
  hold(0.8)
end

local function roof()
  local cn = find("Camera 1")
  if not cn then return "-" end
  local b = body()
  local u = V(cn.x - b.x, cn.y - b.y, cn.z - b.z):normalized()
  local a = find("Astronaut")
  local hit = raycast(V(cn.x, cn.y, cn.z), u, 30, a and { ignore = a } or nil)
  if not hit then return "open sky" end
  return string.format("%s at %.1f m", hit.node and hit.node.name or "?", hit.distance or -1)
end

local function state(tag)
  local L, pc = light(), post()
  local s = wx.sky or {}
  local c = wx.current() or {}
  P("STATE %s level %s | wx %s precip %.2f storm %.2f cover %.2f haze %.2f mist %.2f bank %.2f cloudH %.2f stops %.2f | fog vol %s %.0f..%.0f dens %.5f h %.1f fall %.1f noise %.2f/%.0f sky %.2f rgb %.2f %.2f %.2f | dof f %.1f r %.0f blur %.2f n %s | rain %s rate %.2f wet %.2f pud %.2f",
    tag, gx.level(), tostring(c.type), c.precip or -1, c.storm or -1, c.cover or -1, s.haze or -1, s.mist or -1, s.bank or -1, s.cloudH or -1, s.stops or -1,
    tostring(L.fogVolumetric), L.fogStart or -1, L.fogEnd or -1, L.fogDensity or -1, L.fogHeight or -1, L.fogFalloff or -1, L.fogNoise or -1, L.fogNoiseScale or -1,
    L.fogSky or -1, L.fogColorR or -1, L.fogColorG or -1, L.fogColorB or -1,
    pc.dofFocus or -1, pc.dofRange or -1, pc.dofBlur or -1, tostring(pc.dofSamples),
    rf and tostring(rf.state.shader) or "-", rf and rf.state.rate or -1, rf and rf.state.wet or -1, rf and rf.state.puddles or -1)
  P("ROOF %s: sheltered %s particles %s, ray up: %s; sun %.3f", tag, tostring(c.sheltered), tostring(c.particles), roof(), at.sun_now or -1)
end

local SCRIPTS = { "rain_fx", "weather", "atmosphere", "graphics", "sun_flare" }
local function gpu(tag)
  hold(0.8)
  GPU = { sum = {}, n = 0, total = 0, sms = {}, sn = 0, fms = 0 }
  hold(params.gpusecs)
  local g = GPU; GPU = nil
  local ps = {}
  for k, v in pairs(g.sum) do ps[#ps + 1] = { k, v / math.max(g.n, 1) } end
  table.sort(ps, function(a, b) return a[2] > b[2] end)
  local t = {}
  for _, e in ipairs(ps) do t[#t + 1] = string.format("%s %.3f", e[1], e[2]) end
  local sc = {}
  for _, n in ipairs(SCRIPTS) do sc[#sc + 1] = string.format("%s %.4f", n, (g.sms[n] or 0) / math.max(g.sn, 1)) end
  P("GPU [%s] level %s total %.3f ms (%d samples) frame %.2f ms | %s || cpu %s", tag, gx.level(), g.total / math.max(g.n, 1), g.n,
    g.fms / math.max(g.sn, 1), table.concat(t, ", "), table.concat(sc, ", "))
end

-- the old (HEAD) depth of field: focus 25 m × the world's shadow scale + 1.2 × altitude,
-- range 2.5 × focus, Medium 1.75 px / 8 taps, High 2.25 / 12, Ultra 2.5 / 16
local OLDPX = { Medium = { 1.75, 8 }, High = { 2.25, 12 }, Ultra = { 2.5, 16 } }
local function dof_mode(which)
  if which == "old" then
    OLDDOF = OLDPX[gx.level()] or OLDPX.Medium
  else
    OLDDOF = nil
    gx.setLook("dof", false); hold(0.15); gx.setLook("dof", true)
  end
  hold(0.5)
end

-- ── where ───────────────────────────────────────────────────────────────────
local U0          -- the crew's spawn, body frame unit
local VALLEY      -- { dir, r } the lowest ground found round the base
local function find_valley()
  local b = body()
  local best = nil
  local t = U0:cross(V(0, 1, 0)); if t:length() < 1e-3 then t = U0:cross(V(1, 0, 0)) end
  t = t:normalized()
  local t2 = U0:cross(t):normalized()
  for i = 0, 35 do
    local a = i / 36 * 2 * math.pi
    local h = (t * math.cos(a) + t2 * math.sin(a))
    for _, dist in ipairs({ params.valleyMin, (params.valleyMin + params.valleyMax) / 2, params.valleyMax }) do
      local th = dist / b.radius
      local u = (U0 * math.cos(th) + h * math.sin(th)):normalized()
      local r = ground_r(u)
      if not best or r < best.r then best = { dir = u, r = r, head = h, dist = dist } end
    end
  end
  return best
end

local function pad_site()
  local site = findScript("base_facilities").launchSite("pad")
  return V(site.x, site.y, site.z), V(site.up.x, site.up.y, site.up.z), V(site.fwd.x, site.fwd.y, site.fwd.z)
end

-- the crew out on the open ground past the pad (the player's save may have
-- left them indoors), facing `fwd`
local function put_crew(fwd_back)
  local pad, pu, pf = pad_site()
  local b = body()
  local th = 32 / b.radius
  local u = (pu * math.cos(th) + pf * math.sin(th)):normalized()
  local gr = ground_r(u)
  local a = find("Astronaut")
  local p = V(b.x, b.y, b.z) + u * (gr + 1.2)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  hold(2.0)
  -- the sun held where it is (the free camera's T only holds while it flies)
  if physics and physics.pause then physics.pause(true) end
  return u, pf
end

local function at_base_view()
  -- from over the open ground past the pad, 16 m up, looking back over the pad
  -- at the base (the pad 25 m off, the buildings 90–170 m)
  local pad, pu, pf = pad_site()
  local b = body()
  local th = 25 / b.radius
  local u = (pu * math.cos(th) + pf * math.sin(th)):normalized()
  local gr = ground_r(u)
  local e = u * (gr + 16)
  local t = pad - pf * 110
  place(u, gr + 16, (t - e):normalized())
end

local function at_valley_view()
  local v = VALLEY
  local b = body()
  -- a point 170 m back toward the base from the valley floor, 25 m up,
  -- looking over the floor and on past it
  local back = v.dist - 170
  local th = back / b.radius
  local u = (U0 * math.cos(th) + v.head * math.sin(th)):normalized()
  local gr = ground_r(u)
  local e = u * (gr + 25)
  local t = v.dir * (v.r + 15)
  place(u, gr + 25, (t - e):normalized())
end

-- ── the parts ───────────────────────────────────────────────────────────────
local function info()
  local b = body()
  local w = save.get("world." .. b.name) or {}
  local s = star()
  local a = find("Astronaut")
  local up = V(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
  local sd = V(s.x - a.x, s.y - a.y, s.z - a.z):normalized()
  P("INFO body %s R %.1f atmo %.2f atmoHeight %.1f sea %.1f kind %s moist? base.r %.1f ground at crew %.1f sun elev %.1f deg",
    b.name, b.radius, w.atmo or -1, w.atmoHeight or -1, w.sea or -1, tostring(w.kind), save.get("base.r") or -1, ground_r(up), math.deg(math.asin(up:dot(sd))))
  VALLEY = find_valley()
  P("INFO valley: lowest ground %.1f m (%.1f under the radius) %.0f m from the crew", VALLEY.r, b.radius - VALLEY.r, VALLEY.dist)
end

local WX = { { "clear" }, { "overcast" }, { "rain", 1.25, 1, 0.8 }, { "storm", 1.0, 1, 1 } }
local function wx_part()
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.0)
    for _, where in ipairs({ "base", "valley" }) do
      if where == "base" then at_base_view() else at_valley_view() end
      settle(15)
      for _, w in ipairs(WX) do
        weather(w[1], w[2], w[3], w[4])
        state(string.format("%s_%s_%s", lv, where, w[1])); shot(string.format("wx_%s_%s_%s", lv, where, w[1]))
      end
      if where == "valley" then
        weather("clear")
        wx.forceMist(1); hold(1.0); at.snapWeather(); hold(0.8)
        state(lv .. "_valley_mist"); shot("wx_" .. lv .. "_valley_mist")
        wx.forceMist(nil)
      end
    end
  end
  weather("clear")
  gx.set("Medium")
end

local function splash_part()
  local b = body()
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.0)
    weather("rain", 1.3, 1, 1)
    -- open ground beside the crew: 1.7 m up, looking down 28 degrees
    local pad0, pu0, pf0 = pad_site()
    local h = pu0:cross(pf0):normalized()
    local th = 40 / b.radius
    local u = (pu0 * math.cos(th) + pf0 * math.sin(th)):normalized()
    local gr = ground_r(u)
    local fwd = (h * math.cos(math.rad(28)) - u * math.sin(math.rad(28))):normalized()
    place(u, gr + 1.7, fwd)
    settle(10)
    state(lv .. "_ground"); shot("splash_" .. lv .. "_ground")
    -- the same, dry (the look it replaces)
    rf.setOn(false); hold(0.4); shot("splash_" .. lv .. "_ground_off"); rf.setOn(true); hold(0.4)
    -- the pad deck, from its edge
    local site = findScript("base_facilities").launchSite("pad")
    local pu = V(site.up.x, site.up.y, site.up.z)
    local pf = V(site.fwd.x, site.fwd.y, site.fwd.z)
    local pad = V(site.x, site.y, site.z)
    local right = pu:cross(pf):normalized()
    for _, d in ipairs({ 9, 12, 15, 18, 22 }) do
      local eye = pad + pf * d + right * 4 + pu * 2.2
      place(eye:normalized(), eye:length(), (pad - pf * 2 - eye):normalized())
      hold(0.3)
      if roof() == "open sky" then break end
    end
    settle(8)
    state(lv .. "_pad"); shot("splash_" .. lv .. "_pad")
    rf.setOn(false); hold(0.4); shot("splash_" .. lv .. "_pad_off"); rf.setOn(true); hold(0.4)
    -- the crew in the rain: the astronaut's own camera (third person)
    cam.setFreecam(false); put_crew(); hold(1.0)
    shot("splash_" .. lv .. "_crew")
    cam.setFreecam(true); hold(0.3); cam.setTimeFreeze(true); hold(0.3)
  end
  weather("clear")
  gx.set("Medium")
end

local function dof_part()
  cam.setFreecam(false)
  hold(1.0)
  weather("clear")
  -- the crew past the pad; look out over open ground, and back at the base
  local u, pf = put_crew()
  local away = pf:flatten(u):normalized()
  for _, head in ipairs({ { "out", away }, { "base", away * -1 } }) do
    cam.face(head[2].x, head[2].y, head[2].z, -0.12)
    hold(1.5)
    for _, lv in ipairs({ "Medium", "High" }) do
      gx.set(lv); hold(1.0)
      dof_mode("old"); state("dof_" .. lv .. "_" .. head[1] .. "_old"); shot("dof_" .. lv .. "_" .. head[1] .. "_old")
      dof_mode("new"); state("dof_" .. lv .. "_" .. head[1] .. "_new"); shot("dof_" .. lv .. "_" .. head[1] .. "_new")
      local pc = post(); pc.dofShowFocus = true; hold(0.4); shot("dof_" .. lv .. "_" .. head[1] .. "_band"); pc.dofShowFocus = false
    end
  end
  gx.set("Medium")
  cam.setFreecam(true)
  hold(0.3); cam.setTimeFreeze(true)
  hold(0.5)
end

local function gpu_part()
  cam.setFreecam(false)
  local u, pf = put_crew()
  if physics and physics.pause then physics.pause(false) end   -- (a live frame is measured)
  cam.face(-pf.x, -pf.y, -pf.z, -0.1)     -- toward the pad and the base
  hold(1.0)
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.0)
    weather("rain", 1.3, 1, 1)
    for rep = 1, 3 do
      rf.setOn(true); state("gpu_" .. lv .. "_rain_on"); gpu(lv .. " heavy rain, rain_fx on #" .. rep)
      rf.setOn(false); gpu(lv .. " heavy rain, rain_fx off #" .. rep)
    end
    rf.setOn(true)
    weather("clear")
    for rep = 1, 2 do
      dof_mode("old"); gpu(lv .. " clear, old dof #" .. rep)
      dof_mode("new"); gpu(lv .. " clear, new dof #" .. rep)
    end
  end
  gx.set("Medium")
  cam.setFreecam(true)
end

-- ── rover: rolled out through the builder scene, as perfbench does ─────────
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local HP = math.pi / 2
local ROVER = {
  rec(1, "roverBody", 0, 0.62, 0),
  rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
}
local function key_down(k) HELD[k] = true; input.simulate { key = k, down = true } end
local function key_up(k) HELD[k] = nil; input.simulate { key = k, down = false } end
local function rover_part()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = ROVER })
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local Bd = wait_for(function() local Bd = findScript("builder"); return Bd and Bd.partUids and #Bd.partUids() >= 6 and Bd end, 90)
  if not Bd then P("rover: no builder"); return end
  hold(1.5)
  save.set("shipyard.site", "runway")
  Bd.doLaunch()
  if save.get("shipyard.launch") ~= 1 then Bd.doLaunch() end
  local vc = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting and v.node and v.node.valid then
        local i = assembly.info(v.node)
        if i and i.anchored and #i.parts >= 6 then return v end
      end
    end
  end, 150)
  if not vc then P("rover: no craft"); return end
  gx, at, cam, wx, rf = findScript("graphics"), findScript("atmosphere"), findScript("planet_camera"), findScript("weather"), findScript("rain_fx")
  wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150)
  hold(2.0)
  weather("clear")
  if vc.releaseClamps then vc.releaseClamps() end
  hold(1.0)
  -- drive 8 s down the runway, then hold the brakes
  key_down("w"); hold(8.0); key_up("w"); key_down("space"); hold(3.0); key_up("space")
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.0)
    dof_mode("old"); state("rover_" .. lv .. "_old"); shot("dof_" .. lv .. "_rover_old")
    dof_mode("new"); state("rover_" .. lv .. "_new"); shot("dof_" .. lv .. "_rover_new")
  end
  gx.set("Medium")
end

local function main()
  NODE.persistent = true
  save.slot("slot1")
  if app.setDisplayMode then pcall(app.setDisplayMode, { width = math.floor(params.w), height = math.floor(params.h), fullscreen = false }) end
  if app.setVsync then pcall(app.setVsync, "Off") end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 200)
  P("ready")
  gx, at, cam, wx, rf = findScript("graphics"), findScript("atmosphere"), findScript("planet_camera"), findScript("weather"), findScript("rain_fx")
  P("scripts: rain_fx %s, snapWeather %s, forceMist %s", tostring(rf ~= nil), tostring(at.snapWeather ~= nil), tostring(wx.forceMist ~= nil))
  if not wx.forceMist then wx.forceMist = function() end end
  if not at.snapWeather then at.snapWeather = function() end end
  if not rf then rf = { setWet = function() end, setOn = function() end, state = {} } end
  wx.force("clear")
  perf.enable(true)
  if cam.setCinematic then cam.setCinematic(true) end
  hold(0.3)
  if cam.setTimeFreeze then cam.setTimeFreeze(true) end
  local b = body()
  local a = find("Astronaut")
  U0 = V(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
  local want = {}
  -- (the scene's strs arrive in params; `strs` here is only the default)
  for w in string.gmatch((type(params.only) == "string" and params.only) or strs.only or "", "[^,]+") do want[w] = true end
  info()
  cam.setFreecam(true)
  hold(0.3)
  if cam.setTimeFreeze then cam.setTimeFreeze(true) end   -- (only takes in the free camera)
  local parts = { { "wx", wx_part }, { "splash", splash_part }, { "dof", dof_part }, { "gpu", gpu_part }, { "rover", rover_part } }
  for _, pt in ipairs(parts) do
    if want[pt[1]] then
      P("PART %s", pt[1])
      local ok, err = pcall(pt[2])
      if not ok then P("ERROR in %s: %s", pt[1], tostring(err)) end
    end
  end
  wait_for(function() return pending <= 0 end, 20)
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  if not CO then NODE = node; CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end

function lateUpdate(node, dt)
  if OLDDOF and gx and at then
    local pc = post()
    local cn = find("Camera 1")
    if pc and cn then
      local alt = 0
      local d = space.dominant(cn.x, cn.y, cn.z)
      local b = d and space.body(d)
      if b then alt = math.max(0, math.sqrt((cn.x - b.x) ^ 2 + (cn.y - b.y) ^ 2 + (cn.z - b.z) ^ 2) - b.radius) end
      local function s01(a0, b0, x) local t = math.max(0, math.min(1, (x - a0) / (b0 - a0))); return t * t * (3 - 2 * t) end
      local k = s01(0.05, 0.4, at.rho_now or 0) * s01(-0.15, 0.15, at.sun_now or 1)
      local _, h = camera.screenSize()
      local f = 25 * (gx.shadowScale or 1) + 1.2 * alt
      pc.dofFocus, pc.dofRange, pc.dofNearRange = f, f * 2.5, 1e6
      pc.dofBlur, pc.dofSamples = OLDDOF[1] * (h or 1080) / 1080 * k, OLDDOF[2]
    end
  end
  if GPU then
    local ok, g = pcall(perf.gpu)
    if ok and g and g.total then
      GPU.n = GPU.n + 1
      GPU.total = GPU.total + g.total
      for _, e in ipairs(g.passes or {}) do GPU.sum[e.name] = (GPU.sum[e.name] or 0) + e.ms end
    end
    GPU.sn = GPU.sn + 1
    GPU.fms = GPU.fms + (dt or 0) * 1000
    for _, n in ipairs(SCRIPTS) do GPU.sms[n] = (GPU.sms[n] or 0) + (perf.scriptMs(n) or 0) end
  end
end
