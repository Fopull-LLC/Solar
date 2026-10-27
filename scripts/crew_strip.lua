-- CREW STRIP — live portraits of the crew aboard the craft you control,
-- bottom-left (docs/crew-and-items.md §4.4, §3.3).
--
--   ┌ CREW · Kestrel I · 3/3 ─────────────────────── ◂ 1/2 ▸ ┐
--   │ [live cam] [live cam] [live cam] [live cam]            │  128 × 96 (large: 256 × 192)
--   │  D.OKAFOR★   J.REYES    M.HALE     ...                 │  hover: [EVA] [⇄]
--   ├ ON FOOT ───────────────────────────────────────────────┤
--   │ [T.VANCE 42 m · CONTROL]  [R.ITO 310 m · CONTROL]      │  chips, no live cam
--   └────────────────────────────────────────────────────────┘
--
-- Portraits: at most 4 a page, each a UI image wearing `rt:crew<k>`, filmed by
-- a top-level camera ("Crew Cam <k>") set every lateUpdate 0.55 m in front of
-- the member's face in their seat, looking back at it, fovY 0.9. In a closed
-- part the camera draws only the `interior` layer (the room, iva.lua, and the
-- dolls); an open seat's rider needs the world, so only the HOVERED open-seat
-- portrait films (4 Hz) and the others keep their last picture.
--
-- Budget: 4 targets at 192 × 144 sharing RT_BUDGET redraws a second (the
-- design's 8 Hz each waits on engine card H1, see RT_BUDGET), hovered 6 Hz.
-- Hidden strip, the map, the builder, cinematic mode: the cameras are
-- disabled (a disabled camera is not drawn) and the images keep their frames.
--
-- `\` cycles small → large → hidden (saved: opt_crewStrip).
--
-- EVA from a portrait: crew.eva(id); with no RCS Pack in space it comes back
-- "confirm" and the warning is asked here, Cancel the default (Enter
-- cancels; "EVA anyway" must be clicked); after the third time a "don't ask
-- again this save" box appears (crew.evaNoAsk).
--
-- Pure layout (luajit, tests/smoke_crew_strip.lua): layout(n, page, size).

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

PER_PAGE = 4
SIZES = { small = { w = 128, h = 96, tw = 192, th = 144 }, large = { w = 256, h = 192, tw = 384, th = 288 } }
MODES = { "small", "large", "hidden" }
-- Measured on rc38 (tools/perf/ivaprobe.sh ivapod2, Medium, 1920×1052): a
-- portrait target pays for a whole scene render whatever its cullMask (the
-- sky, terrain, sun shadows and post run for it: engine card H1), ~7 ms a
-- redraw: three at 8 Hz cost 1.1 ms a frame, at 4 Hz 0.8 ms, against the
-- 0.6 ms budget; sharing 6 redraws a second measured 0.12–0.59 ms (noise
-- ±0.3 at load 4–9). Until H1 lands the portraits SHARE a redraw budget:
-- RT_BUDGET redraws a second across the page (each portrait RT_BUDGET / n,
-- staggered), the hovered one HOVER_HZ.
RT_BUDGET = 5.0
HZ_MIN = 1.2
HOVER_HZ, OPEN_HZ = 6.0, 4.0
function rateFor(k, n, hovered)
  if hovered then return HOVER_HZ end
  local hz = math.max(HZ_MIN, RT_BUDGET / math.max(1, n))
  return hz * (1.0 + 0.04 * ((k or 1) - 1))       -- staggered: never in step for long
end
CAM_DIST, CAM_FOV = 0.55, 0.9
GAP, PLATE_H = 6, 18
INTERIOR_BIT, OFFSTAGE_BIT = 16, 32

-- ── pure layout ────────────────────────────────────────────────────────────
-- n members aboard, page (1-based), size "small" | "large" → {
--   pages, page, first, last, shown = {i…}, w, h, strip_w, strip_h, paged }
function layout(n, page, size)
  local S = SIZES[size or "small"] or SIZES.small
  local pages = math.max(1, math.ceil((n or 0) / PER_PAGE))
  page = math.max(1, math.min(page or 1, pages))
  local first = (page - 1) * PER_PAGE + 1
  local last = math.min(n or 0, first + PER_PAGE - 1)
  local shown = {}
  for i = first, last do shown[#shown + 1] = i end
  local cols = math.max(1, #shown)
  return { pages = pages, page = page, first = first, last = last, shown = shown, w = S.w, h = S.h,
           tw = S.tw, th = S.th, paged = pages > 1,
           strip_w = cols * S.w + (cols - 1) * GAP + 16, strip_h = 22 + S.h + PLATE_H + 12 }
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
  return out
end

-- ── state ──────────────────────────────────────────────────────────────────
local el, host
local mode = "small"
local page = 1
local cams = {}           -- [k] = { node, making, target, hz, on, last_open }
local hover_id, hover_t = nil, -10
local confirm = nil       -- { id, warn, stay, t }
local msg, msg_t = nil, -10
strip = { shown = 0, live = 0 }   -- published for probes: portraits drawn, cameras live
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
                    active = false, cullMask = INTERIOR_BIT }
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

local function set_cam(c, hz, mask)
  if not (c and c.node and c.node.valid ~= false) then return end
  if c.hz ~= hz or c.mask ~= mask then
    pcall(function() c.node:setCamera { hz = hz, cullMask = mask } end)
    c.hz, c.mask = hz, mask
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
  local p = eye - back * CAM_DIST - up * 0.06
  c.node.pos = p
  c.node:lookAt(eye - up * 0.10, up)
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

local function portrait(i, m, L, live, hov, v)
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
  local tex = live and ("rt:crew" .. i) or nil
  local img = tex and { "image", key = "img" .. i, texture = tex, w = L.w, h = L.h, imageFit = "cover" }
    or { "box", key = "img" .. i, style = "hud/bezel", w = L.w, h = L.h }
  local chips = chipsFor(a, m)
  local col = { "col", key = "pt" .. i, style = "hud/chip", w = L.w + 4, h = "fit", gap = 1, pad = 2, align = "start",
                img, plate }
  if #chips > 0 then col[#col + 1] = chip_row("ch" .. i, chips) end
  return col
end

local function describe(v, list, L, afoot)
  local C = ref("crew")
  local rows = {}
  if v then
    local total = 0
    for _, s in ipairs((C and C.seatMap and C.seatMap(v)) or {}) do total = total + 1 end
    local head = { "row", key = "head", w = "fit", h = 18, gap = 8, pad = 0, align = "center",
                   { "text", key = "ht", style = "hud/micro", w = "fit", h = 18,
                     text = string.format("CREW · %s · %d/%d", tostring(v.craftName or "Craft"), #list, math.max(total, #list)) } }
    if L.paged then
      head[#head + 1] = { "button", key = "pgL", style = "hud/button", w = 20, h = 16, text = "◂", textAlign = "center",
                          onClicked = function() page = math.max(1, page - 1) end }
      head[#head + 1] = { "text", key = "pgN", style = "hud/micro", w = "fit", h = 16, text = L.page .. "/" .. L.pages }
      head[#head + 1] = { "button", key = "pgR", style = "hud/button", w = 20, h = 16, text = "▸", textAlign = "center",
                          onClicked = function() page = page + 1 end }
    end
    rows[#rows + 1] = head
    local prow = { "row", key = "ports", w = "fit", h = "fit", gap = GAP, pad = 0, align = "start" }
    for j, i in ipairs(L.shown) do
      local m = list[i]
      prow[#prow + 1] = portrait(j, m, L, true, hover_id == m.id, v)
    end
    if #L.shown == 0 then
      prow[#prow + 1] = { "text", key = "empty", style = "hud/micro", w = "fit", h = 18, text = "NOBODY ABOARD" }
    end
    rows[#rows + 1] = prow
  end
  if #afoot > 0 then
    rows[#rows + 1] = { "text", key = "afh", style = "hud/micro", w = "fit", h = 14, text = v and "ON FOOT" or "CREW" }
    local row = { "row", key = "afoot", w = "fit", h = "fit", gap = 4, pad = 0, align = "center" }
    for i, e in ipairs(afoot) do
      if i > 6 then break end
      row[#row + 1] = { "button", key = "af" .. i, style = "hud/button", w = "fit", h = 20,
                        text = e.label, textAlign = "center", onClicked = e.act }
    end
    rows[#rows + 1] = row
  end
  if confirm then
    local cf = confirm
    local asked = (save and save.get and save.get("crew.evaAsked")) or 0
    local box = { "col", key = "confirm", style = "hud/card", w = 360, h = "fit", gap = 6, pad = 8, align = "start",
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
    rows[#rows + 1] = { "text", key = "msg", style = "hud/chipWarnText", w = "fit", h = 16, text = msg }
  end
  local root = { "col", key = "strip", style = "hud/card", w = "fit", h = "fit", gap = 4, pad = 6, align = "start" }
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

function lateUpdate(node, dt)
  if not el then return end
  local C = ref("crew")
  local v = piloted()
  if mode == "hidden" or blocked() or not C then
    if el.visible then el.visible = false end
    all_off()
    strip.shown = 0
    lift_ops(node, false)
    return
  end
  local list = (v and C.aboard and C.aboard(v)) or {}
  local afoot = afoot_entries(v)
  if #list == 0 and #afoot == 0 and not confirm then
    if el.visible then el.visible = false end
    all_off()
    strip.shown = 0
    lift_ops(node, false)
    return
  end
  if not el.visible then el.visible = true end
  local L = layout(#list, page, mode)
  page = L.page
  local S = SIZES[mode] or SIZES.small
  -- hover: which portrait the pointer is over (its id), for EVA/⇄ and 15 Hz
  local hk = hovered_key("pt") or hovered_key("img") or hovered_key("pl") or hovered_key("eva") or hovered_key("mv")
    or hovered_key("nm")
  local hm = hk and L.shown[hk] and list[L.shown[hk]]
  if forced_hover then hover_id, hover_t = forced_hover, now()
  elseif hm then hover_id, hover_t = hm.id, now()
  elseif now() - hover_t > 0.3 then hover_id = nil end
  -- the interiors the portraits film
  local I = ref("iva")
  if v and I and I.need then I.need(v) end
  local live = 0
  for k = 1, PER_PAGE do
    local m = list[L.shown[k] or -1]
    local c = m and cam_for(k, S) or cams[k]
    if m and c and c.node then
      local hov = hover_id == m.id
      if m.open then
        -- an open seat films the world: only while hovered (the rest keep
        -- their last picture, which costs nothing)
        set_cam(c, OPEN_HZ, 4294967295 - INTERIOR_BIT - OFFSTAGE_BIT)
        cam_on(c, hov or c.last ~= m.id)
      else
        set_cam(c, rateFor(k, #L.shown, hov), INTERIOR_BIT)
        -- while the seat view is up only its own room is drawn: a portrait
        -- from another room keeps its last picture
        local pc = ref("planet_camera")
        local sv = pc and pc.cockpit and pc.seatView
        cam_on(c, not (sv and not sv.open and sv.uid ~= m.uid))
      end
      if c.on and aim(c, v, m) then live = live + 1 end
      c.last = m.id
    else
      cam_on(c, false)
    end
  end
  strip.shown, strip.live = #L.shown, live
  ui.make(node, describe(v, list, L, afoot))
  lift_ops(node, true)
end

-- The Flight Ops card shares the bottom-left corner: while the strip shows,
-- the card stands on top of it (§4.4), and goes back down when it hides.
local ops_el, ops_y0 = nil, nil
function lift_ops(node, on)
  if not (ops_el and ops_el.valid ~= false) then
    local n = find and find("Flight Ops")
    ops_el = n and n.getcomponent and n:getcomponent("UiElement") or nil
    if not ops_el then return end
    ops_y0 = ops_y0 or ops_el.posY or -16
  end
  local want = ops_y0
  if on and node.uiRect and camera and camera.screenSize then
    local _, _, _, h = node:uiRect()
    local _, sh = camera.screenSize()
    if h and sh and sh > 0 then want = ops_y0 - (h * 720 / sh + 8) end
  end
  if ops_el.posY ~= want then ops_el.posY = want end
end
