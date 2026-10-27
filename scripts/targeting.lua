-- TARGETING — pick something to fly to, hold the craft on it, and dock with it.
--
--   SET A TARGET    right-click a world, a moon or a rock on the map, a craft on
--                   the map, or a craft or one of its parts in the world (the
--                   right-click menus: scripts/context_menu.lua + the registry)
--                   → "Set target". A DOCKING PORT is a target of its own.
--                   "Clear target" on any of those menus. The target rides
--                   the save (`target.sel`).
--   SAS TARGET ◉    (the navball grid, or ALT+0) points the nose at it;
--   ANTI-TARGET ⊘   points the nose away.
--   DOCKING         with a PORT targeted, SAS Target swings YOUR docking port
--                   onto THEIRS instead of the nose: the two axes face each
--                   other (anti-parallel), and the guide petals (three on our
--                   port) are rolled to interleave. Which of your ports docks
--                   is "Control from this port" on its right-click menu; with
--                   one free port it is that one, and with several and none
--                   picked, engaging SAS Target asks which (a menu listing
--                   them, the nearest first).
--   READOUT         the target's marker in the world (its name and distance,
--                   pinned to the screen's edge when it is off screen: the same
--                   tags salvage.lua and objectives.lua draw), on the map (and
--                   the closest approach of the two orbits), and with a port
--                   targeted the DOCKING INDICATOR: angle error, roll error,
--                   lateral offset, range and closing speed, the miss and the
--                   tilt drawn on a cross-hair.
--
-- THE MOVING PLANET. The home planet moves metres a tick, so nothing here keeps
-- a world position between frames: a target is a body NAME, a craft's NODE ID
-- (and its fleet id for the save) and a part UID, and its place is read again
-- every time it is asked for, in the frame of whoever asks (fixedUpdate:
-- physics-fresh `partFrameNow`; lateUpdate: the drawn pose).
--
-- The flight controller asks `steer(...)` for the SAS Target hold (its
-- fixedUpdate is at LuaJIT's upvalue ceiling, so the logic is here and its hook
-- is a few lines). The maths at the top (TM) is pure: tests/smoke_targeting.lua
-- loads this file in luajit and checks it.

defaults = {
  --@header Targeting
  --@range 0 1
  enabled = 1,
  --- The marker's distance is drawn this far at most (m).
  marker_range = 1e12,
  --- SAS Target's turn-rate gain near the target (1/s): the hold slows in
  --- proportion to the error inside this, so it settles instead of chattering.
  --@range 0.2 5
  klin = 1.2,
}

-- ── published ───────────────────────────────────────────────────────────────
-- The selection: { kind = "body", name } | { kind = "craft", id, fid, name }
-- | { kind = "part", id, fid, uid, port, name, craft }. nil = no target.
target = nil
-- Our docking port to dock with ("Control from this port"): { id, uid } on the
-- craft flown. nil = pick (the only free one), or ask.
ctrlPort = nil
-- The last readout lateUpdate measured (probes and the HUD read it):
-- { range, closing, lateral, along, angle, roll, myPort, name, port = bool }
readout = nil
-- The last few seconds' SAS Target hold, for probes: { angle, roll, rate, t }
steerLog = nil

-- ══ TM: pure maths (tests/smoke_targeting.lua) ═══════════════════════════════
TM = {}
local sqrt, abs, atan2, cos, sin, pi = math.sqrt, math.abs, math.atan2, math.cos, math.sin, math.pi

function TM.dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end
function TM.cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
function TM.len(x, y, z) return sqrt(x * x + y * y + z * z) end
function TM.norm(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
  if l < 1e-12 then return 0, 0, 0, 0 end
  return x / l, y / l, z / l, l
end
-- v rotated about the unit axis a by angle t (Rodrigues).
function TM.rotate(vx, vy, vz, ax, ay, az, t)
  local c, s = cos(t), sin(t)
  local cx, cy, cz = TM.cross(ax, ay, az, vx, vy, vz)
  local d = TM.dot(ax, ay, az, vx, vy, vz) * (1 - c)
  return vx * c + cx * s + ax * d, vy * c + cy * s + ay * d, vz * c + cz * s + az * d
end
-- The part of v across the unit axis a, normalised (nil when v is along a).
function TM.across(vx, vy, vz, ax, ay, az)
  local d = TM.dot(vx, vy, vz, ax, ay, az)
  local x, y, z, l = TM.norm(vx - ax * d, vy - ay * d, vz - az * d)
  if l < 1e-9 then return nil end
  return x, y, z
end
-- Angle between two unit vectors, radians, stable near 0 and pi.
function TM.angle(ax, ay, az, bx, by, bz)
  local cx, cy, cz = TM.cross(ax, ay, az, bx, by, bz)
  return atan2(TM.len(cx, cy, cz), TM.dot(ax, ay, az, bx, by, bz))
end

-- A rotation matrix (rows) → unit quaternion (w, x, y, z), w ≥ 0 (Shepperd).
function TM.quatFromMatrix(m)
  local m00, m01, m02 = m[1][1], m[1][2], m[1][3]
  local m10, m11, m12 = m[2][1], m[2][2], m[2][3]
  local m20, m21, m22 = m[3][1], m[3][2], m[3][3]
  local tr = m00 + m11 + m22
  local w, x, y, z
  if tr > 0 then
    local s = sqrt(tr + 1.0) * 2
    w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
  elseif m00 > m11 and m00 > m22 then
    local s = sqrt(1.0 + m00 - m11 - m22) * 2
    w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
  elseif m11 > m22 then
    local s = sqrt(1.0 + m11 - m00 - m22) * 2
    w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
  else
    local s = sqrt(1.0 + m22 - m00 - m11) * 2
    w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
  end
  local l = sqrt(w * w + x * x + y * y + z * z)
  w, x, y, z = w / l, x / l, y / l, z / l
  if w < 0 then w, x, y, z = -w, -x, -y, -z end
  return w, x, y, z
end

-- The rotation taking frame C (unit axis a, unit key k ⊥ a) onto frame W
-- (A, K), as an axis × angle vector in world space (radians). R = W·Cᵀ.
function TM.frameError(ax, ay, az, kx, ky, kz, Ax, Ay, Az, Kx, Ky, Kz)
  local bx, by, bz = TM.cross(ax, ay, az, kx, ky, kz)
  local Bx, By, Bz = TM.cross(Ax, Ay, Az, Kx, Ky, Kz)
  local C = { { ax, kx, bx }, { ay, ky, by }, { az, kz, bz } }
  local W = { { Ax, Kx, Bx }, { Ay, Ky, By }, { Az, Kz, Bz } }
  local R = {}
  for i = 1, 3 do
    R[i] = {}
    for j = 1, 3 do
      R[i][j] = W[i][1] * C[j][1] + W[i][2] * C[j][2] + W[i][3] * C[j][3]
    end
  end
  local w, x, y, z = TM.quatFromMatrix(R)
  local s = sqrt(x * x + y * y + z * z)
  if s < 1e-12 then return 0, 0, 0, 0 end
  local th = 2 * atan2(s, w)
  return x / s * th, y / s * th, z / s * th, th
end

-- The shortest rotation taking unit a onto unit A, axis × angle (radians).
-- Exactly opposite: a half turn about any axis across a.
function TM.pointError(ax, ay, az, Ax, Ay, Az)
  local cx, cy, cz = TM.cross(ax, ay, az, Ax, Ay, Az)
  local s = TM.len(cx, cy, cz)
  local c = TM.dot(ax, ay, az, Ax, Ay, Az)
  local th = atan2(s, c)
  if s < 1e-9 then
    if c > 0 then return 0, 0, 0, 0 end
    local px, py, pz = TM.across(1, 0, 0, ax, ay, az)
    if not px then px, py, pz = TM.across(0, 1, 0, ax, ay, az) end
    return px * pi, py * pi, pz * pi, pi
  end
  return cx / s * th, cy / s * th, cz / s * th, th
end

-- THE ROLL KEY. Two docking ports meet face to face, so OUR port's key must sit
-- where THEIR key, seen from the mating axis A (= −their axis), allows it:
-- `fold` keys around the ring (3 petals: every 120°), offset by `offset`
-- (petals interleave: 60°). Of those, the one nearest our key now, so the hold
-- never rolls further than it must. → Kx, Ky, Kz (⊥ A).
function TM.matchKey(Ax, Ay, Az, tkx, tky, tkz, mkx, mky, mkz, fold, offset)
  local bx, by, bz = TM.across(tkx, tky, tkz, Ax, Ay, Az)
  if not bx then return nil end
  local px, py, pz = TM.across(mkx, mky, mkz, Ax, Ay, Az)
  fold = math.max(1, math.floor(fold or 1))
  local best, bk = -2, nil
  for j = 0, fold - 1 do
    local kx, ky, kz = TM.rotate(bx, by, bz, Ax, Ay, Az, (offset or 0) + j * 2 * pi / fold)
    local d = px and TM.dot(kx, ky, kz, px, py, pz) or (j == 0 and 1 or -1)
    if d > best then best, bk = d, { kx, ky, kz } end
  end
  return bk[1], bk[2], bk[3]
end

-- Signed roll from our key to the wanted key about A (radians, −π..π).
function TM.rollError(Ax, Ay, Az, Kx, Ky, Kz, mkx, mky, mkz)
  local px, py, pz = TM.across(mkx, mky, mkz, Ax, Ay, Az)
  if not px then return 0 end
  local cx, cy, cz = TM.cross(px, py, pz, Kx, Ky, Kz)
  return atan2(TM.dot(cx, cy, cz, Ax, Ay, Az), TM.dot(px, py, pz, Kx, Ky, Kz))
end

-- The hold's turn rate for an error of `th` radians: the KSP braking law (the
-- fastest rate that can still stop on arrival), capped, and linear near zero
-- so it lands instead of hunting across the target.
function TM.rate(th, max_rate, accel, klin)
  if th <= 0 then return 0 end
  return math.min(max_rate or 1.0, sqrt(2 * (accel or 2.5) * th), (klin or 1.2) * th)
