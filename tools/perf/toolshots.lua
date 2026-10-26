-- TOOLSHOTS: the hand tools in the game, on a copy of the player's save
-- (tools/perf/toolshots.sh). First person and third person, idle and firing,
-- the gravity gun on a crate if one is near, and a close-up of each tool in
-- the hands. Pictures to user://toolshots/.
defaults = { quit = 1, firesecs = 4.0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("TSG %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = time + secs; while time < t do yield() end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://toolshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function main()
  NODE.persistent = true
  save.slot("slot1")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 200)
  hold(3.0)
  local tb, cam = findScript("tool_belt"), findScript("planet_camera")
  local b = space.body(save.get("base.body"))
  local function body() return find(b.name) end
  local function crew() return find("Astronaut") end
  local function up_at()
    local a, bn = crew(), body()
    local u = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z)
    return u:normalized()
  end
  local function equip(id)
    for i, s in ipairs(tb.belt()) do if s.id == id then tb.sim = { pressed = { [tostring(i)] = true } } end end
    hold(1.2)
    P("equipped %s (want %s)", tostring(tb.toolId()), id)
  end
  -- a heading on the ground: the camera's own, flattened
  local u = up_at()
  local f0 = vec3(cam.fwd_x or 1, cam.fwd_y or 0, cam.fwd_z or 0):flatten(u):normalized()
  -- a crate or can to hold, if the base has one near
  local prop
  for _, nm in ipairs({ "PropCrate", "PropCan", "PropCone" }) do
    for _, n in ipairs(findAll(nm) or {}) do
      local a = crew()
      local d = len(n.x - a.x, n.y - a.y, n.z - a.z)
      if n.valid and d < 60 and (not prop or d < prop.d) then prop = { n = n, d = d } end
    end
  end
  -- else a loose stone from the mineral field
  local mf = findScript("mineral_field")
  local seen
  if not prop and mf and mf.rocksNear then
    local a, bn = crew(), body()
    seen = {}
    for _, rk in ipairs(mf.rocksNear(a.x, a.y, a.z, 40) or {}) do
      local rec = mf.rockRecord and mf.rockRecord(rk)
      local kid = rec and rec.kind and rec.kind.id
      seen[#seen + 1] = tostring(kid)
      local d = len(rk.x - a.x, rk.y - a.y, rk.z - a.z)
      if (kid == "stone" or kid == "boulder") and d > 3 and (not prop or d < prop.d) then
        prop = { rel = vec3(rk.x - bn.x, rk.y - bn.y, rk.z - bn.z), d = d, name = kid }
      end
    end
  end
  if mf then P("rocks near: %s", table.concat(seen or {}, ",")) end
  if prop and prop.n then prop.name = prop.n.name; local bn = body(); prop.rel = vec3(prop.n.x - bn.x, prop.n.y - bn.y, prop.n.z - bn.z) end
  P("prop %s", prop and string.format("%s at %.1f m", prop.name, prop.d) or "none")

  local function fp_set(id)
    cam.setFreecam(false)
    cam.firstPerson = true
    cam.face(f0.x, f0.y, f0.z, -0.12)
    hold(1.5)
    shot("fp_" .. id .. "_idle")
    hold(0.4)
    -- fire at the ground ahead
    cam.face(f0.x, f0.y, f0.z, -0.55)
    tb.sim = { btn = { [0] = true } }
    local t = time + params.firesecs
    while time < t do tb.sim.btn = { [0] = true }; yield() end
    shot("fp_" .. id .. "_fire")
    hold(0.1)
    tb.sim = { btn = { [0] = false } }
    P("fp %s fired: heat %.2f inUse %s", id, tb.heat or -1, tostring(tb.inUse))
    hold(0.6)
  end
  local function tp_tool()
    for _, nm in ipairs({ "ToolGravGun", "ToolLaser" }) do
      for _, n in ipairs(findAll(nm) or {}) do if n.valid and n.visible then return n end end
    end
  end
  local function tp_cam(side, fwd, upm)
    -- the free camera beside the tool in the crew's hands, looking at it:
    -- `fwd` along the barrel, `side` to the crew's right, `upm` up
    local a, bn = crew(), body()
    local uu = up_at()
    local tn = tp_tool()
    local tgt, fw
    if tn then
      local o = tn:toWorld(vec3(0, 0, 0))
      tgt = o
      fw = (tn:toWorld(vec3(0, 0, -1)) - o):flatten(uu):normalized()
    else
      tgt = vec3(a.x, a.y, a.z) + uu * 1.1
      fw = f0
    end
    local rt = fw:cross(uu):normalized()
    local pos = tgt + rt * side + fw * fwd + uu * upm
    cam.setFreecam(true)
    local fc = cam.freecamState()
    fc.body = b.name
    fc.rel = pos - vec3(bn.x, bn.y, bn.z)
    local d = tgt - pos
    local h = d:flatten(uu)
    fc.ref = h:normalized()
    fc.pitch = math.atan2(d:dot(uu), h:length())
  end
  local function tp_set(id)
    cam.firstPerson = false
    hold(0.5)
    for _, v in ipairs({ { "idle", 1.4, 1.3, 0.35 }, { "close", 0.42, 0.30, 0.12 }, { "left", -1.1, 1.2, 0.3 } }) do
      for _ = 1, 20 do tp_cam(v[2], v[3], v[4]); yield() end
      shot("tp_" .. id .. "_" .. v[1])
      for _ = 1, 4 do tp_cam(v[2], v[3], v[4]); yield() end
    end
    -- fire: the aim along the crew's heading, down at the ground 3 m out
    local t = time + params.firesecs
    while time < t do
      local a = crew()
      local uu = up_at()
      local e = vec3(a.x, a.y, a.z) + uu * 1.5
      local gpt = vec3(a.x, a.y, a.z) + f0 * 3.0 - uu * 0.2
      local dd = gpt - e
      tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, dd.x, dd.y, dd.z } }
      tp_cam(1.5, 1.1, 0.4)
      yield()
    end
    shot("tp_" .. id .. "_fire")
    hold(0.1)
    tb.sim = { btn = { [0] = false } }
    hold(0.6)
    cam.setFreecam(false)
  end

  -- face the heading, the crew turned to it
  cam.face(f0.x, f0.y, f0.z, -0.1)
  hold(1.0)
  for _, id in ipairs({ "gravgun", "laser" }) do
    equip(id)
    fp_set(id)
    tp_set(id)
  end
  -- the gravity gun holding a prop
  if prop then
    equip("gravgun")
    local a = crew()
    local uu = up_at()
    local bn = body()
    local prel = prop.rel
    local function ppos()
      if prop.n and prop.n.valid then return vec3(prop.n.x, prop.n.y, prop.n.z) end
      local b2 = body()
      return vec3(b2.x, b2.y, b2.z) + prel
    end
    local p0 = ppos()
    local d = (p0 - vec3(a.x, a.y, a.z)):flatten(uu):normalized()
    local srel = prel - d * 3.5 + uu * 0.8
    for _ = 1, 30 do
      local bb = body()
      a = crew()
      a.x, a.y, a.z = bb.x + srel.x, bb.y + srel.y, bb.z + srel.z
      a.vx, a.vy, a.vz = 0, 0, 0
      yield()
    end
    hold(1.0)
    cam.firstPerson = true
    cam.face(d.x, d.y, d.z, -0.2)
    hold(0.6)
    local t = time + 3.0
    while time < t do
      local aa, bb = crew(), body()
      local e = vec3(aa.x, aa.y, aa.z) + uu * 1.5
      local dd = ppos() + uu * 0.1 - e
      tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, dd.x, dd.y, dd.z } }
      yield()
    end
    P("holding %s", tostring(tb.holding and tb.holding.name))
    shot("fp_gravgun_hold")
    hold(0.2)
    cam.firstPerson = false
    for _ = 1, 30 do tb.sim = { btn = { [0] = true } }; tp_cam(1.5, 1.1, 0.4); yield() end
    shot("tp_gravgun_hold")
    hold(0.2)
    tb.sim = { btn = { [0] = true }, pressed = { r = true } }
    hold(0.08)
    shot("tp_gravgun_punt")
    tb.sim = { btn = { [0] = false } }
    hold(0.3)
    cam.setFreecam(false)
  end
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
