-- TL-5 SURVEYOR — the crew's plasma rifle (items.lua `surveyor`): a survey
-- tool's beam optics turned into a weapon, for the hostile life the crew will
-- meet out there and, as built, for each other.
--
-- WHO DOES WHAT. The rifle is a two-handed TOOL, so tool_belt draws it (the
-- third-person hold, the first-person view model, the energy shaders) and
-- reads the mouse; when it is the item in hand tool_belt calls `tick` here
-- every frame and draws `drawReticle` for its reticle. This script owns the
-- rest: the charge, the scope, the cell, the bolts in flight, what they hit,
-- the marks they leave, and the cells' recharge. It rides the ItemsLib node.
--
-- THE TEMPO: a sniper's, not a machine gun's. Hold LMB and the capacitor
-- charges (`charge_secs` to full, the coolant loop and the cell glow climb);
-- let go and the bolt leaves — a quick tap is a weak bolt, a full charge the
-- real one, under `min_charge` nothing fires. After a shot the coils vent for
-- `vent_secs` before the next charge can start. RMB held: aim down the scope
-- (first person: the scope's picture, `zoom_fp`×; third person: over the
-- shoulder, `zoom_tp`×), the look slowed to match. H holsters (item_hand).
--
-- THE BOLT is a fast PROJECTILE, not a hitscan ray: `speed` m/s (150 m in
-- 0.4 s), dead straight (a magnetically confined plasmoid; no drop) and gone
-- at `range`. Travel time is what makes it read — you see the bolt cross the
-- valley — and what makes a long shot a skill (lead a walking target); it
-- costs one ray and a few capsule tests per bolt per frame. Its position is
-- kept in its PLANET's frame and turned into a world point each frame (the
-- home world moves 1.5–6 m a tick): never a world point across frames.
--
-- WHAT IT HITS, nearest first along each frame's step:
--   * crew: every member out in the world as an analytic capsule — the one
--     you control, a CrewBody on foot, a doll in an OPEN seat (a closed cabin
--     shields its crew: the hull takes the hit). Head or body by the height
--     along the capsule. crew.hurt(id, dmg, "shot", "by <name>, <d> m"):
--     the HP and HIT chips, death and the memorial at 0 — or the rescue with
--     death off. Friendly fire is real; the shooter's own capsule is skipped.
--   * a craft part: its hp drops (vessel_controller.hitPart when it has it,
--     which can break the part; else wearPart, which scuffs but never breaks)
--     and the hull shader scorches; a burn mark rides the craft.
--   * the ground: a burn mark and a small crater (a 0.35 m bite; the flora
--     wash is lifted first, as the laser does).
-- Everything else (a building, a crate, a rock): a burn mark.
--
-- DAMAGE (pure, below; tests/smoke_surveyor.lua): base × charge × falloff ×
-- zone × (1 − armour). Full charge, body, 30 m: 0.51 of a healthy crew member
-- (two hits); 150 m: 0.45 (three). Head ×1.6 through the visor (armour 0.12),
-- a bare head takes it all. Falloff: whole to `full_range`, then down to
-- `fall_min` at `range` (the plasmoid bleeding off).
--
-- THE CELL is the item's FILL (inventory: a level per rifle, 0..100). A
-- shot draws `cost_min`..`cost_max` by charge. It recharges at
-- `recharge`/s while its member is aboard a craft or within `home_r` of the
-- base (the Command Centre), so a long walk out is a budget.
--
-- SAFETY: no firing under a roof that isn't rock (a building), in the VAB's
-- builder (tool_belt's gate), aboard, or with a panel up.
--
-- Probes: `sim` = { lmb = bool, rmb = bool } overrides the buttons (tool_belt
-- passes its own sim too); `fireFrom(ox,oy,oz, dx,dy,dz, opts)` fires a bolt
-- from anywhere as anyone (opts.charge, opts.by, opts.shooter); `bolts_()`;
-- `lastShot`, `lastHit`, `stats`.

defaults = {
  --@header Tempo
  --@range 0.2 3 --@units s
  charge_secs = 0.9,       -- trigger held → full charge
  --@range 0 1
  min_charge = 0.25,       -- let go below this and nothing fires
  --@range 0 4 --@units s
  vent_secs = 0.7,         -- after a shot, before the next charge starts
  --@header Bolt
  --@range 50 2000 --@units m/s
  speed = 380.0,
  --@range 50 2000 --@units m
  range = 450.0,
  --@range 1 8 --@units m
  streak = 6.0,            -- the drawn streak behind the head (a tracer: it must read at 150 m)
  --@header Damage
  --@range 0 2
  dmg = 0.64,              -- a full-charge body hit at point blank, before armour (crew hp 0..1)
  --@range 1 4
  head_mul = 1.6,
  --@range 0 400 --@units m
  full_range = 60.0,
  --@range 0 1
  fall_min = 0.45,         -- the falloff's floor, at `range`
  --@range 0 1
  part_dmg = 0.25,         -- a full-charge hit on a craft part (part hp 0..1)
  --@range 0 1 --@units m
  crater_r = 0.35,         -- the ground's bite (0 = a burn mark only)
  --@header Cell
  --@range 1 50
  cost_min = 5.0,          -- cell units for the weakest bolt …
  --@range 1 50
  cost_max = 10.0,         -- … and for a full charge (a cell is 100)
  --@range 0 50 --@units /s
  recharge = 4.0,
  --@range 10 400 --@units m
  home_r = 90.0,
  --@header Scope
  --@range 1 12
  zoom_fp = 4.0,
  --@range 1 6
  zoom_tp = 2.0,
  --@range 0 1
  sound = 1.0,
  --@range 30 900 --@units s
  mark_life = 240.0,
}

-- ── the rules, pure (luajit: tests/smoke_surveyor.lua) ─────────────────────

local function P(k) return (params and params[k] ~= nil) and params[k] or defaults[k] end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local sqrt = math.sqrt
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end

-- Armour by where the bolt lands and what is worn: the pressure suit's TMG
-- layers stop a share of a body hit, the visor a little less of a head hit;
-- a bare head nothing.
ARMOUR = { body = 0.20, head = 0.12, head_bare = 0.0 }

-- The charge after `secs` of trigger (eased: most of it early, the last
-- tenth slow, so a full charge is a held breath, not a long wait).
function chargeAt(secs)
  local k = clamp((secs or 0) / P("charge_secs"), 0, 1)
  return 1 - (1 - k) * (1 - k)
end

-- Cell units a bolt of `charge` draws.
function shotCost(charge)
  return P("cost_min") + (P("cost_max") - P("cost_min")) * clamp(charge or 0, 0, 1)
end

-- May a bolt of `charge` leave a cell holding `cell`? → ok, why
function canFire(cell, charge)
  if (charge or 0) < P("min_charge") then return false, "not charged" end
  if (cell or 0) + 1e-6 < shotCost(charge) then return false, "the cell is flat" end
  return true, nil
end

-- The plasmoid bleeding off with distance: 1 to `full_range`, then linear
-- down to `fall_min` at `range`; past the range nothing (the bolt is gone).
function falloff(d)
  d = d or 0
  local r0, r1 = P("full_range"), P("range")
  if d <= r0 then return 1.0 end
  if d >= r1 then return 0.0 end
  return 1 - (1 - P("fall_min")) * (d - r0) / (r1 - r0)
end

-- The share of a hit the suit stops. zone "head"|"body"; helmet false = bare.
function armourOf(zone, helmet)
  if zone == "head" then return helmet == false and ARMOUR.head_bare or ARMOUR.head end
  return ARMOUR.body
end

-- What a bolt of `charge` does to a crew member at `d` metres in `zone`.
function crewDamage(charge, d, zone, helmet)
  local c = 0.3 + 0.7 * clamp(charge or 0, 0, 1)
  local z = zone == "head" and P("head_mul") or 1.0
  return P("dmg") * c * falloff(d) * z * (1 - armourOf(zone, helmet))
end

-- What it does to a craft part's hp.
function partDamage(charge, d)
  return P("part_dmg") * (0.3 + 0.7 * clamp(charge or 0, 0, 1)) * falloff(d)
end

-- Hits to bring a healthy member down with full-charge bolts (the tests and
-- the item's card read it).
function hitsToKill(d, zone, helmet)
  local x = crewDamage(1.0, d, zone or "body", helmet)
  if x <= 0 then return math.huge end
  return math.ceil(1 / x - 1e-9)
end

-- A ray (origin o, unit dir d) against a capsule (segment a→b, radius r) →
-- distance along the ray and where along the axis (0 at a … 1 at b), or nil.
-- (Inigo Quilez's capsule intersection.)
function rayCapsule(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, r)
  local bax, bay, baz = bx - ax, by - ay, bz - az
  local oax, oay, oaz = ox - ax, oy - ay, oz - az
  local baba = bax * bax + bay * bay + baz * baz
  local bard = bax * dx + bay * dy + baz * dz
  local baoa = bax * oax + bay * oay + baz * oaz
  local rdoa = dx * oax + dy * oay + dz * oaz
  local oaoa = oax * oax + oay * oay + oaz * oaz
  local a = baba - bard * bard
  local b = baba * rdoa - baoa * bard
  local c = baba * oaoa - baoa * baoa - r * r * baba
  local h = b * b - a * c
  if a > 1e-9 and h >= 0 then
    local t = (-b - sqrt(h)) / a
    local y = baoa + t * bard
    if y > 0 and y < baba and t >= 0 then return t, y / baba end
  end
  -- the end caps
  local best, s = nil, nil
  for k = 0, 1 do
    local cx, cy, cz = oax, oay, oaz
    if k == 1 then cx, cy, cz = ox - bx, oy - by, oz - bz end
    local bb = dx * cx + dy * cy + dz * cz
    local cc = cx * cx + cy * cy + cz * cz - r * r
    local hh = bb * bb - cc
    if hh >= 0 then
      local t = -bb - sqrt(hh)
      if t >= 0 and (not best or t < best) then best, s = t, k end
    end
  end
  return best, s
end

-- Head or body, by where along a standing capsule (0 soles … 1 crown) or a
-- seated one the bolt went in.
function zoneAt(s, seated)
  if seated then return (s or 0) > 0.72 and "head" or "body" end
  -- (the head bone sits 0.565 m over a suit's centre, measured on the rig:
  -- the helmet from 0.50 m up, 0.78 of the way up the capsule)
  return (s or 0) > 0.78 and "head" or "body"
end

-- ── runtime ────────────────────────────────────────────────────────────────

-- Published (tool_belt, the HUD, probes).
charge = 0.0          -- 0..1 while the trigger is held
heat = 0.0            -- 0..1: the coolant loop's colour (climbs a shot, vents off)
scoped = false        -- RMB held: aiming down the scope (eased: scopeK)
scopeK = 0.0
cell = nil            -- the rifle in hand's cell, 0..100 (nil: none in hand)
ready = false         -- charged past min_charge
venting = 0.0         -- seconds of vent left
blocked = nil         -- why it won't fire here (a roof, …), or nil
aimDist = nil         -- metres to what the crosshair is on
lastShot = nil        -- { t, charge, cost, x,y,z, dx,dy,dz, by, ms }
lastHit = nil         -- { t, kind = "crew"|"part"|"ground"|"thing", id, uid, dmg, d, zone, hp, x,y,z, ms }
stats = { shots = 0, hits = 0, crew_hits = 0, part_hits = 0, ground_hits = 0, fire_ms = 0, hit_ms = 0, step_ms = 0 }
sim = nil
flash = 0.0           -- the shot's flash on the energy parts (decays)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function clock() return os and os.clock and os.clock() or 0 end

local function play(path, a, b, c, o)
  if (P("sound") or 1) <= 0 or not (audio and audio.play) then return nil end
  local ok, h
  if type(a) == "number" then ok, h = pcall(audio.play, path, a, b, c, o)
  else ok, h = pcall(audio.play, path, a) end
  return ok and h or nil
end
local SND = {
  charge = "audio/sfx/surveyor_charge.ogg",
  ready = "audio/sfx/surveyor_ready.ogg",
  fire = "audio/sfx/surveyor_fire.ogg",
  hit = "audio/sfx/surveyor_hit.ogg",
  vent = "audio/foley/hiss_short.ogg",
  dry = "audio/foley/buzz_denied.ogg",
  scope = "audio/foley/switch_2.ogg",
}

local astro_n = nil
local function astro()
  if not (astro_n and astro_n.valid) then astro_n = find and find("Astronaut") or nil end
  return astro_n
end

-- The planet a world point is in, and the point in its frame.
local function to_body(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return nil end
  return name, x - b.x, y - b.y, z - b.z, b
end
local function to_world(name, x, y, z)
  local b = name and space.body(name)
  if not b then return nil end
  return b.x + x, b.y + y, b.z + z
end
local function up_at(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return 0, 1, 0 end
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = len(ux, uy, uz)
  if l < 1e-6 then return 0, 1, 0 end
  return ux / l, uy / l, uz / l
end

-- ── the cell: the rifle in hand is the FULLEST in the pack ─────────────────
local function pack()
  local C = ref("crew")
  local id = C and C.activeId and C.activeId()
  return id and ("crew:" .. id) or "astro", id
end
local function cells(cid)
  local inv = ref("inventory")
  if not (inv and inv.fills) then return {} end
  return inv.fills(cid, "surveyor")
end
local function cell_now()
  local list = cells((pack()))
  local best = nil
  for _, f in ipairs(list) do if not best or f > best then best = f end end
  return best
end
-- Draw from the fullest rifle (the one in hand).
local function cell_draw(amount)
  local inv = ref("inventory")
  local cid = pack()
  if not (inv and inv.fills and save) then return 0 end
  local list = inv.fills(cid, "surveyor")
  if #list == 0 then return 0 end
  local bi = 1
  for i, f in ipairs(list) do if f > list[bi] then bi = i end end
  local got = math.min(list[bi], amount)
  list[bi] = list[bi] - got
  local t = save.get("inv.fill." .. cid)
  t = type(t) == "table" and t or {}
  t.surveyor = list
  save.set("inv.fill." .. cid, t)
  return got
end
-- Recharge every rifle in a pack by `amount` (capped) → added.
function recharge(cid, amount)
  local inv = ref("inventory")
  local I = ref("items")
  if not (inv and inv.fills and save) then return 0 end
  local cap = (I and I.fillCap and I.fillCap("surveyor")) or 100
  local list = inv.fills(cid, "surveyor")
  local add = 0
  for i = 1, #list do
    local a = math.min(cap - list[i], amount)
    if a > 0 then list[i] = list[i] + a; add = add + a end
  end
  if add > 0 then
    local t = save.get("inv.fill." .. cid)
    t = type(t) == "table" and t or {}
    t.surveyor = list
    save.set("inv.fill." .. cid, t)
  end
  return add
end

-- Is the active member somewhere that charges a cell (aboard, or home)?
local function charging_spot()
  local C = ref("crew")
  if C and C.avatarCraft and C.avatarCraft() then return "aboard" end
  local a = astro()
  local fo = ref("flight_ops")
  if a and fo and fo.crewHome then
    local ok, hx, hy, hz = pcall(fo.crewHome)
    if ok and hx and len(a.x - hx, a.y - hy, a.z - hz) < P("home_r") then return "base" end
  end
  return nil
end

-- ── where it may not be fired ──────────────────────────────────────────────
-- Under a roof that is a NODE (a building, a hangar, a craft's cabin roof
-- over an EVA) — rock overhead (a tunnel the laser bored, an overhang) is
-- fine. One ray up, at most four times a second.
local vessel_of            -- (below, with the crew targets)
local roof = { t = -10, why = nil }
local function roof_check(a)
  if now() - roof.t < 0.25 then return roof.why end
  roof.t = now()
  roof.why = nil
  local ux, uy, uz = a.up_x or 0, a.up_y or 1, a.up_z or 0
  local ok, h = pcall(raycast, a.x + ux * 1.2, a.y + uy * 1.2, a.z + uz * 1.2, ux, uy, uz, 30, a)
  if ok and h and h.node and h.node.valid ~= false and not is_ground(h.node) and not vessel_of(h.node) then
    roof.why = "indoors — not under a roof"
  end
  return roof.why
end

-- ── the crew as targets: capsules ──────────────────────────────────────────
-- Standing: soles `FOOT` under the body's centre, `TALL` up from the soles;
-- seated: from the seat up. Radii a suit's.
local FOOT, TALL, RAD = 0.98, 1.9, 0.30
local SEAT_H, SEAT_R = 1.15, 0.30
local tgt_cache = { t = -1, list = {} }
local function crew_targets()
  if tgt_cache.t == now() then return tgt_cache.list end
  local list = {}
  local C = ref("crew")
  if C and C.roster then
    local act = C.activeId and C.activeId()
    local ride = C.avatarCraft and C.avatarCraft()
    for _, r in ipairs(C.roster()) do
      local e = nil
      if r.status ~= "dead" and r.status ~= "base" then
        local node, seated, x, y, z, ux, uy, uz = nil, false, nil, nil, nil, nil, nil, nil
        if r.id == act and not ride then
          node = astro()
          if node then x, y, z = node.x, node.y, node.z end
        elseif r.status == "afoot" and r.id ~= act then
          node = C.bodyOf and C.bodyOf(r.id)
          if node and node.valid ~= false then x, y, z = node.x, node.y, node.z end
        elseif r.status == "aboard" or r.id == act then
          local p = C.dollPose and C.dollPose(r.id)
          if p and p.open then
            seated = true
            x, y, z, ux, uy, uz = p.x, p.y, p.z, p.ux, p.uy, p.uz
          end
        end
        if x then
          if not ux then ux, uy, uz = up_at(x, y, z) end
          local ax, ay, az, bx, by, bz, rr
          if seated then
            ax, ay, az = x - ux * 0.05, y - uy * 0.05, z - uz * 0.05
            bx, by, bz = x + ux * SEAT_H, y + uy * SEAT_H, z + uz * SEAT_H
            rr = SEAT_R
          else
            ax, ay, az = x - ux * (FOOT - RAD), y - uy * (FOOT - RAD), z - uz * (FOOT - RAD)
            local top = TALL - FOOT - RAD
            bx, by, bz = x + ux * top, y + uy * top, z + uz * top
            rr = RAD
          end
          e = { id = r.id, name = r.name, helmet = r.helmet ~= false, seated = seated, node = node,
                ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz, r = rr }
        end
      end
      if e then list[#list + 1] = e end
    end
  end
  tgt_cache.t, tgt_cache.list = now(), list
  return list
end

-- ── the ray ignore list: the crew's own colliders (their capsules are ours) ─
local function ignore_list(extra)
  local out = {}
  local a = astro()
  if a then out[#out + 1] = a end
  for _, t in ipairs(crew_targets()) do
    if t.node and t.node.valid ~= false and t.node ~= a then out[#out + 1] = t.node end
  end
  if extra and extra.valid ~= false then out[#out + 1] = extra end
  return out
end

-- Is a hit node the ground? A ray that meets a world's terrain answers
-- with the world's own node (named for the body: "Ryil").
function is_ground(n)
  if not (n and n.valid ~= false) then return true end
  local nm = n.name
  return nm ~= nil and space ~= nil and space.body ~= nil and space.body(nm) ~= nil
end

-- The vessel a hit node belongs to (its vessel_controller), if any: the hit
-- node or one of its parents is a craft's root. (Asking each node for the
-- script would warn once for every node that has none.)
vessel_of = function(n)
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

-- ── effects ────────────────────────────────────────────────────────────────
local marks = {}       -- { id, t }
local function mark(tex, x, y, z, nx, ny, nz, size, alpha, frame)
  if not (decals and decals.add) then return end
  local o = { texture = tex, pos = vec3(x, y, z), normal = vec3(nx, ny, nz), size = size,
              rotation = math.random() * 6.283, alpha = alpha }
  if frame then o.frame = frame end
  local ok, id = pcall(decals.add, o)
  if ok and id then
    marks[#marks + 1] = { id = id, t = now() }
    while #marks > 40 do pcall(decals.remove, marks[1].id); table.remove(marks, 1) end
  end
end
local function marks_tick()
  local life = P("mark_life")
  while marks[1] and now() - marks[1].t > life do
    pcall(decals.remove, marks[1].id)
    table.remove(marks, 1)
  end
end

local function emit(key, x, y, z, nx, ny, nz, intensity)
  local fx = ref("vfx")
  if fx and fx.emit then
    fx.emit(key, x, y, z, { normal = vec3(nx, ny, nz), intensity = intensity })
  elseif spawnEffect then
    pcall(spawnEffect, key, vec3(x, y, z), { normal = vec3(nx, ny, nz), intensity = intensity })
  end
end
local function light(x, y, z, i, rng, life)
  local fx = ref("vfx")
  if fx and fx.flash then pcall(fx.flash, x, y, z, 0.55, 0.8, 1.0, i, rng, life) end
end

-- The ground's bite: the flora wash lifted first (a dig re-lays every decal
-- whose 48 m chunk it touches: tool_belt's quiet_ground), then a 0.35 m ball.
local function crater(x, y, z, nx, ny, nz)
  local r = P("crater_r")
  if r <= 0 or not (terrain and terrain.dig) then return end
  local ff = ref("flora_field")
  if ff and ff.liftWash then pcall(ff.liftWash, x, y, z, 110.0, 8.0) end
  pcall(terrain.dig, x - nx * r * 0.4, y - ny * r * 0.4, z - nz * r * 0.4, r, 1.0)
end

-- ── the bolts ──────────────────────────────────────────────────────────────
local bolts = {}       -- { body, x,y,z (planet frame), dx,dy,dz, flown, charge, by, shooter, t0, fx }
local pool = {}        -- FxPlasmaBolt nodes: node | "spawning"
local POOL_N = 4

local function pool_node(i)
  local n = pool[i]
  if n == "spawning" then return nil end
  if n and n.valid then return n end
  if not spawn then return nil end
  pool[i] = "spawning"
  local a = astro()
  spawn("FxPlasmaBolt", a and vec3(a.x, a.y, a.z) or vec3(0, 0, 0), function(m) pool[i] = m end)
  return nil
end

function bolts_() return bolts end
function boltsInFlight() return #bolts end

-- Fire a bolt from a WORLD point along a unit direction. opts: charge (1),
-- by (a name), shooter (a member id whose capsule it never hits), speed
-- (m/s; a slower bolt for something weaker than the rifle, or a picture).
function fireFrom(ox, oy, oz, dx, dy, dz, opts)
  opts = opts or {}
  local l = len(dx, dy, dz)
  if l < 1e-6 then return nil end
  dx, dy, dz = dx / l, dy / l, dz / l
  local name, bx, by, bz = to_body(ox, oy, oz)
  if not name then return nil end
  local b = { body = name, x = bx, y = by, z = bz, ox = bx, oy = by, oz = bz, dx = dx, dy = dy, dz = dz, flown = 0,
              charge = opts.charge or 1.0, by = opts.by, shooter = opts.shooter, t0 = now(), speed = opts.speed }
  bolts[#bolts + 1] = b
  -- the muzzle: blast, light, the crack
  emit("PlasmaMuzzle", ox, oy, oz, dx, dy, dz, 0.6 + 0.6 * b.charge)
  light(ox + dx * 0.4, oy + dy * 0.4, oz + dz * 0.4, 6 + 10 * b.charge, 8, 0.12)
  play(SND.fire, ox, oy, oz, { track = "SFX", volume = 0.55 + 0.45 * b.charge, pitch = 1.08 - 0.12 * b.charge,
    mode = "Spatial", falloff = "Inverse", minDistance = 6, maxDistance = 900 })
  stats.shots = stats.shots + 1
  return b
end

-- What a bolt hits: crew, a part, the ground, a thing.
local function apply_hit(b, kind, h, d)
  local t0 = clock()
  local x, y, z = h.x, h.y, h.z
  local nx, ny, nz = h.nx or -b.dx, h.ny or -b.dy, h.nz or -b.dz
  local rec = { t = now(), kind = kind, d = d, x = x, y = y, z = z, charge = b.charge,
                node = h.node and h.node.valid ~= false and h.node.name or nil }
  local fxk = 1.0
  if kind == "crew" then
    local C = ref("crew")
    local zone = zoneAt(h.s, h.seated)
    local dmg = crewDamage(b.charge, d, zone, h.helmet)
    local detail = string.format("by %s, %.0f m", b.by or "an unknown shooter", d)
    local hp, why = nil, nil
    if C and C.hurt then hp, why = C.hurt(h.id, dmg, "shot", detail, { by = b.by, x = x, y = y, z = z }) end
    rec.id, rec.zone, rec.dmg, rec.hp, rec.why, rec.name = h.id, zone, dmg, hp, why, h.name
    stats.crew_hits = stats.crew_hits + 1
    fxk = 0.7
    play("audio/sfx/crew_hit.ogg", x, y, z, { track = "SFX", volume = 0.8, mode = "Spatial", minDistance = 3,
      maxDistance = 120 })
  elseif kind == "part" then
    local v, uid = h.v, h.uid
    local dmg = partDamage(b.charge, d)
    local before = v.partHp and v.partHp(uid)
    local after = nil
    if before then
      if v.hitPart then
        local ok, r = pcall(v.hitPart, uid, dmg, x, y, z)
        after = ok and r or nil
      elseif v.wearPart then
        local ok, r = pcall(v.wearPart, uid, before - dmg)
        after = ok and r or nil
      end
    end
    rec.v, rec.uid, rec.dmg, rec.hp0, rec.hp = v.craftName, uid, dmg, before, after
    stats.part_hits = stats.part_hits + 1
    mark("textures/vfx/decal/scorch_b.png", x, y, z, nx, ny, nz, 0.55 + 0.35 * b.charge, 0.9, v.node)
  elseif kind == "ground" then
    crater(x, y, z, nx, ny, nz)
    mark("textures/vfx/decal/scorch.png", x, y, z, nx, ny, nz, 1.0 + 0.6 * b.charge, 0.85)
    stats.ground_hits = stats.ground_hits + 1
  else
    mark("textures/vfx/decal/scorch_b.png", x, y, z, nx, ny, nz, 0.5 + 0.3 * b.charge, 0.85)
  end
  emit("PlasmaHit", x + nx * 0.05, y + ny * 0.05, z + nz * 0.05, nx, ny, nz, fxk * (0.6 + 0.6 * b.charge))
  light(x + nx * 0.5, y + ny * 0.5, z + nz * 0.5, 8 + 14 * b.charge, 12, 0.35)
  play(SND.hit, x, y, z, { track = "SFX", volume = 0.5 + 0.5 * b.charge, mode = "Spatial", minDistance = 5,
    maxDistance = 600 })
  stats.hits = stats.hits + 1
  rec.ms = (clock() - t0) * 1000
  stats.hit_ms = rec.ms
  lastHit = rec
  if log then
    log(string.format("surveyor: hit %s%s%s at %.0f m (charge %.2f)%s%s", kind, rec.node and (" [" .. rec.node .. "]") or "",
      rec.id and (" #" .. rec.id .. " " .. tostring(rec.zone)) or (rec.uid and (" part " .. rec.uid) or ""), d, b.charge,
      rec.dmg and string.format(", -%.2f", rec.dmg) or "", rec.hp and string.format(" → hp %.2f", rec.hp) or ""))
  end
end

-- One frame of one bolt: the step's segment against the colliders and the
-- crew capsules; the nearest wins. → true when it is done.
local function step_bolt(b, dt)
  local ox, oy, oz = to_world(b.body, b.x, b.y, b.z)
  if not ox then return true end
  local step = math.min((b.speed or P("speed")) * dt, P("range") - b.flown)
  if step <= 0 then return true end
  local best, bk, bh = step, nil, nil
  local ok, h = pcall(raycast, ox, oy, oz, b.dx, b.dy, b.dz, step, { ignore = ignore_list() })
  if ok and h and (h.distance or step) <= best then
    best = h.distance or step
    local v = h.node and vessel_of(h.node)
    local uid = v and v.uidOfNode and v.uidOfNode(h.node)
    if v and uid then bk, bh = "part", h; h.v, h.uid = v, uid
    elseif not h.node or is_ground(h.node) then bk, bh = "ground", h
    else bk, bh = "thing", h end
  end
  for _, t in ipairs(crew_targets()) do
    if t.id ~= b.shooter then
      local tt, s = rayCapsule(ox, oy, oz, b.dx, b.dy, b.dz, t.ax, t.ay, t.az, t.bx, t.by, t.bz, t.r)
      if tt and tt <= best then
        best, bk = tt, "crew"
        local hx, hy, hz = ox + b.dx * tt, oy + b.dy * tt, oz + b.dz * tt
        -- the normal: off the capsule's axis toward where it went in
        local cx, cy, cz = t.bx - t.ax, t.by - t.ay, t.bz - t.az
        local cl2 = cx * cx + cy * cy + cz * cz
        local k = cl2 > 0 and clamp(((hx - t.ax) * cx + (hy - t.ay) * cy + (hz - t.az) * cz) / cl2, 0, 1) or 0
        local nx, ny, nz = hx - (t.ax + cx * k), hy - (t.ay + cy * k), hz - (t.az + cz * k)
        local nl = len(nx, ny, nz)
        if nl > 1e-6 then nx, ny, nz = nx / nl, ny / nl, nz / nl else nx, ny, nz = -b.dx, -b.dy, -b.dz end
        bh = { x = hx, y = hy, z = hz, nx = nx, ny = ny, nz = nz, id = t.id, name = t.name, s = s,
               seated = t.seated, helmet = t.helmet }
      end
    end
  end
  if bk then
    apply_hit(b, bk, bh, b.flown + best)
    return true
  end
  b.x, b.y, b.z = b.x + b.dx * step, b.y + b.dy * step, b.z + b.dz * step
  b.flown = b.flown + step
  if b.flown >= P("range") - 1e-3 then
    -- spent: it fizzles out in the air
    local wx, wy, wz = to_world(b.body, b.x, b.y, b.z)
    if wx then emit("PlasmaMuzzle", wx, wy, wz, b.dx, b.dy, b.dz, 0.25) end
    return true
  end
  return false
end

-- ── the trigger, the scope, the cell: tool_belt calls this while it's held ─
local trig = { held = false, t0 = 0, snd = nil, ready_snd = nil, need_up = false }
local gated_t = -10        -- the last frame the rifle was in hand (update)
local vent_until = -10
local aim_cache = { t = -10 }

local function stop_snd(h) if h then pcall(function() h:stop() end) end end
local function charge_reset()
  charge, ready = 0.0, false
  trig.held = false
  stop_snd(trig.snd); trig.snd = nil
  stop_snd(trig.ready_snd); trig.ready_snd = nil
end

-- The aim point along the camera ray (world), from the PLAYER's range.
local function aim_point(api, node)
  local ox, oy, oz, dx, dy, dz = api.aim()
  if not ox then return nil end
  local ok, h = pcall(raycast, ox, oy, oz, dx, dy, dz, P("range") + 60, { ignore = ignore_list() })
  local px, py, pz, d
  if ok and h then px, py, pz = h.x, h.y, h.z else px, py, pz = ox + dx * P("range"), oy + dy * P("range"), oz + dz * P("range") end
  -- a crew capsule along the line is the aim too
  local best = (ok and h and h.distance) or P("range")
  for _, t in ipairs(crew_targets()) do
    if t.node ~= node then
      local tt = rayCapsule(ox, oy, oz, dx, dy, dz, t.ax, t.ay, t.az, t.bx, t.by, t.bz, t.r)
      if tt and tt < best then best = tt; px, py, pz = ox + dx * tt, oy + dy * tt, oz + dz * tt end
    end
  end
  d = len(px - node.x, py - node.y, pz - node.z)
  return px, py, pz, d, ox, oy, oz, dx, dy, dz
end

local function fire(node, api)
  local t0 = clock()
  local c = charge
  local cl = cell_now() or 0
  if not canFire(cl, c) then return false end
  local px, py, pz, d, ox, oy, oz, dx, dy, dz = aim_point(api, node)
  if not px then return false end
  local mx, my, mz = api.muzzle()
  if scopeK > 0.5 and api.fp() then
    -- through the scope the barrel is just under the eye
    local a = astro()
    local ux, uy, uz = (a and a.up_x) or 0, (a and a.up_y) or 1, (a and a.up_z) or 0
    mx, my, mz = ox + dx * 0.5 - ux * 0.06, oy + dy * 0.5 - uy * 0.06, oz + dz * 0.5 - uz * 0.06
  end
  if not mx then mx, my, mz = ox + dx * 0.8, oy + dy * 0.8, oz + dz * 0.8 end
  local fx, fy, fz = px - mx, py - my, pz - mz
  local fl = len(fx, fy, fz)
  if fl < 1.5 then fx, fy, fz = dx, dy, dz end
  local C = ref("crew")
  local me = C and C.activeId and C.activeId()
  local rec = me and C.get and C.get(me)
  local cost = shotCost(c)
  cell_draw(cost)
  fireFrom(mx, my, mz, fx, fy, fz, { charge = c, by = rec and rec.name or "the crew", shooter = me })
  api.kick(0.03 + 0.05 * c)
  heat = math.min(1, heat + 0.25 + 0.2 * c)
  flash = 1.0
  vent_until = now() + P("vent_secs")
  local ms = (clock() - t0) * 1000
  stats.fire_ms = ms
  lastShot = { t = now(), charge = c, cost = cost, cell = (cell_now() or 0), x = mx, y = my, z = mz,
               dx = fx, dy = fy, dz = fz, d = d, by = rec and rec.name, ms = ms }
  return true
end

-- tool_belt, every frame the rifle is in hand and the hands are free:
--   lmb, rmb  the buttons (tool_belt's sim already applied)
--   api       { aim() → ox,oy,oz,dx,dy,dz, muzzle() → x,y,z, fp() → bool,
--               kick(k), say(text) }
-- → busy (the walker faces the aim, the hold comes up), reticle kind, label,
--   and the aim point (world).
function tick(node, dt, lmb, rmb, api)
  if sim then
    if sim.lmb ~= nil then lmb = sim.lmb end
    if sim.rmb ~= nil then rmb = sim.rmb end
  end
  cell = cell_now()
  blocked = roof_check(node)
  -- the scope: eased in and out
  local want = rmb and not blocked
  if want ~= scoped then
    scoped = want
    play(SND.scope, { track = "UI", volume = 0.3, pitch = want and 1.2 or 0.9 })
  end
  scopeK = scopeK + ((scoped and 1 or 0) - scopeK) * (1 - math.exp(-14 * dt))
  -- the vent after a shot
  venting = math.max(0, vent_until - now())
  if venting > 0 and venting - dt <= 0 then play(SND.vent, { track = "SFX", volume = 0.3 }) end
  -- the trigger
  if not lmb then trig.need_up = false end
  if blocked then
    if trig.held then charge_reset() end
  elseif lmb and not trig.need_up and venting <= 0 then
    if not trig.held then
      trig.held, trig.t0 = true, now()
      if (cell or 0) >= shotCost(P("min_charge")) then
        trig.snd = play(SND.charge, { track = "SFX", volume = 0.5 })
      end
    end
    if (cell or 0) >= shotCost(P("min_charge")) then
      charge = chargeAt(now() - trig.t0)
    else
      charge = 0
    end
    ready = charge >= P("min_charge")
    if charge >= 0.999 and not trig.ready_snd and trig.snd then
      trig.ready_snd = play(SND.ready, { track = "SFX", volume = 0.35, loop = true })
    end
  elseif trig.held then
    -- let go: fire; a flat cell clicks dry; a tap under the minimum does nothing
    if (cell or 0) + 1e-6 < shotCost(P("min_charge")) then
      play(SND.dry, { track = "UI", volume = 0.4 })
      if api.say then api.say("TL-5: the cell is flat — it recharges aboard a craft and at the base") end
    elseif charge >= P("min_charge") then
      fire(node, api)
    end
    charge_reset()
  end
  heat = math.max(0, heat - dt * 0.35)
  -- the aim (a few times a second is plenty for the readout and the hold)
  local px, py, pz, d = nil, nil, nil, nil
  if now() - aim_cache.t > 0.08 then
    aim_cache.t = now()
    local x, y, z, dd = aim_point(api, node)
    aim_cache.p = x and { to_body(x, y, z) } or nil
    aim_cache.d = dd
  end
  if aim_cache.p and aim_cache.p[1] then px, py, pz = to_world(aim_cache.p[1], aim_cache.p[2], aim_cache.p[3], aim_cache.p[4]) end
  d = aim_cache.d
  aimDist = d
  local busy = trig.held or scoped or (now() - (lastShot and lastShot.t or -10) < 0.6)
  local label = ""
  if blocked then label = "TL-5 · " .. blocked
  elseif cell and cell < shotCost(P("min_charge")) then label = "TL-5 · CELL FLAT"
  elseif d then label = string.format("%.0f m", d) end
  return busy, blocked and "full" or "rifle", label, px, py, pz
end

-- Is the right button the scope's right now (the rifle in hand)? The
-- context menu asks, so a scope press is never a menu tap.
function ownsRmb() return now() - gated_t < 0.2 end

-- Hands away, aboard, a panel: whatever was charging stops.
function stow()
  if trig.held then charge_reset() end
  scoped, ready = false, false
  trig.need_up = true
end

-- ── the reticle and the scope picture (tool_belt's reticle hook) ───────────
local COL = { ink = { 0.92, 0.89, 0.81 }, cyan = { 0.55, 0.85, 1.0 }, hot = { 0.9, 0.97, 1.0 },
              warn = { 1.0, 0.80, 0.28 }, danger = { 0.97, 0.34, 0.25 }, muted = { 0.56, 0.55, 0.50 } }
local function bar(x, y, w, h, c, a)
  draw.rect(x - 1, y - 1, w + 2, h + 2, 0, 0, 0, a * 0.45)
  draw.rect(x, y, w, h, c[1], c[2], c[3], a)
end

function drawReticle(ax, ay, k, fp)
  if not (draw and draw.rect and draw.circle) then return end
  local c = COL.ink
  if blocked or (cell and cell < shotCost(P("min_charge"))) then c = COL.warn end
  if ready then c = charge >= 0.999 and COL.hot or COL.cyan end
  if venting > 0 then c = COL.muted end
  local a = 0.9
  local sw, sh = 1280, 720
  if camera and camera.screenSize then
    local ok, w, h = pcall(camera.screenSize)
    if ok and w then sw, sh = w, h end
  end
  -- THE SCOPE (first person, aimed in): the scope's round field, black past
  -- it; a fine crosshair with mil ticks; the range and the charge round it
  if fp and scopeK > 0.6 then
    local R = math.min(sw, sh) * 0.46
    -- black past the field: four slabs outside its square, and rings over
    -- the square's corners (a ring is drawn `px` thick about its radius)
    draw.rect(0, 0, sw, math.max(0, ay - R), 0, 0, 0, 1)
    draw.rect(0, ay + R, sw, math.max(0, sh - ay - R), 0, 0, 0, 1)
    draw.rect(0, ay - R, math.max(0, ax - R), 2 * R, 0, 0, 0, 1)
    draw.rect(ax + R, ay - R, math.max(0, sw - ax - R), 2 * R, 0, 0, 0, 1)
    local step = 14 * k
    local rr = R + step * 0.5
    while rr < R * 1.43 + step do
      draw.circleOutline(ax, ay, rr, 0.0, 0.0, 0.0, 1.0, step + 2)
      rr = rr + step
    end
    draw.circleOutline(ax, ay, R, 0.05, 0.06, 0.07, 1.0, 6 * k)
    draw.circleOutline(ax, ay, R * 0.985, 0.0, 0.0, 0.0, 0.35, 10 * k)
    local t = 1.2 * k
    bar(ax - R, ay - t / 2, R - 14 * k, t, { 0.05, 0.05, 0.05 }, 0.9)
    bar(ax + 14 * k, ay - t / 2, R - 14 * k, t, { 0.05, 0.05, 0.05 }, 0.9)
    bar(ax - t / 2, ay + 14 * k, t, R - 14 * k, { 0.05, 0.05, 0.05 }, 0.9)
    bar(ax - t / 2, ay - R, t, R - 14 * k, { 0.05, 0.05, 0.05 }, 0.9)
    for i = 1, 6 do
      local o = i * R / 7
      bar(ax - t, ay + o, t * 2, t, { 0.05, 0.05, 0.05 }, 0.9)
      bar(ax - 4 * k, ay + o - t / 2, 8 * k, t, { 0.05, 0.05, 0.05 }, 0.9)
      bar(ax + o, ay - 3 * k, t, 6 * k, { 0.05, 0.05, 0.05 }, 0.9)
      bar(ax - o, ay - 3 * k, t, 6 * k, { 0.05, 0.05, 0.05 }, 0.9)
    end
    draw.circle(ax, ay, 1.6 * k, c[1], c[2], c[3], 1.0)
    -- the charge, a lit arc low on the field's edge
    local n = 40
    for i = 0, n - 1 do
      local ang = math.pi * (0.28 + 0.44 * i / (n - 1))
      local px, py = ax + math.cos(ang) * (R - 22 * k), ay + math.sin(ang) * (R - 22 * k)
      if i / n < charge then draw.circle(px, py, 2.2 * k, c[1], c[2], c[3], 0.95)
      else draw.circle(px, py, 1.2 * k, 0.5, 0.55, 0.6, 0.5) end
    end
    if draw.text then
      local txt = aimDist and string.format("RNG %4.0f m", aimDist) or "RNG  ---"
      draw.text(ax + R * 0.42, ay + R * 0.55, txt, 14 * k, 0.55, 0.85, 1.0, 0.9, "left")
      draw.text(ax + R * 0.42, ay + R * 0.55 + 18 * k, string.format("CELL %3.0f%%", cell or 0), 14 * k,
        (cell or 0) < 20 and COL.warn[1] or 0.55, (cell or 0) < 20 and COL.warn[2] or 0.85,
        (cell or 0) < 20 and COL.warn[3] or 1.0, 0.9, "left")
      draw.text(ax - R * 0.42, ay + R * 0.55, string.format("%.0f×", P("zoom_fp")), 14 * k, 0.55, 0.85, 1.0, 0.7, "right")
    end
    return
  end
  -- THE RETICLE: four ticks round a gap (a bolt goes where the gap is), the
  -- dot, the charge as a ring of pips closing round it, the cell under it
  local g, l, t = 6 * k, 9 * k, 1.6 * k
  local spread = (1 - math.min(1, charge)) * 4 * k + (venting > 0 and 3 * k or 0)
  g = g + spread
  bar(ax - t / 2, ay - g - l, t, l, c, a); bar(ax - t / 2, ay + g, t, l, c, a)
  bar(ax - g - l, ay - t / 2, l, t, c, a); bar(ax + g, ay - t / 2, l, t, c, a)
  draw.circle(ax, ay, 1.4 * k, c[1], c[2], c[3], a)
  if charge > 0.01 then
    local n = 24
    local lit = math.floor(charge * n + 0.5)
    for i = 0, n - 1 do
      local ang = -math.pi / 2 + i / n * 2 * math.pi
      local px, py = ax + math.cos(ang) * 24 * k, ay + math.sin(ang) * 24 * k
      if i < lit then draw.circle(px, py, 1.7 * k, c[1], c[2], c[3], 0.95)
      else draw.circle(px, py, 1.0 * k, c[1], c[2], c[3], 0.3) end
    end
  end
  -- the cell: a short bar under the reticle, its ticks the full shots left
  local cw = 64 * k
  local fr = math.max(0, math.min(1, (cell or 0) / 100))
  local cc = fr < 0.2 and COL.warn or COL.cyan
  bar(ax - cw / 2, ay + 36 * k, cw, 3 * k, { 0.1, 0.12, 0.14 }, 0.7)
  draw.rect(ax - cw / 2, ay + 36 * k, cw * fr, 3 * k, cc[1], cc[2], cc[3], 0.9)
end

-- ── the frame ──────────────────────────────────────────────────────────────
-- The scope's lens: the main camera's field of view and the look's speed,
-- written only while it changes, put back the moment it is not wanted.
local lens = { applied = nil, fov0 = nil, sens0 = nil }
local function lens_tick(fp, active)
  local pc = ref("planet_camera")
  local cn = pc and pc.node
  if not (pc and cn and cn.valid ~= false) then return end
  local base = (pc.params and pc.params.fov_y) or 1.1519173
  local k = active and scopeK or 0
  local zoom = 1 + ((fp and P("zoom_fp") or P("zoom_tp")) - 1) * k
  local fov = 2 * math.atan(math.tan(base * 0.5) / zoom)
  if k < 0.01 then
    if lens.applied then
      pcall(function() cn:setCamera { fovY = base } end)
      if lens.sens0 and pc.params then pc.params.sensitivity = lens.sens0 end
      lens.applied, lens.sens0 = nil, nil
    end
    return
  end
  if not lens.applied or math.abs(lens.applied - fov) > 1e-3 then
    pcall(function() cn:setCamera { fovY = fov } end)
    if pc.params then
      if not lens.sens0 then lens.sens0 = pc.params.sensitivity end
      pc.params.sensitivity = lens.sens0 / zoom
    end
    lens.applied = fov
  end
end

local recharge_t = 0
function update(node, dt)
  local t0 = clock()
  -- bolts fly whatever is in anyone's hand
  local i = 1
  while i <= #bolts do
    if step_bolt(bolts[i], dt) then table.remove(bolts, i) else i = i + 1 end
  end
  stats.step_ms = (clock() - t0) * 1000
  marks_tick()
  flash = flash * math.exp(-6 * dt)
  -- the cells: recharge aboard or at the base, twice a second
  recharge_t = recharge_t + dt
  if recharge_t >= 0.5 then
    local spot = charging_spot()
    if spot then recharge((pack()), P("recharge") * recharge_t) end
    recharge_t = 0
  end
  -- not in hand this frame (tool_belt stopped calling tick): let go of it all
  local tb = ref("tool_belt")
  local held = tb and tb.toolId and tb.toolId() == "surveyor" and tb.gate == "in hand"
  if not held then
    if trig.held or scoped then stow() end
    scopeK = scopeK * math.exp(-14 * dt)
    if scopeK < 0.01 then scopeK = 0 end
  else
    gated_t = now()
  end
end

function lateUpdate(node, dt)
  -- the lens (first person or the shoulder)
  local tb = ref("tool_belt")
  local fp = tb and tb.firstPersonNow and tb.firstPersonNow() or false
  lens_tick(fp, now() - gated_t < 0.2)
  -- the bolts in flight on the pooled nodes, from their planet frame now
  for k = 1, POOL_N do
    local b = bolts[k]
    local n = pool_node(k)
    if n then
      local ps = n.particles and n:particles()
      local L = n.getcomponent and n:getcomponent("PointLight")
      if b then
        local hx, hy, hz = to_world(b.body, b.x, b.y, b.z)
        if hx then
          n.x, n.y, n.z = hx, hy, hz
          local tl = math.min(P("streak"), b.flown + 0.3)
          if ps then
            if not ps:isPlaying() then ps:play() end
            if ps.setIntensity then ps:setIntensity(0.6 + 0.6 * b.charge) end
            if ps.setBeamEnd then ps:setBeamEnd(hx - b.dx * tl, hy - b.dy * tl, hz - b.dz * tl) end
          end
          if L then L.intensity = 4 + 6 * b.charge end
        end
      else
        if ps and ps:isPlaying() then ps:stop() end
        if L and L.intensity ~= 0 then L.intensity = 0 end
      end
    end
  end
end

function start(node)
  bolts, marks = {}, {}
end

function _debug() return { bolts = bolts, pool = pool, marks = marks, targets = crew_targets(), lens = lens } end
