-- ITEM NET — conveyors and tubes as an inventory network (expansion X5;
-- work/expansion/PLAN.md §3.2–3.3; docs/base-building.md §23).
--
-- PURE. No engine calls: it loads from disk in a luajit test
-- (tests/smoke_item_net.lua). The scene half is scripts/logistics.lua.
--
-- MATERIAL FLOW IS NOT BODIES. A belt or a tube carries kilograms between
-- containers; nothing rides it as a physics body (the belt's surface and the
-- load on it are drawn by a shader, logistics.lua). So a pipeline of thirty
-- belts costs what a sum costs.
--
-- THE PIECES the scene hands `build` (all points body-relative):
--   { key, kind = "belt" | "tube" | "blower" | "store" | "chute",
--     ports = { { x, y, z, bore, role = "in" | "out" | "any" } },
--     cap (kg/s for a conveyor; kg for a store), ok (a conveyor runs: powered,
--     not switched off), why (why not), one (a silo: one material), mat (a
--     silo's set material), label, src (a store a quarry discharges into) }
-- A conveyor's "in" port is where it takes load, its "out" where it gives it
-- (the way it was laid; its menu reverses it). A store or a chute meets them
-- on "any" port.
--
-- THE NETWORK. Conveyors that meet (a port on a port, the same bore) are one
-- LINE: its capacity is its weakest piece's (a straight belt 8 kg/s, a ramp
-- 5, a tube 2), it runs only if every piece runs (and, a tube line, it has a
-- Tube Blower). Where a line meets a store at a conveyor's "out" port the
-- store is DOWNSTREAM of it; at an "in" port, UPSTREAM. Two belts meeting
-- head on jam the line, with the reason. The stores are ordered by the lines
-- (topologically); lines in a loop stall ("it loops back on itself").
--
-- THE FLOW, given the state (kg of each material in each store; a chute's
-- room in the craft under it; a quarry's progress), is piecewise constant:
--   * a store with stock offers what its lines can carry; an empty one passes
--     on only what comes in (and what its quarry makes);
--   * a store drains its materials in a fixed order (by name), so the flow is
--     linear between events (a material running out, a store filling, a
--     quarry starting a new layer, a craft's hold full);
--   * a full store takes only what it passes on (`acc`, a backward pass), and
--     its quarry slows to what it can discharge;
--   * a silo takes one material (the one in it, else the one set, else the
--     first offered); a chute takes anything while the craft under it has room.
-- `advance` steps from event to event exactly, so one call of any length
-- equals any number of short ones (smoke_item_net: a day in one call against
-- 86,400).
--
--   build(pieces)                 → net { nodes, lines, order, cyc }
--   newState(net, x)              → st { x = { [i] = { mat = kg } }, prog = {}, room = {} }
--   rates(net, st)                → { flows = { { l, u, d, mat, q } }, r = { [i] = { mat = kg/s } }, prod, f }
--   advance(net, st, dt, opts)    → rep { flows, moved = { "u|d|mat" = kg }, made = { [i] = { mat = kg } }, segs, ff }
--   limitedBy(net, st, rep, i)    → plain words, or nil
--   nodeOf(net, key)              → i

EPS = 1e-9
JOIN = 0.12              -- m: ports this near are one joint
MAX_EVENTS = 400         -- events one advance() call walks (then the rates are held: `ff`)
CAP = { belt = 8.0, ramp = 5.0, tube = 2.0 }

local INF = math.huge
local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end
local function total(x)
  local s = 0
  for _, v in pairs(x or {}) do s = s + v end
  return s
end

function nodeOf(net, key)
  return net and net.byKey and net.byKey[key] or nil
end

-- ── BUILD ───────────────────────────────────────────────────────────────────
function build(pieces)
  local net = { nodes = {}, lines = {}, order = {}, cyc = {}, byKey = {}, why = {} }
  local conv, nodeIdx = {}, {}
  for pi, p in ipairs(pieces) do
    if p.kind == "store" or p.kind == "chute" then
      local n = { key = p.key, kind = p.kind, cap = p.cap or INF, one = p.one, mat = p.mat, label = p.label, src = p.src, slack = p.slack or 0,
                  ups = {}, downs = {}, piece = pi }
      net.nodes[#net.nodes + 1] = n
      net.byKey[p.key] = #net.nodes
      nodeIdx[pi] = #net.nodes
    else
      conv[#conv + 1] = pi
    end
  end
  -- the ports, flat; joints by distance (snapped pieces meet exactly)
  local ports = {}
  for pi, p in ipairs(pieces) do
    for k, pt in ipairs(p.ports or {}) do ports[#ports + 1] = { pi = pi, k = k, x = pt.x, y = pt.y, z = pt.z, bore = pt.bore or "BELT", role = pt.role or "any" } end
  end
  local joint = {}
  local nj = 0
  for a = 1, #ports do
    if not joint[a] then
      nj = nj + 1
      joint[a] = nj
      local A = ports[a]
      for b = a + 1, #ports do
        local Bp = ports[b]
        if not joint[b] and Bp.bore == A.bore and math.abs(Bp.x - A.x) < JOIN and math.abs(Bp.y - A.y) < JOIN and math.abs(Bp.z - A.z) < JOIN then
          joint[b] = nj
        end
      end
    end
  end
  local byJoint = {}
  for a, j in pairs(joint) do byJoint[j] = byJoint[j] or {}; table.insert(byJoint[j], a) end
  -- union-find over the conveyors that meet
  local parent = {}
  local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
  for _, pi in ipairs(conv) do parent[pi] = pi end
  for j = 1, nj do
    local first = nil
    for _, a in ipairs(byJoint[j] or {}) do
      local pi = ports[a].pi
      if parent[pi] then
        if first then local ra, rb = find(first), find(pi); if ra ~= rb then parent[rb] = ra end else first = pi end
      end
    end
  end
  local lineOf = {}
  local roots = {}
  for _, pi in ipairs(conv) do local r = find(pi); roots[r] = roots[r] or {}; table.insert(roots[r], pi) end
  for _, r in ipairs(sorted_keys(roots)) do
    local members = roots[r]
    table.sort(members)
    local L = { key = pieces[members[1]].key, pieces = {}, cap = INF, ok = true, why = nil, ups = {}, downs = {}, kind = "belt", len = 0, segs = {} }
    local blower, tube = false, false
    for _, pi in ipairs(members) do
      local p = pieces[pi]
      L.pieces[#L.pieces + 1] = p.key
      lineOf[pi] = #net.lines + 1
      L.cap = math.min(L.cap, p.cap or CAP.belt)
      L.len = L.len + (p.len or 0)
      if p.kind == "tube" or p.kind == "blower" then tube = true end
      if p.kind == "blower" then blower = true end
      if p.ok == false and L.ok then L.ok, L.why = false, p.why or "a piece of it is off" end
      for _, s in ipairs(p.segs or {}) do L.segs[#L.segs + 1] = s end
    end
    if tube then
      L.kind = "tube"
      if not blower and L.ok then L.ok, L.why = false, "no Tube Blower on it: a tube line needs one to push its capsules" end
    end
    if L.cap == INF then L.cap = CAP.belt end
    net.lines[#net.lines + 1] = L
  end
  -- where the lines meet the stores, and head-on jams
  for j = 1, nj do
    local list = byJoint[j] or {}
    local cport, nport = {}, {}
    for _, a in ipairs(list) do
      local P = ports[a]
      if lineOf[P.pi] then cport[#cport + 1] = P elseif nodeIdx[P.pi] then nport[#nport + 1] = P end
    end
    if #cport >= 2 then
      local outs, ins = 0, 0
      for _, P in ipairs(cport) do if P.role == "out" then outs = outs + 1 elseif P.role == "in" then ins = ins + 1 end end
      if (outs >= 2 or ins >= 2) and #cport == 2 then
        local L = net.lines[lineOf[cport[1].pi]]
        if L.ok then L.ok, L.why = false, (outs >= 2) and "two belts run into each other head on: reverse one (its menu)" or "two belts run away from each other: reverse one (its menu)" end
      end
    end
    for _, P in ipairs(cport) do
      local L = net.lines[lineOf[P.pi]]
      for _, Q in ipairs(nport) do
        local ni = nodeIdx[Q.pi]
        local list2 = (P.role == "out") and L.downs or ((P.role == "in") and L.ups or nil)
        if list2 then
          local seen = false
          for _, v in ipairs(list2) do if v == ni then seen = true end end
          if not seen then list2[#list2 + 1] = ni end
        end
      end
    end
  end
  for li, L in ipairs(net.lines) do
    table.sort(L.ups); table.sort(L.downs)
    for _, u in ipairs(L.ups) do table.insert(net.nodes[u].downs, li) end
    for _, d in ipairs(L.downs) do table.insert(net.nodes[d].ups, li) end
    if L.ok and (#L.ups == 0 or #L.downs == 0) then
      L.idle = (#L.ups == 0 and #L.downs == 0) and "it joins nothing yet" or ((#L.ups == 0) and "nothing feeds it: its tail meets no hopper, silo or quarry drive" or "it delivers nowhere: its head meets no hopper, silo or chute")
    end
    for _, u in ipairs(L.ups) do
      for _, d in ipairs(L.downs) do
        if u == d and L.ok then L.ok, L.why = false, "it runs from a store back into the same store" end
      end
    end
  end
  -- the stores in the order the lines feed them (Kahn); what's left loops
  local indeg = {}
  for i = 1, #net.nodes do indeg[i] = 0 end
  local edges = {}
  for li, L in ipairs(net.lines) do
    if L.ok then
      for _, u in ipairs(L.ups) do for _, d in ipairs(L.downs) do
        if u ~= d then edges[#edges + 1] = { u, d, li }; indeg[d] = indeg[d] + 1 end
      end end
    end
  end
  local ready = {}
  for i = 1, #net.nodes do if indeg[i] == 0 then ready[#ready + 1] = i end end
  local placed = {}
  while #ready > 0 do
    table.sort(ready)
    local i = table.remove(ready, 1)
    net.order[#net.order + 1] = i
    placed[i] = true
    for _, e in ipairs(edges) do
      if e[1] == i then indeg[e[2]] = indeg[e[2]] - 1; if indeg[e[2]] == 0 then ready[#ready + 1] = e[2] end end
    end
  end
  for i = 1, #net.nodes do
    if not placed[i] then
      net.order[#net.order + 1] = i
      net.cyc[i] = true
    end
  end
  for li, L in ipairs(net.lines) do
    for _, u in ipairs(L.ups) do
      if net.cyc[u] and L.ok then L.ok, L.why = false, "it loops back on itself: a line can't feed the store it comes from" end
    end
  end
  net.lineOf = {}
  for pi, li in pairs(lineOf) do net.lineOf[pieces[pi].key] = li end
  return net
end

function newState(net, x)
  local st = { x = {}, prog = {}, room = {} }
  for i, n in ipairs(net.nodes) do
    st.x[i] = {}
    if x and x[i] then for m, v in pairs(x[i]) do st.x[i][m] = v end end
    if n.kind == "chute" then st.room[i] = 0 end
    if n.src then st.prog[i] = 0 end
  end
  return st
end

-- ── THE RATES (constant until the next event) ───────────────────────────────
-- A node's profile (its quarry): node.profile(prog) → { cps, kgps = {mat = kg/s}, toNext }.
local function is_full(n, st, i)
  if n.kind == "chute" then return not (n.target and (st.room[i] or 0) > EPS) end
  return total(st.x[i]) >= (n.cap or INF) - (n.slack or 0) - 1e-7
end

function rates(net, st)
  local nodes, lines = net.nodes, net.lines
  local full, acc = {}, {}
  for i, n in ipairs(nodes) do full[i] = is_full(n, st, i) end
  -- backward: what a full store can take is what it passes on
  for k = #net.order, 1, -1 do
    local i = net.order[k]
    local n = nodes[i]
    if n.kind == "chute" then acc[i] = full[i] and 0 or INF
    elseif not full[i] then acc[i] = INF
    else
      local out = 0
      for _, li in ipairs(n.downs) do
        local L = lines[li]
        if L.ok then
          local a = 0
          for _, d in ipairs(L.downs) do a = a + (acc[d] or 0) end
          out = out + math.min(L.cap, a)
        end
      end
      acc[i] = out
    end
  end
  local inflow, outflow, prod, f = {}, {}, {}, {}
  for i in ipairs(nodes) do inflow[i], outflow[i], prod[i] = {}, {}, {} end
  local lineRem = {}
  for li, L in ipairs(lines) do lineRem[li] = L.ok and L.cap or 0 end
  local accRem = {}
  for i in ipairs(nodes) do accRem[i] = acc[i] end
  local siloMat = {}
  for i, n in ipairs(nodes) do
    if n.one then
      for m, v in pairs(st.x[i]) do if v > EPS then siloMat[i] = m end end
      siloMat[i] = siloMat[i] or n.mat
    end
  end
  local flows = {}
  for _, i in ipairs(net.order) do
    local n = nodes[i]
    -- what this store's quarry makes, at full pace (scaled below when it can't discharge)
    local P = n.profile and n.profile(st.prog[i] or 0) or nil
    local pk = {}
    if P and not P.done and not n.blocked then for m, v in pairs(P.kgps or {}) do pk[m] = v end end
    local mats = {}
    for m, v in pairs(st.x[i]) do if v > EPS then mats[m] = true end end
    for m in pairs(inflow[i]) do mats[m] = true end
    for m in pairs(pk) do mats[m] = true end
    local mlist = sorted_keys(mats)
    local avail = {}
    for _, m in ipairs(mlist) do
      if (st.x[i][m] or 0) > EPS then avail[m] = INF else avail[m] = (inflow[i][m] or 0) + (pk[m] or 0) end
    end
    if n.kind ~= "chute" then
      for _, li in ipairs(n.downs) do
        local L = lines[li]
        if L.ok then
          for _, d in ipairs(L.downs) do
            for _, m in ipairs(mlist) do
              local ok = true
              if nodes[d].one then
                if siloMat[d] == nil then siloMat[d] = m end
                ok = siloMat[d] == m
              end
              if ok then
                local q = math.min(avail[m], lineRem[li], accRem[d])
                if q > EPS and q < INF then
                  flows[#flows + 1] = { l = li, u = i, d = d, mat = m, q = q }
                  avail[m] = avail[m] - q
                  lineRem[li] = lineRem[li] - q
                  if accRem[d] < INF then accRem[d] = accRem[d] - q end
                  inflow[d][m] = (inflow[d][m] or 0) + q
                  outflow[i][m] = (outflow[i][m] or 0) + q
                end
              end
            end
          end
        end
      end
    end
    -- the quarry's pace: full, it makes only what leaves (less what comes in)
    if P and not P.done then
      local pt = 0
      for _, v in pairs(pk) do pt = pt + v end
      local fi = 1
      if full[i] then
        local o, inn = 0, 0
        for _, v in pairs(outflow[i]) do o = o + v end
        for _, v in pairs(inflow[i]) do inn = inn + v end
        if pt > EPS then fi = math.max(0, math.min(1, (o - inn) / pt)) else fi = 0 end
      end
      if n.blocked then fi = 0 end
      f[i] = fi
      for m, v in pairs(pk) do prod[i][m] = v * fi end
    end
  end
  local r = {}
  for i, n in ipairs(nodes) do
    r[i] = {}
    if n.kind ~= "chute" then
      local ms = {}
      for m in pairs(inflow[i]) do ms[m] = true end
      for m in pairs(outflow[i]) do ms[m] = true end
      for m in pairs(prod[i]) do ms[m] = true end
      for m in pairs(ms) do r[i][m] = (inflow[i][m] or 0) + (prod[i][m] or 0) - (outflow[i][m] or 0) end
    end
  end
  return { flows = flows, r = r, prod = prod, f = f, inflow = inflow, outflow = outflow, full = full, acc = acc }
end

-- ── ADVANCE (event to event, exact) ─────────────────────────────────────────
function advance(net, st, dt, opts)
  opts = opts or {}
  local rep = { moved = {}, made = {}, segs = 0, ff = false, events = {} }
  local left = dt
  local R
  local nevents = 0
  while left > 1e-12 do
    R = rates(net, st)
    rep.segs = rep.segs + 1
    -- the next event
    local h = left
    local why = nil
    for i, n in ipairs(net.nodes) do
      local ri = R.r[i]
      if n.kind ~= "chute" then
        local T = 0
        for m, v in pairs(ri) do
          T = T + v
          if v < -EPS and (st.x[i][m] or 0) > EPS then
            local t = (st.x[i][m] or 0) / -v
            if t < h then h, why = t, { "empty", i, m } end
          end
        end
        if T > EPS and (n.cap or INF) < INF and not R.full[i] then
          local t = ((n.cap or INF) - (n.slack or 0) - total(st.x[i])) / T
          if t < h then h, why = math.max(0, t), { "full", i } end
        end
      else
        local inn = 0
        for _, v in pairs(R.inflow[i]) do inn = inn + v end
        if inn > EPS then
          local t = (st.room[i] or 0) / inn
          if t < h then h, why = t, { "room", i } end
        end
      end
      if n.profile and R.f[i] and R.f[i] > EPS then
        local P = n.profile(st.prog[i] or 0)
        if P and not P.done and P.cps > 0 then
          local t = P.toNext / (P.cps * R.f[i])
          if t < h then h, why = t, { "layer", i } end
        end
      end
    end
    if nevents >= MAX_EVENTS then h, why, rep.ff = left, nil, true end
    h = math.max(0, math.min(h, left))
    -- move everything h along
    for _, fl in ipairs(R.flows) do
      local key = fl.u .. "|" .. fl.d .. "|" .. fl.mat
      rep.moved[key] = (rep.moved[key] or 0) + fl.q * h
    end
    for i, n in ipairs(net.nodes) do
      if n.kind == "chute" then
        local inn = 0
        for _, v in pairs(R.inflow[i]) do inn = inn + v end
        st.room[i] = math.max(0, (st.room[i] or 0) - inn * h)
      else
        for m, v in pairs(R.r[i]) do
          local x = (st.x[i][m] or 0) + v * h
          if x < 1e-9 then x = 0 end
          st.x[i][m] = x
        end
        local cap = n.cap or INF
        if cap < INF then
          local T = total(st.x[i])
          if T > cap then
            -- (an overfill from a shared acceptance: off the material coming in fastest)
            local best, bv = nil, -INF
            for m, v in pairs(R.r[i]) do if v > bv then best, bv = m, v end end
            if best then st.x[i][best] = math.max(0, st.x[i][best] - (T - cap)) end
          end
        end
      end
      for m, v in pairs(R.prod[i] or {}) do
        rep.made[i] = rep.made[i] or {}
        rep.made[i][m] = (rep.made[i][m] or 0) + v * h
      end
      if n.profile and R.f[i] then
        local P = n.profile(st.prog[i] or 0)
        if P and not P.done then
          local np = (st.prog[i] or 0) + P.cps * R.f[i] * h
          -- (land exactly on a layer's boundary)
          if why and why[1] == "layer" and why[2] == i then np = (st.prog[i] or 0) + P.toNext end
          st.prog[i] = np
        end
      end
    end
    -- snap the event exactly
    if why then
      nevents = nevents + 1
      if #rep.events < 32 then rep.events[#rep.events + 1] = { what = why[1], i = why[2], mat = why[3], t = dt - left + h } end
      if why[1] == "empty" then st.x[why[2]][why[3]] = 0
      elseif why[1] == "room" then st.room[why[2]] = 0
      elseif why[1] == "full" then
        local n = net.nodes[why[2]]
        local T = total(st.x[why[2]])
        if (n.slack or 0) == 0 and math.abs(T - n.cap) < 1e-6 then
          local best, bv = nil, -INF
          for m, v in pairs(R.r[why[2]]) do if v > bv then best, bv = m, v end end
          if best then st.x[why[2]][best] = st.x[why[2]][best] + (n.cap - T) end
        end
      end
    end
    left = left - h
    if h <= 0 and not why then break end
  end
  rep.flows = R and R.flows or {}
  rep.R = R
  return rep
end

-- ── WHY IT IS SLOW ──────────────────────────────────────────────────────────
-- The first thing holding node i (or the whole net) back, in plain words.
function limitedBy(net, st, rep, i, label)
  label = label or function(j) return net.nodes[j].label or ("store " .. j) end
  local R = rep and rep.R or rates(net, st)
  local function one(j)
    local n = net.nodes[j]
    if n.kind == "chute" then
      if not n.target then return string.format("%s has no craft under it (a craft on its stand, or parked within 6 m)", label(j)) end
      if (st.room[j] or 0) <= EPS then return string.format("%s: the craft's hold is full", label(j)) end
      if #n.ups == 0 then return string.format("%s: no belt or tube brings it anything", label(j)) end
      return nil
    end
    if n.profile then
      local P = n.profile(st.prog[j] or 0)
      if P and P.done then return string.format("%s: the quarry has dug to its floor", label(j)) end
      if n.blocked then return string.format("%s: %s", label(j), n.blocked) end
      if R.f[j] and R.f[j] < 1 - 1e-6 then
        local downs = {}
        for _, li in ipairs(n.downs) do local L = net.lines[li]; if not L.ok then return string.format("%s is full: its line is stopped (%s)", label(j), L.why or "off") end end
        if #n.downs == 0 then return string.format("%s is full: nothing takes from it (lay a belt or tube from its discharge)", label(j)) end
        return string.format("%s is full: its lines carry away only %.2f kg/s", label(j), (function() local o = 0; for _, v in pairs(R.outflow[j]) do o = o + v end return o end)())
      end
    end
    for _, li in ipairs(n.downs) do
      local L = net.lines[li]
      if not L.ok then return string.format("its line is stopped: %s", L.why or "off") end
    end
    if R.full[j] and n.kind == "store" and #n.downs == 0 then return string.format("%s is full", label(j)) end
    return nil
  end
  if i then return one(i) end
  for _, L in ipairs(net.lines) do if not L.ok then return L.why end end
  for _, j in ipairs(net.order) do local w = one(j); if w then return w end end
  for _, L in ipairs(net.lines) do if L.idle then return L.idle end end
  return nil
end

-- Why line li carries nothing now, in plain words (nil while it carries).
function lineWhy(net, st, rep, li, label)
  label = label or function(j) return net.nodes[j].label or ("store " .. j) end
  local L = net.lines[li]
  if not L then return nil end
  if not L.ok then return L.why end
  if L.idle then return L.idle end
  if lineFlow(rep, li) > EPS then return nil end
  local R = rep and rep.R or rates(net, st)
  local stock = {}
  for _, u in ipairs(L.ups) do for m, v in pairs(st.x[u] or {}) do if v > EPS then stock[m] = true end end end
  if next(stock) == nil then return "nothing to carry: " .. label(L.ups[1]) .. " is empty" end
  for _, d in ipairs(L.downs) do
    local n = net.nodes[d]
    if R.full[d] then return n.kind == "chute" and (n.target and (label(d) .. ": the craft's hold is full") or (label(d) .. " has no craft under it")) or (label(d) .. " is full") end
    if n.one then
      local want = n.mat
      for m, v in pairs(st.x[d] or {}) do if v > EPS then want = m end end
      if want and not stock[want] then return string.format("%s takes only %s, and none is offered", label(d), (rep and rep.matLabel and rep.matLabel(want)) or want) end
    end
  end
  return nil
end

-- kg/s a line carries now (from a rates() or advance() report)
function lineFlow(rep, li)
  local q = 0
  for _, fl in ipairs(rep and rep.flows or {}) do if fl.l == li then q = q + fl.q end end
  return q
end
