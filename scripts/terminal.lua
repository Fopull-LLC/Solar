-- TERMINAL — a console you walk up to and run the base from.
--
-- (The interaction plan, work/interact/PLAN.md §4, slices S3 and S4; Ty
-- 2026-11-10: "the computers don't really let me do anything".)
--
-- Walk up to a console piece — a Desk Monitor, a Wall Screen, the Reactor
-- Control Console, a Ladder Controller's desk, a Fire Control Console, a
-- ruin's dead terminal — and "Use the console · E" comes up. E opens a CRT
-- screen over the world (the world keeps running): a rail of PAGES on the
-- left, the page on a green screen in two columns, the keys at the foot.
--
--   1–0 / TAB        a page (Shift+TAB back); a pad's bumpers
--   ↑ ↓ ← → ENTER    walk the rows and press (the engine's UI focus: arrows,
--                    the d-pad, Enter / A); the mouse clicks them
--   ESC              back out of a sub-page, then leave (a pad's B)
--   E                leave (a pad's X)
--
-- While it is open the keyboard is the terminal's (input_guard.hold: the
-- crew stands at the desk, the belt and the walker hear nothing), the
-- pointer is free (planet_camera.panel_open asks isOpen()), and walking away
-- (pushed, knocked) or the console going away closes it.
--
-- PAGES ARE DATA. Any script registers one:
--
--     local T = findScript("terminal")
--     T.registerPage("POWER", function(scope, ctx) return rows end,
--       { order = 20, title = "POWER", scopes = { desk = true, reactor = true } })
--
-- `rows` use the SAME ENTRY CONTRACT as the right-click menus
-- (scripts/context_registry.lua: info / meter / toggle / action / slider /
-- sub / header, with `enabled` + `why`, live values as functions), so a page
-- reuses every system's rows and its whyNot/warnOf: a press goes through
-- context_registry.press exactly as a menu row does (a refusal toasts its
-- reason; an `ok, warn` toasts the warning — danger is never refused). Two
-- more row types a CRT can draw: "line" { text, level 0|1|2 } (a phosphor
-- line, amber, red) and "image" { texture (or fn), w, h }. A row may carry
-- `col = 1 | 2` to choose its column; else the page is split at a header
-- near its middle.
--
-- SCOPE (what a page is given): { sid, uid, kind, sids, ruin, dark, label,
-- tag, readonly }. `kind` is what the piece is (consoleKind):
--   screen   a Wall Screen: STATUS and LOG, read only
--   desk     a Desk Monitor: the base's operations terminal (every base page)
--   reactor  the Reactor Control Console: REACTOR and ALARMS, then the base's
--   plc      a Ladder Controller: LOGIC first (its ladder editor a key away)
--   fire     a Fire Control Console: STATUS, POWER, LOGIC, LOG
--   ruin     any of these in a ruin: its LOG (the lore), its DATA, and what
--            its dead base still answers
-- `sids` are the structures it reaches: its own and every structure WIRED to
-- it (the same base grid) — a console acts at a distance only on what is
-- wired or plumbed to it. `dark` is why it cannot send a command (no grid at
-- all: a ruin before it is powered, a desk on no grid): the base pages' keys
-- then dim with that reason. The reactor's own desk is hardwired to its
-- plant.
--
-- COST: closed, a prompt check at 8 Hz against an index of console pieces
-- (rebuilt when the structures change) — arithmetic, no rays; open, the page
-- is built and ui.make'd at `refresh` Hz (and at once after a press).
--
-- The rules are pure (the globals under PURE: tests/smoke_terminal.lua).
-- Probes: openAt(sid, uid), close(), isOpen(), state(), page(id), press(id),
-- rows(), near().

defaults = {
  --@range 1 4 --@units m
  reach = 1.9,          -- how far from a console's foot the crew can use it
  --@range 10 90 --@units deg
  aim_deg = 55,         -- …facing it within this
  --@range 1 10 --@units Hz
  refresh = 4.0,        -- how often an open page is described again
}

-- ── PURE ────────────────────────────────────────────────────────────────────
PAGES = {}            -- id → { id, fn, order, title, scopes, n }
local seq = 0
-- Register (or replace) a page. opts = { order, title, scopes = { kind = true } | nil (every kind) }
function registerPage(id, fn, opts)
  if type(id) ~= "string" or type(fn) ~= "function" then return nil end
  opts = opts or {}
  seq = seq + 1
  PAGES[id] = { id = id, fn = fn, order = opts.order or 50, title = opts.title or id, scopes = opts.scopes, n = seq,
                orderFor = opts.orderFor, readonly = opts.readonly }
  return id
end
function unregisterPage(id) local had = PAGES[id] ~= nil; PAGES[id] = nil; return had end
-- The pages a console of `kind` carries, in order (a page's `orderFor[kind]`
-- puts it elsewhere on one kind of console: LOGIC first on a PLC's desk).
function pagesFor(kind)
  local out = {}
  for _, p in pairs(PAGES) do
    if p.scopes == nil or p.scopes[kind] then out[#out + 1] = p end
  end
  local function ord(p) return (p.orderFor and p.orderFor[kind]) or p.order end
  table.sort(out, function(a, b) local oa, ob = ord(a), ord(b); if oa ~= ob then return oa < ob end return a.n < b.n end)
  return out
end
-- What a piece is to a terminal: → kind | nil. (def = parts_base.partInfo,
-- part = its record, rec = its structure.)
function consoleKind(def, part, rec)
  if type(def) ~= "table" then return nil end
  local k = nil
  if def.console then k = "reactor"
  elseif def.lg and def.lg.kind == "plc" then k = "plc"
  elseif def.lz and def.lz.kind == "console" then k = "fire"
  elseif def.piece == "monitor" then k = "desk"
  elseif def.screen then k = "screen" end
  if k and rec and rec.ru then return "ruin" end
  return k
end
-- May a console whose scope is `scope` act on structure `sid`?
function linked(scope, sid)
  if not (scope and sid ~= nil) then return false end
  for _, s in ipairs(scope.sids or { scope.sid }) do if s == sid then return true end end
  return false
end
-- Split rows into two columns: by each row's `col` when any row has one,
-- else at the header nearest the middle (never inside a section unless one
-- section is the whole page). → left, right
function splitColumns(rows)
  rows = rows or {}
  local any = false
  for _, e in ipairs(rows) do if e.col then any = true break end end
  local L, R = {}, {}
  if any then
    for _, e in ipairs(rows) do if e.col == 2 then R[#R + 1] = e else L[#L + 1] = e end end
    return L, R
  end
  local n = #rows
  if n <= 10 then for _, e in ipairs(rows) do L[#L + 1] = e end return L, R end
  local best, bestd = nil, math.huge
  for i = 2, n do
    if rows[i].type == "header" then
      local d = math.abs(i - 1 - n / 2)
      if d < bestd then best, bestd = i, d end
    end
  end
  local cut = (best and bestd <= n * 0.3) and best or math.floor(n / 2) + 1
  for i, e in ipairs(rows) do if i < cut then L[#L + 1] = e else R[#R + 1] = e end end
  return L, R
end
-- A page key's label: "1 STATUS"
function tabLabel(i, title) return string.format("%d  %s", i % 10, tostring(title)) end
-- The next page index after k (dir ±1), wrapping over n
function stepPage(k, n, dir)
  if (n or 0) <= 0 then return 1 end
  return ((k or 1) - 1 + (dir or 1)) % n + 1
end
TYPES = { action = true, toggle = true, slider = true, info = true, meter = true, sub = true, header = true, line = true, image = true }
-- One row made whole (the registry's normalize, plus a CRT's own two types).
function normalize(e, i, pid)
  if type(e) ~= "table" then return nil end
  local ty = e.type or (e.sub and "sub") or (e.act and "action") or "info"
  if not TYPES[ty] then return nil end
  e.type = ty
  e.id = e.id or string.format("%s.%d", pid or "t", i or 0)
  e.label = e.label or ""
  return e
end

-- ── the scene ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function snd(path, vol) if audio and audio.play then pcall(audio.play, path, { track = "UI", volume = vol or 0.35 }) end end

escTakenAt = -1
ROWS_KEEP = 1.0           -- s a page's rows are kept between presses
PROF = { builds = 0, build_ms = 0, make_ms = 0, tree_ms = 0, ui_ms = 0, makes = 0, max_ms = 0, last_ms = 0, closed_ms = 0, closed_n = 0 }
lastPress = nil           -- { id, ok, why, t } (probes)

-- The console pieces of every structure: { sid, uid, kind, b, px, py, pz, h }
-- (body-relative feet, once per structures version: the prompt's distances
-- are arithmetic).
local IDX = { ver = nil, list = {}, t = -10 }
local function rebuild_index()
  local ST = ref("structures")
  if not (ST and ST.list) then return end
  IDX.list = {}
  for _, rec in ipairs(ST.list()) do
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      local k = d and consoleKind(d, p, rec)
      if k then
        local px, py, pz = nil, nil, nil
        if ST.partPose then px, py, pz = ST.partPose(rec, p, 0) end
        local b = d.box
        IDX.list[#IDX.list + 1] = { sid = rec.id, uid = p.uid, kind = k, b = rec.b, px = px, py = py, pz = pz,
                                    h = b and (b[3] + b[4]) / 2 or 0.6 }
      end
    end
  end
  -- (scenarios2 F8) the spots scripts put on pieces: E there runs their act
  for key, sp in pairs(SPOTS) do
    local rec = ST.get and ST.get(sp.sid)
    local p = rec and ST.getPart and ST.getPart(sp.sid, sp.uid)
    if p then
      local d = defs(p.id)
      local px, py, pz = nil, nil, nil
      if ST.partPose then px, py, pz = ST.partPose(rec, p, 0) end
      local b = d and d.box
      IDX.list[#IDX.list + 1] = { sid = rec.id, uid = p.uid, kind = "spot", key = key, b = rec.b, px = px, py = py, pz = pz,
                                  h = sp.h or (b and (b[3] + b[4]) / 2) or 0.6 }
    end
  end
  IDX.ver = ST.version
end
-- SPOTS (scenarios2 F8, general): any script may put an E action on a piece
-- that is no console: setSpot(key, { sid, uid, label = "Read the Data Core"
-- | fn, act = fn(), on = fn() → bool (offered now?), h = metres up }) and
-- setSpot(key, nil) to take it off. The walk-up prompt and E are the
-- console's own (reach, facing, what blocks it). A data core in a bunk,
-- a log under a shield block.
SPOTS = {}
function setSpot(key, t)
  if type(key) ~= "string" then return false end
  SPOTS[key] = (type(t) == "table" and t.sid ~= nil and t.uid ~= nil) and t or nil
  IDX.ver = nil
  return true
end
function spots() return SPOTS end
function consoles() return IDX.list end

-- ── the scope: what a console reaches ───────────────────────────────────────
local function label_of(sid, uid)
  local PI = ref("part_info")
  if PI and PI.designate then local ok, n = pcall(PI.designate, sid, uid); if ok and n then return n end end
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  return d and d.label or "console"
end
local function rec_name(rec)
  if not rec then return "?" end
  if rec.n and rec.n ~= "Structure" then return tostring(rec.n) end
  local B = ref("bases")
  local base = B and B.baseAt and B.baseAt(rec.b, rec.x, rec.y, rec.z)
  if base and base.n then return tostring(base.n) end
  return "Structure " .. tostring(rec.id)
end
recName = rec_name
function scopeFor(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not (rec and p) then return nil end
  local d = defs(p.id) or {}
  local kind = consoleKind(d, p, rec)
  if not kind then return nil end
  local sids, seen = { sid }, { [sid] = true }
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  for _, s in ipairs(g and g.sids or {}) do if not seen[s] then seen[s] = true; sids[#sids + 1] = s end end
  local ruin = nil
  local RU = ref("ruins")
  if rec.ru and RU and RU.site then ruin = RU.site(rec.ru) end
  local dark = nil
  if not g then dark = rec.ru and "the terminal is dark: its grid is dead (a battery or a cell on this structure wakes it)"
    or "no power: the console's structure is on no base grid (a tower within 150 m, or a Power Cable)" end
  local PI = ref("part_info")
  local tag = PI and PI.tagOf and PI.tagOf(sid, uid) or nil
  return { sid = sid, uid = uid, kind = kind, sids = sids, ruin = ruin, rec = rec, dark = dark,
           label = d.label or "Console", tag = tag, name = rec_name(rec), readonly = kind == "screen", def = d }
end

-- ── state ───────────────────────────────────────────────────────────────────
local T = nil             -- the open terminal: { sid, uid, scope, pages, k, stack, msg, msg_t, bad, dirty, desc_t, node, making, focus }
local P = { node = nil, making = false, said = nil, near = nil, t = -10 }   -- the prompt
local held_kb = false

function isOpen() return T ~= nil end
function state()
  if not T then return nil end
  local pg = T.pages[T.k]
  return { sid = T.sid, uid = T.uid, kind = T.scope.kind, page = pg and pg.id, pages = #T.pages, sub = #T.stack > 0 and T.stack[#T.stack].title or nil }
end
function near() return P.near end

local function guard(on)
  local IG = ref("input_guard")
  if IG and IG.hold then pcall(IG.hold, "terminal", on) end
  held_kb = on
end

local function ctx()
  local actor = T and T.actor
  if not actor then
    local CM = ref("context_menu")
    actor = CM and CM.actorNow and CM.actorNow() or nil
    if T then T.actor = actor end
  end
  return { actor = actor, ref = ref, terminal = true,
    toast = function(msg, bad) if T then T.msg, T.msg_t, T.bad = msg, now(), bad == true end end,
    close = function() end }
end

function close()
  if not T then return end
  if valid(T.node) then T.node:destroy() end
  T = nil
  guard(false)
  if input and input.setMouseLocked then
    local pc = ref("planet_camera")
    if pc and (pc.firstPerson or pc.shiftlock) then pcall(input.setMouseLocked, true) end
  end
  local fx = ref("sfx")
  if fx and fx.play then pcall(fx.play, "close") end
end

-- Open the terminal of piece (sid, uid), on page `pid` (or its first). → ok, why
function openAt(sid, uid, pid)
  local scope = scopeFor(sid, uid)
  if not scope then return false, "not a console" end
  local pages = pagesFor(scope.kind)
  if #pages == 0 then return false, "no pages" end
  if T then close() end
  T = { sid = sid, uid = uid, scope = scope, pages = pages, k = 1, stack = {}, msg = nil, msg_t = -10, bad = false,
        dirty = true, desc_t = -10, focus = true, opened = now() }
  if pid then for i, p in ipairs(pages) do if p.id == pid then T.k = i end end end
  guard(true)
  snd("audio/foley/key_strike.ogg", 0.4)
  local BL = ref("base_log")
  if log then log(string.format("terminal: open %s:%s (%s) on %s", tostring(sid), tostring(uid), scope.kind, pages[T.k].id)) end
  P.near = nil
  if P.node and valid(P.node) then P.node.visible = false end
  return true
end
-- Show page `id` (or index). → ok
function page(id)
  if not T then return false end
  for i, p in ipairs(T.pages) do
    if p.id == id or i == id then T.k = i; T.stack = {}; T.dirty = true; T.focus = true; snd("audio/foley/key_strike.ogg", 0.25); return true end
  end
  return false
end

-- The rows on screen now (the top sub-page's, else the page's), normalised.
local function build_rows()
  if not T then return {}, nil end
  local top = T.stack[#T.stack]
  local list, sub = nil, nil
  if top then
    local ok, l = pcall(top.sub)
    list = ok and l or {}
    sub = top.title
  else
    local pg = T.pages[T.k]
    -- (the page's rows are kept for ROWS_KEEP s: their numbers are live
    -- functions read at every describe; a press, a new page, a new log line
    -- or the structures changing builds them again)
    local BL = ref("base_log")
    local ST = ref("structures")
    local sig = string.format("%s|%s|%s", pg.id, tostring(BL and BL.version), tostring(ST and ST.version))
    if T.cache and T.cache.sig == sig and now() - T.cache.t < ROWS_KEEP and not T.rebuild then return T.cache.list, T.cache.sub end
    T.rebuild = false
    T.scope.tag = (ref("part_info") and ref("part_info").tagOf) and ref("part_info").tagOf(T.sid, T.uid) or T.scope.tag
    local ok, l, s2 = pcall(pg.fn, T.scope, ctx())
    if not ok then
      if log and T.err ~= l then T.err = l; log("terminal: page " .. pg.id .. " failed: " .. tostring(l)) end
      list = { { type = "line", text = "PAGE FAULT: " .. tostring(l), level = 2 } }
    else list = l or {}; sub = s2 end
  end
  local out = {}
  for i, e in ipairs(list) do
    local n = normalize(e, i, T.pages[T.k].id)
    if n then out[#out + 1] = n end
  end
  if not top then
    local BL, ST = ref("base_log"), ref("structures")
    T.cache = { sig = string.format("%s|%s|%s", T.pages[T.k].id, tostring(BL and BL.version), tostring(ST and ST.version)), t = now(), list = out, sub = sub }
  end
  return out, sub
end
function rows() local r = build_rows(); return r end

local function registry() return ref("context_registry") end
local function live(v)
  local r = registry()
  if r and r.live then return r.live(v) end
  if type(v) == "function" then local ok, x = pcall(v); return ok and x or nil end
  return v
end
local function words(v)
  v = live(v)
  if v == nil then return nil end
  local t = type(v)
  if t == "string" then return v end
  if t == "number" or t == "boolean" then return tostring(v) end
  return nil
end

-- Press a row (a click, Enter, a probe by id). → ok, why
local function handle(e, dir)
  if not (T and e) then return false end
  if e.type == "sub" then
    local r = registry()
    local ok, why = true, nil
    if r then ok, why = r.usable(e) end
    if not ok then T.msg, T.msg_t, T.bad = why, now(), true; snd("audio/foley/switch_3.ogg", 0.2) return false, why end
    T.stack[#T.stack + 1] = { sub = e.sub, title = words(e.title) or words(e.label) }
    T.dirty, T.focus = true, true
    snd("audio/foley/key_strike.ogg", 0.25)
    return true
  end
  if e.type == "info" or e.type == "meter" or e.type == "header" or e.type == "line" or e.type == "image" then return false end
  local r = registry()
  if not r then return false, "no registry" end
  if e.job then T.msg, T.msg_t, T.bad = "that is done at the piece itself, not from a console", now(), true return false end
  local BL = ref("base_log")
  if BL then BL.via = T.scope.tag or label_of(T.sid, T.uid) end
  local ok, why, job = r.press(e, dir)
  if BL then BL.via = nil end
  if job then ok, why = false, "that is done at the piece itself" end
  lastPress = { id = e.id, ok = ok, why = why, t = now() }
  if not ok then
    T.msg, T.msg_t, T.bad = why or "can't do that", now(), true
    snd("audio/foley/switch_3.ogg", 0.25)
  else
    T.msg, T.msg_t, T.bad = why, why and now() or -10, why ~= nil
    snd("audio/foley/key_strike.ogg", 0.4)
  end
  T.dirty, T.rebuild = true, true
  return ok, why
end
function press(id, dir)
  if not T then return false, "closed" end
  for _, e in ipairs(build_rows()) do
    local tail = tostring(e.id):match("%.([^%.]+)$")
    if e.id == id or tail == id then return handle(e, dir) end
  end
  return false, "no row " .. tostring(id)
end
function back()
  if not T then return false end
  if #T.stack > 0 then table.remove(T.stack); T.dirty, T.focus = true, true; return true end
  return false
end

-- ── drawing ─────────────────────────────────────────────────────────────────
-- (the plate stands on the bottom of the screen, its top clear of the
-- objectives card and the HUD's chips, its foot above the crew strip: 495 of 720 lines)
local W_PANEL, W_RAIL, H_COL = 1120, 150, 360
local W_COL = math.floor((W_PANEL - 24 - W_RAIL - 10 - 16 - 12) / 2)   -- two columns in the well
local LV_STYLE = { [0] = "hud/value", [1] = "hud/valueWarn", [2] = "hud/valueDanger" }
local first_named = false
-- the words on a key, by the key's look
TXT = { ["term/row"] = "hud/value", ["term/rowOn"] = "hud/value", ["term/rowWarn"] = "hud/valueWarn",
        ["term/rowDanger"] = "term/danger", ["term/rowDim"] = "hud/valueMuted" }
local function row_tree(e, i)
  local r = registry()
  local ty = e.type
  local key = "e" .. i
  if ty == "header" then
    return { "col", key = key, w = "100%", h = "fit", gap = 2, pad = 0,
      { "text", key = "t", style = "hud/micro", w = "100%", h = 16, text = words(e.label) or "", textValign = "end", maxLines = 1, overflow = "ellipsis" },
      { "box", key = "r", w = "100%", h = 1, fill = { 0.64, 0.93, 0.56, 0.18 } } }
  end
  if ty == "line" then
    local lv = tonumber(live(e.level)) or 0
    return { "text", key = key, style = LV_STYLE[lv] or "hud/value", w = "100%", h = "fit", wrap = true, maxLines = 3, overflow = "ellipsis",
      text = words(e.text) or words(e.label) or "" }
  end
  if ty == "image" then
    local tex = words(e.texture)
    if not tex then return { "box", key = key, w = e.w or 400, h = e.h or 120, fill = { 0.01, 0.03, 0.015, 1 } } end
    return { "image", key = key, texture = tex, w = e.w or 400, h = e.h or 120, imageFit = "stretch" }
  end
  if ty == "info" or ty == "meter" then
    local val = words(e.value) or "—"
    local warn = live(e.warn)
    local st = (warn == 2 or warn == "danger") and "hud/valueDanger" or ((warn == true or warn == 1) and "hud/valueWarn" or "hud/value")
    local lbl = words(e.label) or ""
    local long = #val > 34 or (#lbl > 16 and #val > 18)
    local kids
    if long then
      kids = { "col", key = key, w = "100%", h = "fit", gap = 1, pad = 0,
        { "text", key = "l", style = "hud/micro", w = "100%", h = 14, text = lbl, maxLines = 1, overflow = "ellipsis" },
        { "text", key = "v", style = st, w = "100%", h = "fit", wrap = true, maxLines = 3, overflow = "ellipsis", text = val } }
    else
      kids = { "row", key = key, w = "100%", h = 18, gap = 6, pad = 0, align = "center",
        { "text", key = "l", style = "hud/micro", w = 150, h = 16, text = lbl, textValign = "center", maxLines = 1, overflow = "ellipsis" },
        { "text", key = "v", style = st, w = "grow", h = 16, textAlign = "end", textValign = "center", text = val, maxLines = 1, overflow = "ellipsis" } }
    end
    if ty ~= "meter" then return kids end
    local f = math.max(0, math.min(1, tonumber(live(e.frac)) or 0))
    local GW = W_COL - 8
    return { "col", key = "m" .. i, w = "100%", h = "fit", gap = 2, pad = 0, kids,
      { "row", key = "g", w = "100%", h = 6, pad = 0, gap = 0, radius = 1, fill = { 0.01, 0.02, 0.015 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
        { "box", key = "f", w = math.max(1, math.floor(GW * f + 0.5)), h = 6, radius = 1,
          fill = (warn and warn ~= 0) and { 1.0, 0.80, 0.28 } or { 0.64, 0.93, 0.56 } } } }
  end
  -- the keys: toggle, action, slider, sub
  local ok, why = true, nil
  if r then ok, why = r.usable(e) end
  local warn = live(e.warn)
  local on = (ty == "toggle") and live(e.on) == true
  local style = "term/row"
  if not ok then style = "term/rowDim"
  elseif e.danger then style = "term/rowDanger"
  elseif warn and warn ~= 0 then style = "term/rowWarn"
  elseif on then style = "term/rowOn" end
  local hint = words(e.hint)
  local right = nil
  if ty == "toggle" then right = on and (words(e.onText) or "[ ON ]") or (words(e.offText) or "[OFF ]")
  elseif ty == "sub" then right = hint or "▸"
  elseif ty == "slider" then
    local v = tonumber(live(e.get)) or 0
    right = e.fmt and words(function() return e.fmt(v) end) or string.format("%.2f", v)
  else right = hint end
  local nm = nil
  if not first_named and ok then nm = "TermFirstRow"; first_named = true end
  -- (a text inside a key takes no size from the key's style: each is styled itself)
  local ts = TXT[style] or "hud/value"
  local b = { "button", key = key, name = nm, style = style, w = "100%", h = 20, dir = "row", gap = 6, pad = 2, align = "center",
    tooltip = (not ok) and words(why) or words(e.tip),
    onClicked = function() handle(e, 1) end,
    { "text", key = "l", style = ts, w = "grow", h = 16, text = words(e.label) or "", textValign = "center", maxLines = 1, overflow = "ellipsis" } }
  if hint and ty == "toggle" then b[#b + 1] = { "text", key = "h", style = (style == "term/row") and "hud/valueDim" or ts, w = "fit", h = 16, text = hint, textValign = "center", maxLines = 1 } end
  if right then b[#b + 1] = { "text", key = "k", style = (ty == "toggle" and not on and ok) and "hud/valueDim" or ts, w = "fit", h = 16, text = right, textValign = "center", maxLines = 1 } end
  if ty == "slider" then
    -- a slider is two keys: − and +
    return { "row", key = "s" .. i, w = "100%", h = 20, gap = 4, pad = 0, align = "center",
      { "button", key = "dn", style = ok and "term/row" or "term/rowDim", w = 30, h = 20, text = "−", textAlign = "center", textValign = "center",
        onClicked = function() handle(e, -1) end },
      { "button", key = "up", name = nm, style = ok and "term/row" or "term/rowDim", w = 30, h = 20, text = "+", textAlign = "center", textValign = "center",
        onClicked = function() handle(e, 1) end },
      { "text", key = "l", style = "hud/value", w = "grow", h = 18, text = words(e.label) or "", textValign = "center", maxLines = 1, overflow = "ellipsis" },
      { "text", key = "v", style = "hud/valueAccent", w = "fit", h = 18, text = right or "", textValign = "center" } }
  end
  -- (a disabled key's reason under it, in amber: readable without a hover)
  if not ok and words(why) and e.showWhy ~= false then
    return { "col", key = "c" .. i, w = "100%", h = "fit", gap = 1, pad = 0, b,
      { "text", key = "w", style = "term/why", w = "100%", h = "fit", wrap = true, maxLines = 2, overflow = "ellipsis", text = words(why) } }
  end
  return b
end

local function column(list, key)
  local kids = {}
  for i, e in ipairs(list) do kids[#kids + 1] = row_tree(e, key * 1000 + i) end
  local col = { "scroll", key = "c" .. key, w = W_COL, h = H_COL, dir = "col", gap = 2, pad = 2, align = "stretch" }
  for _, k in ipairs(kids) do col[#col + 1] = k end
  return col
end

local function clock_text()
  local BL = ref("base_log")
  local dp = ref("deployables")
  local t = 0
  if dp and dp.agencyClock then local ok, v = pcall(dp.agencyClock); if ok and type(v) == "number" then t = v end end
  return BL and BL.stamp and BL.stamp(t):gsub(":%d%d$", "") or ""
end

local function tree(list, sub)
  local S = T.scope
  local pg = T.pages[T.k]
  first_named = false
  local L, R = splitColumns(list)
  local top = T.stack[#T.stack]
  -- the rail: one key per page
  local rail = { "col", key = "rail", w = W_RAIL, h = "fit", gap = 4, pad = 0, align = "stretch" }
  for i, p in ipairs(T.pages) do
    rail[#rail + 1] = { "button", key = "tab" .. p.id, style = "term/tab", selected = (i == T.k) or nil, w = "100%", h = 28,
      text = tabLabel(i, p.title), textAlign = "start", textValign = "center", pad = 6,
      onClicked = function() page(i) end }
  end
  rail[#rail + 1] = { "box", key = "gap", w = "100%", h = 8 }
  rail[#rail + 1] = { "text", key = "who", style = "hud/micro", w = "100%", h = "fit", wrap = true,
    text = string.format("%s\n%s", S.tag and (S.tag .. " · " .. S.label) or S.label, S.name or "") }
  if S.dark then
    rail[#rail + 1] = { "text", key = "dark", style = "hud/valueWarn", w = "100%", h = "fit", wrap = true, maxLines = 5, text = "DARK · " .. S.dark }
  end
  -- the screen
  local title = top and (pg.title .. "  ▸  " .. tostring(top.title or "")) or pg.title
  local hdr = { "row", key = "sh", w = "100%", h = 24, gap = 8, pad = 0, align = "center",
    { "text", key = "t", style = "hud/valueLg", w = "grow", h = 24, text = title, textValign = "center", maxLines = 1, overflow = "ellipsis" },
    { "text", key = "s", style = "hud/valueDim", w = "fit", h = 20, text = words(sub) or "", textValign = "center", maxLines = 1 },
    { "text", key = "c", style = "hud/valueDim", w = 110, h = 20, text = clock_text(), textAlign = "end", textValign = "center" } }
  local body = { "row", key = "cols", w = "100%", h = H_COL, gap = 12, pad = 0, align = "start", column(L, 1), column(R, 2) }
  local well = { "col", key = "well", style = "hud/instrument", w = "grow", h = "fit", gap = 6, pad = 8, align = "stretch",
    hdr, { "box", key = "rule", w = "100%", h = 1, fill = { 0.64, 0.93, 0.56, 0.22 } }, body }
  if #list == 0 then body[#body + 1] = { "text", key = "none", style = "hud/valueDim", w = 200, h = 20, text = "NO DATA" } end
  -- the foot: the toast, else the keys
  local recent = T.msg and now() - T.msg_t < 4.0
  -- (playtest 11-11: "can't time warp when accessing computers") . and , warp
  -- with the console open (warp_chip reads them raw); the rate is shown here
  local w = space and space.warp and space.warp() or 1
  local wtxt = (w > 1.001) and string.format("   ·   . ,  warp ×%d", math.floor(w + 0.5)) or "   ·   . ,  warp"
  local foot = recent and words(T.msg) or ((#T.stack > 0) and ("1–0 / TAB  pages   ·   ↑ ↓ ENTER  press   ·   ESC  back" .. wtxt)
    or ("1–0 / TAB  pages   ·   ↑ ↓ ENTER  press   ·   ESC or E  leave the console" .. wtxt))
  return { "col", key = "term", style = "panel/frame", w = W_PANEL, h = "fit", gap = 8, pad = 12, align = "stretch",
    { "row", key = "hd", w = "100%", h = 26, gap = 10, pad = 0, align = "center",
      { "text", key = "h", style = "panel/heading", w = "grow", h = "fit",
        text = S.kind == "reactor" and "REACTOR CONTROL" or (S.kind == "ruin" and "ABANDONED TERMINAL" or (S.kind == "plc" and "LADDER CONTROLLER" or (S.kind == "screen" and "STATUS SCREEN" or "BASE TERMINAL"))) },
      { "text", key = "n", style = "panel/label", w = "fit", h = "fit", text = (S.tag and (S.tag .. " · ") or "") .. tostring(S.name or "") } },
    { "row", key = "main", w = "100%", h = "fit", gap = 10, pad = 0, align = "start", rail, well },
    { "text", key = "foot", style = (recent and T.bad) and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit", wrap = true, maxLines = 2, textAlign = "end", text = foot } }
end

-- (tests, probes) the tree the open terminal would hand ui.make now
function treeNow()
  if not T then return nil end
  local list, sub = build_rows()
  return tree(list, sub), list
end

-- What the plate shows, as one string: when it is what was made last time
-- the engine is not asked to reconcile it again (the trend picture updates in
-- place without a make). (pure: tests)
local SIG_KEYS = { "text", "style", "texture", "tooltip", "selected", "w", "disabled", "name" }
function treeSig(t, acc)
  acc = acc or {}
  if type(t) ~= "table" then return acc end
  if type(t[1]) == "string" then acc[#acc + 1] = t[1] end
  for _, k in ipairs(SIG_KEYS) do local v = t[k]; if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then acc[#acc + 1] = k .. "=" .. tostring(v) end end
  for _, v in ipairs(t) do if type(v) == "table" then treeSig(v, acc) end end
  acc[#acc + 1] = "/"
  return acc
end

local function describe()
  local w0 = wall()
  local list, sub = build_rows()
  local w1 = wall()
  T.rows = list
  local tr = tree(list, sub)
  local sig = table.concat(treeSig(tr), "|")
  local w2 = wall()
  local made = false
  if sig ~= T.sig or not T.made then
    local ok, err = pcall(ui.make, T.node, { tr })
    if not ok and log and T.mkerr ~= err then T.mkerr = err; log("terminal: ui.make failed: " .. tostring(err)) end
    T.sig, T.made, made = sig, true, true
  end
  local w3 = wall()
  if w0 then
    PROF.builds = PROF.builds + 1
    PROF.build_ms = PROF.build_ms + (w1 - w0) * 1000
    PROF.tree_ms = PROF.tree_ms + (w2 - w1) * 1000
    PROF.ui_ms = PROF.ui_ms + (w3 - w2) * 1000
    PROF.make_ms = PROF.make_ms + (w3 - w1) * 1000
    if made then PROF.makes = PROF.makes + 1 end
    PROF.last_ms = (w3 - w0) * 1000
    if PROF.last_ms > PROF.max_ms then PROF.max_ms = PROF.last_ms end
  end
end

-- ── the walk-up prompt ──────────────────────────────────────────────────────
local function show_prompt(text)
  if not valid(P.node) then
    if P.making or not spawn then return end
    local h = find and find("Ship HUD")
    if not h then return end
    P.making = true
    pcall(spawn, "TerminalPrompt", vec3(0, 0, 0), function(n) P.making = false; P.node = n; n.style = "hud/prompt"; P.said = nil end, h)
    return
  end
  if P.said ~= text then
    P.said = text
    pcall(ui.make, P.node, { "row", key = "p", w = "fit", h = 36, pad = 0, gap = 0, align = "center",
      { "box", key = "l", w = 22, h = 1 },
      { "text", key = "t", style = "hud/task", w = "fit", h = "fit", text = text },
      { "box", key = "r", w = 22, h = 1 } })
  end
  P.node.visible = true
end
local function hide_prompt() if valid(P.node) and P.node.visible then P.node.visible = false end end

-- Something else owns the screen or the keys? → reason | nil
local function blocked_why()
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.curtain) then return "loading" end
  if gm and gm.inputOwner ~= nil then return "input owner " .. tostring(gm.inputOwner) end
  local pm = ref("pause_menu")
  if pm and pm.open then return "paused" end
  local CM = ref("context_menu")
  if CM and CM.isOpen and CM.isOpen() then return "context menu" end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return "facility" end
  local ip = ref("inventory_panel")
  if ip and ip.open then return "pack" end
  local lp = ref("loot_panel")
  if lp and lp.isOpen and lp.isOpen() then return "loot" end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return "map" end
  local fb = ref("field_builder")
  if fb and fb.isOpen and fb.isOpen() then return "build kit" end
  local LN = ref("logic_net")
  if LN and LN.editor and LN.editor.sid then return "ladder editor" end
  local pc = ref("planet_camera")
  if pc and (pc.freecam or pc.cinematic) then return "camera" end
  local sg = ref("scenario_stage")
  if sg and sg.isOpen and sg.isOpen() then return "dialogue" end
  return nil
end
blockedWhy = blocked_why

-- The console within reach and in front of the crew now: → entry | nil
local function find_near()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  local a = find and find("Astronaut")
  if not valid(a) then return nil end
  local pc = ref("planet_camera")
  local fx, fy, fz = 0, 0, -1
  if pc and pc.fwd_x then fx, fy, fz = pc.fwd_x, pc.fwd_y, pc.fwd_z end
  local best, bd = nil, math.huge
  local reach = params.reach or 1.9
  local cosA = math.cos(math.rad(params.aim_deg or 55))
  local bodies = {}
  for _, c in ipairs(IDX.list) do
    local sp = c.kind == "spot" and SPOTS[c.key] or nil
    local off = c.kind == "spot" and (not sp or (sp.on and not sp.on()))
    if c.px and c.b and not off then
      local bb = bodies[c.b]
      if bb == nil then bb = (space and space.body and space.body(c.b)) or false; bodies[c.b] = bb end
      if bb then
        -- the console's middle: its foot raised along the local up (both from this frame's body read)
        local l = math.sqrt(c.px * c.px + c.py * c.py + c.pz * c.pz)
        local ux, uy, uz = c.px / l, c.py / l, c.pz / l
        local wx, wy, wz = bb.x + c.px + ux * c.h, bb.y + c.py + uy * c.h, bb.z + c.pz + uz * c.h
        local dx, dy, dz = wx - a.x, wy - a.y, wz - a.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < reach + 0.6 and d < bd then
          -- facing it: the view's forward against the way to it, flattened on the local up
          local du = dx * ux + dy * uy + dz * uz
          local hx, hy, hz = dx - ux * du, dy - uy * du, dz - uz * du
          local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
          local fu = fx * ux + fy * uy + fz * uz
          local gx, gy, gz = fx - ux * fu, fy - uy * fu, fz - uz * fu
          local gl = math.sqrt(gx * gx + gy * gy + gz * gz)
          local facing = hl < 0.35 or (gl > 1e-4 and (hx * gx + hy * gy + hz * gz) / (hl * gl) >= cosA)
          if facing then best, bd = c, d end
        end
      end
    end
  end
  return best
end

local function interact_pressed()
  if input.pressed and input.pressed("e") then return true end
  return input.justPressed ~= nil and input.justPressed("Interact") == true
end
local function raw_pressed(k)
  if input.rawPressed then return input.rawPressed(k) == true end
  return input.pressed and input.pressed(k) == true
end
local function raw_key(k)
  if input.rawKey then return input.rawKey(k) == true end
  return input.key and input.key(k) == true
end

-- Is E the console's right now? (tool_belt asks: the laser stands its E down)
function prompting() return P.near ~= nil and T == nil end

-- ── the open terminal, each frame ───────────────────────────────────────────
local pad_prev = {}
local function pad_edge(btn)
  local down = input.padButton and input.padButton(1, btn) == true or false
  local was = pad_prev[btn]
  pad_prev[btn] = down
  return down and not was
end
local function open_tick(dt)
  -- the console still there, the crew still at it
  local ST = ref("structures")
  if not (ST and ST.getPart and ST.getPart(T.sid, T.uid)) then close() return end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then close() return end
  local n = ST.nodeOf and ST.nodeOf(T.sid, T.uid)
  local a = find and find("Astronaut")
  if valid(n) and valid(a) and a.distanceTo and a:distanceTo(n) > (params.reach or 1.9) + 2.0 then close() return end
  local bw = blocked_why()
  if bw and bw ~= "context menu" then close() return end
  if input.setMouseLocked then pcall(input.setMouseLocked, false) end
  if not held_kb then guard(true) end
  -- the keys
  if raw_pressed("escape") or pad_edge("East") then
    escTakenAt = time
    if not back() then close() return end
  end
  -- (E, or a pad's X, leaves as it came: never on the frame that opened it)
  if (raw_pressed("e") or pad_edge("West")) and now() - (T.opened or 0) > 0.2 then close() return end
  local np = #T.pages
  for k = 1, math.min(10, np) do if raw_pressed(tostring(k % 10)) then page(k) end end
  if raw_pressed("tab") then page(stepPage(T.k, np, (raw_key("shift") or raw_key("lshift")) and -1 or 1)) end
  if pad_edge("RightBumper") then page(stepPage(T.k, np, 1)) end
  if pad_edge("LeftBumper") then page(stepPage(T.k, np, -1)) end
  -- the panel
  if not valid(T.node) then
    if T.making or not spawn then return end
    local h = find and find("Ship HUD")
    if not h then return end
    T.making = true
    local me = T
    pcall(spawn, "TerminalPanel", vec3(0, 0, 0), function(nd)
      me.making = false
      if T ~= me then nd:destroy() return end
      T.node = nd
      T.dirty, T.made = true, false
    end, h)
    return
  end
  local t = now()
  if T.dirty or t - T.desc_t >= 1 / (params.refresh or 4) then
    T.dirty = false
    T.desc_t = t
    describe()
  end
  if T.focus and ui and ui.focus and find then
    local f = find("TermFirstRow")
    if f then ui.focus(f); T.focus = false end
  end
end

local reg_t = -10
function start(node)
  if findScripts then
    local all = findScripts("terminal")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  T, IDX.ver, IDX.list = nil, nil, {}
  P.node, P.making, P.said, P.near = nil, false, nil, nil
end

function update(node, dt)
  if T then open_tick(dt) return end
  local t = now()
  -- the index of console pieces, when the structures change (settled 0.5 s)
  local ST = ref("structures")
  if ST and ST.version ~= IDX.ver then
    if IDX.t < 0 then IDX.t = t end
    if t - IDX.t >= 0.5 or IDX.ver == nil then rebuild_index(); IDX.t = -10 end
  end
  if #IDX.list == 0 then P.near = nil; hide_prompt() return end
  if t - P.t >= 0.125 then
    P.t = t
    local w0 = wall()
    if blocked_why() then P.near = nil else P.near = find_near() end
    if w0 then PROF.closed_ms = PROF.closed_ms + (wall() - w0) * 1000; PROF.closed_n = PROF.closed_n + 1 end
  end
  if not P.near then hide_prompt() return end
  local c = P.near
  if c.kind == "spot" then
    local sp = SPOTS[c.key]
    if not sp then P.near = nil; hide_prompt() return end
    local lbl = type(sp.label) == "function" and sp.label() or sp.label or "Use it"
    show_prompt(string.format("%s   ·   E", tostring(lbl)))
    if interact_pressed() and sp.act then
      P.near = nil
      hide_prompt()
      local ok, err = pcall(sp.act)
      if not ok and log then log("terminal: spot " .. tostring(c.key) .. ": " .. tostring(err)) end
    end
    return
  end
  local what = (c.kind == "reactor") and "Run the reactor" or ((c.kind == "screen") and "Read the screen" or ((c.kind == "ruin") and "Search the terminal" or "Use the console"))
  show_prompt(string.format("%s  ·  %s   ·   E", what, label_of(c.sid, c.uid)))
  if interact_pressed() then openAt(c.sid, c.uid) end
end