end

-- The wanted angular velocity (world) for an error vector (axis × angle).
function TM.command(ex, ey, ez, th, max_rate, accel, klin)
  if th < 1e-6 then return 0, 0, 0 end
  local r = TM.rate(th, max_rate, accel, klin) / th
  return ex * r, ey * r, ez * r
end

-- The approach, our port m to theirs q (q's outward axis a): range, closing
-- speed (+ = coming together), the miss across their axis (lateral) and how
-- far out along it we are (along, + = in front of their face).
function TM.approach(mx, my, mz, mvx, mvy, mvz, qx, qy, qz, qvx, qvy, qvz, ax, ay, az)
  local dx, dy, dz = mx - qx, my - qy, mz - qz
  local range = TM.len(dx, dy, dz)
  local rvx, rvy, rvz = mvx - qvx, mvy - qvy, mvz - qvz
  local closing = 0
  if range > 1e-6 then closing = -(dx * rvx + dy * rvy + dz * rvz) / range end
  local along, lateral = 0, range
  if ax then
    along = TM.dot(dx, dy, dz, ax, ay, az)
    lateral = sqrt(math.max(0, range * range - along * along))
  end
  return range, closing, lateral, along
end

-- WHERE A MARKER GOES on the screen: on its point when that is in front and
-- inside the margins (salvage.lua's and objectives.lua's rule: 40 px from the
-- sides and top, 120 from the bottom, × the interface scale k), else pinned to
-- the side to turn to. → "on", x, y | "left"/"right", x, y. `slot` stacks
-- several pins on one side; `band` is the height (0..1) this kind pins at.
-- `grace` (px, default 0) widens the margins (+) or narrows them (−): a marker
-- that was pinned last frame comes back only well inside, one that was on
-- stays on a little past the line (hysteresis: no flicker at the edge).
function TM.edgePin(sx, sy, dep, on, vx, vy, vw, vh, k, band, slot, grace)
  k = k or 1
  local gm = grace or 0
  local front = sx ~= nil and ((dep ~= nil and dep > 0) or on == true)
  if front and sx >= vx + 40 * k + gm and sx <= vx + vw - 40 * k - gm
    and sy >= vy + 40 * k + gm and sy <= vy + vh - 120 * k - gm then
    return "on", sx, sy
  end
  local right
  if sx and front then right = sx > vx + vw * 0.5 else right = not (sx and sx > vx + vw * 0.5) end
  local x = right and (vx + vw - 170 * k) or (vx + 170 * k)
  local y = vy + vh * (band or 0.30) + (slot or 0) * 26 * k
  return right and "right" or "left", x, y
end

-- The CLOSEST APPROACH of two bodies on conics about one mass: `prop(x,y,z,
-- vx,vy,vz, dt)` advances a state (space.propagate with µ bound). Sampled over
-- `span` seconds in `n` steps, then refined around the best. → t, d.
function TM.closestApproach(s1, s2, prop, span, n)
  n = n or 96
  local best_t, best_d = 0, TM.len(s1[1] - s2[1], s1[2] - s2[2], s1[3] - s2[3])
  local function at(t)
    local a = { prop(s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], t) }
    local b = { prop(s2[1], s2[2], s2[3], s2[4], s2[5], s2[6], t) }
    if not (a[1] and b[1]) then return nil end
    return TM.len(a[1] - b[1], a[2] - b[2], a[3] - b[3]), a, b
  end
  local step = span / n
  for i = 1, n do
    local d = at(i * step)
    if d and d < best_d then best_t, best_d = i * step, d end
  end
  local lo, hi = math.max(0, best_t - step), best_t + step
  for _ = 1, 24 do
    local m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
    local d1, d2 = at(m1), at(m2)
    if not (d1 and d2) then break end
    if d1 < d2 then hi = m2 else lo = m1 end
  end
  local tm = (lo + hi) / 2
  local dm = at(tm)
  if dm and dm < best_d then best_t, best_d = tm, dm end
  return best_t, best_d
end

-- RULE 7 (docs/positions-and-frames.md): what the player READS is smoothed,
-- frame-rate independently, never what SAS steers on. `prev` and `now` are
-- readouts (relative quantities: the same in any pose); a new target or a
-- jump (2 m of range, 30° of angle) snaps. → the smoothed table.
SMOOTH_KEYS = { "range", "closing", "lateral", "along", "angle", "roll", "missX", "missY", "tiltX", "tiltY" }
function TM.smooth(prev, now, dt, k, key)
  if not now then return nil end
  if not prev or prev._key ~= key or abs((prev.range or 0) - (now.range or 0)) > 2.0
    or abs((prev.angle or 0) - (now.angle or 0)) > 30 then
    local o = {}
    for kk, v in pairs(now) do o[kk] = v end
    o._key = key
    return o
  end
  local a = 1 - math.exp(-(k or 12) * (dt or 0))
  local o = {}
  for kk, v in pairs(now) do o[kk] = v end
  for _, kk in ipairs(SMOOTH_KEYS) do
    local p, n = prev[kk], now[kk]
    if p and n then
      if kk == "roll" then
        local d = (n - p + 180) % 360 - 180      -- the wrapped difference
        o[kk] = p + d * a
      else
        o[kk] = p + (n - p) * a
      end
    end
  end
  o._key = key
  return o
end

function TM.fmtDist(m)
  if not m then return "—" end
  local a = abs(m)
  if a < 1000 then return string.format("%.0f m", m) end
  if a < 1e7 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f km", m / 1000)
end
function TM.fmtTime(s)
  if not s or s ~= s then return "—" end
  if s < 60 then return string.format("%.0f s", s) end
  if s < 3600 then return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60)) end
  return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s / 60) % 60)
end

-- The DOCKING PORT's roll key (tools/gen_part_meshes.py part_dockport: three
-- guide petals around the ring, the first at 0.3 rad from the part's +X in
-- its XZ plane). A radial port mates along its +X; its key is then its +Y.
-- Androgynous petals interleave: our petal into their gap, 60° off.
PORT_KEY = { fold = 3, offset = pi / 3, petal = 0.3 }

-- A part's local X, Y, Z in its craft's frame, from the blueprint's YXZ euler
-- (vessel_controller part_axis / part_axis_x, the same formula).
function TM.partBasis(yaw, pitch, roll)
  local cy, sy = cos(yaw or 0), sin(yaw or 0)
  local cx, sx = cos(pitch or 0), sin(pitch or 0)
  local cz, sz = cos(roll or 0), sin(roll or 0)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end
