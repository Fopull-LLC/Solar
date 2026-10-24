-- BUILDER_BIND — fast binding (B) and TEST in the builder (docs/builder-design.md
-- §6.3 A and §4.1, WP5).
--
-- FAST BIND. Select a part (a symmetry ring counts as one), press B, press a
-- key. A riveted placard at the cursor says what is being bound:
--
--   ╔═ BIND ═ Servo Hinge ×2 ═════════════════════════╗
--   ║  press a key for  ANGLE   (rate axis)            ║
--   ║  first key = + , second key = −   ·  ⏎ one key   ║
--   ║  [Angle] [Lock / unlock] …   [rate] [position]   ║
--   ╚══════════════════════════════════════════════════╝
--
--   · the part's PRIMARY action is preselected (controls.primaryOf): a joint's
--     axis, a light's on/off, legs, engine, decoupler, brakes, claw, drill;
--     Tab (or a click) picks another;
--   · an action goes on the first key pressed. A reserved flight key is
--     refused in the placard with its reason; a key another group already
--     uses asks "joins Lights (Y) ▸ ⏎ / pick another";
--   · an AXIS takes a key pair: the first key is +, the second −; Enter after
--     the first makes it a one-key toggle between the two stops. W/S, A/D,
--     Q/E or Shift instead put it on PITCH, YAW, ROLL or THROTTLE (position:
--     the joint follows the stick and springs back);
--   · one undo step (builder cmd "bind"), Esc cancels.
--
-- The context menu's keycaps (WP2) open the same placard for one action:
-- beginFor(uid, choiceId). partActions(uid) lists a part's actions with their
-- keys for that menu.
--
-- TEST (T, the builder's flag: testMode / setTestMode). While it is on, the
-- craft's own keys drive it on the stand: group keys fire their actions, axes
-- move their joints, and hinges, pistons and rotors move KINEMATICALLY with
-- everything built on them — the same maths the flight uses
-- (vessel_controller robo_apply), on display nodes only. Nothing is edited;
-- leaving TEST puts every node back. testInputs() hands the live pitch, yaw
-- and roll to WP4's deflection preview.
--
-- A PANEL script on the "BuilderBind" host node of scenes/builder.ron. It
-- talks to the builder only through its public API (findScript("builder")).

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local el = nil
local prompt = nil        -- the open placard (see begin)
local hold_keys = 0       -- frames to keep the keys after the placard closes
local made_open = false
local T = nil             -- TEST state while it runs

-- ── what the prompt binds ───────────────────────────────────────────────────

-- A part's record for the rulebooks: the builder's partRec plus its modules.
local function rec_of(B, E, uid)
  local r = B.partRec and B.partRec(uid)
  if not r then return nil end
  local d = r.def or {}
  return { uid = uid, id = r.id, label = d.label or r.id, kind = d.kind,
           mods = E and E.deriveMods(d, d.mods) or d.mods, sym = r.sym, parent = r.parent, att = r.att,
           af = d.af, x = r.x, y = r.y, z = r.z, B = r.B, def = d }
end

-- The selection with symmetry rings folded in: uids, the label, the count.
local function ring_of(B, uid)
  local r = B.partRec(uid)
  if not (r and r.sym and r.sym ~= 0) then return { uid } end
  local out = {}
  for _, u in ipairs(B.partUids()) do
    local q = B.partRec(u)
    if q and q.sym == r.sym then out[#out + 1] = u end
  end
  return out
end

local function gather(B, uids)
  local out, seen = {}, {}
  for _, u in ipairs(uids or {}) do
    for _, m in ipairs(ring_of(B, u)) do
      if not seen[m] then seen[m] = true; out[#out + 1] = m end
    end
  end
  return out
end

local function groups_now(B)
  if B.groupsNow then
    local g = B.groupsNow()
    return g or {}
  end
  return {}
end

local function ctl_now(B, C)
  local d = B.controlsData and B.controlsData() or nil
  return C.live(d)
end

-- Open the placard for these parts (`choiceId`: which action; nil = primary).
-- Returns true when it opened.
function begin(uids, choiceId)
  local B, E, C = ref("builder"), ref("electronics"), ref("controls")
  if not (B and E and C) then return false end
  if B.testMode and B.testMode() then return false end
  if type(uids) ~= "table" then uids = { uids } end
  local all = gather(B, uids)
  if #all == 0 then
    if B.hint then B.hint("select a part, then B to give it a key", 2.5) end
    return false
  end
  -- the primary part decides the choices; the rest of the selection must
  -- offer the same action (a light and a leg can't share one "primary")
  local lead = rec_of(B, E, uids[#uids])
  if not lead then return false end
  local choices = C.choicesOf(lead, E)
  if #choices == 0 then
    if B.placard then B.placard((lead.label or "that part") .. " has nothing to switch — it's structure", "warn") end
    return false
  end
  local same = {}
  for _, u in ipairs(all) do
    local r = B.partRec(u)
    if r and r.id == lead.id then same[#same + 1] = u end
  end
  local ci = 1
  for i, c in ipairs(choices) do if c.id == choiceId then ci = i end end
  prompt = { uids = same, lead = lead, label = lead.label or lead.id, n = #same, choices = choices, ci = ci,
             mode = "rate", first = nil, confirm = nil, msg = nil, t0 = time or 0, fresh = true }
  return true
end

-- The context menu's keycap: the placard for one action of one part.
function beginFor(uid, choiceId) return begin({ uid }, choiceId) end

function isOpen() return prompt ~= nil end
function close() prompt = nil; hold_keys = 2 end

-- While the placard is up it owns the mouse and the keys (the builder skips
-- its picking and its own keys); TEST owns the keys too.
function ownsMouse()
  if prompt ~= nil then return true end
  local B = ref("builder")
  return (B and B.testMode and B.testMode()) or false   -- TEST edits nothing
end
function ownsKeys()
  local B = ref("builder")
  return prompt ~= nil or hold_keys > 0 or (B and B.testMode and B.testMode()) or false
end

-- WP2's context menu: every action of a part with its keys (controls.partControls).
function partActions(uid)
  local B, E, C = ref("builder"), ref("electronics"), ref("controls")
  if not (B and E and C) then return {} end
  local rec = rec_of(B, E, uid)
  return C.partControls(groups_now(B), B.controlsData and B.controlsData() or nil, rec, E)
end

local function done(B, text)
  if B.hint then B.hint(text, 2.5) end
  if audio then audio.play("audio/kenney/interface/click_001.ogg", { track = "UI", volume = 0.8 }) end
  close()
end

local function refuse(msg)
  prompt.msg = msg
  if audio then audio.play("audio/kenney/interface/error_004.ogg", { track = "UI", volume = 0.5 }) end
end

local function who() return prompt.label .. (prompt.n > 1 and ("  ×" .. prompt.n) or "") end

local STICK = { w = "pitch", s = "pitch", a = "yaw", d = "yaw", q = "roll", e = "roll", shift = "throttle", ctrl = "throttle" }

-- Commit an axis on a built-in source (position: follows the stick).
local function commit_source(B, C, src)
  local c = prompt.choices[prompt.ci]
  local res = B.cmd("bindAxis", { uids = prompt.uids, act = c.axis, src = src, mode = "position", gain = 1, trim = 0 })
  if not res then return refuse(C.lastError or "couldn't bind that") end
  done(B, string.format("%s · %s on %s", who(), c.label, C.sourceLabel(nil, src)))
end

local function commit_pair(B, C, pos, neg)
  local c = prompt.choices[prompt.ci]
  local mode = neg and prompt.mode or "position"
  local res = B.cmd("bind", { uids = prompt.uids, axis = c.axis, pos = pos, neg = neg, mode = mode,
                              name = prompt.label })
  if not res then return refuse(C.lastError or "couldn't bind that") end
  done(B, string.format("%s · %s on %s%s", who(), c.label,
    C.keyLabel(pos) .. (neg and ("/" .. C.keyLabel(neg)) or " (toggle)"), neg and ("  ·  " .. mode) or ""))
end

local function commit_key(B, C, k)
  local c = prompt.choices[prompt.ci]
  local res = B.cmd("bind", { uids = prompt.uids, acts = c.acts, key = k, name = prompt.label })
  if not res then return refuse(C.lastError or "couldn't bind that") end
  done(B, string.format("%s · %s on %s", who(), c.label, C.keyLabel(k)))
end

-- One key pressed while the placard is up.
local function on_key(B, E, C, k)
  local c = prompt.choices[prompt.ci]
  prompt.msg = nil
  if c.axis then
    if not prompt.first and STICK[k] then return commit_source(B, C, STICK[k]) end
    local ok, why = C.validKey(k)
    if not ok then return refuse(why) end
    local groups = groups_now(B)
    local gid = C.gidForKey(k, E)
    local g = groups[gid]
    local mine = {}
    for _, u in ipairs(prompt.uids) do mine[u] = true end
    for _, b in ipairs(g and g.binds or {}) do
      if not mine[b.uid] then
        return refuse(string.format("%s is %s already — pick another", C.keyLabel(k), C.groupName(groups, gid, E)))
      end
    end
    for _, u in ipairs(C.keyUse(groups, nil, k, E)) do
      if u.kind == "group" and u.standard then
        return refuse(string.format("%s is the %s key — pick another", C.keyLabel(k), u.name))
      end
    end
    if not prompt.first then
      prompt.first = k
      return
    end
    if k == prompt.first then return end
    return commit_pair(B, C, prompt.first, k)
  end
  local ok, why = C.validKey(k)
  if not ok then return refuse(why) end
  local groups = groups_now(B)
  local use = C.keyUse(groups, B.controlsData and B.controlsData() or nil, k, E)
  for _, u in ipairs(use) do
    if u.kind == "axis" then return refuse(string.format("%s drives %s — pick another", C.keyLabel(k), u.name)) end
  end
  local mine = {}
  for _, u in ipairs(prompt.uids) do mine[u] = true end
  local others = nil
  for _, u in ipairs(use) do
    if u.kind == "group" and u.n > 0 then
      local g = groups[u.gid]
      for _, b in ipairs(g and g.binds or {}) do if not mine[b.uid] then others = u end end
    end
  end
  if others and not (prompt.confirm and prompt.confirm == k) then
    prompt.confirm = k
    prompt.msg = string.format("%s is %s — ⏎ joins it, or press another key", C.keyLabel(k), others.name)
    return
  end
  return commit_key(B, C, k)
end

local function prompt_tick(B, E, C)
  if input.pressed("escape") then
    if B.hint then B.hint("bind cancelled", 1.5) end
    return close()
  end
  if input.pressed("tab") then
    prompt.ci = prompt.ci % #prompt.choices + 1
    prompt.first, prompt.confirm, prompt.msg = nil, nil, nil
    return
  end
  if input.pressed("enter") then
    local c = prompt.choices[prompt.ci]
    if c.axis and prompt.first then return commit_pair(B, C, prompt.first, nil) end
    if prompt.confirm then return commit_key(B, C, prompt.confirm) end
    return
  end
  -- the B that opened it is still "pressed" on the first frame: skip that one
  if prompt.fresh then prompt.fresh = false; if input.pressed("b") then return end end
  for _, k in ipairs(C.CAPTURE_KEYS) do
    if k ~= "tab" and input.pressed(k) then return on_key(B, E, C, k) end
  end
end

-- ── the placard ─────────────────────────────────────────────────────────────

local function design_scale()
  if camera and camera.screenSize then
    local _, sh = camera.screenSize()
    if sh and sh > 0 then return 720 / sh end
  end
  return 1
end

local function placard_tree(B, C)
  local c = prompt.choices[prompt.ci]
  -- at the cursor, kept inside the viewport (between the plates)
  local tb = ref("builder_toolbar")
  local Wl, H = 1280, 720
  if tb and tb.layerSize then Wl, H = tb.layerSize() end
  local V = (tb and tb.builderLayout) and tb.builderLayout(Wl, H).view or { x = 16, y = 16, w = Wl - 32, h = H - 32 }
  local s = H / 720 * design_scale()
  local mx, my = input.mouse()
  local W = math.min(440, V.w - 16)
  local x = math.max(V.x + 8, math.min(mx * s + 18, V.x + V.w - W - 8))
  local y = math.max(V.y + 8, math.min(my * s + 18, V.y + V.h - 250))
  local what
  if c.axis then
    what = prompt.first and string.format("now the − key for %s   (⏎ = one-key toggle on %s)", c.label:upper(), C.keyLabel(prompt.first))
      or string.format("press a key for  %s   (%s axis)", c.label:upper(), prompt.mode)
  else
    what = string.format("press a key for  %s", c.label:upper())
  end
  local kids = {
    { "row", key = "hd", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
      { "text", key = "t", style = "panel/heading", w = "fit", h = "fit", text = "BIND" },
      { "text", key = "p", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = who() },
      { "text", key = "x", style = "panel/cellMuted", w = "fit", h = "fit", text = "Esc cancel" } },
    { "text", key = "what", style = "panel/body", w = "100%", h = "fit", wrap = true, text = what },
    { "text", key = "how", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = c.axis and "first key = + , second key = −  ·  W/S A/D Q/E or Shift = the stick (pitch, yaw, roll, throttle)"
        or "any free key: letters, digits, arrows, [ ] ; ' / and the numpad  ·  Tab: another action" },
  }
  if prompt.msg then
    kids[#kids + 1] = { "text", key = "msg", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = "⚠ " .. prompt.msg }
  end
  local row = { "row", key = "acts", wrap = true, w = "100%", h = "fit", gap = 5, pad = 0 }
  for i, ch in ipairs(prompt.choices) do
    if i <= 10 then
      row[#row + 1] = { "button", key = "c" .. i, style = "panel/choice", selected = i == prompt.ci, w = "fit", h = 24,
        pad = 7, textAlign = "center", textValign = "center", text = ch.label .. (ch.axis and "  ±" or ""),
        onClicked = function() if prompt then prompt.ci = i; prompt.first, prompt.confirm, prompt.msg = nil, nil, nil end end }
    end
  end
  kids[#kids + 1] = row
  if c.axis then
    local mrow = { "row", key = "mode", w = "100%", h = 24, gap = 4, pad = 0, align = "center",
      { "text", key = "l", style = "panel/label", w = 60, h = "fit", text = "KEYS" } }
    for _, m in ipairs({ "rate", "position" }) do
      mrow[#mrow + 1] = { "button", key = m, style = "panel/choice", selected = prompt.mode == m, w = "grow", h = 24,
        textAlign = "center", textValign = "center",
        text = m == "rate" and "rate — holds where it stops" or "position — springs back",
        onClicked = function() if prompt then prompt.mode = m end end }
    end
    kids[#kids + 1] = mrow
    local srow = { "row", key = "src", w = "100%", h = 24, gap = 4, pad = 0, align = "center",
      { "text", key = "l", style = "panel/label", w = 60, h = "fit", text = "STICK" } }
    for _, a in ipairs({ "pitch", "yaw", "roll", "throttle", "steer", "drive" }) do
      srow[#srow + 1] = { "button", key = a, style = "panel/secondary", w = "grow", h = 24, textAlign = "center",
        textValign = "center", text = a:upper(),
        tooltip = "Follow " .. C.sourceLabel(nil, a) .. " (position, gain 1, trim 0 — tune it in CONTROLS)",
        onClicked = function()
          local BB, CC = ref("builder"), ref("controls")
          if prompt and BB and CC then commit_source(BB, CC, a) end
        end }
    end
    kids[#kids + 1] = srow
  end
  return {
    { "box", key = "scrim", style = "panel/scrim", inset = 0 },
    { "col", key = "card", style = "panel/frame", pin = "topLeft", x = x, y = y, w = W, h = "fit", gap = 6, pad = 12,
      items = kids, function(k) return k end },
  }
end

-- ── TEST ────────────────────────────────────────────────────────────────────

local function v3(t) return { t.x, t.y, t.z } end
local function rot(v, k, a)
  local c, s = math.cos(a), math.sin(a)
  local d = k[1] * v[1] + k[2] * v[2] + k[3] * v[3]
  local cx = k[2] * v[3] - k[3] * v[2]
  local cy = k[3] * v[1] - k[1] * v[3]
  local cz = k[1] * v[2] - k[2] * v[1]
  return { v[1] * c + cx * s + k[1] * d * (1 - c), v[2] * c + cy * s + k[2] * d * (1 - c),
           v[3] * c + cz * s + k[3] * d * (1 - c) }
end
-- The builder's own euler convention (builder.lua eulerOf).
local function euler(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z[2])))
  if math.abs(Z[2]) > 1 - 1e-10 then return math.atan2(-X[3], X[1]), pitch, 0 end
  return math.atan2(Z[1], Z[3]), pitch, math.atan2(X[2], Y[2])
end
local function child_named(n, name)
  if not (n and n.valid and n.children) then return nil end
  for _, c in ipairs(n:children()) do if c.name == name then return c end end
  return nil
end

-- Enter TEST: every part's record and rest pose, each joint's moving set
-- (everything built on its far side through the parent tree) and which half
-- of it moves.
local function test_begin(B, E, C)
  local recs, kids = {}, {}
  for _, u in ipairs(B.partUids()) do
    local r = rec_of(B, E, u)
    if r then
      recs[u] = r
      E.stateOf(r)
      if r.parent then
        kids[r.parent] = kids[r.parent] or {}
        table.insert(kids[r.parent], u)
      end
    end
  end
  local robo = {}
  for u, r in pairs(recs) do
    for _, kind in ipairs({ "hinge", "piston", "rotor" }) do
      local m = E.modOf(r, kind)
      if m then
        local set, stack = {}, { u }
        while #stack > 0 do
          local x = table.remove(stack)
          for _, k in ipairs(kids[x] or {}) do
            if not set[k] then set[k] = true; stack[#stack + 1] = k end
          end
        end
        -- the head (+Y) moves when what is built on it sits on its top
        local up, dn = 0, 0
        for _, k in ipairs(kids[u] or {}) do
          local q = recs[k]
          local h = (q.x - r.x) * r.B.Y.x + (q.y - r.y) * r.B.Y.y + (q.z - r.z) * r.B.Y.z
          if q.att == "top" or (q.att ~= "bottom" and h >= 0) then up = up + 1 else dn = dn + 1 end
        end
        local head = up >= dn
        local depth, cur, guard = 0, u, 0
        while recs[cur] and recs[cur].parent and guard < 128 do cur = recs[cur].parent; depth = depth + 1; guard = guard + 1 end
        robo[#robo + 1] = { uid = u, kind = kind, m = m, set = set, head = head, sign = head and 1 or -1, cur = 0,
                            depth = depth, rest = { p = v3(r), X = v3(r.B.X), Y = v3(r.B.Y), Z = v3(r.B.Z) } }
      end
    end
  end
  table.sort(robo, function(a, b) if a.depth ~= b.depth then return a.depth < b.depth end return a.uid < b.uid end)
  local chain = {}
  for _, rb in ipairs(robo) do
    for u in pairs(rb.set) do
      chain[u] = chain[u] or {}
      table.insert(chain[u], 1, rb)  -- innermost first
    end
  end
  local groups = C.deepCopy(groups_now(B))
  T = { recs = recs, robo = robo, chain = chain, groups = groups, ctl = ctl_now(B, C), throttle = 0,
        touched = {}, inputs = {}, t0 = time or 0 }
  if B.hint then
    B.hint("TEST — the craft's keys drive it on the stand  ·  T or Esc to stop", 4.0)
  end
end

local function robo_apply(rb, p, Bs)
  local rest = rb.rest
  if rb.kind == "piston" then
    local e = rb.cur * rb.sign
    return { p[1] + rest.Y[1] * e, p[2] + rest.Y[2] * e, p[3] + rest.Y[3] * e }, Bs
  end
  local axis = (rb.kind == "hinge") and rest.Z or rest.Y
  local ang = math.rad(rb.cur) * rb.sign
  local q = rest.p
  local v = rot({ p[1] - q[1], p[2] - q[2], p[3] - q[3] }, axis, ang)
  return { q[1] + v[1], q[2] + v[2], q[3] + v[3] }, { rot(Bs[1], axis, ang), rot(Bs[2], axis, ang), rot(Bs[3], axis, ang) }
end

local function node_of(B, u)
  return B.partNode and B.partNode(u) or nil
end

local function test_pose(B)
  for u, ch in pairs(T.chain) do
    local n = node_of(B, u)
    local r = T.recs[u]
    if n and n.valid and r then
      local p, Bs = v3(r), { v3(r.B.X), v3(r.B.Y), v3(r.B.Z) }
      for _, rb in ipairs(ch) do p, Bs = robo_apply(rb, p, Bs) end
      n.x, n.y, n.z = p[1], p[2], p[3]
      n.yaw, n.pitch, n.roll = euler(Bs[1], Bs[2], Bs[3])
      T.touched[u] = true
    end
  end
  for _, rb in ipairs(T.robo) do
    local n = node_of(B, rb.uid)
    local mv = n and child_named(n, rb.head and "Head" or "Base")
    if mv then
      if not rb.pose0 then
        rb.pose0 = {}
        for _, nm in ipairs({ "Head", "Base", "Stage" }) do
          local c = child_named(n, nm)
          if c then rb.pose0[nm] = { x = c.x, y = c.y, z = c.z, yaw = c.yaw, pitch = c.pitch, roll = c.roll } end
        end
      end
      local p0 = rb.pose0[mv.name]
      if rb.kind == "piston" then
        local e = rb.cur * rb.sign
        mv.y = p0.y + e
        local stg = child_named(n, "Stage")
        if stg and rb.pose0.Stage then stg.y = rb.pose0.Stage.y + e * 0.5 end
      elseif rb.kind == "hinge" then
        local a = math.rad(rb.cur) * rb.sign
        local c, s = math.cos(a), math.sin(a)
        mv.x, mv.y = p0.x * c - p0.y * s, p0.x * s + p0.y * c
        mv:setAngles(0, 0, a)
      else
        local a = math.rad(rb.cur) * rb.sign
        local c, s = math.cos(a), math.sin(a)
        mv.x, mv.z = p0.x * c + p0.z * s, -p0.x * s + p0.z * c
        mv:setAngles(a, 0, 0)
      end
    end
  end
end

-- Leave TEST: every node we moved goes back to the pose the builder holds.
local function test_end(B)
  if not T then return end
  for u in pairs(T.touched) do
    local n, r = node_of(B, u), B.partRec(u)
    if n and n.valid and r then
      n.x, n.y, n.z = r.x, r.y, r.z
      n.yaw, n.pitch, n.roll = r.yaw or 0, r.pitch or 0, r.roll or 0
    end
  end
  for _, rb in ipairs(T.robo) do
    local n = node_of(B, rb.uid)
    for nm, p in pairs(rb.pose0 or {}) do
      local c = child_named(n, nm)
      if c then c.x, c.y, c.z = p.x, p.y, p.z; c:setAngles(p.yaw or 0, p.pitch or 0, p.roll or 0) end
    end
  end
  T = nil
end

-- One action of one part, the way vessel_controller.partAction does it
-- (state only: nothing decouples or fires on the stand).
local function test_action(E, uid, act, force, amount)
  local r = T.recs[uid]
  if not r then return false end
  act = type(act) == "table" and act or E.actionOf(r, act)
  if not act or act.kind == "trigger" then return false end
  local st = E.stateOf(r)
  if act.kind == "axis" then
    if act.dir ~= 0 and not amount then return false end
    local _, ch = E.applyAction(st, act, nil, act.dir ~= 0 and amount or nil)
    if act.axis == "extension" then st.extended = (st.extension or 0) > 0.4 end
    return ch
  end
  local v, changed = E.applyAction(st, act, force, 1.0)
  if act.state == "extended" and changed then st.extension = v and 0.8 or 0.0 end
  return changed
end

local function test_tick(B, E, C, dt)
  -- T or Esc leaves (the builder owns T too; setting it off twice is harmless)
  if (input.pressed("t") or input.pressed("escape")) and (time or 0) - (T.t0 or 0) > 0.1 then
    if B.setTestMode then B.setTestMode(false) end
    return
  end
  -- the craft's keys: groups (press fires, hold moves axis actions)
  for _, g in ipairs(C.allGroups(T.groups, E)) do
    local k = C.keyOfGroup(g.id, E) or g.key
    local gg = T.groups[g.id]
    if k and gg and #(gg.binds or {}) > 0 then
      if input.pressed(k) then
        E.fireGroup(T.groups, g.id, T.recs, function(uid, act, force) return test_action(E, uid, act, force) end)
      end
      if input.key(k) then
        for _, b in ipairs(gg.binds) do
          local r = T.recs[b.uid]
          local a = r and E.actionOf(r, b.act)
          if a and a.kind == "axis" and a.dir ~= 0 then test_action(E, b.uid, a, nil, (a.rate or 1) * dt) end
        end
      end
    end
  end
  -- the axes, with a throttle lever on Shift / Ctrl
  if input.key("shift") then T.throttle = math.min(1, T.throttle + dt * 0.8) end
  if input.key("ctrl") then T.throttle = math.max(0, T.throttle - dt * 0.8) end
  if input.pressed("z") then T.throttle = 1 end
  if input.pressed("x") then T.throttle = 0 end
  T.inputs = C.readInputs(T.ctl, input.key, input.pressed, { throttle = T.throttle })
  C.apply(C.evaluate(T.ctl, T.inputs, T.recs, dt, E), T.recs, E)
  -- the joints chase their setpoints at their own speed
  for _, rb in ipairs(T.robo) do
    local st = E.stateOf(T.recs[rb.uid])
    local spd = math.max(0.1, (st.speed or 100) / 100)
    if not st.locked then
      if rb.kind == "rotor" then
        if st.spin then rb.cur = (rb.cur + (st.rpm or 0) * 6 * dt) % 360 end
      else
        local want = (rb.kind == "hinge") and math.max(-90, math.min(90, st.angle or 0))
          or math.max(0, math.min(0.8, st.extension or 0))
        local rate = (rb.m.rate or (rb.kind == "hinge" and 30 or 0.3)) * spd
        local d = want - rb.cur
        local step = math.min(math.abs(d), rate * dt)
        rb.cur = rb.cur + (d >= 0 and step or -step)
      end
    end
  end
  test_pose(B)
end

-- The live stick in TEST (WP4's deflection preview): { pitch, yaw, roll,
-- throttle, … } or nil when TEST is off.
function testInputs() return T and T.inputs or nil end

-- A joint's current TEST position (degrees or metres) — probes and WP4.
function testJoint(uid)
  if not T then return nil end
  for _, rb in ipairs(T.robo) do if rb.uid == uid then return rb.cur end end
  return nil
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local B, E, C = ref("builder"), ref("electronics"), ref("controls")
  if not (B and E and C) then return end
  if not refs.registered and B.registerPanel then
    refs.registered = B.registerPanel(ref("builder_bind")) or B.registerPanel({ ownsMouse = ownsMouse, ownsKeys = ownsKeys })
  end
  if hold_keys > 0 then hold_keys = hold_keys - 1 end
  -- TEST
  local testing = B.testMode and B.testMode() or false
  if testing and not T then prompt = nil; test_begin(B, E, C) end
  if not testing and T then test_end(B) end
  if T then test_tick(B, E, C, dt) end
  -- the placard
  if prompt then prompt_tick(B, E, C) end
  local open = prompt ~= nil
  if el then
    -- the host covers the layer while the placard is up (the scrim dims it all)
    if open then
      local tb = ref("builder_toolbar")
      local Wl, H = 1280, 720
      if tb and tb.layerSize then Wl, H = tb.layerSize() end
      if math.abs((el.width or 0) - Wl) > 0.5 then el.width = Wl end
      if math.abs((el.height or 0) - H) > 0.5 then el.height = H end
    end
    if el.visible ~= open then el.visible = open end
  end
  if open then
    ui.make(node, placard_tree(B, C))
  elseif made_open then
    ui.make(node, {})
  end
  made_open = open
end
