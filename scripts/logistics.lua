-- LOGISTICS — the scene half of quarries, conveyors, tubes, hoppers, silos and
-- loading chutes (expansion X5; work/expansion/PLAN.md §3.1–3.3, 3.5;
-- docs/base-building.md §23). The rules are quarry.lua and item_net.lua (pure).
--
-- On the Build Kit node (scenes/system.ron) beside fluid_net and logic_net.
--
--   NETWORKS  every structure piece with `it` on a world, read from the
--             records (body-relative: docs/positions-and-frames.md rule 1),
--             is one item_net per world, re-built when the records change
--             (debounced SOLVE_WAIT), never in a frame. Its stores are real
--             containers (inventory.lua): a hopper "hopper:<sid>.<uid>", a
--             silo "silo:<sid>.<uid>" (one material), a quarry drive's bin
--             "hopper:<sid>.<uid>" (500 kg). A chute's store is the hold of
--             the craft under its spout ("hold:<name>").
--   QUARRIES  four Quarry Posts on a rectangle and a Quarry Drive within
--             14 m (quarry.fromPosts). When it completes, the rectangle is
--             SURVEYED (a layer of 16 columns a frame: mineral_field.materialAt
--             under the ground's height by a ray), then the drive's bin is a
--             store with a quarry: its progress (cells) runs in item_net's
--             closed form, gated by the bin's room and the grid (base_grid
--             partServed, a 6 kW aux load while it digs).
--             NEAR (the crew on its world within LIVE_R and the ground
--             resident): the head digs each cell for real (terrain.dig, a
--             sharp ball that covers the cell) and the mineral field pays the
--             cut into the bin by what it removed (trackDig → terrain.yields:
--             the live path is the truth); the closed form makes nothing.
--             AWAY: the closed form makes the survey's estimate, and the cells
--             it claimed are dug when the ground is resident again, without
--             paying twice (CATCH_PER_S a second under the engine's edit
--             budget). Card 0658: at most quarry.MAX_QUARRIES a world.
--   THE CLOCK every world's network is stepped on the agency clock at EVERY s
--             (5 Hz) while anything moves, at IDLE_EVERY when nothing can, and
--             caught up in one call on load. Kilograms move as whole units
--             between the containers (inventory.transfer: the move ring sees
--             every one, so a flight log knows a hold was filled from a silo);
--             what a step moves less than a unit waits on its edge.
--   DRAWN     a belt's surface and its load are shaders (conveyor_run,
--             conveyor_load): their uniforms are set when a line's flow or
--             material changes, never a frame; no body rides a belt. The
--             gantry (bridge, cable, head) is three static nodes on the planet
--             per quarry in view, moved in lateUpdate.
--   READOUTS  the menus on every piece (prop provider), the LOGISTICS overlay
--             (F8 with the kit open): each line with chevrons and kg/s, each
--             store's fill, each quarry's rectangle, layer and rate, each
--             chute's craft, and LIMITED BY.
--
-- SAVE: lgx.<body> = { a } (the world's clock); qry.<sid>.<uid> = JSON of the
-- quarry (its frame and survey, prog, dug, paid, floor). Part states: a belt's
-- `rev` and `off`, a silo's `mat`, a drive's `off` (paused) and `floor`.
--
-- MACHINES (X6; scripts/machines.lua, refinery.lua): a crusher, a furnace, a
-- kiln or a mixer is two of the network's nodes, its inlet "mach:<sid>.<uid>.in"
-- and its outlet "mach:<sid>.<uid>.out" (real containers of the machine's
-- buffer kg); a Fabricator's store "fab:<sid>.<uid>" takes refined solids.
-- refinery.prepare sets each machine's power before a step (its duty: the
-- grid, cooling, water, its switch); what it worked comes out of its inlet in
-- whole units and what it made goes into its outlet; refinery.after runs the
-- Fabricators' queues on the same clock.
--
-- Probes: worlds, worldOf(body), quarryOf(sid, uid), stepNow(), readout(sid, uid),
-- setRun, setRev, setSiloMat, setPaused, overlay, overlayAlways, drawn, PROF.

EVERY = 0.2
IDLE_EVERY = 1.0
SOLVE_WAIT = 0.5
SAVE_EVERY = 5.0
LIVE_R = 1200          -- m: a quarry this near the crew on its world digs for real
VIS_R = 450            -- m: its gantry is drawn this near
CATCH_PER_S = 30       -- catch-up digs a second (one a frame at most)
CATCH_MAX = 30 * 86400 -- s: the longest catch-up one call makes
BELT_SPEED = 1.2       -- m/s a running belt
PROF = { build_ms = 0, step_ms = 0, digs = 0, catch = 0, tracked = 0, nets = 0, overlay_ms = 0, survey_ms = 0, late_ms = 0 }

