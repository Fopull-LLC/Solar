-- ── full builder probe (tools/perf/fullbuildprobe.sh): playtest 11-09 ───────
-- Spliced after vfxprobe_modes.lua, buildkitprobe_modes.lua (BK) and
-- kitprobe_modes.lua (KIT). One `BK PASS|FAIL <check>` a check, `FB` lines.
FB = {}

-- the tower's placement reasons at a few spots (hold it, aim at the ground)
function FB.tower_reasons(fb, tag)
  local cp = findScript("catalog_panel")
  if cp and cp.pickPart then cp.pickPart("tower") else fb.hold("tower") end
  local out = {}
  for _, s in ipairs({ { 8, 0 }, { 12, 4 }, { 10, -6 }, { 16, 0 } }) do
    BK.aim_at(s[1], s[2])
    BK.settle(40)
    local r = fb.req
    local why = r and (r.bad or "valid") or "no req"
    local p = r and r.pose
    P("FB tower %s at %d,%d: %s (mode %s, hit %s)", tag, s[1], s[2], tostring(why), p and tostring(p.mode) or "-",
      p and p.node and tostring(p.node.name) or "-")
    out[#out + 1] = why
  end
  return out
end

function FB.setup(spot)
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  local pc0 = findScript("planet_camera")
  local U = unit(sub(astro(), home()))
  local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
  BK.F = unit(sub(f, scl(U, dot(f, U))))
end

function FB.run_diag()
  BK.tag = "fbdiag"
  wait_ready(120)
  wait(2)
  local fb, C, BS = findScript("field_builder"), findScript("crew"), findScript("bases")
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  local spot = BK.flat_spot()
  FB.setup(spot)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "kit open (gate %s)", tostring(fb.gate))
  local bb = home()
  P("FB world radius %.0f m, spot %.0f m from the base", bb.radius or -1, spot.d or -1)
  FB.tower_reasons(fb, "near")
  fb.dropHeld()
  KIT.close(fb)
  local far = BK.far_spot()
  if far then
    FB.setup(far)
    tap("b"); wait(1.5)
    P("FB far spot %.0f m round", far.d or -1)
    local r = FB.tower_reasons(fb, "far")
    BK.check("far_valid", r[1] == "valid" or r[2] == "valid" or r[3] == "valid", "a tower can go somewhere on the far side")
  end
  BK.result()
end

-- ── the 11-09 fixes in the engine ───────────────────────────────────────────
-- the flattest dry ground `dmin`–`dmax` m out from the base (BK.flat_spot's search)
function FB.spot_at(dists)
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local bf = findScript("base_facilities")
  local best
  for _, d in ipairs(dists) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if g0 then
        local rough, n = 0, 0
        local s = unit(cross(dir, t))
        for _, e in ipairs({ { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 }, { 8, 0 }, { 0, 8 }, { -8, 0 }, { 0, -8 }, { 12, 0 }, { 0, 12 } }) do
          local dd = unit({ x = dir.x * R + t.x * e[1] + s.x * e[2], y = dir.y * R + t.y * e[1] + s.y * e[2], z = dir.z * R + t.z * e[1] + s.z * e[2] })
          local g = ground_r(b, dd.x, dd.y, dd.z, R + 150)
          if g then rough = rough + math.abs(g - g0); n = n + 1 end
        end
        local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
        local wet = (cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)) or (cl and cl.seaDepth and (cl.seaDepth(p.x, p.y, p.z) or 0) > -1.0)
        local kept = bf and bf.keepClear and bf.keepClear(b.name, dir.x * g0, dir.y * g0, dir.z * g0)
        if n >= 8 and not wet and not kept then
          local score = rough / n
          if not best or score < best.score then best = { dir = dir, r = g0, t = t, d = d, score = score } end
        end
      end
    end
  end
  return best
end

function FB.engineer()
  local C = findScript("crew")
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
end

