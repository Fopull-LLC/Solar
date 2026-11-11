-- THIRTY KILOMETRES: the scenario's hooks (scenarios/thirty_km, hooks =
-- "scn_thirty_km_hooks"; prefabs/scn_thirty_km_hooks.prefab.ron). scenario_run
-- spawns this and calls its globals with the scenario `api`: it reads the
-- world only through `api` (a craft's state, a part's health, a pack, where
-- someone is) and writes only the scenario's variables and beats.
-- docs/scenarios.md §6.
--
--   tick   4 Hz on the agency clock (game seconds):
--          RAY'S AIR. A record with a body breathes nothing in the game (a
--          CrewBody is never drawn down: crew.lua recordTick), and Ray's suit
--          is the clock of the night, so it is kept here, in seconds: his
--          knee seal tore when Asha-2 dropped its hub, so it bleeds at
--          LEAK × the suit's rate until Sunniva tapes it (`patched`), then at
--          the suit's own rate. Aboard Asha-1 he is on Sunniva's medical
--          bottle and fills back at FILL a second (its own battery runs the
--          regulator: not on a flat rover). Kit's spare bottle is RESERVE
--          more, once, if she is beside him when he runs low.
--          THE HUB. Ray pressed the bearing back in by hand; a hub pressed in
--          the field runs hot over HUB_V (20 km/h). Above it the heat climbs
--          by the excess (HUB_K a second per m/s), below it cools at
--          HUB_COOL; at 100 the hub lets go again: worn back to 0.12, Kit
--          stops where she is (the `hub_fails` sequence).
--          THE DRIVE: Asha-1's odometer, the lowest its battery got, and what
--          its lamps cost (the lamps' draw while lit: the night's price).
--   goals  what the card reads: the cell ready to go in, Ray's air, the
--          convoy's gap, everyone home.
local ME, RAY, KIT, DOC = "crew:Priestley", "crew:Castellanos", "crew:Nakamura", "crew:Berge"
local A1, A2 = "Asha-1", "Asha-2"
local CELL_UID, HUB_UID = 8, 2        -- Asha-2's traction cell and front-left hub (blueprint lines)
LEAK = 1.5          -- the torn seal: × the suit's rate
FILL = 3.0          -- s of air a second on Sunniva's bottle
RESERVE = 300       -- Kit's spare bottle, s
AIR_MAX = 1500
HUB_V = 5.5         -- m/s (20 km/h): a field-pressed bearing runs hot past it
HUB_K = 2.2
HUB_COOL = 1.5
LAMP_EC = 0.2       -- EC/s a lit floodlight draws (parts_registry `light`)

local last_t = nil
local function aboard(api, who, craft)
  local d = api.dist(who, "craft:" .. craft)
  return d ~= nil and d < 2.6
end

