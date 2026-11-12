-- RENDERFIX: Ty's 2026-11-12 playtest render issues, measured (tools/perf/renderfix.sh).
-- A NEW Career save (as perfbench boot()), silent, under the shared lock.
--
--   mode = "fog"    the spawn in clear air, then forced mist, then mist at dusk
--                   and at night: four headings each (toward the star, away,
--                   both sides), pictures + `RF LIGHT` lines (the Light
--                   component's fog fields) + `RF LUMA` asked of python later
--   mode = "flick"  the 6-part rover driven out past 100 m, warped to dusk,
--                   mist forced, the rover's lights on, then `secs` seconds of
--                   driving in a weave with the chase camera: EVERY frame the
--                   Light component's fog/intensity fields are compared with
--                   the last frame's (`RF LW` on a change: who wrote it is not
--                   known, the values are), perf.counts().lights/lightsDropped
--                   and dt; `DUMP ON/OFF` lines gate renderfix.sh's frame dump
--                   (FLOPTLE_FRAME_DUMP) round the drive. params: shadowmap=0
--                   (Light.shadowMap and fogShaftsMap off for the drive),
--                   night (the star's elevation to warp to, default -0.08)
--   mode = "lights" the rover parked at night on open ground, lights off and
--                   on, three camera angles each (`RF LAMP` intensity/range)
--   mode = "rocks"  survey: every settled stone/boulder/crystal (mineral_field
--                   rocksNear) and every rock NODE (outcrops, cave-in slabs,
--                   ruins debris: tags "rocks"/names) within `rr` m of several
--                   spots, measured against terrain.query: `RF ROCK` floating
--                   counts, `RF FLOAT` the worst ones; then a low pass of the
--                   camera (the rover driven over a rock field) and again
--
-- Pictures: user://rf/<mode>/<name>.png (renderfix.sh moves them out).
defaults = { quit = 1, slot = 23, seed = 5150, scale = 4, w = 1280, h = 720, mode = "fog", secs = 40.0,
             shadowmap = 1, night = -0.08, rr = 140.0, mist = 1.0, nwarp = 400 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RF %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO = nil, nil
local MODE = "fog"
WPEND = 0
local function yield() coroutine.yield() end
local function wait(s)
  local acc, last = 0, time
  while acc < s do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local HELD = {}
local function key_down(k) HELD[k] = true; input.simulate { key = k, down = true } end
local function key_up(k) HELD[k] = nil; input.simulate { key = k, down = false } end
local function tap(k) key_down(k); yield(); yield(); key_up(k) end
local function release_all() for k in pairs(HELD) do key_up(k) end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function scl(a, k) return { x = a.x * k, y = a.y * k, z = a.z * k } end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function astro() return find("Astronaut") end

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
  perf.enable(true)
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local gx = findScript("graphics")
  if gx and gx.params then gx.params.autoLower = false end
  P("BOOT done; graphics level %s", gx and gx.level and gx.level() or "?")
end

-- ── the light, read ─────────────────────────────────────────────────────────
local FIELDS = { "fog", "fogVolumetric", "fogDensity", "fogLight", "fogEnd", "fogStart", "fogColorR", "fogColorG", "fogColorB",
                 "fogHeight", "fogFalloff", "fogAnisotropy", "fogSky", "fogShafts", "intensity", "ambientR",
                 "fogSun", "fogLamps", "fogAmbient", "fogClamp", "shadowStrength", "exposure", "bloom", "wsun", "wstops", "wmist" }
local function light() local n = find("Lighting"); return n and n:getcomponent("Light") end
local function read_light()
  local l = light()
  local o = {}
  if not l then return o end
  for _, k in ipairs(FIELDS) do
    if k == "exposure" then break end
    local ok, v = pcall(function() return l[k] end)
    if ok then o[k] = v end
  end
  -- the picture's exposure, and the weather's sun share and gloom (the star's
  -- colour is written through setCelestial from weather.lua star_light)
  local pn = find("Post Processing"); local pp = pn and pn:getcomponent("PostProcess")
  if pp then o.exposure = pp.exposure; o.bloom = pp.bloomIntensity end
  local wx = findScript("weather")
  local sk = wx and wx.sky
  if sk then o.wsun = sk.sun; o.wstops = sk.stops; o.wmist = sk.mist end
  return o
end
local function fmtv(v)
  if type(v) == "number" then return string.format("%.4g", v) end
  return tostring(v)
end
local function light_line(tag)
  local o = read_light()
  local parts = {}
  for _, k in ipairs(FIELDS) do if o[k] ~= nil then parts[#parts + 1] = k .. "=" .. fmtv(o[k]) end end
  local at = findScript("atmosphere")
  local pn = find("Post Processing"); local pp = pn and pn:getcomponent("PostProcess")
  P("LIGHT %s: sun %.3f exposure %s | %s", tag, at and at.sun_now or -9, fmtv(pp and pp.exposure), table.concat(parts, " "))
end

-- ── pictures ────────────────────────────────────────────────────────────────
local function shot(name)
  local done = false
  local ok = pcall(camera.capture, { w = params.w, h = params.h }, function(b)
    if b then
      WPEND = WPEND + 1
      assets.writeBytes("user://rf/" .. MODE .. "/" .. name .. ".png", b, { async = true }, function() WPEND = WPEND - 1 end)
    end
    done = true
  end)
  if ok then wait_for(function() return done end, 10, "shot " .. name) end
end

-- the star's direction projected on the local horizontal at a point (unit), and up
local function star_dir(p)
  local b = home()
  local U = unit(sub(p, b))
  local best, bmu = nil, -1
  for _, bb in ipairs(space.bodies() or {}) do
    local key = ((bb.soi or 0) < 0 and 1e30 or 0) + (bb.mu or 0)
    if key > bmu then best, bmu = bb.name, key end
  end
  local s = best and space.body(best)
  local S = s and unit(sub(s, p)) or { x = 1, y = 0, z = 0 }
  local h = sub(S, scl(U, dot(S, U)))
  if len(h.x, h.y, h.z) < 1e-4 then h = cross(U, { x = 0, y = 0, z = 1 }) end
  return unit(h), U, dot(S, U)
end
local function star_up(p) local _, _, e = star_dir(p); return e end

-- A camera at `ref` (a node, read every frame: drawn pose) + up*h, looking along
-- the heading `deg` from the star's bearing, pitched `pitch` degrees.
local function cam_heading(ref, deg, h, pitch, back)
  local pc = findScript("planet_camera")
  pc.setShot(function()
    if not (ref and ref.valid) then return nil end
    local p = { x = ref.x, y = ref.y, z = ref.z }
    local F, U = star_dir(p)
    local R = cross(F, U)
    local a = math.rad(deg)
    local D = { x = F.x * math.cos(a) + R.x * math.sin(a), y = F.y * math.cos(a) + R.y * math.sin(a), z = F.z * math.cos(a) + R.z * math.sin(a) }
    local pt = math.rad(pitch or -4)
    local L = { x = D.x * math.cos(pt) + U.x * math.sin(pt), y = D.y * math.cos(pt) + U.y * math.sin(pt), z = D.z * math.cos(pt) + U.z * math.sin(pt) }
    local bk = back or 0
    local c = { x = p.x + U.x * h - D.x * bk, y = p.y + U.y * h - D.y * bk, z = p.z + U.z * h - D.z * bk }
    return c.x, c.y, c.z, c.x + L.x * 20, c.y + L.y * 20, c.z + L.z * 20, U.x, U.y, U.z
  end, 0.05)
end
local function four(ref, tag, h, pitch, back)
  for _, d in ipairs({ { 0, "sun" }, { 90, "side" }, { 180, "away" }, { 270, "side2" } }) do
    cam_heading(ref, d[1], h or 1.7, pitch, back)
    wait(0.8)
    shot(tag .. "_" .. d[2])
  end
  findScript("planet_camera").clearShot(0.05)
end

local function warp_to(want)
  local a = astro()
  local su = star_up(a)
  local t0 = W()
  if su <= want then return su end
  -- past the evening's elevation (falling), not the morning's: warp until it
  -- drops below `want` after having been above it
  space.warp(params.nwarp)
  while W() - t0 < 150 do
    wait(0.25)
    a = astro() or a
    su = star_up(a)
    if space.warp() < 2 then space.warp(params.nwarp) end
    if su < want then break end
  end
  space.warp(1)
  wait(2)
  return star_up(astro())
end

local function mist(k)
  local wx = findScript("weather")
  if wx then wx.force("clear"); if wx.forceMist then wx.forceMist(k) end end
  local at = findScript("atmosphere")
  if at and at.snapWeather then at.snapWeather() end
end

-- ── the rover (perfbench ROVER, through the standalone builder) ─────────────
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
local function pilot()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end
local function launch_rover()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = ROVER })
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 6 and B end, 90, "the builder")
  if not B then return nil end
  wait(1.5)
  save.set("shipyard.site", "runway")
  B.doLaunch()
  if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
  local ready
  local v = wait_for(function()
    local v = pilot()
    if not v then return nil end
    local i = assembly.info(v.node)
    if i and i.anchored and #i.parts >= 6 then ready = ready or time; if time - ready > 2 then return v end end
  end, 150, "the rover on the runway")
  wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150, "the regrade")
  -- (the launch loaded the scene again: a new graphics script, auto-lower on)
  local gx = findScript("graphics"); if gx and gx.params then gx.params.autoLower = false end
  return v
