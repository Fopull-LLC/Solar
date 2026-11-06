-- TRACKING STATION — the orbit map's STATION mode: every craft, member, wreck,
-- relay, flag and structure of ours, on the live map, with the list, the card
-- and the clock beside it (docs/tracking-station.md).
--
-- One screen, two densities. `M` opens the map as a CHART (the legend, the
-- conics, the node: orbit_map.lua as it was); `F2` opens it as the STATION,
-- from anywhere — on foot, in flight, from the pause menu, or with E at the
-- dish (facility_menu). The STATION ▸ / CHART ▸ key on the top bar swaps
-- them. Nothing pauses: the stick, SAS and the walker's air keep running, and
-- the warp ladder is on the bottom strip.
--
--   ┌ top bar ── emblem · TRACKING STATION · agency · counts · [CHART|STATION] ✕ ┐
--   │ FLEET (left)          the live map (orbit_map.lua)            SELECTED (right) │
--   │  groups, rows                                                   the card       │
--   ├ NEXT (events, soonest first)                        WARP (rungs, clock) ───────┤
--
-- THE MAP PASS (drawMap, from orbit_map's lateUpdate, after the camera): an
-- icon by kind (fleet_view.GLYPHS) in a small enamel disc at every entry's
-- anchor, a name tag laid out by map_labels (priority, eight spots, a leader
-- line further out, tiers, a cap of 40, clusters of three or more within
-- 14 px), and the selected entry's orbit. ANCHORS ARE RE-PROJECTED EVERY
-- FRAME from this frame's single space.bodies() read (a live node's drawn
-- pose, or its body + its body-relative offset, carried along its conic);
-- only the tags' OFFSETS from their anchors are kept between layouts
-- (docs/positions-and-frames.md rules 1, 2 and 6).
--
-- THE PANELS are four scene nodes (Stretch layers, scenes/system.ron): this
-- one ("Tracking Station", the top bar), "Station Fleet", "Station Card" and
-- "Station Strip". Each is described only when what it shows changed, at
-- most a few times a second (the old panel re-made itself and read the whole
-- fleet every frame). Their rectangles go into the map's `blocked` list, so
-- no tag, icon or click lands under them (draw.* paints over the UI).
--
-- RECOVERY (below, unchanged): recoverRule / recoverCheck / recoverQuote /
-- recoverFleet — any craft at rest on a world with a tracking station,
-- distance-priced.
--
-- Cross-script: isOpen()  open({from})  close()  typing()  selectCraft(id)
--   selectedId()  renameFlag(id)  escape() → consumed  panelRects()
--   ownsPointer(mx, my)  pointerBusy()  drawMap(ctx)  anchorsNow()  labelsNow()
--   crewHome() → x, y, z (world, this tick)  stats (probe counters)

