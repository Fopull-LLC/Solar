-- CREWUIPROBE: the crew presentation's panels, in the real game
-- (docs/crew-and-items.md §5.6, §2.2, §2.3; WS2). Run by tools/perf/crewuishot.sh.
--
--   case vab         a fresh save, three crew; in the VAB a Pod Mk1 under a
--                    Command Seat over a Stowage Locker: member #1 in the pod
--                    (the default), #2 dragged — seatMember — into the seat,
--                    a Repair Kit and a Relay Beacon planned into the locker;
--                    the inspector on its CREW tab
--   case roster      the Astronaut Complex, ROSTER tab, standing in the
--                    Command Centre
--   case applicants  …its APPLICANTS tab
--   case memorial    member #2 patched dead (impact, 17 m/s, on the home
--                    world, Kestrel I) and the MEMORIAL tab
--
-- One `CREWUI RESULT <case>: PASS|FAIL …` line; then HOLD (the shot is taken
-- by `floptle shot --after`). params: slot (15), seed, quit.
defaults = { slot = 15, seed = 1911564384, quit = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("CREWUI %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "vab"
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
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  local ns = findScript("menu_newsave")
  save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
  P("created %s", s)
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  P("world ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- At least three members (WS1's starters; hired here if the roster is short).
local function crew3()
  local c = wait_for(function() return findScript("crew") end, 30, "the crew library")
  local co = findScript("company")
  if co and co.earn then co.earn(40000, "probe") end
  local n = #(c.roster() or {})
  while n < 3 do
    local id, why = c.hire(1)
    P("hired %s (%s)", tostring(id), tostring(why))
    if not id then break end
    n = n + 1
  end
  local names = {}
  for _, r in ipairs(c.roster()) do names[#names + 1] = string.format("#%d %s [%s]", r.id, r.name, r.status) end
  P("roster: %s", table.concat(names, ", "))
  return c
end

local function rocket()
  local l, y, u = {}, 0, 0
  local function add(id, h)
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = 0 }
    y = y + h
  end
  add("engineM", 1.6); add("tankS", 1.0); add("locker", 0.5); add("pod", 0.8); add("seat", 1.3)
  return l
end

local function vab_case()
  local c = crew3()
  local inv = findScript("inventory")
  -- something in the warehouse to plan from
  if inv and inv.buyItem then
    inv.buyItem("base", "repairkit", 3)
    inv.buyItem("base", "beacon", 4)
    inv.buyItem("base", "flag", 2)
  end
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
  wait(1)
  local bc = wait_for(function() return findScript("builder_crew") end, 10, "builder_crew")
  local ins = findScript("builder_inspector")
  if not bc then P("RESULT vab: FAIL no builder_crew script in the overlay") return end
  bc.sync(true)
  local uid = {}
  for _, u in ipairs(B.partUids()) do uid[B.partIdOf(u)] = u end
  local plan = bc.seatPlan()
  local cmd = plan[uid.pod] and plan[uid.pod][1]
  P("default plan: pod uid %s → %s", tostring(uid.pod), tostring(cmd))
  -- the second member into the open seat (the drop's own call)
  local second
  for _, r in ipairs(c.roster()) do if r.id ~= cmd and r.status == "base" and not second then second = r.id end end
  local okSeat, why = bc.seatMember(second, uid.seat, 1)
  P("seat #%s in the Command Seat: %s %s", tostring(second), tostring(okSeat), tostring(why))
  -- a refused drop (no double booking)
  local okTwice, why2 = bc.seatMember(second, uid.pod, 1)
  P("seat #%s again in the pod: %s (%s)", tostring(second), tostring(okTwice), tostring(why2))
  -- the locker plan
  local st = bc.state()
  st.sel = cmd
  local m1 = bc.moveOne("repairkit", "stock", uid.locker)
  local m2 = bc.moveOne("beacon", "stock", uid.locker)
  local m3 = bc.moveOne("beacon", "stock", uid.locker)
  local m4 = bc.moveOne("repairkit", "stock", "pack")
  P("locker plan: %s %s %s; a kit into #%s's pack: %s", tostring(m1), tostring(m2), tostring(m3), tostring(cmd), tostring(m4))
  local lp = bc.lockerPlanMap()[uid.locker] or {}
  ins.setTab("CREW")
  wait(1.5)
  local blk = bc.launchBlock()
  local chk = B.launchCheck and B.launchCheck()
  local seated = bc.seatedIds(bc.seatPlan())
  local good = cmd ~= nil and okSeat and not okTwice and #seated == 2 and (lp.repairkit or 0) == 1 and (lp.beacon or 0) == 2
    and blk == nil
  P("RESULT vab: %s (seated %d, commander %s, locker kit %s beacons %s, block %s, builder check block %s, shipyard.crew %d entries)",
    good and "PASS" or "FAIL", #seated, tostring(cmd), tostring(lp.repairkit), tostring(lp.beacon), tostring(blk),
    tostring(chk and chk.block), #(save.get("shipyard.crew") or {}))
  -- the block, read once with the plan emptied, then put back
  local keep = save.get("shipyard.crew")
  save.set("shipyard.crew", {})
  P("RESULT vab-block: %s (%s)", bc.launchBlock() and "PASS" or "FAIL", tostring(bc.launchBlock()))
  save.set("shipyard.crew", keep)
  bc.sync(true)
  -- the pointer off the plate, and the stand framed
  input.simulate { mouse = { 500, 400 } }
end

local function stand_in_cc()
  local cc = wait_for(function() return find("FacCommand") end, 60, "the Command Centre")
  local a = find("Astronaut")
  local p = cc:toWorld(vec3(0, 1.5, 5))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(3)
end

local function panel_case(tab)
  local c = crew3()
  -- one of them out on foot elsewhere would need WS1's CrewBody; the roster
  -- shows the three as the save has them
  if tab == "MEMORIAL" then
    local home = save.get("base.body")
    local st = (space and space.time and space.time()) or 0
    local dp = findScript("deployables")
    c.patch(2, { status = "dead", died = { st = st, date = dp and dp.dateOf and dp.dateOf(st) or nil, cause = "impact",
                                           detail = "17 m/s", body = home, craft = "Kestrel I" } })
    local r = c.get(2)
    c.patch(2, { flights = 3, eva_s = 1260, flags = 1 })
    P("patched #2 %s dead: %s", tostring(r and r.name), tostring(r and r.status))
  end
  stand_in_cc()
  local fm = findScript("facility_menu")
  local ok = fm and fm.openRoster and fm.openRoster(tab)
  local rp = findScript("crew_roster_panel")
  wait(1.5)
  local open = rp and rp.isOpen()
  local extra = ""
  if tab == "MEMORIAL" then extra = string.format(" memorial %d", #(c.memorial() or {})) end
  if tab == "APPLICANTS" then extra = string.format(" offers %d", #(c.offers() or {})) end
  P("RESULT %s: %s (openRoster %s, open %s, tab %s, facility_menu.isOpen %s%s)", tab:lower(),
    (ok and open and rp.tab() == tab) and "PASS" or "FAIL", tostring(ok), tostring(open), tostring(rp and rp.tab()),
    tostring(fm and fm.isOpen()), extra)
  input.simulate { mouse = { 1200, 700 } }
end

local MAIN = function()
  boot()
  wait(4)
  if CASE == "vab" then vab_case()
  elseif CASE == "roster" then panel_case("ROSTER")
  elseif CASE == "applicants" then panel_case("APPLICANTS")
  elseif CASE == "memorial" then panel_case("MEMORIAL") end
  P("HOLD")
  if (params.quit or 0) > 0 then
    if save.deleteSlot then save.deleteSlot("slot" .. math.floor(params.slot)) end
    app.quit()
  end
  while true do yield() end
end

function update(node, dt)
  if not CO then
    NODE = node
    CASE = params.case or "vab"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