function FB.run_fix()
  BK.tag = "fbfix"
  wait_ready(120)
  wait(2)
  local fb, ST, KS, IG = findScript("field_builder"), findScript("structures"), findScript("kit_snap"), findScript("input_guard")
  FB.engineer()
  local spot = FB.spot_free({ 340, 380, 420 })
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  FB.setup(spot)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "kit open (gate %s)", tostring(fb.gate))
  -- 1. SNAPS: a slab, a wall dialled 15° off: a quarter turn exactly
  fb.hold("slab2.concrete")
  local g = BK.ground_ahead(7, 0)
  local sid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node)
  if not BK.check("slab", sid ~= nil, "a slab founds a structure") then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  fb.yawOffset = math.rad(15)
  local wu, wp = KIT.put(fb, rec, "wall.steel", { 0.2, 3, 0.75 }, { 0.2, -2, 0.75 }, "wall dialled 15°")
  local q = wp and (wp.yaw or 0) / (math.pi / 2)
  BK.check("wall_exact", wp and math.abs(q - math.floor(q + 0.5)) < 1e-9 and math.abs(wp.y - 0.2) < 1e-9,
    "a wall on the slab's edge with the wheel at 15°: yaw %.9f quarter turns, y %.9f", q or -1, wp and wp.y or -1)
  fb.yawOffset = 0
  -- a slab set on the ground 6 m off: JOINS the structure, in its frame
  fb.hold("slab2.concrete")
  local g2 = BK.ground_ahead(13, 0.3)
  local s2, w2, _, u2 = fb.placeAt(g2.x, g2.y, g2.z, g2.nx, g2.ny, g2.nz, g2.node)
  local p2 = s2 and ST.getPart(s2, u2)
  BK.check("join", s2 == sid and p2 and math.abs(p2.x * 2 - math.floor(p2.x * 2 + 0.5)) < 1e-9 and math.abs(p2.z * 2 - math.floor(p2.z * 2 + 0.5)) < 1e-9
    and math.abs(math.sin(2 * (p2.yaw or 0))) < 1e-9 and p2.gnd == true,
    "a slab on the ground 6 m off joins the structure on its grid (%s: %.3f, %.3f, %.3f, yaw %.4f, gnd %s)", tostring(s2 or w2), p2 and p2.x or -1,
    p2 and p2.y or -1, p2 and p2.z or -1, p2 and p2.yaw or -1, tostring(p2 and p2.gnd))
  -- 2. SUPPORT THROUGH CONNECTIONS: walls round the first slab, a roof, two
  -- modules of balcony off the roof (Career)
  rec = ST.get(sid)
  local W = {}
  for _, w in ipairs({ { 0.2, -0.75 }, { 0.75, 0.2 }, { -0.75, 0.2 } }) do
    W[#W + 1] = KIT.put(fb, rec, "wall.steel", { w[1], 3, w[2] }, { w[1], -2, w[2] }, "wall")
  end
  local r1 = KIT.put(fb, rec, "floor.steel", { 0, 5, 1 }, { 0, 1, 1 }, "roof")
  -- off the roof's back edge: the first rests on the back wall's top, the
  -- next two reach out from it (2 and 4 m of cantilever), a fourth is refused
  local prev = r1
  local placed = {}
  for i = 1, 3 do
    rec = ST.get(sid)
    local pp = prev and ST.getPart(sid, prev)
    local nb = pp and KIT.put(fb, rec, "floor.steel", { pp.x, pp.y + 0.1, pp.z - 3.5 }, { pp.x, pp.y + 0.1, pp.z + 0.5 }, "balcony " .. i)
    placed[i] = nb
    prev = nb
  end
  BK.check("balcony", r1 and placed[1] and placed[2] and placed[3], "a roof on the walls, and a balcony three modules out from it (two of them cantilevered) are held (Career): %s %s %s %s",
    tostring(r1), tostring(placed[1]), tostring(placed[2]), tostring(placed[3]))
  rec = ST.get(sid)
  local bp3 = placed[3] and ST.getPart(sid, placed[3])
  if bp3 then
    fb.hold("floor.steel")
    yield()
    local h3 = KIT.ray(rec, { bp3.x, bp3.y + 0.1, bp3.z - 3.5 }, { bp3.x, bp3.y + 0.1, bp3.z + 0.5 })
    local pz = h3 and fb.pose(h3)
    local rq = pz and fb.validity("floor.steel", pz)
    BK.check("balcony4", rq and rq.bad and tostring(rq.bad):find("holds", 1, true), "a third cantilevered module is refused: %s", rq and tostring(rq.bad) or "-")
  end
  fb.dropHeld()
  BK.shot("fx1_balcony", false)
  -- 3. THE SEARCH FIELD KEEPS ITS KEYS
  local inv, pw = findScript("inventory_panel"), findScript("planet_walker")
  fb.hold("wall.steel")
  yield()
  local f = find("FieldPartSearch")
  if f and ui and ui.focus then ui.focus(f) end
  wait(0.3)
  local a = astro()
  local U = unit(sub(a, home()))
  local y0 = dot(sub(a, home()), U)
  local held0 = fb.heldPart
  do
    local ff = ui and ui.focused and ui.focused()
    P("FB focus %s · typing %s · guarded %s · panel field %s", tostring(ff and ff.name), tostring(IG and IG.typing()), tostring(rawget(input, "__guarded")), tostring(f ~= nil))
  end
  -- (Tab last: the engine's UI moves the focus on Tab, as any form does)
  for _, k in ipairs({ "i", "space", "e", "b", "3", "w", "m", "g", "r", "backspace", "tab" }) do
    tap(k); wait(0.1)
    do
      local ff = ui.focused and ui.focused()
      local f2 = find("FieldPartSearch")
      P("FB typing after %s: focused %s (field node %s → %s), inventory %s, kit %s, typing %s", k, tostring(ff and ff.name), tostring(f and f.id), tostring(f2 and f2.id),
        tostring(inv and inv.open), tostring(fb.isOpen()), tostring(IG and IG.typing()))
    end
  end
  input.simulate { text = "wall" }
  wait(0.6)
  local y1 = dot(sub(astro(), home()), U)
  BK.check("typing", IG and IG.typing() and not (inv and inv.open) and math.abs(y1 - y0) < 0.25 and fb.isOpen() and fb.heldPart == held0,
    "typing in the search: no inventory (%s), no jump (%.2f m), the kit still open (%s), the part in hand kept (%s → %s)",
    tostring(inv and inv.open), y1 - y0, tostring(fb.isOpen()), tostring(held0), tostring(fb.heldPart))
  BK.shot("fx2_typing", true)
  if ui and ui.focus then ui.focus(nil) end
  wait(0.3)
  fb.dropHeld()
  -- 4. THE TOWER, 360+ m out from the spaceport
  fb.hold("tower")
  BK.aim_at(10, 6)
  BK.settle(40)
  BK.check("tower_ok", fb.req and not fb.req.bad, "a tower %.0f m from the spaceport: %s", spot.d, fb.req and tostring(fb.req.bad or "valid") or "no req")
  BK.click(false)
  wait(1.5)
  local BT = findScript("base_tower")
  if BT and BT.prompting and BT.prompting() and BT.commitName then BT.commitName("Probe Ridge") end
  local BS = findScript("bases")
  BK.check("tower_placed", fb.lastPlace and fb.lastPlace.id == "tower" and BS and BS.count() >= 1, "the tower stands and founds a base (%d)", BS and BS.count() or -1)
  KIT.close(fb)
  wait(2)
  BK.shot("fx3_tower", false)
  BK.result()
end


-- ── THE BASE HUB ────────────────────────────────────────────────────────────
-- a structure part at a frame pose → the builder (its box centre, y from the floor + floor_y)
function FB.bput(B, BH, id, lx, ly, lz, yaw, pitch, roll, size)
  local bp = BH.toBuilder({ id = 0, bp = { { uid = 1, id = id, x = lx, y = ly, z = lz, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0 } } }, {})
  local c = bp.parts[1]
  if not c then P("FB bput %s: not a base part", id) return nil end
  return B.cmd("place", { id = id, x = c.x, y = c.y + 0.11, z = c.z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0 })
end
-- a VAB part with its box centre at a frame point (y from the floor)
function FB.vput(B, id, x, y, z, yaw, pitch, roll, size)
  return B.cmd("place", { id = id, x = x, y = y + 0.11, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0, size = size })
end
-- open the hub's builder from its menu, wait for it
function FB.open_hub(sid, uid)
  local ST, bh = findScript("structures"), findScript("build_host")
  local node = ST.nodeOf(sid, uid)
  local list = BK.menu(node)
  local e = BK.entry(list, "hub_build")
  if not e then P("FB hub menu: %d entries, none to build", #list) return nil end
  local ok, why = BK.run_entry(e)
  P("FB hub menu: Build the base → %s %s", tostring(ok), tostring(why or ""))
  wait_for(function() return bh.state == "building" end, 30, "the hub's builder")
  wait(2.5)
  local B = findScript("builder")
  return B, bh
end
function FB.place_hub(fb, ahead, side)
  local sid, why, q, uid
  for _, o in ipairs({ { ahead, side or 0 }, { ahead, 0 }, { ahead + 3, 2 }, { 5, -5 }, { 5, 5 }, { 9, 0 }, { 4, 0 } }) do
    fb.hold("baseHub")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why, q, uid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    P("FB hub placed at %d,%d: %s %s", o[1], o[2], tostring(sid), tostring(why or ""))
    if sid then break end
  end
  wait(1.0)
  return sid, uid
end
-- the builder frame's local point → this frame's world (the hub's structure)
function FB.fw(bh, x, y, z)
  local fr = bh.frameNode()
  if not fr then return nil end
  local w = fr:toWorld(vec3(x, y, z))
  return w
end

function FB.run_hub()
  BK.tag = "fbhub"
  wait_ready(120)
  wait(2)
  local fb, ST, co, BH, SL = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("base_hub"), findScript("struct_live")
  FB.engineer()
  local rs0 = findScript("research")
  for id in pairs(rs0.TECH or {}) do pcall(rs0.grant, id, "probe") end
  local spot = FB.spot_at({ 200, 240, 280 })
  FB.setup(spot)
  tap("b"); wait(1.5)
  local sid, uid = FB.place_hub(fb, 8, -3)
  if not BK.check("hub", sid ~= nil and ST.getPart(sid, uid).id == "baseHub", "a Base Hub placed with the Build Kit") then BK.result() return end
  KIT.close(fb)
  local funds0 = co.balance()
  local B, bh = FB.open_hub(sid, uid)
  BK.check("open", B and bh.state == "building" and B.hubMode and B.hubMode() and ST.suspended(sid), "the hub's menu opens the full builder on the base (suspended %s)",
    tostring(ST.suspended(sid)))
  if not B then BK.result() return end
  local titles = {}
  for _, sec in ipairs(B.catalogue()) do titles[#titles + 1] = sec.title .. ":" .. #sec.ids end
  P("FB catalogue: %s", table.concat(titles, " "))
  local tset = {}
  for _, sec in ipairs(B.catalogue()) do tset[sec.title] = #sec.ids end
  BK.check("catalogue", tset.COMMAND and tset.PROPULSION and tset.BASE and tset.WALL and tset.FLOOR and tset.FLUID and tset.POWER and tset["BASE NUCLEAR"]
    and tset["BASE FRAME"] and tset.PROPS, "every section: the VAB's and every base category")
  BK.shot("fh1_open", true)
  -- pieces through the builder's own command, at exact frame poses
  local slabs = { { 4, 0 }, { 6, 0 }, { 4, 2 }, { 6, 2 } }
  for _, s in ipairs(slabs) do FB.bput(B, BH, "slab2.concrete", s[1], 0, s[2]) end
  FB.bput(B, BH, "wall.steel", 4, 0.2, -1, math.pi)
  FB.bput(B, BH, "windowWall.steel", 6, 0.2, -1, math.pi)
  FB.bput(B, BH, "wall.steel", 7, 0.2, 0, math.pi / 2)
  FB.bput(B, BH, "wall.steel", 3, 0.2, 0, -math.pi / 2)
  wait(1.0)
  -- a wall through the ghost, as a player: pick it, aim at the slab's +Z edge, click
  local bc = findScript("builder_camera")
  if bc and bc.setCamState then bc.setCamState({ P = { x = 5.5, y = 0.6, z = 1.5 }, yaw = 0.5, pitch = -0.75, d = 9.0 }) end
  wait(0.8)
  B.pick("wall.steel")
  wait(0.5)
  local tgt = { 6.3, 0.2 + 0.11, 2.85 }
  for _ = 1, 20 do
    local w = FB.fw(bh, tgt[1], tgt[2], tgt[3])
    local sx, sy, _, on = camera.worldToScreen(w.x, w.y, w.z)
    if sx then input.simulate { mouse = { sx, sy } } end
    yield()
  end
  input.simulate { button = 0, down = true }; yield(); yield()
  input.simulate { button = 0, down = false }; yield(); yield()
  wait(0.4)
  local list = B.hubParts()
  local ents = BH.fromBuilder(list, findScript("parts_registry").REG)
  local gw = nil
  for _, e in ipairs(ents) do if e.id == "wall.steel" and e.z > 2.5 then gw = e end end
  BK.check("ghost_wall", gw and math.abs(gw.y - 0.2) < 1e-6 and math.abs(gw.z - 3) < 1e-6 and math.abs(gw.x - 6) < 1e-6 and math.abs(math.sin(gw.yaw * 2)) < 1e-9,
    "a wall placed through the ghost snaps exactly to the slab's edge: %s", gw and string.format("(%.6f, %.6f, %.6f) yaw %.6f", gw.x, gw.y, gw.z, gw.yaw) or "none")
  -- VAB parts: an I-beam column, a cockpit on top, two engines bolted to the side, a dish
  FB.vput(B, "ibeam3", 8.5, 1.5, 1, 0, 0, 0)
  FB.vput(B, "cockpit", 8.5, 3.0 + 0.5, 1, 0, math.pi / 2, 0)
  FB.vput(B, "engineM", 9.2, 1.6, 1, 0, 0, 0)
  FB.vput(B, "dish", 4, 2.75, -1, 0, 0, 0)
  wait(1.0)
  local n_b = #B.hubParts()
  BK.shot("fh2_built", true)
  B.doLaunch()
  wait_for(function() return bh.state == "idle" end, 15, "the commit")
  wait(3.0)
  local ex = bh.lastHubExit
  local rec = ST.get(sid)
  local lps = save.get("slivebp." .. tostring(sid))
  local nl = 0
  for _ in pairs(type(lps) == "table" and lps or {}) do nl = nl + 1 end
  BK.check("commit", ex and ex.ok and rec and #rec.bp == n_b and nl == 4 and not ST.suspended(sid),
    "BUILD IT: %s · %d parts in the base (%d in the builder), %d VAB records · %s", tostring(ex and ex.msg), rec and #rec.bp or -1, n_b, nl,
    co.money(funds0 - co.balance()))
  wait_for(function() return SL.vesselOf(sid) ~= nil end, 10, "the structure vessel")
  wait(2)
  local v = SL.vesselOf(sid)
  local vc = SL.controllerOf and SL.controllerOf(sid)
  BK.check("vessel", v ~= nil, "the live parts are the anchored structure vessel (%s)", tostring(v and v.name))
  -- pictures from the world, two sides
  rec = ST.get(sid)
  KIT.view("fh3_world_a", rec, { 14, 6, 12 }, { 5, 1.2, 1 })
  KIT.view("fh4_world_b", rec, { -6, 5, -9 }, { 5, 1.2, 1 })
  -- open again: everything comes back, LEAVE changes nothing
  local f1 = co.balance()
  B, bh = FB.open_hub(sid, uid)
  local n2 = B and #B.hubParts() or -1
  if B then B.doLeave() end
  wait_for(function() return bh.state == "idle" end, 15, "leave")
  wait(1)
  BK.check("reopen", n2 == n_b and co.balance() == f1, "the hub opens with all %d parts again; LEAVE without a change costs nothing (%d)", n2, f1 - co.balance())
  FB.stand_mixed(fb, ST)
  BK.result()
end

-- A Build Stand's builder lists the base parts too: a pod with a wall bolted
-- on top, commissioned into a held craft (do kit prefabs make a vessel?)
function FB.stand_mixed(fb, ST)
  local CS, bh = findScript("craft_stand"), findScript("build_host")
  tap("b"); wait(1.2)
  fb.hold("stand")
  local g = BK.ground_ahead(7, 5)
  local sid, why, _, uid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node)
  KIT.close(fb)
  if not BK.check("stand", sid ~= nil, "a Build Stand placed (%s)", tostring(why or "ok")) then return end
  wait(1.5)
  local ok, w = bh.enter({ stand = { sid = sid, uid = uid } })
  wait_for(function() return bh.state == "building" end, 30, "the stand's builder")
  wait(2.5)
  local B = findScript("builder")
  local tset = {}
  for _, sec in ipairs(B.catalogue()) do tset[sec.title] = #sec.ids end
  BK.check("stand_catalogue", tset.WALL and tset.BASE and tset.COMMAND, "the stand's builder lists the base sections too (WALL %s, BASE %s)", tostring(tset.WALL), tostring(tset.BASE))
  local pu = B.cmd("place", { id = "pod", x = 0, y = 0.11 + 0.4, z = 0 })
  local wu = FB.bput(B, findScript("base_hub"), "wall.steel", 0, 0.8, 0, 0)
  wait(1.0)
  B.doLaunch(); wait(0.5); B.doLaunch()
  wait_for(function() return bh.state == "idle" end, 15, "commission")
  wait(4.0)
  local E = CS.heldOf(sid, uid)
  local info = E and E.node and assembly.info(E.node)
  BK.check("stand_mixed", E and E.phase == "held" and E.total == 2 and #E.placed == 2 and info and info.mass and info.mass > 0,
    "a pod with a wall on it commissioned from the stand: %s, %s parts, mass %s t (%s)", E and tostring(E.phase) or "none", E and tostring(#E.placed) or "-",
    info and string.format("%.2f", info.mass or -1) or "-", tostring(bh.lastStandExit and bh.lastStandExit.cwhy or ""))
  KIT.view("fh5_stand_mixed", ST.get(sid), { 5, 3, 5 }, { 0, 1.5, 0 })
end

-- ── fbmake: five player-style creations through the Base Hub's builder ──────
do
FB.used = {}
local function far_from_used(dir, R)
  for _, u in ipairs(FB.used) do
    local c = math.max(-1, math.min(1, dot(dir, u.dir)))
    if math.acos(c) * R < 70 then return false end
  end
  return true
end
function FB.spot_free(dists)
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local bf = findScript("base_facilities")
  local best
  for _, d in ipairs(dists) do
    for k = 0, 35 do
      local ang = k * math.pi / 18
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      if far_from_used(dir, R) then
        local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 150)
        if g0 then
          local rough, n = 0, 0
          local s = unit(cross(dir, t))
          for _, e in ipairs({ { 6, 0 }, { -6, 0 }, { 0, 6 }, { 0, -6 }, { 12, 0 }, { 0, 12 }, { -12, 0 }, { 0, -12 }, { 6, -18 }, { -6, -18 }, { 0, -20 } }) do
            local dd = unit({ x = dir.x * R + t.x * e[1] + s.x * e[2], y = dir.y * R + t.y * e[1] + s.y * e[2], z = dir.z * R + t.z * e[1] + s.z * e[2] })
            local g = ground_r(b, dd.x, dd.y, dd.z, R + 150)
            if g then rough = rough + math.abs(g - g0); n = n + 1 end
          end
          local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
          local wet = (cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)) or (cl and cl.seaDepth and (cl.seaDepth(p.x, p.y, p.z) or 0) > -1.0)
          local kept = bf and bf.keepClear and bf.keepClear(b.name, dir.x * g0, dir.y * g0, dir.z * g0)
          if n >= 10 and not wet and not kept then
            local score = rough / n
            if not best or score < best.score then best = { dir = dir, r = g0, t = t, d = d, score = score } end
          end
        end
      end
    end
  end
  return best
end

local Q = math.pi / 2
-- the builder's id for a kit piece is its structure id; a VAB part's its registry id
local function K(B, BH, id, x, y, z, yaw, pitch, roll) return FB.bput(B, BH, id, x, y, z, yaw, pitch, roll) end
local function V(B, id, x, y, z, yaw, pitch, roll, size) return FB.vput(B, id, x, y, z, yaw, pitch, roll, size) end

FB.MAKE = {}
-- 1. A REFUELLING OUTPOST: a slab pad, a fuel farm piped to a hose stand
-- (tank → pipe → pump → gate valve → gauge → pipe → hose), solar arrays and a
-- battery bank, VAB solar panels and batteries on a rack, floodlights on poles
FB.MAKE[1] = { name = "refuel", title = "Refuelling Outpost", eye = { { 18, 9, 6 }, { 0, 1, -8 } }, eye2 = { { -16, 7, -20 }, { 0, 1, -8 } },
  build = function(B, BH)
    for _, x in ipairs({ 3, 5, 7, 9 }) do for _, z in ipairs({ -5, -7, -9, -11 }) do K(B, BH, "slab2.concrete", x, 0, z) end end
    for _, x in ipairs({ -5, -3, -1, 1 }) do for _, z in ipairs({ -5, -7, -9 }) do K(B, BH, "slab2.concrete", x, 0, z) end end
    K(B, BH, "flTankFuel.steel", -5, 0.2, -7, -Q)
    K(B, BH, "flPipe2.steel", -3, 0.2, -7, Q)
    K(B, BH, "flPump.steel", -1.5, 0.2, -7, Q)
    K(B, BH, "flValve.steel", -0.75, 0.2, -7, Q)
    K(B, BH, "flGauge.steel", -0.25, 0.2, -7, Q)
    K(B, BH, "flPipe2.steel", 1, 0.2, -7, Q)
    K(B, BH, "flHose.steel", 2.5, 0.2, -7, Q)
    K(B, BH, "flTankFuel.steel", -5, 0.2, -4.6, -Q)
    K(B, BH, "flTankWater.steel", -2.6, 0.2, -9.2, -Q)
    K(B, BH, "flVent.steel", 0.4, 0.2, -9.4, 0)
    -- the power plant
    K(B, BH, "solarArray", -9, 0, -3, 0)
    K(B, BH, "solarArray", -9, 0, -7, 0)
    K(B, BH, "batteryBank", -9, 0, -11, Q)
    for i = 0, 2 do V(B, "solar", -6.5 + i * 1.0, 0.35, -11.2, 0, 0, 0) end
    V(B, "battery", -4.0, 0.5, -11.0, 0, 0, 0)
    K(B, BH, "junctionBox.steel", -2.6, 0.2, -5.0, Q)
    -- floodlights on two 4.4 m pillars at the pad's corners
    for _, c in ipairs({ { 2.2, -11.8 }, { 9.8, -4.2 } }) do
      K(B, BH, "pillar4.steel", c[1], 0.2, c[2], 0)
      V(B, "light", c[1], 4.6 + 0.15, c[2], 0, 0, 0)
    end
  end }
-- 2. A PRESSURISED TWO-STOREY HAB: slabs, an airlock chamber (two Airlock
-- Walls), a ship's ladder up through a hatch floor, porthole and window walls,
-- an O2 generator, a scrubber, an air tank rack and an airlock receiver,
-- ceiling lights; its doors open for the crew on their own (no logic)
FB.MAKE[2] = { name = "hab", title = "Two-Storey Hab", eye = { { 13, 7, 4 }, { 5, 2.4, -5 } }, eye2 = { { -6, 9, -15 }, { 5, 2.4, -5 } },
  build = function(B, BH)
    for _, x in ipairs({ 4, 6 }) do for _, z in ipairs({ -4, -6 }) do K(B, BH, "slab2.concrete", x, 0, z) end end
    local function storey(y, list) for _, w in ipairs(list) do K(B, BH, w[1], w[2], y, w[3], w[4]) end end
    storey(0.2, { { "wall.steel", 4, -7, math.pi }, { "porthole.steel", 6, -7, math.pi },
                  { "airlockWall.steel", 4, -3, 0 }, { "windowWall.steel", 6, -3, 0 },
                  { "wall.steel", 7, -4, Q }, { "windowWall.steel", 7, -6, Q },
                  { "wall.steel", 3, -4, -Q }, { "wall.steel", 3, -6, -Q },
                  { "airlockWall.steel", 4, -5, 0 }, { "wall.steel", 5, -4, Q } })
    K(B, BH, "floor.steel", 4, 2.4, -4); K(B, BH, "floor.steel", 6, 2.4, -4); K(B, BH, "floor.steel", 4, 2.4, -6)
    K(B, BH, "floorHatch.steel", 6, 2.4, -6)
    K(B, BH, "ladder.steel", 6.2, 0.2, -5.7, 0)
    storey(2.6, { { "wall.steel", 4, -7, math.pi }, { "wall.steel", 6, -7, math.pi },
                  { "windowWall.steel", 4, -3, 0 }, { "wall.steel", 6, -3, 0 },
                  { "porthole.steel", 7, -4, Q }, { "wall.steel", 7, -6, Q },
                  { "wall.steel", 3, -4, -Q }, { "windowWall.steel", 3, -6, -Q } })
    for _, x in ipairs({ 4, 6 }) do for _, z in ipairs({ -4, -6 }) do K(B, BH, "floor.steel", x, 4.8, z) end end
    -- life support
    K(B, BH, "o2gen.steel", 3.7, 0.2, -6.4, 0)
    K(B, BH, "scrubber.steel", 4.65, 0.2, -6.5, 0)
    K(B, BH, "airReceiver.steel", 3.6, 0.2, -4.45, 0)
    K(B, BH, "airTank.steel", 4.0, 2.6, -6.6, 0)
    -- ceiling lights (mounts under the floors, face down)
    K(B, BH, "lightFitting.steel", 6, 2.4, -4, 0, math.pi)
    K(B, BH, "lightFitting.steel", 4, 2.4, -4, 0, math.pi)
    K(B, BH, "lightFitting.steel", 5, 4.8, -5, 0, math.pi)
    K(B, BH, "steps.steel", 4, 0, -2.0, 0)
  end }
-- 3. A REACTOR-POWERED INDUSTRIAL SHED: a 10 x 12 m slab floor, walls with a
-- double door and louvred upper walls, a roof of deck panels; inside a 5 x 5
-- core (nine fuel channels, graphite, four control rods) on its vessel base,
-- the primary loop to a coolant pump and a steam generator, a turbine set, a
-- pressuriser and the control console; a radiator panel outside
FB.MAKE[3] = { name = "reactor", title = "Reactor Shed", eye = { { 13, 12, 4 }, { 0, 1.5, -9 } }, eye2 = { { 4.2, 4.0, -3.6 }, { -0.5, 1.2, -11 } },
  build = function(B, BH)
    for _, x in ipairs({ -4, -2, 0, 2, 4 }) do for _, z in ipairs({ -4, -6, -8, -10, -12, -14 }) do K(B, BH, "slab2.concrete", x, 0, z) end end
    K(B, BH, "reactorBase.steel", 0, 0.2, -6, math.pi)
    for i = -2, 2 do
      for k = -2, 2 do
        local x, z = i * 0.5, -6 + k * 0.5
        local id
        if math.abs(i) <= 1 and math.abs(k) <= 1 then id = "fuelChannel.steel"
        elseif math.abs(i) == 2 and math.abs(k) == 2 then id = "controlRod.steel"
        else id = "modGraphite.graphite" end
        K(B, BH, id, x, 1.2, z, 0)
      end
    end
    K(B, BH, "pipe2.steel", 0, 0.2, -8.5, 0)
    K(B, BH, "coolantPump.steel", 0, 0.2, -10.5, math.pi)
    K(B, BH, "steamGen.steel", -0.5, 0.2, -12.5, math.pi)
    K(B, BH, "turbineSet.steel", -1, 0.2, -14.5, math.pi)
    K(B, BH, "pressuriser.steel", 2.4, 0.2, -10.4, 0)
    K(B, BH, "reactorConsole.steel", 3.6, 0.2, -5.0, -Q)
    -- the shed: walls, a double door, louvred upper walls, a deck roof
    for _, z in ipairs({ -4, -6, -8, -10, -12, -14 }) do
      K(B, BH, "wall.steel", -5, 0.2, z, -Q); K(B, BH, "ventWall.steel", -5, 2.4, z, -Q)
      K(B, BH, "wall.steel", 5, 0.2, z, Q); K(B, BH, "ventWall.steel", 5, 2.4, z, Q)
    end
    for _, x in ipairs({ -4, -2, 0, 2, 4 }) do K(B, BH, "wall.steel", x, 0.2, -15, math.pi); K(B, BH, "ventWall.steel", x, 2.4, -15, math.pi) end
    K(B, BH, "wall.steel", -4, 0.2, -3, 0); K(B, BH, "wall.steel", -2, 0.2, -3, 0)
    K(B, BH, "doubleDoor.steel", 1, 0.2, -3, 0); K(B, BH, "wall.steel", 4, 0.2, -3, 0)
    for _, x in ipairs({ -4, -2, 0, 2, 4 }) do K(B, BH, "ventWall.steel", x, 2.4, -3, 0) end
    for _, x in ipairs({ -4, -2, 0, 2, 4 }) do for _, z in ipairs({ -4, -6, -8, -10, -12, -14 }) do K(B, BH, "floor.steel", x, 4.6, z) end end
    K(B, BH, "lightFitting.steel", 0, 4.6, -9, 0, math.pi)
    K(B, BH, "lightFitting.steel", 0, 4.6, -5, 0, math.pi)
    K(B, BH, "lightFitting.steel", 0, 4.6, -13, 0, math.pi)
    K(B, BH, "radiatorPanel.steel", 7.5, 0, -10, Q)
  end }
-- 4. A WEIRD CONTRAPTION: a truss tower with a cockpit on top, four rocket
-- engines and two tanks bolted round it, and a box-beam lattice bridge from it
-- to a second tower 12 m off, with deck plates and cross beams
FB.MAKE[4] = { name = "contraption", title = "Rocket Tower Bridge", eye = { { 16, 9, -2 }, { 4, 6, -12 } }, eye2 = { { -9, 4, -14 }, { 4, 6, -11 } },
  build = function(B, BH)
    for _, z in ipairs({ -6, -18 }) do
      K(B, BH, "slab2.concrete", 4, 0, z)
      K(B, BH, "truss4.steel", 4, 0.2, z, 0); K(B, BH, "truss4.steel", 4, 4.2, z, 0); K(B, BH, "trussNode.steel", 4, 8.2, z, 0)
    end
    V(B, "cockpit", 4, 8.7 + 1.1, -6, 0, 0, 0)
    for _, o in ipairs({ { 0.62, 0 }, { -0.62, 0 }, { 0, 0.62 }, { 0, -0.62 } }) do V(B, "engineM", 4 + o[1], 5.6, -6 + o[2], 0, 0, 0) end
    V(B, "tankM", 4.7, 2.6, -6, 0, 0, 0); V(B, "tankM", 3.3, 2.6, -6, 0, 0, 0)
    -- the bridge: two rails of I-beams laid along -Z, cross beams, deck plates
    for _, x in ipairs({ 3.6, 4.4 }) do for i = 0, 3 do V(B, "ibeam3", x, 8.45, -7.75 - i * 3, 0, Q, 0) end end
    for i = 0, 7 do V(B, "beam1", 4, 8.45, -7.0 - i * 1.5, 0, 0, Q) end
    for i = 0, 5 do V(B, "panel3", 4, 8.62, -8 - i * 2, 0, 0, 0) end
    V(B, "light", 4, 8.7 + 0.15, -18, 0, 0, 0)
  end }
-- 5. A RADIO MAST ARRAY: the Base Station Tower, three 12 m truss masts with a
-- deep space dish, a relay dish and three whips and a beacon, isotope cells
-- and a junction box on a slab
FB.MAKE[5] = { name = "masts", title = "Radio Mast Array", eye = { { 18, 10, 2 }, { 0, 6, -10 } }, eye2 = { { -14, 3, -22 }, { 0, 8, -10 } },
  build = function(B, BH)
    K(B, BH, "tower", -6, 0, -9, 0)
    for _, m in ipairs({ { 4, -6 }, { 8, -11 }, { 3, -15 } }) do
      K(B, BH, "slab2.concrete", m[1], 0, m[2])
      K(B, BH, "truss6.steel", m[1], 0.2, m[2], 0); K(B, BH, "truss6.steel", m[1], 6.2, m[2], 0); K(B, BH, "trussNode.steel", m[1], 12.2, m[2], 0)
    end
    V(B, "dishL", 4, 12.7 + 0.6, -6, 0, 0, 0)
    V(B, "dish", 8, 12.7 + 0.4, -11, 0, 0, 0)
    for _, o in ipairs({ { 0.15, 0 }, { -0.15, 0 }, { 0, 0.15 } }) do V(B, "antenna", 3 + o[1], 12.7 + 0.5, -15 + o[2], 0, 0, 0) end
    V(B, "beacon", 3, 6.0, -15.35, 0, 0, 0)
    K(B, BH, "slab2.concrete", 0, 0, -11); K(B, BH, "slab2.concrete", 0, 0, -9)
    V(B, "rtg", -0.4, 0.2 + 0.32, -11, 0, 0, 0); V(B, "rtg", 0.4, 0.2 + 0.32, -11, 0, 0, 0)
    K(B, BH, "junctionBox.steel", 0, 0.2, -9.2, 0)
    K(B, BH, "transformer.steel", 0.2, 0.2, -10.0, Q)
  end }

function FB.make_one(k)
  local M = FB.MAKE[k]
  local fb, ST, co, BH, BP = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("base_hub"), findScript("blueprints")
  local spot = FB.spot_free({ 230, 270, 310, 350, 390 })
  if not BK.check(M.name .. "_spot", spot ~= nil, "flat ground for the %s", M.title) then return end
  FB.used[#FB.used + 1] = spot
  FB.setup(spot)
  tap("b"); wait(1.5)
  local sid, uid = FB.place_hub(fb, 6, -3)
  KIT.close(fb)
  if not BK.check(M.name .. "_hub", sid ~= nil, "a Base Hub for the %s", M.title) then return end
  local f0 = co.balance()
  local B, bh = FB.open_hub(sid, uid)
  if not BK.check(M.name .. "_open", B and bh.state == "building", "the full builder on it") then return end
  M.build(B, BH)
  wait(2.0)
  local n = #B.hubParts()
  local bc = findScript("builder_camera")
  if bc and bc.setCamState then
    local e, t = M.eye[1], M.eye[2]
    local dx, dz = e[1] - t[1], e[3] - t[3]
    bc.setCamState({ P = { x = t[1], y = t[2] + 0.11, z = t[3] }, yaw = math.atan2(dx, dz), pitch = -math.atan2(e[2] - t[2], math.sqrt(dx * dx + dz * dz)),
                     d = math.sqrt(dx * dx + dz * dz + (e[2] - t[2]) ^ 2) })
  end
  wait(1.2)
  BK.shot("m" .. k .. "_" .. M.name .. "_builder", true)
  B.doLaunch()
  wait_for(function() return bh.state == "idle" end, 15, "the commit")
  -- (the flora audit takes the plants rooted under the new floors within a few seconds)
  wait(9.0)
  local ex = bh.lastHubExit
  local rec = ST.get(sid)
  BK.check(M.name .. "_built", ex and ex.ok and rec and #rec.bp == n, "%s: %d parts built into the base · %s · %s", M.title, rec and #rec.bp or -1,
    co.money(f0 - co.balance()), tostring(ex and ex.msg))
  KIT.view("m" .. k .. "_" .. M.name .. "_a", rec, M.eye[1], M.eye[2])
  KIT.view("m" .. k .. "_" .. M.name .. "_b", rec, M.eye2[1], M.eye2[2])
  rec = ST.get(sid)
  if rec then rec.n = M.title; ST.put(rec) end
  local ok, why = fb.saveBlueprint(sid, nil, M.title)
  if BP and BP.closePrompt then BP.closePrompt() end
  local lb = fb.lastBlueprint
  BK.check(M.name .. "_bp", ok and lb and lb.n > 0, "saved as the blueprint \"%s\" (%s pieces, %s, code %d chars)", M.title, lb and tostring(lb.n) or "-",
    lb and tostring(lb.path) or tostring(why), lb and lb.code and #lb.code or 0)
  local SL = findScript("struct_live")
  P("FB MAKE %s: %d parts, live vessel %s, $%d", M.name, rec and #rec.bp or -1, tostring(SL and SL.vesselOf(sid) ~= nil), f0 - co.balance())
end

function FB.run_make()
  BK.tag = "fbmake"
  wait_ready(120)
  wait(2)
  FB.engineer()
  local rs, co = findScript("research"), findScript("company")
  for id in pairs(rs.TECH or {}) do pcall(rs.grant, id, "probe") end
  if co and co.earn then co.earn(3000000, "probe") end
  local set = math.floor(params.set or 0)
  local list = (set == 1 and { 1, 2, 3 }) or (set == 2 and { 4, 5 }) or { 1, 2, 3, 4, 5 }
  for _, k in ipairs(list) do FB.make_one(k) end
  BK.result()
end
end
