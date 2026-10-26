-- INVENTORY PANEL — what's in the suit pack, and where it can go from here.
--
-- Opened with I on foot. It lists the pack's contents and, when you're standing
-- next to something that can hold cargo, offers to move it:
--
--   next to a landed craft with a Cargo Bay  → its hold
--   next to the Commerce Depot               → the warehouse
--
-- Click a row to move that one stack; the button moves everything that fits.
--
-- GEAR (inventory.GEAR) is listed under the cargo: the tools you carry and the
-- consumables (a Relay Beacon) that ride the tool belt until they are used.
--
-- THE DEPOT'S COUNTERS. Gear is bought in one place: standing at the Commerce
-- Depot, the panel is its two counters — BUY (the gear the depot stocks:
-- company money, into the pack, onto the belt) and SELL (the pack, the
-- warehouse and any landed hold, a row per material, through the depot's own
-- sale so prices, standing and discovery premiums are its). There is no buy
-- button anywhere else: a beacon is something you walk home for.
-- Whatever doesn't fit stays in the pack — a transfer never destroys anything,
-- and a full hold says so rather than silently eating the rest.
--
-- Moving cargo into a craft re-applies its mass (vessel_controller.holdApplyMass),
-- so the ship you just loaded actually flies like a loaded ship.
--
-- THE SCREEN IS DESCRIBED, NOT AUTHORED. It used to be eight fixed row nodes in
-- `system.ron`, each carrying its own `inv_row` script, each hiding itself when
-- the pack held fewer than eight stacks. That is a list pretending to be a
-- layout: it could never show a ninth material, it cost eight scripts' worth of
-- per-frame work whether the panel was open or not, and the hover states were
-- nine lines of Lua per row that a stylesheet does for nothing. `ui.make`
-- reconciles, so a row that stays is the same entity frame to frame and keeps
-- its hover and its keyboard focus.
--
--   I / Esc    open / close
--   ↑ ↓ Enter  the rows are focusable, so the panel works without a mouse

defaults = {
  reach = 11.0,   -- how close a craft has to be to load it from the ground
  counter_reach = 15.0, -- how close to the Commerce Depot its counters serve you
}

-- Published.
open = false
targetId = nil
targetLabel = nil

local el

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- THE CREW, if they're out and about — otherwise nil.
--
-- Deliberately NOT `astro.visible`: planet_camera hides the body whenever the
-- camera lands within 0.7 m of it, which includes every time the wall-clip ray
-- finds a wall behind you — i.e. constantly, while you are inside one of the
-- base buildings or standing beside your own rocket. Gating on visibility
-- switched this panel off exactly where it was wanted.
--
-- `planet_walker.onFoot` is the question that was meant, and it is the ONE
-- place in the game that decides.
local function on_foot()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  return find("Astronaut")
end

-- What's in reach that can take cargo. A craft wins over the warehouse if both
-- are close — you walked to the ship for a reason.
local function find_target(astro)
  if not ref("inventory") then return nil, nil end
  local best, bestd, label = nil, params.reach, nil
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.holdId then
      local d = astro:distanceTo(n)
      if d < bestd then
        best, bestd, label = v.holdId, d, (v.craftName or "craft") .. " hold"
      end
    end
  end
  if best then return best, label end
  -- The depot: planet-parented, so its own coordinates are body-relative and
  -- only become world space through its parent chain. `node:distanceTo` composes
  -- that chain in the engine; a raw .x comparison is off by the planet's orbital
  -- position and never fires (see facility_menu). The reach matches the depot's
  -- own prompt, so the row you can click is the row the building answers to.
  local dep = find("FacDepot")
  if dep and astro:distanceTo(dep) < params.counter_reach then
    return "base", "warehouse"
  end
  return nil, nil
end

-- The vessel script owning a hold id (so a transfer can re-apply its mass).
local function vessel_of(hold)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.holdId == hold then return v end
  end
  return nil
end

-- The bottom line: what just happened, for a few seconds, then back to advice.
local msg, msg_t, msg_bad = "", -100, false
local function say(text, bad)
  msg, msg_t, msg_bad = text, time, bad or false
  -- Every line here is the result of a move: a stack landing, or a refusal.
  local fx = ref("sfx")
  if fx and fx.play then fx.play(bad and "denied" or "bag_move") end
end

