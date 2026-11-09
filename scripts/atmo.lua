-- ATMO — what a world's air is made of, and whether you can breathe it
-- (expansion plan X2, PLAN §6; docs/crew-and-items.md §11).
--
-- Every world with air gets `world.<name>.air` (system_generator.publishWorld):
--
--   air = { p0 (bar at the datum), T0 (K), gases = { N2, O2, Ar, CO2, CH4, SO2,
--           H2O, H2 … fractions summing to 1 }, o2 (= gases.O2), choice (the
--           home world's AIR pick, else nil), legacy (true on a save made
--           before air was chosen: see OLD SAVES) }
--
-- THE PRESSURE is the world's density by the one formula there is,
-- p0 = atmo / ATMO_REF bar (aero.lua's ATMO_REF: the density that means sea-
-- level air), never set twice. At height it falls off as the aero model's
-- air does (aero.airShare), so ppO2(alt) = p0 · share(alt) · O2.
--
-- THE TEMPLATES by planet type (TEMPLATES): Earth-like worlds hold N2/O2
-- with the oxygen set by its PARTIAL PRESSURE (0.21 bar at the datum, a
-- dune sea's 0.18), so a thin or thick Earth-like world breathes the same at
-- its sea level; a greenhouse is CO2 with SO2, a hydrocarbon world N2 and
-- methane, a red desert Mars's CO2, a sulfur plain SO2. The AIR choice
-- (`g_air`) overrides the HOME world's oxygen and nothing else.
--
-- THE AIR CHOICE (menu_newsave's AIR row): earth (0.21 bar O2) · rich
-- (0.35 bar) · thin (0.12 bar: a mask) · alien (no oxygen: a suit world) ·
-- random. Random leans breathable: RANDOM_BREATHE (60 %, Ty 2026-11-09) of
-- home seeds give an Earth-like, rich or thin air, the rest the world's own
-- unbreathable mix; the roll is the home seed's alone (resolveChoice), so a
-- reload rolls the same. A breathable choice on an alien home also keeps the
-- world in the suit's temperature band (system_generator alienHomeWorld:
-- BREATHE_T, BREATHE_TYPES), or the helmet could never come off.
--
-- BREATHABLE (breathable(air, share, tK)) → ok, why, info:
--   no air under 0.05 bar · SO2 over 10 µbar, CO2 over CO2_MAX (0.02 bar,
--   room_air's line), CH4 over 0.05 bar or NH3 over 50 µbar: TOXIC, the gas
--   named (the helmet is forced on) · ppO2 over 0.5 bar: oxygen poisoning ·
--   ppO2 under HYPOX (0.10): too thin, the helmet stays on · ppO2 between
--   HYPOX and O2_MIN (0.16): THIN — the helmet may come off, but without the
--   O2 Mask (items.lua o2mask) the crew slowly suffer hypoxia (the scene half
--   below) · else breathable. The temperature is the suit's own rule.
--
-- OLD SAVES. A save with no `g_air` was made before any of this: its worlds'
-- air is still published (the survey shows it), marked `legacy`, and every
-- reader keeps today's yes/no rule for it (aero.OXY by type, suit.lua's thin-
-- air share): nobody wakes up to find the home world has stopped being
-- breathable. `legacyOxygen(w)` is that rule, for the readers.
--
-- THE SCENE HALF (on the System Generator node; 1 Hz, nothing per frame):
--   * THE SPACEPORT REFILLS THE SUIT: within REFILL_R of the Command
--     building's door (or inside it) the suit's air is topped up, as a craft
--     does; on a world with no breathable air the HUD says so once.
--   * THIN AIR: bare-headed in thin air, an O2 Mask in the pack feeds a
--     cannula from the suit at MASK_DRAW of the suit's rate; without one the
--     crew lose HYPOX_HP of their health a minute ("thin air · mask").
--
-- Pure: TEMPLATES, p0Of, roll, resolveChoice, breathable, legacyOxygen,
-- jetOxygen, gasesText; loads under luajit (tests/smoke_atmo.lua).

ATMO_REF = 0.75              -- aero.lua: the world record's `atmo` that means 1 bar at the datum
O2_EARTH = 0.21              -- bar of O2 an Earth-like world holds at its datum
O2_MIN = 0.16                -- bar: under this the air is THIN (room_air.O2_MIN)
HYPOX = 0.10                 -- bar: under this the helmet stays on
O2_MAX = 0.50                -- bar: oxygen poisoning over this
CO2_MAX = 0.02               -- bar (room_air.CO2_MAX)
SO2_MAX = 1e-5               -- bar
CH4_MAX = 0.03               -- bar (60 % of its lower flammable limit at 1 bar)
NH3_MAX = 5e-5               -- bar
P_MIN = 0.05                 -- bar: less than this is no air
RANDOM_BREATHE = 0.60        -- Ty 2026-11-09: alien homes are random, 60 % breathable
CHOICES = { "earth", "rich", "thin", "alien", "random" }
CHOICE_O2 = { earth = 0.21, rich = 0.35, thin = 0.12 }
-- the temperature band a breathable alien home is kept in (inside suit.lua's 228–330 K)
BREATHE_T = { 240, 315 }

-- Each template: gases (fractions; O2 here is replaced by the partial-
-- pressure rule when `ppO2` is set), and `ppO2` (bar of O2 at the datum).
local EARTH = { N2 = 0.7808, O2 = 0.2095, Ar = 0.0093, CO2 = 0.0004 }
TEMPLATES = {
  earth       = { gases = EARTH, ppO2 = 0.21 },
  archipelago = { gases = { N2 = 0.776, O2 = 0.2095, Ar = 0.0093, CO2 = 0.0004, H2O = 0.0048 }, ppO2 = 0.21 },
  verdant     = { gases = { N2 = 0.774, O2 = 0.2095, Ar = 0.0093, CO2 = 0.0006, H2O = 0.0066 }, ppO2 = 0.21 },
  alpine      = { gases = EARTH, ppO2 = 0.21 },
  steppe      = { gases = EARTH, ppO2 = 0.21 },
  tundra      = { gases = { N2 = 0.781, O2 = 0.2095, Ar = 0.0093, CO2 = 0.0002 }, ppO2 = 0.20 },
  dune        = { gases = { N2 = 0.79, O2 = 0.19, Ar = 0.012, CO2 = 0.004, H2O = 0.0004 }, ppO2 = 0.18 },
  -- (no oxygen worth the name)
  greenhouse  = { gases = { CO2 = 0.965, N2 = 0.0348, SO2 = 0.00015, H2O = 0.00002 } },
  titan       = { gases = { N2 = 0.947, CH4 = 0.049, H2 = 0.001, Ar = 0.003 } },
  ironred     = { gases = { CO2 = 0.951, N2 = 0.028, Ar = 0.019, O2 = 0.0016, CO = 0.0004 } },
  canyon      = { gases = { CO2 = 0.93, N2 = 0.045, Ar = 0.022, O2 = 0.003 } },
  saltflat    = { gases = { N2 = 0.62, CO2 = 0.33, Ar = 0.045, O2 = 0.005 } },
  glacial     = { gases = { N2 = 0.91, Ar = 0.045, CH4 = 0.03, CO2 = 0.015 } },
  crystal     = { gases = { N2 = 0.58, CO2 = 0.31, Ar = 0.08, NH3 = 0.0002, O2 = 0.0298 } },
  volcanic    = { gases = { CO2 = 0.80, N2 = 0.10, SO2 = 0.06, H2O = 0.04 } },
  sulfur      = { gases = { SO2 = 0.62, CO2 = 0.33, N2 = 0.05 } },
  frost       = { gases = { N2 = 0.92, CH4 = 0.06, CO = 0.02 } },
  regolith    = { gases = { Ar = 0.70, He = 0.20, N2 = 0.10 } },
  maria       = { gases = { Ar = 0.70, He = 0.20, N2 = 0.10 } },
}
-- the inert mix an "alien" AIR choice gives a world whose own air would breathe
ALIEN_MIX = { N2 = 0.955, Ar = 0.04, CO2 = 0.005 }
-- the order gases are listed in
GAS_ORDER = { "N2", "O2", "CO2", "Ar", "CH4", "SO2", "H2O", "NH3", "CO", "H2", "He" }
GAS_LABEL = { N2 = "N₂", O2 = "O₂", CO2 = "CO₂", Ar = "Ar", CH4 = "CH₄", SO2 = "SO₂", H2O = "H₂O", NH3 = "NH₃",
              CO = "CO", H2 = "H₂", He = "He" }
-- aero.OXY, kept here for the readers of an old save (aero.lua holds the same)
OXY_LEGACY = { archipelago = 1, verdant = 1, alpine = 1, steppe = 1, tundra = 1, dune = 0.8, greenhouse = 0, titan = 0 }

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- The pressure at the datum (bar) from the world's density.
function p0Of(atmo) return math.max(0, (atmo or 0) / ATMO_REF) end

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function normalise(g)
  local s = 0
  for _, v in pairs(g) do s = s + v end
  if s <= 0 then return g end
  for k, v in pairs(g) do g[k] = v / s end
  return g
end

-- Set the oxygen of a mix to `pp` bar at pressure p0, the rest scaled in
-- proportion (O2 capped at 0.6 of the mix).
local function with_o2(g, pp, p0)
  g = copy(g)
  local x = clamp(pp / math.max(p0, 1e-6), 0, 0.6)
  local rest = 0
  for k, v in pairs(g) do if k ~= "O2" then rest = rest + v end end
  local k = rest > 0 and (1 - x) / rest or 0
  for n, v in pairs(g) do if n ~= "O2" then g[n] = v * k end end
  g.O2 = x
  return g
end

-- A deterministic number in [0, 1) from a seed (resolveChoice's roll).
local function hash01(seed, salt)
  local h = (math.floor(seed or 1) * 2654435761 + (salt or 0) * 40503 + 0x9E3779B9) % 4294967296
  h = (h * 1103515245 + 12345) % 2147483648
  h = (h * 1103515245 + 12345) % 2147483648
  return h / 2147483648
end

-- The AIR choice as it lands: "random" becomes one of the others from the
-- seed (RANDOM_BREATHE breathable: 70 % earth, 15 % rich, 15 % thin of those).
-- An unknown or missing choice is returned as is (nil: an old save).
function resolveChoice(choice, seed)
  if choice ~= "random" then return choice end
  local u = hash01(seed, 7)
  if u >= RANDOM_BREATHE then return "alien" end
  local v = hash01(seed, 13)
  if v < 0.70 then return "earth" elseif v < 0.85 then return "rich" end
  return "thin"
end
function breathableChoice(c) return CHOICE_O2[c] ~= nil end

-- A world's air. `w` = { type (the planet type), atmo (density), tempK,
-- home (the save's home world), choice (its AIR choice, resolved), legacy }.
-- → the air record, or nil for an airless world.
function roll(w)
  local atmo = w.atmo or 0
  if atmo < 0.005 then return nil end
  local p0 = p0Of(atmo)
  local tpl = TEMPLATES[w.type or ""] or (w.home and TEMPLATES.earth) or TEMPLATES.ironred
  local g = copy(tpl.gases)
  if tpl.ppO2 then g = with_o2(g, tpl.ppO2, p0) end
  -- the built home world is Earth-like whatever its type says
  if w.home and not tpl.ppO2 then g = with_o2(EARTH, O2_EARTH, p0) end
  local c = w.choice
  if c and CHOICE_O2[c] then
    local base = tpl.ppO2 and g or EARTH
    g = with_o2(base, CHOICE_O2[c], p0)
  elseif c == "alien" and (g.O2 or 0) * p0 >= HYPOX then
    g = copy(ALIEN_MIX)
  end
  if w.legacy then
    -- (an old save: its worlds keep their yes/no rule; the mix only has to
    -- agree with it at the datum, so a world aero.OXY called breathable
    -- holds Earth-like oxygen and one it did not holds none)
    local oxy = w.home and 1 or (OXY_LEGACY[w.type or ""] or 0)
    if oxy >= 0.5 and (g.O2 or 0) * p0 < O2_MIN then g = with_o2(EARTH, O2_EARTH, p0) end
    if oxy < 0.5 and (g.O2 or 0) * p0 >= HYPOX then g = copy(ALIEN_MIX) end
  end
  normalise(g)
  return { p0 = p0, T0 = w.tempK, gases = g, o2 = g.O2 or 0, choice = c, legacy = w.legacy or nil }
end

-- Breathing it. `share` is the air's density here as a share of the datum's
-- (aero.airShare; 1 at sea level), `tK` the temperature or nil.
-- → ok, why, info = { p, ppO2, ppCO2, toxic (gas name), thin }
function breathable(air, share, tK)
  if type(air) ~= "table" then return false, "There is no air here. The helmet stays on.", { p = 0, ppO2 = 0 } end
  local p = (air.p0 or 0) * math.max(0, share or 1)
  local g = air.gases or {}
  local info = { p = p, ppO2 = p * (g.O2 or 0), ppCO2 = p * (g.CO2 or 0) }
  if p < P_MIN then return false, "There is no air here to speak of. The helmet stays on.", info end
  local tox = nil
  if p * (g.SO2 or 0) > SO2_MAX then tox = "SO2"
  elseif p * (g.NH3 or 0) > NH3_MAX then tox = "NH3"
  elseif p * (g.CO2 or 0) > CO2_MAX then tox = "CO2"
  elseif p * (g.CH4 or 0) > CH4_MAX then tox = "CH4" end
  if tox then
    info.toxic = tox
    return false, string.format("The air here is toxic: %s at %s. The helmet stays on.", GAS_LABEL[tox] or tox,
      ppText(p * (g[tox] or 0))), info
  end
  if info.ppO2 > O2_MAX then
    return false, string.format("Too much oxygen: %.2f bar would poison you. The helmet stays on.", info.ppO2), info
  end
  if info.ppO2 < HYPOX then
    if (g.O2 or 0) < 0.02 then return false, "This air has no oxygen to breathe. The helmet stays on.", info end
    return false, string.format("The air is too thin to breathe up here (O₂ %.2f bar). The helmet stays on.", info.ppO2), info
  end
  if tK and (tK < 228 or tK > 330) then info.cold = tK < 228; info.hot = tK > 330 end
  if info.ppO2 < O2_MIN then info.thin = true end
  return true, nil, info
end

-- A partial pressure in words: "0.21 bar", "12 mbar", "40 µbar".
function ppText(b)
  b = b or 0
  if b >= 0.1 then return string.format("%.2f bar", b) end
  if b >= 1e-3 then return string.format("%.0f mbar", b * 1000) end
  return string.format("%.0f µbar", b * 1e6)
end

-- The mix in a line: "N₂ 78 % · O₂ 21 % · Ar 1 %" (the top `n`, default 4).
function gasesText(air, n)
  if type(air) ~= "table" or type(air.gases) ~= "table" then return "none" end
  local list = {}
  for _, k in ipairs(GAS_ORDER) do
    local v = air.gases[k]
    if v and v > 0 then list[#list + 1] = { k, v } end
  end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local out = {}
  for i = 1, math.min(n or 4, #list) do
    local v = list[i][2] * 100
    out[#out + 1] = string.format(v >= 1 and "%s %.0f %%" or (v >= 0.1 and "%s %.1f %%" or "%s %.2f %%"), GAS_LABEL[list[i][1]] or list[i][1], v)
  end
  return table.concat(out, " · ")
end

-- The verdict in one word at the datum: "BREATHABLE" | "THIN" | "TOXIC" | "NO OXYGEN" | "NONE".
function verdict(air)
  if type(air) ~= "table" then return "NONE" end
  local ok, _, info = breathable(air, 1)
  if ok then return info.thin and "THIN" or "BREATHABLE" end
  if info.toxic then return "TOXIC" end
  if (info.p or 0) < P_MIN then return "NONE" end
  return "NO OXYGEN"
end

-- The yes/no oxygen of an OLD save's world (aero.lua's rule before air):
-- 0..1 by type, the home world 1, a world from before types by its density.
function legacyOxygen(w)
  if type(w) ~= "table" or (w.atmo or 0) < 0.05 then return 0 end
  local geo = w.geo
  if type(geo) == "table" then
    if geo.home then return 1 end
    return OXY_LEGACY[geo.type or ""] or 0
  end
  return (w.atmo or 0) > 0.3 and 1 or 0
end

-- The oxygen a jet can burn on world `w` (0..1, of Earth's), for
-- aero.oxygen: an old save's or air-less record's is legacyOxygen; a world
-- with air its ppO2 against Earth's at the datum.
function oxygenOf(w)
  if type(w) ~= "table" or (w.atmo or 0) < 0.05 then return 0 end
  local a = w.air
  if type(a) ~= "table" or a.legacy then return legacyOxygen(w) end
  return clamp((a.p0 or 0) * (a.o2 or 0) / O2_EARTH, 0, 1)
end

-- ── the scene half ──────────────────────────────────────────────────────────
REFILL_R = 6.0               -- m from the Command building's door (or inside it)
MASK_DRAW = 1 / 6            -- the mask's draw on the suit, of the suit's own rate
HYPOX_HP = 0.01              -- health lost a minute in thin air without a mask
TICK = 1.0
stats = { refills = 0, masked = 0, hypox = 0 }
lastState = nil              -- (probes) "refill" | "mask" | "hypoxia" | nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local tick_t, said = -10, {}

-- The air at world point (x, y, z) on its dominant body: the air record (nil
-- airless), the share of the datum's density there, the world record.
function airHere(x, y, z)
  local dom = space and space.dominant and space.dominant(x, y, z)
  local cl = ref("climate")
  local w = dom and cl and cl.worldOf and cl.worldOf(dom)
  if type(w) ~= "table" then return nil, 0, nil end
  local b = space.body and space.body(dom)
  local share = 1
  if b then
    local alt = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - (w.radius or b.radius or 0)
    local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or b.radius or 800)
    local ae = ref("aero")
    if ae and ae.airShare then share = ae.airShare(math.max(alt, -0.25 * H), H, w.atmoScaleH)
    else local f = math.max(0, 1 - math.max(alt, 0) / H); share = f * f end
  end
  return w.air, share, w
end

-- Inside the spaceport's Command building, or within REFILL_R of its walls
-- (its door is on its south face)? The crew's point in the building's own
-- frame, both read in this update (the planet carries both the same tick).
-- COMMAND_HALF: the building's lot (base_facilities FACILITIES), x × z half.
COMMAND_HALF = { 16.1, 9.45 }
local cmd_node = nil
function atCommand(x, y, z)
  if not (cmd_node and cmd_node.valid ~= false) then cmd_node = find and find("FacCommand") or nil end
  local n = cmd_node
  if not (n and n.toLocal and vec3) then return false end
  local ok, p = pcall(n.toLocal, n, vec3(x, y, z))
  if not ok or not p then return false end
  local px, py, pz = p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0
  return math.abs(px) <= COMMAND_HALF[1] + REFILL_R and math.abs(pz) <= COMMAND_HALF[2] + REFILL_R and py > -4 and py < 14
end
local function at_command(node) return atCommand(node.x, node.y, node.z) end

local function say(key, title, line, dur)
  if said[key] then return end
  said[key] = true
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, title, line or "", dur or 3.5) end
end

local function tick(dt)
  local wk = ref("planet_walker")
  lastState = nil
  if not (wk and wk.onFoot and not wk.downed) then return end
  local node = wk.node or (find and find("Astronaut"))
  if not node then return end
  -- the spaceport refills the suit
  if at_command(node) then
    if (wk.suitO2 or 1) < 0.999 and wk.setSuitAir then
      wk.setSuitAir(1.0)
      stats.refills = stats.refills + 1
      say("refill", "SUIT AIR TOPPED UP", "The Command building's air line refills the suit.", 3.0)
    end
    lastState = "refill"
  end
  local su = ref("suit")
  if not (su and su.helmetOn) or su.helmetOn() then return end
  local air, share, w = airHere(node.x, node.y, node.z)
  if type(air) ~= "table" or air.legacy then return end
  local RA = ref("room_air")
  if RA and RA.airAt then
    local ok = RA.airAt(node.x, node.y, node.z)
    if ok ~= nil then return end     -- in a room: the room's air
  end
  local ok, _, info = breathable(air, share, w and type(w.bio) == "table" and w.bio.tempK or nil)
  if not (ok and info.thin) then return end
  local inv = ref("inventory")
  local C = ref("crew")
  local pack = (C and C.packOf and C.packOf()) or "astro"
  local masked = false
  if inv and inv.itemCount then
    local okc, k = pcall(inv.itemCount, pack, "o2mask")
    masked = okc and (k or 0) > 0
  end
  if masked then
    local secs = (C and C.SUIT_AIR_SECS) or 1200
    if wk.setSuitAir and (wk.suitO2 or 0) > 0 then
      wk.setSuitAir(math.max(0, (wk.suitO2 or 1) - dt * MASK_DRAW / secs))
    end
    stats.masked = stats.masked + 1
    lastState = "mask"
    say("mask", "THIN AIR · MASK ON", string.format("O₂ %.2f bar: the mask's cannula feeds you from the suit.", info.ppO2), 3.5)
    if (wk.suitO2 or 0) <= 0 then masked = false end
  end
  if not masked then
    local id = C and C.activeId and C.activeId()
    if id and C.hurt then pcall(C.hurt, id, HYPOX_HP * dt / 60, "hypoxia", "thin air without a mask") end
    stats.hypox = stats.hypox + 1
    lastState = "hypoxia"
    say("hypox", "THIN AIR · MASK", string.format("O₂ %.2f bar: too little to live on for long. Wear an O₂ Mask, or the helmet.", info.ppO2), 4.0)
  end
end

function update(node, dt)
  local t = time or 0
  if t - tick_t < TICK then return end
  local d = math.min(5, t - tick_t)
  tick_t = t
  if tick_t > 0 and d > 0 then pcall(tick, d) end
end
