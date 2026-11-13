-- ── vehfix probe (tools/perf/vehfixprobe.sh): playtest 2026-11-12b ──
-- Spliced after ivaprobe, verifyprobe and jumpprobe modes (uses V.*, JP.*).
--   vcoast       the player's bike (user://probe_dirtbike.json) on a flat
--                strip: up to 5, 15 and 25 m/s on the line, then W let go
--                (the real key, hands off), and once let go mid-turn; every
--                tick until it stops: speed, yaw rate, lean, slip, the rear
--                wheel's motor. `VF COAST` a run, checks: upright, no spin.
--   vcoastslope  the same on a 12 % downhill strip and on natural ground
--                (four headings).
VF = VF or {}
VF_RUN = VF_RUN or {}
VFL = function(fmt, ...) P("VF " .. fmt, ...) end
VF.L = VFL

-- per tick, while armed: the worst of what the bike does
function VF.coast_tick(dt)
  local M, vc = VF.M, VF.vc
  if not (M and vc and vc.node and vc.node.valid) then return end
  local ok, roll, pitch, yaw, rr, U, Fl = pcall(JP.att, vc)
  if not ok then return end
  local i = assembly.info(vc.node)
  local v = i.vel
  local vu = dot(v, U)
  local vh = sub(v, scl(U, vu))
  local sp = len(vh.x, vh.y, vh.z)
  local slip = 0
  if sp > 1.0 then
    local c = clamp(dot(vh, Fl) / sp, -1, 1)
    slip = math.deg(math.acos(c))
  end
  M.t = M.t + dt
  M.n = M.n + 1
  M.yaw = math.max(M.yaw, math.abs(yaw))
  M.roll = math.max(M.roll, math.abs(math.deg(roll)))
  if sp > 1.0 then M.slip = math.max(M.slip, slip) end
  M.sp = sp
  M.minup = math.min(M.minup, V.upness(vc.node))
  -- the heading turned since let go (the level front against the first one)
  if not M.F0 then M.F0 = Fl end
  local d0 = M.F0
  local dd = dot(d0, U)
  d0 = unit(sub(d0, scl(U, dd)))
  M.F0 = d0
  local h = math.deg(math.atan2(dot(cross(d0, Fl), U), dot(d0, Fl)))
  M.head = (M.head or 0) + h
  M.F0 = Fl
  M.headMax = math.max(M.headMax or 0, math.abs(M.head))
  -- the rear wheel: motor and rim against the ground
  local rear
  for _, w in ipairs(vc.R2.wheels or {}) do if (w.a or 0) <= 0 then rear = w end end
  if rear and rear.tyre and rear.tyre.valid then
    local j = rear.tyre:getcomponent("Joint")
    local vf = vc.R2.vf or 0
    if rear.rim and math.abs(vf) > 1 then M.rimSlip = math.max(M.rimSlip, math.abs(rear.rim - vf)) end
    if j and j.motor then M.motorTicks = M.motorTicks + 1; M.maxF = math.max(M.maxF, j.maxForce or 0) end
  end
  if M.n % 15 == 0 and #M.trace < 80 then
    M.trace[#M.trace + 1] = string.format("%.1f:%.1f/%.2f/%.0f/%.0f", M.t, sp, yaw, math.deg(roll), slip)
  end
  if not M.stop_t and sp < 0.3 then M.stop_t = M.t end
end

-- up to vt on the strip's line (the probe steers through
-- R2.cmd), then let go: drive 0, hands off (what a released W gives)
function VF.coast_run(vc, tag, vt, o)
  o = o or {}
  if V.strip and not o.nat then JP.reset(vc, o.d or 0) end
  local t0 = time
  local steady = 0
  local fell = false
  local up, nt = {}, 0
  while time - t0 < 40 do
    local drive, st = JP.cruise(vc, vt, not o.nat)
    if o.nat then st = 0 end
    vc.R2.cmd = { drive = drive, steer = st }
    yield()
    local sp = V.speed(vc)
    if time - t0 >= nt then
      nt = nt + 0.5
      local roll, _, yaw = JP.att(vc)
      local d, lat = 0, 0
      if V.strip and not o.nat then d, lat = JP.along(vc) end
      up[#up + 1] = string.format("%.1f:%.1f/%.2f/%.0f/%.0f@%.0f,%.1f", time - t0, sp, drive, math.deg(roll), yaw * 57.3, d, lat)
    end
    if V.upness(vc.node) < 0.5 then fell = true; break end
    if sp > vt - 0.8 then steady = steady + 1 else steady = 0 end
    if steady > 40 then break end
  end
  if fell then VFL("COAST %s v %d: FELL on the way up | %s", tag, vt, table.concat(up, " ")); return { fell = true, tag = tag, v = vt } end
  if steady <= 40 then VFL("COAST %s v %d: not steady at the speed after %.0f s | %s", tag, vt, time - t0, table.concat(up, " ")) end
  local v0 = V.speed(vc)
  -- the release: the stick (drive 0) and, with o.steer, a turn held
  VF.vc = vc
  VF.M = { t = 0, n = 0, yaw = 0, roll = 0, slip = 0, sp = v0, minup = 1, rimSlip = 0, motorTicks = 0, maxF = 0, trace = {} }
  local i0 = assembly.info(vc.node)
  vc.R2.ebMax = 0
  local t1 = time
  local secs = o.secs or 14
  while time - t1 < secs do
    vc.R2.cmd = { drive = 0, steer = o.steer or 0 }
    yield()
    if V.upness(vc.node) < 0.4 then fell = true end
    if VF.M.stop_t and time - t1 > VF.M.stop_t + 0.5 then break end
    if fell and time - t1 > 2 then break end
  end
  local M = VF.M
  VF.M = nil
  local g = vc.gasState and vc.gasState() or {}
  local r = { tag = tag, v = vt, v0 = v0, fell = fell or M.minup < 0.5, yaw = M.yaw, roll = M.roll, slip = M.slip, head = M.headMax or 0,
    stop = M.stop_t, vend = M.sp, minup = M.minup }
  VFL("COAST %s v %d (let go at %.1f m/s, steer %.2f): %.1f s, stopped %s, end %.2f m/s | peak yaw %.2f rad/s, lean %.1f deg, slip %.1f deg, heading %.0f deg, min upness %.2f, rear rim slip %.2f m/s, rear motor ticks %d (max force %.2f, engine braking at most %.2f kN m), gear %s rpm %s%s | %s",
    tag, vt, v0, o.steer or 0, M.t, M.stop_t and string.format("%.1f s", M.stop_t) or "-", M.sp, M.yaw, M.roll, M.slip, M.headMax or 0, M.minup,
    M.rimSlip, M.motorTicks, M.maxF, vc.R2.ebMax or -1, tostring(g.gear), tostring(g.rpm and math.floor(g.rpm)), r.fell and ", FELL" or "", table.concat(M.trace, " "))
  if not o.nat then V.stop(vc) end
  return r
end

function VF.coast_check(r, o)
  o = o or {}
  local ok = not r.fell and r.slip < (o.slip or 10) and r.yaw < (o.yaw or 0.6) and r.roll < (o.roll or 20)
  if o.stop then ok = ok and r.stop ~= nil end
  V.check("coast_" .. r.tag .. "_" .. r.v, ok, "let go at %.1f: fell %s, peak yaw %.2f rad/s, lean %.1f deg, slip %.1f deg, heading %.0f deg, stopped %s",
    r.v0 or -1, tostring(r.fell), r.yaw or -1, r.roll or -1, r.slip or -1, r.head or -1, r.stop and string.format("%.1f s", r.stop) or "no")
end

function VF_RUN.vcoast()
  local vc = JP.bike("coast")
  if not vc then return end
  if not JP.strip(vc, -15, 520) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 90, "the whole strip")
  VF_TICK = VF.coast_tick
  JP_TICK = function(dt) JP.hold_tick(dt) end
  for _, vt in ipairs(jsplit(params.speeds or "5,15,25")) do
    local r = VF.coast_run(vc, "flat", vt, { secs = 22 })
    VF.coast_check(r, { stop = vt <= 15 })
  end
  -- let go mid-turn: A held (a quarter) as W comes off
  local r = VF.coast_run(vc, "turn", 15, { steer = 0.25, secs = 8 })
  VF.coast_check(r, { yaw = 1.2 })
  -- the Brakes group left ON (B), W let go at 15 m/s: they catch at once
  set_brakes(vc, true)
  vc.R2.ebMax = 0
  local rb = VF.coast_run(vc, "brakes", 15, { secs = 8 })
  VF.coast_check(rb, { stop = true })
  set_brakes(vc, false)
  VF_TICK = nil
  V.result()
