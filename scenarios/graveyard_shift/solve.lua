-- GRAVEYARD SHIFT: the probe's solution (tools/perf/scnprobe.sh <engine> graveyard_shift).
-- Spliced after scnprobe_modes.lua. Plays the shift through the plant's own
-- controls (reactor_plant, the pumps, the valves, the weld) the way the menus
-- call them, answers the dialogue, and takes the pictures of every act.
--   BENCH_STRS='("branch", "alt")': the other branch: the protection left
--   bypassed (no automatic trip: a SCRAM by hand), Dana woken, she starts the
--   makeup herself, the weld late. Default: by the book.
--   graveyard2: Dana walks up for the hand-over (face to face, a picture over
--   your shoulder), walks to the bunk room through its door and lies down
--   (a picture), and in the alt branch you walk to her bunk to wake her. At
--   the end: ten crew switches inside the base, none into a wall, none
--   leaving a button focused (Space would switch again).
--   gy3 (Ty 2026-11-11): you start ON the floor; Dana looks at you while she
--   talks to you, and Priya and Dana at each other's lines; she walks to bed
--   when she says she will (after the hand-over); she and Priya are no one
--   the switcher offers and their records wear the cast's names; the console
--   step ticks on USE (its terminal) from across the room, or standing at it
--   for real (not on its mark); protection ticks on the toggle. Pictures:
--   a1_gaze_side, a1_gaze_listeners. BENCH_STRS='("airlock", "1")': the
--   way out through the airlock walked a step at a time, its doors logged
--   (GS AIRLOCK lines, for the airlock owner; never a fail here).
--   BENCH_STRS='("setback", "1")': as the book, plus a SETBACK at the act 3
--   checkpoint (FW-C, docs/scenarios.md §4.3): a fail as PL-7's act opens,
--   the card, the restage back to `loca` with the story's variables kept.
local S = "Kerne Station"
local GS = {}
-- a camera in the station's own frame, re-placed every frame (docs/positions-and-frames.md)
local function srec()
  local ST = findScript("structures")
  local sid = (save.get("scn.structs") or {})[S]
  return sid and ST.get(sid), sid
end
local function sl(lx, ly, lz)
  local ST = findScript("structures")
  local r = srec()
  if not r then return nil end
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r)
  local b = space.body(r.b)
  return { x = b.x + r.x + rx * lx + ux * ly + fx * lz, y = b.y + r.y + ry * lx + uy * ly + fy * lz, z = b.z + r.z + rz * lx + uz * ly + fz * lz }
end
function lateUpdate(node, dt)
  local c = GS.cam
  if not (c or GS.camw) then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt
  if GS.camw then eye, tgt = GS.camw() else eye, tgt = sl(c[1], c[2], c[3]), sl(c[4], c[5], c[6]) end
  if not (eye and tgt) then return end
  local name = space.dominant(eye.x, eye.y, eye.z)
  local b = name and space.body(name)
  if not b then return end
  pc.setFreecam(true)
  local fc = pc.freecamState and pc.freecamState()
  if not fc then return end
  local pos = vec3(eye.x - b.x, eye.y - b.y, eye.z - b.z)
  local u = pos:normalized()
  fc.body, fc.rel = name, pos
  local d = vec3(tgt.x - eye.x, tgt.y - eye.y, tgt.z - eye.z)
  local du = d:dot(u)
  local h = d - u * du
  fc.ref = h:normalized()
  fc.pitch = math.atan2(du, h:length())
end
local function view(nm, e, t, ui)
  GS.cam = { e[1], e[2], e[3], t[1], t[2], t[3] }
  wait(1.4)
  SP.shot(nm, ui == true)
  GS.cam = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
  wait(0.3)
end

-- the dialogue: click lines through, answer choices by policy
local POLICY = {}
local function talk(sr, hold)
  local st = sr.state()
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    local pick = nil
    for k, v in pairs(POLICY) do if p:find(k, 1, true) then pick = v end end
    if pick then
      P("GS CHOICE %q → %d (%s)", p, pick, tostring(st.choice.options and st.choice.options[pick]))
      sr.choose(pick)
    end
  elseif st.line and not hold and st.line.t0 and (time - st.line.t0) > 0.8 then
    sr.lineDone()
  end
end
local function until_(sr, cond, tmo, what, hold)
  local t0 = W()
  while W() - t0 < (tmo or 60) do
    talk(sr, hold)
    if cond() then return true end
    yield()
  end
  P("GS TIMEOUT %s", tostring(what))
  SP.readings("timeout " .. tostring(what))
  return false
end
local function done(id) return (save.get("scn.done") or {})[id] ~= nil end
-- (graveyard2) metres between two refs now (nil if either is missing)
local function apart(sr, a, b)
  local p, q = sr.posOf(a), sr.posOf(b)
  if not (p and q and p.body == q.body) then return nil end
  -- (along the ground: a crew record is a capsule's centre, a mark the ground)
  local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
  local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
  local du = (dx * q.x + dy * q.y + dz * q.z) / l
  return math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz - du * du))
end
local function rec_of(name)
  local C = findScript("crew")
  local id = (save.get("scn.crew") or {})[name]
  return C and id and C.get(id), id
