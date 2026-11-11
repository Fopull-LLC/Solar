-- ── cave probe (tools/perf/caveprobe.sh): cave kinds and dressing (worlds W4) ─
-- Spliced into a copy of perfbench.lua before its main. One table (perfbench's
-- main chunk is near Lua's 200-locals ceiling).
--   cave   on the save's home world: find a NATURAL cave near the base (columns
--          of terrain.query under the ground, made exact with terrain.prepare),
--          stand in it, and report the kind cave_field reads, its enclosure,
--          height, depth, air and hazards; the formations and marks it lays,
--          the cost of cave_field + underground per frame and the rays, the
--          terrain edits (none: no paint, no pinned chunks); pictures with the
--          helmet lamps and with the torch, a flare thrown, the HUD's Lamp chip.
--          params: sweep=1 also dresses the same cave as each of the eight
--          kinds in turn (cave_field.forceKind) and photographs each;
--          carve=1 carves a chamber when no natural cave is found.
-- `CV` lines; pictures in save/user/caveshots/.
local CV = { tag = "cave", shots = 0 }

function CV.shot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui == true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://caveshots/" .. CV.tag .. "_" .. nm .. ".png", bytes); P("CV SHOT %s_%s", CV.tag, nm)
    else P("CV SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("CV capture error %s", tostring(err)); return end
  wait_for(function() return done end, 6, "shot " .. nm)
  CV.shots = CV.shots + 1
end

function CV.level()
  local gx = findScript("graphics")
  local lv = tostring(params.gfx or "High")
  if gx and gx.set then gx.set(lv) end
end

function CV.pack()
  local C = findScript("crew")
  local id = C and C.activeId and C.activeId()
  return id and ("crew:" .. id) or "astro"
end
function CV.give()
  local inv = findScript("inventory")
  local pk = CV.pack()
  for id, n in pairs({ flashlight = 1, cell = 2, flare = 4 }) do
    local have = inv.itemCount(pk, id) or 0
    if have < n then inv.addItem(pk, id, n - have, { force = true }) end
  end
end
function CV.torch(on)
  local fl = findScript("flashlight")
  if fl and fl.setOn then local ok, why = fl.setOn(on); P("CV torch %s: %s %s", tostring(on), tostring(ok), tostring(why)) end
end

-- A natural cave near the base: columns 90-300 m out, each made exact
-- (terrain.prepare) and walked down in 2.5 m steps from 6 m under the ground
-- to the cave zone's floor; a point in open air with rock above and below
-- and room to stand (4-40 m roof to floor). → { floor (body-local), height,
-- depth, dir (unit, body frame), t (a level direction) } or nil.
function CV.find()
  local b = home()
  local u, t1, t2, R = base_frame()
  local cf = findScript("cave_field")
  local wi = cf and cf.worldInfo and cf.worldInfo(b.name)
  local cd = (wi and wi.cdepth) or 60
  P("CV searching for a cave: R %.0f, cave zone %.0f m deep", R, cd)
  local tried = 0
  for _, d in ipairs({ 110, 160, 210, 260, 320 }) do
    for k = 0, 7 do
      local ang = k * math.pi / 4 + d * 0.01
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      b = home()
      local g = ground_r(b, dir.x, dir.y, dir.z, R + 250)
      if g then
        tried = tried + 1
        local mid = { x = b.x + dir.x * (g - cd * 0.5), y = b.y + dir.y * (g - cd * 0.5), z = b.z + dir.z * (g - cd * 0.5) }
        if terrain.prepare then pcall(terrain.prepare, mid.x, mid.y, mid.z, cd * 0.6 + 10) end
        wait_for(function()
          local bb = home()
          return terrain.ready(bb.x + dir.x * (g - cd * 0.5), bb.y + dir.y * (g - cd * 0.5), bb.z + dir.z * (g - cd * 0.5), cd * 0.5)
        end, 10, "column ready")
        b = home()
        for depth = 6, cd, 2.5 do
          local px, py, pz = b.x + dir.x * (g - depth), b.y + dir.y * (g - depth), b.z + dir.z * (g - depth)
          local q = terrain.query(px, py, pz)
          if q and q > 1.4 then
            local hu = terrain.raycast(vec3(px, py, pz), vec3(dir.x, dir.y, dir.z), 40)
            local hd = terrain.raycast(vec3(px, py, pz), vec3(-dir.x, -dir.y, -dir.z), 40)
            if hu and hd and hu.distance and hd.distance then
              local h = hu.distance + hd.distance
              if h >= 4 and h <= 40 and hu.distance < depth - 3 then
                local f = hd.pos
                P("CV cave found after %d columns: %d m out, %.0f m down, roof-to-floor %.1f m", tried, d, depth, h)
                local tt = unit(sub(t, scl(dir, dot(t, dir))))
                return { floor = { x = f.x - b.x, y = f.y - b.y, z = f.z - b.z }, height = h, depth = depth, dir = dir, t = tt,
                         top = { x = dir.x * g, y = dir.y * g, z = dir.z * g } }
              end
            end
          end
        end
      end
      if tried >= (params.columns or 24) then break end
    end
    if tried >= (params.columns or 24) then break end
  end
  P("CV no natural cave in %d columns", tried)
  return nil
end

-- Carve a chamber (only with carve=1, when no natural cave is found): gritprobe's tunnel.
function CV.carve()
  local b = home()
  local u, t1, t2, R = base_frame()
  local dir = dir_at(u, t1, 150, R)
  local g = ground_r(b, dir.x, dir.y, dir.z, R + 250)
  local C = { x = b.x + dir.x * (g - 14), y = b.y + dir.y * (g - 14), z = b.z + dir.z * (g - 14) }
  for _, o in ipairs({ { 0, 0, 0 }, { 3, 0, 0 }, { -3, 0, 0 }, { 0, 0, 3 }, { 0, 0, -3 }, { 0, 2.5, 0 } }) do
    local s = unit(cross(t1, dir))
    terrain.dig(C.x + t1.x * o[1] + s.x * o[3] + dir.x * o[2], C.y + t1.y * o[1] + s.y * o[3] + dir.y * o[2],
      C.z + t1.z * o[1] + s.z * o[3] + dir.z * o[2], 4.5, 1.0, { hardness = 0.8, falloff = "smooth" })
  end
  wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 30, "the carve")
  b = home()
  local hd = terrain.raycast(vec3(C.x, C.y, C.z), vec3(-dir.x, -dir.y, -dir.z), 20)
  local f = hd and hd.pos or C
  P("CV CARVED a chamber 14 m down (no natural cave)")
  return { floor = { x = f.x - b.x, y = f.y - b.y, z = f.z - b.z }, height = 8, depth = 14, dir = dir, t = t1, carved = true }
