-- ── robotics in the middle of a driving craft (servoprobe.sh, mode smid) ──
-- Spliced after servoprobe_modes.lua (SP.*), jumpprobe (JP.*), verifyprobe
-- (V.*) and ivaprobe (iv_launch). `rig` (strs) picks the craft and its test:
--   bike rigs (the player's bike, user://probe_dirtbike.json, rebuilt):
--     pext    a Piston between the saddle and the front half (locker, fork,
--             front wheel): the wheelbase stretches 0.8 m while it rides
--     curl    Piston + Servo Hinge + Piston there: the frame bends and
--             stretches; then a bumpy stretch and a hill with it curled
--     seatp   a Piston between the saddle and the engine: the engine, chain
--             and rear wheel ride on it together (the rider's mount moves)
--     engs    the engine alone on a Servo Hinge, the swing arm on the frame:
--             the chain runs from a moving engine to a fixed wheel
--     bend    an upright-axis Servo Hinge between the saddle and the front:
--             bent 25°, the rider is told the balance can't hold it
--   rover rigs (built here):
--     skid    four wheels, none steering: a tank-style turn
--     loader  two bodies joined by an upright Servo Hinge, no steered wheel:
--             articulated steering by the hinge alone
--     trailer a trailer on a Decoupler, dropped while it drives
--     hop     each wheel on an upright Piston: slammed out (a hop), then
--             levelled by hand on a slope
--     nest    one wheel on Hinge → Piston → Hinge
--     loop    two Pistons joined at both ends by a plate (a closed loop)
--     spin    a wheel on a Rotor's arm, spinning while it drives
--     right   a self-righting arm (a hinge and a 2 m beam on the top's edge):
--             rolled onto its side by the probe, the arm puts it back
--     keep    the nest rover posed, through a sleep and wake and a real
--             save and load (the fleet written, the system scene loaded again)
--     revert  the nest rover posed, then reverted to launch: as launched
--   every rig: the joints' state through a rescan (a reload), `SM P`.
-- `SM T` lines every 0.5 s, `SM R` per phase, `VP PASS|FAIL`, `VP RESULT`.
local SM = {}
local HPI = math.pi / 2

local function R(uid, id, x, y, z, o)
  o = o or {}
  local d = { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
              parent = o.parent or 0, att = o.att or "surface", sym = 0, mir = "", stage = o.stage or 0 }
  if o.wcfg then d.wcfg = o.wcfg end
  return d
end
local function L(a, b) return { a = a, b = b, k = "surface", sa = "surface", sb = "surface", prim = 1 } end

-- ── the bike rigs ───────────────────────────────────────────────────────────
function SM.bikeRig(bp, rig)
  local by, maxu = {}, 0
  for _, d in ipairs(bp.parts) do by[d.uid] = d; maxu = math.max(maxu, d.uid) end
  local seat, fork, eng, arm
  for _, d in ipairs(bp.parts) do
    if d.seat == 1 or d.seat == true then seat = d end
    if d.id == "forkT" then fork = d end
    if d.id == "swingArm" then arm = d end
    if type(d.id) == "string" and d.id:match("^gasE") then eng = d end
  end
  local front = fork and by[fork.parent]
  if not (seat and front and eng and arm) then return nil, "no saddle / fork host / engine / swing arm" end
  local links = {}
  local function relink(a, b, chain)
    -- drop the a–b primary link, put chain a → c1 → … → b in its place
    for i = #bp.links, 1, -1 do
      local l = bp.links[i]
      if (l.a == a and l.b == b) or (l.a == b and l.b == a) then table.remove(bp.links, i) end
    end
    local prev = a
    for _, u in ipairs(chain) do bp.links[#bp.links + 1] = L(prev, u); prev = u end
    bp.links[#bp.links + 1] = L(prev, b)
  end
  -- (the player's bike welds its gyro, on the engine, to the locker at the
  -- front: with a joint between them that is a real second path, which the
  -- builder rightly calls a loop. The rigs take it off: their joint is meant
  -- to be the only path, and the loop has its own rig.)
  for i = #bp.links, 1, -1 do
    if bp.links[i].k == "weld" then
      P("SM rig: the weld %d-%d taken off", bp.links[i].a, bp.links[i].b)
      table.remove(bp.links, i)
    end
  end
  local note
  if rig == "pext" or rig == "curl" or rig == "bend" then
    -- along the frame between the saddle's front face and the front half
    local x0 = seat.x + (seat.rx or 0.36) * 0.5
    local y = front.y
    local ids = (rig == "pext") and { "piston" } or ((rig == "bend") and { "hinge" }) or { "piston", "hinge", "piston" }
    local chain, prev = {}, seat.uid
    for i, id in ipairs(ids) do
      local u = maxu + i
      local o = { parent = prev }
      if id == "piston" then o.roll = -HPI end      -- its +Y forward (+X): it stretches the frame
      if rig == "bend" then o.roll, o.pitch = -HPI, HPI end   -- its +Y forward, its axis upright: it bends the frame sideways
      bp.parts[#bp.parts + 1] = R(u, id, x0 + 0.06 * (i - 1), y, 0, o)
      chain[#chain + 1] = u
      prev = u
    end
    front.parent = prev
    relink(seat.uid, front.uid, chain)
    note = table.concat(ids, " → ") .. " between the saddle and the " .. tostring(front.id)
  elseif rig == "seatp" then
    local u = maxu + 1
    bp.parts[#bp.parts + 1] = R(u, "piston", eng.x, (seat.y + eng.y) * 0.5, 0, { parent = seat.uid })
    eng.parent = u
    relink(seat.uid, eng.uid, { u })
    note = "a piston between the saddle and the engine"
  elseif rig == "engs" then
    local u = maxu + 1
    bp.parts[#bp.parts + 1] = R(u, "hinge", eng.x, (seat.y + eng.y) * 0.5, 0, { parent = seat.uid })
    eng.parent = u
    relink(seat.uid, eng.uid, { u })
    -- the swing arm off the engine and onto the frame
    for i = #bp.links, 1, -1 do
      local l = bp.links[i]
      if (l.a == eng.uid and l.b == arm.uid) or (l.b == eng.uid and l.a == arm.uid) then table.remove(bp.links, i) end
    end
    -- (hung from the saddle on an upright 1 m beam behind the engine: left
    -- where it was, on nothing, LAUNCH refuses it as not touching)
    local bu = maxu + 2
    bp.parts[#bp.parts + 1] = R(bu, "beam1", eng.x - 0.31, 0.95, eng.z or 0, { parent = seat.uid })   -- (0.45–1.45 m: clear of the ground)
    bp.links[#bp.links + 1] = L(seat.uid, bu)
    arm.parent = bu
    bp.links[#bp.links + 1] = L(bu, arm.uid)
    note = "the engine on a hinge, the swing arm on a beam from the saddle"
  else
    return nil, "unknown bike rig " .. tostring(rig)
  end
  return bp, note
end

-- ── the rover rigs ──────────────────────────────────────────────────────────
function SM.roverRig(rig)
  local off = { steer = "off" }
  local P, K = {}, {}
  local function add(d) P[#P + 1] = d; if d.parent ~= 0 then K[#K + 1] = L(d.parent, d.uid) end; return d.uid end
  local function wheels(body, x, from, o)
    o = o or {}
    for i, z in ipairs({ 0.7, -0.7 }) do
      add(R(from + i - 1, "wheelM", x, 0.42, z, { yaw = (z > 0) and -HPI or HPI, parent = body, wcfg = o.wcfg }))
    end
  end
  local note
  if rig == "skid" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2, { wcfg = off }); wheels(1, -0.66, 4, { wcfg = off })
    add(R(6, "seat", 0, 1.42, 0, { parent = 1, att = "top" }))
    note = "four wheels, none steering"
  elseif rig == "loader" then
    add(R(1, "roverBody", -0.9, 0.62, 0, { att = "" }))
    wheels(1, -0.9, 2, { wcfg = off })
    add(R(4, "seat", -0.9, 1.42, 0, { parent = 1, att = "top" }))
    add(R(5, "hinge", 0, 0.62, 0, { pitch = HPI, parent = 1 }))     -- its axis upright
    add(R(6, "roverBody", 0.9, 0.62, 0, { parent = 5 }))
    wheels(6, 0.9, 7, { wcfg = off })
    note = "two bodies on an upright hinge, no wheel steers"
  elseif rig == "trailer" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2); wheels(1, -0.66, 4)
    add(R(6, "seat", 0, 1.42, 0, { parent = 1, att = "top" }))
    -- (flush: the decoupler 0.25 m long from the body's back face at −0.8,
    -- the trailer's front face on it; a gap over 2 cm and LAUNCH refuses)
    add(R(7, "decoupler", -0.925, 0.62, 0, { roll = HPI, parent = 1, stage = 1 }))
    add(R(8, "roverBody", -1.85, 0.62, 0, { parent = 7 }))
    wheels(8, -1.9, 9)
    note = "a trailer on a decoupler"
  elseif rig == "hop" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    local u = 2
    for _, x in ipairs({ 0.66, -0.66 }) do
      for _, z in ipairs({ 0.7, -0.7 }) do
        -- (its 0.32 m width into the body's flank at ±0.5, the wheel's hub on it)
        add(R(u, "piston", x, 0.67, z * 0.6 / 0.7, { parent = 1 }))
        add(R(u + 1, "wheelM", x, 0.42, z, { yaw = (z > 0) and -HPI or HPI, parent = u }))
        u = u + 2
      end
    end
    add(R(u, "seat", 0, 1.42, 0, { parent = 1, att = "top" }))
    note = "each wheel on an upright piston"
  elseif rig == "nest" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2)
    add(R(4, "wheelM", -0.66, 0.42, -0.7, { yaw = HPI, parent = 1 }))
    add(R(5, "hinge", -0.40, 0.55, 0.7, { parent = 1 }))
    add(R(6, "piston", -0.50, 0.55, 0.7, { parent = 5 }))
    add(R(7, "hinge", -0.60, 0.50, 0.7, { parent = 6 }))
    add(R(8, "wheelM", -0.66, 0.42, 0.7, { yaw = -HPI, parent = 7 }))
    add(R(9, "seat", 0, 1.42, 0, { parent = 1, att = "top" }))
    note = "one wheel on hinge → piston → hinge"
  elseif rig == "right" then
    -- a self-righting arm: a Servo Hinge on the top's left edge, its axis
    -- along the rover, a 2 m Box Beam standing on it; laid on its left side,
    -- the arm swung down into the ground levers it back onto its wheels
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2); wheels(1, -0.66, 4)
    add(R(6, "seat", -0.4, 1.42, 0, { parent = 1, att = "top" }))
    add(R(7, "hinge", 0.4, 0.97, 0.38, { yaw = HPI, parent = 1 }))
    add(R(8, "beam2", 0.4, 0.97 + 0.2 + 1.0, 0.38, { yaw = HPI, parent = 7 }))
    note = "a self-righting arm: a hinge on the top's edge, a 2 m beam on it"
  elseif rig == "keep" or rig == "revert" then
    -- the nest rover again: three joints deep, posed, then kept through a
    -- sleep and a real save and load (keep) or a revert to launch (revert)
    local bp = SM.roverRig("nest")
    return bp, "the nest rover, for " .. ((rig == "keep") and "a sleep and a save and load" or "a revert to launch")
  elseif rig == "loop" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2); wheels(1, -0.66, 4)
    add(R(6, "seat", -0.3, 1.42, 0, { parent = 1, att = "top" }))
    add(R(7, "piston", 0.45, 1.02, 0.25, { parent = 1 }))
    add(R(8, "piston", 0.45, 1.02, -0.25, { parent = 1 }))
    add(R(9, "battery", 0.45, 1.6, 0, { parent = 7 }))
    K[#K + 1] = { a = 8, b = 9, k = "surface", sa = "surface", sb = "surface" }   -- the loop
    note = "two pistons joined at both ends"
  elseif rig == "spin" then
    add(R(1, "roverBody", 0, 0.62, 0, { att = "" }))
    wheels(1, 0.66, 2); wheels(1, -0.66, 4)
    add(R(6, "seat", 0, 1.42, 0, { parent = 1, att = "top" }))
    add(R(7, "rotor", 1.0, 0.62, 0, { pitch = HPI, parent = 1 }))      -- its axis across
    add(R(8, "wheelS", 1.0, 0.62 + 0.45, 0, { yaw = -HPI, parent = 7 }))
    note = "a wheel on a rotor's arm"
  else
    return nil, "unknown rover rig " .. tostring(rig)
  end
  return { parts = P, links = K, name = "Probe " .. rig }, note
end

-- ── launch through the VAB, the builder's warnings read first ───────────────
function SM.launch(rig)
  V.tag = "mid_" .. rig
  local bp, note
  if rig == "pext" or rig == "curl" or rig == "seatp" or rig == "engs" or rig == "bend" then
    local b0 = V.dirtbike()
    if not b0 then V.check("craft", false, "no craft file"); return end
    bp, note = SM.bikeRig(b0, rig)
  else
    bp, note = SM.roverRig(rig)
  end
  if not bp then V.check("rig", false, "%s", tostring(note)); return end
  P("SM rig %s: %s, %d parts", rig, note, #bp.parts)
  local seat
  JP.ids = {}
  for _, d in ipairs(bp.parts) do
    JP.ids[d.uid] = d.id
    if d.seat == 1 or d.seat == true or d.id == "seat" then seat = d.uid end
  end
  -- (the warnings: iv_launch, with a look at the builder before LAUNCH)
  IV.medium()
  local co = findScript("company"); if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(bp.parts) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("launch_enter")
  if not BH then V.check("vab", false, "no VAB"); return end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "launch_bp", bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = bp.name or "Probe", controls = bp.controls, groups = bp.groups })
  wait(0.5)
  local warn = {}
  for _, f in ipairs({ "roboLoopChecks", "roboTowChecks", "chainJointChecks" }) do
    local fn = B[f]
    if fn then for _, w in ipairs(fn({}) or {}) do warn[#warn + 1] = w end end
  end
  if B.wheelChecks then for _, w in ipairs(B.wheelChecks() or {}) do warn[#warn + 1] = w end end
  local chk = B.launchCheck and B.launchCheck() or {}
  P("SM builder: %d warning(s)%s; launch %s", #warn, #warn > 0 and (": " .. table.concat(warn, " | ")) or "", chk.block and ("BLOCKED: " .. chk.block) or "allowed")
  SM.warn, SM.block = warn, chk.block
  if rig ~= "loop" then
    local looped = false
    for _, w in ipairs(warn) do if w:find("a loop", 1, true) then looped = true end end
    V.check("no_false_loop", not looped, "no loop warning on a craft with one path through each joint")
  end
  local BC = findScript("builder_crew")
  if BC and seat then
    if BC.unseatMember then BC.unseatMember(1) end
    local ok, why = BC.seatMember(1, seat, 1)
    P("SM crew -> %d: %s %s", seat, tostring(ok), tostring(why))
  end
  if B.launchSite and B.launchSite() ~= "runway" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#bp.parts, 150)
  if not vc then V.check("rollout", false, "no craft"); return end
  wait(2)
  vc.releaseClamps()
  wait(2)
  return vc
end

-- ── measures ────────────────────────────────────────────────────────────────
function SM.robo(vc, i) return (vc.R2.robo or {})[i] end
function SM.set(vc, i, key, v)
  local r = SM.robo(vc, i)
  if not r then return end
  if type(r.d.st) ~= "table" then r.d.st = {} end
  r.d.st[key] = v
end
function SM.curs(vc)
  local t = {}
  for _, r in ipairs(vc.R2.robo or {}) do t[#t + 1] = string.format("%s%.2f%s", r.kind:sub(1, 1), r.cur or 0, r.stalled and "!" or "") end
  return table.concat(t, ",")
end
-- heading along the strip, deg (+ left)
function SM.head(vc)
  local S = V.strip
  if not S then return 0 end
  local F = V.fwdW(vc)
  local Lf = unit(cross(S.U, S.F))
  return math.deg(math.atan2(dot(F, Lf), dot(F, S.F)))
end
-- the tyres out, the span of the tyres along the craft (hull frame), the lowest tyre's height
function SM.tyres(vc)
  local n, xmin, xmax = 0, math.huge, -math.huge
  for _, w in ipairs(vc.R2.wheels or {}) do
    local lx = SP.tyreLocal(vc, w)
    if lx then n = n + 1; xmin, xmax = math.min(xmin, lx), math.max(xmax, lx) end
  end
  return n, (n > 0) and (xmax - xmin) or 0
end
function SM.wheelsDbg(vc)
  local t = {}
  for _, w in ipairs(vc.R2.wheels or {}) do
    local lx, ly = SP.tyreLocal(vc, w)
    local j = w.tyre and w.tyre.valid and w.tyre:getcomponent("Joint")
    t[#t + 1] = string.format("w%d tyre %.3f,%.3f mount %.3f,%.3f anc %.3f,%.3f", w.uid, lx or 0, ly or 0, w.cx or 0, w.cy or 0,
      j and (j.otherAnchorX or 0) or 0, j and (j.otherAnchorY or 0) or 0)
  end
  return table.concat(t, " ; ")
end
function SM.line(vc, tag)
  local n, span = SM.tyres(vc)
  local roll = JP.att(vc)
  local _, lat = V.strip and JP.along(vc) or 0, 0
  if V.strip then _, lat = JP.along(vc) end
  P("SM T %s v %.2f head %.1f lat %.2f up %.3f roll %.1f | joints %s | tyres %d/%d span %.2f | wb %.2f bike %s rehangs %d | why %s",
    tag, V.speed(vc), SM.head(vc), lat or 0, V.upness(vc.node), math.deg(roll or 0), SM.curs(vc), n, #(vc.R2.wheels or {}), span,
    vc.R2.wheelbase or -1, tostring(vc.R2.bike), vc.R2.rehangs or 0, tostring(vc.R2.why))
  if (tonumber(params.dbg) or 0) > 0 then
    local i = assembly.info(vc.node)
    local hc = vc.r2HullCom and vc.r2HullCom(i)
    P("SM W %s %s | com %s", tag, SM.wheelsDbg(vc), hc and string.format("%.3f,%.3f,%.3f", hc[1], hc[2], hc[3]) or "-")
  end
end
-- ride `secs` at vt (hands on the line), `steer` fixed instead when given; → stats
function SM.ride(vc, tag, secs, o)
  o = o or {}
  local t0, s = time, { n = 0, v = 0, vmin = 99, vmax = 0, up = 1, h0 = SM.head(vc), fell = false }
  while time - t0 < secs do
    local drive, st = JP.cruise(vc, o.vt or 6, o.steer == nil)
    if o.steer then st = o.steer end
    if o.drive then drive = o.drive end
    vc.R2.cmd = { drive = drive, steer = st }
    if o.each then o.each(time - t0) end
    yield()
    local sp = V.speed(vc)
    s.n, s.v = s.n + 1, s.v + sp
    if time - t0 > 1.0 then s.vmin = math.min(s.vmin, sp) end
    s.vmax = math.max(s.vmax, sp)
    s.up = math.min(s.up, V.upness(vc.node))
    if time >= (SM.tl or 0) then SM.tl = time + 0.5; SM.line(vc, string.format("%s+%.1f", tag, time - t0)) end
    if V.upness(vc.node) < 0.3 then s.fell = true; break end
    if V.strip and V.strip.d1 and JP.along(vc) > V.strip.d1 - 20 then P("SM strip end"); break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  s.v = s.v / math.max(1, s.n)
  s.dh = SM.head(vc) - s.h0
  local n, span = SM.tyres(vc)
  s.span, s.out, s.wb = span, n, vc.R2.wheelbase
  P("SM R %s: mean %.2f m/s (min %.2f max %.2f), heading %+.1f deg, least upness %.2f, joints %s, tyres %d span %.2f, wb %.2f%s",
    tag, s.v, s.vmin, s.vmax, s.dh, s.up, SM.curs(vc), n, span, vc.R2.wheelbase or -1, s.fell and " FELL" or "")
  return s
end
function SM.waitJoint(vc, i, key, v, tmo)
  local r = SM.robo(vc, i)
  if not r then return end
  wait_for(function() return math.abs((r.cur or 0) - v) < ((key == "extension") and 0.01 or 0.5) end, tmo or 10, "joint " .. i)
end

-- the joints' state through a rescan (what a reload does: r_scan from the records)
function SM.persist(vc)
  local before = SM.curs(vc)
  local n0, span0 = SM.tyres(vc)
  vc.R2.gen = -1
  wait(1.5)
  local n1, span1 = SM.tyres(vc)
  P("SM P rescan: joints %s -> %s, tyres %d span %.2f -> %d span %.2f", before, SM.curs(vc), n0, span0, n1, span1)
  V.check("persist", before == SM.curs(vc) and math.abs(span0 - span1) < 0.08, "the joints and the tyres after a rescan: %s / %s, span %.2f / %.2f", before, SM.curs(vc), span0, span1)
end

-- ── the tests ───────────────────────────────────────────────────────────────
local function out_and_strip(vc, len_)
  if not JP.strip(vc, -15, len_ or 260) then return false end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the strip")
  return true
end

local T = {}
T.pext = function(vc)
  local a = SM.ride(vc, "lead", 5, { vt = 7 })
  SM.set(vc, 1, "extension", 0.8)
  local b = SM.ride(vc, "extend", 4, { vt = 7 })
  local c = SM.ride(vc, "long", 4, { vt = 7 })
  -- a steer while long: the bike must lean into it and turn
  local d = SM.ride(vc, "turn_long", 2.5, { vt = 6, steer = 0.4 })
  local e = SM.ride(vc, "back", 3, { vt = 6 })
  SM.set(vc, 1, "extension", 0)
  local f = SM.ride(vc, "retract", 4, { vt = 7 })
  local g = SM.ride(vc, "turn_short", 2.5, { vt = 6, steer = 0.4 })
  V.check("upright", not (a.fell or b.fell or c.fell or d.fell or e.fell or f.fell or g.fell), "stayed up")
  V.check("stretched", c.span - a.span > 0.6, "tyre span %.2f -> %.2f m (piston %s)", a.span, c.span, SM.curs(vc))
  V.check("wheelbase_followed", math.abs((vc.R2.wheelbase or 0) - (a.span or 0)) < 0.3, "the plan's wheelbase %.2f vs the tyres' span %.2f back at 0", vc.R2.wheelbase or -1, f.span)
  V.check("tyres_on_mounts", math.abs(c.span - (c.wb or 0)) < 0.06, "long: the tyres' span %.2f vs the frame's wheelbase %.2f", c.span, c.wb or -1)
  V.check("drives_long", b.vmin > 4 and c.vmin > 4, "slowest while extending / long: %.2f / %.2f", b.vmin, c.vmin)
  V.check("steers_long", math.abs(d.dh) > 5, "a 2.5 s turn while long changed heading %.1f deg (short: %.1f)", d.dh, g.dh)
  return true
end
T.curl = function(vc)
  local a = SM.ride(vc, "lead", 5, { vt = 6 })
  SM.set(vc, 1, "extension", 0.4); SM.set(vc, 2, "angle", -20); SM.set(vc, 3, "extension", 0.4)
  local b = SM.ride(vc, "curl", 5, { vt = 6 })
  SM.set(vc, 2, "angle", 20)
  local c = SM.ride(vc, "bend_other", 5, { vt = 6 })
  SM.set(vc, 2, "angle", 0)
  local d = SM.ride(vc, "straight_long", 4, { vt = 6 })
  V.check("upright_flat", not (a.fell or b.fell or c.fell or d.fell), "stayed up on the flat through the curl")
  V.check("drives_curled", b.vmin > 3 and c.vmin > 3, "slowest curled: %.2f / %.2f", b.vmin, c.vmin)
  -- rough ground with the frame stretched and bent
  SM.set(vc, 2, "angle", -15)
  local B, dEnd = JP.bumps()
  local d0 = JP.along(vc) + 25
  for _, bb in ipairs(B) do bb.d = bb.d - B[1].d + d0 end
  JP.bumps_build(vc, B, d0 - 2, B[#B].d + 3)
  local e = SM.ride(vc, "bumps", 12, { vt = 6 })
  V.check("bumps_curled", not e.fell, "over %d bumps curled (least upness %.2f, slowest %.2f)", #B, e.up, e.vmin)
  return true
end
-- the frame bent sideways past what a bike's balance can hold: said, and
-- the bike neither thrown nor wrecked
function SM.said()
  local bc = findScript("big_caption")
  return bc and bc.current
end
T.bend = function(vc)
  local a = SM.ride(vc, "lead", 4, { vt = 5 })
  SM.set(vc, 1, "angle", 25)
  local saw
  local b = SM.ride(vc, "bending", 4, { vt = 4, each = function() saw = saw or ((SM.said() == "WHEELS OUT OF LINE") and SM.said()) end })
  P("SM bend: said %s, heading %+.1f", tostring(saw), b.dh)
  V.check("bent_said", saw ~= nil, "the rider is told the bent frame is past the balance assist")
  SM.set(vc, 1, "angle", 0)
  vc.R2.cmd = { drive = 0, steer = 0 }
  wait(4)
  local i = assembly.info(vc.node)
  local w = i.angVel
  V.check("bent_calm", len(w.x, w.y, w.z) < 3 and #(vc.R2.wheels or {}) == 2, "no blow-up (spin %.2f rad/s, %d wheels)", len(w.x, w.y, w.z), #(vc.R2.wheels or {}))
  return true
end
T.seatp = function(vc)
  local a = SM.ride(vc, "lead", 5, { vt = 7 })
  SM.set(vc, 1, "extension", 0.3)
  local b = SM.ride(vc, "lift", 4, { vt = 7 })
  local c = SM.ride(vc, "held", 4, { vt = 7 })
  SM.set(vc, 1, "extension", 0)
  local d = SM.ride(vc, "down", 3, { vt = 7 })
  local w = SP.rear(vc)
  P("SM rider: aboard %s, chain share %.2f", tostring(vc.crewAboard), w and w.gas and (w.gas.k or 1) or -1)
  V.check("upright", not (a.fell or b.fell or c.fell or d.fell), "stayed up")
  V.check("rider_aboard", vc.crewAboard == true, "the rider is still in the saddle")
  V.check("chain_same_side", w and w.gas and (w.gas.k or 1) > 0.99, "the chain with its engine and wheel on one side keeps its drive (%.2f)", w and w.gas and (w.gas.k or 1) or -1)
  V.check("drives", b.vmin > 4 and c.vmin > 4, "slowest lifting / held: %.2f / %.2f", b.vmin, c.vmin)
  return true
end
T.engs = function(vc)
  local a = SM.ride(vc, "lead", 5, { vt = 7 })
  local w = SP.rear(vc)
  local ks = {}
  for _, ang in ipairs({ 5, -5, 30 }) do
    SM.set(vc, 1, "angle", ang)
    SM.ride(vc, "eng" .. ang, 3.5, { vt = 7 })
    ks[#ks + 1] = string.format("%d:%.2f", ang, w and w.gas and (w.gas.k or 1) or -1)
  end
  P("SM chain share by engine angle: %s", table.concat(ks, " "))
  V.check("chain_follows_engine", w and w.gas and w.gas.run ~= nil and (w.gas.k or 1) < 0.5, "the chain from a moving engine: shares %s", table.concat(ks, " "))
  SM.set(vc, 1, "angle", 0)
  local b = SM.ride(vc, "back", 4, { vt = 7 })
  V.check("drives_back", b.vmin > 4, "back at 0 it drives (%.2f m/s)", b.vmin)
  return true
end
T.skid = function(vc)
  local a = SM.ride(vc, "lead", 4, { vt = 4 })
  -- (on the spot from a stop: rolling, the turn takes it off the strip
  -- onto whatever slope is beside it, and the heading says more about that)
  V.stop(vc)
  local b = SM.ride(vc, "left", 3, { vt = 0, drive = 0, steer = 1 })
  V.stop(vc)
  local c = SM.ride(vc, "right", 3, { vt = 0, drive = 0, steer = -1 })
  V.check("skid_turns", math.abs(b.dh) > 15 and math.abs(c.dh) > 15 and b.dh * c.dh < 0, "skid steer on the spot: %+.1f / %+.1f deg in 3 s", b.dh, c.dh)
  local d = SM.ride(vc, "rolling_left", 3, { vt = 4, steer = 1 })
  P("SM skid rolling: %+.1f deg in 3 s at %.2f m/s", d.dh, d.v)
  return true
end
T.loader = function(vc)
  local a = SM.ride(vc, "lead", 4, { vt = 4, steer = 0 })
  SM.set(vc, 1, "angle", 25)
  local b = SM.ride(vc, "fold_a", 5, { vt = 3, steer = 0 })
  SM.set(vc, 1, "angle", -25)
  local c = SM.ride(vc, "fold_b", 6, { vt = 3, steer = 0 })
  SM.set(vc, 1, "angle", 0)
  local d = SM.ride(vc, "straight", 4, { vt = 3, steer = 0 })
  V.check("upright", not (a.fell or b.fell or c.fell or d.fell), "stayed up")
  local said = false
  for _, w in ipairs(SM.warn or {}) do if w:find("never swings free", 1, true) then said = true end end
  V.check("hitch_said", said, "the builder says the hinge steers it and never swings free like a trailer")
  V.check("articulated_turns", math.abs(b.dh) > 10 and math.abs(c.dh) > 10 and b.dh * c.dh < 0,
    "the hinge alone turned it %+.1f / %+.1f deg (straight %+.1f)", b.dh, c.dh, a.dh)
  return true
end
T.trailer = function(vc)
  local a = SM.ride(vc, "towing", 5, { vt = 5 })
  local n0 = #(vc.R2.wheels or {})
  local ok = vc.stageNext and vc.stageNext()
  P("SM decoupler fired: %s", tostring(ok))
  local b = SM.ride(vc, "dropped", 6, { vt = 5 })
  P("SM wheels %d -> %d, tyres out %d", n0, #(vc.R2.wheels or {}), (SM.tyres(vc)))
  V.check("drops_and_drives", ok and #(vc.R2.wheels or {}) == 4 and b.vmax > 3 and not b.fell, "after the drop: %d wheels, %.2f m/s at best", #(vc.R2.wheels or {}), b.vmax)
  return true
end
T.hop = function(vc)
  local a = SM.ride(vc, "lead", 3, { vt = 3 })
  V.stop(vc)
  local i = assembly.info(vc.node)
  local U = V.up(i.com)
  local h0 = dot(sub(i.com, home()), U)
  for k = 1, 4 do SM.set(vc, k, "speed", 1000); SM.set(vc, k, "extension", 0.8) end
  local hmax, t0 = h0, time
  while time - t0 < 2.5 do
    vc.R2.cmd = { drive = 0, steer = 0 }
    yield()
    local c = assembly.info(vc.node).com
    hmax = math.max(hmax, dot(sub(c, home()), V.up(c)))
    if time >= (SM.tl or 0) then SM.tl = time + 0.25; SM.line(vc, string.format("hop+%.2f", time - t0)) end
  end
  P("SM hop: the centre of mass rose %.2f m at most (pistons out 0.8 m at %.1f m/s)", hmax - h0, 3.0)
  V.check("hop_lifts", hmax - h0 > 0.4 and V.upness(vc.node) > 0.5, "rose %.2f m, upness %.2f", hmax - h0, V.upness(vc.node))
  -- levelled by hand: the left pistons out, the right in, while it drives
  for k = 1, 4 do SM.set(vc, k, "speed", 100) end
  SM.set(vc, 1, "extension", 0.6); SM.set(vc, 2, "extension", 0.1); SM.set(vc, 3, "extension", 0.6); SM.set(vc, 4, "extension", 0.1)
  local b = SM.ride(vc, "tilted", 5, { vt = 3 })
  P("SM tilt: roll %.1f deg with one side 0.5 m longer", math.deg(JP.att(vc) or 0))
  V.check("drives_on_pistons", not b.fell and b.vmax > 2, "drove on its pistons tilted (%.2f m/s)", b.vmax)
  for k = 1, 4 do SM.set(vc, k, "extension", 0) end
  SM.ride(vc, "down", 3, { vt = 3 })
  return true
end
T.nest = function(vc)
  local a = SM.ride(vc, "lead", 3, { vt = 4 })
  SM.set(vc, 1, "angle", 15); SM.set(vc, 2, "extension", 0.3); SM.set(vc, 3, "angle", -15)
  local b = SM.ride(vc, "nested", 5, { vt = 4 })
  SM.set(vc, 1, "angle", 0); SM.set(vc, 2, "extension", 0); SM.set(vc, 3, "angle", 0)
  local c = SM.ride(vc, "back", 4, { vt = 4 })
  V.check("nested_drives", not (a.fell or b.fell or c.fell) and b.vmin > 2 and b.out == 4, "drove on the nested wheel (slowest %.2f, %d tyres)", b.vmin, b.out)
  return true
end
T.loop = function(vc)
  local warned = false
  for _, w in ipairs(SM.warn or {}) do if w:find("loop", 1, true) then warned = true end end
  V.check("loop_warned", warned and not SM.block, "the builder %s and %s", warned and "warned" or "did NOT warn", SM.block and "blocked" or "allowed the launch")
  local a = SM.ride(vc, "lead", 3, { vt = 4 })
  SM.set(vc, 1, "extension", 0.6)       -- one of the pair only: the loop comes apart
  local b = SM.ride(vc, "one", 4, { vt = 4 })
  SM.set(vc, 2, "extension", 0.6)
  local c = SM.ride(vc, "both", 4, { vt = 4 })
  local i = assembly.info(vc.node)
  local w = i.angVel
  V.check("loop_calm", not (a.fell or b.fell or c.fell) and math.sqrt(w.x * w.x + w.y * w.y + w.z * w.z) < 2, "no blow-up: spin %.2f rad/s", math.sqrt(w.x * w.x + w.y * w.y + w.z * w.z))
  return true
end
T.spin = function(vc)
  local a = SM.ride(vc, "lead", 3, { vt = 3 })
  SM.set(vc, 1, "spin", true); SM.set(vc, 1, "rpm", 30)
  local b = SM.ride(vc, "spinning", 8, { vt = 3 })
  SM.set(vc, 1, "spin", false)
  local c = SM.ride(vc, "stopped", 3, { vt = 3 })
  V.check("spin_ok", not (b.fell or c.fell) and b.vmax > 1.5, "drove with the rotor spinning (%.2f m/s best, joints %s)", b.vmax, SM.curs(vc))
  return true
end

T.right = function(vc)
  SM.ride(vc, "lead", 3, { vt = 3 })
  V.stop(vc)
  -- on its left side: rolled about its own right (+X) until its up is level
  -- (the torque in fixedUpdate, as the hold's: JP_TICK)
  local tick0 = JP_TICK
  local flip = true
  JP_TICK = function(dt)
    if tick0 then tick0(dt) end
    if not (flip and vc.node and vc.node.valid) then return end
    local i = assembly.info(vc.node)
    local X = unit(i.right)
    local wr = dot(i.angVel, X)
    -- (enough to lift its centre of mass over the left tyres: its weight on
    -- a 1.5 m lever, plus the rate it is brought to)
    local m = i.mass or 0.5
    -- (the hull's mass only: the tyres are bodies of their own, and its
    -- stability assist fights the roll, so well over what tips it)
    local tq = math.max(0, m * (vc.R2.gl or 9.8) * 5 + 2 * m * 6 * (1.6 - wr))
    SM.flipq = string.format("mass %.2f t, torque %.1f, roll rate %.2f", m, tq, wr)
    assembly.torque(vc.node, vec3(X.x * tq, X.y * tq, X.z * tq))
  end
  local t0 = time
  while time - t0 < 6 and V.upness(vc.node) > 0.12 do
    vc.R2.cmd = { drive = 0, steer = 0 }
    yield()
    if time >= (SM.tl or 0) then SM.tl = time + 0.5; P("SM flip: upness %.2f, %s", V.upness(vc.node), tostring(SM.flipq)) end
  end
  flip = false
  JP_TICK = tick0
  wait(4)
  local u0 = V.upness(vc.node)
  P("SM right: on its side, upness %.2f roll %.1f", u0, math.deg(JP.att(vc) or 0))
  V.check("flipped", u0 < 0.35, "the probe laid it on its side (upness %.2f)", u0)
  local best, used = u0, nil
  for _, ang in ipairs({ 90, -90 }) do
    SM.set(vc, 1, "angle", ang)
    local t1 = time
    while time - t1 < 7 do
      vc.R2.cmd = { drive = 0, steer = 0 }
      yield()
      if time >= (SM.tl or 0) then SM.tl = time + 0.5; SM.line(vc, string.format("right%+d+%.1f", ang, time - t1)) end
      local u = V.upness(vc.node)
      if u > best then best = u end
    end
    local u = V.upness(vc.node)
    P("SM right: arm to %+d deg (%s): upness %.2f (best %.2f)", ang, SM.curs(vc), u, best)
    if u > 0.8 then used = ang; break end
    SM.set(vc, 1, "angle", 0)
    wait(4)
  end
  SM.set(vc, 1, "angle", 0)
  wait(4)
  local i = assembly.info(vc.node)
  local w = i.angVel
  V.check("rights_itself", used ~= nil and V.upness(vc.node) > 0.8, "the arm put it back on its wheels (arm %s, upness %.2f, spin %.2f rad/s)", tostring(used), V.upness(vc.node), len(w.x, w.y, w.z))
  local b = SM.ride(vc, "after", 4, { vt = 3 })
  V.check("drives_after", not b.fell and b.vmax > 1.5, "drives off afterwards (%.2f m/s)", b.vmax)
  return true
end
-- the posed state, for comparing: each joint's position and setpoint, and
-- each wheel's mount where the joints have it (hull frame)
function SM.snap(vc)
  local t = {}
  for _, r in ipairs(vc.R2.robo or {}) do
    local st = r.d.st or {}
    t[#t + 1] = string.format("%s%.2f/%.2f", r.kind:sub(1, 1), r.cur or 0, (r.kind == "piston") and (st.extension or 0) or (st.angle or 0))
  end
  for _, w in ipairs(vc.R2.wheels or {}) do
    if w.onRobo then t[#t + 1] = string.format("w%d(%.2f,%.2f,%.2f)", w.uid, w.cx or 0, w.cy or 0, w.cz or 0) end
  end
  return table.concat(t, " ")
end
local function pose_nest(vc)
  SM.set(vc, 1, "angle", 15); SM.set(vc, 2, "extension", 0.3); SM.set(vc, 3, "angle", -15)
  SM.ride(vc, "pose", 4, { vt = 0, drive = 0 })
  V.stop(vc)
end
T.keep = function(vc)
  pose_nest(vc)
  local s0 = SM.snap(vc)
  -- 1. a sleep: the controller skipped (dormant) for 3 s, then woken
  -- (nobody at the controls meanwhile, or the first tick wakes it)
  local pil, aboard = vc.piloting, vc.crewAboard
  local t0, slept = time, 0
  while time - t0 < 3 do
    vc.piloting, vc.crewAboard = false, false
    vc.dormant, vc.DORM.far, vc.DORM.check = true, false, time
    yield()
    if vc.dormant then slept = slept + 1 end
  end
  vc.piloting, vc.crewAboard = pil, aboard
  vc.dormWake(vc.node)
  P("SM keep: dormant through %d of the frames", slept)
  wait(1.5)
  local s1 = SM.snap(vc)
  P("SM keep sleep: %s -> %s (piloting %s)", s0, s1, tostring(pil))
  V.check("sleep_keeps", s0 == s1, "the joints and mounts through a sleep and wake: %s / %s", s0, s1)
  local b = SM.ride(vc, "woken", 3, { vt = 4 })
  V.check("drives_woken", b.vmax > 2 and b.out == 4, "drives after waking (%.2f m/s, %d tyres)", b.vmax, b.out)
  V.stop(vc)
  s0 = SM.snap(vc)
  -- 2. a real save and load: the fleet written, the world loaded again
  local fo = findScript("flight_ops")
  if fo and fo.fleetSync then fo.fleetSync(true) end
  save.flush()
  P("SM keep: saved; loading the world again")
  local vn0, R0 = vc.node, vc.R2
  scene.load("system")
  yield()
  -- (the old world gone first: the old rover must not stand in for the new;
  -- by its controller's own tables, as a node handle's slot is reused)
  wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do if v.R2 == R0 then return nil end end
    return true
  end, 60, "the old world gone")
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    return gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 240, "the reload")
  local v2 = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid and v.R2 and v.R2 ~= R0 and #(v.R2.robo or {}) == 3 and v.R2.posed then return v end
    end
  end, 150, "the rover from the fleet")
  if not v2 then V.check("reload_keeps", false, "no rover after the reload"); return true end
  wait(3)
  local s2 = SM.snap(v2)
  P("SM keep reload: %s -> %s (node %s -> %s)", s0, s2, tostring(vn0 and vn0.id), tostring(v2.node.id))
  V.check("reload_keeps", s0 == s2, "the joints and mounts through a save and load: %s / %s", s0, s2)
  return true, v2
end
T.revert = function(vc)
  local l0 = SM.snap(vc)
  pose_nest(vc)
  local s0 = SM.snap(vc)
  local vs = findScript("vessel_spawner")
  local ok, why = vs.revertToLaunch()
  P("SM revert: %s %s (posed %s; launched %s)", tostring(ok), tostring(why), s0, l0)
  local vn = vc.node
  local v2 = wait_for(function()
    local v = nil
    for _, x in ipairs(findScripts("vessel_controller")) do if x.piloting and x.node and x.node.valid and x.node ~= vn then v = x end end
    if v then local i = assembly.info(v.node); if i and i.anchored and v.R2 and v.R2.posed then return v end end
  end, 150, "the revert")
  if not v2 then V.check("revert", false, "no craft after the revert (%s)", tostring(why)); return true end
  wait(3)
  local s1 = SM.snap(v2)
  V.check("revert_to_launch_pose", s1 == l0, "after the revert the joints are as launched: %s (launched %s, posed in flight %s)", s1, l0, s0)
  v2.releaseClamps()
  wait(2)
  pose_nest(v2)
  local s2 = SM.snap(v2)
  V.check("revert_then_moves", s2 == s0, "and pose as before: %s / %s", s2, s0)
  return true, v2
end

local function run_smid()
  local rig = params.rig or "pext"
  local vc = SM.launch(rig)
  if not vc then V.result(); return end
  local R2 = vc.R2
  P("SM craft: %d wheels, %d robo, bike %s, wheelbase %.2f, steers %s", #(R2.wheels or {}), #(R2.robo or {}), tostring(R2.bike), R2.wheelbase or -1,
    (function() local t = {} for _, w in ipairs(R2.wheels or {}) do t[#t + 1] = string.format("%d:%s%s", w.uid, tostring(w.steers), w.onRobo and "R" or "") end return table.concat(t, " ") end)())
  -- does it roll at all?
  local c0 = sub(assembly.info(vc.node).com, home())
  local t0 = time
  while time - t0 < 4 do vc.R2.cmd = { drive = 0.8, steer = 0 }; yield() end
  local c1 = sub(assembly.info(vc.node).com, home())
  local moved = len(c1.x - c0.x, c1.y - c0.y, c1.z - c0.z)
  V.check("moves", moved > 4, "4 s of stick from the stand: %.1f m", moved)
  if moved < 1 then
    local i = assembly.info(vc.node)
    local g = vc.gasState and vc.gasState()
    local ws = {}
    for _, w in ipairs(R2.wheels or {}) do
      ws[#ws + 1] = string.format("w%d out %s jointed %s gas %s k %s run %s", w.uid, tostring(w.out), tostring(w.jointed), tostring(w.gas ~= nil),
        w.gas and string.format("%.2f", w.gas.k or 1) or "-", tostring(w.gas and w.gas.run ~= nil))
    end
    P("SM stuck: anchored %s grounded %s why %s live %s drive %s | gas %s | %s", tostring(i.anchored), tostring(i.grounded), tostring(R2.why), tostring(R2.live),
      tostring(R2.drive), g and string.format("engines %s on %s rpm %s left %s", tostring(g.engines), tostring(g.on), tostring(g.rpm), tostring(g.left)) or "-", table.concat(ws, "; "))
    SM.line(vc, "stuck")
    V.result(); return
  end
  if not out_and_strip(vc, (rig == "curl") and 330 or 260) then V.result(); return end
  local fn = T[rig] or ((rig == "keep" or rig == "revert") and nil)
  if fn then
    local _, v2 = fn(vc)
    if v2 then vc, R2 = v2, v2.R2 end
  end
  if rig == "keep" or rig == "revert" then V.result(); return end
  if V.upness(vc.node) > 0.5 and #(R2.robo or {}) > 0 then
    V.stop(vc)
    if rig ~= "trailer" and rig ~= "hop" then SM.set(vc, 1, (R2.robo[1].kind == "piston") and "extension" or "angle", (R2.robo[1].kind == "piston") and 0.5 or 20); SM.ride(vc, "pre_persist", 3, { vt = 0, drive = 0 }) end
    SM.persist(vc)
  end
  V.result()
end
SP_RUN.smid = run_smid
