-- COVPROBE: SUSTAINED relay coverage in the real game (comms.lua "SUSTAINED
-- coverage", electronics.lua "sustained coverage"). Run by
-- tools/perf/covprobe.sh; `COV …` lines, one `COV RESULT <step>: PASS|FAIL`
-- a check.
--
--   1. a fresh save; a relay satellite (probe core, batteries, Relay Dish)
--      rolled out of the VAB, its fleet record put on a circular orbit 2.4
--      radii out whose plane runs over the base, the scene reloaded:
--      flight_ops brings it back in orbit
--   2. ONE relay: the history reset, warp ×`warp`, a `COV T` line every 2 s
--      (game time, warp, snapshot sky, sustained, held/window, satellites,
--      gaps) for `windows` windows: the snapshot spikes, little is HELD
--   3. VELCHECK: where comms says the relay will be (its solve state carried
--      on its conic) against where it is 20 s later — the velocity frame
--   4. THREE relays: two more records on the same orbit 120° apart, put back
--      by fleetRescan; history reset; the same log: most of the band HELD
--   5. ×`warp2` (heavy warp) for a while: the history keeps sampling the orbit
--   6. stop=map: the map open on foot over the home world from step 2 on, a
--      picture (camera.capture) after the one-relay and the three-relay runs
--
-- strs: stop = map | (none: all steps, then quit)
-- params: slot (15), seed, warp (50), warp2 (1000), windows (2.2)
defaults = { slot = 15, seed = 1911564384, quit = 1, warp = 50, warp2 = 1000, windows = 2.2 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("COV %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local function R(step, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), step, ok and "PASS" or "FAIL", ...) end
local STOP = nil
local NODE, CO
local function yield() coroutine.yield() end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false } end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

local SLOT
local function boot()
  SLOT = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. SLOT .. "/terrain")
  if save.deleteSlot then save.deleteSlot(SLOT) end
  save.slot(SLOT)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  local ns = findScript("menu_newsave")
  save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  P("world ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- probe core on three batteries under a Relay Dish
local function relay_sat()
  local l, y, u = {}, 0, 0
  local function add(id, h)
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = 0 }
    y = y + h
  end
  add("battery", 1.0); add("battery", 1.0); add("battery", 1.0); add("probe", 0.42); add("dish", 0.8)
  return l
end

local HOME, BODY, RORB, UX, UY, UZ, TX, TY, TZ
-- a circular orbit through the base's zenith, `ph` radians round from it
local function orbit_state(ph)
  local c, s = math.cos(ph), math.sin(ph)
  local vc = math.sqrt(BODY.mu / RORB)
  return (UX * c + TX * s) * RORB, (UY * c + TY * s) * RORB, (UZ * c + TZ * s) * RORB,
         (-UX * s + TX * c) * vc, (-UY * s + TY * c) * vc, (-UZ * s + TZ * c) * vc
end

local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end

local function to_orbit()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  if rs and rs.grant then rs.grant("probe", "probe"); rs.grant("dish", "probe") end
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  local a = find("Astronaut")
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  local B = findScript("builder")
  wait(1)
  local bp = relay_sat()
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid then local i = assembly.info(v.node); if i and #i.parts >= #bp then return v end end
    end
  end, 200, "the craft on the pad")
  if not vc then return nil end
  wait(3)
  if vc.releaseClamps then vc.releaseClamps() end
  wait(2)
  local fo = findScript("flight_ops")
  fo.fleetSync()
  local f = save.get("fleet.craft") or {}
  local fid, rec = nil, nil
  for k, r in pairs(f) do if r.name == vc.craftName then fid, rec = k, r end end
  if not rec then P("no fleet record for %s", tostring(vc.craftName)); return nil end
  HOME = save.get("base.body")
  BODY = space.body(HOME)
  -- the plane runs over the ground station (comms.station(), world space)
  local sx, sy, sz = findScript("comms").station()
  local bx, by, bz = sx - BODY.x, sy - BODY.y, sz - BODY.z
  local l = len(bx, by, bz)
  UX, UY, UZ = bx / l, by / l, bz / l
  TX, TY, TZ = -UZ, 0, UX
  local tl = len(TX, TY, TZ)
  if tl < 0.1 then TX, TY, TZ, tl = 1, 0, 0, 1 end
  TX, TY, TZ = TX / tl, TY / tl, TZ / tl
  RORB = BODY.radius * 2.4
  -- the dish out and its radio on; the batteries full
  for _, d in ipairs(rec.parts or {}) do
    if d.id == "dish" then
      d.st = type(d.st) == "table" and d.st or {}
      d.st.deployed = true
      d.st.radio = true
    end
  end
  rec.body = HOME
  rec.x, rec.y, rec.z, rec.vx, rec.vy, rec.vz = orbit_state(0)
  rec.landed, rec.splashed, rec.crew = false, nil, false
  rec.stime = space.time()
  rec.name = "Relay A"
  f[fid] = rec
  save.set("fleet.craft", f)
  P("relay %s: orbit r %.0f (alt %.0f), R %.0f, mu %.0f, period %.0f s", fid, RORB, RORB - BODY.radius, BODY.radius, BODY.mu,
    2 * math.pi * math.sqrt(RORB ^ 3 / BODY.mu))
  save.flush({ wait = true })
  scene.load("system")
  yield()
  for _ = 1, 3 do
    local f2 = save.get("fleet.craft") or {}
    f2[fid] = rec
    save.set("fleet.craft", f2)
    yield()
  end
  wait_for(world_ready, 300, "the world again")
  BODY = space.body(HOME)
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid and v.craftName == "Relay A" then return v end
    end
  end, 120, "the relay back in orbit")
  return v2, fid, rec
