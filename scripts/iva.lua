-- IVA — the interiors of the controlled craft's closed crew parts
-- (docs/crew-and-items.md §3.4, §4.4; tools/gen_iva.py builds them).
--
-- One interior (prefabs/Iva<Name>) per closed crew part — Pod Mk1, Pod Mk2,
-- Crew Cabin, Swift Cockpit — of the craft you control, spawned while
-- something needs them (the crew strip's portraits, the first-person seat
-- view) and placed every lateUpdate at the part, in the part's own frame.
--
-- THE SCALE. The rooms are human-sized and so bigger than their hulls (a Pod
-- Mk1 is 0.8 m tall, an astronaut 1.88 m): every interior node and every
-- seated doll lives on the `interior` layer, which the main camera never
-- draws. The portraits (crew_strip.lua) and the seat view's stacked "Iva
-- Cam" (planet_camera.lua) draw ONLY that layer, so the rooms are never seen
-- from outside, and outside is seen only through their windows.
--
-- `offstage` is a layer nobody draws: the doll whose eyes the seat view looks
-- through, and the rider's helmet in an open seat, are parked on it.
--
-- API (crew_strip and planet_camera call these):
--   need(v)                       keep v's interiors alive this frame
--   interiorsOf(v) → { [uid] = {node, def, id} }
--   closedSeats(v) → { {uid, slot, id|nil, label, commander} … }  every slot of a closed part
--   seatFrame(v, uid, slot) → hip, up, fwd, right (world, this frame) | nil
--   eyeOf(v, uid, slot) → pos, right, up, back (the seat's eye) | nil
--   mainEye(v, uid) → pos, right, up, back (the hull-side eye) | nil
--   setView(v, uid, slot) / clearView()   the seat view: the wearer's legs, the
--                                 lamps, the exterior of that part hidden
--   view → { v, uid, slot } | nil
--   standIn(id) → node|nil        the doll that stands in for the avatar aboard
--   LAYER_BIT, OFF_BIT            cullMask bits (project.ron order)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

-- Layers: bit i = project.ron's i-th layer after the implicit Default (0).
LAYER, LAYER_BIT = "interior", 4
OFF, OFF_BIT = "offstage", 5

-- Mirrors tools/gen_iva.py IVAS (tests/smoke_crew_strip.lua checks they
-- agree with the prefabs). seats: hip x, y, z and yaw in the SEAT frame
-- (+X right, +Y up, -Z ahead; yaw 0 faces -Z, + turns toward +X); basis:
-- the seat frame's X, Y, Z in the part's frame; eye_main: in the part frame.
DEFS = {
  pod     = { prefab = "IvaPodMk1", basis = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
              seats = { { 0.0, -0.22, 0.16, 0.0 } }, eye_main = { 0.0, 0.02, 0.06 }, lamps = 2 },
  podMk2  = { prefab = "IvaPodMk2", basis = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
              seats = { { 0.0, -0.28, 0.22, 0.0 }, { -0.66, -0.28, 0.16, -0.30 }, { 0.66, -0.28, 0.16, 0.30 } },
              eye_main = { 0.0, 0.06, 0.04 }, lamps = 3 },
  cabin   = { prefab = "IvaCabin", basis = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
              seats = { { -0.44, -0.30, 0.64, 0.0 }, { 0.44, -0.30, 0.64, 0.0 },
                        { 0.44, -0.30, -0.64, math.pi }, { -0.44, -0.30, -0.64, math.pi } },
              eye_main = { 0.0, 0.18, 0.0 }, lamps = 2 },
  cockpit = { prefab = "IvaCockpit", basis = { { -1, 0, 0 }, { 0, 0, -1 }, { 0, -1, 0 } },
              seats = { { 0.0, -0.20, 0.30, 0.0 } }, eye_main = { 0.0, 0.10, -0.40 }, lamps = 1 },
}
-- The seated rig (scripts/command_seat.lua): eyes 0.77 m over the hip node,
-- 0.07 ahead.
EYE_UP, EYE_FWD = 0.77, 0.07

-- ── pure helpers (luajit tests) ────────────────────────────────────────────
-- A seat's hip, facing and eye in the PART frame: {x,y,z}, {fx,fy,fz}, {ex,ey,ez}.
function seatInPart(def, slot)
  local s = def and def.seats[slot]
  if not s then return nil end
  local B = def.basis
  local function map(x, y, z)
    return B[1][1] * x + B[2][1] * y + B[3][1] * z, B[1][2] * x + B[2][2] * y + B[3][2] * z,
           B[1][3] * x + B[2][3] * y + B[3][3] * z
  end
  local hx, hy, hz = map(s[1], s[2], s[3])
  local fx, fy, fz = map(math.sin(s[4]), 0, -math.cos(s[4]))
  local ex, ey, ez = map(s[1] + math.sin(s[4]) * EYE_FWD, s[2] + EYE_UP, s[3] - math.cos(s[4]) * EYE_FWD)
  local ux, uy, uz = map(0, 1, 0)
  return { hx, hy, hz }, { fx, fy, fz }, { ex, ey, ez }, { ux, uy, uz }
end

-- The seat in crew.lua's SEATS convention (part frame; yaw 0 = the part's +X,
-- about its +Y): what WS1's dolls are placed by.
function crewSeat(def, slot)
  local s = def and def.seats[slot]
  if not s then return nil end
  local h, f = seatInPart(def, slot)
  return { x = h[1], y = h[2], z = h[3], yaw = math.atan2(-f[3], f[1]) }
