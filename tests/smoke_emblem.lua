-- SMOKE: the agency's emblem (scripts/emblem.lua), offline.
--
--   * the same name always gives the same emblem; different names, different
--   * the monogram rule ("Solar Exploration Agency" → "SEA"; one-word names)
--   * every curated palette passes the contrast check
--   * a spec round-trips through the save (clean), and junk is made safe
--   * pictures: a PNG (through a stored-block inflate) and a baseline JPEG
--     decode to the right colours; a progressive JPEG is refused with a why
--   * a missing custom picture falls back to the generated emblem, once noted
--   * an older save is migrated to the default name with a rename prompt
--   * the editor's rows are elements ui.make accepts; typing follows the name
--   * every motif is cut to every shape (nothing outside the emblem), and
--     the flag is the emblem on its field; drawn through the Lua port of
--     image.* (tests/lib/image_shim.lua)
--   * build time (offline, warm) is recorded
--
--   luajit solar/tests/smoke_emblem.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function load(path, env)
  local chunk = assert(loadfile(path))
  setfenv(chunk, setmetatable(env, { __index = _G }))
  chunk()
  return env
end

-- image.* is the engine's; offline, its Lua port draws the same pictures
local IMAGE = dofile("solar/tests/lib/image_shim.lua")
local E = load("solar/scripts/emblem.lua", { image = IMAGE })

