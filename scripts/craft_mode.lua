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
-- flight), or leaves it on AUTO, which reads the whole craft (autoOf). The
-- choice rides on the blueprint (`bp.ctrl`) and on every command part's record
-- (`ctrl`), which is what a fleet save, a staging or a docking carry along;
-- no `ctrl` anywhere is Auto.
--
--   MODES                  { "auto", "rover", "aircraft", "rocket" }, panel order
--   LABEL[m]               "Auto", "Rover", "Aircraft", "Rocket"
--   normalize(m)           "rover" | "aircraft" | "rocket" | nil (auto, or junk)
--   isCommand(rec)         a pod, cockpit, probe core, rover body or seat
--   setOf(recs, cmd_uid, gone)
--                          the player's choice: the command part's `ctrl`, else
--                          any command part's (lowest uid), else nil
--   autoOf(recs, gone)     what Auto makes of the craft: mode, why, figures
--   resolve(recs, cmd_uid, gone)
--                          mode, set (nil = Auto), auto, why
--   describe(set, auto)    "Rover" | "Auto: Rover" — what a panel says

MODES = { "auto", "rover", "aircraft", "rocket" }
LABEL = { auto = "Auto", rover = "Rover", aircraft = "Aircraft", rocket = "Rocket" }
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

function setOf(recs, cmd_uid, gone)
  local by = nil
  if cmd_uid then
    each(recs, gone, function(d, u) if u == cmd_uid then by = d end end)
    local m = by and normalize(by.ctrl)
    if m then return m end
  end
  local best, bu = nil, nil
  each(recs, gone, function(d, u)
    local m = normalize(d.ctrl)
    if m and isCommand(d) and (not bu or u < bu) then best, bu = m, u end
  end)
  return best
end

function autoOf(recs, gone)
  local S, m, wheels, gear, jets, rover = 0, 0, 0, 0, 0, false
  each(recs, gone, function(d)
    local a = spec(d.af)
    m = m + num(d.mass) + num(d.fuel) * ((d.fuel_t ~= nil) and num(d.fuel_t) or FUEL_T)
    if a and a.wing then
      local span, root = num(a.span), num(a.root)
      local tip = (a.tip ~= nil) and num(a.tip) or root
      S = S + span * (root + tip) / 2
    end
    if a and a.jet then jets = jets + 1 end
    local w = wheel_of(d, a)
    if w then
      wheels = wheels + 1
      if w == "gear" then gear = gear + 1 end
    end
    if flag(d.front) or flag(d.seat) then rover = true end
  end)
  local lift = S / math.max(m, 0.05)
  local fig = { lift = lift, area = S, mass = m, wheels = wheels, gear = gear, jets = jets }
  if lift >= AUTO_LIFT or (jets > 0 and lift >= AUTO_LIFT_JET) then
    return "aircraft", string.format("wings carry it (%.1f m²/t)", lift), fig
  end
  if wheels >= 3 or (wheels >= 2 and rover) then
    return "rover", string.format("%d wheels carry it", wheels), fig
  end
  if wheels > 0 then return "rocket", "too few wheels to drive on", fig end
  return "rocket", "no wings, no wheels", fig
end

-- The mode the craft flies by: the player's, or Auto's reading of it.
function resolve(recs, cmd_uid, gone)
  local set = setOf(recs, cmd_uid, gone)
  local auto, why = autoOf(recs, gone)
  return set or auto, set, auto, why
end

function describe(set, auto)
  set = normalize(set)
  if set then return LABEL[set] end
  return "Auto: " .. (LABEL[auto or "rocket"] or "?")
end
