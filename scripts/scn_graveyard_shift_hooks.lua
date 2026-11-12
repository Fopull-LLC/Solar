-- GRAVEYARD SHIFT: the scenario's hooks (scenarios/graveyard_shift, hooks =
-- "scn_graveyard_shift_hooks"; prefabs/scn_graveyard_shift_hooks.prefab.ron).
-- scenario_run spawns this and calls its globals with the scenario `api`: it
-- reads the world only through `api` (the plant, a piece, a dose) and writes
-- only the scenario's variables and beats. docs/scenarios.md §6.
--
--   tick     4 Hz on the agency clock: reads the plant and the four pieces
--            the scenario watches ONCE (the goals and events below read that
--            snapshot), and keeps the shift's meters: energy to the grid, the
--            player's dose, the fuel's peak once the core is shut down after
--            the break. And FW-2's bearing: a bearing is not in the S6 model,
--            so this is its temperature, from Dana's 61 °C at 22:47, climbing
--            while the pump turns and seizing at 115 °C
--   goals    what the card reads: the bearings, the turbine, FW-2, the makeup
--            line, the weld, the refill
local S, ME = "Kerne Station", "Halloran"
local FW2, PL7, MU1, P3 = 147, 109, 114, 116
local SEIZE = 115
local PEAK_AFTER = 20     -- s after the break before the fuel's peak counts (its running heat leaves first)

-- this tick's snapshot
local R, PC = nil, {}
local last_t = nil

local function snap(api)
  R = api.reactor(S)
  PC.fw2 = api.piece(S, FW2) or {}
  PC.pl7 = api.piece(S, PL7) or {}
  PC.mu1 = api.piece(S, MU1) or {}
  PC.p3 = api.piece(S, P3) or {}
end

function tick(api, t)
  snap(api)
  local dt = last_t and math.max(0, math.min(5, t - last_t)) or 0
  last_t = t
  if R then
    if (R.genKW or 0) > 0 and dt > 0 then api.setVar("kwh", (api.var("kwh") or 0) + R.genKW * dt / 3600) end
    if R.protection and not api.var("prot_ok") then api.setVar("prot_ok", true) end
    if api.var("loca") then
      local tb = api.var("break_t")
      if not tb then api.setVar("break_t", t); tb = t end
      if t - tb >= PEAK_AFTER then
        local pk = api.var("peak_k") or 0
        if (R.fuelK or 0) > pk then api.setVar("peak_k", math.floor(R.fuelK + 0.5)) end
      end
    end
  end
  -- (1.0 of a lethal dose taken as 5 Sv)
  local d = api.dose(ME) or 0
  local d0 = api.var("dose0")
  if d0 == nil then api.setVar("dose0", d); d0 = d end
  local msv = math.max(0, (d - d0) * 5000)
  if math.abs(msv - (api.var("dose_msv") or 0)) >= 0.05 then api.setVar("dose_msv", math.floor(msv * 10 + 0.5) / 10) end
  -- the bearing
  if api.var("brg_t0") and not api.var("brg_fixed") and dt > 0 then
    local p = PC.fw2
    local T = api.var("brg") or 61
    if p.knocked then
      -- (out of its housing: nothing to read)
    elseif p.pumpOn ~= false then
      T = T + 0.085 * dt * (1 + (T - 58) / 120)
      if T >= SEIZE and not api.var("seized") then
        api.setVar("seized", true)
        api.beat({ knock = { struct = S, uid = FW2, lean = 0, label = "Swap FW-2's seized bearing cartridge", secs = 30 } })
      end
    else
      T = 40 + (T - 40) * math.exp(-dt / 300)
    end
    api.setVar("brg", math.floor(T * 10 + 0.5) / 10)
    -- (playtest 11-11) the bearing heard at the skid: plant_av's rattle on FW-2,
    -- from a whisper at 61 °C to a grinding knock near seizing, while it turns
    if api.stress then api.stress(S, FW2, "bearing", (not p.knocked and p.pumpOn ~= false) and math.max(0, math.min(1, (T - 50) / (SEIZE - 50))) or 0) end
    if api.var("knocked_seen") and not p.knocked then api.setVar("brg_fixed", true); api.setVar("brg", 38) end
    if p.knocked then api.setVar("knocked_seen", true) end
  end
  -- when the reactor went down after the break (Dana's patience runs from it)
  if api.done("loca") and not api.var("loca_t") then api.setVar("loca_t", t) end
end

-- beats
function bearing_start(api) api.setVar("brg_t0", api.now()); api.setVar("brg", 61) end
function at_break(api)
  local r = api.reactor(S)
  api.setVar("prot_at_break", r and r.protection == true or false)
end

-- goals (they read the tick's snapshot; before the first tick they read it fresh)
goals = {}
local G = goals
local function ready(api) if not R then snap(api) end end
function G.bearing_read(g, api)
  ready(api)
  local T = api.var("brg") or 56
  local p = PC.fw2
  local fw1 = 38 + math.floor((api.now() % 7) / 3.5)
  local vib = 2.1 + math.max(0, T - 40) * 0.09
  local up = (api.var("brg_t0") and p.pumpOn ~= false and not api.var("brg_fixed")) and " ▲" or ""
  local txt = string.format("FW-1 %d °C · FW-2 %.0f °C%s · %.1f mm/s", fw1, T, up, vib)
  if api.var("seized") then txt = "FW-1 39 °C · FW-2 SEIZED" end
  return api.var("diag") == "fw2", txt
end
function G.turbine_on(g, api)
  ready(api)
  if not R then return false, "no plant" end
  return R.turbine and (R.genKW or 0) > 3, string.format("%s · %.1f kW(e)", R.turbine and "on line" or "off line", R.genKW or 0)
end
function G.fw2_off(g, api)
  ready(api)
  local p = PC.fw2
  return p.pumpOn == false, p.pumpOn == false and "isolated" or "running"
end
function G.fw2_on(g, api)
  ready(api)
  local p = PC.fw2
  return p.pumpOn ~= false and not p.knocked, p.knocked and "out of its housing" or (p.pumpOn == false and "off" or "running")
end
local function makeup_on() return (not PC.mu1.shut) and (not PC.p3.off) end
function G.makeup(g, api)
  ready(api)
  return makeup_on() and api.var("loca") == true, string.format("P-3 %s · MU-1 %s", PC.p3.off and "off" or "running", PC.mu1.shut and "shut" or "open")
end
function G.welded(g, api)
  ready(api)
  local brk = tonumber(PC.pl7.brk) or 0
  return api.var("loca") == true and brk <= 0, brk > 0 and string.format("broken (%.0f %% of the bore)", brk * 100) or "whole"
end
function G.covered(g, api)
  ready(api)
  if not R then return false, "no plant" end
  local ok = api.var("loca") == true and (R.inventory or 0) >= 0.6 and (R.fuelK or 999) < 650
  return ok, string.format("inventory %.0f %% · fuel %.0f K", (R.inventory or 0) * 100, R.fuelK or 0)
end
function G.inv_below(g, api)
  ready(api)
  return R ~= nil and api.var("loca") == true and (R.inventory or 1) < (g.below or 0.5), ""
end
function G.fuel_above(g, api)
  ready(api)
  local tb = api.var("break_t")
  return R ~= nil and tb ~= nil and api.now() - tb >= PEAK_AFTER and (R.fuelK or 0) > (g.above or 700), ""
end
function G.dana_should_act(g, api)
  local t0 = api.var("loca_t")
  if not (api.var("woke") and t0) then return false, "" end
  ready(api)
  return (not makeup_on()) and api.now() - t0 > (g.secs or 80), ""
end
