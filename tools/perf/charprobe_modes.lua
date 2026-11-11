-- ── kit probe, mode "character" (sandbox plan S4: bases get character) ───────
-- Spliced after kitprobe_modes.lua (the KIT helpers) by tools/perf/kitprobe.sh.
-- On flat ground 150+ m out from the spaceport:
--   1. a 4 x 4 m hab built through the kit's own path (rays at the faces,
--      field_builder.placeAt): four slabs, a door wall, two window walls, five
--      walls, a roof of four floors, a light and its switch; a tower beside it
--      founds the base "Kestrel Flats" (put in its record: the spaceport's
--      Tracking Station is closer than the 1 km rule allows);
--   2. painted with the paint tool's own functions (a real ray, hitPick: the
--      face it lands on, paintParts): every wall hull white outside (Ctrl: all
--      of a kind), the inside faces bone, the door wall signal orange, the roof
--      gunmetal, one window wall's inside hab green; Ctrl+Z / redo once;
--   3. signs and decals: the base's name on a board along its side (kit_live
--      draws it), a plate by the door with words of its own, stencilled words
--      and the agency emblem on the back, a hazard stripe at the foot of the
--      front, a door number, grime down the back and a rust run, scuffs on the
--      floor inside;
--   4. props inside: a bunk, a table with a monitor and a desk lamp, two
--      chairs, shelving, a crate with a small one on it, a potted plant, a
--      work light, a fire extinguisher and a tool rack on the walls, a pipe
--      run and a cable run;
--   5. pictures (outside front and corner, inside two ways, the sign close);
--   6. saved as a blueprint (the file, the code back identical) and placed
--      again beside it: one bill, every piece, its paint and words;
--   7. a 500-piece base + 100 props + 20 decals in view (copies of it):
--      perf.counts draws / unbatched (by cause) / lights, script ms; the same
--      view with every piece's paint stripped: tint must not split a draw;
--   8. save and reload: the paint, the words, the library.
-- `BK PASS|FAIL <check>`, `CHAR …` lines, `BK RESULT character: PASS/FAIL`.
CH = {}

local function put(fb, rec, id, a, b, tag, yawOff)
  fb.yawOffset = yawOff or 0
  local uid, p = KIT.put(fb, rec, id, a, b, tag)
  fb.yawOffset = 0
  return uid, p
