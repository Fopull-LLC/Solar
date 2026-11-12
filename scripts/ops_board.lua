-- OPS BOARD — the contracts panel at the Command Centre, and the one screen
-- that tells you what the company is actually doing: balance, reputation, the
-- contract on the books with its goals ticked off, and every job you could
-- sign next.
--
-- Opened by pressing E at the Command Centre. Two panes: the list on the left
-- (the contract on the books first, then what you can sign, then — greyed —
-- what is still to come and what unlocks it), and on the right the DETAIL of
-- whichever one is selected: its brief, its goals, what it pays, and the one
-- button that acts on it. Clicking a row only selects it. Signing is the SIGN
-- button; abandoning is the ABANDON button, which arms on the first press and
-- acts on the second, because it costs reputation. (Signing used to be a single
-- click on the row, and abandoning a second click on the same row — a hidden
-- double-click that nothing on screen admitted to.)
--
-- (Career missions E1) The books hold two contracts, one flight and one
-- ground or client job, both listed first; an offer whose place is taken is
-- still listed, its SIGN greyed with the reason under it. The detail shows
-- the advance on signing and what completion pays after it, and the abandon
-- line says the advance goes back.
--
-- THE SCREEN IS DESCRIBED, NOT AUTHORED. It was six fixed row nodes carrying an
-- `ops_row` script each, which meant the board could show at most five offers
-- and a sixth contract was simply invisible — a silent cap on the mission
-- catalogue that nothing in the mission code knew about. `ui.make` reconciles,
-- so a row that stays is the same entity frame to frame and keeps its hover
-- and its keyboard focus.
--
--   E / Esc    leave
--   ↑ ↓ Enter  the rows and buttons are focusable, so it works without a mouse

local el

-- Cross-script singletons, resolved once and kept.
--
-- `findScript` walks every node in the scene comparing script names — it is not
-- the O(1) lookup `find(name)` is (floptle/0063). Asking for the same managers
-- on every frame of every panel is how this project ended up doing a hundred
-- full scene scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
--
-- This idiom is used in every script here that talks to another one.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

-- IS THE CREW OUT AND ABOUT? Deliberately NOT `astro.visible`: planet_camera
-- hides the body whenever the camera lands within 0.7 m of it, which includes
-- every time the wall-clip ray finds a wall behind you — i.e. constantly, while
-- you are inside one of the base buildings. Gating on visibility switched this
-- off exactly where it was wanted.
--
-- `planet_walker.onFoot` is the question that was meant, and it is always
-- published (the script declares it at load), so the three-scan fallback chain
-- that used to sit under here could never run. It is gone.
local function crew_afoot()
  local pw = ref("planet_walker")
  return pw ~= nil and pw.onFoot == true
end

-- The interface sounds (sfx.lua). Absent in a harness, which is just quiet.
local function sfx(key)
  local s = ref("sfx")
  if s and s.play then s.play(key) end
end

-- The same Esc handshake facility_menu publishes: the frame this board spent
-- an Esc on, which the pause menu then leaves alone.
escTakenAt = -1

-- Abandon is armed by the first press and done by a second before this time.
local ARM_TIME = 3.0
local abandon_armed_until = -1

-- The contract whose detail is open (an id), and the panel's design width.
local selected = nil
local W, PAD, LIST_W = 840, 18, 330

function isOpen()
  return (el and el.visible) or false
end

function openBoard()
  if el then el.visible = true end
  abandon_armed_until = -1
  selected = nil
  sfx("open")
end

function closeBoard()
  if el then el.visible = false end
end

function toggle()
  if el then el.visible = not el.visible end
end

-- Published for the probe and the tests: which contract the detail shows.
function selectedId() return selected end
function selectContract(id) selected = id; abandon_armed_until = -1 end

-- ── the board ───────────────────────────────────────────────────────────────
--
-- Sizes are the styles' (ui/solar.uistyle.ron). A row that can wrap is full
-- width and "fit" tall, so it grows by the lines it wraps to.
local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function money_of(co, v)
  return (co and co.money) and co.money(v) or ("$" .. tostring(v))
