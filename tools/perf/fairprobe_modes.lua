-- ── fairing probe (tools/perf/fairprobe.sh): the fairing redesign ──────────
-- (deep-space proposal §6, E1–E6). Spliced into a copy of perfbench.lua after
-- vfxprobe_modes.lua (its cameras); one table of functions (perfbench's main
-- chunk is near Lua's 200-locals ceiling).
--   fairvab   the VAB: a payload on a 1.25 m base over a core with two side
--             boosters. The handles on the fitted shell, a real mouse drag of
--             the TOP handle (the shell re-lathes; craftVersion holds until
--             the drop), the SHAPE menu, a squat shell with parts sticking
--             out (red, FIT), FIT, three pieces and an open top, the STAGE
--             tab's card with an auto-drop; idle with the base selected: no
--             shell rebuilt
--   fairfly   the same craft launched (params pieces = 2 | 3), climbing at
--             full throttle with the boosters still on, the fairing fired:
--             frames of the unlatch, the hinge and the release from a camera
--             beside the craft, then every piece's box against every payload
--             and booster part's box every frame for 6 s (SAT separation:
--             < 0 = they overlap) — inside the craft's ignore window (3 s:
--             they pass through) and after it (they would touch)
-- One `FP PASS|FAIL <check>` line a check and `FP RESULT <mode>: PASS/FAIL`.
-- Pictures: 1280x720, save/user/fairshots/<mode>_<name>.png in the scratch project.
FP = { fails = 0, tag = "fair" }
function FP.check(name, ok, fmt, ...)
  P("FP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then FP.fails = FP.fails + 1 end
  return ok
end
function FP.result() P("FP RESULT %s: %s (%d failed check(s))", FP.tag, FP.fails == 0 and "PASS" or "FAIL", FP.fails) end
function FP.shot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://fairshots/" .. FP.tag .. "_" .. nm .. ".png", bytes); P("FP SHOT %s_%s t=%.3f", FP.tag, nm, time)
    else P("FP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("FP capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- THE CRAFT (bottom up, the builder's frame): Sputter, two FT-M, the 1.25 m
-- fairing base, a probe core and a battery on it; two side boosters (FT-M +
-- Sputter on radial decouplers) along ±X beside the upper tank, their tops
-- just under the fairing base — the parts a falling piece could hit.
function FP.craft(B)
  local function def(id) local pr = findScript("parts_registry"); return (pr and pr.REG and pr.REG[id]) or B.partInfo(id) end
  local up, X = { x = 0, y = 1, z = 0 }, { x = 1, y = 0, z = 0 }
  local R, y, prev = {}, 0, nil
  local function add(r) R[#R + 1] = r return r end
  puid = 0
  local function stack(id)
    local h = def(id).h
    local r = add(prec(id, 0, y + h / 2, 0, X, up, prev and { parent = prev.uid, att = "top" } or nil))
    y = y + h
    prev = r
    return r
  end
  local eng = stack("engineS")
  local t1 = stack("tankM")
  local t2 = stack("tankM")
  local fb = stack("fairingS")
  local pr = stack("probe")
  local bat = stack("battery")
  for _, s in ipairs({ 1, -1 }) do
    local out = { x = s, y = 0, z = 0 }
    local dec = add(prec("radialDec", s * 0.625, t2.y, 0, { x = 0, y = 0, z = 1 }, out, { parent = t2.uid, att = "surface", sym = 1, mir = "x" }))
    local bt = add(prec("tankM", s * 1.25, t2.y, 0, X, up, { parent = dec.uid, att = "surface", sym = 2, mir = "x" }))
    add(prec("engineS", s * 1.25, t2.y - 0.75 - 0.65, 0, X, up, { parent = bt.uid, att = "bottom", sym = 3, mir = "x" }))
  end
  FP.uids = { engine = eng.uid, t1 = t1.uid, t2 = t2.uid, base = fb.uid, payload = { pr.uid, bat.uid } }
  FP.boost, FP.size = {}, {}
  for _, r in ipairs(R) do
    if math.abs(r.x) > 1.0 then FP.boost[#FP.boost + 1] = r.uid end
    local d = def(r.id)
    FP.size[r.uid] = { rx = d.rx, h = d.h, rz = d.rz }
  end
  return R
end

function FP.vab(B)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "fairingS", "radialDec", "probe", "battery" }) do if rs and rs.grant then rs.grant(id, "probe") end end
end

-- ── fairvab ─────────────────────────────────────────────────────────────────
function FP.run_vab()
  FP.tag = params.tag or "vab"
  local BH = enter_vab("fp_enter")
  if not BH then FP.check("vab", false, "no builder"); FP.result(); return end
  local B = findScript("builder")
  FP.vab(B)
  wait(1)
  local list = FP.craft(B)
  load_bp(B, "fp_craft", list, { name = "Faired" })
  wait(1)
  local fb = FP.uids.base
  local bc = findScript("builder_camera")
  B.select({ fb }, "set")
  -- (the whole craft in view: the shell, its nose and the boosters beside it)
  if bc and bc.frameCraft then bc.frameCraft() elseif bc and bc.frameSelection then bc.frameSelection() end
  wait(1.5)
  local f0 = B.fairingInfo(fb)
  FP.check("fitted", f0 and f0.kind == "fitted" and f0.nout == 0 and f0.nin == 2,
    "the fitted shell holds the payload: %s, %d of %d, %.2f m wide, %.0f kg", tostring(f0 and f0.kind), f0 and f0.nin or -1,
    f0 and (f0.nin + f0.nout) or -1, f0 and f0.rmax * 2 or -1, f0 and f0.mass * 1000 or -1)
  -- E6: where the fairing landed in the stack (the boosters' ring below it)
  local v = B.stageView()
  local kinds = {}
  for n, sg in ipairs(v.stages) do
    local ks = {}
    for _, e in ipairs(sg.items) do ks[#ks + 1] = e.kind end
    kinds[n] = table.concat(ks, "+")
  end
  FP.check("stage_default", table.concat(kinds, " ") == "ring fairing", "the default stack: %s (boosters, then the fairing)", table.concat(kinds, " "))
  FP.shot("1handles")
  -- idle with the base selected: nothing re-lathed
  local sv0, cv0 = B.fairingShapeVersion(), B.craftVersion
  local c0 = perf.counts() or {}
  wait(2)
  local c1 = perf.counts() or {}
  FP.check("idle_no_rebuild", B.fairingShapeVersion() == sv0 and B.craftVersion == cv0,
    "2 s idle, base selected: shape version %d → %d, craftVersion %d → %d (meshes %s → %s)", sv0, B.fairingShapeVersion(),
    cv0, B.craftVersion, tostring(c0.meshes), tostring(c1.meshes))
  -- a real mouse drag of the TOP handle: out and up
  local sx, sy = B.fairingHandleScreen(fb, "top")
  P("FP top handle on screen at %s, %s", tostring(sx), tostring(sy))
  if sx then
    local sw, sh = camera.screenSize()
    mouse_to(sx, sy); wait(0.3)
    FP.shot("2hover_top")
    input.simulate { button = 0, down = true }; yield(); yield(); yield()
    local drag0 = B.fairingDragging()
    local svd, cvd = B.fairingShapeVersion(), B.craftVersion
    for k = 1, 20 do mouse_to(sx + k * 3.5 * sw / 1280, sy - k * 2.5 * sh / 720) end
    wait(0.2)
    FP.check("drag_started", drag0 == "top", "the press took the top handle (%s)", tostring(drag0))
    FP.check("drag_relathes", B.fairingShapeVersion() > svd and B.craftVersion == cvd,
      "dragging: the shell re-lathed %d times, craftVersion untouched (%d)", B.fairingShapeVersion() - svd, B.craftVersion)
    FP.shot("3dragging_top")
    input.simulate { button = 0, down = false }; yield(); yield(); yield()
    wait(0.3)
    local f1 = B.fairingInfo(fb)
    FP.check("drag_dropped", B.fairingDragging() == nil and B.craftVersion > cvd and f1.kind == "handles",
      "dropped: one edit, the shell %.2f m wide, %.2f m tall (%s)", f1.rmax * 2, f1.height, f1.kind)
    FP.shot("4after_drag")
  else
    FP.check("drag_started", false, "no top handle on screen")
  end
  -- the SHAPE menu
  B.fairingMenu(fb); wait(0.3)
  FP.shot("5shape_menu")
  B.fairingMenu(nil)
  -- a squat shell: the battery sticks out (red), FIT
  B.cmd("fairing", { uid = fb, op = "handles", hp = { rb = 0.66, rs = 0.7, hs = 0.15, rt = 0.55, ht = 0.6, hn = 0.4, open = false } })
  wait(0.5)
  local f2 = B.fairingInfo(fb)
  FP.check("sticks_out", f2.nout > 0, "a squat shell: %d part(s) stick out", f2.nout)
  FP.shot("6sticks_out_fit")
  B.cmd("fairing", { uid = fb, op = "fit" })
  wait(0.5)
  local f3 = B.fairingInfo(fb)
  FP.check("fit", f3.nout == 0 and f3.nin == 2, "FIT: holds %d of %d, %.2f m wide, %.2f m tall, %.0f kg", f3.nin, f3.nin + f3.nout,
    f3.rmax * 2, f3.height, f3.mass * 1000)
  FP.shot("7after_fit")
  -- three pieces, then an open top (an inter-stage skirt)
  B.cmd("fairing", { uid = fb, op = "split", n = 3 }); wait(0.4)
  FP.shot("8three_pieces")
  B.cmd("fairing", { uid = fb, op = "open", on = true }); wait(0.4)
  local f4 = B.fairingInfo(fb)
  FP.check("open_top", f4.open, "an open top: %.2f m tall, holds %d", f4.height, f4.nin)
  FP.shot("9open_top")
  B.cmd("fairing", { uid = fb, op = "reset" })
  B.cmd("fairing", { uid = fb, op = "auto", pct = 70 }); wait(0.3)
  local ins = findScript("builder_inspector")
  if ins and ins.setTab then ins.setTab("STAGE") end
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(1.2)
  v = B.stageView()
  local fe = nil
  for _, sg in ipairs(v.stages) do for _, e in ipairs(sg.items) do if e.kind == "fairing" then fe = e end end end
  FP.check("stage_card", fe and fe.fauto == 70, "the stage card: the fairing drops at %s %% of the air", tostring(fe and fe.fauto))
  FP.shot("10stage_card")
  if ins and ins.setTab then ins.setTab("INSPECT") end
  B.select({ fb }, "set"); wait(0.8)
  FP.shot("11inspector")
  FP.result()
end

-- ── fairfly ─────────────────────────────────────────────────────────────────
-- An oriented box from a node's drawn pose: centre, axes, half extents.
function FP.box_of(n, hx, hy, hz, oy)
  local o = n:toWorld(vec3(0, oy or 0, 0))
  local c0 = n:toWorld(vec3(0, 0, 0))
  local function ax(v) local w = n:toWorld(v) - c0; return unit({ x = w.x, y = w.y, z = w.z }) end
  return { c = { x = o.x, y = o.y, z = o.z }, a = { ax(vec3(1, 0, 0)), ax(vec3(0, 1, 0)), ax(vec3(0, 0, 1)) }, h = { hx, hy, hz } }
end
-- SAT: the largest gap between two oriented boxes along any separating axis
-- (> 0 apart by at least that, < 0 overlapping).
function FP.sep(A, B)
  local axes = { A.a[1], A.a[2], A.a[3], B.a[1], B.a[2], B.a[3] }
  for i = 1, 3 do for j = 1, 3 do
    local c = cross(A.a[i], B.a[j])
    if len(c.x, c.y, c.z) > 1e-6 then axes[#axes + 1] = unit(c) end
  end end
  local d = sub(B.c, A.c)
  local best = -math.huge
  for _, L in ipairs(axes) do
    local ra, rb = 0, 0
    for i = 1, 3 do ra = ra + A.h[i] * math.abs(dot(A.a[i], L)); rb = rb + B.h[i] * math.abs(dot(B.a[i], L)) end
    best = math.max(best, math.abs(dot(d, L)) - ra - rb)
  end
  return best
end

function FP.run_fly()
  local pieces = (params.pieces or 2) >= 3 and 3 or 2
  FP.tag = params.tag or ("fly" .. pieces)
  local BH = enter_vab("fp_enter")
  if not BH then FP.check("vab", false, "no builder"); FP.result(); return end
  local B = findScript("builder")
  FP.vab(B)
  wait(1)
  local list = FP.craft(B)
  load_bp(B, "fp_craft", list, { name = "Faired" })
  if pieces == 3 then B.cmd("fairing", { uid = FP.uids.base, op = "split", n = 3 }) end
  wait(0.5)
  local site = params.site or "pad"
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not vc then FP.check("rollout", false, "no craft"); FP.result(); return end
  local vn = vc.node
  wait(2)
  local fb = FP.uids.base
  -- the parts a piece must not touch: the payload and the boosters
  local watch = {}
  for _, u in ipairs(FP.uids.payload) do watch[#watch + 1] = { uid = u, what = "payload" } end
  for _, u in ipairs(FP.boost) do watch[#watch + 1] = { uid = u, what = "booster" } end
  for _, wv in ipairs(watch) do
    local d = nil
    for _, r in ipairs(list) do if r.uid == wv.uid then d = r end end
    local sz = FP.size[wv.uid]
    wv.id, wv.hx, wv.hy, wv.hz = d.id, sz.rx, sz.h / 2, sz.rz
  end
  -- up at full throttle, the boosters still on
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0 = time
  while time - t0 < (params.climb or 7) and vn.valid do vc.setThrottle(1); yield() end
  local alt0, V0 = body_state(vn).alt, body_state(vn).V
  P("FP climbing: %.0f m up at %.1f m/s, %d parts", alt0, V0, #(assembly.info(vn).parts))
  -- the camera beside the craft at the fairing's height, in its own frame
  local yb = 0
  for _, r in ipairs(list) do if r.uid == fb then yb = r.y end end
  VP.cam_local(vn, 7.5, yb + 2.2, 4.5, 0, yb + 0.6, 0)
  for _ = 1, 20 do vc.setThrottle(1); yield() end
  FP.shot("0before", false)
  -- FIRE (out of turn: the boosters stay on, the hard case)
  local tj = time
  local fired = vc.fireSeparation(fb)
  FP.check("fired", fired, "the fairing fired with the boosters on")
  local shots = { 0.05, 0.17, 0.30, 0.45, 0.8, 1.5, 2.5 }
  local si = 1
  local released, rel_t = nil, nil
  local worst_in, worst_out = math.huge, math.huge
  local worst_in_what, worst_out_what = "-", "-"
  local logged = {}
  local hard_in = false
  while time - tj < 6.5 and vn.valid do
    vc.setThrottle(1)
    yield()
    local ps, opening = vc.fairingPieces()
    if not released and #ps >= pieces then
      released, rel_t = ps, time
      -- the release: velocity relative to the craft at its point, in the craft's frame
      local ci = assembly.info(vn)
      local cU = up_axis(vn, body_state(vn).U)
      for k, h in ipairs(ps) do
        local rv = { x = (h.vx or 0) - ci.vel.x, y = (h.vy or 0) - ci.vel.y, z = (h.vz or 0) - ci.vel.z }
        local hp = h:toWorld(vec3(0, 0, 0))
        local axis_pt = vn:toWorld(vec3(0, yb, 0))
        local rr = sub(hp, axis_pt)
        local radial = sub(rr, scl(cU, dot(rr, cU)))
        local out = unit(radial)
        P("FP piece %d released at %.3f s after the fire: %.2f m off the axis, rel. velocity out %.2f, along the stack %.2f, total %.2f m/s",
          k, time - tj, len(radial.x, radial.y, radial.z), dot(rv, out), dot(rv, cU), len(rv.x, rv.y, rv.z))
      end
    end
    if released then
      local tt = time - rel_t
      for k, h in ipairs(released) do
        if h.valid then
          local rb = h:getcomponent("RigidBody")
          local A = FP.box_of(h, rb.half_x, rb.half_y, rb.half_z)
          for _, wv in ipairs(watch) do
            local pn = vc.r2NodeOf and vc.r2NodeOf(vn, wv.uid)
            if pn and pn.valid then
              local Bx = FP.box_of(pn, wv.hx, wv.hy, wv.hz)
              local s = FP.sep(A, Bx)
              if tt < 3.0 then
                if s < worst_in then worst_in, worst_in_what = s, string.format("piece %d vs %s %s at +%.2f s", k, wv.what, wv.id, tt) end
              else
                if s < worst_out then worst_out, worst_out_what = s, string.format("piece %d vs %s %s at +%.2f s", k, wv.what, wv.id, tt) end
              end
            end
          end
          local key = k .. ":" .. math.floor(tt * 2)
          if not logged[key] then
            logged[key] = true
            local hp = h:toWorld(vec3(0, 0, 0))
            local loc = sub(hp, vn:toWorld(vec3(0, yb, 0)))
            local cU = up_axis(vn, body_state(vn).U)
            local along = dot(loc, cU)
            local rad = sub(loc, scl(cU, along))
            P("FP piece %d +%.1f s: %.2f m out from the axis, %.2f m along it from the base", k, tt, len(rad.x, rad.y, rad.z), along)
          end
        end
      end
    end
    if shots[si] and time - tj >= shots[si] then
      FP.shot(string.format("%d_t%03d", si, math.floor(shots[si] * 100 + 0.5)), false)
      si = si + 1
    end
  end
  -- the hinge in the craft's own game time (fire → release), and when the probe first saw the pieces
  local _, _, ft, rt = vc.fairingPieces()
  local hinge = (ft and rt) and (rt - ft) or -1
  FP.check("released", released ~= nil and hinge >= 0.3 and hinge < 0.5,
    "%d pieces let go %.3f s (game time) after the fire: the hinge first (seen by the probe at +%.2f s)",
    released and #released or 0, hinge, rel_t and (rel_t - tj) or -1)
  FP.check("clear_after_ignore", worst_out > 0, "after the 3 s ignore window no piece touches the payload or a booster: worst gap %.2f m (%s)",
    worst_out, worst_out_what)
  P("FP inside the ignore window (pieces pass through the craft): worst gap %.2f m (%s)", worst_in, worst_in_what)
  FP.check("clear_in_window", worst_in > 0, "…and inside it they never even pass through one: worst gap %.2f m (%s)", worst_in, worst_in_what)
  VP.cam_off()
  vc.setThrottle(0)
  FP.result()
end
