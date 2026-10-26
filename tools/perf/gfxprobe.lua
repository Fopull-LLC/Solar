-- GFXPROBE: the lens look (bloom, the sun flare, the far-field blur) and the
-- far-distance "grain", on a COPY of the player's save (tools/perf/gfx.sh).
-- Pictures land in user://gfx/*.png; GPU numbers as `GX GPU` lines.
--
-- Each scene is shot with the OLD look (bloom threshold 1.0 / 0.25, no flare,
-- no far blur, upscale sharpness 0.4) and the NEW one (graphics.lua's level),
-- so a before/after is one run. strs `only` = comma list of parts:
--   vista  far ground at Medium and High (+ the grain diagnosis variants)
--   gpu    perf.gpu at the vista: each effect alone, at Medium and High
--   sun    the sun ~25 degrees up, in view
--   hill   a low sun behind a ridge (must show no flare)
--   dusk   the sun on the horizon
--   orbit  from orbit: the sun over the limb, and behind the planet
--   tools  first person, the gravity gun and the laser working (their glow)
defaults = { quit = 1, gpusecs = 2.5, vistaAlt = 25, vistaPitch = -3, head = 0 }
strs = { only = "vista,gpu,sun,hill,dusk,orbit,tools" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("GX %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local NODE, CO
local pending = 0
local FORCE = nil          -- { th, int } bloom forced every lateUpdate (the old look)
local GPU = nil            -- sampling: { sum = {}, n = 0, total = 0 }
local FIRE = nil           -- tool_belt to hold the trigger on while a pair is shot

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1920, h = 1052, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://gfx/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  hold(0.35)
end

local function post() local n = find("Post Processing"); return n and n:getcomponent("PostProcess") end
local function light() local n = find("Lighting"); return n and n:getcomponent("Light") end

local gx, sf, at, cam
local function look(which)
  -- which: "old" | "new" | "noflare" | "nodof"
  if which == "old" then
    FORCE = { 1.0, 0.25 }
    gx.setLook("flare", false); gx.setLook("dof", false)
    app.setRenderSharpness(0.4)
  else
    FORCE = nil
    gx.setLook("flare", which ~= "noflare" and which ~= "bloomonly")
    gx.setLook("dof", which ~= "nodof" and which ~= "bloomonly")
    gx.set(gx.level())       -- re-applies the level's sharpness
  end
  hold(0.6)
end

local function state(tag)
  local pc, L = post(), light()
  local st = sf and sf.state or {}
  P("STATE %s level %s scale %.2f sharp %.2f | bloom %.2f/%.2f dof f %.0f r %.0f blur %.2f n %s | flare vis %.3f uv %.2f,%.2f lens %.2f | atmo fog %.3f rho %.3f sun %.3f | fogDither %s %.2f",
    tag, gx.level(), app.renderScale and app.renderScale() or -1, app.renderSharpness and app.renderSharpness() or -1,
    pc.bloomThreshold or -1, pc.bloomIntensity or -1, pc.dofFocus or -1, pc.dofRange or -1, pc.dofBlur or -1, tostring(pc.dofSamples),
    st.vis or -1, st.uv and st.uv[1] or -1, st.uv and st.uv[2] or -1, st.lens or -1,
    at.fog_now or -1, at.rho_now or -1, at.sun_now or -1, tostring(L.fogDither), L.fogDitherStrength or -1)
end

local function gpu(tag)
  hold(0.8)
  GPU = { sum = {}, n = 0, total = 0, frames = 0 }
  hold(params.gpusecs)
  local g = GPU; GPU = nil
  local ps = {}
  for k, v in pairs(g.sum) do ps[#ps + 1] = { k, v / math.max(g.n, 1) } end
  table.sort(ps, function(a, b) return a[2] > b[2] end)
  local t = {}
  for _, e in ipairs(ps) do t[#t + 1] = string.format("%s %.3f", e[1], e[2]) end
  P("GPU [%s] level %s total %.3f ms (%d samples) | %s", tag, gx.level(), g.total / math.max(g.n, 1), g.n, table.concat(t, ", "))
end

-- ── placing the free camera ─────────────────────────────────────────────────
local B          -- the home body record (refreshed: it moves)
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
local function sunDirFromBody()
  local b, s = body(), star()
  return V(s.x - b.x, s.y - b.y, s.z - b.z):normalized()
end
local function ground_r(up)
  local b = body()
  local top = V(b.x, b.y, b.z) + up * (b.radius + 400)
  local hit = terrain.raycast(top, up * -1, 900)
  if not hit then return b.radius end
  local dx, dy, dz = hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- the camera at radius r along `up` (body frame), looking along `fwd`
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
  hold(1.5)
end
-- an up vector with the star `elev` radians over the horizon, as near the base as can be
local function up_at_elev(elev, U0)
  local S = sunDirFromBody()
  local T = (U0 - S * U0:dot(S))
  if T:length() < 1e-4 then T = S:cross(V(0, 1, 0)) end
  T = T:normalized()
  return (S * math.sin(elev) + T * math.cos(elev)):normalized(), S, T
end
local function sun_from(pos_up, r)
  local b, s = body(), star()
  local p = V(b.x, b.y, b.z) + pos_up * r
  return V(s.x - p.x, s.y - p.y, s.z - p.z):normalized()
end

-- ── the parts ───────────────────────────────────────────────────────────────
local U0
local function pair(tag)
  look("old"); state(tag .. "_old"); shot(tag .. "_old")
  look("new"); hold(0.6); state(tag .. "_new"); shot(tag .. "_new")
end

local function vista()
  local b = body()
  local up = U0
  local gr = ground_r(up)
  -- look along the ground, away from the sun (front-lit: no flare in the way)
  local S = sunDirFromBody()
  local h = (S - up * S:dot(up))
  local fwd = (h:length() > 1e-3 and (h:normalized() * -1) or up:cross(V(1, 0, 0)):normalized())
  fwd = fwd:rotatedAround(up, params.head * math.pi / 2)
  fwd = (fwd * math.cos(math.rad(params.vistaPitch)) + up * math.sin(math.rad(params.vistaPitch))):normalized()
  place(up, gr + params.vistaAlt, fwd)
  settle(20)
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.5)
    pair("vista_" .. lv)
    if lv == "Medium" then
      -- the grain diagnosis, each alone against the old look
      look("old")
      local pc, L = post(), light()
      -- two frames in a row: what changes between them is temporal noise
      pcall(camera.capture, { w = 1920, h = 1052 }, function(by) if by then assets.writeBytes("user://gfx/diag_t0.png", by) end end)
      yield()
      pcall(camera.capture, { w = 1920, h = 1052 }, function(by) if by then assets.writeBytes("user://gfx/diag_t1.png", by) end end)
      hold(0.5)
      local ao = pc.aoStrength; pc.aoStrength = 0; hold(0.5); shot("diag_ao0"); pc.aoStrength = ao; hold(0.3)
      local orig = at.follow
      local okp = pcall(function() at.follow = function(dt) orig(dt); L.fogDither = false end end)
      L.fogDither = false; hold(0.5); state("dither0"); shot("diag_dither0")
      if okp then at.follow = orig end; hold(0.3)
      app.setRenderSharpness(0); hold(0.3); shot("diag_sharp0"); app.setRenderSharpness(0.4)
      app.setRenderScale(1.0); hold(0.5); shot("diag_scale1"); gx.set("Medium"); look("old")
      local bl = pc.bloom; pc.bloom = false; FORCE = nil; hold(0.4); shot("diag_bloom0"); pc.bloom = bl; FORCE = { 1.0, 0.25 }
      local dn = pc.dofBlur
      look("new"); pc.dofShowFocus = true; hold(0.5); shot("diag_dofband"); pc.dofShowFocus = false
    else
      -- High: the volumetric march's dither, alone
      look("old")
      local L = light()
      local orig = at.follow
      local okp = pcall(function() at.follow = function(dt) orig(dt); L.fogDither = false end end)
      L.fogDither = false; hold(0.5); state("High dither0"); shot("diagH_dither0")
      if okp then at.follow = orig end; hold(0.3)
      look("new")
    end
  end
  gx.set("Medium")
end

local function gpu_part()
  -- at the vista, picture size as the window is; old/new interleaved three
  -- times (the machine and the streaming drift), then each effect alone
  for _, lv in ipairs({ "Medium", "High" }) do
    gx.set(lv); hold(1.0)
    for rep = 1, 3 do
      look("old"); gpu(lv .. " old #" .. rep)
      look("new"); gpu(lv .. " new #" .. rep)
    end
    look("bloomonly"); gpu(lv .. " +bloom only")
    look("noflare"); gpu(lv .. " +bloom+dof")
    look("nodof"); gpu(lv .. " +bloom+flare")
  end
  gx.set("Medium")
end

local function sun_part()
  local up = up_at_elev(math.rad(25), U0)
  local gr = ground_r(up)
  place(up, gr + 30, sun_from(up, gr + 30))
  settle(20)
  local up2 = up
  local S = sun_from(up2, gr + 30)
  -- the sun up and to the right of centre, so the ghosts cross the frame
  local right = S:cross(up2):normalized()
  local fwd = (S - up2 * 0.18 - right * 0.22):normalized()
  place(up2, gr + 30, fwd)
  hold(1.0)
  pair("sun")
end

local function hill_part()
  -- On foot (1.8 m) on a ~900 m world the ground's horizon dips 3.5 degrees,
  -- so a sun 2 degrees up is clear, 1.5 degrees under the horizontal shows
  -- over the dip, and 6 degrees under is behind the ground itself.
  for _, e in ipairs({ { "hill_up2", 2 }, { "hill_dn6", -6 } }) do
    local up = up_at_elev(math.rad(e[2]), U0)
    local gr = ground_r(up)
    place(up, gr + 1.8, sun_from(up, gr + 1.8))
    settle(12)
    gr = ground_r(up)
    local Sd = sun_from(up, gr + 1.8)
    place(up, gr + 1.8, (Sd + up * 0.04):normalized())
    hold(1.2)
    look("new"); hold(0.4); state(e[1]); shot(e[1])
  end
end

local function dusk_part()
  local up = up_at_elev(math.rad(1.5), U0)
  local gr = ground_r(up)
  place(up, gr + 60, sun_from(up, gr + 60))
  settle(20)
  local S = sun_from(up, gr + 60)
  local right = S:cross(up):normalized()
  place(up, gr + 60, (S + up * 0.05 - right * 0.15):normalized())
  hold(1.0)
  pair("dusk")
end

local function orbit_part()
  local b = body()
  local S = sunDirFromBody()
  local T = (U0 - S * U0:dot(S)):normalized()
  local R = b.radius * 3.2
  for _, e in ipairs({ { "orbit", 30 }, { "eclipse", 10 } }) do
    local a = math.rad(e[2])
    local u = (S * -math.cos(a) + T * math.sin(a)):normalized()
    local Sd = sun_from(u, R)
    local fwd = (Sd + u * -0.3):normalized()
    place(u, R, fwd)
    settle(8)
    if e[1] == "orbit" then pair("orbit") else look("new"); hold(0.5); state("eclipse_new"); shot("eclipse_new") end
  end
end

local function tools_part()
  local tb, ih = findScript("tool_belt"), findScript("item_hand")
  cam.setFreecam(false)
  hold(1.0)
  for _, id in ipairs({ "gravgun", "laser" }) do
    if ih and ih.hold then local ok, why = ih.hold(id); if not ok then P("hold %s refused %s", id, tostring(why)) end end
    hold(1.2)
    cam.firstPerson = true
    local a, b = find("Astronaut"), body()
    local u = V(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
    local f0 = V(cam.fwd_x or 1, cam.fwd_y or 0, cam.fwd_z or 0):flatten(u):normalized()
    -- facing away from the sun's side, so the tool is front-lit and the flare is out of it
    cam.face(f0.x, f0.y, f0.z, -0.5)
    hold(1.0)
    local t = W() + 1.5
    while W() < t do tb.sim = { btn = { [0] = true } }; yield() end
    FIRE = tb
    pair("tool_" .. id)
    FIRE = nil
    tb.sim = { btn = { [0] = false } }
    hold(0.6)
  end
  cam.firstPerson = false
  cam.setFreecam(true)
  hold(0.5)
end

local function main()
  NODE.persistent = true
  save.slot("slot1")
  if app.setDisplayMode then pcall(app.setDisplayMode, { width = 1920, height = 1052, fullscreen = false }) end
  if app.setVsync then pcall(app.setVsync, "Off") end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 200)
  P("ready")
  gx, sf, at, cam = findScript("graphics"), findScript("sun_flare"), findScript("atmosphere"), findScript("planet_camera")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  perf.enable(true)
  cam.setFreecam(true)
  if cam.setCinematic then cam.setCinematic(true) end
  hold(0.3)
  if cam.setTimeFreeze then cam.setTimeFreeze(true) end
  local b = body()
  local a = find("Astronaut")
  U0 = V(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
  P("body %s R %.0f star %s", b.name, b.radius, tostring(star().name))
  local want = {}
  for w in string.gmatch(strs.only or "", "[^,]+") do want[w] = true end
  local parts = { { "vista", vista }, { "gpu", gpu_part }, { "sun", sun_part }, { "hill", hill_part },
                  { "dusk", dusk_part }, { "orbit", orbit_part }, { "tools", tools_part } }
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
  if FIRE then FIRE.sim = { btn = { [0] = true } } end
  if FORCE then
    local pc = post()
    if pc then pc.bloom = true; pc.bloomThreshold = FORCE[1]; pc.bloomIntensity = FORCE[2] end
  end
  if GPU then
    local ok, g = pcall(perf.gpu)
    if ok and g and g.total then
      GPU.n = GPU.n + 1
      GPU.total = GPU.total + g.total
      for _, e in ipairs(g.passes or {}) do GPU.sum[e.name] = (GPU.sum[e.name] or 0) + e.ms end
    end
  end
end