function tick(api, t)
  local dt = last_t and math.max(0, math.min(5, t - last_t)) or 0
  last_t = t
  if dt <= 0 then return end
  local done = api.var("debriefed")
  -- ── Ray's air ──
  if not done and api.var("air_on") then
    local air = api.var("ray_air") or 1380
    local c1 = api.craft(A1)
    if aboard(api, RAY, A1) and c1 and (c1.charge or 0) > 0.5 then
      air = math.min(AIR_MAX, air + FILL * dt)
    else
      air = air - dt * (api.var("patched") and 1.0 or LEAK)
    end
    -- Kit's spare bottle, once, when she is with him and he is low
    if air < 240 and not api.var("kit_bottle") then
      local dk = api.dist(KIT, RAY)
      if dk and dk < 4.0 then
        api.setVar("kit_bottle", true)
        air = air + RESERVE
        api.run("kit_bottle")
      end
    end
    air = math.max(0, air)
    api.setVar("ray_air", math.floor(air * 10 + 0.5) / 10)
    if air < (api.var("ray_min") or 1e9) then api.setVar("ray_min", math.floor(air)) end
    if air <= 0 and not api.var("ray_out") then
      api.setVar("ray_out", true)
      api.fail("Ray's suit ran dry on the far side of Barrow Ridge.")
    end
  end
  -- ── the hub, once Asha-2 rolls again ──
  if api.var("convoy") and not api.var("hub_failed") then
    local c2 = api.craft(A2)
    local v = c2 and c2.speed or 0
    local h = api.var("hub_heat") or 0
    if v > HUB_V then h = h + (v - HUB_V) * HUB_K * dt else h = math.max(0, h - HUB_COOL * dt) end
    api.setVar("hub_heat", math.floor(h * 10 + 0.5) / 10)
    if h >= 100 then
      api.setVar("hub_failed", true)
      api.beat({ wear = { craft = A2, uid = HUB_UID, hp = 0.12 } })
      api.beat({ drive = { craft = A2, stop = true } })
      api.run("hub_fails")
    end
  end
  -- ── Asha-1's night ──
  local c1 = api.craft(A1)
  if c1 and not done then
    if (c1.speed or 0) > 0.3 then api.setVar("dist_m", math.floor(((api.var("dist_m") or 0) + c1.speed * dt) * 10 + 0.5) / 10) end
    if (c1.cap or 0) > 0 then
      local pct = math.floor(100 * c1.charge / c1.cap + 0.5)
      api.setVar("a1_pct", pct)
      if pct < (api.var("a1_min") or 101) then api.setVar("a1_min", pct) end
    end
    if (c1.lit or 0) > 0 then
      api.setVar("lamp_ec", math.floor(((api.var("lamp_ec") or 0) + c1.lit * LAMP_EC * dt) * 10 + 0.5) / 10)
      api.setVar("lamp_secs", math.floor(((api.var("lamp_secs") or 0) + dt) * 10 + 0.5) / 10)
    end
  end
end

-- beats
function start_air(api) api.setVar("air_on", true) end
function convoy_on(api) api.setVar("convoy", true); api.setVar("hub_heat", 0) end
-- the spare cell goes in: out of the pack, Asha-2's batteries up
function fit_cell(api)
  api.beat({ give = { who = "Priestley", item = "tractionCell", n = -1 } })
  api.beat({ charge = { craft = A2, frac = 1.0 } })
  api.setVar("cell_in", true)
end

local function mmss(s)
  s = math.max(0, math.floor(s or 0))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

goals = {
  -- the cell can go in: the cradle mended, the new cell in the pack, at Asha-2
  cell_ready = function(g, api)
    if api.var("cell_in") then return true, "fitted" end
    local hp = api.partHp(A2, CELL_UID) or 0
    local has = (api.has("Priestley", "tractionCell") or 0) > 0
    local d = api.dist(ME, "craft:" .. A2)
    local near = d ~= nil and d < 3.5
    return hp > 0.9 and has and near, string.format("cradle %d %%, cell %s, %s", math.floor(hp * 100 + 0.5), has and "in your pack" or "not carried",
      near and "at Asha-2" or string.format("%.0f m from Asha-2", d or -1))
  end,
  cell_in = function(g, api) return api.var("cell_in") == true, api.var("cell_in") and "Asha-2 has power" or "the old cell is cooked" end,
  -- Caird's voice: Asha-1's own comms path (comms.statusOf), with Jonah aboard
  link_down = function(g, api)
    local c = api.craft(A1)
    return c ~= nil and c.link == 0 and aboard(api, ME, A1), c and (c.link == 1 and "linked" or "no path") or "no Asha-1"
  end,
  link_up = function(g, api)
    local c = api.craft(A1)
    return api.var("link_lost") == true and c ~= nil and c.link == 1, c and (c.link == 1 and "linked" or "no path") or "no Asha-1"
  end,
  -- the card's clock: always met, it is there to be read
  ray_air = function(g, api)
    local a = api.var("ray_air") or 0
    return true, "Ray's suit " .. mmss(a) .. (api.var("patched") and "" or " (leaking)")
  end,
  -- the convoy: Asha-2's gap and its hub
  convoy = function(g, api)
    local d = api.dist("craft:" .. A1, "craft:" .. A2)
    local h = api.var("hub_heat") or 0
    return true, string.format("Asha-2 %s m back, hub %d °", d and string.format("%.0f", d) or "?", math.floor(40 + h * 0.9))
  end,
}
