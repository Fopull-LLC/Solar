-- SUITSHOTS: the crew's EVA suit in the game, on a NEW save (tools/perf/suitshots.sh).
-- Third person front / side / back / quarter / close with the helmet on; the
-- helmet API (what it says here and on an airless body), the helmet coming
-- off (the hands at the neck ring) and the head under it; first person
-- bare-headed; the left shoulder driven through abduction and flexion by arm
-- IK; a walk; the visor raised. Pictures to user://suitshots/, lines "SUS ".
defaults = { quit = 1, slot = 7, seed = 4242, scale = 4, sweep = 1, walk = 1, seat = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("SUS %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + tmo
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

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://suitshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  -- exactly what the new-save panel's CREATE does (menu_newsave.lua)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function main()
  boot()
  hold(3.0)
  local cam, su, pw = findScript("planet_camera"), findScript("suit"), findScript("planet_walker")
  local b = space.body(save.get("base.body"))
  P("world %s, suit script %s, walker onFoot %s", tostring(b and b.name), tostring(su ~= nil), tostring(pw and pw.onFoot))
  local function crew() return find("Astronaut") end
  local function model()
    for _, c in ipairs(crew():children()) do if c.name == "AstroModel" then return c end end
  end
  local function bone(n) local v = model():bonePos(n); return v end
  local function frame()
    local l = (bone("Upperarm.Left") - bone("Upperarm.Right")):normalized()
    local u = (bone("Head") - bone("Hip")):normalized()
    local f = l:cross(u):normalized()
    return l, u, f
  end
  -- the free camera at `pos` looking at `tgt` (world, this frame)
  local function cam_at(pos, tgt)
    local bn = find(b.name)
    local a = crew()
    local uu = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z):normalized()
    cam.setFreecam(true)
    local fc = cam.freecamState()
    fc.body = b.name
    fc.rel = pos - vec3(bn.x, bn.y, bn.z)
    local d = tgt - pos
    local h = d:flatten(uu)
    fc.ref = h:normalized()
    fc.pitch = math.atan2(d:dot(uu), h:length())
  end
  -- a view: `side` along the crew's left, `fwd` ahead of them, `up`, from
  -- the target bone (+ `lift` up), held for `n` frames then shot
  local function view(name, tb, side, fwd, up, lift, n)
    for _ = 1, (n or 24) do
      local l, u, f = frame()
      local t = bone(tb) + u * (lift or 0)
      cam_at(t + l * side + f * fwd + u * up, t)
      yield()
    end
    shot(name)
    for _ = 1, 3 do
      local l, u, f = frame()
      local t = bone(tb) + u * (lift or 0)
      cam_at(t + l * side + f * fwd + u * up, t)
      yield()
    end
  end
  local function tour(tag)
    view(tag .. "_front", "Back", 0.25, 3.0, 0.15, -0.2)
    view(tag .. "_side", "Back", 3.0, 0.15, 0.15, -0.2)
    view(tag .. "_back", "Back", -0.6, -2.9, 0.4, -0.2)
    view(tag .. "_quarter", "Back", 2.0, 2.2, 0.4, -0.2)
    view(tag .. "_close", "Head", 0.35, 1.05, 0.05, 0.12)
  end

  -- ── helmet on ──
  hold(1.0)
  tour("on")
  -- the API, here and on the other bodies (an airless moon refuses)
  local ok, why = su.canRemoveHelmet()
  P("API here: helmetOn %s canRemoveHelmet %s %s refusal(false) %s", tostring(su.helmetOn()), tostring(ok), tostring(why),
    tostring(su.helmetRefusal(false)))
  for _, nm in ipairs(space.bodies and space.bodies() or {}) do
    local bb = space.body(type(nm) == "table" and nm.name or nm)
    if bb and bb.name ~= b.name and bb.radius then
      local ok2, why2 = su.breathableAt(bb.x, bb.y + bb.radius + 1.0, bb.z)
      P("API on %s: %s %s", bb.name, tostring(ok2), tostring(why2))
    end
  end
  -- ── off: the hands at the neck ring, then the head ──
  local ok3, why3 = su.setHelmet(false)
  P("setHelmet(false): %s %s busy %s", tostring(ok3), tostring(why3), tostring(su.busy))
  view("anim_mid", "Back", 1.6, 1.8, 0.4, -0.1, 30)
  wait_for(function() return not su.busy end, 5, "the helmet animation")
  P("after: helmetOn %s, save crew.helmet %s, changes %s", tostring(su.helmetOn()), tostring(save.get("crew.helmet")),
    tostring(su.changes))
  tour("off")
  view("off_head", "Head", 0.12, 0.62, 0.02, 0.14)
  view("off_head_side", "Head", 0.62, 0.20, 0.02, 0.14)
  -- first person bare-headed
  cam.setFreecam(false)
  cam.firstPerson = true
  hold(1.2)
  shot("off_fp")
  hold(0.3)
  cam.firstPerson = false
  hold(0.6)
  -- ── the left shoulder through its range, by arm IK ──
  if params.sweep > 0 then
    local function drive(kind, deg)
      for _ = 1, 28 do
        su.probeArm = { kind = kind, deg = deg }
        local l, u, f = frame()
        local t = bone("Upperarm.Left")
        cam_at(t + l * 1.05 + f * 0.55 + u * 0.25, t + u * 0.02)
        yield()
      end
      su.probeArm = { kind = kind, deg = deg }
      shot(string.format("sweep_%s_%03d", kind, deg + (kind == "flex" and 40 or 0)))
      yield()
    end
    for _, d in ipairs({ 0, 45, 90, 135, 170 }) do drive("abd", d) end
    for _, d in ipairs({ -40, 0, 60, 120, 170 }) do drive("flex", d) end
  end
  -- ── a walk (helmet off), from the side ──
  if params.walk > 0 then
    input.simulate { key = "w", down = true }
    hold(1.5)
    view("walk_side", "Back", 2.2, 0.3, 0.2, -0.3, 8)
    view("walk_quarter", "Back", 1.6, 1.6, 0.4, -0.3, 6)
    input.simulate { key = "w", down = false }
    hold(1.0)
  end
  -- ── back on, visor raised: the face through the bubble ──
  local ok4, why4 = su.setHelmet(true)
  P("setHelmet(true): %s %s", tostring(ok4), tostring(why4))
  wait_for(function() return not su.busy end, 5, "the helmet animation")
  su.setVisor(false)
  view("visorup_close", "Head", 0.30, 0.95, 0.05, 0.12)
  su.setVisor(true)
  -- ── seated: a rover with an open seat, launched as the builder does it;
  -- the helmet taken off first, so the scene reload shows it kept ──
  if params.seat > 0 then
    su.setHelmet(false, { instant = true })
    P("before the rover: helmetOn %s save %s", tostring(su.helmetOn()), tostring(save.get("crew.helmet")))
    local function rec(uid, id, x, y, z, o)
      o = o or {}
      return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = 0, roll = 0,
               parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = 0 }
    end
    local HP = math.pi / 2
    local bp = { rec(1, "roverBody", 0, 0.62, 0),
      rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
      rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
      rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
      rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
      rec(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }) }
    local co = findScript("company")
    if co and co.earn then co.earn(80000, "probe") end
    cam.setFreecam(false)
    save.set("shipyard.blueprint", { parts = bp })
    save.set("shipyard.site", "runway")
    save.set("shipyard.pilot", 1)
    scene.load("builder")
    local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 6 and B end, 90, "the builder")
    if B then
      hold(1.5)
      save.set("shipyard.site", "runway")
      B.doLaunch()
      if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
      local vc = wait_for(function()
        for _, v in ipairs(findScripts("vessel_controller")) do
          if v.piloting and v.node and v.node.valid then return v end
        end
      end, 150, "the rover")
      wait_for(function()
        local bf = findScript("base_facilities")
        return bf and bf.sited and not (bf.grading and bf.grading())
      end, 120, "the regrade")
      hold(3.0)
      cam, su = findScript("planet_camera"), findScript("suit")
      P("seated: rover %s, helmetOn %s (saved %s), canRemove %s", tostring(vc ~= nil), tostring(su and su.helmetOn()),
        tostring(save.get("crew.helmet")), tostring(su and select(2, su.canRemoveHelmet())))
      if vc then
        view("seat_off_side", "Back", 2.4, 0.4, 0.4, -0.2)
        view("seat_off_quarter", "Back", 1.6, 1.8, 0.6, -0.2)
        su.setHelmet(true, { instant = true })
        view("seat_on_quarter", "Back", 1.6, 1.8, 0.6, -0.2)
        view("seat_on_front", "Back", 0.2, 2.2, 0.5, -0.2)
      end
    end
  end
  P("end: helmetOn %s visor %s lamps %s save %s/%s/%s", tostring(su.helmetOn()), tostring(su.visorDown()),
    tostring(su.lampsOn()), tostring(save.get("crew.helmet")), tostring(save.get("crew.visor")), tostring(save.get("crew.lamps")))
  cam.setFreecam(false)
  wait_for(function() return pending <= 0 end, 20, "the captures")
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  if not CO then NODE = node; CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
