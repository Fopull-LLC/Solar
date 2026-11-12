-- EXIT PICKER — who steps out (Ty, playtest 2026-11-11: "if you press F to
-- unboard, it asks who you want to unboard").
--
--   ┌ WHO STEPS OUT? · Kestrel I ─────────────────────── ✕ ┐
--   │ [1] [face] D.OKAFOR ★ · PILOT · YOU      Pod Mk2      │  a row a member
--   │ [2] [face] J.REYES · ENGINEER            Pod Mk2      │
--   │ [3] [face] M.HALE · SCIENTIST · no RCS Pack           │
--   │ [4]        EVERYONE                       3 out       │
--   │ F · you   SHIFT · they go, you stay   ESC · cancel    │
--   └──────────────────────────────────────────────────────┘
--
-- F in a craft with two or more aboard opens it (vessel_controller's F; with
-- one aboard F steps out as it always did). A click, the row's number, or
-- the pad (the rows are keys the UI focus reaches: d-pad and A; B or Esc
-- closes) picks. F again picks you. The member picked goes out by
-- crew.eva: someone else takes your control with them, as the crew strip's
-- EVA button does; SHIFT keeps you aboard and sends them alone. EVERYONE
-- sends the rest out first (each waits by the hatch) and you last.
-- A member who can't go says why on their row, greyed (crew.evaCheck); one
-- with no RCS Pack in space is asked about first (eva_pack's confirm).
--
-- While it is open the craft's digits and F stand down (vessel_controller
-- asks isOpen), the mouse is freed (planet_camera's POINTER_PANELS) and Esc
-- is ours (pause_menu's ladder reads escTakenAt).
--
-- Pure (tests/smoke_exit_picker.lua): rows(list, checks, active),
-- keyPick(rows, key), order(list, active).

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

-- ── pure ────────────────────────────────────────────────────────────────────
-- "Dana Okafor" → "D.OKAFOR" (crew_strip's)
function shortName(name)
  name = tostring(name or "?")
  local f, l = name:match("^(%S+)%s+(.+)$")
  if not f then return name:upper() end
  return (f:sub(1, 1) .. "." .. l):upper()
end

MAX_ROWS = 9   -- digits 1…9; a tenth member is reached by the pad or a click

-- The rows the picker shows: one a member aboard (crew.aboard order), then
-- EVERYONE. `checks[id]` = { ok, why, warn } (crew.evaCheck), `active` = the
-- member you control. → { { key = "1", id, name, you, ok, why, warn, label } …,
--   { key = "n", everyone = true, ok, n } }
function rows(list, checks, active)
  local out = {}
  local nok = 0
  for i, m in ipairs(list or {}) do
    if #out >= MAX_ROWS - 1 then break end
    local c = (checks or {})[m.id] or { ok = true }
    out[#out + 1] = { key = tostring(#out + 1), id = m.id, name = m.name, you = m.id == active,
                      commander = m.commander == true, ok = c.ok ~= false, why = c.why, warn = c.warn,
                      label = m.label, uid = m.uid }
    if c.ok ~= false then nok = nok + 1 end
  end
  out[#out + 1] = { key = tostring(#out + 1), everyone = true, ok = nok > 0, n = nok }
  return out
end

-- The row a key picks: a digit, or "f" (you). → row | nil
function keyPick(rs, key)
  if key == "f" then
    for _, r in ipairs(rs or {}) do if r.you then return r end end
    return nil
  end
  for _, r in ipairs(rs or {}) do if r.key == key then return r end end
  return nil
end

-- EVERYONE's order: the others first (they wait by the hatch), you last.
-- Only those who may go. → { id … }, the active member's id or nil
function order(rs, active)
  local out, you = {}, nil
  for _, r in ipairs(rs or {}) do
    if r.id and r.ok then
      if r.id == active then you = r.id else out[#out + 1] = r.id end
    end
  end
  return out, you
end

-- ── state ───────────────────────────────────────────────────────────────────
local el = nil
local open_ = false
local vc = nil            -- the craft (its vessel_controller handle)
local cur = nil           -- the rows as last described
local opened_at = -10     -- (the F that opened it is not a pick)
local pad_b = false       -- the pad's B, last frame (an edge)
focus_want = false
KEYS = { t = -1 }
escTakenAt = -1
closedAt = -10            -- (time) the pick's own F must not reach the craft
lastPick = nil            -- probes: { id | "everyone", stay, ok, why }
function isOpen() return open_ end
-- Open, or closed by a pick a moment ago: the key that picked is still this
-- frame's (and the next physics tick's) press, and vessel_controller's F
-- would read it as a second F (reopen the picker, or with you out by the
-- hatch, board again: Ty 11-12 "they go out and IMMEDIATELY go back in").
function isBusy() return open_ or ((time or 0) - closedAt) < 0.3 end

local function caption(t)
  local fx = ref("sfx")
  if fx and fx.caption then fx.caption(t) end
end

local function list_now()
  local C = ref("crew")
  if not (C and vc and C.aboard) then return {}, nil end
  local list = C.aboard(vc)
  local active = C.activeId and C.activeId()
  local checks = {}
  for _, m in ipairs(list) do
    local ok, why, warn = true, nil, nil
    if C.evaCheck then ok, why, warn = C.evaCheck(m.id) end
    checks[m.id] = { ok = ok, why = why, warn = warn }
  end
  return rows(list, checks, active), active
end

function close(why)
  if open_ and log then log("exit_picker: closed (" .. tostring(why or "a pick") .. ")") end
  if not open_ then return end
  open_ = false
  closedAt = time or 0
  cur = nil
  if el then el.visible = false end
  if ui and ui.focus then pcall(ui.focus, nil) end
end

-- Open for craft `v` (a vessel_controller handle). → true when it opened
-- (two or more aboard); false: the caller steps out as before.
function openFor(v)
  if type(v) == "number" then
    local nid = v
    v = nil
    for _, w in ipairs(findScripts and findScripts("vessel_controller") or {}) do
      if w.node and w.node.valid ~= false and w.node.id == nid then v = w break end
    end
  end
  local C = ref("crew")
  if not (v and C and C.aboard) then return false end
  if #C.aboard(v) < 2 then return false end
  vc = v
  open_ = true
  opened_at = time
  focus_want = true
  if input and input.setMouseLocked then pcall(input.setMouseLocked, false) end
  return true
end

-- One member out. stay: you keep the craft (they wait by the hatch).
local function go(id, stay)
  local C = ref("crew")
  if not (C and C.eva) then return false, "no crew" end
  local ok, why, warn = C.eva(id, { stay = stay })
  if why == "confirm" then
    local ep = ref("eva_pack")
    if ep and ep.askEva then ep.askEva(id, warn, { stay = stay }) return true, "asked" end
  end
  if not ok then caption("can't step out: " .. tostring(why)) end
  return ok, why
end

-- Pick a row (a click, its number, F). → ok, why
function pick(r, stay)
  if log then log(string.format("exit_picker: pick %s (stay %s)", tostring(r and (r.everyone and "everyone" or r.id)), tostring(stay))) end
  if not r then return false, "no such row" end
  if not r.ok then caption(r.why or "can't step out now") return false, r.why end
  local C = ref("crew")
  local active = C and C.activeId and C.activeId()
  local ok, why
  if r.everyone then
    local others, you = order(cur or {}, active)
    for k, id in ipairs(others) do
      local c = C.evaCheck and { C.evaCheck(id) } or { true }
      -- (no RCS Pack in space: they stay aboard; asked one at a time instead)
      if c[3] then caption(string.format("%s stays aboard: no RCS Pack", shortName((C.get(id) or {}).name)))
      else C.eva(id, { stay = true, k = k }) end
    end
    if you then ok, why = go(you, false) else ok, why = #others > 0, nil end
    lastPick = { id = "everyone", n = #others + (you and 1 or 0), ok = ok, why = why }
  else
    -- (you: always out yourself. `stay` sends a member out as a CrewBody
    -- while you keep the craft; for the member you ARE that spawned a second
    -- you by the hatch, the record said afoot and the avatar stayed aboard.
    -- Ty 11-12: "they go out and IMMEDIATELY go back inside".)
    ok, why = go(r.id, (not r.you) and stay == true)
    lastPick = { id = r.id, stay = stay == true, ok = ok, why = why }
  end
  close()
  return ok, why
end

-- Probes: pick by key ("1".."9", "f") as a press would.
function press(key, stay)
  if not open_ then return false, "closed" end
  cur = cur or select(1, list_now())
  return pick(keyPick(cur, key), stay)
end
function rowsNow() return cur end

-- ── the description ─────────────────────────────────────────────────────────
local W = 420
local ROW_H, FACE = 52, 44

local function shift_held()
  return input and input.key and (input.key("shift") or input.key("lshift")) or false
end

local function describe(rs)
  local S = ref("crew_strip")
  local C = ref("crew")
  local root = { "col", key = "xp", style = "hud/card", w = W, h = "fit", gap = 4, pad = 8, align = "start" }
  root[#root + 1] = { "row", key = "hd", w = "100%", h = 20, gap = 6, pad = 0, align = "center",
    { "text", key = "t", style = "panel/heading", w = "grow", h = 20, maxLines = 1, overflow = "ellipsis",
      text = "WHO STEPS OUT? · " .. string.upper(tostring(vc and vc.craftName or "craft")) },
    { "button", key = "x", style = "hud/button", w = 22, h = 20, text = "✕", textAlign = "center", focusable = false,
      onClicked = function() close() end } }
  for _, r in ipairs(rs) do
    local line, sub
    if r.everyone then
      line = "EVERYONE"
      sub = r.ok and string.format("%d out · you last", r.n) or "nobody can go"
    else
      local role = C and C.roleTitle and C.roleTitle(r.id)
      role = role and (tostring(role):match("^(.-)%s*·") or role) or nil
      line = shortName(r.name) .. (r.commander and " ★" or "") .. (role and (" · " .. string.upper(role)) or "")
        .. (r.you and " · YOU" or "")
      sub = (not r.ok and r.why) or (r.warn and "no RCS Pack: asked first") or tostring(r.label or "")
    end
    local tex = (not r.everyone) and S and S.portraitTex and S.portraitTex(r.id) or nil
    local face = tex and { "image", key = "f", texture = tex, w = FACE, h = FACE, imageFit = "cover" }
      or (r.everyone and { "box", key = "f", w = FACE, h = FACE })
      or { "box", key = "f", style = "hud/bezel", w = FACE, h = FACE }
    root[#root + 1] = { "button", key = "r" .. r.key, name = "ExitPick" .. r.key, style = r.you and "panel/rowActive" or "panel/row",
      w = "100%", h = ROW_H, dir = "row", gap = 8, pad = 4, align = "center",
      disabled = (not r.ok) or nil, tooltip = (not r.ok) and r.why or nil,
      { "text", key = "k", style = "panel/keys", w = 18, h = 18, text = r.key, textAlign = "center", textValign = "center" },
      face,
      { "col", key = "c", w = "grow", h = "fit", gap = 2, pad = 0, align = "start",
        { "text", key = "n", style = "panel/cellStrong", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis", text = line },
        { "text", key = "s", style = r.ok and "panel/cellMuted" or "hud/chipWarnText", w = "100%", h = "fit", maxLines = 1,
          overflow = "ellipsis", text = sub } },
      onClicked = function() pick(r, shift_held()) end }
  end
  root[#root + 1] = { "text", key = "ft", style = "hud/micro", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis",
    text = "F · YOU    SHIFT · THEY GO, YOU STAY    ESC · CANCEL" }
  return root
end

-- ── lifecycle ───────────────────────────────────────────────────────────────
function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
end

local make_key, make_t = nil, -10
function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not open_ then return end
  -- the craft gone, nobody aboard it any more, or you out of it: shut
  if not (vc and vc.valid ~= false and vc.crewAboard and vc.node and vc.node.valid ~= false) then close("the craft") return end
  local rs = list_now()
  cur = rs
  if #rs < 2 then close("too few") return end
  if input.pressed("escape") then escTakenAt = time; close("escape") return end
  local b = input.padButton and input.padButton(1, "b") == true or false
  local b_edge = b and not pad_b
  pad_b = b
  if b_edge then close("pad B") return end
  -- (the keys' edges kept here from input.key: input.pressed read from
  -- update answered true for keys nobody pressed on the frame another key
  -- went down — the F that opened this picked row 1 at once. A key already
  -- down when it opened is no press.)
  local fresh = KEYS.t ~= opened_at
  for _, r in ipairs(rs) do
    local k = input.key(r.key) == true
    local edge = k and not KEYS[r.key] and not fresh
    KEYS[r.key] = k
    if edge then pick(r, shift_held()) return end
  end
  local kf = input.key("f") == true
  local ef = kf and not KEYS.f and not fresh
  KEYS.f = kf
  KEYS.t = opened_at
  if ef then pick(keyPick(rs, "f"), false) return end
  if el and not el.visible then el.visible = true end
  local sig = {}
  for _, r in ipairs(rs) do sig[#sig + 1] = (r.id or "e") .. (r.ok and "+" or "-") .. tostring(r.why or "") .. tostring(r.warn ~= nil) end
  local key = table.concat(sig, "|")
  if key ~= make_key or time - make_t > 0.5 then
    make_key, make_t = key, time
    ui.make(node, describe(rs))
    -- the pad lands on the first row that can go
    if ui.focus and find and focus_want then
      for _, r in ipairs(rs) do
        local f = r.ok and find("ExitPick" .. r.key)
        if f then pcall(ui.focus, f); focus_want = false break end
      end
    end
  end
end
