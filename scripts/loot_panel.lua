-- LOOT PANEL — open a crate, a locker, a drawer; key a code into a keypad;
-- read a log card. (The interaction plan S5; scripts/loot.lua is the rules.)
--
-- Walk up to anything that holds things (a ruin's crates, shelving, a
-- workbench, a bunk's footlocker, a cabinet, a locker; the same pieces on
-- your own base) or to a door on a keypad, face it, and "Open the Cargo
-- Crate · E" comes up. E opens, over the world (it keeps running):
--
--   THE TRANSFER   two panes: the container on the left, the pack of whoever
--                  you are on the right, each with its kilograms and litres.
--                  Click a row to move one (a material: the stack); Shift+click
--                  moves all of that item. "Take everything" / "Stow the
--                  materials". What does not fit stays where it was and the
--                  foot says why ("no room: 3 kg free"). A log card has READ.
--   THE KEYPAD     a locked one: 0–9, ⌫ (Backspace) and ENT (Enter) or the
--                  keys on screen; a code you have read is offered as a key;
--                  "Force the lock" runs here too (a tool, its seconds, loud).
--                  Three wrong codes lock the keypad out for 30 s.
--   THE READER     a log card's words; its codes are noted (the keypads offer
--                  them), the site it names is found.
--
-- Esc or E leaves (Esc in the reader goes back to the box it came from).
-- While it is up the keyboard is the panel's (input_guard.hold "loot"), the
-- pointer is free (planet_camera.panel_open asks isOpen), the belt, the
-- context menu and the pause ladder stand down (they ask isOpen too).
--
-- COST: closed, a prompt check at 8 Hz over an index of container and keypad
-- pieces (rebuilt when the structures change) — arithmetic, no rays; open,
-- the panel is described at 4 Hz and at once after a press (ui.make only when
-- what it shows changed). Probes: openContainer, openKeypad, openReader,
-- close, isOpen, state, take, put, takeAll, stowMats, key, enter, useKnown,
-- force, near, treeNow.

defaults = {
  --@range 1 4 --@units m
  reach = 2.0,          -- how far from a piece's middle the crew can open it
  --@range 10 90 --@units deg
  aim_deg = 60,         -- …facing it within this
  refresh = 4.0,        -- Hz an open panel is described again
}

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
local function L() return ref("loot") end
local function INV() return ref("inventory") end

escTakenAt = -1
PROF = { describes = 0, makes = 0, desc_ms = 0, closed_ms = 0, closed_n = 0, last_ms = 0 }
lastAction = nil          -- { what, ok, why, t } (probes)

-- ── the open panel ──────────────────────────────────────────────────────────
local V = nil             -- { mode = box|keypad|reader, sid, uid, key, entry, msg, msg_t, bad, node, making, dirty, desc_t, opened, from, job, sig }
local held_kb = false
local function guard(on)
  local IG = ref("input_guard")
  if IG and IG.hold then pcall(IG.hold, "loot", on) end
  held_kb = on
end
local PACK = "astro"
function isOpen() return V ~= nil end
function state()
  if not V then return nil end
  return { mode = V.mode, sid = V.sid, uid = V.uid, key = V.key, entry = V.entry, msg = V.msg, bad = V.bad, job = V.job and V.job.label or nil,
           jobFrac = V.job and (V.job.t / V.job.secs) or nil }
end
local function say(msg, bad)
  if not V then return end
  V.msg, V.msg_t, V.bad = msg, now(), bad == true
  V.dirty = true
  snd(bad and "audio/foley/buzz_denied.ogg" or "audio/foley/key_strike.ogg", bad and 0.25 or 0.3)
end
local function act(what, ok, why) lastAction = { what = what, ok = ok, why = why, t = now() }; return ok, why end

function close()
  if not V then return end
  if valid(V.node) then V.node:destroy() end
  V = nil
  guard(false)
  if input and input.setMouseLocked then
    local pc = ref("planet_camera")
    if pc and (pc.firstPerson or pc.shiftlock) then pcall(input.setMouseLocked, true) end
  end
  snd("audio/foley/latch_clunk.ogg", 0.25)
end
local function open_view(mode, sid, uid, key)
  local keep = V and V.node
  local from = V and { mode = V.mode, sid = V.sid, uid = V.uid } or nil
  if V and not keep then V = nil end
  if not V then guard(true) end
  V = { mode = mode, sid = sid, uid = uid, key = key, entry = "", msg = nil, msg_t = -10, bad = false, node = keep, making = false,
        dirty = true, desc_t = -10, opened = now(), from = from, sig = nil }
  return true
