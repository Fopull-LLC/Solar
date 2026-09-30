-- FACILITIES MENU — walk the astronaut up to a base building and an
-- "⏎ Enter … [E]" prompt appears; press E (or click it) to open that facility's
-- panel. Press E or Esc (or the ✕ button) to leave.
--
--   Command Centre    → the company: balance, standing, the contract on the
--                       books — and the OPS BOARD, where contracts are signed.
--   Vehicle Assembly  → jump to the ship builder.
--   Tracking Station  → lists every launched vessel still holding a comms link
--                       (the `comms.ships` registry vessel_controller's power_tick
--                       writes — name / altitude / battery).
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
  -- near = prompt reach in metres, from the ORIGIN — so it has to clear the
  -- building's own half-diagonal before it clears any ground. At the current
  -- scales the command centre is 12 × 18 m on the ground (half-diagonal 10.8),
  -- the assembly frame 10 × 10, the depot 8 × 8; the plant and the dish are
  -- machines you stand beside.
  --
  -- inside = the building's own half-width: closer than this you are standing
  -- IN it, and "Enter the Command Centre" is an odd thing to be told there.
  -- `use` is what the prompt says instead. The dish is a machine — you stand
  -- beside it, so it only ever names itself.
  FacCommand  = { label = "Command Centre",   kind = "command",  near = 20.0,
                  inside = 6.5, use = "Use the Ops console" },
  FacHangar   = { label = "Vehicle Assembly", kind = "hangar",   near = 17.0,
                  inside = 5.0, use = "Open the builder" },
  FacTracking = { label = "Tracking Station", kind = "tracking", near = 13.0 },
  FacDepot    = { label = "Commerce Depot",   kind = "depot",    near = 15.0,
                  inside = 4.0, use = "Use the depot counter" },
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
  if math.abs(m) >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

