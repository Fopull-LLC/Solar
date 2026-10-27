-- FLOORPROBE (spliced into perfbench.lua by floorprobe.sh): the base's floors
-- and foundations (base_facilities "the floor and its foundations").
--
--   floors : a fresh save. 1) the floor slabs and dig guards are there, and a
--            ray down at each strip's centre and edge finds the slab; 2) the
--            REAL terrain laser (tool_belt, driven through its `sim` hook) is
--            fired at the ground just off the runway's edge, by the pad's
--            hardstand and beside the Command Centre's floor — each refused
--            (the ground there unchanged) — and, as a control, at open ground
--            south of the runway (dug); 3) a pit is forced under the runway's
--            south edge with a direct terrain.dig and the crew walks across it
--            (steered by planet_walker.steer): the lowest the crew got over the
--            grade; 4) a 4-wheel rover rolled out on the runway is driven over
--            a second forced pit: the lowest its centre of mass got. Pictures
--            in save/user/floorshots/.
-- FP lines; `FP PASS|FAIL <what>` for each check.

do
local FP = {}
local function fp(fmt, ...) P("FP " .. fmt, ...) end
local fails = 0
local function check(ok, what, ...)
  if not ok then fails = fails + 1 end
  fp("%s %s", ok and "PASS" or "FAIL", string.format(what, ...))
end

