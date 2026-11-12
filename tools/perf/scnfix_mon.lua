-- SCNFIX_MON — the playtest 11-12 story checks, spliced into scnprobe.sh's
-- perfbench by EXTRA_LUA=tools/perf/scnfix_mon.lua (with camclear_mon.lua or
-- alone). Every frame:
--   * THE TYPEWRITER: the dialogue plate's line node ("Scenario Dialogue
--     Line") and the Ops strip's ("Ops Strip Line"), read back from the
--     scene. A line is "typed out" when the node was seen holding a part of
--     it (more than 0, fewer than all of its characters). Lines: "TW …" per
--     line, "TW TOTAL" at the end. The first part-typed plate is pictured
--     (tw_midline.png).
--   * THE CAMERA IN A BUILDING: while a shot is up, rays from the camera
--     (up, four ways round, and to the point it looks at). A camera with a
--     roof over it and walls on three sides inside 14 m, or with the subject
--     hidden behind something, is counted. "CI …" once a second, "CI TOTAL".
--   * THE WAIT BAR: the runner's state().wait, pictured once (wait_bar.png).
local TW = { lines = 0, partial = 0, seen = {}, cur = nil, pics = 0, strip_lines = 0, strip_partial = 0, scur = nil }
local CI = { frames = 0, enclosed = 0, blocked = 0, last = -1, pic = false }
local WB = { pic = false, seen = 0 }
local mon_pc = nil
local function ulen_(s)
  local n = 0
  for i = 1, #s do local b = s:byte(i); if b < 0x80 or b >= 0xC0 then n = n + 1 end end
  return n
end
local function tw_tick()
  local stg = findScript("scenario_stage", { quiet = true })
  local c = stg and stg.current and stg.current()
  if c and c.text then
    if TW.cur ~= c.text then
      if TW.cur then P("TW line done: part-typed %s · %s", tostring(TW.seen.part == true), TW.cur:sub(1, 40)) end
      TW.cur = c.text; TW.seen = {}; TW.lines = TW.lines + 1
    end
    local n = find("Scenario Dialogue Line")
    local s = n and n.valid ~= false and tostring(n.text or "") or ""
    s = s:gsub("▌", "")
    local k, L = ulen_(s), ulen_(c.text)
    if k > 0 and k < L and not TW.seen.part then
      TW.seen.part = true; TW.partial = TW.partial + 1
      if TW.pics < 1 and k > 12 then TW.pics = TW.pics + 1; TW.want_pic = true end
    end
  end
  -- the Ops strip
  local os_ = findScript("ops_strip", { quiet = true })
  local cur = os_ and os_.current
  if cur and cur.text then
    if TW.scur ~= cur.text then TW.scur = cur.text; TW.strip_lines = TW.strip_lines + 1; TW.sseen = false end
    local n = find("Ops Strip Line")
    local s = n and n.valid ~= false and tostring(n.text or "") or ""
    s = s:gsub("▌", "")
    local k, L = ulen_(s), ulen_(cur.text)
    if k > 0 and k < L and not TW.sseen then TW.sseen = true; TW.strip_partial = TW.strip_partial + 1 end
  end
end
local function ci_late()
  local pc = mon_pc
  if not (pc and pc.cam_x) then return end
  local w = pc.shotW or 0
  if w < 0.9 then return end
  CI.frames = CI.frames + 1
  local cam = vec3(pc.cam_x, pc.cam_y, pc.cam_z)
  local b = space.dominant(cam.x, cam.y, cam.z)
  local bb = b and space.body(b)
  if not bb then return end
  local up = (cam - vec3(bb.x, bb.y, bb.z)):normalized()
  local a = find("Astronaut")
  local ign = a and { ignore = a } or nil
  local function hit(d, far)
    local ok, h = pcall(raycast, cam, d, far, ign)
    return ok and h and h.distance or nil
  end
  local roof = hit(up, 14)
  local ref = math.abs(up.y) < 0.9 and vec3(0, 1, 0) or vec3(1, 0, 0)
  local e1 = up:cross(ref):normalized()
  local e2 = up:cross(e1):normalized()
  local walls = 0
  for _, d in ipairs({ e1, e1 * -1, e2, e2 * -1 }) do if hit(d, 14) then walls = walls + 1 end end
  local f = vec3(pc.fwd_x, pc.fwd_y, pc.fwd_z)
  local sp = pc.shotProbe or {}
  local want = sp.t or 6
  local blk = hit(f, math.max(0.5, want - 0.8))
  local enc = roof ~= nil and walls >= 3
  if enc then CI.enclosed = CI.enclosed + 1 end
  if blk then CI.blocked = CI.blocked + 1 end
  if (enc or blk) and not CI.pic then CI.pic = true; CI.want_pic = true end
  if time - CI.last >= 1.0 then
    CI.last = time
    P("CI t %.1f roof %s walls %d subject blocked at %s (shot t %.1f of %.1f, pulled %s, swing %s)", time, roof and string.format("%.1f", roof) or "-",
      walls, blk and string.format("%.1f", blk) or "-", sp.t or -1, sp.want or -1, tostring(sp.pulled), tostring(sp.swing))
  end