-- The WALL clock for the cost stats (os.clock is the process's CPU time: it
-- counts the engine's worker threads too; base_facilities does the same).
local function wall() return (app and app.wallClock and app.wallClock()) or os.clock() end
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

local function sfx(key)
  local s = ref("sfx")
  if s and s.play then pcall(s.play, key) end
end

-- ── state ───────────────────────────────────────────────────────────────────
local selected = nil          -- an entry id ("c3", "m:2", "b:1", …)
local hover = nil             -- the entry under the pointer (a row or an icon)
local hover_icon = nil        -- (the map's own, this frame)
local collapsed = { DEBRIS = true, STRUCTURES = true }
local msg, msg_t, msg_dur = "", -100, 6.0
local armed = nil             -- { id, t } TERMINATE / REMOVE waiting for its second press
local renaming = nil          -- an entry id being renamed
local base_rename, base_card  -- (deep-space step 7: a base's rename and card)
local rename_text = ""
local from_dish, opened_t = false, -10
local last_click = { id = nil, t = -10 }
stats = { lists = 0, cards = 0, strips = 0, tops = 0, layouts = 0, drawn = 0, tags = 0, ms = 0 }

local function say(text, dur) msg, msg_t, msg_dur = text or "", time or 0, dur or 6.0 end
local function now() return time or 0 end

function isOpen()
  local om = ref("orbit_map")
  return om ~= nil and om.isOpen ~= nil and om.isOpen() and om.mode == "station"
end
function typing() return renaming ~= nil end

-- Open the station (from the dish: `opts.from = "dish"`, so E closes it again).
function open(opts)
  local om = ref("orbit_map")
  if not (om and om.openStation) then return false end
  from_dish = (opts and opts.from == "dish") or false
  opened_t = now()
  armed, renaming = nil, nil
  local net = ref("comms")
  if net and net.refreshNow then pcall(net.refreshNow) end
  local fv = ref("fleet_view")
  if fv and fv.snapshot then fv.snapshot(true) end
  om.openStation()
  return true
end

function close()
  local om = ref("orbit_map")
  if isOpen() and om and om.close then om.close() end
  renaming, armed, from_dish = nil, nil, false
end

-- orbit_map tells us when the station mode starts or ends (any route).
function modeChanged(on)
  if not on then renaming, armed = nil, nil; if ui and ui.focus then pcall(ui.focus, nil) end end
  dirty_all = true
end

function selectCraft(id) selected = id; armed = nil; renaming = nil; dirty_all = true end
function selectedId() return selected end

-- deployables' right-click "Rename…" on a flag: the station on it, renaming.
function renameFlag(id)
  if not isOpen() then open() end
  selected = "f:" .. tostring(id)
  renaming = selected
  local dep = ref("deployables")
  local e = dep and dep.get and dep.get(id)
  rename_text = e and e.n or ""
  dirty_all = true
end

-- Esc, one rung at a time: the rename field, then the selection, then (false)
-- the station itself (orbit_map closes it).
function escape()
  if renaming then renaming = nil; dirty_all = true; if ui and ui.focus then pcall(ui.focus, nil) end return true end
  if armed then armed = nil; dirty_all = true return true end
  return false
end

-- E at the dish closes what the dish opened (not on the frame it opened).
function dishClose()
  return from_dish and now() > opened_t + 0.05
end

-- ── RECOVERY ────────────────────────────────────────────────────────────────
--
-- Any craft at rest (landed or splashed down) on a world with a Tracking
-- Station can be recovered from here, wherever on that world it is: the crew
-- come home to the base, the hardware is refunded, the cargo goes to the
-- warehouse, and the craft leaves the world and the save. Which worlds have a
-- station is base_facilities.trackingStationOn (today: the home world).
--
-- It used to need the craft within 260 m of the base — the same reach as
-- holding ENTER on landing — so anything that came down over the hill sat
-- greyed out for good. Now distance only costs money, as in KSP: the refund is
-- full near the base and falls off with the distance over the ground, down to
-- RECOVER_MIN of it on the far side of the world.
local RECOVER_NEAR = 260.0   -- m over the ground: still "at the base", full refund
local RECOVER_MIN = 0.25     -- the share of the refund left at the antipode
local RECOVER_RATE = 0.85    -- a pristine part's refund (vessel_controller's rate)
last_recovery = nil          -- published: the summary of the last recovery

-- The share of the refund paid for a craft `arc` metres over the ground from
-- the base, on a world of radius `radius`. Pure (smoke-tested).
function recoveryFactor(arc, radius)
  if not arc or arc <= RECOVER_NEAR then return 1.0 end
  local far = math.pi * (radius or 0)
  if far <= RECOVER_NEAR then return 1.0 end
  local k = (arc - RECOVER_NEAR) / (far - RECOVER_NEAR)
  return math.max(RECOVER_MIN, 1.0 - (1.0 - RECOVER_MIN) * math.min(1.0, k))
end

-- Can this board entry be recovered? Pure: `station_on(body)` answers whether
-- that world has a tracking station. Returns (ok, why-not).
--   e.rest      landed or splashed, and stopped
--   e.crewAway  the record says the crew is aboard but the craft isn't back in
--               the scene yet (they'd be recovered from nowhere)
function recoverRule(e, station_on)
  if not e or e.fid == "crew" then return false, "nothing to recover" end
  if not e.rest then
    local s = e.status or "in flight"
    if s == "landed" or s:match("^flying") then s = "in flight" end
    return false, s .. " — only a craft at rest on the ground or in the water can be recovered"
  end
  if not (station_on and station_on(e.body)) then
    return false, "not on a planet with a tracking station"
  end
  if e.crewAway then return false, "the crew is aboard and it's not back in the scene yet" end
  return true, nil
end

local function body_rel(bname, x, y, z)
  local b = bname and space.body(bname)
  if not b then return nil end
  return x - b.x, y - b.y, z - b.z, b
end

-- Is a live craft at rest? Landed (vessel_controller.parked: grounded and
-- stopped) or afloat and stopped.
local function live_rest(v)
  if v.parked and v.parked() then return true end
  local n = v.node
  local info = assembly and assembly.info and assembly.info(n)
  if not info then return false end
  local vel = info.vel
  local spd = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  if spd > 1.5 then return false end
  -- Frozen by the distant-craft LOD, a craft never reports grounded: stopped,
  -- with the ground right under its base, it is down.
  local o = info.origin
  local bname = o and space.dominant(o.x, o.y, o.z)
  local b = bname and space.body(bname)
  if o and b and spd < 0.2 and raycast then
    local ux, uy, uz = o.x - b.x, o.y - b.y, o.z - b.z
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ul > 1e-3 then
      ux, uy, uz = ux / ul, uy / ul, uz / ul
      local h = raycast(o.x + ux, o.y + uy, o.z + uz, -ux, -uy, -uz, 3.0, n)
      if h and h.distance <= 2.0 then return true end
    end
  end
  if water and water.at and vec3 then
    local w = water.at(vec3(n.x, n.y, n.z))
    if w and (w.depth or 0) > 0 then return true end
  end
  return false
end

-- The board entry, with what recovery needs to know added: at rest, where.
local function recover_view(e)
  if not e or e.fid == "crew" then return e end
  local fo = ref("flight_ops")
  local v = fo and fo.liveOf and fo.liveOf(e.fid)
  e.rest = e.landed == true
  if v and v.node and v.node.valid then
    if not e.rest then e.rest = live_rest(v) end
  else
    local f = save and save.get and save.get("fleet.craft")
    local rec = type(f) == "table" and f[e.fid] or nil
    if rec and rec.crew then e.crewAway = true end
  end
  return e
end

function recoverCheck(e)
  local bf = ref("base_facilities")
  return recoverRule(recover_view(e), function(body)
    return bf ~= nil and bf.trackingStationOn ~= nil and bf.trackingStationOn(body)
  end)
end

-- Where the craft is, body-relative, and how far that is over the ground from
-- the base. nil, nil when there is no base on its world.
local function ground_distance(e, v)
  local bf = ref("base_facilities")
  if not (bf and bf.sited and bf.baseBody == e.body) then return nil end
  local bx, by, bz, b = body_rel(e.body, bf.baseX, bf.baseY, bf.baseZ)
  if not bx then return nil end
  local cx, cy, cz
  if v and v.node and v.node.valid then
    cx, cy, cz = body_rel(e.body, v.node.x, v.node.y, v.node.z)
  else
    local f = save.get("fleet.craft")
    local rec = type(f) == "table" and f[e.fid] or nil
    if rec then cx, cy, cz = rec.x, rec.y, rec.z end
  end
  if not cx then return nil end
  local lb = math.sqrt(bx * bx + by * by + bz * bz)
  local lc = math.sqrt(cx * cx + cy * cy + cz * cz)
  if lb < 1e-6 or lc < 1e-6 then return nil end
  local c = math.max(-1, math.min(1, (bx * cx + by * cy + bz * cz) / (lb * lc)))
  return math.acos(c) * b.radius, b.radius
end

-- What the craft is worth back before distance: the controller's own figure
-- for a live craft (damage counted), the parts' list price for a saved one.
local function base_value(e, v)
  if v and v.recoverValue then return v.recoverValue() end
  local f = save.get("fleet.craft")
  local rec = type(f) == "table" and f[e.fid] or nil
  local sum = 0
  for _, d in ipairs((rec and rec.parts) or {}) do sum = sum + (tonumber(d.cost) or 0) end
  return math.floor(sum * RECOVER_RATE)
end

-- Where the crew is set down: a few metres short of the Tracking Station, on
-- the ground (flight_ops' own END FLIGHT spot).
local function crew_home()
  local bf = ref("base_facilities")
  if not (bf and bf.sited and bf.baseBody) then return nil end
  local b = space.body(bf.baseBody)
  if not b then return nil end
  local tx, ty, tz = bf.baseX, bf.baseY, bf.baseZ
  local dish = find("FacTracking") or find("FacCommand")
  if dish then
    local dx, dy, dz = dish.worldX, dish.worldY, dish.worldZ
    if not dx then  -- (planet-parented: its own coords are body-relative)
      dx, dy, dz = dish.x, dish.y, dish.z
      local p, guard = dish.parent, 0
      while p and guard < 8 do dx, dy, dz = dx + p.x, dy + p.y, dz + p.z; p, guard = p.parent, guard + 1 end
    end
    local vx, vy, vz = dx - tx, dy - ty, dz - tz
    local l = math.sqrt(vx * vx + vy * vy + vz * vz)
    if l > 11 then
      local k = (l - 11) / l
      tx, ty, tz = tx + vx * k, ty + vy * k, tz + vz * k
    end
  end
  local ux, uy, uz = tx - b.x, ty - b.y, tz - b.z
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  if ul < 1e-3 then return tx, ty + 2.0, tz end
  ux, uy, uz = ux / ul, uy / ul, uz / ul
  local h = raycast and raycast(tx + ux * 60, ty + uy * 60, tz + uz * 60, -ux, -uy, -uz, 130.0)
  if h then return h.x + ux * 1.6, h.y + uy * 1.6, h.z + uz * 1.6 end
  return tx + ux * 1.6, ty + uy * 1.6, tz + uz * 1.6
end

local function fmt_km(m)
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

-- What a recovery would pay now: { value, factor, dist, near }.
function recoverQuote(e)
  local fo = ref("flight_ops")
  local v = fo and fo.liveOf and fo.liveOf(e.fid)
  if v and not (v.node and v.node.valid) then v = nil end
  local arc, radius = ground_distance(e, v)
  local k = recoveryFactor(arc, radius)
  return { value = math.floor(base_value(e, v) * k + 0.5), factor = k, dist = arc or 0,
           near = arc == nil or arc <= RECOVER_NEAR }
end

-- RECOVER: refund, crew home, cargo to the warehouse, craft gone from the world
-- and the save. Returns (ok, summary-or-why).
function recoverFleet(fid)
  local fo, co = ref("flight_ops"), ref("company")
  if not fo then return false, "no flight ops" end
  local e
  for _, x in ipairs(fo.fleetList()) do if x.fid == fid then e = x end end
  if not e then return false, "no such craft" end
  local ok, why = recoverCheck(e)
  if not ok then return false, why end
  local v = fo.liveOf and fo.liveOf(fid)
  if v and not (v.node and v.node.valid) then v = nil end
  local q = recoverQuote(e)
  local arc, k, value = (not q.near) and q.dist or nil, q.factor, q.value
  local name = e.name or "the craft"
  local crew, cargo = false, 0
  if v then
    -- The crew come home to the base; whatever it carried goes to the warehouse.
    if v.crewAboard and v.standDown then
      local hx, hy, hz = crew_home()
      if hx then v.standDown(v.node, hx, hy, hz, 0, 0, 0) else v.standDown(v.node) end
      crew = true
    end
    local inv = ref("inventory")
    if inv and v.holdId and inv.isEmpty and not inv.isEmpty(v.holdId) then
      cargo = inv.transferAll(v.holdId, "base") or 0
    end
    if v.piloting and v.releaseControl then
      v.releaseControl()
      if v.controlFallback then v.controlFallback(v.node.id) end
    end
    if v.r2Cleanup then v.r2Cleanup() end
  end
  -- Off the board, out of the save, out of the world.
  local gone, gwhy = fo.terminateFleet(fid)
  if not gone then return false, gwhy end
  if co and co.earn and value > 0 then
    co.earn(value, string.format("recovered %s%s", name,
      arc and arc > RECOVER_NEAR and string.format(" (%s from the base, %d%%)", fmt_km(arc), math.floor(k * 100 + 0.5)) or ""))
  end
  save.set("mission.recovered", true)
  local fx = ref("sfx"); if fx and fx.flightEnded then fx.flightEnded("recover") end
  local money = (co and co.money) and co.money(value) or ("$" .. value)
  local parts = { string.format("Recovered %s: +%s", name, money) }
  if arc and arc > RECOVER_NEAR then
    parts[#parts + 1] = string.format("%d%% of its value, %s from the base", math.floor(k * 100 + 0.5), fmt_km(arc))
  else
    parts[#parts + 1] = "full value, at the base"
  end
  if crew then parts[#parts + 1] = "the crew are home" end
  if cargo > 0 then parts[#parts + 1] = string.format("%d cargo unit(s) to the warehouse", cargo) end
  local summary = table.concat(parts, " · ")
  last_recovery = { name = name, value = value, factor = k, dist = arc, crew = crew, cargo = cargo,
                    text = summary, t = time }
  log(string.format("RECOVERED (tracking station) — %s  +$%d  (%.0f%% at %s)", name, value, k * 100,
    arc and fmt_km(arc) or "?"))
  return true, summary
end

-- Where the crew of a recovered craft is set down, and where a member at the
-- base stands up when you switch to them: world, this tick (crew.lua asks
-- in its physics tick).
function crewHome() return crew_home() end

-- ── formatting ──────────────────────────────────────────────────────────────

local function fmt_alt(m)
  if not m then return "—" end
  if math.abs(m) < 0.5 then m = 0 end
  if math.abs(m) >= 1e6 then return string.format("%.0f km", m / 1000) end
  if math.abs(m) >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

local function bars_text(n)
  n = math.max(0, math.min(4, n or 0))
  return string.rep("▮", n) .. string.rep("▯", 4 - n)
end

local function money_of(co, v)
  return (co and co.money) and co.money(v) or ("$" .. tostring(v))
end

local function pct(f) return math.floor(math.max(0, math.min(1, f or 0)) * 100 + 0.5) end

-- Latitude and longitude of a body-relative point, as "12.3°N 45.6°E".
function latlon(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return "—" end
  local lat = math.deg(math.asin(math.max(-1, math.min(1, y / l))))
  local lon = math.deg(math.atan2(z, x))
  return string.format("%.1f°%s  %.1f°%s", math.abs(lat), lat >= 0 and "N" or "S", math.abs(lon), lon >= 0 and "E" or "W")
end

-- The palette (ui/solar.tokens.ron), for what draw.* paints on the map.
local C = {
  ink = { 0.92, 0.89, 0.81 }, soft = { 0.77, 0.75, 0.68 }, muted = { 0.56, 0.55, 0.50 },
  accent = { 0.97, 0.55, 0.22 }, warn = { 1.00, 0.80, 0.28 }, danger = { 0.97, 0.34, 0.25 },
  done = { 0.55, 0.85, 0.42 }, signal = { 0.66, 0.80, 0.86 }, plate = { 0.120, 0.124, 0.112 },
  lit = { 1.00, 0.80, 0.58 },
}

local function rim_of(e)
  if e.attn then return e.attn.level == "danger" and C.danger or C.warn end
  local k = e.kind
  if k == "debris" or k == "remains" then return C.muted end
  if k == "flag" then return C.accent end
  if k == "crew" or k == "structure" or k == "base" then return C.ink end
  if k == "relay" then return e.link and C.signal or C.danger end
  if e.craft then
    if e.link then return C.signal end
    return e.comms and C.danger or C.soft
  end
  return C.soft
end

-- ── the panels' geometry (design units; the layer is MatchHeight) ──────────
local M, TOP_H, FLEET_W, CARD_W, STRIP_H, MENU_RESERVE = 10, 44, 276, 312, 116, 132
local COL_Y = M + TOP_H + 6

local function screen()
  local sw, sh = 1280, 720
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then sw, sh = w, h end
  end
  local dh = uiDesignH()
  return sw, sh, dh, dh * sw / sh, sh / dh
end

local function col_h(dh) return math.max(160, dh - COL_Y - M - STRIP_H - 6) end

-- The four plates, in screen pixels (input.mouse()'s space): top bar, FLEET,
-- SELECTED, the bottom strip. Nothing of the map's lands under them.
function panelRects()
  if not isOpen() then return {} end
  local sw, sh, dh, dw, k = screen()
  local ch = col_h(dh)
  return {
    { M * k, M * k, (dw - 2 * M - MENU_RESERVE) * k, TOP_H * k, name = "top" },
    { M * k, COL_Y * k, FLEET_W * k, ch * k, name = "fleet" },
    { sw - (M + CARD_W) * k, COL_Y * k, CARD_W * k, ch * k, name = "card" },
    { M * k, sh - (M + STRIP_H) * k, sw - 2 * M * k, STRIP_H * k, name = "strip" },
  }
end

function ownsPointer(mx, my)
  if not isOpen() then return false end
  if not mx then mx, my = input.mouse() end
  for _, r in ipairs(panelRects()) do
    if mx >= r[1] and mx <= r[1] + r[3] and my >= r[2] and my <= r[2] + r[4] then return true end
  end
  return false
end
-- The map leaves the pointer alone (no node placed, no zoom) over a panel or
-- an icon of ours.
function pointerBusy() return isOpen() and (ownsPointer() or hover_icon ~= nil) end

-- ── the entries ─────────────────────────────────────────────────────────────

local function ema(k, v) stats[k] = (stats[k] or v) * 0.8 + v * 0.2 end
local function snap()
  local fv = ref("fleet_view")
  if not (fv and fv.snapshot) then return { version = 0, entries = {}, byId = {}, counts = {} } end
  local c0 = wall()
  local v0 = fv.current and fv.current().version
  local S = fv.snapshot()
  if S.version ~= v0 then ema("s_ms", (wall() - c0) * 1000) end
  return S
end

local function sel_entry(S)
  S = S or snap()
  local e = selected and S.byId[selected]
  if e then return e end
  -- nothing picked (or it is gone): the craft you fly, else you, else the first
  for _, x in ipairs(S.entries) do if x.piloted then selected = x.id return x end end
  for _, x in ipairs(S.entries) do if x.active then selected = x.id return x end end
  local x = S.entries[1]
  selected = x and x.id or nil
  return x
end

-- Where an entry is THIS frame: a live node's drawn pose, else its body (from
-- `B`, this frame's one space.bodies() read) plus its offset, carried along
-- its conic to `now` when it rides one. Never kept past the frame.
local n_prop = 0
CARRY_STEP = 1.0      -- game s between exact space.propagate steps for an offline orbit
local function anchor(e, B, now)
  local n = e.node
  if n and n.valid ~= false then return n.x, n.y, n.z end
  local b = e.body and B[e.body]
  if not (b and e.rx) then return nil end
  if e.conic and (b.mu or 0) > 0 and space.propagate then
    if e._pt ~= now then
      local h = (now or 0) - (e._et or -1e18)
      if e._et and h >= 0 and h <= CARRY_STEP then
        -- between exact steps, the second-order carry from the last one (the
        -- body-relative state there, its gravity): at ×1 the error over a
        -- step is millimetres; under warp the step comes round every frame
        local h2 = 0.5 * h * h
        e._px, e._py, e._pz = e._ex + e._evx * h + e._eax * h2, e._ey + e._evy * h + e._eay * h2, e._ez + e._evz * h + e._eaz * h2
        e._vx, e._vy, e._vz = e._evx + e._eax * h, e._evy + e._eay * h, e._evz + e._eaz * h
      else
        local dt = (now or 0) - (e.st or 0)
        local px, py, pz, vx, vy, vz = e.rx, e.ry, e.rz, e.vx or 0, e.vy or 0, e.vz or 0
        if dt ~= 0 and dt < 1e8 then
          n_prop = n_prop + 1
          px, py, pz, vx, vy, vz = space.propagate(e.rx, e.ry, e.rz, e.vx or 0, e.vy or 0, e.vz or 0, b.mu, dt)
        end
        e._px, e._py, e._pz, e._vx, e._vy, e._vz = px, py, pz, vx, vy, vz
        local r = math.sqrt(px * px + py * py + pz * pz)
        local k = r > 1e-6 and -b.mu / (r * r * r) or 0
        e._et, e._ex, e._ey, e._ez, e._evx, e._evy, e._evz = now, px, py, pz, vx, vy, vz
        e._eax, e._eay, e._eaz = px * k, py * k, pz * k
      end
      e._pt = now
    end
    if e._px then return b.x + e._px, b.y + e._py, b.z + e._pz end
  end
  return b.x + e.rx, b.y + e.ry, b.z + e.rz
end

-- The map eases its focus to the selection: this frame's point, from this
-- frame's read (orbit_map calls it with its own bodies list).
local function focus_point(bodies)
  local S = snap()
  local e = selected and S.byId[selected]
  if not e then return nil end
  local B = {}
  for _, b in ipairs(bodies or space.bodies()) do B[b.name] = b end
  local x, y, z = anchor(e, B, space.time())
  if not x and e.kind == "crew" and e.status == "base" then
    local fp = S.byId.base
    if fp then x, y, z = anchor(fp, B, space.time()) end
  end
  return x, y, z, e.name
end

local function focus_on(e, frame)
  local om = ref("orbit_map")
  if not (om and om.focusOn and e) then return end
  om.focusOn(focus_point)
  if frame and om.setZoom then
    local r = 400
    local b = e.body and space.body(e.body)
    if e.craft and not e.landed and e.ap and b then r = (e.ap + b.radius) * 2.6
    elseif e.craft and not e.landed and b then r = math.max(b.radius * 2.0, (e.alt or 0) * 4)
    elseif e.kind == "debris" and e.conic and b then r = b.radius * 3 end
    om.setZoom(r)
  end
end

local function pick(id, frame)
  if selected ~= id then sfx("click") end
  selected, armed, renaming = id, nil, nil
  dirty_all = true
  local S = snap()
  local e = S.byId[id]
  local t = now()
  local dbl = last_click.id == id and t - last_click.t < 0.4
  last_click = { id = id, t = t }
  focus_on(e, frame or dbl)
end

-- ── actions ─────────────────────────────────────────────────────────────────

local function close_for_action()
  close()
end

local function fly(e)
  local fo = ref("flight_ops")
  if not (fo and e and e.craft) then return end
  if not e.live and e.crewed then
    -- not back in the scene (another world, far off): travel to its crew
    local cr = ref("crew")
    local who = e.crew[1] and e.crew[1].id
    if cr and cr.switchToMember and who then
      local ok, why = cr.switchToMember(who)
      if ok then close_for_action() else say(why) end
    end
    return
  end
  local ok, why = fo.takeControlOf(e.id)
  if ok then sfx("click"); close_for_action() else say(why) end
end

local function fly_state(e, co)
  if not e.craft then return nil end
  if e.piloted then return "You're flying it", false end
  local f = e.fleet or {}
  if not e.live then
    if e.crewed then return "Fly  ·  travels there  ▸", true, "Not in the scene: the crew aboard is reached through the travel curtain (a few seconds)" end
    return "Not in the scene", false, string.format("It is %s, too far from you to be in the scene. Switch to someone near it.", e.sub or "far away")
  end
  if e.crewed then return "Fly as its crew  ▸", true end
  if f.pod and not f.crew and not f.probe and (f.fee or 0) > 0 then
    if co and co.afford and not co.afford(f.fee) then
      return string.format("Send the crew  ·  %s", money_of(co, f.fee)), false,
        string.format("The shuttle out to %s costs %s — more than the balance (%s). Recover or sell something first, or walk there.",
          e.name, money_of(co, f.fee), money_of(co, co.balance and co.balance() or 0))
    end
    return string.format("Send the crew  ·  %s  ▸", money_of(co, f.fee)), true
  end
  if f.pod and not f.crew and not f.probe then return "Send the crew  ▸", true end
  if not (f.probe or f.crew or f.pod) then return "Nothing aboard to fly", false end
  if f.probe and f.control == false then return "Fly  ▸", false, f.why end
  return "Fly  ▸", true
end

local function terminate(e)
  local fo, dep, dp = ref("flight_ops"), ref("deployables"), ref("debris_pack")
  local ok, why = false, "nothing to end"
  if e.craft and fo then ok, why = fo.terminateFleet(e.id)
  elseif e.kind == "flag" and dep and dep.remove then ok = dep.remove(e.flagId); why = ok and nil or "it would not come down"
  elseif e.kind == "debris" and dp and dp.forget and e.id:sub(1, 2) == "d:" then ok, why = dp.forget(e.id:sub(3))
  end
  if ok then say(e.name .. (e.craft and " written off" or " gone")); selected = nil else say(why) end
  dirty_all = true
end

local function target(e)
  local tg, fo = ref("targeting"), ref("flight_ops")
  if not tg then return end
  local ok, why
  if e.craft and e.live and fo and fo.liveOf then ok, why = tg.targetCraft(fo.liveOf(e.id))
  elseif e.kind == "body" then ok, why = tg.targetBody(e.name)
  else ok, why = false, "only a craft in the scene can be targeted" end
  if not ok then say(why) else sfx("click") end
end

local function plan(e)
  local om = ref("orbit_map")
  if om and om.setMode then
    om.setMode("chart")
    om.planning = true
  end
end

local function switch_to(id)
  local cr = ref("crew")
  if not (cr and cr.switchToMember) then return end
  local ok, why = cr.switchToMember(id)
  if ok then sfx("click"); close_for_action() else say(why) end
end

-- (a base, deep-space step 7: bases.rename, and the list picks the name up now)
base_rename = function(e, text)
  local B = ref("bases")
  if not B then return false, "no bases in this scene" end
  local ok, why = B.rename(e.baseId, text)
  local fv = ref("fleet_view")
  if ok and fv and fv.snapshot then fv.snapshot(true) end
  return ok, why
end
local function rename_submit(e, text)
  local fo, dep = ref("flight_ops"), ref("deployables")
  local ok, why
  if e.craft then ok, why = fo.renameFleet(e.id, text)
  elseif e.kind == "flag" then ok, why = dep.rename(e.flagId, text)
  elseif e.kind == "outpost" then ok, why = base_rename(e, text) end
  if ok then sfx("click"); renaming = nil; dirty_all = true else say(why) end
end

-- ── describing: small builders ──────────────────────────────────────────────

local function txt(key, style, text, extra)
  local t = { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function rule(key) return { "box", key = key, style = "panel/rule", w = "100%", h = 1 } end

local function key_btn(key, style, text, w, h, disabled, tip, fn, extra)
  local b = { "button", key = key, style = style, w = w or "grow", h = h or 30, text = text, textAlign = "center",
              textValign = "center", disabled = disabled or nil, tooltip = tip, onClicked = fn }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

-- A gauge: a dark groove and an ink bar (caution yellow under 10 %).
local function gauge(key, label, frac, value)
  local W = 120
  local warn = frac and frac < 0.10
  return { "row", key = key, w = "100%", h = 18, gap = 8, pad = 0, align = "center",
    { "text", key = "l", style = "panel/label", w = 48, h = "fit", text = label },
    { "row", key = "m", w = W, h = 6, radius = 1, pad = 0, gap = 0, fill = { 0.02, 0.03, 0.025 }, border = 1,
      borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(2, math.floor(W * math.max(0, math.min(1, frac or 0)) + 0.5)), h = 6, radius = 1,
        fill = warn and C.warn or C.soft } },
    { "text", key = "v", style = warn and "panel/hintWarn" or "panel/cell", w = "grow", h = "fit", maxLines = 1,
      overflow = "ellipsis", text = value } }
end

-- A CRT inset: live numbers in phosphor (ui-style §1.4).
local function crt(key, lines)
  local col = { "col", key = key, style = "hud/instrument", w = "100%", h = "fit", gap = 2, pad = 8, align = "start" }
  for i, l in ipairs(lines) do
    col[#col + 1] = { "text", key = "l" .. i, style = l.style or "hud/value", w = "100%", h = "fit", maxLines = 1,
                      overflow = "ellipsis", text = l.text or l }
  end
  return col
end

local function role_chip(key, letter)
  return { "text", key = key, style = "panel/role", w = 18, h = 18, text = letter or "?", textAlign = "center",
           textValign = "center", maxLines = 1 }
end

-- ── FLEET (left) ────────────────────────────────────────────────────────────
local ROW_CAP = 60    -- rows a group shows; the rest are "+N more" (P4: paging)

local function row_of(e)
  local E = ref("electronics")
  local right, style, color = "", "panel/cellMuted", nil
  if e.attn then
    right, color = e.attn.text, e.attn.level == "danger" and C.danger or C.warn
  elseif e.kind == "crew" then
    right = e.active and "YOU" or (e.num ~= "" and e.num or (e.role or ""))
  elseif e.craft or e.kind == "relay" then
    if e.link then right, style = bars_text(E and E.bars and E.bars(e.signal or 0) or 0), "panel/keys"
    elseif e.comms or e.kind == "relay" then right = "no link" end
    if e.recover and e.recover.ok then right = "↺ " .. right end
  end
  local active = e.piloted or e.active
  return { "button", key = "r" .. e.id, style = active and "panel/rowActive" or "panel/row",
    selected = selected == e.id, w = "100%", h = 34, dir = "row", gap = 6, align = "center",
    { "text", key = "g", style = "panel/cellStrong", w = 16, h = "fit", textAlign = "center", text = e.glyph,
      textColor = rim_of(e) },
    { "col", key = "nm", w = "grow", h = "fit", gap = 0, pad = 0,
      { "text", key = "t", style = "panel/cellStrong", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis",
        text = e.name or "?" },
      { "text", key = "s", style = "panel/cellMuted", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis",
        text = e.sub or "" } },
    { "text", key = "x", style = style, w = 76, h = "fit", textAlign = "end", maxLines = 1, overflow = "ellipsis",
      text = right, textColor = color },
    onClicked = function() pick(e.id) end }
end

-- What the list shows, as one string: re-made only when this changes (a new
-- snapshot with the same rows and words costs a string, not a ui.make).
local function list_sig(S)
  local parts = {}
  for _, e in ipairs(S.entries) do
    if not collapsed[e.group] or (selected and S.byId[selected] and S.byId[selected].group == e.group) then
      parts[#parts + 1] = e.id .. "\1" .. tostring(e.name) .. "\1" .. tostring(e.sub) .. "\1" .. tostring(e.attn and e.attn.text)
        .. "\1" .. tostring(e.link) .. tostring(e.recover and e.recover.ok) .. tostring(e.piloted or e.active)
    else
      parts[#parts + 1] = e.group
    end
  end
  return table.concat(parts, "\2")
end

local function describe_fleet(S, dh)
  local fv = ref("fleet_view")
  local groups, order = {}, {}
  for _, e in ipairs(S.entries) do
    local g = e.group or "STRUCTURES"
    if not groups[g] then groups[g] = {}; order[#order + 1] = g end
    local l = groups[g]
    l[#l + 1] = e
  end
  local rows = {}
  for _, g in ipairs((fv and fv.GROUPS) or order) do
    local l = groups[g]
    if l and #l > 0 then
      local shut = collapsed[g] and not (selected and S.byId[selected] and S.byId[selected].group == g)
      rows[#rows + 1] = { "button", key = "G" .. g, style = "panel/row", w = "100%", h = 22, dir = "row", gap = 6,
        align = "center", pad = 4,
        { "text", key = "a", style = "panel/label", w = 12, h = "fit", text = shut and "▸" or "▾" },
        { "text", key = "t", style = "panel/label", w = "grow", h = "fit", text = g,
          textColor = g == "ATTENTION" and C.warn or nil },
        { "text", key = "n", style = "panel/label", w = "fit", h = "fit", text = tostring(#l) },
        onClicked = function() collapsed[g] = not collapsed[g]; dirty_all = true end }
      if not shut then
        for i, e in ipairs(l) do
          if i > ROW_CAP then
            rows[#rows + 1] = { "text", key = "more" .. g, style = "panel/cellMuted", w = "100%", h = "fit",
              text = string.format("+%d more — the map has them all", #l - ROW_CAP) }
            break
          end
          rows[#rows + 1] = row_of(e)
        end
      end
    end
  end
  if #rows == 0 then
    rows[1] = txt("empty", "panel/body", "Nothing in the field yet. Anything you launch shows up here, and a probe can be flown from here for as long as it can hear the ground station.")
  end
  local h = col_h(dh)
  return { "col", key = "fleet", style = "panel/frame", pin = "topLeft", x = M, y = COL_Y, w = FLEET_W, h = h,
    gap = 6, pad = 12, align = "start",
    { "row", key = "hd", w = "100%", h = "fit", gap = 6, pad = 0, align = "center",
      { "text", key = "t", style = "panel/heading", w = "grow", h = "fit", text = "FLEET" },
      { "text", key = "n", style = "panel/cellMuted", w = "fit", h = "fit",
        text = string.format("%d craft · %d crew", S.counts.craft or 0, S.counts.crew or 0) } },
    rule("ru"),
    { "scroll", key = "listS", w = "100%", h = "grow", gap = 0, pad = 0, scrollFade = 12,
      { "col", key = "list", w = "100%", h = "fit", gap = 3, pad = 0, align = "start",
        items = rows, function(x) return x end } } }
end

-- ── SELECTED (right) ────────────────────────────────────────────────────────

local function live_numbers(e)
  -- the craft's own state now, for the inset (the snapshot is half a second old)
  local n = e.node
  local b = e.body and space.body(e.body)
  if not (b and n and n.valid ~= false and space.elements) then return e.alt, e.ap, e.pe end
  local alt = math.sqrt((n.x - b.x) ^ 2 + (n.y - b.y) ^ 2 + (n.z - b.z) ^ 2) - b.radius
  if e.landed then return alt, nil, nil end
  local o = space.elements(n.x, n.y, n.z, n.vx or 0, n.vy or 0, n.vz or 0)
  if not o then return alt, nil, nil end
  return alt, o.apoapsis and (o.apoapsis - b.radius) or nil, o.periapsis and (o.periapsis - b.radius) or nil
end

local function crew_rows(e, rows)
  local cr = ref("crew")
  if not (e.crew and #e.crew > 0) then return end
  rows[#rows + 1] = { "text", key = "crl", style = "panel/label", w = "100%", h = "fit",
    text = string.format("CREW %d", #e.crew) }
  for i, m in ipairs(e.crew) do
    local ok, why = false, nil
    if cr and cr.canSwitch then ok, why = cr.canSwitch(m.id) end
    rows[#rows + 1] = { "row", key = "cm" .. i, w = "100%", h = 24, gap = 6, pad = 0, align = "center",
      role_chip("r", m.role),
      { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", text = m.name or "?" },
      { "text", key = "s", style = (m.o2 or 1) < 0.25 and "panel/hintWarn" or "panel/cellMuted", w = 92, h = "fit",
        textAlign = "end", maxLines = 1, text = string.format("O2 %d %% · HP %d %%", pct(m.o2), pct(m.hp)) },
      key_btn("sw", "panel/secondary", "▸", 26, 22, not ok, ok and ("Switch to " .. (m.name or "them")) or why,
        function() switch_to(m.id) end) }
  end
end

local function recover_rows(e, rows, co)
  local r = e.recover
  if not r then return end
  if r.ok then
    local where = r.near and "at the base" or string.format("%d %% · %s from the base", pct(r.factor), fmt_alt(r.dist))
    rows[#rows + 1] = txt("recb", "panel/cellStrong", string.format("↺ RECOVERABLE  ·  +%s  ·  %s", money_of(co, r.value or 0), where),
      { textColor = C.done })
  else
    rows[#rows + 1] = txt("recb", "panel/hint", "✕ Not recoverable: " .. tostring(r.why or "—"))
  end
end

local function header(e, rows, can_rename)
  if renaming == e.id then
    rows[#rows + 1] = { "row", key = "ren", w = "100%", h = 32, gap = 6, pad = 0, align = "center",
      { "field", key = "f", style = "menu/field", w = "grow", h = 30, placeholder = e.name, maxLen = 32,
        onChanged = function(n) rename_text = n.text or "" end,
        onSubmitted = function(n) rename_submit(e, n.text or rename_text) end },
      key_btn("ok", "panel/action", "Save", 54, 30, false, nil, function() rename_submit(e, rename_text) end),
      key_btn("no", "panel/secondary", "✕", 30, 30, false, "Cancel", function() renaming = nil; dirty_all = true end) }
    return
  end
  rows[#rows + 1] = { "row", key = "hd", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
    { "text", key = "g", style = "panel/heading", w = 20, h = "fit", text = e.glyph, textColor = rim_of(e) },
    { "text", key = "nm", style = "panel/heading", w = "grow", h = "fit", wrap = true, text = e.name or "?" },
    can_rename and key_btn("rn", "panel/secondary", "Rename", 70, 24, false, nil, function()
      renaming, rename_text = e.id, e.name or ""; dirty_all = true end) or nil }
  rows[#rows + 1] = { "text", key = "sit", style = "panel/label", w = "100%", h = "fit", wrap = true, text = e.sub or "" }
end

local function armed_on(id) return armed and armed.id == id and now() < armed.t end

local function terminate_btn(e, label, tip)
  local a = armed_on(e.id)
  return key_btn("end", "panel/danger", a and "Confirm" or label, "grow", 30, e.crewed or e.piloted, tip,
    function()
      if armed_on(e.id) then armed = nil; terminate(e)
      else armed = { id = e.id, t = now() + 4.0 } end
      dirty_all = true
    end, { selected = a or nil })
end

local function card_craft(e, rows, co)
  header(e, rows, true)
  local alt, ap, pe = live_numbers(e)
  local lines = {}
  if e.landed then
    lines[1] = string.format("ALT %s   %s", fmt_alt(alt), e.homeWorld and e.dist and ("BASE " .. fmt_alt(e.dist)) or "")
  else
    lines[1] = string.format("ALT %s   AP %s   PE %s", fmt_alt(alt), ap and fmt_alt(ap) or "—", pe and fmt_alt(pe) or "—")
    local b = e.body and space.body(e.body)
    local fv = ref("fleet_view")
    local T = b and fv and fv.orbitTimes and fv.orbitTimes(e.rx, e.ry, e.rz, e.vx or 0, e.vy or 0, e.vz or 0, b.mu, b.radius)
    if T then
      local late = space.time() - (e.st or space.time())
      local function cd(t) return fv.clockText(((t or 0) - late) % (T.period or 1e12)) end
      lines[2] = string.format("INC %.1f°   %s", math.deg(T.inc or 0),
        T.tImpact and ("IMPACT " .. cd(T.tImpact)) or (T.tPe and ("PE " .. cd(T.tPe)) or ""))
      if T.period and not T.tImpact then lines[3] = string.format("PERIOD %s", (fv.clockText(T.period):gsub("^T−", ""))) end
    end
  end
  rows[#rows + 1] = crt("crt", lines)
  crew_rows(e, rows)
  rows[#rows + 1] = rule("r1")
  if (e.cap or 0) > 0 then
    rows[#rows + 1] = gauge("pwr", "POWER", e.charge / e.cap, string.format("%.0f / %.0f EC", e.charge or 0, e.cap))
  else
    rows[#rows + 1] = gauge("pwr", "POWER", 0, "no batteries")
  end
  if (e.fuelCap or 0) > 0 then
    rows[#rows + 1] = gauge("fuel", "FUEL", (e.fuel or 0) / e.fuelCap, string.format("%d %%", pct((e.fuel or 0) / e.fuelCap)))
  end
  local E = ref("electronics")
  if e.link then
    local path = (e.path and #e.path > 0) and table.concat(e.path, " → ") or "Ground station"
    rows[#rows + 1] = { "row", key = "lnk", w = "100%", h = "fit", gap = 8, pad = 0, align = "start",
      { "text", key = "l", style = "panel/label", w = 48, h = "fit", text = "LINK" },
      { "text", key = "v", style = "panel/cell", w = "grow", h = "fit", wrap = true,
        text = string.format("%s  %s · via %s", bars_text(E and E.bars and E.bars(e.signal or 0) or 0),
          (e.hops or 1) <= 1 and "direct" or string.format("%d hops", e.hops), path) } }
  else
    rows[#rows + 1] = { "row", key = "lnk", w = "100%", h = "fit", gap = 8, pad = 0, align = "start",
      { "text", key = "l", style = "panel/label", w = 48, h = "fit", text = "LINK" },
      { "text", key = "v", style = e.comms and "panel/hintWarn" or "panel/cellMuted", w = "grow", h = "fit", wrap = true,
        text = (e.fleet and e.fleet.linkWhy) or (e.comms and "NO PATH HOME" or "no antenna") } }
  end
  if e.attn then
    for i, a in ipairs(e.attn.all or {}) do
      rows[#rows + 1] = { "row", key = "at" .. i, style = "hud/chipWarn", w = "fit", h = 22, pad = 4, gap = 0, align = "center",
        { "text", key = "t", style = "hud/chipWarnText", w = "fit", h = "fit", text = a.text } }
    end
  end
  rows[#rows + 1] = rule("r2")
  recover_rows(e, rows, co)
  -- the keys
  local label, ok, why = fly_state(e, co)
  rows[#rows + 1] = key_btn("fly", "panel/action", label, "100%", 36, not ok, why, function() fly(e) end)
  if why and not ok then rows[#rows + 1] = txt("flywhy", "panel/hintWarn", why) end
  local r = e.recover or {}
  rows[#rows + 1] = { "row", key = "a1", w = "100%", h = 30, gap = 6, pad = 0,
    key_btn("rec", "panel/secondary", r.ok and ("Recover +" .. money_of(co, r.value or 0)) or "Recover", "grow", 30, not r.ok,
      r.ok and "The crew come home, the cargo goes to the warehouse, the hardware is refunded" or ("Recover: " .. tostring(r.why)),
      function()
        local ok2, w2 = recoverFleet(e.id)
        if ok2 then sfx("click"); say(w2, 15.0); selected = nil else say(w2) end
        local fv = ref("fleet_view")
        if fv and fv.forgetVerdicts then fv.forgetVerdicts() end
        if fv and fv.snapshot then fv.snapshot(true) end
        dirty_all = true
      end),
    key_btn("foc", "panel/secondary", "Focus", 64, 30, false, "Frame it on the map (double-click a row does too)",
      function() focus_on(e, true) end) }
  rows[#rows + 1] = { "row", key = "a2", w = "100%", h = 30, gap = 6, pad = 0,
    key_btn("tgt", "panel/secondary", "Target", "grow", 30, not (e.live and not e.piloted),
      e.live and "Set it as the target (SAS Target, closest approach)" or "Only a craft in the scene", function() target(e) end),
    key_btn("pln", "panel/secondary", "Plan", "grow", 30, not (e.piloted and not e.landed),
      e.piloted and "Plan a burn: back to the chart, in PLAN mode" or "Only for the craft you fly", function() plan(e) end),
    terminate_btn(e, "Terminate", "Write it off: gone from the world and the board, no refund. Twice to confirm.") }
  if armed_on(e.id) then rows[#rows + 1] = txt("warn", "panel/hintWarn", "Press again to write " .. e.name .. " off. It cannot be undone.") end
end

local function card_crew(e, rows)
  header(e, rows, false)
  local cr = ref("crew")
  local lines = { string.format("O2 %d %%   HP %d %%", pct(e.o2), pct(e.hp)) }
  local r = cr and cr.get and cr.get(e.member) or {}
  if (tonumber(r.dose) or 0) > 0.05 then lines[1] = lines[1] .. string.format("   DOSE %d %%", pct(r.dose)) end
  if e.status == "afoot" and e.dist then lines[2] = "FROM BASE " .. fmt_alt(e.dist) end
  rows[#rows + 1] = crt("crt", lines)
  rows[#rows + 1] = { "row", key = "rl", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
    role_chip("c", e.role),
    { "text", key = "t", style = "panel/cell", w = "grow", h = "fit", wrap = true,
      text = (cr and cr.roleName and cr.roleName(r) or "") .. (e.busy and (" · " .. e.busy) or "") } }
  if e.attn then
    rows[#rows + 1] = { "row", key = "at", style = "hud/chipWarn", w = "fit", h = 22, pad = 4, gap = 0, align = "center",
      { "text", key = "t", style = "hud/chipWarnText", w = "fit", h = "fit", text = e.attn.text } }
  end
  rows[#rows + 1] = rule("r2")
  local ok, why, mode, detail = false, "no crew library", nil, nil
  if cr and cr.canSwitch then ok, why, mode, detail = cr.canSwitch(e.member) end
  local label = "Switch to  ▸"
  if mode == "travel" then label = "Go to  ·  " .. tostring(detail or "far") .. "  ▸"
  elseif mode == "base" then label = "At base  ·  switch  ▸"
  elseif mode == "craft" then label = "Fly  ·  " .. tostring(detail or "their craft") .. "  ▸" end
  if e.active then
    rows[#rows + 1] = txt("you", "panel/cellMuted", "You are " .. tostring(e.name) .. ". Pick someone else to switch to them.")
  else
    rows[#rows + 1] = key_btn("sw", "panel/action", label, "100%", 36, not ok, why, function() switch_to(e.member) end)
  end
  if why and not ok and not e.active then rows[#rows + 1] = txt("swwhy", "panel/hint", why) end
  rows[#rows + 1] = { "row", key = "a1", w = "100%", h = 30, gap = 6, pad = 0,
    key_btn("foc", "panel/secondary", "Focus", "grow", 30, e.rx == nil and e.node == nil, nil, function() focus_on(e, true) end) }
end

-- A base's card (deep-space step 7, M5: base_tower.bases()): its tower's
-- tier and power, its link, its world's ground coverage, when it was founded.
base_card = function(e, rows)
  local b = e.outpost or {}
  local bt = ref("base_tower")
  local pw = bt and bt.power and e.baseId and bt.power(e.baseId) or b
  rows[#rows + 1] = txt("tw", pw.powered and "panel/keys" or "panel/cell", string.format("Tower: %s  ·  %.1f / %.1f EC/s from its pads",
    pw.powered and "a ground station" or "a mast", pw.supply or 0, pw.need or 2))
  if b.linked and (b.hops or 0) == 0 then
    rows[#rows + 1] = txt("sig", "panel/cellMuted", "A root of the network: craft that hear it are home.")
  elseif b.linked then
    rows[#rows + 1] = txt("sig", "panel/cellMuted", "Home via " .. table.concat(b.via or {}, " → "))
  else
    rows[#rows + 1] = txt("sig", "panel/hintWarn", tostring(b.why or "No path home"))
  end
  if b.coverage then rows[#rows + 1] = txt("cov", "panel/cellMuted", string.format("%s ground %d%% linked", e.body or "?", pct(b.coverage))) end
  if not pw.powered then
    rows[#rows + 1] = txt("ab", "panel/hint", "Stand a Solar Array or an Isotope Skid on its pads: 2 EC/s makes the tower a ground station.")
  end
  if e.date then rows[#rows + 1] = txt("by", "panel/cellMuted", "Founded " .. e.date) end
end

local function card_other(e, rows, co)
  local dep = ref("deployables")
  header(e, rows, e.kind == "flag" or e.kind == "outpost")
  local lines = {}
  if e.body and e.rx then lines[#lines + 1] = string.format("%s  %s", string.upper(e.body), latlon(e.rx, e.ry, e.rz)) end
  if e.dist then lines[#lines + 1] = "FROM BASE " .. fmt_alt(e.dist) end
  if #lines > 0 then rows[#rows + 1] = crt("crt", lines) end
  if e.kind == "relay" then
    if e.link then
      rows[#rows + 1] = txt("sig", "panel/cell", string.format("%s  ·  %s  ·  via %s", bars_text((ref("electronics") or {}).bars and ref("electronics").bars(e.signal or 0) or 0),
        (e.hops or 1) <= 1 and "direct" or string.format("%d hops", e.hops), (e.path and #e.path > 0) and table.concat(e.path, " → ") or "Ground station"))
    else
      rows[#rows + 1] = txt("sig", "panel/hintWarn", "No path home")
    end
    rows[#rows + 1] = txt("ab", "panel/hint", "A relay passes every signal it hears on toward home. Plant more to carry the network round the world; right-click one → Pick up to take it back.")
  elseif e.kind == "flag" then
    local tex = dep and dep.photoTex and dep.photoTex(e.flagId) or nil
    if tex then rows[#rows + 1] = { "image", key = "ph", w = CARD_W - 24, h = math.floor((CARD_W - 24) * 9 / 16), texture = tex, imageFit = "cover" } end
    rows[#rows + 1] = txt("by", "panel/cellMuted", string.format("Planted %s%s", e.date or "", dep and dep.memberName and e.flag and e.flag.by and (" by " .. tostring(dep.memberName(e.flag.by))) or ""))
  elseif e.kind == "debris" then
    rows[#rows + 1] = txt("ab", "panel/cellMuted", string.format("%s%s", e.parts and string.format("%d part%s · ", e.parts, e.parts == 1 and "" or "s") or "",
      e.dkind == "landed" and "down on the ground: salvage it where it lies" or (e.dkind == "orbit" and "on its own orbit" or "adrift")))
  elseif e.kind == "outpost" then
    base_card(e, rows)
  elseif e.kind == "structure" then
    rows[#rows + 1] = txt("ab", "panel/cellMuted", string.format("%d part%s%s", e.parts or 0, (e.parts or 0) == 1 and "" or "s", e.date and (" · founded " .. e.date) or ""))
  elseif e.kind == "base" then
    rows[#rows + 1] = txt("ab", "panel/cellMuted", "The agency's spaceport: the pad, the runway, the buildings and the ground station.")
  end
  rows[#rows + 1] = rule("r2")
  local acts = { "row", key = "a1", w = "100%", h = 30, gap = 6, pad = 0,
    key_btn("foc", "panel/secondary", "Focus", "grow", 30, false, nil, function() focus_on(e, true) end) }
  if e.kind == "flag" then acts[#acts + 1] = terminate_btn(e, "Remove", "Forget this flag: it comes down, and its photo goes. Twice to confirm.") end
  if e.kind == "debris" and e.id:sub(1, 2) == "d:" then acts[#acts + 1] = terminate_btn(e, "Forget", "Forget the piece: its record goes. Twice to confirm.") end
  rows[#rows + 1] = acts
  if armed_on(e.id) then rows[#rows + 1] = txt("warn", "panel/hintWarn", "Press again: it cannot be undone.") end
end

local function describe_card(S, dh)
  local co = ref("company")
  local e = sel_entry(S)
  local rows = {}
  rows[#rows + 1] = { "text", key = "ttl", style = "panel/label", w = "100%", h = "fit", text = "SELECTED" }
  if not e then
    rows[#rows + 1] = txt("none", "panel/body", "Click a row, or an icon on the map.")
  elseif e.craft then card_craft(e, rows, co)
  elseif e.kind == "crew" then card_crew(e, rows)
  else card_other(e, rows, co) end
  if msg ~= "" and now() - msg_t < msg_dur then rows[#rows + 1] = txt("msg", "panel/hintWarn", "» " .. msg) end
  return { "col", key = "card", style = "panel/frame", pin = "topRight", x = -M, y = COL_Y, w = CARD_W, h = col_h(dh),
    gap = 7, pad = 12, align = "start",
    { "scroll", key = "cs", w = "100%", h = "grow", gap = 0, pad = 0, scrollFade = 10,
      { "col", key = "c", w = "100%", h = "fit", gap = 7, pad = 0, align = "start", items = rows, function(x) return x end } } }
end

-- ── NEXT and WARP (bottom) ──────────────────────────────────────────────────
local RUNGS = { 1, 5, 10, 50, 100, 1000, 10000 }
local function rung_text(w) return w >= 1000 and string.format("%dk", math.floor(w / 1000)) or tostring(w) end

local function events(S)
  local fv, om, cr = ref("fleet_view"), ref("orbit_map"), ref("crew")
  if not (fv and fv.nextEvents) then return {} end
  local B = {}
  for _, b in ipairs(space.bodies()) do B[b.name] = b end
  local extra = {}
  local m = om and om.mnvState and om.mnvState()
  if m and m.lead and m.lead > 0 then
    local fl
    for _, e in ipairs(S.entries) do if e.piloted then fl = e end end
    extra[#extra + 1] = { t = m.lead, id = fl and fl.id, glyph = fl and fl.glyph or "◆", name = fl and fl.name or "your craft",
                          what = string.format("maneuver node · Δv %.0f m/s", m.dv or 0) }
  end
  if cr and cr.roster and cr.training then
    for _, r in ipairs(cr.roster()) do
      local tr = cr.training(r.id)
      if tr and tr.left and tr.left > 0 then
        extra[#extra + 1] = { t = tr.left, id = "m:" .. r.id, glyph = "◉", name = r.name,
                              what = "retrained as " .. tostring(cr.roleName and cr.roleName(tr.to) or tr.to) }
      end
    end
  end
  return fv.nextEvents(S.entries, space.time(), B, extra, 4)
end

local function clock_text()
  local dep = ref("deployables")
  local t = dep and dep.agencyClock and dep.agencyClock() or 0
  local d = dep and dep.dateOf and dep.dateOf(t) or ""
  local s = math.floor(t % 86400)
  return string.format("%s · %02d:%02d:%02d", d, math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

local function describe_strip(S, dw)
  local fv = ref("fleet_view")
  local ev = events(S)
  local lines = {}
  for i, x in ipairs(ev) do
    lines[#lines + 1] = { "button", key = "e" .. i, style = "crt/row", w = "100%", h = 18, dir = "row", gap = 8, pad = 2, align = "center",
      { "text", key = "t", style = "hud/value", w = 86, h = "fit", text = fv.clockText(x.t) },
      { "text", key = "n", style = "hud/value", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
        text = string.format("%s %s  ·  %s", x.glyph or "", x.name or "?", x.what or "") },
      onClicked = function() if x.id then pick(x.id, true) end end }
  end
  if #lines == 0 then lines[1] = { "text", key = "none", style = "hud/valueDim", w = "100%", h = "fit", text = "NO EVENTS AHEAD" } end
  local w = space.warp and space.warp() or 1
  local wc = ref("warp_chip")
  local cap = wc and wc.capNow and wc.capNow() or math.huge
  local rungs = { "row", key = "rg", w = "100%", h = 26, gap = 3, pad = 0, align = "center" }
  for i, r in ipairs(RUNGS) do
    rungs[#rungs + 1] = key_btn("w" .. i, "panel/choice", i == 1 and "■ 1" or rung_text(r), i == 1 and 44 or "grow", 26,
      r > cap + 0.001, r > cap + 0.001 and "Limited out here" or ("Time warp ×" .. r),
      function()
        if wc and wc.request then
          local ok, why = wc.request(r)
          if not ok and why then say(why) end
        elseif space.warp then space.warp(r) end
        dirty_all = true
      end, { selected = math.abs(w - r) < 0.5 or nil })
  end
  local hint = (msg ~= "" and now() - msg_t < msg_dur) and ("» " .. msg)
    or "Right-drag turn · Ctrl pan · scroll zoom · Tab next world · click a row or an icon · double-click frames it · , . warp · F2 / M / Esc close"
  return { "row", key = "strip", style = "panel/frame", pin = "bottom", y = -M, w = dw - 2 * M, h = STRIP_H, gap = 14, pad = 10, align = "start",
    { "col", key = "next", w = "grow", h = "100%", gap = 4, pad = 0, align = "start",
      { "text", key = "l", style = "panel/label", w = "100%", h = "fit", text = "NEXT" },
      { "col", key = "ev", style = "hud/instrument", w = "100%", h = "grow", gap = 1, pad = 5, align = "start",
        items = lines, function(x) return x end } },
    { "col", key = "warp", w = 430, h = "100%", gap = 4, pad = 0, align = "start",
      { "row", key = "wh", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
        { "text", key = "l", style = "panel/label", w = "grow", h = "fit", text = "WARP" },
        { "row", key = "ro", style = "hud/instrument", w = "fit", h = 22, gap = 10, pad = 4, align = "center",
          { "text", key = "x", style = "hud/valueAccent", w = 54, h = "fit", textAlign = "end", text = string.format("×%d", math.floor(w + 0.5)) },
          { "text", key = "c", style = "hud/value", w = "fit", h = "fit", text = clock_text() } } },
      rungs,
      { "text", key = "h", style = (msg ~= "" and now() - msg_t < msg_dur) and "panel/hintWarn" or "panel/hint",
        w = "100%", h = "fit", wrap = true, maxLines = 2, text = hint } } }
end

-- ── the top bar ─────────────────────────────────────────────────────────────

local function describe_top(S, dw)
  local em = ref("emblem")
  local etex = em and em.tex and em.tex() or nil
  local aname = em and em.name and em.name() or ""
  local net = ref("comms")
  local bf = ref("base_facilities")
  local home = bf and bf.baseBody
  local cov = (home and net and net.coverage) and net.coverage(home) or nil
  local c = S.counts or {}
  local counts = string.format("%d craft · %d in contact · %d relay%s · %d debris%s%s", c.craft or 0, c.linked or 0,
    c.relays or 0, (c.relays or 0) == 1 and "" or "s", c.debris or 0,
    cov and string.format(" · %s ground %d %%", home, pct(cov.ground)) or "",
    (c.attention or 0) > 0 and string.format(" · %d need attention", c.attention) or "")
  local om = ref("orbit_map")
  return { "row", key = "top", style = "panel/frame", pin = "topLeft", x = M, y = M, w = dw - 2 * M - MENU_RESERVE, h = TOP_H,
    gap = 10, pad = 8, align = "center",
    { "image", key = "emb", w = 28, h = 28, texture = etex or "textures/parts/emblem_default.png", imageFit = "contain" },
    { "text", key = "t", style = "panel/heading", w = "fit", h = "fit", text = "TRACKING STATION" },
    { "text", key = "ag", style = "panel/cellMuted", w = "fit", maxW = 220, h = "fit", maxLines = 1, overflow = "ellipsis", text = aname },
    { "text", key = "n", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis", textAlign = "end", text = counts },
    { "row", key = "mode", w = "fit", h = 28, gap = 2, pad = 0, align = "center",
      key_btn("chart", "panel/choice", "Chart", 64, 26, false, "The orbit map with its legend (M)",
        function() if om and om.setMode then om.setMode("chart") end end),
      key_btn("station", "panel/choice", "Station", 70, 26, false, "This screen (F2)", function() end, { selected = true }) },
    key_btn("x", "panel/secondary", "✕", 30, 26, false, "Close (F2, M or Esc)", function() close() end) }
end

-- ── the driver: each panel described only when it changed ──────────────────
local nodes = {}
local function node_of(name)
  local n = nodes[name]
  if not (n and n.valid ~= false) then
    n = find and find(name) or nil
    nodes[name] = n
  end
  return n
end
local shown = false
local last = { list = nil, card = -10, strip = -10, top = -10 }
dirty_all = true

local function show(on)
  for _, nm in ipairs({ "Tracking Station", "Station Fleet", "Station Card", "Station Strip" }) do
    local n = node_of(nm)
    local el = n and n:getcomponent("UiElement")
    if el and el.visible ~= on then el.visible = on end
    if n and not on and ui and ui.make then ui.make(n, {}) end
  end
  shown = on
end

function start(node)
  local el = node.getcomponent and node:getcomponent("UiElement")
  if el then el.visible = false end
  nodes["Tracking Station"] = node
  if spawn and findScript then
    if not findScript("emblem") then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
    if not findScript("deployables") then pcall(spawn, "DeployLib", vec3(0, 0, 0)) end
  end
end

-- (the row under the pointer: its key is its node's name)
local function hovered_row(S)
  if not (ui and ui.hovered) then return nil end
  local h = ui.hovered()
  if not h then return nil end
  local nm = h.name
  for _ = 1, 3 do
    if type(nm) == "string" and nm:sub(1, 1) == "r" and nm:len() > 1 then
      local id = nm:sub(2)
      if S.byId[id] then return id end
    end
    h = h and h.parent
    nm = h and h.name
  end
  return nil
end

local function update_body(node, dt)
  local open_now = isOpen()
  if not open_now then
    if shown then show(false) end
    hover, hover_icon = nil, nil
    return
  end
  if not shown then show(true); dirty_all = true end
  local S = snap()
  local sw, sh, dh, dw = screen()
  local t = now()
  local hv = hovered_row(S) or hover_icon
  if hv ~= hover then hover = hv end
  if S.version ~= last.sv or dirty_all then last.sig, last.sv = list_sig(S), S.version end
  local list_key = table.concat({ last.sig or "", tostring(selected), math.floor(dh), math.floor(dw) }, "|")
  local any = dirty_all
  if any or list_key ~= last.list then
    local n = node_of("Station Fleet")
    local c0 = wall()
    if n then ui.make(n, { "box", key = "root", pin = "center", w = "100%", h = "100%", describe_fleet(S, dh) }) end
    ema("list_ms", (wall() - c0) * 1000)
    last.list = list_key
    stats.lists = stats.lists + 1
  end
  if any or t - last.card >= 0.2 then
    local n = node_of("Station Card")
    local c0 = wall()
    if n then ui.make(n, { "box", key = "root", pin = "center", w = "100%", h = "100%", describe_card(S, dh) }) end
    ema("card_ms", (wall() - c0) * 1000)
    last.card = t
    stats.cards = stats.cards + 1
  end
  if any or t - last.strip >= 0.25 then
    local n = node_of("Station Strip")
    local c0 = wall()
    if n then ui.make(n, { "box", key = "root", pin = "center", w = "100%", h = "100%", describe_strip(S, dw) }) end
    ema("strip_ms", (wall() - c0) * 1000)
    last.strip = t
    stats.strips = stats.strips + 1
  end
  if any or t - last.top >= 0.5 then
    local c0 = wall()
    ui.make(node, { "box", key = "root", pin = "center", w = "100%", h = "100%", describe_top(S, dw) })
    ema("top_ms", (wall() - c0) * 1000)
    last.top = t
    stats.tops = stats.tops + 1
  end
  dirty_all = false
  -- E at the dish closes what the dish opened
  if from_dish and not typing() and (input.pressed("e") or input.pressed("enter")) and dishClose() then close() end
end

function update(node, dt)
  local u0 = wall()
  update_body(node, dt)
  if shown then ema("u_ms", (wall() - u0) * 1000) end
end

-- ── THE MAP PASS ────────────────────────────────────────────────────────────
local ML_ref = nil
local LAY = { key = nil, t = -10, placed = {}, clusters = {}, member = {} }
local anchors_now, labels_now = {}, {}
local lmb_was = false

local function name_w(text, fs)
  local _, n = tostring(text):gsub("[^\128-\191]", "")
  return n * fs * 0.56 + fs
end

local function inside(rects, x, y, pad)
  pad = pad or 0
  for _, r in ipairs(rects) do
    if x >= r[1] - pad and x <= r[1] + r[3] + pad and y >= r[2] - pad and y <= r[2] + r[4] + pad then return true end
  end
  return false
end

local function line2(e)
  local parts = { e.sub }
  if e.num and e.num ~= "" then parts[#parts + 1] = e.num end
  if e.crewed and e.crew then
    local s = ""
    for _, m in ipairs(e.crew) do s = s .. (m.role or "") end
    if s ~= "" then parts[#parts + 1] = s end
  end
  if e.recover and e.recover.ok then parts[#parts + 1] = "↺ +$" .. tostring(e.recover.value or 0) end
  if e.attn then parts[#parts + 1] = e.attn.text end
  return table.concat(parts, "  ·  ")
end

local function tag(x, y, w, h, l1, l2, fs, hi)
  draw.rect(x - 1, y - 1, w + 2, h + 2, 0.0, 0.0, 0.0, 0.72, fs * 0.15)
  draw.rect(x, y, w, h, C.plate[1], C.plate[2], C.plate[3], 0.9, fs * 0.12)
  if hi then draw.rectOutline(x - 1, y - 1, w + 2, h + 2, C.accent[1], C.accent[2], C.accent[3], 0.9, 1) end
  local cx = x + w / 2
  draw.text(cx, y + fs * 0.12, l1, fs, C.ink[1], C.ink[2], C.ink[3], 1.0, "center", "fonts/SolarLabel.ttf")
  if l2 then
    local f2 = fs * 0.78
    draw.text(cx, y + fs * 1.32, l2, f2, C.soft[1], C.soft[2], C.soft[3], 1.0, "center", "fonts/SolarLabel.ttf")
  end
end

-- One frame of the station on the map. ctx (from orbit_map, this frame):
--   bodies (the one space.bodies() read), px_at, ppu(d), cam {x,y,z}, lk,
--   sw, sh, placed (the worlds' names already drawn), blocked (the HUD's),
--   yaw, pitch, show, drawTrack, TRAJ, label, cine
function drawMap(ctx)
  local t0 = wall()
  if not isOpen() then return end
  local ML = ML_ref
  if not (ML and ML.valid ~= false) then ML = ref("map_labels"); ML_ref = ML end
  local S = snap()
  local B = {}
  for _, b in ipairs(ctx.bodies) do B[b.name] = b end
  local tnow = space.time()
  local sw, sh, k = ctx.sw, ctx.sh, ctx.lk or 1
  local blocked = {}
  for _, r in ipairs(panelRects()) do blocked[#blocked + 1] = r end
  for _, r in ipairs(ctx.blocked or {}) do blocked[#blocked + 1] = r end
  local cam = ctx.cam
  local function cdist(x, y, z) return math.max(1e-3, math.sqrt((x - cam.x) ^ 2 + (y - cam.y) ^ 2 + (z - cam.z) ^ 2)) end
  local disc = {}
  for _, b in ipairs(ctx.bodies) do disc[b.name] = b.radius * ctx.ppu(cdist(b.x, b.y, b.z)) end
  local pts, by = {}, {}
  anchors_now = {}
  n_prop = 0
  local n_proj = 0
  local mx, my = input.mouse()
  -- conics of the craft that are not in the scene (the live ones are the map's own)
  local sel = selected and S.byId[selected]
  -- A layout this frame projects everything; between layouts a cluster's
  -- members are only needed for the disc's place, so three of each will do
  -- (a crowd of 200 debris costs a dozen projections, not 200).
  local rt = now()
  -- (a view that turns or zooms is laid out four times a second, a still one
  -- twice: the offsets ride their anchors in between)
  local vkey = ML and ML.key(ctx.ppuFocus, ctx.yaw, ctx.pitch, nil, nil, 0, 0, sw, sh, uiDesignH()) or ""
  local moving = vkey ~= LAY.vkey
  local relayout = ML ~= nil and (selected ~= LAY.sel or hover ~= LAY.hov or S.version ~= LAY.sv and rt - LAY.t >= 0.25
    or rt - LAY.t >= (moving and 0.25 or 0.5))
  local per_cluster = {}
  for _, e in ipairs(S.entries) do
    local skip = false
    if not relayout then
      local c = LAY.member[e.id]
      if c then
        skip = c.seed ~= nil and c.seed.id ~= e.id and not e.craft   -- (a craft still draws its conic)
      end
    end
    local x, y, z
    if not skip then x, y, z = anchor(e, B, tnow) end
    if x then
      local keep = e.id == selected
      if keep or (disc[e.body] or 99) >= 2 then
        n_proj = n_proj + 1
        local sx, sy, _, on = camera.worldToScreen(x, y, z)
        if on then
          anchors_now[e.id] = { sx, sy, x, y, z }
          if not inside(blocked, sx, sy, 4) then
            local p = { id = e.id, x = sx, y = sy, prio = e.prio + (keep and 100 or 0) + (e.id == hover and 60 or 0), kind = e.kind, e = e }
            pts[#pts + 1] = p
            by[e.id] = p
          end
        end
      end
      if e.craft and not e.live and not e.landed and ctx.drawTrack and ctx.TRAJ and ctx.show.orbits then
        local b = B[e.body]
        if b then
          local rx, ry, rz = (e._px or e.rx), (e._py or e.ry), (e._pz or e.rz)
          local vx, vy, vz = (e._vx or e.vx or 0), (e._vy or e.vy or 0), (e._vz or e.vz or 0)
          local tr = ctx.TRAJ.track(rx, ry, rz, vx, vy, vz, b.mu, b.radius, b.soi, false)
          ctx.drawTrack(tr, b, e.id == selected, ctx.px_at, e.id == selected and ctx.label or nil, k, ctx.show, e.name)
        end
      end
    end
  end
  if ctx.cine then stats.ms = (wall() - t0) * 1000 return end
  ema("a_ms", (wall() - t0) * 1000)
  stats.n_proj, stats.n_prop = n_proj, n_prop
  -- the layout: when the view, the selection or the snapshot changed, or four times a second
  local key = ML and ML.key(ctx.ppuFocus, ctx.yaw, ctx.pitch, selected, hover, S.version, 0, sw, sh, uiDesignH()) or ""
  local R = 7 * k
  local fs = 12 * k
  local l0 = wall()
  if relayout then
    local keep = {}
    if selected then keep[selected] = true end
    if hover then keep[hover] = true end
    local clusters, member = ML.cluster(pts, 14 * k, 3, keep)
    local items, icons = {}, {}
    for _, p in ipairs(pts) do
      if not member[p.id] then
        local e = p.e
        local r = e.kind == "debris" and 3 * k or R
        icons[#icons + 1] = { p.x, p.y, r + 1, id = p.id }
        local w1 = name_w(e.name, fs) + 4
        local tiers
        if e.kind == "debris" and p.id ~= selected and p.id ~= hover then
          tiers = {}
        elseif p.id == selected or p.id == hover or e.attn then
          local l2 = line2(e)
          local w2 = math.max(w1, name_w(l2, fs * 0.78) + 6)
          tiers = { { w2, fs * 2.35 }, { w1, fs * 1.4 } }
        else
          tiers = { { w1, fs * 1.4 } }
        end
        items[#items + 1] = { id = p.id, x = p.x, y = p.y, r = r, prio = p.prio, tiers = tiers,
                              force = p.id == selected or p.id == hover }
      end
    end
    for _, c in ipairs(clusters) do icons[#icons + 1] = { c.x, c.y, 10 * k } end
    local pre = {}
    for _, q in ipairs(ctx.placed or {}) do pre[#pre + 1] = { q[1] - q[3] / 2, q[2] - q[4] / 2, q[3], q[4] } end
    local placed = ML.layout(items, { blocked = blocked, pre = pre, icons = icons, sw = sw, sh = sh, cap = 40 })
    local cl = {}
    -- (each disc's offset from its seed, kept in SCREEN space until the next
    -- layout: only the seed is projected in between)
    for _, c in ipairs(clusters) do
      cl[#cl + 1] = { id = c.id, members = c.members, seed = c.seed.id, kind = c.kind, ox = c.x - c.seed.x, oy = c.y - c.seed.y,
                      n = c.n }
    end
    LAY = { key = key, t = rt, placed = placed, clusters = cl, member = member, sel = selected, hov = hover, vkey = vkey,
            sv = S.version }
    stats.layouts = stats.layouts + 1
    ema("l_ms", (wall() - l0) * 1000)
  end
  -- hover and click on the map (not over a panel, not while the view turns)
  local over_panel = inside(panelRects(), mx, my, 0)
  local best, bd = nil, (R + 5) ^ 2
  local cl_hover = nil
  if not over_panel then
    for _, p in ipairs(pts) do
      if not LAY.member[p.id] then
        local d = (p.x - mx) ^ 2 + (p.y - my) ^ 2
        if d < bd then best, bd = p.id, d end
      end
    end
  end
  -- clusters, at the mean of where their members are THIS frame
  local cdraw = {}
  for _, c in ipairs(LAY.clusters) do
    local sp = by[c.seed]
    if sp then
      local cc = { x = sp.x + (c.ox or 0), y = sp.y + (c.oy or 0), n = c.n or #c.members, c = c }
      cdraw[#cdraw + 1] = cc
      if not over_panel and not best and (cc.x - mx) ^ 2 + (cc.y - my) ^ 2 < (12 * k) ^ 2 then cl_hover = cc end
    end
  end
  hover_icon = best or (cl_hover and cl_hover.c.seed) or nil
  local lmb = input.button(0) == true
  if lmb and not lmb_was and not over_panel and not ctx.busy then
    if best then pick(best)
    elseif cl_hover then pick(cl_hover.c.seed, false) end
  end
  lmb_was = lmb
  -- draw: icons (debris small and muted), clusters, then the tags over them
  local d0 = wall()
  local drawn = 0
  local font = "fonts/SolarLabel.ttf"
  for _, p in ipairs(pts) do
    if not LAY.member[p.id] then
      local e = p.e
      local col = rim_of(e)
      if e.kind == "debris" and p.id ~= selected and p.id ~= hover then
        local s = 2.2 * k
        draw.rect(p.x - s, p.y - s, s * 2, s * 2, col[1], col[2], col[3], 0.75)
      else
        -- (the dark enamel disc always — it is what makes a glyph read over a
        -- lit world; the rim only where it says something: the selection,
        -- the hovered, an alert, the craft you fly. The glyph wears the state.)
        draw.circle(p.x, p.y, R, 0.07, 0.075, 0.068, 0.92)
        if p.id == selected or p.id == hover or e.attn or e.piloted or e.active or e.kind == "crew" then
          draw.circleOutline(p.x, p.y, R, col[1], col[2], col[3], 1.0, math.max(1, 1.3 * k))
        end
        draw.text(p.x, p.y - fs * 0.62, e.glyph, fs, col[1], col[2], col[3], 1.0, "center", font)
      end
      if p.id == selected then
        draw.circleOutline(p.x, p.y, R + 4 * k, C.accent[1], C.accent[2], C.accent[3], 1.0, math.max(1, 1.6 * k))
      elseif p.id == hover then
        draw.circleOutline(p.x, p.y, R + 3 * k, C.lit[1], C.lit[2], C.lit[3], 0.8, 1)
      end
      if (e.piloted or e.active) and p.id ~= selected then
        draw.circle(p.x + R * 0.8, p.y - R * 0.8, 2.2 * k, C.accent[1], C.accent[2], C.accent[3], 1.0)
      end
      drawn = drawn + 1
    end
  end
  for _, cc in ipairs(cdraw) do
    local col = rim_of({ kind = cc.c.kind })
    local r = 10 * k
    draw.circle(cc.x, cc.y, r, 0.07, 0.075, 0.068, 0.92)
    draw.circleOutline(cc.x, cc.y, r, col[1], col[2], col[3], 1.0, math.max(1, 1.3 * k))
    draw.text(cc.x, cc.y - fs * 0.62, tostring(cc.n), fs, C.ink[1], C.ink[2], C.ink[3], 1.0, "center", font)
  end
  -- the hovered cluster fans its names out in a column beside it
  if cl_hover then
    local x0, y0 = cl_hover.x + 14 * k, cl_hover.y - fs
    for i, id in ipairs(cl_hover.c.members) do
      if i > 8 then
        tag(x0, y0, name_w("…", fs), fs * 1.4, string.format("+%d more", #cl_hover.c.members - 8), nil, fs)
        break
      end
      local e = S.byId[id]
      if e then
        local w = name_w(e.glyph .. " " .. e.name, fs) + 4
        tag(x0, y0, w, fs * 1.4, e.glyph .. " " .. e.name, nil, fs)
        y0 = y0 + fs * 1.55
      end
    end
  end
  labels_now = {}
  local ntag = 0
  local tagged = {}
  for _, p in ipairs(pts) do
    local pl = LAY.placed[p.id]
    if pl and pl.tier and pl.tier > 0 and not LAY.member[p.id] then tagged[#tagged + 1] = p end
  end
  table.sort(tagged, function(a, b) return a.prio > b.prio end)
  local drawn_r = {}
  for _, p in ipairs(tagged) do
    local pl = LAY.placed[p.id]
    do
      local x, y = p.x + pl.dx, p.y + pl.dy
      local e = p.e
      -- (an anchor that has moved under a panel since the layout waits; so does
      -- a tag that has drifted onto a higher one since: until the next layout)
      local clash = inside(blocked, x, y) or inside(blocked, x + pl.w, y + pl.h)
      for i = 1, #drawn_r do
        if clash then break end
        local q = drawn_r[i]
        if x < q[1] + q[3] and x + pl.w > q[1] and y < q[2] + q[4] and y + pl.h > q[2] then clash = true end
      end
      if not clash then
        drawn_r[#drawn_r + 1] = { x, y, pl.w, pl.h }
        if pl.leader then
          local cx, cy = x + pl.w / 2, y + pl.h / 2
          if math.abs(cx - p.x) < 1 then
            local y1, y2 = math.min(p.y, cy), math.max(p.y, cy)
            draw.rect(p.x - 0.5, y1, 1, y2 - y1, C.ink[1], C.ink[2], C.ink[3], 0.35)
          else
            local x1, x2 = math.min(p.x, cx), math.max(p.x, cx)
            draw.rect(x1, p.y - 0.5, x2 - x1, 1, C.ink[1], C.ink[2], C.ink[3], 0.35)
          end
        end
        tag(x, y, pl.w, pl.h, e.name, pl.h > fs * 2 and line2(e) or nil, fs, p.id == selected)
        labels_now[#labels_now + 1] = { id = p.id, x = x, y = y, w = pl.w, h = pl.h }
        ntag = ntag + 1
      end
    end
  end
  stats.drawn, stats.tags = drawn, ntag
  ema("d_ms", (wall() - d0) * 1000)
  stats.ms = (wall() - t0) * 1000
  -- (probes: the anchors as this frame drew them, with this frame's read)
  if probeHook then pcall(probeHook, anchors_now, B, S) end
end

function anchorsNow() return anchors_now end
function labelsNow() return labels_now end
-- The live node the map should highlight the track of (the selection), or nil.
function pickedNode()
  local S = snap()
  local e = selected and S.byId[selected]
  return e and e.node or nil
end
