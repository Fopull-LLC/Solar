-- DUST SEASON: the probe's solution (tools/perf/scnprobe.sh <engine> dust_season).
-- Spliced after scnprobe_modes.lua. Plays the storm the way a player does:
-- the console's terminal (openAt, its pages, its keys as press() presses
-- them), the breakers and heaters through it, the airlock and the walk round
-- to the north door, the seal's repair as its menu job ends, and time warp
-- through the front and Beck's drive. Takes the pictures of every act.
--   Default: GOLD. Shed the shop (B-3 open), keep HTR-1, re-seat the seal.
--   BENCH_STRS='("branch", "ride")': RIDE THE BATTERY. Shed nothing; when
--   B-3 trips on the shop's fourth heater, tape it (its dial up) and the flex
--   burns; then the heater off, the dial down, the splice. The seal left
--   blown (the store sealed off). Beck as the battery allows.
local HAB, SHOP, FIELD = "Tarrant Flats", "Workshop", "South Field"
local DS = {}
local WARP = 50         -- (time warp through the front and the drive: a player would use the chip)
local function sidOf(name) return (save.get("scn.structs") or {})[name] end
local function srec(name)
  local ST = findScript("structures")
  local sid = sidOf(name or HAB)
  return sid and ST.get(sid), sid
end
-- a point in a structure's own frame, placed against this frame's body
local function sl(name, lx, ly, lz)
  local ST = findScript("structures")
  local r = srec(name)
  if not r then return nil end
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r)
  local b = space.body(r.b)
  return { x = b.x + r.x + rx * lx + ux * ly + fx * lz, y = b.y + r.y + ry * lx + uy * ly + fy * lz, z = b.z + r.z + rz * lx + uz * ly + fz * lz }
end
function lateUpdate(node, dt)
  local c = DS.cam
  if not (c or DS.camw) then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt
  if DS.camw then eye, tgt = DS.camw() else eye, tgt = sl(c.s, c[1], c[2], c[3]), sl(c.s, c[4], c[5], c[6]) end
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
local function free_off() local pc = findScript("planet_camera"); if pc and pc.setFreecam then pc.setFreecam(false) end end
local function view(nm, e, t, ui, s)
  DS.cam = { e[1], e[2], e[3], t[1], t[2], t[3], s = s or HAB }
  wait(1.4)
  SP.shot(nm, ui == true)
  DS.cam = nil
  free_off()
  wait(0.3)
end

-- the dialogue: lines clicked through, choices by policy
local POLICY = {}
local function talk(sr, hold)
  -- (room_air's DEPRESSURISATION for the store, whenever it is raised)
  if not DS.alarm then
    local RAa = findScript("room_air")
    local la = RAa and RAa.lastAlarm
    if la and la.kind == "depress" and tostring(la.cause):find("BLOWN", 1, true) then DS.alarm = la; P("DS ALARM %s", tostring(la.cause)) end
  end
  local st = sr.state()
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    local pick = nil
    for k, v in pairs(POLICY) do if p:find(k, 1, true) then pick = v end end
    if pick then
      P("DS CHOICE %q → %d (%s)", p, pick, tostring(st.choice.options and st.choice.options[pick]))
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
  P("DS TIMEOUT %s", tostring(what))
  SP.readings("timeout " .. tostring(what))
  return false
end
local function done(id) return (save.get("scn.done") or {})[id] ~= nil end
local function step(sr, id, tmo) local ok = until_(sr, function() return done(id) end, tmo or 60, id); SP.check("step_" .. id, ok, "%s latched", id); return ok end
local function apart(sr, a, b)
  local p, q = sr.posOf(a), sr.posOf(b)
  if not (p and q and p.body == q.body) then return nil end
  local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
  local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
  local du = (dx * q.x + dy * q.y + dz * q.z) / l
  return math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz - du * du))
end
-- over the player's shoulder at member `who`, re-placed every frame
local function over_shoulder(sr, nm, who, me)
  DS.camw = function()
    local a, q = sr.posOf(me or "crew:Szabo"), sr.posOf(who)
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
  DS.camw = nil
  free_off()
