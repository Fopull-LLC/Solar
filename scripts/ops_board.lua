-- OPS BOARD — the contracts panel at the Command Centre, and the one screen
-- that tells you what the company is actually doing: balance, standing, the
-- contract on the books with its goals ticked off, and every job you could
-- sign next.
--
-- Opened from the Command Centre's facility panel. One row per contract, the
-- active one first and marked; clicking signs. Abandoning the active one takes
-- two clicks — the first arms it, the second (within a few seconds) confirms —
-- because it costs standing, and one stray click on your own contract used to
-- throw it away. Contracts you can't sign yet are listed greyed underneath,
-- each with what it is waiting for.
-- Hovering a contract puts its brief on the hint line, so the list stays
-- scannable and the detail is one mouse-move away.
--
-- THE SCREEN IS DESCRIBED, NOT AUTHORED. It was six fixed row nodes carrying an
-- `ops_row` script each, which meant the board could show at most five offers
-- and a sixth contract was simply invisible — a silent cap on the mission
-- catalogue that nothing in the mission code knew about. `ui.make` reconciles,
-- so a row that stays is the same entity frame to frame and keeps its hover
-- and its keyboard focus.
--
--   E / Esc    leave
--   ↑ ↓ Enter  the rows are focusable, so the board works without a mouse

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

-- Abandon is armed by the first click and done by a second before this time.
local ARM_TIME = 3.0
local abandon_armed_until = -1

function isOpen()
  return (el and el.visible) or false
end

function openBoard()
  if el then el.visible = true end
  abandon_armed_until = -1
  sfx("open")
end

function closeBoard()
  if el then el.visible = false end
end

function toggle()
  if el then el.visible = not el.visible end
end

-- The brief of whatever row the pointer is over, shown on the hint line.
local hovered = nil

local function hint_line(mi, n_offers)
  if hovered then return (hovered.brief or ""):gsub("\n", "  ") end
  if mi and mi.active and time < abandon_armed_until then
    return "Click it again to ABANDON the contract — it costs 1 reputation."
  end
  if mi and mi.active then
    return "Click the contract on the books twice to abandon it (costs standing).   E or Esc to leave."
  end
  if n_offers > 0 then
    return "Click a contract to sign it. Hover one to read its brief.   E or Esc to leave."
  end
  return "No contracts available — complete the ones you have."
end

