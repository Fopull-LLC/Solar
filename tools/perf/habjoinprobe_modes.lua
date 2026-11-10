-- ── hab junction probe (tools/perf/kitprobe.sh habjoin; Ty 11-10) ───────────
-- Spliced after kitprobe_modes.lua (KIT helpers) into a copy of perfbench.lua.
--   habjoin  on flat ground 150+ m out, on an airless world (setVacuum): a
--            straight run of four Hab Segments capped both ends, built through
--            the Build Kit's own path (real rays at the rings' rims,
--            field_builder.placeAt); an Air Tank Rack in it; a segment held at
--            the run's side, aimed with the cursor: the ghost and the host's
--            JUNCTION PREVIEW (the T as a hologram, the real can hidden); the
--            branch placed by a ray at the side (the side snap): the host is a
--            T (hj R), its node swapped, a ray out through the port meets no
--            hull; the branch capped: ONE sealed room, pressurised by the tank
--            through the port, the branch's air the run's; a fourth arm (a
--            window segment) opposite: the cross; a run's end cap taken off and
--            a branch off that segment: the corner (Rf), its end plated, sealed
--            again; pictures outside, inside through the port, from the branch,
--            at the plated end; the re-shape's cost and the idle cost; save and
--            reload with the cached codes stripped (an OLD save): the junctions
--            rebuilt, the room still sealed; the first branch taken away: the
--            straight segment back.
-- One `BK PASS|FAIL <check>` line a check, `BK RESULT habjoin: PASS/FAIL`.
-- Pictures save/user/buildshots/hj*.png.
HJ = {}

local function hj_reload()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  wait(4)
end

