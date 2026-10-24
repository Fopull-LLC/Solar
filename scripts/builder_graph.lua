-- BUILDER_GRAPH — the craft as PARTS PLUS CONNECTIONS (WP1, docs/builder-design.md
-- §5.1, §5.8). A pure RULEBOOK script on the BuilderGraph manager node: no
-- scene access, its globals are its API, and it loads from disk in a luajit
-- test. Reach it with findScript("builder_graph").
--
-- A LINK is { id, a, b, k, sa, sb, pa, pb, n, s, prim }:
--   a, b     part uids (a = the host it was placed on, b = the placed part)
--   k        stack | surface | splice | corner | tee | cross | brace | weld |
--            decouple | hinge | piston | rotor
--   sa, sb   the side on a and on b: "top" | "bottom" | "surface" | "radial" |
--            "a" | "b" (member ends) | nil — stack-node OCCUPANCY reads these,
--            never world Y
--   pa, pb   the joint point in a's / b's LOCAL frame (optional)
--   n        the joint normal in a's local frame (optional)
--   s        strength override (optional)
--   prim     true on the PRIMARY link: the one the part was placed through,
--            which is the blueprint's old `parent`/`att` (one per part at most)
--
-- G = newGraph()
--   G:add(link) → id (an identical a,b,k link is not added twice)
--   G:remove(id) ; G:removePart(uid) → the links it had
--   G:incident(uid) → { link… } ; G:neighbours(uid) → { uid… } ; G:get(id)
--   G:primary(uid) → the link that placed uid, or nil
--   G:sideUsed(uid, side) → bool (a stack node in use)
--   G:all() → { link… } sorted by id ; G:count()
--
-- Pure questions over (G, alive), alive = set of uids on the stand:
--   anchorOf(...) / components(G, alive, root) → { { uids…, anchor, root }… }
--   dependents(G, alive, set, root) → set of the parts that would lose their
--       island's anchor without `set` (what comes along when `set` moves)
--   beyond(G, alive, from, via) → set reachable from `from` without passing `via`
--   separation(G, alive, uid, root) → the far side a decoupler throws off, or
--       nil when the far side is still joined to the root another way
--   hingeLocked(G, alive, uid, root) → true when the moving side of a robotic
--       joint reaches the fixed side through another link (a loop)
--   linksFromV1(parts) → links for a v1 blueprint's parent/att fields
--   v1Kind(att) → "stack" | "surface"

local function opp(side)
  if side == "top" then return "bottom" end
  if side == "bottom" then return "top" end
  return side
end

function v1Kind(att)
  if att == nil or att == "" or att == "top" or att == "bottom" then return "stack" end
  return "surface"
end

-- The link a v1 parent edge stands for: a = parent, b = child.
function v1Link(parent, child, att)
  att = (att ~= "" and att) or nil
  local k = v1Kind(att)
  local sa = att or "top"
  local sb = (k == "stack") and opp(sa) or "surface"
  return { a = parent, b = child, k = k, sa = sa, sb = sb, prim = true }
end

