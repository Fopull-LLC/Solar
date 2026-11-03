-- REFITPROBE: the Repair Bay refits parts that broke off (scripts/repair_bay.lua,
-- vessel_controller lostParts/refitParts), on a NEW Career save
-- (tools/perf/refitshots.sh):
--
--   1. a rover with a second seat on its locker, and a tank on its tail with
--      a decoupler and a battery stacked on it, rolled out and set in the bay
--   2. the decoupler is STAGED (the battery and decoupler leave on purpose:
--      never refit), then the tank (emptied), the locker (the seat on it is
--      shed with it) and a wheel are shot until they break off
--   3. the world is SAVED AND LOADED: the rover comes back without them and
--      still knows what it lost
--   4. at the console: the work order prices every refit part; with too little
--      money the service is refused; with enough, it runs and the parts come
--      back on at their blueprint poses, attached (the craft's own children,
--      one compound), whole, filled and charged, the seat empty
--   5. saved and loaded again: the refit parts are still there
--
-- Pictures (1280×720) to user://refitshots/, lines "RFP ", one RESULT a check.
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RFP %7.2f " .. fmt, W() - W0, ...)) end
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
    if bytes then assets.writeBytes("user://refitshots/" .. name .. ".png", bytes); P("SHOT %s", name)
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
  rec(7, "locker", 0.55, 0.62 + 0.15 + 0.25, 0, { parent = 1, att = "top" }),
  -- a second seat on the locker: it comes away when the locker breaks
  rec(11, "seat", 0.55, 0.62 + 0.15 + 0.5 + 0.65, 0, { parent = 7, att = "top" }),
  -- a tank on the tail, and a decoupler and battery stacked on it (the stage)
  rec(10, "tankS", -1.32, 0.62, 0, { parent = 1, att = "surface" }),
  rec(8, "decoupler", -1.32, 1.12 + 0.125, 0, { parent = 10, att = "top" }),
  rec(9, "battery", -1.32, 1.25 + 0.5, 0, { parent = 8, att = "top" }),
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
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= #ROVER and B end, 90, "the builder")
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
    if i and i.anchored and #i.parts >= #ROVER then
      ready = ready or time
      if time - ready > 2 then return v end
    end
  end, 150, "the rover on the runway")
end


