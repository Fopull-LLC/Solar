-- BUILDER_STATUSBAR — the CRT strip along the bottom of the Vehicle Assembly
-- (docs/builder-design.md §4.4; WP2), and the hint line under it.
--
--   ▐ PARTS 312 ▐ MASS 18.40 t ▐ ΔV 1 240 m/s ▐ TWR 1.42 ▐ MARGIN +6 % ▐ COST $12 400 ▐ 3.1 ms ▐
--   hint: drag to move · Alt+drag moves only this · RMB for its menu          [?] KEYS
--
-- Live figures are phosphor numbers on a screen (hud/instrument, hud/value*):
-- they are the builder's stats() (cached per craftVersion), plus whatever the
-- aircraft package adds (builder_aero.statusFigures() → { {label, value, warn} }).
-- The last figure is the builder's own frame cost, caution yellow over 4 ms.
-- While a craft is loading, the strip shows its progress instead.
--
-- The hint line is the builder's hint bar: builder.hintText() when it has
-- one, else the legacy BuildHint node's text (that node is hidden here; the
-- builder still writes to it). A line starting ⚠ prints in caution yellow.
-- PLACARDS: showPlacard(msg, kind, secs) puts a riveted tag above the strip
-- ("error" red title, "warn" yellow, "info" plain) — the builder's placard()
-- can forward here.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local st = { sig = nil, t = 0, placard = nil, legacy = nil, hidden = false }

function showPlacard(msg, kind, secs)
  st.placard = { msg = tostring(msg), kind = kind or "info", until_t = (time or 0) + (secs or 3.0) }
  st.sig = nil
end

