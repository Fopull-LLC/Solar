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
  if def.thrust then return string.format("engine · thrust %d · %.1f t", def.thrust, def.mass) end
  if def.fuel then return string.format("fuel tank · %d fuel · %.1f t", def.fuel, def.mass) end
  if def.kind == "crewed" then return "crew pod — every craft needs one" end
  if def.chute then return "parachute — slows the landing" end
  if def.cargo then return string.format("cargo hold · carries %d kg", def.cargo) end
  if def.legs then return "landing legs — stand up on arrival" end
  if def.solar then return string.format("solar panel · +%d power/s in light", def.gen or 0) end
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
      if def then   -- an id with no registry entry is skipped, not drawn broken
        local locked = (rs and not rs.isUnlocked(id)) or false
        local price = locked and ((rs and rs.costOf(id)) or 0) or def.cost
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
          { "row", key = "top", w = "100%", h = 16, gap = 6, pad = 0, align = "center",
            { "text", key = "n", w = "grow", h = 16, text = def.label,
              textSize = 13, textAlign = "start",
              textColor = locked and "#9fb3c2" or "#d1e8fa" },
            { "text", key = "p", w = "fit", h = 16,
              text = locked and ("unlock " .. money(price)) or money(price),
              textSize = 12, textAlign = "end",
              textColor = locked and "#ffb852" or "#47dbbd" } },
          { "text", key = "r", w = "100%", h = 14, text = role(def),
            textSize = 10.5, textAlign = "start", textColor = "#7f97aa" },
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

function start(node)
  el = node:getcomponent("UiElement")
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or not el.visible then return end
  -- Described every frame: a card's price and lock state change the moment you
  -- buy an unlock or complete a contract. `ui.make` RECONCILES rather than
  -- rebuilds, so the cost is one table walk and the card you're hovering stays
  -- the card you're hovering.
  local tree = describe()
  if tree then ui.make(node, tree) end
end
