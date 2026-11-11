-- ── wood probe (tools/perf/woodprobe.sh; progression W1, Ty 11-11) ──────────
-- Spliced after vfxprobe_modes.lua, buildkitprobe_modes.lua and
-- kitprobe_modes.lua (VP, BK, KIT helpers) into a copy of perfbench.lua.
--   wood  the motorcycle (motoprobe's) launched and ridden 150 m out from the
--         base; 20 m ahead of it: both banks levelled and a trench dug across
--         its way (4.4 m wide, ~1.5 m deep); a 6 m timber bridge over it, in
--         the bike's frame: two 6 m beams (tops at the ground), three Bridge
--         Decks across them, fences down both sides, log posts at the corners.
--         Ridden across (the bike's height over the deck at mid-span, upright,
--         to the far bank); stepped off and WALKED back across on foot (the
--         walker's height at mid-span). Beside it a 4 x 4 m hut: plank floors,
--         timber walls, the Plank Door (hinged: it swings as you come near),
--         gables and shingle roof halves, a Sawbench inside. Planks: an order
--         at the Depot into the warehouse; a timber wall placed paid from them
--         (the quote's planks, the warehouse down by its mass); the Sawbench
--         sawing timber from the pack (the job runs, planks arrive). Pictures:
--         the bridge from the side, from the trench, the deck close, the bike
--         on it; the hut from two angles, inside, the door open.
-- One `BK PASS|FAIL <check>` line a check, `BK RESULT wood: PASS/FAIL`.
-- Pictures save/user/buildshots/wd*.png.
WD = {}

-- ── the motorcycle (motoprobe_modes.lua's, copied: its lateUpdate would clash) ──
local WX1, WY1, WZ1 = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
local function wd_neg(a) return { x = -a.x, y = -a.y, z = -a.z } end
function WD.defs()
  local R = findScript("parts_registry")
  local A = findScript("parts_auto")
  if not A then spawn("AutoLib", vec3(0, 0, 0)); A = wait_for(function() return findScript("parts_auto") end, 10, "parts_auto") end
  return function(id) return (A and A.PARTS and A.PARTS[id]) or (R and R.REG and R.REG[id]) end
end
function WD.member(id, a, b, o)
  local d = { x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }
  local L = len(d.x, d.y, d.z)
  local Y = unit(d)
  local X = unit(cross(Y, WZ1))
  if len(X.x, X.y, X.z) < 0.5 then X = WX1 end
  local r = prec(id, (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, X, Y, o)
  r.size = { len = L, prof = "box" }
  r.proc, r.prof = "member", "box"
  return r
end
function WD.bike()
  puid = 0
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local H = add(prec("hub", 0.18, 1.068, 0, WX1, WY1))
  local F = add(prec("forkT", 0.7416, 0.7564, 0, WX1, WY1, { parent = H.uid, att = "surface" }))
  add(prec("wheelB", 0.8022, 0.3497, 0, WZ1, WY1, { parent = F.uid, att = "surface" }))
  add(prec("packB", 0.12, 0.77, 0, WX1, WY1, { parent = H.uid, att = "surface" }))
  local hp, rp = { x = 0.18, y = 1.068, z = 0 }, { x = -0.03, y = 0.48, z = 0 }
  local sp = add(WD.member("beamP", hp, rp, { parent = H.uid, att = "surface" }))
  local R = add(prec("hub", rp.x, rp.y, 0, WX1, WY1, { parent = sp.uid, att = "surface" }))
  local A = add(prec("swingArm", -0.485, 0.4826, 0, wd_neg(WX1), WY1, { parent = R.uid, att = "surface" }))
  add(prec("wheelB", -0.75, 0.35, 0, wd_neg(WZ1), WY1, { parent = A.uid, att = "surface" }))
  local sh = { x = -0.30, y = 0.79, z = 0 }
  local sf = add(WD.member("beamP", rp, sh, { parent = R.uid, att = "surface" }))
  local S = add(prec("hub", sh.x, sh.y, 0, WX1, WY1, { parent = sf.uid, att = "surface" }))
  add(prec("saddle", sh.x, sh.y + 0.12 + 0.65, 0, WX1, WY1, { parent = S.uid, att = "top" }))
  return L
end
function WD.launch(list)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
  local def = WD.defs()
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local recs = {}
  for _, r in ipairs(list) do
    local d = def(r.id)
    if d then
      local f = full(r, d, k)
      if r.size then
        local PR = findScript("parts_registry")
        local sz = PR and PR.sizeOf and PR.sizeOf(d, r.size)
        f.size, f.proc, f.prof = r.size, r.proc, r.prof
        if sz then f.mass, f.cost, f.strength, f.rx, f.rz, f.h = sz.mass, sz.cost, sz.strength, sz.rx, sz.rz, sz.h end
      end
      recs[#recs + 1] = f
    end
  end
  save.set("shipyard.blueprint", { parts = recs, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local vc = wait_craft(#recs, 150)
  wait_regrade()
  return vc
end
function WD.upness(vn)
  local i = assembly.info(vn)
  local b = home()
  if not (i and b) then return 1 end
  local U = unit(sub(i.com, b))
  local up = i.up or vn:worldUp()
  return dot(unit({ x = up.x, y = up.y, z = up.z }), U)
end
-- ride out past `out` m from the base, steering away from it
function WD.out(vc, out)
  local vn = vc.node
  local u, _, _, R = base_frame()
  local function from_base()
    local p = sub(assembly.info(vn).com, home())
    return math.acos(clamp(dot(unit(p), u), -1, 1)) * R
  end
  local t0 = time
  while time - t0 < 90 do
    local i1 = assembly.info(vn)
    local Rh = unit(sub(i1.com, home()))
    local away = sub(Rh, scl(u, dot(Rh, u)))
    local v = i1.vel
    local vh = sub(v, scl(Rh, dot(v, Rh)))
    local st = 0
    if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
      away = unit(away)
      local sn = dot(cross(unit(vh), away), Rh)
      local cs = dot(unit(vh), away)
      if cs < 0.97 then st = (sn >= 0) and 0.5 or -0.5 end
    end
    vc.R2.cmd = { drive = 0.7, steer = st }
    yield()
    if from_base() > out then break end
    if WD.upness(vn) < 0.3 then return false end
  end
  return true
end
-- brake to a stop (drive held back while it rolls), at most `tmo` s → speed
function WD.stop(vc, tmo)
  local t0, calm, tl = time, 0, time
  local sp = 99
  while time - t0 < (tmo or 25) and calm < 1.0 do
    local v = assembly.info(vc.node).vel
    sp = len(v.x, v.y, v.z)
    -- (the stick against the way it rolls, forward or back: a reverse push while it ran
    -- backward only sped it up and laid it down)
    local _, F = WD.heading(vc)
    local vf = F and (v.x * F.x + v.y * F.y + v.z * F.z) or sp
    vc.R2.cmd = { drive = sp > 0.25 and (vf >= 0 and -0.5 or 0.5) or 0, steer = 0 }
    yield()
    if sp < 0.3 then calm = calm + (time - tl) else calm = 0 end
    tl = time
  end
  P("WD stopped: %.2f m/s after %.1f s", sp, time - t0)
  return sp
end
-- hold the brake for `secs` (while the probe builds round the bike)
function WD.hold(vc, secs)
  local t0 = time
  while time - t0 < secs do
    local v = assembly.info(vc.node).vel
    local _, F = WD.heading(vc)
    local vf = F and (v.x * F.x + v.y * F.y + v.z * F.z) or 0
    vc.R2.cmd = { drive = math.abs(vf) > 0.3 and (vf > 0 and -0.4 or 0.4) or 0, steer = 0 }
    yield()
  end
end
-- hold the bike still for `secs`
function WD.still(vc, secs)
  local t0 = time
  while time - t0 < secs do vc.R2.cmd = { drive = 0, steer = 0 }; yield() end
end
-- the bike's ground point and heading (front wheel minus rear), body-relative, this frame
function WD.heading(vc)
  local ws = {}
  for _, w in ipairs(vc.R2.wheels or {}) do if w.tyre and w.tyre.valid then ws[#ws + 1] = w end end
  table.sort(ws, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  -- (drawn poses for both ends: the node's place this frame against this frame's body,
  -- never assembly.info's tick pose against space.body: docs/positions-and-frames.md rule 2)
  local b = home()
  if #ws < 2 then return nil end
  -- (the tyres' drawn places: the vessel's root node lags the rails, docs rule "a node's own axes and position can lag")
  local w1, w2 = ws[1].tyre:toWorld(vec3(0, 0, 0)), ws[2].tyre:toWorld(vec3(0, 0, 0))
  local c = { x = (w1.x + w2.x) / 2, y = (w1.y + w2.y) / 2, z = (w1.z + w2.z) / 2 }
  local U = unit(sub(c, b))
  local f = sub(w1, w2)
  f = unit(sub(f, scl(U, dot(f, U))))
  return sub(c, b), f, U, c
end

-- ── the probe ───────────────────────────────────────────────────────────────
function WD.run()
  BK.tag = "wood"
  wait_ready(120)
  wait(2)
  BK.unlock()
  do local C0 = findScript("crew"); if C0 then C0.patch(C0.activeId(), { role = "engineer" }) end end
  local vc = WD.launch(WD.bike())
  if not BK.check("bike", vc ~= nil, "the motorcycle launched") then BK.result() return end
  vc.releaseClamps()
  WD.still(vc, 3)
  local fb, ST, C, KL, inv = findScript("field_builder"), findScript("structures"), findScript("crew"), findScript("kit_live"), findScript("inventory")
  local TBs = findScript("timber")
  if not BK.check("scene", fb and ST and KL and inv and TBs, "the kit, kit_live, inventory and timber are in the scene") then BK.result() return end
  C.patch(C.activeId(), { role = "engineer" })
  local okout = WD.out(vc, 150)
  -- stop dead before anything is measured: a coasting bike rolled 20 m on into the gap dug for it
  WD.stop(vc, 25)
  WD.still(vc, 1)
  if not BK.check("out", okout and WD.upness(vc.node) > 0.8, "ridden out 150 m, upright") then BK.result() return end
  -- ── the gap and the bridge, 20 m ahead along the bike's heading ──
  local p0, F, U = WD.heading(vc)
  if not BK.check("heading", p0 ~= nil, "the bike's heading") then BK.result() return end
  local b0 = home()
  local Rt = unit(cross(U, F))      -- (the structure's +X: kit_snap.frameOf's R = U x F)
  local function ground(p)      -- p body-relative → body-relative ground point under it (this frame)
    local b = home()
    local q = { x = b.x + p.x + U.x * 6, y = b.y + p.y + U.y * 6, z = b.z + p.z + U.z * 6 }
    local h = raycast(q.x, q.y, q.z, -U.x, -U.y, -U.z, 30, { ignore = { vc.node, astro() } })
    return h and { x = h.x - b.x, y = h.y - b.y, z = h.z - b.z } or nil
  end
  local nearG = ground({ x = p0.x + F.x * 16.6, y = p0.y + F.y * 16.6, z = p0.z + F.z * 16.6 })
  if not BK.check("bank", nearG ~= nil, "ground at the near bank") then BK.result() return end
  -- level both banks and the run-up to the near bank's plane, then dig the gap
  local function at(lz, lx, ly)   -- the bridge's frame (+Z along the bike's way, origin the near bank) → body-relative
    lx, ly = lx or 0, ly or 0
    return { x = nearG.x + F.x * lz + Rt.x * lx + U.x * ly, y = nearG.y + F.y * lz + Rt.y * lx + U.y * ly, z = nearG.z + F.z * lz + Rt.z * lx + U.z * ly }
  end
  local b = home()
  for _, lz in ipairs({ -12, -9, -6, -3, -0.5, 7.3, 9.8, 12.5, 15 }) do
    for _, lx in ipairs({ -2.5, 0, 2.5 }) do
      local q = at(lz, lx)
      terrain.sculpt(b.x + q.x, b.y + q.y, b.z + q.z, 2.4, 1.0, "flatten", { normal = vec3(U.x, U.y, U.z) })
    end
  end
  WD.hold(vc, 1.5)
  b = home()
  for _, lz in ipairs({ 2.6, 3.4, 4.2 }) do
    for _, lx in ipairs({ -3.6, -2.4, -1.2, 0, 1.2, 2.4, 3.6 }) do
      local q = at(lz, lx, -0.2)
      terrain.dig(b.x + q.x, b.y + q.y, b.z + q.z, 1.4, 1.0)
    end
  end
  WD.hold(vc, 1.0)
  b = home()
  for _, lx in ipairs({ -2.4, -1.2, 0, 1.2, 2.4 }) do     -- (a second pass, deeper, down the middle)
    local q = at(3.4, lx, -1.0)
    terrain.dig(b.x + q.x, b.y + q.y, b.z + q.z, 1.2, 1.0)
  end
  WD.hold(vc, 2.5)
  local mid = ground(at(3.4, 0, 0))
  local depth = mid and dot(sub(at(3.4, 0, 0), mid), U) or 0
  BK.check("gap", depth > 0.8, "a gap dug across the way: %.2f m deep at mid-span", depth)
  -- the bridge (the first piece founds its structure in the bike's frame)
  local co = findScript("company")
  if co and co.earn then co.earn(50000, "probe") end
  local q1 = at(6.8 - 0.3, -2.25)
  local sid, why = fb.place(nil, "post3.wood", { body = b0.name, x = q1.x, y = q1.y, z = q1.z, up = U, fwd = F, sup = U, fwd0 = F, mode = "grid" }, "money")
  if not BK.check("found", sid ~= nil, "a log post founds the bridge's structure (%s)", tostring(why)) then BK.result() return end
  local rec = ST.get(sid)
  local p1 = rec.bp[1]
  -- (the structure's frame: its origin the first post's ground point, +Z the bike's way)
  local function put(id, lx, ly, lz, yaw, tag)
    local s2, w2, q, uid = fb.place(sid, id, { body = rec.b, mode = "face", sid = sid, lx = lx, ly = ly, lz = lz, yaw = yaw or 0, pitch = 0, roll = 0 }, "money")
    if not s2 then P("WD %s refused: %s", tag or id, tostring(w2)) end
    return uid, q
  end
  -- local coordinates relative to the near bank (the post is at lz 6.5, lx -2.25)
  local function L(lx, lz) return lx - (-2.25) + p1.x, lz - 6.5 + p1.z end
  local n = 0
  for _, sx in ipairs({ -0.8, 0.8 }) do
    local x, z = L(sx, 3.4)
    if put("beam6w.wood", x, p1.y - 0.3, z, math.pi / 2, "beam") then n = n + 1 end
  end
  for _, dz in ipairs({ 1.4, 3.4, 5.4 }) do
    local x, z = L(0, dz)
    if put("deck24.wood", x, p1.y, z, math.pi / 2, "deck") then n = n + 1 end
  end
  for _, sx in ipairs({ -1.95, 1.95 }) do
    for _, dz in ipairs({ 1.4, 3.4, 5.4 }) do
      local x, z = L(sx, dz)
      if put("fence.wood", x, p1.y + 0.1, z, sx < 0 and -math.pi / 2 or math.pi / 2, "fence") then n = n + 1 end
    end
  end
  for _, c4 in ipairs({ { -2.25, 0.3 }, { 2.25, 0.3 }, { 2.25, 6.5 } }) do
    local x, z = L(c4[1], c4[2])
    if put("post3.wood", x, p1.y, z, 0, "post") then n = n + 1 end
  end
  rec = ST.get(sid)
  BK.check("bridge", n == 14 and #rec.bp == 15, "a 6 m timber bridge: two beams, three decks, six fences, four posts (%d pieces)", #rec.bp)
  WD.hold(vc, 2.0)
  -- a ray down at mid-span lands on the deck
  local function lw(lx, ly, lz) local x, z = L(lx, lz); return KIT.w(rec, x, ly, z) end
  do
    local top, bot = lw(0, 3, 3.4), lw(0, -3, 3.4)
    local d = sub(bot, top)
    local Ld = len(d.x, d.y, d.z)
    local h = raycast(top.x, top.y, top.z, d.x / Ld, d.y / Ld, d.z / Ld, Ld, { ignore = { vc.node, astro() } })
    local hy = h and select(2, KIT.l(rec, h)) or -9
    BK.check("deck_hit", h and math.abs(hy - (p1.y + 0.1)) < 0.06, "a ray down at mid-span stops on the deck (local y %.3f, deck top %.3f)", hy, p1.y + 0.1)
  end
  -- pictures of the bridge before the ride
  local function v(nm, eye, tgt)
    local ex, ez = L(eye[1], eye[3])
    local tx, tz = L(tgt[1], tgt[3])
    KIT.view(nm, rec, { ex, p1.y + eye[2], ez }, { tx, p1.y + tgt[2], tz })
  end
  -- ── ride across ──
  do
    local _, _, _, cw = WD.heading(vc)
    local lx0, _, lz0 = KIT.l(rec, cw)
    P("WD ride from bridge (%.2f, %.2f): the near bank %.1f m ahead (built 16.6 m ahead)", lx0 - p1.x - 2.25, lz0 - p1.z + 6.5, -(lz0 - p1.z + 6.5))
  end
  local minY, maxZ, fell, shot, h0 = 99, -99, false, false, nil
  local t0 = time
  while time - t0 < 25 do
    local _, _, _, c = WD.heading(vc)     -- (the tyres' mid point, drawn, as KIT.l's frame is)
    c = c or vc.node.worldPos
    local lx0, ly0, lz0 = KIT.l(rec, c)
    local bx, bz = lx0 - p1.x + (-2.25), lz0 - p1.z + 6.5      -- the bridge frame
    h0 = h0 or (ly0 - p1.y)      -- (the bike's root over the ground on the run-up: its ride height)
    if bz > 1.6 and bz < 5.2 then minY = math.min(minY, ly0 - p1.y) end
    maxZ = math.max(maxZ, bz)
    -- steer onto the centre line, a point 5 m ahead on it
    local tgt = lw(0, 0, math.max(bz + 5, 0))
    local Rh = unit(sub(c, home()))
    local vv = assembly.info(vc.node).vel
    local vh = sub(vv, scl(Rh, dot(vv, Rh)))
    local d = sub(tgt, c)
    d = sub(d, scl(Rh, dot(d, Rh)))
    local st = 0
    if len(vh.x, vh.y, vh.z) > 0.5 and len(d.x, d.y, d.z) > 0.1 then
      -- (+ steer turns it toward the side the cross product names: motoprobe's mp_out rule)
      st = clamp(dot(cross(unit(vh), unit(d)), Rh) * 1.8, -0.6, 0.6)
    end
    vc.R2.cmd = { drive = bz < 9 and 0.45 or 0.2, steer = st }
    if time >= (WD.nextl or 0) then WD.nextl = time + 0.5; P("WD ride bx %.2f bz %.2f y %.2f steer %.2f v %.1f up %.2f", bx, bz, ly0 - p1.y, st, len(vv.x, vv.y, vv.z), WD.upness(vc.node)) end
    yield()
    if WD.upness(vc.node) < 0.3 then fell = true break end
    if not shot and bz > 2.6 then
      shot = true
      VP.cam_fixed(sub(lw(7.5, 1.6, 2.4), home()), sub(lw(0, 0.6, 3.4), home()))
      wait(0.05); BK.shot("wd5_bike_on_bridge", false); VP.cam_off()
    end
    if bz > 10.5 then break end
  end
  WD.stop(vc, 15)
  BK.check("ride", not fell and maxZ > 8.5 and minY > -0.3, "ridden across: to %.1f m (the far bank 6.8), its root %.2f m over the bridge's base at mid-span (%.2f on the run-up: the deck is 0.1 over the ground, the gap 1.4 under it), upright %s",
    maxZ, minY, h0 or -9, tostring(not fell))
  v("wd1_bridge_side", { 9, 2.2, 1.0 }, { 0, 0, 3.4 })
  v("wd2_bridge_end", { 0.6, 1.7, -5 }, { 0, 0.3, 4 })
  v("wd4_deck_close", { 1.2, 1.1, 2.0 }, { 0.2, 0.1, 3.0 })
  -- ── step off, walk back across ──
  -- (EVA is refused while the bike rolls: brake, step off, again if it crept)
  for _ = 1, 4 do
    WD.stop(vc, 8)
    input.simulate { key = "f", down = true }; WD.hold(vc, 0.2); input.simulate { key = "f", down = false }; WD.hold(vc, 0.5)
    if not vc.crewAboard then break end
  end
  wait_for(function() return not vc.crewAboard end, 3, "EVA")
  wait(1.5)
  -- (beside the parked bike, not on it: 1.2 m to the side, on the far approach)
  do local x, z = L(1.2, 8.2); KIT.tp(rec, x, z, p1.y) end
  do local x0, y0, z0 = KIT.at(rec); P("WD walker at bridge (%.2f, %.2f, %.2f)", x0 - p1.x - 2.25, y0 - p1.y, z0 - p1.z + 6.5) end
  local wmin = 99
  local function watch()
    local lx0, ly0, lz0 = KIT.l(rec, astro())
    local bz = lz0 - p1.z + 6.5
    if bz > 1.6 and bz < 5.2 then wmin = math.min(wmin, ly0 - p1.y) end
  end
  local wx, wz = L(0.3, -1.5)
  local reached = KIT.walk(rec, wx, wz, 25, 0.7, watch)
  do local x0, y0, z0 = KIT.at(rec); P("WD walker ended at bridge (%.2f, %.2f, %.2f)", x0 - p1.x - 2.25, y0 - p1.y, z0 - p1.z + 6.5) end
  BK.check("walk", reached and wmin > 0.5 and wmin < 1.6, "walked back across on foot: reached the near bank %s, the walker's centre %.2f m over the deck's base at mid-span", tostring(reached), wmin)
  -- ── the hut, 8 m to the side of the near bank ──
  local hx0, hz0 = L(9.0, -1.0)
  local HB = {}
  local function hut(id, x, y, z, yaw)
    local uid = put(id, hx0 + x, p1.y + y, hz0 + z, yaw or 0, id)
    HB[#HB + 1] = uid
    return uid
  end
  -- (the hut stands on the bridge's structure: one record, its own floor)
  for _, s in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do hut("plankFloor.wood", s[1], 0, s[2]) end
  local FT, WT2 = 0.08, 2.28
  local door = hut("hutDoor.wood", -1, FT, 2, 0)
  hut("windowWall.wood", 1, FT, 2, 0)
  hut("wall.wood", -1, FT, -2, math.pi); hut("wall.wood", 1, FT, -2, math.pi)
  hut("wall.wood", 2, FT, -1, math.pi / 2); hut("wall.wood", 2, FT, 1, math.pi / 2)
  hut("wall.wood", -2, FT, -1, -math.pi / 2); hut("wall.wood", -2, FT, 1, -math.pi / 2)
  for _, sx in ipairs({ -1, 1 }) do
    hut("shingleRoof.wood", sx, WT2, 1, math.pi)
    hut("shingleRoof.wood", sx, WT2, -1, 0)
  end
  hut("gable.wood", 2, WT2, 1, math.pi / 2); hut("gable.wood", 2, WT2, -1, -math.pi / 2)
  hut("gable.wood", -2, WT2, -1, -math.pi / 2); hut("gable.wood", -2, WT2, 1, math.pi / 2)
  hut("sawbench.wood", 0.6, FT, -1.2, 0)
  local nh = 0
  for _, u in ipairs(HB) do if u then nh = nh + 1 end end
  BK.check("hut", nh == #HB, "a 4 x 4 m hut: floors, walls, the plank door, a window, shingle roof, gables, a sawbench (%d of %d)", nh, #HB)
  wait(2.0)
  local RL, RA = findScript("rooms"), findScript("room_air")
  local st = RA and RA.state and RA.state(sid)
  local sealed = 0
  for _, r in ipairs((st and st.R and st.R.rooms) or {}) do if r.sealed then sealed = sealed + 1 end end
  BK.check("leaky", sealed == 0, "the timber hut holds no air (sealed rooms %d)", sealed)
  local function hv(nm, eye, tgt) KIT.view(nm, rec, { hx0 + eye[1], p1.y + eye[2], hz0 + eye[3] }, { hx0 + tgt[1], p1.y + tgt[2], hz0 + tgt[3] }) end
  hv("wd6_hut_front", { -4.5, 2.0, 7.5 }, { 0, 1.4, 0 })
  hv("wd7_hut_back", { 6.5, 3.2, -6.0 }, { 0, 1.6, 0 })
  -- walk up to the door: it swings open
  do KIT.tp(rec, hx0 - 1.0, hz0 + 4.5, p1.y) end
  local e = KL.entries and KL.entries()[tostring(sid) .. ":" .. tostring(door)]
  local yaw_open = 0
  local function dwatch() if e and e.doors[1] and e.doors[1].node.valid ~= false then yaw_open = math.max(yaw_open, math.abs(e.doors[1].node.yaw or 0)) end end
  local inside = KIT.walk(rec, hx0 - 1.0, hz0 + 0.6, 12, 0.5, dwatch)
  BK.check("door", e ~= nil and yaw_open > math.rad(60), "the plank door swung %.0f° as the walker came through (inside %s)", math.deg(yaw_open), tostring(inside))
  hv("wd8_hut_inside", { -1.4, 1.6, 1.2 }, { 1.0, 1.0, -1.6 })
  KIT.view("wd9_door_open", rec, { hx0 - 1.0, p1.y + 1.6, hz0 + 5.0 }, { hx0 - 1.0, p1.y + 1.1, hz0 + 1.8 })
  -- ── planks: the Depot, a wall paid with them, the saw ──
  local before = inv.count("base", "plank") or 0
  local okb, wb = TBs.orderPlanks(500)
  local after = inv.count("base", "plank") or 0
  BK.check("depot", okb and after - before == 500, "500 kg of planks ordered from the Depot (%s): warehouse %d → %d", tostring(wb), before, after)
  local fund0 = co.balance()
  local wuid, q = put("wall.wood", hx0 + 3.0, p1.y + FT, hz0 + 1.0, math.pi / 2, "planked wall")
  local after2 = inv.count("base", "plank") or 0
  BK.check("planks_pay", wuid and q and q.planks == 106 and after - after2 == 106 and math.abs(fund0 - co.balance() - q.total) <= 1,
    "a timber wall paid from the warehouse: %s kg of planks (warehouse %d → %d) + $%s fittings", tostring(q and q.planks), after, after2, tostring(q and q.total))
  -- the saw: 2 timber from the pack, by hand
  local pack = C.packOf and C.packOf(C.activeId()) or "astro"
  inv.add(pack, "timber", 2)
  local saw
  rec = ST.get(sid)
  for _, p in ipairs(rec.bp) do if p.id == "sawbench.wood" then saw = p end end
  local okS, whyS = TBs.startSaw(sid, saw and saw.uid, 2, { kind = "crew", id = C.activeId(), pack = pack })
  local p_before = inv.count("base", "plank") or 0
  wait(14)
  local jobs = save.get("timber.saw") or {}
  local made = jobs[1] and jobs[1].made or 0
  local p_after = inv.count("base", "plank") or 0
  BK.check("saw", okS and made >= 1 and p_after > p_before, "the Sawbench saws 2 timber by hand (%s): %d kg made in 14 s, warehouse +%d", tostring(whyS), made, p_after - p_before)
  local okT = TBs.stopSaw(sid, saw.uid, { kind = "crew", id = C.activeId(), pack = pack })
  BK.check("saw_stop", okT and #(save.get("timber.saw") or {}) == 0, "stopped: the job is gone, the unsawn timber back")
  -- the menu on the bench (its rows through the registry)
  local snode = ST.nodeOf and ST.nodeOf(sid, saw.uid)
  local ents = snode and KIT.menu(snode) or {}
  local has = false
  for _, en in ipairs(ents) do if tostring(en.id or ""):find("tb_go", 1, true) then has = true end end
  BK.check("saw_menu", has, "the Sawbench's menu offers to saw (%d rows)", #ents)
  BK.result()
end