end

function VF_RUN.vcoastslope()
  local vc = JP.bike("coastslope")
  if not vc then return end
  if not JP.strip(vc, -15, 60) then return end
  -- …and on from 60 m down a 12 % grade to 330 m
  local S = V.strip
  local _, made = V.ground(vc, S.F, S.U, 60, 330, -0.12, S.rel0)
  S.d1 = 330
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 90, "the slope")
  VFL("slope: %d sculpts; profile %s", made, JP.heights(vc, 0, 330, 30))
  VF_TICK = VF.coast_tick
  for _, vt in ipairs({ 10, 18 }) do
    local r = VF.coast_run(vc, "down", vt, { secs = 8 })
    VF.coast_check(r, {})
  end
  -- natural ground, four headings from where it stands
  JP_TICK = nil
  for k = 1, 4 do
    local r = VF.coast_run(vc, "nat" .. k, 15, { nat = true, secs = 10 })
    VF.coast_check(r, {})
    if r.fell then break end
    -- turned 90 deg for the next (stopped, full lock a moment)
    V.stop(vc)
    local t0 = time
    while time - t0 < 3 do vc.R2.cmd = { drive = 0.5, steer = 1 }; yield() end
    V.stop(vc)
  end
  VF_TICK = nil
  V.result()
end