end
-- Open container (sid, uid): a ruin's site rolled first; a locked one opens its keypad. → ok, why
function openContainer(sid, uid)
  local lt = L()
  if not lt then return false, "no loot rules" end
  if not lt.containerAt(sid, uid) then return false, "it holds nothing" end
  if lt.isLocked(sid, uid) then return openKeypad(sid, uid) end
  lt.prepare(sid, uid)
  open_view("box", sid, uid)
  snd("audio/foley/latch_clunk.ogg", 0.4)
  if log then log(string.format("loot_panel: open %s:%s", tostring(sid), tostring(uid))) end
  return true
end
function openKeypad(sid, uid)
  local lt = L()
  if not lt then return false, "no loot rules" end
  if lt.lockOf(sid, uid) == "none" then return false, "it has no keypad" end
  open_view("keypad", sid, uid)
  snd("audio/foley/key_strike.ogg", 0.35)
  return true
end
function openReader(key)
  local lt = L()
  if not (lt and lt.logRecord(key)) then return false, "the card is blank" end
  local _, got, found = lt.readLog(key)
  open_view("reader", V and V.sid, V and V.uid, key)
  V.learned, V.found = got and #got or 0, found
  snd("audio/foley/ticket_short.ogg", 0.3)
  return true
end
-- back from the reader to the box it was opened from
function back()
  if not V then return false end
  if V.mode == "reader" and V.from and V.from.mode == "box" then
    local f = V.from
    open_view("box", f.sid, f.uid)
    return true
  end
  return false
end

