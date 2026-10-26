-- TOOLSHOTS: the hand tools in the game, on a copy of the player's save
-- (tools/perf/toolshots.sh). First person and third person, idle and firing,
-- the gravity gun on a crate if one is near, and a close-up of each tool in
-- the hands. Pictures to user://toolshots/.
-- mode 1: the ENERGY set (see energy_set): each tool idle and working, first
-- and third person, in daylight and then in shade — under a canopy the probe
-- holds between the crew and the sun (ProbeShade, from toolshots.sh).
-- laseronly / dayonly trim the energy set to the laser, or to daylight (the
-- laser design runs: toolshots.sh VARIANT=…).
-- perfsecs > 0: after each first-person idle shot, the GPU's own time per
-- render pass (perf.gpu) and the draw count, averaged over that many seconds,
-- printed as "TSG PERF" lines (run BEFORE=1 and not, and compare).
defaults = { quit = 1, firesecs = 4.0, mode = 0, shadedist = 2.6, laseronly = 0, dayonly = 0, perfsecs = 0 }

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

-- The shade canopy: kept between the crew and the sun every lateUpdate (the
-- planet moves metres a tick, so it is placed after physics, from the crew).
local shade = { on = false, n = nil, asked = false }
local function sun_dir(a)
  local best
  for _, b in ipairs(space.bodies() or {}) do if not best or (b.mu or 0) > (best.mu or 0) then best = b end end
  if not best then return nil end
  local d = vec3(best.x - a.x, best.y - a.y, best.z - a.z)
  return d:normalized()
