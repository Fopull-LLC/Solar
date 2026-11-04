-- FDNPROBE: the base buildings' foundations (tools/perf/fdnprobe.sh). A new
-- save made as the new-save panel makes one (Earth-like, or Alien with its
-- seed: params alien / homeseed), and once the base stands:
--
--   * every facility's lot box (base_facilities FACILITIES, the model's whole
--     x × z box) walked round its edge and a ring 2 m inside it, 1 m apart:
--     the ground under each point measured along the BUILDING's up, as model
--     y (0 = the model's ground plane, the floor slab's bottom at -0.6 or
--     whatever the model has), against the sphere the grade aims at there.
--     One `FP LOT` line a facility: the lowest ground (model y) on the edge
--     and inside, the sphere's sag at the box's corner, and the grade's
--     residual (ground - sphere) min / max;
--   * pictures (shots = 1): from 0.7 m over the ground, 7 m out from two
--     opposite corners of every lot, looking at the corner's foot.
-- The probe's slot is deleted at the end.
defaults = { slot = 15, seed = 1911564384, alien = 0, homeseed = 0, quit = 1, noon = 60, shots = 1, only = "", tag = "", out = 3.0, eyeh = 1.0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FP %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
  return nil
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local NODE, CO
local pending = 0
local TAG = "earth"

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://fdnprobe/" .. TAG .. "_" .. name .. ".png", bytes); P("SHOT %s_%s", TAG, name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  local t = W() + 10
  while pending > 0 and W() < t do coroutine.yield() end
end

local function slot_name() return "slot" .. math.floor(params.slot) end

local function make_save()
  local s = slot_name()
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", 4)
  if params.alien > 0 then
    save.set("g_homeKind", "alien")
    save.set("g_homeSeed", math.floor(params.homeseed))
  end
end

local function ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

local function sun_up()
  local at = findScript("atmosphere")
  return at and at.sun_now or 0
end
local function to_noon()
  if params.noon <= 0 then return end
  local t0, prev, rose = W(), nil, false
  while W() - t0 < 120 do
    space.warp(params.noon)
    yield()
    local s = sun_up()
    if s >= 0.8 or (rose and s > 0.3 and s < prev) then break end
    if prev and s > prev then rose = true end
    prev = s
  end
  space.warp(1)
  hold(1.5)
  P("NOON sun %.2f after %.0f s", sun_up(), W() - t0)
end

-- small vector helpers on plain tables
local function V(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b, k) k = k or 1 return V(a.x + b.x * k, a.y + b.y * k, a.z + b.z * k) end
local function mul(a, k) return V(a.x * k, a.y * k, a.z * k) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function unit(a) local l = math.sqrt(dot(a, a)); return mul(a, 1 / l) end
local FACE = { S = { 0, -1 }, N = { 0, 1 }, E = { 1, 0 }, W = { -1, 0 } }

-- A facility's model frame, body-relative: g (model ground origin at y = 0
-- minus lift), up, right (+X), fwd (+Z).
local function model_frame(bf, Fr, f)
  local up = bf.dirAt(Fr, f.u, f.v)
  local fc = FACE[f.face] or FACE.S
  local w = add(mul(Fr.eu, fc[1]), Fr.ev, fc[2])
  local fwd = unit(add(w, up, -dot(w, up)))
  local right = cross(up, fwd)
  return { g = mul(up, Fr.R), up = up, right = right, fwd = fwd, lift = f.lift or 0 }
end

-- The ground under model point (x, z), as model y (nil on a miss); and the
-- sphere's own height there as model y.
local function ground_y(b, M, R, x, z)
  local p = add(add(add(M.g, M.right, x), M.fwd, z), M.up, M.lift + 8.0)
  local hit = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-M.up.x, -M.up.y, -M.up.z), 40)
  local gy = hit and (8.0 - hit.distance) or nil
  -- sphere: |q + up t| = R, q the plane point at model y 0
  local q = add(add(add(M.g, M.right, x), M.fwd, z), M.up, M.lift)
  local qu = dot(q, M.up)
  local qq = dot(q, q)
  local t = -qu + math.sqrt(math.max(0, qu * qu - (qq - R * R)))
  return gy, t, hit and hit.exact
end

