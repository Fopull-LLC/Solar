-- ── walk probe (tools/perf/walkprobe.sh): the walker against walls, ledges, slopes ──
-- Spliced into a copy of perfbench.lua before its main (like jitterprobe).
-- Playtest 2026-11-05: "better physics with the character controller when
-- interacting with walls right now it feels super slidy which makes fall
-- damage extremely annoying and dangerous".
--
-- A test yard 120 m out from the base, built of static boxes (PaveSlab, the
-- base's floor piece, given a visible cube) on a floor raised clear of the
-- ground, so every run meets the same geometry: a wall, a 3 m ledge, slopes of
-- 25/40/50/60°, a 70° face, a kerb, a low ceiling. Every scenario logs one
-- `WP R <name>` line of ground-relative numbers (velocities are the engine's
-- planet-relative ones; positions are body-relative and measured in the
-- yard's own axes F (forward), L (left) and U (up)), and the fall-damage
-- monitor's Δv (crew.impactRule wrapped, the safety switch on "invincible" so
-- a probe never dies). Modes:
--   walk       the measurements
--   walkshots  pictures: the injury screen at three health levels, a hit,
--              the crouch view under the ceiling (user://walkshots/)
-- Scenarios that need what this pass adds (crouch, slide) are skipped on a
-- walker that has none.

local function WPL(fmt, ...) P("WP " .. fmt, ...) end
local Y = {}               -- the yard: O (body-relative origin on the floor top), F, L, U, pn
local DV = { max = 0, list = {} }

local function crew() return findScript("crew") end
local function walker() return findScript("planet_walker") end

-- body-relative point → world, against this frame's read of the body
local function W_(p) local b = home(); return { x = b.x + p.x, y = b.y + p.y, z = b.z + p.z } end
local function yard(f, l, u)
  return { x = Y.O.x + Y.F.x * f + Y.L.x * l + Y.U.x * u, y = Y.O.y + Y.F.y * f + Y.L.y * l + Y.U.y * u,
           z = Y.O.z + Y.F.z * f + Y.L.z * l + Y.U.z * u }
end
-- where the crew is, in the yard's axes, and how it moves (ground-relative)
local function here()
  local A = astro()
  local b = home()
  local p = { x = A.x - b.x - Y.O.x, y = A.y - b.y - Y.O.y, z = A.z - b.z - Y.O.z }
  local v = { x = A.vx or 0, y = A.vy or 0, z = A.vz or 0 }
  local u = unit({ x = A.x - b.x, y = A.y - b.y, z = A.z - b.z })
  local vu = dot(v, u)
  local vh = len(v.x - u.x * vu, v.y - u.y * vu, v.z - u.z * vu)
  local pw = walker()
  local vs, ws = pw.vertState or {}, pw.wallState or {}
  return { f = dot(p, Y.F), l = dot(p, Y.L), u = dot(p, Y.U), vf = dot(v, Y.F), vl = dot(v, Y.L), vu = vu, vh = vh,
           c = A.grounded == true, pop = vs.pop or 0, slope = vs.slope or 0, snap = vs.snap or 0,
           wall = A.wallNormal ~= nil, cut = ws.cut or 0 }
end

-- a static box: centre (f, l, u) in the yard, size (sl across, su up, sf along),
-- tilted `tilt` radians about L (+ rises toward +F)
local SLABS = {}
local function box(name, f, l, u, sl, su, sf, tilt, col)
  tilt = tilt or 0
  local c = yard(f, l, u)
  local up = unit(sub(scl(Y.U, math.cos(tilt)), scl(Y.F, math.sin(tilt))))
  local fw = unit({ x = Y.F.x * math.cos(tilt) + Y.U.x * math.sin(tilt), y = Y.F.y * math.cos(tilt) + Y.U.y * math.sin(tilt),
                    z = Y.F.z * math.cos(tilt) + Y.U.z * math.sin(tilt) })
  local w = W_(c)
  spawn("PaveSlab", vec3(w.x, w.y, w.z), function(inst)
    inst:setUp(vec3(up.x, up.y, up.z), vec3(fw.x, fw.y, fw.z))
    inst.scale = vec3(sl, su, sf)
    inst.x, inst.y, inst.z = c.x, c.y, c.z
    if inst.setPrimitive then pcall(inst.setPrimitive, inst, "Cube", col or { 0.42, 0.41, 0.38 }) end
    inst.name = "WP " .. name
    SLABS[#SLABS + 1] = inst
  end, Y.pn)
end

local function put(f, l, u)
  local A = astro()
  local p = W_(yard(f, l, u))
  A.x, A.y, A.z = p.x, p.y, p.z
  A.vx, A.vy, A.vz = 0, 0, 0
  local C = crew()
  if C and C.quietMonitors then C.quietMonitors(0.25) end
end
local function face(dir, pitch)
  local pc = findScript("planet_camera")
  local b = home()
  local w = { x = dir.x, y = dir.y, z = dir.z }
  pc.face(w.x, w.y, w.z, pitch or -0.2)
end

local function hp()
  local C = crew()
  local r = C and C.get and C.get(C.activeId())
  return r and r.hp or 1
end
local function heal()
  local C = crew()
  if C and C.patch then C.patch(C.activeId(), { hp = 1.0 }) end
end

-- the site: 120 m out, dry, with the floor raised clear of the ground
local function build_yard()
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local best
  for k = 0, 11 do
    local ang = k * math.pi / 6
    local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
    local dir = dir_at(u, t, 130, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 200)
    local wet = gr and cl and cl.seaDepth and cl.seaDepth(b.x + dir.x * (gr + 1), b.y + dir.y * (gr + 1), b.z + dir.z * (gr + 1))
    if gr and not (wet and wet > 0) then best = { dir = dir, t = t, gr = gr }; break end
  end
  if not best then WPL("no dry site"); return false end
  local U = best.dir
  local F = unit(sub(best.t, scl(U, dot(best.t, U))))
  local L = unit(cross(U, F))
  -- the highest ground under a 44 × 64 m yard
  local top = best.gr
  for fi = -8, 56, 8 do
    for li = -20, 20, 8 do
      local d = unit({ x = U.x * best.gr + F.x * fi + L.x * li, y = U.y * best.gr + F.y * fi + L.y * li, z = U.z * best.gr + F.z * fi + L.z * li })
      local g = ground_r(b, d.x, d.y, d.z, best.gr + 120)
      if g then
        local h = g * dot(d, U) - best.gr
        if h > top - best.gr then top = best.gr + h end
      end
    end
  end
  Y.U, Y.F, Y.L = U, F, L
  Y.O = scl(U, top + 1.2)
  Y.pn = V and V.planetNode and V.planetNode() or find(b.name)
  WPL("yard on %s, %.0f m from the base, floor %.2f m over the ground at its centre", b.name, 130, top + 1.2 - best.gr)
  -- the floor (0.6 m thick, its top at u = 0)
  box("floor", 24, 0, -0.3, 44, 0.6, 64, 0, { 0.36, 0.36, 0.34 })
  -- 1. a wall across F at f = 10, l -6..6, 4 m tall
  box("wall", 10.25, 0, 2.0, 12, 4.0, 0.5, 0, { 0.5, 0.46, 0.4 })
  -- 2. a ledge: a block f 16..22, l -18..-8, 3 m tall (its edge at f = 22)
  box("ledge", 19, -13, 1.5, 10, 3.0, 6, 0, { 0.45, 0.43, 0.4 })
  -- 3. slopes (8 m long, 4 m wide), rising toward +F, their foot at f = 30
  local slopes = { { 25, -15 }, { 40, -9 }, { 50, -3 }, { 60, 3 } }
  Y.slopes = {}
  for _, s in ipairs(slopes) do
    local a = math.rad(s[1])
    local Ls = 8
    local cf, cu = 30 + Ls / 2 * math.cos(a), Ls / 2 * math.sin(a) - 0.25 * math.cos(a)
    box("slope" .. s[1], cf, s[2], cu, 4, 0.5, Ls, a, { 0.48, 0.44, 0.38 })
    Y.slopes[#Y.slopes + 1] = { deg = s[1], l = s[2], a = a, mid_f = 30 + Ls / 2 * math.cos(a), mid_u = Ls / 2 * math.sin(a) }
  end
  -- 4. a 70° face, 7 m tall, at l = 12
  do
    local a = math.rad(70)
    local Ls = 7.5
    box("face70", 30 + Ls / 2 * math.cos(a), 12, Ls / 2 * math.sin(a) - 0.25 * math.cos(a), 4, 0.5, Ls, a, { 0.5, 0.42, 0.36 })
    Y.face70 = { l = 12, top_f = 30 + Ls * math.cos(a), top_u = Ls * math.sin(a) }
  end
  -- 5. a kerb: 0.3 m, across F at f = 44, l 4..12
  box("kerb", 45, 8, 0.15, 8, 0.3, 2, 0, { 0.55, 0.55, 0.52 })
  -- 6. a low ceiling: 1.55 m clear, f 48..54, l -6..6, on two walls
  box("roof", 51, 0, 1.55 + 0.15, 4.2, 0.3, 6, 0, { 0.4, 0.4, 0.42 })
  box("roofL", 51, 2.25, 0.775, 0.3, 1.55, 6, 0, { 0.4, 0.4, 0.42 })
  box("roofR", 51, -2.25, 0.775, 0.3, 1.55, 6, 0, { 0.4, 0.4, 0.42 })
  wait(1.0)
  WPL("yard built: %d boxes", #SLABS)
  return true
end

-- run `secs` of a scenario, steering with `steer(t)` each frame (nil = hands
-- off), and gather what it did
local function run(name, secs, steer, opts)
  opts = opts or {}
  local pw = walker()
  DV.max, DV.list = 0, {}
  local hp0 = hp()
  local t0 = time
  local s = { vu_max = -1e9, u_max = -1e9, u_min = 1e9, vh_max = 0, air = 0, trace = {} }
  local last
  local ground_t = nil
  while time - t0 < secs do
    local t = time - t0
    if steer then steer(t, last) else pw.steer(0, 0, false) end
    yield()
    local h = here()
    s.vu_max = math.max(s.vu_max, h.vu)
    s.u_max, s.u_min = math.max(s.u_max, h.u), math.min(s.u_min, h.u)
    s.vh_max = math.max(s.vh_max, h.vh)
    if not pw.grounded then s.air = s.air + (time - (last and last.t or time)) end
    h.t = time
    h.g = pw.grounded
    last = h
    if opts.trace and (#s.trace < 400) then s.trace[#s.trace + 1] = h end
    if opts.on then opts.on(h, t, s) end
  end
  pw.steer(nil)
  s.last = last
  s.dv = DV.max
  s.wimp = pw.impactSpeed
  s.hits = table.concat(DV.list, ",")
  s.hp_lost = hp0 - hp()
  return s
end

local function trace_line(name, s, every)
  for i = 1, #s.trace, every or 6 do
    local h = s.trace[i]
    WPL("T %s %3d f %.2f l %.2f u %.2f | vf %.2f vl %.2f vu %.2f vh %.2f g %s c %s | pop %.2f slope %.2f snap %.2f wall %s cut %.2f", name, i,
      h.f, h.l, h.u, h.vf, h.vl, h.vu, h.vh, tostring(h.g), tostring(h.c), h.pop, h.slope, h.snap, tostring(h.wall), h.cut)
  end
end

local function pw_has(k) local pw = walker(); return pw and pw[k] ~= nil end

local function settle()
  local pw = walker()
  pw.steer(0, 0, false)
  wait(0.6)
end

local function run_walk()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  if C and C.setSafety then C.setSafety("invincible") end
  -- every Δv the fall monitor judges, kept (the probe never dies: invincible)
  if C and C.impactRule then
    local orig = C.impactRule
    C.impactRule = function(dv)
      if dv > DV.max then DV.max = dv end
      if dv > 0.5 and #DV.list < 12 then DV.list[#DV.list + 1] = string.format("%.1f", dv) end
      return orig(dv)
    end
  end
  local pw = walker()
  local pc = findScript("planet_camera")
  pc.firstPerson = false
  -- trees and rocks under the yard are not in it
  if pw.bump then pw.bump = function() end end
  if not build_yard() then return end
  local F, L, U = Y.F, Y.L, Y.U
  local nF = { x = -F.x, y = -F.y, z = -F.z }
  WPL("walker params walk %.1f run %.1f accel %.1f air %.1f jump %.1f | crouch %s slide %s", pw.params.walk, pw.params.run,
    pw.params.accel, pw.params.air_accel, pw.params.jump, tostring(pw_has("crouching")), tostring(pw_has("sliding")))

  -- 0. flat sprint and stop: how far it runs out
  put(0, 0, 1.05); face(F); settle()
  local stop_f
  local s = run("flat_stop", 4.0, function(t)
    if t < 2.0 then pw.steer(1, 0, true) else pw.steer(0, 0, false) end
  end, { on = function(h, t) if t >= 2.0 and not stop_f then stop_f = h.f end end })
  WPL("R flat_stop: sprint %.2f m/s, ran out %.2f m after release, vu max %.2f", s.vh_max, s.last.f - (stop_f or 0), s.vu_max)

  -- 1. head-on into the wall at f = 10 (its face at 10.0; the capsule's centre stops at 9.67)
  put(2, 0, 1.05); face(F); settle()
  s = run("wall_head", 3.0, function(t) pw.steer(1, 0, true) end, { trace = true })
  WPL("R wall_head: vu max %.2f m/s, rose %.2f m, final f %.2f (face 10.00) vf %.2f vl %.2f, Δv %.1f, hp lost %.2f",
    s.vu_max, s.u_max - 1.0, s.last.f, s.last.vf, s.last.vl, s.dv, s.hp_lost)
  trace_line("wall_head", s, 10)
  -- 2. into the wall at 35°: the slide along it, and on past its end at l = -6
  put(4, 3, 1.05); face(F); settle()
  s = run("wall_skim", 3.0, function(t) pw.steer(0.82, 0.57, true) end, { trace = true })
  WPL("R wall_skim: vu max %.2f, rose %.2f m, final f %.2f l %.2f, along-wall speed at the end vl %.2f (asked %.2f), Δv %.1f",
    s.vu_max, s.u_max - 1.0, s.last.f, s.last.l, s.last.vl, -0.57 * pw.params.run, s.dv)
  trace_line("wall_skim", s, 10)
  -- …and in first person, where the view does not swing round to follow the
  -- run (the third-person orbit drifts behind where you go, which turns a
  -- held W+D along the wall)
  pc.firstPerson = true
  put(4, 3, 1.05); face(F, -0.1); settle()
  local skim_v, skim_n = 0, 0
  s = run("wall_skim_fp", 1.6, function(t) pw.steer(0.82, 0.57, true) end, { on = function(h)
    if h.f > 9.6 and h.l > -5.5 then skim_v, skim_n = skim_v + math.abs(h.vl), skim_n + 1 end end })
  WPL("R wall_skim_fp: mean speed along the wall while against it %.2f m/s (35° of a %.1f m/s sprint leaves %.2f), vu max %.2f",
    skim_n > 0 and skim_v / skim_n or -1, pw.params.run, 0.57 * pw.params.run, s.vu_max)
  pc.firstPerson = false

  -- 3. the ledge (top u = 3, edge at f = 22): walk to the edge and let go there
  local function on_ledge(f) put(f, -13, 3.0 + 1.05); face(F); settle() end
  on_ledge(17)
  local rel_f
  s = run("ledge_walk_stop", 4.0, function(t, h)
    if not rel_f and h and h.f >= 21.6 then rel_f = h.f end
    if rel_f then pw.steer(0, 0, false) else pw.steer(1, 0, false) end
  end)
  WPL("R ledge_walk_stop: let go at f %.2f (edge 22.00), stopped at f %.2f u %.2f, %s, Δv %.1f",
    rel_f or -1, s.last.f, s.last.u, s.last.u < 2.0 and "FELL OFF" or "on the ledge", s.dv)
  -- standing with the centre 0.1 m inside the edge, and 0.12 m past it (boots still on it)
  for _, off in ipairs({ -0.1, 0.12 }) do
    on_ledge(22 + off)
    s = run("ledge_stand", 3.0, nil)
    WPL("R ledge_stand %+.2f: crept %.2f m along F in 3 s, end u %.2f, %s", off, s.last.f - (22 + off), s.last.u,
      s.last.u < 2.0 and "FELL OFF" or "stayed")
  end
  -- walking along the edge with the wall... (no wall there): along the edge at 0.4 m in
  put(21.6, -17.4, 3.0 + 1.05); face(L); settle()
  s = run("ledge_along", 1.6, function(t) pw.steer(1, 0, false) end)
  WPL("R ledge_along (0.4 m in, walking along it): end f %.2f (drift %.2f toward the drop), %s",
    s.last.f, s.last.f - 21.6, s.last.u < 2.0 and "FELL OFF" or "stayed")
  -- sprint off it: the landing, and the run-out with the keys let go on touchdown
  on_ledge(17)
  local air, land_f, land_t
  s = run("ledge_run", 5.0, function(t, h)
    if h and h.f > 22.3 then air = true end
    if air and h and h.g and not land_f then land_f, land_t = h.f, t end
    if land_f then pw.steer(0, 0, false) else pw.steer(1, 0, true) end
  end, { trace = true })
  WPL("R ledge_run: landed at f %.2f, ran out %.2f m after touchdown, Δv %.1f (hits %s), hp lost %.2f",
    land_f or -1, s.last.f - (land_f or 0), s.dv, s.hits, s.hp_lost)
  trace_line("ledge_run", s, 4)

  -- 4. slopes: dropped from 2 m onto the middle, hands off; then across it
  for _, sl in ipairs(Y.slopes) do
    local downhill = 0
    put(sl.mid_f, sl.l, sl.mid_u + 2.6); face(L); wait(0.1)
    local f0
    s = run("slope", 3.5, nil, { on = function(h, t) if h.g and not f0 then f0 = h.f end end })
    WPL("R slope %d: dropped on it; after 3.5 s slid %.2f m downhill (end vf %.2f, vu %.2f), Δv %.1f, end u %.2f",
      sl.deg, (f0 or s.last.f) - s.last.f, s.last.vf, s.last.vu, s.dv, s.last.u)
    -- standing on it a little way up, then walking across it
    put(sl.mid_f - 0.5, sl.l - 1.0, (sl.mid_f - 0.5 - 30) * math.tan(sl.a) + 1.15); face(L); settle()
    local p0 = here()
    s = run("slope_across", 2.0, function(t) pw.steer(1, 0, false) end)
    WPL("R slope %d across: walked %.2f m along L, drifted %.2f m downhill, dropped %.2f m", sl.deg, s.last.l - p0.l,
      p0.f - s.last.f, p0.u - s.last.u)
  end

  -- 5. falls onto the floor
  for _, H in ipairs({ 3, 5, 8, 11, 15 }) do
    heal()
    put(4, -3, H + 1.0); wait(0.05)
    s = run("fall", math.sqrt(2 * H / 9.8) + 1.5, nil)
    WPL("R fall %d m: Δv %.1f (hits %s), hp lost %.2f", H, s.dv, s.hits, s.hp_lost)
  end
  -- 6. the 70° face: from its top edge, off it and down it (a slide, not a drop)
  heal()
  put(Y.face70.top_f + 0.6, Y.face70.l, Y.face70.top_u + 1.1); face(nF); settle()
  s = run("face70", 4.0, function(t) pw.steer(1, 0, false) end, { trace = true })
  WPL("R face70 (7 m of 70° face, walked off its top): Δv %.1f (hits %s), hp lost %.2f, vh max %.2f, air %.2f s",
    s.dv, s.hits, s.hp_lost, s.vh_max, s.air)
  trace_line("face70", s, 6)
  -- …and a 60° slope's top, walked off down it
  heal()
  local s60 = Y.slopes[4]
  put(30 + 8 * math.cos(s60.a) + 0.6, s60.l, 8 * math.sin(s60.a) + 1.1); face(nF); settle()
  s = run("slope60_down", 4.0, function(t) pw.steer(1, 0, false) end)
  WPL("R slope60_down (walked off its top, down it): Δv %.1f (hits %s), hp lost %.2f, vh max %.2f", s.dv, s.hits, s.hp_lost, s.vh_max)
  -- 7. the kerb, walked and sprinted into
  for _, sp in ipairs({ false, true }) do
    heal()
    put(40, 8, 1.05); face(F); settle()
    s = run("kerb", sp and 1.2 or 2.0, function(t) pw.steer(1, 0, sp) end, { trace = not sp })
    WPL("R kerb %s: over it %s (end u %.2f), vu max %.2f, Δv %.1f, hp lost %.2f", sp and "sprint" or "walk", tostring(s.last.f > 46.2), s.last.u, s.vu_max, s.dv, s.hp_lost)
    if not sp then trace_line("kerb", s, 3) end
  end
  -- 8. jumps on the flat: a jump is no fall
  heal()
  put(4, 6, 1.05); face(F); settle()
  s = run("jumps", 4.0, function(t) pw.steer(1, 0, true, (t % 1.3) < 0.05) end)
  WPL("R jumps: Δv %.1f (hits %s), hp lost %.2f", s.dv, s.hits, s.hp_lost)

  -- 8b. a pit dug in the natural ground at f = -30 (surface-nets walls, not boxes)
  do
    local b = home()
    local function ground_u(f, l)
      local top = W_(yard(f, l, 4))
      local h = raycast(top.x, top.y, top.z, -U.x, -U.y, -U.z, 40, { ignore = { astro() } })
      return h and (4 - h.distance) or nil
    end
    local g0 = ground_u(-30, 0)
    if g0 then
      for li = -4.5, 4.5, 1.5 do
        for _, dd in ipairs({ 0.0, -1.5, -3.0 }) do
          local c = W_(yard(-30, li, g0 + dd))
          terrain.dig(c.x, c.y, c.z, 2.6, 1.0)
        end
      end
      wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "pit")
      wait(1.0)
      local floor_u = ground_u(-30, 0)
      local rim_u = ground_u(-23, 0)
      WPL("R pit: ground %.2f, pit floor %.2f (%.1f m deep), rim ground at f -23 %.2f", g0, floor_u or -99, g0 - (floor_u or g0), rim_u or -99)
      -- run off the rim into it, hands off on touchdown
      heal()
      put(-21, 0, (rim_u or g0) + 1.1); face(nF); settle()
      local landed_f
      s = run("pit_run", 4.0, function(t, h)
        if h and h.u < (rim_u or g0) - 0.5 and h.g and not landed_f then landed_f = h.f end
        if landed_f then pw.steer(0, 0, false) else pw.steer(1, 0, true) end
      end, { trace = true })
      WPL("R pit_run: Δv %.1f (hits %s), walker impact %s, hp lost %.2f, landed at f %.2f, end f %.2f u %.2f",
        s.dv, s.hits, tostring(s.wimp), s.hp_lost, landed_f or -99, s.last.f, s.last.u)
      trace_line("pit_run", s, 8)
      -- from the floor, into the wall at 35° and head-on
      if floor_u then
        heal()
        put(-30, 0, floor_u + 1.1); face(F); settle()
        s = run("pit_wall", 2.5, function(t) pw.steer(0.82, 0.57, true) end, { trace = true })
        WPL("R pit_wall 35°: vu max %.2f, rose %.2f m, along-wall speed at the end %.2f, Δv %.1f",
          s.vu_max, s.u_max - (floor_u + 1.0), math.abs(s.last.vl), s.dv)
        trace_line("pit_wall", s, 10)
        put(-30, 0, floor_u + 1.1); face(F); settle()
        s = run("pit_head", 2.5, function(t) pw.steer(1, 0, true) end, { trace = true })
        WPL("R pit_head: vu max %.2f, rose %.2f m (wall climbed? %s), Δv %.1f", s.vu_max, s.u_max - (floor_u + 1.0),
          tostring(s.u_max - (floor_u + 1.0) > 1.5), s.dv)
        trace_line("pit_head", s, 6)
        -- jumping at the wall: the air's contact may not lift
        put(-30, 0, floor_u + 1.1); face(F); settle()
        s = run("pit_jump", 2.5, function(t) pw.steer(1, 0, true, (t % 0.8) < 0.05) end)
        WPL("R pit_jump: rose %.2f m (a jump alone: %.2f), vu max %.2f", s.u_max - (floor_u + 1.0),
          pw.params.jump ^ 2 / 19.6, s.vu_max)
      end
    else
      WPL("R pit: no ground under f -30")
    end
  end

  -- 9. crouch under the ceiling (needs the crouch)
  if pw_has("crouching") then
    put(44, 0, 1.05); face(F); settle()
    local under_ok, stood_under = nil, false
    s = run("crouch_in", 4.5, function(t, h)
      local inside = h and h.f > 48.6 and h.f < 53.4
      local want_c = t < 3.0
      pw.steer(t < 3.0 and 1 or 0, 0, false, false, 0, want_c)
      if inside and t > 3.2 and not pw.crouching then stood_under = true end
    end)
    WPL("R crouch_in: under the roof at f %.2f, crouching %s after letting go under it, stood up under it %s, capsule %.2f m, eye drop %.2f m",
      s.last.f, tostring(pw.crouching), tostring(stood_under), (astro():getcomponent("RigidBody") or {}).height or -1, pw.crouchAmount or -1)
    -- out the far side: stands up again
    s = run("crouch_out", 3.5, function(t) pw.steer(1, 0, false, false, 0, false) end)
    WPL("R crouch_out: f %.2f, crouching %s, capsule %.2f m", s.last.f, tostring(pw.crouching), (astro():getcomponent("RigidBody") or {}).height or -1)
    -- crouch-walk speed and the plain walk on the flat
    put(2, 6, 1.05); face(F); settle()
    s = run("crouch_walk", 2.5, function(t) pw.steer(1, 0, false, false, 0, true) end)
    WPL("R crouch_walk: speed %.2f m/s", s.last.vh)
  end
  -- 10. the slide: sprint, then crouch (flat, then down the 25° slope)
  if pw_has("sliding") then
    put(0, 6, 1.05); face(F); settle()
    local sl_t, v0 = nil, nil
    local pts = {}
    s = run("slide_flat", 4.5, function(t, h)
      local c = t > 1.6
      pw.steer(1, 0, true, false, 0, c)
      if pw.sliding and not sl_t then sl_t, v0 = t, h and h.vh end
      if sl_t and h and #pts < 12 and (t - sl_t) >= #pts * 0.25 then pts[#pts + 1] = string.format("%.1f", h.vh) end
    end)
    WPL("R slide_flat: began at %.2f m/s, speed every 0.25 s %s, ended crouching %s", v0 or -1, table.concat(pts, " "), tostring(pw.crouching))
    -- downhill: sprint up to the top of the 25° slope's line from above? Start on it, facing down
    local s25 = Y.slopes[1]
    put(30 + 7.5 * math.cos(s25.a), s25.l, 7.5 * math.sin(s25.a) + 1.15); face(nF); settle()
    pts, sl_t = {}, nil
    s = run("slide_down", 4.0, function(t, h)
      pw.steer(1, 0, true, false, 0, t > 0.7)
      if pw.sliding and not sl_t then sl_t = t end
      if sl_t and h and #pts < 12 and (t - sl_t) >= #pts * 0.25 then pts[#pts + 1] = string.format("%.1f", h.vh) end
    end)
    WPL("R slide_down 25°: speed every 0.25 s %s, Δv %.1f", table.concat(pts, " "), s.dv)
  end
  -- 11. a heavy pack (needs encumbrance): walk and sprint speed, jump height
  if pw_has("encumbrance") then
    local inv = findScript("inventory")
    for _, kg in ipairs({ 0, 20, 45, 80 }) do
      if inv and inv.debugSetMass then inv.debugSetMass("astro", kg) end
      pw.packOverride = kg
      wait(0.7)
      put(0, 17, 1.05); face(F); settle()
      s = run("pack", 2.2, function(t) pw.steer(1, 0, true) end)
      local spr = s.last.vh
      put(0, 17, 1.05); settle()
      s = run("packj", 1.6, function(t) pw.steer(0, 0, false, t < 0.05) end)
      WPL("R pack %d kg: sprint %.2f m/s, jump rose %.2f m, encumbrance %.2f", kg, spr, s.u_max - 1.0, pw.encumbrance or -1)
    end
    pw.packOverride = nil
  end
  WPL("DONE")
end

-- ── walkshots: the injury screen at three health levels, a hit, the crouch ──
local function wshot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false }, function(bytes, why)
    if bytes then assets.writeBytes("user://walkshots/" .. nm .. ".png", bytes); WPL("SHOT %s", nm)
    else WPL("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then WPL("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 6, "shot " .. nm)
end
local function run_walkshots()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  if C and C.setSafety then C.setSafety("rescue") end
  local pw = walker()
  local pc = findScript("planet_camera")
  if pw.bump then pw.bump = function() end end
  if not build_yard() then return end
  local F, L = Y.F, Y.L
  pc.firstPerson = true
  -- (at the yard's edge, looking out over the open ground)
  put(4, 18.5, 1.05); face(L, -0.08); settle()
  local id = C.activeId()
  local fx = findScript("injury_fx")
  WPL("injury_fx present %s", tostring(fx ~= nil))
  C.patch(id, { hp = 1.0 }); wait(2.5)
  wshot("hp100")
  for _, lv in ipairs({ { 0.7, "hp70" }, { 0.4, "hp40" }, { 0.15, "hp15" } }) do
    C.patch(id, { hp = lv[1] })
    wait(3.0)
    wshot(lv[2])
    if fx then WPL("fx %s: %s", lv[2], fx.describe and fx.describe() or "") end
  end
  -- a fresh hit (a shot), the flash at its height
  C.patch(id, { hp = 0.8 })
  wait(3.0)
  C.hurt(id, 0.3, "shot", "a probe")
  wait(0.08)
  wshot("hit_shot")
  wait(0.5)
  wshot("hit_shot_0p6")
  -- a fall's hit
  C.patch(id, { hp = 0.8 })
  wait(3.0)
  C.hurt(id, 0.25, "impact", "a probe's fall")
  wait(0.08)
  wshot("hit_fall")
  -- healed: the screen comes back clean
  C.patch(id, { hp = 1.0 })
  wait(4.0)
  wshot("healed")
  -- the crouch under the roof, in first person and from outside
  if pw.steer then
    -- standing, then crouched, at the roof's mouth (its lip 1.55 m up)
    put(46.0, 0, 1.05); face(F, 0.05); settle()
    wshot("stand_fp")
    local t0 = time
    while time - t0 < 1.5 do pw.steer(0, 0, false, false, 0, true); yield() end
    wshot("crouch_fp")
    -- from outside, third person, in the open
    pw.steer(nil)
    pc.firstPerson = false
    put(40, 4, 1.05); settle()
    pc.face(F.x + L.x * 0.9, F.y + L.y * 0.9, F.z + L.z * 0.9, -0.15)
    wait(1.0)
    wshot("stand_tp")
    local t1 = time
    while time - t1 < 1.5 do pw.steer(0, 0, false, false, 0, true); yield() end
    wshot("crouch_tp")
    pw.steer(nil)
  end
  WPL("DONE")
end