end

-- Everything on the board, in list order: { m, state = "active"|"offer"|"locked", needs }.
local function entries(mi)
  local out = {}
  if not mi then return out end
  -- The contracts on the books: one flight, one ground or client job
  -- (missions.lua `actives`, career missions E1), the flight first.
  local ids = (mi.actives and mi.actives()) or { mi.active }
  for _, id in ipairs(ids) do
    local m = id and mi.byId(id)
    if m then out[#out + 1] = { m = m, state = "active" } end
  end
  -- The programme (missions.lua PROGRAMME): the milestones in progress, then
  -- the next one still waiting on another. Done ones are a line at the foot.
  if mi.programme then
    local next_locked = false
    for _, e in ipairs(mi.programme()) do
      if e.state == "active" then
        out[#out + 1] = { m = e.m, state = "prog", prog = true }
      elseif e.state == "locked" and not next_locked then
        next_locked = true
        out[#out + 1] = { m = e.m, state = "proglocked", prog = true, needs = e.needs }
      end
    end
  end
  for _, m in ipairs(mi.offers()) do out[#out + 1] = { m = m, state = "offer" } end
  for _, u in ipairs((mi.upcoming and mi.upcoming()) or {}) do
    out[#out + 1] = { m = u.m, state = "locked", needs = u.needs }
  end
  return out
end

-- The selection falls back to the contract on the books, else the first one you
-- could sign — so the detail pane is never empty while there is anything to say.
local function current(list)
  for _, c in ipairs(list) do if c.m.id == selected then return c end end
  for _, c in ipairs(list) do if c.state ~= "locked" and c.state ~= "proglocked" then return c end end
  return list[1]
end

-- A tier or the Charter is a goal on the horizon, not a contract you can sign:
-- it says "goal" or "from $X" rather than a price that reads like a fee ($0).
local function pay_label(co, m)
  if m.charter then return "GOAL" end
  if m.tier then return (m.reward or 0) > 0 and ("from " .. money_of(co, m.reward)) or "—" end
  return money_of(co, m.reward)
end

local function list_row(c, co, sel)
  local is_sel = sel and sel.m.id == c.m.id
  local locked = c.state == "locked" or c.state == "proglocked"
  return {
    "button", key = c.m.id,
    style = c.state == "active" and "panel/rowActive" or "panel/row",
    selected = is_sel,
    w = "100%", h = locked and 30 or 34, dir = "row", gap = 10, align = "center",
    opacity = locked and (is_sel and 0.85 or 0.55) or 1.0,
    { "text", key = "mark", style = locked and "panel/cellMuted" or "panel/cell", w = 12, h = "fit",
      text = c.state == "active" and "◆" or (c.state == "prog" and "★" or (locked and "·" or "›")) },
    { "text", key = "title", style = locked and "panel/cellMuted" or "panel/cellStrong",
      w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = c.m.title },
    { "text", key = "pay", style = locked and "panel/cellMuted" or "panel/cellStrong",
      w = 104, h = "fit", textAlign = "end", text = pay_label(co, c.m) },
    onClicked = function()
      if selected ~= c.m.id then sfx("click") end
      selected = c.m.id
      abandon_armed_until = -1
    end,
  }
end

-- The goals of the selected contract: ticked live for the one on the books,
-- as plain labels for the rest.
local function goal_lines(mi, c)
  if c.prog and mi.progGoalLines then return mi.progGoalLines(c.m.id) end
  if c.state == "active" and mi.goalLines then return mi.goalLines(c.m.id) end
  local out = {}
  for _, g in ipairs(c.m.goals or {}) do
    local label = (mi.goalLabel and mi.goalLabel(g)) or g.label or g.kind
    out[#out + 1] = "○ " .. tostring(label)
  end
  return out
end

local function detail(mi, co, c)
  local rows = {}
  if not c then
    rows[#rows + 1] = wrapped("none", "panel/body",
      "No contracts on the board right now. Finish the one you have, and more open up.")
    return rows
  end
  local m = c.m
  -- which place on the books it takes (career missions E1: one of each)
  local kind = (mi.slotGroup and (mi.slotGroup(m) == "ground" and " · ground job" or " · flight contract")) or ""
  local status = ({
    active = "On the books" .. kind,
    offer = "Available to sign" .. kind,
    locked = "Unlocks after " .. tostring(c.needs or "?"),
    prog = "Programme milestone · in progress",
    proglocked = "Programme milestone · after " .. tostring(c.needs or "?"),
  })[c.state]
  rows[#rows + 1] = { "text", key = "status", style = "panel/label", w = "100%", h = "fit", text = status }
  rows[#rows + 1] = { "text", key = "dtitle", style = "panel/heading", w = "100%", h = "fit",
                      wrap = true, text = m.title }
  rows[#rows + 1] = wrapped("brief", "panel/body", ((m.brief or ""):gsub("\n", " ")))
  local goals = goal_lines(mi, c)
  if #goals > 0 then
    rows[#rows + 1] = { "text", key = "goalsL", style = "panel/label", w = "100%", h = "fit", text = "Goals" }
    for i, l in ipairs(goals) do
      rows[#rows + 1] = wrapped("goal" .. i, l:sub(1, 3) == "✓" and "hud/goalDone" or "hud/goal", l)
    end
  end
  if c.prog then
    rows[#rows + 1] = { "text", key = "payL", style = "panel/label", w = "100%", h = "fit", text = "Completes for" }
    rows[#rows + 1] = wrapped("pay", "panel/body",
      (mi.progRewardLine and mi.progRewardLine(m)) or money_of(co, m.reward))
    rows[#rows + 1] = { "box", key = "drule", style = "panel/rule", w = "100%", h = 1 }
    rows[#rows + 1] = wrapped("progH", "panel/hint", c.state == "prog"
      and "Nothing to sign: milestones count as they happen, alongside any contract, and each stage pays as it ticks."
      or ("Opens once " .. tostring(c.needs or "the milestone before it") .. " is complete."))
    local net = mi.progNet
    if net and (m.id == "relay_net" or m.id == "sky" or m.id == "beyond") then
      rows[#rows + 1] = wrapped("net", "panel/cellMuted", net.api and string.format(
        "Network: ground %d%% · sky %d%%%s · relays in orbit %d · worlds linked %d",
        math.floor((net.ground or 0) * 100), math.floor((net.sky or 0) * 100),
        net.skyHeld and (" (" .. net.skyHeld .. ")") or "", net.orbit or 0, #(net.linked or {}))
        or "Network: not reporting yet.")
    end
    return rows
  end
  -- The reputation it earns: ground work's point stops at Trusted
  -- (missions.repOf / GROUND_REP_CAP, career missions E1).
  local rp, rcap = 0, nil
  if mi.repOf then rp, rcap = mi.repOf(m) else rp = m.rep or 0 end
  local cap_st = rcap and co and co.standing and co.standing(rcap)
  local reptext = (rp > 0 and string.format("%+d reputation", rp) or "money, not standing")
    .. ((rp > 0 and cap_st) and (" (up to " .. cap_st.name .. ")") or "")
  if m.ground then reptext = "repeatable · " .. reptext end
  rows[#rows + 1] = { "row", key = "pays", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
    { "text", key = "payL", style = "panel/label", w = "fit", h = "fit", text = "Pays" },
    { "text", key = "pay", style = "panel/figure", w = "fit", h = "fit", text = money_of(co, m.reward) },
    { "text", key = "rep", style = "panel/cellMuted", w = "grow", h = "fit", wrap = true, text = reptext } }
  -- THE ADVANCE: what signing pays now and what is left for completion.
  local adv = 0
  if c.state == "active" and mi.advancePaid then adv = mi.advancePaid(m.id)
  elseif mi.advanceFor then adv = mi.advanceFor(m) end
  if adv > 0 then
    rows[#rows + 1] = wrapped("adv", "panel/body", string.format(c.state == "active"
      and "Advance %s paid at signing  ·  %s on completion"
      or  "Advance %s on signing  ·  %s on completion",
      money_of(co, adv), money_of(co, math.max(0, (m.reward or 0) - adv))))
  end
  rows[#rows + 1] = { "box", key = "drule", style = "panel/rule", w = "100%", h = 1 }

  if c.state == "offer" then
    -- why it can't be signed now (missions.signBlock: its place on the books
    -- is taken); an older missions without it: one contract at a time
    local function sign_block()
      if mi.signBlock then return mi.signBlock(m) end
      return mi.active and "One contract at a time: finish or abandon the one on the books first." or nil
    end
    local block = sign_block()
    rows[#rows + 1] = { "button", key = "sign", style = "panel/action", w = "100%", h = 38,
      textAlign = "center", disabled = block ~= nil, text = "Sign contract",
      onClicked = function()
        if sign_block() then return end
        if mi.accept(m.id) then
          selected = m.id
          sfx("sign")
        end
      end }
    if block then rows[#rows + 1] = wrapped("busy", "panel/hintWarn", block) end
  elseif c.state == "active" then
    local armed = time < abandon_armed_until
    rows[#rows + 1] = { "button", key = "abandon", style = "panel/danger", w = "100%", h = 34,
      textAlign = "center", selected = armed,
      text = armed and "Confirm — abandon it" or "Abandon contract",
      onClicked = function()
        if time < abandon_armed_until then
          abandon_armed_until = -1
          mi.abandon(m.id)
          selected = nil
          sfx("close")
        else
          abandon_armed_until = time + ARM_TIME
          sfx("arm")
        end
      end }
    -- what walking away costs: the advance back (what the balance can't
    -- cover is owed, and then it costs 2 reputation)
    local short = (adv > 0 and co and co.balance) and math.max(0, adv - co.balance()) or 0
    local cost = (adv > 0) and string.format("It returns the %s advance%s and costs %d reputation.",
        money_of(co, adv), short > 0 and string.format(" (%s of it owed, repaid from income)", money_of(co, short)) or "",
        short > 0 and 2 or 1)
      or "It costs 1 reputation."
    rows[#rows + 1] = wrapped("cost", armed and "panel/hintWarn" or "panel/hint", armed
      and ("Press again to abandon. " .. cost .. " Its progress is lost.")
      or  ("Abandoning: " .. cost:sub(1, 1):lower() .. cost:sub(2)))
  else
    rows[#rows + 1] = wrapped("lockedH", "panel/hint",
      "Complete " .. tostring(c.needs or "the contract before it") .. " to unlock this one.")
  end
  return rows
end

local function describe()
  local co, mi = ref("company"), ref("missions")
  local list = entries(mi)
  local sel = current(list)
  if sel then selected = sel.m.id end

  -- The list: three labelled groups.
  local left = {}
  local function group(state, label, empty)
    local any = false
    for _, c in ipairs(list) do
      if c.state == state then
        if not any then
          left[#left + 1] = { "text", key = "L" .. state, style = "panel/label", w = "100%", h = "fit",
                              text = label }
          any = true
        end
        left[#left + 1] = list_row(c, co, sel)
      end
    end
    if not any and empty then
      left[#left + 1] = { "text", key = "L" .. state, style = "panel/label", w = "100%", h = "fit",
                          text = label }
      left[#left + 1] = { "text", key = "E" .. state, style = "panel/cellMuted", w = "100%", h = "fit",
                          text = empty }
    end
  end
  -- two places on the books (one flight, one ground or client job)
  local booked = 0
  for _, c in ipairs(list) do if c.state == "active" then booked = booked + 1 end end
  group("active", (mi and mi.actives) and string.format("On the books · %d of 2", booked) or "On the books", nil)
  group("prog", "Programme", nil)
  group("proglocked", (function()
    for _, c in ipairs(list) do if c.state == "prog" then return "Programme · next" end end
    return "Programme"
  end)(), nil)
  group("offer", "Available", booked > 0 and "Nothing else to sign yet." or "None right now.")
  group("locked", "Coming up", nil)
  if mi and mi.programme then
    local done = {}
    for _, e in ipairs(mi.programme()) do if e.state == "done" then done[#done + 1] = e.m.title end end
    if #done > 0 then
      left[#left + 1] = { "text", key = "progdone", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
                          text = "Milestones done: " .. table.concat(done, ", ") }
    end
  end

  local board = { "col", key = "board", style = "panel/frame", w = "100%",
    dir = "col", gap = 12, pad = PAD, align = "start",
    -- Heading: the board's name and the two numbers it is about, and the way
    -- back to the company overview (the Command Centre's other screen).
    { "row", key = "head", w = "100%", h = "fit", gap = 14, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Ops Board" },
      { "text", key = "bal", style = "panel/figure", w = "fit", h = "fit",
        text = co and money_of(co, co.balance()) or "" },
      { "text", key = "rep", style = "panel/cellMuted", w = "fit", h = "fit",
        -- The tier name when the company has one ("Contractor · +5 (Trusted
        -- at 8)"): it is what decides which contracts the board offers.
        text = co and ("Reputation  " .. ((co.standingLine and co.standingLine())
          or string.format("%+d", co.rep()))) or "" },
      { "button", key = "overview", style = "panel/secondary", w = 108, h = 30,
        textAlign = "center", text = "Overview",
        onClicked = function()
          local fm = ref("facility_menu")
          closeBoard()
          if fm and fm.openMenu then fm.openMenu("FacCommand") end
        end },
      -- The Astronaut Complex (crew_roster_panel.lua, docs §2.2): roster,
      -- hiring, memorial. facility_menu owns it once it is up.
      { "button", key = "crew", style = "panel/secondary", w = 84, h = 30,
        textAlign = "center", text = "Crew",
        onClicked = function()
          local fm = ref("facility_menu")
          closeBoard()
          if fm and fm.openRoster then fm.openRoster("ROSTER") end
        end } },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "panes", w = "100%", h = "fit", gap = 24, pad = 0, align = "start",
      -- (a scroll view under the screen's height: with two contracts on the
      -- books, the programme and the board's offers the list outgrew a
      -- 720-high screen and pushed the heading off the top)
      { "scroll", key = "list", w = LIST_W, h = "fit", maxH = math.max(240, uiDesignH() - 190), dir = "col",
        gap = 4, pad = 0, align = "start", scrollFade = 16, items = left, function(x) return x end },
      { "col", key = "detail", w = "grow", h = "fit", gap = 8, pad = 0, align = "start",
        items = detail(mi, co, sel), function(x) return x end } },
    { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 },
    wrapped("hint", "panel/hint", "Click a contract to read it.   E or Esc to leave."),
  }
  -- The world behind is dimmed rather than shown through the panel — by the
  -- shared scrim facility_menu lays under every reading panel.
  return board
end

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return uiDesignH() * w / h end
  end
  return 1280 * uiDesignH() / 720
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  -- A closed board costs nothing.
  if not el or not el.visible then return end
  -- Walking away closes it: the board is a thing you stand at, and a panel that
  -- follows you across the map is a panel you fight.
  if not crew_afoot() then
    el.visible = false
    return
  end
  if input.pressed("escape") then
    escTakenAt = time
    el.visible = false
    sfx("close")
    return
  end
  -- The pointer belongs to the board while the board is up.
  input.setMouseLocked(false)
  local w = math.min(W, design_width() - 32)
  if el.width ~= w then el.width = w end
  ui.make(node, describe())
end
