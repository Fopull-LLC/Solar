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
        if n >= 5 and not wet then
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
      local foot = { x = w.x - U.x * rq.def.seat, y = w.y - U.y * rq.def.seat, z = w.z - U.z * rq.def.seat }
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
  -- placed again (Shift keeps one in hand), then the shed beside it
  cp.pickPart("padPlate")
  BK.aim_at(9, 0)
  for _ = 1, 20 do BK.aimfn(); yield() end
  BK.click(true)
  wait(0.5)
  local sid_pad = fb.lastPlace and fb.lastPlace.sid
  BK.check("keep", fb.heldPart == "padPlate", "Shift+LMB keeps a Pad Plate in hand")
  -- a red ghost: over the slab just placed
  for _ = 1, 30 do BK.aimfn(); yield() end
  BK.check("red", fb.req and fb.req.bad ~= nil, "a second slab on the first: red, \"%s\"", fb.req and tostring(fb.req.bad) or "no req")
  BK.shot("4_red_ghost")
  cp.pickPart("shed")
  BK.aim_at(8.5, 5.5)
  for _ = 1, 30 do BK.aimfn(); yield() end
  BK.check("shed_ghost", fb.req and not fb.req.bad, "the shed's ghost beside the slab: %s", fb.req and tostring(fb.req.bad) or "valid")
  BK.shot("5_shed_ghost")
  local f2 = co.balance()
  BK.click(false)
  wait(1.0)
  local sid_shed = fb.lastPlace and fb.lastPlace.sid
  BK.check("shed", sid_shed and sid_shed ~= sid_pad and f2 - co.balance() == 1590, "the shed placed: %s ($1,400 + $190 shipping)", tostring(f2 - co.balance()))
  -- close the kit, look from two sides
  tap("escape"); wait(0.3)
  BK.check("close", not fb.isOpen(), "Esc closes the kit (after the hand is empty)")
  wait(0.5)
  local _, pn = BK.struct_err(ST, sid_pad)
  local _, sn = BK.struct_err(ST, sid_shed)
  if pn and sn then
    local b = home()
    local mid = { x = (pn.worldPos.x + sn.worldPos.x) / 2 - b.x, y = (pn.worldPos.y + sn.worldPos.y) / 2 - b.y, z = (pn.worldPos.z + sn.worldPos.z) / 2 - b.z }
    local U = unit(mid)
    local F, Rt = BK.F, unit(cross(BK.F, U))
    local function view(nm, fwd, side, hgt)
      local eye = { x = mid.x + F.x * fwd + Rt.x * side + U.x * hgt, y = mid.y + F.y * fwd + Rt.y * side + U.y * hgt, z = mid.z + F.z * fwd + Rt.z * side + U.z * hgt }
      VP.cam_fixed(eye, { x = mid.x + U.x, y = mid.y + U.y, z = mid.z + U.z })
      wait(1.2)
      BK.shot(nm, false)
    end
    view("6_built_a", 12, -8, 4)
    view("7_built_b", -10, 9, 6)
    VP.cam_off()
  end
  -- the idle cost of placed structures (the kit closed)
  wait(1)
  local f3 = FRAME
  wait(3)
  P("BK COST idle: structures %.4f ms/frame, field_builder %.4f ms (%d frames, 2 structures)",
    perf.scriptMs and perf.scriptMs("structures") or -1, perf.scriptMs and perf.scriptMs("field_builder") or -1, FRAME - f3)
  BK.cost_idle = perf.scriptMs and perf.scriptMs("structures") or -1
  -- SAVE AND RELOAD
  local recs = {}
  for _, id in ipairs({ sid_pad, sid_shed }) do local r = ST.get(id); recs[id] = r and { x = r.x, y = r.y, z = r.z } end
  local b0 = home()
  local bp0 = { x = b0.x, y = b0.y, z = b0.z }
  local w0 = pn and { x = pn.worldPos.x, y = pn.worldPos.y, z = pn.worldPos.z }
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(3)
  ST = findScript("structures")
  local ok_all, worst2 = true, 0
  for id, r0 in pairs(recs) do
    local r = ST and ST.get(id)
    local e = r and BK.struct_err(ST, id)
    if not (r and e and r.x == r0.x and r.y == r0.y and r.z == r0.z) then ok_all = false end
    worst2 = math.max(worst2, e or 99)
  end
  local b1 = home()
  local moved2 = len(b1.x - bp0.x, b1.y - bp0.y, b1.z - bp0.z)
  local _, pn2 = BK.struct_err(ST, sid_pad)
  local wmoved = (pn2 and w0) and len(pn2.worldPos.x - w0.x, pn2.worldPos.y - w0.y, pn2.worldPos.z - w0.z) or -1
  BK.check("reload", ok_all and worst2 < 0.01 and ST.count() == 2,
    "after a reload both stand on their records (worst %.4f m) on the planet that moved %.0f m (the slab's world point moved %.0f m with it)",
    worst2, moved2, wmoved)
  -- their colliders: a ray down onto the shed's roof
  local _, sn2 = BK.struct_err(ST, sid_shed)
  if sn2 then
    local w = sn2.worldPos
    local U = unit(sub(w, b1))
    local h = raycast(w.x + U.x * 6, w.y + U.y * 6, w.z + U.z * 6, -U.x, -U.y, -U.z, 10, { ignore = astro() })
    local top = h and len(h.x - w.x, h.y - w.y, h.z - w.z)
    BK.check("collider", h and h.node and top and math.abs(top - 1.30) < 0.15,
      "a ray from above stops on the shed's roof (%.2f m over its origin, node %s)", top or -1, h and h.node and h.node.name or "none")
  end
  -- from the walker's own view, after the reload
  local a2 = astro()
  if a2 and pn2 then
    local w = pn2.worldPos
    local U = unit(sub(w, b1))
    local Rt = unit(cross(BK.F, U))
    local eye = sub({ x = w.x - BK.F.x * 14 + Rt.x * 6 + U.x * 5, y = w.y - BK.F.y * 14 + Rt.y * 6 + U.y * 5, z = w.z - BK.F.z * 14 + Rt.z * 6 + U.z * 5 }, b1)
    VP.cam_fixed(eye, sub(w, b1))
    wait(1.5)
    BK.shot("8_after_reload", false)
    VP.cam_off()
  end
  BK.result()
end
