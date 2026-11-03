-- LABFIX: the Research Lab playtest fixes of 2026-11-03 in the real game, on a
-- NEW Career save (tools/perf/labfix.sh; scripts/lab.lua, scientist.lua,
-- lab_talk.lua, face.lua, prefabs/LabInterior, prefabs/LabScientist):
--
--   1. the crew waits in the yard (the interior off, the planet moving on),
--      then WALKS from the depot through the link into the lab
--   2. walks into every solid thing (benches, hood, partitions, glove box,
--      freezer, stool, eyewash, bench, the four scientists) and logs whether
--      it was blocked, with a ray along the same line
--   3. approaches each scientist: shots of their look from two angles, and
--      the head's yaw against the crew's while the crew walks past
--   4. each scientist's pose from the front, three quarters and the side
--   5. the talk view for each of the four: the medium shot and the close-up,
--      where the camera stood and whether anything overlaps it
--
-- Pictures (1280x720) to user://labfix/, lines "LFX ", one RESULT a check.
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4, shots = 1, yard = 6.0, walkonly = 0, debug = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("LFX %7.2f " .. fmt, W() - W0, ...)) end
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
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://labfix/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  local t = W() + 5
  while pending > 0 and W() < t do coroutine.yield() end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function key(k, down) input.simulate { key = k, down = down } end

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
local function labaxes()
  local L = lab()
  local o = L.ROOT.worldPos
  local u = L.ROOT:toWorld(vec3(0, 1, 0))
  local r = L.ROOT:toWorld(vec3(1, 0, 0))
  local f = L.ROOT:toWorld(vec3(0, 0, 1))
  return { x = u.x - o.x, y = u.y - o.y, z = u.z - o.z }, { x = r.x - o.x, y = r.y - o.y, z = r.z - o.z },
         { x = f.x - o.x, y = f.y - o.y, z = f.z - o.z }
end
-- world point → ground frame (drawn poses, now)
local function toground(p)
  local L = lab()
  local q = L.ROOT:toLocal(p)
  return q.x, q.y + 4.24, q.z + 2.05
end
local function astro() return find("Astronaut") end
local function stand_lab(gx, gz)
  local a = astro()
  local p = labpt(gx, 0.15 + 1.1, gz)
  local u = labaxes()
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.0) end
end
local function face_dir(gdx, gdz, pitch)
  local _, r, f = labaxes()
  local pc = findScript("planet_camera")
  pc.face(r.x * gdx + f.x * gdz, r.y * gdx + f.y * gdz, r.z * gdx + f.z * gdz, pitch or -0.15)
end
local function cam_fn(fn) findScript("planet_camera").setShot(fn, 0.05) end
local function cam_off() local pc = findScript("planet_camera"); if pc.clearShot then pc.clearShot(0.05) end end
local function cam_lab(c, t)
  cam_fn(function()
    local a, b = labpt(c[1], c[2], c[3]), labpt(t[1], t[2], t[3])
    if not (a and b) then return nil end
    local u = labaxes()
    return a.x, a.y, a.z, b.x, b.y, b.z, u.x, u.y, u.z
  end)
end

-- Walk toward a ground-frame point, holding W, for at most `secs`; returns
-- the ground-frame track's last point.
local function walk_to(gx, gz, secs, stop_d)
  local a = astro()
  local t0 = W()
  key("w", true)
  local lx, lz
  while W() - t0 < secs do
    local x, _, z = toground(a.worldPos)
    lx, lz = x, z
    local dx, dz = gx - x, gz - z
    if math.sqrt(dx * dx + dz * dz) < (stop_d or 0.4) then break end
    face_dir(dx, dz, -0.15)
    yield()
  end
  key("w", false)
  hold(0.3)
  local x, _, z = toground(a.worldPos)
  return x, z
end

