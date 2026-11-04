-- NECKPROBE: the lab scientists' necks and the lab's ceiling (playtest
-- 2026-11-04), in the real game on a NEW Career save (tools/perf/neckshots.sh):
--
--   1. each scientist's neck and collar close up (front, three quarters, side,
--      under the chin, behind), as their own looks (Okafor dark, Pillai
--      mid-dark, Haddad mid, Nakamura light), then again with the heads and
--      skins swapped round (params.swap = 1: heads 5-8, the darkest and the
--      lightest skins), so every head is seen with more than one tone
--   2. params.diag = 1: the SuitHead part (the coat's own little neck) red and
--      the shirt's knit green, to tell which surface shows at the collar
--   3. the ceiling: the crew jumps at several spots (open floor, under a lamp,
--      the vestibule's door, the instrument room, the vestibule) and the
--      highest the capsule's centre got over the slab is logged; the ceiling's
--      face is at 3.45 m, so the centre must stay under ~2.4
--
-- Pictures (1280x720) to user://neck/, lines "NKP ", one RESULT a check.
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4, shots = 1, diag = 0, swap = 1, jumps = 1, close = 0.42 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("NKP %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
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
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  if params.shots ~= 1 then return end
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://neck/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  local t = W() + 5
  while pending > 0 and W() < t do coroutine.yield() end
end

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

local function lab() return findScript("lab") end
-- The lab's GROUND frame (x east, y up from the slab, z south) → the world NOW
-- (drawn poses; this frame only).
local function labpt(gx, gy, gz)
  local L = lab()
  if not (L and L.ROOT and L.ROOT.valid) then return nil end
  return L.ROOT:toWorld(vec3(gx, gy - 4.24, gz - 2.05))
end
local function labup()
  local L = lab()
  local o = L.ROOT.worldPos
  local u = L.ROOT:toWorld(vec3(0, 1, 0))
  return u.x - o.x, u.y - o.y, u.z - o.z
end
local function toground(p)
  local q = lab().ROOT:toLocal(p)
  return q.x, q.y + 4.24, q.z + 2.05
end
local function astro() return find("Astronaut") end
local function stand_lab(gx, gz)
  local a = astro()
  local p = labpt(gx, 0.15 + 1.1, gz)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.0) end
end
local function cam_fn(fn) findScript("planet_camera").setShot(fn, 0.05) end
local function cam_off() local pc = findScript("planet_camera"); if pc.clearShot then pc.clearShot(0.05) end end

local function parts(n)
  local model, face = nil, nil
  for _, c in ipairs(n:children() or {}) do
    if c.name == "LabModel" then
      model = c
      for _, k in ipairs(c:children() or {}) do if k.name == "Face" then face = k end end
    end
  end
  return model, face
end

-- close-ups round one scientist's neck: the camera and its target are worked
-- out from the scientist's node and the Face node's drawn poses each frame
local VIEWS = {
  { "front", 0.0, 1.0, 0.02 }, { "34", 0.62, 0.78, 0.04 }, { "side", 1.0, 0.0, 0.0 },
  { "chin", 0.25, 0.8, -0.45 }, { "back", 0.45, -0.9, 0.12 }, { "34l", -0.62, 0.78, -0.08 },
}
local function neck_shots(i, n, tag)
  local _, face = parts(n)
  local sc = n:getScript("scientist")
  local sg = sc and sc.faceSign or 1
  for _, v in ipairs(VIEWS) do
    cam_fn(function()
      if not (n.valid and face and face.valid) then return nil end
      local o = n.worldPos
      local f = n:toWorld(vec3(0, 0, sg)); local r = n:toWorld(vec3(1, 0, 0)); local u = n:toWorld(vec3(0, 1, 0))
      local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
      local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
      local ux, uy, uz = u.x - o.x, u.y - o.y, u.z - o.z
      local h = face.worldPos
      -- the neck: a little under the Face node's origin
      local tx, ty, tz = h.x - ux * 0.10, h.y - uy * 0.10, h.z - uz * 0.10
      local d = params.close
      local a, b, c = v[2], v[3], v[4]
      local l = math.sqrt(a * a + b * b + c * c)
      a, b, c = a / l * d, b / l * d, c / l * d
      return tx + rx * a + fx * b + ux * c, ty + ry * a + fy * b + uy * c, tz + rz * a + fz * b + uz * c,
        tx, ty, tz, ux, uy, uz
    end)
    hold(0.45)
    shot(string.format("%s_sci%d_%s", tag, i, v[1]))
  end
  cam_off()
end

local function scientists()
  local L = lab()
  local list = wait_for(function() return L.scientists and #L.scientists >= 4 and L.scientists end, 20, "the scientists")
  if not list then R("scientists", false) return end
  -- the crew out of the way, by the vestibule's door
  stand_lab(9.5, 6.3)
  hold(1.5)
  local cf = findScript("crew_faces")
  for i, s in ipairs(list) do
    local n = s.node
    local model, face = parts(n)
    local fs = face and face:getScript("face")
    local nk = model and model:material("SuitHead")
    local c = nk and nk.color
    local sk = face and face:material("FaceSkin")
    local sx, sy, sz = 0, 0, 0
    if sk and sk.shaderParam then sx, sy, sz = sk:shaderParam("skin") end
    P("sci%d %s: SuitHead colour %s; FaceSkin skin %s", i, s.staff and s.staff.name or "?",
      c and string.format("%.3f %.3f %.3f", c[1] or c.r or 0, c[2] or c.g or 0, c[3] or c.b or 0) or "-",
      sx and string.format("%.3f %.3f %.3f", sx or 0, sy or 0, sz or 0) or "-")
    if params.diag == 1 and model then
      pcall(function() model:material("SuitHead").color = { 1, 0, 0 } end)
      pcall(function() model:material("LabKnit").color = { 0, 1, 0 } end)
    end
    neck_shots(i, n, params.diag == 1 and "diag" or "own")
    if params.diag == 2 and nk then
      -- the coat's neck in the face shader's own (linear) skin colour
      pcall(function() nk.color = { sx, sy, sz } end)
      local keep = VIEWS
      VIEWS = { keep[1], keep[2] }
      neck_shots(i, n, "lin")
      VIEWS = keep
    end
  end
  if params.swap == 1 and cf and cf.SKIN then
    -- other heads, the darkest and the lightest skins
    local SW = { { 5, 10 }, { 6, 1 }, { 7, 9 }, { 8, 2 } }
    for i, s in ipairs(list) do
      local _, face = parts(s.node)
      local fs = face and face:getScript("face")
      if fs and fs.setLook then
        local l = cf.lookFor(s.staff.seed or 1, 9000 + i, s.staff.name)
        local t = {}
        for k, v in pairs(l) do t[k] = v end
        t.head = SW[i][1]
        t.skin = cf.SKIN[SW[i][2]]
        fs.setLook(t)
      end
    end
    hold(1.0)
    for i, s in ipairs(list) do neck_shots(i, s.node, "swap") end
    -- heads 2-4 too
    local SW2 = { { 2, 8 }, { 3, 5 }, { 4, 3 }, { 1, 7 } }
    for i, s in ipairs(list) do
      local _, face = parts(s.node)
      local fs = face and face:getScript("face")
      if fs and fs.setLook then
        local l = cf.lookFor(s.staff.seed or 1, 9000 + i, s.staff.name)
        local t = {}
        for k, v in pairs(l) do t[k] = v end
        t.head = SW2[i][1]
        t.skin = cf.SKIN[SW2[i][2]]
        fs.setLook(t)
      end
    end
    hold(1.0)
    for i, s in ipairs(list) do
      local _, face = parts(s.node)
      -- front and three quarters only for these
      local keep = VIEWS
      VIEWS = { keep[1], keep[2], keep[4] }
      neck_shots(i, s.node, "swap2")
      VIEWS = keep
    end
  end
end

local function jumps()
  local L = lab()
  local pw = findScript("planet_walker")
  local a = astro()
  local g = nil
  pcall(function() local gm = findScript("game_manager"); g = gm and gm.gravity and gm.gravity() end)
  local SPOTS = {
    { "open floor", 0.0, 2.2 }, { "aisle west", -8.0, 2.8 }, { "under a lamp", -3.9, -3.6 },
    { "vestibule", 8.4, 5.0 }, { "vestibule door", 6.6, 4.95 }, { "instrument room", 6.0, -4.5 },
    { "by the hoods", -6.0, -5.3 },
  }
  local worst = -1e9
  for _, s in ipairs(SPOTS) do
    stand_lab(s[2], s[3])
    hold(1.2)
    local _, y0 = toground(a.worldPos)
    pw.steer(0, 0, false, true)
    local top, t0 = y0, W()
    while W() - t0 < 3.5 do
      yield()
      local _, y = toground(a.worldPos)
      if y > top then top = y end
    end
    pw.steer(nil)
    P("JUMP %-16s stood %.2f, top %.2f (capsule centre over the slab)", s[1], y0, top)
    if top > worst then worst = top end
    if params.shots == 1 and s[1] == "open floor" then
      -- a look up at the ceiling from the floor
      cam_fn(function()
        local c, t = labpt(1.0, 1.6, 4.5), labpt(-1.0, 3.45, 1.0)
        if not (c and t) then return nil end
        local ux, uy, uz = labup()
        return c.x, c.y, c.z, t.x, t.y, t.z, ux, uy, uz
      end)
      hold(0.4)
      shot("ceiling_up")
      cam_off()
    end
  end
  -- the capsule is 2.0 m with 0.33 caps: its top is ~1.0-1.33 over the centre
  R("ceiling_stops_jump", worst + 1.0 < 3.45, "the highest centre %.2f m (ceiling 3.45); g %s", worst, tostring(g))
end

local function main()
  boot()
  hold(3.0)
  local L = wait_for(function() local l = lab(); return l and l.ROOT and l.ROOT.valid and l.interior and l end, 60, "the lab")
  if not L then R("lab", false) P("DONE fails %d", FAILS) return end
  stand_lab(8.0, 5.6)
  wait_for(function() return L.inside end, 15, "the interior on")
  hold(2.0)
  local n = 0
  for _, c in ipairs(L.interior:children() or {}) do if (c.name or ""):sub(1, 9) == "LabSolid " then n = n + 1 end end
  P("interior solids: %d LabSolid boxes", n)
  if params.jumps == 1 then jumps() end
  scientists()
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
