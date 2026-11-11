-- LOOTPROBE (tools/perf/lootprobe.sh): loot, keypads, log cards, stripping
-- and scenario data (work/interact/PLAN.md §5, slices S5 and S6) in the real
-- game, on scenarios/_story staged as PLAY stages it, then a ruin stamped by
-- the crew.
--
--   story  first person at the hut's shelf: the walk-up prompt, E opens the
--          two-pane transfer (pictured), the rations and Hale's note taken,
--          the note read (pictured: the reader), the small crate's keypad (E:
--          pictured), the code keyed in (the scenario's `kit` step latches),
--          the Repair Kit taken; the bunk's footlocker locked and FORCED from
--          its keypad (a timed job, loud, the lock broken); a chair STRIPPED
--          (gone, steel in the pack); saved and the scene loaded again: every
--          container and the pack hold what they held, the lock still broken.
--   ruin   a home-world site stamped 25 m from the crew: its crate opened by
--          E (the whole site rolled once), everything taken, a log card read,
--          a locked door opened with the code it gave; a wall stripped.
--
-- Lines: `LP PASS|FAIL <check>`, `LP SHOT`, `LP COST`, `LP RESULT`.
-- Pictures: save/user/lootshots/.
defaults = { quit = 1, case = "story" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("LP %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "story"
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
      if bytes then assets.writeBytes("user://lootshots/" .. name .. ".png", bytes); P("SHOT %s", name)
      else P("SHOT %s failed: %s", name, tostring(why)) end
    end)
    if not ok then pending = pending - 1 end
  end
  wait_for(function() return pending == 0 end, 10, "shot " .. nm)
end
local function astro() return find("Astronaut") end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
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
local function LT() return findScript("loot") end
local function LP() return findScript("loot_panel") end
local function INV() return findScript("inventory") end

-- stand `dist` m from piece (sid, uid) on the side toward the crew now (drawn poses, re-read each frame)
local function stand_by(sid, uid, dist, side)
  local ST = findScript("structures")
  local a = astro()
  for _ = 1, 30 do
    local n = ST.nodeOf(sid, uid)
    if n and a then
      local w = n.worldPos
      local u = up_of(a)
      local dx, dy, dz
      if side then dx, dy, dz = side(n) else dx, dy, dz = a.worldX - w.x, a.worldY - w.y, a.worldZ - w.z end
      local du = dx * u.x + dy * u.y + dz * u.z
      dx, dy, dz = dx - u.x * du, dy - u.y * du, dz - u.z * du
      local l = math.max(len(dx, dy, dz), 1e-3)
      local k = (dist or 1.2) / l
      a.x, a.y, a.z = w.x + dx * k + u.x * 1.0, w.y + dy * k + u.y * 1.0, w.z + dz * k + u.z * 1.0
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    yield()
  end
end
-- the piece's front (its local +Z): stand in front of it
local function front_of(n)
  local f = n.forward or (n.toWorld and n:toWorld(vec3(0, 0, 1)))
  if f and n.forward then return f.x, f.y, f.z end
  if f then local w = n.worldPos; return f.x - w.x, f.y - w.y, f.z - w.z end
  return 0, 0, 1
end
local function mid(sid, uid, h)
  return function()
    local n = findScript("structures").nodeOf(sid, uid)
    if not n then return nil end
    local w = n.worldPos
    local u = up_of(astro())
    return { x = w.x + u.x * (h or 0.7), y = w.y + u.y * (h or 0.7), z = w.z + u.z * (h or 0.7) }
  end
end
local function mass_of(cid) local inv = INV(); return inv.mass(cid) end

-- ── staging _story (the choice: "Now.") ─────────────────────────────────────
local function talk(sr)
  local st = sr.state()
  if st.cutscene then sr.skipCutscene() end
  if st.choice then sr.choose(1)
  elseif st.line and st.line.t0 and (time - st.line.t0) > 0.5 then sr.lineDone() end
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
  local wx = findScript("weather")
  if wx and wx.force then pcall(wx.force, "clear") end
  wait_for(function() talk(sr); local st = sr.state(); return sr.var("trust") == 1 and not st.cutscene and not st.choice end, 90, "the choice made")
  wait_for(function() talk(sr); local st = sr.state(); return not st.cutscene and not st.line and not st.choice and gm.inputOwner == nil end, 40, "control")
  return sr
end

local function case_story()
  local sr = stage("_story")
  if not sr then return end
  local H = "Story Hut"
  local lt, lp, inv, ST = LT(), LP(), INV(), findScript("structures")
  if not check("scripts", lt and lp and inv, "loot %s, loot_panel %s", tostring(lt ~= nil), tostring(lp ~= nil)) then return end
  local ssid, suid = sr.pieceOf({ struct = H, part = "shelf" })
  local csid, cuid = sr.pieceOf({ struct = H, part = "crateS" })
  local bsid, buid = sr.pieceOf({ struct = H, part = "bunk" })
  local hsid, huid = sr.pieceOf({ struct = H, part = "chair" })
  check("pieces", ssid and csid and bsid and hsid, "shelf %s:%s, small crate %s, bunk %s, chair %s", tostring(ssid), tostring(suid), tostring(cuid), tostring(buid), tostring(huid))
  local shelf, crate = lt.cidOf(ssid, suid), lt.cidOf(csid, cuid)
  check("staged_contents", inv.itemCount(shelf, "ration") == 3 and inv.itemCount(shelf, "datalog:hale_note") == 1 and inv.itemCount(crate, "repairkit") == 1,
    "start.containers: shelf rations %d, note %d; small crate kit %d", inv.itemCount(shelf, "ration"), inv.itemCount(shelf, "datalog:hale_note"), inv.itemCount(crate, "repairkit"))
  check("staged_lock", lt.isLocked(csid, cuid) and lt.knownCode(csid, cuid) == nil, "start.locks: the small crate locked, its code not known yet")
  local BL = findScript("base_log")
  local logged = false
  for _, e in ipairs(BL.entries({ ssid }, 30)) do if tostring(e.x):find("Third night", 1, true) then logged = true end end
  check("staged_log", logged, "start.logs: Hale's line in the hut's base log")
  -- the closed cost: prompt checks
  local c0, n0 = lp.PROF.closed_ms, lp.PROF.closed_n
  wait(3)
  local nc = lp.PROF.closed_n - n0
  P("COST closed: %.4f ms per prompt check (%d in 3 s; at most 8 Hz)", nc > 0 and (lp.PROF.closed_ms - c0) / nc or 0, nc)
  -- 1. the shelf: prompt, E, the transfer
  stand_by(ssid, suid, 1.1, front_of)
  aim(mid(ssid, suid, 1.0), 1.2)
  local nr = wait_for(function() local n = lp.near(); return n and n.uid == suid and n end, 3, "the shelf's prompt")
  check("prompt", nr ~= nil, "the walk-up prompt names the shelf")
  shot("lt_00_prompt")
  -- (E is refused while the dialogue plate is up: a radio line can land now; let it pass and press again)
  for _ = 1, 6 do
    if lp.isOpen() then break end
    talk(sr); wait(0.3)
    aim(mid(ssid, suid, 1.0), 0.3)
    if lp.near() then key("e") end
    wait(0.4)
  end
  if not lp.isOpen() then P("E did not open it: %s", tostring(findScript("terminal").blockedWhy())) end
  wait_for(function() return lp.isOpen() end, 3, "the panel")
  check("e_opens", lp.isOpen() and lp.state().mode == "box", "E opens the two-pane transfer (%s)", tostring(lp.state() and lp.state().mode))
  wait(0.8)
  shot("lt_01_transfer", true)
  local p0 = mass_of("astro")
  lp.take("ration", 3); lp.take("datalog:hale_note", 1); lp.take("iron", nil, nil, true)
  wait(0.5)
  check("take", inv.itemCount("astro", "ration") == 3 and inv.itemCount("astro", "datalog:hale_note") == 1 and inv.itemCount(shelf, "ration") == 0,
    "rations and the note into the pack (+%.1f kg)", mass_of("astro") - p0)
  wait(0.6)
  shot("lt_02_transfer_taken")
  check("rations_step", wait_for(function() return (save.get("scn.done") or {}).rations ~= nil end, 4, "rations") ~= nil, "the optional `looted` step latched")
  -- 2. the reader
  lp.openReader("hale_note")
  wait(0.8)
  check("reader", lp.state().mode == "reader" and lt.knownCode(csid, cuid) == "0417", "the note read: the small crate's code noted (%s)", tostring(lt.knownCode(csid, cuid)))
  shot("lt_03_reader", true)
  check("note_step", wait_for(function() return (save.get("scn.done") or {}).note ~= nil end, 4, "note") ~= nil, "`terminal read` latched")
  key("escape"); wait(0.3)
  check("esc_back", lp.isOpen() and lp.state().mode == "box", "Esc from the reader goes back to the box")
  key("escape"); wait(0.3)
  local pm = findScript("pause_menu")
  check("esc_leave", not lp.isOpen() and not (pm and pm.open), "Esc leaves; the pause menu stays shut")
  -- 3. the small crate's keypad
  stand_by(csid, cuid, 1.0, front_of)
  aim(mid(csid, cuid, 0.4), 1.2)
  nr = wait_for(function() local n = lp.near(); return n and n.uid == cuid and n end, 3, "the crate's prompt")
  if nr then key("e") else lp.openKeypad(csid, cuid) end
  wait_for(function() return lp.isOpen() end, 3, "the keypad")
  check("keypad", lp.isOpen() and lp.state().mode == "keypad", "E at a locked crate opens its keypad (prompt %s)", tostring(nr ~= nil))
  key("1"); key("2"); key("3")
  wait(0.4)
  shot("lt_04_keypad", true)
  key("enter")
  wait(0.4)
  check("wrong_code", lt.isLocked(csid, cuid) and lp.state().bad, "123 refused (%s)", tostring(lp.state().msg))
  key("0"); key("4"); key("1"); key("7")
  wait(0.3)
  shot("lt_05_keypad_0417")
  key("enter")
  local opened = wait_for(function() return lp.isOpen() and lp.state().mode == "box" end, 3, "the crate's box")
  check("code_opens", not lt.isLocked(csid, cuid) and opened, "0417 typed opens it and the box comes up (%s)", tostring(lt.lockOf(csid, cuid)))
  lp.take("repairkit", 1)
  check("kit_step", wait_for(function() return (save.get("scn.done") or {}).kit ~= nil end, 4, "kit") ~= nil, "`part_state` locked = false and `has_item` repairkit: the kit step latched")
  wait(0.5)
  shot("lt_06_crate_open")
  lp.close()
  -- 4. the bunk's footlocker: locked on a code nobody knows, forced from its keypad
  lt.setCode(bsid, buid, "8642", false)
  stand_by(bsid, buid, 1.0, front_of)
  lp.openKeypad(bsid, buid)
  wait(0.3)
  local okf = lp.force()
  check("force_starts", okf and lp.state().job ~= nil, "Force the lock: a job (%s)", tostring(lp.state().job))
  wait(2.0)
  shot("lt_07_forcing")
  local forced = wait_for(function() return lt.lockOf(bsid, buid) == "broken" end, 40, "the lock to give")
  check("forced", forced and lt.lastNoise and lt.lastNoise.what == "forced", "forced: the lock broken (%s), it was loud", tostring(lt.lockOf(bsid, buid)))
  wait_for(function() return lp.isOpen() and lp.state().mode == "box" end, 3, "the bunk's box")
  lp.take("flashlight", 1)
  lp.close()
  -- 5. strip a chair (Okafor: an Engineer with the laser)
  local steel0 = inv.count("astro", "steel")
  local q = lt.stripQuote(hsid, huid, { actor = { pack = "astro" } })
  check("strip_quote", q and q.why == nil, "a chair strips into %s in %.0f s (%s)", lt.yieldText(q), q and q.secs or -1, tostring(q and q.why))
  local oks, why = lt.strip(hsid, huid, { actor = { pack = "astro" } })
  check("strip", oks and ST.getPart(hsid, huid) == nil and (inv.count("astro", "steel") > steel0 or inv.itemCount("astro", "part:chair.steel") > 0 or (lt.lastStrip and lt.lastStrip.salvage ~= nil)),
    "%s (into the pack %.1f kg, salvage %s)", tostring(why), lt.lastStrip and lt.lastStrip.into or -1, tostring(lt.lastStrip and lt.lastStrip.salvage))
  -- 6. save, the scene again: the contents persist
  local keep = { shelf = mass_of(shelf), crate = mass_of(crate), pack = mass_of("astro"), bunk = mass_of(lt.cidOf(bsid, buid)) }
  local gm = findScript("game_manager")
  if gm and gm.saveGame then gm.saveGame() end
  wait(1.0)
  scene.load("system")
  yield()
  local sr2 = wait_for(function() local s = findScript("scenario_run"); return s and s ~= sr and s.isActive and s.isActive() and s.phaseNow and s.phaseNow() == "running" and s end, 240, "the reload")
  gm = findScript("game_manager")
  wait_for(function() return gm and not gm.curtain end, 60, "the reveal")
  wait(2.0)
  lt, lp, inv = LT(), LP(), INV()
  local ok_keep = math.abs(mass_of(shelf) - keep.shelf) < 1e-6 and math.abs(mass_of(crate) - keep.crate) < 1e-6 and math.abs(mass_of(lt.cidOf(bsid, buid)) - keep.bunk) < 1e-6
  check("reload_contents", sr2 ~= nil and ok_keep, "after a save and a reload: shelf %.1f/%.1f, crate %.1f/%.1f, bunk %.1f/%.1f kg",
    mass_of(shelf), keep.shelf, mass_of(crate), keep.crate, mass_of(lt.cidOf(bsid, buid)), keep.bunk)
  check("reload_pack", math.abs(mass_of("astro") - keep.pack) < 1e-6 and inv.itemCount("astro", "repairkit") >= 1, "the pack %.1f/%.1f kg, the Repair Kit in it", mass_of("astro"), keep.pack)
  check("reload_lock", lt.lockOf(bsid, buid) == "broken" and not lt.isLocked(csid, cuid) and lt.knownCode(csid, cuid) == "0417", "the forced lock still broken; the crate's code still noted")
  check("reload_restage", inv.itemCount(shelf, "ration") == 0, "the restaging did not fill the shelf again")
end

-- ── a ruin by the crew ──────────────────────────────────────────────────────
local function case_ruin()
  local RU, ST, lt, lp, inv = findScript("ruins"), findScript("structures"), LT(), LP(), INV()
  local a = astro()
  local bname = space.dominant(a.worldX, a.worldY, a.worldZ)
  local b = space.body(bname)
  local s = nil
  for _, x in ipairs(RU.sites(bname)) do if not x.pending then s = x; break end end
  if not check("site", s ~= nil, "a site on %s", tostring(bname)) then return end
  s.kind = "hab"            -- (the probe's pick: locks, a locker, a cabinet, bunks, crates)
  local e = RU.state(s.id)
  if e.sid then RU.unstampNow(s.id) end
  local u = up_of(a)
  -- 25 m along the ground from the crew, on the ground under there (a terrain ray)
  local t1 = { x = u.y, y = -u.x, z = 0 }
  local tl = len(t1.x, t1.y, t1.z); if tl < 0.1 then t1 = { x = 0, y = u.z, z = -u.y }; tl = len(t1.x, t1.y, t1.z) end
  t1 = { x = t1.x / tl, y = t1.y / tl, z = t1.z / tl }
  local ox, oy, oz = a.worldX + t1.x * 25 + u.x * 30, a.worldY + t1.y * 25 + u.y * 30, a.worldZ + t1.z * 25 + u.z * 30
  local hit = terrain.raycast(vec3(ox, oy, oz), vec3(-u.x, -u.y, -u.z), 80)
  local gx, gy, gz = (hit and hit.pos.x or ox) - b.x, (hit and hit.pos.y or oy) - b.y, (hit and hit.pos.z or oz) - b.z
  local gl = len(gx, gy, gz)
  local ux, uy, uz = gx / gl, gy / gl, gz / gl
  local fx, fy, fz = t1.x - ux * (t1.x * ux + t1.y * uy + t1.z * uz), t1.y - uy * (t1.x * ux + t1.y * uy + t1.z * uz), t1.z - uz * (t1.x * ux + t1.y * uy + t1.z * uz)
  local fl = len(fx, fy, fz)
  e.g = { x = gx - ux * 0.15, y = gy - uy * 0.15, z = gz - uz * 0.15, ux = ux, uy = uy, uz = uz, fx = fx / fl, fy = fy / fl, fz = fz / fl }
  e.drop = nil
  local sid = RU.stampNow(s.id, true)
  if not check("stamped", sid ~= nil, "%s stamped as structure %s", s.name, tostring(sid)) then return end
  wait_for(function() return ST.isLive(sid) and ST.pacing() == 0 and #(ST.nodesOf(sid) or {}) > 0 end, 20, "the ruin's pieces")
  wait(1.0)
  local rec = ST.get(sid)
  local crate, door = nil, nil
  for _, p in ipairs(rec.bp) do
    if p.rl == "loot" and not crate then crate = p end
    local st = ST.partState(sid, p.uid)
    if st and st.kp and RU.isLockDoor(p.id) and not door then door = p end
  end
  stand_by(sid, crate.uid, 1.3)
  aim(mid(sid, crate.uid, 0.5), 1.2)
  local nr = wait_for(function() local n = lp.near(); return n and n.uid == crate.uid and n end, 3, "the ruin crate's prompt")
  check("ruin_prompt", lp.near() ~= nil, "a container prompt by the ruin's crate (%s)", tostring(lp.near() and lp.near().uid))
  if nr then key("e") else lp.openContainer(sid, crate.uid) end
  wait_for(function() return lp.isOpen() end, 3, "the panel")
  check("ruin_open", lp.isOpen() and lt.filled(sid, crate.uid) and RU.peekState(s.id).lp ~= nil, "E opens the ruin's crate; the site rolled (%.2f ms)", lt.stats.last_fill_ms or -1)
  wait(0.8)
  shot("lt_10_ruin_crate", true)
  local cid = lt.cidOf(sid, crate.uid)
  lp.takeAll()
  wait(0.5)
  check("ruin_take", lt.isEmpty(cid) or (lp.state().bad == true), "everything that fits taken (%s)", tostring(lp.state().msg))
  lp.close()
  -- find the shift note in any of the site's boxes, read it, open the door with it
  local codelog = nil
  for _, p in ipairs(rec.bp) do
    local d = findScript("parts_base").partInfo(p.id)
    if d and d.container then
      for _, g in ipairs(inv.itemList(lt.cidOf(sid, p.uid))) do
        local k = lt.logKeyOf(g.id)
        local r = k and lt.logRecord(k)
        if r and r.codes and #r.codes > 0 then codelog = k; inv.moveItem(lt.cidOf(sid, p.uid), "astro", g.id, 1) end
      end
    end
  end
  for _, g in ipairs(inv.itemList("astro")) do local k = lt.logKeyOf(g.id); local r = k and lt.logRecord(k); if r and r.codes and #r.codes > 0 then codelog = k end end
  if door then
    check("ruin_note", codelog ~= nil, "the site's shift note (%s)", tostring(codelog))
    if codelog then
      lp.openReader(codelog); wait(0.6); shot("lt_11_ruin_note"); lp.close()
      check("ruin_code_known", lt.knownCode(sid, door.uid) ~= nil, "reading it noted the door's code (%s)", tostring(lt.knownCode(sid, door.uid)))
      stand_by(sid, door.uid, 1.4)
      lp.openKeypad(sid, door.uid)
      wait(0.5)
      shot("lt_12_ruin_keypad")
      lp.useKnown()
      wait(0.5)
      check("ruin_door", not lt.isLocked(sid, door.uid) and ST.partState(sid, door.uid).dh == nil, "the door's keypad takes the code and its bolt lets go")
      wait(1.0)
      lp.close()
    end
  else
    P("ruin: no locked door on this roll (hab lock chance 0.55)")
  end
  -- strip a wall
  local wall = nil
  for _, p in ipairs(ST.get(sid).bp) do if p.id == "wall.steel" then wall = p break end end
  if wall then
    local before = inv.count("astro", "steel")
    local ok, why = lt.strip(sid, wall.uid, { actor = { pack = "astro" } })
    check("ruin_strip", ok and ST.getPart(sid, wall.uid) == nil, "a ruin wall stripped: %s (steel %d → %d)", tostring(why), before, inv.count("astro", "steel"))
  end
end

local MAIN = function()
  NODE.persistent = true
  wait(1)
  if CASE == "story" or CASE == "all" then case_story() end
  if CASE == "ruin" or CASE == "all" then case_ruin() end
  P("RESULT %s %s (%d passed, %d failed)", CASE, fails == 0 and "PASS" or "FAIL", passes, fails)
  wait(0.5)
  if (params.quit or 1) > 0 then app.quit() end
end

function update(node, dt)
  if not CO then
    NODE = node
    CASE = params.case or "story"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); fails = fails + 1; P("RESULT %s FAIL (error)", CASE); if (params.quit or 1) > 0 then app.quit() end end
  end
end