-- 1. the yard, then the walk in
local function walk_in()
  local L = wait_for(function() local l = lab(); return l and l.ROOT and l.ROOT.valid and l.interior and l end, 60, "the lab")
  if not L then R("lab_present", false) return false end
  -- out in the yard, the interior off, while the planet moves on
  stand_lab(-14.0, 20.0)
  hold(1.0)
  local off = wait_for(function() return not L.inside end, 10, "the interior off")
  R("interior_off_in_yard", off == true, "inside=%s", tostring(L.inside))
  local b0 = home()
  local x0, y0, z0 = b0.x, b0.y, b0.z
  hold(params.yard)
  local b1 = home()
  P("the planet moved %.0f m while the crew was in the yard (%.1f s)", len(b1.x - x0, b1.y - y0, b1.z - z0), params.yard)
  -- into the depot, then walk: through the link, the lab's door, the vestibule, the inner door
  stand_lab(8.0, 19.0)
  hold(1.5)
  local path = { { 8.0, 11.0 }, { 8.0, 7.6 }, { 8.0, 5.0 }, { 5.6, 4.95 }, { 3.0, 3.0 } }
  local ok = true
  for i, p in ipairs(path) do
    local x, z = walk_to(p[1], p[2], 12, 0.45)
    local d = math.sqrt((x - p[1]) ^ 2 + (z - p[2]) ^ 2)
    P("walk leg %d to (%.1f, %.1f): at (%.2f, %.2f) d %.2f", i, p[1], p[2], x, z, d)
    if d > 0.8 then ok = false end
  end
  R("walked_in_from_depot", ok and L.crewInLab, "crewInLab=%s inside=%s", tostring(L.crewInLab), tostring(L.inside))
  if not L.crewInLab then stand_lab(3.0, 3.0); hold(1.0) end
  return true
end

-- 2. walk into each solid thing
-- { name, start x, z, dir x, z, distance to its near face from the start, control, half width }
-- Through = the crew's centre got past the near face within the thing's half
-- width (sliding round a person or a post is being blocked, not through).
local SOLIDS = {
  { "open aisle (control)", 2.0, 2.9, -1, 0, 9.0, true },
  { "island bench W (south face)", -7.0, 2.4, 0, -1, 1.22 },
  { "island bench E (south face)", 1.5, 2.4, 0, -1, 1.22 },
  { "island bench W (north face)", -4.0, -1.8, 0, 1, 1.32 },
  { "south wall bench", -2.0, 4.2, 0, 1, 1.67 },
  { "receiving cabinet", -7.0, 2.5, 0, 1, 1.50 },
  { "fume hood 3", -5.4, -4.0, 0, -1, 1.70 },
  { "sink bench", 0.0, -4.4, 0, -1, 1.47 },
  { "eyewash", -3.4, -4.4, 0, -1, 1.71, false, 0.2 },
  { "instrument glass (z)", 6.0, 0.0, 0, -1, 1.96 },
  { "instrument glass (x)", -0.5, -4.0, 1, 0, 1.96 },
  { "vestibule glass (z)", 8.4, 1.5, 0, 1, 1.86 },
  { "vestibule glass (x)", 4.5, 3.9, 1, 0, 1.66 },
  { "glove box", -8.0, -0.6, -1, 0, 1.80 },
  { "freezer", 8.0, 2.25, 1, 0, 1.77 },
  { "west cupboards", -8.5, 1.6, -1, 0, 1.52 },
  { "SEM stool", 3.4, -3.4, 0, -1, 1.75 },
  { "vestibule bench", 8.4, 5.4, 0, -1, 1.50 },
  { "Dr Imani Okafor (Sci 1)", -7.65, 1.9, 0, 1, 1.66, false, 0.24 },
  { "Dr Felix Haddad (Sci 2)", -5.2, 3.3, 0, -1, 1.68, false, 0.24 },
  { "Dr Hana Nakamura (Sci 3)", -7.5, -3.6, 0, -1, 1.66, false, 0.24 },
  { "Dr Ravi Pillai (Sci 4)", 3.0, 3.3, 0, -1, 1.68, false, 0.24 },
}
local function walk_tests()
  local L = lab()
  L.forceDoors = false
  local a = astro()
  local nblocked, nsolid = 0, 0
  for _, t in ipairs(SOLIDS) do
    local name, sx, sz, dx, dz, face, control, hw = t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8] or 2.0
    stand_lab(sx, sz)
    face_dir(dx, dz, -0.1)
    hold(0.6)
    local x0, _, z0 = toground(a.worldPos)
    -- the ray along the same line, at the waist
    local p0 = labpt(x0, 1.0, z0)
    local _, r, f = labaxes()
    local wd = { x = r.x * dx + f.x * dz, y = r.y * dx + f.y * dz, z = r.z * dx + f.z * dz }
    local okr, hit = pcall(raycast, p0.x, p0.y, p0.z, wd.x, wd.y, wd.z, face + 1.0, { ignore = a })
    local hitname = (okr and hit and hit.node and hit.node.name) or "-"
    local hitd = (okr and hit and hit.distance) or -1
    -- walk at it for 2.5 s (straight on, no steering)
    local best, side, through = 0, 0, false
    local t0 = W()
    key("w", true)
    while W() - t0 < 2.5 do
      face_dir(dx, dz, -0.1)
      yield()
      local x, _, z = toground(a.worldPos)
      local pr, sd = (x - x0) * dx + (z - z0) * dz, math.abs((x - x0) * dz - (z - z0) * dx)
      best = math.max(best, pr)
      side = math.max(side, sd)
      if pr > face + 0.05 and sd < hw then through = true end
    end
    key("w", false)
    hold(0.2)
    local blocked = not through
    if control then
      R("walk " .. name, not blocked and best > 2.0, "went %.2f m (ray: %s at %.2f)", best, hitname, hitd)
    else
      nsolid = nsolid + 1
      if blocked then nblocked = nblocked + 1 end
      R("walk " .. name, blocked, "%s: got %.2f m of %.2f to its face, %.2f m sideways (ray: %s at %.2f)",
        blocked and (best > face + 0.05 and "BLOCKED (slid round it)" or "BLOCKED") or "WALKED THROUGH", best, face, side, hitname, hitd)
    end
  end
  R("solids_blocked", nblocked == nsolid, "%d of %d solids blocked the crew", nblocked, nsolid)
