-- ── grit probe (tools/perf/gritprobe.sh): the gritty-realism pass ───────────
-- (2026-11-10: "the lazer effects on the dig beam … no creepy atmospheres").
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam,
-- VP.cam). One table of functions (perfbench's main chunk is near Lua's
-- 200-locals ceiling).
--   gritdig   the Terrain Laser's DIG on bare rock by day: first person close,
--             third person mid and close, the cut cooling after the trigger
--             comes up, then the same at night; the frame's GPU and the
--             scripts while it fires against the same view idle
--   gritcave  a cave carved under the ground (a sloping tunnel into a
--             chamber ~12 m down): the view deeper in and back up at the
--             mouth, the helmet lamps and the clip-on torch, by day; the
--             frame's cost in there
--   gritsky   the home world's air record swapped for each alien air
--             (atmo.lua TEMPLATES: titan, sulfur, ironred, crystal) and for
--             no air at all, by day and by night, from a hill
--   gritfog   a low fog bank in the low ground (weather.forceMist), seen from
--             above it by day and by night
-- `GR` lines; `GR COST <tag>` has the GPU total and the scripts (one perfbench
-- scenario each, PB RESULT lines too). Pictures: save/user/gritshots/.
local GR = { tag = "grit", shots = 0 }

function GR.shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://gritshots/" .. GR.tag .. "_" .. nm .. ".png", bytes); P("GR SHOT %s_%s", GR.tag, nm)
    else P("GR SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("GR capture error %s", tostring(err)); return end
  wait_for(function() return done end, 6, "shot " .. nm)
  GR.shots = GR.shots + 1
end

-- strs gfx = Low | Medium | High | Ultra (default High: what Ty plays)
function GR.level()
  local gx = findScript("graphics")
  local lv = tostring(params.gfx or "High")
  if gx and gx.set then gx.set(lv) end
  P("GR LEVEL %s", tostring(gx and gx.level and gx.level()))
end

-- One scenario: `secs` of frames, the GPU passes and the scripts (perfbench's
-- record), then a one-line summary.
function GR.cost(tag, secs)
  sc_begin(tag)
  wait(secs or 4)
  local r = RECS[tag]
  sc_end(tag)
  local c = perf.counts() or {}
  local function ms(k) return (r and r.s[k] or 0) / math.max(r and #r.dts or 1, 1) end
  P("GR COST %s: gpu %.2f ms | tool_belt %.3f vfx %.3f atmosphere %.3f weather %.3f soundscape %.3f underground %.3f suit %.3f ms/frame | particles %s effects %s lights %s voices %s",
    tag, (r and r.gn > 0) and r.gpu / r.gn or -1, ms("tool_belt"), ms("vfx"), ms("atmosphere"), ms("weather"), ms("soundscape"),
    ms("underground"), ms("suit"), tostring(c.particles), tostring(c.effects), tostring(c.lights), tostring(c.voices))
end

-- The star's elevation at a point (cosine of the angle from the zenith).
function GR.sun_up(p)
  local E = findScript("electronics")
  local bs = space.bodies() or {}
  local s = E and E.sunOf and E.sunOf(p.x, p.y, p.z, bs) or nil
  local b = home()
  if not (s and b) then return 1 end
  local u = unit(sub(p, b))
  local d = unit(sub(s, p))
  return dot(u, d)
end
-- Warp until the star's elevation at the crew is below (night) or above (day) `want`.
function GR.warp_to(want, below)
  local a = astro()
  local function done()
    local su = GR.sun_up(a)
    if below then return su < want end
    return su > want
  end
  if done() then return end
  local t0 = W()
  space.warp(tonumber(params.nwarp or 600))
  while W() - t0 < 150 do
    wait(0.2)
    if (space.warp() or 1) < 2 then space.warp(tonumber(params.nwarp or 600)) end
    if done() then break end
  end
  space.warp(1)
  wait(2)
  P("GR sun elevation now %.2f", GR.sun_up(a))
end

function GR.laser()
  local inv = findScript("inventory")
  local tb = findScript("tool_belt")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  local ok, why = pcall(tb.hold, "laser")
  wait(0.8)
  P("GR tool %s gate %s", tostring(tb.toolId()), tostring(tb.gate))
  return tb
end

-- the crew's eye and a point `k` m ahead along `t`, `drop` m under the eye
function GR.aim_at(t, k, drop)
  local a, bb = astro(), home()
  local up = unit(sub(a, bb))
  local eye = { x = a.x + up.x * 1.55, y = a.y + up.y * 1.55, z = a.z + up.z * 1.55 }
  local tgt = { x = a.x + t.x * k - up.x * (drop or 0), y = a.y + t.y * k - up.y * (drop or 0), z = a.z + t.z * k - up.z * (drop or 0) }
  -- on the ground itself, k m ahead (the crew may stand in a dip or on a
  -- slope): the ray then meets the ground there, whatever its lie
  local gd = unit(sub(tgt, bb))
  local gr = ground_r(bb, gd.x, gd.y, gd.z, len(a.x - bb.x, a.y - bb.y, a.z - bb.z) + 12)
  if gr then tgt = { x = bb.x + gd.x * (gr - 0.3), y = bb.y + gd.y * (gr - 0.3), z = bb.z + gd.z * (gr - 0.3) } end
  GR.bite = { x = tgt.x - bb.x, y = tgt.y - bb.y, z = tgt.z - bb.z }   -- body-relative (rule 1)
  local d = sub(tgt, eye)
  return { eye.x, eye.y, eye.z, d.x, d.y, d.z }, tgt, up
end

-- A camera in the crew's frame: `back` behind along -t, `side` along t×up, `upm` up, looking at `look`(fn).
function GR.cam_crew(t, back, side, upm, look)
  VP.cam = function()
    local a, bb = astro(), home()
    if not (a and bb) then return nil end
    local up = unit(sub(a, bb))
    local s = unit(cross(t, up))
    local e = { x = a.x - t.x * back + s.x * side + up.x * upm, y = a.y - t.y * back + s.y * side + up.y * upm,
                z = a.z - t.z * back + s.z * side + up.z * upm }
    local tg = look(a, up, s)
    return vec3(e.x, e.y, e.z), vec3(tg.x, tg.y, tg.z)
  end
end

-- Open, dry, gently sloped ground 140-260 m from the base (away from its
-- buildings), with the least flora: { dir, r, t, d, biome, flora }.
function GR.spot()
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local sea = cl and cl.seaRadius and cl.seaRadius(b.name) or 0
  local best
  for _, d in ipairs({ 120, 150, 190, 230, 270, 320 }) do
    for k = 0, 15 do
      local ang = k * math.pi / 8
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 200)
      if g0 then
        local tt = unit(sub(t, scl(dir, dot(t, dir))))
        local g1
        local d6 = unit({ x = dir.x * R + tt.x * 6, y = dir.y * R + tt.y * 6, z = dir.z * R + tt.z * 6 })
        g1 = ground_r(b, d6.x, d6.y, d6.z, R + 200)
        local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        local smp = cl and cl.sampleAt and cl.sampleAt(b.name, p.x, p.y, p.z)
        local fl = smp and smp.density or 0.5
        if g1 and not wet and (sea <= 0 or g0 > sea + 12) then
          local slope = math.abs(g1 - g0) / 6
          local score = fl + slope * 2
          if slope < 0.35 and (not best or score < best.score) then
            best = { dir = dir, r = g0, t = tt, d = d, score = score, biome = smp and smp.biome, flora = fl, slope = slope }
          end
        end
      end
    end
  end
  if best then P("GR spot %s flora %.2f slope %.2f %d m out", tostring(best.biome), best.flora, best.slope, best.d) end
  return best
end

-- The dig's cost at ONE fixed camera (beside the crew, the bite in view):
-- idle and firing alternated twice, 4 s each, after a second to settle.
function GR.ab_dig(tb, t, tagp)
  local function fire(on)
    tb.sim = { btn = { [0] = on }, aim = GR.aim_at(t, 4.5, 1.6) }
  end
  GR.cam_crew(t, -1.0, 6.0, 2.8, function(a, up, s)
    return { x = a.x + t.x * 3.5 - up.x * 0.6, y = a.y + t.y * 3.5 - up.y * 0.6, z = a.z + t.z * 3.5 - up.z * 0.6 }
  end)
  local res = {}
  for i = 1, 4 do
    local on = (i % 2 == 0)
    local tag = string.format("%s_ab%d_%s", tagp, i, on and "fire" or "idle")
    local t0 = time
    while time - t0 < 1.0 do fire(on); yield() end
    sc_begin(tag)
    t0 = time
    while time - t0 < 4.0 do fire(on); yield() end
    sc_end(tag)
    local r = RECS[tag]
    local function ms(k) return (r and r.s[k] or 0) / math.max(r and #r.dts or 1, 1) end
    local c = perf.counts() or {}
    res[#res + 1] = { on = on, gpu = (r and r.gn > 0) and r.gpu / r.gn or -1,
                      cpu = ms("tool_belt") + ms("vfx"), parts = r and r.b and (r.b.particles or 0) / math.max(#r.dts, 1) or 0 }
    P("GR AB %s: gpu %.2f ms | tool_belt+vfx %.3f ms | engine particles bucket %.3f ms | particles %s effects %s",
      tag, res[#res].gpu, res[#res].cpu, res[#res].parts, tostring(c.particles), tostring(c.effects))
  end
  fire(false)
  local gi, gf, ci, cf, pi, pf = 0, 0, 0, 0, 0, 0
  for _, e in ipairs(res) do
    if e.on then gf, cf, pf = gf + e.gpu / 2, cf + e.cpu / 2, pf + e.parts / 2 else gi, ci, pi = gi + e.gpu / 2, ci + e.cpu / 2, pi + e.parts / 2 end
  end
  P("GR AB %s SUMMARY: firing adds gpu %+.2f ms (%.2f -> %.2f), scripts %+.3f ms, particle sim %+.3f ms", tagp, gf - gi, gi, gf, cf - ci, pf - pi)
  VP.cam_off()
end

-- ── the dig ────────────────────────────────────────────────────────────────
function GR.run_dig()
  wait_ready(90)
  clear_weather()
  GR.level()
  local rock = GR.spot()
  if not rock then P("GR no spot"); return end
  stand_at(rock)
  wait(params.settle or 8)
  settle_chunks(40)
  do local a, bb = astro(), home(); local u0, _, _, R0 = base_frame()
    P("GR crew at %.1f m over the radius, %.0f m from the base", len(a.x - bb.x, a.y - bb.y, a.z - bb.z) - bb.radius,
      len(a.x - bb.x - u0.x * R0, a.y - bb.y - u0.y * R0, a.z - bb.z - u0.z * R0)) end
  local tb = GR.laser()
  local pc = findScript("planet_camera")
  local t = rock.t
  local function fire(on, k, drop)
    local aim = GR.aim_at(t, k or 4.5, drop or 1.6)
    tb.sim = { btn = { [0] = on }, aim = aim }
  end
  local function hold(secs, k, drop)
    local t0 = time
    while time - t0 < secs do fire(true, k, drop); yield() end
  end
  local function phase(tagp)
    -- 1. first person, close
    VP.cam_off()
    pc.firstPerson = true
    if pc.face then pc.face(t.x, t.y, t.z, -0.24) end
    wait(1.0)
    GR.cost(tagp .. "_fp_idle", 3)
    hold(2.4)
    GR.shot(tagp .. "_fp_close")
    sc_begin(tagp .. "_fp_fire")
    hold(3.0)
    sc_end(tagp .. "_fp_fire")
    local r = RECS[tagp .. "_fp_fire"]
    P("GR COST %s_fp_fire: gpu %.2f ms", tagp, (r and r.gn > 0) and r.gpu / r.gn or -1)
    GR.shot(tagp .. "_fp_close2")
    fire(false)
    wait(0.8)
    GR.shot(tagp .. "_fp_after1s")
    wait(3.0)
    GR.shot(tagp .. "_fp_after4s")
    pc.firstPerson = false
    wait(0.5)
    -- 2. third person, mid: off to the side, the crew, the beam and the bite in frame
    local hitp = nil
    GR.cam_crew(t, -1.0, 6.0, 2.8, function(a, up, s)
      return { x = a.x + t.x * 3.5 - up.x * 0.6, y = a.y + t.y * 3.5 - up.y * 0.6, z = a.z + t.z * 3.5 - up.z * 0.6 }
    end)
    wait(0.6)
    hold(2.2)
    GR.shot(tagp .. "_tp_mid")
    GR.cost(tagp .. "_tp_fire", 5)
    -- 3. close on the bite, from beside and a little above it
    -- on the bite itself (the tool's own hit this frame), from beside it
    VP.cam = function()
      local a, bb = astro(), home()
      if not (a and bb and GR.bite) then return nil end
      local h = { x = bb.x + GR.bite.x, y = bb.y + GR.bite.y, z = bb.z + GR.bite.z }
      local up = unit(sub(h, bb))
      local back = sub(a, h)
      back = unit(sub(back, scl(up, dot(back, up))))
      local sd = unit(cross(back, up))
      local e = { x = h.x + back.x * 1.5 + sd.x * 1.1 + up.x * 0.9, y = h.y + back.y * 1.5 + sd.y * 1.1 + up.y * 0.9,
                  z = h.z + back.z * 1.5 + sd.z * 1.1 + up.z * 0.9 }
      return vec3(e.x, e.y, e.z), vec3(h.x, h.y, h.z)
    end
    hold(1.6)
    GR.shot(tagp .. "_tp_close")
    fire(false)
    wait(0.15)
    GR.cost(tagp .. "_tp_idle", 5)
    GR.shot(tagp .. "_tp_close_after3s")
    VP.cam_off()
  end
  phase("day")
  do local a, bb = astro(), home(); local up = unit(sub(a, bb))
    local s2 = unit(cross(t, up))
    a.x, a.y, a.z = a.x + s2.x * 10 + up.x * 1.0, a.y + s2.y * 10 + up.y * 1.0, a.z + s2.z * 10 + up.z * 1.0
    a.vx, a.vy, a.vz = 0, 0, 0 end
  wait(2)
  GR.ab_dig(tb, t, "day")
  -- the night: a fresh face of rock a quarter turn round
  local s = unit(cross(t, unit(sub(astro(), home()))))
  t = s
  do local a, bb = astro(), home(); local up = unit(sub(a, bb))
    a.x, a.y, a.z = a.x - t.x * 9 + up.x * 1.0, a.y - t.y * 9 + up.y * 1.0, a.z - t.z * 9 + up.z * 1.0
    a.vx, a.vy, a.vz = 0, 0, 0 end
  GR.warp_to(-0.25, true)
  phase("night")
  tb.sim = nil
end

-- ── the cave ───────────────────────────────────────────────────────────────
-- A sloping tunnel from the surface into a chamber, carved with terrain.dig.
function GR.carve(bb, G, t, up)
  local L, slope = 24, math.rad(28)
  local pts = {}
  for s = -2, L, 1.2 do
    local c = { x = G.x + t.x * s * math.cos(slope) - up.x * s * math.sin(slope),
                y = G.y + t.y * s * math.cos(slope) - up.y * s * math.sin(slope),
                z = G.z + t.z * s * math.cos(slope) - up.z * s * math.sin(slope) }
    pts[#pts + 1] = c
    terrain.dig(c.x, c.y, c.z, 2.3, 1.0, { hardness = 0.8, falloff = "smooth" })
  end
  local e = pts[#pts]
  local C = { x = e.x + t.x * 3.5 - up.x * 1.0, y = e.y + t.y * 3.5 - up.y * 1.0, z = e.z + t.z * 3.5 - up.z * 1.0 }
  for _, o in ipairs({ { 0, 0 }, { 2.5, 0 }, { -2.5, 0 }, { 0, 2.5 }, { 0, -2.5 } }) do
    local s = unit(cross(t, up))
    terrain.dig(C.x + t.x * o[1] + s.x * o[2], C.y + t.y * o[1] + s.y * o[2], C.z + t.z * o[1] + s.z * o[2], 4.2, 1.0,
      { hardness = 0.8, falloff = "smooth" })
  end
  return C, e
end

function GR.torch(on)
  local inv = findScript("inventory")
  local C = findScript("crew")
  local id = C and C.activeId and C.activeId()
  local pack = id and ("crew:" .. id) or "astro"
  if on and inv and inv.itemCount and (inv.itemCount(pack, "flashlight") or 0) < 1 then inv.addItem(pack, "flashlight", 1) end
  local fl = findScript("flashlight")
  if fl and fl.setOn then local ok, why = fl.setOn(on); P("GR torch %s: %s %s", tostring(on), tostring(ok), tostring(why)) end
end

function GR.run_cave()
  wait_ready(90)
  clear_weather()
  GR.level()
  local rock = GR.spot()
  if not rock then P("GR no spot"); return end
  stand_at(rock)
  wait(params.settle or 8)
  local bb = home()
  local up = rock.dir
  local G = { x = bb.x + up.x * rock.r, y = bb.y + up.y * rock.r, z = bb.z + up.z * rock.r }
  local t = rock.t
  -- held in the planet's frame: the planet moves while the ground re-meshes
  local Gb = { x = G.x - bb.x, y = G.y - bb.y, z = G.z - bb.z }
  local C, e = GR.carve(bb, G, t, up)
  local Cb = { x = C.x - bb.x, y = C.y - bb.y, z = C.z - bb.z }
  local eb = { x = e.x - bb.x, y = e.y - bb.y, z = e.z - bb.z }
  P("GR cave carved: chamber %.1f m under the ground", len(G.x - C.x, G.y - C.y, G.z - C.z))
  wait(1)
  wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 30, "the carve")
  wait(2)
  -- the crew on the chamber's floor
  local function inside()
    local b2 = home()
    local a = astro()
    local c = { x = b2.x + Cb.x, y = b2.y + Cb.y, z = b2.z + Cb.z }
    local u = unit(c)
    u = unit(sub(c, b2))
    a.x, a.y, a.z = c.x - u.x * 2.6, c.y - u.y * 2.6, c.z - u.z * 2.6
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  inside()
  wait(3)
  local pc = findScript("planet_camera")
  pc.firstPerson = true
  local function look(dir, pitch, nm)
    if pc.face then pc.face(dir.x, dir.y, dir.z, pitch) end
    wait(1.2)
    GR.shot(nm)
  end
  local ug = findScript("underground")
  local function st(tag)
    local l = find("Lighting"); l = l and l:getcomponent("Light")
    local su = findScript("suit")
    P("GR CAVE %s: enclosed %s ambient %.4f %.4f %.4f fog %s light %s lamp %.2f sun %.2f",
      tag, tostring(ug and ug.enclosed), l and l.ambientR or -1, l and l.ambientG or -1, l and l.ambientB or -1,
      tostring(l and l.fog), tostring(l and l.fogLight), su and su.beamLit or -1, GR.sun_up(astro()))
  end
  wait(3)
  st("in")
  -- the drips (real recordings, 3D where each drop lands): on any world here
  if ug and ug.params then ug.params.dripsAlways = true end
  wait(12)
  local dl = ug and ug.dripLog or {}
  local last = dl.last or {}
  P("GR DRIPS: spots found %d, drops played %d; last: %s, %.1f m from the eye, %.1f m along up, fall %.2f s, handle %s, spots %s",
    dl.found or -1, dl.played or -1, tostring(last.clip), last.dist or -1, last.above or 0, last.fall or 0, tostring(last.handle), tostring(last.spots))
  local back = { x = -t.x, y = -t.y, z = -t.z }
  look(t, -0.1, "cave_deep")
  look(back, 0.25, "cave_mouth")
  GR.cost("cave_lamps", 4)
  GR.torch(true)
  wait(0.5)
  st("torch")
  look(t, -0.15, "cave_torch_deep")
  look(back, 0.2, "cave_torch_mouth")
  GR.cost("cave_torch", 4)
  -- third person over the shoulder, the torch on
  pc.firstPerson = false
  wait(1)
  look(t, -0.2, "cave_tp")
  GR.torch(false)
  pc.firstPerson = true
  -- the terrain's shadow volumes catch up with a fresh carve over seconds:
  -- the same views later, and with the helmet beam's shadows off (diagnostic)
  wait(15)
  st("late")
  -- the creaks and groans (real recordings, 3D on the rock a ray found)
  local cl = ug and ug.creakLog or {}
  local cr = cl.last or {}
  P("GR CREAKS: played %d, spatial %d; last: %s, groan %s, %s m off, spatial %s, handle %s",
    cl.played or -1, cl.spatial or -1, tostring(cr.clip), tostring(cr.groan), cr.dist and string.format("%.1f", cr.dist) or "-",
    tostring(cr.spatial), tostring(cr.handle))
  local ry = cl.ray or {}
  P("GR CREAK RAY: vac %s, tries %s, ok %s hit %s why %s at %s, dist %s, cos-off-up %s",
    tostring(cr.vac), tostring(ry.tries), tostring(ry.ok), tostring(ry.hit), tostring(ry.why), tostring(ry.wd), tostring(ry.dist), tostring(ry.up))
  look(t, -0.1, "cave_late_deep")
  local hb = find("Helmet Lamp Beam")
  local hl = hb and hb:getcomponent("PointLight")
  if hl then pcall(function() hl.shadows = 0 end) end
  wait(1)
  look(t, -0.1, "cave_noshadow_deep")
  look(back, 0.2, "cave_noshadow_mouth")
  if hl then pcall(function() hl.shadows = 1 end) end
  pc.firstPerson = false
  -- the night outside, the same cave
  GR.warp_to(-0.25, true)
  pc.firstPerson = true
  st("night")
  look(t, -0.1, "cave_night_deep")
  pc.firstPerson = false
end

-- ── alien skies ────────────────────────────────────────────────────────────
-- The hill: the highest ground among the sampled spots round the base.
function GR.hill()
  local b = home()
  local u, t1, t2, R = base_frame()
  local best
  for _, d in ipairs({ 120, 170, 230, 300 }) do
    for k = 0, 11 do
      local ang = k * math.pi / 6
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 200)
      local cl = findScript("climate")
      local p = gr and { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
      local wet = p and cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
      if gr and not wet and (not best or gr > best.r) then best = { dir = dir, r = gr, t = t, d = d } end
    end
  end
  return best
end
function GR.low()
  local b = home()
  local u, t1, t2, R = base_frame()
  local best
  for _, d in ipairs({ 90, 140, 200, 260 }) do
    for k = 0, 15 do
      local ang = k * math.pi / 8
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 200)
      local cl = findScript("climate")
      local p = gr and { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
      local wet = p and cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
      if gr and not wet and (not best or gr < best.r) then best = { dir = dir, r = gr, t = t, d = d } end
    end
  end
  return best
end

-- A camera on the hill looking out along `t`, a little over the horizon.
function GR.cam_hill(spot, t, upm, pitchUp)
  VP.cam = function()
    local bb = home()
    if not bb then return nil end
    local u = spot.dir
    local e = { x = bb.x + u.x * (spot.r + upm), y = bb.y + u.y * (spot.r + upm), z = bb.z + u.z * (spot.r + upm) }
    local tg = { x = e.x + t.x * 100 + u.x * (pitchUp or 6), y = e.y + t.y * 100 + u.y * (pitchUp or 6), z = e.z + t.z * 100 + u.z * (pitchUp or 6) }
    return vec3(e.x, e.y, e.z), vec3(tg.x, tg.y, tg.z)
  end
end

GR.AIRS = { "titan", "sulfur", "ironred", "crystal" }
function GR.run_sky()
  wait_ready(90)
  clear_weather()
  GR.level()
  local b = home()
  local name = b.name
  local w0 = save.get("world." .. name)
  local A = findScript("atmo")
  P("GR home %s kind %s type %s atmo %.2f rgb %.2f %.2f %.2f gases %s", name, tostring(w0.kind), tostring(w0.geo and w0.geo.type),
    w0.atmo or 0, w0.atmoR or 0, w0.atmoG or 0, w0.atmoB or 0, tostring(A and A.gasesText and w0.air and A.gasesText(w0.air, 4)))
  for _, bd in ipairs(space.bodies() or {}) do
    local w = save.get("world." .. bd.name)
    if type(w) == "table" then
      P("GR WORLD %s kind %s type %s atmo %.2f R %.0f rgb %.2f %.2f %.2f gases %s", bd.name, tostring(w.kind), tostring(w.geo and w.geo.type),
        w.atmo or 0, w.radius or 0, w.atmoR or 0, w.atmoG or 0, w.atmoB or 0, tostring(A and A.gasesText and w.air and A.gasesText(w.air, 4)))
    end
  end
  local hill = GR.hill()
  if not hill then P("GR no hill"); return end
  stand_at(hill)
  wait(params.settle or 8)
  settle_chunks(40)
  local at = findScript("atmosphere")
  local wx = findScript("weather")
  local function swap(kind)
    local w = save.get("world." .. name)
    local copy = {}
    for k, v in pairs(w0) do copy[k] = v end
    if kind == "home" then
      -- as it was
    elseif kind == "airless" then
      copy.atmo = 0
    else
      local T = A and A.TEMPLATES and A.TEMPLATES[kind]
      local g = {}
      for k, v in pairs(T and T.gases or {}) do g[k] = v end
      copy.air = { p0 = (w0.air and w0.air.p0) or 1, T0 = (w0.air and w0.air.T0) or 280, gases = g, o2 = g.O2 or 0 }
      -- the air colour the generator rolled for such worlds in this very
      -- system (Solol titan 0.85 0.60 0.30, Kaethex ironred 0.85 0.55 0.42);
      -- sulfur and crystal by the same rule (its pastel, value 0.85)
      local ROLL = { titan = { 0.85, 0.60, 0.30 }, ironred = { 0.85, 0.55, 0.42 }, sulfur = { 0.85, 0.80, 0.42 },
                     crystal = { 0.55, 0.85, 0.72 } }
      local c = ROLL[kind] or { w0.atmoR, w0.atmoG, w0.atmoB }
      copy.atmoR, copy.atmoG, copy.atmoB = c[1], c[2], c[3]
    end
    save.set("world." .. name, copy)
    local n = find(name)
    if n and n.setCelestial then
      if kind == "airless" then n:setCelestial { atmoDensity = 0, clouds = 0 }
      else n:setCelestial { atmoDensity = (w0.atmo or 0) * 0.9 } end
    end
    if at and at.snapWeather then at.snapWeather() end
    wait(3.5)
  end
  local function round(tod)
    for _, kind in ipairs({ "home", "titan", "sulfur", "ironred", "crystal", "airless" }) do
      swap(kind)
      GR.cam_hill(hill, hill.t, 2.0, 5)
      wait(0.8)
      GR.shot(tod .. "_" .. kind)
      if tod == "night" and kind == "airless" then
        -- the harsh black of an airless night, looking down at the ground
        GR.cam_hill(hill, hill.t, 1.7, -30)
        wait(0.8)
        GR.shot(tod .. "_" .. kind .. "_ground")
      end
      if kind == "titan" or kind == "airless" then GR.cost(tod .. "_sky_" .. kind, 3) end
    end
  end
  round("day")
  -- a low sun: the hill's own heading toward it is not known, so the dusk is
  -- what the clock gives
  GR.warp_to(-0.3, true)
  round("night")
  swap("home")
  VP.cam_off()
end

-- ── fog banks ──────────────────────────────────────────────────────────────
function GR.run_fog()
  wait_ready(90)
  clear_weather()
  GR.level()
  local low = GR.low()
  local hill = GR.hill()
  if not (low and hill) then P("GR no low ground / hill"); return end
  local b = home()
  P("GR fog: low ground %.1f m, hill %.1f m (radius)", low.r - b.radius, hill.r - b.radius)
  -- stand on the hill, look toward the low ground
  stand_at(hill)
  wait(params.settle or 8)
  settle_chunks(40)
  local wx = findScript("weather")
  local at = findScript("atmosphere")
  local function view(tod)
    VP.cam = function()
      local bb = home()
      if not bb then return nil end
      local u = hill.dir
      local e = { x = bb.x + u.x * (hill.r + 3), y = bb.y + u.y * (hill.r + 3), z = bb.z + u.z * (hill.r + 3) }
      local lu = low.dir
      local tg = { x = bb.x + lu.x * (low.r + 2), y = bb.y + lu.y * (low.r + 2), z = bb.z + lu.z * (low.r + 2) }
      return vec3(e.x, e.y, e.z), vec3(tg.x, tg.y, tg.z)
    end
    wait(0.8)
    if wx and wx.forceMist then wx.forceMist(nil) end
    if at and at.snapWeather then at.snapWeather() end
    wait(2.5)
    GR.shot(tod .. "_fog_none")
    if wx and wx.forceMist then wx.forceMist(1.0) end
    if at and at.snapWeather then at.snapWeather() end
    wait(4)
    GR.shot(tod .. "_fog_bank")
    GR.cost(tod .. "_fog_bank", 3)
    -- in it: down in the low ground
    VP.cam = function()
      local bb = home()
      if not bb then return nil end
      local u = low.dir
      local e = { x = bb.x + u.x * (low.r + 1.7), y = bb.y + u.y * (low.r + 1.7), z = bb.z + u.z * (low.r + 1.7) }
      local hu = hill.dir
      local tg = { x = bb.x + hu.x * (hill.r + 1), y = bb.y + hu.y * (hill.r + 1), z = bb.z + hu.z * (hill.r + 1) }
      return vec3(e.x, e.y, e.z), vec3(tg.x, tg.y, tg.z)
    end
    wait(2.5)
    GR.shot(tod .. "_fog_inside")
    if wx and wx.forceMist then wx.forceMist(nil) end
  end
  view("day")
  GR.warp_to(-0.25, true)
  view("night")
  VP.cam_off()
end

-- ── the dig, framed (gritdigshot): fixed cameras on the bite ──────────────
-- The crew on open ground; the bite 4.5 m ahead on the ground (GR.aim_at);
-- cameras placed off the bite in the planet's frame (rule 1) each frame:
--   close  2.4 m beside and 1.6 m over the bite
--   mid    7 m to the side and 2.5 m up, the crew and the bite in frame
--   fp     first person, the view turned onto the bite
-- by day, then at dusk-dark, each while firing and 2 s after the trigger.
function GR.cam_bite(side, upm, back)
  VP.cam = function()
    local a, bb = astro(), home()
    if not (a and bb and GR.bite) then return nil end
    local h = { x = bb.x + GR.bite.x, y = bb.y + GR.bite.y, z = bb.z + GR.bite.z }
    local up = unit(sub(h, bb))
    local tw = sub(a, h)
    tw = unit(sub(tw, scl(up, dot(tw, up))))
    local sd = unit(cross(tw, up))
    local e = { x = h.x + sd.x * side + up.x * upm + tw.x * back, y = h.y + sd.y * side + up.y * upm + tw.y * back,
                z = h.z + sd.z * side + up.z * upm + tw.z * back }
    local look = { x = (h.x * 3 + a.x) / 4, y = (h.y * 3 + a.y) / 4, z = (h.z * 3 + a.z) / 4 }
    if back > 0.5 then look = h end
    return vec3(e.x, e.y, e.z), vec3(look.x, look.y, look.z)
  end
end
function GR.run_digshot()
  wait_ready(90)
  clear_weather()
  GR.level()
  local spot = GR.spot()
  if not spot then P("GR no spot"); return end
  stand_at(spot)
  wait(params.settle or 8)
  settle_chunks(40)
  local tb = GR.laser()
  local pc = findScript("planet_camera")
  local t = spot.t
  local function fire(on) tb.sim = { btn = { [0] = on }, aim = GR.aim_at(t, 4.5, 1.6) } end
  local function hold(secs) local t0 = time; while time - t0 < secs do fire(true); yield() end end
  local function set(tod)
    -- a fresh face of ground each time: step 6 m along the tangent
    local a, bb = astro(), home()
    local up = unit(sub(a, bb))
    local s2 = unit(cross(t, up))
    a.x, a.y, a.z = a.x + s2.x * 7 + up.x * 0.8, a.y + s2.y * 7 + up.y * 0.8, a.z + s2.z * 7 + up.z * 0.8
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(2.5)
    fire(false); wait(0.3)
    GR.cam_bite(5.5, 2.4, 3.0)       -- mid, beside, the crew in frame
    hold(2.6)
    GR.shot(tod .. "_bite_mid")
    GR.cam_bite(1.9, 1.5, 1.2)       -- close
    hold(1.4)
    GR.shot(tod .. "_bite_close")
    hold(1.2)
    GR.shot(tod .. "_bite_close2")
    fire(false)
    wait(2.0)
    GR.shot(tod .. "_bite_cool2s")
    wait(3.0)
    GR.shot(tod .. "_bite_cool5s")
    VP.cam_off()
    -- first person onto a fresh bite
    a, bb = astro(), home()
    up = unit(sub(a, bb))
    a.x, a.y, a.z = a.x + s2.x * 7 + up.x * 0.8, a.y + s2.y * 7 + up.y * 0.8, a.z + s2.z * 7 + up.z * 0.8
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(2.5)
    pc.firstPerson = true
    GR.aim_at(t, 4.5, 1.6)
    local eye = { x = a.x + up.x * 1.55, y = a.y + up.y * 1.55, z = a.z + up.z * 1.55 }
    local h = { x = bb.x + GR.bite.x, y = bb.y + GR.bite.y, z = bb.z + GR.bite.z }
    local d = sub(h, eye)
    local du = dot(d, up)
    local hz = len(d.x - up.x * du, d.y - up.y * du, d.z - up.z * du)
    if pc.face then pc.face(d.x, d.y, d.z, math.atan2(du, hz) + 0.12) end
    wait(1.0)
    hold(2.4)
    GR.shot(tod .. "_bite_fp")
    fire(false)
    wait(1.5)
    GR.shot(tod .. "_bite_fp_after")
    pc.firstPerson = false
  end
  set("day")
  GR.warp_to(-0.12, true)
  set("dusk")
  tb.sim = nil
end
