-- LASER TURRET — the craft-mounted laser (expansion X9; Ty 11-09: "turrets for
-- jets", "remote turrets guarding the outside of a landing pod";
-- scripts/parts_weapons.lua; docs/base-building.md §27.7).
--
-- On the Electronics node (scenes/system.ron) beside parts_weapons. The beam's
-- physics is beam.lua's, the hit lasers.lua's (applyHit, classify, the beam
-- drawing), so a turret's pulse does exactly what a kit laser's does.
--
--   FINDING     once a second, every live craft's parts (aboardRecs) for
--               "laserTurret"; nothing else is kept between frames but the
--               turret's own numbers (charge, aim in its own gimbal frame).
--   CHARGING    its 0.5 MJ capacitor draws from the craft's batteries at up to
--               10 kW while ARMED (vessel_controller controlState /
--               elecSetCharge), on the agency clock.
--   AIMING      fixedUpdate, tick poses: the TARGET (targeting.resolve) into
--               the part's frame (partFrameNow), yaw about the hull normal
--               (+X) and elevation, slewed at 40°/s, 20 times a second. AUTO fires the moment it
--               is on target and charged: a sentry.
--   FIRING      one raycast from the muzzle (tick pose) along where it points,
--               the craft itself ignored; lasers.applyHit; the beam drawn by
--               lasers.showBeam from the head's drawn pose.
--   THE HEAD    lateUpdate: its Yoke and Head nodes turned to the aim (angles
--               in the part's frame: nothing world-side to go stale).
--
-- Not saved: the charge starts at 0 each session (it refills from the
-- batteries) and ARM/AUTO are off. Old saves: no change.
--
-- Probes: turrets(), turretOf(v, uid), arm(v, uid, on), auto, fireTurret,
-- setTurretCharge, lastShot, PROF.

TUR = { id = "laserTurret", cap = 0.5e6, kw = 10, eff = 0.30, D = 0.3, jit = 1.0e-6, slew = 40,
        pivot = 0.30, muzzle = 0.40, elMin = math.rad(-5), elMax = math.rad(90), reach = 5000, lock = 5000 }
PROF = { scan_ms = 0, fix_ms = 0, late_ms = 0, shots = 0 }
SHOW = 0.15          -- s a pulse's beam is drawn
AIM_DT = 0.05        -- s between aim updates (20 Hz: each reads two part frames and the target's)
lastShot = nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function log10(x) return math.log(x) / math.log(10) end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return now()
end

-- key "<craft node id>:<uid>" → { v, uid, e, armed, auto, yaw, el, cd, onT, err, range, … }
TS = {}
local LIST = {}
local scan_t, chg_a = -10, nil
local queue = {}
local armedN = 0

local function scan()
  local w0 = wall()
  local keep, list = {}, {}
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid ~= false and v.aboardRecs and not (v.isLost and v.isLost()) then
      for uid, d in pairs(v.aboardRecs() or {}) do
        if d.id == TUR.id then
          local k = tostring(v.node.id) .. ":" .. tostring(uid)
          local s = TS[k] or { e = 0, armed = false, auto = false, yaw = 0, el = 0, cd = -1e9 }
          s.v, s.uid, s.key = v, uid, k
          keep[k] = s
          list[#list + 1] = s
        end
      end
    end
  end
  TS, LIST = keep, list
  armedN = 0
  for _, s in ipairs(LIST) do if s.armed then armedN = armedN + 1 end end
  scan_t = now()
  if w0 then PROF.scan_ms = (wall() - w0) * 1000 end
end
function turrets() return LIST end
function turretOf(v, uid) return v and v.node and TS[tostring(v.node.id) .. ":" .. tostring(uid)] or nil end

-- the gimbal frame in the world from the part's frame F (partFrameNow, tick):
-- up = the part's +X (out of the hull), front = its +Z, right = up × front
local function gimbal(F)
  local U = { x = F.rx, y = F.ry, z = F.rz }
  local Fw = { x = F.zx, y = F.zy, z = F.zz }
  local R = { x = U.y * Fw.z - U.z * Fw.y, y = U.z * Fw.x - U.x * Fw.z, z = U.x * Fw.y - U.y * Fw.x }
  return U, Fw, R
end
local function aim_dir(s, U, Fw, R)
  local cy, sy, ce, se = math.cos(s.yaw), math.sin(s.yaw), math.cos(s.el), math.sin(s.el)
  return R.x * sy * ce + U.x * se + Fw.x * cy * ce, R.y * sy * ce + U.y * se + Fw.y * cy * ce, R.z * sy * ce + U.z * se + Fw.z * cy * ce
end
-- the muzzle and the beam's direction, tick pose
local function muzzle_tick(s)
  local F = s.v.partFrameNow and s.v.partFrameNow(s.uid)
  if not F then return nil end
  local U, Fw, R = gimbal(F)
  local dx, dy, dz = aim_dir(s, U, Fw, R)
  local px, py, pz = F.ox + U.x * TUR.pivot, F.oy + U.y * TUR.pivot, F.oz + U.z * TUR.pivot
  return px + dx * TUR.muzzle, py + dy * TUR.muzzle, pz + dz * TUR.muzzle, dx, dy, dz, px, py, pz, U, Fw, R
end
-- the muzzle as DRAWN this frame: the head node itself
local function muzzle_drawn(s)
  local v = s.v
  if not (v and v.node and v.node.valid ~= false and v.r2NodeOf) then return nil end
  local n = v.r2NodeOf(v.node, s.uid)
  local h = n and (s.headN and s.headN.valid ~= false and s.headN or n:find("Head"))
  if not (h and h.toWorld) then return nil end
  s.headN = h
  local o = h:toWorld(vec3(0, 0, TUR.muzzle))
  local f = h:toWorld(vec3(0, 0, TUR.muzzle + 1))
  return o.x, o.y, o.z, f.x - o.x, f.y - o.y, f.z - o.z
end

local function slew(s, dt)
  local TG = ref("targeting")
  local T = TG and TG.resolve and TG.resolve()
  s.tgtName = nil
  if not T or (T.v and T.v == s.v) then s.onT = false; s.range = nil; s.err = nil; return end
  local ox, oy, oz, _, _, _, px, py, pz, U, Fw, R = muzzle_tick(s)
  if not px then return end
  local tx, ty, tz = T.x - px, T.y - py, T.z - pz
  local r = len(tx, ty, tz)
  s.range, s.tgtName = r, T.name
  local tk = tostring(T.name) .. "|" .. tostring(T.v and T.v.node and T.v.node.id or "")
  if tk ~= s.tkey then s.tkey = tk; s.onT = false end
  if r < 1 or r > TUR.lock then s.onT = false; return end
  local lx, ly, lz = tx * R.x + ty * R.y + tz * R.z, tx * U.x + ty * U.y + tz * U.z, tx * Fw.x + ty * Fw.y + tz * Fw.z
  local wy = math.atan2(lx, lz)
  local we = math.max(TUR.elMin, math.min(TUR.elMax, math.atan2(ly, math.sqrt(lx * lx + lz * lz))))
  local step = math.rad(TUR.slew) * dt
  s.yaw = wrap(s.yaw + math.max(-step, math.min(step, wrap(wy - s.yaw))))
  s.el = s.el + math.max(-step, math.min(step, we - s.el))
  local dx, dy, dz = aim_dir(s, U, Fw, R)
  local err = math.acos(math.max(-1, math.min(1, (dx * tx + dy * ty + dz * tz) / r)))
  s.err = err
  local miss = err * r
  if s.onT then s.onT = miss < 0.6 else s.onT = miss < 0.3 end
end

local function pulse_of(s)
  local BEAM = ref("beam")
  return BEAM and BEAM.BUS_EFF * TUR.eff * (s.e or 0) or 0
end
local function why_not(s)
  if not s.armed then return "not armed" end
  if now() < (s.cd or -1e9) then return string.format("cooling: %.1f s", s.cd - now()) end
  if (s.e or 0) < TUR.cap * 0.98 then return string.format("charging: %d %%", math.floor((s.e or 0) / TUR.cap * 100)) end
  return nil
end
whyNot = why_not

function fireTurret(v, uid)
  local s = turretOf(v, uid)
  if not s then return false, "no turret" end
  local why = why_not(s)
  if why then return false, why end
  queue[#queue + 1] = s.key
  return true
end

local function fire_now(s)
  local LZ, BEAM = ref("lasers"), ref("beam")
  if not (LZ and BEAM and LZ.applyHit) then return end
  local ox, oy, oz, dx, dy, dz = muzzle_tick(s)
  if not ox then return end
  local E = pulse_of(s)
  s.e = 0
  local rmax = math.min(20000, (s.range or TUR.lock) + 40)
  local ig = LZ.chunkNodes and LZ.chunkNodes(s.v.node) or { s.v.node }
  local ok, h = pcall(raycast, ox, oy, oz, dx, dy, dz, rmax, { ignore = ig, ignoreChildren = true })
  if not ok then h = nil end
  local hit = LZ.classify(h, ox, oy, oz, dx, dy, dz, rmax)
  local theta = BEAM.divergence(TUR.D, 0, TUR.jit)
  local focus = BEAM.focusFor(hit.d, TUR.reach)
  local body = space.dominant and space.dominant(ox, oy, oz)
  local rho = LZ.airAlong and LZ.airAlong(body, ox, oy, oz, hit.x, hit.y, hit.z) or 0
  local rec = LZ.applyHit(hit, E, { D = TUR.D, theta = theta, focus = focus, stages = 0, body = body, tag = "turret " .. s.key, airRho = rho })
  rec.focus, rec.theta = focus, theta
  s.cd = now() + BEAM.cooldown(E / 1e6, 1)
  rec.cooldown = s.cd - now()
  lastShot = rec
  s.last = rec
  PROF.shots = PROF.shots + 1
  local to = LZ.holdHit(hit)
  LZ.showBeam("t" .. s.key, function() return muzzle_drawn(s) end, to, SHOW, log10(E / 1e5 + 1) + 0.5)
  if audio and audio.play then
    pcall(audio.play, "audio/sfx/surveyor_fire.ogg", ox, oy, oz, { track = "SFX", volume = 0.8, pitch = 0.8, mode = "Spatial", falloff = "Inverse", minDistance = 6, maxDistance = 1200 })
  end
  if log then
    log(string.format("laser_turret: PULSE %s %.0f kJ at %.0f m → %s %s · spot %.3f m · F %.3g · T %.3f%s", s.key, E / 1e3, rec.R, rec.kind,
      rec.hit and (rec.hit.label or rec.hit.kind) or "", rec.d, rec.F, rec.T,
      rec.hit and rec.hit.amount and string.format(" · amount %.3f hp %s→%s", rec.hit.amount, tostring(rec.hit.hp0), tostring(rec.hit.hp)) or ""))
  end
  return rec
end

-- ── controls ────────────────────────────────────────────────────────────────
function arm(v, uid, on)
  local s = turretOf(v, uid)
  if not s then return false end
  s.armed = on and true or false
  if not on then s.auto = false end
  armedN = 0
  for _, x in ipairs(LIST) do if x.armed then armedN = armedN + 1 end end
  return true
end
function auto(v, uid, on) local s = turretOf(v, uid); if not s then return false end s.auto = on and s.armed or false; return s.auto end
function setTurretCharge(v, uid, k) local s = turretOf(v, uid); if not s then return false end s.e = TUR.cap * math.max(0, math.min(1, k)); return true end

-- the batteries → the capacitor, on the agency clock
local function charge_step()
  local a = agency_now()
  if not chg_a then chg_a = a end
  local dt = math.max(0, math.min(3600, a - chg_a))
  chg_a = a
  if dt <= 0 then return end
  for _, s in ipairs(LIST) do
    if s.armed and (s.e or 0) < TUR.cap then
      local v = s.v
      local cs = v.controlState and v.controlState()
      if cs and cs.charge and v.elecSetCharge then
        local want = math.min(TUR.cap - s.e, TUR.kw * 1000 * dt)
        local take = math.min(want, math.max(0, cs.charge) * 1000)   -- (1 EC = 1 kJ)
        if take > 0 then
          pcall(v.elecSetCharge, cs.charge - take / 1000)
          s.e = s.e + take
        end
        s.short = take + 1 < want
      end
    end
  end
end

-- ── the part's menu ─────────────────────────────────────────────────────────
local function provider(t, ctx)
  if not (t and t.vessel and t.uid) then return {} end
  local v, uid = t.vessel, t.uid
  local d = (v.partRec and v.partRec(uid)) or t.rec or {}
  if d.id ~= TUR.id then return {} end
  if not turretOf(v, uid) then scan() end
  local G = "Laser Turret"
  local LZ = ref("lasers")
  local fE = LZ and LZ.fmtEnergy or function(j) return string.format("%.0f kJ", (j or 0) / 1e3) end
  local out = {}
  out[#out + 1] = { id = "lt_arm", type = "toggle", group = G, label = "ARMED (charges from the batteries, tracks the target)", keep = true,
    on = function() local s = turretOf(v, uid); return s and s.armed or false end, act = function(want) arm(v, uid, want) end }
  out[#out + 1] = { id = "lt_auto", type = "toggle", group = G, label = "AUTO: fire when on target and charged", keep = true,
    on = function() local s = turretOf(v, uid); return s and s.auto or false end, act = function(want) auto(v, uid, want) end }
  out[#out + 1] = { id = "lt_state", type = "info", group = G, label = "Capacitor", value = function()
    local s = turretOf(v, uid)
    if not s then return "—" end
    return string.format("%s of %s · pulse %s%s", fE(s.e), fE(TUR.cap), fE(pulse_of(s)), s.short and " · the batteries are flat" or "")
  end }
  out[#out + 1] = { id = "lt_tgt", type = "info", group = G, label = "Target", value = function()
    local s = turretOf(v, uid)
    if not (s and s.tgtName) then return "none · right-click a craft, a part or a spot → Set target" end
    if (s.range or 0) > TUR.lock then return string.format("%s · %.0f m: past its 5 km lock", s.tgtName, s.range) end
    return string.format("%s · %.0f m · %s", s.tgtName, s.range or 0, s.onT and "ON TARGET" or string.format("slewing (%.1f°)", math.deg(s.err or 0)))
  end }
  out[#out + 1] = { id = "lt_fire", type = "action", group = G, label = "FIRE", keep = true,
    enabled = function() local s = turretOf(v, uid); return s ~= nil and why_not(s) == nil end,
    why = function() local s = turretOf(v, uid); return s and why_not(s) or "no turret" end,
    act = function() return fireTurret(v, uid) end }
  return out, d.label or "Laser Turret"
end
providerFn = provider
local reg_on = false

-- ── the engine's calls ──────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("laser_turret")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  TS, LIST, queue = {}, {}, {}
end

local chg_t = -10
function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("part", provider, { id = "laser_turret", order = 9 }); reg_on = true end
  end
  if now() - scan_t > 1.0 then scan() end
  if #LIST == 0 then return end
  if now() - chg_t > 0.5 then chg_t = now(); charge_step() end
end

function fixedUpdate(node, dt)
  if #LIST == 0 or (armedN == 0 and #queue == 0) then return end
  local w0 = wall()
  for _, s in ipairs(LIST) do
    if s.armed and s.v and s.v.node and s.v.node.valid ~= false then
      s.acc = (s.acc or 0) + (dt or (1 / 60))
      if s.acc >= AIM_DT then
        slew(s, s.acc)
        s.acc = 0
        if s.auto and s.onT and why_not(s) == nil then queue[#queue + 1] = s.key end
      end
    end
  end
  local done = {}
  for _, k in ipairs(queue) do
    local s = TS[k]
    if s and not done[k] and why_not(s) == nil then done[k] = true; fire_now(s) end
  end
  queue = {}
  if w0 then PROF.fix_ms = (wall() - w0) * 1000 end
end

function lateUpdate(node, dt)
  if #LIST == 0 then return end
  local w0 = wall()
  for _, s in ipairs(LIST) do
    local v = s.v
    if v and v.node and v.node.valid ~= false and v.r2NodeOf then
      local n = v.r2NodeOf(v.node, s.uid)
      if n then
        if s.partN ~= n then s.partN, s.yokeN, s.headN = n, n:find("Yoke"), n:find("Head") end
        if s.yokeN and (s.shownY ~= s.yaw or s.shownE ~= s.el) then
          pcall(function()
            s.yokeN:setAngles(s.yaw, 0, 0)
            if s.headN then s.headN:setAngles(s.yaw, -s.el, 0) end   -- (a sibling of the yoke: yaw, then pitch)
          end)
          s.shownY, s.shownE = s.yaw, s.el
        end
      end
    end
  end
  if w0 then PROF.late_ms = (wall() - w0) * 1000 end
end