function FP.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui == true, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://floorshots/" .. nm .. ".png", bytes); fp("SHOT %s", nm)
    else fp("SHOT %s failed %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end

local BF, Fr, RS, EDGE
local function frame()
  BF = findScript("base_facilities")
  Fr = BF.frameOf({ x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") }, save.get("base.heading") or 0,
    save.get("base.r"))
  RS = BF.stripOf(Fr, BF.RUNWAY.u0, BF.RUNWAY.v, BF.RUNWAY.u1, BF.RUNWAY.v)
  EDGE = BF.RUNWAY.half + BF.RUNWAY.shoulder
end
-- a unit direction: layout (u, v), or the runway's (s, w)
local function dUV(u, v) return BF.dirAt(Fr, u, v) end
local function dRW(s, w) return BF.stripDir(RS, s, w) end
local function at(d, h) local b = home(); return { x = b.x + d.x * (Fr.R + h), y = b.y + d.y * (Fr.R + h), z = b.z + d.z * (Fr.R + h) } end
local function height_of(p) local b = home(); return len(p.x - b.x, p.y - b.y, p.z - b.z) - Fr.R end
local function ground_h(d) local b = home(); local r = ground_r(b, d.x, d.y, d.z, Fr.R + 30); return r and (r - Fr.R) end
local function settle_edits(tmo) wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, tmo or 10, "edits landed") end

-- 1. the slabs and the guards
local function floor_census()
  fp("slabs %s, guard volumes %d, SLAB top %.2f thick %.2f, GUARD margin %.1f", tostring(BF.SLAB_COUNT),
    #BF.guardVolumes(), BF.SLAB.top, BF.SLAB.thick, BF.GUARD.margin)
  check((BF.SLAB_COUNT or 0) >= 40, "%s floor slabs laid", tostring(BF.SLAB_COUNT))
  local function ray(tag, d, want_slab)
    local o = at(d, 4.0)
    local h = raycast(o.x, o.y, o.z, -d.x, -d.y, -d.z, 12.0)
    local nm = h and h.node and h.node.valid and h.node.name or (h and "terrain" or "nothing")
    local top = h and (4.0 - h.distance) or 0
    fp("RAY %-22s hits %-12s at %+.2f m (ground %+.2f)", tag, nm, top, ground_h(d) or 99)
    if want_slab == true and nm ~= "Floor Slab" then
      -- the graded ground stands a few cm over the slab's top here: take it
      -- out (a 1.6 m ball under the grade) and look again
      for _ = 1, 2 do local c = at(d, -1.0); terrain.dig(c.x, c.y, c.z, 1.6, 1.0) end
      settle_edits(10); wait(0.3)
      o = at(d, 4.0)
      h = raycast(o.x, o.y, o.z, -d.x, -d.y, -d.z, 12.0)
      nm = h and h.node and h.node.valid and h.node.name or (h and "terrain" or "nothing")
      top = h and (4.0 - h.distance) or 0
      fp("RAY %-22s with the ground under it dug out: hits %-12s at %+.2f m", tag, nm, top)
    end
    if want_slab ~= nil then
      check((nm == "Floor Slab") == want_slab, "ray at %s %s the slab (%s)", tag, want_slab and "finds" or "misses", nm)
    end
  end
  ray("runway centre", dRW(RS.L / 2, 0), true)
  ray("runway s=5 (blast pad)", dRW(5, 0), true)
  ray("runway edge-0.3", dRW(RS.L / 2, -(EDGE - 0.3)), true)
  ray("runway edge+0.8", dRW(RS.L / 2, -(EDGE + 0.8)), false)
  ray("taxiway", dUV(0, -40), true)
  ray("apron", dUV(-15, -12), true)
  ray("road east", dUV(80, -8), true)
  ray("crawlerway", dUV(0, 80), true)
  ray("depot yard", dUV(-50, -2), true)
end

-- 2. the laser
local function laser_at(tag, stand_d, target_d, want_refused)
  local a, tb = astro(), findScript("tool_belt")
  local gs = ground_h(stand_d) or 0
  local p = at(stand_d, gs + 1.1)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  local okh, whyh = tb.hold("laser")
  wait(0.6)
  fp("LASER %s: hold %s %s, in hand %s, gate %s", tag, tostring(okh), tostring(whyh or ""), tostring(tb.toolId()), tostring(tb.gate))
  local g0 = ground_h(target_d) or 0
  local tgt = at(target_d, g0)
  local ref0 = BF.DIG_REFUSED or 0
  local q0 = terrain.query(tgt.x, tgt.y, tgt.z)
  local shot_taken = false
  local t0 = time
  while time - t0 < 2.5 do
    local a2 = astro()
    local up2 = unit(sub(a2, home()))
    local e = { x = a2.x + up2.x * 0.6, y = a2.y + up2.y * 0.6, z = a2.z + up2.z * 0.6 }
    local t2 = at(target_d, g0)
    tb.sim = { btn = { [0] = true }, aim = { e.x, e.y, e.z, t2.x - e.x, t2.y - e.y, t2.z - e.z } }
    yield()
    if want_refused and not shot_taken and time - t0 > 1.0 then shot_taken = true; FP.shot("laser_" .. tag, true) end
  end
  local prompt = tostring(tb.prompt)
  tb.sim = { btn = { [0] = false } }
  wait(0.3)
  tb.sim = nil
  settle_edits()
  wait(0.5)
  local t3 = at(target_d, g0)
  local q1 = terrain.query(t3.x, t3.y, t3.z)
  local dug = (q1 or 0) - (q0 or 0)
  local refusedN = (BF.DIG_REFUSED or 0) - ref0
  fp("LASER %-10s ground %+.2f, field at the aim %+.2f -> %+.2f (dug %.2f m), refused %d, prompt: %s", tag, g0, q0 or 99, q1 or 99,
    dug, refusedN, prompt:sub(1, 120))
  if want_refused then
    check(refusedN > 0 and dug < 0.05 and prompt:find("foundations") ~= nil, "laser at %s refused (dug %.2f m, %d refusals)", tag, dug, refusedN)
  else
    check(refusedN == 0 and dug > 0.1, "laser at %s digs (dug %.2f m)", tag, dug)
  end
end

-- the crew walks from a to b (directions), steered against the camera's view;
-- answers the lowest the capsule's centre got over the grade, and how near the
-- pit centre it passed
local function walk(a_d, b_d, pit_d, secs)
  local pw, cam = findScript("planet_walker"), findScript("planet_camera")
  local a = astro()
  local gs = ground_h(a_d) or 0
  local p = at(a_d, math.max(gs, BF.SLAB.top) + 1.1)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(1.5)
  local low, near, rescues0 = 1e9, 1e9, pw.groundNet and pw.groundNet.rescues or 0
  local t0 = time
  while time - t0 < secs do
    a = astro()
    local up = unit(sub(a, home()))
    local tgt = at(b_d, 1.0)
    local D = sub(tgt, a)
    D = sub(D, scl(up, dot(D, up)))
    if len(D.x, D.y, D.z) < 1.0 then break end
    D = unit(D)
    local f = { x = cam.fwd_x or 0, y = cam.fwd_y or 0, z = cam.fwd_z or 1 }
    f = sub(f, scl(up, dot(f, up)))
    if len(f.x, f.y, f.z) < 1e-6 then f = D else f = unit(f) end
    local r = cross(f, up)
    pw.steer(dot(D, f), dot(D, r), false)
    yield()
    low = math.min(low, height_of(a))
    local pc = at(pit_d, 0)
    local hd = sub(a, pc)
    hd = sub(hd, scl(up, dot(hd, up)))
    near = math.min(near, len(hd.x, hd.y, hd.z))
  end
  pw.steer(nil)
  return low, near, (pw.groundNet and pw.groundNet.rescues or 0) - rescues0
end

local function pit(d, depth_c, r)
  for _ = 1, 3 do
    local c = at(d, -depth_c)
    terrain.dig(c.x, c.y, c.z, r, 1.0)
  end
  settle_edits(15)
  wait(1.0)
end

-- a freecam picture from (d_from, h) toward (d_to, h_to)
local function look(nm, d_from, h, d_to, h_to)
  local cam = findScript("planet_camera")
  cam.setFreecam(true)
  local fc = cam.freecamState()
  local b = home()
  local up = vec3(d_from.x, d_from.y, d_from.z)
  local pf = vec3(d_from.x * (Fr.R + h), d_from.y * (Fr.R + h), d_from.z * (Fr.R + h))
  local pt = vec3(d_to.x * (Fr.R + h_to), d_to.y * (Fr.R + h_to), d_to.z * (Fr.R + h_to))
  local fwd = pt - pf
  local fl = fwd - up * fwd:dot(up)
  fc.body = b.name
  fc.rel = pf
  fc.ref = fl:normalized()
  fc.pitch = math.atan2(fwd:dot(up), len(fl.x, fl.y, fl.z))
  wait(1.2)
  FP.shot(nm)
  cam.setFreecam(false)
end

function run_floors()
  wait_ready(120)
  clear_weather()
  frame()
  fp("base on %s R %.1f runway L %.0f m, edge %.1f m", tostring(save.get("base.body")), Fr.R, RS.L, EDGE)
  floor_census()

  -- 2. the laser: off the runway's edge, by the pad, by the Command floor; and open ground
  local s = RS.L / 2 - 20
  laser_at("runway", dRW(s, -(EDGE + 3.5)), dRW(s, -(EDGE + 0.5)), true)
  laser_at("open", dRW(s + 8, -(EDGE + 4.5)), dRW(s + 8, -(EDGE + 8.0)), false)
  laser_at("pad", dUV(BF.PAD.u + 25.5, 121), dUV(BF.PAD.u + 21.8, 121), true)
  laser_at("command", dUV(71.5, 10), dUV(67.8, 10), true)
  -- the guard itself, at a crater's sizes (what vessel_controller's crater / gouge ask)
  for _, c in ipairs({ { "pad centre", dUV(BF.PAD.u, BF.PAD.v), 4.8 }, { "runway 6 m off", dRW(s, -(EDGE + 6)), 4.8 },
                       { "VAB floor", dUV(0, 28), 2.0 }, { "far field", dUV(150, 90), 4.8 } }) do
    local p = at(c[2], 0)
    local r, why = BF.digClamp(p.x, p.y, p.z, c[3])
    fp("CLAMP %-14s r %.1f -> %.2f %s", c[1], c[3], r, why or "")
  end

  -- 3. a pit under the runway's south edge; the crew walks across it
  local ps = RS.L / 2 + 30
  local pd = dRW(ps, -(EDGE - 2.0))
  local gh0 = ground_h(pd)
  pit(pd, 1.5, 3.6)
  local gh1 = ground_h(pd)
  local q = at(pd, 0.0)
  fp("PIT 1 at runway s %.0f w %.1f: ground %+.2f -> %+.2f (field at the grade %+.2f)", ps, -(EDGE - 2.0), gh0 or 99, gh1 or 99,
    terrain.query(q.x, q.y, q.z) or 99)
  check((terrain.query(q.x, q.y, q.z) or 0) > 1.0, "the forced pit is open air under the runway's paving")
  local low, near, resc = walk(dRW(ps - 9, -(EDGE - 2.0)), dRW(ps + 9, -(EDGE - 2.0)), pd, 14)
  fp("WALK over pit 1: lowest capsule centre %+.2f m over the grade, passed %.1f m from the pit centre, net rescues %d", low, near, resc)
  check(near < 1.5 and low > 0.6 and resc == 0, "the walker crossed the pit on the floor (lowest %+.2f, %.1f m from its centre)", low, near)
  -- stand over it for the pictures
  local a = astro()
  local p = at(pd, BF.SLAB.top + 1.1)
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(3.0)
  local hstand = height_of(astro())
  fp("STAND over pit 1: capsule centre %+.2f m over the grade", hstand)
  check(hstand > 0.6, "the crew stands over the pit (%+.2f)", hstand)
  look("pit1_side", dRW(ps + 1, -(EDGE + 9)), 1.0, pd, -0.5)
  look("pit1_low", dRW(ps - 1, -(EDGE + 4.5)), 0.2, dRW(ps, -(EDGE - 3.0)), -1.0)

  -- 4. a rover over a second pit on the runway's centreline
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then check(false, "rover rolled out"); return end
  clear_weather()
  frame()
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  local function com() return assembly.info(vn).com end
  -- where it stands along the runway
  local b = home()
  local c0 = com()
  local s0 = 0
  do
    local best = 1e9
    for k = 0, math.floor(RS.L) do
      local d = dRW(k, 0)
      local pp = at(d, 0)
      local dd = len(pp.x - c0.x, pp.y - c0.y, pp.z - c0.z)
      if dd < best then best, s0 = dd, k end
    end
  end
  local s2 = s0 + 28
  local pd2 = dRW(s2, 0)
  pit(pd2, 1.5, 4.0)
  local q2 = at(pd2, 0.0)
  fp("PIT 2 at runway s %.0f (the rover at s %.0f): field at the grade %+.2f", s2, s0, terrain.query(q2.x, q2.y, q2.z) or 99)
  local h_start = height_of(com())     -- (this frame's: the planet moves metres a tick)
  local low2, near2, t0 = 1e9, 1e9, time
  local goal = dRW(math.min(RS.L - 5, s2 + 40), 0)
  while time - t0 < 16 do
    yield()
    if not vn.valid then break end
    if not HELD.w then key_down("w") end
    local i1 = assembly.info(vn)
    local Rh = unit(sub(i1.com, home()))
    local tg = at(goal, 0)
    local away = sub(tg, i1.com); away = sub(away, scl(Rh, dot(away, Rh)))
    local v = i1.vel
    local vh = sub(v, scl(Rh, dot(v, Rh)))
    local want = nil
    if len(away.x, away.y, away.z) > 3 and len(vh.x, vh.y, vh.z) > 1.5 then
      local sn = dot(cross(unit(vh), unit(away)), Rh)
      if dot(unit(vh), unit(away)) < 0.995 then want = sn >= 0 and "a" or "d" end
    end
    for _, k in ipairs({ "a", "d" }) do
      if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
    end
    local pc = at(pd2, 0)
    local hd = sub(i1.com, pc); hd = sub(hd, scl(Rh, dot(hd, Rh)))
    local nd = len(hd.x, hd.y, hd.z)
    if nd < 6 then low2 = math.min(low2, height_of(i1.com)) end
    near2 = math.min(near2, nd)
    if nd < 0.8 then break end          -- over the pit's centre: let go and look
    if len(away.x, away.y, away.z) < 4 then break end
  end
  release_all()
  wait(2.0)
  if vn.valid then
    local i2 = assembly.info(vn)
    local hc = height_of(i2.com)
    local Rh = unit(sub(i2.com, home()))
    local pc = at(pd2, 0)
    local hd = sub(i2.com, pc); hd = sub(hd, scl(Rh, dot(hd, Rh)))
    fp("ROVER let go over pit 2: com %+.2f m over the grade, %.1f m from the pit centre", hc, len(hd.x, hd.y, hd.z))
    low2 = math.min(low2, hc)
    local b2 = home()
    local cd = unit(sub(i2.com, b2))
    look("rover_over_pit2", dRW(s2 + 1, -(EDGE + 7)), 0.6, cd, 0.0)
  end
  fp("ROVER over pit 2: com %+.2f m at the start, lowest %+.2f within 6 m of the pit, passed %.1f m from its centre", h_start, low2, near2)
  check(near2 < 2.0 and low2 > h_start - 0.35, "the rover crossed the pit on the floor (lowest %+.2f vs %+.2f at the start, %.1f m off)", low2, h_start, near2)
  fp("SUMMARY %d failure(s)", fails)
end
end
