-- ── mine probe (tools/perf/fellprobe.sh): ore veins, physical yields, logs, bush bends ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua,
-- verifyprobe_modes.lua and fellprobe_modes.lua (V.*, FP.*). Modes:
--   vmine   a new world: out from the base on rings until mineral_field has a
--           vein with outcrops in reach; the crew stands off it (the seam is
--           painted as you come near), pictures of the vein; then the laser
--           held 5 s on the plain ground beside it and 5 s on the seam: what
--           came out (inventory, mineral_field.yieldStats m³ and units by
--           material) against terrain.slotAt at the aim; the seam must give
--           its ore, the ground beside it its own rock, and the ore cut slower.
--   vlog    a new world: a broadleaf or conifer felled with the laser, the
--           logs it leaves (tags, what materials.resourceOf reads, the save's
--           loose.bodies), one picked up with the gravity gun (picture).
--   vbush   a new world: a bush or shrub found, the crew walked into it (the
--           touch-bend swap): the bend nodes' materials and pictures before,
--           bent, and after it springs back.
-- `VP PASS|FAIL <check>` lines and `VP RESULT <mode>`; pictures in
-- $WORK/proj/save/user/vshots/<mode>_*.png.
local MP = {}

-- the world point under body-relative direction-ish point `rel`, on the ground now
function MP.ground_at(rel)
  local b = home()
  local l = len(rel.x, rel.y, rel.z)
  local u = { x = rel.x / l, y = rel.y / l, z = rel.z / l }
  local top = l + 200
  local h = terrain.raycast(vec3(b.x + u.x * top, b.y + u.y * top, b.z + u.z * top), vec3(-u.x, -u.y, -u.z), 400)
  if not (h and h.pos) then return nil end
  return { x = h.pos.x - b.x, y = h.pos.y - b.y, z = h.pos.z - b.z }
end
function MP.w(rel) local b = home(); return { x = b.x + rel.x, y = b.y + rel.y, z = b.z + rel.z } end

-- stand the crew `D` m from body-relative ground point `rel`, along `side` (a unit tangent)
function MP.stand_off(rel, side, D)
  local b = home()
  local s = { x = rel.x + side.x * D, y = rel.y + side.y * D, z = rel.z + side.z * D }
  local l = len(s.x, s.y, s.z)
  local dir = { x = s.x / l, y = s.y / l, z = s.z / l }
  local gr = ground_r(b, dir.x, dir.y, dir.z, l + 40)
  stand_at({ dir = dir, r = gr or l })
  FP.aim.ref = nil
end

function MP.inv_snapshot()
  local inv = findScript("inventory")
  local out = {}
  for _, it in ipairs(inv.items("astro")) do out[it.mat] = it.n or it.count or 0 end
  return out
