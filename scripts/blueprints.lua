-- BLUEPRINTS — a structure (or part of one) saved, shared and built again
-- (sandbox plan S4, work/sandbox/PLAN.md §1.4, §6; docs/base-building.md §15).
--
-- On the Build Kit node (scenes/system.ron) beside field_builder.lua. The
-- rules half is pure (it loads from disk in a luajit test,
-- tests/smoke_character.lua); the scene half keeps the library on disk, the
-- name/code prompt and dropped files.
--
-- ── A BLUEPRINT ─────────────────────────────────────────────────────────────
--   { v = 1, name, by, made (agency clock), n, mass, cost,
--     pieces = { { id, x, y, z, yaw, pitch, roll, paint, paintIn, text } … } }
-- Pieces are in the frame of the ANCHOR (the lowest piece, then the first
-- placed): it stands at the origin with yaw 0, and every other piece is turned
-- by the anchor's yaw into that frame, exactly as field_builder's clipboard is
-- (copyParts), so a blueprint is a saved Ctrl+C: Ctrl+V's composite ghost, its
-- turning (R, the wheel) and its snapping (the anchor snaps; the rest follow)
-- place it, with ONE bill and one step in the undo ring. Paint, a wall's inside
-- paint and a sign's words travel with the piece.
--
-- ── WHERE THEY LIVE ─────────────────────────────────────────────────────────
--   user://blueprints/<slug>.json       the blueprint (assets.writeJson): a file
--                                       the player can send, back up, edit
--   user://blueprints/<slug>.code.txt   its CODE, one line to paste anywhere
-- One library for every save (they are the player's, not a save's). A JSON or
-- code file dropped on the window joins it (filesDropped); a code pasted into
-- the BLUEPRINTS tab's import field does too. STOCK blueprints ship in this
-- script (STOCK): the kit's examples to place, open and change. The Shed and
-- the Hab stay one-click prefabs (Ty 11-06); the stock set stands beside them.
--
-- ── THE CODE ────────────────────────────────────────────────────────────────
--   SOLBP1.<payload>.<check>
-- payload = base64url (no padding) of a compact text: the name, the piece ids
-- once each, then one line a piece (centimetres, degrees, palette keys); check
-- = 4 base36 digits of an Adler-32 of the payload, so a code cut short or
-- mistyped in a chat is refused instead of building half a hab. Pure Lua (no
-- engine deflate) so luajit checks it; a 30-piece shed is ~1.5 kB.

V = 1
DIR = "user://blueprints"
PREFIX = "SOLBP1"
CODE_MAX = 16000
NAME_MAX = 40

-- ── pure: making one ────────────────────────────────────────────────────────
local function r2(v) return math.floor((v or 0) * 100 + 0.5) / 100 end
local function wrapA(a) a = (a + math.pi) % (2 * math.pi); return a - math.pi end

