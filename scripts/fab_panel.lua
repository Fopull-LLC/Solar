-- FAB PANEL — a Fabricator's RECIPE panel (expansion X6, N7; docs/base-
-- building.md §24). Opened from a Fabricator's menu ("RECIPE panel — make a
-- part"): two plates over the world.
--
--   THE PARTS   every part the Build Kit's catalogue holds that a Fabricator
--               can make (recipes.recipeFor: not made at home only, not a
--               cable), searchable; a row says what it weighs and whether the
--               store holds what it needs (✓), or that it isn't researched.
--   THE RECIPE  the part picked: each material, what it needs and what the
--               store has (short in amber), the fittings in money, the time
--               (10 s + 20 s a tonne, at the Fabricator's duty now), and
--               QUEUE 1 / QUEUE 5. Under it the queue (four jobs): each job's
--               part, count and progress, a ✕ to cancel (a started job's
--               materials go back to the store), and why the head waits.
--
-- ESC, walking 10 m off, or Close ends it. Nothing runs while it is shut (no
-- update: logistics ticks it while open); open, it repaints when what it
-- shows changes (checked twice a second).
--
-- Runs on the "Fab Panel" UI layer in scenes/system.ron. Probes: open(sid,
-- uid), close(), isOpen(), pick(id), queueSel(n), view.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local el, self_node
local S = { open = false, sid = nil, uid = nil, q = "", sel = nil, last_v = nil, t = -10, msg = nil, msg_t = -10 }
view = S
LEAVE = 10

function isOpen() return S.open end

local function layer_size()
  local st_ = ref("settings")
  local H = (st_ and st_.designHeight and st_.designHeight()) or 720
  local W = 1280
  if camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw and sh and sh > 0 then W = H * sw / sh end
  end
  return W, H
end
local function kgs(v)
  v = v or 0
  if v >= 10000 then return string.format("%.1f t", v / 1000) end
  if v < 10 and v % 1 ~= 0 then return string.format("%.1f kg", v) end
  return string.format("%d kg", math.floor(v + 0.5))
end
local function money(v) local co = ref("company"); return (co and co.money) and co.money(v) or ("$" .. tostring(math.floor((v or 0) + 0.5))) end

local function fab_cid() return "fab:" .. tostring(S.sid) .. "." .. tostring(S.uid) end
local function have(mat) local inv = ref("inventory"); return inv and inv.count(fab_cid(), mat) or 0 end

-- the parts a Fabricator can make, filtered by the search
local list_memo = { q = nil, out = nil }
local function parts_list()
  if list_memo.q == S.q and list_memo.out then return list_memo.out end
  local FB = ref("field_builder")
  local out = {}
  if not (FB and FB.catalogue and FB.recipeOf) then return out end
  local q = (S.q or ""):lower()
  for _, sec in ipairs(FB.catalogue() or {}) do
    for _, id in ipairs(sec.ids or {}) do
      local d = FB.partInfo and FB.partInfo(id)
      local r = d and not (FB.toolDef and FB.toolDef(id)) and FB.recipeOf(id)
      if r and not r.shipOnly and not r.perMetre and (r.total or 0) > 0 then
        local name = (d.label or id) .. ((d.kit and d.matLabel and d.matLabel ~= "Steel") and (" · " .. d.matLabel) or "")
        if q == "" or name:lower():find(q, 1, true) or sec.title:lower():find(q, 1, true) then
          out[#out + 1] = { id = id, name = name, section = sec.title, r = r, d = d }
        end
      end
    end
  end
  list_memo.q, list_memo.out = S.q, out
  return out
end

local function researched(e)
  local rs = ref("research")
  local rid = (e.d and (e.d.vab or e.d.tech)) or e.id
  return not (rs and rs.isUnlocked and not rs.isUnlocked(rid))
end
local function can_make(r)
  for _, m in ipairs(r.mats or {}) do if have(m.mat) + 1e-9 < m.kg then return false end end
  return true
end

local function say(t) S.msg, S.msg_t = t, time or 0 end

function pick(id) S.sel = id; S.last_v = nil end
function queueSel(n)
  local RF = ref("refinery")
  if not (RF and S.sel) then return false end
  local ok, why = RF.queue(S.sid, S.uid, S.sel, n or 1)
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, ok and "click" or "denied") end
  say(ok and string.format("queued: %d × %s", n or 1, tostring(S.sel)) or tostring(why))
  S.last_v = nil
  return ok, why
end

local function left_plate(W, H)
  local list = parts_list()
  local RF = ref("refinery")
  local F, P = nil, nil
  if RF and RF.fabOf then F, P = RF.fabOf(S.sid, S.uid) end
  local M = ref("materials")
  local store = {}
  for _, m in ipairs((M and M.REFINED) or {}) do local n = have(m); if n > 0 then store[#store + 1] = string.format("%s %s", (M.label and M.label(m)) or m, kgs(n)) end end
  local sc = { "scroll", key = "list", name = "FabPanelList", w = "100%", h = "fit", maxH = math.max(160, H - 250), gap = 2, pad = 0, dir = "column" }
  for i, e in ipairs(list) do
    if i > 160 then break end
    local ok = researched(e)
    local mk = ok and can_make(e.r)
    sc[#sc + 1] = { "button", key = "p" .. i, style = (S.sel == e.id) and "panel/rowActive" or "panel/row", w = "100%", h = 26,
      dir = "row", gap = 6, pad = 4, align = "center", opacity = ok and 1 or 0.55,
      onClicked = function() pick(e.id) end,
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = e.name, textValign = "center", maxLines = 1, overflow = "ellipsis" },
      { "text", key = "k", style = "panel/keys", w = 64, h = 18, text = kgs(e.r.kg or 0), textAlign = "end", textValign = "center" },
      { "text", key = "s", style = mk and "panel/keys" or "panel/cellMuted", w = 22, h = 18, text = (not ok) and "🔒" or (mk and "✓" or "·"), textAlign = "end", textValign = "center" } }
  end
  if #list == 0 then sc[#sc + 1] = { "text", key = "none", style = "panel/hint", w = "100%", h = 18, text = "Nothing matches." } end
  local rows = {
    { "text", key = "title", style = "panel/heading", w = "100%", h = 20, text = string.upper((P and P.label) or "Fabricator") .. "  ·  RECIPE" },
    { "text", key = "st", style = "panel/label", w = "100%", h = 30, wrap = true,
      text = "STORE  ·  " .. (#store > 0 and table.concat(store, "  ·  ") or "no refined materials: belt Steel, Glass, Wire, Regocrete in") },
    { "field", key = "q", name = "FabPanelSearch", style = "menu/field", w = "100%", h = 26, textSize = 13, placeholder = "search parts…", maxLen = 32,
      onChanged = function(n) if n then S.q = n.text or ""; S.last_v = nil end end },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    sc,
  }
  return { "col", key = "fabl", style = "panel/frame", pin = "topLeft", x = 24, y = 60, w = 360, h = "fit", gap = 5, pad = 12, align = "stretch",
    items = rows, function(r) return r end }
end

local function right_plate(W, H)
  local RF, FB = ref("refinery"), ref("field_builder")
  local F, P, s = nil, nil, nil
  if RF and RF.fabOf then F, P, s = RF.fabOf(S.sid, S.uid) end
  F = F or { q = {} }
  local rows = {}
  local e = nil
  for _, x in ipairs(parts_list()) do if x.id == S.sel then e = x end end
  if not e and S.sel and FB and FB.recipeOf then
    local d = FB.partInfo and FB.partInfo(S.sel)
    local r = FB.recipeOf(S.sel)
    if d and r then e = { id = S.sel, name = d.label or S.sel, r = r, d = d } end
  end
  local duty = s and s.duty or 0
  if e then
    local r = e.r
    rows[#rows + 1] = { "text", key = "pn", style = "panel/heading", w = "100%", h = 22, text = string.upper(e.name) }
    rows[#rows + 1] = { "text", key = "pk", style = "panel/label", w = "100%", h = 14,
      text = string.format("%s CRATED  ·  %s  ·  %.0f s%s", kgs(r.kg or 0), e.section or "", r.secs or 0, duty > 0 and duty < 1 and string.format(" (at %d %%: %.0f s)", math.floor(duty * 100 + 0.5), (r.secs or 0) / duty) or "") }
    rows[#rows + 1] = { "box", key = "r0", style = "panel/rule", w = "100%", h = 1 }
    for k, m in ipairs(r.mats or {}) do
      local h = have(m.mat)
      local short = h + 1e-9 < m.kg
      local M = ref("materials")
      rows[#rows + 1] = { "row", key = "m" .. k, w = "100%", h = 20, gap = 6, pad = 0, align = "center",
        { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = (M and M.label and M.label(m.mat)) or m.mat, textValign = "center" },
        { "text", key = "v", style = short and "panel/hintWarn" or "panel/keys", w = 150, h = 18,
          text = string.format("%s / %s%s", kgs(h), kgs(m.kg), short and "  short" or "  ✓"), textAlign = "end", textValign = "center" } }
    end
    rows[#rows + 1] = { "row", key = "fit", w = "100%", h = 20, gap = 6, pad = 0, align = "center",
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = "Fittings (valves, seals, chips)", textValign = "center" },
      { "text", key = "v", style = "panel/keys", w = 120, h = 18, text = money(r.fittings or 0), textAlign = "end", textValign = "center" } }
    local ok = researched(e)
    if not ok then
      local rs = ref("research")
      local rid = (e.d and (e.d.vab or e.d.tech)) or e.id
      local t = "Not researched: " .. tostring(rs and rs.lockLine and rs.lockLine(rid) or "")
      rows[#rows + 1] = { "text", key = "lk", style = "panel/hint", w = "100%", h = 32, wrap = true, text = t }
    else
      rows[#rows + 1] = { "row", key = "btn", w = "100%", h = 28, gap = 6, pad = 0,
        { "button", key = "q1", name = "FabQueue1", style = "panel/action", w = "grow", h = 26, text = "Queue 1", textAlign = "center", textValign = "center",
          onClicked = function() queueSel(1) end },
        { "button", key = "q5", name = "FabQueue5", style = "panel/secondary", w = "grow", h = 26, text = "Queue 5", textAlign = "center", textValign = "center",
          onClicked = function() queueSel(5) end } }
    end
  else
    rows[#rows + 1] = { "text", key = "pick", style = "panel/hint", w = "100%", h = 34, wrap = true,
      text = "Pick a part on the left: its recipe, what the store holds of it, and the time it takes." }
  end
  rows[#rows + 1] = { "box", key = "r1", style = "panel/rule", w = "100%", h = 1 }
  rows[#rows + 1] = { "text", key = "ql", style = "panel/label", w = "100%", h = 16, textValign = "end",
    text = string.format("QUEUE  ·  %d of 4 jobs  ·  %d %% duty", #F.q, math.floor(duty * 100 + 0.5)) }
  for k, j in ipairs(F.q) do
    local r = FB and FB.recipeOf and FB.recipeOf(j.id)
    local d = FB and FB.partInfo and FB.partInfo(j.id)
    local pr = (j.started and r) and math.min(1, (j.t or 0) / math.max(1, r.secs or 1)) or 0
    local bar = string.rep("|", math.floor(pr * 16 + 0.5)) .. string.rep(".", 16 - math.floor(pr * 16 + 0.5))
    rows[#rows + 1] = { "row", key = "j" .. k, style = "panel/row", w = "100%", h = 26, gap = 6, pad = 4, align = "center",
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = string.format("%s ×%d", (d and d.label) or tostring(j.id), j.n or 1),
        textValign = "center", maxLines = 1, overflow = "ellipsis" },
      { "text", key = "b", style = "panel/keys", w = 150, h = 18, text = j.done and "[ done · no room ]" or (j.started and ("[" .. bar .. "]") or "waiting"),
        textAlign = "end", textValign = "center" },
      { "button", key = "x", style = "panel/secondary", w = 26, h = 22, text = "✕", textAlign = "center", textValign = "center",
        onClicked = function() local RF2 = ref("refinery"); if RF2 then RF2.cancel(S.sid, S.uid, k); S.last_v = nil end end } }
  end
  if s and s.fwhy then rows[#rows + 1] = { "text", key = "why", style = "panel/hint", w = "100%", h = 32, wrap = true, text = "LIMITED BY " .. s.fwhy } end
  if s and s.why then rows[#rows + 1] = { "text", key = "why2", style = "panel/hint", w = "100%", h = 32, wrap = true, text = "LIMITED BY " .. s.why } end
  if S.msg and (time or 0) - S.msg_t < 4 then rows[#rows + 1] = { "text", key = "msg", style = "panel/label", w = "100%", h = 16, text = S.msg } end
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = 26, gap = 6, pad = 0,
    { "text", key = "k", style = "panel/hint", w = "grow", h = 22, text = "ESC  close  ·  crates wait in its store, in an Engineer's reach", textValign = "center" },
    { "button", key = "close", name = "FabPanelClose", style = "panel/secondary", w = 80, h = 24, text = "Close", textAlign = "center", textValign = "center",
      onClicked = function() close() end } }
  return { "col", key = "fabr", style = "panel/frame", pin = "topLeft", x = 24 + 360 + 14, y = 136, w = 400, h = "fit", gap = 5, pad = 12, align = "stretch",
    items = rows, function(r) return r end }
end

local function redraw(force)
  if not (el and self_node and ui and ui.make) then return end
  local W, H = layer_size()
  if not S.open then ui.make(self_node, {}); return end
  local RF = ref("refinery")
  local F, P, s = nil, nil, nil
  if RF and RF.fabOf then F, P, s = RF.fabOf(S.sid, S.uid) end
  local qs = {}
  for _, j in ipairs((F and F.q) or {}) do qs[#qs + 1] = string.format("%s:%d:%d:%s", tostring(j.id), j.n or 1, math.floor((j.t or 0) * 2), tostring(j.done)) end
  local inv = ref("inventory")
  local v = table.concat({ tostring(S.sel), S.q or "", table.concat(qs, ","), string.format("%.1f", inv and inv.mass(fab_cid()) or 0),
    tostring(s and s.fwhy), tostring(s and s.why), tostring(s and s.duty), math.floor(W), math.floor(H), tostring(S.msg and (time or 0) - S.msg_t < 4) }, "|")
  if v == S.last_v and not force then return end
  S.last_v = v
  if math.abs((el.width or 0) - W) > 0.5 then el.width = W end
  if math.abs((el.height or 0) - H) > 0.5 then el.height = H end
  ui.make(self_node, { left_plate(W, H), right_plate(W, H) })
end

function open(sid, uid)
  local RF = ref("refinery")
  if not (RF and RF.fabOf and RF.fabOf(sid, uid)) then return false end
  S.open, S.sid, S.uid, S.last_v = true, sid, uid, nil
  list_memo.q = nil
  local cm = ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() and cm.close then cm.close() end
  if el then el.visible = true end
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, "open") end
  redraw(true)
  return true
end
function close()
  if not S.open then return end
  S.open = false
  if el then el.visible = false end
  redraw(true)
end

function start(node)
  self_node = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
end

-- (logistics.update calls this while the panel is open: no update of its
-- own, so a shut panel costs nothing a frame)
function tick(dt)
  if not S.open then return end
  if not el and self_node then el = self_node:getcomponent("UiElement") end
  -- walked off, the piece gone, the builder up: end it
  local a = find and find("Astronaut")
  local ST = ref("structures")
  local rec = ST and ST.get(S.sid)
  local p = rec and ST.getPart(S.sid, S.uid)
  if not p then close() return end
  if a and ST.partPose and space and space.body then
    local b = space.body(rec.b)
    local x, y, z = ST.partPose(rec, p, 0)
    if b and x then
      local d = math.sqrt((a.x - b.x - x) ^ 2 + (a.y - b.y - y) ^ 2 + (a.z - b.z - z) ^ 2)
      if d > LEAVE then close() return end
    end
  end
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then close() return end
  if input and input.pressed and input.pressed("escape") then close() return end
  if (time or 0) - S.t >= 0.5 then S.t = time or 0; redraw(false) end
end