local function child(n, name) for _, c in ipairs(n:children()) do if c.name == name then return c end end end
local function rover_now(n_parts)
  for _, v in ipairs(findScripts("vessel_controller")) do
    local i = v.node and v.node.valid and assembly.info(v.node)
    if i and (not n_parts or #i.parts == n_parts) and v.fleetParts and not (v.isLost and v.isLost()) then
      for _, r in ipairs((v.fleetParts() or { parts = {} }).parts) do
        if r.id == "roverBody" then return v end
      end
    end
  end
end
local function uids_of(list)
  local out = {}
  for _, d in ipairs(list or {}) do out[#out + 1] = tostring(d.uid) end
  return table.concat(out, ",")
end
local function count_parts(vc) local i = assembly.info(vc.node); return i and #i.parts or -1 end
-- Every live child of the craft against its blueprint pose (the craft frame):
-- → the worst offset (m) over `uids`, and how many of them have a child there.
local function attached(vc, uids)
  local worst, found = 0, 0
  for _, u in ipairs(uids) do
    local d = vc.partRec(u)
    local best = math.huge
    if d then
      for _, c in ipairs(vc.node:children()) do
        local e = len((c.x or 0) - d.x, (c.y or 0) - d.y, (c.z or 0) - d.z)
        if e < best then best = e end
      end
    end
    if best < 0.05 then found = found + 1 end
    if best < math.huge and best > worst then worst = best end
  end
  return worst, found
end

local BAY = {}
local function bay()
  BAY.fac = BAY.fac and BAY.fac.valid and BAY.fac or find("FacRepair")
  local fac = BAY.fac
  BAY.rb = fac and fac:getScript("repair_bay")
  BAY.fl, BAY.cl = fac and child(fac, "Bay Floor"), fac and child(fac, "Repair Console")
  return BAY.rb
end
local function at_console(vn)
  local rb, cl = BAY.rb, BAY.cl
  local cx, cy, cz = rb.worldOf(cl.x - 0.3, cl.y + 1.0, cl.z)
  stand_at(cx, cy, cz, 1.5)
  hold(0.8)
  local rp = vn.worldPos
  face(rp.x, rp.y, rp.z, -0.20)
  hold(0.6)
end
-- the second angle: across the bay, beside the craft
local function at_side(vn)
  local rb, fl = BAY.rb, BAY.fl
  local x, y, z = rb.worldOf(fl.x - 3.2, fl.y + 1.0, fl.z + 1.5)
  local okst = stand_at(x, y, z, 1.2)
  hold(0.8)
  local ap = find("Astronaut")
  local qx, qy, qz = rb.localOf(ap.x, ap.y, ap.z)
  P("side spot: stood %s at bay-local %.1f %.1f %.1f", tostring(okst), qx - fl.x, qy - fl.y, qz - fl.z)
  -- (twice: the camera eases round, and a stale aim from the console turn lingers)
  for _ = 1, 2 do
    local rp = vn.worldPos
    face(rp.x, rp.y, rp.z, -0.25)
    hold(1.2)
  end
end
local function shots(vn, name)
  at_side(vn); shot(name .. "_side")
  at_console(vn); shot(name .. "_console")
  wait_for(function() return pending == 0 end, 5, "the pictures")
end
local function hit_until_off(vc, uid)
  for k = 1, 40 do
    local h = vc.partHp(uid)
    if not h or h <= 0 then return true, k end
    vc.hitPart(uid, 0.3)
    hold(0.25)
  end
  return false, 40
end
local function reload(want_parts, what)
  local fo = findScript("flight_ops")
  fo.fleetSync(true)
  save.flush()
  P("fleet saved; loading the world again (%s)", what)
  scene.load("system")
  yield()
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    return gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 240, "the reload")
  local vc = wait_for(function()
    local v = rover_now(want_parts)
    if v then local i = assembly.info(v.node); if i and not i.anchored then return v end end
  end, 150, "the rover rebuilt from the fleet")
  hold(3.0)
  bay()
  return vc
end

local function main()
  boot()
  hold(3.0)
  local co = findScript("company")
  local vc = launch_rover()
  if not vc then R("rollout", false, "no rover") return end
  local vn = vc.node
  local N = #ROVER
  vc.releaseClamps()
  wait_for(function() local bf = findScript("base_facilities"); return bf and not (bf.grading and bf.grading()) end, 120, "the grade")
  hold(3.0)
  wait_for(function() return find("FacRepair") end, 30, "the repair bay")
  local rb = wait_for(function() local r = bay(); return r and r.worldOf and r.worldOf(0, 0, 0) and r end, 10, "the bay's script")
  if not rb then R("bay", false, "no FacRepair") return end
  local landed = false
  for k = 1, 3 do
    local x, y, z = rb.worldOf(BAY.fl.x, BAY.fl.y + 1.0, BAY.fl.z - 1.0)
    assembly.teleport(vn, vec3(x, y, z))
    hold(1.5)
    local o = assembly.info(vn).origin
    local qx, qy, qz = rb.localOf(o.x, o.y, o.z)
    local lx, ly, lz = qx - BAY.fl.x, qy - BAY.fl.y, qz - BAY.fl.z
    P("rover in the bay frame, try %d: %.2f %.2f %.2f", k, lx, ly, lz)
    if math.abs(lx) < 3 and math.abs(lz) < 5 and ly > -0.5 and ly < 2.5 then landed = true break end
  end
  R("in_bay", landed and count_parts(vc) == N, "%d parts", count_parts(vc))
  -- the crew out first (the seat on the locker is going to leave)
  do
    local cx, cy, cz = rb.worldOf(BAY.cl.x - 0.3, BAY.cl.y + 1.0, BAY.cl.z)
    vc.standDown(vn, cx, cy, cz, 0, 0, 0)
    hold(1.5)
  end
  -- STAGED: the decoupler fires; what leaves is not lost
  local n0 = count_parts(vc)
  local fired = vc.fireSeparation(8)
  hold(2.5)
  local n1 = count_parts(vc)
  local l1 = vc.lostParts()
  R("staged_not_lost", fired and n1 < n0 and #l1 == 0, "fired %s, %d → %d parts, lost [%s]", tostring(fired), n0, n1, uids_of(l1))
  -- BROKEN OFF: the tank (emptied: a dry can, not a bomb), the locker (its
  -- seat goes with it), a wheel
  vc.fuelFill(0)
  local okT, kT = hit_until_off(vc, 10)
  hold(1.5)
  local okL, kL = hit_until_off(vc, 7)
  hold(1.5)
  local okW, kW = hit_until_off(vc, 2)
  hold(2.5)
  local n2 = count_parts(vc)
  local l2 = vc.lostParts()
  local want = { [2] = true, [7] = true, [10] = true, [11] = true }
  local good = #l2 == 4
  for _, d in ipairs(l2) do if not want[d.uid] then good = false end end
  R("broken_lost", okT and okL and okW and good and n2 == n1 - 4,
    "tank %s (%d hits), locker %s (%d), wheel %s (%d); %d → %d parts; lost [%s]; body hp %.2f",
    tostring(okT), kT, tostring(okL), kL, tostring(okW), kW, n1, n2, uids_of(l2), vc.partHp(1) or -1)
  at_console(vn)
  shots(vn, "1_broken")
  -- SAVE AND LOAD with the parts missing
  vc = reload(n2, "broken")
  if not vc then R("reload_broken", false, "no rover") return end
  vn = vc.node
  rb = BAY.rb
  co = findScript("company")     -- (the scene was loaded again: new handles)
  local l3 = vc.lostParts()
  R("reload_broken", #l3 == 4 and count_parts(vc) == n2, "%d parts, lost [%s]", count_parts(vc), uids_of(l3))
  -- (the rover is back where it stood: in the bay)
  at_console(vn)
  hold(1.0)
  P("bay: inside %s, prompt %s, dbg %s", tostring(rb.insideName), tostring(rb.prompt), tostring(rb.dbg))
  local q = rb.quoteFor(vc)
  P("quote: refit %d $%.0f, mend %d $%.0f, fuel %d $%.0f, charge %d $%.0f, lost %d, total $%d",
    q.refit, q.refitCost, q.parts, q.mend, q.fuel, q.fuelCost, q.charge, q.chargeCost, q.lost, q.total)
  -- TOO POOR: the service is refused, nothing spent, nothing refit
  local bal = co.balance()
  co.spend(bal - (q.total - 1), "probe: broke")
  local b_poor = co.balance()
  local okp, whyp = rb.service(vc)
  hold(1.0)
  R("refused_poor", not okp and co.balance() == b_poor and #vc.lostParts() == 4,
    "balance $%d < $%d: %s (%s), lost still %d", b_poor, q.total, tostring(okp), tostring(whyp), #vc.lostParts())
  co.earn(20000, "probe: funds back")
  -- THE ORDER: every refit part priced
  local cm = findScript("context_menu")
  rb.openOrder()
  hold(0.8)
  shot("2_order")
  local rows, refit_rows = {}, 0
  for _, e in ipairs(cm.entries()) do
    local val = type(e.value) == "function" and e.value() or e.value or ""
    rows[#rows + 1] = (e.label or "") .. "=" .. tostring(val)
    if (e.label or ""):match("^Refit") then refit_rows = refit_rows + 1 end
  end
  P("order: %s", table.concat(rows, " | "))
  R("order_lines", refit_rows == 4 and q.refit == 4 and q.fuel >= 80, "%d refit rows, refit $%.0f, propellant %d u", refit_rows, q.refitCost, q.fuel)
  local b0 = co.balance()
  local pressed = cm.press("service")
  hold(2.0)
  shot("3_working")
  wait_for(function() return rb.jobs and rb.jobs > 0 end, 40, "the job")
  hold(1.5)
  cm.close()
  local b1 = co.balance()
  local n4 = count_parts(vc)
  local l4 = vc.lostParts()
  local worst, found = attached(vc, { 2, 7, 10, 11 })
  local whole = true
  for _, u in ipairs({ 2, 7, 10, 11 }) do if vc.partHp(u) ~= 1 then whole = false end end
  local fuel_full, cap, left = true, 0, 0
  for _, t in ipairs(vc.tankList()) do cap = cap + (t.cap or 0); left = left + (t.left or 0) end
  fuel_full = cap >= 80 and left >= cap - 0.5
  local cs = vc.controlState()
  local seat_free, seat_seen = false, false
  for _, s in ipairs(vc.seatsOf()) do if s.uid == 11 then seat_seen = true; seat_free = s.taken == nil end end
  local wheels = #(vc.R2 and vc.R2.wheels or {})
  R("refit", pressed and n4 == n1 and #l4 == 0 and found == 4 and worst < 0.05 and whole,
    "pressed %s; %d → %d parts (want %d); lost [%s]; %d/4 at their blueprint poses (worst %.3f m); whole %s; %s",
    tostring(pressed), n2, n4, n1, uids_of(l4), found, worst, tostring(whole), tostring(rb.lastJob))
  R("refit_paid", b0 - b1 == q.total, "paid $%d, quoted $%d", b0 - b1, q.total)
  -- (the rover's own draw takes a few EC in the moments since the fill)
  R("refit_filled", fuel_full and cs.charge >= cs.cap * 0.98, "propellant %.0f/%.0f, charge %.0f/%.0f", left, cap, cs.charge or -1, cs.cap or -1)
  R("refit_seat", seat_seen and seat_free, "seat 11 aboard %s, empty %s", tostring(seat_seen), tostring(seat_free))
  R("refit_wheels", wheels == 4, "%d wheels driven", wheels)
  -- it holds together: still one compound a few seconds on, and not moving
  hold(4.0)
  local v_end = assembly.info(vn).vel
  R("refit_holds", count_parts(vc) == n1 and len(v_end.x, v_end.y, v_end.z) < 0.3,
    "%d parts, %.2f m/s", count_parts(vc), len(v_end.x, v_end.y, v_end.z))
  shots(vn, "4_refit")
  -- SAVE AND LOAD after the refit
  vc = reload(n1, "refit")
  if not vc then R("reload_refit", false, "no rover") return end
  local w2, f2 = attached(vc, { 2, 7, 10, 11 })
  R("reload_refit", count_parts(vc) == n1 and #vc.lostParts() == 0 and f2 == 4,
    "%d parts, lost [%s], %d/4 at their poses (worst %.3f m)", count_parts(vc), uids_of(vc.lostParts()), f2, w2)
  shots(vc.node, "5_reloaded")
end

local function run()
  main()
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(run)
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
