-- ── jump probe (tools/perf/jumpprobe.sh): the 2026-11 playtest's vehicle fixes ──
-- Spliced after ivaprobe_modes.lua and verifyprobe_modes.lua (uses V.*). The
-- player's bike (user://probe_dirtbike.json), out past 95 m, on a flattened strip:
--   vjump   kickers along the strip, each taken at its own speed (strs `speeds`,
--           default "8,12,15", and a bigger drop at `bigv`): W held to the lip
--           (the real key, so the air stick sees it), hands off the bars from
--           the lip to 2.5 s after touchdown. Every tick from the lip a
--           `JP T` line (roll, the lean asked, the bars, yaw rate, roll torque,
--           tyres down, pitch, suspension); per jump a `JP R` summary: air time,
--           peak roll / yaw after touchdown, settle time, fell.
--   vbrake  from 10 m/s: coast, brakes (B) alone, brakes + S held, S alone;
--           then from a standstill with the brakes on: S held (reverse), W held.
--           `JP B` lines: the deceleration and how far it ran.
--   vlight  the base at night (warped to it on foot), the bike out, the
--           Floodlight on (Y): pictures from behind the rider and from the side,
--           the lamp's beam against the bike's front, the lights in the shader.
-- `VP PASS|FAIL` lines and `VP RESULT`; pictures in $WORK/proj/save/user/vshots/.
local JP = {}
local function jsplit(s) local t = {}; for x in tostring(s):gmatch("[^,]+") do t[#t + 1] = tonumber(x) end; return t end

-- the bike's roll (+ left), pitch (+ nose up) and yaw rate (+ left), from its own axes
function JP.att(vc)
  local vn = vc.node
  local info = assembly.info(vn)
  local U = V.up(info.com)
  local Fw = V.fwdW(vc)
  local B = vn:worldUp()
  B = unit({ x = B.x, y = B.y, z = B.z })
  local d = dot(Fw, U)
  local Fl = unit(sub(Fw, scl(U, d)))
  local R = unit(cross(Fl, U))
  local roll = math.atan2(-dot(B, R), dot(B, U))
  local pitch = math.asin(clamp(d, -1, 1))
  local w = info.angVel
  local yaw = w.x * U.x + w.y * U.y + w.z * U.z
  local rr = -(w.x * Fl.x + w.y * Fl.y + w.z * Fl.z)
  return roll, pitch, yaw, rr, U, Fl
end
function JP.down(vc)
  local f, r = 0, 0
  for _, w in ipairs(vc.R2.wheels or {}) do
    if w.tyre and w.tyre.valid and w.tyre.grounded then if (w.a or 0) > 0 then f = 1 else r = 1 end end
  end
  return f, r
end
-- where the bike is along / across the strip (planet frame)
-- (in the strip's own measure: V.ground and JP.kicker place d at the
-- direction of rel0 + F d, so d is the tangent's, not the projection on it;
-- on the home world, R ~1 km, the projection read 283 m at the 295 m kicker
-- and the lip was "reached" after the bike had landed)
function JP.along(vc)
  local S = V.strip
  local c = sub(assembly.info(vc.node).com, home())
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local u, u0 = unit(c), unit(S.rel0)
  local L = unit(cross(S.U, S.F))
  local k = R0 / math.max(1e-3, dot(u, u0))
  return dot(u, S.F) * k, dot(u, L) * k
end
-- a kicker: grade g over len m from d0 (on the sphere through the strip's start)
function JP.kicker(d0, len_, g)
  local S = V.strip
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local L = unit(cross(S.U, S.F))
  local made = 0
  for pass = 1, 3 do
    local d = d0
    while d <= d0 + len_ + 1e-6 do
      local bb = home()
      local r = { x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d }
      local Ud = unit(r)
      local h = (d - d0) * g
      local p = { x = bb.x + Ud.x * (R0 + h), y = bb.y + Ud.y * (R0 + h), z = bb.z + Ud.z * (R0 + h) }
      local nn = unit(sub(Ud, scl(S.F, g)))
      for _, lat in ipairs({ -1.2, 0, 1.2 }) do
        local q = { x = p.x + L.x * lat, y = p.y + L.y * lat, z = p.z + L.z * lat }
        if pass <= 2 then terrain.sculpt(q.x, q.y, q.z, 1.5, 1.0, "raise") end
        terrain.sculpt(q.x, q.y, q.z, 1.7, 1.0, "flatten", { normal = vec3(nn.x, nn.y, nn.z) })
        made = made + 1
      end
      d = d + 0.6
    end
  end
  -- …and a clean drop behind the lip: the ground back down to the strip
  local d = d0 + len_ + 1.6
  while d <= d0 + len_ + 4.5 do
    local bb = home()
    local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
    local p = { x = bb.x + Ud.x * R0, y = bb.y + Ud.y * R0, z = bb.z + Ud.z * R0 }
    for _, lat in ipairs({ -1.0, 0, 1.0 }) do
      local q = { x = p.x + L.x * lat, y = p.y + L.y * lat, z = p.z + L.z * lat }
      terrain.sculpt(q.x, q.y, q.z, 1.0, 1.0, "flatten", { normal = vec3(Ud.x, Ud.y, Ud.z) })
      made = made + 1
    end
    d = d + 0.5
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "kicker")
  wait(0.5)
  return made
end
-- heights over the strip's sphere along the centreline, d0..d1
function JP.heights(vc, d0, d1, step)
  local S = V.strip
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local out = {}
  local d = d0
  while d <= d1 + 1e-6 do
    local bb = home()
    local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
    local p = { x = bb.x + Ud.x * (R0 + 8), y = bb.y + Ud.y * (R0 + 8), z = bb.z + Ud.z * (R0 + 8) }
    local h = raycast(p.x, p.y, p.z, -Ud.x, -Ud.y, -Ud.z, 20, { ignore = { vc.node } })
    out[#out + 1] = string.format("%.1f:%.2f", d, h and (8 - h.distance) or -99)
    d = d + step
  end
  return table.concat(out, " ")
end
local function hold_w(on)
  if on and not JP.w then key_down("w"); JP.w = true elseif not on and JP.w then key_up("w"); JP.w = nil end
end
local function susp(vc)
  local t = {}
  for _, w in ipairs(vc.R2.wheels or {}) do
    local tn = w.tyre
    local j = tn and tn.valid and tn:getcomponent("Joint")
    local rim = j and (j.speed or 0) / 57.29578 * (w.r or 0.3) * (w.rs or 1) or 0
    t[#t + 1] = string.format("%.3f:%.1f:%.1f:%s", (w.susp and w.susp.comp) or 0, rim, (w.susp and w.susp.dampF) or 0, tostring(j and j.motor))
  end
  return table.concat(t, "/")
end
-- line follow + cruise: the drive and steer that hold the strip's centreline at vt
function JP.cruise(vc, vt, hands)
  local sp = V.speed(vc)
  local _, lat = JP.along(vc)
  local drive = clamp(0.25 + (vt - sp) * 0.6 + vt / 16, 0, 1)
  local st = 0
  if hands then
    -- heading toward the centreline 12 m ahead (assembly.info's vel is
    -- already the craft's against the ground it rides: V.speed reads it so)
    local S = V.strip
    local i = assembly.info(vc.node)
    local U = V.up(i.com)
    local vr = i.vel
    local vh = sub(vr, scl(U, dot(vr, U)))
    local L = unit(cross(S.U, S.F))
    local head = (len(vh.x, vh.y, vh.z) > 1.0) and math.atan2(dot(vh, L), dot(vh, S.F)) or 0
    -- (the look-ahead grows with speed: at a fixed 12 m the lean's lag made
    -- the line swing ±2.8 m at 15 m/s, off the 3 m strip and past the kicker)
    local want = clamp(math.atan2(-lat, math.max(12, 1.6 * sp)), -0.5, 0.5)
    st = clamp(1.2 * (want - head), -0.5, 0.5)
  end
  return drive, st
end

-- one jump: from where it is to the kicker at k.d0, at k.v; logged to k.d0 + 60
function JP.jump(vc, k)
  local tag = k.tag
  local t0 = time
  local lip = k.d0 + k.len
  local air, td, t_lip, t_air0 = false, nil, nil, nil
  local peak_roll, peak_yaw, peak_bars, settle, fell = 0, 0, 0, 0, false
  local roll_lip, yaw_lip, pitch_lip, v_lip, pitch_td, roll_td, yaw_td, v_td
  local airtime = 0
  local log_next = 0
  local n_sign, last_sign = 0, 0
  local v_min
  while time - t0 < 40 do
    local d, lat = JP.along(vc)
    local hands = (d < k.d0 - 3) or (td and time - td > 2.5)
    local drive, st = JP.cruise(vc, k.v, hands)
    -- airoff=1: the throttle shut from the lip to touchdown + 1 s
    if (params.airoff or 0) > 0 and t_lip and not (td and time - td > 1.0) then drive = 0 end
    vc.R2.cmd = { drive = drive, steer = st }
    hold_w(drive > 0.5 and not td)
    yield()
    local roll, pitch, yaw, rr = JP.att(vc)
    local f, r = JP.down(vc)
    local sp = V.speed(vc)
    if not t_lip and d >= lip - 0.3 then t_lip = time; roll_lip, yaw_lip, pitch_lip, v_lip = roll, yaw, pitch, sp end
    if t_lip and not air and f + r == 0 then air = true; t_air0 = time end
    if air and not td and f + r > 0 then
      td = time; airtime = time - t_air0
      roll_td, yaw_td, pitch_td, v_td = roll, yaw, pitch, sp
    end
    if not t_lip and time >= (JP.alog or 0) then
      -- (alog: the approach's log interval, s; default 0.5)
      JP.alog = time + (tonumber(params.alog) or 0.5)
      P("JP A %s d %.1f lat %.2f v %.2f roll %.1f yaw %.3f st %.2f served %.2f lk %.2f drive %.2f pitch %.1f gr %d%d comp %s", tag, d, lat, sp, math.deg(roll), yaw, st,
        vc.R2.served or -1, vc.R2.lk or -1, vc.R2.drive or 0, math.deg(pitch), f, r, susp(vc))
      JP.p0 = pitch
    end
    if t_lip and time >= log_next then
      log_next = time + 1 / 30
      local R2 = vc.R2
      P("JP T %s t %.3f d %.1f lat %.2f v %.2f roll %.1f rr %.2f leanT %.1f bars %.2f yaw %.3f tq %.2f gr %d%d pitch %.1f comp %s drive %.2f",
        tag, time - t_lip, d, lat, sp, math.deg(roll), rr, math.deg(R2.leanT or 0), R2.bikeSteer or 0, yaw, R2.bikeTorque or 0, f, r,
        math.deg(pitch), susp(vc), R2.drive or 0)
    end
    if td and time - td <= 2.5 then
      local dt_ = time - td
      peak_roll = math.max(peak_roll, math.abs(roll))
      peak_yaw = math.max(peak_yaw, math.abs(yaw))
      peak_bars = math.max(peak_bars, math.abs(vc.R2.bikeSteer or 0))
      if math.abs(roll) > math.rad(3) or math.abs(yaw) > 0.15 or f + r == 0 or math.abs(pitch) > math.rad(5) then settle = dt_ end
      v_min = math.min(v_min or sp, sp)
      local sg = roll > math.rad(1) and 1 or (roll < -math.rad(1) and -1 or 0)
      if sg ~= 0 and sg ~= last_sign then if last_sign ~= 0 then n_sign = n_sign + 1 end; last_sign = sg end
    end
    if td and time - td > 4.0 then break end
    if V.upness(vc.node) < 0.5 then fell = true; break end
    if not t_lip and time - t0 > 30 then break end
    if t_lip and not air and time - t_lip > 2.0 then break end   -- it never left the ground
  end
  hold_w(false)
  local r = { tag = tag, v = k.v, kick = string.format("%.0f%% x %.1f m", k.g * 100, k.len), v_lip = v_lip, air = airtime,
    pitch_lip = pitch_lip and math.deg(pitch_lip), pitch_td = pitch_td and math.deg(pitch_td), roll_td = roll_td and math.deg(roll_td),
    yaw_td = yaw_td, peak_roll = math.deg(peak_roll), peak_yaw = peak_yaw, peak_bars = peak_bars, settle = settle, swings = n_sign, fell = fell, landed = td ~= nil, vloss = (v_td or 0) - (v_min or v_td or 0), lat = select(2, JP.along(vc)) }
  P("JP R %s v %.0f kicker %s: lip %.1f m/s, air %.2f s, pitch lip %.1f td %.1f, roll td %.1f, yaw td %.3f | after: peak roll %.1f deg, peak yaw %.2f rad/s, peak bars %.1f, settle %.2f s, roll swings %d, speed lost %.1f m/s, fell %s, lat %.1f",
    tag, k.v, r.kick, v_lip or -1, airtime, r.pitch_lip or -99, r.pitch_td or -99, r.roll_td or -99, yaw_td or -99, r.peak_roll, peak_yaw, peak_bars, settle, n_sign, r.vloss, tostring(fell), r.lat)
  return r
end

function JP.bike(name)
  V.tag = name
  local bp = V.dirtbike()
  if not bp then V.check("craft", false, "no craft file"); V.result(); return end
  local seat
  for _, d in ipairs(bp.parts) do if (d.seat == 1 or d.seat == true) then seat = d.uid end end
  local vc = iv_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = "Dirt Bike", controls = bp.controls, groups = bp.groups, turned = bp.turned },
    "runway", seat and { { uid = seat, slot = 1, id = 1 } } or nil)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  wait(2)
  vc.releaseClamps()
  wait(2)
  local i = assembly.info(vc.node)
  P("JP bike: mass %.3f t, %d wheels, bike %s, wheelbase %.2f, hcg %.2f, gyros %d, rider %s", i.mass or -1, #(vc.R2.wheels or {}), tostring(vc.R2.bike),
    vc.R2.wheelbase or -1, vc.R2.plan and vc.R2.plan.hcg or -1, #(vc.R2.gyros or {}), tostring(vc.R2.rider))
  return vc
end
function JP.strip(vc, from_d, to_d)
  local okout = V.out(vc, 95)
  V.stop(vc)
  if not okout then V.check("out", false, "fell on the way out"); V.result(); return false end
  local U = V.up(assembly.info(vc.node).com)
  local F = V.fwdW(vc)
  F = unit(sub(F, scl(U, dot(F, U))))
  local rel0, made = V.ground(vc, F, U, from_d, to_d, 0)
  V.strip = { rel0 = rel0, F = F, U = U }
  P("JP flat strip %d..%d m: %d sculpts", from_d, to_d, made)
  V.stop(vc)
  return true
end

local function run_vjump()
  local vc = JP.bike("jump")
  if not vc then return end
  local speeds = jsplit(params.speeds or "8,12,15")
  local bigv = tonumber(params.bigv or 12)
  local kicks = {}
  local d = 45
  for _, v in ipairs(speeds) do
    if v >= 14 then d = d + 50 end   -- (the last few m/s come slowly)
    kicks[#kicks + 1] = { tag = "small" .. v, v = v, d0 = d, len = 4.0, g = tonumber(params.kg or 0.22) }; d = d + 100
  end
  if bigv > 0 then kicks[#kicks + 1] = { tag = "big" .. bigv, v = bigv, d0 = d, len = 5.5, g = tonumber(params.bg or 0.32) }; d = d + 100 end
  if not JP.strip(vc, -15, d - 20) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the whole strip")
  P("JP strip profile (every 20 m): %s", JP.heights(vc, 0, d - 20, 20))
  for _, k in ipairs(kicks) do
    local made = JP.kicker(k.d0, k.len, k.g)
    P("JP kicker %s at %.0f m: %d sculpts; profile %s", k.tag, k.d0, made, JP.heights(vc, k.d0 - 2, k.d0 + k.len + 3, 1.0))
  end
  local res = {}
  for _, k in ipairs(kicks) do
    local r = JP.jump(vc, k)
    res[#res + 1] = r
    if r.fell then P("JP fell at %s: the rest is skipped", k.tag); break end
  end
  for _, r in ipairs(res) do
    V.check("jump_" .. r.tag, r.landed and not r.fell and r.settle < 1.2 and r.peak_roll < 12 and math.abs(r.lat or 0) < 4,
      "%s at %.0f m/s (lip %.1f, air %.2f s): peak roll %.1f deg, peak yaw %.2f rad/s, settled (both tyres down, pitch, roll, yaw) in %.2f s, %d roll swings, %.1f m/s lost%s",
      r.kick, r.v, r.v_lip or -1, r.air, r.peak_roll, r.peak_yaw, r.settle, r.swings, r.vloss or 0, r.fell and ", FELL" or "")
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.result()
end

-- ── vride ───────────────────────────────────────────────────────────────────
-- The straight-line ride on the flat strip: at each of `speeds` (strs, default
-- "8,12,15") a 30 m lead-in and then `seg` m (default 100) held on the line,
-- hands on; then full W for `topsecs` s (default 10) for the top speed. Per
-- segment a `JP RIDE` line: tyre-off ticks (front, rear, both) and how many
-- times a tyre left the ground, pitch (sd, peak), roll peak, yaw rate peak,
-- the bars' sd and the suspension's travel (min..max) each end.
local function ride_seg(vc, tag, vt, lead, seg, full)
  local d0 = JP.along(vc)
  local n, offF, offR, both, events = 0, 0, 0, 0, 0
  local lastF, lastR = 1, 1
  local sp_, sp2, pmax, rmax, ymax, b1, b2, vmax = 0, 0, 0, 0, 0, 0, 0, 0
  local cmin, cmax = { 9, 9 }, { -9, -9 }
  local t0 = time
  while true do
    local d = JP.along(vc)
    local drive, st = JP.cruise(vc, vt, true)
    if full then drive = 1 end
    vc.R2.cmd = { drive = drive, steer = st }
    hold_w(drive > 0.5)
    yield()
    local roll, pitch, yaw = JP.att(vc)
    local f, r = JP.down(vc)
    if V.upness(vc.node) < 0.5 then hold_w(false); return { fell = true } end
    local sp = V.speed(vc)
    local measuring = (full and time - t0 > 0) or (not full and d - d0 >= lead)
    if measuring then
      n = n + 1
      if f == 0 then offF = offF + 1 end
      if r == 0 then offR = offR + 1 end
      if f + r == 0 then both = both + 1 end
      if (f == 0 and lastF == 1) or (r == 0 and lastR == 1) then events = events + 1 end
      sp_, sp2 = sp_ + pitch, sp2 + pitch * pitch
      pmax, rmax, ymax = math.max(pmax, math.abs(pitch)), math.max(rmax, math.abs(roll)), math.max(ymax, math.abs(yaw))
      local bs = vc.R2.bikeSteer or 0
      b1, b2 = b1 + bs, b2 + bs * bs
      vmax = math.max(vmax, sp)
      for i, w in ipairs(vc.R2.wheels or {}) do
        local c = w.susp and w.susp.comp
        if c and i <= 2 then cmin[i], cmax[i] = math.min(cmin[i], c), math.max(cmax[i], c) end
      end
    end
    -- (rtrace = v: every tick of that segment's measure, the tyres' gap to
    -- the ground under them (m), their speed along the local up and the
    -- suspension: what lifts a tyre on the flat)
    if measuring and (tonumber(params.rtrace) or -1) == vt and n <= 240 then
      local U = V.up(assembly.info(vc.node).com)
      local g = {}
      for _, w in ipairs(vc.R2.wheels or {}) do
        local tn = w.tyre
        if tn and tn.valid then
          local p = tn.tickPos or tn.worldPos
          local h = raycast(p.x + U.x * 0.5, p.y + U.y * 0.5, p.z + U.z * 0.5, -U.x, -U.y, -U.z, 3, { ignore = { vc.node, tn } })
          local tv = tn.vel or { x = 0, y = 0, z = 0 }
          g[#g + 1] = string.format("%.3f:%.2f:%.3f", h and (h.distance - 0.5 - (w.r or 0.3)) or -9, dot(tv, U), (w.susp and w.susp.comp) or 0)
        end
      end
      P("JP RT %s %d gr %d%d pitch %.2f vup %.3f | %s", tag, n, f, r, math.deg(pitch), dot(assembly.info(vc.node).vel, U), table.concat(g, " "))
    end
    -- (rlog = s: a line that often through every segment)
    if (tonumber(params.rlog) or 0) > 0 and time >= (JP.rlog_t or 0) then
      JP.rlog_t = time + tonumber(params.rlog)
      P("JP RL %s d %.1f lat %.2f v %.2f roll %.1f pitch %.1f yaw %.3f bars %.2f gr %d%d drive %.2f comp %s", tag, d, select(2, JP.along(vc)), sp, math.deg(roll),
        math.deg(pitch), yaw, vc.R2.bikeSteer or 0, f, r, vc.R2.drive or 0, susp(vc))
    end
    lastF, lastR = f, r
    if full and time - t0 >= (tonumber(params.topsecs) or 10) then break end
    if not full and d - d0 >= lead + seg then break end
    if time - t0 > 60 then break end
  end
  hold_w(false)
  local function sd(a, a2) return n > 1 and math.sqrt(math.max(0, a2 / n - (a / n) ^ 2)) or 0 end
  P("JP RIDE %s v %.0f: %d ticks, tyre off front %d rear %d both %d, %d lift-offs, pitch sd %.2f peak %.1f deg, roll peak %.1f deg, yaw peak %.3f, bars sd %.3f, top %.2f m/s, comp F %.3f..%.3f R %.3f..%.3f, lat %.1f",
    tag, vt, n, offF, offR, both, events, math.deg(sd(sp_, sp2)), math.deg(pmax), math.deg(rmax), ymax, sd(b1, b2), vmax,
    cmin[1], cmax[1], cmin[2], cmax[2], select(2, JP.along(vc)))
  return { events = events, both = both, vmax = vmax }
end
local function run_vride()
  local vc = JP.bike("ride")
  if not vc then return end
  local speeds = jsplit(params.speeds or "8,12,15")
  local seg = tonumber(params.seg or 100)
  local total = #speeds * (30 + seg) + 200
  if not JP.strip(vc, -15, total) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the whole strip")
  P("JP strip profile (every 20 m): %s", JP.heights(vc, 0, total, 20))
  P("JP strip ripple (every 0.5 m, 100..130): %s", JP.heights(vc, 100, 130, 0.5))
  P("JP strip far (every 1 m): %s", JP.heights(vc, total - 230, total, 1.0))
  local ok = true
  for _, v in ipairs(speeds) do
    local r = ride_seg(vc, "v" .. v, v, 30, seg, false)
    if r.fell then P("JP RIDE v%d: FELL", v); ok = false; break end
  end
  if ok then
    local r = ride_seg(vc, "top", 99, 0, 0, true)
    if r.fell then P("JP RIDE top: FELL"); ok = false end
  end
  V.check("ride", ok, "rode every segment upright")
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.result()
end

-- ── vbrake ──────────────────────────────────────────────────────────────────
local function brakes_on(vc)
  local any
  for _, w in ipairs(vc.R2.wheels or {}) do
    local E = findScript("electronics")
    local st = E and E.stateOf and E.stateOf(w.d) or {}
    any = any or st.brakes == true
  end
  return any == true
end
local function set_brakes(vc, on)
  for _ = 1, 3 do
    if brakes_on(vc) == on then return true end
    tap("b"); wait(0.2)
  end
  return brakes_on(vc) == on
end
function JP.brake_test(vc, tag, v0, brk, dcmd, secs)
  -- up to v0 on the line
  local t0 = time
  set_brakes(vc, false)
  while time - t0 < 15 and V.speed(vc) < v0 do
    local drive, st = JP.cruise(vc, v0 + 1, true)
    vc.R2.cmd = { drive = 1, steer = st }
    yield()
  end
  local sp0 = V.speed(vc)
  local d0 = JP.along(vc)
  local okb = set_brakes(vc, brk)
  local t1 = time
  local vs = {}
  local stop_t
  while time - t1 < secs do
    local _, st = JP.cruise(vc, 0, true)
    vc.R2.cmd = { drive = dcmd, steer = st }
    yield()
    local sp = V.speed(vc)
    if not stop_t and sp < 0.3 then stop_t = time - t1 end
    if #vs < 1 or time - t1 >= #vs * 0.5 then vs[#vs + 1] = string.format("%.2f", sp) end
    if V.upness(vc.node) < 0.5 then break end
    if stop_t and time - t1 > stop_t + 0.3 then break end
  end
  local sp1 = V.speed(vc)
  local run = JP.along(vc) - d0
  local el = time - t1
  local a = (sp0 - sp1) / math.max(el, 1e-3)
  P("JP B %s: brakes %s (%s) stick %.0f from %.2f m/s: %.2f m/s after %.2f s, stopped at %s s, ran %.1f m, mean decel %.2f m/s2 | v: %s",
    tag, tostring(brk), tostring(okb), dcmd, sp0, sp1, el, stop_t and string.format("%.2f", stop_t) or "-", run, a, table.concat(vs, " "))
  vc.R2.cmd = { drive = 0, steer = 0 }
  return { a = a, stop = stop_t, run = run, v1 = sp1 }
end
function JP.from_still(vc, tag, dcmd, secs)
  V.stop(vc)
  local ok = set_brakes(vc, true)
  local d0 = JP.along(vc)
  local t1 = time
  local vmax = 0
  while time - t1 < secs do
    local _, st = JP.cruise(vc, 0, true)
    vc.R2.cmd = { drive = dcmd, steer = st }
    yield()
    vmax = math.max(vmax, math.abs(V.speed(vc)))
  end
  local run = JP.along(vc) - d0
  P("JP B %s: brakes on (%s), stick %.0f from a standstill for %.1f s: speed %.2f m/s (max %.2f), ran %.2f m", tag, tostring(ok), dcmd, secs, V.speed(vc), vmax, run)
  vc.R2.cmd = { drive = 0, steer = 0 }
  return { v = V.speed(vc), run = run }
end
local function run_vbrake()
  local vc = JP.bike("brake")
  if not vc then return end
  if not JP.strip(vc, -15, 330) then return end
  local coast = JP.brake_test(vc, "coast", 10, false, 0, 3)
  local b = JP.brake_test(vc, "brakes", 10, true, 0, 6)
  local bs = JP.brake_test(vc, "brakes+S", 10, true, -1, 6)
  local s = JP.brake_test(vc, "S", 10, false, -1, 6)
  local rev = JP.from_still(vc, "brakes,S still", -1, 3)
  local fwd = JP.from_still(vc, "brakes,W still", 1, 3)
  set_brakes(vc, true)
  V.stop(vc)
  local park0 = JP.along(vc)
  wait(3)
  local creep = JP.along(vc) - park0
  set_brakes(vc, false)
  V.check("brake_plus_s", bs.a > b.a * 1.05 and bs.a >= s.a * 0.95, "brakes + S %.2f m/s2 against brakes %.2f, S %.2f, coast %.2f", bs.a, b.a, s.a, coast.a)
  V.check("brakes_no_lockout", rev.v < -0.8 and fwd.v > 0.8, "brakes on, from a standstill: S %.2f m/s, W %.2f m/s", rev.v, fwd.v)
  V.check("parked_brakes", math.abs(creep) < 0.3, "parked with the brakes on 3 s: crept %.2f m", creep)
  V.result()
end

-- ── vlight ──────────────────────────────────────────────────────────────────
local function star_up(p)
  local best, bmu = nil, -1
  for _, b in ipairs(space.bodies() or {}) do
    local key = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
    if key > bmu then best, bmu = b.name, key end
  end
  local s = best and space.body(best)
  if not s then return 1 end
  local U = V.up(p)
  return dot(U, unit(sub(s, p)))
end
local function run_vlight()
  V.tag = "light"
  wait(3)
  local a = astro()
  local su = star_up(a)
  P("JP sun elevation at the base: %.2f", su)
  local t0 = W()
  local want = tonumber(params.night or -0.45)
  if su > want then
    space.warp(tonumber(params.nwarp or 500))
    while W() - t0 < 120 do
      wait(0.25)
      su = star_up(astro())
      if space.warp() < 2 then space.warp(tonumber(params.nwarp or 500)) end
      if su < want then break end
    end
    space.warp(1)
    wait(2)
  end
  P("JP night: sun elevation %.2f after %.1f s of warp", star_up(astro()), W() - t0)
  local vc = JP.bike("light")
  if not vc then return end
  local okout = V.out(vc, 95)
  V.stop(vc)
  set_brakes(vc, true)
  local i = assembly.info(vc.node)
  P("JP at the spot: sun elevation %.2f", star_up(i.com))
  local lamp
  local function scan(n, depth)
    for _, c in ipairs(n:children()) do
      if c.name == "Lamp" then lamp = c end
      if depth < 3 then scan(c, depth + 1) end
    end
  end
  scan(vc.node, 0)
  local pc = V.pc()
  local fw = V.fwdW(vc)
  local up = V.up(i.com)
  local right = unit(cross(fw, up))
  -- the player's own two views: the chase camera behind the rider and the
  -- seat view (a photo camera placed by script sat metres off the bike on a
  -- planet on its rails)
  local function shots(sfx)
    wait(0.4)
    V.shot("chase_" .. sfx, false)
    pc.setCockpit(true, vc, 1)
    pc.setSeatLook(0, -0.12)
    wait(0.8)
    V.shot("seat_" .. sfx, false)
    pc.setCockpit(false)
    wait(0.6)
  end
  shots("off")
  tap("y")
  wait(1.0)
  local pl = lamp and lamp:getcomponent("PointLight")
  P("JP lamp %s: intensity %s range %s spot %s", tostring(lamp ~= nil), tostring(pl and pl.intensity), tostring(pl and pl.range), tostring(pl and (pl.spotAngle or pl.spot)))
  if lamp then
    local o = lamp:toWorld(vec3(0, 0, 0))
    local f = unit(sub(lamp:toWorld(vec3(0, 0, -1)), o))
    P("JP beam: against the front %.3f, down %.1f deg, lamp %.2f m up", dot(f, fw), math.deg(math.asin(clamp(-dot(f, up), -1, 1))),
      (function() local h = raycast(o.x, o.y, o.z, -up.x, -up.y, -up.z, 10, { ignore = { vc.node } }); return h and h.distance or -1 end)())
    local h = raycast(o.x, o.y, o.z, f.x, f.y, f.z, 200, { ignore = { vc.node } })
    P("JP beam centre meets the ground at %s m", h and string.format("%.1f", h.distance) or "none (200 m)")
  end
  local c = perf.counts and perf.counts() or {}
  P("JP lights in the shader %s, dropped %s", tostring(c.lights), tostring(c.lightsDropped))
  shots("on")
  V.check("lamp_on", pl and (pl.intensity or 0) > 0, "lamp intensity %s", tostring(pl and pl.intensity))
  V.result()
end
