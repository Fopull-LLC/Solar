-- ── z-fight / doorway / stair probe (tools/perf/kitprobe.sh zfight; Ty 11-10) ──
-- Spliced after kitprobe_modes.lua (KIT helpers) into a copy of perfbench.lua.
-- Ty, 11-10: "the biggest issue is definitely the z fighting ... constantly
-- jittering on random parts", "incomplete pipes", "barely squeezing through
-- doors", "the stairs going up to the entrance doorway I had to get on it and
-- crouch to get inside".
--   zfight  on flat ground 150+ m out: Graveyard Shift's station (its
--           station.bp.txt, the entrance steps set as the scenario patch in
--           work/zfight2 proposes) and a Hab Block ruin's full build stamped
--           as structures; bursts of consecutive frames in the control room,
--           the camera held in the structure's frame and then sliding 1 cm a
--           frame (zf_<tag>_fNN.png: flicker.py / flicker_diff.py read them);
--           close-ups of the gas racks' manifolds, door jambs, corners, the
--           steps and the ladder; then WALKS (every door forced open, so it is
--           the geometry that is tested): up the station's steps and through
--           its airlock, into the ruin up its steps, through both airlock
--           doors, up the ladder to the upper floor, through a Door Wall and an
--           Open Frame: each `ZF walk` line says whether the crew got there,
--           how long it took and the highest the feet rose.
-- One `BK PASS|FAIL <check>` line a check, `BK RESULT zfight: PASS/FAIL`.
-- Pictures save/user/buildshots/zf_*.png.
ZF = {}

local function zf_g(spot, dz)
  local b = home()
  local s = unit(cross(spot.dir, spot.t))
  local p = { x = spot.dir.x * spot.r + s.x * (dz or 0), y = spot.dir.y * spot.r + s.y * (dz or 0), z = spot.dir.z * spot.r + s.z * (dz or 0) }
  local u = unit(p)
  local r = ground_r(b, u.x, u.y, u.z, spot.r + 150) or spot.r
  return { body = b.name, x = u.x * r, y = u.y * r, z = u.z * r, ux = u.x, uy = u.y, uz = u.z, fx = spot.t.x, fy = spot.t.y, fz = spot.t.z }
end

-- N consecutive frames, the camera in the structure's frame each frame (drawn
-- poses, lateUpdate), held still, or sliding `slide` m a frame along x
function ZF.burst(tag, rec, eye, tgt, n, slide)
  local k = 0
  VP.cam = function()
    local d = (slide or 0) * k
    return KIT.w(rec, eye[1] + d, eye[2], eye[3]), KIT.w(rec, tgt[1] + d, tgt[2], tgt[3])
  end
  wait(1.5)
  local out = 0
  for i = 1, n do
    out = out + 1
    local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
      out = out - 1
      if bytes then assets.writeBytes(string.format("user://buildshots/zf_%s_f%02d.png", tag, i), bytes)
      else P("ZF burst %s %d: %s", tag, i, tostring(why)) end
    end)
    if not ok then out = out - 1 end
    yield()
    k = k + 1
  end
  wait_for(function() return out <= 0 end, 15, "burst " .. tag)
  P("ZF BURST %s: %d frames", tag, n)
  VP.cam_off()
  wait(0.3)
end

-- walk to structure-local (x, z) and report: reached?, seconds, the feet's highest y in the frame
function ZF.walk(tag, rec, lx, lz, secs, stop)
  local t0, top = time, -1e9
  local ok = KIT.walk(rec, lx, lz, secs or 12, stop or 0.45, function()
    local _, y = KIT.at(rec)
    if y and y > top then top = y end
  end)
  local x, y, z = KIT.at(rec)
  P("ZF walk %s: %s in %.1f s, at (%.2f, %.2f, %.2f), feet rose to %.2f", tag, ok and "reached" or "STUCK", time - t0, x, y, z, top)
  return ok, top, y
end