overlay = false
overlayAlways = false
drawn = { lines = 0, labels = 0 }

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
local function say(s, secs) if caption then pcall(caption, s, secs or 5) end if log then log("logistics: " .. s) end end
local function enc(t) if not (json and json.encode) then return nil end local ok, s = pcall(json.encode, t); return ok and s or nil end
local function dec(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" or not (json and json.decode) then return nil end
  local ok, t = pcall(json.decode, s)
  return ok and type(t) == "table" and t or nil
end
local function mat_label(m) local M = ref("materials"); return (M and M.label and M.label(m)) or tostring(m) end
local function kg_of(m) local M = ref("materials"); return (M and M.kg and M.kg(m)) or 1 end
local function fmt_kg(v) v = v or 0; if v >= 10000 then return string.format("%.1f t", v / 1000) end return string.format("%.0f kg", v) end

local W = {}            -- body → world entry
local ver, pending_t = -1, nil
local tick_t, save_t = -10, -10
worlds = W
function worldOf(b) return W[b] end

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
local function keyOf(sid, uid) return tostring(sid) .. "." .. tostring(uid) end
local function cidOf(it, sid, uid)
  if it.kind == "silo" then return "silo:" .. keyOf(sid, uid) end
  if it.kind == "fab" then return "fab:" .. keyOf(sid, uid) end
  if it.kind == "machine" then return "mach:" .. keyOf(sid, uid) .. ".in", "mach:" .. keyOf(sid, uid) .. ".out" end
  return "hopper:" .. keyOf(sid, uid)
end
storeCid = cidOf

-- ── what a piece is, body-relative ──────────────────────────────────────────
local function frame_of(rec)
  local KS = ref("kit_snap")
  return KS and KS.frameOf(rec) or nil
end
local function toB(fr, lx, ly, lz)
  return fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz, fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz, fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
end
local function piece_point(fr, p, x, y, z)
  local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  local lx, lz = x * c + z * s, -x * s + z * c
  return toB(fr, (p.x or 0) + lx, (p.y or 0) + y, (p.z or 0) + lz)
end

-- the stores' labels ("Hopper 2", "Silo 1 · Iron Ore"), and whether one stands
local labels = {}
function storeLabel(cid) return labels[cid] end
-- (X6) the stores within `reach` m of world point (x, y, z) on body `bname`:
-- the Fabricators' stores (their crates are in an Engineer's reach) → { { id, d, label } }
function storesNear(bname, x, y, z, reach)
  local w = W[bname]
  local b = space and space.body and space.body(bname)
  local out = {}
  if not (w and b) then return out end
  for _, P in ipairs(w.pieces or {}) do
    local function add(cid, lbl)
      local d = math.sqrt((b.x + P.gx - x) ^ 2 + (b.y + P.gy - y) ^ 2 + (b.z + P.gz - z) ^ 2)
      if d <= reach then out[#out + 1] = { id = cid, d = d, label = lbl } end
    end
    if P.cid and P.fab then add(P.cid, P.label) end
  end
  return out
end
function storeExists(cid) return labels[cid] ~= nil end

-- ── BUILD a world's network from the records ───────────────────────────────
local Q, N = nil, nil
local function libs() Q, N = ref("quarry"), ref("item_net"); return Q and N end

local function load_quarry(key)
  local t = dec(save and save.get and save.get("qry." .. key))
  if type(t) ~= "table" then return nil end
  return t
end
local function save_quarry(e)
  if not (save and save.set) then return end
  local t = { sig = e.sig, prog = e.prog or 0, dug = e.dug or 0, paid = e.paid or 0, q = e.q and Q.pack(e.q) or nil }
  save.set("qry." .. e.key, enc(t) or false)
end

local function build_world(body, recs)
  local w0 = wall()
  local old = W[body]
  local w = old or { body = body, quarries = {}, acc = {}, made = {}, a = nil, vis = {}, beltSet = {} }
  if not old then
    local sv = save and save.get and save.get("lgx." .. body)
    if type(sv) == "table" then w.a = tonumber(sv.a) end
  end
  w.pieces, w.recs = {}, {}
  w.settled = nil
  local posts, drives, chutes, belts = {}, {}, {}, {}
  local n_hop, n_silo, n_chute = 0, 0, 0
  local n_mach, n_fab = {}, 0
  w.machines = {}
  local MC = ref("machines")
  for _, rec in ipairs(recs) do
    local fr = frame_of(rec)
    w.recs[rec.id] = rec
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      local it = d and d.it
      if it and fr and it.kind ~= "visual" then
        local st = part_state(rec.id, p.uid) or {}
        local key = keyOf(rec.id, p.uid)
        local gx, gy, gz = piece_point(fr, p, 0, 0, 0)
        local ports = {}
        local rev = st.rev == true
        for _, pt in ipairs(d.ports or {}) do
          local x, y, z = piece_point(fr, p, pt.x, pt.y or 0.8, pt.z)
          local role = pt.role or "any"
          if rev then role = (role == "in") and "out" or ((role == "out") and "in" or role) end
          ports[#ports + 1] = { x = x, y = y, z = z, bore = pt.bore, role = role, name = pt.name, side = pt.side }
        end
        local P = { key = key, sid = rec.id, uid = p.uid, def = d, it = it, ports = ports, gx = gx, gy = gy, gz = gz, rec = rec, part = p }
        if it.kind == "post" then posts[#posts + 1] = P
        elseif it.kind == "belt" or it.kind == "tube" or it.kind == "blower" then
          P.kind = it.kind
          P.cap = it.cap
          P.len = it.len
          local BG = ref("base_grid")
          local served = BG and BG.partServed and BG.partServed(rec.id, p.uid)
          P.ok = not st.off and served ~= false
          P.why = st.off and "switched off (its RUN terminal, or its menu)" or ((served == false) and "no power: the grid is short" or nil)
          -- the drawn run: its ports, in order (for the overlay)
          P.segs = {}
          for k = 1, #ports - 1 do P.segs[#P.segs + 1] = { ports[k], ports[#ports] } end
          belts[#belts + 1] = P
          w.pieces[#w.pieces + 1] = P
        elseif it.kind == "hopper" or it.kind == "silo" then
          P.kind = "store"
          P.cap = it.kg
          P.one = it.kind == "silo"
          P.mat = st.mat
          P.cid = cidOf(it, rec.id, p.uid)
          if it.kind == "hopper" then n_hop = n_hop + 1; P.label = "Hopper " .. n_hop else n_silo = n_silo + 1; P.label = "Silo " .. n_silo end
          w.pieces[#w.pieces + 1] = P
        elseif it.kind == "drive" then
          P.kind = "store"
          P.cap = it.buf or 500
          P.cid = cidOf(it, rec.id, p.uid)
          P.label = "Quarry Drive " .. (#drives + 1)
          drives[#drives + 1] = P
          w.pieces[#w.pieces + 1] = P
        elseif it.kind == "machine" and MC and MC.MACH[it.m] then
          -- (X6) its inlet (this piece's key) and its outlet (key .. ">")
          local M = MC.MACH[it.m]
          P.kind = "machine"
          P.m = it.m
          P.capIn, P.capOut = M.capIn or 200, M.capOut or 200
          P.conv, P.accept = MC.convOf(it.m), MC.acceptOf(it.m)
          P.cid, P.ocid = cidOf(it, rec.id, p.uid)
          n_mach[it.m] = (n_mach[it.m] or 0) + 1
          P.label = M.label .. " " .. n_mach[it.m]
          P.cap = P.capIn
          w.pieces[#w.pieces + 1] = P
          w.machines[#w.machines + 1] = P
        elseif it.kind == "fab" then
          -- (X6) a Fabricator's store: refined solids in, its crates kept in it
          P.kind = "store"
          P.cap = it.kg or 2000
          P.cid = cidOf(it, rec.id, p.uid)
          P.accept = MC and MC.FAB_TAKES or nil
          n_fab = n_fab + 1
          P.label = "Fabricator " .. n_fab
          P.fab = true
          w.pieces[#w.pieces + 1] = P
          w.machines[#w.machines + 1] = P
        elseif it.kind == "electro" then
          -- (X6) not on the belts: water in and propellant out are fluid_net's (refinery.lua)
          n_mach[it.m] = (n_mach[it.m] or 0) + 1
          P.kind = "electro"
          P.m = it.m
          P.label = ((MC and MC.MACH[it.m] and MC.MACH[it.m].label) or "Electrolyser") .. " " .. n_mach[it.m]
          w.machines[#w.machines + 1] = P
        elseif it.kind == "chute" then
          n_chute = n_chute + 1
          P.kind = "chute"
          P.label = "Loading Chute " .. n_chute
          local m = it.mouth or { 0, 1.85, 2.2 }
          P.mx, P.my, P.mz = piece_point(fr, p, m[1], m[2], m[3])
          P.reach = it.reach or 6
          chutes[#chutes + 1] = P
          w.pieces[#w.pieces + 1] = P
        end
      end
    end
  end
  -- the stores' containers: a drive's bin is 500 kg
  local inv = ref("inventory")
  for _, P in ipairs(w.pieces) do
    if P.cid then
      labels[P.cid] = P.label
      if inv and inv.setCap and P.it.kind == "drive" and (inv.cap(P.cid) or 0) ~= P.cap then inv.setCap(P.cid, P.cap) end
      -- (X6) a machine's buffers
      if inv and inv.setCap and P.kind == "machine" then
        if (inv.cap(P.cid) or 0) ~= P.capIn then inv.setCap(P.cid, P.capIn) end
        if (inv.cap(P.ocid) or 0) ~= P.capOut then inv.setCap(P.ocid, P.capOut) end
        labels[P.ocid] = P.label .. " outlet"
      end
    end
  end
  -- QUARRIES: posts grouped by distance (a side ≤ 32 m), each group of four a rectangle
  local groups = {}
  do
    local parent = {}
    local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
    for i = 1, #posts do parent[i] = i end
    local lim = (Q.SIDE_MAX * 1.42 + 1)
    for i = 1, #posts do for j = i + 1, #posts do
      local a, b = posts[i], posts[j]
      if math.sqrt((a.gx - b.gx) ^ 2 + (a.gy - b.gy) ^ 2 + (a.gz - b.gz) ^ 2) <= lim then
        local ra, rb = find(i), find(j)
        if ra ~= rb then parent[rb] = ra end
      end
    end end
    local by = {}
    for i = 1, #posts do local r = find(i); by[r] = by[r] or {}; table.insert(by[r], posts[i]) end
    for _, g in pairs(by) do groups[#groups + 1] = g end
    table.sort(groups, function(a, b) return a[1].key < b[1].key end)
  end
  local seen = {}
  w.frames = {}
  local nq = 0
  for _, g in ipairs(groups) do
    local pts = {}
    for _, P in ipairs(g) do pts[#pts + 1] = { x = P.gx, y = P.gy, z = P.gz } end
    local q, why = Q.fromPosts(pts, {})
    local F = { posts = g, q = q, why = why }
    w.frames[#w.frames + 1] = F
    if q then
      -- the drive nearest the rectangle, within DRIVE_R of its edge
      local best, bd = nil, Q.DRIVE_R
      for _, D in ipairs(drives) do
        if not D.quarry then
          local lx, _, lz = Q.toLocal(q, D.gx, D.gy, D.gz)
          local dx, dz = math.max(0, math.abs(lx) - q.hx), math.max(0, math.abs(lz) - q.hz)
          local dd = math.sqrt(dx * dx + dz * dz)
          if dd <= bd then best, bd = D, dd end
        end
      end
      if not best then F.why = "no Quarry Drive within 14 m of the posts: set one beside them"
      else
        nq = nq + 1
        local sig = {}
        for _, P in ipairs(g) do sig[#sig + 1] = string.format("%.1f,%.1f,%.1f", P.gx, P.gy, P.gz) end
        table.sort(sig)
        local sigs = table.concat(sig, ";")
        local e = w.quarries[best.key]
        if not e then
          e = { key = best.key, sid = best.sid, uid = best.uid, prog = 0, dug = 0, paid = 0 }
          local t = load_quarry(best.key)
          if t and t.sig == sigs and t.q then
            e.q = Q.unpackQ(t.q)
            e.prog, e.dug, e.paid = tonumber(t.prog) or 0, tonumber(t.dug) or 0, tonumber(t.paid) or 0
          end
          w.quarries[best.key] = e
        end
        if e.sig and e.sig ~= sigs then e.q, e.prog, e.dug, e.paid, e.survey = nil, 0, 0, 0, nil end
        e.sig = sigs
        e.frame = F
        e.drive = best
        e.fresh = q
        best.quarry = e
        F.quarry = e
        if nq > Q.MAX_QUARRIES then e.refused = string.format("terrain budget: %d quarries a world until the engine evicts edited ground (card 0658)", Q.MAX_QUARRIES)
        else e.refused = nil end
        seen[best.key] = true
      end
    end
  end
  for k in pairs(w.quarries) do if not seen[k] then w.quarries[k] = nil end end
  -- the network
  local NP = {}
  for _, P in ipairs(w.pieces) do
    NP[#NP + 1] = { key = P.key, kind = P.kind, ports = P.ports, cap = P.cap, ok = P.ok, why = P.why, len = P.len, one = P.one, mat = P.mat,
                    label = P.label, src = P.quarry ~= nil, slack = (P.kind == "store" or P.kind == "machine") and 8 or nil,   -- (whole units: a store within a unit of its cap is full)
                    accept = P.accept, conv = P.conv, capIn = P.capIn, capOut = P.capOut, kw = 0 }
  end
  w.byKey = {}
  for _, P in ipairs(w.pieces) do
    w.byKey[P.key] = P
    -- (X6) a machine's outlet node reads and fills its outlet container
    if P.kind == "machine" then w.byKey[P.key .. ">"] = { key = P.key .. ">", cid = P.ocid, label = P.label .. " outlet", outlet = P, it = P.it, rec = P.rec, part = P.part } end
  end
  local net = N.build(NP)
  -- keep what the old state held for its quarries (progress lives in the quarry entry)
  w.net = net
  w.st = N.newState(net)
  w.chutes = chutes
  w.belts = belts
  w.rep = nil
  if not w.a then w.a = agency_now() end
  W[body] = w
  if #w.pieces == 0 and #posts == 0 and #w.machines == 0 then W[body] = nil end
  local RF = ref("refinery")
  if RF and RF.built then RF.built(w) end
  if w0 then PROF.build_ms = (wall() - w0) * 1000 end
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
end

-- ── the quarry's survey (a layer of 16 columns a frame, the crew near) ─────
local function ground_at(b, q, lx, lz)
  if not (terrain and terrain.raycast) then return nil end
  local x, y, z = Q.toBody(q, lx, 40, lz)
  local h = terrain.raycast(vec3(b.x + x, b.y + y, b.z + z), vec3(-q.U[1], -q.U[2], -q.U[3]), 120)
  if not (h and h.pos) then return nil end
  local _, ly = Q.toLocal(q, h.pos.x - b.x, h.pos.y - b.y, h.pos.z - b.z)
  return ly
end
local function survey_step(w, e, b)
  local MF, M = ref("mineral_field"), ref("materials")
  local q = e.fresh
  local S = e.survey
  if not S then
    -- the ground over the columns first
    local cols = Q.columns(q)
    local g = {}
    local top = -1e9
    for i, c in ipairs(cols) do
      local y = ground_at(b, q, c.lx, c.lz)
      if not y then return false end
      g[i] = y
      top = math.max(top, y)
    end
    q.ytop = math.max(0, math.ceil(top / Q.LAYER - 1e-6) * Q.LAYER)
    local _, _, _, layers = Q.cells(q)
    S = { k = 0, layers = layers, g = g, cols = cols, mix = {} }
    e.survey = S
    return false
  end
  local y = (q.ytop or 0) - (S.k + 0.5) * Q.LAYER
  local air, n, comp = 0, 0, {}
  for i, c in ipairs(S.cols) do
    n = n + 1
    if y > S.g[i] then air = air + 1
    else
      local x0, y0, z0 = Q.toBody(q, c.lx, y, c.lz)
      local m = MF and MF.materialAt and MF.materialAt(b.x + x0, b.y + y0, b.z + z0) or nil
      m = m or "regolith"
      comp[m] = (comp[m] or 0) + 1
    end
  end
  local solid = n - air
  local hard, hk, cl = 0, 0, {}
  for m, c in pairs(comp) do cl[m] = c / math.max(1, solid); hard = hard + (M and M.hardness and M.hardness(m) or 1) * c; hk = hk + c end
  S.mix[S.k + 1] = { air = air / math.max(1, n), hard = hk > 0 and hard / hk or 1, comp = cl }
  S.k = S.k + 1
  if S.k >= S.layers then
    q.mix = S.mix
    e.q = q
    e.survey = nil
    save_quarry(e)
    say(string.format("the quarry is surveyed: %.0f × %.0f m, %d layers to %.0f m · it starts digging", 2 * q.hx, 2 * q.hz, S.layers, S.layers * Q.LAYER - (q.ytop or 0)))
    return true
  end
  return false
end

-- the crew on this world (or the craft flown), and whether the quarry is near
local function observer()
  local a = find and find("Astronaut")
  if valid(a) then return a end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting and valid(v.node) then return v.node end
  end
  return valid(a) and a or nil
end

-- ── the quarry as the network's source ─────────────────────────────────────
local function attach_quarries(w, b, obs)
  local M = ref("materials")
  local cur = obs and space.dominant(obs.x, obs.y, obs.z) or nil
  PROF.att = string.format("%s|%s|%s|%s", tostring(cur), tostring(w.body), tostring(obs and obs.name), tostring(b ~= nil))
  for key, e in pairs(w.quarries) do
    local i = N.nodeOf(w.net, key)
    local node = i and w.net.nodes[i]
    if node then
      local q = e.q
      local st = part_state(e.sid, e.uid) or {}
      e.live = false
      if q and cur == w.body and b and obs then
        local x, y, z = Q.toBody(q, 0, 0, 0)
        local d = math.sqrt((obs.x - b.x - x) ^ 2 + (obs.y - b.y - y) ^ 2 + (obs.z - b.z - z) ^ 2)
        e.dist = d
        if d <= LIVE_R and (not terrain.ready or terrain.ready(b.x + x, b.y + y, b.z + z, 4.0)) then e.live = true end
      end
      node.blocked = nil
      if e.refused then node.blocked = e.refused
      elseif not q then node.blocked = e.survey and "surveying the ground" or "the ground isn't surveyed yet (it is when the crew is near)"
      elseif st.off then node.blocked = "paused (its menu)"
      elseif e.guard then node.blocked = e.guard
      else
        local BG = ref("base_grid")
        local served = BG and BG.partServed and BG.partServed(e.sid, e.uid)
        if served == false then node.blocked = "no power: the grid is short (6 kW)" end
      end
      local floor = tonumber(st.floor)
      if q then q.depth = math.min(Q.DEPTH_MAX, floor or Q.DEPTH_MAX) end
      if q then
        local live = e.live
        node.profile = function(prog)
          local P = Q.profile(q, prog, M)
          if live then P.kgps = {} end
          return P
        end
      else
        node.profile = nil
      end
      w.st.prog[i] = e.prog or 0
    end
  end
end

-- ── a chute's craft: one held on a stand or parked within its reach ────────
local function chute_target(P, b)
  if not (findScripts and b) then return nil end
  local mx, my, mz = b.x + P.mx, b.y + P.my, b.z + P.mz
  local best, bd = nil, P.reach
  for _, v in ipairs(findScripts("vessel_controller") or {}) do
    local n = v.node
    if valid(n) and not v.structureMode and v.holdId then
      local d = math.sqrt((n.x - mx) ^ 2 + (n.y - my) ^ 2 + (n.z - mz) ^ 2)
      if d < bd then best, bd = v, d end
    end
  end
  return best
end

-- ── one step of a world on the agency clock ────────────────────────────────
local function step_world(w, a, obs)
  local inv = ref("inventory")
  if not (inv and w.net) then return end
  local b = space and space.body and space.body(w.body)
  attach_quarries(w, b, obs)
  if not w.a then w.a = a end
  local dt = math.min(a - w.a, CATCH_MAX)
  if dt <= 0 then w.a = math.max(w.a, a - CATCH_MAX); return end
  local net, st = w.net, w.st
  local RF = ref("refinery")
  if RF and RF.prepare then RF.prepare(w, dt) end
  -- (X6) A SETTLED network: its last step moved, worked and made nothing, no
  -- container anywhere has changed since (inventory.bagVer), and every
  -- machine's power and quarry's state is as it was: nothing can move now
  -- either, so the step is skipped (the clock still advances). A chute's
  -- craft can come and go unseen, so a network with a chute always steps.
  local sig = nil
  if #w.chutes == 0 and inv.bagVer then
    local parts = {}
    for _, n in ipairs(net.nodes) do if n.conv then parts[#parts + 1] = string.format("%.6g", n.kw or 0) end end
    for _, P in ipairs(w.machines or {}) do
      local s0 = P.fab and RF and RF.stateOf and RF.stateOf(P.sid, P.uid)
      if s0 then parts[#parts + 1] = string.format("%.4g", s0.duty or -1) end
    end
    for k, e in pairs(w.quarries) do
      local i = N.nodeOf(net, k)
      parts[#parts + 1] = tostring(i and net.nodes[i].blocked) .. tostring(e.q ~= nil)
    end
    sig = table.concat(parts, "|")
    local S0 = w.settled
    if S0 and S0.ver == inv.bagVer and S0.sig == sig and not (RF and RF.busy and RF.busy(w)) then
      w.a = a
      PROF.skips = (PROF.skips or 0) + 1
      return
    end
  end
  w.settled = nil
  -- the stores as the containers hold them now (a hand or a run may have moved some)
  for i, n in ipairs(net.nodes) do
    local P = w.byKey[n.key]
    st.x[i] = {}
    if P and P.cid then
      for _, itx in ipairs(inv.items(P.cid) or {}) do st.x[i][itx.mat] = (itx.n or 0) * kg_of(itx.mat) end
    end
    if n.kind == "chute" then
      local v = (dt < 5) and chute_target(P, b) or nil
      n.target = v and v.holdId or nil
      P.craft = v and (v.craftName or "craft") or nil
      st.room[i] = n.target and (inv.free(n.target) or 0) or 0
    end
  end
  local w1 = wall()
  local rep = N.advance(net, st, dt)
  rep.matLabel = mat_label
  if w1 then PROF.adv_ms = (wall() - w1) * 1000 end
  PROF.segs = rep.segs
  PROF.ev = rep.events[1] and (rep.events[1].what .. ':' .. tostring(rep.events[1].i) .. ':' .. tostring(rep.events[1].mat)) or nil
  w.rep = rep
  -- what moved: whole units, container to container, the rest waits on its edge
  for k, kg in pairs(rep.moved) do
    if kg > 0 then
      local u, d, m = k:match("^(%d+)|(%d+)|(.+)$")
      u, d = tonumber(u), tonumber(d)
      local Pu, Pd = w.byKey[net.nodes[u].key], w.byKey[net.nodes[d].key]
      local from = Pu and Pu.cid
      local to = (net.nodes[d].kind == "chute") and net.nodes[d].target or (Pd and Pd.cid)
      local acc = (w.acc[k] or 0) + kg
      local ku = kg_of(m)
      local nunits = math.floor(acc / ku + 1e-9)
      if nunits > 0 and from and to then
        local got = inv.transfer(from, to, m, nunits)
        acc = acc - got * ku
      end
      w.acc[k] = math.min(acc, ku * 0.999)
    end
  end
  -- what the quarries made (away: the survey's estimate) into their bins
  for i, made in pairs(rep.made) do
    local P = w.byKey[net.nodes[i].key]
    local e = P and P.quarry
    for m, kg in pairs(made) do
      local k = i .. "|made|" .. m
      local acc = (w.made[k] or 0) + kg
      local ku = kg_of(m)
      local nunits = math.floor(acc / ku + 1e-9)
      if nunits > 0 and P and P.cid then
        local got = inv.add(P.cid, m, nunits, w.body)
        acc = acc - got * ku
      end
      w.made[k] = math.min(acc, ku * 0.999)
    end
  end
  -- (X6) what the machines worked comes out of their inlets, whole units
  for i, worked in pairs(rep.conv or {}) do
    local P = w.byKey[net.nodes[i].key]
    for m, kg in pairs(worked) do
      local k = i .. "|conv|" .. m
      local acc = (w.made[k] or 0) + kg
      local ku = kg_of(m)
      local nunits = math.floor(acc / ku + 1e-9)
      if nunits > 0 and P and P.cid then
        local got = inv.remove(P.cid, m, nunits)
        acc = acc - (got or 0) * ku
        if (got or 0) < nunits then acc = 0 end
      end
      w.made[k] = math.min(acc, ku * 0.999)
    end
  end
  if RF and RF.after then RF.after(w, rep, dt) end
  -- (X7) what each base mined, worked and sent down a chute (base_roles stats)
  local BR = ref("base_roles")
  if BR and BR.creditStep then pcall(BR.creditStep, w, rep) end
  -- (X6) settled? (nothing flowed, worked or was made: the next step can be skipped)
  if sig and #(rep.flows or {}) == 0 and #((rep.R and rep.R.convs) or {}) == 0 and next(rep.made) == nil then
    w.settled = { ver = inv.bagVer, sig = sig }
  end
  -- the quarries' progress; away, what they claimed is paid by the estimate
  for key, e in pairs(w.quarries) do
    local i = N.nodeOf(net, key)
    if i and st.prog[i] then
      e.prog = st.prog[i]
      if not e.live then e.paid = math.max(e.paid or 0, math.floor(e.prog + 1e-9)) end
    end
  end
  w.a = a
end

function stepNow()
  local a = agency_now()
  local obs = observer()
  for _, w in pairs(W) do step_world(w, a, obs) end
end

-- ── live digging (the crew near): the claimed cells, for real ──────────────
local catch_t = 0
local function dig_cell(w, e, b, i, tracked)
  local q = e.q
  local _, _, _, lx, ly, lz = Q.cellAt(q, i)
  local x, y, z = Q.toBody(q, lx, ly, lz)
  local wx, wy, wz = b.x + x, b.y + y, b.z + z
  if not (terrain and terrain.dig) then return false end
  local ok, rid = pcall(terrain.dig, wx, wy, wz, Q.DIG_R, 1.0, { hardness = 1.0, falloff = "sharp" })
  if not ok then return false end
  if tracked then
    local MF = ref("mineral_field")
    local P = e.drive
    if MF and MF.trackDig and P and P.cid and MF.trackDig(rid, wx, wy, wz, P.cid, Q.YIELD_K) then PROF.tracked = PROF.tracked + 1 end
    e.lastRid = rid
  end
  PROF.digs = PROF.digs + 1
  e.lastDig = time
  return true
end
local function dig_tick(w, b, dt)
  local budget = 1
  for _, e in pairs(w.quarries) do
    if e.live and e.q then
      local claimed = math.floor((e.prog or 0) + 1e-9)
      local behind = claimed - (e.dug or 0)
      if behind > 0 then
        local catching = behind > 2 or (e.dug or 0) < (e.paid or 0)
        if catching then
          catch_t = catch_t + dt * CATCH_PER_S
          if catch_t >= 1 and budget > 0 then
            catch_t = catch_t - 1
            budget = budget - 1
            local i = (e.dug or 0) + 1
            if dig_cell(w, e, b, i, i > (e.paid or 0)) then
              e.dug = i
              PROF.catch = PROF.catch + 1
              -- (the props and flora re-drop once a row, not a dig)
              if i % 8 == 0 then
                local FF = ref("flora_field")
                local x, y, z = Q.toBody(e.q, 0, 0, 0)
                if FF and FF.groundChanged then pcall(FF.groundChanged, b.x + x, b.y + y, b.z + z, math.max(e.q.hx, e.q.hz) * 1.45) end
              end
            end
          end
        elseif budget > 0 then
          budget = budget - 1
          local i = (e.dug or 0) + 1
          if dig_cell(w, e, b, i, i > (e.paid or 0)) then
            e.dug = i
            local FF = ref("flora_field")
            local _, _, _, lx, ly, lz = Q.cellAt(e.q, i)
            local x, y, z = Q.toBody(e.q, lx, ly, lz)
            if FF and FF.groundChanged then pcall(FF.groundChanged, b.x + x, b.y + y, b.z + z, Q.DIG_R + 0.3) end
          end
        end
      end
    end
  end
end

-- ── the grid's view: what a piece draws while it runs ──────────────────────
function gridAux(sid, uid)
  local d = nil
  local ST = ref("structures")
  -- (X6) a refinery machine or a Fabricator: refinery.lua's answer
  do
    local p0 = ST and ST.getPart and ST.getPart(sid, uid)
    local d0 = p0 and defs(p0.id)
    if d0 and d0.it and (d0.it.kind == "machine" or d0.it.kind == "fab" or d0.it.kind == "electro") then
      local RF = ref("refinery")
      return RF and RF.gridAux and RF.gridAux(sid, uid) or 0
    end
  end
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  d = p and defs(p.id)
  local it = d and d.it
  if not (it and it.kw) then return 0 end
  local rec = ST.get(sid)
  local w = rec and W[rec.b]
  if not (w and w.net) then return 0 end
  local key = keyOf(sid, uid)
  if it.kind == "drive" then
    local e = w.quarries[key]
    if not (e and e.q) then return 0 end
    local st = part_state(sid, uid) or {}
    if st.off or e.refused then return 0 end
    return it.kw
  end
  local li = w.net.lineOf and w.net.lineOf[key]
  local L = li and w.net.lines[li]
  if not L then return 0 end
  local st = part_state(sid, uid) or {}
  if st.off then return 0 end
  -- a line draws while it is switched on and joins a store to a store (not
  -- by its flow: the grid's answer gates the flow, and the load must not
  -- come and go with it)
  if #L.ups > 0 and #L.downs > 0 then return it.kw end
  return 0
end

-- ── controls ────────────────────────────────────────────────────────────────
local function touch(sid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local w = rec and W[rec.b]
  if w then step_world(w, agency_now(), observer()) end
  pending_t = now()
  ver = -1
end
function setRun(sid, uid, on) touch(sid); set_part_state(sid, uid, "off", (not on) or nil); return true end
function isRun(sid, uid) local st = part_state(sid, uid); return not (st and st.off) end
function setRev(sid, uid) local st = part_state(sid, uid) or {}; touch(sid); set_part_state(sid, uid, "rev", (not st.rev) or nil); return true end
function setSiloMat(sid, uid, m) touch(sid); set_part_state(sid, uid, "mat", m); return true end
function setPaused(sid, uid, on) touch(sid); set_part_state(sid, uid, "off", on and true or nil); return true end
function setFloor(sid, uid, depth) touch(sid); set_part_state(sid, uid, "floor", depth); return true end

-- the store's level (logic's Level Switch): % full
function levelOf(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  if not (d and d.it and (d.it.kind == "hopper" or d.it.kind == "silo" or d.it.kind == "drive")) then return nil end
  local inv = ref("inventory")
  local cid = cidOf(d.it, sid, uid)
  local cap = (d.it.kind == "drive") and (d.it.buf or 500) or d.it.kg
  return inv and 100 * (inv.mass(cid) or 0) / math.max(1, cap) or nil
end

function quarryOf(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local w = rec and W[rec.b]
  return w and w.quarries[keyOf(sid, uid)] or nil
end

-- A piece's numbers now: → { kind, line = { q, cap, ok, why, mat }, store = { kg, cap, items }, quarry = {…}, lim }
function readout(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local w = rec and W[rec.b]
  if not (w and w.net) then return nil end
  local key = keyOf(sid, uid)
  local P = w.byKey and w.byKey[key]
  local o = { key = key }
  local net, st, rep = w.net, w.st, w.rep
  local li = net.lineOf and net.lineOf[key]
  if li then
    local L = net.lines[li]
    local q, mat = 0, nil
    for _, fl in ipairs(rep and rep.flows or {}) do if fl.l == li then q = q + fl.q; mat = mat or fl.mat end end
    o.line = { q = q, cap = L.cap, ok = L.ok, why = L.why, idle = L.idle, mat = mat, kind = L.kind, n = #L.pieces }
    o.lim = N.lineWhy(net, st, rep, li, function(j) local Pj = w.byKey[net.nodes[j].key]; return Pj and Pj.label or "a store" end)
  end
  local i = N.nodeOf(net, key)
  if i then
    local n = net.nodes[i]
    local inv = ref("inventory")
    if P and P.cid and inv then
      o.store = { kg = inv.mass(P.cid) or 0, cap = n.cap, items = inv.items(P.cid) or {}, cid = P.cid, label = P.label, mat = n.mat }
    end
    if n.kind == "chute" then o.chute = { craft = P and P.craft, target = n.target, room = st.room[i] } end
    o.lim = N.limitedBy(net, st, rep, i, function(j) local Pj = w.byKey[net.nodes[j].key]; return Pj and Pj.label or "a store" end)
  end
  local RF = ref("refinery")
  if RF and RF.machineReadout and P and (P.kind == "machine" or P.fab or P.kind == "electro") then o.machine = RF.machineReadout(w, P) end
  if not P and RF and RF.machineReadout then
    for _, M in ipairs(w.machines or {}) do if M.key == key then o.machine = RF.machineReadout(w, M) end end
  end
  local e = w.quarries[key]
  if e then
    local q = e.q
    o.quarry = { live = e.live, prog = e.prog, dug = e.dug, paid = e.paid, refused = e.refused, surveying = e.survey ~= nil, q = q }
    if q then
      local k, depth = Q.depthAt(q, e.prog)
      local _, _, _, layers, total = Q.cells(q)
      o.quarry.layer, o.quarry.layers, o.quarry.depth, o.quarry.total = k, layers, depth, total
      local P2 = Q.profile(q, e.prog, ref("materials"))
      local f = rep and rep.R and rep.R.f and i and rep.R.f[i] or 0
      o.quarry.m3h = (P2.cps or 0) * Q.CELL_VOL * 3600 * f
      o.quarry.done = P2.done
    end
  end
  return o
end

-- ── save ────────────────────────────────────────────────────────────────────
function saveNow()
  if not (save and save.set) then return end
  for body, w in pairs(W) do
    save.set("lgx." .. body, { a = w.a })
    for _, e in pairs(w.quarries) do if e.q then save_quarry(e) end end
  end
end

-- ── drawn: the belts' shaders (on change), the gantry (in view) ────────────
local MATCOL = {
  regolith = { 0.48, 0.42, 0.35 }, soil = { 0.36, 0.28, 0.20 }, sand = { 0.70, 0.60, 0.42 }, gravel = { 0.50, 0.48, 0.45 },
  iron = { 0.46, 0.26, 0.18 }, hematite = { 0.52, 0.24, 0.16 }, rustrock = { 0.55, 0.30, 0.18 }, copper = { 0.40, 0.45, 0.30 },
  silica = { 0.78, 0.76, 0.70 }, ice = { 0.82, 0.88, 0.94 }, basalt = { 0.22, 0.22, 0.23 }, granite = { 0.55, 0.52, 0.50 },
  clay = { 0.58, 0.40, 0.28 }, ash = { 0.30, 0.30, 0.31 }, sulfur = { 0.85, 0.78, 0.25 }, obsidian = { 0.10, 0.10, 0.12 },
}
local function mat_col(m) return MATCOL[m or ""] or { 0.45, 0.42, 0.38 } end
local function belt_visuals(w)
  local ST = ref("structures")
  if not (ST and w.net) then return end
  local net, rep = w.net, w.rep
  local t = now()
  for li, L in ipairs(net.lines) do
    if L.kind == "belt" then
      local q, mat = 0, nil
      for _, fl in ipairs(rep and rep.flows or {}) do if fl.l == li then q = q + fl.q; mat = mat or fl.mat end end
      local run = L.ok and q > 1e-6
      local speed = run and BELT_SPEED or 0
      local fill = run and math.min(1, q / math.max(1e-6, L.cap)) or 0
      local sig = string.format("%.2f|%.2f|%s", speed, fill, tostring(mat))
      for _, key in ipairs(L.pieces) do
        local P = w.byKey[key]
        local n = P and ST.nodeOf(P.sid, P.uid)
        local S = w.beltSet[key]
        if valid(n) and (not S or S.sig ~= sig or S.node ~= n) then
          local rev = (part_state(P.sid, P.uid) or {}).rev == true
          local sp = rev and -speed or speed
          -- (the phase carried across a change, so the cleats don't jump)
          local off = 0
          if S and S.node == n then off = (S.sp - sp) * t + S.off end
          local c = mat_col(mat)
          local m1, m2 = n:find("Mesh"), n:find("Load")
          if m1 and m1.setShaderParam then pcall(m1.setShaderParam, m1, "speed", sp); pcall(m1.setShaderParam, m1, "off", off) end
          if m2 and m2.setShaderParam then
            pcall(m2.setShaderParam, m2, "speed", sp); pcall(m2.setShaderParam, m2, "off", off)
            pcall(m2.setShaderParam, m2, "fill", fill); pcall(m2.setShaderParam, m2, "col", c[1], c[2], c[3])
          end
          w.beltSet[key] = { sig = sig, node = n, sp = sp, off = off }
        end
      end
    end
  end
end

local function vis_drop(V)
  for _, k in ipairs({ "bridge", "cable", "head" }) do if V[k] and valid(V[k]) then V[k]:destroy() end V[k] = nil end
end
local function gantry(w, b, obs, dt)
  local planet = find and find(w.body)
  for key, e in pairs(w.quarries) do
    local V = w.vis[key] or {}
    w.vis[key] = V
    local q = e.q
    local near = q and planet and obs and e.dist and e.dist <= VIS_R
    if not near then
      if V.bridge or V.head then vis_drop(V) end
    else
      if not V.asked and spawn then
        V.asked = true
        for _, k in ipairs({ { "bridge", "KitQBridge_steel" }, { "cable", "KitQCable_steel" }, { "head", "KitQHead_steel" } }) do
          local x, y, z = Q.toBody(q, 0, 2.42, 0)
          pcall(spawn, k[2], vec3(b.x + x, b.y + y, b.z + z), function(n)
            if w.vis[key] ~= V then n:destroy() return end
            n:setUp(vec3(q.U[1], q.U[2], q.U[3]), vec3(-q.F[1], -q.F[2], -q.F[3]))
            n.x, n.y, n.z = x, y, z
            V[k[1]] = n
          end, planet)
        end
      end
      -- where the head is: between the cell it is on and the next, by progress
      local p = math.max(0, e.prog or 0)
      local i0 = math.max(1, math.floor(p) + 1)
      local f = p - math.floor(p)
      local _, _, _, ax, ay, az = Q.cellAt(q, i0)
      local _, _, _, bx, by, bz = Q.cellAt(q, i0 + 1)
      if math.abs(by - ay) > 1e-6 then bx, by, bz = ax, ay, az end
      local tx, ty, tz = ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f
      -- (smoothed in the quarry's frame, frame-rate independent; a jump snaps)
      local S = V.s
      if not S or math.abs(S[1] - tx) + math.abs(S[3] - tz) > 4 then S = { tx, ty, tz } end
      local k = 1 - math.exp(-6 * (dt or 0))
      S = { S[1] + (tx - S[1]) * k, S[2] + (ty - S[2]) * k, S[3] + (tz - S[3]) * k }
      V.s = S
      local top = 2.42
      local hy = S[2] - Q.LAYER / 2 + 0.1
      if valid(V.bridge) then
        local x, y, z = Q.toBody(q, 0, top, S[3])
        V.bridge.x, V.bridge.y, V.bridge.z = x, y, z
        V.bridge.scale_x = 2 * q.hx
      end
      if valid(V.head) then
        local x, y, z = Q.toBody(q, S[1], hy, S[3])
        V.head.x, V.head.y, V.head.z = x, y, z
      end
      if valid(V.cable) then
        local x, y, z = Q.toBody(q, S[1], top, S[3])
        V.cable.x, V.cable.y, V.cable.z = x, y, z
        V.cable.scale_y = math.max(0.05, top - (hy + 1.6))
      end
    end
  end
end

-- ── the LOGISTICS overlay (lateUpdate: drawn poses, this frame's body read) ─
OVERLAY_R = 220
LABEL_R = 45
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
local GREEN, AMBER, RED, DIM, BLUE = { 0.45, 0.95, 0.55 }, { 1.0, 0.75, 0.25 }, { 1.0, 0.32, 0.25 }, { 0.62, 0.66, 0.68 }, { 0.45, 0.75, 1.0 }
function drawOverlay()
  drawn = { lines = 0, labels = 0 }
  if not (draw and draw.line) then return drawn end
  local w0 = wall()
  local a = observer()
  if not valid(a) then return drawn end
  local placed = {}
  local function label(x, y, z, t1, t2, col)
    if not (camera and camera.worldToScreen and draw.text) then return end
    if (x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2 > LABEL_R * LABEL_R then return end
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    if not on then return end
    local wdt = math.max(#t1 * 9.5, #(t2 or "") * 7.6) + 16
    for _ = 1, 6 do
      local hit = false
      for _, bb in ipairs(placed) do if math.abs(bb[1] - sx) < (bb[3] + wdt) / 2 and math.abs(bb[2] - sy) < 40 then hit = true end end
      if not hit then break end
      sy = sy + 42
    end
    placed[#placed + 1] = { sx, sy, wdt }
    if draw.rect then draw.rect(sx - wdt / 2, sy - 4, wdt, t2 and 40 or 22, 0.02, 0.03, 0.04, 0.66, 4) end
    draw.text(sx, sy, t1, 16, col[1], col[2], col[3], 1, "center")
    if t2 then draw.text(sx, sy + 19, t2, 13, col[1], col[2], col[3], 0.9, "center") end
    drawn.labels = drawn.labels + 1
  end
  local function L(x1, y1, z1, x2, y2, z2, c) draw.line(x1, y1, z1, x2, y2, z2, c[1], c[2], c[3], 0.95); drawn.lines = drawn.lines + 1 end
  local cur = space.dominant(a.x, a.y, a.z)
  local w = W[cur]
  local b = space.body(cur)
  if not (w and b and w.net) then return drawn end
  local net, st, rep = w.net, w.st, w.rep
  local inv = ref("inventory")
  -- the lines
  for li, Ln in ipairs(net.lines) do
    local q, mat = 0, nil
    for _, fl in ipairs(rep and rep.flows or {}) do if fl.l == li then q = q + fl.q; mat = mat or fl.mat end end
    local col = (not Ln.ok) and (Ln.why and Ln.why:find("head on") and RED or AMBER) or (q > 1e-6 and GREEN or DIM)
    if Ln.kind == "tube" and Ln.ok then col = q > 1e-6 and BLUE or DIM end
    local mid = nil
    local nseg = 0
    for _, key in ipairs(Ln.pieces) do
      local P = w.byKey[key]
      if P and #P.ports >= 2 then
        local A, Bp = nil, nil
        for _, pt in ipairs(P.ports) do if pt.role == "in" then A = A or pt elseif pt.role == "out" then Bp = Bp or pt end end
        A, Bp = A or P.ports[1], Bp or P.ports[#P.ports]
        local x1, y1, z1 = b.x + A.x, b.y + A.y + 0.15, b.z + A.z
        local x2, y2, z2 = b.x + Bp.x, b.y + Bp.y + 0.15, b.z + Bp.z
        if (x1 - a.x) ^ 2 + (y1 - a.y) ^ 2 + (z1 - a.z) ^ 2 < OVERLAY_R * OVERLAY_R then
          L(x1, y1, z1, x2, y2, z2, col)
          nseg = nseg + 1
          if not mid and nseg >= math.ceil(#Ln.pieces / 2) then mid = { (x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2 } end
          -- chevrons the way it flows (more the more it carries)
          if q > 1e-6 then
            local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
            local len = math.sqrt(dx * dx + dy * dy + dz * dz)
            if len > 0.2 then
              local ux, uy, uz = dx / len, dy / len, dz / len
              local upx, upy, upz = (x1 - b.x), (y1 - b.y), (z1 - b.z)
              local ul = math.sqrt(upx * upx + upy * upy + upz * upz)
              upx, upy, upz = upx / ul, upy / ul, upz / ul
              local sx, sy, sz = upy * uz - upz * uy, upz * ux - upx * uz, upx * uy - upy * ux
              local nch = math.max(1, math.floor(len / 0.5 * math.min(1, 0.3 + q / Ln.cap)))
              local ph = (now() * 0.8) % 1
              for k = 0, nch - 1 do
                local f = (k + ph) / nch
                local px, py, pz = x1 + dx * f, y1 + dy * f, z1 + dz * f
                local h = 0.12
                L(px, py, pz, px - ux * h + sx * h, py - uy * h + sy * h, pz - uz * h + sz * h, col)
                L(px, py, pz, px - ux * h - sx * h, py - uy * h - sy * h, pz - uz * h - sz * h, col)
              end
            end
          end
        end
      end
    end
    if mid then
      local t1 = string.format("%s · %.2f kg/s%s", Ln.kind == "tube" and "TUBE" or "BELT", q, mat and (" · " .. mat_label(mat)) or "")
      local t2 = (not Ln.ok) and ("STOPPED · " .. tostring(Ln.why)) or (q <= 1e-6 and ("IDLE · " .. tostring(N.lineWhy(net, st, rep, li, function(j) local Pj = w.byKey[net.nodes[j].key]; return Pj and Pj.label or "a store" end) or "")) or string.format("of %.0f kg/s", Ln.cap))
      label(mid[1], mid[2] + 0.3, mid[3], t1, t2, col)
    end
  end
  -- the stores and chutes
  local RF = ref("refinery")
  if RF and RF.overlayLabels then RF.overlayLabels(w, b, label, L) end
  for i, n in ipairs(net.nodes) do
    local P = w.byKey[n.key]
    if P and not P.outlet and P.kind ~= "machine" and not P.fab then
      local top = (P.it.kind == "silo") and 6.9 or ((P.it.kind == "chute") and 3.6 or 2.9)
      local fr = frame_of(P.rec)
      local x, y, z = piece_point(fr, P.part, 0, top, 0)
      x, y, z = b.x + x, b.y + y, b.z + z
      if n.kind == "chute" then
        local craft = P.craft
        local t2 = craft and string.format("filling %s · %.0f kg of room", craft, st.room[i] or 0) or "no craft under the spout"
        label(x, y, z, P.label:upper(), t2, craft and GREEN or DIM)
        -- a line from the spout to the craft it fills (both drawn this frame)
        if n.target then
          local v = chute_target(P, b)
          if v and valid(v.node) then L(b.x + P.mx, b.y + P.my, b.z + P.mz, v.node.x, v.node.y, v.node.z, GREEN) end
        end
      elseif P.cid and inv then
        local kg = inv.mass(P.cid) or 0
        local items = inv.items(P.cid) or {}
        local parts = {}
        table.sort(items, function(p1, p2) return (p1.n or 0) * kg_of(p1.mat) > (p2.n or 0) * kg_of(p2.mat) end)
        for k = 1, math.min(3, #items) do parts[#parts + 1] = string.format("%s %s", mat_label(items[k].mat), fmt_kg(items[k].n * kg_of(items[k].mat))) end
        local pct = kg / math.max(1, n.cap)
        local bar = string.rep("|", math.floor(pct * 20 + 0.5)) .. string.rep(".", 20 - math.floor(pct * 20 + 0.5))
        local t1 = string.format("%s · %s / %s", P.label:upper(), fmt_kg(kg), fmt_kg(n.cap))
        local t2 = "[" .. bar .. "] " .. (#parts > 0 and table.concat(parts, " · ") or (n.one and (n.mat and ("set to " .. mat_label(n.mat)) or "empty · takes the first material in") or "empty"))
        label(x, y, z, t1, t2, pct >= 0.999 and AMBER or BLUE)
      end
    end
  end
  -- the quarries: the rectangle, its layer and rate
  for _, F in ipairs(w.frames or {}) do
    local e = F.quarry
    local q = F.q or (e and e.q)
    if q then
      local cs = { { q.hx, q.hz }, { -q.hx, q.hz }, { -q.hx, -q.hz }, { q.hx, -q.hz } }
      local col = (e and e.q and not e.refused) and GREEN or AMBER
      for k = 1, 4 do
        local c1, c2 = cs[k], cs[k % 4 + 1]
        local x1, y1, z1 = Q.toBody(q, c1[1], 0.25, c1[2])
        local x2, y2, z2 = Q.toBody(q, c2[1], 0.25, c2[2])
        L(b.x + x1, b.y + y1, b.z + z1, b.x + x2, b.y + y2, b.z + z2, col)
      end
      local x, y, z = Q.toBody(q, 0, 4.0, 0)
      if e then
        local o = readout(e.sid, e.uid) or {}
        local qo = o.quarry or {}
        local t1 = e.q and string.format("QUARRY · layer %d of %d · %.1f m down · %.1f m³/h%s", (qo.layer or 0) + 1, qo.layers or 0, qo.depth or 0, qo.m3h or 0, e.live and "" or " (estimated)")
                   or (e.survey and "QUARRY · SURVEYING" or "QUARRY · waiting for its survey")
        label(b.x + x, b.y + y, b.z + z, t1, "LIMITED BY " .. tostring(o.lim or "nothing"), o.lim and AMBER or GREEN)
      else
        label(b.x + x, b.y + y, b.z + z, "QUARRY FRAME", tostring(F.why or ""), AMBER)
      end
    elseif F.why then
      local P = F.posts[1]
      label(b.x + P.gx, b.y + P.gy + 3.4, b.z + P.gz, string.format("QUARRY POSTS · %d", #F.posts), F.why, AMBER)
    end
  end
  if w0 then PROF.overlay_ms = (wall() - w0) * 1000 end
  return drawn
end

-- ── the menus ───────────────────────────────────────────────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id) or {}
  local it = d.it
  if not it or it.kind == "visual" then return {} end
  local sid, uid = rec.id, part.uid
  local G = "Logistics"
  local out = {}
  if it.kind == "belt" or it.kind == "tube" or it.kind == "blower" then
    out[#out + 1] = { id = "lg_line", type = "info", label = "Line", group = G, value = function()
      local o = readout(sid, uid)
      if not (o and o.line) then return "not part of a line yet" end
      local L = o.line
      return string.format("%.2f of %.0f kg/s%s · %d pieces", L.q, L.cap, L.mat and (" · " .. mat_label(L.mat)) or "", L.n)
    end }
    out[#out + 1] = { id = "lg_run", type = "toggle", label = "Running", group = G, keep = true,
      on = function() return isRun(sid, uid) end, act = function(want) setRun(sid, uid, want) end }
    if it.kind ~= "blower" then
      out[#out + 1] = { id = "lg_rev", type = "action", label = "Reverse it", group = G, keep = true,
        hint = function() return "turns which end takes the load" end,
        act = function() setRev(sid, uid); return true end }
    end
  elseif it.kind == "hopper" or it.kind == "silo" or it.kind == "drive" then
    out[#out + 1] = { id = "lg_store", type = "info", label = (it.kind == "drive") and "Discharge bin" or "Holds", group = G, value = function()
      local o = readout(sid, uid)
      local s = o and o.store
      if not s then return "—" end
      local parts = {}
      for _, itx in ipairs(s.items) do parts[#parts + 1] = string.format("%d %s", itx.n, mat_label(itx.mat)) end
      return string.format("%s of %s%s", fmt_kg(s.kg), fmt_kg(s.cap), #parts > 0 and (" · " .. table.concat(parts, ", ")) or " · empty")
    end }
    out[#out + 1] = { id = "lg_take", type = "action", label = "Take what fits into your pack", group = G, keep = true,
      act = function()
        local inv = ref("inventory")
        local cid = cidOf(it, sid, uid)
        if not inv then return false, "no inventory" end
        local moved = 0
        for _, itx in ipairs(inv.items(cid) or {}) do moved = moved + inv.transfer(cid, "astro", itx.mat, itx.n) end
        if moved <= 0 then return false, "nothing in it, or no room in your pack" end
        return true
      end }
    if it.kind == "silo" then
      out[#out + 1] = { id = "lg_mat", type = "action", label = "Material", group = G, keep = true,
        hint = function() local st = part_state(sid, uid); return st and st.mat and mat_label(st.mat) or "the first in" end,
        act = function()
          local st = part_state(sid, uid) or {}
          local inv = ref("inventory")
          local cid = cidOf(it, sid, uid)
          if inv and (inv.mass(cid) or 0) > 0 then return false, "empty it first: a silo holds one material" end
          local list = { false, "regolith", "iron", "silica", "ice", "copper", "basalt", "sulfur" }
          local cur = st.mat or false
          local k = 1
          for j, m in ipairs(list) do if m == cur then k = j end end
          local nxt = list[k % #list + 1]
          setSiloMat(sid, uid, nxt or nil)
          return true
        end }
    end
    if it.kind == "drive" then
      out[#out + 1] = { id = "lg_q", type = "info", label = "Quarry", group = G, value = function()
        local o = readout(sid, uid)
        local q = o and o.quarry
        if not q then
          local ST2 = ref("structures")
          local r2 = ST2 and ST2.get(sid)
          local w = r2 and W[r2.b]
          for _, F in ipairs(w and w.frames or {}) do if F.why then return "no frame: " .. F.why end end
          return "no frame: four Quarry Posts on a rectangle within 14 m"
        end
        if q.refused then return q.refused end
        if q.surveying then return "surveying the ground" end
        if not q.q then return "waiting for its survey (the crew near it)" end
        if q.done then return string.format("dug to its floor (%.1f m)", q.depth or 0) end
        return string.format("layer %d of %d · %.1f m down · %.1f m³/h%s", (q.layer or 0) + 1, q.layers or 0, q.depth or 0, q.m3h or 0, q.live and " · live" or " · estimated")
      end }
      out[#out + 1] = { id = "lg_pause", type = "toggle", label = "Digging", group = G, keep = true,
        on = function() local st = part_state(sid, uid); return not (st and st.off) end,
        act = function(want) setPaused(sid, uid, not want) end }
      out[#out + 1] = { id = "lg_floor", type = "action", label = "Floor −0.5 m (shallower)", group = G, keep = true,
        hint = function() local st = part_state(sid, uid); return string.format("%.1f m", tonumber(st and st.floor) or Q.DEPTH_MAX) end,
        act = function() local st = part_state(sid, uid); setFloor(sid, uid, math.max(1.0, (tonumber(st and st.floor) or Q.DEPTH_MAX) - 0.5)); return true end }
      out[#out + 1] = { id = "lg_floor2", type = "action", label = "Floor +0.5 m (deeper)", group = G, keep = true,
        act = function() local st = part_state(sid, uid); setFloor(sid, uid, math.min(Q.DEPTH_MAX, (tonumber(st and st.floor) or Q.DEPTH_MAX) + 0.5)); return true end }
    end
  elseif it.kind == "chute" then
    out[#out + 1] = { id = "lg_chute", type = "info", label = "Fills", group = G, value = function()
      local o = readout(sid, uid)
      local c = o and o.chute
      if not (c and c.craft) then return "no craft under the spout (one on its stand, or parked within 6 m)" end
      return string.format("%s · %.0f kg of room in the hold", c.craft, c.room or 0)
    end }
  elseif it.kind == "post" then
    out[#out + 1] = { id = "lg_post", type = "info", label = "Quarry", group = G, value = function()
      local ST2 = ref("structures")
      local r2 = ST2 and ST2.get(sid)
      local w = r2 and W[r2.b]
      for _, F in ipairs(w and w.frames or {}) do
        for _, P in ipairs(F.posts) do
          if P.sid == sid and P.uid == uid then
            if F.quarry then return string.format("a %.0f × %.0f m frame · its drive's menu runs it", 2 * F.q.hx, 2 * F.q.hz) end
            return F.why or "—"
          end
        end
      end
      return "—"
    end }
  end
  out[#out + 1] = { id = "lg_lim", type = "info", label = "Limited by", group = G, value = function()
    local o = readout(sid, uid); return (o and o.lim) or "nothing: it runs as laid" end }
  return out, d.label
end
providerFn = provider
local reg_on = false

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("logistics")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  W, ver, pending_t = {}, -1, nil
  worlds = W
  tick_t, save_t = -10, -10
end

local function has_it(rec)
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.it and d.it.kind ~= "visual" then return true end
  end
  return false
end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "logistics", order = 9 }); reg_on = true end
  end
  -- (X6) the refinery's menus and an open RECIPE panel, from here: neither has an update of its own
  local RF = ref("refinery")
  if RF and RF.tick then RF.tick() end
  local FP = ref("fab_panel")
  if FP and FP.tick and FP.isOpen and FP.isOpen() then FP.tick(dt or 0) end
  local ST = ref("structures")
  if not (ST and libs()) then return end
  local t = now()
  if ST.version ~= ver then
    ver = ST.version
    pending_t = pending_t or t
  end
  if pending_t and t - pending_t >= SOLVE_WAIT then
    pending_t = nil
    local w0 = wall()
    local byBody = {}
    for _, rec in ipairs(ST.list()) do
      if has_it(rec) then byBody[rec.b] = byBody[rec.b] or {}; table.insert(byBody[rec.b], rec) end
    end
    local a = agency_now()
    local obs = observer()
    for body, w in pairs(W) do if not byBody[body] then step_world(w, a, obs); W[body] = nil; labels = {} end end
    for body, list in pairs(byBody) do
      local w = W[body]
      if w then step_world(w, a, obs) end
      build_world(body, list)
    end
    if w0 then PROF.build_ms = (wall() - w0) * 1000 end
  end
  if next(W) == nil then return end
  local obs = observer()
  local cur = obs and space.dominant(obs.x, obs.y, obs.z)
  local b = cur and space.body(cur)
  -- surveys (a layer a frame) and live digging, on the crew's world
  local w = cur and W[cur]
  if w and b then
    for _, e in pairs(w.quarries) do
      if not e.q and e.fresh and not e.refused and obs then
        local x, y, z = Q.toBody(e.fresh, 0, 0, 0)
        local d = math.sqrt((obs.x - b.x - x) ^ 2 + (obs.y - b.y - y) ^ 2 + (obs.z - b.z - z) ^ 2)
        local BF = ref("base_facilities")
        local why = BF and BF.digRefused and BF.digRefused(b.x + x, b.y + y, b.z + z, math.min(e.fresh.hx, e.fresh.hz))
        e.guard = why and ("too near the base's foundations: " .. tostring(why)) or nil
        if d <= LIVE_R and not e.guard and (not terrain.ready or terrain.ready(b.x + x, b.y + y, b.z + z, 4.0)) then
          local w0 = wall()
          survey_step(w, e, b)
          if w0 then PROF.survey_ms = (wall() - w0) * 1000 end
        end
      end
    end
    dig_tick(w, b, dt or 0)
  end
  -- the clock
  local busy = false
  for _, ww in pairs(W) do
    if ww.rep and (#(ww.rep.flows or {}) > 0 or (ww.rep.R and #(ww.rep.R.convs or {}) > 0)) then busy = true end
    local RF = ref("refinery")
    if RF and RF.busy and RF.busy(ww) then busy = true end
    for _, e in pairs(ww.quarries) do if e.q and not e.refused then busy = true end end
  end
  if t - tick_t >= (busy and EVERY or IDLE_EVERY) then
    tick_t = t
    local w0 = wall()
    local a = agency_now()
    PROF.nets = 0
    for _, ww in pairs(W) do step_world(ww, a, obs); PROF.nets = PROF.nets + 1 end
    if w0 then PROF.step_ms = (wall() - w0) * 1000 end
    if w then belt_visuals(w) end
  end
  if t - save_t >= SAVE_EVERY then save_t = t; saveNow() end
end

-- Drawn over the world: after the camera has placed this frame's view
-- (planet_camera.deferLate; docs/positions-and-frames.md rule 2)
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
local function late_overlay() if overlay_on() then drawOverlay() end end
function lateUpdate(node, dt)
  local w0 = wall()
  if next(W) ~= nil then
    local obs = observer()
    local cur = obs and space.dominant(obs.x, obs.y, obs.z)
    local w = cur and W[cur]
    local b = cur and space.body(cur)
    if w and b then gantry(w, b, obs, dt) end
  end
  after_camera(node, dt, late_overlay)
  if w0 then PROF.late_ms = (wall() - w0) * 1000 end
end
