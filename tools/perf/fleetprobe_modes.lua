-- ── fleet probe (tools/perf/fleetprobe.sh): what does each idle craft cost? ──
-- mode "fleet": a rover is rolled out of the VAB onto the runway, released and
-- left (the crew steps off and is put back where they stood at the start),
-- then copies of it are written into the fleet as the player's other craft —
-- alternately parked on the ground 70–330 m from the crew and coasting in a
-- high orbit (the engine's distant-craft LOD) — and rebuilt by flight_ops
-- the way a continued save rebuilds them. With 1, 5, 10 and 20 craft in the
-- world, each window waits `fleet_settle` s for them to settle and measures
-- `fleet_secs` s: frame p50/mean, the scripts bucket and the per-craft
-- scripts (vessel_controller, flight_ops, crew_strip, flight_hud, dock_row,
-- crew_alerts_hud, iva). One FLEET line a window, and a FLEETJSON row.
-- With fleet_fly = 1 a last window flies the rover with all 20 about.
local FL = { cloned = 0 }
local FL_SCRIPTS = { "vessel_controller", "flight_ops", "crew_strip", "flight_hud", "dock_row", "crew_alerts_hud", "iva", "comms", "targeting" }
local function fl_craft()
  local n, live, parts = 0, 0, 0
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid then
      n = n + 1
      local i = assembly.info(v.node)
      if i then live = live + 1; parts = parts + #(i.parts or {}) end
    end
  end
  return n, live, parts
end
-- rotate vector p about unit axis k by angle a (Rodrigues)
local function fl_rot(p, k, a)
  local c, s = math.cos(a), math.sin(a)
  local kxp = cross(k, p)
  local kd = dot(k, p)
  return { x = p.x * c + kxp.x * s + k.x * kd * (1 - c), y = p.y * c + kxp.y * s + k.y * kd * (1 - c),
           z = p.z * c + kxp.z * s + k.z * kd * (1 - c) }
end
-- the template: the rover's own fleet record pieces
local function fl_template(v)
  local fp = v.fleetParts and v.fleetParts()
  local E = findScript("electronics")
  if not (fp and E and E.packRecord) then return nil end
  local recs = {}
  for i, d in ipairs(fp.parts) do recs[i] = E.packRecord(d) end
  local rx, up, rz = basis(v.node)
  return { parts = recs, fuel = fp.fuel or 0, charge = fp.charge or 0, rx = rx, up = up, rz = rz,
           x = v.node.x, y = v.node.y, z = v.node.z }
end
local function fl_add(T, k)
  local b = home()
  local u, t1, t2, R = base_frame()
  local a = astro()
  local rec = { name = string.format("Probe craft %02d", k), body = b.name, vx = 0, vy = 0, vz = 0,
                fuel = T.fuel, charge = T.charge, probe = false, crew = false, flown = true, pod = false, comms = false,
                stime = space.time and space.time() or 0, t = time, parts = {} }
  for i, d in ipairs(T.parts) do local c = {}; for kk, vv in pairs(d) do c[kk] = vv end; rec.parts[i] = c end
  local ang = math.rad(k * 47)
  local tdir = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                      z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  -- the crew's own up, so "near" is near the crew rather than the base centre
  local au = a and unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }) or u
  local dir, ox, oy, oz
  if k % 2 == 1 then
    local d = 70 + 26 * k
    dir = dir_at(au, tdir, d, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150) or R
    ox, oy, oz = dir.x * (gr + 0.6), dir.y * (gr + 0.6), dir.z * (gr + 0.6)
    rec.landed = true
  else
    dir = dir_at(u, tdir, 0.0, R)
    local r = R * 1.6
    ox, oy, oz = dir.x * r, dir.y * r, dir.z * r
    local vt = math.sqrt(b.mu / r)
    local tv = unit(cross(dir, tdir))
    rec.vx, rec.vy, rec.vz = tv.x * vt, tv.y * vt, tv.z * vt
    rec.landed = false
  end
  rec.x, rec.y, rec.z = ox, oy, oz
  -- the rover's own axes, turned from its up to the new spot's
  local tu = unit({ x = T.x - b.x, y = T.y - b.y, z = T.z - b.z })
  local axis = cross(tu, dir)
  local s = len(axis.x, axis.y, axis.z)
  local X, Y, Z = T.rx, T.up, T.rz
  if s > 1e-6 then
    local kax = { x = axis.x / s, y = axis.y / s, z = axis.z / s }
    local an = math.atan2(s, dot(tu, dir))
    X, Y, Z = fl_rot(X, kax, an), fl_rot(Y, kax, an), fl_rot(Z, kax, an)
  end
  rec.yaw, rec.pitch, rec.roll = eulerOf(X, Y, Z)
  local f = save.get("fleet.craft")
  if type(f) ~= "table" then f = {} end
  f["probe" .. k] = rec
  save.set("fleet.craft", f)
