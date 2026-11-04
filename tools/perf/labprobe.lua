-- LABPROBE: the Research Lab (2026-11-03) in the real game, on a NEW Career
-- save (tools/perf/labshots.sh; scripts/lab.lua, lab_talk.lua, scientist.lua,
-- research.lua, material_intake.lua):
--
--   1. loads dropped on the intake's belt send capsules up the sample tube:
--      pictures of the exterior with a capsule in the tube; research points
--      gained (and more for a new kind)
--   2. the interior from several angles, the receiving station, the hoods,
--      the instrument room through its glass
--   3. each scientist's face and neck close up, from the front, three
--      quarters, the side and under the chin
--   4. the talk view: the list, then a material's close-up with the turning
--      sample and the codex text
--   5. frame time outside the lab and inside it
--
-- Pictures (1280x720) to user://labshots/, lines "LBP ", one RESULT a check.
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4, shots = 1, perf = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("LBP %7.2f " .. fmt, W() - W0, ...)) end
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
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://labshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  -- (a capture lands a few frames later: hold the view until it has)
  if coroutine.running() then
    local t = W() + 5
    while pending > 0 and W() < t do coroutine.yield() end
  end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function wpos(n) return n.worldPos or vec3(n.worldX, n.worldY, n.worldZ) end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
local function face(tx, ty, tz, pitch)
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local b = home()
  local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  local ex, ey, ez = a.x + u.x * 1.5, a.y + u.y * 1.5, a.z + u.z * 1.5
  local dx, dy, dz = tx - ex, ty - ey, tz - ez
  local v = dx * u.x + dy * u.y + dz * u.z
  local hx, hy, hz = dx - u.x * v, dy - u.y * v, dz - u.z * v
  local hl = len(hx, hy, hz)
  if cam and cam.face and hl > 1e-3 then cam.face(hx / hl, hy / hl, hz / hl, pitch or -0.18) end
end
-- The avatar onto the ground at a world point (its radial; a raycast finds
-- paving and slabs as well as the terrain).
local function stand_at(px, py, pz, top_)
  local C = findScript("crew")
  local b = home()
  local a = find("Astronaut")
  local u = unit({ x = px - b.x, y = py - b.y, z = pz - b.z })
  local top = top_ or 30
  local h = raycast(px + u.x * top, py + u.y * top, pz + u.z * top, -u.x, -u.y, -u.z, 80, { ignore = a })
  local gx, gy, gz
  if h then gx, gy, gz = h.x, h.y, h.z
  else
    local gr = ground_r(b, u.x, u.y, u.z, len(px - b.x, py - b.y, pz - b.z) + 30)
    if not gr then return false end
    gx, gy, gz = b.x + u.x * gr, b.y + u.y * gr, b.z + u.z * gr
  end
  a.x, a.y, a.z = gx + u.x * 1.1, gy + u.y * 1.1, gz + u.z * 1.1
  a.vx, a.vy, a.vz = 0, 0, 0
  if C and C.quietMonitors then C.quietMonitors(1.0) end
  return true
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

local function drop(prefab, s, w, h, mat, qty, crosswise)
  local mi = find("FacIntake"):getScript("material_intake")
  local x, y, z = mi.beltWorld(s, w, h)
  local G = mi.belt()
  local got = nil
  spawn(prefab, vec3(x, y, z), function(n)
    got = n
    n.name = prefab .. " probe " .. tostring(math.floor(s * 10))
    local u, a = G.u, G.a
    local f = crosswise and a or G.w
    if n.setUp then n:setUp(vec3(u.x, u.y, u.z), vec3(f.x, f.y, f.z)) end
    local mf, mats = findScript("mineral_field"), findScript("materials")
    if mf and mf.adoptBody then mf.adoptBody(n, prefab, mat, qty, 1.0)
    elseif mats and mats.tagResource then mats.tagResource(n, mat, qty) end
    if assembly and assembly.rebuild then assembly.rebuild(n) end
  end)
  wait_for(function() return got end, 10, "the " .. prefab)
  return got
end


local function lab() return findScript("lab") end
-- A point in the lab's GROUND frame (x east, y up from the slab, z south),
-- in the world NOW (drawn poses; use it this frame only).
local function labpt(gx, gy, gz)
  local L = lab()
  if not (L and L.ROOT and L.ROOT.valid) then return nil end
  local p = L.ROOT:toWorld(vec3(gx, gy - 4.24, gz - 2.05))
  return p