end
function lateUpdate(node, dt)
  if not shade.on then
    if shade.n and shade.n.valid then shade.n.visible = false; shade.n.x = shade.n.x + 500 end
    return
  end
  local a = find("Astronaut")
  if not a then return end
  if not (shade.n and shade.n.valid) then
    if not shade.asked then shade.asked = true; spawn("ProbeShade", vec3(a.x, a.y, a.z), function(n) shade.n = n end) end
    return
  end
  local s = sun_dir(a)
  if not s then return end
  local up = vec3(a.up_x or 0, a.up_y or 1, a.up_z or 0)
  local c = vec3(a.x, a.y, a.z) + up * 1.2 + s * params.shadedist
  shade.n.visible = true
  shade.n.x, shade.n.y, shade.n.z = c.x, c.y, c.z
  if shade.n.setUp then shade.n:setUp(s, up:cross(s):normalized()) end
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
  -- the hands are item_hand's: hold(id) puts a tool in them (tool_belt's
  -- key sim is no longer read for that)
  local function equip(id)
    local ih = findScript("item_hand")
    if ih and ih.hold then
      local ok, why = ih.hold(id)
      if not ok then P("hold %s refused: %s", id, tostring(why)) end
    else
      for i, s in ipairs(tb.belt()) do if s.id == id then tb.sim = { pressed = { [tostring(i)] = true } } end end
    end
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
  if params.mode == 1 then
    -- THE ENERGY SET: daylight, then shade; each tool idle and working.
    local tools = params.laseronly > 0 and { "laser" } or { "gravgun", "laser" }
    -- Shade: the shadow side of the nearest base building, where its colliders
    -- shade the first-person view model too (a stacked camera takes only
    -- terrain and collider-proxy shadows); the canopy if no spot is found.
    local function building_shade()
      local a, uu = crew(), up_at()
      local sd = sun_dir(a)
      if not sd then return nil end
      local sf = sd:flatten(uu):normalized()
      local best
      for _, nm in ipairs({ "FacTracking", "FacHangar", "FacCommand", "FacDepot", "FacPower" }) do
        for _, n in ipairs(findAll(nm) or {}) do
          -- facilities ride their planet: their x/y/z are planet-local
          local w = n.valid and n:toWorld(vec3(0, 0, 0))
          local d = w and len(w.x - a.x, w.y - a.y, w.z - a.z)
          if w and (not best or d < best.d) then best = { n = n, d = d, w = w } end
        end
      end
      P("shade: nearest building %s", best and string.format("%s at %.0f m", best.n.name, best.d) or "none")
      if not best then return nil end
      local c = best.w
      for D = 12, 44, 4 do
        local p = c - sf * D + uu * 40
        local g = raycast(p.x, p.y, p.z, -uu.x, -uu.y, -uu.z, 90, a)
        if g then
          local e = vec3(g.x, g.y, g.z) + uu * 1.5
          local blk = raycast(e.x, e.y, e.z, sd.x, sd.y, sd.z, 300, a)
          if blk then
            local bn = body()
            P("shade spot: %.0f m from %s, ground found, sun blocked at %.1f m", D, best.n.name,
              len(blk.x - e.x, blk.y - e.y, blk.z - e.z))
            return vec3(g.x, g.y, g.z) + uu * 1.0 - vec3(bn.x, bn.y, bn.z), -sf
          end
        end
      end
      return nil
    end
    for _, lt in ipairs(params.dayonly > 0 and { "day" } or { "day", "shade" }) do
      if lt == "shade" then
        local rel, look = building_shade()
        if rel then
          for _ = 1, 40 do
            local bn, a = body(), crew()
            a.x, a.y, a.z = bn.x + rel.x, bn.y + rel.y, bn.z + rel.z
            a.vx, a.vy, a.vz = 0, 0, 0
            yield()
          end
          f0 = look
          cam.face(f0.x, f0.y, f0.z, -0.1)
        else
          shade.on = true
        end
      end
      hold(1.0)
      local sd = sun_dir(crew())
      P("light %s sun elevation %.1f deg", lt, sd and math.deg(math.asin(math.max(-1, math.min(1, sd:dot(up_at()))))) or -99)
      for _, id in ipairs(tools) do
        equip(id)
        cam.setFreecam(false)
        cam.firstPerson = true
        cam.face(f0.x, f0.y, f0.z, -0.12)
        hold(1.5)
        shot(lt .. "_fp_" .. id .. "_idle")
        hold(0.3)
        if params.perfsecs > 0 and perf and perf.gpu then
          perf.enable(true)
          hold(0.5)
          local sum, n, draws, fms = {}, 0, 0, 0
          local t = time + params.perfsecs
          while time < t do
            local g = perf.gpu()
            if g and g.passes then
              n = n + 1
              sum.total = (sum.total or 0) + (g.total or 0)
              for _, ps in ipairs(g.passes) do sum[ps.name] = (sum[ps.name] or 0) + ps.ms end
              local c = perf.counts()
              draws = draws + (c.draws or 0)
              fms = fms + (perf.ms("render") or 0)
            end
            yield()
          end
          local parts = {}
          for k, v in pairs(sum) do parts[#parts + 1] = string.format("%s=%.3f", k, v / math.max(n, 1)) end
          table.sort(parts)
          P("PERF %s %s frames %d draws %.1f cpu-render %.3f | %s", lt, id, n, draws / math.max(n, 1),
            fms / math.max(n, 1), table.concat(parts, " "))
          perf.enable(false)
        end
        -- working: the trigger held at the ground ahead (the gun reaching,
        -- the laser heating up)
        cam.face(f0.x, f0.y, f0.z, -0.5)
        local t = time + params.firesecs
        while time < t do tb.sim = { btn = { [0] = true } }; yield() end
        shot(lt .. "_fp_" .. id .. "_work")
        hold(0.1)
        P("%s fp %s: heat %.2f charge %.2f inUse %s", lt, id, tb.heat or -1, tb.charge or -1, tostring(tb.inUse))
        tb.sim = { btn = { [0] = false } }
        cam.firstPerson = false
        hold(0.6)
        for _ = 1, 24 do tp_cam(0.42, 0.30, 0.12); yield() end
        shot(lt .. "_tp_" .. id .. "_idle")
        t = time + params.firesecs
        while time < t do
          local a = crew()
          local uu = up_at()
          local e = vec3(a.x, a.y, a.z) + uu * 1.5
          local gpt = vec3(a.x, a.y, a.z) + f0 * 3.0 - uu * 0.2
          local dd = gpt - e
          tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, dd.x, dd.y, dd.z } }
          tp_cam(0.42, 0.30, 0.12)
          yield()
        end
        shot(lt .. "_tp_" .. id .. "_work")
        -- a second frame a beat later (still firing): a spinning part has turned
        for _ = 1, 3 do
          local a = crew()
          local uu = up_at()
          local e = vec3(a.x, a.y, a.z) + uu * 1.5
          local dd = vec3(a.x, a.y, a.z) + f0 * 3.0 - uu * 0.2 - e
          tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, dd.x, dd.y, dd.z } }
          tp_cam(0.42, 0.30, 0.12)
          yield()
        end
        shot(lt .. "_tp_" .. id .. "_work2")
        hold(0.1)
        tb.sim = { btn = { [0] = false } }
        cam.setFreecam(false)
        hold(1.5)
      end
    end
    shade.on = false
    wait_for(function() return pending <= 0 end, 20)
    P("DONE")
    if params.quit > 0 then app.quit() end
    return
  end
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
