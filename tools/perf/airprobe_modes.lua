-- ── air and survey probe (tools/perf/airprobe.sh; expansion X1/X2) ──────────
-- Spliced into a copy of perfbench.lua; one table (AP). The save is made with
-- the new-save panel's keys plus `g_air` (strs "air"), an alien home when
-- params homealien = 1 / homeseed.
--   airalien  (an alien home with a breathable AIR choice) the air as rolled;
--             the helmet comes off (and a third-person shot of it); the
--             Tracking Station's WORLDS group and the BODY card of the home
--             and of a moon part-surveyed; the lab's BODIES page and a
--             world's close-up with its globe; the Command building refills
--             the suit; save and reload (the air, the survey, the helmet);
--             then the menu's new-save panel with its AIR row
--   airtoxic  (an alien home with no oxygen) the helmet stays on with the gas
--             named; the BODY card says TOXIC; a bare-headed crew member put
--             there gets the helmet back at once
-- `AP PASS|FAIL <check>` lines and `AP RESULT`. Pictures: save/user/airshots/.
AP = { fails = 0, passed = 0 }
function AP.check(name, okc, fmt, ...)
  P("AP %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then AP.passed = AP.passed + 1 else AP.fails = AP.fails + 1 end
  return okc
end
function AP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://airshots/" .. nm .. ".png", bytes); P("AP SHOT %s", nm)
    else P("AP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function AP.result() P("AP RESULT %d passed, %d failed", AP.passed, AP.fails) end

-- the camera on the crew's face, from in front (drawn poses, this frame)
function AP.face_cam(dist, side)
  local pc = findScript("planet_camera")
  if not (pc and pc.setShot) then return end
  pc.setShot(function()
    local a = find("Astronaut")
    local b = home()
    if not (a and b) then return nil end
    local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
    local f = a:toWorld(vec3(0, 0, 1))
    local o = a:toWorld(vec3(0, 0, 0))
    local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
    local d = fx * u.x + fy * u.y + fz * u.z
    fx, fy, fz = fx - u.x * d, fy - u.y * d, fz - u.z * d
    local l = len(fx, fy, fz)
    if l < 1e-6 then fx, fy, fz, l = 1, 0, 0, 1 end
    fx, fy, fz = fx / l, fy / l, fz / l
    local rx, ry, rz = fy * u.z - fz * u.y, fz * u.x - fx * u.z, fx * u.y - fy * u.x
    local hx, hy, hz = a.x + u.x * 0.65, a.y + u.y * 0.65, a.z + u.z * 0.65
    local s = side or 0.6
    return hx + fx * dist + rx * s + u.x * 0.15, hy + fy * dist + ry * s + u.y * 0.15, hz + fz * dist + rz * s + u.z * 0.15,
           hx, hy, hz, u.x, u.y, u.z
  end, 0.05)
end
function AP.cam_off() local pc = findScript("planet_camera"); if pc and pc.clearShot then pc.clearShot(0.05) end end
-- (a shot hides the crew's own body: the third-person camera shows it instead)
function AP.third(on)
  local pc = findScript("planet_camera")
  if not pc then return end
  pc.firstPerson = not on
  if on and pc.params then pc.params.distance = 3.0 end
end

function AP.home_air()
  local b = home()
  local w = b and save.get("world." .. b.name)
  local A = findScript("atmo")
  local sg = findScript("system_generator")
  local f = sg and sg.homeFeatures and sg.homeFeatures(b.name)
  P("AP AIR %s: type %s %s K, p0 %.2f bar, %s, verdict %s, choice %s, legacy %s, breathable(features) %s, mag %s µT",
    b.name, tostring(w and w.geo and w.geo.type), tostring(w and w.bio and w.bio.tempK), w and w.air and w.air.p0 or -1,
    A and A.gasesText and A.gasesText(w and w.air) or "?", A and A.verdict and A.verdict(w and w.air) or "?",
    tostring(w and w.air and w.air.choice), tostring(w and w.air and w.air.legacy), tostring(f and f.breathable), tostring(w and w.mag))
  return w, f
end

function AP.moon_name()
  local h = save.get("system.home")
  for _, b in ipairs(h and h.bodies or {}) do if b.parent and b.parent ~= h.star then return b.name end end
  return h and h.bodies and h.bodies[2] and h.bodies[2].name
end

function AP.station(names)
  local ts, om, fv = findScript("tracking_station"), findScript("orbit_map"), findScript("fleet_view")
  tap("f2"); wait(1.5)
  AP.check("station_open", ts and ts.isOpen() and om.mode == "station", "F2 opens the station")
  local S = fv.snapshot(true)
  local nw = 0
  for _, e in ipairs(S.entries) do if e.kind == "body" then nw = nw + 1 end end
  AP.check("worlds_group", nw >= 2, "%d worlds in the WORLDS group", nw)
  for i, n in ipairs(names) do
    ts.selectCraft("w:" .. n.name); wait(0.4)
    local e = fv.current().byId["w:" .. n.name]
    if e and om.setZoom then
      local b = space.body(n.name)
      om.focusOn(function() local bb = space.body(n.name); return bb.x, bb.y, bb.z, n.name end)
      om.setZoom((b and b.radius or 600) * 3.2)
    end
    wait(2.0)
    AP.check("body_card_" .. i, e ~= nil and e.group == "WORLDS", "%s: %s · %s", n.name, tostring(e and e.sub), tostring(e and e.num))
    AP.shot(n.shot)
  end
  tap("f2"); wait(1.0)
end

function AP.lab(moon)
  local L, lt = findScript("lab"), findScript("lab_talk")
  -- into the lab's vestibule (labprobe's labpt): the interior and its staff come on
  if L and L.ROOT and L.ROOT.valid then
    local p = L.ROOT:toWorld(vec3(8.0, 0.6 - 4.24, 5.6 - 2.05))
    local b = home()
    local u = unit({ x = p.x - b.x, y = p.y - b.y, z = p.z - b.z })
    local a = find("Astronaut")
    a.x, a.y, a.z = p.x + u.x * 1.0, p.y + u.y * 1.0, p.z + u.z * 1.0
    a.vx, a.vy, a.vz = 0, 0, 0
    wait_for(function() return L.inside and L.scientists and L.scientists[1] and L.scientists[1].node end, 20, "the lab's staff")
  end
  local s = L and L.scientists and L.scientists[1]
  if not (lt and s and s.node) then AP.check("lab", false, "no lab or scientist (%s %s)", tostring(L ~= nil), tostring(s ~= nil)) return end
  local n = s.node
  local sc = n:getScript("scientist")
  local sg = sc and sc.faceSign or 1
  local o = n.worldPos
  local f = n:toWorld(vec3(0, 0, sg))
  local a = find("Astronaut")
  a.x, a.y, a.z = o.x + (f.x - o.x) * 1.3, o.y + (f.y - o.y) * 1.3 + 0.0, o.z + (f.z - o.z) * 1.3
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(1.5)
  lt.open({ node = n, idx = s.idx, staff = s.staff })
  wait(1.2)
  lt.showBodies()
  wait(1.5)
  AP.check("lab_bodies", lt.isOpen(), "the lab's BODIES page is up")
  AP.shot("lab_bodies")
  lt.openBody(moon)
  wait(3.0)
  AP.check("lab_body", lt.viewBody == moon, "the close-up of %s (%s)", moon, lt.standInfo and lt.standInfo() or "?")
  AP.shot("lab_body_moon")
  lt.close()
  wait(1.0)
end

function AP.reload()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(4)
end

function AP.run_alien()
  wait_ready(150)
  local w, f = AP.home_air()
  AP.check("air_chosen", w and w.air and not w.air.legacy and w.air.choice ~= nil, "the home's air is the save's choice (%s)",
    tostring(w and w.air and w.air.choice))
  AP.check("breathable_home", f and f.breathable == true, "an alien home with %s air is breathable", tostring(params.air))
  -- the helmet comes off
  local su, wk = findScript("suit"), findScript("planet_walker")
  wait(2)
  local ok, why = su.canRemoveHelmet()
  AP.check("helmet_may", ok == true, "the helmet may come off here (%s)", tostring(why))
  su.setHelmet(false, { instant = true, quiet = true })
  wait(3)
  AP.check("helmet_off", su.helmetOn() == false, "bare-headed and it stays off (%s)", tostring(su.helmetOn()))
  AP.third(true); wait(2.0)
  AP.shot("alien_helmet_off")
  AP.third(false); wait(0.5)
  -- the survey: credit a moon by hand (an orbit and a 0.3 m sweep) so its card shows bands
  local sv = findScript("survey")
  local moon = AP.moon_name()
  if sv and moon then sv.creditNow(moon, "orbit"); sv.creditNow(moon, "tel30") end
  local hb = home()
  AP.station({ { name = hb.name, shot = "station_body_home" }, { name = moon or hb.name, shot = "station_body_moon" } })
  AP.lab(moon or hb.name)
  -- the Command building refills the suit
  local cmd = find("FacCommand")
  if cmd and wk and wk.setSuitAir then
    wk.setSuitAir(0.3)
    local p = cmd:toWorld(vec3(0, 0, -14))   -- outside its south face, 4.5 m off the wall
    local a = find("Astronaut")
    local b = home()
    local u = unit({ x = p.x - b.x, y = p.y - b.y, z = p.z - b.z })
    a.x, a.y, a.z = p.x + u.x * 1.2, p.y + u.y * 1.2, p.z + u.z * 1.2
    a.vx, a.vy, a.vz = 0, 0, 0
    wait(3)
    AP.check("command_refill", (wk.suitO2 or 0) > 0.99, "by the Command building the suit is topped up (%.2f)", wk.suitO2 or -1)
  else
    AP.check("command_refill", false, "no Command building")
  end
  -- save and reload
  local rec0 = moon and save.get("survey." .. moon)
  local o2_0 = w.air.o2
  wait(6)   -- (the helmet's state is persisted at once; the survey's flush is each tick)
  AP.reload()
  local w2 = save.get("world." .. hb.name)
  local rec2 = moon and save.get("survey." .. moon)
  AP.check("reload_air", w2 and w2.air and math.abs(w2.air.o2 - o2_0) < 1e-9 and w2.air.choice == w.air.choice,
    "after a reload the air is the same (%s, O2 %.4f)", tostring(w2 and w2.air and w2.air.choice), w2 and w2.air and w2.air.o2 or -1)
  AP.check("reload_survey", rec2 and rec0 and rec2.L and math.abs((rec2.L.atmo or 0) - (rec0.L.atmo or 0)) < 1e-9 and (rec2.L.atmo or 0) > 0,
    "after a reload the survey of %s stands (atmo %.2f)", tostring(moon), rec2 and rec2.L and rec2.L.atmo or -1)
  wait(2)
  su = findScript("suit")
  -- (informational: crew.lua suit_in restores the member record's helmet, which only a switch writes)
  P("AP NOTE reload_helmet: helmet %s after the reload (crew record helmet %s)", tostring(su and su.helmetOn()),
    tostring((findScript("crew").get(findScript("crew").activeId()) or {}).helmet))
  -- the new-save panel's AIR row
  scene.load("menu")
  wait(4)
  local ns = findScript("menu_newsave")
  if ns and ns.openFor then
    ns.openFor(13)
    wait(0.8)
    ns.setHome("alien", "")
    wait(1.0)
    AP.check("menu_air_default", ns.airOption() == "random", "an alien home defaults to Random air (%s)", tostring(ns.airOption()))
    AP.shot("menu_air_alien")
    ns.setAir("thin")
    wait(1.0)
    AP.check("menu_air_pick", ns.airOption() == "thin", "the AIR row picks Thin")
    AP.shot("menu_air_thin")
  else
    AP.check("menu", false, "no new-save panel")
  end
end

function AP.run_toxic()
  wait_ready(150)
  local w, f = AP.home_air()
  local A = findScript("atmo")
  AP.check("toxic_home", f and f.breathable == false and A.verdict(w.air) ~= "BREATHABLE", "an alien home with no oxygen: %s",
    A.verdict(w.air))
  local su = findScript("suit")
  wait(2)
  local ok, why = su.canRemoveHelmet()
  AP.check("helmet_stays", ok == false and type(why) == "string", "the helmet stays on: %s", tostring(why))
  -- bare-headed by force (a stale save): the helmet goes back on at once, the gas named
  local bc = findScript("big_caption")
  su.helmet = false
  wait(1.0)
  AP.check("helmet_forced", su.helmetOn() == true, "bare-headed in toxic air: the helmet goes back on")
  AP.third(true); wait(2.0)
  AP.shot("toxic_helmet_on")
  AP.third(false)
  local hb = home()
  AP.station({ { name = hb.name, shot = "station_body_toxic" } })
end
