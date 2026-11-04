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
-- Which ends have a tyre on the ground, by the load the ground carries
-- (node.contactForce, engine card 0629: 0 in the tick the tyre leaves), and
-- that load at each end (kN). Before 0629 it was node.grounded; JP.gstat
-- counts the ticks the two disagree (a tyre `grounded` that carries nothing).
JP.gstat = { n = 0, odd = 0 }
function JP.down(vc)
  local f, r, lf, lr = 0, 0, 0, 0
  for _, w in ipairs(vc.R2.wheels or {}) do
    local t = w.tyre
    if t and t.valid then
      local cf = t.contactForce
      local on
      if cf ~= nil then on = cf > 0 else on = t.grounded == true; cf = 0 end
      if (t.grounded == true) ~= on then JP.gstat.odd = JP.gstat.odd + 1 end
      JP.gstat.n = JP.gstat.n + 1
      if (w.a or 0) > 0 then
        if on then f = 1 end
        lf = lf + cf
      else
        if on then r = 1 end
        lr = lr + cf
      end
    end
  end
  return f, r, lf, lr
end
-- the craft's weight here (kN): its mass × the local g
function JP.weight(vc)
  return (assembly.info(vc.node).mass or 0) * (vc.R2.gl or 9.8)
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
  JP.ids = {}
  for _, d in ipairs(bp.parts) do JP.ids[d.uid] = d.id; if (d.seat == 1 or d.seat == true) then seat = d.uid end end
  local vc = iv_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = "Dirt Bike", controls = bp.controls, groups = bp.groups, turned = bp.turned },
    "runway", seat and { { uid = seat, slot = 1, id = 1 } } or nil)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  -- A/B switches: ride2=0 the rider before BIKE_RIDE2; ftrav / rtrav the
  -- fork's and the swing arm's travel (m, as the wheel's Travel setting)
  if params.ride2 and tonumber(params.ride2) == 0 then vc.BIKE_RIDE2 = false end
  -- govoff=1: the gas governor off (GAS_SAFE_V nil), gov=v: set to v m/s
  if (tonumber(params.govoff) or 0) > 0 then vc.GAS_SAFE_V = nil elseif tonumber(params.gov) then vc.GAS_SAFE_V = tonumber(params.gov) end
  -- grip=k: the traction control's load cap (R2_GRIP_K, card 0629) at k; grip=0 off
  if tonumber(params.grip) then vc.R2_GRIP_K = (tonumber(params.grip) > 0) and tonumber(params.grip) or nil end
  for _, w in ipairs(vc.R2.wheels or {}) do
    local kind = w.susp and w.susp.m and w.susp.m.kind
    local tv = (kind == "fork" and tonumber(params.ftrav)) or (kind == "arm" and tonumber(params.rtrav)) or nil
    if tv then
      w.d.wcfg = type(w.d.wcfg) == "table" and w.d.wcfg or {}
      w.d.wcfg.travel = tv
    end
  end
  wait(2)
  vc.releaseClamps()
  wait(2)
  local i = assembly.info(vc.node)
  local tr = {}
  for _, w in ipairs(vc.R2.wheels or {}) do if w.susp then tr[#tr + 1] = string.format("%s %.2f", tostring(w.susp.m.kind), w.susp.travel or -1) end end
  P("JP bike: mass %.3f t, %d wheels, bike %s, wheelbase %.2f, hcg %.2f, gyros %d, rider %s, ride2 %s, gov %s, grip %s, travel %s", i.mass or -1, #(vc.R2.wheels or {}), tostring(vc.R2.bike),
    vc.R2.wheelbase or -1, vc.R2.plan and vc.R2.plan.hcg or -1, #(vc.R2.gyros or {}), tostring(vc.R2.rider), tostring(vc.BIKE_RIDE2), tostring(vc.GAS_SAFE_V), tostring(vc.R2_GRIP_K), table.concat(tr, ", "))
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
  V.strip = { rel0 = rel0, F = F, U = U, d1 = to_d }
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
  local ls, lpk, wt = 0, 0, JP.weight(vc)
  local g0 = JP.gstat.odd
  local t0 = time
  while true do
    local d = JP.along(vc)
    local drive, st = JP.cruise(vc, vt, true)
    if full then drive = 1 end
    vc.R2.cmd = { drive = drive, steer = st }
    hold_w(drive > 0.5)
    yield()
    local roll, pitch, yaw = JP.att(vc)
    local f, r, lf, lr = JP.down(vc)
    if V.upness(vc.node) < 0.5 then hold_w(false); return { fell = true } end
    local sp = V.speed(vc)
    local measuring = (full and time - t0 > 0) or (not full and d - d0 >= lead)
    if measuring then
      n = n + 1
      if f == 0 then offF = offF + 1 end
      if r == 0 then offR = offR + 1 end
      if f + r == 0 then both = both + 1 end
      if (f == 0 and lastF == 1) or (r == 0 and lastR == 1) then events = events + 1 end
      ls, lpk = ls + (lf + lr), math.max(lpk, lf + lr)
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
    -- (ttrace = n: every tick of the flat-out segment, up to n lines: the
    -- push the control lets out and why, the loads, the engine and the
    -- rider's torques — what lifts the front at speed)
    if full and (tonumber(params.ttrace) or 0) > 0 and n <= tonumber(params.ttrace) then
      local R = vc.R2
      local g = JP.gas(vc) or {}
      local rw
      for _, w in ipairs(R.wheels or {}) do if (w.a or 0) <= 0 then rw = w end end
      local j = rw and rw.tyre and rw.tyre.valid and rw.tyre:getcomponent("Joint")
      local rim = j and (j.speed or 0) / 57.29578 * (rw.r or 0.3) * (rw.rs or 1) or 0
      local A = vc.AERO and vc.AERO.hud or {}
      P("JP TT %.2f d %.1f lat %.2f v %.2f p %.1f r %.1f gs %.1f gr %d%d L %.2f/%.2f dr %.2f cap %.3f gA %.3f wt %.2f g%d %.0f mF %.0f rim %.2f vf %.2f lk %.2f ap %.3f pT %.3f aT %.3f aim %.1f lean %.2f drag %.3f ry %.2f sl %.1f tc %.2f sld %.2f spn %.2f",
        time - t0, d, select(2, JP.along(vc)), sp, math.deg(pitch), math.deg(roll), math.deg(math.asin(math.max(-1, math.min(1, R.gslope or 0)))), f, r, lf, lr, R.drive or 0,
        R.bikeCap or -1, (R.gripA or 0) / (R.gl or 9.8), R.wheelie_t or 0, g.gear or 0, g.rpm or 0, j and j.maxForce or -1, rim, R.vf or 0, R.lk or 0,
        R.aeroPitch or 0, R.pitchTq or 0, R.airPitchTq or 0, math.deg(R.airAim or 0), R.bikeLean or 0, A.drag or 0, yaw,
        math.deg(R.landSlope or 0), R.tcK or 0, R.tcSlide or 0, R.tcSpin or 0)
    end
    -- (rlog = s: a line that often through every segment)
    if (tonumber(params.rlog) or 0) > 0 and time >= (JP.rlog_t or 0) then
      JP.rlog_t = time + tonumber(params.rlog)
      P("JP RL %s d %.1f lat %.2f v %.2f roll %.1f pitch %.1f yaw %.3f bars %.2f gr %d%d drive %.2f comp %s", tag, d, select(2, JP.along(vc)), sp, math.deg(roll),
        math.deg(pitch), yaw, vc.R2.bikeSteer or 0, f, r, vc.R2.drive or 0, susp(vc))
    end
    lastF, lastR = f, r
    if full and time - t0 >= (tonumber(params.topsecs) or 10) then break end
    -- (the flat-out run stops 40 m short of the strip's end: past it the
    -- natural ground stands up like a wall, and at 29 m/s the bike hit it
    -- nose first, a "58 degree wheelie" that was a crash, 2026-11-04)
    if full and V.strip and V.strip.d1 and d > V.strip.d1 - 40 then P("JP RIDE %s: the strip ends at %.0f m, stopped at %.0f m", tag, V.strip.d1, d); break end
    if not full and d - d0 >= lead + seg then break end
    if time - t0 > 60 then break end
  end
  hold_w(false)
  local function sd(a, a2) return n > 1 and math.sqrt(math.max(0, a2 / n - (a / n) ^ 2)) or 0 end
  -- (load: the tyres' contactForce summed, mean and peak, in the craft's
  -- weights; `odd` the wheel-ticks node.grounded disagreed with it)
  P("JP RIDE %s v %.0f: %d ticks, tyre off front %d rear %d both %d, %d lift-offs, pitch sd %.2f peak %.1f deg, roll peak %.1f deg, yaw peak %.3f, bars sd %.3f, top %.2f m/s, comp F %.3f..%.3f R %.3f..%.3f, lat %.1f, load mean %.3f peak %.2f W (W %.3f kN), odd %d",
    tag, vt, n, offF, offR, both, events, math.deg(sd(sp_, sp2)), math.deg(pmax), math.deg(rmax), ymax, sd(b1, b2), vmax,
    cmin[1], cmax[1], cmin[2], cmax[2], select(2, JP.along(vc)), ls / math.max(1, n) / math.max(1e-6, wt), lpk / math.max(1e-6, wt), wt, JP.gstat.odd - g0)
  return { events = events, both = both, vmax = vmax }
end
local function run_vride()
  local vc = JP.bike("ride")
  if not vc then return end
  local speeds = jsplit(params.speeds or "8,12,15")
  local seg = tonumber(params.seg or 100)
  -- (the flat-out run's 30 m a second on top: on 200 m the 500 ran off the
  -- strip's end into the natural ground at 26 m/s)
  local total = #speeds * (30 + seg) + 80 + 40 * (tonumber(params.topsecs) or 10)
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

-- ── vhill ───────────────────────────────────────────────────────────────────
-- Power and hill climbing (playtest 2026-11: "bikes don't really feel like they
-- have much torque … they should be so much better at hill climbing"). Works
-- for any craft file (BIKE=…/rov1.json for the rover to compare against).
-- On the flat strip, one hill per grade (strs `grades`, default
-- "0.36,0.58,0.84,1.0": 20, 30, 40, 45 deg), each `hh` m high (default 2.5):
-- up at the grade, an 8 m plateau, down at 35%. Per hill:
--   speed  from 45 m back, cruise at `vat` (default 10) m/s, full stick from
--          3 m before the toe: the speed at the toe and the crest, the least on
--          the ramp, and the climb it sustains at speed,
--          a = (v_crest² − v_toe²) / 2s + g sin θ, as the steepest grade it
--          would hold its speed on (asin(a/g)) — momentum alone climbs 2.5 m
--   still  teleported back to `still0` m (default 1.3: the front tyre at the toe) short of the toe, stopped, full stick:
--          whether it makes the crest, how far up it got, the time
-- Both log the front tyre's time off the ground on the ramp and the worst
-- wheelie (pitch over the ramp's). Then, past the last hill, full stick from a
-- standstill for `topsecs` s (default 10): the time to 5, 10 and 15 m/s and the
-- top speed. `JP H` per attempt, `JP ACC`, and a `JP HILL` summary.
function JP.hill_h(k, d)
  local x = d - k.toe
  if x <= 0 then return 0 end
  local up = k.hh / k.g
  if x <= up then return x * k.g end
  if x <= up + 8 then return k.hh end
  return math.max(0, k.hh - (x - up - 8) * 0.35)
end
function JP.hill_build(vc, k)
  local S = V.strip
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local L = unit(cross(S.U, S.F))
  local up = k.hh / k.g
  local d_end = k.toe + up + 8 + k.hh / 0.35
  local made, worst = 0, 0
  for pass = 1, 14 do
    worst = 0
    local d = k.toe - 0.6
    while d <= d_end + 0.6 do
      local bb = home()
      local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
      local h = JP.hill_h(k, d)
      local x = d - k.toe
      local nn = Ud
      if x > 0 and x <= up then nn = unit(sub(Ud, scl(S.F, k.g)))
      elseif x > up + 8 and h > 0 then local e = scl(S.F, 0.35); nn = unit({ x = Ud.x + e.x, y = Ud.y + e.y, z = Ud.z + e.z }) end
      for _, lat in ipairs({ -1.2, 0, 1.2 }) do
        local top = { x = bb.x + Ud.x * (R0 + h + 10) + L.x * lat, y = bb.y + Ud.y * (R0 + h + 10) + L.y * lat, z = bb.z + Ud.z * (R0 + h + 10) + L.z * lat }
        local hit = raycast(top.x, top.y, top.z, -Ud.x, -Ud.y, -Ud.z, 30, { ignore = { vc.node } })
        local cur = hit and (h + 10 - hit.distance) or 0
        local q = { x = bb.x + Ud.x * (R0 + h) + L.x * lat, y = bb.y + Ud.y * (R0 + h) + L.y * lat, z = bb.z + Ud.z * (R0 + h) + L.z * lat }
        if h - cur > 0.12 then
          worst = math.max(worst, h - cur)
          local g = { x = bb.x + Ud.x * (R0 + cur) + L.x * lat, y = bb.y + Ud.y * (R0 + cur) + L.y * lat, z = bb.z + Ud.z * (R0 + cur) + L.z * lat }
          terrain.sculpt(g.x, g.y, g.z, 1.5, 1.0, "raise")
          made = made + 1
        end
        if h - cur < 0.6 then terrain.sculpt(q.x, q.y, q.z, 1.7, 1.0, "flatten", { normal = vec3(nn.x, nn.y, nn.z) }); made = made + 1 end
      end
      d = d + 0.6
    end
    wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "hill")
    wait(0.2)
    if worst < 0.15 and pass > 1 then break end
  end
  -- the ramp as built: its mean grade over the middle of the climb, the steepest 1.5 m
  local prof = {}
  local bb = home()
  local d = k.toe - 1
  while d <= k.toe + up + 1 do
    local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
    local p = { x = bb.x + Ud.x * (R0 + 12), y = bb.y + Ud.y * (R0 + 12), z = bb.z + Ud.z * (R0 + 12) }
    local hit = raycast(p.x, p.y, p.z, -Ud.x, -Ud.y, -Ud.z, 30, { ignore = { vc.node } })
    prof[#prof + 1] = { d = d, h = hit and (12 - hit.distance) or 0 / 0 }
    d = d + 0.25
  end
  local a, z
  for _, e in ipairs(prof) do
    if not a and e.d >= k.toe + 0.2 * up then a = e end
    if e.d <= k.toe + 0.85 * up then z = e end
  end
  k.mean = (a and z and z.d > a.d) and (z.h - a.h) / (z.d - a.d) or 0
  k.steep = 0
  for i = 1, #prof - 6 do
    local s = (prof[i + 6].h - prof[i].h) / (prof[i + 6].d - prof[i].d)
    if s == s then k.steep = math.max(k.steep, s) end
  end
  k.crest = k.toe + up
  k.d_end = d_end
  P("JP hill g %.2f (%.0f deg): %d sculpts, built mean %.2f (%.1f deg), steepest 1.5 m %.2f, worst short %.2f m; heights %s", k.g, math.deg(math.atan(k.g)), made,
    k.mean, math.deg(math.atan(k.mean)), k.steep, worst, JP.heights(vc, k.toe - 1, k.d_end + 1, 1.0))
end
-- the craft moved along the strip to d (level ground, stopped), square to
-- the strip again: JP.reset's hold (vbump). (It used to keep the heading it
-- had, and a bike that had wandered off the line's heading met the next
-- hill at an angle: the 125's 37° climb from 1.35 m/s, 2026-11-03.)
function JP.place(vc, d)
  if (tonumber(params.oldplace) or 0) == 0 then return JP.reset(vc, d) end
  local S = V.strip
  local i = assembly.info(vc.node)
  local bb = home()
  local c = sub(i.com, bb)
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local hc = len(c.x, c.y, c.z) - R0
  local _, lat = JP.along(vc)
  local L = unit(cross(S.U, S.F))
  local Ud = unit({ x = S.rel0.x + S.F.x * d + L.x * lat * 0, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
  local to = { x = Ud.x * (R0 + hc + 0.05), y = Ud.y * (R0 + hc + 0.05), z = Ud.z * (R0 + hc + 0.05) }
  local o = i.origin
  local dl = sub(to, c)
  assembly.teleport(vc.node, vec3(o.x + dl.x, o.y + dl.y, o.z + dl.z))
  wait(0.5)
  V.stop(vc)
end
-- ride the hill k from where it is: `still` from a stop at the toe, else at k.v
function JP.climb(vc, k, still)
  local t0 = time
  local tag = string.format("%s g%.2f", still and "still" or "speed", k.g)
  local v_toe, v_crest, v_min, t_toe, t_crest
  local best, foff, ftick, wmax, fell, stall_t = 0, 0, 0, 0, false, 0
  local slope = math.atan(k.mean > 0.05 and k.mean or k.g)
  local nextl = 0
  while time - t0 < 40 do
    local d = JP.along(vc)
    local sp = V.speed(vc)
    local drive, st = JP.cruise(vc, k.v, true)
    if still or d >= k.toe - 3 then drive = 1 end
    if t_crest then drive = (sp > 4) and -1 or 0.3 end
    vc.R2.cmd = { drive = drive, steer = st }
    hold_w(drive > 0.5)
    yield()
    sp = V.speed(vc)
    d = JP.along(vc)
    local _, pitch = JP.att(vc)
    local f, r = JP.down(vc)
    if not t_toe and d >= k.toe then t_toe, v_toe = time, sp end
    if t_toe and not t_crest then
      best = math.max(best, d)
      v_min = math.min(v_min or sp, sp)
      ftick = ftick + 1
      if f == 0 then foff = foff + 1 end
      -- (the ramp's pitch until the rear is on it, then the grade)
      if d > k.toe + 0.6 and d < k.crest - 0.6 then wmax = math.max(wmax, pitch - slope) end
      if sp < 0.25 then stall_t = stall_t + 1 / 60 else stall_t = 0 end
      if d >= k.crest - 0.2 then t_crest, v_crest = time, sp end
    end
    if (t_toe or (tonumber(params.happ) or 0) > 0) and time >= nextl then
      nextl = time + 0.25
      P("JP HT %s t %.2f d %.2f v %.2f pitch %.1f gr %d%d drive %.2f lk %.2f served %.2f tq %s cap %.2f tc %.2f sld %.2f spn %.2f", tag, time - (t_toe or time), d - k.toe, sp, math.deg(pitch), f, r,
        vc.R2.drive or 0, vc.R2.lk or 0, vc.R2.served or 0, tostring(vc.R2.tq_dbg), vc.R2.bikeCap or -1, vc.R2.tcK or 0, vc.R2.tcSlide or 0, vc.R2.tcSpin or 0)
    end
    if V.upness(vc.node) < 0.4 then fell = true; break end
    if t_toe and not t_crest and (stall_t > 1.2 or sp < -0.5) then break end
    if t_crest and d > k.d_end + 4 then break end
  end
  hold_w(false)
  vc.R2.cmd = { drive = 0, steer = 0 }
  local up = k.crest - k.toe
  local s = up / math.cos(slope)
  local ahold
  if v_crest and v_toe then
    local a = (v_crest ^ 2 - v_toe ^ 2) / (2 * s) + 9.8 * math.sin(slope)
    ahold = math.deg(math.asin(clamp(a / 9.8, -1, 1)))
  end
  local r = { tag = tag, top = t_crest ~= nil, fell = fell, v_toe = v_toe, v_crest = v_crest, v_min = v_min, t = t_crest and t_toe and (t_crest - t_toe),
    got = (best - k.toe) / math.max(up, 1e-3), foff = ftick > 0 and foff / ftick or 0, wmax = math.deg(wmax), ahold = ahold }
  P("JP H %s (built %.1f deg): %s, toe %.2f m/s, crest %s, least %.2f, %s up the ramp, front tyre off %.0f%% of the climb, worst wheelie %.1f deg%s%s",
    tag, math.deg(slope), r.top and "OVER" or (fell and "FELL" or "STALLED"), v_toe or -1, v_crest and string.format("%.2f", v_crest) or "-", v_min or -1,
    string.format("%.0f%%", 100 * math.min(1, r.got)), 100 * r.foff, r.wmax, r.t and string.format(", %.2f s toe to crest", r.t) or "",
    ahold and string.format(", holds its speed up to %.1f deg", ahold) or "")
  return r
end
-- the craft's gas (vessel_controller gasState), when it carries any
function JP.gas(vc)
  local ok, g = pcall(function() return vc.gasState and vc.gasState() end)
  if ok and g and ((g.cap or 0) > 0 or (g.engines or 0) > 0) then return g end
  return nil
end
-- THE FORCES ALONG THE ROAD (ftrace=1, every 0.5 s): the air's drag (the
-- aero model's, kN) and the six parts that drag most, the engine's push at
-- the wheel (auto_drive gasWheel: torque / r, and the traction control's cap
-- on it, the joint's maxForce), the slope's share, and what is left over
-- once m·a is taken off: the tyres' rolling loss and anything else unmodelled.
function JP.forces(vc, tag)
  local R2, AE = vc.R2, vc.AERO
  local i = assembly.info(vc.node)
  local m = i.mass or 0.4
  local h = AE and AE.hud or {}
  local M = AE and AE.model
  local parts = {}
  if M then
    for _, b in ipairs(M.bodies) do
      local f = math.sqrt((b.fx or 0) ^ 2 + (b.fy or 0) ^ 2 + (b.fz or 0) ^ 2)
      parts[#parts + 1] = { f = f, id = (JP.ids and JP.ids[b.uid] or "?") .. b.uid }
    end
    table.sort(parts, function(a, b) return a.f > b.f end)
  end
  local top = {}
  for k = 1, math.min(6, #parts) do top[#top + 1] = string.format("%s %.0f", parts[k].id, parts[k].f * 1000) end
  local AL = vc.autoLib and vc.autoLib()
  local push, cap, gtxt = 0, 0, ""
  for _, w in ipairs(R2.wheels or {}) do
    local j = w.tyre and w.tyre.valid and w.tyre:getcomponent("Joint")
    if w.gas and AL then
      local q = AL.gasWheel(w.gas.e.m, R2.vf or 0, w.r or 0.33, w.gas.teeth)
      local full = q.torque * (R2.rk or 1)
      push = push + full / (w.r or 0.33)
      cap = cap + math.min(full, j and j.maxForce or full) / (w.r or 0.33)
      local rim = j and (j.speed or 0) / 57.29578 * (w.r or 0.33) * (w.rs or 1) or 0
      local tgt = j and (j.motorSpeed or 0) / 57.29578 * (w.r or 0.33) * (w.rs or 1) or 0
      gtxt = gtxt .. string.format(" | gas %s g%d %.0f rpm full %.3f kN.m (%.2f kN) cap %.3f top %.1f rim %.2f tgt %.2f motor %s", w.gas.e.label or "?", q.gear, q.rpm,
        full, full / (w.r or 0.33), j and j.maxForce or -1, q.top, rim, tgt, tostring(j and j.motor))
    elseif j and j.motor == 1 and (j.maxForce or 0) > 0 then
      cap = cap + (j.maxForce or 0) / (w.r or 0.33)
      gtxt = gtxt .. string.format(" | elec mF %.3f", j.maxForce or 0)
    end
  end
  local g = 9.8
  local slope = (R2.gslope or 0) * g * m
  local ma = m * (R2.a_s or 0)
  local rest = cap - (h.drag or 0) - slope - ma
  P("JP F %s v %.2f a %.2f m %.3f | drag %.3f kN (rho %.3f q %.0f CdA %.2f m2) [%s] | push cap %.3f kN slope %.3f ma %.3f rest %.3f kN (%.3f g)%s",
    tag, V.speed(vc), R2.a_s or 0, m, h.drag or 0, h.rho or 0, h.q or 0, (h.q or 0) > 1 and (h.drag or 0) * 1000 / h.q or 0,
    table.concat(top, ", "), cap, slope, ma, rest, rest / (m * g), gtxt)
end
-- coast=s: after the run, the wheels let roll free that long (no engine
-- braking, no motors), the first half with the air off (AERO.scale = 0):
-- the tyres' rolling loss alone, then the air's on top of it.
function JP.coast(vc, secs)
  local R2 = vc.R2
  local was = {}
  for k, w in ipairs(R2.wheels or {}) do was[k] = w.coast; w.coast = true end
  vc.R2.cmd = { drive = 0, steer = 0 }
  local t0 = time
  local seg = {}
  local function mark(nm)
    seg[nm] = { t = time, v = V.speed(vc) }
  end
  vc.AERO.scale = 0
  wait(0.3)
  mark("a0")
  while time - t0 < secs * 0.5 do
    local _, st = JP.cruise(vc, 0, true); vc.R2.cmd = { drive = 0, steer = st }; yield()
    if time >= (JP.ft_t or 0) then JP.ft_t = time + 0.5; JP.forces(vc, "coast_noair") end
  end
  mark("a1")
  vc.AERO.scale = nil
  wait(0.3)
  mark("b0")
  while time - t0 < secs do
    local _, st = JP.cruise(vc, 0, true); vc.R2.cmd = { drive = 0, steer = st }; yield()
    if time >= (JP.ft_t or 0) then JP.ft_t = time + 0.5; JP.forces(vc, "coast_air") end
  end
  mark("b1")
  for k, w in ipairs(R2.wheels or {}) do w.coast = was[k] end
  local m = assembly.info(vc.node).mass or 0.4
  local function dec(a, b) return (seg[a].v - seg[b].v) / math.max(1e-3, seg[b].t - seg[a].t) end
  local da, db = dec("a0", "a1"), dec("b0", "b1")
  P("JP COAST no air %.2f -> %.2f m/s: %.3f m/s2 (%.3f kN, %.3f g) | with air %.2f -> %.2f: %.3f m/s2 (%.3f kN)", seg.a0.v, seg.a1.v, da, da * m, da / 9.8,
    seg.b0.v, seg.b1.v, db, db * m)
end
function JP.accel(vc, secs)
  local t0 = time
  local d0 = JP.along(vc)
  local g0 = JP.gas(vc)
  local gmax, gearmax = 0, 0
  local marks = {}
  local vmax, foff, n, pmax = 0, 0, 0, 0
  local p0
  while time - t0 < secs do
    local _, st = JP.cruise(vc, 99, true)
    vc.R2.cmd = { drive = 1, steer = st }
    hold_w(true)
    yield()
    local sp = V.speed(vc)
    local _, pitch = JP.att(vc)
    p0 = p0 or pitch
    local f = JP.down(vc)
    n = n + 1
    if f == 0 then foff = foff + 1 end
    pmax = math.max(pmax, pitch - p0)
    vmax = math.max(vmax, sp)
    for _, v in ipairs({ 5, 10, 15, 20 }) do if not marks[v] and sp >= v then marks[v] = time - t0 end end
    -- (atrace = s: a line every 0.1 s for the first that many seconds)
    if time - t0 < (tonumber(params.atrace) or 0) and time >= (JP.at_t or 0) then
      JP.at_t = time + 0.1
      local mf = {}
      for _, w in ipairs(vc.R2.wheels or {}) do
        local j = w.tyre and w.tyre.valid and w.tyre:getcomponent("Joint")
        mf[#mf + 1] = string.format("%.0f/%s", j and j.maxForce or -1, tostring(j and j.motor))
      end
      local g = JP.gas(vc)
      local roll_ = JP.att(vc)
      P("JP AT t %.2f v %.2f pitch %.1f roll %.1f susp %s gr %d%d drive %.2f a_s %.2f lk %.2f slope %.3f cap %.2f mF %s%s", time - t0, sp, math.deg(pitch - p0), math.deg(roll_), susp(vc), f, select(2, JP.down(vc)),
        vc.R2.drive or 0, vc.R2.a_s or 0, vc.R2.lk or 0, vc.R2.gslope or 0, vc.R2.bikeCap or -1, table.concat(mf, " "),
        g and string.format(" gas %.0f rpm g%d vf %.2f ap %.3f", g.rpm or 0, g.gear or 0, vc.R2.vf or 0, vc.R2.aeroPitch or 0) or "")
    end
    if (tonumber(params.ftrace) or 0) > 0 and time >= (JP.ft_t or 0) then JP.ft_t = time + 0.5; JP.forces(vc, "drive") end
    local g = JP.gas(vc)
    if g then gmax, gearmax = math.max(gmax, g.rpm or 0), math.max(gearmax, g.gear or 0) end
    if V.upness(vc.node) < 0.4 then P("JP ACC FELL"); break end
    -- (stopped 30 m short of the strip's end: the natural ground past it is a
    -- wall at 30 m/s, and a run that reached it read as a 20 degree wheelie)
    if V.strip and V.strip.d1 and JP.along(vc) > V.strip.d1 - 30 then P("JP ACC: the strip ends at %.0f m, stopped %.1f s in", V.strip.d1, time - t0); break end
  end
  hold_w(false)
  vc.R2.cmd = { drive = 0, steer = 0 }
  local g1 = JP.gas(vc)
  if g0 and g1 then
    local used, dt_ = (g0.left or 0) - (g1.left or 0), time - t0
    local lph = used / math.max(dt_, 1e-3) * 3600
    P("JP GAS %s: %.3f L in %.1f s full stick (%.2f L/h), rpm up to %.0f, gear up to %d; a full %.0f L tank lasts %.0f min at that, %s",
      g1.label or "engine", used, dt_, lph, gmax, gearmax, g1.cap or 0, (g1.cap or 0) / math.max(lph, 1e-6) * 60,
      string.format("%.2f / %.1f L left", g1.left or 0, g1.cap or 0))
  end
  local function m(v) return marks[v] and string.format("%.2f", marks[v]) or "-" end
  P("JP ACC from a stop, full stick %.0f s: 0-5 %s s, 0-10 %s s, 0-15 %s s, 0-20 %s s, top %.2f m/s, %.0f m, front tyre off %.0f%%, worst nose-up %.1f deg",
    secs, m(5), m(10), m(15), m(20), vmax, JP.along(vc) - d0, 100 * foff / math.max(1, n), math.deg(pmax))
  return { t15 = marks[15], vmax = vmax }
end
local function run_vhill()
  local vc = JP.bike("hill")
  if not vc then return end
  -- (A/B: blean, btop override vessel_controller's R2_BIKE lean and top)
  if vc.R2_BIKE then
    if params.blean then vc.R2_BIKE.lean = params.blean end
    if params.btop then vc.R2_BIKE.top = params.btop end
    P("JP R2_BIKE top %.1f lean %.2f tc %.2f", vc.R2_BIKE.top, vc.R2_BIKE.lean, vc.R2_BIKE.tc)
  end
  local grades = jsplit(params.grades or "0.36,0.58,0.84,1.0")
  local hh = tonumber(params.hh or 2.5)
  local vat = tonumber(params.vat or 10)
  local hills, d = {}, 55
  for _, g in ipairs(grades) do
    hills[#hills + 1] = { g = g, hh = hh, toe = d, v = vat }
    d = d + 80
  end
  local acc0 = d - 50
  -- (33 m a second of the flat run: the 500 covers 475 m in 16 s, and at 28
  -- it ran off the strip's end into the natural ground at 30 m/s)
  local total = acc0 + 20 + 40 * (tonumber(params.topsecs) or 10) + 25 * (tonumber(params.coast) or 0)
  if not JP.strip(vc, -15, total) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the whole strip")
  if (tonumber(params.acconly) or 0) > 0 then hills = {} end   -- (acconly=1: the flat run alone)
  for _, k in ipairs(hills) do JP.hill_build(vc, k) end
  local res = {}
  local ok = true
  JP.place(vc, acc0)
  -- (the strip there as flattened: real ground more than a metre off the
  -- plane is past the flatten's reach, and a run into it is no flat run)
  P("JP accel strip (every 10 m): %s", JP.heights(vc, acc0, total, 10))
  local acc = JP.accel(vc, tonumber(params.topsecs) or 10)
  if (tonumber(params.coast) or 0) > 0 then JP.coast(vc, tonumber(params.coast)) end
  V.stop(vc)
  for i, k in ipairs(hills) do
    JP.place(vc, k.toe - 45)
    local a = JP.climb(vc, k, false)
    if a.fell then ok = false; break end
    V.stop(vc)
    JP.place(vc, k.toe - (tonumber(params.still0) or 1.3))
    local b = JP.climb(vc, k, true)
    res[#res + 1] = { k = k, a = a, b = b }
    if b.fell then ok = false; break end
    V.stop(vc)
  end
  local t = {}
  for _, e in ipairs(res) do
    t[#t + 1] = string.format("%.0f°: speed %s%s still %s%s", math.deg(math.atan(e.k.mean)), e.a.top and "over" or (e.a.fell and "FELL" or string.format("%.0f%%", 100 * math.min(1, e.a.got))),
      e.a.ahold and string.format(" (holds %.0f°)", e.a.ahold) or "", e.b.top and "over" or (e.b.fell and "FELL" or string.format("%.0f%%", 100 * math.min(1, e.b.got))),
      e.b.t and string.format(" %.1fs", e.b.t) or "")
  end
  P("JP HILL %s: %s | 0-15 %s s, top %.1f m/s", V.tag, table.concat(t, " | "), acc and acc.t15 and string.format("%.2f", acc.t15) or "-", acc and acc.vmax or -1)
  V.check("hill", ok, "upright through every hill")
  V.result()
end

-- ── vlook ───────────────────────────────────────────────────────────────────
-- The seated rider's head follows the view (playtest 2026-11). The craft
-- (BIKE: the dirt bike's saddle, or rov1.json's Command Seat) at the launch
-- site, released.
--   1. the seat view (V) turned ahead, left, right and behind
--      (planet_camera setSeatLook), then the chase view: `JP LOOK` lines, the
--      seat script's lookState against the view's yaw in the seat's frame
--      (it follows ahead/left/right, lets go behind, eases in).
--   2. pictures: the chase camera turned to film the rider from their right
--      side and from their front quarter, the head told to follow a view
--      ahead / left / right of the seat instead of the camera's own
--      (command_seat lookFrom: a camera filming from the side IS a view to
--      the side). (A spawned photo camera draws the world but not the craft
--      or its rider on .1406, so the main camera films.)
local function seat_script(vc)
  for u, n in pairs(vc.R2.node or {}) do
    local cs = n.valid and n.getScript and n:getScript("command_seat")
    if cs and cs.riding then return cs, n end
  end
  return nil
end
local function run_vlook()
  local vc = JP.bike(params.looktag or "look")
  if not vc then return end
  wait(2)
  local pc = V.pc()
  local cs, sn = seat_script(vc)
  wait_for(function() cs, sn = seat_script(vc); return cs ~= nil end, 5, "seat")
  if not cs then V.check("seat", false, "no riding seat script"); V.result(); return end
  local function frame()
    local fwd, up, f2 = sn:worldRight(), sn:worldUp(), sn:worldForward()
    return fwd, up, { x = -f2.x, y = -f2.y, z = -f2.z }
  end
  local function report(nm, yaw_view)
    local ls = cs.lookState or {}
    P("JP LOOK %s: view yaw %.0f deg; head yaw %.1f pitch %.1f weight %.2f, chest twist %.1f deg (head bone %s)", nm, math.deg(yaw_view or 0), math.deg(ls.yaw or 0), math.deg(ls.pitch or 0), ls.w or -1,
      math.deg(ls.twist or 0), tostring(ls.head))
    return ls
  end
  local ok = true
  pc.setCockpit(true, vc, 1)
  for _, L in ipairs({ { "ahead", 0, -0.08 }, { "left", -1.1, -0.05 }, { "right", 1.1, -0.05 }, { "back", 2.9, 0.0 } }) do
    pc.setSeatLook(L[2], L[3])
    wait(1.2)
    local ls = report("seat_" .. L[1], L[2])
    -- (an open seat's view turns ±OPEN_YAW at most: "back" stays at that)
    if L[1] ~= "back" then
      local vy = math.max(-1.1, math.min(1.1, L[2]))
      ok = ok and ls.w and ls.w > 0.8 and math.abs((ls.yaw or 0) - vy) < math.rad(6)
    end
    V.shot("firstperson_" .. L[1], false)
  end
  pc.setSeatLook(0, 0)
  wait(1.0)
  pc.setSeatLook(0.8, 0.1)
  wait(0.15)
  local l1 = report("seat_easing", 0.8)
  wait(1.0)
  local l2 = report("seat_settled", 0.8)
  ok = ok and (l1.yaw or 0) < (l2.yaw or 0) + 1e-3
  pc.setCockpit(false)
  wait(1.5)
  do
    local fwd, up, right = frame()
    local f = { x = pc.fwd_x, y = pc.fwd_y, z = pc.fwd_z }
    local ls = report("chase", math.atan2(dot(f, right), dot(f, fwd)))
    V.shot("chase_as_is", false)
  end
  -- the pictures
  for _, C in ipairs({ { "side", 0, -1 }, { "front", -0.8, -0.6 } }) do
    local fwd, up, right = frame()
    local d = unit({ x = fwd.x * C[2] + right.x * C[3], y = fwd.y * C[2] + right.y * C[3], z = fwd.z * C[2] + right.z * C[3] })
    pc.face(d.x, d.y, d.z, -0.12)
    pc.setCamMode("chase")
    wait(1.0)
    for _, L in ipairs({ { "ahead", 0 }, { "left", -1.1 }, { "right", 1.1 } }) do
      cs.lookFrom = function()
        local fw, _, rt = frame()
        local c, s_ = math.cos(L[2]), math.sin(L[2])
        return fw.x * c + rt.x * s_, fw.y * c + rt.y * s_, fw.z * c + rt.z * s_
      end
      wait(1.2)
      report(C[1] .. "_" .. L[1], L[2])
      V.shot(C[1] .. "_" .. L[1], false)
    end
  end
  -- a view straight behind the rider: the head lets go
  cs.lookFrom = function()
    local fw = frame()
    return -fw.x, -fw.y, -fw.z
  end
  wait(1.5)
  local lb = report("behind", math.pi)
  ok = ok and (lb.w or 1) < 0.2
  cs.lookFrom = nil
  V.check("look", ok, "the head followed the seat view ahead, left and right, let go behind, and eased in")
  V.result()
end

-- ── vbump ───────────────────────────────────────────────────────────────────
-- FLIPS OVER ROUGH GROUND (playtest 9e675fb: "the slightest bumps when going
-- fast make entire bikes flip over"). On the flat strip: `bapp` m of
-- approach (default 110), then `bn` whoops (default 14: 0.10..`bhmax` m high,
-- default 0.30, 1.6-3.6 m long, 5-11 m apart, the same every run), then a
-- kicker (`bkg` grade, default 0.2, over 3.5 m; 0 = none) and a run-out.
-- Each of `speeds` (strs, default "15,20,24") is ridden `reps` times (default
-- 2), every pass from a standstill at the strip's start: the probe holds the
-- bike up in the air, square to the strip and still, and sets it down
-- (JP.reset: a pure hold in fixedUpdate, no teleport of its attitude), so a
-- fall costs one pass, not the run. A pass ends at a fall (upness < 0.5, or
-- roll or pitch past 50°), the probe catching it at once.
-- `JP BUMP` per pass: its speed into the whoops, the airborne hops, peak
-- pitch (off the ground's) and roll, the worst suspension, fell and where;
-- `JP BUMPS` the tally, falls of passes at each speed.
function JP.bumps()
  local B, seed = {}, 12345
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
  local d = tonumber(params.bapp or 110)
  local hmax = tonumber(params.bhmax or 0.30)
  for _ = 1, tonumber(params.bn or 14) do
    local w = 1.6 + 2.0 * rnd()
    B[#B + 1] = { d = d + w / 2, w = w, h = 0.10 + (hmax - 0.10) * rnd() }
    d = d + w + 5 + 6 * rnd()
  end
  return B, d
end
function JP.bump_h(B, d)
  local h = 0
  for _, b in ipairs(B) do
    local x = (d - b.d) / (b.w / 2)
    if math.abs(x) < 1 then h = math.max(h, b.h * 0.5 * (1 + math.cos(math.pi * x))) end
  end
  return h
end
-- the whoops built to their profile: raised where short, flattened to the
-- plane through the profile with its slope (hill_build's method, finer)
function JP.bumps_build(vc, B, d0, d1)
  local S = V.strip
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local L = unit(cross(S.U, S.F))
  local made, worst = 0, 0
  for pass = 1, 10 do
    worst = 0
    local d = d0
    while d <= d1 do
      local h = JP.bump_h(B, d)
      local sl = (JP.bump_h(B, d + 0.2) - JP.bump_h(B, d - 0.2)) / 0.4
      local bb = home()
      local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
      local nn = unit(sub(Ud, scl(S.F, sl)))
      for _, lat in ipairs({ -1.0, 0, 1.0 }) do
        local top = { x = bb.x + Ud.x * (R0 + 10) + L.x * lat, y = bb.y + Ud.y * (R0 + 10) + L.y * lat, z = bb.z + Ud.z * (R0 + 10) + L.z * lat }
        local hit = raycast(top.x, top.y, top.z, -Ud.x, -Ud.y, -Ud.z, 30, { ignore = { vc.node } })
        local cur = hit and (10 - hit.distance) or 0
        local off = h - cur
        if lat == 0 then worst = math.max(worst, math.abs(off)) end
        if off > 0.08 then
          local g = { x = bb.x + Ud.x * (R0 + cur) + L.x * lat, y = bb.y + Ud.y * (R0 + cur) + L.y * lat, z = bb.z + Ud.z * (R0 + cur) + L.z * lat }
          terrain.sculpt(g.x, g.y, g.z, 0.9, 0.6, "raise")
          made = made + 1
        end
        if math.abs(off) > 0.025 then
          local q = { x = bb.x + Ud.x * (R0 + h) + L.x * lat, y = bb.y + Ud.y * (R0 + h) + L.y * lat, z = bb.z + Ud.z * (R0 + h) + L.z * lat }
          terrain.sculpt(q.x, q.y, q.z, 0.9, 1.0, "flatten", { normal = vec3(nn.x, nn.y, nn.z) })
          made = made + 1
        end
      end
      d = d + 0.35
    end
    wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 25, "whoops")
    wait(0.2)
    P("JP whoops pass %d: worst %.1f cm off", pass, 100 * worst)
    if worst < 0.05 then break end
  end
  return made, worst
end
-- THE HOLD (fixedUpdate, JP_TICK): gravity taken off and the velocity damped
-- (the engine's, already the ground's: no positions mixed across frames),
-- the attitude brought square to the strip at d, critically damped.
function JP.hold_tick(dt)
  local H, vc = JP.HOLD, JP.vc
  if not (H and vc and vc.node and vc.node.valid) then return end
  local i = assembly.info(vc.node)
  if not (i and i.up and i.right) then return end
  local S = V.strip
  local m = i.mass or 0.4
  local U = V.up(i.com)
  local v, w = i.vel, i.angVel
  local g = H.g or 9.8
  local kd = 5.0
  -- (H.sink: of gravity let through, to set it down)
  local k = 1 - (H.sink or 0)
  assembly.force(vc.node, vec3(m * (g * k * U.x - kd * v.x), m * (g * k * U.y - kd * v.y), m * (g * k * U.z - kd * v.z)))
  local up = unit(i.up)
  local rt = unit(i.right)
  local Z = cross(rt, up)
  local F = vc.R2.fwd or { x = 1, z = 0 }
  local fw = unit({ x = rt.x * F.x + Z.x * F.z, y = rt.y * F.x + Z.y * F.z, z = rt.z * F.x + Z.z * F.z })
  local Ft = unit(sub(S.F, scl(U, dot(S.F, U))))
  local e1, e2 = cross(up, U), cross(fw, Ft)
  -- (facing backwards the cross is ~0: turn it about the up first)
  if dot(fw, Ft) < 0 then e2 = scl(U, (dot(cross(fw, Ft), U) >= 0) and 1 or -1) end
  local e = { x = e1.x + e2.x, y = e1.y + e2.y, z = e1.z + e2.z }
  local I = 0.35 * m
  local W = 4.0
  assembly.torque(vc.node, vec3(I * (W * W * e.x - 2 * W * w.x), I * (W * W * e.y - 2 * W * w.y), I * (W * W * e.z - 2 * W * w.z)))
  H.err = len(e.x, e.y, e.z)
  H.v = len(v.x, v.y, v.z)
  H.w = len(w.x, w.y, w.z)
end
JP_TICK = function(dt) JP.hold_tick(dt) end
-- put the bike at d on the strip's line, upright and square to it, still
function JP.reset(vc, d)
  local S = V.strip
  JP.vc = vc
  -- (the wear of the last pass mended: each pass starts on a whole bike, or
  -- the saddle wore through over a dozen passes and the craft was lost)
  if vc.damagedParts and vc.repairPart then
    local worn = {}
    for _, e in ipairs(vc.damagedParts()) do
      worn[#worn + 1] = string.format("%s %.2f", JP.ids and JP.ids[e.uid] or tostring(e.uid), e.hp)
      vc.repairPart(e.uid)
    end
    if #worn > 0 then P("JP worn (mended): %s", table.concat(worn, ", ")) end
  end
  JP.g = JP.g or vc.R2.gl or 9.8
  if not JP.hc0 then
    local i0 = assembly.info(vc.node)
    local c0 = sub(i0.com, home())
    JP.hc0 = len(c0.x, c0.y, c0.z) - len(S.rel0.x, S.rel0.y, S.rel0.z)
  end
  hold_w(false)
  vc.R2.cmd = { drive = 0, steer = 0 }
  vc.R2.motoOff = true
  vc.AERO.scale = 0
  JP.HOLD = { g = JP.g or 9.8 }
  wait(0.3)
  -- lifted clear over the strip at d (a translation: its attitude is the hold's)
  local i = assembly.info(vc.node)
  local bb = home()
  local R0 = len(S.rel0.x, S.rel0.y, S.rel0.z)
  local Ud = unit({ x = S.rel0.x + S.F.x * d, y = S.rel0.y + S.F.y * d, z = S.rel0.z + S.F.z * d })
  -- (0.3 m up, and down within ~2 s: past 2.5 s aloft the tyres fold in)
  local hh = R0 + (JP.hc0 or 0.9) + 0.3
  local to = { x = bb.x + Ud.x * hh, y = bb.y + Ud.y * hh, z = bb.z + Ud.z * hh }
  local dl = sub(to, i.com)
  local o = i.origin
  assembly.teleport(vc.node, vec3(o.x + dl.x, o.y + dl.y, o.z + dl.z))
  local t0 = time
  -- (square to the strip within a few degrees: a bike's own rest pitch is
  -- its wheels', not the hold's, and it takes it back on its tyres)
  while time - t0 < 1.4 do
    yield()
    local H = JP.HOLD
    if time - t0 > 0.6 and (H.err or 9) < 0.06 and (H.v or 9) < 0.15 and (H.w or 9) < 0.1 then break end
  end
  local held = time - t0
  -- set down: a third of gravity through, damped (~0.65 m/s)
  JP.HOLD.sink = 0.33
  local t1 = time
  while time - t1 < 2 do
    yield()
    local f, r = JP.down(vc)
    if f + r == 2 then break end
  end
  wait(0.4)
  JP.HOLD = nil
  vc.R2.motoOff = nil
  vc.AERO.scale = nil
  wait(0.8)
  V.stop(vc)
  local roll, pitch = JP.att(vc)
  local _, lat = JP.along(vc)
  P("JP reset to %.0f m: held %.1f s, down in %.1f s, roll %.1f pitch %.1f lat %.2f, upness %.3f", d, held, time - t1, math.deg(roll), math.deg(pitch), lat, V.upness(vc.node))
end
-- one pass: from the start at vt over the whoops and the kicker
function JP.bump_pass(vc, tag, vt, B, b0, b1, kick, dEnd)
  local t0 = time
  local inz, fell, fell_d = false, false, nil
  local v_in, hops, lastAir = nil, 0, false
  local pmax, rmax, airmax, air_t0 = 0, 0, 0, nil
  local cmax = { -9, -9 }
  local lpk, wt = { 0, 0 }, JP.weight(vc)
  local dmax = 0
  -- (by zone: the whoops' and the kicker's peak roll, the slide off the lip
  -- (m/s across the bike's own front while leaving the kicker) and, for a
  -- second after the kicker's landing, the rear's least load in weights)
  local rW, rK, vlatK, rearMin, landT = 0, 0, 0, 9, nil
  while time - t0 < 60 do
    local d = JP.along(vc)
    local drive, st = JP.cruise(vc, vt, true)
    vc.R2.cmd = { drive = drive, steer = st }
    hold_w(drive > 0.5)
    yield()
    d = JP.along(vc)
    dmax = math.max(dmax, d)
    local roll, pitch = JP.att(vc)
    local f, r, lf, lr = JP.down(vc)
    if not inz and d >= b0 - 1 then inz = true; v_in = V.speed(vc) end
    if inz then
      -- (pitch off the ground's: the whoops' slope under the wheelbase is
      -- small next to a bike going over, so off the local level)
      pmax = math.max(pmax, math.abs(pitch))
      rmax = math.max(rmax, math.abs(roll))
      local air = f + r == 0
      if air and not lastAir then hops = hops + 1; air_t0 = time end
      if air and air_t0 then airmax = math.max(airmax, time - air_t0) end
      if kick and d >= kick - 1 then
        rK = math.max(rK, math.abs(roll))
        local _, _, _, _, Uu, Fl = JP.att(vc)
        local Rt = unit(cross(Fl, Uu))
        if d <= kick + 6 then vlatK = math.max(vlatK, math.abs(dot(assembly.info(vc.node).vel, Rt))) end
        if lastAir and not air and d > kick + 6 and not landT then landT = time end
        if landT and time - landT < 1.0 and (vc.R2.drive or 0) > 0.5 then rearMin = math.min(rearMin, lr / math.max(1e-6, wt)) end
      else
        rW = math.max(rW, math.abs(roll))
      end
      lastAir = air
      lpk[1], lpk[2] = math.max(lpk[1], lf), math.max(lpk[2], lr)
      for k, w in ipairs(vc.R2.wheels or {}) do
        local c = w.susp and w.susp.comp
        if c and k <= 2 then cmax[k] = math.max(cmax[k], c) end
        -- (a picture of the fork deep in its travel, once a run: the
        -- sliders on their stanchions)
        if c and w.susp.m.kind == "fork" and c > 0.7 * (w.susp.travel or 0.13) and not JP.fork_shot then
          JP.fork_shot = true
          V.shot("fork_deep_" .. string.format("%.0f", c * 100), false)
        end
      end
      if (tonumber(params.blog) or 0) > 0 and time >= (JP.blog_t or 0) then
        JP.blog_t = time + tonumber(params.blog)
        local gs = vc.R2.gyroT or -1
        local _, _, yawr, rrate, Uu, Fl = JP.att(vc)
        local vv = assembly.info(vc.node).vel
        local Rt = unit(cross(Fl, Uu))
        P("JP BT %s yaw %.2f rr %.2f vlat %.2f vup %.2f | d %.1f v %.2f roll %.1f pitch %.1f gr %d%d ld %.2f/%.2f tq %.2f ptq %.2f atq %.2f aim %.1f tmax %.2f gyro %.2f drive %.2f comp %s tc %.2f sld %.2f spn %.2f cap %.2f", tag, yawr, rrate, dot(vv, Rt), dot(vv, Uu), d, V.speed(vc), math.deg(roll), math.deg(pitch), f, r, lf, lr,
          vc.R2.bikeTorque or 0, vc.R2.pitchTq or 0, vc.R2.airPitchTq or 0, math.deg(vc.R2.airAim or 0), vc.R2.tmax or -1, gs, vc.R2.drive or 0, susp(vc),
          vc.R2.tcK or 0, vc.R2.tcSlide or 0, vc.R2.tcSpin or 0, vc.R2.bikeCap or -1)
      end
    end
    -- (a breakup: the craft is no longer flown, and the run is over)
    if not (vc.node and vc.node.valid) or not vc.piloting then fell, fell_d, JP.dead = true, d, true; break end
    if V.upness(vc.node) < 0.5 or math.abs(roll) > math.rad(50) or math.abs(pitch) > math.rad(50) then fell, fell_d = true, d; break end
    if d >= dEnd then break end
  end
  hold_w(false)
  vc.R2.cmd = { drive = 0, steer = 0 }
  -- (to a stop on the strip, on the line: S held, steering still)
  if not fell and not JP.dead then
    local ts = time
    while time - ts < 8 and V.speed(vc) > 1.0 do
      local _, st = JP.cruise(vc, 0, true)
      vc.R2.cmd = { drive = -1, steer = st }
      yield()
      if V.upness(vc.node) < 0.5 then break end
    end
    vc.R2.cmd = { drive = 0, steer = 0 }
  end
  local where = fell_d and (fell_d < b0 and "approach" or (fell_d < b1 and "whoops" or (kick and fell_d < kick + 30 and "kicker" or "run-out"))) or "-"
  P("JP BUMP %s v %.0f: in at %.2f m/s, %d hops (longest %.2f s), peak pitch %.1f roll %.1f deg, comp F %.3f R %.3f, peak load F %.1f R %.1f W, %s%s",
    tag, vt, v_in or -1, hops, airmax, math.deg(pmax), math.deg(rmax), cmax[1], cmax[2], lpk[1] / math.max(1e-6, wt), lpk[2] / math.max(1e-6, wt),
    JP.dead and "BROKE UP" or (fell and "FELL" or "upright"), fell and string.format(" at %.1f m (%s)", fell_d, where) or "")
  P("JP BZ %s v %.0f: roll whoops %.1f kicker %.1f deg, slide off the lip %.2f m/s, rear load after the landing (1 s, throttle open) least %.2f W", tag, vt,
    math.deg(rW), math.deg(rK), vlatK, rearMin < 9 and rearMin or -1)
  return { fell = fell, where = where, v_in = v_in }
end
function JP.press(vc)
  JP.reset(vc, 20)
  local pc = V.pc()
  local i = assembly.info(vc.node)
  local U = V.up(i.com)
  local Fw = V.fwdW(vc)
  local Rt = unit(cross(Fw, U))
  if pc and pc.face then pc.face(Rt.x, Rt.y, Rt.z, -0.08); if pc.setCamMode then pc.setCamMode("chase") end end
  wait(1.5)
  local function comps()
    local t = {}
    for _, w in ipairs(vc.R2.wheels or {}) do if w.susp then t[#t + 1] = string.format("%s %.3f/%.2f", w.susp.m.kind, w.susp.comp or 0, w.susp.travel or 0) end end
    return table.concat(t, ", ")
  end
  V.shot("press_rest", false)
  P("JP press rest: %s", comps())
  vc.R2.motoOff = true
  JP.HOLD = { g = JP.g or 9.8, sink = 3.0 }
  wait(1.2)
  P("JP press 3 g: %s", comps())
  V.shot("press_3g", false)
  JP.HOLD.sink = -0.6
  wait(1.0)
  P("JP press lifted: %s", comps())
  V.shot("press_lifted", false)
  JP.HOLD.sink = 0.33
  wait(1.5)
  JP.HOLD = nil
  vc.R2.motoOff = nil
  wait(1.0)
end
local function run_vbump()
  local vc = JP.bike("bump")
  if not vc then return end
  JP.vc = vc
  local speeds = jsplit(params.speeds or "15,20,24")
  local reps = tonumber(params.reps or 2)
  local B, b1 = JP.bumps()
  local b0 = B[1].d - B[1].w / 2
  local kg = tonumber(params.bkg or 0.2)
  local kick = (kg > 0) and (b1 + 10) or nil
  local dEnd = (kick and kick + 3.5 + 45) or (b1 + 20)
  -- (60 m past the end to stop in: braking from 20 m/s off the strip's
  -- end onto the natural ground broke the bike up, 2026-11-04)
  if not JP.strip(vc, -15, dEnd + 90) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the whole strip")
  local made, worst = JP.bumps_build(vc, B, b0 - 0.5, b1 + 0.5)
  P("JP whoops %d from %.0f to %.0f m: %d sculpts, worst %.1f cm; profile %s", #B, b0, b1, made, 100 * worst, JP.heights(vc, b0 - 1, b1 + 1, 0.5))
  if kick then
    JP.kicker(kick, 3.5, kg)
    P("JP kicker at %.0f m: profile %s", kick, JP.heights(vc, kick - 2, kick + 8, 0.5))
  end
  -- the CoM's height at rest and the world's gravity, for the hold
  JP.g = vc.R2.gl or 9.8
  do
    local i = assembly.info(vc.node)
    local c = sub(i.com, home())
    local S = V.strip
    JP.hc0 = len(c.x, c.y, c.z) - len(S.rel0.x, S.rel0.y, S.rel0.z)
  end
  P("JP bump course: approach %.0f m, whoops %.0f..%.0f m, kicker %s, end %.0f m; CoM %.2f m up, g %.2f", b0, b0, b1, kick and string.format("%.0f m (%.0f%%)", kick, kg * 100) or "none", dEnd, JP.hc0, JP.g)
  local tally = {}
  for _, v in ipairs(speeds) do
    tally[v] = { n = 0, fell = 0, where = {} }
    for rep = 1, reps do
      JP.reset(vc, 0)
      local r = JP.bump_pass(vc, string.format("v%d#%d", v, rep), v, B, b0, b1, kick, dEnd)
      local t = tally[v]
      t.n = t.n + 1
      if r.fell then t.fell = t.fell + 1; t.where[#t.where + 1] = r.where .. (JP.dead and "!" or "") end
      if JP.dead then break end
      V.stop(vc)
    end
    if JP.dead then P("JP bump: the bike broke up, the rest is skipped"); break end
  end
  local parts = {}
  for _, v in ipairs(speeds) do
    local t = tally[v] or { n = 0, fell = 0, where = {} }
    parts[#parts + 1] = string.format("%d m/s %d/%d%s", v, t.fell, t.n, #t.where > 0 and (" (" .. table.concat(t.where, ",") .. ")") or "")
  end
  P("JP BUMPS %s: falls %s", V.tag, table.concat(parts, " | "))
  -- THE FORK DEEP IN ITS TRAVEL AND HANGING, from the side (bpress=0: no):
  -- the bike held square, pressed down at 3 g and then lifted, a picture each
  if not JP.dead and (tonumber(params.bpress) or 1) > 0 then JP.press(vc) end
  V.check("bump", true, "the course ridden")
  V.result()
end

-- ── vload ───────────────────────────────────────────────────────────────────
-- The tyres' loads (node.contactForce, engine card 0629) against the craft's
-- weight: parked on the flat strip (`JP LOAD parked`, 3 s mean), then held at
-- each of `speeds` (strs, default "0.5,5,10,15,20") on the line for 3 s
-- (`JP LOAD v`). `JP MASS`: what assembly.info's mass holds — the part
-- bodies, the tyres (bodies of their own on wheel joints), the seated rider
-- (the Astronaut: kinematic in the seat, not a body of the craft).
local function load_mean(vc, secs, vt)
  local n, sf, sr, sw, mn, mx = 0, 0, 0, 0, 1e9, 0
  local t0 = time
  while time - t0 < secs do
    if vt then
      local drive, st = JP.cruise(vc, vt, true)
      vc.R2.cmd = { drive = drive, steer = st }
    end
    yield()
    local _, _, lf, lr = JP.down(vc)
    local wt = JP.weight(vc)
    n, sf, sr, sw = n + 1, sf + lf, sr + lr, sw + wt
    mn, mx = math.min(mn, lf + lr), math.max(mx, lf + lr)
  end
  n = math.max(1, n)
  return sf / n, sr / n, sw / n, mn, mx
end
local function run_vload()
  local vc = JP.bike("load")
  if not vc then return end
  if not JP.strip(vc, -15, 260) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the whole strip")
  -- the mass: assembly.info, the part bodies, the tyres, the rider
  local i = assembly.info(vc.node)
  local parts, tyres, nt = 0, 0, 0
  for _, c in ipairs(vc.node:children()) do
    local rb = c:getcomponent("RigidBody")
    if rb and (c.name or ""):sub(1, 4) == "Part" then parts = parts + (rb.mass or 0) end
  end
  for _, w in ipairs(vc.R2.wheels or {}) do
    local rb = w.tyre and w.tyre.valid and w.tyre:getcomponent("RigidBody")
    if rb then tyres, nt = tyres + (rb.mass or 0), nt + 1 end
  end
  local a = find("Astronaut")
  local arb = a and a:getcomponent("RigidBody")
  local dry, wet = 0, 0
  if vc.trueMass then dry, wet = vc.trueMass() end
  P("JP MASS info %.4f t | part bodies %.4f t + %d tyres %.4f t = %.4f | trueMass dry %.4f wet %.4f | rider aboard %s, Astronaut body mass %s kinematic %s | g %.3f",
    i.mass or -1, parts, nt, tyres, parts + tyres, dry, wet, tostring(vc.crewAboard), arb and string.format("%.4f", arb.mass or -1) or "-",
    arb and tostring(arb.kinematic) or "-", vc.R2.gl or -1)
  V.stop(vc)
  wait(1.0)
  local lf, lr, wt, mn, mx = load_mean(vc, 3.0, nil)
  -- (what else may hold it up: the seated rider's kinematic body against the
  -- saddle, the craft's own contact, the game's forces)
  local ii = assembly.info(vc.node)
  P("JP LOAD others: Astronaut contactForce %s grounded %s | craft grounded %s anchored %s | gyro torque %.2f, motoOff %s, aero %s",
    a and string.format("%.3f", a.contactForce or -1) or "-", a and tostring(a.grounded) or "-", tostring(ii.grounded), tostring(ii.anchored),
    vc.R2.gyroT or -1, tostring(vc.R2.motoOff), tostring(vc.AERO and vc.AERO.active))
  P("JP LOAD parked: front %.3f rear %.3f sum %.3f kN (%.3f..%.3f) vs weight %.3f kN = %.1f%%; with the tyres' own %.3f kN: %.1f%%",
    lf, lr, lf + lr, mn, mx, wt, 100 * (lf + lr) / math.max(1e-6, wt), tyres * (vc.R2.gl or 9.8),
    100 * (lf + lr) / math.max(1e-6, wt + tyres * (vc.R2.gl or 9.8)))
  for _, v in ipairs(jsplit(params.speeds or "0.5,5,10,15,20")) do
    local ts = time
    while time - ts < 12 and math.abs(V.speed(vc) - v) > math.max(0.3, 0.05 * v) do
      local drive, st = JP.cruise(vc, v, true)
      vc.R2.cmd = { drive = drive, steer = st }
      yield()
    end
    local f, r, w2, a2, b2 = load_mean(vc, 3.0, v)
    P("JP LOAD v %.1f (at %.2f m/s): front %.3f rear %.3f sum %.3f kN (%.3f..%.3f) vs weight %.3f = %.1f%%", v, V.speed(vc), f, r, f + r, a2, b2, w2, 100 * (f + r) / math.max(1e-6, w2))
    if V.upness(vc.node) < 0.5 then break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.check("load", true, "measured")
  V.result()
end

