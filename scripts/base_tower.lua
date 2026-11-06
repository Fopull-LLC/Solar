-- BASE TOWER — the Base Station Tower's behaviour (deep-space addendum M1–M3,
-- M5, M8–M9; docs/base-building.md §11). The part itself is parts_base
-- `tower`, placed with the Build Kit like any BASE part; this is its
-- `script` (structures.lua's spawned / gone hooks, field_builder's canRemove
-- and placeWhy), on the Build Kit node beside bases.lua.
--
--   FOUNDING (M1)  every tower part in the structures is a base (bases.lua):
--                  a new one is founded the moment its tower appears, its id
--                  kept on the tower's bp entry (`base`), and a name field
--                  opens over the view ("Outpost <n>" if left as it is). A
--                  tower taken down marks its base down, under its name, so
--                  the minute's undo (or redo) stands the same base again.
--                  Kept in step whenever structures.version moves; nothing
--                  is looked at otherwise.
--   THE RULES      towers stand 1 km apart along the ground, the spaceport's
--                  Tracking Station included (placeWhy, the red ghost's
--                  reason). M8's dig guard: no dig reaches under a structure
--                  (base_facilities.setGuards, one owner a structure, synced
--                  with the records).
--   THE RELAY (M2) comms.solve asks commsNodes(): each standing tower is a
--                  transmitter with its antenna 11.6 m up its mast, tiered by
--                  power (Q20):
--                    unpowered  a mast: a beacon-class relay (COMMS.beacon,
--                               1500), linking home through other relays;
--                    powered    2 EC/s or more: a ground station, a second
--                               HOME ROOT at the Tracking Station's 4.0e5
--                               (solveNetwork zeroes every `home`). Off the
--                               home world (not buildable before step 13) a
--                               powered tower is a 4.0e5 relay: home only
--                               through a path to the real one.
--   POWER          the base grid (M6, step 8; base_grid.lua): every
--                  structure within 150 m of the tower, and any joined to it
--                  by a Power Cable, shares one grid with the tower's 2 EC/s
--                  as a load. Solar Arrays, Isotope Skids and Battery Banks
--                  on it decide whether it is a ground station (its load
--                  served) or a mast (shed). This script only reads the
--                  grid's answer.
--   THE MAP (M5)   bases() lists every base for the map's glyph and the
--                  Tracking Station's BASES section: the home base #0 first,
--                  then each tower with its power, its link and its world's
--                  ground coverage.
--
-- COST: an idle tower is a static prefab like any placed part. Per frame this
-- script compares one version number (and registers its menu once); the
-- solve's call is a cached list. The name field draws only while it is open.
--
-- Probes: prompting(), prompt, commitName(s), cancelName(), power(bid),
-- bases(), commsNodes(by), towerOf(bid), reconcile(), placeWhy(id, def, p).

defaults = {
  --@range 0.5 10 --@units s
  power_every = 2.0,
}

-- Published.
prompt = nil          -- { bid, text, t } while the name field is open
escTakenAt = -1

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function say(s)
  if caption then pcall(caption, s) end
  if log then log("tower: " .. s) end
end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function home_body() return save and save.get and save.get("base.body") or nil end
local function parts() return ref("parts_base") end
local function defOf(p) local pb = parts(); return pb and p and pb.partInfo(p.id) or nil end
local function towerDef() local pb = parts(); return pb and pb.partInfo("tower") or nil end
local function radiusOf(body)
  local b = space and space.body and space.body(body)
  return b and b.radius or nil
end

-- ── the towers, kept in step with the structures ────────────────────────────
-- tw[bid] = { sid, uid, b, gx, gy, gz (ground point), ax, ay, az (antenna),
--             both body-relative, ux, uy, uz (its up) }
local tw = {}
local st_ver, bs_ver = nil, nil
local nodes = {}      -- "sid:uid" → the tower's live node
local guard_owners = {}