function newGraph()
  local G = { links = {}, adj = {}, next_id = 1, n = 0 }

  local function adj(uid)
    local t = G.adj[uid]
    if not t then t = {}; G.adj[uid] = t end
    return t
  end

  function G:add(l)
    if not (l and l.a and l.b) or l.a == l.b then return nil end
    -- one link per (a, b, kind)
    for id in pairs(self.adj[l.a] or {}) do
      local o = self.links[id]
      if o and o.k == l.k and ((o.a == l.a and o.b == l.b) or (o.a == l.b and o.b == l.a)) then
        if l.prim then o.prim = true; o.sa = l.sa or o.sa; o.sb = l.sb or o.sb end
        return id
      end
    end
    if l.prim then
      -- one primary link per placed part
      local old = self:primary(l.b)
      if old then old.prim = nil end
    end
    local id = l.id
    if not id or self.links[id] then id = self.next_id end
    if id >= self.next_id then self.next_id = id + 1 end
    local c = {}
    for k2, v in pairs(l) do c[k2] = v end
    c.id = id
    self.links[id] = c
    adj(c.a)[id] = true
    adj(c.b)[id] = true
    self.n = self.n + 1
    return id
  end

  function G:get(id) return self.links[id] end

  function G:remove(id)
    local l = self.links[id]
    if not l then return nil end
    self.links[id] = nil
    if self.adj[l.a] then self.adj[l.a][id] = nil end
    if self.adj[l.b] then self.adj[l.b][id] = nil end
    self.n = self.n - 1
    return l
  end

  function G:removePart(uid)
    local out = {}
    for id in pairs(self.adj[uid] or {}) do
      local l = self:remove(id)
      if l then out[#out + 1] = l end
    end
    self.adj[uid] = nil
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
  end

  function G:incident(uid)
    local out = {}
    for id in pairs(self.adj[uid] or {}) do out[#out + 1] = self.links[id] end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
  end

  function G:neighbours(uid)
    local out, seen = {}, {}
    for id in pairs(self.adj[uid] or {}) do
      local l = self.links[id]
      local o = (l.a == uid) and l.b or l.a
      if not seen[o] then seen[o] = true; out[#out + 1] = o end
    end
    table.sort(out)
    return out
  end

  function G:primary(uid)
    for id in pairs(self.adj[uid] or {}) do
      local l = self.links[id]
      if l.prim and l.b == uid then return l end
    end
    return nil
  end

  -- Is this stack node of `uid` in use by a link? (side "top"/"bottom")
  function G:sideUsed(uid, side)
    for id in pairs(self.adj[uid] or {}) do
      local l = self.links[id]
      if (l.a == uid and l.sa == side) or (l.b == uid and l.sb == side) then return true end
    end
    return false
  end

  function G:all()
    local out = {}
    for _, l in pairs(self.links) do out[#out + 1] = l end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
  end

  function G:count() return self.n end
  function G:clear() self.links, self.adj, self.n = {}, {}, 0 end

  return G
end

-- BFS from `starts` over live parts, never entering `block` (a set) and never
-- crossing a link `skip(l)` says to skip. → set.
local function flood(G, alive, starts, block, skip)
  local seen, q, h = {}, {}, 1
  for _, s in ipairs(starts) do
    if alive[s] and not (block and block[s]) and not seen[s] then seen[s] = true; q[#q + 1] = s end
  end
  while h <= #q do
    local u = q[h]; h = h + 1
    for id in pairs(G.adj[u] or {}) do
      local l = G.links[id]
      if l and not (skip and skip(l)) then
        local o = (l.a == u) and l.b or l.a
        if alive[o] and not seen[o] and not (block and block[o]) then
          seen[o] = true
          q[#q + 1] = o
        end
      end
    end
  end
  return seen
end
graphFlood = flood

-- The ANCHOR of an island: the craft root if it is in it, else its command
-- part (lowest uid), else the lowest uid with no primary link, else its
-- lowest uid. `isCommand(uid)` is optional.
function components(G, alive, root, isCommand)
  local done, out = {}, {}
  local uids = {}
  for u in pairs(alive) do uids[#uids + 1] = u end
  table.sort(uids)
  for _, u in ipairs(uids) do
    if not done[u] then
      local set = flood(G, alive, { u })
      local list = {}
      for v in pairs(set) do list[#list + 1] = v; done[v] = true end
      table.sort(list)
      local anchor, cmd, free = nil, nil, nil
      if root and set[root] then anchor = root end
      for _, v in ipairs(list) do
        if not cmd and isCommand and isCommand(v) then cmd = v end
        if not free and not G:primary(v) then free = v end
      end
      anchor = anchor or cmd or free or list[1]
      list.anchor = anchor
      list.root = (root ~= nil and set[root]) and true or false
      list.set = set
      out[#out + 1] = list
    end
  end
  return out
end

-- What comes along when `set` moves: every part of the islands `set` touches
-- that can no longer reach its island's anchor once `set` is gone. When the
-- anchor itself is in `set`, its whole island comes along.
function dependents(G, alive, set, root, isCommand)
  local out = {}
  local comps = components(G, alive, root, isCommand)
  for _, c in ipairs(comps) do
    local touched = false
    for u in pairs(set) do if c.set[u] then touched = true break end end
    if touched then
      if set[c.anchor] then
        for _, v in ipairs(c) do if not set[v] then out[v] = true end end
      else
        local reach = flood(G, alive, { c.anchor }, set)
        for _, v in ipairs(c) do
          if not set[v] and not reach[v] then out[v] = true end
        end
      end
    end
  end
  return out
end

-- Everything reachable from `from` without passing through `via`.
function beyond(G, alive, from, via)
  return flood(G, alive, { from }, { [via] = true })
end

-- A decoupler's far side: cut the decoupler's links to its root side, take the
-- component of the decoupler; nil when that still reaches the root (a loop
-- through a strut or weld keeps the stages joined). `uid` itself is included
-- (a radial decoupler leaves with its booster, as the flight throws it).
function separation(G, alive, uid, root)
  if not (alive[uid] and root and alive[root]) or uid == root then return nil end
  local prim = G:primary(uid)
  -- the root side: whichever neighbour still reaches the root without uid
  local rootReach = flood(G, alive, { root }, { [uid] = true })
  local cut = {}
  for id in pairs(G.adj[uid] or {}) do
    local l = G.links[id]
    local o = (l.a == uid) and l.b or l.a
    if rootReach[o] then cut[id] = true end
  end
  if next(cut) == nil and not prim then return nil end
  -- every neighbour still reaches the root without it: nothing falls off
  local all = true
  for id in pairs(G.adj[uid] or {}) do
    local l = G.links[id]
    local o = (l.a == uid) and l.b or l.a
    if alive[o] and not rootReach[o] then all = false end
  end
  if all then return nil end
  local far = flood(G, alive, { uid }, nil, function(l) return cut[l.id] end)
  if far[root] then return nil end
  return far
end

-- A robotic joint (hinge/piston/rotor part `uid`) moves what stands on its
-- moving face: the part's links other than its primary link lead to the moving
-- side. It is LOCKED when the moving side reaches the fixed side (the primary
-- host) through any other path.
function hingeLocked(G, alive, uid)
  local prim = G:primary(uid)
  if not prim then return false end
  local fixed = prim.a
  local moving = {}
  for id in pairs(G.adj[uid] or {}) do
    local l = G.links[id]
    if id ~= prim.id then moving[#moving + 1] = (l.a == uid) and l.b or l.a end
  end
  if #moving == 0 then return false end
  local reach = flood(G, alive, moving, { [uid] = true })
  return reach[fixed] == true
end

-- A v1 blueprint's parent edges as links (a = parent, b = child, primary).
function linksFromV1(list)
  local out, have = {}, {}
  for _, d in pairs(list) do have[d.uid] = true end
  for _, d in pairs(list) do
    local p = d.parent or 0
    if p ~= 0 and have[p] then out[#out + 1] = v1Link(p, d.uid, d.att) end
  end
  table.sort(out, function(x, y) return x.b < y.b end)
  return out
end

-- A link as the blueprint stores it (no ids, plain numbers; pa/pb/n tables).
function packLink(l)
  local function v(t) return t and { x = t.x, y = t.y, z = t.z } or nil end
  return { a = l.a, b = l.b, k = l.k, sa = l.sa, sb = l.sb, pa = v(l.pa), pb = v(l.pb),
           n = v(l.n), s = l.s, prim = l.prim and 1 or nil }
end

function unpackLink(t)
  local function v(x) return x and { x = x.x or 0, y = x.y or 0, z = x.z or 0 } or nil end
  return { a = t.a, b = t.b, k = t.k or "surface", sa = t.sa, sb = t.sb, pa = v(t.pa), pb = v(t.pb),
           n = v(t.n), s = t.s, prim = (t.prim == 1 or t.prim == true) or nil }
end
