-- SMOKE: every glyph the Tracking Station draws on the map is in the fonts
-- it draws them with (docs/tracking-station.md §4.3: a missing glyph draws a
-- box). Reads each built font's cmap (formats 4 and 12) in plain Lua.
--
--   luajit solar/tests/smoke_ui_font.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function u16(s, i) local a, b = s:byte(i, i + 1) return a * 256 + b end
local function u32(s, i) local a, b, c, d = s:byte(i, i + 3) return ((a * 256 + b) * 256 + c) * 256 + d end

-- The set of code points a TrueType/OpenType font maps.
local function cmap_of(path)
  local fh = assert(io.open(path, "rb"))
  local s = fh:read("*a")
  fh:close()
  local n = u16(s, 5)
  local off
  for t = 0, n - 1 do
    local rec = 13 + t * 16
    if s:sub(rec, rec + 3) == "cmap" then off = u32(s, rec + 8) + 1 end
  end
  assert(off, "no cmap in " .. path)
  local has = {}
  local nt = u16(s, off + 2)
  for t = 0, nt - 1 do
    local sub = off + u32(s, off + 4 + t * 8 + 4)
    local fmt = u16(s, sub)
    if fmt == 4 then
      local segx2 = u16(s, sub + 6)
      local ends, starts = sub + 14, sub + 16 + segx2
      local deltas, ranges = starts + segx2, starts + 2 * segx2
      for k = 0, segx2 / 2 - 1 do
        local e, st = u16(s, ends + k * 2), u16(s, starts + k * 2)
        local delta, ro = u16(s, deltas + k * 2), u16(s, ranges + k * 2)
        for cp = st, math.min(e, 0xFFFE) do
          local g
          if ro == 0 then g = (cp + delta) % 65536
          else
            local gi = ranges + k * 2 + ro + (cp - st) * 2
            g = u16(s, gi)
            if g ~= 0 then g = (g + delta) % 65536 end
          end
          if g ~= 0 then has[cp] = true end
        end
      end
    elseif fmt == 12 then
      local ng = u32(s, sub + 12)
      for k = 0, ng - 1 do
        local g0 = sub + 16 + k * 12
        local a, b = u32(s, g0), u32(s, g0 + 4)
        for cp = a, math.min(b, a + 4096) do has[cp] = true end
      end
    end
  end
  return has
end

local function codepoints(str)
  local out = {}
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local c = ch:byte(1)
    local cp
    if c < 0x80 then cp = c
    elseif c < 0xE0 then cp = (c - 0xC0) * 64 + (ch:byte(2) - 0x80)
    elseif c < 0xF0 then cp = ((c - 0xE0) * 64 + (ch:byte(2) - 0x80)) * 64 + (ch:byte(3) - 0x80)
    else cp = (((c - 0xF0) * 64 + (ch:byte(2) - 0x80)) * 64 + (ch:byte(3) - 0x80)) * 64 + (ch:byte(4) - 0x80) end
    out[#out + 1] = { cp = cp, ch = ch }
  end
  return out
end

local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/fleet_view.lua"))
setfenv(chunk, env)
chunk()

local label = cmap_of("solar/fonts/SolarLabel.ttf")
local ui = cmap_of("solar/fonts/SolarUI.ttf")
check(label[65] and ui[65], "the cmap reader reads the fonts (A is mapped)")
-- the map's icons and tags (draw.text, the label face) and the panels' marks
local need = ""
for _, g in pairs(env.GLYPHS) do need = need .. g end
need = need .. "▸▾◂▮▯·×↺✕◎★"
for _, c in ipairs(codepoints(need)) do
  check(label[c.cp], string.format("SolarLabel carries %s (U+%04X)", c.ch, c.cp))
  check(ui[c.cp], string.format("SolarUI carries %s (U+%04X)", c.ch, c.cp))
end

if #failures == 0 then
  print(string.format("UI FONT SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("UI FONT SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