end
local function from_base(vn)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local b = home()
  local p = sub(assembly.info(vn).com, b)
  local u = unit({ x = bx, y = by, z = bz })
  return math.acos(clamp(dot(unit(p), u), -1, 1)) * len(p.x, p.y, p.z), u
end
-- W held, steering away from the base until `out` m (perfbench run_rover)
local function drive_out(vc, out, tmo)
  local vn = vc.node
  local t0 = time
  while time - t0 < (tmo or 60) do
    yield()
    if not vn.valid then return false end
    if not HELD.w then key_down("w") end
    local d, u = from_base(vn)
    if d > out then break end
    local want = nil
    local i1 = assembly.info(vn)
    local Rh = unit(sub(i1.com, home()))
    local away = sub(Rh, scl(u, dot(Rh, u)))
    local v = i1.vel
    local vh = sub(v, scl(Rh, dot(v, Rh)))
    if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
      away = unit(away)
      local sn = dot(cross(unit(vh), away), Rh)
      if dot(unit(vh), away) < 0.97 then want = sn >= 0 and "a" or "d" end
    end
    for _, k in ipairs({ "a", "d" }) do
      if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
    end
  end
  release_all()
  local d = from_base(vn)
  P("ROVER out: %.0f m from the base after %.1f s", d, time - t0)
  return true