end

-- ── state ──────────────────────────────────────────────────────────────────
local iv = {}            -- [uid] = { node, def, id, want, lamps_on }
local cur_v = nil        -- the craft the interiors belong to (a controller handle)
local cur_id = nil       -- … and its node's id: handles are fresh per lookup, ids are not
local need_t = -10
view = nil               -- { v, uid, slot }
local hidden = {}        -- nodes we hid for the seat view: { node, was }
local parked = {}        -- [node] = layer it had before we parked it
local stand = { id = nil, node = nil, want = false, anim = nil, model = nil }

local function now() return time or 0 end

local function vid(v) return v and v.node and v.node.valid ~= false and v.node.id or nil end
local function same(v) return v ~= nil and vid(v) == cur_id end

function need(v)
  if vid(v) ~= cur_id or not v then
    for uid in pairs(iv) do
      local e = iv[uid]
      if e.node and e.node.valid ~= false and destroy then destroy(e.node) end
      iv[uid] = nil
    end
    cur_id = vid(v)
  end
  cur_v = v
  need_t = now()
end

local function set_layer(n, layer, depth)
  if not (n and n.valid ~= false) or (depth or 0) > 6 then return end
  pcall(function() n.layer = layer end)
  for _, c in ipairs(n:children() or {}) do set_layer(c, layer, (depth or 0) + 1) end
end

local function find_child(n, name, depth)
  if not (n and n.valid ~= false) or (depth or 0) > 4 then return nil end
  for _, c in ipairs(n:children() or {}) do
    if c.name == name then return c end
    local f = find_child(c, name, (depth or 0) + 1)
    if f then return f end
  end
  return nil
end