-- The Tracking Station body: read the shared comms.ships registry live.
local function tracking_body()
  local ships = save.get("comms.ships")
  local list = {}
  if type(ships) == "table" then
    for _, s in pairs(ships) do if type(s) == "table" then list[#list + 1] = s end end
  end
  if #list == 0 then
    return "No vessels are transmitting.\n\nLaunch a craft carrying a comms dish and keep it powered — it will appear here with live telemetry."
  end
  -- Stable order (UX: rows never jump around between refreshes).
  table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
  local lines = { string.format("%d vessel(s) transmitting", #list), "" }
  for _, s in ipairs(list) do
    local pct = 0
    if (s.cap or 0) > 0 then pct = math.floor((s.charge or 0) / s.cap * 100 + 0.5) end
    lines[#lines + 1] = string.format("•  %s   ·   %s   ·   bat %d%%", (s.name or "Vessel"), fmt_alt(s.alt), pct)
  end
  return table.concat(lines, "\n")
end

-- Is a facility panel up? The tool belt asks, so holding E at the depot digs a
-- hole in the floor instead of… well, exactly that.
function isOpen()
  return open_fac ~= nil
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

-- Sell: the warehouse, at the registry's prices, nudged by standing — except
-- what the contract on the books is waiting for. A first sale of a material is
-- a DISCOVERY — the moment the science half of the game starts paying, and the
-- one time a single crate is worth real money.
function depotSell()
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  local rs = ref("research")
  if not (inv and co and mats) then return "no depot systems" end
  local items = inv.items("base")
  if #items == 0 then return "the warehouse is empty" end
  local mult = 1.0 + 0.04 * co.rep()
  local total, bonus, firsts, kept = 0, 0, {}, 0
  local sold = save.get("depot.sold") or {}
  for _, it in ipairs(items) do
    if kept_back(it.mat) then
      kept = kept + it.n
    else
      total = total + it.value * mult
      if not sold[it.mat] then
        sold[it.mat] = true
        firsts[#firsts + 1] = mats.label(it.mat)
        -- The discovery premium: tier-scaled, paid once, ever.
        bonus = bonus + 150 * (1 + mats.tier(it.mat))
      end
      inv.remove("base", it.mat, it.n)
    end
  end
  local keep = kept > 0 and string.format("%d unit%s kept for the contract", kept,
    kept == 1 and "" or "s") or nil
  if total <= 0 and bonus <= 0 then return keep or "nothing to sell" end
  save.set("depot.sold", sold)
  total = math.floor(total)
  co.earn(total, "materials sold")
  if bonus > 0 then
    co.earn(bonus, "discovery premium")
    co.addRep(1, "first sale of " .. table.concat(firsts, ", "))
    if rs and rs.noteDiscovery then rs.noteDiscovery() end
  end
  return string.format("sold for %s%s%s", co.money(total),
    bonus > 0 and string.format("  ·  NEW DISCOVERY: %s (+%s)",
      table.concat(firsts, ", "), co.money(bonus)) or "",
    keep and ("  ·  " .. keep) or "")
end

-- What one press would do: the sale value of everything on the pad, in the
-- pack and in the warehouse, and how many units stay behind for a contract.
local function depot_plan()
  local inv, co = ref("inventory"), ref("company")
  local ids = { "astro", "base" }
  for _, h in ipairs(landedHolds()) do ids[#ids + 1] = h.id end
  local worth, kept, units = 0, 0, 0
  for _, cid in ipairs(ids) do
    for _, it in ipairs(inv.items(cid)) do
      units = units + it.n
      if kept_back(it.mat) then kept = kept + it.n else worth = worth + it.value end
    end
  end
  local mult = 1.0 + 0.04 * ((co and co.rep()) or 0)
  return math.floor(worth * mult), kept, units
end

-- WHAT THE BUTTON DOES, and what it pays. ONE press: the cargo comes off the
-- craft and out of the suit, and whatever isn't spoken for is sold.
--
-- It was two presses — "unload", then "sell" — and a player with a full pack
-- pressed once, read "12 units into the warehouse", and walked away with no
-- money and no idea there was a second step. The warehouse is still where
-- things go (a delivery contract counts it), it just isn't a stop you have to
-- make yourself.
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
    return string.format("%s — %s  ▸", kept > 0 and "Sell the rest" or "Sell everything", money)
  end
  return "Store it for the contract  ▸"
end

-- The depot body: what's in the warehouse, what it's worth, and what's still
-- sitting in a hold out on the pad.
local function depot_body()
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  if not (inv and co and mats) then return "Depot systems offline." end
  local lines = {}
  local holds = landedHolds()
  if #holds > 0 then
    lines[#lines + 1] = "ON THE PAD"
    for _, h in ipairs(holds) do
      lines[#lines + 1] = string.format("•  %s   ·   %.1f kg", h.name, h.kg)
    end
    lines[#lines + 1] = ""
  end
  local pack = inv.mass("astro")
  if pack > 0.05 then
    lines[#lines + 1] = string.format("IN YOUR SUIT PACK — %s", inv.line("astro"))
    for _, it in ipairs(inv.items("astro")) do
      lines[#lines + 1] = string.format("•  %d × %s   ·   %s", it.n, mats.label(it.mat),
        co.money(it.value))
    end
    lines[#lines + 1] = ""
  end
  local items = inv.items("base")
  lines[#lines + 1] = string.format("WAREHOUSE — %.1f kg", inv.mass("base"))
  if #items == 0 then
    lines[#lines + 1] = "Empty. Mine rock with the laser, cut flora with the harvester, or fly it home in a Cargo Bay."
  else
    for _, it in ipairs(items) do
      lines[#lines + 1] = string.format("•  %d × %s   ·   %s%s", it.n, mats.label(it.mat),
        co.money(it.value), kept_back(it.mat) and "   (for the contract)" or "")
    end
  end
  local worth, kept, units = depot_plan()
  if units > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Sale value %s   ·   standing %+d%%",
      co.money(worth), math.floor(co.rep() * 4))
    if kept > 0 then
      lines[#lines + 1] = string.format("%d unit%s kept back — your contract needs %s in the warehouse.",
        kept, kept == 1 and "" or "s", kept == 1 and "it" or "them")
    end
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
  if f.kind == "tracking" then
    body = tracking_body()
  elseif f.kind == "hangar" then
    body = "Assemble and launch a new vessel from your saved parts."
    act = "Open Builder  ▸"
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

-- Called by the panel's ✕ button and by pressing E/Esc while open.
function close()
  if open_fac then sfx("close") end
  open_fac = nil
  if panel_el then panel_el.visible = false end
end

function openMenu(name)
  if not FAC[name] then return end
  open_fac = name
  sfx("open")
  if prompt_el then prompt_el.visible = false end
  if panel_el then panel_el.visible = true end
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

-- The action button routes by the open facility's kind.
function action()
  if not open_fac then return end
  local kind = FAC[open_fac].kind
  sfx("click")
  if kind == "hangar" then
    fade_to("builder")
  elseif kind == "command" then
    -- The Command Centre opens the OPS BOARD. Leaving for the main menu moved
    -- to the HUD's ☰ button, which is where every other "quit" already lives —
    -- a facility panel shouldn't be the only route out of the world.
    local ob = ref("ops_board")
    close()
    if ob and ob.openBoard then ob.openBoard() end
  elseif kind == "depot" then
    depotUnload()
    depot_msg = depotSell()
    depot_msg_t = time
    refresh()
  else
    close()
  end
end

function update(node, dt)
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
  local pm, om = ref("pause_menu"), ref("orbit_map")
  if (pm and pm.open) or (om and om.isOpen and om.isOpen()) then
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
    diag(string.format("%d standing · nearest %s, %.0f m away", standing,
      nearest_n and FAC[nearest_n].label or "?", nearest_d or 0))
  end

  if open_fac then
    if prompt_el then prompt_el.visible = false end
    refresh() -- keep telemetry live while the panel is up
    if input.pressed("escape") then
      escTakenAt = time
      close()
    elseif interact_pressed() then
      close()
    end
    return
  end

  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then
    if prompt_el then prompt_el.visible = false end
    if interact_pressed() then ob.closeBoard() end
    return
  end
  if near_fac then
    local f = FAC[near_fac]
    local say = f.label
    if f.inside then
      say = (best_in < f.inside) and f.use or ("Enter the " .. f.label)
    end
    say = say .. "   ·   E"
    show_prompt(say)
    if prompt_el then prompt_el.visible = true end
    if interact_pressed() then openMenu(near_fac) end
  elseif prompt_el then
    prompt_el.visible = false
  end
end
