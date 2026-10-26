-- EMBLEM — the agency's name and emblem (docs/crew-and-items.md §2.5, §7).
--
-- The player IS the agency. It has a name, chosen on the new-save panel (and
-- changeable in Settings ▸ Agency), and an emblem: generated from the name,
-- tweakable, or the player's own picture. The emblem is painted on every flag,
-- on a plate on every crewed part, on the suit's shoulder, and in the headers
-- that show who you are.
--
-- ── THE RULEBOOK (pure; loads in luajit, smoke_emblem.lua) ──────────────────
--
--   monogram(name)            "Solar Exploration Agency" → "SEA"
--   specFor(name [, seed])    the generated emblem's spec for a name: the same
--                             name always gives the same emblem
--   regenerate(spec, name)    the next emblem for that name (↻)
--   tweak(spec, field, dir)   step "shape", "motif", "pal" or "font" (◂ ▸)
--   setColour(spec, slot, c)  one of the four colours ("bg", "ring", "fg",
--                             "accent"), c = { r, g, b } 0..1
--   clean(t)                  a spec read back from a save, made safe
--   rasterEmblem(spec, name [, size [, picture]]) → pixels (size² × 4), image
--   rasterFlag(spec, name, emblem)               → pixels (FLAG_W × FLAG_H), image
--                             (drawn with the engine's image.*; offline, with
--                             tests/lib/image_shim.lua handed in as `image`)
--   decodePng(bytes, inflate) → { w, h, px = { r,g,b,a … 0..255 } } or nil, why
--   imageToBuf(img, size)     a picture centre-cropped to a square emblem buf
--
-- A spec is small and plain (it is what the save keeps, never pixels):
--
--   { v = 1, seed, shape, mono, motif, font, pal = { bg, ring, fg, accent },
--     image = nil | "user://emblems/<file>" }
--
-- ── THE SERVICE (in a game or the menu; findScript("emblem")) ───────────────
--
-- This script runs on the AgencyLib node (prefabs/AgencyLib), spawned by the
-- first thing that needs it (emblem_plate, the menus, the Tracking Station,
-- deployables). It builds the textures from the save at load and whenever the
-- spec changes, and publishes:
--
--   name()  agencyName()      the agency's name
--   spec()                    the current spec (a copy)
--   tex()                     "img:N" — the 256² emblem (nil until built,
--                             or under `floptle run`, which draws nothing)
--   flagTex()                 "img:N" — the 512×341 flag cloth
--   smallTex(slot)            a 96² emblem for another save slot's card
--   version                   bumps whenever tex()/flagTex() change; poll it
--   set(name, spec)           store a new identity in the current save, rebuild
--   preview(name, spec)       build textures for an editor without saving
--   customFiles()             { "user://emblems/x.png", … } (the folder scan)
--   emblemsFolder()           the real path of that folder, to show the player
--   canPickFile()             true when the engine has a native file picker
--   pickFile(fn)              open it (app.openFile) and copy the choice in
--   lastBuildMs               how long the last emblem + flag build took
--
-- A custom picture is read with assets.readBytes and decoded HERE (PNG, with
-- the engine's data.inflate; baseline JPEG in Lua), centre-cropped to a square
-- and composed exactly like a generated emblem, so the flag, the plates and the
-- suit all wear it. If the file has gone, the generated emblem for the same
-- name is used, with a notice once.

-- ════════════════════════════════════════════════════════════════════════════
-- THE RULEBOOK
-- ════════════════════════════════════════════════════════════════════════════

DEFAULT_NAME = "Solar Exploration Agency"
NAME_MAX = 32
EMBLEM_SIZE = 256
FLAG_W, FLAG_H = 512, 341

SHAPES = { "roundel", "patch", "shield", "hex", "chevron", "square" }
SHAPE_LABEL = { roundel = "Roundel", patch = "Mission patch", shield = "Shield", hex = "Hexagon",
                chevron = "Chevron", square = "Badge" }
MOTIFS = { "orbit", "rocket", "star", "planet", "swoosh" }
MOTIF_LABEL = { orbit = "Orbit", rocket = "Rocket", star = "Star", planet = "Ringed planet",
                swoosh = "Swooshes" }
FONTS = { "stencil", "label" }
FONT_LABEL = { stencil = "Stencil", label = "Block" }

local function hex(s)
  return { tonumber(s:sub(2, 3), 16) / 255, tonumber(s:sub(4, 5), 16) / 255, tonumber(s:sub(6, 7), 16) / 255 }
end

-- Ten curated four-colour sets in the Flight Hardware spirit: enamel fields,
-- warm whites, one signal colour each. `bg` is the field, `ring` the band and
-- border, `fg` the monogram and the line work, `accent` the one bright mark.
PALETTES = {
  { name = "Navy & red",       bg = hex("#1E3766"), ring = hex("#E9E5DA"), fg = hex("#F3F0E7"), accent = hex("#C9372C") },
  { name = "Olive & cream",    bg = hex("#4A5233"), ring = hex("#DCCFA8"), fg = hex("#F1E8CB"), accent = hex("#E07B2F") },
  { name = "Black & orange",   bg = hex("#1D1D1F"), ring = hex("#F08A24"), fg = hex("#F4F0E6"), accent = hex("#F08A24") },
  { name = "Maroon & gold",    bg = hex("#5B1F24"), ring = hex("#D6B160"), fg = hex("#F2E8D2"), accent = hex("#D6B160") },
  { name = "Slate & coral",    bg = hex("#22474F"), ring = hex("#ECE4D0"), fg = hex("#F5F0E3"), accent = hex("#E5674A") },
  { name = "Cream & navy",     bg = hex("#EAE3CD"), ring = hex("#1E3766"), fg = hex("#1E3766"), accent = hex("#C9372C") },
  { name = "Forest & gold",    bg = hex("#1F4634"), ring = hex("#EAE4D3"), fg = hex("#F3EFE5"), accent = hex("#E3B23C") },
  { name = "Royal & yellow",   bg = hex("#24489A"), ring = hex("#F1C232"), fg = hex("#F6F3EC"), accent = hex("#F1C232") },
  { name = "Rust & black",     bg = hex("#B8501C"), ring = hex("#1C1B1A"), fg = hex("#F7F0E3"), accent = hex("#1C1B1A") },
  { name = "White & crimson",  bg = hex("#F0EDE5"), ring = hex("#AF2A22"), fg = hex("#AF2A22"), accent = hex("#1E3766") },
}

-- ── names ───────────────────────────────────────────────────────────────────

-- The words that never make an initial.
local STOP = { ["of"] = true, ["the"] = true, ["and"] = true, ["&"] = true, ["for"] = true, ["a"] = true,
               ["an"] = true, ["de"] = true, ["la"] = true, ["le"] = true, ["du"] = true, ["von"] = true,
               ["der"] = true, ["to"] = true, ["at"] = true, ["in"] = true, ["on"] = true }

-- Accented capitals the alphabets don't carry, folded to their base letter.
local FOLD = {
  ["À"] = "A", ["Á"] = "A", ["Â"] = "A", ["Ã"] = "A", ["Ä"] = "A", ["Å"] = "A", ["Æ"] = "AE", ["Ç"] = "C",
  ["È"] = "E", ["É"] = "E", ["Ê"] = "E", ["Ë"] = "E", ["Ì"] = "I", ["Í"] = "I", ["Î"] = "I", ["Ï"] = "I",
  ["Ñ"] = "N", ["Ò"] = "O", ["Ó"] = "O", ["Ô"] = "O", ["Õ"] = "O", ["Ö"] = "O", ["Ø"] = "O", ["Ù"] = "U",
  ["Ú"] = "U", ["Û"] = "U", ["Ü"] = "U", ["Ý"] = "Y", ["ß"] = "SS",
  ["à"] = "A", ["á"] = "A", ["â"] = "A", ["ã"] = "A", ["ä"] = "A", ["å"] = "A", ["æ"] = "AE", ["ç"] = "C",
  ["è"] = "E", ["é"] = "E", ["ê"] = "E", ["ë"] = "E", ["ì"] = "I", ["í"] = "I", ["î"] = "I", ["ï"] = "I",
  ["ñ"] = "N", ["ò"] = "O", ["ó"] = "O", ["ô"] = "O", ["õ"] = "O", ["ö"] = "O", ["ø"] = "O", ["ù"] = "U",
  ["ú"] = "U", ["û"] = "U", ["ü"] = "U", ["ý"] = "Y", ["ÿ"] = "Y",
}

-- The name as the alphabets can draw it: capitals, digits and a little
-- punctuation; anything else becomes a space. Runs of spaces collapse.
function upperName(name)
  local s = tostring(name or "")
  s = s:gsub("[\192-\223][\128-\191]", function(c) return FOLD[c] or " " end)
  s = s:gsub("[\224-\247][\128-\191]+", " ")
  s = s:upper():gsub("[^A-Z0-9&%-%.'!%?/%+ ]", " ")
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return s
end

-- A name the player typed, made storable: trimmed, 1..NAME_MAX characters
-- (UTF-8 aware), control characters gone. "" gives the default.
function cleanName(name)
  local s = tostring(name or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  if s == "" then return DEFAULT_NAME end
  local out, n = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    n = n + 1
    if n > NAME_MAX then break end
    out[#out + 1] = ch
  end
  return (table.concat(out):gsub("%s+$", ""))
end

-- The initials of the name's significant words, up to three:
-- "Solar Exploration Agency" → "SEA". A single short word (≤ 4) is kept whole
-- ("NASA"); a single long one gives its first letter.
function monogram(name)
  local up = upperName(name)
  local words = {}
  for w in up:gmatch("[^ %-/]+") do
    local bare = w:gsub("[^A-Z0-9]", "")
    if bare ~= "" and not STOP[bare:lower()] then words[#words + 1] = bare end
  end
  if #words == 0 then return "A" end
  if #words == 1 then
    local w = words[1]
    if #w <= 4 then return w end
    return w:sub(1, 1)
  end
  local m = ""
  for i = 1, math.min(3, #words) do m = m .. words[i]:sub(1, 1) end
  return m
end

-- A stable 31-bit hash of the name (case and spacing don't matter).
function hashName(name)
  local s = upperName(name)
  local h = 2166136261
  for i = 1, #s do
    h = (h * 16777619) % 4294967296
    h = (h + s:byte(i) * 2654435761) % 4294967296
    h = (h - math.floor(h / 65536) * 65536) * 65536 % 4294967296 + math.floor(h / 65536)  -- rotate 16
  end
  return h % 2147483647
end

-- A small seeded generator (deterministic on every machine and in luajit).
local function lcg(seed)
  local s = math.floor(seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

local function pick(rnd, list) return list[math.floor(rnd() * #list) + 1] end

local function copy_rgb(c) return { c[1], c[2], c[3] } end

-- The generated spec for a name. The same name always gives the same emblem;
-- `seed` (the ↻ steps it) picks another from the same name.
function specFor(name, seed)
  seed = math.floor(seed or hashName(name))
  local rnd = lcg(seed * 7 + 13)
  rnd(); rnd()
  local pi = math.floor(rnd() * #PALETTES) + 1
  local p = PALETTES[pi]
  return {
    v = 1, seed = seed,
    shape = pick(rnd, SHAPES), motif = pick(rnd, MOTIFS), font = (rnd() < 0.62) and "stencil" or "label",
    mono = monogram(name), palIndex = pi,
    pal = { bg = copy_rgb(p.bg), ring = copy_rgb(p.ring), fg = copy_rgb(p.fg), accent = copy_rgb(p.accent) },
  }
end

-- ↻: the next emblem for the same name.
function regenerate(spec, name)
  local s = (spec and spec.seed) or hashName(name)
  return specFor(name, (s + 7919) % 2147483647)
end

local function index_of(list, v)
  for i, x in ipairs(list) do if x == v then return i end end
  return 1
end

local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end
copySpec = deep

-- ◂ ▸ on one of the panel's steppers. A palette step replaces all four colours
-- (the colour pickers then edit from there).
function tweak(spec, field, dir)
  local s = deep(spec)
  dir = (dir or 1) < 0 and -1 or 1
  if field == "shape" then
    s.shape = SHAPES[(index_of(SHAPES, s.shape) - 1 + dir) % #SHAPES + 1]
  elseif field == "motif" then
    s.motif = MOTIFS[(index_of(MOTIFS, s.motif) - 1 + dir) % #MOTIFS + 1]
  elseif field == "font" then
    s.font = FONTS[(index_of(FONTS, s.font) - 1 + dir) % #FONTS + 1]
  elseif field == "pal" then
    local i = ((s.palIndex or 1) - 1 + dir) % #PALETTES + 1
    local p = PALETTES[i]
    s.palIndex = i
    s.pal = { bg = copy_rgb(p.bg), ring = copy_rgb(p.ring), fg = copy_rgb(p.fg), accent = copy_rgb(p.accent) }
  end
  return s
end

function setColour(spec, slot, c)
  local s = deep(spec)
  if s.pal and s.pal[slot] and type(c) == "table" then
    s.pal[slot] = { math.max(0, math.min(1, c[1] or c.r or 0)), math.max(0, math.min(1, c[2] or c.g or 0)),
                    math.max(0, math.min(1, c[3] or c.b or 0)) }
    s.palIndex = nil
  end
  return s
end

-- WCAG relative luminance and contrast ratio (1..21).
local function lin(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
function luminance(c) return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3]) end
function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

-- Is a palette readable? The monogram on the field and the name on the band
-- must read (3:1, the large-text rule); the accent must show on the field.
function paletteOk(p)
  if contrast(p.fg, p.bg) < 3.0 then return false, "the monogram doesn't stand out from the field" end
  if contrast(p.ring, p.bg) < 3.0 then return false, "the band is too close to the field" end
  if contrast(p.accent, p.bg) < 1.6 then return false, "the accent disappears into the field" end
  return true
end

-- A spec from the save (or anywhere): every field checked, anything missing
-- or wrong filled from the generated spec for that name.
function clean(t, name)
  local base = specFor(name or DEFAULT_NAME, type(t) == "table" and tonumber(t.seed) or nil)
  if type(t) ~= "table" then return base end
  local s = deep(base)
  local function one_of(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
  if one_of(SHAPES, t.shape) then s.shape = t.shape end
  if one_of(MOTIFS, t.motif) then s.motif = t.motif end
  if one_of(FONTS, t.font) then s.font = t.font end
  if type(t.mono) == "string" then
    local m = upperName(t.mono):gsub("[^A-Z0-9&]", ""):sub(1, 4)
    if m ~= "" then s.mono = m end
  end
  if type(t.palIndex) == "number" and PALETTES[t.palIndex] then s.palIndex = t.palIndex else s.palIndex = nil end
  if type(t.pal) == "table" then
    for _, k in ipairs({ "bg", "ring", "fg", "accent" }) do
      local c = t.pal[k]
      if type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
        s.pal[k] = { math.max(0, math.min(1, c[1])), math.max(0, math.min(1, c[2])), math.max(0, math.min(1, c[3])) }
      end
    end
  end
  if type(t.image) == "string" and t.image:match("^user://emblems/[^/]+%.[%a]+$") and not t.image:find("%.%.") then
    s.image = t.image
  end
  return s
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE RASTERISER
-- ════════════════════════════════════════════════════════════════════════════
--
-- The emblem is drawn with the engine's image.* calls (docs/lua-api.md
-- `image`), in design units — a 256-unit square for the emblem, 512×341 for
-- the flag — scaled to the picture. Every shape is a circle, a ring or a
-- polygon (curves cut into short straight edges; the letters are outlines,
-- tools/gen_emblem_glyphs.py), and the engine fills each with a smooth edge,
-- so nothing here loops over pixels: an emblem costs a few milliseconds where
-- the old signed-distance rasteriser in Lua cost 50–200.
--
-- Two effects image.* has no call for are built from what it has:
--
--   * CLIPPING. A motif is drawn into a picture of its own, cut back with
--     transparent fills, row by row, to an outline a little OUTSIDE its
--     field, and laid on the emblem; then the field's margin and the border
--     are painted again over the cut. The smooth edge the player sees is the
--     margin's own, exactly where the clip was.
--   * WEAR (the painted-metal mottling) multiplies every pixel. A black layer
--     laid over by its alpha multiplies exactly, so every colour is drawn a
--     touch brighter (the pen's gain) and a layer of noise darkens it back;
--     the worn flecks are a faint white. The noise is two small tiles worked
--     out once in Lua and laid as tiles, cut to the emblem's outline.
--
-- Offline (the luajit tests and the tools) the same calls run on
-- tests/lib/image_shim.lua, a Lua port of the engine's image.*, handed in as
-- the global `image`.

local sqrt, floor, ceil, abs, min, max, cos, sin, atan2, pi =
  math.sqrt, math.floor, math.ceil, math.abs, math.min, math.max, math.cos, math.sin, math.atan2 or math.atan, math.pi
local acos = math.acos
local char, unpack = string.char, unpack or table.unpack

-- TIME-SLICING. A build run inside a coroutine (the service's jobs) gives the
-- frame back whenever it has worked SLICE.budget ms, so no build ever stops
-- the game; called plainly (the tests, the tools) it runs straight through.
-- A build is a few ms now, so this mostly matters for a custom picture's
-- decode and the wear noise worked out the first time.
SLICE = { budget = nil, t0 = 0, work = 0 }
local function now_ms()
  if app and app.wallClock then return app.wallClock() * 1000 end
  return os.clock() * 1000
end
local function step()
  if SLICE.budget then
    local t = now_ms()
    if t - SLICE.t0 > SLICE.budget then
      SLICE.work = SLICE.work + (t - SLICE.t0)
      coroutine.yield()
      SLICE.t0 = now_ms()
    end
  end
end

-- ── the pen: design units onto a picture ────────────────────────────────────
-- { img, k = pixels per design unit, gain = what every colour is scaled by
-- (the wear darkens it back) }

local function pen(img, k, gain) return { img = img, k = k, gain = gain or 1 } end

local function rgb(cv, c)
  local g = cv.gain
  if g == 1 then return c[1], c[2], c[3] end
  return min(1, c[1] * g), min(1, c[2] * g), min(1, c[3] * g)
end

local function p_circle(cv, x, y, r, col, a)
  local k = cv.k
  local cr, cg, cb = rgb(cv, col)
  cv.img:circle(x * k, y * k, r * k, cr, cg, cb, a or 1)
end

-- the ring between radii r0 and r1
local function p_band(cv, x, y, r0, r1, col, a)
  local k = cv.k
  local cr, cg, cb = rgb(cv, col)
  cv.img:ring(x * k, y * k, (r0 + r1) * 0.5 * k, (r1 - r0) * k, cr, cg, cb, a or 1)
end

local function p_poly(cv, pts, col, a)
  if not pts or #pts < 6 then return end
  local k = cv.k
  local s = {}
  for i = 1, #pts do s[i] = pts[i] * k end
  local cr, cg, cb = rgb(cv, col)
  cv.img:polygon(s, cr, cg, cb, a or 1)
end

-- ── outlines (flat lists { x1, y1, x2, y2, … } in design units) ─────────────

local function arc_into(out, cx, cy, r, a0, a1, n)
  if not n then
    -- short enough edges that the chord strays under 0.05 units from the arc
    local step_a = 2 * sqrt(0.1 / max(r, 0.1))
    n = max(2, min(400, ceil(abs(a1 - a0) / step_a)))
  end
  for i = 0, n do
    local a = a0 + (a1 - a0) * i / n
    out[#out + 1] = cx + cos(a) * r
    out[#out + 1] = cy + sin(a) * r
  end
  return out
end

local function circle_pts(cx, cy, r)
  local n = max(16, min(240, ceil(2 * pi / (2 * sqrt(0.1 / max(r, 0.1))))))
  local out = {}
  for i = 0, n - 1 do
    local a = i * 2 * pi / n
    out[#out + 1] = cx + cos(a) * r
    out[#out + 1] = cy + sin(a) * r
  end
  return out
end

-- Several closed outlines as one even-odd polygon: each one is visited from
-- the first one's first corner and left back to it, so the joins cancel.
local function evenodd(...)
  local cs = { ... }
  local out = {}
  local fx, fy
  for ci = 1, #cs do
    local c = cs[ci]
    if c and #c >= 6 then
      for i = 1, #c do out[#out + 1] = c[i] end
      out[#out + 1], out[#out + 2] = c[1], c[2]          -- closed
      if fx then out[#out + 1], out[#out + 2] = fx, fy   -- back to the anchor
      else fx, fy = c[1], c[2] end
    end
  end
  return out
end

local function area2(p)
  local s, n = 0, #p / 2
  for i = 1, n do
    local j = (i == n) and 1 or i + 1
    s = s + p[2 * i - 1] * p[2 * j] - p[2 * j - 1] * p[2 * i]
  end
  return s
end

-- Keep the part of a polygon where nx·x + ny·y ≤ d (Sutherland–Hodgman).
local function clip_half(p, nx, ny, d)
  local out = {}
  local n = #p / 2
  if n < 3 then return out end
  local px, py = p[2 * n - 1], p[2 * n]
  local pin = nx * px + ny * py <= d
  for i = 1, n do
    local x, y = p[2 * i - 1], p[2 * i]
    local cin = nx * x + ny * y <= d
    if cin ~= pin then
      local a, b = nx * px + ny * py - d, nx * x + ny * y - d
      local t = a / (a - b)
      out[#out + 1] = px + (x - px) * t
      out[#out + 1] = py + (y - py) * t
    end
    if cin then out[#out + 1] = x; out[#out + 1] = y end
    px, py, pin = x, y, cin
  end
  return out
end

-- A polygon (any) cut to a CONVEX window.
local function clip_convex(p, win)
  local s = area2(win) > 0 and 1 or -1
  local n = #win / 2
  for i = 1, n do
    local j = (i == n) and 1 or i + 1
    local ax, ay, bx, by = win[2 * i - 1], win[2 * i], win[2 * j - 1], win[2 * j]
    local ex, ey = bx - ax, by - ay
    local nx, ny = ey * s, -ex * s                       -- outward
    p = clip_half(p, nx, ny, nx * ax + ny * ay)
    if #p < 6 then return p end
  end
  return p
end

local function box_pts(x0, y0, x1, y1) return { x0, y0, x1, y0, x1, y1, x0, y1 } end

-- An outline moved out by d (in by -d), as a distance field's level set: a
-- corner the move opens is rounded, one it closes is mitred.
local function offset(p, d)
  -- drop repeated corners
  local q = {}
  local n0 = #p / 2
  for i = 1, n0 do
    local j = (i == n0) and 1 or i + 1
    if abs(p[2 * i - 1] - p[2 * j - 1]) + abs(p[2 * i] - p[2 * j]) > 1e-9 then
      q[#q + 1], q[#q + 2] = p[2 * i - 1], p[2 * i]
    end
  end
  local n = #q / 2
  local s = area2(q) > 0 and 1 or -1
  local out = {}
  for i = 1, n do
    local h = (i == 1) and n or i - 1
    local j = (i == n) and 1 or i + 1
    local x, y = q[2 * i - 1], q[2 * i]
    local e1x, e1y = x - q[2 * h - 1], y - q[2 * h]
    local e2x, e2y = q[2 * j - 1] - x, q[2 * j] - y
    local l1, l2 = sqrt(e1x * e1x + e1y * e1y), sqrt(e2x * e2x + e2y * e2y)
    local n1x, n1y = e1y / l1 * s, -e1x / l1 * s
    local n2x, n2y = e2y / l2 * s, -e2x / l2 * s
    local cross = (e1x * e2y - e1y * e2x) * s            -- > 0: a convex corner
    if (cross > 0) == (d > 0) and abs(cross) > 1e-12 then
      local a0, a1 = atan2(n1y * d, n1x * d), atan2(n2y * d, n2x * d)
      local da = a1 - a0
      if da > pi then da = da - 2 * pi elseif da < -pi then da = da + 2 * pi end
      local m = max(1, ceil(abs(da) / (pi / 16)))
      for t = 0, m do
        local a = a0 + da * t / m
        out[#out + 1] = x + cos(a) * abs(d)
        out[#out + 1] = y + sin(a) * abs(d)
      end
    else
      local den = 1 + n1x * n2x + n1y * n2y
      if den < 0.1 then
        out[#out + 1], out[#out + 2] = x + n1x * d, y + n1y * d
        out[#out + 1], out[#out + 2] = x + n2x * d, y + n2y * d
      else
        out[#out + 1] = x + (n1x + n2x) / den * d
        out[#out + 1] = y + (n1y + n2y) / den * d
      end
    end
  end
  return out
end

-- A rounded box: centre, half sizes, corner radius.
local function rbox_pts(cx, cy, hw, hh, rr)
  local out = {}
  local cs = { { cx + hw - rr, cy + hh - rr, 0 }, { cx - hw + rr, cy + hh - rr, pi / 2 },
               { cx - hw + rr, cy - hh + rr, pi }, { cx + hw - rr, cy - hh + rr, 3 * pi / 2 } }
  for _, c in ipairs(cs) do arc_into(out, c[1], c[2], rr, c[3], c[3] + pi / 2, 12) end
  return out
end

-- Circle A less circle B.
local function crescent(ax, ay, ar, bx, by, br)
  local dx, dy = bx - ax, by - ay
  local d = sqrt(dx * dx + dy * dy)
  if d >= ar + br then return circle_pts(ax, ay, ar) end
  if d + ar <= br then return nil end
  if d + br <= ar then return evenodd(circle_pts(ax, ay, ar), circle_pts(bx, by, br)) end
  local phi = atan2(dy, dx)
  local al = acos(max(-1, min(1, (d * d + ar * ar - br * br) / (2 * d * ar))))
  local be = acos(max(-1, min(1, (d * d + br * br - ar * ar) / (2 * d * br))))
  local out = {}
  arc_into(out, ax, ay, ar, phi + al, phi + 2 * pi - al)       -- A's rim outside B
  arc_into(out, bx, by, br, phi + pi + be, phi + pi - be)      -- B's rim inside A, back
  return out
end

-- An ellipse's outline as a band wd wide (its two offset curves).
local function ellipse_band(cx, cy, a, b, rot, wd)
  local hw = wd * 0.5
  local c, s = cos(rot), sin(rot)
  local n = 160
  local outer, inner = {}, {}
  for i = 0, n - 1 do
    local t = i / n * 2 * pi
    local ct, st = cos(t), sin(t)
    local ux, uy = a * ct, b * st
    local nx, ny = b * ct, a * st
    local l = sqrt(nx * nx + ny * ny)
    nx, ny = nx / l * hw, ny / l * hw
    local ox, oy, ix, iy = ux + nx, uy + ny, ux - nx, uy - ny
    outer[2 * i + 1], outer[2 * i + 2] = cx + ox * c - oy * s, cy + ox * s + oy * c
    inner[2 * i + 1], inner[2 * i + 2] = cx + ix * c - iy * s, cy + ix * s + iy * c
  end
  return evenodd(outer, inner)
end

-- A star's points as a polygon.
local function star_pts(cx, cy, R, r, n, rot)
  local pts = {}
  for i = 0, 2 * n - 1 do
    local a = rot + i * pi / n
    local rr = (i % 2 == 0) and R or r
    pts[#pts + 1] = cx + cos(a) * rr
    pts[#pts + 1] = cy + sin(a) * rr
  end
  return pts
end

local function rot_pts(pts, cx, cy, ang, sx, sy, ox, oy)
  local c, s = cos(ang), sin(ang)
  local out = {}
  for i = 1, #pts, 2 do
    local x, y = pts[i] * (sx or 1), pts[i + 1] * (sy or 1)
    out[i] = cx + (ox or 0) + x * c - y * s
    out[i + 1] = cy + (oy or 0) + x * s + y * c
  end
  return out
end

-- ── rows: cutting a picture to an outline ───────────────────────────────────
-- The pixel rows' spans inside the union of some outlines (pixel centres,
-- even-odd per outline), as rows[r] = { x0, x1, x0, x1, … } merged.
local function spans_of(outlines, k, H)
  local rows = {}
  for _, p in ipairs(outlines) do
    local hits = {}
    local n = #p / 2
    for i = 1, n do
      local j = (i == n) and 1 or i + 1
      local x1, y1, x2, y2 = p[2 * i - 1] * k, p[2 * i] * k, p[2 * j - 1] * k, p[2 * j] * k
      if y1 ~= y2 then
        local ya, yb = min(y1, y2), max(y1, y2)
        for r = max(0, ceil(ya - 0.5)), min(H - 1, ceil(yb - 0.5) - 1) do
          local t = hits[r]
          if not t then t = {}; hits[r] = t end
          t[#t + 1] = x1 + (r + 0.5 - y1) / (y2 - y1) * (x2 - x1)
        end
      end
    end
    for r, t in pairs(hits) do
      table.sort(t)
      local row = rows[r]
      if not row then row = {}; rows[r] = row end
      for i = 1, #t - 1, 2 do row[#row + 1] = { t[i], t[i + 1] } end
    end
  end
  for r, row in pairs(rows) do
    table.sort(row, function(a, b) return a[1] < b[1] end)
    local m = {}
    for _, s in ipairs(row) do
      if #m > 0 and s[1] <= m[#m] then
        if s[2] > m[#m] then m[#m] = s[2] end
      else m[#m + 1] = s[1]; m[#m + 1] = s[2] end
    end
    rows[r] = m
  end
  return rows
end

-- Make everything outside the spans transparent (hard edged: it is always
-- covered by an opaque margin, or is a faint overlay).
local function cut_outside(img, rows)
  local W, H = img.width, img.height
  local empty0 = nil
  for r = 0, H do
    local m = (r < H) and rows[r] or nil
    if r < H and not m then
      empty0 = empty0 or r
    else
      if empty0 then img:fill(0, empty0, W, r - empty0, 0, 0, 0, 0); empty0 = nil end
      if m then
        local x = 0
        for i = 1, #m, 2 do
          if m[i] > x then img:fill(x, r, m[i] - x, 1, 0, 0, 0, 0) end
          x = max(x, m[i + 1])
        end
        if x < W then img:fill(x, r, W - x, 1, 0, 0, 0, 0) end
      end
    end
  end
end

-- ── the alphabets ───────────────────────────────────────────────────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64V = {}
for i = 1, 64 do B64V[B64:byte(i)] = i - 1 end
local glyph_cache = { stencil = {}, label = {} }

-- A glyph as { adv, cs = { contour, … } }: x from the pen, y down from the
-- baseline, in units where a capital is GLYPH_CAP tall.
local function glyph(face, ch)
  local cache = glyph_cache[face] or glyph_cache.label
  local g = cache[ch]
  if g ~= nil then return g or nil end
  local src = GLYPH_DATA and GLYPH_DATA[face] and GLYPH_DATA[face][ch]
  if not src then cache[ch] = false return nil end
  local cs = {}
  for i = 2, #src do
    local s, c = src[i], {}
    for j = 1, #s - 3, 4 do
      c[#c + 1] = (B64V[s:byte(j)] * 64 + B64V[s:byte(j + 1)]) / GLYPH_RES - GLYPH_OX
      c[#c + 1] = (B64V[s:byte(j + 2)] * 64 + B64V[s:byte(j + 3)]) / GLYPH_RES - GLYPH_OY
    end
    cs[#cs + 1] = c
  end
  g = { adv = src[1], cs = cs }
  cache[ch] = g
  return g
end

-- The width of a string in glyph units (letter-spacing `track` units).
local function text_width(face, s, track)
  local wsum = 0
  local data = GLYPH_DATA and GLYPH_DATA[face]
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g = glyph(face, ch)
    wsum = wsum + (g and g.adv or (data and data.space or 10)) + (i < #s and (track or 0) or 0)
  end
  return wsum
end
textWidth = text_width

-- One glyph placed in design space: its pen's baseline centre at (ox, oy),
-- the advance along (tx, ty), `scale` design units per glyph unit; drawn
-- (thickened by `grow` when given: its edges stroked that wide each side).
local function draw_glyph(cv, g, ox, oy, tx, ty, scale, col, alpha, grow)
  local dx, dy = -ty, tx         -- "down" in the glyph
  local h = g.adv * 0.5
  local cs = {}
  for ci, c in ipairs(g.cs) do
    local t = {}
    for i = 1, #c, 2 do
      local u, v = c[i] - h, c[i + 1]
      t[i] = ox + (u * tx + v * dx) * scale
      t[i + 1] = oy + (u * ty + v * dy) * scale
    end
    cs[ci] = t
  end
  p_poly(cv, evenodd(unpack(cs)), col, alpha)
  if grow and grow > 0 then
    local k = cv.k
    local cr, cg, cb = rgb(cv, col)
    local wd = 2 * grow * k
    local img = cv.img
    for _, t in ipairs(cs) do
      local n = #t / 2
      for i = 1, n do
        local j = (i == n) and 1 or i + 1
        img:line(t[2 * i - 1] * k, t[2 * i] * k, t[2 * j - 1] * k, t[2 * j] * k, wd, cr, cg, cb, 1)
      end
    end
  end
end

-- Paint a string along a straight baseline centred at (cx, by), cap height
-- `cap` design units. `grow` thickens (an outline pass). Returns the width.
local function paint_text(cv, face, s, cx, by, cap, col, track, grow, alpha)
  local scale = cap / GLYPH_CAP
  local wd = text_width(face, s, track or 0) * scale
  local pen_x = cx - wd * 0.5
  local data = GLYPH_DATA[face]
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g = glyph(face, ch)
    local adv = (g and g.adv or data.space) * scale
    if g then draw_glyph(cv, g, pen_x + adv * 0.5, by, 1, 0, scale, col, alpha, grow) end
    pen_x = pen_x + adv + (track or 0) * scale
  end
  return wd
end

-- Paint a string round an arc: centre (cx, cy), the baseline at radius r, cap
-- height `cap`, centred on angle `at` (radians, screen: -pi/2 is the top).
-- `top` = true reads clockwise with the letters' tops outward (the top of a
-- patch); false reads anticlockwise with the tops inward (its bottom).
local function paint_arc_text(cv, face, s, cx, cy, r, cap, at, top, col, track, alpha)
  local scale = cap / GLYPH_CAP
  local data = GLYPH_DATA[face]
  local wd = text_width(face, s, track or 0) * scale
  -- the arc measured at the letters' middle, so spacing looks even
  local rm = top and (r + cap * 0.5) or (r - cap * 0.5)
  local span = wd / rm
  local dir = top and 1 or -1
  local a = at - dir * span * 0.5
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g = glyph(face, ch)
    local adv = (g and g.adv or data.space) * scale
    local am = a + dir * (adv * 0.5) / rm
    if g then
      local ux, uy = cos(am), sin(am)            -- outward
      local tx, ty
      if top then tx, ty = -uy, ux else tx, ty = uy, -ux end
      draw_glyph(cv, g, cx + ux * r, cy + uy * r, tx, ty, scale, col, alpha)
    end
    a = a + dir * (adv + (track or 0) * scale) / rm
  end
  return span
end

-- Fit a string's cap height so it spans at most `maxw` design units.
local function fit_cap(face, s, want, maxw, track)
  local w = text_width(face, s, track or 0)
  if w <= 0 then return want end
  return min(want, maxw / w * GLYPH_CAP)
end

-- ── motifs ──────────────────────────────────────────────────────────────────
-- Each draws into the motif's own layer L (centre cx, cy, radius R), which
-- is cut to the field afterwards; what must NOT be cut (the orbit's
-- satellite, the rocket's window) goes into `later`, drawn on the emblem
-- after the cut. The random draws come in the old order, so a seed gives the
-- emblem it always gave.

local function motif_orbit(L, later, P, cx, cy, R, rnd)
  local tilt = -0.42 + (rnd() - 0.5) * 0.25
  local a, b = R * 0.98, R * 0.36
  local wd = max(2.2, R * 0.045)
  p_poly(L, ellipse_band(cx, cy + R * 0.04, a, b, tilt, wd), P.fg)
  -- the satellite on it, upper right
  local t = -0.55
  local sx = cx + cos(t) * a * cos(tilt) - sin(t) * b * sin(tilt)
  local sy = cy + R * 0.04 + cos(t) * a * sin(tilt) + sin(t) * b * cos(tilt)
  later[#later + 1] = function(cv) p_circle(cv, sx, sy, wd * 2.1, P.accent) end
  -- a few stars in the field
  for i = 1, 7 do
    local ang, rr = rnd() * 2 * pi, R * (0.45 + rnd() * 0.5)
    local x, y = cx + cos(ang) * rr, cy + sin(ang) * rr * 0.9
    local s = R * (0.025 + rnd() * 0.025)
    p_poly(L, star_pts(x, y, s * 2.2, s * 0.7, 4, 0), P.fg, 0.9)
  end
end

local function motif_rocket(L, later, P, cx, cy, R, rnd)
  local ang = 0.30 + (rnd() - 0.5) * 0.12      -- leaning a little to the right
  local Lr = R * 1.62
  local body = {
    0, -0.50,  0.07, -0.40,  0.10, -0.28,  0.10, 0.22,  0.19, 0.36,  0.19, 0.45,  0.09, 0.40,
    0.06, 0.46,  -0.06, 0.46,  -0.09, 0.40,  -0.19, 0.45,  -0.19, 0.36,  -0.10, 0.22,  -0.10, -0.28,
    -0.07, -0.40,
  }
  for i = 1, #body do body[i] = body[i] * Lr end
  local ox, oy = cx + R * 0.02, cy - R * 0.08
  local pts = rot_pts(body, ox, oy, ang)
  -- the exhaust trail: a swelling arc from the lower left
  local tr = crescent(cx + R * 1.55, cy + R * 1.75, R * 2.05, cx + R * 1.68, cy + R * 1.62, R * 2.02)
  if tr then p_poly(L, clip_convex(tr, box_pts(cx - R, cy - R, cx + R, cy + R)), P.accent) end
  p_poly(L, pts, P.fg)
  -- its window
  local wx, wy = ox + sin(ang) * Lr * 0.30, oy - cos(ang) * Lr * 0.30
  later[#later + 1] = function(cv) p_circle(cv, wx, wy, Lr * 0.045, P.bg) end
  for i = 1, 5 do
    local a2, rr = rnd() * 2 * pi, R * (0.5 + rnd() * 0.45)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    p_circle(L, x, y, R * (0.018 + rnd() * 0.018), P.fg, 0.9)
  end
end

local function motif_star(L, later, P, cx, cy, R, rnd)
  local n = (rnd() < 0.5) and 4 or 5
  local rot = -pi / 2
  p_poly(L, star_pts(cx, cy - R * 0.02, R * 0.98, R * (n == 4 and 0.30 or 0.40), n, rot), P.accent)
  -- a scatter of small stars round it
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.62 + rnd() * 0.3)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    local s = R * (0.03 + rnd() * 0.02)
    p_poly(L, star_pts(x, y, s * 2, s * 0.8, 5, -pi / 2), P.fg, 0.9)
  end
end

local function motif_planet(L, later, P, cx, cy, R, rnd)
  local px, py, pr = cx + R * 0.30, cy - R * 0.30, R * 0.38
  local tilt = -0.35 + (rnd() - 0.5) * 0.2
  local SHADE = { 0, 0, 0 }
  p_circle(L, px, py, pr, P.accent)
  -- terminator shade: the lower left of the disc a touch darker
  local shade = crescent(px, py, pr, px + pr * 0.35, py - pr * 0.35, pr * 1.05)
  p_poly(L, shade, SHADE, 0.22)
  -- the ring: drawn whole, then the disc's top half again over its back
  p_poly(L, ellipse_band(px, py, pr * 1.75, pr * 0.42, tilt, max(2.0, R * 0.04)), P.fg)
  local c, s = cos(tilt), sin(tilt)
  -- the half-plane above the ring's axis: (x - px)·s − (y − py)·c ≤ 0
  local d = px * s - py * c
  p_poly(L, clip_half(circle_pts(px, py, pr), s, -c, d), P.accent)
  if shade then p_poly(L, clip_half(shade, s, -c, d), SHADE, 0.22) end
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.45 + rnd() * 0.5)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    if (x - px) ^ 2 + (y - py) ^ 2 > (pr * 1.9) ^ 2 then
      p_circle(L, x, y, R * (0.016 + rnd() * 0.016), P.fg, 0.9)
    end
  end
end

local function motif_swoosh(L, later, P, cx, cy, R, rnd)
  -- two crescents crossing under the monogram: the agency's "vector"
  local box = box_pts(cx - R, cy - R, cx + R, cy + R)
  local s1 = crescent(cx - R * 0.10, cy + R * 1.98, R * 1.55, cx - R * 0.0, cy + R * 2.10, R * 1.58)
  if s1 then p_poly(L, clip_convex(s1, box), P.accent) end
  local s2 = crescent(cx + R * 0.15, cy - R * 2.0, R * 1.55, cx + R * 0.05, cy - R * 2.12, R * 1.6)
  if s2 then p_poly(L, clip_convex(s2, box), P.fg) end
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.55 + rnd() * 0.4)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    p_circle(L, x, y, R * (0.016 + rnd() * 0.016), P.fg, 0.9)
  end
end

local MOTIF_FN = { orbit = motif_orbit, rocket = motif_rocket, star = motif_star, planet = motif_planet,
                   swoosh = motif_swoosh }

-- ── the monogram ────────────────────────────────────────────────────────────

-- The monogram centred at (cx, cy) inside a box maxw × maxh, knocked out of
-- what is behind it with an outline in the field colour.
local function paint_monogram(cv, P, face, mono, cx, cy, maxw, maxh, outline)
  local track = (face == "stencil") and 2 or 3
  local cap = fit_cap(face, mono, maxh, maxw, track)
  local by = cy + cap * 0.5
  if outline and outline > 0 then
    paint_text(cv, face, mono, cx, by, cap, P.bg, track, outline)
  end
  paint_text(cv, face, mono, cx, by, cap, P.fg, track)
  return cap
end

-- ── shapes ──────────────────────────────────────────────────────────────────

local DARK = { 0.05, 0.05, 0.055 }

local function shield_pts(cx, cy, W, H)
  -- flat top with clipped corners, straight flanks, curved to a point
  local pts = {}
  local hw = W * 0.5
  local top, mid, bot = cy - H * 0.5, cy + H * 0.02, cy + H * 0.5
  local cut = W * 0.07
  local function add(x, y) pts[#pts + 1] = x; pts[#pts + 1] = y end
  add(cx - hw + cut, top); add(cx + hw - cut, top); add(cx + hw, top + cut)
  add(cx + hw, mid)
  for i = 1, 10 do
    local t = i / 10
    local x = cx + hw * (1 - t) ^ 1.15 * (1 - 0.15 * t)
    local y = mid + (bot - mid) * (1 - (1 - t) ^ 2.0)
    add(x, y)
  end
  for i = 9, 1, -1 do
    local t = i / 10
    local x = cx - hw * (1 - t) ^ 1.15 * (1 - 0.15 * t)
    local y = mid + (bot - mid) * (1 - (1 - t) ^ 2.0)
    add(x, y)
  end
  add(cx - hw, mid)
  add(cx - hw, top + cut)
  return pts
end

local function hex_pts(cx, cy, r)
  local pts = {}
  for i = 0, 5 do
    local a = -pi / 2 + i * pi / 3
    pts[#pts + 1] = cx + cos(a) * r
    pts[#pts + 1] = cy + sin(a) * r
  end
  return pts
end

local function chevron_pts(cx, cy, s)
  return { cx, cy - s * 0.98, cx + s * 0.86, cy + s * 0.80, cx + s * 0.80, cy + s * 0.92,
           cx, cy + s * 0.52, cx - s * 0.80, cy + s * 0.92, cx - s * 0.86, cy + s * 0.80 }
end

-- Fit a name on one or two arcs: the top half reads clockwise, the bottom
-- half anticlockwise. Returns top, bottom (bottom may be nil).
local function split_name(up)
  if #up <= 18 then return up, nil end
  local best, bi = math.huge, nil
  for i = 2, #up - 1 do
    if up:sub(i, i) == " " then
      local d = abs(i - #up * 0.58)
      if d < best then best, bi = d, i end
    end
  end
  if not bi then return up, nil end
  return up:sub(1, bi - 1), up:sub(bi + 1)
end
splitName = split_name

-- A motif in its own layer, cut to `coarse` (an outline just outside its
-- field, inside what `margin` paints), laid on the emblem; then `margin()`
-- paints the field's edge and the border again over the cut, and the motif's
-- uncut pieces go on top.
local function motif_in(cv, motif, P, rnd, cx, cy, R, coarse, margin)
  local size = cv.img.width
  local T = PROF and now_ms
  local t0 = T and T()
  local L = pen(image.new(size, size), cv.k, cv.gain)
  local later = {}
  motif(L, later, P, cx, cy, R, rnd)
  if T then PROF.motif = (PROF.motif or 0) + T() - t0; t0 = T() end
  step()
  cut_outside(L.img, spans_of({ coarse }, cv.k, size))
  if T then PROF.cut = (PROF.cut or 0) + T() - t0; t0 = T() end
  cv.img:draw(L.img, 0, 0)
  margin()
  if T then PROF.lay = (PROF.lay or 0) + T() - t0 end
  for _, f in ipairs(later) do f(cv) end
end

-- The emblem itself, drawn in its 256-unit design square. Returns the
-- outlines of its body (what the wear covers).
local function draw_emblem(cv, spec, name)
  local P = spec.pal
  local rnd = lcg((spec.seed or 1) * 31 + 7)
  local face = spec.font or "stencil"
  local mono = spec.mono or monogram(name)
  local up = upperName(name)
  local C = 128
  local motif = MOTIF_FN[spec.motif] or motif_orbit
  local shape = spec.shape
  if shape == "roundel" then
    p_circle(cv, C, C, 125.2, DARK, 0.6)
    p_circle(cv, C, C, 124, P.ring)
    p_circle(cv, C, C, 118, P.bg)
    -- the field is r 118, the motif's clip 115; cut at 120.5, under the margin
    motif_in(cv, motif, P, rnd, C, C, 112, circle_pts(C, C, 120.5), function()
      p_band(cv, C, C, 115, 119.5, P.bg)
      p_band(cv, C, C, 118, 122.5, P.ring)
    end)
    paint_monogram(cv, P, face, mono, C, C + 4, 178, #mono <= 2 and 92 or 74, 5)
    return { circle_pts(C, C, 124) }
  elseif shape == "patch" then
    p_circle(cv, C, C, 126.2, DARK, 0.6)
    p_circle(cv, C, C, 125, P.ring)
    p_band(cv, C, C, 119.4, 121.6, P.bg)
    p_circle(cv, C, C, 89, P.bg)
    p_band(cv, C, C, 85.5, 87.5, P.ring)
    -- the field is r 86, the clip 83; cut at 85.8 under the margin
    motif_in(cv, motif, P, rnd, C, C, 82, circle_pts(C, C, 85.8), function()
      p_band(cv, C, C, 83, 88.5, P.bg)
      p_band(cv, C, C, 85.5, 87.5, P.ring)
    end)
    paint_monogram(cv, P, face, mono, C, C + 3, 132, #mono <= 2 and 66 or 54, 4)
    local top, bot = split_name(up)
    local cap = 20
    -- the band's text in the field colour, sized to its arc
    local ttop = min(cap, 3.0 * 104 / max(1, text_width("label", top, 4)) * GLYPH_CAP)
    local tcap = min(cap, ttop)
    paint_arc_text(cv, "label", top, C, C, 98, tcap, -pi / 2, true, P.bg, 4)
    if bot then
      local bcap = min(cap, 2.0 * 104 / max(1, text_width("label", bot, 4)) * GLYPH_CAP)
      paint_arc_text(cv, "label", bot, C, C, 116, bcap, pi / 2, false, P.bg, 4)
      -- stars where the two halves meet
      for _, sx in ipairs({ -1, 1 }) do
        local a = pi / 2 + sx * (pi / 2 + 0.10) * 1.0
        local x, y = C + cos(a) * 107, C + sin(a) * 107
        p_poly(cv, star_pts(x, y, 7, 2.8, 5, -pi / 2), P.bg)
      end
    else
      for k = -1, 1 do
        local a = pi / 2 + k * 0.32
        local x, y = C + cos(a) * 107, C + sin(a) * 107
        p_poly(cv, star_pts(x, y, k == 0 and 9 or 6.5, k == 0 and 3.6 or 2.6, 5, -pi / 2), P.bg)
      end
    end
    return { circle_pts(C, C, 125) }
  elseif shape == "shield" then
    local pts = shield_pts(C, C + 2, 214, 246)
    p_poly(cv, offset(pts, 1.2), DARK, 0.6)
    p_poly(cv, pts, P.ring)
    local inner = offset(pts, -8)
    p_poly(cv, inner, P.bg)
    -- the chief: a band across the top in the ring colour with the name
    local chief = clip_half(inner, 0, 1, 62)
    p_poly(cv, chief, P.ring)
    -- the field is inner ∩ y > 66, the clip 3 inside it; cut at 6 in, y > 64
    local clipo = clip_half(offset(pts, -11), 0, -1, -69)
    motif_in(cv, motif, P, rnd, C, 146, 86, clip_half(offset(pts, -6), 0, -1, -64), function()
      p_poly(cv, evenodd(clip_half(offset(pts, -6.5), 0, -1, -60.5), clipo), P.bg)
      p_poly(cv, evenodd(offset(pts, -3), inner), P.ring)
      p_poly(cv, chief, P.ring)
    end)
    paint_monogram(cv, P, face, mono, C, 150, 150, #mono <= 2 and 74 or 60, 4)
    local cap = fit_cap("label", up, 22, 182, 3)
    local l1, l2 = split_name(up)
    if cap < 12 and l2 then
      -- two lines, each as large as the narrower of them allows
      local c2 = min(fit_cap("label", l1, 15, 176, 2.5), fit_cap("label", l2, 15, 176, 2.5))
      paint_text(cv, "label", l1, C, 36 + c2 * 0.5 - c2 * 0.66, c2, P.bg, 2.5)
      paint_text(cv, "label", l2, C, 36 + c2 * 0.5 + c2 * 0.66, c2, P.bg, 2.5)
    else
      local short = up
      if cap < 9.5 then short = mono; cap = fit_cap("label", short, 22, 182, 3) end
      paint_text(cv, "label", short, C, 40 + cap * 0.5, cap, P.bg, 3)
    end
    return { pts }
  elseif shape == "hex" then
    -- (a hexagon r across its corners is r·cos 30° across its flats)
    local function hexd(r, d) return hex_pts(C, C, r + d / 0.8660254) end
    p_poly(cv, offset(hex_pts(C, C, 127), 1.2), DARK, 0.6)
    p_poly(cv, hex_pts(C, C, 127), P.ring)
    p_poly(cv, hex_pts(C, C, 115), P.bg)
    local line = evenodd(hex_pts(C, C, 109), hex_pts(C, C, 106.5))
    p_poly(cv, line, P.ring, 0.9)
    -- the field is the hexagon r 106, the clip 3 inside it; cut at r 107.5
    motif_in(cv, motif, P, rnd, C, C - 10, 88, hex_pts(C, C, 107.5), function()
      p_poly(cv, evenodd(hex_pts(C, C, 111.5), hexd(106, -3)), P.bg)
      p_poly(cv, line, P.ring, 0.9)
    end)
    paint_monogram(cv, P, face, mono, C, C - 6, 150, #mono <= 2 and 72 or 58, 4)
    -- a ribbon across the lower third, over the border, with the name
    local by = 186
    local rib = { 4, by - 17, 252, by - 17, 242, by, 252, by + 17, 4, by + 17, 14, by }
    p_poly(cv, offset(rib, 1.2), DARK, 0.6)
    p_poly(cv, rib, P.ring)
    for _, sy in ipairs({ -1, 1 }) do
      local yc = by + sy * 12.5
      p_poly(cv, clip_convex(rib, box_pts(-10, yc - 0.8, 266, yc + 0.8)), P.bg, 0.8)
    end
    local short = up
    local cap = fit_cap("label", short, 16, 208, 3)
    if cap < 8.5 then short = mono; cap = fit_cap("label", short, 16, 208, 3) end
    paint_text(cv, "label", short, C, by + cap * 0.5, cap, P.bg, 3)
    return { hex_pts(C, C, 127), rib }
  elseif shape == "chevron" then
    local pts = chevron_pts(C, C + 4, 128)
    p_poly(cv, offset(pts, 1.2), DARK, 0.6)
    p_poly(cv, pts, P.ring)
    local inner = offset(pts, -7)
    p_poly(cv, inner, P.bg)
    -- the clip is 10 in; cut at 5 in, under the margin
    motif_in(cv, motif, P, rnd, C, C + 14, 74, offset(pts, -5), function()
      p_poly(cv, evenodd(offset(pts, -5.5), offset(pts, -10)), P.bg)
      p_poly(cv, evenodd(offset(pts, -2.5), inner), P.ring)
    end)
    paint_monogram(cv, P, face, mono, C, C + 30, 128, #mono <= 2 and 66 or 54, 4)
    return { pts }
  else -- "square": a rounded badge
    p_poly(cv, rbox_pts(C, C, 121.2, 121.2, 35.2), DARK, 0.6)
    p_poly(cv, rbox_pts(C, C, 120, 120, 34), P.ring)
    local inner = rbox_pts(C, C, 112, 112, 27)
    p_poly(cv, inner, P.bg)
    -- a diagonal stripe across the lower right corner in the accent: where
    -- (x + y − 2C)/√2 is 96 ± 9
    local function stripe_in(win)
      local o1, o2 = 2 * C + 87 * 1.41421356, 2 * C + 105 * 1.41421356
      local band = { o1 - 300, 300, o1 + 300, -300, o2 + 300, -300, o2 - 300, 300 }
      return clip_convex(band, win)
    end
    p_poly(cv, stripe_in(inner), P.accent)
    -- the clip is 3 inside; cut at 1 outside, under the margin
    local clipo = rbox_pts(C, C, 109, 109, 24)
    motif_in(cv, motif, P, rnd, C, C - 6, 96, rbox_pts(C, C, 113, 113, 28), function()
      p_poly(cv, evenodd(rbox_pts(C, C, 113.5, 113.5, 28.5), clipo), P.bg)
      p_poly(cv, evenodd(stripe_in(inner), stripe_in(clipo)), P.accent)
      p_poly(cv, evenodd(rbox_pts(C, C, 116.5, 116.5, 31.5), inner), P.ring)
    end)
    paint_monogram(cv, P, face, mono, C, C - 2, 176, #mono <= 2 and 88 or 68, 5)
    local short = (#up <= 26) and up or nil
    if short then
      local cap = fit_cap("label", short, 13, 150, 2.5)
      p_poly(cv, clip_convex(inner, box_pts(C - 112, 198, C + 112, 226)), P.bg, 0.85)
      paint_text(cv, "label", short, C, 212 + cap * 0.5, cap, P.fg, 2.5)
    end
    return { rbox_pts(C, C, 120, 120, 34) }
  end
end

-- ── finishing: wear ─────────────────────────────────────────────────────────

local function hash2(x, y, s)
  local h = (x * 374761393 + y * 668265263 + s * 2246822519) % 4294967296
  h = ((h - (h % 8192)) / 8192 + h * 1274126177) % 4294967296
  return (h % 65536) / 65536
end

-- The wear's noise, worked out once: a 128-unit tile of mottling (black, by
-- its alpha) with the worn flecks (white) folded in, a 64-pixel tile of
-- grain, both wrapping. The same lattices as ever.
local WEAR = nil
local FLECK = 0.6                 -- how strongly a fleck lightens
local function wear_tiles()
  if WEAR then return WEAR end
  local function lattice(n, sd)
    local L = {}
    for j = 0, n - 1 do for i = 0, n - 1 do L[j * n + i] = hash2(i, j, sd) end end
    return L
  end
  local octs = { { 4, lattice(4, 1), 0.6 }, { 16, lattice(16, 2), 0.4 }, { 32, lattice(32, 3), 0 } }
  local rows = {}
  for y = 0, 127 do
    if y % 16 == 0 then step() end
    local row = {}
    for x = 0, 127 do
      local m, fl = 0, 0
      for o = 1, 3 do
        local n, L, wgt = octs[o][1], octs[o][2], octs[o][3]
        local fx, fy = x * n / 128, y * n / 128
        local ix, iy = floor(fx), floor(fy)
        local tx, ty = fx - ix, fy - iy
        tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
        local x1, y1 = (ix + 1) % n, (iy + 1) % n
        local a, b = L[iy * n + ix], L[iy * n + x1]
        local c, d = L[y1 * n + ix], L[y1 * n + x1]
        local v = (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
        if o < 3 then m = m + v * wgt else fl = v end
      end
      -- black at 0.07·m, then white at the fleck's strength, as one pixel
      local a1 = 0.07 * m
      local a2 = fl > 0.86 and (fl - 0.86) * 0.9 * FLECK or 0
      local oa = a2 + a1 * (1 - a2)
      local grey = oa > 0 and a2 / oa or 0
      local gv = floor(grey * 255 + 0.5)
      row[#row + 1] = char(gv, gv, gv, floor(oa * 255 + 0.5))
    end
    rows[#rows + 1] = table.concat(row)
  end
  local mottle = image.fromPixels(128, 128, table.concat(rows))
  local g = {}
  for i = 1, 64 * 64 do
    local G = hash2(i % 64, floor(i / 64), 9) - 0.5
    g[i] = char(0, 0, 0, floor(0.035 * (G + 0.5) * 255 + 0.5))
  end
  local grain = image.fromPixels(64, 64, table.concat(g))
  WEAR = { mottle = mottle, grain = grain }
  return WEAR
end

-- What every colour is scaled by before the wear darkens it back: the light
-- at the top (1.04) and the grain's half.
local function wear_gain(amount) return 1.04 * (1 + 0.0175 * amount) end

-- The wear for a size, seed and strength, before it is cut to a shape: the
-- light from above (1.04 at the top to 0.96 at the bottom; the gain lifts the
-- top back), the mottling and the grain, all black by their alpha.
local function wear_base(size, seed, amount)
  local W = wear_tiles()
  local k = size / 256
  local O = image.new(size, size)
  -- the light, a row at a time (a fill sets the row: O is empty)
  for y = 0, size - 1 do
    O:fill(0, y, size, 1, 0, 0, 0, 1 - (1.04 - 0.08 * (y / size)) / 1.04)
  end
  local ox, oy = (seed * 37) % 128, (seed * 61) % 128
  local ga = amount / (1 + 0.0175 * amount)
  if size == 256 then
    -- at 1:1 the mottling (128 units) and the grain (64 px) share a 128-pixel
    -- period: make that tile once for the seed, then lay it four times
    local Tl = image.new(128, 128)
    for ty = -oy, 127, 128 do
      for tx = -ox, 127, 128 do Tl:draw(W.mottle, tx, ty, 128, 128, amount) end
    end
    for py = -(seed % 64), 127, 64 do
      for px = 0, 127, 64 do Tl:draw(W.grain, px, py, 64, 64, ga) end
    end
    for ty = 0, 255, 128 do
      for tx = 0, 255, 128 do O:draw(Tl, tx, ty) end
    end
  else
    local T = 128 * k
    for ty = -oy, 255, 128 do
      for tx = -ox, 255, 128 do O:draw(W.mottle, tx * k, ty * k, T, T, amount) end
    end
    for py = -(seed % 64), size - 1, 64 do
      for px = 0, size - 1, 64 do O:draw(W.grain, px, py, 64, 64, ga) end
    end
  end
  return O
end

-- The wear as one overlay cut to a body. Both kept: a tweak of the colours or
-- the motif keeps the seed and the shape, a tweak of the shape keeps the seed.
local wear_bases, wear_cut = {}, {}
local function remember(list, key, img)
  table.insert(list, 1, { key = key, img = img })
  if #list > 6 then list[#list] = nil end
  return img
end
local function recall(list, key)
  for _, e in ipairs(list) do if e.key == key then return e.img end end
end
local function wear_overlay(size, seed, amount, body, shape)
  local bk = table.concat({ size, seed, amount }, ":")
  local ck = bk .. ":" .. tostring(shape)
  local O = recall(wear_cut, ck)
  if O then return O end
  local base = recall(wear_bases, bk) or remember(wear_bases, bk, wear_base(size, seed, amount))
  O = base:copy()
  cut_outside(O, spans_of(body, size / 256, size))
  return remember(wear_cut, ck, O)
end

-- ── packing a buffer (a decoded picture) to bytes ───────────────────────────

-- An image buffer { w, h, R, G, B, A } (premultiplied 0..1) as w*h*4 bytes
-- (straight alpha), the layout image.fromPixels takes.
local function pack(cv)
  local w, h = cv.w, cv.h
  local R, G, B, A = cv.R, cv.G, cv.B, cv.A
  local rows = {}
  local row = {}
  for y = 0, h - 1 do
    if y % 16 == 0 then step() end
    local n = 0
    local base = y * w
    for x = 1, w do
      local i = base + x
      local a = A[i]
      local r, g, b = 0, 0, 0
      if a > 0.002 then
        local inv = 255 / a
        r, g, b = R[i] * inv, G[i] * inv, B[i] * inv
        if r > 255 then r = 255 end
        if g > 255 then g = 255 end
        if b > 255 then b = 255 end
      end
      row[n + 1] = floor(r + 0.5); row[n + 2] = floor(g + 0.5); row[n + 3] = floor(b + 0.5)
      row[n + 4] = floor(a * 255 + 0.5)
      n = n + 4
    end
    local parts = {}
    for j = 1, n, 4096 do parts[#parts + 1] = char(unpack(row, j, min(n, j + 4095))) end
    rows[y + 1] = table.concat(parts)
  end
  return table.concat(rows)
end

-- A decoded picture (an image buffer) as an image, made once per buffer.
local function buf_image(buf)
  if not buf.img then buf.img = image.fromPixels(buf.w, buf.h, pack(buf)) end
  return buf.img
end

-- ── the two pictures ────────────────────────────────────────────────────────

-- The emblem: its pixels (size² × 4 bytes, straight alpha) and its image.
-- `custom` = a picture to use instead of a generated emblem (an image buffer
-- from imageToBuf, or an image), already square.
function rasterEmblem(spec, name, size, custom)
  size = size or EMBLEM_SIZE
  spec = spec or specFor(name)
  local T = PROF and now_ms
  local t0 = T and T()
  local img = image.new(size, size)
  if custom then
    img:draw(custom.R and buf_image(custom) or custom, 0, 0, size, size)
  else
    local amount = size >= 64 and (size >= 128 and 1 or 0.6) or 0
    local cv = pen(img, size / 256, amount > 0 and wear_gain(amount) or 1)
    local body = draw_emblem(cv, spec, name)
    if T then PROF.draw = (PROF.draw or 0) + T() - t0; t0 = T() end
    step()
    if amount > 0 then
      img:draw(wear_overlay(size, (spec.seed or 1) % 9973, amount, body, spec.shape), 0, 0)
    end
    if T then PROF.wear = (PROF.wear or 0) + T() - t0; t0 = T() end
  end
  local px = img:bytes()
  if T then PROF.bytes = (PROF.bytes or 0) + T() - t0 end
  return px, img
end

-- The flag cloth: the field, the emblem, and the name, FLAG_W × FLAG_H.
-- `epx` is the emblem (rasterEmblem's pixels or its image, 256²), set on the
-- field at 1:1 so nothing is resampled. Returns the pixels and the image.
local byte = string.byte
function rasterFlag(spec, name, epx)
  local P = (spec and spec.pal) or specFor(name).pal
  local W, H = FLAG_W, FLAG_H
  local img = image.new(W, H, P.bg[1], P.bg[2], P.bg[3], 1)
  -- the hoist: the sleeve in the band colour, a fine accent stripe beside it
  local HOIST, STRIPE = 18, 4
  img:fill(0, 0, HOIST, H, P.ring[1], P.ring[2], P.ring[3], 1)
  img:fill(HOIST, 0, STRIPE, H, P.accent[1], P.accent[2], P.accent[3], 1)
  local ES = EMBLEM_SIZE
  local EX, EY = floor(W / 2 + 10 - ES / 2), 16
  if epx then
    local e = type(epx) == "string" and image.fromPixels(ES, ES, epx) or epx
    img:draw(e, EX, EY)
  end
  -- the name under it
  local up = upperName(name)
  local TY0, TH = EY + ES + 6, H - (EY + ES + 6)
  local cap = fit_cap("label", up, 34, W - 90, 5)
  paint_text(pen(img, 1), "label", up, W / 2 + 10, TY0 + TH * 0.5 + cap * 0.5, cap, P.fg, 5)
  return img:bytes(), img
end

-- ════════════════════════════════════════════════════════════════════════════
-- PICTURES: PNG (with an inflate) and baseline JPEG, decoded in Lua
-- ════════════════════════════════════════════════════════════════════════════

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- decodePng(bytes, inflate) — `inflate(zlibBytes) → raw` (the engine's
-- data.inflate). 8-bit and 16-bit greyscale, grey+alpha, RGB, RGBA and
-- palette (1/2/4/8-bit) images; interlaced ones are refused.
function decodePng(s, inflate)
  if type(s) ~= "string" or s:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a PNG" end
  local i = 9
  local w, h, depth, ctype, interlace
  local idat, plte, trns = {}, nil, nil
  while i + 8 <= #s do
    local len = u32(s, i)
    local typ = s:sub(i + 4, i + 7)
    local body = s:sub(i + 8, i + 7 + len)
    if typ == "IHDR" then
      w, h = u32(body, 1), u32(body, 5)
      depth, ctype, interlace = body:byte(9), body:byte(10), body:byte(13)
    elseif typ == "PLTE" then plte = body
    elseif typ == "tRNS" then trns = body
    elseif typ == "IDAT" then idat[#idat + 1] = body
    elseif typ == "IEND" then break end
    i = i + 12 + len
  end
  if not w then return nil, "a PNG with no header" end
  if interlace ~= 0 then return nil, "interlaced PNGs aren't supported (save it without interlacing)" end
  if w > 4096 or h > 4096 then return nil, "the picture is larger than 4096 pixels" end
  local chans = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[ctype]
  if not chans then return nil, "an unknown PNG colour type" end
  if not inflate then return nil, "no inflate available" end
  local ok, raw = pcall(inflate, table.concat(idat))
  if not ok or type(raw) ~= "string" then return nil, "the PNG's data is damaged" end
  local bpp = max(1, floor(chans * depth / 8))
  local stride = floor((w * chans * depth + 7) / 8)
  if #raw < h * (stride + 1) then return nil, "the PNG's data is short" end
  local R, G, B, A = {}, {}, {}, {}
  local prev = {}
  for x = 1, stride do prev[x] = 0 end
  local cur = {}
  local pos = 1
  for y = 0, h - 1 do
    local ft = raw:byte(pos)
    pos = pos + 1
    for x = 1, stride do
      local v = raw:byte(pos + x - 1)
      local a = x > bpp and cur[x - bpp] or 0
      local b = prev[x]
      if ft == 1 then v = v + a
      elseif ft == 2 then v = v + b
      elseif ft == 3 then v = v + floor((a + b) / 2)
      elseif ft == 4 then
        local c = x > bpp and prev[x - bpp] or 0
        local p = a + b - c
        local pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        if pa <= pb and pa <= pc then v = v + a elseif pb <= pc then v = v + b else v = v + c end
      end
      cur[x] = v % 256
    end
    pos = pos + stride
    local base = y * w
    for x = 0, w - 1 do
      local r, g, b, al
      if depth == 8 then
        local o = x * chans + 1
        if ctype == 0 then r = cur[o]; g, b, al = r, r, 255
        elseif ctype == 2 then r, g, b, al = cur[o], cur[o + 1], cur[o + 2], 255
        elseif ctype == 3 then
          local p = cur[o]
          r, g, b = (plte and plte:byte(p * 3 + 1, p * 3 + 3)) or 0
          if plte then r, g, b = plte:byte(p * 3 + 1), plte:byte(p * 3 + 2), plte:byte(p * 3 + 3) end
          al = (trns and trns:byte(p + 1)) or 255
        elseif ctype == 4 then r = cur[o]; g, b = r, r; al = cur[o + 1]
        else r, g, b, al = cur[o], cur[o + 1], cur[o + 2], cur[o + 3] end
      elseif depth == 16 then
        local o = x * chans * 2 + 1
        local function c16(k) return cur[o + k * 2] end
        if ctype == 0 then r = c16(0); g, b, al = r, r, 255
        elseif ctype == 2 then r, g, b, al = c16(0), c16(1), c16(2), 255
        elseif ctype == 4 then r = c16(0); g, b = r, r; al = c16(1)
        elseif ctype == 6 then r, g, b, al = c16(0), c16(1), c16(2), c16(3)
        else return nil, "a 16-bit palette PNG" end
      else -- 1, 2, 4-bit grey or palette
        local per = 8 / depth
        local byte = cur[floor(x / per) + 1]
        local shift = (per - 1 - x % per) * depth
        local v = floor(byte / 2 ^ shift) % (2 ^ depth)
        if ctype == 3 then
          if plte then r, g, b = plte:byte(v * 3 + 1), plte:byte(v * 3 + 2), plte:byte(v * 3 + 3) end
          r, g, b = r or 0, g or 0, b or 0
          al = (trns and trns:byte(v + 1)) or 255
        else
          r = floor(v * 255 / (2 ^ depth - 1)); g, b, al = r, r, 255
        end
      end
      local i2 = base + x + 1
      R[i2], G[i2], B[i2], A[i2] = (r or 0) / 255, (g or 0) / 255, (b or 0) / 255, (al or 255) / 255
    end
    prev, cur = cur, prev
  end
  return { w = w, h = h, R = R, G = G, B = B, A = A }
end

-- ── baseline JPEG ───────────────────────────────────────────────────────────
-- Huffman-coded baseline (SOF0/SOF1) with any sampling factors, 1 or 3
-- components, restart markers. Progressive JPEGs (SOF2) are refused with a
-- reason; re-saving as PNG or baseline JPEG fixes it.

local ZZ = { 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
             13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52,
             45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 }

local function idct_tables()
  local T = {}
  for x = 0, 7 do
    for u = 0, 7 do
      local cu = (u == 0) and (1 / sqrt(2)) or 1
      T[x * 8 + u + 1] = cu * cos((2 * x + 1) * u * pi / 16) * 0.5
    end
  end
  return T
end
local IDCT

function decodeJpeg(s)
  if type(s) ~= "string" or s:byte(1) ~= 0xFF or s:byte(2) ~= 0xD8 then return nil, "not a JPEG" end
  IDCT = IDCT or idct_tables()
  local qt, hts = {}, {}
  local frame, comps
  local restart = 0
  local i = 3
  local n = #s
  local function u16(p) return s:byte(p) * 256 + s:byte(p + 1) end
  local scan_at
  while i < n do
    if s:byte(i) ~= 0xFF then return nil, "the JPEG is damaged" end
    local m = s:byte(i + 1)
    if m == 0xD8 or (m >= 0xD0 and m <= 0xD7) or m == 0x01 then i = i + 2
    elseif m == 0xFF then i = i + 1
    else
      local len = u16(i + 2)
      local p = i + 4
      if m == 0xDB then
        local e = i + 2 + len
        while p < e do
          local pq, tq = floor(s:byte(p) / 16), s:byte(p) % 16
          p = p + 1
          local t = {}
          for k = 1, 64 do
            if pq == 0 then t[k] = s:byte(p); p = p + 1 else t[k] = u16(p); p = p + 2 end
          end
          qt[tq] = t
        end
      elseif m == 0xC4 then
        local e = i + 2 + len
        while p < e do
          local tc, th = floor(s:byte(p) / 16), s:byte(p) % 16
          local counts = { s:byte(p + 1, p + 16) }
          p = p + 17
          -- canonical codes → a lookup keyed by (length, code)
          local lookup, code = {}, 0
          for l = 1, 16 do
            for _ = 1, counts[l] do
              lookup[l * 65536 + code] = s:byte(p)
              p = p + 1
              code = code + 1
            end
            code = code * 2
          end
          hts[tc * 16 + th] = lookup
        end
      elseif m == 0xC0 or m == 0xC1 then
        frame = { h = u16(p + 1), w = u16(p + 3), n = s:byte(p + 5) }
        comps = {}
        for c = 1, frame.n do
          local q = p + 6 + (c - 1) * 3
          comps[c] = { id = s:byte(q), hs = floor(s:byte(q + 1) / 16), vs = s:byte(q + 1) % 16, tq = s:byte(q + 2) }
        end
      elseif m == 0xC2 or m == 0xC6 or m == 0xCA then
        return nil, "progressive JPEGs aren't supported (save it as a PNG or a baseline JPEG)"
      elseif m >= 0xC3 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
        return nil, "this kind of JPEG isn't supported (save it as a PNG)"
      elseif m == 0xDD then
        restart = u16(p)
      elseif m == 0xDA then
        local ns = s:byte(p)
        for c = 1, ns do
          local cid, tbl = s:byte(p + 1 + (c - 1) * 2), s:byte(p + 2 + (c - 1) * 2)
          for _, cp in ipairs(comps or {}) do
            if cp.id == cid then cp.td, cp.ta = floor(tbl / 16), tbl % 16 end
          end
        end
        scan_at = i + 2 + len
        break
      elseif m == 0xD9 then break end
      i = i + 2 + len
    end
  end
  if not (frame and scan_at) then return nil, "the JPEG has no picture in it" end
  if frame.w > 4096 or frame.h > 4096 then return nil, "the picture is larger than 4096 pixels" end
  local hmax, vmax = 1, 1
  for _, c in ipairs(comps) do hmax, vmax = max(hmax, c.hs), max(vmax, c.vs) end
  local mcux, mcuy = 8 * hmax, 8 * vmax
  local mx, my = floor((frame.w + mcux - 1) / mcux), floor((frame.h + mcuy - 1) / mcuy)
  for _, c in ipairs(comps) do
    c.bw, c.bh = mx * c.hs * 8, my * c.vs * 8
    c.px = {}
    c.pred = 0
  end
  -- the bit reader (skips stuffed zero bytes, stops at markers)
  local pos, bitbuf, bits = scan_at, 0, 0
  local function fill()
    local b = s:byte(pos) or 0
    if b == 0xFF then
      local nb = s:byte(pos + 1) or 0
      if nb == 0 then pos = pos + 2
      else b = 0 end   -- a marker: feed zeros
    else pos = pos + 1 end
    bitbuf = bitbuf * 256 + b
    bits = bits + 8
  end
  local function getbit()
    if bits == 0 then fill() end
    bits = bits - 1
    local p2 = 2 ^ bits
    local v = floor(bitbuf / p2)
    bitbuf = bitbuf - v * p2
    return v
  end
  local function getbits(nb)
    local v = 0
    for _ = 1, nb do v = v * 2 + getbit() end
    return v
  end
  local function decode(tbl)
    local code = 0
    for l = 1, 16 do
      code = code * 2 + getbit()
      local v = tbl[l * 65536 + code]
      if v then return v end
    end
    return 0
  end
  local function extend(v, t)
    if t == 0 then return 0 end
    if v < 2 ^ (t - 1) then return v - 2 ^ t + 1 end
    return v
  end
  local blk = {}
  local tmp = {}
  local function block(c, ox, oy)
    for k = 1, 64 do blk[k] = 0 end
    local t = decode(hts[c.td])
    local diff = extend(getbits(t), t)
    c.pred = c.pred + diff
    local q = qt[c.tq]
    blk[1] = c.pred * q[1]
    local k = 2
    local at = hts[16 + c.ta]
    while k <= 64 do
      local rs = decode(at)
      local r, sz = floor(rs / 16), rs % 16
      if sz == 0 then
        if r ~= 15 then break end
        k = k + 16
      else
        k = k + r
        if k > 64 then break end
        blk[ZZ[k] + 1] = extend(getbits(sz), sz) * q[k]
        k = k + 1
      end
    end
    -- separable IDCT
    local T = IDCT
    for y = 0, 7 do
      for x = 0, 7 do
        local acc = 0
        for u = 0, 7 do acc = acc + T[x * 8 + u + 1] * blk[y * 8 + u + 1] end
        tmp[y * 8 + x + 1] = acc
      end
    end
    local px, bw = c.px, c.bw
    for x = 0, 7 do
      for y = 0, 7 do
        local acc = 0
        for v = 0, 7 do acc = acc + T[y * 8 + v + 1] * tmp[v * 8 + x + 1] end
        local val = acc + 128
        if val < 0 then val = 0 elseif val > 255 then val = 255 end
        px[(oy + y) * bw + ox + x + 1] = val
      end
    end
  end
  local mcus = 0
  for my_ = 0, my - 1 do
    for mx_ = 0, mx - 1 do
      if restart > 0 and mcus > 0 and mcus % restart == 0 then
        -- realign to the RST marker
        bits, bitbuf = 0, 0
        while pos < n and not (s:byte(pos) == 0xFF and (s:byte(pos + 1) or 0) >= 0xD0 and (s:byte(pos + 1) or 0) <= 0xD7) do
          pos = pos + 1
        end
        pos = pos + 2
        for _, c in ipairs(comps) do c.pred = 0 end
      end
      for _, c in ipairs(comps) do
        for v = 0, c.vs - 1 do
          for h = 0, c.hs - 1 do
            block(c, (mx_ * c.hs + h) * 8, (my_ * c.vs + v) * 8)
          end
        end
      end
      mcus = mcus + 1
    end
  end
  local W, H = frame.w, frame.h
  local R, G, B, A = {}, {}, {}, {}
  local c1, c2, c3 = comps[1], comps[2], comps[3]
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local function at(c)
        local sx = floor(x * c.hs / hmax)
        local sy = floor(y * c.vs / vmax)
        return c.px[sy * c.bw + sx + 1] or 0
      end
      local i2 = y * W + x + 1
      local Y = at(c1)
      if c3 then
        local cb, cr = at(c2) - 128, at(c3) - 128
        local r = Y + 1.402 * cr
        local g = Y - 0.344136 * cb - 0.714136 * cr
        local b = Y + 1.772 * cb
        R[i2] = max(0, min(255, r)) / 255; G[i2] = max(0, min(255, g)) / 255; B[i2] = max(0, min(255, b)) / 255
      else
        R[i2] = Y / 255; G[i2] = Y / 255; B[i2] = Y / 255
      end
      A[i2] = 1
    end
  end
  return { w = W, h = H, R = R, G = G, B = B, A = A }
end

-- Any picture the folder may hold.
function decodeImage(bytes, inflate)
  if type(bytes) ~= "string" then return nil, "no data" end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return decodePng(bytes, inflate) end
  if bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 then return decodeJpeg(bytes) end
  return nil, "only PNG and JPEG pictures can be used"
end

-- A picture centre-cropped to a square and resampled to size × size (an
-- image buffer, premultiplied). A box filter when shrinking a lot.
function imageToBuf(img, size)
  size = size or EMBLEM_SIZE
  local side = min(img.w, img.h)
  local ox, oy = floor((img.w - side) / 2), floor((img.h - side) / 2)
  local R, G, B, A = {}, {}, {}, {}
  local f = side / size
  local taps = max(1, min(4, floor(f)))
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local r, g, b, a = 0, 0, 0, 0
      for ty = 0, taps - 1 do
        for tx = 0, taps - 1 do
          local sx = ox + floor((x + (tx + 0.5) / taps) * f)
          local sy = oy + floor((y + (ty + 0.5) / taps) * f)
          if sx >= img.w then sx = img.w - 1 end
          if sy >= img.h then sy = img.h - 1 end
          local i = sy * img.w + sx + 1
          local al = img.A[i]
          r, g, b, a = r + img.R[i] * al, g + img.G[i] * al, b + img.B[i] * al, a + al
        end
      end
      local i = y * size + x + 1
      local nt = taps * taps
      A[i], R[i], G[i], B[i] = a / nt, r / nt, g / nt, b / nt
    end
  end
  return { w = size, h = size, R = R, G = G, B = B, A = A }
end

-- The pixels of an image buffer (for a custom emblem's texture).
function bufToPixels(buf) return pack(buf) end

-- ════════════════════════════════════════════════════════════════════════════
-- THE SERVICE
-- ════════════════════════════════════════════════════════════════════════════

version = 0
lastBuildMs = nil        -- ms of work the last emblem + flag build took (all its slices)
lastBuildFrames = nil    -- over how many frames it was spread
lastLoadMs = nil         -- ms the last load from the cache took
local cur = nil          -- { name, spec, tex, flagTex, epx }
local notice = nil

local function can_draw() return assets ~= nil and assets.textureFromPixels ~= nil end

local function release(t) if t and assets and assets.release then pcall(assets.release, t) end end

local function inflate_fn()
  if data and data.inflate then return function(z) return data.inflate(z) end end
  return nil
end

-- Read and decode a custom picture → image buffer (256²) or nil, why.
local custom_cache = {}
function loadCustom(path)
  if type(path) ~= "string" then return nil, "no picture" end
  local hit = custom_cache[path]
  if hit then return hit end
  if not (assets and assets.readBytes) then return nil, "pictures can't be read here" end
  local ok, bytes, err = pcall(assets.readBytes, path)
  if not ok or type(bytes) ~= "string" then return nil, "the picture is missing (" .. tostring(err or bytes) .. ")" end
  if #bytes > 8 * 1024 * 1024 then return nil, "the picture is larger than 8 MB" end
  local img, why = decodeImage(bytes, inflate_fn())
  if not img then return nil, why end
  local buf = imageToBuf(img, EMBLEM_SIZE)
  custom_cache[path] = buf
  return buf
end

-- A build's identity: everything that changes its pixels (a picture by its
-- path and its size on disk, so a replaced file is noticed).
local function signature(nm, sp)
  local parts = { "v4", nm, tostring(sp.seed), sp.shape, sp.motif, tostring(sp.font), tostring(sp.mono) }
  for _, k in ipairs({ "bg", "ring", "fg", "accent" }) do
    for i = 1, 3 do parts[#parts + 1] = string.format("%.4f", sp.pal[k][i]) end
  end
  if sp.image then
    parts[#parts + 1] = sp.image
    local ok, b = pcall(function() return assets and assets.readBytes and assets.readBytes(sp.image) end)
    parts[#parts + 1] = tostring(ok and type(b) == "string" and #b or "gone")
  end
  return table.concat(parts, "|")
end

-- ── THE CACHE ───────────────────────────────────────────────────────────────
-- The finished pixels are kept in the player's folder (user://agency/,
-- never in the save), so a load is a file read and two texture uploads, not
-- a raster. A cache file is only ever trusted when its signature matches the
-- spec in the save; the save stays the truth.
local function cache_path()
  local sl = save and save.slot and save.slot()
  return string.format("user://agency/%s.rgba", (type(sl) == "string" and sl ~= "") and sl:gsub("[^%w_%-]", "_") or "slot")
end

local function cache_read(sig)
  if not (assets and assets.readBytes) then return nil end
  local ok, bytes = pcall(assets.readBytes, cache_path())
  if not ok or type(bytes) ~= "string" then return nil end
  local nl = bytes:find("\n", 1, true)
  if not nl or bytes:sub(1, nl - 1) ~= sig then return nil end
  local e = EMBLEM_SIZE * EMBLEM_SIZE * 4
  local f = FLAG_W * FLAG_H * 4
  if #bytes ~= nl + e + f then return nil end
  return bytes:sub(nl + 1, nl + e), bytes:sub(nl + e + 1)
end

local function cache_write(sig, epx, fpx)
  if not (assets and assets.writeBytes) then return end
  pcall(assets.writeBytes, cache_path(), sig .. "\n" .. epx .. fpx)
end

-- ── JOBS: builds spread over frames ─────────────────────────────────────────
local jobs = {}          -- a queue: { co, done, t0, frames }
local JOB_BUDGET = 5.0   -- ms of raster work a frame
local live = false       -- the node's update is running (else builds run straight through)

local function run(fn, done)
  if not live or not coroutine or not coroutine.create then
    local t0 = now_ms()
    local r = fn()
    done(r, now_ms() - t0, 1)
    return
  end
  jobs[#jobs + 1] = { co = coroutine.create(fn), done = done, frames = 0 }
end

local function pump()
  local j = jobs[1]
  if not j then return end
  j.frames = j.frames + 1
  SLICE.budget, SLICE.t0, SLICE.work = JOB_BUDGET, now_ms(), j.work or 0
  local ok, r = coroutine.resume(j.co)
  local t = now_ms()
  j.work = SLICE.work + (t - SLICE.t0)
  SLICE.budget = nil
  if not ok then
    table.remove(jobs, 1)
    if log then log("emblem: a build failed: " .. tostring(r)) end
    return
  end
  if coroutine.status(j.co) == "dead" then
    table.remove(jobs, 1)
    j.done(r, j.work, j.frames)
  end
end

function busy() return #jobs > 0 end

-- Raster both pictures for (name, spec): → { epx, fpx, custom } (pure work).
local function raster(nm, sp)
  local custom, why = nil, nil
  if sp.image then
    custom, why = loadCustom(sp.image)
    if not custom then
      notice = string.format("Your emblem picture couldn't be used (%s); the generated emblem is shown instead.",
        tostring(why))
      if log then log("emblem: " .. notice) end
    end
  end
  local epx, eimg = rasterEmblem(sp, nm, EMBLEM_SIZE, custom)
  local fpx, fimg = rasterFlag(sp, nm, eimg)
  return { epx = epx, fpx = fpx, eimg = eimg, fimg = fimg, custom = custom ~= nil }
end

-- A texture for a picture: the image's own (img:texture()), or one made from
-- its pixels (a cache file's, or where image.* draws nothing).
local function texture_of(img, w, h, px)
  local t = nil
  if img and img.texture then t = img:texture() end
  if not t and can_draw() and px then t = assets.textureFromPixels(w, h, px) end
  return t
end

local function textures(rec)
  rec.tex = texture_of(rec.eimg, EMBLEM_SIZE, EMBLEM_SIZE, rec.epx)
  rec.flagTex = texture_of(rec.fimg, FLAG_W, FLAG_H, rec.fpx)
  rec.eimg, rec.fimg = nil, nil
  return rec
end

local function read_save()
  if not (save and save.get) then return DEFAULT_NAME, specFor(DEFAULT_NAME) end
  local n = save.get("agency.name")
  local nm = (type(n) == "string" and n ~= "") and cleanName(n) or DEFAULT_NAME
  return nm, clean(save.get("agency.emblem"), nm)
end

local function install(rec)
  local old = cur
  cur = rec
  version = version + 1
  if old then
    -- the old textures go a moment later, once nothing is drawing them
    local a, b = old.tex, old.flagTex
    if after then after(1.0, function() release(a); release(b) end) else release(a); release(b) end
  end
end

-- Build (or load from the cache) the live identity. `then_` runs when it is
-- installed.
local building = 0
local function build_live(nm, sp, then_)
  building = building + 1
  local mine = building
  local sig = signature(nm, sp)
  local t0 = now_ms()
  local epx, fpx = cache_read(sig)
  if epx then
    local rec = textures({ name = nm, spec = sp, epx = epx, fpx = fpx })
    lastLoadMs = now_ms() - t0
    install(rec)
    if then_ then then_(rec) end
    return
  end
  run(function() return raster(nm, sp) end, function(r, work, frames)
    if mine ~= building then return end   -- a newer build overtook it
    lastBuildMs, lastBuildFrames = work, frames
    r.name, r.spec = nm, sp
    cache_write(sig, r.epx, r.fpx)
    install(textures(r))
    if then_ then then_(r) end
  end)
end

-- What the save keeps: the spec with nothing derived.
local function storable(sp) return deep(sp) end

-- Is a game save open (rather than the main menu)?
local function is_menu()
  local sc = scene and scene.current and scene.current()
  return type(sc) == "string" and sc:match("menu") ~= nil
end
local function in_game()
  return not is_menu() and save and save.get and save.get("g_seed") ~= nil
end

-- One-time setup of an older save: the default name, and a prompt to rename.
function migrate()
  if not (save and save.get and save.set) then return false end
  if not in_game() then return false end
  if type(save.get("agency.name")) == "string" then return false end
  save.set("agency.name", DEFAULT_NAME)
  save.set("agency.emblem", storable(specFor(DEFAULT_NAME)))
  save.set("agency.prompt", true)
  return true
end

-- The save is the truth (a set() is in it before its build lands).
function name()
  if save and save.get and not is_menu() then return (read_save()) end
  return (cur and cur.name) or DEFAULT_NAME
end
agencyName = name
function spec()
  if save and save.get and not is_menu() then return select(2, read_save()) end
  return deep((cur and cur.spec) or specFor(DEFAULT_NAME))
end
function tex() return cur and cur.tex end
function flagTex() return cur and cur.flagTex end
function emblemPixels() return cur and cur.epx end
function noticeText() local n = notice; return n end
function clearNotice() notice = nil end
function needsPrompt() return save and save.get and save.get("agency.prompt") == true end
function clearPrompt() if save and save.set then save.set("agency.prompt", false) end end

-- Store a new identity in the current save and repaint everything (once the
-- build lands, a few frames later in a game).
function set(nm, sp)
  local n = cleanName(nm)
  local s2 = clean(sp, n)
  if save and save.set then
    save.set("agency.name", n)
    save.set("agency.emblem", storable(s2))
    save.set("agency.prompt", false)
  end
  notice = nil
  build_live(n, s2)
  return n, s2
end

-- Rebuild from the save (after a load, or a revert).
function reload()
  migrate()
  local n, s2 = read_save()
  build_live(n, s2)
end

-- A preview for an editor: textures for (name, spec) without touching the
-- save or the live identity. fn(emblemTex, flagTex, ms) when they are ready;
-- a newer request supersedes an older one still building.
local prev = nil
local prev_seq = 0
function preview(nm, sp, fn)
  local n = cleanName(nm)
  local s2 = clean(sp, n)
  prev_seq = prev_seq + 1
  local mine = prev_seq
  run(function() return raster(n, s2) end, function(r, work)
    if mine ~= prev_seq then return end
    textures(r)
    if prev then
      local a, b = prev.tex, prev.flagTex
      if after then after(0.5, function() release(a); release(b) end) else release(a); release(b) end
    end
    prev = r
    if fn then fn(r.tex, r.flagTex, work) end
  end)
end

-- A small emblem for another slot's card (cached per slot and spec).
local small = {}
function smallTex(slot, nm, sp)
  if not can_draw() then return nil end
  local key = tostring(slot)
  local n = cleanName(nm)
  local s2 = clean(sp, n)
  local sig = signature(n, s2)
  local hit = small[key]
  if hit and hit.sig == sig then return hit.tex end
  if hit and hit.pending then return nil end
  small[key] = { sig = sig, pending = true }
  run(function()
    local custom = s2.image and loadCustom(s2.image) or nil
    local px, img = rasterEmblem(s2, n, 96, custom)
    return { px = px, img = img }
  end, function(r)
    local old = hit and hit.tex
    small[key] = { sig = sig, tex = texture_of(r.img, 96, 96, r.px) }
    if old then release(old) end
  end)
  return small[key].tex
end

-- ── the user://emblems folder ───────────────────────────────────────────────

EMBLEM_DIR = "user://emblems"

function emblemsFolder()
  local base = app and app.dataPath and app.dataPath()
  if type(base) == "string" and base ~= "" then return base .. "/emblems" end
  return "user://emblems"
end

-- The pictures in the folder, sorted. Makes the folder (with a short
-- README) the first time, so the player has somewhere to put them.
function customFiles()
  local out = {}
  if not (assets and assets.getContents) then return out end
  local ok, list = pcall(assets.getContents, EMBLEM_DIR)
  if not ok or type(list) ~= "table" then list = {} end
  if #list == 0 and assets.writeText then
    pcall(assets.writeText, EMBLEM_DIR .. "/README.txt",
      "Put a PNG or JPG here to use it as your agency's emblem (square works best; it is centre-cropped).\n"
      .. "Then press the refresh button on the emblem panel.\n")
  end
  for _, p in ipairs(list) do
    local lp = p:lower()
    if lp:match("%.png$") or lp:match("%.jpe?g$") then
      if not p:match("^user://") then p = EMBLEM_DIR .. "/" .. p:gsub("^.*/", "") end
      out[#out + 1] = p
    end
  end
  table.sort(out)
  return out
end

function refreshCustom() custom_cache = {} end

-- The native file picker (engine card 0536, planned for rc29). When the
-- engine has one, "Load image…" opens it and copies the choice into
-- user://emblems/, so a save still points inside the player's folder.
function canPickFile() return app ~= nil and type(app.openFile) == "function" end

function pickFile(fn)
  if not canPickFile() then return false, "this engine has no file picker yet" end
  local ok, err = pcall(app.openFile, { title = "Choose an emblem picture", filter = { "png", "jpg", "jpeg" } },
    function(fname, bytes, why)
      if not bytes then if fn then fn(nil, why or "nothing chosen") end return end
      local base = tostring(fname or "emblem.png"):gsub("^.*[/\\]", ""):gsub("[^%w%._%-]", "_")
      if not base:lower():match("%.png$") and not base:lower():match("%.jpe?g$") then base = base .. ".png" end
      local path = EMBLEM_DIR .. "/" .. base
      local wok, werr = assets.writeBytes(path, bytes)
      custom_cache[path] = nil
      if fn then fn(wok and path or nil, wok and nil or werr) end
    end)
  if not ok then return false, tostring(err) end
  return true
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE EDITOR (the new-save panel and Settings ▸ Agency share it)
-- ════════════════════════════════════════════════════════════════════════════
--
--   local ed = em.newEditor(name, spec)      -- or nil, nil for a new agency
--   ui.make(box, em.editorRows(ed, 330))     -- the rows, for a column W wide
--   em.editorTick(ed)                        -- each frame: rebuilds the
--                                            -- preview once typing settles
--   local name, spec = em.editorResult(ed)
--
-- Until the player tweaks something, the emblem follows the name as it is
-- typed; after a tweak a new name changes only the monogram.

-- The colour chips: twelve hues in three shades, and six neutrals.
local function hsv(h, s, v)
  local i = floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return { v, t, p } elseif i == 1 then return { q, v, p } elseif i == 2 then return { p, v, t }
  elseif i == 3 then return { p, q, v } elseif i == 4 then return { t, p, v } end
  return { v, p, q }
end
CHIPS = {}
for row, sv in ipairs({ { 0.75, 0.38 }, { 0.72, 0.70 }, { 0.42, 0.92 } }) do
  for k = 0, 11 do CHIPS[#CHIPS + 1] = hsv(k / 12, sv[1], sv[2]) end
end
for _, g in ipairs({ 0.08, 0.2, 0.38, 0.6, 0.82, 0.95 }) do CHIPS[#CHIPS + 1] = { g, g * 0.98, g * 0.93 } end

local function hexof(c)
  return string.format("#%02x%02x%02x", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

function newEditor(nm, sp)
  local n = (type(nm) == "string" and nm ~= "") and cleanName(nm) or DEFAULT_NAME
  return { name = n, typed = (type(nm) == "string" and nm ~= "") and n or "", spec = clean(sp or specFor(n), n), tweaked = sp ~= nil,
           mode = (sp and sp.image) and "files" or "gen", pick = nil, files = nil, msg = nil,
           dirty = true, dirty_t = 0, tex = nil, flag = nil, ms = nil }
end

function editorResult(ed) return cleanName(ed.name), clean(ed.spec, cleanName(ed.name)) end

local function changed(ed, now) ed.dirty = true; ed.dirty_t = now or (time or 0) end

function editorSetName(ed, text)
  ed.typed = text or ""
  local n = cleanName(text)
  if n == ed.name then return end
  ed.name = n
  if ed.tweaked then
    local s = deep(ed.spec)
    s.mono = monogram(n)
    ed.spec = s
  else
    local img = ed.spec.image
    ed.spec = specFor(n)
    ed.spec.image = img
  end
  changed(ed)
end

-- Rebuild the preview when something changed and the typing has paused.
function editorTick(ed, svc)
  if not ed.dirty then return false end
  local now = time or 0
  if now - (ed.dirty_t or 0) < 0.12 then return false end
  ed.dirty = false
  local host = svc or (findScript and findScript("emblem"))
  local pv = (host and host.preview) or preview
  pv(ed.name, ed.spec, function(t, f, ms) ed.tex, ed.flag, ed.ms = t, f, ms end)
  return true
end

local function stepper(key, label, value, on)
  return { "row", key = key, w = "100%", h = 26, gap = 4, pad = 0, align = "center",
    { "text", key = "l", style = "panel/label", w = 74, h = "fit", text = label },
    { "button", key = "dn", style = "panel/secondary", w = 26, h = 24, text = "◂", textAlign = "center",
      textValign = "center", onClicked = function() on(-1) end },
    { "text", key = "v", style = "panel/cellStrong", w = "grow", h = "fit", textAlign = "center", text = value },
    { "button", key = "up", style = "panel/secondary", w = 26, h = 24, text = "▸", textAlign = "center",
      textValign = "center", onClicked = function() on(1) end } }
end

function editorRows(ed, W, sfx)
  W = W or 330
  local rows = {}
  local function add(x) rows[#rows + 1] = x end
  local function click() if sfx then sfx("click") end end
  local f = ui and ui.focused and ui.focused()
  local typing = f and f.name == "FieldAgencyName"
  add({ "text", key = "ag", style = "panel/label", w = "100%", h = "fit", text = "YOUR AGENCY" })
  add({ "field", key = "name", name = "FieldAgencyName", style = "menu/field", w = "100%", h = 32, maxLen = NAME_MAX,
    placeholder = DEFAULT_NAME, text = typing and nil or ed.typed, textValign = "center",
    onChanged = function(n) editorSetName(ed, n and n.text or "") end,
    onSubmitted = function(n) editorSetName(ed, n and n.text or "") end })
  -- the previews: the emblem and the flag it makes
  add({ "row", key = "pv", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
    { "image", key = "em", w = 132, h = 132, texture = ed.tex or "textures/parts/emblem_default.png", imageFit = "contain" },
    { "col", key = "fc", w = "grow", h = "fit", gap = 6, pad = 0, align = "start",
      { "image", key = "fl", w = 150, h = 100, texture = ed.flag or "textures/parts/flag_default.png", imageFit = "stretch" },
      { "text", key = "mono", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
        text = ed.spec.image and "Your own picture" or string.format("Monogram %s", ed.spec.mono or "") },
      { "button", key = "regen", style = "panel/action", w = "100%", h = 28, text = "↻  Regenerate", textAlign = "center",
        textValign = "center", disabled = ed.spec.image ~= nil,
        tooltip = "Another emblem from the same name",
        onClicked = function()
          click()
          local img = ed.spec.image
          ed.spec = regenerate(ed.spec, ed.name)
          ed.spec.mono = monogram(ed.name)
          ed.spec.image = img
          ed.tweaked = true
          changed(ed)
        end } } })
  if ed.mode ~= "files" then
    add(stepper("sh", "Shape", SHAPE_LABEL[ed.spec.shape] or ed.spec.shape, function(d)
      click(); ed.spec = tweak(ed.spec, "shape", d); ed.tweaked = true; changed(ed) end))
    add(stepper("mo", "Motif", MOTIF_LABEL[ed.spec.motif] or ed.spec.motif, function(d)
      click(); ed.spec = tweak(ed.spec, "motif", d); ed.tweaked = true; changed(ed) end))
    add(stepper("pa", "Colours", ed.spec.palIndex and PALETTES[ed.spec.palIndex].name or "Your own", function(d)
      click(); ed.spec = tweak(ed.spec, "pal", d); ed.tweaked = true; ed.pick = nil; changed(ed) end))
    add(stepper("fo", "Letters", FONT_LABEL[ed.spec.font] or "Stencil", function(d)
      click(); ed.spec = tweak(ed.spec, "font", d); ed.tweaked = true; changed(ed) end))
    -- the four colours: click one to repaint it from the chips
    local sw = { "row", key = "sw", w = "100%", h = 30, gap = 6, pad = 0, align = "center",
      { "text", key = "l", style = "panel/label", w = 74, h = "fit", text = "Paint" } }
    for _, slot in ipairs({ "bg", "ring", "fg", "accent" }) do
      local c = ed.spec.pal[slot]
      sw[#sw + 1] = { "button", key = "s" .. slot, w = "grow", h = 26, fill = hexof(c), radius = 4,
        border = (ed.pick == slot) and 2 or 1, borderColor = (ed.pick == slot) and "#f78c38" or "#00000088",
        tooltip = ({ bg = "The field", ring = "The band and border", fg = "The monogram and lines", accent = "The accent" })[slot],
        onClicked = function() click(); ed.pick = (ed.pick == slot) and nil or slot end }
    end
    add(sw)
    if ed.pick then
      local slot = ed.pick
      add({ "row", key = "chips", w = "100%", h = "fit", wrap = true, gap = 3, pad = 0, items = CHIPS,
        function(c, i)
          return { "button", key = "c" .. i, w = 22, h = 16, fill = hexof(c), radius = 2, border = 1,
            borderColor = "#00000066",
            onClicked = function() ed.spec = setColour(ed.spec, slot, c); ed.tweaked = true; changed(ed) end }
        end })
    end
    local ok, why = paletteOk(ed.spec.pal)
    if not ok then add({ "text", key = "warn", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true,
      text = "Hard to read: " .. why .. "." }) end
    add({ "row", key = "own", w = "100%", h = 28, gap = 6, pad = 0,
      { "button", key = "use", style = "panel/secondary", w = "grow", h = 28, text = "Use my own image…",
        textAlign = "center", textValign = "center",
        onClicked = function() click(); ed.mode = "files"; ed.files = nil end } })
  else
    -- a picture of the player's own, from the user://emblems folder (or
    -- the native picker, when the engine has one)
    if not ed.files then ed.files = customFiles() end
    add({ "text", key = "fh", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Put a PNG or JPG in this folder, then press ↻:" })
    add({ "text", key = "fp", style = "panel/keys", w = "100%", h = "fit", wrap = true, text = emblemsFolder() })
    local list = { "col", key = "files", w = "100%", h = "fit", gap = 3, pad = 0, items = ed.files,
      function(p, i)
        local short = p:gsub("^.*/", "")
        return { "button", key = "f" .. i, style = "panel/row", selected = ed.spec.image == p, w = "100%", h = 26,
          text = short, textValign = "center",
          onClicked = function()
            click()
            refreshCustom()
            local buf, why = loadCustom(p)
            if not buf then ed.msg = "Can't use " .. short .. ": " .. tostring(why) return end
            ed.msg = nil
            ed.spec = deep(ed.spec); ed.spec.image = p
            changed(ed)
          end }
      end }
    if #ed.files == 0 then
      add({ "text", key = "none", style = "panel/cellMuted", w = "100%", h = "fit", text = "No pictures there yet." })
    else
      add({ "scroll", key = "fs", w = "100%", h = "fit", maxH = 110, gap = 0, pad = 0, list })
    end
    if ed.msg then add({ "text", key = "msg", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = ed.msg }) end
    local btns = { "row", key = "fb", w = "100%", h = 28, gap = 6, pad = 0,
      { "button", key = "rf", style = "panel/secondary", w = "grow", h = 28, text = "↻  Look again",
        textAlign = "center", textValign = "center",
        onClicked = function() click(); refreshCustom(); ed.files = customFiles(); ed.msg = nil; changed(ed) end } }
    if canPickFile() then
      btns[#btns + 1] = { "button", key = "ld", style = "panel/secondary", w = "grow", h = 28, text = "Load image…",
        textAlign = "center", textValign = "center",
        onClicked = function()
          click()
          pickFile(function(path, why)
            if not path then ed.msg = why and ("No picture: " .. tostring(why)) or nil return end
            refreshCustom()
            ed.files = customFiles()
            ed.spec = deep(ed.spec); ed.spec.image = path
            changed(ed)
          end)
        end }
    end
    add(btns)
    add({ "button", key = "gen", style = "panel/secondary", w = "100%", h = 28, text = "◂  Back to a generated emblem",
      textAlign = "center", textValign = "center",
      onClicked = function()
        click(); ed.mode = "gen"; ed.msg = nil
        if ed.spec.image then ed.spec = deep(ed.spec); ed.spec.image = nil; changed(ed) end
      end })
  end
  return rows
end

-- Settings ▸ Agency (settings.lua's tab calls this): the same editor on the
-- save's own agency, with Save and Revert. A saved change repaints every
-- plate and flag at once (version bumps).
local sed = nil
local sed_msg = nil
function settingsRows(out, W)
  local function add(x) out[#out + 1] = x end
  if not in_game() then
    add({ "text", key = "agx", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Each save is its own agency. Load a save, then open Settings ▸ Agency to rename it or change its emblem." })
    return out
  end
  if not sed then sed = newEditor(name(), spec()) end
  editorTick(sed)
  local box = { "col", key = "agency_ed", w = math.min(W or 420, 420), h = "fit", gap = 7, pad = 0, align = "start" }
  for _, r in ipairs(editorRows(sed, W)) do box[#box + 1] = r end
  add(box)
  local n, s = editorResult(sed)
  local cur_n, cur_s = name(), spec()
  local dirty = n ~= cur_n or s.seed ~= cur_s.seed or s.shape ~= cur_s.shape or s.motif ~= cur_s.motif
    or s.font ~= cur_s.font or s.image ~= cur_s.image or s.mono ~= cur_s.mono
  if not dirty then
    for _, k in ipairs({ "bg", "ring", "fg", "accent" }) do
      for i = 1, 3 do if math.abs(s.pal[k][i] - cur_s.pal[k][i]) > 1e-4 then dirty = true end end
    end
  end
  add({ "row", key = "agsave", w = "100%", h = 30, gap = 8, pad = 0,
    { "button", key = "save", style = "panel/action", w = 140, h = 30, text = dirty and "Save the agency" or "Saved",
      textAlign = "center", textValign = "center", disabled = not dirty,
      onClicked = function()
        set(n, s)
        sed = nil
        sed_msg = "Saved: every flag and plate now wears it."
      end },
    { "button", key = "revert", style = "panel/secondary", w = 100, h = 30, text = "Revert", textAlign = "center",
      textValign = "center", disabled = not dirty, onClicked = function() sed = nil; sed_msg = nil end } })
  if sed_msg then add({ "text", key = "agmsg", style = "panel/hint", w = "100%", h = "fit", wrap = true, text = sed_msg }) end
  if needsPrompt() then clearPrompt() end
  return out
end

-- ── the node ────────────────────────────────────────────────────────────────

function start(node)
  -- One AgencyLib per scene: a second (two scripts asked for it in the same
  -- frame) stands down.
  if findScripts then
    local all = findScripts("emblem")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then
      node:destroy()
      return
    end
  end
  live = true
  -- The main menu has no agency of its own (the slot cards and the editor
  -- ask for what they need); a game builds its identity at once.
  if is_menu() then return end
  reload()
end

local reported = false
function update(node, dt)
  pump()
  if not reported and cur then
    reported = true
    if log then
      if lastLoadMs and not lastBuildMs then
        log(string.format("emblem: '%s' loaded from the cache in %.1f ms", cur.name, lastLoadMs))
      else
        log(string.format("emblem: '%s' built: %.1f ms of work over %d frame(s)", cur.name, lastBuildMs or -1,
          lastBuildFrames or 0))
      end
    end
  end
end

-- GLYPHS BEGIN (tools/gen_emblem_glyphs.py writes this block; do not edit)
GLYPH_CAP, GLYPH_RES, GLYPH_OX, GLYPH_OY = 40, 32, 16, 48
GLYPH_DATA = {
  stencil = { space = 15.12,
    A = { 39.94, "ObEAO7EAROL+N4YAIEYA", "U+UdQHUdRVP/TqP/QPEAVjEAb6YAV/YA" },
    B = { 38.95, "J5EAPtEAPtYAJ5YA", "Q7TjSHTjS1TjTXThTuTcT/TTUJTFUQSzUUSaUVR3UURUUQQ6UJQoT/QaTvQSTWQMSzQJSHQIQ7QIQ7LrR8LrSqLqTLLoTjLjTzLaT+LNUFK8UJKkUKKFUJJkUFJMT+I7TzItTjIkTLIfSqIdR8IdQ7IdQ7EAUPEAVeEEWjEQXfEkYSFAY7FjZcGPZzHDaBH+aFJCaCKCZ4K5ZnLoZQMPYyMuYMNJXeNfWoNvWoN3XgOHYQObY2OyZVPOZvP2aBQoaNRkaQSqaNTraCUlZwVYZWWFY1WqYMXJXbXhWgXyVdX9URYAQ7YA" },
    C = { 33.02, "QhDzQ0DyRQDxSADxT7D2V0EEWqENXTEWXTIgW8IfWdIbV2IXUkIQTdIOScIPRpISRBIZQhIi", "K0WBKUVMJ8UMJrTBJiSAJcQ1JZPfJXOAJZMSJeKyJlJhJxIcKCHfKZGpK3F6LdFTMLEzNDEaOFEHPTD6PTOAPUPmPXRJPcR2PlScP0S5QHTOQiTeRDTnRrTtSeTxTdTyUgTxVcTuWRTpWzTmXaTgXaXtV5X/UMYJTJYNSAYPQoYNPZYHOUX9NZXuMWXULgWv" },
    D = { 39.53, "J5EAPtEAPtYAJ5YA", "Q7TjRKTjSBTiSsTgTLTbTtTNUESzUQSYUXR1UaRJUdPoUeOAUdMYUaK1UWKJUOJmUDJLT0I4TfIqTFIiSkIfR7IdRKIdQ7IdQ7EARKEASoEBT7EGVCENWBEXW4ElXnE2YOFLYwFkZMGCZiGlZ0HNaBH7aOJCaVKVaYLWaZMlaaOAaZPcaYQraVRsaOS+aBUFZ0UzZiVbZMV+YwWcYOW1XnXKW4XbWBXpVCXzT7X6SoX/RKYAQ7YA" },
    E = { 35.81, "J5EAPtEAPtYAJ5YA", "Q7EAYUEAYUIdQ7Id", "Q7LrW8LrW8QIQ7QI", "Q7TjYUTjYUYAQ7YA" },
    F = { 33.49, "J5EAPtEAPtYAJ5YA", "Q7EAXvEAXvIdQ7Id", "Q7MQWqMQWqQtQ7Qt" },
    G = { 38.37, "QhD1RlDyScDxUID0VvD7XPEHYUERZXEeZXIoYnIjYAIfXhIbXIIZWmIWV7IRVRIPUyIOUeIOTZIOSiIQR4ISRHIbQhIq", "LHWQKiVbKFUaJxTNJmSJJeQ7JZPjJXOAJZMRJfKwJoJeJ2IXKJHZKiGkLCF2LoFQMVEyNLEbOKEJPTD8PTOAPUPRPWQUPaRKPhR1PqSYP2S1QHTMQdTeQ3TrRWTzR+T4SvT6SvYPScYPREYNP1YIOvX/NzXzMvXcL1W7", "T9QVR5QVR5MHZcMHZcXgYdXtXVX4WDYAVBYHT9YL" },
    H = { 41.63, "J5EAPtEAPtYAJ5YA", "VHQTQ7QTQ7LpVHLpVHEAa7EAa7YAVHYA" },
    I = { 19.19, "J5EAPtEAPtYAJ5YA" },
    J = { 24.71, "IlTyJjTyKWTwLATtLgTnL7TdMPTQMiSzMsSMMvQRMvEASjEASjOTSjPnSiQwSgRvSeSkSZTgSRUVSGVCR2VtRiWQRJWtQrXEQGXXPaXmOrXwN1X3M4X7MCX9LCX/J5YAIlYA" },
    K = { 39.71, "J5EAPtEAPtYAJ5YA", "Q7RAQ7KwVhEAb3EAU+Nbb8YAVcYA" },
    L = { 31.45, "J5EAPtEAPtYAJ5YA", "Q7TUXJTUXJYAQ7YA" },
    M = { 51.45, "J5E4J5EAPPEAXnVzWqYAS4YA", "aUPmaNPmYQUUVwO9aUEAf2EAf2YAaUYA", "J5HwPPTJPPYAJ5YA" },
    N = { 41.63, "J5E0J5EAPtEAa7XKa7YAVJYA", "VaLTVaEAa7EAa7Uw", "J5HPPaQrPaYAJ5YA" },
    O = { 40.58, "VAOAVAM2U/L6U/LMU+KsU6J+UzJZUpI9UcIpUKIbTzITTXIQS0IOSJIORaIPQ3IRQhIVQhDzQ2DyRTDxSJDxTsDzVCD5WNEDXMESYBElYvE9ZVFaZzF9aPGvajHravIxa0Jwa4K9a6MXa7OAa7Pca5Qta2RyazSsaqTvacUoaJVaZsWKZGWyYXXRXcXqWVX8VAYH", "MDXTLdW9K8WjKiWDKDVLJuUHJiTBJbRxJaRCJYQKJYPKJXOAJYMkJaLTJcKOJgJUJoITJ2HYKKGmKnF3LNFQL7EwM1EYN9EFPTD5PTOAPUPrPXRSPbSBPhSmPqTCP3TWQJTkQfTrQ5TvRcTxSJTyS3TyTaTwTxTtTxYNTdYOS/YPSJYPQjYNPIYFN6X5M4Xp" },
    P = { 37.50, "J5EAPtEAPtYAJ5YA", "Q7NVRoNVSMNVSqNTTANRTaNJTuM7T7MpUDMPUHLrUIK5UHKGUDJiT7JJTuI1TaIpS/IhSbIeRoIdQ7IdQ7EATWEAUsEDV2EMW2EbXrEwYXFMY5FuZSGTZmG/ZzHxZ7IqaAJtaBK5aAMBZ7NBZ0N5ZnOpZVPUY9P5YZQdXtQ7W4RTV4RkUtRuTWRyQ7Ry" },
    Q = { 40.58, "VAYEVAOAVAM2U/L6U/LMU+KsU6J+UzJZUpI9UcIpUKIbTzITTXIQS0IOSJIORaIPQ3IRQhIVQhDzQ2DyRTDxSJDxTsDzVCD5WNEDXMESYBElYvE9ZVFaZzF9aPGvajHravIxa0Jwa4K9a6MXa7OAa6Pga3Q1aySAarS/acUIaEVIZkWAdZbLdZbWW5bW", "MDXTLdW9K8WjKiWDKDVLJuUHJiTBJbRxJaRCJYQKJYPKJXOAJYMkJaLTJcKOJgJUJoITJ2HYKKGmKnF3LNFQL7EwM1EYN9EFPTD5PTOAPUPrPXRSPbSBPhSmPqTCP3TWQJTkQfTrQ5TvRcTxSJTyS3TyTaTwTxTtTxYLTGYNSkYOSJYPQjYNPIYFN6X5M4Xp" },
    R = { 39.19, "J5EAPtEAPtYAJ5YA", "SGRNQ7RNQ7MwR6MwStMvTSMrTsMlUAMaUNMJUVLzUZLTUaKmUZJ6UVJZUNJCUAIxTuImTVIgS+IeSgIdR6IdQ7IdQ7EAT7EAVNEDWVEMXREaYDEvYtFJZPFqZoGOZ6G4aGHnaOIdaTJdaUKmaSLtaNMsaENiZ4OPZhO/ZCPoYcQJXvQiawYAUpYA" },
    S = { 35.58, "UTIRTeIPSwIOSJIORIIPQLIRQLDxQ5DxTVD2V2EGWtEOXrEaXrImXGIiWWIdVaIY", "S4SGS2RlSyROSrQ/SgQ1SOQwRzQrOOQPNCQDMBPvLKPVKeO0J9OLJiNYJSMaJMLqJIKzJHJ2JLIoJYHjJtGoKLF1KxFMLiErMfERNoD/O9D1O9JrO/KUPBKjPGKuPNK3PZK+PpLCQALEUALkVJLwWDMAWxMVXYM0X2NcYOOPYfPOYpQXYsRqYoTDYbURYGVTXpWKXEW2WQXbVTX0ULYES4YN", "L7X+LBX4KRXyJsXsJsTcK5TiMMToNnTvOdTxPHTyPmTyQhTyRNTwRqTtRqYPRVYPPcYNNpYH" },
    T = { 33.78, "IREAYoEAYoIqIRIq", "NhJ0TWJ0TWYANhYA" },
    U = { 40.12, "K4WJKdVaKKUiJ/TjJ6SrJ2RmJ0QVJzO4JzEAPnEAPnQCPrSGPxSyP8TPQOThQpTrQ/TvRdTxSCTyStTyTOTvTOYNS+YOSpYPSCYPQmYNPVYHOPX9NUXvMUXWLgW0", "UcEAaQEAaQO4aQQNaPRYaMSXaJTLaBUGZzU6ZgVnZDWUYdW5XvXXW1XuVvX/UcYJ" },
    V = { 38.55, "N0XKNJU5MORsL7QvLsP9LfPWLSOlLHOCIJEAOFEAThYAOFYA", "SYPJVUEAbIEAYKOCXGRsWlTVWIU5VdXKVNYAUzYA" },
    W = { 57.91, "M1XKMrWjMgVyMTU5LhRsKpOCITEAOFEASNYANCYA", "RZOATkEAZiEAeTYAZVYAZGXDYfUhXnQ0WkMcWZMcVaQ0VFSTU0TeUkUhT/XDTwYATbYA", "dJN1e4EAkqEAiSOChaRshKSvg8TngyUVgqU5gGXKf5YAfjYA" },
    X = { 39.42, "IREAO3EAbkYAU8YA", "S6IEVHEAbfEAV9M5", "NvO8QwTvOhYAIJYA" },
    Y = { 36.80, "OSRaOBQ0NRPWMiNzMaNjMQNMLDKuH3EANyEAUGRcUGYAOSYA", "SCKMUvEAajEAYSItXUKsVfOgUxQA" },
    Z = { 35.93, "JfEAYzEAYzIIYkIdJfId", "JKTvQqJnXtJnNAYAJKYA", "R1TjYzTjYzYAOhYA" },
    ["0"] = { 38.37, "T5OAT5M2T4L6T4LMT3KsT0J9TvJYToI+TYIkTAIWSqIRSMIPRmIORHIPQhIRQhDzQvDyRDDxRmDxTCDzUTD5VZEDWTESXFElXvE9YTFaYwF9ZLGvZeHrZpIxZuJwZyK9Z0MXZ0OAZ0PeZyQxZwR3ZsSxZkTzZWUtZCVgYlWQX/W3XQXWWWXuVOX/T5YJ", "KcWBKBVPJuUUJjTPJeSRJaREJYPpJXOAJYMiJaLPJcKJJgJPJoINJ2HTKKGgKnFwLNFJL8EqM2ESN+EBPTD3PTOAPTPJPTQFPUQyPVRSPYSAPeSlPmTCP2TcQNTqQiTvRATxRmTySLTySrTvSrYNSdYOSJYPRmYPQLYNO6YHN0X9M5XuMIXbLdXDK5Wl" },
    ["1"] = { 23.37, "L/J2ITLPITGtN8EARzEARzYAL/YA" },
    ["2"] = { 35.70, "JxEgMREDOzD0RZDxRZITRCIRQjIPP5IOPGIOOEIPM5IULlIdJxIs", "JXVEJYT5JbS4JfSBJrQ7J/QAKePLLIOdLrOCMXNpNJNRQjL6RJLqRqLbSDLOSTLASdKySjKiSmKMSnJvSnDzT6D7VBEIV8EdWvE8XWFiX0GSYKHMYXIQYbJeYXKxYML6X6M2XgNoW/OPWWOyVkPQUpPqQhRQQDRdPqRpPYR0PMR/PESMPASdO/S1O/TaO/YAJXYA", "QNTeYbTeYbYAQNYA" },
    ["3"] = { 35.47, "JfEeLvEFN7D2QDDxQpDyRDDzRDITQhIQP5IOPKIOOmION6IPNGIRJfIo", "ScR/SaRaSVQ/SMQqR+QaRsQSRRQMQuQJQBQIM1QIM1LrQBLrQtLqROLnRmLiR5LZSFLLSMK6SQKhSRJ9SRD5TdEDUgETVaEnWLFAWzFeXaGLX2G/YHH8YMJCYJKCX/K5XuLoXXMPW5MuWTNJVlNfUvNvUvN3VnOHWXObW+OyXcPOX2P2YJQoYURkYXSqYTTzYFUzXuVpXNWWWlW4VzXUU2XrTuX8ScYH", "JXXiJXTYLoTnNuTvPpTyQXTxROTvROYNQ1YOQPYPPHYNN5YJMkYBLTX3KOXt" },
    ["4"] = { 38.02, "I4QMPZEAVuEAMsUJI4UJ", "SJUJOFUJQlPsSLPsUXLtX2LtX2PsaSPsaSUJX2UJX2YASJYA" },
    ["5"] = { 36.51, "S9RwS8RFS3QnStQQScQASEP1RkPvRJPsQnPrP+PqN/PtL5P1LGP6KgP9KIP/KIEAPCEAPCLZQALTQ7LRRtLPSWLOS2LNUJLSVSLeWRL0XFMRXvM3YHNaYaOBYoOuYxPfY3QXY5RUY3SZYxTXYoUMYaU7YHVmXvWLXPWrWpXHV6XeVEXwUFX+S9YH", "QQEAXaEAXaIgQQIg", "J5XiJ5TYMBTmN9TuPtTwQiTwROTvRvTtRvYNRKYOQWYPOlYMM2YCLwX5KxXu" },
    ["6"] = { 38.49, "XJIfWCIYVFIUUUIQTsIOTQIOSUIPRkISQ/IaQhImQhDzREDyR3DxTqD0VgD+WtEHXzESYxEeYxIo", "MqXsMCXaLgXELCWpKqWIKVVhKEU1J0T4JoSuJfRXJZPyJXOAJZMQJfKuJoJZJ2IQKJHSKiGcLBFvLmFKMTEtNJEXOJEGPTD6PTRjPVSSPbS1PmTNP2TgQJTqQgTvRATyRtTyScTyStTxTBTvTBYNSzYOSgYPR8YPQuYOPqYMOxYHNnX9", "UPRwUNRGUIQnT+QPTwP/TcP0TCPuSePrRtPqREPrQhPwQhL0RbLfSdLSTmLNUqLPVmLTWZLZXGLkXtL1YQMLYwMqZKNSZeOCZtO7Z1P/Z4RNZ2SVZxTWZnUOZaU/ZIVrYxWQYTWxXuXMXCXiWPX0VTYBUPYJ" },
    ["7"] = { 33.49, "I6EAX4EAX4IGXtIgI6Ig", "RIJrXLJrQ9YAKmYA" },
    ["8"] = { 39.30, "LBWwKfWQKDVsJwVDJiUWJaTiJXSqJbRkJmQoJ5P2KTPOKxOyLYObMIOHNAN3NANvMKNfLcNJK2MuKYMPKALoJwK5JmKCJjJCJoH6J3G9KRGJK0FfLeFAMREmNMESOREDPeD5PeJ9PfKmPjLDPqLXP4LmQKLvQjL1RFL5R1L6SkL5THL1TgLvTzLmUALXUHLDUKKmUMJ9UKJWUHI5UAIjTzITThIJTJIDSmIAR1H/ROH/QsIDQsDzQ7DyRQDxR1DxTTDzUoD7VyEHWzEXXqEtYXFHY7FlZYGIZtGuZ7HZaEILaHJCaEKCZ6K5ZpLoZSMPY0MuYNNJXfNfWqNvWqN3XiOHYRObY4OyZXPOZxP2aDQoaPRkaSSqaOTyaBUxZpVnZGWWYdW4XrXVWuXrVnX8UXYHUXR/UVRVUPQ1UFQeT3QNTjQDTJP9SmP6R1P5REP6QgP9QGQDPzQNPkQePaQ1PVRVPTR/PVSnPZTFPjTbPzTrQHT2QhT8RFUAR1UBSjUBS0UATJT9TJYNS4YOSgYPR1YPQSYMO6YENsX3MoXlLwXN" },
    ["9"] = { 38.49, "T9KdT7JtT0JKTpIxTZIfTHIUSxIQSeIPSEIORiIOQ0IOQjIPQPIRQPDzQcDyQwDxRTDxSqDyT2D2U4D8VvEFWtEWXhExYMFWYoF6Y/GnZSHbZgIYZrJfZyKzZ3MTZ4OAZ2PxZxRTZoSnZbTvZIUtYwViYRWPXrW1W9XSWHXpVHX6T9YG", "LBPzKiPUKHOtJyN9JjNEJaMBJXKzJZJqJfIqJoHxJ2G/KIGTKgFuK9FOLhEzMMEdM/EMN7D/PAD3PAKQPCK5PILZPSLvPgMAP0MLQPMRQyMVRiMWSNMVSvMQSvQMR0QhQyQuPpQzOlQxNqQtM3QmMKQaLjQJ", "KeXiKeTYL8ThNiTqOjTvPYTxQATyQ8TxRsTuSRTmSvTaSvYNQjYLOWYDM7X6LpXv" },
    ["&"] = { 42.97, "VyIDU2IBUEH/TbH/SLIARJIEQWIKQWD3RYDzShDxVID3XjEHYuESZ0EeZ0IZ", "K+WwKaWRJ/VuJtVGJhUYJaTkJXSqJbRkJmQoJ5P2KTPOKxOyLYObMIOHNAN3NANvMKNfLcNJK2MuKYMPKALoJwK5JmKCJjJCJnH+J1HDKLGRKrFoLQFJL/EvM4EZN7EIPID8PIJ9PJKiPNK+PVLSPgLiPwLrQHLyQmL1RQL2SvL2SvP9RQP9QjP+QCQAPqQGPZQRPLQhPCQ3O+RWO9R/O/SmPGTEPTTZPnTpQFT0QrT8RMT/R0UASjUBTWUBTWYPSjYPQyYMPOYEN2X3MsXlLuXN", "UkL2c6L2c6P9Z8P9Z8XiY+XuX4X4WoYAVoYHUkYL" },
    ["-"] = { 22.03, "JXNkRqNkRqR5JXR5" },
    ["."] = { 19.19, "J3TRPvTRPvYAJ3YA" },
    ["'"] = { 17.44, "J5FbJ5EAO1EAO1FbOQLrKeLr" },
    ["!"] = { 21.10, "K6LAK2KdKyJtKtIxKgGzKZFQKVEcKVEAQ0EAQ0EcQyFQQpGzQdIxQPLAPpQ2LfQ2", "KnTRQfTRQfYAKnYA" },
    ["?"] = { 30.29, "L0O9L3OGMANXMPMwMkMSM6MANSLzNwLnOXLZOzLPPLLGPdK8PpKxP1KXP3KGP4JvP4DxRHD2SNEBTKEUT/EyUmFYVFGGVbG/VoIAVsJLVpKRVgLNVRL/U8MnUlNBUKNWTpNnTBN3RkOWRROdREOjQ9OqQ3O0QzPDQyPWQxPjQwP3QwQTQwQ2L0Q2", "JBEYKBENLKEDMbD6OqDzOqIQOeIOOMIONnIOMuIPLtITKkIZJBIk", "LYTRRQTRRQYALYYA" },
    ["/"] = { 24.94, "QHCaUzCaMVZmHsZm" },
    ["+"] = { 31.40, "N6SmKCSmKCOtN6OtN6K1RzK1RzOtVqOtVqSmRzSmRzWdN6Wd" },
  },
  label = { space = 11.43,
    A = { 31.54, "TsXuS8UqS5UlSzUjM7UjM1UlMxUqMEXuL7X7LqYAI8YAIwX9IqX1IqXoN3ESOAEFOQEARhEARxEFR7ESXHXoXJXwXEX8W1YAUFYAT1X7", "NmR8SHR8SPR6SQRxP7IaP1IUPwIaNdRxNfR6" },
    B = { 30.97, "QQYAKLYAJ7X6J1XqJ1EWJ7EGKLEAP7EARSEFSfEWTiExUbFXVAF9VdGqVxHeV+IYWCJaV8KhVqLfVNMUUjNBTuNlTpNqTsNwUfORVIO5VpPpWAQfWORcWSShWOTiWBUcVsVQVOV+UnWlTuXNSsXpRiX6", "NJHANJMUNLMbNSMdP8MdQxMYReMJSDLvSeLLSuKgSzJsSuI3SeIKSDHmReHMQxG8P8G3NSG3NLG5", "S+SFS5RNSoQdSNP2RoPZQ8PIQHPCNSPCNLPENJPLNJU+NLVFNSVHQJVHQ9VCRpUxSOUUSpTuS5S+" },
    C = { 30.46, "JaSLJaJxJfIoJwHkKMGnKyFyLhFFMaEhNaEHOgD3PsDxQ4D3R+EGS+EgT3FDUmFvVMGkVoHfV5IiV+JqV+J1V4KFVxKLVoKNS+KUSyKSSrKKSoJ+SoJoSiIzSRIER0HdROHAQgGuPsGoO2GuOIHANiHdNFIEM0IzMuJoMuSaM0TPNFT9NiUkOIVBO2VSPsVYQgVSROVBR0UkSRT9SiTPSoSaSoSCSuRzS+RuVoR1V4R7V+SLV+SSV5TbVoUeVMVbUmWQT3W8S+XgR+X6Q4YJPsYPOgYJNaX5MaXeLhW5KyWMKMVWJwUYJfTV" },
    D = { 31.14, "J1XqJ1EWJ7EGKLEAQFEARaEGSlEZToE4UiFjVIGNVmG8V8HxWJIrWNJqWNSWWJTVV8UPVmVEVIVzUiWdToXISlXnRaX6QFYAKLYAJ7X6", "NSVJQHVHQ4VBRiUvSFURSgTpSxS4S5R+S5KCSzJISjIXSIHuRkHPQ5G9QHG3NSG3NLG5NJHANJVANLVH" },
    E = { 29.31, "VPG3NSG3NLG5NJHANJMYNLMfNSMhSYMhSnMnSuM3SuPCSnPRSYPYNSPYNLPaNJPhNJVANLVHNSVJVPVJVeVQVlVfVlXqVeX6VPYAKLYAJ7X6J1XqJ1EWJ7EGKLEAVPEAVeEGVlEWVlGhVeGw" },
    F = { 27.94, "VNG3NSG3NLG5NJHANJMYNLMfNSMhSYMhSnMnSuM3SuPCSnPRSYPYNSPYNLPaNJPhNJXqNDX6MzYAKLYAJ7X6J1XqJ1EWJ7EGKLEAVNEAVcEGVjEWVjGhVcGw" },
    G = { 30.69, "JaSQJaJwJfInJwHkKMGnKyFyLhFFMZEhNYEHOeD3PqDxQ2D3R8EGS8EgT1FDUkFvVKGjVmHdV3IdV8JjV8KNV2KcVmKjS+KjSvKcSoKNSoJjSiIvSRICR0HcROG/QgGuPqGoO2GuOIHANiHeNFIGM0I1MuJsMuSUM0TLNGT6NkUiOLVAO6VSPwVYQkVSRRVCR2UnSSUDSjTXSoSjSoQSSmQLSfQJP5QJPpQDPjPzPjNuPpNeP5NYVmNYV2NeV8NuV8SLV4TQVrUPVVVIU2V7UPWnTgXNSrXpRxX+QwYKPqYPOeYJNYX5MZXfLhW7KyWOKMVZJwUcJfTZ" },
    H = { 31.83, "TNEAV1EAWFEGWLEWWLXqWFX6V1YATNYAS9X6S3XqS3PjS1PcSuPaNSPaNLPcNJPjNJXqNDX6MzYAKLYAJ7X6J1XqJ1EWJ7EGKLEAMzEANDEGNJEWNJMYNLMfNSMhSuMhS1MfS3MYS3EWS9EG" },
    I = { 13.89, "J1XqJ1EWJ7EGKLEAMzEANDEGNJEWNJXqNDX6MzYAKLYAJ7X6" },
    J = { 29.26, "IlSfIlQfIrQQI7QJLjQJLyQQL5QfL5ShL+TUMOUAMpUlNNVBN4VSOqVYPcVSQIVBQuUlRKUARbTURhShRhEWRnEGR3EAUdEAUtEGUzEWUzSfUuTlUdUmUCVgTcWTSuW+R3XhQ4X6P0YKOqYPNmYLMoX/LvXqK8XOKPWqJoV/JLVPI2UaIpTf" },
    K = { 31.37, "J1XqJ1EWJ7EGKLEAMzEANDEGNJEWNJMlNNMsNUMoTLEPTWEETlEAWdEAWoECWvEIWwERWsEbRSMdRSMqXFXmXJXxXFX8W3YAT8YATsX8ThXwPAPPO7PJOzPNNNRaNJRlNJXqNDX6MzYAKLYAJ7X6" },
    L = { 28.17, "J1XqJ1EWJ7EGKLEAMzEANDEGNJEWNJVANLVHNSVJVJVJVZVQVfVfVfXqVZX6VJYAKLYAJ7X6" },
    M = { 35.83, "VJEAXzEAYDEGYJEWYJXqYDX6XzYAVLYAU7X6U1XqU1KHUxJ/UqKERoPERePPRPPSQsPSQcPPQSPENQKFNJKBNFKJNFXqM/X6MwYAKHYAJ4X6JxXqJxEWJ4EGKHEAMwEAM/EENJEPQ5KNQ+KSREKNUwEPU6EE" },
    N = { 33.60, "UCEAWqEAW6EGXAEWXAXqW6X6WqYAT5YATqX8TfXwNQK8NJK4NFLANHXqNBX6MxYAKJYAJ6X6JzXqJzEWJ6EGKJEAM5EANIEENSEQTjRHTqRMTuRETsEWTyEG" },
    O = { 31.09, "JaSCJaJ+JfIzJwHuKMGvKyF3LiFIMbEjNbEHOiD3PwDxQ+D3SFEHTGEjT/FIUvF3VWGvVyHuWDIzWJJ+WJSCWDTOVyUUVWVTUvWLT/W6TGXfSFX7Q+YLPwYQOiYLNbX7MbXfLiW6KyWLKMVTJwUUJfTO", "S1SLS1J5SvI+SdIMR/HiRXHCQnGvPwGoO5GvOKHCNjHiNFIMM0I+MuJ5MuSLM0TENFT2NjUgOKVAO5VTPwVaQnVTRXVAR/UgSdT2SvTE" },
    P = { 30.06, "WQJ7WLLBV9MBVkM8VCNwUYOcTlO/StPZRvPpQsPuNLPuNEPwNCP3NCXqM7X6MsYAKEYAJ0X6JuXqJuEUJ0EFKED+QqD+RuEDSsETTlEuUYFSVCF/VkG0V9HxWLIz", "S8J+S3JFSnIVSMHsRoHNQ9G7QLG1NLG1NEG3NCG+NCM7NENBNLNEQLNEQ9M+RoMsSMMOSnLmS3K2" },
    Q = { 29.77, "VmKCVmSFViTLVUULU8VGUbV7TzWqTDXQSMXtRPYCRJYFRHYLRHaoRBa4Qxa+OHa+N4a4NxaoNxYLNwYFNqYCMtXuL2XRLGWsKdV9J8VIJlUNJXTMJSSFJSKCJYI2JoHwKEGwKpF5LXFKMOEkNMEIORD3PbDxQmD3RrEISqEkThFKUQF5U1GwVQHwVhI2", "SSJxSNI5R8IJRgHgQ7HBQPGuPbGoOpGuN+HBNZHgM9IJMsI5MmJxMmSPMsTHM9T3NZUgN+U/OpVSPbVYQPVSQ7U/RgUgR8T3SNTHSSSP" },
    R = { 30.69, "S+XuP5PhPwPaNSPaNLPcNJPjNJXqNDX6MzYAKLYAJ7X6J1XqJ1EWJ7EGKLEAQxEAR0EFSyEVTqEvUcFSVFF+VmGyV/HuWNIvWSJ1WMLBV6MGVbNEUyN4UAOiTFPATAPFTAPNWYXmWaXxWVX8WHYATYYATHX7", "NJHANJMsNLMzNSM1QSM1RCMvRsMeSPMBSpLaS5KsS+J3S5JASpISSPHrRsHORCG9QSG3NSG3NLG5" },
    S = { 29.31, "JFSxJFSCJMRyJbRsMARsMQRyMWSCMWSmMcTYMuUCNNUmN2VCOnVSPhVYQWVTRCVERlUsR+UMSNTlSSS5SMSLR5RkRaRBQwQiQMQLPcPwOhPQNbOrMgOILuNoLDNHKdMgJ7LzJiLAJSKGJNJFJRIJJeHSJzGgKQF0K2FNLvElMwEIN5D3PLDxQXD2RdEFSdEeTWFAUEFrUqGdVFHXVWIWVbJaVbKAVVKQVFKWShKWSRKQSLKASLJdSFIsRzIBRWHbQvG/P/GuPHGoOXGtNtG7NLHRMyHwMiIWMdJEMjJxM1KYNTK6N9LaOjLwPUMLQQMqRONNSDNtSvOITSOfT6O+UdPiU7QMVTQ8ViRyVmSwViTtVVUmVAVZUhWHT7WwTAXZR8X3QwYJPaYPOMYKNGX8MFXkLNXDKeWaJ4VpJcUxJLT0" },
    T = { 29.49, "V3EWV3GjVwGyVhG5RFG5Q/G7Q8HCQ8XqQ2X6QmYAN+YANvX6NoXqNoHCNmG7NfG5JPG5I/GyI5GjI5EWI/EGJPEAVhEAVwEG" },
    U = { 31.83, "JqSAJqEWJwEGKAEAMoEAM4EGM+EWM+SLNETENVT1NyUfOZU/PHVRP8VYQyVRRgU/SHUfSlT1S2TES8SLS8EWTDEGTSEAV7EAWKEGWQEWWQSAWLTMV6USVeVRU4WJUJW4TQXdSQX5RKYJP8YPOwYJNqX5MqXdLyW4LCWJKcVRKAUSJwTM" },
    V = { 30.86, "N5XuI1EYI1EQI6EEJJEAL+EAMNEFMWESPuSqPzSxP5SqTLEUTUEFTjEAWUEAWhEDWnELWmEYRjXuRaX7RJYAOSYAOCX7" },
    W = { 44.06, "NPXuIuEYIuEQIzEEJCEALxEAMBEFMJEUOzQzO5Q5O+QxRbEURiEFRzEAUSEAUiEFUqEUXUQzXaQ7XfQzaAEUaIEFaYEAdAEAdOEDdUELdUEYZEXsY8X7YsYAWHYAV3X7VwXsTHKzTCKuS8KzQdXsQWX7QFYANmYANXX7" },
    X = { 30.74, "I8XmNwOFNwN7I8EaI5EPI+EEJNEAL+EAMOEEMYEQPoK7PuK+PzK7TCEQTNEETbEAWLEAWWECWcEGWeEOWbEaRoN7RoOFWbXmWfXxWaX8WLYATbYATNX8TCXwPzRHPuRDPoRHMYXwMOX8L+YAJNYAJCX+I7X6I5Xy" },
    Y = { 30.17, "N5XoN5P7N3PwI7EaI5EPI9EEJLEAL+EAMPEEMYEQPdL+PjMFPoL+SsEQS1EETFEAV7EAWFECWLEHWNEQWLEaRNPwRLP7RLXoRFX4Q1X+OPX+N/X4" },
    Z = { 27.43, "I5XqI5VSJAU3RCHCRDG6Q7G3JPG3I/GwI5GhI5EWI/EGJPEAUWEAUlEGUsEWUsGuUlHJMjU+MiVGMqVJUWVJUlVQUsVfUsXqUlX6UWYAJPYAI/X6" },
    ["0"] = { 29.09, "JWSaJWJmJaIkJmHoJ7GxKYGAK9FULpEvMbETNSD+OODyPQDuQTDyRQD+SIETS5EvTlFUULGAUoGxU8HoVJIkVNJmVNSaVJTcU8UYUoVPULWBTlWtS5XSSIXvRQYEQTYQPQYUOOYQNSYEMbXvLpXSK9WtKYWBJ7VPJmUYJaTc", "R5SmR5JdR0IpRkH9RLHYQpG8QAGsPQGmOiGsN5G8NYHYM+H9MvIpMqJdMqSmMvTaM+UFNYUqN5VFOiVWPQVbQAVWQpVFRLUqRkUFR0Ta" },
    ["1"] = { 17.89, "MQEAPAEAPQEGPWEWPWXqPQX6PAYAMYYAMIX6MCXqMCHdL+HWL3HUJQICJJIEI7H/I3HwIxF1I1FlJAFbL1EFMAEB" },
    ["2"] = { 27.89, "NdVJUoVJU4VQU+VfU+XqU4X6UoYAJhYAJRX6JLXqJLVdJNVQJUVCLWSjNQQIPENxP1MpQbLoQ3KuRHJ6RNJNRIIeQ6H2QjHVQEG8PeGtOzGoOJGtNkG8NFHUMuH1MgIcMbJJMbKFMVKVMFKbJbKbJMKVJFKFJFI3JPHxJlGzKGF7KzFLLqEkMnEINsD3O3DxP9D2Q9EFR3EeSqFATUFpT2GaUPHQUeILUjJLUfKDUTK9T/L3TjMzS/NySSOzR0PdROQOQhRIPtSIOxTQOaTtN8URNYU+NWVF" },
    ["3"] = { 27.31, "UaRuUVS4UJT9TzU7TVV5StWuR7XYRQXwQfYBPpYLOuYPNqYKMsX8L0XlLCXFKXWcJ1VuJbU5JLT+JDTFI+SCJBR2JIRuJURsL8RsMJRuMQR2MSSCMXSxMdTaMoT+M4UdNPU2NqVJOKVUOuVYPPVVPtVLQHU7QdUkQuUJQ7ToRFSlRJRdRHQkRBPzQ3PJQmOjQPOFP0NwPTNjOuNfOQNkNwNxNhN3NQNwL8MQL1MAL7LxQHHCQLG6QCG3JmG3JXGwJQGhJQEWJXEGJmEAT8EAUMEGUSEWUSGoUQG3UJHCQYLhQWLoQbLsRML3R4MKSgMlTCNITfNwT1OfUJPeUWQj" },
    ["4"] = { 29.83, "V8QJV8SbV2SrVmSxUlSxUeS0UbS7UbXqUVX6UFYARdYAROX6RHXqRHS7RFS0Q+SxJJSxI6SrIzSbIzQlI1QYI5QJNjEQNsEEN8EAQwEAQ+EDREELRCEaMoPoMpPwMwPzQ+PzRFPxRHPqRHL+ROLvRdLoUFLoUVLvUbL+UbPqUePxUlPzVmPzV2P6" },
    ["5"] = { 27.31, "UuRwUsStUmTjUbUSUHVLTsV9TKWoSgXMRwXoQ6X9P/YJO+YNN9YJNCX8MLXnLbXJKwWkKOV3JzVDJhUHJYTdJUS+JUS7JaStJqSoMUSoMjStMqS8MuTSM3TsNDULNTUmNoU7OBVKOeVTO+VWPhVSP/VIQaU2QvUeRAT/RLTbRVStRYRxRVQ0RLP+RAPdQvPBQaOsP/OdPhOUO+OQOQOWNnOnNHPDMwPqMnP4MYP8JoP8JZP2JSPmJSEWJZEGJoEAT3EAUGEGUNEWUNGhUGGwT3G3MwG3MpG5MmHAMmMUMqMbMxMYNZL8OHLoO6LcPuLYQyLeRvLvSlMMTSM0T2NlUQOhUhPeUqQj" },
    ["6"] = { 27.37, "UwRwUqTEUYUWUFVOTsV/TKWpSiXNRzXpQ9X9QDYJPCYNOFYJNOX+MbXsLuXSLGWyKlWLKKVeJ1UqJxUfJhTvJXS3JUR3JSI3JZHxJrGyKKF6K2FKLsEjMpEINuD3O7DxQED3RGEISBEjS1FKTfF6T+GxUQHuUWIzUWJdUQJtUAJzRYJzRIJtRCJdRCJFQ+IbQxH2QbHXQAG/PfGxO7GsOSGxNvG/NRHXM7H3MtIdMoJJMoMNMsMUMzMSNYL2OALiOtLWPdLSQlLZRlLtSdMOTNM6TyNxUNOxUgPsUsQr", "RaRqRUQjREPjQuO4QROaPtOIPAOCOTOINtObNQO5M7PlMwQLMqQ5MoRuMsSwM3ToNGUQNcUuN3VEOZVSPAVWPnVRQJVEQkUtQ6UNRJTlRVSp" },
    ["7"] = { 25.14, "LFXmQmHCQmG6QfG3LdG3LWG5LUHALUIJLOIZK+IfI8IfItIZImIJIoEWIvEGI+EATzEAUDEGUJEWUJGoUFHEOjXuOaX7OLYALWYALNX+LGX6LEXy" },
    ["8"] = { 27.66, "UqSQUmTRUaUNUFVETlV+S6WwSGXZRKX3QGYJO7YPNyYJMvX3LxXaK8WxKQV/JuVEJaUKJPTOJLSPJPRMJcQMJxPPKKOkKpOBLPNlLUNfLQNYKwM9KUMdJ8L5JmLFJZKLJUJLJaIAJtG8KNGAKuFULXEvMIERM/D8N7DuO7DqP7DuQ2D7RtEQSdEuTGFSToF+UJG+UcICUjJLUeKKUPLFT3L7TSMtSjNWSfNdSjNjTIN/TnOhUAPLUXQGUlRI", "MlJYMnKAMwKlM+LFNULmNwL9OTMMO7MQPjMMQGL9QjLkQ7LCRLKRRQJWRLIfQ7HxQmHQQIG3PjGmO5GhORGmNuG2NQHQM7HzMqIi", "RUSARSRPRKQkQ+QAQnPaQJO+PlOuO7OoOQOuNrPANNPcM5QCMsQnMlRRMjSAMlStMsTVM5T5NNUhNrU/OQVSO7VYPlVSQKU/QoUhQ+T5RKTVRSSt" },
    ["9"] = { 27.43, "T8HhUOITUYJLUbKJUbTJUVUPUDVOTkWGS5W2SDXdRGX4QBYJOzYPNqYJMoX4LtXdK5W2KOWGJwVPJeUSJYTNJYSjJeSTJuSNMWSNMlSTMsSjMsS7MwTlM9UKNSUpNuVBOPVPO1VUPdVPQAVBQeUpQ1UJRDTjRHS3RHPxREPqQ8PsQZQJPwQdPDQqOQQuNJQnMJQTLQPyKhPGJ8OPJhNPJPMWJELWJAKQJFI4JWHqJoGyKCGBKjFXLMEzL7EXMwEDNrD3OsDzPoD3QgECRTEUSAEuSoFOTJF1TkGiT5HW", "RHKSREJVQ5IYQtH3QcHcQGHGPtG3PQGtOwGqOHGvNmG8NKHTM0HzMlIbMaJUMWKWMYLJMfL2MqMdNANINeNmODN4OwN+PdN4QDNlQgNFQzMbRCLc" },
    ["&"] = { 36.29, "Y1XzYwX9YjYAVoYAVZX9VNXzUJWjUDWfT8WhSvXSRdX1QHYJOuYQNgYLMbX8LdXjKnXAKDWdJoV0JUVFJIUQJETWJHSbJTRlJmQzKBQFKvPOLnOZMoNmMrNgMqNaMAMhLeLwLELHKyKlKdJmKWIjKcHiKtGoLJF0LwFGMhEhNZEHOZD3PfDxQfD2RaEDSQEZTBE2TqFbULGHUjG5UyHwU3IsUwJ0UcK1T7LwTNMlSWNYRUOJRROPRSOWR+PJSyQHTuRQUNR5UUR9UbR7VQQwV7PsWIPhWYPlYUQsYfQ6YbRJXZSxWSUSWQUYWSUdYwXl", "NqIxNvJVN8J5ONKWOoK9PNLuPTLyPaLwQULCQ/KURTJ0RfJSRjIuRfILRTHuRAHVQnHCQJG3PmGzPDG3OlHDOMHWN5HwNuIO", "SEUPSJUJSFUCQqSUQPRzOxQCOrP+OlQANqQwM+RgMqSCMeSmMaTNMeT1MtUXNFUzNlVJOMVVO7VaPsVVQeVHRRUv" },
    ["-"] = { 20.80, "I3QfI3OUI9OFJNN+RPN+ReOFRlOURlQfReQvRPQ1JNQ1I9Qv" },
    ["."] = { 13.83, "JaWCJeVeJqU/J+UlKZUQK4UELbUAL/UEMeUQM4UlNMU/NXVeNbWCNXWlNLXEM3XfMcXzL+YALbYEK4YAKZXzJ+XfJqXEJeWl" },
    ["'"] = { 8.74, "I1J8IjEYIoEHI3ECLjECLyEHL3EYLjJ8LhKFLbKMLLKSJNKSI8KMI3KF" },
    ["!"] = { 17.26, "LAQ7KsEWKyEGLCEANqEAN6EGOAEWNqQ7NkRKNURQLWRQLGRK", "KPV7KTVXKfU4KzUeLOUKLtT+MQT7M0T+NTUKNuUeOCU4OOVXOSV7OOWeOCW9NuXYNTXsM0X4MQX8LtX4LOXsKzXYKfW9KTWe" },
    ["?"] = { 26.06, "MaRjMaQYMfPeMwOsNIOCNkNfOHM+O1MYPdL2P+LWQYK4QqKZQ1J1Q5JNQ0IgQmH6QQHbPxHDPNG0OjGwN2G1NQHEMwHdMXH/MJImMEJSMEJ5L+KILuKNJFKFI9KEI2J+IwJuIwJSI1IPJFHRJfGZKDFnKwE8LlEbMhECNiDzOoDuP2D0Q7EFR4EjStFMTYF/T2G5UJH8UPJFUMJ5UEKnT2LQTbMFS7MwSSNWRfOCQ8OfQfO5QJPRP6PqPxQFPuQlPuRjPnRyPYR5MwR5MgRy", "MAWAMEVdMQU+MlUkM/UQNeUEOCUAOlUEPEUQPfUkPzU+QAVdQEWAQAWkPzXDPfXdPEXyOlX+OCYCNeX+M/XyMlXdMQXDMEWk" },
    ["/"] = { 23.83, "IuXmPHESPQEFPfEASHEASRECSXEGSZEOSYEaL+XuL1X7LmYAI+YAI1X+IvX6IsXy" },
    ["+"] = { 26.57, "UdOLUdQJUXQZUHQfQHQfQAQhP+QoP+UmP4U2PoU8NqU8NbU2NUUmNUQoNSQhNLQfJNQfI9QZI3QJI3OLI9N7JNN1NLN1NSNzNUNsNUJqNbJbNqJUPoJUP4JbP+JqP+NsQANzQHN1UHN1UXN7" },
  },
}
-- GLYPHS END
