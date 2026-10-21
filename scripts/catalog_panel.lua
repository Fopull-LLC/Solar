-- THE CATALOGUE — every part you can bolt onto a craft, and what it costs.
--
-- Clicking a card hands its id to the builder (`pick`), which spawns the ghost
-- on your cursor. A card for a part R&D hasn't opened yet is dimmed and priced
-- at its unlock cost, and clicking it BUYS the unlock rather than doing nothing
-- — the catalogue is the research screen, which is why a locked card is meant
-- to look available-but-not-yet rather than disabled.
--
-- THE SCREEN IS DESCRIBED, NOT AUTHORED. This was nineteen button nodes in
-- `builder.ron`, each carrying a `catalog_button` script, each holding a NUMBER
-- that indexed a parallel id array inside that script. Three places had to
-- agree for a card to say the right thing, and when they didn't the failure was
-- a card quietly labelled as the wrong part. The builder's registry is the only
-- source now (`builder.catalogue()`), and adding a part is one line there.
--
-- The sections are the other thing the flat list couldn't do: nineteen
-- identical cards in a column is a wall, and you build in an order — capsule,
-- engine, tank, gear — that the panel may as well show you.
--
--   ↑ ↓ Enter  the cards are focusable, so the catalogue works without a mouse

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

-- What a part is FOR, in a few words under its name. A card that said only
-- "Sputter  $150" asked a new player to already know what a Sputter is; the
-- numbers are the registry's own, so a card can't quote a stat the part lacks.
local function role(def)
  -- A part that says what it is for in its own words (builder REG `desc`).
  if def.desc then return def.desc end
  -- ve (exhaust velocity) is what Δv is made of: Δv = ve · ln(full / empty).
  if def.thrust then
    return def.ve and string.format("engine · %.0f kN · ve %.0f m/s · %.2f t", def.thrust, def.ve, def.mass)
      or string.format("engine · %.0f kN · %.2f t", def.thrust, def.mass)
  end
  -- Full and empty: the propellant is most of a tank's mass.
  if def.fuel then
    local ft = def.fuel_t or 0.01
    return string.format("fuel tank · %d fuel · %.2f t full, %.2f empty",
      def.fuel, def.mass + def.fuel * ft, def.mass)
  end
  if def.kind == "crewed" then return "crew pod — flies anywhere, with you in it" end
  if def.kind == "probe" then return "probe core — flies with power + a link home" end
  -- Electronics read from the part's modules (scripts/electronics.lua).
  for _, m in ipairs(def.mods or {}) do
    if m.type == "antenna" and (m.power or 0) >= 1000 then
      -- How far it reaches the ground station (two antennas reach sqrt(P1·P2)).
      local E = ref("electronics")
      local home = math.sqrt(m.power * ((E and E.COMMS and E.COMMS.station) or 4e5))
      local reach = home >= 1e6 and string.format("%.1f Mm", home / 1e6) or string.format("%.0f km", home / 1000)
      return string.format("%s · home %s%s · −%.2f/s", m.dish and "dish" or "omni", reach,
        m.relay and " · relay" or "", m.draw or 0)
    end
    if m.type == "light" then return string.format("floodlight · −%.2f power/s while lit", m.draw or 0) end
  end
  if def.chute then return "parachute — slows the landing" end
  if def.cargo then return string.format("cargo hold · carries %d kg", def.cargo) end
  if def.legs then return string.format("landing legs · %.0f kg — stand up on arrival", def.mass * 1000) end
  if def.solar then return string.format("solar panel · +%.1f power/s in sunlight", def.gen or 0) end
  if def.power then return string.format("battery · stores %d power", def.ec or 0) end
  if def.comms then return "comms dish — tracked from the base" end
  if def.dock then return "docking port — join two craft in flight" end
  if def.rcs then return "RCS — fine attitude for docking" end
  if def.decouple then return def.radial and "radial decoupler — drops side boosters"
                                         or "decoupler — separates a stage" end
  if def.aero then return "aero — less drag, steadier flight" end
  return string.format("%.1f t", def.mass)
end