end

-- (storypolish) BENCH_STRS='("branch", "arrive")': straight to act 4 (the
-- earlier acts latched, their events marked fired, the storm past), then
-- Beck's drive home under warp and his arrival played out at 1x: pictures of
-- every shot, his rover's track, his walk through the lock (no set-downs).
function DS.arrive(sr)
  local t0w = W()
  until_(sr, function() return sr.state().phase == "running" end, 60, "running")
  if sr.state().cutscene then sr.skipCutscene() end
  local fired = save.get("scn.ev") or {}
  local t = findScript("deployables").agencyClock()
  for i, ev in ipairs(sr.scenario().events or {}) do
    local key = ev.id or ("ev" .. i)
    if not tostring(key):match("^beck") then fired[key] = t end
  end
  save.set("scn.ev", fired)
  for k, v in pairs({ handover = true, plan = "shop", shed_ok = true, storm = true, front_passed = true, seal_choice = "off", seal_blown = true }) do sr.setVar(k, v) end
  sr.runBeat({ weather = { kind = "dust", secs = 5 } })
  sr.runBeat({ light = { time = -9, secs = 3 } })
  sr.gotoStep("home")
  SP.stand("mark:beckops", 30)
  until_(sr, function() return sr.state().stepId == "home" end, 30, "act 4")
  sr.setVar("beck_km", 1.95); sr.setVar("beck_driving", true)
  SP.check("arrive_act4", sr.state().stepId == "home", "act 4 open after %.0f s", W() - t0w)
  -- the drive under warp, to the staging (2 km) and the arrival
  until_(sr, function() return sr.var("rover_staged") == true end, 120, "the rover staged")
  space.warp(1)
  local okR = until_(sr, function() local p = sr.posOf("craft:Tarrant Rover"); return p ~= nil end, 60, "the rover rebuilt")
  local d0 = apart(sr, "craft:Tarrant Rover", "mark:roverfar") or -1
  until_(sr, function() local C = findScript("crew"); local id = sr.who_id and sr.who_id("Oyelaran"); return id and C.craftOf and C.craftOf(id) ~= nil end, 30, "Beck aboard")
  local C = findScript("crew")
  local bid = sr.who_id and sr.who_id("Oyelaran")
  SP.check("rover_staged", okR and d0 >= 0 and d0 < 12 and bid ~= nil and C.craftOf(bid) ~= nil, "the rover %.1f m from its mark, Beck aboard %s", d0, tostring(bid and C.craftOf(bid) ~= nil))
  view("a4_rover_waiting_far", { -14, 3.2, 9 }, { -26, 0.5, 62 }, false)
  -- (the last of the drive: two hundred metres of it, the model's own pace)
  sr.setVar("beck_km", 0.2); sr.setVar("beck_driving", true)
  space.warp(4)
  local lastP = W()
  until_(sr, function()
    if W() - lastP > 5 then
      lastP = W()
      local mp = sr.worldAdapter and sr.worldAdapter.piece and sr.worldAdapter.piece({ struct = "Mast", uid = 1 })
      P("DS DRIVE beck_km %s driving %s dark %s parked %s home %s mast %s", tostring(sr.var("beck_km")), tostring(sr.var("beck_driving")),
        tostring(sr.var("beck_dark")), tostring(sr.var("beck_parked")), tostring(sr.var("beck_home")), tostring(mp and mp.running))
    end
    return sr.state().cutscene end, 200, "Beck's arrival")
  space.warp(1)
  DS.watch_arrival(sr)
  step(sr, "home", 60)
  until_(sr, function() return sr.state().cutscene end, 30, "the morning")
  wait(4); SP.shot("a4_morning", true)
  step(sr, "morning", 200)
  until_(sr, function() return not sr.state().line end, 40, "the last line")
  wait(2); SP.shot("a4_debrief", true)
end
-- the arrival cutscene, at 1x: lines run by themselves (hold), pictures by
-- what is said; the rover's track and Beck's steps sampled every frame
function DS.watch_arrival(sr)
  local C = findScript("crew")
  local bid = sr.who_id and sr.who_id("Oyelaran")
  local track, maxstep, last, lastBeck, beckMax = {}, 0, nil, nil, 0
  local lastW, lastBW = W(), W()
  local function sample()
    local p = sr.posOf("craft:Tarrant Rover")
    if p then
      -- (as a speed over the real time between samples: a picture holds frames)
      local dw = math.max(0.016, W() - lastW)
      if last and last.body == p.body then local s = math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 + (p.z - last.z) ^ 2) / dw; if s > maxstep then maxstep = s end end
      last, lastW = p, W()
    end
    local q = sr.posOf("crew:Oyelaran")
    local C2 = findScript("crew")
    local afoot = bid and C2.get(bid) and C2.get(bid).status == "afoot"
    -- (the first moments afoot are the climb down from the seat: not a walk)
    if afoot and not DS.afoot_t then DS.afoot_t = W() end
    if q and afoot and W() - DS.afoot_t > 1.5 then
      -- (over half a second or more: a member's record, which posOf reads,
      -- follows the body twice a second while it walks)
      local dw = math.max(0.016, W() - lastBW)
      if not (dw < 0.6 and lastBeck) then
        if lastBeck and lastBeck.body == q.body then local s = math.sqrt((q.x - lastBeck.x) ^ 2 + (q.y - lastBeck.y) ^ 2 + (q.z - lastBeck.z) ^ 2) / dw; if s > beckMax then beckMax = s end end
        lastBeck, lastBW = q, W()
      end
    else lastBeck = nil end
  end
  local diag_t = W()
  local function diag()
    if W() - diag_t < 1.0 then return end
    diag_t = W()
    local rd = sr.SC5R and sr.SC5R.read and sr.SC5R.read("Tarrant Rover")
    local n = rd and rd.npc or {}
    P("DS ROVER way %.1f park %.1f speed %.2f charge %.0f npc %s dist %s v* %s stuck %s why %s · beck lock %.1f door %.1f status %s",
      apart(sr, "craft:Tarrant Rover", "mark:roverway") or -1, apart(sr, "craft:Tarrant Rover", "mark:beckpark") or -1, rd and rd.speed or -1, rd and rd.charge or -1,
      tostring(n.active), tostring(n.dist), tostring(n.vstar), tostring(n.stuck), tostring(n.why),
      apart(sr, "crew:Oyelaran", "mark:lockout") or -1, apart(sr, "crew:Oyelaran", "mark:lockdoor") or -1,
      tostring(bid and C.get(bid) and C.get(bid).status))
  end
  local function line_has(s) local st = sr.state(); return st.line and tostring(st.line.text):find(s, 1, true) ~= nil end
  local function upto(cond, tmo, what) return until_(sr, function() sample(); diag(); return cond() end, tmo, what, true) end
  local ta = W()
  upto(function() return W() - ta > 4.0 end, 6, "lights")
  SP.shot("a4_arrive_1_lights_in_dust", true)
  upto(function() return line_has("Prettiest thing") end, 25, "Beck on the radio")
  wait(1.0); SP.shot("a4_arrive_2_radio", true)
  upto(function() return line_has("Last hundred metres") end, 40, "the last hundred metres")
  wait(1.5); SP.shot("a4_arrive_3_alongside", true)
  upto(function() local d = apart(sr, "craft:Tarrant Rover", "mark:beckpark"); return d and d < 12 end, 40, "near the lock")
  SP.shot("a4_arrive_4_pulling_up", true)
  local tp = W()
  upto(function() local C2 = findScript("crew"); local r = bid and C2.get(bid); return r and r.status == "afoot" end, 45, "Beck climbs down")
  local dpark = apart(sr, "craft:Tarrant Rover", "mark:beckpark") or -1
  SP.check("rover_parked", dpark >= 0 and dpark < 6, "the rover drove in and parked %.1f m from its mark (%.0f s after pulling up)", dpark, W() - tp)
  wait(2.0); SP.shot("a4_arrive_5_climbs_down", true)
  upto(function() local d = apart(sr, "crew:Oyelaran", "mark:lockout"); return d and d < 2.0 end, 45, "Beck at the lock")
  SP.shot("a4_arrive_6_at_the_lock", true)
  local tl = W()
  upto(function() return line_has("gone amber") end, 30, "inside, the wait")
  wait(1.0); SP.shot("a4_arrive_7_waiting_inside", true)
  upto(function() local d = apart(sr, "crew:Oyelaran", "mark:lockdoor"); return d and d < 1.5 end, 90, "Beck through the lock")
  local through = W() - tl
  wait(0.8); SP.shot("a4_arrive_8_through_the_door", true)
  upto(function() return line_has("You look terrible") end, 30, "face to face")
  local dbw = apart(sr, "crew:Oyelaran", "crew:Achterberg") or -1
  wait(1.5); SP.shot("a4_arrive_9_face_to_face", true)
  SP.check("beck_walked_in", through > 3 and beckMax < 4.0, "Beck through the lock in %.0f s, his fastest %.2f m/s (walked, never set down); Wren %.2f m from him", through, beckMax, dbw)
  SP.check("rover_drove", maxstep < 12.0, "the rover's fastest %.2f m/s (driven, never placed)", maxstep)
  upto(function() return line_has("Mast's still lit") end, 50, "the mast")
  wait(1.0); SP.shot("a4_arrive_10_mast_still_lit", true)
  until_(sr, function() return not sr.state().cutscene end, 40, "arrival ends", true)
  SP.check("arrival_done", sr.var("act4") == true and sr.var("beck_in") == true, "act4 %s beck_in %s", tostring(sr.var("act4")), tostring(sr.var("beck_in")))
