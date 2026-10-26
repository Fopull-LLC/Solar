-- ── wheel probe (tools/perf/wheelprobe.sh): "wheels face the wrong way after getting off and back on" (playtest 2026-10-26) ──
-- A 4-wheel rover driven out past 95 m, then: (1) crew out MID-TURN (W+A
-- held), back aboard, drive straight; (2) parked and braked, crew out, left
-- until the chassis sleeps, back aboard, drive. Each step prints every wheel's
-- drawn yaw against the chassis (the tyre mesh's axle), the joint's steer and
-- what the controller asked for, and the hull's own wheel visual while the
-- tyres are in. A drawn yaw more than WP_TOL from the joint's is a FAIL, and
-- so is a mesh that turns with its ball body (counted as 90).
local WP_TOL = 3.0
local WP_TAG = "w"
local WP_FAILS = 0
local function wp_shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = false }, function(bytes)
    if bytes then assets.writeBytes("user://wheelshots/" .. WP_TAG .. "_" .. nm .. ".png", bytes); P("WP SHOT %s_%s", WP_TAG, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
local function wp_fold(a) while a > 90 do a = a - 180 end while a <= -90 do a = a + 180 end return a end
-- an axle's yaw in the chassis frame, degrees (+ toward the chassis X), folded to (-90, 90]
local function wp_yaw(vn, ax)
  local f = vn:worldForward()
  local r = vn:worldRight()
  return wp_fold(math.deg(math.atan2(dot(ax, r), dot(ax, { x = -f.x, y = -f.y, z = -f.z }))))
end
local function wp_measure(vc, vn, tag, check)
  local o, worst = {}, 0
  for k, w in ipairs(vc.R2.wheels or {}) do
    local t = w.tyre
    if t and t.valid then
      local m = child_named(t, "TyreMesh")
      local j = t:getcomponent("Joint")
      local my = m and wp_yaw(vn, m:worldRight()) or -999
      local js = j and wp_fold(j.steer or 0) or -999
      local ty = wp_yaw(vn, (function() local f = t:worldForward(); return { x = -f.x, y = -f.y, z = -f.z } end)())
      local err = math.abs(wp_fold(my - js))
      -- a mesh nobody lays turns with its ball: drawn = body, off the joint
      if math.abs(wp_fold(my - ty)) < 0.05 and math.abs(wp_fold(ty - js)) > 1 then err = math.max(err, 90) end
      worst = math.max(worst, err)
      o[#o + 1] = string.format("#%d%s drawn %.1f joint %.1f (base %.1f now %.1f, steers %s) body %.1f", k, w.gear and "g" or "", my, js,
        w.steer0 or 0, w.steerNow or 0, tostring(w.steers), ty)
    else
      local n = vc.r2NodeOf and vc.r2NodeOf(vn, w.uid)
      local pt = n and child_named(n, "Tyre")
      local pr = n and n.valid and wp_yaw(vn, n:worldRight()) or -999
      local ty = pt and pt.valid and wp_yaw(vn, pt:worldRight()) or -999
      o[#o + 1] = string.format("#%d%s hull wheel (tyres in): part axle %.1f drawn %.1f visible %s", k, w.gear and "g" or "", pr, ty, tostring(pt and pt.visible))
    end
  end
  P("WP %s [%s] live %s why %s steer %.2f | %s | worst drawn-vs-joint %.1f", WP_TAG, tag, tostring(vc.R2.live), tostring(vc.R2.why), vc.R2.steer or 0,
    table.concat(o, " | "), worst)
  if check and worst > WP_TOL then WP_FAILS = WP_FAILS + 1; P("WP %s FAIL [%s] worst %.1f deg", WP_TAG, tag, worst) end
  return worst
end
local function wp_heading(vn)
  local f = vn:worldForward()
  return { x = -f.x, y = -f.y, z = -f.z }
end
-- drive with the probe's command (R2.cmd: what W/A/D press) for `secs`, measuring every half second
local function wp_drive(vc, vn, drive, steer, secs, tag, check)
  local t0, nextm, worst = time, 0, 0
  while time - t0 < secs do
    vc.R2.cmd = { drive = drive, steer = steer }
    yield()
    if time - t0 >= nextm then nextm = nextm + 0.5; worst = math.max(worst, wp_measure(vc, vn, string.format("%s+%.1f", tag, time - t0), check)) end
  end
  return worst
end
local function wp_out(vc, keep)
  if not keep then vc.R2.cmd = nil end
  tap("f"); yield(); yield()
  -- F is refused on the move (crew.evaCheck); the player's "got off while
  -- steering" is a crawl, so the probe steps them out the way F does
  if vc.crewAboard and vc.evaNow then vc.evaNow() end
  vc.R2.cmd = nil
  wait(2)
  P("WP %s crew out: aboard %s piloting %s", WP_TAG, tostring(vc.crewAboard), tostring(vc.piloting))
end
local function wp_in(vc)
  local ok = vc.boardNow and vc.boardNow()
  if not ok then
    -- walk-up is not simulated: put them by the seat and try again
    local a = astro()
    local i = assembly.info(vc.node)
    for _ = 1, 120 do
      if ok or not (a and i) then break end
      i = assembly.info(vc.node)
      a.x, a.y, a.z = i.com.x, i.com.y, i.com.z
      yield()
      ok = vc.boardNow()
    end
  end
  P("WP %s boarded %s piloting %s", WP_TAG, tostring(ok), tostring(vc.piloting))
  return ok
end

local function run_wheels()
  WP_TAG = params.tag or "rover"
  local vc = run_rover({ name = "wp_out", out = 95, secs = 90, stop = true })
  if not vc then P("WP RESULT: no rover"); return end
  local vn = vc.node
  release_all()
  vc.R2.cmd = { drive = 0, steer = 0 }
  wait(3)
  wp_measure(vc, vn, "out95", true)
  -- 1. crew out MID-TURN
  wp_drive(vc, vn, 1, 1, 3, "turn", true)
  wp_measure(vc, vn, "turning", true)
  wp_shot("1turning")
  wp_out(vc, true)
  wait(3)
  wp_measure(vc, vn, "out-midturn", false)
  wp_shot("2out_midturn")
  wp_in(vc)
  for _ = 1, 3 do yield() end
  wp_measure(vc, vn, "boarded+3f", false)
  wait(1)
  vc.R2.cmd = { drive = 0, steer = 0 }
  wp_measure(vc, vn, "boarded+1s", true)
  wp_shot("3boarded")
  local h0 = wp_heading(vn)
  wp_drive(vc, vn, 1, 0, 4, "straight", true)
  local h1 = wp_heading(vn)
  P("WP %s straight after reboard: heading turned %.1f deg in 4 s", WP_TAG, math.deg(math.acos(clamp(dot(h0, h1), -1, 1))))
  wp_shot("4straight")
  -- 2. parked, crew out, the chassis asleep, back on
  wp_drive(vc, vn, 0, -1, 2, "stop", false)
  vc.R2.cmd = { drive = 0, steer = 0 }
  wait(2)
  wp_out(vc)
  local t0, slept = time, nil
  while time - t0 < (params.sleepwait or 40) do
    yield()
    local i = assembly.info(vn) or {}
    if not slept and (i.asleep or vn.asleep) then slept = time - t0; P("WP %s chassis asleep %.1f s after the crew got out", WP_TAG, slept) end
    if slept and time - t0 > slept + 3 then break end
  end
  if not slept then P("WP %s chassis NOT asleep in %.0f s", WP_TAG, time - t0) end
  wp_measure(vc, vn, "asleep", false)
  wp_shot("5asleep")
  wp_in(vc)
  wait(1)
  wp_measure(vc, vn, "woke+1s", true)
  wp_shot("6woke")
  h0 = wp_heading(vn)
  wp_drive(vc, vn, 1, 0, 4, "straight2", true)
  h1 = wp_heading(vn)
  P("WP %s straight after the sleep: heading turned %.1f deg in 4 s", WP_TAG, math.deg(math.acos(clamp(dot(h0, h1), -1, 1))))
  wp_drive(vc, vn, 1, -1, 2, "turn2", true)
  wp_shot("7turn2")
  -- 3. out and in again at once, twice, mid-turn
  for n = 1, 2 do
    wp_drive(vc, vn, 1, (n == 1) and 1 or -1, 1.5, "turn" .. (2 + n), true)
    wp_out(vc, true)
    wp_in(vc)
    wait(1)
    vc.R2.cmd = { drive = 0, steer = 0 }
    wp_measure(vc, vn, "quick" .. n, true)
  end
  vc.R2.cmd = nil
  P("WP RESULT %s: %s (%d failed measurement(s))", WP_TAG, WP_FAILS == 0 and "PASS" or "FAIL", WP_FAILS)
end

-- the jet's steerable nose gear (mode planewheels): taxi, rudder held, crew
-- out mid-turn, back in, taxi and turn again
local function run_planewheels()
  WP_TAG = params.tag or "plane"
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local list = {}
  for _, r in ipairs(plane()) do
    local def = pa and pa.PARTS[r.id]
    if def then list[#list + 1] = full(r, def, k) end
  end
  save.set("shipyard.blueprint", { parts = list, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#list, 150)
  wait_regrade()
  if not vc then P("WP RESULT plane: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  local function taxi(thr, yaw, secs, tag, check)
    local t0, nextm = time, 0
    while time - t0 < secs do
      vc.setThrottle(thr)
      vc.AERO.cmd = { p = 0, y = yaw, r = 0 }
      yield()
      if time - t0 >= nextm then nextm = nextm + 0.5; wp_measure(vc, vn, string.format("%s+%.1f", tag, time - t0), check) end
    end
  end
  taxi(0.25, 0, 3, "roll", true)
  taxi(0.1, 1, 3, "taxiturn", true)
  wp_shot("1taxiturn")
  vc.setThrottle(0)
  wp_out(vc, true)
  vc.AERO.cmd = nil
  wait(3)
  wp_measure(vc, vn, "out", false)
  wp_in(vc)
  wait(1)
  wp_measure(vc, vn, "boarded+1s", true)
  taxi(0.1, -1, 4, "taxiturn2", true)
  wp_shot("2taxiturn2")
  vc.setThrottle(0)
  vc.AERO.cmd = nil
  P("WP RESULT %s: %s (%d failed measurement(s))", WP_TAG, WP_FAILS == 0 and "PASS" or "FAIL", WP_FAILS)
end
