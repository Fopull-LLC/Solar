-- ── sea probe (tools/perf/seaprobe.sh): the sea's Water Volume and node handles ──
-- `handle`: engine card 0552. A node is made and destroyed, then nodes are made
-- until one takes its id; the old handle must read valid=false, name=nil, and
-- never equal the new node. `SH RESULT: PASS / FAIL / INCONCLUSIVE`.
-- `sea`: engine card 0551 (prefabs/Sea.prefab.ron's Sea Volume density). The
-- crew is put 3 m under the home world's sea, then on its surface, then a rover
-- is dropped into it: the swim state, water.at, climate.seaDepth, pictures of
-- the underwater look, and the rover's height against the sea's radius each
-- second (Solar floats craft itself: vessel_controller waterTick). Run it with
-- the prefab as committed and with density 0.0 (PATCHES=sea_density0.patch) and
-- count the engine's `≈ ... density` warnings in the two logs.
local function sh_run()
  local old, made = nil, false
  createNode("Handle Probe Old", function(n) old = n; made = true end)
  wait_for(function() return made end, 5, "old node")
  local oid = old.id
  old:destroy()
  yield(); yield()
  local twin, list, n = nil, {}, 0
  for i = 1, 200 do
    createNode("Handle Probe New " .. i, function(m) list[#list + 1] = m; n = n + 1 end)
  end
  wait_for(function() return n >= 200 end, 10, "new nodes")
  for _, m in ipairs(list) do if m.id == oid then twin = m end end
  P("SH old id %s; after 200 new nodes: old.valid %s old.name %s; twin %s", tostring(oid), tostring(old.valid),
    tostring(old.name), twin and (twin.name .. "#" .. twin.id) or "none")
  local pass
  if not twin then
    P("SH RESULT: INCONCLUSIVE (the slot was not reused)")
  else
    local ok_eq = not rawequal(old, twin) and not (old == twin)
    local wrote_ok = pcall(function() old.x = 123 end)
    pass = old.valid == false and old.name == nil and ok_eq and math.abs((twin.x or 0) - 123) > 1e-6
    P("SH old==twin %s, write through old reached twin %s (pcall %s)", tostring(old == twin),
      tostring(math.abs((twin.x or 0) - 123) < 1e-6), tostring(wrote_ok))
    P("SH RESULT: %s", pass and "PASS" or "FAIL")
  end
  for _, m in ipairs(list) do if m.valid then m:destroy() end end
end

local function sea_log(tag, A)
  local b = home()
  local cl = findScript("climate")
  local pw = findScript("planet_walker")
  local R = cl and cl.seaRadius(b.name) or 0
  local r = len(A.x - b.x, A.y - b.y, A.z - b.z)
  local w = water.at(vec3(A.x, A.y, A.z))
  local cam = find("Camera 1")
  local cw = cam and water.at(vec3(cam.x, cam.y, cam.z))
  P("SEA %s: r-R %.2f swim %s seaDepth %s water.at %s camera water.at %s",
    tag, r - R, tostring(pw and pw.swimming), tostring(cl and cl.seaDepth(A.x, A.y, A.z)),
    w and string.format("depth %.2f density %s node %s", w.depth or -1, tostring(w.density), tostring(w.node and w.node.name)) or "nil",
    cw and string.format("depth %.2f", cw.depth or -1) or "nil")
end

local function sea_shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://seashots/" .. nm .. ".png", bytes); P("SHOT %s", nm)
    else P("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- the deepest open sea in a scan round the home world (a Fibonacci sphere)
local function find_sea(b, R)
  local best, bu
  local N = 600
  for i = 0, N - 1 do
    local y = 1 - (i + 0.5) / N * 2
    local rr = math.sqrt(1 - y * y)
    local th = i * 2.399963
    local u = { x = math.cos(th) * rr, y = y, z = math.sin(th) * rr }
    local g = ground_r(b, u.x, u.y, u.z, b.radius * 1.3)
    if g and R - g > (best or 8) then best, bu = R - g, u end
    if i % 40 == 0 then yield() end
  end
  return bu, best
end

local function run_sea()
  wait_ready(90)
  sh_run()
  local b = home()
  local cl = findScript("climate")
  local R = cl and cl.seaRadius(b.name) or 0
  local vols = water.volumes and water.volumes() or {}
  for _, v in ipairs(vols) do
    local okc, m = pcall(function() return v:getcomponent("WaterVolume") end)
    if not okc then m = nil end
    P("SEA volume %s density %s", tostring(v.name), tostring(m and m.density))
  end
  P("SEA world %s radius %.1f sea radius %.1f", b.name, b.radius, R)
  if R <= 0 then P("SEA RESULT: no sea on the home world"); return end
  local u, deep = find_sea(b, R)
  if not u then P("SEA RESULT: no open sea found"); return end
  P("SEA deepest spot: %.1f m of water", deep)
  local A = astro()
  local function put(r)
    b = home()
    A.x, A.y, A.z = b.x + u.x * r, b.y + u.y * r, b.z + u.z * r
    A.vx, A.vy, A.vz = 0, 0, 0
  end
  -- the crew 3 m under: swims (Solar's own), water.at, the underwater look
  put(R - 3)
  for i = 1, 8 do wait(0.5); sea_log("under t=" .. (i * 0.5), A) end
  sea_shot("1_under")
  -- on the surface
  put(R + 0.5)
  for i = 1, 8 do wait(0.5); sea_log("surface t=" .. (i * 0.5), A) end
  sea_shot("2_surface")
  -- the underwater look: the free camera 3 m under the sea, looking level
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam and pc.freecamState then
    pc.setFreecam(true); wait(0.3)
    b = home()
    local fc = pc.freecamState()
    fc.body = b.name
    fc.rel = vec3(u.x, u.y, u.z) * (R - 3)
    fc.pitch = -0.2
    local f = vec3(u.x, u.y, u.z):cross(vec3(1, 0, 0))
    fc.ref = f:normalized()
    wait(1.5)
    sea_log("camera 3 m under", A)
    sea_shot("1b_camera_under")
    fc.rel = vec3(u.x, u.y, u.z) * (R + 2)
    wait(1.0)
    sea_log("camera 2 m over", A)
    sea_shot("1c_camera_over")
    pc.setFreecam(false); wait(0.5)
  end
  -- a craft in the sea: Solar floats it (waterTick)
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then P("SEA RESULT: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(1)
  b = home()
  u = find_sea(b, R) or u   -- again: the world turns under a fixed direction
  -- drop it 3 m over the sea, 15 m off the crew
  local t = unit(cross(u, { x = 0, y = 1, z = 0 }))
  local at = { x = b.x + u.x * (R + 3) + t.x * 15, y = b.y + u.y * (R + 3) + t.y * 15, z = b.z + u.z * (R + 3) + t.z * 15 }
  assembly.teleport(vn, vec3(at.x, at.y, at.z))
  local hs = {}
  for i = 1, 15 do
    wait(1)
    b = home()
    local inf = assembly.info(vn)
    local c = inf.com
    local h = len(c.x - b.x, c.y - b.y, c.z - b.z) - R
    hs[#hs + 1] = h
    P("SEA craft t=%d: com over the sea %.2f m (%+.2f in 1 s), asleep %s", i, h, h - (hs[i - 1] or h), tostring(inf.asleep))
  end
  local lo, hi = 1e9, -1e9
  for i = 8, #hs do lo, hi = math.min(lo, hs[i]), math.max(hi, hs[i]) end
  P("SEA RESULT craft: com %.2f..%.2f m over the sea for t=8..15 s (%s)", lo, hi,
    (lo > -3 and hi < 3) and "floats" or "SINKS or flies")
  -- the crew under once more, looking at the craft from below
  put(R - 2)
  wait(2)
  sea_log("under again", A)
  sea_shot("3_under_again")
end
