-- SANDBOXPROBE: the GAME MODE and CREW SAFETY options of the new-save panel in
-- the real game (tools/perf/sandboxshots.sh; scripts/menu_newsave.lua,
-- company.lua, research.lua, crew.lua).
--
--   1. the menu: the new-save panel on an empty slot, as it opens (Career +
--      Permadeath) and with Sandbox + Invincible picked; CREATE makes the save
--      exactly as a click would
--   2. the Sandbox: funds read ∞ and reputation the top, the depot sells the
--      TL-5 Surveyor and the balance is still ∞ after, the Skipper is unlocked
--   3. Invincible: dropped from 40 m (well past the 13 m/s that kills) —
--      hp 1.0, still on foot, still in control; a full-charge bolt in the chest
--      — hp 1.0, no chip
--   4. pictures: the HUD (∞ / MAX), Settings ▸ Agency (the crew-safety switch)
--
-- Pictures (1280×720) to user://sandboxshots/, lines "SBX ", one RESULT a check.
defaults = { quit = 1, slot = 17, seed = 5150, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("SBX %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://sandboxshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
-- the ground `d` m from the base along bearing `ang` (planet frame)
local function spot(d, ang)
  local b = home()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R0 = len(bx, by, bz)
  local u = { x = bx / R0, y = by / R0, z = bz / R0 }
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, a))
  local t2 = unit(cross(u, t1))
  local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                   z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  local k = d / R0
  local dir = unit({ x = u.x * math.cos(k) + t.x * math.sin(k), y = u.y * math.cos(k) + t.y * math.sin(k),
                     z = u.z * math.cos(k) + t.z * math.sin(k) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 150)
  return gr and { dir = dir, r = gr } or nil
end
local function at(s, h)
  local b = home()
  return b.x + s.dir.x * (s.r + h), b.y + s.dir.y * (s.r + h), b.z + s.dir.z * (s.r + h)
end

local function main()
  NODE.persistent = true
  local s = "slot" .. math.floor(params.slot)
  -- 1. the menu's new-save panel
  scene.load("menu")
  yield()
  local ns = wait_for(function() return findScript("menu_newsave") and findScript("emblem") and findScript("menu_newsave") end, 30, "the menu")
  if not ns then R("menu", false, "no menu"); return end
  hold(1.0)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  ns.openFor(math.floor(params.slot))
  wait_for(function() local ed = ns.editor(); return ed and ed.tex end, 15, "the emblem preview")
  hold(1.0)
  local m0, s0 = ns.options()
  shot("newsave_career")
  frames(3)
  ns.setOptions("sandbox", "invincible")
  hold(0.5)
  shot("newsave_sandbox")
  frames(3)
  R("panel", m0 == "career" and s0 == "death" and select(1, ns.options()) == "sandbox", "opens on %s/%s; picked %s/%s",
    tostring(m0), tostring(s0), ns.options())
  wait_for(function() return pending == 0 end, 10, "the panel pictures")
  ns.press("create")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  hold(3.0)
  local co, C, inv, rs = findScript("company"), findScript("crew"), findScript("inventory"), findScript("research")
  local pw, SV = findScript("planet_walker"), findScript("surveyor")
  R("stored", save.get("game.mode") == "sandbox" and save.get("crew.safety") == "invincible" and C.invincible(),
    "game.mode %s crew.safety %s crew.death %s", tostring(save.get("game.mode")), tostring(save.get("crew.safety")),
    tostring(save.get("crew.death")))
  -- 2. the Sandbox
  local b0 = co.money(co.balance())
  local cost = nil
  for _, e in ipairs(inv.shopList()) do if e.id == "surveyor" then cost = e.cost end end
  local ok, why = inv.buyItem("crew:1", "surveyor", 1)
  local b1 = co.money(co.balance())
  R("funds", b0 == "∞" and b1 == "∞" and ok, "before %s; the Surveyor ($%s) bought %s (%s); after %s; ledger: %s",
    b0, tostring(cost), tostring(ok), tostring(why), b1, tostring((co.ledgerLines(1) or {})[1]))
  R("rep", co.rep() == co.REP_MAX and co.standing().name == "Legend" and rs.isUnlocked("skipper") and rs.isUnlocked("dockPort"),
    "rep %d (%s); skipper %s dockPort %s; advance %s", co.rep(), co.standing().name, tostring(rs.isUnlocked("skipper")),
    tostring(rs.isUnlocked("dockPort")), tostring(co.advanceReady()))
  -- 3a. a 40 m drop, 140 m out
  local id = C.activeId()
  local sp = spot(140, 0.9)
  local a = find("Astronaut")
  local peak, landed = 0, false
  if sp then
    a.x, a.y, a.z = at(sp, 40)
    a.vx, a.vy, a.vz = 0, 0, 0
    hold(0.3)
    local t0 = W()
    wait_for(function()
      local b = home()
      local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
      local vr = -(a.vx * u.x + a.vy * u.y + a.vz * u.z)
      peak = math.max(peak, vr)
      if W() - t0 > 1.0 and pw.grounded and vr < 1 then landed = true; return true end
    end, 20, "the landing")
    hold(1.5)
  end
  local r = C.get(id)
  R("drop", landed and r.hp == 1 and r.status == "afoot" and C.activeId() == id and peak > 13,
    "40 m: peak fall %.1f m/s (kills from %.0f in Permadeath); hp %.2f status %s active #%s → #%s; lastDeath %s",
    peak, C.defaults.impact_kill, r.hp or -1, tostring(r.status), tostring(id), tostring(C.activeId()), tostring(C.lastDeath))
  -- 3b. a full-charge bolt in the chest, from 6 m up and 4 m out
  a = find("Astronaut")
  local b = home()
  local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  local side = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
  local cx, cy, cz = a.x + u.x * 0.3, a.y + u.y * 0.3, a.z + u.z * 0.3
  local ox, oy, oz = cx + u.x * 6 + side.x * 4, cy + u.y * 6 + side.y * 4, cz + u.z * 6 + side.z * 4
  local n0 = SV.stats.hits
  SV.fireFrom(ox, oy, oz, cx - ox, cy - oy, cz - oz, { charge = 1.0, by = "a probe's hostile" })
  wait_for(function() return SV.stats.hits > n0 end, 3, "the bolt")
  frames(3)
  local h = SV.lastHit or {}
  local chips = findScript("crew_alerts_hud") and findScript("crew_alerts_hud").chipsOf(C.alerts()) or {}
  r = C.get(id)
  R("shot", h.kind == "crew" and h.id == id and r.hp == 1 and #chips == 0,
    "hit %s #%s dmg %.2f → hp %s (%s); hp now %.2f; chips %d", tostring(h.kind), tostring(h.id), h.dmg or -1,
    tostring(h.hp), tostring(h.why), r.hp or -1, #chips)
  -- 3c. an empty suit: the gauge runs out, nobody blacks out
  if pw.setSuitAir then pw.setSuitAir(0) end
  hold(1.0)
  R("air", not pw.downed and C.get(id).hp == 1, "suit air 0: source %s airLeft %.0f downed %s", tostring(pw.airSource),
    pw.airLeft or -1, tostring(pw.downed))
  if pw.setSuitAir then pw.setSuitAir(1) end
  -- 4. the HUD, Settings ▸ Agency
  hold(1.0)
  shot("hud_sandbox")
  frames(3)
  local pm, st = findScript("pause_menu"), findScript("settings")
  if pm and st then
    pm.openMenu()
    pm.showPage("settings")
    st.showTab("agency")
    frames(90)  -- (the pause menu pauses the game clock: count frames)
    shot("settings_agency")
    frames(3)
    pm.close()
  end
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 then
      if app.quit then app.quit() end
    end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
