-- ECONPROBE (scratch only): the economy's panels in the real game, for
-- `floptle shot` (tools/perf/econshot.sh): the Ops Board with ground work on
-- it, the Commerce Depot with a rover-load on the books (the freight rate),
-- and the builder's catalogue prices.
--
--   case board    First Steps done: the board's ground work, one selected
--   case depot    the depot with pack + warehouse goods, some of it freight
--   case catalog  the VAB builder (its catalogue shows the part prices)
--
-- strs: case; params: slot (13), fresh (1 = make the save new, as the
-- new-save panel does), quit (0 holds for the shot).
defaults = { slot = 13, seed = 1911564384, fresh = 0, quit = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("ECON %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "astro"
local NODE, CO
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
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false } end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  if (params.fresh or 0) > 0 then
    terrain.deleteSaveDir("saves/" .. s .. "/terrain")
    if save.deleteSlot then save.deleteSlot(s) end
    save.slot(s)
    save.set("g_seed", math.floor(params.seed))
    for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                        g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
    local ns = findScript("menu_newsave")
    save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
    P("created %s", s)
  else
    save.slot(s)
    P("continuing %s (seed %s)", s, tostring(save.get("g_seed")))
  end
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  P("world ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function rocket()
  local l, y, u = {}, 0, 0
  local function add(id, h, st)
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = st or 0 }
    y = y + h
  end
  add("engineM", 1.6); add("tankM", 1.5); add("tankS", 1.0); add("locker", 0.5); add("pod", 0.8); add("chute", 0.34, 1)
  return l
end

local function launch()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  local a = find("Astronaut")
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  local B = findScript("builder")
  wait(1)
  local bp = rocket()
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  P("builder: %d parts", B.partCount or -1)
  return B, BH, bp
end


local PICK = nil
local function board_case()
  local pd = save.get("prog.done") or {}
  pd.first_steps = true
  save.set("prog.done", pd)
  local d = save.get("mission.done") or {}
  d.firstflight = true
  save.set("mission.done", d)
  local mi = findScript("missions")
  -- the board is the Command Centre's console: stand in the building
  local cc = wait_for(function() return find("FacCommand") end, 60, "the Command Centre")
  local a = find("Astronaut")
  local p = cc:toWorld(vec3(0, 1.5, 5))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(3)                                   -- the board refills once a second
  local ob = findScript("ops_board")
  local pick
  for _, s in ipairs(mi.offers()) do
    P("OFFER %s | %s | $%d%s", s.id, s.title, s.reward or 0, s.ground and " | ground" or "")
    if s.ground and s.kind == "bulk" then pick = s.id end
    if s.ground and not pick then pick = s.id end
  end
  ob.openBoard()
  wait(0.5)
  if pick then ob.selectContract(pick) end
  PICK = pick
  P("RESULT board: %s (selected %s, tier line: %s)", pick and "PASS" or "FAIL", tostring(pick), mi.tierLine())
end

local function depot_case()
  local inv = findScript("inventory")
  local co = findScript("company")
  local dep = wait_for(function() return find("FacDepot") end, 60, "the depot")
  local a = find("Astronaut")
  local p = dep:toWorld(vec3(0, 1.5, 5))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2)
  inv.add("astro", "iron", 10)
  inv.add("astro", "timber", 12)
  inv.add("base", "iron", 60)
  inv.add("base", "silica", 30)
  save.set("depot.freight", { iron = 60, silica = 30 })
  local fm = findScript("facility_menu")
  fm.openMenu("FacDepot")
  wait(1)
  P("RESULT depot: %s", tostring(fm.depotAction and fm.depotAction()))
end

local function catalog_case()
  launch()
  wait(3)
  local B = findScript("builder")
  P("RESULT catalog: builder up with %d parts", B and B.partCount or -1)
end

local MAIN = function()
  boot()
  wait(4)
  if CASE == "board" then board_case()
  elseif CASE == "depot" then depot_case()
  else catalog_case() end
  P("HOLD")
  if (params.quit or 0) > 0 then app.quit() end
  while true do
    -- the board closes itself while the crew isn't on foot (a load, a
    -- curtain): keep it up for the picture
    if CASE == "board" then
      local ob = findScript("ops_board")
      if ob and not ob.isOpen() then ob.openBoard(); if PICK then ob.selectContract(PICK) end end
    elseif CASE == "depot" then
      local fm = findScript("facility_menu")
      if fm and fm.isOpen and not fm.isOpen() then fm.openMenu("FacDepot") end
    end
    yield()
  end
end

function update(node, dt)
  if not CO then
    NODE = node
    CASE = params.case or "board"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
