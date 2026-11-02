-- CRAFT_MODE — how a craft is driven: as a ROVER, an AIRCRAFT or a ROCKET.
--
-- A pure rulebook (no scene access), shared by the builder (which shows the
-- choice and what Auto makes of the craft) and vessel_controller (which flies
-- by it). It rides the CraftModeLib node, spawned on demand by either side
-- when the scene carries none, and is reached with findScript("craft_mode");
-- under luajit it loads from disk (tests/smoke_craft_mode.lua).
--
-- THE MODE, not the parts, says what the wheels do (playtest 2026-10-26: "i
-- may want to use landing gear as a rover wheel ... and if on a jet craft i
-- add a rover wheel i should be able to use that as the wheels on my plane"):
--
--   rover     every wheel, landing gear too, is driven and steered by the
--             rover drive: W/S drive, A/D steer, B brakes, and in the air the
--             rover's keys lean it. Landing gear still folds on G; folded, it
--             is no wheel at all until it comes down again.
--   aircraft  every wheel, a rover wheel too, is the plane's gear: it rolls
--             free, brakes on B, the front ones steer with the rudder, and the
--             stick flies the craft. (A rover wheel can't fold: that is what
--             landing gear is for.)
--   rocket    the wheels are passive (they roll and brake); the stick turns
--             the craft.
--
-- The player picks one in the builder (or from the command part's menu in
-- flight), or leaves it on AUTO (autoOf).
--
-- SECTIONS (2026-11: "a ship that deploys a rover: is the rover going to
-- switch to rover control when you pilot it? a jet that drops a ship?"). A
-- craft divides into sections at its decouplers and docking ports: the cut is
-- a separating part's joint to its parent (SPLIT.sides cuts there too; a
-- separating part at the tree's root cuts every joint to its children). What
-- stays rigidly on through any other joint (a stack, a weld, a hinge) is one
-- section. Auto reads the section of the command part the craft is flown from,
-- not the whole stack:
--   * a ship with a rover in its bay is a rocket while you fly the ship, and
--     the rover is a rover once it is away (or flown from its own body);
--   * a jet carrying a rocket is an aircraft, the released rocket a rocket.
-- The wings must still carry everything attached: the lift test divides the
-- section's wing area by the WHOLE craft's mass (a shuttle's orbiter on its
-- tank is a rocket until the tank goes).
-- The player's choice is per section too: it rides on that section's command
-- parts' records (`ctrl`), which a fleet save, a staging or a docking carry
-- along; no `ctrl` in a section is Auto there. (Builds before this put one
-- choice on the blueprint, `bp.ctrl`, and on EVERY command part: legacy()
-- keeps it for the main section only.)
--
--   MODES                  { "auto", "rover", "aircraft", "rocket" }, panel order
--   LABEL[m]               "Auto", "Rover", "Aircraft", "Rocket"
--   normalize(m)           "rover" | "aircraft" | "rocket" | nil (auto, or junk)
--   isCommand(rec)         a pod, cockpit, probe core, rover body or seat
--   isSeparator(rec)       a decoupler (axial or radial) or a docking port
--   sections(recs, gone)   { of = uid → section id, parts = id → { uid… },
--                          cmds = id → { command uid… } } (ids: lowest uid)
--   sectionOf(recs, uid, gone)  the set (uid → true) of uid's section
--   setOf(recs, cmd_uid, gone, only)
--                          the player's choice: the command part's `ctrl`, else
--                          any command part's in its section (lowest uid), else
--                          nil. `only` (a set) limits the search; nil = all.
--   autoOf(recs, gone, only)
--                          what Auto makes of the craft (or of the section
--                          `only`, whose wings lift the whole craft's mass):
--                          mode, why, figures
--   resolve(recs, cmd_uid, gone)
--                          mode, set (nil = Auto), auto, why, section — of the
--                          section cmd_uid is in (no cmd_uid: the whole craft)
--   perSection(recs, gone, primary)
--                          { { cmd, cmds, parts, set, auto, why, mode }… } for
--                          each section with a command part; primary's first
--   setSection(recs, cmd_uid, m, gone)
--                          the choice m (nil = Auto) on cmd_uid's section's
--                          command parts only; returns how many it wrote
--   legacy(recs, m, keep_uid, gone)
--                          an old craft's one choice (bp.ctrl, copied on every
--                          command part): kept on keep_uid's section only
--   describe(set, auto)    "Rover" | "Auto: Rover" — what a panel says
--   short(set, auto)       "Rover" | "Auto (Rover)"
--   notice(mode)           "Mode: Rover — W/S drive" (said on a change)

MODES = { "auto", "rover", "aircraft", "rocket" }
LABEL = { auto = "Auto", rover = "Rover", aircraft = "Aircraft", rocket = "Rocket" }
HINT = {
  rover = "W/S drive, A/D steer",
  aircraft = "the stick flies it",
  rocket = "the stick turns it",
}
TIP = {
  auto = "Read the craft: wings that can carry it fly it as an aircraft, wheels that can carry it drive it as a rover, anything else is a rocket",
  rover = "Every wheel (landing gear too) drives and steers: W/S A/D, brakes B; gear still folds on G",
  aircraft = "Every wheel (rover wheels too) is landing gear: rolls free, brakes B, nose steers with the rudder; the stick flies it",
  rocket = "The wheels only roll and brake; the stick turns the craft",
}

-- AUTO'S RULE. The question is "what carries this craft?", asked of the whole
-- craft, never of one part, so a rover with one landing gear on it is still a
-- rover and a plane on rover wheels is still a plane:
--   1. WINGS. The lifting area (every wing and control surface, span × mean
--      chord) per tonne of the craft, full tanks. AUTO_LIFT m²/t is a wing
--      that holds the craft up below ~75 m/s at a lift coefficient of 1 in
--      sea-level air (the stock light jet has ~7). With an air-breathing
--      engine aboard, a jet that only needs its wings to rotate, AUTO_LIFT_JET
--      will do. → aircraft
--   2. WHEELS. Three or more wheels (any kind: a landing gear counts the
--      same as a rover wheel), or two on a craft with a rover body or a seat
--      (a bike). → rover
--   3. Anything else (no wheels, or one stray one) → rocket.
-- A decorative wing on a rover is far under AUTO_LIFT; a rocket's fins are
-- not wings here (they steady it, they don't carry it).
AUTO_LIFT = 3.0         -- m² of wing per tonne: it flies
AUTO_LIFT_JET = 1.0     -- …with a jet aboard
FUEL_T = 0.01           -- t a unit of propellant, when a record doesn't say

local function num(v) v = tonumber(v); return (v and v == v) and v or 0 end
local function flag(v) return v == true or v == 1 end

function normalize(m)
  if m == "rover" or m == "aircraft" or m == "rocket" then return m end
  return nil
end

-- (the aero spec's words, as aero.lua's parse reads them)
local function spec(s)
  if type(s) ~= "string" or s == "" then return nil end
  local t = {}
  for tok in s:gmatch("%S+") do
    local k, v = tok:match("^([%w_]+)=(.*)$")
    if k then t[k] = tonumber(v) or v else t[tok] = true end
  end
  return t
end

function isCommand(d)
  if type(d) ~= "table" then return false end
  return d.kind == "crewed" or d.kind == "probe" or flag(d.seat) or flag(d.front)
end

function isSeparator(d)
  return type(d) == "table" and (flag(d.decouple) or flag(d.dock))
end

-- The wheel a record is, or nil: "gear" (a landing gear) or "wheel".
local function wheel_of(d, a)
  if a and a.gear then return "gear" end
  if type(d.wheel) == "string" and d.wheel ~= "" then return "wheel" end
  return nil
end

local function each(recs, gone, fn)
  for k, d in pairs(recs or {}) do
    local u = type(d) == "table" and (d.uid or k) or nil
    if u and not (gone and gone[u]) then fn(d, u) end
  end
end

-- THE SECTIONS. Joints run child → parent (the blueprint tree, made whole by
-- SPLIT.normalize in flight). A joint is cut where the child is a separating
-- part, or where the parent is one at the tree's root. A gone part still holds
-- its section together (what is left of it is still bolted on); it only stops
-- counting. Records with no tree at all (no `parent` anywhere: a flat list)
-- are one section.
local function uid_of(k, d) return type(d) == "table" and (d.uid or k) or nil end
function sections(recs, gone)
  local by, list = {}, {}
  for k, d in pairs(recs or {}) do
    local u = uid_of(k, d)
    if u then by[u] = d; list[#list + 1] = u end
  end
  table.sort(list)
  local up = {}
  local function find(u)
    local r = u
    while up[r] and up[r] ~= r do r = up[r] end
    while up[u] and up[u] ~= r do local n = up[u]; up[u] = r; u = n end
    return r
  end
  local function join(a, b)
    local ra, rb = find(a), find(b)
    if ra == rb then return end
    if ra < rb then up[rb] = ra else up[ra] = rb end
  end
  for _, u in ipairs(list) do up[u] = u end
  local roots = {}
  for _, u in ipairs(list) do
    local d = by[u]
    local p = tonumber(d.parent) or 0
    if p ~= 0 and by[p] then
      local pp = tonumber(by[p].parent) or 0
      local proot = pp == 0 or not by[pp]
      if not isSeparator(d) and not (isSeparator(by[p]) and proot) then join(u, p) end
    else
      roots[#roots + 1] = u
    end
  end
  -- (loose roots ride with the first: a flat list, or a part the tree lost)
  local r1 = nil
  for _, u in ipairs(roots) do
    if not isSeparator(by[u]) then
      if r1 then join(r1, u) else r1 = u end
    end
  end
  local out = { of = {}, parts = {}, cmds = {} }
  for _, u in ipairs(list) do
    local s = find(u)
    out.of[u] = s
    out.parts[s] = out.parts[s] or {}
    local pl = out.parts[s]
    pl[#pl + 1] = u
    if isCommand(by[u]) and not (gone and gone[u]) then
      out.cmds[s] = out.cmds[s] or {}
      local cl = out.cmds[s]
      cl[#cl + 1] = u
    end
  end
  return out
end
function sectionOf(recs, uid, gone)
  local S = sections(recs, gone)
  local s = S.of[uid]
  if not s then return nil end
  local set = {}
  for _, u in ipairs(S.parts[s]) do set[u] = true end
  return set, S
end

function setOf(recs, cmd_uid, gone, only)
  local by = nil
  if cmd_uid then
    each(recs, gone, function(d, u) if u == cmd_uid then by = d end end)
    local m = by and normalize(by.ctrl)
    if m then return m end
  end
  local best, bu = nil, nil
  each(recs, gone, function(d, u)
    if only and not only[u] then return end
    local m = normalize(d.ctrl)
    if m and isCommand(d) and (not bu or u < bu) then best, bu = m, u end
  end)
  return best
end

function autoOf(recs, gone, only)
  local S, m, wheels, gear, jets, rover, rockets = 0, 0, 0, 0, 0, false, 0
  local carried = 0
  each(recs, gone, function(d, u)
    local dm = num(d.mass) + num(d.fuel) * ((d.fuel_t ~= nil) and num(d.fuel_t) or FUEL_T)
    carried = carried + dm
    if only and not only[u] then return end
    local a = spec(d.af)
    m = m + dm
    if a and a.wing then
      local span, root = num(a.span), num(a.root)
      local tip = (a.tip ~= nil) and num(a.tip) or root
      S = S + span * (root + tip) / 2
    end
    if a and a.jet then jets = jets + 1 elseif num(d.thrust) > 0 then rockets = rockets + 1 end
    local w = wheel_of(d, a)
    if w then
      wheels = wheels + 1
      if w == "gear" then gear = gear + 1 end
    end
    if flag(d.front) or flag(d.seat) then rover = true end
  end)
  -- (the wings lift everything attached, the other sections too)
  local lift = S / math.max(carried, 0.05)
  local fig = { lift = lift, area = S, mass = m, carried = carried, wheels = wheels, gear = gear, jets = jets }
  if lift >= AUTO_LIFT or (jets > 0 and lift >= AUTO_LIFT_JET) then
    return "aircraft", string.format("wings carry it (%.1f m²/t)", lift), fig
  end
  -- (two driven wheels and no rocket engine is a motorcycle, whatever
  -- commands it: a Probe Core and a Balance Gyro ride as well as a saddle)
  if wheels >= 3 or (wheels >= 2 and (rover or (rockets == 0 and wheels - gear >= 2))) then
    return "rover", string.format("%d wheels carry it", wheels), fig
  end
  if S > 0 and carried > m + 1e-6 then
    return "rocket", string.format("its wings can't lift what it carries (%.1f m²/t)", lift), fig
  end
  if wheels > 0 then return "rocket", "too few wheels to drive on", fig end
  return "rocket", "no wings, no wheels", fig
end

-- The mode the craft flies by, from command part cmd_uid: the player's choice
-- for its section, or Auto's reading of that section.
function resolve(recs, cmd_uid, gone)
  local only = nil
  if cmd_uid then only = sectionOf(recs, cmd_uid, gone) end
  local set = setOf(recs, cmd_uid, gone, only)
  local auto, why = autoOf(recs, gone, only)
  return set or auto, set, auto, why, only
end

-- Every section that can be flown (has a command part), primary's first,
-- then by lowest command uid.
function perSection(recs, gone, primary)
  local S = sections(recs, gone)
  local out = {}
  for s, cl in pairs(S.cmds) do
    local only = {}
    for _, u in ipairs(S.parts[s]) do only[u] = true end
    local cmd = cl[1]
    if primary and only[primary] and isCommand(recs[primary] or {}) then cmd = primary end
    local set = setOf(recs, cmd, gone, only)
    local auto, why, fig = autoOf(recs, gone, only)
    out[#out + 1] = { cmd = cmd, cmds = cl, parts = only, set = set, auto = auto, why = why, fig = fig,
                      mode = set or auto, primary = primary ~= nil and only[primary] == true }
  end
  table.sort(out, function(a, b)
    if a.primary ~= b.primary then return a.primary end
    return a.cmds[1] < b.cmds[1]
  end)
  return out
end

-- The player's choice on one section: every command part in it carries it
-- (whichever of them the craft is flown from), none outside it.
function setSection(recs, cmd_uid, m, gone)
  m = normalize(m)
  local only = cmd_uid and sectionOf(recs, cmd_uid, gone)
  if not only then return 0 end
  local n = 0
  each(recs, nil, function(d, u)
    if only[u] and isCommand(d) then d.ctrl = m; n = n + 1 end
  end)
  return n
end

-- An old craft's single choice (`bp.ctrl`, written on every command part):
-- it was made for the craft as flown, so it stays on keep_uid's section and
-- leaves the others' command parts (where it was only a copy) on Auto.
function legacy(recs, m, keep_uid, gone)
  m = normalize(m)
  if not m then return 0 end
  local only = keep_uid and sectionOf(recs, keep_uid, gone)
  local n = 0
  each(recs, nil, function(d, u)
    if isCommand(d) then
      if only and only[u] then
        if not normalize(d.ctrl) then d.ctrl = m; n = n + 1 end
      elseif d.ctrl == m then d.ctrl = nil; n = n + 1 end
    end
  end)
  return n
end

function describe(set, auto)
  set = normalize(set)
  if set then return LABEL[set] end
  return "Auto: " .. (LABEL[auto or "rocket"] or "?")
end
function short(set, auto)
  set = normalize(set)
  if set then return LABEL[set] end
  return "Auto (" .. (LABEL[auto or "rocket"] or "?") .. ")"
end
function notice(mode)
  mode = normalize(mode) or "rocket"
  return "Mode: " .. LABEL[mode] .. " — " .. HINT[mode]
end