-- ── moves (the panel's keys; probes call them) ──────────────────────────────
local function cid() return V and L() and L().cidOf(V.sid, V.uid) or nil end
local function reweigh() end
local function name_of(id)
  local I = ref("items")
  return (I and I.nameOf and I.nameOf(id)) or id
end
local function mat_name(m, origin)
  local inv = INV()
  if inv and inv.stackLabel then return inv.stackLabel(m, origin) end
  local M = ref("materials")
  return (M and M.label and M.label(m)) or m
end
-- an item or a material stack, between the box and the pack
local function move(from, to, what, id, n, origin, verb)
  local inv = INV()
  if not (inv and V) then return 0 end
  if what == "mat" then
    local have = inv.count(from, id, origin)
    local moved = inv.transfer(from, to, id, n or have, origin)
    if moved <= 0 then say(string.format("%s won't fit: %s", mat_name(id, origin), to == PACK and "the pack is full" or "it is full"), true)
    elseif moved < (n or have) then say(string.format("%d of %d %s %s · the rest won't fit", moved, n or have, mat_name(id, origin), verb), true)
    else say(string.format("%d %s %s", moved, mat_name(id, origin), verb)) end
    act(verb, moved > 0)
    return moved
  end
  local moved, why = inv.moveItem(from, to, id, n or 1)
  if moved > 0 then say(string.format("%s%s %s%s", moved > 1 and (moved .. " × ") or "", name_of(id), verb, why and ("  ·  " .. why) or ""), why ~= nil)
  else say(string.format("the %s won't go: %s", name_of(id), why or "no room"), true) end
  act(verb, moved > 0, why)
  return moved
end
function take(id, n, origin, isMat)
  local c = cid()
  if not c then return 0 end
  local r = move(c, PACK, isMat and "mat" or "item", id, n, origin, "into the pack")
  if r > 0 then L().remember(V.sid, V.uid) end
  return r
end
function put(id, n, origin, isMat)
  local c = cid()
  if not c then return 0 end
  local r = move(PACK, c, isMat and "mat" or "item", id, n, origin, "stowed")
  if r > 0 then L().remember(V.sid, V.uid) end
  return r
end
function takeAll()
  local inv, c = INV(), cid()
  if not (inv and c) then return 0 end
  local n, why = inv.moveAllItems(c, PACK)
  local m = inv.transferAll(c, PACK)
  if n + m == 0 then say(why or "nothing fits in the pack", true)
  else say(string.format("%d thing%s, %d unit%s into the pack%s", n, n == 1 and "" or "s", m, m == 1 and "" or "s", why and ("  ·  " .. why) or ""), why ~= nil) end
  act("takeAll", n + m > 0, why)
  return n + m
end
function stowMats()
  local inv, c = INV(), cid()
  if not (inv and c) then return 0 end
  local m = inv.transferAll(PACK, c)
  if m == 0 then say(inv.isEmpty(PACK) and "no materials in the pack" or "no room for them in here", true)
  else say(string.format("%d unit%s of material stowed", m, m == 1 and "" or "s")); L().remember(V.sid, V.uid) end
  act("stowMats", m > 0)
  return m
end
-- keypad: a digit, clear, enter, a known code
function key(k)
  if not (V and V.mode == "keypad") then return false end
  if k == "clr" then V.entry = ""; V.dirty = true; snd("audio/foley/key_strike.ogg", 0.25); return true end
  if k == "del" then V.entry = V.entry:sub(1, -2); V.dirty = true; snd("audio/foley/key_strike.ogg", 0.2); return true end
  if type(k) == "string" and k:match("^%d$") and #V.entry < 8 then
    V.entry = V.entry .. k
    V.dirty = true
    snd("audio/foley/key_strike.ogg", 0.3)
    return true
  end
  return false
end
local function after_open()
  if not V then return end
  local lt = L()
  if lt.containerAt(V.sid, V.uid) then V.switch_t = now() + 0.6 else V.close_t = now() + 0.9 end
end
function enter()
  if not (V and V.mode == "keypad") then return false end
  local lt = L()
  local ok, why = lt.enterCode(V.sid, V.uid, V.entry)
  V.entry = ""
  if ok then say("OPEN" .. (why and ("  ·  " .. why) or "")); after_open()
  else say(why or "wrong code", true) end
  return act("enter", ok, why)
end
function useKnown()
  if not (V and V.mode == "keypad") then return false end
  local c = L().knownCode(V.sid, V.uid)
  if not c then return false, "you don't know its code" end
  V.entry = c
  return enter()
end
-- Force the lock from the keypad: a timed job here (a tool, its seconds, loud). → ok, why
function force()
  if not (V and V.mode == "keypad") then return false end
  local lt = L()
  local inv = INV()
  local function count(id) return inv and inv.itemCount(PACK, id) or 0 end
  local tool, _, tname = lt.toolFor("force", count)
  if not tool then say("needs a tool in the pack: the Terrain Laser, a Repair Kit or the Gravity Gun", true) return false end
  local secs = lt.forceSecs(tool, lt.roleOf(nil) == "engineer", lt.isDoor(V.sid, V.uid))
  V.job = { t = 0, secs = secs, label = "Forcing the lock with " .. tname, tool = tname, next = 0 }
  say("forcing it: " .. lt.forceWarn(V.sid, V.uid), true)
  return act("force", true)
end
function cancelJob() if V and V.job then V.job = nil; say("called off", true) end end

-- ── drawing ─────────────────────────────────────────────────────────────────
local W_BOX, W_COL, H_LIST = 1040, 500, 250
local first_named = false
local function nm()
  if first_named then return nil end
  first_named = true
  return "LootFirstRow"
end
local function shift_held()
  if input and input.rawKey then return input.rawKey("shift") == true or input.rawKey("lshift") == true end
  return input and input.key and (input.key("shift") or input.key("lshift")) or false
end
local function meter(key, frac, warn)
  frac = math.max(0, math.min(1, frac or 0))
  return { "row", key = key, w = "100%", h = 6, radius = 1, pad = 0, gap = 0, fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
    { "box", key = "f", w = math.max(2, math.floor((W_COL - 8) * frac + 0.5)), h = 6, radius = 1,
      fill = (warn or frac > 0.85) and { 1.0, 0.80, 0.28 } or { 0.66, 0.70, 0.56 } } }
end
local function load_of(inv, c)
  local cap = inv.cap(c)
  local vc = inv.volCap and inv.volCap(c) or math.huge
  local kgf = cap > 0 and inv.mass(c) / cap or 0
  local lf = (vc < math.huge and vc > 0) and inv.volume(c) / vc or 0
  local txt = string.format("%.1f / %.0f kg", inv.mass(c), cap)
  if vc < math.huge then txt = txt .. string.format("  ·  %.0f / %.0f L", inv.volume(c), vc) end
  return math.max(kgf, lf), txt
end
local function item_row(g, side, keyp)
  local into = side == "box"
  local logk = L().logKeyOf(g.id)
  local tip = into and "Take one into the pack (Shift: all of them)" or "Stow one (Shift: all of them)"
  local row = { "button", key = keyp .. g.id, name = nm(), style = "panel/row", w = "100%", h = 30, dir = "row", gap = 8, align = "center",
    tooltip = tip,
    onClicked = function()
      local n = shift_held() and g.n or 1
      if into then take(g.id, n) else put(g.id, n) end
    end,
    { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", g.n) },
    { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
      text = g.name .. (g.fills and g.fillCap and string.format("  (%d %%)", math.floor(100 * (g.fill or 0) / math.max(1, #g.fills * g.fillCap) + 0.5)) or "") },
    { "text", key = "kg", style = "panel/cellMuted", w = 96, h = "fit", textAlign = "end", text = string.format((g.L or 0) < 1 and "%.1f kg · %.1f L" or "%.1f kg · %.0f L", g.kg or 0, g.L or 0) },
    { "text", key = "go", style = "panel/cellMuted", w = 22, h = "fit", textAlign = "end", text = into and "→" or "←" } }
  if not logk then return row end
  row.w = "grow"
  return { "row", key = keyp .. "r" .. g.id, w = "100%", h = 30, gap = 4, pad = 0, align = "center",
    row,
    { "button", key = "read", style = "panel/secondary", w = 64, h = 28, text = L().isRead(logk) and "READ" or "READ ●", textAlign = "center", textValign = "center",
      tooltip = "Read the card", onClicked = function() openReader(logk) end } }
end
local function mat_row(e, side, keyp)
  local into = side == "box"
  return { "button", key = keyp .. (e.key or e.mat), name = nm(), style = "panel/row", w = "100%", h = 30, dir = "row", gap = 8, align = "center",
    tooltip = into and "Take the stack (what fits)" or "Stow the stack",
    onClicked = function() if into then take(e.mat, nil, e.origin, true) else put(e.mat, nil, e.origin, true) end end,
    { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", e.n) },
    { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = e.label or mat_name(e.mat, e.origin) },
    { "text", key = "kg", style = "panel/cellMuted", w = 96, h = "fit", textAlign = "end", text = string.format("%.1f kg", e.kg or 0) },
    { "text", key = "go", style = "panel/cellMuted", w = 22, h = "fit", textAlign = "end", text = into and "→" or "←" } }
end
local function pane(side, c, title, sub)
  local inv = INV()
  local frac, txt = load_of(inv, c)
  local list = { "scroll", key = "list", w = "100%", h = H_LIST, dir = "col", gap = 3, pad = 0, align = "stretch", scrollFade = 12 }
  local gear = inv.itemList(c) or {}
  local stacks = (inv.stacks or inv.items)(c) or {}
  local keyp = side == "box" and "b_" or "p_"
  for _, g in ipairs(gear) do list[#list + 1] = item_row(g, side, keyp) end
  for _, e in ipairs(stacks) do list[#list + 1] = mat_row(e, side, keyp .. "m_") end
  if #gear + #stacks == 0 then
    list[#list + 1] = { "text", key = "empty", style = "panel/cellMuted", w = "100%", h = 40, textAlign = "center", textValign = "center",
      text = side == "box" and "— empty —" or "— nothing in the pack —" }
  end
  local btn
  if side == "box" then
    btn = { "button", key = "all", style = "panel/action", w = "100%", h = 32, text = "Take everything that fits  →", textAlign = "center", textValign = "center",
      disabled = (#gear + #stacks == 0) or nil, onClicked = function() takeAll() end }
  else
    btn = { "button", key = "all", style = "panel/secondary", w = "100%", h = 32, text = "←  Stow the materials", textAlign = "center", textValign = "center",
      disabled = (#stacks == 0) or nil, onClicked = function() stowMats() end }
  end
  return { "col", key = side, w = W_COL, h = "fit", gap = 6, pad = 0, align = "stretch",
    { "row", key = "hd", w = "100%", h = 22, gap = 8, pad = 0, align = "center",
      { "text", key = "t", style = "panel/label", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = title },
      { "text", key = "s", style = "panel/cellMuted", w = "fit", h = "fit", text = txt } },
    meter("m", frac),
    { "text", key = "sub", style = "panel/cellMuted", w = "100%", h = 16, maxLines = 1, overflow = "ellipsis", text = sub or "" },
    list, btn }
end
local function rec_name(sid)
  local T = ref("terminal")
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  if not rec then return "" end
  if rec.ru then local RU = ref("ruins"); local s = RU and RU.site and RU.site(rec.ru); if s then return s.name end end
  return (T and T.recName and T.recName(rec)) or tostring(rec.n or "")
end
local function crew_name()
  local C = ref("crew")
  if C and C.activeId and C.get then local ok, r = pcall(C.get, C.activeId()); if ok and type(r) == "table" and r.name then return r.name end end
  return "your"
end
local function foot(keys)
  local recent = V.msg and now() - V.msg_t < 4.0
  return { "text", key = "foot", style = (recent and V.bad) and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit", wrap = true, maxLines = 2, textAlign = "end",
    text = recent and V.msg or keys }
end
local function tree_box()
  local lt = L()
  local c = cid()
  local _, p = lt.containerAt(V.sid, V.uid)
  local d = p and defs(p.id) or {}
  local what = (d.container and d.container.what) or d.label or "container"
  local state = lt.lockOf(V.sid, V.uid)
  local lockTxt = (state == "open" and "keypad: open") or (state == "broken" and "lock forced") or ""
  return { "col", key = "loot", style = "panel/frame", w = W_BOX, h = "fit", gap = 8, pad = 14, align = "stretch",
    { "row", key = "hd", w = "100%", h = 26, gap = 10, pad = 0, align = "center",
      { "text", key = "h", style = "panel/heading", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = lt.labelOf(V.sid, V.uid) },
      { "text", key = "l", style = "panel/hintWarn", w = "fit", h = "fit", text = lockTxt },
      { "text", key = "n", style = "panel/label", w = "fit", h = "fit", text = rec_name(V.sid) } },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "panes", w = "100%", h = "fit", gap = 16, pad = 0, align = "start",
      pane("box", c, string.upper(what), lt.summary(V.sid, V.uid)),
      pane("pack", PACK, string.upper(crew_name() .. " · suit pack"), "what you carry: kilograms and litres both bind") },
    foot("click: move one   ·   Shift+click: all of it   ·   READ: a log card   ·   Esc or E  leave") }
end
local DIG = { { "1", "2", "3" }, { "4", "5", "6" }, { "7", "8", "9" }, { "clr", "0", "ent" } }
local function tree_keypad()
  local lt = L()
  local st = lt.lockOf(V.sid, V.uid)
  local left = lt.lockoutLeft(V.sid, V.uid)
  local known = lt.knownCode(V.sid, V.uid)
  local shown = V.entry ~= "" and (V.entry:gsub(".", "%0 ")) or "_ _ _ _"
  local status, sst = "LOCKED", "hud/valueWarn"
  if st == "open" or st == "broken" then status, sst = (st == "broken" and "FORCED · OPEN" or "OPEN"), "hud/value" end
  if left then status, sst = string.format("LOCKED OUT · %d s", math.ceil(left)), "hud/valueDanger" end
  local grid = { "col", key = "grid", w = "100%", h = "fit", gap = 6, pad = 0, align = "center" }
  for r, row in ipairs(DIG) do
    local rw = { "row", key = "r" .. r, w = "fit", h = 46, gap = 6, pad = 0, align = "center" }
    for _, k in ipairs(row) do
      local label = (k == "clr" and "CLR") or (k == "ent" and "ENT") or k
      -- (no key takes the UI focus: Enter would press the focused key as well as ENT)
      rw[#rw + 1] = { "button", key = "k" .. k, style = (k == "ent") and "panel/action" or "panel/secondary",
        w = 76, h = 44, text = label, textSize = 20, textAlign = "center", textValign = "center", disabled = (left ~= nil or V.job ~= nil) or nil,
        onClicked = function() if k == "ent" then enter() else key(k) end end }
    end
    grid[#grid + 1] = rw
  end
  local inv = INV()
  local tool, _, tname = lt.toolFor("force", function(id) return inv and inv.itemCount(PACK, id) or 0 end)
  local secs = tool and lt.forceSecs(tool, lt.roleOf(nil) == "engineer", lt.isDoor(V.sid, V.uid)) or nil
  local kids = { "col", key = "kp", style = "panel/frame", w = 400, h = "fit", gap = 8, pad = 14, align = "stretch",
    { "text", key = "h", style = "panel/heading", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis", text = "KEYPAD · " .. tostring(lt.labelOf(V.sid, V.uid)) },
    { "text", key = "n", style = "panel/label", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis", text = rec_name(V.sid) },
    { "col", key = "lcd", style = "hud/instrument", w = "100%", h = "fit", gap = 2, pad = 10, align = "center",
      { "text", key = "code", style = "hud/valueLg", w = "100%", h = 36, textSize = 30, textAlign = "center", textValign = "center", text = shown },
      { "text", key = "st", style = sst, w = "100%", h = 18, textAlign = "center", text = status } },
    grid }
  if known and st == "locked" then
    kids[#kids + 1] = { "button", key = "known", style = "panel/secondary", w = "100%", h = 30, textAlign = "center", textValign = "center",
      text = "Key in " .. known .. "  (from what you've read)", disabled = (left ~= nil or V.job ~= nil) or nil, onClicked = function() useKnown() end }
  end
  if st == "locked" then
    if V.job then
      local f = math.min(1, V.job.t / V.job.secs)
      kids[#kids + 1] = { "text", key = "jl", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = string.format("%s  %d %%  ·  Esc calls it off", V.job.label, math.floor(f * 100)) }
      kids[#kids + 1] = { "row", key = "jg", w = "100%", h = 8, pad = 0, gap = 0, radius = 1, fill = { 0.02, 0.03, 0.025 },
        { "box", key = "f", w = math.max(2, math.floor(370 * f)), h = 8, radius = 1, fill = { 1.0, 0.55, 0.25 } } }
    else
      kids[#kids + 1] = { "button", key = "force", style = "panel/danger", w = "100%", h = 30, textAlign = "center", textValign = "center",
        text = tool and string.format("Force the lock · %s · %.0f s", tname, secs) or "Force the lock (needs a tool)",
        tooltip = lt.forceWarn(V.sid, V.uid), onClicked = function() force() end }
      kids[#kids + 1] = { "text", key = "fw", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true, maxLines = 3, text = "Forcing it: " .. lt.forceWarn(V.sid, V.uid) }
    end
  end
  kids[#kids + 1] = foot("0–9   ·   Backspace  ⌫   ·   Enter  ENT   ·   Esc or E  leave")
  return kids
end
local function tree_reader()
  local lt = L()
  local rec = lt.logRecord(V.key) or {}
  local well = { "col", key = "well", style = "hud/instrument", w = "100%", h = "fit", gap = 4, pad = 12, align = "stretch",
    { "text", key = "who", style = "hud/micro", w = "100%", h = 16, text = string.format("%s · %s", tostring(rec.who or "?"), tostring(rec.when or "")) } }
  local i = 0
  for _, l in ipairs(rec.lines or {}) do
    i = i + 1
    local isCode = tostring(l):match(":%s*%d%d%d+%s*$") ~= nil
    well[#well + 1] = { "text", key = "l" .. i, style = isCode and "hud/valueAccent" or "hud/value", w = "100%", h = "fit", wrap = true, maxLines = 4, text = tostring(l) }
  end
  if rec.text then well[#well + 1] = { "text", key = "tx", style = "hud/value", w = "100%", h = "fit", wrap = true, maxLines = 8, text = tostring(rec.text) } end
  local notes = {}
  if (V.learned or 0) > 0 then notes[#notes + 1] = string.format("%d code%s noted: the keypads will offer %s", V.learned, V.learned == 1 and "" or "s", V.learned == 1 and "it" or "them") end
  if V.found then local RU = ref("ruins"); local s = RU and RU.site and RU.site(V.found); notes[#notes + 1] = string.format("%s is on the Tracking Station now", s and s.name or "the site") end
  local kids = { "col", key = "rd", style = "panel/frame", w = 640, h = "fit", gap = 8, pad = 14, align = "stretch",
    { "text", key = "h", style = "panel/heading", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis", text = "DATA LOG · " .. tostring(rec.title or "?") },
    well }
  if #notes > 0 then kids[#kids + 1] = { "text", key = "nt", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = table.concat(notes, "   ·   ") } end
  kids[#kids + 1] = foot((V.from and V.from.mode == "box") and "Esc  back to the box   ·   E  leave" or "Esc or E  close")
  return kids
end
local function tree()
  first_named = false
  if V.mode == "keypad" then return tree_keypad() end
  if V.mode == "reader" then return tree_reader() end
  return tree_box()
end
function treeNow() if not V then return nil end return tree() end
local SIG_KEYS = { "text", "style", "w", "disabled", "name", "tooltip" }
local function sig_of(t, acc)
  if type(t) ~= "table" then return acc end
  if type(t[1]) == "string" then acc[#acc + 1] = t[1] end
  for _, k in ipairs(SIG_KEYS) do local v = t[k]; if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then acc[#acc + 1] = k .. "=" .. tostring(v) end end
  for _, v in ipairs(t) do if type(v) == "table" then sig_of(v, acc) end end
  acc[#acc + 1] = "/"
  return acc
end
local function describe()
  local w0 = wall()
  local okt, tr = pcall(tree)
  if not okt then
    if log and V.err ~= tr then V.err = tr; log("loot_panel: tree failed: " .. tostring(tr)) end
    tr = { "col", key = "err", style = "panel/frame", w = 400, h = "fit", pad = 14, { "text", key = "t", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = "PANEL FAULT: " .. tostring(tr) } }
  end
  local sig = table.concat(sig_of(tr, {}), "|")
  if sig ~= V.sig then
    local ok, err = pcall(ui.make, V.node, { tr })
    if not ok and log and V.mkerr ~= err then V.mkerr = err; log("loot_panel: ui.make failed: " .. tostring(err)) end
    V.sig = sig
    PROF.makes = PROF.makes + 1
  end
  if w0 then
    PROF.describes = PROF.describes + 1
    PROF.last_ms = (wall() - w0) * 1000
    PROF.desc_ms = PROF.desc_ms + PROF.last_ms
  end
end

-- ── the walk-up prompt ──────────────────────────────────────────────────────
-- every container piece and every keypad door: { sid, uid, b, px, py, pz, h, door }
local IDX = { ver = nil, list = {}, t = -10 }
local function rebuild_index()
  local ST = ref("structures")
  if not (ST and ST.list) then return end
  IDX.list = {}
  for _, rec in ipairs(ST.list()) do
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      local st = ST.partState and ST.partState(rec.id, p.uid)
      if d and (d.container or (d.door and st and st.kp)) then
        local px, py, pz = ST.partPose(rec, p, 0)
        local b = d.box
        IDX.list[#IDX.list + 1] = { sid = rec.id, uid = p.uid, b = rec.b, px = px, py = py, pz = pz, h = b and math.min(1.2, (b[3] + b[4]) / 2) or 0.6,
                                    door = d.door ~= nil, container = d.container ~= nil }
      end
    end
  end
  IDX.ver = ST.version
end
function index() return IDX.list end
local P = { node = nil, making = false, said = nil, near = nil, t = -10 }
function near() return P.near end
function prompting() return P.near ~= nil and V == nil end
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
      { "box", key = "l", w = 22, h = 1 }, { "text", key = "t", style = "hud/task", w = "fit", h = "fit", text = text }, { "box", key = "r", w = 22, h = 1 } })
  end
  P.node.visible = true
end
local function hide_prompt() if valid(P.node) and P.node.visible then P.node.visible = false end end
local function blocked_why()
  local T = ref("terminal")
  if T and T.isOpen and T.isOpen() then return "terminal" end
  if T and T.prompting and T.prompting() then return "a console's prompt" end
  if T and T.blockedWhy then local w = T.blockedWhy(); if w then return w end end
  for _, k in ipairs({ "salvage", "facility_menu", "rope_climb", "repair_bay" }) do
    local s = ref(k)
    if s and s.prompting and s.prompting() then return k end
  end
  return nil
end
local function find_near()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  local a = find and find("Astronaut")
  if not valid(a) then return nil end
  local pc = ref("planet_camera")
  local fx, fy, fz = 0, 0, -1
  if pc and pc.fwd_x then fx, fy, fz = pc.fwd_x, pc.fwd_y, pc.fwd_z end
  local reach = params.reach or 2.0
  local cosA = math.cos(math.rad(params.aim_deg or 60))
  local best, bd = nil, math.huge
  local bodies = {}
  local lt = L()
  for _, c in ipairs(IDX.list) do
    if c.px and c.b then
      local bb = bodies[c.b]
      if bb == nil then bb = (space and space.body and space.body(c.b)) or false; bodies[c.b] = bb end
      if bb then
        local l = math.sqrt(c.px * c.px + c.py * c.py + c.pz * c.pz)
        local ux, uy, uz = c.px / l, c.py / l, c.pz / l
        local wx, wy, wz = bb.x + c.px + ux * c.h, bb.y + c.py + uy * c.h, bb.z + c.pz + uz * c.h
        local dx, dy, dz = wx - a.x, wy - a.y, wz - a.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < reach + 0.4 and d < bd and (c.container or (lt and lt.isLocked(c.sid, c.uid))) then
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
local pad_prev = {}
local function pad_edge(btn)
  local down = input.padButton and input.padButton(1, btn) == true or false
  local was = pad_prev[btn]
  pad_prev[btn] = down
  return down and not was
end

-- ── each frame while open ───────────────────────────────────────────────────
local function open_tick(dt)
  local ST = ref("structures")
  local lt = L()
  if V.mode ~= "reader" or V.sid then
    if not (ST and lt and ST.getPart and ST.getPart(V.sid, V.uid)) then close() return end
    local n = ST.nodeOf and ST.nodeOf(V.sid, V.uid)
    local a = find and find("Astronaut")
    if valid(n) and valid(a) and a.distanceTo and a:distanceTo(n) > (params.reach or 2.0) + 2.5 then close() return end
  end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then close() return end
  if input.setMouseLocked then pcall(input.setMouseLocked, false) end
  if not held_kb then guard(true) end
  if raw_pressed("escape") or pad_edge("East") then
    escTakenAt = time
    if V.job then cancelJob()
    elseif not back() then close() return end
  end
  if (raw_pressed("e") or pad_edge("West")) and now() - (V.opened or 0) > 0.2 then close() return end
  if V.mode == "keypad" and not V.job then
    for k = 0, 9 do if raw_pressed(tostring(k)) or raw_pressed("numpad" .. k) then key(tostring(k)) end end
    if raw_pressed("backspace") then key("del") end
    if raw_pressed("enter") or raw_pressed("return") or raw_pressed("numpadenter") then enter() end
  end
  -- a job (forcing): polled, its noise, finished
  if V.job then
    local J = V.job
    J.t = J.t + dt
    if J.t >= J.next then
      J.next = J.t + 1.6
      if audio and audio.play then
        local n = ST.nodeOf and ST.nodeOf(V.sid, V.uid)
        if valid(n) then local w = n.worldPos; pcall(audio.play, "audio/foley/ratchet_" .. (1 + math.floor(J.t) % 5) .. ".ogg", w.x, w.y, w.z, { maxDistance = 60, track = "SFX", volume = 0.9 }) end
      end
    end
    V.dirty = true
    if J.t >= J.secs then
      V.job = nil
      local ok, why = lt.forceLock(V.sid, V.uid, nil, J.tool)
      say(ok and why or tostring(why), not ok)
      if ok then after_open() end
    end
  end
  if V.switch_t and now() >= V.switch_t then V.switch_t = nil; openContainer(V.sid, V.uid) return end
  if V.close_t and now() >= V.close_t then close() return end
  if not valid(V.node) then
    if V.making or not spawn then return end
    local h = find and find("Ship HUD")
    if not h then return end
    V.making = true
    local me = V
    pcall(spawn, "LootPanel", vec3(0, 0, 0), function(nd)
      me.making = false
      if V ~= me then nd:destroy() return end
      V.node = nd
      V.dirty, V.sig = true, nil
    end, h)
    return
  end
  local t = now()
  if V.dirty or t - V.desc_t >= 1 / (params.refresh or 4) then
    V.dirty = false
    V.desc_t = t
    describe()
  end
  if V.focus ~= false and V.mode ~= "keypad" and ui and ui.focus and find then
    local f = find("LootFirstRow")
    if f then ui.focus(f); V.focus = false end
  end
end

function start(node)
  if findScripts then
    local all = findScripts("loot_panel")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  V, IDX.ver, IDX.list = nil, nil, {}
  P.node, P.making, P.said, P.near = nil, false, nil, nil
end

function update(node, dt)
  if V then open_tick(dt) return end
  local t = now()
  local ST = ref("structures")
  local lt = L()
  if ST and ST.version ~= IDX.ver then
    if IDX.t < 0 then IDX.t = t end
    if t - IDX.t >= 0.5 or IDX.ver == nil then rebuild_index(); IDX.t = -10 end
  end
  if #IDX.list == 0 or not lt then P.near = nil; hide_prompt() return end
  if t - P.t >= 0.125 then
    P.t = t
    local w0 = wall()
    if blocked_why() then P.near = nil else P.near = find_near() end
    if w0 then PROF.closed_ms = PROF.closed_ms + (wall() - w0) * 1000; PROF.closed_n = PROF.closed_n + 1 end
  end
  if not P.near then hide_prompt() return end
  local c = P.near
  local locked = lt.isLocked(c.sid, c.uid)
  local nm2 = lt.labelOf(c.sid, c.uid)
  if locked then show_prompt(string.format("Keypad  ·  %s (locked)   ·   E", nm2))
  else show_prompt(string.format("Open the %s   ·   E", nm2)) end
  if interact_pressed() then
    if locked then openKeypad(c.sid, c.uid) else openContainer(c.sid, c.uid) end
    hide_prompt()
  end
end
