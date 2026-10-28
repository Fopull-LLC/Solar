-- CREW STRIP — live portraits of the crew aboard the craft you control,
-- bottom-left (docs/crew-and-items.md §4.4, §3.3).
--
--   ┌ CREW · Kestrel I · 6/8 ─────────────────────────────────┐
--   │ ◂ ░[live cam] [live cam] [live cam] [live ca░ ▸          │  112 × 112 (large: 208 × 208)
--   │    D.OKAFOR★   J.REYES    M.HALE     ...                 │  hover: [EVA] [⇄]
--   ├ ON FOOT ────────────────────────────────────────────────┤
--   │ [T.VANCE 42 m · CONTROL]  [R.ITO 310 m · CONTROL]       │  chips, no live cam
--   └─────────────────────────────────────────────────────────┘
--
-- A HORIZONTAL SCROLL VIEW. Its width is capped so the strip always ends
-- before whatever holds the bottom centre (the flight console, the hotbar on
-- foot; status_hud.stripMaxW), at every interface size and screen. With more
-- crew than fit, the view clips and scrolls: the wheel over it steps one
-- portrait a notch (the engine's scroll view: a wheel drives X when there is
-- no Y to drive), ◂ ▸ at the ends show only while there is more that way,
-- and a fade on the clipped side says so too. Switching to a member, or a
-- member boarding, scrolls them into view (focusMember). A wheel notch or an
-- arrow moves one portrait.
--
-- Portraits: one a member, each a UI image wearing `rt:crew<i>`, filmed by a
-- top-level camera ("Crew Cam <i>") set every lateUpdate 0.42 m in front of
-- the member's face in their seat, looking back at it, fovY 0.9. ONLY THE
-- PORTRAITS IN VIEW FILM: a scrolled-out one's camera is disabled (a disabled
-- camera is not drawn), so the cost is bounded by what fits, not by the crew.
-- In a closed part the camera draws only the `interior` layer (the room,
-- iva.lua, and the dolls); an open seat's rider needs the world.
--
-- Budget: the portraits in view share RT_BUDGET redraws a second, hovered
-- HOVER_HZ. Hidden strip, the map, the builder, cinematic mode: the cameras
-- are disabled and the images keep their frames.
--
-- `\` cycles small → large → hidden (saved: opt_crewStrip).
--
-- EVA from a portrait: crew.eva(id); with no RCS Pack in space it comes back
-- "confirm" and the warning is asked here, Cancel the default (Enter
-- cancels; "EVA anyway" must be clicked); after the third time a "don't ask
-- again this save" box appears (crew.evaNoAsk).
--
-- Pure layout (luajit, tests/smoke_crew_strip.lua): layout(n, size, maxW,
-- scroll), scrollToShow(L, i, scroll).

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

-- A portrait is SQUARE, its target too, and it is drawn at exactly its frame's
-- size inside the frame's border (playtest: a 4:3 target "cover"-fitted into
-- its frame drew past the border, off the strip's left edge).
SIZES = { small = { w = 112, h = 112, tw = 168, th = 168 }, large = { w = 208, h = 208, tw = 312, th = 312 } }
FRAME_PAD = 3                -- the frame's border round the picture (design units, every side)
MODES = { "small", "large", "hidden" }
-- Measured on rc38 (tools/perf/ivaprobe.sh ivapod2, Medium, 1920×1052): a
-- portrait target pays for a whole scene render whatever its cullMask (the
-- sky, terrain, sun shadows and post run for it: engine card H1), ~7 ms a
-- redraw: three at 8 Hz cost 1.1 ms a frame, at 4 Hz 0.8 ms, against the
-- 0.6 ms budget; sharing 6 redraws a second measured 0.12–0.59 ms (noise
-- ±0.3 at load 4–9). Until H1 lands the portraits SHARE a redraw budget:
-- RT_BUDGET redraws a second across the view (each portrait RT_BUDGET / n,
-- staggered), the hovered one HOVER_HZ. Engine 0.117.1-dev.1363 (cards
-- 0568/0570: the portraits skip shadows, sky, terrain and fog, and a hidden
-- one stops drawing) measured the strip at 5 a second at ~0.1 ms, so the
-- budget is raised to 12: about 4 Hz a portrait for a pod of three.
RT_BUDGET = 12.0
HZ_MIN = 1.2
HOVER_HZ, OPEN_HZ = 6.0, 4.0
-- An open seat's portrait films the world, so it costs more than a cabin's:
-- unhovered it still films, slowly. (It used to film ONE frame and then
-- switch off — but a camera that has drawn once redraws only at its `hz`, so
-- that one frame at 4 Hz was never drawn and the portrait stayed black:
-- playtest dfb3e17, M.MOREAU on a bike.)
OPEN_IDLE_HZ = 1.0
function rateFor(k, n, hovered)
  if hovered then return HOVER_HZ end
  local hz = math.max(HZ_MIN, RT_BUDGET / math.max(1, n))
  return hz * (1.0 + 0.04 * ((k or 1) - 1))       -- staggered: never in step for long
end
CAM_DIST, CAM_FOV = 0.42, 0.9   -- close enough that a face fills the frame and its expression reads (crew_faces)
GAP, PLATE_H = 6, 18
INTERIOR_BIT, OFFSTAGE_BIT = 16, 32

CARD_PAD = 6                 -- the strip card's own padding (describe's root)
ARROW_W, ARROW_GAP = 14, 4   -- the ◂ ▸ keys at the ends of an overflowing view
FADE_W = 6                   -- one step of the edge fade (three steps)
HEAD_MIN = 180               -- the header's width when the cap allows (CREW · name · k/N)

-- ── pure layout ────────────────────────────────────────────────────────────
-- n members aboard, size "small" | "large", maxW the strip's widest OUTER
-- width in design units (nil: no cap), scroll the view's position → {
--   n, w, h, tw, th, fw (a framed portrait's width), pitch (fw + GAP),
--   content_w, view_w, overflow, max_scroll, scroll (clamped), visible =
--   {i…} (the portraits at least partly in view), vis = {[i] = true},
--   strip_w, strip_h, inner_w (inside the card's padding), more_l, more_r }
function layout(n, size, maxW, scroll)
  n = math.max(0, math.floor(n or 0))
  local S = SIZES[size or "small"] or SIZES.small
  local fw = S.w + 2 * FRAME_PAD
  local pitch = fw + GAP
  local content_w = n > 0 and (n * pitch - GAP) or 0
  local inner_max = maxW and (maxW - 2 * CARD_PAD) or math.huge
  local overflow, view_w = false, content_w
  if content_w > inner_max then
    overflow = true
    -- the view takes all the room it has: a portrait cut by its edge sits
    -- under the fade (snapping to whole portraits left up to a large
    -- portrait's width of the corner empty)
    view_w = math.max(40, math.floor(inner_max - 2 * (ARROW_W + ARROW_GAP)))
  end
  local max_scroll = math.max(0, content_w - view_w)
  scroll = math.max(0, math.min(scroll or 0, max_scroll))
  local visible, vis = {}, {}
  for i = 1, n do
    local x0 = (i - 1) * pitch
    if x0 + fw > scroll + 0.5 and x0 < scroll + view_w - 0.5 then
      visible[#visible + 1] = i
      vis[i] = true
    end
  end
  local row_w = view_w + (overflow and 2 * (ARROW_W + ARROW_GAP) or 0)
  local inner_w = math.min(inner_max, math.max(row_w, HEAD_MIN))
  return { n = n, w = S.w, h = S.h, tw = S.tw, th = S.th, fw = fw, pitch = pitch,
           content_w = content_w, view_w = view_w, overflow = overflow, max_scroll = max_scroll, scroll = scroll,
           visible = visible, vis = vis, row_w = row_w, inner_w = inner_w,
           more_l = scroll > 0.5, more_r = scroll < max_scroll - 0.5,
           strip_w = inner_w + 2 * CARD_PAD,
           strip_h = 22 + S.h + 2 * FRAME_PAD + PLATE_H + 2 * CARD_PAD }
end

-- The scroll that brings portrait i fully into view, moving as little as it
-- can (an in-view portrait leaves it where it is).
function scrollToShow(L, i, scroll)
  scroll = scroll or L.scroll or 0
  if not (L and i and i >= 1 and i <= L.n) then return scroll end
  local x0 = (i - 1) * L.pitch
  if x0 < scroll then scroll = x0
  elseif x0 + L.fw > scroll + L.view_w then scroll = x0 + L.fw - L.view_w end
  return math.max(0, math.min(scroll, L.max_scroll))
end

-- "Dana Okafor" → "D.OKAFOR"
function shortName(name)
  name = tostring(name or "?")
  local f, l = name:match("^(%S+)%s+(.+)$")
  if not f then return name:upper() end
  return (f:sub(1, 1) .. "." .. l):upper()
end

-- The chips a portrait wears, from crew.alerts / the record: {text, style}.
function chipsFor(a, m)
  local out = {}
  a = a or {}
  local o2 = a.o2 or (m and m.o2) or 1
  if o2 < 0.25 then out[#out + 1] = { string.format("O2 %d%%", math.floor(o2 * 100 + 0.5)), o2 < 0.10 and "danger" or "warn" } end
  local hp = a.hp or (m and m.hp) or 1
  if hp < 0.99 then out[#out + 1] = { string.format("HP %d%%", math.floor(hp * 100 + 0.5)), hp < 0.35 and "danger" or "warn" } end
  if (a.heat or 0) >= 0.2 then out[#out + 1] = { "HEAT", (a.heat or 0) >= 0.6 and "danger" or "warn" } end
  if a.blackout then out[#out + 1] = { "BLACKOUT", "danger" } end
  if a.downed then out[#out + 1] = { string.format("DOWN %d s", math.max(0, math.floor(a.downed + 0.5))), "danger" } end
  return out
end

-- ── state ──────────────────────────────────────────────────────────────────
local el, host
local mode = "small"
local cams = {}           -- [i] = { node, making, tw, hz, mask, open, on }: member i's portrait camera
VIEW_NAME = "Crew Strip View"
local view_node = nil     -- the scroll view's node, while the crew overflow it
local scroll = 0          -- where the view stands (design units), read back each frame
local scroll_pending = nil  -- a scroll to write into the view (it may not exist yet)
local want_focus = nil    -- a member id to bring into view
local last_active, last_ids, last_craft = nil, nil, nil
local last_L = nil
local hover_id, hover_t = nil, -10
local confirm = nil       -- { id, warn, stay, t }
local msg, msg_t = nil, -10
-- Published for probes: shown = portraits in view, live = cameras filming,
-- n = aboard, and the view's geometry (design units).
strip = { shown = 0, live = 0, n = 0, overflow = false, scroll = 0, maxScroll = 0, viewW = 0, width = 0, cap = nil,
          visible = {} }
hoverId = nil             -- published: the member whose portrait the pointer is on
local function now() return time or 0 end

local function opt_load()
  local m = save and save.get and save.get("opt_crewStrip")
  if m == "small" or m == "large" or m == "hidden" then mode = m end
end

function setMode(m)
  if m ~= "small" and m ~= "large" and m ~= "hidden" then return end
  mode = m
  if save and save.set then save.set("opt_crewStrip", m) end
end
function getMode() return mode end
function cycleMode()
  for i, m in ipairs(MODES) do
    if m == mode then setMode(MODES[i % #MODES + 1]) return mode end
  end
  setMode("small")
  return mode
end

-- ── what is controlled ─────────────────────────────────────────────────────
local function piloted()
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting and v.node and v.node.valid ~= false then return v end
  end
  return nil
end

local function blocked()
  local pc = ref("planet_camera")
  if pc and (pc.cinematic or pc.freecam) then return true end
  local gm = ref("game_manager")
  if gm and (gm.inputOwner == "builder" or gm.loading or gm.curtain) then return true end
  local om = ref("orbit_map")
  if om and (om.open or om.isOpen and om.isOpen()) then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  return false
end

-- ── cameras ────────────────────────────────────────────────────────────────
local function cam_for(k, S)
  local c = cams[k]
  if not c then c = {}; cams[k] = c end
  if c.node and c.node.valid ~= false then
    if c.tw ~= S.tw then
      pcall(function() c.node:setCamera { width = S.tw, height = S.th } end)
      c.tw = S.tw
    end
    return c
  end
  if c.making or not createNode then return nil end
  c.making = true
  createNode("Crew Cam " .. k, nil, function(n)
    c.making = false
    c.node = n
    c.tw = S.tw
    pcall(function()
      n:setCamera { target = "crew" .. k, width = S.tw, height = S.th, hz = rateFor(k, 1, false), fovY = CAM_FOV,
                    active = false, cullMask = INTERIOR_BIT,
                    -- a portrait films a lit cabin: no sun map, sky, terrain or fog passes of its own
                    shadows = false, sky = false, terrain = false, fog = false }
    end)
    c.hz, c.mask = rateFor(k, 1, false), INTERIOR_BIT
  end)
  return nil
end

local function cam_on(c, on)
  if c and c.node and c.node.valid ~= false and c.on ~= on then
    c.node.enabled = on
    c.on = on
  end
end

local function all_off()
  for _, c in pairs(cams) do cam_on(c, false) end
  strip.live = 0
end

-- `open`: the portrait films the world (an open seat), so it draws the sky
-- and the ground behind the face. A cabin's draws neither: the Skybox's
-- solid colour is black, which is right behind a lit room and a black void
-- behind a rider.
local function set_cam(c, hz, mask, open)
  if not (c and c.node and c.node.valid ~= false) then return end
  open = open == true
  if c.hz ~= hz or c.mask ~= mask or c.open ~= open then
    pcall(function() c.node:setCamera { hz = hz, cullMask = mask, sky = open, terrain = open } end)
    c.hz, c.mask, c.open = hz, mask, open
  end
end

-- Aim camera c at member m's face: closed seats through iva (the seat's eye,
-- this frame); an open seat at the rider's doll (or the avatar).
local function aim(c, v, m)
  local I, C = ref("iva"), ref("crew")
  local eye, right, up, back
  if not m.open and I and I.eyeOf then
    eye, right, up, back = I.eyeOf(v, m.uid, m.slot)
  end
  if not eye then
    local n = (C and C.dollOf and C.dollOf(m.id)) or (m.avatar and find and find("Astronaut")) or nil
    if not (n and n.valid ~= false and I and I.riderEye) then return false end
    eye, right, up, back = I.riderEye(v, m.uid, n)
    if not eye then return false end
    eye = eye - back * 0.08            -- the face, not the eye-in-front-of-it
  end
  -- level with the face (a seated doll's eyes sit a little under the
  -- rig's standing eye height), looking straight back at it
  local p = eye - back * CAM_DIST - up * 0.03
  c.node.pos = p
  c.node:lookAt(eye - up * 0.06, up)
  return true
end

-- ── actions ────────────────────────────────────────────────────────────────
local function say(t) msg, msg_t = t, now() end

function evaMember(id, stay, confirmed)
  local C = ref("crew")
  if not (C and C.eva) then return false end
  local ok, why, warn = C.eva(id, { stay = stay, confirmed = confirmed })
  if ok then confirm = nil return true end
  if why == "confirm" then
    if save and save.get and save.get("crew.evaNoAsk") then
      return evaMember(id, stay, true)
    end
    confirm = { id = id, warn = warn or "No RCS Pack.", stay = stay, t = now() }
    return false, "confirm"
  end
  say(why or "can't EVA now")
  return false, why
end

function confirmEva(yes, noAsk)
  if not confirm then return false end
  local c = confirm
  confirm = nil
  if not yes then return false end
  if save and save.set then
    local n = (save.get("crew.evaAsked") or 0) + 1
    save.set("crew.evaAsked", n)
    if noAsk then save.set("crew.evaNoAsk", true) end
  end
  return evaMember(c.id, c.stay, true)
end
function confirmOpen() return confirm end
-- Probes: show the hover controls on member `id`'s portrait (nil: the pointer).
local forced_hover = nil
function forceHover(id) forced_hover = id end

-- ⇄: the member moves to the next free slot aboard (an IVA transfer).
function moveSeat(v, m)
  local C = ref("crew")
  if not (v and C and C.seatMap) then return false end
  local map = C.seatMap(v)
  local start = nil
  for i, s in ipairs(map) do if s.uid == m.uid and s.slot == m.slot then start = i end end
  if not start then return false end
  for j = 1, #map - 1 do
    local s = map[(start + j - 1) % #map + 1]
    if not s.taken then
      if v.seatMember then
        local ok, why = v.seatMember(s.uid, s.slot, m.id)
        if ok ~= false then
          v.seatMember(m.uid, m.slot, nil)
          say(shortName(m.name) .. " → " .. tostring(s.label or "seat"))
          return true
        end
        say(why or "can't move there")
        return false
      elseif C.board then
        return C.board(m.id, v, s.uid, s.slot)
      end
    end
  end
  say("no free seat aboard")
  return false
end

-- ── the description ────────────────────────────────────────────────────────
local function hovered_names()
  local h = ui and ui.hovered and ui.hovered()
  local out = {}
  local depth = 0
  while h and depth < 6 do
    if h.name then out[#out + 1] = h.name end
    h = h.parent
    depth = depth + 1
  end
  return out
end

local function hovered_key(prefix)
  for _, nm in ipairs(hovered_names()) do
    local k = nm:match("^" .. prefix .. "(%d+)")
    if k then return tonumber(k) end
  end
  return nil
end

local function chip_row(key, chips)
  local row = { "row", key = key, w = "fit", h = 14, gap = 3, pad = 0, align = "center" }
  for i, c in ipairs(chips) do
    row[#row + 1] = { "text", key = key .. i, style = c[2] == "danger" and "hud/lampDanger" or "hud/lampWarn",
                      w = "fit", h = 13, text = " " .. c[1] .. " " }
  end
  return row
end

local function portrait(i, m, L, hov, v)
  local C = ref("crew")
  local a = (C and C.alerts and C.alerts(m.id)) or {}
  local name = shortName(m.name) .. (m.commander and " ★" or "")
  local plate = { "row", key = "pl" .. i, w = L.w, h = PLATE_H, gap = 2, pad = 0, align = "center",
                  { "text", key = "nm" .. i, style = "hud/micro", w = "grow", h = PLATE_H, text = name } }
  if hov then
    local ok, why, warn = true, nil, nil
    if C and C.evaCheck then ok, why, warn = C.evaCheck(m.id) end
    plate[#plate + 1] = { "button", key = "eva" .. i, style = "hud/button", w = 34, h = PLATE_H - 2, text = "EVA",
                          textAlign = "center", opacity = ok and 1.0 or 0.45,
                          onClicked = function()
                            if not ok then say(why or "can't EVA now") return end
                            evaMember(m.id, input and input.key and (input.key("shift") or input.key("lshift")), false)
                          end }
    plate[#plate + 1] = { "button", key = "mv" .. i, style = "hud/button", w = 22, h = PLATE_H - 2, text = "⇄",
                          textAlign = "center", onClicked = function() moveSeat(v, m) end }
    if not ok and why then
      plate[1].text = shortName(m.name) .. " · " .. why
    end
  end
  -- a member whose camera has never been made (never in view) shows the
  -- bezel: an image wearing a target nobody draws would be an empty hole
  local c = cams[i]
  local tex = (c and c.node and c.node.valid ~= false) and ("rt:crew" .. i) or nil
  local img = tex and { "image", key = "img" .. i, texture = tex, w = L.w, h = L.h, imageFit = "contain" }
    or { "box", key = "img" .. i, style = "hud/bezel", w = L.w, h = L.h }
  local chips = chipsFor(a, m)
  local col = { "col", key = "pt" .. i, style = "hud/chip", w = L.w + 2 * FRAME_PAD, h = "fit", gap = 1, pad = FRAME_PAD,
                align = "start",
                img, plate }
  if #chips > 0 then col[#col + 1] = chip_row("ch" .. i, chips) end
  return col
end

-- The portraits' column height: the picture in its frame, the name plate,
-- and the chip row when anyone wears chips (the view is exactly this tall,
-- so it has no vertical travel and the wheel drives it sideways).
local function port_h(L, chips) return L.h + 2 * FRAME_PAD + 1 + PLATE_H + (chips and 15 or 0) end

-- Step the view a portrait at a time (the ◂ ▸ keys).
function scrollBy(d)
  local L = last_L
  if not (L and L.overflow) then return end
  scroll_pending = math.max(0, math.min((scroll_pending or scroll) + d * L.pitch, L.max_scroll))
end
-- Put the view at x (probes); focusMember(id) brings a member into view.
function scrollTo(x) scroll_pending = math.max(0, x or 0) end
function focusMember(id) want_focus = id end

local function fade(key, pin, h, more)
  local out = {}
  if not more then return out end
  for s = 1, 3 do
    out[#out + 1] = { "box", key = key .. s, pin = pin, x = (pin == "topRight" and -1 or 1) * (s - 1) * FADE_W, y = 0,
                      w = FADE_W, h = h, fill = { 0.112, 0.116, 0.104, ({ 0.82, 0.55, 0.25 })[s] } }
  end
  return out
end

local function arrow(key, glyph, on, h, d)
  if not on then return { "box", key = key .. "0", w = ARROW_W, h = h } end
  return { "button", key = key, style = "hud/button", w = ARROW_W, h = h, text = glyph, textAlign = "center",
           textValign = "center", onClicked = function() scrollBy(d) end }
end

-- A row of on-foot chips no wider than the strip may be: it wraps.
local function chip_w(label) return #label * 6.0 + 16 end

local function describe(v, list, L, afoot, chips_any, cap_in)
  local C = ref("crew")
  local rows = {}
  if v then
    local total = 0
    for _, s in ipairs((C and C.seatMap and C.seatMap(v)) or {}) do total = total + 1 end
    rows[#rows + 1] = { "row", key = "head", w = L.inner_w, h = 18, gap = 8, pad = 0, align = "center",
                        { "text", key = "ht", style = "hud/micro", w = "grow", h = 18, maxLines = 1, overflow = "ellipsis",
                          text = string.format("CREW · %s · %d/%d", tostring(v.craftName or "Craft"), #list,
                            math.max(total, #list)) } }
    local ph = port_h(L, chips_any)
    if #list == 0 then
      rows[#rows + 1] = { "text", key = "empty", style = "hud/micro", w = "fit", h = 18, text = "NOBODY ABOARD" }
    elseif L.overflow then
      -- the clipped, scrolling view: every portrait is in it (the clip hides
      -- and the hit test skips the ones out of view; their cameras are off)
      local view = { "scroll", key = "view", name = VIEW_NAME, pin = "topLeft", x = 0, y = 0, w = L.view_w, h = ph + 0.5,
                     dir = "row", gap = GAP, pad = 0, align = "start", scrollSpeed = L.pitch }
      for i, m in ipairs(list) do view[#view + 1] = portrait(i, m, L, hover_id == m.id, v) end
      local framebox = { "box", key = "vf", w = L.view_w, h = ph + 0.5, view }
      for _, f in ipairs(fade("fl", "topLeft", ph, L.more_l)) do framebox[#framebox + 1] = f end
      for _, f in ipairs(fade("fr", "topRight", ph, L.more_r)) do framebox[#framebox + 1] = f end
      rows[#rows + 1] = { "row", key = "ports", w = L.row_w, h = "fit", gap = ARROW_GAP, pad = 0, align = "start",
                          arrow("arL", "◂", L.more_l, L.h + 2 * FRAME_PAD, -1), framebox,
                          arrow("arR", "▸", L.more_r, L.h + 2 * FRAME_PAD, 1) }
    else
      local prow = { "row", key = "prow", w = "fit", h = "fit", gap = GAP, pad = 0, align = "start" }
      for i, m in ipairs(list) do prow[#prow + 1] = portrait(i, m, L, hover_id == m.id, v) end
      rows[#rows + 1] = prow
    end
  end
  if #afoot > 0 then
    rows[#rows + 1] = { "text", key = "afh", style = "hud/micro", w = "fit", h = 14, text = v and "ON FOOT" or "CREW" }
    local est, shown = 0, {}
    for i, e in ipairs(afoot) do
      if i > 6 then break end
      shown[#shown + 1] = e
      est = est + chip_w(e.label) + (i > 1 and 4 or 0)
    end
    local row = { "row", key = "afoot", w = math.min(cap_in, est), h = "fit", gap = 4, pad = 0, align = "center", wrap = true }
    for i, e in ipairs(shown) do
      row[#row + 1] = { "button", key = "af" .. i, style = "hud/button", w = "fit", h = 20,
                        text = e.label, textAlign = "center", onClicked = e.act }
    end
    rows[#rows + 1] = row
  end
  if confirm then
    local cf = confirm
    local asked = (save and save.get and save.get("crew.evaAsked")) or 0
    local box = { "col", key = "confirm", style = "hud/card", w = math.min(360, cap_in), h = "fit", gap = 6, pad = 8, align = "start",
      { "text", key = "cft", style = "hud/chipWarnText", w = "100%", h = "fit", wrap = true, text = cf.warn },
      { "row", key = "cfb", w = "100%", h = 24, gap = 8, pad = 0, align = "center",
        { "button", key = "cfyes", style = "hud/button", w = 120, h = 22, text = "EVA anyway", textAlign = "center",
          onClicked = function() confirmEva(true, cf.noAsk) end },
        { "button", key = "cfno", style = "panel/action", w = 90, h = 22, text = "Cancel", textAlign = "center",
          onClicked = function() confirmEva(false) end } } }
    if asked >= 3 then
      box[#box + 1] = { "button", key = "cfask", style = "hud/button", w = "fit", h = 18,
                        text = (cf.noAsk and "☑" or "☐") .. " Don't ask again this save", textAlign = "start",
                        onClicked = function() cf.noAsk = not cf.noAsk end }
    end
    rows[#rows + 1] = box
  end
  if msg and now() - msg_t < 2.5 then
    rows[#rows + 1] = { "text", key = "msg", style = "hud/chipWarnText", w = "fit", maxW = cap_in, h = 16, maxLines = 1,
                        overflow = "ellipsis", text = msg }
  end
  local root = { "col", key = "strip", style = "hud/card", w = "fit", h = "fit", gap = 4, pad = CARD_PAD, align = "start" }
  for _, r in ipairs(rows) do root[#root + 1] = r end
  return root
end

-- The on-foot chips: members on foot in range (CONTROL), and on foot, the
-- craft you came from (◂ Kestrel I).
local function afoot_entries(v)
  local C = ref("crew")
  local out = {}
  if not C then return out end
  local active = C.activeId and C.activeId()
  local list = (C.switchList and C.switchList()) or {}
  for _, e in ipairs(list) do
    if e.kind == "crew" and e.id ~= active then
      out[#out + 1] = { label = string.format("%s %s · CONTROL", shortName(e.name), e.dist and string.format("%.0f m", e.dist) or ""),
                        act = function() local ok, why = C.control(e.id); if not ok then say(why or "can't") end end }
    end
  end
  if not v then
    for _, e in ipairs(list) do
      if e.kind == "vessel" and e.v and (e.crew or 0) > 0 then
        out[#out + 1] = { label = "◂ " .. tostring(e.name),
                          act = function()
                            local ok, why
                            if C.takeCraft then ok, why = C.takeCraft(e.v) else ok, why = C.quickSwap() end
                            if not ok then say(why or "can't") end
                          end }
        break
      end
    end
  end
  return out
end

-- ── lifecycle ──────────────────────────────────────────────────────────────
function start(node)
  host = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  opt_load()
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if input and input.pressed and input.pressed("\\") and not blocked() then cycleMode() end
  if confirm and input.pressed("enter") then confirmEva(false) end
end

-- The strip's widest outer width (design units): status_hud knows where the
-- console or the hotbar stands. nil: no cap known yet.
local function cap()
  local SH = ref("status_hud")
  return SH and SH.stripMaxW and SH.stripMaxW() or nil
end

local function view_el()
  if not (view_node and view_node.valid ~= false) then view_node = find and find(VIEW_NAME) or nil end
  return view_node and view_node:getcomponent("UiElement") or nil
end

local function hide(node)
  if el.visible then el.visible = false end
  all_off()
  strip.shown, strip.n, strip.overflow = 0, 0, false
  lift_ops(node, false)
end

function lateUpdate(node, dt)
  if not el then return end
  local C = ref("crew")
  local v = piloted()
  if mode == "hidden" or blocked() or not C then return hide(node) end
  local list = (v and C.aboard and C.aboard(v)) or {}
  local afoot = afoot_entries(v)
  if #list == 0 and #afoot == 0 and not confirm then return hide(node) end
  if not el.visible then el.visible = true end
  local maxW = cap()
  local S = SIZES[mode] or SIZES.small
  -- where the view stands: the wheel moved it (the engine owns it), or we
  -- are about to
  local L = layout(#list, mode, maxW, scroll)
  if L.overflow then
    local e = view_el()
    if e then
      if scroll_pending then e.scrollX = math.min(scroll_pending, L.max_scroll); scroll_pending = nil end
      scroll = e.scrollX or scroll
    elseif scroll_pending then
      scroll = scroll_pending
    end
  else
    view_node, scroll, scroll_pending = nil, 0, nil
  end
  -- who to bring into view: the member you switch to, a member boarding
  local active = C.activeId and C.activeId()
  local craft = v and v.node and v.node.id or nil
  local ids = {}
  for _, m in ipairs(list) do ids[m.id] = true end
  if craft ~= last_craft then
    scroll, scroll_pending = 0, 0
    want_focus = active
  else
    if active ~= last_active then want_focus = active end
    if last_ids then
      for _, m in ipairs(list) do if not last_ids[m.id] then want_focus = m.id end end
    end
  end
  last_active, last_ids, last_craft = active, ids, craft
  L = layout(#list, mode, maxW, scroll_pending or scroll)
  if want_focus then
    for i, m in ipairs(list) do
      if m.id == want_focus then
        local ns = scrollToShow(L, i, L.scroll)
        if math.abs(ns - L.scroll) > 0.5 then
          scroll_pending = ns
          L = layout(#list, mode, maxW, ns)
        end
      end
    end
    want_focus = nil
  end
  last_L = L
  -- hover: which portrait the pointer is over (its id), for EVA/⇄ and the rate
  local hk = hovered_key("pt") or hovered_key("img") or hovered_key("pl") or hovered_key("eva") or hovered_key("mv")
    or hovered_key("nm")
  local hm = hk and L.vis[hk] and list[hk]
  if forced_hover then hover_id, hover_t = forced_hover, now()
  elseif hm then hover_id, hover_t = hm.id, now()
  elseif now() - hover_t > 0.3 then hover_id = nil end
  hoverId = hover_id          -- published: face.lua turns the hovered member's eyes to the lens
  -- the interiors the portraits film
  local I = ref("iva")
  if v and I and I.need then I.need(v) end
  local live = 0
  local nvis = #L.visible
  local chips_any = false
  for i, m in ipairs(list) do
    if not chips_any and #chipsFor((C.alerts and C.alerts(m.id)) or {}, m) > 0 then chips_any = true end
    local c = L.vis[i] and cam_for(i, S) or cams[i]
    if L.vis[i] and c and c.node then
      local hov = hover_id == m.id
      if m.open then
        -- an open seat films the world: hovered at OPEN_HZ, otherwise slowly
        -- (a one-frame shot never drew: see OPEN_IDLE_HZ)
        set_cam(c, hov and OPEN_HZ or OPEN_IDLE_HZ, 4294967295 - INTERIOR_BIT - OFFSTAGE_BIT, true)
        cam_on(c, true)
      else
        set_cam(c, rateFor(i, nvis, hov), INTERIOR_BIT, false)
        -- while the seat view is up only its own room is drawn: a portrait
        -- from another room keeps its last picture
        local pc = ref("planet_camera")
        local sv = pc and pc.cockpit and pc.seatView
        cam_on(c, not (sv and not sv.open and sv.uid ~= m.uid))
      end
      if c.on and aim(c, v, m) then live = live + 1 end
    else
      -- scrolled out of view (or nobody there): not drawn at all
      cam_on(c, false)
    end
  end
  for i, c in pairs(cams) do if i > #list then cam_on(c, false) end end
  strip.shown, strip.live, strip.n = nvis, live, #list
  strip.overflow, strip.scroll, strip.maxScroll, strip.viewW = L.overflow, L.scroll, L.max_scroll, L.view_w
  strip.width, strip.cap, strip.visible = L.strip_w, maxW, L.visible
  ui.make(node, describe(v, list, L, afoot, chips_any, (maxW or 1e9) - 2 * CARD_PAD))
  lift_ops(node, true)
end

-- The Flight Ops card shares the bottom-left corner: while the strip shows,
-- the card stands on top of it (§4.4). status_hud.lua's layout pass does
-- that now (it owns every HUD block's place, and measures the strip in design
-- units: this converted with 720 and fell short at any interface size under
-- 100%, so "END FLIGHT" sat on the portraits — playtest dfb3e17). Two
-- writers on one posY is how that bug hid. Kept as a no-op for the callers.
function lift_ops(node, on) end