local function describe()
  local b, rs, co = ref("builder"), ref("research"), ref("company")
  if not (b and b.catalogue and b.partInfo) then return nil end

  local function money(v)
    return (co and co.money) and co.money(v) or ("$" .. tostring(v or 0))
  end

  local rows = {
    { "text", key = "title", style = "panel/title", w = "100%", h = 18,
      text = "PARTS CATALOGUE", tracking = 2.0 },
  }

  for _, section in ipairs(b.catalogue()) do
    rows[#rows + 1] = { "text", key = "h" .. section.title, style = "panel/label",
      w = "100%", h = 26, textValign = "end", text = section.title }
    -- Cards go straight into the catalogue column rather than into a box
    -- per section: the nested column added its own inset and spacing, and
    -- at 720 the list overflowed the screen by a card and a half.
    for _, id in ipairs(section.ids) do
      local def = b.partInfo(id)
      -- The thrust and ve a card quotes are the ones this save's catalogue is
      -- built with (builder.liveDef) — exactly what the part flies with.
      def = def and b.liveDef and b.liveDef(id) or def
      if def then   -- an id with no registry entry is skipped, not drawn broken
        local locked = (rs and not rs.isUnlocked(id)) or false
        local price = locked and ((rs and rs.costOf(id)) or 0) or def.cost
        -- What stands in the way, ON the card: the Skipper used to show $1,250
        -- and nothing else, though it can't be bought before the Anvil.
        local needs = locked and rs and rs.blockedBy and rs.blockedBy(id) or nil
        local armed = locked and b.researchPending and b.researchPending(id) or false
        local price_text = locked and ("unlock " .. money(price)) or money(price)
        if armed then price_text = "confirm " .. money(price) .. "?" end
        local role_text = role(def)
        if needs then role_text = "locked · " .. needs end
        -- Name left, price right: two runs in a row (a single string padded
        -- with `%-18s` only lined prices up in a monospace font). What the
        -- part is for goes under both, full width, so it never runs into the
        -- price.
        rows[#rows + 1] = {
          "button", key = id, style = "panel/row", w = "100%", h = 41,
          dir = "col", align = "stretch", gap = 2,
          -- Locked cards read as unavailable-but-live: dimmer and cooler,
          -- never invisible — you're supposed to want them.
          opacity = locked and 0.7 or 1.0,
          -- Colours are styles ("cat/*", ui/solar.uistyle.ron): the name
          -- printed in ink, the price in the mono face — orange for an
          -- unlock, red for one waiting on a second click.
          { "row", key = "top", w = "100%", h = 16, gap = 6, pad = 0, align = "center",
            { "text", key = "n", style = locked and "cat/nameLocked" or "cat/name",
              w = "grow", h = 16, text = def.label, textAlign = "start", maxLines = 1, overflow = "ellipsis" },
            { "text", key = "p", style = armed and "cat/priceArmed" or (locked and "cat/priceLocked" or "cat/price"),
              w = "fit", h = 16, text = price_text, textAlign = "end" } },
          { "text", key = "r", style = needs and "cat/roleNeeds" or "cat/role",
            w = "100%", h = 14, text = role_text, textAlign = "start", maxLines = 1, overflow = "ellipsis" },
          onClicked = function() if b.pick then b.pick(id) end end,
          -- What a locked part needs, on the builder's own hint bar — the one
          -- place every other explanation in this scene appears. Focus says it
          -- too, so a pad gets the same reading a mouse does.
          onHoverStart = function()
            if locked and rs and b.hintNow then
              b.hintNow(rs.labelOf(id) .. "  —  " .. (rs.lockLine(id) or ""), 4.0)
            end
          end,
          onFocusEnter = function()
            if locked and rs and b.hintNow then
              b.hintNow(rs.labelOf(id) .. "  —  " .. (rs.lockLine(id) or ""), 4.0)
            end
          end,
        }
      end
    end
  end

  -- No frame style here on purpose: the catalogue is a SCROLL viewport, and a
  -- background described INSIDE it would scroll away with the cards. The
  -- container node keeps the chrome; this is only what moves.
  return { "col", key = "catalogue", w = "100%",
           dir = "col", gap = 3, pad = 12, align = "stretch",
           items = rows, function(row) return row end }
end

-- The faces the builder's styles name. A font only a style asks for is never
-- loaded (the engine registers fonts that scene elements name themselves), so
-- one hidden element per face names it — see status_hud.lua's FONT_PRIMER.
local FONTS = { "fonts/SolarLabel.ttf", "fonts/SolarMono.ttf", "fonts/SolarStencil.ttf" }
local function primer()
  return { "box", key = "fontprimer", visible = false, w = 1, h = 1, pad = 0, gap = 0,
           items = FONTS, function(f, i) return { "text", key = "f" .. i, font = f, text = "0" } end }
end

function start(node)
  el = node:getcomponent("UiElement")
  ui.make(node, { primer() })
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or not el.visible then return end
  -- Described every frame: a card's price and lock state change the moment you
  -- buy an unlock or complete a contract. `ui.make` RECONCILES rather than
  -- rebuilds, so the cost is one table walk and the card you're hovering stays
  -- the card you're hovering.
  local tree = describe()
  if tree then ui.make(node, { tree, primer() }) end
end
