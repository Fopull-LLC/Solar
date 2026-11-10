-- ── reach probe (tools/perf/reachprobe.sh; expansion X7, "Roles & reach and
-- Survey II"; docs/base-building.md §25, docs/tracking-station.md §6)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam),
-- buildkitprobe_modes.lua (BK: the flat spot, the unlock) and
-- refineryprobe_modes.lua (RX: shots and views).
--   reach   the costs with nothing built (base_roles, survey, missions); a
--           base founded on flat ground ~200 m out (a Base Station Tower) with
--           an Electrolyser, a Fuel Tank and a Fuel Hose Stand, two Hoppers, a
--           Quarry Drive, a Crusher and a 1 m Telescope round it: the census
--           reads FUEL, MINE, REFINERY, SCIENCE and DEPOT; its cost; the
--           Tracking Station's BASES row (glyph, situation), the base card
--           (ROLES, 24 h stats), the role key filtering to FUEL, the chart's
--           label; the moon's swath grid from one inclined orbit and a second
--           plane, its res_map on the station's map (cost a frame, cells
--           drawn), the BODY card's ORE MAP; the reach contracts the
--           generator makes for the moon; the Reach stage's lines; the costs
--           with the base standing, the station open and the res_map drawn.
-- `XR PASS|FAIL <check>`, `XR …` lines and `XR RESULT`. Pictures: save/user/reachshots/.
XR = { fails = 0, passed = 0 }
function XR.check(name, okc, fmt, ...)
  P("XR %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then XR.passed = XR.passed + 1 else XR.fails = XR.fails + 1 end
  return okc
end
function XR.result() P("XR RESULT %s (%d passed, %d failed)", XR.fails == 0 and "PASS" or "FAIL", XR.passed, XR.fails) end
function XR.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://reachshots/" .. nm .. ".png", bytes); P("XR SHOT %s", nm)
    else P("XR SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function XR.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  local BR, SV = findScript("base_roles"), findScript("survey")
  P("XR COST %s: base_roles %.4f ms/frame, survey %.4f, missions %.4f, tracking_station %.4f, fleet_view %.4f, orbit_map %.4f, logistics %.4f, route_ops %.4f · census %.3f ms (%d bases, %d pieces, %d censuses), survey tick %.3f ms, swath %.3f ms",
    tag, ms("base_roles"), ms("survey"), ms("missions"), ms("tracking_station"), ms("fleet_view"), ms("orbit_map"), ms("logistics"), ms("route_ops"),
    BR.stats.ms or 0, BR.stats.bases or 0, BR.stats.parts or 0, BR.stats.census or 0, SV.stats.ms or 0, SV.stats.swath_ms or 0)
  return ms("base_roles"), ms("survey")
end
function XR.moon()
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

function XR.run()
  wait_ready(120)
  wait(2)
  local ST, BR, B, SV, TS, FV, OM, MI, inv, FN, co, C = findScript("structures"), findScript("base_roles"), findScript("bases"),
    findScript("survey"), findScript("tracking_station"), findScript("fleet_view"), findScript("orbit_map"), findScript("missions"),
    findScript("inventory"), findScript("fluid_net"), findScript("company"), findScript("crew")
  if not XR.check("scene", ST and BR and B and SV and TS and FV and OM and MI, "base_roles %s survey %s missions %s",
    tostring(BR ~= nil), tostring(SV ~= nil), tostring(MI ~= nil)) then XR.result() return end
  if perf.enable then perf.enable(true) end
  -- (the average settles after the load: the first census and the scene coming up are in the early frames)
  local br0, sv0 = XR.cost("idle: nothing built", 10)
  XR.check("idle_cost", br0 >= 0 and br0 < 0.015, "base_roles %.4f ms a frame with no base (one compare a frame)", br0)
  if co and co.earn then co.earn(500000, "probe") end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  -- 1. the site and the base
  local spot = BK.flat_spot()
  if not XR.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then XR.result() return end
  stand_at(spot)
  wait(4)
  local b = home()
  local a = astro()
  local U = unit(sub(a, b))
  local Fw = unit(sub(spot.t, scl(U, dot(spot.t, U))))
  local R = unit(cross(U, Fw))
  local A = sub(a, b)
  local O = { x = A.x + Fw.x * 6, y = A.y + Fw.y * 6, z = A.z + Fw.z * 6 }
  local function ground_local(lx, lz)
    local bb = home()
    local wx, wy, wz = bb.x + O.x + R.x * lx + Fw.x * lz + U.x * 30, bb.y + O.y + R.y * lx + Fw.y * lz + U.y * 30, bb.z + O.z + R.z * lx + Fw.z * lz + U.z * 30
    local h = terrain.raycast(vec3(wx, wy, wz), vec3(-U.x, -U.y, -U.z), 80)
    if not (h and h.pos) then return 0 end
    return dot(sub(h.pos, bb), U) - dot(O, U)
  end
  local y0 = ground_local(0, 0)
  O = { x = O.x + U.x * y0, y = O.y + U.y * y0, z = O.z + U.z * y0 }
  local nb0 = #B.list()
  local rec = ST.newRecord(nil, b.name, O.x, O.y, O.z, U, Fw, "tower", { name = "Far Pad", t = 0 })
  local sid = ST.add(rec)
  rec = ST.get(sid)
  local hy = 0
  for _, c in ipairs({ { 0, 0 }, { 8, 6 }, { -8, 6 }, { 8, 14 }, { -8, 14 }, { 0, 20 } }) do hy = math.max(hy, ground_local(c[1], c[2])) end
  hy = hy + 0.05
  local Q = math.pi / 2
  local function add(id, x, z, yaw) return ST.addPart(sid, { id = id, x = x, y = hy, z = z, yaw = yaw or 0 }) end
  local U2 = {}
  U2.electro = add("mcElectro.steel", 6, 6)
  U2.fuel = add("flTankFuel.steel", 9, 6, Q)
  U2.hose = add("flHose.steel", 6, 10)
  U2.hop1 = add("lgHopper.steel", -6, 6)
  U2.hop2 = add("lgHopper.steel", -9, 6)
  U2.drive = add("qDrive.steel", -6, 12)
  U2.crusher = add("mcCrusher.steel", 0, 14)
  U2.scope = add("telescope1m.steel", 7, 16)
  ST.spawnNow(sid)
  wait(1.0)
  local bid = nil
  wait_for(function()
    for _, r in ipairs(B.list()) do if r.sid == sid then bid = r.id end end
    return bid ~= nil
  end, 10, "the base founded")
  if not XR.check("founded", bid ~= nil and #B.list() == nb0 + 1, "the tower founded base #%s (%d bases)", tostring(bid), #B.list()) then XR.result() return end
  P("XR PIECES: %s", (function() local t = {} for k, v in pairs(U2) do t[#t + 1] = k .. "=" .. tostring(v) end table.sort(t) return table.concat(t, " ") end)())
  -- (the census runs within 2 s of the structures changing)
  local c0 = BR.stats.census
  wait_for(function() return BR.stats.census > c0 and B.get(bid).roles ~= nil end, 8, "the census")
  local r1 = B.get(bid).roles or {}
  P("XR ROLES: %s · census %.3f ms over %d bases, %d pieces · why: %s", BR.roleLine(r1, 6), BR.stats.ms, BR.stats.bases, BR.stats.parts,
    (function() local t = {} for k, v in pairs(BR.why[bid] or {}) do t[#t + 1] = k .. ": " .. v end table.sort(t) return table.concat(t, " | ") end)())
  XR.check("roles", BR.shown(r1, "fuel") and BR.shown(r1, "mine") and BR.shown(r1, "refinery") and BR.shown(r1, "science") and BR.shown(r1, "depot"),
    "FUEL (an Electrolyser), MINE (a drive), REFINERY (a Crusher), SCIENCE (a telescope), DEPOT (8 t of hoppers): %s", BR.roleLine(r1, 6))
  XR.check("census_cost", BR.stats.ms < 2.0, "a census %.3f ms", BR.stats.ms)
  -- the fuel tank filled: the hose stand's own FUEL reason; stock in a hopper
  if FN and FN.setContent then FN.setContent(sid, U2.fuel, 900) end
  inv.add("hopper:" .. sid .. "." .. U2.hop1, "iron", 40, b.name)
  wait(2.5)
  P("XR STOCK: iron in Far Pad's stores %.0f kg · fuel tank %s kg", BR.stockOf(bid, "iron"), tostring(FN and FN.content and FN.content(sid, U2.fuel)))
  XR.check("stock", BR.stockOf(bid, "iron") > 0, "stockOf reads the hopper: %.0f kg of iron", BR.stockOf(bid, "iron"))
  -- the base itself, from a camera on the ground (body-relative points)
  local function at(lx, ly, lz) return { x = O.x + R.x * lx + U.x * ly + Fw.x * lz, y = O.y + R.y * lx + U.y * ly + Fw.y * lz, z = O.z + R.z * lx + U.z * ly + Fw.z * lz } end
  VP.cam_fixed(at(18, 12, -10), at(0, 2, 10))
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(true) end
  wait(1.5)
  XR.shot("base_world", false)
  VP.cam_off()
  wait(0.5)
  local br1 = XR.cost("a base with five roles, the station shut", 4)
  XR.check("built_cost", br1 < 0.05, "base_roles %.4f ms a frame with a base standing", br1)
  -- 2. the station: BASES, the card, the role key
  OM.openStation()
  wait(1.5)
  local S = FV.snapshot(true)
  local e = S.byId["o:" .. tostring(bid)]
  XR.check("entry", e and e.roleText and e.glyph == BR.GLYPH[BR.strongest(e.roles)[1]], "the BASES row: %s %s · %s", tostring(e and e.glyph), tostring(e and e.name), tostring(e and e.sub))
  TS.pickEntry("o:" .. tostring(bid))
  OM.setZoom(400)
  wait(2.0)
  XR.shot("station_base_card")
  TS.setFilter("role", "fuel")
  wait(1.0)
  S = FV.snapshot(true)
  local nfuel, nother = 0, 0
  for _, x in ipairs(S.entries) do
    if FV.passes(x, TS.filter) then if x.kind == "outpost" or x.kind == "base" then nfuel = nfuel + 1 else nother = nother + 1 end end
  end
  XR.check("role_key", nfuel >= 1 and nother == 0, "the role key on FUEL: %d base(s) pass, %d other entries", nfuel, nother)
  XR.shot("station_role_fuel")
  TS.setFilter("role", nil)
  local stc = XR.cost("the station open on the base card", 3)
  -- 3. Survey II: the moon's swath from two orbital planes, the res_map
  local moon = XR.moon()
  if XR.check("moon", moon ~= nil, "the moon: %s", moon and moon.name or "none") then
    local Rm = moon.radius
    local mu = moon.mu
    local r0 = Rm * 1.6
    local v0 = math.sqrt(mu / r0)
    local Pm = 2 * math.pi * math.sqrt(r0 ^ 3 / mu)
    local rec2 = SV.record(moon.name)
    local res0 = rec2.L.res or 0
    local S2 = SV.swathOf(moon.name)
    local w0 = os.clock()
    local function orbit(vy, vz)
      SV.swathTrack(r0, 0, 0, 0, vy, vz, mu, Pm, Rm, 0.1, function(ux, uy, uz, alt)
        if SV.inScanBand(alt, Rm) then S2.n = S2.n + SV.swathMark(S2.mask, ux, uy, uz, SV.swathHalf(alt, Rm) + SV.SWATH_PAD, SV.SWATH_N) end
      end)
    end
    orbit(v0 * math.sin(math.rad(55)), v0 * math.cos(math.rad(55)))
    local one = S2.n / SV.SWATH_N
    orbit(0, v0)
    local ms = (os.clock() - w0) * 1000
    rec2.sw = SV.maskEncode(S2.mask, SV.SWATH_N)
    SV.creditNow(moon.name, "scanner", { comp = 0.7, atmo = 0.9, res = S2.n / SV.SWATH_N })
    XR.check("swath", one > 0.3 and S2.n / SV.SWATH_N > one + 0.1, "one inclined orbit 0.6 R up maps %.0f %% of %s, a second plane %.0f %% (two orbits marked in %.2f ms)",
      one * 100, moon.name, S2.n / SV.SWATH_N * 100, ms)
    XR.check("res_layer", (SV.record(moon.name).L.res or 0) > res0, "res layer %.2f → %.2f", res0, SV.record(moon.name).L.res or 0)
    TS.pickEntry("w:" .. moon.name)
    wait(1.0)
    -- the res_map reads RESMAP_PER_CALL cells a frame
    wait_for(function() local _, _, done = SV.resMap(moon.name, 0); return done end, 20, "the res_map")
    local list, counts = SV.resMap(moon.name, 0)
    local cl = {}
    for ore, n in pairs(counts) do cl[#cl + 1] = ore .. " " .. n end
    table.sort(cl)
    XR.check("resmap", #list > 50, "%d cells mapped with ores: %s", #list, table.concat(cl, ", "))
    wait(1.5)
    local rs = TS.resmapStats
    P("XR RESMAP: %d cells, %d drawn this frame, %.3f ms (draw pass) · resMap read %.3f ms", rs.cells, rs.drawn, rs.ms, SV.stats.resmap_ms or 0)
    XR.check("resmap_draw", rs.drawn > 10 and rs.ms < 1.0, "the map draws %d discs (the facing half) in %.3f ms", rs.drawn, rs.ms)
    XR.shot("station_resmap")
    OM.setZoom(moon.radius * 2.4)
    wait(1.5)
    XR.shot("station_resmap_close")
    XR.cost("the station open on the moon with its res_map", 3)
    -- the contracts the generator makes for the moon now
    for _, k in ipairs({ "establish", "layer", "supply", "pipeline" }) do
      local sp = MI.genSpec(k, moon.name, 1)
      P("XR CONTRACT %s: %s", k, sp and string.format("%s · $%d · %s", sp.title, sp.reward, sp.goals[1].label) or "none (not possible here now)")
    end
    local es = MI.genSpec("establish", moon.name, 1)
    XR.check("contract", es ~= nil and es.goals[1].kind == "establish", "an establish contract for %s: %s", moon.name, es and es.title or "none")
  end
  -- the Reach stage
  for i, l in ipairs(MI.progGoalLines("reach")) do P("XR REACH %d: %s", i, l) end
  -- 4. the chart's label for the base
  TS.close()
  wait(0.5)
  OM.openStation()
  wait(0.3)
  OM.setMode("chart")
  wait(0.5)
  local tw = findScript("base_tower").towerOf(bid)
  if tw then
    OM.focusOn(function(bodies)
      for _, x in ipairs(bodies) do if x.name == b.name then return x.x + tw.gx, x.y + tw.gy, x.z + tw.gz, b.name end end
    end)
    OM.setZoom(700)
    wait(2.0)
    XR.shot("chart_base_label")
  end
  OM.close()
  wait(0.5)
  -- 5. a day passes with the electrolyser gone: FUEL fades, not at once
  if FN and FN.setContent then FN.setContent(sid, U2.fuel, 0) end
  ST.removeParts(sid, { U2.electro })
  local c1 = BR.stats.census
  wait_for(function() return BR.stats.census > c1 end, 8, "the census after")
  local r2 = B.get(bid).roles or {}
  P("XR AFTER: %s (fuel %.3f)", BR.roleLine(r2, 6), r2.fuel or 0)
  XR.check("fade", (r2.fuel or 0) >= 0.5, "the Electrolyser gone: FUEL still %.2f (fades over 3 game days)", r2.fuel or 0)
  XR.result()
end