end
-- paint through the tool's own functions: a real ray, the piece and face it lands on
local function paint_ray(fb, rec, a, b, key, mode)
  local h = KIT.ray(rec, a, b)
  if not h then P("CHAR paint ray found nothing") return nil end
  local r2, part, nx, _, nz = fb.hitPick(h)
  if not part then P("CHAR paint ray: no piece") return nil end
  local KP = findScript("kit_paint")
  local def = findScript("parts_base").partInfo(part.id)
  local face = (def.faces2 and nx) and KP.faceOf(part.yaw or 0, nx, nz) or "both"
  local uids = { part.uid }
  if mode == "kind" then
    uids = {}
    for _, p in ipairs(r2.bp) do local d = findScript("parts_base").partInfo(p.id); if d and d.piece == def.piece then uids[#uids + 1] = p.uid end end
  end
  local n, why = fb.paintParts(r2.id, uids, key, face)
  P("CHAR paint %s on the %s (%s face, %s): %s", key, def.label, face, mode or "one", tostring(n or why))
  return n, face, part
end

function CH.build(fb, ST, rec, sid)
  local T = 0.2
  for _, s in ipairs({ { 2, 0 }, { 0, 2 }, { 2, 2 } }) do
    fb.hold("slab2.concrete")
    yield()
    local h = KIT.ray(rec, { s[1], 4, s[2] }, { s[1], -4, s[2] })
    if h then fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node) end
    rec = ST.get(sid)
  end
  local W = {
    { "doorWall.steel", { 0, 3, 2.7 }, "front door" }, { "windowWall.steel", { 2, 3, 2.7 }, "front window" },
    { "wall.steel", { 0, 3, -0.7 }, "back" }, { "wall.steel", { 2, 3, -0.7 }, "back" },
    { "windowWall.steel", { -0.7, 3, 0 }, "left window" }, { "wall.steel", { -0.7, 3, 2 }, "left" },
    { "wall.steel", { 2.7, 3, 0 }, "right" }, { "wall.steel", { 2.7, 3, 2 }, "right" },
  }
  local U = {}
  for _, w in ipairs(W) do
    local a = w[2]
    U[#U + 1] = KIT.put(fb, rec, w[1], a, { a[1], -2, a[3] }, w[3])
  end
  KIT.put(fb, rec, "floor.steel", { 0, 5, 3 }, { 0, 1, 3 }, "roof")
  KIT.put(fb, rec, "floor.steel", { 2, 5, 3 }, { 2, 1, 3 }, "roof")
  KIT.put(fb, rec, "floor.steel", { 0, 2.5, -4 }, { 0, 2.5, 4 }, "roof")
  KIT.put(fb, rec, "floor.steel", { 2, 2.5, -4 }, { 2, 2.5, 4 }, "roof")
  local light = KIT.put(fb, rec, "lightFitting.steel", { 1.0, 1.2, 1.0 }, { 1.0, 4, 1.0 }, "light")
  KIT.put(fb, rec, "switchPlate.steel", { 0.25, 1.45, 1.5 }, { 0.25, 1.45, 4 }, "switch")
  return U, light
end

-- The sun's direction in a structure's frame (x, y, z): pictures are taken
-- from its side, so the paint is seen in light, not against it.
function CH.sun(rec)
  local E = findScript("electronics")
  local b = home()
  local sun = E and E.sunOf and E.sunOf(b.x, b.y, b.z, space.bodies() or {})
  if not sun then return 0, 0.7, 0.7 end
  local d = unit(sub(sun, b))
  local fr = findScript("kit_snap").frameOf(rec)
  return dot(d, fr.R), dot(d, fr.U), dot(d, fr.F)
end
-- an eye `r` m out from (cx, cz) toward the sun, turned `turn` rad round, `h` m up
function CH.sunEye(rec, cx, cz, r, h, turn)
  local sx, sy, sz = CH.sun(rec)
  local a = math.atan2(sx, sz) + (turn or 0)
  return { cx + math.sin(a) * r, h, cz + math.cos(a) * r }
end

-- THE PALETTE BOARD: a row of 1 m steel walls on slabs behind the hab, one
-- per swatch and the last bare, pictured from the front (how each enamel
-- sits on the cladding's own wear, in this world's light).
function CH.palette(fb, ST, rec)
  local KP = findScript("kit_paint")
  local psid
  for k = 0, 6 do
    fb.hold("slab2.concrete")
    yield()
    local prec = psid and ST.get(psid)
    local h = prec and KIT.ray(prec, { 2 * k, 4, 0 }, { 2 * k, -4, 0 }) or KIT.ray(rec, { -1, 4, -7 }, { -1, -4, -7 })
    if h then
      local s2 = fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node)
      psid = psid or s2
    end
  end
  if not psid then P("CHAR palette: no ground") return nil end
  local prec = ST.get(psid)
  local keys = KP.keys()
  -- (the row faces whichever way along its Z the sun stands)
  local _, _, sz = CH.sun(prec)
  local side = sz >= 0 and 1 or -1
  local n = 0
  for i = 0, 12 do
    local p = { body = prec.b, mode = "face", sid = psid, lx = -0.5 + i, ly = 0.2, lz = side, yaw = side > 0 and 0 or math.pi, pitch = 0, roll = 0 }
    local s2, why, q, uid = fb.place(psid, "wall12.steel", p, "money")
    if s2 and keys[i + 1] then fb.paintParts(psid, { uid }, keys[i + 1], "both"); n = n + 1 end
  end
  fb.dropHeld()
  P("CHAR palette board: %d walls painted (structure %s), the 13th bare", n, tostring(psid))
  wait(1.5)
  prec = ST.get(psid)
  KIT.view("c0_palette", prec, { 6.0, 1.7, side * 6.5 }, { 6.0, 1.2, side })
  return psid
end