-- The tower's ground point and antenna in its body's frame (pure given ST).
local function tower_pose(ST, rec, p, def)
  local gx, gy, gz, U = ST.partPose(rec, p, 0)
  local m = (def and def.tower and def.tower.mast) or 11.6
  return gx, gy, gz, gx + U.x * m, gy + U.y * m, gz + U.z * m, U
end

-- M8: a dig guard under every structure part, from under its footing to over
-- its roof, half a metre wider than its footprint. One owner a structure.
local function sync_guards(ST, pb)
  local bf = ref("base_facilities")
  if not (bf and bf.setGuards and ST.list) then return end
  local seen = {}
  for _, rec in ipairs(ST.list()) do
    local list = {}
    for _, p in ipairs(rec.bp) do
      local def = pb and pb.partInfo(p.id)
      if def and def.half then
        local gx, gy, gz, U, F = ST.partPose(rec, p, 0)
        local R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }
        local dn = ((p.ft and p.ft.d) or 0) + 2.0
        list[#list + 1] = { c = { x = gx, y = gy, z = gz }, t = R, up = U, n = F, ht = def.half.x + 0.5, hn = def.half.z + 0.5,
                            lo = -dn, hi = (def.h or 2) + 1.0,
                            why = "The " .. tostring(def.label) .. "'s foundations — can't dig here" }
      end
    end
    local owner = "struct:" .. tostring(rec.id)
    seen[owner] = true
    pcall(bf.setGuards, owner, rec.b, list)
  end
  for owner in pairs(guard_owners) do
    if not seen[owner] then pcall(bf.setGuards, owner, nil) end
  end
  guard_owners = seen
end
guardOwners = function() return guard_owners end   -- (probes, tests)

local just_founded = nil
-- Every tower part a base, every base a tower: run when the structures (or
-- the bases) changed. Idempotent.
function reconcile()
  local ST, B, pb = ref("structures"), ref("bases"), parts()
  if not (ST and B and pb and ST.list) then return 0 end
  local def = towerDef()
  local seen, n = {}, 0
  local fb = ref("field_builder")
  local lp = fb and fb.lastPlace
  for _, rec in ipairs(ST.list()) do
    for _, p in ipairs(rec.bp) do
      if p.id == "tower" then
        local gx, gy, gz, ax, ay, az, U = tower_pose(ST, rec, p, def)
        local r = p.base and B.get(p.base) or nil
        if r and (r.sid ~= rec.id or r.uid ~= p.uid) then r = nil end   -- (a copy: found its own)
        -- (a placement's redo puts back a copy taken before its base was
        -- founded: the base still standing down at that spot is its own)
        if not r and not p.base then r = B.byTower(rec.id, p.uid) end
        if r and p.base ~= r.id then p.base = r.id; ST.put(rec) end
        if r and r.down then B.setDown(r.id, false, gx, gy, gz) end
        if not r then
          local dp = ref("deployables")
          local t = agency_now()
          local bid = B.found(rec.b, gx, gy, gz, rec.id, p.uid, { t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, by = p.paid and p.paid.by or rec.by })
          p.base = bid
          ST.put(rec)
          r = B.get(bid)
          log(string.format("tower: %s founded on %s (structure %s)", r.n, tostring(rec.b), tostring(rec.id)))
          -- the player just placed it: the name field opens
          if lp and lp.sid == rec.id and lp.uid == p.uid then just_founded = bid end
        end
        tw[r.id] = { sid = rec.id, uid = p.uid, b = rec.b, gx = gx, gy = gy, gz = gz, ax = ax, ay = ay, az = az,
                     ux = U.x, uy = U.y, uz = U.z }
        seen[r.id] = true
        n = n + 1
      end
    end
  end
  for _, r in ipairs(B.list()) do
    if not seen[r.id] then B.setDown(r.id, true); tw[r.id] = nil end
  end
  for id in pairs(tw) do if not seen[id] then tw[id] = nil end end
  sync_guards(ST, pb)
  st_ver, bs_ver = ST.version, B.version
  return n
end

function towerOf(bid) return tw[bid] end