-- Every slot of every closed crew part on craft v, in stack order.
function closedSeats(v)
  local out = {}
  local C = ref("crew")
  if not (v and C) then return out end
  local map = C.seatMap and C.seatMap(v) or {}
  for _, s in ipairs(map) do
    local rec = v.partRec and v.partRec(s.uid)
    if rec and DEFS[rec.id] and not s.open then
      out[#out + 1] = { uid = s.uid, slot = s.slot, id = s.taken, label = s.label, part = rec.id, command = s.command }
    end
  end
  return out
end

function interiorsOf(v)
  if not same(v) then return {} end
  return iv
end

-- The part's world frame this frame: origin, and its X, Y, Z axes. The
-- craft's axes and origin from partFrameNow (what the dolls ride, the same
-- to the millimetre as the drawn pose in lateUpdate), turned by the part's
-- own blueprint rotation (YXZ, the project's convention).
function partFrame(v, uid)
  if not (v and v.partFrameNow) then return nil end
  local ok, F = pcall(v.partFrameNow, uid, true)
  if not ok or not F then return nil end
  local d = v.partRec and v.partRec(uid) or {}
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  -- the part's local axes in the craft frame
  local lx = { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz }
  local ly = { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz }
  local lz = { sy * cx, -sx, cy * cx }
  local function W(l) return vec3(F.rx * l[1] + F.ux * l[2] + F.zx * l[3], F.ry * l[1] + F.uy * l[2] + F.zy * l[3],
                                  F.rz * l[1] + F.uz * l[2] + F.zz * l[3]) end
  return vec3(F.ox, F.oy, F.oz), W(lx), W(ly), W(lz)
end

local function at(o, X, Y, Z, p) return o + X * p[1] + Y * p[2] + Z * p[3] end

-- ROOM SPACE. The rooms are bigger than their hulls, so two crew parts stacked
-- on one craft would have overlapping rooms: from a Crew Cabin's couch you
-- would see the Pod Mk2's floor above it at chest height. So every room is
-- kept in a space of its own, ROOM_AWAY metres UP the craft from its part
-- (each a further ROOM_STEP), where nothing else on the `interior` layer is
-- and nothing shades it from the sun. Not far: down the craft is underground,
-- in the terrain's shadow, and hundreds of metres away is past the sun's
-- shadow cascades, which read as shadow (both made the portraits dark). While
-- the seat view is up, the other rooms and their crew are put away (not
-- drawn), or a canopy would show them hanging in the sky;
-- and only the room the seat view is in sits at its part, so the sun reaches
-- it through its windows the way it reaches the hull. Only interior cameras
-- draw the rooms, so where they stand is otherwise invisible; dolls ride
-- their room (dollPose).
ROOM_AWAY, ROOM_STEP = 30.0, 8.0
local room_index = {}          -- [uid] = k (1…), in spawn order
local room_next = 0
function roomFrame(v, uid)
  local o, X, Y, Z = partFrame(v, uid)
  if not o then return nil end
  if view and view.uid == uid and same(view.v) then return o, X, Y, Z end
  local k = room_index[uid]
  if not k then room_next = room_next + 1; k = room_next; room_index[uid] = k end
  return o + Y * (ROOM_AWAY + ROOM_STEP * k), X, Y, Z
end

function seatFrame(v, uid, slot)
  local d = v and v.partRec and v.partRec(uid)
  local def = d and DEFS[d.id]
  if not def then return nil end
  local o, X, Y, Z = roomFrame(v, uid)
  if not o then return nil end
  local h, f, _, u = seatInPart(def, slot)
  if not h then return nil end
  local up, fwd = (X * u[1] + Y * u[2] + Z * u[3]), (X * f[1] + Y * f[2] + Z * f[3])
  return at(o, X, Y, Z, h), up, fwd, fwd:cross(up)
end

-- The seat's eye: position and the head's right/up/back (looking ahead).
function eyeOf(v, uid, slot)
  local d = v and v.partRec and v.partRec(uid)
  local def = d and DEFS[d.id]
  if not def then return nil end
  local o, X, Y, Z = roomFrame(v, uid)
  if not o then return nil end
  local _, f, e, u = seatInPart(def, slot)
  if not e then return nil end
  local up, fwd = (X * u[1] + Y * u[2] + Z * u[3]), (X * f[1] + Y * f[2] + Z * f[3])
  local right = fwd:cross(up)
  return at(o, X, Y, Z, e), right, up, fwd * -1
end

-- The main camera's eye for the seat view: inside the HULL, at its window.
function mainEye(v, uid)
  local d = v and v.partRec and v.partRec(uid)
  local def = d and DEFS[d.id]
  if not def then return nil end
  local o, X, Y, Z = partFrame(v, uid)
  if not o then return nil end
  return at(o, X, Y, Z, def.eye_main)
end

-- An open seat's rider: the eye just in front of their face and their head's
-- right/up/back. From the seat PART's own drawn frame, the frame
-- command_seat.lua seats them by (the seat faces its +X; the rider sits
-- SIT_FORWARD ahead of its centre, hips 0.04 m under it, eyes EYE_UP over
-- the hips), so it needs no bone and no guess at which way they face.
-- `n` (the rider) is optional: it is only checked for being there.
SIT_FORWARD, FACE_CLEAR = 0.20, 0.10
function riderEye(v, uid, n)
  local vn = v and v.node
  if not (vn and vn.valid ~= false and v.uidOfNode) then return nil end
  local pn = nil
  for _, c in ipairs(vn:children() or {}) do
    if v.uidOfNode(c) == uid then pn = c break end
  end
  if not (pn and pn.worldPos and pn.worldRight) then return nil end
  local P, fx, Y = pn.worldPos, pn:worldRight(), pn:worldUp()
  local d = v.partRec and v.partRec(uid)
  local sf = (d and d.id == "saddle") and 0.0 or SIT_FORWARD
  local hip = P + fx * sf - Y * 0.04
  local eye = hip + Y * EYE_UP + fx * (EYE_FWD + FACE_CLEAR)
  return eye, fx:cross(Y), Y, fx * -1
end

-- ── spawning and placing ───────────────────────────────────────────────────
local function spawn_iva(uid, def)
  local e = { def = def, node = nil, spawning = true }
  iv[uid] = e
  local ok = pcall(spawn, def.prefab, nil, function(n)
    e.spawning = false
    if iv[uid] ~= e then if n and n.valid ~= false then destroy(n) end return end
    e.node = n
    set_layer(n, LAYER)
    e.basis = find_child(n, "Basis")
    e.lamps = {}
    for k = 1, def.lamps or 0 do e.lamps[k] = find_child(n, "Lamp" .. k) end
    e.selfs = {}
    for k = 1, #def.seats do e.selfs[k] = find_child(n, "Self" .. k) end
    e.shell = find_child(n, "Shell")
  end)
  if not ok then iv[uid] = nil end
end

local function place(v, uid, e)
  local n = e.node
  if not (n and n.valid ~= false) then return end
  local o, X, Y, Z = roomFrame(v, uid)
  if not o then n.visible = false return end
  n.pos = o
  n:setUp(Y, Z * -1)
end

-- n lamps on (the first n), the rest off.
local function lamps(e, n)
  if e.lamps_on == n then return end
  e.lamps_on = n
  for k, l in ipairs(e.lamps or {}) do
    if l and l.valid ~= false then l.enabled = k <= n end
  end
end

-- ── the dolls on the interior layer ────────────────────────────────────────
-- Every seated doll in a CLOSED part goes on `interior` and is shown (the
-- main camera never draws the layer); an open seat's rider stays in the
-- world. Dolls are WS1's (crew.lua / crew_body.lua): this only re-layers.
local doll_layer = {}     -- [node id] = layer we set
local placed_ids = {}     -- dolls place_dolls seats in the controlled craft's rooms (it layers them)
local function layer_dolls()
  local C = ref("crew")
  if not (C and C.roster and C.dollOf) then return end
  C.showInterior = true
  for _, r in ipairs(C.roster()) do
    if r.status == "aboard" then
      local n = C.dollOf(r.id)
      if n and n.valid ~= false and not placed_ids[n.id] then
        local p = C.dollPose and C.dollPose(r.id)
        local want = (p and p.open) and "Default" or LAYER
        if parked[n] then want = OFF end
        if doll_layer[n.id] ~= want then
          set_layer(n, want)
          doll_layer[n.id] = want
        end
      end
    end
  end
end

-- Where a seated doll in a CLOSED part goes this frame, in crew.dollPose's
-- shape (crew.lua asks this first, so its dolls sit in their room).
function dollPose(v, uid, slot)
  local hip, up, fwd = seatFrame(v, uid, slot)
  if not hip then return nil end
  return { x = hip.x, y = hip.y, z = hip.z, ux = up.x, uy = up.y, uz = up.z, fx = fwd.x, fy = fwd.y, fz = fwd.z,
           open = false, v = v, uid = uid, visible = true }
end

-- ── the avatar's stand-in ──────────────────────────────────────────────────
-- The member at the controls is the hidden `Astronaut` (crew.lua §4.1, as
-- built): they have no doll. Their portrait and the other seats' view of
-- them need one, so a CrewDoll (unbound: its crew_body idles) is seated
-- here, posed like crew_body poses a seated doll.
local SEAT_RIG = { foot_out = 0.42, foot_down = 0.55, foot_side = 0.12, hand_out = 0.18, hand_side = 0.26 }
function standIn() return stand.node end

-- Seat a doll node at hip/up/fwd/right: the node on the hip, facing fwd, its
-- AstroModel turned to face the node's -Z, feet on the footrest and hands
-- on the armrests by IK (crew_body.lua's seated pose).
local function seat_pose(n, model, anim, hip, up, fwd, right)
  n.pos = hip
  n:setUp(up, fwd)
  if model and model.valid ~= false then model.yaw, model.pitch, model.roll = math.pi, 0, 0 end
  if not anim then return end
  local function Pt(o, u, s) return hip + fwd * o + up * u + right * s end
  for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
    local nm, sg = side[1], side[2]
    pcall(function()
      anim:reach("Foot." .. nm, Pt(SEAT_RIG.foot_out, -SEAT_RIG.foot_down, sg * SEAT_RIG.foot_side),
        { pole = Pt(1.2, 0.0, sg * SEAT_RIG.foot_side) })
      anim:reach("Hand." .. nm, Pt(SEAT_RIG.hand_out, -0.12, sg * SEAT_RIG.hand_side), { pole = Pt(-0.3, -0.1, sg * 0.6) })
    end)
  end
end

-- The seated dolls of the controlled craft's closed parts, placed here too,
-- every lateUpdate, at THIS interior's seats: the room and its crew come
-- from the same frame, so a portrait never films an empty couch. (crew.lua
-- places them as well; a doll it has not managed to bind yet — a script's
-- handle is empty the frame its node spawns — would otherwise wait at the
-- spawn point.)
local doll_rig = {}       -- [node id] = { model, anim }
posed = { dolls = 0, rigged = 0 }   -- published for probes
local function place_dolls(v)
  posed.dolls, posed.rigged = 0, 0
  placed_ids = {}
  local C = ref("crew")
  if not (C and C.dollOf) then return end
  for _, s in ipairs(closedSeats(v)) do
    local n = s.id and C.dollOf(s.id)
    if n and n.valid ~= false then
      local hip, up, fwd, right = seatFrame(v, s.uid, s.slot)
      if hip then
        local rig = doll_rig[n.id]
        if not rig then
          rig = {}
          for _, c in ipairs(n:children() or {}) do if c.name == "AstroModel" then rig.model = c end end
          if rig.model then
            local ok, an = pcall(function() return rig.model:animator() end)
            rig.anim = ok and an or nil
          end
          doll_rig[n.id] = rig
        end
        if not n.visible then n.visible = true end
        if rig.model and not rig.model.visible then rig.model.visible = true end
        -- in the seat view only the room you are in is drawn, without the
        -- one whose eyes you look out of
        local lay = LAYER
        if view and (view.uid ~= s.uid or view.slot == s.slot) then lay = OFF end
        if doll_layer[n.id] ~= lay then set_layer(n, lay); doll_layer[n.id] = lay end
        placed_ids[n.id] = true
        seat_pose(n, rig.model, rig.anim, hip, up, fwd, right)
        posed.dolls = posed.dolls + 1
        if rig.anim then posed.rigged = posed.rigged + 1 end
      end
    end
  end
end

local function stand_in(v)
  local C = ref("crew")
  local id = C and C.activeId and C.activeId()
  local seat = nil
  if id and v and v.crewAboard then
    for _, s in ipairs(closedSeats(v)) do if s.id == id then seat = s end end
  end
  if not seat then
    if stand.node and stand.node.valid ~= false then stand.node.visible = false end
    stand.seat = nil
    return
  end
  stand.seat = seat
  if not (stand.node and stand.node.valid ~= false) then
    if stand.spawning then return end
    stand.spawning = true
    pcall(spawn, "CrewDoll", nil, function(n)
      stand.spawning = false
      stand.node = n
      for _, c in ipairs(n:children() or {}) do
        if c.name == "AstroModel" then stand.model = c end
      end
      if stand.model then
        local ok, an = pcall(function() return stand.model:animator() end)
        stand.anim = ok and an or nil
      end
      set_layer(n, LAYER)
    end)
    return
  end
  local n = stand.node
  local hip, up, fwd, right = seatFrame(v, seat.uid, seat.slot)
  if not hip then n.visible = false return end
  n.visible = true
  if stand.model then stand.model.visible = true end
  local want = (view and (view.uid ~= seat.uid or view.slot == seat.slot)) and OFF or LAYER
  if stand.layer ~= want then set_layer(n, want); stand.layer = want end
  seat_pose(n, stand.model, stand.anim, hip, up, fwd, right)
end

-- ── the seat view ──────────────────────────────────────────────────────────
local function part_node(v, uid)
  local vn = v and v.node
  if not (vn and vn.valid ~= false and v.uidOfNode) then return nil end
  for _, c in ipairs(vn:children() or {}) do
    if v.uidOfNode(c) == uid then return c end
  end
  return nil
end

local function hide_tree(n, depth)
  if not (n and n.valid ~= false) or depth > 5 then return end
  hidden[#hidden + 1] = { node = n, was = n.visible }
  n.visible = false
  for _, c in ipairs(n:children() or {}) do hide_tree(c, depth + 1) end
end

local function unhide()
  for _, h in ipairs(hidden) do
    if h.node and h.node.valid ~= false then h.node.visible = h.was ~= false end
  end
  hidden = {}
end

local function unpark()
  for n, was in pairs(parked) do
    if n and n.valid ~= false then set_layer(n, was) end
    if n and n.id then doll_layer[n.id] = nil end
  end
  parked = {}
end

function clearView()
  unhide()
  unpark()
  if view then
    local e = iv[view.uid]
    if e and e.selfs and e.selfs[view.slot] and e.selfs[view.slot].valid ~= false then e.selfs[view.slot].enabled = false end
    if e and e.shell and e.shell.valid ~= false then e.shell.castShadow = false end
  end
  view = nil
end

function setView(v, uid, slot)
  clearView()
  if not v then return false end
  need(v)
  view = { v = v, uid = uid, slot = slot }
  hide_tree(part_node(v, uid), 0)
  -- the occupant's doll (another member) is who we are looking out of
  local C = ref("crew")
  for _, s in ipairs(closedSeats(v)) do
    if s.uid == uid and s.slot == slot and s.id and C and C.dollOf then
      local dn = C.dollOf(s.id)
      if dn and dn.valid ~= false then
        parked[dn] = doll_layer[dn.id] or LAYER
        set_layer(dn, OFF)
        doll_layer[dn.id] = OFF
      end
    end
  end
  return true
end

-- Park any node (the open-seat rider's helmet) on the layer nobody draws,
-- until clearView.
function park(n)
  if not (n and n.valid ~= false) or parked[n] then return end
  parked[n] = n.layer or "Default"
  set_layer(n, OFF)
end

-- ── the manager ────────────────────────────────────────────────────────────
local dolls_t = -10
function lateUpdate(node, dt)
  local live = cur_v ~= nil and now() - need_t < 0.5 and cur_v.node and cur_v.node.valid ~= false
  if view and not (same(view.v) and live) then clearView() end
  if not live then
    if next(iv) then need(nil) end
    if stand.node and stand.node.valid ~= false then stand.node.visible = false end
    return
  end
  local v = cur_v
  local want = {}
  for _, s in ipairs(closedSeats(v)) do
    local rec = v.partRec(s.uid)
    want[s.uid] = DEFS[rec.id]
  end
  for uid, e in pairs(iv) do
    if not want[uid] then
      if e.node and e.node.valid ~= false then destroy(e.node) end
      iv[uid] = nil
    end
  end
  for uid, def in pairs(want) do
    local e = iv[uid]
    if not e then spawn_iva(uid, def)
    elseif e.node then
      place(v, uid, e)
      local vw = view and view.uid == uid
      local shown = (view == nil) or vw
      if e.node.visible ~= shown then e.node.visible = shown end
      -- the cabin lamps: the faces in the portraits need them whatever the
      -- sun is doing. A lamp is not stopped by walls drawn on another layer,
      -- but a room away in its own space has nothing near it to spill onto;
      -- the room you sit in has its hull round it
      -- (a room only filmed by the portraits keeps its first lamp: each lamp
      -- is paid for in every render that reaches it)
      lamps(e, vw and 99 or 1)
      for k, sn in ipairs(e.selfs or {}) do
        local on = vw and view.slot == k
        if sn and sn.valid ~= false and sn.enabled ~= on then sn.enabled = on end
      end
      if e.shell and e.shell.valid ~= false then
        local cs = vw == true
        if e.shell.castShadow ~= cs then e.shell.castShadow = cs end
      end
    end
  end
  if now() - dolls_t > 0.25 then
    dolls_t = now()
    layer_dolls()
  end
  place_dolls(v)
  stand_in(v)
end
