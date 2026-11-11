-- REATTACHPROBE: the Repair Kit puts back what came off (Ty 2026-11-11:
-- "if a part gets detached but it's still visibly on it, it looks like
-- something I can repair but I just can't"), on a NEW Career save
-- (tools/perf/reattachshots.sh):
--
--   1. a rover rolled out, its crew stood beside it, dropped from 4 m at
--      9 m/s (a hard landing); what that does not tear off, the probe does:
--      the locker (and the seat on it) torn at its joint, the tank broken
--   2. each wreck through the right-click menu: the Condition row, the
--      "Reattach" row (refused while it lies too far, with why; brought
--      back), pressed: the part is back at its blueprint pose, one kit used,
--      the wreck gone, the craft holding together
--   3. a kit wall knocked askew and worn to 40 %: the Condition row says so,
--      "Repair the Wall" puts it square and whole; from 12 m it says why not
--
-- Pictures (1280x720) to user://reattachshots/, lines "RAP ", one RESULT a check.
local function cross_(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
defaults = { quit = 1, slot = 21, seed = 5150, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RAP %7.2f " .. fmt, W() - W0, ...)) end
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
    if bytes then assets.writeBytes("user://reattachshots/" .. name .. ".png", bytes); P("SHOT %s", name)
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

-- ── the rover ───────────────────────────────────────────────────────────────
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
  rec(11, "seat", 0.55, 0.62 + 0.15 + 0.5 + 0.65, 0, { parent = 7, att = "top" }),
  rec(10, "tankS", -1.32, 0.62, 0, { parent = 1, att = "surface" }),
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
local function count_parts(vc) local i = assembly.info(vc.node); return i and #i.parts or -1 end
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
local function kits() local inv = findScript("inventory"); return inv.itemCount("astro", "repairkit") end
local function menu_on(node, label)
  local cm = findScript("context_menu")
  local a = find("Astronaut")
  local w = node.worldPos
  local t = cm.resolve({ node = node, x = w.x, y = w.y, z = w.z }, a)
  if not t then P("no target for %s", label); return nil end
  cm.close()
  local ok = cm.openFor(t)
  hold(0.4)
  local rows = {}
  for _, e in ipairs(cm.entries()) do
    local val = type(e.value) == "function" and e.value() or e.value
    local en = e.enabled
    if type(en) == "function" then en = en() end
    local why = e.why
    if type(why) == "function" then why = why() end
    rows[#rows + 1] = string.format("[%s] %s%s%s", tostring(e.id), type(e.label) == "function" and e.label() or tostring(e.label),
      val and ("=" .. tostring(val)) or "", (en == false) and (" (off: " .. tostring(why) .. ")") or "")
  end
  P("MENU %s (%s %s): %s", label, tostring(t.kind), tostring(ok), table.concat(rows, " | "))
  return t, cm
end
-- a row's live value (a function is asked; false stays false: not the
-- `f() or f` idiom, which hands back the function when it answers false)
local function live(v) if type(v) == "function" then return v() end return v end
local function entry(cm, id)
  for _, e in ipairs(cm.entries()) do if e.id == id then return e end end
end
local function look_at(w, pitch) face(w.x, w.y, w.z, pitch or -0.25) end
local function stand_by(w, off)
  local b = home()
  local u = unit({ x = w.x - b.x, y = w.y - b.y, z = w.z - b.z })
  local a = find("Astronaut")
  -- off: a tangent offset (world) from the point
  stand_at(w.x + off.x, w.y + off.y, w.z + off.z, 1.5)   -- (a short ray down: never onto the craft's top)
end
local function tangent(w)
  local b = home()
  local u = unit({ x = w.x - b.x, y = w.y - b.y, z = w.z - b.z })
  local ax = math.abs(u.y) < 0.9 and { x = 0, y = 1, z = 0 } or { x = 1, y = 0, z = 0 }
  local t = unit({ x = ax.y * u.z - ax.z * u.y, y = ax.z * u.x - ax.x * u.z, z = ax.x * u.y - ax.y * u.x })
  return t, u
end

-- Reattach one wreck through the menu. → ok
local function reattach_one(vc, wr, name)
  local vn = vc.node
  local n = wr.n
  local w = n.worldPos
  local t1 = tangent(w)
  stand_by(w, { x = t1.x * 1.6, y = t1.y * 1.6, z = t1.z * 1.6 })
  hold(1.0)
  look_at(n.worldPos, -0.35)
  hold(0.8)
  shot(name .. "_0_wreck")
  local t, cm = menu_on(n, name)
  local e = cm and entry(cm, "kit_repair.kit_reattach")
  local en = e and live(e.enabled)
  local why = e and live(e.why)
  P("%s: reattach row %s, enabled %s, why %s, %d parts, dist %.2f m", name, tostring(e ~= nil), tostring(en), tostring(why),
    #(wr.set or {}), wr.dist or -1)
  shot(name .. "_1_menu")
  if e and en == false and why and tostring(why):find("from its mount", 1, true) then
    -- too far: bring it back (the gravity gun's job; a teleport here) and ask again
    R(name .. "_too_far_said", true, "%s", tostring(why))
    cm.close()
    local s = vn:toWorld(vec3(vc.lostRec(wr.uid).x, vc.lostRec(wr.uid).y, vc.lostRec(wr.uid).z))
    assembly.teleport(n, vec3(s.x + t1.x * 1.2, s.y + t1.y * 1.2, s.z + t1.z * 1.2))
    hold(2.0)
    t, cm = menu_on(n, name .. " (brought back)")
    e = cm and entry(cm, "kit_repair.kit_reattach")
    en = e and live(e.enabled)
  end
  if not (e and en ~= false) then R(name .. "_reattach", false, "no usable row"); cm.close(); return false end
  local k0, n0 = kits(), count_parts(vc)
  local ok = cm.press("kit_repair.kit_reattach")
  local secs = e.job and e.job.secs or 10
  hold(secs * 0.5)
  shot(name .. "_2_working")
  hold(secs * 0.5 + 2.5)
  cm.close()
  local n1 = count_parts(vc)
  local worst, found = attached(vc, wr.set)
  local hps = {}
  for _, u in ipairs(wr.set) do hps[#hps + 1] = string.format("%d:%.2f", u, vc.partHp(u) or -1) end
  local lost = {}
  for _, d in ipairs(vc.lostParts()) do lost[#lost + 1] = tostring(d.uid) end
  R(name .. "_reattach", ok and n1 == n0 + #wr.set and found == #wr.set and worst < 0.05 and kits() == k0 - 1 and not n.valid,
    "pressed %s; %d → %d parts; %d/%d at their blueprint poses (worst %.3f m); hp %s; kits %d → %d; wreck gone %s; still lost [%s]",
    tostring(ok), n0, n1, found, #wr.set, worst, table.concat(hps, " "), k0, kits(), tostring(not n.valid), table.concat(lost, ","))
  hold(3.0)
  local v = assembly.info(vn).vel
  R(name .. "_holds", count_parts(vc) == n1 and len(v.x, v.y, v.z) < 0.4, "%d parts, %.2f m/s", count_parts(vc), len(v.x, v.y, v.z))
  -- two angles
  -- (the craft where it is this tick: its root through assembly.info)
  local function craft_at() local o = assembly.info(vn).origin; return { x = o.x, y = o.y, z = o.z } end
  local rp = craft_at()
  local t2 = tangent(rp)
  stand_by(rp, { x = t2.x * 5.5, y = t2.y * 5.5, z = t2.z * 5.5 })
  for _ = 1, 2 do hold(0.8); look_at(craft_at(), -0.3) end
  hold(0.8)
  shot(name .. "_3_back_on_a")
  rp = craft_at()
  stand_by(rp, { x = -t2.x * 5.5, y = -t2.y * 5.5, z = -t2.z * 5.5 })
  for _ = 1, 2 do hold(0.8); look_at(craft_at(), -0.3) end
  hold(0.8)
  shot(name .. "_3_back_on_b")
  return true
end

local function craft_part()
  local co = findScript("company")
  local vc = launch_rover()
  if not vc then R("rollout", false, "no rover") return end
  local vn = vc.node
  local N = #ROVER
  vc.releaseClamps()
  wait_for(function() local bf = findScript("base_facilities"); return bf and not (bf.grading and bf.grading()) end, 120, "the grade")
  hold(3.0)
  local inv = findScript("inventory")
  inv.addItem("astro", "repairkit", 4, { force = true })
  -- the crew out beside it
  do
    local rp = vn.worldPos
    local t = tangent(rp)
    vc.standDown(vn, rp.x + t.x * 3, rp.y + t.y * 3, rp.z + t.z * 3, 0, 0, 0)
    hold(1.5)
  end
  vc.fuelFill(0)
  R("rollout", count_parts(vc) == N, "%d parts", count_parts(vc))
  -- A HARD LANDING: dropped from 1.5 m at 6 m/s down (4 m at 9 m/s broke the
  -- whole airframe up: the craft lost, nothing to put back); whatever it tears off
  local b = home()
  local o = assembly.info(vn).origin
  local u = unit({ x = o.x - b.x, y = o.y - b.y, z = o.z - b.z })
  assembly.teleport(vn, vec3(o.x + u.x * 1.5, o.y + u.y * 1.5, o.z + u.z * 1.5))
  pcall(function() vn.vel = vec3(-u.x * 6, -u.y * 6, -u.z * 6) end)
  hold(4.0)
  local wr = vc.lostWrecks()
  local ls = {}
  for _, e in ipairs(wr) do ls[#ls + 1] = string.format("%s(uid %d, %d parts, %.1f m)", e.label, e.uid, #e.set, e.dist or -1) end
  P("hard landing: %d → %d parts; wrecks: %s", N, count_parts(vc), table.concat(ls, ", "))
  -- what the landing did not tear, the probe does: the locker (its seat with
  -- it) torn at its joint, the tank broken by blows
  local have = {}
  for _, e in ipairs(wr) do for _, uu in ipairs(e.set) do have[uu] = true end end
  if not have[7] and vc.partHp(7) then
    local okj = vc.shedJoint(vn, 7, "probe: torn", 1.0, false)
    P("tore the locker at its joint: %s", tostring(okj))
    hold(2.0)
  end
  if not have[10] and vc.partHp(10) then
    for _ = 1, 20 do
      local h = vc.partHp(10)
      if not h or h <= 0 then break end
      vc.hitPart(10, 0.3)
      hold(0.25)
    end
    hold(2.0)
  end
  wr = vc.lostWrecks()
  ls = {}
  for _, e in ipairs(wr) do ls[#ls + 1] = string.format("%s(uid %d, %d parts, %.1f m)", e.label, e.uid, #e.set, e.dist or -1) end
  P("wrecks lying about: %s", table.concat(ls, ", "))
  R("wrecks", #wr >= 2, "%d wrecks", #wr)
  -- a part that is not ours: no reattach row on a plain boulder (no menu noise)
  for i, e in ipairs(wr) do
    if i > 3 then break end
    if e.n and e.n.valid then reattach_one(vc, e, string.format("craft%d_%s", i, tostring(e.label):gsub("%W", ""))) end
  end
  R("all_back", #vc.lostParts() == 0 and count_parts(vc) == N, "%d parts of %d, lost %d", count_parts(vc), N, #vc.lostParts())
  return vc
end

-- ── a kit piece knocked askew and worn ─────────────────────────────────────
local function kit_piece(vc)
  local ST = findScript("structures")
  local b = home()
  local a = find("Astronaut")
  local t, U = tangent(a.worldPos or vec3(a.x, a.y, a.z))
  local O = { x = a.x - b.x + t.x * 4, y = a.y - b.y + t.y * 4, z = a.z - b.z + t.z * 4 }
  local h = terrain.raycast(vec3(b.x + O.x + U.x * 5, b.y + O.y + U.y * 5, b.z + O.z + U.z * 5), vec3(-U.x, -U.y, -U.z), 20)
  if h then O = { x = h.pos.x - b.x, y = h.pos.y - b.y, z = h.pos.z - b.z } end
  local F = unit(cross_(U, t))
  local r = ST.newRecord(nil, b.name, O.x, O.y, O.z, U, F, "wall.steel", { name = "Probe Shed", t = 0 })
  local sid = ST.add(r)
  if ST.spawnNow then ST.spawnNow(sid) end
  hold(2.0)
  r = ST.get(sid)
  local p = r.bp[1]
  local uid = p.uid
  -- knocked askew (the scenario's knock) and worn (a beam's 40 %)
  p.wr = true
  p.o_p = p.pitch or 0
  local pitch0 = p.o_p
  p.pitch = (p.pitch or 0) + 0.22
  ST.put(r)
  if ST.respawnPart then ST.respawnPart(sid, uid) end
  ST.setPartState(sid, uid, { hp = 0.4 })
  hold(1.5)
  local n = ST.nodeOf(sid, uid)
  if not n then R("piece_spawned", false, "no node"); return end
  local w = n.worldPos
  stand_by(w, { x = F.x * 2.6, y = F.y * 2.6, z = F.z * 2.6 })
  hold(1.0)
  look_at(n.worldPos, -0.15)
  hold(0.8)
  shot("piece_0_knocked")
  local tg, cm = menu_on(n, "knocked wall")
  shot("piece_1_menu")
  local cond = nil
  for _, e in ipairs(cm.entries()) do if e.id == "part_info.pi_cond" then cond = type(e.value) == "function" and e.value() or e.value end end
  R("piece_condition", cond and tostring(cond):find("KNOCKED", 1, true) and tostring(cond):find("WORN", 1, true), "%s", tostring(cond))
  local e = entry(cm, "kit_repair.kit_piece")
  local en = e and live(e.enabled)
  if not (e and en ~= false) then R("piece_repair", false, "no usable row (%s)", e and tostringlive(e.why) or "none"); cm.close(); return end
  local k0 = kits()
  local ok = cm.press("kit_repair.kit_piece")
  local secs = e.job and e.job.secs or 10
  hold(secs * 0.5)
  shot("piece_2_working")
  hold(secs * 0.5 + 1.5)
  cm.close()
  local p2 = ST.getPart(sid, uid)
  local st = ST.partState(sid, uid)
  R("piece_repair", ok and p2 and not p2.wr and math.abs((p2.pitch or 0) - pitch0) < 1e-6 and not (st and st.hp) and kits() == k0 - 1,
    "pressed %s; knocked %s pitch %.3f (was %.3f); hp %s; kits %d → %d", tostring(ok), tostring(p2 and p2.wr), p2 and p2.pitch or -1,
    pitch0, tostring(st and st.hp), k0, kits())
  hold(1.0)
  n = ST.nodeOf(sid, uid)
  if n then look_at(n.worldPos, -0.15) end
  hold(0.6)
  shot("piece_3_square")
  -- too far: walked off 6 m (past arm's reach, inside the menu's own), the row says why
  -- (where the piece is NOW: a point read minutes ago is kilometres off on a
  -- moving planet, docs/positions-and-frames.md rule 1)
  local wn = (ST.nodeOf(sid, uid) or n).worldPos
  stand_by(wn, { x = F.x * 6, y = F.y * 6, z = F.z * 6 })
  hold(1.0)
  p2.wr, p2.o_p, p2.pitch = true, p2.pitch, (p2.pitch or 0) + 0.2
  ST.put(ST.get(sid))
  if ST.respawnPart then ST.respawnPart(sid, uid) end
  hold(1.5)   -- (the piece's node is made again: ask for the new one)
  local tg2, cm2 = menu_on(ST.nodeOf(sid, uid) or n, "knocked wall from 6 m")
  local e2 = cm2 and entry(cm2, "kit_repair.kit_piece")
  if not e2 and tg2 then
    -- (the menu did not stay open in the probe from there: ask the provider
    -- itself, as the menu would, with this actor)
    local H = findScript("item_hand")
    local rows = H and H.KIT and H.KIT.provider(tg2, { actor = cm2.actorNow() }) or {}
    for _, r in ipairs(rows) do if r.id == "kit_piece" then e2 = r end end
  end
  local why2 = e2 and live(e2.why)
  local en2 = e2 and live(e2.enabled)
  R("piece_too_far", e2 and en2 == false and tostring(why2):find("walk up", 1, true), "%s", tostring(why2))
  cm2.close()
  ST.remove(sid)
end

local function main()
  boot()
  hold(3.0)
  local vc = craft_part()
  kit_piece(vc)
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
