-- GROUNDPROBE: do the plants and rocks stand ON the ground? On a copy of the
-- player's save (tools/perf/groundprobe.sh): the astronaut is put at spots
-- round the base (fence sides, the pad), the fields are left to settle, and
-- every settled prop near is measured against the terrain under it
-- (flora_field / mineral_field groundAudit: terrain.query at the prop's root,
-- + over the ground, − under it). Then a pit is dug under a bush with
-- laser-sized bites and the bush is measured again. 1280x720 pictures.
--
-- params: arrive (s at each spot), radius (m audited round it), dig (1 = the
--   dig test), notify (1 = tell the fields the ground changed, as the tool
--   belt does), fix (0 = hold every re-drop back: the fields' GROUND.wait is
--   set to forever, the "before"), early (m audited round the crew and the
--   base centre the moment the world is ready, and again early_wait s later:
--   what settled while the world was loading), quit.
defaults = { arrive = 14, radius = 40, dig = 1, notify = 1, quit = 1, after = 8, fix = 1, early = 150, early_wait = 12, away = 300, spots = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("GP %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local NODE, CO
local pending = 0

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://ground/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if math.abs(d) < 0.03 then return r end
    r = r - (d > 0 and math.max(d * 0.8, 0.02) or math.min(d * 0.8, -0.02))
  end
  return r
end

-- What a floating prop rests on: a ray from just over its root, down.
local function under(b, e)
  local rx, ry, rz = e.x - b.x, e.y - b.y, e.z - b.z
  local l = len(rx, ry, rz)
  local ux, uy, uz = rx / l, ry / l, rz / l
  local h = raycast(vec3(e.x + ux * 0.3, e.y + uy * 0.3, e.z + uz * 0.3), vec3(-ux, -uy, -uz), 1.0)
  if not h then return "nothing" end
  local nm = h.node and h.node.valid and h.node.name or "terrain?"
  return string.format("%s@%.2f", nm, h.distance - 0.3)
end

local F, BF
local function uv_of(b, e)
  local u, v = BF.uvOf(F, { x = e.x - b.x, y = e.y - b.y, z = e.z - b.z })
  return u, v
end

local function audit(tag, b, a, radius)
  local ff, mf = findScript("flora_field"), findScript("mineral_field")
  local res = {}
  for nm, f in pairs({ flora = ff, rocks = mf }) do
    local r = f and f.groundAudit and f.groundAudit(a.x, a.y, a.z, radius or params.radius) or nil
    if r then
      P("AUDIT %s %s: checked %d floating %d buried %d worst %+.2f", tag, nm, r.checked, r.floating, r.buried, r.worst)
      for i, e in ipairs(r.examples) do
        if i > 6 then break end
        local u, v = uv_of(b, e)
        P("  %s %s d %+.2f at u %.1f v %.1f on %s", nm, tostring(e.kind), e.d, u, v, under(b, e))
      end
      res[nm] = r
    end
  end
  return res
end

local function stand(b, u, v)
  local d = BF.dirAt(F, u, v)
  local gr = ground_r(b, d.x, d.y, d.z, F.R + 60)
  local a = find("Astronaut")
  a.x, a.y, a.z = b.x + d.x * (gr + 1.0), b.y + d.y * (gr + 1.0), b.z + d.z * (gr + 1.0)
  a.vx, a.vy, a.vz = 0, 0, 0
  return d, gr
end

-- A freecam at (u, v), eye height, looking toward (tu, tv).
local function look(b, u, v, tu, tv, alt)
  local cam = findScript("planet_camera")
  cam.setFreecam(true)
  local fc = cam.freecamState()
  local d = BF.dirAt(F, u, v)
  local gr = ground_r(b, d.x, d.y, d.z, F.R + 60) or F.R
  local t = BF.dirAt(F, tu, tv)
  local up = vec3(d.x, d.y, d.z)
  local fwd = vec3(t.x - d.x, t.y - d.y, t.z - d.z)
  fwd = (fwd - up * fwd:dot(up)):normalized()
  fc.body = b.name
  fc.rel = up * (gr + (alt or 1.7))
  fc.pitch = math.rad(-8)
  fc.ref = fwd
end

local function main()
  NODE.persistent = true
  pcall(perf.enable, true)
  save.slot("slot1")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 300)
  P("ready  engine %s", tostring(app.version and app.version()))
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  BF = findScript("base_facilities")
  local b = space.body(save.get("base.body"))
  F = BF.frameOf({ x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") }, save.get("base.heading") or 0,
    save.get("base.r"))
  local ffx = findScript("flora_field")
  if params.fix <= 0 and ffx and ffx.GROUND then
    ffx.GROUND.wait = 1e12
    if ffx.AUDIT then ffx.AUDIT.every = 0 end
    P("fix held back (GROUND.wait = forever, no audit)")
  end
  local function counters(tag)
    local mf = findScript("mineral_field")
    P("COUNTERS %s flora removed %s redropped %s queued %s | rocks removed %s redropped %s queued %s", tag,
      tostring(ffx and ffx.auditRemoved), tostring(ffx and ffx.auditRedropped), tostring(ffx and ffx.groundBusy and ffx.groundBusy()),
      tostring(mf and mf.auditRemoved), tostring(mf and mf.auditRedropped), tostring(mf and mf.groundBusy and mf.groundBusy()))
  end
  if params.early > 0 then
    for pass = 1, 2 do
      b = space.body(b.name)
      local a = find("Astronaut")
      local au, av = uv_of(b, a)
      P("EARLY pass %d: crew at u %.0f v %.0f", pass, au, av)
      audit("early" .. pass .. "-crew", b, { x = a.x, y = a.y, z = a.z }, params.early)
      local c = BF.dirAt(F, 0, 0)
      audit("early" .. pass .. "-base", b, { x = b.x + c.x * F.R, y = b.y + c.y * F.R, z = b.z + c.z * F.R }, 200)
      counters("early" .. pass)
      if pass == 1 then hold(params.early_wait) end
    end
  end
  local FN = BF.FENCE
  local spots = {
    { "fenceW", FN.u0 - 4, 20, FN.u0, 20 },
    { "fenceE", FN.u1 + 4, 20, FN.u1, 20 },
    { "fenceN", 40, FN.v1 + 4, 40, FN.v1 },
    { "fenceS", -50, FN.v0 - 3, -50, FN.v0 },
    { "pad", BF.PAD.u + 14, BF.PAD.v, BF.PAD.u, BF.PAD.v },
  }
  local total = { flora = { f = 0, b = 0, n = 0 }, rocks = { f = 0, b = 0, n = 0 } }
  for _, s in ipairs(params.spots > 0 and spots or {}) do
    b = space.body(b.name)
    stand(b, s[2], s[3])
    hold(params.arrive)
    b = space.body(b.name)
    local a = find("Astronaut")
    local r = audit(s[1], b, a)
    for nm, t in pairs(total) do
      if r[nm] then t.f, t.b, t.n = t.f + r[nm].floating, t.b + r[nm].buried, t.n + r[nm].checked end
    end
    look(b, s[2] + (s[2] - s[4]) * 1.5, s[3] + (s[3] - s[5]) * 1.5, s[4], s[5])
    hold(1.0)
    shot(s[1])
    hold(0.5)
    findScript("planet_camera").setFreecam(false)
  end
  counters("spots")
  if params.away > 0 then
    -- Walk away (the fields drop the base's patches) and come back.
    b = space.body(b.name)
    stand(b, FN.u0 - params.away, 20)
    hold(params.arrive)
    P("AWAY %d m: back to the base", params.away)
    for _, s in ipairs(spots) do
      b = space.body(b.name)
      stand(b, s[2], s[3])
      hold(params.arrive)
      b = space.body(b.name)
      local a = find("Astronaut")
      local r = audit("back-" .. s[1], b, a)
      for nm, t in pairs(total) do
        if r[nm] then t.f, t.b, t.n = t.f + r[nm].floating, t.b + r[nm].buried, t.n + r[nm].checked end
      end
      look(b, s[2] + (s[2] - s[4]) * 1.5, s[3] + (s[3] - s[5]) * 1.5, s[4], s[5])
      hold(1.0)
      shot("back_" .. s[1])
      hold(0.5)
      findScript("planet_camera").setFreecam(false)
    end
    counters("back")
  end
  P("TOTAL flora floating %d buried %d of %d | rocks floating %d buried %d of %d",
    total.flora.f, total.flora.b, total.flora.n, total.rocks.f, total.rocks.b, total.rocks.n)

  if params.dig > 0 then
    -- A bush (anything not a carpet) 120 m out from the west fence.
    b = space.body(b.name)
    stand(b, FN.u0 - 60, 20)
    hold(params.arrive)
    b = space.body(b.name)
    local a = find("Astronaut")
    local ff = findScript("flora_field")
    local r = ff.groundAudit(a.x, a.y, a.z, 30)
    local pick
    for _, e in ipairs(r.props) do
      local dd = len(e.x - a.x, e.y - a.y, e.z - a.z)
      if e.kind ~= "grass" and e.kind ~= "moss" and math.abs(e.d) < 0.3 and dd > 4 and (not pick or dd < pick.dd) then
        pick = e; pick.dd = dd
      end
    end
    if not pick then
      P("DIG no bush near (%d props)", #r.props)
    else
      local rx, ry, rz = pick.x - b.x, pick.y - b.y, pick.z - b.z
      local l = len(rx, ry, rz)
      local ux, uy, uz = rx / l, ry / l, rz / l
      P("DIG %s at %.1f m, d %+.2f — digging a pit under it", pick.kind, pick.dd, pick.d)
      for k = 0, 5 do
        b = space.body(b.name)
        local x, y, z = b.x + rx - ux * (k * 0.5), b.y + ry - uy * (k * 0.5), b.z + rz - uz * (k * 0.5)
        terrain.dig(x, y, z, 2.4, 0.85)
        if params.notify > 0 and tb and tb.groundChanged then tb.groundChanged(x, y, z, 2.4) end
        hold(0.12)
      end
      hold(params.after)
      b = space.body(b.name)
      -- by id: a re-dropped stand is a new source with the same plants
      local inst = scatter.instance(pick.src, pick.id)
      if not inst then
        for _, e in ipairs(ff.groundAudit(b.x + rx, b.y + ry, b.z + rz, 12).props) do
          if e.id == pick.id then inst = scatter.instance(e.src, e.id); P("DIG (the stand was re-declared: source %s -> %s)", tostring(pick.src), tostring(e.src)) end
        end
      end
      if not inst then
        P("DIG RESULT the bush is gone (no ground left under it?)")
      else
        local d = terrain.query(inst.pos.x, inst.pos.y, inst.pos.z)
        local drop = len(inst.pos.x - b.x, inst.pos.y - b.y, inst.pos.z - b.z) - l
        P("DIG RESULT settled %s, moved %+.2f m along the radial, now d %+.2f", tostring(inst.settled), drop, d or 99)
      end
      local d0 = len(rx, ry, rz)
      local gx, gy, gz = b.x + ux * d0, b.y + uy * d0, b.z + uz * d0
      local cam = findScript("planet_camera")
      cam.setFreecam(true)
      local fc = cam.freecamState()
      local up = vec3(ux, uy, uz)
      local side = up:cross(vec3(0, 0, 1)):normalized()
      fc.body = b.name
      fc.rel = up * (d0 + 3.5) + side * 6
      fc.ref = (side * -1)
      fc.pitch = math.rad(-25)
      hold(1.0)
      shot("dig")
      hold(0.5)
    end
  end
  counters("end")
  wait_for(function() return pending <= 0 end, 20)
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
