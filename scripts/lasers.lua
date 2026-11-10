-- LASERS — the scene half of a laser built from kit pieces on a base grid
-- (expansion X9, "Energy weapons I"; work/expansion/PLAN.md §4.1;
-- docs/base-building.md §27). The physics is beam.lua's, what it does
-- damage.lua's (both pure). The craft turret (laser_turret.lua) borrows the
-- hit, the beam drawing and the menus' readout from here.
--
-- On the Build Kit node (scenes/system.ron) beside refinery and logic_net.
--
--   THE LAYOUT  each structure's DEFENCE pieces are read when the records
--               change (structures.version): beam.layout joins banks and bus
--               bars into pulse groups and walks each emitter's beam through
--               stages and lenses to its Beam Director (a WEAPON); the
--               emitters' and stages' heat ports go through machines.coolLoops
--               with the S6 sinks on them (Radiator Panels, Jacket Radiators,
--               pipes); a Targeting Radar on the same grid stretches its lock.
--   CHARGING    an ARMED weapon's banks charge at 50 kW each from the base
--               grid (an aux load on base_grid while not full; partServed
--               says whether the grid carries it). Every `every` s on the
--               agency clock: the same step catches up after a reload or a
--               long warp (linear to full, then held; 0.1 %/h leak).
--   AIMING      in fixedUpdate (tick poses, docs/positions-and-frames.md rule
--               2): the target is the TARGETING selection (targeting.resolve:
--               a craft, a part, a spot on a world); the director's yaw and
--               elevation (in its own frame, never a world point) slew toward
--               it at 10°/s. Idle (nothing armed) it costs a flag test.
--   FIRING      a pulse (the console's FIRE, a logic `fire` edge, laser.fire)
--               is queued and cast in the next fixedUpdate from the
--               director's tick pose along where it POINTS (a director that
--               lags misses): one raycast. CW (30 kW optical, 90 kW from the
--               grid) is one raycast every 0.1 s while it burns.
--   DAMAGE      a craft part: vessel_controller.hitPart by damage.partAmount;
--               a kit piece: its hp in the part state (`hp`, none = 1.0) by
--               damage.pieceAmount, removed at 0 with chunks and a burst;
--               the ground: the energy waits on the spot until it makes a
--               ≥ 1 m pit (the ground takes no smaller dig) (damage.crater), then terrain.dig. The
--               cinematic regime (beam.regime, 0 for normal builds) adds a
--               blast (pieces and parts within its radius) and explosive
--               cratering, continuously.
--   THE BEAM    lateUpdate, drawn poses: from the director's muzzle (its
--               record against this pass's space.body) to the hit (held
--               body-relative, or in the struck part's frame), 0.15 s for a
--               pulse, steady for CW; the head's yoke and mirror turned to the
--               aim. A pool of four FxWeaponBeam nodes.
--
-- SAVE: lz.e = { ["sid:uid"] = J } the banks' charge; lz.a = the agency clock
-- it was stepped to; a director's `arm` and a lens's `focus` in their part
-- states; a piece's `hp` in its part state. An old save has none: no change.
--
-- Probes: weapons(), weaponOf(sid, uid), fire(sid, uid), setArm, setCw,
-- charge(sid, uid) / setCharge, lastShot, shots, readout(sid, uid), PROF.

defaults = {
  --@range 0.1 5 --@units s
  every = 0.5,
}

PROF = { scan_ms = 0, fix_ms = 0, fire_ms = 0, ray_ms = 0, draw_ms = 0, late_ms = 0, shots = 0, rays = 0, hits = {}, removed = 0 }
CATCH_MAX = 30 * 86400
LEAK = 0.001 / 3600          -- the banks' self-discharge, a share a second
CW_TICK = 0.1                -- s between a CW beam's rays
PULSE_SHOW = 0.15            -- s a pulse's beam is drawn
RAY_MAX = 20000              -- m: the longest cast
OPTICAL = 5000               -- m: the lock without a Targeting Radar
CHUNKS = 8                   -- debris chunks a felled piece throws (≤ 12, PLAN)
CHUNK_LIFE = 25              -- s
DIG_MAX = 12                 -- m: the largest single dig (a cinematic shot at X11 scale)

