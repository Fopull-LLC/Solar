-- ── framefix probe (tools/perf/framefix.sh): markers lagging, world jitter ──
-- Spliced into a copy of perfbench.lua before its main (like jitterprobe).
-- Playtest 2026-11-10: "lots of indicators lagging behind slightly and slight
-- world jitter and plants flickering".
--
-- The probe's coroutine resumes in ITS update, which runs before every other
-- script's (the probe node is the first one made): at that moment the scene
-- mirror still holds what the last frame RENDERED (update → ticks →
-- interpolated writeback → lateUpdate → render, play_step.rs), camera
-- included. So, each frame, from update:
--
--  LAG   camera.worldToScreen is wrapped (the `camera` table is shared): every
--        call made last frame is recorded with its caller (file:line), the
--        world point and the pixel it answered. Re-projected through the
--        camera as it rendered, the difference is the marker's error from a
--        stale camera (a script that projected before planet_camera placed
--        the view). `FF LAG <phase> <caller> n rms p95 max px`.
--  TGT   named markers whose target is known are checked against the target's
--        DRAWN place (`FF TGT`), the other half of a lag (a tick pose, a
--        cached world point).
--  JIT   world jitter: a ground point fixed to the planet node (as drawn) and
--        the crew, projected through the rendered camera; the residual of each
--        frame from the straight line between its neighbours in frame time
--        (uneven frames allowed), in px; and the camera's and the crew's
--        planet-relative motion, the same residual in mm. A smooth pan has a
--        residual of a small fraction of a px; a jitter has its own amplitude.
--        `gap` = |space.body() - the planet node's drawn place| read in update
--        and in lateUpdate.
local function F(fmt, ...) P("FF " .. fmt, ...) end
local FFS = { recs = {}, on = false, phase = "-", lag = {}, ser = {}, maxrec = 600 }
local W2S0 = nil
local SRC_CACHE = {}
local function caller_src()
  if debug and debug.info then
    -- (Luau) the caller of the wrapper, three up: caller_src, the wrapper, it
    for lvl = 2, 7 do
      local ok, src, line = pcall(debug.info, lvl, "sl")
      if ok and src then
        local f = tostring(src):match('"([%w_]+)"') or tostring(src):match("([%w_]+)%.lua") or tostring(src)
        if f ~= "perfbench" then return f .. ":" .. tostring(line) end
      end
    end
  end
  if debug and debug.getinfo then
    local i = debug.getinfo(3, "Sl")
    if i then
      local s = i.short_src or i.source or "?"
      return (s:match("([%w_]+)%.lua") or s) .. ":" .. tostring(i.currentline or 0)
    end
  end
  for lvl = 3, 7 do
    local _, msg = pcall(error, "", lvl)
    local f, l = tostring(msg):match("([%w_]+)%.lua:(%d+)")
    if f and f ~= "perfbench" then return f .. ":" .. l end
    if not f then
      f, l = tostring(msg):match("([%w_]+):(%d+):")
      if f and f ~= "perfbench" then return f .. ":" .. l end
    end
  end
  return "?"
