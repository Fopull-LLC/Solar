-- GRAVEYARD SHIFT: the probe's solution (tools/perf/scnprobe.sh <engine> graveyard_shift).
-- Spliced after scnprobe_modes.lua. Plays the shift through the plant's own
-- controls (reactor_plant, the pumps, the valves, the weld) the way the menus
-- call them, answers the dialogue, and takes the pictures of every act.
--   BENCH_STRS='("branch", "alt")': the other branch: the protection left
--   bypassed (no automatic trip: a SCRAM by hand), Dana woken, she starts the
--   makeup herself, the weld late. Default: by the book.
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
local function step(sr, id, tmo) local ok = until_(sr, function() return done(id) end, tmo or 60, id); SP.check("step_" .. id, ok, "%s latched", id); return ok end

function SOLVE(SP)
  local sr = SP.run_()
  local RP, ST, RU, inv = findScript("reactor_plant"), findScript("structures"), findScript("ruins"), findScript("inventory")
  local alt = tostring(params.branch or "") == "alt"
  P("GS branch %s", alt and "ALT (protection bypassed, Dana woken)" or "MAIN (by the book)")
  POLICY = { ["Questions before"] = alt and 1 or 2, ["Which one"] = 1, ["wake her"] = alt and 1 or 2 }
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
