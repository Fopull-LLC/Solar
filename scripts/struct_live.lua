-- STRUCT_LIVE — anything placed in the world works (sandbox plan S2 §2;
-- docs/base-building.md §13): the VAB parts an Engineer places with the
-- Build Kit (parts_kit FITTINGS: pods, seats, the cockpit, lockers, lights,
-- batteries, panels, isotope cells) are ONE ANCHORED STRUCTURE VESSEL per
-- structure, in the `structure` control mode. Walls, floors and every other
-- piece stay static prefabs (structures.lua): zero a tick, batched draws.
--
-- On the Build Kit node (scenes/system.ron).
--
--   THE VESSEL  the fleet's own rebuild path, as a stand's Commission
--               (craft_stand.lua): a `Vessel` root spawned at the structure's
--               origin with its axes (so the blueprint's x, y, z ARE the
--               structure frame), the live parts handed over as
--               `dock.handoff.<id>` with `held` and `structure = sid`, each
--               part spawned as its child, then assembly.rebuild and
--               setAnchored(true). Its vessel_controller wakes in structure
--               mode: no clamp release (SPACE), no recovery, no navball, off
--               the fleet board (`standHeld`), but its seats, hatches, IVA,
--               lockers, lights, electronics and part menus are a craft's. F
--               boards a placed cockpit or pod; a locker's Take / Put are the
--               part menu's; a light switches from its menu or the Lights
--               group (Y) from the seat.
--   THE PIN     held on its structure as the planet moves: each frame while
--               the crew is within HOLD_R, the body-relative origin is
--               re-applied (assembly.teleport), as a stand holds its craft.
--   REBUILT     when the structure's live parts change (one placed, one taken
--               down): the old vessel goes and a new one is made, its parts'
--               state carried over (a locker keeps its number and contents,
--               a battery its charge). A structure with no live part has no
--               vessel. Spawned only while structures.isLive(sid).
--   STATE       every SAVE_EVERY s and before a rebuild, the vessel's records
--               (fleetParts) go to the save as `slive.<sid>` = { st = { [uid]
--               = part state }, charge } — what the next build starts with.
--   THE GRID    a battery, a panel or a cell placed live is a member of the
--               base grid by its record (parts_kit gives it a `power` figure
--               base_grid reads), and it counts ONCE: the vessel carries it
--               without that module (GRID_MODS); a floodlight's and a crewed
--               part's draw are grid loads, their modules here draw nothing,
--               and the vessel's own cells are topped up from the grid every
--               SAVE_EVERY s while it is up (grid_up).
--
-- COST. A structure with no live part: nothing. With some: the vessel's own
-- dormant controller plus one teleport a frame while the crew is near.
--
-- Probes: vessels(), vesselOf(sid), bpFor(sid), changed(sid), rebuildNow(sid).