-- The port's key in its craft's frame.
function TM.portKeyLocal(rec)
  local X, Y, Z = TM.partBasis(rec and rec.yaw, rec and rec.pitch, rec and rec.roll)
  if rec and (rec.att or "") == "radial" then return Y[1], Y[2], Y[3] end
  local c, s = cos(PORT_KEY.petal), sin(PORT_KEY.petal)
  return X[1] * c + Z[1] * s, X[2] * c + Z[2] * s, X[3] * c + Z[3] * s
end
-- ══ end TM ═══════════════════════════════════════════════════════════════════

-- ── plumbing ────────────────────────────────────────────────────────────────
local QUIET = { quiet = true }   -- (the builder scene has no map, no flight HUD)
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, QUIET) or nil; refs[kind] = r end
  return r
end
local function log_(s) if log then log("targeting: " .. s) end end

-- Every craft in the scene, by node id: listed at most once a frame.
local vc_cache = { t = -1, list = {}, by = {} }
local function vessels()
  local now = time or 0
  if vc_cache.t ~= now then
    local list, by = {}, {}
    for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
      if v.node and v.node.valid then list[#list + 1] = v; by[v.node.id] = v end
    end
    vc_cache = { t = now, list = list, by = by }
  end
  return vc_cache.list, vc_cache.by
end
local function vessel_by_id(id)
  if not id then return nil end
  local _, by = vessels()
  return by[id]
end
local function piloted()
  for _, v in ipairs(vessels()) do
    if v.piloting then return v end
  end
  return nil
end
local function lost(v) return v == nil or (v.isLost and v.isLost()) end
local function craft_name(v)
  if not v then return "craft" end
  return (v.craftName and v.craftName ~= "Vessel" and v.craftName) or (v.node and v.node.name) or "craft"
end

-- The fleet id of a live craft (the save names craft by it), or nil.
local function fid_of(v)
  local fo = ref("flight_ops")
  if not (fo and fo.fleetList and v and v.node) then return nil end
  local ok, list = pcall(fo.fleetList)
  if not ok then return nil end
  for _, e in ipairs(list or {}) do
    if e.nodeId == v.node.id then return e.fid end
  end
  return nil
end

-- The port records of a craft (the controller's own, cross-script), by uid.
local function port_rec(v, uid)
  for _, p in ipairs((v and v.dock and v.dock.ports) or {}) do
    if p.uid == uid then return p end
  end
  return nil
end
local function is_port(v, uid)
  local d = v and v.partRec and v.partRec(uid)
  return d ~= nil and (d.dock == 1 or d.dock == true or d.id == "dockPort")
end
-- A craft's free ports, numbered as the peripherals console numbers them.
local function free_ports(v)
  local out = {}
  local list = (v and v.dockPorts and v.dockPorts()) or {}
  for i, p in ipairs(list) do
    if not p.mate and not p.buried then out[#out + 1] = { uid = p.uid, n = i } end
  end
  return out
end

-- A port in the world, as the craft's physics frame stands NOW (fixedUpdate
-- and lateUpdate alike: partFrameNow): its centre, outward axis, roll key and
-- velocity. → table or nil.
local function port_geom(v, uid)
  if not (v and v.partFrameNow) then return nil end
  local F = v.partFrameNow(uid)
  local p = port_rec(v, uid)
  if not (F and p) then return nil end
  local function w(x, y, z)
    return F.rx * x + F.ux * y + F.zx * z, F.ry * x + F.uy * y + F.zy * z, F.rz * x + F.uz * y + F.zz * z
  end
  local ax, ay, az = TM.norm(w(p.ax or 0, p.ay or 1, p.az or 0))
  local kx, ky, kz = w(TM.portKeyLocal(v.partRec and v.partRec(uid)))
  kx, ky, kz = TM.across(kx, ky, kz, ax, ay, az)
  if not kx then kx, ky, kz = TM.across(F.rx, F.ry, F.rz, ax, ay, az) end
  local _, _, _, vx, vy, vz = v.partPointNow(uid, 0, 0, 0)
  return { x = F.ox, y = F.oy, z = F.oz, ax = ax, ay = ay, az = az, kx = kx, ky = ky, kz = kz,
           vx = vx or F.vx, vy = vy or F.vy, vz = vz or F.vz, free = not (p.mate or p.buried) }
end

-- The DRAWN pose of a port (docs/positions-and-frames.md rule 2: lines and
-- markers use drawn poses for both ends): the craft root's toWorld this pass.
-- → x, y, z, ax, ay, az, or nil.
local function port_drawn(v, uid)
  local p = port_rec(v, uid)
  local n = v and v.node
  if not (p and n and n.valid and n.toWorld) then return nil end
  local o = n:toWorld(vec3(p.x or 0, p.y or 0, p.z or 0))
  local a = n:toWorld(vec3((p.x or 0) + (p.ax or 0), (p.y or 0) + (p.ay or 1), (p.z or 0) + (p.az or 0)))
  return o.x, o.y, o.z, a.x - o.x, a.y - o.y, a.z - o.z
end
-- The target's drawn point: a world as this pass's space.body() has it, a
-- part on its craft root's drawn pose, a craft at its drawn root.
local function drawn_point(T)
  local t = target
  if not (T and t) then return nil end
  if T.body then return T.x, T.y, T.z end
  local v = T.v
  if not (v and v.node and v.node.valid) then return nil end
  if t.kind == "part" then
    local d = v.partRec and v.partRec(t.uid)
    if d and v.node.toWorld then
      local o = v.node:toWorld(vec3(d.x or 0, d.y or 0, d.z or 0))
      return o.x, o.y, o.z
    end
  end
  local w = v.node.worldPos
  if w then return w.x, w.y, w.z end
  return v.node.x, v.node.y, v.node.z
end

-- Where a craft is (its centre of mass) and how fast, this tick.
local function craft_state(v)
  local i = v and v.node and assembly and assembly.info(v.node)
  if i and i.com then return i.com.x, i.com.y, i.com.z, i.vel.x, i.vel.y, i.vel.z end
  local n = v and v.node
  if not n then return nil end
  return n.x, n.y, n.z, n.vx or 0, n.vy or 0, n.vz or 0
end

-- ── the selection ───────────────────────────────────────────────────────────
local SAVE_SEL, SAVE_PORT = "target.sel", "target.port"
local pending = nil      -- a saved target still waiting for its craft to load
local pend_t0 = nil

local function store()
  if not (save and save.set) then return end
  local t = target
  if not t then save.set(SAVE_SEL, false) return end
  save.set(SAVE_SEL, { kind = t.kind, name = t.name, fid = t.fid, uid = t.uid, port = t.port, craft = t.craft })
end

local function say(msg)
  log_(msg)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, msg) elseif caption then pcall(caption, msg) end
end

-- The docking lock on the craft flown follows a PORT target (so its capture
-- readout, magnetism and autopilot work that berth and no other).
local function sync_lock()
  local me = piloted()
  if not (me and me.dock) then return end
  local t = target
  if t and t.kind == "part" and t.port and t.id then
    local mine = ctrlPort and ctrlPort.id == me.node.id and ctrlPort.uid or nil
    local L = me.dock.lock
    if not (L and L.id == t.id and L.uid == t.uid and L.mine == mine and L.by == "targeting") then
      me.dock.lock = { id = t.id, uid = t.uid, mine = mine, by = "targeting" }
    end
  elseif me.dock.lock and me.dock.lock.by == "targeting" then
    me.dock.lock = nil
  end
end

function get() return target end

function clear(quiet)
  target = nil
  pending = nil
  store()
  sync_lock()
  if not quiet then say("target cleared") end
  return true
end

-- Set a target. `t` is a selection table (see `target`) or one of the helpers
-- below. → true, or false and why.
function set(t)
  if type(t) ~= "table" or not t.kind then return false, "nothing to target" end
  local me = piloted()
  if (t.kind == "craft" or t.kind == "part") and me and t.id == me.node.id then
    return false, "that is the craft you are flying"
  end
  target = t
  pending = nil
  store()
  sync_lock()
  say("target: " .. (t.name or t.kind))
  return true
end

function targetBody(name)
  if not (space and space.body and space.body(name)) then return false, "no such world" end
  return set({ kind = "body", name = name })
end
function targetCraft(v)
  if not (v and v.node and v.node.valid) then return false, "no craft" end
  return set({ kind = "craft", id = v.node.id, fid = fid_of(v), name = craft_name(v) })
end
function targetPart(v, uid)
  if not (v and v.node and v.node.valid and v.partRec and v.partRec(uid)) then return false, "no such part" end
  local d = v.partRec(uid)
  local port = is_port(v, uid)
  local cn = craft_name(v)
  return set({ kind = "part", id = v.node.id, fid = fid_of(v), uid = uid, port = port,
               craft = cn, name = string.format("%s · %s", cn, d.label or (port and "Docking Port") or "part") })
end

-- "Control from this port": our port to dock with. A uid on the craft flown.
function controlFrom(v, uid)
  if not (v and v.node and v.node.valid) then return false, "no craft" end
  if uid and not port_rec(v, uid) then return false, "not a docking port" end
  ctrlPort = uid and { id = v.node.id, uid = uid } or nil
  if save and save.set then
    local fid = uid and fid_of(v) or nil
    save.set(SAVE_PORT, uid and { fid = fid, uid = uid } or false)
  end
  sync_lock()
  if uid then say("docking from port " .. tostring(uid)) end
  return true
end

-- Our port, as SAS Target uses it: the one picked if it is still free and on
-- the craft flown; else the only free one; else nil (and how many there are).
function myPort(me)
  me = me or piloted()
  if not me then return nil, 0 end
  local free = free_ports(me)
  if ctrlPort and ctrlPort.id == me.node.id then
    for _, p in ipairs(free) do if p.uid == ctrlPort.uid then return p.uid, #free end end
  end
  if #free == 1 then return free[1].uid, 1 end
  return nil, #free
end

-- ── where the target is ─────────────────────────────────────────────────────
-- The target NOW: { x,y,z, vx,vy,vz (world), name, radius?, port? (port_geom),
-- v? (its controller) } or nil. World velocity = the craft's own (its
-- dominant body's frame, the engine's SOI convention) + that body's.
local function body_vel(x, y, z)
  local dn = space.dominant and space.dominant(x, y, z)
  local b = dn and space.body(dn)
  if not b then return 0, 0, 0 end
  return b.vx or 0, b.vy or 0, b.vz or 0