local unpack = unpack or table.unpack
local function log10(x) return math.log(x) / math.log(10) end
local update_t = -10
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function keyOf(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
local function say(s, secs) if caption then pcall(caption, s, secs or 5) end if log then log("lasers: " .. s) end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function fmtE(j)
  j = j or 0
  if j >= 1e9 then return string.format("%.2f GJ", j / 1e9) end
  if j >= 1e6 then return string.format("%.1f MJ", j / 1e6) end
  return string.format("%.0f kJ", j / 1e3)
end
local function fmtR(m)
  if m >= 1e6 then return string.format("%.0f km", m / 1e3) end
  if m >= 1e4 then return string.format("%.1f km", m / 1e3) end
  return string.format("%.0f m", m)
end
fmtEnergy, fmtRange = fmtE, fmtR

local function part_state(sid, uid) local ST = ref("structures"); return ST and ST.partState and ST.partState(sid, uid) or nil end
local function set_part_state(sid, uid, k, v)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return end
  local t = {}
  for a, b in pairs(ST.partState(sid, uid) or {}) do t[a] = b end
  t[k] = v
  ST.setPartState(sid, uid, next(t) and t or nil)
end

-- ── state ───────────────────────────────────────────────────────────────────
W = {}               -- director key → weapon
local LIST = {}      -- weapons in order
local BANK = {}      -- bank key → { sid, uid, cap, kw, w (the weapon it charges for) }
local EMIT = {}      -- emitter key → weapon
local BYSID = {}     -- sid → { weapons }
E = {}               -- bank key → J
local ver = { st = nil }
local scan_t = -10
local A = nil         -- the agency clock the banks were stepped to
local dirtyE, saveE_t = false, -10
local armedN = 0      -- weapons armed (fixedUpdate's flag)
local queue = {}      -- pulses asked for, cast in the next fixedUpdate
local HPM = {}        -- "sid:uid" → { hp, w }: CW wear not yet written (see hp_now)
local hp_flush        -- (defined with the hits)
local beams = {}      -- { key, t1, from = fn → x,y,z, to = { … }, power }
lastShot = nil
shots = {}            -- the last 32 shots, for probes and the menu

-- ── the layout ──────────────────────────────────────────────────────────────
local function rot(yaw, x, z) local c, s = math.cos(yaw or 0), math.sin(yaw or 0); return x * c + z * s, -x * s + z * c end
local function ports_of(p, d)
  local out = {}
  for _, pt in ipairs(d.ports or {}) do
    if pt.pulse or pt.beam then
      local dx, dz = rot(p.yaw, pt.x, pt.z)
      local nx, nz = rot(p.yaw, pt.nx or 0, pt.nz or 0)
      out[#out + 1] = { x = (p.x or 0) + dx, y = (p.y or 0) + (pt.y or 0.6), z = (p.z or 0) + dz, nx = nx, nz = nz, pulse = pt.pulse, beam = pt.beam }
    end
  end
  return out
end

-- the cooling of the hot laser pieces in a structure: machines.coolLoops over
-- their heat ports and the S6 sinks on them (refinery.lua's way)
local function cool_of(rec)
  local MC = ref("machines")
  if not MC then return {} end
  local env = { air = false, tamb = 288 }
  local M = ref("materials")
  local tr = M and M.bodyTraits and M.bodyTraits(rec.b)
  if tr then env.air = not tr.airless; if tr.temp then env.tamb = 200 + 150 * tr.temp end end
  local pieces = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.ports and math.abs(p.pitch or 0) < 1e-3 then
      local hot = d.lz and (d.lz.heat or 0) > 0
      if hot or d.reject or d.pipe then
        local ports = {}
        for _, pt in ipairs(d.ports) do
          if not pt.fluid and not pt.bore and (not hot or pt.heat) then
            local dx, dz = rot(p.yaw, pt.x, pt.z)
            local nx, nz = rot(p.yaw, pt.nx or 0, pt.nz or 0)
            ports[#ports + 1] = { x = (p.x or 0) + dx, y = (p.y or 0) + (pt.y or 0.6), z = (p.z or 0) + dz, nx = nx, nz = nz }
          end
        end
        pieces[#pieces + 1] = { key = keyOf(rec.id, p.uid), ports = ports, heat = hot and d.lz.heat or nil,
                                sink = d.reject and MC.rejectKW(d.reject, env) or nil }
      end
    end
  end
  return MC.coolLoops(pieces)
end

local function load_E()
  local t = save and save.get and save.get("lz.e")
  E = {}
  if type(t) == "table" then for k, v in pairs(t) do E[k] = tonumber(v) or 0 end end
  A = tonumber(save and save.get and save.get("lz.a")) or nil
end
local function save_E(force)
  if not (save and save.set) then return end
  if not (dirtyE or force) then
    if next(HPM) and now() - saveE_t >= 10 then saveE_t = now(); hp_flush() end
    return
  end
  if not force and now() - saveE_t < 10 then return end
  local t, any = {}, false
  for k, v in pairs(E) do if BANK[k] and v > 1 then t[k] = math.floor(v); any = true end end
  save.set("lz.e", any and t or false)
  if A then save.set("lz.a", A) end
  dirtyE, saveE_t = false, now()
  hp_flush()
end

function scan()
  local ST, BEAM = ref("structures"), ref("beam")
  if not (ST and BEAM and ST.list) then return end
  local w0 = wall()
  local old = W
  W, LIST, BANK, EMIT, BYSID = {}, {}, {}, {}, {}
  local BG = ref("base_grid")
  local radarGrids, radarSids = {}, {}
  local recs = {}
  for _, rec in ipairs(ST.list()) do
    local pieces, has = {}, false
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      if d and d.lz and math.abs(p.pitch or 0) < 1e-3 then
        has = true
        local L = d.lz
        if L.kind == "radar" then
          radarSids[rec.id] = true
          local g = BG and BG.gridOfStruct and BG.gridOfStruct(rec.id)
          if g then radarGrids[g.id] = true end
        end
        pieces[#pieces + 1] = { key = keyOf(rec.id, p.uid), kind = L.kind, ports = ports_of(p, d), part = p, def = d }
      end
    end
    if has then recs[#recs + 1] = { rec = rec, pieces = pieces } end
  end
  for _, R in ipairs(recs) do
    local rec = R.rec
    local weapons, groups, members, byKey = BEAM.layout(R.pieces)
    local cool = nil
    local consoles = {}
    for _, p in ipairs(R.pieces) do if p.kind == "console" then consoles[#consoles + 1] = p.part.uid end end
    BYSID[rec.id] = {}
    for _, L in ipairs(weapons) do
      if L.director then
        cool = cool or cool_of(rec)
        local dp = byKey[L.director]
        local key = L.director
        -- (the same table across rescans: its aim, cooldown and CW carry on, and
        -- whoever holds it — a beam being drawn, a probe — sees it live)
        local wpn = old[key] or { yaw = 0, el = 0, cw = false, cd = -1e9, cwT = 0, onT = false }
        wpn.key, wpn.sid, wpn.uid, wpn.rec, wpn.b, wpn.part, wpn.def = key, rec.id, dp.part.uid, rec, rec.b, dp.part, dp.def
        wpn.L, wpn.why, wpn.emitter, wpn.stages, wpn.lenses, wpn.consoles = dp.def.lz, L.why, L.emitter, L.stages, L.lenses, consoles
        local st = part_state(rec.id, dp.part.uid) or {}
        wpn.armed = st.arm == true
        -- the banks each device dumps, and its share of them
        local function feed(dev)
          local g = groups[dev]
          local m = g and members[g]
          if not m then return { banks = {}, n = 1 } end
          return { banks = m.banks, n = math.max(1, #m.devs) }
        end
        wpn.feedE = feed(L.emitter)
        wpn.feedS = {}
        for i, s in ipairs(L.stages) do wpn.feedS[i] = feed(s) end
        -- the lens: its reach, or the range it holds
        wpn.reach = dp.def.lz.reach or 5000
        wpn.focusFixed = nil
        for _, lk in ipairs(L.lenses) do
          local lp = byKey[lk]
          wpn.reach = math.max(wpn.reach, lp.def.lz.reach or 0)
          local ls = part_state(rec.id, lp.part.uid) or {}
          if tonumber(ls.focus) then wpn.focusFixed = tonumber(ls.focus); wpn.lensUid = lp.part.uid end
          wpn.lensUid = wpn.lensUid or lp.part.uid
        end
        -- cooling: the worst of the emitter and its stages
        local c = 1
        for _, dk in ipairs({ L.emitter, unpack(L.stages) }) do
          local cl = cool and cool[dk]
          local mc = ref("machines")
          c = math.min(c, cl and cl.cool or (mc and mc.PASSIVE or 0.2))
        end
        wpn.cool = c
        local ed = byKey[L.emitter]
        wpn.emitterUid = ed and ed.part.uid
        wpn.emitL = ed and ed.def.lz or {}
        -- the radar: on this structure, or on its grid
        local g = BG and BG.gridOfStruct and BG.gridOfStruct(rec.id)
        wpn.radar = radarSids[rec.id] or (g and radarGrids[g.id]) or false
        wpn.lock = wpn.radar and 5.0e5 or OPTICAL
        W[key] = wpn
        LIST[#LIST + 1] = wpn
        BYSID[rec.id][#BYSID[rec.id] + 1] = wpn
        for _, f in ipairs({ wpn.feedE, unpack(wpn.feedS) }) do
          for _, bk in ipairs(f.banks) do
            local bp = byKey[bk]
            BANK[bk] = BANK[bk] or { sid = rec.id, uid = bp.part.uid, cap = bp.def.lz.cap or 20e6, kw = bp.def.lz.kw or 50, w = wpn }
            E[bk] = E[bk] or 0
          end
        end
        if L.emitter then EMIT[L.emitter] = wpn end
      else
        -- an emitter whose beam reaches no director: remembered for the menus
        BYSID[rec.id].broken = BYSID[rec.id].broken or {}
        BYSID[rec.id].broken[#BYSID[rec.id].broken + 1] = L
      end
    end
  end
  armedN = 0
  for _, w in ipairs(LIST) do if w.armed then armedN = armedN + 1 end end
  ver.st = ST.version
  scan_t = now()
  if w0 then PROF.scan_ms = (wall() - w0) * 1000 end
end

function weapons() return LIST end
function weaponOf(sid, uid)
  local w = W[keyOf(sid, uid)]
  if w then return w end
  local list = BYSID[sid]
  return list and list[1] or nil
end

-- ── charging ────────────────────────────────────────────────────────────────
local function charging(bk)
  local b = BANK[bk]
  return b and b.w.armed and (E[bk] or 0) < b.cap - 1
end
function gridAux(sid, uid)
  local k = keyOf(sid, uid)
  local b = BANK[k]
  if b then return charging(k) and b.kw or 0 end
  local w = EMIT[k]
  if w and w.armed and w.cw then return w.emitL.kw or 90 end
  return 0
end
local function charged_set()
  local s = {}
  for k in pairs(BANK) do if charging(k) then s[#s + 1] = k end end
  table.sort(s)
  return table.concat(s, ",")
end
local last_set = ""
local function step_banks()
  local a = agency_now()
  if not A then A = a end
  local dt = math.max(0, math.min(CATCH_MAX, a - A))
  if dt <= 0 then return end
  local BG = ref("base_grid")
  -- (just after a load the grid may not be built yet: wait for it, so the
  -- catch-up is not lost)
  for k in pairs(BANK) do
    if charging(k) and BG and BG.partServed and BG.partServed(BANK[k].sid, BANK[k].uid) == nil and now() < 20 then return end
  end
  for k, b in pairs(BANK) do
    local e = E[k] or 0
    if charging(k) and BG and BG.partServed and BG.partServed(b.sid, b.uid) == true then
      e = math.min(b.cap, e + b.kw * 1000 * dt)
    end
    e = e * math.exp(-LEAK * dt)
    if e ~= E[k] then E[k] = e; dirtyE = true end
  end
  A = a
  local s = charged_set()
  if s ~= last_set then
    last_set = s
    if BG and BG.markDirty then BG.markDirty() end
  end
end

-- the charge a weapon would fire now, and what each device takes
local function feed_J(f)
  local s = 0
  for _, bk in ipairs(f.banks) do s = s + (E[bk] or 0) end
  return s / f.n
end
function pulseOf(w)
  local BEAM = ref("beam")
  if not (w and BEAM) then return 0, 0, 0 end
  local chain = { emitter = feed_J(w.feedE), stages = {} }
  for i, f in ipairs(w.feedS) do chain.stages[i] = feed_J(f) end
  return BEAM.pulseEnergy(chain)
end
function capOf(w)
  local c, e = 0, 0
  local seen = {}
  for _, f in ipairs({ w.feedE, unpack(w.feedS) }) do
    for _, bk in ipairs(f.banks) do
      if not seen[bk] then seen[bk] = true; c = c + (BANK[bk] and BANK[bk].cap or 0); e = e + (E[bk] or 0) end
    end
  end
  return e, c
end
local function drain(w)
  for _, f in ipairs({ w.feedE, unpack(w.feedS) }) do
    for _, bk in ipairs(f.banks) do
      local e = E[bk] or 0
      E[bk] = e - e / f.n * 1
      if E[bk] < 1 then E[bk] = 0 end
    end
  end
  dirtyE = true
  save_E(true)
end

-- ── geometry (body frame; a world point only within one pass) ────────────────
-- the director's pivot (body-relative) and its axes U, F, R (body frame)
local function director_frame(w)
  local ST = ref("structures")
  local x, y, z, U, F = ST.partPose(w.rec, w.part, 0)
  local Rx, Ry, Rz = U.y * F.z - U.z * F.y, U.z * F.x - U.x * F.z, U.x * F.y - U.y * F.x
  local h = w.L.pivot or 1.75
  return x + U.x * h, y + U.y * h, z + U.z * h, U, F, { x = Rx, y = Ry, z = Rz }
end
local function aim_dir(w, U, F, R)
  local cy, sy, ce, se = math.cos(w.yaw), math.sin(w.yaw), math.cos(w.el), math.sin(w.el)
  return R.x * sy * ce + U.x * se + F.x * cy * ce, R.y * sy * ce + U.y * se + F.y * cy * ce, R.z * sy * ce + U.z * se + F.z * cy * ce
end
-- the muzzle and the beam's direction in the world, from this pass's read of the body
function muzzleOf(w)
  local b = space and space.body and space.body(w.b)
  if not b then return nil end
  local px, py, pz, U, F, R = director_frame(w)
  local dx, dy, dz = aim_dir(w, U, F, R)
  local m = w.L.muzzle or 0.55
  return b.x + px + dx * m, b.y + py + dy * m, b.z + pz + dz * m, dx, dy, dz
end

local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function slew(w, dt)
  local TG = ref("targeting")
  local T = TG and TG.resolve and TG.resolve()
  w.tgt = nil
  if not T then w.onT = false; w.err = nil; w.range = nil; return end
  local b = space.body(w.b)
  if not b then return end
  local px, py, pz, U, F, R = director_frame(w)
  local tx, ty, tz = T.x - b.x - px, T.y - b.y - py, T.z - b.z - pz
  local r = len(tx, ty, tz)
  w.range = r
  -- (a new target: not on it until the director has slewed there)
  local tk = tostring(T.name) .. "|" .. tostring(T.v and T.v.node and T.v.node.id or "")
  if tk ~= w.tkey then w.tkey = tk; w.onT = false end
  w.tgtName = T.name
  if r < 1 then w.onT = false; return end
  -- in range of its lock, and not behind a world (one bodies read)
  local BEAM = ref("beam")
  local occ = w.occ
  if r > 200 and BEAM and space.bodies then
    -- (four times a second: one bodies read, every sphere)
    if now() - (w.occT or -10) > 0.25 then
      w.occT = now()
      occ = BEAM.occluded(b.x + px, b.y + py, b.z + pz, T.x, T.y, T.z, space.bodies(), nil, 2)
    end
  else occ = nil end
  w.occ = occ
  if r > w.lock or occ then w.onT = false; w.err = nil; return end
  w.tgt = T
  local lx, ly, lz = tx * R.x + ty * R.y + tz * R.z, tx * U.x + ty * U.y + tz * U.z, tx * F.x + ty * F.y + tz * F.z
  local wy = math.atan2(lx, lz)
  local we = math.atan2(ly, math.sqrt(lx * lx + lz * lz))
  we = math.max(math.rad(-10), math.min(math.rad(88), we))
  local step = math.rad(w.L.slew or 10) * dt
  local dy = wrap(wy - w.yaw)
  w.yaw = wrap(w.yaw + math.max(-step, math.min(step, dy)))
  local de = we - w.el
  w.el = w.el + math.max(-step, math.min(step, de))
  -- the miss at the target, on its own scale
  local dx, dyy, dz = aim_dir(w, U, F, R)
  local c = (dx * tx + dyy * ty + dz * tz) / r
  local err = math.acos(math.max(-1, math.min(1, c)))
  w.err = err
  local miss = err * r
  -- (hysteresis: on at 0.3 m, off at 0.6 m)
  if w.onT then w.onT = miss < 0.6 else w.onT = miss < 0.3 end
end

-- ── what a ray met ──────────────────────────────────────────────────────────
local function vessel_of(n)
  local roots = {}
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid ~= false then roots[v.node.id] = v end
  end
  for _ = 1, 8 do
    if not n or n.valid == false then return nil end
    local v = roots[n.id]
    if v then return v, n end
    n = n.parent
  end
  return nil
end
local function is_ground(n)
  if not (n and n.valid ~= false) then return true end
  local nm = n.name
  return nm ~= nil and space ~= nil and space.body ~= nil and space.body(nm) ~= nil
end
-- → hit = { kind = "part"|"piece"|"ground"|"thing"|"sky", x,y,z, nx,ny,nz, d, v, uid, rec, part }
function classify(h, ox, oy, oz, dx, dy, dz, rmax)
  if not h then return { kind = "sky", x = ox + dx * rmax, y = oy + dy * rmax, z = oz + dz * rmax, d = rmax, nx = -dx, ny = -dy, nz = -dz } end
  local o = { x = h.x, y = h.y, z = h.z, nx = h.nx or -dx, ny = h.ny or -dy, nz = h.nz or -dz, d = h.distance or len(h.x - ox, h.y - oy, h.z - oz), node = h.node }
  local v, root = vessel_of(h.node)
  if v then
    local uid = v.uidOfNode and h.node ~= root and v.uidOfNode(h.node) or nil
    if not uid and v.node and v.node.toLocal and v.aboardRecs then
      local l = v.node:toLocal(vec3(h.x, h.y, h.z))
      local best, bd = nil, 1e18
      for u, d in pairs(v.aboardRecs() or {}) do
        local dd = ((d.x or 0) - l.x) ^ 2 + ((d.y or 0) - l.y) ^ 2 + ((d.z or 0) - l.z) ^ 2
        if dd < bd then best, bd = u, dd end
      end
      uid = best
    end
    if uid then o.kind, o.v, o.uid = "part", v, uid; return o end
  end
  local ST = ref("structures")
  local rec, part = nil, nil
  if ST and ST.partOfNode then rec, part = ST.partOfNode(h.node) end
  if rec and part then o.kind, o.rec, o.part = "piece", rec, part; return o end
  o.kind = is_ground(h.node) and "ground" or "thing"
  return o
end

-- ── effects ─────────────────────────────────────────────────────────────────
local marks = {}
local function mark(tex, x, y, z, nx, ny, nz, size, alpha)
  if not (decals and decals.add) then return end
  local ok, id = pcall(decals.add, { texture = tex, pos = vec3(x, y, z), normal = vec3(nx, ny, nz), size = size,
                                      rotation = math.random() * 6.283, alpha = alpha })
  if ok and id then
    marks[#marks + 1] = { id = id, t = now() }
    while #marks > 48 do pcall(decals.remove, marks[1].id); table.remove(marks, 1) end
  end
end
local function play(path, x, y, z, vol, pitch, maxd)
  if not (audio and audio.play) then return end
  pcall(audio.play, path, x, y, z, { track = "SFX", volume = vol or 1, pitch = pitch or 1, mode = "Spatial", falloff = "Inverse",
                                     minDistance = 8, maxDistance = maxd or 1500 })
end
local function fx_hit(x, y, z, nx, ny, nz, E, kind, cw)
  local fx = ref("vfx")
  local k = math.min(1.6, 0.3 + 0.25 * math.log(1 + (E or 0) / 1e5))
  if fx and fx.emit then
    fx.emit(kind == "ground" and "LaserChips" or "ImpactSparks", x + nx * 0.08, y + ny * 0.08, z + nz * 0.08,
            { normal = vec3(nx, ny, nz), intensity = k, dust = kind == "ground" })
  end
  if fx and fx.flash and not cw then fx.flash(x + nx * 0.4, y + ny * 0.4, z + nz * 0.4, 1.0, 0.85, 0.7, 6 + 10 * k, 10 + 14 * k, 0.25) end
  if not cw and (E or 0) >= 1e6 and fx and fx.emit then
    fx.emit("ExplosionSmall", x + nx * 0.3, y + ny * 0.3, z + nz * 0.3, { intensity = math.min(1.5, 0.4 + 0.15 * log10((E or 1) / 1e6 + 1) * 3) })
  end
end

-- debris chunks off a felled piece (plain bodies, gone after CHUNK_LIFE)
local chunks = {}
local function throw_chunks(x, y, z, nx, ny, nz, n, col)
  if not spawn then return end
  for i = 1, math.min(12, n or CHUNKS) do
    local ox, oy, oz = (math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2 + 0.4, (math.random() - 0.5) * 1.2
    pcall(spawn, "Debris", vec3(x + ox, y + oy, z + oz), function(c)
      if not c then return end
      pcall(function()
        local s = 0.35 + math.random() * 0.5
        c.scale = s
        local kick = 3 + math.random() * 5
        c.vx, c.vy, c.vz = (nx + ox) * kick, (ny + oy + 0.6) * kick, (nz + oz) * kick
        if col and c.setPrimitive then c:setPrimitive("Cube", col) end
      end)
      chunks[#chunks + 1] = { n = c, t = now() }
    end)
  end
end
-- the chunks still flying (a beam passes through them: they are only the look)
function chunkNodes(extra)
  local out = {}
  if extra then out[#out + 1] = extra end
  for _, c in ipairs(chunks) do if c.n and c.n.valid ~= false then out[#out + 1] = c.n end end
  return out
end
local function chunks_tick()
  while chunks[1] and now() - chunks[1].t > CHUNK_LIFE do
    local c = table.remove(chunks, 1)
    if c.n and c.n.valid ~= false then pcall(function() c.n:destroy() end) end
  end
end

-- ground energy waiting on a spot: { body, x,y,z (body-relative), e }
local pits = {}
local MAT_COL = { steel = { 0.55, 0.56, 0.55 }, concrete = { 0.62, 0.6, 0.56 }, regocrete = { 0.6, 0.48, 0.38 }, glass = { 0.7, 0.8, 0.82 } }

-- ── applying a hit ──────────────────────────────────────────────────────────
-- E = J that arrives (after the air), d = the spot, F = its fluence, c = the
-- regime. → a record of what it did.
-- a piece's hp: the part state's, or the wear a CW beam has put on it since it was last written
-- (written in 2 % steps and on every pulse: a part-state write bumps structures.version, which
-- re-reads every grid and layout, so ten writes a second would cost more than the beam)
local function hp_now(sid, uid)
  local m = HPM[keyOf(sid, uid)]
  if m then return m.hp end
  local st = part_state(sid, uid) or {}
  return tonumber(st.hp) or 1.0
end
hpOf = hp_now
local function hp_write(sid, uid, hp, force)
  local k = keyOf(sid, uid)
  local m = HPM[k] or { w = hp_now(sid, uid) }
  HPM[k] = m
  m.hp = hp
  if force or math.abs((m.w or 1) - hp) >= 0.02 then
    set_part_state(sid, uid, "hp", math.floor(hp * 1e6 + 0.5) / 1e6)
    m.w = hp
    HPM[k] = nil
  end
end
hp_flush = function()
  for k, m in pairs(HPM) do
    local sid, uid = k:match("^(.-):(.+)$")
    sid, uid = tonumber(sid) or sid, tonumber(uid) or uid
    local ST = ref("structures")
    if ST and ST.getPart and ST.getPart(sid, uid) then set_part_state(sid, uid, "hp", math.floor(m.hp * 1e6 + 0.5) / 1e6) end
    HPM[k] = nil
  end
end
local function apply_piece(rec, part, F, Eon, x, y, z, nx, ny, nz, amount_over, cw)
  local DM = ref("damage")
  local d = defs(part.id) or {}
  local mat = d.mat or DM.matOf(part.id) or "steel"
  local b = d.box or { -1, 1, 0, 2, -0.1, 0.1 }
  local L = math.max(b[2] - b[1], b[4] - b[3], b[6] - b[5])
  local amount = amount_over or DM.pieceAmount(F, Eon, mat, d.mass or 0.1, L)
  local hp0 = hp_now(rec.id, part.uid)
  local hp = DM.hpAfter(hp0, amount)
  local r = { kind = "piece", sid = rec.id, uid = part.uid, id = part.id, label = d.label, mat = mat, amount = amount, hp0 = hp0, hp = hp,
              cut = DM.pieceCut(mat, d.mass or 0.1, L) }
  if amount <= 0 then return r end
  if hp <= 1e-6 then
    HPM[keyOf(rec.id, part.uid)] = nil
    local ST = ref("structures")
    ST.removeParts(rec.id, { part.uid })
    PROF.removed = PROF.removed + 1
    r.removed = true
    throw_chunks(x, y, z, nx, ny, nz, math.max(3, math.min(CHUNKS, math.floor((d.mass or 0.2) * 6))), MAT_COL[mat])
    local fx = ref("vfx")
    if fx and fx.explode then fx.explode(x, y, z, 0, 0, 0, false) end
    play("audio/foley/pyro_bang.ogg", x, y, z, 0.9, 0.8, 900)
  else
    hp_write(rec.id, part.uid, hp, not cw)
  end
  return r
end
local function apply_part(v, uid, F, Eon, x, y, z, amount_over)
  local DM = ref("damage")
  local d = v.partRec and v.partRec(uid) or (v.aboardRecs and v.aboardRecs()[uid]) or {}
  local cls = DM.partClass(d)
  local amount = amount_over or DM.partAmount(F, Eon, cls)
  local hp0 = v.partHp and v.partHp(uid)
  local hp = nil
  if hp0 and amount > 0 and v.hitPart then
    local ok, h = pcall(v.hitPart, uid, amount, x, y, z)
    hp = ok and h or nil
  end
  return { kind = "part", craft = v.craftName, uid = uid, label = d.label, cls = cls, amount = amount, hp0 = hp0, hp = hp }
end
local function apply_ground(body, x, y, z, nx, ny, nz, Eabs, c)
  local DM = ref("damage")
  local b = space.body(body)
  if not b then return { kind = "ground" } end
  local bx, by, bz = x - b.x, y - b.y, z - b.z
  local P = nil
  for _, p in ipairs(pits) do
    if p.body == body and math.abs(p.x - bx) + math.abs(p.y - by) + math.abs(p.z - bz) < 1.0 then P = p end
  end
  if not P then
    P = { body = body, x = bx, y = by, z = bz, e = 0 }
    pits[#pits + 1] = P
    if #pits > 32 then table.remove(pits, 1) end
  end
  P.e = P.e + Eabs
  local r = math.min(DIG_MAX, DM.crater(P.e, c))
  local out = { kind = "ground", e = P.e, r = r }
  if r >= DM.CRATER_MIN and terrain and terrain.dig then
    local bf = ref("base_facilities")
    local cx, cy, cz = x - nx * r * 0.3, y - ny * r * 0.3, z - nz * r * 0.3
    if bf and bf.digRefused and bf.digRefused(cx, cy, cz, r) then
      out.refused = true
    else
      local ff = ref("flora_field")
      if ff and ff.liftWash then pcall(ff.liftWash, x, y, z, 110.0, 8.0) end
      -- (a hard, whole ball: the soft default brush barely moves ~1 m voxels at this size)
      local okd, ed = pcall(terrain.dig, cx, cy, cz, r, 1.0, { hardness = 1.0, falloff = "linear" })
      if not okd and log then log("lasers: terrain.dig refused: " .. tostring(ed)) end
      out.cx, out.cy, out.cz = cx - b.x, cy - b.y, cz - b.z
      if ff and ff.groundChanged then pcall(ff.groundChanged, x, y, z, r) end
      out.dug = r
    end
    if terrain.paint then pcall(terrain.paint, x, y, z, r * 1.6, 0.08, 0.07, 0.06, 0.7) end
    P.e = 0
  end
  return out
end

-- the cinematic blast (c > 0): pieces and parts within r_b take blastAmount
local function apply_blast(body, x, y, z, Eabs, c, skipSid, skipUid)
  local DM = ref("damage")
  local Wt, rb = DM.blast(Eabs, c)
  if rb <= 0.5 then return nil end
  local out = { W = Wt, rb = rb, pieces = 0, parts = 0 }
  local b = space.body(body)
  local ST = ref("structures")
  local n = 0
  if b and ST and ST.partsNear then
    for _, e in ipairs(ST.partsNear(body, x - b.x, y - b.y, z - b.z, rb) or {}) do
      if n >= 40 then break end
      if not (e.rec.id == skipSid and e.part.uid == skipUid) then
        local a = DM.blastAmount(e.d or 0, rb)
        if a > 0 then
          apply_piece(e.rec, e.part, 0, 0, x, y, z, 0, 1, 0, a)
          n = n + 1; out.pieces = out.pieces + 1
        end
      end
    end
  end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if n >= 40 then break end
    if v.node and v.node.valid ~= false and v.aboardRecs and v.partPointNow then
      local w = v.node.worldPos
      if w and len(w.x - x, w.y - y, w.z - z) < rb + 30 then
        for u in pairs(v.aboardRecs()) do
          local px, py, pz = v.partPointNow(u, 0, 0, 0)
          if px then
            local a = DM.blastAmount(len(px - x, py - y, pz - z), rb)
            if a > 0 and n < 40 then apply_part(v, u, 0, 0, x, y, z, a); n = n + 1; out.parts = out.parts + 1 end
          end
        end
      end
    end
  end
  local fx = ref("vfx")
  if fx and fx.explode then
    fx.explode(x, y, z, 0, 0, 0, true)
    if rb > 8 then for k = 1, math.min(4, math.floor(rb / 8)) do fx.explode(x + (math.random() - 0.5) * rb * 0.5, y + (math.random() - 0.5) * rb * 0.5, z + (math.random() - 0.5) * rb * 0.5, 0, 0, 0, true) end end
  end
  play("audio/foley/pyro_far.ogg", x, y, z, 1.0, 0.7, 4000)
  return out
end

-- The shared hit: the beam (E J leaving the muzzle, spot at range from the
-- optics) has met `hit`. o = { D, theta, focus, stages, cw, body (the
-- director's world), tag, airRho }. → the shot record.
function applyHit(hit, E, o)
  local BEAM, DM = ref("beam"), ref("damage")
  local R = hit.d or 0
  local T = BEAM.airTransmission(R, o.airRho or 0, o.cw, o.cwKW)
  local Eon = E * T
  local d = BEAM.spotAt(R, o.D, o.theta, o.focus)
  local F = BEAM.fluence(Eon, d)
  local c = BEAM.regime(Eon, F, o.stages or 0, o.D)
  local rec = { t = now(), tag = o.tag, kind = hit.kind, R = R, E = E, T = T, Eon = Eon, d = d, F = F, c = c, cw = o.cw == true }
  local x, y, z, nx, ny, nz = hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz
  local area = 1.0
  if hit.kind == "part" then
    local pd = hit.v.partRec and hit.v.partRec(hit.uid) or {}
    area = math.max(0.05, 2 * (pd.rx or 0.5) * (pd.h or 1))
    rec.hit = apply_part(hit.v, hit.uid, F, Eon * DM.intercept(d, area), x, y, z)
    mark("textures/vfx/decal/scorch_b.png", x, y, z, nx, ny, nz, math.min(1.5, 0.25 + d), 0.9)
  elseif hit.kind == "piece" then
    local pdf = defs(hit.part.id) or {}
    local bb = pdf.box or { -1, 1, 0, 2, -0.1, 0.1 }
    local sx, sy, sz = bb[2] - bb[1], bb[4] - bb[3], bb[6] - bb[5]
    area = math.max(sx * sy, sy * sz, sx * sz)
    rec.hit = apply_piece(hit.rec, hit.part, F, Eon * DM.intercept(d, area), x, y, z, nx, ny, nz, nil, o.cw)
    if not rec.hit.removed then mark("textures/vfx/decal/scorch_b.png", x, y, z, nx, ny, nz, math.min(1.5, 0.3 + d), 0.9) end
  elseif hit.kind == "ground" then
    local body = space.dominant and space.dominant(x, y, z) or o.body
    rec.hit = apply_ground(body, x, y, z, nx, ny, nz, Eon, c)
    if not o.cw or (rec.hit.dug) then mark("textures/vfx/decal/scorch.png", x, y, z, nx, ny, nz, math.max(0.5, (rec.hit.r or 0.2) * 3), 0.85) end
  else
    rec.hit = { kind = hit.kind }
  end
  if c > 1e-4 and hit.kind ~= "sky" then
    local body = space.dominant and space.dominant(x, y, z) or o.body
    rec.blast = apply_blast(body, x, y, z, Eon, c, hit.rec and hit.rec.id, hit.part and hit.part.uid)
  end
  if hit.kind ~= "sky" then fx_hit(x, y, z, nx, ny, nz, Eon, hit.kind, o.cw) end
  rec.hitKind = hit.kind
  PROF.hits[hit.kind] = (PROF.hits[hit.kind] or 0) + 1
  return rec
end

-- the air along a path in the world (mean ρ), from the world record (aero.airAt)
function airAlong(body, ax, ay, az, bx, by, bz)
  local BEAM, AE = ref("beam"), ref("aero")
  local b = body and space.body(body)
  if not (BEAM and AE and b and AE.airAt) then return 0 end
  local w = save and save.get and save.get("world." .. body)
  if type(w) ~= "table" then return 0 end
  local R = b.radius or 600
  local g = (b.mu or 0) / (R * R)
  return BEAM.rhoAlong(ax, ay, az, bx, by, bz, b.x, b.y, b.z, R, function(alt) return (AE.airAt(w, alt, g, R)) end, 6)
end

-- ── the beam drawing ────────────────────────────────────────────────────────
local pool, pool_ask = {}, {}
local function pool_node(i)
  local n = pool[i]
  if n and n.valid ~= false then return n end
  if pool_ask[i] or not spawn then return nil end
  pool_ask[i] = true
  pcall(spawn, "FxWeaponBeam", vec3(0, 0, 0), function(m) pool[i] = m; pool_ask[i] = nil end)
  return nil
end
-- a beam to draw: from(): x,y,z (drawn, this pass); to = { body, bx,by,bz }
-- | { v, uid, lx,ly,lz } | { sky = true, dx,dy,dz, R }
function showBeam(key, from, to, secs, power)
  for _, bm in ipairs(beams) do
    if bm.key == key then bm.from, bm.to, bm.t1, bm.power = from, to, now() + secs, power; return end
  end
  if #beams >= 4 then table.remove(beams, 1) end
  beams[#beams + 1] = { key = key, from = from, to = to, t1 = now() + secs, power = power or 1 }
end
-- a hit → where the beam ends, kept in its own frame (never a world point)
function holdHit(hit)
  if hit.kind == "part" and hit.v and hit.v.partFrameNow then
    local Fr = hit.v.partFrameNow(hit.uid)
    if Fr then
      local qx, qy, qz = hit.x - Fr.ox, hit.y - Fr.oy, hit.z - Fr.oz
      return { v = hit.v, uid = hit.uid, lx = qx * Fr.rx + qy * Fr.ry + qz * Fr.rz, ly = qx * Fr.ux + qy * Fr.uy + qz * Fr.uz,
               lz = qx * Fr.zx + qy * Fr.zy + qz * Fr.zz }
    end
  end
  if hit.kind == "sky" then return { sky = true, R = hit.d } end
  local body = space.dominant and space.dominant(hit.x, hit.y, hit.z)
  local b = body and space.body(body)
  if not b then return nil end
  return { body = body, bx = hit.x - b.x, by = hit.y - b.y, bz = hit.z - b.z }
end
local function end_of(to, ox, oy, oz, dx, dy, dz)
  if not to then return nil end
  if to.sky then return ox + dx * to.R, oy + dy * to.R, oz + dz * to.R end
  if to.v then
    local v = to.v
    if not (v.node and v.node.valid ~= false) then return nil end
    -- (drawn: the part's own node, its frame as drawn this frame)
    local n = v.r2NodeOf and v.r2NodeOf(v.node, to.uid)
    if n and n.toWorld then
      local w = n:toWorld(vec3(to.lx, to.ly, to.lz))
      return w.x, w.y, w.z
    end
    return nil
  end
  local b = space.body(to.body)
  if not b then return nil end
  return b.x + to.bx, b.y + to.by, b.z + to.bz
end
local function draw_beams()
  local t = now()
  for i = #beams, 1, -1 do if t > beams[i].t1 then table.remove(beams, i) end end
  for i = 1, 4 do
    local bm = beams[i]
    local n = (bm or pool[i]) and pool_node(i) or nil
    local ps = n and n.particles and n:particles()
    if ps then
      if bm then
        local ox, oy, oz, dx, dy, dz = bm.from()
        local ex, ey, ez = nil, nil, nil
        if ox then ex, ey, ez = end_of(bm.to, ox, oy, oz, dx, dy, dz) end
        if ex then
          n.x, n.y, n.z = ox, oy, oz
          ps:setBeamEnd(ex, ey, ez)
          ps:setIntensity(math.min(2.0, 0.5 + 0.35 * (bm.power or 1)))
          if not ps:isPlaying() then ps:play() end
          bm.drawn = { ox, oy, oz, ex, ey, ez }
        elseif ps:isPlaying() then ps:stop() end
      elseif ps:isPlaying() then ps:stop() end
    end
  end
end
function beamsNow() return beams end

-- ── firing ──────────────────────────────────────────────────────────────────
local function why_not(w)
  if w.why then return w.why end
  if not w.armed then return "not armed (ARM it on the console or the director)" end
  if now() < (w.cd or -1e9) then return string.format("cooling: %.1f s", w.cd - now()) end
  local Ep = pulseOf(w)
  if Ep < 1000 then return "the banks are flat: arm it and let them charge" end
  return nil
end
whyNot = why_not
function ready(w) return w and why_not(w) == nil end

-- Ask for a pulse (cast in the next fixedUpdate). → ok, why
function fire(sid, uid)
  local w = weaponOf(sid, uid)
  if not w then return false, "no laser here" end
  local why = why_not(w)
  if why then return false, why end
  queue[#queue + 1] = w.key
  return true
end

local function cast(w, E, cw)
  local w0 = wall()
  local b = space.body(w.b)
  if not b then return nil end
  local ox, oy, oz, dx, dy, dz = muzzleOf(w)
  local rmax = math.min(RAY_MAX, (w.range or OPTICAL) + 40)
  local h = nil
  local ig = chunkNodes()
  local ok, hh
  if #ig > 0 then ok, hh = pcall(raycast, ox, oy, oz, dx, dy, dz, rmax, { ignore = ig }) else ok, hh = pcall(raycast, ox, oy, oz, dx, dy, dz, rmax) end
  if ok then h = hh end
  PROF.rays = PROF.rays + 1
  if w0 then PROF.ray_ms = (wall() - w0) * 1000 end
  local hit = classify(h, ox, oy, oz, dx, dy, dz, rmax)
  local BEAM = ref("beam")
  local theta = BEAM.divergence(w.L.D, #w.stages, w.L.jit)
  local focus = BEAM.focusFor(hit.d, w.reach, w.focusFixed)
  local rho = airAlong(w.b, ox, oy, oz, hit.x, hit.y, hit.z)
  local rec = applyHit(hit, E, { D = w.L.D, theta = theta, focus = focus, stages = #w.stages, cw = cw, cwKW = w.emitL.cw or 30,
                                 body = w.b, tag = w.key, airRho = rho })
  rec.focus, rec.theta, rec.rho = focus, theta, rho
  local to = holdHit(hit)
  local key = w.key
  showBeam(key, function() return muzzleOf(W[key] or w) end, to, cw and (CW_TICK * 1.6) or PULSE_SHOW, cw and 0.6 or log10(E / 1e5 + 1))
  return rec
end

local function fire_now(w)
  local w0 = wall()
  local why = why_not(w)
  if why then return end
  local E, wallJ, heat = pulseOf(w)
  drain(w)
  local rec = cast(w, E, false)
  if not rec then return end
  rec.wall, rec.heat, rec.stages = wallJ, heat, #w.stages
  local BEAM = ref("beam")
  w.cd = now() + BEAM.cooldown(E / 1e6, w.cool)
  rec.cooldown = w.cd - now()
  lastShot = rec
  shots[#shots + 1] = rec
  if #shots > 32 then table.remove(shots, 1) end
  PROF.shots = PROF.shots + 1
  local ox, oy, oz = muzzleOf(w)
  if ox then
    play("audio/sfx/surveyor_fire.ogg", ox, oy, oz, math.min(1, 0.5 + 0.1 * log10(E / 1e5 + 1) * 3), math.max(0.45, 0.9 - 0.08 * log10(E / 1e5 + 1)), 2000)
    if E >= 5e6 then play("audio/foley/pyro_bang.ogg", ox, oy, oz, 0.8, 0.7, 2500) end
    local fx = ref("vfx")
    if fx and fx.flash then fx.flash(ox, oy, oz, 0.9, 0.9, 1.0, 8, 12, 0.15) end
  end
  if log then
    log(string.format("lasers: PULSE %s %s at %s → %s %s · spot %.3f m · F %.3g J/m² · T %.3f · c %.3g%s", w.key, fmtE(E), fmtR(rec.R), rec.kind,
      rec.hit and (rec.hit.label or rec.hit.kind) or "", rec.d, rec.F, rec.T, rec.c,
      rec.hit and rec.hit.amount and string.format(" · amount %.3f hp %.3f→%s", rec.hit.amount, rec.hit.hp0 or 1, tostring(rec.hit.hp)) or ""))
  end
  if w0 then PROF.fire_ms = (wall() - w0) * 1000 end
  return rec
end

-- ── controls ────────────────────────────────────────────────────────────────
local function touch()
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
end
function setArm(sid, uid, on)
  local w = weaponOf(sid, uid)
  if not w then return false end
  set_part_state(w.sid, w.uid, "arm", on and true or nil)
  w.armed = on and true or false
  if not on then w.cw = false end
  armedN = 0
  for _, x in ipairs(LIST) do if x.armed then armedN = armedN + 1 end end
  last_set = ""
  touch()
  return true
end
function setCw(sid, uid, on)
  local w = weaponOf(sid, uid)
  if not w then return false end
  w.cw = on and w.armed and not w.why and true or false
  touch()
  return w.cw
end
function setFocus(sid, uid, m)
  local w = weaponOf(sid, uid)
  if not (w and w.lensUid) then return false end
  set_part_state(w.sid, w.lensUid, "focus", m and math.max(20, m) or nil)
  w.focusFixed = m and math.max(20, m) or nil
  return true
end
function charge(sid, uid) local w = weaponOf(sid, uid); if not w then return 0, 0 end return capOf(w) end
-- (probes) set every bank of a weapon to a share of its capacity
function setCharge(sid, uid, k)
  local w = weaponOf(sid, uid)
  if not w then return false end
  for _, f in ipairs({ w.feedE, unpack(w.feedS) }) do
    for _, bk in ipairs(f.banks) do E[bk] = (BANK[bk] and BANK[bk].cap or 0) * math.max(0, math.min(1, k)) end
  end
  dirtyE = true
  save_E(true)
  last_set = ""
  return true
end

-- logic (logic_net's dev "laser"): fire on a rising edge, arm by level
function logicIn(sid, uid, pin, on)
  local w = weaponOf(sid, uid)
  if not w then return end
  if pin == "fire" and on then fire(w.sid, w.uid)
  elseif pin == "arm" then setArm(w.sid, w.uid, on) end
end
function logicOut(sid, uid)
  local w = weaponOf(sid, uid)
  if not w then return { ready = false, ontgt = false } end
  return { ready = ready(w), ontgt = w.onT == true }
end

-- The fire-control readout for a weapon now: what it would do at its target.
function readout(sid, uid)
  local w = weaponOf(sid, uid)
  if not w then return nil end
  local BEAM, DM = ref("beam"), ref("damage")
  local E, wallJ = pulseOf(w)
  local e, c = capOf(w)
  local o = { w = w, E = E, wall = wallJ, stored = e, cap = c, armed = w.armed, cw = w.cw, why = why_not(w), cool = w.cool,
              target = w.tgtName, range = w.range, onT = w.onT, err = w.err, lock = w.lock, occ = w.occ, stages = #w.stages,
              cd = math.max(0, (w.cd or 0) - now()) }
  if w.range then
    local theta = BEAM.divergence(w.L.D, #w.stages, w.L.jit)
    local focus = BEAM.focusFor(w.range, w.reach, w.focusFixed)
    local P = BEAM.predict(E, w.range, w.L.D, theta, focus, 1, #w.stages)
    o.d, o.F, o.c, o.focus = P.d, P.F, P.c, focus
    o.verdict = {
      tank = DM.verdict(DM.partAmount(P.F, P.E, "tank")),
      pod = DM.verdict(DM.partAmount(P.F, P.E, "pod")),
      engine = DM.verdict(DM.partAmount(P.F, P.E, "engine")),
      steel = DM.verdict(DM.pieceAmount(P.F, P.E, "steel", 0.11, 2.2)),
      concrete = DM.verdict(DM.pieceAmount(P.F, P.E, "concrete", 2.02, 2.2)),
    }
    o.crater = DM.crater(P.E, P.c)
  end
  return o
end

-- ── the menus ───────────────────────────────────────────────────────────────
local function provider(t, ctx)
  local out = {}
  local TG = ref("targeting")
  -- any spot on a world with a laser on it: "Laser target here"
  if t and t.body and t.rx and #LIST > 0 and TG and TG.targetSpot then
    local onb = false
    for _, w in ipairs(LIST) do if w.b == t.body then onb = true end end
    if onb then
      local ST = ref("structures")
      local rec, part = nil, nil
      if t.node and ST and ST.partOfNode then rec, part = ST.partOfNode(t.node) end
      local d = part and defs(part.id)
      local nm = d and d.label or "ground"
      local bx, by, bz = t.rx, t.ry, t.rz
      out[#out + 1] = { id = "lz_tgt", type = "action", group = "TARGET", label = "Laser target here", hint = "◉",
        act = function() local ok, why = TG.targetSpot(t.body, bx, by, bz, nm); return ok, why end }
    end
  end
  if not (t and t.node) then return out end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return out end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return out end
  local d = defs(part.id) or {}
  local st = part_state(rec.id, part.uid) or {}
  local G = "Laser"
  -- a damaged piece of any kind says so
  if hp_now(rec.id, part.uid) < 1 then
    local sid0, uid0 = rec.id, part.uid
    out[#out + 1] = { id = "lz_hp", type = "info", group = "Damage", label = "Integrity", value = function() return string.format("%d %% (burnt by a beam)", math.floor(hp_now(sid0, uid0) * 100 + 0.5)) end }
  end
  local L = d.lz
  if not L then return out, (#out > 0) and d.label or nil end
  local sid, uid = rec.id, part.uid
  local k = keyOf(sid, uid)
  if L.kind == "cap" then
    out[#out + 1] = { id = "lz_cap", type = "info", group = G, label = "Charge", value = function()
      local b = BANK[k]
      if not b then return string.format("%s · on no laser (join it to an emitter's or a stage's pulse port)", fmtE(E[k] or 0)) end
      local BG = ref("base_grid")
      local sv = BG and BG.partServed and BG.partServed(sid, uid)
      return string.format("%s of %s · %s", fmtE(E[k] or 0), fmtE(b.cap), charging(k) and (sv == false and "the grid is short" or string.format("charging at %d kW", b.kw)) or (b.w.armed and "full" or "laser not armed"))
    end }
    return out, d.label
  end
  local w = (L.kind == "director" and W[k]) or nil
  if not w then
    -- the emitter, a stage, a lens, a console, a bank's laser: its structure's first
    for _, x in ipairs(BYSID[sid] or {}) do
      if L.kind == "console" or L.kind == "radar" or x.emitter == k or keyOf(sid, x.lensUid or -1) == k then w = x; break end
      for _, s in ipairs(x.stages) do if s == k then w = x end end
    end
  end
  if L.kind == "radar" then
    out[#out + 1] = { id = "lz_radar", type = "info", group = G, label = "Radar", value = function()
      local n = 0
      for _, x in ipairs(LIST) do if x.radar then n = n + 1 end end
      return string.format("locks to %s for %d laser%s on its grid", fmtR(L.range or 5e5), n, n == 1 and "" or "s")
    end }
    return out, d.label
  end
  if not w then
    local br = BYSID[sid] and BYSID[sid].broken
    out[#out + 1] = { id = "lz_none", type = "info", group = G, label = "Laser", value = (br and br[1] and br[1].why) or "no laser here: emitter → (stages, lens) → Beam Director, banks on a Pulse Bus" }
    return out, d.label
  end
  local wk = w.key
  local function wn() return W[wk] end
  out[#out + 1] = { id = "lz_arm", type = "toggle", group = G, label = "ARMED (banks charge from the grid)", keep = true,
    on = function() local x = wn(); return x and x.armed or false end, act = function(want) setArm(w.sid, w.uid, want) end }
  out[#out + 1] = { id = "lz_state", type = "info", group = G, label = "Charge", value = function()
    local o = readout(w.sid, w.uid)
    if not o then return "—" end
    return string.format("%s of %s in the banks · pulse %s · %d stage%s · cooling %d %%", fmtE(o.stored), fmtE(o.cap), fmtE(o.E), o.stages, o.stages == 1 and "" or "s", math.floor((o.cool or 0) * 100 + 0.5))
  end }
  out[#out + 1] = { id = "lz_tgt2", type = "info", group = G, label = "Target", value = function()
    local o = readout(w.sid, w.uid)
    if not (o and o.target) then return "none · right-click a craft, a part or a spot → Set target / Laser target here" end
    if o.occ then return string.format("%s · behind %s", o.target, o.occ) end
    if (o.range or 0) > o.lock then return string.format("%s · %s: past its lock (%s%s)", o.target, fmtR(o.range), fmtR(o.lock), o.lock < 1e5 and "; a Targeting Radar on its grid reaches 500 km" or "") end
    return string.format("%s · %s · %s", o.target, fmtR(o.range or 0), o.onT and "ON TARGET" or string.format("slewing (%.1f°)", math.deg(o.err or 0)))
  end }
  out[#out + 1] = { id = "lz_pred", type = "info", group = G, label = "Predicted", value = function()
    local o = readout(w.sid, w.uid)
    if not (o and o.d) then return "—" end
    local v = o.verdict
    local s = string.format("spot %s · F %.2g J/m² · tank %s · pod %s · engine %s · steel wall %s · concrete wall %s · ground %.2f m",
      o.d < 1 and string.format("%.0f cm", o.d * 100) or string.format("%.1f m", o.d), o.F, v.tank, v.pod, v.engine, v.steel, v.concrete, o.crater or 0)
    if (o.c or 0) > 1e-4 then s = s .. string.format(" · CINEMATIC %.0f %%", o.c * 100) end
    return s
  end }
  out[#out + 1] = { id = "lz_fire", type = "action", group = G, label = "FIRE (pulse)", hint = "F", keep = true,
    enabled = function() local x = wn(); return x and why_not(x) == nil end, why = function() local x = wn(); return x and why_not(x) or "no laser" end,
    act = function() return fire(w.sid, w.uid) end }
  out[#out + 1] = { id = "lz_cw", type = "toggle", group = G, label = "CW beam (30 kW, 90 kW from the grid)", keep = true,
    on = function() local x = wn(); return x and x.cw or false end, act = function(want) setCw(w.sid, w.uid, want) end }
  if w.lensUid and keyOf(sid, w.lensUid) == k then
    out[#out + 1] = { id = "lz_focus", type = "action", group = G, label = "Focus: auto / hold the range now", keep = true,
      act = function()
        local x = wn()
        if not x then return false end
        if x.focusFixed then setFocus(x.sid, x.uid, nil) else setFocus(x.sid, x.uid, x.range or 300) end
        return true
      end }
    out[#out + 1] = { id = "lz_focus2", type = "info", group = G, label = "Focus", value = function()
      local x = wn()
      return x and (x.focusFixed and ("held at " .. fmtR(x.focusFixed)) or ("auto, out to " .. fmtR(x.reach))) or "—"
    end }
  end
  out[#out + 1] = { id = "lz_why", type = "info", group = G, label = "Limited by", value = function()
    local x = wn(); return x and (why_not(x) or "nothing: ready") or "—" end }
  return out, d.label
end
providerFn = provider
local reg_on = false

-- ── the engine's calls ──────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("lasers")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  W, LIST, BANK, EMIT, BYSID, beams, queue, pits, chunks = {}, {}, {}, {}, {}, {}, {}, {}, {}
  load_E()
end

local yokes = {}
local function pose_heads()
  local ST = ref("structures")
  if not ST then return end
  for _, w in ipairs(LIST) do
    local n = ST.nodeOf and ST.nodeOf(w.sid, w.uid)
    if n then
      local e = yokes[w.key]
      if not e or e.n ~= n then
        e = { n = n, yoke = n:find("Yoke"), head = n:find("Head") }
        yokes[w.key] = e
      end
      if e.yoke and (e.yaw == nil or math.abs(e.yaw - w.yaw) > 1e-4 or math.abs((e.el or 0) - w.el) > 1e-4) then
        pcall(function()
          e.yoke:setAngles(w.yaw, 0, 0)
          if e.head then e.head:setAngles(w.yaw, -w.el, 0) end   -- (a sibling of the yoke: yaw, then pitch)
        end)
        e.yaw, e.el = w.yaw, w.el
      end
    end
  end
end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "lasers", order = 8 }); reg_on = true end
  end
  local ST = ref("structures")
  if not ST then return end
  if ST.version ~= ver.st and now() - scan_t > 0.5 then scan() end
  if #LIST == 0 then return end
  local t = now()
  local every = (params and params.every) or 0.5
  if t - (update_t or -10) >= every then
    update_t = t
    step_banks()
    save_E(false)
  end
  if #chunks > 0 then chunks_tick() end
end

function fixedUpdate(node, dt)
  if #LIST == 0 or (armedN == 0 and #queue == 0) then return end
  local w0 = wall()
  for _, w in ipairs(LIST) do
    if w.armed then
      slew(w, dt or (1 / 60))
      if w.cw and not w.why then
        local BG = ref("base_grid")
        local served = BG and BG.partServed and w.emitterUid and BG.partServed(w.sid, w.emitterUid)
        if served == false then w.cw = false; say("CW beam off: the grid is short of its 90 kW")
        else
          w.cwT = (w.cwT or 0) + (dt or 1 / 60)
          if w.cwT >= CW_TICK then
            local duty = math.max(0.4, w.cool or 1)
            local E = (w.emitL.cw or 30) * 1000 * w.cwT * duty
            w.cwT = 0
            w.lastCw = cast(w, E, true)
          end
        end
      end
    end
  end
  for i = 1, #queue do
    local w = W[queue[i]]
    if w then
      fire_now(w)
    end
  end
  queue = {}
  if w0 then PROF.fix_ms = (wall() - w0) * 1000 end
end

function lateUpdate(node, dt)
  if #LIST == 0 then return end
  local w0 = wall()
  pose_heads()
  if #beams > 0 or pool[1] or pool[2] then draw_beams() end
  if w0 then PROF.late_ms = (wall() - w0) * 1000 end
end
