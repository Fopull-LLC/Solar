-- ── servo probe (tools/perf/servoprobe.sh): wheels on servo hinges ──
-- Spliced after ivaprobe_modes.lua, verifyprobe_modes.lua and
-- jumpprobe_modes.lua (V.*, JP.*). The player's bike (user://probe_dirtbike.json)
-- rebuilt by `rig` (strs):
--   none    as built (the control: an ordinary bike)
--   arm     a Servo Hinge between the engine and the swing arm, at the arm's
--           pivot (axis across the bike): the swing arm, its wheel and the
--           chain's rear sprocket swing on it (a tilting / lowering rear)
--   direct  the swing arm taken off and the rear wheel bolted to a Servo
--           Hinge on the engine at the arm's pivot (no suspension part)
--   elec    as `arm` but no Drive Chain: the rear wheel's own hub motor, a
--           Battery Pack under the saddle
--   far     as `arm` but the hinge 0.35 m above the pivot: the servo's arc
--           stretches the chain past its slack (the chain's limit)
-- Modes:
--   sservo  6 s of full W from where it rolls out (does it move?), out past
--           95 m, a flat strip, then cruising at ~7 m/s the servo is driven
--           to +`ang` (default 20), −`ang` and back to 0 while W holds the
--           speed: `SP T` lines every 0.25 s (speed, the hinge's angle, the
--           rear tyre in the hull's frame, the hull's pitch, the chain's share
--           of the drive), `SP R` per phase; then from a stop full W for
--           `accsecs` (default 5: `JP ACC`); `VP PASS|FAIL` and `VP RESULT`.
local SP = {}

local function sp_basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end

-- the bike rebuilt as `rig` asks; → bp, notes
function SP.rig(bp, rig)
  local arm, wheel, eng, chain, seat
  local maxu = 0
  for _, d in ipairs(bp.parts) do
    maxu = math.max(maxu, d.uid)
    if d.id == "swingArm" then arm = d end
    if type(d.id) == "string" and d.id:match("^gasE") then eng = d end
    if d.proc == "chain" or d.id == "chain" then chain = d end
    if d.seat == 1 or d.seat == true then seat = d end
  end
  for _, d in ipairs(bp.parts) do if d.wheel and d.wheel ~= "" and arm and d.parent == arm.uid then wheel = d end end
  if rig == "none" or not rig then return bp, "as built" end
  if not (arm and wheel and eng) then return nil, "no swing arm / rear wheel / engine in the craft" end
  -- the arm's pivot in the craft frame (its susp module's px, py, pz)
  local sm
  for _, m in ipairs(type(arm.mods) == "table" and arm.mods or {}) do if m.type == "susp" then sm = m end end
  local X, Y, Z = sp_basis(arm.yaw, arm.pitch, arm.roll)
  local px, py, pz = sm and sm.px or 0, sm and sm.py or 0, sm and sm.pz or 0
  local hx = arm.x + X[1] * px + Y[1] * py + Z[1] * pz
  local hy = arm.y + X[2] * px + Y[2] * py + Z[2] * pz
  local hz = arm.z + X[3] * px + Y[3] * py + Z[3] * pz
  if rig == "far" then hy = hy + 0.35 end
  local hu = maxu + 1
  local hinge = { uid = hu, id = "hinge", x = hx, y = hy, z = hz, yaw = 0, pitch = 0, roll = 0,
                  parent = eng.uid, att = "surface", sym = 0, mir = "", stage = 0 }
  local parts, links = {}, {}
  for _, d in ipairs(bp.parts) do
    local keep = true
    if rig == "direct" and d == arm then keep = false end
    if rig == "elec" and d == chain then keep = false end
    if keep then parts[#parts + 1] = d end
  end
  parts[#parts + 1] = hinge
  if rig == "direct" then wheel.parent = hu else arm.parent = hu end
  local gone = {}
  if rig == "direct" then gone[arm.uid] = true end
  if rig == "elec" and chain then gone[chain.uid] = true end
  for _, l in ipairs(bp.links or {}) do
    local drop = gone[l.a] or gone[l.b]
    -- the engine → arm link becomes engine → hinge → arm
    if (l.a == eng.uid and l.b == arm.uid) or (l.b == eng.uid and l.a == arm.uid) then drop = true end
    if not drop then links[#links + 1] = l end
  end
  links[#links + 1] = { a = eng.uid, b = hu, k = "surface", sa = "surface", sb = "surface", prim = 1 }
  if rig == "direct" then
    links[#links + 1] = { a = hu, b = wheel.uid, k = "surface", sa = "surface", sb = "surface", prim = 1 }
  else
    links[#links + 1] = { a = hu, b = arm.uid, k = "surface", sa = "surface", sb = "surface", prim = 1 }
  end
  if rig == "elec" and seat then
    local pu = hu + 1
    parts[#parts + 1] = { uid = pu, id = "packB", x = seat.x, y = seat.y - 0.35, z = seat.z, yaw = 0, pitch = 0, roll = 0,
                          parent = seat.uid, att = "surface", sym = 0, mir = "", stage = 0 }
    links[#links + 1] = { a = seat.uid, b = pu, k = "surface", sa = "surface", sb = "surface", prim = 1 }
  end
  bp.parts, bp.links = parts, links
  return bp, string.format("hinge %d at %.2f %.2f %.2f on %s (%s)", hu, hx, hy, hz, eng.id, rig)
end

function SP.launch(rig)
  V.tag = "servo_" .. rig
  local bp0 = V.dirtbike()
  if not bp0 then V.check("craft", false, "no craft file"); V.result(); return end
  local bp, note = SP.rig(bp0, rig)
  if not bp then V.check("rig", false, "%s", note); V.result(); return end
  P("SP rig %s: %s, %d parts", rig, note, #bp.parts)
  local seat
  JP.ids = {}
  for _, d in ipairs(bp.parts) do JP.ids[d.uid] = d.id; if (d.seat == 1 or d.seat == true) then seat = d.uid end end
  local vc = iv_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v, name = "Servo Bike", controls = bp.controls, groups = bp.groups, turned = bp.turned },
    "runway", seat and { { uid = seat, slot = 1, id = 1 } } or nil)
  if not vc then V.check("rollout", false, "no craft"); V.result(); return end
  wait(2)
  vc.releaseClamps()
  wait(2)
  return vc
end

-- the rear tyre (the wheel with the lowest lever) and the hinge
function SP.rear(vc)
  local best
  for _, w in ipairs(vc.R2.wheels or {}) do if not best or (w.a or 0) < (best.a or 0) then best = w end end
  return best
end
function SP.front(vc)
  local best
  for _, w in ipairs(vc.R2.wheels or {}) do if not best or (w.a or 0) > (best.a or 0) then best = w end end
  return best
end
function SP.hinge(vc) return (vc.R2.robo or {})[1] end
-- the rear tyre in the hull's frame (drawn poses both ends), m
function SP.tyreLocal(vc, w)
  local t = w and w.tyre
  local vn = vc.node
  if not (t and t.valid and vn and vn.valid) then return nil end
  local o = vn:toWorld(vec3(0, 0, 0))
  local ex, ey, ez = vn:toWorld(vec3(1, 0, 0)) - o, vn:toWorld(vec3(0, 1, 0)) - o, vn:toWorld(vec3(0, 0, 1)) - o
  local d = { x = t.x - o.x, y = t.y - o.y, z = t.z - o.z }
  return dot(d, ex), dot(d, ey), dot(d, ez)
end
function SP.state(vc, tag)
  local R2 = vc.R2
  local w = SP.rear(vc)
  local r = SP.hinge(vc)
  local lx, ly, lz = SP.tyreLocal(vc, w)
  local _, pitch = JP.att(vc)
  local j = w and w.tyre and w.tyre.valid and w.tyre:getcomponent("Joint")
  P("SP T %s v %.2f drive %.2f | hinge %s cur %.1f want %s stalled %s | rear w%d out %s jointed %s onRobo %s gas %s chainK %s | tyre local %s | joint pos %.3f anchor %.3f %.3f | pitch %.1f why %s live %s",
    tag, V.speed(vc), R2.drive or 0, r and r.uid or "-", r and r.cur or 0, r and tostring(r.d.st and r.d.st.angle) or "-",
    tostring(r and r.stalled), w and w.uid or -1, tostring(w and w.out), tostring(w and w.jointed), tostring(w and w.onRobo),
    tostring(w and w.gas ~= nil), w and w.gas and string.format("%.2f", w.gas.k or 1) or "-",
    lx and string.format("%.3f %.3f %.3f", lx, ly, lz) or "none", j and (j.position or 0) or -1,
    j and (j.otherAnchorX or 0) or 0, j and (j.otherAnchorY or 0) or 0, math.deg(pitch), tostring(R2.why), tostring(R2.live))
end
function SP.setAngle(vc, a)
  local r = SP.hinge(vc)
  if not r then return end
  if type(r.d.st) ~= "table" then r.d.st = {} end
  r.d.st.angle = a
end

local function run_sservo()
  local rig = params.rig or "none"
  local vc = SP.launch(rig)
  if not vc then return end
  local R2 = vc.R2
  P("SP craft: %d wheels, %d robo, bike %s, gas chained %s", #(R2.wheels or {}), #(R2.robo or {}), tostring(R2.bike), tostring(vc.GAS and vc.GAS.chained))
  for _, w in ipairs(R2.wheels or {}) do
    P("SP wheel %d a %.2f onRobo %s susp %s gas %s rs %s", w.uid, w.a or 0, tostring(w.onRobo), tostring(w.susp and w.susp.m.kind), tostring(w.gas ~= nil), tostring(w.rs))
  end
  -- 1. does it move at all? 6 s of full W from the stand (steering away from the base)
  local i0 = assembly.info(vc.node)
  local b0 = home()
  local c0 = sub(i0.com, b0)
  local t0 = time
  local vmax = 0
  while time - t0 < 6 do
    vc.R2.cmd = { drive = 1, steer = 0 }
    yield()
    vmax = math.max(vmax, V.speed(vc))
    if time - (SP.tt or 0) > 1.0 then SP.tt = time; SP.state(vc, string.format("roll+%.0f", time - t0)) end
  end
  local c1 = sub(assembly.info(vc.node).com, home())
  local moved = len(c1.x - c0.x, c1.y - c0.y, c1.z - c0.z)
  V.check("moves", moved > 8 and vmax > 3, "full W 6 s from the stand: %.1f m, top %.1f m/s", moved, vmax)
  if moved < 2 then V.result(); return end
  -- 2. out to a flat strip
  if not JP.strip(vc, -15, 260) then return end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the strip")
  -- 3. cruise at vt, the servo driven while it rolls
  local vt = tonumber(params.vt or 7)
  local ang = tonumber(params.ang or 20)
  local phases = { { "lead", nil, 6 }, { "up", ang, 4 }, { "down", -ang, 5 }, { "zero", 0, 4 } }
  if not SP.hinge(vc) then phases = { { "lead", nil, 6 }, { "cruise", nil, 13 } } end
  local fell = false
  local res = {}
  -- (fresh=1, the default: every tyre hung again as the lead-in starts, so
  -- the mounts the phases are measured against are made the way the
  -- servo's are, not left from the rollout: a plain bike's rear tyre sat
  -- 0.615 or 0.700 in its hull frame on two runs of the same craft)
  if (tonumber(params.fresh) or 1) > 0 and vc.roboRehang then
    local i = assembly.info(vc.node)
    for _, w in ipairs(R2.wheels or {}) do vc.roboRehang(vc.node, w, i) end
    P("SP lead: every tyre hung again (%d)", #(R2.wheels or {}))
  end
  for _, ph in ipairs(phases) do
    if ph[2] ~= nil then SP.setAngle(vc, ph[2]) end
    local p0 = time
    local s = { n = 0, v = 0, vmin = 99, tyre = nil, pitch = 0, cur = 0, kmin = 1 }
    while time - p0 < ph[3] do
      local drive, st = JP.cruise(vc, vt, true)
      vc.R2.cmd = { drive = drive, steer = st }
      yield()
      local sp = V.speed(vc)
      s.n, s.v = s.n + 1, s.v + sp
      if time - p0 > 1.5 then s.vmin = math.min(s.vmin, sp) end
      local w = SP.rear(vc)
      if w and w.gas then s.kmin = math.min(s.kmin, w.gas.k or 1) end
      if time - (SP.tt or 0) > 0.25 then SP.tt = time; SP.state(vc, ph[1] .. string.format("+%.2f", time - p0)) end
      if V.upness(vc.node) < 0.4 then fell = true; break end
      if V.strip and JP.along(vc) > V.strip.d1 - 25 then P("SP strip end"); break end
    end
    local w = SP.rear(vc)
    local lx, ly = SP.tyreLocal(vc, w)
    local _, pitch = JP.att(vc)
    local r = SP.hinge(vc)
    local fx, fy = SP.tyreLocal(vc, SP.front(vc))
    res[ph[1]] = { v = s.v / math.max(1, s.n), vmin = s.vmin, ly = ly, lx = lx, fy = fy, pitch = math.deg(pitch), cur = r and r.cur or 0, kmin = s.kmin }
    P("SP R %s: mean %.2f m/s (min %.2f after 1.5 s), hinge %.1f deg, rear tyre local x %.3f y %.3f, front tyre local x %.3f y %.3f, pitch %.1f, chain share min %.2f, rehangs %d%s",
      ph[1], res[ph[1]].v, s.vmin, res[ph[1]].cur, lx or -99, ly or -99, fx or -99, fy or -99, math.deg(pitch), s.kmin, vc.R2.rehangs or 0, fell and " FELL" or "")
    if fell then break end
  end
  vc.R2.cmd = { drive = 0, steer = 0 }
  -- 4. a standing start, full stick, the servo where it is (the control's
  -- number to compare an ordinary bike against: JP ACC)
  -- (with a servo: held at `accang`, default +`ang`, first — the drive at an
  -- angle, or for the `far` rig, the chain past its slack)
  local acc, kacc, aacc = nil, 1, 0
  if not fell then
    V.stop(vc)
    local r = SP.hinge(vc)
    if r then
      aacc = tonumber(params.accang or ang)
      SP.setAngle(vc, aacc)
      wait_for(function() return math.abs(r.cur - aacc) < 0.5 end, 8, "the servo")
      wait(0.5)
      V.stop(vc)
    end
    local w = SP.rear(vc)
    kacc = w and w.gas and (w.gas.k or 1) or 1
    P("SP ACC at hinge %.1f deg, chain share %.2f", r and r.cur or 0, kacc)
    acc = JP.accel(vc, tonumber(params.accsecs or 5))
    vc.R2.cmd = { drive = 0, steer = 0 }
  end
  P("SP rehangs %d", vc.R2.rehangs or 0)
  V.check("upright", not fell, "stayed up through every phase")
  local L = res.lead
  V.check("cruise", L and L.v > vt * 0.6, "lead-in cruise %.2f m/s (asked %.0f)", L and L.v or -1, vt)
  if SP.hinge(vc) and res.up and res.down and res.zero then
    local U, D, Z = res.up, res.down, res.zero
    V.check("servo_moves", math.abs(U.cur - ang) < 1 and math.abs(D.cur + ang) < 1 and math.abs(Z.cur) < 1,
      "hinge reached %.1f / %.1f / %.1f (asked %d / %d / 0)", U.cur, D.cur, Z.cur, ang, -ang)
    V.check("wheel_follows", U.ly and D.ly and math.abs(U.ly - D.ly) > 0.05,
      "rear tyre height in the hull frame %.3f (up) vs %.3f (down): %.3f m apart", U.ly or -99, D.ly or -99, (U.ly or 0) - (D.ly or 0))
    local L0 = res.lead
    -- (where a tyre rests on its spring is not unique: on one craft a plain
    -- bike's rear sat 0.615 to 0.700 in its hull frame from run to run, so
    -- this is a reading, not a check)
    P("SP mounts back at 0: rear %.3f (lead %.3f), front %.3f (lead %.3f)", Z.ly or -99, L0 and L0.ly or -99, Z.fy or -99, L0 and L0.fy or -99)
    if acc and kacc < 0.01 then
      V.check("chain_slips", acc.vmax < 3, "the chain past its slack at %d deg: full stick from a stop reaches %.2f m/s (the wheel rolls free)", aacc, acc.vmax)
    elseif acc then
      V.check("accel_at_angle", acc.vmax > 10, "full stick from a stop with the servo at %d deg (chain share %.2f): top %.2f m/s", aacc, kacc, acc.vmax)
    end
    V.check("drives_while_servo", U.vmin > 2 and D.vmin > 2 and Z.vmin > 2, "slowest after each move: %.2f / %.2f / %.2f m/s", U.vmin, D.vmin, Z.vmin)
  end
  V.result()
end
SP_RUN = { sservo = run_sservo }
