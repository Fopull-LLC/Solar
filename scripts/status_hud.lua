-- STATUS — the three numbers you are playing for, on screen while you are on
-- your feet.
--
-- They were not. This is a game about running a company, and your balance
-- existed in exactly two places: inside the Ops Board, and inside the Commerce
-- Depot's panel — both of which you have to walk into a building to open. Your
-- standing was in one of those. How full your pack was appeared on the tool
-- belt's line, sharing it with the belt, the prompt and the last thing that
-- happened, so it was the first thing pushed off.
--
-- So you could mine for five minutes, walk back with a full pack, and have seen
-- no number change the entire time. That is most of what makes a game read as a
-- tech demo rather than a game: the state is all there and none of it is in
-- front of you.
--
-- It sits top-left, which is empty on foot — while flying that corner belongs
-- to the contract card, and this stands down so the two never argue over it.
--
-- Drawn as a row of chips sized to their content. It was one 560-unit bar with
-- the text run jammed against its left edge and most of its width empty.
--
--   Published:  line   the three readouts as one line of text

defaults = {
  --@header Card
  --@range 0 1
  enabled = 1,
}

local el

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function crew_afoot()
  local pw = ref("planet_walker")
  return pw ~= nil and pw.onFoot == true
end

-- Everything in front of the player owns the screen while it is there.
local function blocked()
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  return false
end

