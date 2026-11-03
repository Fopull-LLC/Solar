-- FLICKERPROBE: does the picture flicker while NOTHING moves? (2026-11-03,
-- engine cards 0616/0617/0618; tools/perf/flickerprobe.sh, flicker.py).
-- A NEW Career save with the player's own graphics settings copied in. The
-- crew stands still and the camera is held still against the planet (every
-- point is in the lab's ground frame, placed against its drawn pose each
-- frame: docs/positions-and-frames.md), then N consecutive frames are taken,
-- one camera.capture a frame (each renders on the frame it is asked for, and
-- through the Game panel's own scene history, so reflections compare against
-- the frame before, as the window's do).
--
--   spots: the lab's glass wall at 1.5 / 5 / 10 m, the Commerce Depot's
--   west wall at 2 / 10 / 30 m, a far landscape, the crew standing still
--   (third person)
--   configs (cfgs=1): the player's settings; reflections off; AO off;
--   contact shadows off; all three off (the floor: what moves anyway)
--
-- Frames: user://flicker/<cfg>/<spot>/fNN.png; lines "FLK ".
defaults = { quit = 1, dump = 0, pan = 0.0, slide = 0.0, slot = 19, seed = 5150, scale = 4, n = 30, warm = 4, cfgs = 1, scout = 0, w = 1280, h = 720 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FLK %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO = nil, nil
WPEND = 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- the lab's GROUND frame (x east, y up from the slab, z south) → world, drawn, now
local function lab() return findScript("lab") end
local function labpt(gx, gy, gz)
  local L = lab()
  if not (L and L.ROOT and L.ROOT.valid) then return nil end
  return L.ROOT:toWorld(vec3(gx, gy - 4.24, gz - 2.05))
end
local function labaxes()
  local L = lab()
  local o = L.ROOT.worldPos
  local u = L.ROOT:toWorld(vec3(0, 1, 0))
  return { x = u.x - o.x, y = u.y - o.y, z = u.z - o.z }
end
local function astro() return find("Astronaut") end
-- the ground's height (ground frame y) under a ground-frame point, by a ray down
local function ground_y(gx, gz)
  local p = labpt(gx, 40, gz)
  local u = labaxes()
  local ok, hit = pcall(raycast, p.x, p.y, p.z, -u.x, -u.y, -u.z, 80, { ignore = astro() })
  if ok and hit and hit.distance then return 40 - hit.distance, hit.node and hit.node.name or "?" end
  return 0, "-"
end
local function stand(gx, gz)
  local a = astro()
  local gy = ground_y(gx, gz)
  local p = labpt(gx, gy + 1.25, gz)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.0) end
end
local function cam_at(c, t)
  -- pan (deg/s) and slide (m/s) params: the camera turns / creeps sideways
  -- slowly from the moment it is set (both 0: perfectly still)
  local t0 = time
  local pan, slide = params.pan or 0, params.slide or 0
  findScript("planet_camera").setShot(function()
    local a, b = labpt(c[1], c[2], c[3]), labpt(t[1], t[2], t[3])
    if not (a and b) then return nil end
    local u = labaxes()
    if pan ~= 0 or slide ~= 0 then
      local el = time - t0
      local fx, fy, fz = b.x - a.x, b.y - a.y, b.z - a.z
      local d = len(fx, fy, fz)
      local rx, ry, rz = fy * u.z - fz * u.y, fz * u.x - fx * u.z, fx * u.y - fy * u.x
      local rl = math.max(len(rx, ry, rz), 1e-9)
      rx, ry, rz = rx / rl, ry / rl, rz / rl
      local sl = slide * el
      local sh = sl + d * math.tan(math.rad(pan * el))
      a = { x = a.x + rx * sl, y = a.y + ry * sl, z = a.z + rz * sl }
      b = { x = b.x + rx * sh, y = b.y + ry * sh, z = b.z + rz * sh }
    end
    return a.x, a.y, a.z, b.x, b.y, b.z, u.x, u.y, u.z
  end, 0.05)
end

-- the crew drawn (third person: the orbit camera far enough back that it does not hide the body)
local DIST0 = nil
local function third(on)
  local pc = findScript("planet_camera")
  if DIST0 == nil then DIST0 = pc.params.distance end
  pc.firstPerson = false
  pc.params.distance = on and 4.0 or DIST0
end

-- ── the settings ───────────────────────────────────────────────────────────
local CFGS = {
  { "base", {} },
  { "norefl", { gfx_reflections = false } },
  { "noao", { gfx_ao = 0.0 } },
  { "nocontact", { gfx_contact_shadows = false } },
  { "none", { gfx_reflections = false, gfx_ao = 0.0, gfx_contact_shadows = false } },
}
local BASE = {}
local function apply_cfg(c)
  local st = findScript("settings")
  for _, k in ipairs({ "gfx_reflections", "gfx_ao", "gfx_contact_shadows" }) do
    if BASE[k] == nil then BASE[k] = { st.get(k) } end
    local v = c[2][k]
    if v == nil then v = BASE[k][1] end
    st.set(k, v)
  end
  hold(1.2)
  local ln = find("Lighting"); local l = ln and ln:getcomponent("Light")
  local pn = find("Post Processing"); local pc = pn and pn:getcomponent("PostProcess")
  local gx = findScript("graphics")
  P("CFG %s: level %s reflections %s contact %s aoMode %s aoStrength %.2f motionBlur %.2f fxaa? render scale %.2f",
    c[1], gx and gx.level and gx.level() or "?", tostring(l and l.reflections), tostring(l and l.contactShadows),
    tostring(pc and pc.aoMode), pc and pc.aoStrength or -1, pc and pc.motionBlur or -1,
    app.renderScale and app.renderScale() or -1)
end

-- ── the spots (ground frame) ───────────────────────────────────────────────
-- the lab's instrument-room glass wall stands at x = 1.46 (z -7.6 .. -2)
local GLASS_X = 1.46
local SPOTS = {}
local function add_lab(tag, d)
  local cx = GLASS_X - d
  SPOTS[#SPOTS + 1] = { tag = tag, inside = true, crew = { cx - 1.3, -4.0 },
    cam = { cx, 1.6, -4.0 }, look = { GLASS_X, 1.35, -4.4 } }
end
add_lab("lab_glass_1p5m", 1.5)
add_lab("lab_glass_5m", 5.0)
add_lab("lab_glass_10m", 10.0)

local function main()
  boot()
  local gx = findScript("graphics")
  if gx and gx.params then gx.params.autoLower = false end
  local L = wait_for(function() local l = lab(); return l and l.ROOT and l.ROOT.valid and l.interior and l end, 60, "the lab")
  if not L then P("DONE no lab") return end
  -- the Commerce Depot (FacDepot): its centre in the ground frame, then rays
  -- at it from the west and the south across open ground at eye height
  local dep = find("FacDepot")
  local dc = dep and L.ROOT:toLocal(dep.worldPos)
  local dgx, dgz = dc and dc.x or 8.0, dc and (dc.z + 2.05) or 22.0
  P("FacDepot at ground (%.1f, %.1f)", dgx, dgz)
  local o = L.ROOT.worldPos
  local function axis(v) local q = L.ROOT:toWorld(v); return q.x - o.x, q.y - o.y, q.z - o.z end
  local function wall(from_x, from_z, dx, dz)
    local wy = ground_y(from_x, from_z)
    local p0 = labpt(from_x, wy + 1.6, from_z)
    local ex, ey, ez = axis(vec3(dx, 0, dz))
    local ok, hit = pcall(raycast, p0.x, p0.y, p0.z, ex, ey, ez, 120, { ignore = astro() })
    local d = (ok and hit and hit.distance) or nil
    local nm = ok and hit and hit.node and hit.node.name or "-"
    local par = ok and hit and hit.node and hit.node.parent and hit.node.parent.name or "-"
    P("ray from (%.1f, %.1f) dir (%d, %d): hit %s (parent %s) at %s", from_x, from_z, dx, dz, nm, par, tostring(d))
    return d, par
  end
  -- the south front, left of the door: a ray north from the lot at 2.5 m
  local function wall2(from_x, from_z)
    local wy = ground_y(from_x, from_z)
    local p0 = labpt(from_x, wy + 2.5, from_z)
    local ex, ey, ez = axis(vec3(0, 0, -1))
    local ok, hit = pcall(raycast, p0.x, p0.y, p0.z, ex, ey, ez, 60, { ignore = astro() })
    local nm = ok and hit and hit.node and hit.node.name or "-"
    local par = ok and hit and hit.node and hit.node.parent and hit.node.parent.name or "-"
    P("ray north from (%.1f, %.1f): hit %s (parent %s) at %s", from_x, from_z, nm, par, tostring(ok and hit and hit.distance))
    return ok and hit and hit.distance
  end
  -- the front's ray finds no collider up there (it passes to the lab), so the
  -- front is taken from lab.lua's depot zone (z 28.8) and the shots: the door
  -- spans about x 4.5 .. 10.5; the panel left of it stands at x 2
  wall2(2.0, 45.0)
  local WX, wz = 2.0, 28.8
  for _, d in ipairs({ 2, 10, 30 }) do
    local cz = wz + d
    local gy = ground_y(WX, cz)
    SPOTS[#SPOTS + 1] = { tag = "depot_" .. d .. "m", inside = false, crew = { WX, cz + 1.5 },
      cam = { WX, gy + 1.6, cz }, look = { WX - 0.8, gy + 1.5 + d * 0.03, wz } }
  end
  -- far landscape: from the yard's west edge, facing west over the land
  local ly = ground_y(-60, 22.0)
  SPOTS[#SPOTS + 1] = { tag = "landscape", inside = false, crew = { -57, 22.0 },
    cam = { -60, ly + 1.8, 22.0 }, look = { -400, ly - 12, 30.0 } }
  -- the crew standing still on the lot, third person (camera behind and above)
  local cy = ground_y(dgx + 4.0, wz + 7.0)
  SPOTS[#SPOTS + 1] = { tag = "crew_still", inside = false, third = true, crew = { dgx + 4.0, wz + 7.0 },
    cam = { dgx + 5.2, cy + 2.2, wz + 10.0 }, look = { dgx + 4.0, cy + 0.9, wz + 7.0 } }
  -- a shot hides the crew (planet_camera shot_tick), so the crew's own spot is
  -- framed by the shot and then HELD there (holdOn: body-relative, hides nothing)
  local pc = findScript("planet_camera")
  function place(s, secs)
    L.forceInside = s.inside
    third(s.third)
    stand(s.crew[1], s.crew[2])
    cam_at(s.cam, s.look)
    if s.third then
      hold(1.0)
      local p = labpt(s.look[1], s.look[2], s.look[3])
      pc.holdOn(p.x, p.y, p.z, 6.0)
      KEEPVIS = true
    end
    hold(secs)
  end
  function unplace(s)
    if s.third then
      KEEPVIS = false
      wait_for(function() return not pc.holding() end, 15, "the hold")
    end
  end
  if params.scout == 1 then
    for _, s in ipairs(SPOTS) do
      place(s, 1.5)
      local done = false
      pcall(camera.capture, { w = params.w, h = params.h }, function(b)
        if b then assets.writeBytes("user://flicker/scout/" .. s.tag .. ".png", b) end; done = true end)
      wait_for(function() return done end, 8, "scout shot")
      unplace(s)
      local a = astro(); local q = L.ROOT:toLocal(a.worldPos)
      P("SCOUT %s: crew at ground (%.1f, %.1f) wanted (%.1f, %.1f), visible %s; camera firstPerson %s distance %s hidesBody %s", s.tag, q.x, q.z + 2.05, s.crew[1], s.crew[2], tostring(a.visible),
        tostring(findScript("planet_camera").firstPerson), tostring(findScript("planet_camera").params.distance), tostring(findScript("planet_camera").hidesBody))
    end
    P("DONE scout")
    return
  end

  -- dump=1: no captures; the WINDOW's own frames are dumped by the engine
  -- (FLOPTLE_FRAME_DUMP, frame-NNNNN.png = the player's frame count); each
  -- spot is held still and its frame window logged by this script's update
  -- count (flickerprobe.sh dump: flicker.py matches the two by the cuts)
  if params.dump == 1 then
    local ncfg = params.cfgs == 1 and #CFGS or 1
    for ci = 1, ncfg do
      apply_cfg(CFGS[ci])
      for _, s in ipairs(SPOTS) do
        place(s, 2.0)
        local f0 = FRAME
        local n = 0
        while n < params.n do yield(); n = n + 1 end
        P("DUMP %s %s frames %d %d", CFGS[ci][1], s.tag, f0 + 1, FRAME)
        unplace(s)
      end
    end
    P("DONE dump")
    return
  end
  local ncfg = params.cfgs == 1 and #CFGS or 1
  local N, WARM = math.floor(params.n), math.floor(params.warm)
  for ci = 1, ncfg do
    local c = CFGS[ci]
    apply_cfg(c)
    for _, s in ipairs(SPOTS) do
      place(s, 2.0)
      local out, issued, refused = 0, 0, 0
      local dts, moved, rel = {}, {}, {}
      local b0 = home(); local bx, by, bz = b0.x, b0.y, b0.z
      local t0 = W()
      for i = 1, N + WARM do
        local idx = i - WARM
        out = out + 1
        local okc = pcall(camera.capture, { w = params.w, h = params.h }, function(bytes, why)
          out = out - 1
          if bytes then
            if idx >= 1 then
              WPEND = WPEND + 1
              assets.writeBytes(string.format("user://flicker/%s/%s/f%02d.png", c[1], s.tag, idx), bytes, { async = true },
                function(okw, err) WPEND = WPEND - 1; if not okw then P("write failed %s", tostring(err)) end end)
            end
          else refused = refused + 1; P("capture %s/%s %d: %s", c[1], s.tag, i, tostring(why)) end
        end)
        if not okc then out = out - 1; refused = refused + 1 end
        yield()
        local b = home()
        if idx >= 1 then
          dts[#dts + 1] = dt or 0; moved[#moved + 1] = len(b.x - bx, b.y - by, b.z - bz)
          -- the camera against the planet (drawn, both read now): should not move at all
          local cn = findScript("planet_camera").node
          local cp = cn and cn.worldPos
          if cp then rel[#rel + 1] = { cp.x - b.x, cp.y - b.y, cp.z - b.z } end
        end
        bx, by, bz = b.x, b.y, b.z
      end
      wait_for(function() return out <= 0 end, 15, "captures")
      unplace(s)
      local sdt, smv = 0, 0
      for i = 1, #dts do sdt = sdt + dts[i]; smv = smv + moved[i] end
      local jit = 0
      if #rel > 1 then
        local m = { 0, 0, 0 }
        for _, r in ipairs(rel) do for k = 1, 3 do m[k] = m[k] + r[k] / #rel end end
        for _, r in ipairs(rel) do jit = math.max(jit, len(r[1] - m[1], r[2] - m[2], r[3] - m[3])) end
      end
      P("BURST %s %s: %d frames in %.2f s wall, mean frame %.1f ms, planet %.2f m/frame, camera-vs-planet wobble %.2f mm, refused %d",
        c[1], s.tag, N, W() - t0, 1000 * sdt / math.max(#dts, 1), smv / math.max(#moved, 1), jit * 1000, refused)
    end
  end
  apply_cfg(CFGS[1])
  wait_for(function() return WPEND <= 0 end, 90, "the frames on disk")
  P("DONE (writes pending %d)", WPEND)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

FRAME = 0
function update(node, dt_)
  dt = dt_
  FRAME = FRAME + 1
  if KEEPVIS then local a = astro(); if a then a.visible = true end end
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
