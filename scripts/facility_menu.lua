-- FACILITIES MENU — walk the astronaut up to a base building and an
-- "⏎ Enter … [E]" prompt appears; press E (or click it) to open that facility's
-- panel. Press E or Esc (or the ✕ button) to leave.
--
--   Command Centre    → E opens the OPS BOARD, where contracts are signed;
--                       its "Overview" button shows the company: balance,
--                       reputation, the contract on the books, the ledger;
--                       its CREW button (and the overview's) opens the
--                       Astronaut Complex (crew_roster_panel.lua): roster,
--                       applicants, memorial. This menu owns that panel's
--                       E/Esc, walking away and scrim, as it does the board's.
--   Vehicle Assembly  → E opens the builder directly, in the building, over the
--                       live world (scripts/build_host.lua).
--   Tracking Station  → the FLEET board: every craft you have left somewhere
--                       (flight_ops keeps it, in the save), where it is and what
--                       it's doing, and TAKE CONTROL of the selected one (↑ ↓).
--                       A craft with a powered comms dish reports live and is
--                       flown remotely for free; without one the board shows
--                       where you left it and a crew transfer is billed.
--   Commerce Depot    → one press unloads everything and sells it.
--
-- The Power Plant has no panel. It had one that said "Reactor ONLINE" and
-- nothing else — there is no grid to read out — and a prompt that opens a
-- panel with nothing to do in it teaches a player that prompts are skippable.
--
-- Proximity is measured in WORLD space, and the engine is asked for it:
-- `a:distanceTo(b)` composes both nodes' full parent chains (rotation and scale
-- included) rather than trusting a script's own arithmetic. It has to be world
-- space, because the two things being compared do not live in the same frame —
-- a facility is parented to its planet, so its .x/.y/.z are body-relative and
-- ride the orbit, while the astronaut is top-level and reads world. Comparing
-- them raw is off by the planet's orbital position (thousands of units) and the
-- check silently never fires. `world_of` below is the fallback for a build whose
-- node handles predate `distanceTo`.

-- `radius` is the fallback reach, measured from a building's ORIGIN, so it has
-- to cover the building itself now that you can stand INSIDE one: a prompt that
-- only fires outside the front door would go quiet exactly when you walked in.
-- Buildings differ in size, so each carries its own `near` below.
defaults = { radius = 16.0 }

local FAC = {
  -- near = prompt reach in metres, from the prefab ORIGIN — which the engine
  -- puts at the middle of each model's box, so it stands well up in the air
  -- (13.9 m in the 21 m VAB) and off the lot centre where a stair tower or a
  -- crane makes the box lopsided (tools/gen_base.py prints both). The reach
  -- has to clear the building's half-diagonal AND that height.
  --
  -- inside = closer than this you are standing IN it, and "Enter the …" is
  -- an odd thing to be told there; `use` is what the prompt says instead.
  -- Measured from the origin too: at the VAB's floor you are never nearer
  -- than 12.9 m to it. The dish is a machine — it only names itself.
  FacCommand  = { label = "Command Centre",   kind = "command",  near = 22.0,
                  inside = 9.2, use = "Use the Ops console", direct = "Ops Board" },
  -- The VAB is 50 × 50 m (tools/vab_dims.py) and its origin is the floor
  -- slab's centre: 38 m reaches every corner of the high bay (35.4 m) and a
  -- few metres out of either door; inside the walls (24.4 m) you are IN it.
  FacHangar   = { label = "Vehicle Assembly", kind = "hangar",   near = 38.0,
                  inside = 24.0, use = "Open the builder", direct = "builder" },
  FacTracking = { label = "Tracking Station", kind = "tracking", near = 18.0 },
  FacDepot    = { label = "Commerce Depot",   kind = "depot",    near = 18.0,
                  inside = 7.6, use = "Use the depot counter" },
}

-- A node's WORLD position: its own coordinates plus every ancestor's. The
-- fallback for `apart` below, and correct only because this particular chain —
-- system group → planet → facility — carries no rotation and no scale, so
-- summing translations IS the world transform. Anywhere else, ask the engine.
local function world_of(n)
  local x, y, z = n.x, n.y, n.z
  local p, guard = n.parent, 0
  while p and guard < 8 do
    x, y, z = x + p.x, y + p.y, z + p.z
    p, guard = p.parent, guard + 1
  end
  return x, y, z
end

-- Metres between two nodes in world space. The engine's own composition when the
-- handle offers it; the hand-rolled walk when it doesn't.
local function apart(a, b)
  if a.distanceTo then return a:distanceTo(b) end
  local ax, ay, az = world_of(a)
  local bx, by, bz = world_of(b)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- IS THE CREW OUT AND ABOUT? Deliberately NOT `astro.visible`.
--
-- planet_camera hides the astronaut whenever the camera ends up within 0.7 m of
-- them: scrolled into first person, and — this is the one that mattered — any
-- time the wall-clip ray finds a wall behind you. Walking INSIDE the command
-- centre does that on most headings, so the prompt used to vanish the moment you
-- got through the door and come back when you stepped out. Ty: "im still
-- struggling to enter buildings… sometimes they work other times completely
-- broken."
--
-- planet_walker publishes the question that was actually meant. The scan below
-- is the fallback for a scene (or a harness) without one.
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

-- `planet_walker.onFoot` is always published (declared at load), so the
-- three-scan fallback chain that used to sit under this could never run.
local function crew_afoot()
  local pw = ref("planet_walker")
  return pw ~= nil and pw.onFoot == true
end

