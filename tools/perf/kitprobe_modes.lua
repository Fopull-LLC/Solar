-- ── kit probe (tools/perf/kitprobe.sh): sandbox plan S1 + S2 ─────────────────
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua and
-- buildkitprobe_modes.lua (the BK helpers: check, shot, flat_spot, menu…).
--   kit      on flat ground 150+ m out from the spaceport: a 4 x 4 m hab built
--            from pieces through the Build Kit's own path (real raycasts at
--            the pieces' faces, field_builder.placeAt: pose → face snap →
--            validity → place): four slabs edge to edge, eight walls (a door
--            wall and two window walls among them), a roof of four floors, a
--            light under it, a switch plate and a screen on the back wall, a
--            cockpit, a seat and a locker inside; a red ghost; a Ctrl+drag
--            run; walked into through the door (it opens, it shuts); the
--            cockpit boarded and left; the locker opened and an item put; the
--            light switched off and on; an Equipment Shed and a Surface Hab
--            placed and walked into (doors, steps, deck); a Build Stand with a
--            craft on it drawn in blueprint blue with its hint; a hidden
--            Collidable still collides (E's question); the idle cost; save and
--            reload (every piece on its record, the vessel once, the locker's
--            contents kept); pictures from outside, two angles, and inside.
--   kitperf  500, 2,000 and 6,000 pieces in view (floors and walls in rooms),
--            and 30 live lockers on the 500: perf.counts nodes / instances /
--            draws / unbatched (by cause), the render bucket and script ms.
-- One `BK PASS|FAIL <check>` line a check, `BK RESULT kit: PASS/FAIL`.
KIT = {}

local function KS() return findScript("kit_snap") end
-- a structure-local point → this frame's world point
function KIT.w(rec, lx, ly, lz)
  local fr = KS().frameOf(rec)
  local b = space.body(rec.b)
  return { x = b.x + fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz,
           y = b.y + fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
           z = b.z + fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz }
end
-- a world point → structure-local
function KIT.l(rec, w)
  local fr = KS().frameOf(rec)
  local b = space.body(rec.b)
  local d = { x = w.x - b.x - fr.O.x, y = w.y - b.y - fr.O.y, z = w.z - b.z - fr.O.z }
  return dot(d, fr.R), dot(d, fr.U), dot(d, fr.F)
end
-- a real ray between two structure-local points (the crew skipped)
function KIT.ray(rec, a, b)
  local p, q = KIT.w(rec, a[1], a[2], a[3]), KIT.w(rec, b[1], b[2], b[3])
  local d = sub(q, p)
  local L = len(d.x, d.y, d.z)
  local h = raycast(p.x, p.y, p.z, d.x / L, d.y / L, d.z / L, L, { ignore = astro() })
  return h
end
-- hold `id` and place it where the ray from a to b lands, the kit's own way
function KIT.put(fb, rec, id, a, b, tag)
  fb.hold(id)
  yield()
  local h = KIT.ray(rec, a, b)
  if not h then P("KIT %s: the ray found nothing", tag or id) return nil, "no hit" end
  local sid, why, q, uid = fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node)
  if not sid then P("KIT %s refused: %s", tag or id, tostring(why)) return nil, why end
  local p = findScript("structures").getPart(sid, uid)
  P("KIT %s: uid %d at (%.2f, %.2f, %.2f) yaw %.0f° pitch %.0f° · %s", tag or id, uid, p.x, p.y, p.z, math.deg(p.yaw or 0), math.deg(p.pitch or 0),
    q and ("$" .. tostring(q.total)) or "")
  return uid, p
end
-- walk the crew to a structure-local (x, z), steering as a player would
function KIT.walk(rec, lx, lz, secs, stop, watch)
  local pw, cam = findScript("planet_walker"), findScript("planet_camera")
  local t0 = time
  local reached = false
  while time - t0 < (secs or 10) do
    local a = astro()
    local up = unit(sub(a, home()))
    local tgt = KIT.w(rec, lx, 0, lz)
    local D = sub(tgt, a)
    D = sub(D, scl(up, dot(D, up)))
    if len(D.x, D.y, D.z) < (stop or 0.5) then reached = true break end
    D = unit(D)
    local f = { x = cam.fwd_x or 0, y = cam.fwd_y or 0, z = cam.fwd_z or 1 }
    f = sub(f, scl(up, dot(f, up)))
    if len(f.x, f.y, f.z) < 1e-6 then f = D else f = unit(f) end
    local r = cross(f, up)
    pw.steer(dot(D, f), dot(D, r), false)
    if watch then watch() end
    yield()
  end
  pw.steer(nil)
  wait(0.4)
  return reached
end
-- put the crew on their feet at a structure-local (x, z) (the ground under it)
function KIT.tp(rec, lx, lz, ly)
  -- (11-09: from 4 m up the ray met a hab's ROOF first and the crew stood on
  -- it — the S8 probe's "on the roof after a reload". It starts 1.2 m over
  -- the floor asked for, under any ceiling, and only then from above.)
  local a = astro()
  local top = KIT.w(rec, lx, (ly or 0) + 1.2, lz)
  local up = unit(sub(top, home()))
  local h = raycast(top.x, top.y, top.z, -up.x, -up.y, -up.z, 12, { ignore = a })
  if not h then
    top = KIT.w(rec, lx, 4, lz)
    h = raycast(top.x, top.y, top.z, -up.x, -up.y, -up.z, 12, { ignore = a })
  end
  local g = h or KIT.w(rec, lx, 0, lz)
  a.x, a.y, a.z = g.x + up.x * 1.0, g.y + up.y * 1.0, g.z + up.z * 1.0
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(1.5)
end
-- where the crew stands in the structure's frame (their feet, about)
function KIT.at(rec)
  local x, y, z = KIT.l(rec, astro())
  return x, y, z
end
-- a fixed picture: eye and target structure-local
function KIT.view(nm, rec, eye, tgt, ui)
  local b = home()
  local e, t = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(e, b), sub(t, b))
  wait(1.2)
  BK.shot(nm, ui == true)
  VP.cam_off()
  wait(0.3)
