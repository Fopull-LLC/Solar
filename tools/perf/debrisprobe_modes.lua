-- ── debris probe (tools/perf/debrisprobe.sh): spent stages packed out of the scene ──
-- scripts/debris_pack.lua. A three-stage rocket with two radial boosters —
-- Skipper, 2 FT-M (boosters: 2 × FT-S + Sputter on radial decouplers) |
-- Anvil, FT-M | Sputter, FT-S, pod, chute — flown from the VAB:
--   debrisrevert  booster ring and stage 1 dropped low, packed at once
--                 (PACK_DIST 60 m, PACK_HOLD 1 s), then REVERT TO BUILDER:
--                 nothing of the flight left in the scene or packed
--   debris        to orbit, every stage dropped on the way; then the frame
--                 cost coasting with the debris in the scene (`d_debris_live`,
--                 debris_pack off) against packed (`d_debris_packed`, on),
--                 and off again (`d_debris_live2`); `spheres=1` keeps the
--                 fall tick on through the ascent and d_debris_live; the PB RESULT lines
--                 carry the frame stats, nodes and draws
-- One `DB CHECK <name>: PASS|FAIL` line a check and `DB RESULT <mode>`.
local DB = { fails = 0 }
function DB.check(name, ok, fmt, ...)
  P("DB CHECK %s: %s — " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
  if not ok then DB.fails = DB.fails + 1 end
  return ok
end
function DB.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://debrisshots/" .. nm .. ".png", bytes); P("DB SHOT %s", nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function DB.roots()
  local crafts, roots, n = {}, {}, 0
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and not (v.isLost and v.isLost()) then crafts[v.node.id] = true end
  end
  for _, p in ipairs(findTagged("craftpart")) do
    local r = p.valid ~= false and p.parent
    if r and r.parent == nil and not crafts[r.id] and not roots[r.id] then roots[r.id] = true; n = n + 1 end
  end
  return n
end

local function rocket3b()
  puid = 0
  local R, y = {}, 0
  local up = { x = 0, y = 1, z = 0 }
  local function add(r) R[#R + 1] = r return r end
  local last = nil
  local function stack(id, h, o)
    o = o or {}
    local r = add(prec(id, 0, y + h / 2, 0, NOSE, up, { parent = last and last.uid or 0, att = last and "top" or "", stage = o.stage }))
    y = y + h
    last = r
    return r
  end
  stack("skipper", 1.6)
  local t1 = stack("tankM", 1.5)
  stack("tankM", 1.5)
  stack("decoupler", 0.25, { stage = 1 })
  stack("engineM", 1.6)
  stack("tankM", 1.5)
  stack("decoupler", 0.25, { stage = 2 })
  stack("engineS", 1.3)
  stack("tankS", 1.0)
  stack("pod", 0.8)
  stack("chute", 0.34)
  for _, s in ipairs({ 1, -1 }) do
    local out = { x = s, y = 0, z = 0 }
    local cy = t1.y
    local dec = add(prec("radialDec", s * 0.625, cy, 0, { x = 0, y = 0, z = 1 }, out, { parent = t1.uid, att = "surface", sym = 1, mir = "x" }))
    local bt = add(prec("tankS", s * 1.25, cy + 0.15, 0, NOSE, up, { parent = dec.uid, att = "surface", sym = 2, mir = "x" }))
    add(prec("engineS", s * 1.25, cy + 0.15 - 1.15, 0, NOSE, up, { parent = bt.uid, att = "bottom", sym = 3, mir = "x" }))
  end
  return R
end

local function db_launch()
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "engineM", "skipper", "radialDec", "decoupler" }) do if rs and rs.grant then rs.grant(id, "probe") end end
  local bp = rocket3b()
  local vc = launch_in_vab(bp, "pad", #bp, { name = "Debris Three" })
  return vc, #bp
end

-- SPACE, then follow the pilot onto whatever is flown now
local function stage_now(vc, tag)
  local before = DB.roots()
  P("DB STAGE %s: %s", tag, tostring(vc.stageNext()))
  wait(0.6)
  local nv = pilot()
  if nv and nv.node and nv.node.valid then vc = nv end
  P("DB after %s: %d parts flown, %d debris roots (was %d)", tag, #assembly.info(vc.node).parts, DB.roots(), before)
  return vc
end

local function run_debrisrevert()
  local dp = findScript("debris_pack")
  if not DB.check("packer", dp ~= nil, "debris_pack is in the scene") then P("DB RESULT debrisrevert: FAIL"); return end
  local vc = db_launch()
  if not DB.check("rollout", vc ~= nil, "the rocket rolled out") then P("DB RESULT debrisrevert: FAIL"); return end
  dp.PACK_DIST, dp.UNPACK_DIST, dp.PACK_HOLD = 60, 40, 1.0
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0 = time
  while time - t0 < 6 and vc.node.valid do vc.setThrottle(1); yield() end
  vc = stage_now(vc, "1 (boosters)")
  local t1 = time
  while time - t1 < 2 and vc.node.valid do vc.setThrottle(1); yield() end
  vc = stage_now(vc, "2 (stage 1)")
  local t2 = time
  while time - t2 < 12 and vc.node.valid do vc.setThrottle(1); yield() end
  local np = dp.packedCount()
  DB.check("packed", np >= 1, "%d piece(s) packed out of the scene (debris roots left %d; %s)", np, DB.roots(), dp.stats and string.format("scan %.2f ms", dp.stats.last_ms or -1) or "")
  local vs = findScript("vessel_spawner")
  local tag = vs and vs.flightTag and vs.flightTag()
  local okr, why = false, "no spawner"
  if vs and vs.revertToBuilder then okr, why = vs.revertToBuilder() end
  DB.check("revert", okr, "revert to the builder: %s", tostring(why or "ok"))
  wait(3)
  local left = tag and #findTagged(tag) or -1
  DB.check("revert_clean", dp.packedCount() == 0 and left == 0, "after the revert: %d packed, %d part(s) of the flight in the scene", dp.packedCount(), left)
  P("DB RESULT debrisrevert: %s (%d failed)", DB.fails == 0 and "PASS" or "FAIL", DB.fails)
end

local function coast(name, secs, vc)
  sc_begin(name)
  local t = time
  while time - t < secs and vc.node.valid do yield() end
  sc_note(name, "debris_roots", DB.roots())
  local dp = findScript("debris_pack")
  sc_note(name, "packed", dp and dp.packedCount() or -1)
  sc_end(name)
end

local function run_debris()
  local dp = findScript("debris_pack")
  if not DB.check("packer", dp ~= nil, "debris_pack is in the scene") then P("DB RESULT debris: FAIL"); return end
  -- spheres=1: the fall tick on (falling stages ride on spheres) and
  -- packing kept out until the packed window, as the game runs it
  dp.active = (params.spheres or 0) > 0
  if dp.active then dp.PACK_DIST = 1e9 end
  local vc, nparts = db_launch()
  if not DB.check("rollout", vc ~= nil, "the rocket rolled out") then P("DB RESULT debris: FAIL"); return end
  local vn = vc.node
  local S = body_state(vn)
  up_axis(vn, S.U)
  local b = S.b
  local wd = save.get("world." .. b.name) or {}
  local atmoH = (type(wd) == "table" and wd.atmoHeight) or b.radius * 0.3
  local APO = params.apo or math.max(atmoH * 1.25, b.radius * 0.15) + 40
  local PERI = params.peri or math.max(atmoH * 1.08, b.radius * 0.1) + 20
  P("DB world %s R %.0f atmo %.0f: apo %.0f peri %.0f", b.name, b.radius, atmoH, APO, PERI)
  vc.releaseClamps()
  vc.setSAS("stability")
  vc.setThrottle(1)
  local f0 = vc.fuel or 0
  -- the fuel at which each stage is spent: boosters 160, stage 1 320, stage 2 160
  local marks = { f0 - 160, f0 - 480, f0 - 640 }
  local staged = 0
  local alt0, phase, tstart = S.alt, "vertical", time
  while time - tstart < (params.ascentmax or 150) do
    yield()
    if not vn.valid then
      local nv = pilot(); if not nv then break end
      vc, vn = nv, nv.node
    end
    S = body_state(vn)
    if not S then break end
    local tilt = S.V > 1 and math.deg(math.acos(clamp(S.vr / S.V, -1, 1))) or 0
    if staged < 3 and (vc.fuel or 0) <= marks[staged + 1] + 0.5 then
      staged = staged + 1
      vc = stage_now(vc, tostring(staged)); vn = vc.node; BS_LAST = nil
      vc.setSAS(phase == "vertical" and "stability" or "prograde")
      vc.setThrottle((phase == "coast") and 0 or (phase == "circ" and params.circthr or 1))
    end
    if phase == "vertical" and S.alt - alt0 > 40 then phase = "kick"; key_down("s")
    elseif phase == "kick" and tilt > 8 then key_up("s"); vc.setSAS("prograde"); phase = "turn"
    elseif phase == "turn" and S.apo > APO then vc.setThrottle(0); phase = "coast"; P("DB MECO apo %.0f alt %.0f", S.apo, S.alt)
    elseif phase == "coast" and S.vr < 3 then vc.setThrottle(params.circthr); phase = "circ"; P("DB circ at alt %.0f", S.alt)
    elseif phase == "circ" and (S.peri > math.min(PERI, S.alt - 15) or (vc.fuel or 1) <= 0) then
      vc.setThrottle(0); phase = "orbit"; P("DB ORBIT apo %.0f peri %.0f fuel %.1f", S.apo, S.peri, vc.fuel or -1); break
    end
  end
  release_all()
  -- whatever is still aboard of the lower stages goes now (the probe wants
  -- every stage down)
  while staged < 3 do staged = staged + 1; vc = stage_now(vc, tostring(staged) .. " (late)"); vn = vc.node end
  DB.check("orbit", phase == "orbit", "phase %s, apo %.0f peri %.0f", phase, S and S.apo or -1, S and S.peri or -1)
  wait(params.settle or 20)
  local live = DB.roots()
  DB.check("debris_present", live >= 3, "%d debris root(s) in the scene with packing off", live)
  DB.shot("1_orbit_live")
  coast("d_debris_live", params.coast or 20, vc)
  P("DB fall tick so far: %d switch(es) to spheres, %d back to boxes", dp.fallStats and dp.fallStats.spheres or -1, dp.fallStats and dp.fallStats.boxes or -1)
  dp.active = true
  dp.PACK_DIST = 1000
  dp.PACK_HOLD = 1.0
  local tw = time
  wait_for(function() return dp.packedCount() >= live or time - tw > 25 end, 30, "packing")
  P("DB packed %d of %d (scan %.2f ms); list: %s", dp.packedCount(), live, dp.stats.last_ms or -1,
    (function() local o = {}; for _, e in ipairs(dp.packedList()) do o[#o + 1] = string.format("%s %s %d parts", e.name, e.kind, e.parts) end; return table.concat(o, " | ") end)())
  DB.check("packed", dp.packedCount() >= 1, "%d packed, %d still in the scene (nearest within %.0f m stay)", dp.packedCount(), DB.roots(), dp.PACK_DIST)
  coast("d_debris_packed", params.coast or 20, vc)
  DB.shot("2_orbit_packed")
  dp.active = false
  wait(5)
  DB.check("unpacked", dp.packedCount() == 0, "switched off, %d still packed, %d roots back", dp.packedCount(), DB.roots())
  coast("d_debris_live2", params.coast or 20, vc)
  P("DB RESULT debris: %s (%d failed)", DB.fails == 0 and "PASS" or "FAIL", DB.fails)
end