local function group(n)
  local s = string.format("%d", math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^%s+", ""))
end

-- The figures, as data: { { key, label, value, tone } } — tone nil | "warn" |
-- "danger" | "dim".
function figures(B)
  local out = {}
  local function add(k, label, value, tone) out[#out + 1] = { key = k, label = label, value = value, tone = tone } end
  local lp = B.loadProgress and B.loadProgress() or nil
  if lp and lp.total and lp.total > 0 then
    add("load", "LOADING", string.format("%d / %d", lp.done or 0, lp.total), "warn")
    return out
  end
  local s = B.stats and B.stats() or {}
  local n = s.parts or 0
  add("parts", "PARTS", group(n), n >= 3000 and "danger" or (n >= 1000 and "warn" or nil))
  add("mass", "MASS", string.format("%.2f t", s.mass or 0))
  add("dv", "ΔV", group(s.dv or 0) .. " m/s", (n > 0 and (s.dv or 0) <= 0) and "dim" or nil)
  local twr = s.twr or 0
  add("twr", "TWR", string.format("%.2f", twr), (n > 0 and twr > 0 and twr < 1) and "warn" or nil)
  local A = ref("builder_aero")
  if A and A.statusFigures then
    for i, f in ipairs(A.statusFigures() or {}) do add("a" .. i, f.label or f[1], f.value or f[2], f.warn and "warn" or f.tone) end
  end
  local co = ref("company")
  add("cost", "COST", (co and co.money) and co.money(s.cost or 0) or ("$" .. group(s.cost or 0)))
  local ms = B.frameMs and B.frameMs() or nil
  if not ms and perf and perf.scriptMs then
    local ok, v = pcall(perf.scriptMs, "builder")
    if ok and type(v) == "number" then ms = v end
  end
  if ms then add("ms", "BUILDER", string.format("%.1f ms", ms), ms > 4 and "warn" or "dim") end
  return out
end

local TONE = { warn = "hud/valueWarn", danger = "hud/valueDanger", dim = "hud/valueDim" }

-- The hint text, and whether it is a warning.
local function hint_text(B)
  local t
  if B.hintText then t = B.hintText() end
  if not t then
    if st.legacy == nil then st.legacy = (find and find("BuildHint")) or false end
    if st.legacy and st.legacy.valid ~= false then t = st.legacy.text end
  end
  t = t or ""
  return t, t:find("^⚠") ~= nil
end

-- The legacy header and hint nodes this strip replaces (the scene still
-- carries them until WP6 strips them; the builder keeps writing to them).
local function hide_legacy()
  if st.hidden or not find then return end
  for _, nm in ipairs({ "BuildTitle", "BuildHint" }) do
    local n = find(nm)
    local e = n and n:getcomponent("UiElement")
    if e then e.visible = false end
  end
  st.hidden = true
end

local function layout(W, H)
  local tb = ref("builder_toolbar")
  if tb and tb.builderLayout then return tb.builderLayout(W, H) end
  return { W = W, H = H, status = { x = 8, y = H - 52, w = W - 16, h = 44 } }
end

function describe(B, L)
  local r = L.status
  local cells = {}
  for i, f in ipairs(figures(B)) do
    if i > 1 then cells[#cells + 1] = { "box", key = "sep" .. i, style = "panel/rule", w = 1, h = 14 } end
    cells[#cells + 1] = { "row", key = f.key, w = "fit", h = 22, gap = 5, pad = 0, align = "center",
      { "text", key = "l", style = "hud/micro", w = "fit", h = 22, text = f.label, textValign = "center" },
      { "text", key = "v", style = TONE[f.tone] or "hud/value", w = "fit", h = 22, text = f.value, textValign = "center" } }
  end
  local hint, warn = hint_text(B)
  local tree = {
    { "col", key = "sb", pin = "topLeft", x = r.x, y = r.y, w = r.w, h = r.h, gap = 2, pad = 0, align = "stretch",
      { "row", key = "crt", style = "hud/instrument", w = "100%", h = 26, gap = 12, pad = 0, align = "center",
        justify = "start", { "box", key = "padl", w = 4, h = 1 },
        { "row", key = "cells", w = "grow", h = 22, gap = 12, pad = 0, align = "center", items = cells,
          function(x) return x end } },
      { "row", key = "hintrow", style = "hud/card", w = "100%", h = 16, gap = 8, pad = 0, align = "center",
        { "box", key = "padl", w = 2, h = 1 },
        { "text", key = "hint", style = warn and "panel/hintWarn" or "hud/hint", w = "grow", h = 16, text = hint,
          maxLines = 1, overflow = "ellipsis", textValign = "center" },
        { "button", key = "keys", style = "panel/secondary", w = 64, h = 16, text = "? KEYS", textAlign = "center",
          textValign = "center", tooltip = "Every key   ·   ?",
          onClicked = function() local tb = ref("builder_toolbar"); if tb then tb.keysOpen = not tb.keysOpen end end } } },
  }
  local p = st.placard
  if p and (time or 0) < p.until_t then
    tree[#tree + 1] = { "col", key = "placard", style = "hud/toast", pin = "bottom", y = -(L.H - r.y) - 8, w = "fit",
      h = "fit", gap = 2, pad = 10, align = "center",
      { "text", key = "t", style = p.kind == "error" and "hud/captionTitle" or "hud/task", w = "fit", h = "fit",
        text = p.msg, maxW = 520, wrap = true } }
  end
  return tree
end

-- ── panel plumbing ──────────────────────────────────────────────────────────
local LAST = { L = nil }
function ownsMouse()
  local L = LAST.L
  if not (L and camera and camera.screenSize) then return false end
  local sw, sh = camera.screenSize()
  if not (sh and sh > 0) then return false end
  local mx, my = input.mouse()
  local x, y = mx * L.H / sh, my * L.H / sh
  local r = L.status
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local el, registered = nil, false
function start(node) el = node.getcomponent and node:getcomponent("UiElement") or nil end

function update(node, dt)
  local B = ref("builder")
  if not B then return end
  if not registered and B.registerPanel then registered = B.registerPanel(findScript("builder_statusbar")) end
  hide_legacy()
  if not el then el = node:getcomponent("UiElement") end
  local tb = ref("builder_toolbar")
  local W, H = 1280, 720
  if tb and tb.layerSize then W, H = tb.layerSize() end
  if tb and tb.fitHost then tb.fitHost(el, W, H) end
  local L = layout(W, H)
  LAST.L = L
  st.t = st.t + (dt or 0)
  -- The frame-cost figure ticks; the rest only moves with the craft and the hint.
  local hint = hint_text(B)
  local p = st.placard
  if p and (time or 0) >= p.until_t then st.placard = nil; p = nil end
  local sig = table.concat({ math.floor(W), math.floor(H), tostring(B.craftVersion), hint, p and p.msg or "" }, "|")
  if sig == st.sig and st.t < 0.5 then return end
  st.sig, st.t = sig, 0
  ui.make(node, describe(B, L))
end
