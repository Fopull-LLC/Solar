-- TERMPROBE (tools/perf/termprobe.sh): the base terminals (work/interact/PLAN.md
-- §4, slices S3 and S4) in the real game, on Graveyard Shift's Kerne Station
-- staged as PLAY stages it.
--
--   scn   first person at the Reactor Control Console: the walk-up prompt, E
--         (simulated) opens the terminal on REACTOR; every page pictured at
--         1080p (REACTOR, POWER and LOG at 1440p too); the keys 1–9 and TAB;
--         a breaker added to the station tripped (trip test), refused closing
--         into its trip, reset; MU-1 shut and opened again; SCRAM; the
--         airlock cycled to its outer door; a door locked and unlocked; the
--         LOG page read back for each; Esc leaves (and the pause menu stays
--         shut); the desk monitor (the log desk) as a base terminal; the cost
--         of an open page (terminal.PROF) and of the closed prompt check.
--
-- Lines: `TP PASS|FAIL <check>`, `TP SHOT`, `TP COST`, `TP RESULT`.
-- Pictures: save/user/termshots/.
defaults = { quit = 1, case = "scn" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("TP %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "scn"
local NODE, CO
local fails, passes = 0, 0
local function yield() coroutine.yield() end
local function frames(n) for _ = 1, n do yield() end end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local function check(name, ok, fmt, ...)
  P("%s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if ok then passes = passes + 1 else fails = fails + 1 end
  return ok
end
local pending = 0
local function shot(nm, big)
  local sizes = big and { { 1920, 1080 }, { 2560, 1440 } } or { { 1920, 1080 } }
  for _, sz in ipairs(sizes) do
    pending = pending + 1
    local name = string.format("%s_%d", nm, sz[2])
    local ok = pcall(camera.capture, { w = sz[1], h = sz[2], ui = true, draws = true }, function(bytes, why)
      pending = pending - 1
      if bytes then assets.writeBytes("user://termshots/" .. name .. ".png", bytes); P("SHOT %s", name)
      else P("SHOT %s failed: %s", name, tostring(why)) end
    end)
    if not ok then pending = pending - 1 end
  end
  wait_for(function() return pending == 0 end, 10, "shot " .. nm)
end
local function astro() return find("Astronaut") end
local function TM() return findScript("terminal") end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function clear_weather()
  local wx = findScript("weather")
  if wx and wx.force then pcall(wx.force, "clear") end
end
local function up_of(a)
  local name = space.dominant(a.worldX, a.worldY, a.worldZ)
  local b = name and space.body(name)
  if not b then return { x = 0, y = 1, z = 0 } end
  local x, y, z = a.worldX - b.x, a.worldY - b.y, a.worldZ - b.z
  local l = len(x, y, z)
  return { x = x / l, y = y / l, z = z / l }
end
-- aim the eyes at `pt()` (this frame's world point), for `secs`
local function aim(pt, secs)
  local pc = findScript("planet_camera")
  pc.firstPerson = true
  local t0 = W()
  repeat
    local a = astro()
    local p = pt()
    if a and p then
      local u = up_of(a)
      local ex, ey, ez = a.worldX + u.x * 0.72, a.worldY + u.y * 0.72, a.worldZ + u.z * 0.72
      local dx, dy, dz = p.x - ex, p.y - ey, p.z - ez
      local du = dx * u.x + dy * u.y + dz * u.z
      local hx, hy, hz = dx - u.x * du, dy - u.y * du, dz - u.z * du
      local hl = len(hx, hy, hz)
      if hl > 1e-4 then pc.face(hx / hl, hy / hl, hz / hl, math.atan2(du, hl)) end
    end
    yield()
  until W() - t0 > (secs or 0.8)
end
local function key(k) input.simulate { key = k, down = true }; frames(2); input.simulate { key = k, down = false }; frames(3) end

-- ── staging (as ixprobe) ────────────────────────────────────────────────────
local S = "Kerne Station"
local POLICY = { ["Questions before"] = 3, ["Which one"] = 1, ["wake her"] = 2 }
local function talk(sr)
  local st = sr.state()
  if st.cutscene then sr.skipCutscene() end
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    local pick = 1
    for k, v in pairs(POLICY) do if p:find(k, 1, true) then pick = v end end
    sr.choose(pick)
  elseif st.line and st.line.t0 and (time - st.line.t0) > 0.5 then
    sr.lineDone()
  end
end
local function stage(id)
  if not find("ScenarioLib") then spawn("ScenarioLib", vec3(0, 0, 0)) end
  local R = wait_for(function() return findScript("scenario") end, 10, "the rulebook")
  local ok, err = R.prepareSlot(id)
  if not check("prepare", ok, "%s in slot %s: %s", id, tostring(save.slot()), tostring(err)) then return nil end
  local t0 = W()
  scene.load("system")
  yield()
  local sr = wait_for(function() local s = findScript("scenario_run"); return s and s.isActive and s.isActive() and s end, 150, "the runner")
  if not sr then check("runner", false, "no runner") return nil end
  local ph = wait_for(function() local p = sr.phaseNow(); return (p == "running" or p == "briefing") and p end, 240, "staged")
  if ph == "briefing" then sr.go() end
  local gm = findScript("game_manager")
  wait_for(function() return gm and not gm.curtain end, 60, "the reveal")
  check("staged", ph ~= nil, "%s staged in %.1f s", id, W() - t0)
  clear_weather()
  wait_for(function() talk(sr); return (save.get("scn.done") or {}).handover ~= nil end, 120, "the handover")
  wait_for(function() talk(sr); local st = sr.state(); return not st.cutscene and not st.line and not st.choice and (gm.inputOwner == nil) end, 40, "control")
  return sr
end
-- stand 1.3 m from piece (sid, uid) on the side away from `from` (a ref), its middle at `h`
local function stand_by(sr, sid, uid, from, dist)
  local ST = findScript("structures")
  local a = astro()
  for _ = 1, 30 do
    local n = ST.nodeOf(sid, uid)
    local m = from and sr.posOf(from)
    if n then
      local w = n.worldPos
      local u = up_of(a)
      local dx, dy, dz
      if m then
        local b = space.body(m.body)
        dx, dy, dz = (b.x + m.x) - w.x, (b.y + m.y) - w.y, (b.z + m.z) - w.z
      else dx, dy, dz = a.worldX - w.x, a.worldY - w.y, a.worldZ - w.z end
      local du = dx * u.x + dy * u.y + dz * u.z
      dx, dy, dz = dx - u.x * du, dy - u.y * du, dz - u.z * du
      local l = math.max(len(dx, dy, dz), 1e-3)
      local k = (dist or 1.3) / l
      a.x, a.y, a.z = w.x + dx * k + u.x * 1.0, w.y + dy * k + u.y * 1.0, w.z + dz * k + u.z * 1.0
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    yield()
  end
end
local function mid(sid, uid, h)
  return function()
    local n = findScript("structures").nodeOf(sid, uid)
    if not n then return nil end
    local w = n.worldPos
    local u = up_of(astro())
    return { x = w.x + u.x * (h or 0.9), y = w.y + u.y * (h or 0.9), z = w.z + u.z * (h or 0.9) }
  end
end
local function rows_by()
  local by = {}
  for _, q in ipairs(TM().rows()) do by[q.id] = q; local tail = tostring(q.id):match("%.([^%.]+)$"); if tail then by[tail] = by[tail] or q end end
  return by
end
local function log_has(sid, pat)
  local BL = findScript("base_log")
  for _, e in ipairs(BL.entries({ sid }, 60)) do if tostring(e.x):find(pat, 1, true) then return BL.lineOf(e) end end
  return nil
end

local function case_scn()
  local sr = stage("graveyard_shift")
  if not sr then return end
  local ST = findScript("structures")
  local csid, cuid = sr.pieceOf({ struct = S, part = "reactorConsole" })
  if not check("console_piece", csid ~= nil, "the station stands (console %s:%s)", tostring(csid), tostring(cuid)) then return end
  local tm = TM()
  local DPc = findScript("deployables"); P("agency clock %s, space.time %s", tostring(DPc and DPc.agencyClock and DPc.agencyClock()), tostring(space.time and space.time()))
  if not check("terminal_script", tm ~= nil, "terminal.lua runs (ContextLib)") then return end
  -- the closed prompt's cost, measured over 3 s of walking around nowhere near
  local t_closed0 = tm.PROF.closed_ms or 0
  local n0 = tm.PROF.closed_n or 0
  wait(3)
  local nc = (tm.PROF.closed_n or 0) - n0
  P("COST closed: %.4f ms per prompt check (%d checks in 3 s, at most 8 Hz)", nc > 0 and ((tm.PROF.closed_ms or 0) - t_closed0) / nc or 0, nc)
  -- walk up: first person, facing it, 1.3 m off (away from Dana's post)
  stand_by(sr, csid, cuid, "mark:console", 1.25)
  aim(mid(csid, cuid, 1.0), 1.2)
  local near = wait_for(function() return tm.near() end, 3, "the prompt")
  check("prompt", near ~= nil and near.sid == csid and near.uid == cuid, "the walk-up prompt names the console (%s)", tostring(near and near.kind))
  shot("tm_00_prompt")
  key("e")
  wait_for(function() return tm.isOpen() end, 3, "the terminal")
  if not check("e_opens", tm.isOpen() and tm.state().page == "REACTOR", "E opens the terminal on REACTOR (%s)", tostring(tm.state() and tm.state().page)) then
    tm.openAt(csid, cuid)
  end
  wait(1.2)
  shot("tm_01_reactor", true)
  -- the keys: 1–9 and TAB
  key("4")
  check("key_4", tm.state().page == "POWER", "key 4 → %s", tostring(tm.state().page))
  key("tab")
  check("key_tab", tm.state().page == "FLUIDS", "TAB → %s", tostring(tm.state().page))
  -- every page, pictured
  for i, p in ipairs(tm.pagesFor("reactor")) do
    tm.page(p.id)
    wait(0.6)
    shot(string.format("tm_%02d_%s", 2 + i, p.id:lower()), p.id == "POWER" or p.id == "LOG")
  end
  -- POWER: a breaker added to the station: trip test, refused closing, reset
  local rec = ST.get(csid)
  local cp = ST.getPart(csid, cuid)
  local bu = ST.addPart(csid, { id = "breaker63.steel", x = (cp.x or 0) + 1.6, y = 1.2, z = (cp.z or 0) - 0.6, yaw = 0, pitch = 0, roll = 0 })
  wait(1.0)
  tm.page("POWER")
  wait(0.4)
  local bid = "br_" .. csid .. "_" .. bu
  local by = rows_by()
  check("breaker_row", by[bid] ~= nil, "the new breaker is on POWER (%s)", bid)
  local BP = findScript("base_power")
  local okt, wt = tm.press("brt_" .. csid .. "_" .. bu)
  check("trip_test", okt and BP.breakerState(csid, bu) == "tripped", "trip test from the console: %s (%s)", BP.breakerState(csid, bu), tostring(wt))
  wait(1.2)
  local okc, whyc = tm.press(bid)
  check("no_close_into_trip", okc == false and tostring(whyc):find("Reset", 1, true) ~= nil, "closing into the trip refused: %s", tostring(whyc))
  wait(0.5)
  shot("tm_20_power_tripped")
  local okr = tm.press("brr_" .. csid .. "_" .. bu)
  check("reset", okr and BP.breakerState(csid, bu) == "closed", "reset from the console: %s", BP.breakerState(csid, bu))
  check("log_trip", log_has(csid, "TRIP") ~= nil, "the trip is in the log: %s", tostring(log_has(csid, "TRIP")))
  -- FLUIDS: MU-1 shut, opened
  local s1, u1 = sr.pieceOf({ struct = S, uid = 114 })
  local FN = findScript("fluid_net")
  tm.page("FLUIDS")
  wait(0.4)
  local fid = "fl_" .. s1 .. "_" .. u1
  local okv, wv = tm.press(fid)
  check("valve_shut", okv and not FN.isOn(s1, u1), "MU-1 shut from the console (%s)", tostring(wv))
  wait(0.8)
  shot("tm_21_fluids_mu1_shut")
  local okv2 = tm.press(fid)
  check("valve_open", okv2 and FN.isOn(s1, u1), "MU-1 opened again")
  local mu1 = findScript("part_info").designate(s1, u1)
  check("log_valve", log_has(s1, mu1 .. " shut") ~= nil, "logged: %s", tostring(log_has(s1, mu1 .. " shut")))
  -- DOORS: lock a door, unlock; cycle the airlock
  tm.page("DOORS")
  wait(0.4)
  local KL, RA = findScript("kit_live"), findScript("room_air")
  local lockd, cyc = nil, nil
  for _, q in ipairs(tm.rows()) do
    local id = tostring(q.id)
    if not lockd and id:find("dl_", 1, true) then lockd = id end
    if not cyc and id:find("dc_", 1, true) then cyc = id end
  end
  if lockd then
    local ds, du = lockd:match("dl_(%d+)_(%d+)")
    tm.press(lockd)
    check("door_lock", KL.doorHold(tonumber(ds), tonumber(du)) == "lock", "a door locked from the console (%s)", lockd)
    wait(0.5)
    shot("tm_22_doors_locked")
    tm.press(lockd)
    check("door_unlock", KL.doorHold(tonumber(ds), tonumber(du)) == nil, "…and unlocked")
  else check("door_lock", false, "no door on DOORS") end
  if cyc then
    local cs, cu = cyc:match("dc_(%d+)_(%d+)")
    cs, cu = tonumber(cs), tonumber(cu)
    local okc2, wc = tm.press(cyc)
    local opened = wait_for(function() local o = KL.doorOpen(cs, cu); return o and o > 0.99 end, 45, "the airlock to cycle")
    check("airlock_cycle", okc2 and opened ~= nil, "the airlock cycled to %s from the console (%s); open %s", cyc, tostring(wc), tostring(KL.doorOpen(cs, cu)))
    check("log_cycle", log_has(cs, "airlock cycled") ~= nil, "logged")
  else check("airlock_cycle", false, "no airlock door on DOORS") end
  -- REACTOR: SCRAM
  tm.page("REACTOR")
  wait(0.5)
  local RP = findScript("reactor_plant")
  local e = RP.plantOfPart(csid, cuid)
  local okS = tm.press("rx_scram")
  wait(2.5)
  check("scram", okS and e and e.S.scram, "SCRAM from the desk: tripped %s", tostring(e and e.S.scram))
  shot("tm_23_reactor_scrammed", true)
  check("log_scram", log_has(csid, "SCRAM by hand") ~= nil, "logged: %s", tostring(log_has(csid, "SCRAM by hand")))
  -- protection bypass: said, never refused; then restored (Graveyard starts
  -- with it bypassed: Dana's item 2 — restore it first, then bypass it)
  if e.S.prot == false then
    local okr0, wr0 = tm.press("rx_prot")
    check("restore", okr0 and e.S.prot ~= false, "protection restored from the desk (%s)", tostring(wr0))
    wait(0.3)
  end
  local okp, wp = tm.press("rx_prot")
  check("bypass", okp and e.S.prot == false and tostring(wp):find("meltdown", 1, true) ~= nil, "protection bypassed, the warning said: %s", tostring(wp))
  wait(0.6)
  shot("tm_24_reactor_bypassed")
  tm.press("rx_prot")
  P("agency clock %s, space.time %s", tostring(DPc and DPc.agencyClock and DPc.agencyClock()), tostring(space.time and space.time()))
  -- the LOG page reads it all
  tm.page("LOG")
  wait(0.6)
  local lines = {}
  local reg = findScript("context_registry")
  for _, q in ipairs(tm.rows()) do if q.type == "line" then lines[#lines + 1] = tostring(reg.live(q.text)) end end
  local all = table.concat(lines, " | ")
  check("log_page", all:find("SCRAM", 1, true) and all:find("TRIP", 1, true) and all:find(mu1, 1, true) and all:find("airlock", 1, true), "the LOG page: %s", all:sub(1, 600))
  shot("tm_25_log_after", true)
  -- cost while open: each page 4 s (the rows, the tree, the engine's make, the trend's paint)
  local pf = tm.PROF
  local TPg = findScript("terminal_pages")
  local worst = 0
  for _, pid in ipairs({ "REACTOR", "POWER", "FLUIDS", "LOG" }) do
    tm.page(pid)
    wait(0.5)
    local b0, t0_, u0, n0b, k0 = pf.build_ms, pf.tree_ms, pf.ui_ms, pf.builds, pf.makes
    local p0 = TPg and TPg.PROF and TPg.PROF.paint_ms or 0
    local f0, w0 = 0, W()
    local tw = W() + 4
    while W() < tw do yield(); f0 = f0 + 1 end
    local nb = math.max(1, pf.builds - n0b)
    local tot = (pf.build_ms - b0) + (pf.tree_ms - t0_) + (pf.ui_ms - u0)
    local per = tot / math.max(1, f0)
    if per > worst then worst = per end
    P("COST open %s: %d frames (%.0f fps), %d describes, %d makes; rows %.3f + tree %.3f + make %.3f ms a describe (paint %.3f ms in 4 s); %.3f ms a frame on average",
      pid, f0, f0 / (W() - w0), pf.builds - n0b, pf.makes - k0, (pf.build_ms - b0) / nb, (pf.tree_ms - t0_) / nb, (pf.ui_ms - u0) / nb,
      (TPg and TPg.PROF and TPg.PROF.paint_ms or 0) - p0, per)
  end
  P("COST worst describe %.2f ms", pf.max_ms)
  check("cost_open", worst < 0.2, "an open terminal costs at most %.3f ms a frame on average over its pages (budget 0.2)", worst)
  -- Esc leaves; the pause menu stays shut
  key("escape")
  wait(0.3)
  local pm = findScript("pause_menu")
  check("esc", not tm.isOpen() and not (pm and pm.open), "Esc leaves the console (open %s) and the pause menu stays shut (%s)", tostring(tm.isOpen()), tostring(pm and pm.open))
  -- the desk monitor: a base terminal (the log desk)
  local ms, mu = sr.pieceOf({ struct = S, part = "monitor" })
  if ms then
    stand_by(sr, ms, mu, "mark:logdesk", 1.0)
    aim(mid(ms, mu, 0.9), 1.0)
    local nr = wait_for(function() local n = tm.near(); return n and n.uid == mu and n end, 3, "the desk prompt")
    if nr then key("e") else tm.openAt(ms, mu) end
    wait_for(function() return tm.isOpen() end, 3, "the desk terminal")
    check("desk", tm.isOpen() and tm.state().kind == "desk" and tm.state().page == "STATUS", "the desk monitor opens as the base's terminal (%s, prompt %s)",
      tostring(tm.state() and tm.state().page), tostring(nr ~= nil))
    wait(1.0)
    shot("tm_30_desk_status", true)
    tm.page("CREW"); wait(0.6); shot("tm_31_desk_crew")
    tm.close()
  end
end

local MAIN = function()
  NODE.persistent = true
  wait(1)
  if CASE == "scn" then case_scn() end
  P("RESULT %s %s (%d passed, %d failed)", CASE, fails == 0 and "PASS" or "FAIL", passes, fails)
  wait(0.5)
  if (params.quit or 1) > 0 then app.quit() end
end

function update(node, dt)
  if not CO then
    NODE = node
    CASE = params.case or "scn"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); fails = fails + 1; P("RESULT %s FAIL (error)", CASE); if (params.quit or 1) > 0 then app.quit() end end
  end
end