-- A blueprint from parts of structure `rec` (uids; nil = all of it). defs(id)
-- → def (only kit pieces travel). opts = { name, by, made, texts = fn(uid) → text }
-- → bp | nil, why
function fromParts(rec, uids, defs, opts)
  opts = opts or {}
  if not (rec and rec.bp) then return nil, "no structure" end
  local want = nil
  if uids then want = {} for _, u in ipairs(uids) do want[u] = true end end
  local list = {}
  for _, p in ipairs(rec.bp) do
    local d = defs(p.id)
    if d and d.kit and (not want or want[p.uid]) then list[#list + 1] = p end
  end
  if #list == 0 then return nil, "nothing of the kit to save" end
  table.sort(list, function(a, b)
    if math.abs((a.y or 0) - (b.y or 0)) > 0.05 then return (a.y or 0) < (b.y or 0) end
    return (a.uid or 0) < (b.uid or 0)
  end)
  local a = list[1]
  local c, s = math.cos(a.yaw or 0), math.sin(a.yaw or 0)
  local out, mass, cost = {}, 0, 0
  for _, p in ipairs(list) do
    local dx, dz = (p.x or 0) - (a.x or 0), (p.z or 0) - (a.z or 0)
    local e = { id = p.id, x = r2(dx * c - dz * s), y = r2((p.y or 0) - (a.y or 0)), z = r2(dx * s + dz * c),
                yaw = r2(wrapA((p.yaw or 0) - (a.yaw or 0))), pitch = r2(p.pitch or 0), roll = r2(p.roll or 0),
                paint = p.paint, paintIn = p.paintIn }
    if opts.texts then local t = opts.texts(p.uid); if type(t) == "string" and t ~= "" then e.text = t end end
    -- (playtest 11-09: a VAB part the Base Hub placed keeps its launch record
    -- in the file — a strut's size, an engine's figures — not in the code)
    if opts.lps then local lp = opts.lps[tostring(p.uid)]; if type(lp) == "table" then e.lp = lp end end
    out[#out + 1] = e
    local d = defs(p.id)
    mass = mass + (d.mass or 0)
    cost = cost + (d.cost or 0)
  end
  local name = tostring(opts.name or rec.n or "Blueprint"):sub(1, NAME_MAX)
  return { v = V, name = name, by = opts.by, made = opts.made, n = #out, mass = r2(mass), cost = math.floor(cost), pieces = out }
end

-- The clipboard field_builder pastes: { parts = { { id, dx, dy, dz, yaw,
-- pitch, roll, paint, paintIn, text } … }, n, label, bp }
function toClip(bp)
  local parts = {}
  for _, e in ipairs(bp.pieces or {}) do
    parts[#parts + 1] = { id = e.id, dx = e.x or 0, dy = e.y or 0, dz = e.z or 0, yaw = e.yaw or 0, pitch = e.pitch or 0, roll = e.roll or 0,
                          paint = e.paint, paintIn = e.paintIn, text = e.text, lp = e.lp }
  end
  return { parts = parts, n = #parts, label = bp.name, bp = bp }
end

-- ONE BILL (one delivery): the pieces' prices, shipping once on the sum
-- (base_economy: 10 % + $50). quote(id) → price | nil (no such piece / locked).
-- → { cost, ship, total, mass, n, missing = { id … } }
function bill(bp, priceOf, massOf, shipping)
  local cost, mass, n, miss, seen = 0, 0, 0, {}, {}
  for _, e in ipairs(bp.pieces or {}) do
    local c = priceOf(e.id)
    if c then
      cost = cost + c; n = n + 1
      mass = mass + ((massOf and massOf(e.id)) or 0)
    elseif not seen[e.id] then seen[e.id] = true; miss[#miss + 1] = e.id end
  end
  local ship = (n > 0 and shipping) and shipping(cost) or 0
  return { cost = cost, ship = ship, total = cost + ship, mass = mass, n = n, missing = miss }
end
-- A piece's share of the delivery (its `paid` record: an undo or a deconstruct
-- refunds it piece by piece, the shares summing to the bill).
function shareOf(b, cost)
  if not b or b.cost <= 0 then return 0 end
  return math.floor(b.ship * cost / b.cost + 0.5)
end

-- A file name for a blueprint name.
function slug(name)
  local s = tostring(name or "blueprint"):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then s = "blueprint" end
  return s:sub(1, 40)
end

-- ── pure: the code ──────────────────────────────────────────────────────────
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64I = {}
for i = 1, 64 do B64I[B64:sub(i, i)] = i - 1 end
function b64enc(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local k = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    local m = b == nil and 2 or (c == nil and 3 or 4)
    for j = 1, m do out[#out + 1] = B64:sub(k[j] + 1, k[j] + 1) end
  end
  return table.concat(out)
end
function b64dec(s)
  local out = {}
  local i = 1
  while i <= #s do
    local q = { s:byte(i, i + 3) }
    local v, m = 0, 0
    for j = 1, 4 do
      local ch = q[j] and string.char(q[j])
      local x = ch and B64I[ch]
      if q[j] and x == nil then return nil end
      v = v * 64 + (x or 0)
      if x then m = m + 1 end
    end
    if m < 2 then return nil end
    local a, b, c = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
    out[#out + 1] = string.char(a)
    if m >= 3 then out[#out + 1] = string.char(b) end
    if m >= 4 then out[#out + 1] = string.char(c) end
    i = i + 4
  end
  return table.concat(out)
end
function adler(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return b * 65536 + a
end
local function b36(n, w)
  local d, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
  for _ = 1, w do local k = n % 36; out = d:sub(k + 1, k + 1) .. out; n = math.floor(n / 36) end
  return out
end
local function esc(s) return (tostring(s):gsub("[%%|,;\n\r]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function deg(a) return math.floor(math.deg(a or 0) + 0.5) end
local function cm(v) return math.floor((v or 0) * 100 + 0.5) end

-- The blueprint as one line. → code
function encode(bp)
  local ids, idx, keys, kidx = {}, {}, {}, {}
  local function key(k)
    if not k then return "" end
    if not kidx[k] then keys[#keys + 1] = k; kidx[k] = #keys end
    return tostring(kidx[k])
  end
  local lines = {}
  for _, e in ipairs(bp.pieces or {}) do
    if not idx[e.id] then ids[#ids + 1] = e.id; idx[e.id] = #ids end
    local f = { idx[e.id], cm(e.x), cm(e.y), cm(e.z), deg(e.yaw), deg(e.pitch), deg(e.roll), key(e.paint), key(e.paintIn), e.text and esc(e.text) or "" }
    local s = table.concat(f, ",")
    s = s:gsub(",+$", "")
    lines[#lines + 1] = s
  end
  local head = table.concat({ "v" .. tostring(bp.v or V), esc(bp.name or "Blueprint"), table.concat(ids, ","), table.concat(keys, ",") }, "|")
  local payload = b64enc(head .. "|" .. table.concat(lines, ";"))
  return PREFIX .. "." .. payload .. "." .. b36(adler(payload), 4)
end

-- A code back to a blueprint. → bp | nil, why
function decode(code)
  if type(code) ~= "string" then return nil, "no code" end
  code = code:gsub("%s+", "")
  if #code > CODE_MAX then return nil, "that code is too long" end
  local pre, payload, chk = code:match("^([%w]+)%.([%w%-_]+)%.(%w+)$")
  if not pre then return nil, "that isn't a blueprint code (SOLBP1.…)" end
  if pre ~= PREFIX then return nil, "a blueprint code from another version (" .. pre .. ")" end
  if b36(adler(payload), 4) ~= chk then return nil, "the code is damaged or cut short (its check doesn't match)" end
  local text = b64dec(payload)
  if not text then return nil, "the code is damaged" end
  local v, name, idl, keyl, body = text:match("^v(%d+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
  if not v then return nil, "the code is damaged" end
  local ids, keys = {}, {}
  for s in (idl .. ","):gmatch("([^,]*),") do if s ~= "" then ids[#ids + 1] = s end end
  for s in (keyl .. ","):gmatch("([^,]*),") do if s ~= "" then keys[#keys + 1] = s end end
  local pieces = {}
  for line in (body .. ";"):gmatch("([^;]*);") do
    if line ~= "" then
      local f = {}
      for s in (line .. ","):gmatch("([^,]*),") do f[#f + 1] = s end
      local id = ids[tonumber(f[1] or "") or 0]
      if not id then return nil, "the code is damaged (a piece with no id)" end
      local function n(i) return (tonumber(f[i] or "") or 0) end
      pieces[#pieces + 1] = { id = id, x = n(2) / 100, y = n(3) / 100, z = n(4) / 100,
        yaw = math.rad(n(5)), pitch = math.rad(n(6)), roll = math.rad(n(7)),
        paint = keys[tonumber(f[8] or "") or 0], paintIn = keys[tonumber(f[9] or "") or 0],
        text = (f[10] and f[10] ~= "") and unesc(f[10]) or nil }
    end
  end
  if #pieces == 0 then return nil, "the code holds no pieces" end
  return { v = tonumber(v), name = unesc(name), n = #pieces, pieces = pieces }
end

-- The JSON shape (assets.writeJson) and back, checked: every piece has an id
-- and numbers. → bp | nil, why
function fromTable(t)
  if type(t) ~= "table" or type(t.pieces) ~= "table" then return nil, "not a blueprint" end
  if (tonumber(t.v) or 0) > V then return nil, "a blueprint from a newer Solar" end
  local pieces = {}
  for _, e in ipairs(t.pieces) do
    if type(e) ~= "table" or type(e.id) ~= "string" then return nil, "a piece with no id" end
    local function n(k) return tonumber(e[k]) or 0 end
    pieces[#pieces + 1] = { id = e.id, x = n("x"), y = n("y"), z = n("z"), yaw = n("yaw"), pitch = n("pitch"), roll = n("roll"),
      paint = type(e.paint) == "string" and e.paint or nil, paintIn = type(e.paintIn) == "string" and e.paintIn or nil,
      text = type(e.text) == "string" and e.text or nil }
  end
  if #pieces == 0 then return nil, "no pieces" end
  return { v = tonumber(t.v) or V, name = tostring(t.name or "Blueprint"):sub(1, NAME_MAX), by = t.by, made = t.made,
           n = #pieces, mass = tonumber(t.mass), cost = tonumber(t.cost), pieces = pieces }
end

-- Are two blueprints the same build? (names aside; to 1 cm and 1°)
function same(a, b)
  if not (a and b) or #a.pieces ~= #b.pieces then return false end
  for i, e in ipairs(a.pieces) do
    local f = b.pieces[i]
    if e.id ~= f.id or e.paint ~= f.paint or e.paintIn ~= f.paintIn or (e.text or "") ~= (f.text or "") then return false end
    for _, k in ipairs({ "x", "y", "z" }) do if math.abs((e[k] or 0) - (f[k] or 0)) > 0.006 then return false end end
    for _, k in ipairs({ "yaw", "pitch", "roll" }) do
      local d = math.abs(wrapA((e[k] or 0) - (f[k] or 0)))
      if d > math.rad(0.6) then return false end
    end
  end
  return true
end

-- ── pure: a plan drawing for the card (top-down, ink on enamel) ─────────────
-- → { { x0, z0, x1, z1, kind } … } in metres, and the bounds
function planOf(bp, defs)
  local rects, lo, hi = {}, { 1e9, 1e9 }, { -1e9, -1e9 }
  for _, e in ipairs(bp.pieces or {}) do
    local d = defs(e.id)
    local b = d and (d.box or (d.half and { -d.half.x, d.half.x, 0, 0, -d.half.z, d.half.z }))
    if b and not (d and (d.film or d.snap == "mount")) then
      local c, s = math.cos(e.yaw or 0), math.sin(e.yaw or 0)
      local xs, zs = {}, {}
      for _, q in ipairs({ { b[1], b[5] }, { b[2], b[5] }, { b[2], b[6] }, { b[1], b[6] } }) do
        xs[#xs + 1] = e.x + q[1] * c + q[2] * s
        zs[#zs + 1] = e.z - q[1] * s + q[2] * c
      end
      local up = table.unpack or unpack
      local r = { math.min(up(xs)), math.min(up(zs)), math.max(up(xs)), math.max(up(zs)), d.snap or "block", e.y or 0 }
      rects[#rects + 1] = r
      lo[1], lo[2] = math.min(lo[1], r[1]), math.min(lo[2], r[2])
      hi[1], hi[2] = math.max(hi[1], r[3]), math.max(hi[2], r[4])
    end
  end
  return rects, lo, hi
end

-- ── STOCK: blueprints that ship (examples to place and change) ──────────────
-- Built as kit pieces in the anchor's frame (the first piece at the origin).
-- A 4 x 4 m crew hut on four slabs: steel walls, a door, two windows, a flat
-- roof, a light and switch, a bunk, a table and chairs, shelving, a sign with
-- the base's name over the door, hazard stripes at the step, a little grime.
local function hut()
  local P = {}
  local function add(id, x, y, z, yaw, pitch, roll, paint, paintIn, text)
    P[#P + 1] = { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0, paint = paint, paintIn = paintIn, text = text }
  end
  local q = math.pi / 2
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do add("slab2.concrete", s[1], 0, s[2]) end
  local T = 0.2
  add("doorWall.steel", 0, T, 3, 0, 0, 0, "hull", "bone")
  add("windowWall.steel", 2, T, 3, 0, 0, 0, "hull", "bone")
  add("wall.steel", 0, T, -1, math.pi, 0, 0, "hull", "bone")
  add("wall.steel", 2, T, -1, math.pi, 0, 0, "hull", "bone")
  add("windowWall.steel", -1, T, 0, -q, 0, 0, "hull", "bone")
  add("wall.steel", -1, T, 2, -q, 0, 0, "hull", "bone")
  add("wall.steel", 3, T, 0, q, 0, 0, "hull", "bone")
  add("wall.steel", 3, T, 2, q, 0, 0, "hull", "bone")
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do add("floor.steel", s[1], T + 2.2, s[2], 0, 0, 0, "gunmetal") end
  add("lightFitting.steel", 1, T + 2.2, 1, 0, math.pi, 0)
  add("switchPlate.steel", 0.25, T + 1.25, 2.9, math.pi, q, 0)
  add("bunk.steel", 0.1, T, -0.4, 0, 0, 0, "olive")
  add("table.steel", 1.75, T, 1.5, q, 0, 0)
  add("chair.steel", 0.95, T, 1.5, q, 0, 0)
  add("chair.steel", 2.55, T, 1.5, -q, 0, 0)
  add("shelf.steel", 2.6, T, 0.0, -q, 0, 0)
  add("crateS.steel", 2.6, T, 2.55, 0, 0, 0, "orange")
  add("lampDesk.steel", 1.75, T + 0.74, 1.15, 0)
  add("plant.steel", -0.55, T, 2.5, 0)
  -- outside: the hut's number by the door, the base's name along its side,
  -- a kick stripe under the front, grime down the back
  add("signPlate.steel", 0.5, T + 1.65, 3.1, 0, q, 0)
  add("signBoard.steel", 3.1, T + 1.55, 1.0, q, q, 0)
  add("decalHaz.film", 1.0, T + 0.15, 3.1, 0, q, 0)
  add("grimeStreaks.film", 0.0, T + 1.1, -1.1, math.pi, q, 0)
  add("grimeLeak.film", 3.1, T + 1.4, 2.4, q, q, 0)
  return P
end
local function shack()
  local P = {}
  local function add(id, x, y, z, yaw, pitch, roll, paint, paintIn, text)
    P[#P + 1] = { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0, paint = paint, paintIn = paintIn, text = text }
  end
  local q = math.pi / 2
  add("slab2.concrete", 0, 0, 0)
  local T = 0.2
  add("openFrame.steel", 0, T, 1, 0, 0, 0, "olive")
  add("wall.steel", 0, T, -1, math.pi, 0, 0, "olive")
  add("wall.steel", -1, T, 0, -q, 0, 0, "olive")
  add("wall.steel", 1, T, 0, q, 0, 0, "olive")
  add("floor.steel", 0, T + 2.2, 0, 0, 0, 0, "gunmetal")
  add("workbench.steel", 0, T, -0.55, 0, 0, 0, "oxide")
  add("toolRack.steel", -0.9, T + 1.45, 0.2, q, q, 0)
  add("lampFloor.steel", 0.55, T, 0.45, -2.356, 0, 0)
  add("crateS.steel", -0.55, T, 0.55, 0, 0, 0, "orange")
  add("decalNum2.film", 1.1, T + 1.6, 0, q, q, 0)
  add("decalHazS.film", 0, T + 2.125, 1.1, 0, q, 0)
  return P
end
STOCK = {
  { key = "stock.hut", name = "Crew Hut 4 × 4 (stock)", pieces = hut, desc = "a furnished 4 x 4 m hut: bunk, table, light, a name board over the door" },
  { key = "stock.shack", name = "Tool Shack 2 × 2 (stock)", pieces = shack, desc = "an open-fronted 2 x 2 m workshop with a bench and a work light" },
}
function stock(key)
  for _, s in ipairs(STOCK) do
    if s.key == key then
      local ps = s.pieces()
      return { v = V, name = s.name, n = #ps, pieces = ps, stock = true, desc = s.desc }
    end
  end
  return nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE SCENE HALF: the library on disk, the prompt, dropped files
-- ════════════════════════════════════════════════════════════════════════════
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function say(s) if caption then pcall(caption, s) end if log then log("blueprints: " .. s) end end

local LIB = nil            -- slug → bp (the files), read once and kept
local ORDER = {}
version = 0                -- bumps when the library changes (the catalogue redraws)
lastSaved = nil            -- { slug, path, code, n } (probes)

local function store() return assets ~= nil and assets.writeJson ~= nil end
function scan()
  LIB, ORDER = {}, {}
  if not (assets and assets.getContents and assets.readJson) then return end
  local ok, files = pcall(assets.getContents, DIR)
  if not ok or type(files) ~= "table" then return end
  table.sort(files)
  for _, f in ipairs(files) do
    local s = tostring(f):match("([^/]+)%.json$")
    if s then
      local okj, t = pcall(assets.readJson, f)
      local bp = okj and fromTable(t) or nil
      if bp then LIB[s] = bp; ORDER[#ORDER + 1] = s end
    end
  end
  version = version + 1
end
local function lib() if not LIB then scan() end return LIB end

-- Every blueprint the BLUEPRINTS tab shows: the player's, then the stock.
-- → { { key, bp } … } (key: a slug, or a STOCK key)
function all()
  local L = lib()
  local out = {}
  for _, s in ipairs(ORDER) do if L[s] then out[#out + 1] = { key = s, bp = L[s] } end end
  for _, s in ipairs(STOCK) do out[#out + 1] = { key = s.key, stockKey = true } end
  return out
end
function get(key)
  if type(key) ~= "string" then return nil end
  if key:match("^stock%.") then return stock(key) end
  return lib()[key]
end

-- Save a blueprint to the library (a file and its code). → slug, path, code | nil, why
function saveBp(bp)
  if not store() then return nil, "no file store here" end
  local s0 = slug(bp.name)
  local s, i = s0, 1
  local L = lib()
  while L[s] and L[s].name ~= bp.name do i = i + 1; s = s0 .. "-" .. i end
  local path = DIR .. "/" .. s .. ".json"
  local t = { v = bp.v or V, name = bp.name, by = bp.by, made = bp.made, n = #bp.pieces, mass = bp.mass, cost = bp.cost, pieces = bp.pieces }
  local ok, err = pcall(assets.writeJson, path, t)
  if not ok then return nil, "couldn't write " .. path .. ": " .. tostring(err) end
  local code = encode(bp)
  if assets.writeText then pcall(assets.writeText, DIR .. "/" .. s .. ".code.txt", code .. "\n") end
  L[s] = bp
  local have = false
  for _, x in ipairs(ORDER) do if x == s then have = true end end
  if not have then ORDER[#ORDER + 1] = s end
  version = version + 1
  lastSaved = { slug = s, path = path, code = code, n = #bp.pieces }
  return s, path, code
end
function remove(key)
  local L = lib()
  if not L[key] then return false end
  if assets and assets.remove then
    pcall(assets.remove, DIR .. "/" .. key .. ".json")
    pcall(assets.remove, DIR .. "/" .. key .. ".code.txt")
  end
  L[key] = nil
  for i = #ORDER, 1, -1 do if ORDER[i] == key then table.remove(ORDER, i) end end
  version = version + 1
  return true
end
-- A code (pasted, or a .txt dropped) into the library. → slug | nil, why
function importCode(code)
  local bp, why = decode(code)
  if not bp then return nil, why end
  return saveBp(bp)
end

-- A dropped file: a blueprint's JSON or its code.
function filesDropped(node, files)
  for _, f in ipairs(files or {}) do
    local nm = tostring(f.name or "")
    local s, why
    if nm:match("%.json$") and json and json.decode then
      local t = json.decode(f.bytes or "")
      local bp
      bp, why = fromTable(t)
      if bp then s, why = saveBp(bp) end
    elseif nm:match("%.txt$") or tostring(f.bytes or ""):match("^%s*" .. PREFIX .. "%.") then
      s, why = importCode(f.bytes or "")
    end
    if s then say(string.format("blueprint \"%s\" added to the library (%s)", get(s).name, nm))
    elseif why then say(string.format("%s: not a blueprint (%s)", nm, why)) end
  end
end

-- ── THE PROMPT: a name, a sign's words, a code to import (one at a time) ────
-- opts = { title, line, text, placeholder, maxLen, ok, cancel, onOk = fn(text)
--          → true | false, why, onCancel = fn(), code (a read-only line shown) }
local P = { node = nil, making = false, focused = false, opts = nil, text = "" }
function prompt(opts)
  P.opts, P.text, P.focused, P.err = opts, opts.text or "", false, nil
  return true
end
function prompting() return P.opts ~= nil end
function promptText() return P.text end
local function close_prompt()
  P.opts = nil
  if P.node and P.node.valid ~= false then P.node:destroy() end
  P.node, P.focused = nil, false
end
function closePrompt() close_prompt() end
function commit(text)
  local o = P.opts
  if not o then return false, "no prompt" end
  local t = text
  if t == nil then t = P.text end
  local ok, why = true, nil
  if o.onOk then ok, why = o.onOk(t) end
  if ok == false then P.err = why; return false, why end
  -- (an onOk may open the next prompt: the code after a save)
  if P.opts == o then close_prompt() end
  return true
end
function cancel()
  local o = P.opts
  if o and o.onCancel then pcall(o.onCancel) end
  if P.opts == o then close_prompt() end
end
local function tree()
  local o = P.opts
  local rows = { "col", key = "kp", style = "panel/frame", w = 460, h = "fit", dir = "col", gap = 8, pad = 16, align = "start",
    { "text", key = "h", style = "panel/heading", w = "100%", h = "fit", text = o.title or "Name it" } }
  if o.line then rows[#rows + 1] = { "text", key = "w", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true, text = o.line } end
  if not o.readOnly then
    rows[#rows + 1] = { "field", key = "f", name = "FieldKitText", style = "menu/field", w = "100%", h = 32, maxLen = o.maxLen or NAME_MAX,
      placeholder = o.placeholder or "", onChanged = function(n) P.text = n.text or "" end,
      onSubmitted = function(n) if input.spaceSubmit and input.spaceSubmit(n) then return end commit((n and n.text) or P.text) end }
  end
  if o.code then
    rows[#rows + 1] = { "field", key = "c", name = "FieldKitCode", style = "menu/field", w = "100%", h = 32, maxLen = CODE_MAX,
      placeholder = "", text = o.code }
  end
  rows[#rows + 1] = { "text", key = "t", style = P.err and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit", wrap = true,
    text = P.err or o.hint or "Enter to confirm · Esc to cancel" }
  rows[#rows + 1] = { "row", key = "b", w = "100%", h = 32, gap = 8, pad = 0, align = "center",
    { "button", key = "ok", style = "panel/action", w = "grow", h = 32, text = o.ok or "OK", textAlign = "center",
      textValign = "center", onClicked = function() commit(nil) end },
    { "button", key = "no", style = "panel/secondary", w = 150, h = 32, textAlign = "center", textValign = "center",
      text = o.cancel or "Cancel", onClicked = function() cancel() end } }
  return rows
end
local function prompt_tick()
  if not P.opts then
    if P.node then close_prompt() end
    return
  end
  if input and input.setMouseLocked then input.setMouseLocked(false) end
  if input and input.pressed and input.pressed("escape") then
    local fb = ref("field_builder")
    if fb then fb.escTakenAt = now() end
    cancel()
    return
  end
  if not (P.node and P.node.valid ~= false) then
    if P.making or not spawn then return end
    local h = find and find("Ship HUD")
    if not h then return end
    P.making = true
    pcall(spawn, "BaseNamePrompt", vec3(0, 0, 0), function(n)
      P.making = false
      if not P.opts then n:destroy() return end
      P.node = n
    end, h)
    return
  end
  if ui and ui.make then ui.make(P.node, { tree() }) end
  if not P.focused and ui and ui.focus and find then
    local f = find(P.opts.readOnly and "FieldKitCode" or "FieldKitText")
    if f then ui.focus(f); P.focused = true end
  end
end

function start(node)
  if findScripts then
    local all_ = findScripts("blueprints")
    if #all_ > 1 and all_[1].node and all_[1].node.id ~= node.id then node:destroy() return end
  end
  LIB = nil
  P.opts, P.node = nil, nil
end
function update(node, dt)
  if P.opts or P.node then prompt_tick() end
end