end

-- the scientist's head (drawn), facing axes
local function sci_frame(n)
  local sc = n:getScript("scientist")
  local sg = sc and sc.faceSign or 1
  local face = nil
  for _, c in ipairs(n:children() or {}) do
    if c.name == "LabModel" then for _, k in ipairs(c:children() or {}) do if k.name == "Face" then face = k end end end
  end
  local h = face and face.worldPos or n:toWorld(vec3(0, 0.72, 0))
  local o = n.worldPos
  local f = n:toWorld(vec3(0, 0, sg)); local r = n:toWorld(vec3(1, 0, 0)); local u = n:toWorld(vec3(0, 1, 0))
  return h, { x = f.x - o.x, y = f.y - o.y, z = f.z - o.z }, { x = r.x - o.x, y = r.y - o.y, z = r.z - o.z },
         { x = u.x - o.x, y = u.y - o.y, z = u.z - o.z }, sc
end
local function crew_head()
  local a = astro()
  for _, c in ipairs(a:children() or {}) do
    if c.name == "AstroModel" then for _, k in ipairs(c:children() or {}) do if k.name == "Face" then return k.worldPos end end end
  end
  return a:toWorld(vec3(0, 0.62, 0))
end

-- 4. poses (the crew far off: idle)
local function poses()
  local L = lab()
  stand_lab(9.0, -0.5)
  hold(0.8)
  for i, s in ipairs(L.scientists or {}) do
    local n = s.node
    for _, v in ipairs({ { "front", 0, 1.35, 0.05 }, { "34", 0.95, 0.95, 0.05 }, { "side", 1.35, 0.0, 0.0 },
                         { "34back", 0.9, -0.9, 0.1 } }) do
      cam_fn(function()
        if not n.valid then return nil end
        local h, f, r, u = sci_frame(n)
        local a, b, c = v[2], v[3], v[4]
        local cx = h.x + r.x * a + f.x * b + u.x * c
        local cy = h.y + r.y * a + f.y * b + u.y * c
        local cz = h.z + r.z * a + f.z * b + u.z * c
        return cx, cy, cz, h.x - u.x * 0.42, h.y - u.y * 0.42, h.z - u.z * 0.42, u.x, u.y, u.z
      end)
      hold(0.5)
      shot(string.format("pose_sci%d_%s", i, v[1]))
    end
  end
  cam_off()