end
function KIT.cost(tag, secs)
  local fr0 = FRAME
  wait(secs or 3)
  local c = perf.counts and perf.counts() or {}
  local ub = {}
  for k, v in pairs(c.unbatchedBy or {}) do ub[#ub + 1] = k .. "=" .. tostring(v) end
  P("KIT COST %s: structures %.4f, kit_live %.4f, struct_live %.4f, vessel_controller %.4f, field_builder %.4f, craft_stand %.4f ms/frame · nodes %s instances %s draws %s unbatched %s (%s) lights %s dropped %s (%d frames)",
    tag, perf.scriptMs("structures") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("struct_live") or -1,
    perf.scriptMs("vessel_controller") or -1, perf.scriptMs("field_builder") or -1, perf.scriptMs("craft_stand") or -1,
    tostring(c.nodes), tostring(c.instances), tostring(c.draws), tostring(c.unbatched), table.concat(ub, " "),
    tostring(c.lights), tostring(c.lightsDropped), FRAME - fr0)
end
-- the context menu's entries on a node, asked by the crew member on foot
function KIT.menu(node)
  local reg, cm = findScript("context_registry"), findScript("context_menu")
  if not (reg and cm and node and node.valid ~= false) then return {}, nil end
  local w = node.worldPos
  local tgt = cm.resolve({ node = node, x = w.x, y = w.y, z = w.z })
  P("KIT menu target: %s", tgt and tostring(tgt.kind) or "none")
  local C = findScript("crew")
  local ctx = { actor = { kind = "crew", node = astro(), id = C.activeId(), pack = C.packOf and C.packOf(C.activeId()) or "astro", aboard = false },
                ref = function(k) return findScript(k) end,
                toast = function(m, bad) P("KIT toast %s%s", bad and "(bad) " or "", tostring(m)) end }
  return (tgt and reg.entriesFor(tgt, ctx)) or {}, tgt, ctx
end
-- put the kit away (never Esc: a second one opens the pause menu)
function KIT.close(fb)
  fb.dropHeld()
  fb.close()
  local pm = findScript("pause_menu")
  if pm and pm.open and pm.close then pcall(pm.close) end
  wait(0.3)
  P("KIT kit closed: open %s, paused %s", tostring(fb.isOpen()), tostring(pm and pm.open))
end
local function reload()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(4)
end

function KIT.run()
  BK.tag = "kit"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  local KL, SL = findScript("kit_live"), findScript("struct_live")
  if not BK.check("scene", fb and ST and KL and SL and KS() and findScript("parts_kit"), "the kit's scripts are in the scene") then BK.result() return end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "B opens the kit (gate %s)", tostring(fb.gate))
  local cp = findScript("catalog_panel")
  local list = cp and cp.listFor and cp.listFor(fb, "WALL", "") or {}
  BK.check("cards", #list >= 10, "the WALL tab lists the kit's walls (%d)", #list)
  local funds0 = co.balance()
  -- ── 1. THE HAB FROM PIECES ──────────────────────────────────────────────
  fb.hold("slab2.concrete")
  local g = BK.ground_ahead(7, 0)
  local sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node)
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  for _, s in ipairs({ { 2, 0 }, { 0, 2 }, { 2, 2 } }) do
    fb.hold("slab2.concrete")
    yield()
    local h = KIT.ray(rec, { s[1], 4, s[2] }, { s[1], -4, s[2] })
    local s2, w2 = h and fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node)
    rec = ST.get(sid)
    local last = rec.bp[#rec.bp]
    BK.check("slab_" .. s[1] .. s[2], s2 == sid and math.abs(last.x - s[1]) < 0.01 and math.abs(last.z - s[2]) < 0.01 and math.abs(last.y) < 0.01,
      "a slab edge to edge at (%d, %d): %s", s[1], s[2], tostring(w2 or "joined"))
  end
  wait(1.0)
  local T = 0.2   -- the slabs' top
  local walls = {
    { "doorWall.steel", { 0, 3, 2.7 }, "front door" }, { "windowWall.steel", { 2, 3, 2.7 }, "front window" },
    { "wall.steel", { 0, 3, -0.7 }, "back" }, { "wall.steel", { 2, 3, -0.7 }, "back" },
    { "windowWall.steel", { -0.7, 3, 0 }, "left window" }, { "wall.steel", { -0.7, 3, 2 }, "left" },
    { "wall.steel", { 2.7, 3, 0 }, "right" }, { "wall.steel", { 2.7, 3, 2 }, "right" },
  }
  local uids = {}
  for i, w in ipairs(walls) do
    local a = w[2]
    local uid, p = KIT.put(fb, rec, w[1], a, { a[1], -2, a[3] }, w[3])
    uids[#uids + 1] = uid
    local ok = p and math.abs(p.y - T) < 0.01 and (math.abs(math.abs(p.x - 1) - 2) < 0.01 or math.abs(math.abs(p.z - 1) - 2) < 0.01)
    BK.check("wall" .. i, ok, "the %s wall stands on the slab's edge line (%s)", w[3], p and string.format("%.2f, %.2f, %.2f", p.x, p.y, p.z) or "refused")
  end
  local doorUid = uids[1]
  -- a red ghost: a second wall where the back wall stands
  fb.hold("wall.steel")
  local hb = KIT.ray(rec, { 0, 3, -0.7 }, { 0, -2, -0.7 })
  local pz = hb and fb.pose(hb)
  local rq = pz and fb.validity("wall.steel", pz)
  BK.check("red", rq and rq.bad ~= nil, "a second back wall where one stands: red, \"%s\"", rq and tostring(rq.bad) or "-")
  -- the roof: two floors on the front walls' tops (seen from outside), two beside them
  local r1 = KIT.put(fb, rec, "floor.steel", { 0, 5, 3 }, { 0, 1, 3 }, "roof over the front")
  local r2 = KIT.put(fb, rec, "floor.steel", { 2, 5, 3 }, { 2, 1, 3 }, "roof over the front")
  local r3 = KIT.put(fb, rec, "floor.steel", { 0, 2.5, -4 }, { 0, 2.5, 4 }, "roof over the back")
  local r4 = KIT.put(fb, rec, "floor.steel", { 2, 2.5, -4 }, { 2, 2.5, 4 }, "roof over the back")
  rec = ST.get(sid)
  local roofOK = 0
  for _, u in ipairs({ r1, r2, r3, r4 }) do
    local p = u and ST.getPart(sid, u)
    if p and math.abs(p.y - (T + 2.2)) < 0.01 and p.z > -0.1 and p.z < 2.1 then roofOK = roofOK + 1 end
  end
  BK.check("roof", roofOK == 4, "a roof of four floors on the walls' tops, over the room (%d of 4)", roofOK)
  -- the fittings: a light under the roof, a switch and a screen on the back wall's inner face
  local lightUid = KIT.put(fb, rec, "lightFitting.steel", { 0.5, 1.2, 0.5 }, { 0.5, 4, 0.5 }, "light")
  local lp = lightUid and ST.getPart(sid, lightUid)
  BK.check("light", lp and math.abs(math.abs(lp.pitch) - math.pi) < 1e-3, "a light hangs under the roof, face down")
  local swUid = KIT.put(fb, rec, "switchPlate.steel", { 0.25, 1.4, 1.5 }, { 0.25, 1.4, -2 }, "switch")
  local scUid = KIT.put(fb, rec, "wallScreen.steel", { 1.5, 1.6, 1.5 }, { 1.5, 1.6, -2 }, "screen")
  local scp = scUid and ST.getPart(sid, scUid)
  BK.check("screen", scp and math.abs(scp.pitch - math.pi / 2) < 1e-3 and scp.z > -1.0 and scp.z < -0.8, "the screen on the back wall's inner face, facing in")
  -- inside: a cockpit (on its belly), a seat, a locker
  local ckUid = KIT.put(fb, rec, "vab.cockpit", { 0.5, 2.0, 1.2 }, { 0.5, -1, 1.2 }, "cockpit")
  local seUid = KIT.put(fb, rec, "vab.seat", { 2.2, 2.0, 2.0 }, { 2.2, -1, 2.0 }, "seat")
  local lkUid = KIT.put(fb, rec, "vab.locker", { 2.3, 2.0, -0.4 }, { 2.3, -1, -0.4 }, "locker")
  BK.check("live_placed", ckUid and seUid and lkUid, "a cockpit, a seat and a locker placed inside")
  fb.dropHeld()
  rec = ST.get(sid)
  P("KIT hab: %d pieces, $%d spent", #rec.bp, funds0 - co.balance())
  -- a Ctrl+drag run: three floors laid along the front, outside, one undo
  do
    local n0 = #ST.get(sid).bp
    fb.hold("floor.steel")
    fb.sim = fb.sim or {}
    local pts = { { -0.5, T * 0.5, 4.05 }, { 1.5, T * 0.5, 4.05 }, { 3.5, T * 0.5, 4.05 } }
    -- (a floor beside the front slabs, level: aimed at their front faces)
    fb.sim.ctrl = true
    for i, pt in ipairs(pts) do
      local tx = (i - 1) * 2
      BK.aim_local(ST, sid, tx, 0.1, 3.0)
      BK.settle(20)
      fb.sim.lmb = true
      BK.settle(6)
    end
    fb.sim.lmb = false
    yield(); yield()
    fb.sim.ctrl = false
    local n1 = #ST.get(sid).bp
    local lr = fb.lastRun
    BK.check("run", lr and lr.n >= 2 and n1 - n0 == lr.n, "a Ctrl+drag run along the slabs' front: %d floors, one step (%s)", lr and lr.n or 0, lr and ("$" .. lr.total) or "-")
    local f1 = co.balance()
    local amt = fb.undo()
    BK.check("run_undo", amt and #ST.get(sid).bp == n0, "one Ctrl+Z takes the run back ($%s)", tostring(amt))
    fb.dropHeld()
  end
  wait(2)
  -- pictures: outside, two angles, while the planet moves
  rec = ST.get(sid)
  KIT.view("k1_hab_front", rec, { -4, 3.2, 9 }, { 1, 1.2, 1 })
  KIT.view("k2_hab_corner", rec, { 7, 4.5, -4 }, { 1, 1.2, 1 })
  -- E's question: does a hidden Collidable still collide?
  do
    local wn = ST.nodeOf(sid, uids[3])
    if wn then
      local h0 = KIT.ray(rec, { 0, 1.2, -3 }, { 0, 1.2, 1 })
      local p0 = nil; if h0 then local _r; _r, p0 = ST.partOfNode(h0.node) end
      P("KIT hidden control: the ray hits %s (part %s) before hiding", h0 and h0.node and tostring(h0.node.name) or "nothing", tostring(p0 and p0.uid))
      wn.visible = false
      wait(0.3)
      local h = KIT.ray(rec, { 0, 1.2, -3 }, { 0, 1.2, 1 })
      local p3 = nil; if h then local _r; _r, p3 = ST.partOfNode(h.node) end
      BK.check("hidden_collides", p3 and p3.uid == uids[3], "a hidden wall still stops a ray (hit %s of part %s; the hidden one is %s)",
        h and h.node and tostring(h.node.name) or "nothing", tostring(p3 and p3.uid), tostring(uids[3]))
      wn.visible = true
    end
  end
  -- ── 2. WALK IN THROUGH THE DOOR ─────────────────────────────────────────
  KIT.close(fb); wait(0.5)
  local dmax = 0
  local function watch() local o = KL.doorOpen(sid, doorUid) or 0; dmax = math.max(dmax, o) end
  KIT.walk(rec, -0.46, 4.6, 14, 0.4)
  local shut0 = KL.doorOpen(sid, doorUid) or -1
  local got = KIT.walk(rec, -0.46, 1.8, 10, 0.4, watch)
  KIT.walk(rec, -0.2, 0.6, 6, 0.4, watch)
  local x, y, z = KIT.at(rec)
  BK.check("walk_in", dmax > 0.9 and x > -0.9 and x < 2.9 and z > -0.9 and z < 2.9 and y > T - 0.1 and y < T + 2.0,
    "walked in through the door: it opened (%.2f), the crew inside at (%.2f, %.2f, %.2f) on the floor", dmax, x, y, z)
  do
    local ff = findScript("flora_field")
    P("KIT flora: %s plants cleared from inside structures' floors, %s taken off kit floors by the audit",
      tostring(ff and ff.structClearRemoved), tostring(ff and ff.auditRemoved))
  end
  KIT.view("k3_inside", rec, { -0.6, 1.75, -0.6 }, { 1.5, 1.0, 2.8 })
  -- the screen and the light from inside
  wait(2.5)
  local st = KL.screenText(sid, scUid)
  BK.check("screen_text", st and st:find("GRID", 1, true), "the screen shows the base: %s", tostring(st))
  KIT.view("k4_inside_back", rec, { 1.8, 1.7, 2.6 }, { 1.0, 1.3, -1.0 })
  -- ── 3. BOARD THE COCKPIT ────────────────────────────────────────────────
  local vc = SL.controllerOf(sid)
  BK.check("vessel", vc ~= nil and vc.structureMode == true and vc.structureSid == sid and vc.standHeld == true,
    "the live parts are one structure vessel (structure mode %s)", tostring(vc and vc.structureMode))
  local boarded = false
  if vc then
    KIT.walk(rec, -0.3, 1.2, 6, 0.3)
    for _ = 1, 60 do
      boarded = vc.boardNow and vc.boardNow()
      if boarded then break end
      yield()
    end
  end
  wait(1.5)
  BK.check("board", boarded and vc.piloting, "F boards the placed cockpit (piloting %s, seat %s)", tostring(vc and vc.piloting), tostring(vc and vc.stationUid))
  if boarded then
    BK.shot("k5_seated", true)
    local rel = vc.releaseClamps and vc.releaseClamps()
    local i = assembly.info(vc.node)
    BK.check("no_release", rel == false and i and i.anchored, "SPACE in a base cockpit releases nothing: it stays anchored")
    if vc.evaNow then vc.evaNow() end
    wait(2.5)
    local pw = findScript("planet_walker")
    BK.check("eva", pw.onFoot == true, "and the crew climbs out again")
  end
  -- ── 4. THE LOCKER ───────────────────────────────────────────────────────
  local Ls = SL.vessels()[sid]
  local lockerNode
  for _, e in ipairs(Ls and Ls.placed or {}) do if e.d.uid == lkUid then lockerNode = e.part end end
  local inv = findScript("inventory")
  local cid0
  if lockerNode then
    KIT.walk(rec, 1.6, -0.2, 6, 0.3)
    local ents = KIT.menu(lockerNode)
    local ids = {}
    for _, e in ipairs(ents) do ids[#ids + 1] = tostring(e.id) .. (e.sub and "+" or "") end
    P("KIT locker menu: %s", table.concat(ids, " "))
    local meter = BK.entry(ents, "locker")
    local put
    for _, e in ipairs(ents) do if tostring(e.id):lower():find("put", 1, true) and e.sub then put = e end end
    local moved = false
    if put then
      local sub_ = put.sub()
      for _, s in ipairs(sub_ or {}) do
        if s.act and not moved and not tostring(s.id):find("buildkit", 1, true) then
          local ok, w = s.act(); moved = ok == true
          P("KIT locker put %s: %s %s", tostring(s.id), tostring(ok), tostring(w))
        end
      end
    end
    cid0 = vc and vc.lockerOf and vc.lockerOf(lkUid)
    BK.check("locker", meter ~= nil and moved and cid0 and #inv.itemList(cid0) > 0,
      "the locker's menu opens it (%s): an item Put (%d in it)", tostring(cid0), cid0 and #inv.itemList(cid0) or -1)
  else BK.check("locker", false, "no locker node") end
  -- ── 5. THE LIGHT ────────────────────────────────────────────────────────
  local ln = lightUid and ST.nodeOf(sid, lightUid)
  if ln then
    local ents = BK.menu(ln)
    local tg = BK.entry(ents, "kl_light")
    local k = tostring(sid) .. ":" .. tostring(lightUid)
    local wasLit = KL.lit()[k] == true
    if tg then tg.act(false) end
    wait(1.2)
    local off = KL.lit()[k] == nil
    KIT.view("k6_light_off", rec, { 1.8, 1.7, 2.6 }, { 0.5, 1.0, 0.0 })
    if tg then tg.act(true) end
    wait(1.2)
    BK.check("light_switch", tg and wasLit and off and KL.lit()[k] == true, "the light's menu switches it off and on (lit %s → off %s → %s)",
      tostring(wasLit), tostring(off), tostring(KL.lit()[k]))
  else BK.check("light_switch", false, "no light node") end
  KIT.cost("hab, crew inside", 3)
  -- out again
  KIT.walk(rec, -0.46, 1.8, 6, 0.4)
  KIT.walk(rec, -0.46, 7.0, 10, 0.5)
  wait(2.5)
  BK.check("door_shut", (KL.doorOpen(sid, doorUid) or 1) < 0.05, "the door shut behind the crew")
  -- ── 6. THE SHED AND THE HAB PREFABS ────────────────────────────────────
  tap("b"); wait(1.0)
  for _, pre in ipairs({ { "shed", 6, 11, "Equipment Shed" }, { "hab", 8, -13, "Surface Hab" } }) do
    fb.hold(pre[1])
    yield()
    local gh = BK.ground_ahead(pre[2], pre[3])
    local ps, pwhy = nil, "no ground"
    if gh then ps, pwhy = fb.placeAt(gh.x, gh.y, gh.z, gh.nx, gh.ny, gh.nz, gh.node) end
    P("KIT %s: %s", pre[1], tostring(ps or pwhy))
    BK.check("place_" .. pre[1], ps ~= nil, "a %s placed beside the hab", pre[4])
    pre.sid = ps
  end
  fb.dropHeld()
  KIT.close(fb); wait(2.0)
  do
    local shed = nil
    for _, r in ipairs(ST.list()) do if r.bp[1].id == "shed" then shed = r end end
    if shed then
      local omax = 0
      local key = shed.id
      local function w2() omax = math.max(omax, KL.doorOpen(key, 1) or 0) end
      KIT.tp(shed, 0, 3.4); KIT.walk(shed, 0, 2.6, 8, 0.4)
      KIT.walk(shed, 0, 0.2, 8, 0.35, w2)
      local sx, sy, sz = KIT.at(shed)
      BK.check("shed_in", omax > 0.9 and math.abs(sx) < 1.4 and sz > -1.1 and sz < 1.1 and sy > 0.0,
        "into the Equipment Shed: its door slid open (%.2f), the crew inside (%.2f, %.2f, %.2f)", omax, sx, sy, sz)
      KIT.view("k7_shed_inside", shed, { 0.9, 1.6, 1.0 }, { -0.6, 1.0, -0.8 })
      KIT.view("k8_shed_door", shed, { 2.5, 1.8, 4.0 }, { 0, 1.0, 1.2 })
      KIT.walk(shed, 0, 3.5, 8, 0.5)
    else BK.check("shed_in", false, "no shed") end
    local hab = nil
    for _, r in ipairs(ST.list()) do if r.bp[1].id == "hab" then hab = r end end
    if hab then
      local omax = 0
      local function w3() omax = math.max(omax, KL.doorOpen(hab.id, 1) or 0) end
      KIT.tp(hab, 0, 5.4); P("KIT hab leg0 at %.2f %.2f %.2f", KIT.at(hab)); KIT.walk(hab, 0, 4.4, 6, 0.3, w3); P("KIT hab leg1 (the foot of the steps) at %.2f %.2f %.2f", KIT.at(hab))
      KIT.walk(hab, 0, 3.4, 6, 0.3, w3); P("KIT hab leg2 (on the steps) at %.2f %.2f %.2f", KIT.at(hab)); KIT.walk(hab, 0, 2.5, 6, 0.3, w3); P("KIT hab leg3 (the landing) at %.2f %.2f %.2f", KIT.at(hab))
      KIT.walk(hab, 0.0, 1.2, 6, 0.35, w3); P("KIT hab leg4 (the collar) at %.2f %.2f %.2f", KIT.at(hab))
      KIT.walk(hab, 0.4, 0.0, 6, 0.35, w3)
      local hx, hy, hz = KIT.at(hab)
      BK.check("hab_in", omax > 0.9 and math.abs(hx) < 2.8 and math.abs(hz) < 1.5 and hy > 1.6,
        "up the Surface Hab's steps and in: its hatch slid open (%.2f), the crew on its deck (%.2f, %.2f, %.2f)", omax, hx, hy, hz)
      KIT.view("k9_hab_inside", hab, { 2.7, 2.5, 0.2 }, { -1.5, 1.7, 0.3 })
      KIT.view("k10_hab_outside", hab, { -3.2, 2.6, 7.2 }, { 0, 1.6, 2.2 })
      KIT.walk(hab, 0.0, 1.6, 6, 0.4)
      KIT.walk(hab, 0, 2.5, 6, 0.4)
      KIT.walk(hab, 0, 4.4, 8, 0.4)
      KIT.walk(hab, 0, 6.5, 8, 0.5)
    else BK.check("hab_in", false, "no hab") end
  end
  -- ── 7. THE STAND'S BLUE DISPLAY COPY ───────────────────────────────────
  do
    tap("b"); wait(1.0)
    fb.hold("stand")
    yield()
    stand_at(spot)
    wait(2.0)
    local ssid, swhy = nil, "no ground"
    for _, c in ipairs({ { 5, -6 }, { 4, 6 }, { 3, -3 }, { 6, 4 }, { 8, -8 }, { 2, 5 } }) do
      local gs = BK.ground_ahead(c[1], c[2])
      local onTerrain = gs and (not gs.node or gs.node.name == home().name or (pcall(function() return gs.node.terrain end) and gs.node.terrain))
      swhy = nil
      -- (diagnosis: what the aim ray hit, and what a terrain ray from 3.5 m
      -- above that point finds — the stand's own ground sampling)
      local diag = "no hit"
      if gs then
        local U = unit(sub(gs, home()))
        local o = { x = gs.x + U.x * 3.5, y = gs.y + U.y * 3.5, z = gs.z + U.z * 3.5 }
        local th = terrain and terrain.raycast and terrain.raycast(vec3(o.x, o.y, o.z), vec3(-U.x, -U.y, -U.z), 8)
        diag = string.format("hit %s (n·up %.2f), terrain ray from 3.5 m: %s", tostring(gs.node and gs.node.name),
          gs.nx and (gs.nx * U.x + gs.ny * U.y + gs.nz * U.z) or -9, th and string.format("%.2f m", th.distance or -1) or "MISS")
      end
      if onTerrain then fb.hold("stand"); yield(); ssid, swhy = fb.placeAt(gs.x, gs.y, gs.z, gs.nx, gs.ny, gs.nz, gs.node) end
      if onTerrain and not ssid and fb.sampleGround then
        -- (what the footprint sampling saw: the snapped pose against the aim point, the nine heights)
        local p = fb.pose({ x = gs.x, y = gs.y, z = gs.z, nx = gs.nx, ny = gs.ny, nz = gs.nz, node = gs.node }, "stand")
        local b = home()
        local hs = p and fb.sampleGround(fb.partInfo("stand"), p) or {}
        local t = {}
        for _, h in ipairs(hs) do t[#t + 1] = h and string.format("%.2f", h) or "x" end
        P("KIT stand diag: mode %s, pose %.2f m from the aim point, up·radial %.3f, heights [%s], last miss %s", tostring(p and p.mode),
          p and len(b.x + p.x - gs.x, b.y + p.y - gs.y, b.z + p.z - gs.z) or -1,
          p and dot(p.up, unit(sub(gs, b))) or -9, table.concat(t, " "), tostring(fb.lastRayWhy))
      end
      P("KIT stand try (%d, %d): %s · %s", c[1], c[2], tostring(ssid or swhy or "not the ground"), diag)
      if ssid then break end end
    P("KIT stand: %s (the last terrain-ray miss: %s)", tostring(ssid or swhy), tostring(fb.lastRayWhy))
    fb.dropHeld()
    KIT.close(fb); wait(1.0)
    local CS = findScript("craft_stand")
    if ssid and CS then
      local fake = { id = -1, bp = { { uid = 1, id = "vab.pod", x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 } }, n = "Probe Pod" }
      local bpc = SL.blueprintOf(fake, function(i) return findScript("parts_base").partInfo(i) end, nil, findScript("electronics"))
      for _, d in ipairs(bpc.parts) do d.y = d.h / 2 end
      bpc.name = "Pod on a stand"
      local ok, w = CS.putOn(ssid, 1, bpc, { name = "Pod on a stand" })
      wait(2.0)
      local a = astro()
      local top = BK.stand_top(ST, CS, ssid)
      if top then a.x, a.y, a.z = top.x + BK.F.x * 1.5, top.y + BK.F.y * 1.5, top.z + BK.F.z * 1.5 end
      wait(1.0)
      local h = CS.displayHint and CS.displayHint()
      local ents = BK.menu(ST.nodeOf(ssid, 1))
      local row = BK.entry(ents, "cs_notyet")
      BK.check("stand_blue", ok and h and h:find("not commissioned", 1, true) and row ~= nil,
        "an uncommissioned craft on a stand: its hint \"%s\", its menu row %s", tostring(h or w), tostring(row and row.value))
      local srec = ST.get(ssid)
      KIT.view("k11_stand_blue", srec, { 2.5, 2.2, 3.5 }, { 0, 1.3, 0 })
    else BK.check("stand_blue", false, "no stand") end
  end
  KIT.cost("idle, the hab, the shed, the hab prefab, a stand", 3)
  -- and with the crew 30 m off (the structure vessel asleep: DORM_STRUCT 12 m)
  KIT.tp(rec, 1, 30)
  KIT.cost("idle, the crew 30 m from the hab", 4)
  -- ── 8. SAVE AND RELOAD ─────────────────────────────────────────────────
  local n0 = #ST.get(sid).bp
  local items0 = cid0 and #inv.itemList(cid0) or 0
  local b0 = home()
  local bp0 = { x = b0.x, y = b0.y, z = b0.z }
  reload()
  ST, KL, SL = findScript("structures"), findScript("kit_live"), findScript("struct_live")
  inv = findScript("inventory")
  wait(3)
  rec = ST.get(sid)
  local worst, missing = 0, 0
  for _, p in ipairs(rec and rec.bp or {}) do
    local d = findScript("parts_base").partInfo(p.id)
    if d and not d.live then
      local n = ST.nodeOf(sid, p.uid)
      if not n then missing = missing + 1
      else
        local x, y, z = ST.partPose(rec, p, d.seat)
        local b = space.body(rec.b)
        local w = n.worldPos
        worst = math.max(worst, len(w.x - b.x - x, w.y - b.y - y, w.z - b.z - z))
      end
    end
  end
  local b1 = home()
  local nv = 0
  for _ in pairs(SL.vessels()) do nv = nv + 1 end
  local vc2 = SL.controllerOf(sid)
  local cid2 = vc2 and vc2.lockerOf and vc2.lockerOf(lkUid)
  BK.check("reload", rec and #rec.bp == n0 and missing == 0 and worst < 0.01,
    "after a reload all %d pieces stand on their records (worst %.4f m, %d missing); the planet moved %.0f m", rec and #rec.bp or 0, worst, missing,
    len(b1.x - bp0.x, b1.y - bp0.y, b1.z - bp0.z))
  BK.check("reload_live", nv >= 1 and vc2 and vc2.structureMode and cid2 == cid0 and #inv.itemList(cid2) == items0,
    "the structure vessel made again (%d), the locker the same (%s) with its %d item(s)", nv, tostring(cid2), cid2 and #inv.itemList(cid2) or -1)
  KIT.view("k12_after_reload", rec, { -4, 3.2, 9 }, { 1, 1.2, 1 })
  KIT.cost("after the reload", 3)
  BK.result()
end

-- ── kitperf: pieces in view ──────────────────────────────────────────────────
function KIT.block(ST, spot, k, live)
  local b = home()
  local U = spot.dir
  local Rt = unit(cross(spot.t, U))
  local o = { x = U.x * spot.r, y = U.y * spot.r, z = U.z * spot.r }
  local o2 = { x = o.x + spot.t.x * 25, y = o.y + spot.t.y * 25, z = o.z + spot.t.z * 25 }
  local rec = ST.newRecord(nil, b.name, o2.x, o2.y, o2.z, U, spot.t, "floor.steel", { name = "perf block" })
  rec.bp = {}
  local uid = 0
  local function add(id, x, y, z, yaw, pitch)
    uid = uid + 1
    rec.bp[#rec.bp + 1] = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0, parent = 0, att = "", sym = 0, mir = "", stage = 0 }
  end
  for i = 0, k - 1 do
    for j = 0, k - 1 do
      local x, z = (i - k / 2) * 2, j * 2
      add(((i + j) % 5 == 0) and "floor.concrete" or "floor.steel", x, 0, z)
      add(((i * 7 + j) % 4 == 0) and "windowWall.steel" or "wall.steel", x, 0.2, z + 1, 0)
      add(((i + j * 3) % 6 == 0) and "doorWall.steel" or "wall.concrete", x + 1, 0.2, z, math.pi / 2)
    end
  end
  for n = 1, (live or 0) do add("vab.locker", ((n % 6) - 3) * 2, 0.2, (math.floor(n / 6)) * 2 + 0.4) end
  return rec
end
function KIT.run_perf()
  BK.tag = "kitperf"
  wait_ready(120)
  wait(2)
  local ST = findScript("structures")
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
  stand_at(spot)
  wait(4)
  spawnBudget(4)
  -- the same views with no block: what the scene costs by itself
  for _, k in ipairs({ 13, 45 }) do
    local U = spot.dir
    VP.cam_fixed({ x = U.x * (spot.r + 14) - spot.t.x * 8, y = U.y * (spot.r + 14) - spot.t.y * 8, z = U.z * (spot.r + 14) - spot.t.z * 8 },
                 { x = U.x * spot.r + spot.t.x * (25 + k), y = U.y * spot.r + spot.t.y * (25 + k), z = U.z * spot.r + spot.t.z * (25 + k) })
    wait(3)
    local nm = "kit_none_" .. k
    sc_begin(nm); wait(5); sc_end(nm)
    local c = perf.counts()
    P("KIT PERF %s: no block · nodes %d instances %d draws %d unbatched %d", nm, c.nodes or -1, c.instances or -1, c.draws or -1, c.unbatched or -1)
    VP.cam_off()
  end
  for _, case in ipairs({ { 13, 0, "kit_500" }, { 13, 30, "kit_500_live30" }, { 26, 0, "kit_2000" }, { 45, 0, "kit_6000" } }) do
    local rec = KIT.block(ST, spot, case[1], case[2])
    local t0 = W()
    local id = ST.add(rec)
    ST.spawnNow(id)
    wait_for(function() return spawnPending() == 0 and #(ST.nodesOf(id) or {}) >= #rec.bp - case[2] - 2 end, 240, "the block's pieces")
    local tsp = W() - t0
    wait(3)
    -- a camera over the crew's shoulder, the whole block ahead of it
    local b = home()
    local U = spot.dir
    local eye = { x = U.x * (spot.r + 14) - spot.t.x * 8, y = U.y * (spot.r + 14) - spot.t.y * 8, z = U.z * (spot.r + 14) - spot.t.z * 8 }
    local tgt = { x = U.x * spot.r + spot.t.x * (25 + case[1]), y = U.y * spot.r + spot.t.y * (25 + case[1]), z = U.z * spot.r + spot.t.z * (25 + case[1]) }
    VP.cam_fixed(eye, tgt)
    wait(2)
    sc_begin(case[3])
    wait(5)
    sc_end(case[3])
    local c = perf.counts()
    local ub = {}
    for k2, v in pairs(c.unbatchedBy or {}) do ub[#ub + 1] = k2 .. "=" .. tostring(v) end
    P("KIT PERF %s: %d pieces (+%d live), spawned in %.1f s · nodes %d instances %d draws %d unbatched %d (%s) · structures %.4f, kit_live %.4f, struct_live %.4f, vessel_controller %.4f ms/frame",
      case[3], #rec.bp - case[2], case[2], tsp, c.nodes or -1, c.instances or -1, c.draws or -1, c.unbatched or -1, table.concat(ub, " "),
      perf.scriptMs("structures") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("struct_live") or -1, perf.scriptMs("vessel_controller") or -1)
    BK.shot(case[3], false)
    VP.cam_off()
    ST.remove(id)
    wait(3)
  end
  spawnBudget(nil)
  BK.result()
end

-- kitview (builderperf): one block (params.kk, default 26 = 2,028 pieces) in
-- kitperf's view, held until the run ends: for `floptle shot --after N --timing`
-- (the GPU per-pass split at two render sizes) and for still pictures.
function KIT.run_view()
  BK.tag = "kitview"
  wait_ready(120)
  wait(2)
  local ST = findScript("structures")
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
  stand_at(spot)
  wait(3)
  local k = math.floor(params.kk or 26)
  local rec = KIT.block(ST, spot, k, 0)
  local id = ST.add(rec)
  ST.spawnNow(id)
  wait_for(function() return spawnPending() == 0 and #(ST.nodesOf(id) or {}) >= #rec.bp - 2 end, 240, "the block's pieces")
  local U = spot.dir
  VP.cam_fixed({ x = U.x * (spot.r + 14) - spot.t.x * 8, y = U.y * (spot.r + 14) - spot.t.y * 8, z = U.z * (spot.r + 14) - spot.t.z * 8 },
               { x = U.x * spot.r + spot.t.x * (25 + k), y = U.y * spot.r + spot.t.y * (25 + k), z = U.z * spot.r + spot.t.z * (25 + k) })
  wait(2)
  local c = perf.counts()
  P("KIT VIEW %d pieces · nodes %d instances %d draws %d sunMapDraws %d triangles %d lights %d", #rec.bp, c.nodes or -1, c.instances or -1,
    c.draws or -1, c.sunMapDraws or -1, c.triangles or -1, c.lights or -1)
  if (params.kshot or 0) > 0 then BK.shot("kitview_" .. k, false) end
  -- the GPU's own per-pass time (perf.gpu), mean of 90 frames, at the render
  -- scale the project has and at half of it: what scales with pixels
  local function gpu_mean(nm)
    local acc, n = {}, 0
    for _ = 1, 90 do
      yield()
      local g = perf.gpu and perf.gpu()
      if g and g.total then
        n = n + 1
        acc.total = (acc.total or 0) + g.total
        for _, p in ipairs(g.passes or {}) do acc[p.name] = (acc[p.name] or 0) + p.ms end
      end
    end
    local parts = {}
    for key, v in pairs(acc) do if key ~= "total" and v / math.max(n, 1) >= 0.15 then parts[#parts + 1] = string.format("%s %.2f", key, v / n) end end
    table.sort(parts)
    local c2 = perf.counts()
    P("KIT GPU %s (scale %.2f, %d frames): total %.2f ms · %s · sunMapDraws %d instances %d", nm, app.renderScale and app.renderScale() or -1, n,
      (acc.total or 0) / math.max(n, 1), table.concat(parts, ", "), c2.sunMapDraws or -1, c2.instances or -1)
  end
  if perf.gpu and app.setRenderScale then
    local s0 = app.renderScale()
    app.setRenderScale(1.0); wait(1.0); gpu_mean("full")
    app.setRenderScale(0.5); wait(1.0); gpu_mean("half")
    app.setRenderScale(s0)
    local KL = findScript("kit_live")
    if KL and KL.setWallCull then
      local n, hid = KL.wallStats()
      P("KIT GPU walls %d, inside hidden %d", n, hid)
      KL.setWallCull(false); app.setRenderScale(1.0); wait(1.0); gpu_mean("full_nocull")
      KL.setWallCull(true); app.setRenderScale(s0)
    end
  end
  BK.result()
  while true do wait(1) end
end

-- tbprof (builderperf): what tool_belt, fp_body, item_hand and planet_walker cost
-- standing idle, by the script sampler's lines: third person empty-handed, first
-- person empty-handed, first person with the Terrain Laser held (gritdig's idle).
function KIT.prof_phase(nm, secs)
  perf.samples()
  sc_begin(nm); wait(secs); sc_end(nm)
  local per = {}
  for _, s in ipairs(perf.samples() or {}) do
    local k = s.script
    if k == "tool_belt" or k == "fp_body" or k == "item_hand" or k == "planet_walker" or k == "planet_camera" then
      per[k] = per[k] or { sum = 0 }
      per[k].sum = per[k].sum + (s.ms or 0)
      if #per[k] < (k == "tool_belt" and 24 or 8) then per[k][#per[k] + 1] = string.format("%s:%d %.1f", tostring(s.fn), s.line or -1, s.ms or 0) end
    end
  end
  P("TBPROF %s: tool_belt %.3f fp_body %.3f item_hand %.3f planet_walker %.3f planet_camera %.3f ms/frame", nm,
    perf.scriptMs("tool_belt") or -1, perf.scriptMs("fp_body") or -1, perf.scriptMs("item_hand") or -1,
    perf.scriptMs("planet_walker") or -1, perf.scriptMs("planet_camera") or -1)
  for k, l in pairs(per) do P("TBPROF %s %s lines (sampled %.1f ms in all): %s", nm, k, l.sum, table.concat(l, " | ")) end
  -- the engine calls each script made (perf.frames' calls), summed over the last 120 frames
  local calls = {}
  for _, f in ipairs(perf.frames(120) or {}) do
    for _, c in ipairs(f.calls or {}) do
      if c.script == "tool_belt" or c.script == "item_hand" then
        local key = c.script .. "." .. tostring(c.call)
        calls[key] = (calls[key] or 0) + (c.ms or 0) / 120
      end
    end
  end
  local cl = {}
  for key, v in pairs(calls) do cl[#cl + 1] = { key, v } end
  table.sort(cl, function(a, b) return a[2] > b[2] end)
  local out = {}
  for i = 1, math.min(12, #cl) do out[#out + 1] = string.format("%s %.3f", cl[i][1], cl[i][2]) end
  P("TBPROF %s engine calls ms/frame: %s", nm, table.concat(out, " | "))
end
function KIT.run_tbprof()
  BK.tag = "tbprof"
  wait_ready(120)
  wait(2)
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
  stand_at(spot)
  wait(5)
  if perf.sampleScripts then perf.sampleScripts(true) end
  local pc = findScript("planet_camera")
  KIT.prof_phase("tp_empty", 6)
  pc.firstPerson = true
  wait(1)
  KIT.prof_phase("fp_empty", 6)
  local inv, tb = findScript("inventory"), findScript("tool_belt")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  pcall(tb.hold, "laser")
  wait(1.5)
  P("TBPROF tool %s", tostring(tb.toolId and tb.toolId()))
  KIT.prof_phase("fp_laser", 6)
  pc.firstPerson = false
  wait(1)
  KIT.prof_phase("tp_laser", 6)
  if perf.sampleScripts then perf.sampleScripts(false) end
  KIT.prof_phase("tp_laser_nosample", 6)
  BK.result()
end

-- ── rooms (sandbox S3): a sealed hab with an airlock, its air, a leak ────────
-- On flat ground 150+ m out: three slabs edge to edge, an airlock chamber
-- (an Airlock Wall out, a Door Wall in) and a 4 x 2 m hab beyond it (a
-- window, a Door Wall at its far end to the outside), a roof; an Air Tank
-- Rack, a CO2 Scrubber, an Isotope Cell (live: it powers the scrubber on the
-- base grid), a seat, a light and a wall screen inside. The outside is made
-- vacuum for the run (room_air.setVacuum: the home world breathes, the moons
-- don't). Then: the rooms solved (two sealed, the chamber an airlock); the
-- tank pressurises the hab; the ROOMS overlay from outside, two angles; the
-- crew walks in through the airlock (outer door, cycle, inner door: never both
-- open); in the hab they breathe its air (no suit air drawn), take the helmet
-- off; the seat tick's cost by the seat; the far door opened: the hab vents,
-- DEPRESSURISATION, the helmet goes back on; the door shut, the tank brings it
-- back; save and reload: the rooms and their air from the save.
-- a picture with the world's draw.line shapes and the screen text in it (the overlay)
function KIT.oview(nm, rec, eye, tgt)
  local b = home()
  local e, t = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(e, b), sub(t, b))
  wait(1.2)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time)
    else P("BK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("BK capture error %s", tostring(err)) end
  wait_for(function() return done end, 5, "shot " .. nm)
  VP.cam_off()
  wait(0.3)
end
function KIT.run_rooms()
  BK.tag = "rooms"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  local KL, RA, SL = findScript("kit_live"), findScript("room_air"), findScript("struct_live")
  if not BK.check("scene", fb and ST and KL and RA and findScript("rooms"), "the rooms scripts are in the scene") then BK.result() return end
  RA.setVacuum(true)
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "B opens the kit")
  -- ── build ──
  -- (a plant or a rock under the ray: the next spot)
  local sid, why
  for _, o in ipairs({ { 8, -2 }, { 7, 0 }, { 9, 2 }, { 6, -4 }, { 10, 0 }, { 8, 3 }, { 11, -3 } }) do
    fb.hold("slab2.concrete")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    P("KIT ROOMS first slab at (%d, %d): %s", o[1], o[2], tostring(sid or why))
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  for _, x in ipairs({ 2, 4 }) do
    fb.hold("slab2.concrete")
    yield()
    local h = KIT.ray(rec, { x, 4, 0 }, { x, -4, 0 })
    local s2 = h and fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node)
    rec = ST.get(sid)
    local last = rec.bp[#rec.bp]
    BK.check("slab_" .. x, s2 == sid and math.abs(last.x - x) < 0.01 and math.abs(last.z) < 0.01, "a slab edge to edge at x %d", x)
  end
  fb.dropHeld()
  local T = 0.2
  local function put(id, x, y, z, yaw, pitch)
    local p = { body = rec.b, mode = "face", sid = sid, lx = x, ly = y, lz = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }
    local s2, w2, q, uid = fb.place(sid, id, p, "money")
    if not s2 then P("KIT ROOMS %s refused: %s", id, tostring(w2)) end
    return uid
  end
  local H = math.pi / 2
  local U = {}
  U.outer = put("airlockWall.steel", -1, T, 0, H)
  U.inner = put("doorWall.steel", 1, T, 0, H)
  put("wall.steel", 0, T, -1, 0); put("wall.steel", 0, T, 1, 0)
  put("wall.steel", 2, T, -1, 0); put("wall.steel", 4, T, -1, 0)
  put("windowWall.steel", 2, T, 1, 0); put("wall.steel", 4, T, 1, 0)
  U.far = put("doorWall.steel", 5, T, 0, H)
  for _, x in ipairs({ 0, 2, 4 }) do put("floor.steel", x, T + 2.2, 0) end
  -- (along the back wall, and the cell by the window: the walk from the
  -- inner door to the far one along z 0.46 stays clear)
  U.scrub = put("scrubber.steel", 1.6, T, -0.62, 0)
  U.rtg = put("vab.rtg", 2.4, T, -0.55, 0)
  U.seat = put("vab.seat", 3.25, T, -0.5, 0)
  U.tank = put("airTank.steel", 4.35, T, -0.62, 0)
  U.light = put("lightFitting.steel", 3.0, T + 2.2 - 0.001, 0, 0, math.pi)
  U.screen = put("wallScreen.steel", 3.0, 1.6, -0.9, 0, H)
  rec = ST.get(sid)
  P("KIT ROOMS built: %d pieces · outer %s inner %s far %s tank %s scrubber %s", #rec.bp, tostring(U.outer), tostring(U.inner), tostring(U.far), tostring(U.tank), tostring(U.scrub))
  KIT.close(fb)
  wait(2.0)
  -- ── the rooms ──
  local st = RA.state(sid)
  local R = st and st.R
  local RL = findScript("rooms")
  local ch = R and RL.roomAt(R, 0, 1.2, 0)
  local hab = R and RL.roomAt(R, 3, 1.2, 0)
  local nsealed = 0
  for _, r in ipairs(R and R.rooms or {}) do if r.sealed then nsealed = nsealed + 1 end end
  BK.check("rooms", R and #R.rooms == 2 and nsealed == 2 and ch and ch.airlock and hab and not hab.airlock,
    "two sealed rooms: the chamber an airlock (%.1f m³), the hab (%.1f m³); solved in %.2f ms (%d cells)", ch and ch.m3 or -1, hab and hab.m3 or -1,
    RA.PROF.solve_ms or -1, RA.PROF.cells or -1)
  -- ── pressurise: the tank's regulator ──
  local t0 = time
  wait_for(function() local a = hab and RA.airOf(sid, hab.id); return a and a.p > 0.97 end, 90, "the hab pressurised")
  local ah = hab and RA.airOf(sid, hab.id)
  BK.check("pressurised", ah and ah.p > 0.97 and ah.breathable, "the Air Tank Rack pressurised the hab in %.0f s: %.2f atm, O2 %.0f %%, tank %.1f of 60 m³",
    time - t0, ah and ah.p or -1, ah and 100 * ah.o2 / math.max(ah.p, 1e-6) or -1, st and st.tanks[U.tank] or -1)
  P("KIT ROOMS power: scrubber on the grid %s (struct %s grid up %s)", tostring(st and st.pow), tostring(sid), tostring(SL.grid_up and SL.grid_up(sid)))
  -- ── the overlay from outside ──
  RA.overlay, RA.overlayAlways = true, true
  KIT.oview("r1_rooms_overlay_front", rec, { -2.5, 4.5, 8.5 }, { 2, 1.0, 0 })
  KIT.oview("r2_rooms_overlay_corner", rec, { 8.5, 5.5, -5.5 }, { 2, 1.0, 0 })
  -- ── in through the airlock ──
  local both, maxo = false, { o = 0, i = 0 }
  local function watch()
    local o, i = KL.doorOpen(sid, U.outer) or 0, KL.doorOpen(sid, U.inner) or 0
    if o > 0.02 and i > 0.02 then both = true end
    maxo.o, maxo.i = math.max(maxo.o, o), math.max(maxo.i, i)
  end
  KIT.tp(rec, -4, 0)
  -- (the doorways of these walls, turned a quarter, are at z 0 .. 0.92)
  local DZ = 0.46
  KIT.walk(rec, -2.0, DZ, 8, 0.3, watch)
  local opened = wait_for(function() watch(); return (KL.doorOpen(sid, U.outer) or 0) > 0.95 end, 60, "the outer door")
  BK.check("outer_open", opened, "outside, the outer door opens (the chamber at the moon's vacuum: %.2f atm)", RA.airOf(sid, ch.id).p)
  KIT.view("r3_airlock_outer_open", rec, { -4.5, 1.9, 2.8 }, { -0.5, 1.1, 0 })
  KIT.walk(rec, 0.0, DZ, 8, 0.3, watch)
  local x, y, z = KIT.at(rec)
  local _, crid = RA.crewRoom()
  BK.check("in_chamber", crid == ch.id, "in the chamber (%.2f, %.2f, %.2f)", x, y, z)
  local pmin, cyc_seen = 1, false
  local inner = wait_for(function()
    watch()
    local c = RA.chamberOf(sid, ch.id)
    if c and c.cyc then cyc_seen = true end
    return (KL.doorOpen(sid, U.inner) or 0) > 0.95
  end, 90, "the inner door")
  local cp, hp = RA.airOf(sid, ch.id).p, RA.airOf(sid, hab.id).p
  BK.check("cycle", inner and cyc_seen and cp > 0.75 and math.abs(cp - hp) < 0.06,
    "the outer door shut, the chamber pressurised from the hab's air to the hab's pressure (%.2f / %.2f atm), the inner door opened", cp, hp)
  BK.check("interlock", not both, "never both airlock doors open (outer max %.2f, inner max %.2f)", maxo.o, maxo.i)
  KIT.walk(rec, 2.4, DZ, 8, 0.3, watch)
  KIT.walk(rec, 2.6, -0.1, 6, 0.3, watch)
  wait(1.5)
  local _, hrid = RA.crewRoom()
  local a = astro()
  local okA = RA.airAt(a.x, a.y, a.z)
  local pw, su = findScript("planet_walker"), findScript("suit")
  local s0 = pw.suitO2
  wait(4)
  BK.check("breathe_room", hrid == hab.id and okA == true and pw.airSource == "ambient" and math.abs((pw.suitO2 or 0) - (s0 or 0)) < 1e-6,
    "in the hab the crew breathe its air: room %s, airAt %s, the walker's air %s, suit O2 %.4f → %.4f",
    tostring(hrid), tostring(okA), tostring(pw.airSource), s0 or -1, pw.suitO2 or -1)
  local okh, whyh = su.canRemoveHelmet()
  local offd = okh and su.setHelmet(false, { instant = true })
  wait(1.0)
  local _, hr2 = RA.crewRoom()
  BK.check("helmet_off", okh and not su.helmetOn() and hr2 == hab.id, "the helmet comes off in the room's air (in room %s; %s)", tostring(hr2), tostring(whyh))
  KIT.oview("r4_inside_hab_overlay", rec, { 4.4, 1.75, 0.6 }, { 0.2, 1.1, -0.2 })
  -- the seat tick: the crew by the seat, the vessel dormant
  KIT.walk(rec, 3.25, 0.25, 6, 0.3)
  wait(2.5)
  local vc = SL.controllerOf(sid)
  P("KIT ROOMS seat: vessel dormant %s, seat tick %s, prompt shown %s", tostring(vc and vc.dormant), tostring(vc and vc.DORM and vc.DORM.seat), tostring(vc and vc.DORM and vc.DORM.seatShown))
  KIT.cost("by the seat (S2 follow-up: the seat tick)", 4)
  BK.check("seat_tick", vc and vc.dormant == true and vc.DORM.seat == true, "the structure vessel stays dormant with the crew by its seat (vessel_controller %.4f ms/frame)",
    perf.scriptMs("vessel_controller") or -1)
  KIT.cost("rooms: crew inside, air ticking", 3)
  P("KIT ROOMS cost: room_air %.4f, rooms %.4f ms/frame · air step %.3f ms", perf.scriptMs("room_air") or -1, perf.scriptMs("rooms") or -1, RA.PROF.air_ms or -1)
  -- ── the far door: a leak ──
  KIT.walk(rec, 3.9, DZ, 6, 0.3)
  wait(3.0)
  local ax, ay, az = KIT.at(rec)
  local held = (KL.doorOpen(sid, U.far) or 1) < 0.02 and RA.airOf(sid, hab.id).p > 0.9
  BK.check("held", held, "the far door, to the moon, is held shut by the pressure with the crew beside it (crew at %.2f, %.2f; door %.2f; hab %.2f atm)",
    ax, az, KL.doorOpen(sid, U.far) or -1, RA.airOf(sid, hab.id).p)
  local ents = BK.menu(ST.nodeOf(sid, U.far))
  local fo = BK.entry(ents, "ra_force")
  P("KIT ROOMS far door menu: %s", fo and tostring(fo.label) or "no force row")
  -- (S7: the suit rule: helmet off, the crew won't go through a door to the
  -- moon, forced or not, so it goes back on first; forcing is a timed job)
  su.setHelmet(true, { instant = true })
  wait(0.5)
  if fo then BK.run_entry(fo) end
  local vent = wait_for(function() local q = RA.airOf(sid, hab.id); return q and q.venting and q.p < 0.6 end, 30, "the hab venting")
  local q = RA.airOf(sid, hab.id)
  local al = RA.lastAlarm
  BK.check("leak", vent and al and al.kind == "depress" and tostring(al.cause):find("Door Wall", 1, true),
    "forced open from its menu: the hab vents to the moon (%.2f atm), DEPRESSURISATION: %s", q.p, al and tostring(al.cause) or "no alarm")
  wait(1.0)
  KIT.oview("r5_leak_overlay", rec, { 7.5, 2.6, 2.5 }, { 3.5, 1.1, 0.0 })
  BK.check("helmet_back", su.helmetOn() and pw.airSource == "suit", "the helmet went back on, the suit's air (%s)", tostring(pw.airSource))
  KIT.walk(rec, 2.2, 0.0, 6, 0.3)
  -- (S7: forcing damaged the door's seal: it leaks, the regulator holding the
  -- hab against it, until the seal is re-seated from the door's menu)
  local held2 = wait_for(function() local q2 = RA.airOf(sid, hab.id); return q2 and q2.p > 0.9 end, 120, "the hab refilled")
  local q1 = RA.airOf(sid, hab.id)
  local seal = RA.sealOf and RA.sealOf(sid, U.far) or 0
  P("KIT ROOMS after forcing: seal %.0f %%, hab %.2f atm, venting %s (%s)", seal * 100, q1.p, tostring(q1.venting), tostring(q1.causes and q1.causes[1]))
  local rp = BK.entry(BK.menu(ST.nodeOf(sid, U.far)), "ra_repair")
  if rp then BK.run_entry(rp) end
  local back = held2 and wait_for(function() local q2 = RA.airOf(sid, hab.id); return q2 and not q2.venting and q2.p > 0.96 end, 120, "the hab refilled, the seal re-seated")
  local q2 = RA.airOf(sid, hab.id)
  BK.check("refill", back, "the far door shut behind the crew, its forced seal re-seated: the tank brought the hab back (%.2f atm, tank %.1f m³)", q2.p, RA.state(sid).tanks[U.tank] or -1)
  local st_txt = KL.screenText(sid, U.screen)
  BK.check("screen_rooms", st_txt and st_txt:find("ROOMS", 1, true) and st_txt:find("AIR", 1, true), "the screen reads the rooms: %s", tostring(st_txt))
  KIT.view("r6_screen", rec, { 3.7, 1.65, 0.55 }, { 3.0, 1.55, -0.9 })
  -- ── save and reload ──
  wait(3)
  -- (the air kept: every room's and the tank's, the inner door may be open)
  local function total(R_, sid_)
    local st_ = R_.state(sid_)
    local n, parts = 0, {}
    for _, r in ipairs(st_ and st_.R and st_.R.rooms or {}) do
      local a_ = R_.airOf(sid_, r.id)
      n = n + a_.p * r.m3
      parts[#parts + 1] = string.format("room %d %.3f atm", r.id, a_.p)
    end
    for _, q in pairs(st_ and st_.tanks or {}) do n = n + q end
    return n, table.concat(parts, ", ")
  end
  RA.saveNow()
  q2 = RA.airOf(sid, hab.id)
  local p0 = q2.p
  local tq0 = RA.state(sid).tanks[U.tank]
  local n0, d0 = total(RA, sid)
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(5)
  RA, ST, KL = findScript("room_air"), findScript("structures"), findScript("kit_live")
  RA.setVacuum(true)
  wait(2)
  local st2 = RA.state(sid)
  local R2 = st2 and st2.R
  local hab2 = R2 and findScript("rooms").roomAt(R2, 3, 1.2, 0)
  local q3 = hab2 and RA.airOf(sid, hab2.id)
  local n3, d3 = total(RA, sid)
  BK.check("reload", q3 and math.abs(n3 - n0) < 0.2 and q3.p > 0.95 and #R2.rooms == 2,
    "after a reload: %d rooms, the hab at %.3f atm (was %.3f), the tank %.2f m³ (was %.2f): all the air %.2f → %.2f m³ (%s → %s)", R2 and #R2.rooms or -1,
    q3 and q3.p or -1, p0, st2 and st2.tanks[U.tank] or -1, tq0 or -1, n0, n3, d0, d3)
  rec = ST.get(sid)
  RA.overlay, RA.overlayAlways = true, true
  KIT.oview("r7_after_reload", rec, { -2.5, 4.5, 8.5 }, { 2, 1.0, 0 })
  BK.result()
end
