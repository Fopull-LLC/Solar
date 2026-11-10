-- ── ruin probe (tools/perf/ruinprobe.sh; expansion X8, "Abandoned bases";
-- docs/base-building.md §26, docs/tracking-station.md §6.2)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam).
--   ruins   the home world's sites (from the seed), one moved to flat ground
--           on the far side (lit), the crew walked in: 700 m nothing, 500 m
--           stamped (paced: parts a frame), 300 m found; the five kinds
--           stamped in turn there and pictured from two sides; the frame at
--           one camera with no ruin, while one streams in, and with the
--           biggest (the power hall) standing; walked 1.2 km off: an
--           untouched ruin leaves the records, a touched one stays unloaded
--           (no nodes); a scanner's swath and a telescope find the others;
--           the Tracking Station's ruin entry, card and map marker; a crate
--           searched, the core pulled and read; the claim (a base founded
--           under the site's name, its roles), restore, a repair; the base
--           card (the side check: its stats box whole); the costs.
-- `RN PASS|FAIL <check>`, `RN …` lines and `RN RESULT`. Pictures: save/user/ruinshots/.
RN = { fails = 0, passed = 0 }
function RN.check(name, okc, fmt, ...)
  P("RN %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then RN.passed = RN.passed + 1 else RN.fails = RN.fails + 1 end
  return okc
end
function RN.result() P("RN RESULT %s (%d passed, %d failed)", RN.fails == 0 and "PASS" or "FAIL", RN.passed, RN.fails) end
function RN.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://ruinshots/" .. nm .. ".png", bytes); P("RN SHOT %s", nm)
    else P("RN SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function RN.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  local RU, ST = findScript("ruins"), findScript("structures")
  local c = perf.counts() or {}
  P("RN COST %s: ruins %.4f ms/frame, structures %.4f, base_tower %.4f, fleet_view %.4f, tracking_station %.4f · tick %.3f ms · draws %s instances %s triangles %s nodes %s",
    tag, ms("ruins"), ms("structures"), ms("base_tower"), ms("fleet_view"), ms("tracking_station"), RU.stats.ms or 0,
    tostring(c.draws), tostring(c.instances), tostring(c.triangles), tostring(c.nodes))
  return ms("ruins")
end
-- the flattest dry, lit ground on the far side of the home world
function RN.far_spot()
  local b = home()
  local u, t1, t2, R = base_frame()
  local E = findScript("electronics")
  local cl = findScript("climate")
  local sun = E and E.sunOf and E.sunOf(b.x, b.y, b.z, space.bodies() or {}) or nil
  local sd = sun and unit(sub(sun, b)) or nil
  local best
  for _, frac in ipairs({ 0.9, 0.8, 0.7 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, math.pi * R * frac, R)
      local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if g0 then
        local tt = unit(sub(t, scl(dir, dot(t, dir))))
        local s = unit(cross(dir, tt))
        local lo, hi, n = g0, g0, 0
        for _, e in ipairs({ { 11, 0 }, { -11, 0 }, { 0, 11 }, { 0, -11 }, { 8, 8 }, { -8, -8 }, { 8, -8 }, { -8, 8 } }) do
          local dd = unit({ x = dir.x * R + tt.x * e[1] + s.x * e[2], y = dir.y * R + tt.y * e[1] + s.y * e[2], z = dir.z * R + tt.z * e[1] + s.z * e[2] })
          local g = ground_r(b, dd.x, dd.y, dd.z, R + 150)
          if g then lo, hi, n = math.min(lo, g), math.max(hi, g), n + 1 end
        end
        local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        local lit = sd and dot(dir, sd) or 0
        if n >= 7 and not wet then
          local score = (hi - lo) + (lit > 0.25 and 0 or 2.0)
          if not best or score < best.score then best = { dir = dir, r = g0, t = tt, score = score, spread = hi - lo, lit = lit } end
        end
      end
    end
  end
  return best
end
function RN.daylight(dir, tmo)
  local E = findScript("electronics")
  local function lit()
    local b = home()
    local sun = E and E.sunOf and E.sunOf(b.x, b.y, b.z, space.bodies() or {})
    return sun and dot(dir, unit(sub(sun, b))) or 1
  end
  local l0 = lit()
  if l0 >= 0.35 then return end
  local t0 = W()
  space.warp(50)
  while W() - t0 < (tmo or 60) and lit() < 0.45 do yield() end
  space.warp(1)
  wait(1.0)
  P("RN daylight: %.2f → %.2f (%.0f s of warp)", l0, lit(), W() - t0)
end
-- the crew `d` m from the site along the ground, on the ground
function RN.crew_at(s, d)
  local b = home()
  local u = { x = s.ux, y = s.uy, z = s.uz }
  local RU = findScript("ruins")
  local e1x, e1y, e1z = RU.tangent(s.ux, s.uy, s.uz)
  local dir = dir_at(u, { x = e1x, y = e1y, z = e1z }, d, b.radius)
  local gr = ground_r(b, dir.x, dir.y, dir.z, b.radius + 150) or b.radius
  -- (held for a few frames: a body swimming or settling can take the first back)
  for _ = 1, 20 do stand_at({ dir = dir, r = gr }); yield() end
end
-- a camera in the site's frame (eye and target in its right/up/front, metres)
function RN.cam(g, ex, ey, ez, tx, ty, tz)
  local U = { x = g.ux, y = g.uy, z = g.uz }
  local F = { x = g.fx, y = g.fy, z = g.fz }
  local Rt = unit(cross(U, F))
  local function at(x, y, z) return { x = g.x + Rt.x * x + U.x * y + F.x * z, y = g.y + Rt.y * x + U.y * y + F.y * z, z = g.z + Rt.z * x + U.z * y + F.z * z } end
  VP.cam_fixed(at(ex, ey, ez), at(tx, ty, tz))
end
function RN.wait_spawned(ST, sid, tmo)
  local t0 = W()
  wait_for(function()
    if not ST.isLive(sid) or ST.pacing() > 0 then return false end
    local ns = ST.nodesOf(sid)
    return ns and #ns > 0
  end, tmo or 15, "the ruin's pieces")
  wait(0.5)
  local ns = ST.nodesOf(sid)
  return ns and #ns or 0, W() - t0
end

function RN.run()
  wait_ready(120)
  wait(2)
  local RU, ST, B, BR, SV, TS, FV, OM, inv, C, co = findScript("ruins"), findScript("structures"), findScript("bases"),
    findScript("base_roles"), findScript("survey"), findScript("tracking_station"), findScript("fleet_view"), findScript("orbit_map"),
    findScript("inventory"), findScript("crew"), findScript("company")
  if not RN.check("scene", RU and ST and B and TS and FV and OM and inv, "ruins %s structures %s", tostring(RU ~= nil), tostring(ST ~= nil)) then RN.result() return end
  if perf.enable then perf.enable(true) end
  local gx = findScript("graphics")
  if gx and gx.set then gx.set(tostring(params.gfx or "High")) end
  if co and co.earn then co.earn(500000, "probe") end
  local r0 = RN.cost("idle: the home world's sites rolled, none near", 6)
  RN.check("idle_cost", r0 >= 0 and r0 < 0.02, "ruins %.4f ms a frame (a 1 Hz tick)", r0)
  local b = home()
  local list = RU.sites(b.name)
  for _, s in ipairs(list) do
    P("RN SITE %s: %s · %s · %d days · %s%s", s.id, s.name, s.kind, s.age, RU.latlon(s.ux, s.uy, s.uz), s.pending and " · PENDING (the life seam)" or "")
  end
  local nall, worlds = 0, 0
  for _, bb in ipairs((save.get("system.home") or {}).bodies or {}) do
    local w = save.get("world." .. bb.name) or {}
    local ss = RU.sites(bb.name)
    worlds = worlds + 1
    nall = nall + #ss
    P("RN WORLD %s: %s (atmo %.2f, %s) · %d site(s)", bb.name, RU.worldClass(bb.name, w, bb.name == b.name), w.atmo or 0, tostring(w.geo and w.geo.family), #ss)
  end
  local s = nil
  for _, x in ipairs(list) do if not x.pending then s = x; break end end
  if not RN.check("sites", s ~= nil, "%d sites on %s, %d over %d worlds", #list, b.name, nall, worlds) then RN.result() return end
  -- 1. move the site to the far side's flattest lit ground, the crew walking in
  local spot = RN.far_spot()
  if not RN.check("spot", spot ~= nil, "flat ground on the far side (spread %.2f m, lit %.2f)", spot and spot.spread or -1, spot and spot.lit or -1) then RN.result() return end
  RN.daylight(spot.dir, 60)
  s.ux, s.uy, s.uz = spot.dir.x, spot.dir.y, spot.dir.z
  s.kind = tostring(params.rkind or "hab")
  s.name = RU.siteName(s.co, s.kind, s.num)
  RU.state(s.id)
  local SS = save.get("ruins.s") or {}
  SS[s.id] = nil
  save.set("ruins.s", SS)
  RU.reset()
  list = RU.sites(b.name)
  for _, x in ipairs(list) do if x.id == s.id then x.ux, x.uy, x.uz, x.kind, x.name = s.ux, s.uy, s.uz, s.kind, s.name; s = x end end
  RN.crew_at(s, 700)
  wait(3)
  RN.check("far", not RU.discovered(s.id) and RU.state(s.id).sid == nil, "700 m: not found, not stamped")
  RN.crew_at(s, 500)
  wait_for(function() return RU.state(s.id).sid ~= nil or RU.state(s.id).drop ~= nil end, 30, "the stamp")
  local e = RU.state(s.id)
  if not RN.check("stamped", e.sid ~= nil, "500 m: stamped as structure %s (%d pieces; dropped: %s) in %.2f ms", tostring(e.sid), e.n or 0, tostring(e.drop), RU.stats.stamp_ms or -1) then RN.result() return end
  RN.check("not_found_yet", not RU.discovered(s.id), "…not found yet at 500 m")
  local n0 = ST.pacedParts
  local nn, secs = RN.wait_spawned(ST, e.sid, 15)
  RN.check("paced", ST.pacedParts - n0 >= nn - 2, "%d nodes streamed in over %.1f s, %d through the paced queue", nn, secs, ST.pacedParts - n0)
  RN.crew_at(s, 300)
  wait(2.5)
  RN.check("proximity", RU.discovered(s.id) and RU.state(s.id).dsc == "proximity", "300 m: found (%s)", tostring(RU.state(s.id).dsc))
  -- 2. the five kinds, pictured
  local g = RU.state(s.id).g
  RN.crew_at(s, 40)
  wait(2)
  local pc = findScript("planet_camera")
  for _, k in ipairs(RU.kinds()) do
    local ee = RU.state(s.id)
    if ee.sid then ST.remove(ee.sid) end
    ee.sid, ee.n, ee.tc, ee.cl, ee.core, ee.lf, ee.silo = nil, nil, nil, nil, nil, nil, nil
    s.kind = k
    s.name = RU.siteName(s.co, k, s.num)
    local sid = RU.stampNow(s.id, true)
    local n1 = RN.wait_spawned(ST, sid, 15)
    local r = ST.get(sid)
    local worn, lean = 0, 0
    for _, p in ipairs(r.bp) do if p.wr then worn = worn + 1 end if (p.pitch or 0) ~= 0 and p.rl == "wall" then lean = lean + 1 end end
    P("RN KIND %s: %s · %d pieces stand of %d (%d nodes) · %d knocked, %d walls leaning · %.2f ms to stamp", k, s.name, #r.bp, #RU.blueprintOf(s), n1, worn, lean, RU.stats.stamp_ms or -1)
    local big = k == "reactor" and 1.6 or 1
    RN.cam(g, 11 * big, 11 * big, 13 * big, 2 * big, 1, -2 * big)
    if pc and pc.setFreecam then pc.setFreecam(true) end
    wait(1.2)
    RN.shot("kind_" .. k .. "_a", false)
    RN.cam(g, -10 * big, 10 * big, -12 * big, 3, 1, -2)
    wait(0.8)
    RN.shot("kind_" .. k .. "_b", false)
  end
  -- 3. THE FRAME: no ruin, one streaming in, the biggest standing (same camera)
  do
    local ee = RU.state(s.id)
    if ee.sid then ST.remove(ee.sid) end
    ee.sid, ee.n = nil, nil
    ee.drop = "probe: the baseline"   -- (held off: the 1 Hz tick would stamp it again at once)
    s.kind = "reactor"
    s.name = RU.siteName(s.co, "reactor", s.num)
    RN.cam(g, 18, 16, 22, 4, 1, -5)
    wait(3)
    sc_begin("r_noruin")
    wait(8)
    sc_end("r_noruin")
    RN.shot("frame_noruin", false)
    local c0 = perf.counts() or {}
    RN.check("baseline", ST.get(ee.sid or -1) == nil and RU.state(s.id).sid == nil, "the baseline has no ruin in the records")
    ee.drop = nil
    sc_begin("r_stream")
    local sid = RU.stampNow(s.id, true)
    local _, ss = RN.wait_spawned(ST, sid, 15)
    sc_end("r_stream")
    sc_begin("r_ruin")
    wait(8)
    sc_end("r_ruin")
    RN.shot("frame_ruin", false)
    local c1 = perf.counts() or {}
    P("RN FRAME: the power hall (%d pieces) streamed in over %.1f s; draws %s → %s, instances %s → %s, triangles %s → %s, nodes %s → %s, sunMapDraws %s → %s (see RESULT [r_noruin] / [r_stream] / [r_ruin])",
      #ST.get(sid).bp, ss, tostring(c0.draws), tostring(c1.draws), tostring(c0.instances), tostring(c1.instances), tostring(c0.triangles), tostring(c1.triangles),
      tostring(c0.nodes), tostring(c1.nodes), tostring(c0.sunMapDraws), tostring(c1.sunMapDraws))
    -- far: untouched → out of the records; touched → kept, unloaded
    VP.cam_off()
    RN.crew_at(s, 1200)
    wait(3)
    RN.check("unstamped", RU.state(s.id).sid == nil and ST.get(sid) == nil, "1.2 km away, untouched: out of the records (%d unstamps)", RU.stats.unstamps)
    local cfar0 = perf.counts() or {}
    RN.crew_at(s, 40)
    wait_for(function() return RU.state(s.id).sid ~= nil end, 20, "restamp")
    P("RN RESTAMP: sid %s, crew %.0f m from the site, drop %s", tostring(RU.state(s.id).sid), RU.stats.dist or -1, tostring(RU.state(s.id).drop))
    sid = RU.state(s.id).sid
    RN.wait_spawned(ST, sid, 15)
    RU.state(s.id).tc = 1
    RN.crew_at(s, 1200)
    wait(3)
    local cfar1 = perf.counts() or {}
    RN.check("unloaded", RU.state(s.id).sid == sid and ST.get(sid) ~= nil and not ST.isLive(sid) and ST.nodesOf(sid) == nil,
      "1.2 km away, touched: kept in the records, no nodes (draws %s with none in the records, %s with it unloaded)", tostring(cfar0.draws), tostring(cfar1.draws))
    RN.cost("1.2 km from a stamped ruin", 3)
  end
  -- 4. the main flow on a hab block
  do
    local ee = RU.state(s.id)
    if ee.sid then ST.remove(ee.sid) end
    ee.sid, ee.n, ee.tc = nil, nil, nil
    s.kind = "hab"
    s.name = RU.siteName(s.co, "hab", s.num)
  end
  RN.crew_at(s, 25)
  wait_for(function() return RU.state(s.id).sid ~= nil end, 10, "the hab stamped")
  local sid = RU.state(s.id).sid
  RN.wait_spawned(ST, sid, 15)
  local rec = ST.get(sid)
  RN.check("tower_held", RU.towerHeld(rec) and B.byTower(sid, (function() for _, p in ipairs(rec.bp) do if p.id == "tower" then return p.uid end end end)()) == nil,
    "the ruin's tower founds no base while unclaimed (%d bases)", #B.list())
  -- discovery by scanner and telescope on the other sites
  local others = {}
  for _, x in ipairs(RU.sites()) do if not x.pending and x.id ~= s.id and not RU.discovered(x.id) then others[#others + 1] = x end end
  if #others >= 1 then
    local o = others[1]
    local sw = SV.swathOf(o.body)
    local cells = SV.swathCells(SV.SWATH_N)
    local c = RU.cellOf(cells, o.ux, o.uy, o.uz)
    sw.mask[c] = true
    sw.n = sw.n + 1
    wait(6)
    RN.check("scanner", RU.discovered(o.id) and RU.state(o.id).dsc == "scanner", "%s on %s mapped by a scanner's swath (cell %d)", o.name, o.body, c)
  end
  if #others >= 2 then
    local o = others[2]
    local nt = RU.telescopeSwept(o.body, "tel30")
    RN.check("telescope", RU.discovered(o.id) or nt > 0, "a 0.3 m sweep of %s found %d (%s: %s)", o.body, nt, o.name, tostring(RU.state(o.id).dsc))
  end
  for _, x in ipairs(list) do if x.pending then RN.check("pending", not RU.discovered(x.id), "the pending site (the life seam) is never found; occupant() = %s", tostring(RU.occupant(x))) end end
  -- 5. the station: the ruin entry, its card, the map marker on it
  local OMv = findScript("orbit_map")
  OMv.openStation()
  wait(1.5)
  local S = FV.snapshot(true)
  local en = S.byId["u:" .. s.id]
  RN.check("entry", en ~= nil and en.glyph == "▣" and en.group == "STRUCTURES", "the ruin entry: %s %s · %s (%s)", tostring(en and en.glyph), tostring(en and en.name), tostring(en and en.sub), tostring(en and en.group))
  local dup = false
  for _, x in ipairs(S.entries) do if x.id == "s:" .. tostring(sid) then dup = true end end
  RN.check("no_dup", not dup, "its records are not a second STRUCTURES entry")
  TS.pickEntry("u:" .. s.id)
  OMv.setZoom(300)
  wait(2.0)
  RN.shot("station_ruin_card")
  OMv.setZoom(60)
  wait(1.5)
  RN.shot("station_ruin_marker")
  RN.cost("the station open on a ruin's card", 3)
  TS.close()
  OMv.close()
  wait(0.8)
  -- 6. the right-click rows, a crate, the core
  local REG = findScript("context_registry")
  local crate, core, tower = nil, nil, nil
  for _, p in ipairs(rec.bp) do
    if p.rl == "loot" and not crate then crate = p end
    if p.rl == "core" then core = p end
    if p.id == "tower" then tower = p end
  end
  local ctx = { actor = { kind = "crew", node = astro(), id = C.activeId(), pack = "astro" }, ref = findScript, toast = function(m) P("RN TOAST %s", m) end }
  local function rows_of(p)
    local n = ST.nodeOf(sid, p.uid)
    local out, title, sub = RU.providerFn({ kind = "prop", node = n }, ctx)
    local l = {}
    for _, r in ipairs(out or {}) do
      local lab = type(r.label) == "function" and r.label() or r.label
      local v = r.value and (type(r.value) == "function" and r.value() or r.value) or ""
      l[#l + 1] = tostring(lab) .. (v ~= "" and (": " .. v) or "")
    end
    P("RN ROWS %s (%s · %s): %s", p.id, tostring(title), tostring(sub), table.concat(l, " | "))
    return out
  end
  rows_of(tower)
  rows_of(core)
  rows_of(crate)
  local before = #(inv.itemList("astro") or {})
  local got, why = RU.searchCrate(s.id, crate.ri, "astro")
  RN.check("crate", got > 0 or why ~= nil, "searched the crate: %d things into the pack%s", got, why and (" (" .. why .. ")") or "")
  RN.check("crate_once", RU.searchCrate(s.id, crate.ri, "astro") == 0, "…once only")
  local okc = RU.pullCore(s.id, "astro")
  RN.check("core", okc and inv.itemCount("astro", "datacore") == 1, "the Data Core pulled (pack has %d)", inv.itemCount("astro", "datacore"))
  local rp0 = save.get("res.pts") or 0
  local nread = RU.readCores("astro")
  RN.check("read", nread == 1 and (save.get("res.pts") or 0) == rp0 + RU.RP.hab, "read at the lab: +%d RP (%d → %d); the log: %s", (save.get("res.pts") or 0) - rp0, rp0, save.get("res.pts") or 0,
    RU.lastRead and table.concat(RU.lastRead.lore, " / ") or "?")
  local BPs = findScript("blueprints")
  RN.check("blueprint", RU.lastRead and RU.lastRead.bp ~= nil and BPs.get(RU.lastRead.bp) ~= nil, "the site's blueprint in the library: %s", tostring(RU.lastRead and RU.lastRead.bp))
  -- 7. the claim
  C.patch(C.activeId(), { role = "engineer" })
  local okcl, whycl = RU.claim(s.id, ctx)
  RN.check("claim", okcl, "an Engineer claims %s: %s", s.name, tostring(whycl or "ok"))
  local bid = nil
  wait_for(function() local br = RU.baseOf(s.id); bid = br and br.id; return bid ~= nil end, 8, "the base founded")
  local brec = bid and B.get(bid)
  RN.check("base", brec ~= nil and brec.n == s.name and brec.by == "claimed", "base #%s %s (by %s)", tostring(bid), tostring(brec and brec.n), tostring(brec and brec.by))
  if bid and BR then
    local c0 = BR.stats.census
    wait_for(function() return BR.stats.census > c0 and B.get(bid).roles ~= nil end, 10, "the census")
    P("RN ROLES: %s · why: %s", BR.roleLine(B.get(bid).roles or {}, 6), (function() local t = {} for k, v in pairs(BR.why[bid] or {}) do t[#t + 1] = k .. ": " .. v end table.sort(t) return table.concat(t, " | ") end)())
  end
  local q = RU.restoreQuote(s.id)
  local cash0 = co.balance and co.balance() or 0
  local nr = RU.restore(s.id)
  RN.check("restore", nr == q.n and RU.restoreQuote(s.id).n == 0, "restored %d missing pieces for $%d", nr, q.cost)
  local worn = nil
  rec = ST.get(sid)
  for _, p in ipairs(rec.bp) do if p.wr and (p.o_p or p.o_r) then worn = p; break end end
  if worn then
    RN.check("repair", RU.repairPiece(sid, worn.uid) and ST.getPart(sid, worn.uid).wr == nil, "repaired the %s (uid %d)", worn.id, worn.uid)
  end
  RN.wait_spawned(ST, sid, 10)
  RN.cam(g, 11, 11, 13, 2, 1, -2)
  wait(1.5)
  RN.shot("claimed_restored", false)
  VP.cam_off()
  -- 8. the base card (and the side check: the stats box whole)
  OMv.openStation()
  wait(1.5)
  FV.snapshot(true)
  if bid then TS.pickEntry("o:" .. tostring(bid)) end
  OMv.setZoom(400)
  wait(2.0)
  RN.shot("station_base_card")
  RN.cost("the station open on the claimed base's card", 3)
  TS.close()
  OMv.close()
  RN.result()
end
