-- FLEET VIEW — everything of ours out there, as one snapshot the Tracking
-- Station reads (docs/tracking-station.md §5.1).
--
-- Craft (flight_ops' records, live or waiting to be rebuilt), the crew on
-- foot and at base, packed and lost debris, relay beacons, flags, remains,
-- structures and the spaceport — each an ENTRY:
--
--   id      "c3" (a fleet record) | "m:2" (a member) | "d:d14" (packed debris)
--           | "v:<node>" (a lost wreck) | "b:3" (relay) | "f:2" (flag)
--           | "r:5" (remains) | "s:4" (structure) | "base" (the spaceport)
--   kind    crew | rocket | probe | plane | rover | bike | station | debris
--           | relay | flag | remains | structure | base
--   name, body, group (the FLEET list heading), sub (the situation line),
--   num (the number that matters), attn = { level = "warn"|"danger", text }
--   rx, ry, rz, vx, vy, vz, st  BODY-RELATIVE pose and the game time it was
--           read (never a world point: docs/positions-and-frames.md rule 1);
--           conic = true when it rides its orbit and has to be carried to now
--   node    the live node (a craft, a crew body, the avatar), whose DRAWN
--           pose is the anchor in the map pass
--   fleet   the flight_ops board entry (craft); crew = { {id, name, role}… }
--   recover = { ok, why, value, factor, dist, near }   (craft at rest)
--
-- (expansion X1) THE WORLDS: every planet and moon of the home system is an
-- entry too, "w:<name>", kind `body`, group WORLDS, at its body's centre
-- (rx = ry = rz = 0): its card is the BODY card (the survey's six layers,
-- scripts/survey.lua). The map draws the bodies itself, so the station puts
-- no icon on them; `known` is the share of the six layers filled.
--
-- snapshot() rebuilds at 2 Hz, or as soon as one of the sources says it
-- changed (flight_ops.fleetVersion, comms.networkVersion, structures.version,
-- deployables.version, debris_pack.packVersion; crew.version at most 4 Hz).
-- A record's decoded fields (kind, crew seats) are kept by its `t`, so a
-- record that was not written again is never decoded again.
--
-- Pure (luajit, tests/smoke_fleet_view.lua): kindOf(parts, flags),
-- attention(e), situation(e), keyNumber(e), groupOf(e), GLYPHS, PRIO.

GLYPHS = { crew = "◉", rocket = "◆", probe = "◇", plane = "✈", rover = "⊡", bike = "⊚", station = "⊕",
           debris = "✕", relay = "▲", flag = "▮", remains = "◌", structure = "⌂", base = "⌂", outpost = "⌂", target = "◎",
           recover = "↺", body = "●", route = "⇄" }
-- Layout priority (map_labels): the selected and hovered are lifted above these.
PRIO = { crew = 70, rocket = 66, station = 64, plane = 62, rover = 60, bike = 60, probe = 50, base = 46, outpost = 46,
         relay = 40, flag = 38, structure = 36, remains = 30, debris = 10, body = 5, route = 55 }
GROUPS = { "ATTENTION", "CREW", "CREWED", "PROBES", "RUNS", "LANDED", "DEBRIS", "RELAYS", "FLAGS", "BASES", "STRUCTURES", "WORLDS" }
RATE = 2.0          -- s between rebuilds while nothing says it changed (a source
                    -- that changes rebuilds it at once; live craft are placed
                    -- from their nodes every frame anyway)
MIN_GAP = 0.1       -- s: never rebuilt twice inside this

-- ── pure rules ──────────────────────────────────────────────────────────────

local function is_wing(id)
  return id:find("^wing") ~= nil or id == "cockpit" or id == "jet" or id == "elevon" or id == "tailFin"
    or id == "canard" or id == "aileron"
end

-- What a craft is, from its part records. flags: lost, landed, crewed
-- (someone is seated), orbit (in flight, on a closed conic).
function kindOf(parts, flags)
  flags = flags or {}
  local wheels, bwheels, saddle, wings, dock, commands, crewed_parts, probe = 0, 0, 0, 0, 0, 0, 0, false
  local n = 0
  for _, d in pairs(parts or {}) do
    n = n + 1
    local id = tostring(d.id or "")
    if id:find("^wheel") then
      wheels = wheels + 1
      if id:find("^wheelB") then bwheels = bwheels + 1 end
    end
    if id == "saddle" or id == "forkT" or id == "swingArm" then saddle = saddle + 1 end
    if is_wing(id) then wings = wings + 1 end
    if id == "dockPort" then dock = dock + 1 end
    if d.kind == "crewed" and id ~= "cabin" then commands = commands + 1; crewed_parts = crewed_parts + 1 end
    if d.kind == "probe" or id == "probe" or id == "roverBody" then commands = commands + 1; probe = true end
  end
  if flags.lost or commands == 0 then return "debris" end
  if flags.orbit and dock > 0 and (commands >= 2 or n >= 14) then return "station" end
  if (wheels == 2 and (bwheels > 0 or saddle > 0)) or (wheels <= 2 and saddle > 0 and wheels > 0) then return "bike" end
  if wheels >= 3 then return "rover" end
  if wings >= 2 then return "plane" end
  if crewed_parts > 0 then return "rocket" end
  return "probe"
end

local function fmt_dist(m)
  m = math.abs(m or 0)
  if m < 1000 then return string.format("%.0f m", m) end
  if m < 100000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f km", m / 1000)
end
fmtDist = fmt_dist

local function pct(f) return math.floor(math.max(0, math.min(1, f or 0)) * 100 + 0.5) end

-- The countdown inside an alert: "4:12", "1h 03m".
local function mmss(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- THE ATTENTION TABLE (docs/tracking-station.md §3.1). The worst alert on an
-- entry: { level, text, all = { {level, text}… } } | nil.
--   craft: cap, charge (power) · comms (has an antenna), link, probe, crewed
--          (signal) · heat (0..1, the reactor's T), scram (scrammed) · cabin
--          (the weakest crewed seat's hp 0..1) · tImpact (s, sub-orbital),
--          landed, chutes (open) · crewAlerts (the members aboard)
--   crew:  o2, hp, downed (s left), dose (0..1), doseRising, lastAir (the
--          left-behind's record alert { level, text }, crew.recordAlerts)
HEAT_WARN, HEAT_SCRAM = 0.75, 0.90      -- thermal.lua's scram line is 0.90
CABIN_FAIL = 0.35
DOSE_WARN, DOSE_DANGER = 0.50, 0.80
IMPACT_DANGER = 120                     -- s: an impact closer than this is red
function attention(e)
  local all = {}
  local function add(level, text) all[#all + 1] = { level = level, text = text } end
  if e.kind == "crew" then
    if e.downed then add("danger", string.format("DOWN · %d s", math.floor(e.downed + 0.5))) end
    if e.lastAir and e.lastAir.text then add(e.lastAir.level or "danger", e.lastAir.text)
    elseif e.o2 and e.o2 < 0.10 then add("danger", string.format("O2 %d %%", pct(e.o2)))
    elseif e.o2 and e.o2 < 0.25 then add("warn", string.format("O2 %d %%", pct(e.o2))) end
    if e.hp and e.hp < 0.5 and not e.downed then add("warn", string.format("HP %d %%", pct(e.hp))) end
    local d = e.dose or 0
    if d >= DOSE_DANGER then add("danger", string.format("DOSE %d %%%s", pct(d), e.doseRising and " ▲" or ""))
    elseif d >= DOSE_WARN or (e.doseRising and d >= 0.05) then
      add("warn", string.format("DOSE %d %%%s", pct(d), e.doseRising and " ▲" or ""))
    end
  elseif e.craft then
    if (e.cap or 0) > 0 then
      if (e.charge or 0) <= 0 then add("danger", "NO POWER")
      elseif e.charge / e.cap < 0.10 then add("warn", string.format("POWER %d %%", pct(e.charge / e.cap))) end
    end
    if e.comms and not e.link then
      if e.probe and not e.crewed then add("danger", "NO SIGNAL · no path home")
      elseif e.crewed then add("warn", "NO SIGNAL") end
    end
    if e.scram or (e.heat or 0) >= HEAT_SCRAM then add("danger", string.format("HEAT %d %% · SCRAM", pct(e.heat)))
    elseif (e.heat or 0) >= HEAT_WARN then add("warn", string.format("HEAT %d %%", pct(e.heat))) end
    if e.cabin and e.cabin < CABIN_FAIL then add("danger", "CABIN FAILING") end
    if e.crewed and e.tImpact and not e.landed and not e.chutes then
      add(e.tImpact < IMPACT_DANGER and "danger" or "warn", "IMPACT in " .. mmss(e.tImpact))
    end
    for _, m in ipairs(e.crewAlerts or {}) do add(m.level, m.text) end
  end
  if #all == 0 then return nil end
  local best = all[1]
  for _, a in ipairs(all) do if a.level == "danger" and best.level ~= "danger" then best = a end end
  return { level = best.level, text = best.text, all = all }
end

-- ── FILTERS, SEARCH AND SORT (the FLEET column's header; pure) ─────────────
-- F = { kind = "all"|"craft"|"crew"|"infra"|"debris", body = nil|name,
--       crewed = bool, attn = bool, q = "search text", sort = SORTS key }
-- The filters hide what fails them, on the list and on the map; the search
-- only dims the map (what it does not match stays where it is, faint).
KINDS = { "all", "craft", "crew", "infra", "debris" }
KIND_LABEL = { all = "All", craft = "Craft", crew = "Crew", infra = "Infra", debris = "Debris" }
SORTS = { "name", "world", "alt", "base", "alert" }
SORT_LABEL = { name = "A–Z", world = "World", alt = "Altitude", base = "From base", alert = "Alerts" }
local INFRA = { relay = true, flag = true, remains = true, structure = true, base = true, outpost = true }
-- The bases (the spaceport and every tower's base) are always on the map:
-- no filter hides them and they never fold into a cluster (the station).
ALWAYS = { base = true, outpost = true }

function kindClass(e)
  if e.kind == "body" then return "world" end
  if e.kind == "route" then return "craft" end
  if e.craft then return "craft" end
  if e.kind == "crew" then return "crew" end
  if e.kind == "debris" then return "debris" end
  if INFRA[e.kind] then return "infra" end
  return "craft"
end

-- (X7) THE ROLE KEY: one role at a time (base_roles.ORDER), each click the
-- next; only the bases carrying it pass (F.role). Kept beside the kind key.
ROLE_KEYS = { "port", "fuel", "mine", "power", "refinery", "science", "depot", "defence" }
ROLE_SHOW = 0.5   -- (base_roles.SHOW)
function hasRole(e, r)
  return type(e.roles) == "table" and (e.roles[r] or 0) >= ROLE_SHOW
end

-- Does the entry pass the filters (the search is searchHit)?
function passes(e, F)
  if not F then return true end
  if F.role and not hasRole(e, F.role) then return false end
  if F.kind and F.kind ~= "all" and kindClass(e) ~= F.kind then return false end
  if F.body and e.body ~= F.body then return false end
  if F.crewed and not (e.crewed or e.kind == "crew") then return false end
  if F.attn and not e.attn then return false end
  return true
end

-- Does the entry match the search text? Its name, world, kind, situation
-- line, alert and the names of the crew aboard; case-blind, plain text.
function searchHit(e, q)
  if not q or q == "" then return true end
  local hay = e._hay
  if not hay then
    local parts = { tostring(e.name or ""), tostring(e.body or ""), tostring(e.kind or ""), tostring(e.sub or "") }
    for _, m in ipairs(e.crew or {}) do parts[#parts + 1] = tostring(m.name or "") end
    if e.attn then parts[#parts + 1] = tostring(e.attn.text or "") end
    hay = table.concat(parts, "\1"):lower()
    e._hay = hay
  end
  return hay:find(q:lower(), 1, true) ~= nil
end

-- The order inside a group; the flown craft (or you) first, ties by name.
local LEVEL = { danger = 2, warn = 1 }
local function sort_val(e, by)
  if by == "world" then return tostring(e.body or "~") end
  if by == "alt" then return e.alt or (e.landed and 0) or math.huge end
  if by == "base" then return e.dist or math.huge end
  if by == "alert" then return -(e.attn and (LEVEL[e.attn.level] or 0) or 0) end
  return nil
end
function sortList(list, by)
  table.sort(list, function(a, b)
    if (a.piloted or a.active or false) ~= (b.piloted or b.active or false) then return (a.piloted or a.active) == true end
    -- (the worlds keep the roster's order: planets outward, each with its moons)
    if a.kind == "body" and b.kind == "body" and (a.ord or 0) ~= (b.ord or 0) then return (a.ord or 0) < (b.ord or 0) end
    if by and by ~= "name" then
      local va, vb = sort_val(a, by), sort_val(b, by)
      if va ~= nil and vb ~= nil and va ~= vb then return va < vb end
    end
    if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
    return tostring(a.id) < tostring(b.id)
  end)
  return list
end

-- The filters as one string (cache keys).
function filterSig(F)
  F = F or {}
  return string.format("%s|%s|%s|%s|%s|%s|%s", tostring(F.kind or "all"), tostring(F.body or ""), F.crewed and 1 or 0,
    F.attn and 1 or 0, tostring(F.q or ""), tostring(F.sort or "name"), tostring(F.role or ""))
end

-- The situation line, in words: "orbiting Naolol", "landed · 4.1 km from base".
function situation(e)
  if e.kind == "crew" then
    if e.status == "base" then return "at the base" end
    if e.status == "afoot" then
      return string.format("on foot · %s%s", e.body or "?", e.dist and (" · " .. fmt_dist(e.dist) .. " from base") or "")
    end
    return e.status or ""
  end
  if e.kind == "relay" then return e.link and ((e.hops or 1) <= 1 and "relay · direct" or string.format("relay · %d hops", e.hops)) or "relay · no link" end
  if e.kind == "flag" then return "flag" .. (e.date and (" · " .. e.date) or "") end
  if e.kind == "remains" then return "remains" end
  if e.kind == "structure" then return "structure" .. (e.date and (" · " .. e.date) or "") end
  if e.kind == "base" then return "spaceport" .. (e.roleText and (" · " .. e.roleText) or "") end
  if e.kind == "body" then
    local what = e.home and "home world" or (e.parent and ("moon of " .. e.parent) or "planet")
    if e.surveyed then return what .. " · surveyed" end
    return string.format("%s · %d %% known", what, math.floor((e.known or 0) * 100 + 0.5))
  end
  if e.kind == "outpost" then
    return (e.roleText and (e.roleText .. " · ") or "base · ") .. (e.tier or "mast")
  end
  if e.kind == "route" then return e.rsub or "automated run" end
  if e.kind == "debris" then
    if e.dkind == "landed" then return "debris · down on " .. tostring(e.body) end
    if e.dkind == "orbit" then return "debris · orbiting " .. tostring(e.body) end
    return "debris · " .. tostring(e.body)
  end
  local b = e.body or "?"
  local pre = e.piloted and "flying · " or ""
  if e.splashed then return pre .. "splashed down · " .. b end
  if e.landed then
    return pre .. "landed" .. (e.homeWorld and e.dist and (" · " .. fmt_dist(e.dist) .. " from base") or (" on " .. b))
  end
  if e.escaping then return pre .. "escaping " .. b end
  if e.pe and e.pe < 0 then return pre .. "sub-orbital over " .. b end
  if e.pe then return pre .. "orbiting " .. b end
  return pre .. "in flight over " .. b
end

-- The one number that matters for its state.
function keyNumber(e)
  if e.kind == "route" then return string.format("cycle %d", (e.cycles or 0) + 1) end
  if e.kind == "body" then return e.surveyed and "SURVEYED" or string.format("%d %%", math.floor((e.known or 0) * 100 + 0.5)) end
  if e.kind == "crew" then
    if e.status == "afoot" and e.o2 then return string.format("O2 %d %%", pct(e.o2)) end
    return ""
  end
  if not e.craft then return "" end
  if e.landed then return e.alt and ("alt " .. fmt_dist(e.alt)) or "" end
  if e.ap and e.pe and e.pe > 0 then return string.format("Ap %s · Pe %s", fmt_dist(e.ap), fmt_dist(e.pe)) end
  if e.pe and e.ap then return string.format("Ap %s", fmt_dist(e.ap)) end
  return e.alt and ("alt " .. fmt_dist(e.alt)) or ""
end

-- The FLEET list heading that claims it (ATTENTION first, by the caller).
function groupOf(e)
  if e.attn then return "ATTENTION" end
  if e.kind == "route" then return "RUNS" end
  if e.kind == "crew" then return "CREW" end
  if e.craft then
    if e.crewed then return "CREWED" end
    if e.landed then return "LANDED" end
    return "PROBES"
  end
  if e.kind == "debris" then return "DEBRIS" end
  if e.kind == "relay" then return "RELAYS" end
  if e.kind == "flag" or e.kind == "remains" then return "FLAGS" end
  if e.kind == "outpost" then return "BASES" end
  if e.kind == "body" then return "WORLDS" end
  return "STRUCTURES"
end

-- The orbit's clock from a body-relative state: { period, inc (rad), tPe,
-- tAp, tImpact (s from now) } or nil for an escape. `R` is the body's radius:
-- a conic dipping under it gives the time it comes down instead of Ap/Pe.
function orbitTimes(rx, ry, rz, vx, vy, vz, mu, R)
  if not (mu and mu > 0) then return nil end
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  if r < 1e-6 then return nil end
  local v2 = vx * vx + vy * vy + vz * vz
  local rv = rx * vx + ry * vy + rz * vz
  local inv_a = 2 / r - v2 / mu
  if inv_a <= 0 then return nil end
  local a = 1 / inv_a
  local hx, hy, hz = ry * vz - rz * vy, rz * vx - rx * vz, rx * vy - ry * vx
  local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
  local k = v2 - mu / r
  local ex, ey, ez = (k * rx - rv * vx) / mu, (k * ry - rv * vy) / mu, (k * rz - rv * vz) / mu
  local e = math.sqrt(ex * ex + ey * ey + ez * ez)
  local n = math.sqrt(mu / (a * a * a))
  local P = 2 * math.pi / n
  local out = { period = P, inc = hl > 0 and math.acos(math.max(-1, math.min(1, hy / hl))) or 0, e = e, a = a }
  if e < 1e-5 then return out end
  local E = math.atan2(rv / (e * math.sqrt(mu * a)), (1 - r / a) / e)
  local M = E - e * math.sin(E)
  local function ahead(Mt)
    local d = (Mt - M) % (2 * math.pi)
    return d / n
  end
  local peR = a * (1 - e)
  if R and peR < R then
    local c = (1 - R / a) / e
    if c > -1 and c < 1 then
      local Er = 2 * math.pi - math.acos(c)     -- the descending crossing
      out.tImpact = ahead(Er - e * math.sin(Er))
    end
    return out
  end
  out.tPe, out.tAp = ahead(0), ahead(math.pi)
  return out
end

-- "T−1h 03m", "T−04:12", "T−2 d 4 h": a countdown a person reads.
function clockText(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  if s >= 86400 then return string.format("T−%d d %d h", math.floor(s / 86400), math.floor(s % 86400 / 3600)) end
  if s >= 3600 then return string.format("T−%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return string.format("T−%02d:%02d", math.floor(s / 60), s % 60)
end

-- The next events across the snapshot, soonest first: { {t (s from now),
-- id, glyph, name, what}… } at most `n`. `now` is space.time(); `bodies`
-- name → { mu, radius }; `extra` events the caller adds (a maneuver node, a
-- retrain finishing).
function nextEvents(entries, now, bodies, extra, n)
  local out = {}
  for _, e in ipairs(extra or {}) do out[#out + 1] = e end
  for _, e in ipairs(entries or {}) do
    if e.craft and not e.landed and e.body and e.rx then
      local b = bodies[e.body]
      local T = b and orbitTimes(e.rx, e.ry, e.rz, e.vx or 0, e.vy or 0, e.vz or 0, b.mu, b.radius)
      if T then
        local late = (now or 0) - (e.st or now or 0)
        local function add(t, what)
          if t then
            local tt = t - late
            if T.period and T.period > 0 then tt = tt % T.period end
            out[#out + 1] = { t = tt, id = e.id, glyph = e.glyph, name = e.name, what = what }
          end
        end
        if T.tImpact then add(T.tImpact, "impact on " .. e.body)
        else
          add(T.tPe, "Pe " .. fmt_dist(T.a * (1 - T.e) - (b.radius or 0)))
          add(T.tAp, "Ap " .. fmt_dist(T.a * (1 + T.e) - (b.radius or 0)))
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.t < b.t end)
  local cut = {}
  for i = 1, math.min(n or 4, #out) do cut[i] = out[i] end
  return cut
end

-- ── the snapshot (in the scene) ─────────────────────────────────────────────

-- The WALL clock for the cost stats (os.clock is the process's CPU time: it
-- counts the engine's worker threads too; base_facilities does the same).
local function wall() return (app and app.wallClock and app.wallClock()) or os.clock() end
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

local snap = { version = 0, t = -1e9, entries = {}, byId = {}, counts = {} }
local pause   -- (the build's yield point: set with the job below)
local stamp = nil
local meta = {}        -- fid → { t, n, kind, seats } decoded from the record
local rcache = {}      -- fid → { t, landed, r } the recovery verdict, kept 2 s
decodes = 0            -- (tests: how many records were decoded)

local function stamp_now()
  local fo, net, stc, dep, dp, cr = ref("flight_ops"), ref("comms"), ref("structures"), ref("deployables"),
    ref("debris_pack"), ref("crew")
  local sv, ro, br = ref("survey"), ref("route_ops"), ref("base_roles")
  return { fo and fo.fleetVersion or 0, net and net.networkVersion or 0, stc and stc.version or 0,
           dep and dep.version or 0, dp and dp.packVersion or 0, cr and cr.version or 0, sv and sv.version or 0,
           ro and ro.version or 0, br and br.version or 0 }
end

local function changed(a, b)
  if not (a and b) then return true end
  for i = 1, 5 do if a[i] ~= b[i] then return true end end
  if a[7] ~= b[7] or a[8] ~= b[8] or a[9] ~= b[9] then return true end
  return false
end

local function home_dist(bname, x, y, z)
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if not (fp and fp.body == bname and space and space.body) then return nil end
  local b = space.body(bname)
  if not b then return nil end
  local lb = math.sqrt(fp.x * fp.x + fp.y * fp.y + fp.z * fp.z)
  local lc = math.sqrt(x * x + y * y + z * z)
  if lb < 1e-6 or lc < 1e-6 then return nil end
  local c = math.max(-1, math.min(1, (fp.x * x + fp.y * y + fp.z * z) / (lb * lc)))
  return math.acos(c) * (b.radius or lb)
end

local function member_alerts(C, id, r)
  local o2, hp, downed = r.o2 or 1, r.hp or 1, r.downed and (r.downed.left or 0) or nil
  local rising = false
  if C and C.alerts and C.activeId and id == C.activeId() then
    local ok, a = pcall(C.alerts, id)
    if ok and a then o2, hp, downed, rising = a.o2 or o2, a.hp or hp, a.downed or downed, a.dose_rising == true end
  end
  return o2, hp, downed, rising
end

local function craft_entries(out)
  local fo, C, ts = ref("flight_ops"), ref("crew"), ref("tracking_station")
  if not (fo and fo.fleetList) then return end
  local recs = (fo.fleetRecords and fo.fleetRecords()) or {}
  local l0 = wall()
  local list = fo.fleetList()
  if ema then ema("list", (wall() - l0) * 1000) end
  for ci, f in ipairs(list) do
    if ci % 12 == 0 then pause() end
    local rec = recs[f.fid] or {}
    local v = fo.liveOf and fo.liveOf(f.fid) or nil
    if v and not (v.node and v.node.valid ~= false) then v = nil end
    local m = meta[f.fid]
    if not (m and m.t == rec.t and m.n == #(rec.parts or {})) then
      decodes = decodes + 1
      m = { t = rec.t, n = #(rec.parts or {}), seats = (C and C.seatedIn) and C.seatedIn(rec.parts or {}) or {} }
      m.kindOrbit = kindOf(rec.parts, { orbit = true })
      m.kindFlat = kindOf(rec.parts, {})
      local fc = 0
      for _, d in ipairs(rec.parts or {}) do fc = fc + (tonumber(d.fuel) or 0) end
      m.fuelCap = fc
      meta[f.fid] = m
    end
    local crew = {}
    -- (who sits where is in the record — a boarding is a structural change,
    -- written at once — so only a craft with seats taken, or the one the
    -- avatar rides, is asked live)
    if v and C and C.aboard and (#m.seats > 0 or v.crewAboard) then
      for _, s in ipairs(C.aboard(v)) do crew[#crew + 1] = { id = s.id, name = s.name } end
    else
      for _, s in ipairs(m.seats) do
        local r = C and C.get and C.get(s.id)
        if r and r.status ~= "dead" then crew[#crew + 1] = { id = s.id, name = r.name } end
      end
    end
    local alerts = {}
    for _, c in ipairs(crew) do
      local r = C and C.get and C.get(c.id) or {}
      c.role = C and C.roleLetter and C.roleLetter(r) or nil
      local o2, hp = member_alerts(C, c.id, r)
      c.o2, c.hp = o2, hp
      c.dose = tonumber(r.dose) or 0
      if hp < 0.5 then alerts[#alerts + 1] = { level = "warn", text = string.format("%s HP %d %%", c.name or "crew", pct(hp)) } end
      if c.dose >= DOSE_WARN then
        alerts[#alerts + 1] = { level = c.dose >= DOSE_DANGER and "danger" or "warn",
                                text = string.format("%s DOSE %d %%", c.name or "crew", pct(c.dose)) }
      end
    end
    local in_orbit = not f.landed and f.pe ~= nil and f.pe > 0
    local e = { id = f.fid, craft = true, fleet = f, name = f.name, body = f.body,
                kind = in_orbit and m.kindOrbit or m.kindFlat,
                rx = rec.x or 0, ry = rec.y or 0, rz = rec.z or 0, vx = rec.vx or 0, vy = rec.vy or 0, vz = rec.vz or 0,
                st = (fo.simTimeOf and fo.simTimeOf(rec)) or rec.stime or 0, conic = not f.landed and v == nil,
                node = v and v.node or nil, live = v ~= nil, piloted = f.piloted, landed = f.landed,
                splashed = rec.splashed == true, escaping = f.escaping, pe = f.pe, ap = f.ap, alt = f.alt,
                cap = f.cap, charge = f.charge, comms = f.comms, link = f.link, signal = f.signal, hops = f.hops,
                path = f.path, probe = f.probe, crewed = #crew > 0, crew = crew, crewAlerts = alerts,
                fuel = rec.fuel, fuelCap = m.fuelCap, status = f.status }
    if v and v.node and space and space.dominant then
      local n = v.node
      local bn = space.dominant(n.x, n.y, n.z)
      local b = bn and space.body(bn)
      if b then
        e.body, e.rx, e.ry, e.rz = bn, n.x - b.x, n.y - b.y, n.z - b.z
        -- (the node's velocity is already in its body's frame: rule 4)
        e.vx, e.vy, e.vz = n.vx or e.vx, n.vy or e.vy, n.vz or e.vz
        e.st = space.time and space.time() or e.st
      end
    end
    if e.body then
      local hd = home_dist(e.body, e.rx, e.ry, e.rz)
      e.homeWorld, e.dist = hd ~= nil, hd
    end
    -- (the rest of the attention table: the reactor's heat, the cabin, and a
    -- crewed craft coming down without its chutes open)
    if v then
      local okh, hud = pcall(function() return v.thermalHud and v.thermalHud() end)
      if okh and hud then e.heat, e.scram = hud.T or 0, hud.scrammed == true end
      if v.partHp and #m.seats > 0 then
        for _, s in ipairs(m.seats) do
          local okp, hp = pcall(v.partHp, s.uid)
          if okp and hp and (not e.cabin or hp < e.cabin) then e.cabin = hp end
        end
      end
      e.chutes = v.chutes_deployed == true
    end
    if e.crewed and not e.landed and e.pe and e.pe < 0 and e.body and space and space.body then
      local b = space.body(e.body)
      local T = b and orbitTimes(e.rx, e.ry, e.rz, e.vx, e.vy, e.vz, b.mu, b.radius)
      if T and T.tImpact then e.tImpact = T.tImpact - math.max(0, (space.time and space.time() or e.st) - e.st) end
    end
    -- (debris that is ours: a lost craft with no command part left)
    if e.kind == "debris" then e.kind = "probe" end
    -- (the recovery verdict raycasts and prices the parts: kept two seconds a
    -- craft, staggered, and asked again at once when the craft lands or lifts)
    local rc = rcache[f.fid]
    local now_t = time or 0
    if ts and ts.recoverCheck and not (rc and rc.landed == f.landed and now_t - rc.t < 2.0 + (#out % 4) * 0.25) then
      local probe_e = {}
      for k, val in pairs(f) do probe_e[k] = val end
      local ok, why = ts.recoverCheck(probe_e)
      rc = { t = now_t, landed = f.landed, r = { ok = ok, why = why } }
      if ok and ts.recoverQuote then
        local q = ts.recoverQuote(probe_e)
        rc.r.value, rc.r.factor, rc.r.dist, rc.r.near = q.value, q.factor, q.dist, q.near
      end
      rcache[f.fid] = rc
    end
    e.recover = rc and rc.r or nil
    e.attn = attention(e)
    out[#out + 1] = e
  end
end

local function crew_entries(out)
  local C = ref("crew")
  if not (C and C.roster) then return end
  local active = C.activeId and C.activeId()
  local ride = C.avatarCraft and C.avatarCraft() or nil
  for _, r in ipairs(C.roster()) do
    if r.status == "afoot" or r.status == "base" then
      local o2, hp, downed, rising = member_alerts(C, r.id, r)
      local e = { id = "m:" .. tostring(r.id), member = r.id, kind = "crew", name = r.name, status = r.status,
                  doseRising = rising,
                  body = r.body, rx = r.x, ry = r.y, rz = r.z, vx = 0, vy = 0, vz = 0, st = 0,
                  o2 = o2, hp = hp, downed = downed, active = (r.id == active and not ride) or false,
                  dose = tonumber(r.dose) or 0, lastAir = C.recordAlerts and C.recordAlerts[r.id] or nil,
                  role = C.roleLetter and C.roleLetter(r) or nil, busy = C.busy and C.busy(r) or nil }
      local node = C.bodyOf and C.bodyOf(r.id) or nil
      if node and node.valid ~= false then e.node = node end
      if r.status == "base" then e.rx = nil end
      if e.node and space and space.dominant then
        local n = e.node
        local bn = space.dominant(n.x, n.y, n.z)
        local b = bn and space.body(bn)
        if b then e.body, e.rx, e.ry, e.rz = bn, n.x - b.x, n.y - b.y, n.z - b.z end
      end
      if e.body and e.rx then e.dist = home_dist(e.body, e.rx, e.ry, e.rz) end
      e.attn = attention(e)
      out[#out + 1] = e
    end
  end
end

local function debris_entries(out)
  local dp = ref("debris_pack")
  if dp and dp.packedPoses then
    for _, d in ipairs(dp.packedPoses()) do
      out[#out + 1] = { id = "d:" .. tostring(d.id), kind = "debris", dkind = d.kind, name = d.name or "debris",
                        body = d.body, rx = d.x, ry = d.y, rz = d.z, vx = d.vx, vy = d.vy, vz = d.vz, st = d.stime,
                        conic = d.kind == "orbit", parts = d.parts }
    end
  end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    local n = v.node
    if n and n.valid ~= false and v.isLost and v.isLost() then
      out[#out + 1] = { id = "v:" .. tostring(n.id), kind = "debris", dkind = "wreck", name = (v.craftName or "wreck") .. " (lost)",
                        body = space.dominant(n.x, n.y, n.z), node = n, rx = 0, ry = 0, rz = 0, st = 0 }
    end
  end
end

local base_entries
-- (X7) a base's roles on its entry: the role key's filter, the glyph (its
-- strongest role's), the situation line ("⛁ FUEL · ⚒ MINE")
local function role_fields(e, roles, st, id)
  e.roles, e.bstats, e.baseIdx = roles, st, id
  local BR = ref("base_roles")
  if BR and BR.strongest and roles then
    local s = BR.strongest(roles)
    if #s > 0 then
      e.glyph = BR.GLYPH[s[1]]
      local bits = {}
      for i = 1, math.min(2, #s) do bits[#bits + 1] = BR.LABEL[s[i]] end
      e.roleText = table.concat(bits, " · ")
    end
  end
end
local function infra_entries(out)
  local net = ref("comms")
  if net and net.beaconList then
    for _, b in ipairs(net.beaconList()) do
      local gb = b.body and space.body(b.body)
      if gb and b.x then
        local e = { id = "b:" .. tostring(b.id), kind = "relay", name = b.name, body = b.body,
                    rx = b.x - gb.x, ry = b.y - gb.y, rz = b.z - gb.z, st = 0, link = b.linked, signal = b.strength,
                    hops = b.hops, path = b.names, beacon = b }
        e.dist = home_dist(b.body, e.rx, e.ry, e.rz)
        out[#out + 1] = e
      end
    end
  end
  local dep = ref("deployables")
  if dep and dep.list then
    for _, kind in ipairs({ "flag", "remains" }) do
      for _, f in ipairs(dep.list(kind) or {}) do
        local e = { id = (kind == "flag" and "f:" or "r:") .. tostring(f.id), kind = kind, name = f.n or (kind == "flag" and "Flag" or "Remains"),
                    body = f.b, rx = f.x, ry = f.y, rz = f.z, st = 0, date = f.d, flag = f, flagId = f.id }
        e.dist = f.b and home_dist(f.b, f.x or 0, f.y or 0, f.z or 0) or nil
        out[#out + 1] = e
      end
    end
  end
  local stc = ref("structures")
  if stc and stc.list then
    for _, r in ipairs(stc.list()) do
      out[#out + 1] = { id = "s:" .. tostring(r.id), kind = "structure", name = r.n or "Structure", body = r.b,
                        rx = r.x, ry = r.y, rz = r.z, st = 0, date = r.d, parts = #(r.bp or {}), by = r.by }
    end
  end
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if fp and fp.body then
    out[#out + 1] = { id = "base", kind = "base", name = "Spaceport", body = fp.body, rx = fp.x, ry = fp.y, rz = fp.z, st = 0 }
    local hr = save and save.get and save.get("bases.home")
    if type(hr) == "table" then role_fields(out[#out], hr.roles, hr.stats, 0) end
  end
  base_entries(out)
end

-- THE BASES (deep-space step 7, M5): each Base Station Tower's base, from
-- base_tower.bases() (the home base #0 is the spaceport entry above), as an
-- entry "o:<base id>" at its tower's ground point (body-relative).
base_entries = function(out)
  local bt = ref("base_tower")
  if not (bt and bt.bases) then return end
  local ok, list = pcall(bt.bases, { brief = true })
  if not ok or type(list) ~= "table" then return end
  for _, b in ipairs(list) do
    local gb = not b.home and b.body and space.body(b.body)
    if gb and b.gx then
      out[#out + 1] = { id = "o:" .. tostring(b.id), kind = "outpost", name = b.name, body = b.body,
                        rx = b.gx - gb.x, ry = b.gy - gb.y, rz = b.gz - gb.z, st = 0, outpost = b, baseId = b.id,
                        tier = b.tier, link = b.linked, signal = b.strength, hops = b.hops, path = b.via, date = b.founded }
      out[#out].dist = home_dist(b.body, out[#out].rx, out[#out].ry, out[#out].rz)
      role_fields(out[#out], b.roles, b.stats, b.id)
    end
  end
end

-- THE WORLDS (X1): one entry a body of the home system, its survey summary.
local function world_entries(out)
  local sv = ref("survey")
  local h = save and save.get and save.get("system.home")
  local list = type(h) == "table" and type(h.bodies) == "table" and h.bodies or {}
  local home = (save and save.get and save.get("base.body")) or (list[1] and list[1].name)
  local layers = (sv and sv.LAYERS) or {}
  for i, b in ipairs(list) do
    if type(b.name) == "string" then
      local r = sv and sv.record and sv.record(b.name) or nil
      local known, n = 0, 0
      for _, l in ipairs(layers) do n = n + 1; known = known + ((r and r.L and r.L[l]) or 0) end
      known = n > 0 and known / n or 0
      local parent = (b.parent and b.parent ~= h.star) and b.parent or nil
      out[#out + 1] = { id = "w:" .. b.name, kind = "body", name = b.name, body = b.name, rx = 0, ry = 0, rz = 0, st = 0,
                        world = true, ord = i, home = b.name == home, parent = parent, known = known,
                        surveyed = known >= 1 - 1e-9, visited = r and r.visited ~= nil, landedOn = r and r.landed ~= nil }
    end
  end
end

-- THE RUNS (expansion X3, scripts/route_ops.lua): one entry a run, "R:<id>",
-- kind `route`, group RUNS, anchored where the run puts its craft now
-- (routes.poseAt: the stand, a stop, or along the leg's recorded path —
-- body-relative; the map re-places it each frame from `run`). A waiting run
-- is an ATTENTION entry (amber) with the reason.
local function route_entries(out)
  local ro = ref("route_ops")
  if not (ro and ro.list) then return end
  for _, r in ipairs(ro.list() or {}) do
    local body, x, y, z = ro.poseNow(r)
    if body then
      local e = { id = "R:" .. tostring(r.id), kind = "route", route = true, run = r, runId = r.id, name = r.name, body = body,
                  rx = x, ry = y, rz = z, st = 0, cycles = r.cycles or 0, crewed = r.crewed == true, probe = not r.crewed,
                  rsub = ro.situationOf(r) }
      if r.state == "waiting" then
        e.attn = { level = "warn", text = "WAITING", all = { { level = "warn", text = tostring(r.why or "waiting") } } }
      end
      e.dist = home_dist(body, x, y, z)
      out[#out + 1] = e
    end
  end
end

local GROUP_ORDER = {}
for i, g in ipairs(GROUPS) do GROUP_ORDER[g] = i end

stats = { craft = 0, crew = 0, debris = 0, infra = 0, sort = 0, list = 0 }
function ema(k, v) stats[k] = (stats[k] or v) * 0.7 + v * 0.3 end
local function build()
  local out = {}
  craft_entries(out)
  pause()
  crew_entries(out)
  pause()
  debris_entries(out)
  infra_entries(out)
  route_entries(out)
  world_entries(out)
  local by = {}
  local counts = { craft = 0, linked = 0, relays = 0, debris = 0, crew = 0, attention = 0 }
  for _, e in ipairs(out) do
    e.glyph = e.glyph or GLYPHS[e.kind] or "◇"
    e.prio = PRIO[e.kind] or 20
    if e.attn then e.prio = e.prio + 15; counts.attention = counts.attention + 1 end
    e.sub = situation(e)
    e.num = keyNumber(e)
    e.group = groupOf(e)
    by[e.id] = e
    if e.craft then counts.craft = counts.craft + 1; if e.link then counts.linked = counts.linked + 1 end end
    if e.kind == "relay" then counts.relays = counts.relays + 1 end
    if e.kind == "debris" then counts.debris = counts.debris + 1 end
    if e.kind == "crew" then counts.crew = counts.crew + 1 end
  end
  table.sort(out, function(a, b)
    local ga, gb = GROUP_ORDER[a.group] or 99, GROUP_ORDER[b.group] or 99
    if ga ~= gb then return ga < gb end
    if (a.piloted or a.active) ~= (b.piloted or b.active) then return (a.piloted or a.active) == true end
    if a.kind == "body" and b.kind == "body" then return (a.ord or 0) < (b.ord or 0) end
    if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
    return tostring(a.id) < tostring(b.id)
  end)
  return out, by, counts
end

-- The snapshot, rebuilt when due. `force` rebuilds now.
-- THE BUILD IS SPREAD OVER FRAMES: a coroutine resumed once a call, which
-- pauses after every dozen craft and between the sections, so a rebuild of a
-- 50-craft fleet is a few short slices, not one 5 ms frame. The last finished
-- snapshot is served meanwhile. `force` (an action: a recovery, an opening)
-- runs it to the end at once.
local job = nil
local in_job = false
pause = function() if in_job and coroutine.isyieldable and coroutine.isyieldable() then coroutine.yield() elseif in_job then coroutine.yield() end end
local function finish(entries, by, counts, s, t)
  snap = { version = snap.version + 1, t = t, gt = space and space.time and space.time() or 0,
           entries = entries, byId = by, counts = counts }
  stamp = s
end
function snapshot(force)
  local t = time or 0
  local s = stamp_now()
  if job then
    in_job = true
    local ok, e1, e2, e3
    repeat
      local w0 = wall()
      ok, e1, e2, e3 = coroutine.resume(job.co)
      local ms = (wall() - w0) * 1000
      ema("slice", ms)
      if ms > (stats.sliceMax or 0) then stats.sliceMax = ms end
    until not force or coroutine.status(job.co) == "dead" or not ok
    in_job = false
    if not ok then job = nil; if log then log("fleet_view: build failed — " .. tostring(e1)) end return snap end
    if coroutine.status(job.co) == "dead" then
      finish(e1, e2, e3, job.s, job.t)
      job = nil
    end
    return snap
  end
  local due = force or t - snap.t >= RATE or (changed(s, stamp) and t - snap.t >= MIN_GAP)
    or (stamp and s[6] ~= stamp[6] and t - snap.t >= 0.25)
  if not due then return snap end
  if force or not coroutine then
    local entries, by, counts = build()
    finish(entries, by, counts, s, t)
    return snap
  end
  job = { co = coroutine.create(build), s = s, t = t }
  snap.t = t   -- (not due again while this one is under way)
  return snapshot(false)
end

function current() return snap end
-- Tests: forget the snapshot and the per-record cache.
function reset() snap = { version = 0, t = -1e9, entries = {}, byId = {}, counts = {} }; stamp = nil; meta = {}; rcache = {}; decodes = 0; job = nil end
-- (a recovery or a write-off: forget its verdict now)
function forgetVerdicts() rcache = {} end
