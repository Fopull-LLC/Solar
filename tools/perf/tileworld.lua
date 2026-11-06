-- TILEWORLD (tools/perf/tileworld.sh): the terrain textures' tiling on whole
-- worlds, no base, no save. `WORLDS` (prepended by the .sh from
-- alienprobe_dump.lua) is a list of { name, opts }. Each world is filled into
-- terrain 1 (a static node at the origin, so nothing moves under the camera)
-- and photographed on its sunlit side: the flattest ground (at the feet, eye
-- level 12 m out, toward the horizon, 25 m up) and the steepest (12 m and 3 m
-- off, eye height).
--
-- params: first, last (world indices), settle (s), cave (1: also carve a chamber
-- 14 m under the flat ground, paint seam / magma / crystal pockets on its walls and
-- photograph them by a lamp at the camera: the depth layers and the glow slots),
-- graze (1: a low view along the flat ground to the horizon, the tiling at a
-- grazing angle), smin/smax (the sun's height at the spot, as sin(elevation): the
-- default 0.55-0.85 is a high sun; 0.2-0.34 a low one), dist (1: the flat ground
-- at the feet and 30, 100 and 300 m out, then the feet and 30 m with the sun from
-- the right: `_side_*`, where a normal map's bumps must light from the right),
-- phys (1: the planet's Material Physical, as system_generator makeBody sets it;
-- pcol its colour), loadwatch (1: log every frame over 40 ms, and shoot the planet
-- once a second while it fills: a palette arriving late shows grey or white),
-- seam (1: slot borders up close, seam_a | seam_b and 1 | 13, from 0.3-1.7 m; night 1 also
-- in the dark by a lamp), only (1: skip the feet/eye/far/high and slope views),
-- border (1: painted slot pairs br_rock | br_soil, br_sand | br_rock2, br_snow | br_rock
-- and a br_crystal seam in br_host rock, from 0.6, 1.5, 3 and 30 m: `_b<pair>_*`).
defaults = { first = 1, last = 99, settle = 3, quit = 1, cave = 0, graze = 0,
  smin = 0.55, smax = 0.85, dist = 0, phys = 0, pcol = 1, loadwatch = 0, trace = 0,
  seam = 0, seam_a = 2, seam_b = 15, seam_c = 1, seam_d = 13, night = 1, only = 0,
  border = 0, br_rock = 14, br_soil = 20, br_sand = 16, br_rock2 = 15, br_snow = 22, br_host = 13, br_crystal = 7 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
-- trace (1: perf on; every frame's ms, terrain bucket and parts, chunk counts and
-- terrain.busy into user://twtrace/frames.tsv, a perf.counts() dump at each mark
-- into counts.txt: for the engine, around a world's arrival and a cold load)
local TR, TRC = {}, {}
local MARK = ""
local function P(fmt, ...)
  local line = string.format("TW %7.2f " .. fmt, W() - W0, ...)
  print(line)
  if params and params.trace and params.trace > 0 then MARK = MARK .. line:gsub("\t", " ") .. "; " end
end
local function ser(v, ind)
  ind = ind or ""
  if type(v) ~= "table" then return tostring(v) end
  local ks = {}
  for k in pairs(v) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  local o = {}
  for _, k in ipairs(ks) do o[#o + 1] = ind .. "  " .. tostring(k) .. " = " .. ser(v[k], ind .. "  ") end
  return "{\n" .. table.concat(o, "\n") .. "\n" .. ind .. "}"
end
local function countsDump(label)
  if not (params.trace > 0) then return end
  TRC[#TRC + 1] = string.format("== %s at %.2f s\n%s\n", label, W() - W0, ser(perf.counts()))
end
local function traceFlush()
  if params.trace > 0 then
    assets.writeBytes("user://twtrace/frames.tsv", table.concat(TR))
    assets.writeBytes("user://twtrace/counts.txt", table.concat(TRC))
  end
end
local function yield() coroutine.yield() end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local CO
local SUN = vec3(0.4, 0.9, 0.45):normalized()

local function shot(name)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://tworld/" .. name .. ".png", bytes); P("SHOT %s", name); countsDump("shot " .. name)
    else P("SHOT %s failed %s", name, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 10) end
end

local function ground(d, R, top)
  local hit = terrain.raycast(d * (R + top), d * -1, top + R * 0.5)
  return hit and hit.pos:length() or nil, hit
end

local function fib(i, n)
  local y = 1 - (i + 0.5) / n * 2
  local r = math.sqrt(math.max(0, 1 - y * y))
  local a = i * 2.39996323
  return vec3(math.cos(a) * r, y, math.sin(a) * r)
end

-- a point `m` metres from unit direction d along tangent t, on the ground (+h)
local function along(d, t, m, R, top, h)
  local a = m / R
  local e = (d * math.cos(a) + t * math.sin(a)):normalized()
  local g = ground(e, R, top)
  return e * ((g or R) + (h or 0)), e
end

local function view(cam, eye, at, up, name)
  cam.x, cam.y, cam.z = eye.x, eye.y, eye.z
  cam:lookAt(at, up)
  hold(params.settle)
  shot(name)
end

local function main()
  local cam = find("Camera")
  if params.phys > 0 then
    local k = params.pcol   -- the Material colour (1 = white)
    find("Planet"):setMaterial { color = { k, k, k }, shading = "physical", roughness = 1.0, metallic = 0.0 }
  end
  for wi = params.first, math.min(params.last, #WORLDS) do
    local w = WORLDS[wi]
    local o = w.opts
    local R = o.radius
    local tag = string.format("w%d_%s", wi, (w.name:gsub(":", "-")))
    local far = SUN * (R * 3)
    cam.x, cam.y, cam.z = far.x, far.y, far.z
    cam:lookAt(vec3(0, 0, 0), vec3(0, 1, 0))
    yield()
    countsDump("world " .. wi .. " before generatePlanet")
    P("GENERATE %s", w.name)
    terrain.generatePlanet(1, o)
    yield(); yield()
    if params.loadwatch > 0 and wi == params.first then
      -- the palette's arrival: the planet from afar, a shot a second while it fills
      for k = 1, 8 do
        if not terrain.busy() then break end
        shot(string.format("%s_lw_orbit%d", tag, k)); hold(1.0)
      end
    end
    wait_for(function() return not terrain.busy() end, 240)
    P("FILLED %s", w.name); countsDump("world " .. wi .. " filled")
    local top = (w.peak or 100) + 60
    -- slope over ~6 m at directions 35-60 deg from the sun
    local flat, flat_s, steep, steep_s
    local N = 700
    for i = 0, N - 1 do
      local d = fib(i, N)
      local s = d:dot(SUN)
      if s > params.smin and s < params.smax then
        local h0 = ground(d, R, top)
        local t1 = d:cross(vec3(0, 1, 0)):normalized()
        local t2 = d:cross(t1)
        local h1 = ground((d + t1 * (6 / R)):normalized(), R, top)
        local h2 = ground((d + t2 * (6 / R)):normalized(), R, top)
        if h0 and h1 and h2 and (not w.seaAlt or h0 > R + w.seaAlt + 1) then
          local sl = math.sqrt(((h1 - h0) / 6) ^ 2 + ((h2 - h0) / 6) ^ 2)
          if not flat_s or sl < flat_s then flat, flat_s = d, sl end
          if not steep_s or sl > steep_s then steep, steep_s = d, sl end
        end
      end
    end
    if not flat then P("WORLD %d %s: no sunlit ground", wi, w.name) end
    if flat then
    P("WORLD %d %s (%s) r %.0f | flat slope %.2f | steep slope %.2f", wi, w.name, w.label or "?", R, flat_s, steep_s or -1)
    do
      -- flat ground: look away from the sun's azimuth (light from behind-left)
      local d = flat
      local t = (SUN - d * SUN:dot(d)):normalized() * -1
      local eye = along(d, t, 0, R, top, 1.7)
      if params.dist > 0 then
        P("SUN elevation %.1f deg", math.deg(math.asin(SUN:dot(d))))
        view(cam, eye, along(d, t, 2.5, R, top, 0), d, tag .. "_feet")
        for _, m in ipairs({ 30, 100, 300 }) do
          view(cam, eye, along(d, t, m, R, top, 0), d, tag .. "_d" .. m)
        end
        -- the sun on the right: look a quarter turn from it (the camera's right is
        -- forward x up, so turn until that leans toward the sun)
        local side = d:cross(t):normalized()
        if side:cross(d):dot(SUN) < 0 then side = side * -1 end
        view(cam, eye, along(d, side, 2.5, R, top, 0), d, tag .. "_side_feet")
        view(cam, eye, along(d, side, 30, R, top, 0), d, tag .. "_side_d30")
      elseif params.only == 0 then
      view(cam, eye, along(d, t, 2.5, R, top, 0), d, tag .. "_feet")
      view(cam, eye, along(d, t, 12, R, top, 0), d, tag .. "_eye")
      view(cam, eye, along(d, t, 80, R, top, 0), d, tag .. "_far")
      view(cam, along(d, t, 0, R, top, 25), along(d, t, 60, R, top, 0), d, tag .. "_high")
      end
      if params.graze > 0 then
        view(cam, along(d, t, 0, R, top, 0.6), along(d, t, 300, R, top, 0), d, tag .. "_graze")
      end
      if params.seam > 0 then
        -- slot borders up close (playtest 2026-11-06 "odd blending lines"): two
        -- discs of slots far apart in the palette (2 soil | 15 sandstone, 1 rust |
        -- 13 basalt) painted side by side ahead, photographed from 0.25-1.7 m up.
        -- An interpolated vertex slot crossing a whole number between them shows
        -- that slot as a thin line (raster.wgsl terrain_splat's `whole` test).
        local t2 = d:cross(t):normalized()
        local function paint(p, slot, r)
          terrain.paintTexture(p.x, p.y, p.z, r, slot, { hardness = 1.0, falloff = "linear" })
        end
        local A = along(d, t, 3.0, R, top, 0)
        local B = along(d, t, 6.0, R, top, 0)
        local C2 = along(d, t2, 8.0, R, top, 0)
        local D2 = (C2 + t * 3.0)
        paint(A, params.seam_a, 2.6); paint(B, params.seam_b, 2.0)
        paint(C2, params.seam_c, 2.6); paint(D2, params.seam_d, 2.0)
        yield(); wait_for(function() return not terrain.busy() end, 60)
        hold(1.0)
        local mid = along(d, t, 4.6, R, top, 0)
        view(cam, along(d, t, 2.4, R, top, 0.30), mid, d, tag .. "_seam_030")
        view(cam, along(d, t, 3.6, R, top, 0.12), mid, d, tag .. "_seam_012")
        view(cam, along(d, t, 1.8, R, top, 0.70), mid, d, tag .. "_seam_070")
        view(cam, along(d, t, 0.0, R, top, 1.70), mid, d, tag .. "_seam_170")
        local mid2 = (C2 + t * 1.6)
        view(cam, C2 - t * 0.6 + d * 0.35, mid2, d, tag .. "_seam2_035")
        if params.night > 0 then
          -- the same borders in the dark (a lamp at the knee): only self-lit slots show
          local lamp
          createNode("Lamp", nil, function(n) lamp = n end)
          wait_for(function() return lamp end, 5)
          local lp = along(d, t, 3.0, R, top, 0.8)
          lamp.x, lamp.y, lamp.z = lp.x, lp.y, lp.z
          lamp:setPointLight({ color = { 1.0, 0.93, 0.82 }, intensity = 0.6, range = 6 })
          local L = find("Lighting"); L = L and L:getcomponent("Light")
          local was = L and { L.intensity, L.ambientR, L.ambientG, L.ambientB }
          if L then L.intensity = 0.0; L.ambientR, L.ambientG, L.ambientB = 0.004, 0.004, 0.005 end
          view(cam, along(d, t, 2.4, R, top, 0.30), mid, d, tag .. "_seam_030_dark")
          view(cam, C2 - t * 0.6 + d * 0.35, mid2, d, tag .. "_seam2_035_dark")
          if L then L.intensity, L.ambientR, L.ambientG, L.ambientB = was[1], was[2], was[3], was[4] end
          lamp:setPointLight({ intensity = 0 })
        end
      end
      if params.border > 0 then
        -- slot borders as the generator and veins make them (engine terrain stage 2,
        -- height blending): pairs painted as two discs side by side, so a border runs
        -- straight ahead through Q, photographed from 0.6, 1.5 and 3 m and 30 m back;
        -- then a crystal seam (a line of small default-brush discs, as mineral_field
        -- paints one) across a disc of host rock. Off to the side of the seam test.
        local t2 = d:cross(t):normalized() * -1
        local function at(a, b, h)
          local v = t * a + t2 * b
          local m = v:length()
          if m < 1e-6 then return along(d, t, 0, R, top, h) end
          return along(d, v * (1 / m), m, R, top, h)
        end
        local function paint(p, slot, r, brush)
          if brush then terrain.paintTexture(p.x, p.y, p.z, r, slot, brush)
          else terrain.paintTexture(p.x, p.y, p.z, r, slot) end
        end
        local function settle() yield(); wait_for(function() return not terrain.busy() end, 60); hold(1.0) end
        local function views(name)
          view(cam, at(4.2, 9.0, 0.6), at(5.0, 10.5, 0), d, tag .. "_b" .. name .. "_06")
          view(cam, at(3.5, 9.6, 1.5), at(5.4, 10.5, 0), d, tag .. "_b" .. name .. "_15")
          view(cam, at(2.0, 10.0, 3.0), at(5.6, 10.5, 0), d, tag .. "_b" .. name .. "_30")
          view(cam, at(-24.0, 10.5, 10.0), at(5.0, 10.5, 0), d, tag .. "_b" .. name .. "_d30")
        end
        local bpairs = { { "rocksoil", params.br_rock, params.br_soil }, { "sandrock", params.br_sand, params.br_rock2 },
          { "snowrock", params.br_snow, params.br_rock } }
        for _, pr in ipairs(bpairs) do
          -- A on the near side of the border line (b < 10.5), B beyond it
          paint(at(5.0, 7.5, 0), pr[2], 3.2); paint(at(5.0, 13.5, 0), pr[3], 3.2)
          settle(); views(pr[1])
        end
        -- the crystal deposit: host rock, then a seam of 0.9 m discs across it
        paint(at(5.0, 10.5, 0), params.br_host, 5.0)
        for k = -5, 5 do
          paint(at(5.0 + k * 0.55, 10.5 + 0.25 * math.sin(k * 0.9), -0.2), params.br_crystal, 0.9 + 0.15 * math.cos(k * 1.3))
        end
        settle(); views("crystal")
      end
      if params.cave > 0 then
        local g = ground(d, R, top) or R
        local c = d * (g - 14)
        local t2 = d:cross(t):normalized()
        for _, o in ipairs({ vec3(0, 0, 0), t * 5, t * -5, t2 * 5, t2 * -5 }) do
          local q = c + o
          terrain.dig(q.x, q.y, q.z, 8, 4, { hardness = 1, falloff = "linear" })
        end
        yield(); wait_for(function() return not terrain.busy() end, 60)
        -- what the generator lays in pockets and seams, on the walls (slots 5, 6 and the world's crystal)
        local paints = { { t, 5 }, { t2, 6 }, { t2 * -1, (o.pockets and o.pockets.slot) or 7 } }
        for _, pp in ipairs(paints) do
          local w = c + pp[1] * 12.5 - d * 1.0
          terrain.paintTexture(w.x, w.y, w.z, 3.0, pp[2], { hardness = 0.6, falloff = "smooth" })
        end
        yield(); wait_for(function() return not terrain.busy() end, 60)
        local lamp
        createNode("Lamp", nil, function(n) lamp = n end)
        wait_for(function() return lamp end, 5)
        lamp.x, lamp.y, lamp.z = c.x, c.y, c.z
        lamp:setPointLight({ color = { 1.0, 0.93, 0.82 }, intensity = 3.0, range = 30 })
        local eye = c - t * 3 - t2 * 3
        view(cam, eye, c + t * 12, d, tag .. "_cave_seam")
        view(cam, eye, c + t2 * 12, d, tag .. "_cave_magma")
        view(cam, c + t * 3 + t2 * 3, c - t2 * 12, d, tag .. "_cave_crystal")
        -- the crystal pocket up close, the lamp at the shoulder (the playtest's 8.png distance)
        lamp.x, lamp.y, lamp.z = (c - t2 * 7 + t * 1.5).x, (c - t2 * 7 + t * 1.5).y, (c - t2 * 7 + t * 1.5).z
        view(cam, c - t2 * 8.0, c - t2 * 12.5 - d * 1.0, d, tag .. "_cave_crystal_near")
        lamp.x, lamp.y, lamp.z = c.x, c.y, c.z
        lamp.x, lamp.y, lamp.z = c.x + 0, c.y, c.z
        view(cam, c + d * 4, c - d * 9 + t * 4, t, tag .. "_cave_floor")
        if params.seam > 0 then
          -- two slots far apart in the palette side by side on a dug wall (a tunnel
          -- face), the camera a hand from it: the playtest's 7.png distance
          local hw = terrain.raycast(c, t * -1, 30)
          if hw then
            local w = hw.pos
            terrain.paintTexture((w + t2 * -1.4).x, (w + t2 * -1.4).y, (w + t2 * -1.4).z, 1.8, params.seam_c, { hardness = 1.0, falloff = "linear" })
            terrain.paintTexture((w + t2 * 1.4).x, (w + t2 * 1.4).y, (w + t2 * 1.4).z, 1.8, params.seam_d, { hardness = 1.0, falloff = "linear" })
            yield(); wait_for(function() return not terrain.busy() end, 60)
            hold(1.0)
            local lp = w + t * 1.2 + d * 0.5
            lamp.x, lamp.y, lamp.z = lp.x, lp.y, lp.z
            lamp:setPointLight({ color = { 1.0, 0.93, 0.82 }, intensity = 1.2, range = 8 })
            view(cam, w + t * 0.6, w, d, tag .. "_wall_060")
            view(cam, w + t * 0.25 + d * 0.1, w - d * 0.1, d, tag .. "_wall_025")
            lamp:setPointLight({ intensity = 0.0 })
            view(cam, w + t * 0.25 + d * 0.1, w - d * 0.1, d, tag .. "_wall_025_dark")
          end
        end
        lamp:setPointLight({ intensity = 0 })
      end
    end
    if steep and params.only == 0 then
      local d = steep
      local t = (SUN - d * SUN:dot(d)):normalized()
      local aim = along(d, t, 0, R, top, 1.0)
      local e12, u12 = along(d, t, -12, R, top, 1.7)
      view(cam, e12, aim, u12, tag .. "_slope12")
      local e3, u3 = along(d, t, -3, R, top, 1.7)
      view(cam, e3, aim, u3, tag .. "_slope3")
    end
    end
  end
  P("DONE")
  countsDump("done"); traceFlush()
  if params.quit > 0 then app.quit() end
end

local HT, NF, TRON = 0, 0, false
local TPART = { "terrainMeshing", "terrainStreaming", "terrainPalette", "terrainShadow", "assetDecode", "assetUpload" }
function lateUpdate(node, dt)
  if params.trace > 0 then
    if not TRON then perf.enable(true); TRON = true
      TR[1] = "t\tframe\tms\tterrain_bucket\tuntimed\trender\tgpuWait\tpresent\tassets\tscripts\tphysics\tpaced\t" .. table.concat(TPART, "\t") .. "\tchunks\tfieldChunks\tfieldStandIns\tbusy\tmark\n" end
    local f = perf.frames(1)
    f = f and f[1]
    if f then
      local b, pt, c = f.buckets or {}, f.parts or {}, f.counts or {}
      local row = { string.format("%.3f", W() - W0), tostring(f.frame), string.format("%.2f", f.ms or 0),
        string.format("%.2f", b.terrain or 0), string.format("%.2f", b.untimed or 0), string.format("%.2f", b.render or 0),
        string.format("%.2f", b.gpuWait or 0), string.format("%.2f", b.present or 0), string.format("%.2f", b.assets or 0),
        string.format("%.2f", b.scripts or 0), string.format("%.2f", b.physics or 0), tostring(f.paced or "") }
      for _, k in ipairs(TPART) do row[#row + 1] = string.format("%.2f", pt[k] or 0) end
      row[#row + 1] = tostring(c.chunks or ""); row[#row + 1] = tostring(c.fieldChunks or ""); row[#row + 1] = tostring(c.fieldStandIns or "")
      row[#row + 1] = terrain.busy() and "1" or "0"; row[#row + 1] = MARK
      TR[#TR + 1] = table.concat(row, "\t") .. "\n"
      MARK = ""
    end
    -- written once at the end: rewriting a growing file every few hundred frames
    -- was itself a 0.2-1.2 s script stall (the first traces, 2026-11-05)
  end
  NF = NF + (params.loadwatch > 0 and 0 or 1)
  -- loadwatch: every frame over 40 ms from the start (the palette build, the fill)
  if params.loadwatch > 0 then
    NF = NF + 1
    if dt > 0.040 then HT = HT + 1; P("HITCH frame %d dt %.1f ms", NF, dt * 1000) end
  end
  if not CO then CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
