-- ── materials probe (tools/perf/matprobe.sh; expansion X4, "Materials & items")
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam)
-- and buildkitprobe_modes.lua (BK.unlock, BK.click, BK.shot's pattern).
--   materials  HOME: the active member made the Engineer, at the Depot's
--              supply crate A; the kit open; a steel Wall's card (price), its
--              preview plate (CRATED · K ships one, what it is made of
--              off-world); K three times: three crated walls loaded into the
--              crate (price + shipping each), then a Light Fitting crated the
--              same way; the crate's panel listing them (shot).
--              THE MOON: another member made an Engineer and set down on the
--              nearest moon, a Build Kit, a crated Light Fitting and 40 kg of
--              Steel in the pack; GO TO them (the travel curtain); a supply
--              drop (a salvage container) beside them with two crated walls;
--              the kit open: the wall's card "2 crated · in reach", a floor's
--              "no crate" and its recipe with Steel 40/119 on the plate, a red
--              ghost and the reason; the wall placed out of its crate (the
--              drop down to 1, the record's paid.item), shots from two angles
--              while the moon moves; Ctrl+Z puts it back in its crate (2);
--              placed again; Deconstruct returns it (2); the cost of the kit
--              open off-world against closed.
-- `MX PASS|FAIL <check>` lines and `MX RESULT`. Pictures: save/user/matshots/.
MX = { fails = 0, passed = 0 }
function MX.check(name, okc, fmt, ...)
  P("MX %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then MX.passed = MX.passed + 1 else MX.fails = MX.fails + 1 end
  return okc
end
function MX.result() P("MX RESULT %d passed, %d failed", MX.passed, MX.fails) end
function MX.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://matshots/" .. nm .. ".png", bytes); P("MX SHOT %s", nm)
    else P("MX SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function MX.cost(tag, secs)
  wait(secs or 3)
  local ms = function(k) return perf.scriptMs and perf.scriptMs(k) or -1 end
  P("MX COST %s: field_builder %.4f ms/frame, inventory %.4f, items %.4f, catalog_panel %.4f, recipes %.4f", tag,
    ms("field_builder"), ms("inventory"), ms("items"), ms("catalog_panel"), ms("recipes"))
  return ms("field_builder")
end
-- the body the crew stands on now, and up / a forward along the ground
function MX.frame()
  local a = astro()
  local bn = space.dominant(a.x, a.y, a.z)
  local b = space.body(bn)
  local U = unit(sub(a, b))
  local pc = findScript("planet_camera")
  local f = { x = pc.fwd_x or 1, y = pc.fwd_y or 0, z = pc.fwd_z or 0 }
  local F = unit(sub(f, scl(U, dot(f, U))))
  if len(F.x, F.y, F.z) < 0.5 then F = unit(cross(U, { x = 0.3, y = 0.9, z = 0.1 })) end
  return bn, b, U, F
end
-- the ground `ahead` m in front of the crew (this frame), a world hit
function MX.ground_ahead(ahead, side)
  local a = astro()
  local _, _, U = MX.frame()
  local F = MX.F
  local Rt = unit(cross(F, U))
  local p = { x = a.x + F.x * ahead + Rt.x * (side or 0) + U.x * 6, y = a.y + F.y * ahead + Rt.y * (side or 0) + U.y * 6,
              z = a.z + F.z * ahead + Rt.z * (side or 0) + U.z * 6 }
  return raycast(p.x, p.y, p.z, -U.x, -U.y, -U.z, 40, { ignore = a })
end
function MX.aim_at(ahead, side)
  local fb = findScript("field_builder")
  MX.aimfn = function()
    local h = MX.ground_ahead(ahead, side)
    if not h then return end
    local sx, sy, _, on = camera.worldToScreen(h.x, h.y, h.z)
    if sx and on ~= false then fb.sim = fb.sim or {}; fb.sim.mouse = { sx, sy } end
  end
end
function MX.settle(n) for _ = 1, n or 30 do if MX.aimfn then MX.aimfn() end yield() end end
-- a free camera fixed off a body-relative point on body `bn`, looking at it
function MX.view(nm, bn, rel, U, F, back, side, up)
  local Rr = unit(cross(F, U))
  local eye = { x = rel.x - F.x * back + Rr.x * side + U.x * up, y = rel.y - F.y * back + Rr.y * side + U.y * up, z = rel.z - F.z * back + Rr.z * side + U.z * up }
  local tgt = { x = rel.x + U.x * 1.0, y = rel.y + U.y * 1.0, z = rel.z + U.z * 1.0 }
  -- (each frame against this frame's body: the moon moves metres a tick)
  VP.cam = function()
    local b = space.body(bn)
    if not b then return nil end
    return { x = b.x + eye.x, y = b.y + eye.y, z = b.z + eye.z }, { x = b.x + tgt.x, y = b.y + tgt.y, z = b.z + tgt.z }
  end
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(true) end
  wait(1.0)
  MX.shot(nm, false)
  VP.cam_off()
  wait(0.3)
end
function MX.moon()
  local b = home()
  local best, bd
  for _, x in ipairs(space.bodies()) do
    if x.name ~= b.name and (x.soi or -1) > 0 and x.radius > 0 and x.radius < b.radius then
      local d = len(x.x - b.x, x.y - b.y, x.z - b.z)
      if not bd or d < bd then best, bd = x, d end
    end
  end
  return best
end

function MX.run()
  wait_ready(120)
  wait(2)
  local fb, ST, co, C, V = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew"), findScript("inventory")
  local sc, R, I, sv = findScript("supply_crates"), findScript("recipes"), findScript("items"), findScript("salvage")
  if not MX.check("scene", fb and ST and co and C and V and sc and R and I and sv, "field_builder %s recipes %s items %s salvage %s",
    tostring(fb ~= nil), tostring(R ~= nil), tostring(I ~= nil), tostring(sv ~= nil)) then MX.result() return end
  if co.earn then co.earn(60000, "probe") end
  BK.unlock()
  local me = C.activeId()
  C.patch(me, { role = "engineer" })
  wait(3.5)
  -- ════ HOME: crate parts at the Depot's crate A ═══════════════════════════
  local crate
  for _, c in ipairs(sc.list()) do if c.id == 1 then crate = c end end
  wait_for(function() for _, c in ipairs(sc.list()) do if c.id == 1 and c.node then crate = c return true end end end, 20, "crate A")
  if not MX.check("crate", crate and crate.node, "the Depot's crate A stands") then MX.result() return end
  do
    local a, b = astro(), home()
    local cw = crate.node.worldPos
    local U = unit(sub(cw, b))
    local away = unit(cross(U, { x = 0.2, y = 0.3, z = 0.9 }))
    a.x, a.y, a.z = cw.x + away.x * 2.2 + U.x * 1.2, cw.y + away.y * 2.2 + U.y * 1.2, cw.z + away.z * 2.2 + U.z * 1.2
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  wait(2.5)
  tap("b"); wait(1.5)
  MX.check("open_home", fb.isOpen(), "the kit opens at home (gate %s)", tostring(fb.gate))
  local cp = findScript("catalog_panel")
  local p1, p2 = fb.cardLines("wall.steel", fb.partInfo("wall.steel"), false)
  MX.check("card_home", p1 and p1:sub(1, 1) == "$", "the steel Wall's card at home: %s / %s", tostring(p1), tostring(p2))
  cp.pickPart("wall.steel")
  wait(1.0)
  local rows = fb.plateRows("wall.steel") or {}
  local txt = {}
  for _, r in ipairs(rows) do txt[#txt + 1] = r.text end
  MX.check("plate_home", #rows >= 2 and tostring(rows[1].text):find("CRATED", 1, true) ~= nil, "the plate: %s", table.concat(txt, " | "))
  MX.cost("kit open at home, a part in hand", 3)
  MX.cost("kit open at home, a part in hand, 6 s later", 6)
  local f0 = co.balance()
  local q = findScript("base_economy").crateQuote(fb.partInfo("wall.steel"), "WALL")
  for _ = 1, 3 do tap("k"); wait(0.4) end
  -- (the nearest crate with room takes each: crate A and B stand 0.9 m apart)
  local nwall, where, kg = 0, {}, 0
  for _, c in ipairs(sc.list()) do
    local k = V.itemCount(c.cid, "part:wall.steel")
    if k > 0 then nwall = nwall + k; where[#where + 1] = string.format("%s ×%d", c.cid, k); kg = kg + V.mass(c.cid) end
  end
  MX.check("crated", nwall == 3 and math.abs((f0 - co.balance()) - 3 * q.total) < 1, "K ×3: %d crated walls (%s), %s charged (3 × %s)",
    nwall, table.concat(where, ", "), tostring(f0 - co.balance()), tostring(q.total))
  local ledger = save.get("co.ledger") or {}
  local last = ledger[#ledger] or {}
  MX.check("ledger", tostring(last.why):find("crated", 1, true) ~= nil, "the ledger: %s %s", tostring(last.amount), tostring(last.why))
  MX.check("crate_mass", math.abs(kg - 3 * I.def("part:wall.steel").kg) < 1, "the crates weigh %.1f kg for three walls of %.1f kg", kg, I.def("part:wall.steel").kg)
  cp.pickPart("lightFitting.steel"); wait(0.3)
  tap("k"); wait(0.4)
  local lc = fb.lastCrate and fb.lastCrate.cid
  MX.check("crated_light", lc and V.itemCount(lc, "part:lightFitting.steel") == 1, "a Light Fitting crated into %s", tostring(lc))
  if lc then for _, c in ipairs(sc.list()) do if c.cid == lc then crate = c end end end
  cp.pickPart("wall.steel"); wait(0.8)
  MX.shot("1_home_plate")
  -- the crate's panel: the crated parts as rows
  tap("escape"); wait(0.3); tap("escape"); wait(0.5)
  local ip = findScript("inventory_panel")
  sc.open(crate.cid)
  wait(1.2)
  MX.check("crate_panel", ip.open == true, "the crate's panel is open on %s", tostring(ip.targetId))
  MX.shot("2_crate_panel")
  ip.closePanel(); wait(0.5)
  -- ════ THE MOON ═══════════════════════════════════════════════════════════
  local m = MX.moon()
  if not MX.check("moon", m ~= nil, "the nearest moon: %s", m and m.name or "-") then MX.result() return end
  local R0 = C.roster()
  local mid
  for _, r in ipairs(R0) do if r.id ~= me and r.status ~= "dead" then mid = r.id end end
  if not mid and C.hire then C.hire(1, { free = true }); for _, r in ipairs(C.roster()) do if r.id ~= me then mid = r.id end end end
  C.patch(mid, { role = "engineer", status = "afoot", craft = false, body = m.name, x = 0, y = m.radius + 2.0, z = 0, o2 = 1.0, helmet = true })
  local pk = C.packOf(mid)
  V.addItem(pk, "buildkit", 1, { force = true })
  V.addItem(pk, "part:lightFitting.steel", 1, { force = true })
  V.add(pk, "steel", 40)
  local gm = findScript("game_manager")
  local okm, how = C.switchToMember(mid)
  MX.check("goto", okm, "GO TO the member on %s: %s", m.name, tostring(how))
  local done = wait_for(function() return gm.travel == nil and C.activeId() == mid end, 80, "the trip to the moon")
  wait(3.0)
  local a = astro()
  MX.check("arrived", done ~= nil and space.dominant(a.x, a.y, a.z) == m.name, "on %s as #%s", tostring(space.dominant(a.x, a.y, a.z)), tostring(mid))
  local bn, mb, U, F = MX.frame()
  MX.F = F
  MX.check("away", fb.awayNow(), "the kit knows it is off the home world (%s, home %s)", bn, tostring(save.get("base.body")))
  -- the supply drop: two crated walls beside them, 4 m to the left
  V.addItem("crate:mxprobe", "part:wall.steel", 2, { force = true })
  local Rt = unit(cross(F, U))
  local dp = { x = a.x - Rt.x * 4 + U.x * 2, y = a.y - Rt.y * 4 + U.y * 2, z = a.z - Rt.z * 4 + U.z * 2 }
  local did = sv.drop(bn, dp.x, dp.y, dp.z, a, { from = "crate:mxprobe", items = true, label = "Supply drop" })
  local dcid = did and sv.containerOf(did)
  MX.check("drop", dcid and V.itemCount(dcid, "part:wall.steel") == 2, "a supply drop %s with 2 crated walls", tostring(dcid))
  wait(1.5)
  tap("b"); wait(1.5)
  MX.check("open_moon", fb.isOpen(), "the kit opens on %s", bn)
  cp = findScript("catalog_panel")    -- (the column is a new node each time the kit opens)
  local st = fb.reachScan(true)
  local ord = {}
  for _, c in ipairs(st.order) do ord[#ord + 1] = c .. "=" .. tostring(st.label[c]) end
  MX.check("reach", #st.order >= 2 and st.order[#st.order] == C.packOf(mid), "in reach, nearest first, the pack last: %s", table.concat(ord, ", "))
  local w1, w2 = fb.cardLines("wall.steel", fb.partInfo("wall.steel"), false)
  MX.check("card_crated", w1 == "2 crated", "the Wall's card: %s / %s", tostring(w1), tostring(w2))
  local l1, l2 = fb.cardLines("lightFitting.steel", fb.partInfo("lightFitting.steel"), false)
  MX.check("card_pack", l1 == "1 crated" and tostring(l2):find("pack", 1, true), "the Light Fitting's card: %s / %s", tostring(l1), tostring(l2))
  local fl1, fl2 = fb.cardLines("floor.steel", fb.partInfo("floor.steel"), false)
  MX.check("card_none", fl1 == "no crate" and tostring(fl2):find("Steel", 1, true), "a Floor's card: %s / %s", tostring(fl1), tostring(fl2))
  cp.pickPart("floor.steel")
  MX.aim_at(6, 0)
  MX.settle(40)
  local frows = fb.plateRows("floor.steel") or {}
  local ft = {}
  for _, r in ipairs(frows) do ft[#ft + 1] = r.text end
  MX.check("plate_moon", table.concat(ft, " | "):find("Steel 40", 1, true) ~= nil, "the Floor's plate: %s", table.concat(ft, " | "))
  MX.check("red_none", fb.req and fb.req.bad and tostring(fb.req.bad):find("crated", 1, true), "a Floor with none in reach: red, \"%s\"", fb.req and tostring(fb.req.bad) or "no req")
  MX.shot("3_moon_none")
  cp.pickPart("wall.steel")
  MX.settle(40)
  MX.check("ghost_ok", fb.req and not fb.req.bad and fb.req.quote and fb.req.quote.mode == "item", "the Wall's ghost: valid, from a crate (%s)",
    fb.req and tostring(fb.req.bad or (fb.req.quote and fb.req.quote.mode)) or "no req")
  MX.shot("4_moon_ghost")
  local cost_open = MX.cost("kit open off-world, a ghost up", 3)
  MX.cost("kit open off-world, a ghost up, 6 s later (icons taken)", 6)
  local f1 = co.balance()
  MX.aimfn()
  BK.click(false)
  wait(0.8)
  local lp = fb.lastPlace
  local part = lp and ST.getPart(lp.sid, lp.uid)
  MX.check("placed", lp and part and part.paid and part.paid.item == dcid and V.itemCount(dcid, "part:wall.steel") == 1,
    "the Wall placed out of its crate: paid.item %s, the drop holds %d, %s spent (footing only)", tostring(part and part.paid and part.paid.item),
    V.itemCount(dcid, "part:wall.steel"), tostring(f1 - co.balance()))
  MX.check("rec_moon", lp and ST.get(lp.sid) and ST.get(lp.sid).b == bn, "struct.%s on %s", tostring(lp and lp.sid), tostring(lp and ST.get(lp.sid) and ST.get(lp.sid).b))
  wait(1.0)
  -- two angles, the moon moving under them
  fb.dropHeld()      -- (the wall stays in hand after a placement: no ghost in the pictures)
  wait(0.3)
  local rec = lp and ST.get(lp.sid)
  if rec then
    local mbb = space.body(bn)
    local nodes = ST.nodesOf(lp.sid)
    local w = nodes and nodes[1] and nodes[1].worldPos
    local rel = w and { x = w.x - mbb.x, y = w.y - mbb.y, z = w.z - mbb.z } or { x = rec.x, y = rec.y, z = rec.z }
    local Ur = unit(rel)
    MX.view("5_moon_wall_a", bn, rel, Ur, F, 7, 3, 2.5)
    MX.view("6_moon_wall_b", bn, rel, Ur, F, -6, -4, 3.5)
    local p0 = space.body(bn)
    wait(1.0)
    local p1b = space.body(bn)
    local w2n = nodes and nodes[1] and nodes[1].valid and nodes[1].worldPos
    local err = w2n and len(w2n.x - p1b.x - rel.x, w2n.y - p1b.y - rel.y, w2n.z - p1b.z - rel.z) or -1
    MX.check("rides", err >= 0 and err < 0.05, "the wall rides the moon: %.4f m off its spot after the moon moved %.1f m", err,
      len(p1b.x - p0.x, p1b.y - p0.y, p1b.z - p0.z))
  end
  -- undo: back in its crate
  key_down("ctrl"); tap("z"); key_up("ctrl")
  wait(0.6)
  MX.check("undo", lp and ST.getPart(lp.sid, lp.uid) == nil and V.itemCount(dcid, "part:wall.steel") == 2, "Ctrl+Z: the wall back in its crate (the drop holds %d)",
    V.itemCount(dcid, "part:wall.steel"))
  if not fb.isOpen() then tap("b"); wait(1.5) end
  cp = findScript("catalog_panel")
  P("MX after the views: kit open %s, in hand %s", tostring(fb.isOpen()), tostring(fb.heldPart))
  cp.pickPart("wall.steel")
  MX.aim_at(6, 0)
  MX.settle(40)
  P("MX second wall: req %s", fb.req and tostring(fb.req.bad or "valid") or "none")
  BK.click(false)
  wait(0.8)
  local lp2 = fb.lastPlace
  MX.check("placed2", lp2 and ST.getPart(lp2.sid, lp2.uid) and V.itemCount(dcid, "part:wall.steel") == 1, "placed again (the drop holds %d)", V.itemCount(dcid, "part:wall.steel"))
  local amt, w = fb.deconstruct(lp2.sid, lp2.uid)
  wait(0.5)
  MX.check("decon", amt ~= nil and V.itemCount(dcid, "part:wall.steel") == 2, "Deconstruct: %s, the crate back in the drop (%d)", tostring(w and type(w) == "string" and w or "ok"),
    V.itemCount(dcid, "part:wall.steel"))
  tap("escape"); wait(0.3); tap("escape"); wait(0.8)
  local cost_closed = MX.cost("kit closed off-world", 3)
  MX.check("cost", cost_closed < 0.2, "the kit closed costs %.4f ms a frame (open with a ghost %.4f)", cost_closed, cost_open)
  -- tidy: the drop's crates into the pack's way (nothing left lying in the save)
  MX.result()
end