-- ── power: the base grid (M6, step 8; base_grid.lua) ────────────────────────
-- The tower of base `bid` on its grid: { supply, need, draw, powered, stored,
-- cap, grid, src, … } (base_grid.towerPower). The grid is solved on change
-- and every couple of seconds; this only reads its answer. (`bodies` and
-- `force` are kept for the old callers: a force advances the grid now.)
function power(bid, bodies, force)
  local G = ref("base_grid")
  if not (G and G.towerPower) then
    local def = towerDef()
    local need = (def and def.tower and def.tower.draw) or 2.0
    return { supply = 0, need = need, draw = need, powered = false, stored = 0, cap = 0, src = {} }
  end
  if force then
    if G.markDirty then G.markDirty() end
    if G.rebuildNow then G.rebuildNow() end
  end
  return G.towerPower(bid)
end

-- One line for a tower's grid (the menu, the station's card):
-- "battery 1,840 / 4,000 EC (46 %) · 3 structures · 1 cable"
local function thousands(v)
  local s = string.format("%d", math.floor((v or 0) + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end
function gridLine(pw)
  local bits = {}
  if (pw.cap or 0) > 0 then
    bits[#bits + 1] = string.format("battery %s / %s EC (%d %%)", thousands(pw.stored), thousands(pw.cap),
      math.floor((pw.stored or 0) / pw.cap * 100 + 0.5))
  else
    bits[#bits + 1] = "no storage"
  end
  if pw.structures then bits[#bits + 1] = string.format("%d structure%s", pw.structures, pw.structures == 1 and "" or "s") end
  if (pw.cables or 0) > 0 then bits[#bits + 1] = string.format("%d cable%s", pw.cables, pw.cables == 1 and "" or "s") end
  if (pw.towers or 0) > 1 then bits[#bits + 1] = string.format("%d towers", pw.towers) end
  return table.concat(bits, " · ")
end

-- ── the relay (comms.solve calls this every solve) ──────────────────────────
-- `by` = the solve's one read of the bodies, by name; `bodies` the list.
-- Nodes in solveNetwork's shape, pinned to their world (frame, rx..rz).
function commsNodes(by, bodies, E)
  E = E or ref("electronics")
  if not E then return {} end
  local ST, B = ref("structures"), ref("bases")
  if ST and B and (ST.version ~= st_ver or B.version ~= bs_ver) then reconcile() end
  local out = {}
  local home = home_body()
  local def = towerDef()
  local mast = (def and def.tower and def.tower.mast) or 11.6
  local ids = {}
  for id in pairs(tw) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local T = tw[id]
    local b = by[T.b]
    local r = B and B.get(id)
    if b and r then
      local x, y, z = b.x + T.ax, b.y + T.ay, b.z + T.az
      local pw = power(id, bodies)
      local nd
      if pw.powered and T.b == home then
        nd = { id = "t:" .. tostring(id), name = r.n, x = x, y = y, z = z, home = true, power = E.COMMS.station,
               agl = mast, tower = true, base = id, body = T.b }
      elseif pw.powered then
        nd = { id = "t:" .. tostring(id), name = r.n, x = x, y = y, z = z, any = E.COMMS.station, relay = E.COMMS.station,
               rate = 2, agl = mast, tower = true, landed = true, base = id, body = T.b }
      else
        nd = E.beaconNode("t:" .. tostring(id), r.n, x, y, z)
        nd.agl, nd.tower, nd.base, nd.body = mast, true, id, T.b
      end
      nd.powered = pw.powered
      nd.frame, nd.rx, nd.ry, nd.rz = T.b, T.ax, T.ay, T.az
      out[#out + 1] = nd
    end
  end
  return out
end

-- ── the list for the map and the station (M5: the `bases()` hook) ───────────
-- { { id, name, home, body, x, y, z (antenna, world now), gx, gy, gz (ground,
--     world now), tier ("ground station" | "mast"), powered, supply, need,
--     linked, strength, hops, via, coverage (its world's ground share),
--     structures (n within 150 m, unless opts.brief), founded, by } }
function bases(opts)
  opts = opts or {}
  local out = {}
  local B, net, ST, bf = ref("bases"), ref("comms"), ref("structures"), ref("base_facilities")
  local cov = {}
  local function cov_of(body)
    if cov[body] == nil then
      local c = net and net.coverage and net.coverage(body)
      cov[body] = c and c.ground or false
    end
    return cov[body] or nil
  end
  local function count_near(body, x, y, z)
    if opts.brief or not (ST and ST.partsNear and B) then return nil end
    local seen, n = {}, 0
    for _, e in ipairs(ST.partsNear(body, x, y, z, B.RADIUS or 150)) do
      if not seen[e.rec.id] then seen[e.rec.id] = true; n = n + 1 end
    end
    return n
  end
  -- (step 8) the crew at each base: on foot within its radius (their records'
  -- body-relative points), or at the spaceport for the home base
  local roster = nil
  local function crew_at(body, x, y, z, home)
    local cl = ref("crew")
    if not (cl and cl.roster) then return nil end
    roster = roster or cl.roster()
    local n, R = 0, (B and B.RADIUS) or 150
    for _, c in ipairs(roster) do
      if home and c.status == "base" then n = n + 1
      elseif c.status == "afoot" then
        -- (a member in the scene: where their body is now, against this
        -- read of their world; otherwise the record's body-relative point)
        local cx, cy, cz, cb = tonumber(c.x), tonumber(c.y), tonumber(c.z), c.body
        local nb = cl.bodyOf and cl.bodyOf(c.id)
        if nb and nb.valid ~= false and space and space.dominant then
          cb = space.dominant(nb.x, nb.y, nb.z)
          local w = cb and space.body(cb)
          if w then cx, cy, cz = nb.x - w.x, nb.y - w.y, nb.z - w.z end
        end
        if cb == body and cx and cy and cz and math.sqrt((cx - x) ^ 2 + (cy - y) ^ 2 + (cz - z) ^ 2) <= R then n = n + 1 end
      end
    end
    return n
  end
  if bf and bf.baseBody and net and net.station then
    local sx, sy, sz = net.station()
    local b = space.body(bf.baseBody)
    if sx and b then
      local em = ref("emblem")
      local an = em and em.name and em.name() or nil
      out[#out + 1] = { id = 0, home = true, name = (an and an ~= "") and (an .. " Spaceport") or "The Spaceport", body = bf.baseBody,
                        x = sx, y = sy, z = sz, gx = sx, gy = sy, gz = sz, tier = "ground station", powered = true,
                        linked = true, strength = 1, hops = 0, coverage = cov_of(bf.baseBody),
                        structures = count_near(bf.baseBody, sx - b.x, sy - b.y, sz - b.z),
                        crew = crew_at(bf.baseBody, sx - b.x, sy - b.y, sz - b.z, true) }
    end
  end
  if B then
    if ST and (ST.version ~= st_ver or B.version ~= bs_ver) then reconcile() end
    for _, r in ipairs(B.list()) do
      local T = tw[r.id]
      local b = T and space.body(r.b)
      if b then
        local pw = power(r.id)
        local s = net and net.statusOf and net.statusOf("t:" .. tostring(r.id)) or nil
        out[#out + 1] = { id = r.id, name = r.n, body = r.b, x = b.x + T.ax, y = b.y + T.ay, z = b.z + T.az,
                          gx = b.x + T.gx, gy = b.y + T.gy, gz = b.z + T.gz, ux = T.ux, uy = T.uy, uz = T.uz,
                          tier = pw.powered and "ground station" or "mast", powered = pw.powered, supply = pw.supply,
                          need = pw.need, src = pw.src, linked = (s and s.connected) or false, strength = s and s.strength or 0,
                          hops = s and s.hops or 0, via = s and s.names or nil, why = s and s.why or nil,
                          coverage = cov_of(r.b), structures = count_near(r.b, T.gx, T.gy, T.gz),
                          founded = r.d, by = r.by, sid = T.sid, uid = T.uid,
                          -- (step 8, M6: its grid)
                          grid = pw.grid, draw = pw.draw, stored = pw.stored, cap = pw.cap, gridStructures = pw.structures,
                          cables = pw.cables, towers = pw.towers, solar = pw.solar, rtg = pw.rtg, short = pw.short,
                          gridLine = gridLine(pw), crew = crew_at(r.b, T.gx, T.gy, T.gz, false) }
      end
    end
  end
  return out
end

-- ── the rules for placing a tower (field_builder.validity asks) ─────────────
function placeWhy(id, def, p)
  if not (def and def.tower) then return nil end
  local B = ref("bases")
  if not (B and p and p.body) then return nil end
  local home = nil
  local net, bf = ref("comms"), ref("base_facilities")
  if net and net.station and bf and bf.baseBody then
    local sx, sy, sz = net.station()
    local b = space.body(bf.baseBody)
    if sx and b then home = { b = bf.baseBody, x = sx - b.x, y = sy - b.y, z = sz - b.z } end
  end
  return B.spacingWhy(p.body, p.x, p.y, p.z, radiusOf(p.body), home)
end

-- ── structures' hooks ───────────────────────────────────────────────────────
function spawned(rec, p, inst) nodes[tostring(rec.id) .. ":" .. tostring(p.uid)] = inst end
function gone(sid, uid) nodes[tostring(sid) .. ":" .. tostring(uid)] = nil end
function canRemove(rec, p) return true end
function nodeOfBase(bid)
  local T = tw[bid]
  local n = T and nodes[tostring(T.sid) .. ":" .. tostring(T.uid)]
  return (n and n.valid ~= false) and n or nil
end

-- ── the name field (M1: "on placement a name field opens") ──────────────────
local pr = { node = nil, making = false, focused = false }
function prompting() return prompt ~= nil end
local function close_prompt()
  prompt = nil
  if pr.node and pr.node.valid ~= false then pr.node:destroy() end
  pr.node, pr.focused = nil, false
end
function openName(bid)
  local B = ref("bases")
  local r = B and B.get(bid)
  if not r then return false end
  prompt = { bid = bid, text = "", t = now(), was = r.n }
  pr.focused = false
  return true
end
function commitName(s)
  if not prompt then return false, "no name field open" end
  local B = ref("bases")
  local bid = prompt.bid
  local text = s
  if text == nil then text = prompt.text end
  local ok, w = true, nil
  if B and type(text) == "string" and text:match("%S") then ok, w = B.rename(bid, text) end
  if not ok then say(w); return false, w end
  local r = B and B.get(bid)
  close_prompt()
  local net = ref("comms")
  if net and net.refreshNow then pcall(net.refreshNow) end
  say(string.format("%s founded · its tower is %s", r and r.n or "the base",
    (power(bid, nil, true).powered and "a ground station") or "a mast until its grid has 2 EC/s"))
  return true, r and r.n
end
function cancelName() if prompt then return commitName("") end return false end

local function hud() return find and find("Ship HUD") or nil end
local function prompt_tree()
  local B = ref("bases")
  local r = B and B.get(prompt.bid)
  local where = r and r.b or "?"
  local line = "Base Station Tower on " .. tostring(where)
  local pw = power(prompt.bid)
  local tier = pw.powered and string.format("a ground station (%.1f EC/s on its grid)", pw.supply)
    or string.format("a mast until its grid has %.0f EC/s: a Solar Array or an Isotope Skid within 150 m, a Battery Bank for the night", pw.draw or pw.need)
  local function submit(n)
    local ok, w = commitName((n and n.text) or prompt.text)
    if not ok and w then prompt.err = w end
  end
  return { "col", key = "bn", style = "panel/frame", w = 420, h = "fit", dir = "col", gap = 8, pad = 16, align = "start",
    { "text", key = "h", style = "panel/heading", w = "100%", h = "fit", text = "Name the base" },
    { "text", key = "w", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = line .. "  ·  every structure within 150 m belongs to it" },
    { "field", key = "f", name = "FieldBaseName", style = "menu/field", w = "100%", h = 32, maxLen = (B and B.NAME_MAX) or 32,
      placeholder = r and r.n or "Outpost", onChanged = function(n) prompt.text = n.text or "" end, onSubmitted = submit },
    { "text", key = "t", style = prompt.err and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit", wrap = true,
      text = prompt.err or ("Its tower is " .. tier .. ".") },
    { "row", key = "b", w = "100%", h = 32, gap = 8, pad = 0, align = "center",
      { "button", key = "ok", style = "panel/action", w = "grow", h = 32, text = "Found it", textAlign = "center",
        textValign = "center", onClicked = function() submit(nil) end },
      { "button", key = "no", style = "panel/secondary", w = 150, h = 32, textAlign = "center", textValign = "center",
        text = "Keep " .. (r and r.n or "the name"), onClicked = function() commitName("") end } } }
end
local function prompt_tick()
  if not prompt then
    if pr.node then close_prompt() end
    return
  end
  if input and input.setMouseLocked then input.setMouseLocked(false) end
  if input and input.pressed and input.pressed("escape") then
    escTakenAt = now()
    commitName("")
    return
  end
  if not (pr.node and pr.node.valid ~= false) then
    if pr.making or not spawn then return end
    local h = hud()
    if not h then return end
    pr.making = true
    pcall(spawn, "BaseNamePrompt", vec3(0, 0, 0), function(n)
      pr.making = false
      if not prompt then n:destroy() return end
      pr.node = n
    end, h)
    return
  end
  if ui and ui.make then ui.make(pr.node, { prompt_tree() }) end
  if not pr.focused and ui and ui.focus and find then
    local f = find("FieldBaseName")
    if f then ui.focus(f); pr.focused = true end
  end
end

-- ── the context menu on a tower (rename, power, link) ───────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, B = ref("structures"), ref("bases")
  if not (ST and ST.partOfNode and B) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not (part and part.id == "tower") then return {} end
  local r = part.base and B.get(part.base)
  if not r then return {} end
  local bid = r.id
  return {
    { id = "bt_name", type = "info", label = "Base", group = "Tower", value = function()
        local rr = B.get(bid); return rr and rr.n or "?" end },
    { id = "bt_power", type = "info", label = "Power", group = "Tower", value = function()
        local pw = power(bid)
        return string.format("%.1f / %.1f EC/s · %s", pw.supply, pw.need, pw.powered and "ground station" or "mast")
      end },
    { id = "bt_grid", type = "info", label = "Grid", group = "Tower", value = function() return gridLine(power(bid)) end },
    { id = "bt_link", type = "info", label = "Link", group = "Tower", value = function()
        local net = ref("comms")
        local s = net and net.statusOf and net.statusOf("t:" .. tostring(bid))
        if not s then return "—" end
        if s.connected and s.hops == 0 then return "a ground station: the network's root here" end
        if s.connected then return string.format("home via %s (%.0f%%)", table.concat(s.names or {}, " → "), (s.strength or 0) * 100) end
        return s.why or "no path home"
      end },
    { id = "bt_rename", type = "action", label = "Rename the base", group = "Tower", hint = "✎",
      act = function() openName(bid); return true end },
  }, "Base Station Tower"
end
providerFn = provider
local provider_on, provider_t = false, -10
local function register_provider()
  if provider_on or now() - provider_t < 1.0 then return end
  provider_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", provider, { id = "base_tower", order = 4 })
    provider_on = true
  end
end

function start(node)
  if findScripts then
    local all = findScripts("base_tower")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  tw, nodes, guard_owners = {}, {}, {}
  st_ver, bs_ver, prompt = nil, nil, nil
end

function update(node, dt)
  register_provider()
  local ST, B = ref("structures"), ref("bases")
  if ST and B and (ST.version ~= st_ver or B.version ~= bs_ver) then
    reconcile()
  end
  if just_founded then
    local bid = just_founded
    just_founded = nil
    openName(bid)
    local net = ref("comms")
    if net and net.refreshNow then pcall(net.refreshNow) end
  end
  if prompt or pr.node then prompt_tick() end
end