-- The three readouts as data: what the chips show, and the one-line text the
-- harness (and anything else) can read back as `line`.
local function readouts()
  local co, inv = ref("company"), ref("inventory")
  local out = {}
  if co and co.money then
    out[#out + 1] = { key = "funds", label = "Funds", value = co.money(co.balance()) }
    out[#out + 1] = { key = "rep", label = "Rep", value = string.format("%+d", co.rep()) }
  end
  if inv and inv.mass then
    local m, cap = inv.mass("astro"), (inv.cap and inv.cap("astro")) or nil
    if cap and cap > 0 then
      -- FULL IS THE ONE STATE THAT LOOKS LIKE A BROKEN TOOL. You keep firing
      -- the laser, rock keeps coming off, and nothing goes in the pack — so say
      -- it here as well as on the belt, and say what to do about it.
      if m >= cap - 0.05 then
        out[#out + 1] = { key = "pack", label = "Pack full",
                          value = string.format("%.0f kg — sell at the Commerce Depot", cap),
                          warn = true, frac = 1 }
      else
        out[#out + 1] = { key = "pack", label = "Pack",
                          value = string.format("%.1f / %.0f kg", m, cap),
                          frac = math.max(0, math.min(1, m / cap)) }
      end
    else
      out[#out + 1] = { key = "pack", label = "Pack", value = string.format("%.1f kg", m) }
    end
  end
  return out
end

local function text_of(rs)
  local parts = {}
  for _, r in ipairs(rs) do
    if r.key == "rep" then parts[#parts + 1] = "rep " .. r.value
    elseif r.warn then parts[#parts + 1] = "PACK FULL  " .. r.value
    elseif r.key == "pack" then parts[#parts + 1] = "pack " .. r.value
    else parts[#parts + 1] = r.value end
  end
  return table.concat(parts, "     ")
end

-- Published: the same three numbers as one line of text.
line = ""

-- A chip: a small caps label and its value on dark glass, sized to what it
-- says. The pack chip carries a fill bar, because "how full" is a shape
-- before it is a number.
local METER_W = 44

local function chip(r)
  local kids = {
    { "text", key = "l", style = "hud/chipLabel", w = "fit", h = "fit",
      text = r.label },
    { "text", key = "v", style = r.warn and "hud/chipWarnText" or "hud/chipValue",
      w = "fit", h = "fit", text = r.value },
  }
  if r.frac and not r.warn then
    local hot = r.frac > 0.85
    kids[#kids + 1] = { "row", key = "m", w = METER_W, h = 4, radius = 2, pad = 0, gap = 0,
      fill = { 0.10, 0.16, 0.20 },
      { "box", key = "f", w = math.max(2, math.floor(METER_W * r.frac + 0.5)), h = 4, radius = 2,
        fill = hot and { 1.0, 0.72, 0.32 } or { 0.28, 0.86, 0.74 } } }
  end
  return { "row", key = r.key, style = r.warn and "hud/chipWarn" or "hud/chip",
           w = "fit", h = 28, gap = 7, align = "center", items = kids,
           function(k) return k end }
end


-- ── the HUD's layout at this screen size ────────────────────────────────────
--
-- The layer is MatchHeight at 720: the design height never changes and the
-- design WIDTH is 720 × aspect — 900 at 5:4, 1280 at 16:9, 1680 at 21:9. The
-- scene-authored blocks were laid out for one width, so at 5:4 they ran into
-- each other.
--
-- This pass owns the numbers that depend on the screen for the scene's cards:
-- widths, and which block stacks under which. In flight it stacks them around
-- the cockpit, whose own geometry flight_hud publishes as `layout`. It runs
-- every frame whether or not the chips are up, and it only writes a field that
-- moved.

local M, GAP = 16, 8          -- screen margin, gap between stacked blocks
local PAD = 14                -- the instrument frames' own padding
local PERIPH_W = 360
local MAP_W = 600             -- the orbit map's text block
local MENU_W = 112            -- the ☰ button, top-right
local CARD_W, FLIGHT_CARD_W = 360, 300
local TOAST_Y = -180          -- the notice toast's authored lift
-- The hotbar's half-width and height on foot (tool_belt), with its hint line.
local HOTBAR_HALF, HOTBAR_TOP = 230, 82

local nodes = {}
local function nd(name)
  local n = nodes[name]
  if n == nil or (n and n.valid == false) then
    n = find(name) or false
    nodes[name] = n
  end
  return n or nil
end

local function comp(n) return n and n:getcomponent("UiElement") or nil end

local function set(e, k, v)
  if e and math.abs((e[k] or -1e9) - v) > 0.25 then e[k] = v end
end

-- Design-space width of the screen right now.
function designWidth()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return 720 * w / h end
  end
  return 1280
end

function layout()
  local dw = designWidth()
  local fh = ref("flight_hud")
  local cockpit = fh and fh.layout

  -- The orbit map's text block, top-left, beside the ☰ button.
  local map_e, map_t = comp(nd("HUD Panel")), comp(nd("Ship HUD Text"))
  if map_e and map_t then
    local w = math.max(400, math.min(MAP_W, dw - M * 2 - MENU_W - GAP))
    set(map_e, "width", w)
    set(map_t, "width", w - PAD * 2)
  end

  -- The device console stacks under whatever holds the top-right corner: the
  -- fuel and charge block in flight, the ☰ button otherwise.
  local per = comp(nd("Peripherals Panel"))
  if per then
    set(per, "width", PERIPH_W)
    set(per, "posY", (cockpit and cockpit.rightBottom or (M + 28)) + GAP)
    set(comp(nd("Peripherals Title")), "width", PERIPH_W - PAD * 2)
  end

  -- The objectives card: top-right under the ☰ button on foot. In flight that
  -- corner is fuel and charge, so it moves to the top-left — beside the orbit
  -- strip where the screen is wide enough, under it where it isn't. (Its pin
  -- is TopRight, so a left edge at M is an offset of M + width − screen.)
  local ob = comp(nd("Objectives"))
  if ob then
    if cockpit then
      set(ob, "width", FLIGHT_CARD_W)
      set(ob, "posX", M + FLIGHT_CARD_W - dw)
      local beside = M + FLIGHT_CARD_W + GAP <= cockpit.topLeft
      set(ob, "posY", beside and M or (cockpit.topBottom + GAP))
    else
      set(ob, "width", CARD_W)
      set(ob, "posX", -M)
      set(ob, "posY", M + 28 + GAP)
    end
  end

  -- The flight card, bottom-left, beside whatever holds the bottom centre: the
  -- hotbar on foot, the instrument console in flight. Where the screen is too
  -- narrow for both it sits on top of them instead.
  local fo = comp(nd("Flight Ops"))
  if fo then
    local w, posY = CARD_W, -M
    if cockpit then
      w = FLIGHT_CARD_W
      if M + w + GAP > cockpit.consoleLeft then posY = -(720 - cockpit.consoleTop + GAP) end
    elseif crew_afoot() and dw / 2 - HOTBAR_HALF - GAP - M < w then
      posY = -(HOTBAR_TOP + GAP)
    end
    set(fo, "width", w)
    set(fo, "posY", posY)
  end

  -- The notice toast rides above the console in flight rather than across it.
  set(comp(nd("Notice Toast")), "posY", cockpit and -(720 - cockpit.consoleTop + GAP) or TOAST_Y)
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  layout()
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local show = params.enabled >= 0.5 and crew_afoot() and not blocked()
  el.visible = show
  if not show then return end
  local rs = readouts()
  line = text_of(rs)
  ui.make(node, { "row", key = "chips", w = "fit", h = "fit", gap = 6, pad = 0, align = "center",
                  items = rs, function(r) return chip(r) end })
end