function CH.run()
  BK.tag = "character"
  wait_ready(120)
  wait(2)
  local fb, ST, co, C = findScript("field_builder"), findScript("structures"), findScript("company"), findScript("crew")
  local KP, BPs, KL, BS = findScript("kit_paint"), findScript("blueprints"), findScript("kit_live"), findScript("bases")
  if not BK.check("scene", fb and ST and KP and BPs and KL and BS and fb.paintParts and fb.hitPick, "kit_paint, blueprints, kit_live, bases in the scene") then BK.result() return end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local Uu = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(Uu, dot(f, Uu))))
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "B opens the kit")
  local cp = findScript("catalog_panel")
  for _, tab in ipairs({ "PAINT", "PROPS", "DECALS", "BLUEPRINTS" }) do
    local l = cp and cp.listFor and cp.listFor(fb, tab, "") or {}
    P("CHAR tab %s: %d cards", tab, #l)
    BK.check("tab_" .. tab, #l >= 4, "the %s tab lists its cards (%d)", tab, #l)
  end
  local funds0 = co.balance()
  -- ── 1. the hab ──
  local sid, why
  for _, o in ipairs({ { 7, 0 }, { 8, -2 }, { 9, 2 }, { 6, -4 }, { 10, 0 }, { 8, 3 } }) do
    fb.hold("slab2.concrete")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  if not BK.check("slab1", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  local walls, light = CH.build(fb, ST, rec, sid)
  rec = ST.get(sid)
  BK.check("hab", #rec.bp >= 18, "a 4 x 4 m hab of %d pieces", #rec.bp)
  -- the base: a tower beside it, named
  do
    local up = ST.addPart(sid, { id = "tower", x = 6.5, y = 0, z = -1.5, yaw = 0 })
    ST.spawnNow(sid)
    local BT = findScript("base_tower")
    wait(2.5)
    local b = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
    if b then BS.rename(b.id, "Kestrel Flats") end
    if BT and BT.prompting and BT.prompting() and BT.cancelName then pcall(BT.closeName or BT.cancelName) end
    b = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
    BK.check("base", b and b.n == "Kestrel Flats", "the base is %s (tower uid %s)", b and tostring(b.n) or "none", tostring(up))
  end
  -- the crew in front of the hab, 8 m out (props face them)
  KIT.tp(rec, 1, 9)
  -- ── 2. paint ──
  local KS = findScript("kit_snap")
  paint_ray(fb, rec, { 2.0, 1.2, 6 }, { 2.0, 1.2, 0 }, "hull", nil)                -- the front window wall, outside
  paint_ray(fb, rec, { 1.6, 1.0, -4 }, { 1.6, 1.0, 0 }, "hull", "kind")            -- every plain wall, outside (Ctrl)
  paint_ray(fb, rec, { -3.5, 0.6, 0 }, { 0, 0.6, 0 }, "hull", nil)                -- the left window wall
  paint_ray(fb, rec, { 0.6, 1.2, 6 }, { 0.6, 1.2, 0 }, "orange", nil)              -- the door wall, signal orange
  -- (each panel's middle: a ray down a joint lands on a wall's end)
  for _, a in ipairs({ { { 0, 1.2, 1 }, { 0, 1.2, -3 } }, { { 2, 1.2, 1 }, { 2, 1.2, -3 } }, { { 0.5, 1.2, 1 }, { 0.5, 1.2, 5 } },
                       { { 2, 0.6, 1 }, { 2, 0.6, 5 } }, { { 1, 0.6, 0 }, { -3, 0.6, 0 } }, { { 1, 1.2, 2 }, { -3, 1.2, 2 } },
                       { { 1, 1.2, 0 }, { 5, 1.2, 0 } }, { { 1, 1.2, 2 }, { 5, 1.2, 2 } } }) do
    paint_ray(fb, rec, a[1], a[2], "hull", nil)                                     -- the inside faces, hull white
  end
  paint_ray(fb, rec, { 1, 0.6, 0.0 }, { -3, 0.6, 0.0 }, "habgreen", nil)          -- the left window wall's inside, hab green
  paint_ray(fb, rec, { 0, 5, 0 }, { 0, 1, 0 }, "gunmetal", "kind")                -- the roof
  rec = ST.get(sid)
  local np, nin = 0, 0
  for _, p in ipairs(rec.bp) do if p.paint then np = np + 1 end if p.paintIn then nin = nin + 1 end end
  BK.check("painted", np >= 12 and nin >= 6, "painted: %d pieces outside, %d insides", np, nin)
  do
    local dw = ST.getPart(sid, walls[1])
    local n1 = ST.nodeOf(sid, walls[1])
    -- (meshfold 11-11: a wall's inside is its Mesh's "<mat>In" slots, not a MeshIn child)
    local m1 = n1 and n1:getChild("Mesh")
    local KPp = findScript("kit_paint")
    local sl = m1 and KPp and KPp.slotsOf and KPp.slotsOf(m1, findScript("parts_base").partInfo(dw.id))
    BK.check("faces", dw and dw.paint == "orange" and dw.paintIn == "hull" and sl, "the door wall: %s outside, %s inside (its inside slots %s)",
      tostring(dw and dw.paint), tostring(dw and dw.paintIn), sl and table.concat(sl.inn, ",") or "missing")
    local a1 = fb.undo()
    local p1 = ST.getPart(sid, rec.bp[#rec.bp].uid)
    fb.redo()
    BK.check("paint_undo", a1 ~= nil, "Ctrl+Z takes the last coat back (%s), redo paints it again", tostring(a1))
  end
  -- ── 3. signs and decals ──
  local sgB = put(fb, rec, "signBoard.steel", { 4.2, 1.85, 0.9 }, { 2.0, 1.85, 0.9 }, "the base's name board", 0)
  local sgP = put(fb, rec, "signPlate.steel", { 0.55, 1.45, 5 }, { 0.55, 1.45, 0 }, "a plate by the door", 0)
  if sgP then KL.setSignWords(sid, sgP, "HAB 1 · CREW 2") end
  local sgS = put(fb, rec, "signStencil.film", { 0.9, 1.85, -4 }, { 0.9, 1.85, 0 }, "stencilled words on the back", 0)
  if sgS then KL.setSignWords(sid, sgS, "WATER  >") end
  put(fb, rec, "decalEmblem.film", { 2.0, 1.2, -4 }, { 2.0, 1.2, 0 }, "the agency emblem on the back", 0)
  put(fb, rec, "decalHaz.film", { 0.9, 0.45, 5 }, { 0.9, 0.45, 0 }, "a hazard stripe at the foot of the front", 0)
  put(fb, rec, "decalNum1.film", { 0.5, 1.95, 5 }, { 0.5, 1.95, 0 }, "the door's number", 0)
  put(fb, rec, "grimeStreaks.film", { 0.0, 1.2, -4 }, { 0.0, 1.2, 0 }, "grime down the back", 0)
  put(fb, rec, "grimeLeak.film", { 4.2, 1.6, 2.6 }, { 2.0, 1.6, 2.6 }, "a rust run on the side", 0)
  put(fb, rec, "decalPell.film", { 4.2, 0.9, 0.5 }, { 2.0, 0.9, 0.5 }, "the builder's mark", 0)
  put(fb, rec, "grimeScuff.film", { 0.6, 1.0, 1.6 }, { 0.6, -1, 1.6 }, "scuffs on the floor inside", 0)
  wait(2.5)
  local wB = sgB and KL.signText(sid, sgB)
  BK.check("sign_base", wB == "KESTREL FLATS", "the board shows the base's name: %s", tostring(wB))
  BK.check("sign_words", sgP and KL.signText(sid, sgP) == "HAB 1 · CREW 2", "the plate shows its own words: %s", tostring(sgP and KL.signText(sid, sgP)))
  -- a rename reaches the board
  do
    local b = BS.baseAt(rec.b, rec.x, rec.y, rec.z)
    BS.rename(b.id, "Kestrel Flats")
  end
  -- ── 4. props inside ──
  local props = {
    { "bunk.steel", { 0.1, 2.2, -0.35 }, 0, "a bunk" },
    { "table.steel", { 1.75, 2.2, 1.55 }, math.pi / 2, "a table" },
    { "chair.steel", { 0.95, 2.2, 1.55 }, math.pi / 2, "a chair" },
    { "chair.steel", { 2.55, 2.2, 1.55 }, -math.pi / 2, "a chair" },
    { "shelf.steel", { 2.6, 2.2, 0.0 }, -math.pi / 2, "shelving" },
    { "crate.steel", { -0.25, 2.2, 1.6 }, 0, "a crate" },
    { "plant.steel", { -0.6, 2.2, 0.65 }, 0, "a plant" },
    { "lampFloor.steel", { 2.55, 2.2, 2.55 }, math.pi * 0.75, "a work light" },
  }
  local placed = 0
  for _, pr in ipairs(props) do
    local a = pr[2]
    local u = put(fb, rec, pr[1], a, { a[1], -1, a[3] }, pr[4], pr[3])
    if u then placed = placed + 1 end
  end
  -- on top of the table, the crate; on the walls
  if put(fb, rec, "monitor.steel", { 1.75, 2.2, 1.85 }, { 1.75, 0, 1.85 }, "a monitor on the table", math.pi / 2) then placed = placed + 1 end
  if put(fb, rec, "lampDesk.steel", { 1.75, 2.2, 1.0 }, { 1.75, 0, 1.0 }, "a desk lamp", 0) then placed = placed + 1 end
  if put(fb, rec, "crateS.steel", { -0.25, 2.3, 1.6 }, { -0.25, 0, 1.6 }, "a small crate on the crate", 0.3) then placed = placed + 1 end
  if put(fb, rec, "coffee.steel", { 2.0, 2.2, 1.95 }, { 2.0, 0, 1.95 }, "a coffee maker", 0) then placed = placed + 1 end
  if put(fb, rec, "extinguisher.steel", { 0.6, 1.0, 1.5 }, { 0.6, 1.0, 4 }, "a fire extinguisher", 0) then placed = placed + 1 end
  if put(fb, rec, "toolRack.steel", { 1.5, 1.6, 1.1 }, { 4, 1.6, 1.1 }, "a tool rack", 0) then placed = placed + 1 end
  if put(fb, rec, "pipeRun.steel", { 0.9, 2.0, 1.0 }, { 0.9, 2.0, -3 }, "a pipe run", 0) then placed = placed + 1 end
  if put(fb, rec, "cableRun.steel", { 1.0, 1.5, 0.25 }, { 1.0, 4, 0.25 }, "a cable run under the roof", 0) then placed = placed + 1 end
  fb.dropHeld()
  BK.check("props", placed >= 14, "%d props inside", placed)
  rec = ST.get(sid)
  local nprops, nfilm = 0, 0
  for _, p in ipairs(rec.bp) do
    local d = findScript("parts_base").partInfo(p.id)
    if d and d.section == "PROPS" then nprops = nprops + 1 end
    if d and d.film then nfilm = nfilm + 1 end
  end
  P("CHAR the hab: %d pieces, %d props, %d films · $%d spent", #rec.bp, nprops, nfilm, funds0 - co.balance())
  wait(3)
  -- ── 5. pictures (the forest's flora off for them: the hab is what is looked at) ──
  KIT.close(fb); wait(1.0)
  local FL = findScript("flora_field")
  local fl0 = FL and FL.params and FL.params.enabled
  if FL and FL.params then FL.params.enabled = 0 end
  wait(1.5)
  CH.palette(fb, ST, rec)
  KIT.view("c1_hab_front", rec, { -3.5, 2.6, 8.5 }, { 1, 1.2, 1 })
  KIT.view("c2_hab_sunside", rec, CH.sunEye(rec, 1, 1, 8.5, 3.0, 0.5), { 1, 1.2, 1 })
  KIT.view("c2_hab_sunside2", rec, CH.sunEye(rec, 1, 1, 8.5, 3.0, -0.5), { 1, 1.2, 1 })
  KIT.view("c3_sign_close", rec, { 6.0, 1.9, 3.0 }, { 3.1, 1.7, 0.8 })
  KIT.view("c4_inside", rec, { 0.35, 1.65, 2.55 }, { 1.8, 0.9, -0.6 })
  KIT.view("c5_inside_back", rec, { 1.35, 1.85, -0.6 }, { -0.2, 0.9, 2.6 })
  KIT.cost("character hab, idle", 3)
  -- (the flora stays off for the rest: the copies' pictures and the base's numbers are the kit's)
  -- ── 6. a blueprint, and a copy placed ──
  tap("b"); wait(1.5)
  local ok = fb.saveBlueprint(sid, nil, "Kestrel Hab")
  if BPs.prompting() then BPs.closePrompt() end
  local lb = fb.lastBlueprint
  local onDisk = lb and assets.readJson(lb.path)
  local back = lb and BPs.decode(lb.code)
  local bp0 = lb and BPs.get(lb.slug)
  local nkit = 0
  for _, p in ipairs(rec.bp) do local d = findScript("parts_base").partInfo(p.id); if d and d.kit then nkit = nkit + 1 end end
  BK.check("bp_saved", ok and lb and onDisk and back and bp0 and BPs.same(bp0, back) and back.n == nkit,
    "saved as a blueprint: %s (%s pieces, a %d-character code that decodes to the same build)", lb and lb.path or "-", lb and lb.n or "-", lb and #lb.code or -1)
  if lb then P("CHAR code %s", lb.code:sub(1, 120) .. "…") end
  local copySid
  if lb then
    fb.hold("bp:" .. lb.slug)
    yield()
    local g = KIT.ray(rec, { 1, 6, 14 }, { 1, -6, 14 })
    local p = g and fb.pose(g)
    local r = p and fb.validity(fb.heldPart, p)
    if p and r then
      p.base, p.plan = r.base, r.plan
      local f0 = co.balance()
      local bill = fb.clipBill(fb.clip)
      fb.paste_click(p)
      local lp = fb.lastPaste
      copySid = lp and lp.sid
      BK.check("bp_placed", lp and lp.placed == lb.n and lp.skipped == 0 and math.abs((f0 - co.balance()) - bill.total) <= 1,
        "the copy placed beside it: %d of %d pieces, one bill %s (paid %s)%s", lp and lp.placed or -1, lb.n, tostring(bill.total), tostring(f0 - co.balance()),
        lp and #(lp.why or {}) > 0 and (" · " .. table.concat(lp.why, "; ")) or "")
    else
      BK.check("bp_placed", false, "no ground for the copy (%s)", r and tostring(r.bad) or "no pose")
    end
    fb.dropHeld()
  end
  KIT.close(fb); wait(2)
  KIT.view("c6_hab_and_copy", rec, { -6.0, 5.0, 24.0 }, { 1.5, 1.0, 7.5 })
  -- ── 7. 500 pieces + 100 props + 20 decals in view ──
  -- (copies of the hab's pieces in a grid ahead of the crew, each its own
  -- structure: the structure first until there are 500, the props until 100,
  -- the decals and signs until 20; measured against the same view with none)
  do
    rec = ST.get(sid)
    local PBs = findScript("parts_base")
    local function cat(p)
      local d = PBs.partInfo(p.id)
      if not (d and d.kit) then return nil end
      if d.section == "PROPS" then return "p" end
      if d.section == "DECALS" then return "d" end
      return "s"
    end
    local per = { s = 0, p = 0, d = 0 }
    for _, p in ipairs(rec.bp) do local c = cat(p); if c then per[c] = per[c] + 1 end end
    local want = { s = 500, p = 100, d = 20 }
    local copies = math.max(1, math.ceil(want.s / math.max(1, per.s)))
    local U = spot.dir
    local Rt = cross(spot.t, U)
    local eye = { x = U.x * (spot.r + 16) + spot.t.x * 18, y = U.y * (spot.r + 16) + spot.t.y * 18, z = U.z * (spot.r + 16) + spot.t.z * 18 }
    local tgt = { x = U.x * spot.r + spot.t.x * 55, y = U.y * spot.r + spot.t.y * 55, z = U.z * spot.r + spot.t.z * 55 }
    local function measure(tag)
      VP.cam_fixed(eye, tgt)
      wait(2)
      sc_begin(tag); wait(5); sc_end(tag)
      local c = perf.counts()
      local ub = {}
      for k2, v in pairs(c.unbatchedBy or {}) do ub[#ub + 1] = k2 .. "=" .. tostring(v) end
      P("CHAR PERF %s: nodes %d instances %d draws %d unbatched %d (%s) lights %s dropped %s · structures %.4f, kit_live %.4f, kit_paint %.4f, struct_live %.4f, field_builder %.4f ms/frame",
        tag, c.nodes or -1, c.instances or -1, c.draws or -1, c.unbatched or -1, table.concat(ub, " "), tostring(c.lights), tostring(c.lightsDropped),
        perf.scriptMs("structures") or -1, perf.scriptMs("kit_live") or -1, perf.scriptMs("kit_paint") or -1, perf.scriptMs("struct_live") or -1, perf.scriptMs("field_builder") or -1)
      VP.cam_off()
      return c
    end
    local c0 = measure("char_none")
    spawnBudget(4)
    local ids, got = {}, { s = 0, p = 0, d = 0 }
    for k = 1, copies do
      local i, j = (k - 1) % 5, math.floor((k - 1) / 5)
      local o = { x = U.x * spot.r + spot.t.x * (40 + j * 9) + Rt.x * ((i - 2) * 9),
                  y = U.y * spot.r + spot.t.y * (40 + j * 9) + Rt.y * ((i - 2) * 9),
                  z = U.z * spot.r + spot.t.z * (40 + j * 9) + Rt.z * ((i - 2) * 9) }
      local r2 = ST.newRecord(nil, rec.b, o.x, o.y, o.z, U, spot.t, "floor.steel", { name = "perf copy" })
      r2.bp = {}
      for _, p in ipairs(rec.bp) do
        local c = cat(p)
        if c and got[c] < want[c] then
          got[c] = got[c] + 1
          local q = {}
          for kk, v in pairs(p) do q[kk] = v end
          q.paid = nil
          r2.bp[#r2.bp + 1] = q
        end
      end
      if #r2.bp > 0 then
        local id = ST.add(r2)
        ST.spawnNow(id)
        ids[#ids + 1] = id
      end
    end
    wait_for(function() return spawnPending() == 0 end, 240, "the copies' pieces")
    wait(4)
    local cP = measure("char_base_painted")
    BK.shot("c7_base_500", false)
    -- strip every copy's paint (records and tints) and look again: tint must not split a draw
    for _, id in ipairs(ids) do
      local r3 = ST.get(id)
      for _, p in ipairs(r3.bp) do p.paint, p.paintIn = nil, nil end
      ST.put(r3)
      for _, p in ipairs(r3.bp) do KP.refresh(id, p.uid) end
    end
    wait(1)
    local cB = measure("char_base_bare")
    P("CHAR PERF the base: %d structures, %d structure pieces + %d props + %d decals and signs; it adds %d draws, %d instances, %d nodes, %d unbatched to the view",
      #ids, got.s, got.p, got.d, (cP.draws or 0) - (c0.draws or 0), (cP.instances or 0) - (c0.instances or 0), (cP.nodes or 0) - (c0.nodes or 0),
      (cP.unbatched or 0) - (c0.unbatched or 0))
    BK.check("tint_batches", math.abs((cP.draws or 0) - (cB.draws or 0)) <= 2 and (cP.unbatched or 0) <= (cB.unbatched or 0) + 2,
      "paint keeps the batches: %d draws painted, %d bare (unbatched %d vs %d)", cP.draws or -1, cB.draws or -1, cP.unbatched or -1, cB.unbatched or -1)
    BK.check("budget_draws", (cP.draws or 0) - (c0.draws or 0) <= 120,
      "the base adds %d draws to the view (plan §7: ≤ 120)", (cP.draws or 0) - (c0.draws or 0))
    local sw = KP.scans
    wait(6)
    BK.check("dust_idle", KP.scans == sw, "idle, the dust driver looks at no structure (%d scans in 6 s)", KP.scans - sw)
    for _, id in ipairs(ids) do ST.remove(id) end
    spawnBudget(nil)
    wait(3)
    KIT.cost("after the copies went", 3)
  end
  -- ── 8. save and reload ──
  local nb = #ST.get(sid).bp
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(5)
  ST, KL, BPs, KP = findScript("structures"), findScript("kit_live"), findScript("blueprints"), findScript("kit_paint")
  rec = ST.get(sid)
  local np2 = 0
  for _, p in ipairs(rec and rec.bp or {}) do if p.paint then np2 = np2 + 1 end end
  KIT.tp(rec, 1, 6)
  wait(3)
  local w2 = sgB and KL.signText(sid, sgB)
  local inLib = lb and BPs.get(lb.slug) ~= nil
  BK.check("reload", rec and #rec.bp == nb and np2 == np and w2 == "KESTREL FLATS" and inLib,
    "after a reload: %d pieces (was %d), %d painted (was %d), the board %s, the blueprint in the library %s",
    rec and #rec.bp or -1, nb, np2, np, tostring(w2), tostring(inLib))
  do local FL2 = findScript("flora_field"); if FL2 and FL2.params then FL2.params.enabled = 0 end end
  wait(1.5)
  KIT.view("c8_after_reload", rec, { -3.5, 2.6, 8.5 }, { 1, 1.2, 1 })
  BK.result()
end

-- ── mode "tint": does a tint reach a kit piece? (a diagnostic) ───────────────
function CH.run_tint()
  BK.tag = "tint"
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local KP = findScript("kit_paint")
  local spot = BK.flat_spot()
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
  tap("b"); wait(1.5)
  local sid
  for _, o in ipairs({ { 7, 0 }, { 8, -2 }, { 9, 2 } }) do
    fb.hold("slab2.concrete"); yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    if sid then break end
  end
  local rec = ST.get(sid)
  KP.DEBUG = true
  local uids = {}
  for i = 0, 3 do
    local p = { body = rec.b, mode = "face", sid = sid, lx = -0.75 + i * 0.5, ly = 0.2, lz = 0, yaw = 0, pitch = 0, roll = 0 }
    local _, _, _, u = fb.place(sid, (i == 3) and "crateS.steel" or "wall12.steel", p, "money")
    uids[#uids + 1] = u
  end
  -- a fifth, painted before its node has landed (the spawn-time path)
  do
    local p = { body = rec.b, mode = "face", sid = sid, lx = 0.5, ly = 0.2, lz = -0.95, yaw = math.pi, pitch = 0, roll = 0 }
    local _, _, _, u5 = fb.place(sid, "wall12.steel", p, "money")
    fb.paintParts(sid, { u5 }, "orange", "both")
    P("TINT fifth wall uid %s painted before it landed (node %s)", tostring(u5), tostring(ST.nodeOf(sid, u5)))
  end
  fb.dropHeld()
  KIT.close(fb)
  wait(2)
  local FL = findScript("flora_field"); if FL and FL.params then FL.params.enabled = 0 end
  for i, u in ipairs(uids) do
    local n = ST.nodeOf(sid, u)
    local names = {}
    if n then for _, c in ipairs(n:children() or {}) do names[#names + 1] = tostring(c.name) end end
    P("TINT piece %d uid %s node %s children: %s", i, tostring(u), tostring(n and n.name), table.concat(names, ", "))
  end
  local n1, n2, n3 = ST.nodeOf(sid, uids[1]), ST.nodeOf(sid, uids[2]), ST.nodeOf(sid, uids[3])
  local nn, why = fb.paintParts(sid, { uids[1] }, "orange", "both")
  P("TINT paintParts: %s %s; record paint %s", tostring(nn), tostring(why), tostring(ST.getPart(sid, uids[1]).paint))
  local out, inn = KP.surfaces(n1)
  P("TINT kit_paint surfaces: %d out, %d in", #out, #inn)
  local m2 = n2 and n2:getChild("Mesh")
  P("TINT direct Mesh child: %s", tostring(m2 and m2.name))
  if m2 then local ok, e = pcall(m2.setTint, m2, { color = { 1.9, 0.5, 0.15 } }); P("TINT setTint ok %s %s", tostring(ok), tostring(e)) end
  local CS = findScript("craft_stand")
  if n3 and CS and CS.tint_tree then CS.tint_tree(n3, 0) end
  fb.paintParts(sid, { uids[4] }, "orange", "both")
  wait(1.5)
  KIT.view("t1_tint_front", rec, { 0, 1.4, 4.0 }, { 0, 1.1, 0 })
  KIT.view("t2_tint_back", rec, { 0, 1.4, -4.0 }, { 0, 1.1, 0 })
  BK.result()
end
