-- TRACKING STATION — every craft you have out there, and the crew.
--
-- Opened at the Tracking Station building (E at the dish, through
-- facility_menu). The list on the left is everything in the field — flying,
-- landed, and the crew on foot — with its signal bars; the detail on the right
-- is the selected one:
--
--   where        body, situation, altitude, periapsis / apoapsis, distance home
--   power        battery charge (each craft's own batteries, synced live)
--   signal       strength, hops, and the path home ("via Relay 2 → Ground station")
--   control      who can fly it now: the crew aboard, a probe over its link, or
--                why not (NO SIGNAL, NO POWER, the pod is empty)
--
-- and what you can do with it:
--
--   FLY ▸        take its controls. A probe is flown from here, over the comms
--                network; a crewed craft gets the crew (free over a link, else a
--                shuttle flies them out — flight_ops.takeControlOf)
--   RECOVER      a craft at rest anywhere on a world with a tracking station
--                (today: home): crew home, refund scaled by distance, gone
--   END FLIGHT   write a craft off (twice to confirm; never one the crew is in)
--   RENAME       what the board, the map and the HUD call it
--   MAP          open the orbit map on it
--
-- RELAYS: every relay beacon planted on the ground (scripts/comms.lua) is
-- listed under its own heading with its link home, and the header carries the
-- network's size and the home world's ground coverage.
--
-- FLAGS: every flag the agency has planted (scripts/deployables.lua), under
-- the relays: its name, world, date and who planted it. The detail shows the
-- photo taken as it went in, where it stands and how far from home, and:
--
--   VIEW         the photo, the whole panel
--   MAP          the orbit map on its world
--   RENAME       what the board and the map call it
--   REMOVE       forget it (twice to confirm): the flag comes down
--
-- (A live camera to the flag isn't offered: it would stream another world
-- in from a building at the base. The photo is the memento.)
--
-- The header wears the agency's emblem and name (scripts/emblem.lua), and the
-- crew row lists the roster (scripts/crew.lua) when there is one.
--
-- Switching between craft in flight without coming here is `[` / `]` (the
-- vessel switcher, scripts/vessel_switcher.lua).

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

local function sfx(key)
  local s = ref("sfx")
  if s and s.play then s.play(key) end
end

local W, PAD, LIST_W = 900, 18, 360
local selected = nil          -- a fid, or "crew"
local msg, msg_t = "", -100
local armed_end = nil         -- { fid, until }
local renaming = nil          -- fid being renamed
local rename_text = ""
local viewing = nil           -- a flag id whose photo fills the panel
local armed_remove = nil      -- { fid, t }

function isOpen() return (el and el.visible) or false end
function typing() return renaming ~= nil end

function open()
  if el then el.visible = true end
  armed_end, renaming = nil, nil
  local net = ref("comms")
  if net and net.refreshNow then net.refreshNow() end
end

function close()
  if el then el.visible = false end
  renaming = nil
  viewing = nil
end

-- deployables' right-click "Rename…" on a flag: select it here, ready to rename.
function renameFlag(id)
  selected = "f:" .. tostring(id)
  renaming = selected
  local dep = ref("deployables")
  local e = dep and dep.get and dep.get(id)
  rename_text = e and e.n or ""
end

function selectCraft(id) selected = id; armed_end = nil; renaming = nil end
function selectedId() return selected end

local msg_dur = 6.0
local function say(text, dur) msg, msg_t, msg_dur = text or "", time, dur or 6.0 end

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
local RECOVER_MIN = 0.10     -- the share of the refund left at the antipode
local RECOVER_RATE = 0.65    -- a pristine part's refund (vessel_controller's rate)
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

-- ── formatting ──────────────────────────────────────────────────────────────

local function fmt_alt(m)
  if not m then return "—" end
  if math.abs(m) < 0.5 then m = 0 end
  if math.abs(m) >= 1e6 then return string.format("%.0f km", m / 1000) end
  if math.abs(m) >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