end
local function labup()
  local L = lab()
  local o = L.ROOT.worldPos
  local u = L.ROOT:toWorld(vec3(0, 1, 0))
  return u.x - o.x, u.y - o.y, u.z - o.z
end
-- A camera at ground-frame point c looking at ground-frame point t (snapped).
local function cam_lab(c, t)
  local pc = findScript("planet_camera")
  pc.setShot(function()
    local a, b = labpt(c[1], c[2], c[3]), labpt(t[1], t[2], t[3])
    if not (a and b) then return nil end
    local ux, uy, uz = labup()
    return a.x, a.y, a.z, b.x, b.y, b.z, ux, uy, uz
  end, 0.05)
end
local function cam_fn(fn) findScript("planet_camera").setShot(fn, 0.05) end
local function cam_off() local pc = findScript("planet_camera"); if pc.clearShot then pc.clearShot(0.05) end end
local function stand_lab(gx, gz)
  local p = labpt(gx, 0.6, gz)
  if p then stand_at(p.x, p.y, p.z, 1.6) end
end

-- Frame time with vsync off (the CPU's wall clock a frame) and the GPU's own
-- time (perf.gpu, averaged), and what was drawn.
local function frame_ms(secs, tag)
  if app and app.setVsync then pcall(app.setVsync, "Off") end
  if perf and perf.enable then pcall(perf.enable, true) end
  frames(30)
  local n, t0 = 0, W()
  local gsum, gn = 0, 0
  local passes = {}
  while W() - t0 < secs do
    yield(); n = n + 1
    local ok, g = pcall(perf.gpu)
    if ok and g and g.total then
      gsum, gn = gsum + g.total, gn + 1
      for _, ps in ipairs(g.passes or {}) do passes[ps.name] = (passes[ps.name] or 0) + ps.ms end
    end
  end
  local dt = (W() - t0) / math.max(1, n)
  local pc = perf.counts and perf.counts() or {}
  local top = {}
  for k, v in pairs(passes) do top[#top + 1] = { k, v / math.max(1, gn) } end
  table.sort(top, function(a, b) return a[2] > b[2] end)
  local tl = {}
  for i = 1, math.min(5, #top) do tl[#tl + 1] = string.format("%s %.2f", top[i][1], top[i][2]) end
  P("PERF %s: %.2f ms/frame CPU wall (%d frames), GPU %.2f ms; draws %s lights %s nodes %s; gpu: %s", tag or "", dt * 1000, n,
    gsum / math.max(1, gn), tostring(pc.draws), tostring(pc.lights), tostring(pc.nodes), table.concat(tl, ", "))
  if app and app.setVsync then pcall(app.setVsync, "On") end
  return dt * 1000, n
end

local function exterior_and_tube()
  local fac = wait_for(function() return find("FacIntake") end, 30, "the intake")
  local L = wait_for(function() local l = lab(); return l and l.ROOT and l.ROOT.valid and l end, 40, "the lab")
  if not (fac and L) then R("lab_present", false) return end
  R("lab_present", true, "FacLab and its script are up")
  wait_for(function() return L.received ~= nil and find("Lab Tube Glass") end, 30, "the tube mesh")
  R("tube_mesh", find("Lab Tube Glass") ~= nil, "the outdoor tube is built")
  local mi = wait_for(function() local s = fac:getScript("material_intake"); return s and s.belt and s.belt() and s end, 20, "the belt")
  local G = mi.belt()
  local sx, sy, sz = mi.beltWorld(4.0, -4.2, 0)
  stand_at(sx, sy, sz)
  hold(1.5)
  if params.shots == 1 then
    cam_lab({ -20, 5.5, 3 }, { -9, 4.2, 15 })
    hold(0.8)
    shot("ext_tube_side")
    cam_lab({ -28, 22, 40 }, { -6, 2, 8 })
    hold(0.8)
    shot("ext_aerial")
    cam_lab({ 18, 2.2, 13 }, { 6, 2.5, 6 })
    hold(0.8)
    shot("ext_link_door")
    cam_lab({ 8, 1.7, 20.5 }, { 8, 1.5, 8 })
    hold(0.8)
    shot("ext_link_corridor")
    cam_off()
  end
  local rs = findScript("research")
  local p0 = rs.points()
  drop("LooseLog", 1.4, 0, 0.9, "timber", 3, true)
  drop("LooseRock", 3.2, 0.3, 0.6, "iron", 2)
  drop("LooseRock", 4.6, -0.4, 0.6, "basalt", 3)
  -- watch for a capsule in the outdoor run
  local cap = wait_for(function()
    for _, n in ipairs(findTagged and {} or {}) do end
    local c = nil
    for _, s in ipairs({ "LabCapsule" }) do c = find(s) end
    return c and c.visible and c
  end, 40, "a capsule")
  if cap and params.shots == 1 then
    hold(0.5)
    cam_fn(function()
      if not cap.valid then return nil end
      local p = cap.worldPos
      local ux, uy, uz = labup()
      local r = lab().ROOT:toWorld(vec3(1, 0, 0)); local o = lab().ROOT.worldPos
      local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
      return p.x - rx * 2.2 + ux * 0.6, p.y - ry * 2.2 + uy * 0.6, p.z - rz * 2.2 + uz * 0.6, p.x, p.y, p.z, ux, uy, uz
    end)
    hold(0.15)
    shot("tube_capsule_close")
    cam_lab({ -20, 5.5, 3 }, { -9, 4.2, 15 })
    hold(0.2)
    shot("tube_capsule_wide")
    cam_off()
  end
  wait_for(function() return (L.received or 0) >= 3 end, 60, "three capsules received")
  local p1 = rs.points()
  local list = rs.studiedList()
  local names = {}
  for _, r in ipairs(list) do names[#names + 1] = string.format("%s %d u %.1f rp", r.mat, r.n, r.rp) end
  R("research_points", p1 > p0, "RP %d → %d; studied: %s; capsules received %d", p0, p1, table.concat(names, ", "), L.received or 0)
  -- a second load of a kind already studied earns less than the first
  local before = rs.points()
  local g1 = rs.study("iron", 2, nil)
  R("research_repeat", g1 >= 0 and rs.points() >= before, "a second iron x2 earns %d", g1)
  -- (for the talk view's list: a fictional one, a geode)
  rs.study("crystal", 2, nil)
  rs.study("geode", 1, nil)
  local hud = findScript("status_hud")
  R("hud_line", hud and (hud.line or ""):match("research") ~= nil, "HUD: %s", hud and hud.line or "?")
end

local function interior()
  local L = lab()
  stand_lab(8.0, 5.6)        -- in the vestibule
  local on = wait_for(function() return L.inside end, 10, "the interior on")
  R("interior_on", on == true, "standing in the vestibule")
  hold(2.0)
  if params.shots == 1 then
    local VIEWS = {
      { "int_from_door", { 6.0, 1.7, 2.8 }, { -8, 1.1, -1.5 } },
      { "int_nw_corner", { -10.2, 2.9, -4.8 }, { 3, 0.8, 3 } },
      { "int_receiving", { -6.3, 1.6, 2.2 }, { -8, 1.25, 4.6 } },
      { "int_hoods", { -5.6, 1.65, -2.6 }, { -8.2, 1.35, -6.4 } },
      { "int_instruments", { 3.6, 1.65, -1.3 }, { 7.5, 1.2, -5.6 } },
      { "int_floor_low", { 1.0, 0.45, 5.0 }, { -6, 0.8, -3 } },
      { "int_island", { -3.0, 1.75, 2.6 }, { -6.0, 1.0, 0.2 } },
      { "int_vestibule", { 10.2, 2.0, 6.2 }, { 5.0, 1.2, 1.0 } },
    }
    for _, v in ipairs(VIEWS) do
      cam_lab(v[2], v[3])
      hold(0.6)
      shot(v[1])
    end
    cam_off()
  end
  if params.perf == 1 then
    -- inside, looking across the lab (the camera's own view, the crew in it)
    cam_lab({ 6.0, 1.7, 2.8 }, { -8, 1.1, -1.5 })
    hold(1.0)
    frame_ms(5.0, "inside")
    cam_off()
  end
end

local function scientists()
  local L = lab()
  local list = L.scientists or {}
  R("scientists", #list >= 2, "%d scientists at their stations", #list)
  for i, s in ipairs(list) do
    local n = s.node
    if n and n.valid then
      -- stand the crew back so the camera is the only one near
      local hp = function()
        local face = nil
        for _, c in ipairs(n:children() or {}) do
          if c.name == "LabModel" then for _, k in ipairs(c:children() or {}) do if k.name == "Face" then face = k end end end
        end
        return face and face.worldPos or n:toWorld(vec3(0, 0.72, 0))
      end
      local sc = n:getScript("scientist")
      local sg = sc and sc.faceSign or 1
      for _, v in ipairs({ { "front", 0, 0.62, 0.0 }, { "34", 0.55, 0.5, 0.02 }, { "side", 0.95, 0.0, 0.0 },
                           { "chin", 0.15, 0.42, -0.30 }, { "back", 0.4, -0.6, 0.08 } }) do
        if params.shots == 1 then
          cam_fn(function()
            if not n.valid then return nil end
            local h = hp()
            local o = n.worldPos
            local f = n:toWorld(vec3(0, 0, sg)); local r = n:toWorld(vec3(1, 0, 0)); local u = n:toWorld(vec3(0, 1, 0))
            local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
            local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
            local ux, uy, uz = u.x - o.x, u.y - o.y, u.z - o.z
            local a, b, c = v[2], v[3], v[4]
            local cx = h.x + rx * a + fx * b + ux * c
            local cy = h.y + ry * a + fy * b + uy * c
            local cz = h.z + rz * a + fz * b + uz * c
            return cx, cy, cz, h.x - ux * 0.08, h.y - uy * 0.08, h.z - uz * 0.08, ux, uy, uz
          end)
          hold(0.5)
          shot(string.format("sci%d_%s", i, v[1]))
        end
      end
      if params.shots == 1 then
        cam_fn(function()
          if not n.valid then return nil end
          local o = n.worldPos
          local f = n:toWorld(vec3(0, 0, sg)); local u = n:toWorld(vec3(0, 1, 0)); local r = n:toWorld(vec3(1, 0, 0))
          local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
          local ux, uy, uz = u.x - o.x, u.y - o.y, u.z - o.z
          local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
          return o.x + fx * 2.6 + rx * 0.9 + ux * 0.6, o.y + fy * 2.6 + ry * 0.9 + uy * 0.6, o.z + fz * 2.6 + rz * 0.9 + uz * 0.6,
            o.x, o.y, o.z, ux, uy, uz
        end)
        hold(0.5)
        shot(string.format("sci%d_full", i))
      end
    end
  end
  cam_off()
end

local function talk()
  local L = lab()
  local lt = findScript("lab_talk")
  local s = L.scientists and L.scientists[1]
  if not (lt and s) then R("talk", false, "no talk view / scientist") return end
  -- walk up to Dr 1 (in front of them, a metre off)
  local n = s.node
  local sc = n:getScript("scientist")
  local sg = sc and sc.faceSign or 1
  local o = n.worldPos
  local f = n:toWorld(vec3(0, 0, sg))
  stand_at(o.x + (f.x - o.x) * 1.3, o.y + (f.y - o.y) * 1.3, o.z + (f.z - o.z) * 1.3, 1.6)
  hold(1.0)
  local fm = findScript("facility_menu")
  local near = L.nearAstro(find("Astronaut"), 2.2)
  R("talk_prompt", near ~= nil, "the prompt finds Dr %s", near and near.staff.name or "-")
  lt.open({ node = n, idx = s.idx, staff = s.staff })
  hold(1.6)
  shot("talk_list")
  R("talk_open", lt.isOpen(), "the talk view is open")
  lt.openMaterial("iron")
  hold(2.2)
  P("stand: %s", lt.standInfo and lt.standInfo() or "?")
  shot("talk_iron")
  hold(1.5)
  shot("talk_iron_b")
  lt.openMaterial("crystal")
  hold(2.2)
  shot("talk_crystal")
  lt.openMaterial("timber")
  hold(2.2)
  shot("talk_timber")
  lt.back()
  hold(1.4)
  shot("talk_back")
  lt.close()
  hold(1.2)
  R("talk_closed", not lt.isOpen(), "closed")
end

local function outside_perf()
  if params.perf ~= 1 then return end
  local fac = find("FacIntake")
  local mi = fac and fac:getScript("material_intake")
  if not mi then return end
  local sx, sy, sz = mi.beltWorld(4.0, -4.2, 0)
  stand_at(sx, sy, sz)
  hold(2.0)
  cam_lab({ -20, 5.5, 3 }, { -9, 4.2, 15 })
  hold(1.0)
  local L = lab()
  R("interior_off_outside", not L.inside, "the interior is switched off from the yard")
  frame_ms(5.0, "outside")
  -- …and the same view with the interior forced on: what switching it off saves
  local L2 = lab()
  L2.forceInside = true
  frames(20)
  frame_ms(5.0, "outside, interior forced on")
  L2.forceInside = false
  cam_off()
end

local function main()
  boot()
  hold(3.0)
  exterior_and_tube()
  outside_perf()
  interior()
  scientists()
  talk()
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