end

function CV.stand(cv)
  local b = home()
  local a = astro()
  local p = { x = b.x + cv.floor.x, y = b.y + cv.floor.y, z = b.z + cv.floor.z }
  a.x, a.y, a.z = p.x + cv.dir.x * 1.1, p.y + cv.dir.y * 1.1, p.z + cv.dir.z * 1.1
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.0) end
end

function CV.state(tag)
  local cf = findScript("cave_field")
  local ug = findScript("underground")
  local l = find("Lighting"); l = l and l:getcomponent("Light")
  local air = {}
  for k, v in pairs(cf.air or {}) do air[#air + 1] = string.format("%s %.4g", k, v) end
  local hz = {}
  for k, v in pairs(cf.hazard or {}) do hz[#hz + 1] = k .. " " .. tostring(v) end
  table.sort(air); table.sort(hz)
  P("CV STATE %s: kind %s (%s) enclosure %.2f height %s depth %s | air {%s} | hazard {%s} | nodes %d records %d decals %d cells %d | ambient %.4f %.4f %.4f fog %s end %s | ug kind %s floor %s",
    tag, tostring(cf.caveKind), tostring(cf.label), cf.enclosure or -1, cf.height and string.format("%.1f", cf.height) or "-",
    cf.depth and string.format("%.1f", cf.depth) or "-", table.concat(air, ", "), table.concat(hz, ", "),
    cf.stats.nodes or -1, cf.stats.records or -1, cf.stats.decals or -1, cf.stats.cells or -1,
    l and l.ambientR or -1, l and l.ambientG or -1, l and l.ambientB or -1, tostring(l and l.fog), tostring(l and l.fogEnd),
    tostring(ug and ug.kindNow), ug and ug.ambK and string.format("%.3f", ug.ambK.floor or -1) or "-")
  -- what the view's centre (the torch spot) lands on: the slot and its layer
  local pc = findScript("planet_camera")
  local a = astro()
  local bb = home()
  if pc and a and bb and pc.fwd_x then
    local u = unit(sub(a, bb))
    local e = vec3(a.x + u.x * 1.6, a.y + u.y * 1.6, a.z + u.z * 1.6)
    local h = terrain.raycast(e, vec3(pc.fwd_x, pc.fwd_y, pc.fwd_z), 60)
    if h and h.pos then
      local slot = terrain.slotAt and terrain.slotAt(h.pos.x, h.pos.y, h.pos.z)
      local pal = save.get("system.palette")
      local layer = pal and pal.layer and slot and pal.layer[slot]
      local G = findScript("geology")
      P("CV SPOT %s: %.1f m, slot %s layer %s (%s)", tag, h.distance or -1, tostring(slot), tostring(layer),
        tostring(G and G.nameOf and layer and G.nameOf(layer)))
    end
  end
  local bl = {}
  for _, e in ipairs((ug and ug.bedLog) or {}) do bl[#bl + 1] = string.format("%s %.2f", e.clip:match("[^/]+$"), e.v) end
  if #bl > 0 then P("CV BEDS %s: %s", tag, table.concat(bl, ", ")) end
  local hl = ug and ug.hazeLog
  if hl then P("CV HAZE %s: w %.2f rgb %.3f %.3f %.3f dens %s far %s vol %s", tag, hl.w, hl.r, hl.g, hl.b, tostring(hl.dens), tostring(hl.far), tostring(hl.vol)) end
end

function CV.cost(tag, secs)
  local c0 = perf.counts() or {}
  sc_begin(tag)
  local t0 = time
  local rays, raym, n = 0, 0, 0
  while time - t0 < (secs or 5) do
    yield()
    local c = perf.counts() or {}
    rays, raym, n = rays + (c.rays or 0), raym + (c.rayMs or 0), n + 1
  end
  local r = RECS[tag]
  sc_end(tag)
  local c = perf.counts() or {}
  local function ms(k) return (r and r.s[k] or 0) / math.max(r and #r.dts or 1, 1) end
  local cf = findScript("cave_field")
  P("CV COST %s: cave_field %.3f underground %.3f cave_flares %.3f ms/frame (cave_field's own clock %.3f ms) | script rays %.1f/frame %.3f ms | nodes %d | fieldEdited %s -> %s | lights %s dropped %s | decals %s | gpu %.2f ms",
    tag, ms("cave_field"), ms("underground"), ms("cave_flares"), cf.stats.ms or -1, rays / math.max(n, 1), raym / math.max(n, 1),
    cf.stats.nodes or -1, tostring(c0.fieldEdited), tostring(c.fieldEdited), tostring(c.lights), tostring(c.lightsDropped),
    tostring(c.decals), (r and r.gn > 0) and r.gpu / r.gn or -1)
end

function CV.look(t, up, pitch, nm, ui)
  local pc = findScript("planet_camera")
  if pc.face then pc.face(t.x, t.y, t.z, pitch) end
  wait(1.4)
  CV.shot(nm, ui)
end

-- THE TINT LAB (W3's open question: a tint on a rock prop barely shows):
-- four stalagmites 3 m ahead, all tinted pure red; B with reflectivity 0
-- (set a beat after the model lands), C with its ambient share 0, D both.
-- Shot with the lamps, with the torch, and (surface=1) the same on the
-- ground above in daylight.
function CV.tintlab(cv, tag, t, s, up)
  local b = home()
  local a = astro()
  local planet = find(b.name)
  local lx, ly, lz = a.x - b.x, a.y - b.y, a.z - b.z
  local nodes = {}
  for i = 1, 4 do
    local off = (i - 2.5) * 1.1
    local px = lx + t.x * 3.0 + s.x * off - up.x * 0.9
    local py = ly + t.y * 3.0 + s.y * off - up.y * 0.9
    local pz = lz + t.z * 3.0 + s.z * off - up.z * 0.9
    createNode("Tint Lab " .. i, planet, function(n)
      n.model = "models/cave/stalagmite_l0.gltf"
      n.x, n.y, n.z = px, py, pz
      n.scale_x, n.scale_y, n.scale_z = 1.0, 1.0, 1.0
      n:setUp(vec3(up.x, up.y, up.z), vec3(t.x, t.y, t.z))
      local tt = { color = { 1.3, 0.05, 0.05 } }
      if i == 3 or i == 4 then tt.ambient = 0 end
      n:setTint(tt)
      nodes[i] = n
    end)
  end
  wait(1.0)
  for i = 2, 4, 2 do if nodes[i] and nodes[i].valid then pcall(nodes[i].setMaterial, nodes[i], { reflectivity = 0 }) end end
  wait(0.8)
  local pc = findScript("planet_camera")
  pc.face(t.x, t.y, t.z, -0.25)
  wait(1.2)
  CV.shot(tag .. "_lamps")
  CV.torch(true); wait(0.8)
  CV.shot(tag .. "_torch")
  CV.torch(false)
  for _, n in pairs(nodes) do if n.valid then n:destroy() end end
  P("CV TINTLAB %s: A red | B red, reflectivity 0 | C red, ambient 0 | D both (left to right)", tag)
end

function CV.run()
  wait_ready(90)
  clear_weather()
  CV.level()
  CV.tag = string.format("s%d", math.floor(params.seed or 0))
  local b = home()
  local wd = save.get("world." .. b.name) or {}
  local f = wd.bio and wd.bio.formation
  P("CV WORLD %s type %s formation %s principal %s matGen %s", b.name, tostring(wd.geo and wd.geo.type), tostring(f and f.id),
    tostring(wd.bio and wd.bio.caves and wd.bio.caves.principal), tostring(save.get("g_matGen")))
  CV.give()
  local cv = CV.find()
  if not cv and (params.carve or 0) > 0 then cv = CV.carve() end
  if not cv then P("CV RESULT no cave"); return end
  CV.stand(cv)
  wait(2)
  CV.stand(cv)
  local pc = findScript("planet_camera")
  pc.firstPerson = true
  -- wait for the ground and the dressing
  wait_for(function() local c = perf.counts() or {}; return (c.meshesPending or 0) < 4 end, 30, "meshes")
  wait(8)
  local cf = findScript("cave_field")
  CV.state("natural")
  local t = cv.t
  local back = { x = -t.x, y = -t.y, z = -t.z }
  local s = unit(cross(t, cv.dir))
  if (params.tintlab or 0) > 0 then
    CV.tintlab(cv, "tintlab_cave", t, s, cv.dir)
    if (params.surface or 0) > 0 and cv.top then
      local bb = home()
      local a = astro()
      a.x, a.y, a.z = bb.x + cv.top.x + cv.dir.x * 1.2, bb.y + cv.top.y + cv.dir.y * 1.2, bb.z + cv.top.z + cv.dir.z * 1.2
      a.vx, a.vy, a.vz = 0, 0, 0
      wait(4)
      CV.tintlab(cv, "tintlab_surface", t, s, cv.dir)
      CV.stand(cv); wait(3); CV.stand(cv); wait(3)
    end
  end
  CV.cost("cost_lamps", 5)
  CV.look(t, cv.dir, -0.05, "lamps_fwd")
  CV.look(s, cv.dir, 0.35, "lamps_side_up")
  CV.torch(true)
  wait(0.6)
  CV.look(t, cv.dir, -0.1, "torch_fwd")
  CV.look(back, cv.dir, 0.15, "torch_back")
  CV.look(s, cv.dir, 0.55, "torch_roof")
  CV.cost("cost_torch", 5)
  CV.state("torch")
  -- walk a few metres through it (the dressing follows, the cells are saved)
  key_down("w"); wait(4); key_up("w")
  wait(3)
  CV.state("walked")
  CV.cost("cost_walk", 4)
  -- flares: two thrown ahead, the torch off
  CV.torch(false)
  local fla = findScript("cave_flares")
  if fla then
    fla.sim = { throw = true }; wait(1.5)
    pc.face(s.x, s.y, s.z, -0.05); wait(0.3)
    fla.sim = { throw = true }; wait(3)
    local l = fla.list and fla.list() or {}
    P("CV FLARES lit %s thrown %s, first landed %s", tostring(fla.lit), tostring(fla.thrown), tostring(l[1] and l[1].landed))
    CV.look(t, cv.dir, -0.15, "flares")
    CV.cost("cost_flares", 3)
  end
  CV.look(t, cv.dir, -0.1, "hud", true)
  -- the helmet lamps on the cell, then the cell flat: the emergency glow
  local fl = findScript("flashlight")
  local su = findScript("suit")
  wait(2)
  P("CV LAMPS helmet beam %.2f emergency %s cell %.1f draw %s minutes %s", su.beamLit or -1, tostring(su.beamEmergency),
    fl.cellLevel() or -1, tostring(fl.drawNow()), tostring(fl.minutesLeft()))
  CV.look(t, cv.dir, -0.1, "helmet", true)
  fl.cellAdd(-100)
  wait(2)
  P("CV LAMPS flat: helmet beam %.2f emergency %s cell %.1f", su.beamLit or -1, tostring(su.beamEmergency), fl.cellLevel() or -1)
  CV.look(t, cv.dir, -0.1, "emergency", true)
  fl.cellAdd(100)
  P("CV RESULT natural kind %s nodes %d decals %d %s", tostring(cf.caveKind), cf.stats.nodes or -1, cf.stats.decals or -1, cv.carved and "CARVED" or "natural")
  -- every kind dressed in this same cave
  if (params.sweep or 0) > 0 then
    CV.torch(true)
    local CKS = findScript("cave_kinds")
    local list = CKS.ORDER
    if type(params.kinds) == "string" and params.kinds ~= "" then
      list = {}
      for k in params.kinds:gmatch("[%w_]+") do list[#list + 1] = k end
    end
    for _, id in ipairs(list) do
      cf.params.forceKind = id
      cf.reset()
      CV.stand(cv)
      wait(7)
      CV.state("kind_" .. id)
      CV.look(t, cv.dir, -0.05, "kind_" .. id .. "_fwd")
      CV.look(s, cv.dir, 0.45, "kind_" .. id .. "_roof")
      CV.cost("cost_kind_" .. id, 3)
    end
    cf.params.forceKind = ""
  end
  pc.firstPerson = false
end