end
function resolve()
  local t = target
  if not t then return nil end
  if t.kind == "body" then
    local b = space.body(t.name)
    if not b then return nil end
    return { x = b.x, y = b.y, z = b.z, vx = b.vx or 0, vy = b.vy or 0, vz = b.vz or 0, name = t.name, radius = b.radius, body = true }
  end
  local v = vessel_by_id(t.id)
  if lost(v) then return nil end
  if t.kind == "part" then
    local F = v.partFrameNow and v.partFrameNow(t.uid)
    if not F then return nil end
    local G = t.port and port_geom(v, t.uid) or nil
    local _, _, _, pvx, pvy, pvz = v.partPointNow(t.uid, 0, 0, 0)
    local bx, by, bz = body_vel(F.ox, F.oy, F.oz)
    if G then G.vx, G.vy, G.vz = G.vx + bx, G.vy + by, G.vz + bz end
    return { x = F.ox, y = F.oy, z = F.oz, vx = (pvx or F.vx) + bx, vy = (pvy or F.vy) + by, vz = (pvz or F.vz) + bz,
             name = t.name, port = G, v = v }
  end
  local x, y, z, vx, vy, vz = craft_state(v)
  if not x then return nil end
  local bx, by, bz = body_vel(x, y, z)
  return { x = x, y = y, z = z, vx = vx + bx, vy = vy + by, vz = vz + bz, name = t.name, v = v }
end

