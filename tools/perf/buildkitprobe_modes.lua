-- ── build kit probe (tools/perf/buildkitprobe.sh): deep-space step 4 ────────
-- (K1–K4, K8, K13, N1: the Build Kit, the free cursor, the BASE column, the
-- ghost, placing, structure records, money and shipping). Spliced into a copy
-- of perfbench.lua after vfxprobe_modes.lua (its freecam); one table of
-- functions (perfbench's main chunk is near Lua's 200-locals ceiling).
--   buildkit   on the home world, 150+ m out from the spaceport on flat
--              ground: the Pilot's B refused; the Engineer issued a kit; B
--              opens it (third person, a free cursor, the parts column with
--              its BASE cards and "$900 + $140 shipping"); a Pad Plate's ghost
--              on the ground under the cursor (green), held there while the
--              planet moves (the ghost's foot against a terrain ray, every
--              frame); LMB places it: $1,040 charged, a structure record in
--              the planet's frame; Ctrl+Z: all of it back; placed again with
--              an Equipment Shed beside it; a red ghost over the shed; the
--              cost of the kit and of idle structures; save, reload: both
--              where they were on the planet that moved meanwhile, their
--              colliders there; pictures from two sides.
--              STEP 5 (K5–K7, K9–K10), on from there: a plate edge to edge
--              with the slab; a hab across the two; a third plate along the
--              row and a shed on its deck; a mound raised and a shed set on
--              its flank (the footing, its bill, the ground levelled under
--              it); Deconstruct from the context menu's entry (the third
--              plate past its minute and the shed on it); the undo ring
--              (Ctrl+Z ×2, Ctrl+Shift+Z, refused past a minute); the folded
--              36 px tab; the icon camera captured in the sky and inside the
--              planet; the idle cost; save, reload, every part on its record.
--              Run with PATCHES=funds.patch (a fresh save has $500).
-- One `BK PASS|FAIL <check>` line a check and `BK RESULT <mode>: PASS/FAIL`.
-- Pictures: 1280x720, save/user/buildshots/<name>.png in the scratch project.
BK = { fails = 0, tag = "buildkit" }
function BK.check(name, ok, fmt, ...)
  P("BK %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then BK.fails = BK.fails + 1 end
  return ok
end
function BK.result() P("BK RESULT %s: %s (%d failed check(s))", BK.tag, BK.fails == 0 and "PASS" or "FAIL", BK.fails) end
function BK.shot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s t=%.3f", nm, time)
    else P("BK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("BK capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- The flattest dry ground 150–260 m out from the base (radii sampled ±3 m).
function BK.flat_spot()
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local best
  for _, d in ipairs({ 150, 180, 210, 240, 270 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local g0 = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if g0 then
        local rough, n = 0, 0
        for _, e in ipairs({ { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 }, { 8, 0 }, { 0, 8 } }) do
          local s = unit(cross(dir, t))
          local dd = unit({ x = dir.x * R + t.x * e[1] + s.x * e[2], y = dir.y * R + t.y * e[1] + s.y * e[2], z = dir.z * R + t.z * e[1] + s.z * e[2] })
          local g = ground_r(b, dd.x, dd.y, dd.z, R + 150)
          if g then rough = rough + math.abs(g - g0); n = n + 1 end
        end
        local p = { x = b.x + dir.x * g0, y = b.y + dir.y * g0, z = b.z + dir.z * g0 }
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        -- (never on the spaceport's own ground: the runway's graded overruns
        -- are the flattest ground there is, and building there is refused)
        local bf = findScript("base_facilities")
        local kept = false
        if bf and bf.keepClear then
          local s = unit(cross(dir, t))
          for _, e in ipairs({ { 0, 0 }, { 25, 0 }, { -25, 0 }, { 0, 25 }, { 0, -25 } }) do
            local q = { x = dir.x * g0 + t.x * e[1] + s.x * e[2], y = dir.y * g0 + t.y * e[1] + s.y * e[2], z = dir.z * g0 + t.z * e[1] + s.z * e[2] }
            if bf.keepClear(b.name, q.x, q.y, q.z) then kept = true end
          end
        end
        if n >= 5 and not wet and not kept then
          local score = rough / n
          if not best or score < best.score then best = { dir = dir, r = g0, t = t, d = d, score = score } end
        end
      end
    end
  end
  return best
end

-- A world point on the ground `ahead` m in front of the crew and `side` m to
-- their right (this frame: the crew's drawn pose, a terrain ray down).
function BK.ground_ahead(ahead, side)
  local a, b = astro(), home()
  local U = unit(sub(a, b))
  local F = BK.F
  local Rt = unit(cross(F, U))
  local p = { x = a.x + F.x * ahead + Rt.x * side + U.x * 6, y = a.y + F.y * ahead + Rt.y * side + U.y * 6,
              z = a.z + F.z * ahead + Rt.z * side + U.z * 6 }
  local h = raycast(p.x, p.y, p.z, -U.x, -U.y, -U.z, 40, { ignore = a })
  return h
end

-- The cursor on a ground point, re-aimed every frame (the planet moves).
function BK.aim_at(ahead, side)
  local fb = findScript("field_builder")
  BK.aimfn = function()
    local h = BK.ground_ahead(ahead, side)
    if not h then return end
    local sx, sy, _, on = camera.worldToScreen(h.x, h.y, h.z)
    if sx and on ~= false then fb.sim = fb.sim or {}; fb.sim.mouse = { sx, sy } end
  end
end

function BK.click(shift)
  local fb = findScript("field_builder")
  fb.sim = fb.sim or {}
  fb.sim.shift = shift == true
  fb.sim.lmb = true
  yield(); yield()
  fb.sim.lmb = false
  yield(); yield()
  fb.sim.shift = false     -- (Shift also frees the grid: not past the click)
end

-- the ghost's foot vs the ground under it, every frame for `secs`
function BK.ghost_on_ground(secs)
  local fb = findScript("field_builder")
  local worst, n, moved = 0, 0, 0
  local b0 = home()
  local p0 = { x = b0.x, y = b0.y, z = b0.z }
  local t_end = time + secs
  while time < t_end do
    BK.aimfn()
    yield()
    local g, rq = fb.ghost_node, fb.req
    if g and g.valid and g.visible and rq and rq.def then
      local b = home()
      local w = g.worldPos
      local U = unit(sub(w, b))
      -- (the pose's ground point: the ghost's origin less its seat and the
      -- levelled base step 5 sets it on)
      local s = rq.def.seat + (rq.base or 0)
      local foot = { x = w.x - U.x * s, y = w.y - U.y * s, z = w.z - U.z * s }
      local h = raycast(foot.x + U.x * 3, foot.y + U.y * 3, foot.z + U.z * 3, -U.x, -U.y, -U.z, 8, { ignore = astro() })
      if h then
        local gap = len(foot.x - h.x, foot.y - h.y, foot.z - h.z)
        worst = math.max(worst, gap)
        n = n + 1
      end
    end
  end
  local b1 = home()
  moved = len(b1.x - p0.x, b1.y - p0.y, b1.z - p0.z)
  return worst, n, moved
end

function BK.struct_err(ST, id)
  local r = ST.get(id)
  local nodes = ST.nodesOf(id)
  if not (r and nodes and nodes[1]) then return nil end
  local pb = findScript("parts_base")
  local def = pb.partInfo(r.bp[1].id)
  local x, y, z = ST.partPose(r, r.bp[1], def.seat)
  local b = space.body(r.b)
  local w = nodes[1].worldPos
  return len(w.x - b.x - x, w.y - b.y - y, w.z - b.z - z), nodes[1]
end

function BK.run()
  BK.tag = params.tag or "buildkit"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  if not BK.check("scene", fb and ST and co and C, "field_builder %s structures %s", tostring(fb ~= nil), tostring(ST ~= nil)) then BK.result() return end
  -- out to flat ground
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out, roughness %.2f m", spot and spot.d or -1, spot and spot.score or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  -- face along the bearing (the walker turns to its last move: a short walk)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  local a = astro()
  -- "ahead" = the camera's view along the ground, so the aim points are on screen
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(a, home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  P("BK at %s, %.0f m from the base", home().name, spot.d)
  -- THE GATE: the active member is the Pilot on a new save
  local act = C.activeId()
  BK.check("pilot", C.role(act) ~= "engineer", "the active member #%d is the %s", act, tostring(C.role(act)))
  tap("b"); wait(0.5)
  BK.check("gate", not fb.isOpen(), "the Pilot's B opens nothing (gate: %s)", tostring(fb.gate))
  -- make them the Engineer (the probe's shortcut for a retrain) and wait for the issue
  C.patch(act, { role = "engineer" })
  wait(3.5)
  local inv = findScript("inventory")
  BK.check("issued", inv.itemCount("astro", "buildkit") == 1, "the Engineer is issued one Build Kit (%d)", inv.itemCount("astro", "buildkit"))
  tap("b"); wait(1.5)
  local pc = findScript("planet_camera")
  BK.check("open", fb.isOpen() and not pc.firstPerson and not pc.shiftlock, "B opens the kit: third person, no shift-lock (gate %s)", tostring(fb.gate))
  local catn = find("Field Catalogue")
  BK.check("panel", catn ~= nil, "the parts column is up (Field Catalogue node)")
  local cp = findScript("catalog_panel")
  local list = cp and cp.listFor and cp.listFor(fb, "ALL", "") or {}
  BK.check("cards", #list == 3 and list[1].id == "padPlate", "ALL lists the BASE parts: %d", #list)
  local p1, p2 = fb.cardLines("padPlate", fb.partInfo("padPlate"), false)
  BK.check("price", p1 == "$1,040" and p2 == "$900 + $140 shipping · Pell Groundworks", "the Pad Plate card: %s / %s", tostring(p1), tostring(p2))
  wait(4)
  BK.check("icons", cp.iconCount and cp.iconCount() >= 3, "the cards' icons are taken from the stand: %d", cp.iconCount and cp.iconCount() or -1)
  BK.shot("1_kit_open")
  -- the stand is out of the main view: look straight down and up for it
  P("BK preview frame: %s", tostring(find("FieldPreviewFrame") ~= nil))
  -- THE GHOST
  local funds0 = co.balance()
  cp.pickPart("padPlate")
  BK.aim_at(9, 0)
  for _ = 1, 30 do BK.aimfn(); yield() end
  local rq = fb.req
  BK.check("ghost", fb.ghost_node ~= nil and rq and not rq.bad, "a Pad Plate ghost under the cursor, valid (%s)", rq and tostring(rq.bad) or "no req")
  local worst, n, moved = BK.ghost_on_ground(3.0)
  BK.check("ghost_ground", n > 30 and worst < 0.06, "the ghost's foot on the ground over %d frames: worst %.3f m while the planet moved %.0f m", n, worst, moved)
  BK.shot("2_ghost_pad")
  -- the kit's own cost while the ghost is up
  local f0 = FRAME
  local ms0 = perf.scriptMs and perf.scriptMs("field_builder") or -1
  wait(2)
  BK.cost_open = perf.scriptMs and perf.scriptMs("field_builder") or -1
  P("BK COST open with a ghost: field_builder %.3f ms/frame, structures %.3f ms (%d frames)", BK.cost_open,
    perf.scriptMs and perf.scriptMs("structures") or -1, FRAME - f0)
  -- PLACE
  BK.aimfn()
  BK.click(false)
  wait(0.5)
  local lp = fb.lastPlace
  local spent = funds0 - co.balance()
  BK.check("charged", lp ~= nil and spent == 1040, "LMB placed it: %s charged ($900 + $140 shipping)", tostring(spent))
  local ledger = save.get("co.ledger") or {}
  local last = ledger[#ledger] or {}
  BK.check("ledger", last.amount == -1040 and tostring(last.why):find("Pell Groundworks", 1, true), "the ledger: %s %s", tostring(last.amount), tostring(last.why))
  BK.check("dropped", fb.heldPart == nil, "a plain click empties the hand")
  local sid = lp and lp.sid
  local rec = sid and ST.get(sid)
  BK.check("record", rec and rec.b == home().name and rec.bp[1].id == "padPlate" and math.abs(len(rec.x, rec.y, rec.z) - home().radius) < 200,
    "struct.%s on %s, body-relative (%.1f m from the centre)", tostring(sid), rec and rec.b or "?", rec and len(rec.x, rec.y, rec.z) or -1)
  wait(1.5)
  local err = BK.struct_err(ST, sid)
  BK.check("spawned", err and err < 0.01, "the slab stands where its record says (%.4f m)", err or -1)
  BK.shot("3_placed_pad")
  -- UNDO (Ctrl+Z)
  local f1 = co.balance()
  key_down("ctrl"); tap("z"); key_up("ctrl")
  wait(0.5)
  BK.check("undo", co.balance() - f1 == 1040 and ST.get(sid) == nil, "Ctrl+Z within the minute: %s back, the slab gone", tostring(co.balance() - f1))
  -- placed again (Shift keeps one in hand), then the shed off to one side
  cp.pickPart("padPlate")
  BK.aim_at(9, 0)
  for _ = 1, 20 do BK.aimfn(); yield() end
  BK.click(true)
  wait(0.5)
  local sid_pad = fb.lastPlace and fb.lastPlace.sid
  BK.check("keep", fb.heldPart == "padPlate", "Shift+LMB keeps a Pad Plate in hand")
  -- a red ghost: over the slab just placed (its centre is no edge slot)
  for _ = 1, 30 do BK.aimfn(); yield() end
  BK.check("red", fb.req and fb.req.bad ~= nil, "a second slab on the first: red, \"%s\"", fb.req and tostring(fb.req.bad) or "no req")
  BK.shot("4_red_ghost")
  cp.pickPart("shed")
  BK.aim_at(8.5, 9.0)
  for _ = 1, 30 do BK.aimfn(); yield() end
  BK.check("shed_ghost", fb.req and not fb.req.bad and fb.req.pose.mode == "grid", "the shed's ghost on the ground beside the slab, on the grid: %s (%s)",
    fb.req and tostring(fb.req.bad) or "valid", fb.req and fb.req.pose and tostring(fb.req.pose.mode) or "-")
  BK.shot("5_shed_ghost")
  local f2 = co.balance()
  local qs = fb.req and fb.req.quote and fb.req.quote.total or -1
  BK.click(false)
  wait(1.0)
  local sid_shed = fb.lastPlace and fb.lastPlace.sid
  BK.check("shed", sid_shed and sid_shed ~= sid_pad and f2 - co.balance() == qs and qs >= 1590,
    "the shed placed: %s ($1,400 + $190 shipping%s)", tostring(f2 - co.balance()), qs > 1590 and " + its footing" or "")
  BK.sid_pad, BK.sid_shed = sid_pad, sid_shed
  -- ════ STEP 5 (K5–K7, K9–K10) ═════════════════════════════════════════════
  BK.step5(fb, ST, co, cp)
end

-- a part's node vs its record (m), and the node
function BK.part_err(ST, sid, uid)
  local r = ST.get(sid)
  local p = r and ST.getPart(sid, uid)
  local n = ST.nodeOf(sid, uid)
  if not (p and n) then return nil end
  local def = findScript("parts_base").partInfo(p.id)
  local x, y, z = ST.partPose(r, p, def.seat)
  local b = space.body(r.b)
  local w = n.worldPos
  return len(w.x - b.x - x, w.y - b.y - y, w.z - b.z - z), n
end
-- a structure-frame point → this frame's world point
function BK.lw(ST, rec, lx, ly, lz)
  local SN = findScript("base_snap")
  local fr = SN.frameOf(rec)
  local x, y, z = SN.toBody(fr, lx, ly, lz)
  local b = space.body(rec.b)
  return { x = b.x + x, y = b.y + y, z = b.z + z }
end
-- the cursor on a structure-frame point, re-aimed every frame
function BK.aim_local(ST, sid, lx, ly, lz)
  local fb = findScript("field_builder")
  BK.aimfn = function()
    local r = ST.get(sid)
    if not r then return end
    local w = BK.lw(ST, r, lx, ly, lz)
    local sx, sy, _, on = camera.worldToScreen(w.x, w.y, w.z)
    if sx and on ~= false then fb.sim = fb.sim or {}; fb.sim.mouse = { sx, sy } end
  end
end
function BK.settle(n) for _ = 1, n or 30 do BK.aimfn(); yield() end end
-- the free edge slot of part (sid, uid) farthest from a world point
function BK.far_slot(ST, sid, uid, from)
  local r = ST.get(sid)
  local p = ST.getPart(sid, uid)
  local best
  for _, s in ipairs({ { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 } }) do
    local lx, lz = p.x + s[1], p.z + s[2]
    local w = BK.lw(ST, r, lx, p.y, lz)
    local d = len(w.x - from.x, w.y - from.y, w.z - from.z)
    local a = astro()
    local reach = len(w.x - a.x, w.y - a.y, w.z - a.z)
    if reach < 20 and (not best or d > best.d) then best = { d = d, lx = lx, lz = lz } end
  end
  return best
end

function BK.step5(fb, ST, co, cp)
  local pb = findScript("parts_base")
  local a = astro()
  -- THE SLAB from step 4's run (sid_pad) is the anchor: find it
  local sid_pad = BK.sid_pad
  local sid_shed = BK.sid_shed
  local shed_w = ST.nodeOf(sid_shed, 1) and ST.nodeOf(sid_shed, 1).worldPos
  -- 1. PLATES EDGE TO EDGE: a plate aimed 0.6 m past the slab's far edge
  cp.pickPart("padPlate")
  local slot = BK.far_slot(ST, sid_pad, 1, shed_w or a)
  BK.aim_local(ST, sid_pad, slot.lx * 1.15, 0.0, slot.lz * 1.15)
  BK.settle(30)
  local rq = fb.req
  BK.check("edge_ghost", rq and rq.pose and rq.pose.mode == "edge" and rq.pose.sid == sid_pad and not rq.bad,
    "a plate aimed past the slab's edge snaps edge to edge: mode %s, joins %s, %s", rq and rq.pose and tostring(rq.pose.mode) or "-",
    rq and rq.pose and tostring(rq.pose.sid) or "-", rq and tostring(rq.bad or "valid") or "no req")
  BK.shot("9_edge_ghost")
  local f0 = co.balance()
  BK.click(false)
  wait(1.0)
  local r = ST.get(sid_pad)
  local p2 = r and r.bp[2]
  local e2, n2 = 99, nil
  if p2 then e2, n2 = BK.part_err(ST, sid_pad, p2.uid) end
  local n1 = ST.nodeOf(sid_pad, 1)
  local gap = (n1 and n2) and len(n2.worldPos.x - n1.worldPos.x, n2.worldPos.y - n1.worldPos.y, n2.worldPos.z - n1.worldPos.z) or -1
  local U = n1 and unit(sub(n1.worldPos, home()))
  local dh = (n1 and n2) and dot(sub(n2.worldPos, n1.worldPos), U) or 99
  BK.check("edge", p2 and math.abs(math.abs(p2.x) + math.abs(p2.z) - 4) < 1e-6 and p2.y == 0 and (e2 or 99) < 0.01
    and math.abs(gap - 4.0) < 0.01 and math.abs(dh) < 0.05 and f0 - co.balance() >= 1040,
    "the second plate: local (%.2f, %.2f, %.2f), centres %.3f m apart, level within %.3f m (curvature), %s charged",
    p2 and p2.x or -1, p2 and p2.y or -1, p2 and p2.z or -1, gap, dh, tostring(f0 - co.balance()))
  -- 2. A HAB ON THE TWO PLATES: aimed at their shared edge, turned along them
  cp.pickPart("hab")
  local mx, mz = p2 and p2.x / 2 or 0, p2 and p2.z / 2 or 0
  fb.yawOffset = 0
  BK.aim_local(ST, sid_pad, mx, 0.2, mz)
  BK.settle(30)
  -- (the hab's long axis must run along the plates: a quarter turn if not)
  if fb.req and fb.req.bad and tostring(fb.req.bad):find("hangs off", 1, true) then
    fb.yawOffset = math.pi / 2
    BK.settle(20)
  end
  rq = fb.req
  BK.check("hab_ghost", rq and rq.pose and rq.pose.mode == "deck" and not rq.bad,
    "a hab aimed between the plates stands on their deck: %s, %s", rq and rq.pose and tostring(rq.pose.mode) or "-", rq and tostring(rq.bad or "valid") or "no req")
  BK.shot("10_hab_ghost")
  BK.click(false)
  wait(1.0)
  fb.yawOffset = 0
  r = ST.get(sid_pad)
  local ph = r and r.bp[3]
  local eh = ph and BK.part_err(ST, sid_pad, ph.uid)
  BK.check("hab", ph and ph.id == "hab" and math.abs(ph.y - 0.20) < 1e-6 and eh and eh < 0.01,
    "the hab joins the structure on the deck (local y %.2f, node %.4f m off its record)", ph and ph.y or -1, eh or -1)
  -- one hab on ONE plate: refused
  -- 3. A THIRD PLATE and A SHED ON IT
  cp.pickPart("padPlate")
  local slot3 = BK.far_slot(ST, sid_pad, p2 and p2.uid or 2, n1 and n1.worldPos or a)
  BK.aim_local(ST, sid_pad, slot3.lx + (slot3.lx - (p2 and p2.x or 0)) * 0.1, 0, slot3.lz + (slot3.lz - (p2 and p2.z or 0)) * 0.1)
  BK.settle(30)
  rq = fb.req
  BK.check("edge2", rq and rq.pose and rq.pose.mode == "edge" and not rq.bad, "a third plate along the row: %s %s",
    rq and rq.pose and tostring(rq.pose.mode) or "-", rq and tostring(rq.bad or "valid") or "no req")
  BK.click(false)
  wait(1.0)
  r = ST.get(sid_pad)
  local p3 = r and r.bp[4]
  cp.pickPart("shed")
  BK.aim_local(ST, sid_pad, p3 and p3.x + 0.2 or 0, 0.2, p3 and p3.z - 0.15 or 0)
  BK.settle(30)
  rq = fb.req
  BK.check("deck_ghost", rq and rq.pose and rq.pose.mode == "deck" and not rq.bad and math.abs(rq.pose.ly - 0.2) < 1e-6,
    "a shed aimed at the third plate stands on its deck: %s at %.2f m, %s", rq and rq.pose and tostring(rq.pose.mode) or "-",
    rq and rq.pose and rq.pose.ly or -1, rq and tostring(rq.bad or "valid") or "no req")
  BK.shot("11_shed_on_plate_ghost")
  BK.click(false)
  wait(1.0)
  r = ST.get(sid_pad)
  local ps = r and r.bp[5]
  local es, ns = 99, nil
  if ps then es, ns = BK.part_err(ST, sid_pad, ps.uid) end
  local n3 = p3 and ST.nodeOf(sid_pad, p3.uid)
  local over = (ns and n3) and dot(sub(ns.worldPos, n3.worldPos), unit(sub(n3.worldPos, home()))) or -1
  -- (the shed's origin sits seat 1.30 over its ground, the plate's −0.0475 under its own: 0.20 + 1.30 + 0.0475)
  BK.check("shed_on_plate", ps and ps.id == "shed" and es < 0.01 and math.abs(over - (0.20 + 1.30 + 0.0475)) < 0.02
    and math.abs(ps.x - p3.x) < 0.51 and math.abs(ps.z - p3.z) < 0.51,
    "the shed stands on the plate: %.3f m over its origin (want 1.548), local (%.2f, %.2f) on a plate at (%.2f, %.2f)",
    over, ps and ps.x or -1, ps and ps.z or -1, p3 and p3.x or -1, p3 and p3.z or -1)
  -- a ray from above lands on the shed's roof, and the deck beside it on the plate
  if ns then
    local w = ns.worldPos
    local Uw = unit(sub(w, home()))
    local h = raycast(w.x + Uw.x * 6, w.y + Uw.y * 6, w.z + Uw.z * 6, -Uw.x, -Uw.y, -Uw.z, 10, { ignore = astro() })
    local hp = nil
    if h and h.node then local _, pp = ST.partOfNode(h.node); hp = pp end
    BK.check("roof_owner", hp and hp.uid == ps.uid, "a ray on the shed's roof resolves to its structure part (%s)", h and h.node and h.node.name or "none")
  end
  BK.shot("12_structure_close")
  -- 4. A FOUNDATION ON A SLOPE: a mound raised beside the crew, a shed on its flank
  local b = home()
  a = astro()
  local Ua = unit(sub(a, b))
  local Rt = unit(cross(BK.F, Ua))
  -- (19 m ahead, clear of the plate row, which runs away from the shed)
  local mc = { x = a.x + BK.F.x * 19 + Rt.x * 1, y = a.y + BK.F.y * 19 + Rt.y * 1, z = a.z + BK.F.z * 19 + Rt.z * 1 }
  local gh = raycast(mc.x + Ua.x * 8, mc.y + Ua.y * 8, mc.z + Ua.z * 8, -Ua.x, -Ua.y, -Ua.z, 30, { ignore = a })
  if gh then
    local rel = sub(gh, b)
    for _ = 1, 2 do
      local bb = home()
      terrain.sculpt(bb.x + rel.x, bb.y + rel.y, bb.z + rel.z, 6.0, 1.0, "raise")
      wait(0.3)
    end
    wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20, "the mound")
    wait(1.0)
    BK.mound = rel
  end
  cp.pickPart("shed")
  local best, bestp = nil, nil
  -- walk the cursor down the mound's flank until the ghost wants a footing
  for _, k in ipairs({ 4.0, 4.5, 5.0, 5.5, 6.0, 3.5, 6.5, 3.0, 7.0, 2.5 }) do
    local fbase = BK.mound
    if fbase then
      BK.aimfn = function()
        local bb = home()
        local p = { x = bb.x + fbase.x + Rt.x * k + Ua.x * 6, y = bb.y + fbase.y + Rt.y * k + Ua.y * 6, z = bb.z + fbase.z + Rt.z * k + Ua.z * 6 }
        local h = raycast(p.x, p.y, p.z, -Ua.x, -Ua.y, -Ua.z, 20, { ignore = astro() })
        if not h then return end
        local sx, sy, _, on = camera.worldToScreen(h.x, h.y, h.z)
        if sx and on ~= false then fb.sim = fb.sim or {}; fb.sim.mouse = { sx, sy } end
      end
      BK.settle(25)
      rq = fb.req
      P("BK slope try %.1f m: %s footing %s spread %s", k, rq and tostring(rq.bad or "valid") or "no req",
        rq and rq.plan and rq.plan.footing and string.format("%.2f", rq.plan.footing.d) or "-", rq and rq.plan and string.format("%.2f", rq.plan.spread or -1) or "-")
      if rq and not rq.bad and rq.plan and rq.plan.footing then best = k break end
    end
  end
  rq = fb.req
  BK.check("slope_ghost", best ~= nil, "a shed on the mound's flank: footing %.2f m deep, the ground falls %.2f m across it, quote %s",
    rq and rq.plan and rq.plan.footing and rq.plan.footing.d or -1, rq and rq.plan and rq.plan.spread or -1, rq and rq.quote and tostring(rq.quote.total) or "-")
  BK.shot("13_slope_ghost")
  local fs = co.balance()
  local quote_total = rq and rq.quote and rq.quote.total or 0
  BK.click(false)
  wait(0.5)
  local lp = fb.lastPlace
  local sid_slope = lp and lp.sid
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20, "the levelling")
  wait(1.5)
  local rs = sid_slope and ST.get(sid_slope)
  local pfs = rs and rs.bp[1]
  BK.check("slope_place", pfs and pfs.ft and pfs.ft.d > 0.3 and fs - co.balance() == quote_total and (pfs.paid.foot or 0) > 0
    and ST.footOf(sid_slope, 1) ~= nil,
    "placed with its footing: %.2f m deep, %s charged (%s of it concrete), the footing drawn %s",
    pfs and pfs.ft and pfs.ft.d or -1, tostring(fs - co.balance()), tostring(pfs and pfs.paid.foot), tostring(ST.footOf(sid_slope or 0, 1) ~= nil))
  -- the ground under it is level at its base now (terrain rays at the footprint's corners)
  if rs then
    local SN = findScript("base_snap")
    local fr = SN.frameOf(rs)
    local worst = 0
    for _, q in ipairs(SN.footPoints(pb.partInfo("shed"), 0, 0, 0, 0.3)) do
      local w = BK.lw(ST, rs, q.x, 2.5, q.z)
      local h = terrain.raycast(vec3(w.x, w.y, w.z), vec3(-fr.U.x, -fr.U.y, -fr.U.z), 8)
      if h and h.distance then
        worst = math.max(worst, math.abs(h.distance - 2.5))
        BK.above = math.max(BK.above or -9, 2.5 - h.distance)
        BK.below = math.max(BK.below or 0, h.distance - 2.5)
        P("BK level sample (%.2f, %.2f): ground %+.3f m from the base", q.x, q.z, 2.5 - h.distance)
      end
    end
    -- (levelled: nothing stands above the base; what the fill could not reach
    -- on the low side lies inside the footing, which is cast to cover it)
    local fd = pfs and pfs.ft and pfs.ft.d or 0
    BK.check("levelled", (BK.above or 0) < 0.05 and (BK.below or 0) < fd - 0.3,
      "the ground under the footprint: at most %+.3f m above the shed's base, %.3f m below it on the low side (inside the %.2f m footing)",
      BK.above or 0, BK.below or 0, fd)
  end
  -- the view of it, from the open side
  do
    local n = ST.nodeOf(sid_slope or 0, 1)
    if n then
      local bb = home()
      local w = sub(n.worldPos, bb)
      local Uw = unit(w)
      local eye = { x = w.x + Rt.x * 9 - BK.F.x * 4 + Uw.x * 2.5, y = w.y + Rt.y * 9 - BK.F.y * 4 + Uw.y * 2.5, z = w.z + Rt.z * 9 - BK.F.z * 4 + Uw.z * 2.5 }
      VP.cam_fixed(eye, { x = w.x - Uw.x * 0.8, y = w.y - Uw.y * 0.8, z = w.z - Uw.z * 0.8 })
      wait(1.2)
      BK.shot("14_footing", false)
      VP.cam_off()
      wait(0.5)
    end
  end
  -- 5. DECONSTRUCT through the context menu's entry: the third plate (aged past
  -- its minute) takes the shed standing on it down too
  local reg = findScript("context_registry")
  local cm = findScript("context_menu")
  local n3b = p3 and ST.nodeOf(sid_pad, p3.uid)
  local tgt = n3b and cm and cm.resolve and cm.resolve({ node = n3b, x = n3b.worldPos.x, y = n3b.worldPos.y, z = n3b.worldPos.z })
  local ents = (tgt and reg and reg.entriesFor) and reg.entriesFor(tgt, { actor = { kind = "crew", id = findScript("crew").activeId() }, toast = function() end }) or {}
  local dec = nil
  for _, e in ipairs(ents) do if tostring(e.id):find("bk_decon", 1, true) then dec = e end end
  BK.check("menu", tgt and tgt.kind == "prop" and dec ~= nil and dec.job ~= nil, "RMB on the third plate offers Deconstruct (%d rows, target %s)",
    #ents, tgt and tgt.kind or "none")
  if p3 then
    local rr = ST.get(sid_pad)
    for _, pp in ipairs(rr.bp) do if pp.uid == p3.uid then pp.paid.t = pp.paid.t - 120 end end
    ST.put(rr)
  end
  local fd = co.balance()
  local q_amt, q_n, q_full = fb.deconstructQuote(sid_pad, p3 and p3.uid or 0)
  if dec and dec.job then
    local okc = dec.job.check and dec.job.check()
    BK.check("menu_check", okc ~= false, "the job's check passes")
    wait(3.0)      -- (the menu runs it 3 s; the probe waits the same)
    dec.job.done()
  end
  wait(0.5)
  local got = co.balance() - fd
  BK.check("deconstruct", got == q_amt and got == 900 + 1590 and q_n == 2 and not q_full and ST.getPart(sid_pad, p3 and p3.uid or 0) == nil
    and ST.getPart(sid_pad, ps and ps.uid or 0) == nil and ST.nodeOf(sid_pad, p3 and p3.uid or 0) == nil,
    "deconstructed: %s back (the plate's $900, fee kept; the shed on it in its minute, all $1,590), 2 parts down, their nodes gone", tostring(got))
  BK.shot("15_after_deconstruct", false)
  -- 6. THE UNDO RING: Ctrl+Z puts them back, Ctrl+Z again returns the footed shed,
  -- Ctrl+Shift+Z buys it again; past its minute the ring refuses
  local fu = co.balance()
  key_down("ctrl"); tap("z"); key_up("ctrl")
  wait(0.6)
  BK.check("undo_decon", ST.getPart(sid_pad, p3 and p3.uid or 0) ~= nil and ST.getPart(sid_pad, ps and ps.uid or 0) ~= nil
    and fu - co.balance() == got, "Ctrl+Z on the deconstruct: both back, %s taken back", tostring(fu - co.balance()))
  wait(0.8)
  BK.check("undo_respawn", ST.nodeOf(sid_pad, p3 and p3.uid or 0) ~= nil and ST.nodeOf(sid_pad, ps and ps.uid or 0) ~= nil, "...and standing again")
  local fu2 = co.balance()
  key_down("ctrl"); tap("z"); key_up("ctrl")
  wait(0.6)
  BK.check("undo_ring", ST.get(sid_slope or 0) == nil and co.balance() - fu2 == quote_total,
    "Ctrl+Z again (the ring's next step): the footed shed returned, %s back", tostring(co.balance() - fu2))
  local fu3 = co.balance()
  key_down("ctrl"); key_down("shift"); tap("z"); key_up("shift"); key_up("ctrl")
  wait(1.0)
  BK.check("redo", ST.get(sid_slope or 0) ~= nil and fu3 - co.balance() == quote_total, "Ctrl+Shift+Z: bought again (%s)", tostring(fu3 - co.balance()))
  -- age the ring's top past its minute: refused
  local H = fb.history()
  if H and H:top() then H:top().t = H:top().t - 120 end
  local fu4, n0 = co.balance(), ST.count()
  key_down("ctrl"); tap("z"); key_up("ctrl")
  wait(0.4)
  BK.check("undo_old", co.balance() == fu4 and ST.count() == n0 and H:canUndo(), "past its minute Ctrl+Z refuses (deconstruct it instead)")
  -- 7. THE FOLDED COLUMN: B folds it to its 36 px tab
  tap("b"); wait(0.8)
  BK.check("folded", fb.collapsed == true and find("Field Catalogue") ~= nil, "B folds the column to its tab")
  BK.shot("16_folded")
  tap("b"); wait(0.5)
  -- 8. THE ICONS: the stand's icon camera photographed in the sky (now) and,
  -- for the record, with the stand where step 4 had it (inside the planet)
  BK.icon_ab()
  -- the idle cost of the structures (the kit closed)
  fb.heldPart = nil
  tap("escape"); wait(0.5)
  BK.check("close", not fb.isOpen(), "Esc closes the kit (after the hand is empty)")
  wait(1)
  local f3 = FRAME
  wait(3)
  P("BK COST idle step5: structures %.4f ms/frame, field_builder %.4f ms (%d frames, %d structures, %d parts)",
    perf.scriptMs and perf.scriptMs("structures") or -1, perf.scriptMs and perf.scriptMs("field_builder") or -1, FRAME - f3,
    ST.count(), #ST.get(sid_pad).bp)
  -- views of the base
  do
    local n = ST.nodeOf(sid_pad, 1)
    if n then
      local bb = home()
      local w = sub(n.worldPos, bb)
      local Uw = unit(w)
      local Rr = unit(cross(BK.F, Uw))
      local function view(nm, fwd, side, hgt)
        local eye = { x = w.x + BK.F.x * fwd + Rr.x * side + Uw.x * hgt, y = w.y + BK.F.y * fwd + Rr.y * side + Uw.y * hgt, z = w.z + BK.F.z * fwd + Rr.z * side + Uw.z * hgt }
        VP.cam_fixed(eye, { x = w.x + Uw.x * 1.5, y = w.y + Uw.y * 1.5, z = w.z + Uw.z * 1.5 })
        wait(1.2)
        BK.shot(nm, false)
      end
      view("17_base_a", -14, -10, 7)
      view("18_base_b", 12, 12, 5)
      VP.cam_off()
    end
  end
  -- 9. SAVE AND RELOAD
  local snap = {}
  for _, rr in ipairs(ST.list()) do
    for _, pp in ipairs(rr.bp) do snap[#snap + 1] = { sid = rr.id, uid = pp.uid, id = pp.id, ft = pp.ft ~= nil } end
  end
  local b0 = home()
  local bp0 = { x = b0.x, y = b0.y, z = b0.z }
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(3)
  ST = findScript("structures")
  local worst, missing, feet = 0, 0, 0
  for _, s in ipairs(snap) do
    local e = BK.part_err(ST, s.sid, s.uid)
    if not e then missing = missing + 1 else worst = math.max(worst, e) end
    if s.ft and ST.footOf(s.sid, s.uid) then feet = feet + 1 end
  end
  local b1 = home()
  BK.check("reload5", missing == 0 and worst < 0.01 and feet >= 1,
    "after a reload all %d parts stand on their records (worst %.4f m, %d missing, %d footing drawn) on a planet that moved %.0f m",
    #snap, worst, missing, feet, len(b1.x - bp0.x, b1.y - bp0.y, b1.z - bp0.z))
  local _, nsh = BK.part_err(ST, sid_pad, ps and ps.uid or 0)
  local _, np3 = BK.part_err(ST, sid_pad, p3 and p3.uid or 0)
  if nsh and np3 then
    local over2 = dot(sub(nsh.worldPos, np3.worldPos), unit(sub(np3.worldPos, b1)))
    BK.check("reload_deck", math.abs(over2 - 1.5475) < 0.02, "...the shed still on its plate's deck (%.3f m over it)", over2)
  end
  local n1r = ST.nodeOf(sid_pad, 1)
  if n1r then
    local w = n1r.worldPos
    local Uw = unit(sub(w, b1))
    local Rr = unit(cross(BK.F, Uw))
    local eye = sub({ x = w.x - BK.F.x * 16 + Rr.x * 8 + Uw.x * 6, y = w.y - BK.F.y * 16 + Rr.y * 8 + Uw.y * 6, z = w.z - BK.F.z * 16 + Rr.z * 8 + Uw.z * 6 }, b1)
    VP.cam_fixed(eye, sub(w, b1))
    wait(1.5)
    BK.shot("19_after_reload5", false)
    VP.cam_off()
  end
  BK.result()
end

-- The icon question (NOTES): camera.capture through PartIconCam, the stand
-- 2.4 km up (this build) and moved back inside the planet (step 4's place).
function BK.icon_ab()
  local cp = findScript("catalog_panel")
  local fr = find("FieldPreviewFrame")
  local cam = find("PartIconCam")
  BK.check("icon_cam", fr ~= nil and cam ~= nil and cp.iconCount() >= 3, "the icon camera and its stand (%d icons)", cp.iconCount())
  if not (fr and cam) then return end
  cp.pickPart("hab")
  wait(1.0)
  local function grab(nm)
    local done = false
    camera.capture(cam, { w = 128, h = 128 }, function(bytes, why)
      if bytes then assets.writeBytes("user://buildshots/" .. nm .. ".png", bytes); P("BK SHOT %s", nm) end
      done = true
    end)
    wait_for(function() return done end, 5, nm)
  end
  grab("icon_sky")
  local bb = home()
  local y0 = fr.y
  fr.y = -(2400 + (bb.radius or 600) * 0.5)
  wait(0.5)
  grab("icon_underground")
  fr.y = y0
  wait(0.3)
  findScript("field_builder").heldPart = nil
end
