-- THIRTY KILOMETRES: the probe's solution (tools/perf/scnprobe.sh <engine> thirty_km).
-- Spliced after scnprobe_modes.lua. Plays the night through the game's own
-- controls: the rover driven by its stick (vessel_controller R2.cmd, the
-- keys a headless run can't press), the lamps by their group, the Repair Kit
-- by item_hand's repair job, the cell out of Asha-1's locker into the pack,
-- the convoy led home while Kit drives Asha-2 on the `drive` beat.
--   BENCH_STRS='("variant", "crawl")': Ray stays with Kit, the convoy at a
--     crawl (the default is "split": Ray rides Asha-1, Kit follows).
--   BENCH_STRS='("route", "flats")': the long way round (default: the ridge).
--   BENCH_STRS='("real", "350")': metres of each leg driven for real; the
--     rest of the leg is FAST-FORWARDED in 40 m hops along the route (a run
--     must stay under six minutes: 1.9 km each way is eight minutes of
--     driving). The par is the real legs' speed over the full distance.
--   BENCH_STRS='("mode", "gen")': rebuild the rover JSONs through the VAB
--     (the records below; written to save/user/scnshots/*.json).
local HP = math.pi / 2
local TK = { cam = nil }
local function n3(x, y, z) local l = math.sqrt(x * x + y * y + z * z) return x / l, y / l, z / l, l end

-- ── the rovers, as built (mode gen) ─────────────────────────────────────────
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local function wheels(t, first, body, x0, x1, y, z)
  t[#t + 1] = rec(first, "wheelL", x0, y, z, { yaw = -HP, parent = body, att = "surface", sym = 1, mir = "z" })
  t[#t + 1] = rec(first + 1, "wheelL", x0, y, -z, { yaw = HP, parent = body, att = "surface", sym = 1, mir = "z" })
  t[#t + 1] = rec(first + 2, "wheelL", x1, y, z, { yaw = -HP, parent = body, att = "surface", sym = 2, mir = "z" })
  t[#t + 1] = rec(first + 3, "wheelL", x1, y, -z, { yaw = HP, parent = body, att = "surface", sym = 2, mir = "z" })
end
local CRAFT = {}
do -- Asha-1: four seats on a deck, a rear deck with a cell and a locker, two lamps
  local t = { rec(1, "roverBody", 0, 0.85, 0) }
  wheels(t, 2, 1, 0.75, -0.75, 0.6, 0.80)
  t[#t + 1] = rec(6, "panel3", 0, 1.02, 0, { parent = 1, att = "top" })
  t[#t + 1] = rec(7, "seat", 0.4, 1.69, 0.42, { parent = 6, att = "top" })
  t[#t + 1] = rec(8, "seat", 0.4, 1.69, -0.42, { parent = 6, att = "top" })
  t[#t + 1] = rec(9, "seat", -0.5, 1.69, 0.42, { parent = 6, att = "top" })
  t[#t + 1] = rec(10, "seat", -0.5, 1.69, -0.42, { parent = 6, att = "top" })
  t[#t + 1] = rec(11, "panel2", -1.5, 1.02, 0, { yaw = HP, parent = 6, att = "surface" })
  t[#t + 1] = rec(12, "battery", -1.5, 1.54, 0.5, { parent = 11, att = "top" })
  t[#t + 1] = rec(13, "locker", -1.5, 1.29, -0.5, { parent = 11, att = "top" })
  t[#t + 1] = rec(14, "light", 0.95, 0.85, 0.3, { parent = 1, att = "surface" })
  t[#t + 1] = rec(15, "light", 0.95, 0.85, -0.3, { parent = 1, att = "surface" })
  CRAFT.asha1 = t
end
do -- Asha-2: two seats on the body, the traction cell behind them, two lamps
  local t = { rec(1, "roverBody", 0, 0.85, 0) }
  wheels(t, 2, 1, 0.75, -0.75, 0.6, 0.80)
  t[#t + 1] = rec(6, "seat", 0.35, 1.65, 0.3, { parent = 1, att = "top" })
  t[#t + 1] = rec(7, "seat", 0.35, 1.65, -0.3, { parent = 1, att = "top" })
  t[#t + 1] = rec(8, "battery", -0.6, 1.5, 0, { parent = 1, att = "top" })
  t[#t + 1] = rec(9, "light", 0.95, 0.85, 0.3, { parent = 1, att = "surface" })
  t[#t + 1] = rec(10, "light", 0.95, 0.85, -0.3, { parent = 1, att = "surface" })
  CRAFT.asha2 = t
end
local function gen(SP)
  for _, nm in ipairs({ "asha1", "asha2" }) do
    save.set("shipyard.blueprint", { parts = CRAFT[nm] })
    save.set("shipyard.site", "pad")
    save.set("shipyard.pilot", 0)
    scene.load("builder")
    local Bd = wait_for(function() local Bd = findScript("builder"); return Bd and Bd.partUids and #Bd.partUids() >= #CRAFT[nm] and Bd end, 120)
    if not Bd then P("TK GEN %s: no builder", nm) else
      wait(1.5)
      local bp = Bd.blueprintNow()
      bp.name = nm == "asha1" and "Asha-1" or "Asha-2"
      local text = Bd.libText(bp)
      local ok = assets.writeText("user://scnshots/" .. nm .. ".json", text)
      P("TK GEN %s: %d parts, %d bytes, turned %s, written %s", nm, #bp.parts, #text, tostring(bp.turned), tostring(ok))
      SP.shot("gen_" .. nm, true)
    end
  end
end

-- ── a camera re-placed every frame from body-relative points ────────────────
function lateUpdate(node, dt)
  local f = TK.camw
  if not f then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt = f()
  if not (eye and tgt) then return end
  local name = space.dominant(eye.x, eye.y, eye.z)
  local b = name and space.body(name)
  if not b then return end
  pc.setFreecam(true)
  local fc = pc.freecamState and pc.freecamState()
  if not fc then return end
  local pos = vec3(eye.x - b.x, eye.y - b.y, eye.z - b.z)
  local u = pos:normalized()
  fc.body, fc.rel = name, pos
  local d = vec3(tgt.x - eye.x, tgt.y - eye.y, tgt.z - eye.z)
  local du = d:dot(u)
  local h = d - u * du
  fc.ref = h:normalized()
  fc.pitch = math.atan2(du, h:length())
end
local function cam_off()
  TK.camw = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
-- behind and above a craft, looking along its front (drawn pose: node:toWorld)
local function chase(vc, back, up, side, aheadLook)
  TK.camw = function()
    local n = vc and vc.node
    if not (n and n.valid) then return nil end
    local e = n:toWorld(vec3(-back, up, side or 0))
    local t = n:toWorld(vec3(aheadLook or 12, 0.5, 0))
    return { x = e.x, y = e.y, z = e.z }, { x = t.x, y = t.y, z = t.z }
  end
end
local function shot_at(SP, nm, secs) wait(secs or 1.4); SP.shot(nm, true) end

-- ── the dialogue ────────────────────────────────────────────────────────────
local POLICY = {}
local function talk(sr)
  local st = sr.state()
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    for k, v in pairs(POLICY) do
      if p:find(k, 1, true) then P("TK CHOICE %q → %d", p, v); sr.choose(v); return end
    end
  elseif st.line and st.line.t0 and (time - st.line.t0) > 0.8 then
    sr.lineDone()
  end
end
local function until_(sr, cond, tmo, what)
  local t0 = W()
  while W() - t0 < (tmo or 60) do
    talk(sr)
    if cond() then return true end
    yield()
  end
  P("TK TIMEOUT %s", tostring(what))
  SP.readings("timeout " .. tostring(what))
  return false
end
local function done(id) return (save.get("scn.done") or {})[id] ~= nil end
local function vcOf(name)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.craftName == name and v.node and v.node.valid then return v end
  end
  return nil
end
local function body() local n = save.get("base.body"); return n and space.body(n), n end

-- ── the stick: auto_drive.followLaw toward a ref, every frame (tick-pose
-- vectors of one read: assembly.info, the body now, the ref body-relative) ──
local function stick_to(sr, vc, ref, r, vmax, mem, dt)
  local A = findScript("auto_drive")
  local info = vc and vc.node and vc.node.valid and assembly.info(vc.node)
  local p = sr.posOf(ref)
  if not (A and A.followLaw and info and p) then return nil end
  local b = space.body(p.body)
  local o = info.origin
  local ux, uy, uz = n3(o.x - b.x, o.y - b.y, o.z - b.z)
  local d, s, I = A.followLaw({ fwd = info.right, up = { x = ux, y = uy, z = uz },
    d = { x = b.x + p.x - o.x, y = b.y + p.y - o.y, z = b.z + p.z - o.z }, v = info.vel, speed = vmax, r = r, dt = dt or (1 / 60), mem = mem })
  vc.R2.cmd = { drive = d, steer = s }
  return I
end
-- every rover's tick pose moved `m` metres along the ground toward `ref`
-- (a fast-forward: small hops so the tilt between frames stays a few degrees)
local function hop(sr, list, ref, m)
  local p = sr.posOf(ref)
  if not p then return end
  local b = space.body(p.body)
  local ground = sr.groundOf(b)
  local tx, ty, tz = n3(p.x, p.y, p.z)
  local lead = nil      -- (followers take the spot the leader hopped from: ground it drove)
  for k, vc in ipairs(list) do
    local info = vc and vc.node and vc.node.valid and assembly.info(vc.node)
    if info then
      local o = info.origin
      local ox, oy, oz, ol = n3(o.x - b.x, o.y - b.y, o.z - b.z)
      local g0 = ground({ x = ox, y = oy, z = oz }) or ol
      local clear = ol - g0
      local nx, ny, nz
      if k > 1 and lead then
        nx, ny, nz = lead.x, lead.y, lead.z
      else
        local dd = ox * tx + oy * ty + oz * tz
        local hx, hy, hz = n3(tx - ox * dd, ty - oy * dd, tz - oz * dd)
        local a = m / ol
        lead = { x = ox, y = oy, z = oz }
        nx, ny, nz = n3(ox * math.cos(a) + hx * math.sin(a), oy * math.cos(a) + hy * math.sin(a), oz * math.cos(a) + hz * math.sin(a))
      end
      local g1 = ground({ x = nx, y = ny, z = nz }) or g0
      local R1 = g1 + clear + 0.25
      assembly.teleport(vc.node, vec3(b.x + nx * R1, b.y + ny * R1, b.z + nz * R1))
    end
  end
end
local function dist_to(sr, a, ref)
  local p, q = sr.posOf(a), sr.posOf(ref)
  if not (p and q and p.body == q.body) then return nil end
  return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
end

-- drive the player's rover to `ref` (radius r), for real for the first `real`
-- metres, then fast-forward with `followers` riding the same hops
local SPEEDS = {}
local function leg(sr, vc, ref, r, vmax, real, followers, tag, shots)
  local mem = {}
  local d0 = dist_to(sr, "craft:Asha-1", ref) or 0
  local t0, start = W(), sr.posOf("craft:Asha-1")
  local gone, last = 0, nil
  local maxerr = 0
  local ok = until_(sr, function()
    local I = stick_to(sr, vc, ref, r * 0.6, vmax, mem, 1 / 60)
    if not I then return false end
    local p = sr.posOf("craft:Asha-1")
    if last and p then gone = gone + math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 + (p.z - last.z) ^ 2) end
    last = p
    if shots and shots[1] and gone >= shots[1].at then local s = table.remove(shots, 1); s.fn() end
    if W() - (TK.dbg or 0) > 3 then
      TK.dbg = W()
      P("TK STEER %s gone %.0f dist %.0f err %.2f vf %.2f vstar %.2f stuck %s cmd %.2f/%.2f", tag, gone, I.dist, I.err, I.vf, I.vstar, tostring(I.stuck),
        vc.R2.cmd.drive or 0, vc.R2.cmd.steer or 0)
    end
    if gone >= real or I.arrived then return true end
    return false
  end, 300, tag .. " (real)")
  local secs = W() - t0
  SPEEDS[#SPEEDS + 1] = { tag = tag, m = gone, s = secs }
  P("TK LEG %s: %.0f m real in %.1f s (%.2f m/s), %.0f m to go", tag, gone, secs, gone / math.max(secs, 0.1), dist_to(sr, "craft:Asha-1", ref) or -1)
  -- the rest: hops, then the last stretch for real
  local guard = 0
  while (dist_to(sr, "craft:Asha-1", ref) or 0) > r + 60 and guard < 120 do
    guard = guard + 1
    local list = { vc }
    for _, f in ipairs(followers or {}) do list[#list + 1] = f end
    vc.R2.cmd = { drive = 0, steer = 0 }
    hop(sr, list, ref, 40)
    for _ = 1, 20 do talk(sr); yield() end
  end
  until_(sr, function()
    local I = stick_to(sr, vc, ref, r * 0.6, vmax, mem, 1 / 60)
    return (I and I.arrived) or done(tag)
  end, 90, tag .. " (arrive)")
  vc.R2.cmd = { drive = 0, steer = 0 }
  return ok
end

local function board_player(sr, vc)
  local a = astro()
  local info = assembly.info(vc.node)
  for _ = 1, 40 do
    local n = vc.node
    local w = n:toWorld(vec3(0.4, 0.2, 1.4))
    a.x, a.y, a.z = w.x, w.y, w.z
    a.vx, a.vy, a.vz = 0, 0, 0
    yield()
    if vc.boardNow and vc.boardNow() then return true end
  end
  return false
end
local function get_out(sr)
  local C = findScript("crew")
  local id = C.activeId()
  local ok, why = C.eva(id, { confirmed = true })
  P("TK EVA %s %s", tostring(ok), tostring(why))
  wait_for(function() local pw = findScript("planet_walker"); return pw and pw.onFoot == true end, 10, "on foot")
  wait(0.8)
end
-- stand the player beside a part of a craft (its part frame, drawn pose)
local function stand_at_part(vc, uid, side)
  local a = astro()
  for _ = 1, 30 do
    local x, y, z = vc.partPointNow(uid, 0, 0, 0, true)
    if x then
      local n = vc.node
      local s = n:toWorld(vec3(0, 0, side or 1.6))
      local c = n:toWorld(vec3(0, 0, 0))
      a.x, a.y, a.z = x + (s.x - c.x), y + (s.y - c.y) + 0.2, z + (s.z - c.z)
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    yield()
  end
end
local function repair(sr, vc, uid, label)
  local IH = findScript("item_hand")
  IH.hold("repairkit")
  wait(0.5)
  local ok, why = IH.startRepair({ vessel = vc, uid = uid })
  P("TK REPAIR %s start %s %s (hp %.2f)", label, tostring(ok), tostring(why), vc.partHp(uid) or -1)
  until_(sr, function() return (vc.partHp(uid) or 0) > 0.9 end, 60, "repair " .. label)
  P("TK REPAIR %s hp %.2f", label, vc.partHp(uid) or -1)
end

-- mode "drive": the crew driver alone. Asha-2 is brought to the pad (the
-- `place` beat: rebuilt the right way up), mended and charged, Kit seated in
-- it, the `drive` beat set to follow Asha-1; Jonah drives Asha-1 out along
-- the road for `real` metres and back toward Caird while the gap is logged.
local function drivetest(SP)
  local sr = SP.run_()
  until_(sr, function() return not sr.state().cutscene end, 60, "opening")
  sr.skipCutscene()
  -- (out on the road, past the base's footprint: flight_ops holds a rebuild
  -- inside it until the base has stood up)
  sr.runBeat({ place = { craft = "Asha-1", at = "mark:r1" } })
  sr.runBeat({ place = { craft = "Asha-2", at = "mark:r1", offset = { 0, 0, -16 } } })
  local A2 = wait_for(function() local v = vcOf("Asha-2"); local p = v and vcOf("Asha-1") and dist_to(sr, "craft:Asha-2", "craft:Asha-1"); return p and p < 40 and v end, 80, "Asha-2 near")
  local A1 = vcOf("Asha-1")
  local FO = findScript("flight_ops")
  for fid, r in pairs(FO.fleetRecords() or {}) do P("TK FLEET %s %s landed %s live %s", fid, tostring(r.name), tostring(r.landed), tostring(FO.liveOf(fid) ~= nil)) end
  SP.check("place_far", A2 ~= nil, "Asha-2 rebuilt beside Asha-1: %s m", tostring(dist_to(sr, "craft:Asha-2", "craft:Asha-1")))
  if not A2 then return end
  wait(2)
  A2.repairPart(2, 1.0); A2.repairPart(8, 1.0)
  sr.runBeat({ charge = { craft = "Asha-2", frac = 1.0 } })
  sr.runBeat({ board = { who = "Nakamura", craft = "Asha-2", seat = 6 } })
  wait(1)
  local C = findScript("crew")
  local kv = C.craftOf((save.get("scn.crew") or {}).Nakamura)
  SP.check("kit_seated", kv and kv.craftName == "Asha-2", "Kit in %s", tostring(kv and kv.craftName))
  board_player(sr, A1)
  A1.fireGroup("lights")
  sr.runBeat({ drive = { craft = "Asha-2", follow = "craft:Asha-1", speed = 7, gap = 14 } })
  local real = tonumber(params.real or 300) or 300
  local mem, gone, last, gaps, a2last = {}, 0, nil, {}, nil
  local p20 = sr.posOf("craft:Asha-2")
  local t0 = W()
  local shot = false
  until_(sr, function()
    local I = stick_to(sr, A1, "mark:r2", 20, 5, mem, 1 / 60)
    local p = sr.posOf("craft:Asha-1")
    if last and p then gone = gone + math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 + (p.z - last.z) ^ 2) end
    last = p
    local g = dist_to(sr, "craft:Asha-1", "craft:Asha-2")
    if g and W() - t0 > 8 then gaps[#gaps + 1] = g end
    if W() - (TK.dbg or 0) > 3 then
      TK.dbg = W()
      local ns = A2.npcState and A2.npcState() or {}
      P("TK DRV gone %.0f · lead err %.2f vf %.2f · gap %.1f · kit active %s dist %.1f err %.2f vf %.2f vstar %.2f stuck %s why %s cmd %.2f/%.2f",
        gone, I and I.err or -9, I and I.vf or -9, g or -1, tostring(ns.active), ns.dist or -1, ns.err or -9, ns.vf or -9, ns.vstar or -9,
        tostring(ns.stuck), tostring(ns.why), ns.drive or 0, ns.steer or 0)
    end
    if not shot and gone > 120 then shot = true; chase(A2, 9, 3.2, 3, 4) end
    return gone >= real or (I and I.arrived)
  end, 200, "convoy test")
  if shot then SP.shot("05_convoy_test", true); cam_off() end
  local p21 = sr.posOf("craft:Asha-2")
  local moved = (p20 and p21) and math.sqrt((p21.x - p20.x) ^ 2 + (p21.y - p20.y) ^ 2 + (p21.z - p20.z) ^ 2) or 0
  local lo, hi = 1e9, 0
  for _, g in ipairs(gaps) do lo, hi = math.min(lo, g), math.max(hi, g) end
  SP.check("convoy_follows", moved > gone * 0.6 and hi < 45, "Kit followed: moved %.0f m of Asha-1's %.0f m in %.0f s, gap %.1f..%.1f m", moved, gone, W() - t0, lo, hi)
  A1.R2.cmd = { drive = 0, steer = 0 }
  wait(6)
  local ns = A2.npcState() or {}
  wait(8)
  ns = A2.npcState() or {}
  local gp = dist_to(sr, "craft:Asha-1", "craft:Asha-2") or -1
  SP.check("convoy_parks", gp > 8 and (ns.vf == nil or math.abs(ns.vf) < 0.8), "Kit closes up and stops behind a stopped leader, never into it: vf %.2f gap %.1f m", ns.vf or -1, gp)
  sr.finish()
end

function SOLVE(SP)
  if tostring(params.tk or "") == "gen" then gen(SP); return end
  if tostring(params.tk or "") == "drive" then drivetest(SP); return end
  local sr = SP.run_()
  local variant = tostring(params.variant or "split")
  local route = tostring(params.route or "ridge")
  local real = tonumber(params.real or 130) or 130
  POLICY = { ["Which way, Jonah"] = route == "flats" and 2 or 1, ["Which way?"] = route == "flats" and 2 or 1,
             ["How do we go home"] = variant == "crawl" and 2 or (variant == "abandon" and 3 or 1) }
  local b, bn = body()
  local A1, A2 = vcOf("Asha-1"), vcOf("Asha-2")
  -- ── the staged night ──
  local function up_dot(vc)
    local info = vc and assembly.info(vc.node)
    if not info then return -2 end
    local o = info.origin
    local bb = space.body(space.dominant(o.x, o.y, o.z))
    local ux, uy, uz = n3(o.x - bb.x, o.y - bb.y, o.z - bb.z)
    return info.up.x * ux + info.up.y * uy + info.up.z * uz
  end
  SP.check("staged_rovers", A1 ~= nil and A2 ~= nil, "Asha-1 %s, Asha-2 %s", tostring(A1 ~= nil), tostring(A2 ~= nil))
  if not (A1 and A2) then return end
  SP.check("asha2_upright", up_dot(A2) > 0.9, "Asha-2's up against the ground's: %.3f (rebuilt the right way up 1.9 km round)", up_dot(A2))
  SP.check("asha2_at_wreck", (dist_to(sr, "craft:Asha-2", "mark:wreck") or 99) < 4, "Asha-2 %.1f m from its mark", dist_to(sr, "craft:Asha-2", "mark:wreck") or -1)
  local cs2 = A2.controlState()
  SP.check("asha2_flat", (cs2.charge or 1) < 1, "Asha-2's charge %.1f of %.1f", cs2.charge or -1, cs2.cap or -1)
  SP.check("asha2_worn", (A2.partHp(2) or 1) < 0.2 and (A2.partHp(8) or 1) < 0.3, "hub %.2f, cradle %.2f", A2.partHp(2) or -1, A2.partHp(8) or -1)
  local CM = findScript("comms")
  local nb = CM and CM.beaconList and #CM.beaconList() or 0
  SP.check("beacons", nb >= 4, "%d relay beacons on the line", nb)
  local inv = findScript("inventory")
  local lk = A1.lockerOf and A1.lockerOf(13)
  SP.check("locker", lk and inv.itemCount(lk, "tractionCell") == 1, "Asha-1's locker %s holds the cell (%s)", tostring(lk), tostring(lk and inv.itemCount(lk, "tractionCell")))
  -- the opening, the hand-over, the route
  until_(sr, function() return not sr.state().cutscene end, 60, "opening")
  chase(A1, 7, 2.6, 2.5, 6)
  shot_at(SP, "01_pad_dusk")
  cam_off()
  until_(sr, function() return (sr.var("route") or "") ~= "" end, 90, "route chosen")
  until_(sr, function() local C = findScript("crew"); return C.craftOf(C.idOf and C.idOf("Berge") or (save.get("scn.crew") or {}).Berge) ~= nil end, 30, "Sunniva aboard")
  SP.check("route", sr.var("route") == route, "route %s", tostring(sr.var("route")))
  -- Jonah takes the controls; the cell comes along at the wreck
  SP.check("board", board_player(sr, A1), "Jonah boards Asha-1")
  SP.wait_step("board", 20)
  -- the lamps: their cost, measured at rest (EC/s drawn, off and on)
  wait(2.0)
  local r0 = A1.elecReadout()
  A1.fireGroup("lights")
  wait(2.5)
  local r1 = A1.elecReadout()
  P("TK LAMPS off: demand %.3f EC/s · on: demand %.3f EC/s (%d lit) · lamps %.3f EC/s · store %.0f EC = %.0f min of lamps alone",
    r0.demand, r1.demand, r1.lit, r1.demand - r0.demand, r1.cap, r1.cap / math.max(1e-3, r1.demand - r0.demand) / 60)
  SP.check("lamps", r1.lit >= 2 and r1.demand > r0.demand, "lamps lit %d, +%.3f EC/s", r1.lit, r1.demand - r0.demand)
  -- ── act 1: the drive out ──
  local legs = route == "ridge" and { { "r1", 30 }, { "r2", 45 }, { "r3", 35 } } or { { "f1", 40 }, { "f2", 40 }, { "f3", 40 } }
  local linked0 = A1.controlState and sr.linkUp("craft:Asha-1")
  P("TK LINK at the pad: %s", tostring(linked0))
  for i, L in ipairs(legs) do
    local shots = nil
    if i == 3 then shots = { { at = 110, fn = function() chase(A1, 8, 3.0, 0, 14); wait(0.01) end } } end
    leg(sr, A1, "mark:" .. L[1], L[2], 8, i == 2 and real or math.min(real, 250), {}, L[1], shots)
    if i == 3 then SP.shot("02_night_drive", true); cam_off() end
    P("TK LINK at %s: %s · Asha-1 %s %% · lamps %.0f EC · ray %s", L[1], tostring(sr.linkUp("craft:Asha-1")), tostring(sr.var("a1_pct")), sr.var("lamp_ec") or 0, tostring(sr.var("ray_air")))
    if not SP.wait_step(L[1], 20) then sr.completeStep(); wait(1) end
  end
  if route == "ridge" then
    SP.check("link_behind_ridge", sr.var("link_lost") == true or not sr.linkUp("craft:Asha-1"), "Caird's link past the crest: %s (lost %s)", tostring(sr.linkUp("craft:Asha-1")), tostring(sr.var("link_lost")))
  end
  -- ── act 2: Asha-2 ──
  leg(sr, A1, "mark:park", 6, 6, 120, {}, "park")
  SP.wait_step("arrive", 40)
  chase(A1, 5, 2.2, -3, 10)
  shot_at(SP, "03_arrival_lamps")
  cam_off()
  until_(sr, function() return not sr.state().cutscene end, 60, "arrival")
  get_out(sr)
  -- the cell out of Asha-1's locker into the pack
  A1 = vcOf("Asha-1") or A1
  local lk1 = A1.lockerOf(13)
  P("TK CELL locker %s holds %s", tostring(lk1), tostring(lk1 and inv.itemCount(lk1, "tractionCell")))
  local mv = lk1 and inv.moveItem(lk1, "astro", "tractionCell", 1)
  P("TK CELL moved %s · pack %d", tostring(mv), inv.itemCount("astro", "tractionCell"))
  A2 = vcOf("Asha-2")
  stand_at_part(A2, 2, 1.5)
  repair(sr, A2, 2, "hub")
  -- the repair, over the shoulder
  stand_at_part(A2, 8, -1.4)
  TK.camw = function()
    local a = astro()
    local n = A2.node
    if not (a and n and n.valid) then return nil end
    local c = n:toWorld(vec3(-0.6, 1.2, 0))
    local e = n:toWorld(vec3(1.6, 2.4, -4.2))
    return { x = e.x, y = e.y, z = e.z }, { x = (c.x + a.x) * 0.5, y = (c.y + a.y) * 0.5, z = (c.z + a.z) * 0.5 }
  end
  local IH = findScript("item_hand")
  IH.hold("repairkit")
  wait(0.5)
  local ok, why = IH.startRepair({ vessel = A2, uid = 8 })
  P("TK REPAIR cradle start %s %s", tostring(ok), tostring(why))
  wait(3.0)
  SP.shot("04_repair_cradle", true)
  until_(sr, function() return (A2.partHp(8) or 0) > 0.9 end, 60, "repair cradle")
  cam_off()
  stand_at_part(A2, 8, -1.4)
  until_(sr, function() return sr.var("cell_in") == true and (A2.controlState().charge or 0) > 100 end, 25, "cell fitted")
  SP.check("cell_fitted", sr.var("cell_in") == true and (A2.controlState().charge or 0) > 100, "Asha-2's charge %.0f of %.0f", A2.controlState().charge or -1, A2.controlState().cap or -1)
  until_(sr, function() return sr.var("patched") == true end, 60, "Sunniva's tape")
  SP.wait_step("hub", 10); SP.wait_step("cradle", 10); SP.wait_step("cell", 10)
  until_(sr, function() return (sr.var("plan") or "") ~= "" end, 90, "the plan")
  SP.check("plan", sr.var("plan") == variant, "plan %s", tostring(sr.var("plan")))
  -- ── act 3: the convoy ──
  until_(sr, function() return done("who") end, 20, "who latched")
  wait(1.0)
  -- back in Asha-1
  A1 = vcOf("Asha-1")
  board_player(sr, A1)
  local ray_seat = function() local C = findScript("crew"); local v = C.craftOf((save.get("scn.crew") or {}).Castellanos); return v and v.craftName end
  until_(sr, function()
    if variant == "abandon" then return true end
    local v2 = vcOf("Asha-2")
    local ns = v2 and v2.npcState and v2.npcState()
    return ns and ns.active
  end, 60, "Kit at the wheel")
  P("TK SEATS Ray in %s, Kit in %s", tostring(ray_seat()), tostring((function() local C = findScript("crew"); local v = C.craftOf((save.get("scn.crew") or {}).Nakamura); return v and v.craftName end)()))
  A2 = vcOf("Asha-2")
  local vlead = variant == "crawl" and 3.2 or 5.0
  -- the convoy for real: Kit must keep station behind Asha-1
  local gaps, a2moved, a2max = {}, 0, 0
  local p20 = sr.posOf("craft:Asha-2")
  local mem = {}
  local t0 = W()
  local gone, last = 0, nil
  local shot_done = false
  local target = route == "ridge" and "mark:r2" or "mark:f2"
  until_(sr, function()
    stick_to(sr, A1, target, 30, vlead, mem, 1 / 60)
    local p = sr.posOf("craft:Asha-1")
    if last and p then gone = gone + math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 + (p.z - last.z) ^ 2) end
    last = p
    if variant ~= "abandon" and A2 then
      local g = dist_to(sr, "craft:Asha-1", "craft:Asha-2")
      if g then gaps[#gaps + 1] = g end
      local inf = assembly.info(A2.node)
      if inf then a2max = math.max(a2max, math.sqrt(inf.vel.x ^ 2 + inf.vel.y ^ 2 + inf.vel.z ^ 2)) end
      if not shot_done and gone > 80 then
        shot_done = true
        chase(A2, 9, 3.2, 3, 4)
      end
      if shot_done and gone > 150 and gone < 152 then end
    end
    return gone >= real
  end, 240, "convoy (real)")
  if shot_done then SP.shot("05_convoy_front", true); cam_off() end
  if variant ~= "abandon" and A2 then
    local p21 = sr.posOf("craft:Asha-2")
    a2moved = (p20 and p21) and math.sqrt((p21.x - p20.x) ^ 2 + (p21.y - p20.y) ^ 2 + (p21.z - p20.z) ^ 2) or 0
    local lo, hi, sum = 1e9, 0, 0
    for _, g in ipairs(gaps) do lo, hi, sum = math.min(lo, g), math.max(hi, g), sum + g end
    local tail = {}
    for i = math.floor(#gaps / 3), #gaps do tail[#tail + 1] = gaps[i] end
    local tlo, thi = 1e9, 0
    for _, g in ipairs(tail) do tlo, thi = math.min(tlo, g), math.max(thi, g) end
    P("TK CONVOY %.0f m real in %.1f s: Asha-2 moved %.0f m, gap %.1f..%.1f (after the start %.1f..%.1f), its top speed %.2f m/s, hub heat %s",
      gone, W() - t0, a2moved, lo, hi, tlo, thi, a2max, tostring(sr.var("hub_heat")))
    SP.check("convoy_follows", a2moved > gone * 0.7 and thi < 45 and tlo > 4, "Kit kept station: moved %.0f of %.0f m, gap %.1f..%.1f m", a2moved, gone, tlo, thi)
    if variant == "crawl" then SP.check("crawl_speed", a2max < 4.4, "Asha-2's top speed %.2f m/s", a2max) end
    SP.check("hub_holds", sr.var("hub_failed") ~= true, "hub heat %s", tostring(sr.var("hub_heat")))
  end
  SPEEDS[#SPEEDS + 1] = { tag = "convoy", m = gone, s = W() - t0 }
  -- the rest of the way home: hops for both rovers, then the last stretch
  local list = { A1 }
  if variant ~= "abandon" and A2 then list[2] = A2 end
  local function home_leg(ref)
    local guard = 0
    while (dist_to(sr, "craft:Asha-1", ref) or 0) > 70 and guard < 100 do
      guard = guard + 1
      A1.R2.cmd = { drive = 0, steer = 0 }
      hop(sr, list, ref, 40)
      for _ = 1, 20 do talk(sr); yield() end
    end
  end
  if route == "ridge" then home_leg("mark:r1") else home_leg("mark:f1") end
  P("TK HOME blizzard %s · ray %s · a1 %s %%", tostring((findScript("weather") or {}).kind), tostring(sr.var("ray_air")), tostring(sr.var("a1_pct")))
  chase(A1, 8, 3.0, -2, 12)
  shot_at(SP, "06_blizzard_home", 1.0)
  cam_off()
  home_leg("mark:caird")
  until_(sr, function() stick_to(sr, A1, "mark:caird", 25, 4, mem, 1 / 60); return done("home") end, 90, "home")
  A1.R2.cmd = { drive = 0, steer = 0 }
  SP.wait_step("home", 10)
  until_(sr, function() return sr.var("debriefed") == true end, 90, "resolution")
  SP.wait_step("morning", 30)
  -- the par: the real legs' average speed over the full night
  local m, s = 0, 0
  for _, L in ipairs(SPEEDS) do m, s = m + L.m, s + L.s end
  local v = m / math.max(s, 1)
  P("TK PAR real legs %.0f m in %.0f s = %.2f m/s; ray min %s, a1 min %s %%, lamps %s EC over %s s, dist %s m",
    m, s, v, tostring(sr.var("ray_min")), tostring(sr.var("a1_min")), tostring(sr.var("lamp_ec")), tostring(sr.var("lamp_secs")), tostring(sr.var("dist_m")))
end
