-- BASE POWER — power networks II: cables with real losses and limits,
-- breakers, transformers, the POWER overlay (sandbox plan S5,
-- work/sandbox/PLAN.md §3.2, §3.6; docs/base-building.md §16).
--
-- On the Build Kit node (scenes/system.ron) beside base_grid.lua. The rules
-- half is pure (its globals are its API; it loads from disk in a luajit test,
-- tests/smoke_netpower.lua): base_grid builds each grid's NETWORK with it when
-- the grid is rebuilt and asks it for the year's losses and trips. The scene
-- half is the POWER overlay (F2 with the kit open), the breakers' menu and
-- the breaker switch (the seam S8's logic will pull).
--
-- ── UNITS ───────────────────────────────────────────────────────────────────
-- The grid counts in EC/s; a base reads 1 EC/s as 1 kW (a strip light's
-- 0.03 EC/s is 30 W, a tower's 2 EC/s is 2 kW, a Solar Array's 3 EC/s is a
-- 3 kW array). Everything here is in kW, ohms, volts and metres.
--
-- ── THE NETWORK OF A GRID ───────────────────────────────────────────────────
--   buses   a structure is one bus (its parts share its busbar); structures
--           within 150 m of a tower share the tower's bus (the base's own
--           low-voltage ring: lossless, as before)
--   edges   the grid's live cables between two buses: R = ρ·L / A (annealed
--           copper, ρ = 1.72e-8 Ω·m), at their voltage (400 V, or 11 kV for
--           the HV cable, which runs only between two transformers), with a
--           capacity V·I_rated
--   loads   at their structure's bus; sources likewise; the batteries are the
--           SLACK: they take a surplus and cover a shortfall, shared by size
--           (with none, sources are curtailed or loads shed in proportion)
--   flow    a DC load flow in per-unit: each edge's admittance Y = V² / R
--           (a transformer adds its 4 % impedance in series), the Laplacian
--           solved once per network (LU) and back-substituted for each slot of
--           the year. On a tree that is exactly "push the loads up to the
--           sources"; on a cycle the flow splits by conductance.
--   losses  per cable P²·R / V²; per transformer P0 + Pk·(S / S_rated)²; their
--           sum is one more LOAD on the grid's closed-form battery step
--           (base_grid.advance), slot by slot, so one big step still equals
--           many small ones
--
-- ── PROTECTION ──────────────────────────────────────────────────────────────
--   breaker   a kit piece (Breaker Panel 63 A / 160 A). A cable plugged into
--             one is GUARDED by it: the breaker opens the moment the flow on
--             that cable passes its rating (a TRIP: it stays open until a hand
--             resets it, or S8's logic does). A breaker with no cable is its
--             structure's MAIN: open, the structure's own loads are off; it
--             trips when they draw more than its rating. Open or tripped, a
--             guarded cable carries nothing and the grid may split in two.
--   burn      a cable with no breaker at either end that is driven past 125 %
--             of its rating burns through (the copper melts its insulation):
--             it carries nothing until it is spliced (right-click its end).
--   Both happen at the START of the first slot whose flow passes the limit,
--   so a long step and a series of short ones trip at the same moment.
--
-- ── WHAT IT PUBLISHES (per grid, in base_grid's model) ──────────────────────
--   M.lossP[k]   kW lost in slot k;  M.trip[k] = { events } the first slot
--   that trips or burns something;  flowsAt(M, k) the flows of slot k for the
--   overlay and the menus;  limitedBy(M, F) the one line that says what holds
--   the grid back ("cable 3 at 140 % — upgrade the gauge").

-- ── the constants ───────────────────────────────────────────────────────────
RHO = 1.72e-8           -- Ω·m, annealed copper at 20 °C
VOLTS = { lv = 400, hv = 11000 }
BURN = 1.25             -- an unguarded cable burns through past this share of its rating
LOSS_ITERS = 16         -- the slack covers the losses: re-solved until they settle (to 1e-9 kW)

-- The cables (parts_base's drums name one each). mm2 = the copper of each
-- conductor; amps = the rating buried / on the ground (IEC 60364 ballpark
-- for 4-core SWA at 400 V, 3-core XLPE at 11 kV); kgm and perm real-ish.
CABLES = {
  lv16 = { label = "Power Cable 16 mm²", short = "16 mm²", mm2 = 16, v = "lv", amps = 80, kgm = 1.4, perm = 3.0, r = 0.016, max = 1500 },
  lv35 = { label = "Power Cable 35 mm²", short = "35 mm²", mm2 = 35, v = "lv", amps = 125, kgm = 2.6, perm = 6.0, r = 0.020, max = 1500 },
  lv95 = { label = "Power Cable 95 mm²", short = "95 mm²", mm2 = 95, v = "lv", amps = 230, kgm = 5.8, perm = 14.0, r = 0.027, max = 1500 },
  hv35 = { label = "HV Cable 11 kV", short = "11 kV", mm2 = 35, v = "hv", amps = 140, kgm = 2.3, perm = 9.0, r = 0.022, max = 6000 },
}
CABLE_ORDER = { "lv16", "lv35", "lv95", "hv35" }

function cableType(key) return CABLES[key or "lv16"] or CABLES.lv16 end
function volts(key) return VOLTS[cableType(key).v] end
-- Ω of one conductor of `len` m
function resistance(key, len)
  local c = cableType(key)
  return RHO * math.max(1.0, len or 0) / (c.mm2 * 1e-6)
end
-- kW the cable may carry
function capacityKW(key) local c = cableType(key); return VOLTS[c.v] * c.amps / 1000 end
-- kW lost carrying P kW over R Ω at V volts (P²R/V²)
function lossKW(P, R, V)
  local I = math.abs(P) * 1000 / V
  return I * I * R / 1000
end
-- the share lost: P²R/V² ÷ P
function lossShare(P, key, len)
  if math.abs(P) < 1e-12 then return 0 end
  return lossKW(P, resistance(key, len), volts(key)) / math.abs(P)
end
-- a breaker's rating (kW at 400 V)
function breakerKW(pw) return (pw and pw.amps or 63) * VOLTS.lv / 1000 end
-- a transformer's own loss carrying S kW
function xfmrLossKW(pw, S)
  local k = math.abs(S or 0) / math.max(1e-9, pw.kva or 100)
  return (pw.p0 or 0) + (pw.pk or 0) * k * k
end
-- the gauge after this one (an upgrade's name), or nil
function nextGauge(key)
  local c = cableType(key)
  local best = nil
  for _, k in ipairs(CABLE_ORDER) do
    local d = CABLES[k]
    if d.v == c.v and d.amps > c.amps and (not best or d.amps < CABLES[best].amps) then best = k end
  end
  return best
end

-- ── linear algebra: a dense LU with partial pivoting ────────────────────────
-- (a network is a few dozen buses; factored once, solved once per slot)
function luFactor(A, n)
  local P = {}
  for i = 1, n do P[i] = i end
  for k = 1, n do
    local p, best = k, math.abs(A[k][k])
    for i = k + 1, n do local v = math.abs(A[i][k]); if v > best then p, best = i, v end end
    if best < 1e-300 then return nil, "singular" end
    if p ~= k then A[k], A[p] = A[p], A[k]; P[k], P[p] = P[p], P[k] end
    local Ak, akk = A[k], A[k][k]
    for i = k + 1, n do
      local Ai = A[i]
      local f = Ai[k] / akk
      if f ~= 0 then
        Ai[k] = f
        for j = k + 1, n do Ai[j] = Ai[j] - f * Ak[j] end
      else
        Ai[k] = 0
      end
    end
  end
  return { A = A, P = P, n = n }
end
function luSolve(F, b)
  local A, P, n = F.A, F.P, F.n
  local y = {}
  for i = 1, n do
    local s = b[P[i]]
    local Ai = A[i]
    for j = 1, i - 1 do s = s - Ai[j] * y[j] end
    y[i] = s
  end
  for i = n, 1, -1 do
    local s = y[i]
    local Ai = A[i]
    for j = i + 1, n do s = s - Ai[j] * y[j] end
    y[i] = s / Ai[i]
  end
  return y
end

-- ── the network of one grid ─────────────────────────────────────────────────
-- spec = {
--   buses   = { key … }                          (ordered: the index is the bus)
--   gen     = { [bus] = kW always }               (rtg and the like)
--   arrays  = { { bus, prof = { [k] kW } } … }     (solar, by slot)
--   loads   = { { bus, kW, sid?, main? } … }       (served unless shed)
--   stores  = { { bus, cap } … }                   (the slack, by size)
--   edges   = { { id, a, z (bus), ty, len, guard = { { key, kW } … }, xf = { { key, pw } … } } … }
--   mains   = { { key, kW, sid, load } … }         (a structure's main breaker and its load)
--   xfmrs   = { { key, pw } … }                    (every transformer on the grid: its P0)
-- }
-- → net = spec plus { nb, Y (per edge, kW per unit), F (LU of the reduced
-- Laplacian), ref (the slack's reference bus), R, V, cap (per edge) }
function network(spec)
  local net = spec
  net.nb = #spec.buses
  net.R, net.V, net.cap, net.Y = {}, {}, {}, {}
  for i, e in ipairs(spec.edges) do
    local R, V = resistance(e.ty, e.len), volts(e.ty)
    net.R[i], net.V[i], net.cap[i] = R, V, capacityKW(e.ty)
    -- (W per unit of voltage drop, in kW): a cable's V²/R, a transformer's
    -- S/z in series at each end it is plugged into
    local inv = R / (V * V)
    for _, x in ipairs(e.xf or {}) do inv = inv + (x.pw.z or 0.04) / ((x.pw.kva or 100) * 1000) end
    net.Y[i] = (1 / inv) / 1000
  end
  -- the reference bus: the biggest store's (the slack sits there), else bus 1
  local ref, best = 1, -1
  for _, s in ipairs(spec.stores or {}) do if s.cap > best then ref, best = s.bus, s.cap end end
  net.ref = ref
  -- the reduced Laplacian (every bus but the reference)
  local n = net.nb
  local idx, k = {}, 0
  for b = 1, n do if b ~= ref then k = k + 1; idx[b] = k end end
  net.idx = idx
  if n > 1 then
    local A = {}
    for i = 1, n - 1 do local row = {} for j = 1, n - 1 do row[j] = 0 end A[i] = row end
    for i, e in ipairs(spec.edges) do
      if e.a ~= e.z then
        local y, ia, iz = net.Y[i], idx[e.a], idx[e.z]
        if ia then A[ia][ia] = A[ia][ia] + y end
        if iz then A[iz][iz] = A[iz][iz] + y end
        if ia and iz then A[ia][iz] = A[ia][iz] - y; A[iz][ia] = A[iz][ia] - y end
      end
    end
    net.F = luFactor(A, n - 1)
  end
  return net
end

-- The bus injections of slot k (kW, + = into the network), balanced by the
-- slack with `extra` kW of losses to cover. → inj, gen, load (totals), shed
local function injections(net, k, extra)
  local n = net.nb
  local g, l = {}, {}
  for b = 1, n do g[b], l[b] = net.gen and net.gen[b] or 0, 0 end
  for _, a in ipairs(net.arrays or {}) do
    local p = a.prof and a.prof[k] or a.kW or 0
    g[a.bus] = g[a.bus] + p
  end
  for _, d in ipairs(net.loads or {}) do l[d.bus] = l[d.bus] + d.kW end
  local G, L = 0, 0
  for b = 1, n do G, L = G + g[b], L + l[b] end
  -- the losses are drawn where the loads are (shared by load), or at the
  -- reference bus when nothing draws
  if (extra or 0) > 0 then
    if L > 1e-12 then
      for b = 1, n do l[b] = l[b] + extra * l[b] / L end
    else
      l[net.ref] = l[net.ref] + extra
    end
    L = L + extra
  end
  local inj = {}
  local C = 0
  for _, s in ipairs(net.stores or {}) do C = C + s.cap end
  local shed = 0
  if C > 0 then
    -- the batteries take the difference, shared by size
    for b = 1, n do inj[b] = g[b] - l[b] end
    local d = G - L
    for _, s in ipairs(net.stores) do inj[s.bus] = inj[s.bus] - d * s.cap / C end
  elseif G >= L then
    -- no store: the sources turned down to what is drawn
    local f = (G > 1e-12) and L / G or 0
    for b = 1, n do inj[b] = g[b] * f - l[b] end
  else
    -- no store, too little: every load gets the same share (shedding, averaged)
    local f = (L > 1e-12) and G / L or 0
    shed = L - G
    for b = 1, n do inj[b] = g[b] - l[b] * f end
  end
  return inj, G, L, shed
end

-- The flows of slot k: → F = { P = { [edge] kW, + from a to z }, loss (kW,
-- cables + transformers), cl = { [edge] kW lost }, xl = { [xkey] kW through },
-- gen, load, shed }
function flowsAt(net, k, guess)
  local E = net.edges
  local P = {}
  local loss, cl, xl = guess or 0, {}, {}
  local G, L, shed = 0, 0, 0
  for it = 1, LOSS_ITERS do
    local inj
    inj, G, L, shed = injections(net, k, loss)
    for i in ipairs(E) do P[i] = 0 end
    if net.F then
      local rhs = {}
      for b = 1, net.nb do local j = net.idx[b]; if j then rhs[j] = inj[b] end end
      local phi = luSolve(net.F, rhs)
      local function th(b) local j = net.idx[b]; return j and phi[j] or 0 end
      for i, e in ipairs(E) do
        if e.a ~= e.z then P[i] = net.Y[i] * (th(e.a) - th(e.z)) end
      end
    end
    local nl = 0
    xl = {}
    for i, e in ipairs(E) do
      cl[i] = lossKW(P[i], net.R[i], net.V[i])
      nl = nl + cl[i]
      for _, x in ipairs(e.xf or {}) do xl[x.key] = (xl[x.key] or 0) + math.abs(P[i]) end
    end
    for _, x in ipairs(net.xfmrs or {}) do nl = nl + xfmrLossKW(x.pw, xl[x.key] or 0) end
    if math.abs(nl - loss) < 1e-9 then loss = nl break end
    loss = nl
  end
  return { P = P, loss = loss, cl = cl, xl = xl, gen = G, load = L - loss, shed = shed }
end

-- What trips or burns in a slot's flows: → { { kind = "trip"|"burn"|"main",
-- key | id, kW, rating } … } | nil
function eventsIn(net, F)
  local ev = nil
  local function add(e) ev = ev or {}; ev[#ev + 1] = e end
  local seen = {}
  for i, e in ipairs(net.edges) do
    local P = math.abs(F.P[i])
    if #(e.guard or {}) > 0 then
      for _, gd in ipairs(e.guard) do
        if P > gd.kW * (1 + 1e-9) and not seen[gd.key] then
          seen[gd.key] = true
          add({ kind = "trip", key = gd.key, kW = P, rating = gd.kW, edge = e.id })
        end
      end
    elseif P > net.cap[i] * BURN * (1 + 1e-9) then
      add({ kind = "burn", id = e.id, kW = P, rating = net.cap[i] })
    end
  end
  for _, m in ipairs(net.mains or {}) do
    if (m.load or 0) > m.kW * (1 + 1e-9) and not seen[m.key] then
      seen[m.key] = true
      add({ kind = "trip", key = m.key, kW = m.load, rating = m.kW, main = true })
    end
  end
  return ev
end

-- The year: losses and the first trip, slot by slot. N slots (k = 1..N; a
-- network with nothing that varies is one slot). → lossP, trip, peak
-- peak = { [edge] = max |P| }, xpeak = { [xkey] = max S }
function yearOf(net, N)
  local varies = false
  for _, a in ipairs(net.arrays or {}) do if a.prof then varies = true end end
  local lossP, trip, peak, xpeak = {}, {}, {}, {}
  local first = nil
  local nslots = varies and N or 1
  -- (slots whose arrays give the same are solved once: the nights; the last
  -- slot's losses start the next one's iteration)
  local memo, guess = {}, 0
  for k = 1, nslots do
    local key = nil
    if varies then
      local t = {}
      for i, a in ipairs(net.arrays) do t[i] = string.format("%.9g", a.prof and a.prof[k] or a.kW or 0) end
      key = table.concat(t, ",")
    end
    local F = key and memo[key]
    if not F then
      F = flowsAt(net, k, guess)
      if key then memo[key] = F end
    end
    guess = F.loss
    lossP[k] = F.loss
    for i in ipairs(net.edges) do peak[i] = math.max(peak[i] or 0, math.abs(F.P[i])) end
    for key, s in pairs(F.xl) do xpeak[key] = math.max(xpeak[key] or 0, s) end
    local ev = eventsIn(net, F)
    if ev then trip[k] = ev; first = first or k end
  end
  if not varies then
    for k = 2, N do lossP[k] = lossP[1]; trip[k] = trip[1] end
  end
  return lossP, (first ~= nil) and trip or nil, peak, xpeak
end

-- The one line that says what holds the grid back, from a slot's flows:
-- → text, element { kind, id|key, share } | nil
function limitedBy(net, F)
  local best, bi = nil, 0
  local function consider(share, el) if share > bi then best, bi = el, share end end
  for i, e in ipairs(net.edges) do
    local P = math.abs(F.P[i])
    consider(P / net.cap[i], { kind = "cable", id = e.id, share = P / net.cap[i], ty = e.ty, edge = i })
    for _, gd in ipairs(e.guard or {}) do consider(P / gd.kW, { kind = "breaker", key = gd.key, share = P / gd.kW, edge = i }) end
  end
  for _, x in ipairs(net.xfmrs or {}) do
    local S = F.xl[x.key] or 0
    consider(S / (x.pw.kva or 100), { kind = "xfmr", key = x.key, share = S / (x.pw.kva or 100) })
  end
  for _, m in ipairs(net.mains or {}) do consider((m.load or 0) / m.kW, { kind = "main", key = m.key, share = (m.load or 0) / m.kW }) end
  -- the worst loss share on a line, when nothing is near its limit
  local lossEl, lossSh = nil, 0
  for i, e in ipairs(net.edges) do
    local P = math.abs(F.P[i])
    if P > 0.05 then
      local sh = F.cl[i] / P
      if sh > lossSh then lossEl, lossSh = { kind = "loss", id = e.id, share = sh, ty = e.ty, edge = i }, sh end
    end
  end
  if best and bi >= 0.8 then
    local pc = math.floor(bi * 100 + 0.5)
    if best.kind == "cable" then
      local up = nextGauge(best.ty)
      return string.format("cable %s at %d %% — %s", tostring(best.id), pc,
        up and ("upgrade the gauge to " .. CABLES[up].short) or "run a second line"), best
    elseif best.kind == "breaker" then
      return string.format("breaker at %d %% of its rating — %s", pc, bi > 1 and "it trips" or "near its trip"), best
    elseif best.kind == "xfmr" then
      return string.format("transformer at %d %% — a second line, or shed load", pc), best
    else
      return string.format("main breaker at %d %% — split the loads, or a bigger panel", pc), best
    end
  end
  if lossEl and lossSh >= 0.05 then
    return string.format("cable %s loses %d %% — %s", tostring(lossEl.id), math.floor(lossSh * 100 + 0.5),
      cableType(lossEl.ty).v == "lv" and "a transformer at each end (11 kV)" or "a heavier cable"), lossEl
  end
  return nil, best
end

-- ── the scene half: the breaker switch, the overlay, the menus ──────────────
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
local function partsDef(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end

-- A breaker's state: "closed" | "open" (switched off) | "tripped".
function breakerState(sid, uid)
  local ST = ref("structures")
  local st = ST and ST.partState(sid, uid)
  if st and st.trip then return "tripped" end
  if st and st.open then return "open" end
  return "closed"
end
-- (THE LOGIC SEAM, S8) Close or open a breaker: `closed` true closes it
-- (and resets a trip), false opens it. `by` = "hand" | "logic" | "trip".
-- Hooks in `onBreaker` hear every change: fn(sid, uid, state, by).
onBreaker = {}
function setBreaker(sid, uid, closed, by)
  local ST = ref("structures")
  if not ST then return false end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  if by == "trip" then
    t.trip, t.open = agency_now(), nil
  elseif closed then
    t.trip, t.open = nil, nil
  else
    t.open, t.trip = true, nil
  end
  ST.setPartState(sid, uid, next(t) and t or nil)
  local state = breakerState(sid, uid)
  for _, fn in ipairs(onBreaker) do pcall(fn, sid, uid, state, by or "hand") end
  if by ~= "logic" and audio and audio.play then
    pcall(audio.play, by == "trip" and "audio/foley/switch_3.ogg" or "audio/foley/switch_2.ogg", { track = "UI", volume = by == "trip" and 0.7 or 0.45 })
  end
  return true
end
lastTrips = {}         -- probes: { { kind, key|id, kW, rating, t } … } (newest last)

-- ── the POWER overlay (lateUpdate: drawn poses, this frame's body read) ─────
overlay = false        -- F2 with the kit open
overlayAlways = false  -- (probes: drawn with the kit shut)
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
COL = { ok = { 0.35, 1.0, 0.55 }, warm = { 1.0, 0.78, 0.25 }, hot = { 1.0, 0.30, 0.22 }, dead = { 0.45, 0.45, 0.48 } }
local function load_col(share, dead)
  if dead then return COL.dead end
  if share < 0.5 then return COL.ok end
  if share <= 1.0 then return COL.warm end
  return COL.hot
end
function colourOf(share, dead) return load_col(share, dead) end
local function kw(v)
  v = math.abs(v or 0)
  if v >= 100 then return string.format("%.0f kW", v) end
  if v >= 1 then return string.format("%.1f kW", v) end
  return string.format("%.0f W", v * 1000)
end
fmtKW = kw

drawn = { lines = 0, labels = 0, arrows = 0 }  -- probes: what the last overlay frame drew
OVERLAY_R = 700.0
LABEL_R = 160.0
function drawOverlay()
  drawn = { lines = 0, labels = 0, arrows = 0 }
  if not (draw and draw.line) then return drawn end
  local BG, CB, ST = ref("base_grid"), ref("base_cable"), ref("structures")
  if not (BG and CB and ST and BG.cableFlow) then return drawn end
  -- (what is near the CAMERA this frame: its drawn pose, the crew's if none)
  local a = find and (find("Camera 1") or find("Astronaut"))
  local ax, ay, az = 0, 0, 0
  if valid(a) then local w = a.worldPos or a; ax, ay, az = w.x, w.y, w.z end
  local bodies = {}
  local function body(name)
    local b = bodies[name]
    if b == nil then b = (space and space.body and space.body(name)) or false; bodies[name] = b end
    return b or nil
  end
  local placed = {}
  local function text(x, y, z, s, col, dy, size, always)
    if not (camera and camera.worldToScreen and draw.text) then return end
    -- (labels only within LABEL_R of the camera, unless a card; lines go further)
    if not always and (x - ax) ^ 2 + (y - ay) ^ 2 + (z - az) ^ 2 > LABEL_R * LABEL_R then return end
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    if on then
      local w = #s * (size or 15) * 0.52 + 12
      sy = sy + (dy or 0)
      dy = 0
      -- (a later label steps down past one already drawn there)
      for _ = 1, 8 do
        local hit = false
        for _, p in ipairs(placed) do
          if math.abs(p[1] - sx) < (p[3] + w) / 2 and math.abs(p[2] - sy) < (size or 15) + 8 then hit = true end
        end
        if not hit then break end
        sy = sy + (size or 15) + 9
      end
      placed[#placed + 1] = { sx, sy, w }
      if draw.rect then draw.rect(sx - w / 2, sy + (dy or 0) - 3, w, (size or 15) + 7, 0.02, 0.03, 0.04, 0.62, 3) end
      draw.text(sx, sy + (dy or 0), s, size or 15, col[1], col[2], col[3], 1, "center")
      drawn.labels = drawn.labels + 1
    end
  end
  for _, c in ipairs(CB.list()) do
    local b = body(c.b)
    local pts = b and CB.pathOf and CB.pathOf(c.id)
    if pts and #pts >= 2 then
      local m = pts[math.floor(#pts / 2) + 1]
      local mx, my, mz = b.x + m.x, b.y + m.y, b.z + m.z
      if (mx - ax) ^ 2 + (my - ay) ^ 2 + (mz - az) ^ 2 < OVERLAY_R * OVERLAY_R then
        local f = BG.cableFlow(c.id) or {}
        local dead = f.dead or false
        local share = f.share or 0
        local col = load_col(share, dead)
        -- the run itself, a few cm over the cable (at most ~80 segments)
        local step = math.max(1, math.floor(#pts / 80))
        local px, py, pz = nil, nil, nil
        for i = 1, #pts, step do
          local p = pts[i]
          local x, y, z = b.x + p.x, b.y + p.y, b.z + p.z
          if px then draw.line(px, py, pz, x, y, z, col[1], col[2], col[3], 0.95); drawn.lines = drawn.lines + 1 end
          px, py, pz = x, y, z
        end
        local l = pts[#pts]
        draw.line(px, py, pz, b.x + l.x, b.y + l.y, b.z + l.z, col[1], col[2], col[3], 0.95)
        -- arrows: chevrons along it, pointing the way the power flows
        if not dead and math.abs(f.P or 0) > 1e-4 then
          local n = math.max(1, math.min(6, math.floor(#pts / 12)))
          for j = 1, n do
            local i = math.max(2, math.min(#pts - 1, math.floor(#pts * j / (n + 1))))
            local p0, p1 = pts[i - 1], pts[i + 1]
            local dx, dy, dz = p1.x - p0.x, p1.y - p0.y, p1.z - p0.z
            if (f.P or 0) < 0 then dx, dy, dz = -dx, -dy, -dz end
            local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dl > 1e-6 then
              dx, dy, dz = dx / dl, dy / dl, dz / dl
              local p = pts[i]
              local ux, uy, uz = p.x, p.y, p.z
              local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
              ux, uy, uz = ux / ul, uy / ul, uz / ul
              -- a side vector (up × along) for the chevron's arms
              local sx, sy, sz = uy * dz - uz * dy, uz * dx - ux * dz, ux * dy - uy * dx
              local cx, cy, cz = b.x + p.x + ux * 0.25, b.y + p.y + uy * 0.25, b.z + p.z + uz * 0.25
              local s = 0.45
              draw.line(cx, cy, cz, cx - dx * s + sx * s * 0.6, cy - dy * s + sy * s * 0.6, cz - dz * s + sz * s * 0.6, col[1], col[2], col[3], 1)
              draw.line(cx, cy, cz, cx - dx * s - sx * s * 0.6, cy - dy * s - sy * s * 0.6, cz - dz * s - sz * s * 0.6, col[1], col[2], col[3], 1)
              drawn.arrows = drawn.arrows + 1
            end
          end
        end
        local lab
        if f.burnt then lab = string.format("CABLE %s BURNT THROUGH · splice it", tostring(c.id))
        elseif dead then lab = string.format("CABLE %s · %s · OFF (%s)", tostring(c.id), cableType(c.ty).short, f.why or "breaker open")
        else
          lab = string.format("CABLE %s · %s · %s · %d %% · loss %s", tostring(c.id), cableType(c.ty).short, kw(f.P), math.floor(share * 100 + 0.5), kw(f.loss))
        end
        text(mx, my, mz, lab, col, -26, 15)
      end
    end
  end
  -- breakers, transformers and each structure's bus figure
  for _, g in ipairs(BG.grids() or {}) do
    local M = BG.model(g.id)
    local net = M and M.net
    for _, sid in ipairs(g.sids) do
      local rec = ST.get(sid)
      local b = rec and body(rec.b)
      if b and (rec.x - (ax - b.x)) ^ 2 + (rec.y - (ay - b.y)) ^ 2 + (rec.z - (az - b.z)) ^ 2 < OVERLAY_R * OVERLAY_R then
        for _, p in ipairs(rec.bp) do
          local d = partsDef(p.id)
          local pw = d and d.power
          if pw and (pw.kind == "breaker" or pw.kind == "xfmr") then
            local x, y, z = ST.partPose(rec, p, (d.h or 1) + 0.3)
            local info = BG.partFlow and BG.partFlow(sid, p.uid) or {}
            local col = load_col(info.share or 0, info.state == "open" or info.state == "tripped")
            if pw.kind == "breaker" then
              if info.state == "tripped" then col = COL.hot end
              text(b.x + x, b.y + y, b.z + z, string.format("BREAKER %d A · %s%s", pw.amps or 63,
                info.state == "tripped" and "TRIPPED" or (info.state == "open" and "OPEN" or string.format("%s · %d %%", kw(info.kW), math.floor((info.share or 0) * 100 + 0.5))),
                info.main and " · main" or ""), col, 0, 14)
            else
              text(b.x + x, b.y + y, b.z + z, string.format("TRANSFORMER %d kVA · %s · %d %% · loss %s", pw.kva or 100, kw(info.kW),
                math.floor((info.share or 0) * 100 + 0.5), kw(info.loss)), col, 0, 14)
            end
          end
        end
      end
    end
    -- the network's card over its first base (or structure): IN, OUT, LOSS
    local s = BG.status(g.id)
    if s and M then
      local rec = ST.get(g.sids[1])
      local b = rec and body(rec.b)
      if b and (rec.x - (ax - b.x)) ^ 2 + (rec.y - (ay - b.y)) ^ 2 + (rec.z - (az - b.z)) ^ 2 < OVERLAY_R * OVERLAY_R then
        local U = { rec.ux or 0, rec.uy or 1, rec.uz or 0 }
        local x, y, z = b.x + rec.x + U[1] * 6, b.y + rec.y + U[2] * 6, b.z + rec.z + U[3] * 6
        local col = (s.limited and s.limitShare and s.limitShare > 1) and COL.hot or COL.ok
        text(x, y, z, string.format("GRID %s · IN %s · OUT %s · LOSS %s%s", tostring(g.id), kw(s.supply), kw(s.need), kw(s.loss or 0),
          (M.C or 0) > 0 and string.format(" · BATTERY %d %%", math.floor(100 * (s.stored or 0) / M.C + 0.5)) or ""), col, -40, 16, true)
        if s.limited then text(x, y, z, "LIMITED BY " .. s.limited, (s.limitShare or 0) > 1 and COL.hot or COL.warm, -18, 15, true) end
      end
    end
  end
  return drawn
end

-- ── the menu on a breaker or a transformer ──────────────────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, BG = ref("structures"), ref("base_grid")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local def = partsDef(part.id) or {}
  local pw = def.power
  if not (pw and (pw.kind == "breaker" or pw.kind == "xfmr")) then return {} end
  local sid, uid = rec.id, part.uid
  local out = {}
  if pw.kind == "breaker" then
    out[#out + 1] = { id = "bp_state", type = "info", label = "Breaker", group = "Power",
      value = function()
        local st = breakerState(sid, uid)
        local f = BG and BG.partFlow and BG.partFlow(sid, uid) or {}
        local what = f.main and "its structure's main" or string.format("guards %d cable%s", f.cables or 0, (f.cables or 0) == 1 and "" or "s")
        if st == "tripped" then return string.format("TRIPPED · %s · rated %s", what, kw(breakerKW(pw))) end
        if st == "open" then return string.format("open · %s", what) end
        return string.format("%s of %s · %s", kw(f.kW), kw(breakerKW(pw)), what)
      end }
    out[#out + 1] = { id = "bp_on", type = "toggle", label = "Breaker closed", group = "Power", keep = true,
      on = function() return breakerState(sid, uid) == "closed" end,
      act = function(want)
        local wn = BG and BG.warnOf and BG.warnOf(sid, uid, want) or nil
        setBreaker(sid, uid, want, "hand")
        return true, wn
      end,
      enabled = function() return not (BG and BG.whyNot) or BG.whyNot(sid, uid, breakerState(sid, uid) ~= "closed") == nil end,
      why = function() return BG and BG.whyNot and BG.whyNot(sid, uid, breakerState(sid, uid) ~= "closed") end,
      hint = (breakerState(sid, uid) == "tripped") and "reset" or nil }
    if breakerState(sid, uid) == "tripped" then
      out[#out + 1] = { id = "bp_reset", type = "action", label = "Reset the breaker", group = "Power", hint = "E",
        act = function() setBreaker(sid, uid, true, "hand"); return true end }
    end
  else
    out[#out + 1] = { id = "bp_xf", type = "info", label = "Transformer", group = "Power",
      value = function()
        local f = BG and BG.partFlow and BG.partFlow(sid, uid) or {}
        return string.format("%s of %d kVA · loss %s · %d HV line%s", kw(f.kW), pw.kva or 100, kw(f.loss), f.cables or 0, (f.cables or 0) == 1 and "" or "s")
      end }
  end
  return out, def.label
end
providerFn = provider
local reg_on = false

-- A breaker's lamp: green closed, amber near its rating, red tripped, dark
-- open (its "Lens" child, tinted only when that changes; once a second).
local LAMP = { ok = nil, warm = { 1.0, 0.62, 0.15 }, trip = { 1.0, 0.18, 0.12 }, off = { 0.12, 0.12, 0.13 } }
local lamp_t, lamp_was = -10, {}
local function lamps()
  local BG, ST = ref("base_grid"), ref("structures")
  if not (BG and ST and BG.grids and BG.model) then return end
  for _, g in ipairs(BG.grids() or {}) do
    local M = BG.model(g.id)
    for _, b in ipairs(M and M.breakers or {}) do
      local f = BG.partFlow and BG.partFlow(b.sid, b.uid) or {}
      local want = (f.state == "tripped") and "trip" or (f.state == "open" and "off" or (((f.share or 0) >= 0.8) and "warm" or "ok"))
      if lamp_was[b.key] ~= want then
        local n = ST.nodeOf(b.sid, b.uid)
        local ok, lens = false, nil
        if n then ok, lens = pcall(n.getChild, n, "Lens") end
        if ok and lens then
          lamp_was[b.key] = want
          if LAMP[want] then pcall(lens.setTint, lens, { color = LAMP[want] }) else pcall(lens.setTint, lens) end
        end
      end
    end
  end
end

function start(node)
  if findScripts then
    local all = findScripts("base_power")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  lastTrips, onBreaker, lamp_was = {}, {}, {}
end
function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "base_power", order = 6 }); reg_on = true end
  end
  local t = now()
  if t - lamp_t >= 1.0 then lamp_t = t; lamps() end
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
  after_camera(node, dt, late_overlay)
end
