-- LOOKPROBE: what the ground looks like from a free camera over the base, on a
-- copy of the player's save (tools/perf/look.sh). Pictures at intervals while
-- the world streams, with the numbers that decide what is drawn: the home
-- body's radius and occluder radius, the engine's chunk counts, the fog.
--
-- params: alt (m over the astronaut), pitch (deg), weather (1 = rain),
--   secs (how long to watch), every (s between pictures), occl (-1 = leave
--   the save's occluder radius; otherwise set it to this many metres, 0 = off),
--   head (camera heading, quarter turns), quit.
defaults = { alt = 75, pitch = -12, weather = 0, secs = 30, every = 5, occl = -1, head = 3, quit = 1, untint = 0, gfx = 0, fog = -1, starmark = 0, off = 0, seq = 0, camr = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("LP %7.2f " .. fmt, W() - W0, ...)) end
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
  local ok, err = pcall(camera.capture, { w = 1280, h = 702, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://look/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function diag(tag)
  local b = space.body(save.get("base.body"))
  local cx, cy, cz = camera.screenToRay(640, 351)
  local bn = find(b.name)
  local cb = bn and bn:getcomponent("CelestialBody")
  local c = perf.counts and perf.counts() or {}
  P("DIAG %s cam over R %.1f | R %.1f bodyRadius %s occluderRadius %s | busy %s chunks %s fieldChunks %s standIns %s",
    tag, len(cx - b.x, cy - b.y, cz - b.z) - b.radius, b.radius, tostring(cb and cb.bodyRadius),
    tostring(cb and cb.occluderRadius), tostring(terrain.busy and terrain.busy()), tostring(c.chunks),
    tostring(c.fieldChunks), tostring(c.fieldStandIns))
  if tag == "t0" or tag == "t2" then
    for _, sp in ipairs({ { 640, 600 }, { 300, 600 }, { 640, 420 }, { 100, 300 } }) do
      local ox, oy, oz, dx, dy, dz = camera.screenToRay(sp[1], sp[2])
      local h1 = raycast(ox, oy, oz, dx, dy, dz, 3000)
      local h2, why = terrain.raycast(vec3(ox, oy, oz), vec3(dx, dy, dz), 3000)
      P("RAY px %d,%d | collider %s r %s node %s | field %s r %s exact %s ready %s %s",
        sp[1], sp[2], h1 and string.format("%.1f", h1.distance) or "nil",
        h1 and string.format("%.1f", len(h1.x - b.x, h1.y - b.y, h1.z - b.z)) or "-", tostring(h1 and h1.node and h1.node.name),
        h2 and string.format("%.1f", h2.distance) or "nil",
        h2 and string.format("%.1f", len(h2.pos.x - b.x, h2.pos.y - b.y, h2.pos.z - b.z)) or "-",
        tostring(h2 and h2.exact), tostring(h2 and terrain.ready(h2.pos.x, h2.pos.y, h2.pos.z)), tostring(why))
    end
    local ks = {}
    for k, v in pairs(c) do ks[#ks + 1] = k .. "=" .. tostring(v) end
    table.sort(ks)
    P("DIAG   counts %s", table.concat(ks, " "))
    local okA, an = pcall(terrain.lodAnchor)
    P("DIAG   lodAnchor %s | body node visible %s", tostring(okA and an), tostring(bn and bn.visible))
    -- The engine draws EVERY terrain with one material: the first terrain
    -- node it finds that carries one (terrain_material). Which bodies do?
    for _, sb in ipairs(space.bodies()) do
      local n = find(sb.name)
      local okm, m = pcall(function() return n and n:material() end)
      if okm and m then
        local c = m.color or {}
        P("DIAG   MATERIAL on body %s: unlit %s color %.2f %.2f %.2f emissiveStrength %s", sb.name, tostring(m.unlit),
          c.r or c[1] or -1, c.g or c[2] or -1, c.b or c[3] or -1, tostring(m.emissiveStrength))
      end
    end
    local fb = findScript("far_bodies")
    if fb and fb.stats then P("DIAG   far_bodies %s", tostring(fb.stats()):sub(1, 300)) end
  end
  local ln = find("Lighting")
  local l = ln and ln:getcomponent("Light")
  local at = findScript("atmosphere")
  if l then
    P("DIAG   fog %s vol %s rgb %.2f %.2f %.2f start %.0f end %.0f | sun %.2f gfx %s", tostring(l.fog), tostring(l.fogVolumetric),
      l.fogColorR or -1, l.fogColorG or -1, l.fogColorB or -1, l.fogStart or -1, l.fogEnd or -1,
      at and at.sun_now or -1, tostring(findScript("graphics") and findScript("graphics").level()))
  end
end

local function main()
  NODE.persistent = true
  save.slot("slot1")
  P("usersave slot1 seed %s base %s", tostring(save.get("g_seed")), tostring(save.get("base.body")))
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 200)
  P("ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force((params.weather or 0) > 0 and "rain" or "clear") end
  local b = space.body(save.get("base.body"))
  local bn = find(b.name)
  local cb = bn and bn:getcomponent("CelestialBody")
  if params.occl >= 0 and cb then
    P("occluderRadius %s -> %s", tostring(cb.occluderRadius), tostring(params.occl))
    cb.occluderRadius = params.occl
  end
  local cam = findScript("planet_camera")
  cam.setFreecam(true)
  hold(0.2)
  local fc = cam.freecamState()
  local a = find("Astronaut")
  local rx, ry, rz = a.x - b.x, a.y - b.y, a.z - b.z
  local r = len(rx, ry, rz)
  local up = vec3(rx / r, ry / r, rz / r)
  if params.off ~= 0 then
    -- `off` metres along the ground from the astronaut, away from the base
    local side = up:cross(vec3(0, 0, 1)):normalized()
    local ang = params.off / r
    up = (up * math.cos(ang) + side * math.sin(ang)):normalized()
  end
  -- the ground under the astronaut (who may be indoors: the VAB interior sits
  -- below the surface), found from above
  local top = vec3(b.x, b.y, b.z) + up * (b.radius + 300)
  local hit = terrain.raycast(top, up * -1, 600)
  local gr = hit and len(hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z) or r
  P("astronaut r %.1f ground r %.1f (R %.1f, hit %s)", r, gr, b.radius, tostring(hit ~= nil))
  local gp = vec3(b.x, b.y, b.z) + up * (gr + 0.5)
  local wa = water.at and water.at(gp)
  P("water at the ground: %s depth %s node %s | volumes %d", tostring(wa ~= nil), tostring(wa and wa.depth),
    tostring(wa and wa.node and wa.node.name), #(water.volumes and water.volumes() or {}))
  fc.body = b.name
  -- camr: an absolute radius for the camera (the same spot run to run, while
  -- the ground under the astronaut may still be streaming in)
  fc.rel = up * (params.camr > 0 and params.camr or (gr + params.alt))
  fc.pitch = math.rad(params.pitch)
  fc.ref = up:cross(vec3(1, 0, 0)):normalized():rotatedAround(up, params.head * math.pi / 2)
  local t0 = W()
  local i = 0
  while W() - t0 < params.secs do
    hold(i == 0 and 1.0 or params.every)
    diag("t" .. i)
    shot(string.format("t%02d", i))
    if i == 1 and params.untint > 0 then
      local okt, et = pcall(bn.setTint, bn)
      P("untint planet node: %s %s", tostring(okt), tostring(et))
      local tb = findScript("tool_belt")
      P("tool_belt grab %s", tostring(tb and tb.grab))
    end
    if i == 1 and params.starmark > 0 then
      -- Paint every body that carries a material magenta: if the ground turns
      -- magenta, the terrain is drawn in another node's material.
      for _, sb in ipairs(space.bodies()) do
        local n = find(sb.name)
        local okm, m = pcall(function() return n and n:material() end)
        if okm and m then m.color = { 1, 0, 1 }; P("starmark %s", sb.name) end
      end
    end
    if i == 1 and params.gfx > 0 then
      local gx = findScript("graphics")
      local name = gx.LEVELS[params.gfx]
      gx.set(name)
      P("graphics -> %s", name)
    end
    if i == 1 and params.fog >= 0 then
      local at = findScript("atmosphere")
      at.params.on = params.fog > 0
      local l = find("Lighting"):getcomponent("Light")
      l.fog = params.fog > 0
      P("fog -> %s", tostring(l.fog))
    end
    i = i + 1
  end
  local at = findScript("atmosphere")
  if params.seq == 3 then
    -- the air's own look off (the engine's atmosphere over every surface)
    shot("a_before")
    hold(0.5)
    at.params.on = false
    local d0 = cb.atmoDensity
    bn:setCelestial { atmoDensity = 0 }
    hold(1.5)
    P("atmoDensity %s -> %s", tostring(d0), tostring(cb.atmoDensity))
    shot("a_air0")
    hold(1.5)
    bn:setCelestial { atmoDensity = d0 }
    at.params.on = true
    hold(1.5)
    shot("a_back")
  elseif params.seq == 2 then
    shot("p_before")
    hold(1.0)
    P("planetmat red %s", tostring(pcall(bn.setMaterial, bn, { color = { 1, 0.35, 0.35 } })))
    hold(1.5)
    shot("p_red")
    hold(4)
    shot("p_red5")
  elseif params.seq > 0 then
    local F = { "atmoDensity", "atmoHeight", "atmoColorR", "atmoColorG", "atmoColorB", "clouds", "cloudDarkness",
      "cloudHeight", "cloudColorR", "luminosity", "bodyRadius" }
    local function dumpcb(tag)
      local t = {}
      for _, k in ipairs(F) do t[#t + 1] = k .. "=" .. tostring(cb[k]) end
      P("CEL %s %s", tag, table.concat(t, " "))
    end
    dumpcb("before")
    local at = findScript("atmosphere")
    local L = find("Lighting"):getcomponent("Light")
    local saved = {}
    local function keep(k) saved[k] = cb[k] end
    local fl = findTagged and findTagged("farlod") or {}
    for _, n in ipairs(fl) do
      local wp = n.worldPos or n
      P("FARLOD %s visible %s scale %s dist-from-home-centre %.1f", n.name, tostring(n.visible), tostring(n.scale),
        len(wp.x - b.x, wp.y - b.y, wp.z - b.z))
    end
    -- every point light under the scene's roots we can reach
    local plights = {}
    local seen = {}
    local function walk(n, depth)
      if not n or seen[n.name .. tostring(n)] or depth > 12 then return end
      seen[n.name .. tostring(n)] = true
      local okp, pl = pcall(function() return n:getcomponent("PointLight") end)
      if okp and pl then plights[#plights + 1] = { n = n, pl = pl } end
      local c = n.children
      if type(c) == "function" then local okc, r = pcall(c, n); c = okc and r or {} end
      for _, k in ipairs(c or {}) do walk(k, depth + 1) end
    end
    local function root(n) while n and n.parent and n.parent.valid ~= false do n = n.parent end return n end
    for _, nm in ipairs({ b.name, "Astronaut", "Lighting", "Camera" }) do walk(root(find(nm)), 0) end
    for _, e in ipairs(plights) do
      local wp = e.n.worldPos or e.n
      P("PLIGHT %s range %s intensity %s color %s %s %s dist %.0f", e.n.name, tostring(e.pl.range), tostring(e.pl.intensity),
        tostring(e.pl.colorR or e.pl.r), tostring(e.pl.colorG or e.pl.g), tostring(e.pl.colorB or e.pl.b),
        len(wp.x - b.x, wp.y - b.y, wp.z - b.z))
    end
    -- every node with a Material of its own, by name (the engine shades ALL
    -- terrain with the material of one terrain node that has one)
    local agg = {}
    local unlitnodes = {}
    local seen2 = {}
    local function walk2(n, depth)
      if not n or depth > 14 then return end
      local key = tostring(n)
      if seen2[key] then return end
      seen2[key] = true
      local okm, m = pcall(function() return n:material() end)
      if okm and m then
        local c = m.color or {}
        local cel = n:getcomponent("CelestialBody") ~= nil
        local k = string.format("%s unlit=%s color=%.2f,%.2f,%.2f es=%s cel=%s", n.name, tostring(m.unlit),
          c.r or c[1] or -1, c.g or c[2] or -1, c.b or c[3] or -1, tostring(m.emissiveStrength), tostring(cel))
        agg[k] = (agg[k] or 0) + 1
        if m.unlit then unlitnodes[#unlitnodes + 1] = { n = n, m = m } end
      end
      local c = n.children
      if type(c) == "function" then local okc, r = pcall(c, n); c = okc and r or {} end
      for _, kd in ipairs(c or {}) do walk2(kd, depth + 1) end
    end
    local roots = {}
    local names = { b.name, "Astronaut", "Lighting", "Camera", "Look Probe" }
    for _, sb in ipairs(space.bodies()) do names[#names + 1] = sb.name end
    for _, nm in ipairs(names) do
      for _, nd in ipairs(findAll(nm) or {}) do
        local r0 = root(nd); if r0 then roots[tostring(r0)] = r0 end
      end
    end
    for _, r0 in pairs(roots) do P("ROOT %s", r0.name); walk2(r0, 0) end
    local ks = {}
    for k, v in pairs(agg) do ks[#ks + 1] = string.format("%4d %s", v, k) end
    table.sort(ks)
    for _, k in ipairs(ks) do P("MATNODE %s", k) end
    local fvis = {}
    local toggles = {
      { "sun0", function()
          at.params.on = false
          local h = save.get("system.home")
          local st = h and h.star and find(h.star)
          local sc = st and st:getcomponent("CelestialBody")
          saved.star = st
          saved.sc = sc and { sc.starColorR, sc.starColorG, sc.starColorB }
          saved.amb = { L.ambientR, L.ambientG, L.ambientB }
          saved.I = L.intensity
          if st then st:setCelestial { starColor = { 0, 0, 0 } } end
          L.ambientR, L.ambientG, L.ambientB = 0, 0, 0
          L.intensity = 0
          P("sun0 star %s was %s", tostring(st and st.name), saved.sc and table.concat(saved.sc, ",") or "?")
        end, function()
          if saved.star and saved.sc then saved.star:setCelestial { starColor = saved.sc } end
          L.ambientR, L.ambientG, L.ambientB = saved.amb[1], saved.amb[2], saved.amb[3]
          L.intensity = saved.I
          at.params.on = true
        end },
      { "starmark", function()
          for _, e in ipairs(unlitnodes) do
            if e.n:getcomponent("CelestialBody") then e.m.color = { 1, 0, 1 }; e.m.emissive = { 1, 0, 1 }; P("starmark %s", e.n.name) end
          end
        end, function() end },
      { "unlitmark", function()
          for _, e in ipairs(unlitnodes) do e.m.color = { 1, 0, 1 }; e.m.emissive = { 1, 0, 1 } end
          P("unlitmark %d nodes", #unlitnodes)
        end, function() end },
      { "planetmat", function() P("planetmat %s", tostring(pcall(bn.setMaterial, bn, { color = { 1, 1, 1 } }))) end, function() end },
      { "plights0", function() for _, e in ipairs(plights) do e.r0 = e.pl.range; e.i0 = e.pl.intensity; e.pl.range = 0.1; e.pl.intensity = 0 end end,
        function() for _, e in ipairs(plights) do e.pl.range = e.r0; e.pl.intensity = e.i0 end end },
      { "farlod0", function() for i, n in ipairs(fl) do fvis[i] = n.visible; n.visible = false end end,
        function() for i, n in ipairs(fl) do n.visible = fvis[i] end end },
      { "farbodies0", function() findScript("far_bodies").setActive(false) end, function() findScript("far_bodies").setActive(true) end },
      { "body0", function() bn.visible = false end, function() bn.visible = true end },
      { "atmo0", function() keep("atmoDensity"); cb.atmoDensity = 0 end, function() cb.atmoDensity = saved.atmoDensity end },
      { "clouds0", function() keep("clouds"); cb.clouds = 0 end, function() cb.clouds = saved.clouds end },
      { "atmoscript0", function() at.params.on = false end, function() at.params.on = true end },
      { "key0", function() at.params.on = false; saved.I = L.intensity; L.intensity = 0 end,
        function() L.intensity = saved.I; at.params.on = true end },
    }
    for _, tg in ipairs(toggles) do
      tg[2]()
      hold(1.5)
      dumpcb(tg[1])
      diag(tg[1])
      shot("s_" .. tg[1])
      hold(0.3)
      tg[3]()
      hold(1.0)
    end
    shot("s_after")
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
