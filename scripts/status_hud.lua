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

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
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
  -- The full-height consoles carry their own balance in their header, and the
  -- chips sat on top of it.
  for _, k in ipairs({ "ops_board", "facility_menu", "tracking_station" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then return true end
  end
  return false
end

-- (The UI faces a style names, ui/solar.tokens.ron, load on their own since
-- 0.117.0-rc7, floptle/0477; the hidden FONT_PRIMER element that named them
-- is gone.)

-- The three readouts as data: what the chips show, and the one-line text the
-- harness (and anything else) can read back as `line`.
local function readouts()
  local co, inv = ref("company"), ref("inventory")
  local out = {}
  -- AIR, first and only while the tank is not full (planet_walker's breath):
  -- the suit's tank drains with the head under water. A gauge that turns
  -- caution yellow under half and warning red under a quarter.
  local pw = ref("planet_walker")
  if pw and pw.oxygen and (pw.oxygen < 0.995 or pw.downed) then
    local o = math.max(0, math.min(1, pw.oxygen))
    out[#out + 1] = { key = "o2", label = pw.downed and "Out of air" or "Air",
                      value = pw.downed and "—" or string.format("%d s", math.floor((pw.o2Left or 0) + 0.5)),
                      frac = o, warn = pw.downed or o < 0.25, gauge = "air" }
  end
  if co and co.money then
    out[#out + 1] = { key = "funds", label = "Funds", value = co.money(co.balance()) }
    out[#out + 1] = { key = "rep", label = "Rep", value = (co.isSandbox and co.isSandbox()) and "MAX" or string.format("%+d", co.rep()) }
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
    if r.key == "o2" then parts[#parts + 1] = "air " .. r.value
    elseif r.key == "rep" then parts[#parts + 1] = "rep " .. r.value
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
  if r.frac and (not r.warn or r.gauge == "air") then
    local hot = r.frac > 0.85
    local fillc = hot and { 1.0, 0.80, 0.28 } or { 0.77, 0.75, 0.68 }
    if r.gauge == "air" then
      -- Air runs the other way: low is the danger (warn yellow, danger red).
      fillc = (r.frac < 0.25 and { 0.97, 0.34, 0.25 }) or (r.frac < 0.5 and { 1.0, 0.80, 0.28 })
        or { 0.77, 0.75, 0.68 }
    end
    -- A gauge: a dark groove, an ink bar (caution yellow when
    -- nearly full).
    kids[#kids + 1] = { "row", key = "m", w = METER_W, h = 5, radius = 1, pad = 0, gap = 0,
      fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(2, math.floor(METER_W * r.frac + 0.5)), h = 5, radius = 1,
        fill = fillc } }
  end
  return { "row", key = r.key, style = r.warn and "hud/chipWarn" or "hud/chip",
           w = "fit", h = 28, gap = 7, align = "center", items = kids,
           function(k) return k end }
end


-- ── the HUD's layout at this screen size ────────────────────────────────────
--
-- The layer is MatchHeight at uiDesignH() (720 at an interface size of 100%)
-- and the design WIDTH is that × aspect — 900 at 5:4, 1280 at 16:9, 1680 at 21:9. The
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
    if w and h and h > 0 then return uiDesignH() * w / h end
  end
  return 1280 * uiDesignH() / 720
end

-- The crew strip's top edge, in design units above the screen's bottom, or
-- nil when it is not showing. Pure arithmetic in `stripTopOf` (tests).
function stripTopOf(bottom_off, h_px, screen_h, design_h)
  if not (h_px and h_px > 0 and screen_h and screen_h > 0) then return nil end
  return -(bottom_off or -12) + h_px * (design_h or 720) / screen_h
end

function stripTop()
  local n = nd("Crew Strip")
  local e = comp(n)
  if not (e and e.visible ~= false and n.uiRect and camera and camera.screenSize) then return nil end
  local _, _, _, h = n:uiRect()
  local _, sh = camera.screenSize()
  return stripTopOf(e.posY, h, sh, uiDesignH())
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
      if M + w + GAP > cockpit.consoleLeft then posY = -((cockpit.consoleRise or (uiDesignH() - cockpit.consoleTop)) + GAP) end
    elseif crew_afoot() and dw / 2 - HOTBAR_HALF - GAP - M < w then
      posY = -(HOTBAR_TOP + GAP)
    end
    -- …and the crew strip shares that corner (crew_strip.lua, pinned
    -- bottom-left): while it shows, the card stands on top of it. Measured
    -- in DESIGN units — the strip's pixel height × uiDesignH() / screen
    -- height. crew_strip used to lift the card itself with 720 in place of
    -- the design height, so at any interface size under 100% (Auto is 85% at
    -- 1080p) the lift came up short and "END FLIGHT" sat on the portraits
    -- (playtest dfb3e17).
    local lift = stripTop()
    if lift then posY = math.min(posY, -(lift + GAP)) end
    set(fo, "width", w)
    set(fo, "posY", posY)
  end

  -- The notice toast rides above the console in flight rather than across it.
  set(comp(nd("Notice Toast")), "posY", cockpit and -((cockpit.consoleRise or (uiDesignH() - cockpit.consoleTop)) + GAP) or TOAST_Y)
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
  ui.make(node, { { "row", key = "chips", w = "fit", h = "fit", gap = 6, pad = 0, align = "center",
                    items = rs, function(r) return chip(r) end } })
end
