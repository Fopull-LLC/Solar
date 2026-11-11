-- KIT_PAINT — paint and weather on the modular kit's pieces (sandbox plan S4,
-- work/sandbox/PLAN.md §5; docs/base-building.md §15).
--
-- On the Build Kit node (scenes/system.ron) beside parts_kit.lua. The rules
-- half is pure (its globals are its API; it loads from disk in a luajit test,
-- tests/smoke_character.lua); the scene half tints a placed piece's nodes.
--
-- ── THE PALETTE (Ty 11-06: a curated palette of about 12 swatches) ──────────
-- Twelve enamels drawn from the UI tokens (ui/solar.tokens.ron: bezel, ink,
-- plate, phos, signal, accent, warn …) so a painted hab and the HUD read as
-- one world: hull whites, primer and gunmetal greys, olive and hab green, a
-- quiet blue-grey, regolith tan, signal orange, oxide red, safety yellow, and
-- the AGENCY swatch (the company emblem's own colour when there is one).
-- Each swatch is the ALBEDO the painted surface should average, in linear
-- light, a little dusty already: real enamel, not a screen colour.
--
-- ── HOW PAINT SITS ON A PIECE ───────────────────────────────────────────────
-- node:setTint multiplies over everything a node draws and keeps its
-- textures: the normal, roughness and AO maps, and the albedo's own stains,
-- scuffs and streaks. So paint is the tint that turns the piece's material
-- average into the swatch (swatch / base, per channel): the panel seams, the
-- concrete's pitting and the grime in the texture all show through, the way
-- a coat of enamel over a worn panel does. Tint never splits a draw (engine
-- perf.counts: "colour … tint … never split a draw"), so a painted wall row
-- still batches.
--
-- ── THE RECORD (a structure's bp entry, so it saves, copies and travels in
-- a blueprint with the piece) ───────────────────────────────────────────────
--   paint    the swatch key of the whole piece, or of a wall's OUTSIDE (+Z)
--   paintIn  a wall-class piece's INSIDE (-Z) face: the "<mat>In" slots of its
--            Mesh (meshfold, 11-11: CladIn, SteelIn, ConcreteIn, one instance
--            with the outside's slots), or a hab can's "MeshIn" child
--   pt       the agency clock when it was last painted (fresh paint is clean)
--
-- ── WEATHER (the light pass of plan §5's wear) ──────────────────────────────
-- An exterior piece gathers DUST with its age (since it was placed or last
-- painted): fast on a dry world (an airless moon's regolith clings), slowly
-- where rain washes it (the home world). Dust is mixed into the tint toward
-- the world's own ground colour, on the outside skin only (a wall's MeshIn,
-- props and fittings stay clean). The level is quantised to DUST_STEPS, so a
-- structure is re-tinted only when its level steps (a few times a game month).

-- (S5 polish, from the S4 screenshots: the first palette was picked as if
-- its numbers were screen colours, but they are LINEAR albedo, so every
-- swatch came out a pale mid-tone pastel (Gunmetal 0.27 linear is a light
-- grey on screen, Oxide Red a salmon) and they read alike. Each swatch is
-- now named by the sRGB colour a real enamel shows (RAL-like: 9010 pure
-- white, 9001 cream, 7035 light grey, 1003 signal yellow, 2004 orange, 3009
-- oxide red, 6011 reseda green, 6003 olive, 5015 sky blue, 7037 dust grey,
-- 7016 anthracite) and converted to linear once: three light swatches and a
-- yellow, the saturated signal colours, the mids and two darks, so a painted
-- base has a real value range. Still a little dirty: no swatch is a pure
-- primary or brighter than a weathered white.)
local function lin(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end
PALETTE = {
  { key = "hull",      label = "Hull White",    srgb = { 0.93, 0.92, 0.88 }, token = "bezel" },
  { key = "bone",      label = "Cream",         srgb = { 0.92, 0.86, 0.72 }, token = "ink" },
  { key = "lightgrey", label = "Light Grey",    srgb = { 0.76, 0.77, 0.76 }, token = "plate" },
  { key = "safety",    label = "Safety Yellow", srgb = { 0.96, 0.74, 0.07 }, token = "warn" },
  { key = "orange",    label = "Signal Orange", srgb = { 0.90, 0.38, 0.08 }, token = "accent" },
  { key = "oxide",     label = "Oxide Red",     srgb = { 0.52, 0.14, 0.10 }, token = "accentDim" },
  { key = "habgreen",  label = "Hab Green",     srgb = { 0.36, 0.55, 0.38 }, token = "phosDim" },
  { key = "olive",     label = "Olive Drab",    srgb = { 0.34, 0.36, 0.21 }, token = "panel" },
  { key = "signal",    label = "Signal Blue",   srgb = { 0.18, 0.40, 0.62 }, token = "signal" },
  { key = "primer",    label = "Primer Grey",   srgb = { 0.48, 0.49, 0.48 }, token = "muted" },
  { key = "gunmetal",  label = "Anthracite",    srgb = { 0.18, 0.19, 0.20 }, token = "plateHi" },
  { key = "agency",    label = "Agency Colour", srgb = { 0.16, 0.38, 0.42 }, token = "agency", agency = true },
}
for _, s in ipairs(PALETTE) do s.rgb = { lin(s.srgb[1]), lin(s.srgb[2]), lin(s.srgb[3]) } end
-- keys a save may hold from the first palette, and the swatch they became
ALIAS = { sand = "bone" }
BY_KEY = {}
for i, s in ipairs(PALETTE) do s.i = i; BY_KEY[s.key] = s end
for k, v in pairs(ALIAS) do BY_KEY[k] = BY_KEY[v] end

-- What each kit material's surface averages (linear albedo: the texture's
-- mean × the generator's paint colour, tools/gen_kit_parts.py look()):
-- cladding 0.63 × factory white 0.74, concrete 0.29 × 0.95, regolith brown.
BASE = {
  steel     = { 0.470, 0.462, 0.434 },
  concrete  = { 0.285, 0.273, 0.247 },
  regocrete = { 0.198, 0.154, 0.114 },
  glass     = { 0.257, 0.261, 0.260 },
  -- (W1, W2) weathered softwood: textures/kit/timber_board_albedo.png (Wood062's boards, weathered:
  -- tools/gen_kit_wood.py STRIP_MEAN) × the boards' tints (0.85 on average); paint on it is a stain
  wood      = { 0.252, 0.186, 0.115 },
  film      = { 0.70, 0.70, 0.70 },
  prop      = { 0.42, 0.42, 0.41 },
}
-- (a white coat on dark regocrete multiplies its blue by ~6.6: S5 raised
-- the ceiling from 3, which had clamped light paint on dark materials grey)
TINT_MAX = 8.0
-- what a coat of paint costs a piece, by its share of a 2 x 2.2 m wall face
PAINT_COST = 30

DUST_STEPS = 20
DUST_TAU_DAYS = 60.0
DAY = 86400.0
-- the dust's colour by world kind (climate.KIND), linear: the regolith that settles
DUST_COL = {
  barren = { 0.36, 0.34, 0.31 }, crystal = { 0.40, 0.37, 0.42 }, lava = { 0.16, 0.14, 0.13 },
  temperate = { 0.38, 0.33, 0.26 }, arid = { 0.52, 0.40, 0.27 }, ice = { 0.62, 0.64, 0.66 },
}
DUST_DEFAULT = { 0.40, 0.36, 0.30 }

-- ── pure ────────────────────────────────────────────────────────────────────
function swatch(key) return BY_KEY[key] end
function keys() local o = {} for _, s in ipairs(PALETTE) do o[#o + 1] = s.key end return o end

-- sRGB → linear light (the emblem's own colours are sRGB picks)
function toLinear(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

-- The agency swatch's albedo: the emblem's main colour (sRGB) made into a
-- worn enamel (a little greyed and darkened), or the swatch's own.
AGENCY_RGB = nil
function setAgency(srgb)
  if type(srgb) ~= "table" or #srgb < 3 then AGENCY_RGB = nil return end
  local r, g, b = toLinear(srgb[1]), toLinear(srgb[2]), toLinear(srgb[3])
  local m = (r + g + b) / 3
  -- 15 % toward its own grey, at most 0.8 albedo: weathered enamel
  r, g, b = r + (m - r) * 0.15, g + (m - g) * 0.15, b + (m - b) * 0.15
  local hi = math.max(r, g, b)
  if hi > 0.8 then r, g, b = r * 0.8 / hi, g * 0.8 / hi, b * 0.8 / hi end
  AGENCY_RGB = { math.max(0.03, r), math.max(0.03, g), math.max(0.03, b) }
end
function rgbOf(key)
  local s = BY_KEY[key]
  if not s then return nil end
  if s.agency and AGENCY_RGB then return AGENCY_RGB end
  return s.rgb
end

-- The material a piece's surface is (for its base albedo).
function baseOf(def)
  if def and def.paintBase then return def.paintBase end
  local m = def and def.mat
  return BASE[m] or BASE.prop
end

-- The multiply that turns `def`'s surface into swatch `key` (nil = unpainted).
function tintFor(key, def)
  local rgb = key and rgbOf(key)
  if not rgb then return nil end
  local b = baseOf(def)
  local t = {}
  for i = 1, 3 do t[i] = math.max(0, math.min(TINT_MAX, rgb[i] / math.max(0.02, b[i]))) end
  return t
end

-- Does a piece take paint at all? (not a light's lens, a screen, a film)
function paintable(def)
  if not def or not def.kit then return false end
  if def.live or def.light or def.screen or def.noPaint then return false end
  return true
end
-- Does it have an inside face to paint apart? (a wall-class piece: the
-- generator gave it a MeshIn)
function twoFaced(def) return def ~= nil and def.faces2 == true end

-- Which face of a wall-class piece a hit normal is on: "out" (+Z) or "in".
-- n = the hit normal in the piece's own frame's yaw (structure-frame x, z),
-- yaw = the piece's yaw.
function faceOf(yaw, nx, nz)
  local fx, fz = math.sin(yaw or 0), math.cos(yaw or 0)
  return (nx * fx + nz * fz) >= 0 and "out" or "in"
end

-- How dusty an exterior piece is after `days` on world kind `kind`
-- (wet = rain washes it). 0 .. cap, quantised.
function dustLevel(days, wet)
  if not days or days <= 0 then return 0 end
  local cap = wet and 0.28 or 0.55
  local k = cap * (1 - math.exp(-days / DUST_TAU_DAYS))
  return math.floor(k * DUST_STEPS + 0.5) / DUST_STEPS
end
function dustColor(kind) return DUST_COL[kind or ""] or DUST_DEFAULT end
-- When (days of age) the quantised level next steps, or nil (it has stopped).
function nextStepDays(days, wet)
  local cap = wet and 0.28 or 0.55
  local L = dustLevel(days, wet)
  local r = (L * DUST_STEPS + 0.5) / DUST_STEPS
  if r >= cap - 1e-9 then return nil end
  return -DUST_TAU_DAYS * math.log(1 - r / cap)
end

-- The tint for a surface: paint (or none) with dust mixed toward `dcol`.
-- → { r, g, b } | nil (no tint: unpainted and clean)
function surfaceTint(key, def, dust, dcol)
  local t = tintFor(key, def)
  if (dust or 0) <= 0 then return t end
  local b = baseOf(def)
  t = t or { 1, 1, 1 }
  local o = {}
  for i = 1, 3 do
    local d = math.min(TINT_MAX, (dcol or DUST_DEFAULT)[i] / math.max(0.02, b[i]))
    o[i] = t[i] * (1 - dust) + d * dust
  end
  return o
end

-- What painting `n` pieces costs (Creative: nothing).
function costOf(n, creative) if creative then return 0 end return PAINT_COST * (n or 1) end

-- The swatch a part shows on its face `face` ("out" | "in"): the eyedropper.
function pick(part, face)
  if not part then return nil end
  if face == "in" and part.paintIn then return part.paintIn end
  return part.paint
end

-- A part's record after painting: face = "out" | "in" | "both"; key nil
-- strips it. Returns the fields changed { paint, paintIn, pt } (pure).
function painted(part, key, face, t)
  local o = { paint = part.paint, paintIn = part.paintIn, pt = t }
  if face == "in" then o.paintIn = key
  elseif face == "out" then o.paint = key
  else o.paint, o.paintIn = key, nil end
  return o
end

-- ── the scene half ──────────────────────────────────────────────────────────
local function valid(n) return n ~= nil and n.valid ~= false end
local function tint(n, c)
  if not valid(n) then return end
  if c then pcall(n.setTint, n, { color = { c[1], c[2], c[3] } }) else pcall(n.setTint, n) end
end

-- The nodes paint goes on: the piece's Mesh (and its door leaves, which are
-- the same wall), and the MeshIn of a two-faced piece. → out{}, in{}
-- (a two-faced WALL has no MeshIn now: its inside is slots of its Mesh, see
-- slotsOf; `inn` is then empty and the Mesh is in `out`, so a rim or a
-- highlight still covers both faces)
-- (by name, as kit_live finds a door: a node's children() list can still be
-- empty in the spawn callback that hands over a fresh piece, getChild is not)
local function named(n, nm)
  local ok, c = pcall(n.getChild, n, nm)
  if ok and c and c.valid ~= false then return c end
  return nil
end
function surfaces(node)
  local out, inn = {}, {}
  for _, nm in ipairs({ "Mesh", "Door", "Door2" }) do local c = named(node, nm); if c then out[#out + 1] = c end end
  local c = named(node, "MeshIn")
  if c then inn[#inn + 1] = c end
  return out, inn
end

-- (meshfold, 11-11) A folded wall's Mesh: its slots, outside and inside, by
-- the names the generator gives (tools/gen_kit_parts.py fold_inside: an
-- inside slot is its outside's name + "In"). Read from the model once per
-- prefab. → { out = { names }, inn = { names } } | false (not folded)
-- Paint on such a piece is written to each slot's own colour (the prefab's
-- override holds every slot's whole material, so only its colour changes)
-- instead of setTint, which covers the whole model: the engine then draws
-- the wall as ONE instance whatever its two faces wear (engine 0685).
local SLOTS = {}
function slotsOf(mesh, def)
  local k = def and (def.prefab or def.id) or "?"
  local s = SLOTS[k]
  if s ~= nil then return s end
  s = false
  local ok, list = pcall(mesh.materials, mesh)
  if ok and type(list) == "table" then
    local o, i, seen = {}, {}, {}
    for _, sl in ipairs(list) do
      local nm = sl.material
      if type(nm) == "string" and not seen[nm] then
        seen[nm] = true
        if nm:sub(-2) == "In" then i[#i + 1] = nm else o[#o + 1] = nm end
      end
    end
    if #i > 0 then s = { out = o, inn = i } end
  end
  -- (a model not loaded yet answers no slots: asked again next time, and meanwhile the
  -- names the generator gives a wall of this material; a name no part wears is unused)
  if s or (ok and type(list) == "table" and #list > 0) then SLOTS[k] = s; return s end
  return def and def.faces2 and FOLD_GUESS[def.mat] or false
end
FOLD_GUESS = {
  steel = { out = { "Clad", "Steel" }, inn = { "CladIn", "SteelIn" } },
  concrete = { out = { "Concrete", "Steel" }, inn = { "ConcreteIn", "SteelIn" } },
  regocrete = { out = { "Concrete", "Steel" }, inn = { "ConcreteIn", "SteelIn" } },
  glass = { out = { "Steel" }, inn = { "SteelIn" } },
  -- (W1) a timber wall keeps its own sets: the boards and the iron (tools/gen_kit_wood.py)
  wood = { out = { "Timber", "Steel" }, inn = { "TimberIn", "SteelIn" } },
}
local WHITE = { 1, 1, 1 }
local function slot_paint(mesh, names, c)
  c = c or WHITE
  for _, nm in ipairs(names) do
    pcall(function() mesh:material(nm).color = { c[1], c[2], c[3] } end)
  end
end
slotWrites = 0         -- probes: slot colours written

-- Tint a placed piece's node for its record: paint, inside paint, dust.
-- dust = 0..1 on its outside; dcol = the dust colour. Clean and unpainted
-- clears the tint (the identity costs nothing).
function apply(node, part, def, dust, dcol)
  if not (valid(node) and part and def) then return end
  local out, inn = surfaces(node)
  local d = (def.exterior ~= false) and (dust or 0) or 0
  local tO = surfaceTint(part.paint, def, d, dcol)
  -- (a two-faced piece's inside is its own swatch, or the outside's when it
  -- has none: an unsplit "paint the wall" coats both)
  local tI = surfaceTint(def.faces2 and (part.paintIn or part.paint) or part.paint, def, 0, dcol)
  local sl = def.faces2 and #inn == 0 and out[1] and out[1].name == "Mesh" and slotsOf(out[1], def)
  if sl then
    slot_paint(out[1], sl.out, tO)
    slot_paint(out[1], sl.inn, tI)
    slotWrites = slotWrites + #sl.out + #sl.inn
    for k = 2, #out do tint(out[k], tO) end
  else
    for _, n in ipairs(out) do tint(n, tO) end
  end
  for _, n in ipairs(inn) do tint(n, tI) end
  if DEBUG and log then
    log(string.format("kit_paint: %s %s out %d in %d · %s / %s", tostring(node.name), tostring(part.uid), #out, #inn,
      tO and string.format("%.2f %.2f %.2f", tO[1], tO[2], tO[3]) or "-", tI and string.format("%.2f %.2f %.2f", tI[1], tI[2], tI[3]) or "-"))
  end
end
DEBUG = false

-- The selection's highlight (field_builder Alt+click): over the piece's
-- surfaces, then its paint back when it is let go.
function highlight(node, on, part, def, dust, dcol)
  if not valid(node) then return end
  local out, inn = surfaces(node)
  if on then
    -- (a folded wall's paint is in its slots: the highlight stands in for it, as its tint did)
    local sl = def and def.faces2 and #inn == 0 and out[1] and out[1].name == "Mesh" and slotsOf(out[1], def)
    if sl then slot_paint(out[1], sl.out, nil); slot_paint(out[1], sl.inn, nil) end
    for _, n in ipairs(out) do pcall(n.setTint, n, { color = { 0.6, 0.9, 1.0 }, rim = { 0.2, 0.7, 1.0 }, rimStrength = 0.8 }) end
    for _, n in ipairs(inn) do pcall(n.setTint, n, { color = { 0.6, 0.9, 1.0 }, rim = { 0.2, 0.7, 1.0 }, rimStrength = 0.8 }) end
  else
    for _, n in ipairs(out) do pcall(n.setTint, n) end
    for _, n in ipairs(inn) do pcall(n.setTint, n) end
    if part and def then apply(node, part, def, dust, dcol) end
  end
end

-- ── the swatch icons (the PAINT cards): drawn once, kept for the session ────
local ICON = {}
local function to_srgb(c)
  if c <= 0.0031308 then return 12.92 * c end
  return 1.055 * c ^ (1 / 2.4) - 0.055
end
-- a 64² chip of the swatch: a painted plate with a rubbed edge and a few
-- scuffs, the way the enamel on a placed piece looks (img: name | nil)
function iconOf(key)
  if ICON[key] ~= nil then return ICON[key] or nil end
  if not (image and image.new) then return nil end
  local rgb = (key == "strip" and { 0.30, 0.30, 0.30 }) or (key == "pick" and { 0.10, 0.10, 0.10 }) or rgbOf(key)
  if not rgb then ICON[key] = false return nil end
  local r, g, b = to_srgb(rgb[1]), to_srgb(rgb[2]), to_srgb(rgb[3])
  local ok, img = pcall(image.new, 64, 64, 0.09, 0.09, 0.08, 1)
  if not ok or not img then ICON[key] = false return nil end
  pcall(img.fill, img, 4, 4, 56, 56, r * 0.82, g * 0.82, b * 0.82, 1)
  pcall(img.fill, img, 6, 6, 52, 50, r, g, b, 1)
  -- wear: a rubbed lighter band at the top edge, dark scuffs low down
  pcall(img.fill, img, 6, 6, 52, 3, math.min(1, r * 1.15), math.min(1, g * 1.15), math.min(1, b * 1.15), 1)
  local seed = 0
  for c in tostring(key):gmatch(".") do seed = (seed * 31 + c:byte()) % 9973 end
  for i = 1, 5 do
    seed = (seed * 1103 + 12345) % 9973
    local x, y = 10 + seed % 44, 34 + math.floor(seed / 7) % 20
    pcall(img.circle, img, x, y, 1 + i % 3, r * 0.6, g * 0.6, b * 0.6, 0.55)
  end
  if key == "strip" then
    pcall(img.line, img, 12, 52, 52, 12, 4, 0.85, 0.30, 0.22, 1)
  elseif key == "pick" then
    pcall(img.text, img, 32, 18, "PICK", 16, 0.92, 0.89, 0.81, 1, "center", "fonts/SolarLabel.ttf")
  end
  local okt, tex = pcall(img.texture, img)
  ICON[key] = (okt and tex) or false
  return ICON[key] or nil
end

-- ── the driver: paint on spawn, dust by age, the agency swatch ──────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return (save and save.get and tonumber(save.get("agency.clock"))) or 0
end
local WORLD = {}       -- body → { kind, wet } (climate's world record, read once)
local function world_of(b)
  local w = WORLD[b]
  if w then return w end
  local cl = ref("climate")
  local rec = cl and cl.worldOf and cl.worldOf(b)
  w = { kind = rec and rec.kind or "barren", wet = rec ~= nil and (rec.atmo or 0) > 0.15 and (rec.sea or 0) > 0 }
  WORLD[b] = w
  return w
end
-- A placed piece's dust now: its age since placed or painted, its world.
function dustOf(rec, part, now)
  local t0 = part.pt or (type(part.paid) == "table" and part.paid.t) or rec.t or 0
  local w = world_of(rec.b)
  return dustLevel(((now or agency_now()) - t0) / DAY, w.wet), dustColor(w.kind)
end
-- (structures.spawn_part) a kit piece's node landed: its paint and dust
LEVEL = {}             -- "sid:uid" → the dust level it was last tinted at
function applyPart(rec, part, def, node, now)
  if not (rec and part and def and def.kit) then return end
  if not paintable(def) and not part.paint then return end
  local d, c = 0, nil
  if def.exterior then d, c = dustOf(rec, part, now) end
  LEVEL[tostring(rec.id) .. ":" .. tostring(part.uid)] = d
  if d <= 0 and not part.paint and not part.paintIn then return end
  apply(node, part, def, d, c)
end
-- Re-tint one piece after its record changed (painted, stripped).
function refresh(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  local part = rec and ST.getPart(sid, uid)
  local node = ST and ST.nodeOf(sid, uid)
  local pb = ref("parts_base")
  local def = part and pb and pb.partInfo(part.id)
  if not (node and def) then return false end
  local d, c = 0, nil
  if def.exterior then d, c = dustOf(rec, part) end
  LEVEL[tostring(sid) .. ":" .. tostring(uid)] = d
  apply(node, part, def, d, c)
  return true
end

local scan_t, agency_v, st_ver = -10, nil, nil
NEXT = {}              -- sid → the agency time its next dust step is due
scans = 0              -- probes: structures looked through by the dust driver
DUST_EVERY = 2.0
retints = 0            -- probes: pieces re-tinted by dust since the start
function start(node)
  if findScripts then
    local all = findScripts("kit_paint")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  LEVEL, WORLD = {}, {}
end
function update(node, dt)
  local t = time or 0
  if t - scan_t < DUST_EVERY then return end
  scan_t = t
  -- the agency swatch follows the emblem (its field colour)
  local em = ref("emblem")
  if em and em.version ~= agency_v and em.spec then
    agency_v = em.version
    local ok, sp = pcall(em.spec)
    if ok and sp and sp.pal and sp.pal.bg then setAgency(sp.pal.bg) end
  end
  -- dust: each live structure's exterior pieces, re-tinted only when a
  -- piece's quantised level steps (a few times a game month at 1x). A
  -- structure is looked at again only when its earliest step comes due
  -- (NEXT, agency clock) or the structures change: idle, this is one
  -- comparison a structure every DUST_EVERY seconds.
  local ST, pb = ref("structures"), ref("parts_base")
  if not (ST and pb and ST.list) then return end
  if ST.version ~= st_ver then st_ver = ST.version; NEXT = {} end
  local now = agency_now()
  for _, rec in ipairs(ST.list()) do
    if ST.isLive(rec.id) and (NEXT[rec.id] == nil or now >= NEXT[rec.id]) then
      local soonest = math.huge
      local w = world_of(rec.b)
      for _, p in ipairs(rec.bp) do
        local def = pb.partInfo(p.id)
        if def and def.kit and def.exterior and paintable(def) then
          local k = tostring(rec.id) .. ":" .. tostring(p.uid)
          local t0 = p.pt or (type(p.paid) == "table" and p.paid.t) or rec.t or 0
          local days = (now - t0) / DAY
          local d = dustLevel(days, w.wet)
          if LEVEL[k] ~= d then
            local n = ST.nodeOf(rec.id, p.uid)
            if n then LEVEL[k] = d; apply(n, p, def, d, dustColor(w.kind)); retints = retints + 1 end
          end
          local nx = nextStepDays(days, w.wet)
          if nx then soonest = math.min(soonest, t0 + nx * DAY) end
        end
      end
      NEXT[rec.id] = soonest
      scans = scans + 1
    end
  end
end