HOLD_R = 600.0
SAVE_EVERY = 5.0

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function V(x, y, z) return { x = x, y = y, z = z } end
local function defOf(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end

local L = {}          -- sid → { node, sig, phase, placed, total, relv, t0, saved_t }
local dirty = {}      -- sid → true: look again
local ver = -1
local sigs = {}       -- sid → the live parts' signature, as the records last stood

function vessels() return L end
function vesselOf(sid) local e = L[sid]; return e and valid(e.node) and e.node or nil end
function controllerOf(sid)
  local n = vesselOf(sid)
  if not n then return nil end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.id == n.id then return v end
  end
  return nil
end
function changed(sid) if sid then dirty[sid] = true end end

-- ── the blueprint (pure: what make_blueprint would have written) ─────────────
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
local CMD = { crewed = 2, probe = 1 }
-- COUNTED ONCE (S2 follow-up): a battery, panel or cell placed live is the
-- base grid's (parts_kit.LIVE_POWER, base_grid reads it by record), so the
-- vessel carries it WITHOUT that module; a floodlight's and a crewed part's
-- draw are grid loads, so the vessel's modules draw nothing. (Before, a placed
-- battery was 150 EC in the grid and another 150 in the vessel.)
GRID_MODS = { battery = true, solar = true, rtg = true }
local function grid_mods(mods, pw)
  if not pw or type(mods) ~= "table" then return mods end
  local out = {}
  for _, m in ipairs(mods) do
    if pw.kind ~= "load" and GRID_MODS[m.type] then
      -- (the grid holds it)
    else
      local c = {}
      for k, v in pairs(m) do c[k] = v end
      if pw.kind == "load" and c.draw then c.draw = 0 end
      out[#out + 1] = c
    end
  end
  return out
end
-- The live parts of `rec` as launch-format blueprint parts, in the structure
-- frame. `saved` = { [uid] = st } carried over; El = the electronics rulebook.
-- → bp { parts, root, v = 2, name } | nil (no live part)
function blueprintOf(rec, defs, saved, El)
  local parts = {}
  local root, rank = nil, -1
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.live and d.reg then
      local R = d.reg
      local mods = R.mods
      if El and El.deriveMods then mods = El.deriveMods(R, R.mods) end
      mods = grid_mods(mods, d.power)
      if El and El.encodeMods then mods = El.encodeMods(mods) end
      local onGrid = d.power ~= nil and d.power.kind ~= "load"
      local rec_ = {
        uid = p.uid, id = d.vab, prefab = R.prefab, label = R.label,
        x = p.x or 0, y = (p.y or 0) + (d.seat or 0), z = p.z or 0,
        yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0,
        parent = 0, att = "", sym = 0, stage = 0,
        h = R.h, mass = R.mass, cost = R.cost, kind = R.kind, rx = R.rx or 0, rz = R.rz or 0,
        strength = R.strength or 0, maxq = 0, thrust = 0, burn = 0, fuel = 0, ve = 0, fuel_t = 0,
        decouple = 0, legs = 0, radial = 0, chute = 0, comms = 0, aero = 0, af = R.af,
        power = (R.power and not onGrid) and 1 or 0, solar = (R.solar and not onGrid) and 1 or 0,
        ec = onGrid and 0 or (R.ec or 0), gen = onGrid and 0 or (R.gen or 0),
        dock = 0, rcs = 0, rcs_thrust = 0, cargo = 0, store = R.store or 0,
        front = 0, wheel = "", fairing = 0, seat = R.seat and 1 or 0, robo = "", claw = 0, mir = "",
        mods = mods,
      }
      if saved and saved[p.uid] then rec_.st = copy(saved[p.uid]) end
      parts[#parts + 1] = rec_
      local rk = CMD[R.kind] or 0
      if rk > rank then root, rank = p.uid, rk end
    end
  end
  if #parts == 0 then return nil end
  for _, d in ipairs(parts) do if d.uid ~= root then d.parent = root end end
  return { parts = parts, root = root, v = 2, name = rec.n or ("Structure " .. tostring(rec.id)) }
end
-- The live parts' signature: what makes a rebuild needed.
function signatureOf(rec, defs)
  local t = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.live then
      t[#t + 1] = string.format("%d:%s:%.2f:%.2f:%.2f:%.3f:%.3f:%.3f", p.uid, p.id, p.x or 0, p.y or 0, p.z or 0, p.yaw or 0, p.pitch or 0, p.roll or 0)
    end
  end
  table.sort(t)
  return table.concat(t, "|")
end

-- ── the saved state ─────────────────────────────────────────────────────────
local function skey(sid) return "slive." .. tostring(sid) end
local function save_state(sid, e)
  -- (only a vessel that has assembled and run a moment: one dropped while
  -- still coming up — three fittings placed in a row — has no state yet, and
  -- saving its zero charge emptied the next one's batteries)
  if not (e and e.phase == "held" and e.ready_t and now() - e.ready_t > 1.0) then return end
  local v = e and controllerOf(sid)
  if not (v and v.fleetParts) then return end
  local ok, fp = pcall(v.fleetParts)
  if not (ok and fp and fp.parts) then return end
  local El = ref("electronics")
  local st = {}
  for _, d in ipairs(fp.parts) do
    local r = (El and El.packRecord) and El.packRecord(d) or d
    if d.uid and type(r.st) == "table" then st[tostring(d.uid)] = copy(r.st) end
  end
  if save and save.set then save.set(skey(sid), { st = st, charge = fp.charge }) end
end
local function saved_of(sid)
  local s = save and save.get and save.get(skey(sid))
  if type(s) ~= "table" then return nil, nil end
  local out = {}
  for k, v in pairs(s.st or {}) do out[tonumber(k) or k] = v end
  return out, s.charge
end

-- ── spawning ────────────────────────────────────────────────────────────────
local function drop(sid, keep_state)
  local e = L[sid]
  if not e then return end
  if keep_state then save_state(sid, e) end
  local ST = ref("structures")
  for _, x in ipairs(e.placed or {}) do if ST and ST.unadopt then ST.unadopt(x.part) end end
  if valid(e.node) then
    local fo = ref("flight_ops")
    if fo and fo.forgetNodes then pcall(fo.forgetNodes, { e.node.id }) end
    pcall(e.node.destroy, e.node)
  end
  L[sid] = nil
end

local function build(rec)
  local sid = rec.id
  local El = ref("electronics")
  local saved, charge = saved_of(sid)
  local bp = blueprintOf(rec, defOf, saved, El)
  if not bp then return end
  local b = space and space.body and space.body(rec.b)
  local SN = ref("kit_snap") or ref("base_snap")
  if not (b and spawn and assembly and SN) then return end
  local fr = SN.frameOf(rec)
  local e = { sig = signatureOf(rec, defOf), phase = "assembling", placed = {}, total = #bp.parts, t0 = now(),
              relv = V(rec.x, rec.y, rec.z), body = rec.b, saved_t = now() }
  L[sid] = e
  local X, U, Z = fr.R, fr.U, fr.F
  spawn("Vessel", vec3(b.x + rec.x, b.y + rec.y, b.z + rec.z), function(v)
    if L[sid] ~= e then v:destroy() return end
    v:setUp(vec3(U.x, U.y, U.z), vec3(-Z.x, -Z.y, -Z.z))
    e.node = v
    pcall(function() v.name = bp.name end)
    save.set("dock.handoff." .. tostring(v.id or 0),
      { parts = bp.parts, charge = charge or 1e9, lockout = 2.0, name = bp.name, flown = false, held = true, structure = sid })
    local b2 = space.body(rec.b) or b
    for _, d in ipairs(bp.parts) do
      local px = b2.x + e.relv.x + X.x * d.x + U.x * d.y + Z.x * d.z
      local py = b2.y + e.relv.y + X.y * d.x + U.y * d.y + Z.y * d.z
      local pz = b2.z + e.relv.z + X.z * d.x + U.z * d.y + Z.z * d.z
      spawn(d.prefab, vec3(px, py, pz), function(part)
        if L[sid] ~= e or not valid(v) then part:destroy() return end
        part.x, part.y, part.z = d.x, d.y, d.z
        part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
        if part.addTag then part:addTag("craftpart") end
        local ST = ref("structures")
        if ST and ST.adopt then ST.adopt(part, sid, d.uid) end
        e.placed[#e.placed + 1] = { part = part, d = d }
        if #e.placed == e.total then
          assembly.rebuild(v)
          assembly.setAnchored(v, true)
          e.phase, e.ready_t = "held", now()
          e.saved_t = now() - SAVE_EVERY + 2.0   -- (a new locker's number is saved soon)
        end
      end, v)
    end
  end)
end

function rebuildNow(sid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  drop(sid, true)
  if rec and ST.isLive and ST.isLive(sid) then build(rec) end
end

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("struct_live")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  L, dirty, ver, sigs = {}, {}, -1, {}
end

local check_t = -10
-- Is structure sid on a real base grid that is up (not short with its battery flat)?
function grid_up(sid)
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  if not g then return false end
  local M = BG.model and BG.model(g.id)
  if not (#(g.bases or {}) > 0 or (M and ((M.sources or 0) > 0 or (M.C or 0) > 0))) then return false end
  local s = BG.status and BG.status(g.id)
  return not (s and (s.short or 0) > 0 and (s.stored or 0) <= 0)
end
local function crew_far(e)
  local a = find and find("Astronaut")
  if not valid(a) then return false end
  local b = space.body(e.body)
  if not b then return true end
  return math.sqrt((b.x + e.relv.x - a.x) ^ 2 + (b.y + e.relv.y - a.y) ^ 2 + (b.z + e.relv.z - a.z) ^ 2) > HOLD_R
end

function update(node, dt)
  local ST = ref("structures")
  if not ST then return end
  local t = now()
  -- what to (re)build: on a change of the records, and once a second
  -- the live parts' signatures are worked out only when the records change
  -- (a scan of every part of every structure once a second cost 1.4 ms a
  -- frame at 6,000 pieces); the once-a-second pass reads only the cache and
  -- who is streamed in
  local changed_ = ST.version ~= ver or next(dirty) ~= nil
  if changed_ then
    ver = ST.version
    sigs = {}
    for _, rec in ipairs(ST.list()) do sigs[rec.id] = signatureOf(rec, defOf) end
  end
  if changed_ or t - check_t > 1.0 then
    check_t = t
    local seen = {}
    for _, rec in ipairs(ST.list()) do
      seen[rec.id] = true
      local live = ST.isLive and ST.isLive(rec.id)
      local e = L[rec.id]
      if live then
        local sig = sigs[rec.id] or ""
        if sig == "" then
          if e then drop(rec.id, false); if save and save.set then save.set(skey(rec.id), false) end end
        elseif not e or (e.sig ~= sig and e.phase == "held") then
          if e then drop(rec.id, true) end
          build(rec)
        end
      elseif e then
        drop(rec.id, true)
      end
    end
    for sid in pairs(L) do if not seen[sid] then drop(sid, false) end end
    dirty = {}
  end
  if next(L) == nil then return end
  for sid, e in pairs(L) do
    if e.node and not valid(e.node) then
      L[sid] = nil
    elseif e.phase == "assembling" and e.node and now() - e.t0 > 20 and #e.placed > 0 then
      assembly.rebuild(e.node)
      assembly.setAnchored(e.node, true)
      e.phase, e.ready_t = "held", now()
    elseif e.phase == "held" and e.node then
      local b = space.body(e.body)
      if b and not crew_far(e) then
        local i = assembly.info(e.node)
        if i and not i.anchored then assembly.setAnchored(e.node, true) end
        assembly.teleport(e.node, vec3(b.x + e.relv.x, b.y + e.relv.y, b.z + e.relv.z))
      end
      if t - (e.saved_t or 0) >= SAVE_EVERY then
        e.saved_t = t
        -- (the vessel's own cells, a pod's battery, are kept full from the
        -- base grid while it is up: their draw is the grid's load)
        if grid_up(sid) then
          local v = controllerOf(sid)
          if v and v.elecSetCharge then pcall(v.elecSetCharge, 1e9) end
        end
        save_state(sid, e)
      end
    end
  end
end

-- (a save is written: the parts' state with it)
function saveNow() for sid, e in pairs(L) do save_state(sid, e) end end
