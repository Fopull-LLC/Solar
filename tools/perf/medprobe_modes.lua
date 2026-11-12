-- ── medical probe (tools/perf/medprobe.sh; missions plan S0, N1, M1) ────────
-- Spliced into a copy of perfbench.lua. In a FRESH career:
--   med       the Medical Bay stands between the lab and the VAB with its link
--             and interior; pictured from the alley and inside; the crew is
--             set in the Research Lab and WALKS through the lab's east door,
--             down the glazed link, into the bay to Dr Rao; hurt (hp 0.4, a
--             dose), E at her: the talk plays as a career beat run (a say, a
--             choice on the plate with her live portrait, a shot of her at
--             work), "Patch me up" → hp 1.0, dose 0; a survivor carried in
--             off the alley is admitted (Bed 2); a career beat sequence from
--             mission_story plays (accept: the strip).
--   medrover  a rover from the runway is DRIVEN up Road West and the alley
--             into the bay: medical.craftIn sees it; pictured inside.
-- `MED PASS|FAIL <check>` and `MED RESULT`. Pictures: save/user/medshots/.
MED = { fails = 0, passed = 0 }
function MED.check(name, okc, fmt, ...)
  P("MED %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then MED.passed = MED.passed + 1 else MED.fails = MED.fails + 1 end
  return okc
end
function MED.result() P("MED RESULT %s (%d passed, %d failed)", MED.fails == 0 and "PASS" or "FAIL", MED.passed, MED.fails) end
function MED.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1600, h = 900, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://medshots/" .. nm .. ".png", bytes); P("MED SHOT %s", nm)
    else P("MED SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- the bay's ground frame (tools/base_buildings.py MED: the origin sits at
-- ground (-0.141, 3.430, 0.425)) and the lab's ((0, 4.24, 2.05)) → world, drawn
function MED.G(gx, gy, gz)
  local n = find("FacMedical")
  if not n then return nil end
  return n:toWorld(vec3(gx + 0.141, gy - 3.430, gz - 0.425))
end
function MED.LG(gx, gy, gz)
  local n = find("FacLab")
  if not n then return nil end
  return n:toWorld(vec3(gx, gy - 4.24, gz - 2.05))
end
-- a camera: from ground point a to ground point b in the bay's (or lab's) frame
function MED.cam(a, b, lab)
  local pc = findScript("planet_camera")
  local f = lab and MED.LG or MED.G
  pc.setShot(function()
    local p, q, n = f(a[1], a[2], a[3]), f(b[1], b[2], b[3]), find(lab and "FacLab" or "FacMedical")
    if not (p and q and n) then return nil end
    local o, u = n.worldPos, n:toWorld(vec3(0, 1, 0))
    return p.x, p.y, p.z, q.x, q.y, q.z, u.x - o.x, u.y - o.y, u.z - o.z
  end, 0.05)
  wait(0.8)
end
function MED.cam_off() local pc = findScript("planet_camera"); pcall(pc.clearShot, 0.05); wait(0.5) end
function MED.put(p)
  local a = find("Astronaut")
  if not (a and p) then return end
  local b = home()
  local u = unit(sub(p, b))
  a.x, a.y, a.z = p.x + u.x * 1.0, p.y + u.y * 1.0, p.z + u.z * 1.0
  a.vx, a.vy, a.vz = 0, 0, 0
end
-- walk the avatar to a ground point (fn → world, drawn, this frame) with the
-- walker's own steering in the camera's frame; → the distance left
function MED.walk(fn, tmo, near)
  local pw, pc = findScript("planet_walker"), findScript("planet_camera")
  local a = find("Astronaut")
  local t0, d = W(), 1e9
  while W() - t0 < (tmo or 20) do
    local q = fn()
    if not (q and a) then break end
    local b = home()
    local up = unit(sub(a, b))
    local dx, dy, dz = q.x - a.x, q.y - a.y, q.z - a.z
    local du = dx * up.x + dy * up.y + dz * up.z
    dx, dy, dz = dx - up.x * du, dy - up.y * du, dz - up.z * du
    d = len(dx, dy, dz)
    if d < (near or 0.6) then break end
    local fx, fy, fz = pc.flat_x or pc.fwd_x, pc.flat_y or pc.fwd_y, pc.flat_z or pc.fwd_z
    local rx, ry, rz = fy * up.z - fz * up.y, fz * up.x - fx * up.z, fx * up.y - fy * up.x
    local f = (dx * fx + dy * fy + dz * fz) / d
    local s = (dx * rx + dy * ry + dz * rz) / d
    local m = math.max(math.abs(f), math.abs(s), 1e-3)
    pw.steer(f / m, s / m)
    yield()
  end
  pw.steer(0, 0); yield(); pw.steer(nil)
  return d