local function bars_text(n)
  return string.rep("▮", n) .. string.rep("▯", 4 - n)
end

local function money_of(co, v)
  return (co and co.money) and co.money(v) or ("$" .. tostring(v))
end

-- The crew member you control, by name (the roster's), else "Crew".
local function crew_name()
  local cr = ref("crew")
  local r = cr and cr.get and cr.activeId and cr.get(cr.activeId())
  return (r and type(r.name) == "string" and r.name ~= "") and r.name or "Crew"
end

-- The crew, as a row: on foot somewhere, or in a craft's seat.
local function crew_entry(rows)
  local pw = ref("planet_walker")
  local astro = find("Astronaut")
  for _, e in ipairs(rows) do
    if e.crew then
      return { fid = "crew", name = crew_name(), status = "aboard " .. e.name, aboard = e, body = e.body }
    end
  end
  if not astro then return nil end
  local body = space.dominant(astro.x, astro.y, astro.z)
  local b = body and space.body(body)
  local alt = b and (math.sqrt((astro.x - b.x) ^ 2 + (astro.y - b.y) ^ 2 + (astro.z - b.z) ^ 2) - b.radius) or nil
  return { fid = "crew", name = crew_name(), status = (pw and pw.onFoot) and "on foot" or "at the base",
           body = body, alt = alt }
end

-- ── rows ────────────────────────────────────────────────────────────────────

local function row(e, sel)
  local E = ref("electronics")
  local n = (E and e.signal) and E.bars(e.signal) or 0
  local sig = (e.fid == "crew" or e.flagId) and "" or (e.link and bars_text(n) or "no link")
  return { "button", key = "r" .. tostring(e.fid), style = e.piloted and "panel/rowActive" or "panel/row",
    selected = sel == e.fid, w = "100%", h = 34, dir = "row", gap = 10, align = "center",
    { "text", key = "m", style = "panel/cell", w = 12, h = "fit",
      text = e.fid == "crew" and "◉" or (e.relay and "▲") or (e.flagId and "▮") or (e.probe and not e.pod and "◇" or "◆") },
    { "col", key = "nm", w = "grow", h = "fit", gap = 0, pad = 0,
      { "text", key = "t", style = "panel/cellStrong", w = "100%", h = "fit", maxLines = 1,
        overflow = "ellipsis", text = e.name },
      { "text", key = "s", style = "panel/cellMuted", w = "100%", h = "fit", maxLines = 1,
        overflow = "ellipsis", text = (e.body or "?") .. " · " .. (e.status or "") } },
    { "text", key = "g", style = e.link and "panel/keys" or "panel/cellMuted", w = 62, h = "fit",
      textAlign = "end", text = sig },
    onClicked = function()
      if selected ~= e.fid then sfx("click") end
      selected, armed_end, renaming = e.fid, nil, nil
    end }
end

local function line(key, label, value, style)
  return { "row", key = key, w = "100%", h = "fit", gap = 10, pad = 0, align = "start",
    { "text", key = "l", style = "panel/label", w = 86, h = "fit", text = label },
    { "text", key = "v", style = style or "panel/cellStrong", w = "grow", h = "fit", wrap = true, text = value } }
end

local function wrapped(key, style, text)
  return { "text", key = key, style = style, w = "100%", h = "fit", wrap = true, text = text }
end

-- ── relays ──────────────────────────────────────────────────────────────────

-- Every planted relay beacon, as a board entry (fid "b:<id>").
function relay_entries()
  local net = ref("comms")
  local out = {}
  if not (net and net.beaconList) then return out end
  local bf = ref("base_facilities")
  for _, b in ipairs(net.beaconList()) do
    local st = net.statusOf and net.statusOf("b:" .. tostring(b.id))
    local dist
    if bf and bf.baseX and b.gx then
      dist = math.sqrt((b.gx - bf.baseX) ^ 2 + (b.gy - bf.baseY) ^ 2 + (b.gz - bf.baseZ) ^ 2)
    end
    out[#out + 1] = { fid = "b:" .. tostring(b.id), relay = true, beacon = b, name = b.name, body = b.body,
                      status = b.linked and (b.hops <= 1 and "relay · direct" or string.format("relay · %d hops", b.hops))
                        or "relay · no link",
                      link = b.linked, signal = b.strength, hops = b.hops, path = b.names, dist = dist,
                      why = st and st.why or nil, landed = true }
  end
  return out
end

-- "  ·  4 relays · home ground 31%"
function relay_summary(net, relays)
  if not (net and #relays > 0) then return "" end
  local bf = ref("base_facilities")
  local home = bf and bf.baseBody
  local cov = (home and net.coverage) and net.coverage(home) or nil
  return string.format("  ·  %d relay%s%s", #relays, #relays == 1 and "" or "s",
    cov and string.format("  ·  %s ground %d%%", home, math.floor(cov.ground * 100 + 0.5)) or "")
end

-- ── flags ───────────────────────────────────────────────────────────────────

-- Latitude and longitude of a body-relative point, as "12.3°N 45.6°E".
function latlon(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return "—" end
  local lat = math.deg(math.asin(math.max(-1, math.min(1, y / l))))
  local lon = math.deg(math.atan2(z, x))
  return string.format("%.1f°%s  %.1f°%s", math.abs(lat), lat >= 0 and "N" or "S", math.abs(lon), lon >= 0 and "E" or "W")
end

-- Every planted flag, as a board entry (fid "f:<id>").
function flag_entries()
  local dep = ref("deployables")
  local out = {}
  if not (dep and dep.list) then return out end
  local bf = ref("base_facilities")
  for _, f in ipairs(dep.list("flag")) do
    local dist, home = nil, false
    if bf and bf.baseBody == f.b then
      home = true
      local b = space.body(f.b)
      if b and bf.baseX then
        local bx, by, bz = bf.baseX - b.x, bf.baseY - b.y, bf.baseZ - b.z
        local lb = math.sqrt(bx * bx + by * by + bz * bz)
        local lf = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
        if lb > 1e-6 and lf > 1e-6 then
          local c = math.max(-1, math.min(1, (bx * f.x + by * f.y + bz * f.z) / (lb * lf)))
          dist = math.acos(c) * (b.radius or lb)
        end
      end
    elseif bf and bf.baseBody then
      local a, b = space.body(bf.baseBody), space.body(f.b)
      if a and b then dist = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
    end
    out[#out + 1] = { fid = "f:" .. tostring(f.id), flag = f, flagId = f.id, name = f.n or "Flag", body = f.b,
                      status = string.format("flag · %s", f.d or ""), landed = true, dist = dist, homeWorld = home,
                      by = dep.memberName and dep.memberName(f.by) or nil }
  end
  return out
end

local function flag_detail(e, rows)
  local function add(x) rows[#rows + 1] = x end
  local dep = ref("deployables")
  local f = e.flag
  add({ "text", key = "st", style = "panel/label", w = "100%", h = "fit", text = "Agency flag" })
  if renaming == e.fid then
    add({ "row", key = "ren", w = "100%", h = 34, gap = 6, pad = 0, align = "center",
      { "field", key = "f", style = "menu/field", w = "grow", h = 32, placeholder = e.name, maxLen = 40,
        onChanged = function(n) rename_text = n.text or "" end,
        onSubmitted = function(n)
          local ok, why = dep.rename(e.flagId, n.text or rename_text)
          if ok then sfx("click"); renaming = nil else say(why) end
        end },
      { "button", key = "ok", style = "panel/action", w = 70, h = 32, text = "Save", textAlign = "center",
        textValign = "center", onClicked = function()
          local ok, why = dep.rename(e.flagId, rename_text)
          if ok then sfx("click"); renaming = nil else say(why) end
        end },
      { "button", key = "no", style = "panel/secondary", w = 70, h = 32, text = "Cancel", textAlign = "center",
        textValign = "center", onClicked = function() renaming = nil end } })
  else
    add({ "row", key = "hd", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
      { "text", key = "nm", style = "panel/heading", w = "grow", h = "fit", wrap = true, text = e.name },
      { "button", key = "rn", style = "panel/secondary", w = 76, h = 26, text = "Rename", textAlign = "center",
        textValign = "center", onClicked = function() renaming, rename_text = e.fid, e.name end } })
  end
  -- the photo (built from its file once, then cached by deployables)
  local tex = dep and dep.photoTex and dep.photoTex(e.flagId) or nil
  if tex then
    add({ "button", key = "ph", w = 320, h = 180, texture = tex, imageFit = "cover", tooltip = "View the photo",
      onClicked = function() sfx("click"); viewing = e.flagId end })
  else
    add({ "box", key = "ph", w = 320, h = 180, style = "panel/frame",
      { "text", key = "t", style = "panel/cellMuted", w = "100%", h = "fit", textAlign = "center",
        text = f.photo and "developing the photo…" or "no photo" } })
  end
  add(line("where", "Where", string.format("%s  ·  %s", e.body or "?", latlon(f.x or 0, f.y or 0, f.z or 0))))
  if e.dist then
    add(line("home", e.homeWorld and "From base" or "From home", e.homeWorld and fmt_alt(e.dist)
      or string.format("%s (world to world)", fmt_km(e.dist))))
  end
  add(line("when", "Planted", f.d or "—"))
  add(line("by", "By", e.by or "the agency"))
  add({ "box", key = "rule", style = "panel/rule", w = "100%", h = 1 })
  local armed = armed_remove and armed_remove.fid == e.fid and time < armed_remove.t
  add({ "row", key = "acts", w = "100%", h = 32, gap = 6, pad = 0,
    { "button", key = "view", style = "panel/secondary", w = "grow", h = 32, textAlign = "center",
      textValign = "center", text = "View", disabled = tex == nil, tooltip = "The photo taken as it went in",
      onClicked = function() sfx("click"); viewing = e.flagId end },
    { "button", key = "map", style = "panel/secondary", w = "grow", h = 32, textAlign = "center",
      textValign = "center", text = "Map", tooltip = "Open the orbit map on " .. tostring(e.body),
      onClicked = function()
        local om = ref("orbit_map")
        local n = (dep.nodeOf and dep.nodeOf(e.flagId)) or find(e.body)
        if om and om.focusNode and n then
          local fm = ref("facility_menu")
          if fm and fm.close then fm.close() else close() end
          om.focusNode(n)
        end
      end },
    { "button", key = "rm", style = "panel/danger", w = "grow", h = 32, textAlign = "center",
      textValign = "center", selected = armed, text = armed and "Confirm" or "Remove",
      tooltip = "Forget this flag: it comes down, and its photo goes",
      onClicked = function()
        if armed then
          armed_remove = nil
          if dep.remove(e.flagId) then say(e.name .. " taken down"); selected = nil end
        else
          armed_remove = { fid = e.fid, t = time + 4.0 }
        end
      end } })
  if armed then add(wrapped("warn", "panel/hintWarn", "Press again to take " .. e.name .. " down. It cannot be undone.")) end
  return rows
end

-- The photo, the whole panel.
local function photo_view()
  local dep = ref("deployables")
  local e = dep and dep.get and dep.get(viewing)
  if not e then viewing = nil return nil end
  local tex = dep.photoTex(viewing)
  local w = math.min(W, design_width_now and design_width_now() or W) - PAD * 2
  local h = math.floor(w * 9 / 16)
  return { "col", key = "ts", style = "panel/frame", w = "100%", dir = "col", gap = 12, pad = PAD, align = "start",
    { "row", key = "head", w = "100%", h = "fit", gap = 14, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = e.n or "Flag" },
      { "text", key = "n", style = "panel/cellMuted", w = "fit", h = "fit",
        text = string.format("%s  ·  %s", e.b or "?", e.d or "") },
      { "button", key = "back", style = "panel/secondary", w = 90, h = 28, text = "◂  Back", textAlign = "center",
        textValign = "center", onClicked = function() sfx("click"); viewing = nil end } },
    { "image", key = "photo", w = w, h = h, texture = tex or "textures/parts/flag_default.png", imageFit = "contain" },
  }
end

-- ── the detail pane ─────────────────────────────────────────────────────────

local function detail(e, fo, co)
  local rows = {}
  local function add(x) rows[#rows + 1] = x end
  if not e then
    add(wrapped("none", "panel/body",
      "Nothing in the field yet. Anything you launch shows up here — and a probe can be flown from this desk for as long as it can hear the ground station."))
    return rows
  end
  local E = ref("electronics")
  if e.flagId then return flag_detail(e, rows) end
  if e.relay then
    local b = e.beacon
    add({ "text", key = "st", style = "panel/label", w = "100%", h = "fit", text = "Relay beacon" })
    add({ "text", key = "nm", style = "panel/heading", w = "100%", h = "fit", text = e.name })
    add(line("where", "Where", string.format("on the ground, %s", e.body or "?")))
    if e.dist then add(line("home", "From base", fmt_alt(e.dist))) end
    if e.link then
      local n = E and E.bars(e.signal) or 0
      local path = (e.path and #e.path > 0) and table.concat(e.path, " → ") or "Ground station"
      add(line("sig", "Signal", string.format("%s  %d%%  ·  %s", bars_text(n), math.floor((e.signal or 0) * 100 + 0.5),
        (e.hops or 1) <= 1 and "direct" or string.format("%d hops", e.hops)), "panel/keys"))
      add(line("path", "Path", "via " .. path, "panel/cellMuted"))
    else
      add(line("sig", "Signal", e.why or "no path home", "panel/hintWarn"))
    end
    add(line("pwr", "Power", "always on (long-life cell)", "panel/cellMuted"))
    add(wrapped("about", "panel/hint",
      "A relay beacon passes every signal it hears on toward home. Carry more (the depot sells them), "
      .. "take one in hand and set it down to carry the network round the world; right-click a planted one "
      .. "→ Pick up to take it back."))
    return rows
  end
  if e.fid == "crew" then
    add({ "text", key = "st", style = "panel/label", w = "100%", h = "fit", text = "Your crew" })
    add({ "text", key = "nm", style = "panel/heading", w = "100%", h = "fit", text = e.name or "Crew" })
    add(line("where", "Where", (e.aboard and ("in the seat of " .. e.aboard.name)) or
      string.format("%s, %s", e.status or "on foot", e.body or "?")))
    if e.alt then add(line("alt", "Altitude", fmt_alt(e.alt))) end
    local cr = ref("crew")
    local roster = cr and cr.roster and cr.roster() or {}
    if #roster > 0 then
      add({ "text", key = "rl", style = "panel/label", w = "100%", h = "fit", text = "Roster" })
      for i, r in ipairs(roster) do
        local st, det = nil, nil
        if cr.where then st, det = cr.where(r.id) end
        local wtxt = (st == "aboard" and ("aboard " .. tostring(det or "a craft")))
          or (st == "afoot" and ("on foot, " .. tostring(det or "?")))
          or (st == "dead" and "lost" ) or (st or "at the base")
        add(line("m" .. i, r.name or ("#" .. tostring(r.id)), wtxt, st == "dead" and "panel/cellMuted" or nil))
      end
    end
    add(wrapped("about", "panel/hint",
      "The crew fly what they sit in; probes are flown from this desk while they stay put."))
    return rows
  end
  add({ "text", key = "st", style = "panel/label", w = "100%", h = "fit",
    text = (e.piloted and "Flying now" or (e.live and "In the field" or "Being put back")) })
  if renaming == e.fid then
    add({ "row", key = "ren", w = "100%", h = 34, gap = 6, pad = 0, align = "center",
      { "field", key = "f", style = "menu/field", w = "grow", h = 32, placeholder = e.name, maxLen = 32,
        onChanged = function(n) rename_text = n.text or "" end,
        onSubmitted = function(n)
          local ok, why = fo.renameFleet(e.fid, n.text or rename_text)
          if ok then sfx("click"); renaming = nil else say(why) end
        end },
      { "button", key = "ok", style = "panel/action", w = 70, h = 32, text = "Save", textAlign = "center",
        textValign = "center", onClicked = function()
          local ok, why = fo.renameFleet(e.fid, rename_text)
          if ok then sfx("click"); renaming = nil else say(why) end
        end },
      { "button", key = "no", style = "panel/secondary", w = 70, h = 32, text = "Cancel", textAlign = "center",
        textValign = "center", onClicked = function() renaming = nil end } })
  else
    add({ "row", key = "hd", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
      { "text", key = "nm", style = "panel/heading", w = "grow", h = "fit", wrap = true, text = e.name },
      { "button", key = "rn", style = "panel/secondary", w = 76, h = 26, text = "Rename", textAlign = "center",
        textValign = "center", onClicked = function() renaming, rename_text = e.fid, e.name end } })
  end
  -- where
  local where = string.format("%s · %s", e.body or "?", e.status or "")
  add(line("where", "Where", where))
  local orbit = fmt_alt(e.alt)
  if e.pe and e.ap and not e.landed then
    orbit = string.format("%s   ·   pe %s · ap %s", fmt_alt(e.alt), fmt_alt(e.pe), fmt_alt(e.ap))
  elseif e.escaping then
    orbit = fmt_alt(e.alt) .. "   ·   escaping " .. (e.body or "")
  end
  add(line("alt", "Altitude", orbit))
  if e.dist then add(line("home", "From base", fmt_alt(e.dist))) end
  -- power
  if (e.cap or 0) > 0 then
    local f = e.charge / e.cap
    add(line("pwr", "Power", string.format("%.0f / %.0f EC  (%d%%)", e.charge, e.cap, math.floor(f * 100 + 0.5)),
      f < 0.1 and "panel/hintWarn" or "panel/cellStrong"))
  else
    add(line("pwr", "Power", "no batteries", "panel/cellMuted"))
  end
  -- signal
  if e.link then
    local n = E and E.bars(e.signal) or 0
    local path = (e.path and #e.path > 0) and table.concat(e.path, " → ") or "Ground station"
    add(line("sig", "Signal", string.format("%s  %d%%  ·  %s", bars_text(n), math.floor((e.signal or 0) * 100 + 0.5),
      (e.hops or 1) <= 1 and "direct" or string.format("%d hops", e.hops)), "panel/keys"))
    add(line("path", "Path", "via " .. path, "panel/cellMuted"))
  else
    add(line("sig", "Signal", e.linkWhy or ((e.comms or e.probe) and "no path home" or "no antenna"), "panel/hintWarn"))
  end
  -- control
  local ctl
  if e.crew then ctl = "crew aboard"
  elseif e.probe and e.control then ctl = "probe — under command"
  elseif e.probe then
    local w = tostring(e.why or (e.link and "ready" or "no signal"))
    -- just the headline ("NO SIGNAL"): the Signal line already says why
    ctl = "probe — " .. (w:match("^(.-) — ") or w):lower()
  elseif e.pod then ctl = "crew pod, empty"
  else ctl = "no command part" end
  add(line("ctl", "Control", ctl, (e.probe and not e.control and not e.crew) and "panel/hintWarn" or nil))
  add({ "box", key = "rule", style = "panel/rule", w = "100%", h = 1 })
  -- actions
  local fly_label, fly_ok, fly_why = "Fly  ▸", true, nil
  if e.piloted then fly_label, fly_ok = "You're flying it", false
  elseif not e.live then fly_label, fly_ok = "Not back yet", false
  elseif e.pod and not e.crew and not e.probe and (e.fee or 0) > 0 then
    fly_label = string.format("Send the crew  ·  %s  ▸", money_of(co, e.fee))
    if co and co.afford and not co.afford(e.fee) then
      fly_ok = false
      fly_why = string.format("The shuttle out to %s costs %s — more than the balance (%s). "
        .. "Recover or sell something first, or walk there.", e.name, money_of(co, e.fee),
        money_of(co, co.balance and co.balance() or 0))
    end
  elseif e.pod and not e.crew and not e.probe then fly_label = "Send the crew  ▸"
  elseif not (e.probe or e.crew or e.pod) then fly_label, fly_ok = "Nothing aboard to fly", false end
  add({ "button", key = "fly", style = "panel/action", w = "100%", h = 38, textAlign = "center",
    textValign = "center", disabled = not fly_ok, text = fly_label, tooltip = fly_why,
    onClicked = function()
      local ok, why = fo.takeControlOf(e.fid)
      if ok then
        sfx("click")
        local fm = ref("facility_menu")
        if fm and fm.close then fm.close() else close() end
      else
        say(why)
      end
    end })
  if fly_why then add(wrapped("flywhy", "panel/hintWarn", fly_why)) end
  local armed = armed_end and armed_end.fid == e.fid and time < armed_end.t
  local rec_ok, rec_why = recoverCheck(e)
  local rec_text, rec_tip = "Recover", "Recover: " .. tostring(rec_why)
  if rec_ok then
    local q = recoverQuote(e)
    rec_text = "Recover  ·  +" .. money_of(co, q.value)
    rec_tip = q.near and "At the base: the crew come home and most of its hardware value is refunded"
      or string.format("%s from the base: the crew come home, %d%% of the refund (it falls off with distance)",
        fmt_km(q.dist), math.floor(q.factor * 100 + 0.5))
  end
  add({ "row", key = "acts", w = "100%", h = 32, gap = 6, pad = 0,
    { "button", key = "rec", style = "panel/secondary", w = "grow", h = 32, textAlign = "center",
      textValign = "center", text = rec_text, disabled = not rec_ok, tooltip = rec_tip,
      onClicked = function()
        local ok, why = recoverFleet(e.fid)
        if ok then sfx("click"); say(why, 15.0); selected = nil else say(why) end
      end },
    { "button", key = "map", style = "panel/secondary", w = "grow", h = 32, textAlign = "center",
      textValign = "center", text = "Map", disabled = not e.live,
      tooltip = "Open the orbit map on this craft",
      onClicked = function()
        local om, v = ref("orbit_map"), fo.liveOf and fo.liveOf(e.fid)
        if om and v and om.focusNode then
          local fm = ref("facility_menu")
          if fm and fm.close then fm.close() else close() end
          om.focusNode(v.node)
        end
      end },
    { "button", key = "end", style = "panel/danger", w = "grow", h = 32, textAlign = "center",
      textValign = "center", selected = armed, disabled = e.crew,
      text = armed and "Confirm" or "End flight",
      tooltip = "Write the craft off: it leaves the world and the board, no refund",
      onClicked = function()
        if armed then
          local ok, why = fo.terminateFleet(e.fid)
          armed_end = nil
          if ok then say(e.name .. " written off"); selected = nil else say(why) end
        else
          armed_end = { fid = e.fid, t = time + 4.0 }
        end
      end } })
  if not rec_ok then
    add(wrapped("recwhy", "panel/hint", "Can't recover: " .. tostring(rec_why) .. "."))
  end
  if armed then
    add(wrapped("warn", "panel/hintWarn", "Press again to write " .. e.name .. " off. It cannot be undone."))
  end
  return rows
end

local function describe()
  local fo, co = ref("flight_ops"), ref("company")
  local list = (fo and fo.fleetList) and fo.fleetList() or {}
  local crew = crew_entry(list)
  local all = {}
  if crew then all[#all + 1] = crew end
  for _, e in ipairs(list) do all[#all + 1] = e end
  local relays = relay_entries()
  for _, e in ipairs(relays) do all[#all + 1] = e end
  local flags = flag_entries()
  for _, e in ipairs(flags) do all[#all + 1] = e end
  local sel = nil
  for _, e in ipairs(all) do if e.fid == selected then sel = e end end
  if not sel then
    for _, e in ipairs(list) do if e.piloted then sel = e end end
    sel = sel or list[1] or crew
    selected = sel and sel.fid or nil
  end
  local left = {}
  local function group(label, pred)
    local any = false
    for _, e in ipairs(all) do
      if pred(e) then
        if not any then
          left[#left + 1] = { "text", key = "L" .. label, style = "panel/label", w = "100%", h = "fit", text = label }
          any = true
        end
        left[#left + 1] = row(e, selected)
      end
    end
  end
  group("Crew", function(e) return e.fid == "crew" end)
  group("In flight", function(e) return e.fid ~= "crew" and not e.relay and not e.flagId and not e.landed end)
  group("Landed", function(e) return e.fid ~= "crew" and not e.relay and not e.flagId and e.landed end)
  if #list == 0 then
    left[#left + 1] = { "text", key = "empty", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "No craft in the field." }
  end
  group("Relays", function(e) return e.relay == true end)
  group("Flags", function(e) return e.flagId ~= nil end)
  local net = ref("comms")
  local linked = 0
  for _, e in ipairs(list) do if e.link then linked = linked + 1 end end
  local hint = (msg ~= "" and time - msg_t < msg_dur) and ("» " .. msg)
    or "Click a craft for its details.   [ / ] switch between nearby craft in flight.   E or Esc to leave."
  if viewing then
    local pv = photo_view()
    if pv then return pv end
  end
  local em = ref("emblem")
  local etex = em and em.tex and em.tex() or nil
  local aname = em and em.name and em.name() or nil
  return { "col", key = "ts", style = "panel/frame", w = "100%", dir = "col", gap = 12, pad = PAD, align = "start",
    { "row", key = "head", w = "100%", h = "fit", gap = 14, pad = 0, align = "center",
      { "image", key = "emb", w = 34, h = 34, texture = etex or "textures/parts/emblem_default.png", imageFit = "contain" },
      { "col", key = "tt", w = "grow", h = "fit", gap = 0, pad = 0, align = "start",
        { "text", key = "title", style = "panel/heading", w = "100%", h = "fit", text = "Tracking Station" },
        { "text", key = "ag", style = "panel/cellMuted", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = aname or "" } },
      { "text", key = "n", style = "panel/cellMuted", w = "fit", h = "fit",
        text = string.format("%d craft  ·  %d in contact  ·  %d transmitters%s%s", #list, linked,
          net and net.transmitters or 0, relay_summary(net, relays),
          #flags > 0 and string.format("  ·  %d flag%s", #flags, #flags == 1 and "" or "s") or "") } },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "panes", w = "100%", h = "fit", gap = 24, pad = 0, align = "start",
      { "scroll", key = "listS", w = LIST_W, h = "fit", maxH = 470, gap = 0, pad = 0,
        { "col", key = "list", w = "100%", h = "fit", gap = 4, pad = 0, align = "start",
          items = left, function(x) return x end } },
      { "col", key = "detail", w = "grow", h = "fit", gap = 8, pad = 0, align = "start",
        items = detail(sel, fo, co), function(x) return x end } },
    { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 },
    { "text", key = "hint", style = (msg ~= "" and time - msg_t < msg_dur) and "panel/hintWarn" or "panel/hint",
      w = "100%", h = "fit", wrap = true, text = hint },
  }
end

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return uiDesignH() * w / h end
  end
  return 1280 * uiDesignH() / 720
end

design_width_now = design_width

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
  -- the agency's identity and its flags: their libraries, if this scene has none
  if spawn and findScript then
    if not findScript("emblem") then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
    if not findScript("deployables") then pcall(spawn, "DeployLib", vec3(0, 0, 0)) end
  end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or not el.visible then return end
  input.setMouseLocked(false)
  local w = math.min(W, design_width() - 32)
  if el.width ~= w then el.width = w end
  ui.make(node, describe())
end