-- Enter/leave: the E key OR the mapped "Interact" action (input.ron binds it to
-- E and the pad's west face), so the prompt answers a controller too. An action
-- the map doesn't carry reads false rather than erroring, which keeps the raw
-- key working in a project with no map at all.
local function interact_pressed()
  if input.pressed("e") then return true end
  return input.justPressed ~= nil and input.justPressed("Interact") == true
end

-- One console line, only when it CHANGES: "why is there no prompt?" is a
-- question the game should answer by itself — how many buildings exist, which
-- is nearest, how far. Silence means nothing changed, not that nothing ran.
local last_diag = ""
local function diag(msg)
  if msg ~= last_diag then
    last_diag = msg
    log("facilities: " .. msg)
  end
end
local ORDER = { "FacCommand", "FacHangar", "FacTracking", "FacDepot" }

-- How far from the depot a landed craft can be and still be unloaded by the
-- crane. Generous — you land where you can, not where a trigger volume is.
local UNLOAD_RANGE = 140.0

local prompt_n, prompt_el
local panel_el
local title_n, body_n, action_n, action_el
local open_fac = nil   -- name of the facility whose panel is open
local near_fac = nil   -- name of the nearest facility in range

-- Is the ⏎ prompt up — i.e. is E about to mean "go inside"?
--
-- Published because E means two things. It is the interact key here and it is
-- also the tool belt's trigger, so walking up to the Commerce Depot and pressing
-- E to go in ALSO fired the mining laser at the ground you were standing on: a
-- crater in the plaza, a bite out of your heat budget, and a beam across the
-- screen at the exact moment a panel opened over it. The belt asks this and
-- stands its E down while a door is in front of you. LMB still fires, because
-- nothing else wants it.
function prompting() return near_fac ~= nil and open_fac == nil end
-- The depot's last receipt ("sold for $412"), shown under the stock list for a
-- few seconds so the panel confirms what just happened without a popup.
local depot_msg, depot_msg_t = "", -100

-- The panel's look comes from the shared styles (ui/solar.uistyle.ron), so the
-- five buildings read as the same game as the ops board and the suit pack.
local STYLE = {
  ["Facility Prompt"] = "hud/prompt",
  ["Facility Panel"]  = "panel/frame",
  ["Facility Title"]  = "panel/heading",
  ["Facility Body"]   = "panel/body",
  ["Facility Action"] = "panel/action",
  ["Facility Exit"]   = "panel/secondary",
}

local function grab()
  prompt_n = find("Facility Prompt")
  prompt_el = prompt_n and prompt_n:getcomponent("UiElement")
  local panel = find("Facility Panel")
  panel_el = panel and panel:getcomponent("UiElement")
  title_n = find("Facility Title")
  body_n = find("Facility Body")
  action_n = find("Facility Action")
  action_el = action_n and action_n:getcomponent("UiElement")
  for name, style in pairs(STYLE) do
    local n = find(name)
    if n then n.style = style end
  end
end

-- ── sizing ──────────────────────────────────────────────────────────────────
-- The body is "fit" tall in the scene (capped at what fits under the title and
-- over the buttons) and the panel (Fit) grows around it. The prompt is a "fit"
-- row: its label with 22 of room either side.
local PROMPT_PAD = 22
local prompt_said

-- The interface sounds (sfx.lua). Absent in a harness, which is just quiet.
local function sfx(key)
  local s = ref("sfx")
  if s and s.play then s.play(key) end
end

-- ESC IS ANSWERED ONCE. Closing a panel on Esc and the pause menu opening on
-- the same Esc used to happen in the same frame whenever this script ran
-- first: the panel shut, the pause menu then saw nothing open, and opened. The
-- time of the frame an Esc was spent here is published, and pause_menu leaves
-- that frame's Esc alone.
escTakenAt = -1

local function show_prompt(text)
  if not prompt_n or prompt_said == text then return end
  prompt_said = text
  ui.make(prompt_n, { "row", key = "p", w = "fit", h = 36, pad = 0, gap = 0, align = "center",
    items = { { "box", key = "l", w = PROMPT_PAD, h = 1 },
              { "text", key = "t", style = "hud/task", w = "fit", h = "fit", text = text },
              { "box", key = "r", w = PROMPT_PAD, h = 1 } }, function(x) return x end })
end

function start(node)
  grab()
  if prompt_el then prompt_el.visible = false end
  if panel_el then panel_el.visible = false end
end

local function fmt_alt(m)
  m = m or 0
  if math.abs(m) < 0.5 then m = 0 end   -- never "-0 m"
  if math.abs(m) >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

-- ── THE TRACKING STATION ────────────────────────────────────────────────────
--
-- It used to list only craft carrying a powered comms dish — a $420 part locked
-- behind copper — and offer nothing to do about any of them, so for most of a
-- save it said "No vessels are transmitting" while craft sat parked all over
-- the world. It is the fleet board now: EVERY craft you've left (flight_ops'
-- `fleet.craft`), with TAKE CONTROL. The dish still means something: it is the
-- remote control. Over a live link the board's numbers are live and taking
-- control is free; without one it's "last seen", and a crew transfer is billed.
local track_sel = 1        -- which row the action button acts on
local track_msg, track_msg_t = "", -100

local function fleet_rows()
  local fo = ref("flight_ops")
  return (fo and fo.fleetList) and fo.fleetList() or {}
end

