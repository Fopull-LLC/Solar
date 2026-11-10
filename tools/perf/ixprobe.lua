-- IXPROBE (tools/perf/ixprobe.sh): the part-interaction slices S0–S2 in the
-- real game (work/interact/PLAN.md). Right taps given the way a player gives
-- them (input.simulate: the button, with the hand drifting while it is down),
-- in FIRST PERSON at the crosshair, and what came up; pictures of the piece
-- panels. One case per run:
--
--   scn      Graveyard Shift staged as PLAY stages it (the tags patch applied
--            by the runner): first person at the console, a tap with a 12 px
--            drift → the console's menu; the crew switched to Kowalczyk, the
--            tap again; at the sky → no menu, the caption; the piece panels on
--            P-3 (the makeup pump), MU-1 (its valve), FW-2, a light
--   reenter  Graveyard staged, left for the menu, staged again: the console tap
--   slot1    a COPY of Ty's slot1 (crew 3 in control): first person at his
--            ruin's wall and its light (he switched two off), and his base
--
-- Lines: `IX PASS|FAIL <check>`, `IX MENU`, `IX TAP` (context_menu.lastTap,
-- ctxDebug on), `IX SHOT`, `IX RESULT`. Pictures: save/user/ixshots/.
defaults = { quit = 1, case = "scn" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("IX %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "scn"
local NODE, CO
local fails, passes = 0, 0
local function yield() coroutine.yield() end
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
local function shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://ixshots/" .. nm .. ".png", bytes); P("SHOT %s", nm)
    else P("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
local function astro() return find("Astronaut") end
local function cm() return findScript("context_menu") end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end
local function clear_weather()
  local wx = findScript("weather")
  if wx and wx.force then pcall(wx.force, "clear") end
end

-- ── the view: first person, aimed at a world point (re-read every frame) ───
local function up_of(a)
  local name = space.dominant(a.worldX, a.worldY, a.worldZ)
  local b = name and space.body(name)
  if not b then return { x = 0, y = 1, z = 0 } end
  local x, y, z = a.worldX - b.x, a.worldY - b.y, a.worldZ - b.z
  local l = len(x, y, z)
  return { x = x / l, y = y / l, z = z / l }
end
-- aim the eyes at `pt()` (a function → this frame's world point), for `secs`
local function aim(pt, secs)
  local pc = findScript("planet_camera")
  pc.firstPerson = true
  local t0 = W()
  repeat
    local a = astro()
    local p = pt()
    if a and p then
      local u = up_of(a)
      -- (both ends this frame's: the crew's eye from its node, the piece's node)
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
local function center()
  local ox, oy, w, h = camera.screenRect()
  return ox + w * 0.5, oy + h * 0.5, h
end

-- A right TAP the way a player gives it in first person: down, the hand
-- drifting `drift` px over the press (the look), up within 0.25 s.
local function rtap(drift)
  local cx, cy = center()
  input.simulate { mouse = { cx, cy } }
  yield(); yield()
  input.simulate { button = 1, down = true }
  yield()
  local n = 4
  for k = 1, n do input.simulate { mouse = { cx + (drift or 0) * k / n, cy + (drift or 0) * 0.3 * k / n } }; yield() end
  input.simulate { button = 1, down = false }
  yield(); yield(); yield()
end

local function dump(tag)
  local c = cm()
  local list, title, sub = c.entries()
  local reg = findScript("context_registry")
  local out = {}
  for _, e in ipairs(list or {}) do
    local v = reg and reg.live(e.value)
    local u, why = true, nil
    if reg then u, why = reg.usable(e) end
    out[#out + 1] = string.format("%s[%s]%s%s%s", e.id, e.type, e.label ~= "" and (" " .. tostring(e.label)) or "",
      v and (" = " .. tostring(v)) or "", u and "" or (" (dim: " .. tostring(why) .. ")"))
  end
  P("MENU %s: open %s · %s · %s | %s", tag, tostring(c.isOpen()), tostring(title), tostring(sub), table.concat(out, " ; "))
  return list, title, sub
end
local function tap_line(tag)
  local L = cm().lastTap
  if not L then P("TAP %s: none recorded (blocked: %s)", tag, tostring(cm().blockedWhy and cm().blockedWhy())) return end
  P("TAP %s: by %s eyes %s hit %s<%s %.2f m%s -> %s %s · why %s · said %s", tag, tostring(L.by), tostring(L.eyes), tostring(L.hit), tostring(L.parent),
    L.dist or -1, L.recast and (" (cast past " .. L.recast .. ")") or "", tostring(L.kind), tostring(L.label), tostring(L.why), tostring(L.said))
end

-- Tap at piece (sid, uid) from where the crew stands; → the menu's title
local function tap_piece(tag, sid, uid, want_title, nm)
  local ST = findScript("structures")
  local c = cm()
  if c.isOpen() then c.close() end
  local function pt()
    local n = ST.nodeOf(sid, uid)
    if not n then return nil end
    local w = n.worldPos
    -- (a piece's node sits at its foot: aim a little up its height)
    local d = findScript("parts_base").partInfo(ST.getPart(sid, uid).id) or {}
    local b = d.box
    local hgt = b and (b[3] + b[4]) / 2 or 0.4
    local u = up_of(astro())
    return { x = w.x + u.x * hgt, y = w.y + u.y * hgt, z = w.z + u.z * hgt }
  end
  if not pt() then check(tag, false, "piece %s:%s has no node", tostring(sid), tostring(uid)) return nil end
  aim(pt, 1.0)
  rtap(12)
  aim(pt, 0.3)
  tap_line(tag)
  local list, title, sub = dump(tag)
  local okt = c.isOpen() and title ~= nil and (want_title == nil or tostring(title):find(want_title, 1, true) ~= nil)
  check(tag, okt, "a first-person right tap (12 px of drift) opened %s (want %s)", tostring(title), tostring(want_title))
  if nm then wait(0.4); aim(pt, 0.4); shot(nm) end
  return title, list
end

-- ── scenarios ───────────────────────────────────────────────────────────────
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
  -- the dialogue and the cutscenes through to the handover's end
  wait_for(function() talk(sr); return (save.get("scn.done") or {}).handover ~= nil end, 120, "the handover")
  wait_for(function() talk(sr); local st = sr.state(); return not st.cutscene and not st.line and not st.choice and (gm.inputOwner == nil) end, 40, "control")
  return sr
end
local function stand(sr, ref, frames_)
  local a = astro()
  for _ = 1, frames_ or 20 do
    local p = sr.posOf(ref)
    if p and a then
      local l = len(p.x, p.y, p.z)
      local b = space.body(p.body)
      a.x, a.y, a.z = b.x + p.x * (l + 1) / l, b.y + p.y * (l + 1) / l, b.z + p.z * (l + 1) / l
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    yield()
  end
end

-- stand on the console's far side from Dana, 1.3 m off it
local function off_dana(sr)
  local a = astro()
  local cp = sr.posOf("mark:console")
  local dp = sr.posOf("crew:Kowalczyk") or sr.posOf("mark:dana")
  if not (a and cp and dp) then return end
  local dx, dy, dz = cp.x - dp.x, cp.y - dp.y, cp.z - dp.z
  local l = len(cp.x, cp.y, cp.z)
  local ux, uy, uz = cp.x / l, cp.y / l, cp.z / l
  local du = dx * ux + dy * uy + dz * uz
  dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
  local m = len(dx, dy, dz)
  if m < 1e-3 then return end
  local b = space.body(cp.body)
  for _ = 1, 30 do
    local q = sr.posOf("mark:console")
    a.x = b.x + q.x + ux + dx / m * 1.3
    a.y = b.y + q.y + uy + dy / m * 1.3
    a.z = b.z + q.z + uz + dz / m * 1.3
    a.vx, a.vy, a.vz = 0, 0, 0
    yield()
  end
end

local function case_scn()
  local sr = stage("graveyard_shift")
  if not sr then return end
  local ST = findScript("structures")
  local c = cm()
  c.ctxDebug = true
  local csid, cuid = sr.pieceOf({ struct = S, part = "reactorConsole" })
  if not check("console_piece", csid ~= nil, "the station stands (console %s:%s)", tostring(csid), tostring(cuid)) then return end
  stand(sr, "mark:console", 30)
  wait(0.5)
  -- (from the console mark itself Dana, posted 0.76 m off it at mark:dana,
  -- stands in the line of sight: recorded, not asserted — a tap on her is
  -- her menu, rightly)
  local ST0 = findScript("structures")
  local function pt0() local n = ST0.nodeOf(csid, cuid); local w = n.worldPos; local u = up_of(astro()); return { x = w.x + u.x * 0.6, y = w.y + u.y * 0.6, z = w.z + u.z * 0.6 } end
  aim(pt0, 1.0); rtap(12); aim(pt0, 0.3)
  tap_line("console_from_mark (recorded: Dana's post is in the line of sight)")
  wait(0.3); shot("ix_00_console_from_mark")
  c.close()
  off_dana(sr)
  wait(0.5)
  local title, list = tap_piece("scn_console", csid, cuid, "Reactor Control Console", "ix_01_console")
  local reg = findScript("context_registry")
  check("console_setpoint", reg and reg.byId(list or {}, "rx_up") ~= nil, "the console's menu has Setpoint +10 %% (the step Ty never finished)")
  c.close()
  -- hold the Context key: your own suit
  input.simulate { key = "u", down = true }
  wait(0.6)
  input.simulate { key = "u", down = false }
  yield(); yield()
  check("suit_hold", c.isOpen() and c.target and c.target.kind == "astro", "U held 0.4 s opens your own suit's menu (%s)", tostring(c.target and c.target.kind))
  c.close()
  -- the U key tapped at the console: the same menu as RMB
  off_dana(sr)
  aim(function() local n = ST.nodeOf(csid, cuid); local w = n.worldPos; local u = up_of(astro()); return { x = w.x + u.x * 0.6, y = w.y + u.y * 0.6, z = w.z + u.z * 0.6 } end, 0.8)
  input.simulate { key = "u", down = true }; yield(); yield(); input.simulate { key = "u", down = false }; yield(); yield(); yield()
  tap_line("key_u")
  check("key_u", c.isOpen() and c.target and c.target.kind == "prop", "U tapped at the console opens its menu (%s)", tostring(c.target and c.target.kind))
  c.close()
  -- the pieces Graveyard talks about: P-3, MU-1, FW-2 (their designations from start.tags)
  stand(sr, "mark:mu1", 30)
  local s3, u3 = sr.pieceOf({ struct = S, uid = 116 })
  local s1, u1 = sr.pieceOf({ struct = S, uid = 114 })
  local _, lp = tap_piece("pump_P3", s3, u3, "P-3", "ix_02_pump_P3")
  _, lp = tap_piece("valve_MU1", s1, u1, "MU-1", "ix_03_valve_MU1")
  -- the valve: shut it by its own row, then open it again (B5)
  local FN = findScript("fluid_net")
  c.press("fl_on"); wait(0.6)
  local shut = not FN.isOn(s1, u1)
  if not c.isOpen() then tap_piece("valve_MU1b", s1, u1, "MU-1", nil) end
  c.press("fl_on"); wait(0.6)
  check("valve_reopen", shut and FN.isOn(s1, u1), "MU-1 shut by its row (%s) and opened again (%s)", tostring(shut), tostring(FN.isOn(s1, u1)))
  c.close()
  local s2, u2 = sr.pieceOf({ struct = S, uid = 147 })
  -- 1.4 m off FW-2 on the side its mark is (the radiators stand behind it)
  do
    local a = astro()
    for _ = 1, 30 do
      local n = ST.nodeOf(s2, u2)
      local m = sr.posOf("mark:fw2")
      if n and m then
        local b = space.body(m.body)
        local w = n.worldPos
        local px, py, pz = w.x - b.x, w.y - b.y, w.z - b.z
        local l = len(px, py, pz)
        local ux, uy, uz = px / l, py / l, pz / l
        local dx, dy, dz = m.x - px, m.y - py, m.z - pz
        local du = dx * ux + dy * uy + dz * uz
        dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
        local dl = math.max(len(dx, dy, dz), 1e-3)
        a.x, a.y, a.z = w.x + dx / dl * 1.4 + ux, w.y + dy / dl * 1.4 + uy, w.z + dz / dl * 1.4 + uz
        a.vx, a.vy, a.vz = 0, 0, 0
      end
      yield()
    end
    wait(0.5)
  end
  tap_piece("feed_FW2", s2, u2, "FW-2", "ix_04_feed_FW2")
  c.close()
  -- the sky: no menu, a caption (no silent EVA suit)
  aim(function() local a = astro(); local u = up_of(a); return { x = a.worldX + u.x * 50 + 3, y = a.worldY + u.y * 50, z = a.worldZ + u.z * 50 } end, 0.8)
  rtap(5)
  wait(0.2); shot("ix_10_sky_caption")
  tap_line("sky")
  check("sky", not c.isOpen() and c.lastTap and c.lastTap.said ~= nil, "a tap at nothing in first person opens no menu and says so: %s", tostring(c.lastTap and c.lastTap.said))

  -- a light: stand a metre off it, look up
  local ls, lu = sr.pieceOf({ struct = S, part = "lightFitting" })
  if ls then
    local rec = ST.get(ls)
    local p = ST.getPart(ls, lu)
    local KS = findScript("kit_snap")
    local fr = KS.frameOf(rec)
    local a = astro()
    for _ = 1, 30 do
      local b = space.body(rec.b)
      local lx, lz = (p.x or 0) + 1.2, (p.z or 0) + 0.6
      local wx = b.x + fr.O.x + fr.R.x * lx + fr.F.x * lz + fr.U.x * 1.1
      local wy = b.y + fr.O.y + fr.R.y * lx + fr.F.y * lz + fr.U.y * 1.1
      local wz = b.z + fr.O.z + fr.R.z * lx + fr.F.z * lz + fr.U.z * 1.1
      a.x, a.y, a.z = wx, wy, wz
      a.vx, a.vy, a.vz = 0, 0, 0
      yield()
    end
    wait(0.5)
    local _, ll = tap_piece("light", ls, lu, "Light", "ix_05_light")
    -- off by its own row: the grid stops counting it
    local BG = findScript("base_grid")
    local g = BG.gridOfStruct(ls)
    local need0 = g and BG.model(g.id) and BG.model(g.id).need or -1
    c.press("kl_light"); wait(0.3)
    BG.rebuildNow()
    local need1 = g and BG.model(BG.gridOfStruct(ls).id).need or -1
    check("light_off_draw", need1 < need0 - 1e-6, "a light switched off: the grid's need %.3f -> %.3f kW", need0, need1)
    c.press("kl_light")
    c.close()
  end
  -- the crew switched (Ty: "after switching characters right clicking in
  -- first person keeps just selecting the eva suit")
  local C = findScript("crew")
  local dana = nil
  for _, r in ipairs(C.roster()) do if tostring(r.name):find("Kowalczyk", 1, true) then dana = r.id end end
  local ok, why = false, "no Kowalczyk"
  if dana then ok, why = C.switchToMember(dana) end
  wait(2.0)
  check("switched", ok and C.activeId() == dana, "control → Kowalczyk (#%s): %s %s", tostring(dana), tostring(ok), tostring(why))
  stand(sr, "mark:console", 30)
  wait(0.5)
  tap_piece("switch_console", csid, cuid, "Reactor Control Console", "ix_06_console_after_switch")
end

local function case_reenter()
  local sr = stage("graveyard_shift")
  if not sr then return end
  local c = cm()
  c.ctxDebug = true
  local csid, cuid = sr.pieceOf({ struct = S, part = "reactorConsole" })
  stand(sr, "mark:console", 30)
  off_dana(sr)
  tap_piece("first_console", csid, cuid, "Reactor Control Console", nil)
  c.close()
  -- leave for the menu the way the pause menu's "Exit to menu" does
  sr.toMenu()
  wait_for(function() return not findScript("scenario_run") or not findScript("scenario_run").isActive() end, 60, "the menu")
  wait(3.0)
  P("at the menu: scene has scenario_run %s", tostring(findScript("scenario_run") ~= nil))
  local sr2 = stage("graveyard_shift")
  if not sr2 then return end
  c = cm()
  c.ctxDebug = true
  local pc = findScript("planet_camera")
  P("after re-entry: cinematic %s freecam %s blocked %s inputOwner %s", tostring(pc.cinematic), tostring(pc.freecam), tostring(c.blockedWhy and c.blockedWhy()),
    tostring(findScript("game_manager").inputOwner))
  csid, cuid = sr2.pieceOf({ struct = S, part = "reactorConsole" })
  stand(sr2, "mark:console", 30)
  off_dana(sr2)
  tap_piece("reenter_console", csid, cuid, "Reactor Control Console", "ix_07_console_reentered")
end

local function case_slot1()
  NODE.persistent = true
  save.slot("slot1")
  P("slot1: crew.active %s", tostring(save.get("crew.active")))
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  clear_weather()
  wait(3)
  local c = cm()
  c.ctxDebug = true
  local C = findScript("crew")
  check("crew3", C.activeId() == 3, "Ty's save: crew %s in control", tostring(C.activeId()))
  -- Ty's save has Talia aboard "Untitled" (a seat, not the controls): a tap there
  local pw = findScript("planet_walker")
  P("slot1: onFoot %s, avatarCraft %s, piloting %s", tostring(pw.onFoot), tostring(C.avatarCraft() ~= nil), tostring(C.avatarCraft() and C.avatarCraft().piloting))
  if not pw.onFoot then
    rtap(4)
    tap_line("seated")
    check("seated_tap", c.lastTap ~= nil, "a right tap from the seat is heard (actor %s): %s %s", tostring(c.actor and c.actor.id), tostring(c.lastTap and c.lastTap.kind), tostring(c.lastTap and (c.lastTap.label or c.lastTap.why)))
    wait(0.3); shot("ix_11_seated_tap")
    c.close()
    local okE, whyE = C.eva(3, { confirmed = true })
    P("slot1: EVA %s %s", tostring(okE), tostring(whyE))
    wait_for(function() return pw.onFoot == true end, 20, "on foot")
    wait(1.0)
  end
  local ST, KS = findScript("structures"), findScript("kit_snap")
  local ruin = nil
  for _, r in ipairs(ST.list()) do if r.ru then ruin = r end end
  if not check("ruin", ruin ~= nil, "a ruin in Ty's save: %s", tostring(ruin and ruin.ru)) then return end
  -- a wall of it and a light of it
  local PB = findScript("parts_base")
  local wall, light = nil, nil
  for _, p in ipairs(ruin.bp) do
    local d = PB.partInfo(p.id) or {}
    if not wall and d.piece == "wall" and not d.door and (p.ri or 1) > 0 then wall = p end
    if not light and d.light then light = p end
  end
  P("ruin %s: %d pieces, wall %s, light %s", tostring(ruin.ru), #ruin.bp, tostring(wall and wall.uid), tostring(light and light.uid))
  local function stand_near(p, off)
    local a = astro()
    local fr = KS.frameOf(ruin)
    for _ = 1, 40 do
      local b = space.body(ruin.b)
      local lx, lz = (p.x or 0) + off[1], (p.z or 0) + off[2]
      a.x = b.x + fr.O.x + fr.R.x * lx + fr.F.x * lz + fr.U.x * (off[3] or 1.2)
      a.y = b.y + fr.O.y + fr.R.y * lx + fr.F.y * lz + fr.U.y * (off[3] or 1.2)
      a.z = b.z + fr.O.z + fr.R.z * lx + fr.F.z * lz + fr.U.z * (off[3] or 1.2)
      a.vx, a.vy, a.vz = 0, 0, 0
      local CR = findScript("crew")
      if CR and CR.quietMonitors then CR.quietMonitors(0.3) end
      yield()
    end
    wait(1.0)
  end
  wait_for(function() return wall and ST.nodeOf(ruin.id, wall.uid) end, 10, "the ruin's wall node")
  if wall then
    -- face the wall from 2.5 m on its outer side (its own +Z), then the inner side
    local fw = KS.localAxes and select(2, KS.localAxes(wall.yaw or 0, wall.pitch or 0, wall.roll or 0)) or { math.sin(wall.yaw or 0), 0, math.cos(wall.yaw or 0) }
    stand_near(wall, { fw[1] * 2.5, fw[3] * 2.5 })
    local t = tap_piece("ruin_wall", ruin.id, wall.uid, nil, "ix_08_ruin_wall")
    local list, title, sub = cm().entries()
    check("ruin_title", title and not tostring(title):find(tostring(ruin.ru):gsub("#.*", ""), 1, true) and sub and tostring(sub):find("Abandoned", 1, true) ~= nil,
      "the ruin's wall is titled by itself (%s), the site in the subtitle (%s)", tostring(title), tostring(sub))
    c.close()
  end
  if light then
    -- (inside the hab: try a few spots round it until the tap lands on it)
    local got = nil
    for k, off in ipairs({ { -1.0, -0.6, 1.1 }, { 1.0, 0.6, 1.1 }, { 0.6, -1.0, 1.1 }, { -0.6, 1.0, 1.1 } }) do
      stand_near(light, off)
      local last = k == 4
      got = tap_piece(last and "ruin_light" or ("ruin_light_try" .. k), ruin.id, light.uid, "Light", nil)
      if got and tostring(got):find("Light", 1, true) then
        if not last then check("ruin_light", true, "(spot %d)", k) end
        wait(0.4); shot("ix_09_ruin_light")
        break
      end
      c.close()
    end
    c.close()
  end
end

local MAIN = function()
  NODE.persistent = true
  wait(1)
  if CASE == "scn" then case_scn()
  elseif CASE == "reenter" then case_reenter()
  elseif CASE == "slot1" then case_slot1() end
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
