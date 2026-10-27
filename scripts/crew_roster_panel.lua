-- CREW_ROSTER_PANEL — the Astronaut Complex (docs/crew-and-items.md §2.2, §2.3).
--
-- The agency's people, at the Command Centre. Three tabs:
--
--   ROSTER       every living member: name, status, where, and the service
--                record (flights, EVA time, flags, repairs, hire date).
--                Rename · Go to (crew.control: switch to an on-foot member)
--                · Recall (an on-foot member brought home for the pickup fee,
--                flight_ops.pickupFee; arms on the first press, pays on the
--                second, like the Ops Board's ABANDON)
--   APPLICANTS   crew.offers(): name and the one-time fee; HIRE is
--                crew.hire(i). When every astronaut is dead the first one
--                is a FREE volunteer.
--   MEMORIAL     crew.memorial(): name, hire date, date and place of death,
--                the cause in plain words, the craft, flights, EVA time,
--                flags, and "brought home" or "remains on <world>".
--
-- Opened from the Ops Board's CREW button or the Command Centre overview's
-- (facility_menu). facility_menu owns "a panel is up" for it, as it does for
-- the Ops Board: the scrim, E/Esc, and walking out of the building close it
-- (facility_menu.isOpen() answers true while this is up, so the tool belt,
-- the camera and the pause menu stand down without knowing about it).
--
--   openPanel(tab)  close()  isOpen()  typing()  tab()  describe() (tests)
--
-- Everything the crew API answers is read through pcall: WS1 is still
-- filling crew.lua, and a missing function greys a button rather than
-- breaking the panel.

local el

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function call(obj, fn, ...)
  if not (obj and type(obj[fn]) == "function") then return nil end
  local ok, a, b, c = pcall(obj[fn], ...)
  if ok then return a, b, c end
  return nil
end

local function sfx(key)
  local s = ref("sfx")
  if s and s.play then pcall(s.play, key) end
end

function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

local W, PAD = 720, 18
TABS = { "ROSTER", "APPLICANTS", "MEMORIAL" }
local st = { tab = "ROSTER", renaming = nil, msg = nil, msgT = -1e9, armed = nil, armedT = -1e9, sig = nil, t = 0 }
local ARM_TIME = 3.0

local function now() return time or 0 end

function isOpen() return (el and el.visible) or false end
function tab() return st.tab end
function typing() return st.renaming ~= nil end

function openPanel(t)
  st.tab = (t and t:upper()) or st.tab or "ROSTER"
  st.renaming, st.armed, st.sig = nil, nil, nil
  if el then el.visible = true end
  sfx("open")
end

function close()
  if el and el.visible then sfx("close") end
  if el then el.visible = false end
  st.renaming, st.armed = nil, nil
  if ui and ui.focus then pcall(ui.focus, nil) end
end

local function say(msg)
  st.msg, st.msgT = msg, now()
end

-- ── words ───────────────────────────────────────────────────────────────────
-- "Day 41, Y2" (deployables.dateOf when it is in the scene; the same rule here).
function dateOf(t)
  local dp = ref("deployables")
  local s = call(dp, "dateOf", t)
  if s then return s end
  t = tonumber(t) or 0
  local day = math.floor(t / 86400)
  return string.format("Day %d, Y%d", day % 365 + 1, math.floor(day / 365) + 1)
end

function evaText(s)
  s = tonumber(s) or 0
  if s < 60 then return string.format("%d s on EVA", math.floor(s)) end
  if s < 3600 then return string.format("%d min on EVA", math.floor(s / 60)) end
  return string.format("%.1f h on EVA", s / 3600)
end

local function plural(n, one, many)
  n = n or 0
  return string.format("%d %s", n, n == 1 and one or (many or (one .. "s")))
end

function serviceLine(r)
  return table.concat({ plural(r.flights, "flight"), evaText(r.eva_s), plural(r.flags, "flag"),
                        plural(r.repairs, "repair") }, " · ")
end

-- The cause, in plain words (§2.3's table).
CAUSE = {
  impact = "killed on impact", fall = "killed in a fall",
  o2 = "ran out of suit oxygen", oxygen = "ran out of suit oxygen", air = "ran out of suit oxygen",
  drown = "drowned", drowned = "drowned", drowning = "drowned",
  crush = "crushed", crushed = "crushed", pinned = "crushed",
  heat = "burned on re-entry", burn = "burned on re-entry", burned = "burned on re-entry", reentry = "burned on re-entry",
  cabin = "lost when the cabin broke up", part = "lost when the cabin broke up",
  destroyed = "lost when the cabin broke up", craft = "lost with the craft", lost = "lost with the craft",
}
function causeText(d)
  if type(d) ~= "table" then return "cause unknown" end
  local c = d.cause and (CAUSE[d.cause] or tostring(d.cause)) or "cause unknown"
  local det = d.detail or (d.dv and string.format("%.0f m/s", d.dv)) or nil
  -- a detail naming who did it reads on: "shot by Dana Okafor, 30 m"
  if det and tostring(det):sub(1, 3) == "by " then c = c .. " " .. tostring(det)
  elseif det then c = c .. " (" .. tostring(det) .. ")" end
  return c
end

function statusText(r, active)
  local s = r.status
  if s == "aboard" then return "Aboard " .. tostring(r.craft or "a craft") end
  if s == "afoot" then
    return (r.id == active and "On foot (you)" or "On foot") .. (r.body and (" · " .. tostring(r.body)) or "")
  end
  if s == "base" then return "At base" end
  if s == "dead" then return "Dead" end
  return tostring(s or "?")
end

local function money(v)
  local co = ref("company")
  local m = call(co, "money", v)
  return m or string.format("$%d", math.floor((v or 0) + 0.5))
end

-- The pickup fee for an on-foot member: distance from the base on the home
-- world, the cap anywhere else.
function recallFee(r)
  local fo = ref("flight_ops")
  if not (fo and fo.pickupFee) then return nil end
  local home = save and save.get("base.body")
  local d = 1e12
  if r.body and r.body == home and r.x then
    local bx, by, bz = save.get("base.x") or 0, save.get("base.y") or 0, save.get("base.z") or 0
    d = math.sqrt((r.x - bx) ^ 2 + ((r.y or 0) - by) ^ 2 + ((r.z or 0) - bz) ^ 2)
  end
  return call(fo, "pickupFee", d)
end

local function recall(r)
  local fee = recallFee(r) or 0
  local co = ref("company")
  if fee > 0 and co and co.spend then
    if not co.spend(fee, "crew recall: " .. tostring(r.name)) then say("not enough money for the pickup") return false end
  end
  local c = ref("crew")
  local ok = call(c, "recall", r.id)
  if ok == nil then ok = call(c, "patch", r.id, { status = "base", craft = false }) end
  say(ok and (r.name .. " is on the shuttle home") or "the recall did not go through")
  return ok
end

-- ── the tabs ────────────────────────────────────────────────────────────────
local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function small_button(key, text, disabled, tip, fn, style)
  return { "button", key = key, style = style or "panel/secondary", w = (#text > 8) and 120 or 72, h = 26,
    text = text, textAlign = "center", textValign = "center", disabled = disabled, tooltip = tip,
    onClicked = fn }
end

local function roster_rows(c, rows)
  local active = call(c, "activeId")
  local list = call(c, "roster") or {}
  local n = 0
  for _, r in ipairs(list) do
    if r.status ~= "dead" then
      n = n + 1
      local afoot_away = r.status == "afoot" and r.id ~= active
      local armed = st.armed == r.id and now() < st.armedT
      local fee = afoot_away and recallFee(r) or nil
      local name
      if st.renaming == r.id then
        name = { "field", key = "nf", name = "FieldCrewRename", style = "menu/field", w = "grow", h = 26, maxLen = 32,
          text = nil, placeholder = r.name,
          onSubmitted = function(node)
            local s = node and node.text
            if s and #s > 0 then
              local ok, why = call(c, "rename", r.id, s)
              if ok then say("renamed: " .. s) else say("can't rename — " .. tostring(why or "no answer")) end
            end
            st.renaming = nil
            if ui and ui.focus then pcall(ui.focus, nil) end
          end }
      else
        name = { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = r.name }
      end
      rows[#rows + 1] = { "col", key = "m" .. r.id, style = r.id == active and "panel/rowActive" or "panel/row",
        w = "100%", h = "fit", gap = 4, pad = 8, align = "stretch",
        { "row", key = "a", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
          name,
          { "text", key = "s", style = "panel/cell", w = 190, h = "fit", maxLines = 1, overflow = "ellipsis",
            text = statusText(r, active) },
          small_button("rn", st.renaming == r.id and "Cancel" or "Rename", type(c and c.rename) ~= "function",
            "Give them another name", function()
              st.renaming = (st.renaming ~= r.id) and r.id or nil
              if st.renaming and ui and ui.focus then
                -- the field is made on the next describe; focus it then
                st.focusNext = true
              end
            end),
          small_button("go", "Go to", not afoot_away or type(c and c.control) ~= "function",
            afoot_away and "Take control of them" or "Only someone on foot elsewhere", function()
              local ok, why = call(c, "control", r.id)
              if ok then sfx("click"); close() else say("can't switch — " .. tostring(why or "no answer")) end
            end),
          small_button("rc", armed and ("Confirm · " .. money(fee or 0)) or "Recall", not afoot_away or not fee,
            afoot_away and string.format("Bring them home on the shuttle: %s", money(fee or 0)) or "Only someone on foot elsewhere",
            function()
              if st.armed == r.id and now() < st.armedT then
                st.armed = nil
                if recall(r) then sfx("sign") end
              else
                st.armed, st.armedT = r.id, now() + ARM_TIME
                sfx("arm")
              end
            end, armed and "panel/danger" or "panel/secondary") },
        { "text", key = "b", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
          text = serviceLine(r) .. " · hired " .. dateOf(r.hired) .. ((r.cost or 0) > 0 and (" for " .. money(r.cost)) or
            (r.starter and " · founding crew" or "")) } }
    end
  end
  if n == 0 then
    rows[#rows + 1] = wrapped("none", "panel/body", "Nobody on the roster. The applicants are on the next tab.")
  end
end

local function applicant_rows(c, rows)
  local offers = call(c, "offers") or {}
  local co = ref("company")
  local living = 0
  for _, r in ipairs(call(c, "roster") or {}) do if r.status ~= "dead" then living = living + 1 end end
  rows[#rows + 1] = wrapped("about", "panel/body", living == 0
    and "Every astronaut is lost. The first applicant volunteers for nothing, kit included."
    or "A one-time hiring fee and no wages: once they're on the roster they cost nothing. "
       .. "A new hire starts at base with the standard issue.")
  for i, a in ipairs(offers) do
    local free = a.free == true or (a.cost or 0) <= 0
    rows[#rows + 1] = { "row", key = "o" .. i, style = "panel/row", w = "100%", h = "fit", gap = 10, pad = 8, align = "center",
      { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = a.name },
      { "text", key = "c", style = free and "panel/cellStrong" or "panel/figure", w = "fit", h = "fit",
        text = free and "FREE · a volunteer" or money(a.cost) },
      { "button", key = "h", style = "panel/action", w = 96, h = 30, text = "Hire", textAlign = "center", textValign = "center",
        disabled = type(c and c.hire) ~= "function" or (not free and co and co.afford and not co.afford(a.cost)) or nil,
        tooltip = free and "A volunteer: no fee" or ("Hire for " .. money(a.cost)),
        onClicked = function()
          local id, why = call(c, "hire", i)
          if id then
            sfx("sign")
            say(a.name .. " joins the agency, at base")
          else
            say("can't hire — " .. tostring(why or "no answer"))
          end
        end } }
  end
  if #offers == 0 then rows[#rows + 1] = wrapped("none", "panel/hint", "Nobody on the board right now.") end
end

local function memorial_rows(c, rows)
  local list = call(c, "memorial") or {}
  if #list == 0 then
    rows[#rows + 1] = wrapped("none", "panel/body", "No names on the wall.")
    return
  end
  for i, m in ipairs(list) do
    local d = type(m.died) == "table" and m.died or {}
    local where = d.body and (" on " .. tostring(d.body)) or ""
    local fate
    if m.home or d.home then fate = "Brought home"
    elseif d.lost then fate = "Lost in space"
    elseif d.body then fate = "Remains on " .. tostring(d.body)
    else fate = "Remains not recovered" end
    rows[#rows + 1] = { "col", key = "d" .. (m.id or i), style = "panel/row", w = "100%", h = "fit", gap = 3, pad = 8, align = "stretch",
      { "row", key = "a", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
        { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = "† " .. tostring(m.name) },
        { "text", key = "f", style = "panel/cell", w = "fit", h = "fit", text = fate } },
      { "text", key = "c", style = "panel/cell", w = "100%", h = "fit", wrap = true,
        text = string.format("%s%s, %s%s.", causeText(d):sub(1, 1):upper(), causeText(d):sub(2),
          d.date or dateOf(d.st), where) },
      { "text", key = "s", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
        text = string.format("Hired %s%s · %s · %s · %s", dateOf(m.hired),
          d.craft and (" · craft " .. tostring(d.craft)) or "",
          plural(m.flights, "flight"), evaText(m.eva_s), plural(m.flags, "flag planted", "flags planted")) } }
  end
end

function describe()
  local c, co = ref("crew"), ref("company")
  local tabs = { "row", key = "tabs", w = "fit", h = "fit", gap = 4, pad = 0, align = "center" }
  for _, t in ipairs(TABS) do
    tabs[#tabs + 1] = { "button", key = "t" .. t, style = "panel/choice", selected = st.tab == t, w = 124, h = 28,
      text = t, textAlign = "center", textValign = "center",
      onClicked = function() if st.tab ~= t then sfx("click") end st.tab = t; st.renaming = nil; st.armed = nil end }
  end
  local rows = {}
  if not c then
    rows[1] = wrapped("nocrew", "panel/body", "The crew office isn't staffed in this scene.")
  elseif st.tab == "APPLICANTS" then applicant_rows(c, rows)
  elseif st.tab == "MEMORIAL" then memorial_rows(c, rows)
  else roster_rows(c, rows) end
  if st.msg and now() - st.msgT < 6.0 then rows[#rows + 1] = wrapped("msg", "panel/hintWarn", "» " .. st.msg) end
  return { "col", key = "complex", style = "panel/frame", w = "100%", dir = "col", gap = 12, pad = PAD, align = "start",
    { "row", key = "head", w = "100%", h = "fit", gap = 14, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Astronaut Complex" },
      { "text", key = "bal", style = "panel/figure", w = "fit", h = "fit",
        text = co and (call(co, "money", call(co, "balance") or 0) or "") or "" },
      { "button", key = "ops", style = "panel/secondary", w = 108, h = 30, textAlign = "center", text = "Ops Board",
        onClicked = function()
          local ob = ref("ops_board")
          close()
          if ob and ob.openBoard then ob.openBoard() end
        end } },
    tabs,
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "scroll", key = "body", w = "100%", h = "fit", dir = "col", gap = 6, pad = 0, align = "stretch",
      items = rows, function(x) return x end },
    { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 },
    wrapped("hint", "panel/hint", st.renaming and "Type a name and press Enter." or "E or Esc to leave."),
  }
end

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return uiDesignH() * w / h end
  end
  return 1280 * uiDesignH() / 720
end

-- The same answer ops_board gives: is the crew member on foot? The panel is
-- a thing you stand at.
local function crew_afoot()
  local pw = ref("planet_walker")
  return pw ~= nil and pw.onFoot == true
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or not el.visible then return end
  if not crew_afoot() then close() return end
  -- E/Esc and walking out of the building are facility_menu's (it owns the
  -- Esc handshake with the pause menu).
  input.setMouseLocked(false)
  local w = math.min(W, design_width() - 32)
  if el.width ~= w then el.width = w end
  ui.make(node, describe())
  if st.focusNext and ui and ui.focus then
    st.focusNext = nil
    local f = find and find("FieldCrewRename")
    if f then pcall(ui.focus, f) end
  end
end
