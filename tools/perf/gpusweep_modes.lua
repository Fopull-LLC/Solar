-- ── gpusweep (tools/perf/gpusweep.sh): every preset, at every scene, every GPU pass ──
-- Spliced into a copy of perfbench.lua (after vfxprobe_modes.lua and
-- buildkitprobe_modes.lua, whose helpers it uses); one table of functions
-- because perfbench's main chunk sits at Lua's 200-locals ceiling.
--
--   strs scenes  = "runway,meadow,forest" | "far,bigbase,vab" | "alien,alienfar" …
--   strs presets = "Low,Medium,High,Ultra" (the order they are measured in)
--   params gssecs  : seconds measured per preset (the camera turns through four
--                    headings in that time, so a view's luck does not decide)
--   params shots   : 1 = a 1920x1080 picture of heading 0 per scene and preset
--                    (user://gpusweep/<scene>_<preset>.jpg)
--   params fov     : the settings' field of view (Ty plays at 75)
--
-- Each preset is set the way the Settings menu does it (settings.set
-- "gfx_level", which drops any custom option); when the plant or rock reach,
-- the plant budget or the terrain detail changed the field is cleared and
-- grown again and the terrain left to settle, so every preset is measured
-- with its own world, not the last one's.
--
-- Per scene and preset: "GS RES" (frame p50/p95, GPU total and every pass,
-- draws, instances, chunks, props, lights, decals) and one "GSJSON {...}".
GS = { view = { head = 0, h = 1.7, pitch = -3 }, out = {} }

function GS.list(s, def)
  local t = {}
  for w in string.gmatch(tostring(s or def), "[^,%s]+") do t[#t + 1] = w end
  return t
end

-- The camera: planet_camera's framed shot, recomputed every frame from the
-- drawn astronaut and this frame's body (nothing kept as a world point).
-- view.mode "eye": eye height h, heading head (quarter turns from the
-- scene's forward, kept body-relative: planets only translate), pitch deg.
-- view.mode "over": `up` m over the crew, `back` m behind, looking `ahead` m on.
function GS.cam_on()
  local cam = findScript("planet_camera")
  if not (cam and cam.setShot) then P("GS: no camera shot hook"); return end
  cam.setShot(function()
    local a, b = astro(), home()
    if not (a and b) then return nil end
    local v = GS.view
    local rx, ry, rz = a.x - b.x, a.y - b.y, a.z - b.z
    local r = len(rx, ry, rz)
    local up = vec3(rx / r, ry / r, rz / r)
    local f0 = GS.fwd and vec3(GS.fwd.x, GS.fwd.y, GS.fwd.z) or up:cross(vec3(1, 0, 0))
    f0 = (f0 - up * f0:dot(up)):normalized()
    local fwd = f0:rotatedAround(up, (v.head or 0) * math.pi / 2)
    if v.mode == "over" then
      local eye = vec3(a.x, a.y, a.z) + up * v.up - fwd * v.back
      local look = vec3(a.x, a.y, a.z) + fwd * v.ahead
      return eye.x, eye.y, eye.z, look.x, look.y, look.z, up.x, up.y, up.z
    end
    if v.mode == "drive" then
      -- (meshfold) a drive: the eye `s` m along the heading from the crew, `h` m over the
      -- ground under it (asked of the terrain each frame, body-relative), looking ahead
      local p = vec3(rx, ry, rz) + fwd * (v.s or 0)
      local pr = len(p.x, p.y, p.z)
      local du = vec3(p.x / pr, p.y / pr, p.z / pr)
      local gr = ground_r(b, du.x, du.y, du.z, pr + 40) or pr
      -- (a little easing over the ground's steps while it moves every frame; none in the stepped
      -- pictures, so every variant stands at exactly the same height at each step)
      v.gr = (v.gr and not v.noease) and (v.gr + (gr - v.gr) * 0.25) or gr
      local eye = vec3(b.x, b.y, b.z) + du * (v.gr + (v.h or 2.5))
      local f2 = (fwd - du * fwd:dot(du)):normalized()
      local look = eye + f2 * 20 + du * (20 * math.tan(math.rad(v.pitch or 0)))
      return eye.x, eye.y, eye.z, look.x, look.y, look.z, du.x, du.y, du.z
    end
    local eye = vec3(a.x, a.y, a.z) + up * ((v.h or 1.7) - 0.9)
    local look = eye + fwd * 20 + up * (20 * math.tan(math.rad(v.pitch or 0)))
    return eye.x, eye.y, eye.z, look.x, look.y, look.z, up.x, up.y, up.z
  end, 0.05)
end
function GS.cam_off()
  local cam = findScript("planet_camera")
  if cam and cam.clearShot then cam.clearShot(0.05) end
end

-- The graphics level, as the menu sets it.
function GS.set_level(lv)
  local st = findScript("settings")
  if st and st.set then st.set("gfx_level", lv)
  else local gx = findScript("graphics"); if gx and gx.set then gx.set(lv) end end
end

-- What the level changes in the world (not the frame): when any of these
-- moved, the fields are grown again.
function GS.world_key()
  local ff, mf = findScript("flora_field"), findScript("mineral_field")
  local gx = findScript("graphics")
  return string.format("%s|%s|%s|%s", tostring(ff and ff.params.reach), tostring(ff and ff.params.max_props),
    tostring(mf and mf.params.reach), tostring(gx and gx.opt and gx.opt("terrain_detail")))
end
function GS.regrow(why)
  local ff, mf = findScript("flora_field"), findScript("mineral_field")
  local t0 = time
  if ff and ff.clearAll then ff.clearAll() end
  if mf and mf.clearAll then mf.clearAll() end
  wait(2)
  local last, lastT = "", time
  -- (the field adds patches a few rows at a time and can sit still for seconds between them:
  -- 3.5 s of quiet stopped Ultra at 9 of ~45 sources, so wait for 10 s of quiet, up to 70 s)
  while time - t0 < 70 do
    local c = perf.counts() or {}
    local k = string.format("%s/%s/%s", tostring(ff and ff.sources), tostring(ff and ff.count), tostring(c.chunks))
    if k ~= last then last, lastT = k, time end
    if time - lastT > 10 and not (terrain.busy and terrain.busy()) then break end
    wait(0.5)
  end
  P("GS regrown (%s) in %.0f s: flora sources %s props %s, chunks %s", why, time - t0, tostring(ff and ff.sources),
    tostring(ff and ff.count), tostring((perf.counts() or {}).chunks))
end

function GS.shot(name)
  if math.max(params.gsshots or 0, params.shots or 0) <= 0 then return end
  local done = false
  local ok, err = pcall(camera.capture, { w = 1920, h = 1080, ui = false, draws = false, format = "jpeg", quality = 88 }, function(bytes, why)
    if bytes then assets.writeBytes("user://gpusweep/" .. name .. ".jpg", bytes); P("GS SHOT %s", name)
    else P("GS SHOT %s failed %s", name, tostring(why)) end
    done = true
  end)
  if not ok then P("GS capture error %s", tostring(err)); return end
  wait_for(function() return done end, 8, "shot " .. name)
end

-- What covers the picture at heading 0: a 96x54 grid of rays from the camera
-- (no hit within 4 km = sky, a hit with no node = terrain, a node = geometry:
-- the base, a craft, the crew), printed as rows of s/t/g; and two pictures,
-- with the flora and without, whose difference is the flora's pixels
-- (gscover.py makes the coverage picture and the shares).
function GS.coverage(scene)
  GS.view.head = 0
  wait(0.8)
  local w, h = screen()
  local a = astro()
  local rows, n = {}, { s = 0, t = 0, g = 0 }
  local names = {}
  local GW, GH = 96, 54
  for j = 0, GH - 1 do
    local r = {}
    for i = 0, GW - 1 do
      local ox, oy, oz, dx, dy, dz = camera.screenToRay((i + 0.5) * w / GW, (j + 0.5) * h / GH)
      local hit = ox and raycast(ox, oy, oz, dx, dy, dz, 4000, { ignore = a })
      local c = "s"
      if hit then
        if hit.node and hit.node.valid ~= false and tostring(hit.node.name) ~= tostring(home().name) then
          c = "g"; local nm = tostring(hit.node.name); names[nm] = (names[nm] or 0) + 1
        else c = "t" end
      end
      n[c] = n[c] + 1
      r[#r + 1] = c
    end
    rows[#rows + 1] = table.concat(r)
  end
  local tot = GW * GH
  P("GS COVER %s rays: sky %.1f%% terrain %.1f%% geometry %.1f%% | geometry by node: %s", scene, 100 * n.s / tot, 100 * n.t / tot, 100 * n.g / tot,
    fmtk(topk(names, 8)))
  P("GSCOVER %s %d %d %s", scene, GW, GH, table.concat(rows, "/"))
  local ff = findScript("flora_field")
  local function cap(nm)
    local done = false
    pcall(camera.capture, { w = 960, h = 540, ui = false, draws = false }, function(bytes)
      if bytes then assets.writeBytes("user://gpusweep/cover_" .. nm .. ".png", bytes) end
      done = true
    end)
    wait_for(function() return done end, 8, "cover shot")
  end
  if ff then
    cap(scene .. "_with")
    ff.params.enabled = 0
    wait(2.0)
    cap(scene .. "_without")
    ff.params.enabled = 1
    GS.regrow("coverage")
  end
end

-- One measurement: `secs` with the camera turning through the four headings.
function GS.measure(scene, lv)
  local name = string.format("s_%s_%s", scene, lv)
  local secs = params.gssecs or 8
  local turn = GS.view.mode ~= "over" and GS.turn ~= false
  GS.view.head = 0
  wait(0.6)
  GS.shot(scene .. "_" .. lv)
  sc_begin(name)
  local t0 = time
  while time - t0 < secs do
    if turn then GS.view.head = math.floor((time - t0) / secs * 4) % 4 end
    yield()
  end
  sc_end(name)
  GS.view.head = 0
  local r = RECS[name]
  local st = stats(r.dts)
  local cm = {}
  for k, v in pairs(r.cnt) do cm[k] = v / math.max(r.cn, 1) end
  local ps = {}
  for k, v in pairs(r.gp or {}) do ps[k] = v / math.max(r.gn, 1) end
  local w, h = screen()
  local gx = findScript("graphics")
  local L = light()
  local o = {
    scene = scene, preset = lv, w = w, h = h, scale = app.renderScale and app.renderScale() or -1,
    gpu = r.gn > 0 and r.gpu / r.gn or -1, samples = r.gn, passes = ps,
    p50 = st.p50, p95 = st.p95, mean = st.mean, frames = st.n,
    draws = cm.draws, instances = cm.instances, chunks = cm.chunks, props = cm.props, nodes = cm.nodes,
    lights = cm.lights, decals = cm.decals, decalTris = cm.decalTris, particles = cm.particles, unbatched = cm.unbatched,
    render = (r.b.render or 0) / math.max(st.n, 1), scripts = (r.b.scripts or 0) / math.max(st.n, 1),
    shadowDist = L and L.shadowDistance, fogVol = L and L.fogVolumetric, fogSteps = L and L.fogSteps,
    ssr = L and L.reflections, contact = L and L.contactShadows, shadowMap = env and env.shadowMapSize,
    fogShafts = L and L.fogShafts, fogShaftsMap = L and L.fogShaftsMap, stars = L and L.stars, fogDensity = L and L.fogDensity, fogHeight = L and L.fogHeight, fogLight = L and L.fogLight,
    reach = (findScript("flora_field") or { params = {} }).params.reach, level = gx and gx.level(),
  }
  local cn = perf.counts() or {}
  o.shadowVolumes, o.shadowProxies, o.lightsDropped, o.textureMB = cn.shadowVolumes, cn.shadowProxies, cn.lightsDropped, (cn.textureBytes or 0) / 1048576
  o.sunMapDraws, o.sunMapCulled, o.triangles = cm.sunMapDraws, cm.sunMapCulled, cm.triangles
  o.t1, o.secs = W() - W0, params.gssecs or 8
  local pl = {}
  for _, e in ipairs(topk(ps, 16)) do pl[#pl + 1] = string.format("%s %.2f", e[1], e[2]) end
  P("GS RES %-8s %-6s %dx%d scale %.2f | frame p50 %.1f p95 %.1f | GPU %.2f ms | %s | draws %.0f inst %.0f chunks %.0f props %.0f lights %.0f decals %.0f",
    scene, lv, w, h, o.scale, st.p50, st.p95, o.gpu, table.concat(pl, ", "), cm.draws or 0, cm.instances or 0, cm.chunks or 0,
    cm.props or 0, cm.lights or 0, cm.decals or 0)
  P("GSJSON %s", json(o))
end

-- (meshfold, plant flicker 11-11) A DRIVE through the scene at `gsdrive` m/s: the eye
-- runs from -gsdrivelen to +gsdrivelen m along the heading, gsdriveh (4) m over the ground. Pass 1
-- measures (frame times, GPU, sunMapDraws: "GS DRIVE"); pass 2 takes a 640x360 PNG every
-- step (user://gpusweep/drive_<tag>_fNNNN.png) for tools/perf/drive_diff.py, which
-- finds what changes between frames that the motion does not explain (a plant that
-- turns lighter or darker as the drive crosses a distance).
function GS.drive(scene, tag)
  local spd, L = params.gsdrive or 15, params.gsdrivelen or 45
  local keep = GS.view
  GS.view = { mode = "drive", head = 0, h = params.gsdriveh or 4.0, pitch = -5, s = -L }
  wait(2.5)
  local name = "d_" .. tag
  sc_begin(name)
  local t0 = time
  while GS.view.s < L do GS.view.s = -L + (time - t0) * spd; yield() end
  sc_end(name)
  local r = RECS[name]
  local st = stats(r.dts)
  local cm = {}
  for k, v in pairs(r.cnt) do cm[k] = v / math.max(r.cn, 1) end
  local ps = {}
  for k, v in pairs(r.gp or {}) do ps[k] = v / math.max(r.gn, 1) end
  local pl = {}
  for _, e in ipairs(topk(ps, 8)) do pl[#pl + 1] = string.format("%s %.2f", e[1], e[2]) end
  P("GS DRIVE %s %s | frame p50 %.1f p95 %.1f | GPU %.2f ms | %s | sunMapDraws %.0f culled %.0f props %.0f",
    scene, tag, st.p50, st.p95, r.gn > 0 and r.gpu / r.gn or -1, table.concat(pl, ", "), cm.sunMapDraws or 0, cm.sunMapCulled or 0, cm.props or 0)
  P("GSJSON %s", json({ scene = scene, preset = "drive_" .. tag, gpu = r.gn > 0 and r.gpu / r.gn or -1, passes = ps, p50 = st.p50, p95 = st.p95,
    sunMapDraws = cm.sunMapDraws, sunMapCulled = cm.sunMapCulled, props = cm.props, instances = cm.instances }))
  if (params.gsdriveshots or 1) > 0 then
    GS.view.s, GS.view.gr, GS.view.noease = -L, nil, true
    wait(2.5)
    -- (a capture takes ~0.25 s to come back, so the pictures are taken in STEPS of
    -- gsdrivestep m, each once the last is written: the same places in every variant, and
    -- as far apart as a 15 m/s drive's frames at 30-40 fps)
    local ds = params.gsdrivestep or 0.45
    local i = 0
    t0 = time
    while GS.view.s < L do
      i = i + 1
      local nm = string.format("user://gpusweep/drive_%s_f%04d.png", tag, i)
      local done = false
      yield(); yield()
      local ok = pcall(camera.capture, { w = 640, h = 360, ui = false, draws = false }, function(bytes)
        -- (off the frame: a busy disk held it 15 s, adopt1500)
        if bytes then assets.writeBytes(nm, bytes, { async = true }) end
        done = true
      end)
      if ok then wait_for(function() return done end, 5, "drive shot") end
      GS.view.s = GS.view.s + ds
    end
    P("GS DRIVESHOTS %s %d frames over %.1f s (a step of %.2f m)", tag, i, time - t0, ds)
  end
  GS.view = keep
  wait(1.0)
end

-- Every preset at the scene the crew (and GS.view) now stand in.
function GS.presets(scene)
  local key = GS.world_key()
  for _, lv in ipairs(GS.list(params.presets, "Low,Medium,High,Ultra")) do
    GS.set_level(lv)
    -- gsfog: every level at this many volumetric fog steps (the Volumetric quality row, as a player sets it)
    if (params.gsfog or 0) > 0 then local st = findScript("settings"); if st and st.set then st.set("gfx_fog_quality", math.floor(params.gsfog)) end end
    wait(1.3)                       -- graphics.apply_world runs once a second
    local k2 = GS.world_key()
    if k2 ~= key then GS.regrow(lv .. ": " .. k2); key = k2 else wait(1.0) end
    -- gsscale: every level at one render scale (E's 0.67 rows), over the level's own
    if (params.gsscale or 0) > 0 and app.setRenderScale then app.setRenderScale(params.gsscale); wait(0.5) end
    if (params.coverage or 0) > 0 and lv == (params.covlevel or "High") then pcall(GS.coverage, scene) end
    GS.measure(scene, lv)
  end
end

-- Where each scene stands.
function GS.dry_spot(dist, pick)
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local best
  for _, d in ipairs(type(dist) == "table" and dist or { dist }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 250)
      if gr then
        local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
        local smp = cl and cl.sampleAt and cl.sampleAt(b.name, p.x, p.y, p.z)
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        if not wet then
          local s = pick(smp or {}, gr, d, R)
          if s and (not best or s > best.score) then
            best = { dir = dir, r = gr, t = t, d = d, score = s, biome = smp and smp.biome, flora = smp and smp.density or 0 }
          end
        end
      end
    end
  end
  return best
end
function GS.go(spot, fwd)
  stand_at(spot)
  GS.fwd = fwd or spot.t
  wait(3)
  settle_chunks(45)
  local ff = findScript("flora_field")
  -- the field round the new spot: its sources still for a few seconds
  local t0, last, lastT = time, "", time
  while time - t0 < 30 do
    local k = tostring(ff and ff.sources) .. "/" .. tostring(ff and ff.count)
    if k ~= last then last, lastT = k, time end
    if time - lastT > 4 then break end
    wait(0.5)
  end
end

function GS.scene(sc)
  GS.view = { mode = "eye", head = 0, h = 1.7, pitch = -3 }
  GS.turn = true
  local b = home()
  if sc == "base" then
    -- the spaceport as a new save starts it: the crew by the hangar, the
    -- lamps, the glass and the buildings all round
    local a = astro()
    -- (the spawn as the run found it, body-relative: an earlier scene has moved the crew)
    local rel = GS.spawnRel or sub(a, b)
    local d = unit(rel)
    GS.go({ dir = d, r = len(rel.x, rel.y, rel.z) - 0.9, t = unit(cross(d, { x = 0.3, y = 0.9, z = 0.1 })) })
    P("GS at the base spawn")
  elseif sc == "runway" then
    local bf = findScript("base_facilities")
    local ls = bf and bf.launchSite and bf.launchSite("runway")
    if not ls then P("GS runway: no runway"); return false end
    local d = unit(ls)
    local r = len(ls.x, ls.y, ls.z)
    GS.go({ dir = d, r = r + 0.2 }, ls.fwd)
    P("GS at the runway threshold")
  elseif sc == "meadow" or sc == "alien" then
    local spot = find_meadow(params.gpu_walk or 120)
    if not spot then P("GS %s: no spot", sc); return false end
    GS.go(spot)
    P("GS at the %s %d m out (flora %.2f)", tostring(spot.biome), spot.d, spot.flora)
  elseif sc == "forest" then
    local spot = GS.dry_spot({ 150, 220, 300, 400, 520, 650 }, function(s)
      return (s.biome == "forest" and 10 or 0) + (s.density or 0)
    end)
    if not spot then P("GS forest: no spot"); return false end
    GS.go(spot)
    P("GS at the %s %d m out (flora %.2f)", tostring(spot.biome), spot.d, spot.flora)
  elseif sc == "far" or sc == "alienfar" then
    -- far from the base, on a rise (a long view over the ground)
    local u, t1, t2, R = base_frame()
    local spot = GS.dry_spot({ 0.55 * R, 0.7 * R, 0.85 * R }, function(s, gr, d, Rr) return gr - Rr end)
    if not spot then P("GS far: no spot"); return false end
    GS.go(spot)
    GS.view.pitch = -6
    P("GS far: %s %d m out, %.1f m over the datum (flora %.2f)", tostring(spot.biome), spot.d, spot.r - R, spot.flora)
  elseif sc == "bigbase" then
    local ST = findScript("structures")
    local spot = BK.flat_spot()
    if not (ST and spot) then P("GS bigbase: no structures/spot"); return false end
    stand_at(spot)
    GS.fwd = spot.t
    wait(3)
    spawnBudget(4)
    local rec = GS.block(ST, spot, 13)
    local id = ST.add(rec)
    GS.kitid = id
    ST.spawnNow(id)
    wait_for(function() return spawnPending() == 0 and #(ST.nodesOf(id) or {}) >= #rec.bp - 2 end, 120, "the base's pieces")
    spawnBudget(nil)
    P("GS bigbase: %d pieces spawned", #(ST.nodesOf(id) or {}))
    settle_chunks(30)
    -- over the crew's shoulder, the whole block ahead
    GS.view = { mode = "over", up = 6, back = -6, ahead = 34, head = 0 }
  elseif sc == "vab" then
    local BH = enter_vab("gs_vab_enter")
    if not BH then P("GS vab: no builder"); return false end
    local B = findScript("builder")
    wait(1.5)
    load_bp(B, "gs_vab_load", finned_spine(10, 12))
    GS.cam_off()
    GS.view = { mode = "over", up = 0, back = 0, ahead = 0 }
    GS.turn = false
    wait(3)
  else
    P("GS unknown scene %s", sc); return false
  end
  return true
end
-- (only if kitprobe_modes.lua is not spliced in)
function GS.block(ST, spot, k)
  local U = spot.dir
  local o = { x = U.x * spot.r + spot.t.x * 25, y = U.y * spot.r + spot.t.y * 25, z = U.z * spot.r + spot.t.z * 25 }
  local rec = ST.newRecord(nil, home().name, o.x, o.y, o.z, U, spot.t, "floor.steel", { name = "perf block" })
  rec.bp = {}
  local uid = 0
  local function add(id, x, y, z, yaw)
    uid = uid + 1
    rec.bp[#rec.bp + 1] = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, mir = "", stage = 0 }
  end
  for i = 0, k - 1 do
    for j = 0, k - 1 do
      local x, z = (i - k / 2) * 2, j * 2
      add(((i + j) % 5 == 0) and "floor.concrete" or "floor.steel", x, 0, z)
      add(((i * 7 + j) % 4 == 0) and "windowWall.steel" or "wall.steel", x, 0.2, z + 1, 0)
      add(((i + j * 3) % 6 == 0) and "doorWall.steel" or "wall.concrete", x + 1, 0.2, z, math.pi / 2)
    end
  end
  -- 16 strip lights over the first rows (the kit pools the nearest 8 by
  -- default: kit_live.POOL; the lamps toggles set it)
  for n = 0, (params.kitlamps or 16) - 1 do
    add("lightFitting.steel", ((n % 4) - 1.5) * 4 + 0.5, 2.3, math.floor(n / 4) * 3 + 1.5)
  end
  return rec
end

-- the kit base's toggles: its pieces by kind hidden, and the lamps it pools
function GS.kit_vis(match, v)
  local ST = findScript("structures")
  local n = 0
  for _, nd in ipairs(GS.kitid and ST and ST.nodesOf(GS.kitid) or {}) do
    if nd.valid and (match == nil or tostring(nd.name):find(match)) then nd.visible = v; n = n + 1 end
  end
  return n
end
function GS.kit_names()
  local ST = findScript("structures")
  local c = {}
  for _, nd in ipairs(GS.kitid and ST and ST.nodesOf(GS.kitid) or {}) do if nd.valid then c[tostring(nd.name)] = (c[tostring(nd.name)] or 0) + 1 end end
  return c
end
function GS.lamps(n)
  return {
    on = function(c) local kl = findScript("kit_live"); c.pool = kl.POOL; kl.POOL = n; wait(1.2)
      local cn = perf.counts() or {}; P("GPU lamps%d: pool %d, lights %s dropped %s", n, n, tostring(cn.lights), tostring(cn.lightsDropped)) end,
    off = function(c) local kl = findScript("kit_live"); kl.POOL = c.pool or 8; wait(1.2) end,
  }
end
TOGGLES.lamps0, TOGGLES.lamps1, TOGGLES.lamps4, TOGGLES.lamps16 = GS.lamps(0), GS.lamps(1), GS.lamps(4), GS.lamps(16)
function GS.kt(match)
  return { on = function(c) P("GPU kit hidden (%s): %d nodes", tostring(match), GS.kit_vis(match, false)) end, off = function(c) GS.kit_vis(match, true) end }
end
TOGGLES.kit0, TOGGLES.kitglass0, TOGGLES.kitwalls0, TOGGLES.kitfloor0 = GS.kt(nil), GS.kt("[Ww]indow"), GS.kt("[Ww]all"), GS.kt("[Ff]loor")
-- A picture every 0.25 s for 3 s (960x540): what the frame does right after a
-- teleport or a level switch (the Grid fog's dark wedge, 2026-11-09).
function GS.burst(tag)
  local n = 0
  for i = 0, 12 do
    local nm = string.format("burst_%s_%02d", tag, i)
    n = n + 1
    local ok = pcall(camera.capture, { w = 960, h = 540, ui = false, draws = false, format = "jpeg", quality = 85 }, function(bytes)
      if bytes then assets.writeBytes("user://gpusweep/" .. nm .. ".jpg", bytes) end
      n = n - 1
    end)
    if not ok then n = n - 1 end
    wait(0.25)
  end
  wait_for(function() return n <= 0 end, 10, "burst shots")
  P("GS BURST %s done", tag)
end
function GS.run_burst()
  -- the meadow, on High, straight after the teleport; then Medium for 6 s and
  -- High again with no teleport
  GS.set_level("Medium"); wait(1.5)
  GS.view = { mode = "eye", head = 0, h = 1.7, pitch = -3 }
  local spot = find_meadow(params.gpu_walk or 120)
  GS.cam_on()
  stand_at(spot); GS.fwd = spot.t
  GS.set_level("High")
  GS.burst("teleport_high")
  wait(4)
  GS.burst("settled_high")
  GS.set_level("Medium"); wait(6)
  GS.set_level("High")
  GS.burst("switch_high")
  GS.set_level("Medium")
  GS.burst("switch_medium")
end
-- E's forest questions (2026-11-09): the Lighting node out of stars mode (one
-- directional sun, no per-star march), every cloud deck's cover to 0 (no cloud
-- shading of the ground), and flora_field without its 0661 shadow config
-- (every plant casts, as before the card) — the field grown again each way.
TOGGLES.stars0 = { on = function(c) c.st = c.L.stars; c.L.stars = false end, off = function(c) c.L.stars = c.st end }
TOGGLES.clouds0 = {
  on = function(c)
    c.cl = {}
    for _, nm in ipairs(space.bodies() or {}) do
      local name = type(nm) == "table" and nm.name or nm
      local nd = find(name)
      local cb = nd and nd:getcomponent("CelestialBody")
      if cb and (cb.clouds or 0) > 0 then c.cl[#c.cl + 1] = { cb = cb, v = cb.clouds }; cb.clouds = 0 end
    end
    P("GPU clouds0: %d deck(s) cleared", #c.cl)
  end,
  off = function(c) for _, e in ipairs(c.cl or {}) do pcall(function() e.cb.clouds = e.v end) end end,
}
TOGGLES.shadowkind0 = {
  on = function(c)
    local ff = findScript("flora_field")
    c.sk = ff.SHADOW_KIND; ff.SHADOW_KIND = {}
    ff.clearAll(); GS.regrow("every plant casts")
  end,
  off = function(c)
    local ff = findScript("flora_field")
    ff.SHADOW_KIND = c.sk
    ff.clearAll(); GS.regrow("0661 config back")
  end,
}
-- (meshfold, plant flicker 11-11) flora_field's shadow config as it was before: ferns and
-- succulents cast to 25 m, bushes/cactus 40 m, trees 60 m (a plant past its distance drew
-- unshadowed, lighter than the self-shaded ones just inside: the pop Ty saw driving)
TOGGLES.shadowkindold = {
  on = function(c)
    local ff = findScript("flora_field")
    c.sk = ff.SHADOW_KIND
    ff.SHADOW_KIND = {
      grass = { cast = false }, moss = { cast = false }, reed = { cast = false },
      fern = { cast = true, dist = 25 }, succulent = { cast = true, dist = 25 },
      bush = { cast = true, dist = 40 }, shrub = { cast = true, dist = 40 },
      broadleaf = { cast = true, dist = 60 }, conifer = { cast = true, dist = 60 }, palm = { cast = true, dist = 60 },
      bulb = { cast = true, dist = 60 }, coral = { cast = true, dist = 60 }, cactus = { cast = true, dist = 40 },
    }
    ff.clearAll(); GS.regrow("the old 0661 config")
  end,
  off = function(c)
    local ff = findScript("flora_field")
    ff.SHADOW_KIND = c.sk
    ff.clearAll(); GS.regrow("the new config back")
  end,
}
-- (adopt1500, 0691 shadowFade) other SHADOW_KIND configs, each regrown, against the field's own:
-- shadowmeshfold: meshfold's (ferns and succulents never cast, the rest to the map's edge);
-- shadowtreefade: bushes to 80 m (fade 15), trees to 140 m (fade 25), ferns as the field's;
-- shadowgrass: grass casts to 12 m (fade 4) too
function GS.shadowcfg(edit, label)
  return {
    on = function(c)
      local ff = findScript("flora_field")
      c.sk = ff.SHADOW_KIND
      local t = {}
      for k, v in pairs(c.sk) do t[k] = { cast = v.cast, dist = v.dist, fade = v.fade } end
      for k, v in pairs(edit) do t[k] = v end
      ff.SHADOW_KIND = t
      ff.clearAll(); GS.regrow(label)
    end,
    off = function(c)
      local ff = findScript("flora_field")
      ff.SHADOW_KIND = c.sk
      ff.clearAll(); GS.regrow("the field's config back")
    end,
  }
end
TOGGLES.shadowmeshfold = GS.shadowcfg({ fern = { cast = false }, succulent = { cast = false } }, "meshfold's config")
do
  local B, T = { cast = true, dist = 80, fade = 15 }, { cast = true, dist = 140, fade = 25 }
  TOGGLES.shadowtreefade = GS.shadowcfg({ bush = B, shrub = B, cactus = B, broadleaf = T, conifer = T, palm = T, bulb = T, coral = T },
    "bushes 80/15, trees 140/25")
end
TOGGLES.shadowgrass = GS.shadowcfg({ grass = { cast = true, dist = 12, fade = 4 } }, "grass to 12 m")
-- every LightProbes volume in the scene switched off (E's GI-ambient question)
TOGGLES.probes0 = {
  on = function(c)
    c.probes = {}
    for _, nm in ipairs({ "LightProbes", "Light Probes", "Probes", "GI", "Lighting" }) do
      for _, nd in ipairs(findAll and findAll(nm) or {}) do
        local lp = nd.valid and nd:getcomponent("LightProbes")
        if lp then c.probes[#c.probes + 1] = lp; lp.enabled = false end
      end
    end
    P("GPU probes0: %d LightProbes volumes switched off", #c.probes)
  end,
  off = function(c) for _, lp in ipairs(c.probes or {}) do pcall(function() lp.enabled = true end) end end,
}
function GS.run()
  wait_ready(120)
  GS.key0 = GS.world_key()
  do local a0, b0 = astro(), home(); if a0 and b0 then GS.spawnRel = sub(a0, b0) end end
  if (params.gsburst or 0) > 0 then
    local okb, eb = pcall(GS.run_burst)
    if not okb then P("GS ERROR burst %s", tostring(eb)) end
    GS.cam_off()
    return
  end
  local gx = findScript("graphics")
  if gx and gx.params then gx.params.autoLower = false end
  local st = findScript("settings")
  if st and st.set and params.fov then st.set("fov", params.fov) end
  local w, h = screen()
  P("GS picture %dx%d fullscreen %s fov %s", w, h, tostring(app.fullscreen and app.fullscreen()), tostring(params.fov))
  -- E's fog questions (2026-11-09): the luminous bodies, and the fog's own dials
  GS.sky_report = function(tag)
    -- every celestial body's CelestialBody component: the luminous ones as the
    -- engine ranks them (irradiance = luminosity x 1e6 / d^2; star_uniforms keeps
    -- up to 4 at >= 1 % of the brightest), and every cloud deck in reach
    local cam = astro() or find("Camera 1")
    local list, decks = {}, {}
    for _, nm in ipairs(space.bodies() or {}) do
      local name = type(nm) == "table" and nm.name or nm
      local bd, nd = space.body(name), find(name)
      local cb = nd and nd.getcomponent and nd:getcomponent("CelestialBody")
      if bd and cb then
        local d = len(bd.x - cam.x, bd.y - cam.y, bd.z - cam.z)
        local lum = cb.luminosity or 0
        if lum > 0 then list[#list + 1] = { name, lum, d, lum * 1e6 / math.max(d * d, 1) } end
        if (cb.clouds or 0) > 0.01 and d < (bd.radius or 0) * 3 then
          decks[#decks + 1] = string.format("%s clouds %.2f darkness %.2f height %.0f", name, cb.clouds, cb.cloudDarkness or -1, cb.cloudHeight or -1)
        end
      end
    end
    table.sort(list, function(a, b) return a[4] > b[4] end)
    local o, lit = {}, 0
    for _, e in ipairs(list) do
      local share = e[4] / list[1][4]
      if share >= 0.01 then lit = lit + 1 end
      o[#o + 1] = string.format("%s lum %.3g at %.3g m share %.2g", e[1], e[2], e[3], share)
    end
    local L = light()
    P("GS STARS [%s] Light.stars %s | %d luminous, %d at >= 1%% (lit by the engine, max 4): %s", tag, tostring(L and L.stars), #list,
      math.min(lit, 4), table.concat(o, "; "))
    P("GS CLOUDS [%s] %d deck(s) round the camera: %s", tag, #decks, table.concat(decks, "; "))
    local ff = findScript("flora_field")
    P("GS FLORA0661 [%s] shadowOpts %s (true = the engine took castShadow/shadowDistance; false = refused)", tag, tostring(ff and ff.shadowOpts))
  end
  pcall(GS.sky_report, "start")
  local L0 = light()
  if L0 then
    P("GS FOGDIALS stars %s fogVolumetric %s fogShafts %s fogShaftsMap %s fogSteps %s fogDensity %s fogHeight %s fogFalloff %s fogLight %s fogEnd %s shadowDistance %s shadowMap %s",
      tostring(L0.stars), tostring(L0.fogVolumetric), tostring(L0.fogShafts), tostring(L0.fogShaftsMap), tostring(L0.fogSteps), tostring(L0.fogDensity),
      tostring(L0.fogHeight), tostring(L0.fogFalloff), tostring(L0.fogLight), tostring(L0.fogEnd), tostring(L0.shadowDistance), tostring(L0.shadowMap))
  end
  for _, sc in ipairs(GS.list(params.scenes, "runway,meadow,forest")) do
    local ok, err = pcall(GS.scene, sc)
    if ok and err then
      if GS.view.mode ~= "over" or sc == "bigbase" then GS.cam_on() end
      wait(1.5)
      local ok2, e2
      if params.gsvariants then
        -- variants at one level, each measured like a preset row and photographed
        -- (strs gsvariants = "base,foglight0,…": TOGGLES names, "base" = untouched)
        GS.set_level(tostring(params.gfx or "High")); wait(1.5)
        if GS.world_key() ~= GS.key0 then GS.regrow("level") end
        local c = { L = light(), PP = post(), gx = findScript("graphics"), at = findScript("atmosphere"),
                    fl = findScript("flora_field"), fb = findScript("far_bodies") }
        ok2 = true
        -- graphics.lua re-asserts the shadow dials every frame: silenced for the variants, as ab_toggles does
        local gxu = c.gx and c.gx.update
        pcall(function() c.gx.update = function() end end)
        pcall(GS.sky_report, sc)
        for _, v in ipairs(GS.list(params.gsvariants)) do
          local T = TOGGLES[v]
          if T then pcall(T.on, c) end
          wait(2)
          -- (a repeated variant, e.g. "base" again at the end to check drift, gets its own record:
          -- a record name measured twice would return the first one's numbers)
          GS.seen = GS.seen or {}
          local key = sc .. "_" .. v
          GS.seen[key] = (GS.seen[key] or 0) + 1
          local lbl = v .. (GS.seen[key] > 1 and tostring(GS.seen[key]) or "")
          local okm, em = pcall(GS.measure, sc, tostring(params.gfx or "High") .. "_" .. lbl)
          -- what grows round the crew in this variant: per species, props by distance and LOD, est. triangles
          pcall(flora_inventory, sc .. "_" .. v)
          if not okm then P("GS ERROR variant %s: %s", v, tostring(em)) end
          if (params.gsdrive or 0) > 0 then
            local okd, ed = pcall(GS.drive, sc, lbl)
            if not okd then P("GS ERROR drive %s: %s", lbl, tostring(ed)) end
          end
          if T then pcall(T.off, c) end
          wait(1.5)
        end
        if gxu then pcall(function() c.gx.update = gxu end) end
      elseif params.gstoggles then
        -- the toggle A/B (perfbench gpu mode's) at this scene, at one level
        GS.set_level(tostring(params.gfx or "High")); wait(1.5)
        if (params.gsnovol or 0) > 0 then local at = findScript("atmosphere"); if at then at.params.volumetric = false end; P("GS volumetric OFF for this run"); wait(1) end
        if GS.world_key() ~= GS.key0 then GS.regrow("level") end
        if sc == "bigbase" then
          local cn = GS.kit_names(); local o = {}
          for k, v in pairs(cn) do o[#o + 1] = k .. " " .. v end
          table.sort(o)
          P("GS kit nodes: %s", table.concat(o, ", "))
          local fn = findScript("kit_live")
          P("GS kit lit %s, pool %s, shadowProxies %s", tostring(fn and fn.lit and #(function() local t = {} for k in pairs(fn.lit()) do t[#t + 1] = k end return t end)()), tostring(fn and fn.POOL), tostring((perf.counts() or {}).shadowProxies))
        end

        GS.shot(sc .. "_toggles_look")
        ok2, e2 = pcall(ab_toggles, "g_" .. sc)
      else
        ok2, e2 = pcall(GS.presets, sc)
      end
      if not ok2 then P("GS ERROR presets %s: %s", sc, tostring(e2)) end
      GS.cam_off()
      wait(0.5)
    else
      P("GS ERROR scene %s: %s", sc, tostring(err))
    end
  end
end