end
function MP.diff(a, b)
  local out, parts = {}, {}
  for m, n in pairs(b) do local d = n - (a[m] or 0); if d ~= 0 then out[m] = d; parts[#parts + 1] = m .. " +" .. d end end
  return out, table.concat(parts, ", ")
end
function MP.stats_copy()
  local mf = findScript("mineral_field")
  local s = mf.yieldStats or { vol = {}, units = {} }
  local c = { vol = {}, units = {}, removed = s.removed or 0, reports = s.reports or 0 }
  for k, v in pairs(s.vol) do c.vol[k] = v end
  for k, v in pairs(s.units) do c.units[k] = v end
  return c
end
function MP.stats_line(a, b, secs)
  local parts = {}
  local tot = 0
  for m, v in pairs(b.vol) do
    local d = v - (a.vol[m] or 0)
    if d > 0.001 then parts[#parts + 1] = string.format("%s %.2f m3 (%d u)", m, d, (b.units[m] or 0) - (a.units[m] or 0)); tot = tot + d end
  end
  return string.format("%.2f m3 in %.1f s (%.2f m3/s), %d reports: %s", tot, secs, tot / math.max(0.1, secs),
    b.reports - a.reports, table.concat(parts, ", ")), tot
end

-- hold the laser's trigger `secs` on world point T() (asked each frame): the
-- beam aimed exactly through the tool's test hook (tool_belt `sim.aim`, a ray
-- from the crew's chest to the target, read each frame in the planet's
-- frame), the camera turned onto it for the pictures
function MP.dig(T, secs, shot_at, shot_name)
  local tb = findScript("tool_belt")
  local function ray()
    local a, t = astro(), T()
    local U = V.up(a)
    local o = { x = a.x + U.x * 1.3, y = a.y + U.y * 1.3, z = a.z + U.z * 1.3 }
    local d = unit(sub(t, o))
    return o.x, o.y, o.z, d.x, d.y, d.z
  end
  for _ = 1, 40 do FP.aim_step(T); yield() end
  tb.sim = { aim = ray, btn = { [0] = false } }
  for _ = 1, 3 do yield() end
  local t = T()
  MP.lastAimErr = tb.aimX and len(tb.aimX - t.x, tb.aimY - t.y, tb.aimZ - t.z) or -1
  do
    local ox, oy, oz, dx, dy, dz = ray()
    local h = raycast(ox, oy, oz, dx, dy, dz, 40, astro())
    local a = astro()
    P("VP aim: crew %.1f m from the target, the ray %.1f m long; raycast hits %s at %.2f m (node %s); the tool's aim point %.2f m from the crew; tool %s mode %s",
      len(a.x - t.x, a.y - t.y, a.z - t.z), len(t.x - ox, t.y - oy, t.z - oz), h and "something" or "nothing", h and (h.distance or -1) or -1,
      h and h.node and tostring(h.node.name) or "-", tb.aimX and len(tb.aimX - a.x, tb.aimY - a.y, tb.aimZ - a.z) or -1, tostring(tb.toolId()), tostring(tb.laserMode))
  end
  local s0, i0 = MP.stats_copy(), MP.inv_snapshot()
  local mats = {}
  tb.sim.btn[0] = true
  local t0, shot = time, false
  while time - t0 < secs do
    FP.aim_step(T)
    yield()
    if tb.aimMat then mats[tb.aimMat] = (mats[tb.aimMat] or 0) + 1 end
    if shot_at and not shot and time - t0 >= shot_at then shot = true; V.shot(shot_name, true) end
  end
  tb.sim.btn[0] = false
  yield()
  tb.sim = nil
  wait(1.2)   -- the last receipts land
  local s1, i1 = MP.stats_copy(), MP.inv_snapshot()
  local line, vol = MP.stats_line(s0, s1, secs)
  local _, got = MP.diff(i0, i1)
  local ml = {}
  for m, n in pairs(mats) do ml[#ml + 1] = m .. " " .. n end
  return { aimErr = MP.lastAimErr, line = line, vol = vol, got = got, inv = select(1, MP.diff(i0, i1)), aim = table.concat(ml, ", "), s0 = s0, s1 = s1, prompt = tb.prompt }
end

local function run_vmine()
  V.tag = "mine"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  local mf, mats, inv = findScript("mineral_field"), findScript("materials"), findScript("inventory")
  local cl = findScript("climate")
  local hb = home()
  local w = cl.worldOf(hb.name)
  P("VP the world %s: kind %s, its vein ores: %s", hb.name, tostring(w and w.kind), (function()
    local o = {}
    for _, e in ipairs(mats.veinOres(w and w.kind or "barren")) do o[#o + 1] = string.format("%s %.2f", e.mat, e.w) end
    return table.concat(o, ", ")
  end)())
  -- 1. find a vein with outcrops
  local u, t1, t2, R = base_frame()
  local pick, seen = nil, 0
  for _, dist in ipairs({ 110, 170, 240, 330, 430, 560 }) do
    for k = 0, 7 do
      if pick then break end
      local ang = k * math.pi / 4 + dist * 0.013
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local gr = ground_r(hb, dir.x, dir.y, dir.z, R + 150)
      local sea = cl.seaRadius and cl.seaRadius(hb.name) or 0
      if gr and gr > sea + 1 then
        stand_at({ dir = dir, r = gr })
        wait(3.5)
        local a = astro()
        local list = mf.veinsNear(a.x, a.y, a.z, 140)
        seen = seen + #list
        local o = {}
        for i = 1, math.min(4, #list) do local v = list[i]; o[#o + 1] = string.format("%s %.0f m (out %d, painted %s, slot %s)", v.ore, v.d, v.out, tostring(v.painted), tostring(v.slot)) end
        P("VP veins at %d m bearing %.0f: %d: %s", dist, math.deg(ang), #list, table.concat(o, "; "))
        for _, v in ipairs(list) do
          local bb = home()
          local vs = cl.seaRadius and cl.seaRadius(hb.name) or 0
          if not pick and v.out > 0 and len(v.x - bb.x, v.y - bb.y, v.z - bb.z) > vs + 1.5 then
            pick = { rel = { x = v.x - bb.x, y = v.y - bb.y, z = v.z - bb.z }, ore = v.ore, len = v.len, width = v.width, up = { x = v.ux, y = v.uy, z = v.uz },
                     strike = { x = v.sx, y = v.sy, z = v.sz } }
          end
        end
      end
    end
    if pick then break end
  end
  V.check("a vein in reach", pick ~= nil, "%d veins seen on the way; the pick: %s", seen, pick and pick.ore or "none")
  if not pick then V.result() return end
  -- 2. stand off it; it is painted as you come near
  local U = pick.up
  local a0 = { x = 0, y = 1, z = 0 }
  if math.abs(U.y) > 0.9 then a0 = { x = 1, y = 0, z = 0 } end
  local side = unit(cross(U, pick.strike))   -- across the seam
  MP.stand_off(pick.rel, side, 9.0)
  local painted = wait_for(function()
    local a = astro()
    local l = mf.veinsNear(a.x, a.y, a.z, 30)
    return l[1] and l[1].painted
  end, 12, "vein painted")
  local a = astro()
  local now = mf.veinsNear(a.x, a.y, a.z, 30)[1]
  local bb = home()
  local cw = MP.w(pick.rel)
  local slot_c = terrain.slotAt(cw.x - U.x * 0.3, cw.y - U.y * 0.3, cw.z - U.z * 0.3)
  local sidep = { x = pick.rel.x + side.x * 4.5, y = pick.rel.y + side.y * 4.5, z = pick.rel.z + side.z * 4.5 }
  local hostg = MP.ground_at(sidep)
  local hw = hostg and MP.w(hostg)
  local slot_h = hw and terrain.slotAt(hw.x - U.x * 0.3, hw.y - U.y * 0.3, hw.z - U.z * 0.3)
  P("VP the vein: %s, %.1f m long, %.1f m wide, painted %s slot %s; slotAt its middle %s (%s), 5.5 m beside %s (%s); materialAt middle %s, beside %s; %d outcrops standing",
    pick.ore, pick.len or 0, pick.width or 0, tostring(now and now.painted), tostring(now and now.slot), tostring(slot_c), mats.ofSlot(slot_c),
    tostring(slot_h), mats.ofSlot(slot_h), tostring(mf.materialAt(cw.x - U.x * 0.3, cw.y - U.y * 0.3, cw.z - U.z * 0.3)),
    hw and tostring(mf.materialAt(hw.x - U.x * 0.3, hw.y - U.y * 0.3, hw.z - U.z * 0.3)) or "-", now and now.out or -1)
  -- where the paint actually is: the vein's slot on a 9×9 grid (1 m) round
  -- its middle, 0.4 m under the ground, and the frames' body-vs-node offset
  do
    local A = { x = 0, y = 1, z = 0 }
    if math.abs(U.y) > 0.9 then A = { x = 1, y = 0, z = 0 } end
    local e1 = unit(cross(U, A)); local e2 = unit(cross(U, e1))
    local hit, sx, sy = 0, 0, 0
    for i = -4, 4 do for j = -4, 4 do
      local rp = { x = pick.rel.x + e1.x * i + e2.x * j, y = pick.rel.y + e1.y * i + e2.y * j, z = pick.rel.z + e1.z * i + e2.z * j }
      local g = MP.ground_at(rp)
      if g then
        local w = MP.w(g)
        local sl = terrain.slotAt(w.x - U.x * 0.4, w.y - U.y * 0.4, w.z - U.z * 0.4)
        if now and sl == now.slot then hit = hit + 1; sx = sx + i; sy = sy + j end
      end
    end end
    local pn = find(hb.name)
    local b = home()
    P("VP paint grid: %d of 81 cells read the vein's slot, centroid (%.1f, %.1f) m off the middle; planet node − space.body = %.2f m",
      hit, hit > 0 and sx / hit or 0, hit > 0 and sy / hit or 0, pn and len(pn.x - b.x, pn.y - b.y, pn.z - b.z) or -1)
  end
  do
    local list = findTagged("ore_outcrop")
    for i, n in ipairs(list) do
      if i <= 3 then
        local ok, tc = pcall(function() local c = n:getcomponent("Tint"); return c and c.color end)
        local okp, ml = pcall(function() return n:materials() end)
        local parts = {}
        for _, e in ipairs(okp and ml or {}) do parts[#parts + 1] = string.format("%s textured %s overridden %s", tostring(e.material), tostring(e.textured), tostring(e.overridden)) end
        local a = astro()
        local wp = n.worldPos or n.pos
        P("VP outcrop %s %.1f m away, model %s scale %.2f; tint %s; parts %s", n.name, wp and len(wp.x - a.x, wp.y - a.y, wp.z - a.z) or -1, tostring(n.model), n.scale_x or -1,
          ok and tc and string.format("%.2f %.2f %.2f", tc.r or tc[1] or tc.x or -1, tc.g or tc[2] or tc.y or -1, tc.b or tc[3] or tc.z or -1) or ("none " .. tostring(tc)), table.concat(parts, "; "))
      end
    end
    P("VP %d outcrop nodes", #list)
  end
  V.check("the vein is painted when you come near", painted == true and now ~= nil and now.slot ~= nil, "slot %s", tostring(now and now.slot))
  V.check("the seam reads as its ore, the ground beside as its own rock", mf.materialAt(cw.x - U.x * 0.3, cw.y - U.y * 0.3, cw.z - U.z * 0.3) == pick.ore
    and hw ~= nil and mf.materialAt(hw.x - U.x * 0.3, hw.y - U.y * 0.3, hw.z - U.z * 0.3) ~= pick.ore,
    "middle %s, beside %s", tostring(mf.materialAt(cw.x - U.x * 0.3, cw.y - U.y * 0.3, cw.z - U.z * 0.3)), hw and tostring(mf.materialAt(hw.x - U.x * 0.3, hw.y - U.y * 0.3, hw.z - U.z * 0.3)) or "-")
  -- pictures: from where the crew stands, and from further off and up
  local Tc = function() return MP.w(pick.rel) end
  for _ = 1, 60 do FP.aim_step(Tc); yield() end
  V.shot("vein_near", false)
  MP.stand_off(pick.rel, side, 22.0)
  wait(1.0)
  for _ = 1, 60 do FP.aim_step(Tc); yield() end
  V.shot("vein_far", false)
  -- from above and to the side: the seam on the ground and its outcrops
  do
    local cam = V.fixed_cam(MP.w(pick.rel), U, side, 7.0, 7.0)
    for _ = 1, 20 do V.place_cam(); yield() end
    V.shot("vein_above", false, cam)
    for _ = 1, 20 do V.place_cam(); yield() end
    V.place_cam = nil
    if cam and cam.valid then cam:destroy() end
  end
  -- 3. the laser on the ground beside it, then on the seam
  V.select_tool("laser")
  inv.clear("astro")
  -- the seam first (from 3.5 m on one side), then plain ground 6 m out on
  -- the other side, with the crew standing past it (so its bore runs away
  -- from the seam)
  MP.stand_off(pick.rel, { x = -side.x, y = -side.y, z = -side.z }, 3.5)
  wait(1.5)
  local Tv = function() local w = MP.w(pick.rel); return { x = w.x - U.x * 0.4, y = w.y - U.y * 0.4, z = w.z - U.z * 0.4 } end
  local vein = MP.dig(Tv, 6.0, 2.5, "mining_vein")
  P("VP vein dig aim lands %.2f m from its target", vein.aimErr or -1)
  P("VP vein dig: %s; the pack got %s; the crosshair read %s; prompt '%s'", vein.line, vein.got, vein.aim, tostring(vein.prompt))
  inv.clear("astro")
  local hostg2 = MP.ground_at({ x = pick.rel.x + side.x * 6, y = pick.rel.y + side.y * 6, z = pick.rel.z + side.z * 6 })
  hostg = hostg2 or hostg
  local hw2 = MP.w(hostg)
  slot_h = terrain.slotAt(hw2.x - U.x * 0.3, hw2.y - U.y * 0.3, hw2.z - U.z * 0.3)
  MP.stand_off(pick.rel, side, 9.5)
  wait(1.5)
  local Th = function() local w = MP.w(hostg); return { x = w.x - U.x * 0.4, y = w.y - U.y * 0.4, z = w.z - U.z * 0.4 } end
  local host = MP.dig(Th, 5.0, 2.5, "dig_host")
  P("VP host dig aim lands %.2f m from its target", host.aimErr or -1)
  P("VP host dig (slot %s = %s): %s; the pack got %s; the crosshair read %s; prompt '%s'", tostring(slot_h), mats.ofSlot(slot_h), host.line, host.got, host.aim, tostring(host.prompt))
  inv.clear("astro")
  MP.stand_off(pick.rel, { x = -side.x, y = -side.y, z = -side.z }, 11.0)
  wait(1.0)
  for _ = 1, 40 do FP.aim_step(Tc); yield() end
  V.shot("vein_dug", false)
  local host_mat = mats.ofSlot(slot_h)
  local hv = host.s1.vol[host_mat] and (host.s1.vol[host_mat] - (host.s0.vol[host_mat] or 0)) or 0
  local ov = (vein.s1.vol[pick.ore] or 0) - (vein.s0.vol[pick.ore] or 0)
  V.check("the ground beside gives its own material", hv > 0.5 * host.vol and (host.inv[host_mat] or 0) > 0,
    "%s %.2f of %.2f m3, %d units", host_mat, hv, host.vol, host.inv[host_mat] or 0)
  V.check("the seam gives its ore", ov > 0 and (vein.inv[pick.ore] or 0) > 0, "%s %.2f m3 of %.2f, %d units", pick.ore, ov, vein.vol, vein.inv[pick.ore] or 0)
  local hh, oh = mats.hardness(host_mat), mats.hardness(pick.ore)
  V.check("ore cuts slower than the ground round it", oh > hh, "hardness %s %.2f against %s %.2f (the bite and the bore ÷ by it); m3/s host %.2f, vein %.2f",
    pick.ore, oh, host_mat, hh, host.vol / 5.0, vein.vol / 6.0)
  inv.clear("astro")
  V.result()
end

local function run_vlog()
  V.tag = "log"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  local ff, tb, mats = findScript("flora_field"), findScript("tool_belt"), findScript("materials")
  local found = FP.search(4, params.fstops or 30)
  local q
  for _, k in ipairs({ "broadleaf", "conifer", "palm" }) do if found[k] and found[k][1] then q = found[k][1] break end end
  V.check("a tree to fell", q ~= nil, "%s", q and q.kind or "none")
  if not q then V.result() return end
  V.select_tool("laser")
  local logs0 = #findTagged("log")
  local fell = FP.cut(q, 3.5, "lmb", "tree")
  wait(1.0)
  local list = findTagged("log")
  local a = astro()
  local best, bd = nil, 1e9
  local o = {}
  for _, n in ipairs(list) do
    local r = mats.resourceOf(n)
    local d = len(n.x - a.x, n.y - a.y, n.z - a.z)
    o[#o + 1] = string.format("%s %.1f m [%s] → %s", n.name, d, table.concat(n.tags or {}, ","), r and string.format("%s ×%d %.0f kg $%d", r.mat, r.qty, r.kg, r.value) or "nil")
    if d < bd then best, bd = n, d end
  end
  P("VP logs after the fall (%d before): %s", logs0, table.concat(o, "; "))
  V.check("the felled tree left log bodies", fell == true and #list > logs0, "%d → %d", logs0, #list)
  local r = best and mats.resourceOf(best)
  V.check("a log carries its material and quantity in its tags", r ~= nil and r.mat == "timber" and r.qty >= 1, "%s", r and (r.mat .. " ×" .. r.qty) or "nil")
  -- the save keeps them
  wait(2.5)
  local sv = save.get("loose.bodies") or {}
  local nl = 0
  for _, e in ipairs(sv) do if e.pf == "LooseLog" then nl = nl + 1 end end
  V.check("the logs are in the save (loose.bodies)", nl >= 1, "%d LooseLog entries of %d", nl, #sv)
  if not best then V.result() return end
  -- pick it up with the gravity gun
  V.select_tool("gravgun")
  local Tl = function() return { x = best.x, y = best.y, z = best.z } end
  for k = 1, 90 do local err = FP.aim_step(Tl); yield(); if k > 25 and err < 0.5 then break end end
  input.simulate { button = 0, down = true }
  local t0, held = time, nil
  while time - t0 < 3.0 do FP.aim_step(Tl); yield(); if tb.holding and not held then held = tb.holding.name end end
  V.shot("log_held", true)
  FP.aim.pitch = (FP.aim.pitch or 0) + 0.25
  for _ = 1, 40 do yield() end
  V.shot("log_lifted", false)
  P("VP the gravity gun: holding %s; last try %s", tostring(tb.holding and tb.holding.name), tostring(tb.lastTry))
  input.simulate { button = 0, down = false }
  V.check("the gravity gun picks the log up", held ~= nil, "%s", tostring(held))
  V.result()
end

local function run_vbush()
  V.tag = "bush"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  local ff = findScript("flora_field")
  local u, t1, t2, R = base_frame()
  local q
  for _, dist in ipairs({ 90, 140, 200, 280, 380 }) do
    for k = 0, 7 do
      if q then break end
      local ang = k * math.pi / 4 + dist * 0.017
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 150)
      if gr then
        stand_at({ dir = dir, r = gr })
        wait(2.5)
        local a = astro()
        for _, p in ipairs(V.plants_near(a, 25, { bush = true, shrub = true })) do
          if not q and (p.height or 1) >= 0.7 then q = p; q.from = { x = a.x - home().x, y = a.y - home().y, z = a.z - home().z } end
        end
      end
    end
    if q then break end
  end
  V.check("a bush to brush past", q ~= nil, "%s", q and (q.kind .. " " .. tostring(q.name)) or "none")
  if not q then V.result() return end
  -- a photo camera 3.2 m off the bush, 1.6 m up, held on it (planet frame)
  local p0 = V.w(q)
  local U = V.up(p0)
  local from = q.from and MP.w(q.from) or astro()
  local T = unit(cross(U, flat(sub(p0, from), U)))   -- side-on to the crew's walk
  local cam = V.fixed_cam({ x = p0.x + U.x * 0.5, y = p0.y + U.y * 0.5, z = p0.z + U.z * 0.5 }, U, T, 2.4, 0.5)
  local function hold(secs) local t0 = time; while time - t0 < secs do V.place_cam(); yield() end end
  local function bush_nodes()
    local out = {}
    for _, n in ipairs(findTagged("flora")) do
      if n.valid and n.name == "Flora Bend" and tostring(n.model):find(q.kind == "bush" and "bush" or "", 1, true) then
        out[#out + 1] = n
      end
    end
    return out
  end
  -- before: the crew 6 m off
  FP.place(q, 6.0)
  hold(1.5)
  V.shot("before", false, cam)
  hold(0.3)
  -- walk into it: the crew a step at a time up to its root, from the camera's side
  local bent, nb = 0, 0
  for i = 1, 14 do
    FP.place(q, math.max(0.15, 3.0 - i * 0.22))
    hold(0.12)
    bent = math.max(bent, (ff.touchStats and ff.touchStats.bent) or 0)
  end
  hold(0.5)
  local nodes = bush_nodes()
  for i, n in ipairs(nodes) do
    local ok, m = pcall(function() return n:material() end)
    local parts = {}
    local okp, ml = pcall(function() return n:materials() end)
    for _, e in ipairs(okp and ml or {}) do parts[#parts + 1] = string.format("%s/%s textured %s overridden %s", tostring(e.object), tostring(e.material), tostring(e.textured), tostring(e.overridden)) end
    if i <= 6 then
      P("VP bend node %d model %s: own material texture %s colour %s; parts: %s", i, tostring(n.model), ok and m and tostring(m.texture) or "-",
        ok and m and m.color and string.format("%.2f %.2f %.2f", m.color[1] or m.color.r or 0, m.color[2] or m.color.g or 0, m.color[3] or m.color.b or 0) or "-", table.concat(parts, "; "))
    end
  end
  nb = #nodes
  V.check("walking into it bends it (a node stands in)", nb > 0, "%d %s bend nodes, touchStats.bent max %d", nb, q.kind, bent)
  hold(0.3)
  V.shot("bent", false, cam)
  -- back off: it springs back and is handed back to the field
  FP.place(q, 6.0)
  hold(4.0)
  V.shot("after", false, cam)
  hold(0.3)
  local left = #bush_nodes()
  V.check("and it is handed back", left == 0, "%d %s bend nodes left", left, q.kind)
  V.place_cam = nil
  if cam and cam.valid then cam:destroy() end
  V.result()
end

-- vflick: props beside a laser dig, every frame. The props within 14 m of the
-- dig point, as scatter.near answers (flora_field / mineral_field
-- groundAudit), split into those whose ground the bites reach (< 4 m) and
-- those whose ground is untouched (6–14 m); every frame's count, the frames
-- any of them was missing, the sources' declares (the fields' source counts
-- and ids) and the scripts' redeclare queues; a picture every 3rd frame from
-- a fixed camera.
local function run_vflick()
  V.tag = "flick"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  local ff, mf = findScript("flora_field"), findScript("mineral_field")
  local u, t1, t2, R = base_frame()
  local best, bn = nil, -1
  for _, dist in ipairs({ 150, 220 }) do
    for k = 0, 7 do
      local ang = k * math.pi / 4
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local gr = ground_r(home(), dir.x, dir.y, dir.z, R + 150)
      local sea = findScript("climate").seaRadius and findScript("climate").seaRadius(home().name) or 0
      if gr and gr > sea + 1 then
        stand_at({ dir = dir, r = gr })
        wait(2.0)
        local a = astro()
        local n = #V.plants_near(a, 14) + #(mf.groundAudit(a.x, a.y, a.z, 14, 5).props or {}) * 3
        if n > bn then best, bn = { dir = dir, r = gr }, n end
      end
    end
  end
  stand_at(best)
  wait(3)
  local a = astro()
  local U = V.up(a)
  local fw = flat(t2, U)
  local target = { x = a.x + fw.x * 6, y = a.y + fw.y * 6, z = a.z + fw.z * 6 }
  local trel = MP.ground_at(sub(target, home()))
  local Tg = function() return MP.w(trel) end
  local function census()
    local p = Tg()
    local near, far = {}, {}
    for _, A in ipairs({ ff.groundAudit(p.x, p.y, p.z, 14, 5), mf.groundAudit(p.x, p.y, p.z, 14, 5) }) do
      for _, q in ipairs(A.props or A.examples or {}) do
        local d = len(q.x - p.x, q.y - p.y, q.z - p.z)
        local key = tostring(q.kind) .. ":" .. tostring(q.id)
        if d < 4 then near[key] = true elseif d > 6 then far[key] = true end
      end
    end
    return near, far
  end
  local function srcset()
    local n = 0
    for _ in pairs(ff.sourceInfo and {} or {}) do n = n + 1 end
    return tostring(ff.sources or "?") .. "/" .. tostring(mf.sources or "?")
  end
  local cam = V.fixed_cam(Tg(), U, fw, 9.0, 3.0)
  V.select_tool("laser")
  for _ = 1, 60 do FP.aim_step(Tg); V.place_cam(); yield() end
  local base_near, base_far = census()
  local nf, nn = 0, 0
  for _ in pairs(base_far) do nf = nf + 1 end
  for _ in pairs(base_near) do nn = nn + 1 end
  P("VP before: %d props within 4 m of the dig, %d at 6–14 m; sources flora/rocks %s", nn, nf, srcset())
  local frames, miss_far, miss_near, worst_far, shots = 0, 0, 0, 0, 0
  local src_changes, last_src = 0, srcset()
  input.simulate { button = 0, down = true }
  local t0 = time
  while time - t0 < 6.0 do
    FP.aim_step(Tg); V.place_cam()
    if time - t0 > 4.0 then input.simulate { button = 0, down = false } end
    yield()
    frames = frames + 1
    local near, far = census()
    local gone = 0
    for k in pairs(base_far) do if not far[k] then gone = gone + 1 end end
    if gone > 0 then miss_far = miss_far + 1; worst_far = math.max(worst_far, gone) end
    local gn = 0
    for k in pairs(base_near) do if not near[k] then gn = gn + 1 end end
    if gn > 0 then miss_near = miss_near + 1 end
    local ss = srcset()
    if ss ~= last_src then src_changes = src_changes + 1; last_src = ss end
    if frames % 3 == 0 and shots < 40 then shots = shots + 1; V.shot(string.format("f%03d", frames), false, cam, 640, 360) end
    if frames % 20 == 0 then
      P("VP frame %d (%.1f s): untouched props missing %d of %d, near props missing %d of %d; sources %s; flora groundBusy %s, rocks %s; perf props %s",
        frames, time - t0, gone, nf, gn, nn, ss, tostring(ff.groundBusy and ff.groundBusy()), tostring(mf.groundBusy and mf.groundBusy()),
        tostring(perf and perf.counts and perf.counts().props))
    end
  end
  input.simulate { button = 0, down = false }
  local ys = mf.yieldStats or {}
  P("VP the dig removed %.1f m3 in %d reports this session", ys.removed or 0, ys.reports or 0)
  P("VP over %d frames: untouched props (6–14 m from the dig) missing in %d frames (worst %d of %d); near props missing in %d; source-count changes %d",
    frames, miss_far, worst_far, nf, miss_near, src_changes)
  V.check("untouched props never blink", miss_far == 0, "%d of %d frames had some missing (worst %d of %d)", miss_far, frames, worst_far, nf)
  V.check("no script redeclares a source for a dig", src_changes == 0, "%d changes", src_changes)
  V.place_cam = nil
  if cam and cam.valid then cam:destroy() end
  V.result()
end

-- vpaint: where terrain.paintTexture lands against where it was asked, on a
-- moving planet. terrain.slotAt cannot see paint (it reads the physics copy,
-- which a paint does not refresh), so the test is a dig: a 1.5 m ball of slot 7
-- (crystal) painted at a ground point, then small digs at it and 2.5 m to
-- each side, each dig's measured yield (mineral_field.trackDig / yieldStats).
local function run_vpaint()
  V.tag = "paint"
  wait(4)
  local mf = findScript("mineral_field")
  local u, t1, t2, R = base_frame()
  local dir = dir_at(u, t2, 160, R)
  stand_at({ dir = dir, r = ground_r(home(), dir.x, dir.y, dir.z, R + 150) })
  wait(4)
  local a = astro()
  local U = V.up(a)
  local A = math.abs(U.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local e1 = unit(cross(U, A)); local e2 = unit(cross(U, e1))
  local P0 = MP.ground_at(sub({ x = a.x + e1.x * 7, y = a.y + e1.y * 7, z = a.z + e1.z * 7 }, home()))
  local b = home()
  local id = terrain.paintTexture(b.x + P0.x - U.x * 0.4, b.y + P0.y - U.y * 0.4, b.z + P0.z - U.z * 0.4, 1.5, 7)
  wait(1.5)
  local res, total = {}, 0
  for _, o in ipairs({ { 0, 0, "middle" }, { 2.5, 0, "+e1" }, { -2.5, 0, "-e1" }, { 0, 2.5, "+e2" }, { 0, -2.5, "-e2" } }) do
    local g = MP.ground_at({ x = P0.x + e1.x * o[1] + e2.x * o[2], y = P0.y + e1.y * o[1] + e2.y * o[2], z = P0.z + e1.z * o[1] + e2.z * o[2] })
    local s0 = MP.stats_copy()
    local bb = home()
    local wx, wy, wz = bb.x + g.x - U.x * 0.2, bb.y + g.y - U.y * 0.2, bb.z + g.z - U.z * 0.2
    local rid = terrain.dig(wx, wy, wz, 0.8, 1.0)
    mf.trackDig(rid, wx, wy, wz, "astro")
    wait(1.0)
    local s1 = MP.stats_copy()
    local cv = (s1.vol.crystal or 0) - (s0.vol.crystal or 0)
    local all = 0
    for m, v in pairs(s1.vol) do all = all + v - (s0.vol[m] or 0) end
    res[#res + 1] = string.format("%s %.2f of %.2f m3", o[3], cv, all)
    total = total + cv
    if o[3] == "middle" then res.mid = cv end
  end
  P("VP paint receipt %s; the painted slot (crystal) in each dig: %s", tostring(id), table.concat(res, ", "))
  V.check("paint lands where asked", (res.mid or 0) > 0 and (res.mid or 0) >= total * 0.5, "middle %.2f of %.2f m3 painted volume found", res.mid or 0, total)
  V.result()
end