end
local function ff_install()
  if W2S0 or not (camera and camera.worldToScreen) then return end
  W2S0 = camera.worldToScreen
  camera.worldToScreen = function(x, y, z)
    local sx, sy, dep, on = W2S0(x, y, z)
    if FFS.on and #FFS.recs < FFS.maxrec then
      FFS.recs[#FFS.recs + 1] = { src = caller_src(), x = x, y = y, z = z, sx = sx, sy = sy, on = on }
    end
    return sx, sy, dep, on
  end
  F("worldToScreen wrapped (debug.getinfo %s, debug.info %s)", tostring(debug and debug.getinfo ~= nil), tostring(debug and debug.info ~= nil))
end
LATE = nil
FF_LATE_GAP = 0
function lateUpdate(node, dt)
  if LATE then LATE(node, dt) end
end
local function planet_node()
  local b = home()
  local pn = b and find(b.name)
  return b, pn
end
local function wpos(n)
  local w = n.worldPos
  return w.x, w.y, w.z
end
local function push(key, t, v)
  local s = FFS.ser[key]
  if not s then s = {}; FFS.ser[key] = s end
  s[#s + 1] = { t = t, v = v }
end
local G_REL = nil       -- the ground point, from the planet node
local LAST_T = nil
local function ff_frame()
  local t = LAST_T
  LAST_T = time
  -- the LAG half: last frame's projections against the rendered camera
  local recs = FFS.recs
  FFS.recs = {}
  if t and W2S0 then
    for _, r in ipairs(recs) do
      if r.on and r.sx then
        local sx, sy, _, on = W2S0(r.x, r.y, r.z)
        if sx then
          local e = math.sqrt((sx - r.sx) ^ 2 + (sy - r.sy) ^ 2)
          local L = FFS.lag[r.src]
          if not L then L = {}; FFS.lag[r.src] = L end
          L[#L + 1] = e
        end
      end
    end
  end
  if not t then return end
  local b, pn = planet_node()
  local A = astro()
  local pc = findScript("planet_camera")
  if not (b and pn and pn.valid and pc and pc.node and pc.node.valid) then return end
  local px, py, pz = wpos(pn)
  push("gap_upd", t, len(px - b.x, py - b.y, pz - b.z))
  push("gap_late", t, FF_LATE_GAP)
  local cx, cy, cz = wpos(pc.node)
  do
    local fw = pc.node:worldForward()
    local ux, uy, uz = cx - px, cy - py, cz - pz
    local ul = len(ux, uy, uz)
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    push("cam_pitch", t, math.asin(math.max(-1, math.min(1, fw.x * ux + fw.y * uy + fw.z * uz))))
    local rt = pc.node:worldRight()
    push("cam_roll", t, math.asin(math.max(-1, math.min(1, rt.x * ux + rt.y * uy + rt.z * uz))))
    if not FF_YREF then FF_YREF = { x = fw.x, y = fw.y, z = fw.z } end
    local fl = sub({ x = fw.x, y = fw.y, z = fw.z }, scl({ x = ux, y = uy, z = uz }, fw.x * ux + fw.y * uy + fw.z * uz))
    local r0 = sub(FF_YREF, scl({ x = ux, y = uy, z = uz }, dot(FF_YREF, { x = ux, y = uy, z = uz })))
    local cr = cross(r0, fl)
    push("cam_yaw", t, math.atan2(dot(cr, { x = ux, y = uy, z = uz }), dot(r0, fl)))
  end
  push("cam_rel_x", t, cx - px); push("cam_rel_y", t, cy - py); push("cam_rel_z", t, cz - pz)
  if A and A.valid then
    local ax, ay, az = wpos(A)
    push("crew_rel_x", t, ax - px); push("crew_rel_y", t, ay - py); push("crew_rel_z", t, az - pz)
    local sx, sy, _, on = W2S0(ax, ay, az)
    if on then push("crew_sx", t, sx); push("crew_sy", t, sy) end
    if not G_REL then
      -- 9 m ahead of the camera along the ground, 0.3 m up: a point fixed to
      -- the planet as drawn
      local f = { x = pc.fwd_x or 1, y = pc.fwd_y or 0, z = pc.fwd_z or 0 }
      local u = unit({ x = ax - px, y = ay - py, z = az - pz })
      local fl = unit(sub(f, scl(u, dot(f, u))))
      G_REL = { x = ax - px + fl.x * 9, y = ay - py + fl.y * 9, z = az - pz + fl.z * 9 }
    end
  end
  if G_REL then
    local sx, sy, _, on = W2S0(px + G_REL.x, py + G_REL.y, pz + G_REL.z)
    if on then push("ground_sx", t, sx); push("ground_sy", t, sy) end
  end
end
-- residual of x[i] from the time-line between x[i-1] and x[i+1]
local function resid(s, k)
  local v = {}
  for i = 2, #s - 1 do
    local a, m, c = s[i - 1], s[i], s[i + 1]
    local span = c.t - a.t
    if span > 1e-5 and span < 0.25 then
      local w = (m.t - a.t) / span
      v[#v + 1] = math.abs(m.v - (a.v + (c.v - a.v) * w)) * k
    end
  end
  table.sort(v)
  if #v == 0 then return 0, 0, 0, 0 end
  local q = 0
  for _, x in ipairs(v) do q = q + x * x end
  return math.sqrt(q / #v), v[math.max(1, math.floor(#v * 0.95))], v[#v], #v
end
local function pstats(v)
  table.sort(v)
  if #v == 0 then return 0, 0, 0 end
  local q = 0
  for _, x in ipairs(v) do q = q + x * x end
  return math.sqrt(q / #v), v[math.max(1, math.floor(#v * 0.95))], v[#v]
end
local function ff_report(phase, secs, frames)
  F("PHASE %s: %d frames in %.1f s (%.0f fps)", phase, frames, secs, frames / math.max(secs, 1e-3))
  local srcs = {}
  for src in pairs(FFS.lag) do srcs[#srcs + 1] = src end
  table.sort(srcs)
  for _, src in ipairs(srcs) do
    local n = #FFS.lag[src]
    local rms, p95, mx = pstats(FFS.lag[src])
    F("LAG %s %-28s n %5d | rms %.2f p95 %.2f max %.2f px", phase, src, n, rms, p95, mx)
  end
  for _, key in ipairs({ "ground_sx", "ground_sy", "crew_sx", "crew_sy" }) do
    local s = FFS.ser[key]
    if s then
      local rms, p95, mx, n = resid(s, 1)
      F("JIT %s %-10s n %4d | resid rms %.3f p95 %.3f max %.3f px", phase, key, n, rms, p95, mx)
    end
  end
  do
    local q = {}
    for _, key in ipairs({ "cam_pitch", "cam_yaw", "cam_roll" }) do
      local sr = FFS.ser[key]
      if sr then
        local rms, p95, mx = resid(sr, 1000)
        q[#q + 1] = string.format("%s %.3f/%.3f/%.3f", key, rms, p95, mx)
      end
    end
    F("JIT %s view turn resid rms/p95/max mrad: %s", phase, table.concat(q, "  "))
  end
  for _, key in ipairs({ "cam_rel", "crew_rel" }) do
    local q = {}
    for _, ax in ipairs({ "x", "y", "z" }) do
      local s = FFS.ser[key .. "_" .. ax]
      if s then
        local rms, p95, mx = resid(s, 1000)
        q[#q + 1] = string.format("%s %.2f/%.2f/%.2f", ax, rms, p95, mx)
      end
    end
    F("JIT %s %-10s resid rms/p95/max mm: %s", phase, key, table.concat(q, "  "))
  end
  for _, key in ipairs({ "gap_upd", "gap_late" }) do
    local s = FFS.ser[key]
    if s then
      local mx, sum = 0, 0
      for _, e in ipairs(s) do mx = math.max(mx, e.v); sum = sum + e.v end
      F("JIT %s %-10s mean %.4f max %.4f m", phase, key, sum / math.max(#s, 1), mx)
    end
  end
  if (params.ff_frames or 0) > 0 then
    local s = FFS.ser.cam_pitch
    local s2 = FFS.ser.cam_yaw
    local s3 = FFS.ser.crew_rel_x
    if s and s2 then
      for i = 1, math.min(#s, #s2, 120) do
        F("F %s %3d t %.4f pitch %.3f yaw %.3f mrad crewx %.4f", phase, i, s[i].t - s[1].t, s[i].v * 1000, s2[i].v * 1000, s3 and s3[i] and s3[i].v or 0)
      end
    end
  end
end
local function ff_phase(phase, secs, steer)
  FFS.lag, FFS.ser, FFS.recs = {}, {}, {}
  G_REL, LAST_T, FF_YREF = nil, nil, nil
  FFS.on = true
  LATE = function()
    local b, pn = planet_node()
    if b and pn and pn.valid then
      local x, y, z = wpos(pn)
      FF_LATE_GAP = len(x - b.x, y - b.y, z - b.z)
    end
    -- a piloted craft: its physics frame (assembly.info().origin, what a
    -- marker built from info.com / partFrameNow uses) against its root as
    -- drawn, both read now in the camera pass
    if FF_VN and FF_VN.valid then
      local i = assembly.info(FF_VN)
      local w = FF_VN.worldPos
      if i and i.origin then
        local g = len(i.origin.x - w.x, i.origin.y - w.y, i.origin.z - w.z)
        FF_ASM = FF_ASM or { n = 0, sum = 0, mx = 0 }
        FF_ASM.n, FF_ASM.sum, FF_ASM.mx = FF_ASM.n + 1, FF_ASM.sum + g, math.max(FF_ASM.mx, g)
        -- a part's frame as a marker or a prompt reads it (partFrameNow,
        -- rendered = true) against the part node as drawn
        local vc = FF_VC
        if vc and vc.partFrameNow and vc.uidOfNode then
          for _, c in ipairs(FF_VN:children() or {}) do
            local uid = vc.uidOfNode(c)
            if uid then
              local Fd = vc.partFrameNow(uid, true)
              local Ft = vc.partFrameNow(uid)
              local cw = c.worldPos
              if Fd and Ft then
                local ed = len(Fd.ox - cw.x, Fd.oy - cw.y, Fd.oz - cw.z)
                local et = len(Ft.ox - cw.x, Ft.oy - cw.y, Ft.oz - cw.z)
                FF_ASM.dsum, FF_ASM.dmx = (FF_ASM.dsum or 0) + ed, math.max(FF_ASM.dmx or 0, ed)
                FF_ASM.tsum, FF_ASM.tmx = (FF_ASM.tsum or 0) + et, math.max(FF_ASM.tmx or 0, et)
              end
              break
            end
          end
        end
      end
    end
  end
  local t0, n = time, 0
  while time - t0 < secs do
    if steer then steer(time - t0) end
    yield()
    ff_frame()
    n = n + 1
  end
  FFS.on = false
  LATE = nil
  ff_report(phase, time - t0, n)
  if FF_ASM then
    F("TGT %s assembly.info().origin vs the root as drawn (lateUpdate): mean %.4f max %.4f m over %d frames", phase, FF_ASM.sum / math.max(1, FF_ASM.n), FF_ASM.mx, FF_ASM.n)
    F("TGT %s a part's frame vs the part as drawn: partFrameNow(uid, true) mean %.4f max %.4f m | partFrameNow(uid) mean %.4f max %.4f m", phase,
      (FF_ASM.dsum or 0) / math.max(1, FF_ASM.n), FF_ASM.dmx or 0, (FF_ASM.tsum or 0) / math.max(1, FF_ASM.n), FF_ASM.tmx or 0)
    FF_ASM = nil
  end
end
local function ff_shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://ffshots/" .. nm .. ".png", bytes); F("SHOT %s", nm)
    else F("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then F("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end
local function ff_away()
  local A, b = astro(), home()
  local u0 = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local bu = base_frame()
  local away = sub(u0, scl(bu, dot(u0, bu)))
  if len(away.x, away.y, away.z) < 1e-4 then away = cross(u0, { x = 0, y = 0, z = 1 }) end
  return unit(away), u0
end
local function ff_set_warp(want)
  for _ = 1, 12 do
    local w = space.warp()
    if w >= want * 0.99 then break end
    tap("."); wait(0.25)
  end
  F("warp now %.0fx", space.warp())
end
local function ff_unwarp()
  for _ = 1, 12 do if space.warp() <= 1.001 then break end; tap(","); wait(0.25) end
  if space.warp() > 1.001 and space.setWarp then pcall(space.setWarp, 1) end
end
local function run_lag()
  wait_ready(90)
  wait(2)
  clear_weather()
  ff_install()
  local C = findScript("crew")
  if C and C.setSafety then C.setSafety("invincible") end
  local pc = findScript("planet_camera")
  local pw = findScript("planet_walker")
  local which = params.ff_only or 0
  -- a target marker on the nearest other world (targeting.lua draws it)
  local tg = findScript("targeting")
  if tg and tg.targetBody and space.bodies then
    local hb = home()
    for _, bb in ipairs(space.bodies()) do
      if bb.name ~= hb.name and bb.radius and bb.radius < 5e5 then pcall(tg.targetBody, bb.name); F("target %s", bb.name); break end
    end
  end
  local away = ff_away()
  pc.firstPerson = false
  -- toward the base first: its facility labels and the objective marker are
  -- on screen (objectives.lua), walking and then turning the view
  do
    local tb = scl(away, -1)
    pc.face(tb.x, tb.y, tb.z, -0.15)
    wait(1.0)
    ff_phase("tp_base_stand", 2)
    pw.steer(1, 0, false); wait(0.6)
    ff_phase("tp_base_walk", 4, function() pw.steer(1, 0, false) end)
    if (params.ff_shots or 0) > 0 then ff_shot("tp_base_walk") end
    local _, u = ff_away()
    local sd = unit(cross(u, tb))
    ff_phase("tp_base_look", 4, function(tt)
      local a = 0.35 * math.sin(tt * 1.6)
      pw.steer(0.6, 0, false)
      pc.face(tb.x * math.cos(a) + sd.x * math.sin(a), tb.y * math.cos(a) + sd.y * math.sin(a), tb.z * math.cos(a) + sd.z * math.sin(a), -0.15)
    end)
    pc.firstPerson = true
    wait(0.8)
    ff_phase("fp_base_look", 4, function(tt)
      local a = 0.35 * math.sin(tt * 1.6)
      pw.steer(0.6, 0, false)
      pc.face(tb.x * math.cos(a) + sd.x * math.sin(a), tb.y * math.cos(a) + sd.y * math.sin(a), tb.z * math.cos(a) + sd.z * math.sin(a), -0.15)
    end)
    pc.firstPerson = false
    pw.steer(0, 0, false); wait(1.0)
    away = ff_away()
  end
  pc.face(away.x, away.y, away.z, -0.2)
  wait(1.0)
  ff_phase("tp_stand", 3)
  pw.steer(1, 0, false); wait(1.0)
  ff_phase("tp_walk", 6, function() pw.steer(1, 0, false) end)
  if (params.ff_shots or 0) > 0 then ff_shot("tp_walk") end
  pw.steer(1, 0, true); wait(0.8)
  ff_phase("tp_sprint", 5, function() pw.steer(1, 0, true) end)
  pw.steer(0, 0, false); wait(1.0)
  -- look round while walking: the camera turns (mouse-like), 3rd person
  local _, u = ff_away()
  local d0 = unit(sub(away, scl(u, dot(away, u))))
  local sd = unit(cross(u, d0))
  ff_phase("tp_walklook", 6, function(tt)
    local a = 0.5 * math.sin(tt * 1.3)
    pw.steer(1, 0, false)
    pc.face(d0.x * math.cos(a) + sd.x * math.sin(a), d0.y * math.cos(a) + sd.y * math.sin(a), d0.z * math.cos(a) + sd.z * math.sin(a), -0.2)
  end)
  pw.steer(0, 0, false); wait(1.0)
  pc.firstPerson = true
  away = ff_away()
  pc.face(-away.x, -away.y, -away.z, -0.1)
  wait(1.0)
  ff_phase("fp_stand", 3)
  pw.steer(1, 0, false); wait(1.0)
  ff_phase("fp_walk", 6, function() pw.steer(1, 0, false) end)
  if (params.ff_shots or 0) > 0 then ff_shot("fp_walk") end
  pw.steer(1, 0, true); wait(0.8)
  ff_phase("fp_sprint", 5, function() pw.steer(1, 0, true) end)
  pw.steer(0, 0, false); wait(1.0)
  pc.firstPerson = false
  wait(0.8)
  ff_set_warp(params.ff_warp or 100)
  ff_phase("tp_warp_stand", 4)
  ff_phase("tp_warp_walk", 4, function() pw.steer(1, 0, false) end)
  pw.steer(0, 0, false)
  ff_unwarp()
  pw.steer(nil)
  F("DONE lag")
end
local function run_lagrover()
  ff_install()
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then F("no rover"); return end
  local vn = vc.node
  FF_VN, FF_VC = vn, vc
  ff_phase("rover_rest", 2)
  vc.releaseClamps()
  wait(2)
  local pc = findScript("planet_camera")
  key_down("w")
  wait(3)
  ff_phase("rover_tp", 8, function() if not HELD.w then key_down("w") end end)
  if (params.ff_shots or 0) > 0 then ff_shot("rover_tp") end
  -- a turn: the chase camera swings
  key_down("a")
  ff_phase("rover_turn", 4)
  key_up("a")
  ff_phase("rover_tp2", 5)
  release_all()
  F("DONE lagrover")
end
-- ── lagflora: plants flickering ────────────────────────────────────────────
-- On a meadow ~150 m from the base: (1) LOGICAL, every frame, every flora
-- source's instances within `fl_r` m of the camera (scatter.near), keyed by
-- (patch, species, part, instance id) so a stand redeclared under a new
-- source id is the same plant; a plant that leaves while well inside the
-- radius is a DROP, one back within 1 s of leaving a BLINK, binned by its
-- distance to the camera; and perf.counts().props per frame. (2) PICTURES: a
-- still camera's burst of `fl_n` consecutive captures (flicker.py's hf).
FL_SDIST = {}
FL_SRC = {}
local function fl_keys(FFm, r)
  local cn = findScript("planet_camera").node
  local c = cn.worldPos
  local out = {}
  local cv = vec3(c.x, c.y, c.z)
  for _, id in ipairs(FFm.sourceIds()) do
    local inf = FFm.sourceInfo(id)
    if inf and not inf.retiring then
      local ok, list = pcall(scatter.near, id, cv, r)
      if ok and list then
        for _, h in ipairs(list) do
          local k = tostring(inf.patch) .. "|" .. tostring(inf.spid) .. "|" .. tostring(inf.part) .. "|" .. tostring(h.id)
          out[k] = h.distance or len(h.pos.x - c.x, h.pos.y - c.y, h.pos.z - c.z)
          FL_SRC[k] = id
          local sk = FFm.SHADOW_KIND and inf.kind and FFm.SHADOW_KIND[inf.kind]
          if sk and sk.cast and sk.dist and inf.part ~= "bark" then FL_SDIST[k] = sk.dist end
        end
      end
    end
  end
  return out
end
local function fl_track(tag, secs, steer, burst)
  local FFm = findScript("flora_field")
  local r = params.fl_r or 40
  local prev, gone = nil, {}
  local drops, blinks, appears = { a = 0, b = 0, c = 0 }, { a = 0, b = 0, c = 0 }, { a = 0, b = 0, c = 0 }
  local function bin(d) return d < 4 and "a" or (d < r * 0.6 and "b" or "c") end
  local props, jumps, frames = {}, 0, 0
  local sh = { toggles = 0, flicker = 0, last = {}, keys = {} }
  local whys = {}
  local ids0 = {}
  for _, id in ipairs(FFm.sourceIds()) do ids0[id] = true end
  local made, destroyed = 0, 0
  local gb = 0
  local t0 = time
  local out, idx = 0, 0
  while time - t0 < secs do
    if steer then steer(time - t0) end
    if burst and idx < burst then
      idx = idx + 1
      out = out + 1
      local my = idx
      pcall(camera.capture, { w = 960, h = 540 }, function(bytes)
        out = out - 1
        if bytes then assets.writeBytes(string.format("user://ffshots/flora/%s/f%02d.png", tag, my), bytes) end
      end)
    end
    yield()
    frames = frames + 1
    local cur = fl_keys(FFm, r)
    local now = time
    if prev then
      for k, d in pairs(prev) do
        if not cur[k] and d < r * 0.85 then
          drops[bin(d)] = drops[bin(d)] + 1
          gone[k] = { t = now, d = d }
          if d >= 4 then
            local inf = FFm.sourceInfo(FL_SRC[k])
            local why = not inf and "src_destroyed" or (inf.retiring and "src_retiring") or (inf.current == false and "src_not_current") or "inst_removed"
            whys[why] = (whys[why] or 0) + 1
          end
        end
      end
      for k, d in pairs(cur) do
        if not prev[k] and d < r * 0.85 then
          appears[bin(d)] = appears[bin(d)] + 1
          local g = gone[k]
          if g and now - g.t < 1.0 then blinks[bin(d)] = blinks[bin(d)] + 1 end
          if d >= 4 then
            local inf = FFm.sourceInfo(FL_SRC[k])
            local why = (inf and inf.made and time - inf.made < 1.5) and "app_new_src" or "app_old_src"
            whys[why] = (whys[why] or 0) + 1
          end
        end
      end
    end
    -- the sun shadow's cut (scatter_draw: casts while d <= shadowDistance,
    -- measured from the eye, no band): a plant crossing it turns its shadow
    -- on or off; one that crosses back within 1 s flickered
    for k, d in pairs(cur) do
      local sd = FL_SDIST[k]
      local pd = prev and prev[k]
      if sd and pd and ((pd <= sd) ~= (d <= sd)) then
        sh.toggles = sh.toggles + 1
        local lt = sh.last[k]
        if lt and now - lt < 1.0 then sh.flicker = sh.flicker + 1; sh.keys[k] = true end
        sh.last[k] = now
      end
    end
    prev = cur
    do
      local ids = {}
      for _, id in ipairs(FFm.sourceIds()) do ids[id] = true; if not ids0[id] then made = made + 1 end end
      for id in pairs(ids0) do if not ids[id] then destroyed = destroyed + 1 end end
      ids0 = ids
      if FFm.groundBusy then gb = math.max(gb, FFm.groundBusy()) end
    end
    local c = perf.counts() or {}
    props[#props + 1] = c.props or 0
    if #props > 1 and props[#props - 1] > 0 and math.abs(props[#props] - props[#props - 1]) / props[#props - 1] > 0.015 then jumps = jumps + 1 end
  end
  wait_for(function() return out <= 0 end, 10, "captures")
  local pmin, pmax = 1e9, 0
  for _, v in ipairs(props) do pmin = math.min(pmin, v); pmax = math.max(pmax, v) end
  local n = 0
  for _ in pairs(prev or {}) do n = n + 1 end
  F("FLORA %-12s %d frames | in %d m now %d | drops <4m %d mid %d far %d | appears <4m %d mid %d far %d | BLINKS <4m %d mid %d far %d | props %d..%d, %d jumps >1.5%% | bent %s",
    tag, frames, r, n, drops.a, drops.b, drops.c, appears.a, appears.b, appears.c, blinks.a, blinks.b, blinks.c, pmin, pmax, jumps,
    tostring(FFm.touchStats and FFm.touchStats.bent))
  local nk = 0
  for _ in pairs(sh.keys) do nk = nk + 1 end
  local wl = {}
  for k2, v in pairs(whys) do wl[#wl + 1] = k2 .. " " .. v end
  table.sort(wl)
  F("FLORA %-12s why (4 m+): %s | sources made %d gone %d | groundBusy max %d | auditRemoved %s", tag, table.concat(wl, ", "), made, destroyed, gb, tostring(FFm.auditRemoved))
  F("FLORA %-12s shadow cut crossings %d, back within 1 s %d (%d plants flickered their shadow)", tag, sh.toggles, sh.flicker, nk)
end
local function run_lagflora()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = findScript("crew")
  if C and C.setSafety then C.setSafety("invincible") end
  local spot = find_meadow(params.meadow_m or 150)
  if not spot then F("no meadow"); return end
  F("meadow %s flora %.2f %d m out", tostring(spot.biome), spot.flora, spot.d)
  stand_at(spot)
  wait(params.settle or 10)
  local pc = findScript("planet_camera")
  local pw = findScript("planet_walker")
  pc.firstPerson = false
  local A, b = astro(), home()
  local u = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local t = spot.t
  local f = unit(sub(t, scl(u, dot(t, u))))
  pc.face(f.x, f.y, f.z, -0.12)
  wait(3)
  if (params.ff_shots or 0) > 0 then ff_shot("flora_still") end
  fl_track("still", 4, nil, params.fl_n or 30)
  pw.steer(0.35, 0, false); wait(0.5)
  fl_track("creep", 6, function() pw.steer(0.35, 0, false) end)
  fl_track("walk", 8, function() pw.steer(1, 0, false) end)
  fl_track("sprint", 6, function() pw.steer(1, 0, true) end)
  pw.steer(0, 0, false); wait(1.5)
  local A2, b2 = astro(), home()
  local u2 = unit(sub({ x = A2.x, y = A2.y, z = A2.z }, { x = b2.x, y = b2.y, z = b2.z }))
  local sd = unit(cross(u2, f))
  fl_track("turn", 6, function(tt)
    local a = 0.6 * math.sin(tt * 1.1)
    pw.steer(0, 0, false)
    pc.face(f.x * math.cos(a) + sd.x * math.sin(a), f.y * math.cos(a) + sd.y * math.sin(a), f.z * math.cos(a) + sd.z * math.sin(a), -0.12)
  end)
  pc.face(f.x, f.y, f.z, -0.12)
  wait(1.5)
  fl_track("still2", 4, nil, params.fl_n or 30)
  pw.steer(nil)
  F("DONE lagflora")
end

-- ── lagshadow: do shadows swim while the camera moves? ─────────────────────
-- The sun map's texel snap is relative to the camera (raster.rs
-- sun_shadow_matrix), so a camera that moves across the sun should drag the
-- grid over the ground and make shadow edges crawl. On the meadow, the camera
-- is slid sideways `sh_step` m a FRAME (planet_camera.setShot, body-relative,
-- looking at a point 12 m ahead that slides with it) and `sh_n` consecutive
-- frames are captured: with the shadow map on, then off (Light.shadowMap =
-- false: the per-pixel march, no grid), and held still. flicker_hf.py compares
-- the frames' temporal jitter: the motion is the same, so the difference is
-- the map's.
FF_SH = nil
local function sh_burst(tag, step, n)
  local pc = findScript("planet_camera")
  local A, b = astro(), home()
  local bn = save.get("base.body")
  local up = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local f = { x = pc.fwd_x, y = pc.fwd_y, z = pc.fwd_z }
  f = unit(sub(f, scl(up, dot(f, up))))
  local sd = unit(cross(up, f))
  local c0 = { x = A.x - b.x - f.x * 3 + up.x * 1.9, y = A.y - b.y - f.y * 3 + up.y * 1.9, z = A.z - b.z - f.z * 3 + up.z * 1.9 }
  local l0 = { x = A.x - b.x + f.x * 12, y = A.y - b.y + f.y * 12, z = A.z - b.z + f.z * 12 }
  FF_SH = { k = 0 }
  local S = FF_SH
  pc.setShot(function()
    local bb = space.body(bn)
    local o = S.k * step
    return bb.x + c0.x + sd.x * o, bb.y + c0.y + sd.y * o, bb.z + c0.z + sd.z * o,
           bb.x + l0.x + sd.x * o, bb.y + l0.y + sd.y * o, bb.z + l0.z + sd.z * o, up.x, up.y, up.z
  end, 0.05)
  wait(1.0)
  local out = 0
  for i = 1, n do
    S.k = i
    out = out + 1
    pcall(camera.capture, { w = 960, h = 540, ui = false, draws = false }, function(bytes)
      out = out - 1
      if bytes then assets.writeBytes(string.format("user://ffshots/shadow/%s/f%02d.png", tag, i), bytes) end
    end)
    yield()
  end
  wait_for(function() return out <= 0 end, 15, "captures")
  pc.clearShot(0.05)
  wait(0.5)
  F("SHADOW burst %s: %d frames, %.3f m a frame", tag, n, step)
end
local function run_lagshadow()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = findScript("crew")
  if C and C.setSafety then C.setSafety("invincible") end
  local spot = find_meadow(params.meadow_m or 150)
  if not spot then F("no meadow"); return end
  stand_at(spot)
  wait(params.settle or 10)
  local pc = findScript("planet_camera")
  pc.firstPerson = false
  local A, b = astro(), home()
  local u = unit(sub({ x = A.x, y = A.y, z = A.z }, { x = b.x, y = b.y, z = b.z }))
  local f = unit(sub(spot.t, scl(u, dot(spot.t, u))))
  pc.face(f.x, f.y, f.z, -0.25)
  wait(3)
  -- the grass giving way round the crew (flora_field touch_engine), two angles
  local pw = findScript("planet_walker")
  pw.steer(0.5, 0, false); wait(1.5)
  ff_shot("bend_walk_back")
  pc.face(-f.x, -f.y, -f.z, -0.35)
  wait(0.6)
  ff_shot("bend_walk_front")
  pw.steer(0, 0, false); wait(0.4)
  ff_shot("bend_stop")
  pw.steer(nil)
  wait(1.5)
  pc.face(f.x, f.y, f.z, -0.25)
  wait(1.5)
  local step, n = params.sh_step or 0.01, params.sh_n or 24
  local Lc = find("Lighting") and find("Lighting"):getcomponent("Light")
  local was = Lc and Lc.shadowMap
  F("SHADOW Light.shadowMap %s shadowDistance %s", tostring(was), tostring(Lc and Lc.shadowDistance))
  sh_burst("map_still", 0, n)
  sh_burst("map_slide", step, n)
  if Lc then Lc.shadowMap = false end
  wait(1)
  F("SHADOW Light.shadowMap now %s", tostring(Lc and Lc.shadowMap))
  sh_burst("march_slide", step, n)
  sh_burst("march_still", 0, n)
  if Lc then Lc.shadowMap = was end
  wait(1)
  sh_burst("map_slide2", step, n)
  F("DONE lagshadow")
end