end
-- a camera over the player's shoulder at member `who`'s face, re-placed every frame
local function over_shoulder(sr, nm, who)
  GS.camw = function()
    local a, q = sr.posOf("crew:Halloran"), sr.posOf(who)
    if not (a and q and a.body == q.body) then return nil end
    local b = space.body(a.body)
    local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    local ux, uy, uz = a.x / l, a.y / l, a.z / l
    local dx, dy, dz = q.x - a.x, q.y - a.y, q.z - a.z
    local du = dx * ux + dy * uy + dz * uz
    dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
    local m = math.sqrt(dx * dx + dy * dy + dz * dz)
    if m < 1e-3 then return nil end
    dx, dy, dz = dx / m, dy / m, dz / m
    local rx, ry, rz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
    local ex, ey, ez = b.x + a.x - dx * 0.55 + rx * 0.35 + ux * 0.75, b.y + a.y - dy * 0.55 + ry * 0.35 + uy * 0.75, b.z + a.z - dz * 0.55 + rz * 0.35 + uz * 0.75
    local tx, ty, tz = b.x + q.x + ux * 0.6, b.y + q.y + uy * 0.6, b.z + q.z + uz * 0.6
    return { x = ex, y = ey, z = ez }, { x = tx, y = ty, z = tz }
  end
  wait(1.2)
  SP.shot(nm, true)
  GS.camw = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
-- the player's own view turned to member `who`'s chest for a moment (the
-- name-and-role tag under the crosshair), then a picture
local function look_at(sr, nm, who, secs)
  local pc = findScript("planet_camera")
  local t0 = W()
  while W() - t0 < (secs or 1.5) do
    local x, y, z = sr.pointOf(who)
    local q = sr.posOf(who)
    if x and pc and pc.face and pc.cam_x then
      local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
      local tx, ty, tz = x + q.x / l * 0.35, y + q.y / l * 0.35, z + q.z / l * 0.35
      local dx, dy, dz = tx - pc.cam_x, ty - pc.cam_y, tz - pc.cam_z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      local du = (dx * q.x + dy * q.y + dz * q.z) / l
      pc.face(dx, dy, dz, math.atan2(du, math.sqrt(math.max(0, d * d - du * du))))
    end
    yield()
  end
  if nm then SP.shot(nm, true) end
end
-- (gy3) the player stood at a point of the station's own frame (x east, y up
-- over its origin: the floor's top is 0.2, so a capsule centre is 1.23), held
-- a few frames: a mark is a TERRAIN point and SP.stand put the capsule's
-- centre 1 m over it, inside the slab where the floor stands higher
local function stand_st(lx, ly, lz, frames_)
  local a = find("Astronaut")
  for _ = 1, frames_ or 20 do
    local q = sl(lx, ly, lz)
    if q and a then a.x, a.y, a.z = q.x, q.y, q.z; a.vx, a.vy, a.vz = 0, 0, 0 end
    yield()
  end
end
-- the Astronaut's capsule centre over the station's origin, now
local function astro_h()
  local ST = findScript("structures")
  local r = srec()
  local a = find("Astronaut")
  if not (r and a and ST) then return nil end
  local ux, uy, uz = ST.frame(r)
  local b = space.body(r.b)
  local p = a.worldPos or a
  return (p.x - b.x - r.x) * ux + (p.y - b.y - r.y) * uy + (p.z - b.z - r.z) * uz
