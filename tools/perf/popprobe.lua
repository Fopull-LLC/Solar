-- POPPROBE: do plants pop in and out round the base while nothing moves?
-- (2026-11-03, playtest: "plants and trees pop in and out rapidly and
-- jarringly near the base, most when you first spawn"; tools/perf/popprobe.sh,
-- pop.py). A NEW Career save, the camera and crew held still against the planet.
--
-- Three phases, `secs` seconds each:
--   spawn   from the scene load: the player's own spawn view, untouched
--   outside the crew outside the VAB's door, looking south over the yard to
--           the edge of the clearing and the treeline
--   inside  inside the VAB, looking out of its door
--
-- Two measures every frame:
--   LOGICAL every flora source's props within `r` m of the camera
--           (scatter.near, ids), keyed by (patch, species, id) so a stand
--           redeclared under a new source id is the same stand: props that
--           appear / disappear, binned by distance to the camera and to the
--           base; a BLINK is one gone within `blink` s of appearing (or back
--           within `blink` s of going), the jarring kind
--   DRAWN   perf.counts().props (scatter instances drawn): with the camera
--           still it should not change; `jumps` = frames it moved > 1.5 %
-- and the field's sources (flora_field.sourceInfo over the scatter ids),
-- per second. A burst of `n` consecutive frames is
-- captured at the start of each phase and `burst2` s in:
-- user://pop/<phase>/bK_fNN.png (pop.py diffs them).
defaults = { quit = 1, slot = 18, seed = 5150, scale = 4, secs = 60, r = 220, blink = 3.0, n = 24, w = 640, h = 360,
             burst2 = 30, preload = 0, phases = 7, usersave = 0, rthz = 30 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("POP %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO = nil, nil
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function astro() return find("Astronaut") end

-- ── the tracker ────────────────────────────────────────────────────────────
local T = { on = false, phase = "?", prev = nil, pos = {}, born = {}, gone = {}, group = {}, ng = 0 }
local SEC = nil
local TOT = {}
local function bin_cam(d) return d < 30 and "c30" or (d < 80 and "c80" or (d < 150 and "c150" or "cfar")) end
local function bin_base(d) return d < 100 and "b100" or (d < 180 and "b180" or (d < 230 and "b230" or "bfar")) end
local function sec_new(t)
  return { t = t, app = 0, dis = 0, blinkIn = 0, blinkOut = 0, bins = {}, pmin = math.huge, pmax = -1, jumps = 0,
           imax = 0, frames = 0, st0 = nil, n = 0, worst = nil }
end
local function addbin(S, k) S.bins[k] = (S.bins[k] or 0) + 1 end
local function tot(k, v) TOT[T.phase] = TOT[T.phase] or {}; local t = TOT[T.phase]; t[k] = (t[k] or 0) + (v or 1) end
-- (the plants' ground audit count, flora_field.auditRemoved)
local function stats_copy(ff)
  return { audited = ff and ff.auditRemoved or 0 }
end
local last_props = nil
local function sec_flush(force)
  local S = SEC
  if not S then return end
  if not force and time - S.t < 1.0 then return end
  local ff = findScript("flora_field")
  local st = stats_copy(ff)
  local d = {}
  for k, v in pairs(st) do d[#d + 1] = string.format("%s %d", k, v - (S.st0 and S.st0[k] or 0)); tot(k, v - (S.st0 and S.st0[k] or 0)) end
  table.sort(d)
  local b = {}
  for k, v in pairs(S.bins) do b[#b + 1] = k .. "=" .. v end
  table.sort(b)
  P("SEC %s +%.0f: app %d dis %d blinkIn %d blinkOut %d [%s] | drawn %s..%s jumps %d inst<=%d frames %d | sources %d | %s%s",
    T.phase, S.t - T.t0, S.app, S.dis, S.blinkIn, S.blinkOut, table.concat(b, " "),
    S.pmax >= 0 and tostring(S.pmin) or "-", S.pmax >= 0 and tostring(S.pmax) or "-", S.jumps, S.imax, S.frames,
    S.n, table.concat(d, ", "), S.worst and (" | e.g. " .. S.worst) or "")
  tot("app", S.app); tot("dis", S.dis); tot("blinkIn", S.blinkIn); tot("blinkOut", S.blinkOut); tot("jumps", S.jumps)
  tot("frames", S.frames)
  SEC = sec_new(time)
  SEC.st0 = st
end

local function cam_pos()
  local pc = findScript("planet_camera")
  local n = pc and pc.node
  local p = n and n.valid ~= false and n.worldPos
  return p
end

-- The field's sources now, live and retiring: flora_field.sourceInfo over
-- scatter ids (small integers, shared with the rocks), scanned to 400 past
-- the highest seen.
local hi_id = 0
local function flora_sources(ff)
  local out = {}
  if not (ff and ff.sourceInfo) then return out end
  for id = 1, hi_id + 400 do
    local s = ff.sourceInfo(id)
    if s then
      out[#out + 1] = { id = id, patch = s.patch, spid = s.spid, part = s.part }
      if id > hi_id then hi_id = id end
    end
  end
  return out
end

local function track()
  if not T.on then return end
  local ff = findScript("flora_field")
  local b = home()
  local cp = cam_pos()
  if not SEC then SEC = sec_new(time); SEC.st0 = stats_copy(ff) end
  local S = SEC
  S.frames = S.frames + 1
  local c = perf.counts and perf.counts() or {}
  local pr = c.props or 0
  if pr < S.pmin then S.pmin = pr end
  if pr > S.pmax then S.pmax = pr end
  if (c.instances or 0) > S.imax then S.imax = c.instances or 0 end
  if last_props and math.abs(pr - last_props) > math.max(20, last_props * 0.015) then S.jumps = S.jumps + 1 end
  last_props = pr
  if not (ff and ff.sourceInfo and b and cp) then sec_flush(); return end
  local list = flora_sources(ff)
  S.n = #list
  local cur, pos = {}, {}
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  for _, s in ipairs(list) do
    if s.part ~= "bark" then
      local gk = tostring(s.patch) .. "|" .. tostring(s.spid)
      local g = T.group[gk]
      if not g then T.ng = T.ng + 1; g = T.ng; T.group[gk] = g end
      local ok, F = pcall(scatter.near, s.id, cp, params.r, { flat = true, fields = { "ids", "x", "y", "z" } })
      if ok and F and F.ids then
        local ids, X, Y, Z = F.ids, F.x, F.y, F.z
        for k = 1, F.count do
          local key = g * 4294967296 + ids[k]
          if not cur[key] then
            cur[key] = true
            pos[key] = { X[k] - b.x, Y[k] - b.y, Z[k] - b.z }
          end
        end
      end
    end
  end
  local prev = T.prev
  T.prev = cur
  if not prev then T.pos = pos; return end
  local now = time
  local function classify(p)
    local dc = len(b.x + p[1] - cp.x, b.y + p[2] - cp.y, b.z + p[3] - cp.z)
    local db = type(bx) == "number" and len(p[1] - bx, p[2] - by, p[3] - bz) or 1e9
    return bin_cam(dc), bin_base(db), dc, db
  end
  for key in pairs(cur) do
    if not prev[key] then
      S.app = S.app + 1
      local p = pos[key]
      local bc, bb, dc, db = classify(p)
      addbin(S, "+" .. bc); addbin(S, "+" .. bb)
      if T.gone[key] and now - T.gone[key] < params.blink then
        S.blinkIn = S.blinkIn + 1
        S.worst = S.worst or string.format("back after %.2f s at cam %.0f m base %.0f m (group %d)", now - T.gone[key], dc, db, math.floor(key / 4294967296))
      end
      T.born[key] = now
    end
  end
  for key in pairs(prev) do
    if not cur[key] then
      S.dis = S.dis + 1
      local p = T.pos[key]
      if p then
        local bc, bb, dc, db = classify(p)
        addbin(S, "-" .. bc); addbin(S, "-" .. bb)
        if T.born[key] and now - T.born[key] < params.blink then
          S.blinkOut = S.blinkOut + 1
          S.worst = S.worst or string.format("gone after %.2f s at cam %.0f m base %.0f m (group %d)", now - T.born[key], dc, db, math.floor(key / 4294967296))
        end
      end
      T.gone[key] = now
    end
  end
  for key, p in pairs(pos) do T.pos[key] = p end
  sec_flush()
end

local function phase(name)
  sec_flush(true)
  T.phase, T.t0, T.on = name, time, true
  T.prev, T.born, T.gone = nil, {}, {}
  SEC = nil
  last_props = nil
  P("PHASE %s", name)
end
local function phase_end()
  sec_flush(true)
  local t = TOT[T.phase] or {}
  local ks = {}
  for k, v in pairs(t) do ks[#ks + 1] = string.format("%s %d", k, v) end
  table.sort(ks)
  P("TOTAL %s: %s", T.phase, table.concat(ks, ", "))
end

-- ── frames ─────────────────────────────────────────────────────────────────
local function burst(tag)
  local out = 0
  for i = 1, math.floor(params.n) do
    out = out + 1
    local okc = pcall(camera.capture, { w = params.w, h = params.h, ui = false, draws = false }, function(bytes)
      out = out - 1
      if bytes then assets.writeBytes(string.format("user://pop/%s/%s_f%02d.png", T.phase, tag, i), bytes, { async = true }) end
    end)
    if not okc then out = out - 1 end
    yield()
    track()
  end
  wait_for(function() track(); return out <= 0 end, 10, "captures")
end
-- hold `secs` of game time, tracking every frame, a burst at `bursts` s
-- (`fbursts`: seconds after the first flora source is made, bursts "fK")
local function hold(secs, bursts, fbursts)
  local acc, last = 0, time
  local bi, fi, ft = 1, 1, nil
  while acc < secs do
    if bursts and bursts[bi] and acc >= bursts[bi] then burst("b" .. bi); bi = bi + 1 end
    local ff = findScript("flora_field")
    if not ft and ff and (ff.sources or 0) > 0 then ft = acc; P("first flora source at +%.1f s", acc) end
    if ft and fbursts and fbursts[fi] and acc - ft >= fbursts[fi] then burst("f" .. fi); fi = fi + 1 end
    yield()
    track()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end

-- ── the base's ground frame (base_facilities' layout u, v; h over the plain) ─
local function base_pt(u, v, h)
  local bf = findScript("base_facilities")
  local b = home()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R = save.get("base.r") or len(bx, by, bz)
  local F = bf.frameOf({ x = bx, y = by, z = bz }, save.get("base.heading") or 0, R)
  local d = bf.dirAt(F, u, v)
  return b.x + d.x * (R + h), b.y + d.y * (R + h), b.z + d.z * (R + h), d
end
local function stand(u, v)
  local a = astro()
  local x, y, z, d = base_pt(u, v, 40)
  local ok, hit = pcall(raycast, x, y, z, -d.x, -d.y, -d.z, 80, { ignore = a })
  local h = (ok and hit and hit.distance) and (40 - hit.distance) or 0.2
  x, y, z = base_pt(u, v, h + 1.25)
  a.x, a.y, a.z = x, y, z
  a.vx, a.vy, a.vz = 0, 0, 0
  return h
end
local function cam_at(c, t)
  findScript("planet_camera").setShot(function()
    local ax, ay, az, d = base_pt(c[1], c[2], c[3])
    local tx, ty, tz = base_pt(t[1], t[2], t[3])
    return ax, ay, az, tx, ty, tz, d.x, d.y, d.z
  end, 0.05)
end

local function main()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  pcall(perf.enable, true)
  if params.usersave > 0 then
    -- a COPY of the player's save (popprobe.sh USERSAVE=1), loaded as CONTINUE does
    save.slot("slot1")
    scene.load("system")
    yield()
  else
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
  end
  local ph = math.floor(params.phases)
  -- SPAWN: from the load, the player's own view; tracked from the reveal on
  -- (and the flora's work before it is counted in the first second).
  local seen = {}
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    local ff = findScript("flora_field")
    if ff and (ff.sources or 0) > 0 and not seen.flora then seen.flora = W(); P("first flora source") end
    if gm and gm.loading == false and not seen.loaded then seen.loaded = W(); P("loaded") end
    if gm and seen.loaded and not gm.curtain and not seen.reveal then seen.reveal = W(); P("REVEAL (flora sources %s)", ff and ff.sources or "?") end
    if bf and bf.sited and not seen.sited then seen.sited = W(); P("sited") end
    return seen.reveal
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  if ph % 2 == 1 then
    phase("spawn")
    hold(params.secs, { params.burst2 }, { 0.3, 2.5 })
    phase_end()
  end
  wait_for(function()
    local bf = findScript("base_facilities")
    return bf and bf.sited and not (bf.grading and bf.grading())
  end, 120, "the grade")
  if math.floor(ph / 2) % 2 == 1 then
    -- OUTSIDE the VAB's door (the hangar's lot: u 0, v 28 ± 29.6, door south)
    stand(0, -8)
    cam_at({ 0, -10, 1.7 }, { 0, -120, 0.0 })
    hold(4)
    phase("outside")
    hold(params.secs, { 2, params.burst2 })
    phase_end()
  end
  if math.floor(ph / 4) % 2 == 1 then
    stand(0, 18)
    cam_at({ 0, 16, 1.7 }, { 0, -100, 1.0 })
    hold(4)
    phase("inside")
    hold(params.secs, { 2, params.burst2 })
    phase_end()
  end
  if math.floor(ph / 8) % 2 == 1 then
    -- A SECOND VIEW (engine card draft 0627): a render-target camera 1.5 km
    -- over the base, as the item and part previews stand, drawing at 30 Hz
    -- while the crew stands still outside the VAB. With one scatter cache for
    -- every view, the props round the player's camera are forgotten each
    -- time it draws, and settle back over the next frames.
    stand(0, -8)
    cam_at({ 0, -10, 1.7 }, { 0, -120, 0.0 })
    hold(4)
    local rt
    createNode("Pop RT Cam", nil, function(n)
      rt = n
      pcall(function()
        n:setCamera { target = "poprt", width = 64, height = 64, hz = params.rthz, active = false,
                      sky = false, terrain = false, fog = false, shadows = false }
      end)
    end)
    wait_for(function() return rt ~= nil end, 5, "the rt camera")
    phase("rtcam")
    local t0 = W()
    local acc, last = 0, time
    while acc < params.secs do
      if rt and rt.valid ~= false then
        local x, y, z = base_pt(0, -10, 1500)
        rt.x, rt.y, rt.z = x, y, z
      end
      if acc >= 2 and not T.rtb then T.rtb = true; burst("b1") end
      yield(); track()
      local d = time - last; last = time
      if d > 0 and d < 1 then acc = acc + d end
    end
    phase_end()
    if rt and rt.valid ~= false then rt:destroy() end
    phase("rtoff")
    hold(10, { 2 })
    phase_end()
  end
  findScript("planet_camera").clearShot(0.1)
  -- (the frames are written asynchronously: let the last ones land before quitting)
  local t = W() + 3
  while W() < t do yield() end
  P("DONE")
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt_)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
