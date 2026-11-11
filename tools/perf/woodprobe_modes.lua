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
--         (W2, the load model, kit_load.lua) the ride is watched: the beams'
--         r while the bike is on the bridge (it creaks and holds: 0.7 < r <
--         1.0, a creak heard, nothing broken); the walker is quiet. At the end
--         a steel deck on steel pillars beside the hut is walked on (r < 0.5,
--         no sag, no creak), then the bike is boarded again, put back on the
--         middle of the span (teleported: at a crawl it stuck at the deck's lip), and
--         1.3 t of cargo goes into its hold (a fuelled hopper's weight): the
--         beams go over 1.0, sag, creak and splinter, and break; the decks
--         over the gap come down and the bike drops into it.
--   woodlook  (W2) a timber hut, a deck and a fence on flat ground in clear
--         daylight (warped to a high sun): one view at 6 m in its plants, then
--         with the plants off (the forest hid it, the mushrooms shaded it)
--         from 3, 6, 20 and 60 m with the sun behind the camera and 20 m on its
--         shaded side (wl*.png): the before/after of the board look.
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
  local BEAMS = {}
  for _, sx in ipairs({ -0.8, 0.8 }) do
    local x, z = L(sx, 3.4)
    -- (W2: the beams sunk 0.35 so the deck stands 5 cm over the banks: its 10 cm lip either
    -- flipped the bike (fast) or stalled and turned it (slow) in four runs of eight; flush, the
    -- walker stuck at a bump on the far bank)
    local bu = put("beam6w.wood", x, p1.y - 0.35, z, math.pi / 2, "beam")
    if bu then n = n + 1; BEAMS[bu] = true end
  end
  for _, dz in ipairs({ 1.4, 3.4, 5.4 }) do
    local x, z = L(0, dz)
    if put("deck24.wood", x, p1.y - 0.05, z, math.pi / 2, "deck") then n = n + 1 end
  end
  for _, sx in ipairs({ -1.95, 1.95 }) do
    for _, dz in ipairs({ 1.4, 3.4, 5.4 }) do
      local x, z = L(sx, dz)
      if put("fence.wood", x, p1.y + 0.05, z, sx < 0 and -math.pi / 2 or math.pi / 2, "fence") then n = n + 1 end
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
    BK.check("deck_hit", h and math.abs(hy - (p1.y + 0.05)) < 0.06, "a ray down at mid-span stops on the deck (local y %.3f, deck top %.3f: 5 cm over the banks)", hy, p1.y + 0.05)
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
  -- (W2) what the load model says of the beams while the bike is on them
  local KLd = findScript("kit_load")
  local LW = { r = 0, sag = 0, n = 0 }
  local function load_watch(t)
    if not KLd then return end
    local res, L = KLd.lastResult(sid)
    if res and L and time - L.t < 0.6 then
      for u in pairs(BEAMS) do
        local R = res[u]
        if R and R.r then
          if R.r > t.r then t.span = R.span end
          t.r = math.max(t.r, R.r); t.n = t.n + 1
        end
      end
    end
    for u in pairs(BEAMS) do
      local st = KLd.stateOf(sid, u)
      if st then t.sag = math.max(t.sag, st.cur or 0) end
    end
  end
  local ks0 = KLd and KLd.stats() or { creaks = 0, broke = 0 }
  local creaks0, broke0 = ks0.creaks, ks0.broke
  local minY, maxZ, fell, shot, h0 = 99, -99, false, false, nil
  local t0 = time
  while time - t0 < 25 do
    load_watch(LW)
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
    -- (W2: held near 5.5 m/s from 9 m before the deck: at 7.7 m/s its 10 cm lip flipped the bike, at a crawl it stalled on it)
    local spd = len(vv.x, vv.y, vv.z)
    vc.R2.cmd = { drive = bz < -9 and 0.45 or (bz < 9 and (spd > 5.5 and -0.3 or 0.4) or 0.2), steer = st }
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
  do
    local ks = KLd and KLd.stats() or { creaks = 0, broke = 0 }
    P("WD LOAD ride: beams' worst r %.2f (%d readings, span %.2f m), sag %.1f cm, creaks %d, broke %d, the craft %.3f t over %s point(s)", LW.r, LW.n, LW.span or -1, LW.sag * 100, ks.creaks - creaks0, ks.broke - broke0, ks.craftT or -1, tostring(ks.craftPts))
    -- (it creaks when the gap is dug wide (5.3 m: r 0.74), not when narrow (4.3 m: r 0.36); it always holds)
    local creaked = ks.creaks > creaks0
    BK.check("load_bike", KLd ~= nil and LW.n > 0 and LW.r > 0.25 and LW.r < 1.0 and ks.broke == broke0 and creaked == (LW.r > 0.7) and (LW.sag > 0) == (LW.r > 0.7),
      "the bike on the 6 m timber bridge holds (beams' worst r %.2f over a %.2f m span; %d creak(s), sag %.1f cm: creak and sag only over 0.7; nothing broke)", LW.r, LW.span or -1, ks.creaks - creaks0, LW.sag * 100)
  end
  BK.check("ride", not fell and maxZ > 8.5 and minY > -0.3, "ridden across: to %.1f m (the far bank 6.8), its root %.2f m over the bridge's base at mid-span (%.2f on the run-up: the deck 5 cm over the banks, the gap 1.5 under it), upright %s",
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
  local WW = { r = 0, sag = 0, n = 0 }
  local function watch()
    local lx0, ly0, lz0 = KIT.l(rec, astro())
    local bz = lz0 - p1.z + 6.5
    if bz > 1.6 and bz < 5.2 then wmin = math.min(wmin, ly0 - p1.y) end
    load_watch(WW)
  end
  local wx, wz = L(0.3, -1.5)
  local reached = KIT.walk(rec, wx, wz, 25, 0.7, watch)
  do local x0, y0, z0 = KIT.at(rec); P("WD walker ended at bridge (%.2f, %.2f, %.2f)", x0 - p1.x - 2.25, y0 - p1.y, z0 - p1.z + 6.5) end
  BK.check("load_walker", WW.n > 0 and WW.r < 0.7 and WW.sag < 0.001, "a walker on the bridge: quiet (beams' worst r %.2f, %d readings)", WW.r, WW.n)
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
  WD.steel_and_heavy(vc, sid, rec, p1, L, lw, BEAMS, put)
  BK.result()
end

-- (W2) a steel deck on steel pillars (unaffected), then the bike back on the
-- span with 1.3 t in its hold: it sags, creaks, breaks
function WD.steel_and_heavy(vc, sid, rec0, p1, L, lw, BEAMS, put)
  local ST, KLd, C = findScript("structures"), findScript("kit_load"), findScript("crew")
  if not BK.check("kit_load", KLd ~= nil, "kit_load is in the scene") then return end
  BK.check("none_broke", KLd.stats().broke == 0, "nothing broke under the bike, the walker or the hut (%d broke)", KLd.stats().broke)
  -- ── steel: four pillars and a floor on them, 14 m beside the near bank ──
  local sx0, sz0 = L(-12.0, -1.0)
  local SU = {}
  for _, c in ipairs({ { -0.85, -0.85 }, { 0.85, -0.85 }, { -0.85, 0.85 }, { 0.85, 0.85 } }) do
    SU[#SU + 1] = put("pillar2.steel", sx0 + c[1], p1.y, sz0 + c[2], 0, "steel pillar")
  end
  local fu = put("floor.steel", sx0, p1.y + 2.2, sz0, 0, "steel floor")
  local rec = ST.get(sid)
  local fp = fu and ST.getPart(sid, fu)
  BK.check("steel_built", fu ~= nil and #SU == 4, "a steel floor on four steel pillars (floor at local y %.2f)", fp and fp.y or -9)
  local ks0 = {}
  for k, v in pairs(KLd.stats()) do ks0[k] = v end
  if fp then
    wait(2.0)      -- (the floor's node and collider land a frame or more after the placement)
    KIT.tp(rec, fp.x + 0.3, fp.z + 0.2, fp.y + 0.2)
    local worst, n, sag = 0, 0, 0
    local t0 = time
    while time - t0 < 4 do
      local res, Lr = KLd.lastResult(sid)
      if res and Lr and time - Lr.t < 0.6 and res[fu] then worst = math.max(worst, res[fu].r or 0); n = n + 1 end
      local st = KLd.stateOf(sid, fu)
      if st then sag = math.max(sag, st.cur or 0) end
      yield()
    end
    local ks = KLd.stats()
    do local x0, y0, z0 = KIT.at(rec); P("WD steel: walker at local (%.2f, %.2f, %.2f), floor top %.2f · kit_load walker ticks %d, on a piece %d", x0, y0, z0, fp.y + 0.2, ks.walker - (ks0.walker or 0), ks.walkerOn - (ks0.walkerOn or 0)) end
    BK.check("steel_quiet", n > 0 and worst < 0.5 and sag < 0.001 and ks.creaks == ks0.creaks,
      "a walker on the steel floor: r %.3f (%d readings), no sag (%.1f mm), no creak (%d)", worst, n, sag * 1000, ks.creaks - ks0.creaks)
    KIT.view("wd12_steel_deck", rec, { fp.x + 5, p1.y + 3.0, fp.z + 5 }, { fp.x, p1.y + 1.6, fp.z })
  end
  -- ── the bike back onto the span, heavy ──
  local vn = vc.node
  if not (vn and vn.valid) then BK.check("heavy", false, "the bike is gone") return end
  -- board it (beside it, then boardNow)
  do
    local _, _, _, cw = WD.heading(vc)
    local lx0, _, lz0 = KIT.l(rec, cw or vn.worldPos)
    KIT.tp(rec, lx0 + 0.9, lz0, p1.y)
  end
  local boarded = vc.boardNow and vc.boardNow()
  for _ = 1, 120 do
    if boarded then break end
    local ii = assembly.info(vn)
    local aa = astro()
    aa.x, aa.y, aa.z = ii.com.x, ii.com.y, ii.com.z
    yield()
    boarded = vc.boardNow()
  end
  if not BK.check("reboard", boarded and vc.piloting, "the rider boards the bike again (piloting %s)", tostring(vc.piloting)) then return end
  wait(1.5)
  -- put it back on the bridge, its tyres on the middle deck at mid-span, as it faced
  do
    -- (the target body-relative, as struct_live pins a structure's vessel; the bike stands
    -- still, so its tick origin and its tyres' drawn places differ by what the frame's carry
    -- does, and the second pass below takes out what is left)
    -- (assembly.teleport places the assembly's ORIGIN, which is not its root node's place:
    -- the node's drawn position put the tyres 1.5 m short every time)
    local root = assembly.info(vn).origin
    local _, _, _, cw = WD.heading(vc)
    local off = sub(root, cw)
    local tgt = lw(0, 0.45, 3.4)      -- (the tyres on the middle deck at mid-span: riding there at a crawl stuck at the deck's lip)
    assembly.teleport(vn, vec3(tgt.x + off.x, tgt.y + off.y, tgt.z + off.z))
    vc.R2.cmd = { drive = 0, steer = 0 }
    wait(2.0)
    -- (a second pass corrects what the first missed by: the root's and the tyres' drawn places
    -- are a frame apart in the handle)
    do
      local _, _, _, c1 = WD.heading(vc)
      if c1 then
        local want = lw(0, 0.45, 3.4)
        local root2 = assembly.info(vn).origin
        assembly.teleport(vn, vec3(root2.x + want.x - c1.x, root2.y + want.y - c1.y, root2.z + want.z - c1.z))
        wait(1.5)
      end
    end
    local _, _, _, c2 = WD.heading(vc)
    local lx2, ly2, lz2 = KIT.l(rec, c2 or vn.worldPos)
    P("WD teleported: the tyres at bridge (%.2f, %.2f, %.2f), upright %.2f", lx2 - p1.x - 2.25, ly2 - p1.y, lz2 - p1.z + 6.5, WD.upness(vn))
  end
  local at = -99
  WD.stop(vc, 10)
  WD.still(vc, 0.5)
  do
    local _, _, _, c = WD.heading(vc)
    local _, _, lz0 = KIT.l(rec, c or vn.worldPos)
    at = lz0 - p1.z + 6.5
  end
  BK.check("on_span", at > 1.3 and at < 5.5, "the bike stands on the span, over the gap (bridge z %.2f; the gap 1.2-5.6, mid-span 3.4)", at)
  -- before the cargo: what it reads at rest
  local W0 = { r = 0, sag = 0, n = 0 }
  local function watch_beams(t, secs)
    local tt = time
    while time - tt < secs do
      local res, Lr = KLd.lastResult(sid)
      if res and Lr and time - Lr.t < 0.6 then
        for u in pairs(BEAMS) do if res[u] and res[u].r then t.r = math.max(t.r, res[u].r); t.n = t.n + 1 end end
      end
      for u in pairs(BEAMS) do local s2 = KLd.stateOf(sid, u); if s2 then t.sag = math.max(t.sag, s2.cur or 0) end end
      vc.R2.cmd = { drive = 0, steer = 0 }
      yield()
      if t.stop and t.stop() then break end
    end
  end
  watch_beams(W0, 3.0)
  do local ks = KLd.stats(); P("WD LOAD parked on the span: r %.2f, sag %.1f cm · craft ticks on a piece %d (its mass %.3f t over %s points)", W0.r, W0.sag * 100, ks.crafts, ks.craftT or -1, tostring(ks.craftPts)) end
  -- the cargo: 1.3 t more on the bike as the load model weighs it (kit_load.addMass: a
  -- fuelled hopper's weight; the bike's physics is untouched)
  -- (the dug gap's width differs run to run — 4.3 to 5.3 m bearing to bearing — and r goes
  -- with its square: the load is raised until the beams are well over, 1.3 t then 0.7 t steps
  -- every 6 s to 4 t, and the mass it took is reported)
  local ks1 = {}
  for k, v in pairs(KLd.stats()) do ks1[k] = v end
  local added = 1.3
  KLd.addMass(vn.id, added)
  local HW = { r = 0, sag = 0, n = 0, hp = 1 }
  local step_t = time
  local over_t = nil
  local shot_sag = false
  local tb = nil
  HW.stop = function()
    for u in pairs(BEAMS) do
      local hp = findScript("lasers") and findScript("lasers").hpOf(sid, u) or 1
      HW.hp = math.min(HW.hp, hp)
    end
    if not shot_sag and HW.sag > 0.04 then
      shot_sag = true
      local e, t = lw(6.5, 1.0, 3.4), lw(0, 0, 3.4)
      VP.cam_fixed(sub(e, home()), sub(t, home()))
      wait(0.05); BK.shot("wd10_heavy_sag", false); VP.cam_off()
    end
    local gone = 0
    for u in pairs(BEAMS) do if not ST.getPart(sid, u) then gone = gone + 1 end end
    if gone > 0 and not tb then tb = time end
    if HW.r > 1.0 and not over_t then over_t = time end
    if tb and time >= (HW.dl or 0) then
      HW.dl = time + 1.0
      local res, Lr = KLd.lastResult(sid)
      local best, bu, nl = 0, nil, Lr and Lr.loads and #Lr.loads or 0
      for u, R in pairs(res or {}) do if (R.r or 0) > best then best, bu = R.r, u end end
      local p = bu and ST.getPart(sid, bu)
      P("WD LOAD after the first break: %d live load(s), worst r %.2f on %s (result %.1f s old)", nl, best, p and p.id or "-", Lr and time - Lr.t or -1)
    end
    if not over_t and time - step_t > 6 and added < 4.0 then
      added = math.min(4.0, added + 0.7); step_t = time
      KLd.addMass(vn.id, added)
      P("WD LOAD r %.2f after 6 s: the load raised to %.1f t more", HW.r, added)
    end
    return gone == 2
  end
  local th = time
  watch_beams(HW, 40.0)
  local ks2 = KLd.stats()
  local gone = 0
  for u in pairs(BEAMS) do if not ST.getPart(sid, u) then gone = gone + 1 end end
  P("WD LOAD errors %s (last: %s)", tostring(ks2.errors), tostring(ks2.lastError))
  P("WD LOAD heavy: r %.2f, sag %.1f cm, hp low %.2f, creaks %d, broke %d, beams gone %d after %.1f s", HW.r, HW.sag * 100, HW.hp, ks2.creaks - ks1.creaks, ks2.broke - ks1.broke, gone, (tb or time) - th)
  BK.check("heavy_over", W0.r < 1.0 and HW.r > 1.2, "%.1f t more on the parked bike (%.2f t in all): the beams from r %.2f to %.2f", added, added + 0.288, W0.r, HW.r)
  BK.check("heavy_sag", HW.sag > 0.03 and ks2.creaks > ks1.creaks and HW.hp < 1.0, "it sags (%.1f cm), creaks (%d) and gives (hp down to %.2f) before it goes", HW.sag * 100, ks2.creaks - ks1.creaks, HW.hp)
  BK.check("heavy_break", gone >= 1 and ks2.broke > ks1.broke and tb and over_t and tb - over_t > 2.0 and (ks2.errors or 0) == 0,
    "the beams break (%d of 2 gone, %d piece(s) broke) %.1f s after going over 1.0 (the 2 s hold, then hp at 0.15/s); driver errors %d", gone, ks2.broke - ks1.broke, (tb or time) - (over_t or th), ks2.errors or 0)
  wait(2.5)
  local _, _, _, c = WD.heading(vc)
  local _, ly, _ = KIT.l(rec, c or vn.worldPos)
  local decks = 0
  for _, p in ipairs(ST.get(sid) and ST.get(sid).bp or {}) do
    if p.id == "deck24.wood" then
      local bz = p.z - p1.z + 6.5
      if bz > 2.6 and bz < 4.2 then decks = decks + 1 end
    end
  end
  P("WD LOAD after: the bike's tyres at local y %.2f (deck top %.2f), %d deck(s) still over the middle of the gap", ly - p1.y, 0.0, decks)
  BK.check("heavy_fall", ly - p1.y < -0.3, "the bike dropped into the gap (its tyres' middle %.2f m from the deck's top line; %d deck(s) left over the middle of the gap)", ly - p1.y, decks)
  local e, t = lw(7.5, 2.0, 3.4), lw(0, -0.6, 3.4)
  VP.cam_fixed(sub(e, home()), sub(t, home()))
  wait(0.5); BK.shot("wd11_broken", false); VP.cam_off()
  KLd.addMass(vn.id, 0)
end

-- ── woodlook: the board look at 1.5, 5, 20 and 60 m ─────────────────────────
function WD.run_look()
  BK.tag = "woodlook"
  wait_ready(120)
  wait(2)
  BK.unlock()
  local C, fb, ST, co = findScript("crew"), findScript("field_builder"), findScript("structures"), findScript("company")
  C.patch(C.activeId(), { role = "engineer" })
  if co and co.earn then co.earn(80000, "probe") end
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
  stand_at(spot)
  wait(3)
  -- (a high sun, the same for every run: warp until it is well up over the spot)
  do
    local E0 = findScript("electronics")
    local function lit()
      local b0 = home()
      local sun = E0 and E0.sunOf and E0.sunOf(b0.x, b0.y, b0.z, space.bodies() or {})
      return sun and dot(spot.dir, unit(sub(sun, b0))) or 1
    end
    local l0, t0 = lit(), W()
    if l0 < 0.8 then
      space.warp(tonumber(params.daywarp) or 50)
      while W() - t0 < 150 and lit() < 0.82 do yield() end
      space.warp(1)
      wait(1.0)
    end
    P("WL daylight: the sun from %.2f to %.2f over the spot (%.0f s)", l0, lit(), W() - t0)
  end
  if wx and wx.force then wx.force("clear") end
  local b = home()
  local U, F = spot.dir, spot.t
  local g0 = { x = U.x * (spot.r + 4) + F.x * 12, y = U.y * (spot.r + 4) + F.y * 12, z = U.z * (spot.r + 4) + F.z * 12 }
  local h = raycast(b.x + g0.x, b.y + g0.y, b.z + g0.z, -U.x, -U.y, -U.z, 30, { ignore = astro() })
  if not BK.check("ground", h ~= nil, "ground 12 m ahead") then BK.result() return end
  local q = { x = h.x - b.x, y = h.y - b.y, z = h.z - b.z }
  local sid, why = fb.place(nil, "plankFloor.wood", { body = b.name, x = q.x, y = q.y, z = q.z, up = U, fwd = F, sup = U, fwd0 = F, mode = "grid" }, "money")
  if not BK.check("found", sid ~= nil, "a plank floor founds the hut (%s)", tostring(why)) then BK.result() return end
  local rec = ST.get(sid)
  local p1 = rec.bp[1]
  local hx0, hz0 = p1.x + 1, p1.z + 1
  local n, nf = 0, 0
  local function put(id, x, y, z, yaw)
    local s2, w2 = fb.place(sid, id, { body = rec.b, mode = "face", sid = sid, lx = hx0 + x, ly = p1.y + y, lz = hz0 + z, yaw = yaw or 0, pitch = 0, roll = 0 }, "money")
    if s2 then n = n + 1 else nf = nf + 1; P("WL %s refused: %s", id, tostring(w2)) end
  end
  for _, s in ipairs({ { 1, -1 }, { -1, 1 }, { 1, 1 } }) do put("plankFloor.wood", s[1], 0, s[2]) end
  local FT, WT2 = 0.08, 2.28
  put("hutDoor.wood", -1, FT, 2, 0); put("windowWall.wood", 1, FT, 2, 0)
  put("wall.wood", -1, FT, -2, math.pi); put("wall.wood", 1, FT, -2, math.pi)
  put("wall.wood", 2, FT, -1, math.pi / 2); put("wall.wood", 2, FT, 1, math.pi / 2)
  put("wall.wood", -2, FT, -1, -math.pi / 2); put("wall.wood", -2, FT, 1, -math.pi / 2)
  for _, sx in ipairs({ -1, 1 }) do put("shingleRoof.wood", sx, WT2, 1, math.pi); put("shingleRoof.wood", sx, WT2, -1, 0) end
  put("gable.wood", 2, WT2, 1, math.pi / 2); put("gable.wood", 2, WT2, -1, -math.pi / 2)
  put("gable.wood", -2, WT2, -1, -math.pi / 2); put("gable.wood", -2, WT2, 1, math.pi / 2)
  -- a deck on the hut's right with a fence and two log posts
  put("plankFloor.wood", 3.0, 0, 1); put("plankFloor.wood", 3.0, 0, -1)
  put("fence.wood", 4.0, FT, 1, math.pi / 2); put("fence.wood", 4.0, FT, -1, math.pi / 2)
  put("post3.wood", 4.6, 0, 2.3, 0); put("post3.wood", 4.6, 0, -2.3, 0)
  BK.check("built", nf == 0, "the hut, its deck, fence and posts (%d placed, %d refused)", n, nf)
  local rec2 = ST.get(sid)
  wait(3)
  -- the sun's bearing in the hut's frame: the lit views stand between the hut and the sun
  local E = findScript("electronics")
  local KSn = findScript("kit_snap")
  local fr = KSn.frameOf(rec2)
  local bb = home()
  local sun = E and E.sunOf and E.sunOf(bb.x, bb.y, bb.z, space.bodies() or {})
  local sb = 0
  if sun then
    local c = KIT.w(rec2, hx0, p1.y + 1.3, hz0)
    local d = sub(sun, c)
    sb = math.atan2(dot(d, fr.R), dot(d, fr.F))
  end
  P("WL the sun's bearing from the hut: %.0f deg (0 = its front)", math.deg(sb))
  -- a clear line to the hut: turn the bearing until a ray from the eye reaches it
  local function clear_eye(bear, dist, h)
    for _, db in ipairs({ 0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05, 1.4, -1.4 }) do
      for _, hh in ipairs({ h, h + 4, h + 9 }) do
        local b2 = bear + db
        local ex, ez = hx0 + math.sin(b2) * dist, hz0 + math.cos(b2) * dist
        local e = KIT.w(rec2, ex, p1.y + hh, ez)
        -- (three rays: the hut's middle and a point 1.6 m to each side of it, as seen from here)
        local ok = true
        local sx, sz = math.cos(b2), -math.sin(b2)
        for _, k in ipairs({ 0, 1.6, -1.6 }) do
          local t = KIT.w(rec2, hx0 + sx * k, p1.y + 1.2, hz0 + sz * k)
          local d = sub(t, e)
          local Ld = len(d.x, d.y, d.z)
          local hit = raycast(e.x, e.y, e.z, d.x / Ld, d.y / Ld, d.z / Ld, Ld, { ignore = astro() })
          local hd = hit and (hit.distance or len(hit.x - e.x, hit.y - e.y, hit.z - e.z)) or Ld
          if hd < Ld - 3.4 then ok = false break end
        end
        if ok then return { ex, p1.y + hh, ez }, b2 end
      end
    end
    return { hx0 + math.sin(bear) * dist, p1.y + h + 9, hz0 + math.cos(bear) * dist }, bear
  end
  local function v(nm, bear, dist, h, tgt)
    local e, b2 = clear_eye(bear, dist, h)
    P("WL %s: bearing %.0f deg, %.0f m, eye %.1f m up", nm, math.deg(b2), dist, e[2] - p1.y)
    KIT.view(nm, rec2, e, { hx0 + (tgt and tgt[1] or 0), p1.y + (tgt and tgt[2] or 1.3), hz0 + (tgt and tgt[3] or 0) })
  end
  -- lit (the sun behind the camera, a little to one side) and shaded; one view in its
  -- plants first, then the plants off (the forest round the spot hid the hut from 20 m and
  -- more, and the mushrooms' shade fell on it at 5 m): the A/B is the wood, not the canopy
  local lit = sb + 0.35
  v("wl5_plants6", lit, 6.0, 1.7)
  local ff = findScript("flora_field")
  if ff and ff.params then ff.params.enabled = 0; wait(2.0) end
  v("wl0_close", lit, 3.0, 1.5, { 0, 1.2, 0 })
  v("wl1_5m", lit, 6.0, 1.7)
  v("wl2_20m", lit, 20.0, 2.5)
  v("wl3_60m", lit, 60.0, 4.0)
  v("wl4_shade20", sb + math.pi, 20.0, 2.5)
  if ff and ff.params then ff.params.enabled = 1 end
  BK.result()
end