end
-- (gy3) where member `who`'s head looks, against where member `at`'s head is,
-- sampled every frame for `secs` (all read in the same frame: drawn poses)
-- → samples, on target (< 20 deg, weight > 0.6, the talk look's target is them), worst deg
local function gaze_samples(sr, who, at, secs, t_skip)
  local _, wid = rec_of(who)
  local _, aid = rec_of(at)
  local n, good, worst, eyes, aimed = 0, 0, 0, 0, 0
  local t0 = W()
  while W() - t0 < secs do
    talk(sr, true)
    if W() - t0 >= (t_skip or 0) then
      local x, y, z, w, tg = sr.talkLook(wid)
      local cb = body_of(who)
      local hx, hy, hz = nil, nil, nil
      if cb and cb.headPoint then hx, hy, hz = cb.headPoint() end
      local px, py, pz = sr.talkHead(aid)
      if x and hx and px then
        local ax, ay, az = x - hx, y - hy, z - hz
        local bx, by, bz = px - hx, py - hy, pz - hz
        local la, lb = math.sqrt(ax * ax + ay * ay + az * az), math.sqrt(bx * bx + by * by + bz * bz)
        local deg = math.deg(math.acos(math.max(-1, math.min(1, (ax * bx + ay * by + az * bz) / (la * lb)))))
        n = n + 1
        if deg < 20 and (w or 0) > 0.6 and tg == aid then good = good + 1 end
        if (w or 0) > 0.5 and tg == aid then aimed = aimed + 1 end
        if deg > worst then worst = deg end
        local fc = nil
        for _, f in ipairs(findScripts("face")) do if f.memberId == wid then fc = f end end
        if fc and fc.talkGaze then eyes = eyes + 1 end
      end
    end
    yield()
  end
  return n, good, worst, eyes, aimed
end
-- a picture from the side of two people talking, re-placed every frame
local function side_view(sr, nm, a, b)
  GS.camw = function()
    local p, q = sr.posOf(a), sr.posOf(b)
    if not (p and q and p.body == q.body) then return nil end
    local bd = space.body(p.body)
    local l = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
    local ux, uy, uz = p.x / l, p.y / l, p.z / l
    local dx, dy, dz = q.x - p.x, q.y - p.y, q.z - p.z
    local du = dx * ux + dy * uy + dz * uz
    dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
    local m = math.sqrt(dx * dx + dy * dy + dz * dz)
    if m < 1e-3 then return nil end
    dx, dy, dz = dx / m, dy / m, dz / m
    local rx, ry, rz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
    local mx, my, mz = bd.x + (p.x + q.x) / 2, bd.y + (p.y + q.y) / 2, bd.z + (p.z + q.z) / 2
    return { x = mx + rx * 2.1 + ux * 0.65, y = my + ry * 2.1 + uy * 0.65, z = mz + rz * 2.1 + uz * 0.65 },
           { x = mx + ux * 0.55, y = my + uy * 0.55, z = mz + uz * 0.55 }
  end
  local t0 = W()
  while W() - t0 < 1.0 do talk(sr, true); yield() end
  SP.shot(nm, true)
  GS.camw = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
-- (gy3, Ty: "I can control Dana as one of the crew members") the cast
-- members you don't play: refused by every switching verb, on no list
local function npc_test(sr, tg)
  local C = findScript("crew")
  local r, id = rec_of("Kowalczyk")
  local rp, idp = rec_of("Anand")
  local me, idm = rec_of("Halloran")
  local ok1, why1 = C.control(id)
  local ok2 = C.control(idp)
  local ok3 = C.canSwitch(id)
  local ok4 = C.switchToMember(id)
  local inList, inPick = false, false
  for _, e in ipairs(C.switchList() or {}) do if e.id == id or e.id == idp then inList = true end end
  for _, m in ipairs(C.switchTargets() or {}) do if m.id == id or m.id == idp then inPick = true end end
  wait(0.6)
  SP.check("dana_not_playable", not ok1 and not ok2 and not ok3 and not ok4 and not inList and not inPick and C.activeId() == idm,
    "control %s (%s), Priya %s, canSwitch %s, switchToMember %s, on the [ ] list %s, on the picker %s, still Halloran %s",
    tostring(ok1), tostring(why1), tostring(ok2), tostring(ok3), tostring(ok4), tostring(inList), tostring(inPick), tostring(C.activeId() == idm))
  SP.check("names_agree", r and r.name == "Dana Kowalczyk" and rp and rp.name == "Dr Priya Anand" and me and me.name == "Halloran"
    and tg ~= nil and tg.name == "Dana Kowalczyk" and tostring(tg.rec) == "Dana Kowalczyk",
    "records %s / %s / %s; the tag over her %s (record %s)", tostring(r and r.name), tostring(rp and rp.name), tostring(me and me.name),
    tostring(tg and tg.name), tostring(tg and tg.rec))
end
-- (gy3, the airlock owner's repro: Ty "the first door opened and the second
-- one wouldn't") the way out walked a step at a time: to the inner door,
-- into the chamber, to the outer door, out; at each door the walker waits
-- for it (up to 25 s) as a person would, and every 0.5 s the chamber is
-- logged: which door it allows, its target, the pressures, each door's open
-- fraction, the gate's answer. Helmet on. Never a check: GS AIRLOCK lines.
local function airlock_walk(sr, sid)
  local RA, KL, ST = findScript("room_air"), findScript("kit_live"), findScript("structures")
  local S_ = RA and RA.state and RA.state(sid)
  if not (S_ and S_.cham and KL and ST) then P("GS AIRLOCK no chamber state") return end
  local C, rid = nil, nil
  for r_, c in pairs(S_.cham) do C, rid = c, r_ end
  if not C then P("GS AIRLOCK no airlock") return end
  local r = srec()
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r)
  local function local_of(n)
    if not (n and n.valid ~= false) then return nil end
    local b = space.body(r.b)
    local p = n.worldPos or n
    local dx, dy, dz = p.x - b.x - r.x, p.y - b.y - r.y, p.z - b.z - r.z
    return dx * rx + dy * ry + dz * rz, dx * ux + dy * uy + dz * uz, dx * fx + dy * fy + dz * fz
  end
  local doors = {}
  for _, u in ipairs(C.doors or {}) do
    local e = (KL.entries() or {})[sid .. ":" .. u]
    if not e then for _, ee in pairs(KL.entries() or {}) do if ee.sid == sid and ee.uid == u then e = ee end end end
    local x, _, z = local_of(e and e.node)
    doors[#doors + 1] = { uid = u, x = x, z = z }
    P("GS AIRLOCK door %s at station (%.2f, %.2f) label %s", tostring(u), x or -99, z or -99, tostring(e and e.def and e.def.label))
  end
  local function dump(tag)
    local s2 = RA.state(sid)
    local c = s2 and s2.cham[rid] or C
    local A = s2 and s2.air and s2.air[rid]
    local rr = s2 and s2.R and s2.R.byId and s2.R.byId[rid]
    local pc = (A and rr and rr.m3 and rr.m3 > 0) and ((A.N + A.x + A.c) / rr.m3) or -1
    local parts = {}
    for _, d in ipairs(doors) do parts[#parts + 1] = string.format("%s open %.2f", tostring(d.uid), KL.doorOpen(sid, d.uid) or -1) end
    local csid, crid = RA.crewRoom()
    P("GS AIRLOCK %s: crew room %s/%s (chamber %s) allow %s target %s entered %s cyc %s dir %s pc %.3f atm · %s · said %s · suit %s",
      tag, tostring(csid), tostring(crid), tostring(rid), tostring(c.allow), tostring(c.target), tostring(c.entered), tostring(c.cyc),
      tostring(c.dir), pc, table.concat(parts, ", "), tostring(RA.lastCycle), tostring(RA.lastSuitRefusal and RA.lastSuitRefusal.uid))
  end
  if #doors < 2 or not doors[1].x then dump("no doors placed") return end
  -- inner = the door nearer the control room's middle (-5, 2)
  table.sort(doors, function(p_, q_) return ((p_.x + 5) ^ 2 + (p_.z - 2) ^ 2) < ((q_.x + 5) ^ 2 + (q_.z - 2) ^ 2) end)
  local inn, out = doors[1], doors[#doors]
  local cx, cz = (inn.x + out.x) / 2, (inn.z + out.z) / 2
  local ix, iz = inn.x + (inn.x - cx) * 0.9, inn.z + (inn.z - cz) * 0.9       -- before the inner door, inside
  local ox, oz = out.x + (out.x - cx) * 0.9, out.z + (out.z - cz) * 0.9       -- past the outer door, outside
  local path = { { ix, iz, nil }, { inn.x, inn.z, inn.uid }, { cx, cz, nil }, { out.x, out.z, out.uid }, { ox, oz, nil } }
  local px, pz = ix, iz
  stand_st(px, 1.23, pz, 10)
  local t_log = 0
  for k, wp in ipairs(path) do
    local tx, tz, du = wp[1], wp[2], wp[3]
    local tw0 = W()
    while true do
      local dx, dz = tx - px, tz - pz
      local d = math.sqrt(dx * dx + dz * dz)
      if d < 0.05 then break end
      -- before a door: wait for it to be open
      local wait_door = du and d < 0.7 and (KL.doorOpen(sid, du) or 0) < 0.8
      if wait_door then
        if W() - tw0 > 25 then dump(string.format("GAVE UP at door %s after 25 s", tostring(du))) return false end
      else
        local st = math.min(d, 0.04)
        px, pz = px + dx / d * st, pz + dz / d * st
      end
      stand_st(px, 1.23, pz, 1)
      if W() - t_log > 0.5 then t_log = W(); dump(string.format("leg %d (%.2f, %.2f)%s", k, px, pz, wait_door and " WAITING" or "")) end
    end
    dump(string.format("reached leg %d in %.1f s", k, W() - tw0))
  end
  return true
end
local function step(sr, id, tmo) local ok = until_(sr, function() return done(id) end, tmo or 60, id); SP.check("step_" .. id, ok, "%s latched", id); return ok end

-- (graveyard2) Dana walks to the bunk room, through its door, and lies down
-- (gy3: after the hand-over, when she says she is going)
function dana_bed(sr)
  do
    space.warp(1)
    local cb = body_of("Kowalczyk")
    local w0 = cb and cb.walkStats and { plans = cb.walkStats.plans, paths = cb.walkStats.paths } or { plans = 0, paths = 0 }
    local mind, t0b = 99, W()
    local laid = until_(sr, function()
      talk(sr)
      local d = apart(sr, "crew:Kowalczyk", "mark:bunkdoor")
      if d and d < mind then mind = d end
      local r = rec_of("Kowalczyk")
      return r and type(r.pose) == "table" and r.pose.kind == "lie"
    end, 60, "Dana lies down")
    cb = body_of("Kowalczyk")
    local ws = cb and cb.walkStats or {}
    local db = apart(sr, "crew:Kowalczyk", "mark:bunk") or -1
    P("GS WALK Dana: ticks %s metres %.1f game %.1f s waits %s stops %s plans %s straight %s",
      tostring(ws.ticks), ws.metres or -1, ws.game or -1, tostring(ws.waits), tostring(ws.stops), tostring(ws.plans), tostring(ws.straight))
    SP.check("dana_to_bed", laid and mind < 0.9 and db < 0.8 and (ws.paths or 0) + (ws.straight or 0) > (w0.paths or 0),
      "Dana in her bunk in %.0f s: through the door (%.2f m from it at the nearest), %.2f m from her bunk side, %d paths planned (%d cells asked)",
      W() - t0b, mind, db, (ws.paths or 0) - (w0.paths or 0), ws.evals or -1)
    wait(1.5)
    view("a1_dana_resting", { -3.0, 1.55, 6.3 }, { -5.6, 0.75, 8.4 }, false)
    -- (fix) on the lower mattress, not the floor: the pose's surface in the
    -- station's frame is the mattress top (0.68 over the frame's origin), and
    -- a low picture from the bunk's side
    do
      local r = rec_of("Kowalczyk")
      local ST = findScript("structures")
      local s = srec()
      local h = -9
      if r and type(r.pose) == "table" and s and ST then
        local ux, uy, uz = ST.frame(s)
        h = (r.pose.x - s.x) * ux + (r.pose.y - s.y) * uy + (r.pose.z - s.z) * uz
      end
      SP.check("dana_on_mattress", math.abs(h - 0.68) < 0.03, "her pose's surface %.2f m over the station's origin (the lower mattress's top 0.68; the slab's 0.2)", h)
      view("a1_dana_on_bunk", { -4.25, 0.95, 7.5 }, { -5.7, 0.8, 8.45 }, false)
    end
    view("a1_control_room_wide", { -8.4, 1.9, 4.3 }, { -2.0, 0.9, 0.0 }, false)
  end
end

function SOLVE(SP)
  local sr = SP.run_()
  local RP, ST, RU, inv = findScript("reactor_plant"), findScript("structures"), findScript("ruins"), findScript("inventory")
  local alt = tostring(params.branch or "") == "alt"
  P("GS branch %s", alt and "ALT (protection bypassed, Dana woken)" or "MAIN (by the book)")
  POLICY = { ["Questions before"] = alt and 1 or 2, ["Which one"] = 1, ["wake her"] = alt and 1 or 2, ["What do you need"] = 1 }
  local _, sid = srec()
  local e = RP.plantOfPart(sid)
  SP.check("plant", e ~= nil and e.M ~= nil, "the station's plant: %s", e and e.key or "none")
  local key = RP.keyOf(e.sid, e.uid)
  local function sunAt()
    local E = findScript("electronics")
    local r = srec()
    local b = r and space.body(r.b)
    if not (E and E.sunOf and b) then return -9 end
    local sun = E.sunOf(b.x, b.y, b.z, space.bodies() or {})
    if not sun then return -9 end
    local ux, uy, uz = r.x, r.y, r.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    local sx, sy, sz = sun.x - b.x, sun.y - b.y, sun.z - b.z
    local m = math.sqrt(sx * sx + sy * sy + sz * sz)
    return (ux * sx + uy * sy + uz * sz) / (l * m)
  end
  local function line(tag)
    local o = e.o or {}
    P("GS SUN %s: %.3f at agency %.0f s", tag, sunAt(), findScript("deployables") and findScript("deployables").agencyClock() or -1)
    P("GS RX %s: P %.3f Tf %.0f Tp %.0f Pe %.1f kW inv %.3f prot %s %s · vars peak %s dose %s kwh %.2f brg %s",
      tag, o.P or -1, o.Tf or 0, o.Tp or 0, (o.Pe or 0) / 1000, e.S.y[22] or -1, tostring(e.S.prot), e.S.scram and ("TRIP " .. tostring(e.S.cause)) or tostring(e.S.mode),
      tostring(sr.var("peak_k")), tostring(sr.var("dose_msv")), sr.var("kwh") or 0, tostring(sr.var("brg")))
  end
  line("staged")
  -- (gy3, Ty: "graveyard shift spawned me in the ground") on the floor, not in the slab
  do
    local h = astro_h() or -9
    SP.check("spawn_on_floor", h - 0.95 >= 0.17 and h - 0.95 <= 0.40, "the capsule's centre %.2f m over the station's origin: feet at %.2f (the floor's top 0.20; the suit capsule stands 0.95 m)", h, h - 0.95)
  end
  -- portraits: each named crew member's face, from a metre in front, toward the console
  local function face(nm, who)
    local p = sr.posOf(who)
    local c = sr.posOf("mark:console")
    if not (p and c and p.body == c.body) then P("GS no face for %s", who) return end
    GS.camw = function()
      local b = space.body(p.body)
      local q = sr.posOf(who)
      if not (b and q) then return nil end
      local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
      local ux, uy, uz = q.x / l, q.y / l, q.z / l
      local dx, dy, dz = c.x - q.x, c.y - q.y, c.z - q.z
      local du = dx * ux + dy * uy + dz * uz
      dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
      local m = math.sqrt(dx * dx + dy * dy + dz * dz)
      if m < 1e-3 then dx, dy, dz, m = 1, 0, 0, 1 end
      dx, dy, dz = dx / m, dy / m, dz / m
      local h = 1.55
      local hx, hy, hz = b.x + q.x + ux * h, b.y + q.y + uy * h, b.z + q.z + uz * h
      return { x = hx + dx * 0.95, y = hy + dy * 0.95, z = hz + dz * 0.95 }, { x = hx, y = hy, z = hz }
    end
    wait(1.2)
    SP.shot(nm, false)
    GS.camw = nil
    local pc = findScript("planet_camera")
    if pc and pc.setFreecam then pc.setFreecam(false) end
  end
  -- (portraits: crew positions read here are their records', not their bodies
  -- yet; face() is kept for when they are)
  -- ── ACT 1 ──
  -- the arrival's cutscene: pictures while it plays
  if sr.state().cutscene then
    wait(2.5); SP.shot("a0_arrival_flyin", true)
    wait(5.0); SP.shot("a0_arrival_dolly", true)
    until_(sr, function() return not sr.state().cutscene end, 30, "arrival ends")
  end
  wait(1.0)
  -- (graveyard2) Dana turns from the console and walks up to you
  local d0 = apart(sr, "crew:Kowalczyk", "crew:Halloran") or -1
  local came = until_(sr, function() local d = apart(sr, "crew:Kowalczyk", "crew:Halloran"); return d and d < 1.9 end, 25, "Dana walks up", true)
  local d1 = apart(sr, "crew:Kowalczyk", "crew:Halloran") or -1
  SP.check("dana_walks_up", came and d1 > 0.9, "Dana from %.2f m to %.2f m of you, face to face", d0, d1)
  until_(sr, function() local st = sr.state(); return st.line and st.line.who == "dana" end, 10, "Dana speaks", true)
  -- (graveyard2) who is who: the tag under the crosshair when you look at her
  -- (before the over-the-shoulder picture: its freecam leaves the view's pitch behind)
  look_at(sr, nil, "crew:Kowalczyk", 1.2)
  local hud = findScript("crew_alerts_hud")
  local tg = hud and hud.tagNow
  for _ = 1, 8 do if tg then break end; look_at(sr, nil, "crew:Kowalczyk", 0.25); tg = hud and hud.tagNow end
  P("GS TAG ray met %s", tostring(hud and hud.tagRay))
  look_at(sr, "a1_role_tag", "crew:Kowalczyk", 0.3)
  SP.check("role_tag", tg ~= nil and tostring(tg.rec) == "Dana Kowalczyk" and tg.title ~= nil, "looking at Dana: %s · %s", tostring(tg and tg.name), tostring(tg and tg.title))
  over_shoulder(sr, "a1_dana_face_to_face", "crew:Kowalczyk")
  SP.shot("a1_handover_dialogue", true)
  -- (gy3) Dana's head and eyes on you while she talks to you
  do
    local st = sr.state()
    local n, good, worst, eyes = gaze_samples(sr, "Kowalczyk", "Halloran", 2.5, 0.0)
    SP.check("dana_gaze_at_you", n > 20 and good >= 0.6 * n and eyes >= 0.9 * n,
      "on '%s…' (with %s): her head on yours %d of %d frames (worst %.0f deg, the looks away), her eyes' look set %d",
      tostring(st.line and st.line.text or "?"):sub(1, 30), tostring(st.line and st.line.with and st.line.with.who), good, n, worst, eyes)
    side_view(sr, "a1_gaze_side", "crew:Kowalczyk", "crew:Halloran")
  end
  -- (gy3) Priya's line to you: she looks at you, Dana turns to her
  do
    until_(sr, function() local st = sr.state(); return st.line and st.line.who == "priya" end, 60, "Priya speaks")
    -- (Dana is a bystander here: her HEAD turns to Priya, her body stays on
    -- you, so Priya behind her is reached as far as a neck goes: the check
    -- is that her look is Priya's; the angle is reported)
    local n2, g2, w2, _, a2 = gaze_samples(sr, "Kowalczyk", "Anand", 1.6, 1.0)
    local n1, g1, w1 = gaze_samples(sr, "Anand", "Halloran", 1.2, 0.3)
    SP.check("priya_gaze_and_listener", n1 > 15 and g1 >= 0.6 * n1 and n2 > 10 and a2 >= 0.8 * n2,
      "Priya's head on yours %d of %d (worst %.0f deg); Dana's look on Priya %d of %d, within 20 deg %d (worst %.0f deg)", g1, n1, w1, a2, n2, g2, w2)
    side_view(sr, "a1_gaze_listeners", "crew:Anand", "crew:Kowalczyk")
  end
  step(sr, "handover", 120)
  -- (gy3, Ty: "she doesn't go to the bedroom to sleep when she says she's gonna sleep")
  dana_bed(sr)
  npc_test(sr, tg)
  local _, cuid = sr.pieceOf({ struct = S, part = "reactorConsole" })
  if not alt then
    stand_st(-6.6, 1.23, 2.6, 30)
    until_(sr, function() return sr.var("read_log") end, 20, "the log")
    wait(1.0); SP.shot("a1_shift_log", true)
    until_(sr, function() return not sr.state().line end, 60, "log read")
    -- (gy3, Ty: "told to go to the reactor console while already using it")
    -- from the log desk: not yet; then its menu (a right-click) from there,
    -- 5 m off, ticks it; and its terminal (E) from 1.9 m off its mark, past
    -- the step's r 1.8 but within the terminal's reach, reads as in use
    wait(1.0)
    local before = done("console")
    local CM, ST2 = findScript("context_menu"), findScript("structures")
    local cn = ST2.nodeOf and ST2.nodeOf(sid, cuid)
    local okM = cn and CM and CM.openFor and CM.openFor({ kind = "prop", node = cn, label = "Reactor Console" }, CM.actorNow and CM.actorNow() or nil)
    local t0c = W()
    local ok = until_(sr, function() return done("console") end, 5, "console on its menu")
    SP.check("console_on_use", not before and okM and ok, "not by distance from the desk (%s); its menu open from there (%s) latched it in %.1f s",
      tostring(not before), tostring(okM), W() - t0c)
    if CM and CM.close then CM.close() end
    local T = findScript("terminal")
    stand_st(-5.2, 1.23, 1.2, 20)
    local okT = T and T.openAt and T.openAt(sid, cuid, "REACTOR")
    wait(0.5)
    local u, how = sr.worldAdapter.using({ struct = S, part = "reactorConsole" })
    local m2, rd2 = findScript("scenario").evalGoal({ kind = "at", who = "crew:Halloran", at = "mark:console", r = 1.8 }, sr.worldAdapter, {}, { now = 0 })
    SP.check("console_terminal_use", okT and u == true and not m2, "its terminal open (%s) reads as in use (%s: %s) from %s off its mark (the at goal alone: %s)",
      tostring(okT), tostring(u), tostring(how), tostring(rd2), tostring(m2))
    -- (gy3) protection: the REACTOR page's toggle, as its row does it; the
    -- story's reading of it (prot_ok, Priya's line) follows at once
    local p0 = sr.var("prot_ok")
    local t0p = W()
    RP.setProtection(key, false, "hand"); wait(0.4)
    RP.setProtection(key, true, "hand")
    local okp = until_(sr, function() return sr.var("prot_ok") == true end, 3, "protection read")
    local evp = until_(sr, function() return (save.get("scn.ev") or {}).prot_seen ~= nil end, 3, "protection noticed")
    SP.check("protection_on_toggle", p0 ~= true and okp and evp, "off then ARMED on the toggle: prot_ok %s in %.1f s, its event %s",
      tostring(sr.var("prot_ok")), W() - t0p, tostring(evp))
    if T and T.close then T.close() end
    stand_st(-3.05, 1.23, 0.0, 20)
  else
    -- standing at the console as a player does (0.75 m off its middle), not on its mark
    stand_st(-3.05, 1.23, 0.0, 20)
    local ok = until_(sr, function() return done("console") end, 5, "console by standing")
    SP.check("console_at_real_spot", ok, "standing in front of it (%.2f m along the ground from its mark) latched it", apart(sr, "crew:Halloran", "mark:console") or -1)
  end
  step(sr, "console", 20)
  -- (graveyard2, S7) the HINT key: F1 shows the step's hint as a toast
  do
    local su = findScript("scenario_ui")
    if input and input.simulate then
      input.simulate({ key = "f1", down = true }); yield(); yield()
      input.simulate({ key = "f1", down = false })
    end
    wait(0.5)
    local lh = su and su.lastHint
    local st = sr.state()
    SP.check("hint_key", lh ~= nil and lh.ok == true and type(lh.text) == "string" and st.hint ~= nil,
      "F1 → %s %s (card hint %s)", tostring(lh and lh.ok), tostring(lh and lh.text), tostring(st.hint ~= nil))
    SP.shot("a1_hint_toast", true)
    local ok2, why2 = sr.hint()
    SP.check("hint_again", ok2 == true, "a second press answers too (%s)", tostring(why2))
  end
  space.warp(5)
  RP.setPoint(key, 0.3)
  view("a1_console_close", { -3.25, 1.75, 0.0 }, { -2.3, 1.15, 0.0 }, false)
  step(sr, "p30", 240)
  line("30 %")
  RP.setTurbine(key, true)
  step(sr, "turbine", 120)
  RP.setPoint(key, 0.6)
  step(sr, "p60", 240)
  line("60 %")
  -- (holding the shift at 60 %: ten game minutes at 10x, as a player waits
  -- for the night; the hum comes in it: its question on screen for the picture)
  space.warp(10)
  POLICY["Which one"] = nil
  local t0h, shot_h = W(), false
  while W() - t0h < 55 or not done("diagnose") do
    talk(sr)
    local st = sr.state()
    if st.choice and not shot_h then
      space.warp(1); wait(1.0); SP.shot("a2_hum_choice", true); shot_h = true
      POLICY["Which one"] = 1
      space.warp(10)
    end
    if W() - t0h > 150 then break end
    yield()
  end
  space.warp(1)
  line("after the hold")
  view("a1_control_room_at_power", { -6.4, 1.8, 4.4 }, { -1.0, 1.0, 0.0 }, true)
  view("a1_hall_at_power", { 11.8, 3.6, -6.2 }, { 4.0, 1.2, 0.5 }, false)
  -- the frame's cost at the base (High): the control room, the hall, the outside
  local function cost(name, e, t)
    GS.cam = e and { e[1], e[2], e[3], t[1], t[2], t[3] } or nil
    wait(1.5)
    sc_begin(name); wait(8); sc_end(name)
    local c = perf.counts and perf.counts() or {}
    P("GS COST %s: draws %s instances %s lights %s (dropped %s) nodes %s · scenario_run %.4f ms, hooks %.4f ms, reactor_plant %.4f ms", name,
      tostring(c.draws), tostring(c.instances), tostring(c.lights), tostring(c.lightsDropped), tostring(c.nodes),
      perf.scriptMs and perf.scriptMs("scenario_run") or -1, perf.scriptMs and perf.scriptMs("scn_graveyard_shift_hooks") or -1,
      perf.scriptMs and perf.scriptMs("reactor_plant") or -1)
    GS.cam = nil
    local pc = findScript("planet_camera")
    if pc and pc.setFreecam then pc.setFreecam(false) end
  end
  cost("gs_control_room", { -6.4, 1.7, 4.4 }, { -1.0, 1.0, 0.0 })
  cost("gs_hall", { 11.8, 3.6, -6.2 }, { 4.0, 1.2, 0.5 })
  cost("gs_outside", { -14, 3.0, -14 }, { 6, 1.5, 2 })
  -- ── ACT 2 ──
  step(sr, "diagnose", 60)
  RP.setPoint(key, 0.4)
  space.warp(4)
  step(sr, "setback", 120)
  space.warp(1)
  local su = findScript("suit")
  if su and su.setHelmet then pcall(su.setHelmet, true) end
  if tostring(params.airlock or "") == "1" then
    local okA = airlock_walk(sr, sid)
    P("GS AIRLOCK walked out: %s", tostring(okA))
  end
  SP.stand("mark:lockout", 40)
  step(sr, "suit", 30)
  wait(1.0); SP.shot("a2_outside_dark", true)
  SP.stand("mark:skid", 40)
  step(sr, "skid", 30)
  wait(1.0); SP.shot("a2_at_the_skid", true)
  view("a2_skid_wide", { 14.0, 2.4, -1.5 }, { 19.0, 0.8, 4.6 }, false)
  RP.setPump(sid, 147, false)
  step(sr, "isolate", 30)
  until_(sr, function() local p = ST.getPart(sid, 147); return p and p.wr end, 10, "knocked")
  -- the repair, as the menu's job ends: the kit used, the piece back
  if inv and inv.removeItem then inv.removeItem("astro", "repairkit", 1) end
  wait(2.0)
  RU.repairPiece(sid, 147)
  step(sr, "swap", 30)
  RP.setPump(sid, 147, true)
  step(sr, "restore", 30)
  stand_st(-3.05, 1.23, 0.0, 30)
  if su and su.setHelmet then pcall(su.setHelmet, false) end
  RP.setPoint(key, 0.6)
  space.warp(4)
  step(sr, "back", 180)
  space.warp(1)
  line("back at 60 %")
  if tostring(params.setback or "") == "1" then
    until_(sr, function() local cp = save.get("scn.cpSnap"); return cp and cp.id == "loca" end, 20, "the act 3 checkpoint")
    local snap = save.get("scn.cpSnap") or { vars = {} }
    sr.fail("Probe: a setback at the act 3 checkpoint.")
    wait(1.0)
    SP.check("setback_card", sr.phaseNow() == "setback", "the fail is a setback (phase %s)", tostring(sr.phaseNow()))
    SP.shot("a3_setback_card", true)
    if SP.fail_screen then SP.fail_screen(sr, "a3") end
    local sr2 = nil
    local t0 = W()
    while W() - t0 < 300 do
      local s2 = findScript("scenario_run")
      if s2 and s2 ~= sr and s2.isActive and s2.isActive() and s2.phaseNow and s2.phaseNow() == "running" then sr2 = s2 break end
      yield()
    end
    local d = save.get("scn.done") or {}
    SP.check("setback_restore", sr2 ~= nil and d.back ~= nil and d.loca == nil and sr2.var("kwh") == snap.vars.kwh and sr2.var("brg_fixed") == snap.vars.brg_fixed
      and (tonumber(save.get("scn.setbacks")) or 0) == 1, "back at PL-7's act: back %s, loca %s, kwh %s (snap %s), brg_fixed %s, setbacks %s",
      tostring(d.back ~= nil), tostring(d.loca), tostring(sr2 and sr2.var("kwh")), tostring(snap.vars.kwh), tostring(sr2 and sr2.var("brg_fixed")), tostring(save.get("scn.setbacks")))
    sr = sr2 or SP.run_()
    local gm = findScript("game_manager")
    until_(sr, function() return gm and not gm.curtain end, 60, "the reveal")
    RP, ST, RU = findScript("reactor_plant"), findScript("structures"), findScript("ruins")
    _, sid = srec()
    e = RP.plantOfPart(sid)
    key = RP.keyOf(e.sid, e.uid)
    local o = e.o or {}
    SP.check("setback_plant", (o.P or 0) > 0.5, "the plant restaged at %.0f %% (turbine %s)", (o.P or 0) * 100, tostring(e.turbOn))
    stand_st(-3.05, 1.23, 0.0, 30)
    line("after the setback")
  end
  -- ── ACT 3 ──
  until_(sr, function() return sr.state().cutscene end, 60, "the trip")
  wait(1.5); SP.shot("a3_trip_pl7", true)
  wait(3.5); SP.shot("a3_trip_core", true)
  until_(sr, function() return not sr.state().cutscene end, 40, "trip ends")
  line("+trip")
  if alt then
    wait(12)
    line("bypassed, before the hand SCRAM")
    RP.scram(key)
  end
  step(sr, "loca", 60)
  if alt then
    -- (graveyard2) waking Dana: walk to her bunk and talk to her
    SP.stand("mark:wakespot", 30)
    local up = until_(sr, function() local r = rec_of("Kowalczyk"); return r and type(r.pose) == "table" and r.pose.kind == "sit" end, 15, "Dana sits up", true)
    wait(1.0)
    view("a3_wake_dana", { -6.4, 1.5, 6.1 }, { -5.3, 0.9, 8.0 }, true)
    local woke = until_(sr, function() return sr.var("woke") == true end, 40, "Dana woken")
    local gone = until_(sr, function() local d = apart(sr, "crew:Kowalczyk", "mark:danaboard"); return d and d < 1.0 end, 40, "Dana at the board")
    SP.check("wake_dana", up and woke and gone, "woken by her bunk (sat up %s, woke %s), at the board %s", tostring(up), tostring(woke), tostring(gone))
    stand_st(-3.05, 1.23, 0.0, 30)
  end
  view("a3_hall_alarm", { 11.8, 3.6, -6.2 }, { 4.0, 1.2, 0.5 }, true)
  if not alt then
    SP.stand("mark:mu1", 30)
    wait(1.0)
    local FN = findScript("fluid_net")
    FN.setOn(sid, 116, true)
    P("GS TANK %s kg", tostring(FN.content(sid, 118)))
    wait(2.0); SP.shot("a3_makeup_on", true)
  else
    until_(sr, function() return sr.var("dana_mu") end, 150, "Dana starts the makeup")
  end
  line("makeup")
  SP.stand("mark:pl7", 30)
  wait(alt and 20 or 4)
  SP.shot("a3_weld_at_pl7", true)
  RP.breakPipe(sid, 109, 0)
  line("welded")
  stand_st(-3.05, 1.23, 0.0, 30)
  space.warp(10)
  step(sr, "stabilise", 300)
  space.warp(1)
  line("stable")
  -- ── ACT 4 ──
  until_(sr, function() return sr.state().cutscene end, 30, "the morning")
  wait(4); SP.shot("a4_morning", true)
  step(sr, "morning", 120)
  for _, k in ipairs({ "peak_k", "dose_msv", "kwh", "prot_at_break", "woke", "seized", "dana_mu", "read_log" }) do P("GS VAR %s = %s", k, tostring(sr.var(k))) end
  wait(2); SP.shot("a4_debrief", true)
end
