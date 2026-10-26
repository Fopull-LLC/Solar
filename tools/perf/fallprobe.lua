-- FALLPROBE: does the crew fall through the planet? (caves, drops, runs)
-- Run by tools/perf/fall.sh. Logs `FALL ...` lines: one per logged frame with
-- the crew's height over the field (terrain.query at the capsule centre), the
-- radius from the planet's centre, contact, velocity, ticks this frame, the
-- swim state; `FALL THROUGH` when the centre is > 1 m inside the rock.
-- params: slot (15), seed, usersave (0/1), net (0: the walker's ground net off)
defaults = { notint = 0, slot = 15, seed = 1911564384, usersave = 0, net = 0, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FALL %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local NODE, CO
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end
local SLOT
local function boot()
  SLOT = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  if params.usersave > 0 then
    save.slot(SLOT)
  else
    terrain.deleteSaveDir("saves/" .. SLOT .. "/terrain")
    if save.deleteSlot then save.deleteSlot(SLOT) end
    save.slot(SLOT)
    save.set("g_seed", math.floor(params.seed))
    for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                        g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
    local ns = findScript("menu_newsave")
    save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
  end
  perf.enable(true)
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local A, PW
local function body() local n = space.dominant(A.x, A.y, A.z); return n and space.body(n), n end
local through, minq, frames_logged = 0, 99, 0
local function state(tag, every)
  local b = body()
  local q = terrain.query(A.x, A.y, A.z)
  local rd = terrain.ready(A.x, A.y, A.z, 2.0)
  local fr = perf.frames and perf.frames(1)
  local f = fr and fr[1] or {}
  local ux, uy, uz = A.x - b.x, A.y - b.y, A.z - b.z
  local r = len(ux, uy, uz)
  local vup = (A.vx * ux + A.vy * uy + A.vz * uz) / r
  local ss = PW.swimState or {}
  local cl = findScript("climate")
  local depth = cl and cl.seaDepth(A.x, A.y, A.z)
  if q and q < minq then minq = q end
  local bad = q and q < -1.0
  if bad then through = through + 1 end
  frames_logged = frames_logged + 1
  if bad or frames_logged % (every or 6) == 0 then
    P("%s %s r %.2f q %s ready %s contact %s grounded %s vup %.2f |v| %.2f ticks %s drop %s swim %s depth %s net %d",
      bad and "THROUGH" or "s", tag, r, q and string.format("%.2f", q) or "nil", tostring(rd), tostring(A.grounded),
      tostring(PW.grounded), vup, len(A.vx, A.vy, A.vz), tostring(f.ticks), tostring(f.ticksDropped),
      tostring(PW.swimming), depth and string.format("%.2f", depth) or "nil", PW.groundNet and PW.groundNet.rescues or -1)
  end
end
local function rays(tag)
  local b = body()
  local ux, uy, uz = A.x - b.x, A.y - b.y, A.z - b.z
  local l = len(ux, uy, uz); ux, uy, uz = ux / l, uy / l, uz / l
  local h = raycast(A.x, A.y, A.z, -ux, -uy, -uz, 10.0, A)
  local th, why, wd = terrain.raycast(vec3(A.x, A.y, A.z), vec3(-ux, -uy, -uz), 10.0)
  local c = perf.counts() or {}
  P("RAYS %s physics %s | field %s %s | q %.2f ready0 %s ready8 %s standIns %s fieldChunks %s",
    tag, h and string.format("%.2f %s", h.distance, tostring(h.node and h.node.name)) or "miss",
    th and string.format("%.2f exact %s", th.distance, tostring(th.exact)) or "nil", tostring(why or ""),
    terrain.query(A.x, A.y, A.z) or 99, tostring(terrain.ready(A.x, A.y, A.z)), tostring(terrain.ready(A.x, A.y, A.z, 8)),
    tostring(c.fieldStandIns), tostring(c.fieldChunks))
end
local function watch(secs, tag, every, each)
  local t0 = time
  while time - t0 < secs do
    if each then each(time - t0) end
    yield(); state(tag, every)
  end
end

-- columns round the crew; the radius of the ground, and a void under it
local function frame_at(b)
  local ux, uy, uz = A.x - b.x, A.y - b.y, A.z - b.z
  local l = len(ux, uy, uz); ux, uy, uz = ux / l, uy / l, uz / l
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local e1x, e1y, e1z = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
  l = len(e1x, e1y, e1z); e1x, e1y, e1z = e1x / l, e1y / l, e1z / l
  local e2x, e2y, e2z = uy * e1z - uz * e1y, uz * e1x - ux * e1z, ux * e1y - uy * e1x
  return { ux, uy, uz }, { e1x, e1y, e1z }, { e2x, e2y, e2z }, l
end
local function col_dir(b, dist, ang)
  local u, e1, e2 = frame_at(b)
  local R = len(A.x - b.x, A.y - b.y, A.z - b.z)
  local th = dist / R
  local c, s = math.cos(th), math.sin(th)
  local tx, ty, tz = e1[1] * math.cos(ang) + e2[1] * math.sin(ang), e1[2] * math.cos(ang) + e2[2] * math.sin(ang), e1[3] * math.cos(ang) + e2[3] * math.sin(ang)
  return u[1] * c + tx * s, u[2] * c + ty * s, u[3] * c + tz * s, R
end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 600 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
end
local function find_cave()
  local b = body()
  local best
  for dist = 30, 420, 15 do
    for k = 0, 23 do
      local ux, uy, uz, R = col_dir(b, dist, k * math.pi / 12)
      local g = ground_r(b, ux, uy, uz, R + 120)
      if g then
        local inrock, r = false, g - 0.5
        for _ = 1, 50 do
          local px, py, pz = b.x + ux * r, b.y + uy * r, b.z + uz * r
          local d = terrain.query(px, py, pz)
          if not d then break end
          if not terrain.ready(px, py, pz) then break end
          if d < -0.5 then inrock = true
          elseif inrock and d > 1.2 then
            -- the floor under this void
            local f = r
            for _ = 1, 40 do
              local dd = terrain.query(b.x + ux * f, b.y + uy * f, b.z + uz * f)
              if not dd or dd < 0.05 then break end
              f = f - 0.25
            end
            return { ux = ux, uy = uy, uz = uz, floor = f, ground = g, dist = dist, ang = k }
          end
          r = r - 0.75
        end
      end
    end
    yield()
  end
end
local function put(b, ux, uy, uz, r)
  A.x, A.y, A.z = b.x + ux * r, b.y + uy * r, b.z + uz * r
  A.vx, A.vy, A.vz = 0, 0, 0
end

local function run()
  boot()
  A = find("Astronaut")
  PW = findScript("planet_walker")
  PW.groundNetOn = params.net > 0
  if (params.notint or 0) > 0 then
    for _, ff in ipairs(findScripts("flora_field")) do ff.params.tint = 0 end
    P("flora tint decals off")
  end
  P("ready; net %s", tostring(PW.groundNetOn))
  watch(3, "idle", 30)
  -- controls: lifted 5 m where we stand; 3 m over ground 30 m off; a run
  do
    local b = body()
    local ux, uy, uz, R = col_dir(b, 0, 0)
    local g = ground_r(b, ux, uy, uz, R + 20)
    put(b, ux, uy, uz, g + 5); P("CONTROL lift 5 m (ground %.1f)", g)
    watch(3, "ctl-lift", 6)
    b = body(); ux, uy, uz, R = col_dir(b, 30, 2.0)
    g = ground_r(b, ux, uy, uz, R + 40)
    put(b, ux, uy, uz, g + 3); P("CONTROL 30 m off, 3 m up (ground %.1f)", g)
    watch(3, "ctl-off30", 6)
    watch(8, "ctl-run", 12, function(t) PW.steer(1, 0, true, false, 0) end)
    PW.steer(nil)
    watch(1, "ctl-stop", 12)
  end

  -- 1. a cave near the base: stand on its floor, run about, jump
  local cv = find_cave()
  if cv then
    P("CAVE at %d m (dir %d): ground r %.1f floor r %.1f (%.1f m under)", cv.dist, cv.ang, cv.ground, cv.floor, cv.ground - cv.floor)
    local b = body()
    -- the collision ray at the cave floor with the crew far away, then with it there
    for i = 1, 40 do
      b = body()
      local r = cv.floor + 1.3
      local h = raycast(b.x + cv.ux * r, b.y + cv.uy * r, b.z + cv.uz * r, -cv.ux, -cv.uy, -cv.uz, 10.0, A)
      if i % 5 == 1 then P("EMPTY-CAVE ray %d: %s", i, h and string.format("%.2f", h.distance) or "miss") end
      yield()
    end
    b = body()
    put(b, cv.ux, cv.uy, cv.uz, cv.floor + 1.3)
    for i = 1, 12 do
      b = body()
      local r = cv.floor + 1.3
      local h = raycast(b.x + cv.ux * r, b.y + cv.uy * r, b.z + cv.uz * r, -cv.ux, -cv.uy, -cv.uz, 10.0, A)
      local h2 = raycast(b.x + cv.ux * r + 6 * cv.uy, b.y + cv.uy * r, b.z + cv.uz * r, -cv.ux, -cv.uy, -cv.uz, 10.0, A)
      P("CREW-IN ray %d: at the put spot %s | crew q %.2f asleep %s", i, h and string.format("%.2f", h.distance) or "miss",
        terrain.query(A.x, A.y, A.z) or 99, tostring(A.asleep))
      yield()
    end
    rays("cave-put")
    watch(0.1, "cave-stand", 1); rays("cave+0.1")
    watch(0.5, "cave-stand", 3); rays("cave+0.6")
    watch(3.4, "cave-stand", 10)
    -- again, with the ground there made exactly first (terrain.prepare)
    b = body()
    local cx, cy, cz = b.x + cv.ux * cv.floor, b.y + cv.uy * cv.floor, b.z + cv.uz * cv.floor
    terrain.prepare(cx, cy, cz, 24)
    wait_for(function() return terrain.ready(cx, cy, cz, 24) end, 20, "prepare")
    b = body()
    put(b, cv.ux, cv.uy, cv.uz, cv.floor + 1.3)
    rays("prep-put")
    watch(0.1, "prep-stand", 1); rays("prep+0.1")
    watch(3, "prep-stand", 10); rays("prep+3")
    for _, d in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, -1 } }) do
      watch(2.5, "cave-run", 6, function(t) PW.steer(d[1], d[2], true, t > 1.0 and t < 1.1, 0) end)
    end
    PW.steer(nil)
    watch(2, "cave-stop", 10)
    -- dropped into the cave from its roof's underside
    b = body()
    local ux, uy, uz = cv.ux, cv.uy, cv.uz
    local top = cv.floor
    for _ = 1, 60 do
      local d = terrain.query(b.x + ux * (top + 0.5), b.y + uy * (top + 0.5), b.z + uz * (top + 0.5))
      if not d or d < 0.6 then break end
      top = top + 0.5
    end
    P("CAVE void height %.1f m", top - cv.floor)
    put(b, ux, uy, uz, top - 0.6)
    watch(4, "cave-drop", 3)
  else
    P("no cave found")
  end

  -- 2. dropped from 60 m and 150 m onto ground no one has stood on
  for i, h in ipairs({ 60, 150 }) do
    local b = body()
    local ux, uy, uz, R = col_dir(b, 260 + 70 * i, 1.0 + i)
    local g = ground_r(b, ux, uy, uz, R + 150)
    if g then
      put(b, ux, uy, uz, g + h)
      P("DROP %d m from r %.1f (ground %.1f)", h, g + h, g)
      watch(h > 100 and 10 or 7, "drop" .. h, 4)
    end
  end
  P("SUMMARY through-frames %d min q %.2f net rescues %d", through, minq, PW.groundNet and PW.groundNet.rescues or -1)
  if params.usersave == 0 then
    if save.deleteSlot then save.deleteSlot(SLOT) end
  end
  if params.quit > 0 then app.quit() end
end

function start(node)
  NODE = node
  CO = coroutine.create(function()
    local ok, e = pcall(run)
    if not ok then P("ERROR %s", tostring(e)) end
  end)
end
function update(node, dt)
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, e = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(e)) end
  end
end
