-- MAP LABELS — where the Tracking Station's name tags go on the map, so that
-- two of them never sit on each other (docs/tracking-station.md §4.4).
--
-- Pure: screen rectangles in, offsets out. No scene, no drawing: the station
-- (scripts/tracking_station.lua) projects the anchors, asks for a layout a
-- few times a second, keeps each tag's OFFSET FROM ITS ANCHOR between runs and
-- re-projects the anchors every frame. Nothing world-positioned is kept here.
--
--   cluster(points, radius, minN, keep) → clusters, member_of
--       points: { {id, x, y, prio, kind}… }; radius px; minN (3) or more
--       icons within `radius` of the first become one disc with a count.
--       keep[id] = true never clusters (the selected, the hovered).
--   layout(items, opts) → placed[id] = { dx, dy, w, h, tier, leader }
--       items: { {id, x, y, r, prio, tiers = { {w, h}, … } }… }  best tier first
--       opts:  blocked = { {x, y, w, h}… }  (panels: nothing lands under them)
--              pre     = { {x, y, w, h}… }  (already placed: the worlds' names)
--              icons   = { {x, y, r}… }     (every icon drawn: tags avoid them)
--              sw, sh, cap (40 tags), cell (32 px)
--       items may say force = true (the selection): past every spot it tries
--       again over the other icons (never over a tag or a panel).
--       Priority order; each tries 8 spots round its icon, then 4 further out
--       with a leader line; a tag that finds none drops a tier, and past the
--       last tier (or the cap) the item is drawn as its icon only (tier 0).
--   key(parts) → string   the cache key the station re-runs the layout on
--   overlaps(placed, items) → n   pairs of placed tags that overlap (tests, probe)
--
-- A 32 px grid holds what is placed: a rectangle is tested against the cells
-- it spans, so a layout is about n × (a few cells) tests, not n².

CELL = 32
CAP = 40
GAP = 3          -- px between an icon's rim and its tag
FAR = 26         -- px further out for the leader-line spots

local function grid_new(cell)
  return { cell = cell or CELL, c = {} }
end

local function span(g, x, y, w, h)
  local c = g.cell
  return math.floor(x / c), math.floor(y / c), math.floor((x + w) / c), math.floor((y + h) / c)
end

local function grid_add(g, r)
  local x0, y0, x1, y1 = span(g, r[1], r[2], r[3], r[4])
  for cx = x0, x1 do
    for cy = y0, y1 do
      local k = cx * 65536 + cy
      local l = g.c[k]
      if not l then l = {}; g.c[k] = l end
      l[#l + 1] = r
    end
  end
end

local function hit(a, b)
  return a[1] < b[1] + b[3] and a[1] + a[3] > b[1] and a[2] < b[2] + b[4] and a[2] + a[4] > b[2]
end

local function grid_hit(g, r, skip_icons)
  local x0, y0, x1, y1 = span(g, r[1], r[2], r[3], r[4])
  for cx = x0, x1 do
    for cy = y0, y1 do
      local l = g.c[cx * 65536 + cy]
      if l then
        for i = 1, #l do
          local q = l[i]
          if q ~= r.self and not (skip_icons and q.icon) and hit(r, q) then return true end
        end
      end
    end
  end
  return false
end

-- The spots round an icon of radius r for a tag w × h: (dx, dy) of the tag's
-- top-left corner from the anchor, and whether it needs a leader line.
local function spots(r, w, h)
  local g = GAP
  local a = r + g
  return {
    { -w / 2, -a - h, false },            -- above
    { a, -h / 2, false },                 -- right
    { -a - w, -h / 2, false },            -- left
    { -w / 2, a, false },                 -- below
    { a * 0.7, -a * 0.7 - h, false },     -- up-right
    { -a * 0.7 - w, -a * 0.7 - h, false },-- up-left
    { a * 0.7, a * 0.7, false },          -- down-right
    { -a * 0.7 - w, a * 0.7, false },     -- down-left
    { -w / 2, -a - FAR - h, true },       -- further up, with a leader
    { a + FAR, -h / 2, true },
    { -a - FAR - w, -h / 2, true },
    { -w / 2, a + FAR, true },
  }
end

local function by_prio(a, b)
  if a.prio ~= b.prio then return a.prio > b.prio end
  return tostring(a.id) < tostring(b.id)
end

function layout(items, opts)
  opts = opts or {}
  local sw, sh = opts.sw or 1e9, opts.sh or 1e9
  local cap = opts.cap or CAP
  local g = grid_new(opts.cell)
  for _, b in ipairs(opts.blocked or {}) do grid_add(g, { b[1], b[2], b[3], b[4], blocked = true }) end
  for _, b in ipairs(opts.pre or {}) do grid_add(g, { b[1], b[2], b[3], b[4] }) end
  local icon_r = {}
  for _, ic in ipairs(opts.icons or {}) do
    local q = { ic[1] - ic[3], ic[2] - ic[3], ic[3] * 2, ic[3] * 2, icon = true }
    grid_add(g, q)
    if ic.id ~= nil then icon_r[ic.id] = q end
  end
  local order = {}
  for i, it in ipairs(items) do order[i] = it end
  table.sort(order, by_prio)
  local out, n = {}, 0
  for _, it in ipairs(order) do
    local done = false
    -- (an item marked `force` — the selection — may cover other icons as a
    -- last resort, never another tag or a panel)
    for pass = 1, (it.force and 2 or 1) do
    if n < cap and not done then
      for t, sz in ipairs(it.tiers or {}) do
        local w, h = sz[1], sz[2]
        for _, s in ipairs(spots(it.r or 6, w, h)) do
          local x, y = it.x + s[1], it.y + s[2]
          if x >= 0 and y >= 0 and x + w <= sw and y + h <= sh then
            local r = { x, y, w, h, self = icon_r[it.id] }
            if not grid_hit(g, r, pass == 2) then
              r.self = nil
              grid_add(g, r)
              out[it.id] = { dx = s[1], dy = s[2], w = w, h = h, tier = t, leader = s[3] }
              n = n + 1
              done = true
              break
            end
          end
        end
        if done then break end
      end
    end
    end
    if not done then out[it.id] = { tier = 0 } end
  end
  return out, n
end

-- Icons near each other become one disc with a count (≥ minN within radius).
-- The highest priority icon of a group is its seed and names the cluster.
function cluster(points, radius, minN, keep)
  radius = radius or 14
  minN = minN or 3
  keep = keep or {}
  local g = {}
  local cell = radius
  local function k(cx, cy) return cx * 65536 + cy end
  for _, p in ipairs(points) do
    local cx, cy = math.floor(p.x / cell), math.floor(p.y / cell)
    local key = k(cx, cy)
    local l = g[key]
    if not l then l = {}; g[key] = l end
    l[#l + 1] = p
  end
  local order = {}
  for i, p in ipairs(points) do order[i] = p end
  table.sort(order, by_prio)
  local used, out, member_of = {}, {}, {}
  local r2 = radius * radius
  for _, p in ipairs(order) do
    if not used[p.id] and not keep[p.id] then
      local cx, cy = math.floor(p.x / cell), math.floor(p.y / cell)
      local near = { p }
      for ix = cx - 1, cx + 1 do
        for iy = cy - 1, cy + 1 do
          for _, q in ipairs(g[k(ix, iy)] or {}) do
            if q ~= p and not used[q.id] and not keep[q.id] then
              local dx, dy = q.x - p.x, q.y - p.y
              if dx * dx + dy * dy <= r2 then near[#near + 1] = q end
            end
          end
        end
      end
      if #near >= minN then
        local c = { id = "k:" .. tostring(p.id), x = 0, y = 0, n = #near, members = {}, seed = p, kind = p.kind }
        local counts = {}
        for _, q in ipairs(near) do
          used[q.id] = true
          member_of[q.id] = c
          c.members[#c.members + 1] = q.id
          c.x, c.y = c.x + q.x, c.y + q.y
          counts[q.kind or "?"] = (counts[q.kind or "?"] or 0) + 1
        end
        c.x, c.y = c.x / #near, c.y / #near
        -- the kind most of it is (the rim colour), the seed's on a tie
        local best, bn = p.kind, counts[p.kind or "?"] or 0
        for kd, cnt in pairs(counts) do if cnt > bn then best, bn = kd, cnt end end
        c.kind = best
        out[#out + 1] = c
      end
    end
  end
  -- clusters whose discs would touch merge (a dense world read as a pile of
  -- overlapping counts)
  local merged = true
  while merged do
    merged = false
    for i = 1, #out do
      for j = i + 1, #out do
        local a, b = out[i], out[j]
        local dx, dy = a.x - b.x, a.y - b.y
        if dx * dx + dy * dy < (radius * 1.6) ^ 2 then
          local n = a.n + b.n
          a.x, a.y = (a.x * a.n + b.x * b.n) / n, (a.y * a.n + b.y * b.n) / n
          a.n = n
          for _, id in ipairs(b.members) do a.members[#a.members + 1] = id; member_of[id] = a end
          if (b.seed.prio or 0) > (a.seed.prio or 0) then a.seed = b.seed end
          table.remove(out, j)
          merged = true
          break
        end
      end
      if merged then break end
    end
  end
  return out, member_of
end

-- The layout's cache key: re-run when any of these changes (and at most
-- every 0.25 s otherwise, the station's rule).
--   ppu: pixels per metre at the focus; yaw, pitch: the view, radians.
function key(ppu, yaw, pitch, sel, hover, ver, filt, sw, sh, dh)
  local zb = (ppu and ppu > 0) and math.floor(math.log(ppu) / math.log(2) * 4 + 0.5) or 0
  local qy = math.floor(math.deg(yaw or 0) + 0.5)
  local qp = math.floor(math.deg(pitch or 0) + 0.5)
  return string.format("%d|%d|%d|%s|%s|%s|%s|%d|%d|%d", zb, qy, qp, tostring(sel), tostring(hover),
    tostring(ver), tostring(filt), math.floor(sw or 0), math.floor(sh or 0), math.floor(dh or 0))
end

function overlaps(placed, items)
  local rects = {}
  for _, it in ipairs(items) do
    local p = placed[it.id]
    if p and p.tier and p.tier > 0 then rects[#rects + 1] = { it.x + p.dx, it.y + p.dy, p.w, p.h } end
  end
  local n = 0
  for i = 1, #rects do
    for j = i + 1, #rects do
      local a, b = rects[i], rects[j]
      -- (a hair of tolerance: touching edges are not an overlap)
      if a[1] + 0.01 < b[1] + b[3] and a[1] + a[3] > b[1] + 0.01 and a[2] + 0.01 < b[2] + b[4] and a[2] + a[4] > b[2] + 0.01 then
        n = n + 1
      end
    end
  end
  return n
end