-- Our own state, world velocity (as resolve's).
local function own_state(me)
  local x, y, z, vx, vy, vz = craft_state(me)
  if not x then return nil end
  local bx, by, bz = body_vel(x, y, z)
  return x, y, z, vx + bx, vy + by, vz + bz
end

-- ── SAS TARGET (vessel_controller asks, in fixedUpdate) ─────────────────────
-- `id` the asking craft's node id; n the nose (world, unit); mode "target" or
-- "antitarget"; the controller's own rate cap and braking acceleration.
-- → dwx, dwy, dwz (the wanted angular velocity, world), aimx, aimy, aimz (the
-- direction held, for the navball's aim ring) — or nil (hold still).
function steer(id, nx, ny, nz, mode, max_rate, accel)
  local me = vessel_by_id(id)
  if not me then return nil end
  local T = resolve()
  if not T or (T.v and T.v.node.id == id) then return nil end
  local klin = (params and params.klin) or defaults.klin
  local anti = mode == "antitarget"
  if T.port and not anti then
    local uid = myPort(me)
    local G = uid and port_geom(me, uid)
    if G then
      local Ax, Ay, Az = -T.port.ax, -T.port.ay, -T.port.az
      local Kx, Ky, Kz = TM.matchKey(Ax, Ay, Az, T.port.kx, T.port.ky, T.port.kz, G.kx, G.ky, G.kz,
        PORT_KEY.fold, PORT_KEY.offset)
      local ex, ey, ez, th
      if Kx then
        ex, ey, ez, th = TM.frameError(G.ax, G.ay, G.az, G.kx, G.ky, G.kz, Ax, Ay, Az, Kx, Ky, Kz)
      else
        ex, ey, ez, th = TM.pointError(G.ax, G.ay, G.az, Ax, Ay, Az)
      end
      local wx, wy, wz = TM.command(ex, ey, ez, th, max_rate, accel, klin)
      steerLog = { t = time or 0, angle = math.deg(TM.angle(G.ax, G.ay, G.az, Ax, Ay, Az)),
                   roll = Kx and math.deg(TM.rollError(Ax, Ay, Az, Kx, Ky, Kz, G.kx, G.ky, G.kz)) or 0,
                   rate = TM.len(wx, wy, wz), port = uid,
                   d = { T.port.x - G.x, T.port.y - G.y, T.port.z - G.z } }
      return wx, wy, wz, Ax, Ay, Az
    end
  end
  local ox, oy, oz = craft_state(me)
  if not ox then return nil end
  local dx, dy, dz, l = TM.norm(T.x - ox, T.y - oy, T.z - oz)
  if l < 1e-3 then return nil end
  if anti then dx, dy, dz = -dx, -dy, -dz end
  local ex, ey, ez, th = TM.pointError(nx, ny, nz, dx, dy, dz)
  local wx, wy, wz = TM.command(ex, ey, ez, th, max_rate, accel, klin)
  steerLog = { t = time or 0, angle = math.deg(th), roll = 0, rate = TM.len(wx, wy, wz) }
  return wx, wy, wz, dx, dy, dz
end

-- ── the approach readout ────────────────────────────────────────────────────
-- From the craft flown: range, closing speed and (a port target with one of
-- ours) the docking figures. nil without a target or a craft.
function measure(me)
  me = me or piloted()
  local T = resolve()
  if not T then return nil end
  local R = { name = T.name, port = T.port ~= nil }
  local ox, oy, oz, ovx, ovy, ovz
  if me then
    if T.v and T.v.node.id == me.node.id then return nil end
    ox, oy, oz, ovx, ovy, ovz = own_state(me)
  else
    local a = find and find("Astronaut")
    if not a then return nil end
    ox, oy, oz = a.x, a.y, a.z
    ovx, ovy, ovz = body_vel(ox, oy, oz)
  end
  if not ox then return nil end
  local uid = me and T.port and myPort(me) or nil
  local G = uid and port_geom(me, uid) or nil
  if G and T.port then
    local bx, by, bz = body_vel(G.x, G.y, G.z)
    local P = T.port
    R.range, R.closing, R.lateral, R.along = TM.approach(G.x, G.y, G.z, G.vx + bx, G.vy + by, G.vz + bz,
      P.x, P.y, P.z, P.vx, P.vy, P.vz, P.ax, P.ay, P.az)
    local Ax, Ay, Az = -P.ax, -P.ay, -P.az
    R.angle = math.deg(TM.angle(G.ax, G.ay, G.az, Ax, Ay, Az))
    local Kx, Ky, Kz = TM.matchKey(Ax, Ay, Az, P.kx, P.ky, P.kz, G.kx, G.ky, G.kz, PORT_KEY.fold, PORT_KEY.offset)
    R.roll = Kx and math.deg(TM.rollError(Ax, Ay, Az, Kx, Ky, Kz, G.kx, G.ky, G.kz)) or 0
    R.myPort = uid
    -- the two faces as measured (in the caller's frame: lateUpdate's is the drawn one)
    R.m = { G.x, G.y, G.z, G.ax, G.ay, G.az }
    R.q = { P.x, P.y, P.z, P.ax, P.ay, P.az }
    -- the miss and the tilt, on OUR port's face (right = its key, up = axis × key)
    local dx, dy, dz = G.x - P.x, G.y - P.y, G.z - P.z
    local al = TM.dot(dx, dy, dz, P.ax, P.ay, P.az)
    local mx, my, mz = dx - P.ax * al, dy - P.ay * al, dz - P.az * al
    local ux, uy, uz = TM.cross(G.ax, G.ay, G.az, G.kx, G.ky, G.kz)
    R.missX, R.missY = TM.dot(mx, my, mz, G.kx, G.ky, G.kz), TM.dot(mx, my, mz, ux, uy, uz)
    R.tiltX, R.tiltY = TM.dot(Ax, Ay, Az, G.kx, G.ky, G.kz), TM.dot(Ax, Ay, Az, ux, uy, uz)
  else
    R.range, R.closing = TM.approach(ox, oy, oz, ovx, ovy, ovz, T.x, T.y, T.z, T.vx, T.vy, T.vz)
    if T.body and T.radius then R.range = R.range - T.radius end
  end
  return R
end

-- ── the right-click menus ───────────────────────────────────────────────────
local function same(t)
  local c = target
  if not (c and t) then return false end
  if c.kind ~= t.kind then return false end
  if c.kind == "body" then return c.name == t.name end
  if c.kind == "craft" then return c.id == t.id end
  return c.id == t.id and c.uid == t.uid
end
local function rows_common(out, ctx, pick, current_label)
  local cur = same(pick)
  out[#out + 1] = { type = "action", id = "set", group = "TARGET",
    label = cur and "◉ Current target" or "Set target", hint = cur and "" or "◉",
    enabled = not cur, why = "already the target",
    act = function()
      local ok, why = set(pick)
      if ctx and ctx.toast then ctx.toast(ok and ("target: " .. (pick.name or "")) or why, not ok) end
      return ok, why
    end }
  if target then
    out[#out + 1] = { type = "action", id = "clear", group = "TARGET", label = "Clear target",
      hint = cur and "" or (target.name or ""),
      act = function() clear() return true end }
  end
end

-- a part of a craft in the world (the existing part menu)
local function part_rows(t, ctx)
  local v, uid = t.vessel, t.uid
  if not (v and v.node and v.node.valid and uid) then return {} end
  local out = {}
  local me = ctx and ctx.actor and ctx.actor.kind == "craft" and ctx.actor.vessel
  local own = me and me.node and me.node.id == v.node.id
  if own then
    -- our own craft: which port docks
    if is_port(v, uid) then
      local p = port_rec(v, uid)
      local on = ctrlPort and ctrlPort.id == v.node.id and ctrlPort.uid == uid
      out[#out + 1] = { type = "toggle", id = "ctrlport", group = "DOCKING", label = "Control from this port",
        keep = true, on = function() return ctrlPort ~= nil and ctrlPort.id == v.node.id and ctrlPort.uid == uid end,
        enabled = p ~= nil and not (p.mate or p.buried), why = "this port is mated or blocked",
        act = function(want) return controlFrom(v, want and uid or nil) end }
      if on then out[#out].hint = "◉" end
    end
    return out
  end
  local port = is_port(v, uid)
  local d = v.partRec(uid) or {}
  local pick = { kind = "part", id = v.node.id, uid = uid, port = port, craft = craft_name(v),
                 name = string.format("%s · %s", craft_name(v), d.label or "part") }
  local cur = same(pick)
  out[#out + 1] = { type = "action", id = "set", group = "TARGET",
    label = cur and "◉ Current target" or (port and "Set target (this docking port)" or "Set target (this part)"),
    hint = cur and "" or "◉", enabled = not cur, why = "already the target",
    act = function()
      pick.fid = fid_of(v)
      local ok, why = set(pick)
      if ctx and ctx.toast then ctx.toast(ok and ("target: " .. pick.name) or why, not ok) end
      return ok, why
    end }
  local cpick = { kind = "craft", id = v.node.id, name = craft_name(v) }
  if not same(cpick) then
    out[#out + 1] = { type = "action", id = "setcraft", group = "TARGET", label = "Set target (the whole craft)",
      act = function() return targetCraft(v) end }
  end
  if target then
    out[#out + 1] = { type = "action", id = "clear", group = "TARGET", label = "Clear target",
      act = function() clear() return true end }
  end
  return out
end

-- a world on the map
local function body_rows(t, ctx)
  if not t.name then return {} end
  local out = {}
  rows_common(out, ctx, { kind = "body", name = t.name })
  local b = space.body(t.name)
  if b then
    out[#out + 1] = { type = "info", id = "size", label = "Radius", value = TM.fmtDist(b.radius) }
    out[#out + 1] = { type = "info", id = "dist", label = "Distance", value = function()
      local me = piloted()
      local a = me and me.node or (find and find("Astronaut"))
      local bb = space.body(t.name)
      if not (a and bb) then return "—" end
      return TM.fmtDist(TM.len(a.x - bb.x, a.y - bb.y, a.z - bb.z) - bb.radius)
    end }
  end
  return out, t.name, "world"
end

-- a craft on the map
local function craft_rows(t, ctx)
  local v = t.vessel
  if not (v and v.node and v.node.valid) then return {} end
  local out = {}
  local me = piloted()
  if me and me.node.id == v.node.id then
    out[#out + 1] = { type = "info", id = "self", label = "The craft you are flying", value = "" }
    return out, craft_name(v), "craft"
  end
  rows_common(out, ctx, { kind = "craft", id = v.node.id, fid = fid_of(v), name = craft_name(v) })
  local ports = free_ports(v)
  if #ports > 0 then
    out[#out + 1] = { type = "sub", id = "ports", group = "TARGET", label = "Target a docking port",
      hint = string.format("%d ▸", #ports),
      sub = function()
        local rows = {}
        for _, p in ipairs(ports) do
          rows[#rows + 1] = { type = "action", id = "port" .. p.n, label = string.format("Port %d", p.n),
            act = function() return targetPart(v, p.uid) end }
        end
        return rows, "Its docking ports"
      end }
  end
  return out, craft_name(v), "craft"
end

-- WHICH OF OUR PORTS DOCKS: the prompt SAS Target raises with several free.
local function choice_rows(t, ctx)
  local me = piloted()
  if not me then return {} end
  local T = resolve()
  local out = {}
  local list = free_ports(me)
  local rows = {}
  for _, p in ipairs(list) do
    local G = port_geom(me, p.uid)
    local d = (G and T) and TM.len(G.x - T.x, G.y - T.y, G.z - T.z) or nil
    rows[#rows + 1] = { p = p, d = d or math.huge }
  end
  table.sort(rows, function(a, b) return a.d < b.d end)
  for i, r in ipairs(rows) do
    out[#out + 1] = { type = "action", id = "mine" .. r.p.n, group = "DOCK WITH",
      label = string.format("Port %d%s", r.p.n, i == 1 and "  (nearest)" or ""),
      hint = r.d < math.huge and TM.fmtDist(r.d) or "",
      act = function()
        local ok = controlFrom(me, r.p.uid)
        if ok and ctx and ctx.toast then ctx.toast("docking from port " .. r.p.n) end
        return ok
      end }
  end
  return out, "Dock with which port?", T and T.name or nil
end

local registered_with = nil
local function try_register()
  if registered_with and registered_with.valid ~= false then return true end
  local r = ref("context_registry")
  if not (r and r.register) then return false end
  r.register("part", part_rows, { id = "target", order = 5 })
  r.register("body", body_rows, { id = "target", order = 5 })
  r.register("craft", craft_rows, { id = "target", order = 5 })
  r.register("dockchoice", choice_rows, { id = "target", order = 5 })
  registered_with = r
  return true
end

-- ── the map: a right-click on a world or a craft ────────────────────────────
-- What is under a screen pixel on the map: the nearest world (inside its disc,
-- or within 18 px of its centre) or craft (18 px). → a menu target or nil.
function mapPick(sx, sy)
  if not (camera and camera.worldToScreen) then return nil end
  local best, bd = nil, 18.0
  for _, v in ipairs(vessels()) do
    if not lost(v) then
      local n = v.node
      local px, py, _, on = camera.worldToScreen(n.x, n.y, n.z)
      if on and px then
        local d = TM.len(px - sx, py - sy, 0)
        if d < bd then best, bd = { kind = "craft", vessel = v, node = n, label = craft_name(v), map = true }, d end
      end
    end
  end
  if best then return best end
  local bb, bbd = nil, math.huge
  local sh = 720
  if camera.screenSize then sh = select(2, camera.screenSize()) or 720 end
  for _, b in ipairs(space.bodies and space.bodies() or {}) do
    local px, py, dep, on = camera.worldToScreen(b.x, b.y, b.z)
    if on and px then
      local d = TM.len(px - sx, py - sy, 0)
      -- the disc on screen: radius × pixels per unit at its depth (the map's lens)
      local rpx = 0
      if dep and dep > 0 and camera.pixelsPerUnit then
        local ok, ppu = pcall(camera.pixelsPerUnit, dep)
        if ok and ppu then rpx = b.radius * ppu end
      end
      if (d < math.max(18, rpx)) and d < bbd then bb, bbd = b, d end
    end
  end
  if bb then return { kind = "body", name = bb.name, label = bb.name, map = true } end
  return nil
end

local rmb = nil
local function map_tap()
  local down = input.button(1) == true
  if down and not rmb then
    local mx, my = input.mouse()
    rmb = { t = time or 0, x = mx, y = my, moved = 0 }
    return nil
  end
  if rmb and down then
    local dx, dy = input.mouse_delta()
    rmb.moved = rmb.moved + abs(dx or 0) + abs(dy or 0)
    return nil
  end
  if rmb and not down then
    local r = rmb
    rmb = nil
    if (time or 0) - r.t <= 0.35 and r.moved <= 6 then return r end
  end
  return nil
end

-- Open the context menu on a map target (also for probes). → true if it opened.
function openMapMenu(t, sx, sy)
  local cm = ref("context_menu")
  if not (t and cm and cm.openFor and cm.actorNow) then return false end
  local who = cm.actorNow()
  if not who then return false end
  return cm.openFor(t, who, sx, sy)
end

-- ── the map drawing (orbit_map calls this in its pass) ──────────────────────
local ca = { t = -10, key = nil, res = nil }
function drawMap(subject, px_at, label, lk)
  local T = resolve()
  if not T then return end
  local me = piloted()
  local o = (me and me.node) or subject
  if not (o and camera and camera.worldToScreen) then return end
  -- drawn poses for the marks (rule 2): the target's drawn point, our drawn node
  local X, Y, Z = drawn_point(T)
  if not X then return end
  local r, g, b = 0.80, 0.55, 1.0
  local s = px_at(X, Y, Z, T.body and 0 or 9)
  if T.body then s = math.max(T.radius * 1.15, px_at(X, Y, Z, 12)) end
  -- a ring facing the camera (the map flies the game camera)
  local cam = find and find("Camera 1")
  local vx, vy, vz = 0, 1, 0
  if cam then vx, vy, vz = TM.norm(cam.x - X, cam.y - Y, cam.z - Z) end
  if vx == 0 and vy == 0 and vz == 0 then vx, vy, vz = 0, 1, 0 end
  draw.ring(X, Y, Z, vx, vy, vz, s, r, g, b, 0.95)
  draw.ring(X, Y, Z, vx, vy, vz, s * 1.25, r, g, b, 0.45)
  local d = TM.len(X - o.x, Y - o.y, Z - o.z) - (T.body and T.radius or 0)
  local sx, sy, _, on = camera.worldToScreen(X, Y, Z)
  if on and sx and label then
    local fs = 13 * (lk or 1)
    local spx = T.body and 0 or 12 * (lk or 1)
    label(sx, sy + spx + fs * 1.4, string.format("◉ %s  ·  %s", T.name or "target", TM.fmtDist(d)), fs)
  end
  -- THE CLOSEST APPROACH: both on conics about the body we are in (a craft
  -- in our sphere, or a moon of our world). Recomputed twice a second.
  if not (me and space.propagate and space.dominant) then return end
  local dn = space.dominant(o.x, o.y, o.z)
  local db = dn and space.body(dn)
  if not (db and (db.mu or 0) > 0) or T.name == dn then return end
  local tdn = T.body and nil or space.dominant(T.x, T.y, T.z)
  if not T.body and tdn ~= dn then return end
  if T.body then
    -- a body: only one that orbits ours (what owns the space just outside its sphere)
    local soi = (space.body(T.name) or {}).soi or -1
    if soi <= 0 or space.dominant(T.x + soi * 1.02, T.y, T.z) ~= dn then return end
  end
  local now = time or 0
  local key = tostring(T.name) .. dn
  if now - ca.t > 0.5 or ca.key ~= key then
    ca.t, ca.key, ca.res = now, key, nil
    local ox, oy, oz, ovx, ovy, ovz = own_state(me)
    if ox then
      local s1 = { ox - db.x, oy - db.y, oz - db.z, ovx - (db.vx or 0), ovy - (db.vy or 0), ovz - (db.vz or 0) }
      local s2 = { T.x - db.x, T.y - db.y, T.z - db.z, T.vx - (db.vx or 0), T.vy - (db.vy or 0), T.vz - (db.vz or 0) }
      local el = space.elements and space.elements(o.x, o.y, o.z, o.vx or 0, o.vy or 0, o.vz or 0)
      local span = (el and el.period) or 3600
      span = math.max(60, math.min(span, 6 * 3600))
      local mu = db.mu
      local function prop(x, y, z, vx2, vy2, vz2, dt) return space.propagate(x, y, z, vx2, vy2, vz2, mu, dt) end
      local okc, tmin, dmin = pcall(TM.closestApproach, s1, s2, prop, span, 96)
      if okc and tmin then
        local a = { space.propagate(s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], mu, tmin) }
        local bq = { space.propagate(s2[1], s2[2], s2[3], s2[4], s2[5], s2[6], mu, tmin) }
        ca.res = { t = tmin, d = dmin, a = a, b = bq, at = now }
      end
    end
  end
  local C = ca.res
  if C and C.a[1] and C.b[1] then
    local left = C.t - ((time or 0) - C.at)
    local ax, ay, az = db.x + C.a[1], db.y + C.a[2], db.z + C.a[3]
    local bx2, by2, bz2 = db.x + C.b[1], db.y + C.b[2], db.z + C.b[3]
    local ss = px_at(ax, ay, az, 5)
    draw.sphere(ax, ay, az, ss, 0.6, 1.0, 0.7, 0.9)
    draw.sphere(bx2, by2, bz2, ss, r, g, b, 0.9)
    draw.line(ax, ay, az, bx2, by2, bz2, r, g, b, 0.6)
    local px, py, _, on2 = camera.worldToScreen(bx2, by2, bz2)
    if on2 and px and label then
      local fs = 12 * (lk or 1)
      label(px, py - fs * 1.6, string.format("closest %s  in %s", TM.fmtDist(C.d), TM.fmtTime(math.max(0, left))), fs)
    end
  end
end

-- ── the world marker and the docking indicator (screen) ─────────────────────
local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end
-- salvage.lua's tag: a dark rounded plate and the text
local function tag(x, y, text, size, r, g, b, a)
  local w = chars(text) * size * 0.5 + size
  local h = size * 1.5
  draw.rect(x - w / 2, y - h / 2, w, h, 0.05, 0.03, 0.02, 0.66 * a, size * 0.35)
  draw.text(x, y - size * 0.62, text, size, r, g, b, a, "center")
end
local function blocked()
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ip = ref("inventory_panel")
  if ip and ip.open then return true end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then return true end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return true end
  return false
end

local VIOLET = { 0.82, 0.62, 1.0 }
PIN = { was = nil }   -- the marker's last placement (hysteresis)
local function draw_marker(T, R, vx, vy, vw, vh, k)
  local mx, my, mz = drawn_point(T)   -- (a world's marker is on its centre)
  if not mx then return end
  local sx, sy, dep, on = camera.worldToScreen(mx, my, mz)
  local text = string.format("◉ %s  ·  %s", T.name or "TARGET", TM.fmtDist(R and R.range))
  if R and R.closing and not T.body and abs(R.closing) >= 0.05 then
    text = text .. string.format("  ·  %+.1f m/s", R.closing)
  end
  local grace = (PIN.was == "on") and -12 * k or 12 * k
  local where, x, y = TM.edgePin(sx, sy, dep, on, vx, vy, vw, vh, k, 0.30, 0, grace)
  -- behind the camera the side follows the screen half: keep the last one
  -- until the point is clearly on the other side
  if where ~= "on" and PIN.was ~= "on" and PIN.was and where ~= PIN.was and sx
    and abs(sx - (vx + vw * 0.5)) < 60 * k then
    where = PIN.was
    x = (where == "right") and (vx + vw - 170 * k) or (vx + 170 * k)
  end
  PIN.was = where
  local c = VIOLET
  if where == "on" then
    tag(x, y - 26 * k, text, 14 * k, c[1], c[2], c[3], 1.0)
    draw.circleOutline(x, y, 11 * k, c[1], c[2], c[3], 0.9, 2 * k)
    draw.circleOutline(x, y, 4 * k, c[1], c[2], c[3], 0.9, 2 * k)
  else
    tag(x, y, where == "right" and (text .. "  ›") or ("‹  " .. text), 14 * k, c[1], c[2], c[3], 1.0)
  end
  return where, x, y
end

-- KSP's docking mode, small: a cross-hair where the dot is the MISS (our port
-- off their centreline) and the ring the TILT (where their axis points from
-- ours), a tick on the rim the ROLL; the figures under it. Green inside the
-- capture envelope (vessel_controller dock.captureR / alignMin / driftMax).
local function draw_indicator(me, R, vx, vy, vw, vh, k)
  local fh = ref("flight_hud")
  local L = fh and fh.layout
  local S = 118 * k
  local x0, y0
  if L and L.consoleRight and L.consoleTop then
    x0 = vx + L.consoleRight * k - S - 10 * k
    y0 = vy + L.consoleTop * k - S - 64 * k
  else
    x0 = vx + vw * 0.5 + 180 * k
    y0 = vy + vh - 330 * k
  end
  local d = me.dock or {}
  local good = R.range < (d.captureR or 0.55) * 3 and R.angle < 8 and abs(R.closing) < (d.driftMax or 1.5)
  local c = good and { 0.35, 1.0, 0.5 } or VIOLET
  local cx, cy = x0 + S / 2, y0 + S / 2
  draw.rect(x0 - 6 * k, y0 - 22 * k, S + 12 * k, S + 82 * k, 0.04, 0.035, 0.03, 0.78, 6 * k)
  draw.text(x0, y0 - 18 * k, "DOCK  ◉ PORT", 11 * k, 0.75, 0.72, 0.66, 1.0, "left")
  draw.rectOutline(x0, y0, S, S, 0.5, 0.48, 0.44, 0.7, 1)
  draw.rect(cx - S / 2, cy - 0.5, S, 1, 0.5, 0.48, 0.44, 0.5)
  draw.rect(cx - 0.5, cy - S / 2, 1, S, 0.5, 0.48, 0.44, 0.5)
  draw.circleOutline(cx, cy, S * 0.16, 0.5, 0.48, 0.44, 0.5, 1)
  -- the miss: ±2 m full scale (beyond, on the rim)
  local function clampr(px, py, rmax)
    local l = TM.len(px, py, 0)
    if l > rmax then px, py = px / l * rmax, py / l * rmax end
    return px, py
  end
  local full = math.max(2.0, math.min(20.0, R.range * 0.25))
  local mx, my = clampr((R.missX or 0) / full * S / 2, -(R.missY or 0) / full * S / 2, S / 2 - 3 * k)
  draw.circle(cx + mx, cy + my, 4.5 * k, c[1], c[2], c[3], 1.0)
  -- the tilt: 30° full scale
  local s30 = 0.5
  local tx, ty = clampr((R.tiltX or 0) / s30 * S / 2, -(R.tiltY or 0) / s30 * S / 2, S / 2 - 3 * k)
  draw.circleOutline(cx + tx, cy + ty, 9 * k, c[1], c[2], c[3], 0.9, 2 * k)
  -- the roll: a tick on the rim, at the roll error from the top
  local ra = math.rad(R.roll or 0)
  local rr = S * 0.46
  draw.circle(cx + math.sin(ra) * rr, cy - math.cos(ra) * rr, 3 * k, 1.0, 0.8, 0.3, 1.0)
  local fs = 11 * k
  local ty0 = y0 + S + 6 * k
  draw.text(x0, ty0, string.format("RNG %s", R.range < 100 and string.format("%.2f m", R.range) or TM.fmtDist(R.range)), fs, c[1], c[2], c[3], 1.0, "left")
  draw.text(x0 + S, ty0, string.format("%+.2f m/s", R.closing), fs, c[1], c[2], c[3], 1.0, "right")
  draw.text(x0, ty0 + 14 * k, string.format("LAT %.2f m", R.lateral or 0), fs, c[1], c[2], c[3], 1.0, "left")
  draw.text(x0 + S, ty0 + 14 * k, string.format("ANG %.1f°", R.angle or 0), fs, c[1], c[2], c[3], 1.0, "right")
  draw.text(x0, ty0 + 28 * k, string.format("ROLL %+.0f°", R.roll or 0), fs, c[1], c[2], c[3], 1.0, "left")
  local sm = me.sas_mode
  draw.text(x0 + S, ty0 + 28 * k, (sm == "target") and "SAS ◉" or "SAS —", fs, 0.75, 0.72, 0.66, 1.0, "right")
  draw.text(x0, ty0 + 42 * k, string.format("from port %s", tostring(R.myPort)), fs * 0.9, 0.6, 0.58, 0.54, 1.0, "left")
end

-- THE GUIDES, in the camera pass, both ends from DRAWN poses read in this
-- pass (port_drawn: each craft root's toWorld): a line from our port to
-- theirs, ending ON their port, its length at its middle, and a dot on their
-- face. (vessel_controller dockGuides adds their approach corridor, out of
-- their port, and inside 12 m the red miss bar from our port to it.)
local function draw_guides(me, R)
  local T = resolve()
  local t = target
  if not (T and T.v and t and t.uid and R.myPort) then return end
  local m, q = { port_drawn(me, R.myPort) }, { port_drawn(T.v, t.uid) }
  if not (m[1] and q[1]) then return end
  R.dm, R.dq = m, q
  local c = VIOLET
  draw.line(m[1], m[2], m[3], q[1], q[2], q[3], c[1], c[2], c[3], 0.85)
  draw.sphere(q[1], q[2], q[3], 0.18, c[1], c[2], c[3], 0.95)
  -- its length, at its middle (what the line IS, on the line)
  local sx, sy, _, on = camera.worldToScreen((m[1] + q[1]) / 2, (m[2] + q[2]) / 2, (m[3] + q[3]) / 2)
  if on and sx and (R.range or 0) > 1.5 then
    local _, _, _, vh = camera.screenRect()
    local k = (vh or 720) / uiH()
    draw.text(sx + 8 * k, sy - 6 * k, string.format("%.1f m", R.range), 11 * k, c[1], c[2], c[3], 0.9, "left")
  end
end

-- A GEOMETRY CHECK for probes (DEBUG_GEOM = true): this pass's port poses three
-- ways — partFrameNow, the part nodes' drawn poses, and the tick's (steer) —
-- and where they land on the screen. Published as GEOM.
DEBUG_GEOM = false
GEOM = nil
local function part_node(v, uid)
  for _, c in ipairs(v.node:children()) do
    if v.uidOfNode and v.uidOfNode(c) == uid then return c end
  end
  return nil
end
local function geom_check(me, R)
  local T = resolve()
  if not (T and T.v and R and R.m and R.q) then GEOM = nil return end
  local m, q = R.dm or R.m, R.dq or R.q        -- the drawn poses the guides used
  local fm, fq = R.m, R.q                      -- partFrameNow (tick) in this pass
  local mn, qn = part_node(me, R.myPort), part_node(T.v, target.uid)
  local mw = mn and mn.worldPos
  local qw = qn and qn.worldPos
  local dx, dy, dz = q[1] - m[1], q[2] - m[2], q[3] - m[3]
  local ux, uy, uz, l = TM.norm(dx, dy, dz)
  local along = TM.dot(dx, dy, dz, m[4], m[5], m[6])
  local G = {
    range = l,
    -- our axis against the line to their port, and how far their port sits
    -- off our axis (the docking axis passes through it when this is ~0)
    aimToPort = math.deg(TM.angle(m[4], m[5], m[6], ux, uy, uz)),
    rayMiss = math.sqrt(math.max(0, l * l - along * along)),
    antiPar = math.deg(TM.angle(m[4], m[5], m[6], -q[4], -q[5], -q[6])),
    -- the part nodes' own drawn poses against the guides' ends (should be ~0)
    nodeErrMine = mw and TM.len(mw.x - m[1], mw.y - m[2], mw.z - m[3]) or -1,
    nodeErrTheirs = qw and TM.len(qw.x - q[1], qw.y - q[2], qw.z - q[3]) or -1,
    -- tick pose (partFrameNow) against drawn pose, absolute: the gap rule 2 is about
    tickGapMine = TM.len(fm[1] - m[1], fm[2] - m[2], fm[3] - m[3]),
  }
  -- the RELATIVE vector is the same in both poses when each is read whole
  G.relTickVsDrawn = TM.len((fq[1] - fm[1]) - dx, (fq[2] - fm[2]) - dy, (fq[3] - fm[3]) - dz)
  local sl = steerLog and steerLog.d
  if sl then G.tickVsRender = TM.len(sl[1] - dx, sl[2] - dy, sl[3] - dz) end
  local function scr(x, y, z)
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    return { sx or -1, sy or -1, on == true }
  end
  G.sMine = scr(m[1], m[2], m[3])
  G.sTheirs = scr(q[1], q[2], q[3])
  G.sRayEnd = scr(m[1] + m[4] * l, m[2] + m[5] * l, m[3] + m[6] * l)
  if qw then G.sTheirsNode = scr(qw.x, qw.y, qw.z) end
  GEOM = G
end

-- While the prompt is up, our ports are numbered where they are.
local function draw_port_numbers(me, k)
  for _, p in ipairs(free_ports(me)) do
    local x, y, z, ax, ay, az = port_drawn(me, p.uid)   -- (drawn pose: a label)
    if x then
      local sx, sy, _, on = camera.worldToScreen(x + ax * 0.4, y + ay * 0.4, z + az * 0.4)
      if on and sx then tag(sx, sy, string.format("PORT %d", p.n), 13 * k, 1.0, 0.86, 0.62, 1.0) end
    end
  end
end

-- ── the save ────────────────────────────────────────────────────────────────
local function restore_try()
  local s = pending
  if not s then return end
  if s.kind == "body" then
    if space.body(s.name) then target = { kind = "body", name = s.name }; pending = nil end
    return
  end
  local fo = ref("flight_ops")
  local v = fo and fo.liveOf and s.fid and fo.liveOf(s.fid) or nil
  if v and v.node and v.node.valid then
    if s.kind == "part" then
      if v.partRec and v.partRec(s.uid) then
        target = { kind = "part", id = v.node.id, fid = s.fid, uid = s.uid, port = s.port, craft = s.craft, name = s.name }
      end
    else
      target = { kind = "craft", id = v.node.id, fid = s.fid, name = s.name }
    end
    pending = nil
    log_("restored the target " .. tostring(s.name))
    sync_lock()
  elseif (time or 0) - (pend_t0 or 0) > 180 then
    pending = nil   -- (kept in the save: a later session may find it)
  end
end

local loaded = false
local port_pending = nil
local function load_saved()
  loaded = true
  if not (save and save.get) then return end
  local s = save.get(SAVE_SEL)
  if type(s) == "table" and s.kind then pending, pend_t0 = s, time or 0 end
  local p = save.get(SAVE_PORT)
  if type(p) == "table" and p.uid then port_pending = p end
end
local function port_restore()
  local p = port_pending
  if not p then return end
  local me = piloted()
  if not me then return end
  local f = fid_of(me)
  if f and p.fid == f and port_rec(me, p.uid) then
    ctrlPort = { id = me.node.id, uid = p.uid }
    port_pending = nil
  elseif f and p.fid ~= f then
    port_pending = nil
  end
end

-- ── driver ──────────────────────────────────────────────────────────────────
local last_mode, prompted = nil, false
local chk_t = -10

function start(node)
  try_register()
end

function update(node, dt)
  if (params and params.enabled or 1) < 0.5 then return end
  try_register()
  if not loaded then load_saved() end
  if pending and (time or 0) - chk_t > 0.5 then chk_t = time or 0; restore_try() end
  if port_pending then port_restore() end
  -- a craft target that left the scene (docked into us, recovered, broken)
  local t = target
  if t and (t.kind == "craft" or t.kind == "part") then
    local v = vessel_by_id(t.id)
    if lost(v) or (t.kind == "part" and not (v.partRec and v.partRec(t.uid))) then
      -- the node changed (a re-spawn keeps the fleet id): look it up again
      local fo = ref("flight_ops")
      local nv = t.fid and fo and fo.liveOf and fo.liveOf(t.fid) or nil
      if nv and nv.node and nv.node.valid and not lost(nv) and (t.kind == "craft" or (nv.partRec and nv.partRec(t.uid))) then
        t.id = nv.node.id
      else
        target = nil
        store()
        say("target lost: " .. tostring(t.name))
      end
    end
  end
  local me = piloted()
  if me then sync_lock() end
  -- THE PORT PROMPT: SAS Target just engaged on a port, several of ours free
  -- and none picked.
  local mode = me and me.sas_mode or nil
  if mode ~= last_mode then
    if mode == "target" then prompted = false end
    last_mode = mode
  end
  if me and mode == "target" and not prompted and target and target.port then
    local uid, n = myPort(me)
    if not uid and n > 1 then
      prompted = true
      local cm = ref("context_menu")
      if cm and cm.openFor and cm.actorNow then
        local who = cm.actorNow()
        if who then cm.openFor({ kind = "dockchoice", label = "Dock with which port?" }, who) end
      end
    end
  end
  -- the map's right-click
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() and input then
    local tap = map_tap()
    if tap then
      local pick = mapPick(tap.x, tap.y)
      if pick then openMapMenu(pick, tap.x, tap.y) end
    end
  else
    rmb = nil
  end
end

readout_s = nil   -- the smoothed readout carried between frames (relative values only)
function lateUpdate(node, dt)
  if (params and params.enabled or 1) < 0.5 then return end
  if not (camera and camera.worldToScreen and camera.screenRect and draw and draw.text) then return end
  readout = nil
  if not target or blocked() then return end
  local me = piloted()
  local T = resolve()
  if not T then return end
  if me and T.v and T.v.node.id == me.node.id then return end
  local key = string.format("%s|%s|%s|%s", tostring(target.kind), tostring(target.id or target.name),
    tostring(target.uid), tostring(me and myPort(me) or ""))
  local R = TM.smooth(readout_s, measure(me), dt, 12, key)
  readout_s = R
  readout = R
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / uiH()
  draw_marker(T, R, vx, vy, vw, vh, k)
  if me and R and R.myPort then
    draw_guides(me, R)
    draw_indicator(me, R, vx, vy, vw, vh, k)
    if DEBUG_GEOM then geom_check(me, R) end
  end
  local cm = ref("context_menu")
  if me and cm and cm.open and cm.target and cm.target.kind == "dockchoice" then draw_port_numbers(me, k) end
end