end

-- a picture of the screen as the player sees it (UI and map lines) into
-- user://screenshots/<name>.png (save/user/screenshots in the scratch project)
local function snap(name)
  local done = false
  camera.capture({ w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then
      local ok, err = assets.writeBytes("user://screenshots/" .. name .. ".png", bytes)
      P("SHOT %s: %s %s", name, tostring(ok), tostring(err))
    else
      P("SHOT %s failed: %s", name, tostring(why))
    end
    done = true
  end)
  wait_for(function() return done end, 20, "the picture")
end

local function open_map()
  local om = findScript("orbit_map")
  if om and not om.isOpen() then om.toggle() end
  wait(0.5)
  if om.setZoom then om.setZoom(BODY.radius * 9) end
  P("MAP open")
end

local function sats()
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and type(v.craftName) == "string" and v.craftName:sub(1, 6) == "Relay " then out[#out + 1] = v end
  end
  return out
end

local function topup()
  for _, v in ipairs(sats()) do if v.elecSetCharge then pcall(v.elecSetCharge, 1e6) end end
end

-- log the network for `secs` real seconds at `warp`; returns the last coverage
-- and the snapshot's peak
local function watch(tag, secs, warp)
  local net = findScript("comms")
  space.warp(warp)
  local t_end, next_t, top_t = W() + secs, 0, 0
  local c, peak = nil, 0
  while W() < t_end do
    yield()
    -- batteries topped up often: at ×1000 two real seconds are half an hour
    -- of game time, and a flat dish is a network down (not what this measures)
    if W() >= top_t then top_t = W() + 0.1; topup() end
    c = net.coverage(HOME)
    peak = math.max(peak, c.sky or 0)
    if W() >= next_t then
      next_t = W() + 2
      topup()
      local g = c.gaps and c.gaps.clusters and c.gaps.clusters[1]
      P("T %s game %.0f warp %s · snapshot ground %.3f sky %.3f · sustained %.3f · held %.0f / %.0f full %s · sats %d · gaps %s%s",
        tag, space.time(), tostring(space.warp()), c.ground, c.sky, c.sustained or -1, c.held or -1, c.window or -1,
        tostring(c.full), c.satellites or -1, c.gaps and tostring(c.gaps.n) or "-",
        g and string.format(" (biggest %d at %.0f°)", g.n, g.lat) or "")
      -- each relay: its radius, its angle round the orbit from the base's
      -- zenith, its charge and its link (a constellation drifting out of
      -- phase, or a flat battery, shows here)
      local bb = space.body(HOME)
      local parts = {}
      for _, v in ipairs(sats()) do
        local n = v.node
        local x, y, z = n.x - bb.x, n.y - bb.y, n.z - bb.z
        local q = net.statusOf(n.id)
        local ok, cs = pcall(v.controlState)
        local ch = ok and cs or nil
        parts[#parts + 1] = string.format("%s r%.0f a%.0f %s%s", v.craftName:sub(-1), len(x, y, z),
          math.deg(math.atan2(x * TX + y * TY + z * TZ, x * UX + y * UY + z * UZ)),
          (q and q.connected) and "L" or "-", type(ch) == "table" and string.format(" c%.0f", ch.charge or -1) or "")
      end
      P("SATS %s %s", tag, table.concat(parts, " · "))
      if space.warp() < warp * 0.5 then space.warp(warp) end
    end
  end
  return c, peak
end

local function MAIN()
  boot()
  local v, fid, rec = to_orbit()
  if not v then R("orbit", false, "no relay in orbit"); return end
  local net = findScript("comms")
  wait(2)
  topup()
  net.refreshNow()
  local st = net.statusOf(v.node.id)
  local b = space.body(HOME)
  local rr = len(v.node.x - b.x, v.node.y - b.y, v.node.z - b.z)
  R("orbit", st ~= nil and rr > b.radius * 2, "Relay A at r %.0f, linked %s (%s)", rr, tostring(st and st.connected),
    tostring(st and st.why))
  -- 2. one relay
  if STOP == "map" then open_map() end
  net.sustainReset(HOME)
  net.coverage(HOME)
  local P1 = 2 * math.pi * math.sqrt(RORB ^ 3 / b.mu)
  local Wn = math.max(300, P1)
  local secs = Wn * params.windows / params.warp
  -- 3. the velocity frame: comms's state of the relay, carried 20 s on
  local nd = net.nodeOf(v.node.id)
  local E = findScript("electronics")
  local vt0 = space.time()
  local c1, peak1 = watch("one", math.min(secs, 60), params.warp)
  if nd and nd.vx and nd.frame == HOME then
    local bb = space.body(HOME)
    local px, py, pz = E.kepler(nd.rx, nd.ry, nd.rz, nd.vx, nd.vy, nd.vz, bb.mu, space.time() - nd.t0)
    local ax, ay, az = v.node.x - bb.x, v.node.y - bb.y, v.node.z - bb.z
    local err = len(px - ax, py - ay, pz - az)
    local vw = len(nd.vx, nd.vy, nd.vz)
    R("velcheck", err < RORB * 0.1, "predicted vs actual after %.0f s of game: %.1f m (r %.0f; |v| %.2f vs circular %.2f)",
      space.time() - vt0, err, RORB, vw, math.sqrt(bb.mu / RORB))
  else
    R("velcheck", false, "no state for the relay (%s)", tostring(nd and nd.frame))
  end
  if STOP == "map" then space.warp(1); wait(0.5); snap("cov_one") end
  R("one_relay", c1 and c1.full and peak1 > (c1.sustained or 1) + 0.15, "snapshot peak %.3f, sustained %.3f over a %.0f s window (full %s)",
    peak1, c1 and c1.sustained or -1, c1 and c1.window or -1, tostring(c1 and c1.full))
  -- 4. three relays
  local f = save.get("fleet.craft") or {}
  local base = deep(f[fid])
  for k, ph in ipairs({ 2 * math.pi / 3, 4 * math.pi / 3 }) do
    local r2 = deep(base)
    r2.x, r2.y, r2.z, r2.vx, r2.vy, r2.vz = orbit_state(0)
    -- the relay A record was written at its own stime: put the others on
    -- the same orbit ph ahead of where A is NOW
    local an = v.node
    local bb = space.body(HOME)
    local ax, ay, az = an.x - bb.x, an.y - bb.y, an.z - bb.z
    local a0 = math.atan2(ax * TX + ay * TY + az * TZ, ax * UX + ay * UY + az * UZ)
    r2.x, r2.y, r2.z, r2.vx, r2.vy, r2.vz = orbit_state(a0 + ph)
    r2.stime = space.time()
    r2.name = "Relay " .. string.char(65 + k)
    local nfid = "c" .. tostring(900 + k)
    f[nfid] = r2
  end
  space.warp(1)
  wait(0.5)
  save.set("fleet.craft", f)
  local fo = findScript("flight_ops")
  fo.fleetRescan()
  wait_for(function() return #sats() >= 3 end, 60, "three relays")
  wait(2)
  topup()
  net.refreshNow()
  local linked = 0
  for _, s in ipairs(sats()) do local q = net.statusOf(s.node.id); if q and q.connected then linked = linked + 1 end end
  R("three", #sats() == 3, "%d relays in orbit, %d linked", #sats(), linked)
  net.sustainReset(HOME)
  net.coverage(HOME)
  local c3, peak3 = watch("three", secs, params.warp)
  if STOP == "map" then space.warp(1); wait(0.5); snap("cov_three") end
  R("three_held", c3 and c3.full and (c3.sustained or 0) > (c1 and c1.sustained or 0) + 0.2,
    "sustained %.3f (one relay %.3f), snapshot now %.3f peak %.3f, %d gaps in %d patches",
    c3 and c3.sustained or -1, c1 and c1.sustained or -1, c3 and c3.sky or -1, peak3, c3 and c3.gaps and c3.gaps.n or -1,
    c3 and c3.gaps and #c3.gaps.clusters or -1)
  -- 5. heavy warp
  local c5 = watch("heavy", 12, params.warp2)
  R("heavy_warp", c5 and c5.full and math.abs((c5.sustained or 0) - (c3 and c3.sustained or 0)) < 0.1,
    "×%d: sustained %.3f (×%d %.3f)", params.warp2, c5 and c5.sustained or -1, params.warp, c3 and c3.sustained or -1)
  space.warp(1)
  local enc = save.get("comms.sustain." .. HOME)
  R("saved", type(enc) == "string" and #enc > 100, "history in the save: %d chars", type(enc) == "string" and #enc or -1)
  P("DONE")
  if save.deleteSlot then save.deleteSlot(SLOT) end
  if (params.quit or 0) > 0 then app.quit() end
end

function update(node, dt)
  if not CO then
    NODE = node
    STOP = params.stop
    if STOP == "" or STOP == "none" then STOP = nil end
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