function HJ.run()
  BK.tag = "habjoin"
  wait_ready(120)
  wait(2)
  local fb, ST, C, RA, RL, KS = findScript("field_builder"), findScript("structures"), findScript("crew"), findScript("room_air"),
    findScript("rooms"), findScript("kit_snap")
  if not BK.check("scene", fb and ST and RA and RL and KS and KS.habShapes, "the kit, rooms and the join rules are in the scene") then BK.result() return end
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
  -- ── the first segment on the ground ──
  local sid, why
  for _, o in ipairs({ { 9, -3 }, { 8, 0 }, { 10, 3 }, { 7, -5 }, { 11, 0 }, { 9, 4 } }) do
    fb.hold("habSeg.steel")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    if g then sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    P("HJ first segment at (%d, %d): %s", o[1], o[2], tostring(sid or why))
    if sid then break end
  end
  if not BK.check("seg1", sid ~= nil, "the first segment founds a structure (%s)", tostring(why)) then BK.result() return end
  wait(0.5)
  local rec = ST.get(sid)
  local p1 = rec.bp[1]
  local c1, s1 = math.cos(p1.yaw or 0), math.sin(p1.yaw or 0)
  -- a point in the first segment's frame (its +Z the run) → structure-local
  local function L(x, y, z) return { p1.x + x * c1 + z * s1, p1.y + y, p1.z - x * s1 + z * c1 } end
  local function partAt(x, z, id)
    rec = ST.get(sid)
    local q = L(x, 0, z)
    for _, p in ipairs(rec.bp) do
      if math.abs(p.x - q[1]) < 0.05 and math.abs(p.z - q[3]) < 0.05 and (not id or p.id == id) then return p end
    end
  end
  P("HJ seg1 at (%.2f, %.2f, %.2f) yaw %.1f°", p1.x, p1.y, p1.z, math.deg(p1.yaw or 0))
  -- the run: each ring on the last one's +Z end (a ray at the rim's crown)
  local RIM = 2.86
  for i = 2, 4 do
    local zE = 2 * (i - 2) + 1
    KIT.put(fb, rec, "habSeg.steel", L(0, RIM, zE + 3), L(0, RIM, zE - 0.5), "seg" .. i)
    rec = ST.get(sid)
  end
  KIT.put(fb, rec, "habCap.steel", L(0, RIM, 7 + 3), L(0, RIM, 6.5), "cap+Z")
  KIT.put(fb, rec, "habCap.steel", L(0, RIM, -1 - 3), L(0, RIM, -0.5), "cap-Z")
  rec = ST.get(sid)
  local segs = { partAt(0, 0), partAt(0, 2), partAt(0, 4), partAt(0, 6) }
  local capF, capB = partAt(0, 7.35, "habCap.steel"), partAt(0, -1.35, "habCap.steel")
  BK.check("run", segs[1] and segs[2] and segs[3] and segs[4] and capF and capB, "a straight run of four, capped both ends (%d pieces)", #rec.bp)
  local straight = true
  for _, p in ipairs(segs) do if p and p.hj then straight = false end end
  BK.check("run_straight", straight, "every segment of the run straight")
  -- an Air Tank Rack in the first segment, on its deck (fb.place: the kit
  -- refuses fittings inside a can, so the probe puts it there itself)
  do
    local q = L(0, 0.8, -0.35)
    local s2, w2, _, uid = fb.place(sid, "airTank.steel", { body = rec.b, mode = "face", sid = sid, lx = q[1], ly = q[2], lz = q[3],
      yaw = (p1.yaw or 0) + math.pi / 2, pitch = 0, roll = 0 }, "money")
    P("HJ air tank: %s", tostring(uid or w2))
  end
  wait(2.0)
  local st = RA.state(sid)
  local R = st and st.R
  BK.check("run_sealed", R and #R.rooms == 1 and R.rooms[1].sealed, "the capped run: one sealed room (%d rooms)", R and #R.rooms or -1)
  local m3run = R and R.rooms[1] and R.rooms[1].m3 or 0
  -- ── the preview: a segment held at the side of seg 2, aimed with the cursor ──
  fb.hold("habSeg.steel")
  yield()
  local b0 = home()
  local eye, tgt = L(6.0, 6.8, -1.5), L(1.25, 1.6, 2.2)
  local we, wt = KIT.w(rec, eye[1], eye[2], eye[3]), KIT.w(rec, tgt[1], tgt[2], tgt[3])
  VP.cam_fixed(sub(we, b0), sub(wt, b0))
  wait(0.6)
  local shown = false
  for _ = 1, 90 do
    local w = KIT.w(rec, tgt[1], tgt[2], tgt[3])
    local sx, sy = camera.worldToScreen(w.x, w.y, w.z)
    if sx then fb.sim = { mouse = { sx, sy } } end
    yield()
    if fb.JP and fb.JP.n >= 1 and next(fb.JP.holo) and fb.req and fb.req.pose and not fb.req.bad then shown = true end
    if shown and fb.ghost_node and fb.ghost_node.visible then break end
  end
  wait(0.5)
  local real = ST.nodeOf(sid, segs[2].uid)
  local pz = fb.req and fb.req.pose
  BK.check("preview", shown and real and real.visible == false and fb.JP.holo[segs[2].uid] ~= nil,
    "held at the side, the ghost is the branch (%s) and the host shows the T it will make (preview holograms %d, the real can hidden %s)",
    pz and string.format("%.2f, %.2f yaw %.0f°", pz.lx or 0, pz.lz or 0, math.deg(pz.yaw or 0)) or "no pose", fb.JP and fb.JP.n or -1, tostring(real and real.visible == false))
  BK.shot("hj1_preview_T", true)
  VP.cam_off()
  fb.sim = nil
  fb.dropHeld()
  wait(0.5)
  BK.check("preview_gone", real and real.visible ~= false and not next(fb.JP.holo), "the hand empty: the preview gone, the real can drawn again")
  -- ── the branch: by a ray at seg 2's +X side ──
  local rs0 = ST.reshapes or 0
  local t0 = os.clock()
  local ub, pb = KIT.put(fb, rec, "habSeg.steel", L(4.5, 1.65, 2), L(0, 1.65, 2), "branch")
  local place_ms = (os.clock() - t0) * 1000
  rec = ST.get(sid)
  local br = ub and ST.getPart(sid, ub)
  local q = L(2.35, 0, 2)
  BK.check("branch_pose", br and math.abs(br.x - q[1]) < 0.01 and math.abs(br.z - q[3]) < 0.01 and math.abs(math.cos(br.yaw - p1.yaw)) < 1e-6,
    "the side snap: the branch's end on seg 2's side, square to it (%s)", br and string.format("%.2f, %.2f yaw %.0f°", br.x, br.z, math.deg(br.yaw)) or "none")
  BK.check("T", segs[2].hj == "R" and (ST.reshapes or 0) == rs0 + 1, "seg 2 is a T (hj %s), re-drawn once (%d); the placement call %.2f ms (a frame's yield in it)",
    tostring(segs[2].hj), (ST.reshapes or 0) - rs0, place_ms)
  wait(1.0)
  do
    -- the port is open: a ray from inside seg 2 out through its +X side meets no hull before the branch's far end
    local a, bpt = L(0, 1.6, 2), L(3.2, 1.6, 2)
    local h = KIT.ray(rec, a, bpt)
    local hd = h and len(h.x - KIT.w(rec, a[1], a[2], a[3]).x, h.y - KIT.w(rec, a[1], a[2], a[3]).y, h.z - KIT.w(rec, a[1], a[2], a[3]).z)
    BK.check("port_open", h == nil, "a ray from the run out through the port meets nothing for 3.2 m (%s)", hd and string.format("hit at %.2f m", hd) or "clear")
    local h2 = KIT.ray(rec, L(0, 1.6, 4), L(3.2, 1.6, 4))
    BK.check("wall_kept", h2 ~= nil, "seg 3's side is still a wall")
  end
  KIT.put(fb, rec, "habCap.steel", L(2.35 + 1 + 3, RIM, 2), L(2.35 + 0.5, RIM, 2), "branch cap")
  rec = ST.get(sid)
  wait(2.5)
  st = RA.state(sid)
  R = st and st.R
  local rr = R and RL.roomAt(R, L(0, 1.6, 2)[1], 1.6, L(0, 1.6, 2)[3])
  local rb = R and RL.roomAt(R, L(2.9, 1.6, 2)[1], 1.6, L(2.9, 1.6, 2)[3])
  BK.check("T_sealed", R and #R.rooms == 1 and R.rooms[1].sealed and rr and rb and rr.id == rb.id and R.rooms[1].m3 > m3run + 4,
    "the T capped: ONE sealed room, the run and the branch in it (%.1f m³, the run alone %.1f)", R and R.rooms[1] and R.rooms[1].m3 or -1, m3run)
  -- the tank's regulator moves 0.25 m³/s: a 50 m³ T fills in ~200 s. Its rate
  -- into the whole room, run and branch, is the check (a leak would hold it back)
  local a0 = rr and RA.airOf(sid, rr.id)
  local p0, t0a = a0 and a0.p, time
  wait(40)
  local a1 = rr and RA.airOf(sid, rr.id)
  local V = R and R.rooms[1] and R.rooms[1].m3 or 1
  local rate = (p0 and a1) and (a1.p - p0) * V / math.max(time - t0a, 1e-3) or -1
  local ab = rb and RA.airOf(sid, rb.id)
  BK.check("T_air", rate > 0.25 * 0.85 and rate < 0.25 * 1.15 and ab and a1 and math.abs(ab.p - a1.p) < 1e-6,
    "the tank fills the whole T through the port at its full 0.25 m³/s (%.3f m³/s: %.2f -> %.2f atm over %.0f s in %.1f m³); the branch's air is the run's (%.3f atm)",
    rate, p0 or -1, a1 and a1.p or -1, time - t0a, V, ab and ab.p or -1)
  fb.dropHeld()
  -- (two ceiling lights to see by: mounts meet only mounts, so they may hang in a can)
  for _, lq in ipairs({ L(0, 2.70, 1.2), L(2.9, 2.70, 2.0) }) do
    local _, w2, _, luid = fb.place(sid, "lightFitting.steel", { body = rec.b, mode = "face", sid = sid, lx = lq[1], ly = lq[2], lz = lq[3],
      yaw = p1.yaw or 0, pitch = math.pi, roll = 0 }, "money")
    P("HJ light: %s", tostring(luid or w2))
  end
  rec = ST.get(sid)
  wait(1.5)
  KIT.view("hj2_T_outside", rec, L(8, 5, -5), L(1.2, 1.4, 2.5))
  KIT.view("hj3_T_outside_low", rec, L(6.5, 1.2, 6.5), L(1.3, 1.6, 2.0))
  KIT.view("hj4_T_inside_port", rec, L(-0.55, 1.75, 0.6), L(1.4, 1.55, 2.0))
  KIT.view("hj4b_T_mouth_close", rec, L(-0.2, 1.9, 1.15), L(1.0, 1.7, 2.6))
  KIT.view("hj4c_T_mouth_sill", rec, L(0.0, 1.3, 2.9), L(1.2, 0.85, 1.7))
  KIT.view("hj5_T_from_branch", rec, L(3.15, 1.7, 2.3), L(0, 1.5, 1.8))
  KIT.view("hj6_T_joint_close", rec, L(3.6, 2.7, 4.2), L(1.4, 1.8, 2.8))
  KIT.view("hj6b_T_under", rec, L(3.0, 0.35, 3.6), L(1.3, 0.9, 2.2))
  -- ── the cross: a window segment off seg 2's -X side ──
  local ux = KIT.put(fb, rec, "habWindow.steel", L(-4.5, 1.65, 2), L(0, 1.65, 2), "arm -X")
  rec = ST.get(sid)
  BK.check("X", ux and segs[2].hj == "LR", "a window segment off the other side: the cross (hj %s)", tostring(segs[2].hj))
  KIT.put(fb, rec, "habCap.steel", L(-2.35 - 1 - 3, RIM, 2), L(-2.35 - 0.5, RIM, 2), "arm -X cap")
  rec = ST.get(sid)
  wait(2.5)
  st = RA.state(sid)
  R = st and st.R
  BK.check("X_sealed", R and #R.rooms == 1 and R.rooms[1].sealed, "the cross capped: one sealed room (%d rooms, %.1f m³)", R and #R.rooms or -1, R and R.rooms[1] and R.rooms[1].m3 or -1)
  fb.dropHeld()
  KIT.view("hj7_X_outside", rec, L(-7, 6, -6), L(0, 1.4, 2.5))
  KIT.view("hj7b_X_inside", rec, L(0.2, 1.75, 0.3), L(-1.6, 1.5, 2.1))
  -- ── the corner: seg 4's end cap off, a branch off seg 4's +X ──
  local okd, wd = fb.deconstruct(sid, capF.uid)
  rec = ST.get(sid)
  BK.check("cap_off", ST.getPart(sid, capF.uid) == nil, "seg 4's end cap taken off (%s)", tostring(okd or wd))
  local uL = KIT.put(fb, rec, "habSeg.steel", L(4.5, 1.65, 6), L(0, 1.65, 6), "corner")
  rec = ST.get(sid)
  BK.check("L", uL and segs[4].hj == "Rf", "a branch off the run's last segment: the corner, its free end plated (hj %s)", tostring(segs[4].hj))
  KIT.put(fb, rec, "habCap.steel", L(2.35 + 1 + 3, RIM, 6), L(2.35 + 0.5, RIM, 6), "corner cap")
  rec = ST.get(sid)
  wait(2.5)
  st = RA.state(sid)
  R = st and st.R
  BK.check("L_sealed", R and #R.rooms == 1 and R.rooms[1].sealed, "the corner, plated and capped: one sealed room (%d rooms)", R and #R.rooms or -1)
  fb.dropHeld()
  KIT.view("hj8_L_outside", rec, L(6, 4.5, 11), L(1.0, 1.4, 5.5))
  KIT.view("hj9_L_plated_end_inside", rec, L(-0.3, 1.7, 4.6), L(0.3, 1.5, 7.0))
  -- ── cost ──
  do
    local t1 = os.clock()
    for _ = 1, 50 do KS.habShapes(ST.get(sid), findScript("parts_base").partInfo, { { x = q[1], z = q[3] } }) end
    local per = (os.clock() - t1) / 50 * 1000
    local t2 = os.clock()
    for _ = 1, 20 do KS.habShapes(ST.get(sid), findScript("parts_base").partInfo, nil) end
    local all = (os.clock() - t2) / 20 * 1000
    BK.check("reshape_cost", per < 1.0, "a placement's re-shape: %.3f ms; the whole structure (%d parts): %.3f ms", per, #ST.get(sid).bp, all)
    KIT.close(fb)
    wait(1.0)
    KIT.cost("habjoin idle, kit shut", 3)
  end
  -- ── save, strip the cached codes (an OLD save), reload ──
  local before = nil
  do
    local st0 = RA.state(sid)
    local rr0 = st0 and st0.R and RL.roomAt(st0.R, L(0, 1.6, 2)[1], 1.6, L(0, 1.6, 2)[3])
    local ab0 = rr0 and RA.airOf(sid, rr0.id)
    before = ab0 and ab0.p
    if save.flush then save.flush() end
    local r = save.get("struct." .. tostring(sid))
    local n = 0
    for _, p in ipairs(r and r.bp or {}) do if p.hj then p.hj = nil; n = n + 1 end end
    save.set("struct." .. tostring(sid), r)
    P("HJ stripped %d cached codes from the saved record", n)
  end
  hj_reload()
  ST, RA, RL, fb = findScript("structures"), findScript("room_air"), findScript("rooms"), findScript("field_builder")
  rec = ST.get(sid)
  local function code(x, z) local p = partAt(x, z); return p and p.hj end
  BK.check("reload_codes", rec and code(0, 2) == "LR" and code(0, 6) == "Rf", "after the reload (no codes in the save): seg 2 %s, seg 4 %s",
    tostring(code(0, 2)), tostring(code(0, 6)))
  wait(3.0)
  st = RA.state(sid)
  R = st and st.R
  local rr2 = R and RL.roomAt(R, L(0, 1.6, 2)[1], 1.6, L(0, 1.6, 2)[3])
  local a2 = rr2 and RA.airOf(sid, rr2.id)
  -- (the corner step took an end cap off: the room vented until it was capped,
  -- so what matters is that the reload keeps the air it had)
  BK.check("reload_sealed", R and #R.rooms == 1 and R.rooms[1].sealed and a2 and before and a2.p >= before - 0.02,
    "the junctions rebuilt: one sealed room, its air kept (%.2f atm before the save, %.2f after)", before or -1, a2 and a2.p or -1)
  KIT.view("hj10_reloaded", rec, L(8, 6, -6), L(0.5, 1.4, 3.0))
  -- ── take the first branch away: the straight segment back ──
  local brp = partAt(2.35, 2)
  if brp then
    for _, p in ipairs(ST.get(sid).bp) do
      local qq = L(3.7, 0, 2)
      if p.id == "habCap.steel" and math.abs(p.x - qq[1]) < 0.05 and math.abs(p.z - qq[3]) < 0.05 then fb.deconstruct(sid, p.uid) end
    end
    fb.deconstruct(sid, brp.uid)
  end
  rec = ST.get(sid)
  BK.check("removed", partAt(2.35, 2) == nil and code(0, 2) == "L", "the +X branch taken away: seg 2 is a T on its other side again (hj %s)", tostring(code(0, 2)))
  wait(2.5)
  st = RA.state(sid)
  R = st and st.R
  BK.check("removed_sealed", R and #R.rooms == 1 and R.rooms[1].sealed, "and the hab is still one sealed room (%d)", R and #R.rooms or -1)
  KIT.view("hj11_branch_removed", rec, L(7.5, 4.5, -4), L(1.0, 1.4, 2.5))
  KIT.view("hj11b_side_closed_inside", rec, L(-0.6, 1.75, 0.8), L(1.2, 1.5, 2.0))
  BK.result()
end