function ZF.stamp(ST, pieces, g, name)
  local rec = ST.recordFromPieces(pieces, g.body, g, name, "probe", { t = 0 })
  local sid = ST.add(rec)
  P("ZF stamped %s: %d pieces as #%s", name, #pieces, tostring(sid))
  return sid
end

function ZF.run()
  BK.tag = "zfight"
  wait_ready(120)
  wait(2)
  local ST, BPs, RU, KL = findScript("structures"), findScript("blueprints"), findScript("ruins"), findScript("kit_live")
  if not BK.check("scene", ST and BPs and RU and KL and KS, "structures, blueprints, ruins, kit_live") then BK.result() return end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  wait(3)
  -- ── Graveyard's station ──
  local code = assets.readText("scenarios/graveyard_shift/station.bp.txt")
  local bp = code and BPs.decode(code)
  if not BK.check("station", bp ~= nil, "the station's blueprint decodes (%s pieces)", bp and bp.n or "-") then BK.result() return end
  -- (the entrance steps as work/zfight2/graveyard.patch proposes: top tread flush with the sill)
  -- (and the log desk 1.3 m south, out of the bunk room's doorway)
  for _, p in ipairs(bp.pieces) do
    if params.zf_gy_fix ~= 0 then
      if p.id == "steps.steel" then p.x, p.y, p.z = -3.54, -0.6, -3.5 end
      if math.abs(p.z - 3.9) < 0.01 and (p.id == "table.steel" or p.id == "monitor.steel" or (p.id == "chair.steel" and math.abs(p.x + 5.5) < 0.01)) then p.z = 2.6 end
      if p.id == "coffee.steel" and math.abs(p.z - 3.2) < 0.01 then p.z = 1.9 end
      -- (the battery row stood across the steps' foot: 2.3 m apart from x -17.5)
      if p.id == "batteryBank" then p.x = -17.5 + 2.3 * math.floor((p.x + 15) / 2.4 + 0.5) end
    end
  end
  local g1 = zf_g(spot, 0)
  local sidG = ZF.stamp(ST, bp.pieces, g1, "Kerne Station (probe)")
  -- ── a Hab Block ruin's full build, 40 m along ──
  local hab = RU.blueprintOf({ kind = "hab", co = 1, seed = 99, age = 1000, id = "Z#1", body = home().name, name = "Probe Habitat" })
  local g2 = zf_g(spot, 40)
  local sidR = ZF.stamp(ST, hab, g2, "Probe Habitat")
  wait(8)
  local recG, recR = ST.get(sidG), ST.get(sidR)
  -- the lights on (pictures), every door forced open for the walks later
  if KL.setAll then pcall(KL.setAll, sidG, true) end
  -- ── frames: the control room (x -7..-1, z -1..5, its floor at 0.2) ──
  local Y = 0.2
  ZF.burst("ctl_still", recG, { -6.4, Y + 1.65, 4.4 }, { -2.0, Y + 1.0, -0.6 }, 3)
  ZF.burst("ctl_slide", recG, { -6.4, Y + 1.65, 4.4 }, { -2.0, Y + 1.0, -0.6 }, 3, 0.01)
  ZF.burst("ctl_back", recG, { -2.0, Y + 1.6, -0.3 }, { -6.5, Y + 0.9, 4.5 }, 3)
  ZF.burst("hall_still", recG, { 1.0, Y + 1.7, 7.5 }, { 8.0, Y + 1.0, -4.0 }, 3)
  ZF.burst("bunk_still", recG, { -3.6, Y + 1.6, 6.6 }, { -6.6, Y + 0.6, 5.6 }, 3)
  -- close-ups (the station's own pieces)
  KIT.view("zf_gy_airtank", recG, { -4.8, Y + 1.9, 3.3 }, { -4.8, Y + 1.55, 4.6 })
  KIT.view("zf_gy_airtank_side", recG, { -3.9, Y + 1.8, 3.6 }, { -4.6, Y + 1.6, 4.6 })
  KIT.view("zf_gy_o2gen_back", recG, { -2.0, Y + 1.0, 3.6 }, { -2.6, Y + 0.6, 4.5 })
  KIT.view("zf_gy_airlock_out", recG, { -3.5, 1.7, -6.0 }, { -3.6, 0.8, -3.0 })
  KIT.view("zf_gy_airlock_steps", recG, { -1.8, 1.0, -5.2 }, { -3.6, 0.3, -3.4 })
  KIT.view("zf_gy_corner_in", recG, { -4.5, Y + 1.5, 2.5 }, { -6.9, Y + 1.2, 4.9 })
  KIT.view("zf_gy_bunkdoor", recG, { -6.0, Y + 1.6, 2.6 }, { -6.4, Y + 1.0, 5.0 })
  KIT.view("zf_gy_hall_plant", recG, { 3.0, Y + 1.8, 0.0 }, { 6.5, Y + 0.8, -4.0 })
  -- the ruin
  KIT.view("zf_ru_front", recR, { 2.5, 1.7, 6.0 }, { -0.3, 0.6, 1.0 })
  KIT.view("zf_ru_steps", recR, { 1.6, 0.9, 3.2 }, { -0.4, 0.2, 1.2 })
  KIT.view("zf_ru_airlock", recR, { -0.5, 1.7, 0.7 }, { -0.4, 0.8, -1.4 })
  KIT.view("zf_ru_ladder", recR, { 2.2, 1.6, -2.8 }, { 2.2, 2.0, 0.0 })
  KIT.view("zf_ru_well", recR, { 0.3, 4.2, 0.6 }, { 2.2, 2.4, -1.5 })
  ZF.burst("ru_up_still", recR, { -0.5, 2.6 + 1.65, 0.6 }, { 2.0, 2.6 + 0.8, -2.0 }, 3)
  -- ── door timing (doors NOT forced): walk at the bunk room's Door Wall from 4 m and read how open
  -- its leaf is when the shoulder reaches the door's plane (z 5 - 0.1 wall - 0.31 capsule) ──
  -- (a lone Door Wall on a row of slabs, 40 m the other way: a straight 5 m run-up)
  local dpieces = { { id = "doorWall.steel", x = 0, y = Y, z = 1, yaw = 0 } }
  for z = -4, 4, 2 do dpieces[#dpieces + 1] = { id = "slab2.concrete", x = 0, y = 0, z = z, yaw = 0 } end
  local sidD = ZF.stamp(ST, dpieces, zf_g(spot, -40), "Probe Door")
  wait(4)
  local recD = ST.get(sidD)
  KIT.tp(recD, -0.46, -4.2)
  wait(1.5)
  local atPlane, minOpen = nil, 1
  local okD = KIT.walk(recD, -0.46, 4.0, 10, 0.45, function()
    local _, _, z = KIT.at(recD)
    local o = KL.doorOpen(sidD, 1)
    if o and z and z > 0.4 and z < 1.6 and o < minOpen then minOpen = o end
    if o and z and not atPlane and z >= 1 - 0.1 - 0.31 then atPlane = o end
  end)
  P("ZF door timing: walking, the Door Wall's leaf %.0f %% open at the shoulder's plane, at least %.0f %% while passing; %s",
    (atPlane or -1) * 100, minOpen * 100, okD and "walked through" or "STUCK")
  BK.check("door_timing", okD and (atPlane or 0) >= 0.7, "a walker meets the Door Wall's leaf %.0f %% open", (atPlane or -1) * 100)
  -- ── walks, every door open ──
  KL.forceDoors = true
  wait(3)
  -- the station: from 4 m out, up the steps and through both airlock doors into the control room
  KIT.tp(recG, -3.54, -8.5)
  local okA = ZF.walk("gy_steps_airlock", recG, -3.54, -2.0, 14)
  local okB = ZF.walk("gy_into_control", recG, -3.54, 1.0, 8)
  local okC = ZF.walk("gy_bunk_door", recG, -6.4, 6.0, 12)
  BK.check("gy_walk", okA and okB, "the station's steps and airlock walked without crouching")
  BK.check("gy_bunk", okC, "into the bunk room through its Door Wall")
  -- the ruin: up its steps, through both airlock doors, round to the ladder and up it
  KIT.tp(recR, -0.46, 4.0)
  local r1 = ZF.walk("ru_steps", recR, -0.46, 0.0, 12)
  local r2 = ZF.walk("ru_airlock", recR, -0.46, -1.6, 8)
  ZF.walk("ru_round", recR, 1.3, -1.6, 8)
  ZF.walk("ru_back", recR, 1.3, -2.55, 6, 0.3)
  local r3 = ZF.walk("ru_to_ladder", recR, 2.2, -2.55, 10, 0.3)
  local r4, top = ZF.walk("ru_ladder", recR, 2.2, 0.35, 14)
  local _, uy = KIT.at(recR)
  BK.check("ru_walk", r1 and r2, "the ruin's steps and both airlock doors walked standing")
  BK.check("ru_ladder", r3 and (uy or 0) > 2.4, "up the ladder to the upper floor (feet at %.2f)", uy or -1)
  -- (builderperf, Ty 11-10 decision: the hab's door and a junction's passage are 2.0 m clear for
  -- the 1.9 m capsule) a run of three cans with a Door Bulkhead and Hab Steps at its -Z end, a
  -- branch off the middle one's +X side (the T) capped; walked in from the ground, up the steps,
  -- through the door, along the run and through the port into the branch, never crouching
  local hp = { { id = "habSteps.steel", x = 0, y = 0, z = -1.8, yaw = math.pi },
               { id = "habBulkhead.steel", x = 0, y = 0, z = -1.2, yaw = 0 } }
  for k = 0, 2 do hp[#hp + 1] = { id = "habSeg.steel", x = 0, y = 0, z = 2 * k, yaw = 0 } end
  hp[#hp + 1] = { id = "habCap.steel", x = 0, y = 0, z = 5.35, yaw = 0 }
  hp[#hp + 1] = { id = "habSeg.steel", x = 2.35, y = 0, z = 2, yaw = math.pi / 2 }
  hp[#hp + 1] = { id = "habCap.steel", x = 3.7, y = 0, z = 2, yaw = math.pi / 2 }
  local sidH = ZF.stamp(ST, hp, zf_g(spot, 80), "Probe Hab")
  wait(6)
  local recH = ST.get(sidH)
  local hj = nil
  for _, p in ipairs(recH and recH.bp or {}) do if p.hj then hj = p.hj end end
  P("ZF hab: %d pieces, the junction %s", recH and #recH.bp or -1, tostring(hj))
  KIT.view("zf_hab_door_out", recH, { 1.2, 1.7, -4.2 }, { 0, 1.4, -1.2 })
  KIT.view("zf_hab_inside_run", recH, { 0, 1.75, -0.6 }, { 0, 1.2, 4.5 })
  KIT.view("zf_hab_port", recH, { -0.4, 1.7, 1.0 }, { 2.4, 1.4, 2.0 })
  KIT.view("zf_hab_door_in", recH, { 0, 1.7, 3.5 }, { 0, 1.4, -1.2 })
  local pw = findScript("planet_walker")
  local crouched = false
  local function watch_crouch() if pw and (pw.crouching or (pw.crouchAmount or 0) > 0.05) then crouched = true end end
  KIT.tp(recH, 0, -4.2)
  wait(1.5)
  local h1 = KIT.walk(recH, 0, -0.4, 14, 0.45, watch_crouch)
  local _, hy1 = KIT.at(recH)
  local h2 = KIT.walk(recH, 0, 2.0, 8, 0.4, watch_crouch)
  local h3 = KIT.walk(recH, 2.3, 2.0, 10, 0.4, watch_crouch)
  local hx3, hy3 = KIT.at(recH)
  P("ZF hab walk: steps+door %s (feet at %.2f), run %s, port %s (at x %.2f, feet %.2f), crouched %s",
    tostring(h1), hy1 or -1, tostring(h2), tostring(h3), hx3 or -1, hy3 or -1, tostring(crouched))
  BK.check("hab_door", h1 and h2 and (hy1 or 0) > 0.5, "up the Hab Steps and through the Door Bulkhead onto the deck, standing")
  BK.check("hab_port", h3 and (hx3 or 0) > 1.5, "through the junction's passage into the branch, standing")
  BK.check("hab_stand", not crouched, "never crouched (a 2.0 m opening for the 1.9 m capsule)")
  KL.forceDoors = false
  if save.flush then save.flush() end
  BK.result()
end
