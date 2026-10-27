-- VEHICLE FX — what a craft gives off while it works, so you can SEE it work:
--
--   * JETS: a turbojet's tailpipe glow and light, its heat shimmer, soot at
--     spool-up, a contrail in cold thin air (prefabs/FxJet on the nozzle).
--   * HEAT: a simple thermal model per engine and per hull part, shown as a
--     blackbody glow on the part's own material (shaders/hullPanels.flsl
--     `heat`, `flow`): a nozzle glows dull red to orange with its burn and
--     cools after it; reentry cooks the windward faces and they glow on
--     after the plasma has gone. Read out on the part's context menu.
--   * TYRES: tread prints pressed into loose ground, black rubber where a
--     tyre slides on paving or the pad, dust off loose ground, rubber smoke
--     off a hard slide, a puff and a mark where a tyre touches down fast.
--   * DAMAGE: sparks where the hull knocks into something, a badly torn-up
--     part shorting out.
--   * REENTRY: the wake behind the plasma (prefabs/FxReentryWake) and the
--     glow it casts on the craft.
--
-- It reads the craft from the vessel controllers' published state (AERO,
-- R2, throttle, damagedParts, r2NodeOf, partRec) and never writes to them:
-- the effects are a reading of the craft, not part of its simulation. Heat
-- has NO consequence here: the only heat that damages a part is the
-- controller's own reentry heating, which this only shows.
--
-- Design, triggers, costs and the quality tiers: docs/vfx-feedback.md.
-- Spawned by vfx.lua (prefabs/VehicleFx) when the scene has no node running it.

defaults = {
  on = true,
  --- Jet exhaust: plume, shimmer, soot, contrails.
  jets = true,
  --- Engine and reentry heat glow on the parts.
  heat = true,
  --- Tyre marks, dust and rubber smoke.
  tyres = true,
  --- Impact sparks and damaged parts shorting out.
  damage = true,
}

local sqrt, abs, min, max, exp = math.sqrt, math.abs, math.min, math.max, math.exp
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

local now = 0
local RHO0 = 1.225

-- ── quality tiers (graphics.lua level) ──────────────────────────────────────
-- marks: tracked ground marks (decals); paved: rubber strips drawn on the
-- paving (draw.quad a frame each); life: seconds a mark lasts; loose: tread
-- prints on loose ground (else only skids); dust: tyre dust rate scale.
local TIERS = {
  Low    = { haze = false, contrail = false, puffs = false, smoke = 0.5, marks = 120, paved = 60, life = 40,
             loose = false, dust = 0.45, wake = false, shimmer = false, sparks = 0.5 },
  Medium = { haze = true, contrail = true, puffs = false, smoke = 1.0, marks = 360, paved = 160, life = 100,
             loose = true, dust = 0.8, wake = true, shimmer = true, sparks = 1.0 },
  High   = { haze = true, contrail = true, puffs = true, smoke = 1.0, marks = 700, paved = 260, life = 200,
             loose = true, dust = 1.0, wake = true, shimmer = true, sparks = 1.0 },
  Ultra  = { haze = true, contrail = true, puffs = true, smoke = 1.0, marks = 1100, paved = 360, life = 320,
             loose = true, dust = 1.0, wake = true, shimmer = true, sparks = 1.0 },
}
local Q = TIERS.Medium
local tier_name, tier_t = "Medium", -10
local function tier_tick()
  if now - tier_t < 2 then return end
  tier_t = now
  local gx = findScript("graphics")
  local lv = gx and gx.level and gx.level() or "Medium"
  if params.tier and TIERS[params.tier] then lv = params.tier end   -- probes
  tier_name, Q = lv, TIERS[lv] or TIERS.Medium
end

-- ── the world under a point ─────────────────────────────────────────────────
local function body_at(x, y, z)
  if not (space and space.dominant) then return nil end
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  return name, b
end

local vfx_ref = nil
local function vfx()
  if not (vfx_ref and vfx_ref.valid) then vfx_ref = findScript("vfx") end
  return vfx_ref
end

-- A one-shot through vfx.lua (its frame rules and dust tint), or plain.
-- A world sound through sfx.lua (hooks: zap, knock, tyre), riding `node`.
local sfx_ref = nil
local function sound(key, node, vol)
  if not (sfx_ref and sfx_ref.valid) then sfx_ref = findScript("sfx") end
  if sfx_ref and sfx_ref.playAt then pcall(sfx_ref.playAt, key, node, vol) end
end

local function emit(key, x, y, z, o)
  local v = vfx()
  if v and v.emit then v.emit(key, x, y, z, o) else spawnEffect(key, vec3(x, y, z), o or {}) end
end

local cam_x, cam_y, cam_z = nil, nil, nil
local function cam_tick()
  local ok, w, h = pcall(camera.screenSize)
  if ok and w and w > 0 then
    local ok2, ox, oy, oz = pcall(camera.screenToRay, w * 0.5, h * 0.5)
    if ok2 and ox then cam_x, cam_y, cam_z = ox, oy, oz end
  end
end
local function cam_d(x, y, z)
  if not cam_x then return 0 end
  return len(x - cam_x, y - cam_y, z - cam_z)
end

