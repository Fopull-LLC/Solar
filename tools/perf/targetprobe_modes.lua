-- ── target probe (tools/perf/targetprobe.sh): Set target, SAS Target, docking ──
-- tdock: a craft (battery, pod, a docking port on each end) launched from the
--        pad, put on a circular orbit, and a twin rebuilt from a fleet record
--        `gap` m ahead on the same orbit, turned crooked. Its top port is
--        targeted, SAS Target engaged (the "which port?" prompt answered with
--        our top port), and the port's angle and roll error logged every
--        0.25 s for `holdsecs`; then the map (its marker, a right-click on the
--        twin and on a world, Set target there), the edge pin, Anti-target.
-- Everything is one table (TP) and one function: perfbench's main chunk is
-- near LuaJIT's 200-local ceiling. Look for `TP` lines; pictures land in
-- $WORK/proj/save/user/targetshots/.
local TP = { tag = "t", AX = { x = 0, y = 1, z = 0 } }
function TP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://targetshots/" .. TP.tag .. "_" .. nm .. ".png", bytes); P("TP SHOT %s_%s", TP.tag, nm)
    else P("TP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function TP.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = TP.copy(v) end
  return o
end
function TP.bp()
  return {
    rec(1, "battery", 0, 0.5, 0),
    rec(2, "pod", 0, 1.4, 0, { parent = 1, att = "top" }),
    rec(3, "dockPort", 0, 1.94, 0, { parent = 2, att = "top" }),
    rec(4, "dockPort", 0, -0.14, 0, { parent = 1, att = "bottom" }),
  }
end
function TP.frame(vn)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local T = cross(U, TP.AX)
  if len(T.x, T.y, T.z) < 0.1 then T = cross(U, { x = 1, y = 0, z = 0 }) end
  return i, b, U, unit(T)
end
-- the hold, logged: → { t, angle, roll, rate, range, closing, lateral }
function TP.sample(TG, t0)
  local s = TG.steerLog or {}
  local r = TG.readout or {}
  return { t = time - t0, angle = s.angle or -1, roll = s.roll or 0, rate = s.rate or 0,
           range = r.range or -1, closing = r.closing or 0, lateral = r.lateral or -1, rangle = r.angle or -1, rroll = r.roll or 0 }
end
function TP.hold(TG, vc, secs, tag)
  local t0, nextp = time, 0
  local L = {}
  while time - t0 < secs do
    yield()
    if time - t0 >= nextp then
      nextp = nextp + 0.25
      local s = TP.sample(TG, t0)
      L[#L + 1] = s
      if (#L - 1) % 4 == 0 then
        P("TP %s t %5.2f angle %7.3f roll %+7.3f rate %.3f | range %.2f closing %+.3f lateral %.2f | sas %s",
          tag, s.t, s.angle, s.roll, s.rate, s.range, s.closing, s.lateral, tostring(vc.sas_mode))
      end
    end
  end
  -- settle figures: first under 2° and 1°, the worst after first under 1°, the last
  local u2, u1, worst, rworst = nil, nil, 0, 0
  for _, s in ipairs(L) do
    if s.angle >= 0 then
      if not u2 and s.angle < 2 then u2 = s.t end
      if not u1 and s.angle < 1 then u1 = s.t end
      if u1 then worst = math.max(worst, s.angle); rworst = math.max(rworst, math.abs(s.roll)) end
    end
  end
  local last = L[#L] or {}
  P("TP RESULT %s: under 2° at %s s, under 1° at %s s, worst after 1° %.3f° (roll %.3f°), final angle %.3f° roll %+.3f° rate %.4f",
    tag, u2 and string.format("%.2f", u2) or "never", u1 and string.format("%.2f", u1) or "never", worst, rworst,
    last.angle or -1, last.roll or 0, last.rate or 0)
  return L
end
function TP.geom(TG, tag)
  local G = TG.GEOM
  if not G then P("TP GEOM %s: none", tag) return end
  local function sv(t) return t and string.format("(%.0f,%.0f%s)", t[1], t[2], t[3] and "" or " off") or "-" end
  P("TP GEOM %s: range %.2f | aim-to-port %.2f° | port off our axis %.3f m | anti-parallel err %.3f° | line ends vs part nodes: ours %.3f m theirs %.3f m | tick-vs-drawn absolute %.3f m, relative %.3f m | steer(tick) vs drawn rel %.3f m | screen ours %s theirs %s (node %s) ray end %s",
    tag, G.range, G.aimToPort, G.rayMiss, G.antiPar, G.nodeErrMine, G.nodeErrTheirs, G.tickGapMine or -1, G.relTickVsDrawn or -1,
    G.tickVsRender or -1, sv(G.sMine), sv(G.sTheirs), sv(G.sTheirsNode), sv(G.sRayEnd))
end
-- the photo orbit round our craft: shots from several sides
function TP.around(TG, nm, n, dist)
  local pc = findScript("planet_camera")
  if not pc then return end
  pc.setCamMode("free")
  if pc.params then pc.params.distance = dist end
  pc.setPhotoOrbit(true)
  pc.PHOTO_ORBIT_RATE = math.rad(30)
  wait(1.0)
  for k = 1, n do
    TP.geom(TG, nm .. k)
    TP.shot(nm .. k)
    wait(12 / n)
  end
  pc.setPhotoOrbit(false)
end
local function run_tdock()
  local TG = findScript("targeting")
  P("TP targeting script %s", tostring(TG ~= nil))
  local bp = TP.bp()
  local vc = launch_via_builder(bp, "pad", #bp)
  if not vc then P("TP RESULT no craft") return end
  TG = findScript("targeting")
  local vn = vc.node
  local fp = vc.fleetParts()
  local parts = TP.copy(fp.parts)
  P("TP craft on the pad: %d parts, ports %d (%s)", #parts, #vc.dockPorts(), tostring(vc.dock and #vc.dock.ports))
  -- ── to orbit ──
  vc.releaseClamps()
  vc.setSAS("stability")
  wait(0.5)
  local i, b, U, T = TP.frame(vn)
  local wd = save.get("world." .. b.name)
  local atmo = type(wd) == "table" and (wd.atmoHeight or 0) or 0
  local r = b.radius + math.max(atmo + 500, b.radius * 0.6)
  if (b.soi or -1) > 0 then r = math.min(r, b.soi * 0.5) end
  P("TP world %s R %.0f atmo %.0f soi %.0f mu %.1f: orbit r %.0f (alt %.0f)", b.name, b.radius, atmo, b.soi or -1, b.mu, r, r - b.radius)
  local o = i.origin
  local off = sub(o, b)
  local want = { x = b.x + U.x * r, y = b.y + U.y * r, z = b.z + U.z * r }
  assembly.teleport(vn, vec3(want.x + (o.x - i.com.x), want.y + (o.y - i.com.y), want.z + (o.z - i.com.z)))
  wait(0.3)
  local vcirc = math.sqrt(b.mu / r)
  -- (an impulse of dv × info.mass came out ~0.11 dv on rc 1364: the gain is
  -- measured on the first push and the rest are scaled by it)
  local gain = 1.0
  for k = 1, 10 do
    i, b, U, T = TP.frame(vn)
    local wv = scl(T, vcirc)
    local dv = sub(wv, i.vel)
    local dl = len(dv.x, dv.y, dv.z)
    P("TP push %d: vel (%.2f %.2f %.2f) want |v| %.2f, off by %.2f (gain %.3f)", k, i.vel.x, i.vel.y, i.vel.z, vcirc, dl, gain)
    if dl < 0.5 then break end
    local v0 = i.vel
    local s = i.mass / gain
    assembly.impulseAt(vn, vec3(dv.x * s, dv.y * s, dv.z * s), i.com)
    wait(0.6)
    local i2 = assembly.info(vn)
    local got = len(i2.vel.x - v0.x, i2.vel.y - v0.y, i2.vel.z - v0.z)
    if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
  end
  local el = space.elements(vn.x, vn.y, vn.z, vn.vx, vn.vy, vn.vz)
  P("TP orbit: pe %.0f ap %s alt %.0f", el and el.periapsis and (el.periapsis - b.radius) or -1,
    el and el.apoapsis and string.format("%.0f", el.apoapsis - b.radius) or "-", len(sub(i.com, b).x, sub(i.com, b).y, sub(i.com, b).z) - b.radius)
  -- ── the twin, `gap` m ahead, crooked ──
  i, b, U, T = TP.frame(vn)
  local rel = sub(i.origin, b)
  local gap = params.gap or 40
  local relB = { x = rel.x + T.x * gap + U.x * 1.5, y = rel.y + T.y * gap + U.y * 1.5, z = rel.z + T.z * gap + U.z * 1.5 }
  local Y = unit({ x = -T.x + U.x * 0.45, y = -T.y + U.y * 0.45, z = -T.z + U.z * 0.45 })
  local X = unit(cross(Y, U))
  local Z = cross(X, Y)
  local yaw, pitch, roll = eulerOf(X, Y, Z)
  local f = save.get("fleet.craft")
  if type(f) ~= "table" then f = {} end
  f.c900 = { name = "Target Twin", body = b.name, x = relB.x, y = relB.y, z = relB.z,
             vx = i.vel.x, vy = i.vel.y, vz = i.vel.z, pitch = pitch, yaw = yaw, roll = roll,
             landed = false, fuel = 0, charge = fp.charge or 0, parts = TP.copy(parts),
             stime = space.time(), pod = true, crew = false, probe = false, flown = true, comms = false }
  save.set("fleet.craft", f)
  local fo = findScript("flight_ops")
  fo.fleetRescan()
  local vB = wait_for(function() local v = fo.liveOf("c900"); return v and v.node and v.node.valid and #v.dockPorts() > 0 and v end, 40, "the twin")
  if not vB then P("TP RESULT no twin (shipyard.pilot %s)", tostring(save.get("shipyard.pilot"))) return end
  wait(3)
  local ia, ib = assembly.info(vn), assembly.info(vB.node)
  P("TP twin live: %d ports, %.2f m apart, rel speed %.3f m/s; still piloting A %s",
    #vB.dockPorts(), len(ia.com.x - ib.com.x, ia.com.y - ib.com.y, ia.com.z - ib.com.z),
    len(ia.vel.x - ib.vel.x, ia.vel.y - ib.vel.y, ia.vel.z - ib.vel.z), tostring(vc.piloting))
  -- ── target their top port, engage SAS Target ──
  TG.DEBUG_GEOM = true
  local okT, why = TG.targetPart(vB, 3)
  P("TP targetPart: %s %s | target %s | save %s", tostring(okT), tostring(why), TG.target and TG.target.name or "nil",
    json(save.get("target.sel")))
  wait(0.5)
  TP.shot("1target_set")
  vc.setSAS("target")
  wait(0.8)
  local cm = findScript("context_menu")
  P("TP prompt: open %s kind %s rows %d", tostring(cm.open), tostring(cm.target and cm.target.kind), #(cm.entries() or {}))
  for _, e in ipairs(cm.entries() or {}) do P("TP   row %s '%s' %s", e.id, e.label or "", tostring(e.hint)) end
  TP.shot("2port_prompt")
  local okp, whyp = cm.press("mine1")
  P("TP pressed Port 1: %s %s | ctrlPort %s | myPort %s", tostring(okp), tostring(whyp),
    TG.ctrlPort and tostring(TG.ctrlPort.uid) or "nil", tostring(TG.myPort(vc)))
  if not TG.myPort(vc) then TG.controlFrom(vc, 3) end
  TP.hold(TG, vc, params.holdsecs or 30, "dock")
  TP.geom(TG, "aligned")
  TP.shot("3dock_indicator")
  TP.around(TG, "3b_oblique", 3, 70)
  -- a lock that names our port too
  local L = vc.dock and vc.dock.lock
  P("TP dock lock: id %s uid %s mine %s by %s", tostring(L and L.id), tostring(L and L.uid), tostring(L and L.mine), tostring(L and L.by))
  -- ── the map ──
  local om = findScript("orbit_map")
  om.toggle()
  wait(2.0)
  TP.shot("4map_target")
  local sx, sy, _, on = camera.worldToScreen(vB.node.x, vB.node.y, vB.node.z)
  P("TP twin on the map at %s, %s (on %s)", tostring(sx), tostring(sy), tostring(on))
  if on then
    local pk = TG.mapPick(sx + 3, sy + 2)
    P("TP mapPick → %s %s", pk and pk.kind or "nil", pk and pk.label or "")
    if pk then
      P("TP map menu opened %s", tostring(TG.openMapMenu(pk, sx + 3, sy + 2)))
      wait(0.5)
      for _, e in ipairs(cm.entries() or {}) do P("TP   row %s '%s'", e.id, e.label or "") end
      TP.shot("5map_craft_menu")
      cm.close()
    end
  end
  -- a world on the map: zoom out until one other than ours is on screen
  local picked, zm = nil, 2e4
  for _ = 1, 30 do
    for _, bb in ipairs(space.bodies()) do
      if bb.name ~= b.name then
        local px, py, _, on2 = camera.worldToScreen(bb.x, bb.y, bb.z)
        local vx0, vy0, vw0, vh0 = camera.screenRect()
        if on2 and px and px > vx0 + 80 and px < vx0 + vw0 - 80 and py > vy0 + 80 and py < vy0 + vh0 - 160 then picked = { bb, px, py } break end
      end
    end
    if picked then break end
    zm = zm * 3
    if om.setZoom then om.setZoom(zm) end
    wait(0.5)
  end
  if picked then
    local pk = TG.mapPick(picked[2], picked[3])
    P("TP world %s on the map; mapPick → %s %s", picked[1].name, pk and pk.kind or "nil", pk and pk.label or "")
    if pk then
      TG.openMapMenu(pk, picked[2], picked[3])
      wait(0.5)
      for _, e in ipairs(cm.entries() or {}) do P("TP   row %s '%s'", e.id, e.label or "") end
      TP.shot("6map_world_menu")
      local oks, whys = cm.press("set")
      P("TP Set target on the map: %s %s | target %s | save %s", tostring(oks), tostring(whys),
        TG.target and TG.target.name or "nil", json(save.get("target.sel")))
      wait(1.0)
      TP.shot("7map_world_target")
    end
  else
    P("TP no other world came on screen")
  end
  om.toggle()
  wait(1.5)
  TP.shot("8edge_pin")
  -- ── Anti-target on the twin (the craft as a whole) ──
  TG.targetCraft(vB)
  vc.setSAS("antitarget")
  TP.hold(TG, vc, params.antisecs or 15, "anti")
  TP.shot("9antitarget")
  -- ── THE CAPTURE: our craft tilted ~10° off their axis with the stick, the
  -- twin put 0.9 m short of seating and 0.3 m off our axis at our speed; the
  -- soft capture straightens it, the hard dock seats it ──
  TG.targetPart(vB, 3)
  vc.setSAS("target")
  TP.hold(TG, vc, 8, "re-dock")
  vc.setSAS("stability")
  for _ = 1, 30 do
    local r = TG.readout
    if r and r.angle and r.angle >= 9 then break end
    key_down("w"); wait(0.12); key_up("w"); wait(0.6)
  end
  P("TP tilted: angle %.2f° roll %.2f°", TG.readout and TG.readout.angle or -1, TG.readout and TG.readout.roll or 0)
  local F = vc.partFrameNow(3)
  local Fb = vB.partFrameNow(3)
  local pa
  for _, q in ipairs(vc.dock.ports) do if q.uid == 3 then pa = q end end
  if F and Fb and pa then
    local ax = { x = F.rx * pa.ax + F.ux * pa.ay + F.zx * pa.az, y = F.ry * pa.ax + F.uy * pa.ay + F.zy * pa.az,
                 z = F.rz * pa.ax + F.uz * pa.ay + F.zz * pa.az }
    local side = unit(cross(ax, { x = F.rx, y = F.ry, z = F.rz }))
    local d0 = 0.28 + 0.9
    local want = { x = F.ox + ax.x * d0 + side.x * 0.3, y = F.oy + ax.y * d0 + side.y * 0.3, z = F.oz + ax.z * d0 + side.z * 0.3 }
    local ib = assembly.info(vB.node)
    assembly.teleport(vB.node, vec3(ib.origin.x + want.x - Fb.ox, ib.origin.y + want.y - Fb.oy, ib.origin.z + want.z - Fb.oz))
    -- (no speed match: the teleport keeps the twin's co-orbiting velocity, and
    -- assembly.info's vel of the twin is not its motion against ours — r8's
    -- "match" shoved it into our hull. The real relative speed, measured by
    -- the ports' positions a quarter second apart:)
    local function rel() local a2, b2 = vc.partFrameNow(3), vB.partFrameNow(3); return b2.ox - a2.ox, b2.oy - a2.oy, b2.oz - a2.oz end
    local x1, y1, z1 = rel(); wait(0.25); local x2, y2, z2 = rel()
    P("TP twin placed: relative speed %.3f m/s (measured)", len(x2 - x1, y2 - y1, z2 - z1) / 0.25)
    local pc = findScript("planet_camera")
    if pc then pc.setCamMode("free"); if pc.params then pc.params.distance = 9 end end
    TP.shot("10capture_start")
    local t0, nextp, shots = time, 0, { 1.0, 2.5 }
    while time - t0 < 15 do
      yield()
      if time - t0 >= nextp then
        nextp = nextp + 0.25
        local S, r = vc.dock.soft, TG.readout
        P("TP capture t %5.2f | soft %s gap %s misaligned %s° axis %s° drift %s | readout range %s angle %s roll %s | latched %d",
          time - t0, tostring(S ~= nil), S and string.format("%.3f", S.gap) or "-", S and string.format("%.2f", S.th) or "-",
          S and string.format("%.2f", S.ang) or "-", S and string.format("%.3f", S.drift) or "-",
          r and string.format("%.3f", r.range or -1) or "-", r and string.format("%.2f", r.angle or -1) or "-",
          r and string.format("%.1f", r.roll or 0) or "-", vc.dock.latched or 0)
      end
      if shots[1] and time - t0 >= shots[1] then table.remove(shots, 1); TP.shot(string.format("11capture_%.1fs", time - t0)) end
      if (vc.dock.latched or 0) > 0 then break end
    end
    wait(1.5)
    -- the seam as the merged craft records it: flush, coaxial, interleaved
    for _, p in ipairs(vc.dock.ports) do
      local q
      for _, o in ipairs(vc.dock.ports) do if o.uid == p.mate then q = o end end
      if q and p.uid < q.uid then
        local dc = len(p.x - q.x, p.y - q.y, p.z - q.z)
        local ang = math.deg(math.acos(math.max(-1, math.min(1, -(p.ax * q.ax + p.ay * q.ay + p.az * q.az)))))
        local off = len((q.x - p.x) - p.ax * dc, (q.y - p.y) - p.ay * dc, (q.z - p.z) - p.az * dc)
        local k1 = { vc.DOCKM.keyLocal(vc.partRec(p.uid)) }
        local k2 = { vc.DOCKM.keyLocal(vc.partRec(q.uid)) }
        local kd = math.deg(math.acos(math.max(-1, math.min(1, k1[1] * k2[1] + k1[2] * k2[2] + k1[3] * k2[3]))))
        P("TP SEAM ports %d+%d: centres %.4f m apart (flush = 0.28), axes %.3f° from opposed, off-axis %.4f m, petal keys %.1f° apart (interleaved: 60 mod 120)",
          p.uid, q.uid, dc, ang, off, kd)
      end
    end
    TP.shot("12docked")
    TP.around(TG, "13docked_oblique", 2, 7)
  else
    P("TP capture: no frames")
  end
  TG.clear()
  P("TP cleared: target %s save %s", tostring(TG.target), json(save.get("target.sel")))
end