end
local function lamps_of(vn)
  local out = {}
  local function scan(n, depth)
    for _, c in ipairs(n:children()) do
      local pl = c:getcomponent("PointLight")
      if pl then out[#out + 1] = { node = c, l = pl } end
      if depth < 4 then scan(c, depth + 1) end
    end
  end
  scan(vn, 0)
  return out
end
local function lamp_line(tag, vn)
  for i, L in ipairs(lamps_of(vn)) do
    P("LAMP %s %d %s: intensity %s range %s spot %s", tag, i, L.node.name, fmtv(L.l.intensity), fmtv(L.l.range), tostring(L.l.spotAngle or L.l.spot))
  end
end
local function stop(vc, secs)
  release_all()
  local t0 = time
  while time - t0 < (secs or 3) do
    if vc.R2 then vc.R2.cmd = { drive = 0, steer = 0, brake = 1 } end
    key_down("s"); yield(); key_up("s")
    local i = assembly.info(vc.node)
    if i and len(i.vel.x, i.vel.y, i.vel.z) < 0.3 then break end
  end
  release_all()
end

-- every lit lamp under the home planet's node (the base, crafts, the crew),
-- nearest the camera first
local function census(tag)
  local b = home()
  local pn = b and find(b.name)
  local cam = findScript("planet_camera")
  local cn = cam and cam.node
  local cp = cn and cn.worldPos or (astro() and astro().worldPos)
  local out = {}
  local function walk(n, depth)
    for _, c in ipairs(n:children() or {}) do
      local pl = c:getcomponent("PointLight")
      if pl and (pl.intensity or 0) > 0 then
        local p = c.worldPos
        out[#out + 1] = { nm = (c.parent and c.parent.name or "?") .. "/" .. (c.name or "?"), i = pl.intensity, r = pl.range,
                          d = cp and len(p.x - cp.x, p.y - cp.y, p.z - cp.z) or -1, en = c.enabled }
      end
      if depth < 7 then walk(c, depth + 1) end
    end
  end
  if pn then walk(pn, 0) end
  table.sort(out, function(a, c) return a.d < c.d end)
  local c = perf.counts() or {}
  P("CENSUS %s: %d lit lamps; engine lights %s dropped %s", tag, #out, tostring(c.lights), tostring(c.lightsDropped))
  for i, L in ipairs(out) do
    if i <= 40 then P("CENSUS %s %2d %-44s i %.2f r %.0f d %.0f m en %s", tag, i, L.nm, L.i, L.r or -1, L.d, tostring(L.en)) end
  end
end

-- ── modes ───────────────────────────────────────────────────────────────────
local function run_fog()
  local a = astro()
  wait(3)
  light_line("clear")
  four(a, "clear", 1.7)
  mist(params.mist)
  wait(4)
  light_line("mist")
  four(a, "mist", 1.7)
  local su = warp_to(0.02)
  mist(params.mist)
  wait(4)
  P("dusk: star elevation %.3f", su)
  light_line("mist_dusk")
  four(a, "mistdusk", 1.7)
  su = warp_to(-0.2)
  mist(params.mist)
  wait(4)
  P("night: star elevation %.3f", su)
  light_line("mist_night")
  four(a, "mistnight", 1.7)
  local c = perf.counts() or {}
  P("COUNTS night: lights %s lightsDropped %s", tostring(c.lights), tostring(c.lightsDropped))
  census("night_spawn")
  mist(nil)
  wait(4)
  light_line("clear_night")
  four(a, "clearnight", 1.7)
end

-- the mist at the spawn's hour (and at dusk) under a sweep of atmosphere
-- params: `sweep` = "fogLight=0.75,0.4,0.2,0" style (one key), pictures
-- toward the star and away
local function run_fogsweep()
  local a = astro()
  wait(3)
  local at = findScript("atmosphere")
  local key, vals = tostring(params.sweep or "fogLight=0.75,0.4,0.2,0"):match("^(%w+)=(.*)$")
  local keep = at.params[key]
  mist(params.mist)
  wait(4)
  for _, phase in ipairs({ "day", "dusk" }) do
    if phase == "dusk" then warp_to(0.05); mist(params.mist); wait(3) end
    for v in vals:gmatch("[^,]+") do
      at.params[key] = tonumber(v)
      wait(1.5)
      light_line(phase .. "_" .. key .. v)
      for _, d in ipairs({ { 0, "sun" }, { 180, "away" } }) do
        cam_heading(a, d[1], 1.7, -4)
        wait(0.6)
        shot(phase .. "_" .. key .. v .. "_" .. d[2])
      end
      findScript("planet_camera").clearShot(0.05)
    end
    at.params[key] = keep
  end
end

local function frame_watch(secs, vc)
  local last = read_light()
  local n, changes, dropped_frames, maxdt, sumdt = 0, 0, 0, 0, 0
  local lmin, lmax = 99, 0
  local cuts = 0
  local t0 = time
  local wsec = 0
  local turn = 1
  while time - t0 < secs do
    yield()
    n = n + 1
    local d = dt or 0
    sumdt = sumdt + d
    if d > maxdt then maxdt = d end
    -- a weave: steer one way 3 s, the other 3 s
    local el = time - t0
    local want = (math.floor(el / 3) % 2 == 0) and "a" or "d"
    -- (held to ~10 m/s: at 19 m/s the weave crashed the rover into the base, renderfix cam_after3)
    local iv = assembly.info(vc.node)
    local spd = iv and len(iv.vel.x, iv.vel.y, iv.vel.z) or 0
    if spd < (params.vmax or 10) then if not HELD.w then key_down("w") end elseif HELD.w then key_up("w") end
    for _, k in ipairs({ "a", "d" }) do
      if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
    end
    if d > 0.12 then P("HITCH f%d t%.2f dt %.1f ms", FRAME, el, d * 1000) end
    local cur = read_light()
    local diff = {}
    for _, k in ipairs(FIELDS) do
      local a, b = last[k], cur[k]
      if type(a) == "number" and type(b) == "number" then
        local rel = math.abs(b - a) / math.max(math.abs(a), 1e-3)
        if rel > 0.15 then diff[#diff + 1] = string.format("%s %.4g->%.4g", k, a, b) end
      elseif a ~= b then diff[#diff + 1] = string.format("%s %s->%s", k, tostring(a), tostring(b)) end
    end
    if cur.fog == false or cur.fogVolumetric == false then cuts = cuts + 1 end
    if #diff > 0 then
      changes = changes + 1
      if changes <= 60 then P("LW f%d t%.2f dt %.1f ms: %s", FRAME, el, d * 1000, table.concat(diff, ", ")) end
    end
    last = cur
    local c = perf.counts() or {}
    if (c.lightsDropped or 0) > 0 then dropped_frames = dropped_frames + 1 end
    lmin, lmax = math.min(lmin, c.lights or 0), math.max(lmax, c.lights or 0)
    if math.floor(el) ~= wsec then
      wsec = math.floor(el)
      local i = assembly.info(vc.node)
      P("DRIVE t%d: speed %.1f lights %s dropped %s fog %s vol %s dens %s", wsec, i and len(i.vel.x, i.vel.y, i.vel.z) or -1,
        tostring(c.lights), tostring(c.lightsDropped), tostring(cur.fog), tostring(cur.fogVolumetric), fmtv(cur.fogDensity))
    end
  end
  release_all()
  local pcs = findScript("planet_camera")
  local st = pcs and pcs.propClipStats
  P("PROPCLIP asks %s, props near the view now %s (most %s), frames pulled in %s", tostring(st and st.asks), tostring(st and st.props), tostring(st and st.most), tostring(st and st.pulls))
  P("WATCH %d frames, mean dt %.1f ms, max %.1f ms; light changes >15%% on %d frames; frames with fog cut %d; frames with lightsDropped %d; lights %d..%d",
    n, 1000 * sumdt / math.max(n, 1), maxdt * 1000, changes, cuts, dropped_frames, lmin, lmax)
end

local function run_flick()
  wait(2)
  local su = warp_to(params.night)
  P("star elevation %.3f", su)
  local vc = launch_rover()
  if not vc then P("DONE no rover") return end
  vc.releaseClamps()
  wait(2)
  drive_out(vc, 100, 70)
  mist(params.mist)
  wait(3)
  tap("y")
  wait(1)
  lamp_line("on", vc.node)
  if params.shadowmap == 0 then
    local l = light()
    l.shadowMap = false
    pcall(function() l.fogShaftsMap = false end)
    P("SHADOWMAP off: shadowMap %s fogShaftsMap %s", tostring(l.shadowMap), tostring(l.fogShaftsMap))
  end
  light_line("drive")
  census("drive")
  P("DUMP ON f%d", FRAME)
  frame_watch(params.secs, vc)
  P("DUMP OFF f%d", FRAME)
  light_line("after")
end

local function run_lights()
  wait(2)
  local su = warp_to(-0.25)
  P("star elevation %.3f", su)
  local vc = launch_rover()
  if not vc then P("DONE no rover") return end
  vc.releaseClamps()
  wait(2)
  drive_out(vc, 110, 70)
  stop(vc, 4)
  wait(1)
  local vn = vc.node
  local function views(tag)
    -- the chase view as the player has it, then from the side and from in front
    wait(1.0)
    shot(tag .. "_chase")
    local rb = nil
    for _, c in ipairs(vn:children()) do if c.name and c.name:find("Rover") then rb = c end end
    rb = rb or vn
    local pc = findScript("planet_camera")
    -- (the rover's FRONT is +X)
    local function at(lx, ly, lz, tx, ty, tz, nm)
      pc.setShot(function()
        if not rb.valid then return nil end
        local c = rb:toWorld(vec3(lx, ly, lz))
        local t = rb:toWorld(vec3(tx, ty, tz))
        local u = unit(sub(rb.worldPos, home()))
        return c.x, c.y, c.z, t.x, t.y, t.z, u.x, u.y, u.z
      end, 0.05)
      wait(0.8)
      shot(tag .. "_" .. nm)
    end
    at(-6, 3.0, 0, 8, 0, 0, "behind")
    at(2, 2.5, 6, 10, 0, 0, "side")
    at(0.3, 1.6, 0, 20, -1.2, 0, "driver")
    pc.clearShot(0.05)
  end
  lamp_line("off", vn)
  views("off")
  tap("y")
  wait(1)
  lamp_line("on", vn)
  local c = perf.counts() or {}
  P("COUNTS lights on: lights %s lightsDropped %s", tostring(c.lights), tostring(c.lightsDropped))
  views("on")
  mist(params.mist)
  wait(4)
  light_line("lights_mist")
  views("onmist")
end

-- ── rocks ───────────────────────────────────────────────────────────────────
local function survey(tag, cx, cy, cz, R)
  local mf = findScript("mineral_field")
  local b = home()
  local n, fl, fl2, worst = 0, 0, 0, {}
  if mf and mf.rocksNear then
    for _, rk in ipairs(mf.rocksNear(cx, cy, cz, R)) do
      n = n + 1
      local d = terrain.query(rk.x, rk.y, rk.z)
      if d then
        -- a rock's origin sits about at its foot; d is metres above the field
        local over = d - 0.15 * (rk.scale or 1)
        if over > 0.4 then fl = fl + 1 end
        if over > 2.0 then fl2 = fl2 + 1 end
        if over > 0.4 then worst[#worst + 1] = { over = over, x = rk.x - b.x, y = rk.y - b.y, z = rk.z - b.z, key = rk.key, dist = len(rk.x - cx, rk.y - cy, rk.z - cz) } end
      end
    end
  end
  -- rock NODES under the planet: outcrops (tag ore_outcrop), cave-in slabs,
  -- ruins rubble, debris
  local pn = find(b.name)
  local nn, nfl = 0, 0
  if pn then
    for _, c in ipairs(pn:children()) do
      local nm = c.name or ""
      local tags = c.tags or {}
      local isrock = nm:find("^Ore ") or nm:find("Rubble") or nm:find("Slab") or nm:find("Rock") or nm:find("Boulder")
      for _, t in ipairs(tags) do if t == "rocks" then isrock = true end end
      if isrock then
        local p = c.worldPos
        if len(p.x - cx, p.y - cy, p.z - cz) <= R then
          nn = nn + 1
          local d = terrain.query(p.x, p.y, p.z)
          local s = (c.scale_y or 1)
          if d and d - 0.5 * s > 0.4 then
            nfl = nfl + 1
            worst[#worst + 1] = { over = d - 0.5 * s, x = p.x - b.x, y = p.y - b.y, z = p.z - b.z, key = "node:" .. nm, dist = len(p.x - cx, p.y - cy, p.z - cz) }
          end
        end
      end
    end
  end
  table.sort(worst, function(a, c) return a.over > c.over end)
  local mfa = mf and mf.auditRemoved or -1
  P("ROCK %s: scatter rocks %d floating>0.4m %d (>2m %d); rock nodes %d floating %d; audit removed %s redropped %s",
    tag, n, fl, fl2, nn, nfl, tostring(mfa), tostring(mf and mf.auditRedropped))
  for i = 1, math.min(8, #worst) do
    local w = worst[i]
    P("FLOAT %s %d: %.2f m over the ground, %.0f m from the eye, %s", tag, i, w.over, w.dist, w.key)
  end
  return worst
end

local function look_at_rock(w, tag)
  local b = home()
  if not w then return end
  local pc = findScript("planet_camera")
  pc.setShot(function()
    local bb = home()
    local p = { x = bb.x + w.x, y = bb.y + w.y, z = bb.z + w.z }
    local U = unit({ x = w.x, y = w.y, z = w.z })
    local a = math.abs(U.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
    local T = unit(cross(U, a))
    local c = { x = p.x + T.x * 7 + U.x * 2.0, y = p.y + T.y * 7 + U.y * 2.0, z = p.z + T.z * 7 + U.z * 2.0 }
    return c.x, c.y, c.z, p.x, p.y, p.z, U.x, U.y, U.z
  end, 0.05)
  wait(1.0)
  shot(tag)
  pc.clearShot(0.05)
end

local function body_pt(p) local b = home(); return { x = p.x - b.x, y = p.y - b.y, z = p.z - b.z } end
local function world_pt(q) local b = home(); return { x = b.x + q.x, y = b.y + q.y, z = b.z + q.z } end
local function ground_at(q)
  local p = world_pt(q)
  local U = unit(q)
  local ok, h = pcall(terrain.raycast, vec3(p.x + U.x * 40, p.y + U.y * 40, p.z + U.z * 40), vec3(-U.x, -U.y, -U.z), 120)
  if ok and h and h.pos then return body_pt(h.pos) end
  return q
end
local function put_crew(q, lift)
  local a = astro()
  local U = unit(q)
  local p = world_pt({ x = q.x + U.x * lift, y = q.y + U.y * lift, z = q.z + U.z * lift })
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
end
local function hold_crew(q, lift, secs)
  local t0 = time
  while time - t0 < secs do put_crew(q, lift); yield() end
end
local function offset(q, dist, ang)
  local U = unit(q)
  local a = math.abs(U.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local T = unit(cross(U, a)); local S = cross(U, T)
  local c, s = math.cos(ang) * dist, math.sin(ang) * dist
  return ground_at({ x = q.x + T.x * c + S.x * s, y = q.y + T.y * c + S.y * s, z = q.z + T.z * c + S.z * s })
end
local function run_rocks()
  wait(3)
  local a = astro()
  local R = params.rr
  local mf = findScript("mineral_field")
  local w = survey("spawn", a.x, a.y, a.z, R)
  look_at_rock(w[1], "spawn_worst")
  -- three spots out on the land, the crew put there: what lies round each
  -- as it arrives (6 s) and once the audit has had its passes (20 s)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local base = { x = bx, y = by, z = bz }
  local tot = { 0, 0, 0, 0 }
  for i, sp in ipairs({ { 300, 0.4 }, { 380, 2.5 }, { 460, 4.4 } }) do
    local q = offset(base, sp[1], sp[2])
    put_crew(q, 1.2)
    wait(6)
    local p = world_pt(q)
    local w1 = survey("spot" .. i .. "_6s", p.x, p.y, p.z, R)
    look_at_rock(w1[1], "spot" .. i .. "_6s_worst")
    wait(14)
    p = world_pt(q)
    local w2 = survey("spot" .. i .. "_20s", p.x, p.y, p.z, R)
    look_at_rock(w2[1], "spot" .. i .. "_20s_worst")
    tot[1], tot[2] = tot[1] + #w1, tot[2] + #w2
  end
  P("ROCKS TOTAL floating>0.4m: %d on arrival, %d after 20 s; audit removed %s redropped %s; outcrops dug %s",
    tot[1], tot[2], tostring(mf.auditRemoved), tostring(mf.auditRedropped), tostring(mf.outcropsDug))
end

-- ── catch: rocks settling onto a body that then leaves ─────────────────────
-- The engine's settling ray stops at the first collider under a rock. The
-- crew stands on a stone while its stand is declared again (as arriving
-- ground or a re-drop does), so the stand's rocks under the crew settle on
-- the crew; the crew then walks off. Measured: right after; from 90 m away
-- (past the old 60 m audit) after 10 s; from 12 m after 9 s; then the same
-- stand caught a SECOND time (the old audit re-dropped a stand once).
local function count_near(tag, q, R)
  local p = world_pt(q)
  return survey(tag, p.x, p.y, p.z, R)
end

-- ── camclip: the view backed into a tree trunk / a boulder on purpose ──────
-- The crew stands `gap` m in front of the nearest trunk (then boulder), the
-- view faced away from it (planet_camera.face), so the third-person camera
-- backs out along the line through the prop: a picture, how far the camera
-- ends up from the prop's axis against its radius, and planet_camera's
-- propClipStats. Run before (PATCHES reverting the clip) and after.
local function run_camclip()
  if (params.noclip or 0) > 0 then local pc0 = findScript("planet_camera"); if pc0 and pc0.PROP_CLIP then pc0.PROP_CLIP.off = true end end
  wait(3)
  local ff = findScript("flora_field")
  local pc = findScript("planet_camera")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local base = { x = bx, y = by, z = bz }
  local done = { trunk = 0, rock = 0 }
  for _, dist in ipairs({ 200, 260, 320, 380, 440 }) do
    for k = 0, 7 do
      if done.trunk >= 2 and done.rock >= 2 then break end
      local q = offset(base, dist, k * math.pi / 4)
      put_crew(q, 1.2)
      wait(3.0)
      local p = world_pt(q)
      local list = ff.cameraObstacles(p.x, p.y, p.z, 40) or {}
      for _, kind in ipairs({ "trunk", "rock" }) do
        if done[kind] < 2 then
          local best = nil
          for _, o in ipairs(list) do
            local ok = (kind == "trunk" and o.h > 0) or (kind == "rock" and o.h == 0 and o.r >= 0.7)
            if ok then
              local d = len(o.x - q.x, o.y - q.y, o.z - q.z)
              if not best or d < best.d then best = { o = o, d = d } end
            end
          end
          if best then
            done[kind] = done[kind] + 1
            local o = best.o
            local U = { x = o.ux, y = o.uy, z = o.uz }
            -- away from the prop along the ground, from a direction of its own
            local a = math.abs(U.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
            local T = unit(cross(U, a))
            local gap = o.r + (params.gap or 2.4)
            local stand = ground_at({ x = o.x + T.x * gap, y = o.y + T.y * gap, z = o.z + T.z * gap })
            local pulls0 = pc.propClipStats and pc.propClipStats.pulls or 0
            local tag = string.format("%s%d", kind, done[kind])
            local t0 = time
            -- third person (first person is the default since 11-11), the
            -- orbit just long enough to end in the prop
            if pc.setFootFirstPerson then pc.setFootFirstPerson(false) else pc.firstPerson = false end
            pc.params.distance = gap
            while time - t0 < 2.5 do
              put_crew(stand, 1.2)
              pc.face(T.x, T.y, T.z, -0.12)
              yield()
            end
            local cn = pc.node
            local cp = cn and cn.worldPos
            local bb = home()
            local cq = cp and { x = cp.x - bb.x, y = cp.y - bb.y, z = cp.z - bb.z }
            local axd = -1
            if cq then
              local qx, qy, qz = cq.x - o.x, cq.y - o.y, cq.z - o.z
              local al = clamp(qx * o.ux + qy * o.uy + qz * o.uz, 0, o.h)
              axd = len(qx - o.ux * al, qy - o.uy * al, qz - o.uz * al)
            end
            P("CAMCLIP %s: prop r %.2f h %.1f, crew %.1f m off its axis; camera %.2f m from its axis (%s); pulls +%d",
              tag, o.r, o.h, gap, axd, axd >= 0 and (axd < o.r and "INSIDE" or "outside") or "?",
              (pc.propClipStats and pc.propClipStats.pulls or 0) - pulls0)
            shot("camclip_" .. tag)
          end
        end
      end
    end
  end
  P("CAMCLIP done: trunks %d rocks %d", done.trunk, done.rock)
end

local function run_catch()
  wait(3)
  local mf = findScript("mineral_field")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local base = { x = bx, y = by, z = bz }
  -- a stony spot: ring out from the base at 140 .. 400 m until a stone or boulder is near
  local spot, rock = nil, nil
  for _, dist in ipairs({ 160, 220, 300, 400 }) do
    for k = 0, 7 do
      local q = offset(base, dist, k * math.pi / 4)
      put_crew(q, 1.2)
      wait(2.5)
      local p = world_pt(q)
      local best = nil
      for _, rk in ipairs(mf.rocksNear(p.x, p.y, p.z, 40)) do
        if (rk.r or 0) >= 0.45 and (not best or rk.d < best.d) then best = rk end
      end
      if best then spot, rock = q, best; break end
    end
    if spot then break end
  end
  if not rock then P("DONE no rocks found") return end
  local rq = body_pt(rock)
  P("CATCH stone %s r %.2f at %.0f m from the base", rock.key, rock.r, len(rq.x - base.x, rq.y - base.y, rq.z - base.z))
  count_near("before", rq, 20)
  local function catch(tag)
    -- a slab (a static kit floor, standing in for a craft) held over the
    -- stone while its stand is declared again; then taken away
    put_crew(offset(rq, 10, 2.5), 1.2)
    local U = unit(rq)
    local h = rock.r * 2 + 1.5
    local sp = world_pt({ x = rq.x + U.x * h, y = rq.y + U.y * h, z = rq.z + U.z * h })
    local slab = nil
    spawn(params.slab or "KitFloor21_regocrete", vec3(sp.x, sp.y, sp.z), function(n)
      slab = n
      if n.setUp then n:setUp(vec3(U.x, U.y, U.z), vec3(0, 0, 1)) end
      n.scale = 2.0
    end)
    wait_for(function() return slab end, 10, "the slab")
    wait(1.0)
    local p = world_pt(rq)
    -- the stone put back while the slab is over it: rolled again, it settles
    -- on what is under it now (what an arriving chunk does under a craft)
    scatter.remove(rock.src, rock.inst)
    yield(); yield(); yield()
    scatter.restore(rock.src, rock.inst)
    P("CATCH %s: stone %s re-rolled under the slab %s", tag, tostring(rock.inst), tostring(slab and slab.name))
    local t0 = time
    while time - t0 < 3.0 do
      if slab and slab.valid then
        local bq = world_pt({ x = rq.x + U.x * h, y = rq.y + U.y * h, z = rq.z + U.z * h })
        slab.x, slab.y, slab.z = bq.x, bq.y, bq.z
      end
      yield()
    end
    count_near(tag .. "_under_slab", rq, 20)
    if slab and slab.valid then slab:destroy() end
    wait(0.6)
    local w = count_near(tag .. "_left", rq, 20)
    look_at_rock(w[1], tag .. "_caught")
    return w
  end
  catch("catch1")
  -- far: past the old audit's 60 m
  put_crew(offset(rq, 90, 2.0), 1.2)
  wait(10)
  local w = count_near("catch1_from90m_10s", rq, 20)
  -- near again
  put_crew(offset(rq, 12, 1.0), 1.2)
  wait(9)
  w = count_near("catch1_from12m_9s", rq, 20)
  look_at_rock(w[1], "catch1_after")
  -- the same stand a second time
  catch("catch2")
  put_crew(offset(rq, 12, 1.0), 1.2)
  wait(9)
  w = count_near("catch2_from12m_9s", rq, 20)
  look_at_rock(w[1], "catch2_after")
  P("CATCH audit totals: removed %s redropped %s", tostring(mf.auditRemoved), tostring(mf.auditRedropped))
end

local function main()
  MODE = params.mode or "fog"
  boot()
  -- noclip=1: the chase view's scatter-prop clip off (a before run); set again after a launch reload
  NOCLIP = (params.noclip or 0) > 0
  if MODE == "fog" then run_fog()
  elseif MODE == "flick" then run_flick()
  elseif MODE == "lights" then run_lights()
  elseif MODE == "rocks" then run_rocks()
  elseif MODE == "fogsweep" then run_fogsweep()
  elseif MODE == "catch" then run_catch()
  elseif MODE == "camclip" then run_camclip()
  end
  wait_for(function() return WPEND <= 0 end, 60, "the pictures on disk")
  P("DONE")
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

FRAME = 0
function update(node, dt_)
  dt = dt_
  FRAME = FRAME + 1
  if NOCLIP and FRAME % 30 == 0 then local pc0 = findScript("planet_camera"); if pc0 and pc0.PROP_CLIP then pc0.PROP_CLIP.off = true end end
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    release_all()
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; release_all(); if params.quit == 1 and app.quit then app.quit() end end
end
