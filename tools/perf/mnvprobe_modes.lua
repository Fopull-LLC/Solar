-- ── maneuver-node probe (tools/perf/mnvprobe.sh): the click-and-drag node ──
-- mnvnode: a small rocket (pod, FT-S, Sputter) launched from the pad and put
--   on a circular orbit; the map opened; a simulated click on the orbit an
--   eighth of a period ahead places a node; each of the six handles dragged
--   along its stalk; the disc dragged along the orbit; a right-click tap opens
--   the node's menu (+1 / −1 orbit pressed); the gizmo photographed at three
--   map zooms; then warp to node, and the flight readout's WARP key.
--   Every frame while watching (lateUpdate, after the map has drawn), the
--   node's point is checked against the craft's own conic on the SCREEN
--   (the node must sit on the line) and the gizmo's disc against that point,
--   at ×1 and under ×100 warp, while the planet carries both.
-- One table (MP) and one entry: perfbench's main chunk is near the local
-- ceiling. Look for `MP` lines; pictures land in $WORK/proj/save/user/mnvshots/.
local MP = { tag = "mnv", fails = 0, watch = nil }
function MP.check(name, okc, fmt, ...)
  P("MP %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if not okc then MP.fails = MP.fails + 1 end
  return okc
end
function MP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://mnvshots/" .. MP.tag .. "_" .. nm .. ".png", bytes); P("MP SHOT %s_%s", MP.tag, nm)
    else P("MP SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function MP.frames(n) for _ = 1, n do yield() end end
function MP.mouse(x, y) input.simulate { mouse = { x, y } } end
function MP.btn(b, down) input.simulate { button = b, down = down } end
-- The craft's own conic `dt` s ahead, as a world point placed against this
-- frame's body (the line the map draws for it).
function MP.conic_at(vn, dt)
  local i = assembly.info(vn)
  local dn = space.dominant(i.origin.x, i.origin.y, i.origin.z)
  local b = space.body(dn)
  local rx, ry, rz = space.propagate(i.origin.x - b.x, i.origin.y - b.y, i.origin.z - b.z, i.vel.x, i.vel.y, i.vel.z, b.mu, dt)
  return b.x + rx, b.y + ry, b.z + rz
end
function MP.screen_at(vn, dt)
  local x, y, z = MP.conic_at(vn, dt)
  local sx, sy, _, on = camera.worldToScreen(x, y, z)
  return sx, sy, on
end
-- (lateUpdate: after the map's own pass when it runs first, the frame before
-- otherwise — both the line and the node are projected here with one camera)
function MP.sample()
  local W = MP.watch
  local om = W.om
  local R, S, G = om.mnvRel(), om.mnvState(), om.mnvGizmo()
  if not (R and S) then return end
  local bs = space.bodies()
  local b = bs[R.anchor]
  if not b then return end
  local nx, ny, nz = b.x + R.x, b.y + R.y, b.z + R.z
  local sx, sy, _, on = camera.worldToScreen(nx, ny, nz)
  if not on then return end
  -- the drawn conic near the node: 24 chords over ±3 % of the period
  local lead = S.t0 - space.time()
  local best = math.huge
  local px, py
  for k = -12, 12 do
    local qx, qy, qon = MP.screen_at(W.vn, lead + k * W.T * 0.0025)
    if qon and px then
      local dx, dy = qx - px, qy - py
      local l2 = dx * dx + dy * dy
      local u = l2 > 0 and math.max(0, math.min(1, ((sx - px) * dx + (sy - py) * dy) / l2)) or 0
      local ex, ey = px + dx * u - sx, py + dy * u - sy
      best = math.min(best, math.sqrt(ex * ex + ey * ey))
    end
    px, py = qx, qy
  end
  W.n = W.n + 1
  if best < math.huge then W.line = math.max(W.line, best); W.line_sum = W.line_sum + best end
  -- The disc against the node. This lateUpdate runs before the map's, so the
  -- disc on hand is the map's from the frame before: project the node at THAT
  -- frame's body read (kept from our pass then) with the camera the map left
  -- (it is not moved again until the map's pass this frame).
  if G and W.prev and W.prev.gt ~= G.t then
    local px0, py0, _, on0 = camera.worldToScreen(W.prev.bx + R.x, W.prev.by + R.y, W.prev.bz + R.z)
    if on0 and W.prev.anchor == R.anchor then
      local d = math.sqrt((G.sx - px0) ^ 2 + (G.sy - py0) ^ 2)
      local walked = W.prev.rx ~= R.x or W.prev.ry ~= R.y or W.prev.rz ~= R.z
      if walked then
        -- a new walk this frame: the disc is the old walk's point
        W.rewalks = (W.rewalks or 0) + 1
        P("MP rewalk: node moved %.3f m in its body's frame (disc %.2f px off the new point)",
          len(W.prev.rx - R.x, W.prev.ry - R.y, W.prev.rz - R.z), d)
      else
        W.disc = math.max(W.disc, d); W.disc_sum = W.disc_sum + d; W.nd = W.nd + 1
        if d > 2 then P("MP OUTLIER disc %.2f px at warp ×%d", d, space.warp()) end
      end
    end
  end
  W.prev = { bx = b.x, by = b.y, bz = b.z, anchor = R.anchor, gt = G and G.t, rx = R.x, ry = R.y, rz = R.z }
  -- how far the planet carried the node this frame, in the world
  if W.last then W.moved = W.moved + len(nx - W.last.x, ny - W.last.y, nz - W.last.z) end
  W.last = { x = nx, y = ny, z = nz }
end
function lateUpdate(_, _)
  if MP.watch then pcall(MP.sample) end
end
function MP.watch_for(om, vn, T, secs, tag)
  MP.watch = { om = om, vn = vn, T = T, n = 0, nd = 0, line = 0, line_sum = 0, disc = 0, disc_sum = 0, moved = 0 }
  local c0 = perf.scriptMs and perf.scriptMs("orbit_map")
  wait(secs)
  P("MP COST %s: orbit_map %.3f ms/frame (perf.scriptMs, before %.3f)", tag, perf.scriptMs and perf.scriptMs("orbit_map") or -1, c0 or -1)
  local W = MP.watch
  MP.watch = nil
  P("MP LOCK %s: %d frames, node carried %.0f m in the world; node vs the drawn conic max %.2f px (mean %.2f); disc vs the node max %.2f px (mean %.2f, %d same-frame samples); warp ×%d",
    tag, W.n, W.moved, W.line, W.line_sum / math.max(1, W.n), W.disc, W.disc_sum / math.max(1, W.nd), W.nd, space.warp())
  return W
end
-- Drag the mouse from (x0,y0) by (dx,dy) a frame for n frames, left button held.
function MP.drag(x0, y0, dx, dy, n)
  MP.mouse(x0, y0); MP.frames(3)
  MP.btn(0, true); MP.frames(2)
  local x, y = x0, y0
  for _ = 1, n do x, y = x + dx, y + dy; MP.mouse(x, y); yield() end
  MP.frames(2)
  MP.btn(0, false); MP.frames(3)
end
function MP.bp()
  return {
    rec(1, "pod", 0, 2.05, 0),
    rec(2, "tankS", 0, 1.15, 0, { parent = 1, att = "bottom" }),
    rec(3, "engineS", 0, 0.0, 0, { parent = 2, att = "bottom", stage = 0 }),
  }
end
function MP.to_orbit(vn)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local T = cross(U, { x = 0, y = 1, z = 0 })
  if len(T.x, T.y, T.z) < 0.1 then T = cross(U, { x = 1, y = 0, z = 0 }) end
  T = unit(T)
  local wd = save.get("world." .. b.name)
  local atmo = type(wd) == "table" and (wd.atmoHeight or 0) or 0
  local r = b.radius + math.max(atmo + 500, b.radius * 0.6)
  if (b.soi or -1) > 0 then r = math.min(r, b.soi * 0.5) end
  local o = i.origin
  local want = { x = b.x + U.x * r, y = b.y + U.y * r, z = b.z + U.z * r }
  assembly.teleport(vn, vec3(want.x + (o.x - i.com.x), want.y + (o.y - i.com.y), want.z + (o.z - i.com.z)))
  wait(0.3)
  local vcirc = math.sqrt(b.mu / r)
  local gain = 1.0
  for _ = 1, 10 do
    i = assembly.info(vn)
    b = home()
    U = unit(sub(i.com, b))
    local Tn = unit(cross(U, cross(T, U)))
    local dv = sub(scl(Tn, vcirc), i.vel)
    local dl = len(dv.x, dv.y, dv.z)
    if dl < 0.5 then break end
    local v0 = i.vel
    local s = i.mass / gain
    assembly.impulseAt(vn, vec3(dv.x * s, dv.y * s, dv.z * s), i.com)
    wait(0.6)
    local i2 = assembly.info(vn)
    local got = len(i2.vel.x - v0.x, i2.vel.y - v0.y, i2.vel.z - v0.z)
    if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
  end
  local io = assembly.info(vn)
  local el = space.elements(io.origin.x, io.origin.y, io.origin.z, io.vel.x, io.vel.y, io.vel.z)
  P("MP orbit about %s: r %.0f (alt %.0f), pe %.0f ap %s period %s", b.name, r, r - b.radius,
    el and el.periapsis and (el.periapsis - b.radius) or -1,
    el and el.apoapsis and string.format("%.0f", el.apoapsis - b.radius) or "-", el and el.period and string.format("%.0f", el.period) or "-")
  return el, r
end
function MP.run()
  MP.tag = params.tag or "mnv"
  local bp = MP.bp()
  local vc = launch_via_builder(bp, "pad", #bp)
  if not vc then MP.check("rollout", false, "no craft") P("MP RESULT FAIL") return end
  local vn = vc.node
  vc.releaseClamps()
  vc.setSAS("stability")
  vc.setThrottle(0)
  wait(0.5)
  local el = MP.to_orbit(vn)
  if not MP.check("orbit", el and el.period, "a closed orbit") then P("MP RESULT FAIL") return end
  local T = el.period
  local om = findScript("orbit_map")
  local cm = findScript("context_menu")
  om.toggle()
  wait(2.5)
  MP.shot("0map_open")
  -- F1: hover the line, then click. Where: the stretch of the first half
  -- orbit seen most squarely (prograde, radial and normal all long on the
  -- screen), so no handle is end-on and hidden behind the disc
  local lead0, best = T / 8, -1
  for k = 2, 9 do
    local L = T * k / 20
    local x0, y0, z0 = MP.conic_at(vn, L)
    local x1, y1, z1 = MP.conic_at(vn, L + T * 0.002)
    local io0 = assembly.info(vn)
    local bb = space.body(space.dominant(io0.origin.x, io0.origin.y, io0.origin.z))
    local tx, ty, tz = x1 - x0, y1 - y0, z1 - z0
    local tl = len(tx, ty, tz)
    local rx, ry, rz = x0 - bb.x, y0 - bb.y, z0 - bb.z
    local rl = len(rx, ry, rz)
    local nv = cross({ x = rx, y = ry, z = rz }, { x = tx, y = ty, z = tz })
    local nl = len(nv.x, nv.y, nv.z)
    local s0x, s0y, _, o0 = camera.worldToScreen(x0, y0, z0)
    local function sl(dx, dy, dz)
      local qx, qy, _, oq = camera.worldToScreen(x0 + dx, y0 + dy, z0 + dz)
      return (oq and o0) and math.sqrt((qx - s0x) ^ 2 + (qy - s0y) ^ 2) or 0
    end
    local a = sl(tx / tl * 50, ty / tl * 50, tz / tl * 50)
    local b2 = sl(rx / rl * 50, ry / rl * 50, rz / rl * 50)
    local c = sl(nv.x / nl * 50, nv.y / nl * 50, nv.z / nl * 50)
    local s = math.min(a, b2, c) / math.max(a, b2, c, 1e-6)
    local vx0, vy0, vw0, vh0 = camera.screenRect()
    local inside = o0 and s0x > vx0 + 200 and s0x < vx0 + vw0 - 260 and s0y > vy0 + 260 and s0y < vy0 + vh0 - 140
    P("MP spot +%.0f s: axes on screen %.1f / %.1f / %.1f px per 50 m (balance %.2f) %s", L, a, b2, c, s, inside and "" or "(near the edge)")
    if inside and s > best then lead0, best = L, s end
  end
  local sx, sy, on = MP.screen_at(vn, lead0)
  P("MP orbit point +%.0f s on screen at %.1f, %.1f (on %s)", lead0, sx or -1, sy or -1, tostring(on))
  MP.mouse(sx + 5, sy - 4); MP.frames(4)
  local G = om.mnvGizmo()
  local hv = om.GZ and om.GZ.hover
  MP.check("hover", hv ~= nil, "hovering 6 px off the orbit shows the ring at +%.1f s (want +%.0f)", hv and hv.t - space.time() or -1, lead0)
  MP.shot("1hover")
  MP.btn(0, true); MP.frames(2); MP.btn(0, false); MP.frames(3)
  local S = om.mnvState()
  MP.check("place", S and math.abs(S.lead - lead0) < T * 0.01 and S.dv == 0, "a click placed a node at +%.1f s (want +%.0f), %.2f m/s",
    S and S.lead or -1, lead0, S and S.dv or -1)
  wait(0.6)
  S = om.mnvState()
  MP.check("walked", S and S.fresh, "the walk caught up: post-burn Pe %s Ap %s", tostring(S and S.pe), tostring(S and S.ap))
  MP.watch_for(om, vn, T, 4, "x1")
  -- F3: each handle dragged outward along its stalk, 5 px a frame for 12 frames
  local before = om.mnvState()
  local got = {}
  for _, id in ipairs({ "pro+", "pro-", "nor+", "nor-", "rad+", "rad-" }) do
    G = om.mnvGizmo()
    local h = G and G.handles[id]
    if h and h.on then
      local dx, dy = h.x - G.sx, h.y - G.sy
      local l = math.sqrt(dx * dx + dy * dy)
      local s0 = om.mnvState()
      MP.drag(h.x, h.y, dx / l * 5, dy / l * 5, 12)
      local s1 = om.mnvState()
      got[id] = { pro = s1.pro - s0.pro, nor = s1.nor - s0.nor, rad = s1.rad - s0.rad }
      P("MP drag %s (stalk %.1f px): Δpro %+.2f Δnor %+.2f Δrad %+.2f m/s", id, l, got[id].pro, got[id].nor, got[id].rad)
    else
      P("MP drag %s: handle off screen", id)
    end
  end
  local function sgn(id, comp, s) return got[id] and got[id][comp] * s > 0.5 end
  MP.check("handles", sgn("pro+", "pro", 1) and sgn("pro-", "pro", -1) and sgn("nor+", "nor", 1) and sgn("nor-", "nor", -1)
    and sgn("rad+", "rad", 1) and sgn("rad-", "rad", -1), "every handle drags its own axis its own way")
  -- leave a real burn on it: +40 % more prograde
  G = om.mnvGizmo()
  local hp = G.handles["pro+"]
  local dxp, dyp = hp.x - G.sx, hp.y - G.sy
  local lp = math.sqrt(dxp * dxp + dyp * dyp)
  MP.drag(hp.x, hp.y, dxp / lp * 3, dyp / lp * 3, 20)
  wait(0.5)
  S = om.mnvState()
  P("MP node after the drags: pro %.1f nor %.1f rad %.1f (%.1f m/s), Pe %s Ap %s", S.pro, S.nor, S.rad, S.dv, tostring(S.pe), tostring(S.ap))
  MP.shot("2dragged")
  -- F4: the disc dragged along the orbit to +T/5
  G = om.mnvGizmo()
  local comp0 = { S.pro, S.nor, S.rad }
  MP.mouse(G.sx, G.sy); MP.frames(3)
  MP.btn(0, true); MP.frames(2)
  local l0 = S.lead
  for f = 1, 30 do
    local qx, qy = MP.screen_at(vn, l0 + (T / 5 - l0) * f / 30)
    MP.mouse(qx, qy); yield()
  end
  MP.frames(2)
  local mid = om.mnvGizmo()
  MP.shot("3sliding")
  MP.btn(0, false); MP.frames(3)
  S = om.mnvState()
  MP.check("slide", math.abs(S.lead - T / 5) < T * 0.01, "the disc slid the node to +%.1f s (want +%.0f)", S.lead, T / 5)
  MP.check("slide_dv", S.pro == comp0[1] and S.nor == comp0[2] and S.rad == comp0[3], "…keeping its Δv components")
  -- behind the craft: it stops at now + 1 s
  G = om.mnvGizmo()
  MP.mouse(G.sx, G.sy); MP.frames(3)
  MP.btn(0, true); MP.frames(2)
  for f = 1, 20 do
    local qx, qy = MP.screen_at(vn, S.lead - (S.lead + T * 0.05) * f / 20)
    MP.mouse(qx, qy); yield()
  end
  MP.frames(2)
  local Sb = om.mnvState()
  MP.check("slide_clamp", Sb.lead >= 0.9 and Sb.lead < 3, "slid behind the craft, it stops at +%.2f s", Sb.lead)
  -- back to +T/5
  for f = 1, 20 do
    local qx, qy = MP.screen_at(vn, T / 5 * f / 20)
    MP.mouse(qx, qy); yield()
  end
  MP.frames(2)
  MP.btn(0, false); MP.frames(3)
  wait(0.5)
  MP.watch_for(om, vn, T, 3, "x1 after edits")
  -- F6: a right-click tap on the disc opens the node's menu
  G = om.mnvGizmo()
  MP.mouse(G.sx, G.sy); MP.frames(4)
  MP.btn(1, true); MP.frames(3); MP.btn(1, false); MP.frames(6)
  MP.check("menu", cm.open and cm.target and cm.target.kind == "mnvnode", "a right-click on the node opens its menu (open %s kind %s)",
    tostring(cm.open), tostring(cm.target and cm.target.kind))
  for _, e in ipairs(cm.entries() or {}) do P("MP   row %s '%s' %s", e.id, e.label or "", tostring(e.enabled)) end
  wait(0.4)
  MP.shot("4menu")
  local la = om.mnvState().lead
  cm.press("orbit_up"); MP.frames(2)
  local lb = om.mnvState().lead
  MP.check("orbit_up", math.abs(lb - la - T) < T * 0.01, "+1 orbit: %.0f → %.0f s (period %.0f)", la, lb, T)
  cm.press("orbit_down"); MP.frames(2)
  MP.check("orbit_down", math.abs(om.mnvState().lead - la) < T * 0.01, "−1 orbit: back to %.0f s", om.mnvState().lead)
  cm.close()
  MP.frames(3)
  wait(0.6)
  -- three zooms: the closest that shows the gizmo, ×3 and ×10 of it
  local io = assembly.info(vn)
  local b = space.body(space.dominant(io.origin.x, io.origin.y, io.origin.z))
  local r = len(io.origin.x - b.x, io.origin.y - b.y, io.origin.z - b.z)
  local zc = r * 0.9
  for _ = 1, 12 do
    om.setZoom(zc); wait(0.8)
    if om.mnvGizmo() then break end
    zc = zc * 1.3
  end
  local zooms = { zc, zc * 3, zc * 10 }
  for k, z in ipairs(zooms) do
    om.setZoom(z); wait(1.2)
    local g = om.mnvGizmo()
    P("MP zoom %d: %.0f m, gizmo %s at %.1f, %.1f", k, z, tostring(g ~= nil), g and g.sx or -1, g and g.sy or -1)
    MP.watch_for(om, vn, T, 1.0, "zoom" .. k)
    MP.shot(string.format("5zoom%d", k))
  end
  om.setZoom(zooms[2]); wait(1.0)
  -- three orbits out (×100 for 2 s is 200 s of sim: the node must still be ahead)
  om.mnvOrbits(1); om.mnvOrbits(1); om.mnvOrbits(1)
  wait(0.6)
  P("MP node now +%.0f s", om.mnvState().lead)
  -- the planet carrying everything fast: ×100 rails warp, watched
  space.warp(100)
  local W100 = MP.watch_for(om, vn, T, 2, "x100")
  MP.shot("6warp100")
  space.warp(1)
  wait(0.5)
  MP.check("locked", W100.line < 3 and W100.disc < 3 and W100.n > 10,
    "under ×100 the node stays on the drawn line (max %.2f px) and the disc on the node (max %.2f px) over %d frames (planet carried it %.0f km)",
    W100.line, W100.disc, W100.n, W100.moved / 1000)
  -- F8: warp to node
  wait(0.6)
  S = om.mnvState()
  local tb = om.MNV.burnSecs(vc.tele, S.dv) or 0
  vc.setThrottle(0.5); MP.frames(3)
  local okr = om.warpToNode()
  MP.check("warp_refused", okr == false, "warp to node is refused with the throttle open")
  vc.setThrottle(0); MP.frames(3)
  MP.check("warp_start", om.warpToNode() == true, "warp to node starts (node in %.0f s, burn %.1f s)", S.lead, tb)
  local top, t0 = 1, W()
  local mid_shot = false
  while om.warpingToNode() and W() - t0 < 120 do
    yield(); top = math.max(top, space.warp())
    if not mid_shot and space.warp() >= 100 then mid_shot = true; MP.shot("7warping") end
  end
  local wr = {}
  for _ = 1, 6 do wr[#wr + 1] = tostring(space.warp()); yield() end
  P("MP warp in the frames after landing: %s (settling %s); the chip says: %s", table.concat(wr, " "),
    tostring(om.warpSettling and om.warpSettling()), tostring(findScript("warp_chip") and findScript("warp_chip").lastNotice))
  S = om.mnvState()
  local start_in = S.lead - tb / 2
  MP.check("warp_land", not om.warpingToNode() and space.warp() == 1 and start_in >= 9.0 and start_in < 13.5,
    "landed at ×%d with the burn starting in %.1f s (node − burn/2 − 10 s: want 10–12.5), top warp ×%d, %.1f s real",
    space.warp(), start_in, top, W() - t0)
  MP.shot("8landed")
  -- the flight readout's WARP key
  om.toggle(); wait(1.5)
  MP.shot("9flight_readout")
  P("MP RESULT %s: %s (%d failed check(s))", MP.tag, MP.fails == 0 and "PASS" or "FAIL", MP.fails)
end