-- Buy one piece of gear at the depot's BUY counter. Refused anywhere else:
-- the counter is the only place gear is sold.
atCounter = false
counter = "buy"     -- the counter the depot panel shows: "buy" | "sell"
function buyGear(id)
  local inv = ref("inventory")
  if not (inv and inv.buyGear) then return end
  if not atCounter then
    say("gear is sold at the Commerce Depot's BUY counter", true)
    return false
  end
  local g = inv.GEAR and inv.GEAR[id]
  local ok, why = inv.buyGear("astro", id, 1)
  if ok then
    say(string.format("bought a %s — %d in the pack, on the tool belt", g and g.name or id, inv.gearCount("astro", id)))
  else
    say(string.format("can't buy a %s: %s", g and g.name or id, why or "?"), true)
  end
  return ok
end

-- Sell at the SELL counter: the depot's own sale (facility_menu), so prices,
-- standing, contracts kept back and discovery premiums are the depot's.
function sellOne(mat)
  local fm = ref("facility_menu")
  if not (atCounter and fm and fm.depotSellOne) then return end
  fm.depotSellOne(mat)
  local mats = ref("materials")
  say(string.format("%s sold", (mats and mats.label(mat)) or mat))
end

function sellAll()
  local fm = ref("facility_menu")
  if not (atCounter and fm and fm.depotSell) then return end
  if fm.depotUnload then fm.depotUnload() end
  say(fm.depotSell() or "sold")
end

-- ── moving cargo ────────────────────────────────────────────────────────────

-- Move one stack. Called by a row's click.
function moveStack(mat)
  local inv = ref("inventory")
  if not (inv and targetId) then return end
  local have = inv.count("astro", mat)
  local moved = inv.transfer("astro", targetId, mat, have)
  local mats = ref("materials")
  local nm = (mats and mats.label(mat)) or mat
  if moved == 0 then
    say(string.format("%s won't fit in the %s", nm, targetLabel or "hold"), true)
  elseif moved < have then
    say(string.format("%d of %d %s moved — %s full", moved, have, nm, targetLabel or "hold"), true)
  else
    say(string.format("%d × %s → %s", moved, nm, targetLabel or "hold"))
  end
  local v = vessel_of(targetId)
  if v and v.holdApplyMass then v.holdApplyMass(v.node) end
end

function moveAll()
  local inv = ref("inventory")
  if not (inv and targetId) then return end
  local before = inv.mass("astro")
  local n = inv.transferAll("astro", targetId)
  if n == 0 then
    say((before > 0.05) and ("nothing fits in the " .. (targetLabel or "hold"))
      or "the pack is empty", true)
  else
    local rest = inv.mass("astro") > 0.05
    say(string.format("%d unit(s) → %s%s", n, targetLabel or "hold",
      rest and "  (the rest didn't fit)" or ""), rest)
  end
  local v = vessel_of(targetId)
  if v and v.holdApplyMass then v.holdApplyMass(v.node) end
end

-- ── the screen ──────────────────────────────────────────────────────────────

-- Tier tints the row: the drab stuff reads drab, the good stuff doesn't. These
-- are set on the element rather than in the stylesheet on purpose — a style
-- that named `text_color` would overwrite them every frame (ui-styles.md).
local TIER_INK = {
  [3] = { 1.00, 0.86, 0.55 },
  [2] = { 0.72, 0.96, 0.80 },
}
local TIER_DEFAULT = { 0.78, 0.86, 0.94 }

local function hint_line(inv)
  if time - msg_t < 4.0 and msg ~= "" then return msg, msg_bad end
  -- An EMPTY pack wins over a target in reach. Standing at the depot with
  -- nothing on your back, the panel used to say "click a row to move that
  -- stack" above no rows at all.
  if inv and inv.isEmpty("astro") and #(inv.gearItems and inv.gearItems("astro") or {}) == 0 then
    return "Empty — dig rock with the Terrain Laser, uproot plants with the Gravity Gun.", false
  end
  if atCounter then
    return counter == "buy" and "Bought gear goes in the pack and onto the tool belt."
      or "Click a row to sell that material; the button sells the lot.", false
  end
  if targetId then
    return "Click a row to move that stack.", false
  end
  return "Unload at a craft's Cargo Bay or the Commerce Depot.", false
end

-- Sizes are the styles' (ui/solar.uistyle.ron); the one row that can wrap —
-- the hint — is full width and "fit" tall.
local W, PAD = 440, 16                       -- the Inventory Panel node's width; the pad
local METER_W = W - (PAD + 2) * 2

local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