end

function SOLVE(SP)
  local sr = SP.run_()
  if tostring(params.branch or "") == "arrive" then return DS.arrive(sr) end
  local ST, BG, BP, KL, T, RA, CB, BT = findScript("structures"), findScript("base_grid"), findScript("base_power"), findScript("kit_live"),
    findScript("terminal"), findScript("room_air"), findScript("base_cable"), findScript("base_tower")
  local ride = tostring(params.branch or "") == "ride"
  P("DS branch %s", ride and "RIDE (shed nothing, B-3 taped, the seal left)" or "GOLD (shed the shop, keep HTR-1, re-seat the seal)")
  POLICY = { ["What do we shed"] = ride and 3 or 2, ["What do we do"] = ride and 1 or 2 }
  local hsid, ssid = sidOf(HAB), sidOf(SHOP)
  SP.check("structures", hsid ~= nil and ssid ~= nil and sidOf(FIELD) ~= nil and sidOf("Mast") ~= nil, "the hab #%s, the shop #%s, the field #%s, the mast #%s",
    tostring(hsid), tostring(ssid), tostring(sidOf(FIELD)), tostring(sidOf("Mast")))
  -- the grid as staged: one grid holding all four, the shop on the run
  local g = BG.gridOfStruct(hsid)
  local gs = BG.gridOfStruct(ssid)
  local cab = CB.list and CB.list() or {}
  SP.check("grid", g ~= nil and g == gs and #cab == 1 and cab[1].ty == "lv2", "one grid (%s) with the shop on the run (%d cable, %s, %.0f m)",
    tostring(g and g.id), #cab, tostring(cab[1] and cab[1].ty), cab[1] and cab[1].len or -1)
  local function gline(tag)
    local s = g and BG.status(g.id)
    local M = g and BG.model(g.id)
    local f = BP.breakerState(hsid, 150)
    local fl = cab[1] and BG.cableFlow(cab[1].id) or {}
    local pf = BG.partFlow(hsid, 150) or {}
    local si = BG.soilInfo(sidOf(FIELD), 1)
    P("DS GRID %s: supply %.2f kW need %.2f kW battery %.3f · B-3 %s %.2f/%.2f kW (Ir %s) · run %.2f kW %s · panel1 k %.2f dust %.2f sky %.2f · grow %.1f °C · beck %.2f km dark %s · agency %.0f",
      tag, s and s.supply or -1, M and M.need or -1, (s and M and M.C > 0) and s.stored / M.C or -1, tostring(f), pf.kW or -1, pf.rating or -1, tostring(pf.ir),
      fl.P or -1, fl.dead and ("DEAD " .. tostring(fl.why)) or "", si.k, si.dust, si.sky, sr.var("grow_c") or -99, sr.var("beck_km") or -1,
      tostring(sr.var("beck_dark")), findScript("deployables").agencyClock())
    -- the hab's rooms: pressure, O2, CO2, breathable
    local RAx = findScript("room_air")
    local R = RAx and RAx.roomsOf and RAx.roomsOf(hsid)
    local parts = {}
    for _, r in ipairs(R and R.rooms or {}) do
      local a = RAx.airOf(hsid, r.id)
      if a then parts[#parts + 1] = string.format("%d%s %.0fm3 p%.2f o2 %.2f co2 %.3f %s", r.id, r.airlock and "L" or (r.sealed and "" or "~"), r.m3 or 0,
        a.p or -1, a.o2 or -1, a.co2 or -1, a.breathable and "ok" or tostring(a.why)) end
    end
    P("DS AIR %s: %s", tag, table.concat(parts, " | "))
  end
  gline("staged")
  local s0 = BG.status(g.id); local M0 = BG.model(g.id)
  SP.check("battery_71", s0 and M0 and math.abs(s0.stored / M0.C - 0.71) < 0.02, "the banks staged at %.1f %%", (s0 and M0) and 100 * s0.stored / M0.C or -1)
  SP.check("b3_dial", math.abs((BP.breakerIr(hsid, 150) or 1) - 0.4) < 1e-6, "B-3's dial at Ir %.2f", BP.breakerIr(hsid, 150) or -1)

  -- ── ACT 1 ──
  if sr.state().cutscene then
    wait(2.5); SP.shot("a0_arrival_flyin", true)
    wait(6.0); SP.shot("a0_arrival_field", true)
    until_(sr, function() return not sr.state().cutscene end, 40, "arrival ends")
  end
  wait(0.5)
  local d0 = apart(sr, "crew:Achterberg", "crew:Szabo") or -1
  local came = until_(sr, function() local d = apart(sr, "crew:Achterberg", "crew:Szabo"); return d and d < 1.9 end, 60, "Wren walks up")
  local d1 = apart(sr, "crew:Achterberg", "crew:Szabo") or -1
  SP.check("wren_walks_up", came and d1 > 0.8, "Wren from %.2f m to %.2f m, face to face", d0, d1)
  until_(sr, function() local st = sr.state(); return st.line and st.line.who == "wren" end, 15, "Wren speaks", true)
  over_shoulder(sr, "a1_wren_face_to_face", "crew:Achterberg")
  SP.shot("a1_handover_dialogue", true)
  -- (the plan's question held on screen for its picture, then answered)
  local pick = POLICY["What do we shed"]
  POLICY["What do we shed"] = nil
  until_(sr, function() local st = sr.state(); return st.choice ~= nil end, 90, "the plan's question", false)
  wait(0.6); SP.shot("a1_plan_choice", true)
  POLICY["What do we shed"] = pick
  step(sr, "handover", 60)
  SP.floor_check("ops_room")     -- (scnfix2) Wren and the rest stand on the hab's floor, not in it
  -- the console: its LOG page, then its POWER page; the plan done by its keys
  SP.stand("mark:console", 30)
  local ok = T.openAt(hsid, 109, "LOG")
  SP.check("terminal_open", ok ~= false and T.isOpen(), "the ops console's terminal opens (%s)", tostring(ok))
  until_(sr, function() return sr.var("read_log") end, 10, "the log")
  wait(1.0); SP.shot("a1_terminal_log", true)
  until_(sr, function() return not sr.state().line end, 60, "log read")
  T.page("POWER")
  wait(1.0)
  if not ride then
    -- B-3 open by the POWER page's key, as a player presses it
    local pr = T.press("br_" .. hsid .. "_150")
    wait(0.5)
    SP.check("b3_open", BP.breakerState(hsid, 150) == "open", "B-3 opened from the POWER page (%s): %s", tostring(pr), BP.breakerState(hsid, 150))
  end
  wait(1.0); SP.shot("a1_terminal_power", true)
  step(sr, "shed", 20)
  step(sr, "power", 20)
  gline("planned")
  T.close()
  -- the front: its cutscene
  until_(sr, function() return sr.state().cutscene end, 60, "the front")
  wait(3.0); SP.shot("a1_front_hits", true)
  wait(5.0); SP.shot("a1_front_field", true)
  until_(sr, function() return not sr.state().cutscene end, 40, "front ends")
  wait(5)
  gline("front +5 s")
  view("a1_storm_base_from_field", { -8, 2.2, -36 }, { 0, 1.5, 0 }, false)
  view("a1_storm_field", { 9, 2.0, -26 }, { -2, 1.0, -36 }, false)
  view("a1_grow_room", { 1.7, 1.6, 2.4 }, { 5.0, 0.9, -2.0 }, false)
  view("a1_ops_room", { 0.4, 1.7, -2.0 }, { -4.0, 1.0, 2.2 }, false)

  -- ── ACT 2: the ledger ──
  until_(sr, function() return sr.state().stepId == "hold" end, 60, "the hold opens")
  T.openAt(hsid, 109, "POWER")
  -- the POWER page in the storm, once the lines are done (a picture)
  until_(sr, function() return not sr.state().line end, 40, "the ledger's lines")
  space.warp(10)
  wait(4.0)
  space.warp(1)
  wait(0.8); SP.shot("a2_power_page_storm", true)
  local tapedAt, burnt, handled = nil, false, false
  space.warp(WARP)
  local t0, lastP = W(), -99
  while not done("hold") and W() - t0 < 400 do
    talk(sr)
    if W() - lastP > 15 then gline(string.format("hold +%.0f s", W() - t0)); lastP = W() end
    if ride then
      -- B-3 trips on the fourth heater: tape it (the dial up), once
      if not tapedAt and BP.breakerState(hsid, 150) == "tripped" then
        space.warp(1)
        wait(1.0); SP.shot("a2_b3_tripped_power_page", true)
        SP.check("b3_trips", (sr.var("b3_trips") or 0) >= 1, "B-3 tripped on the shop's fourth heater (%s trips)", tostring(sr.var("b3_trips")))
        BP.setBreakerIr(hsid, 150, 1.0, "hand")
        BP.setBreaker(hsid, 150, true, "hand")
        tapedAt = W()
        space.warp(WARP)
      end
      if tapedAt and not burnt and sr.var("burnt") then
        burnt = true
        space.warp(1)
        until_(sr, function() return not sr.state().cutscene end, 30, "the burn's cutscene")
        wait(0.5); SP.shot("a2_flex_burnt", true)
        SP.check("flex_burnt", true, "taped, the flex burnt through")
        -- the load off it, the dial back down, the splice (at B-3's end)
        T.press("ht_" .. ssid .. "_26")
        wait(0.3)
        BP.setBreakerIr(hsid, 150, 0.4, "hand")
        local okS, w = CB.splice(cab[1].id)
        SP.check("spliced", okS == true, "the run spliced (%s)", tostring(w))
        wait(1.0)
        space.warp(WARP)
      end
    end
    if sr.var("front_passed") then break end
    yield()
  end
  space.warp(1)
  gline("front past")
  step(sr, "hold", 30)
  if ride then
    SP.check("ride_burn_path", tapedAt ~= nil and burnt and sr.var("spliced") == true, "tape → burn → splice (taped %s, burnt %s, spliced %s)",
      tostring(tapedAt ~= nil), tostring(burnt), tostring(sr.var("spliced")))
  else
    SP.check("gold_hold", (sr.var("batt_min") or 0) >= 0.2 and sr.var("trial_lost") ~= true, "through the front: battery never under %.0f %%, grow room %.1f °C at its coldest",
      100 * (sr.var("batt_min") or 0), sr.var("grow_min") or -99)
  end
  T.close()

  -- ── ACT 3: the seal ──
  until_(sr, function() return sr.state().cutscene end, 90, "the seal")
  -- room_air's alarm for the store, naming the blown seal (polled: a later
  -- "air" notice may replace lastAlarm)
  local al = nil
  local t2 = W()
  while W() - t2 < 20 and not al do
    local la = RA.lastAlarm
    if la and la.kind == "depress" and tostring(la.cause):find("BLOWN", 1, true) then al = la end
    for _, a in pairs((RA.alarms and RA.alarms()) or {}) do
      if type(a) == "table" and a.kind == "depress" and tostring(a.cause):find("BLOWN", 1, true) then al = a end
    end
    if W() - t2 > 1.5 and not DS.sealShot then DS.sealShot = true; SP.shot("a3_seal_blows", true) end
    yield()
  end
  DS.alarm = DS.alarm or al
  until_(sr, function() return not sr.state().cutscene end, 40, "seal ends")
  step(sr, "gusts", 60)
  if ride then
    until_(sr, function() return DS.alarm ~= nil end, 90, "the store's alarm")
    SP.check("depress_alarm", DS.alarm ~= nil, "room_air's DEPRESSURISATION named the door: %s", tostring(DS.alarm and DS.alarm.cause))
    until_(sr, function() return sr.state().stepId == "home" end, 30, "the store left sealed off: on to act 4")
  end
  if not ride then
    -- helmet on, out the airlock, round to the north door, the repair's job
    local su = findScript("suit")
    if su and su.setHelmet then pcall(su.setHelmet, true) end
    SP.stand("mark:lockout", 40)
    wait(1.0); SP.shot("a3_outside_storm", true)
    SP.stand("mark:northdoor", 40)
    wait(1.0); SP.shot("a3_north_door", true)
    view("a3_north_door_wide", { 4.6, 1.8, 9.5 }, { 1.6, 1.0, 5.0 }, false)
    -- lock it (the store is empty: it opens for whoever walks up), then the repair's job
    local okL, whyL = KL.setDoorHold(hsid, 96, "lock", "hand")
    SP.check("door_locked", okL ~= false, "the north door locked by hand (%s)", tostring(whyL))
    wait(1.5)
    RA.repairSeal(hsid, 96)
    wait(0.5)
    KL.setDoorHold(hsid, 96, nil, "hand")
    step(sr, "seal", 30)
    SP.check("depress_alarm", DS.alarm ~= nil, "room_air's DEPRESSURISATION named the door: %s", tostring(DS.alarm and DS.alarm.cause))
    -- back in the way a player comes in: into the chamber from outside, and
    -- the lock cycles (the purge: the outside's CO2 pumped overboard first)
    SP.stand("mark:lockout", 30)
    wait(2.0)
    local t3 = W()
    while W() - t3 < 70 do
      SP.stand("mark:lockin", 4)
      local C = nil
      local RAs = RA.state and RA.state(hsid)
      if RAs and RAs.cham then for _, c in pairs(RAs.cham) do C = c end end
      if C and not C.cyc and W() - t3 > 8 then break end
      yield()
    end
    P("DS LOCK last cycle message: %s", tostring(RA.lastCycle))
    SP.stand("mark:beckops", 60)
    wait(6.0)
    gline("came in through the lock")
    local worst = 0
    local R = RA.roomsOf and RA.roomsOf(hsid)
    for _, r in ipairs(R and R.rooms or {}) do
      if r.sealed and not r.airlock and (r.m3 or 0) > 40 then local a = RA.airOf(hsid, r.id); if a and a.co2 > worst then worst = a.co2 end end
    end
    SP.check("lock_purged", worst < 0.02, "in through the airlock on a CO2 world: the worst big room holds %.4f atm of CO2 (≤ 0.02 breathable)", worst)
    if su and su.setHelmet then pcall(su.setHelmet, false) end
  end

  -- ── ACT 4: the mast light ──
  until_(sr, function() return done("home") or sr.state().phase == "running" and sr.state().stepId == "home" end, 30, "act 4")
  if not ride then
    -- (G4) the field caked by the front: three panels wiped by the menu's job
    local fsid = sidOf(FIELD)
    local su = findScript("suit")
    if su and su.setHelmet then pcall(su.setHelmet, true) end
    SP.stand("mark:panel", 40)
    local before = BG.soilInfo(fsid, 1)
    local rows = BG.soilProviderFn and BG.soilProviderFn({ node = ST.nodeOf(fsid, 1) }, {}) or {}
    local wrow = nil
    for _, r in ipairs(rows) do if r.id == "sg_wipe" then wrow = r end end
    SP.check("wipe_row", wrow ~= nil and wrow.enabled() == true, "the array's menu: Wipe the panel (%s s), open to Imre", tostring(wrow and wrow.job and wrow.job.secs))
    wait(1.0); SP.shot("a4_wiping_the_field", true)
    for _, u in ipairs({ 1, 2, 3 }) do
      local rs = BG.soilProviderFn({ node = ST.nodeOf(fsid, u) }, {})
      for _, r in ipairs(rs or {}) do if r.id == "sg_wipe" then r.job.done() end end
    end
    wait(2.5)
    local after = BG.soilInfo(fsid, 1)
    SP.check("wiped", after.dust == 0 and after.k > before.k, "panel 1 wiped: dust %.2f → %.2f, its share %.2f → %.2f", before.dust, after.dust, before.k, after.k)
    gline("wiped three")
    SP.stand("mark:beckops", 40)
    if su and su.setHelmet then pcall(su.setHelmet, false) end
  end
  space.warp(WARP)
  local t1 = W()
  local lastQ = -99
  while not sr.var("act4") and W() - t1 < 400 do
    talk(sr)
    if W() - lastQ > 15 then gline(string.format("drive +%.0f s", W() - t1)); lastQ = W() end
    if sr.state().cutscene then break end
    yield()
  end
  space.warp(1)
  if sr.var("beck_home") then
    until_(sr, function() return sr.state().cutscene end, 20, "Beck's arrival")
    DS.watch_arrival(sr)
  end
  step(sr, "home", 60)
  gline("home")
  until_(sr, function() return sr.state().cutscene end, 30, "the morning")
  wait(4); SP.shot("a4_morning", true)
  wait(4); SP.shot("a4_morning_late", true)
  step(sr, "morning", 160)
  until_(sr, function() return not sr.state().line end, 40, "the last line")
  for _, k in ipairs({ "plan", "batt_min", "grow_min", "trial_lost", "b3_trips", "taped", "burnt", "spliced", "seal_choice", "seal_fixed", "beck_home", "beck_parked", "unbreathable_s", "silver_ok" }) do
    P("DS VAR %s = %s", k, tostring(sr.var(k)))
  end
  wait(2); SP.shot("a4_debrief", true)
  -- (what the runner still does once the story is over: its queue, its state's version)
  local q1, c1, b1, f1 = sr.debugQueue()
  local v1 = sr.state().version
  wait(2.0)
  local q2, c2, b2, f2 = sr.debugQueue()
  P("DS AFTER queue %s→%s cam %s busy %s finishing %s · version %s→%s · phase %s", tostring(q1), tostring(q2), tostring(c2), tostring(b2),
    tostring(f2), tostring(v1), tostring(sr.state().version), tostring(sr.phaseNow()))
end