end

-- 3. the look
local function looks()
  local L = lab()
  -- where the crew stands to be looked at, ground frame (the aisle by each)
  -- beside each in the aisle (a quarter turn off their work) and, for the
  -- record, behind them (past the neck's reach: they turn as far as it goes)
  local SPOT = { { -6.3, 3.3 }, { -3.85, 1.75 }, { -6.15, -5.15 }, { 4.35, 1.75 } }
  for i, s in ipairs(L.scientists or {}) do
    local n = s.node
    local sp = SPOT[i]
    -- far first: idle
    stand_lab(9.0, -0.5)
    hold(1.5)
    local _, _, _, _, sc = sci_frame(n)
    P("sci %d far: looking=%s eng %.2f", i, tostring(sc and sc.looking), sc and sc.gz and sc.gz.eng or -1)
    stand_lab(sp[1], sp[2])
    -- face the scientist
    local a = astro()
    local sx, _, sz = toground(n.worldPos)
    local ax, _, az = toground(a.worldPos)
    face_dir(sx - ax, sz - az, -0.1)
    hold(2.0)
    local h, f, r, u
    h, f, r, u, sc = sci_frame(n)
    local ch = crew_head()
    local dx, dy, dz = ch.x - h.x, ch.y - h.y, ch.z - h.z
    local cyaw = math.deg(math.atan2(dx * r.x + dy * r.y + dz * r.z, dx * f.x + dy * f.y + dz * f.z))
    local hyaw = sc and sc.gz and math.deg(sc.gz.yaw) or 0
    local want = math.max(-math.deg(sc.NECK_YAW or 1.15), math.min(math.deg(sc.NECK_YAW or 1.15), cyaw))
    R(string.format("look sci%d", i), sc and sc.looking and math.abs(hyaw - want) < 8,
      "eng %.2f; head yaw %.1f°, crew at %.1f° (clamped %.1f°), %.2f m", sc.gz.eng, hyaw, cyaw, want, len(dx, dy, dz))
    -- two angles: what the player sees (from the crew's eyes), and from above
    -- and to the side, both heads in frame
    cam_fn(function()
      if not n.valid then return nil end
      local hh = sci_frame(n)
      local c = crew_head()
      local vx, vy, vz = hh.x - c.x, hh.y - c.y, hh.z - c.z
      local l = len(vx, vy, vz)
      local uu = labaxes()
      return c.x + vx / l * 0.3 + uu.x * 0.05, c.y + vy / l * 0.3 + uu.y * 0.05, c.z + vz / l * 0.3 + uu.z * 0.05,
        hh.x - uu.x * 0.15, hh.y - uu.y * 0.15, hh.z - uu.z * 0.15, uu.x, uu.y, uu.z
    end)
    hold(0.5)
    shot(string.format("look_sci%d_pov", i))
    cam_fn(function()
      if not n.valid then return nil end
      local hh = sci_frame(n)
      local c = crew_head()
      local mx, my, mz = (hh.x + c.x) / 2, (hh.y + c.y) / 2, (hh.z + c.z) / 2
      local vx, vy, vz = hh.x - c.x, hh.y - c.y, hh.z - c.z
      local uu = labaxes()
      local sx_, sy_, sz_ = vy * uu.z - vz * uu.y, vz * uu.x - vx * uu.z, vx * uu.y - vy * uu.x
      local sl = len(sx_, sy_, sz_)
      -- to whichever side has the room (the aisle)
      local best, bs = -1, 1
      for _, sg in ipairs({ 1, -1 }) do
        local okr, hit = pcall(raycast, mx, my, mz, sx_ / sl * sg, sy_ / sl * sg, sz_ / sl * sg, 3.0, { ignore = astro() })
        local d = (okr and hit and hit.distance) or 3.0
        if d > best then best, bs = d, sg end
      end
      local d = math.min(best - 0.3, 1.6)
      return mx + sx_ / sl * bs * d + uu.x * 1.0, my + sy_ / sl * bs * d + uu.y * 1.0, mz + sz_ / sl * bs * d + uu.z * 1.0,
        mx - uu.x * 0.2, my - uu.y * 0.2, mz - uu.z * 0.2, uu.x, uu.y, uu.z
    end)
    hold(0.5)
    shot(string.format("look_sci%d_high", i))
    cam_off()
    -- walk past (moving): the head follows within a frame or so
    local worst = 0
    local t0 = W()
    key("d", true)
    local nsamp = 0
    while W() - t0 < 1.6 do
      yield()
      h, f, r, u, sc = sci_frame(n)
      ch = crew_head()
      dx, dy, dz = ch.x - h.x, ch.y - h.y, ch.z - h.z
      local cy = math.atan2(dx * r.x + dy * r.y + dz * r.z, dx * f.x + dy * f.y + dz * f.z)
      local cl = math.max(-(sc.NECK_YAW or 1.15), math.min(sc.NECK_YAW or 1.15, cy))
      if sc.looking and sc.gz.eng > 0.95 then
        nsamp = nsamp + 1
        worst = math.max(worst, math.abs(math.deg(cl - sc.gz.yaw)))
      end
    end
    key("d", false)
    P("sci %d tracking while the crew sidesteps: worst lag %.1f° over %d frames", i, worst, nsamp)
    -- walk off: back to the work
    stand_lab(9.0, -0.5)
    hold(2.5)
    h, f, r, u, sc = sci_frame(n)
    R(string.format("look_release sci%d", i), not sc.looking and sc.gz.eng < 0.15, "eng %.2f after leaving", sc.gz.eng)
  end
end

-- 5. the talk view, each scientist
local function talks()
  local L = lab()
  local lt = findScript("lab_talk")
  local pc = findScript("planet_camera")
  local SPOT = { { -6.6, 2.5 }, { -4.2, 2.6 }, { -6.4, -4.2 }, { 4.0, 2.6 } }
  local rs = findScript("research")
  if rs and rs.study then rs.study("iron", 2, nil) end
  for i, s in ipairs(L.scientists or {}) do
    stand_lab(SPOT[i][1], SPOT[i][2])
    hold(0.8)
    lt.open({ node = s.node, idx = s.idx, staff = s.staff })
    hold(1.8)
    local function check(tag)
      local c = pc.node.worldPos
      local gx, gy, gz = toground(c)
      local okq, hits = pcall(overlapSphere, c, 0.12, { ignore = { astro(), s.node } })
      local names = {}
      if okq and hits then for _, hh in ipairs(hits) do names[#names + 1] = hh.node and hh.node.name or "?" end end
      local inside = gx > -10.6 and gx < 10.6 and gz > -6.6 and gz < 6.6 and gy > 0.2 and gy < 3.4
      local pk = lt.shotPick and lt.shotPick[tag] or {}
      R(string.format("talk sci%d %s", i, tag), inside and #names == 0,
        "camera at ground (%.2f, %.2f, %.2f), spot %d %s (%.2f, %.2f), overlaps: %s", gx, gy, gz, pk.i or -1,
        pk.clear and "clear" or "TIGHTENED", pk.spot and pk.spot[1] or 0, pk.spot and pk.spot[2] or 0,
        #names > 0 and table.concat(names, ",") or "none")
    end
    check("medium")
    shot(string.format("talk_sci%d_medium", i))
    lt.openMaterial("iron")
    hold(2.2)
    check("close")
    shot(string.format("talk_sci%d_close", i))
    lt.close()
    hold(1.2)
  end
end


local function debug_stage()
  local L = lab()
  stand_lab(9.0, -0.5)
  hold(1.0)
  for i, s in ipairs(L.scientists or {}) do
    local n = s.node
    local h, f, r, u, sc = sci_frame(n)
    local o = n.worldPos
    local model = nil
    for _, c in ipairs(n:children() or {}) do if c.name == "LabModel" then model = c end end
    local function loc(p) if not p then return "nil" end
      local dx, dy, dz = p.x - o.x, p.y - o.y, p.z - o.z
      return string.format("(r %.2f u %.2f f %.2f)", dx * r.x + dy * r.y + dz * r.z, dx * u.x + dy * u.y + dz * u.z, dx * f.x + dy * f.y + dz * f.z) end
    local function bp(b) local ok, p = pcall(model.bonePos, model, b); return ok and p or nil end
    sc.debugHands = true
    hold(0.3)
    local ha = sc.handsAt or {}
    local function v(p) return p and string.format("(%.2f %.2f %.2f)", p.x, p.y, p.z) or "nil" end
    P("sci %d after IK, root frame (x left, y up, z front): Hand.L %s Hand.R %s shoulder L %s R %s", i, v(ha.L), v(ha.R), v(ha.SL), v(ha.SR))
    P("sci %d faceSign %s: Hand.L %s Hand.R %s Upperarm.L %s Upperarm.R %s Head %s board %s", i, tostring(sc.faceSign),
      loc(bp("Hand.Left")), loc(bp("Hand.Right")), loc(bp("Upperarm.Left")), loc(bp("Upperarm.Right")), loc(bp("Head")),
      sc.board and sc.board.valid ~= false and loc(sc.board.worldPos) or "-")
  end
  for _, i in ipairs({ 2, 4 }) do
    local n = L.scientists[i].node
    for _, v in ipairs({ { "front", 0, 0.9, -0.25 }, { "34", 0.65, 0.65, -0.25 } }) do
      cam_fn(function()
        local h, f, r, u = sci_frame(n)
        return h.x + r.x * v[2] + f.x * v[3] + u.x * v[4], h.y + r.y * v[2] + f.y * v[3] + u.y * v[4],
          h.z + r.z * v[2] + f.z * v[3] + u.z * v[4], h.x - u.x * 0.45, h.y - u.y * 0.45, h.z - u.z * 0.45, u.x, u.y, u.z
      end)
      hold(0.5)
      shot(string.format("dbg_sci%d_%s", i, v[1]))
    end
  end
  cam_off()
  local lt = findScript("lab_talk")
  for i, s in ipairs(L.scientists or {}) do
    lt.open({ node = s.node, idx = s.idx, staff = s.staff })
    hold(0.3)
    P("talk %d medium tries: %s", i, table.concat(lt.tries or {}, " | "))
    lt.openMaterial("iron")
    hold(0.3)
    P("talk %d close tries: %s", i, table.concat(lt.tries or {}, " | "))
    lt.close()
    hold(0.3)
  end
end

local function main()
  boot()
  hold(3.0)
  local L = lab()
  if not walk_in() then P("DONE fails %d", FAILS + 1) return end
  local n = 0
  for _, c in ipairs(lab().interior:children() or {}) do if (c.name or ""):sub(1, 9) == "LabSolid " then n = n + 1 end end
  P("interior solids: %d LabSolid boxes; scientists %d", n, #(lab().scientists or {}))
  if params.debug == 1 then debug_stage() walk_tests() P("DONE fails %d", FAILS) return end
  walk_tests()
  if params.walkonly == 1 then P("DONE fails %d", FAILS) return end
  poses()
  looks()
  talks()
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
