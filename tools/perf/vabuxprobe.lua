-- VABUXPROBE: the VAB's direct-manipulation pass (playtest 2026-11), in the
-- real game, driven through the pointer as a player would. Run by
-- tools/perf/vabuxshot.sh. One play, pictures in user://vabux/<n>.png:
--
--   1 stage_drag    a three-stage rocket, STAGE tab: the top stage's grip
--                   dragged down onto stage 1 (the drop line and the ghost)
--   2 stage_after   …let go: the chutes now fire first
--   3 inspect       the tab on CREW, a Stowage Locker clicked IN THE VIEW: the
--                   plate turns to INSPECT; its ABOUT box scrolled by the wheel
--   4 portraits     a rover (seat, locker), CREW tab: the crew's faces
--   5 seat_drag     member #2's card dragged onto the seat (lit, ghost on the
--                   pointer)
--   6 seated        …let go
--   7 kit           BUY ▸ on the locker, +1 Medkit (no medkit in stock: it is
--                   bought at launch)
--   8 locker_flight launched: the locker's context menu in flight, the medkit
--                   in it, its price charged
--
-- `VABUX RESULT <step>: PASS|FAIL …` lines. params: slot (15), seed, quit.
defaults = { slot = 15, seed = 1911564384, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("VABUX %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local NODE, CO
local function yield() coroutine.yield() end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
end
local function frames(n) for _ = 1, n do yield() end end
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
local function result(step, ok, fmt, ...)
  P("RESULT %s: %s " .. (fmt or ""), step, ok and "PASS" or "FAIL", ...)
end

local pending = 0
local function shot(name)
  local sw, sh = 1280, 720
  if camera and camera.screenSize then sw, sh = camera.screenSize() end
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = math.floor(sw), h = math.floor(sh), ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://vabux/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("capture failed %s %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  frames(4)
end

-- ── the pointer, in design units ───────────────────────────────────────────
local function layer_H()
  local tb = findScript("builder_toolbar")
  local _, H = 1280, 720
  if tb and tb.layerSize then _, H = tb.layerSize() end
  return H
end
local function to_px(x, y)
  local sw, sh = camera.screenSize()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  local k = sh / layer_H()
  return (ox or 0) + x * k, (oy or 0) + y * k
end
local function point(x, y) local px, py = to_px(x, y); input.simulate { mouse = { px, py } } end
local function named(n, test)
  for _ = 1, 6 do
    if not n then return nil end
    if n.name and test(n.name) then return n.name end
    n = n.parent
  end
  return nil
end
-- Where an element named so is (node:uiRect, window pixels → design units,
-- its centre); else run the pointer down vertical lines at the given xs until
-- the hovered element (or an ancestor) has a name `test` likes. → x, y, name
local function to_du(px, py)
  local _, sh = camera.screenSize()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  local k = layer_H() / sh
  return (px - (ox or 0)) * k, (py - (oy or 0)) * k
end
local function seek(xs, y0, y1, test, step, exact)
  if exact then
    local n = find(exact)
    local x, y, w, h
    if n and n.uiRect then x, y, w, h = n:uiRect() end
    if x and w and w > 1 then
      local cx, cy = to_du(x + w * 0.5, y + h * 0.5)
      if cy >= y0 and cy <= y1 then point(cx, cy); frames(2); return cx, cy, exact end
    end
  end
  for _, x in ipairs(xs) do
    for y = y0, y1, step or 6 do
      point(x, y)
      frames(2)
      local h = ui.hovered and ui.hovered()
      local nm = named(h, test)
      if nm then return x, y, nm end
    end
  end
  return nil
end
-- Scroll the inspector's body so element `name` is in view (the wheel would;
-- this is exact). → true when it is
local function reveal(name)
  for _ = 1, 3 do
    local n, b = find(name), find("InspBody")
    if not (n and b and n.uiRect and b.uiRect) then return false end
    local _, ny, _, nh = n:uiRect()
    local _, by, _, bh = b:uiRect()
    if not (ny and by) then frames(2) else
      local _, sh = camera.screenSize()
      local k = layer_H() / sh
      local el = b:getcomponent("UiElement")
      if ny + nh <= by + bh and ny >= by then return true end
      el.scrollY = math.max(0, (el.scrollY or 0) + ((ny + nh) - (by + bh)) * k + 8)
      frames(3)
    end
  end
  return false
end
local function right_plate()
  local tb = findScript("builder_toolbar")
  local tw, th = tb.layerSize()
  return tb.builderLayout(tw, th).right
end
-- a press, a slow drag to (x1, y1), a held moment (the picture) and a release
local function drag(x0, y0, x1, y1, pic)
  point(x0, y0); frames(3)
  input.simulate { button = 0, down = true }; frames(3)
  local n = 24
  for i = 1, n do
    local t = i / n
    point(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
    frames(1)
  end
  frames(6)
  if pic then shot(pic) end
  input.simulate { button = 0, down = false }; frames(4)
end

-- ── the world and the builder ──────────────────────────────────────────────
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

local function crew3()
  local c = wait_for(function() return findScript("crew") end, 30, "the crew library")
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local n = #(c.roster() or {})
  while n < 3 do
    local id = c.hire(1)
    if not id then break end
    n = n + 1
  end
  return c
end

local function enter_vab()
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
  return BH
end

local HP = math.pi / 2
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local function load_bp(B, list)
  save.set("shipyard.blueprint", { parts = list })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #list end, 60, "the blueprint")
  wait(1.0)
end
local function stack(B, ids)
  local l, y = {}, 0
  for i, id in ipairs(ids) do
    local h = (B.partInfo(id) or {}).h or 1
    l[i] = rec(i, id, 0, y + h / 2, 0, { parent = i > 1 and i - 1 or 0, att = i > 1 and "top" or "" })
    y = y + h
  end
  return l
end

-- the screen point of a part on the stand (its frame-local centre, drawn now)
local function part_px(B, uid)
  local r = B.partRec(uid)
  local F = B.frameNodeOrNil and B.frameNodeOrNil()
  if not (r and F) then return nil end
  local w = F:toWorld(vec3(r.x, r.y, r.z))
  local sx, sy, _, on = camera.worldToScreen(w.x, w.y, w.z)
  if not on then return nil end
  return sx, sy
end

-- ── 1–2: a stage dragged by its grip ───────────────────────────────────────
local function stage_case(B, ins)
  load_bp(B, stack(B, { "engineM", "tankM", "decoupler", "engineS", "tankS", "decoupler", "tankS", "pod", "chute" }))
  ins.setTab("STAGE")
  wait(1.0)
  local v = B.stageView()
  local N = #(v.stages or {})
  local function kinds()
    local o = {}
    for n, sg in ipairs(B.stageView().stages or {}) do
      local k = {}
      for _, e in ipairs(sg.items or {}) do k[#k + 1] = e.kind end
      o[#o + 1] = n .. ":" .. table.concat(k, "+")
    end
    return table.concat(o, " ")
  end
  P("stages before: %s", kinds())
  local r = right_plate()
  local cx = r.x + r.w * 0.5
  local x0, y0 = seek({ cx }, r.y + 30, r.y + r.h - 10, function(n) return n == "StageGrip" .. N end, 4, "StageGrip" .. N)
  local x1, y1 = seek({ cx }, r.y + 30, r.y + r.h - 10, function(n) return n == "StageGrip1" end, 4, "StageGrip1")
  P("grip %d at %s,%s; grip 1 at %s,%s", N, tostring(x0), tostring(y0), tostring(x1), tostring(y1))
  if not (x0 and x1) then result("stage_drag", false, "grips not found"); return end
  -- (onto the lower half of stage 1's card: below its middle is "fire first")
  drag(x0, y0, x1, y1 + 70, "1_stage_drag")
  wait(0.6)
  local after = kinds()
  P("stages after: %s", after)
  local first = (B.stageView().stages or {})[1]
  local k1 = first and first.items and first.items[1] and first.items[1].kind
  result("stage_drag", k1 == "chute" and N >= 3, "(%d stages; stage 1 is now %s)", N, tostring(k1))
  point(r.x + 20, r.y + r.h - 4); frames(4)
  shot("2_stage_after")
end

-- ── 3: a part clicked in the view inspects it; ABOUT scrolls ───────────────
local function inspect_case(B, ins, uid)
  ins.setTab("CREW")
  wait(0.8)
  local sx, sy = part_px(B, uid)
  P("locker uid %d on screen at %s,%s", uid, tostring(sx), tostring(sy))
  if not sx then result("inspect", false, "locker not on screen"); return end
  input.simulate { mouse = { sx, sy } }; frames(3)
  input.simulate { button = 0, down = true }; frames(2)
  input.simulate { button = 0, down = false }; frames(6)
  wait(0.5)
  local tab = ins.tab()
  local sel = B.selection()
  -- the ABOUT box under the pointer, and the wheel
  local r = right_plate()
  local ax, ay = seek({ r.x + r.w * 0.5 }, r.y + 40, r.y + r.h - 10, function(n) return n == "InspAbout" end, 5, "InspAbout")
  local about = find("InspAbout")
  local el = about and about:getcomponent("UiElement")
  local maxY = el and el.scrollMaxY or -1
  if ax then
    for _ = 1, 3 do input.simulate { scroll = -1 }; frames(3) end
    if el and (el.scrollY or 0) <= 0 then for _ = 1, 3 do input.simulate { scroll = 1 }; frames(3) end end
  end
  wait(0.4)
  local sy1 = el and el.scrollY or -1
  P("ABOUT at %s,%s: scrollMaxY %.1f, scrollY after the wheel %.1f", tostring(ax), tostring(ay), maxY, sy1)
  result("inspect", tab == "INSPECT" and sel[1] == uid and maxY > 0 and sy1 > 0,
    "(tab %s, selected %s, the ABOUT box scrolls %.0f du and the wheel moved it %.0f)", tostring(tab), tostring(sel[1]), maxY, sy1)
  shot("3_inspect_scrolled")
end

-- ── 4–7: the crew's faces, a card dragged onto a seat, kit bought ──────────
local function crew_case(B, ins, bc, c, U)
  ins.setTab("CREW")
  B.select({}, "set")
  wait(0.5)
  -- nobody seated: the seat for the drag
  save.set("shipyard.crew", {})
  bc.sync(true)
  local want = 0
  for _, r in ipairs(c.roster()) do if r.status ~= "dead" then want = want + 1 end end
  wait_for(function() return (bc.portraitsTaken or 0) >= want end, 60, "the portraits")
  local got = 0
  for _, r in ipairs(c.roster()) do if bc.portraitOf(r.id) then got = got + 1 end end
  local pb = bc.portraitBooth and bc.portraitBooth() or {}
  P("portraits: %d of %d (booth aimed %s, failed %s)", got, want, tostring(pb.aimed), tostring(next(pb.failed or {})))
  wait(1.0)
  point(20, 300); frames(4)
  shot("4_portraits")
  result("portraits", got >= want and want > 0, "(%d of %d members have a picture)", got, want)
  -- a card onto the seat
  local member
  for _, r in ipairs(c.roster()) do if r.status == "base" and not member then member = r end end
  if bc.seatPlan()[U.seat] then save.set("shipyard.crew", {}); bc.sync(true); wait(0.5) end
  local r = right_plate()
  local cx = r.x + r.w * 0.5
  local x0, y0 = seek({ cx }, r.y + 30, r.y + r.h - 10, function(n) return n == "CrewCard" .. member.id end, 5, "CrewCard" .. member.id)
  local x1, y1 = seek({ cx }, r.y + 30, r.y + r.h - 10, function(n) return n == string.format("CrewSeat%d_1", U.seat) end, 5, string.format("CrewSeat%d_1", U.seat))
  P("card #%d at %s,%s; the seat at %s,%s", member.id, tostring(x0), tostring(y0), tostring(x1), tostring(y1))
  if not (x0 and x1) then result("seat_drag", false, "card or seat not found") return end
  drag(x0, y0, x1, y1, "5_seat_drag")
  wait(0.6)
  local plan = bc.seatPlan()
  local who = plan[U.seat] and plan[U.seat][1]
  result("seat_drag", who == member.id, "(%s dragged onto the Command Seat: the plan seats %s)", member.name, tostring(who))
  point(20, 300); frames(4)
  shot("6_seated")
  -- kit: BUY ▸ on the locker, then +1 Medkit
  local inv = findScript("inventory")
  local base0 = inv.itemCount("base", "medkit")
  reveal("CrewShop_" .. U.locker)
  local bx, by = seek({ r.x + r.w - 32 }, r.y + 30, r.y + r.h - 10, function(n) return n == "CrewShop_" .. U.locker end, 5, "CrewShop_" .. U.locker)
  if not bx then
    -- it may be below the fold: scroll the body down and look again
    point(cx, r.y + r.h * 0.6); frames(2)
    for _ = 1, 12 do input.simulate { scroll = -1 }; frames(2) end
    bx, by = seek({ r.x + r.w - 32 }, r.y + 30, r.y + r.h - 10, function(n) return n == "CrewShop_" .. U.locker end, 5, "CrewShop_" .. U.locker)
  end
  P("BUY ▸ at %s,%s", tostring(bx), tostring(by))
  if bx then
    point(bx, by); frames(3)
    input.simulate { button = 0, down = true }; frames(2); input.simulate { button = 0, down = false }; frames(6)
  end
  wait(0.5)
  reveal(string.format("CrewBuy_%d_medkit", U.locker))
  local mx, my = seek({ r.x + r.w - 26 }, r.y + 30, r.y + r.h - 10,
    function(n) return n == string.format("CrewBuy_%d_medkit", U.locker) end, 4, string.format("CrewBuy_%d_medkit", U.locker))
  P("+1 Medkit at %s,%s", tostring(mx), tostring(my))
  if mx then
    point(mx, my); frames(3)
    input.simulate { button = 0, down = true }; frames(2); input.simulate { button = 0, down = false }; frames(6)
  end
  wait(0.6)
  local lp = bc.lockerPlanMap()[U.locker] or {}
  local kit = bc.kitForLaunch()
  P("locker plan: medkit %s; kit at launch %s (stock medkits %d)", tostring(lp.medkit), tostring(kit.cost), base0)
  point(20, 300); frames(4)
  shot("7_kit")
  result("kit_planned", (lp.medkit or 0) == 1 and kit.cost == 150 and base0 == 0,
    "(1 medkit planned into LOCKER #1, %s to buy at launch)", tostring(kit.cost))
end

local function pilot()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end

-- ── 8: launched; the medkit is in the locker ───────────────────────────────
local function launch_case(B, BH, U)
  local co = findScript("company")
  local inv = findScript("inventory")
  local m0 = co.balance()
  if B.launchSite and B.launchSite() ~= "runway" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local spent_hull = save.get("shipyard.spent") or 0
  local v = wait_for(function()
    local v = pilot()
    return v and v.lockerOf and v.lockerOf(U.locker) and BH.state == "idle" and v
  end, 150, "the rover out of the VAB")
  if not v then result("locker_flight", false, "no craft") return end
  wait(2.0)
  local cid = v.lockerOf(U.locker)
  local n = inv.itemCount(cid, "medkit")
  local lk = BH.lastKit or {}
  local m1 = co.balance()
  P("rover out: locker %s holds %d medkit(s); kit %s loaded, %s bought, %s spent; money %.0f -> %.0f (hull %.0f)",
    tostring(cid), n, tostring(lk.loaded), tostring(lk.bought), tostring(lk.spent), m0, m1, spent_hull)
  for _, l in ipairs(lk.lines or {}) do P("  kit: %s", l) end
  -- the locker's context menu, its contents
  local cm = findScript("context_menu")
  if cm and cm.openFor and v.partRec then
    local pr = v.partRec(U.locker)
    local w = v.node.worldPos
    cm.openFor({ kind = "part", vessel = v, uid = U.locker, rec = pr, node = nil, label = pr and pr.label or "Locker",
                 wx = w.x, wy = w.y + 1.2, wz = w.z }, nil, 640, 300)
    wait(0.6)
    local ids = {}
    for _, e in ipairs(cm.entries() or {}) do ids[#ids + 1] = tostring(e.id) end
    P("menu: %s", table.concat(ids, " "))
    for _, e in ipairs(cm.entries() or {}) do
      if tostring(e.id):find("take") and e.type ~= "action" then cm.press(e.id) break end
    end
    wait(0.6)
    ids = {}
    for _, e in ipairs(cm.entries() or {}) do ids[#ids + 1] = tostring(e.id) .. "=" .. tostring(e.label) end
    P("menu (take): %s", table.concat(ids, " ; "))
  end
  shot("8_locker_flight")
  result("locker_flight", n == 1 and (lk.bought or 0) == 1 and math.abs((m0 - m1) - (spent_hull + 150)) < 1,
    "(the rover's locker holds %d medkit, bought at launch for %s; balance fell %.0f = hull %.0f + kit)", n,
    tostring(lk.spent), m0 - m1, spent_hull)
end

local MAIN = function()
  boot()
  wait(4)
  local c = crew3()
  local BH = enter_vab()
  if not BH then P("RESULT builder: FAIL no builder") return end
  local B = findScript("builder")
  local ins = wait_for(function() return findScript("builder_inspector") end, 10, "the inspector")
  local bc = wait_for(function() return findScript("builder_crew") end, 10, "builder_crew")
  wait(1.0)
  local ok, err = pcall(stage_case, B, ins)
  if not ok then P("ERROR stage %s", tostring(err)) end
  -- the rover: body, four wheels, the Command Seat, a Stowage Locker on its back
  local ROVER = {
    rec(1, "roverBody", 0, 0.62, 0),
    rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
    rec(7, "locker", -0.62, 0.62 + 0.15 + 0.25, 0, { parent = 1, att = "surface" }),
  }
  load_bp(B, ROVER)
  save.set("shipyard.lockerPlan", {})
  local U = { seat = 6, locker = 7 }
  ok, err = pcall(inspect_case, B, ins, U.locker)
  if not ok then P("ERROR inspect %s", tostring(err)) end
  ok, err = pcall(crew_case, B, ins, bc, c, U)
  if not ok then P("ERROR crew %s", tostring(err)) end
  ok, err = pcall(launch_case, B, BH, U)
  if not ok then P("ERROR launch %s", tostring(err)) end
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE")
  if (params.quit or 0) > 0 then
    if save.deleteSlot then save.deleteSlot("slot" .. math.floor(params.slot)) end
    app.quit()
  end
  while true do yield() end
end

function update(node, dt)
  if not CO then
    NODE = node
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