end
local function inside_bay(a)
  local md = findScript("medical")
  return md and a and md.inRoom and md.inRoom(a.x, a.y, a.z)
end

function MED.med()
  wait_ready(120)
  wait(3)
  local BF, C, run = findScript("base_facilities"), findScript("crew"), findScript("scenario_run")
  local bay, lab = find("FacMedical"), find("FacLab")
  MED.check("placed", bay ~= nil and lab ~= nil and BF.medicalSite and BF.medicalSite.i == 1,
    "FacMedical %s FacLab %s site %s", tostring(bay ~= nil), tostring(lab ~= nil), tostring(BF.medicalSite and BF.medicalSite.where))
  if not bay then MED.result() return end
  local md = wait_for(function() local m = findScript("medical"); return m and m.linked and m end, 10, "medical")
  MED.check("linked", md and md.linked and find("MedLink") ~= nil and find("MedInterior") ~= nil, "link %s interior %s",
    tostring(find("MedLink") ~= nil), tostring(find("MedInterior") ~= nil))
  -- outside: from the alley, and over the roofs
  md.forceInside = true
  wait(1.5)
  MED.cam({ 2.0, 2.2, 24.0 }, { 0.5, 2.0, 4.0 })
  MED.shot("med_alley")
  MED.cam({ -22.0, 14.0, 22.0 }, { -6.0, 1.0, 0.0 })
  MED.shot("med_aerial")
  MED.cam({ -16.0, 2.0, 6.0 }, { -9.0, 1.5, 0.2 })
  MED.shot("med_link_out")
  -- inside: the treatment area, the bay floor
  MED.cam({ 4.5, 2.3, 6.5 }, { -3.5, 1.0, -5.5 })
  MED.shot("med_in_treat")
  MED.cam({ -5.0, 2.3, -2.0 }, { 3.0, 1.0, 6.0 })
  MED.shot("med_in_bay")
  MED.cam_off()
  md.forceInside = false
  -- the walk: in the lab by its east door → the link → the bay → Dr Rao
  MED.put(MED.LG(7.5, 0.2, 0.15))
  wait(2.5)
  local lb = findScript("lab")
  MED.check("in_lab", lb and lb.crewInLab, "crewInLab %s", tostring(lb and lb.crewInLab))
  local d1 = MED.walk(function() return MED.LG(12.0, 1.0, 0.15) end, 12, 0.7)
  MED.shot("med_walk_door")
  local d2 = MED.walk(function() return MED.G(-9.0, 1.0, 0.15) end, 12, 0.7)
  MED.shot("med_walk_link")
  local d3 = MED.walk(function() return MED.G(-4.5, 1.0, 0.15) end, 12, 0.7)
  local d4 = MED.walk(function() return MED.G(-3.0, 1.0, -3.3) end, 12, 0.6)
  local a = find("Astronaut")
  MED.check("walked_in", d1 < 1.5 and d2 < 1.5 and d3 < 1.5 and inside_bay(a),
    "lab door %.2f, link %.2f, bay %.2f, by her %.2f m left; in the room %s", d1, d2, d3, d4, tostring(inside_bay(a)))
  local medic = wait_for(function() local m = findScript("medical"); return m and m.medic and m.inside and m end, 8, "the medic")
  MED.check("medic", medic ~= nil, "Dr Rao %s, interior %s", tostring(md.medic ~= nil), tostring(md.inside))
  MED.shot("med_at_medic")
  -- hurt, then talk (E at her, through facility_menu's prompt)
  local id = C.activeId()
  C.patch(id, { hp = 0.4, dose = 0.3, hurtBy = "impact" })
  local near = md.nearMedic(a, 2.4)
  P("MED near the medic: %s (%.2f m)", tostring(near ~= nil), near and near.d or -1)
  if not near then MED.walk(function() return md.medic and md.medic.worldPos end, 6, 1.6) end
  tap("e")
  local talking = wait_for(function() return md.isTalking() end, 3, "the talk")
  if not talking then P("MED E did not open it; talk()"); md.talk() end
  local saw = { say = false, choice = false, shot = false, portrait = false }
  local t0 = W()
  local picked, shot_said, plate_shot = false, false, false
  while W() - t0 < 40 do
    local l, ch = run.careerLine()
    if l then saw.say = true; if l.portrait == "rt:medic_face" then saw.portrait = true end end
    if l and not plate_shot and W() - t0 > 1.5 then plate_shot = true; MED.shot("med_talk_line") end
    if ch then
      saw.choice = true
      if not picked then
        wait(1.2)
        MED.shot("med_talk_choice")
        picked = true
        tap("1")
        wait(0.3)
        local _, ch2 = run.careerLine()
        if ch2 then run.choose(1) end
      end
    end
    local pc = findScript("planet_camera")
    if picked and pc and pc.cinematic and not md.lastTalk.treated and not shot_said then
      -- the treatment shot (the runner's camera beat)
      wait(1.5); saw.shot = true; shot_said = true
      MED.shot("med_treat_shot")
    end
    if md.lastTalk and md.lastTalk.treated and not saw.after then
      saw.after = true
      wait(1.5)
      MED.shot("med_treat_after")
    end
    if not md.isTalking() then break end
    yield()
  end
  local r = C.get(id)
  MED.check("career_beats", saw.say and saw.choice and saw.shot, "say %s choice %s shot %s (run %s, dropped %s)",
    tostring(saw.say), tostring(saw.choice), tostring(saw.shot), tostring(run.lastCareer and run.lastCareer.id),
    table.concat(run.lastCareer and run.lastCareer.dropped or {}, ","))
  MED.check("portrait", saw.portrait, "the plate's portrait is her live render target")
  MED.check("healed", r.hp == 1.0 and (r.dose or 0) == 0, "hp %.2f dose %.2f (before: %s)", r.hp or -1, r.dose or -1,
    tostring(md.lastTalk and md.lastTalk.before and md.lastTalk.before.cause))
  MED.check("talk_over", not md.isTalking() and not run.careerActive(), "talking %s runner %s", tostring(md.isTalking()), tostring(run.careerActive()))
  -- a survivor off the alley, carried in
  local p = MED.G(2.75, 0.5, 12.0)
  local b = home()
  local sid = C.newClient("Ines Barrow", { client = "probe", body = b.name, x = p.x - b.x, y = p.y - b.y, z = p.z - b.z, hp = 0.3,
                                            downed = { cause = "impact", left = 0, secs = 0 } })
  MED.put(MED.G(2.75, 0.5, 13.2))
  wait(2.5)
  local okc, whyc = C.carry(sid)
  MED.check("carry", okc and C.carrying() == sid, "carry %s (%s), load %s kg", tostring(okc), tostring(whyc), tostring(findScript("planet_walker").extraLoad))
  local pw = findScript("planet_walker")
  wait(0.6)
  MED.check("carry_load", (pw.packKg or 0) >= 60 and (pw.encumbrance or 0) > 0.3,
    "carrying: packKg %.1f, encumbrance %.2f", pw.packKg or -1, pw.encumbrance or -1)
  MED.walk(function() return MED.G(2.75, 1.0, 3.0) end, 25, 0.8)
  local adm = wait_for(function() return md.isAdmitted(sid) end, 6, "the admit")
  MED.check("admitted", adm and C.get(sid).pose and C.get(sid).pose.kind == "lie" and C.get(sid).hp == 1.0,
    "admitted %s, pose %s, hp %.2f, load %s", tostring(adm), tostring(C.get(sid).pose and C.get(sid).pose.kind), C.get(sid).hp or -1, tostring(pw.extraLoad))
  wait(4)
  MED.cam({ 0.5, 2.0, -3.0 }, { -1.9, 0.7, -6.9 })
  MED.shot("med_admitted")
  MED.cam_off()
  local FT = findScript("feats")
  MED.check("medevac", FT and FT.count and FT.count("medevac") >= 1, "feat medevac %s", tostring(FT and FT.count and FT.count("medevac")))
  -- a mission_story sequence in a career save: a bulk haul's accept line
  local MS = findScript("mission_story")
  local bl, cast = MS and MS.beatsFor({ id = "probe-bulk", kind = "bulk", gen = true, title = "Probe Haul" }, "accept")
  local okr = bl and run.runBeats(bl, { id = "probe-story", cast = cast })
  local strip = findScript("ops_strip")
  wait(1.0)
  MED.check("story_beats", okr == true, "mission_story accept: %d beats, %s", bl and #bl or 0, tostring(bl and bl[1] and bl[1].say and bl[1].say.text))
  MED.shot("med_story_strip")
  wait_for(function() return not run.careerActive() end, 15, "the story run")
  MED.result()
end

-- ── the rover: Road West, the alley, the bay ────────────────────────────────
function MED.rover()
  wait_ready(120)
  wait(2)
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not MED.check("rover", vc ~= nil, "launched %s", tostring(vc and vc.craftName)) then MED.result() return end
  vc.releaseClamps()
  wait(2)
  local vn = vc.node
  local BF = findScript("base_facilities")
  local R, hd = save.get("base.r"), save.get("base.heading")
  local c = unit({ x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") })
  local Fr = BF.frameOf(c, hd, R)
  local function at(u, v)
    local d = BF.dirAt(Fr, u, v)
    local b = home()
    return { x = b.x + d.x * (R + 1), y = b.y + d.y * (R + 1), z = b.z + d.z * (R + 1) }
  end
  -- the way: the taxiway, the apron, Road West, the alley, the bay floor
  local way = { { 0, -40 }, { 0, -14 }, { -14, -8 }, { -29.5, -7 }, { -30.0, 8 }, { -31.0, 19 }, { -31.25, 26 }, { -31.25, 31.5 } }
  local md = findScript("medical")
  local i, t0 = 1, W()
  local log_t = 0
  while i <= #way and W() - t0 < 150 do
    yield()
    if not vn.valid then break end
    local inf = assembly.info(vn)
    local b = home()
    local Rh = unit(sub(inf.com, b))
    local q = at(way[i][1], way[i][2])
    local to = sub(q, inf.com)
    to = sub(to, scl(Rh, dot(to, Rh)))
    local dist = len(to.x, to.y, to.z)
    local v = inf.vel
    local vh = sub(v, scl(Rh, dot(v, Rh)))
    local sp = len(vh.x, vh.y, vh.z)
    local last = i == #way
    if dist < (last and 1.2 or 3.0) then i = i + 1
    else
      local want = nil
      if sp > 0.6 then
        local sn = dot(cross(unit(vh), unit(to)), Rh)
        local cs = dot(unit(vh), unit(to))
        if cs < 0.995 then want = sn >= 0 and "a" or "d" end
      end
      for _, k in ipairs({ "a", "d" }) do
        if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
      end
      local vmax = (i >= #way - 2) and 2.2 or 5.0
      if sp < vmax then if HELD.s then key_up("s") end; if not HELD.w then key_down("w") end
      else if HELD.w then key_up("w") end; if sp > vmax + 1.5 and not HELD.s then key_down("s") elseif HELD.s then key_up("s") end end
    end
    if W() - log_t > 3 then
      log_t = W()
      P("MED drive: waypoint %d/%d, %.1f m to it, speed %.1f, in bay %s", i, #way, dist, sp, tostring(md and md.craftIn and md.craftIn.name))
    end
  end
  release_all()
  -- (the brakes: S held at a stop is reverse, and backed it out of the door)
  tap("b")
  wait(3.0)
  md = findScript("medical")
  local inb = md and md.inBay and vn.valid and md.inBay(vn.x, vn.y, vn.z)
  MED.check("drove_in", inb and md.craftIn ~= nil, "in the bay %s, craftIn %s, reached waypoint %d/%d",
    tostring(inb), tostring(md and md.craftIn and md.craftIn.name), math.min(i, #way), #way)
  md.forceInside = true
  wait(1.0)
  MED.cam({ -4.5, 2.6, -4.0 }, { 2.75, 0.8, 3.0 })
  MED.shot("med_rover_in")
  MED.cam({ 2.0, 2.2, 22.0 }, { 2.75, 1.0, 4.0 })
  MED.shot("med_rover_door")
  MED.cam_off()
  MED.result()
end