local function stack_row(entry, mats, co)
  local ink = TIER_INK[mats and mats.tier(entry.mat) or 1] or TIER_DEFAULT
  local money = (co and co.money) and co.money(entry.value) or ("$" .. entry.value)
  return {
    "button", key = entry.mat, style = "panel/row", w = "100%", h = 32,
    dir = "row", gap = 10, align = "center",
    -- The tint rides the row and its cells inherit it (they set no colour).
    textR = ink[1], textG = ink[2], textB = ink[3],
    { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end",
      text = string.format("%d ×", entry.n) },
    { "text", key = "name", style = "panel/cell", w = "grow", h = "fit",
      text = mats and mats.label(entry.mat) or entry.mat },
    { "text", key = "kg", style = "panel/cell", w = 64, h = "fit", textAlign = "end",
      text = string.format("%.1f kg", entry.kg) },
    { "text", key = "val", style = "panel/cell", w = 64, h = "fit", textAlign = "end",
      text = money },
    onClicked = function() moveStack(entry.mat) end,
  }
end

-- THE COUNTERS, at the depot. Two keys pick the counter; the one in force is
-- latched. BUY lists what the depot stocks; SELL lists everything one press
-- could sell (the depot's own stock list: pack, warehouse, landed holds).
local function counter_rows(inv, co, mats)
  local out = {}
  local function money(v) return (co and co.money) and co.money(v) or ("$" .. v) end
  out[#out + 1] = { "box", key = "crule", style = "panel/rule", w = "100%", h = 1 }
  out[#out + 1] = { "row", key = "counters", w = "100%", h = "fit", gap = 6, pad = 0, align = "center",
    { "text", key = "at", style = "panel/label", w = "grow", h = "fit", text = "COMMERCE DEPOT" },
    { "button", key = "buy", style = "panel/choice", w = 120, h = 28, selected = counter == "buy",
      textAlign = "center", textValign = "center", text = "Buy counter",
      onClicked = function() counter = "buy" end },
    { "button", key = "sell", style = "panel/choice", w = 120, h = 28, selected = counter == "sell",
      textAlign = "center", textValign = "center", text = "Sell counter",
      onClicked = function() counter = "sell" end } }
  if counter == "buy" then
    local bal = (co and co.balance) and co.balance() or nil
    for _, g in ipairs(inv and inv.shopList and inv.shopList() or {}) do
      local fit, room_why = 1, nil
      if inv.roomForItem then fit, room_why = inv.roomForItem("astro", g.id, 1)
      elseif inv.free("astro") + 1e-6 < g.kg then fit = 0 end
      local room = fit >= 1
      local cash = not bal or bal >= g.cost
      local why = (not cash and "not enough money") or (not room and (room_why or "no room in the pack")) or nil
      out[#out + 1] = { "button", key = "buy_" .. g.id, style = "panel/row", w = "100%", h = 34,
        dir = "row", gap = 10, align = "center", disabled = why and true or nil, opacity = why and 0.55 or nil,
        tooltip = g.about,
        { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", text = g.name },
        { "text", key = "have", style = "panel/cellMuted", w = "fit", h = "fit",
          text = why or string.format("%d carried", inv.gearCount("astro", g.id)) },
        { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end",
          text = g.L and string.format("%.0f kg · %.0f L", g.kg, g.L) or string.format("%.0f kg", g.kg) },
        { "text", key = "pay", style = "panel/cellStrong", w = 64, h = "fit", textAlign = "end", text = money(g.cost) },
        { "text", key = "go", style = "panel/cellMuted", w = 30, h = "fit", textAlign = "end", text = "buy" },
        onClicked = function() buyGear(g.id) end }
    end
  else
    local fm = ref("facility_menu")
    local stock = (fm and fm.depotStock) and fm.depotStock() or {}
    if #stock == 0 then
      out[#out + 1] = { "text", key = "nosell", style = "panel/cellMuted", w = "100%", h = 34,
        textAlign = "center", text = "— nothing to sell: not in the pack, the warehouse or a landed hold —" }
    end
    for _, e in ipairs(stock) do
      local tail = e.kept and "for the contract" or (e.first and string.format("NEW · +%s", money(e.bonus)) or "")
      out[#out + 1] = { "button", key = "sell_" .. e.mat, style = "panel/row", w = "100%", h = 30,
        dir = "row", gap = 10, align = "center", disabled = e.kept or nil, opacity = e.kept and 0.55 or nil,
        { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end", text = string.format("%d ×", e.n) },
        { "text", key = "name", style = "panel/cell", w = "grow", h = "fit",
          text = (mats and mats.label(e.mat)) or e.mat },
        { "text", key = "first", style = e.first and "panel/cellStrong" or "panel/cellMuted", w = "fit", h = "fit", text = tail },
        { "text", key = "pay", style = "panel/cellStrong", w = 64, h = "fit", textAlign = "end",
          text = e.kept and "" or money(e.value) },
        { "text", key = "go", style = "panel/cellMuted", w = 30, h = "fit", textAlign = "end", text = e.kept and "" or "sell" },
        onClicked = function() if not e.kept then sellOne(e.mat) end end }
    end
    if #stock > 0 and fm and fm.depotAction then
      out[#out + 1] = { "button", key = "sellall", style = "panel/action", w = "100%", h = 34,
        text = fm.depotAction() or "Sell everything", onClicked = function() sellAll() end }
    end
  end
  return out
end

local function describe(astro)
  local inv, mats, co, cl = ref("inventory"), ref("materials"), ref("company"), ref("climate")
  local items = inv and inv.items("astro") or {}
  local hint, bad = hint_line(inv)

  local rows = {
    { "row", key = "head", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Inventory" },
      { "text", key = "mass", style = "panel/cellMuted", w = "fit", h = "fit",
        text = "suit pack  " .. (inv and (inv.lineFull or inv.line)("astro") or "") } },
  }
  -- How full, as a shape: the bar goes amber in the last 15 %.
  if inv and inv.cap then
    local cap = inv.cap("astro")
    local frac = cap > 0 and math.max(0, math.min(1, inv.mass("astro") / cap)) or 0
    -- A gauge: a dark groove with an ink bar, caution yellow
    -- when nearly full.
    rows[#rows + 1] = { "row", key = "meter", w = "100%", h = 6, radius = 1, pad = 0, gap = 0,
      fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(2, math.floor(METER_W * frac + 0.5)), h = 6, radius = 1,
        fill = frac > 0.85 and { 1.0, 0.80, 0.28 } or { 0.77, 0.75, 0.68 } } }
  end
  -- Where you are, and what the load would fetch.
  local facts = {}
  local where = cl and cl.surveyLine and cl.surveyLine(astro.x, astro.y, astro.z)
  if where then facts[#facts + 1] = where end
  local worth = inv and inv.totalValue("astro") or 0
  if worth > 0 then
    facts[#facts + 1] = string.format("worth %s at the depot",
      (co and co.money(worth)) or ("$" .. worth))
  end
  if #facts > 0 then
    rows[#rows + 1] = { "text", key = "facts", style = "panel/title", w = "100%", h = "fit",
                        text = table.concat(facts, "   ·   ") }
  end

  if #items == 0 then
    rows[#rows + 1] = { "text", key = "empty", style = "panel/cellMuted", w = "100%",
      h = 40, textAlign = "center", text = "— nothing in the pack —" }
  else
    rows[#rows + 1] = { "row", key = "cols", w = "100%", h = "fit", gap = 10, pad = 0,
      { "box", key = "p", w = 42, h = 1 },
      { "text", key = "a", style = "panel/label", w = "grow", h = "fit", text = "Material" },
      { "text", key = "b", style = "panel/label", w = 64, h = "fit", textAlign = "end", text = "Mass" },
      { "text", key = "c", style = "panel/label", w = 72, h = "fit", textAlign = "end", text = "Value" } }
  end

  -- One row per stack, however many there are. `key` is the material id, so a
  -- stack that survives a transfer keeps its element — and with it the row you
  -- were hovering or had focused.
  rows[#rows + 1] = { "col", key = "stacks", w = "100%", h = "fit", gap = 4, pad = 0,
    items = items, function(entry) return stack_row(entry, mats, co) end }

  -- GEAR: what the crew carries to use, not to sell — the belt's slots, and
  -- what is worn (the RCS Pack, Oxygen Tanks: carried is enough).
  local gear = (inv and inv.gearItems) and inv.gearItems("astro") or {}
  if #gear > 0 then
    local vol = (inv.volume and inv.volCap) and string.format("  ·  %.0f / %.0f L", inv.volume("astro"), inv.volCap("astro")) or ""
    rows[#rows + 1] = { "text", key = "gearH", style = "panel/label", w = "100%", h = "fit", text = "GEAR  ·  ON THE BELT OR WORN" .. vol }
    for _, g in ipairs(gear) do
      local about = inv.GEAR[g.id] and inv.GEAR[g.id].about or ""
      local what = g.kind == "worn" and "worn" or (g.tool and "tool" or "")
      rows[#rows + 1] = { "row", key = "gear_" .. g.id, style = "panel/row", w = "100%", h = 32,
        dir = "row", gap = 10, align = "center",
        { "text", key = "n", style = "panel/cell", w = 34, h = "fit", textAlign = "end",
          text = g.tool and "" or string.format("%d ×", g.n) },
        { "text", key = "name", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = g.name .. "  ·  " .. about },
        { "text", key = "w", style = "panel/cellMuted", w = 40, h = "fit", textAlign = "end", text = what },
        { "text", key = "kg", style = "panel/cell", w = 92, h = "fit", textAlign = "end",
          text = g.L and string.format("%.1f kg · %.0f L", g.kg, g.L) or string.format("%.1f kg", g.kg) } }
      -- each Oxygen Tank's air, fullest first
      if g.fills and g.fillCap then
        local lv = {}
        for i = #g.fills, 1, -1 do
          local f = g.fills[i]
          lv[#lv + 1] = f <= 0 and "empty" or string.format("%.0f min", f / 60)
        end
        rows[#rows + 1] = { "row", key = "fill_" .. g.id, w = "100%", h = 22, gap = 10, pad = 0, align = "center",
          { "box", key = "p", w = 34, h = 1 },
          { "text", key = "t", style = "panel/cellMuted", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
            text = string.format("air  ·  %s  ·  %.0f of %.0f min  ·  refill aboard, at a locker or at the base",
              table.concat(lv, " · "), (g.fill or 0) / 60, #g.fills * g.fillCap / 60) } }
      end
    end
  end

  if atCounter then
    for _, r in ipairs(counter_rows(inv, co, mats)) do rows[#rows + 1] = r end
  end

  -- The one primary action, and only when there is somewhere for it to go.
  if targetId and not atCounter then
    rows[#rows + 1] = { "button", key = "all", style = "panel/action", w = "100%",
      h = 34, text = string.format("Transfer all  →  %s", targetLabel or "hold"),
      onClicked = function() moveAll() end }
  end

  rows[#rows + 1] = { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 }
  -- The hint wraps in its own column and the way out sits beside it, so the
  -- close keys never end up as a stray "close." on a line of their own.
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = "fit", gap = 12, pad = 0, align = "start",
    { "text", key = "hint", style = bad and "panel/hintWarn" or "panel/hint", w = "grow", h = "fit",
      wrap = true, text = hint },
    { "text", key = "close", style = "panel/hint", w = "fit", h = "fit", text = "I / Esc  close" } }

  return { "col", key = "panel", style = "panel/frame", w = "100%",
           dir = "col", gap = 8, pad = PAD + 2, align = "start",
           items = rows, function(row) return row end }
end

-- ── driver ──────────────────────────────────────────────────────────────────

-- Open the pack at a counter (the depot panel's "Buy & sell counters" key).
function openCounters(which)
  open = true
  if which == "sell" or which == "buy" then counter = which end
end

-- The time this panel last closed on Esc (see pause_menu's Esc ladder).
escTakenAt = -1

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
  open = false
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local astro = on_foot()
  if not astro then
    -- (No separate loading check: `onFoot` is already false while the world
    -- streams in.)
    open = false
    el.visible = false
    return
  end
  -- TAB, because Tab is what a player reaches for to open a bag — Minecraft,
  -- Terraria, Valheim, Don't Starve. This game shipped on `I` only because the
  -- editor was swallowing Tab before the game ever saw it (floptle/0084), so
  -- `input.pressed("tab")` had been false for the life of the project and there
  -- was nothing to detect. v0.33.0 hands it back. `I` still works.
  if input.pressed("i") or input.pressed("tab") then open = not open end
  if input.pressed("escape") and open then
    open = false
    escTakenAt = time -- pause_menu reads this: the same Esc must not also pause
  end
  -- Not while the game is paused: the menu owns Esc and the pointer, and a bag
  -- opening behind it is a bag you cannot see or close.
  local pm = ref("pause_menu")
  if pm and pm.open then open = false end
  el.visible = open
  if not open then
    targetId, targetLabel, atCounter = nil, nil, false
    -- A closed panel costs nothing: no target search, no screen described.
    return
  end
  -- The pointer belongs to the panel while the panel is up — v0.26.0 made the
  -- editor's cursor trap re-evaluate every frame, so asking here is enough.
  input.setMouseLocked(false)

  targetId, targetLabel = find_target(astro)
  atCounter = targetId == "base"
  -- Described every frame: the heading carries a live mass and a live valuation
  -- and both change as you mine. `ui.make` RECONCILES rather than rebuilds, so
  -- the cost is one table walk and the rows keep their hover and focus.
  ui.make(node, describe(astro))
end