-- Every contract the board can show: the active one first, marked, then the
-- offers in catalogue order. However many there are.
local function contracts(mi)
  local out = {}
  if not mi then return out end
  local active = mi.active and mi.byId(mi.active) or nil
  if active then out[#out + 1] = { m = active, active = true } end
  for _, m in ipairs(mi.offers()) do out[#out + 1] = { m = m, active = false } end
  return out
end

-- ── the board ───────────────────────────────────────────────────────────────
--
-- Sizes are the styles' (ui/solar.uistyle.ron). A row that can wrap is full
-- width and "fit" tall, so it grows by the lines it wraps to.
local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function contract_row(c, co, mi)
  local money = (co and co.money) and co.money(c.m.reward) or ("$" .. tostring(c.m.reward))
  local armed = c.active and time < abandon_armed_until
  return {
    "button", key = c.m.id,
    style = c.active and "panel/rowActive" or "panel/row",
    w = "100%", h = 34, dir = "row", gap = 10, align = "center",
    { "text", key = "mark", style = "panel/cell", w = 12, h = "fit",
      text = c.active and "◆" or "›" },
    { "text", key = "title", style = "panel/cellStrong", w = "grow", h = "fit", text = c.m.title },
    { "text", key = "pay", style = "panel/cellStrong", w = 84, h = "fit", textAlign = "end",
      text = money },
    { "text", key = "rep", style = "panel/cellMuted", w = 56, h = "fit", textAlign = "end",
      text = armed and "abandon?" or string.format("rep %+d", c.m.rep or 0) },
    onClicked = function()
      if not mi then return end
      if not c.active then
        if mi.accept(c.m.id) then sfx("sign") end
      elseif time < abandon_armed_until then
        abandon_armed_until = -1
        mi.abandon()
        sfx("close")
      else
        abandon_armed_until = time + ARM_TIME
        sfx("arm")
      end
    end,
    -- The brief on hover: the list stays scannable, the detail is one
    -- mouse-move away. Focus does it too, so a pad gets the same reading.
    onHoverStart  = function() hovered = c.m end,
    onHoverEnd    = function() if hovered == c.m then hovered = nil end end,
    onFocusEnter  = function() hovered = c.m end,
    onFocusExit   = function() if hovered == c.m then hovered = nil end end,
  }
end

-- A contract you can't sign yet: not a button, dimmed, and saying what it is
-- waiting for so the ladder is visible before you are on it.
local function locked_row(u, co)
  local money = (co and co.money) and co.money(u.m.reward) or ("$" .. tostring(u.m.reward))
  return {
    "row", key = "up" .. u.m.id, w = "100%", h = 30, gap = 10, pad = 0, align = "center",
    opacity = 0.55,
    { "text", key = "mark", style = "panel/cellMuted", w = 12, h = "fit", text = "·" },
    { "text", key = "title", style = "panel/cellMuted", w = "grow", h = "fit",
      text = u.m.title .. "  —  after " .. u.needs },
    { "text", key = "pay", style = "panel/cellMuted", w = 84, h = "fit", textAlign = "end",
      text = money },
  }
end

local function describe()
  local co, mi = ref("company"), ref("missions")
  local list = contracts(mi)
  local n_offers = mi and #mi.offers() or 0

  -- The heading: the board's name, and the two numbers it is about.
  local rows = {
    { "row", key = "head", w = "100%", h = "fit", gap = 12, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Ops Board" },
      { "text", key = "bal", style = "panel/figure", w = "fit", h = "fit",
        text = (co and co.money) and co.money(co.balance()) or "" },
      { "text", key = "rep", style = "panel/cellMuted", w = "fit", h = "fit",
        text = co and string.format("reputation %+d", co.rep()) or "" } },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
  }

  local active = list[1] and list[1].active and list[1] or nil
  if active then
    rows[#rows + 1] = { "text", key = "booksL", style = "panel/label", w = "100%", h = "fit",
                        text = "On the books" }
    rows[#rows + 1] = contract_row(active, co, mi)
    for i, l in ipairs(mi.goalLines()) do
      rows[#rows + 1] = wrapped("goal" .. i, l:sub(1, 3) == "✓" and "hud/goalDone" or "hud/goal",
                                "   " .. l)
    end
  end

  local offers = {}
  for _, c in ipairs(list) do if not c.active then offers[#offers + 1] = c end end
  rows[#rows + 1] = { "text", key = "offersL", style = "panel/label", w = "100%", h = "fit",
                      text = #offers > 0 and "Available contracts" or "Available contracts — none right now" }
  rows[#rows + 1] = { "col", key = "contracts", w = "100%", h = "fit", gap = 4, pad = 0,
    items = offers, function(c) return contract_row(c, co, mi) end }
  local later = (mi and mi.upcoming) and mi.upcoming() or {}
  if #later > 0 then
    rows[#rows + 1] = { "text", key = "laterL", style = "panel/label", w = "100%", h = "fit",
                        text = "Coming up" }
    rows[#rows + 1] = { "col", key = "later", w = "100%", h = "fit", gap = 2, pad = 0,
      items = later, function(u) return locked_row(u, co) end }
  end

  local hint = hint_line(mi, n_offers)
  rows[#rows + 1] = { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 }
  rows[#rows + 1] = wrapped("hint", "panel/hint", hint)

  return { "col", key = "board", style = "panel/frame", w = "100%",
           dir = "col", gap = 8, pad = PAD, align = "start",
           items = rows, function(row) return row end }
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
    hovered = nil
    return
  end
  if input.pressed("escape") then
    escTakenAt = time
    el.visible = false
    hovered = nil
    sfx("close")
    return
  end
  -- The pointer belongs to the board while the board is up.
  input.setMouseLocked(false)
  ui.make(node, describe())
end