local function tracking_body()
  local rows = fleet_rows()
  if #rows == 0 then
    return "No craft out there yet.\n\nAnything you leave behind — END FLIGHT away from the base, or an "
      .. "abort from orbit — stays where it is and appears here, and you can take control of it again.", nil
  end
  track_sel = math.max(1, math.min(track_sel, #rows))
  local co = ref("company")
  local lines = { string.format("%d craft in the field   ·   ↑ ↓ select", #rows), "" }
  for i, e in ipairs(rows) do
    local where = e.body or "?"
    local h = e.alt and fmt_alt(e.alt) or "—"
    local orbit = ""
    if e.status == "in orbit" and e.pe and e.ap then
      orbit = string.format("   pe %s · ap %s", fmt_alt(e.pe), fmt_alt(e.ap))
    end
    local link = e.link and "live link" or (e.comms and "dish down — last seen" or "last seen")
    lines[#lines + 1] = string.format("%s %s   ·   %s   ·   %s   ·   %s%s   ·   %s",
      i == track_sel and "▸" or "  ", e.name, where, h, e.status, orbit, link)
  end
  local e = rows[track_sel]
  lines[#lines + 1] = ""
  if not e.pod then
    lines[#lines + 1] = e.name .. " has no crew pod — it can be tracked, not flown."
  elseif e.piloted then
    lines[#lines + 1] = "You're flying " .. e.name .. "."
  elseif e.fee > 0 then
    lines[#lines + 1] = string.format("No comms link: a shuttle takes the crew out to %s — %s.",
      e.name, co and co.money(e.fee) or ("$" .. e.fee))
  else
    lines[#lines + 1] = "Comms link up: take control from here, free."
  end
  if track_msg ~= "" and time - track_msg_t < 6.0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "» " .. track_msg
  end
  local act = nil
  if e.pod and not e.piloted then
    act = (e.fee > 0)
      and string.format("Take control  ·  %s  ▸", co and co.money(e.fee) or ("$" .. e.fee))
      or "Take control  ▸"
  end
  return table.concat(lines, "\n"), act
end

-- The board's action: take control of the selected craft.
function trackingAction()
  local rows = fleet_rows()
  local e = rows[track_sel]
  local fo = ref("flight_ops")
  if not (e and fo and fo.takeControlOf) then return false end
  local ok, why = fo.takeControlOf(e.fid)
  if ok then return true end
  track_msg, track_msg_t = why or "can't take control", time
  return false
end

function trackingSelect(i) track_sel = i end

-- Is a facility panel up? The tool belt asks, so holding E at the depot digs a
-- hole in the floor instead of… well, exactly that.
function isOpen()
  return open_fac ~= nil or roster_open()
end

-- THE ASTRONAUT COMPLEX (crew_roster_panel.lua). Counted as "a facility panel
-- is up" (isOpen above), so the tool belt, the camera and the pause menu that
-- already stand down for this menu stand down for it too.
function roster_open()
  local rp = ref("crew_roster_panel")
  return rp ~= nil and rp.isOpen ~= nil and rp.isOpen() == true
end

function openRoster(tab)
  local rp = ref("crew_roster_panel")
  if not (rp and rp.openPanel) then return false end
  if open_fac then close() end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() and ob.closeBoard then ob.closeBoard() end
  rp.openPanel(tab or "ROSTER")
  sync_scrim()
  return true
end

-- ── the depot ───────────────────────────────────────────────────────────────

-- Every vessel hold within crane reach of the depot that has something in it.
function landedHolds()
  local inv = ref("inventory")
  local dep = find("FacDepot")
  if not (inv and dep) then return {} end
  -- Both in WORLD space (the depot is planet-parented, a landed craft usually
  -- isn't) — the same rule the proximity check below follows.
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.holdId then
      if apart(dep, n) < UNLOAD_RANGE and not inv.isEmpty(v.holdId) then
        out[#out + 1] = { id = v.holdId, name = v.craftName or "Vessel",
                          kg = inv.mass(v.holdId) }
      end
    end
  end
  return out
end

-- Unload: holds first, then the suit pack. Returns a sentence for the panel.
-- Global so the smoke harness (and any future crane button) can drive it.
function depotUnload()
  local inv = ref("inventory")
  if not inv then return "no inventory system" end
  local moved, from = 0, 0
  for _, h in ipairs(landedHolds()) do
    -- What comes off a craft is FREIGHT, and sells at the freight rate.
    local fr = save.get("depot.freight") or {}
    for _, it in ipairs(inv.items(h.id)) do fr[it.mat] = (fr[it.mat] or 0) + it.n end
    save.set("depot.freight", fr)
    local n = inv.transferAll(h.id, "base")
    if n > 0 then
      moved, from = moved + n, from + 1
      -- An emptied craft flies like an empty craft again: push the manifest's
      -- mass back into its bays.
      for _, v in ipairs(findScripts("vessel_controller")) do
        if v.holdId == h.id and v.holdApplyMass then v.holdApplyMass(v.node) end
      end
    end
  end
  local pack = inv.transferAll("astro", "base")
  moved = moved + pack
  if moved == 0 then return "nothing to unload" end
  return string.format("%d unit(s) into the warehouse%s", moved,
    from > 0 and string.format(" (%d craft)", from) or "")
end

-- Is this material spoken for? A delivery contract on the books needs it IN
-- the warehouse, so it is stored rather than sold.
local function kept_back(mat)
  local mi = ref("missions")
  return mi ~= nil and mi.reserves ~= nil and mi.reserves(mat) == true
end

-- THE FREIGHT RATE. Goods that come off a craft's hold at the depot pad (a
-- rover, a bike's locker, a lander's Cargo Bay) sell for FREIGHT_RATE more
-- than the same goods out of a suit pack: a bulk load is worth more to the
-- depot than handfuls, and a rover is how a broke company earns its way back
-- (playtest 2026-10-26). Counted in units per material at unload
-- (`depot.freight`) and spent as those units are sold or delivered.
FREIGHT_RATE = 0.30

local function freight_units(mat, n)
  local fr = save.get("depot.freight") or {}
  return math.min(n or 0, fr[mat] or 0)
end

-- The depot's price for one material right now: list × standing.
local function price_mult(co)
  if co and co.priceMult then return co.priceMult() end
  return 1.0 + 0.04 * ((co and co.rep()) or 0)
end

-- Has this material ever been sold? Its FIRST sale is a discovery: a premium
-- (materials.discoveryBonus — more for rarer stuff), and for a rare material
-- a point of standing. The panel marks the ones still waiting NEW, because
-- "sell everything" used to be the only button and nothing said which crate
-- was about to be worth ten times its weight.
local function first_sale(mat)
  local sold = save.get("depot.sold") or {}
  return not sold[mat]
end

local function bonus_of(mats, mat)
  if mats.discoveryBonus then return mats.discoveryBonus(mat) end
  return 150 * (1 + mats.tier(mat))
end

-- Sell: the warehouse, at the registry's prices, nudged by standing — except
-- what the contract on the books is waiting for. `only` sells just that one
-- material (the depot's per-material rows); nil sells everything. A first sale
-- of a material is a DISCOVERY — the moment the science half of the game starts
-- paying, and the one time a single crate is worth real money.
function depotSell(only)
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  local rs = ref("research")
  if not (inv and co and mats) then return "no depot systems" end
  local items = inv.items("base")
  if #items == 0 then return "the warehouse is empty" end
  local mult = price_mult(co)
  local total, bonus, firsts, kept, rare = 0, 0, {}, 0, 0
  local sold = save.get("depot.sold") or {}
  local fr = save.get("depot.freight") or {}
  local freight = 0
  for _, it in ipairs(items) do
    if only and it.mat ~= only then
      -- not this press
    elseif kept_back(it.mat) then
      kept = kept + it.n
    else
      total = total + it.value * mult
      local fu = math.min(it.n, fr[it.mat] or 0)
      if fu > 0 and it.n > 0 then
        freight = freight + it.value * mult * FREIGHT_RATE * fu / it.n
        fr[it.mat] = (fr[it.mat] or 0) - fu
      end
      if not sold[it.mat] then
        sold[it.mat] = true
        firsts[#firsts + 1] = mats.label(it.mat)
        -- The discovery premium: tier-scaled, paid once, ever.
        bonus = bonus + bonus_of(mats, it.mat)
        if mats.tier(it.mat) >= 2 then rare = rare + 1 end
      end
      inv.remove("base", it.mat, it.n)
    end
  end
  local keep = kept > 0 and string.format("%d unit%s kept for the contract", kept,
    kept == 1 and "" or "s") or nil
  if total <= 0 and bonus <= 0 then return keep or "nothing to sell" end
  save.set("depot.sold", sold)
  save.set("depot.freight", fr)
  freight = math.floor(freight)
  total = math.floor(total) + freight
  co.earn(total, only and ("sold " .. mats.label(only)) or "materials sold")
  if bonus > 0 then
    co.earn(bonus, "discovery premium")
    -- Standing for finding something rare, not for selling dirt.
    if rare > 0 then co.addRep(rare, "first sale of " .. table.concat(firsts, ", ")) end
    if rs and rs.noteDiscovery then rs.noteDiscovery() end
  end
  return string.format("sold for %s%s%s%s", co.money(total),
    freight > 0 and string.format("  (freight rate +%s)", co.money(freight)) or "",
    bonus > 0 and string.format("  ·  NEW DISCOVERY: %s (+%s)",
      table.concat(firsts, ", "), co.money(bonus)) or "",
    keep and ("  ·  " .. keep) or "")
end

-- Everything one press could sell, merged by material across the pad, the
-- pack and the warehouse: { mat, n, value, kept, first, bonus }, in the
-- registry's order.
local function depot_stock()
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  if not (inv and mats) then return {} end
  local ids = { "astro", "base" }
  local held = {}
  for _, h in ipairs(landedHolds()) do ids[#ids + 1] = h.id; held[h.id] = true end
  local by = {}
  for _, cid in ipairs(ids) do
    for _, it in ipairs(inv.items(cid)) do
      local e = by[it.mat] or { mat = it.mat, n = 0, value = 0, fvalue = 0 }
      e.n, e.value = e.n + it.n, e.value + it.value
      -- freight: what is still in a hold, plus what came off one earlier
      local fu = held[cid] and it.n or (cid == "base" and freight_units(it.mat, it.n) or 0)
      if it.n > 0 then e.fvalue = e.fvalue + it.value * fu / it.n end
      by[it.mat] = e
    end
  end
  local mult = price_mult(co)
  local out = {}
  for _, mat in ipairs(mats.list()) do
    local e = by[mat]
    if e then
      e.freight = math.floor(e.fvalue * mult * FREIGHT_RATE)
      e.value = math.floor(e.value * mult) + e.freight
      e.kept = kept_back(mat)
      e.first = first_sale(mat)
      e.bonus = e.first and bonus_of(mats, mat) or 0
      out[#out + 1] = e
    end
  end
  return out
end

-- Published for the harness (and any panel that wants the goods as data).
function depotStock() return depot_stock() end

-- What one press would do: the sale value of everything on the pad, in the
-- pack and in the warehouse (discovery premiums included), and how many units
-- stay behind for a contract.
local function depot_plan()
  local worth, kept, units = 0, 0, 0
  for _, e in ipairs(depot_stock()) do
    units = units + e.n
    if e.kept then kept = kept + e.n else worth = worth + e.value + e.bonus end
  end
  return worth, kept, units
end

-- WHAT THE BUTTON DOES, and what it pays. ONE press: the cargo comes off the
-- craft and out of the suit, and whatever isn't spoken for is sold.
--
-- It was two presses — "unload", then "sell" — and a player with a full pack
-- pressed once, read "12 units into the warehouse", and walked away with no
-- money and no idea there was a second step. The warehouse is still where
-- things go (a delivery contract counts it), it just isn't a stop you have to
-- make yourself. Each material also has its own row (see `depot_rows`), for
-- selling one thing and keeping the rest.
--
-- The label carries the MONEY because "Sell everything — $1,240" is a
-- decision, and there is always a label: "nothing to sell yet" is an answer.
function depotAction()
  local inv, co = ref("inventory"), ref("company")
  if not inv then return nil end
  local worth, kept, units = depot_plan()
  if units == 0 then return "Nothing to sell yet" end
  local money = (co and co.money(worth)) or ("$" .. worth)
  if worth > 0 then
    return string.format("%s — %s", kept > 0 and "Sell the rest" or "Sell everything", money)
  end
  return "Store it for the contract"
end

-- One press on a material's row: unload, then sell just that.
function depotSellOne(mat)
  depotUnload()
  depot_msg = depotSell(mat)
  depot_msg_t = time
  sfx("click")
end

-- THE PER-MATERIAL ROWS. Described into the panel (ui.make leaves the authored
-- title, body and buttons alone) while the depot is open, and emptied for every
-- other building. A row is a button: what it is, how many, what it fetches,
-- and NEW with the premium when its first sale is still to come.
local rows_shown = nil
local function depot_rows(show)
  local panel = find("Facility Panel")
  if not (panel and ui and ui.make) then return end
  if not show then
    if rows_shown ~= false then ui.make(panel, {}) end
    rows_shown = false
    return
  end
  rows_shown = true
  local co, mats = ref("company"), ref("materials")
  local stock = depot_stock()
  local function money(v) return (co and co.money(v)) or ("$" .. v) end
  local items = {}
  for _, e in ipairs(stock) do items[#items + 1] = e end
  -- The BUY counter (gear: relay beacons) is the suit pack's panel at the
  -- depot (inventory_panel's counters): gear is bought here and nowhere else.
  local function counters(which)
    close()
    local ip = ref("inventory_panel")
    if ip and ip.openCounters then ip.openCounters(which) end
  end
  ui.make(panel, {
    { "row", key = "depotCounters", w = "100%", h = "fit", gap = 6, pad = 0, order = 1,
      { "button", key = "buyCounter", style = "panel/secondary", w = "grow", h = 30,
        textAlign = "center", textValign = "center", text = "Buy counter  ·  gear",
        tooltip = "Relay beacons and other gear, into the pack and onto the tool belt.",
        onClicked = function() counters("buy") end },
      { "button", key = "sellCounter", style = "panel/secondary", w = "grow", h = 30,
        textAlign = "center", textValign = "center", text = "Sell counter  ·  materials",
        onClicked = function() counters("sell") end } },
    { "col", key = "depotRows", w = "100%", h = "fit", gap = 3, pad = 0, order = 2,
      items = items, function(e)
        local label = string.format("%d × %s", e.n, (mats and mats.label(e.mat)) or e.mat)
        local tail
        if e.kept then
          tail = "for the contract"
        elseif e.first then
          tail = string.format("NEW · first sale +%s", money(e.bonus))
        else
          tail = ""
        end
        return {
          "button", key = "sell_" .. e.mat, style = "panel/row", w = "100%", h = 28,
          dir = "row", gap = 8, align = "center", disabled = e.kept or nil,
          opacity = e.kept and 0.55 or nil,
          tooltip = e.kept and "Kept back — the contract on the books needs it in the warehouse."
            or (e.first and "Never sold before: the first sale pays a discovery premium." or nil),
          { "text", key = "what", style = "panel/cell", w = "grow", h = "fit", text = label },
          { "text", key = "first", style = e.first and "panel/cellStrong" or "panel/cellMuted",
            w = "fit", h = "fit", text = tail },
          { "text", key = "pay", style = "panel/cellStrong", w = 70, h = "fit", textAlign = "end",
            text = e.kept and "" or money(e.value) },
          { "text", key = "go", style = "panel/cellMuted", w = 34, h = "fit", textAlign = "end",
            text = e.kept and "" or "sell" },
          onClicked = function() if not e.kept then depotSellOne(e.mat) end end,
        }
      end },
  })
end

-- The depot body: what's on the pad and in the pack, the warehouse's weight,
-- and what the prices are worth to you today. The goods themselves are the
-- rows under it.
local function depot_body()
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  if not (inv and co and mats) then return "Depot systems offline." end
  local lines = {}
  local holds = landedHolds()
  if #holds > 0 then
    local parts = {}
    for _, h in ipairs(holds) do parts[#parts + 1] = string.format("%s %.0f kg", h.name, h.kg) end
    lines[#lines + 1] = "ON THE PAD — " .. table.concat(parts, "  ·  ")
  end
  local pack = inv.mass("astro")
  if pack > 0.05 then
    lines[#lines + 1] = string.format("SUIT PACK — %s", inv.line("astro"))
  end
  lines[#lines + 1] = string.format("WAREHOUSE — %.1f kg", inv.mass("base"))
  local worth, kept, units = depot_plan()
  if units == 0 then
    lines[#lines + 1] = "Empty. Mine rock with the laser, cut flora with the harvester, or bring it in by rover: goods off a craft's hold sell at the freight rate (+" .. math.floor(FREIGHT_RATE * 100 + 0.5) .. "%)."
  else
    local any_first = false
    for _, e in ipairs(depot_stock()) do if e.first and not e.kept then any_first = true end end
    local pct = math.floor((price_mult(co) - 1.0) * 100 + 0.5)
    lines[#lines + 1] = string.format("Worth %s   ·   reputation %+d%% on prices", co.money(worth), pct)
    local fr = 0
    for _, e in ipairs(depot_stock()) do if not e.kept then fr = fr + (e.freight or 0) end end
    if fr > 0 then
      lines[#lines + 1] = string.format("Freight rate: +%d%% on goods off a craft's hold (+%s here)",
        math.floor(FREIGHT_RATE * 100 + 0.5), co.money(fr))
    end
    if any_first then
      lines[#lines + 1] = "NEW — never sold before: its first sale pays a discovery premium."
    end
    if kept > 0 then
      lines[#lines + 1] = string.format("%d unit%s kept back — your contract needs %s in the warehouse.",
        kept, kept == 1 and "" or "s", kept == 1 and "it" or "them")
    end
    lines[#lines + 1] = "Click a row to sell one material; the button sells it all."
  end
  if depot_msg ~= "" and time - depot_msg_t < 8.0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "» " .. depot_msg
  end
  return table.concat(lines, "\n")
end

-- What one facility's panel says. Split out from the writing below so that the
-- two can be made ATOMIC — see `refresh`.
local function panel_content(f)
  local body, act = "", nil
  depot_rows(f.kind == "depot")
  if f.kind == "tracking" then
    body, act = tracking_body()
  elseif f.kind == "hangar" then
    body = "Assemble and launch a new vessel from your saved parts."
    act = "Open the builder  ▸"
  elseif f.kind == "command" then
    local astro = find("Astronaut")
    local where = astro and space.dominant(astro.x, astro.y, astro.z) or "?"
    local ships = save.get("comms.ships")
    local n = 0
    if type(ships) == "table" then for _ in pairs(ships) do n = n + 1 end end
    -- The company's state, in the building the company is run from.
    local co = ref("company")
    local mi = ref("missions")
    local lines = { string.format("Base world %s   ·   %d vessel%s tracked", where or "?",
                                  n, n == 1 and "" or "s") }
    if co and co.money then
      lines[#lines + 1] = string.format("Balance %s   ·   reputation %+d",
        co.money(co.balance()), co.rep())
      local owe = co.owed and co.owed() or 0
      if owe > 0 then
        lines[#lines + 1] = string.format("Mission Control advance — %s still owed, repaid from a quarter of income",
          co.money(owe))
      end
    end
    if mi then
      lines[#lines + 1] = ""
      lines[#lines + 1] = mi.active
        and ("CONTRACT — " .. (mi.activeLine() or ""))
        or  ("CONTRACT — none. Sign one at the Ops Board.")
      if mi.active then
        for _, l in ipairs(mi.goalLines()) do lines[#lines + 1] = "   " .. l end
      end
    end
    if co and co.ledgerLines then
      local led = co.ledgerLines(4)
      if #led > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "RECENT"
        for _, l in ipairs(led) do lines[#lines + 1] = "   " .. l end
      end
    end
    body = table.concat(lines, "\n")
    act = "Ops Board  ▸"
  elseif f.kind == "depot" then
    body = depot_body()
    act = depotAction()
  end
  return body, act
end

local content_warned = nil

-- Paint the open facility's panel. ONE panel serves all five buildings, so the
-- only thing keeping them apart is that all three of its text nodes are rewritten
-- together, from the same building, every time.
--
-- ⚠ THEY USED TO NOT BE. The title was written FIRST, then the body was computed,
-- then the body and action were written LAST — so anything that raised in
-- between left the panel showing the NEW building's name above the OLD
-- building's contents. Every line of the content above reaches across into
-- another script (`co.balance()`, `mi.goalLines()`, the depot's inventory walk),
-- which is exactly the code most likely to raise mid-reload, and it fails
-- silently because a Lua error in `update` kills the frame's remaining work
-- rather than the panel. Reported as *"the facilities uis were often mixed up"*.
--
-- Now: compute everything, and only then write. If the content raises, the panel
-- keeps the last building it successfully painted — WHOLE, not half — and says
-- what happened once rather than every frame.
local function refresh()
  if not open_fac then return end
  local f = FAC[open_fac]
  local got, body, act = pcall(panel_content, f)
  if not got then
    if content_warned ~= open_fac then
      content_warned = open_fac
      diag(string.format("%s panel could not be built: %s", f.label, tostring(body)))
    end
    -- Say so IN the panel, WITH THE REASON. A building that shows another
    -- building's numbers is worse than one that admits it has none — but "not
    -- responding" on its own sends the player to the Console to find out what
    -- happened, and the whole point of this path is that something went wrong
    -- where nobody was looking. Put the message where they already are.
    --
    -- The file:line prefix is stripped: it names a line in a script the player
    -- did not write, and the message after it is the part that identifies the
    -- fault. (Kept in the Console line above, which is for whoever debugs it.)
    local short = tostring(body):gsub("^.-:%d+:%s*", "")
    body = "This console is not responding.\n\n"
      .. short .. "\n\nStep out and back in to retry."
    act = nil
  elseif content_warned == open_fac then
    content_warned = nil
  end
  if title_n then title_n.text = f.label end
  crew_button(f.kind == "command")
  if body_n then body_n.text = body end
  -- ALWAYS write the label. It used to be written only when there WAS an
  -- action, on the reasoning that the button would be hidden otherwise — which
  -- leaves the scene's authored placeholder, the literal word "Action", sitting
  -- on screen for every path that doesn't set one. Ty: "i opened the commerce
  -- depot and it just showed 'action'." A label that can go stale is a label
  -- that will.
  if action_n then action_n.text = act or "" end
  if action_el then action_el.visible = act ~= nil end
end

-- THE DIM BEHIND A PANEL. One scrim for every panel you stop to read — this
-- one, the Ops Board, the pause menu. It cannot be a panel's own child (a child
-- draws over its parent's fill, and inside a stacked panel it takes part in the
-- flow), so it is described into the HUD layer itself, ordered behind
-- everything else there: the world goes quiet, the panel and the HUD stay crisp.
-- One owner, because two scripts describing into one container would each
-- delete what the other made.
local scrim_on = nil
local function scrim(on)
  if scrim_on == on or not (ui and ui.make) then return end
  local layer = find("Ship HUD")
  if not layer then return end
  scrim_on = on
  ui.make(layer, on and { { "box", key = "panelScrim", style = "panel/scrim", pin = "center",
                            w = 4000, h = 2400, order = -100 } } or {})
end

function sync_scrim()
  local pm, ob = ref("pause_menu"), ref("ops_board")
  scrim(open_fac ~= nil or (pm ~= nil and pm.open == true)
    or (ob ~= nil and ob.isOpen ~= nil and ob.isOpen() == true) or roster_open())
end

-- The overview's CREW button, beside its action: described into the scene's
-- button row (hand-placed buttons there are left alone by ui.make), only for
-- the Command Centre. The action button narrows to make room.
local crew_btn_on = nil
function crew_button(on)
  if crew_btn_on == on or not (ui and ui.make) then return end
  local row = find("Facility Buttons")
  if not row then return end
  crew_btn_on = on
  if action_el then action_el.width = on and 176 or 300 end
  ui.make(row, on and { { "button", key = "crew", style = "panel/action", w = 116, h = 36, text = "Crew  ▸",
    textAlign = "center", textValign = "center", tooltip = "The Astronaut Complex: roster, hiring, memorial",
    onClicked = function() sfx("click"); openRoster("ROSTER") end } } or {})
end

-- The Tracking Station has a screen of its own (scripts/tracking_station.lua):
-- the whole fleet with its power, signal and control, and the actions on it.
-- This menu still owns "a facility is open" (E/Esc, walking away, the scrim);
-- the station only draws.
local function station()
  local ts = ref("tracking_station")
  return (ts and ts.open and ts.close) and ts or nil
end

-- Called by the panel's ✕ button and by pressing E/Esc while open.
function close()
  if open_fac then sfx("close") end
  if open_fac and FAC[open_fac].kind == "tracking" then
    local ts = station()
    if ts then ts.close() end
  end
  open_fac = nil
  if panel_el then panel_el.visible = false end
  sync_scrim()
end

function openMenu(name)
  if not FAC[name] then return end
  open_fac = name
  sfx("open")
  if prompt_el then prompt_el.visible = false end
  local ts = FAC[name].kind == "tracking" and station() or nil
  if ts then
    if panel_el then panel_el.visible = false end
    ts.open()
    scrim(true)
    return
  end
  if panel_el then panel_el.visible = true end
  scrim(true)
  refresh()
end

-- A quarter-second to black before the scene changes, instead of the world
-- vanishing mid-frame. The loading screen's backdrop is the black: it is
-- already a full-screen panel, and the next scene opens behind its own.
local fading = false
local function fade_to(scene_name)
  if fading then return end
  local n = find("Loading Screen")
  local el = n and n:getcomponent("UiElement")
  if not (el and tween) then scene.load(scene_name) return end
  fading = true
  close()
  el.opacity, el.visible = 0.0, true
  tween(0.25, function(a)
    el.opacity = a
    if a >= 1.0 then scene.load(scene_name) end
  end, "smooth")
end

-- THE VAB. The builder opens IN the building, over the live world
-- (scripts/build_host.lua): no scene load, the real sky through the doors.
-- Without a build host (an old scene) it is the separate builder scene.
local function open_builder()
  local bh = ref("build_host")
  if bh and bh.enter and bh.enter() then close() return end
  fade_to("builder")
end

-- The action button routes by the open facility's kind.
function action()
  if not open_fac then return end
  local kind = FAC[open_fac].kind
  sfx("click")
  if kind == "hangar" then
    open_builder()
  elseif kind == "command" then
    -- The Command Centre opens the OPS BOARD. Leaving for the main menu moved
    -- to the HUD's ☰ button, which is where every other "quit" already lives —
    -- a facility panel shouldn't be the only route out of the world.
    local ob = ref("ops_board")
    close()
    if ob and ob.openBoard then ob.openBoard() end
  elseif kind == "tracking" then
    -- Flying it now: the cockpit takes the screen.
    if trackingAction() then close() else refresh() end
  elseif kind == "depot" then
    depotUnload()
    depot_msg = depotSell()
    depot_msg_t = time
    refresh()
  else
    close()
  end
end

-- Past a facility's prompt reach, with a few metres' grace so a step back
-- from the counter doesn't slam the panel shut. A building that is gone counts
-- as left.
local LEAVE_SLACK = 4.0
local function beyond(astro, name)
  local f = find(name)
  if not (f and astro) then return true end
  return apart(astro, f) > (FAC[name].near or params.radius) + LEAVE_SLACK
end

function update(node, dt)
  -- The VAB builder has the keys and the screen: no prompts, no panels.
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then
    near_fac = nil
    if prompt_el then prompt_el.visible = false end
    if open_fac then close() end
    if roster_open() then ref("crew_roster_panel").close(); sync_scrim() end
    return
  end
  sync_scrim()
  if not panel_el then grab() end
  if not panel_el then
    diag("no \"Facility Panel\" node in this scene — nothing can open")
    return
  end

  local astro = find("Astronaut")
  -- Only the on-foot astronaut interacts. While piloting / loading there is
  -- nobody standing here — no prompts, and any open panel closes.
  local afoot = crew_afoot()
  if not astro then
    diag("no Astronaut in the scene")
  elseif not afoot then
    diag("the crew is aboard a vessel (or the world is loading) — prompts are off")
  end
  if not afoot then
    near_fac = nil
    if prompt_el then prompt_el.visible = false end
    if open_fac then close() end
    return
  end
  -- The pause menu and the orbit map own the screen while they are up: a
  -- prompt drawn over them is one you cannot act on.
  -- So does an open right-click menu: the prompt sits where the menu opens
  -- beside the crew, and its text was drawn over the menu's rows.
  local pm, om, cmn = ref("pause_menu"), ref("orbit_map"), ref("context_menu")
  if (pm and pm.open) or (om and om.isOpen and om.isOpen()) or (cmn and cmn.isOpen and cmn.isOpen()) then
    if prompt_el then prompt_el.visible = false end
    return
  end

  -- Nearest facility within ITS reach, in world space.
  near_fac = nil
  local standing, nearest_d, nearest_n, best_in = 0, nil, nil, nil
  for _, name in ipairs(ORDER) do
    local f = find(name)
    if f then
      standing = standing + 1
      local dist = apart(astro, f)
      if not nearest_d or dist < nearest_d then nearest_d, nearest_n = dist, name end
      if dist < (FAC[name].near or params.radius) and (not best_in or dist < best_in) then
        best_in, near_fac = dist, name
      end
    end
  end
  -- Report the SHAPE of the situation, not every metre walked: the building
  -- count and which one you're at. Walking around the base doesn't spam it.
  if standing == 0 then
    diag("none standing yet — base_facilities hasn't sited them")
  elseif near_fac then
    diag(string.format("%d standing · at %s", standing, FAC[near_fac].label))
  else
    -- No distance in it: the line is only logged when it CHANGES, and a
    -- distance changes every metre you walk (a log line a step, 0.116).
    diag(string.format("%d standing · nearest %s", standing,
      nearest_n and FAC[nearest_n].label or "?"))
  end

  if open_fac then
    if prompt_el then prompt_el.visible = false end
    -- Walk away and it closes: a counter you have left is not one you are
    -- standing at, and a panel that followed you round the planet hid the
    -- world and kept the belt's keys for as long as you forgot it was up.
    if beyond(astro, open_fac) then close() return end
    local ts = FAC[open_fac].kind == "tracking" and station() or nil
    if FAC[open_fac].kind == "tracking" and not ts then
      if input.pressed("up") then track_sel = math.max(1, track_sel - 1) end
      if input.pressed("down") then track_sel = track_sel + 1 end
    end
    if not ts then refresh() end -- keep telemetry live while the panel is up
    if input.pressed("escape") then
      escTakenAt = time
      close()
    elseif interact_pressed() and not (ts and ts.typing and ts.typing()) then
      close()
    end
    return
  end

  -- The Astronaut Complex: the Command Centre's other console. E (unless a
  -- name is being typed) or Esc closes it; so does walking out.
  if roster_open() then
    local rp = ref("crew_roster_panel")
    if prompt_el then prompt_el.visible = false end
    if input.pressed("escape") then
      escTakenAt = time
      rp.close()
    elseif (interact_pressed() and not (rp.typing and rp.typing())) or beyond(astro, "FacCommand") then
      rp.close()
    end
    if not roster_open() then sync_scrim() end
    return
  end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then
    if prompt_el then prompt_el.visible = false end
    -- The board is the Command Centre's console: it stays in the building.
    if interact_pressed() or beyond(astro, "FacCommand") then ob.closeBoard() end
    return
  end
  if near_fac then
    local f = FAC[near_fac]
    local say = f.label
    if f.inside then
      say = (best_in < f.inside) and f.use or ("Enter the " .. f.label)
    end
    -- E goes straight to the screen you came for: the Ops Board at the
    -- Command Centre, the builder at the Vehicle Assembly. Both used to open
    -- an overview panel first whose only real content was a button to the
    -- screen you wanted. (The Command Centre's overview is one click from the
    -- board's own "Overview" button.)
    if f.direct and say == ("Enter the " .. f.label) then say = say .. " — " .. f.direct end
    say = say .. "   ·   E"
    show_prompt(say)
    if prompt_el then prompt_el.visible = true end
    if interact_pressed() then
      if f.kind == "command" and ob and ob.openBoard then
        if prompt_el then prompt_el.visible = false end
        ob.openBoard()
      elseif f.kind == "hangar" then
        sfx("open")
        if prompt_el then prompt_el.visible = false end
        open_builder()
      else
        openMenu(near_fac)
      end
    end
  elseif prompt_el then
    prompt_el.visible = false
  end
end
