-- INSPECTPROBE (tools/perf/inspectprobe.sh): what an open context menu, the
-- terminal and the loot panel cost a frame (Ty's playtest 2026-11-11: "inspecting
-- a base part in a scenario absolutely destroys the framerate"). Each panel is
-- opened on a piece and HELD `hold` seconds; every frame's perf record is read
-- (frame ms, the scripts and ui buckets, context_menu / terminal / loot_panel's
-- own hook time, the scripts parts) and then a short pass with the script
-- sampler names the hot lines. A closed-menu hold at the same spot first is
-- the floor the open menus are read against.
--
--   scn     Graveyard Shift staged as PLAY stages it: the Reactor Control
--           Console, P-3 (pump), MU-1 (valve), FW-2, a light, a wall, a
--           breaker, a tank, a container; the console's Inspect… sub-panel; the
--           terminal on REACTOR, POWER, FLUIDS, LOG; the loot panel on a container
--   hollis  What Hollis Left staged: ruin pieces (a wall, a knocked block, a
--           terminal, a container), the loot panel on a ruin crate
--   base    a new save, a 500-piece sandbox base (floors, walls, doors) with
--           lights, a pump, a valve, a tank and lockers on the home world: a
--           wall, a floor, a light, a pump, a valve, a locker
--
-- Lines: `IP COST <tag>: ...` (per hold), `IP HOT <tag>: ...` (sampler lines),
-- `IP PASS|FAIL`, `IP RESULT`. Budget (the brief): open, at most 0.3 ms a frame
-- on average above the closed floor, no frame over 33 ms from scripts.
defaults = { quit = 1, case = "scn", hold = 10, sample = 3 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("IP %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "scn"
local NODE, CO
local fails, passes = 0, 0
local SR = nil
local function yield() coroutine.yield() end
local function talk(sr)
  if not sr then return end
  local st = sr.state()
  if st.cutscene then sr.skipCutscene() end
  if st.choice then sr.choose(1)
  elseif st.line and st.line.t0 and (time - st.line.t0) > 0.5 then sr.lineDone() end
end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); talk(SR); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
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
local function astro() return find("Astronaut") end
local function cm() return findScript("context_menu") end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function clear_weather()
  local wx = findScript("weather")
  if wx and wx.force then pcall(wx.force, "clear") end
end

-- ── the measurement ─────────────────────────────────────────────────────────
local OWN = { inspectprobe = true }
local WATCH = { "context_menu", "terminal", "loot_panel", "part_info", "context_registry" }
local SUMMARY = {}
local function hold(tag, secs, keep_open)
  secs = secs or params.hold or 10
  local n, sum, worst, scr, scrw, uib, uibw = 0, 0, 0, 0, 0, 0, 0
  local per, perw = {}, {}
  local parts = {}
  local over33 = 0
  local last_frame = nil
  local seen = {}
  local c0 = cm()
  local P0 = {}
  for k, v in pairs((c0 and c0.PROF) or {}) do P0[k] = v end
  local t0 = W()
  yield(); yield()
  while W() - t0 < secs do
    yield()
    talk(SR)
    if keep_open and not keep_open() then P("COST %s: the panel closed after %.1f s", tag, W() - t0) break end
    local fr = perf.frames(1)
    local f = fr and fr[1]
    if f and f.frame ~= last_frame then
      last_frame = f.frame
      n = n + 1
      sum = sum + (f.ms or 0)
      worst = math.max(worst, f.ms or 0)
      local own = 0
      for _, s in ipairs(f.scripts or {}) do
        if OWN[s.name] then own = own + (s.ms or 0) end
        per[s.name] = (per[s.name] or 0) + (s.ms or 0)
        seen[s.name] = (seen[s.name] or 0) + 1
        perw[s.name] = math.max(perw[s.name] or 0, s.ms or 0)
      end
      local s = ((f.buckets or {}).scripts or 0) - own
      scr = scr + s
      scrw = math.max(scrw, s)
      if s > 33 then over33 = over33 + 1 end
      local u = (f.buckets or {}).ui or 0
      uib = uib + u
      uibw = math.max(uibw, u)
      for k, v in pairs(f.parts or {}) do parts[k] = (parts[k] or 0) + v end
    end
  end
  if n == 0 then P("COST %s: no frames", tag) return nil end
  local w = {}
  for _, nm in ipairs(WATCH) do
    if per[nm] then w[#w + 1] = string.format("%s %.3f (worst %.2f)", nm, per[nm] / n, perw[nm]) end
  end
  local top = {}
  for k, v in pairs(per) do if not OWN[k] then top[#top + 1] = { k, v / n } end end
  table.sort(top, function(a, b) return a[2] > b[2] end)
  local tl = {}
  for i = 1, math.min(6, #top) do tl[#tl + 1] = string.format("%s %.3f", top[i][1], top[i][2]) end
  local pl = {}
  for k, v in pairs(parts) do if k:find("^scripts") or k:find("^callbacks") then pl[#pl + 1] = { k, v / n } end end
  table.sort(pl, function(a, b) return a[2] > b[2] end)
  local pt = {}
  for i = 1, math.min(5, #pl) do pt[#pt + 1] = string.format("%s %.3f", pl[i][1], pl[i][2]) end
  -- (the menu's own account: provider passes, describes, makes; and how many
  -- frames its script ran in at all: the engine stops a script whose update
  -- runs past 2 s three times)
  local PR = (c0 and c0.PROF) or {}
  local function d(k) return (PR[k] or 0) - (P0[k] or 0) end
  local acct = string.format("menu: %d provider passes %.2f ms each, %d describes %.3f ms, %d makes %.3f ms, worst pass %.2f ms; context_menu seen in %d of %d frames",
    d("rows"), d("rows") > 0 and d("rows_ms") / d("rows") or 0, d("describes"), d("describes") > 0 and d("desc_ms") / d("describes") or 0,
    d("makes"), d("makes") > 0 and d("make_ms") / d("makes") or 0, PR.worst_ms or -1, seen.context_menu or 0, n)
  if c0 and c0.PROF then c0.PROF.worst_ms = 0 end
  local r = { tag = tag, n = n, frame = sum / n, worst = worst, scripts = scr / n, scrw = scrw, ui = uib / n, uiw = uibw,
              cm = (per.context_menu or 0) / n, cmw = perw.context_menu or 0,
              tm = (per.terminal or 0) / n, tmw = perw.terminal or 0, lp = (per.loot_panel or 0) / n, lpw = perw.loot_panel or 0,
              over33 = over33 }
  P("COST %s: %d frames (%.0f fps) · frame %.2f ms (worst %.1f) · scripts %.3f (worst %.2f, %d over 33) · ui %.3f (worst %.2f) · %s · top: %s · parts: %s",
    tag, n, n / secs, r.frame, worst, r.scripts, scrw, over33, r.ui, uibw, table.concat(w, ", "), table.concat(tl, ", "), table.concat(pt, ", "))
  P("COST %s: %s", tag, acct)
  SUMMARY[#SUMMARY + 1] = r
  return r
end
local function hot(tag, secs, keep_open)
  if (params.sample or 0) <= 0 or not perf.sampleScripts then return end
  perf.sampleScripts(true)
  perf.samples()
  local t0 = W()
  while W() - t0 < (secs or params.sample or 3) do
    yield(); talk(SR)
    if keep_open and not keep_open() then break end
  end
  local s = perf.samples() or {}
  perf.sampleScripts(false)
  local out = {}
  for _, e in ipairs(s) do
    if not OWN[e.script] then
      out[#out + 1] = string.format("%s:%s:%s %.1f ms", tostring(e.script), tostring(e.fn), tostring(e.line), e.ms or 0)
      if #out >= 12 then break end
    end
  end
  P("HOT %s (%.0f s): %s", tag, secs or params.sample or 3, table.concat(out, " ; "))
end

-- ── opening a piece's menu ──────────────────────────────────────────────────
local function target_of(sid, uid)
  local ST = findScript("structures")
  local n = ST.nodeOf(sid, uid)
  if not n then return nil end
  local w = n.worldPos
  return cm().resolve({ node = n, x = w.x, y = w.y, z = w.z, distance = 2 }, astro())
end
local function menu_hold(tag, sid, uid, sub)
  local c = cm()
  if c.isOpen() then c.close() end
  yield()
  local t = target_of(sid, uid)
  if not t then check("open_" .. tag, false, "piece %s:%s has no node", tostring(sid), tostring(uid)) return end
  local a = astro()
  local n = findScript("structures").nodeOf(sid, uid)
  local d = (a and n and a.distanceTo) and a:distanceTo(n) or -1
  local okc = c.openFor(t, c.actorNow())
  local _, title = c.entries()
  if not check("open_" .. tag, okc and c.isOpen(), "%s (%.1f m off): %s · %d rows", tag, d, tostring(title), #(c.entries() or {})) then return end
  local still = function() return c.isOpen() end
  hold("menu " .. tag, nil, still)
  hot("menu " .. tag, nil, still)
  if sub and c.isOpen() then
    local okp = c.press(sub)
    if okp and c.isOpen() then
      hold("menu " .. tag .. " > " .. sub, nil, still)
      hot("menu " .. tag .. " > " .. sub, nil, still)
    else
      P("no %s on %s", sub, tag)
    end
  end
  c.close()
end
local function term_hold(tag, sid, uid, pages)
  local tm = findScript("terminal")
  if not (tm and tm.openAt) then P("no terminal") return end
  tm.openAt(sid, uid)
  wait(0.3)
  if not check("term_" .. tag, tm.isOpen(), "terminal open at %s:%s", tostring(sid), tostring(uid)) then return end
  local still = function() return tm.isOpen() end
  for _, pg in ipairs(pages) do
    pcall(tm.page, pg)
    hold("terminal " .. tag .. " " .. pg, nil, still)
    hot("terminal " .. tag .. " " .. pg, nil, still)
  end
  tm.close()
end
local function loot_hold(tag, sid, uid)
  local lp = findScript("loot_panel")
  if not (lp and lp.openContainer) then P("no loot panel") return end
  lp.openContainer(sid, uid)
  wait(0.3)
  if not check("loot_" .. tag, lp.isOpen(), "loot panel on %s:%s", tostring(sid), tostring(uid)) then return end
  local still = function() return lp.isOpen() end
  hold("loot " .. tag, nil, still)
  hot("loot " .. tag, nil, still)
  lp.close()
end

-- pieces of a record by a test on their def
local function find_piece(rec, test, skip)
  local PB = findScript("parts_base")
  for _, p in ipairs(rec.bp or {}) do
    local d = PB.partInfo(p.id) or {}
    if test(d, p) and not (skip and skip[p.uid]) then return p.uid, p end
  end
  return nil
end

-- ── scenarios ───────────────────────────────────────────────────────────────
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
  SR = sr
  wait_for(function() talk(sr); local st = sr.state(); return not st.cutscene and not st.line and not st.choice and (gm.inputOwner == nil) end, 60, "control")
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
-- stand the crew 1.5 m above piece (sid, uid)'s foot (inside its structure's
-- reach; the menu closes past 40 m)
local function stand_at_piece(sid, uid, frames_)
  local ST = findScript("structures")
  local a = astro()
  for _ = 1, frames_ or 20 do
    local n = ST.nodeOf(sid, uid)
    if n and a then
      local w = n.worldPos
      local name = space.dominant(w.x, w.y, w.z)
      local b = name and space.body(name)
      if b then
        local px, py, pz = w.x - b.x, w.y - b.y, w.z - b.z
        local l = len(px, py, pz)
        a.x, a.y, a.z = w.x + px / l * 1.5 + 1.2, w.y + py / l * 1.5, w.z + pz / l * 1.5
        a.vx, a.vy, a.vz = 0, 0, 0
      end
    end
    yield()
  end
end

local function case_scn()
  local sr = stage("graveyard_shift")
  if not sr then return end
  local S = "Kerne Station"
  local ST = findScript("structures")
  local csid, cuid = sr.pieceOf({ struct = S, part = "reactorConsole" })
  if not check("console_piece", csid ~= nil, "the station stands (console %s:%s, %d pieces)", tostring(csid), tostring(cuid), csid and #ST.get(csid).bp or 0) then return end
  stand(sr, "mark:console", 30)
  wait(2)
  hold("closed at the console", 5)
  menu_hold("console", csid, cuid, "pi_insp")
  local rec = ST.get(csid)
  local s3, u3 = sr.pieceOf({ struct = S, uid = 116 })
  local s1, u1 = sr.pieceOf({ struct = S, uid = 114 })
  local s2, u2 = sr.pieceOf({ struct = S, uid = 147 })
  menu_hold("P-3 pump", s3, u3, "pi_insp")
  menu_hold("MU-1 valve", s1, u1)
  menu_hold("FW-2", s2, u2)
  local ls, lu = sr.pieceOf({ struct = S, part = "lightFitting" })
  if ls then menu_hold("light", ls, lu) end
  local wu = find_piece(rec, function(d) return d.piece == "wall" and not d.door end)
  if wu then menu_hold("wall", csid, wu) end
  local bu = find_piece(rec, function(d) return d.power and d.power.kind == "breaker" end)
  if bu then menu_hold("breaker", csid, bu) end
  local tu = find_piece(rec, function(d) return d.fl and d.fl.kind == "tank" end)
  if tu then menu_hold("tank", csid, tu) end
  local vu = find_piece(rec, function(d) return d.nuclear end)
  if vu then menu_hold("reactor part", csid, vu) end
  local ku = find_piece(rec, function(d) return d.container end)
  if ku then
    menu_hold("container", csid, ku)
    stand_at_piece(csid, ku, 20)
    loot_hold("container", csid, ku)
  end
  stand(sr, "mark:console", 30)
  term_hold("console", csid, cuid, { "REACTOR", "POWER", "FLUIDS", "LOG", "STATUS" })
end

local function case_hollis()
  local sr = stage("hollis")
  if not sr then return end
  local ST = findScript("structures")
  local rs = nil
  for _, r in ipairs(ST.list()) do if r.ru then rs = r end end
  if not check("ruin", rs ~= nil, "the camp stands (%s, %d pieces)", tostring(rs and rs.id), rs and #rs.bp or 0) then return end
  local u60 = sr.pieceOf({ struct = "Lindqvist Camp", uid = 60 })
  stand_at_piece(rs.id, 60, 30)
  wait(2)
  hold("closed in the camp", 5)
  local wu = find_piece(rs, function(d, p) return d.piece == "wall" and not d.door and (p.ri or 1) > 0 end)
  if wu then menu_hold("ruin wall", rs.id, wu, "pi_insp") end
  menu_hold("ruin knocked block", rs.id, 117)
  menu_hold("ruin terminal", rs.id, 60)
  local ku = find_piece(rs, function(d) return d.container end)
  if ku then
    menu_hold("ruin container", rs.id, ku)
    stand_at_piece(rs.id, ku, 20)
    loot_hold("ruin container", rs.id, ku)
  end
  stand_at_piece(rs.id, 60, 20)
  term_hold("ruin terminal", rs.id, 60, { "RUINLOG", "DATA" })
  local _ = u60
end

-- ── a 500-piece sandbox base ────────────────────────────────────────────────
local function new_save()
  local s = "slotip"
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", 1234)
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  local ns = findScript("menu_newsave")
  save.set("g_scale", (ns and ns.WORLD_SCALE) or 4)
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 300, "the world")
  clear_weather()
end
local function block(ST, k)
  local a = astro()
  local name = space.dominant(a.worldX, a.worldY, a.worldZ)
  local b = space.body(name)
  local px, py, pz = a.worldX - b.x, a.worldY - b.y, a.worldZ - b.z
  local r = len(px, py, pz)
  local U = { x = px / r, y = py / r, z = pz / r }
  local t = { x = -U.z, y = 0, z = U.x }
  local tl = len(t.x, t.y, t.z); if tl < 1e-3 then t = { x = 1, y = 0, z = 0 }; tl = 1 end
  t = { x = t.x / tl, y = t.y / tl, z = t.z / tl }
  local R0 = r - 1.0
  local o = { x = U.x * R0 + t.x * 25, y = U.y * R0 + t.y * 25, z = U.z * R0 + t.z * 25 }
  local rec = ST.newRecord(nil, name, o.x, o.y, o.z, U, t, "floor.steel", { name = "inspect block" })
  rec.bp = {}
  local uid = 0
  local function add(id, x, y, z, yaw)
    uid = uid + 1
    rec.bp[#rec.bp + 1] = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, mir = "", stage = 0 }
    return uid
  end
  for i = 0, k - 1 do
    for j = 0, k - 1 do
      local x, z = (i - k / 2) * 2, j * 2
      add(((i + j) % 5 == 0) and "floor.concrete" or "floor.steel", x, 0, z)
      add(((i * 7 + j) % 4 == 0) and "windowWall.steel" or "wall.steel", x, 0.2, z + 1, 0)
      add(((i + j * 3) % 6 == 0) and "doorWall.steel" or "wall.concrete", x + 1, 0.2, z, math.pi / 2)
    end
  end
  local want = { light = "lightFitting.steel", pump = "flPump.steel", valve = "flValve.steel", tank = "flTankWater.steel",
                  locker = "locker.steel", crate = "crate.steel" }
  local U2 = {}
  local k2 = 0
  for _, nm in ipairs({ "light", "pump", "valve", "tank", "locker", "crate" }) do
    k2 = k2 + 1
    U2[nm] = add(want[nm], 0.3 + k2 * 1.2, 0.2, 0.6)
  end
  for n = 1, 8 do add("lightFitting.steel", ((n % 4) - 2) * 2, 2.6, n * 2) end
  return rec, U2
end
local function case_base()
  new_save()
  local ST = findScript("structures")
  local rec, U2 = block(ST, 13)
  local id = ST.add(rec)
  ST.spawnNow(id)
  wait_for(function() return #(ST.nodesOf(id) or {}) >= #rec.bp - 4 end, 240, "the block's pieces")
  P("block %s: %d pieces, %d nodes; working pieces: %s", tostring(id), #rec.bp, #(ST.nodesOf(id) or {}),
    (function() local o = {}; for k, v in pairs(U2) do o[#o + 1] = k .. "=" .. v end; return table.concat(o, " ") end)())
  stand_at_piece(id, 1, 30)
  wait(3)
  hold("closed by the block", 5)
  menu_hold("base wall", id, 2, "pi_insp")
  menu_hold("base floor", id, 1)
  menu_hold("base door", id, 3 * 4 + 3)
  for _, nm in ipairs({ "light", "pump", "valve", "tank", "locker", "crate" }) do
    if U2[nm] then menu_hold("base " .. nm, id, U2[nm], "pi_insp") end
  end
  ST.remove(id)
  wait(1)
end

local MAIN = function()
  NODE.persistent = true
  perf.enable(true)
  wait(1)
  if CASE == "scn" then case_scn()
  elseif CASE == "hollis" then case_hollis()
  elseif CASE == "base" then case_base() end
  P("TABLE tag | frame ms | scripts ms (worst) | context_menu ms (worst) | terminal | loot_panel | ui ms")
  for _, r in ipairs(SUMMARY) do
    P("TABLE %s | %.2f | %.3f (%.2f) | %.3f (%.2f) | %.3f (%.2f) | %.3f (%.2f) | %.3f", r.tag, r.frame, r.scripts, r.scrw, r.cm, r.cmw, r.tm, r.tmw, r.lp, r.lpw, r.ui)
  end
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
