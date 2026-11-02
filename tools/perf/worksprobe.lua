-- WORKSPROBE: the base works of 2026-11-02 in the real game, on a NEW Career
-- save (tools/perf/worksshots.sh; scripts/material_intake.lua, repair_bay.lua,
-- context_providers.lua, supply_crates.lua):
--
--   1. the MATERIALS INTAKE: a log (timber, tagged as docs/resources.md says),
--      an iron-ore rock and a basalt rock dropped on the tail of the belt ride
--      it in and are taken behind the curtain: the warehouse gains timber and
--      iron, the basalt is sold; pictures from the side and from the tail,
--      while they ride and after (the receipt board and the screen line)
--   2. the SUPPLY CRATE's right-click menu, and a STOWAGE LOCKER's (no
--      "Contents" row)
--   3. the REPAIR BAY: a rover (with a locker) worn and run down, set in the
--      bay, the crew at the console: the work order, the job running, the
--      craft whole and charged afterwards
--
-- Pictures (1280×720) to user://worksshots/, lines "WKP ", one RESULT a check.
defaults = { quit = 1, slot = 18, seed = 5150, scale = 4, intake = 1, bay = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("WKP %7.2f " .. fmt, W() - W0, ...)) end
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
    if bytes then assets.writeBytes("user://worksshots/" .. name .. ".png", bytes); P("SHOT %s", name)
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
-- The avatar onto the ground at a world point (its radial; a raycast finds
-- paving and slabs as well as the terrain).
local function stand_at(px, py, pz, top_)
  local C = findScript("crew")
  local b = home()
  local a = find("Astronaut")
  local u = unit({ x = px - b.x, y = py - b.y, z = pz - b.z })
  local top = top_ or 30
  local h = raycast(px + u.x * top, py + u.y * top, pz + u.z * top, -u.x, -u.y, -u.z, 80, { ignore = a })
  local gx, gy, gz
  if h then gx, gy, gz = h.x, h.y, h.z
  else
    local gr = ground_r(b, u.x, u.y, u.z, len(px - b.x, py - b.y, pz - b.z) + 30)
    if not gr then return false end
    gx, gy, gz = b.x + u.x * gr, b.y + u.y * gr, b.z + u.z * gr
  end
  a.x, a.y, a.z = gx + u.x * 1.1, gy + u.y * 1.1, gz + u.z * 1.1
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

-- A loose body on the belt, tagged the way the mining work tags it.
local function drop(prefab, s, w, h, mat, qty, crosswise)
  local mi = find("FacIntake"):getScript("material_intake")
  local x, y, z = mi.beltWorld(s, w, h)
  local G = mi.belt()
  local got = nil
  spawn(prefab, vec3(x, y, z), function(n)
    got = n
    n.name = prefab .. " probe " .. tostring(math.floor(s * 10))
    local u, a = G.u, G.a
    local f = crosswise and a or G.w
    if n.setUp then n:setUp(vec3(u.x, u.y, u.z), vec3(f.x, f.y, f.z)) end
    local mf, mats = findScript("mineral_field"), findScript("materials")
    if mf and mf.adoptBody then mf.adoptBody(n, prefab, mat, qty, 1.0)
    elseif mats and mats.tagResource then mats.tagResource(n, mat, qty) end
    if assembly and assembly.rebuild then assembly.rebuild(n) end
  end)
  wait_for(function() return got end, 10, "the " .. prefab)
  return got
end

