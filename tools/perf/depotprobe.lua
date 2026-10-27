-- DEPOTPROBE: the economy round of 2026-10-27 in the real game, on a NEW
-- Career save (tools/perf/depotshots.sh; scripts/inventory_panel.lua,
-- items.lua, inventory.lua, supply_crates.lua, facility_menu.lua,
-- missions.lua, crew.lua, pause_menu.lua, menu_ng_button.lua).
--
--   1. the depot's BUY counter with an item's CARD up: the rifle, then the
--      Medkit — the turning picture (render target), the description, the
--      numbers; the buy key on the card buys
--   2. the SELL counter's GEAR rows: a Medkit sold back for 60 %
--   3. the SUPPLY CRATES: five laid round the base; at the depot pair the
--      "Open the supply crate · E" prompt; the crate open in the pack's panel,
--      gear and ore stowed into it; the save holds the contents
--   4. the bleed-out clock (180–60 s), the relay programme (10 / 25 %), the
--      network numbers as the game reads them
--   5. QUIT: the title page's Quit button (save, then app.quit) — the shell
--      times how long the process takes to end after it
--
-- Pictures (1280×720) to user://depotshots/, lines "DPP ", one RESULT a check.
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4, menu_quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("DPP %7.2f " .. fmt, W() - W0, ...)) end
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
    if bytes then assets.writeBytes("user://depotshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function wpos(n) return n.worldPos or vec3(n.worldX, n.worldY, n.worldZ) end
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
local function face(tx, ty, tz, pitch)
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local b = home()
  local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  local ex, ey, ez = a.x + u.x * 1.5, a.y + u.y * 1.5, a.z + u.z * 1.5
  local dx, dy, dz = tx - ex, ty - ey, tz - ez
  local v = dx * u.x + dy * u.y + dz * u.z
  local hx, hy, hz = dx - u.x * v, dy - u.y * v, dz - u.z * v
  local hl = len(hx, hy, hz)
  if cam and cam.face and hl > 1e-3 then cam.face(hx / hl, hy / hl, hz / hl, pitch or -0.18) end
end
-- Stand the avatar `d` m from a world point, on the side toward `from`, on the ground.
local function stand_near(p, from, d)
  local C = findScript("crew")
  local b = home()
  local a = find("Astronaut")
  local u = unit({ x = p.x - b.x, y = p.y - b.y, z = p.z - b.z })
  local o = { x = from.x - p.x, y = from.y - p.y, z = from.z - p.z }
  local k = o.x * u.x + o.y * u.y + o.z * u.z
  local t = unit({ x = o.x - u.x * k, y = o.y - u.y * k, z = o.z - u.z * k })
  local px, py, pz = p.x + t.x * d, p.y + t.y * d, p.z + t.z * d
  local pu = unit({ x = px - b.x, y = py - b.y, z = pz - b.z })
  local gr = ground_r(b, pu.x, pu.y, pu.z, len(px - b.x, py - b.y, pz - b.z) + 30)
  if not gr then return false end
  a.x, a.y, a.z = b.x + pu.x * (gr + 1.1), b.y + pu.y * (gr + 1.1), b.z + pu.z * (gr + 1.1)
  a.vx, a.vy, a.vz = 0, 0, 0
  if C and C.quietMonitors then C.quietMonitors(1.0) end
  return true
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function main()
  boot()
  hold(3.0)
  local inv, co, I, ip, fm = findScript("inventory"), findScript("company"), findScript("items"), findScript("inventory_panel"),
    findScript("facility_menu")
  co.earn(6000, "probe")
  -- ── 1. the depot's item card ─────────────────────────────────────────────
  local dep = find("FacDepot")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local b = home()
  local mid = { x = b.x + bx, y = b.y + by, z = b.z + bz }
  local dw = wpos(dep)
  stand_near(dw, mid, 11)
  hold(1.0)
  dw = wpos(dep)
  face(dw.x, dw.y, dw.z)
  hold(0.5)
  P("at the depot: %.1f m", find("Astronaut"):distanceTo(dep))
  ip.openCounters("buy")
  ip.detailId = "surveyor"
  local ready = wait_for(function() return ip.previewReady() and ip.previewId == "surveyor" end, 15, "the rifle on the stand")
  hold(1.5)
  -- side-on for the picture
  -- (the camera sits at 0.78 sun + 0.45 side + 0.32 up of the stand: the long
  -- axis is across the view where 0.45 cos a + 0.78 sin a ≈ 0)
  wait_for(function()
    local a = ip.previewSpin and ip.previewSpin() or 0
    return math.abs(0.45 * math.cos(a) + 0.78 * math.sin(a)) < 0.12
  end, 10, "the rifle side-on")
  shot("depot_card_rifle")
  frames(3)
  local host = find("Item Card Host")
  local he = host and host:getcomponent("UiElement")
  R("card_rifle", ready ~= nil and ip.atCounter and ip.shownId == "surveyor" and he and he.visible, "preview %s, shown %s, at counter %s, card host %s",
    tostring(ip.previewReady()), tostring(ip.shownId), tostring(ip.atCounter), tostring(he and he.visible))
  ip.detailId = "medkit"
  ready = wait_for(function() return ip.previewReady() and ip.previewId == "medkit" end, 15, "the medkit on the stand")
  hold(1.2)
  shot("depot_card_medkit")
  frames(3)
  local c = I.card("medkit")
  local rows = {}
  for _, r in ipairs(c.rows) do rows[#rows + 1] = r[1] .. "=" .. r[2] end
  R("card_medkit", ready ~= nil and #c.rows >= 6, "%s", table.concat(rows, " | "))
  local b0 = co.balance()
  ip.buyGear("medkit")
  local b1 = co.balance()
  R("buy", b0 - b1 == 150 and inv.itemCount("astro", "medkit") >= 1, "$%d → $%d, %d medkit(s) in the pack", b0, b1,
    inv.itemCount("astro", "medkit"))
  -- ── 2. the SELL counter's gear ────────────────────────────────────────────
  ip.counter = "sell"
  hold(0.8)
  shot("depot_sell_gear")
  frames(3)
  b0 = co.balance()
  local n = ip.sellGear("astro", "medkit")
  b1 = co.balance()
  R("sell", n == 1 and b1 - b0 == 90, "sold %d medkit for $%d", n, b1 - b0)
  ip.open = false
  ip.detailId = nil
  hold(0.5)
  -- ── 3. the supply crates ──────────────────────────────────────────────────
  local sc = wait_for(function() return findScript("supply_crates") end, 20, "the crates library")
  local placed = wait_for(function() return sc and sc.placed == #sc.LAYOUT and sc.placed end, 40, "five crates")
  local L = sc and sc.list() or {}
  local where = {}
  for _, e in ipairs(L) do
    if e.node then
      local p = wpos(e.node)
      local q = terrain.query(p.x, p.y, p.z)
      where[#where + 1] = string.format("%s %.1f m from the depot, %.2f m over the ground", e.name, e.node:distanceTo(dep), q or -1)
    end
  end
  R("crates", placed == 5, "%s", table.concat(where, "; "))
  local cn = L[1] and L[1].node
  if cn then
    local cp = wpos(cn)
    stand_near(cp, mid, 1.9)
    hold(1.2)
    cp = wpos(cn)
    face(cp.x, cp.y, cp.z, -0.35)
    hold(1.0)
    shot("crate_prompt")
    frames(3)
    R("prompt", fm.prompting() == true, "facility_menu.prompting %s, astro→crate %.2f m", tostring(fm.prompting()),
      find("Astronaut"):distanceTo(cn))
    -- stow some kit and some ore
    inv.addItem("astro", "medkit", 2, { force = true })
    inv.add("astro", "iron", 8)
    sc.open(L[1].cid)
    hold(0.6)
    R("open", ip.open == true and ip.targetId == L[1].cid, "panel open %s on %s", tostring(ip.open), tostring(ip.targetId))
    ip.putItem("medkit")
    ip.moveStack("iron")
    hold(0.4)
    ip.putItem("laser")
    hold(0.8)
    shot("crate_panel")
    frames(3)
    local cid = L[1].cid
    R("stowed", inv.itemCount(cid, "medkit") == 1 and inv.count(cid, "iron") == 8 and inv.itemCount(cid, "laser") == 1,
      "%s: %s; save inv.gear.%s = %s", cid, inv.lineFull(cid), cid, tostring(save.get("inv.gear." .. cid) and "set" or "nil"))
    ip.takeItem("laser")
    R("take", inv.itemCount(cid, "laser") == 0 and inv.itemCount("astro", "laser") == 1, "laser back in the pack")
    ip.closePanel()
    hold(0.5)
    -- a wider look at the depot pair (the planet moved: read the crate again)
    cp = wpos(cn)
    mid = { x = home().x + bx, y = home().y + by, z = home().z + bz }
    stand_near(cp, mid, 5)
    hold(1.0)
    cp = wpos(cn)
    face(cp.x, cp.y, cp.z, -0.25)
    hold(0.8)
    shot("crate_world")
    frames(3)
  end
  -- ── 4. the rules as the running game reads them ──────────────────────────
  local C, mi, net = findScript("crew"), findScript("missions"), findScript("comms")
  R("bleed", C.bleedSecs("impact", 1.0) == 180 and C.bleedSecs("impact", 1.6) == 60, "%.0f–%.0f s",
    C.bleedSecs("impact", 1.0), C.bleedSecs("impact", 1.6))
  local rn = mi.progById("relay_net")
  R("relay", rn and #rn.goals == 2 and rn.goals[2].frac == 0.25, "relay_net goals %s; sky %s",
    rn and (rn.goals[1].frac .. "/" .. rn.goals[2].frac) or "-",
    (function() local m = mi.progById("sky"); return m and (m.goals[2].frac .. "/" .. m.goals[3].frac) or "-" end)())
  local hn = mi.progHome and mi.progHome()
  local cv = net and net.coverage and net.coverage(hn) or {}
  P("NET home %s ground %.3f sky %.3f samples %s ready %s; progNet ground %.3f sky %.3f orbit %s",
    tostring(hn), cv.ground or -1, cv.sky or -1, tostring(cv.samples), tostring(cv.ready),
    mi.progNet.ground or -1, mi.progNet.sky or -1, tostring(mi.progNet.orbit))
  R("geode", mi.isGeodeFind("crystal", 8) and not mi.isGeodeFind("crystal", 1), "rule live")
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
  -- ── 5. quit from the title page ───────────────────────────────────────────
  if params.menu_quit == 1 then
    local pm = findScript("pause_menu")
    R("pause_quit_fn", pm and pm.quitToDesktop ~= nil, "pause menu has Save and quit to desktop")
    scene.load("menu")
    yield()
    local btn = wait_for(function()
      for _, s in ipairs(findScripts("menu_ng_button") or {}) do
        if s.params and s.params.role == "quit" then return s end
      end
    end, 30, "the title page's Quit")
    hold(1.0)
    P("QUIT pressing the title page's Quit (wall %.2f)", W())
    if btn and btn.clicked then btn.clicked(btn.node) end
    -- if the process is still here a few seconds on, the shell sees it
    hold(8.0)
    P("QUIT still running 8 s after Quit")
  end
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