-- ── names ───────────────────────────────────────────────────────────────────
check(E.monogram("Solar Exploration Agency") == "SEA", "SEA: " .. E.monogram("Solar Exploration Agency"))
check(E.monogram("United Federation of Planets") == "UFP", "stop words skipped: " .. E.monogram("United Federation of Planets"))
check(E.monogram("NASA") == "NASA", "a short single word is kept whole")
check(E.monogram("Vostok") == "V", "a long single word gives its initial")
check(E.monogram("Agence Spatiale Européenne") == "ASE", "accents fold: " .. E.monogram("Agence Spatiale Européenne"))
check(E.monogram("Station 9") == "S9", "digits count")
check(E.monogram("The Fourth Rock Space Corps") == "FRS", "three initials at most: " .. E.monogram("The Fourth Rock Space Corps"))
check(E.cleanName("   ") == E.DEFAULT_NAME, "an empty name is the default")
check(#E.cleanName(string.rep("x", 60)) == 32, "names stop at 32 characters")
check(E.cleanName("  Kestrel   Aerospace ") == "Kestrel Aerospace", "spaces are tidied")

-- ── the same name, the same emblem ──────────────────────────────────────────
local a1, a2 = E.specFor("Kestrel Aerospace"), E.specFor("kestrel  aerospace")
check(a1.seed == a2.seed and a1.shape == a2.shape and a1.motif == a2.motif and a1.palIndex == a2.palIndex,
  "the same name (any case or spacing) gives the same spec")
local px1 = E.rasterEmblem(a1, "Kestrel Aerospace")
local px2 = E.rasterEmblem(E.specFor("Kestrel Aerospace"), "Kestrel Aerospace")
check(#px1 == 256 * 256 * 4 and px1 == px2, "...and the same pixels")
local names = { "Solar Exploration Agency", "Kestrel Aerospace", "Northern Lights Space Command", "Vostok",
  "United Federation of Planets", "Orbital Dynamics & Freight", "Bluebird Rocketry", "Deep Sky Mining Co.",
  "Ad Astra Collective", "Station 9", "Polaris Works", "Copper Moon Institute" }
local sigs, shapes, motifs, pals = {}, {}, {}, {}
for _, n in ipairs(names) do
  local s = E.specFor(n)
  sigs[s.shape .. s.motif .. s.palIndex .. s.font] = (sigs[s.shape .. s.motif .. s.palIndex .. s.font] or 0) + 1
  shapes[s.shape], motifs[s.motif], pals[s.palIndex] = true, true, true
end
local distinct = 0
for _ in pairs(sigs) do distinct = distinct + 1 end
check(distinct >= 10, "different names give different emblems (" .. distinct .. " of 12 distinct)")
local ns, nm, np = 0, 0, 0
for _ in pairs(shapes) do ns = ns + 1 end
for _ in pairs(motifs) do nm = nm + 1 end
for _ in pairs(pals) do np = np + 1 end
check(ns >= 4 and nm >= 4 and np >= 5, string.format("names reach the variety (%d shapes, %d motifs, %d palettes)", ns, nm, np))
local r1 = E.regenerate(a1, "Kestrel Aerospace")
check(r1.seed ~= a1.seed, "↻ steps the seed")
check(E.tweak(a1, "shape", 1).shape ~= a1.shape and E.tweak(E.tweak(a1, "shape", 1), "shape", -1).shape == a1.shape,
  "◂ ▸ step the shape and back")
local p2 = E.tweak(a1, "pal", 1)
check(p2.palIndex ~= a1.palIndex and p2.pal.bg[1] == E.PALETTES[p2.palIndex].bg[1], "a palette step repaints all four colours")
local c2 = E.setColour(a1, "accent", { 0.1, 0.9, 0.2 })
check(c2.pal.accent[2] == 0.9 and c2.palIndex == nil, "a colour picked by hand sticks")

-- ── palettes ────────────────────────────────────────────────────────────────
for i, p in ipairs(E.PALETTES) do
  local ok, why = E.paletteOk(p)
  check(ok, string.format("palette %d (%s) reads: %s", i, p.name, tostring(why)))
end
check(not E.paletteOk({ bg = { 0.5, 0.5, 0.5 }, ring = { 0.52, 0.5, 0.5 }, fg = { 0.55, 0.5, 0.5 }, accent = { 0.5, 0.5, 0.5 } }),
  "a muddy palette is flagged")

-- ── the save ────────────────────────────────────────────────────────────────
local s0 = E.specFor("Polaris Works")
s0.image = "user://emblems/logo.png"
local back = E.clean(s0, "Polaris Works")
check(back.shape == s0.shape and back.motif == s0.motif and back.seed == s0.seed and back.image == s0.image
  and back.pal.ring[2] == s0.pal.ring[2] and back.mono == s0.mono, "a spec round-trips through the save")
local junk = E.clean({ shape = "blob", motif = 7, pal = { bg = "red" }, image = "/etc/passwd", seed = 5 }, "Polaris Works")
check(E.SHAPE_LABEL[junk.shape] and E.MOTIF_LABEL[junk.motif] and type(junk.pal.bg) == "table" and junk.image == nil,
  "junk in the save is made safe")
check(E.clean({ image = "user://emblems/../x.png" }, "A").image == nil, "a path out of the folder is refused")
local holds_pixels = false
for k, v in pairs(back) do if type(v) == "string" and #v > 200 then holds_pixels = true end end
check(not holds_pixels, "the spec holds no pixels")

-- ── pictures ────────────────────────────────────────────────────────────────
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function unb64(s)
  local out, bits, n = {}, 0, 0
  for c in s:gmatch("[%w%+/]") do
    bits = bits * 64 + (B64:find(c, 1, true) - 1)
    n = n + 6
    if n >= 8 then
      n = n - 8
      local b = math.floor(bits / 2 ^ n)
      out[#out + 1] = string.char(b)
      bits = bits - b * 2 ^ n
    end
  end
  return table.concat(out)
end
local function be32(v) return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256) end
-- a PNG of 4×3 RGBA, its zlib stream one STORED deflate block
local raw = {}
for y = 0, 2 do
  raw[#raw + 1] = string.char(0)   -- filter none
  for x = 0, 3 do raw[#raw + 1] = (x < 2) and string.char(250, 20, 10, 255) or string.char(10, 30, 240, 128) end
end
raw = table.concat(raw)
local zl = string.char(0x78, 0x01, 0x01) .. string.char(#raw % 256, math.floor(#raw / 256), 255 - #raw % 256, 255 - math.floor(#raw / 256)) .. raw .. "\0\0\0\0"
local function chunk(t, d) return be32(#d) .. t .. d .. "\0\0\0\0" end
local png = "\137PNG\r\n\26\n" .. chunk("IHDR", be32(4) .. be32(3) .. string.char(8, 6, 0, 0, 0)) .. chunk("IDAT", zl) .. chunk("IEND", "")
local function stored_inflate(z)
  local len = z:byte(4) + z:byte(5) * 256
  return z:sub(8, 7 + len)
end
local img, why = E.decodePng(png, stored_inflate)
check(img and img.w == 4 and img.h == 3, "a PNG decodes: " .. tostring(why))
if img then
  check(math.abs(img.R[1] - 250 / 255) < 0.01 and math.abs(img.B[4] - 240 / 255) < 0.01 and math.abs(img.A[4] - 128 / 255) < 0.01,
    "...to its colours and alpha")
end
local jpg = unb64("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCAAQABgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5brl/iT/y5f8AbT/2Wuorl/iT/wAuX/bT/wBlryvo7f8AJ48s/wC43/qPVP7Z+kT/AMmczP8A7g/+pFI5eiiiv9QT/L4//9k=")
local j, jwhy = E.decodeJpeg(jpg)
check(j and j.w == 24 and j.h == 16, "a baseline JPEG decodes: " .. tostring(jwhy))
if j then
  local L = j.R[16 * 0 + 3 + 1] * 255
  local Rb = j.B[8 * 24 + 20 + 1] * 255
  check(L > 160 and j.B[3 + 1] * 255 < 80, string.format("...its red half is red (%.0f)", L))
  check(Rb > 160 and j.R[8 * 24 + 20 + 1] * 255 < 80, string.format("...its blue half is blue (%.0f)", Rb))
  local sq = E.imageToBuf(j, 64)
  check(sq.w == 64 and sq.h == 64, "a picture is centre-cropped to a square emblem")
end
local pj, pwhy = E.decodeJpeg(unb64("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAAQABgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAWAQEBAQAAAAAAAAAAAAAAAAAABgf/2gAMAwEAAhADEAAAAYgSm2Af/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQABBQJf/8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAwEBPwE//8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAgEBPwE//8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQAGPwJf/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQABPyFf/9oADAMBAAIAAwAAABD77//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QP//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QP//EABQQAQAAAAAAAAAAAAAAAAAAACD/2gAIAQEAAT8QX//Z"))
check(pj == nil and tostring(pwhy):find("progressive"), "a progressive JPEG is refused with a reason: " .. tostring(pwhy))
check(select(2, E.decodeImage("GIF89a....")) ~= nil, "anything else is refused")

-- ── the service: a missing picture falls back ───────────────────────────────
local SAVE = { g_seed = 5 }
local made = {}
local S = load("solar/scripts/emblem.lua", {
  image = IMAGE,
  save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end },
  assets = {
    textureFromPixels = function(w, h, px) made[#made + 1] = { w, h, #px } return "img:" .. #made end,
    readBytes = function(p) return nil, "no such file" end,
    release = function() end,
  },
  log = function() end,
})
-- an older save: no agency yet
S.reload()
check(SAVE["agency.name"] == "Solar Exploration Agency" and SAVE["agency.prompt"] == true,
  "an older save is named the Solar Exploration Agency, with a prompt to rename")
check(type(SAVE["agency.emblem"]) == "table" and SAVE["agency.emblem"].shape ~= nil, "...and gets the generated emblem")
check(S.tex() ~= nil and S.flagTex() ~= nil and made[1][1] == 256 and made[2][1] == 512 and made[2][2] == 341,
  "the emblem (256²) and the flag (512×341) are built")
local v0 = S.version
local sp = S.specFor("Polaris Works")
sp.image = "user://emblems/gone.png"
S.set("Polaris Works", sp)
check(S.version == v0 + 1 and S.name() == "Polaris Works", "a new identity bumps the version")
check(S.noticeText() and S.noticeText():find("generated emblem"), "a missing picture says so once and uses the generated one")
check(SAVE["agency.prompt"] == false, "naming it clears the prompt")
check(SAVE["agency.emblem"].image == "user://emblems/gone.png", "the save keeps the picture's path (it may come back)")
check(S.migrate() == false, "migration runs once")
check(S.lastBuildMs ~= nil, "the build time is measured")

-- ── the editor ──────────────────────────────────────────────────────────────
local PROPS = {}
for p in ([[align border borderB borderColor borderL borderR borderT button case cell cols
  count dir disabled draggable dropTarget field fill fillA fillB fillG fillR flip focusable
  font frame frameSlice frameUV gap group groupA groupB groupG groupR groupTint h height image
  imageFit inset interact justify lineHeight margin mask max maxH maxLen maxLines maxW min minH
  minW numeric opacity order overflow pad part pin pivot placeholder pos posX posY radius
  radiusBL radiusBR radiusTL radiusTR rotation rows scale scaleX scaleY scrollDrag scrollSpeed
  scrollX scrollY scrollbarAxis scrollbarFor selected shader size slice sliderDir stretch style
  template text textA textAlign textB textColor textFit textG textR textSize textValign texture
  tiling tint tintA tintB tintG tintR toggle tooltip tooltipBox tracking upper value visible w
  width wrap x y navUp navDown navLeft navRight]]):gmatch("%S+") do PROPS[p] = true end
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local bad = {}
local function validate(el, path)
  if type(el) ~= "table" then return end
  if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = path .. ": kind " .. el[1] end
  for k in pairs(el) do
    if type(k) == "string" and not (PROPS[k] or k == "key" or k == "name" or k == "items" or k:match("^on%u")) then
      bad[#bad + 1] = path .. ": property " .. k
    end
  end
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then validate(el[i], path .. "/" .. tostring(el[i].key or i))
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then for i, it in ipairs(el.items) do validate(fn(it, i), path .. "/" .. i) end end
end
local ed = E.newEditor(nil, nil)
check(ed.name == E.DEFAULT_NAME and ed.typed == "", "a new agency starts as the default, the field empty")
for _, r in ipairs(E.editorRows(ed, 330)) do validate(r, "ed") end
ed.pick = "accent"
for _, r in ipairs(E.editorRows(ed, 330)) do validate(r, "ed+chips") end
ed.mode = "files"; ed.files = { "user://emblems/a.png" }
for _, r in ipairs(E.editorRows(ed, 330)) do validate(r, "ed+files") end
check(#bad == 0, "every editor element is one ui.make accepts: " .. table.concat(bad, ", "))
ed.mode = "gen"
E.editorSetName(ed, "Copper Moon Institute")
check(ed.spec.seed == E.specFor("Copper Moon Institute").seed and ed.spec.mono == "CMI", "typing a name regenerates its emblem")
ed.spec = E.tweak(ed.spec, "shape", 1); ed.tweaked = true
local shape = ed.spec.shape
E.editorSetName(ed, "Copper Moon Works")
check(ed.spec.shape == shape and ed.spec.mono == "CMW", "after a tweak, a new name changes only the monogram")

-- ── the picture: every shape cuts every motif to itself ─────────────────────
-- A motif is drawn in a layer and cut to its field; nothing of it may show
-- outside the emblem (the rocket's trail and the swooshes are big crescents
-- that reach the corners when uncut).
local leaks = {}
for _, shape in ipairs(E.SHAPES) do
  for _, motif in ipairs(E.MOTIFS) do
    local s = E.specFor("Polaris Works")
    s.shape, s.motif = shape, motif
    local _, img = E.rasterEmblem(s, "Polaris Works", 96)
    local function alpha(x, y) return select(4, img:getPixel(x, y)) or 0 end
    local out = { { 0, 0 }, { 95, 0 }, { 0, 95 }, { 95, 95 }, { 2, 2 }, { 93, 2 }, { 2, 93 }, { 93, 93 } }
    if shape == "roundel" or shape == "patch" then
      -- outside the rim (r 126.2 units, 47.3 px) and its smooth edge
      for i = 0, 15 do
        local a = (i + 0.5) * math.pi / 8
        out[#out + 1] = { 47.5 + math.cos(a) * 49, 47.5 + math.sin(a) * 49 }
      end
    end
    local bad = 0
    for _, p in ipairs(out) do if alpha(p[1], p[2]) > 0 then bad = bad + 1 end end
    if bad > 0 or alpha(48, 48) < 0.99 then leaks[#leaks + 1] = shape .. "/" .. motif end
  end
end
check(#leaks == 0, "every motif stays inside every shape, and the middle is solid: " .. table.concat(leaks, ", "))
local px96 = E.rasterEmblem(E.specFor("Vostok"), "Vostok", 96)
local px48 = E.rasterEmblem(E.specFor("Vostok"), "Vostok", 48)
check(#px96 == 96 * 96 * 4 and #px48 == 48 * 48 * 4, "a slot card's small emblem, worn and unworn")
local fpx, fimg = E.rasterFlag(E.specFor("Vostok"), "Vostok", px1)
check(#fpx == E.FLAG_W * E.FLAG_H * 4 and fimg.width == E.FLAG_W, "the flag takes the emblem's pixels")
local P0 = E.specFor("Vostok").pal
local r, g, b = fimg:getPixel(E.FLAG_W - 4, 4)
check(math.abs(r - P0.bg[1]) < 0.01 and math.abs(g - P0.bg[2]) < 0.01, "...on a field of the emblem's own colour")

-- ── the build time (offline, through the Lua image shim; the engine's own
-- is measured by tools/perf/emblemprobe.sh) ─────────────────────────────────
local t0 = os.clock()
for _ = 1, 3 do
  local p = E.rasterEmblem(E.specFor("Northern Lights Space Command"), "Northern Lights Space Command")
  E.rasterFlag(E.specFor("Northern Lights Space Command"), "Northern Lights Space Command", p)
end
local ms = (os.clock() - t0) * 1000 / 3
check(ms < 2000, string.format("an emblem and its flag build in %.1f ms here (the Lua shim)", ms))

if #failures > 0 then
  print("EMBLEM SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("EMBLEM SMOKE OK — %d checks passed (emblem + flag %.1f ms)", passed, ms))