end
local function wb_tick()
  local sr = findScript("scenario_run", { quiet = true })
  local st = sr and sr.isActive and sr.isActive() and sr.state and sr.state()
  local wt = st and st.wait
  if wt then
    WB.seen = WB.seen + 1
    if time - (WB.last or -10) >= 5 then WB.last = time; P("WB at %.0f: %s · %s · eta %.0f s · %.0f %%", time, tostring(st.stepId), tostring(wt.label), wt.eta or -1, (wt.frac or 0) * 100) end
    if not WB.pic and WB.seen > 200 and find("Scenario Wait") ~= nil then WB.pic = true; WB.want_pic = true
      P("WB %s · %s left · %.0f %%", tostring(wt.label), tostring(wt.eta), (wt.frac or 0) * 100) end
  end
end
-- THE WAYPOINTS (BENCH_STRS ("wpshot", "1")): once the run is on foot and out
-- of its cutscene, two waypoints placed through targeting's WPT (one ahead of
-- the camera, one off to the side), the world pictured (wp_world.png), then
-- the map (wp_map.png) with a right-click pick read at a waypoint and at the
-- ground; the save checked; the map closed and the waypoints cleared.
local WP = { st = 0, t = 0 }
local function wp_tick()
  if tostring(params.wpshot or "") ~= "1" or WP.st >= 9 then return end
  local sr = findScript("scenario_run", { quiet = true })
  local pw = findScript("planet_walker", { quiet = true })
  local stg = findScript("scenario_stage", { quiet = true })
  local tg = findScript("targeting", { quiet = true })
  local pc = findScript("planet_camera", { quiet = true })
  local om = findScript("orbit_map", { quiet = true })
  if not (sr and sr.isActive and sr.isActive() and sr.phaseNow() == "running" and pw and pw.onFoot and tg and tg.WPT and pc and om) then WP.t = time return end
  if stg and stg.cutsceneOn and stg.cutsceneOn() then WP.t = time return end
  if WP.st == 0 and time - WP.t > 3.0 then
    local a = find("Astronaut")
    local b = space.body(space.dominant(a.x, a.y, a.z))
    local px, py, pz = a.x - b.x, a.y - b.y, a.z - b.z
    local l = math.sqrt(px * px + py * py + pz * pz)
    local ux, uy, uz = px / l, py / l, pz / l
    local fx, fy, fz = pc.fwd_x, pc.fwd_y, pc.fwd_z
    local fu = fx * ux + fy * uy + fz * uz
    fx, fy, fz = fx - ux * fu, fy - uy * fu, fz - uz * fu
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local function at(df, dr)
      local qx, qy, qz = px + fx * df + rx * dr, py + fy * df + ry * dr, pz + fz * df + rz * dr
      local q = math.sqrt(qx * qx + qy * qy + qz * qz)
      return qx / q * b.radius, qy / q * b.radius, qz / q * b.radius
    end
    tg.WPT.clear()
    local n1 = tg.WPT.add(b.name, at(80, 12))
    local n2 = tg.WPT.add(b.name, at(260, -420))
    P("WP placed %s %s on %s · saved %d", tostring(n1), tostring(n2), b.name, #(save.get("nav.waypoints") or {}))
    WP.st, WP.t = 1, time
  elseif WP.st == 1 and time - WP.t > 1.5 then
    WP.want = "wp_world"; WP.st, WP.t = 2, time
  elseif WP.st == 2 and time - WP.t > 1.0 then
    if not om.isOpen() then om.toggle() end
    WP.st, WP.t = 3, time
  elseif WP.st == 3 and time - WP.t > 0.4 and not WP.zoomed then
    -- (close enough that the world fills the view: the click lands on it)
    local w0 = tg.WPT.load()[1]
    local b0 = w0 and space.body(w0.body)
    -- (om.setZoom here left the map black: the default zoom is kept)
    WP.zoomed = true
  elseif WP.st == 3 and time - WP.t > 3.5 then
    -- what a right-click would open: on the first waypoint, and on the ground beside it
    local w = tg.WPT.load()[1]
    local x, y, z = tg.WPT.point(w, 0)
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    local p1 = on and tg.mapPick(sx, sy)
    local b0 = space.body(w.body)
    local bx, by, _, bon = camera.worldToScreen(b0.x, b0.y, b0.z)
    -- (the waypoints set aside for the world's own pick: zoomed out, WP 1
    -- sits within a click of the world's middle)
    local keep = tg.WPT.list
    tg.WPT.list = {}
    local p2 = bon and tg.mapPick(bx, by)
    tg.WPT.list = keep
    -- the menu that pick opens: its rows, "Place a waypoint here" among them
    local reg = findScript("context_registry", { quiet = true })
    if p2 and reg and reg.entriesFor then
      local okr, rows = pcall(reg.entriesFor, p2, {})
      local labels = {}
      for _, r in ipairs(okr and rows or {}) do labels[#labels + 1] = tostring(r.label) end
      P("WP world menu: %s", table.concat(labels, " | "))
    end
    local hd = -1
    if p2 and p2.hit then hd = math.sqrt(p2.hit.x ^ 2 + p2.hit.y ^ 2 + p2.hit.z ^ 2) - b0.radius end
    P("WP map pick at WP 1: %s %s · at the world's middle: %s hit %s (%.2f m off the sphere)", tostring(p1 and p1.kind), tostring(p1 and p1.label), tostring(p2 and p2.kind), tostring(p2 and p2.hit ~= nil), hd)
    WP.want = "wp_map"; WP.st, WP.t = 4, time
  elseif WP.st == 4 and time - WP.t > 1.0 then
    if om.isOpen() then om.toggle() end
    P("WP TOTAL placed %d, saved %d", #tg.WPT.load(), #(save.get("nav.waypoints") or {}))
    WP.st, WP.t = 5, time
  elseif WP.st == 5 and time - WP.t > 1.0 then
    tg.WPT.clear()
    WP.st = 9
  end
end
local mon_busy = false
function MON_tick()
  pcall(tw_tick)
  pcall(wb_tick)
  local okw, ew = pcall(wp_tick)
  if not okw then P("WP error %s", tostring(ew)); WP.st = 9 end
  if WP.want and not mon_busy then
    local nm = WP.want
    WP.want = nil
    mon_busy = true
    pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
      if bytes then assets.writeBytes("user://scnshots/" .. nm .. ".png", bytes); P("SP SHOT %s", nm) end
      mon_busy = false
    end)
  end
  if not (mon_pc and mon_pc.valid ~= false) then mon_pc = findScript("planet_camera", { quiet = true }) end
  if mon_pc and mon_pc.deferLate and NODE then pcall(mon_pc.deferLate, NODE, 0, ci_late) end
  if not mon_busy and (TW.want_pic or CI.want_pic or WB.want_pic) then
    local nm = TW.want_pic and "tw_midline" or (CI.want_pic and "cam_inside" or "wait_bar")
    if TW.want_pic then TW.want_pic = false elseif CI.want_pic then CI.want_pic = false else WB.want_pic = false end
    mon_busy = true
    pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
      if bytes then assets.writeBytes("user://scnshots/" .. nm .. ".png", bytes); P("SP SHOT %s", nm) end
      mon_busy = false
    end)
  end
end
function MON_total()
  if TW.cur then P("TW line done: part-typed %s · %s", tostring(TW.seen.part == true), TW.cur:sub(1, 40)) end
  P("TW TOTAL plate lines %d, typed out on screen %d · strip lines %d, typed out %d", TW.lines, TW.partial, TW.strip_lines, TW.strip_partial)
  P("CI TOTAL shot frames %d, camera enclosed %d, subject blocked %d", CI.frames, CI.enclosed, CI.blocked)
  P("WB TOTAL frames with a wait bar %d", WB.seen)
end