local function intake_round()
  local inv, co = findScript("inventory"), findScript("company")
  local fac = wait_for(function() return find("FacIntake") end, 30, "the intake shed")
  if not fac then R("intake", false, "no FacIntake") return end
  local mi = wait_for(function() local s = fac:getScript("material_intake"); return s and s.belt and s.belt() and s end, 20, "the belt")
  if not mi then R("intake", false, "no belt") return end
  local G = mi.belt()
  P("belt: %.2f m, take at %.2f m", G.L, G.take)
  -- stand on the west side of the belt, looking at it and the hood
  local sx, sy, sz = mi.beltWorld(4.0, -4.2, 0)
  stand_at(sx, sy, sz)
  hold(2.0)
  local hx, hy, hz = mi.beltWorld(G.take, 0, 0.6)
  face(hx, hy, hz, -0.12)
  hold(1.0)
  shot("intake_empty")
  frames(2)
  local t0, i0, b0 = inv.count("base", "timber"), inv.count("base", "iron"), co.balance()
  local log_n = drop("LooseLog", 1.4, 0, 0.9, "timber", 3, true)
  local rock_n = drop("LooseRock", 3.2, 0.3, 0.6, "iron", 2)
  local rock2 = drop("LooseRock", 4.6, -0.4, 0.6, "basalt", 3)
  hold(1.2)
  hx, hy, hz = mi.beltWorld(4, 0, 0.5)
  face(hx, hy, hz, -0.15)
  hold(0.4)
  shot("intake_riding_1")
  local carried = 0
  for _ = 1, 3 do hold(0.5); carried = math.max(carried, mi.carried or 0) end
  do
    local G2 = mi.belt()
    local b = home()
    for _, n in ipairs({ log_n, rock_n, rock2 }) do
      if n.valid then
        local inf = assembly.info(n)
        local c = inf and inf.com
        if c then
          local s2, w2, h2 = mi.beltLocal(G2, c.x - b.x, c.y - b.y, c.z - b.z)
          P("load %s: s %.2f w %.2f h %.2f vel %.2f %.2f %.2f mass %.3f asleep %s wake %s anchored %s parent %s", n.name, s2, w2, h2,
            inf.vel.x, inf.vel.y, inf.vel.z, inf.mass, tostring(inf.asleep), tostring(inf.wake), tostring(inf.anchored), tostring(n.parent and n.parent.name))
        else P("load %s: no assembly info", n.name) end
      end
    end
  end
  -- from the tail, along the belt to the hood
  local tx, ty, tz = mi.beltWorld(-5.5, 1.2, 0)
  stand_at(tx, ty, tz)
  hold(0.6)
  hx, hy, hz = mi.beltWorld(G.take, 0, 0.8)
  face(hx, hy, hz, -0.10)
  hold(0.6)
  shot("intake_riding_2")
  local took = wait_for(function()
    return not (log_n.valid and log_n.name:match("probe")) and not (rock_n.valid and rock_n.name:match("probe"))
      and not (rock2.valid and rock2.name:match("probe")) and true
  end, 30, "the loads taken")
  hold(0.3)
  shot("intake_taken_tail")
  sx, sy, sz = mi.beltWorld(G.take - 2.5, -4.5, 0)
  stand_at(sx, sy, sz)
  hold(0.6)
  hx, hy, hz = mi.beltWorld(G.take, 0, 1.6)
  face(hx, hy, hz, -0.05)
  hold(0.5)
  shot("intake_receipts")
  local t1, i1, b1 = inv.count("base", "timber"), inv.count("base", "iron"), co.balance()
  local lines = {}
  for _, r in ipairs(mi.receipts or {}) do lines[#lines + 1] = r.text end
  R("intake_carried", carried >= 1, "the belt drove %d bodies at once", carried)
  R("intake_taken", took ~= nil, "%s", table.concat(lines, " | "))
  R("intake_credit", t1 - t0 >= 3 and i1 - i0 >= 2 and b1 > b0,
    "timber %d→%d, iron %d→%d, balance $%d→$%d", t0, t1, i0, i1, b0, b1)
  local fr = save.get("depot.freight") or {}
  R("intake_freight", (fr.timber or 0) >= 3, "freight timber %d iron %d", fr.timber or 0, fr.iron or 0)
  -- a can of the base's own stock, pushed on by hand: back to stores, no money
end

-- ── the menus ───────────────────────────────────────────────────────────────
local function crate_menu()
  local sc = wait_for(function() local s = findScript("supply_crates"); return s and s.placed and s.placed > 0 and s end, 40, "the crates")
  local cm = findScript("context_menu")
  if not (sc and cm) then R("crate_menu", false, "no crates / menu") return end
  local e = nil
  for _, c in ipairs(sc.list()) do if c.node then e = c break end end
  local p = wpos(e.node)
  local b = home()
  local u = unit({ x = p.x - b.x, y = p.y - b.y, z = p.z - b.z })
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local to = unit({ x = b.x + bx - p.x, y = b.y + by - p.y, z = b.z + bz - p.z })
  stand_at(p.x + to.x * 2.2, p.y + to.y * 2.2, p.z + to.z * 2.2)
  hold(1.0)
  p = wpos(e.node)
  face(p.x, p.y, p.z, -0.35)
  hold(0.5)
  p = wpos(e.node)
  cm.openFor({ kind = "prop", node = e.node, label = e.name, wx = p.x + u.x * 0.3, wy = p.y + u.y * 0.3, wz = p.z + u.z * 0.3 })
  hold(0.6)
  local reg = findScript("context_registry")
  local tgt = { kind = "prop", node = e.node, label = e.name }
  local l2, errs = reg.entriesFor(tgt, { actor = cm.actorNow(), ref = findScript, toast = function() end })
  P("crate menu: open %s, %d rows direct, errs: %s", tostring(cm.isOpen()), #l2, table.concat(errs or {}, " | "))
  if not cm.isOpen() then
    p = wpos(e.node)
    cm.openFor({ kind = "prop", node = e.node, label = e.name, wx = p.x + u.x * 0.3, wy = p.y + u.y * 0.3, wz = p.z + u.z * 0.3 })
    frames(2)
  end
  shot("crate_menu")
  wait_for(function() return pending == 0 end, 5, "the crate picture")
  local ids = {}
  for _, x in ipairs(cm.entries()) do ids[#ids + 1] = x.id end
  local has_contents = false
  for _, x in ipairs(l2) do ids[#ids + 1] = x.id; if (x.label or ""):lower() == "contents" then has_contents = true end end
  R("crate_menu", not has_contents and #ids > 0, "rows: %s", table.concat(ids, ", "))
  cm.close()
end

-- ── the rover and the bay ───────────────────────────────────────────────────
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local HP = math.pi / 2
local ROVER = {
  rec(1, "roverBody", 0, 0.62, 0),
  rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(6, "seat", -0.35, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
  rec(7, "locker", 0.5, 0.62 + 0.15 + 0.25, 0, { parent = 1, att = "top" }),
}
local function pilot()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end
local function launch_rover()
  local co = findScript("company")
  if co and co.earn then co.earn(20000, "probe") end
  save.set("shipyard.blueprint", { parts = ROVER })
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 7 and B end, 90, "the builder")
  if not B then return nil end
  hold(1.5)
  save.set("shipyard.site", "runway")
  B.doLaunch()
  if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
  local ready = nil
  return wait_for(function()
    local v = pilot()
    if not v then return nil end
    local i = assembly.info(v.node)
    if i and i.anchored and #i.parts >= 7 then
      ready = ready or time
      if time - ready > 2 then return v end
    end
  end, 150, "the rover on the runway")
end

local function bay_round()
  local vc = launch_rover()
  if not vc then R("bay", false, "no rover") return end
  local vn = vc.node
  if vc.releaseClamps then vc.releaseClamps() end
  wait_for(function() local bf = findScript("base_facilities"); return bf and not (bf.grading and bf.grading()) end, 120, "the grade")
  wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited end, 60, "the base sited")
  hold(4.0)
  local fac = wait_for(function() return find("FacRepair") end, 30, "the repair bay")
  local rb = fac and wait_for(function() local s2 = fac:getScript("repair_bay"); return s2 and s2.worldOf and s2.worldOf(0, 0, 0) and s2 end, 10, "the bay's script")
  if not rb then R("bay", false, "no FacRepair") return end
  do
    local b = space.body(fac.parent.name)
    local w0, wp = fac:toWorld(vec3(0, 0, 0)), fac.worldPos
    P("FacRepair: body+x (%.1f %.1f %.1f)  worldPos (%.1f %.1f %.1f)  toWorld(0) (%.1f %.1f %.1f)",
      b.x + fac.x, b.y + fac.y, b.z + fac.z, wp.x, wp.y, wp.z, w0.x, w0.y, w0.z)
  end
  local function child(n, name) for _, c in ipairs(n:children()) do if c.name == name then return c end end end
  local fl, cl = child(fac, "Bay Floor"), child(fac, "Repair Console")
  -- into the bay: teleport, then measure where it landed in the bay's frame
  -- and correct once (a teleport is a world point on a moving planet)
  local landed = false
  for k = 1, 3 do
    local x, y, z = rb.worldOf(fl.x, fl.y + 1.0, fl.z - 1.0)
    assembly.teleport(vn, vec3(x, y, z))
    hold(1.5)
    local o = assembly.info(vn).origin
    local qx, qy, qz = rb.localOf(o.x, o.y, o.z)
    local lx, ly, lz = qx - fl.x, qy - fl.y, qz - fl.z
    P("rover in the bay frame, try %d: %.2f %.2f %.2f", k, lx, ly, lz)
    if math.abs(lx) < 3 and math.abs(lz) < 5 and ly > -0.5 and ly < 2.5 then landed = true break end
  end
  hold(2.0)
  -- wear it: two wheels and the body, and run the battery down
  local wear = { [1] = 0.45, [2] = 0.30, [5] = 0.62 }
  for uid, hp in pairs(wear) do if vc.wearPart then vc.wearPart(uid, hp) end end
  local cs = vc.controlState()
  if cs and cs.cap then vc.elecSetCharge(cs.cap * 0.25) end
  local inv = findScript("inventory")
  local lk = vc.lockerOf and vc.lockerOf(7)
  if lk and inv then inv.add(lk, "iron", 4); inv.add(lk, "copper", 2) end
  -- the crew out, at the console
  local cx, cy, cz = rb.worldOf(cl.x - 0.3, cl.y + 1.0, cl.z)
  vc.standDown(vn, cx, cy, cz, 0, 0, 0)
  hold(1.5)
  cx, cy, cz = rb.worldOf(cl.x - 0.3, cl.y + 1.0, cl.z)
  stand_at(cx, cy, cz, 1.5)
  hold(1.0)
  local rp = vn.worldPos
  face(rp.x, rp.y, rp.z, -0.20)
  hold(1.0)
  P("bay: inside %s, prompt %s, dbg %s", tostring(rb.insideName), tostring(rb.prompt), tostring(rb.dbg))
  shot("bay_prompt")
  local q0 = rb.quoteFor(vc)
  local worn0 = #vc.damagedParts()
  R("bay_detect", landed and rb.insideName ~= nil and rb.prompt ~= nil and rb.prompt:match("Service") ~= nil,
    "inside %s; prompt '%s'; %d worn parts, total $%d", tostring(rb.insideName), tostring(rb.prompt), worn0, q0 and q0.total or -1)
  local cm = findScript("context_menu")
  rb.openOrder()
  hold(0.6)
  do
    local reg = findScript("context_registry")
    local l2, errs = reg.entriesFor({ kind = "prop", node = fac, label = "Repair Bay" }, { actor = cm.actorNow(), ref = findScript, toast = function() end })
    P("bay menu: open %s, %d rows direct, errs: %s", tostring(cm.isOpen()), #l2, table.concat(errs or {}, " | "))
  end
  shot("bay_order")
  local rows = {}
  for _, e in ipairs(cm.entries()) do rows[#rows + 1] = (e.label or "") .. "=" .. tostring(type(e.value) == "function" and e.value() or e.value or "") end
  P("order: %s", table.concat(rows, " | "))
  local co = findScript("company")
  local b0 = co.balance()
  local okp = cm.press("service")
  hold(2.0)
  shot("bay_working")
  wait_for(function() return rb.jobs and rb.jobs > 0 end, 30, "the job")
  hold(0.8)
  shot("bay_done")
  local b1 = co.balance()
  local worn1 = #vc.damagedParts()
  local cs1 = vc.controlState()
  R("bay_service", okp and worn0 >= 3 and worn1 == 0 and b0 - b1 == q0.total and cs1.charge >= cs1.cap - 0.5,
    "pressed %s; worn %d → %d; paid $%d (quoted $%d); charge %.0f/%.0f; %s", tostring(okp), worn0, worn1, b0 - b1,
    q0.total, cs1.charge or -1, cs1.cap or -1, tostring(rb.lastJob))
  cm.close()
  hold(0.5)
  -- the locker's menu: the load meter, Take…, Put… — no "Contents"
  do
    local o = assembly.info(vn).origin
    local qx, qy, qz = rb.localOf(o.x, o.y, o.z)
    local x2, y2, z2 = rb.worldOf(qx + 1.8, qy + 1.0, qz + 1.8)
    stand_at(x2, y2, z2, 1.5)
    hold(0.8)
  end
  local lp = vn:toWorld(vec3(0.5, 1.02, 0))
  face(lp.x, lp.y, lp.z, -0.3)
  hold(0.6)
  lp = vn:toWorld(vec3(0.5, 1.02, 0))
  P("locker at %.1f m", find("Astronaut"):distanceTo(vn))
  cm.openFor({ kind = "part", vessel = vc, uid = 7, rec = vc.partRec(7), label = "Stowage Locker", wx = lp.x, wy = lp.y, wz = lp.z })
  hold(0.6)
  shot("locker_menu")
  local ids, contents = {}, false
  for _, e in ipairs(cm.entries()) do
    ids[#ids + 1] = e.id
    if (e.label or ""):lower() == "contents" then contents = true end
  end
  R("locker_menu", not contents and #ids > 0, "rows: %s", table.concat(ids, ", "))
  -- Take… is the contents list
  local take = nil
  for _, e in ipairs(cm.entries()) do if (e.id or ""):match("^take_") then take = e end end
  if take then cm.press(take.id); hold(0.5); shot("locker_take") end
  cm.close()
end

local function main()
  boot()
  hold(3.0)
  local co = findScript("company")
  if co then co.earn(5000, "probe") end
  if params.intake == 1 then intake_round() end
  crate_menu()
  if params.bay == 1 then bay_round() end
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
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