-- ── runjump ─────────────────────────────────────────────────────────────────
-- Run-jumps on flat ground (playtest 2026-11-12b: "fall damage when running
-- and jumping on flat ground over and over"): sprinting with jump pressed
-- again the moment the feet are down (a bunny hop) or a few strides later
-- (landing mid-stride), sets of 8 in a row from a start spot, 56+ landings
-- per load (0 and 85 kg) on the base's graded apron and on open ground. Every
-- Δv the fall monitor judges (crew.impactRule wrapped), every kill (blocked,
-- logged) and any hp lost. `VF LAND` for each landing judged over 5 m/s,
-- `VF RUNJUMP` per load and spot, checks: no hp lost, nothing over impact_injure.
VF.K = { dv = {}, kills = {} }
function VF.wrap_crew()
  local C = findScript("crew")
  if C.__vf then return C end
  C.__vf = true
  local orig = C.impactRule
  C.impactRule = function(dv)
    if dv > 0.5 then VF.K.dv[#VF.K.dv + 1] = dv end
    return orig(dv)
  end
  local okill = C.kill
  C.kill = function(id, cause, detail, opts)
    if VF.K.block then
      VF.K.kills[#VF.K.kills + 1] = string.format("%s(%s)", tostring(cause), tostring(detail))
      VFL("KILL blocked: #%s %s %s", tostring(id), tostring(cause), tostring(detail))
      return false
    end
    return okill(id, cause, detail, opts)
  end
  return C
end
function VF.set_pack(kg)
  local inv = findScript("inventory")
  if not inv then return 0 end
  inv.clear("astro")
  if kg > 0 then
    local cap = inv.cap and inv.cap("astro") or 90
    if cap < kg + 1 and inv.setCap then inv.setCap("astro", kg + 10) end
    inv.add("astro", "regolith", math.floor(kg / 1.8 + 0.5))
  end
  return inv.mass("astro")
end
function VF.put_rel(p)
  local A = astro()
  local b = home()
  A.x, A.y, A.z = b.x + p.x, b.y + p.y, b.z + p.z
  A.vx, A.vy, A.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(0.25) end
end
function VF.hp()
  local C = findScript("crew")
  local r = C.get(C.activeId())
  return r and r.hp or 1
end
-- one set: sprint from p, `n` landings, jump at once (hop) or `stride` s after
-- touching down; → the landings judged and the worst Δv
function VF.jump_set(tag, p, n, stride, heading)
  local pw = findScript("planet_walker")
  VF.put_rel(p)
  pw.steer(0, 0, false)
  wait(0.6)
  local seq0 = pw.impactSeq or 0
  local lands, worst = 0, 0
  local t0, tdown = time, nil
  local last_seq = seq0
  local lastdv = #VF.K.dv
  local rng = 0
  while lands < n and time - t0 < 30 do
    local t = time - t0
    local jump = false
    if pw.grounded then
      tdown = tdown or time
      rng = (rng * 1103515245 + 12345) % 2147483648
      local delay = stride and (stride * (0.5 + (rng % 1000) / 1000)) or 0
      jump = t > 0.8 and time - tdown >= delay
    else
      tdown = nil
    end
    pw.steer(1, heading or 0, true, jump)
    yield()
    if (pw.impactSeq or 0) ~= last_seq then
      last_seq = pw.impactSeq
      lands = lands + 1
      local A = astro()
      local sp = len(A.vx or 0, A.vy or 0, A.vz or 0)
      if (pw.impactRaw or 0) > 5 or (pw.impactSpeed or 0) > 5 then
        VFL("LAND %s #%d: raw %.2f judged by the walker %.2f (speed now %.2f, moveSpeed %.2f)", tag, lands, pw.impactRaw or -1, pw.impactSpeed or -1, sp, pw.moveSpeed or -1)
      end
    end
  end
  pw.steer(0, 0, false)
  wait(0.5)
  for k = lastdv + 1, #VF.K.dv do worst = math.max(worst, VF.K.dv[k]) end
  return lands, worst
end
-- a spot whose ground leans `lo`..`hi` degrees, 40-160 m from the start:
-- its body-relative centre 1 m up and the uphill way (body frame), or nil
function VF.hill_spot(lo, hi)
  local b = home()
  local A = astro()
  local u0 = unit(sub(A, b))
  local t1 = unit(cross(u0, math.abs(u0.y) < 0.9 and { x = 0, y = 1, z = 0 } or { x = 1, y = 0, z = 0 }))
  local t2 = cross(u0, t1)
  local R = len(A.x - b.x, A.y - b.y, A.z - b.z)
  for _, d in ipairs({ 40, 60, 80, 110, 140, 160 }) do
    for k = 0, 15 do
      local a = k * math.pi / 8
      local th = d / R
      local dir = unit({ x = u0.x * math.cos(th) + (t1.x * math.cos(a) + t2.x * math.sin(a)) * math.sin(th),
                         y = u0.y * math.cos(th) + (t1.y * math.cos(a) + t2.y * math.sin(a)) * math.sin(th),
                         z = u0.z * math.cos(th) + (t1.z * math.cos(a) + t2.z * math.sin(a)) * math.sin(th) })
      local o = vec3(b.x + dir.x * (R + 120), b.y + dir.y * (R + 120), b.z + dir.z * (R + 120))
      local h = terrain.raycast(o, vec3(-dir.x, -dir.y, -dir.z), 400)
      if h and h.normal then
        local n = unit({ x = h.normal.x, y = h.normal.y, z = h.normal.z })
        local deg = math.deg(math.acos(clamp(dot(n, dir), -1, 1)))
        local cl = findScript("climate")
        local wet = cl and cl.isUnderwater and cl.isUnderwater(h.pos.x, h.pos.y + 0.5, h.pos.z)
        if deg >= lo and deg <= hi and not wet then
          local upw = unit(sub(scl(dir, dot(n, dir)), n))   -- the uphill way: −n's part along the ground
          local p = { x = h.pos.x - b.x + dir.x, y = h.pos.y - b.y + dir.y, z = h.pos.z - b.z + dir.z }
          return p, upw, deg
        end
      end
    end
  end
  return nil
end
function VF.runjump_at(tag, p, kgs, headings)
  local C = findScript("crew")
  local pw = findScript("planet_walker")
  local pc = findScript("planet_camera")
  local inj = C.params and C.params.impact_injure or 9
  local bad = 0
  for _, kg in ipairs(kgs) do
    local m = VF.set_pack(kg)
    wait(0.6)
    VF.K.dv, VF.K.kills = {}, {}
    local hp0 = VF.hp()
    local lands, worst, k = 0, 0, 0
    local t0 = time
    while lands < (tonumber(params.lands) or 56) and time - t0 < 140 do
      k = k + 1
      local hd = headings and headings[(k - 1) % #headings + 1]
      if hd and pc and pc.face then pcall(pc.face, hd.x, hd.y, hd.z, -0.1) end
      local stride = (k % 2 == 0) and 0.3 or nil
      local l, w = VF.jump_set(tag, p, 8, stride, hd and 0 or ({ 0, 0.35, -0.35, 0 })[(k % 4) + 1])
      lands, worst = lands + l, math.max(worst, w)
    end
    local lost = hp0 - VF.hp()
    local over = 0
    for _, d in ipairs(VF.K.dv) do if d > inj then over = over + 1 end end
    VFL("RUNJUMP %s %d kg (pack %.1f, encumbrance %.2f): %d landings in %d sets, worst Δv judged %.2f m/s, %d over %.1f, hp lost %.3f, kills %d %s",
      tag, kg, m, pw.encumbrance or -1, lands, k, worst, over, inj, lost, #VF.K.kills, table.concat(VF.K.kills, ","))
    V.check("runjump_" .. tag .. "_" .. kg, lost <= 0 and over == 0 and #VF.K.kills == 0 and lands >= 50,
      "%d landings, worst %.2f m/s, hp lost %.3f", lands, worst, lost)
    if lost > 0 then C.patch(C.activeId(), { hp = 1.0 }) end
  end
end
function VF.runjump_setup()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = VF.wrap_crew()
  C.setSafety("death")
  VF.K.block = true
  local pw = findScript("planet_walker")
  if pw.bump then pw.bump = function() end end
  return C
end
function VF_RUN.runjump()
  VF.runjump_setup()
  local A, b = astro(), home()
  VF.runjump_at("apron", { x = A.x - b.x, y = A.y - b.y, z = A.z - b.z }, jsplit(params.kgs or "0,85"))
  V.result()
end
function VF_RUN.runjumpopen()
  VF.runjump_setup()
  local b = home()
  local _, rock = find_spots()
  local gr = rock and ground_r(b, rock.dir.x, rock.dir.y, rock.dir.z, b.radius + 300)
  if not gr then V.check("open_spot", false, "no open ground"); V.result(); return end
  local p = scl(rock.dir, gr + 1.0)
  VF.runjump_at("open", p, jsplit(params.kgs or "0,85"))
  -- a real fall still hurts: 14 m onto it
  local u = unit(p)
  VF.set_pack(0)
  VF.put_rel({ x = p.x + u.x * 14, y = p.y + u.y * 14, z = p.z + u.z * 14 })
  VF.K.dv = {}
  local hp0 = VF.hp()
  wait(5)
  local mx = 0
  for _, d in ipairs(VF.K.dv) do mx = math.max(mx, d) end
  VFL("FALL 14 m: max Δv %.2f, hp lost %.3f, kills %d", mx, hp0 - VF.hp(), #VF.K.kills)
  V.check("fall_still_hurts", hp0 - VF.hp() > 0 or #VF.K.kills > 0, "14 m: Δv %.2f, hp lost %.3f", mx, hp0 - VF.hp())
  V.result()
end
function VF_RUN.runjumphill()
  VF.runjump_setup()
  local p, upw, deg = VF.hill_spot(tonumber(params.hlo) or 12, tonumber(params.hhi) or 26)
  if not p then V.check("hill_spot", false, "no slope found"); V.result(); return end
  VFL("hill: %.0f deg", deg)
  local dn = scl(upw, -1)
  local side = unit(cross(upw, unit(p)))
  VF.runjump_at("hill", p, jsplit(params.kgs or "0,85"), { upw, dn, side, scl(side, -1) })
  V.result()
end

-- ── crewshove ───────────────────────────────────────────────────────────────
-- Crew on foot against a piloted rover (playtest 2026-11-12b: "party members
-- walking into a rover push it around wildly while you pilot"). The stock
-- rover out past 95 m, stopped, piloted; a second crew member set down 6 m to
-- its side, then:
--   through  walked to a point 6 m past the rover's far side (the straight
--            line runs through it): the rover's displacement and peak speed
--   board    walked to the rover's middle as SC5R.board's walk does (near
--            2.0): did the walk end at the hull (arrived), how far it pushed
--   drive    the rover driven at ~2 m/s into the member standing: the
--            rover's speed lost, the member moved out of its way
-- `VF SHOVE` per part; checks: the rover moved < 0.15 m by the walks.
function VF.rover_rel(vn)
  local b = home()
  local c = assembly.info(vn).com
  return { x = c.x - b.x, y = c.y - b.y, z = c.z - b.z }
end
function VF.shove_watch(vc, secs, fn)
  local vn = vc.node
  local p0 = VF.rover_rel(vn)
  local maxd, maxv = 0, 0
  local t0 = time
  while time - t0 < secs do
    if fn and fn(time - t0) then break end
    vc.R2.cmd = vc.R2.cmd or { drive = 0, steer = 0 }
    yield()
    local p = VF.rover_rel(vn)
    maxd = math.max(maxd, len(p.x - p0.x, p.y - p0.y, p.z - p0.z))
    local v = assembly.info(vn).vel
    maxv = math.max(maxv, len(v.x, v.y, v.z))
  end
  return maxd, maxv
end
function VF_RUN.crewshove()
  wait_ready(90)
  wait(2)
  clear_weather()
  V.tag = "crewshove"
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then V.check("rollout", false, "no rover"); V.result(); return end
  vc.releaseClamps()
  wait(2)
  V.out(vc, 95)
  V.stop(vc)
  wait(1)
  local C = findScript("crew")
  local me = C.activeId()
  local other
  for _, r in ipairs(C.roster()) do if r.id ~= me and r.status ~= "dead" and not other then other = r.id end end
  if not other and C.hire then pcall(C.hire, 1, { free = true }); for _, r in ipairs(C.roster()) do if r.id ~= me and r.status ~= "dead" and not other then other = r.id end end end
  if not other then V.check("second_crew", false, "no second crew member"); V.result(); return end
  local vn = vc.node
  local function frame()
    local i = assembly.info(vn)
    local U = V.up(i.com)
    local F = V.fwdW(vc)
    F = unit(sub(F, scl(U, dot(F, U))))
    local S = unit(cross(U, F))
    return i.com, U, F, S
  end
  local function ground_at(w, U)
    local h = raycast(w.x + U.x * 4, w.y + U.y * 4, w.z + U.z * 4, -U.x, -U.y, -U.z, 12, { ignore = { vn } })
    if h then return { x = h.x + U.x * 1.0, y = h.y + U.y * 1.0, z = h.z + U.z * 1.0 } end
    return { x = w.x, y = w.y, z = w.z }
  end
  local function place_other(side)
    local c, U, F, S = frame()
    local w = ground_at({ x = c.x + S.x * side, y = c.y + S.y * side, z = c.z + S.z * side }, U)
    C.setDown(other, w.x, w.y, w.z)
    wait(2.0)
  end
  local function cb_of()
    for _, s in ipairs(findScripts("crew_body")) do if s.memberId == other and s.doll ~= true then return s end end
  end
  -- 1. through
  place_other(6)
  local cb = cb_of()
  if not cb then V.check("crew_body", false, "no body for #%s", tostring(other)); V.result(); return end
  -- (A/B: yieldoff=1 the craft contact off, as before the fix)
  local function ab(c2) if c2 and c2.YIELD and (tonumber(params.yieldoff) or 0) > 0 then c2.YIELD.on = false end end
  ab(cb)
  VFL("SHOVE craft contact %s", (tonumber(params.yieldoff) or 0) > 0 and "OFF (A/B)" or "on")
  local y0 = cb.yieldStats and { blocked = cb.yieldStats.blocked, arrived = cb.yieldStats.arrived, pushed = cb.yieldStats.pushed } or {}
  local c, U, F, S = frame()
  local tgt = ground_at({ x = c.x - S.x * 6, y = c.y - S.y * 6, z = c.z - S.z * 6 }, U)
  local b = home()
  local trel = { x = tgt.x - b.x, y = tgt.y - b.y, z = tgt.z - b.z }
  local d1, v1 = VF.shove_watch(vc, 14, function()
    cb.steerSelf(C.get(other).body, trel.x, trel.y, trel.z, { speed = 1.5, arrive = 0.3 })
    return false
  end)
  local ys = cb.yieldStats or {}
  VFL("SHOVE through: rover moved %.3f m, peak speed %.2f m/s; crew blocked %d ticks, arrived %d, pushed %d", d1, v1,
    (ys.blocked or 0) - (y0.blocked or 0), (ys.arrived or 0) - (y0.arrived or 0), (ys.pushed or 0) - (y0.pushed or 0))
  V.check("shove_through", d1 < 0.15 and v1 < 0.5, "rover moved %.3f m, %.2f m/s", d1, v1)
  if cb.steerStop then cb.steerStop() end
  -- 2. board: to the rover's middle, near 2.0 (SC5R.board's walk)
  place_other(6)
  cb = cb_of() or cb
  ab(cb)
  local arrived = false
  local d2, v2 = VF.shove_watch(vc, 14, function(t)
    local cc = assembly.info(vn).com
    local bb = home()
    if t > 0.3 and cb.arrived and cb.arrived() and not (cb.walking and cb.walking()) then arrived = true; return true end
    cb.steerSelf(C.get(other).body, cc.x - bb.x, cc.y - bb.y, cc.z - bb.z, { speed = 1.5, arrive = 2.0 })
    return false
  end)
  VFL("SHOVE board: rover moved %.3f m, peak speed %.2f m/s; walk ended at the hull %s", d2, v2, tostring(arrived))
  V.check("shove_board", d2 < 0.15 and arrived, "rover moved %.3f m, arrived %s", d2, tostring(arrived))
  if cb.steerStop then cb.steerStop() end
  -- 3. drive into them, standing 5 m ahead
  local cc, U2, F2 = frame()
  local w = ground_at({ x = cc.x + F2.x * 5, y = cc.y + F2.y * 5, z = cc.z + F2.z * 5 }, U2)
  C.setDown(other, w.x, w.y, w.z)
  wait(2.0)
  local r0 = C.get(other)
  ab(cb_of())
  local pushed0 = (cb_of() or cb).yieldStats and (cb_of() or cb).yieldStats.pushed or 0
  local vmin, vpk = 99, 0
  local d3 = VF.shove_watch(vc, 8, function(t)
    local sp = V.speed(vc)
    vc.R2.cmd = { drive = (sp < 2.0) and 0.35 or 0.0, steer = 0 }
    if t > 3 then vpk = math.max(vpk, sp); vmin = math.min(vmin, sp) end
    return false
  end)
  local r1 = C.get(other)
  local moved = len((r1.x or 0) - (r0.x or 0), (r1.y or 0) - (r0.y or 0), (r1.z or 0) - (r0.z or 0))
  local cbn = cb_of() or cb
  VFL("SHOVE drive: rover ran %.1f m, speed %.2f..%.2f after 3 s; the member moved %.2f m out of its way (pushed %d ticks)", d3, vmin, vpk, moved,
    (cbn.yieldStats and cbn.yieldStats.pushed or 0) - pushed0)
  V.check("shove_drive", vmin > 0.5 and moved > 0.3, "rover speed %.2f..%.2f, member moved %.2f m", vmin, vpk, moved)
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.result()
end

-- ── bayfix ──────────────────────────────────────────────────────────────────
-- The repair bay and a wreck (playtest 2026-11-12b: "a craft an old astronaut
-- crashed, brought to the repair bay, can't be repaired"). The player's bike
-- put in the bay, the rider stepped off at the console; its saddle (the
-- crewed part) broken with vessel_controller.hitPart, as a crash breaks it:
-- the craft is lost (isLost). Does the bay see it, quote the rebuild, and
-- does the service make it a craft again (its saddle whole, not lost, a seat
-- to sit in)? Plus a worn wheel on the same order. Pictures in user://vehfix/.
function VF.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true }, function(bytes)
    if bytes then assets.writeBytes("user://vehfix/" .. nm .. ".png", bytes); VFL("SHOT %s", nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function VF_RUN.bayfix()
  local vc = JP.bike("bay")
  if not vc then return end
  local vn = vc.node
  local fac = wait_for(function() return find("FacRepair") end, 30, "the repair bay")
  local rb = fac and fac:getScript("repair_bay")
  rb = wait_for(function() return rb and rb.worldOf and rb.worldOf(0, 0, 0) and rb end, 10, "the bay's script")
  if not rb then V.check("bay", false, "no FacRepair"); V.result(); return end
  local function child(n, name) for _, c in ipairs(n:children()) do if c.name == name then return c end end end
  local fl, cl = child(fac, "Bay Floor"), child(fac, "Repair Console")
  for _ = 1, 3 do
    local x, y, z = rb.worldOf(fl.x, fl.y + 1.0, fl.z - 1.0)
    assembly.teleport(vn, vec3(x, y, z))
    wait(1.5)
    local o = assembly.info(vn).origin
    local qx, _, qz = rb.localOf(o.x, o.y, o.z)
    if math.abs(qx - fl.x) < 3 and math.abs(qz - fl.z) < 5 then break end
  end
  V.stop(vc)
  local cx, cy, cz = rb.worldOf(cl.x - 0.3, cl.y + 1.0, cl.z)
  vc.standDown(vn, cx, cy, cz, 0, 0, 0)
  wait(1.5)
  -- a worn wheel and the saddle broken
  local saddle, wheel
  for _, d in ipairs(vc.fleetParts().parts) do
    if d.id == "saddle" then saddle = d.uid end
    if (d.id or ""):match("^wheel") and not wheel then wheel = d.uid end
  end
  if wheel then vc.wearPart(wheel, 0.5) end
  local o = assembly.info(vn).origin
  vc.hitPart(saddle, 5.0, o.x, o.y + 1.0, o.z)
  wait(2.0)
  local lost = vc.isLost()
  local wm = vc.wreckMendable and vc.wreckMendable()
  wait(1.0)
  VFL("BAY wreck: lost %s, mendable %s; the bay has %s, prompt %q", tostring(lost), wm and wm.label or "no", tostring(rb.insideName), tostring(rb.prompt))
  V.check("bay_sees_wreck", lost and wm ~= nil and rb.insideName ~= nil, "lost %s, inside %s", tostring(lost), tostring(rb.insideName))
  local cam = findScript("planet_camera")
  local rp = vn.worldPos
  if cam and cam.face then pcall(cam.face, rp.x - astro().x, rp.y - astro().y, rp.z - astro().z, -0.25) end
  wait(0.6)
  VF.shot("bay_1_wreck")
  local q = rb.quoteFor(vc)
  local cm = findScript("context_menu")
  rb.openOrder()
  wait(0.8)
  VF.shot("bay_2_order")
  local rows = {}
  for _, e in ipairs(cm.entries()) do
    local val = type(e.value) == "function" and e.value() or e.value or ""
    rows[#rows + 1] = (e.label or "") .. "=" .. tostring(val)
  end
  VFL("BAY order: %s", table.concat(rows, " | "))
  V.check("bay_quotes_rebuild", q.wreck ~= nil and not q.nothing, "wreck line %s, total $%d", q.wreck and q.wreck.label or "none", q.total or -1)
  local co = findScript("company")
  local b0 = co.balance()
  local jobs0 = rb.jobs or 0
  local pressed = cm.press("service")
  wait_for(function() return (rb.jobs or 0) > jobs0 end, 40, "the job")
  wait(1.0)
  cm.close()
  local hp = vc.partHp and vc.partHp(saddle)
  local worn = #(vc.damagedParts() or {})
  local free = vc.freeSeat and vc.freeSeat(nil)
  VFL("BAY after: pressed %s, lost %s, saddle hp %s, worn parts %d, free seat %s, paid $%d (quoted $%d), %s", tostring(pressed), tostring(vc.isLost()),
    tostring(hp), worn, tostring(free), b0 - co.balance(), q.total, tostring(rb.lastJob))
  V.check("bay_mends_wreck", pressed and not vc.isLost() and hp == 1 and worn == 0 and free ~= nil, "lost %s, saddle %s, worn %d", tostring(vc.isLost()), tostring(hp), worn)
  -- and it rides again: board it and drive 3 s
  local C = findScript("crew")
  do
    local sx, sy, sz = vc.partPointNow(saddle, 0, 0, 0, true)
    local i = assembly.info(vn)
    local R = i.right
    local A = astro()
    if sx and R then A.x, A.y, A.z = sx + R.x * 0.9, sy + R.y * 0.9, sz + R.z * 0.9; A.vx, A.vy, A.vz = 0, 0, 0 end
    if C.quietMonitors then C.quietMonitors(1.0) end
    wait(0.8)
  end
  local _, okb = pcall(function() return vc.boardNow and vc.boardNow() end)
  wait(1.5)
  local t0 = time
  local vmax = 0
  while time - t0 < 3 do vc.R2.cmd = { drive = 0.5, steer = 0 }; yield(); vmax = math.max(vmax, math.abs(V.speed(vc))) end
  vc.R2.cmd = { drive = 0, steer = 0 }
  VFL("BAY ride: boarded %s, piloting %s, top %.2f m/s", tostring(okb), tostring(vc.piloting), vmax)
  V.check("bay_rides_again", vc.piloting and vmax > 1.0, "piloting %s, %.2f m/s", tostring(vc.piloting), vmax)
  VF.shot("bay_3_mended")
  V.result()
end
-- one load a run (a loaded machine runs few landings a minute): rj0 / rj85 on
-- the base's apron and open ground by turns, 56 landings
function VF.rj(kg)
  VF.runjump_setup()
  local b = home()
  local A = astro()
  local apron = { x = A.x - b.x, y = A.y - b.y, z = A.z - b.z }
  local _, rock = find_spots()
  local gr = rock and ground_r(b, rock.dir.x, rock.dir.y, rock.dir.z, b.radius + 300)
  local open = gr and scl(rock.dir, gr + 1.0) or apron
  params.lands = 28
  VF.runjump_at("apron", apron, { kg })
  VF.runjump_at("open", open, { kg })
  V.result()
end
VF_RUN.rj0 = function() VF.rj(0) end
VF_RUN.rj85 = function() VF.rj(85) end