local function ring(cx, cz, hx, hz, step)
  local out = {}
  local nx, nz = math.max(1, math.ceil(2 * hx / step)), math.max(1, math.ceil(2 * hz / step))
  for i = 0, nx do
    local x = cx - hx + 2 * hx * i / nx
    out[#out + 1] = { x, cz - hz }; out[#out + 1] = { x, cz + hz }
  end
  for j = 1, nz - 1 do
    local z = cz - hz + 2 * hz * j / nz
    out[#out + 1] = { cx - hx, z }; out[#out + 1] = { cx + hx, z }
  end
  return out
end

local function measure(bf, Fr, bname)
  local b = space.body(bname)
  for _, f in ipairs(bf.FACILITIES) do
    local M = model_frame(bf, Fr, f)
    local hx, hz = f.lot[1] / 2, f.lot[2] / 2
    local function stats(pts)
      local lo, lox, loz, rmin, rmax, miss, inexact, smin = 1e9, 0, 0, 1e9, -1e9, 0, 0, 1e9
      for _, p in ipairs(pts) do
        local gy, sy, ex = ground_y(b, M, Fr.R, p[1], p[2])
        if gy then
          if gy < lo then lo, lox, loz = gy, p[1], p[2] end
          rmin, rmax = math.min(rmin, gy - sy), math.max(rmax, gy - sy)
          smin = math.min(smin, sy)
          if not ex then inexact = inexact + 1 end
        else miss = miss + 1 end
      end
      return lo, lox, loz, rmin, rmax, smin, miss, inexact
    end
    local e = { stats(ring(f.ox, f.oz, hx, hz, 1.0)) }
    local i = { stats(ring(f.ox, f.oz, math.max(0.5, hx - 2), math.max(0.5, hz - 2), 1.0)) }
    P("LOT %-11s edge low %6.2f at (%6.1f,%6.1f) sphere %6.2f resid %5.2f..%5.2f | in2m low %6.2f sphere %6.2f resid %5.2f..%5.2f | miss %d/%d inexact %d",
      f.prefab, e[1], e[2], e[3], e[6], e[4], e[5], i[1], i[6], i[4], i[5], e[7], i[7], e[8] + i[8])
  end
end

local function aim(cam, bname, rel, at, pitch)
  local fc = cam.freecamState()
  fc.body = bname
  fc.rel = rel
  local up = rel:normalized()
  local d = (at - rel):flatten(up)
  if d:length() < 1e-3 then d = up:cross(vec3(1, 0, 0)) end
  fc.ref = d:normalized()
  fc.pitch = math.rad(pitch or 0)
end

local function pictures(bf, Fr, bname)
  local cam = findScript("planet_camera")
  if not (cam and cam.setFreecam) then P("no camera"); return end
  cam.setFreecam(true)
  hold(0.3)
  local only = params.only
  for _, f in ipairs(bf.FACILITIES) do
    if not only or only == "" or f.prefab == only then
      local M = model_frame(bf, Fr, f)
      local hx, hz = f.lot[1] / 2, f.lot[2] / 2
      for _, c in ipairs({ { -1, 1, "fl" }, { 1, -1, "br" } }) do
        local cx, cz = f.ox + c[1] * hx, f.oz + c[2] * hz
        local ex, ez = cx + c[1] * params.out, cz + c[2] * params.out
        local b = space.body(bname)
        local gy = ground_y(b, M, Fr.R, ex, ez) or 0
        local gc = ground_y(b, M, Fr.R, cx, cz) or 0
        local eye = add(add(add(M.g, M.right, ex), M.fwd, ez), M.up, M.lift + gy + params.eyeh)
        -- look at the corner's foot (the camera's yaw toward the corner, its pitch down to the ground there)
        local at = add(add(add(M.g, M.right, cx - c[1] * 0.5), M.fwd, cz - c[2] * 0.5), M.up, M.lift + gc)
        local dist = math.sqrt(2) * (params.out + 0.5)
        aim(cam, bname, vec3(eye.x, eye.y, eye.z), vec3(at.x, at.y, at.z), math.deg(math.atan((gc - gy - params.eyeh) / dist)))
        hold(1.2)
        shot(f.prefab .. "_" .. c[3])
      end
    end
  end
  cam.setFreecam(false)
  hold(0.3)
end

local function main()
  NODE.persistent = true
  TAG = (params.tag and params.tag ~= "") and params.tag
    or (params.alien > 0 and string.format("alien%d", math.floor(params.homeseed)) or "earth")
  make_save()
  P("created %s: seed %d, home %s", save.slot(), params.seed, params.alien > 0 and "alien" or "earth")
  scene.load("system")
  yield()
  local t0 = W()
  local ok = wait_for(ready, 260)
  P("READY %s after %.1f s", tostring(ok ~= nil), W() - t0)
  local bf = findScript("base_facilities")
  local bname = save.get("base.body")
  local Fr = bf.frameOf({ x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") },
    save.get("base.heading") or 0, save.get("base.r"))
  local b = space.body(bname)
  P("BASE %s R %.2f (body radius %.1f) heading %.2f", tostring(bname), Fr.R, b and b.radius or -1, Fr.heading)
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  hold(3.0)
  measure(bf, Fr, bname)
  to_noon()
  if params.shots > 0 then pictures(bf, Fr, bname) end
end

function start(node)
  NODE = node
  CO = coroutine.create(function()
    local ok, err = pcall(main)
    if not ok then P("ERROR %s", tostring(err)) end
    wait_for(function() return pending <= 0 end, 20)
    local s = slot_name()
    pcall(scene.load, "menu"); yield(); yield()
    pcall(terrain.deleteSaveDir, "saves/" .. s .. "/terrain")
    if save.deleteSlot then pcall(save.deleteSlot, s) end
    P("deleted %s", s)
    P("DONE")
    if params.quit > 0 then app.quit() end
  end)
end

function update(node, dt)
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
