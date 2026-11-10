-- LOGIC NET — the scene half of a base's signals (sandbox plan S8,
-- work/sandbox/PLAN.md §3.4; docs/base-building.md §18). The rules are
-- logic.lua's (pure).
--
-- On the Build Kit node (scenes/system.ron) beside fluid_net and room_air.
--
--   THE NETWORK  every piece with `lg` (parts_kit LOGIC, and the terminals of
--                doors, airlocks, lights, pumps, valves, breakers, reactor
--                pumps and consoles, life support) is a node; every Signal
--                Cable is a wire from an output pin to an input pin; every
--                radio receiver hears each transmitter on its channel within
--                RADIO_R. Built again only when the logic SIGNATURE changes
--                (the logic pieces, their settings, the cables), debounced,
--                never in a frame. Its state (latches, counters, levers,
--                timers, the ladders' relays) is kept by piece across a
--                rebuild and in the save.
--   THE CLOCK    the network is stepped on the agency clock, at most every
--                EVERY s (10 Hz) and only when something is due or changed:
--                a timer's event, a button pressed, a reading crossing its
--                setpoint. Sensors are read every SENSE s; a reading that
--                doesn't cross anything marks nothing. Idle, nothing is
--                evaluated. A load catches it up in one advance (logic.lua:
--                events in time order, exactly).
--   DEVICES      what the network asks of a piece, on change: a door held
--                open or locked (kit_live asks doorCmd every step), an
--                airlock asked to cycle to a door (room_air.requestDoor while
--                the signal is on), a light, a pump, a valve, a breaker
--                (base_power.setBreaker(…, "logic")), a reactor pump, SCRAM
--                and the power setback (reactor_plant), the O2 Generator and
--                the scrubber (room_air.setMachine), lamps and alarm beacons
--   SIGNAL CABLE laid pin to pin from its drum (field_builder hands the clicks
--                here as it does a Power Cable's to base_cable): a run in the
--                frame of the structure its first end is on, settled at
--                placement the way base_cable settles a power cable (a
--                catenary of its weight and a hand's pull, lying on the
--                floors, decks and ground under it: base_cable.settle), kept
--                in its record, drawn as one mesh per structure
--   READOUTS     the menus on every piece, the Ladder Controller's CRT and its
--                editor, the LOGIC overlay (F5 with the kit open): every
--                cable lit or dark with chevrons the way a lit signal runs,
--                each pin's lamp, each node's state and value
--
-- SAVE: lg.wires = { { id, b, a = { sid, uid, pin }, z = { … }, f (the frame's
-- structure), p = { x, y, z, … } (flat), len, t, cost } … }, lg.seq,
-- lg.st = logic.pack(state), lg.a (agency time). A piece's settings (setpoint,
-- mode, delay, channel, colour, code, the ladder's rungs as strings) are its
-- part state's `lp` and `prog`.
--
-- Probes: net(), state(), keyOf(sid, uid), press(sid, uid), setLever(sid,
-- uid, on), setParam(sid, uid, k, v), setProgram(sid, uid, list), program,
-- readout(sid, uid), out(sid, uid, pin), wires(), layWire(a, z), takeUp(id),
-- stepNow(), sampleNow(), pinWorld(sid, uid, pin), doorCmd, overlay,
-- overlayAlways, drawn, PROF, editorOpen(sid, uid), editor.

EVERY = 0.1
SENSE = 0.25
SOLVE_WAIT = 0.3
SAVE_EVERY = 5.0
RADIO_R = 2000
PULL = 3.0            -- N: the most a hand pulls a signal cable (a = PULL / (λ g))
SLACK = 0.35          -- a laid run's catenary a, as a share of its span (a slack lay)
PROF = { build_ms = 0, tick_ms = 0, sense_ms = 0, evals = 0, events = 0, nodes = 0, wires = 0, ticks = 0, osc = 0,
         -- (running sums, for a probe to difference over a window)
         evsum = 0, tsum = 0, sensesum = 0, paints = 0, paintsum = 0, lampsum = 0 }

overlay = false
overlayAlways = false
drawn = { lines = 0, labels = 0, rings = 0 }
lastLay = nil
pending = nil
preview = nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function LG() return ref("logic") end
local function say(s) if caption then pcall(caption, s) end if log then log("logic: " .. s) end end
local function snd(path, vol, x, y, z, dist)
  if not (audio and audio.play) then return nil end
  if x then local ok, h = pcall(audio.play, path, x, y, z, { maxDistance = dist or 20, track = "SFX", volume = vol or 0.4 }); return ok and h or nil end
  local ok, h = pcall(audio.play, path, { track = "UI", volume = vol or 0.4 })
  return ok and h or nil
end
local function len3(x, y, z) return math.sqrt(x * x + y * y + z * z) end
function keyOf(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
-- the eye this frame (the ray through the middle of the view): rings face it
function eye_now()
  if not (camera and camera.screenRect and camera.screenToRay and camera.exists and camera.exists()) then return nil end
  local ok, x, y, w, h = pcall(camera.screenRect)
  if not ok or not w or w <= 0 then return nil end
  local ok2, ox, oy, oz = pcall(camera.screenToRay, x + w / 2, y + h / 2)
  if not ok2 or not ox then return nil end
  return { x = ox, y = oy, z = oz }
end
local function unkey(k) local a, b = tostring(k):match("^(%d+):(%d+)$"); return tonumber(a), tonumber(b) end

local function part_state(sid, uid)
  local ST = ref("structures")
  return ST and ST.partState and ST.partState(sid, uid) or nil
end
local function set_part_state(sid, uid, k, v)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for a, b in pairs(st) do t[a] = b end
  t[k] = v
  ST.setPartState(sid, uid, next(t) and t or nil)
end
local function part_of(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  if not rec then return nil end
  local p = ST.getPart and ST.getPart(sid, uid)
  if not p then for _, q in ipairs(rec.bp or {}) do if q.uid == uid then p = q end end end
  return rec, p, p and defs(p.id)
end

-- ── frames: a piece's pin in its structure's frame, in the body's ──────────
local function axes(p)
  local KS = ref("kit_snap")
  local up, fw
  if KS and KS.localAxes then up, fw = KS.localAxes(p.yaw or 0, p.pitch or 0, p.roll or 0)
  else
    local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
    up, fw = { 0, 1, 0 }, { s, 0, c }
  end
  local X = { up[2] * fw[3] - up[3] * fw[2], up[3] * fw[1] - up[1] * fw[3], up[1] * fw[2] - up[2] * fw[1] }
  return X, up, fw
end
-- a piece-frame point → its structure's frame
function pieceToLocal(p, x, y, z)
  local X, Y, Z = axes(p)
  return (p.x or 0) + X[1] * x + Y[1] * y + Z[1] * z, (p.y or 0) + X[2] * x + Y[2] * y + Z[2] * z, (p.z or 0) + X[3] * x + Y[3] * y + Z[3] * z
end
local function pin_def(d, name)
  for _, q in ipairs(d and d.lg and d.lg.pins or {}) do if q.n == name then return q end end
  return nil
end
-- structure frame ↔ body frame (kit_snap.frameOf; pure arithmetic)
local function frame(rec) local KS = ref("kit_snap"); return KS and KS.frameOf(rec) or nil end
local function to_body(fr, x, y, z)
  return fr.O.x + fr.R.x * x + fr.U.x * y + fr.F.x * z, fr.O.y + fr.R.y * x + fr.U.y * y + fr.F.y * z, fr.O.z + fr.R.z * x + fr.U.z * y + fr.F.z * z
end
local function to_local(fr, x, y, z)
  local dx, dy, dz = x - fr.O.x, y - fr.O.y, z - fr.O.z
  return dx * fr.R.x + dy * fr.R.y + dz * fr.R.z, dx * fr.U.x + dy * fr.U.y + dz * fr.U.z, dx * fr.F.x + dy * fr.F.y + dz * fr.F.z
end
-- a pin: → its structure-frame point, its body-frame point
function pinLocal(sid, uid, pin)
  local rec, p, d = part_of(sid, uid)
  local q = pin_def(d, pin)
  if not (rec and p and q) then return nil end
  return pieceToLocal(p, q.x, q.y, q.z)
end
function pinBody(sid, uid, pin)
  local rec = select(1, part_of(sid, uid))
  local x, y, z = pinLocal(sid, uid, pin)
  if not x then return nil end
  local fr = frame(rec)
  if not fr then return nil end
  return to_body(fr, x, y, z)
end
-- (probes, drawing) a pin's world point now: this frame's body read
function pinWorld(sid, uid, pin)
  local rec = select(1, part_of(sid, uid))
  local bx, by, bz = pinBody(sid, uid, pin)
  local b = rec and space and space.body and space.body(rec.b)
  if not (bx and b) then return nil end
  return b.x + bx, b.y + by, b.z + bz
end

-- ── the cable records ───────────────────────────────────────────────────────
local W = nil              -- id → record
local WORDER = {}
wversion = 0
local function wplain(r) return { id = r.id, b = r.b, a = r.a, z = r.z, f = r.f, p = r.p, len = r.len, t = r.t, cost = r.cost, h = r.h, sig = r.sig } end
local function wload()
  W, WORDER = {}, {}
  local L = save and save.get and save.get("lg.wires")
  for _, r in ipairs(type(L) == "table" and L or {}) do
    if type(r) == "table" and r.id and type(r.a) == "table" and type(r.z) == "table" then
      local rec = wplain(r)
      W[rec.id] = rec
      WORDER[#WORDER + 1] = rec.id
    end
  end
end
local function wensure() if not W then wload() end end
local function wsave()
  if not (save and save.set) then return end
  local L = {}
  for _, id in ipairs(WORDER) do L[#L + 1] = wplain(W[id]) end
  save.set("lg.wires", L)
end
function wires() wensure(); local o = {} for _, id in ipairs(WORDER) do o[#o + 1] = W[id] end return o end
function wire(id) wensure(); return W[id] end
local function wbump() wversion = wversion + 1 end
local function wseq() local n = (tonumber(save and save.get and save.get("lg.seq")) or 0) + 1; if save and save.set then save.set("lg.seq", n) end; return n end
function wiresAt(sid, uid)
  wensure()
  local out = {}
  for _, id in ipairs(WORDER) do
    local r = W[id]
    if (r.a.sid == sid and (uid == nil or r.a.uid == uid)) or (r.z.sid == sid and (uid == nil or r.z.uid == uid)) then out[#out + 1] = r end
  end
  return out
end

-- ── the settle: how a signal cable lies ─────────────────────────────────────
-- What holds a cable up under a station of its run (structure frame `fr` of
-- the cable): the tops of the floors, slabs, decks and blocks it passes over
-- (any structure on its world within reach, by record: no scene read), and
-- the ground sampled at laying (`h`). → { support y … } per station
local SUPPORT = { slab = true, floor = true, block = true, prop = true, hab = true, pipe = true, post = true }
local function supports_along(rf, A, B, n, hgr, skip)
  local ST = ref("structures")
  local S = {}
  for i = 0, n do S[i + 1] = (hgr and hgr[i + 1]) or -1e9 end
  if not (ST and ST.list) then return S end
  local frA = frame(rf)
  local cx, cz = (A[1] + B[1]) / 2, (A[3] + B[3]) / 2
  local reach = math.sqrt((A[1] - B[1]) ^ 2 + (A[3] - B[3]) ^ 2) / 2 + 8
  for _, rec in ipairs(ST.list()) do
    if rec.b == rf.b and type(rec.bp) == "table" then
      local fr = frame(rec)
      -- the other structure's frame in this one's (planets only translate:
      -- both frames are body-relative, and parallel this close)
      local ox, oy, oz = to_local(frA, fr.O.x, fr.O.y, fr.O.z)
      if (ox - cx) ^ 2 + (oz - cz) ^ 2 < (reach + 300) ^ 2 then
        local rx_, _, rz_ = to_local(frA, frA.O.x + fr.R.x, frA.O.y + fr.R.y, frA.O.z + fr.R.z)
        -- (its yaw relative to ours: its +X is (cos, 0, -sin) of it in our frame)
        local rel = math.atan2(-rz_, rx_)
        for _, p in ipairs(rec.bp) do
          local d = defs(p.id)
          if d and d.box and SUPPORT[d.snap or "block"] and (p.pitch or 0) == 0 and (p.roll or 0) == 0 and not d.film and not d.wire
             and not (skip and skip[keyOf(rec.id, p.uid)]) then
            -- the piece's place in the cable's frame (through the body frame)
            local bx, by, bz = to_body(fr, p.x or 0, p.y or 0, p.z or 0)
            local qx, qy, qz = to_local(frA, bx, by, bz)
            local yaw = (p.yaw or 0) + rel
            local c, s = math.cos(yaw), math.sin(yaw)
            local b = d.box
            local top = qy + b[4]
            if (qx - cx) ^ 2 + (qz - cz) ^ 2 < (reach + math.max(b[2] - b[1], b[6] - b[5])) ^ 2 then
              for i = 0, n do
                local f = i / n
                local sx, sz = A[1] + (B[1] - A[1]) * f, A[3] + (B[3] - A[3]) * f
                local dx, dz = sx - qx, sz - qz
                -- into the piece's own frame (yaw only)
                local ux, uz = dx * c - dz * s, dx * s + dz * c
                -- (only what is under the straight line between the pins holds it up:
                -- a ceiling over the run is no support; a cable through a wall is through its gland)
                local chord = A[2] + (B[2] - A[2]) * f
                if ux >= b[1] and ux <= b[2] and uz >= b[5] and uz <= b[6] and top <= chord + 0.02 then
                  if top > S[i + 1] then S[i + 1] = top end
                end
              end
            end
          end
        end
      end
    end
  end
  return S
end
-- The run between two structure-frame points A and B of cable frame rec
-- `rf`: stations along the straight line, the catenary settled on what is
-- under it (base_cable.settle), thinned (base_cable.thin). → pts { {x,y,z} },
-- length, the ground sampled { y … } (kept: a reload settles on it again)
function wirePath(rf, A, B, hgr, opts)
  opts = opts or {}
  local BC = ref("base_cable")
  local dx, dy, dz = B[1] - A[1], B[2] - A[2], B[3] - A[3]
  local D = math.sqrt(dx * dx + dz * dz)
  local L3 = math.sqrt(dx * dx + dy * dy + dz * dz)
  if D < 0.15 or not (BC and BC.settle and BC.thin) then
    return { { A[1], A[2], A[3] }, { B[1], B[2], B[3] } }, L3, hgr
  end
  local n = math.max(8, math.min(200, math.ceil(D / 0.1)))
  local ds = D / n
  -- the ground under it, once (at laying): the terrain's distance field
  if not hgr and opts.ground ~= false then
    hgr = {}
    local fr = frame(rf)
    local b = space and space.body and space.body(rf.b)
    for i = 0, n do
      local f = i / n
      local lx, lz = A[1] + dx * f, A[3] + dz * f
      local g = -1e9
      if fr and b and BC.groundR then
        local bx, by, bz = to_body(fr, lx, 0, lz)
        local r0 = len3(bx, by, bz)
        local r = BC.groundR(b.x, b.y, b.z, bx / r0, by / r0, bz / r0, r0 + 3.0)
        if r then
          local gx, gy, gz = bx / r0 * r, by / r0 * r, bz / r0 * r
          local _, ly = to_local(fr, gx, gy, gz)
          g = ly
        end
      end
      hgr[i + 1] = math.floor(g * 100 + 0.5) / 100
    end
  end
  local S = supports_along(rf, A, B, n, hgr, opts.skip)
  local W_ = opts.r or 0.0045
  for i = 1, n + 1 do S[i] = S[i] + W_ + 0.004 end
  local C = opts.wire or { kgm = 0.045 }
  local g = 9.81
  local b = space and space.body and space.body(rf.b)
  if b and b.mu and b.radius and b.radius > 0 then g = b.mu / (b.radius * b.radius) end
  -- (laid slack by hand: the pull a fraction of the run's own weight, so the
  -- catenary's a grows with the span, a = SLACK × span, and a long run sags
  -- to whatever is under it; never stiffer than the hand's PULL in this
  -- gravity: on a moon the same pull holds it straighter)
  local a = math.min(PULL / ((C.kgm or 0.045) * math.max(g, 0.05)), math.max(0.6, SLACK * D))
  local y = BC.settle(S, ds, A[2], B[2], a)
  local keep = BC.thin(y, ds, 0.003, 4)
  local pts = {}
  for _, i in ipairs(keep) do
    local f = (i - 1) / n
    pts[#pts + 1] = { A[1] + dx * f, y[i], A[3] + dz * f }
  end
  local Ltot = 0
  for i = 2, n + 1 do local h = y[i] - y[i - 1]; Ltot = Ltot + math.sqrt(ds * ds + h * h) end
  return pts, Ltot, hgr
end
local function flat(pts) local o = {} for _, q in ipairs(pts) do o[#o + 1] = math.floor(q[1] * 1000 + 0.5) / 1000; o[#o + 1] = math.floor(q[2] * 1000 + 0.5) / 1000; o[#o + 1] = math.floor(q[3] * 1000 + 0.5) / 1000 end return o end
local function unflat(f) local o = {} for i = 1, #(f or {}) - 2, 3 do o[#o + 1] = { f[i], f[i + 1], f[i + 2] } end return o end
function pathOf(id) local r = wire(id); return r and unflat(r.p) or nil end

-- the two ends of a cable in its frame's structure frame. → A, B, rf | nil
local function ends_local(r)
  local ST = ref("structures")
  local rf = ST and ST.get(r.f)
  if not rf then return nil end
  local frf = frame(rf)
  local ax, ay, az = pinBody(r.a.sid, r.a.uid, r.a.pin)
  local zx, zy, zz = pinBody(r.z.sid, r.z.uid, r.z.pin)
  if not (ax and zx and frf) then return nil end
  local A = { to_local(frf, ax, ay, az) }
  local B = { to_local(frf, zx, zy, zz) }
  return A, B, rf
end
function resettle(r)
  local A, B, rf = ends_local(r)
  if not A then return false end
  local d = defs("sigCable.steel")
  local pts, L = wirePath(rf, A, B, r.h, { wire = d and d.wire, r = d and d.wire and d.wire.r, ground = false,
    skip = { [keyOf(r.a.sid, r.a.uid)] = true, [keyOf(r.z.sid, r.z.uid)] = true } })
  r.p, r.len = flat(pts), L
  return true
end

-- ── the network ─────────────────────────────────────────────────────────────
local NET, STATE = nil, nil
local TG = {}               -- key → what a sensor reads ({ kind, sid, uid, … })
local META = {}             -- key → { sid, uid, def, rec, p }
local DOORS = {}            -- key → { open, lock } (kit_live asks)
local CYCLE = {}            -- key → true: an airlock asked to cycle to this door
local LAMPS, ALARMS = {}, {}
local SETBACK = {}          -- console key → the setpoint it had
local sig_ver, wsig_ver, sig = -1, -1, nil
local pending_t = nil
local tick_t, sense_t, save_t, flash_t = -10, -10, -10, -10
local dirty_now = false
function net() return NET end
function state() return STATE end
function meta(key) return META[key] end
function doorCmd(sid, uid) return DOORS[keyOf(sid, uid)] end
function holding(sid, uid) local c = DOORS[keyOf(sid, uid)]; return c ~= nil and (c.open or c.lock) == true end
function cycling(sid, uid) return CYCLE[keyOf(sid, uid)] == true end
function lampOn(sid, uid) return LAMPS[keyOf(sid, uid)] == true or ALARMS[keyOf(sid, uid)] == true end

-- a piece's settings: its def's lg over its part state's `lp`
local PARAMS = { "set", "mode", "hys", "T", "n", "ch", "col", "code", "gas", "src", "sense", "step", "unit" }
function paramsOf(sid, uid, d)
  d = d or select(3, part_of(sid, uid))
  local L = d and d.lg or {}
  local st = part_state(sid, uid)
  local lp = st and st.lp
  local o = {}
  for _, k in ipairs(PARAMS) do
    local v = (type(lp) == "table" and lp[k] ~= nil) and lp[k] or L[k]
    o[k] = v
  end
  return o
end

-- the signature of everything the network is built from (cheap: the logic
-- pieces only, their place and settings; the cables; never the lights' own
-- on/off or a door's state)
local function signature()
  local ST = ref("structures")
  local parts = {}
  for _, rec in ipairs(ST and ST.list() or {}) do
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      if d and d.lg and d.lg.kind ~= "wire" then
        local st = rec.st and rec.st[tostring(p.uid)]
        local lp, prog = st and st.lp, st and st.prog
        local s = string.format("%d:%d:%s:%.2f:%.2f:%.2f", rec.id, p.uid, p.id, p.x or 0, p.y or 0, p.z or 0)
        if type(lp) == "table" then for _, k in ipairs(PARAMS) do if lp[k] ~= nil then s = s .. "|" .. k .. "=" .. tostring(lp[k]) end end end
        if type(prog) == "table" then s = s .. "|" .. table.concat(prog, ";") end
        if st and st.stop then s = s .. "|stop" end
        parts[#parts + 1] = s
      end
    end
  end
  wensure()
  for _, id in ipairs(WORDER) do local r = W[id]; parts[#parts + 1] = string.format("w%d:%d:%d:%s>%d:%d:%s", id, r.a.sid, r.a.uid, r.a.pin, r.z.sid, r.z.uid, r.z.pin) end
  return table.concat(parts, "\n")
end

-- what a sensor reads: resolved once at build from the records
local function nearest(rec, lx, ly, lz, R, pred)
  local best, bd = nil, R * R
  for _, q in ipairs(rec.bp or {}) do
    local d = defs(q.id)
    if d and pred(d, q) then
      local dd = ((q.x or 0) - lx) ^ 2 + ((q.y or 0) + 0.8 - ly) ^ 2 + ((q.z or 0) - lz) ^ 2
      if dd < bd then best, bd = q, dd end
    end
  end
  return best, best and math.sqrt(bd) or nil
end
local function resolve_target(rec, p, d, P)
  local sense = d.lg.sense
  -- the sensor's face: 0.25 m out of what it is mounted on (its +Y)
  local fx, fy, fz = pieceToLocal(p, 0, 0.25, 0)
  local T = { sense = sense, sid = rec.id, uid = p.uid, lx = fx, ly = fy, lz = fz }
  if sense == "temp" or sense == "reactor" or sense == "flow" then
    local RP = ref("reactor_plant")
    local R = (sense == "reactor") and 30 or ((sense == "temp") and 8 or 4)
    local q = nearest(rec, fx, fy, fz, R, function(dd) return dd.nuclear ~= nil or dd.pump ~= nil or dd.pipe ~= nil or dd.press ~= nil or dd.hx ~= nil end)
    if q and RP and RP.plantOfPart then T.plant = { sid = rec.id, uid = q.uid } end
    if sense == "flow" and not T.plant then
      local f = nearest(rec, fx, fy, fz, 4, function(dd) return dd.fl ~= nil and (dd.fl.kind == "pipe" or dd.fl.kind == "pump" or dd.fl.kind == "valve" or dd.fl.kind == "check" or dd.fl.kind == "gauge" or dd.fl.kind == "reg") end)
      if f then T.pipe = f.uid end
    end
  elseif sense == "level" then
    local f = nearest(rec, fx, fy, fz, 4, function(dd) return (dd.fl and (dd.fl.kind == "tank" or dd.fl.kind == "bottle")) or (dd.life and dd.life.store)
      or (dd.it and (dd.it.kind == "hopper" or dd.it.kind == "silo" or dd.it.kind == "drive")) end)
    if f then T.tank = f.uid; T.air = defs(f.id).life ~= nil; T.store = defs(f.id).it ~= nil end
  elseif sense == "door" then
    local f = nearest(rec, fx, fy - 0.8, fz, 2.5, function(dd) return dd.door ~= nil end)
    if f then T.door = f.uid end
  end
  return T
end

local function build()
  local L, ST = LG(), ref("structures")
  if not (L and ST) then return end
  local w0 = wall()
  local nodes = {}
  TG, META = {}, {}
  local RT = {}               -- radios: { key, kind, ch, b, x, y, z }
  for _, rec in ipairs(ST.list()) do
    local fr = frame(rec)
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      local lg = d and d.lg
      if lg and lg.kind ~= "wire" then
        local key = keyOf(rec.id, p.uid)
        local P = paramsOf(rec.id, p.uid, d)
        local ins, outs = {}, {}
        for _, q in ipairs(lg.pins or {}) do if q.io == "in" then ins[#ins + 1] = q.n else outs[#outs + 1] = q.n end end
        if lg.kind == "tx" then outs = { "air" } end
        if lg.kind == "rx" then ins = { "air" } end
        local st = part_state(rec.id, p.uid)
        local node = { key = key, kind = lg.kind, p = P, ins = ins, outs = outs, label = d.label }
        if lg.kind == "plc" then node.prog = type(st and st.prog) == "table" and st.prog or {} end
        nodes[#nodes + 1] = node
        META[key] = { sid = rec.id, uid = p.uid, def = d, b = rec.b, dev = lg.dev, kind = lg.kind }
        if lg.kind == "sensor" then TG[key] = resolve_target(rec, p, d, P) end
        if (lg.kind == "tx" or lg.kind == "rx") and fr then
          local bx, by, bz = to_body(fr, p.x or 0, p.y or 0, p.z or 0)
          RT[#RT + 1] = { key = key, kind = lg.kind, ch = tonumber(P.ch) or 1, b = rec.b, x = bx, y = by, z = bz }
        end
      end
    end
  end
  local wl = {}
  wensure()
  for _, id in ipairs(WORDER) do
    local r = W[id]
    wl[#wl + 1] = { id = id, a = keyOf(r.a.sid, r.a.uid), ap = r.a.pin, z = keyOf(r.z.sid, r.z.uid), zp = r.z.pin }
  end
  for _, rx in ipairs(RT) do
    if rx.kind == "rx" then
      for _, tx in ipairs(RT) do
        if tx.kind == "tx" and tx.ch == rx.ch and tx.b == rx.b and len3(tx.x - rx.x, tx.y - rx.y, tx.z - rx.z) <= RADIO_R then
          wl[#wl + 1] = { a = tx.key, ap = "air", z = rx.key, zp = "air", air = true }
        end
      end
    end
  end
  NET = L.build({ nodes = nodes, wires = wl })
  if not STATE then
    STATE = L.unpack(save and save.get and save.get("lg.st"), save and save.get and save.get("lg.a"))
  end
  -- (a piece taken away takes its state with it)
  for k in pairs(STATE.n) do if not NET.idx[k] then STATE.n[k] = nil end end
  -- the levers' and stops' positions are part of the state; the PLC's stop is a part state
  for _, n in ipairs(NET.N) do
    if n.kind == "plc" then
      local m = META[n.key]
      local S = L.nodeState(STATE, n.key)
      local st = part_state(m.sid, m.uid)
      S.stop = (st and st.stop) and true or nil
    end
  end
  L.markAll(NET)
  PROF.nodes, PROF.wires = #NET.N, #NET.wires
  if w0 then PROF.build_ms = (wall() - w0) * 1000 end
  -- the holds a door, an airlock, a lamp and an alarm were left in
  DOORS, CYCLE, LAMPS, ALARMS = {}, {}, {}, {}
  for _, n in ipairs(NET.N) do
    local S = STATE.n[n.key]
    local m = META[n.key]
    if S and S.ib and m then
      for pin, b in pairs(S.ib) do apply_level(n.key, m, pin, b) end
    end
  end
  dirty_now = true
end

-- ── what the network asks of the pieces ─────────────────────────────────────
-- levels (held while the signal is on): doors, airlocks, lamps, alarms, setback
function apply_level(key, m, pin, b)
  local dev = m.dev or m.kind
  if dev == "door" or dev == "airlock" then
    if pin == "open" or pin == "lock" then
      local c = DOORS[key] or {}
      c[pin] = b == true or nil
      DOORS[key] = (c.open or c.lock) and c or nil
      return true
    elseif pin == "cycle" then CYCLE[key] = b == true or nil; return true end
  elseif m.kind == "lamp" then LAMPS[key] = b == true or nil; return true
  elseif m.kind == "alarm" then ALARMS[key] = b == true or nil; return true
  end
  return false
end
local function plant_key(sid, uid)
  local RP = ref("reactor_plant")
  local e = RP and RP.plantOfPart and RP.plantOfPart(sid, uid)
  return e and RP.keyOf(e.sid, e.uid) or nil, e
end
lastCommands = {}
local function apply(c)
  local m = META[c.key]
  if not m then return end
  local sid, uid = m.sid, m.uid
  lastCommands[#lastCommands + 1] = { key = c.key, pin = c.pin, b = c.b, t = agency_now() }
  if #lastCommands > 40 then table.remove(lastCommands, 1) end
  if apply_level(c.key, m, c.pin, c.b) then
    if m.kind == "lamp" or m.kind == "alarm" then m.shown = nil end
    return
  end
  if c.free or c.b == nil then return end
  local on = c.b == true
  local dev = m.dev
  if dev == "light" then
    local KL = ref("kit_live")
    if KL and KL.setLight then KL.setLight(sid, uid, on) end
  elseif dev == "pump" or dev == "valve" then
    local FN = ref("fluid_net")
    if FN and FN.setOn then FN.setOn(sid, uid, on) end
  elseif dev == "belt" then
    -- (X5) a conveyor's or a tube blower's RUN: off stops its whole line
    local LX = ref("logistics")
    if LX and LX.setRun then LX.setRun(sid, uid, on) end
  elseif dev == "breaker" then
    local BP = ref("base_power")
    if BP and BP.setBreaker then
      local was = BP.breakerState and BP.breakerState(sid, uid)
      -- (logic opens and recloses; a TRIP waits for a hand: no auto-reclose into a fault)
      if on then if was == "open" then BP.setBreaker(sid, uid, true, "logic") end
      elseif was == "closed" then BP.setBreaker(sid, uid, false, "logic") end
      local BG = ref("base_grid")
      if BG and BG.markDirty then BG.markDirty() end
    end
  elseif dev == "rxpump" then
    local RP = ref("reactor_plant")
    if RP and RP.setPump then RP.setPump(sid, uid, on) end
  elseif dev == "rxconsole" then
    local RP = ref("reactor_plant")
    local k, e = plant_key(sid, uid)
    if RP and k then
      if c.pin == "scram" and on then
        if RP.scram(k) then say("SCRAM by logic: the protection on the " .. tostring(m.def.label)) end
      elseif c.pin == "setback" then
        if on then
          SETBACK[c.key] = SETBACK[c.key] or (e and e.S and e.S.set) or 0.5
          local P = paramsOf(sid, uid, m.def)
          RP.setPoint(k, (tonumber(P.set) or 30) / 100)
        elseif SETBACK[c.key] then
          RP.setPoint(k, SETBACK[c.key]); SETBACK[c.key] = nil
        end
      end
    end
  elseif dev == "machine" then
    local RA = ref("room_air")
    if RA and RA.setMachine then RA.setMachine(sid, uid, on) end
  elseif dev == "refinery" then
    -- (X6) a refinery machine's or a Fabricator's RUN
    local RF = ref("refinery")
    if RF and RF.setRun then RF.setRun(sid, uid, on) end
  elseif dev == "laser" then
    -- (X9) a Beam Director's or a Fire Control Console's: fire on the edge, arm by level
    local LZ = ref("lasers")
    if LZ and LZ.logicIn then LZ.logicIn(sid, uid, c.pin, on) end
  end
end

-- ── the readings ────────────────────────────────────────────────────────────
local function room_reading(T)
  local RA, RL = ref("room_air"), ref("rooms")
  local s = RA and RA.state and RA.state(T.sid)
  if not (s and s.R and RL) then return nil end
  local r = RL.roomAt(s.R, T.lx, T.ly, T.lz)
  if not r then
    -- (outside the rooms: the outside's air)
    local o = s.out
    return o and { p = o.p or 0, o2 = (o.p or 0) * (o.x or 0.21), co2 = 0 } or nil
  end
  return RA.airOf(T.sid, r.id), r
end
local function crew_points()
  local out = {}
  local a = find and find("Astronaut")
  local pw = ref("planet_walker")
  if valid(a) and (not pw or pw.onFoot ~= false) then out[#out + 1] = { x = a.x, y = a.y, z = a.z } end
  local C = ref("crew")
  if C and C.roster and C.activeId then
    local act = C.activeId()
    for _, r in ipairs(C.roster()) do
      if r.status == "afoot" and r.id ~= act and r.body and r.x then
        local b = space.body(r.body)
        if b then out[#out + 1] = { x = b.x + r.x, y = b.y + r.y, z = b.z + r.z } end
      end
    end
  end
  return out
end
local sun_cache = { t = -10 }
-- the star lighting body `bname` (electronics.sunOf: the heaviest near one), its name kept 2 s
local function sun_of(bname)
  if now() - sun_cache.t < 2 and sun_cache.name then return space.body(sun_cache.name) end
  sun_cache.t = now()
  local bodies = space and space.bodies and space.bodies() or {}
  local E = ref("electronics")
  local home = nil
  for _, b in ipairs(bodies) do if b.name == bname then home = b end end
  local s = nil
  if E and E.sunOf and home then s = E.sunOf(home.x, home.y, home.z, bodies, nil) end
  if not s then for _, b in ipairs(bodies) do if b.star then s = b end end end
  if s and home and s.name == home.name then s = nil end
  sun_cache.name = s and s.name or nil
  return s
end
function reading(key)
  local T = TG[key]
  local m = META[key]
  if not (T and m) then return nil end
  local s = T.sense
  if s == "press" or s == "gas" then
    local a = room_reading(T)
    if not a then return nil end
    if s == "press" then return a.p end
    local P = paramsOf(m.sid, m.uid, m.def)
    if P.gas == "co2" then return (a.co2 or 0) * 100 end
    return (a.o2 or 0) * 100
  elseif s == "temp" or s == "reactor" or s == "flow" then
    if T.plant then
      local RP = ref("reactor_plant")
      local e = RP and RP.plantOfPart and RP.plantOfPart(T.plant.sid, T.plant.uid)
      local o = e and e.o
      if not o then return nil end
      local P = paramsOf(m.sid, m.uid, m.def)
      if s == "temp" then return (P.src == "fuel") and o.Tf or o.Tp end
      if s == "flow" then return o.mpe or 0 end
      if P.src == "k" then return o.k end
      return (o.P or 0) * 100
    end
    if s == "flow" and T.pipe then
      local FN = ref("fluid_net")
      local o = FN and FN.readout and FN.readout(m.sid, T.pipe)
      return o and math.abs(o.q or 0) or 0
    end
    if s == "temp" then
      local cl = ref("climate")
      local ok, t = pcall(function() return cl and cl.tempAt and cl.tempAt(m.b) end)
      return ok and tonumber(t) or nil
    end
    return nil
  elseif s == "level" then
    if not T.tank then return nil end
    if T.store then
      -- (X5) a hopper's, a silo's or a quarry drive's bin: % of its kg
      local LX = ref("logistics")
      return LX and LX.levelOf and LX.levelOf(m.sid, T.tank) or nil
    end
    if T.air then
      local RA = ref("room_air")
      local st = RA and RA.state and RA.state(m.sid)
      local d = select(3, part_of(m.sid, T.tank))
      local q = st and st.tanks and st.tanks[T.tank]
      if not (q and d and d.life and d.life.store) then return nil end
      return 100 * q / d.life.store
    end
    local FN = ref("fluid_net")
    local x, cap = nil, nil
    if FN and FN.content then x, cap = FN.content(m.sid, T.tank) end
    if not (x and cap and cap > 0) then return nil end
    return 100 * x / cap
  elseif s == "battery" then
    local BG = ref("base_grid")
    local g = BG and BG.gridOfStruct and BG.gridOfStruct(m.sid)
    if not g then return nil end
    local M = BG.model and BG.model(g.id)
    local st = BG.status and BG.status(g.id)
    if not (M and st and (M.C or 0) > 0) then return nil end
    return 100 * (st.stored or 0) / M.C
  elseif s == "dose" then
    local BS = ref("base_shield")
    local bx, by, bz = nil, nil, nil
    local rec = select(1, part_of(m.sid, m.uid))
    local fr = rec and frame(rec)
    if fr then bx, by, bz = to_body(fr, T.lx, T.ly, T.lz) end
    if not (BS and BS.doseAt and bx) then return 0 end
    return (BS.doseAt(m.b, bx, by, bz) or 0) * 3600 * 100
  elseif s == "prox" then
    local rec = select(1, part_of(m.sid, m.uid))
    local fr = rec and frame(rec)
    local b = rec and space and space.body and space.body(rec.b)
    if not (fr and b) then return nil end
    local bx, by, bz = to_body(fr, T.lx, T.ly, T.lz)
    local best = 99
    for _, c in ipairs(crew_points()) do
      local d = len3(c.x - b.x - bx, c.y - b.y - by, c.z - b.z - bz)
      if d < best then best = d end
    end
    return best
  elseif s == "light" then
    local rec = select(1, part_of(m.sid, m.uid))
    local b = rec and space and space.body and space.body(rec.b)
    local sun = sun_of(rec and rec.b)
    if not (rec and b and sun) then return nil end
    local fr = frame(rec)
    local bx, by, bz = to_body(fr, T.lx, T.ly, T.lz)
    local sx, sy, sz = sun.x - b.x - bx, sun.y - b.y - by, sun.z - b.z - bz
    local l = len3(sx, sy, sz)
    local e = (sx * fr.U.x + sy * fr.U.y + sz * fr.U.z) / math.max(l, 1e-9)
    return math.max(0, e) * 100
  elseif s == "door" then
    if not T.door then return nil end
    local KL = ref("kit_live")
    local o = KL and KL.doorOpen and KL.doorOpen(m.sid, T.door)
    return (o or 0) * 100
  end
  return nil
end
-- a device's state pins now
local function device_outs(key, m)
  local dev = m.dev
  local o = {}
  if dev == "door" or dev == "airlock" then
    local KL = ref("kit_live")
    local d = KL and KL.doorOpen and KL.doorOpen(m.sid, m.uid)
    o.state = (d or 0) > 0.5
    if dev == "airlock" then
      local RA = ref("room_air")
      o.ready = (RA and RA.airlockReady and RA.airlockReady(m.sid, m.uid)) == true
    end
  elseif dev == "breaker" then
    local BP = ref("base_power")
    o.tripped = (BP and BP.breakerState and BP.breakerState(m.sid, m.uid)) == "tripped"
  elseif dev == "rxconsole" then
    local _, e = plant_key(m.sid, m.uid)
    o.tripped = (e and e.S and e.S.scram) and true or false
  elseif dev == "refinery" then
    -- (X6) BUSY: the machine is working (power, feed and room all there)
    local RF = ref("refinery")
    o.busy = (RF and RF.isBusy and RF.isBusy(m.sid, m.uid)) == true
  elseif dev == "laser" then
    -- (X9) READY: armed, charged, cooled; ONTGT: the director is on the target
    local LZ = ref("lasers")
    local s = LZ and LZ.logicOut and LZ.logicOut(m.sid, m.uid)
    o.ready = (s and s.ready) == true
    o.ontgt = (s and s.ontgt) == true
  end
  return o
end
function sampleNow()
  local L = LG()
  if not (L and NET and STATE) then return 0 end
  local w0 = wall()
  local n = 0
  for _, node in ipairs(NET.N) do
    local m = META[node.key]
    if node.kind == "sensor" then
      if L.setValue(NET, STATE, node.key, reading(node.key)) then n = n + 1 end
    elseif node.kind == "device" and m and #node.outs > 0 then
      for pin, b in pairs(device_outs(node.key, m)) do if L.setOut(NET, STATE, node.key, pin, b) then n = n + 1 end end
    end
  end
  if w0 then PROF.sense_ms = (wall() - w0) * 1000; PROF.sensesum = PROF.sensesum + PROF.sense_ms end
  return n
end

-- the network to agency time a, its commands applied
local function step(a)
  local L = LG()
  if not (L and NET and STATE) then return end
  local w0 = wall()
  local rep = L.advance(NET, STATE, a)
  for _, c in ipairs(L.takeCommands(NET)) do apply(c) end
  PROF.evals, PROF.events, PROF.osc = rep.evals, rep.events, rep.osc
  PROF.ticks = PROF.ticks + 1
  PROF.evsum = PROF.evsum + (rep.evals or 0)
  if w0 then PROF.tick_ms = (wall() - w0) * 1000; PROF.tsum = PROF.tsum + PROF.tick_ms end
  if rep.evals > 0 then PLC_DIRTY = true end
  return rep
end
function stepNow() if NET then sampleNow(); return step(agency_now()) end end
function rebuildNow() build(); return stepNow() end

-- ── controls (menus, probes) ────────────────────────────────────────────────
local function touch() dirty_now = true end
function press(sid, uid)
  local L = LG()
  if not (L and NET) then return false end
  local a = agency_now()
  step(a)
  local ok = L.press(NET, STATE, keyOf(sid, uid), a)
  step(a)
  local x, y, z = pinWorld(sid, uid, "Q")
  snd("audio/foley/switch_1.ogg", 0.5, x, y, z, 15)
  return ok
end
function setLever(sid, uid, on)
  local L = LG()
  if not (L and NET) then return false end
  local a = agency_now()
  step(a)
  L.setLever(NET, STATE, keyOf(sid, uid), on)
  step(a)
  local x, y, z = pinWorld(sid, uid, "Q")
  snd(on and "audio/foley/rocker_on.ogg" or "audio/foley/rocker_off.ogg", 0.5, x, y, z, 15)
  return true
end
function lever(sid, uid) local S = STATE and STATE.n[keyOf(sid, uid)]; return S and S.lev == true or false end
function resetNode(sid, uid)
  local L = LG()
  if not (L and NET) then return false end
  step(agency_now()); L.resetLatch(NET, STATE, keyOf(sid, uid)); step(agency_now())
  return true
end
function setParam(sid, uid, k, v)
  local st = part_state(sid, uid) or {}
  local lp = {}
  for a, b in pairs(type(st.lp) == "table" and st.lp or {}) do lp[a] = b end
  lp[k] = v
  set_part_state(sid, uid, "lp", lp)
  touch()
  return true
end
function param(sid, uid, k) return paramsOf(sid, uid)[k] end
function setProgram(sid, uid, list)
  local L = LG()
  local out = {}
  for k = 1, (L and L.RUNGS or 16) do
    local r = list[k]
    if type(r) == "table" then r = L.rungString(r) end
    out[k] = type(r) == "string" and r or ""
  end
  set_part_state(sid, uid, "prog", out)
  touch()
  -- (the edit is live at once: the network rebuilt now, not after the debounce)
  build()
  step(agency_now())
  return true
end
function program(sid, uid)
  local st = part_state(sid, uid)
  local L = LG()
  return L and L.parseProgram(type(st and st.prog) == "table" and st.prog or {}) or {}
end
function setRun(sid, uid, run)
  set_part_state(sid, uid, "stop", (not run) or nil)
  build(); step(agency_now())
end
function out(sid, uid, pin)
  local L = LG()
  if not (L and STATE) then return nil end
  return L.outOf(STATE, keyOf(sid, uid), pin)
end
function inp(sid, uid, pin)
  local L = LG()
  if not (L and NET and STATE) then return nil end
  return L.inputOf(NET, STATE, keyOf(sid, uid), pin)
end
-- A piece's numbers now: → { kind, q, v, set, mode, unit, osc, pins = { { n, io, b, v, wired } } }
function readout(sid, uid)
  local key = keyOf(sid, uid)
  local m = META[key]
  local L = LG()
  if not (m and L and NET and STATE) then return nil end
  local i = NET.idx[key]
  local S = STATE.n[key] or { o = {}, v = {} }
  local P = paramsOf(sid, uid, m.def)
  local o = { kind = m.kind, dev = m.dev, set = P.set, mode = P.mode, unit = P.unit, osc = i and NET.osc[i] or false, loop = i and NET.cyc[i] or false, pins = {} }
  o.q, o.v = L.outOf(STATE, key, "Q")
  if m.kind == "sensor" then o.v = S.raw end
  o.count, o.lev = S.c, S.lev
  for _, q in ipairs(m.def.lg.pins or {}) do
    local b, v, n
    if q.io == "in" then b, v, n = L.inputOf(NET, STATE, key, q.n) else b, v = L.outOf(STATE, key, q.n); n = 0 end
    o.pins[#o.pins + 1] = { n = q.n, io = q.io, b = b, v = v, wired = n }
  end
  if m.kind == "plc" then o.Y, o.M, o.X, o.re, o.stop = S.Y, S.M, S.X, S.re, S.stop end
  if m.kind == "timer" then o.left = S.due and math.max(0, S.due - agency_now()) or 0 end
  return o
end

-- ── laying a Signal Cable (field_builder hands its clicks here) ────────────
local function drum_def() local fb = ref("field_builder"); local d = fb and fb.heldPart and defs(fb.heldPart); return (d and d.wire) and d or defs("sigCable.steel") end
function heldWire() local fb = ref("field_builder"); local d = fb and fb.heldPart and defs(fb.heldPart); return d and d.wire ~= nil end
-- the pin of a piece nearest a structure-frame point (opposite `io` to `want` if given)
function pinNear(rec, part, lx, ly, lz, want)
  local d = defs(part.id)
  local best, bd = nil, 1e18
  for _, q in ipairs(d and d.lg and d.lg.pins or {}) do
    if not want or q.io == want then
      local x, y, z = pieceToLocal(part, q.x, q.y, q.z)
      local dd = (x - lx) ^ 2 + (y - ly) ^ 2 + (z - lz) ^ 2
      if dd < bd then best, bd = q, dd end
    end
  end
  return best
end
function quote(L)
  local d = drum_def()
  local C = d and d.wire or { perm = 1.2, kgm = 0.045 }
  local cost = math.ceil((L or 0) * (C.perm or 1.2))
  return { mode = "money", cost = cost, ship = 0, foot = 0, total = cost, mass = (L or 0) * (C.kgm or 0.045) / 1000 }
end
local function money(v) local E = ref("base_economy"); return E and E.money and E.money(v) or ("$" .. tostring(v)) end
-- A first end (e1 = pending) and the piece under the cursor. → v { bad, len, quote, label, pin }
function validity(e1, hit, body, hitPt)
  local r = {}
  if not (hit and hit.rec and hit.part) then
    r.bad = e1 and "aim at a pin on another piece to make the far end off" or "aim at a logic piece (or a door, a light, a pump…) to make the cable off at a pin"
    return r
  end
  local d = defs(hit.part.id)
  if not (d and d.lg and d.lg.pins and #d.lg.pins > 0) then r.bad = string.format("the %s has no signal terminals", d and d.label or "part") return r end
  local lx, ly, lz = hit.part.x or 0, (hit.part.y or 0) + 0.5, hit.part.z or 0
  if hitPt then lx, ly, lz = hitPt[1], hitPt[2], hitPt[3] end
  local want = nil
  if e1 then want = (e1.io == "out") and "in" or "out" end
  local q = pinNear(hit.rec, hit.part, lx, ly, lz, want)
  if not q then r.bad = string.format("the %s has no %s pin to take this end", d.label, want == "in" and "input" or "output") return r end
  r.pin, r.io, r.label = q.n, q.io, d.label
  if not e1 then return r end
  if hit.rec.b ~= e1.b then r.bad = "the other end is on another world" return r end
  if hit.rec.id == e1.sid and hit.part.uid == e1.uid then r.bad = "the same piece: wire it to another" return r end
  -- (out → in; a pin may take many cables: an input ORs them)
  local a = (e1.io == "out") and { sid = e1.sid, uid = e1.uid, pin = e1.pin } or { sid = hit.rec.id, uid = hit.part.uid, pin = q.n }
  local z = (e1.io == "out") and { sid = hit.rec.id, uid = hit.part.uid, pin = q.n } or { sid = e1.sid, uid = e1.uid, pin = e1.pin }
  for _, w in ipairs(wiresAt(a.sid, a.uid)) do
    if w.a.sid == a.sid and w.a.uid == a.uid and w.a.pin == a.pin and w.z.sid == z.sid and w.z.uid == z.uid and w.z.pin == z.pin then
      r.bad = "those two pins are wired already" return r
    end
  end
  local ax, ay, az = pinBody(a.sid, a.uid, a.pin)
  local zx, zy, zz = pinBody(z.sid, z.uid, z.pin)
  if not (ax and zx) then r.bad = "an end is gone" return r end
  local L = len3(ax - zx, ay - zy, az - zz) * 1.08 + 0.3
  local C = (drum_def() or {}).wire or { max = 150 }
  if L > (C.max or 150) then r.bad = string.format("%.0f m: a signal run is at most %.0f m (a radio channel goes further)", L, C.max or 150) return r end
  r.len, r.a, r.z = L, a, z
  r.quote = quote(L)
  local co = ref("company")
  local fb = ref("field_builder")
  local free = fb and fb.creative and fb.creative()
  if not free and co and co.afford and not co.afford(r.quote.total) then r.bad = "can't afford it: " .. money(r.quote.total) return r end
  return r
end
-- The cable from a to z ({ sid, uid, pin }, a an output, z an input). → id | nil, why, quote, length
function layWire(a, z, opts)
  opts = opts or {}
  local ST, co = ref("structures"), ref("company")
  if not ST then return nil, "no structures" end
  local ra = ST.get(a.sid)
  if not ra then return nil, "that structure is gone" end
  local r = { id = opts.id or wseq(), b = ra.b, a = { sid = a.sid, uid = a.uid, pin = a.pin }, z = { sid = z.sid, uid = z.uid, pin = z.pin }, f = a.sid }
  local A, B, rf = ends_local(r)
  if not A then return nil, "an end has no such pin" end
  local d = defs("sigCable.steel")
  local pts, L, h = wirePath(rf, A, B, nil, { wire = d and d.wire, r = d and d.wire and d.wire.r, ground = opts.ground,
    skip = { [keyOf(a.sid, a.uid)] = true, [keyOf(z.sid, z.uid)] = true } })
  r.p, r.len, r.h = flat(pts), L, h
  local q = quote(L)
  local fb = ref("field_builder")
  local free = opts.free or (fb and fb.creative and fb.creative())
  if not free and co and co.spend and q.total > 0 then
    if not co.spend(q.total, string.format("Signal Cable · %.1f m", L)) then return nil, "can't afford it: " .. money(q.total) end
    r.cost = q.total
  end
  r.t = agency_now()
  wensure()
  W[r.id] = r
  WORDER[#WORDER + 1] = r.id
  wsave()
  wbump()
  MESH_DIRTY[r.f] = true
  lastLay = { id = r.id, len = L, total = q.total, n = #pts }
  if fb and fb.pushHistory and not opts.noHistory then
    local e = { label = "lay the Signal Cable", kind = "cable", t = r.t, cable = r.id }
    e.undo = function()
      local r2 = W[e.cable]
      if not r2 then e.res, e.why = nil, "it's gone" return end
      takeUp(e.cable, true)
      e.res = r2.cost or 0
    end
    e.redo = function()
      local id2, w = layWire(a, z, { id = e.cable, noHistory = true })
      if not id2 then e.res, e.why = nil, w return end
      e.res = lastLay and lastLay.total or 0
    end
    fb.pushHistory(e)
  end
  touch()
  local x, y, zz = pinWorld(z.sid, z.uid, z.pin)
  snd("audio/foley/clamp_clunk.ogg", 0.35, x, y, zz, 12)
  return r.id, nil, q, L
end
-- Take a cable up: what it cost back (undo, or within the minute: deconstruct's rule). → refund
function takeUp(id, full)
  wensure()
  local r = W[id]
  if not r then return nil, "it's gone" end
  W[id] = nil
  for i, x in ipairs(WORDER) do if x == id then table.remove(WORDER, i) break end end
  wsave()
  wbump()
  MESH_DIRTY[r.f] = true
  local amt = 0
  local co, EC = ref("company"), ref("base_economy")
  if r.cost and r.cost > 0 then
    -- (within the minute all of it, as a placement's undo; later deconstruct's rule)
    if full or agency_now() - (r.t or -1e9) < 60 then amt = r.cost
    elseif EC and EC.deconstructRefund then amt = EC.deconstructRefund({ total = r.cost, cost = r.cost, t = r.t }, agency_now()) or 0
    else amt = math.floor(r.cost * 0.5) end
    if co and amt > 0 then if co.refund then co.refund(amt, "returned: Signal Cable") elseif co.earn then co.earn(amt, "returned: Signal Cable") end end
  end
  touch()
  return amt
end

-- field_builder's hooks (as base_cable's): the cursor's hit → this frame's request
function aimTick(hit)
  local ST = ref("structures")
  local FB = ref("field_builder")
  local hrec, hpart = nil, nil
  if hit and hit.node and ST and ST.partOfNode then
    if FB and FB.hitPick then hrec, hpart = FB.hitPick(hit) end
    if not hpart then hrec, hpart = ST.partOfNode(hit.node) end
  end
  local body = hit and space.dominant(hit.x, hit.y, hit.z) or nil
  local hp = nil
  if hrec and hit then
    local b = space.body(hrec.b)
    local fr = frame(hrec)
    if b and fr then hp = { to_local(fr, hit.x - b.x, hit.y - b.y, hit.z - b.z) } end
  end
  -- A wall-hung box (a mount) has no collider: the ray lands on the wall behind
  -- it. A logic piece within 0.3 m of the hit point wins over the wall's own
  -- terminals, so aiming at a button on a door's wall takes the button.
  if hrec and hpart and hp then
    local hd = defs(hpart.id)
    if not (hd and hd.lg and hd.lg.kind ~= "device") then
      local best, bd = nil, 0.3 * 0.3
      for _, q in ipairs(hrec.bp or {}) do
        local d = defs(q.id)
        if q ~= hpart and d and d.lg and d.lg.kind ~= "device" and d.lg.pins and #d.lg.pins > 0 then
          local dd = ((q.x or 0) - hp[1]) ^ 2 + ((q.y or 0) - hp[2]) ^ 2 + ((q.z or 0) - hp[3]) ^ 2
          for _, pq in ipairs(d.lg.pins) do
            local x, y, z = pieceToLocal(q, pq.x, pq.y, pq.z)
            dd = math.min(dd, (x - hp[1]) ^ 2 + (y - hp[2]) ^ 2 + (z - hp[3]) ^ 2)
          end
          if dd < bd then best, bd = q, dd end
        end
      end
      if best then hpart = (ST.getPart and ST.getPart(hrec.id, best.uid)) or best end
    end
  end
  local v = validity(pending, hrec and { rec = hrec, part = hpart } or nil, body, hp)
  v.hitRec, v.hitPart, v.body = hrec, hpart, body
  -- the preview: the end made off to the pin under the cursor, or to the cursor
  local tgt = nil
  if hrec and hpart and v.pin then tgt = { sid = hrec.id, uid = hpart.uid, pin = v.pin } end
  preview = { from = pending and { sid = pending.sid, uid = pending.uid, pin = pending.pin } or nil, to = tgt, bad = v.bad, b = body,
              hit = hit and { x = hit.x - (space.body(body or "") or { x = 0 }).x, y = hit.y - (space.body(body or "") or { y = 0 }).y, z = hit.z - (space.body(body or "") or { z = 0 }).z } or nil }
  return v
end
function drawPreview()
  if not (preview and draw and draw.line) then return end
  local ok = not preview.bad
  local r, g, bl = ok and 0.97 or 1.0, ok and 0.62 or 0.28, ok and 0.22 or 0.20
  local function ring(x, y, z, big)
    local cp = eye_now()
    if draw.ring and cp then
      local nx, ny, nz = cp.x - x, cp.y - y, cp.z - z
      local l = math.max(len3(nx, ny, nz), 1e-6)
      draw.ring(x, y, z, nx / l, ny / l, nz / l, big and 0.05 or 0.035, r, g, bl, 1)
    end
  end
  local ax, ay, az
  if preview.from then ax, ay, az = pinWorld(preview.from.sid, preview.from.uid, preview.from.pin) end
  local zx, zy, zz
  if preview.to then zx, zy, zz = pinWorld(preview.to.sid, preview.to.uid, preview.to.pin)
  elseif preview.hit and preview.b then
    local b = space.body(preview.b)
    if b then zx, zy, zz = b.x + preview.hit.x, b.y + preview.hit.y, b.z + preview.hit.z end
  end
  if zx and preview.to then ring(zx, zy, zz, true) end
  if ax then
    ring(ax, ay, az, true)
    if zx then draw.line(ax, ay, az, zx, zy, zz, r, g, bl, 0.95) end
  end
end
function clearPending() pending, preview = nil, nil end
-- the first end (a click on a piece with the drum in hand): the pin the last aim chose
function makeOff(rec, part, pin, io)
  local d = defs(part.id)
  if not pin then
    local q = pinNear(rec, part, part.x or 0, (part.y or 0) + 0.5, part.z or 0)
    pin, io = q and q.n, q and q.io
  end
  if not pin then return nil end
  pending = { sid = rec.id, uid = part.uid, pin = pin, io = io, b = rec.b, label = d and d.label or "piece" }
  return pending
end
-- (field_builder's click, both ends) → ok, message
function click(req)
  if not req then return false, "aim at a pin" end
  if not pending then
    if req.bad then return false, req.bad end
    makeOff(req.hitRec, req.hitPart, req.pin, req.io)
    return true, string.format("Signal Cable made off at the %s's %s %s · now a pin of the other kind", tostring(req.label), req.io == "out" and "output" or "input", tostring(req.pin))
  end
  if req.bad then return false, req.bad end
  local id, why, q, L = layWire(req.a, req.z)
  if not id then return false, why end
  clearPending()
  return true, string.format("Signal Cable laid · %s %s → %s · %.1f m · %s · Ctrl+Z within a minute takes it up", tostring(req.a.pin), "", tostring(req.z.pin), L or 0, money(q.total))
end

-- ── keeping in step with the structures ─────────────────────────────────────
-- A piece taken down takes its cables up; a structure whose floors changed
-- settles its cables again.
local supsig = {}
local function support_sig(rec)
  local n, s = 0, 0
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and SUPPORT[d.snap or "block"] then n = n + 1; s = s + (p.uid or 0) * 7 + math.floor((p.x or 0) * 10 + (p.y or 0) * 100 + (p.z or 0) * 1000) end
  end
  return n * 1000003 + s
end
local function reconcile()
  local ST = ref("structures")
  if not ST then return end
  wensure()
  local gone = {}
  for _, id in ipairs(WORDER) do
    local r = W[id]
    if not (ST.getPart(r.a.sid, r.a.uid) and ST.getPart(r.z.sid, r.z.uid)) then gone[#gone + 1] = id end
  end
  for _, id in ipairs(gone) do takeUp(id) end
  local changed = {}
  for _, rec in ipairs(ST.list()) do
    local s = support_sig(rec)
    if supsig[rec.id] ~= nil and supsig[rec.id] ~= s then changed[rec.id] = true end
    supsig[rec.id] = s
  end
  local any = false
  for _, id in ipairs(WORDER) do
    local r = W[id]
    if changed[r.f] or changed[r.a.sid] or changed[r.z.sid] then if resettle(r) then MESH_DIRTY[r.f] = true; any = true end end
  end
  if any then wsave() end
end

-- ── the cables' meshes: one per structure ──────────────────────────────────
MESH_DIRTY = {}
local MESH = {}            -- sid → { node, making, old }
local WIRE_MAT = { color = { 0.10, 0.18, 0.30 }, roughness = 0.78, metallic = 0.0, shading = "physical" }
local function tube_into(P, N, UV, I, pts, rad, o)
  local S = 6
  local base = #P / 3
  local px, py, pz = 0, 1, 0
  local v = 0
  for i, p in ipairs(pts) do
    local q0 = pts[math.max(1, i - 1)]
    local q1 = pts[math.min(#pts, i + 1)]
    local tx, ty, tz = q1[1] - q0[1], q1[2] - q0[2], q1[3] - q0[3]
    local tl = math.max(len3(tx, ty, tz), 1e-9)
    tx, ty, tz = tx / tl, ty / tl, tz / tl
    local d = px * tx + py * ty + pz * tz
    local sx, sy, sz = px - tx * d, py - ty * d, pz - tz * d
    local sl = len3(sx, sy, sz)
    if sl < 1e-6 then sx, sy, sz = ty, -tx + tz, -ty; sl = math.max(len3(sx, sy, sz), 1e-9) end
    sx, sy, sz = sx / sl, sy / sl, sz / sl
    local bx, by, bz = ty * sz - tz * sy, tz * sx - tx * sz, tx * sy - ty * sx
    px, py, pz = sx, sy, sz
    if i > 1 then local a = pts[i - 1]; v = v + len3(p[1] - a[1], p[2] - a[2], p[3] - a[3]) end
    for k = 0, S do
      local ang = k / S * 2 * math.pi
      local c, s = math.cos(ang), math.sin(ang)
      local nx, ny, nz = sx * c + bx * s, sy * c + by * s, sz * c + bz * s
      P[#P + 1] = p[1] - o[1] + nx * rad; P[#P + 1] = p[2] - o[2] + ny * rad; P[#P + 1] = p[3] - o[3] + nz * rad
      N[#N + 1] = nx; N[#N + 1] = ny; N[#N + 1] = nz
      UV[#UV + 1] = k / S * 0.25; UV[#UV + 1] = v * 4.0
    end
  end
  local ring = S + 1
  for i = 0, #pts - 2 do
    for k = 0, S - 1 do
      local a, b = base + i * ring + k, base + i * ring + k + 1
      local c2, d2 = base + (i + 1) * ring + k, base + (i + 1) * ring + k + 1
      I[#I + 1] = a + 1; I[#I + 1] = c2 + 1; I[#I + 1] = b + 1
      I[#I + 1] = b + 1; I[#I + 1] = c2 + 1; I[#I + 1] = d2 + 1
    end
  end
end
local function build_mesh(sid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local M_ = MESH[sid]
  if not rec then
    if M_ and valid(M_.node) then M_.node:destroy() end
    MESH[sid] = nil
    return
  end
  local fr = frame(rec)
  local planet = find and find(rec.b)
  if not (fr and planet and createNode and mesh and mesh.build) then return end
  local P, N, UV, I = {}, {}, {}, {}
  local o = nil
  local d = defs("sigCable.steel")
  local rad = d and d.wire and d.wire.r or 0.0045
  for _, id in ipairs(WORDER) do
    local r = W[id]
    if r.f == sid then
      local pts = {}
      for _, q in ipairs(unflat(r.p)) do pts[#pts + 1] = { to_body(fr, q[1], q[2], q[3]) } end
      if #pts >= 2 then
        o = o or pts[1]
        tube_into(P, N, UV, I, pts, rad, o)
      end
    end
  end
  if not o then
    if M_ and valid(M_.node) then M_.node:destroy() end
    MESH[sid] = nil
    return
  end
  local ok, name = pcall(mesh.build, { positions = P, indices = I, normals = N, uvs = UV, scene = true })
  if not ok then if log then log("logic: wire mesh failed: " .. tostring(name)) end return end
  local E = { making = true, old = M_ and (M_.node or M_.old) or nil }
  MESH[sid] = E
  createNode("SignalCables", planet, function(n)
    E.making = false
    if MESH[sid] ~= E then n:destroy() return end
    n.x, n.y, n.z = o[1], o[2], o[3]
    n.model = name
    pcall(n.setMaterial, n, WIRE_MAT)
    E.node = n
    if E.old and valid(E.old) then E.old:destroy() end
    E.old = nil
  end)
end
function meshOf(sid) local E = MESH[sid]; return E and valid(E.node) and E.node or nil end

-- ── the pieces' own nodes: lamps, beacons, the controller's screen ─────────
local PIECE = {}           -- key → { node, lens, screen, img, tex }
function spawned(rec, part, node)
  local d = defs(part.id)
  if not (d and d.lg and valid(node)) then return end
  local e = { sid = rec.id, uid = part.uid, node = node, def = d }
  local function child(name) local ok, c = pcall(node.getChild, node, name); return ok and c or nil end
  e.lens = child("Lens")
  e.screen = child("Screen")
  e.lit = (d.lg.kind == "lamp" or d.lg.kind == "alarm") or nil
  PIECE[keyOf(rec.id, part.uid)] = e
  local m = META[keyOf(rec.id, part.uid)]
  if m then m.shown = nil end
  PLC_DIRTY = true
end
-- (probes) a lamp's lens: found?, the colour last put on it
function lensOf(sid, uid)
  local e = PIECE[keyOf(sid, uid)]
  local m = META[keyOf(sid, uid)]
  return e ~= nil and valid(e.lens), m and m.shown or nil
end
function gone(sid, uid)
  local e = PIECE[keyOf(sid, uid)]
  if e and e.tex and assets and assets.release then pcall(assets.release, e.tex) end
  if e and e.klax then pcall(function() e.klax:stop() end) end
  PIECE[keyOf(sid, uid)] = nil
end
local LAMP_COL = { green = { 0.35, 1.0, 0.45 }, amber = { 1.0, 0.72, 0.18 }, red = { 1.0, 0.22, 0.16 }, white = { 1.0, 0.96, 0.88 } }
LAMP_ORDER = { "green", "amber", "red", "white" }
local DARK = { 0.12, 0.12, 0.12 }
local function lamps_tick(t)
  for key, e in pairs(PIECE) do
    local m = META[key]
    if e.lit and m and valid(e.lens) then
      local on
      if m.kind == "lamp" then on = LAMPS[key] == true else on = ALARMS[key] == true end
      local col
      if m.kind == "lamp" then
        local P = paramsOf(m.sid, m.uid, m.def)
        col = on and (LAMP_COL[P.col or "green"] or LAMP_COL.green) or DARK
      else
        -- a rotating beacon: its lens flashes twice a second while on
        local ph = on and (math.floor(t * 4) % 2 == 0) or false
        col = ph and LAMP_COL.red or (on and { 0.45, 0.08, 0.06 } or DARK)
      end
      local sk = string.format("%.2f%.2f%.2f", col[1], col[2], col[3])
      if m.shown ~= sk then m.shown = sk; pcall(e.lens.setTint, e.lens, { color = col }) end
      -- the klaxon: a positional loop while on
      if m.kind == "alarm" and valid(e.node) then
        if on and not e.klax then
          local w = e.node.worldPos
          e.klax = true
          if audio and audio.play then
            local ok, hh = pcall(audio.play, "audio/sfx/crew_alarm_loop.ogg", w.x, w.y, w.z, { loop = true, maxDistance = 45, track = "SFX", volume = 0.55 })
            if ok and hh then e.klax = hh end
          end
        elseif not on and e.klax then
          if type(e.klax) ~= "boolean" then pcall(function() e.klax:stop() end) end
          e.klax = nil
        end
      end
    end
  end
end

-- ── the Ladder Controller's screen (img:text, the console's way) ───────────
local SW, SH = 1024, 512
local F_MONO, F_LABEL = "fonts/SolarMono.ttf", "fonts/SolarLabel.ttf"
local PH, PHD, AMB, RED = { 0.64, 0.93, 0.56 }, { 0.30, 0.46, 0.27 }, { 1.0, 0.78, 0.28 }, { 1.0, 0.36, 0.26 }
PLC_DIRTY = true
local function bits8(t) local s = {} for k = 1, 8 do s[k] = (t and t[k]) and "1" or "0" end return table.concat(s) end
function plcLines(sid, uid)
  local o = readout(sid, uid)
  local L = LG()
  if not (o and L) then return nil end
  local rungs = program(sid, uid)
  local lines = {}
  local hdr = string.format("PLC %s  X %s  Y %s  M %s", o.stop and "STOP" or "RUN", bits8(o.X), bits8(o.Y), bits8(o.M))
  for k = 1, L.RUNGS do
    lines[#lines + 1] = { L.rungText(k, rungs[k]), (o.re and o.re[k]) and 1 or (L.rungActive(rungs[k]) and 0 or -1) }
  end
  return hdr, lines, o
end
local function paint_plc(e)
  if not (image and image.new and valid(e.screen)) then return end
  local hdr, lines, o = plcLines(e.sid, e.uid)
  if not hdr then return end
  local img = e.img
  if not img then
    local ok, im = pcall(image.new, SW, SH, 0.005, 0.02, 0.01, 1)
    if not ok or not im then return end
    img, e.img = im, im
  end
  pcall(img.fill, img, 0, 0, SW, SH, 0.006, 0.022, 0.012, 1)
  pcall(img.fill, img, 0, 0, SW, 50, 0.02, 0.09, 0.045, 1)
  pcall(img.fill, img, 0, 50, SW, 2, PHD[1], PHD[2], PHD[3], 1)
  local hc = o.osc and AMB or (o.stop and AMB or PH)
  pcall(img.text, img, 16, 8, "LADDER CONTROLLER", 34, hc[1], hc[2], hc[3], 1, "left", F_LABEL)
  pcall(img.text, img, SW - 16, 12, hdr, 26, PH[1], PH[2], PH[3], 1, "right", F_MONO)
  -- the rungs in use, as large as fit (blank rungs are a count, not lines:
  -- read at a desk's distance, 16 lines of ladder are too small), lit while
  -- their coil is energised, between the power rails
  local used = {}
  for _, l in ipairs(lines) do if l[2] >= 0 then used[#used + 1] = l end end
  local n = math.max(1, #used)
  local cols = (n > 9) and 2 or 1
  local per = math.ceil(n / cols)
  local y0 = 62
  local dy = math.min(50, math.floor((SH - y0 - 40) / per))
  local fs = math.min(40, math.floor(dy * 0.8))
  if cols == 2 then fs = math.min(fs, 26) end
  local cw = SW / cols
  local t = { hdr }
  for c = 0, cols - 1 do
    local x0 = c * cw
    pcall(img.fill, img, x0 + 6, y0, 4, dy * per, PHD[1], PHD[2], PHD[3], 1)
    pcall(img.fill, img, x0 + cw - 10, y0, 4, dy * per, PHD[1], PHD[2], PHD[3], 1)
  end
  for k, l in ipairs(used) do
    local c = math.floor((k - 1) / per)
    local r = (k - 1) % per
    local x0, y = c * cw, y0 + r * dy
    local col = (l[2] == 1) and PH or { PH[1] * 0.6, PH[2] * 0.6, PH[3] * 0.6 }
    if l[2] == 1 then pcall(img.fill, img, x0 + 12, y + 2, cw - 24, dy - 4, 0.05, 0.17, 0.06, 1) end
    pcall(img.text, img, x0 + 16, y + math.floor((dy - fs) / 2), l[1], fs, col[1], col[2], col[3], 1, "left", F_MONO)
  end
  pcall(img.text, img, 16, SH - 34, string.format("%d RUNGS IN USE · %d BLANK · RIGHT-CLICK TO PROGRAM", #used, #lines - #used), 24, PHD[1] * 2, PHD[2] * 1.7, PHD[3] * 2, 1, "left", F_MONO)
  for _, l in ipairs(lines) do t[#t + 1] = l[1] .. ((l[2] == 1) and " *" or "") end
  e.text = table.concat(t, " | ")
  local ok, tex = pcall(img.texture, img)
  if ok and tex and e.tex ~= tex then
    e.tex = tex
    pcall(e.screen.setMaterial, e.screen, { texture = tex, unlit = true, color = { 1, 1, 1 } })
  end
end
function screenText(sid, uid) local e = PIECE[keyOf(sid, uid)]; return e and e.text or nil end
local paint_t = -10
local function screens_tick(t)
  if not PLC_DIRTY or t - paint_t < 0.5 then return end
  local a = find and find("Astronaut")
  local any = false
  for key, e in pairs(PIECE) do
    local m = META[key]
    if m and m.kind == "plc" and valid(e.screen) and valid(e.node) then
      local w = e.node.worldPos
      if (not valid(a)) or len3(w.x - a.x, w.y - a.y, w.z - a.z) < 30 or EDIT.sid == m.sid then paint_plc(e); any = true end
    end
  end
  paint_t = t
  PLC_DIRTY = false
  return any
end

-- ── the ladder editor (a CRT panel; ui.make while it is open) ───────────────
EDIT = { sid = nil, uid = nil, node = nil, making = false }
editor = EDIT
function editorOpen(sid, uid)
  if sid then EDIT.sid, EDIT.uid = sid, uid; PLC_DIRTY = true end
  return EDIT.sid ~= nil
end
function editorClose()
  if EDIT.node and valid(EDIT.node) then EDIT.node:destroy() end
  EDIT.sid, EDIT.uid, EDIT.node = nil, nil, nil
  if input and input.setMouseLocked then pcall(input.setMouseLocked, true) end
end
function editCell(k, f, back)
  local L = LG()
  if not (L and EDIT.sid) then return false end
  local rungs = program(EDIT.sid, EDIT.uid)
  rungs[k] = L.editRung(rungs[k], f, back)
  setProgram(EDIT.sid, EDIT.uid, rungs)
  snd("audio/foley/key_strike.ogg", 0.35)
  return true
end
local function shifted() return input and input.key and (input.key("shift") or input.key("lshift")) or false end
local function ed_tree()
  local L = LG()
  local sid, uid = EDIT.sid, EDIT.uid
  local o = readout(sid, uid) or {}
  local rungs = program(sid, uid)
  local function lamp(on) return on and "crt/rowOn" or "crt/row" end
  local rows = { "col", key = "lp", style = "panel/frame", w = 980, h = "fit", dir = "col", gap = 6, pad = 14, align = "start",
    { "row", key = "hd", w = "100%", h = 28, gap = 8, pad = 0, align = "center",
      { "text", key = "h", style = "panel/heading", w = "grow", h = "fit", text = "LADDER CONTROLLER" },
      { "text", key = "st", style = o.stop and "hud/valueWarn" or "hud/value", w = 160, h = "fit", text = o.stop and "STOPPED" or (o.osc and "RUN · NOT SETTLING" or "RUN") } },
    { "text", key = "w", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Each rung: IF contact [AND|OR contact] THEN coil [after a delay]. Click a cell to step it, Shift+click to step back. ┤/├ is a normally closed contact. SET and RST latch a coil. X are the input pins, Y the outputs, M the inner relays." },
  }
  local well = { "col", key = "well", style = "hud/instrument", w = "100%", h = "fit", dir = "col", gap = 2, pad = 8 }
  -- the registers, lit
  local regs = { "row", key = "regs", w = "100%", h = 22, gap = 3, pad = 0, align = "center" }
  for _, grp in ipairs({ { "X", o.X }, { "Y", o.Y }, { "M", o.M } }) do
    regs[#regs + 1] = { "text", key = "rg" .. grp[1], style = "hud/micro", w = 22, h = 20, text = grp[1] }
    for k = 1, 8 do
      local on = grp[2] and grp[2][k]
      regs[#regs + 1] = { "box", key = "r" .. grp[1] .. k, style = on and "hud/lampOn" or "hud/lamp", w = 22, h = 18,
        { "text", key = "t", style = "hud/micro", w = "100%", h = "100%", text = tostring(k), textAlign = "center", textValign = "center" } }
    end
  end
  well[#well + 1] = regs
  for k = 1, (L and L.RUNGS or 16) do
    local r = rungs[k] or {}
    local on = o.re and o.re[k]
    local st = lamp(on)
    local function b(f, w, txt, s)
      return { "button", key = f, style = s or st, w = w, h = 22, text = txt, textAlign = "center", textValign = "center",
        onClicked = function() editCell(k, f, shifted()) end }
    end
    local dim = "crt/rowDim"
    local act = L and L.rungActive(r)
    well[#well + 1] = { "row", key = "r" .. k, w = "100%", h = 22, gap = 3, pad = 0, align = "center",
      { "text", key = "n", style = "hud/micro", w = 26, h = 20, text = string.format("%02d", k) },
      b("a", 62, r.a or "—", r.a and st or dim),
      b("na", 54, r.a and (r.na and "┤/├" or "┤ ├") or "", r.a and st or dim),
      b("op", 58, (r.op ~= "" and r.op) or "—", act and st or dim),
      b("b", 62, r.b or "—", r.b and st or dim),
      b("nb", 54, r.b and (r.nb and "┤/├" or "┤ ├") or "", r.b and st or dim),
      { "text", key = "ar", style = "hud/micro", w = 40, h = 20, text = act and "──▸" or "", textAlign = "center" },
      b("k", 58, r.k or "OUT", act and st or dim),
      b("c", 70, r.c and ("( " .. r.c .. " )") or "—", r.c and st or dim),
      b("d", 64, (r.d or 0) > 0 and string.format("%d s", r.d) or "no delay", act and st or dim),
      { "text", key = "ex", style = "hud/micro", w = "grow", h = 20, text = L and L.explain(r) or "" },
      b("clear", 30, "✕", dim) }
  end
  rows[#rows + 1] = well
  rows[#rows + 1] = { "row", key = "bt", w = "100%", h = 32, gap = 8, pad = 0, align = "center",
    { "button", key = "run", style = "panel/secondary", w = 180, h = 32, text = o.stop and "Run" or "Stop", textAlign = "center", textValign = "center",
      onClicked = function() setRun(sid, uid, o.stop == true) end },
    { "text", key = "hint", style = "panel/hint", w = "grow", h = "fit", text = "Wire sensors and buttons to X1–X8 and the doors, pumps, lamps to Y1–Y8 · Esc closes" },
    { "button", key = "ok", style = "panel/action", w = 150, h = 32, text = "Done", textAlign = "center", textValign = "center",
      onClicked = function() editorClose() end } }
  return rows
end
local function editor_tick()
  if not EDIT.sid then return end
  if input and input.setMouseLocked then pcall(input.setMouseLocked, false) end
  if input and input.pressed and input.pressed("escape") then
    local fb = ref("field_builder")
    if fb then fb.escTakenAt = now() end
    editorClose()
    return
  end
  if not valid(EDIT.node) then
    if EDIT.making or not spawn then return end
    local h = find and find("Ship HUD")
    if not h then return end
    EDIT.making = true
    pcall(spawn, "LogicLadderPanel", vec3(0, 0, 0), function(n)
      EDIT.making = false
      if not EDIT.sid then n:destroy() return end
      EDIT.node = n
    end, h)
    return
  end
  if ui and ui.make then pcall(ui.make, EDIT.node, { ed_tree() }) end
end

-- ── the menus ───────────────────────────────────────────────────────────────
local KIND_LABEL = { ["and"] = "AND", ["or"] = "OR", xor = "XOR", ["not"] = "NOT", timer = "TIMER", latch = "LATCH", cmp = "COMPARATOR",
  counter = "COUNTER", button = "BUTTON", lever = "LEVER", keypad = "KEYPAD", lamp = "LAMP", alarm = "ALARM", tx = "RADIO TX", rx = "RADIO RX",
  plc = "PLC", sensor = "SENSOR", device = "TERMINALS" }
local function fmtv(v, unit)
  if v == nil then return "—" end
  if unit == "atm" then return string.format("%.3f atm", v) end
  if unit == "K" then return string.format("%.0f K", v) end
  if unit == "kg/s" then return string.format("%.2f kg/s", v) end
  if unit == "m" then return v >= 98 and "nobody near" or string.format("%.1f m", v) end
  if unit == "%/h" then return string.format("%.2f %%/h", v) end
  if unit == "% open" then return string.format("%.0f %% open", v) end
  if unit == "%" then return string.format("%.1f %%", v) end
  if math.abs(v) < 10 then return string.format("%.4g", v) end
  return string.format("%.1f", v)
end
fmtValue = fmtv
local function step_of(P) return tonumber(P.step) or 1 end
local function from_label(w, here)
  local ST = ref("structures")
  local o = (w.a.sid == here.sid and w.a.uid == here.uid) and w.z or w.a
  local p = ST and ST.getPart(o.sid, o.uid)
  local d = p and defs(p.id)
  return string.format("%s %s", d and d.label or "piece", o.pin)
end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id) or {}
  if not (d.lg and d.lg.kind ~= "wire") then return {} end
  local sid, uid = rec.id, part.uid
  local key = keyOf(sid, uid)
  local kind = d.lg.kind
  local G = "Logic"
  local out = {}
  local P = paramsOf(sid, uid, d)
  out[#out + 1] = { id = "lg_state", type = "info", label = KIND_LABEL[kind] or "Logic", group = G, value = function()
    local o = readout(sid, uid)
    if not o then return "not on the network yet" end
    local s
    if kind == "sensor" then
      s = string.format("%s · %s %s %s · %s", fmtv(o.v, P.unit), P.mode == "below" and "below" or "above", fmtv(tonumber(P.set), P.unit),
        (o.v == nil) and "(nothing to read here)" or "", o.q and "ON" or "off")
    elseif kind == "timer" then
      s = string.format("%s %s s · %s%s", P.mode or "on", tostring(P.T), o.q and "ON" or "off", (o.left or 0) > 0 and string.format(" · %.1f s left", o.left) or "")
    elseif kind == "counter" then s = string.format("%d of %d · %s", o.count or 0, tonumber(P.n) or 1, o.q and "ON" or "off")
    elseif kind == "plc" then s = string.format("%s · Y %s", o.stop and "STOPPED" or "RUN", bits8(o.Y))
    elseif kind == "device" or kind == "lamp" or kind == "alarm" then
      local parts = {}
      for _, q in ipairs(o.pins) do parts[#parts + 1] = string.format("%s %s%s", q.n, q.b and "●" or "○", (q.io == "in" and q.wired == 0) and "" or "") end
      s = table.concat(parts, "  ")
    else s = o.q and "ON" or "off" end
    if o.osc then s = s .. " · DOESN'T SETTLE (a loop)" end
    return s
  end }
  -- the pins and their cables
  local ws = wiresAt(sid, uid)
  out[#out + 1] = { id = "lg_pins", type = "info", label = "Cables", group = G, value = function()
    local w2 = wiresAt(sid, uid)
    if #w2 == 0 then return "none yet · lay a Signal Cable from the LOGIC tab" end
    local s = {}
    for i, w in ipairs(w2) do if i <= 3 then s[#s + 1] = (w.a.sid == sid and w.a.uid == uid) and (w.a.pin .. " → " .. from_label(w, { sid = sid, uid = uid })) or (from_label(w, { sid = sid, uid = uid }) .. " → " .. w.z.pin) end end
    if #w2 > 3 then s[#s + 1] = string.format("+%d more", #w2 - 3) end
    return table.concat(s, " · ")
  end }
  if kind == "sensor" or kind == "cmp" then
    local st = step_of(P)
    out[#out + 1] = { id = "lg_setup", type = "action", label = "Setpoint +", group = G, keep = true, hint = function() return fmtv(tonumber(paramsOf(sid, uid, d).set), P.unit) end,
      act = function() setParam(sid, uid, "set", (tonumber(paramsOf(sid, uid, d).set) or 0) + st); return true end }
    out[#out + 1] = { id = "lg_setdn", type = "action", label = "Setpoint −", group = G, keep = true,
      act = function() setParam(sid, uid, "set", (tonumber(paramsOf(sid, uid, d).set) or 0) - st); return true end }
    out[#out + 1] = { id = "lg_mode", type = "toggle", label = "On above (off: on below)", group = G, keep = true,
      on = function() return paramsOf(sid, uid, d).mode ~= "below" end, act = function(want) setParam(sid, uid, "mode", want and "above" or "below") end }
    if d.lg.sense == "gas" then
      out[#out + 1] = { id = "lg_gas", type = "toggle", label = "Reads O2 (off: CO2)", group = G, keep = true,
        on = function() return paramsOf(sid, uid, d).gas ~= "co2" end, act = function(want) setParam(sid, uid, "gas", want and "o2" or "co2") end }
    elseif d.lg.sense == "temp" then
      out[#out + 1] = { id = "lg_src", type = "toggle", label = "Reads the fuel (off: the primary loop)", group = G, keep = true,
        on = function() return paramsOf(sid, uid, d).src == "fuel" end, act = function(want) setParam(sid, uid, "src", want and "fuel" or "primary") end }
    elseif d.lg.sense == "reactor" then
      out[#out + 1] = { id = "lg_src", type = "toggle", label = "Reads k (off: power %)", group = G, keep = true,
        on = function() return paramsOf(sid, uid, d).src == "k" end,
        act = function(want) setParam(sid, uid, "src", want and "k" or "power"); setParam(sid, uid, "set", want and 1.001 or 105); setParam(sid, uid, "step", want and 0.001 or 5); setParam(sid, uid, "unit", want and "k" or "%") end }
    end
  elseif kind == "timer" then
    local TS = { 0.5, 1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600 }
    out[#out + 1] = { id = "lg_tup", type = "action", label = "Delay longer", group = G, keep = true, hint = function() return tostring(paramsOf(sid, uid, d).T) .. " s" end,
      act = function() local L = LG(); setParam(sid, uid, "T", L.cycle(TS, tonumber(paramsOf(sid, uid, d).T) or 5)); return true end }
    out[#out + 1] = { id = "lg_tdn", type = "action", label = "Delay shorter", group = G, keep = true,
      act = function() local L = LG(); setParam(sid, uid, "T", L.cycle(TS, tonumber(paramsOf(sid, uid, d).T) or 5, true)); return true end }
    out[#out + 1] = { id = "lg_tmode", type = "action", label = "Mode", group = G, keep = true, hint = function() return ({ on = "on-delay", off = "off-delay", pulse = "pulse", clock = "clock" })[paramsOf(sid, uid, d).mode or "on"] end,
      act = function() local L = LG(); setParam(sid, uid, "mode", L.cycle({ "on", "off", "pulse", "clock" }, paramsOf(sid, uid, d).mode or "on")); return true end }
  elseif kind == "counter" then
    out[#out + 1] = { id = "lg_nup", type = "action", label = "Preset +1", group = G, keep = true, hint = function() return tostring(paramsOf(sid, uid, d).n) end,
      act = function() setParam(sid, uid, "n", (tonumber(paramsOf(sid, uid, d).n) or 1) + 1); return true end }
    out[#out + 1] = { id = "lg_ndn", type = "action", label = "Preset −1", group = G, keep = true,
      act = function() setParam(sid, uid, "n", math.max(1, (tonumber(paramsOf(sid, uid, d).n) or 1) - 1)); return true end }
    out[#out + 1] = { id = "lg_reset", type = "action", label = "Clear the count", group = G, act = function() return resetNode(sid, uid) end }
  elseif kind == "latch" then
    out[#out + 1] = { id = "lg_reset", type = "action", label = "Reset the latch", group = G, act = function() return resetNode(sid, uid) end }
  elseif kind == "button" then
    out[#out + 1] = { id = "lg_press", type = "action", label = "Press", group = G, keep = true, act = function() return press(sid, uid) end }
  elseif kind == "lever" then
    out[#out + 1] = { id = "lg_lever", type = "toggle", label = "Lever thrown", group = G, keep = true,
      on = function() return lever(sid, uid) end, act = function(want) setLever(sid, uid, want) end }
  elseif kind == "keypad" then
    out[#out + 1] = { id = "lg_code", type = "action", label = "Enter the code…", group = G, hint = "▦",
      act = function()
        local BP = ref("blueprints")
        if not (BP and BP.prompt) then return false end
        BP.prompt({ title = "Keypad", line = "Four digits.", text = "", placeholder = "····", maxLen = 8, ok = "Enter",
          onOk = function(text)
            snd("audio/foley/key_strike.ogg", 0.4)
            if tostring(text) == tostring(paramsOf(sid, uid, d).code or "1234") then press(sid, uid); return true end
            snd("audio/foley/buzz_denied.ogg", 0.5)
            return false, "wrong code"
          end })
        return true
      end }
    out[#out + 1] = { id = "lg_setcode", type = "action", label = "Set the code…", group = G,
      enabled = function() local c = ref("crew"); if not (c and c.hasRole and c.activeId) then return true end local ok, y = pcall(c.hasRole, c.activeId(), "engineer"); return ok and y == true end,
      why = function() return "Engineers only" end,
      act = function()
        local BP = ref("blueprints")
        if not (BP and BP.prompt) then return false end
        BP.prompt({ title = "Keypad code", line = "The digits that open it.", text = tostring(paramsOf(sid, uid, d).code or "1234"), maxLen = 8, ok = "Set it",
          onOk = function(text) if not tostring(text):match("^%d+$") then return false, "digits only" end setParam(sid, uid, "code", tostring(text)); return true end })
        return true
      end }
  elseif kind == "lamp" then
    out[#out + 1] = { id = "lg_col", type = "action", label = "Lens colour", group = G, keep = true, hint = function() return paramsOf(sid, uid, d).col or "green" end,
      act = function() local L = LG(); setParam(sid, uid, "col", L.cycle(LAMP_ORDER, paramsOf(sid, uid, d).col or "green")); local m = META[key]; if m then m.shown = nil end; return true end }
  elseif kind == "tx" or kind == "rx" then
    out[#out + 1] = { id = "lg_chup", type = "action", label = "Channel +", group = G, keep = true, hint = function() return "CH " .. tostring(paramsOf(sid, uid, d).ch or 1) end,
      act = function() setParam(sid, uid, "ch", (tonumber(paramsOf(sid, uid, d).ch) or 1) % 16 + 1); return true end }
    out[#out + 1] = { id = "lg_chdn", type = "action", label = "Channel −", group = G, keep = true,
      act = function() setParam(sid, uid, "ch", ((tonumber(paramsOf(sid, uid, d).ch) or 1) - 2) % 16 + 1); return true end }
  elseif kind == "plc" then
    out[#out + 1] = { id = "lg_edit", type = "action", label = "Program the ladder…", group = G, hint = "16 rungs",
      act = function() editorOpen(sid, uid); return true end }
    out[#out + 1] = { id = "lg_run", type = "toggle", label = "Running", group = G, keep = true,
      on = function() local o = readout(sid, uid); return not (o and o.stop) end, act = function(want) setRun(sid, uid, want) end }
  elseif kind == "device" and d.lg.dev == "rxconsole" then
    out[#out + 1] = { id = "lg_sb", type = "action", label = "Setback power +5 %", group = G, keep = true, hint = function() return tostring(paramsOf(sid, uid, d).set or 30) .. " %" end,
      act = function() setParam(sid, uid, "set", math.min(100, (tonumber(paramsOf(sid, uid, d).set) or 30) + 5)); return true end }
  end
  if #ws > 0 then
    out[#out + 1] = { id = "lg_up", type = "action", label = string.format("Take up its signal cable%s (%d)", #ws == 1 and "" or "s", #ws), group = G, danger = true, hint = "2 s",
      job = { secs = 2.0, label = "Taking up the cables",
        check = function() return true end, tick = function() end,
        done = function() local n = 0 for _, w in ipairs(wiresAt(sid, uid)) do takeUp(w.id); n = n + 1 end; return true, string.format("%d cables taken up", n) end } }
  end
  return out, (kind == "device") and nil or d.label
end
providerFn = provider
local reg_on = false

-- ── the LOGIC overlay (lateUpdate: drawn poses, this frame's body read) ────
OVERLAY_R = 120
LABEL_R = 25
MAX_LABELS = 10
local ON, OFF, OSC, AIR = { 1.0, 0.62, 0.20 }, { 0.36, 0.44, 0.40 }, { 1.0, 0.85, 0.25 }, { 0.62, 0.80, 0.95 }
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
function drawOverlay()
  drawn = { lines = 0, labels = 0, rings = 0, lit = 0 }
  if not (draw and draw.line and NET and STATE) then return drawn end
  local L = LG()
  local ST = ref("structures")
  local a = find and find("Astronaut")
  if not (L and ST and valid(a)) then return drawn end
  local bodies = {}
  local function B(name) local b = bodies[name]; if b == nil then b = space.body(name) or false; bodies[name] = b end return b or nil end
  local frames = {}
  local function FR(rec) local f = frames[rec.id]; if not f then f = frame(rec); frames[rec.id] = f end return f end
  local cam = eye_now()
  local function ring(x, y, z, r, col)
    if not (draw.ring and cam) then return end
    local nx, ny, nz = cam.x - x, cam.y - y, cam.z - z
    local l = math.max(len3(nx, ny, nz), 1e-6)
    draw.ring(x, y, z, nx / l, ny / l, nz / l, r, col[1], col[2], col[3], 1)
    drawn.rings = drawn.rings + 1
  end
  -- (labels queued, then only the MAX_LABELS nearest the eye drawn, nearest
  -- first, each nudged down off the ones already placed: a wall of tags reads as noise)
  local queue = {}
  local eye = cam or a
  local function label(x, y, z, t1, t2, col)
    if (x - eye.x) ^ 2 + (y - eye.y) ^ 2 + (z - eye.z) ^ 2 > LABEL_R * LABEL_R then return end
    queue[#queue + 1] = { x = x, y = y, z = z, t1 = t1, t2 = t2, col = col, d = (x - eye.x) ^ 2 + (y - eye.y) ^ 2 + (z - eye.z) ^ 2 }
  end
  local function flush_labels()
    if not (camera and camera.worldToScreen and draw.text) then return end
    table.sort(queue, function(p, q) return p.d < q.d end)
    local placed = {}
    for _, L_ in ipairs(queue) do
      if drawn.labels >= MAX_LABELS then break end
      local sx, sy, _, on = camera.worldToScreen(L_.x, L_.y, L_.z)
      if on then
        local w = math.max(#L_.t1 * 9.2, #(L_.t2 or "") * 7.8) + 16
        local ok = true
        for _ = 1, 8 do
          local hit = false
          for _, b in ipairs(placed) do if math.abs(b[1] - sx) < (b[3] + w) / 2 + 4 and math.abs(b[2] - sy) < 40 then hit = true end end
          if not hit then ok = true break end
          ok = false
          sy = sy + 42
        end
        if ok then
          placed[#placed + 1] = { sx, sy, w }
          local col = L_.col
          if draw.rect then draw.rect(sx - w / 2, sy - 4, w, L_.t2 and 37 or 21, 0.02, 0.03, 0.03, 0.74, 3) end
          draw.text(sx, sy, L_.t1, 14, col[1], col[2], col[3], 1, "center")
          if L_.t2 then draw.text(sx, sy + 17, L_.t2, 12, col[1], col[2], col[3], 0.9, "center") end
          drawn.labels = drawn.labels + 1
        end
      end
    end
  end
  local ph = (now() * 1.2) % 1
  -- the cables
  for _, id in ipairs(WORDER) do
    local r = W[id]
    local rf = ST.get(r.f)
    local b = rf and B(rf.b)
    if b then
      local fr = FR(rf)
      local pts = unflat(r.p)
      if #pts >= 2 then
        local x0, y0, z0 = to_body(fr, pts[1][1], pts[1][2], pts[1][3])
        if (b.x + x0 - eye.x) ^ 2 + (b.y + y0 - eye.y) ^ 2 + (b.z + z0 - eye.z) ^ 2 < OVERLAY_R * OVERLAY_R then
          local on = L.outOf(STATE, keyOf(r.a.sid, r.a.uid), r.a.pin)
          local i = NET.idx[keyOf(r.a.sid, r.a.uid)]
          local osc = i and NET.osc[i]
          local col = osc and OSC or (on and ON or OFF)
          if on then drawn.lit = drawn.lit + 1 end
          local W_ = {}
          for k, q in ipairs(pts) do
            local x, y, z = to_body(fr, q[1], q[2], q[3])
            W_[k] = { b.x + x + fr.U.x * 0.012, b.y + y + fr.U.y * 0.012, b.z + z + fr.U.z * 0.012 }
          end
          local tot = 0
          for k = 2, #W_ do
            local p, q = W_[k - 1], W_[k]
            draw.line(p[1], p[2], p[3], q[1], q[2], q[3], col[1], col[2], col[3], on and 1 or 0.8)
            drawn.lines = drawn.lines + 1
            tot = tot + len3(q[1] - p[1], q[2] - p[2], q[3] - p[3])
          end
          -- a lit signal runs from its output to its input: chevrons along it
          if on and tot > 0.2 then
            local nchev = math.max(1, math.floor(tot / 0.6))
            for c = 0, nchev - 1 do
              local s = (c + ph) / nchev * tot
              local acc = 0
              for k = 2, #W_ do
                local p, q = W_[k - 1], W_[k]
                local sl = len3(q[1] - p[1], q[2] - p[2], q[3] - p[3])
                if acc + sl >= s and sl > 1e-6 then
                  local f = (s - acc) / sl
                  local ux, uy, uz = (q[1] - p[1]) / sl, (q[2] - p[2]) / sl, (q[3] - p[3]) / sl
                  local px, py, pz = p[1] + (q[1] - p[1]) * f, p[2] + (q[2] - p[2]) * f, p[3] + (q[3] - p[3]) * f
                  local sx, sy, sz = fr.U.y * uz - fr.U.z * uy, fr.U.z * ux - fr.U.x * uz, fr.U.x * uy - fr.U.y * ux
                  local sll = math.max(len3(sx, sy, sz), 1e-6)
                  sx, sy, sz = sx / sll, sy / sll, sz / sll
                  local h = 0.05
                  draw.line(px, py, pz, px - ux * h + sx * h, py - uy * h + sy * h, pz - uz * h + sz * h, col[1], col[2], col[3], 1)
                  draw.line(px, py, pz, px - ux * h - sx * h, py - uy * h - sy * h, pz - uz * h - sz * h, col[1], col[2], col[3], 1)
                  drawn.lines = drawn.lines + 2
                  break
                end
                acc = acc + sl
              end
            end
          end
        end
      end
    end
  end
  -- the pieces: each pin's lamp, each node's state
  local radios = {}
  for _, node in ipairs(NET.N) do
    local m = META[node.key]
    local rec = m and ST.get(m.sid)
    local b = rec and B(rec.b)
    if b then
      local fr = FR(rec)
      local p = ST.getPart(m.sid, m.uid)
      if p then
        local cx, cy, cz = to_body(fr, p.x or 0, p.y or 0, p.z or 0)
        if (b.x + cx - eye.x) ^ 2 + (b.y + cy - eye.y) ^ 2 + (b.z + cz - eye.z) ^ 2 < OVERLAY_R * OVERLAY_R then
          local o = readout(m.sid, m.uid)
          local i = NET.idx[node.key]
          local hasWire = false
          for _, q in ipairs(o and o.pins or {}) do
            local lx, ly, lz = pinLocal(m.sid, m.uid, q.n)
            if lx then
              local x, y, z = to_body(fr, lx, ly, lz)
              local wired = q.io == "out" or (q.wired or 0) > 0
              if q.io == "out" then for _, w in ipairs(wiresAt(m.sid, m.uid)) do if w.a.sid == m.sid and w.a.uid == m.uid and w.a.pin == q.n then hasWire = true end end
              elseif (q.wired or 0) > 0 then hasWire = true end
              if wired or m.kind ~= "device" then ring(b.x + x, b.y + y, b.z + z, 0.018, q.b and ON or OFF) end
            end
          end
          if (m.kind ~= "device" or hasWire) and o then
            local lx, ly, lz = pieceToLocal(p, 0, 0.12, 0)
            if m.kind == "device" or m.kind == "plc" then lx, ly, lz = pieceToLocal(p, 0, (m.def.box and m.def.box[4] or 1) + 0.25, 0) end
            local x, y, z = to_body(fr, lx, ly, lz)
            local P = paramsOf(m.sid, m.uid, m.def)
            local t1 = string.upper(m.def.label or "?")
            -- (a lamp or a beacon has no output: it is on while its IN is)
            local qon = o.q
            if m.kind == "lamp" or m.kind == "alarm" then qon = lampOn(m.sid, m.uid) end
            if not (m.kind == "device" or m.kind == "plc") then t1 = t1 .. (qon and " · ON" or " · off") end
            local t2 = nil
            if m.kind == "sensor" then t2 = string.format("%s · %s %s", fmtv(o.v, P.unit), P.mode == "below" and "<" or ">", fmtv(tonumber(P.set), P.unit))
            elseif m.kind == "timer" then t2 = string.format("%s %s s%s", P.mode or "on", tostring(P.T), (o.left or 0) > 0 and string.format(" · %.1f s left", o.left) or "")
            elseif m.kind == "counter" then t2 = string.format("count %d of %s", o.count or 0, tostring(P.n))
            elseif m.kind == "tx" or m.kind == "rx" then t2 = "CH " .. tostring(P.ch or 1)
            elseif m.kind == "plc" then t2 = string.format("%s · Y %s", o.stop and "STOP" or "RUN", bits8(o.Y))
            elseif m.kind == "device" then
              local s = {}
              for _, q in ipairs(o.pins) do if q.io == "out" or (q.wired or 0) > 0 then s[#s + 1] = string.format("%s %s", q.n, q.b and "●" or "○") end end
              t2 = table.concat(s, "  ")
            end
            if i and NET.osc[i] then t2 = (t2 or "") .. " · LOOP DOESN'T SETTLE" end
            label(b.x + x, b.y + y, b.z + z, t1, t2, (i and NET.osc[i]) and OSC or (qon and ON or { 0.72, 0.80, 0.74 }))
          end
          if m.kind == "tx" or m.kind == "rx" then radios[#radios + 1] = { m = m, x = b.x + cx, y = b.y + cy + 0.4, z = b.z + cz } end
        end
      end
    end
  end
  -- the radio links: a dashed line between each transmitter and its receivers in view
  for _, w in ipairs(NET.wires) do
    if w.air then
      local ka, kz = NET.N[w.a].key, NET.N[w.z].key
      local A_, Z_ = nil, nil
      for _, r in ipairs(radios) do if keyOf(r.m.sid, r.m.uid) == ka then A_ = r end if keyOf(r.m.sid, r.m.uid) == kz then Z_ = r end end
      if A_ and Z_ then
        local on = L.outOf(STATE, ka, "air")
        local col = on and ON or AIR
        local n = 12
        for k = 0, n - 1, 2 do
          local f0, f1 = k / n, (k + 1) / n
          draw.line(A_.x + (Z_.x - A_.x) * f0, A_.y + (Z_.y - A_.y) * f0, A_.z + (Z_.z - A_.z) * f0,
                    A_.x + (Z_.x - A_.x) * f1, A_.y + (Z_.y - A_.y) * f1, A_.z + (Z_.z - A_.z) * f1, col[1], col[2], col[3], 0.8)
          drawn.lines = drawn.lines + 1
        end
      end
    end
  end
  flush_labels()
  return drawn
end

-- ── save ────────────────────────────────────────────────────────────────────
function saveNow()
  local L = LG()
  if not (save and save.set and L and STATE) then return end
  save.set("lg.st", L.pack(STATE))
  save.set("lg.a", STATE.a)
end

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("logic_net")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  W, WORDER, NET, STATE = nil, {}, nil, nil
  TG, META, DOORS, CYCLE, LAMPS, ALARMS, SETBACK, PIECE, MESH, MESH_DIRTY = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
  sig_ver, wsig_ver, sig, pending_t = -1, -1, nil, nil
  tick_t, sense_t, save_t = -10, -10, -10
  EDIT.sid, EDIT.uid, EDIT.node = nil, nil, nil
end
-- (probes: drop the cached network and state and read the save again)
function reloadFromSave()
  W, NET, STATE = nil, nil, nil
  sig_ver, wsig_ver, sig = -1, -1, nil
  for sid in pairs(MESH) do MESH_DIRTY[sid] = true end
end

local mesh_t = -10
function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "logic_net", order = 6 }); reg_on = true end
  end
  local ST = ref("structures")
  if not (ST and LG()) then return end
  local t = now()
  wensure()
  -- the drum put away: the end made off is let go
  if pending then
    local fb = ref("field_builder")
    if not (fb and fb.isOpen and fb.isOpen() and heldWire()) then clearPending() end
  end
  -- what the network is built from: compared only when the records move
  if ST.version ~= sig_ver or wversion ~= wsig_ver then
    if ST.version ~= sig_ver then reconcile() end
    sig_ver, wsig_ver = ST.version, wversion
    local s = signature()
    if s ~= sig then sig = s; pending_t = pending_t or t end
  end
  if pending_t and t - pending_t >= SOLVE_WAIT then
    pending_t = nil
    if NET then step(agency_now()) end
    build()
    sampleNow()
    step(agency_now())
  end
  if not NET or #NET.N == 0 then
    if next(MESH_DIRTY) and t - mesh_t > 0.2 then mesh_t = t; for sid in pairs(MESH_DIRTY) do MESH_DIRTY[sid] = nil; build_mesh(sid) end end
    if EDIT.sid then editor_tick() end
    return
  end
  -- the readings, a few times a second; the clock, at most ten
  local a = agency_now()
  local changed = 0
  if t - sense_t >= SENSE then sense_t = t; changed = sampleNow() end
  local due = LG().nextDue(NET, STATE)
  if dirty_now or changed > 0 or NET.ndirty > 0 or (due and due <= a) then
    if t - tick_t >= EVERY or dirty_now then
      tick_t = t
      dirty_now = false
      step(a)
    end
  else
    STATE.a = a
  end
  -- an airlock asked to cycle: the chamber hears it while the signal is on
  if next(CYCLE) then
    local RA = ref("room_air")
    if RA and RA.requestDoor then for key in pairs(CYCLE) do local m = META[key]; if m then RA.requestDoor(m.sid, m.uid) end end end
  end
  local w0 = wall()
  if t - flash_t >= 0.125 then flash_t = t; lamps_tick(t) end
  local w1 = wall()
  if screens_tick(t) then PROF.paints = PROF.paints + 1 end
  if w0 then local w2 = wall(); PROF.lampsum = PROF.lampsum + (w1 - w0) * 1000; PROF.paintsum = PROF.paintsum + (w2 - w1) * 1000 end
  if next(MESH_DIRTY) and t - mesh_t > 0.2 then
    mesh_t = t
    for sid in pairs(MESH_DIRTY) do MESH_DIRTY[sid] = nil; build_mesh(sid) end
  end
  if EDIT.sid then editor_tick() end
  if t - save_t >= SAVE_EVERY then save_t = t; saveNow() end
end

local spawn_t = -10
function lateUpdate(node, dt)
  if overlay_on() then drawOverlay() end
  -- (the meshes follow the crew's world, once a second, as base_cable's do)
  if now() - spawn_t > 1.0 and W then
    spawn_t = now()
    local a = find and find("Astronaut")
    local dom = valid(a) and space.dominant(a.x, a.y, a.z) or nil
    local ST = ref("structures")
    local want = {}
    for _, id in ipairs(WORDER) do local r = W[id]; if r.b == dom then want[r.f] = true end end
    for sid in pairs(want) do if not MESH[sid] then MESH_DIRTY[sid] = true end end
    for sid, E in pairs(MESH) do
      local rec = ST and ST.get(sid)
      if not want[sid] or not rec then if valid(E.node) then E.node:destroy() end MESH[sid] = nil end
    end
  end
end