-- ── the craft ───────────────────────────────────────────────────────────────
local vessels, vessels_t = {}, -10
local function vessels_tick()
  if now - vessels_t < 1.0 then return end
  vessels_t = now
  local out = {}
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.valid and v.node and v.node.valid and not (v.isLost and v.isLost()) then out[#out + 1] = v end
  end
  vessels = out
end

-- The nodes that carry a part's materials: its named mesh children (round
-- two parts, the turbojet's Body) or the part itself.
local MESH_KIDS = { Body = true, Mount = true, Tyre = true, Base = true, Head = true, Stage = true,
                    Hub = true, Fingers = true, Housing = true, Bit = true, Panel = true, Flap = true,
                    Leg = true, Blade = true, SolarYoke = true, SolarWing = true }
local function mesh_nodes(part)
  local kids = {}
  for _, k in ipairs(part:children()) do
    if MESH_KIDS[k.name or ""] then kids[#kids + 1] = k end
  end
  if #kids == 0 then kids[1] = part end
  return kids
end

-- ════════════════════════════════════════════════════════════════════════════
-- HEAT
-- ════════════════════════════════════════════════════════════════════════════
-- One entry per part node that is or was hot: two temperatures on the same
-- 0 … 1.4 scale the shader reads (0.3 dull red, 0.7 orange-red, 1 bright
-- orange, 1.4 yellow-white), each easing toward what heats it this frame:
--   Te  an engine's own: the nozzle (named materials only)
--   Th  the hull: reentry, on every material, windward faces
-- Rising is quick, cooling slow and slower still in vacuum (radiation only);
-- an airstream carries heat off faster. A part's temperature in kelvin is
-- shown as 290 + 1100·T (1 ≈ 1,400 K, an orange glow).
local heat = {}           -- part node id → entry
local heat_n = 0
local writes = 0          -- shader writes this frame (stats)

local function heat_entry(part)
  local id = part.id
  local e = heat[id]
  if e and e.part == part and e.part.valid then return e end
  e = { part = part, Te = 0, Th = 0, se = 0, sh = 0, set = -1, sht = -1, wTe = 0, wTh = 0,
        mats = nil, meshes = nil, air = 1, spd = 0, flow = nil, wflow = nil, nozzle = nil, shim_t = 0 }
  heat[id] = e
  return e
end

-- An engine heats its nozzle toward `target` this frame.
local function heat_engine(part, target, mats, air, nozzle)
  if params.heat == false or (target <= 0 and not heat[part.id]) then return end
  local e = heat_entry(part)
  local tn = time or now
  e.se, e.set, e.air = max(tn - e.set < 0.05 and e.se or 0, target), tn, air or e.air
  e.mats, e.nozzle = mats, nozzle or e.nozzle
end

-- Reentry heats a hull part toward `target`, windward faces along (fx,fy,fz).
local function heat_hull(part, target, fx, fy, fz, air, spd)
  if params.heat == false or (target <= 0 and not heat[part.id]) then return end
  local e = heat_entry(part)
  local tn = time or now
  e.sh, e.sht = max(tn - e.sht < 0.05 and e.sh or 0, target), tn
  e.flow, e.air, e.spd = { fx, fy, fz }, air or e.air, spd or e.spd
end

local function mats_of(n)
  local ok, list = pcall(n.materials, n)
  local set = {}
  if ok and type(list) == "table" then
    for _, m in ipairs(list) do
      if type(m) == "table" then
        if m.material then set[m.material] = true end
      elseif type(m) == "string" then
        set[m] = true
      end
    end
  end
  return set
end

local function write_mats(e, names, T)
  for _, mn in ipairs(e.meshes) do
    mn.mset = mn.mset or mats_of(mn.n)
    for _, name in ipairs(names) do
      if mn.mset[name] then
        local ok, m = pcall(mn.n.material, mn.n, name)
        if ok and m then pcall(m.setShaderParam, m, "heat", T) end
      end
    end
  end
end

local function heat_write(e)
  if not e.meshes then
    e.meshes = {}
    for _, n in ipairs(mesh_nodes(e.part)) do e.meshes[#e.meshes + 1] = { n = n } end
  end
  local th, te = e.Th, e.Te
  local dh, de = abs(th - e.wTh), abs(te - e.wTe)
  local hull_changed = dh > 0.012 or (th < 0.004 and e.wTh > 0)
  if hull_changed then
    for _, mn in ipairs(e.meshes) do
      if mn.n.valid then
        pcall(mn.n.setShaderParam, mn.n, "heat", th)
        local f = e.flow
        if f then pcall(mn.n.setShaderParam, mn.n, "flow", f[1], f[2], f[3]) end
      end
    end
    e.wTh = th < 0.004 and 0 or th
    writes = writes + 1
  end
  -- the nozzle's own, over the hull's (a node-wide write above set it too)
  if e.mats and (de > 0.012 or hull_changed or (te < 0.004 and e.wTe > 0)) then
    local T = max(te, th)
    write_mats(e, e.mats.hot, T)
    if e.mats.warm then write_mats(e, e.mats.warm, max(te * 0.55, th)) end
    e.wTe = te < 0.004 and 0 or te
    writes = writes + 1
  end
end

local function heat_tick(dt)
  writes = 0
  local n = 0
  for id, e in pairs(heat) do
    if not e.part.valid then
      heat[id] = nil
    else
      n = n + 1
      -- (a source reported this frame or the last: vfx.lua may run before or
      -- after this script in a frame)
      local se = now - e.set < 0.12 and e.se or 0
      local sh = now - e.sht < 0.12 and e.sh or 0
      -- cooling: radiation alone in vacuum (slow), an airstream carries more
      local cool = 26 / (1 + 4 * (e.air or 0) * (0.4 + min(1, (e.spd or 0) / 60)))
      local tau_e = se > e.Te and 5.5 or cool
      local tau_h = sh > e.Th and 2.2 or cool * 0.8
      e.Te = e.Te + (se - e.Te) * (1 - exp(-dt / tau_e))
      e.Th = e.Th + (sh - e.Th) * (1 - exp(-dt / tau_h))
      heat_write(e)
      -- shimmer over a hot nozzle once the burn is over (air only)
      if Q.shimmer and se <= 0 and e.Te > 0.3 and (e.air or 0) > 0.08 and e.nozzle and e.nozzle.valid
        and now - e.shim_t > 0.35 and cam_d(e.part.x, e.part.y, e.part.z) < 80 then
        e.shim_t = now
        local w = e.nozzle.worldPos
        emit("HeatShimmer", w.x, w.y, w.z, { intensity = min(1.5, e.Te) })
      end
      if e.Te < 0.004 and e.Th < 0.004 and se <= 0 and sh <= 0 and e.wTe <= 0 and e.wTh <= 0 then heat[id] = nil end
    end
  end
  heat_n = n
end

-- A part's temperature (kelvin) for the menu and probes: the hotter of its
-- two, or nil when it is cold and not tracked.
function partTemp(part)
  local e = part and heat[part.id]
  if not (e and e.part == part) then return nil end
  local T = max(e.Te, e.Th)
  return 290 + 1100 * T, T, e.Te, e.Th
end

-- ════════════════════════════════════════════════════════════════════════════
-- ROCKET ENGINES (called by vfx.flame every frame per "Engine Flame")
-- ════════════════════════════════════════════════════════════════════════════
local ROCKET_MATS = { hot = { "BellIn", "Bell" } }
local burning = {}     -- flame node id → { live, t }
function burn(part, live, pct, air, flame)
  if not (part and part.valid) or params.on == false then return end
  local fid = flame and flame.id or part.id
  local b = burning[fid] or { live = false, t = -10 }
  burning[fid] = b
  -- a radiation-cooled bell: dull red at a trickle, orange at full
  heat_engine(part, live and (0.36 + 0.52 * (pct or 0)) or 0, ROCKET_MATS, air, flame)
  -- lighting and cutting off: a flash and a gout of smoke, a breath of vapour
  if live ~= b.live and now - b.t > 0.25 and flame and flame.valid then
    local w, pw = flame.worldPos, part.worldPos
    local dx, dy, dz = norm(w.x - pw.x, w.y - pw.y, w.z - pw.z)
    local o = { normal = vec3(dx, dy, dz), intensity = clamp(0.4 + (air or 0) * 1.2, 0.3, 1.4) }
    if (air or 0) > 0.02 or live then
      emit(live and "IgnitionPuff" or "ShutdownPuff", w.x + dx * 0.4, w.y + dy * 0.4, w.z + dz * 0.4, o)
    end
    b.t = now
  end
  b.live = live
end

-- ════════════════════════════════════════════════════════════════════════════
-- JETS
-- ════════════════════════════════════════════════════════════════════════════
-- The turbojet nozzle: the inner pipe and the turbine face glow first, the
-- outer shroud a little.
local JET_MATS = { hot = { "BellIn", "Dark" }, warm = { "Bell" } }
local NOZZLE_Y = -0.92
local jets = {}       -- vessel node id .. ":" .. uid → state
local jets_n = 0
local climate_ref = nil
local cold_cache = {}  -- vessel id → { t, k }

local function child_of(n, name)
  for _, c in ipairs(n:children()) do if c.name == name then return c end end
  return nil
end

local function jet_nodes(J, n)
  J.fx = n
  J.plume, J.haze = child_of(n, "Jet Plume"), child_of(n, "Jet Haze")
  J.smoke, J.trail, J.puffs = child_of(n, "Jet Smoke"), child_of(n, "Jet Contrail"), child_of(n, "Contrail Puffs")
  J.light = J.plume and J.plume:getcomponent("PointLight")
end

-- Run a child effect at an intensity; 0 lets its live particles finish,
-- and it is stopped once it has been idle a while.
local function drive(node, k, key, J)
  if not (node and node.valid) then return end
  local ps = node:particles()
  if not ps then return end
  if k > 0.02 then
    if not ps:isPlaying() then ps:play() end
    ps:setIntensity(k)
    J[key] = now
  elseif ps:isPlaying() then
    if now - (J[key] or 0) < 8 then ps:setIntensity(0) else ps:stop() end
  end
end

-- How far past the frost point the jet's air is, 0 … 1: the world's surface
-- temperature (climate.lua) lapsing with height through its air.
local function contrail_k(vc, x, y, z, name, b, alt, sigma)
  local c = cold_cache[vc.node.id]
  if c and now - c.t < 2 then return c.k end
  c = c or {}
  c.t = now
  if not (climate_ref and climate_ref.valid) then climate_ref = findScript("climate") end
  local w = save.get("world." .. name)
  local H = (type(w) == "table" and (w.atmoHeight or 0) > 0) and w.atmoHeight or (b.radius or 800) * 0.35
  local ok, s = false, nil
  if climate_ref and climate_ref.sampleAt then ok, s = pcall(climate_ref.sampleAt, name, x, y, z) end
  local surfC = (ok and type(s) == "table" and s.temp) and (-40 + s.temp * 90) or 10
  local T = surfC - 60 * clamp(alt / H, 0, 1.5)
  c.k = clamp((-30 - T) / 14, 0, 1) * clamp((sigma - 0.04) / 0.1, 0, 1)
  cold_cache[vc.node.id] = c
  return c.k
end

local function jet_one(vc, M, j, thr, sigma, ctx)
  local key = vc.node.id .. ":" .. j.uid
  local J = jets[key]
  if not J then J = { uid = j.uid, s0 = 0 }; jets[key] = J end
  J.t = now
  local part = J.part
  if not (part and part.valid) then
    part = vc.r2NodeOf and vc.r2NodeOf(vc.node, j.uid)
    J.part, J.fx, J.asked = part, nil, nil
  end
  if not part then return end
  if not (J.fx and J.fx.valid) then
    if not J.asked and spawn then
      J.asked = true
      spawn("FxJet", part.worldPos, function(n)
        n.x, n.y, n.z = 0, NOZZLE_Y, 0
        n.pitch = math.pi   -- local +Y out of the nozzle (−Y of the part)
        jet_nodes(J, n)
      end, part)
    end
    return
  end
  local s, lit = j.s or 0, j.lit == true
  local run = lit and s or 0
  -- the plume and its light by the spool
  drive(J.plume, run > 0.04 and (0.2 + 0.95 * run) or 0, "pt", J)
  if J.light then J.light.intensity = run > 0.04 and (0.35 + 3.2 * run ^ 1.5) * (0.9 + 0.2 * math.random()) or 0 end
  drive(J.haze, (Q.haze and run > 0.06) and (0.3 + 0.9 * run) or 0, "ht", J)
  -- soot: an early turbojet smokes as it spools up, thinly at power
  local lag = max(0, (lit and thr or 0) - s)
  drive(J.smoke, lit and clamp((0.1 * s + 1.8 * lag) * min(1, sigma * 2) * Q.smoke, 0, 1.2) or 0, "st", J)
  -- the contrail
  local ck = 0
  if Q.contrail and run > 0.3 and ctx.spd > 25 then
    ck = contrail_k(vc, ctx.x, ctx.y, ctx.z, ctx.name, ctx.b, ctx.alt, sigma) * min(1, (run - 0.3) * 2.5)
  end
  drive(J.trail, ck, "ct", J)
  drive(J.puffs, Q.puffs and ck or 0, "cp", J)
  -- the nozzle's heat: a dull red down the pipe at power
  heat_engine(part, lit and (0.06 + 0.66 * s * s) or 0, JET_MATS, min(1, sigma * 2), J.plume)
  -- lighting: a puff of unburnt fuel out of the pipe
  if lit and s > 0.02 and J.s0 <= 0.02 and thr > 0.05 then
    local w = J.fx.worldPos
    local pw = part.worldPos
    local dx, dy, dz = norm(w.x - pw.x, w.y - pw.y, w.z - pw.z)
    emit("IgnitionPuff", w.x + dx * 0.3, w.y + dy * 0.3, w.z + dz * 0.3, { normal = vec3(dx, dy, dz), intensity = 0.5 })
  end
  J.s0 = s
end

local function jets_tick(vc)
  if params.jets == false then return end
  local A = vc.AERO
  local M = A and A.model
  if not (M and M.jets and #M.jets > 0) then return end
  local n = vc.node
  local name, b = body_at(n.x, n.y, n.z)
  if not b then return end
  local rho = M.diag and M.diag.rho or 0
  local v = assembly.info(n)
  v = v and v.vel or { x = 0, y = 0, z = 0 }
  local ctx = { name = name, b = b, x = n.x, y = n.y, z = n.z,
                alt = len(n.x - b.x, n.y - b.y, n.z - b.z) - (b.radius or 0),
                spd = len(v.x, v.y, v.z) }
  for _, j in ipairs(M.jets) do jet_one(vc, M, j, vc.throttle or 0, rho / RHO0, ctx) end
end

local function jets_reap()
  local n = 0
  for k, J in pairs(jets) do
    if now - (J.t or 0) > 1.0 or not (J.part and J.part.valid) then
      if J.fx and J.fx.valid then J.fx:destroy() end
      jets[k] = nil
    else
      n = n + 1
    end
  end
  jets_n = n
end

-- ════════════════════════════════════════════════════════════════════════════
-- REENTRY (called by vfx.heat every frame a craft is in the hot band)
-- ════════════════════════════════════════════════════════════════════════════
local wake = { node = nil, asked = false, t = -10, glow = 0 }
local hull_parts = {}   -- vessel node id → { t, list }

local function parts_of(vnode)
  local c = hull_parts[vnode.id]
  if c and now - c.t < 1.0 then return c.list end
  local list = {}
  for _, ch in ipairs(vnode:children()) do
    local nm = ch.name or ""
    if nm:sub(1, 4) == "Part" then list[#list + 1] = ch end
  end
  hull_parts[vnode.id] = { t = now, list = list }
  return list
end

function reentry(vnode, glow, vx, vy, vz)
  if params.on == false or not (vnode and vnode.valid) then return end
  local w = vnode.worldPos
  local name, b = body_at(w.x, w.y, w.z)
  if not b then return end
  local rx, ry, rz = vx, vy, vz
  local dx, dy, dz, spd = norm(rx, ry, rz)
  if spd < 1 then return end
  -- the windward parts take the heat, the lee ones a little
  local list = parts_of(vnode)
  local best = -math.huge
  local proj = {}
  for i, p in ipairs(list) do
    if p.valid then
      local pw = p.worldPos
      proj[i] = (pw.x - w.x) * dx + (pw.y - w.y) * dy + (pw.z - w.z) * dz
      if proj[i] > best then best = proj[i] end
    end
  end
  local hot = min(1.35, glow * 0.95)
  for i, p in ipairs(list) do
    if proj[i] then
      local k = clamp(1 - (best - proj[i]) / 2.6, 0.18, 1)
      heat_hull(p, hot * k, dx, dy, dz, 0.2, spd)
    end
  end
  wake.v, wake.glow, wake.t, wake.dx, wake.dy, wake.dz, wake.lead = vnode, glow, now, dx, dy, dz, best
end

local function wake_tick()
  local live = now - wake.t < 0.3 and wake.v and wake.v.valid
  if live and Q.wake and not (wake.node and wake.node.valid) and not wake.asked and spawn then
    wake.asked = true
    spawn("FxReentryWake", wake.v.worldPos, function(n) wake.node = n end)
  end
  local n = wake.node
  if not (n and n.valid) then return end
  local ps = n:particles()
  local light = n:getcomponent("PointLight")
  if not live or not Q.wake then
    if ps and ps:isPlaying() then
      if now - wake.t < 3 then ps:setIntensity(0) else ps:stop() end
    end
    if light then light.intensity = 0 end
    return
  end
  -- at the leading face, streaming back: the ribbon and the sparks are left
  -- along the path behind it
  local w = wake.v.worldPos
  local f = (wake.lead or 1) + 0.6
  n.x, n.y, n.z = w.x + wake.dx * f, w.y + wake.dy * f, w.z + wake.dz * f
  local tx, ty, tz = 0, 0, 1
  if abs(wake.dz) > 0.9 then tx, ty, tz = 1, 0, 0 end
  n.yaw, n.pitch, n.roll = lookRotation(vec3(tx, ty, tz), vec3(-wake.dx, -wake.dy, -wake.dz))
  if ps then
    if not ps:isPlaying() then ps:play() end
    ps:setIntensity(clamp(0.15 + wake.glow * 1.1, 0, 1.8))
  end
  -- the plasma lights the craft: pink-orange, flickering
  if light then
    light.intensity = clamp(wake.glow, 0, 1.6) * 9 * (0.85 + 0.3 * math.random())
    light.range = 18 + 14 * clamp(wake.glow, 0, 1)
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TYRES
-- ════════════════════════════════════════════════════════════════════════════
-- Each grounded tyre is read every frame: the contact patch, its speed over
-- the ground, and its SLIP — the patch's own speed over the ground, from the
-- tyre's velocity and its spin (the turn of the ball between frames about
-- its axle; the drawn tyre's spin is the hull's speed, so it would never
-- slip). A rolling tyre's patch is at rest: slip 0. A slide sideways, a
-- locked wheel or a spinning one all show as slip.
--
-- Where it rolls decides the mark:
--   loose ground   a tread print always (Medium+), darker as it slips; dust
--   paving, pad    nothing while rolling; black rubber and smoke when it
--                  slides; light rubber under a hard stop
-- The base's paving is a visual mesh 0.14 m over the graded ground with no
-- collider, and decals lie on colliders, so a rubber mark there would lie
-- under the asphalt: on the paving the marks are quads drawn just over it
-- (draw.quad, a frame each, culled by distance). Everywhere else (the pad,
-- loose ground) they are decals.
local TRACK_TEX = "textures/vfx/decal/tyre_track.png"
local SKID_TEX = "textures/vfx/decal/skid.png"
local SCUFF_TEX = "textures/vfx/decal/scuff.png"
local PAVE_H = 0.155
local wheels = {}          -- tyre node id → state
local marks = {}           -- decals, oldest first: { id, body, ox, oy, oz, a0, t0, life, vis }
local quads = {}           -- paving strips, oldest first: { body, corners (8 rel), a, t0, life }
local stat = { decals = 0, quads = 0, dust = 0, smoke = 0, sparks = 0, shorts = 0, skid_m = 0 }

-- ── is a point on the base's paving? (base_facilities' layout) ──
local bf_ref, paveF, paveF_t = nil, nil, -10
local function pave_frame()
  if now - paveF_t < 5 and paveF ~= nil then return paveF end
  paveF_t = now
  paveF = false
  if not (bf_ref and bf_ref.valid) then bf_ref = findScript("base_facilities") end
  local bf = bf_ref
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (bf and bf.frameOf and bf.uvOf and bx) then return false end
  local R = save.get("base.r") or len(bx, by, bz)
  paveF = { F = bf.frameOf({ x = bx, y = by, z = bz }, save.get("base.heading") or 0, R), body = save.get("base.body"),
            bf = bf, R = R }
  return paveF
end

local function in_strip(u, v, u0, v0, u1, v1, half)
  local du, dv = u1 - u0, v1 - v0
  local L2 = du * du + dv * dv
  local t = L2 > 0 and ((u - u0) * du + (v - v0) * dv) / L2 or 0
  if t < -0.01 or t > 1.01 then return false end
  local px, py = u0 + du * t - u, v0 + dv * t - v
  return px * px + py * py <= half * half
end

local function paved_at(name, rx, ry, rz)
  local P = pave_frame()
  if not P or P.body ~= name then return false end
  local bf = P.bf
  local u, v = bf.uvOf(P.F, { x = rx, y = ry, z = rz })
  if u * u + v * v > 300 * 300 then return false end
  local RW, TW = bf.RUNWAY, bf.TAXIWAY
  if RW and save.get("base.runway") ~= false and in_strip(u, v, RW.u0 - RW.blast, RW.v, RW.u1 + RW.blast, RW.v, RW.half + RW.shoulder) then return true end
  if TW and in_strip(u, v, TW.u, TW.v0, TW.u, TW.v1, TW.half) then return true end
  for _, s in ipairs(bf.STRIPS or {}) do
    if in_strip(u, v, s[2], s[3], s[4], s[5], s[6]) then return true end
  end
  return false
end

-- ── laying marks ──
local function mark_vis(m, x, y, z)
  local v = 1
  if cam_x then
    local d = len(x - cam_x, y - cam_y, z - cam_z)
    v = 1 - clamp((d - 70) / 45, 0, 1)
  end
  local age = now - m.t0
  if age > m.life * 0.75 then v = v * max(0, (m.life - age) / (m.life * 0.25)) end
  return math.floor(v * 4 + 0.5) / 4
end

local function mark_drop(i)
  local m = marks[i]
  if m.id then pcall(decals.remove, m.id) end
  table.remove(marks, i)
end

local function lay_decal(tex, name, b, cx, cy, cz, nx, ny, nz, dx, dy, dz, width, length, alpha, color)
  if not (decals and decals.add) then return end
  local m = { body = name, ox = cx - b.x, oy = cy - b.y, oz = cz - b.z, a0 = alpha, t0 = now, life = Q.life }
  m.vis = mark_vis(m, cx, cy, cz)
  local ok, id = pcall(decals.add, { texture = tex, pos = vec3(cx, cy, cz), normal = vec3(nx, ny, nz),
    size = width, height = length, depth = 0.6, up = vec3(dx, dy, dz), alpha = alpha * m.vis, color = color })
  if not (ok and id) then return end
  m.id = id
  while #marks >= Q.marks do mark_drop(1) end
  marks[#marks + 1] = m
  stat.decals = stat.decals + 1
end

local function lay_quad(name, b, ax, ay, az, bx2, by2, bz2, ux, uy, uz, width, alpha)
  -- corners: the strip from A to B, `width` across, lifted onto the paving
  local dx, dy, dz, L = norm(bx2 - ax, by2 - ay, bz2 - az)
  if L < 0.05 then return end
  local sx, sy, sz = norm(dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux)
  local h = width * 0.5
  local lx, ly, lz = ux * PAVE_H - b.x, uy * PAVE_H - b.y, uz * PAVE_H - b.z
  local q = { body = name, a = alpha, t0 = now, life = Q.life,
    c = { ax - sx * h + lx, ay - sy * h + ly, az - sz * h + lz, ax + sx * h + lx, ay + sy * h + ly, az + sz * h + lz,
          bx2 + sx * h + lx, by2 + sy * h + ly, bz2 + sz * h + lz, bx2 - sx * h + lx, by2 - sy * h + ly, bz2 - sz * h + lz } }
  while #quads >= Q.paved do table.remove(quads, 1) end
  quads[#quads + 1] = q
  stat.quads = stat.quads + 1
end

local function quads_draw()
  if #quads == 0 or not (draw and draw.quad) then return end
  local bodies = {}
  local i = 1
  while i <= #quads do
    local q = quads[i]
    local age = now - q.t0
    if age > q.life then
      table.remove(quads, i)
    else
      local b = bodies[q.body]
      if b == nil then b = space.body(q.body) or false; bodies[q.body] = b end
      if b then
        local c = q.c
        local x0, y0, z0 = b.x + c[1], b.y + c[2], b.z + c[3]
        local d = cam_d(x0, y0, z0)
        if d < 110 then
          local a = q.a * (1 - clamp((d - 70) / 40, 0, 1))
          if age > q.life * 0.75 then a = a * (q.life - age) / (q.life * 0.25) end
          draw.quad(SKID_TEX, x0, y0, z0, b.x + c[4], b.y + c[5], b.z + c[6], b.x + c[7], b.y + c[8], b.z + c[9],
            b.x + c[10], b.y + c[11], b.z + c[12], 1, 1, 1, a)
        end
      end
      i = i + 1
    end
  end
end

local mark_fade_t = 0
local function marks_tick()
  if #marks == 0 or now - mark_fade_t < 0.25 then return end
  mark_fade_t = now
  local i = 1
  while i <= #marks do
    local m = marks[i]
    local b = space.body(m.body)
    if not b or now - m.t0 > m.life then
      mark_drop(i)
    else
      local v = mark_vis(m, b.x + m.ox, b.y + m.oy, b.z + m.oz)
      if v ~= m.vis and not decals.set(m.id, { alpha = m.a0 * v }) then
        table.remove(marks, i)
      else
        m.vis = v
        i = i + 1
      end
    end
  end
end

-- ── one tyre ──
local function tyre_one(vc, w, name, b, dt, hardbrake)
  local t = w.tyre
  local W = wheels[t.id]
  if not W or W.tyre ~= t then W = { tyre = t, air_t = now, seg = nil }; wheels[t.id] = W end
  W.t = now
  local r = w.r or 0.4
  local ux, uy, uz = norm(t.x - b.x, t.y - b.y, t.z - b.z)
  local gn = t.groundNormal
  local nx, ny, nz = ux, uy, uz
  if gn then nx, ny, nz = gn.x, gn.y, gn.z end
  local cx, cy, cz = t.x - nx * r, t.y - ny * r, t.z - nz * r
  local v = t.vel or { x = 0, y = 0, z = 0 }
  local gvx, gvy, gvz = v.x, v.y, v.z
  local vn = gvx * nx + gvy * ny + gvz * nz
  gvx, gvy, gvz = gvx - nx * vn, gvy - ny * vn, gvz - nz * vn
  local spd = len(gvx, gvy, gvz)
  -- the axle: the drawn tyre's X (laid along the steered axle each frame)
  local m = w.mesh
  local ax = (m and m.valid) and m:worldRight() or vc.node:worldRight()
  local axn = ax.x * nx + ax.y * ny + ax.z * nz
  local axx, axy, axz = norm(ax.x - nx * axn, ax.y - ny * axn, ax.z - nz * axn)
  -- the ball's turn about the axle since the last frame
  local bu = t:worldUp()
  local omega, trusted = nil, false
  if W.bu and dt > 0 then
    local p, c = W.bu, bu
    local pa = p.x * axx + p.y * axy + p.z * axz
    local ca = c.x * axx + c.y * axy + c.z * axz
    local px, py, pz = p.x - axx * pa, p.y - axy * pa, p.z - axz * pa
    local qx, qy, qz = c.x - axx * ca, c.y - axy * ca, c.z - axz * ca
    local crx, cry, crz = py * qz - pz * qy, pz * qx - px * qz, px * qy - py * qx
    local ang = math.atan2(crx * axx + cry * axy + crz * axz, px * qx + py * qy + pz * qz)
    omega = ang / dt
    trusted = spd / r * dt < 1.3 and abs(ang) < 1.6
  end
  W.bu = { x = bu.x, y = bu.y, z = bu.z }
  local grounded = t.grounded == true
  if not grounded then
    if W.ground then W.air_t = now end
    W.ground, W.seg = false, nil
    return
  end
  -- the patch's own speed over the ground: v + ω × r, r = −n·R
  local slip
  if trusted and omega then
    -- ω × (−n R) with ω = omega·axle
    local wx, wy, wz = axy * (-nz) - axz * (-ny), axz * (-nx) - axx * (-nz), axx * (-ny) - axy * (-nx)
    local px, py, pz = gvx + omega * r * wx, gvy + omega * r * wy, gvz + omega * r * wz
    slip = len(px, py, pz)
  else
    -- too fast to read the spin: assume it rolls, so only the sideways part slips
    slip = abs(gvx * axx + gvy * axy + gvz * axz)
  end
  W.slip, W.spd = slip, spd
  local rel_x, rel_y, rel_z = cx - b.x, cy - b.y, cz - b.z
  -- a hard surface: the paving, or anything standing over the ground (the pad)
  W.pq = (W.pq or 0) - 1
  if W.pq <= 0 then
    W.pq = 6
    W.paved = paved_at(name, rel_x, rel_y, rel_z)
    local q = terrain and terrain.query and terrain.query(cx, cy, cz)
    W.hard = W.paved or (q ~= nil and q > 0.12)
  end
  local width = clamp(r * 0.62, 0.14, 0.5)
  -- touchdown: a fast tyre meeting the ground after a while in the air
  if W.ground == false and now - (W.air_t or now) > 0.4 and spd > 6 then
    if W.hard then
      emit("TyreTouch", cx + nx * 0.1, cy + ny * 0.1, cz + nz * 0.1, { vel = vec3(gvx, gvy, gvz), intensity = clamp(spd / 30, 0.4, 1.4) })
      W.touch = now
      sound("tyre", t, clamp(spd / 25, 0.3, 1.0))
    else
      emit("TyreDust", cx + nx * 0.1, cy + ny * 0.1, cz + nz * 0.1, { vel = vec3(gvx, gvy, gvz), intensity = 1.6, dust = true })
    end
  end
  W.ground = true
  if spd < 0.6 and slip < 1.0 then W.seg = nil return end
  local skid = clamp((slip - 1.2) / 4.0, 0, 1)
  if W.touch and now - W.touch < 0.35 then skid = max(skid, 0.8) end
  if hardbrake and W.hard then skid = max(skid, 0.3) end
  -- dust off loose ground, smoke off a hard slide
  W.fx_acc = (W.fx_acc or 0)
  if not W.hard then
    local rate = Q.dust * min(14, spd * 0.55 + slip * 2.2)
    W.fx_acc = W.fx_acc + rate * dt
    if W.fx_acc >= 1 and cam_d(cx, cy, cz) < 160 then
      W.fx_acc = 0
      emit("TyreDust", cx + nx * 0.12, cy + ny * 0.12, cz + nz * 0.12,
        { vel = vec3(gvx, gvy, gvz), intensity = clamp(0.5 + spd / 14 + slip / 6, 0.5, 1.6), dust = true })
      stat.dust = stat.dust + 1
    end
  elseif skid > 0.3 then
    W.fx_acc = W.fx_acc + Q.smoke * 9 * skid * dt
    if W.fx_acc >= 1 and cam_d(cx, cy, cz) < 160 then
      W.fx_acc = 0
      emit("TyreSmoke", cx + nx * 0.2, cy + ny * 0.2, cz + nz * 0.2, { vel = vec3(gvx, gvy, gvz), intensity = clamp(skid * 1.3, 0.4, 1.4) })
      stat.smoke = stat.smoke + 1
    end
  end
  -- the mark: a segment each `seg` metres along the path
  local want = (not W.hard and Q.loose) or skid > 0.08
  if not want then W.seg = nil return end
  local S = W.seg
  if not S or S.body ~= name or S.hard ~= W.hard then
    W.seg = { body = name, x = rel_x, y = rel_y, z = rel_z, hard = W.hard, paved = W.paved }
    return
  end
  local dx, dy, dz, d = norm(rel_x - S.x, rel_y - S.y, rel_z - S.z)
  local step = W.hard and 0.9 or 1.5
  if d < step then return end
  if d > 6 then S.x, S.y, S.z = rel_x, rel_y, rel_z return end   -- a jump, not a slide
  if W.hard then
    local a = 0.25 + 0.6 * skid
    stat.skid_m = stat.skid_m + d
    if W.paved then
      lay_quad(name, b, b.x + S.x, b.y + S.y, b.z + S.z, cx, cy, cz, ux, uy, uz, width, a)
    else
      lay_decal(SKID_TEX, name, b, b.x + (S.x + rel_x) * 0.5, b.y + (S.y + rel_y) * 0.5, b.z + (S.z + rel_z) * 0.5,
        nx, ny, nz, dx, dy, dz, width, d + 0.12, a)
    end
  else
    local v = vfx()
    local tint = v and v.dustTint and v.dustTint(name)
    local col = tint and { tint[1] * 0.85, tint[2] * 0.85, tint[3] * 0.85 } or nil
    lay_decal(TRACK_TEX, name, b, b.x + (S.x + rel_x) * 0.5, b.y + (S.y + rel_y) * 0.5, b.z + (S.z + rel_z) * 0.5,
      nx, ny, nz, dx, dy, dz, width * 1.1, d + 0.1, clamp(0.6 + 0.5 * skid, 0, 1), col)
  end
  S.x, S.y, S.z = rel_x, rel_y, rel_z
end

local function tyres_tick(vc, dt)
  if params.tyres == false then return end
  local R2 = vc.R2
  if not (R2 and R2.live and R2.wheels and #R2.wheels > 0) then return end
  local n = vc.node
  local name, b = body_at(n.x, n.y, n.z)
  if not b then return end
  if cam_d(n.x, n.y, n.z) > 400 then return end
  -- a hard stop: the craft slowing faster than ~0.55 g over the ground
  local i = assembly.info(n)
  local v = i and i.vel or { x = 0, y = 0, z = 0 }
  local sp = len(v.x, v.y, v.z)
  local V = wheels[n.id .. "v"] or {}
  wheels[n.id .. "v"] = V
  local g = (b.mu or 0) / ((b.radius or 1) ^ 2)
  local hardbrake = V.sp and dt > 0 and (V.sp - sp) / dt > 0.55 * max(g, 1) and sp > 2
  V.sp, V.t = sp, now
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid then tyre_one(vc, w, name, b, dt, hardbrake) end
  end
end

local function wheels_reap()
  for k, W in pairs(wheels) do
    if now - (W.t or 0) > 2 then wheels[k] = nil end
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- DAMAGE: knocks and a torn-up part shorting out
-- ════════════════════════════════════════════════════════════════════════════
local knock_t = {}    -- vessel id → last spark time
local short_t = {}

local function impacts_tick(vc)
  if params.damage == false or not (assembly and assembly.impacts) then return end
  local n = vc.node
  if now - (knock_t[n.id] or 0) < 0.12 then return end
  local ok, list = pcall(assembly.impacts, n)
  if not ok or type(list) ~= "table" or #list == 0 then return end
  local best = nil
  for _, h in ipairs(list) do
    local s = h.speedAbs or h.speed or 0
    if s > 4.5 and (not best or s > (best.speedAbs or best.speed or 0)) then best = h end
  end
  if not best then return end
  -- landing legs are built to hit the ground
  -- (`part` is the part's node id: the craft's own child)
  local pn = best.part
  if type(pn) == "number" then pn = n:getChild(pn) end
  local uid = pn and pn.valid and vc.uidOfNode and vc.uidOfNode(pn)
  local rec = uid and vc.partRec and vc.partRec(uid)
  if rec and (rec.legs or 0) == 1 and (best.speedAbs or 0) < 9 then return end
  knock_t[n.id] = now
  local s = best.speedAbs or best.speed or 0
  local _, b = body_at(best.x, best.y, best.z)
  local i = assembly.info(n)
  local v = i and i.vel or { x = 0, y = 0, z = 0 }
  emit("ImpactSparks", best.x, best.y, best.z, { vel = vec3(v.x, v.y, v.z),
    intensity = clamp(s / 10, 0.4, 1.8) * Q.sparks })
  sound("knock", (pn and pn.valid) and pn or n, clamp(s / 12, 0.3, 1.0))
  stat.sparks = stat.sparks + 1
end

local function shorts_tick(vc)
  if params.damage == false or not vc.damagedParts then return end
  local n = vc.node
  if now - (short_t[n.id] or 0) < 0.4 then return end
  short_t[n.id] = now
  if cam_d(n.x, n.y, n.z) > 250 then return end
  local list = vc.damagedParts()
  local fired = 0
  for _, d in ipairs(list) do
    if d.hp < 0.35 and fired < 3 and math.random() < 0.35 * Q.sparks then
      local p = vc.r2NodeOf and vc.r2NodeOf(n, d.uid)
      if p and p.valid then
        local w = p.worldPos
        local _, b = body_at(w.x, w.y, w.z)
        local i = assembly.info(n)
        local v = i and i.vel or { x = 0, y = 0, z = 0 }
        local ox, oy, oz = (math.random() - 0.5) * 0.6, (math.random() - 0.5) * 0.6, (math.random() - 0.5) * 0.6
        emit("ShortSpark", w.x + ox, w.y + oy, w.z + oz, { vel = vec3(v.x, v.y, v.z) })
        local fx = vfx()
        if fx and fx.flash and math.random() < 0.5 then fx.flash(w.x + ox, w.y + oy, w.z + oz, 0.65, 0.75, 1.0, 3.5, 6, 0.1) end
        sound("zap", p, 0.7 + 0.3 * math.random())
        fired = fired + 1
        stat.shorts = stat.shorts + 1
      end
    end
  end
end

-- A hull dragged over the ground: a scuff laid where it bit (vfx.scrape).
local scuff_t = 0
function scuff(x, y, z, vx, vy, vz)
  if params.damage == false or now - scuff_t < 0.18 then return end
  local name, b = body_at(x, y, z)
  if not b then return end
  local ux, uy, uz = norm(x - b.x, y - b.y, z - b.z)
  local h = raycast(x + ux * 1.0, y + uy * 1.0, z + uz * 1.0, -ux, -uy, -uz, 3.0)
  if not h then return end
  scuff_t = now
  local rx, ry, rz = vx, vy, vz
  local hn = (h.nx and h.ny and h.nz) and h or { nx = ux, ny = uy, nz = uz }
  local dn = rx * hn.nx + ry * hn.ny + rz * hn.nz
  local dx, dy, dz, sp = norm(rx - hn.nx * dn, ry - hn.ny * dn, rz - hn.nz * dn)
  if sp < 0.5 then dx, dy, dz = norm(hn.ny, hn.nz, hn.nx) end
  lay_decal(SCUFF_TEX, name, b, h.x, h.y, h.z, hn.nx, hn.ny, hn.nz, dx, dy, dz, 0.9, clamp(1.2 + sp * 0.12, 1.2, 3.5), 0.85)
end

-- ════════════════════════════════════════════════════════════════════════════
-- the part menu: an engine's nozzle, a hot hull part
-- ════════════════════════════════════════════════════════════════════════════
local reg_with = nil
local function temp_words(K)
  if K < 500 then return "cold" end
  if K < 800 then return "hot" end
  if K < 1050 then return "glowing dull red" end
  if K < 1350 then return "glowing orange" end
  return "white hot"
end
local function provider(t, ctx)
  local part = t.node
  if not (part and part.valid) then return {} end
  local rec = t.rec or {}
  local engine = (rec.thrust or 0) > 0
  if not engine and not heat[part.id] then return {} end
  local label = engine and "NOZZLE" or "SKIN"
  return { { type = "meter", id = "temp", label = label .. " TEMP",
    frac = function()
      local K = partTemp(part)
      return K and clamp((K - 290) / 1540, 0, 1) or 0
    end,
    value = function()
      local K = partTemp(part) or 290
      return string.format("%.0f K  %s", K, temp_words(K))
    end,
    warn = function() return (partTemp(part) or 0) > 1100 end } }
end
local function reg_tick()
  if reg_with and reg_with.valid ~= false then return end
  local r = findScript("context_registry")
  if r and r.register then
    r.register("part", provider, { id = "vehicle_fx.temp", order = 26 })
    reg_with = r
  end
end

-- ════════════════════════════════════════════════════════════════════════════
local said = {}
function vessel_tick(vc, dt)
  jets_tick(vc)
  tyres_tick(vc, dt)
  impacts_tick(vc)
  shorts_tick(vc)
end

function start(node)
  reg_tick()
end

function update(node, dt)
  now = time or (now + dt)
  if params.on == false then return end
  tier_tick()
  cam_tick()
  vessels_tick()
  reg_tick()
  for _, vc in ipairs(vessels) do
    local n = vc.valid and vc.node
    if n and n.valid then
      -- one craft's trouble must not take the others' (or the heat) down
      local ok, err = pcall(vessel_tick, vc, dt)
      if not ok and not said[tostring(err)] then said[tostring(err)] = true; log("vehicle_fx: " .. tostring(err)) end
    end
  end
  jets_reap()
  if math.floor(now) ~= math.floor(now - dt) then wheels_reap() end
  heat_tick(dt)
  marks_tick()
end

function lateUpdate(node, dt)
  if params.on == false then return end
  wake_tick()
  quads_draw()
end

-- What it is doing, for probes and the perf readout.
function stats()
  local hot = 0
  for _, e in pairs(heat) do if max(e.Te, e.Th) > 0.05 then hot = hot + 1 end end
  return { tier = tier_name, jets = jets_n, heat = heat_n, hot = hot, writes = writes, marks = #marks,
           quads = #quads, decals = stat.decals, laidQuads = stat.quads, dust = stat.dust, smoke = stat.smoke,
           sparks = stat.sparks, shorts = stat.shorts, skid_m = stat.skid_m, wake = wake.node ~= nil and now - wake.t < 0.3 }
end

-- A tyre's reading, for probes: { slip, spd, hard, paved, ground } by tyre id.
function wheelStats()
  local out = {}
  for k, W in pairs(wheels) do
    if type(k) == "number" then
      out[#out + 1] = { id = k, slip = W.slip or 0, spd = W.spd or 0, hard = W.hard, paved = W.paved, ground = W.ground }
    end
  end
  return out
end
