-- CRAFT_STAND — the Build Stand and the craft built on it (deep-space addendum
-- L1, L2, L4; docs/base-building.md §9).
--
-- THE STAND (L1) is a BASE part (parts_base `stand`): a 0.9 m base plate with
-- a telescoping column and a 0.9 m deck. It is placed with the Build Kit like
-- any BASE part, so snapping (on the ground, or on a Pad Plate's deck), the
-- footing, the undo ring and Deconstruct come with it. Its deck height is the
-- part's own bp field `h` (0.5–4.0 m, a slider on its context menu); `lo`
-- true means it is lowered (STAND.low) after letting a wheeled craft down.
-- The deck is the prefab's "Deck" child (and its "Deck Wall" colliders),
-- placed along the stand's up when its node lands (`spawned`).
--
-- A CRAFT ON THE STAND (L2) is a blueprint in the launch format the VAB
-- writes (builder make_blueprint: the library's files, `shipyard.blueprint`),
-- kept under its own save key STAND_KEY(sid, uid) — the save holds four
-- tables deep, and a structure record is already three — with the stand's
-- part state (structures.partState) saying what it is:
--
--   nil                    the stand is empty
--   { s = "built", … }     on the stand, not commissioned: the parts are drawn
--                          as display copies (spawn body = false, the VAB's
--                          prefabs/vis/ variants where there are some) under
--                          one node parented to the planet. No body, no
--                          script: an idle craft on a stand costs nothing a
--                          tick.
--   { s = "held", … }      COMMISSIONED: a live Vessel (the fleet's own
--                          rebuild path: a Vessel root, the blueprint handed
--                          over as `dock.handoff.<id>`, the parts as its
--                          children, assembly.rebuild), anchored on the deck.
--                          The handoff's `held` keeps it off the fleet board
--                          (vessel_controller leftPad = false) until it is
--                          released: the stand rebuilds it on a reload.
--   fields: s, key, name, n (parts), cost, ship, total, t (agency clock when
--           paid), by, ret (it came back to the stand: `cost` is what
--           recovering it was worth), wheeled
--
-- WHERE IT GOES. The craft's centre of mass (its parts' masses, x and z) is
-- over the deck's centre, its front (the spawner's craft_front rule: a
-- cockpit's nose, a rover body's front, a seat, the command part) along the
-- stand's front, and its BELLY — the lowest part over the deck — a hair over
-- the deck's pads. Whatever hangs lower (wheels, gear, legs) must clear the
-- ground by WHEEL_CLEAR: the stand raises itself to `need` when a craft goes
-- on, and refuses a craft that would need more than its 4 m.
--
-- COMMISSION / RELEASE / RETURN (L4), all on the stand's context menu (and the
-- craft's, for Return):
--   Put a craft on it   a library craft, bought at the VAB's price plus
--                       shipping (N1: one truck, 10 % + $50), charged now.
--   Clear the stand     the parts go back: everything within a minute, the
--                       price after (base_economy.deconstructRefund).
--   Commission          (Engineer, a job) the checks (something commands it,
--                       nothing in the way), then the live craft, held.
--   Release             a craft on wheels is JACKED DOWN: craft and deck go
--                       down together until its wheels touch, the stand
--                       drops to `low` (a new node: its colliders are made
--                       where they are), and the clamps let go. Anything else
--                       is let go where it stands (a rocket lifts off the
--                       deck; SPACE in the cockpit does the same, as on the
--                       pad: vessel_controller.releaseClamps).
--   Return to stand     (a landed, stopped, empty craft within RETURN_R of an
--                       empty stand) the craft is lifted back onto the stand
--                       as an uncommissioned craft, its fuel, charge and wear
--                       in its records. Clearing it then pays what recovering
--                       it would have.
--
-- THE HOOK FOR L3 (the detail editor at a stand, step 17): everything a
-- craft on a stand is lives in `blueprint(sid, uid)` / `putOn(sid, uid, bp,
-- opts)` and `framePose(sid, uid)` (the stand's deck as a body-frame pose).
-- build_host.enter{ frame = stand } edits that blueprint where it stands and
-- hands the result back through putOn{ diff = … }; bp.kind rides in the
-- blueprint untouched.
--
-- Frames: every point kept is body-relative or in the stand's frame
-- (docs/positions-and-frames.md rule 1). A held craft's pin is its origin
-- relative to its body, re-applied each frame while the crew is near.

defaults = {
  --@range 0 0.2 --@units m
  clear = 0.02,          -- the belly over the deck's pads
  --@range 0 0.5 --@units m
  wheel_clear = 0.10,    -- what hangs lowest over the ground, on the stand
  --@range 0.05 2 --@units m/s
  jack_rate = 0.35,      -- how fast a release lets a craft down
  --@range 1 10 --@units m
  return_r = 3.0,        -- Return to stand: a craft part this near the deck
  --@range 0 1
  sound = 1.0,
}

STATE_BUILT, STATE_HELD = "built", "held"
COMMISSION_SECS = { base = 4.0, per = 0.15, max = 20.0 }
RETURN_SECS = 4.0
PUT_SECS = { base = 3.0, per = 0.1, max = 12.0 }

-- Published (probes).
lastPut, lastClear, lastCommission, lastRelease, lastReturn = nil, nil, nil, nil, nil

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function V(x, y, z) return { x = x, y = y, z = z } end
local function cross(a, b) return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

function STAND_KEY(sid, uid) return "stand.bp." .. tostring(sid) .. "." .. tostring(uid) end
local function keyOf(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end

-- ═══ PURE: the craft's shape ════════════════════════════════════════════════

-- A part's local axes in the vessel frame (YXZ, as everywhere in Solar).
function axesOf(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  local X = V(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz)
  local Y = V(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz)
  return X, Y, cross(X, Y)
end

-- A part's box in the vessel frame: { x0, x1, y0, y1, z0, z1 }. `half` = its
-- collider's half-extents when known (a live RigidBody), else the
-- blueprint's rx, h/2, rz.
function partBox(d, half)
  local hx = math.max(0.05, (half and half.x) or d.rx or 0.5)
  local hy = math.max(0.05, (half and half.y) or (d.h or 1.0) * 0.5)
  local hz = math.max(0.05, (half and half.z) or d.rz or 0.5)
  local X, Y, Z = axesOf(d)
  local ex = math.abs(X.x) * hx + math.abs(Y.x) * hy + math.abs(Z.x) * hz
  local ey = math.abs(X.y) * hx + math.abs(Y.y) * hy + math.abs(Z.y) * hz
  local ez = math.abs(X.z) * hx + math.abs(Y.z) * hy + math.abs(Z.z) * hz
  local x, y, z = d.x or 0, d.y or 0, d.z or 0
  return { x0 = x - ex, x1 = x + ex, y0 = y - ey, y1 = y + ey, z0 = z - ez, z1 = z + ez }
end

-- The craft's bounds in its own frame and where it rests on a deck of
-- half-width `deckR` (the circle inside the square): → { lo, hi, x0, x1, z0,
-- z1, com = { x, z }, belly (the lowest part over the deck) | nil, n }.
-- `halves` = uid → { x, y, z } (live colliders) or nil.
function bounds(bp, deckR, halves)
  local parts = bp and bp.parts or {}
  local b = { lo = math.huge, hi = -math.huge, x0 = math.huge, x1 = -math.huge, z0 = math.huge, z1 = -math.huge, n = 0 }
  local m, mx, mz = 0, 0, 0
  local boxes = {}
  for _, d in pairs(parts) do
    local bx = partBox(d, halves and halves[d.uid])
    boxes[#boxes + 1] = bx
    b.lo, b.hi = math.min(b.lo, bx.y0), math.max(b.hi, bx.y1)
    b.x0, b.x1 = math.min(b.x0, bx.x0), math.max(b.x1, bx.x1)
    b.z0, b.z1 = math.min(b.z0, bx.z0), math.max(b.z1, bx.z1)
    local w = math.max(1e-3, d.mass or 0.01)
    m, mx, mz = m + w, mx + w * (d.x or 0), mz + w * (d.z or 0)
    b.n = b.n + 1
  end
  if b.n == 0 then return nil end
  b.com = { x = mx / m, z = mz / m }
  local r = deckR or 0.45
  for _, bx in ipairs(boxes) do
    -- the box's nearest point to the deck's centre (under the com), in x, z
    local qx = math.max(bx.x0, math.min(b.com.x, bx.x1)) - b.com.x
    local qz = math.max(bx.z0, math.min(b.com.z, bx.z1)) - b.com.z
    if qx * qx + qz * qz <= r * r and (not b.belly or bx.y0 < b.belly) then b.belly = bx.y0 end
  end
  return b
end

-- The deck height a craft with bounds `b` needs, so that what hangs below its
-- belly clears the ground by `wheelClear` (+ `rise`: the ground under the
-- craft standing higher than the stand's base). Rounded up to the stand's
-- step. → h, or nil, why
function needHeight(b, S, wheelClear, rise, clear)
  if not b then return nil, "there is nothing to put on the stand" end
  if not b.belly then return nil, "nothing of it rests on the deck: it needs a part over its centre of mass" end
  local need = (b.belly - b.lo) + (wheelClear or 0.10) + (rise or 0) - (clear or 0)
  local step = S.step or 0.1
  need = math.max(S.min, math.ceil(need / step - 1e-6) * step)
  if need > S.max + 1e-6 then
    return nil, string.format("it hangs %.1f m below its belly: more than the stand's %.1f m", b.belly - b.lo, S.max)
  end
  return need
end

-- Wheels or gear: a release lets it down onto them.
function wheeled(bp)
  for _, d in pairs(bp and bp.parts or {}) do
    if type(d.wheel) == "string" and d.wheel ~= "" then return true end
    if type(d.af) == "string" and (" " .. d.af .. " "):find(" gear") then return true end
  end
  return false
end

-- Can anything aboard command it? (vessel_controller r2PickCommand's kinds)
function commandWhy(bp)
  local parts = bp and bp.parts
  if type(parts) ~= "table" or next(parts) == nil then return "there is nothing on the stand" end
  for _, d in pairs(parts) do
    if d.kind == "crewed" or d.kind == "probe" then return nil end
  end
  return "nothing aboard can command it: it needs a pod, a seat or a probe core"
end

-- What the hull costs (the VAB's build_cost: the parts' prices).
function hullCost(bp)
  local c = 0
  for _, d in pairs(bp and bp.parts or {}) do c = c + (d.cost or 0) end
  return math.floor(c + 0.5)
end

-- The craft's front in its own frame, (fx, fz): the rule vessel_spawner's
-- craft_front drives by (a cockpit's +Y, a rover body's or a seat's +X, the
-- command part's +X, else +X).
function frontOf(parts)
  local function level(d, axis)
    local X, Y = axesOf(d)
    local A = axis == "y" and Y or X
    local l = math.sqrt(A.x * A.x + A.z * A.z)
    if l < 0.5 then return nil end
    return A.x / l, A.z / l
  end
  for _, d in pairs(parts or {}) do
    if type(d.af) == "string" and (" " .. d.af .. " "):find(" cockpit ") then
      local fx, fz = level(d, "y")
      if fx then return fx, fz end
    end
  end
  local best, bu = nil, nil
  for _, d in pairs(parts or {}) do
    if (d.front or 0) == 1 or (d.seat or 0) == 1 or d.seat == true then
      if not bu or (d.uid or 0) < bu then
        local fx, fz = level(d, "x")
        if fx then best, bu = { fx, fz }, d.uid or 0 end
      end
    end
  end
  if best then return best[1], best[2] end
  for _, d in pairs(parts or {}) do
    if d.kind == "crewed" or d.kind == "probe" then
      local fx, fz = level(d, "x")
      if fx then return fx, fz end
    end
  end
  return 1, 0
end

-- The vessel's axes (body-frame vectors) on a stand whose right, up and front
-- are R, U, F, so that a craft whose front is (fx, fz) in its own frame faces
-- F: X = R cos a − F sin a, Z = R sin a + F cos a, a = atan2(fz, fx) − 90°.
-- (Its +Y is U; X = U × Z, so node:setUp(U, −Z) turns a node onto it.)
function vesselAxes(R, U, F, fx, fz)
  local a = math.atan2(fz, fx) - math.pi / 2
  local c, s = math.cos(a), math.sin(a)
  local X = V(R.x * c - F.x * s, R.y * c - F.y * s, R.z * c - F.z * s)
  local Z = V(R.x * s + F.x * c, R.y * s + F.y * c, R.z * s + F.z * c)
  return X, V(U.x, U.y, U.z), Z
end

-- The vessel's origin (body frame) on a deck `h` over the stand's ground
-- point G: its centre of mass over the deck's centre, its belly `clear` over
-- the pads.
function vesselOrigin(G, X, U, Z, h, b, clear)
  local up = h + (clear or 0) - b.belly
  return V(G.x + U.x * up - X.x * b.com.x - Z.x * b.com.z,
           G.y + U.y * up - X.y * b.com.x - Z.y * b.com.z,
           G.z + U.z * up - X.z * b.com.x - Z.z * b.com.z)
end

-- The Deck child's local height over the stand's root origin, for a deck top
-- `h` over the ground point (the root's origin sits `seat` over it).
function deckY(def, h) return h - def.stand.deckOff - def.seat end

-- A deck height the stand can be set to.
function clampHeight(S, h)
  h = math.max(S.min, math.min(S.max, h or S.min))
  return math.floor(h / S.step + 0.5) * S.step
end

-- What a craft on the stand costs (N1 on the home world: the hull's price,
-- trucked out once at 10 % + $50). → { cost, ship, total }
function quote(bp, E)
  local cost = hullCost(bp)
  local ship = E and E.shipping and E.shipping(cost) or math.floor(cost * 0.1 + 50 + 0.5)
  return { cost = cost, ship = ship, total = cost + ship }
end

-- The JSON a library file holds, back into the tables it was written from
-- (builder.lua libDecode: tagged keys and numbers). Pure.
function decodeLib(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then
      local m, e = rest:match("^(-?%d+):(-?%d+)$")
      if m then return math.ldexp(tonumber(m), tonumber(e)) end
      return v
    end
    if tag == "f:" then return rest == "nan" and (0 / 0) or (rest == "-inf" and -math.huge or math.huge) end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" and k:sub(1, 1) == "\0" then
      local tag, rest = k:sub(2, 3), k:sub(4)
      if tag == "n:" then k = tonumber(rest)
      elseif tag == "b:" then k = rest == "true"
      elseif tag == "s:" then k = rest end
    end
    if k ~= nil then out[k] = decodeLib(x) end
  end
  return out
end

-- ═══ THE STORE ══════════════════════════════════════════════════════════════

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function say(s)
  if caption then pcall(caption, s) end
  if log then log("stand: " .. s) end
end
local SFX = { place = "audio/foley/clamp_clunk.ogg", denied = "audio/foley/buzz_denied.ogg", jack = "audio/foley/latch_clunk.ogg" }
local function play(k, vol)
  if ((params and params.sound) or 1) <= 0 or not (audio and audio.play) then return end
  pcall(audio.play, SFX[k], { track = "UI", volume = vol or 0.5 })
end
local function P(k) return (params and params[k]) or defaults[k] end
local function money(v) local E = ref("base_economy"); return E and E.money(v) or ("$" .. tostring(v)) end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save.get("agency.clock")) or 0
end
local function member() local c = ref("crew"); return c and c.activeId and c.activeId() or nil end
local function engineer()
  local fb = ref("field_builder")
  return fb and fb.isEngineer and fb.isEngineer() == true
end
local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end

local function defOf(p) local pb = ref("parts_base"); return pb and p and pb.partInfo(p.id) or nil end
local function standAt(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local p = rec and ST.getPart(sid, uid)
  local def = defOf(p)
  if not (def and def.stand) then return nil end
  return rec, p, def, ST
end
function stateOf(sid, uid) local ST = ref("structures"); return ST and ST.partState(sid, uid) or nil end
local function set_state(sid, uid, t) local ST = ref("structures"); return ST and ST.setPartState(sid, uid, t) end
function blueprint(sid, uid)
  local bp = save.get(STAND_KEY(sid, uid))
  return type(bp) == "table" and type(bp.parts) == "table" and bp or nil
end
local function forget_bp(sid, uid)
  local k = STAND_KEY(sid, uid)
  if save.delete then save.delete(k) else save.set(k, false) end
end
-- The deck's height now (the setting, or lowered).
function heightOf(p, def)
  local S = def.stand
  if p.lo then return S.low end
  return clampHeight(S, p.h or (def.fields and def.fields.h) or S.min)
end

-- The stand's pose (body frame): its ground point G and axes R, U, F, and the
-- deck's top. → { body, G, R, U, F, h, top } | nil
function framePose(sid, uid)
  local rec, p, def, ST = standAt(sid, uid)
  if not rec then return nil end
  local gx, gy, gz, U, F = ST.partPose(rec, p, 0)
  local R = cross(U, F)
  local h = heightOf(p, def)
  local G = V(gx, gy, gz)
  return { body = rec.b, G = G, R = R, U = U, F = F, h = h, top = V(gx + U.x * h, gy + U.y * h, gz + U.z * h), def = def }
end

-- Where a blueprint goes on stand (sid, uid) at deck height h. → pose
-- { X, U, Z, O (body frame), b (bounds) } | nil
function craftPose(sid, uid, bp, h, halves)
  local fp = framePose(sid, uid)
  if not fp then return nil end
  local b = bounds(bp, fp.def.stand.deck, halves)
  if not (b and b.belly) then return nil end
  local fx, fz = frontOf(bp.parts)
  local X, U, Z = vesselAxes(fp.R, fp.U, fp.F, fx, fz)
  local O = vesselOrigin(fp.G, X, U, Z, h or fp.h, b, P("clear"))
  return { X = X, U = U, Z = Z, O = O, b = b, fp = fp }
end

-- ═══ THE SCENE ══════════════════════════════════════════════════════════════

local standNode = {}     -- key → the stand's live node
local shown = {}         -- key → { node = container, making }
local J = {}             -- key → a live held craft: { sid, uid, node, relv, body, placed, phase, … }
local vis = nil          -- the prefabs/vis/ names (the VAB's display variants)

local function vis_prefab(prefab)
  if vis == nil then
    vis = {}
    if assets and assets.getContents then
      local ok, list = pcall(assets.getContents, "prefabs/vis")
      if ok and type(list) == "table" then
        for _, f in ipairs(list) do
          local name = tostring(f):match("([^/]+)%.prefab%.ron$")
          if name then vis[name] = true end
        end
      end
    end
  end
  return vis[prefab] and ("vis/" .. prefab) or prefab
end

local function valid(n) return n ~= nil and n.valid ~= false end
-- The stand's node and every node under it (rays and the overlap look past them).
local function stand_nodes(key)
  local out = {}
  local n = standNode[key]
  if not valid(n) then return out end
  local function walk(x, depth)
    out[#out + 1] = x
    if depth < 3 and x.children then
      local ok, kids = pcall(x.children, x)
      if ok and kids then for _, c in ipairs(kids) do walk(c, depth + 1) end end
    end
  end
  walk(n, 0)
  return out
end

-- Put the Deck child at height h (local to the stand's root).
local function pose_deck(key, def, h)
  local n = standNode[key]
  if not valid(n) then return end
  local d = n.getChild and n:getChild("Deck")
  if d then d.x, d.y, d.z = 0, deckY(def, h), 0 end
end

-- The display copy's look (S2): a cool blueprint blue with a blue rim.
DISPLAY_TINT = { color = { 0.36, 0.60, 1.0 }, rim = { 0.30, 0.62, 1.0 }, rimStrength = 1.3, emissive = { 0.06, 0.16, 0.42 }, emissiveStrength = 0.45 }
function tint_tree(n, depth)
  if not valid(n) then return end
  pcall(n.setTint, n, DISPLAY_TINT)
  if depth < 3 then
    local ok, kids = pcall(n.children, n)
    for _, k in ipairs(ok and kids or {}) do tint_tree(k, depth + 1) end
  end
end
-- F beside a craft that is only drawn: say why nothing happens (S2).
function displayHint()
  local a = find and find("Astronaut")
  if not valid(a) then return nil end
  for key, s in pairs(shown) do
    if s and valid(s.node) then
      local w = s.node.worldPos
      if math.sqrt((w.x - a.x) ^ 2 + (w.y - a.y) ^ 2 + (w.z - a.z) ^ 2) < 5.0 then
        local sid, uid = key:match("^(%d+):(%d+)$")
        local st = sid and stateOf(tonumber(sid), tonumber(uid))
        return string.format("%s is not commissioned yet: COMMISSION on the stand to use it", tostring(st and st.name or "This craft"))
      end
    end
  end
  return nil
end
lastHint = nil

local function drop_display(key)
  local s = shown[key]
  if s and valid(s.node) then pcall(s.node.destroy, s.node) end
  shown[key] = nil
end

-- The uncommissioned craft, drawn: one node on the planet at the vessel's
-- pose, the parts its children at their blueprint poses (no bodies).
local editing = nil      -- the stand the editor is open on (its key): no display copy there
local function show_display(sid, uid)
  local key = keyOf(sid, uid)
  if shown[key] or editing == key then return end
  local bp = blueprint(sid, uid)
  local cp = bp and craftPose(sid, uid, bp)
  local planet = cp and find and find(cp.fp.body)
  if not (cp and planet and createNode and spawn) then return end
  local s = { making = true }
  shown[key] = s
  createNode("StandCraft", planet, function(n)
    s.making = false
    if shown[key] ~= s then n:destroy() return end
    s.node = n
    n:setUp(vec3(cp.U.x, cp.U.y, cp.U.z), vec3(-cp.Z.x, -cp.Z.y, -cp.Z.z))
    n.x, n.y, n.z = cp.O.x, cp.O.y, cp.O.z
    local PR = ref("builder_proc")
    for _, d in pairs(bp.parts) do
      if d.prefab then
        local ok = pcall(spawn, vis_prefab(d.prefab), vec3(0, 0, 0), function(part)
          if shown[key] ~= s then part:destroy() return end
          part.x, part.y, part.z = d.x or 0, d.y or 0, d.z or 0
          part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
          if d.size and d.proc and PR and PR.dress then pcall(PR.dress, part, { def = d, size = d.size }) end
          -- (S2: blueprint blue, so it reads as not yet real: setTint keeps
          -- the part's textures and rides per instance, never splitting a batch)
          tint_tree(part, 0)
        end, { parent = n, body = false })
        if not ok and log then log("stand: could not draw " .. tostring(d.prefab)) end
      end
    end
  end)
end

-- The ground under a craft about to go on a stand: the highest point under
-- its footprint's corners and centre, along the stand's up from its ground
-- point (m; + = above). Looks past the stand. nil when no ray found ground.
-- A ray that passes through what it is told to (the stand, a craft, the
-- crew): `roots` is a root set (rootSet: node ids as keys, the nodes in
-- `.nodes`), and the engine skips each root's whole subtree
-- (ignoreChildren, card 0649: the stand's colliders are its children's and a
-- craft's are its parts'). A set without `.nodes` falls back to stepping past
-- hits under a root.
-- → the hit, with `distance` from the first origin, or nil
function rootSet(nodes)
  local s = { nodes = {} }
  for _, n in ipairs(nodes or {}) do
    if n and n.valid ~= false then
      local ok, id = pcall(function() return n.id end)
      if ok and id and not s[id] then s[id] = true; s.nodes[#s.nodes + 1] = n end
    end
  end
  return s
end
function rayPast(ox, oy, oz, dx, dy, dz, maxd, roots, ignore)
  if not raycast then return nil end
  local opts = ignore and { ignore = ignore } or nil
  if roots.nodes and #roots.nodes > 0 then
    local list = {}
    for _, n in ipairs(roots.nodes) do if n.valid ~= false then list[#list + 1] = n end end
    if ignore then list[#list + 1] = ignore end
    opts = { ignore = list, ignoreChildren = true }
  end
  local gone = 0
  for _ = 1, 8 do
    local ok, h = pcall(raycast, ox, oy, oz, dx, dy, dz, maxd - gone, opts)
    if not ok and not RAYPAST_ERR and log then RAYPAST_ERR = true; log("stand: raycast refused: " .. tostring(h)) end
    if not (ok and h and h.distance) then return nil end
    local n, mine = h.node, false
    for _ = 0, 4 do
      if not n then break end
      local okid, id = pcall(function() return n.id end)
      if okid and roots[id] then mine = true break end
      local okp, par = pcall(function() return n.parent end)
      n = okp and par or nil
    end
    if not mine then h.distance = h.distance + gone; return h end
    -- (a hit under a root the engine was told to skip: say so once, for the
    -- engine card, then step past it as before)
    if opts and opts.ignoreChildren and not RAYPAST_WARNED and log then
      RAYPAST_WARNED = true
      local okn, nm = pcall(function() return h.node.name end)
      log("stand: ignoreChildren let a ray stop on " .. tostring(okn and nm or "?") .. " under a skipped root")
    end
    local step = h.distance + 0.02
    gone = gone + step
    ox, oy, oz = ox + dx * step, oy + dy * step, oz + dz * step
    if gone >= maxd then return nil end
  end
  return nil
end
function standRoots(sid, uid, extra)
  local nodes = {}
  for _, n in ipairs(stand_nodes(keyOf(sid, uid))) do nodes[#nodes + 1] = n end
  for _, n in pairs(extra or {}) do nodes[#nodes + 1] = n end
  return rootSet(nodes)
end

local function ground_rise(sid, uid, cp, extra)
  if not (raycast and cp) then return 0 end
  local b = space.body(cp.fp.body)
  if not b then return 0 end
  local key = keyOf(sid, uid)
  local a = find and find("Astronaut")
  local roots = standRoots(sid, uid, { a, extra })
  local G, U = cp.fp.G, cp.U
  local top = cp.b.hi - cp.b.lo + 6
  local hi = nil
  for _, c in ipairs({ { cp.b.x0, cp.b.z0 }, { cp.b.x0, cp.b.z1 }, { cp.b.x1, cp.b.z0 }, { cp.b.x1, cp.b.z1 },
                       { cp.b.com.x, cp.b.com.z } }) do
    local px = cp.O.x + cp.X.x * c[1] + cp.Z.x * c[2]
    local py = cp.O.y + cp.X.y * c[1] + cp.Z.y * c[2]
    local pz = cp.O.z + cp.X.z * c[1] + cp.Z.z * c[2]
    -- (from `top` over the stand's ground plane, straight down)
    local d0 = dot(V(px - G.x, py - G.y, pz - G.z), U)
    local ox, oy, oz = b.x + px + U.x * (top - d0), b.y + py + U.y * (top - d0), b.z + pz + U.z * (top - d0)
    local h = rayPast(ox, oy, oz, -U.x, -U.y, -U.z, top + 8, roots)
    if h and h.distance then
      local g = top - h.distance
      if not hi or g > hi then hi = g end
    end
  end
  return math.max(0, hi or 0)
end

-- The deck height a blueprint needs on this stand (the ground under it read
-- when the scene is there). → h | nil, why
function needFor(sid, uid, bp, extra)
  local fp = framePose(sid, uid)
  if not fp then return nil, "no stand there" end
  local S = fp.def.stand
  local b = bounds(bp, S.deck)
  local h, why = needHeight(b, S, P("wheel_clear"), 0, P("clear"))
  if not h then return nil, why end
  local cp = craftPose(sid, uid, bp, h)
  local rise = ground_rise(sid, uid, cp, extra)
  if rise > 0.02 then
    h, why = needHeight(b, S, P("wheel_clear"), rise, P("clear"))
    if not h then return nil, why end
  end
  return h
end

-- Set the stand's deck height (empty or uncommissioned only). → ok, why
function setHeight(sid, uid, h)
  local rec, p, def, ST = standAt(sid, uid)
  if not rec then return false, "no stand there" end
  local st = stateOf(sid, uid)
  if st and st.s == STATE_HELD then return false, "release the craft first" end
  h = clampHeight(def.stand, h)
  if st and st.s == STATE_BUILT then
    local bp = blueprint(sid, uid)
    local need = bp and needFor(sid, uid, bp)
    if need and h < need - 1e-6 then return false, string.format("the craft on it needs %.1f m", need) end
  end
  p.h, p.lo = h, nil
  ST.put(rec)
  local key = keyOf(sid, uid)
  pose_deck(key, def, h)
  drop_display(key)
  if st and st.s == STATE_BUILT then show_display(sid, uid) end
  return true
end

-- PUT A CRAFT ON THE STAND (L2). bp = a launch-format blueprint. opts = {
-- free = true (no charge), paid = { cost, ship, total, t } (instead of the
-- quote), ret = true (came back to the stand), name }. → ok, why, quote
function putOn(sid, uid, bp, opts)
  opts = opts or {}
  local rec, p, def, ST = standAt(sid, uid)
  if not rec then return false, "no stand there" end
  local cur = stateOf(sid, uid)
  if cur and not (opts.replace and cur.s == STATE_BUILT) then return false, "there is a craft on the stand already" end
  if type(bp) ~= "table" or type(bp.parts) ~= "table" or next(bp.parts) == nil then return false, "that design has no parts" end
  -- (a work in progress from the editor may be headless or too tall: the
  -- CHECK says so, and Commission refuses it)
  if not opts.wip then
    local cw = commandWhy(bp)
    if cw then return false, cw end
  end
  local need, why = needFor(sid, uid, bp, opts.ignore)
  if not need and not opts.wip then return false, why end
  local q = opts.paid
  local co, E = ref("company"), ref("base_economy")
  if not q then
    q = quote(bp, E)
    local home = save.get("base.body")
    if home and rec.b ~= home then return false, "off the home world a craft is made, not shipped: the Fabricator comes later" end
    if not opts.free then
      if not (co and co.spend) then return false, "no company to pay with" end
      local nm = tostring(opts.name or bp.name or "craft")
      if not co.spend(q.total, string.format("%s on a Build Stand · %s + %s shipping (trucked out)", nm, money(q.cost), money(q.ship))) then
        return false, "can't afford it: " .. money(q.total)
      end
    end
    q.t = agency_now()
  end
  local keep = deep(bp)
  keep.name = opts.name or keep.name
  save.set(STAND_KEY(sid, uid), keep)
  local n = 0
  for _ in pairs(keep.parts) do n = n + 1 end
  set_state(sid, uid, { s = STATE_BUILT, key = STAND_KEY(sid, uid), name = keep.name, n = n,
    cost = q.cost or 0, ship = q.ship or 0, total = q.total or 0, t = q.t or agency_now(), by = member(),
    ret = opts.ret or (cur and cur.ret) or nil, wheeled = wheeled(keep) or nil, wip = opts.wip or nil })
  -- the stand raises itself to what the craft needs (and back up from lowered)
  local set = clampHeight(def.stand, p.h or def.stand.min)
  if need and (p.lo or set < need - 1e-6) then
    p.h, p.lo = math.max(need, set), nil
    ST.put(rec)
    pose_deck(keyOf(sid, uid), def, p.h)
  end
  drop_display(keyOf(sid, uid))
  if not opts.noDisplay then show_display(sid, uid) end
  lastPut = { sid = sid, uid = uid, name = keep.name, n = n, total = q.total, h = p.h, need = need, t = now() }
  return true, nil, q
end

-- ═══ THE EDITOR AT A STAND (work/standeditor/PLAN.md §5, §6.4) ══════════════

-- What the stand's craft was last paid for: uid → cost (the blueprint's
-- `committed`; a craft trucked out or returned before the editor: every part).
function committedOf(sid, uid)
  local bp = blueprint(sid, uid)
  if not bp then return {} end
  if type(bp.committed) == "table" then return bp.committed end
  local out = {}
  for _, d in pairs(bp.parts) do if d.uid then out[d.uid] = d.cost or 0 end end
  return out
end

-- THE DIFF, charged on leaving the editor (pure). old = uid → cost (what was
-- paid for), newBp = the blueprint now, E = base_economy, now = agency
-- clock, paid = the stand's record { cost, ship, total, t }. A part replaced
-- (a uid whose cost changed) is a removal and an addition. Removed parts come
-- back by the deconstruct rule (within a minute of the last commit all of it,
-- their share of its shipping too; later the price); what was added rides one
-- truck. → { added, removed, refund, ship, total (+ = to pay, − = back),
--            cost (the craft's price now), committed (uid → cost), n_add, n_rem }
function commitQuote(old, newBp, E, now, paid)
  old = old or {}
  local new = {}
  for _, d in pairs(newBp and newBp.parts or {}) do if d.uid then new[d.uid] = d.cost or 0 end end
  local added, removed, na, nr = 0, 0, 0, 0
  for u, c in pairs(new) do
    if old[u] == nil then added, na = added + c, na + 1
    elseif old[u] ~= c then added, removed, na, nr = added + c, removed + old[u], na + 1, nr + 1 end
  end
  for u, c in pairs(old) do if new[u] == nil then removed, nr = removed + c, nr + 1 end end
  paid = paid or {}
  local refund = removed
  local fresh = paid.t ~= nil and now ~= nil and (now - paid.t) <= ((E and E.UNDO_SECS) or 60) + 1e-6 and (now - paid.t) >= -1
  if fresh and removed > 0 and (paid.cost or 0) > 0 then
    refund = removed + math.floor((paid.ship or 0) * math.min(1, removed / paid.cost) + 0.5)
  end
  local ship = (added > 0) and ((E and E.shipping) and E.shipping(added) or math.floor(added * 0.1 + 50.5)) or 0
  return { added = added, removed = removed, refund = refund, ship = ship, total = added + ship - refund,
           cost = math.max(0, (paid.cost or 0) + added - removed), committed = new, n_add = na, n_rem = nr }
end

-- The one place a commit turns into money (step 13 draws parts from the
-- containers in reach instead, off the home world). → ok, why
function payFor(sid, uid, q, payer)
  if not q or q.total == 0 then return true end
  local rec = standAt(sid, uid)
  local home = save.get("base.body")
  if rec and home and rec.b ~= home and (q.added or 0) > 0 then
    return false, "off the home world a part is made, not shipped: the Fabricator comes later"
  end
  local co = ref("company")
  if not co then return false, "no company to pay with" end
  local nm = tostring(q.name or "the craft")
  if q.total > 0 then
    if not (co.spend and co.spend(q.total, string.format("%s on a Build Stand · %s of parts + %s shipping%s", nm,
        money(q.added), money(q.ship), (q.refund or 0) > 0 and (" − " .. money(q.refund) .. " taken off") or ""))) then
      return false, "can't afford it: " .. money(q.total)
    end
  else
    local why = string.format("%s on a Build Stand · %s of parts taken off", nm, money(q.removed))
    if co.refund then co.refund(-q.total, why) elseif co.earn then co.earn(-q.total, why) end
  end
  return true
end

-- Keep the editor's craft on the stand without charging (the autosave and an
-- exit): the blueprint, with `committed` = what is paid for, and its state.
-- opts = { paid = { cost, ship, total, t }, committed = uid → cost, name,
-- wip = true } → ok, why
function saveWip(sid, uid, bp, opts)
  opts = opts or {}
  local rec, p, def = standAt(sid, uid)
  if not rec then return false, "no stand there" end
  local cur = stateOf(sid, uid)
  if cur and cur.s == STATE_HELD then return false, "release the craft first" end
  if type(bp) ~= "table" or type(bp.parts) ~= "table" or next(bp.parts) == nil then
    -- nothing on the deck: the stand is empty again
    drop_display(keyOf(sid, uid))
    forget_bp(sid, uid)
    set_state(sid, uid, nil)
    return true
  end
  local keep = deep(bp)
  keep.committed = opts.committed or committedOf(sid, uid)
  local paid = opts.paid or (cur and { cost = cur.cost, ship = cur.ship, total = cur.total, t = cur.t }) or { cost = 0, ship = 0, total = 0, t = agency_now() }
  return putOn(sid, uid, keep, { wip = opts.wip ~= false, replace = true, paid = paid, name = opts.name or keep.name,
    noDisplay = opts.noDisplay })
end

-- Public names the editor drives live.
function poseDeck(sid, uid, h)
  local rec, p, def = standAt(sid, uid)
  if rec then pose_deck(keyOf(sid, uid), def, h or heightOf(p, def)) end
end
function hideDisplay(sid, uid) drop_display(keyOf(sid, uid)) end
-- The editor is open on this stand (nil: closed): its parts are the
-- builder's, so the display copy stays down.
function setEditing(sid, uid)
  if sid then editing = keyOf(sid, uid); drop_display(editing) else editing = nil end
end
function editingKey() return editing end
function agencyNow() return agency_now() end
function showDisplay(sid, uid) show_display(sid, uid) end
function standNodeOf(sid, uid) return standNode[keyOf(sid, uid)] end
-- Make the stand's node again (its colliders where its deck now is).
function respawnStand(sid, uid)
  local ST = ref("structures")
  return ST and ST.respawnPart and ST.respawnPart(sid, uid) or false
end

-- CLEAR THE STAND: the craft's parts go back. → refund | nil, why
function clear(sid, uid)
  local st = stateOf(sid, uid)
  if not st then return nil, "the stand is empty" end
  if st.s == STATE_HELD then return nil, "it's commissioned: release it, or return it to the stand first" end
  local E, co = ref("base_economy"), ref("company")
  local amt, rule = 0, "price"
  if E and E.deconstructRefund then amt, rule = E.deconstructRefund({ cost = st.cost, total = st.total, t = st.t }, agency_now()) end
  if st.ret then amt, rule = math.floor(st.cost or 0), "recovered" end
  if amt > 0 and co then
    local why = string.format("cleared off a Build Stand: %s · %s", tostring(st.name or "craft"),
      rule == "full" and "all of it back (within a minute)" or (rule == "recovered" and "its recovery value" or "the price back, shipping kept"))
    if co.refund then co.refund(amt, why) elseif co.earn then co.earn(amt, why) end
  end
  drop_display(keyOf(sid, uid))
  forget_bp(sid, uid)
  set_state(sid, uid, nil)
  lastClear = { sid = sid, uid = uid, refund = amt, rule = rule, t = now() }
  return amt
end

-- A part's collider half-extents (its live RigidBody, scaled), or nil.
local function rb_half(part)
  local getc = part.getComponent or part.getcomponent
  local rb = getc and getc(part, "RigidBody")
  if rb and rb.half_y and rb.half_y > 0 then
    return { x = (rb.half_x or 0.5) * math.abs(part.scale_x or 1), y = rb.half_y * math.abs(part.scale_y or 1),
             z = (rb.half_z or 0.5) * math.abs(part.scale_z or 1) }
  end
  return nil
end

local function controller_of(node)
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and valid(v.node) and v.node.id == node.id then return v end
  end
  return nil
end

-- Is the craft's space on the stand clear? → nil | why (placement.overlapObb,
-- looking past the ground, the stand and the crew's own display copy)
local function in_the_way(sid, uid, cp, skipNode)
  local pl = ref("placement")
  local b = cp and space.body(cp.fp.body)
  if not (pl and pl.overlapObb and b) then return nil end
  local bb = cp.b
  -- from a little over the belly to the top (the deck and what hangs below
  -- it are the stand's, and its column runs down through the box)
  local y0, y1 = bb.belly + 0.10, bb.hi
  if y1 - y0 < 0.2 then return nil end
  local cx, cy, cz = (bb.x0 + bb.x1) / 2, (y0 + y1) / 2, (bb.z0 + bb.z1) / 2
  local wx = b.x + cp.O.x + cp.X.x * cx + cp.U.x * cy + cp.Z.x * cz
  local wy = b.y + cp.O.y + cp.X.y * cx + cp.U.y * cy + cp.Z.y * cz
  local wz = b.z + cp.O.z + cp.X.z * cx + cp.U.z * cy + cp.Z.z * cz
  local skipset = {}
  for _, n in ipairs(stand_nodes(keyOf(sid, uid))) do skipset[n.id] = true end
  local half = { x = math.max(0.1, (bb.x1 - bb.x0) / 2 - 0.05), y = (y1 - y0) / 2, z = math.max(0.1, (bb.z1 - bb.z0) / 2 - 0.05) }
  local hit = pl.overlapObb({ x = wx, y = wy, z = wz }, half, { r = cp.X, u = cp.U, f = cp.Z },
    { skip = function(n)
        if skipset[n.id] then return true end
        if skipNode and n.id == skipNode.id then return true end
        if n.name == cp.fp.body then return true end
        local ok, t = pcall(function() return n.terrain end)
        return ok and t ~= nil and t ~= false
      end })
  if not hit then return nil end
  local a = find and find("Astronaut")
  local n = hit.node
  if a and n and n.id == a.id then return "you're standing where it goes" end
  return "something's in the way" .. (n and n.name and (": " .. tostring(n.name)) or "")
end

-- Is the craft's box on the stand clear? → nil | why (the CHECK's S5 and Commission)
function inTheWay(sid, uid, bp, skipNode)
  local cp = bp and craftPose(sid, uid, bp)
  if not cp then return nil end
  return in_the_way(sid, uid, cp, skipNode)
end

-- COMMISSION (L4): the live craft, held on the deck. → ok, why
function commission(sid, uid, opts)
  opts = opts or {}
  local key = keyOf(sid, uid)
  local st = stateOf(sid, uid)
  if not st then return false, "the stand is empty" end
  if J[key] then return false, "it is commissioned already" end
  if st.s ~= STATE_BUILT and not (opts.reload and st.s == STATE_HELD) then return false, "it is commissioned already" end
  local bp = blueprint(sid, uid)
  if not bp then return false, "the craft's blueprint is missing" end
  local cw = commandWhy(bp)
  if cw then return false, cw end
  if not valid(standNode[key]) then return false, "the stand isn't here (walk closer)" end
  local fp = framePose(sid, uid)
  local cp = craftPose(sid, uid, bp, fp and fp.h)
  if not cp then return false, "nothing of it rests on the deck" end
  if not opts.reload then
    local w = in_the_way(sid, uid, cp)
    if w then return false, w end
  end
  local b = space.body(cp.fp.body)
  if not (b and spawn and assembly) then return false, "no world here" end
  drop_display(key)
  local E = { sid = sid, uid = uid, body = cp.fp.body, relv = V(cp.O.x, cp.O.y, cp.O.z), U = cp.U, placed = {},
              phase = "assembling", t0 = now(), wheeled = wheeled(bp), name = bp.name }
  J[key] = E
  local parts = {}
  for _, d in pairs(bp.parts) do if d.prefab then parts[#parts + 1] = d end end
  local total = #parts
  E.total = total
  local wx, wy, wz = b.x + cp.O.x, b.y + cp.O.y, b.z + cp.O.z
  local X, U, Z = cp.X, cp.U, cp.Z
  local PR = ref("builder_proc")
  spawn("Vessel", vec3(wx, wy, wz), function(v)
    if J[key] ~= E then v:destroy() return end
    v:setUp(vec3(U.x, U.y, U.z), vec3(-Z.x, -Z.y, -Z.z))
    E.node = v
    local nm = bp.name or st.name
    if nm then pcall(function() v.name = nm end) end
    -- (vessel_controller's start reads this, as a fleet rebuild's: the craft
    -- wakes with these parts, fuel and charge, and `held` on the stand)
    save.set("dock.handoff." .. tostring(v.id or 0),
      { parts = bp.parts, lost = bp.lost, fuel = bp.fuel, charge = bp.charge, lockout = 2.0, groups = bp.groups,
        controls = bp.controls, name = nm, from = bp.from, flown = false, held = true })
    local b2 = space.body(E.body) or b
    for _, d in ipairs(parts) do
      local px = b2.x + E.relv.x + X.x * (d.x or 0) + U.x * (d.y or 0) + Z.x * (d.z or 0)
      local py = b2.y + E.relv.y + X.y * (d.x or 0) + U.y * (d.y or 0) + Z.y * (d.z or 0)
      local pz = b2.z + E.relv.z + X.z * (d.x or 0) + U.z * (d.y or 0) + Z.z * (d.z or 0)
      spawn(d.prefab, vec3(px, py, pz), function(part)
        if J[key] ~= E or not valid(v) then part:destroy() return end
        part.x, part.y, part.z = d.x or 0, d.y or 0, d.z or 0
        part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
        if part.addTag then part:addTag("craftpart") end
        if d.size and d.proc and PR and PR.dress then
          pcall(PR.dress, part, { def = d, size = d.size })
          for _, j in ipairs(d.joints or {}) do pcall(PR.dressJoint, part, j) end
        elseif d.joints and PR and PR.dressJoint then
          for _, j in ipairs(d.joints) do pcall(PR.dressJoint, part, j) end
        end
        E.placed[#E.placed + 1] = { part = part, d = d }
        if #E.placed == total then
          assembly.rebuild(v)
          assembly.setAnchored(v, true)
          -- seat the belly on the deck by the real colliders (the blueprint's
          -- boxes were an estimate)
          local halves = {}
          for _, e in ipairs(E.placed) do halves[e.d.uid] = rb_half(e.part) end
          local cp2 = craftPose(sid, uid, bp, nil, halves)
          if cp2 then
            E.relv = V(cp2.O.x, cp2.O.y, cp2.O.z)
            -- (how far its lowest part hangs over the stand's ground: the
            -- jack's fallback when no ray finds the ground)
            E.lowAbove = cp2.fp.h + P("clear") - (cp2.b.belly - cp2.b.lo)
          end
          E.phase = "held"
          E.ready_t = now()
        end
      end, v)
    end
  end)
  if not opts.reload then
    st.s = STATE_HELD
    set_state(sid, uid, st)
    lastCommission = { sid = sid, uid = uid, name = bp.name, n = total, t = now() }
    play("place", 0.6)
  end
  return true
end

-- The held craft on a stand (probes): its live entry, or nil.
function heldOf(sid, uid) return J[keyOf(sid, uid)] end

-- Drop the stand to `low` (a new node: its colliders are made down there).
local function stow(E)
  local rec, p, def, ST = standAt(E.sid, E.uid)
  if not rec then return end
  p.lo = true
  ST.put(rec)
  E.stowing = true
  if not ST.respawnPart(E.sid, E.uid) then E.stowing = false end
end

-- The craft is free: the stand forgets it (the fleet keeps it from now).
local function let_go(E, how)
  local key = keyOf(E.sid, E.uid)
  J[key] = nil
  forget_bp(E.sid, E.uid)
  set_state(E.sid, E.uid, nil)
  lastRelease = { sid = E.sid, uid = E.uid, how = how, t = now(), node = E.node }
  if log then log(string.format("stand: %s released (%s)", tostring(E.name or "the craft"), how)) end
end

-- RELEASE (L4): a craft on wheels is jacked down onto them, anything else is
-- let go on the deck. → ok, why
function release(sid, uid)
  local E = J[keyOf(sid, uid)]
  if not E then return false, "nothing commissioned on this stand" end
  if E.phase == "assembling" then return false, "it's still being put together" end
  if E.phase ~= "held" then return false, "it's already on its way down" end
  if E.wheeled then
    E.phase, E.jack_t = "jack", -10
    play("jack", 0.6)
    say(string.format("letting %s down onto its wheels", tostring(E.name or "the craft")))
    return true
  end
  local v = valid(E.node) and controller_of(E.node)
  if v and v.releaseClamps and v.releaseClamps() then let_go(E, "clamps") return true end
  if valid(E.node) then assembly.setAnchored(E.node, false) end
  let_go(E, "let go")
  return true
end

-- RETURN TO STAND (L4): a landed, stopped, empty craft near an empty stand.
-- → ok, why
function returnWhy(v, sid, uid)
  if not (v and v.node and valid(v.node)) then return "no craft" end
  if v.structureMode then return "part of a structure" end
  if v.piloting or v.crewAboard then return "the crew must step off first" end
  if v.isLost and v.isLost() then return "it's a wreck: recover it instead" end
  local i = assembly.info(v.node)
  if not i then return "it's still being put together" end
  if i.anchored then return "it's clamped" end
  if i.vel and len(i.vel.x, i.vel.y, i.vel.z) > 0.3 then return "it's still moving" end
  if not (i.grounded or (v.r2OnWheels and v.r2OnWheels())) then
    -- (an unpiloted rover stows its tyre state: stopped with ground right
    -- under its centre of mass, it is down — flight_ops' landed rule)
    local c = i.com
    local bname = c and space.dominant(c.x, c.y, c.z)
    local b = bname and space.body(bname)
    local down = false
    if b then
      local ux, uy, uz = c.x - b.x, c.y - b.y, c.z - b.z
      local l = len(ux, uy, uz)
      if l > 1e-3 then
        local h = rayPast(c.x, c.y, c.z, -ux / l, -uy / l, -uz / l, 4.0, rootSet({ v.node }))
        down = h ~= nil and h.distance <= 3.0
      end
    end
    if not down then return "it isn't standing on the ground" end
  end
  if stateOf(sid, uid) then return "that stand is in use" end
  return nil
end

-- The nearest empty stand to a craft (any of its parts within return_r of the
-- deck's centre). → sid, uid, d | nil
function standFor(v)
  local ST = ref("structures")
  if not (ST and v and v.node and valid(v.node)) then return nil end
  local n = v.node
  local bname = space.dominant(n.x, n.y, n.z)
  local b = bname and space.body(bname)
  if not b then return nil end
  local pts = {}
  local okc, kids = pcall(n.children, n)
  for _, c in ipairs(okc and kids or {}) do
    local w = c.worldPos
    if w then pts[#pts + 1] = V(w.x - b.x, w.y - b.y, w.z - b.z) end
  end
  if #pts == 0 then pts[1] = V(n.x - b.x, n.y - b.y, n.z - b.z) end
  local best, bd = nil, P("return_r")
  for _, e in ipairs(ST.partsNear(bname, pts[1].x, pts[1].y, pts[1].z, 40)) do
    local def = defOf(e.part)
    if def and def.stand and not stateOf(e.rec.id, e.part.uid) then
      local fp = framePose(e.rec.id, e.part.uid)
      if fp then
        for _, q in ipairs(pts) do
          local d = len(q.x - fp.top.x, q.y - fp.top.y, q.z - fp.top.z)
          if d < bd then best, bd = e, d end
        end
      end
    end
  end
  if not best then return nil end
  return best.rec.id, best.part.uid, bd
end

function returnTo(v, sid, uid)
  local why = returnWhy(v, sid, uid)
  if why then return false, why end
  local fp = v.fleetParts and v.fleetParts()
  if not (fp and fp.parts and #fp.parts > 0) then return false, "it can't be described" end
  local El = ref("electronics")
  local parts = {}
  for i, d in ipairs(fp.parts) do
    parts[i] = (El and El.packRecord) and El.packRecord(d) or deep(d)
  end
  local lost = nil
  for _, d in ipairs(fp.lost or {}) do lost = lost or {}; lost[#lost + 1] = (El and El.packRecord) and El.packRecord(d) or deep(d) end
  local name = (v.craftName ~= nil and v.craftName ~= "Vessel" and v.craftName) or "Craft"
  local bp = { parts = parts, lost = lost, fuel = fp.fuel, charge = fp.charge, groups = fp.groups, controls = fp.controls,
               from = fp.from, name = name, v = 2 }
  local worth = (v.recoverValue and v.recoverValue()) or math.floor(hullCost(bp) * 0.85)
  local ok, w = putOn(sid, uid, bp, { paid = { cost = math.floor(worth), ship = 0, total = math.floor(worth), t = -1e9 },
                                      ret = true, name = name, ignore = v.node })
  if not ok then return false, w end
  local node = v.node
  local id = node.id
  local fo = ref("flight_ops")
  if fo and fo.forgetNodes then pcall(fo.forgetNodes, { id }) end
  -- (its "F — sit in the seat" prompt goes with it: a craft destroyed mid-
  -- frame never clears the line it last wrote — probe se11)
  local hp = find and find("Vessel HUD")
  if hp and hp.valid ~= false and v.promptText and v.promptText ~= "" then pcall(function() hp.text = "" end) end
  pcall(node.destroy, node)
  lastReturn = { sid = sid, uid = uid, name = name, n = #parts, worth = worth, t = now() }
  play("place", 0.6)
  return true
end

-- ═══ STRUCTURES' HOOKS ══════════════════════════════════════════════════════

-- The stand's node has landed: its deck to its height, and what is on it.
function spawned(rec, p, inst)
  local def = defOf(p)
  if not (def and def.stand) then return end
  local key = keyOf(rec.id, p.uid)
  standNode[key] = inst
  pose_deck(key, def, heightOf(p, def))
  local E = J[key]
  if E and E.stowing then E.stowing = false; E.stowed_t = now() end
  local st = stateOf(rec.id, p.uid)
  if not st then return end
  if st.s == STATE_BUILT then
    drop_display(key)
    show_display(rec.id, p.uid)
  elseif st.s == STATE_HELD and not J[key] then
    -- (a reload: the held craft is the stand's to put back, not the fleet's;
    -- saved mid-release, it goes back up on the deck's setting)
    if p.lo then p.lo = nil; pose_deck(key, def, heightOf(p, def)) end
    local ok, why = commission(rec.id, p.uid, { reload = true })
    if not ok and log then log("stand: could not put the held craft back: " .. tostring(why)) end
  end
end

function gone(sid, uid)
  local key = keyOf(sid, uid)
  standNode[key] = nil
  drop_display(key)
end

-- A stand with a craft on it doesn't come down (field_builder asks).
function canRemove(rec, p)
  local st = stateOf(rec.id, p.uid)
  if st then
    return false, st.s == STATE_HELD and "a commissioned craft stands on it: release it first"
      or "a craft is on the stand: clear it first"
  end
  return true
end

-- ═══ THE TICK: only while a craft is held or coming down ════════════════════

local crew_far = { t = -10, far = false }
local function crew_is_far(E)
  if now() - crew_far.t < 0.5 then return crew_far.far end
  crew_far.t = now()
  local a = find and find("Astronaut")
  local b = space.body(E.body)
  crew_far.far = not (a and b) or len(a.x - b.x - E.relv.x, a.y - b.y - E.relv.y, a.z - b.z - E.relv.z) > 600
  return crew_far.far
end

local function jack_tick(E, dt)
  local b = space.body(E.body)
  if not (b and valid(E.node)) then return end
  local rec, p, def = standAt(E.sid, E.uid)
  -- how far is it to the ground? (vessel_spawner.seatShift's rule: rays down
  -- under every part that hangs within a metre of the lowest, looking past
  -- the craft, the crew and the stand; the part nearest the ground decides)
  if now() - (E.jack_t or -10) > 0.25 then
    E.jack_t = now()
    local a = find and find("Astronaut")
    local roots = standRoots(E.sid, E.uid, { E.node, a })
    local n = E.node
    local f = n:worldForward()
    local Xw, Uw, Zw = n:worldRight(), n:worldUp(), V(-f.x, -f.y, -f.z)
    local pin = V(b.x + E.relv.x, b.y + E.relv.y, b.z + E.relv.z)
    local low, bottoms = nil, {}
    for _, e in ipairs(E.placed) do
      local bx = partBox(e.d, valid(e.part) and rb_half(e.part) or nil)
      bottoms[#bottoms + 1] = { d = e.d, y = bx.y0 }
      if not low or bx.y0 < low then low = bx.y0 end
    end
    local need = nil
    for _, q in ipairs(bottoms) do
      if q.y <= (low or 0) + 1.0 then
        local d = q.d
        local px = pin.x + Xw.x * (d.x or 0) + Uw.x * q.y + Zw.x * (d.z or 0)
        local py = pin.y + Xw.y * (d.x or 0) + Uw.y * q.y + Zw.y * (d.z or 0)
        local pz = pin.z + Xw.z * (d.x or 0) + Uw.z * q.y + Zw.z * (d.z or 0)
        local hit = rayPast(px + Uw.x * 4, py + Uw.y * 4, pz + Uw.z * 4, -Uw.x, -Uw.y, -Uw.z, 4 + 6, roots)
        if hit and hit.distance then
          local gap = 4 - hit.distance          -- the ground over this part's bottom (+ = buried)
          if not need or gap > need then need = gap end
        end
      end
    end
    local sh = need and math.max(-2.0, need + P("clear")) or nil
    -- (no ray found the ground: the blueprint's estimate of the drop)
    if sh == nil and E.lowAbove then sh = -math.max(0, E.lowAbove - (E.down or 0) - P("clear")) end
    E.left = sh
  end
  local sh = E.left
  if not sh or sh >= -0.005 then
    if def then pose_deck(keyOf(E.sid, E.uid), def, def.stand.low) end
    E.phase = "stow"
    stow(E)
    return
  end
  local step = math.max(sh, -P("jack_rate") * dt)
  E.relv = V(E.relv.x + E.U.x * step, E.relv.y + E.U.y * step, E.relv.z + E.U.z * step)
  E.left = sh - step
  E.down = (E.down or 0) - step
  -- the deck goes down under it, until it is stowed
  if def and p then pose_deck(keyOf(E.sid, E.uid), def, math.max(def.stand.low, heightOf(p, def) - E.down)) end
end

function start(node)
  if findScripts then
    local all = findScripts("craft_stand")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  standNode, shown, J = {}, {}, {}
end

local function provider_tick() end

function update(node, dt)
  provider_tick()
  -- (S2: F beside a display copy says why nothing happens)
  if next(shown) ~= nil and input and input.pressed and input.pressed("f") then
    local pw = ref("planet_walker")
    if not pw or pw.onFoot ~= false then
      local h = displayHint()
      if h then lastHint = h; if caption then pcall(caption, h) end; if log then log("stand: " .. h) end end
    end
  end
  if next(J) == nil then return end
  for key, E in pairs(J) do
    if E.node and not valid(E.node) then
      -- the craft went (recovered, wrecked, reverted): the stand is empty
      J[key] = nil
      if stateOf(E.sid, E.uid) then forget_bp(E.sid, E.uid); set_state(E.sid, E.uid, nil) end
    elseif E.phase == "assembling" then
      if now() - E.t0 > 20 and E.node and #E.placed > 0 then
        -- (a part that never landed must not hold the stand for ever)
        assembly.rebuild(E.node)
        assembly.setAnchored(E.node, true)
        E.phase, E.ready_t = "held", now()
      end
    else
      local b = space.body(E.body)
      local i = E.node and assembly.info(E.node)
      if E.phase == "held" and i and not i.anchored and now() - (E.ready_t or 0) > 0.5 then
        -- the pilot let the clamps go (SPACE): a wheeled craft's deck drops away
        if E.wheeled then E.phase = "stow"; stow(E) else let_go(E, "the pilot") end
      elseif E.phase == "jack" then
        jack_tick(E, dt)
      elseif E.phase == "stow" and not E.stowing then
        local v = controller_of(E.node)
        local done = false
        if i and i.anchored then
          if v and v.releaseClamps then done = v.releaseClamps() end
          if not done then assembly.setAnchored(E.node, false); done = true end
        else
          done = true
        end
        if done then let_go(E, "let down") end
      end
      -- the pin: held (or coming down), it stays on its deck as the planet moves
      if J[key] == E and b and i and i.anchored and not crew_is_far(E) then
        assembly.teleport(E.node, vec3(b.x + E.relv.x, b.y + E.relv.y, b.z + E.relv.z))
      end
    end
  end
end

-- ═══ THE MENUS ══════════════════════════════════════════════════════════════

-- The VAB's library (builder craftList / libRead, without the builder).
function designs()
  local out = {}
  for _, e in ipairs(type(save.get("shipyard.crafts")) == "table" and save.get("shipyard.crafts") or {}) do
    if type(e) == "table" and e.slug and e.name then out[#out + 1] = { name = e.name, slug = e.slug, parts = e.parts, cost = e.cost } end
  end
  return out
end
function readDesign(slug)
  if assets and assets.readText and json and json.decode then
    local sl = (save.slot and save.slot()) or "default"
    sl = tostring(sl):gsub("[^%w_%-]", "_")
    local ok, text = pcall(assets.readText, "user://library/" .. sl .. "/" .. slug .. ".json")
    if ok and type(text) == "string" then
      local okd, v = pcall(json.decode, text)
      if okd and type(v) == "table" and type(v.bp) == "table" then return decodeLib(v.bp) end
    end
  end
  local old = save.get("shipyard.craft." .. slug)
  if type(old) == "table" then return deep(old) end
  return nil
end

local function job_secs(T, n) return math.min(T.max, T.base + T.per * (n or 0)) end

local function stand_rows(sid, uid, def, ctx)
  local S = def.stand
  local function toast(msg, bad) if ctx and ctx.toast then ctx.toast(msg, bad) end end
  local rows = {}
  rows[#rows + 1] = { id = "cs_what", type = "info", label = "Build Stand", group = "Stand", value = function()
      local st = stateOf(sid, uid)
      local rec, p = standAt(sid, uid)
      local h = p and heightOf(p, def) or 0
      if not st then return string.format("empty · deck %.1f m%s", h, p and p.lo and " (lowered)" or "") end
      return string.format("%s · %d parts · %s · deck %.1f m", tostring(st.name or "craft"), st.n or 0,
        st.s == STATE_HELD and "commissioned, held" or "not commissioned", h)
    end }
  -- BUILD HERE (the editor at the stand: the VAB's camera and overlay, its
  -- frame on this deck; work/standeditor/PLAN.md §6.1)
  local st0 = stateOf(sid, uid)
  if not (st0 and st0.s == STATE_HELD) then
    rows[#rows + 1] = { id = "cs_build", type = "action", label = "Build here", group = "Stand", hint = "▸",
      value = function() local s2 = stateOf(sid, uid); return s2 and "edit the craft on the deck" or "the VAB, on this deck" end,
      enabled = function()
        local bh = ref("build_host")
        return engineer() and valid(standNode[keyOf(sid, uid)]) and bh ~= nil and bh.enter ~= nil
      end,
      why = function()
        if not engineer() then return "Engineers only" end
        if not valid(standNode[keyOf(sid, uid)]) then return "walk closer" end
        return "the builder isn't in this scene"
      end,
      act = function()
        local fb = ref("field_builder")
        if fb and fb.isOpen and fb.isOpen() and fb.close then fb.close() end
        local bh = ref("build_host")
        local ok, w = bh.enter({ stand = { sid = sid, uid = uid } })
        if not ok then toast(tostring(w or "the builder wouldn't open here"), true) end
        return ok ~= false, w
      end }
  end
  -- (the deck's height, a step a click: the world's menu has no drag slider)
  local function setting() local _, p = standAt(sid, uid); return p and clampHeight(S, p.h or S.min) or S.min end
  local function can_set() local st = stateOf(sid, uid); return engineer() and not (st and st.s == STATE_HELD) end
  local function set_why() return engineer() and "release the craft first" or "Engineers only" end
  for _, dir in ipairs({ 1, -1 }) do
    rows[#rows + 1] = { id = dir > 0 and "cs_up" or "cs_dn", type = "action", keep = true, group = "Stand",
      label = dir > 0 and "Raise the deck" or "Lower the deck",
      hint = dir > 0 and "▴ 0.1 m" or "▾ 0.1 m",
      enabled = can_set, why = set_why,
      act = function()
        local ok, w = setHeight(sid, uid, setting() + dir * S.step)
        if not ok then toast(w, true) end
        return ok, w
      end }
  end
  local st = stateOf(sid, uid)
  if not st then
    rows[#rows + 1] = { id = "cs_put", type = "sub", label = "Truck a saved craft out (as is)…", group = "Stand", hint = "▸",
      title = "THE VAB'S LIBRARY",
      enabled = function() return engineer() end, why = "Engineers only",
      sub = function()
        local list = {}
        local ds = designs()
        if #ds == 0 then
          list[1] = { type = "info", id = "cs_none", label = "No crafts saved", value = "save one in the VAB (Ctrl+S)" }
        end
        local E = ref("base_economy")
        for i, d in ipairs(ds) do
          list[#list + 1] = { type = "action", id = "cs_d" .. i, label = d.name,
            value = function()
              local cost = d.cost or 0
              local ship = E and E.shipping and E.shipping(cost) or 0
              return string.format("%d parts · %s + %s shipping", d.parts or 0, money(cost), money(ship))
            end,
            job = { secs = job_secs(PUT_SECS, d.parts), label = "Trucking out " .. d.name,
              check = function() if stateOf(sid, uid) then return false, "the stand is in use" end return true end,
              tick = function() end,
              done = function()
                local bp = readDesign(d.slug)
                if not bp then toast("couldn't read " .. d.name, true) return false end
                bp.name = bp.name or d.name
                local ok, w, q = putOn(sid, uid, bp, { name = d.name })
                toast(ok and string.format("%s on the stand · %s", d.name, money(q and q.total or 0)) or tostring(w), not ok)
                return ok, w
              end } }
        end
        return list, "PUT A CRAFT ON THE STAND"
      end }
  elseif st.s == STATE_BUILT then
    -- (sandbox S2: Ty's dead cockpit — the craft on the deck is a blue display
    -- copy until it is commissioned, and says so)
    rows[#rows + 1] = { id = "cs_notyet", type = "info", label = tostring(st.name or "The craft"), group = "Stand",
      value = "not commissioned yet: COMMISSION to use it" }
    rows[#rows + 1] = { id = "cs_com", type = "action", label = "Commission", group = "Stand", hint = "job",
      value = function() return "a live craft, held on the deck" end,
      enabled = function() return engineer() end, why = "Engineers only",
      job = { secs = job_secs(COMMISSION_SECS, st.n), label = "Commissioning " .. tostring(st.name or "the craft"),
        check = function() local s2 = stateOf(sid, uid); return s2 and s2.s == STATE_BUILT, "it's gone" end,
        tick = function() end,
        done = function()
          local ok, w = commission(sid, uid)
          toast(ok and "commissioned · held on the stand · Release lets it go" or tostring(w), not ok)
          return ok, w
        end } }
    rows[#rows + 1] = { id = "cs_clr", type = "action", label = "Clear the stand", group = "Stand", danger = true,
      value = function()
        local s2 = stateOf(sid, uid) or {}
        if s2.ret then return money(s2.cost or 0) .. " back (its recovery value)" end
        local E = ref("base_economy")
        local amt, rule = 0, "price"
        if E and E.deconstructRefund then amt, rule = E.deconstructRefund({ cost = s2.cost, total = s2.total, t = s2.t }, agency_now()) end
        return money(amt) .. " back" .. (rule == "full" and "" or " (shipping kept)")
      end,
      enabled = function() return engineer() end, why = "Engineers only",
      act = function()
        local amt, w = clear(sid, uid)
        toast(amt and ("cleared · " .. money(amt) .. " back") or tostring(w), amt == nil)
        return amt ~= nil
      end }
  else
    rows[#rows + 1] = { id = "cs_rel", type = "action", label = "Release", group = "Stand", hint = "▾",
      value = function() local E = J[keyOf(sid, uid)]; return E and E.wheeled and "let it down onto its wheels" or "let the clamps go" end,
      enabled = function() local E = J[keyOf(sid, uid)]; return E ~= nil and E.phase == "held" end,
      why = "it's still being put together",
      act = function()
        local ok, w = release(sid, uid)
        toast(ok and "released" or tostring(w), not ok)
        return ok
      end }
  end
  return rows
end

local function prop_provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  local def = defOf(part)
  if not (def and def.stand) then return {} end
  return stand_rows(rec.id, part.uid, def, ctx), "Build Stand"
end

local function part_provider(t, ctx)
  local v = t and t.vessel
  if not (v and v.node and valid(v.node)) then return {} end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return {} end
  local sid, uid = standFor(v)
  if not sid then return {} end
  return {
    { id = "cs_ret", type = "action", label = "Return to stand", group = "Stand", hint = "job",
      value = function() return "lift it back onto the Build Stand" end,
      enabled = function() return engineer() and returnWhy(v, sid, uid) == nil end,
      why = function() return engineer() and (returnWhy(v, sid, uid) or "") or "Engineers only" end,
      job = { secs = RETURN_SECS, label = "Lifting it onto the stand",
        check = function() local w = returnWhy(v, sid, uid); return w == nil, w end,
        tick = function() end,
        done = function()
          local ok, w = returnTo(v, sid, uid)
          if ctx and ctx.toast then ctx.toast(ok and "on the stand · Commission makes it a craft again" or tostring(w), not ok) end
          return ok, w
        end } },
  }
end
providers = { prop = prop_provider, part = part_provider }   -- (probes)

local provider_on, provider_t = false, -10
provider_tick = function()
  if provider_on or now() - provider_t < 1.0 then return end
  provider_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", prop_provider, { id = "craft_stand", order = 5 })
    reg.register("part", part_provider, { id = "craft_stand", order = 70 })
    provider_on = true
  end
end
