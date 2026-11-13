-- BASELOOPPROBE: the hands-on base loop in the real game, on a NEW Career
-- save (tools/perf/baseloopprobe.sh, MODE=…).
--
--   small   the three small fixes of playtest 11-12b: the depot's SELL and BUY
--           lists scroll (a full warehouse; the list's height, then scrolled),
--           a sale studies what it sells, the dead can't take their own pack
--
-- Pictures (1280×720) to user://baseloopshots/, lines "BLP ", one RESULT a check.
defaults = { quit = 1, slot = 23, seed = 5150, scale = 4 }
MODE = "@MODE@"

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("BLP %7.2f " .. fmt, W() - W0, ...)) end
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
    if bytes then assets.writeBytes("user://baseloopshots/" .. name .. ".png", bytes); P("SHOT %s", name)
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


local function ui_el(name)
  local n = find(name)
  return n and n.getcomponent and n:getcomponent("UiElement") or nil, n
end
local function rect_h(n)
  if not (n and n.uiRect) then return -1 end
  local ok, x, y, w, h = pcall(n.uiRect, n)
  if not ok then return -1 end
  if type(x) == "table" then return x.h or x[4] or -1 end
  return h or -1
end

-- ── small: the depot's lists, sold = studied, the dead and their pack ───────
local function run_small()
  local inv, co, ip, fm, rs, mats = findScript("inventory"), findScript("company"), findScript("inventory_panel"),
    findScript("facility_menu"), findScript("research"), findScript("materials")
  co.earn(6000, "probe")
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
  -- a full warehouse: every material in the registry
  local ids = mats.list()
  local n = 0
  for _, id in ipairs(ids) do if inv.add("base", id, 3) > 0 then n = n + 1 end end
  P("warehouse: %d kinds", n)
  ip.openCounters("sell")
  hold(1.2)
  shot("small_sell_top")
  frames(3)
  local el, node = ui_el("CounterList")
  local panel = find("Inventory Panel")
  local sh = camera.screenRect and select(4, camera.screenRect()) or 720
  P("sell list: element %s, list h %.0f, panel h %.0f, screen h %.0f", tostring(el ~= nil), rect_h(node), rect_h(panel), sh or -1)
  R("sell_fits", el ~= nil and rect_h(panel) > 0 and rect_h(panel) <= (sh or 720), "panel %.0f px of a %.0f px screen with %d kinds", rect_h(panel), sh or -1, n)
  if el then el.scrollY = 600 end
  hold(0.6)
  local y = el and el.scrollY or -1
  shot("small_sell_scrolled")
  frames(3)
  R("sell_scrolls", (tonumber(y) or 0) > 100, "scrollY %.0f after asking for 600", tonumber(y) or -1)
  ip.counter = "buy"
  hold(0.8)
  shot("small_buy_top")
  frames(3)
  el = ui_el("CounterList")
  if el then el.scrollY = 400 end
  hold(0.6)
  shot("small_buy_scrolled")
  frames(3)
  R("buy_fits", rect_h(panel) > 0 and rect_h(panel) <= (sh or 720), "panel %.0f px; scrollY %.0f", rect_h(panel), el and tonumber(el.scrollY) or -1)
  ip.open = false
  hold(0.4)
  -- the depot's own panel (the per-material rows)
  pcall(fm.openMenu, "FacDepot")
  hold(1.0)
  shot("small_depot_panel")
  frames(3)
  local fp = find("Facility Panel")
  R("depot_panel_fits", rect_h(fp) <= (sh or 720), "facility panel %.0f px, open %s", rect_h(fp), tostring(fm.isOpen and fm.isOpen()))
  if fm.close then pcall(fm.close) end
  hold(0.3)
  -- sold = studied
  local pick = nil
  for _, id in ipairs(ids) do if not rs.studied()[id] and inv.count("base", id) > 0 then pick = id break end end
  local p0 = rs.points()
  local msg = pick and fm.depotSell(pick) or "nothing unstudied"
  local st = pick and rs.studied()[pick]
  R("sold_studied", st ~= nil and st.n == 3 and rs.points() > p0, "%s: %s; studied n %s, RP %d → %d", tostring(pick), tostring(msg),
    tostring(st and st.n), p0, rs.points())
  -- the dead and their pack
  local C, sv = findScript("crew"), findScript("salvage")
  inv.add("astro", "iron", 6)
  local id = C.activeId()
  local a = find("Astronaut")
  -- away from the depot, on open ground
  stand_near({ x = mid.x, y = mid.y, z = mid.z }, dw, 60)
  hold(1.5)
  C.kill(id, "probe", "by the probe")
  frames(4)
  local L = sv.list()
  local crate = L[#L]
  local kg0 = crate and inv.mass(sv.containerOf(crate.id)) or -1
  local prompt, took = false, 0
  local t1 = W() + 1.6
  while W() < t1 do
    if sv.prompting() then prompt = true end
    if crate then local m = sv.recover(crate.id); took = took + (m or 0) end
    yield()
  end
  shot("small_death_hold")
  frames(3)
  local kg1 = crate and inv.mass(sv.containerOf(crate.id)) or -1
  R("dead_no_recover", crate ~= nil and C.dying() == true and not prompt and took == 0 and math.abs(kg1 - kg0) < 1e-6,
    "crate %s, %.1f kg before, %.1f kg after, prompt %s, dying %s", tostring(crate and crate.id), kg0, kg1, tostring(prompt), tostring(C.dying()))
  -- the handoff, then the next member walks up and takes it
  wait_for(function() return not C.dying() and not C.deathCurtain end, 20, "the handoff")
  hold(1.0)
  local nid = C.activeId()
  if crate and nid and nid ~= id then
    local c = sv.list()[#sv.list()]
    local cw = c and { x = c.x, y = c.y, z = c.z } or nil
    if cw then stand_near(cw, mid, 1.5); hold(1.5) end
    shot("small_next_recovers")
    frames(3)
    local pr = sv.prompting()
    local moved = sv.recover(crate.id)
    R("next_recovers", (moved or 0) > 0, "member %s → %s, prompt %s, %.1f kg back", tostring(id), tostring(nid), tostring(pr), moved or -1)
  else
    R("next_recovers", false, "no next member (active %s)", tostring(nid))
  end
end

local function main()
  boot()
  hold(3.0)
  if MODE == "small" then run_small()
  else P("unknown mode %s", MODE) end
  P("DONE fails %d", FAILS)
  hold(0.5)
  while pending > 0 do yield() end
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
