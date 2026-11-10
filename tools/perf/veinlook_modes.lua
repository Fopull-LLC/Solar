-- ── vein look probe (tools/perf/veinlook.sh): every ore as its mineral (worlds W3) ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua,
-- verifyprobe_modes.lua, fellprobe_modes.lua and mineprobe_modes.lua (V.*,
-- FP.*, MP.*). Mode:
--   veinlook  a new world (material generation 4). For each ore in `ores`
--             (a string param, comma list; default the home ores and five off-world
--             ones) a 12 m seam is laid on open ground on a ring `vl_ring`
--             (260) m round the base, one ore every 360/n degrees: the seam
--             painted exactly as mineral_field paints a vein that crops out
--             (seamPlan, the ore's first vein slot the world's ground does
--             not use, as vein_slot picks), its outcrops (the look's model,
--             tint and sheen, as outcrop_look sets them) and its float (the
--             look's float kind and colour, as float_make scatters it). Then
--             pictured from 5 m and 20 m at eye height (1.7 m) and from 60 m
--             at 4 m (a low rise), looking at the seam's middle across its
--             strike: veinlook_<ore>_{5m,20m,60m}.png. Then the dosimeter: a
--             real uranite vein found on rings out from the base, the reading
--             over it, 15 m and 40 m off it, and the HUD chip's text.
-- Params: vl_ring (m), vl_ang (rad, turns the sites round the ring), and three
-- switches for the outcrop-tint question (NOTES W3): vl_nofloat 1 lays no
-- float, vl_mat 1 also sets the tint as a material colour, vl_oldmodel 1 puts
-- every outcrop on the old rock_stone model.
-- `VP PASS|FAIL <check>` lines and `VP RESULT veinlook`; pictures in
-- $WORK/proj/save/user/vshots/veinlook_*.png.
local VL = {}
VL.ROCK_NEUTRAL = 0.42
VL.tints = {}

function VL.float_scatter(frame, look, seed, half)
  -- a strip along the frame's local x (the seam), 1 on the line fading out 4 m
  local rows = 16
  local data = {}
  for r = 0, rows - 1 do
    for c = 0, rows - 1 do
      local z = (r / (rows - 1) - 0.5) * 2 * half
      local d = math.abs(z) <= 1.2 and 1 or math.max(0, 1 - (math.abs(z) - 1.2) / 4.0)
      data[r * rows + c + 1] = d * d
    end
  end
  local c = look.float or (look.out and look.out.c) or { 0.5, 0.5, 0.5 }
  local ids = {}
  local mf = findScript("mineral_field")
  local kinds = {
    { lod = { "models/flora/rock_pebbles_l0.gltf", "models/flora/rock_pebbles_l1.gltf" }, scale = { 0.45, 0.9 }, area = 0.45, far = 45 },
    { lod = look.floatModels, scale = { 0.16, 0.42 }, area = 0.32, far = 70 },
  }
  for i, k in ipairs(kinds) do
    local ok, id = pcall(scatter.create, {
      seed = seed + i, center = vec3(0, 0, 0), halfX = half, halfZ = half,
      perChunk = math.max(1, math.floor(k.area * 64 + 0.5)), chunk = 8, align = "surface",
      scaleMin = k.scale[1], scaleMax = k.scale[2], fade = 3,
      lod = { { asset = k.lod[1], distance = k.far * 0.4 }, { asset = k.lod[2], distance = k.far } },
      density = data, densityRows = rows, parent = frame.name,
      tint = { c[1] / mf.neutralOf(k.lod[1]), c[2] / mf.neutralOf(k.lod[1]), c[3] / mf.neutralOf(k.lod[1]) },
      emissive = look.out and look.out.e or nil, emissiveStrength = look.out and look.out.e and (look.out.glow or 0.4) * 0.5 or nil,
    })
    if ok and id then ids[#ids + 1] = id else P("VP float refused: %s", tostring(id)) end
  end
  return ids
end

-- (`rel` body-relative: the planet moves metres a tick, docs/positions-and-frames.md)
function VL.outcrop(planet, look, rel, U, side, k, sc)
  local L = look.out
  local n
  createNode("VL ore", planet, function(nn) n = nn end)
  wait_for(function() return n end, 5, "outcrop node")
  if not n then return nil end
  n.model = ((params.vl_oldmodel or 0) > 0) and "models/flora/rock_stone_l0.gltf" or L.model
  local bb = home()
  local sink = sc * (L.sink or 0.3)
  n.x, n.y, n.z = rel.x - U.x * sink, rel.y - U.y * sink, rel.z - U.z * sink
  n.scale_x, n.scale_y, n.scale_z = sc, sc * (L.cluster and 1.25 or 0.8), sc
  if n.setUp then n:setUp(vec3(U.x, U.y, U.z), vec3(side.x, side.y, side.z)) end
  local c, e = L.c or { 0.5, 0.5, 0.5 }, L.e
  if not L.c then c, e = { 0.62 * 0.55, 0.45 * 0.55, 0.95 * 0.55 }, { 0.62, 0.45, 0.95 } end   -- the crystal's hue
  local nt = findScript("mineral_field").neutralOf(L.model)
  local t = { color = { c[1] / nt, c[2] / nt, c[3] / nt } }
  if e then t.emissive, t.emissiveStrength = e, L.glow or 0.4 end
  yield(); yield()
  if L.metallic or L.rough then pcall(n.setMaterial, n, { shading = "physical", metallic = L.metallic or 0, roughness = L.rough or 0.8 }) end
  local okT, errT = pcall(function() n:setTint(t) end)
  if not VL.saidTint then VL.saidTint = true; P("VP tint: setTint field %s, call ok %s %s", tostring(n.setTint ~= nil), tostring(okT), tostring(errT)) end
  VL.tints[n] = t   -- laid again before the pictures: the model's first load can drop it (mineral_field lays it twice too)
  return n
end

-- A photo camera parented to the planet (its pose kept body-relative by the
-- engine, so the planet's metres a tick never move it off its mark; a world
-- pose re-set each update lags a frame behind the drawn planet): `dist` m back
-- along -T from body-relative point `rel` and `h` m up, aimed at `rel`.
function VL.cam(planet, rel, U, T, dist, h)
  local cam
  local eye = { x = rel.x - T.x * dist + U.x * h, y = rel.y - T.y * dist + U.y * h, z = rel.z - T.z * dist + U.z * h }
  local bb = home()
  spawn("FlagPhotoCam", vec3(bb.x + eye.x, bb.y + eye.y, bb.z + eye.z), function(n) cam = n end, { parent = planet })
  wait_for(function() return cam end, 5, "photo cam")
  if not cam then return nil end
  cam.x, cam.y, cam.z = eye.x, eye.y, eye.z
  yield()
  local b2 = home()
  cam:lookAt(vec3(b2.x + rel.x, b2.y + rel.y, b2.z + rel.z), vec3(U.x, U.y, U.z))
  return cam
end

local function run_veinlook()
  V.tag = "veinlook"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  local mf, mats, cl = findScript("mineral_field"), findScript("materials"), findScript("climate")
  local hb = home()
  local planet = find(hb.name)
  local w = cl.worldOf(hb.name)
  local reserved = mf.worldReserved(w)
  local P4 = save.get("system.palette")
  P("VP palette gen %s; wildcards hold: %s", tostring(P4 and P4.gen), (function()
    local t = {}
    for _, s in ipairs(P4 and P4.wild or {}) do t[#t + 1] = s .. "=" .. tostring(P4.layer[s]) end
    return table.concat(t, " ")
  end)())
  V.check("slot 6 pays magma on a new save", mats.ofSlot(6) == "magma", "%s", tostring(mats.ofSlot(6)))
  local list = {}
  for o in string.gmatch(params.ores or "iron,copper,sulfur,obsidian,galena,uranium,crystal,ilmenite,kamacite,sperrylite,tholin,clathrate", "[^,]+") do list[#list + 1] = o end
  local u, t1, t2, R = base_frame()
  local ringD = params.vl_ring or 260
  local sea = cl.seaRadius and cl.seaRadius(hb.name) or 0
  local done = 0
  for i, ore in ipairs(list) do
    local look = mf.oreLookOf(ore)
    -- the site: on the ring, nudged round until it is dry ground
    local site
    for tryk = 0, 5 do
      local ang = (i - 1) / #list * math.pi * 2 + tryk * 0.09 + (params.vl_ang or 0)
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, ringD, R)
      local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 200)
      if gr and gr > sea + 1.5 then site = { dir = dir, r = gr, t = t } break end
    end
    if site then
      stand_at(site)
      wait(3.5)
      -- the site body-relative; its world point asked fresh each time (SW)
      -- (the ground asked again now the crew stands there: the first answer was a stand-in's)
      local Srel = MP.ground_at({ x = site.dir.x * site.r, y = site.dir.y * site.r, z = site.dir.z * site.r })
        or { x = site.dir.x * site.r, y = site.dir.y * site.r, z = site.dir.z * site.r }
      local function SW() local bb = home(); return { x = bb.x + Srel.x, y = bb.y + Srel.y, z = bb.z + Srel.z } end
      local U = unit(Srel)
      -- the seam runs out along the ring's radial (e2); the cameras stand along the ring (e1),
      -- so neither the base nor the next ore's site is behind them
      local e2 = unit(sub(site.t, { x = U.x * dot(site.t, U), y = U.y * dot(site.t, U), z = U.z * dot(site.t, U) }))
      local e1 = unit(cross(U, e2))
      local g = {}
      for k = 0, 9 do
        local sd = -6 + k * 1.33
        local q = MP.ground_at({ x = Srel.x + e2.x * sd, y = Srel.y + e2.y * sd, z = Srel.z + e2.z * sd })
        if q then
          local l = len(q.x, q.y, q.z)
          g[#g + 1] = { q.x, q.y, q.z, w = 2.0, ux = q.x / l, uy = q.y / l, uz = q.z / l }
        end
      end
      -- the slot vein_slot would pick: the first of the ore's not the ground here
      local here = {}
      local S = SW()
      for _, dd in ipairs({ -3.0, 0.8, 3.0, 6.0 }) do
        local h = terrain.slotAt(S.x - U.x * dd, S.y - U.y * dd, S.z - U.z * dd)
        if h then here[h] = true end
      end
      local slot = -1
      for _, sl in ipairs(mats.veinSlots(ore) or {}) do
        if not reserved[sl] and not here[sl] then slot = sl break end
      end
      local plan = mf.seamPlan(ore, g, slot > 0 and slot or nil, nil)
      for _, o in ipairs(plan) do
        local bb = home()
        if o.op == "tex" then terrain.paintTexture(bb.x + o.x, bb.y + o.y, bb.z + o.z, o.r, o.slot)
        elseif o.brush then terrain.paint(bb.x + o.x, bb.y + o.y, bb.z + o.z, o.r, o.c[1], o.c[2], o.c[3], o.s, o.brush)
        else terrain.paint(bb.x + o.x, bb.y + o.y, bb.z + o.z, o.r, o.c[1], o.c[2], o.c[3], o.s) end
      end
      -- outcrops along the seam (a cluster at its middle for the cluster looks)
      local L = look.out
      local nodes = {}
      local count = L.cluster and 6 or 5
      for j = 1, count do
        local k = L.cluster and math.ceil(#g / 2) or math.max(1, math.min(#g, math.floor((j - 0.5) / count * #g) + 1))
        local q = g[k]
        if q then
          local off = (j % 2 == 0 and 1 or -1) * (L.cluster and 0.5 * j / count or 0.6)
          local qw = { x = q[1] + e1.x * off + e2.x * (L.cluster and (j - count / 2) * 0.35 or 0),
                       y = q[2] + e1.y * off + e2.y * (L.cluster and (j - count / 2) * 0.35 or 0),
                       z = q[3] + e1.z * off + e2.z * (L.cluster and (j - count / 2) * 0.35 or 0) }
          local sc = L.s[1] + (L.s[2] - L.s[1]) * ((j * 0.37) % 1) * (L.cluster and 1 or 1.3)
          nodes[#nodes + 1] = VL.outcrop(planet, look, qw, U, e2, j, sc)
        end
      end
      -- the float, on a frame node at the seam's middle (x along the seam)
      local frame
      createNode("VL float " .. ore, planet, function(nn) frame = nn end)
      wait_for(function() return frame end, 5, "float frame")
      local ids = {}
      if frame then
        local rel = Srel
        frame.x, frame.y, frame.z = rel.x, rel.y, rel.z
        if frame.setUp then frame:setUp(vec3(U.x, U.y, U.z), vec3(e1.x, e1.y, e1.z)) end
        yield()
        if (params.vl_nofloat or 0) == 0 then ids = VL.float_scatter(frame, look, 7000 + i * 13, 9) end
      end
      P("VP veinlook %s: slot %d (%s), %d paint ops, %d outcrops (%s), float %s, seam %s stain %s", ore, slot,
        slot > 0 and tostring(mats.ofSlot(slot)) or "unpainted", #plan, #nodes, tostring(L.model):match("rock_[%a]+") or "?",
        tostring(look.fk), look.seam and string.format("%.2f,%.2f,%.2f", look.seam[1], look.seam[2], look.seam[3]) or "-",
        look.stain and string.format("%.2f,%.2f,%.2f", look.stain[1], look.stain[2], look.stain[3]) or "-")
      -- the crew out of the pictures: behind the far camera
      local back = dir_at(unit(Srel), { x = -e1.x, y = -e1.y, z = -e1.z }, 75, len(Srel.x, Srel.y, Srel.z))
      stand_at({ dir = back, r = ground_r(home(), back.x, back.y, back.z, R + 200) or site.r })
      wait(3.0)
      for _, n in ipairs(nodes) do
        if n and n.valid and VL.tints[n] then
          pcall(function() n:setTint(VL.tints[n]) end)
          if (params.vl_mat or 0) > 0 then
            local c = VL.tints[n].color
            local ok, er = pcall(function() n:setMaterial({ color = { math.min(1, c[1]), math.min(1, c[2]), math.min(1, c[3]) } }) end)
            if not ok then P("VP material colour refused: %s", tostring(er)) end
          end
        end
      end
      for _, view in ipairs({ { "5m", 5.0, 1.7 }, { "20m", 20.0, 1.7 }, { "60m", 60.0, 4.0 } }) do
        local cam = VL.cam(planet, Srel, U, e1, view[2], view[3])
        for _ = 1, 25 do yield() end
        if cam and cam.valid then
          local f0 = cam.toWorld and cam:toWorld(vec3(0, 0, -1))
          local o0 = cam.toWorld and cam:toWorld(vec3(0, 0, 0))
          local s2 = SW()
          local off = -1
          if f0 then off = math.deg(math.acos(math.max(-1, math.min(1, dot(unit(sub(f0, o0)), unit(sub(s2, o0))))))) end
          P("VP cam %s %s: %.1f m from the seam (local), aimed %.1f° off it", ore, view[1],
            len(cam.x - Srel.x, cam.y - Srel.y, cam.z - Srel.z), off)
        end
        V.shot(ore .. "_" .. view[1], false, cam)
        for _ = 1, 10 do yield() end
        if cam and cam.valid then cam:destroy() end
      end
      done = done + 1
      for _, id in ipairs(ids) do pcall(scatter.destroy, id) end
      for _, n in ipairs(nodes) do if n and n.valid then n:destroy() end end
      if frame and frame.valid then frame:destroy() end
    else
      P("VP veinlook %s: no dry ground on the ring", ore)
    end
  end
  V.check("every ore laid and pictured", done == #list, "%d of %d", done, #list)
  -- THE DOSIMETER over a real uranite vein (buried 20 m+): rings out from the base
  local found
  for _, dist in ipairs({ 120, 200, 300, 420, 560, 720 }) do
    for k = 0, 7 do
      if found then break end
      local ang = k * math.pi / 4 + dist * 0.011
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 200)
      if gr and gr > sea + 1 then
        stand_at({ dir = dir, r = gr })
        wait(2.5)
        local a = astro()
        for _, v in ipairs(mf.veinsNear(a.x, a.y, a.z, 160)) do
          if v.ore == "uranium" and (not found or (v.depth or 99) < (found.depth or 99)) then
            local hb2 = home()
            found = v
            found.rel = { x = v.x - hb2.x, y = v.y - hb2.y, z = v.z - hb2.z }   -- body-relative, now
          end
        end
      end
    end
    if found then break end
  end
  if found then
    local rel = found.rel
    -- in a tunnel beside it: the reading 1, 3 and 8 m from the vein's line, under ground
    for _, dd in ipairs({ 1, 3, 8 }) do
      local bb = home()
      local d0, dv = mf.doseAt(bb.x + rel.x + found.ux * dd, bb.y + rel.y + found.uy * dd, bb.z + rel.z + found.uz * dd)
      P("VP dose in rock %d m from a uranite vein (%.0f m down): %.2f µSv/h (veins %.2f)", dd, found.depth or -1, d0, dv)
    end
    local U = { x = found.ux, y = found.uy, z = found.uz }
    local side = unit(cross(U, unit({ x = found.sx, y = found.sy, z = found.sz })))
    local readings = {}
    for _, off in ipairs({ 0, 15, 40 }) do
      MP.stand_off(rel, side, off)
      wait(2.0)
      local hud = findScript("status_hud")
      readings[#readings + 1] = { off = off, dose = mf.dose, ore = mf.doseOre, line = hud and hud.line or "" }
      P("VP dose %2d m off a uranite vein %.0f m down: %.2f µSv/h (veins %.2f); HUD: %s", off, found.depth or -1, mf.dose or -1, mf.doseOre or -1,
        tostring(hud and hud.line or "-"))
    end
    V.check("the dosimeter reads over uranite and falls off with distance",
      readings[1].dose > readings[3].dose and readings[1].ore > 0, "%.2f / %.2f / %.2f", readings[1].dose, readings[2].dose, readings[3].dose)
  else
    P("VP dose: no uranite vein found within 720 m of the base (they lie 20 m+ down and are rare)")
  end
  V.result()
end