end
local function fl_grow(T, n)
  local fo = findScript("flight_ops")
  local have = fl_craft()
  local want = n - have
  for _ = 1, want do FL.cloned = FL.cloned + 1; fl_add(T, FL.cloned) end
  if fo and fo.fleetRescan then fo.fleetRescan() end
  wait_for(function() return fl_craft() >= n end, 40, "the fleet rebuilt to " .. n)
end
local function fl_window(n, tag)
  wait(params.fleet_settle)
  local name = tag or string.format("fleet_n%02d", n)
  sc_begin(name)
  wait(params.fleet_secs)
  local r = RECS[name]
  local nf = math.max(#r.dts, 1)
  local st = stats(r.dts)
  local per = {}
  local mine = 0
  for _, k in ipairs(FL_SCRIPTS) do per[k] = (r.s[k] or 0) / nf; mine = mine + per[k] end
  local sb = (r.b.scripts or 0) / nf
  local nv, live, parts = fl_craft()
  local asleep, dorm, far = 0, 0, 0
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.node.asleep then asleep = asleep + 1 end
    if v.dormant == true then dorm = dorm + 1 end
    if type(v.DORM) == "table" and v.DORM.far then far = far + 1 end
  end
  local o = {}
  for _, k in ipairs(FL_SCRIPTS) do o[#o + 1] = string.format("%s %.3f", k, per[k]) end
  P("FLEET %s: craft %d (live %d, asleep %d, dormant %d, far %d, parts %d) frame p50 %.2f mean %.2f p95 %.2f | scripts %.3f ms, craft scripts %.3f ms | %s",
    name, nv, live, asleep, dorm, far, parts, st.p50, st.mean, st.p95, sb, mine, table.concat(o, ", "))
  print("FLEETJSON " .. json({ win = name, craft = nv, live = live, asleep = asleep, dormant = dorm, parts = parts, p50 = st.p50, mean = st.mean, p95 = st.p95,
    scripts = sb, mine = mine, per = per, frames = st.n }))
  sc_end(name)
end
local function run_fleet()
  wait_ready(120)
  local a, b = astro(), home()
  local home_rel = (a and b) and sub(a, b) or nil
  local vc = launch_in_vab(ROVER, "runway", 6)
  if not vc then P("FLEET: no rover"); return end
  vc.releaseClamps(); wait(2)
  tap("f"); wait(2.5)
  local bh = findScript("build_host")
  if bh and bh.state == "building" then if bh.leave then pcall(bh.leave) end; wait(1.5) end
  -- the crew back where they stood (the base), the rover left on the runway
  a, b = astro(), home()
  if a and b and home_rel then a.x, a.y, a.z = b.x + home_rel.x, b.y + home_rel.y, b.z + home_rel.z; a.vx, a.vy, a.vz = 0, 0, 0 end
  wait(2)
  local T = fl_template(vc)
  if not T then P("FLEET: no template"); return end
  P("FLEET template: %d parts; crew %.0f m from the rover", #T.parts, a and len(a.x - vc.node.x, a.y - vc.node.y, a.z - vc.node.z) or -1)
  for _, n in ipairs({ 1, 5, 10, 20 }) do
    if n > 1 then fl_grow(T, n) end
    fl_window(n)
  end
  if (params.fleet_fly or 0) > 0 and vc.node and vc.node.valid then
    a = astro()
    if a then a.x, a.y, a.z = vc.node.x + 3, vc.node.y + 3, vc.node.z; a.vx, a.vy, a.vz = 0, 0, 0 end
    wait(1.5)
    if vc.boardNow then pcall(vc.boardNow, vc.node, assembly.info(vc.node)) else tap("f") end
    wait(1.5)
    key_down("w")
    fl_window(20, "fleet_fly20")
    release_all()
  end
  -- the probe's craft go again (the scratch save is deleted after anyway)
  local f = save.get("fleet.craft") or {}
  local gone = 0
  for fid in pairs(f) do if tostring(fid):match("^probe") then f[fid] = nil; gone = gone + 1 end end
  save.set("fleet.craft", f)
  P("FLEET end: %d probe records dropped", gone)
end
