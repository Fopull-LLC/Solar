-- ── tracking station probe (tools/perf/trackprobe.sh) ────────────────────────
-- (docs/tracking-station.md §11.) Spliced into a copy of perfbench.lua; one
-- table (TP): perfbench's main chunk is near the 200-locals ceiling.
--   track   on the home world: a rover rolled out of the VAB and left (its
--           record the template), then the busy fleet written into the save —
--           49 more craft (35 on three orbits, a third of them probe cores
--           only, 7 landed near the base, 7 landed 3–30 km out), 200 packed
--           debris, 4 relay beacons, 3 flags, 3 structures, and a fourth crew
--           member standing on a moon. Then:
--     shots     the station (F2 on foot) at three zooms and the chart; the
--               selected card for a member far away
--     frames    10 s at ×100 warp: every anchor the station drew THIS frame
--               against the node's drawn pose / the record carried along its
--               conic, re-projected with the same camera (1 px)
--     labels    the tags pairwise apart, none under a panel, ≤ 40, the
--               selection's tag present at every zoom
--     perf      the station pass (os.clock in drawMap) and the scripts
--               (tracking_station, fleet_view, orbit_map) in STATION against
--               CHART; open/close 30 times, the node count before and after
--     actions   RECOVER a craft landed at the base pays its quote; one in
--               orbit carries the recoverRule reason; FLY a crewed orbiter
--     crewswitch  to a member 300 m off (the one left stands where they were
--               after the planet has moved > 500 m), to one at base, to one
--               seated in an orbiting craft, GO TO the one on the moon (the
--               curtain up and down, standing on its ground)
-- One `TP PASS|FAIL <check>` line a check and `TP RESULT`. Pictures:
-- 1280x720, save/user/trackshots/<name>.png in the scratch project.
TP = { fails = 0, passed = 0 }
function TP.check(name, okc, fmt, ...)
  P("TP %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then TP.passed = TP.passed + 1 else TP.fails = TP.fails + 1 end
  return okc
end
function TP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://trackshots/" .. nm .. ".png", bytes); P("TP SHOT %s", nm)
    else P("TP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end

-- rotate vector p about unit axis k by angle a (Rodrigues)
function TP.rot(p, k, a)
  local c, s = math.cos(a), math.sin(a)
  local kxp = cross(k, p)
  local kd = dot(k, p)
  return { x = p.x * c + kxp.x * s + k.x * kd * (1 - c), y = p.y * c + kxp.y * s + k.y * kd * (1 - c),
           z = p.z * c + kxp.z * s + k.z * kd * (1 - c) }
end
function TP.template(v)
  local fp = v.fleetParts and v.fleetParts()
  local E = findScript("electronics")
  if not (fp and E and E.packRecord) then return nil end
  local recs = {}
  for i, d in ipairs(fp.parts) do recs[i] = E.packRecord(d) end
  local rx, up, rz = basis(v.node)
  return { parts = recs, fuel = fp.fuel or 0, charge = fp.charge or 0, rx = rx, up = up, rz = rz,
           x = v.node.x, y = v.node.y, z = v.node.z }
end
-- One fleet record: kind "orbit" (shell r, angle), "near" / "far" (landed at d).
function TP.add(T, k, kind, opt)
  local b = home()
  local u, t1, t2, R = base_frame()
  local rec = { name = opt.name, body = b.name, vx = 0, vy = 0, vz = 0, fuel = T.fuel, charge = T.charge, probe = false,
                crew = false, flown = true, pod = false, comms = false, stime = space.time and space.time() or 0, t = time, parts = {} }
  for i, d in ipairs(T.parts) do
    local keep = true
    if opt.core and d.id ~= "roverBody" then keep = false end
    if keep then local c = {}; for kk, vv in pairs(d) do c[kk] = vv end; rec.parts[#rec.parts + 1] = c end
  end
  if opt.seat then
    for _, d in ipairs(rec.parts) do if d.id == "seat" then d.st = "crew1=" .. opt.seat end end
  end
  local ang = math.rad(k * 47)
  local tdir = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                      z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  local dir
  if kind == "orbit" then
    -- each shell tilted its own way, the craft spread round it
    local tilt = (opt.shell - 2) * 0.45
    local n = unit(TP.rot(cross(u, t1), t1, tilt))
    local p0 = TP.rot(u, n, opt.phase)
    dir = unit(p0)
    local r = R * opt.r
    rec.x, rec.y, rec.z = dir.x * r, dir.y * r, dir.z * r
    local vt = math.sqrt(b.mu / r)
    local tv = unit(cross(n, dir))
    rec.vx, rec.vy, rec.vz = tv.x * vt, tv.y * vt, tv.z * vt
    rec.landed = false
  else
    dir = dir_at(u, tdir, opt.d, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 400) or R
    rec.x, rec.y, rec.z = dir.x * (gr + 0.6), dir.y * (gr + 0.6), dir.z * (gr + 0.6)
    rec.landed = true
  end
  local tu = unit({ x = T.x - b.x, y = T.y - b.y, z = T.z - b.z })
  local axis = cross(tu, dir)
  local s = len(axis.x, axis.y, axis.z)
  local X, Y, Z = T.rx, T.up, T.rz
  if s > 1e-6 then
    local kax = { x = axis.x / s, y = axis.y / s, z = axis.z / s }
    local an = math.atan2(s, dot(tu, dir))
    X, Y, Z = TP.rot(X, kax, an), TP.rot(Y, kax, an), TP.rot(Z, kax, an)
  end
  rec.yaw, rec.pitch, rec.roll = eulerOf(X, Y, Z)
  local f = save.get("fleet.craft")
  if type(f) ~= "table" then f = {} end
  f["tp" .. k] = rec
  save.set("fleet.craft", f)
  return "tp" .. k
end

function TP.moon()
  local b = home()
  local best, bd
  for _, x in ipairs(space.bodies()) do
    if x.name ~= b.name and (x.soi or -1) > 0 and x.radius > 0 and x.radius < b.radius then
      local d = len(x.x - b.x, x.y - b.y, x.z - b.z)
      if not bd or d < bd then best, bd = x, d end
    end
  end
  return best
end

function TP.setup()
  wait_ready(150)
  local a, b = astro(), home()
  TP.home_rel = (a and b) and sub(a, b) or nil
  local vc = launch_in_vab(ROVER, "runway", 6)
  if not TP.check("rover", vc ~= nil, "the template rover rolled out") then return false end
  if vc.releaseClamps then vc.releaseClamps() end
  wait(2)
  tap("f"); wait(2.5)
  local bh = findScript("build_host")
  if bh and bh.state == "building" and bh.leave then pcall(bh.leave); wait(1.5) end
  a, b = astro(), home()
  if a and b and TP.home_rel then a.x, a.y, a.z = b.x + TP.home_rel.x, b.y + TP.home_rel.y, b.z + TP.home_rel.z; a.vx, a.vy, a.vz = 0, 0, 0 end
  wait(2)
  local T = TP.template(vc)
  if not TP.check("template", T ~= nil, "%d parts", T and #T.parts or 0) then return false end
  TP.rover = vc
  local C = findScript("crew")
  -- the crew: #1 you, #2 at base, #3 300 m off on foot, #4 on a moon
  local R = C.roster()
  TP.ids = {}
  for i, r in ipairs(R) do TP.ids[i] = r.id end
  local co = findScript("company")
  if co and co.earn then co.earn(50000, "probe") end
  for _ = 1, 5 - #R do if C.hire then C.hire(1, { free = true }) end end
  R = C.roster()
  for i, r in ipairs(R) do TP.ids[i] = r.id end
  TP.me = C.activeId()
  local others = {}
  for _, id in ipairs(TP.ids) do if id ~= TP.me then others[#others + 1] = id end end
  TP.base_id, TP.near_id, TP.moon_id, TP.seat_id = others[1], others[2], others[3], others[4]
  if TP.seat_id then C.patch(TP.seat_id, { status = "aboard", craft = "Kestrel 02", body = false, x = false, y = false, z = false }) end
  C.patch(TP.base_id, { status = "base", craft = false, body = false, x = false, y = false, z = false })
  local u, t1, t2, Rr = base_frame()
  local au = unit(sub(a, b))
  local nd = dir_at(au, t1, 300, Rr)
  local ng = ground_r(b, nd.x, nd.y, nd.z, Rr + 200) or Rr
  C.setDown(TP.near_id, b.x + nd.x * (ng + 1.0), b.y + nd.y * (ng + 1.0), b.z + nd.z * (ng + 1.0))
  local m = TP.moon()
  TP.moon_body = m and m.name
  if m then
    C.patch(TP.moon_id, { status = "afoot", craft = false, body = m.name, x = 0, y = m.radius + 2.0, z = 0, o2 = 1.0, helmet = true })
  end
  -- the fleet
  local k = 0
  for i = 1, 49 do
    k = k + 1
    if i % 7 == 0 then TP.add(T, k, "far", { name = string.format("Outpost %02d", i), d = 3000 + i * 560 })
    elseif i % 7 == 1 then TP.add(T, k, "near", { name = string.format("Yard %02d", i), d = 80 + i * 4 })
    else
      local shell = 1 + (i % 3)
      local fid = TP.add(T, k, "orbit", { name = string.format("%s %02d", ({ "Kestrel", "Comsat", "Survey" })[shell], i),
        shell = shell, r = ({ 1.35, 1.8, 2.5 })[shell], phase = i * 0.61, core = (i % 3 == 0), seat = (i == 2) and TP.seat_id or nil })
      if i == 2 then TP.seated_fid = fid end
    end
  end
  TP.near_fid = "tp1"
  local fo = findScript("flight_ops")
  if fo and fo.fleetRescan then fo.fleetRescan() end
  -- 200 packed debris: three quarters in orbit, the rest down 2–20 km out
  local recs = {}
  for i = 1, 200 do
    local rec
    if i % 4 == 0 then
      local d = dir_at(u, unit(TP.rot(t1, u, i * 0.37)), 2000 + i * 90, Rr)
      local g = ground_r(b, d.x, d.y, d.z, Rr + 400) or Rr
      rec = { name = "debris", body = b.name, x = d.x * (g + 0.5), y = d.y * (g + 0.5), z = d.z * (g + 0.5), vx = 0, vy = 0, vz = 0, kind = "landed" }
    else
      local n = unit(TP.rot(cross(u, t1), t1, (i % 5 - 2) * 0.3))
      local dir = unit(TP.rot(u, n, i * 0.27))
      local r = Rr * (1.25 + (i % 17) * 0.08)
      local vt = math.sqrt(b.mu / r)
      local tv = unit(cross(n, dir))
      rec = { name = "debris", body = b.name, x = dir.x * r, y = dir.y * r, z = dir.z * r, vx = tv.x * vt, vy = tv.y * vt, vz = tv.z * vt, kind = "orbit" }
    end
    rec.pitch, rec.yaw, rec.roll, rec.stime, rec.tags = 0, 0, 0, space.time(), { "tp" }
    rec.parts = { { prefab = "PartTankS", x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 } }
    recs["dtp" .. i] = rec
  end
  save.set("debris.packed", recs)
  local dp = findScript("debris_pack")
  if dp and dp.reloadStore then dp.reloadStore() end
  -- relays, flags, structures
  local net, dep, stc = findScript("comms"), findScript("deployables"), findScript("structures")
  for i, d in ipairs({ 500, 1500, 3200, 6400 }) do
    local dd = dir_at(u, unit(TP.rot(t2, u, i * 1.3)), d, Rr)
    local g = ground_r(b, dd.x, dd.y, dd.z, Rr + 400) or Rr
    if net and net.placeBeacon then pcall(net.placeBeacon, b.name, b.x + dd.x * g, b.y + dd.y * g, b.z + dd.z * g) end
  end
  for i, d in ipairs({ 220, 2600, 9000 }) do
    local dd = dir_at(u, unit(TP.rot(t1, u, 2.0 + i)), d, Rr)
    local g = ground_r(b, dd.x, dd.y, dd.z, Rr + 400) or Rr
    if dep and dep.place then pcall(dep.place, "flag", b.name, b.x + dd.x * g, b.y + dd.y * g, b.z + dd.z * g, { ceremony = false, name = "Flag " .. i }) end
  end
  for i, d in ipairs({ 260, 420, 4000 }) do
    local dd = dir_at(u, unit(TP.rot(t2, u, -1.0 - i)), d, Rr)
    local g = ground_r(b, dd.x, dd.y, dd.z, Rr + 400) or Rr
    if stc and stc.newRecord and stc.add then
      pcall(function()
        stc.add(stc.newRecord(nil, b.name, dd.x * g, dd.y * g, dd.z * g, dd, unit(cross(dd, t1)), "padPlate", { name = "Pad " .. i }))
      end)
    end
  end
  local ok = wait_for(function()
    local n = 0
    for _, v in ipairs(findScripts("vessel_controller")) do if v.node and v.node.valid then n = n + 1 end end
    return n >= 40
  end, 60, "the fleet rebuilt")
  TP.check("fleet", ok ~= nil, "%d live craft", #findScripts("vessel_controller"))
  wait(3)
  return true
end

-- every frame the station draws: its anchors against the drawn poses
function TP.watch_on()
  local ts = findScript("tracking_station")
  TP.fw = { n = 0, worst = 0, worst_id = nil, frames = 0, off = 0 }
  ts.probeHook = function(A, B, S)
    local W = TP.fw
    W.frames = W.frames + 1
    local now = space.time()
    for id, a in pairs(A) do
      local e = S.byId[id]
      if e then
        local x, y, z
        if e.node and e.node.valid ~= false then x, y, z = e.node.x, e.node.y, e.node.z
        else
          local b = B[e.body]
          if b and e.rx then
            if e.conic and (b.mu or 0) > 0 then
              local px, py, pz = space.propagate(e.rx, e.ry, e.rz, e.vx or 0, e.vy or 0, e.vz or 0, b.mu, now - (e.st or 0))
              x, y, z = b.x + px, b.y + py, b.z + pz
            else x, y, z = b.x + e.rx, b.y + e.ry, b.z + e.rz end
          end
        end
        if x then
          local sx, sy, _, on = camera.worldToScreen(x, y, z)
          if on then
            local d = math.sqrt((sx - a[1]) ^ 2 + (sy - a[2]) ^ 2)
            W.n = W.n + 1
            if d > W.worst then W.worst, W.worst_id = d, id end
            if d > 1.0 then W.off = W.off + 1 end
          end
        end
      end
    end
  end
end
function TP.watch_off() local ts = findScript("tracking_station"); ts.probeHook = nil end

function TP.labels(tag, want_sel)
  local ts = findScript("tracking_station")
  local L = ts.labelsNow()
  local over = 0
  for i = 1, #L do for j = i + 1, #L do
    local a, b = L[i], L[j]
    if a.x + 0.01 < b.x + b.w and a.x + a.w > b.x + 0.01 and a.y + 0.01 < b.y + b.h and a.y + a.h > b.y + 0.01 then over = over + 1 end
  end end
  local under = 0
  for _, l in ipairs(L) do
    for _, r in ipairs(ts.panelRects()) do
      if l.x < r[1] + r[3] and l.x + l.w > r[1] and l.y < r[2] + r[4] and l.y + l.h > r[2] then under = under + 1 end
    end
  end
  local sel = false
  for _, l in ipairs(L) do if l.id == ts.selectedId() then sel = true end end
  TP.check("labels_" .. tag, over == 0 and under == 0 and #L <= 40 and (sel or not want_sel),
    "%d tags, %d overlapping, %d under a panel, selection tagged %s (%s)", #L, over, under, tostring(sel), tostring(ts.selectedId()))
end

function TP.perf_window(tag, secs)
  local ts = findScript("tracking_station")
  local ms, n = 0, 0
  local t1 = W() + secs
  local s0 = { perf.scriptMs("tracking_station"), perf.scriptMs("fleet_view"), perf.scriptMs("orbit_map"),
               lists = ts.stats.lists, cards = ts.stats.cards, strips = ts.stats.strips, tops = ts.stats.tops, layouts = ts.stats.layouts }
  local acc = { 0, 0, 0 }
  local fr = 0
  while W() < t1 do
    yield()
    ms, n = ms + (ts.stats.ms or 0), n + 1
    acc[1] = acc[1] + perf.scriptMs("tracking_station")
    acc[2] = acc[2] + perf.scriptMs("fleet_view")
    acc[3] = acc[3] + perf.scriptMs("orbit_map")
    fr = fr + 1
  end
  local out = { draw = ms / math.max(1, n), ts = acc[1] / math.max(1, fr), fv = acc[2] / math.max(1, fr), om = acc[3] / math.max(1, fr) }
  P("TP PERF %s: map pass %.3f ms (os.clock), scripts: tracking_station %.3f, fleet_view %.3f, orbit_map %.3f ms; drawn %d icons, %d tags, %d layouts",
    tag, out.draw, out.ts, out.fv, out.om, ts.stats.drawn or 0, ts.stats.tags or 0, ts.stats.layouts or 0)
  local st = ts.stats
  P("TP PERF %s parts (ms, smoothed): update %.3f a frame, anchors %.3f, layout %.3f (per run), draw %.3f, snapshot %.3f (per build), list %.3f, card %.3f, strip %.3f, top %.3f (per make)",
    tag, st.u_ms or 0, st.a_ms or 0, st.l_ms or 0, st.d_ms or 0, st.s_ms or 0, st.list_ms or 0, st.card_ms or 0, st.strip_ms or 0, st.top_ms or 0)
  local fs = findScript("fleet_view").stats or {}
  P("TP PERF %s snapshot (ms): fleetList %.3f, a build slice %.3f (the worst %.3f); anchors: %d projected, %d exact steps",
    tag, fs.list or 0, fs.slice or 0, fs.sliceMax or 0, st.n_proj or 0, st.n_prop or 0)
  local pj = ts.proj or {}
  P("TP PERF %s update split (ms, smoothed): snapshot %.3f (resume + stamp), hover %.3f, list signature %.3f", tag, st.u_snap or 0, st.u_hover or 0, st.u_sig or 0)
  P("TP PERF %s anchors split (ms): before %.3f, gather %.3f, project %.3f, points %.3f, tracks %.3f", tag, (st.a_ms or 0) - (st.a_gather or 0) - (st.a_proj or 0) - (st.a_pts or 0) - (st.a_tracks or 0), st.a_gather or 0, st.a_proj or 0, st.a_pts or 0, st.a_tracks or 0)
  P("TP PERF %s projection: mode %s, check error %.4f px, %d fallback frames so far; %d orbit lines; %s",
    tag, tostring(pj.mode), pj.err or -1, pj.fallbacks or 0, st.tracks or 0, tostring(pj.dbg))
  P("TP PERF %s makes over the window: list %d, card %d, strip %d, top %d, layouts %d (%d frames)", tag,
    st.lists - (s0.lists or 0), st.cards - (s0.cards or 0), st.strips - (s0.strips or 0), st.tops - (s0.tops or 0),
    st.layouts - (s0.layouts or 0), fr)
  return out
end

-- ── P3 / P4: filters, search, an opened cluster, the menu, the orbit lines ──
function TP.click(x, y, button)
  button = button or 0
  input.simulate({ mouse = { x, y } }); yield(); yield()
  input.simulate({ button = button, down = true }); yield(); yield()
  input.simulate({ button = button, down = false }); yield(); yield()
end
function TP.anchor_kinds(ts, fv)
  local S = fv.current()
  local n, deb, other = 0, 0, 0
  for id in pairs(ts.anchorsNow()) do
    local e = S.byId[id]
    n = n + 1
    if e and e.kind == "debris" then deb = deb + 1 elseif id ~= ts.selectedId() then other = other + 1 end
  end
  return n, deb, other
end
function TP.p3p4(ts, fv, om, b)
  om.setZoom(b.radius * 6); wait(1.5)
  -- the orbit lines: the ones that matter (default) against every one
  TP.shot("station_orbits_key")
  local key_tracks = ts.stats.tracks or 0
  ts.mapopt.orbits = "all"; ts.dirty_all = true; wait(1.0)
  local all_tracks = ts.stats.tracks or 0
  TP.shot("station_orbits_all")
  ts.mapopt.orbits = "key"; ts.dirty_all = true; wait(1.0)
  TP.check("orbits", key_tracks >= 1 and key_tracks < all_tracks, "orbit lines: %d that matter by default, %d with Orbits · all", key_tracks, all_tracks)
  -- the debris LOD: specks close in, nothing projected far out
  local _, deb_mid = TP.anchor_kinds(ts, fv)
  om.setZoom(b.radius * 40); wait(2.0)
  local _, deb_far = TP.anchor_kinds(ts, fv)
  om.setZoom(b.radius * 6); wait(1.5)
  TP.check("debris_lod", deb_mid > 50 and deb_far == 0, "debris projected: %d at mid zoom, %d far out (disc under %d px)", deb_mid, deb_far, ts.DEBRIS_DISC)
  -- the kind filter, on the list and the map
  ts.filter.kind = "craft"; ts.dirty_all = true; wait(1.0)
  local n1, d1 = TP.anchor_kinds(ts, fv)
  local V = ts.listView()
  TP.check("filter_craft", d1 == 0 and V.n >= 45 and V.n <= 52, "Craft: %d in the list, %d anchors, %d debris on the map", V.n, n1, d1)
  ts.filter.kind = "all"; ts.dirty_all = true; wait(0.5)
  -- the search, typed into the real field (the engine's text path) when it can be found
  local fld = find and (find("FieldStationSearch") or find("srch"))
  local typed = false
  if fld and ui and ui.focus then
    pcall(ui.focus, fld); yield(); yield()
    input.simulate({ text = "Comsat" }); wait(0.6)
    typed = ts.filter.q == "Comsat"
    P("TP search field: found, focused %s, typing() %s, filter.q '%s'", tostring(ts.typing()), tostring(ts.typing()), tostring(ts.filter.q))
  end
  if not typed then ts.filter.q = "Comsat"; ts.dirty_all = true; wait(0.6) end
  local stray, tags = 0, 0
  for _, l in ipairs(ts.labelsNow()) do
    local e = fv.current().byId[l.id]
    tags = tags + 1
    if e and not tostring(e.name):find("Comsat", 1, true) and l.id ~= ts.selectedId() then stray = stray + 1 end
  end
  V = ts.listView()
  TP.check("search", V.n >= 10 and V.n <= 20 and stray == 0, "search 'Comsat' (%s): %d rows, %d tags, %d on others",
    typed and "typed into the field" or "set", V.n, tags, stray)
  TP.shot("station_search")
  if ui and ui.focus then pcall(ui.focus, nil) end
  ts.filter.q = ""; ts.dirty_all = true; wait(0.6)
  -- an opened cluster: a click on a disc, then a click on a name in it
  local A, pick_c
  for _, zf in ipairs({ 2.2, 6, 3.5, 12 }) do
    if not pick_c then
      om.setZoom(b.radius * zf); wait(2.0)
      A = ts.anchorsNow()
      for _, c in ipairs(ts.clustersNow()) do
        local s = A[c.seed]
        if s and not ts.ownsPointer(s[1] + c.ox, s[2] + c.oy) and (not pick_c or c.n > pick_c.n) then pick_c = c end
      end
    end
  end
  if pick_c then
    local s = A[pick_c.seed]
    local cx, cy = s[1] + pick_c.ox, s[2] + pick_c.oy
    TP.click(cx, cy, 0)
    wait(0.3)
    local F, R = ts.fanNow()
    TP.check("fan_open", F ~= nil and R ~= nil, "a click on a cluster of %d opens its column (%s)", pick_c.n, F and (#F.members .. " names") or "none")
    if F and R then
      local k = (select(2, camera.screenSize()) or 720) / ts.uiDesignH()
      local row_h = 12 * k * 1.55
      local want = F.members[2]
      input.simulate({ mouse = { R[1] + R[3] / 2, R[2] + row_h * 2 + 2 * k + row_h * 0.5 } }); wait(0.4)
      TP.shot("station_fan")
      TP.click(R[1] + R[3] / 2, R[2] + row_h * 2 + 2 * k + row_h * 0.5, 0)
      wait(0.3)
      TP.check("fan_pick", ts.selectedId() == want and ts.fanNow() == nil, "a click on a name selects it (%s, wanted %s)", tostring(ts.selectedId()), tostring(want))
    end
  else
    TP.check("fan_open", false, "no cluster on screen at close zoom")
  end
  -- the shared menu: a right-button tap on a lone icon
  om.setZoom(b.radius * 6); wait(1.5)
  A = ts.anchorsNow()
  local mem = {}
  for _, c in ipairs(ts.clustersNow()) do for _, id in ipairs(c.members) do mem[id] = true end end
  local ids = {}
  for id in pairs(A) do ids[#ids + 1] = id end
  table.sort(ids)
  local lone
  for _, id in ipairs(ids) do
    local e = fv.current().byId[id]
    local a = A[id]
    if e and e.craft and not mem[id] and not ts.ownsPointer(a[1], a[2]) then
      local clear = true
      for _, j in ipairs(ids) do
        local q = A[j]
        if j ~= id and (q[1] - a[1]) ^ 2 + (q[2] - a[2]) ^ 2 < 24 ^ 2 then clear = false break end
      end
      if clear then lone = id break end
    end
  end
  local cm = findScript("context_menu")
  if lone and cm then
    TP.click(A[lone][1], A[lone][2], 1)
    wait(0.5)
    local t = cm.target
    local lt = ts.lastTap or {}
    P("TP menu tap: moved %.1f px, %.3f s, id %s, cluster %s", lt.moved or -1, lt.dt or -1, tostring(lt.id), tostring(lt.cl))
    TP.check("menu", cm.open and t and t.kind == "fleet" and t.id == lone, "a right-click on %s opens the fleet menu (%s)", lone,
      cm.open and tostring(t and t.kind) or "shut")
    TP.shot("station_menu")
    if cm.close then cm.close() end
    wait(0.3)
  else
    TP.check("menu", false, "no lone craft icon to right-click (%s)", tostring(cm ~= nil))
  end
  input.simulate({ mouse = { 4, 4 } }); wait(0.3)
  ts.selectCraft("tp9"); wait(0.5)
end

function TP.run()
  if not TP.setup() then TP.result() return end
  local om, ts, C, fo, gm = findScript("orbit_map"), findScript("tracking_station"), findScript("crew"),
    findScript("flight_ops"), findScript("game_manager")
  local b = home()
  -- ── shots and labels ──
  tap("f2"); wait(1.5)
  TP.check("open_f2", ts.isOpen() and om.mode == "station", "F2 on foot opens the station")
  local fv = findScript("fleet_view")
  local S = fv.snapshot(true)
  TP.check("snapshot", (S.counts.craft or 0) >= 45 and (S.counts.debris or 0) >= 150 and (S.counts.relays or 0) >= 4,
    "%d craft, %d debris, %d relays, %d crew in the snapshot", S.counts.craft or 0, S.counts.debris or 0, S.counts.relays or 0, S.counts.crew or 0)
  ts.selectCraft("tp9")
  for i, z in ipairs({ b.radius * 2.2, b.radius * 6, b.radius * 22 }) do
    om.setZoom(z); wait(2.0)
    TP.labels("z" .. i, true)
    TP.shot("station_z" .. i)
  end
  om.setZoom(b.radius * 6); wait(1.0)
  TP.p3p4(ts, fv, om, b)
  om.setZoom(b.radius * 6); wait(1.0)
  -- ── perf: STATION against CHART ──
  local ps = TP.perf_window("station", 6)
  om.setMode("chart"); wait(1.5)
  local pc = TP.perf_window("chart", 6)
  TP.shot("chart_z2")
  om.setMode("station"); wait(1.0)
  -- the station's own Lua a frame: its map pass (timed inside drawMap, which
  -- the engine bills to orbit_map) plus its script (panels, snapshot)
  local cost = ps.draw + ps.ts + ps.fv
  TP.check("perf", cost <= 1.2, "the station costs %.3f ms of Lua a frame (map pass %.3f + tracking_station %.3f + fleet_view %.3f); orbit_map %.3f in STATION vs %.3f in CHART",
    cost, ps.draw, ps.ts, ps.fv, ps.om, pc.om)
  -- ── frames at ×100 ──
  TP.watch_on()
  if TP.moon_id then C.patch(TP.moon_id, { o2 = 1.0, blackout = false, leftAt = false }) end
  space.warp(100)
  wait(10)
  local W = TP.fw
  TP.check("frames_x100", W.n > 1000 and W.off == 0, "%d anchors over %d frames, worst %.3f px (%s), %d over 1 px",
    W.n, W.frames, W.worst, tostring(W.worst_id), W.off)
  TP.labels("x100", true)
  TP.shot("station_x100")
  space.warp(1); wait(1.0)
  TP.watch_off()
  -- ── open / close 30 times ──
  local n0 = (perf.counts() or {}).nodes or 0
  for _ = 1, 30 do tap("f2"); wait(0.15) end
  wait(1.0)
  if not ts.isOpen() then tap("f2"); wait(0.5) end
  local n1 = (perf.counts() or {}).nodes or 0
  TP.check("open_close", n1 - n0 < 40, "nodes %d before, %d after 30 open/close (no growth)", n0, n1)
  -- ── actions ──
  S = fv.snapshot(true)
  local near = S.byId[TP.near_fid]
  local co = findScript("company")
  if near and near.recover and near.recover.ok then
    local bal0 = co.balance and co.balance() or 0
    local q = near.recover.value
    local okr = ts.recoverFleet(TP.near_fid)
    local bal1 = co.balance and co.balance() or 0
    TP.check("recover", okr and math.abs((bal1 - bal0) - q) < 1, "RECOVER paid %d (quote %d)", bal1 - bal0, q)
  else
    TP.check("recover", false, "the near craft is not recoverable: %s", tostring(near and near.recover and near.recover.why))
  end
  local orb = S.byId.tp9
  TP.check("recover_why", orb and orb.recover and not orb.recover.ok and tostring(orb.recover.why):find("only a craft") ~= nil,
    "in orbit: %s", tostring(orb and orb.recover and orb.recover.why))
  -- the crewed card, far away
  ts.selectCraft("m:" .. tostring(TP.moon_id)); wait(0.6)
  TP.shot("station_card_moon")
  -- ── crew switching ──
  ts.close(); wait(0.5)
  b = home()
  local a = astro()
  local before = sub(a, b)
  local p0 = { x = b.x, y = b.y, z = b.z }
  local okn = C.switchToMember(TP.near_id)
  wait(1.5)
  TP.check("switch_near", okn and C.activeId() == TP.near_id, "to the member 300 m off")
  wait_for(function() local bb = home(); return len(bb.x - p0.x, bb.y - p0.y, bb.z - p0.z) > 500 end, 20, "the planet moving 500 m")
  local left = C.bodyOf(TP.me)
  local bb = home()
  local dl = left and len(left.x - bb.x - before.x, left.y - bb.y - before.y, left.z - bb.z - before.z) or -1
  local rr = C.get(TP.me) or {}
  local dr = left and rr.x and len(left.x - bb.x - rr.x, left.y - bb.y - rr.y, left.z - bb.z - rr.z) or -1
  local drec = rr.x and len(rr.x - before.x, rr.y - before.y, rr.z - before.z) or -1
  local radial = 0
  if left then
    local lr = len(left.x - bb.x, left.y - bb.y, left.z - bb.z)
    radial = lr - len(before.x, before.y, before.z)
  end
  TP.check("left_behind", left ~= nil and dl >= 0 and dl < 0.5,
    "the one left stands %.3f m from where they were (%.3f m of it up/down; their record %.3f m from it, the body %.3f m from the record; planet moved %.0f m)",
    dl, radial, drec, dr, len(bb.x - p0.x, bb.y - p0.y, bb.z - p0.z))
  local okb = C.switchToMember(TP.base_id)
  wait(1.5)
  local hx, hy, hz = ts.crewHome()
  a = astro()
  TP.check("switch_base", okb and C.activeId() == TP.base_id and hx and len(a.x - hx, a.y - hy, a.z - hz) < 3.0,
    "to the member at base: standing %.2f m from the crew home", hx and len(a.x - hx, a.y - hy, a.z - hz) or -1)
  TP.goto_moon(C, gm)
  if TP.seated_fid then
    local v = fo.liveOf(TP.seated_fid)
    local seated = TP.seat_id
    if seated and seated ~= C.activeId() then
      local okc = C.switchToMember(seated)
      wait(2.0)
      TP.check("switch_craft", okc and v.piloting and C.activeId() == seated, "to the member seated in %s (orbit)", tostring(v.craftName))
    else
      TP.check("switch_craft", false, "no member seated in the orbiter (live %s)", tostring(v ~= nil))
    end
  end
  TP.result()
end
function TP.goto_moon(C, gm)
  local a
  if TP.moon_id and TP.moon_body then
    -- (the ×100 window aged everyone 1,000 s: the member left on an airless
    -- moon may have run their suit down — the left-behind rule. Say how they
    -- are, then refill them so the trip has someone to arrive as.)
    local mr = C.get(TP.moon_id) or {}
    P("TP moon member before the trip: %s, o2 %.2f%s", tostring(mr.status), mr.o2 or -1, mr.blackout and " (blacked out)" or "")
    if mr.status ~= "dead" then C.patch(TP.moon_id, { o2 = 1.0, blackout = false, leftAt = false }) end
    local cok, cwhy, cmode, cdet = C.canSwitch(TP.moon_id)
    local bd = C.bodyOf(TP.moon_id)
    local cur = C.current()
    local cn = cur.kind == "vessel" and cur.v.node or astro()
    P("TP moon member: canSwitch %s %s %s %s; a body %s, %.0f m from what you control (%s)", tostring(cok), tostring(cwhy),
      tostring(cmode), tostring(cdet), tostring(bd ~= nil), (bd and cn) and len(bd.x - cn.x, bd.y - cn.y, bd.z - cn.z) or -1,
      cur.kind)
    local okm, how = C.switchToMember(TP.moon_id)
    wait(0.5)
    local up = gm.travel ~= nil or gm.curtain
    TP.check("goto_curtain", okm and how == "travel" and up, "GO TO %s: the curtain is up", TP.moon_body)
    local done = wait_for(function() return gm.travel == nil and C.activeId() == TP.moon_id end, 70, "the trip to the moon")
    wait(2.0)
    a = astro()
    local mb = space.body(TP.moon_body)
    local ux, uy, uz = 0, 1, 0
    if mb then
      local l = len(a.x - mb.x, a.y - mb.y, a.z - mb.z)
      ux, uy, uz = (a.x - mb.x) / l, (a.y - mb.y) / l, (a.z - mb.z) / l
    end
    local h = raycast(a.x + ux * 2, a.y + uy * 2, a.z + uz * 2, -ux, -uy, -uz, 20, a)
    TP.check("goto_arrive", done ~= nil and space.dominant(a.x, a.y, a.z) == TP.moon_body and h ~= nil and h.distance < 5,
      "arrived as them on %s, the ground %.2f m under the feet", TP.moon_body, h and h.distance - 2 or -1)
    TP.shot("goto_moon")
    tap("f2"); wait(1.5)
    TP.shot("station_from_moon")
    tap("f2"); wait(0.5)
  end
end
function TP.result() P("TP RESULT track: %s (%d passed, %d failed)", TP.fails == 0 and "PASS" or "FAIL", TP.passed, TP.fails) end
