-- BASE_HUB — the full freecam builder for a base (playtest 11-09: "when you
-- place a build station … you can maybe actually have a main base hub …
-- separate to stands used for making crafts … what you interact with to go
-- full build mode for your actual base. but id like to be able to still use
-- any of the ship or strut parts … full access builder").
--
-- On the Build Kit node (scenes/system.ron). The records half is pure (it
-- loads in a luajit test: tests/smoke_fullbuild.lua); the scene half is the
-- hub part's menu.
--
--   THE HUB     a BASE part (parts_base `baseHub`, prefab BaseHub: a site
--               operations console on a skid), placed with the Build Kit like
--               any other. Its menu's "Build the base" opens the VAB overlay
--               (build_host.enter{ hub = { sid, uid } }) anchored to the
--               hub's STRUCTURE: the BuildFrame is the structure's own frame
--               (+X right, +Y up, +Z front, its floor at the structure's
--               ground plane), so a builder coordinate IS a structure
--               coordinate. Stands keep building crafts; the hub builds the
--               base.
--   EVERY PART  the builder's catalogue gains, at a stand or a hub, every
--               BASE part and every kit piece in every material it comes in,
--               one section per kit category (parts_kit.catalogue's own
--               sections, so a new category — S8's logic — follows without a
--               change here); a title the VAB already uses (FRAME, NUCLEAR) is
--               "BASE <title>". `register(REG, CATALOGUE)` is the
--               parts_registry.extend provider (kind "base_hub"). A base
--               piece's builder entry carries `base = true`, its structure id
--               and `npiv`: where the prefab's root (its ground point, plus a
--               BASE part's seat) sits from the box centre the builder works
--               in, so the builder draws the prefab where the box is.
--   IN AND OUT  `toBuilder(rec)` is the structure as a launch-format
--               blueprint (frame coordinates, its uids kept); `fromBuilder`
--               turns the builder's parts back into structure entries: a base
--               piece at its ground point, any VAB part (struts, engines,
--               cockpits, robotics) a LIVE part "vab.<id>" whose full
--               launch-format record is kept beside the structure
--               (`slivebp.<sid>`, struct_live builds the anchored structure
--               vessel from it: S2's rule) and whose figures are learned once
--               (`vabdefs`, parts_kit.learnVab) for the world that carries no
--               registry.
--   COMMIT      `diff` + `quote` + `commit`: parts added are charged once, with
--               one truck (base_economy.shipping); parts taken off come back by
--               the deconstruct rule (their own `paid`); moved parts are free.
--               The hub itself never moves or goes; a part whose script refuses
--               removal (a stand holding a craft) stays.
--
-- COST: nothing a tick. The menu provider registers once.
--
-- Probes: register, builderDef(id), toBuilder(rec), fromBuilder(list),
-- diff(rec, entries, hubUid), quote(rec, d, now), commit(sid, entries, opts),
-- lastCommit.

-- (parts_registry.extend keys a provider by its handle's own `kind`, "base_hub")
HUB = "baseHub"
lastCommit = nil

local refs = {}
local function ref(k)
  local r = refs[k]
  if not r or r.valid == false then r = findScript and findScript(k) or nil; refs[k] = r end
  return r
end
local function now() return time or 0 end
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

-- ── rotations (the engine's YXZ order: the builder's rot_basis) ─────────────
local function basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
         { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
         { x = sy * cx, y = -sx, z = cy * cx }
end
function rot(yaw, pitch, roll, v)
  local X, Y, Z = basis(yaw, pitch, roll)
  return X.x * v.x + Y.x * v.y + Z.x * v.z, X.y * v.x + Y.y * v.y + Z.y * v.z, X.z * v.x + Y.z * v.y + Z.z * v.z
end

-- ── THE CATALOGUE (parts_registry.extend provider) ──────────────────────────
local function PB() return ref("parts_base") end
local function KIT() return ref("parts_kit") end
local function KS() return ref("kit_snap") end
local function box_of(d)
  if d.box then return d.box end
  local K = KS()
  if K and K.boxOf then return K.boxOf(d) end
  local h = d.half or { x = 0.5, y = 0.5, z = 0.5 }
  return { -h.x, h.x, 0, 2 * h.y, -h.z, h.z }
end
local bdefs = {}
-- The builder's registry entry for the structure part `id` (a BASE part or a
-- kit piece "<piece>.<mat>"), or nil (a live fitting, a cable run).
function builderDef(id)
  local c = bdefs[id]
  if c ~= nil then return c or nil end
  local pb = PB()
  local d = pb and pb.partInfo(id)
  if not d or d.live or d.cable or not d.prefab then bdefs[id] = false return nil end
  local b = box_of(d)
  local cx, cy, cz = (b[1] + b[2]) / 2, (b[3] + b[4]) / 2, (b[5] + b[6]) / 2
  local seat = d.seat or 0
  local label = d.label or id
  local K = KIT()
  if d.kit and d.piece and K and K.PIECES and K.PIECES[d.piece] and #K.PIECES[d.piece].mats > 1 and d.matLabel then
    label = label .. " · " .. d.matLabel
  end
  local e = {
    prefab = d.prefab, label = label, h = b[4] - b[3], rx = (b[2] - b[1]) / 2, rz = (b[6] - b[5]) / 2,
    mass = d.mass or 0.1, cost = d.cost or 0, kind = "structural", strength = 600, maxq = 80,
    base = true, baseId = id, seat = seat, npiv = { x = -cx, y = seat - cy, z = -cz },
    tech = d.tech, desc = d.desc, film = d.film, kitSnap = d.kit == true or nil,
    top = false, bottom = false, side = false,
  }
  bdefs[id] = e
  return e
end

-- Add every BASE part and kit piece to the builder's REG and CATALOGUE.
function register(REG, CATALOGUE)
  local pb, K = PB(), KIT()
  if not pb then return 0 end
  local n = 0
  local taken = {}
  for _, sec in ipairs(CATALOGUE) do taken[sec[1]] = true end
  local function title(t) if taken[t] then return "BASE " .. t end return t end
  local function add(id)
    if REG[id] ~= nil then return REG[id].base == true end
    local e = builderDef(id)
    if not e then return false end
    REG[id] = e
    n = n + 1
    return true
  end
  -- the BASE section (the hub, the stand, the tower, the shed and hab …)
  for _, sec in ipairs(pb.catalogue and pb.catalogue() or {}) do
    local ids = {}
    for _, id in ipairs(sec.ids or {}) do if add(id) then ids[#ids + 1] = id end end
    if #ids > 0 then CATALOGUE[#CATALOGUE + 1] = { title(sec.title or "BASE"), ids } end
  end
  -- the kit: its own sections (its categories), each piece in every material
  if K and K.catalogue then
    for _, sec in ipairs(K.catalogue("steel")) do
      local ids = {}
      for _, id0 in ipairs(sec.ids) do
        local piece = K.split and K.split(id0)
        local P = piece and K.PIECES and K.PIECES[piece]
        if P then
          for _, m in ipairs(P.mats) do
            local id = K.idOf(piece, m)
            if add(id) then ids[#ids + 1] = id end
          end
        end
      end
      if #ids > 0 then CATALOGUE[#CATALOGUE + 1] = { title(sec.title), ids } end
    end
    -- (hidden pieces — the Door Wall's mirrored twin — load, but aren't listed)
    for piece, P in pairs(K.PIECES or {}) do
      if P.hidden then for _, m in ipairs(P.mats) do add(K.idOf(piece, m)) end end
    end
  end
  return n
end

-- ── IN: a structure → the builder's blueprint (frame coordinates) ───────────
local function lps_of(sid)
  local t = save and save.get and save.get("slivebp." .. tostring(sid))
  return type(t) == "table" and t or {}
end
lpsOf = lps_of

-- → bp { parts = { launch-format records, x, y, z = the box centre }, v = 2, name }
function toBuilder(rec, lps)
  lps = lps or lps_of(rec.id)
  local pb = PB()
  local out = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = pb and pb.partInfo(p.id)
    if d and d.live then
      local lp = lps[tostring(p.uid)]
      local r = type(lp) == "table" and copy(lp) or { id = d.vab, prefab = d.prefab, label = d.label, h = d.h,
        mass = d.mass, cost = d.cost, kind = d.kind, rx = d.rx, rz = d.rz }
      r.id = r.id or d.vab
      r.uid = p.uid
      r.x, r.y, r.z = p.x or 0, (p.y or 0) + (d.seat or 0), p.z or 0
      r.yaw, r.pitch, r.roll = p.yaw or 0, p.pitch or 0, p.roll or 0
      r.parent, r.att, r.sym, r.stage = 0, "", 0, r.stage or 0
      out[#out + 1] = r
    else
      local e = builderDef(p.id)
      if e then
        -- the ground point G, the prefab's root N = G + seat (the structure's up),
        -- the box centre C = N − R·npiv
        local nx, ny, nz = p.x or 0, (p.y or 0) + e.seat, p.z or 0
        local vx, vy, vz = rot(p.yaw, p.pitch, p.roll, e.npiv)
        out[#out + 1] = { uid = p.uid, id = p.id, prefab = e.prefab, label = e.label, h = e.h, mass = e.mass, cost = e.cost,
          kind = e.kind, rx = e.rx, rz = e.rz, x = nx - vx, y = ny - vy, z = nz - vz, yaw = p.yaw or 0, pitch = p.pitch or 0,
          roll = p.roll or 0, parent = 0, att = "", sym = 0, stage = 0 }
      end
    end
  end
  return { parts = out, v = 2, name = rec.n or "Base" }
end

-- ── OUT: the builder's parts → structure entries ────────────────────────────
-- list = { { uid, id (the builder's), x, y, z (box centre, frame), yaw, pitch,
-- roll, lp = its launch-format record (VAB parts) } } ; REG = id → builder def
-- (nil: builderDef / parts_kit). → { { uid, id, x, y, z, yaw, pitch, roll,
-- cost, lp, base = bool } }
function fromBuilder(list, REG)
  local K = KIT()
  local out = {}
  for _, b in ipairs(list or {}) do
    local e = (REG and REG[b.id]) or builderDef(b.id)
    local yaw, pitch, roll = b.yaw or 0, b.pitch or 0, b.roll or 0
    if e and e.base then
      local vx, vy, vz = rot(yaw, pitch, roll, e.npiv)
      out[#out + 1] = { uid = b.uid, id = e.baseId or b.id, x = b.x + vx, y = b.y + vy - (e.seat or 0), z = b.z + vz,
        yaw = yaw, pitch = pitch, roll = roll, cost = e.cost or 0, base = true }
    else
      local sid = "vab." .. tostring(b.id)
      local seat = 0
      local ld = K and K.LIVE and K.LIVE[b.id] and K.partInfo and K.partInfo(sid)
      if ld then seat = ld.seat or 0 end
      local lp = copy(b.lp or {})
      for _, k in ipairs({ "x", "y", "z", "yaw", "pitch", "roll", "uid", "parent", "att", "sym", "stage" }) do lp[k] = nil end
      lp.id = b.id
      out[#out + 1] = { uid = b.uid, id = sid, x = b.x, y = b.y - seat, z = b.z, yaw = yaw, pitch = pitch, roll = roll,
        cost = (b.lp and b.lp.cost) or (e and e.cost) or 0, lp = lp }
    end
  end
  return out
end

-- ── THE DIFF ────────────────────────────────────────────────────────────────
local function moved(p, e)
  local function df(a, b) return math.abs((a or 0) - (b or 0)) > 1e-4 end
  return df(p.x, e.x) or df(p.y, e.y) or df(p.z, e.z) or df(p.yaw, e.yaw) or df(p.pitch, e.pitch) or df(p.roll, e.roll)
end
-- What may not go (the hub; a part whose script says no). → why | nil
function keepWhy(rec, p, hubUid)
  if p.uid == hubUid then return "the hub stays where it stands" end
  local pb = PB()
  local d = pb and pb.partInfo(p.id)
  local sc = d and d.script and ref(d.script)
  if sc and sc.canRemove then
    local ok, can, why = pcall(sc.canRemove, rec, p)
    if ok and can == false then return why or ("the " .. tostring(d.label) .. " can't come down now") end
  end
  return nil
end
-- → { add = { entry }, move = { { part, entry } }, remove = { uid }, kept = { why }, same = n }
function diff(rec, entries, hubUid)
  local by = {}
  for _, e in ipairs(entries) do if e.uid then by[e.uid] = e end end
  local out = { add = {}, move = {}, remove = {}, kept = {}, same = 0 }
  local seen = {}
  for _, p in ipairs(rec.bp or {}) do
    local e = by[p.uid]
    seen[p.uid] = true
    if e and e.id == p.id then
      if moved(p, e) then
        local why = keepWhy(rec, p, hubUid)
        if why then out.kept[#out.kept + 1] = why else out.move[#out.move + 1] = { part = p, entry = e } end
      else
        out.same = out.same + 1
      end
    else
      local why = keepWhy(rec, p, hubUid)
      if why then out.kept[#out.kept + 1] = why
      else out.remove[#out.remove + 1] = p.uid end
      if e then out.add[#out.add + 1] = e end   -- (the same uid, another part: off and on again)
    end
  end
  for _, e in ipairs(entries) do
    if not e.uid or not seen[e.uid] then out.add[#out.add + 1] = e end
  end
  return out
end

-- What the diff costs at agency time `now`: the parts added once with one
-- truck; the parts taken off back by the deconstruct rule. → q { added, ship,
-- refund, total, n_add, n_rem, n_move }
function quote(rec, d, nowT)
  local E = ref("base_economy")
  local added = 0
  for _, e in ipairs(d.add) do added = added + math.floor(e.cost or 0) end
  local ship = 0
  if added > 0 then ship = (E and E.shipping) and E.shipping(added) or math.floor(added * 0.1 + 50.5) end
  local refund = 0
  local gone = {}
  for _, u in ipairs(d.remove) do gone[u] = true end
  for _, p in ipairs(rec.bp or {}) do
    if gone[p.uid] then
      local r = (E and E.deconstructRefund) and E.deconstructRefund(p.paid, nowT) or math.floor((p.paid and p.paid.cost) or 0)
      refund = refund + r
    end
  end
  return { added = added, ship = ship, refund = refund, total = added + ship - refund, n_add = #d.add, n_rem = #d.remove,
           n_move = #d.move, kept = #d.kept }
end

-- Apply the builder's parts to structure `sid`. opts = { hubUid, by, payer =
-- "money" | "free", t } → ok, why, q
function commit(sid, entries, opts)
  opts = opts or {}
  local ST, co, E = ref("structures"), ref("company"), ref("base_economy")
  local rec = ST and ST.get(sid)
  if not rec then return false, "the base is gone" end
  local d = diff(rec, entries, opts.hubUid)
  local t = opts.t or now()
  local q = quote(rec, d, t)
  if opts.payer ~= "free" and co then
    if q.total > 0 then
      local why = string.format("base built from its hub · %s of parts + %s shipping%s", E and E.money(q.added) or q.added,
        E and E.money(q.ship) or q.ship, q.refund > 0 and (" − " .. (E and E.money(q.refund) or q.refund) .. " taken off") or "")
      if not (co.spend and co.spend(q.total, why)) then
        -- (nothing added: what was taken off and moved still stands as the builder left it)
        d.add = {}
        q = quote(rec, d, t)
        q.unpaid = true
      end
    end
    if q.total < 0 then
      local why = string.format("base built from its hub · %s of parts taken off", E and E.money(q.refund) or q.refund)
      if co.refund then co.refund(-q.total, why) elseif co.earn then co.earn(-q.total, why) end
    end
  end
  local lps = lps_of(sid)
  -- taken off
  if #d.remove > 0 then
    ST.removeParts(sid, d.remove)
    for _, u in ipairs(d.remove) do lps[tostring(u)] = nil end
  end
  rec = ST.get(sid)
  if not rec then return true, nil, q end
  -- moved
  for _, m in ipairs(d.move) do
    local p, e = m.part, m.entry
    -- (a piece lifted off the ground it was set on is no longer held by it)
    if math.abs((p.y or 0) - (e.y or 0)) > 1e-4 then p.gnd = nil end
    p.x, p.y, p.z, p.yaw, p.pitch, p.roll = e.x, e.y, e.z, e.yaw, e.pitch, e.roll
    if e.lp then lps[tostring(p.uid)] = e.lp; p.lpv = (p.lpv or 0) + 1 end
  end
  -- the VAB parts' records stay current (a moved part's size, its settings)
  for _, e in ipairs(entries) do if e.lp and e.uid and lps[tostring(e.uid)] then lps[tostring(e.uid)] = e.lp end end
  if #d.move > 0 then ST.put(rec) end
  -- added: each carries its share of the one bill
  local share = q.added > 0 and q.ship / q.added or 0
  local levels = {}
  local K = KIT()
  for _, e in ipairs(d.add) do
    local cost = math.floor(e.cost or 0)
    local ship = math.floor(cost * share + 0.5)
    local entry = { uid = e.uid, id = e.id, x = e.x, y = e.y, z = e.z, yaw = e.yaw, pitch = e.pitch, roll = e.roll,
                    paid = { cost = cost, ship = ship, foot = 0, total = cost + ship, t = t, supplier = "Halden Structural", by = opts.by } }
    if e.lp then
      if K and K.learnVab then K.learnVab(e.lp.id, e.lp) end
      entry.lpv = 1
    end
    -- (a base piece set at the structure's ground plane stands on the ground:
    -- held by it, the terrain levelled under it as the Build Kit does)
    local pb = PB()
    local d = e.base and pb and pb.partInfo(e.id)
    local b0 = d and box_of(d)
    local onGround = d and b0 and d.snap ~= "mount" and not d.film and math.abs((e.y or 0) + b0[3]) <= 0.25 and math.abs(e.pitch or 0) < 1e-3
    if onGround then entry.gnd = true end
    local uid = ST.addPart(sid, entry)
    if e.lp and uid then lps[tostring(uid)] = e.lp end
    if onGround and uid then levels[#levels + 1] = uid end
  end
  local fb = ref("field_builder")
  if fb and fb.levelPart then for _, u in ipairs(levels) do pcall(fb.levelPart, sid, u) end end
  if save and save.set then
    save.set("slivebp." .. tostring(sid), lps)
    if K and K.vabDefs then save.set("vabdefs", K.vabDefs()) end
  end
  lastCommit = { sid = sid, q = q, add = #d.add, move = #d.move, remove = #d.remove, kept = d.kept, t = t }
  return true, nil, q
end

-- ── THE SCENE: the hub's menu ───────────────────────────────────────────────
local nodes = {}
function spawned(rec, p, inst) nodes[tostring(rec.id) .. ":" .. tostring(p.uid)] = inst end
function gone(sid, uid) nodes[tostring(sid) .. ":" .. tostring(uid)] = nil end
function canRemove(rec, p)
  local bh = ref("build_host")
  local hs = bh and bh.hubState and bh.hubState()
  if hs and hs.sid == rec.id then return false, "the base builder is open on it" end
  return true
end
function nodeOf(sid, uid)
  local n = nodes[tostring(sid) .. ":" .. tostring(uid)]
  return (n and n.valid ~= false) and n or nil
end

local function engineer()
  local fb = ref("field_builder")
  return fb ~= nil and fb.isEngineer ~= nil and fb.isEngineer() == true
end
local function hub_rows(rec, part, ctx)
  local function toast(msg, bad) if ctx and ctx.toast then ctx.toast(msg, bad) end end
  local sid, uid = rec.id, part.uid
  return {
    { id = "hub_what", type = "info", label = "Base Hub", group = "Hub", value = function()
        local r = ref("structures") and ref("structures").get(sid)
        return string.format("%s · %d parts", tostring(r and r.n or "Structure"), r and #r.bp or 0)
      end },
    { id = "hub_build", type = "action", label = "Build the base", group = "Hub", hint = "▸",
      value = function() return "the full builder: every part, this base" end,
      enabled = function()
        local bh = ref("build_host")
        return engineer() and nodeOf(sid, uid) ~= nil and bh ~= nil and bh.enter ~= nil
      end,
      why = function()
        if not engineer() then return "Engineers only" end
        if not nodeOf(sid, uid) then return "walk closer" end
        return "the builder isn't in this scene"
      end,
      act = function()
        local fb = ref("field_builder")
        if fb and fb.isOpen and fb.isOpen() and fb.close then fb.close() end
        local bh = ref("build_host")
        local ok, w = bh.enter({ hub = { sid = sid, uid = uid } })
        if not ok then toast(tostring(w or "the builder wouldn't open here"), true) end
        return ok ~= false, w
      end },
  }
end
local function prop_provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not (rec and part and part.id == HUB) then return {} end
  return hub_rows(rec, part, ctx), "Base Hub"
end
providers = { prop = prop_provider }

local provider_on, provider_t = false, -10
function update(node, dt)
  if provider_on or now() - provider_t < 1.0 then return end
  provider_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", prop_provider, { id = "base_hub", order = 4 })
    provider_on = true
  end
end
