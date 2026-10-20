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
--   RECOVER      a craft landed at home goes to the crane, refund and all
--   END FLIGHT   write a craft off (twice to confirm; never one the crew is in)
--   RENAME       what the board, the map and the HUD call it
--   MAP          open the orbit map on it
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
end

function selectCraft(id) selected = id; armed_end = nil; renaming = nil end
function selectedId() return selected end

local function say(text) msg, msg_t = text or "", time end

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

-- The crew, as a row: on foot somewhere, or in a craft's seat.
local function crew_entry(rows)
  local pw = ref("planet_walker")
  local astro = find("Astronaut")
  for _, e in ipairs(rows) do
    if e.crew then
      return { fid = "crew", name = "Crew", status = "aboard " .. e.name, aboard = e, body = e.body }
    end
  end
  if not astro then return nil end
  local body = space.dominant(astro.x, astro.y, astro.z)
  local b = body and space.body(body)
  local alt = b and (math.sqrt((astro.x - b.x) ^ 2 + (astro.y - b.y) ^ 2 + (astro.z - b.z) ^ 2) - b.radius) or nil
  return { fid = "crew", name = "Crew", status = (pw and pw.onFoot) and "on foot" or "at the base",
           body = body, alt = alt }
end

-- ── rows ────────────────────────────────────────────────────────────────────

local function row(e, sel)
  local E = ref("electronics")
  local n = (E and e.signal) and E.bars(e.signal) or 0
  local sig = (e.fid == "crew") and "" or (e.link and bars_text(n) or "no link")
  return { "button", key = "r" .. tostring(e.fid), style = e.piloted and "panel/rowActive" or "panel/row",
    selected = sel == e.fid, w = "100%", h = 34, dir = "row", gap = 10, align = "center",
    { "text", key = "m", style = "panel/cell", w = 12, h = "fit",
      text = e.fid == "crew" and "◉" or (e.probe and not e.pod and "◇" or "◆") },
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
  if e.fid == "crew" then
    add({ "text", key = "st", style = "panel/label", w = "100%", h = "fit", text = "Your crew" })
    add({ "text", key = "nm", style = "panel/heading", w = "100%", h = "fit", text = "Crew" })
    add(line("where", "Where", (e.aboard and ("in the seat of " .. e.aboard.name)) or
      string.format("%s, %s", e.status or "on foot", e.body or "?")))
    if e.alt then add(line("alt", "Altitude", fmt_alt(e.alt))) end
    add(wrapped("about", "panel/hint",
      "There is one crew. They fly what they sit in; probes are flown from this desk while they stay put."))
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
  local fly_label, fly_ok = "Fly  ▸", true
  if e.piloted then fly_label, fly_ok = "You're flying it", false
  elseif not e.live then fly_label, fly_ok = "Not back yet", false
  elseif e.pod and not e.crew and not e.probe and (e.fee or 0) > 0 then
    fly_label = string.format("Send the crew  ·  %s  ▸", money_of(co, e.fee))
  elseif e.pod and not e.crew and not e.probe then fly_label = "Send the crew  ▸"
  elseif not (e.probe or e.crew or e.pod) then fly_label, fly_ok = "Nothing aboard to fly", false end
  add({ "button", key = "fly", style = "panel/action", w = "100%", h = 38, textAlign = "center",
    textValign = "center", disabled = not fly_ok, text = fly_label,
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
  local armed = armed_end and armed_end.fid == e.fid and time < armed_end.t
  add({ "row", key = "acts", w = "100%", h = 32, gap = 6, pad = 0,
    { "button", key = "rec", style = "panel/secondary", w = "grow", h = 32, textAlign = "center",
      textValign = "center", text = "Recover", disabled = not (e.home and e.live and not e.piloted),
      tooltip = e.home and "Landed at home: the crane strips it and refunds most of it"
        or "Only a craft landed at the base can be recovered",
      onClicked = function()
        local ok, why = fo.recoverFleet(e.fid)
        if ok then say("recovered " .. e.name); selected = nil else say(why) end
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
  group("In flight", function(e) return e.fid ~= "crew" and not e.landed end)
  group("Landed", function(e) return e.fid ~= "crew" and e.landed end)
  if #list == 0 then
    left[#left + 1] = { "text", key = "empty", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "No craft in the field." }
  end
  local net = ref("comms")
  local linked = 0
  for _, e in ipairs(list) do if e.link then linked = linked + 1 end end
  local hint = (msg ~= "" and time - msg_t < 6.0) and ("» " .. msg)
    or "Click a craft for its details.   [ / ] switch between nearby craft in flight.   E or Esc to leave."
  return { "col", key = "ts", style = "panel/frame", w = "100%", dir = "col", gap = 12, pad = PAD, align = "start",
    { "row", key = "head", w = "100%", h = "fit", gap = 14, pad = 0, align = "center",
      { "text", key = "title", style = "panel/heading", w = "grow", h = "fit", text = "Tracking Station" },
      { "text", key = "n", style = "panel/cellMuted", w = "fit", h = "fit",
        text = string.format("%d craft  ·  %d in contact  ·  %d transmitters", #list, linked,
          net and net.transmitters or 0) } },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "panes", w = "100%", h = "fit", gap = 24, pad = 0, align = "start",
      { "scroll", key = "listS", w = LIST_W, h = "fit", maxH = 470, gap = 0, pad = 0,
        { "col", key = "list", w = "100%", h = "fit", gap = 4, pad = 0, align = "start",
          items = left, function(x) return x end } },
      { "col", key = "detail", w = "grow", h = "fit", gap = 8, pad = 0, align = "start",
        items = detail(sel, fo, co), function(x) return x end } },
    { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 },
    { "text", key = "hint", style = (msg ~= "" and time - msg_t < 6.0) and "panel/hintWarn" or "panel/hint",
      w = "100%", h = "fit", wrap = true, text = hint },
  }
end

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return 720 * w / h end
  end
  return 1280
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or not el.visible then return end
  input.setMouseLocked(false)
  local w = math.min(W, design_width() - 32)
  if el.width ~= w then el.width = w end
  ui.make(node, describe())
end
