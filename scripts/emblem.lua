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
--   rasterEmblem(spec, name [, size [, image]])  → pixels (size² × 4)
--   rasterFlag(spec, name, emblemPixels)         → pixels (FLAG_W × FLAG_H)
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
-- Everything is a signed distance in design units (a 256-unit square for the
-- emblem, 512×341 for the flag), painted layer by layer with one pixel of
-- antialiasing. A layer is painted over its bounding box in 8-pixel tiles: a
-- tile whose centre is further from the edge than the tile is wide is wholly
-- in or out and is filled without looking at its pixels, so the cost follows
-- the edges, not the area.

local sqrt, floor, abs, min, max, cos, sin, atan2, pi =
  math.sqrt, math.floor, math.abs, math.min, math.max, math.cos, math.sin, math.atan2 or math.atan, math.pi

-- A canvas: premultiplied colour and coverage, 0..1, row-major from the top.
-- TIME-SLICING. A build run inside a coroutine (the service's jobs) gives the
-- frame back whenever it has worked SLICE.budget ms, so no build ever stops
-- the game; called plainly (the tests, the tools) it runs straight through.
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

-- The planes are kept between builds (one set per size): a rebuild clears
-- them rather than making half a million table slots again.
local pool = {}
local function canvas(w, h, k)
  local key = w * 8192 + h
  local p = pool[key]
  if not p or p.busy then
    p = { R = {}, G = {}, B = {}, A = {} }
    if not pool[key] then pool[key] = p end
  end
  local R, G, B, A = p.R, p.G, p.B, p.A
  for i = 1, w * h do R[i], G[i], B[i], A[i] = 0, 0, 0, 0 end
  return { w = w, h = h, k = k or 1, R = R, G = G, B = B, A = A }
end

local TILE = 8
-- paint(cv, sdf, x0, y0, x1, y1, col, alpha, exact)
--   sdf(x, y) → distance in design units (negative inside); the box is in
--   design units; `exact` (default true) lets whole tiles be skipped or
--   filled — only for true distance fields (circles, boxes, polygons and
--   their unions/intersections, glyphs within their range).
local function paint(cv, sdf, x0, y0, x1, y1, col, alpha, exact, reach, bound)
  local k, w, h = cv.k, cv.w, cv.h
  local R, G, B, A = cv.R, cv.G, cv.B, cv.A
  local cr, cg, cb = col[1], col[2], col[3]
  alpha = alpha or 1
  local px0, py0 = max(0, floor(x0 * k) - 1), max(0, floor(y0 * k) - 1)
  local px1, py1 = min(w - 1, floor(x1 * k) + 1), min(h - 1, floor(y1 * k) + 1)
  if px1 < px0 or py1 < py0 then return end
  local inv = 1 / k
  local half = TILE * 0.7072 + 1.0      -- the tile's half-diagonal, plus the AA pixel
  reach = reach or math.huge             -- beyond this (px) the field isn't trusted
  for ty = py0, py1, TILE do
    step()
    local ty1 = min(py1, ty + TILE - 1)
    for tx = px0, px1, TILE do
      local tx1 = min(px1, tx + TILE - 1)
      local state = 0                     -- 0 per pixel, 1 all in, -1 all out
      if exact ~= false then
        local cx, cy = (tx + tx1 + 1) * 0.5, (ty + ty1 + 1) * 0.5
        local d = sdf(cx * inv, cy * inv) * k
        if d > half and d < reach then state = -1 elseif d < -half and -d < reach then state = 1 end
      elseif bound then
        -- a lower bound on the distance: enough to skip tiles that are out
        local cx, cy = (tx + tx1 + 1) * 0.5, (ty + ty1 + 1) * 0.5
        if bound(cx * inv, cy * inv) * k > half then state = -1 end
      end
      if state == 1 then
        local a = alpha
        local ia = 1 - a
        for y = ty, ty1 do
          local row = y * w + 1
          for x = tx, tx1 do
            local i = row + x
            R[i] = cr * a + R[i] * ia; G[i] = cg * a + G[i] * ia; B[i] = cb * a + B[i] * ia; A[i] = a + A[i] * ia
          end
        end
      elseif state == 0 then
        -- an edge runs through: look at its four quarters the same way
        for sy = ty, ty1, 4 do
          local sy1 = min(ty1, sy + 3)
          for sx = tx, tx1, 4 do
            local sx1 = min(tx1, sx + 3)
            local sub = 0
            if exact ~= false then
              local d = sdf((sx + sx1 + 1) * 0.5 * inv, (sy + sy1 + 1) * 0.5 * inv) * k
              if d > 3.9 and d < reach then sub = -1 elseif d < -3.9 and -d < reach then sub = 1 end
            elseif bound and bound((sx + sx1 + 1) * 0.5 * inv, (sy + sy1 + 1) * 0.5 * inv) * k > 3.9 then
              sub = -1
            end
            if sub == 1 then
              local ia = 1 - alpha
              for y = sy, sy1 do
                local row = y * w + 1
                for x = sx, sx1 do
                  local i = row + x
                  R[i] = cr * alpha + R[i] * ia; G[i] = cg * alpha + G[i] * ia; B[i] = cb * alpha + B[i] * ia
                  A[i] = alpha + A[i] * ia
                end
              end
            elseif sub == 0 then
              for y = sy, sy1 do
                local row = y * w + 1
                local fy = (y + 0.5) * inv
                for x = sx, sx1 do
                  local d = sdf((x + 0.5) * inv, fy) * k
                  if d < 0.5 then
                    local a = (d < -0.5 and 1 or (0.5 - d)) * alpha
                    local i = row + x
                    local ia = 1 - a
                    R[i] = cr * a + R[i] * ia; G[i] = cg * a + G[i] * ia; B[i] = cb * a + B[i] * ia; A[i] = a + A[i] * ia
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

-- ── distance primitives (design units) ──────────────────────────────────────

local function d_circle(cx, cy, r)
  return function(x, y) local dx, dy = x - cx, y - cy return sqrt(dx * dx + dy * dy) - r end
end

local function d_ring(cx, cy, r, wd)
  local hw = wd * 0.5
  return function(x, y) local dx, dy = x - cx, y - cy return abs(sqrt(dx * dx + dy * dy) - r) - hw end
end

-- A rounded box: centre, half sizes, corner radius.
local function d_box(cx, cy, hw, hh, rr)
  rr = rr or 0
  return function(x, y)
    local qx, qy = abs(x - cx) - hw + rr, abs(y - cy) - hh + rr
    local ox, oy = max(qx, 0), max(qy, 0)
    return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - rr
  end
end

-- Any simple polygon (convex or not): the exact distance to its edges, signed
-- by the even-odd rule (Inigo Quilez's sdPolygon). `pts` = { x1, y1, x2, y2 … }.
local function d_poly(pts)
  local n = #pts / 2
  local X, Y, EX, EY, IE, YJ = {}, {}, {}, {}, {}, {}
  for i = 1, n do X[i], Y[i] = pts[2 * i - 1], pts[2 * i] end
  for i = 1, n do
    local j = (i == 1) and n or i - 1
    EX[i], EY[i] = X[j] - X[i], Y[j] - Y[i]
    local ee = EX[i] * EX[i] + EY[i] * EY[i]
    IE[i] = ee > 0 and 1 / ee or 0
    YJ[i] = Y[j]
  end
  return function(x, y)
    local d = 1e30
    local s = 1
    for i = 1, n do
      local ex, ey = EX[i], EY[i]
      local wx, wy = x - X[i], y - Y[i]
      local t = (wx * ex + wy * ey) * IE[i]
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      local bx, by = wx - ex * t, wy - ey * t
      local dd = bx * bx + by * by
      if dd < d then d = dd end
      local c1 = y >= Y[i]
      if c1 == (y < YJ[i]) and c1 == (ex * wy > ey * wx) then s = -s end
    end
    return s * sqrt(d)
  end
end

local function poly_box(pts)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #pts, 2 do
    x0, x1 = min(x0, pts[i]), max(x1, pts[i])
    y0, y1 = min(y0, pts[i + 1]), max(y1, pts[i + 1])
  end
  return x0, y0, x1, y1
end

-- An ellipse's outline as a stroke (first-order distance; not exact far away).
local function d_ellipse_stroke(cx, cy, a, b, rot, wd)
  local c, s = cos(rot), sin(rot)
  local hw = wd * 0.5
  return function(x, y)
    local dx, dy = x - cx, y - cy
    local u, v = dx * c + dy * s, -dx * s + dy * c
    local f = (u * u) / (a * a) + (v * v) / (b * b) - 1
    local gx, gy = 2 * u / (a * a), 2 * v / (b * b)
    local g = sqrt(gx * gx + gy * gy)
    if g < 1e-6 then return 1e3 end
    return abs(f / g) - hw
  end, function(x, y)
    -- the gap between the ellipse and its homothetic copy through (x, y) is at
    -- least |rho - 1| times the minor radius: a lower bound on the distance
    local dx, dy = x - cx, y - cy
    local u, v = dx * c + dy * s, -dx * s + dy * c
    local rho = sqrt((u * u) / (a * a) + (v * v) / (b * b))
    return abs(rho - 1) * min(a, b) - hw
  end
end

local function u_min(f, g) return function(x, y) local a, b = f(x, y), g(x, y) return a < b and a or b end end
local function u_max(f, g) return function(x, y) local a, b = f(x, y), g(x, y) return a > b and a or b end end
local function u_sub(f, g) return function(x, y) local a, b = f(x, y), -g(x, y) return a > b and a or b end end
local function u_grow(f, r) return function(x, y) return f(x, y) - r end end
-- A field remembered at every point it is asked about (a motif's clip is the
-- field's outline, asked for again by every layer of the motif).
local function memo(f)
  local m = {}
  return function(x, y)
    local key = floor(x * 64 + 0.5) * 1048576 + floor(y * 64 + 0.5)
    local v = m[key]
    if v == nil then v = f(x, y); m[key] = v end
    return v
  end
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

-- ── the alphabets ───────────────────────────────────────────────────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64V = {}
for i = 1, 64 do B64V[B64:byte(i)] = i - 1 end
local glyph_cache = { stencil = {}, label = {} }

-- A glyph as { w, h, ox, oy, adv, field = { … } } (units of GLYPH_CAP/40).
local function glyph(face, ch)
  local cache = glyph_cache[face] or glyph_cache.label
  local g = cache[ch]
  if g ~= nil then return g or nil end
  local src = GLYPH_DATA and GLYPH_DATA[face] and GLYPH_DATA[face][ch]
  if not src then cache[ch] = false return nil end
  local w, h, ox, oy, adv, data = src[1], src[2], src[3], src[4], src[5], src[6]
  local f = {}
  local range = GLYPH_RANGE
  for i = 1, #data do f[i] = (B64V[data:byte(i)] / 63 - 0.5) * 2 * range end
  -- The baked field stops at ±RANGE. Past it, carry the distance on with a
  -- chamfer (8 neighbours, 1 and √2) so a far tile can be skipped: scaled by
  -- 0.92 (the chamfer's worst overestimate) it stays a lower bound.
  local m, frozen = {}, {}
  local edge = range - 0.07
  for i = 1, #f do
    local a = abs(f[i])
    if a < edge then m[i], frozen[i] = a, true else m[i], frozen[i] = 1e9, false end
  end
  local R2 = 1.41421356
  local function relax(i, j, wgt)
    local v = m[j] + wgt
    if v < m[i] then m[i] = v end
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if not frozen[i] then
        if x > 0 then relax(i, i - 1, 1) end
        if y > 0 then
          relax(i, i - w, 1)
          if x > 0 then relax(i, i - w - 1, R2) end
          if x < w - 1 then relax(i, i - w + 1, R2) end
        end
      end
    end
  end
  for y = h - 1, 0, -1 do
    for x = w - 1, 0, -1 do
      local i = y * w + x + 1
      if not frozen[i] then
        if x < w - 1 then relax(i, i + 1, 1) end
        if y < h - 1 then
          relax(i, i + w, 1)
          if x < w - 1 then relax(i, i + w + 1, R2) end
          if x > 0 then relax(i, i + w - 1, R2) end
        end
      end
    end
  end
  for i = 1, #f do
    if not frozen[i] then
      local d = m[i] < 1e8 and max(range, edge + (m[i] - edge) * 0.92) or range
      f[i] = f[i] < 0 and -d or d
    end
  end
  g = { w = w, h = h, ox = ox, oy = oy, adv = adv, f = f }
  cache[ch] = g
  return g
end

-- The field at a point in the glyph's own grid units (bilinear).
local function glyph_at(g, gx, gy)
  local fx, fy = gx - 0.5, gy - 0.5
  local w, h = g.w, g.h
  if fx < 0 or fy < 0 or fx > w - 1 or fy > h - 1 then
    -- off the grid: outside by at least the distance to it
    local cx = fx < 0 and -fx or (fx > w - 1 and fx - (w - 1) or 0)
    local cy = fy < 0 and -fy or (fy > h - 1 and fy - (h - 1) or 0)
    return GLYPH_RANGE + sqrt(cx * cx + cy * cy)
  end
  local ix, iy = floor(fx), floor(fy)
  local tx, ty = fx - ix, fy - iy
  if ix >= w - 1 then ix, tx = w - 2, 1 end
  if iy >= h - 1 then iy, ty = h - 2, 1 end
  local f = g.f
  local i = iy * w + ix + 1
  local a, b, c, d = f[i], f[i + 1], f[i + w], f[i + w + 1]
  return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
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

-- One glyph placed in design space: its pen's baseline centre at (ox, oy), the
-- advance along (tx, ty), `scale` design units per glyph unit. Returns its
-- distance function and box.
local function placed_glyph(g, ox, oy, tx, ty, scale)
  local dx, dy = -ty, tx         -- "down" in the glyph (towards the baseline side)
  local inv = 1 / scale
  local half_adv = g.adv * 0.5
  local cap = GLYPH_CAP
  local function sdf(x, y)
    local px, py = x - ox, y - oy
    local u = (px * tx + py * ty) * inv + half_adv
    local v = (px * dx + py * dy) * inv + cap
    return glyph_at(g, u - g.ox, v - g.oy) * scale
  end
  -- box: the glyph grid's corners mapped out
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, c in ipairs({ { 0, 0 }, { g.w, 0 }, { 0, g.h }, { g.w, g.h } }) do
    local u, v = c[1] + g.ox - half_adv, c[2] + g.oy - cap
    local X, Y = ox + (u * tx + v * dx) * scale, oy + (u * ty + v * dy) * scale
    x0, x1, y0, y1 = min(x0, X), max(x1, X), min(y0, Y), max(y1, Y)
  end
  return sdf, x0, y0, x1, y1
end

-- Paint a string along a straight baseline centred at (cx, by), cap height
-- `cap` design units. `grow` thickens (an outline pass). Returns the width.
local function paint_text(cv, face, s, cx, by, cap, col, track, grow, alpha)
  local scale = cap / GLYPH_CAP
  local wd = text_width(face, s, track or 0) * scale
  local pen = cx - wd * 0.5
  local data = GLYPH_DATA[face]
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g = glyph(face, ch)
    local adv = (g and g.adv or data.space) * scale
    if g then
      local sdf, x0, y0, x1, y1 = placed_glyph(g, pen + adv * 0.5, by, 1, 0, scale)
      if grow and grow > 0 then sdf = u_grow(sdf, grow) end
      paint(cv, sdf, x0 - (grow or 0), y0 - (grow or 0), x1 + (grow or 0), y1 + (grow or 0), col, alpha, true)
    end
    pen = pen + adv + (track or 0) * scale
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
      local bx, by = cx + ux * r, cy + uy * r
      local sdf, x0, y0, x1, y1 = placed_glyph(g, bx, by, tx, ty, scale)
      paint(cv, sdf, x0, y0, x1, y1, col, alpha, true)
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
-- Each draws into the inner area (centre cx, cy, radius R), clipped by `clip`
-- (a distance function of the field), behind the monogram.

local function motif_orbit(cv, P, cx, cy, R, rnd, clip, under)
  local tilt = -0.42 + (rnd() - 0.5) * 0.25
  local a, b = R * 0.98, R * 0.36
  local wd = max(2.2, R * 0.045)
  local es, eb = d_ellipse_stroke(cx, cy + R * 0.04, a, b, tilt, wd)
  paint(cv, u_max(es, clip), cx - R, cy - R, cx + R, cy + R, P.fg, 1, false, nil, eb)
  -- the satellite on it, upper right
  local t = -0.55
  local sx = cx + cos(t) * a * cos(tilt) - sin(t) * b * sin(tilt)
  local sy = cy + R * 0.04 + cos(t) * a * sin(tilt) + sin(t) * b * cos(tilt)
  paint(cv, d_circle(sx, sy, wd * 2.1), sx - 12, sy - 12, sx + 12, sy + 12, P.accent)
  -- a few stars in the field
  for i = 1, 7 do
    local ang, rr = rnd() * 2 * pi, R * (0.45 + rnd() * 0.5)
    local x, y = cx + cos(ang) * rr, cy + sin(ang) * rr * 0.9
    local s = R * (0.025 + rnd() * 0.025)
    paint(cv, u_max(d_poly(star_pts(x, y, s * 2.2, s * 0.7, 4, 0)), clip), x - 8, y - 8, x + 8, y + 8, P.fg, 0.9)
  end
end

local function motif_rocket(cv, P, cx, cy, R, rnd, clip)
  local ang = 0.30 + (rnd() - 0.5) * 0.12      -- leaning a little to the right
  local L = R * 1.62
  local body = {
    0, -0.50,  0.07, -0.40,  0.10, -0.28,  0.10, 0.22,  0.19, 0.36,  0.19, 0.45,  0.09, 0.40,
    0.06, 0.46,  -0.06, 0.46,  -0.09, 0.40,  -0.19, 0.45,  -0.19, 0.36,  -0.10, 0.22,  -0.10, -0.28,
    -0.07, -0.40,
  }
  for i = 1, #body do body[i] = body[i] * L end
  local ox, oy = cx + R * 0.02, cy - R * 0.08
  local pts = rot_pts(body, ox, oy, ang)
  -- the exhaust trail: a swelling arc from the lower left
  local tr = u_max(u_sub(d_circle(cx + R * 1.55, cy + R * 1.75, R * 2.05), d_circle(cx + R * 1.68, cy + R * 1.62, R * 2.02)), clip)
  paint(cv, tr, cx - R, cy - R, cx + R, cy + R, P.accent, 1, true)
  local x0, y0, x1, y1 = poly_box(pts)
  paint(cv, u_max(d_poly(pts), clip), x0, y0, x1, y1, P.fg)
  -- its window
  local wx, wy = ox + sin(ang) * L * 0.30, oy - cos(ang) * L * 0.30
  paint(cv, d_circle(wx, wy, L * 0.045), wx - 6, wy - 6, wx + 6, wy + 6, P.bg)
  for i = 1, 5 do
    local a2, rr = rnd() * 2 * pi, R * (0.5 + rnd() * 0.45)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    paint(cv, u_max(d_circle(x, y, R * (0.018 + rnd() * 0.018)), clip), x - 5, y - 5, x + 5, y + 5, P.fg, 0.9)
  end
end

local function motif_star(cv, P, cx, cy, R, rnd, clip)
  local n = (rnd() < 0.5) and 4 or 5
  local rot = -pi / 2
  local big = star_pts(cx, cy - R * 0.02, R * 0.98, R * (n == 4 and 0.30 or 0.40), n, rot)
  local x0, y0, x1, y1 = poly_box(big)
  paint(cv, u_max(d_poly(big), clip), x0, y0, x1, y1, P.accent)
  -- a fine rim inside it so it reads as a badge star, not a blob
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.62 + rnd() * 0.3)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    local s = R * (0.03 + rnd() * 0.02)
    paint(cv, u_max(d_poly(star_pts(x, y, s * 2, s * 0.8, 5, -pi / 2)), clip), x - 8, y - 8, x + 8, y + 8, P.fg, 0.9)
  end
end

local function motif_planet(cv, P, cx, cy, R, rnd, clip)
  local px, py, pr = cx + R * 0.30, cy - R * 0.30, R * 0.38
  local tilt = -0.35 + (rnd() - 0.5) * 0.2
  local disc = u_max(d_circle(px, py, pr), clip)
  paint(cv, disc, px - pr, py - pr, px + pr, py + pr, P.accent)
  -- terminator shade: the lower left of the disc a touch darker
  local shade = u_max(u_sub(d_circle(px, py, pr), d_circle(px + pr * 0.35, py - pr * 0.35, pr * 1.05)), clip)
  paint(cv, shade, px - pr, py - pr, px + pr, py + pr, { 0, 0, 0 }, 0.22)
  -- the ring: drawn whole, then the disc's top half again over its back
  local rs, rb = d_ellipse_stroke(px, py, pr * 1.75, pr * 0.42, tilt, max(2.0, R * 0.04))
  paint(cv, u_max(rs, clip), px - pr * 2, py - pr * 2, px + pr * 2, py + pr * 2, P.fg, 1, false, nil, rb)
  local c, s = cos(tilt), sin(tilt)
  local back = u_max(u_max(d_circle(px, py, pr), function(x, y)
    return ((x - px) * s - (y - py) * c)  -- the half-plane above the ring's axis
  end), clip)
  paint(cv, back, px - pr, py - pr, px + pr, py + pr, P.accent)
  paint(cv, u_max(u_max(u_sub(d_circle(px, py, pr), d_circle(px + pr * 0.35, py - pr * 0.35, pr * 1.05)),
    function(x, y) return ((x - px) * s - (y - py) * c) end), clip), px - pr, py - pr, px + pr, py + pr, { 0, 0, 0 }, 0.22)
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.45 + rnd() * 0.5)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    if (x - px) ^ 2 + (y - py) ^ 2 > (pr * 1.9) ^ 2 then
      paint(cv, u_max(d_circle(x, y, R * (0.016 + rnd() * 0.016)), clip), x - 5, y - 5, x + 5, y + 5, P.fg, 0.9)
    end
  end
end

local function motif_swoosh(cv, P, cx, cy, R, rnd, clip)
  -- two crescents crossing under the monogram: the agency's "vector"
  local s1 = u_max(u_sub(d_circle(cx - R * 0.10, cy + R * 1.98, R * 1.55), d_circle(cx - R * 0.0, cy + R * 2.10, R * 1.58)), clip)
  paint(cv, s1, cx - R, cy - R, cx + R, cy + R, P.accent, 1, true)
  local s2 = u_max(u_sub(d_circle(cx + R * 0.15, cy - R * 2.0, R * 1.55), d_circle(cx + R * 0.05, cy - R * 2.12, R * 1.6)), clip)
  paint(cv, s2, cx - R, cy - R, cx + R, cy + R, P.fg, 1, true)
  for i = 1, 6 do
    local a2, rr = rnd() * 2 * pi, R * (0.55 + rnd() * 0.4)
    local x, y = cx + cos(a2) * rr, cy + sin(a2) * rr
    paint(cv, u_max(d_circle(x, y, R * (0.016 + rnd() * 0.016)), clip), x - 5, y - 5, x + 5, y + 5, P.fg, 0.9)
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

-- The emblem itself, drawn into a canvas in its 256-unit design square.
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
    local outer = d_circle(C, C, 124)
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    local field = d_circle(C, C, 118)
    paint(cv, field, 0, 0, 256, 256, P.bg)
    motif(cv, P, C, C, 112, rnd, memo(u_grow(field, -3)))
    paint_monogram(cv, P, face, mono, C, C + 4, 178, #mono <= 2 and 92 or 74, 5)
  elseif shape == "patch" then
    local outer = d_circle(C, C, 125)
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    paint(cv, d_ring(C, C, 120.5, 2.2), 0, 0, 256, 256, P.bg)
    local field = d_circle(C, C, 86)
    paint(cv, d_circle(C, C, 89), 0, 0, 256, 256, P.bg)
    paint(cv, d_ring(C, C, 86.5, 2.0), 0, 0, 256, 256, P.ring)
    motif(cv, P, C, C, 82, rnd, memo(u_grow(field, -3)))
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
        paint(cv, d_poly(star_pts(x, y, 7, 2.8, 5, -pi / 2)), x - 9, y - 9, x + 9, y + 9, P.bg)
      end
    else
      for k = -1, 1 do
        local a = pi / 2 + k * 0.32
        local x, y = C + cos(a) * 107, C + sin(a) * 107
        paint(cv, d_poly(star_pts(x, y, k == 0 and 9 or 6.5, k == 0 and 3.6 or 2.6, 5, -pi / 2)), x - 10, y - 10,
          x + 10, y + 10, P.bg)
      end
    end
  elseif shape == "shield" then
    local pts = shield_pts(C, C + 2, 214, 246)
    local outer = memo(d_poly(pts))
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    local inner = u_grow(outer, -8)
    paint(cv, inner, 0, 0, 256, 256, P.bg)
    -- the chief: a band across the top in the ring colour with the name
    local chief = u_max(inner, function(x, y) return y - 62 end)
    paint(cv, chief, 0, 0, 256, 70, P.ring)
    local field = u_max(inner, function(x, y) return 66 - y end)
    motif(cv, P, C, 146, 86, rnd, memo(u_grow(field, -3)))
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
  elseif shape == "hex" then
    local outer = memo(d_poly(hex_pts(C, C, 127)))
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    local inner = memo(d_poly(hex_pts(C, C, 115)))
    paint(cv, inner, 0, 0, 256, 256, P.bg)
    paint(cv, u_max(d_poly(hex_pts(C, C, 109)), u_sub(function() return -1 end, d_poly(hex_pts(C, C, 106.5)))),
      0, 0, 256, 256, P.ring, 0.9)
    -- a banner across the lower third with the name
    local field = memo(d_poly(hex_pts(C, C, 106)))
    motif(cv, P, C, C - 10, 88, rnd, memo(u_grow(field, -3)))
    paint_monogram(cv, P, face, mono, C, C - 6, 150, #mono <= 2 and 72 or 58, 4)
    -- a ribbon across the lower third, over the border, with the name
    local by = 186
    local rib = d_poly({ 4, by - 17, 252, by - 17, 242, by, 252, by + 17, 4, by + 17, 14, by })
    paint(cv, u_grow(rib, 1.2), 0, by - 22, 256, by + 22, DARK, 0.6)
    paint(cv, rib, 0, by - 20, 256, by + 20, P.ring)
    paint(cv, u_max(rib, function(x, y) return abs(abs(y - by) - 12.5) - 0.8 end), 0, by - 20, 256, by + 20, P.bg, 0.8)
    local short = up
    local cap = fit_cap("label", short, 16, 208, 3)
    if cap < 8.5 then short = mono; cap = fit_cap("label", short, 16, 208, 3) end
    paint_text(cv, "label", short, C, by + cap * 0.5, cap, P.bg, 3)
  elseif shape == "chevron" then
    local pts = chevron_pts(C, C + 4, 128)
    local outer = memo(d_poly(pts))
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    local inner = u_grow(outer, -7)
    paint(cv, inner, 0, 0, 256, 256, P.bg)
    motif(cv, P, C, C + 14, 74, rnd, memo(u_grow(inner, -3)))
    paint_monogram(cv, P, face, mono, C, C + 30, 128, #mono <= 2 and 66 or 54, 4)
  else -- "square": a rounded badge
    local outer = d_box(C, C, 120, 120, 34)
    paint(cv, u_grow(outer, 1.2), 0, 0, 256, 256, DARK, 0.6)
    paint(cv, outer, 0, 0, 256, 256, P.ring)
    local inner = d_box(C, C, 112, 112, 27)
    paint(cv, inner, 0, 0, 256, 256, P.bg)
    -- a diagonal stripe across the lower right corner in the accent
    local stripe = u_max(inner, function(x, y) local t = (x + y - 2 * C) / 1.41421 return abs(t - 96) - 9 end)
    paint(cv, stripe, 0, 0, 256, 256, P.accent, 1, true)
    local field = memo(u_grow(inner, -3))
    motif(cv, P, C, C - 6, 96, rnd, field)
    paint_monogram(cv, P, face, mono, C, C - 2, 176, #mono <= 2 and 88 or 68, 5)
    local short = (#up <= 26) and up or nil
    if short then
      local cap = fit_cap("label", short, 13, 150, 2.5)
      paint(cv, u_max(inner, d_box(C, 212, 112, 14, 0)), 0, 190, 256, 240, P.bg, 0.85)
      paint_text(cv, "label", short, C, 212 + cap * 0.5, cap, P.fg, 2.5)
    end
  end
end

-- ── finishing: wear, and packing to bytes ───────────────────────────────────

local function hash2(x, y, s)
  local h = (x * 374761393 + y * 668265263 + s * 2246822519) % 4294967296
  h = ((h - (h % 8192)) / 8192 + h * 1274126177) % 4294967296
  return (h % 65536) / 65536
end

-- Value noise at a cell size (0..1).
local function vnoise(x, y, cell, s)
  local fx, fy = x / cell, y / cell
  local ix, iy = floor(fx), floor(fy)
  local tx, ty = fx - ix, fy - iy
  tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
  local a, b = hash2(ix, iy, s), hash2(ix + 1, iy, s)
  local c, d = hash2(ix, iy + 1, s), hash2(ix + 1, iy + 1, s)
  return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
end

-- The wear's noise, worked out once: a 128-unit tile of mottling (with the
-- flecks folded in) and a 64-pixel tile of grain, both wrapping.
local WEAR_M, WEAR_G = nil, nil
local function wear_tables()
  if WEAR_M then return end
  WEAR_M, WEAR_G = {}, {}
  -- three wrapping lattices of random values, smoothly interpolated
  local function lattice(n, sd)
    local L = {}
    for j = 0, n - 1 do for i = 0, n - 1 do L[j * n + i] = hash2(i, j, sd) end end
    return L
  end
  local octs = { { 4, lattice(4, 1), 0.6 }, { 16, lattice(16, 2), 0.4 }, { 32, lattice(32, 3), 0 } }
  for y = 0, 127 do
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
      local f = -0.07 * m
      if fl > 0.86 then f = f + (fl - 0.86) * 0.9 end
      WEAR_M[y * 128 + x + 1] = f
    end
  end
  for i = 1, 64 * 64 do WEAR_G[i] = hash2(i % 64, floor(i / 64), 9) - 0.5 end
end

-- Painted metal: a soft mottling, a fine grain, light from above, and the odd
-- worn fleck. `amount` 0..1 scales it all.
local function wear(cv, seed, amount, cheap)
  wear_tables()
  local w, h = cv.w, cv.h
  local R, G, B, A = cv.R, cv.G, cv.B, cv.A
  local k = cv.k
  amount = amount or 1
  local ox, oy = (seed * 37) % 128, (seed * 61) % 128
  local M, Gr = WEAR_M, WEAR_G
  for y = 0, h - 1 do
    if y % 16 == 0 then step() end
    local light = 1.04 - 0.08 * (y / h)
    local my = (floor(y / k) + oy) % 128 * 128 + 1
    local gy = (y + seed) % 64 * 64 + 1
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if A[i] > 0 then
        local f
        if cheap then
          f = light * (1 - amount * 0.04 * Gr[gy + x % 64])
        else
          f = light * (1 + amount * (M[my + (floor(x / k) + ox) % 128] - 0.035 * Gr[gy + x % 64]))
        end
        R[i], G[i], B[i] = R[i] * f, G[i] * f, B[i] * f
      end
    end
  end
end

-- The canvas as w*h*4 bytes (straight alpha), the layout
-- assets.textureFromPixels takes.
local char, unpack = string.char, unpack or table.unpack
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

-- An image buffer { w, h, R, G, B, A } (premultiplied 0..1) copied onto a canvas
-- at (x, y) scaled to dw × dh, bilinear.
local function blit(cv, img, x, y, dw, dh, alpha)
  local k = cv.k
  local px0, py0 = floor(x * k), floor(y * k)
  local pw, ph = floor(dw * k + 0.5), floor(dh * k + 0.5)
  local R, G, B, A = cv.R, cv.G, cv.B, cv.A
  local iw, ih = img.w, img.h
  local IR, IG, IB, IA = img.R, img.G, img.B, img.A
  alpha = alpha or 1
  for py = 0, ph - 1 do
    local Y = py0 + py
    if Y >= 0 and Y < cv.h then
      local sy = (py + 0.5) / ph * ih - 0.5
      local y0 = floor(sy)
      local ty = sy - y0
      if y0 < 0 then y0, ty = 0, 0 elseif y0 >= ih - 1 then y0, ty = ih - 2, 1 end
      for px = 0, pw - 1 do
        local X = px0 + px
        if X >= 0 and X < cv.w then
          local sx = (px + 0.5) / pw * iw - 0.5
          local x0 = floor(sx)
          local tx = sx - x0
          if x0 < 0 then x0, tx = 0, 0 elseif x0 >= iw - 1 then x0, tx = iw - 2, 1 end
          local i00 = y0 * iw + x0 + 1
          local i10, i01, i11 = i00 + 1, i00 + iw, i00 + iw + 1
          local w00, w10, w01, w11 = (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty
          -- a premultiplied image samples straight into a premultiplied canvas
          local a = IA[i00] * w00 + IA[i10] * w10 + IA[i01] * w01 + IA[i11] * w11
          if a > 0 then
            local r = IR[i00] * w00 + IR[i10] * w10 + IR[i01] * w01 + IR[i11] * w11
            local g = IG[i00] * w00 + IG[i10] * w10 + IG[i01] * w01 + IG[i11] * w11
            local b = IB[i00] * w00 + IB[i10] * w10 + IB[i01] * w01 + IB[i11] * w11
            a = a * alpha
            r, g, b = r * alpha, g * alpha, b * alpha
            local i = Y * cv.w + X + 1
            local ia = 1 - a
            R[i] = r + R[i] * ia; G[i] = g + G[i] * ia; B[i] = b + B[i] * ia; A[i] = a + A[i] * ia
          end
        end
      end
    end
  end
end

-- The emblem: pixels (size² × 4 bytes) and its image buffer (for the flag).
-- `image` = an image buffer to use instead of a generated emblem (a custom
-- picture, already square).
function rasterEmblem(spec, name, size, image)
  size = size or EMBLEM_SIZE
  spec = spec or specFor(name)
  local T = PROF and os.clock
  local t0 = T and T()
  local cv = canvas(size, size, size / 256)
  if image then
    blit(cv, image, 0, 0, 256, 256)
  else
    draw_emblem(cv, spec, name)
    if T then PROF.draw = (PROF.draw or 0) + T() - t0; t0 = T() end
    if size >= 64 then wear(cv, (spec.seed or 1) % 9973, size >= 128 and 1 or 0.6) end
  end
  if T then PROF.wear = (PROF.wear or 0) + T() - t0; t0 = T() end
  local px = pack(cv)
  if T then PROF.pack = (PROF.pack or 0) + T() - t0; t0 = T() end
  if T then PROF.buf = 0 end
  return px
end

-- The flag cloth: the field, the emblem, and the name, FLAG_W × FLAG_H.
-- `epx` is the emblem's pixels (rasterEmblem's first result, 256² × 4,
-- straight alpha), set on the field at 1:1 so nothing is resampled. Built
-- row by row as strings: a row that is only field and hoist is one shared
-- string, so the cost is the emblem's square and the name's strip.
local byte, rep_s = string.byte, string.rep
function rasterFlag(spec, name, epx)
  local P = (spec and spec.pal) or specFor(name).pal
  local W, H = FLAG_W, FLAG_H
  local function b3(c) return floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5) end
  local fr, fg, fb = b3(P.bg)
  local rr, rg, rb = b3(P.ring)
  local ar, ag, ab = b3(P.accent)
  -- the hoist: the sleeve in the band colour, a fine accent stripe beside it
  local HOIST, STRIPE = 18, 4
  local field_px = char(fr, fg, fb, 255)
  local base = rep_s(char(rr, rg, rb, 255), HOIST) .. rep_s(char(ar, ag, ab, 255), STRIPE) .. rep_s(field_px, W - HOIST - STRIPE)
  -- the base row as numbers, for compositing
  local BR, BG, BB = {}, {}, {}
  for x = 0, W - 1 do
    if x < HOIST then BR[x], BG[x], BB[x] = rr, rg, rb
    elseif x < HOIST + STRIPE then BR[x], BG[x], BB[x] = ar, ag, ab
    else BR[x], BG[x], BB[x] = fr, fg, fb end
  end
  local ES = EMBLEM_SIZE
  local EX, EY = floor(W / 2 + 10 - ES / 2), 16
  -- the name, painted into a strip of its own
  local up = upperName(name)
  local TY0, TH = EY + ES + 6, H - (EY + ES + 6)
  local cap = fit_cap("label", up, 34, W - 90, 5)
  local strip = canvas(W, TH, 1)
  paint_text(strip, "label", up, W / 2 + 10, TH * 0.5 + cap * 0.5, cap, P.fg, 5)
  local rows = {}
  local out = {}
  for y = 0, H - 1 do
    if y % 8 == 0 then step() end
    if epx and y >= EY and y < EY + ES then
      local ey = y - EY
      local o = ey * ES * 4 + 1
      local e = { byte(epx, o, o + ES * 4 - 1) }
      local n = 0
      for x = 0, ES - 1 do
        local k = x * 4
        local a = e[k + 4]
        local X = EX + x
        if a == 255 then
          out[n + 1], out[n + 2], out[n + 3] = e[k + 1], e[k + 2], e[k + 3]
        elseif a == 0 then
          out[n + 1], out[n + 2], out[n + 3] = BR[X], BG[X], BB[X]
        else
          local t = a / 255
          local it = 1 - t
          out[n + 1] = floor(e[k + 1] * t + BR[X] * it + 0.5)
          out[n + 2] = floor(e[k + 2] * t + BG[X] * it + 0.5)
          out[n + 3] = floor(e[k + 3] * t + BB[X] * it + 0.5)
        end
        out[n + 4] = 255
        n = n + 4
      end
      rows[y + 1] = base:sub(1, EX * 4) .. char(unpack(out, 1, n)) .. base:sub((EX + ES) * 4 + 1)
    elseif y >= TY0 and y < TY0 + TH then
      local sy = y - TY0
      local SR, SG, SB, SA = strip.R, strip.G, strip.B, strip.A
      local any = false
      local row0 = sy * W
      for x = 0, W - 1 do if SA[row0 + x + 1] > 0.002 then any = true break end end
      if any then
        local parts, n = {}, 0
        for x = 0, W - 1 do
          local i = row0 + x + 1
          local a = SA[i]
          -- the strip is premultiplied: colour + base × (1 − a)
          local ia = 1 - a
          out[n + 1] = floor(SR[i] * 255 + BR[x] * ia + 0.5)
          out[n + 2] = floor(SG[i] * 255 + BG[x] * ia + 0.5)
          out[n + 3] = floor(SB[i] * 255 + BB[x] * ia + 0.5)
          out[n + 4] = 255
          n = n + 4
          if n >= 4096 then parts[#parts + 1] = char(unpack(out, 1, n)); n = 0 end
        end
        if n > 0 then parts[#parts + 1] = char(unpack(out, 1, n)) end
        rows[y + 1] = table.concat(parts)
      else
        rows[y + 1] = base
      end
    else
      rows[y + 1] = base
    end
  end
  return table.concat(rows)
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
  local parts = { "v3", nm, tostring(sp.seed), sp.shape, sp.motif, tostring(sp.font), tostring(sp.mono) }
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
  local epx = rasterEmblem(sp, nm, EMBLEM_SIZE, custom)
  local fpx = rasterFlag(sp, nm, epx)
  return { epx = epx, fpx = fpx, custom = custom ~= nil }
end

local function textures(rec)
  if can_draw() then
    rec.tex = assets.textureFromPixels(EMBLEM_SIZE, EMBLEM_SIZE, rec.epx)
    rec.flagTex = assets.textureFromPixels(FLAG_W, FLAG_H, rec.fpx)
  end
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
    return rasterEmblem(s2, n, 96, custom)
  end, function(px)
    local old = hit and hit.tex
    small[key] = { sig = sig, tex = assets.textureFromPixels(96, 96, px) }
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
GLYPH_CAP, GLYPH_RANGE = 40, 4.0
GLYPH_DATA = {
  stencil = { space = 15.08,
    A = { 49, 50, -5.00, -5.00, 39.85, "/////////////////////////////////////////////////////////////////+8889888888888888+//////////////////////////////73001200000000000038////////////////////////////82wsstvssssssssssstx39///////////////////////////5xrlknpkkkkkkkkkkkmsz6//////////////////////////+2vngdjnfddddddddddipw4//////////////////////////70slfbioibWWWWWWWWZgmu19/////////////////////////5yqjdZgmjdWOOOOOOPXdkrz6////////////////////////+3vogbXdklfYRJGGGGNUcipx4////////////////////////80tlfYVcingaTLEAADLSagnu29///////////////////////6yqjdWTagnicVNGAABIQXfksz6///////////////////////3woibTQYflkfXPIAAAGNVcipx4//////////////////////81tmfZROWdjmfZSKCAADLSagnu29/////////////////////6yrjdWPMTbgoibUMFAABJQYfksz7/////////////////////4woibUMKRZgmjdWOHAAAGOVciqx4////////////////////91umfZSKHPXdklfYRJCAAELTagnv2+///////////////////6zrkdXPIFNUcingbTLEAABJQYfls07///////////////////4wpicUNFDLSagnicVNGAAAHOVdjqx5//////////////////92unfZSKDBJQYflkfXQIAAAEMTbgnv2+/////////////////6zskfXQIAAHOVdjnfZSKDAACJRYflt08/////////////////4xpicVNGAAEMTbgoibUMFAAAHOWdjqy5////////////////92unfaSLDAAEMTbgojdWOHAAAFMTbgov3+///////////////7zskfXQIBAAGOVdjqlfYRJCAACJRYflt08///////////////4xqicVOGAABIQYfksngbTLEAAAHOWdjry6//////////////92ungaTLEAADLSagnuqicVNGAAAFMUbiow3//////////////70skfYQJBAAFMUcipxskfXQIAAACKRZgmt18/////////////5xqjdVOGAAAHPWdjrzunfZSKDAAAHPWdjrz6////////////+2vngbTMEAACJRYglrrrpibUMFAAAFMUcipw4////////////70slfYRJCAAELTbgojjjjjdWOGAAADKSZgmu19///////////5yqjdVOHAAAGNVcimfccccbVNFAAAAIPXdkrz6//////////+3vogbTMEAAAIQXfkkdXUUUUQKDAAAAFNUcipx4//////////80tlfYRJCAACKSZgnicVNMMMJFAAAAADLSagnu29/////////6yqjdWOHAAAFMUbingaTLFFECAAAAAABIQXfksz6/////////3woibTMFAAAHOWdjlfYRJBAAAAAAAAAAGNVcipx4////////81tmfZRKCAABJQYfljdWOHFFFFFEBAAAADLSagnu29///////6yrjdWPHAAADLTagnibUMMMMMMMMIDAAABJQYfksz7///////4woibUMFAAAFNVcinfaUUUUUUUUTOIBAAAGOVciqx4//////91umfZSKCAAAHPXdkkfcccccccccZTMEAAAELTagnv2+/////6zrkdXPIAAACKRZgmnjjjjjjjjjjdVOGAAABJQYfls07/////4wpicUNFAAAEMTbgotrrrrrrrrrkfYQIBAAAHOVdjqx5////91umfZSKDAAAGOVdjqyzzzzzzzzungaSLDAAAEMTbgnv2+///6zskfXPIFFFFIQYfks066666664xpicUNFFFFFJRYflt08///4xpicVNMMMMMMSagnu29//////6zrkdXPMMMMMMOWdjqy5//92unfaUUUUUUUUUcipx4///////91tmfZUUUUUUUUUbgov3+/80skfccccccccccdjrz6////////3wogcccccccccccflt19/80tmjjjjjjjjjjjjnt18////////5yqkjjjjjjjjjjjjnu29/+3xsrrrrrrrrrrrrty4/////////81vrrrrrrrrrrrrrty4///83zzzzzzzzzzzzz049//////////62zzzzzzzzzzzzz049////+76666666666667+////////////976666666666667+///////////////////////////////////////////////////" },
    B = { 48, 50, -5.00, -5.00, 38.86, "///////////////////////////////////////////////////////+88888888888889888888888889////////////////////7300000000000002000000000001357+///////////////92wsssssssssssssvsssssssssssuvx037//////////////6yrlkkkkkkkkkkkkqlkkkkkkkkklmoqtw049////////////5xpidddddddddddgoidddddddddffgjmpuy49///////////5xpibWWWWWWWWWagoibWWWWWWWWXYbdfjnty4+//////////5xpibTOOOOOOOSagoibTOOOOOOOPRTWZdintz5//////////5xpibTLGGGGGKSagoibTLGGGGGHIJMPTXdiou29/////////5xpibTLDAAACKSagoibTLDAAAAAACFIMSYfkry5/////////5xpibTLDAAACKSagoibTLFFDBAAAAABHNUbgov3+////////5xpibTLDAAACKSagoibTMMMLIEAAAAACJRYflt08////////5xpibTLDAAACKSagoibUUUUTPKFAAAAAHOWdksz7////////5xpibTLDAAACKSagoicccccaVQJCAAAAFNVcjrz6////////5xpibTLDAAACKSagokjjjjigbTMFAAAAFMUcjrz6////////5xpibTLDAAACKSagorrrrrpjdWOGAAAAFMUcjrz6////////5xpibTLDAAACKSagowzzzzskdWOGAAAAFMUcjrz6////////5xpibTLDAAACKSagow1110skdWOGAAAAGOWdjrz6////////5xpibTLDAAACKSagouttttskdWOGAAABIPXfks08////////5xpibTLDAAACKSagomllllkicVNFAAAFLSZgmu19////////5xpibTLDAAACKSagoifffffcXRKDBDGKQWdipw4/////////5xpibTLDAAACKSagoibXXXXVRMGFIKNRVbgmtz6/////////5xpibTLDAAACKSagoibTPPPOLGFLPSVYcgkrw3+/////////5xpibTLDAAACKSagoibTLHHGECJQWacfglqv27//////////5xpibTLDAAACKSagoibTLDAAADLTbgiknsw16///////////5xpibTLDAAACKSagoibTLDCBADKSYbdfimqv16//////////5xpibTLDAAACKSagoibTLKKIHDHNSUWZcgkqv29/////////5xpibTLDAAACKSagoibTSSSQOKFHKMPSWafkry5/////////5xpibTLDAAACKSagoibaaaaYVQKDDFHLPVbgnu29////////5xpibTLDAAACKSagoigggggfbVOGAAAEKRYfksz7////////5xpibTLDAAACKSagopoooonkfYQIAAAAGOVcjqy5////////5xpibTLDAAACKSagowwwwwunfYQJBAAAEMTbipw4////////5xpibTLDAAACKSagow4443vngaSKCAAADKSagow4////////5xpibTLDAAACKSagow000zvnfZRKCAAACKSagov3////////5xpibTLDAAACKSagosssssrmfYQJBAAACKRZgnv2+///////5xpibTLDAAACKSagolkkkkjidWPHAAAACKSagow3////////5xpibTLDAAACKSagoiddddccXSMFAAAADLTagow4////////5xpibTLDAAACKSagoibWWWVURMGBAAAAFMUcipx4////////5xpibTLDAAACKSagoibTOONMKGBAAAABIPWdjrz6////////5xpibTLDAAACKSagoibTLGFFDAAAAAAFLSZgmt18////////5xpibTLDAAACKSagoibTLDAAAAAABDGLQWdipw3/////////5xpibTLFFFFFKSagoibTLFFFFFGHIKNRVbgmt07/////////5xpibTMMMMMMMSagoibTMMMMMMOOQSVYcglrx3+/////////5xpibUUUUUUUUUagoibUUUUUUUWWYacfilrw28//////////5xpicccccccccccgoiccccccccddfgiknsw27///////////6yqkjjjjjjjjjjjjpkjjjjjjjjjklnpsuy37////////////81vrrrrrrrrrrrrrurrrrrrrrrrstuwz259//////////////62zzzzzzzzzzzzz1zzzzzzzzzz002469/////////////////976666666666668766666666688+/////////////////////////////////////////////////////////////" },
    C = { 43, 51, -5.00, -5.50, 32.94, "/////////////////////////////////////////////////////////////+++8888888899+/////////////////////////97542230000000011244679//////////////////742zxwvvxtssssssstuvwxy026///////////////940xusqonnrmkkkkkkklmnoprsv17/////////////72ytqnkigfgnjddddddffffgijkqw4////////////72wrnjgfcbagnjcWWWWWXXYZabdgnv2+//////////82wrlgdaXVTYgnjcUOOOOPPQSTUYgnv2+/////////+3xrlfbXTQNQYgnjcUMGGGHIJKLQYgnv2+/////////6ztmfbVQMJJQYgnjcUMFAAAABCJQYgnv2+////////+3wpidWQKFBJQYgnjcUMFFFFFEDJQYgnv2+////////80tmfZSLFABJQYgnjcUMMMMMMMLLQYgnv2+////////5yqjdWPHBABJQYgnjcUTUUUUUUTTSYgnv2+////////3wogbTMFAABJQYgnjcbbcccccbbaaYgnv2+///////92unfZRKCAABJQYgnjggijjjjjiiggggnv2+///////80tlfXQIAAABJQYgnnmopqrrrrpponnnrx4////////70skdWOHAAABJQYgnuuwxyzzzyxxwvvvx28////////6zrjdVOGAAABJQYgnv1456666654432248/////////6yrjcUMFAAABJQYgnv2+/////////+++///////////5xpibUMEAAABJQYgnv2+///////////////////////5xpibTLDAAABJQYgnv2+///////////////////////5xpibTLDAAABJQYgnv2+///////////////////////4xpibTLDAAABJQYgnv2+///////////////////////4wogaTLDAAABJQYgnv2+///////////////////////4wogaSKCAAABJQYgnv2+///////////////////////4wogaSKCAAABJQYgnv2+///////////////////////4wogaSKCAAABJQYgnv2+///////////////////////4wogaTLDAAABJQYgnv2+///////////////////////4xpibTLDAAABJQYflt19///////////////////////5xpibTLDAAAAHPXflt19///////////////////////5xpibTLDAAAAHPXflt19///////////////////////5xpicUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXfks08///////////+///////////6zrjdVOGAAAAGOWdjrz456677666544247/////////70skdWOHAAAAFMUciouxyzzzzzzzxxwvw17////////80tlfXQIAAAADKRYfjnpqrrsrrrrpponqw3+///////92unfZRKCAAAAHNTZdgijjjkkjjjiigflt19////////3wogbTMFAAAACIOTXabcccddccccbaflt19////////5yqjdWOHAAAAADIMQSTUUVWWUUUUTXflt19////////80tlfZSLFAAAAACFJLMMMNOONMMMPXflt19////////+3wpidWQJFBAAAAABDEFFFGGFFFHPXflt19/////////6ztmgbUQLIFDBAAAAAAAAAAAABHPXflt19/////////+3wqkfbWSPMLJIHGGFFFFGGHHIJPXflt19//////////71vqkgdZWUSQPPOOMMMMOOPPQRSXflt19///////////61vrmigdcaYXWWWUUUUWWWXYYabflt19////////////62xtpmjiggfdddccccdddffggijnu29/////////////830wtrpnmlkkjjjjjjkkllnopqty4///////////////+731zxvutssrrrrrrssttvvxy049//////////////////86431100zzzzzz001123467+//////////////////////+98886666668889+/////////////////////////////////////////////////////" },
    D = { 49, 50, -5.00, -5.00, 39.44, "////////////////////////////////////////////////////////+88888888888889888888899+///////////////////////730000000000000200000001124579//////////////////92wsssssssssssssvsssssssttvwxz146+///////////////6yrlkkkkkkkkkkkkqlkkkkkklmnoqsuwz37//////////////5xpidddddddddddgoidddddfffggikmpsw16/////////////5xpibWWWWWWWWWagoibWWWWXXYabcdfimqu06////////////5xpibTOOOOOOOSagoibTOOOPPQSTVXZcfjpu17///////////5xpibTLGGGGGKSagoibTLGGHHJKLNPSWafjqw3+//////////5xpibTLDAAACKSagoibTLDAAABCEFILPTaglsz6//////////5xpibTLDAAACKSagoibTLFDCAAAAABEJPVcipw3//////////5xpibTLDAAACKSagoibTMMLJHCAAAAAELSZgmt18/////////5xpibTLDAAACKSagoibUUUTRNIDAAAAAHPWdkrz6/////////5xpibTLDAAACKSagoiccccbYTOIBAAAAFNUcipx5/////////5xpibTLDAAACKSagokjjjigfZTMFAAAADLTbgow4/////////5xpibTLDAAACKSagorrrrpojdWPHAAAACKSagnv3/////////5xpibTLDAAACKSagowzzzxtmfYRJCAAABJRYgnv2+////////5xpibTLDAAACKSagow4663vogaSKCAAABJQYgnu29////////5xpibTLDAAACKSagow4//4wogbTLDAAAAIQXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//5xpibTLDAAAAHPXflt19////////5xpibTLDAAACKSagow4//4woibTLDAAAAIPXflt19////////5xpibTLDAAACKSagow4763wogaSKCAAABJQYgmu19////////5xpibTLDAAACKSagow00zyumfZRKCAAABJQYgnv2+////////5xpibTLDAAACKSagosssrqojdXPIAAAACKSagnv3+////////5xpibTLDAAACKSagolkkjjifZTMFAAAADLTbgow4/////////5xpibTLDAAACKSagoidddcbYTOICAAAAFMUcipx5/////////5xpibTLDAAACKSagoibWVUTRNIDAAAAAHOWdjrz6/////////5xpibTLDAAACKSagoibTOMMKHCAAAAAEKRZglt08/////////5xpibTLDAAACKSagoibTLFECAAAAAAEIPVciow3+/////////5xpibTLDAAACKSagoibTLDAAAABDFHKPTZglsz6//////////5xpibTLFFFFFKSagoibTLFGGHIJLMORVZfjpw29//////////5xpibTMMMMMMMSagoibTMNOOPPRSUWZcgjpu07///////////5xpibUUUUUUUUUagoibUUUWWXXYabdgilpu06////////////5xpicccccccccccgoiccccdddfggijlosw06/////////////6yqkjjjjjjjjjjjjpkjjjjkkklmnprtwz27//////////////81vrrrrrrrrrrrrrurrrrrrsstuvxy0369////////////////62zzzzzzzzzzzzz1zzzzzz00113468+///////////////////9766666666666687666678899//////////////////////////////////////////////////////////////////" },
    E = { 45, 50, -5.00, -5.00, 35.73, "////////////////////////////////////////////////////+8888888888888988888888888888889////////////7300000000000002000000000000000026//////////92wsssssssssssssvssssssssssssssssv06/////////6yrlkkkkkkkkkkkkqlkkkkkkkkkkkkkkkpw3/////////5xpidddddddddddgoiddddddddddddddgnv2+////////5xpibWWWWWWWWWagoibWWWWWWWWWWWWYgnv2+////////5xpibTOOOOOOOSagoibTOOOOOOOOOOQYgnv2+////////5xpibTLGGGGGKSagoibTLGGGGGGGGJQYgnv2+////////5xpibTLDAAACKSagoibTLDAAAAAABJQYgnv2+////////5xpibTLDAAACKSagoibTLFFFFFFFFJQYgnv2+////////5xpibTLDAAACKSagoibTMMMMMMMMMMQYgnv2+////////5xpibTLDAAACKSagoibUUUUUUUUUUUUYgnv2+////////5xpibTLDAAACKSagoiccccccccccccccgnv2+////////5xpibTLDAAACKSagokjjjjjjjjjjjjjjjov3/////////5xpibTLDAAACKSagorrrrrrrrrrrrrrrruz6/////////5xpibTLDAAACKSagowzzzzzzzzzzzzzzz05+/////////5xpibTLDAAACKSagow1111111111112668///////////5xpibTLDAAACKSagouttttttttttttv06////////////5xpibTLDAAACKSagomllllllllllllpv29///////////5xpibTLDAAACKSagoiffffffffffffks08///////////5xpibTLDAAACKSagoibXXXXXXXXXXdks08///////////5xpibTLDAAACKSagoibTPPPPPPPPWdks08///////////5xpibTLDAAACKSagoibTLHHHHHHOWdks08///////////5xpibTLDAAACKSagoibTLDAAAAGOWdks08///////////5xpibTLDAAACKSagoibTLDCCCCGOWdks08///////////5xpibTLDAAACKSagoibTLKKKKKKOWdks08///////////5xpibTLDAAACKSagoibTSSSSSSSSWdks08///////////5xpibTLDAAACKSagoibaaaaaaaaaadks08///////////5xpibTLDAAACKSagoiggggggggggggks08///////////5xpibTLDAAACKSagopooooooooooooqv29///////////5xpibTLDAAACKSagowwwwwwwwwwwwwx16////////////5xpibTLDAAACKSagow4444444444444789///////////5xpibTLDAAACKSagow00000000000000026//////////5xpibTLDAAACKSagossssssssssssssssv06/////////5xpibTLDAAACKSagolkkkkkkkkkkkkkkkpw3/////////5xpibTLDAAACKSagoiddddddddddddddgnv2+////////5xpibTLDAAACKSagoibWWWWWWWWWWWWYgnv2+////////5xpibTLDAAACKSagoibTOOOOOOOOOOQYgnv2+////////5xpibTLDAAACKSagoibTLGGGGGGGGJQYgnv2+////////5xpibTLDAAACKSagoibTLDAAAAAABJQYgnv2+////////5xpibTLFFFFFKSagoibTLFFFFFFFFJQYgnv2+////////5xpibTMMMMMMMSagoibTMMMMMMMMMMQYgnv2+////////5xpibUUUUUUUUUagoibUUUUUUUUUUUUYgnv2+////////5xpicccccccccccgoiccccccccccccccgnv2+////////6yqkjjjjjjjjjjjjpkjjjjjjjjjjjjjjjov3/////////81vrrrrrrrrrrrrrurrrrrrrrrrrrrrrruz6//////////62zzzzzzzzzzzzz1zzzzzzzzzzzzzzzz05+///////////97666666666666876666666666666668///////////////////////////////////////////////////" },
    F = { 43, 50, -5.00, -5.00, 33.41, "//////////////////////////////////////////////////+888888888888898888888888888889///////////730000000000000200000000000000026/////////92wsssssssssssssvsssssssssssssssv17////////6yrlkkkkkkkkkkkkqlkkkkkkkkkkkkkkqx4////////5xpidddddddddddgoidddddddddddddgow4////////5xpibWWWWWWWWWagoibWWWWWWWWWWWagow4////////5xpibTOOOOOOOSagoibTOOOOOOOOOSagow4////////5xpibTLGGGGGKSagoibTLGGGGGGGKSagow4////////5xpibTLDAAACKSagoibTLDAAAAACKSagow4////////5xpibTLDAAACKSagoibTLFFFFFFFKSagow4////////5xpibTLDAAACKSagoibTMMMMMMMMMSagow4////////5xpibTLDAAACKSagoibUUUUUUUUUUUagow4////////5xpibTLDAAACKSagoicccccccccccccgow4////////5xpibTLDAAACKSagokjjjjjjjjjjjjjjpx4////////5xpibTLDAAACKSagorrrrrrrrrrrrrrru07////////5xpibTLDAAACKSagowzzzzzzzzzzzzzz16/////////5xpibTLDAAACKSagow466666666666668//////////5xpibTLDAAACKSagow22222222222359///////////5xpibTLDAAACKSagovvvvvvvvvvvvvy4+//////////5xpibTLDAAACKSagonnnnnnnnnnnnntz6//////////5xpibTLDAAACKSagoifffffffffffipx5//////////5xpibTLDAAACKSagoibYYYYYYYYYbipx5//////////5xpibTLDAAACKSagoibTQQQQQQQTbipx5//////////5xpibTLDAAACKSagoibTLJJJJJLTbipx5//////////5xpibTLDAAACKSagoibTLDBBBDLTbipx5//////////5xpibTLDAAACKSagoibTLDBBBDLTbipx5//////////5xpibTLDAAACKSagoibTLJJJJJLTbipx5//////////5xpibTLDAAACKSagoibTQQQQQQQTbipx5//////////5xpibTLDAAACKSagoibYYYYYYYYYbipx5//////////5xpibTLDAAACKSagoigggggggggggipx5//////////5xpibTLDAAACKSagonnnnnnnnnnnnntz6//////////5xpibTLDAAACKSagovvvvvvvvvvvvvy4+//////////5xpibTLDAAACKSagow22222222222359///////////5xpibTLDAAACKSagow4++++++++++//////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLDAAACKSagow4////////////////////////5xpibTLFFFFFKSagow4////////////////////////5xpibTMMMMMMMSagow4////////////////////////5xpibUUUUUUUUUagow4////////////////////////5xpicccccccccccgow4////////////////////////6yqkjjjjjjjjjjjjpx4////////////////////////81vrrrrrrrrrrrrru07/////////////////////////62zzzzzzzzzzzzz16///////////////////////////976666666666668////////////////////////////////////////////////////////////////" },
    G = { 48, 51, -5.00, -5.50, 38.28, "///////////////////////////////////////////////////////////////////++888888888899+////////////////////////////+8643230000000000112445689////////////////////9520ywvvxtssssssssttuvwxyz0147////////////////+52yvsrpnnrmkkkkkkkkllmnopqrsuw17//////////////83zurnljiggnjddddddddffffgijjkmqw3+////////////83xtokgfdbagnjcWWWWWWWXXYZabcdfflt19///////////93xsmifbYWUYgnjcUOOOOOOPPQSTTUWXflt19///////////5ysmgdYUROQYgnjcUMGGGGHHIJKLMMPXflt19//////////81unicWSNJJQYgnjcUMFAAAAAABCDEHPXflt19//////////4xqjdYRLHCJQYgnjcUMFFFFFFFEDDCHPXflt19/////////92ungbTNGABJQYgnjcUMMMMMMMMMLLKJPXflt19/////////6zrkfXQJCABJQYgnjcUTUUUUUUUTTSSRQXflt19/////////4xpicUNGAABJQYgnjcabcccccccbbaaYYXflt19////////+3vngaSLDAABJQYgnjfgiijjjjjjiigggffflt19////////91tlfYQJBAABJQYgnmknpprrrrrqppoonllkou2+////////80skfXPHAAABJQYgntsvxxzzzzzyxxwvvttsuz5/////////7zrkdWOGAAABJQYgnv02456666665443210015+/////////6zrjcUNFAAABJQYgnv27555555555555555569//////////5xqicUMFAAABJQYgnv20xxxxxxxxxxxxxxxxy27/////////5xpibTLEAAABJQYgnvztqppppppppppppppprw3+////////5xpibTLDAAABJQYgnvwpiiiiiiiiiiiiiiiils08////////5xpibTLDAAABJQYgnvwogbbbbbbbbbbbbbbdks08////////4wogbTLDAAABJQYgnvwogaTTTTTTTTTTTTWdks08////////4wogaSKCAAABJQYgnvwogaSLLLLLLLLLLOWdks08////////4wogaSKCAAABJQYgnvwogaSKDDDDDDDDGOWdks08////////4wogaSKCAAABJQYgnvwogaSKDDAAAAAAGOWdks08////////4wogbTLDAAABJQYgnuwogaSLLKHCAAAAGOWdks08////////5xpibTLDAAAAIQXfltwogaTTTSNHAAAAGOWdks08////////5xpibTLDAAAAHPXfltwogbbbbYSKDAAAGOWdks08////////5xpibTLEAAAAHPXfltwpiiiiibTLDAAAGOWdks08////////5xqicUMFAAAAHPXfksztqpppibTLDAAAGOWdks08////////6zrjcUNFAAAAGOWdkrz0xxxpibTLDAAAGOWdks08////////7zrkdWOGAAAAFNUciqx455xpibTLDAAAGOWdks08////////80skfXPHAAAAELTagnuy01xpibTLDAAAGOWdks08////////91tlfYQJBAAABJQXdjorsttpibTLDAAAGOWdks08////////+3vngaSLDAAAAFMTZfijklmpibTLDAAAGOWdks08/////////4xpicUNFAAAABIOTYbddfgoibTLDAAAGOWdks08/////////6zrkdXQJCAAAADINRUWXagoibTLDAAAGOWdks08/////////91ungaTMGAAAAACHKMOSagoibTLDAAAGOWdks08//////////4xqjdXRLGBAAAAACFKSagoibTLDAAAGOWdks08//////////70ungcWRMIGDCAAACKSagoibTLDCCDGOWdks08///////////4ysmgcXTQNLKIHGGKSagoibTLJJKLMOWdks08///////////93xrmgdaXVTRQPOOOSagoibTPQRSTUVXdks08////////////82wsnjgfcbZYXWWVUagoibXXYYabccdgks08/////////////73yuqnkiggffdddccgoiddfggggijklpv29//////////////940xusponlkkkjjjjplkklmnooprstw06/////////////////742zxwutsssrrrrusssttvvwxzz136////////////////////965321000zzzz1000112345679+/////////////////////////+98876666888899+//////////////////////////////////////////////////////////////" },
    H = { 51, 50, -5.00, -5.00, 41.53, "//////////////////////////////////////////////////////////+88888888888889////////88888888888888/////////////73000000000000026/////941000000000000149//////////92wsssssssssssssv17////4ytssssssssssssty4//////////6yrlkkkkkkkkkkkkqx4///81tnkkkkkkkkkkkknt18/////////5xpidddddddddddgow4///80skddddddddddddks08/////////5xpibWWWWWWWWWagow4///80skdWWWWWWWWWWdks08/////////5xpibTOOOOOOOSagow4///80skdWOOOOOOOOWdks08/////////5xpibTLGGGGGKSagow4///80skdWOGGGGGGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow499980skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow111110skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagouttttttskdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagomlllllllkdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagoiffffffffdVOGAAAAGOWdks08/////////5xpibTLDAAACKSagoibXXXXXXXWSLEAAAAGOWdks08/////////5xpibTLDAAACKSagoibTPPPPPPPMGAAAAAGOWdks08/////////5xpibTLDAAACKSagoibTLHHHHHHFBAAAAAGOWdks08/////////5xpibTLDAAACKSagoibTLDAAAAAAAAAAAAGOWdks08/////////5xpibTLDAAACKSagoibTLDAAAAAAAAAAAAGOWdks08/////////5xpibTLDAAACKSagoibTLHHHHHHFBAAAAAGOWdks08/////////5xpibTLDAAACKSagoibTPPPPPPPMGAAAAAGOWdks08/////////5xpibTLDAAACKSagoibXXXXXXXWSLEAAAAGOWdks08/////////5xpibTLDAAACKSagoiffffffffdVOGAAAAGOWdks08/////////5xpibTLDAAACKSagomlllllllkdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagouttttttskdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow111110skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow499980skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLDAAACKSagow4///80skdWOGAAAAGOWdks08/////////5xpibTLFFFFFKSagow4///80skdWOGFFFFGOWdks08/////////5xpibTMMMMMMMSagow4///80skdWOMMMMMMOWdks08/////////5xpibUUUUUUUUUagow4///80skdWUUUUUUUUWdks08/////////5xpicccccccccccgow4///80skdccccccccccdks08/////////6yqkjjjjjjjjjjjjpx4///80tmjjjjjjjjjjjjmt08/////////81vrrrrrrrrrrrrru07///+3xsrrrrrrrrrrrrsx3+//////////62zzzzzzzzzzzzz16/////83zzzzzzzzzzzzzz38////////////976666666666668///////+76666666666667+/////////////////////////////////////////////////////////" },
    I = { 29, 50, -5.00, -5.00, 19.14, "////////////////////////////////////+88888888888889/////////////73000000000000026///////////92wsssssssssssssv17//////////6yrlkkkkkkkkkkkkqx4//////////5xpidddddddddddgow4//////////5xpibWWWWWWWWWagow4//////////5xpibTOOOOOOOSagow4//////////5xpibTLGGGGGKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLDAAACKSagow4//////////5xpibTLFFFFFKSagow4//////////5xpibTMMMMMMMSagow4//////////5xpibUUUUUUUUUagow4//////////5xpicccccccccccgow4//////////6yqkjjjjjjjjjjjjpx4//////////81vrrrrrrrrrrrrru07///////////62zzzzzzzzzzzzz16/////////////976666666666668////////////////////////////////////" },
    J = { 34, 50, -5.00, -5.00, 24.65, "///////////////////////////////////////////////98888888888888+//////////////////62000000000000038////////////////60vsssssssssssstx3+///////////////3wpkkkkkkkkkkkkmsz7//////////////+2vnfdddddddddddjrz6//////////////+2vnfYWWWWWWWWWcjrz6//////////////+2vnfYQOOOOOOOUcjrz6//////////////+2vnfYQJGGGGGMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////+2vnfYQJBAAAFMUcjrz6//////////////91tmfYQJBAAAFMUcjrz6///////////+++91tlfXPHAAAAFMUcjrz6////////74422220tlfXPHAAAAGOWdjrz6///////61xwvvvutqjdWOHAAAAGOWdks08//////92vqonnnnljfaTMFAAAAHPXdks08//////80skgfffffdaUPIBAAAAIQXflt19//////80skdaYYYXWTPJEAAAACKRZgnu29//////80skdWQQQQOMIEAAAAAEMTbgow3///////80skdWOJJIHFBAAAAABHOVdjqx5///////80skdWOGBAAAAAABCEHMSZgls07///////80skdWOGFFFGGGHIKMOSXdipw3+///////80skdWOMMMNOOOPQRTVZdintz6////////80skdWUUUUUWWWXYZbdginty4+////////80skdccccccdddffggjlpty49/////////80tmjjjjjjjkkkklnoqswz49//////////+3xsrrrrrrrrssstvwy036+////////////83zzzzzzzzz00012357+///////////////+7666666678889+/////////////////////////////////////////////////" },
    K = { 49, 50, -5.00, -5.00, 39.61, "////////////////////////////////////////////////////////+88888888888889////////+888888888888889/////////73000000000000026//////730000000000000026///////92wsssssssssssssv17////82wssssssssssssssv06//////6yrlkkkkkkkkkkkkqx4///+4xrlkkkkkkkkkkkkkpw3//////5xpidddddddddddgow4///6ztmgddddddddddddgnv3+/////5xpibWWWWWWWWWagow4//82vpidWWWWWWWWWWZgkrx4//////5xpibTOOOOOOOSagow4/+4xrkfZSOOOOOOORYdjpv28//////5xpibTLGGGGGKSagow4/6ztmgbUOHGGGGJQWcinu06///////5xpibTLDAAACKSagow481voidWQJDAABIOUbgmsy5////////5xpibTLDAAACKSagow43xqkfYSMFAAAGMSZfkqx39////////5xpibTLDAAACKSagow4ztmfbUNHBAAELRXdipv18/////////5xpibTLDAAACKSagow1uoidWQJCAACJPVcgnt06//////////5xpibTLDAAACKSagowwqjfYSLFAABHNTaglsy4///////////5xpibTLDAAACKSagowsmfaTNHAAAFMSYfjqw39///////////5xpibTLDAAACKSagouoicWPJCAAEKQXdiou17////////////5xpibTLDAAACKSagoqjfYRLEAACIPVbgntz6/////////////5xpibTLDAAACKSagolfaTNHAAAHNTaglry4+/////////////5xpibTLDAAACKSagoicVPJCAAFLSYfjqw29//////////////5xpibTLDAAACKSagoibTLEAADJQWdiou07///////////////5xpibTLDAAACKSagoibTLDACIOUbgmtz5////////////////5xpibTLDAAACKSagoibTLDAGNTZgkrx3+////////////////5xpibTLDAAACKSagoibTLDELRYdjpv28/////////////////5xpibTLDAAACKSagoibTLDGNVcinu06//////////////////5xpibTLDAAACKSagoibTLDFNVbgnt06//////////////////5xpibTLDAAACKSagoibTLDDKQXdipv29/////////////////5xpibTLDAAACKSagoibTLDAFMSZfkry4/////////////////5xpibTLDAAACKSagoibTLDABIOVbgnu07////////////////5xpibTLDAAACKSagoibTLDAADKRXdjpw29///////////////5xpibTLDAAACKSagoibTLDAAAGMTZflsy4///////////////5xpibTLDAAACKSagoibTMGAAABIPVcgnu07//////////////5xpibTLDAAACKSagojdXRKDAAAEKRXdjpw29/////////////5xpibTLDAAACKSagongcVOIBAAAGMTZflsy4/////////////5xpibTLDAAACKSagoskfZSMFAAABIPVcgnu07////////////5xpibTLDAAACKSagovpidXQJDAAAEKRXdjqw39///////////5xpibTLDAAACKSagowtngbUOHBAAAGMTaglsy5///////////5xpibTLDAAACKSagowxrkfZSLFAAABIPVcinu07//////////5xpibTLDAAACKSagow2vpidWQJCAAAELRYdjqw39/////////5xpibTLDAAACKSagow4ztmgbUNHAAAAGNTaglsy5/////////5xpibTLDAAACKSagow43xqkfYRLEAAACIPVcinu07////////5xpibTLDAAACKSagow481voicWPJCAAAELRYdjqw39///////5xpibTLFFFFFKSagow4/6zsmgaTNGFFFFGNTaglsz5///////5xpibTMMMMMMMSagow4/+3wqjdYRMMMMMMMPVciou17//////5xpibUUUUUUUUUagow4//71unicVUUUUUUUUUYfjqw3//////5xpicccccccccccgow4///5yslfccccccccccccgmt19/////6yqkjjjjjjjjjjjjpx4///93wpjjjjjjjjjjjjjjnu29/////81vrrrrrrrrrrrrru07////70urrrrrrrrrrrrrrty4///////62zzzzzzzzzzzzz16//////61zzzzzzzzzzzzzz049////////976666666666668////////8666666666666667+///////////////////////////////////////////////////" },
    L = { 41, 50, -5.00, -5.00, 31.38, "////////////////////////////////////////////////+88888888888889/////////////////////////73000000000000026///////////////////////92wsssssssssssssv17//////////////////////6yrlkkkkkkkkkkkkqx4//////////////////////5xpidddddddddddgow4//////////////////////5xpibWWWWWWWWWagow4//////////////////////5xpibTOOOOOOOSagow4//////////////////////5xpibTLGGGGGKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow4//////////////////////5xpibTLDAAACKSagow44444444444446+////////5xpibTLDAAACKSagowwwwwwwwwwwwwwz5////////5xpibTLDAAACKSagopoooooooooooopt07///////5xpibTLDAAACKSagoiggggggggggggiqx5///////5xpibTLDAAACKSagoibaaaaaaaaaabipx5///////5xpibTLDAAACKSagoibTSSSSSSSSTbipx5///////5xpibTLDAAACKSagoibTLKKKKKKLTbipx5///////5xpibTLDAAACKSagoibTLDCCCCDLTbipx5///////5xpibTLDAAACKSagoibTLDAAAADLTbipx5///////5xpibTLFFFFFKSagoibTLFFFFFFLTbipx5///////5xpibTMMMMMMMSagoibTMMMMMMMMTbipx5///////5xpibUUUUUUUUUagoibUUUUUUUUUUbipx5///////5xpicccccccccccgoiccccccccccccipx5///////6yqkjjjjjjjjjjjjpkjjjjjjjjjjjjkqy6///////81vrrrrrrrrrrrrrurrrrrrrrrrrrrrv18////////62zzzzzzzzzzzzz1zzzzzzzzzzzzzz26//////////976666666666668766666666666679/////////////////////////////////////////////" },
    M = { 61, 50, -5.00, -5.00, 51.33, "////////////////////////////////////////////////////////////////////+8888888888889///////////////////98888888888889/////////////7300000000000026/////////////////6200000000000026///////////92wssssssssssssv06///////////////60vssssssssssssv06//////////6yrlkkkkkkkkkkkpv29/////////////+2vpkkkkkkkkkkkkpw3//////////5xpiddddddddddfksz6/////////////7zslfddddddddddgnv2+/////////5xpibWWWWWWWWWcipw3+////////////4wpicWWWWWWWWWYgnv2+/////////5yqjdWPOOOOOOSZflsz6///////////81tmfZSOOOOOOOQYgnv2+/////////70tmgaSLGGGGHOVcipw3+//////////5xqjdWPIGGGGGJQYgnv2+//////////4xpidWPIBAAELSZgmt07/////////92ungbTMFAAAABJQYgnv2+//////////60tmfZSLEAABIPWdipw4/////////6zskfYRJCAAAABJQYgnv2+/////////70uqpicVOHAAAELSZgmt07///////+3wpicVOGAAAAABJQYgnv2+/////////5yqjklfZSLEAABIPWdjqx4///////70tmfZSKDAAAAABJQYgnv2+/////////5xpiioicVOHAAAFMTagmt18//////4xqjdWPHAAAAAABJQYgnv2+/////////5xpifklfYRKDAABIPWdjqx4/////91ungaTMEAAAAAABJQYgnv2+/////////5xpicioicVOHAAAFMTbgnu18////6yrkdXQJBAAAAAABJQYgnv2+/////////5xpibflkfYRJCAACJQXdjqy5///+2voibUNFAAAAAAABJQYgnv2+/////////5xpibcingbUNGAAAFMTbgnu29//7zslfYRKCAAAAAAABJQYgnv2+/////////5xpibZflkfYRJCAACJRYfkry5//4wpicVOHAAAAAAAABJQYgnv2+/////////5xpibWdingbTMFAAAGNUbgnv2981tmfZSLEAAAAAAAABJQYgnv2+/////////5xpibTZgmjdXQJCAACJRYfksz65xqjdWPIBAAAAAAAABJQYgnv2+/////////5xpibTWdjngbTMFAAAHOVciov22ungbTMFAAAAAAAAABJQYgnv2+/////////5xpibTTagmjdWPIBAADKRYfkszzskfYRJCAAAAAAAAABJQYgnv2+/////////5xpibTPWdjmgaTMFAAAHOVcipwwpicVOGAAAAAAAAAABJQYgnv2+/////////5xpibTMTbgnjdWPIBAAELSZflstmfZSKDAACDCAAAAABJQYgnv2+/////////5xpibTLQXdjmfZSLEAAAHOVcipqjdWPHABGKLJFAAAABJQYgnv2+/////////5xpibTLMTbgnidWPIAAAELSZgmngaTMEAGMRTQLFAAABJQYgnv2+/////////5xpibTLJQYfkmfZSLEAABIPWdingbTMFCKRXbWPIAAABJQYgnv2+/////////5xpibTLGNUbgnicVOHAAAELSagmjdXQIFNUbfYQJBAABJQYgnv2+/////////5xpibTLDJRYfklfZSLDAABIPWdjngaTMJQXdfYQJBAABJQYgnv2+/////////5xpibTLDGNVcioicVOHAAAFMTagmjdWPMTagfYQJBAABJQYgnv2+/////////5xpibTLDDKRYfkkfYRKDAABIPXdjmgaTPWdjfYQJBAABJQYgnv2+/////////5xpibTLDAHOVcioicVOGAAAFMTbgnidWSZgmfYQJBAABJQYgnv2+/////////5xpibTLDADLSZflkfYRJCAACJQXdjmfZVcinfYQJBAABJQYgnv2+/////////5xpibTLDAAHOVcingbUNGAAAFMUbgnicYfknfYQJBAABJQYgnv2+/////////5xpibTLDAAELSZgnkfYQJCAACJRYfklfbgnnfYQJBAABJQYgnv2+/////////5xpibTLDAABJQYgnngbTMFAAAGNUbgoidjqnfYQJBAABJQYgnv2+/////////5xpibTLDAABJQYgnqjdXQJCAACJRYfkkgmtnfYQJBAABJQYgnv2+/////////5xpibTLDAABJQYgnungbTMFAAAHOVcionrvnfYQJBAABJQYgnv2+/////////5xpibTLDAABJQYgnvqjdWPIBAADKRYflsxvnfYQJBAABJQYgnv2+/////////5xpibTLDAABJQYgnvtmgaTMFAAAHOVcipxvnfYQJBAABJQYgnv2+/////////5xpibTLFFFFJQYgnvxqjdWPIFFFJQYfkrzvnfYQJFFFFJQYgnv2+/////////5xpibTMMMMMMQYgnv0tmfZSMMMMMTbgnu2vnfYQMMMMMMQYgnv2+/////////5xpibUUUUUUUUYgnv2wpidWUUUUUWdjqx2vnfYUUUUUUUUYgnv2+/////////5xpiccccccccccgnv20tmfcccccccgmt02vnfccccccccccgnv2+/////////6yqkjjjjjjjjjjjov33wpjjjjjjjjjpx43vojjjjjjjjjjjjov3//////////81vrrrrrrrrrrrruz660urrrrrrrrru076zurrrrrrrrrrrruz6///////////62zzzzzzzzzzzz05+/61zzzzzzzzz16/+50zzzzzzzzzzzz05+////////////97666666666668////86666666668////86666666666668////////////////////////////////////////////////////////////////////" },
    N = { 51, 50, -5.00, -5.00, 41.53, "//////////////////////////////////////////////////////////+88888888888889////////98888888888888/////////////73000000000000026//////62000000000000149//////////92wsssssssssssssv06////71vssssssssssssty4//////////6yrlkkkkkkkkkkkkpv29///4xqkkkkkkkkkkkknt18/////////5xpidddddddddddfksy5///4wogdddddddddddks08/////////5xpibWWWWWWWWWWcinu18//4wogaWWWWWWWWWdks08/////////6yqjfYROOOOOOORYfjqx4//4wogaSOOOOOOOWdks08/////////81unicVOHGGGGGNTbgmt07/4wogaSKGGGGGOWdks08//////////5yslfZSLFAAACJQWdipw3+4wogaSKCAAAGOWdks08/////////70uqpidWPICAAAFMSZflsz64wogaSKCAAAGOWdks08/////////5yqjkmgaTMGAAABIPVciov24wogaSKCAAAGOWdks08/////////5xpignjdXRKDAAAELRYfkry4wogaSKCAAAGOWdks08/////////5xpidjngbVOHAAAAHNUbgnu0wogaSKCAAAGOWdks08/////////5xpibgmkfYSLEAAACJQXdjqwwogaSKCAAAGOWdks08/////////5xpibcioicWPIBAAAFMTagmtwogaSKCAAAGOWdks08/////////5xpibYfkmfZTMFAAABIPWdipvogaSKCAAAGOWdks08/////////5xpibUbgnjdXQJCAAAELSZfksogaSKCAAAGOWdks08/////////5xpibTXdjngbUNHAAAAHOVcgnogaSKCAAAGOWdks08/////////5xpibTTagmkfYRLEAAADKRYdjogbUNGAAAGOWdks08/////////5xpibTPWdioicVPIBAAAGNTbgmkfYRKEAAGOWdks08/////////5xpibTLSZfllfZSMFAAACJQWdinicVOHBAGOWdks08/////////5xpibTLOVcinidWQJCAAAFMSZfllfZSLFAGOWdks08/////////5xpibTLKRYfkmgbTNGAAABIOVcioidWPICGOWdks08/////////5xpibTLGNUbgmjdYRKDAAAELRYfkmgaTMGGOWdks08/////////5xpibTLDJQWdjngcVOHAAAAHNUbgnjdXRJGOWdks08/////////5xpibTLDFMTZglkfZSLEAAACJQXdjngbUOHOWdks08/////////5xpibTLDBIPVcioidWPIBAAAFMTagmkfYSLOWdks08/////////5xpibTLDAELSYfkmgaTMFAAABIPWcioicVPOWdks08/////////5xpibTLDAAHOUbgnjdXQJDAAAELSYfklfZTOWdks08/////////5xpibTLDAADJQXdkngbUOHAAAAHOVbgnjdXQWdks08/////////5xpibTLDAAAGOWdkrkfYRLEAAADKRXdjngbUWdks08/////////5xpibTLDAAAGOWdksoicVPIBAAAGMTagmkfYWdks08/////////5xpibTLDAAAGOWdksslfZSMFAAACJPWdioicWdks08/////////5xpibTLDAAAGOWdkswpidWQJCAAAFLSZfllfZdks08/////////5xpibTLDAAAGOWdks0tmgbUNGAAABHOVciniddks08/////////5xpibTLDAAAGOWdks0xqkfYRKEAAAEKRYfkmgdks08/////////5xpibTLDAAAGOWdks01unicVOHBAAAGNUbgmjdks08/////////5xpibTLDAAAGOWdks05yslfZSLFAAACJQWdjniks08/////////5xpibTLDAAAGOWdks082wpidWPJCAAAFMTZgloqv29/////////5xpibTLDAAAGOWdks086ztmgaTMGAAABIPVciov16//////////5xpibTLFFFFGOWdks08+3xqjdXRKFFFFFLRYfkry4//////////5xpibTMMMMMMOWdks08/71ungbVOMMMMMMOUbgnu19/////////5xpibUUUUUUUUWdks08//4yrkfYUUUUUUUUUXdks08/////////5xpiccccccccccdks08//92voicccccccccccdks08/////////6yqkjjjjjjjjjjjmt08///6zsmjjjjjjjjjjjjmt08/////////81vrrrrrrrrrrrrsx3+///+3xsrrrrrrrrrrrrsx3+//////////62zzzzzzzzzzzzz38/////83zzzzzzzzzzzzzz38////////////97666666666667+///////+76666666666667+/////////////////////////////////////////////////////////" },
    O = { 50, 51, -5.00, -5.50, 40.48, "////////////////////////////////////////////////////////////////////+9+88888888899+//////////////////////////////+86432130000000001124579////////////////////////9530yxvutwtssssssssttvwxz147+///////////////////+62yvtrponlqmkkkkkkkklmnoqsux037/////////////////94zvroljigfgnjdddddddfffggikmptw16///////////////94ytokgfdbaYgnjcWWWWWWXXYabcdgimqv16//////////////4ytnifbYWUSYgnjcUOOOOOPPQSTVXadgkqv17////////////60tnidYUROMQYgnjcUMGGGGHHJKLNPSWafkqw3+//////////+3wpidXSNJHJQYgnjcUMFAAAAABCEFILPUaglsz6//////////7zslfZSMHCBJQYgnjcUMFFFEDAAAAABEJPVcipw3+/////////4xqicVOIBABJQYgnjcUMMMMLKHDAAAAAELSZgmt08////////+2vngaTLEAABJQYgnjcUUUUUTSOJEAAAAAHPWdjrz6////////81tlfYQJBAABJQYgnjccccccbZUPJCAAAAFMUcipx4////////70skdWPHAAABJQYgnkijjjjiifaUNGAAAADLTagow4////////6zrjdVOGAAABJQYgnqpqrrrqpkfXQIBAAACKSagnv2+///////6yrjcUMFAAABJQYgnvxyzzzxungaSKCAAABJQYgnv2+///////5xpibUMEAAABJQYgnv266664wogbTLDAAABJQYgmt19///////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19///////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19///////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19///////4xpibTLDAAABJQYgnv2+///5xpibTMEAAAAHPXflt19///////4wogaTLDAAABJQYgnv2+///6yqjcUMFAAAAHPXflt19///////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAHPXfks08///////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAGOWdks08///////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAGOWdks08///////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAGOWdks08///////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAHPXfks08///////4wogaSKCAAABJQYgmt19///6zrjcUMFAAAAHPXflt19///////4wogbTLDAAAAHPXflt19///6zrjcUMFAAAAHPXflt19///////5xpibTLDAAAAHPXflt19///6zrjcUMFAAAAHPXflt19///////5xpibTLDAAAAHPXflt19///6zrjcUMFAAAAHPXflt19///////5xpibTLDAAAAHPXflt18///6zrjcUMFAAAAHPXflt19///////5xpibTLEAAAAHPWdks066766zrjcUMFAAABIQYflt19///////5xqicUMFAAAAGOVdjqyzzzzzzrjcUMFAAABJQYgnv2+///////6zrjcVNGAAAAEMTbgnqrrsrrrrjcUMFAAACKSZgnv2+///////7zskdWPHAAAACJRYdgjjjkjjjojcUMFAAADLTagow4////////81tlfYQJBAAAAGNSYbccddccgnjcUMFAAAFMUcipx4////////+2vngaSLEAAAACHNRTUUWWVYgnjcUMFAAAHPWdjrz6/////////4xpicVOHBAAAACGJMMMOOQYgnjcUMFAAELSZgmt08/////////6zslfZSMGCAAAAACEFFGJQYgnjcUMFAEJPVcipw3+/////////+3wpidWRNJGECBAAAAABJQYgnjcUMFHLPTaglsz6///////////6ztmgcYTROMKJHHGGFFJQYgnjcUMMOSVafjqw3+///////////+4xsmidbYVTSQPOOOMMMQYgnjcUSUWZcgjpu17/////////////83xsnjgfcbaYXWWWUUUUYgnjcYabdgilqu06///////////////83yuqnkjggffdddcccccgnjfggijlpsw16/////////////////951xusqonllkkjjjjjjjpnlmnprtwz37////////////////////852zywvttssrrrrrrruutuvwy036+///////////////////////975421000zzzzzzz12113468+/////////////////////////////+988866666668999+//////////////////////////////////////////////////////////////////" },
    P = { 47, 50, -5.00, -5.00, 37.41, "//////////////////////////////////////////////////////+8888888888888988888888889////////////////////7300000000000002000000000013469///////////////92wsssssssssssssvsssssssssttvxz259/////////////6yrlkkkkkkkkkkkkqlkkkkkkkklmnpsuy26////////////5xpidddddddddddgoiddddddddffgiknrv06///////////5xpibWWWWWWWWWagoibWWWWWWWXYacfgkpu06//////////5xpibTOOOOOOOSagoibTOOOOOOPRSVYbfjpv18/////////5xpibTLGGGGGKSagoibTLGGGGHHJLNRUZfkqx4/////////5xpibTLDAAACKSagoibTLDAAAAABDGJOUbgmt18////////5xpibTLDAAACKSagoibTLFECAAAAAADJQWdjqy5////////5xpibTLDAAACKSagoibTMMLJGCAAAAAFMTbgow3////////5xpibTLDAAACKSagoibUUUTRNHCAAAACKRZgnu2+///////5xpibTLDAAACKSagoiccccbYSNHAAAAAIQYflt19///////5xpibTLDAAACKSagokjjjigdYRKDAAAAHPXdks08///////5xpibTLDAAACKSagorrrrqnicUMFAAAAGOWdks08///////5xpibTLDAAACKSagowzzzxrjdWOGAAAAGOWdjrz6///////5xpibTLDAAACKSagow4660skdWOGAAAAFMUcjrz6///////5xpibTLDAAACKSagow4/80skdWOGAAAAFMUcjrz6///////5xpibTLDAAACKSagow4/80skdWOGAAAAFMUcjrz6///////5xpibTLDAAACKSagow444zskdWOGAAAAFNVcjrz6///////5xpibTLDAAACKSagowwwwvqjcVNGAAAAGOWdksz7///////5xpibTLDAAACKSagopooonlgbTMEAAAAHOWdks08///////5xpibTLDAAACKSagoiggggfcWQJCAAAAHPXfls08///////5xpibTLDAAACKSagoibaaaYVRLFAAAABJQYglt19///////5xpibTLDAAACKSagoibTSSROLFAAAAAELSagnv3+///////5xpibTLDAAACKSagoibTLKJHEAAAAABHOVcipx4////////5xpibTLDAAACKSagoibTLDBAAAAAACGMSYfksz6////////5xpibTLDAAACKSagoibTLDABBCDEGJNSWdiov29////////5xpibTLDAAACKSagoibTLHIJJJKMORTYdgmtz6/////////5xpibTLDAAACKSagoibTPPQQQRSTVYbfimsx4+/////////5xpibTLDAAACKSagoibXXXXYYYabdfgjntx38//////////5xpibTLDAAACKSagoifffffggggijknquy38///////////5xpibTLDAAACKSagomlllllnnnopqsux159////////////5xpibTLDAAACKSagoutttttuvvvwy0258//////////////5xpibTLDAAACKSagow1111122234679////////////////5xpibTLDAAACKSagow499999++/////////////////////5xpibTLDAAACKSagow4////////////////////////////5xpibTLDAAACKSagow4////////////////////////////5xpibTLDAAACKSagow4////////////////////////////5xpibTLDAAACKSagow4////////////////////////////5xpibTLFFFFFKSagow4////////////////////////////5xpibTMMMMMMMSagow4////////////////////////////5xpibUUUUUUUUUagow4////////////////////////////5xpicccccccccccgow4////////////////////////////6yqkjjjjjjjjjjjjpx4////////////////////////////81vrrrrrrrrrrrrru07/////////////////////////////62zzzzzzzzzzzzz16///////////////////////////////976666666666668////////////////////////////////////////////////////////////////////////" },
    Q = { 52, 57, -5.00, -5.50, 40.48, "//////////////////////////////////////////////////////////////////////+9+88888888899+////////////////////////////////+86432130000000001124579//////////////////////////9530yxvutwtssssssssttvwxz147+/////////////////////+62yvtrponlqmkkkkkkkklmnoqsux037///////////////////94zvroljigfgnjdddddddfffggikmptw16/////////////////94ytokgfdbaYgnjcWWWWWWXXYabcdgimqv16////////////////4ytnifbYWUSYgnjcUOOOOOPPQSTVXadgkqv17//////////////60tnidYUROMQYgnjcUMGGGGHHJKLNPSWafkqw3+////////////+3wpidXSNJHJQYgnjcUMFAAAAABCEFILPUaglsz6////////////7zslfZSMHCBJQYgnjcUMFFFEDAAAAABEJPVcipw3+///////////4xqicVOIBABJQYgnjcUMMMMLKHDAAAAAELSZgmt08//////////+2vngaTLEAABJQYgnjcUUUUUTSOJEAAAAAHPWdjrz6//////////81tlfYQJBAABJQYgnjccccccbZUPJCAAAAFMUcipx4//////////70skdWPHAAABJQYgnkijjjjiifaUNGAAAADLTagow4//////////6zrjdVOGAAABJQYgnqpqrrrqpkfXQIBAAACKSagnv2+/////////6yrjcUMFAAABJQYgnvxyzzzxungaSKCAAABJQYgnv2+/////////5xpibUMEAAABJQYgnv266664wogbTLDAAABJQYgmt19/////////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19/////////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19/////////5xpibTLDAAABJQYgnv2+///5xpibTLDAAAAHPXflt19/////////4xpibTLDAAABJQYgnv2+///5xpibTMEAAAAHPXflt19/////////4wogaTLDAAABJQYgnv2+///6yqjcUMFAAAAHPXflt19/////////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAHPXfks08/////////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAGOWdks08/////////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAGOWdks08/////////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAHOWdks08/////////4wogaSKCAAABJQYgnv2+///6zrjcUMFAAAAHPXflt08/////////4wogaSKCAAABJQYgmt19///6zrjcUMFAAAAHPXflt19/////////4wogbTLDAAAAHPXflt19///6zrjcUMFAAAAHPXflt19/////////5xpibTLDAAAAHPXflt19///6zrjcUMFAAAAHPXflt19/////////5xpibTLDAAAAHPXflt19///6zrjcUMFAAAAIQXflt19/////////5xpibTLDAAAAHPXflt18///6zrjcUMFAAABJQYgnu29/////////5xpibTLEAAAAHPWdks066766zrjcUMFAAABJRYgnv2+/////////5xqicUMFAAAAGOVdjqyzzzzzzrjcUMFAAACKSagnv3//////////6zrjcVNGAAAAEMTbgnqrrsrrrrjcUMFAAADLTbgow4//////////7zskdWPHAAAACJRYdgjjjkjjjojcUMFAAAFMUcipx5//////////81tlfYQJBAAAAGNSYbccddccgnjcUMFAAAHOWdjrz6//////////+2vngaSLEAAAACHNRTUUWWVYgnjcUMFAADKRZglt08///////////4xpicVOHBAAAACGJMMMOOQYgnjcUMFAAHOVciow3+///////////6zslfZSMGCAAAAACEFFGJQYgnjcUMFADKSYfksz6////////////+3wpidWRNJGECBAAAAABJQYgnjcUMFADLTbiou07/////////////6ztmgcYTROMKJHHGGFFJQYgnjcUMFADKSYfjqw29////////////+4xsmidbYVTSQPOOOMMMQYgnjcUMFAAHNTaglsy4+////////////83xsnjgfcbaYXWWWUUUVYgnjcUMFAACIPVcgntz6/////////////83yuqnkjggffdddccccdgnjcVOIBAAEKRXdiou17/////////////951xusqonllkkjjjjjkkplfZSLFAAAFMSYfjqw39//////////////852zywvttssrrrrrssvpidWPJCAABHNTaglsy4+///////////////975421000zzzzzz00tmgaTMGDDDDJPVcgntz6///////////////////+988866666783xqjdXRLLLLLLLRXdipv17//////////////////////////////71ungbUTTTTTTTTTZfkqw3///////////////////////////////4yrkfbbbbbbbbbbbbgmt19//////////////////////////////92voiiiiiiiiiiiiiimu19///////////////////////////////6ztqpppppppppppppsx4////////////////////////////////+50xxxxxxxxxxxxxxz38//////////////////////////////////75555555555555569//////////////////////////////////////////////////////" },
    R = { 49, 50, -5.00, -5.00, 39.09, "////////////////////////////////////////////////////////+88888888888889888888888889/////////////////////73000000000000020000000000013469////////////////92wsssssssssssssvssssssssssttvxz259//////////////6yrlkkkkkkkkkkkkqlkkkkkkkkklmnpsuy27/////////////5xpidddddddddddgoidddddddddffgiknsw16////////////5xpibWWWWWWWWWagoibWWWWWWWWXYacfilqv17///////////5xpibTOOOOOOOSagoibTOOOOOOOPRTVYcfkqw3+//////////5xpibTLGGGGGKSagoibTLGGGGGHHJLORVaglsz6//////////5xpibTLDAAACKSagoibTLDAAAAAABDGKPVciov3+/////////5xpibTLDAAACKSagoibTLFFDCAAAAAAELRYflt08/////////5xpibTLDAAACKSagoibTMMMLJFBAAAAAHOWdjry6/////////5xpibTLDAAACKSagoibUUUUTQMGAAAAAFMUbipx4/////////5xpibTLDAAACKSagoicccccbWSLEAAAADLTagow4/////////5xpibTLDAAACKSagokjjjjigdWPHAAAACKSagnv3/////////5xpibTLDAAACKSagorrrrrpmfZRKCAAABJRYgnv2+////////5xpibTLDAAACKSagowzzzzwogaSKCAAABJQYgnv2+////////5xpibTLDAAACKSagow4664wogbTLDAAABJQYgnv2+////////5xpibTLDAAACKSagow4++4xpibTLDAAABJQYgnv2+////////5xpibTLDAAACKSagow2222wogaTLDAAABJQYgnv2+////////5xpibTLDAAACKSagovvvvvtngaSKCAAABJQYgnv2+////////5xpibTLDAAACKSagonnnnnljfYQJBAAACKSagnv2+////////5xpibTLDAAACKSagoifffffdZTNGAAAADLSagow4/////////5xpibTLDAAACKSagoibYYYYWTOICAAAAEMTbipx4/////////5xpibTLDAAACKSagoibTQQQPMIDAAAAAHOVdjqy6/////////5xpibTLDAAACKSagoibTLJJHFBAAAAADKRYfls07/////////5xpibTLDAAACKSagoibTLDBAAAAAAAEIOVbgnv2+/////////5xpibTLDAAACKSagoibTLDAAAAAABGLPTZgkry5//////////5xpibTLDAAACKSagoibTLGCAAAAAFMSWafjpv29//////////5xpibTLDAAACKSagoibTQNHBAAAAIQXdgjpu06///////////5xpibTLDAAACKSagoibYYSMFAAABJQYgmqu06////////////5xpibTLDAAACKSagoiggdWPIAAAAHPWdjqx4/////////////5xpibTLDAAACKSagonnmfZSLDAAAFMTbgnu29////////////5xpibTLDAAACKSagovvpicVNGAAACJQXfkrz6////////////5xpibTLDAAACKSagowzskfYQJCAAAGNUciow3+///////////5xpibTLDAAACKSagow2ungbTMEAAADKRZflt07///////////5xpibTLDAAACKSagow4xqjdWOHAAAAHOWdjqx4///////////5xpibTLDAAACKSagow40tlfYRKCAAAEMTagnu29//////////5xpibTLDAAACKSagow43voibUMFAAABJQXfkrz6//////////5xpibTLDAAACKSagow46yrjdXPIBAAAGNUciov3+/////////5xpibTLDAAACKSagow481umfZSLDAAADKRYfls07/////////5xpibTLFFFFFKSagow4/4wpicVOGFFFFHOVdiqx4/////////5xpibTMMMMMMMSagow4/6zskfYQMMMMMMMTagnu19////////5xpibUUUUUUUUUagow4/92ungbUUUUUUUUUXdkry6////////5xpicccccccccccgow4//4xqjdccccccccccciow4////////6yqkjjjjjjjjjjjjpx4//70tmjjjjjjjjjjjjjpx4////////81vrrrrrrrrrrrrru07//+3xsrrrrrrrrrrrrru07/////////62zzzzzzzzzzzzz16////83zzzzzzzzzzzzzz16///////////976666666666668//////+766666666666668//////////////////////////////////////////////////////" },
    S = { 45, 51, -5.00, -5.50, 35.49, "/////////////////////////////////////////////////////////////+99+9888888999+//////////////////////////9753211210000001112345689//////////////////852zxwuttuussssssttuvwwxz0148//////////////+51xusqonllookkkkkkllmnooprsux39////////////94zuqnkigfffklfdddddffffggijkmsy5///////////+4ytokgfcbZYdklfXWWWXXXYZabcdfgow4///////////5ztnifbYVTRWdklfXPOOPPPQRSTUWagow4//////////70uoidYUROLOWdklfXPHGHHIJKKLMSagow4//////////4xqjdYSNJGGOWdklfXPHAAAABCCDKSagow4/////////80tmfaTNHCAGOWdklfXPHFFFFDDDCKSagow4/////////6yqjdWPICAAGOWdklfXPMMMMMLLLKKSagow4/////////4woibTMFAAAGOWdklfXUUUUUUTTSSRSagow4////////+2unfZSKCAAAGOWdklfcccccccbbaaYYagow4////////91tlfYQIAAAAGOWdkmijjjjjjiiiggggfgow4////////80slfXPHAAAAGOWdkspqrrrrrppponnmlmrx5////////80skdWOHAAAAGOWdksxyzzzzzxxxwvvtttw28////////80skdWOGAAAAGOWdkswxyz01234443211137/////////80skdWOGAAAAGNVcjnoprrstuvwxz02599///////////80skfXPHAAAAEMTafggijkklnnoprtvy25+//////////91tlfXPHAAAABIPUYabbcdfffggijlnruz49/////////91tmfYQJBAAAAEJORSTUUWXYYabcdfgkoty4+////////+2vngaSKCAAAAADHJKLMNOPQRSTUWYbfintz6/////////4woibUMFAAAAAAABCDEFGHIJKLMORUYdipv29////////6yrjdXQJDAAAAAAAAAAAAAABCDFHJNSZfksz6////////81umgbUOJFCAAAAAAAAAAAAAAAAACHOVcipw3/////////4xqkfZUQNKIGFEDCBAAAAAAAAAAADKSZgmu19////////81vpjfbXURPOMMLKJIHGFEBAAAAAAIPXdksz7/////////60upkgdbZXWUTTSQQPONLIDAAAAAGNVcjrz6//////////60vrnkigfdcbbaYYXWUSOICAAAAFMUcipx5///////////62xuromkjjigggffdcZTNHAAAADLTbipx4////////////841ywusrqponnlkkifYRJBAAADLTagow4//////////+9++96310zyxwvutsrngaSKCAAACKSagow4/////////731224445566543210wogaSKCAAACKSagow4////////71wtvvwwxxxzzzz0zzzwogaSKCAAADLTbiow4///////+3wqlnnooppqrrrrsrrrrogaSKCAAAELTbipx5///////91tlfffggiiijjjjkjjjjogaSKCAAAFMUciqx5///////91tlfYZaabbccccdddccgogaSKCAAAHOWdjrz6///////91tlfXSSSTTUUUUWWVUagogaSKCAABJQYfls08///////91tlfXPKLLLMMMMOOOSagogaSKCAAFMTagnu2+///////91tlfXPHDDEFFFFGGKSagogaSKCADJPWdjqx4////////91tlfXPHCBBAAAAACKSagogaSKDGJOUagmt07////////91tlfXPLKJIHHGGGGKSagogaSKLNQUZfkqx4/////////91tlfXTSSQQPPOOOOMSagogaSQSUXbgjpv17/////////91tlfcbaaYYXXWWWVUUagogaXYacfgkpu06//////////+2uojiigggfffddddcccgogdfggiknrv06////////////5zurqponnllkkkkjjjjkqkkklnpruy26/////////////+51zxxwvvttssssrrrrrvssstvxz249////////////////8654422110000zzzzz200013469///////////////////////++9988876666798889+///////////////////////////////////////////////////////////" },
    T = { 43, 50, -5.00, -5.00, 33.70, "///////////////////////////////////////////////98888888888888888888888888888888888+//////62000000000000000000000000000000000037////60vssssssssssssssssssssssssssssssssssw29///3wpkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkklry6//+2vnfddddddddddddddddddddddddddddddddipx5//+2vnfYWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWbipx5//+2vnfYQOOOOOOOOOOOOOOOOOOOOOOOOOOOOTbipx5//+2vnfYQJGGGGGGGGGGGGGGGGGGGGGGGGGGLTbipx5//+2vnfYQJBAAAAAAAAAAAAAAAAAAAAAAAADLTbipx5//+2vnfYQJCCCCCCCCCCCCCCCCCCCCCCCCCDLTbipx5//+2vnfYQKKKKKKKKKKKKKKKKKKKKKKKKKKKLTbipx5//+2vnfYSSSSSSSSSSSSSSSSSSSSSSSSSSSSSTbipx5//+2vnfaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabipx5//+3vngggggggggggggggggggggggggggggggggiqx5///4ysooooooooooooooooooooooooooooooooopt07///93ywwwwwwwwwrjggggggggggggmtwwwwwwwwwz5/////9544444444zrjcaaaaaaaaaaflt1444444446+//////////////6zrjcUSSSSSSSSXflt19///////////////////////6zrjcUMKKKKKKPXflt19///////////////////////6zrjcUMFCCCCHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFAAAAHPXflt19///////////////////////6zrjcUMFFFFFHPXflt19///////////////////////6zrjcUMMMMMMMPXflt19///////////////////////6zrjcUUUUUUUUUXflt19///////////////////////6zrjcccccccccccflt19///////////////////////7zsljjjjjjjjjjjjnu29///////////////////////92wsrrrrrrrrrrrrty4/////////////////////////72zzzzzzzzzzzzz049//////////////////////////976666666666667+////////////////////////////////////////////////////////" },
    U = { 50, 50, -5.00, -5.00, 40.02, "/////////////////////////////////////////////////////////98888888888888+//////+88888888888889/////////////62000000000000037////73000000000000026///////////71vsssssssssssssw29//92wsssssssssssssv06//////////4xqkkkkkkkkkkkklry6//6yrlkkkkkkkkkkkkpw3//////////4wogdddddddddddipx5//5xpidddddddddddgnv2+/////////4wogaWWWWWWWWWbipx5//5xpibWWWWWWWWWYgnv2+/////////4wogaSOOOOOOOTbipx5//5xpibTOOOOOOOQYgnv2+/////////4wogaSKGGGGGLTbipx5//5xpibTLGGGGGJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAABJQYgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAACKSZgnv2+/////////4wogaSKCAAADLTbipx5//5xpibTLDAAACKSagow4//////////4wogaSKCAAADLTbipx5//5xpibTLDAAACKSagow4//////////4wogaSKCAAADLTbipx4//5xpibTLDAAACKSagow4//////////4wogaSKCAAADLSagow4+/5xpibTLDAAACKSagow4//////////4wogbTLDAAACKSagow2342xpibTLDAAACKSagow4//////////5xpibTLDAAACKRZgmtvvwvvpibTLDAAADLTbgow4//////////5xpibUMEAAAAIPXdjlnnonnpibTLDAAAELTbipx5//////////6yrjcUNFAAAAFMTZdffggfgoibTLDAAAFMUciqx5//////////7zrkdWPHAAAACIOTWYYaaagoibTLDAAAHOWdjrz6//////////81tlfYRJCAAAADIMPQQSSagoibTLDAACJRYflt08//////////+3vogbUNHBAAAABFHJJKSagoibTLDABHNUbgnv2+///////////5yrkfYSMHEBAAAAABCKSagoibTLDDHMSYfkry5////////////92uoidXSOLIGFDDCCCKSagoibTLILOSXdiou29/////////////5ztmgdZVSQOMLLKKJKSagoibTOPSVYdgmtz5//////////////+4xsnifcaXWUTSSSQQSagoibUVXZcfinsx3+///////////////83ytpkigfdcbaaaYYYagoibcdfgikoty38/////////////////94zvspnkjiiggggggggoiiijkmpsvz49///////////////////+62zxusrppoonnnnnnsppprsuwz26+//////////////////////96420zxxwwvvvvvvywwxz01469///////////////////////////98654442222234445679/////////////////////////////////////++++++//////////////////////" },
    V = { 48, 50, -5.00, -5.00, 38.45, "////////////////////////////////////////////////////98888888888888+///////////98888888888888+/////+51000000000000037/////////62000000000000037////5zusssssssssssssw29///////60vsssssssssssssw29//+2uokkkkkkkkkkkklry5///////3wpkkkkkkkkkkkklry6//91tlfdddddddddddgow3//////91tmfdddddddddddiqx5//+3vngbWWWWWWWWWZgmu19/////6zskdXWWWWWWWWXfksz7///5xqjcVOOOOOOOPXdksz7/////4xpicVOOOOOOOSZgnu29///7zskfYQIGGGGGNVciqx4////+3vngaTLGGGGGMUbipw4////92ungaSLDAAAELTagnv3+///80tlfYRJBAAAHPWdjry6/////4xpicUNFAAABJRYflt18///6zrjdWOHAAACJRYglt18/////6zrkdXPHAAAAHPWdjrz6///4xpicUMFAAAEMTbgov3+/////91tmfZRKCAAAFMUcipx4//+2ungaSLDAAAGOVdjqy5///////3wogbTMFAAADLSagnu2+/80slfYQJBAABJQYfks07///////5yqjdWOHAAABIQYfls07/6yrjdWOHAAADLSagnu29///////80slfYRJBAAAHOVdjqy6/4wpibUMFAAAFNVcipx4////////+2vngaTLEAAAEMTbiow392unfZSKDAAAIPXdksz6/////////4xqicVNGAAACKRZgmu170skfXQIAAACKRZgmu19/////////7zskfXQIAAAAIPXfksz5yqjdVOGAAAFMUbiow3//////////92unfZSKDAAAGNVciqx3wogbTMEAAAHOWdjry6///////////4wpicUMFAAAELTbgnv1umfZRKCAACJRYflt08///////////6zrjdWPHAAACJRYfltzskfXPIAAAELTbgnv2+///////////81tlfYRJCAAAHPWdjrxqicVNGAAAGOVciqx5////////////+3vogbTMEAAAFMUcipvogbTLEAABIQXfksz7/////////////5yqjdVOHAAADLSagntmfYRJCAADKSagnu29/////////////70slfYQJBAABIQYflrkdWPHAAAFNUcipw4//////////////+2ungaSLDAAAHOVdjpicUNFAAAHPWdkrz6///////////////4xpicUNFAAAEMTbiogbTMEAACJRYgmt18///////////////6zrkdXPIAAACKSZgmjdVOGAAEMTbgov3////////////////91umfZSKDAAAIPXfkkfXQIBAHOVdjqy5/////////////////4wpibUMFAAAGNVcingaSKDBJQYfls07/////////////////6yrjdWPHAAAELTbgoibUMFDLTagnu2+/////////////////81tlfYRJCAACJRYfljdWOHGNVcipx4//////////////////+3vogbTMEAAAHPWdklfYRJIPXfksz6///////////////////5xqjdVOGAAAFNUcingaTLKSZgmu19///////////////////70skfYQIBAADLSagnicVNMUbipw4////////////////////92ungaSLDAABJQYflkdXPPWdjry6/////////////////////4xpicUNFAAAHOWdjmfZRRYglt18/////////////////////6zrkdXPHAAAFMTbiogbTTbgov3+/////////////////////91tmfYRJCAACKSZgmjdVVcjqy5///////////////////////3vogbTMEAAAIPXfkkfXXfksz7///////////////////////5yqjdVOHFFFGNVcingaagnu29///////////////////////70slfYQMMMMMMTbgoibcipx4////////////////////////+2vngaUUUUUUUUYfljddkrz6/////////////////////////4xqiccccccccccdklfgmu19/////////////////////////7zsmjjjjjjjjjjjlojjpw4//////////////////////////+3xsrrrrrrrrrrrsurru07///////////////////////////83zzzzzzzzzzzzz0zz16/////////////////////////////+76666666666678668///////////////////////////////////////////////////////////////" },
    W = { 67, 50, -5.00, -5.00, 57.77, "///////////////////////////////////////////////////////////////////////98888888888888+///////+88888888888888+///////98888888888888+//////62000000000000037/////830000000000000038/////62000000000000037////71vsssssssssssssw29///+3xtsssssssssssstx3+///71vsssssssssssssw29///4xqkkkkkkkkkkkklry6///7zsmkkkkkkkkkkkkmsz6///4xqkkkkkkkkkkkklry6///4wogdddddddddddiow4///5yqjddddddddddddipx5//+2vnfdddddddddddipx5///4xpicWWWWWWWWWagnv2+//4woibWWWWWWWWWWbgov3//91tlfYWWWWWWWWWdkrz6///6zrkdWOOOOOOOQYflt18/+2unfZSOOOOOOOORYgmt19/70skdXPOOOOOOQYflt08///80tlfYQJGGGGHPWdksz7/80slfYQIGGGGGGHPXdksz7/6yrjdVOGGGGGLSagnv2+///+2vngaSLDAAAFNVcjqy5/6zrjdWOHAAAAAAFNVcjqy5/4xpibUMEAAAFMUcipx4/////4xpibUMFAAAEMTbgow4/4xpicUMFAAAAAAEMTbgow3/3vogaTLDAAAHOWdjrz6/////6yrjdWOHAAACKSZgnu2+3vogaTLDAAAAAACKRZgmu192unfYRJCAABIQYfls08/////80slfXQIAAAAIQYflt081tmfYRJCAAAAAAAIPXfksz70tlfXQIAAADKSagnu2+/////92unfZSKCAAAHOWdkrz70skfXPHAAAAAAAAGNVcjqy6zrkdWOHAAAEMTbipw4///////4woibTMEAAAFNUciqx5yqjdVOGAAAAAAAAEMTbiow4yqjcUNFAAAGOVdjqy6///////6yqjcVNGAAAELTbgow3wpibTMEAAAAAAAACKSZgnu2wpibTMEAAAIQXfks07///////7zskfXPIAAACKRZgnu2vnfaSKDAAAAAAAAAIQXfks0vngaSKDAACKRZgnu29///////91umfZRKCAAAIQXfls0tlfYQIBAAAAAAAAAGOWdjrytmfYQJBAAEMTbgow3/////////3wogbTLEAAAHOWdjrzrkdWPHAAADFECAAAFMUbipwskfXPHAAAGNVcjqy5/////////5xqicVNFAAAFMUcipxqicUNFAAFKMMJFAADKSagnurjdWOGAAAHPXfksz7/////////7zskdXPHAAADLTbgovogbTLEAELRUUQKDABIQYfltpicUMFAACJRYgmt19/////////91tlfYRJBAACJRYgmumfZRKCAHOWcbVNFAAHOWdjrogbTLDAAELTbgov3//////////+3vngaTLDAAAIPXfkskfXPIABJRYgdXPHAAFMUcipnfZSKCAAFNVciqx5///////////4xpicUMFAAAGOWdjrjdWOGADLSagfYRJBADLSagnlfYQIBAAHPWdksz7///////////6zrjdWOHAAAFMUcipibUMFAFMUcigaTLDABJQYflkdWPHAABJRYglt18///////////80tlfYQJBAADLTagnibTMEAHOWdjicUMFAAHPWdklfYQIBADLTagnv3+///////////+2vngaSKDAABJRYgmjcVNGAIQXfljdWOHAAFNUcingaSKDAFMUcipx4/////////////4wpibUMFAAAHPXfkkdXPHCKSZgnlfYQJBADLTagoibUMFAHOWdjrz6/////////////6yrjdWOHAAAGOVdjmfYRJEMTbiongaSLDACJRYgmjdWOGBJQYflt08/////////////80slfYQIAAAEMUbingaSLGNVcjqpicUMFAAHPXdkkfXQIDLSagnv2+/////////////+2unfZSKCAADLSagnibUMHPXdksrjdWOHAAFNVcinfZSKFMUbipx4///////////////4woibTMEAABJRYfljdVOJRYgmtslfYQIBAELTbgoibTMHOWdjry6///////////////6yqjdVOGAAAHPXdkkfXPLSagnvungaSKDACKRZgmjcVNIQYfls08///////////////70skfXQIAAAGNVcjmfYRMUcipxwpibTMEAAIPXfkkfXPKSagnu2+///////////////92unfZSKCAAEMTbingaSOWdjrzyqjdVOGAAGNVcjmfZRMUbipw4/////////////////4woibTMEAADKSagnibUQYfls00skfXQIAAEMTbiogbTOVdjry6/////////////////6yqjcVNGAABJQYfljdVSagnu22unfZRKCACKSZgnicVQXfks07/////////////////7zskfXPIAAAHPWdkkfXTbipw43wogbTMEAAIQXfkkdXSZgnu29/////////////////91umfZRKCAAFNVcjmfYVdjqy65yqjcVNGAAGOVdjmfYTbgow4///////////////////3wogbTLEAAEMTbiogaXfks077zskfXPIAAEMUbingaVcjqy5///////////////////5xqicVNFAACKSagnicZgmu1991umfYRJCADKSagnicXfksz7///////////////////7zskdWPHFFFIQYfljdbgow3//3vogbTLFFFIQYflkdYgmt19///////////////////81tlfYRMMMMMOWdkkfciqx5//5xqicVNMMMMOWdjlfbgov3////////////////////+3vngaUUUUUUUUcimfdksz7//7zskdXUUUUUUUcingciqx5/////////////////////4xpiccccccccccgoggmt19//91tmfcccccccccgnidksz7/////////////////////6zsljjjjjjjjjjjpkjov3////3vojjjjjjjjjjjoljnu19/////////////////////92wsrrrrrrrrrrrurruz6////6zurrrrrrrrrrrusrty4///////////////////////72zzzzzzzzzzzz1zz05+////+50zzzzzzzzzzz0zz049////////////////////////97666666666668768////////8666666666668767+///////////////////////////////////////////////////////////////////////////////" },
    X = { 49, 50, -5.00, -5.00, 39.32, "/////////////////////////////////////////////////////9888888888888888/////////+888888888888888///////6200000000000000149//////8300000000000000149////71vssssssssssssssty4/////+3xtsssssssssssssty4////4xqkkkkkkkkkkkkkknt06////6zsmkkkkkkkkkkkkknt18///4wogdddddddddddddipw29//92wpiddddddddddddgks08///5yslfZWWWWWWWWWWZflsy4//6zslfZWWWWWWWWWWdipv29///92wpidWQOOOOOOOOVcgnu0792voicVOOOOOOOOUbgmt06/////60tmgbUOHGGGGGKRXdjqw35yrkfYRKGGGGGLRYfkqx4+//////4xrkfYSLFAAAAGMTagmsz1ungbVOHAAABIPVciou18///////82voidWPJCAAACIPWciouxqkfYRKDAAAFMTaglsz5/////////6ztmgaTNGAAAAELRYfkqungbUNGAAADKQXdjqw3+/////////+3xqjfYRLEAAAAHNUbgmqjdXQJCAABHOVbgnu07///////////71unicVPIBAAACJQWdipidWPJCAAFLSZfkry4/////////////5yslfZTMGAAAAFLSZfkmgaTNGACJQWdipv29/////////////93wpjdXRKDAAABHOUbgnjdYRLEGNTbgmtz6///////////////70ungbVOIBAAADJQXdinicVPILRYfjqx3+////////////////4yrkfZSMFAAAAFMSZfllfZTMPVcinu18/////////////////92vpidWQJCAAABIPVcgnjdXQTZglsy5///////////////////60tmgbUNHAAAAEKRYdjngbVXdjpw39///////////////////+4xqkfYSLEAAAAGNTagmkfZbgnt07/////////////////////81voicWPJCAAACIPWcioidfkry4///////////////////////6zsmgaTNGAAAAELRYfkmgipv29///////////////////////+3wqjdYRKEAAAAHNUbgmmntz6/////////////////////////71unicVPIBAAACJQWdipuy4+/////////////////////////4ytrlfZTMFAAAAFMSZfkry4/////////////////////////70tnjojdXQKDAAABHOVbgnt07///////////////////////93wpidjngbVOHBAAADKQXdjpw29//////////////////////5yslfagmkfZSMFAAAAFMTZflsy5/////////////////////81unicWdioidWQJCAAABIPVcinu07///////////////////+3xqjfYSYfkmgbUNHAAAAEKRYdjqw3+//////////////////6ztmfbTOUbgmkfYRLEAAAAGNTagmsz6/////////////////92vpidWQJQWdioicWPICAAACIPWciov18////////////////4yrkfZSLFMSZflmfaTNGAAAAELRYfkqx4+//////////////70ungbVOHBIOVcgnjdYRKEAAAAHNUbgmtz6/////////////+3wqjdXRKDAEKRYdjngcVOIBAAACJQWdipv29////////////6zsmfaTMGAAAGNTagnlfZSMFAAAAFMSZfkry4///////////82voicWPICAABIPWdjqpidXQJDAAABHOVbgnu07//////////4xrkfYSLEAAAFMTagmttngbUOHAAAADKQXdjpw39////////70tngbUNHAAACJQXdjqxxrkfZSLFAAAAFMTZflsy5///////93wpidXQJCAAAFMTbgnu02vpidWPJCAAABIPVcinu17//////5yslfZSMFFFFFJQXdjqx46ztmgaTNHFFFFFLRYdjqw3+////81unicVPMMMMMMNUbgnu18+3xqjfYRMMMMMMMNTagmsz6////4xqjfYUUUUUUUUUYfkqx4//71uoicVUUUUUUUUUWciov29//91umfccccccccccccgnu18///5zslfccccccccccccfkrz7//92unjjjjjjjjjjjjjlry5////93wqkjjjjjjjjjjjjjlsz7///4ytrrrrrrrrrrrrrsw29/////71vrrrrrrrrrrrrrrsw29///940zzzzzzzzzzzzzz27///////62zzzzzzzzzzzzzzz27/////+7666666666666679/////////97666666666666679////////////////////////////////////////////////////" },
    Y = { 47, 50, -5.33, -5.00, 36.71, "///////////////////////////////////////////////////88888888888888+//////////988888888888889/////941000000000000038////////62000000000000026////4ytsssssssssssstx3+//////71vsssssssssssssv17//81tnkkkkkkkkkkkkmsz6//////4xqkkkkkkkkkkkkkqx4//80skfdddddddddddipw3+////81tmfdddddddddddiow4//92ungbWWWWWWWWWZgmt07////4xqjdWWWWWWWWWYfksz6///5yqjdXQOOOOOOPWdipw3///92ungbTOOOOOOOVciov29///81ungbTMGGGGGLSZgmt07//6zrkfYQJGGGGJRYfksz6/////4xqjdXQIBAABIPWdjqx4/+2voicUNGAAAGNUbgnv29/////81ungaTMFAAAFMTagmt086zslfYRKDAACJRYfkry5///////4xqjdWPIBAABIPWdjqx43wpicVOHAAAGNUbgnu29///////70tmgaTMFAAAFMTbgnu10tmfZSLEAACJRYfkry5/////////4xqjdWPIBAACJQXdjqxxqjdWPIBAAFMTbgnu29/////////70tmfZSLEAAAFMTbgnuungaTMFAACJQXdjqx5//////////+3wpidWPIBAACJRYfkrrkdXQJBAAFMTbgnu18///////////70tmfZSLEAAAGNUbgnngbUNFAACJQXdjqx4////////////+3wpicVOHAAACJRYfklfYRKDAAFMTbgnu18/////////////6zslfZSLEAAAHOVcioicVOHABIPXdjqx4//////////////+3wpicVOHAAADKRYfkkfYRJCFMTagmu18///////////////6zslfZSKDAAAHOVcingbUNGIPWdjqx4////////////////+3wpicVOHAAAELSZflkfYRJMTagmt07/////////////////6zskfYRKDAAAHOVcingbTMPWdjqx4//////////////////92voicVOHAAAELSZgmjdXQSZgmt07///////////////////6zskfYRJCAABIPWdingbTWdipw4////////////////////92vogbUNGAAAELSZgmjdWZgmt07/////////////////////5yrkfYRJCAABIPWdjmgadipw3+/////////////////////92ungbUNGAAAFMTagmjdgmt07///////////////////////5yrkfYRJCAABIPXdjmfipw3+///////////////////////92ungbUNGAAAFMTbgnjmsz6/////////////////////////5yrkfYRJCAACJQXdjrsx3+/////////////////////////92ungbTLDAAAFMUbgnv38///////////////////////////5xpibTLDAAACJRYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLDAAABJQYgnv2+///////////////////////////5xpibTLFFFFFJQYgnv2+///////////////////////////5xpibTMMMMMMMQYgnv2+///////////////////////////5xpibUUUUUUUUUYgnv2+///////////////////////////5xpicccccccccccgnv2+///////////////////////////6yqkjjjjjjjjjjjjov3////////////////////////////81vrrrrrrrrrrrrruz6/////////////////////////////62zzzzzzzzzzzzz05+//////////////////////////////976666666666668///////////////////////////////////////////////////////////////" },
    Z = { 45, 50, -5.00, -5.00, 35.84, "///////////////////////////////////////////////////+888888888888888888888888888888889//////////830000000000000000000000000000000026////////+3xtsssssssssssssssssssssssssssssssv06///////7zsmkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkpw3///////6zrjddddddddddddddddddddddddddddddgnv2+//////6zrjcWWWWWWWWWWWWWWWWWWWWWWWWWWWWYgnv2+//////6zrjcUOOOOOOOOOOOOOOOOOOOOOOOOOOQYgnv2+//////6zrjcUMGGGGGGGGGGGGGGGGGGGGGGGGJQYgnv2+//////6zrjcUMFAAAAAAAAAAAAAAAAAAAAAABJQYgnv2+//////6zrjcUMFFFFFFFFFFFFFFFFFFFFFFFFJQYgnv2+//////6zrjcUMMMMMMMMMMMMMMMMMMMMMMMMMMQYgnv2+//////6zrjcUUUUUUUUUUUUUUUUUUUUUUUUUUUUYgnv2+//////6zrjccccccccccccccccccccccccccccccgnv2+//////7zsljjjjjjjjjjjjjjjjjjjjjjjjjjjjjjkqx4///////92wsrrrrrrrrrrrrrollllllllllllllmrrv18////////72zzzzzzzzzzzzvpjffffffffffffffipx26//////////976666666663xrkfZXXXXXXXXXXXbgmsz6/////////////////////5ztmfbUPPPPPPPPPSZfkqw39////////////////////60uoidWQJHHHHHHLRXdipv17////////////////////82vpjdYSLFAAAADJPVcgnt06////////////////////+3xrkfZTNHAAAABHOUaglsy4/////////////////////5ztmgbVPICAAAAGMSZfkqw39////////////////////70uoidWQKEAAAAELRXdipv17////////////////////82wqjfYSLFAAAACJPVcgntz6////////////////////+4xrlfaTNHAAAABHNUaglsy4+////////////////////5ztmgbVPICAAAAFMSYfkqw39////////////////////71uoidWQKEAAAAEKRXdiov17////////////////////92wqjfYSMFAAAACJPVcgntz6////////////////////+4yslfaTNHBAAABHNTaglsy4+////////////////////6ztngcVPJCAAAAFMSYfjqw29////////////////////71uoidXRKEAAAAEKRXdiou17////////////////////93wqjfYSMFAAAACIPVcgntz688888888889/////////+4yslfaTNHBAAABHNTaglsy00000000000026////////6ztngcVPJCAAAAFMSYfjqssssssssssssssv06//////+2vpidXRLEAAAAEKQWdiokkkkkkkkkkkkkkkpw3//////91tlfZSMGAAAACIPVbgmkfdddddddddddddgnv2+/////91tlfXPHBAAAAHNTaglmfbWWWWWWWWWWWWYgnv2+/////91tlfXPHAAAAFLSYfjnicWQOOOOOOOOOOQYgnv2+/////91tlfXPHAAAEKQWdioidXRLGGGGGGGGGJQYgnv2+/////91tlfXPHAACIPVbgmkfZSMGAAAAAAAABJQYgnv2+/////91tlfXPHFFHNTZgkmfbUOIFFFFFFFFFFJQYgnv2+/////91tlfXPMMMMSYdjnicWQMMMMMMMMMMMMMQYgnv2+/////91tlfXUUUUUWdiojdYUUUUUUUUUUUUUUUUYgnv2+/////91tlfcccccccgmkfcccccccccccccccccccgnv2+/////92unjjjjjjjjlrljjjjjjjjjjjjjjjjjjjjjov3///////4ytrrrrrrrrswsrrrrrrrrrrrrrrrrrrrrruz6///////940zzzzzzzzz2zzzzzzzzzzzzzzzzzzzzzz05+////////+7666666667976666666666666666666668//////////////////////////////////////////////////" },
    ["0"] = { 48, 51, -5.00, -5.50, 38.28, "/////////////////////////////////////////////////////////////////+99+888888889+//////////////////////////////9754211300000000123468////////////////////////742zxwvttwtssssssttuvxz136+///////////////////940xusqonllqmkkkkkkllnoprtwz37/////////////////83yuqnkigffgnjddddddfffgijmptw16///////////////83xsnjffcbZYgnjcWWWWWXYYacdfimqv16/////////////+3xsmgdaXVTSYgnjcUOOOOPQRSUWZdgkqv18////////////6ztmgcXTQNLQYgnjcUMGGHHIJLMPSWafkqx3+//////////92voidWRMIGJQYgnjcUMFAAAACDFILPUbgmt07//////////6zskfYSLGBBJQYgnjcUMFEDAAAAAAEJQWdipx4//////////4xpicVOHAABJQYgnjcUMMMKIEAAAAAFLSagnu29////////+2unfaSLDAABJQYgnjcUUUTSPJEAAAABIQXfks07////////80tlfYQIBAABJQYgnjccccbZUPJCAAAAGOVdjry6////////7zskdWOHAAABJQYgnkijjjifaTMFAAAAEMUbipx5////////6zrjcVNGAAABJQYgnqprrqpjdXPHAAAADLTbiow4////////6yqjcUMFAAABJQYgnvxzzytmfYQJBAAACKSagow4////////5xpibTMEAAABJQYgnv2662vnfZSKCAAACKSagow3////////5xpibTLDAAABJQYgnv2+/4wogaSKCAAACKRZgnv2+///////5xpibTLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////5xpibTLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4xpibTLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSKCAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSKCAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSKCAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSKCAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSKCAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4wogaSLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////4xpibTLDAAABJQYgnv2+/4wogaSKCAAABJQYgnv2+///////5xpibTLDAAABJQYgmt19/4wogaSKCAAABJQYgnv2+///////5xpibTLDAAAAHPXflt19/4wogaSKCAAABJQYgnv2+///////5xpibTLDAAAAHPXflt19/4wogaSKCAAACJRYgnv2+///////5xpibTMEAAAAHPXfks0684wogaSKCAAACKSagov3////////6yqjcUMFAAAAGOWdkrzz0zwogaSKCAAACKSagow4////////6zrjcVNFAAAAFNUciprrsrrogaSKCAAADLTbgow4////////7zskdWOHAAAADKSZfijjkjjogaSKCAAAEMUbipx5////////80slfXQIAAAAAHOTZccdddgogaSKCAAAGOVdjry6////////92unfZSKDAAAADIOSUUWWagogaSKCAABIQXfks07/////////4wpicUNGAAAAADHKMMOSagogaSKCAAELTagnu29/////////6zrkfYRLFBAAAAADFFKSagogaSKCAEJPWdiqx4//////////92unicWQMIFDBAAAACKSagogaSKEHLPUagmt07///////////5ysmgbWSPMLJIHGGFKSagogaSKMORVagkqw3+///////////93wrlgdZWUSQPPOONMSagogaSSTVYcgkqv17/////////////72wrmigdcaYXWWWUUUagogaYZbdgilqv16///////////////72xtpmjiggfdddccccgogfggijlosw16/////////////////840wtrpnmlkkkjjjjkqlllnoqsvz37///////////////////+731zxvutssrrrrrrvsstvwy0369///////////////////////86431100zzzzzz20012467+////////////////////////////+98887666679889+////////////////////////////////////////////////////////////////" },
    ["1"] = { 33, 50, -5.00, -5.00, 23.32, "////////////////////////////////////////////////98888888889////////////////////95200000000026/////////////////842yusssssssssv06//////////////841xurnkkkkkkkkkpw3////////////741xuqnkgfdddddddgnv2+////////+740xuqnjgfbYWWWWWWYgnv2+///////730xtqmjgdbXUROOOOOQYgnv2+//////82wtqmjfdbXTQNJGGGGJQYgnv2+//////4xrmjfdaXTQMJGCAAABJQYgnv2+/////+2vnfdaWTPMJFCAAAAABJQYgnv2+/////+2vnfYTPMIFCAAAAAAABJQYgnv2+/////+2vnfYQJFBAAAAAAAAABJQYgnv2+/////+2vnfYQJBCFGFDAAAAABJQYgnv2+/////+2vnfYQJGJMONKFAAAABJQYgnv2+/////+2vnfYQLORTWVQJCAAABJQYgnv2+/////+2vnfYQSVYbdbUMEAAABJQYgnv2+/////+2vnfYXacfgjcUMFAAABJQYgnv2+/////+2vnfbdgiknjcUMFAAABJQYgnv2+/////+2vngikmpsrjcUMFAAABJQYgnv2+//////4xrnoruxzrjcUMFAAABJQYgnv2+//////82xvwy14zrjcUMFAAABJQYgnv2+///////8423696zrjcUMFAAABJQYgnv2+/////////+///6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFAAABJQYgnv2+/////////////6zrjcUMFFFFFJQYgnv2+/////////////6zrjcUMMMMMMMQYgnv2+/////////////6zrjcUUUUUUUUUYgnv2+/////////////6zrjcccccccccccgnv2+/////////////7zsljjjjjjjjjjjjov3//////////////92wsrrrrrrrrrrrruz6///////////////72zzzzzzzzzzzzz05+////////////////976666666666668////////////////////////////////////////" },
    ["2"] = { 45, 50, -5.00, -5.67, 35.61, "/////////////////////////////////////////////////////////////+9999999++99+/////////////////////////+87654322111111221224569//////////////////+6421zyxwvvuttttttvutuvwxz147+//////////////94zwutsrpoonnllllllpolnnopruw048/////////////5ytonlkjiggfffffffflkffggikmptx27////////////3vniffdcbbaYYXXXXXflkdYabcdfimrw28//////////+2vnfZYWVUTSRQQPPPXflkdWSTUXZdglrx3+/////////+2vnfYQPNMLKJJIHHPXflkdWOLNPSWbgmsz6/////////+2vnfYQJFEDCCBAAHPXflkdWOGFIMQWciov29////////+2vnfYQJBBCCDDDDHPXflkdWOGABFLRYfksz7////////+2vnfYQJIJKKLLLLLPXflkdWOGAAAHOVciqx4////////+2vnfYQPQQSSTTTTTTXflkdWOGAAAELTagnv3////////+2vnfYWXYYaabbbbbbbflkdWOGAAABJRYgmu19///////+2vnfcdffggggiiiiiigmkdWOGAAAAIPXflt19////////3vojjkklnnoopppppoorkdWOGAAAAHPXfks08////////6zurrsstvvwwxxxxxwwskdWOGAAAAGOWdks08////////+50zzz0123445555540skdWOGAAAAHPWdks08//////////866789++////852zwrjdWOGAAAAHPXflt18///////////////////+741yvsplgbUMFAAAAIQYflt19/////////////////852zxurokifcWQJCAAACJRYgnu2+///////////////741yvspmjgfcZVRLFAAAAELTagov3//////////////840xurolifdbYVSOLFAAAAAHOVciqx4/////////////62xtqmjgfcaXUROLHEAAAAAEKRYfksz7////////////61vrmjfdbYVSPMJHEAAAAABFJPVcinv29///////////61vqkgdaXUROLIFCAAAAACFIMQUaglsy5///////////81vqkfbWTPMJHEBAAAABDGJMPSWbgkqw29///////////4xqkfaUQMIFCAAAAACFILORTWZdgkqv17///////////70tmfbUPJFBAAAABEHJMPSVYbdgimrv16////////////4xqjdWQJEAAAACFILORUWZcfgjmptx26////////////+2ungaTMFAAAAEJMPTVYbdgiknqtw048/////////////80slfYQJBAAAEKPTXacfgjmpsux037+//////////////7zrkdWOHAAABIPVadgilortwz258/////////////////6yrjcUNFAAAEMTagjmqsvy14444444444447/////////5xpibUMEAAAFMUcjquwwwwwwwwwwwwwwwwx16////////5xpibTLDAAAFMUcjroooooooooooooooooqv29///////5xpibTLDAAAFMUcjmgggggggggggggggggks08///////4wogbTLDAAAFMUcjlfaaaaaaaaaaaaaaadks08///////4wogaSKCAAAFMUcjlfXSSSSSSSSSSSSSWdks08///////4wogaSKCAAAFMUcjlfXPKKKKKKKKKKKOWdks08///////4wogaSKCAAAFMUcjlfXPHCCCCCCCCCGOWdks08///////4wogaSKCAAAFMUcjlfXPHAAAAAAAAAGOWdks08///////4wogaSKHHHHHMUcjlfXPHHHHHHHHHHHOWdks08///////4wogaSPPPPPPPUcjlfXPPPPPPPPPPPPPWdks08///////4wogaXXXXXXXXXcjlfXXXXXXXXXXXXXXXdks08///////4wogfffffffffffjlfffffffffffffffffks08///////5xrmlllllllllllnplllllllllllllllllou19///////82wttttttttttttuvtttttttttttttttttuz5/////////73111111111111221111111111111111125+///////////9999999999999+99999999999999999+//////" },
    ["3"] = { 45, 51, -5.00, -5.50, 35.38, "///////////////////////////////////////////////////////////+998888888+99/////////////////////////+97654321100000003123468+//////////////////+6310zxwvvttsssssstwtuvwy0258////////////////5zvtsrponnllkkkkkkmqlnnprsvx149/////////////80uolkjiggffffdddddjnffgijlnquy27////////////6zrjfddcbaYYXXWWWWcjnfYabdfgjnrw16///////////6zrjcXVUTSRQPPOOOUcjnfYSUWYbdglqv27//////////6zrjcUOMLKJIHHGGMUcjnfYQMORTXbgkrw3+/////////6zrjcUMFDCBBAAAFMUcjnfYQJHJMRVbgmsz6/////////6zrjcUMFCDDEFFFFMUcjnfYQJBCGKQWcipw3+////////6zrjcUMJKLLMMMMMMUcjnfYQJBAAFLSZflt08////////6zrjcUQRSTTTUUUUUUcjnfYQJBAAAHOWdjry6////////6zrjcXYYaabbcccccccjnfYQJBAAAFMUbipx5////////6zrjdfggggiijjjjjjiknfYQJBAAADLTbgow4////////7zsmklmnnoppqrrrrqpqnfYQJBAAACKSagow4////////+3xtsttvvwxxyzzzzyxvnfYQJBAAADLSagow4/////////830011234455555552vnfYQJBAAADLTbipx4//////////+8899+50xxxxxxxxxumfYQJBAAAFNUcipx5///////////////6ztqppppppppokfXPIAAABIPWdkrz6///////////////4wpiiiiiiiiiifbVOGAACGMSZgmt18///////////////4wogbbbbbbbbbZVQKDEGJNRWdipw3////////////////4wogaTTTTTTTTROKFHLOQTYcgmt07////////////////4wogaSLLLLLLLKHEHNSVYbdimsx4+////////////////4wogaSKDDDDDDCACJRYcfgjnsx38/////////////////4wogaSKCAAAAAAACKRZffikosx38/////////////////4wogaSKGGGGGGECAHOTXZcfimsx39////////////////4wogaSOOOOOOOMKHDINQSVYcgmsy5////////////////4wogaWWWWWWWVURNHCGILORWcinu29///////////////4wogdddddddddbYSMFAADHLRYfksz6///////////////4xqkkkkkkkkkjidXQJBAAAGNVcipx4///////////////71vsssssssssrngaSKDAAADLSagnv3///////////999+/62000000000wpibTLDAAABJRYgnu2+////////731122445566666765xpibTLDAAAAIQYflt19///////82wttuvwwxxyzzzzzzzxpibTLDAAAAHPXflt19///////5xrmlnnoopprrrrrsrrrpibTLDAAAAHPXflt19///////4wogfffggiijjjjjkjjjpibTLDAAABJQYgmt19///////4wogaYZabbbccccddccgoibTLDAAACKSZgnv2+///////4wogaSSSTTUUUUUWWVagoibTLDAAAFMTbgow4////////4wogaSKKLLMMMMMOOSagoibTLDAACIPWdjqy5////////4wogaSKCDDEFFFFGKSagoibTLDADHNTZgmt08////////4wogaSKDCCBAAAACKSagoibTLFHKOSYdjpw3+////////4wogaSMLKKJHHGGGKSagoibTLMPSVZdinu07/////////4wogaWUTSRQPPOONMSagoibTSUWZcginty5//////////4wogfdcbaZYXXWWVUUagoibYacdgikpty49//////////5ysmkjiigggffddccccgoifggijmpsvz49///////////93xusrpoonmlkkkjjjjjpmlnnprtwz26+/////////////8410zxwwvttsssrrrrruutuvxz1369/////////////////98654321100zzzzzz11123468//////////////////////////+99887666668999//////////////////////////////////////////////////////////////" },
    ["4"] = { 48, 50, -5.00, -5.00, 37.93, "//////////////////////////////////////////////////////////////////9888888888888889///////////////////////////////620000000000000026/////////////////////////////71vssssssssssssssv17///////////////////////////+3wqkkkkkkkkkkkkkkqx4///////////////////////////60tmfddddddddddddiow4//////////////////////////+3wpidWWWWWWWWWWZglsz6//////////////////////////6zslfZSOOOOOOOPWdipw39/////////////////////////92vpicVOIGGGGGMTagmtz6//////////////////////////6zskfZSLEAAACJQXdjqw3+/////////////////////////92voicVOHAAAAGNTbgnt07//////////////////////////5yrkfYRKDAAADKRYfjqx4//////////////////////////82ungbVOHAAAAHOVbgnu18//////////////////////////4xrkfYRKDAAAELSYfkry5//////////////////////////81ungbUNGAAABIPVciov29//////////////////////////4xqjdXQJCAAAFLSZglsz6//////////////////////////70tmgbTMFAAACIPWdipw3+++++++///////////////////+4xqjdWQJCAAAFMTagmt03222222247/////////////////70tmfaTMFAAACJQXdjqxyvvvvvvvvw17///////////////+3wpidWPIBAAAGNUbgnuxsnnnnnnnnqw3+//////////////6ztmfZSMFAAADKRYfkrxtmgffffffflt19/////////////+3wpidWPIBAAAHOVcinuwqjdYYYYYYflt19/////////////6zslfZSLEAAAELSZgksytmfaTQQQQXflt19////////////92voicVOHBAABIPWcipvwpidWPJJJPXflt19////////////6zskfYSLEAAAFMTZgmszslfZSLEBHPXflt199//////////92voicVOHAAACJQWdjpwvoicVOIBAHPXflt11137////////5yrkfYRKDAAAGMTbgmttskfYSLEAAHPXflttttw28//////81ungbUNHAAADJRXdjolllicVOHAAAHPXfllllmrx4//////5xqkfYRJCAAAHOUbgnjfffdYRKDAAAHPXdffffgnv2+/////4wogbUNGAAAELRYfkmfZXXXSNGAAAAFMSXXXXYgnv2+/////4wogaSKCAABHOVcioicWPPPMHCAAAABHMPPPQYgnv2+/////4wogaSKCAAELSZglkfZSLHHFBAAAAAABFHHJQYgnv2+/////4wogaSKCABIPWdinicVOHAAAAAAAAAAAAABJQYgnv2+/////4wogaSKCCFMTagmkfYRKDCCAAAAAAAAAACCJQYgnv2+/////4wogaSKKKKQXdjngbUNKKKKHDAAAAAAEIKKKQYgnv2+/////4wogaSSSSSTbgnjdXSSSSSROICAAAADJPSSSSYgnv2+/////4wogaaaaaaafjmfaaaaaaaZTMFAAAAGOUZaaaagnv2+/////4wpiggggggginkggggggggdWOGAAAAHPXfgggggnv3+/////6ztpooooooootqoooooookdWOGAAAAHPXfloooosy4//////+5zwwwwwwwwwzxwwwwwwskdWOGAAAAHPXfltwwwy39///////+644444444464444440skdWOGAAAAHPXflt14459/////////////////////////80skdWOGFFFFHPXflt19////////////////////////////80skdWOMMMMMMPXflt19////////////////////////////80skdWUUUUUUUUXflt19////////////////////////////80skdccccccccccflt19////////////////////////////80tmjjjjjjjjjjjjnu29////////////////////////////+3xsrrrrrrrrrrrrty4//////////////////////////////83zzzzzzzzzzzzz049///////////////////////////////+76666666666667+/////////////////////////////////////////////////////////" },
    ["5"] = { 46, 50, -5.00, -5.00, 36.42, "//////////////////////////////////////////////////////88888888888898888888888888889///////////////94100000000000200000000000000015+/////////////4ytsssssssssstvsssssssssssssssuz5////////////81tnkkkkkkkkkkmpkkkkkkkkkkkkkkkou2+///////////80skddddddddddjnfdddddddddddddflt19///////////80skdWWWWWWWWcjnfYWWWWWWWWWWWXflt19///////////80skdWOOOOOOUcjnfYQOOOOOOOOOPXflt19///////////80skdWOGGGGMUcjnfYQJGGGGGGGHPXflt19///////////80skdWOGAAFMUcjnfYQJBAAAAAAHPXflt19///////////80skdWOGAAFMUcjnfYQJDDDDDDDHPXflt19///////////80skdWOGAAFMUcjnfYQLLLLLLLLLPXflt19///////////80skdWOGAAFMUcjnfYTTTTTTTTTTTXflt19///////////80skdWOGAAFMUcjnfbbbbbbbbbbbbbflt19///////////80skdWOGAAFMUcjniiiiiiiiiiiiiiimu19///////////80skdWOGAAFMUcjrpppppppppppppppsx4////////////80skdWOGAAFMUcjrxxxxxxxxxxxxxxxz38////////////80skdWOGAAFMUcjrwvvvvvvvvwyz25569/////////////80skdWOGAAFMUcjoonnnnnnnopqsux15+/////////////80skdWOGAAFMUcigggffffffgijknquz49////////////80skdWOGAAEMTZbaaaYYYYYYabcfgjoty49///////////80skdWOGAABIOSTSSSQQQQQRSTVYbfinty4///////////80skdWOGAAADILLKKKJJJJJJKMORTYdinu07//////////80skdWOGAAAABDDDCCBBBBBCDEGJNSXdjpw3//////////80skdWOGABBBCCCCCCCBAAAAAAACHMTZgmt08/////////80skdWOHHJJJKKKKKKKJHFBAAAAABIPWdjry6/////////80skdWOPPQQQSSSSSSRQPMIDAAAAAFMUbipw4/////////80skdWWXXYYYZaaaaaZYWTOICAAAADKSagnv3+////////80skdddffggggggggggfdZTNHAAAABJQYgnu29////////80tmjkklllnnnooooonljfYRJCAAAAIQXflt19////////+3xsrrssttvvvwwwwwvtogbTLDAAAAHPXflt19/////////83zzz0011222444432xpibTLDAAAAHPXflt19//////////7556678999++++++5xpibTLDAAAAHPXflt19/////////60yxyz001112222222xpibTLDAAAAHPXflt19////////70uqpqrsstttvvvvvvvvpibTLDAAABIQYflt19////////5yqjijjkkllmnnnnnnnnpibTLDAAACJRYgnv2+////////5xpibcdddffffffffffgnibTLDAAADLSagov3/////////5xpibUVWXXXYYYYYYYYgnibTLDAAAFMUbipx4/////////5xpibTOOPPPQQQQQQQYgnibTLDAABIPWdjry6/////////5xpibTLGHHHJJJJJJQYgnibTLDABFMSZgmt18/////////5xpibTLDAAABBBBBJQYgnibTLDEHMRXdipw3//////////5xpibTLHGFEDCCCBJQYgnibTLJLOSWcgnt07//////////5xpibTQPOMMLKKKJJQYgnibTOQTVZdgmsy4///////////5xpibZYXWUTTSSSQQQYgnibUWYacgimsx39///////////5yqjggfddcbbaaZYYYYgnibcdfgilptx38////////////70uqonlkjjiiggggggggnjijklnqswz48//////////////60ywvtsrqpooonnnnnnsqpqrtvxz36+////////////////754210zyxwwwvvvvvvyyxyz0247+/////////////////////+98655444222223555578+/////////////////////////////////+++++//////////////////////" },
    ["6"] = { 48, 51, -5.00, -5.50, 38.40, "//////////////////////////////////////////////////////////////////+++8888888899++/////////////////////////////9754223000000001123456789////////////////////+741zxwvvxtsssssssttvvwxyz0248/////////////////840xusqonnrmkkkkkkkllnnopqstux28///////////////72xtqnkigfgnjddddddffffggijklnrx4//////////////72wrmifdcbZgnjcWWWWWXXYYabbcdfgnv2+////////////82wrlgdaXVTYgnjcUOOOOPPQQSTTVWYgnv2+///////////+4xrlfbWTQNQYgnjcUMGGGHHIJKLMNQYgnv2+///////////70tmgbVQMIJQYgnjcUMFAAAABBCDEJQYgnv2+///////////4wpidWQKFBJQYgnjcUMFFFFFDDDCBJQYgnv2+//////////81tmfZSMFABJQYgnjcUMMMMMMLLKKJJQYgnv2+//////////6yrjdWPIBABJQYgnjcUUUUUUUTTSSRQQYgnv2+//////////4wpibUMFAABJQYgnjcbbcccccbbaaYYXYgnv2+/////////+2vnfaSKDAABJQYgnjggijjjjiiiggggffgnv2+/////////91tlfYQIBAABJQYgnnmoprrrrppponnmlkkpw3//////////80skdXPHAAABJQYgnutwxyzzzxxwwvvutssv06//////////6zrjdWOGAAABJQYgnv120zzzzzzz002110026///////////6zrjcUMFAAABJQYgnvxutsrrrrrrstuwz269////////////5xpicUMFAAABJQYgntqnlkjjjjjjklnosvz49///////////5xpibTLDAAABJQYgnmigfdcccccddffikoty49//////////5xpibTLDAAABJQYgnjdaYWVUUUUWWXZcfinty5//////////5xpibTLDAAABJQYgnjcUQONMMMMOOQSVYdinu07/////////4wogbTLDAAABJQYgnjcUMHGFFFFGHIKOSYdjqx4/////////4wogaSKCAAABJQYgnjcUMFAAAAAAAADHNTagmu19////////4wogaSKCAAABJQYgnjcUMGGFDBAAAAACIPXdkrz6////////4wogaSKCAAABJQYgnjcUOOOMLIEAAAAAFNUcipx4////////4wogaTLDAAABJQYgnjcWWWWUSPJEAAAADLTagov3////////4xpibTLDAAABJQYgnjcddddcZUPJCAAACJRYgnv2+///////5xpibTLDAAABJQYgnljkkkjifaTMFAAABJQYgmt19///////5xpibTLDAAABJQYgnsrsssrpjdWOHAAAAHPXflt19///////5xpibUMEAAABJQYgnvzz00ztlfXPHAAAAHPXflt19///////6yrjcUMFAAABJQYgnv27881tlfXQIAAAAHPXflt19///////6zrjdVOGAAABJQYgmt16872unfYQJBAAAHPXflt19///////70skdWOHAAAAHPXflszz0zzvnfYQJBAABIQYflt19///////80slfXPIAAAAHOWdjprrssrsnfYQJBAABJQYgnv2+///////91umfYRJBAAAFMTZfijjkkjlnfYQJBAACKSagnv3+////////3vngaTLDAAABIPUZccdddcjnfYQJBAAEMTbgow4/////////4xpicVNGAAAAEJOSUUWWWcjnfYQJBAAGOVcjqy5/////////6zskfXQICAAAADILMMOOUcjnfYQJBACJQYfksz7/////////92ungaTMGBAAAABDFFGMUcjnfYQJBCHNTbgnu29//////////4xqjdXRMIFCBAAAAAFMUcjnfYQJGJNSYdjqx4///////////70unicXSPMKIHGGGFFMUcjnfYQLNQTYdiou18////////////4ysmgdZWTSQPOOOMMMUcjnfYRTVXbfintz5/////////////93xsnigdbZYXWWWUUUUcjnfYYacfgjoty4+//////////////83ytpmjggffdddcccccjnffggiknquz49////////////////940wtqonlkkkjjjjjjmpklmnpsux15+//////////////////+630ywvtsssrrrrrrsvstuvxz248//////////////////////+85421000zzzzzzz20113469////////////////////////////+988866666679889////////////////////////////////////////////////////////////////" },
    ["7"] = { 43, 50, -5.00, -5.00, 33.41, "////////////////////////////////////////////////+88888888888888888888888888888889/////////73000000000000000000000000000000015+//////92wsssssssssssssssssssssssssssssssuz5//////6yrlkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkou2+/////5xpidddddddddddddddddddddddddddddflt19/////5xpibWWWWWWWWWWWWWWWWWWWWWWWWWWWXflt19/////5xpibTOOOOOOOOOOOOOOOOOOOOOOOOOPXflt19/////5xpibTLGGGGGGGGGGGGGGGGGGGGGGGHPXflt19/////5xpibTLDAAAAAAAAAAAAAAAAAAAAAAHPXflt19/////5xpibTLDDDDDDDDDDDDDDDDDDDDDDDHPXflt19/////5xpibTLLLLLLLLLLLLLLLLLLLLLLLLLPXflt19/////5xpibTTTTTTTTTTTTTTTTTTTTTTTTTTTXflt19/////5xpibbbbbbbbbbbbbbbbbbbbbbbbbbbbbglt19/////5yqjiiiiiiiiiiiiiiiiiiiiiiiiiiiiiipw3+/////70uqppppppppppppppppllllllllllllmqtz6///////60yxxxxxxxxxxxxxxqjffffffffffffipx5+////////755555555555552ungbXXXXXXXXXXdkry6//////////////////////6yrkfYRPPPPPPPTagnu19/////////////////////92voibUNHHHHHIPWdjqx4//////////////////////6zskfYRKCAAAELSZgmt07/////////////////////+3wpicVOHAAAAHOVcipw3+/////////////////////70slfZSLDAAACKRYflsz6//////////////////////3wpidVOHAAAAGNUbiov2+/////////////////////70tmfZSLEAAACJQYfkry6//////////////////////4xqjdWPIBAAAFMTbgnu29/////////////////////81umfaTMFAAABIPWdjqx4//////////////////////4xqjdXPIBAAAELSZgmt08/////////////////////92ungbTMFAAAAHOVcipw4//////////////////////5yrkfYQJCAAADKRZglsz7/////////////////////92vogbUNGAAAAGNVciow3+/////////////////////6zskfYRJCAAACJRYfksz6/////////////////////+3wpicVOHAAAAFMTbgnu29/////////////////////6zslfZSKDAAABIPXdjqx5/////////////////////+3wpicVOHAAAAELTagmu18/////////////////////70tmfZSLEAAAAHOWdiqx4//////////////////////4xqjdWPIBAAADKSZglt07/////////////////////81tmfaTMEAAAAHOVcipw3+/////////////////////4xqjdWPIBAAACJRYfksz6/////////////////////92ungbTMFAAAAFMUbgnv29/////////////////////5yrkfXQJCAAABIQXdjry5/////////////////////92ungbUNGFFFFFMTagnu18/////////////////////6zskfYRMMMMMMMPWdjqx4/////////////////////+3voicVUUUUUUUUUZgmt07/////////////////////80slfccccccccccccipw3+/////////////////////80tmjjjjjjjjjjjjjmsz6//////////////////////+3xsrrrrrrrrrrrrrsx3+///////////////////////83zzzzzzzzzzzzzzz38/////////////////////////+766666666666667+/////////////////////////////////////////////////////////////" },
    ["8"] = { 49, 51, -5.00, -5.50, 39.21, "///////////////////////////////////////////////////////////////////+9+9888888899+//////////////////////////////+8643212100000001234679////////////////////////9630zxwvtuussssssstuvwy0247////////////////////+52yvtrponlookkkkkkllnnpqsux049/////////////////83zuroljigffklfdddddfffgijknqty27///////////////83xsokifdcaZdklfXWWWWXXYabdfgjnrw16/////////////93xsmifbYWUTWdklfXPOOOPQQSTVYbdglqv27////////////4ysmgcYUROMOWdklfXPHGHHIJKMOQTXbfkrw3+//////////81ungcWRNKHGOWdklfXPHBAAABDEGJMQVbgmsz6//////////5xqjdXRLHCAGOWdklfXPJIHGEAAAACFKQWcipw3/////////+3vngbTMGAAAGOWdklfXQQQPOLGBAAAAFLSZgmt19////////91tlfYRJCAAAGOWdklfYYYYXVRMGAAAAAIPXdksz7////////80skdXPHAAAAGOWdklfgggffcXRKDAAAAFNVcjrz6////////70skdWOGAAAAGOWdkplnnnlkicVNFAAAAFMUcipx5////////6zrjdVOGAAAAGOWdkstuvvtskdWOHAAAADLTbipx5////////7zskdWOGAAAAGOWdks02220slfXPHAAAAEMTbipx5////////80skdWOHAAAAGOWdksz7991tlfXPHAAAAFMUcjqy6////////80slfXQIAAAAGNVcjrz1110tlfXPHAAAAHOWdjrz6////////92unfZSKDAAAFMUcjqsttttrkdWOHAAACJQYfls08/////////4wpicVOIDAAEMTagjlllllkgcVNFAACHNTbgnu2+/////////6zskfZTOKHFCIPVbdfffffdbWRKDEHJNSYdjqx4//////////92vpjdZVROMJEKQTWXXXXXWUQLFIMORUYdiou18///////////60uojfcYWTPJFJMOPPPPPONJFIOTVYbfintz5/////////////5zupkifdaTMECFHHHHHHHFCDLSZdfgkoty4+////////////+5zupmjgfcUMFAABCCCCCCAADLTafgilpty49////////////5ztojfdaYWRKDFHJKKKKKJIFCIPUYacfinty4+//////////81uoidZWTROLFHMPRSSSSSRPMIEJOQSVZdintz6//////////4xqjfYTPMJHEHNSWYaaaaaYXTOIDGILOSXdipw3+////////92ungbTNIEBAELRYdgggggggdZTMFABEHMSZflt08////////70skfYQJCAAAGOVcimnoooomjdXPIAAABHOWdjry6////////6yrjdVOGAAAAHPXfksvwwwvumfYRJBAAAFMUbipw4////////5xpibUMEAAABIQYflt14443vngaSKCAAADKSagow4////////4wpibTLDAAABJQYgnv2+++4wogaSKCAAACKSZgnv2+///////4wogaSKDAAABIQYflt12222wogaSKCAAABJQYgnv2+///////4wogbTLDAAAAHPXfksuvvvvvogaSKCAAABJQYgnv2+///////5xpibTLDAAAAGOVcgknnnnnnogaSKCAAACKSagnv3+///////5xpicUMFAAAAELRXcffffffiogaSKCAAADLTbgow4////////6zrjdWOHAAAAAGMRVXYYYYbiogaSKCAAAGNVcipx5////////80tlfZSLEAAAABGLOQQQQTbiogaSKCAADJQXfksz6////////+3wpicVPKFBAAAAEGIJJLTbiogaSKCBEJOUbgnu29/////////6zslgaVQMJGECBAAABDLTbiogaSKFILPTZfkqx4//////////+3wqkfbWTQNLKIHHGGFLTbiogaSLNPSWafjpv18///////////71vqkgdaXVTSQPOOOMMTbiogaSTUXZdgjpu06/////////////61vrmjgfcbZYXWWVUUUbiogaYacdgimqu06///////////////62xtqnkiggffdddcccciogfggikmptw16/////////////////840xusqonllkkjjjjjkqmlnopruw037////////////////////742zxwvtsssrrrrrrvttuvxz147+///////////////////////975421000zzzzzz21123469//////////////////////////////+98876666679999//////////////////////////////////////////////////////////////////" },
    ["9"] = { 48, 51, -5.00, -5.50, 38.40, "////////////////////////////////////////////////////////////////+99998888888899+////////////////////////////+8643112200000000112457+//////////////////////+630ywvutuvsssssssttuvwy0269///////////////////73zwtrpnmlnpkkkkkkkllmnoqsvz37/////////////////61wspljigffjlfddddddfffggjlosw16///////////////61vqlifdbaYcjlfXWWWWWXXYabdfilqv17/////////////82vqkfcZWUSUcjlfXPOOOOPPQSTVYcgkqw29////////////4xrkfaVSOMMUcjlfXPHGGHHIJKMORVaglsy5///////////80tmgbUPLHFMUcjlfXPHAAAAABCEHLPVcgnu29//////////5xqjdWQJEAFMUcjlfXPHFFEBAAAAAEKRYfkrz6/////////+2vngbTMFAAFMUcjlfXPMMMLIFAAAAAGNUcipw4/////////81tlfYRJCAAFMUcjlfXUUUUTPLFAAAADKSZgmu19////////7zskdWPHAAAFMUcjlfcccccaWRLEAAAAIPXfks07////////6yrjcVNFAAAFMUcjnijjjjigcVOHAAAAGOVdjrz6////////5xpibUMEAAAFMUcjrprrrrqlfYRJCAAAFMUcipx5////////5xpibTLDAAAFMUcjrxzzzzvogaTLDAAADLTbiow4////////4woibTLDAAAFMUcjrz6664xpibTLDAAACKSagow4////////4wogaSKCAAAFMUcjrz6885xpibTLDAAACKSZgnv2+///////4wogaSKCAAAFMUciqx0000xpibTLDAAABJQYgnv2+///////4woibTLDAAAELTbgnrssssspibTLDAAABJQYgnu2+///////5xpibTLDAAACJRYdijkkkkkpibTLDAAAAIQYflt19///////5xpicUMFAAAAGNSYcdddddgoibTLDAAAAHPXflt19///////6zrjdVOGAAAACHNRUWWWWagoibTLDAAAAHPXflt19///////70skfXQIBAAAACHKMOOOSagoibTLDAAAAHPXflt19///////92ungaSLEAAAAAADFGGKSagoibTLDAAAAHPXflt19////////4xpidWPJEBAAAAAAACKSagoibTLDAAAAHPXflt19////////70tmgaUPLIHGFFDEFFKSagoibTLDAAAAHPXflt19////////+3wqkfaWSQONMMLLMNPSagoibTLDAAAAHPXflt19/////////71vpkgcaYWVUUTTUVWYbgoibTLDAAAAIQYflt19//////////60vqmigfdcccbbccdggjpibTLDAAABJQYgnu2+///////////61wspnlkjjiiiijklnqpibTLDAAABJQYgnv2+////////////73zxussrrpppqrstvxpibTLDAAACKSagnv2+//////////94211220zzzxxxxzz12xpibTLDAAADKSagow4//////////+4yuttvvwxxyzzzzzzxutpibTLDAAAELTbipw4//////////70tnlmnnoppqrrrrrrpnmpibTLDAAAFMUciqx5//////////6zrjfffggiijjjjkjjiggoibTLDAAAHOWdjrz6//////////6zrjcYYaabbcccddcccbgoibTLDAACJRYflt08//////////6zrjcURSSTTUUUWWUUUagoibTLDAAFMTbgnv2+//////////6zrjcUMKLLMMMMOONMSagoibTLDACIPWdjqx5///////////6zrjcUMFDDEFFFGGFKSagoibTLDCHNTagmt07///////////6zrjcUMFDCBBAAAACKSagoibTLHJNSYdjqx4////////////6zrjcUNMLKJJHHHGGKSagoibTMORUYdiou07////////////6zrjcWVTTSRQPPOOOOSagoibTTVYbfiotz5/////////////6zrjfdcbbaYYXXWWWWWagoibZbdfgkotz5+/////////////70tnlkjigggfffddddddgoigggjlnrvz5+//////////////+4yussqponnlllkkkkkkkqmlnoqsvy26+////////////////9420zyxwvvttssssssssvutvwy0259////////////////////9876543211000000002112457+/////////////////////////////+9988888888999+/////////////////////////////////////////////////////////////////" },
    ["&"] = { 52, 51, -5.00, -5.50, 42.86, "//////////////////////////////////////////////////////////////////////+//988888888899+////////////////////////////////865423310000000001123456789//////////////////////9631zxwvvwtsssssssssttvvwxzz0248//////////////////+52zwtrponnrmkkkkkkkklllnnoprstux28////////////////83zuromkigfiogddddddddffffggijklnrx4///////////////83xsokifdcbbiogaWWWWWWWXXYYabccdfgnv2+/////////////93xsmifcZWUTbiogaSOOOOOOPPQRSTUVWYgnv2+/////////////4ysmgcYURPNTbiogaSKGGGGHHHJJKLMNQYgnv2+////////////81ungcWRNKHLTbiogaSKCBBBBAABBCDFJQYgnv2+////////////5xqjdXRLHDDLTbiogaSKJJJJJIHHHGGFJQYgnv2+///////////+3vngbTMGAADLTbiogaSPQQQQQQPPPOOMMQYgnv2+///////////91tlfYRJCAADLTbiogaXXYYYYYYXXXWWUUTYgnv2+///////////80skdXPHAAADLTbiogdffgggggffffddccbbgnv2+///////////70skdWOGAAADLTbipkkllmnnnnlllkkjjiiggnv3+///////////6zrjdVOGAAADLTbipsstttvvvutttssrrppoosy4////////////7zskdWOGAAADLTbipx0111222211100zzxxwwy39////////////80skdWOHAAADLTbipx58999++999988665544599999+////////80slfXQIAAADLTbgow001113421111111111111111126///////92unfZSKDAACKSagnssttttwyutttttttttttttttttv06///////4wpicVOIDABJQXdikklllmrtnlllllllllllllllllpv2+//////6zskfZTOKHFFMSYcddfffgorjffffffffffffffffflt19//////92vpjdZVROMJHNSVWWXXagorjcXXXXXXXXXXXXXXXflt19///////60uojfcYWTPJHLNOOPSagorjcUPPPPPPPPPPPPPXflt19////////5zupkifdaTMEDFGHKSagorjcUMHHHHHHHHHHHPXflt19///////+5zupmjgfcUMFAABCKSagorjcUMFAAAAAAABBHPXflt19///////5ztojfdaYWRKDGIJJKSagorjcUMFAAAACGIJJJPXflt19//////81uoidZWTROLFKOQQQQSagorjcUMFAAABHNQQQQQXflt19//////4xqjfYTPMJHFLRVYYYYYagorjcUMFAAAFMSYYYYYYflt19/////92ungbTNIEBCJQWcfggggggorjcUMFAAAGOWdgggggglt19/////70skfYQJCAAEMTbgknnnnnnsrjcUMFAAAGOWdknnnnnqw3+/////6yrjdVOGAAAFNUcjquvvvvvyrjcUMFAAAGOWdksvvvvw17//////5xpibUMEAAAGOWdkrz22223zrjcUMFAAAGOWdks022247///////4wpibTLDAAAGOWdks08+++6zrjcUMFAAAGOWdks08++/////////4wogaSKDAAAGOWdjrz12222zrjcUMFAAAGOWdks08///////////4wogaTLDAAAFMUcipstvvvvvrjcUMFAAAGOWdks08///////////4xpibTLDAAADLSZfiklnnnnnrjcUMFAAAGOWdks08///////////5xpicUMFAAAAHOTZcffffffgmjcUMFAAAGOWdks08///////////6zrjdWOHAAAADIOSVXYYYYYfljcUMFAAAGOWdks08///////////80slfYRJDAAAADHLNPQQQQXfljcUMFAAAGOWdks08///////////+2ungbUOJFBAAAAEGHIJJPXfljcUMFAAAGOWdks08////////////5yrkfZUQMJGEDBAAABBHPXfljcUMFCCDGOWdks08////////////92vpjfbWTQOMKJIHGGGHPXfljcUMJJKLMOWdks08/////////////60upkgdaYVTSRQPOOOMPXfljcUPQRSTUVWdks08//////////////60vqmjgfdbaYXXWWVUUXfljcXXYYabbcdfks08///////////////61xtqnkjiggffdddcccfljdffggggijklpv29////////////////840xusqpnnlkkkjjjjjnmkkllnooprstv06///////////////////7420ywvutsssrrrrrttssttvvwxyz126//////////////////////9764321000zzzzz0000112345678+////////////////////////////9988766666788899+/////////////////////////////////////////////////////////////////////" },
    ["-"] = { 32, 30, -5.00, 14.17, 21.98, "//////////////////////////////////////86666666666666666679///////////61zzzzzzzzzzzzzzzzzz26/////////70urrrrrrrrrrrrrrrrrrv17////////4xpjjjjjjjjjjjjjjjjjkqx4////////4wogccccccccccccccccgow4////////4wogaUUUUUUUUUUUUUUagow4////////4wogaSMMMMMMMMMMMMSagow4////////4wogaSKFFFFFFFFFFKSagow4////////4wogaSKCAAAAAAAACKSagow4////////4wogaSKHHHHHHHHHHKSagow4////////4wogaSPPPPPPPPPPPPSagow4////////4wogaXXXXXXXXXXXXXXagow4////////4wogffffffffffffffffgow4////////5xrmllllllllllllllllmsy5////////82wtttttttttttttttttux39/////////7311111111111111111148////////////999999999999999999///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
    ["."] = { 29, 19, -5.00, 25.50, 19.14, "////////////////////////////////////866666666666668/////////////61zzzzzzzzzzzzz16///////////70urrrrrrrrrrrrru06//////////4xpjjjjjjjjjjjjjpw3//////////4wogcccccccccccgnv2+/////////4wogaUUUUUUUUUYgnv2+/////////4wogaSMMMMMMMQYgnv2+/////////4wogaSKFFFFFJQYgnv2+/////////4wogaSKCAAABJQYgnv2+/////////4wogaSKCBBBBJQYgnv2+/////////4wogaSKJJJJJJQYgnv2+/////////4wogaSQQQQQQQQYgnv2+/////////4wogaYYYYYYYYYYgnv2+/////////4wogggggggggggggnv2+/////////5ysnnnnnnnnnnnnnrx4//////////93yvvvvvvvvvvvvvx28///////////94322222222222248//////////////+++++++++++++////////" },
    ["'"] = { 27, 50, -5.00, -5.00, 17.40, "//////////////////////////////////+888888888889/////////////730000000000015+//////////92wsssssssssssuz5//////////6yrlkkkkkkkkkkou2+/////////5xpidddddddddflt19/////////5xpibWWWWWWWXflt19/////////5xpibTOOOOOPXflt19/////////5xpibTLGGGJQYglt19/////////5xpicUMFABJRYgnv2+/////////6zrjcUMFACKSagnv3//////////6zrjdWOGADLSagow4//////////80skdWOHADLTbipx4//////////80slfXPHAEMUbipx5//////////91tlfYQIAFMUcjry6//////////+2unfYQJBGOVdjrz6//////////+2vnfZSKCGOWdks07///////////4wogaSKKKPXfks08///////////4wogbTSSSSXflt19///////////5xpibaaaaaagmu19///////////5xqiggggggggnv3+///////////70tpoooooooosy4/////////////5zwwwwwwwwwy39/////////////+644444444459/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
    ["!"] = { 31, 50, -5.00, -5.00, 21.05, "///////////////////////////////////////9888888888888889//////////////620000000000000026////////////71vssssssssssssssv06///////////4xqkkkkkkkkkkkkkkpw3///////////4wogddddddddddddgnv2+//////////4wogaWWWWWWWWWWYgnv2+//////////4wogbTOOOOOOOOQYgnv2+//////////5xpibTLGGGGGGKSZgnv2+//////////5xpicUMFAAAACKSagow4///////////6zrjcUMFAAAADLTbiow4///////////6zrjdVOGAAAAELTbipx5///////////70skdWOHAAAAFMUciqx5///////////80slfXPHAAAAFNUcjrz6///////////91tlfXQIAAAAGOWdkrz7///////////92unfYQJBAAAHPWdks08///////////+2vnfYRJCAAAHPXflt18////////////3vogaSKCAABJQYglt19////////////4wogbTLDAACJRYgnv2+////////////5xpibTLEAACKSagov3/////////////5xqicUMFAADLTbgow4/////////////6zrjcVNFAAELTbipx5/////////////7zskdWOGAAFMUciqx5/////////////80skdXPHAAFNVcjrz6/////////////91tlfXPHAAGOWdksz7/////////////91tmfYQJBAHPWdks08/////////////+2vnfYRJCAHPXflt18//////////////3vogaSKHHJQYglt19//////////////4wogbTPPPPRYgnv2+//////////////5xpibXXXXXXagnv3///////////////5xqiffffffffgow4///////////////70tnllllllllmrx5///////////////74yutttttttttw26//////////////61wvvvvvvvvvvvvw06////////////92vqnnnnnnnnnnnnpu18///////////80skffffffffffffjrz6///////////80skdYYYYYYYYYYcjrz6///////////80skdWQQQQQQQQUcjrz6///////////80skdWOJJJJJJMUcjrz6///////////80skdWOGBBBBFMUcjrz6///////////80skdWOGAAAAFMUcjrz6///////////80skdWOGFFFFFMUcjrz6///////////80skdWOMMMMMMMUcjrz6///////////80skdWUUUUUUUUUcjrz6///////////80skdcccccccccccjrz6///////////80tmjjjjjjjjjjjjlsz7///////////+3xsrrrrrrrrrrrrsw29////////////83zzzzzzzzzzzzzz27//////////////+766666666666679//////////////////////////////////////" },
    ["?"] = { 40, 50, -5.00, -5.50, 30.22, "////////////////////////////////////////////////////+999888988889/////////////////////98654322111002000113469///////////////9420zxwwvutttssvssstuvxz26+////////////+4yusrpoonnlllkkqkkklmnpsvz38///////////70tnkjiigfffffdgogddffgikosx27//////////6zrjfdcbaZYXXXagogaWXYacfimrw39/////////6zrjcWUTSRQQPSagogaSPRTVYcglsy4/////////6zrjcUMLKKJIKSagogaSKJLORWcgnt07////////6zrjcUMFCCBCKSagogaSKCEHLRXdjqx4////////6zrjcUMFDDFFKSagogaSKCAAFMTagnu29///////6zrjcUMKLLMMMSagogaSKCAABIQXfksz7///////6zrjcUSSTTUUUUagogaSKCAAAGNVcjqy6///////6zrjcYaabbcccccgogaSKCAAAEMTbipx5///////6zrjfgggiiijjjjjogaSKCAAADLTbgow4///////70tnlmnoopprrrrrogaSKCAAACKSagow4///////+4yutuvwwxxzzzzwogaSKCAAACKSagow4////////94211244556530wogaSKCAAADLTbgow4//////////999+//941yvtqmfaSKCAAAEMTbipx5///////////////83yuqoljgdWPIBAAAFNVcjqy5//////////////93xsnjgfdbWSMFAAABIPXdksz7//////////////5ysmgdbYWTQMGBABEHMSZgmu19/////////////92ungcXTROMJFBDGILOSXdipw4//////////////6zskfYRMJHFCFILNQSVYdgnt07//////////////5xpicVNGCAAFLPSVXacfimsy4+//////////////4wogbTLDAAELRWZcfgikotx39///////////////4wogaSKCAAHOWcgiknpsvz38////////////////4wogaSKDDDJQYglpsuxz26+/////////////////4wogaSLLLLLQYgnvz2469///////////////////4wogaTTTTTTTYgnv29//////////////////////4wogbbbbbbbbbgnv2+//////////////////////4wpiiiiiiiiiiinv3///////////////////////6ztqppppppppppty5///////////////////////62zxxxxxxxxxxxz16//////////////////////71vrrrrrrrrrrrrru06/////////////////////4xqkjjjjjjjjjjjjpw3/////////////////////4wogcccccccccccgnv2+////////////////////4wogaUUUUUUUUUYgnv2+////////////////////4wogaSMMMMMMMQYgnv2+////////////////////4wogaSKFFFFFJQYgnv2+////////////////////4wogaSKCAAABJQYgnv2+////////////////////4wogaSKCBBBBJQYgnv2+////////////////////4wogaSKJJJJJJQYgnv2+////////////////////4wogaSQQQQQQQQYgnv2+////////////////////4wogaYYYYYYYYYYgnv2+////////////////////4wogggggggggggggnv2+////////////////////5ysnnnnnnnnnnnnnrx4/////////////////////93yvvvvvvvvvvvvvx28//////////////////////94322222222222248/////////////////////////+++++++++++++////////////////" },
    ["/"] = { 36, 56, -5.67, -8.17, 24.88, "////////////////////////////////////////////////////////9766666666679//////////////////////62zzzzzzzzzzz26////////////////////81vrrrrrrrrrrrv18///////////////////5xqkjjjjjjjjjkqy6//////////////////92vngccccccccciqx5//////////////////7zskfYUUUUUUYfksz7//////////////////4xqicVOMMMMTbgnv29/////////////////92unfaTLFFHOWdjqx5//////////////////6zskfXQIBCKRYglt07//////////////////4wpicVNGAFMUbiov3+/////////////////81tmfZSKDAIPWdjry6//////////////////6yrjdWPIADKSZgmt18/////////////////+3voibUMFAGNVcipw4//////////////////70tlfYRKCBJQXfksz6//////////////////5xqjdWOHAELTagnu29/////////////////92vngbTMFAHOVciqx4//////////////////7zskfYRJCCJRYflsz7//////////////////4xqicVOHAFMTbgnv2+/////////////////92unfaTLEAHOWdjqx5//////////////////6zskfXQIBCKRZglt08//////////////////4wpicVNGAFMUbiow3+/////////////////81tmfZSKDAIPXdjry6//////////////////6yrjdWPIADLSZgmu18/////////////////+3voibUMFAGNVcipw4//////////////////70tlfYRKCBJQXfksz6//////////////////5xqjdWOHAELTagnu29/////////////////92vngbTMFAHOVciqx4//////////////////7zskfYRJCCJRYflsz7//////////////////4xqicVOHAFMTbgnv2+/////////////////92unfaTLEAHPWdjqy5//////////////////6zskfXQIBCKRZgmt08//////////////////4wpicVNGAFNUbiow3+/////////////////81tmfZSKDBIPXdkry6//////////////////6yrjdWPIADLSZgmu19/////////////////+3voibUMFAGNVcipw4//////////////////70tlfYRKCBJQYfksz6//////////////////5xqjdWOHAELTagnu29/////////////////92vngbTMFAHOVdiqx4//////////////////7zskfYRJCCJRYfls07//////////////////4xqicVOHAFMTbgnv2+/////////////////92unfaTLEAHPWdjqy5//////////////////6zskfXQIBCKRZgmt08//////////////////4wpicVNGAFNUbiow3+/////////////////81tmfZSKDBIPXdkry6//////////////////6yrjdWPIADLSagmu19/////////////////+3voibUMFAGOVcipx4//////////////////70tlfYRKCCJQYfksz6//////////////////5xqjdWOKKKMTagnu29/////////////////92vngbTSSSSSVdjqx4//////////////////7zskfaaaaaaaafls07//////////////////6zrjgggggggggiov2+//////////////////81upooooooooootz6////////////////////60xwwwwwwwwwwz4+/////////////////////7444444444446+///////////////////////////////////////////////////////" },
    ["+"] = { 41, 36, -5.00, 8.67, 31.32, "////////////////////////////////////////////////////////97666666668/////////////////////////////62zzzzzzzzz05+//////////////////////////81vrrrrrrrrruz6//////////////////////////6yqkjjjjjjjjov3//////////////////////////5xpicccccccgnv2+/////////////////////////5xpibUUUUUYgnv2+/////////////////////////5xpibTMMMQYgnv2+/////////////////////////5xpibTLFJQYgnv2+///////////////////8655555xpibTLDJQYgnv2555557/////////////61yxxxxxxpibTLDJQYgnvxxxxxx05+//////////92vqpppppppibTLDJQYgnppppppqtz6//////////7zrkiiiiiiiibTLDJQYgiiiiiiiipw4//////////6zrjcbbbbbbbXRKCHPVbbbbbbbbgow4//////////6zrjcUTTTTTTRMGAEKQTTTTTTTagow4//////////6zrjcUMLLLLLKGBAAFJLLLLLLSagow4//////////6zrjcUMFDDDDCAAAAACDDDDDKSagow4//////////6zrjcUMJJJJJHEAAADHJJJJJKSagow4//////////6zrjcUQQQQQQPKFADJOQQQQQQSagow4//////////6zrjcYYYYYYYVQJCHOUYYYYYYYagow4//////////6zrjggggggggbTLDJQYgggggggggow4//////////80uonnnnnnnibTLDJQYgnnnnnnnnsy5///////////5zvvvvvvvpibTLDJQYgnvvvvvvvy39///////////+6322222xpibTLDJQYgnv22222349///////////////++++5xpibTLDJQYgnv2+++++/////////////////////5xpibTLKKQYgnv2+/////////////////////////5xpibTSSSSYgnv2+/////////////////////////5xpibaaaaaagnv2+/////////////////////////5xqiggggggggnv3+/////////////////////////70tpoooooooosy4///////////////////////////5zwwwwwwwwwy39///////////////////////////+644444444459//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
  },
  label = { space = 11.40,
    A = { 41, 50, -5.00, -5.00, 31.46, "////////////////////////////////////////////////////////+8888888889/////////////////////////////8300000000026///////////////////////////93xtssssssssv06//////////////////////////5ysmkkkkkkkkpv29/////////////////////////3vogdddddddfksz7////////////////////////91tmfYWWWWWWcjqy5////////////////////////6zrkdXPOOOOTbgov3////////////////////////4xpicUNGGGJRYgmt19//////////////////////+2vngaTLDAAHPXdkrz6//////////////////////80tlfYRJGHGFNUcipx4//////////////////////6yrjdWOINPOJLTagnv2+/////////////////////4wpibUMNTXUPJRYflt08////////////////////92unfaSKRYfaTLOWdjry6////////////////////70skfYQLTbgcVNMUbipw4////////////////////6yqjdVONVcidXPKSagnu29///////////////////3woibTMPXdkfYRJQYfks07//////////////////91umfZRKRYglgbTLOVdjqy5//////////////////7zskfXPLTagnicVNMTbgow3//////////////////5xqicVNNUcipkdXPKRZgmu19////////////////+3vogbTLPWdkrmfYRJPXfksz7////////////////81tlfYRJRYgltogbTLNVciqx5////////////////6zrkdWPLTagnvqicVNLTbgov3+///////////////4xpicUNMUcipxskdXPJRYflt18//////////////+2vngaSLOWdjrztmfYRJPWdkrz6//////////////80slfYQJQYflt0vogbTLNUcipx4//////////////6yrjdWOLSagnv2xqicVNLSagnv2+/////////////4woibUMMUcipx4zskdXPJQYfls08////////////92unfZSKOWdjrz61tmfYRJOWdjry6////////////7zskfXQJQYflt053vogbTLMUbiow4////////////5yqjcVOKSagnvxxxxqicVNKSZgnu29///////////3vogbTMMUbipppppppkdXPIQXfksz7//////////91tmfYRJOWdiiiiiiiiifYQJOVcjqy5//////////6zskdXPHNUabbbbbbbbbbWPIMTbgov3//////////4xpicVNFJPTTTTTTTTTTTQLFJRYgmt19////////+3vngaTLFJLLLLLLLLLLLLLKHHPXdksz6////////80tlfYRJLQTTTTTTTTTTTTTSNHNVcipx4////////6zrjdWOIPWbbbbbbbbbbbbbYSKLTagnv3+///////4wpicUMKRZgiiiiiiiiiiiicUMJRYflt08//////+2unfaSKMTbgoppppppppppjdWOHOWdjrz6//////70slfYQINVcjqxxxxxxxxxtlfYQIMUcipw4//////6yqjdVOHPXdksz55555552vngaSKKSagnu2+/////3woibTMMRYgmt19//////4wpibUMMQYfls07////91umfZUUUUagov3///////6yrjdWUUUVdjqy6////91tlfcccccdipx4///////80slfccccccipx5////+2uojjjjjjjntz6///////+2vpjjjjjjjlry6/////5zurrrrrrrty4+////////60urrrrrrrsw29/////+50zzzzzzz049//////////61zzzzzzzz27////////866666667+////////////8666666679/////////////////////////////////////////////" },
    B = { 40, 50, -5.00, -5.00, 30.89, "///////////////////////////////////////////////+88888888888888889/////////////////////7300000000000000001347+////////////////92wsssssssssssssssstvxz36+//////////////5yrlkkkkkkkkkkkkkkkmnqsvz37/////////////4wogddddddddddddddffgilosw27////////////4wogaWWWWWWWWWWWWWXYacfimrw27///////////4wogaSOOOOOOOOOOOOPRTVYcglrw29//////////4wogaSKGIMOOOOOOONMJLOSWbglry4//////////4wogaSKHOTWWWWWWWVTRNILQVbgnu18/////////4wogaSKKRZdddddddcbYTOIKQXdjqx5/////////4wogaSKKSagkkkkkkjgdZTNHMTbgnv3+////////4wogaSKKSagosssssqnjfYSLJRYflt18////////4wogaSKKSagow000zyuoicVOHPWdks07////////4wogaSKKSagow48875zskfXQIOVdjrz6////////4wogaSKKSagow4///92unfYQJMUcjrz6////////4wogaSKKSagow4///+2vnfYQJMUcjrz6////////4wogaSKKSagow4///91umfYQJOWdjrz6////////4wogaSKKSagow46653yskfXPIQXfks08////////4wogaSKKSagowzzzywtnicVNLSagnu29////////4wogaSKKSagorrrrqpmidYRKPWdipx4/////////4wogaSKKSagjjjjjjifdYSNPUagmt07/////////4wogaSKJRYcccccccbZWSNRVagkqw3+/////////4wogaSKHNSUUUUUUUTSPLRXcgkqv17//////////4wogaSKCHLMMMMMMMMKILTbgkptz5+//////////4wogaSKGMRTTTTTTTTSPLQWbfiotz6//////////4wogaSKJRXbbbbbbbbZWSNQUZdipv28/////////4wogaSKKSagiiiiiiigdYSNOSZfkrx4/////////4wogaSKKSagopppppomidYSLOUbgnu29////////4wogaSKKSagowxxxxwtoidWOJQYfksz7////////4wogaSKKSagow45553ztlfYRJNVciqx5////////4wogaSKKSagow4///+3vogbTLLTbgow4////////4wogaSKKSagow4////5xpibTLKSagnv2+///////4wogaSKKSagow4////5xpibTLJQYgnv2+///////4wogaSKKSagow4////4wpibTLJQYgnv2+///////4wogaSKKSagow488861unfaSKKSZgnv2+///////4wogaSKKSagow0000zvqjdXQILTagow4////////4wogaSKKSagosssssrpkfaTMGNVcipx4////////4wogaSKKSagkkkkkkkifbVPJJQXfksz6////////4wogaSKKRZddddddddcZUQKIOUbgnu29////////4wogaSKHOTWWWWWWWWUSOJJOSZfkrx4/////////4wogaSKFIMOOOOOOOONKJMQUZdipv28/////////4wogaSMMMMMMMMMMMNOPRTXbfiotz6//////////4wogaUUUUUUUUUUUUUWXYbdgkptz5+//////////4wogccccccccccccccdfggjnqv05+///////////5xrljjjjjjjjjjjjjjkkmoqux16/////////////82wsrrrrrrrrrrrrrrrstvy148///////////////72zzzzzzzzzzzzzzzz01358//////////////////9766666666666666789//////////////////////////////////////////////////////" },
    C = { 40, 51, -5.00, -5.50, 30.38, "////////////////////////////////////////////////////////+9888889/////////////////////////////96421000001357+///////////////////////952zxvtssssstvx036+////////////////////62yuspnlkkkklmnqswz37/////////////////+50vsnkifffdddffgilptw26////////////////5zupkgfcaYXWWWXYbdfimrv16//////////////60uojfcYVSQPOOOPRTVZdgkqv17////////////71upjfZVRNLLMOOOMKLOSWbfkqw39//////////+3wqjfZTOKLPSUWWVUROJLQUaglsy5//////////70tmfaTOIMSWacdddbYUQKJPVcinu29/////////4xpidWPJMSXdgijkjifbVQJLRYfksz6////////92unfaSLJQXdimprsrokgbUOHNVcipw4////////7zskfXQINUbgntxz0yvrkfYRKKSZgnu29///////6yrjcVNIPXdkry36762voibUMIQXflt08///////5xpibUMJQYgmu19///6yrjdWOMOWdks08///////5xpibTLKSagnv2+///80skdWTUUWdks08///////5xpibTLKSagow4////80skdbbcccdks08///////5xpibTLKSagow4////81tniiiijjjou19///////5xpibTLKSagow4/////4ytpppprrruz5////////5xpibTLKSagow4/////94zxxxxzzz05+////////5xpibTLKSagow4//////+655556668//////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4//////////////////////////5xpibTLKSagow4///////866667889//////////5xpibTLKSagow4/////+50zzzz00026/////////5xpibTLKSagow4/////5zurrrrsssv06////////5xpibTLKSagow4////91uojjjjkkkpv29///////5xpibTLKSagow4////80skdccdddfks08///////5xpibTLKSagnv3+///80skdWUVWWdks08///////5xpibUMJQYgnu29///6zrjdWOOOWdks08///////6yrjcVNIQXfksy47862wpicUMIQXflt08///////7zskfXQINVcintx00zwslfZSKKSZgnu29///////92ungaSLKRYdinqssrplgcVOHNUcipw4/////////4xpidWPJNSYdgjkkkifcWRKKRYfkrz6/////////70tmgaTNINSXbddfdcZVRLJPVcgnu29/////////+3wqjfYTOJMQTVWXWUSPKLPUaglsy5///////////71uoidZUQNKMOOPONLLORVagkqw29////////////6ztojfbXURPONMOOQSVYcgkqv17/////////////+5zupkgdbZXWVUWWYacfilqv16///////////////+50vrnkigfdccddfgikosw16//////////////////62yuromkkjjjklnpsvz37////////////////////941ywussrrrstuxz269///////////////////////96310zzzz002469////////////////////////////98766688+///////////////////////////////////////////////////////" },
    D = { 41, 50, -5.00, -5.00, 31.07, "////////////////////////////////////////////////+88888888888888889+/////////////////////7300000000000000001357+/////////////////92wsssssssssssssssstvx037+///////////////5yrlkkkkkkkkkkkkkkklnqtw049//////////////4wogddddddddddddddffgjmpty38/////////////4wogaWWWWWWWWWWWWWXYbdfinsx38////////////4wogaSOOOOOOOOOOOOPRTWZdgmsx39///////////4wogaSKGIMOOOOOOOOMJMPSXcgmsy4///////////4wogaSKHOTWWWWWWWVTRNIMRWcgnu07//////////4wogaSKKRZddddddddbYTOILRXdjqx4//////////4wogaSKKSagkkkkkkjgdZTNHMTagnu29/////////4wogaSKKSagosssssqnjfYRLJQXfksz7/////////4wogaSKKSagow0000yuoicVOGNVcjqy5/////////4wogaSKKSagow48875zskfYQIMTbipw4/////////4wogaSKKSagow4///92ungaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4///92unfZSKKSagow4/////////4wogaSKKSagow49885zskfXQILTbipw4/////////4wogaSKKSagow1100yuoicVOGNVciqx5/////////4wogaSKKSagotttssrnjdYRKIPXdksz7/////////4wogaSKKSagllllkkjgdZTNHMTagmu19/////////4wogaSKKSZffffffddbYTOIKRXdjqx4//////////4wogaSKIPUXXXXXXWWURNILQVcgnt07//////////4wogaSKFJOPPPPPPOOMJLOSWbglsy4///////////4wogaSMMMMMMMMMMMNOQSVYdglrw29///////////4wogaUUUUUUUUUUUUVWYacfimrw27////////////4wogccccccccccccccdfgikotx27/////////////5xrljjjjjjjjjjjjjjklnpsvz38//////////////82wsrrrrrrrrrrrrrrssuxz26+////////////////72zzzzzzzzzzzzzzzz02469///////////////////976666666666666678+////////////////////////////////////////////////////////" },
    E = { 39, 50, -5.00, -5.00, 29.24, "//////////////////////////////////////////////+8888888888888888888888888////////////73000000000000000000000000149/////////92wssssssssssssssssssssssssty4+////////5yrlkkkkkkkkkkkkkkkkkkkkkkknt07////////4wogdddddddddddddddddddddddjrz6////////4wogaWWWWWWWWWWWWWWWWWWWWWcjrz6////////4wogaSOOOOOOOOOOOOOOOOOOOUcjrz6////////4wogaSKGIMOOOOOOOOOOOOOOOUcjrz6////////4wogaSKHOTWWWWWWWWWWWWWWWWcjrz6////////4wogaSKKRZdddddddddddddddddjrz6////////4wogaSKKSagkkkkkkkkkkkkkkkkou08////////4wogaSKKSagosssssssssssssssuz5/////////4wogaSKKSagow0000000000000015+/////////4wogaSKKSagow488888888888889///////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow488888888+////////////////4wogaSKKSagow00000000037///////////////4wogaSKKSagossssssssssw28//////////////4wogaSKKSagkkkkkkkkkklrx5//////////////4wogaSKJRYdddddddddddgow4//////////////4wogaSKHNSWWWWWWWWWWagow4//////////////4wogaSKCHMOOOOOOOOOSagow4//////////////4wogaSKDIMOOOOOOOOOSagow4//////////////4wogaSKHOTWWWWWWWWWWagow4//////////////4wogaSKKRZdddddddddddgow4//////////////4wogaSKKSagkkkkkkkkkkmsy5//////////////4wogaSKKSagossssssssstx39//////////////4wogaSKKSagow00000000148///////////////4wogaSKKSagow488888888/////////////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow4/////////////////////////4wogaSKKSagow49999999999999+///////////4wogaSKKSagow1111111111111125+/////////4wogaSKKSagotttttttttttttttuz5/////////4wogaSKKSagllllllllllllllllou08////////4wogaSKKSZfffffffffffffffffjrz6////////4wogaSKIPUXXXXXXXXXXXXXXXXcjrz6////////4wogaSKFJOPPPPPPPPPPPPPPPUcjrz6////////4wogaSMMMMMMMMMMMMMMMMMMMUcjrz6////////4wogaUUUUUUUUUUUUUUUUUUUUUcjrz6////////4wogccccccccccccccccccccccdjrz6////////5xrljjjjjjjjjjjjjjjjjjjjjjjnt07////////82wsrrrrrrrrrrrrrrrrrrrrrrrty4+/////////72zzzzzzzzzzzzzzzzzzzzzzzz049///////////97666666666666666666666667+////////////////////////////////////////////" },
    F = { 37, 50, -5.00, -5.00, 27.87, "////////////////////////////////////////////+8888888888888888888888888//////////73000000000000000000000000149///////92wssssssssssssssssssssssssty4///////5yrlkkkkkkkkkkkkkkkkkkkkkkknt08//////4wogdddddddddddddddddddddddjrz6//////4wogaWWWWWWWWWWWWWWWWWWWWWcjrz6//////4wogaSOOOOOOOOOOOOOOOOOOOUcjrz6//////4wogaSKGIMOOOOOOOOOOOOOOOUcjrz6//////4wogaSKHOTWWWWWWWWWWWWWWWWcjrz6//////4wogaSKKRZdddddddddddddddddjrz6//////4wogaSKKSagkkkkkkkkkkkkkkkkou08//////4wogaSKKSagosssssssssssssssuz5///////4wogaSKKSagow0000000000000015+///////4wogaSKKSagow488888888888889/////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow488888888+//////////////4wogaSKKSagow00000000037/////////////4wogaSKKSagossssssssssw28////////////4wogaSKKSagkkkkkkkkkklrx5////////////4wogaSKJRYdddddddddddgow4////////////4wogaSKHNSWWWWWWWWWWagow4////////////4wogaSKCHMOOOOOOOOOSagow4////////////4wogaSKDIMOOOOOOOOOSagow4////////////4wogaSKHOTWWWWWWWWWWagow4////////////4wogaSKKRZdddddddddddgow4////////////4wogaSKKSagkkkkkkkkkkmsy5////////////4wogaSKKSagossssssssstx39////////////4wogaSKKSagow00000000148/////////////4wogaSKKSagow488888888///////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSKKSagow4///////////////////////4wogaSMMSagow4///////////////////////4wogaUUUUagow4///////////////////////4wogcccccciow4///////////////////////5xrljjjjjjlry6///////////////////////82wsrrrrrrsw29////////////////////////72zzzzzzzz37//////////////////////////976666667+/////////////////////////////////////////////////////////" },
    G = { 40, 51, -5.00, -5.50, 30.61, "////////////////////////////////////////////////////////+9888889/////////////////////////////96421000001357+///////////////////////952zwvtssssstvx036+////////////////////62yuspnlkkkklmoqtwz38/////////////////+50vrnkiffddddffgjlptx26////////////////5zupkgfcaYXWWWXYbdfimrv16//////////////60tojfbYVSQPOOOPRTWZdgkqv27////////////71upifZVRNKLMOOOMKMOSWbfkrw3+//////////+3wqjfZTOKLPSUWWVUROKLQVbgmsz6//////////70tmfaTOIMSWacdddbYVQKKQWciov29/////////4xpidWPJMSXdgijkjifbVQKLRYfksz6////////92unfaSLJQXdimprsrokgbVOHOVcipw4////////7zskfXQINUbgntwz0yvrkfZSKLSagnu2+///////6yrjcVNHPXdkry36762vpicUMIQYflt19///////5xpibUMJQYgmt19///6zrjdWOHPXdks08///////5xpibTLKSZgnv2+///80skdWPPPWdks08///////5xpibTLKSagow4////80skdXXXXXdks08///////5xpibTLKSagow4////80slgfffffgks08///////5xpibTLKSagow4////+3wqmllllllqv29///////5xpibTLKSagow4/+99971wtttttttw16////////5xpibTLKSagow462111111111111137/////////5xpibTLKSagow40vtttttttttttttw16////////5xpibTLKSagow2vplllllllllllllqv29///////5xpibTLKSagowzrkfffffffffffffks08///////5xpibTLKSagowzrjcXXXXXXXXXXXdks08///////5xpibTLKSagowzrjcUPPPPPPPPPWdks08///////5xpibTLKSagowzrjcUOOOONLHHOWdks08///////5xpibTLKSagowzrjcWWWWWVRLGOWdks08///////5xpibTLKSagowzrjfdddddcVNGOWdks08///////5xpibTLKSagow1uokkkkkkdWOGOWdks08///////5xpibTLKSagow4zussssskdWOGOWdks08///////5xpibTLKSagow4520000skdWOGOWdks08///////5xpibTLKSagow4/98880skdWOGOWdks08///////5xpibTLKSagnv2+///80skdWOGOWdks08///////5xpibTMJQYgmu19///7zskdWOHPXfks08///////6yqjcVNIPXdkry47873xqicVNIQYflt19///////7zskdXPINUbgntxz0zxsmfaTLLSagnv2+///////91umfZSLJRXdimqsssqmicWPIOVcipx4/////////4wpicWPIMSXdgikkkifcXRLKRYfksz6/////////6zsmfaTNHMSWacdfdcaWRMJPVcinu29/////////+3wqjdYSOJMPTVWXWVTPLLPUaglsy5///////////70uoidZUQMKLNOPONLKORVagkqw29////////////5ztoifbXURPONMOOQSVYcgkqv17/////////////+5ztpkgdbZXWVUWWYacfilqv16///////////////+5zvqnjigfdccddfgikosw16/////////////////+61xuromkkjjjklnpsvz37////////////////////841ywussrrrstuwz269///////////////////////86310zzzz002469////////////////////////////98766688+///////////////////////////////////////////////////////" },
    H = { 41, 50, -5.00, -5.00, 31.75, "////////////////////////////////////////////////+88888888+////////+88888888+////////////730000000038//////830000000038//////////92wssssssstx39////93xtsssssstx39/////////5yrlkkkkkkmsz6////5ysmkkkkkkmsz6/////////4wogddddddiow4////4wogddddddiow4/////////4wogaWWWWagow4////4wogaWWWWagow4/////////4wogaSOOSagow4////4wogaSOOSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow488884wogaSKKSagow4/////////4wogaSKKSagow000000wogaSKKSagow4/////////4wogaSKKSagossssssssogaSKKSagow4/////////4wogaSKKSagkkkkkkkkkkgaSKKSagow4/////////4wogaSKJRYddddddddddddYRJKSagow4/////////4wogaSKHNSWWWWWWWWWWWVSNHKSagow4/////////4wogaSKCHMOOOOOOOOOOOOLHCKSagow4/////////4wogaSKDIMOOOOOOOOOOOOMHCKSagow4/////////4wogaSKHOTWWWWWWWWWWWWSNHKSagow4/////////4wogaSKKRZddddddddddddYRJKSagow4/////////4wogaSKKSagkkkkkkkkkkgaSKKSagow4/////////4wogaSKKSagossssssssogaSKKSagow4/////////4wogaSKKSagow000000wogaSKKSagow4/////////4wogaSKKSagow488884wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSKKSagow4////4wogaSKKSagow4/////////4wogaSMMSagow4////4wogaSMMSagow4/////////4wogaUUUUagow4////4wogaUUUUagow4/////////4wogcccccciow4////4wogccccccgow4/////////5xrljjjjjjlry6////5xrljjjjjjlry5/////////82wsrrrrrrsw29////82wsrrrrrrsw29//////////72zzzzzzzz37//////72zzzzzzzz37////////////976666667+////////976666667+///////////////////////////////////////////////" },
    I = { 23, 50, -5.00, -5.00, 13.85, "//////////////////////////////+88888888+////////////730000000038//////////92wssssssstx39/////////5yrlkkkkkkmsz6/////////4wogddddddiow4/////////4wogaWWWWagow4/////////4wogaSOOSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSKKSagow4/////////4wogaSMMSagow4/////////4wogaUUUUagow4/////////4wogcccccciow4/////////5xrljjjjjjlry6/////////82wsrrrrrrsw29//////////72zzzzzzzz37////////////976666667+/////////////////////////////" },
    J = { 39, 50, -5.00, -5.00, 29.18, "//////////////////////////////////////////////////////////////888888889////////////////////////////941000000026///////////////////////////4ytsssssssv17/////////////////////////80tnkkkkkkkqw4/////////////////////////6zrjddddddgnv2+////////////////////////6zrjcWWWWYgnv2+////////////////////////6zrjcUOOQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+////////////////////////6zrjcUMJQYgnv2+/////////+9999999///////6zrjcUMJQYgnv2+////////73111111137/////6zrjcUMJQYgnv2+///////61wtttttttw17////6zrjcUMJQYgnv2+//////92vqllllllmqw3+///6zrjcUMJQYgnv2+//////80skffffffflt08///6zrjcUMJQYgnv2+//////80skdXXXXXdks08///6zrjcUMJQYgnv2+//////80skdWPPPWdks08///6zrjcUMJQYgnv2+//////80skdWOHOWdks08///6zrjcUMJQYgnv2+//////80skdWOGOWdks08///6zrjcUMJQYgnv2+//////80skdWOGOWdks08///6yqjcUMJQYgnv2+//////80skdWPHOWdjry6//+3wpibTMKRZgnv2+//////81tlfYQIMUbiov0342ztmfZSKLTagow3///////+2ungaSLKRYfkqtwwvsoidWPINVcipx4////////4xpicVOHNUafjmoonlidYSLJRYfksz6////////6zskfYSLJPUadfgggfcYSNHOUbgnu29////////92voidWQLJPTWZabaYVRNINSZfkry5//////////6ztmgbWRMJMPRSTSROLLPTYdipv29//////////+3xrlgcXTQNLKKLKLMPSVZdiotz6////////////82wrmgdbXVTSRQSTUWZcgjotz5+/////////////72wsnjgfcbaZYaacdgilpuz5+///////////////73yuqnkiigggggijmpsw05+/////////////////941xusqoonnnoprtwz37/////////////////////842zxwwvvvwxz036+////////////////////////975432234468+///////////////////////////////+++///////////////////" },
    K = { 41, 50, -5.00, -5.00, 31.29, "////////////////////////////////////////////////+88888888+/////////9888888889///////////730000000038///////620000000026/////////92wssssssstx39/////60vssssssssv17////////5yrlkkkkkkmsz6////82vpkkkkkkkkqx4////////4wogddddddiow4///+3xrkfddddddgnv2+///////4wogaWWWWagow4///5ztmfbWWWWXdipw4////////4wogaSOOSagow4//71uoidWQOOVbgnt07////////4wogaSKKSagow4/93wqjfYSLMTZgkry4/////////4wogaSKKSagow4/5yslfaTNKRXdjpv29/////////4wogaSKKSagow470unicVPJPVcgnu06//////////4wogaSKKSagow42wpjdYRLMTZglsy4///////////4wogaSKKSagow4yslfZTNKRXdjpw29///////////4wogaSKKSagow0tngcVPIPVcgnu07////////////4wogaSKKSagowvpidXRKMTZglsy4/////////////4wogaSKKSagowrkfZSMKRXdjpw29/////////////4wogaSKKSagotmgbUOIPVcgnu07//////////////4wogaSKKSagooidWQJNTZglsy4///////////////4wogaSKKSagokfYSLLRYdjpw29///////////////4wogaSKKSagmfaUNIPVcinu07////////////////4wogaSKKSagicWPJNTaglsy5/////////////////4wogaSKKSagdYRLIQYdjqw39/////////////////4wogaSKKSafaTNGJQYflsz6//////////////////4wogaSKIPVYUPICHOVciov29/////////////////4wogaSKEKPQOJKJHLRYfksz6/////////////////4wogaSKCEHJJPSRNHOVciov29////////////////4wogaSKCACIPUZYSLKRYfkry5////////////////4wogaSKCAHNTagdWPINUbgnu18///////////////4wogaSKCFLSYfjfZSLJRYfkqx4///////////////4wogaSKDJQWdioidWPINUbgnu18//////////////4wogaSKHOUbgmtmgaTMJQXdjqx4//////////////4wogaSKKRZgkrxqjdWPJMTbgmt07/////////////4wogaSKKSagov0tmgaTMJQWdjqx4/////////////4wogaSKKSagow4xqjdXQJMTagmt07////////////4wogaSKKSagow41ungbTNIPWdipw3+///////////4wogaSKKSagow44xqjfYRJMSZgmt07///////////4wogaSKKSagow481ungbUNIPWdipw3+//////////4wogaSKKSagow4/5yrkfYRKLSZflsz6//////////4wogaSKKSagow4/92unicVOIPVcipw39/////////4wogaSKKSagow4//5yskfYRKLSZflsz6/////////4wogaSKKSagow4//92voicVOHOVciov29////////4wogaSKKSagow4///6zslfZSLLRYfksz5////////4wogaSMMSagow4///92wpicVOMOVciou29///////4wogaUUUUagow4////6zslfZUUUUYfkry6///////4wogcccccciow4////+3wpidccccccipx5///////5xrljjjjjjlry6/////60tnjjjjjjjlry6///////82wsrrrrrrsw29/////+4ytrrrrrrrsw29////////72zzzzzzzz37///////940zzzzzzzz27//////////976666667+//////////8666666679/////////////////////////////////////////////" },
    L = { 38, 50, -5.00, -5.00, 28.10, "/////////////////////////////////////////////+88888888+///////////////////////////730000000038/////////////////////////92wssssssstx39////////////////////////5yrlkkkkkkmsz6////////////////////////4wogddddddiow4////////////////////////4wogaWWWWagow4////////////////////////4wogaSOOSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow4////////////////////////4wogaSKKSagow49999999999999+//////////4wogaSKKSagow1111111111111126/////////4wogaSKKSagotttttttttttttttv06////////4wogaSKKSagllllllllllllllllpv29///////4wogaSKKSZfffffffffffffffffks08///////4wogaSKIPUXXXXXXXXXXXXXXXXdks08///////4wogaSKFJOPPPPPPPPPPPPPPPWdks08///////4wogaSMMMMMMMMMMMMMMMMMMOWdks08///////4wogaUUUUUUUUUUUUUUUUUUUUWdks08///////4wogccccccccccccccccccccccdks08///////5xrljjjjjjjjjjjjjjjjjjjjjjjou19///////82wsrrrrrrrrrrrrrrrrrrrrrrruz5/////////72zzzzzzzzzzzzzzzzzzzzzzzz05+//////////97666666666666666666666668///////////////////////////////////////////" },
    M = { 45, 50, -5.00, -5.00, 35.74, "////////////////////////////////////////////////////+88888888+////////////988888888+////////////730000000038//////////620000000038//////////82wssssssstx39////////71vssssssstx39/////////4xrlkkkkkkmsy4///////93wqkkkkkkkmsz6////////+2vnfddddddgnu07//////5yslfddddddipx5////////+2vnfYWWWWXdjqw3+////81unicWWWWWbipx5////////+2vnfYQOOOTagmsz6///+3xqjfYROOOTbipx5////////+2vnfYQJGIPWciov18//6ztmfbTNGGLTbipx5////////+2vnfYQJBELRYfkqx4+92vpidWQJCDLTbipx5////////+2vnfYQJBAHNUbgmt064yrkfZSLFADLTbipx5////////+2vnfYQJBACJQWdipv20ungbVOHBADLTbipx5////////+2vnfYQJBAAFMSZfksywqjdXRKDAADLTbipx5////////+2vnfYQJBADDIOVcgnusmfaTMGFDADLTbipx5////////+2vnfYQJCHKLJKRXdjqoicWPILMLGDLTbipx5////////+2vnfYQJHNSTQLMTaglkfYRLNSURMGLTbipx5////////+2vnfYQJKSYbWQJPVcigbUNLSYcXRJLTbipx5////////+2vnfYQJLTbgbUNLRYfdWQJPWdgaSKLTbipx5////////+2vnfYQJLTbifYRLNTZYSMMTaggaSKLTbipx5////////+2vnfYQJLTbiicVPIORRNKRXdjgaSKLTbipx5////////+2vnfYQJLTbilfZTMHKJHOVbgngaSKLTbipx5////////+2vnfYQJLTbipjdXQJCFLSZfkogaSKLTbipx5////////+2vnfYQJLTbipngbUNHJPWdipogaSKLTbipx5////////+2vnfYQJLTbiprkfYSLNTagmtogaSKLTbipx5////////+2vnfYQJLTbipvoicWPRYdjqwogaSKLTbipx5////////+2vnfYQJLTbipxsmfaTVcgnuwogaSKLTbipx5////////+2vnfYQJLTbipxwqjdXZgksywogaSKLTbipx5////////+2vnfYQJLTbipx0ungffipv2wogaSKLTbipx5////////+2vnfYQJLTbipx4ysnllotz4wogaSKLTbipx5////////+2vnfYQJLTbipx53yuttvz54wogaSKLTbipx5////////+2vnfYQJLTbipx59421126+4wogaSKLTbipx5////////+2vnfYQJLTbipx5//999+//4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQJLTbipx5////////4wogaSKLTbipx5////////+2vnfYQMMTbipx5////////4wogaSMMTbipx5////////+2vnfYUUUUbipx5////////4wogaUUUUbipx5////////+2vngccccccipx5////////4wogccccccipx5/////////4xqkjjjjjjmsz6////////5xrljjjjjjmsz6/////////71vrrrrrrrsx39////////82wsrrrrrrsx39//////////62zzzzzzzz38//////////72zzzzzzzz38////////////976666667+////////////976666667+///////////////////////////////////////////////////" },
    N = { 43, 50, -5.00, -5.00, 33.52, "//////////////////////////////////////////////////+888888889//////////988888889/////////////730000000026////////62000000015+//////////82wssssssssv17//////60vsssssssuz5//////////5xrlkkkkkkkqw3+////+3wpkkkkkkkou18/////////4wogddddddgmt07////91tlfddddddjrz6/////////4wogaWWWWWdipw3////91tlfXWWWWcjrz6/////////4wogaSOOOSZgmt07///91tlfXPOOUcjrz6/////////4wogaSKGIPWdjqx4///91tlfXPHMUcjrz6/////////4wogaSKCFMTagmt07//91tlfXPHMUcjrz6/////////4wogaSKCBIPWdjqx4//91tlfXPHMUcjrz6/////////4wogaSKCAFMTagmt07/91tlfXPHMUcjrz6/////////4wogaSKCABIPWdjqx4/91tlfXPHMUcjrz6/////////4wogaSKCAAFMTagmu1891tlfXPHMUcjrz6/////////4wogaSKCAABIPXdjqx491tlfXPHMUcjrz6/////////4wogaSKCCFGFMTbgnu181tlfXPHMUcjrz6/////////4wogaSKEJNOMJQXdjqx41tlfXPHMUcjrz6/////////4wogaSKIPUWSNMTbgnu11tlfXPHMUcjrz6/////////4wogaSKLTadYRJQXdjqx1tlfXPHMUcjrz6/////////4wogaSKLTbgbUNMTbgnu1tlfXPHMUcjrz6/////////4wogaSKLTbifYRJQXfkrytlfXPHMUcjrz6/////////4wogaSKLTbigbUNNUbgnutlfXPHMUcjrz6/////////4wogaSKLTbikfXQJRYfkrtlfXPHMUcjrz6/////////4wogaSKLTbingbTMNUbgntlfXPHMUcjrz6/////////4wogaSKLTbipjdXQJRYfkrlfXPHMUcjrz6/////////4wogaSKLTbipngbTMNUbgnlfXPHMUcjrz6/////////4wogaSKLTbipqjdXQJRYfklfXPHMUcjrz6/////////4wogaSKLTbipungbTMNVcilfXPHMUcjrz6/////////4wogaSKLTbipxqjdXQKRYfkfXPHMUcjrz6/////////4wogaSKLTbipxungaTMOVcifXPHMUcjrz6/////////4wogaSKLTbipxxqjdWPKRYffXPHMUcjrz6/////////4wogaSKLTbipx0tmgaTMOVcdXPHMUcjrz6/////////4wogaSKLTbipx4xqjdWPKRWXSMFMUcjrz6/////////4wogaSKLTbipx50tmgaTMLOPMHFMUcjrz6/////////4wogaSKLTbipx54xqjdWPIHHFBFMUcjrz6/////////4wogaSKLTbipx570tmfZSLEAAAFMUcjrz6/////////4wogaSKLTbipx5/4wpidWPIBAAFMUcjrz6/////////4wogaSKLTbipx5/70tmfZSLEAAFMUcjrz6/////////4wogaSKLTbipx5/+3wpidWPIBAFMUcjrz6/////////4wogaSKLTbipx5//70tmfZSLEAFMUcjrz6/////////4wogaSKLTbipx5//+3wpidWPHAFMUcjrz6/////////4wogaSKLTbipx5///70tmfZSLFFMUcjrz6/////////4wogaSMMTbipx5///+3wpicVOMMMUcjrz6/////////4wogaUUUUbipx5////6zslfZUUUUUcjrz6/////////4wogccccccipx5////+3wpidcccccdjrz6/////////4xqkjjjjjjmsz6/////6ztnjjjjjjjnt18/////////71vsrrrrrrsx39/////+4ytrrrrrrrty4///////////62zzzzzzzz38///////940zzzzzzz049////////////976666667+/////////+766666668//////////////////////////////////////////////////" },
    O = { 41, 51, -5.00, -5.50, 31.01, "/////////////////////////////////////////////////////////+9888889+/////////////////////////////96431000001347+////////////////////////962zxvtssssstvxz26+/////////////////////73zvspnlkkkkklnqsvz37///////////////////61wsokigffdddffgilosw16/////////////////60vqlifcaYXWWWXYacfilqv16///////////////60upkfcYVSQPOOOPRTVYcgkqv16/////////////82vpjfaVROLKMOOOMKLORVafkqv29////////////4xrkfZUPLLPSUWWWUSOLLPUafkry4///////////81ungbUPJLRVZcdddcZVRLJPVbgnu18//////////5xqjdXQJLRWcgijkjifcWRLKQXdjqx5/////////+2ungbTMJPWcglprsrplgcWPIMTbgnv2+////////80slfYRJMTagmswz0zwsmgaTMJRYfls08////////6zrjdWOHOWdjqx36863wqjdWOHOWdjrz6////////5xpicUMIQYflt07///70tlfYQJMUcipx5////////5xpibTLJRYgnv2+///+2vnfZRKLTbipx5////////5xpibTLKSagov3/////3wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow4/////4wogaSKLTbipx5////////5xpibTLKSagow3/////4wogaSKLTbipx5////////5xpibTLKRZgnv2+///+2vnfZSKLTbipx5////////5xpicUMJQYgmt18///81tmfYQJMUcipx5////////6zrjdWOHPWdjrx47973xqjdWPHOVdjrz6////////80skfYQJMUbgntx010xtmgbTMJQYfks07////////92ungaTMJQXdimqstsqmidWQJMTagnu29/////////4xqjdWPJMSXdgjklkjfdXSMJQWdjqx4//////////70tmgaUOIMSWbdffddaWSMIOUbgmt07///////////4xqkfZTOJMQTVXXXVTPLKOTZfkqx4////////////71vpidZUQMKMOPPPOMKNRVZfjpv18/////////////60tojfbXURPOMMMOPRUXbgjpu06///////////////5zupkgdbZXWUUUWXZbdgkpu06////////////////+50vrnjigfdcccdfgiknrv06///////////////////62xuromkjjjjjkmoruy26/////////////////////841ywtsrrrrrsuwy149////////////////////////86310zzzzz01369/////////////////////////////986666689/////////////////////////////////////////////////////////" },
    P = { 40, 50, -5.00, -5.00, 29.98, "///////////////////////////////////////////////9766666666666666689////////////////////62zzzzzzzzzzzzzzzz01358////////////////71vrrrrrrrrrrrrrrrrstvy159//////////////4wqkjjjjjjjjjjjjjjjkmoruy27////////////+2vnfccccccccccccccddfgjnsw16///////////+2vnfYUUUUUUUUUUUUUWXYbdglqv17//////////+2vnfYQMMMMMMMMMMMMOPRUYcfkqw28/////////+2vnfYQJFKOPPPPPPPONKJNRVaflrx4/////////+2vnfYQJJQVXXXXXXXWURNJKPVbgmt07////////+2vnfYQJMUbfffffffdcYUPJKQWdjqx4////////+2vnfYQJMUcjlllllkkifaUOIMTagnu19///////+2vnfYQJMUcjrttttsrokfZSLIQXdksz6///////+2vnfYQJMUcjrz1110zvpidWPHNVcipx5///////+2vnfYQJMUcjrz699860tmfZRKLTbgow4///////+2vnfYQJMUcjrz6///+3wogaTLKSagov3///////+2vnfYQJMUcjrz6////4xpibTLJRYgnv2+//////+2vnfYQJMUcjrz6////4xpibTLKRZgnv2+//////+2vnfYQJMUcjrz6///+3vogaTLKSagow3///////+2vnfYQJMUcjrz688750tmfYRJMTbiow4///////+2vnfYQJMUcjrz0000yupidWPHOVcjqy5///////+2vnfYQJMUcjrsssssrnjfZSLJRYfksz7///////+2vnfYQJMUcjkkkkkkjgfZTOINUbgnu29///////+2vnfYQJMTaddddddddbYTOIMSYfkry5////////+2vnfYQJJPUWWWWWWWVURNJNSXdiov29////////+2vnfYQJEJNOOOOOOOOMLNQTYdintz6/////////+2vnfYQJFLPQQQQQQQQSTVXbfinty4+/////////+2vnfYQJKRWYYYYYYYYabcfgjoty49//////////+2vnfYQJMUcggggggggggiknquz49///////////+2vnfYQJMUcjnnnnnnnnopsux15+////////////+2vnfYQJMUcjrvvvvvvvwxz248//////////////+2vnfYQJMUcjrz2222224569////////////////+2vnfYQJMUcjrz6+++++////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQJMUcjrz6/////////////////////////+2vnfYQMMUcjrz6/////////////////////////+2vnfYUUUUcjrz6/////////////////////////+2vnfcccccdjrz6//////////////////////////3wpkjjjjjjnt07//////////////////////////60vrrrrrrrty4+///////////////////////////62zzzzzzz049/////////////////////////////976666667+///////////////////////////////////////////////////////////////" },
    Q = { 39, 56, -5.00, -5.50, 29.70, "///////////////////////////////////////////////////////9888889+////////////////////////////86320000012469///////////////////////841ywutsssstvxz269///////////////////+61xuronlkkkklnpsvz37/////////////////+5zvqnjiffddddfgikosw16///////////////+5ztpkgdbZXWWWXYacfilqv16//////////////5ztoifbXURQOOOPQSVYcfkqv17////////////70uoidZUQMKMNOONLLORVafkqw29//////////+3wpjdYSOJMQTVWWUSPLLPUaflsy5//////////6zslfZTNIOSXbcddcaWRMJPVcgnu18/////////3wpicVPINTZdgjkkigcXSLKRYdjry5////////81tmfZSLLSYfinqsrpmidWQJNUbgov3+///////6zrjdWPHOVciotxzzwsmgbTMJRYflt18///////4xpicUMJRYglsz4763xqjdWOHPWdksz7///////4wogaTLLSagnv3+//80tlfYQINVcjrz6///////3vngaSKLTbipx4///+2unfYQJMUcipx5//////+2vnfYRJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+2vnfYQJLTbipx5///+2vnfYQJLTbipx5//////+3vngaSKLTbipx4///+2vnfYQJMTbipx5///////4wogaSKLTagov3+//81tlfYQIMUcjqy6///////4wpibTMJRYfltz5874xqjdWPHOWdjrz6///////6yqjdVOHOWdipuy00xtngbTMJRYfls08///////70slfYRJLSZfjorssqmidXQJMTbgnv2+///////+2vngbUNHOTZfijkkjgdXSMJQWdjqx5/////////5yrkfYSMIOTYbddddbWSMIOUbgmt07/////////92voidXRMINRUWXWVTQMJOTZfkqx4///////////6ztngcXSPMKMOPOOMKMQUZfjpv18///////////+4ysmidZWTRNIHHKPRUXbfjpu06/////////////93xsnigdaYTNHJQVZbdgkpu06///////////////83ytpmjgfYQILTbggjnrv06/////////////////940wtqnfYQJLTbiorux26////////////////////730vnfYQJLTbipx148//////////////////////+2vnfYQJLTbipx5////////////////////////+2vnfYQQQTbipx5////////////////////////+2vnfZYYYYbipx5/////////////////////////3voiggggggjqy5/////////////////////////6ztonnnnnnpu07/////////////////////////+4zwvvvvvvw06///////////////////////////+6322222247///////////////////////////////++++++////////////////" },
    R = { 40, 50, -5.00, -5.00, 30.61, "///////////////////////////////////////////////+888888888888888889////////////////////73000000000000000001358////////////////92wssssssssssssssssstvy149//////////////5yrlkkkkkkkkkkkkkkkkmoquy26/////////////4wogdddddddddddddddffgjnrv16////////////4wogaWWWWWWWWWWWWWWXYbdgkqv06///////////4wogaSOOOOOOOOOOOOOPRTXbfkpv17//////////4wogaSKGIMOOOOOOOOMKJMQVafkqw3+/////////4wogaSKHOTWWWWWWWWUSOJKPUagmtz6/////////4wogaSKKRZddddddddcZUPJJPWdipw3/////////4wogaSKKSagkkkkkkjifaUPILSZgmt18////////4wogaSKKSagosssssrpkfaTMIPWdjry6////////4wogaSKKSagow0000zvqjdXQIMUbipx4////////4wogaSKKSagow488860ungaSKLSagow3////////4wogaSKKSagow4////4woibTLKRZgnv2+///////4wogaSKKSagow4////5xpibTLJQYgnv2+///////4wogaSKKSagow4////5xpibTLJQYgnv2+///////4wogaSKKSagow4///93vogbTLKSagnv3+///////4wogaSKKSagow44442yslfYRJMTbiow4////////4wogaSKKSagowwwwwvsnicVOHOVdjqy5////////4wogaSKKSagoooooonlidXRLKRYfls07////////4wogaSKKSaggggggggfcXSMIPVciov2+////////4wogaSKJQWaaaaaaaaYVRMJOTZglsz6/////////4wogaSKFLQSSSSSSSSROLMQUZfjpw29/////////4wogaSKDIMOOOOOOMKJJPTWbfjpu07//////////4wogaSKHOTWWWWWWTOHMTadgkpu06///////////4wogaSKKRZddddddZSLMUcjmqv06////////////4wogaSKKSagkkkkicVNMTagnu16/////////////4wogaSKKSagossskfYQJQXfkrz6/////////////4wogaSKKSagow0ungaTMNUciow3+////////////4wogaSKKSagow4xqjdVOKRZflt07////////////4wogaSKKSagow40slfYRJOWdjqx4////////////4wogaSKKSagow43vogbUMMTagnu29///////////4wogaSKKSagow45yrjdWPJQXfkrz6///////////4wogaSKKSagow481tmfZSLNUciow3+//////////4wogaSKKSagow4/4wpicVNKRZflt07//////////4wogaSKKSagow4/6zskfYQJOWdjqx4//////////4wogaSKKSagow4/92ungbTMMTagnu19/////////4wogaSKKSagow4//4xqjdWOJQXdkry6/////////4wogaSKKSagow4//70tlfYRKNUbiov3+////////4wogaSKKSagow4//+3voibUMKRYfls07////////4wogaSMMSagow4///6yrjdXPMOVdiqx4////////4wogaUUUUagow4///81umfZUUUUagnu29///////4wogcccccciow4////4wpidcccccflt19///////5xrljjjjjjlry6////6zsmjjjjjjjou2+///////82wsrrrrrrsw29////+3xtrrrrrrruz5/////////72zzzzzzzz37//////830zzzzzzz05+//////////976666667+////////+766666668/////////////////////////////////////////////" },
    S = { 39, 51, -5.00, -5.50, 29.24, "//////////////////////////////////////////////////////+9888889////////////////////////////96421000001347+//////////////////////942zwutssssstvxz26+///////////////////62yurpnlkkkkkmnqsvz37////////////////+50vrnkiffddddffgilosw16//////////////+5zupkgfcaYXWWWXYacfilqv16/////////////6ztojfbXUSQPOOOPRTVYcgkqv17///////////81vpidZUQNKLNOOOMKLORVafkqw29//////////4xqkfZTOJMQTUWWVUROKLPUaflry5/////////81umgbUOINSXacdddbZVQLJPVbgnu29////////6yrjdXQJMSYdgikkjifbWRKKRYfkrz6////////4woibUMJQXdinqrsrokgcVPINUciow4///////+2vnfaSKMTbgntxz0yvrlfZSLKSZgnu29//////92unfYQJNUcjqx47762wpicVNIQXflt19//////91tlfXQIOWdkrz7///7zskdWPKPXdks08//////91tlfYQJNVcjry5///81tlfXSSSWdks08//////+2vnfYRJMUbiou049/91tlfaaaaadks08///////3vogbTMKRYfjpuy2692unigggggint18///////5xqjdWPINTZfjnrvz24ytpooooopty4////////70tmfZSMIOTZdgkosvz3zxwwwwwwz49////////+3wpidXRLIOTXbfikpsw044444446+//////////70tnicWRNIMRUYcfilptx159////////////////4ysmgcYTPLJORVZcfimquz37///////////////93xsmidZVROJKOSVZdgjosw16///////////////83xsnjgcYURNJLPSWbfilqu06///////////////83yuplifbYTQMIMQTYcfjpu06///////////////950wsokgdbXTPLJNRVafjpu17////////////////73zvrnjgdaWSOKLPTZfjqw39/////////+755555552yuqnjgdZVQLJOTaglsz6////////940xxxxxxy051xuqmifbWRLJPVciow3+///////4ytqpppppquz640xtpkgcWQJLRZflt08//////91uniiiiiijov2+730vrmgbTMHOWdkrz7//////80skdbbbbbflt19/+62wqjdXPHNUcjqy6//////80skdWTTTXflt19///71tmfYQJMTbipx5//////80skdWOLPXfks08///+2vnfYQJMTbipx5//////80skfXPHOWdjqx368860tlfYQJMUcjqy5//////91tlfYRJMTbgmswz00zvqjdWOHOWdjrz6//////+3vngbTMJQWcilprssrpkfaTMJRYfls08///////5xqjdWPJLRXcfikkkjifaUPINTbgnv2+///////70tmgaTNIMRVZcddddcZUPJLRYdjqx5////////+3wqjfYSOJLPSUWWWWUSOJMRWcinu18/////////71uoidZURNKLNOPPOMKMPSXcgmsy5///////////6ztoifbYUSQOOMNOPRTWZdgmsx39///////////+5ztpkgfcZXWWUVWXYbdginsx38/////////////+50vrnkigfddccdfggjmpty38////////////////62yurpnlkjjjkklnqtw049//////////////////952zwutsrrrsstvx037//////////////////////964200zzzz01357+//////////////////////////988666789+/////////////////////////////////////////////////////" },
    T = { 39, 50, -5.00, -5.00, 29.41, "////////////////////////////////////////////+8888888888888888888888888889/////////8300000000000000000000000000026///////93xtssssssssssssssssssssssssssv17//////6zsmkkkkkkkkkkkkkkkkkkkkkkkkkkqw3+/////5xpidddddddddddddddddddddddddflt19/////5xpibWWWWWWWWWWWWWWWWWWWWWWWXflt19/////5xpibTOOOOOOOOOOOOOOOOOOOOOPXflt19/////5xpibTOOOOOOONLGGGKNOOOOOOOPXflt19/////5xpibWWWWWWWWVRLEKQVWWWWWWWWXflt19/////5xpidddddddddcVNGNVbdddddddddglt19/////6zsmkkkkkkkkkdWOGOWdkkkkkkkkkkqw3+/////93xtsssssssskdWOGOWdksssssssssv17///////8410000000skdWOGOWdks0000000026//////////88888880skdWOGOWdks088888889/////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOMOWdks08////////////////////////80skdWUUUWdks08////////////////////////80skfcccccdks08////////////////////////92uojjjjjjjou19/////////////////////////5zurrrrrrruz5//////////////////////////+51zzzzzzz05+////////////////////////////866666668//////////////////////////////////////////////////////" },
    U = { 41, 50, -5.00, -5.00, 31.75, "////////////////////////////////////////////////988888889//////////88888888+////////////62000000015+//////941000000037//////////60vsssssssuz5/////+4ytsssssssw28////////+3wpkkkkkkkou19////6ztnkkkkkklrx4////////91tlfddddddkrz7////5xpiddddddgnv3+///////91tlfXWWWWcjrz6////5xpibWWWWYgnv2+///////91tlfXPOOUcjrz6////5xpibTOOQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJQYgnv2+///////91tlfXPHMUcjrz6////5xpibTLJRYgnv2+///////91tlfYQIMUcjqy6////4wogbTLKSagov3////////+2unfYRJMTbiow39//71unfZSKLTbgow4/////////3vogbTLKRZflsy2441wqjdXQINVciqx5/////////5xqicVOHOVcinsvwwuqlfbTMIQXfksz7/////////7zslfYRLLRXdiknoonkfbVQJMTagnu29/////////+2voicVPIMSXcfgggfdbVQKKQXdjqx4///////////6zslfaTOJMRVYabaZXUQKKPVbgnt07///////////93wqjfZUPLKOQSTSSQNJMQVaglry4/////////////70upjfaWSPNLKLLKLNQTXbgkqw29//////////////60upkgdZWUTSQRSTVXadglqv17////////////////60vqmigdcbaYYabcfgjnrw16//////////////////61wtpmkiggggggiknquy27////////////////////730wtrponnnooqsux049//////////////////////+741zxwvvvvwxz247///////////////////////////865432234579/////////////////////////////////+++///////////////////" },
    V = { 40, 50, -5.00, -5.00, 30.78, "/////////////////////////////////////////////+888888889///////////988888888+////////730000000026/////////620000000038//////82wssssssssv17///////60vssssssstx39/////5xrlkkkkkkkqw3+/////+3wpkkkkkkkmsz6/////4wogddddddflt08/////80slfddddddipx5/////4wpibWWWWWdjrz6/////6zrjdWWWWWdjqy6/////6yrjdWOOOUcipx4/////4xpicUOOQXfks07/////80slfYQJLTagnv3////+3vngaSLKSagnu29/////+2ungaSLJRYgmt19///81tlfYRJMUbipw4///////4xpicUMHPXdksz7///7zskdWPHOWdjry6///////6zrjdWOHNVciqx5///5xqicVNJQYfls08///////80tlfYRJLTbgow3///3wogbTLLSagnv2+///////+2vngaTLKRZgmu19/91umfZRKMUcipx4/////////4xpicUNIPXfks07/70skfXPIOWdjrz6/////////6zrkdWPHOVdjqy6/6yqjdVOJRYglt08/////////81tmfYRJMTbiow4/4wpibTMLTagnv3+//////////3vogbTLKSZgnu2+2vnfaSKNUcipx4///////////5xqicVNIQYfls080tlfYQIPWdkrz6///////////7zskdXPIOWdjry6zrjdWOJRYgmt18///////////91umfZRKMUbipx4xpicUMLTbgov3/////////////3wogbTMLSagnv2vngaTLNVciqx5/////////////5yqjcVNJQYflt1tmfYRJPXdksz7/////////////7zskfXQIPWdkrzskdXPKRZgmu19/////////////92unfZSKNUcipxqjcVNMTbgow3///////////////4woibTMLTagovogbTMOVcjqy5///////////////6yqjdVOJRYgmtnfZSKQXfksz7///////////////70slfYQIPXdkskfXQKSZgnu29///////////////+2ungaSKNVcjqjdWOMTbiow4/////////////////4wpibUMMTbgoibUMOVdjqy6/////////////////6yrjdWOKRZgmgaSKQYfls07/////////////////80tlfYQJPXfkfYQKSagnu2+/////////////////+2vngaSLOVdjdWOMUbipw4///////////////////4xpicUMMTbicUNOWdjry6///////////////////6zrjdWPKSZfbTLQYflt08///////////////////81tlfYRJPUYVQLSagnv2+///////////////////+3vngaTLJOQPKNUcipx4/////////////////////4xpicUNFHJHHPWdkrz6/////////////////////6zrkdXPHABBJRYglt18/////////////////////91tmfYRJCADLTagnv3+//////////////////////3vogbTLEAFNVcipx4///////////////////////5xqicVNGFHPXdksz6///////////////////////7zskfXPMMMRYgmt19///////////////////////91umfZUUUUUbgov3/////////////////////////3wogccccccdiqx5/////////////////////////5ysmjjjjjjjnt07/////////////////////////93xsrrrrrrrty4+//////////////////////////83zzzzzzzz049////////////////////////////+766666667+//////////////////////////////////////////////////////" },
    W = { 54, 50, -5.00, -5.00, 43.95, "///////////////////////////////////////////////////////////988888888+///////+88888888+////////888888889/////////620000000038/////830000000038/////941000000026///////60vssssssstx39///93xtsssssstx39///+4ytsssssssv17//////3wpkkkkkkkmsz6///6zsmkkkkkkmsz6///70tnkkkkkkkqw4/////+2vnfddddddiow4///4xpiddddddiow4///5xqiddddddgnv2+////+2vngaWWWWagnu2+//3vngaWWWWagnv2+//4wogbWWWWagnv3+/////4wpibTOOQYflt08/91tmfYROOQYflt08/+2unfZSOOUbipx4//////6yqjdVOHOWdkrz6/70skfXPHHOWdkrz7/80tlfYQIOWdjry6//////70skfXPINUcipx5/6zrjdVOGFNUciqx5/7zrkdWOIPXfks08//////91umfZRKLTbgow3/4xpicUMFELTbgow3/5xqicUNKRZgmu19///////3wogbTMKRZgnu293vogaTLDCKRZgnu294wogbTLLTbgow3////////5yqjcVNIQXfks081umfYRJCAIQXfls082unfZSKNUciqx5////////7zskdXPHOWdjrz60skfXPIAAHOWdjrz60tlfYQIPWdkrz7////////91tmfYRJMUcipx4zrjdWOGAAFMUcipx4zrkdWOJQYflt18/////////3vngaTLLSagnv3xpicUMGIIGLTagnv3xqicUNKSagnv2+/////////4xpicUNJRYgmt1vogaTLNQQNJRYgmt1wogbTLMUbipw4//////////6zrkdWOHPXdkszumfYRMSYYSMPXfks0unfZSKOVdjry6//////////80tlfYQJNVcjqyskfXPOWddWOOVdjqytlfYQIPXfks07//////////+2vngaSKMTbipwrjdWOQXffYQMTbipwrkdWOJRYgmu19///////////4wpibUMKSagnvpicUMRZgfZSKSagnvqicUNLTbgov3////////////6yrjdWOIQYfltogaTLTbggbTLQYfltogbTLNUcipx5////////////80slfXQIPWdkrnfZRMUciicUNPWdksnfZRKOWdkrz6////////////92unfZSKNUciqlfXQOWdjkdWONVciqlfXQIQYflt08/////////////4woibTMLTbgojdWOPXfklfYQLTbgojdWOKSagnv2+/////////////5yqjcVNKRZgnicUMRYgmnfZSKSZgnicUMMTbipw4//////////////7zskfXPIQXflgbTLTagooibTMQYflgbTLOVdjqy6//////////////91umfYRJOWdjfZRMUcipqjcVNOWdjfZRKPXfks07///////////////3vogbTLMUcifXQOVdjrskdWPMUcifXQJRYgmu19///////////////5xqicUNLTagdWOPXfkstlfYQLTagdWOLTagov3////////////////7zrkdWPJRYgcUMRYgmtvngaSKRYgcUMMUcipx4////////////////81tlfYRJPVbYSLSagnvwoibTMPVbYSLOWdjrz6////////////////+3vngaSLKQTSNMUbipxyqjcVNKQTSNIQYflt08/////////////////4xpicUMFJLKHNVcjryzskdWPHJLKHKSagnu2+/////////////////6zrjdWOHCDDHPXdksz1tlfYQJCDDEMTbiow4//////////////////80slfYQIBABJQYglt13vngaSKDAAGNVcjqy6//////////////////+2ungaSKDADKSagnv34wpibTMEAAHPXfksz7///////////////////4wpibTMEAEMTbipw46yqjcVNGACJRYgmt19///////////////////6yqjdVOGAFNVcjqy57zskdXPHADLTagov3////////////////////70skfXQIAHPWdksz791tlfYQJBFMUcipx4////////////////////92unfZRKCIQYflt18+3vngaSKDHOWdjrz6/////////////////////3wogbTMFKSagnv2+/4wpibTMFIQYfls08/////////////////////5yqjcVNMMTbiow4//6yqjdVOMMSZgnu2+/////////////////////7zskdXUUUUciqx5//70skfXUUUUbiow4//////////////////////91tmfcccccdkrz7//91tmfcccccdjqy5///////////////////////3wqkjjjjjjou19///3wqkjjjjjjnt07///////////////////////71vrrrrrrruz5////71vrrrrrrrty4+////////////////////////62zzzzzzz05+/////62zzzzzzz049//////////////////////////976666668////////976666667+///////////////////////////////////////////////////////////////////" },
    X = { 40, 50, -5.00, -5.00, 30.67, "/////////////////////////////////////////////+888888889///////////988888888/////////730000000026////////+510000000149//////92wssssssssv06///////5zusssssssty4//////6yrlkkkkkkkpv29/////70uokkkkkkknt18/////5xpiddddddfksz6/////4xqjdddddddks08/////6yqjdXWWWWciov29///70tmfaWWWWZgmt08/////81ungbTOORYfksz6///4xqjdWPOPWdipw3+//////4xqjdXQJOVciov3+/70tmfaTMLSZgmt07///////81ungbTMKRYflsz6/4xqjdWPIPWdipw3+////////4xqjdXQJOVcipw381ungbTMMSZgmt07/////////81ungbUNLSZflsz4xqjdXQJPWdipw3+//////////4xqkfYRJOVcipw1ungbTMMTagmt07///////////81ungbUNLSZflsxqjdXQJPWdjqx4/////////////5yrkfYRJOVcipungbTMMTagmt07/////////////92ungbUNLSZflrkdXQJPWdjqx4///////////////5yrkfYRJOVcingbUNMTagmt07///////////////92ungbUNLSZgkfYRJPWdjqx4/////////////////5yrkfYRJPWdgbUNMTagmt07/////////////////92ungbUNLSZcXRJPWdjqx4///////////////////5yrkfYRJOTURMMTagmt07///////////////////92ungbUNIMMLIPWdjqx4/////////////////////5yrkfYRJEFFMTagmt07/////////////////////92ungbUNGBIPWdjqx4///////////////////////5yrkfYQIDLTagmt07///////////////////////6zskfYQIDLTbgnu18//////////////////////92voicVOHCJQXdjqx4//////////////////////6zskfYRKDDFMTbgnu18////////////////////92voicVOHKLJJQXdjqx4////////////////////5yskfYRKNSTQLMTbgnu18//////////////////92unicVOLSYbWQJQXdjqx4//////////////////5yrkfYRKOVcgbTMMTbgmt07////////////////92ungbUNLSZgjdXQJQWdjqx4////////////////5yrkfYRJOVcingbTMMTagmt07//////////////92ungbUNKRYfkqjdXQIPWdjqx4//////////////5yrkfYRJOVcioungaTMMTagmt07////////////92ungbUNKRYfksxqjdWPIPWdjqx4////////////5yrkfYRJOVciov0tmgaTMMTagmt07//////////92ungbUNKRYfksz4xqjdWPIPWdjqx4//////////5yrkfYRJOVciov270tmgaTMMTagmt07////////92ungbUNKRYfksz6/4xqjdWPIPWdjqx4////////5yrkfYRJOVciov29/70tmgaSLMTagmt07//////92ungbUNMRYfksz6///4xpidWPMPWdjqx4//////6yrkfYUUUUbiov29///70tmfZUUUUagmt18/////5xpiccccccfkry6////+3wpidcccccdks08/////6yrljjjjjjjpv29/////70tnjjjjjjjnt18/////92wsrrrrrrru06//////+4ytrrrrrrrty4///////72zzzzzzzz16////////940zzzzzzz049////////9766666668///////////866666667+////////////////////////////////////////////" },
    Y = { 40, 50, -5.00, -5.00, 30.10, "/////////////////////////////////////////////+888888889//////////988888888+/////////730000000026////////620000000037///////92wssssssssv06//////71vssssssssw28//////6yrlkkkkkkkpv29////+3wqkkkkkkklrx5//////5xpiddddddfksz6////7zslfddddddgow4//////5yqjdWWWWWcipw4////4xpicWWWWWdipx4//////70tmfZSOOSZgmt18//81umfaSOOSZgls07///////3wpicVOIPWdjqy5//5yrjdXPIOVcipw3+///////7zslfYRKMTbgnv29+2vogbUMJRYfksz6////////+3voicUNJRYfksz67zslfYRJMUbgnv29/////////6zrkfYRJOVcipw44xqicVOJQXdjry5//////////92ungbTMLSZgmt11unfaTLMTagnu18///////////5xqjdWPIPWdjqyyrkdXQIPWdjqx4////////////81tmgaTLMTbgnvvoibUNLSZgmt07/////////////4xqidWOJRYfksslfYRKOVcipw3+/////////////70tlfZSKOVcipqidVOKRYflsz6//////////////+3wpicVOLSZgmnfaTLNUciov2+///////////////6zskfYRJPWdjkdXQJQYfkrz6////////////////92vngbUMMTbgibUNMTbgnu29/////////////////5yrjdXQJRYffYRKPWdjqx4//////////////////81ungaTMOVbcWOLSagmt18///////////////////4xqjdWPKQVVRLOWdipx4////////////////////70tmfZSLKNNLLSZglt07////////////////////+3wpicVOHFGHOVcipw3+/////////////////////6zslfYRKCCJRYfksz6//////////////////////+2voibUNGFNUbgnv29///////////////////////6yrkfYQJJQXdkry5////////////////////////92ungaSKKSagnu19/////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSKKSagow4//////////////////////////4wogaSMMSagow4//////////////////////////4wogaUUUUagow4//////////////////////////4woiccccccgow4//////////////////////////6zsmjjjjjjlry5//////////////////////////93xsrrrrrrsw29///////////////////////////83zzzzzzzz37/////////////////////////////+76666667+///////////////////////////////////////////////////////" },
    Z = { 37, 50, -5.00, -5.00, 27.36, "//////////////////////////////////////////+8888888888888888888888888+/////////83000000000000000000000000038///////93xtssssssssssssssssssssssstx39//////6zsmkkkkkkkkkkkkkkkkkkkkkkkmsy5//////5xpidddddddddddddddddddddddgow4//////5xpibWWWWWWWWWWWWWWWWWWWWWagow4//////5xpibTOOOOOOOOOOOOOOOOOOOSagow4//////5xpibTOOOOOOOOOOOOOONKGGKSagow4//////5xpibWWWWWWWWWWWWWWWVQJCKSagow4//////5xpiddddddddddddddddbUMFLSagow4//////6ztnkkkkkkkkkkkkkkkicUMIPWdipx4//////+4ytsssssssssssssqjfYRKMTagmt07///////941000000000000tmgbTNJRXdjqx3+/////////888888888883wpjdWQJOUbgnu07////////////////////6zslfZTMLSYfkry4////////////////////92voicVPIPVciov29////////////////////4yrkfYSLMSZglsz6////////////////////71ungbUOJQWdipw3+///////////////////+3xqjdXRJNTbgmt07////////////////////60tmfaTMKRYfjqx4////////////////////92wpidWPJOVcinu18////////////////////5zslfZSLLSZgksy5////////////////////82uoicVOIPWdipv29////////////////////4xrkfYRKMTagmtz6////////////////////70tngbUNJQXdjqw3+///////////////////+3wqjdXQJNUbgnu07////////////////////6zsmfaTMLRYfkry4////////////////////92vpicWPIPVciov29////////////////////5yskfZSLMSZglsz6////////////////////81ungcVOJQWdipw39///////////////////+4xqjdYRKNTbgmt07////////////////////70tmfbTNKRYdjqx4+///////////////////+3wpidWQJOVbgnu18////////////////////6zslfZSMLSZfkry5////////////////////92voicVPIPWcipv299999999999//////////4yrkfYRLMTagmsz11111111111249///////70ungbUNJQXdjqtttttttttttttuy4+//////5yqjdXQJMTbglllllllllllllllntz6//////5xpibTMFMUbffffffffffffffffiow4//////5xpibTLDJQVXXXXXXXXXXXXXXXagow4//////5xpibTLFFKOPPPPPPPPPPPPPPSagow4//////5xpibTMMMMMMMMMMMMMMMMMMMSagow4//////5xpibUUUUUUUUUUUUUUUUUUUUUagow4//////5xpicccccccccccccccccccccccgow4//////6zsmjjjjjjjjjjjjjjjjjjjjjjjlrx5//////93xsrrrrrrrrrrrrrrrrrrrrrrrsw28///////83zzzzzzzzzzzzzzzzzzzzzzzzz27/////////+76666666666666666666666679//////////////////////////////////////////" },
    ["0"] = { 39, 51, -5.00, -5.50, 29.01, "//////////////////////////////////////////////////////987666789///////////////////////////96420zzzzz02469//////////////////////+62zwussrrrssuwz26+///////////////////83zvspnlkjjjklnpsvz38/////////////////72xtokiffdcccdffikotx27///////////////72wrmifcZXWVUVWXZcfimrw27/////////////93wrlgdYVSQONMNOQSVYdglrw39////////////4ysmfbWSOLKNOOONKLOSWbgmsy4///////////81ungcWQLJOSUWWWUSOJLQWcgnu18//////////4xqjdXRLJPUZcdddcZUPJLRXdjqx4/////////92ungbTMIPUafikkkifaUPIMTbgnu29////////70skfYQJMTZgkprsrpkfaTMJQYfksz7////////6yqjdVOHPWdjpvz0zvqjdWPHOVcjqy6////////5xpibTMJRYgmt06860tmfYRJMTbipx4////////4wogbTLKSagov3///3vogaSKLTagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaSKKSagow4///4wogaSKKSagow4////////4wogaTLKSagow3///3wogaSKLSagow4////////4xpibTMKRZgmu17971umfZRKMTbipx4////////6yqjcVNIPXdjqw010wqjdXPINVcjqy5////////7zskfXQJMTaglqstsqlfbTMIQXfksz7////////92ungaTMJPVbfjklkjfbVQJMTagnu29/////////4xqjdXQKKQVadfffdaVQKKQXdjqx4//////////70tngbVQKKPTVXXXVTPKKQVbgnt07///////////4yrlgbVRNJMOPPPOMJMRVbglry4////////////92wqkgcYTRONMLMNPRTXcgkqw29/////////////71vrlgdbYWUUTUUWYbdglqv17///////////////62wsnjgfdccbccdggjnsw16/////////////////72yuqolkjiiijkloquy27///////////////////951yvtrrppprrtvy149//////////////////////8530zzxxxzz1358//////////////////////////+876555678+/////////////////////////////////////////////////////" },
    ["1"] = { 27, 50, -5.00, -5.00, 17.84, "//////////////////////////////////////9888888889///////////////9620000000026////////////952zvssssssssv17/////////852yusokkkkkkkkqw3+///////61yurnkifddddddflt19//////71vqnkgfcYWWWWWXflt19//////4xqkgfbYVROOOOPXflt19/////+2vnfbYURNKHGGHPXflt19/////+2vnfZSNLNPOKFHPXflt19//////4wogaSRTVXVQJHPXflt19//////4wogaWYbcfbUMHPXflt19//////4wogcdggijcUMHPXflt19//////4xqkijlnqjcUMHPXflt19//////71vqprtvrjcUMHPXflt19///////61yxz0zrjcUMHPXflt19////////86566zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMHPXflt19////////////6zrjcUMMPXflt19////////////6zrjcUUUUXflt19////////////6zrjdcccccflt19////////////80tnjjjjjjjpv2+/////////////4ytrrrrrrru06//////////////940zzzzzzz16////////////////+766666668/////////////////////////////////" },
    ["2"] = { 37, 50, -5.00, -5.50, 27.82, "////////////////////////////////////////////////////9888889+//////////////////////////8531000001347+/////////////////////740yvussssstvx037//////////////////+51xtqomlkkkklnqtw049///////////////94zuqmjgffdddffgimpty38/////////////+4ytojfdbYXWWWXYadfinsx38////////////5ztnifaWTRPOOOPRTWZdgmsx4+//////////70uoidYTPMJMOOOMKLPSXcgmtz6/////////+3wpjdYSNJNRTVWWURNIMRWdiov29////////70tmfZTNHNSYbdddbYTOIMSYfksz6////////4xqidWPIMSYdgjkjifZTNHOVciow3///////+2vngaTLJRXdinqsrojfYRKKRZgmt19//////91tlfYQJMTbgnty0yuoicVNHPXdks07//////80skdXPHNVcjqx476zskdWPHOVdjrz6//////80skdWOJOWdksz7/81tlfXPHMUcjrz6//////80skdWQQQWdks08/80tlfXPHMUcjrz6//////80skdYYYYYdks08/6zrkdWOHOWdjrz6//////80tmgggggggmt08+3wpicUNHPXfks08//////+3wrnnnnnnnrw3+60tmfZSKKRZgmt19///////72xvvvvvvvx2793wpidWPHMUbiow3/////////85322222358/5yslfZSLJQXdjry6////////////+++++///70unicVOIMTbgnu18///////////////////93wqjdYRLJQXdjqx4///////////////////+4yslfaTNHOUbgnu18///////////////////6ztngcVPIMSZfkry4///////////////////71uoidXRLKQXdipv29//////////////////82wqjfYSMIPVbgntz6//////////////////+3xrlfaTNHNTaglry4+//////////////////5ztmgbVPJMSYfjqw29//////////////////60uoidWQKLRXdiou07//////////////////71vpjdYSLJQWcgntz6//////////////////83wqkfZTNIPUbgmsy4+/////////////////+4xslfaUOINTZgkrw39//////////////////5ztmgcVPJMSYfjpv27//////////////////60uoidWRLLSXdiou06//////////////////71vpjdYSMKQWdintz5555555556+////////92wqkfZTNJPVbgmtxxxxxxxxxxxz49///////4yrlfaUOIOUaglpppppppppppppty4//////92ungbVPJHPXfiiiiiiiiiiiiiiint18/////91tlfXQKEHOVbbbbbbbbbbbbbbbdks08/////91tlfXPHBEKQTTTTTTTTTTTTTTWdks08/////91tlfXPJJJJJLLLLLLLLLLLLLOWdks08/////91tlfXQQQQQQQQQQQQQQQQQQQQWdks08/////91tlfYYYYYYYYYYYYYYYYYYYYYYdks08/////91umggggggggggggggggggggggggls08//////4xsnnnnnnnnnnnnnnnnnnnnnnnnrw3+//////83yvvvvvvvvvvvvvvvvvvvvvvvvx27////////9432222222222222222222222248///////////++++++++++++++++++++++++//////" },
    ["3"] = { 37, 50, -5.00, -5.00, 27.24, "///////////////////////////////////////////+88888888888888888888888+///////////730000000000000000000000037/////////82wsssssssssssssssssssssssw28////////4xrlkkkkkkkkkkkkkkkkkkkkklrx4///////+2vnfdddddddddddddddddddddgnv2+//////+2vnfYWWWWWWWWWWWWWWWWWWWYgnv2+//////+2vnfYQOOOOOOOOOOOOOOOOOQYgnv2+//////+2vnfYQOOOOOOOOOOOOLGGGJQYgnv2+//////+2vnfYWWWWWWWWWWWWVSMFCJQYgnv2+//////+2vngddddddddddddddWPHGNSZgnv2+///////4xrmkkkkkkkkkkkkidWOHMSYdipw3////////82wtssssssssssoidXSLLRWdintz6/////////73000000000upidYSMKQVcgmty5+//////////+88888861vpjfZSNJPVbglsx49/////////////////72vqkfZTOIOTagkrw38/////////////////82wrkfaUOINSZfjqv27/////////////////93xrlfbUPJMSYdipu16/////////////////+4ysmgbVQJLRXdiot06//////////////////6ztngcWQKHOWcgnruz38/////////////////4woidXRLFHPXdfikosx38////////////////4wogcWQKMMMSYZcfimsx39///////////////5ysmgbVSUUUSQSUYcgmsy4///////////////93xrlgbZbcbZVRNRWcinu07///////////////82wrkfgijigcWQLRXdjqx4////////////////72vqllprplgbVOMTagnu29////////////////61wsswywrkfYRJQXfkrz6/////////////////7300362vngbTLNUcipx4//////////+9999999+88+/5xqicUMLSagnv3/////////63111111249///6zrjdWOJRYgmu19///////60wttttttuy39//80skdWOIPXflt19//////81upllllllnsy4//80skdWOHPXflt19//////6zrjffffffgnv3+/80skdWOHPXflt19//////6zrjcXXXXYflt19/80skdWOHPXflt19//////6zrjcVPPPXflt08/6zrjdWOIQXflt19//////7zskdWOHOWdksz6/5xqicUMJRYgnu29//////80skfXPHNVcipw242vngbTLLTbgov3///////91tmfYRJLSZgmsvwurkfYRJOVciqx5////////3vogbTMIPWcgloonkfbUNJRYfksz7////////5yqjdXQJLRWcfgggfbVQJNUbgnv29////////81ungbUOJLRVYabaYUQKLRYfkry5//////////4xrkfZUPLKORSTSQNJMRWciou29//////////82vpjfaVSOMLKLKLMPSXcgmsz5////////////60upkgcZWUSSQSTUWZdgmsx3+/////////////60vqlifdbaZYaacdginsx38///////////////61wspljigggggijmpty38/////////////////73zwtrponnnoprtw049///////////////////+630yxwvvvwxz147///////////////////////+86442224468//////////////////////////////+++/////////////////" },
    ["4"] = { 39, 50, -5.00, -5.00, 29.76, "//////////////////////////////////////////////////////988888888+///////////////////////////+510000000038//////////////////////////5zussssssstx3+////////////////////////80uokkkkkkkmsz7////////////////////////5xqjdddddddjrz6///////////////////////92ungbWWWWXfkrz7///////////////////////6zskfYROOTagnu29///////////////////////4wpicVOHOVdiqx4///////////////////////81tmfZSLKRYgls07///////////////////////5yqjdWPINUbiov3+//////////////////////+2vogbTMIPXdkry6///////////////////////7zslfYRJLSagmu19///////////////////////4xpicVOHOVcipx4///////////////////////91umfaSLJRYflsz7///////////////////////6yrkdXPIMTbgov2+//////////////////////+3voibUNIPWdjqy59999999+///////////////70slfYRKLSZgmt13111111137//////////////4xqidVOHOVcipw1wtttttttw17////////////92ungaTLJRYfkszvqlllllllqw3+///////////6zrkfXQJMTbgnu0skfffffffls08//////////+3woicUNIPWdjqx0skdXXXXXdks08//////////70tlfZRKLSZgmt00skdWPPPWdks08//////////4xqjdWOHNVcipw30skdWOHOWdks08/////////92ungbTMJQYfksz60skdWOGOWdks08/////////6zskfYQJMTbgnu240skdWOGOWdks059////////3wpicVNHPWdjqwwwwskdWOGOWdkswy38//////80tmfZSKKRZgmooooookdWOGOWdkoosx3+/////5xqjdWPHLTbgggggggggdWOGOWdgggmt08/////4wogbTMFJQWaaaaaaaaaYSMFMTZaadks08/////4wogaSKCFLQSSSSSSSSSRNHCIORSWdks08/////4wogaSKJJJJKKKKKKKKKJHCADHKOWdks08/////4wogaSQQQQQQQQQQQQQQQMGAGMQQWdks08/////4wogaYYYYYYYYYYYYYYYXSLELSXYYdks08/////4woiggggggggggggggggdVOGOVdgggls08/////6ztnnnnnnnnnnnnnnnnkdWOGOWdknnrw3+/////+4yvvvvvvvvvvvvvvvskdWOGOWdksvx27///////95322222222222220skdWOGOWdks048///////////++++++++++++80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOGOWdks08////////////////////////80skdWOMOWdks08////////////////////////80skdWUUUWdks08////////////////////////80skdcccccfks08////////////////////////91uojjjjjjjou29/////////////////////////5zurrrrrrruz5//////////////////////////+50zzzzzzz05+////////////////////////////866666668///////////////////////////////////////////////" },
    ["5"] = { 37, 50, -5.00, -5.00, 27.24, "///////////////////////////////////////////+88888888888888888888888+///////////730000000000000000000000038/////////82wsssssssssssssssssssssstx39////////4xrlkkkkkkkkkkkkkkkkkkkkkmsy5///////+3vngdddddddddddddddddddddgow4///////+2vnfYWWWWWWWWWWWWWWWWWWWagow4///////+2vnfYQOOOOOOOOOOOOOOOOOSagow4///////+2vnfYQJGJNOOOOOOOOOOOOOSagow4///////+2vnfYQJIPUWWWWWWWWWWWWWWagow4///////+2vnfYQJLTadddddddddddddddgow4///////+2vnfYQJLTbikkkkkkkkkkkkkkmsy5///////+2vnfYQJLTbipssssssssssssstx39///////+2vnfYQJLTbipx000000000000148////////+2vnfYQJLTbipx5888888888888//////////+2vnfYQJLTbipx5//////////////////////+2vnfYQJLTbipx56555679///////////////+2vnfYQJLTbipxzyxxxyz147/////////////+2vnfYQJLTbipusqpppqsux049///////////+2vnfYQJLTbipnkjiiijkmqty37//////////+2vnfYQJLTbijffcbbbcdgjnsw28/////////+2vnfYQJLTbidaXVTTTVXadglrx39////////+2vnfYQJKSYbXTQNMLMNPTXcgmsy5////////+2vnfYQJHNSTRNPQQPNJIMRWcinu29///////+2vnfYQJCHKNSVXYYXUQMGLRYfkry5///////+2vnfYQJFIOTYcfgfdbXSMGNUbgov3+//////+2vnfYQMMMSZfikllkgdXQJJRYflt18//////+2vnfYUUUUWdiosttrngbUMHPWdkrz7//////+3vngccccccgmtz11yrjdWPHNUciqx5///////4xrljjjjjjlrx4981tlfYQJLTbipx4///////82wsrrrrrrsw28/+2vngaSKLSagow4////////73zzzzzzzz37///4wogaSKKSagow4///////93xuttttttuy4+//4wogaSKKSagow4///////5ysmllllllntz6//4wogaSKKSagow4///////4wogffffffipw4/+2vnfaSKLSagow4///////4wogaXXXXagnu2980tlfYQJLTbipx4///////4xpibUPPQYfksz33yqjdWOHNUciqx5///////6yrjdWOHNVciotwvsngbTMIPXdkrz7///////80slfYRJKRYdimoolidXQJLSZgmt19///////+2vogbUNHNSYdfggfcXSMIOVcipw3/////////5yrkfYSMHNSWZaaYWRMHNTZglsz6/////////92voidXSNJMPRSSROLJOSYdjpw3+//////////6ztnidYUROMKKKLMORUZdiou06///////////+4ytnifbYVTSSSSTVYbfiotz5/////////////94ytokgfcbaaaabdfgkptz5+//////////////94zurnkjiggggijlorvz5+////////////////+52xusqpoooopqsvy26+///////////////////852zywwwwwxy0259///////////////////////97544444467+/////////////////////////////////////////////////" },
    ["6"] = { 37, 51, -5.00, -5.50, 27.30, "////////////////////////////////////////////////////9888889+//////////////////////////8531000001247+/////////////////////841ywussssstvxz36//////////////////+61xtqomlkkkklnqsw049///////////////+5zuqmjgffddddfgilpty38/////////////+5ztojfdbZXWWWXYacfinsx39////////////6ztoifbWTRPOOOPQTVZdgmsy4+//////////81uoidYTQMKKMMMMJLOSXcgntz6//////////4xqjfYSNJKPSUUUTQMIMRXdipw3+////////91ungbTNHLRVZcccbXSNHMSZflsz7////////6zrkdXQJJQWcgijjgdYSMHOVciqx4////////4xpicUNGOUbglprqnidWPILTagov3////////4wogaTLJQYfkrwzxtmgaSLJRYgnu2+//////+3vngaSKKSagnu264xpicUMLQYflt19//////+2vnfYQJLTbgow4/6zrjcUTTTXflt19//////+2vnfYQJLTbipx586zrjcbbbbbflt19//////+2vnfYQJLTbipx100zsmiiiiiiiov2+//////+2vnfYQJLTbipwtsssssppppppqtz6///////+2vnfYQJLTbipomkkkkloquxxxx05+///////+2vnfYRJLTbikiffddffgjnrw257//////////3vngaSKLTbifcZXWWXYbdglrw27//////////4wogaSKLSZdZVRPOOPRTXbglrw39/////////4wogaSKIOTWTOPPPPMJMQVbglsz6/////////4wogaSKDIMOQUXXXWTQLKQVciov29////////4wogaSKCFLRWbdffdbWRLLRYfksz6////////4wogaSKCJQWcgklljgcVPIOVcipw3////////4wogaSKFMTbgmrttqlfaTMKSZgmt18///////4wogaSKHPWdjqx11wqjdVOIPWdkrz6///////4wogaSKJQYglt1870slfYQINUcipx5///////4wogaSKKSagnv3++2unfZSKLTbgow4///////4wogaSKKSagow4//4wogaSKKSagow4///////4wogaSKLTbipw4//4wogbTLKSagnv3///////4wogaSKLTbgow4//4wogaSLKSagnv3+//////4wogaSKKSagow4//3vogaSKKSagow4///////4wogbTLKSagnv2+92unfYRJLTbgow4///////5xpicUNIQYflt076zskfXQIMUcipx5///////6zrkdXPIOWdjqwzzvpicVOHOWdjrz6///////91umfZSKMTaglqsspkfZSLJRYglt08////////4wpicVOIPVbfikkifbVOIMTbgnv3+////////6zskfYRLKQVacddcZVQKKQXdjqy5/////////92voicWQLKPTVWWVSPKKPVbgnu18//////////6zsmgbWRNKLNOONLKNRVaglry4///////////+3xrlgcYVSQOOOOPRUYcgkqw29////////////82wrmifcZXWWWWXZbfglqv17//////////////72xsokigfddddfgiknsw16////////////////83zvspnlkkkklmoruy27//////////////////+62zwussssssuwy259/////////////////////96420000001369//////////////////////////98888889///////////////////////////////////////////////////" },
    ["7"] = { 35, 50, -5.00, -5.00, 25.08, "////////////////////////////////////////9888888888888888888888888+////////6200000000000000000000000038//////60vssssssssssssssssssssssstx39////+2vpkkkkkkkkkkkkkkkkkkkkkkkmsz6////91tlfddddddddddddddddddddddipx5////80skdXWWWWWWWWWWWWWWWWWWWWbipx5////80skdWOOOOOOOOOOOOOOOOOOOTbipx5////80skdWOGLOOOOOOOOOOONLGGLTbipx5////80skdWOMSVWWWWWWWWWWVRLELTbipx5////80skdWOPWdddddddddddcVNGLTbipx5////80skdWOPXfkkkkkkkkkjdVOGOVciqx5////80skdWUUXflsssssssngbTMJQYfksz7////80skdccccglt00000slfYRJLTagnu29////91uojjjjjjpw3885xqjdVOHOVciqx4//////5zurrrrrru06/+2vngbTMJQYfksz7//////+50zzzzzz16//70slfYRJLTagnu29////////86666668///5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5xqjdVOHOVciqx4///////////////////+2vngbTMJQYfksz7///////////////////70slfYRJLTagnu29///////////////////5yqjdVOHOVciqx4///////////////////+3vogbTMMQYfksz7///////////////////80tlfYUUUUagnu29///////////////////80skdcccccdiqx4////////////////////81tnjjjjjjjnt07/////////////////////4ytrrrrrrrty4+/////////////////////940zzzzzzz049///////////////////////+766666667+//////////////////////////////////////////////////" },
    ["8"] = { 37, 51, -5.00, -5.67, 27.59, "////////////////////////////////////////////////////9888888+//////////////////////////86310000002469/////////////////////941ywussssstuxz26+//////////////////62yuromkkkkklnpsvz38////////////////60vrnjiffddddfgikptx38//////////////60upkgdbZXWWWWYacfimsx38////////////71vpjfbXURPOOOOQSVZdgmsx3+//////////+3wqkfZVQMKMOOONLLOSWcgmtz6//////////6ztmfaUPKLPTVWWUSOJLRWdiov29////////+3wpidWPJLRWadddcZUPJLSYfksz6////////80tmfZSLJQWcgjkkifaUNHOVcipw4////////6zrjdWPHNUbgmqsrpkfYSLKSZgmu19///////4xpicUMJQYfkrx0zvoicVNIPXfks08///////4wogaTLLSagnu276zskfXPHOWdjrz6///////4wogaSKLTbipx4/91tlfYQJMUcjrz6///////4wogaSKLTbipx5/+2vnfYQJMUcjrz6///////4wogaSLLTbipx4/91tlfYQJOVdjrz6///////4xpibUMLSagnu286zskfXPHPXdks07///////6yrjdWOJQYfkrx0zvpicVNKRZgmt19///////80tlfZSLNUbgmqsspkfZSLOVciow3////////+3wpicVPJQWcgjkkifaUOMSYfksz6/////////6zslfaUPLRWbdddcZUPNSXdiov29/////////+3wqkfaVPLQTWWWVSOLSYdintz6///////////71vqkfYQJJMOOONLIMUcinty4+//////////+3wrlfcWPKOSUUUTRNMTZdintz6//////////6zsmfbVRLQVZbccbYTOOTYdipv29////////+3voicWQLPVbgijjgdZTNNSZfksz6////////70slfYRLMTagkprqnjdYRKOVciow3////////5yqjdVOIPWdjqvyyunibUNKRZgmt18///////4wogbTMKSZgmt165yrkdXPHPWdkrz7//////+2vnfZSKLTbgow4/91tlfYQJNUcjqy5//////91tlfYQJMTbipx5/+2vnfYQJMTbipx5//////91tlfXPHMUcjqy6/+2vnfYQJLTbipx5//////91tlfXPHMUcipx5/+2vnfYQJLTbipx5//////91tlfYQILTbipw4/91tmfYQJLTbipx5//////+2unfYRJKSagnu296zskfXPHMUcipx5///////3vogbTLIQXfkry10vpicVNHOWdjrz6///////5xqicVOGNUbgnsttqkfZSKJRYflt08///////7zskfYRKJQXdgklljfaUOHNUbgov2+///////92ungbVOIMSXcfffdaUPJLRYfkry5/////////5yrkfZTNJMRVXYXWTPJLQWcinu29/////////92vpjdYTPLKNPQQOMJNRVbgmsy5///////////60uoifaWTQOMMMNORTYcglrw39////////////5ztojgdaXWUTUUWYbdglrw27/////////////+5zuqmigfdcbbcdfgjnsw27///////////////+61wtqnkjjiijklnquy37//////////////////730xusrqpprrtvy159////////////////////+7420zyxxyz0258/////////////////////////986555678+//////////////////////////////////////////////////" },
    ["9"] = { 37, 50, -5.00, -5.33, 27.36, "///////////////////////////////////////////////////98766688+/////////////////////////96420zzzz01247/////////////////////+62zwussrrrstvx047//////////////////83zvspnlkjjjklnqtx16////////////////83xtokiffdccddfgjmqu06//////////////93xsmifcZXWVUWWYadgjpu06////////////+4ysmgdYVSQONMOPRTWafjpu07///////////70tngcWSOKLNOPONKMPTZfjqw3+/////////+3wpidXRLINSVWXWURNJOTaglsz6/////////70tmfZSMIOTYcdfdcYSNIPVcipw3/////////5yqjdWPIMTZfiklkidYSLLSZgmt18////////3vogbTMJQXdjossrnidWPIPWdjry6///////91tmfYRJLTagnuz0ytmfZSKMUbiow3///////80skfXPHNUcipx483woibTMKRZgnu29//////7zrkdWOGOWdkrz6/6yqjcUNIQXflt19//////6zrjcUNHPXfks08/7zrkdWOHPXfks08//////6zrjcUMHPXflt19/80skdWOGOWdks08//////6zrjcUMHPXflt19/80skdWOGOWdks08//////6zrjcVNHPXfls08/6zrjdWOGOWdks08//////7zskdWOHOWdksz7/5yqjcUMGOWdks08//////80slfXQINVciqx493wogbTMGOWdks08//////92ungaSLLTagnuz1ztmfZRKGOWdks08///////4wpicVNJQXdjostsoidWPHGOWdks08///////6zskfYQJMTZfiklkidYSLEGOWdks08///////92ungbUNIOTYcffdcYSNHBGOWdks08////////4xqkfYSMINSVXXXVRPPMGGOWdks08////////81uoidXSOLLNPPPNSWWSLGOWdks08/////////5ztnidZVSQPOPRTYddVOGOWdks08/////////+4ytnifcaYXWXYbfidWOGOWdks08/////////864ytpligfddfggjkdWOGOWdks08////////61yxxxwspnlkkkloqkdWOGOWdks08///////81vqppppppqtssstvskdWOGOWdks08///////5xqkiiiiiijqx0010skdWOGOWdks08///////4wogbbbbbbgow4880skdWOGOWdks08///////4wogaTTTTagow3/7zskdWOGOWdks08///////4woibTLLRZgmu164xqjcVNHPXdks08///////5xpibUMIPXdjqwyxtngbTMIQXflt19///////6yrjdVOHMTbglprpmidXQJKSZgnu29///////70slfYRKJQVbfijifdYSMHOVcipw4////////+2voicVPIKQVZbccaWSNHLSYfksz6/////////6zskfZTOJKOSUUUTPMIMRWdiov29/////////92vpjfZUQMKKMMMLJMPSXcgmtz6///////////60upjfbXUSQPOPPRTWZdgmsx3+////////////60upkgdbZYXWXXYbdginsx38//////////////60vrnjigffddfggjmpty38////////////////62xuronlkkklmoqtw049//////////////////841ywutssstuvx037//////////////////////8642100011357+//////////////////////////+988899///////////////" },
    ["&"] = { 46, 51, -5.00, -5.50, 36.20, "//////////////////////////////////////////////////////////////+888889+///////////////////////////////////9642100001247+//////////////////////////////+62zxutsssstvxz36+///////////////////////////94zvspnlkkkklnpswz48/////////////////////////83ytpkiffddddfgilptx38///////////////////////93xsnifcaYWWWXYacfimsx38//////////////////////4ysmgdZVSQPOOPQSVZdgmsx3+////////////////////70tngcXSOLIKLLLJLOSWcgmtz6////////////////////4wpjdXRMHLPSTTSQMIMRWdiov29//////////////////81tmfZTMGMSWZbbaXTOILSYfksz6//////////////////6zrjdWPILRXdgiigdZTNHOVcipx4//////////////////5xpicUMHOVcimopnjfYRJLSagnv3+/////////////////4wogbTLJRYglswxuogbTMJQYgmt19/////////////////4wogaSKKSagov34yqjcUMHPXflt19/////////////////4wogaTLKSagow36yrjcUMIPXflt19/////////////////4xpibUMKRZgmt02voibUMJQYgmu19/////////////////6yrjdWPHPWdjpwxrkfZRKLSagnv3+/////////////////80tmfZSLMTZflsrmgbVOHOVcipx4//////////////////+3wpidWPJPVcgnlgcWQKLRYfksz6///////////////////6ztmgaTNKRXdifbWRLJQWciov29///////////////////+3wqjfYSLMSYdaVQLJPUbgmsz6/////////////////////71uoidWQKNSWTPKLQUagkrw3+//////////////////////5ztmgbVOHMOMJMRWbgkqv27//////////////////////94ytpkfXPHFGGNSXcgkqv16//+///////////////////94ytnifaUOGBAIQYdgmrv16+63247////////////////+4ytnidZUPJIJHIQYfjpv16/5zwvx149//////////////5ztnidXSOJMQQOJNTZfkqw260tpnquy26+///////////70uoidXSMINSXYUPIPUaglrx2wpigjnrvz49/////////+3wqjdYSMIOTYdfaTOJPVbgmsyslfadgkoty4/////////70tmfaTNHNTZdijfZSNKQWcintngcVXbfint18////////4xqidWPIMSYfjopidYSLLRXdipjdXRRUYdks08///////+2vngaTLJQXdioutnidWRKMSZfkfZTMNUbgmt18///////81tlfYQJMTbgntzytmgcVQJOUafbVPLSYfkqx4////////80skdWPHOVdjqx43xslgbUPJPUYVQKQWciov18////////80skdWOGOWdks0782wqkfZTNJOQPKOUbgmsz6/////////80skdWOGOWdksz6871vpjfYSMHJHMSZfkqx3+/////////80skdWOHNVcipvz10zwtoidWOGBIQXdipv18//////////80slfXQILSZfkpstsrpmifbVNFBJQYfkrx39//////////92unfZSLIPVbfiklkjifdZUQKIIHOVbgmsy4///////////4wpicVPIKQUZcdffdcZWSOJNQQNKQWcint06//////////6zslfZTOJJOSVWXXWUSPLLPTYYSNLRXdipv17/////////+3wpjdZUQMJLNPPPOMKMPSWafdYSMMSZfkqw29/////////70uoifbWTRPOMMNOPRTWZdgjidXRQQUaglry4//////////5ztpkgdbYXWUUUWXYbdgimqnicYYYYYbgnv3+/////////+50vqmjgfddcccdfggjmptxsmggggggggnv3+///////////61xtqolkjjjjkkmoqtw03xsnnnnnnnnsy4/////////////840yvtsrrrrrstvy03783yvvvvvvvvy39///////////////85310zzzzz01358///953222222349//////////////////+986666789/////////+++++++/////////////////////////////////////////////////////" },
    ["-"] = { 30, 30, -5.00, 14.83, 20.75, "///////////////////////////////////+8888888888888888889/////////83000000000000000000149//////93xtsssssssssssssssssuy4+/////6zsmkkkkkkkkkkkkkkkkknt07/////4woidddddddddddddddddiqx5/////4wogaWWWWWWWWWWWWWWWbipx5/////4wogaSOOOOOOOOOOOOOTbipx5/////4wogaSOOOOOOOOOOOOOTbipx5/////4wogaWWWWWWWWWWWWWWWbipx5/////4woidddddddddddddddddiqx5/////6zsmkkkkkkkkkkkkkkkkknt07/////93xtsssssssssssssssssty4+//////83000000000000000000149////////+8888888888888888888///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
    ["."] = { 23, 18, -5.00, 27.00, 13.79, "////////////////////////////////976679///////////////941zzz026+////////////72yusrrsvz49//////////82wrnkjjkoty4+/////////4xrlgdcdfintz6////////80tmfbXVVYdipw3+///////6yqjdWQNOSZflt18///////5xpibTMFHPWdks08///////5xpibTMFHOWdks08///////5yqjdWPMNSYglt08///////70tmgaWUUYdiov3+///////+3wqkgdccfintz6/////////71vqmjiiknty4+//////////61wtrpqruy49////////////730zxxz259//////////////+865579///////////////////////////////" },
    ["'"] = { 18, 50, -5.00, -5.00, 8.72, "///////////////////////988888889///////+51000000026//////5zusssssssv06////91uokkkkkkkpv2+///80skddddddflt19///80skdWWWWXflt19///80skdWOOQYflt19///80skdWOJQYgnu2+///80slfXPJQYgnv2+///91tlfXPKRZgnv2+///91tlfXPKSagow3////91tmfYQKSagow4////+2vnfYQLTbgow4////+2vnfYQLTbipx5////+2vnfZSPTbipx5/////4wogaXXXcipx5/////4woifffffjrz6/////6ztnlllllpu18/////+4yutttttv06///////9521111126//////////+99999+/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
    ["!"] = { 27, 50, -5.00, -5.00, 17.21, "////////////////////////////////////988888889/////////////////62000000015+//////////////71vsssssssuz5/////////////+3wqkkkkkkkou08////////////91tlfddddddjrz6////////////91tlfXWWWWcjrz6////////////91tlfXPOOVdjrz6////////////91umfYQJOWdks07////////////+2vnfYQJOWdks08////////////+2vnfYQJOWdks08////////////+2vnfYQJOWdks08////////////+2vnfYQJOWdks08////////////+2vnfYQJPWdks08////////////+2vnfZRKPXflt18/////////////3wogaSKPXflt19/////////////4wogaSKPXflt19/////////////4wogaSKPXflt19/////////////4wogaSKPXflt19/////////////4wogaSKQXflt19/////////////4wogaSKQYgnu29/////////////4wogbTLQYgnv2+/////////////5xpibTLQYgnv2+/////////////5xpibTLQYgnv2+/////////////5xpibTLQYgnv2+/////////////5xpibTLRYgnv2+/////////////5xpibTLSagov3//////////////5xpibTMSagow4//////////////5yqjcUMSagow4//////////////6zrjcUQSagow4//////////////6zrjcYYYagow4//////////////7zrkgggggipx4//////////////92vqnnnnnot07///////////////61wvvvvvvz5////////////////+62zxxxz26+///////////////+5zvsqpqsvz5+//////////////5ztokiiikotz5/////////////70uoifcbcfiou07////////////4xqjdYVTVYdjqx4///////////+3vngaTOLOTagnv3///////////+2vnfYQJEJRYgnv2+//////////+2vnfYRJGKRZgnv2+///////////3vogbUPOPUbgow3////////////5yrkfaXWXagkry5////////////92vqkgdddgkqv29/////////////61vqmkkkmqv16///////////////61xusssux16/////////////////741000147////////////////////98889//////////////////////////////////////" },
    ["?"] = { 36, 50, -5.00, -5.50, 25.99, "//////////////////////////////////////////////////98766688+////////////////////////96310zzzz01257////////////////////952zwussrrrstvx047/////////////////72yuromkkjjjklnqtx16+//////////////61wsnkiffdccddfgjmquz5+////////////61vqlgfcZXWVUWWYbdgjotz5///////////71vqkfcYURPONMOPRTWafiou06/////////+3wqkfaVRNKJLMMLJJMPTYdjpv29////////6zslfaUPKJORTUUTROJJNTZfkry5///////+3voicVPJKQUYbbcbYUQKIOVbgnv29//////70slfYSLJQVbfgiigfbVPJKRYfksz7//////5yqjdVOHNUbgkoppokgaTMHOVcjqy5//////4wogbTMJRYfkqvxxvqjdXQIMTbiow4/////+2vnfaSKLTagnu1551unfZSKKSagow4/////+2vnfYQOOTbipx4//4wogaSKKSagow4/////+2vnfYWWWVbipx5//4wogaSKKSagow4/////+3vngddddcdipx5/71unfZSKLTagow4//////4ysmkkkkjjmsz672wqjdXQIMUcipx4//////93xussssrrtx362wrlfaTMIPWdjrz6///////841000zzz0360vrlfbVPJMTagmt18/////////988876675zupkfbVQKLRXdjqx4////////////////+5ztojfbVQKLRWcgnt07////////////////6ztoifZUQKMRWcgmsy4////////////////81vpidYTPJNSXcgmsx39////////////////4xqkfZSNIOTYdimsx38////////////////92ungbUOIOTZfinsx38/////////////////7zskfXQJMSZfjoty38//////////////////5xqicVNHPWdipuz49///////////////////5xpibTLJRYgmt06+////////////////////5xpibTLKSagnv3//////////////////////5xpibTSSSagow4//////////////////////5xpibaaaaagow4//////////////////////6yqkggggggjpx4//////////////////////81vqoooooopu07///////////////////////61xwwvvwwx06////////////////////////60vronnorv06///////////////////////70upkgffgkpu06/////////////////////+3wpjfbZZbfjpw3+////////////////////80tlfZURRUZfls07////////////////////6zrjdWPKKOVdjrz6////////////////////6zrjcUMFFMUcjrz6////////////////////6zrjdWPJJOVdjrz6////////////////////80tlfZTRRTZgls07////////////////////+3wpjfbYYbfjpw3+/////////////////////70upjggggjou06///////////////////////60uqnnnnquz5/////////////////////////61xvvvvx16+//////////////////////////85322358///////////////////////////////++//////////////////" },
    ["/"] = { 33, 50, -5.00, -5.00, 23.77, "///////////////////////////////////////////////////988888889///////////////////////62000000015+////////////////////60vsssssssuz5///////////////////92vpkkkkkkkou2+//////////////////6zskfdddddflt19//////////////////4xpicWWWWZgmu19/////////////////92unfaSOOUcipw4//////////////////6zskfXQIPXdkrz6//////////////////4xpicVNKSZgmu19/////////////////92unfaSLNUcipw4//////////////////6zskfXQIPWdkrz6//////////////////4xpicVNKRZgmt18/////////////////92unfaSLMUbiow3//////////////////6zskfXQIPWdjry6//////////////////4xpicVNKRZgmt18/////////////////92unfaSLMUbiow3//////////////////6zskfXQIPWdjry6//////////////////4xpicVNKRZgmt18/////////////////92unfaSLMUbiow3//////////////////7zskfXQIPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOKRZgmt18/////////////////92ungaTLMUbiow3//////////////////7zskfYQJPWdjry6//////////////////4xqicVOJRYgmt18/////////////////92ungaTLMTbgov3//////////////////7zskfYQJOWdjqy5//////////////////4xqicVOMRYglt08/////////////////+2ungaUUUUbgov3+/////////////////91tlfcccccdjqy5//////////////////+2vpjjjjjjjou08///////////////////60urrrrrrruz5/////////////////////61zzzzzzz05+//////////////////////866666668////////////////////////////////////////////////////" },
    ["+"] = { 36, 39, -5.00, 5.67, 26.51, "//////////////////////////////////////////////////97666668///////////////////////////72zzzzzz05+////////////////////////82wsrrrrruz5////////////////////////5xrljjjjjou19///////////////////////4wogccccdks08///////////////////////4wogaUUWdks08///////////////////////4wogaSOWdks08///////////////////////4wogaSOWdks08///////////////////////4wogaSOWdks08////////////////+7666664wogaSOWdks06666668/////////73zzzzzzzwogaSOWdkszzzzzzz15+//////92wsrrrrrrrogaSOWdkrrrrrrrruz5//////5yrljjjjjjjjgaSOWdjjjjjjjjjou19/////4wogcccccccccXRNUaccccccccdks08/////4wogaUUUUUUUURMJPTUUUUUUUWdks08/////4wogaSMMMMMMMLGEJMMMMMMMOWdks08/////4wogaSSSSSSSSPKHNRSSSSSSSWdks08/////4wogaaaaaaaaaVPMSYaaaaaaaadks08/////4xqjgggggggggaSOWdgggggggggmt08/////70upoooooooogaSOWdkoooooooosx3+//////60xwwwwwwwogaSOWdkswwwwwwwy38////////74444444wogaSOWdks044444459////////////////4wogaSOWdks08///////////////////////4wogaSOWdks08///////////////////////4wogaSOWdks08///////////////////////4wogaTTWdks08///////////////////////4wogbbbbdks08///////////////////////4xpjiiiiimt08///////////////////////70uqpppppsx3+////////////////////////60yxxxxxz38//////////////////////////755555569/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////" },
  },
}
-- GLYPHS END
