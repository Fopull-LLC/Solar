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
-- ten switches inside the base: the body left behind and the one taken are
-- never inside a wall, and no button is left focused after a switch
local function switch_test(sr)
  local C = findScript("crew")
  local names = { "Anand", "Halloran", "Anand", "Halloran", "Kowalczyk", "Halloran", "Anand", "Halloran", "Anand", "Halloran" }
  local bad, focus, n = 0, 0, 0
  for i, nm in ipairs(names) do
    local r, id = rec_of(nm)
    local prev = C.activeId()
    if r and id ~= prev then
      local ok, why = C.control(id)
      if not ok then P("GS SWITCH %d → %s refused: %s", i, nm, tostring(why)) else
        wait_for(function() return C.activeId() == id end, 5, "switch " .. nm)
        wait(0.6)
        n = n + 1
        local pr = C.get(prev)
        local wx, wy, wz = nil, nil, nil
        local b = pr and pr.body and space.body(pr.body)
        if b then wx, wy, wz = b.x + pr.x, b.y + pr.y, b.z + pr.z end
        local _, _, _, freeL = C.freeSpot(wx or 0, wy or 0, wz or 0)
        local a = find("Astronaut")
        local _, _, _, freeA = C.freeSpot(a.x, a.y, a.z)
        local f = ui and ui.focused and ui.focused()
        if not (freeL and freeA) then
          bad = bad + 1
          -- what is there: the struct-frame point and what the spheres touch
          local ST = findScript("structures")
          local r = srec()
          local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r)
          local sb = space.body(r.b)
          for _, q in ipairs({ { "left", wx, wy, wz }, { "taken", a.x, a.y, a.z } }) do
            if q[2] then
              local dx, dy, dz = q[2] - (sb.x + r.x), q[3] - (sb.y + r.y), q[4] - (sb.z + r.z)
              local names = {}
              for _, hh in ipairs({ -0.33, 0.35 }) do
                local okh, hits = pcall(overlapSphere, vec3(q[2] + ux * hh, q[3] + uy * hh, q[4] + uz * hh), 0.28)
                for _, ht in ipairs(okh and hits or {}) do names[#names + 1] = tostring(ht.node and ht.node.name or "terrain") end
              end
              P("GS SWITCH DIAG %s at station (%.2f, %.2f, %.2f): %s", q[1], dx * rx + dy * ry + dz * rz, dx * ux + dy * uy + dz * uz,
                dx * fx + dy * fy + dz * fz, table.concat(names, ", "))
            end
          end
        end
        if f then focus = focus + 1 end
        P("GS SWITCH %d → %s: left %s free %s, taken free %s, focus %s", i, nm, tostring(pr and pr.name), tostring(freeL), tostring(freeA), tostring(f and f.name))
      end
    end
  end
  SP.check("switch_ten", n >= 9 and bad == 0 and focus == 0, "%d switches in the base: %d into geometry, %d left a focus", n, bad, focus)
  -- (Dana back to bed: she got up when you took her)
  sr.runBeat({ pose = { who = "Kowalczyk", kind = "lie", at = "mark:danabed", height = 0.68, head = "mark:danapillow", stand = "mark:bunk" } })
end
local function step(sr, id, tmo) local ok = until_(sr, function() return done(id) end, tmo or 60, id); SP.check("step_" .. id, ok, "%s latched", id); return ok end

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
  SP.check("role_tag", tg ~= nil and tostring(tg.rec) == "Kowalczyk" and tg.title ~= nil, "looking at Dana: %s · %s", tostring(tg and tg.name), tostring(tg and tg.title))
  over_shoulder(sr, "a1_dana_face_to_face", "crew:Kowalczyk")
  SP.shot("a1_handover_dialogue", true)
  step(sr, "handover", 120)
  if not alt then
    SP.stand("mark:logdesk", 30)
    until_(sr, function() return sr.var("read_log") end, 20, "the log")
    wait(1.0); SP.shot("a1_shift_log", true)
    until_(sr, function() return not sr.state().line end, 60, "log read")
  end
  SP.stand("mark:console", 30)
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
  if not alt then RP.setProtection(key, true) end
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
  -- (graveyard2) Dana walks to the bunk room, through its door, and lies down
  do
    space.warp(1)
    local cb = body_of("Kowalczyk")
    local w0 = cb and cb.walkStats and { plans = cb.walkStats.plans, paths = cb.walkStats.paths } or { plans = 0, paths = 0 }
    local mind, t0b = 99, W()
    local laid = until_(sr, function()
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
    SP.check("dana_to_bed", laid and mind < 0.9 and db < 0.8 and (ws.paths or 0) > (w0.paths or 0),
      "Dana in her bunk in %.0f s: through the door (%.2f m from it at the nearest), %.2f m from her bunk side, %d paths planned (%d cells asked)",
      W() - t0b, mind, db, (ws.paths or 0) - (w0.paths or 0), ws.evals or -1)
    wait(1.5)
    view("a1_dana_resting", { -3.0, 1.55, 6.3 }, { -5.6, 0.75, 8.4 }, false)
    view("a1_control_room_wide", { -8.4, 1.9, 4.3 }, { -2.0, 0.9, 0.0 }, false)
    if tostring(params.switch or "1") == "1" then switch_test(sr) end
  end
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
  SP.stand("mark:console", 30)
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
    SP.stand("mark:console", 30)
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
    SP.stand("mark:console", 30)
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
  SP.stand("mark:console", 30)
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
