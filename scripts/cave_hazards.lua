-- CAVE HAZARDS — what in a cave can hurt you, and what going in pays (worlds
-- plan W5, work/worlds/PLAN.md §4.4, §4.5 and §5.1; docs/worlds-and-caves.md
-- §4).
--
-- THE RULE (Ty's, binding): a hazard is TELEGRAPHED, never PREVENTED. Every
-- one below is said before it bites (a reading that climbs, a sound, dust, a
-- caption with its codex line), and none of them is a wall: you may take the
-- helmet off in a CO2 sump, fire the laser in a methane pocket, dig under a
-- cracked roof, stand at a pitchblende face. It hurts; that is all.
--
--   AIR        cave air CELLS (AIR_CELL m): each kind has a background and
--              pockets (a CO2 sump low in a karst gallery or a lava tube, a
--              vent's SO2 and H2S, methane from clathrate or rotting
--              organics at a roof), each a ball whose gas falls off from its
--              heart, so the suit's reading climbs as you walk in. Heavy
--              gas pools low, methane at the roof. atmo.airHere mixes them
--              into the world's air (cave_field.airAt → airAtWorld here),
--              so the suit judges them as any air: the helmet closes itself
--              in bad air (suit.lua), comes off again if you insist
--              (suit.caveDare), and bare-headed in it you are hurt by the gas
--              and how far over its limit it is.
--   METHANE    5–15 % of the air with oxygen to burn in is FLAMMABLE: the
--              chip says so first; the Terrain Laser fired in it lights it.
--              A flash, a whump, burns (less with the helmet on), maybe the
--              roof; the pocket is burnt out for good (saved).
--   ROCKFALL   "unstable" cells (UNSTABLE_CELL m) by the kind's chance; the
--              roof TICKS while you are in one. A dig with the laser under
--              it, or walking through it, can set it off, ON you, or AHEAD
--              of you or BEHIND you in the passage (rockfallSpot): a crack (a
--              real recording) at the roof, 1.5 s of dust and pattering
--              grit, then 1–3 slabs sized to the passage (slabScale) from
--              inside it. A slab that hits you hurts by its size and speed.
--              What comes down stays as a PILE OF RUBBLE (rubblePile):
--              terrain raised on the floor and painted the roof's rock,
--              sized to the passage, so a tunnel is choked or closed and the
--              laser digs through it like rock. Slabs in the pile are buried
--              in it; the rest stay as loose rock (mineral_field.adoptBody).
--              No caption: it is heard and seen. Each cell falls once (saved).
--   COLD/HEAT  an ice cave is the kind's cold, a vent and a lava tube run
--              hot: thermal.suitThermal. The suit's heater draws on the lamp
--              cell (a cold cave eats your light); bare-headed the air hurts.
--   DOSE       within 6 m of a pitchblende seam (mineral_field's reading
--              over the share at 6 m), radon and gamma add to the crew's
--              dose (crew.addDose, the reactor's dose step; crew_alerts'
--              DOSE chip and W3's dosimeter chip show it).
--   DROPS      a drop over DROP_HINT m under the aim (cave_field's drop
--              ray): a caption with the depth and the rope (a Rope Kit in
--              the pack, or the lack of one).
--   FLOOD      the floor ahead under the water (climate.seaDepth: its
--              cave_wet fill): said before you walk into it.
--   REWARDS    the first entry into each kind on a world raises the survey's
--              composition by COMP_GAIN and credits the kind's RP; each
--              hazard's codex line (codex.CODEX "hazard_<id>") is told the
--              first time it is met.
--
-- COST: nothing a frame. The work runs once per cave_field probe (2 Hz;
-- cave_field publishes probeN and its points) and uses no rays of its own
-- but up to seven per rockfall (the passage measured once); a rockfall's sounds and slabs are followed for a few
-- seconds only while one is under way.
--
-- PURE (tests/smoke_cave_hazards.lua): AIR, airCellOf, airAtLocal, readout,
-- flammable, unstableAt, rockfallPlan, slabHurt, rockfallSpot, slabScale,
-- rubblePile, pileBuries, caveTempK, seamShare,
-- doseRate, dropHint, firstEntry, compGain, HAZARDS.
--
-- Probes: state, stats, last (the last event of each kind; last.pile),
-- forceRockfall(kind, dir), fallState(),
-- forceIgnite(), fellCount(), reset().

defaults = {
  on = true,
  --- Probes: every pocket is this gas at its worst ("" = the cells' own;
  --- "CO2" | "SO2" | "H2S" | "CH4") and every cell is unstable.
  forceAir = "",
  forceUnstable = false,
  --- Probes: the ground's ore dose (µSv/h) where no seam is near (0 = the
  --- dosimeter's own reading).
  forceDoseOre = 0,
  debug = false,
}

local sqrt, max, min, floor, exp = math.sqrt, math.max, math.min, math.floor, math.exp
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end

-- ════════════════════════════════════════════════════════════════════════════
-- PURE
-- ════════════════════════════════════════════════════════════════════════════

-- The same integer hash cave_kinds uses (exact in doubles; luajit and the
-- engine agree), kept here so the rules load on their own.
local M31 = 2147483647
local function mix(h, v)
  h = (h + (floor(v) % M31) * 2654435 + 1) % M31
  for _ = 1, 2 do
    h = (h * (h % 65521 + 1) + 12345) % M31
    h = (h * 48271) % M31
  end
  return h
end
function hash(seed, a, b, c)
  local h = mix(mix(mix(mix(97, seed or 0), a or 0), b or 0), c or 0)
  h = mix(h, 11)
  return h / M31
end

-- ── AIR ─────────────────────────────────────────────────────────────────────
-- Partial pressures in bar at a 1 bar world (scaled by the world's air,
-- AIR_SCALE). `base` everywhere in the kind's caves; `pockets` one ball per
-- cell at most, by chance `p` (summed), radius `r`, its heart's gas. A heavy
-- gas (CO2, SO2, H2S) sinks: the ball is squashed above its heart and
-- stretched below; methane rises: the other way. Real figures: cave air is
-- commonly 0.5–1 % CO2, a sump 3–10 % ("bad air": panting at 3 %, collapse
-- near 10 %); a fumarole's SO2 and H2S run to hundreds of ppm.
AIR_CELL = 36.0
AIR = {
  lava_tube = { base = { CO2 = 0.004, SO2 = 2e-6 },
                pockets = { { gas = { CO2 = 0.065 }, p = 0.30, r = { 6, 11 }, name = "CO2 sump" } } },
  ice       = { base = nil,
                pockets = { { gas = { CH4 = 0.095 }, p = 0.18, r = { 5, 9 }, name = "methane from clathrate" } } },
  karst     = { base = { CO2 = 0.006 },
                pockets = { { gas = { CO2 = 0.07 }, p = 0.32, r = { 6, 12 }, name = "bad air" },
                            { gas = { CH4 = 0.09 }, p = 0.12, r = { 5, 9 }, name = "firedamp" } } },
  geode     = { base = { CO2 = 0.003 },
                pockets = { { gas = { CO2 = 0.05 }, p = 0.30, r = { 4, 7 }, name = "a sealed hollow's CO2" } } },
  salt      = { base = nil, pockets = {} },
  vent      = { base = { SO2 = 4e-6, H2S = 3e-6, CO2 = 0.008 },
                pockets = { { gas = { SO2 = 1.4e-4, H2S = 1.6e-4, CO2 = 0.06 }, p = 0.50, r = { 6, 12 }, name = "fumarole gas" } } },
  collapse  = { base = nil, pockets = { { gas = { CO2 = 0.04 }, p = 0.10, r = { 5, 9 }, name = "CO2 sump" } } },
  chasm     = { base = nil, pockets = { { gas = { CO2 = 0.045 }, p = 0.12, r = { 5, 10 }, name = "CO2 sump" } } },
}
GASES = { "CO2", "SO2", "H2S", "CH4" }
HEAVY = { CO2 = true, SO2 = true, H2S = true }
-- The limits a reading is judged against (bar; atmo.lua's, H2S its W5 one).
LIMIT = { CO2 = 0.02, SO2 = 1e-5, H2S = 1e-5, CH4 = 0.03 }
-- Harm a minute bare-headed, a share of a healthy body, per limit over
-- (capped at HARM_CAP times): CO2 narcosis is slow, H2S kills fast.
HARM = { CO2 = 0.02, SO2 = 0.025, H2S = 0.04, CH4 = 0.01 }
HARM_CAP = 12
LABEL = { CO2 = "CO₂", SO2 = "SO₂", H2S = "H₂S", CH4 = "CH₄" }
-- Methane burns between its lower and upper flammable limits by volume,
-- with oxygen enough to carry a flame (12 % of the air).
LEL, UEL, O2_FLAME = 0.05, 0.15, 0.12

-- How much of a cave's gas a world's air holds: none in a vacuum (it goes),
-- in proportion to the air's pressure otherwise (0.3–1.5 ×).
function airScale(pWorld)
  if not pWorld or pWorld < 0.05 then return 0 end
  return clamp(pWorld, 0.3, 1.5)
end

-- The pocket of air cell (i, j, k) for `kind` on a world of `seed`, or nil:
-- { cx, cy, cz (body-local heart), r, gas, name, key }. `force` (probes) a
-- gas every pocket is made of, every cell having one.
function airCellOf(seed, kind, i, j, k, force)
  local A = AIR[kind]
  if not A then return nil end
  local list = A.pockets or {}
  local u = hash((seed or 1) + 7717, i, j, k)
  local pk = nil
  if force and force ~= "" then
    local g = {}
    g[force] = (force == "CH4" and 0.09) or (force == "CO2" and 0.07) or 1.5e-4
    pk = { gas = g, p = 1, r = { 8, 12 }, name = "forced " .. force }
  else
    local acc = 0
    for _, e in ipairs(list) do
      acc = acc + e.p
      if u < acc then pk = e; break end
    end
  end
  if not pk then return nil end
  local r = pk.r[1] + (pk.r[2] - pk.r[1]) * hash(seed + 31, i, j, k)
  local m = (AIR_CELL - 2 * r) * 0.5
  local function at(n, s) return (n + 0.5) * AIR_CELL + (hash(seed + s, i, j, k) - 0.5) * 2 * max(0, m) end
  return { cx = at(i, 41), cy = at(j, 43), cz = at(k, 47), r = r, gas = pk.gas, name = pk.name,
           key = i .. "," .. j .. "," .. k }
end

-- The share of a pocket's heart gas at a body-local point (0..1).
function pocketShare(pk, x, y, z)
  local dx, dy, dz = x - pk.cx, y - pk.cy, z - pk.cz
  local cl = len(pk.cx, pk.cy, pk.cz)
  local ux, uy, uz = pk.cx / cl, pk.cy / cl, pk.cz / cl
  local v = dx * ux + dy * uy + dz * uz            -- up (+) or down (−) from the heart
  local hx, hy, hz = dx - ux * v, dy - uy * v, dz - uz * v
  local heavy = false
  for g in pairs(pk.gas) do if HEAVY[g] then heavy = true end end
  -- heavy gas: thin above the heart (×2), deep below (×0.7); methane mirrored
  local sv = (v > 0) == heavy and 2.0 or 0.7
  local d = sqrt(hx * hx + hy * hy + hz * hz + (v * sv) ^ 2)
  local f = clamp(1 - d / pk.r, 0, 1)
  return f * f * (3 - 2 * f)
end

-- The gases (bar, at a 1 bar world) a cave of `kind` adds at a body-local
-- point. `burnt` (set of cell keys) pockets already burnt out. → gases
-- { CO2, SO2, H2S, CH4 }, the pocket it is in (or nil), its share.
function airAtLocal(seed, kind, x, y, z, burnt, force)
  local A = AIR[kind]
  if not A then return nil end
  local out = {}
  for g, v in pairs(A.base or {}) do out[g] = v end
  local i, j, k = floor(x / AIR_CELL), floor(y / AIR_CELL), floor(z / AIR_CELL)
  local pk = airCellOf(seed, kind, i, j, k, force)
  local share = 0
  if pk and not (burnt and burnt[pk.key] and pk.gas.CH4) then
    share = pocketShare(pk, x, y, z)
    if share > 0 then
      for g, v in pairs(pk.gas) do out[g] = (out[g] or 0) + v * share end
    end
  end
  return out, (share > 0) and pk or nil, share
end

-- A reading for the suit's chip: the worst gas by its limit. `cave` the gases
-- (bar), `p` the air's total pressure there (bar), `o2` the O2 fraction.
-- → { gas, pp, sev (pp / limit; CH4 by the lower flammable limit), level
-- (0 nothing to say, 1 a trace worth showing, 2 caution, 3 over the limit),
-- flammable, frac (CH4 by volume), text }
function readout(cave, p, o2)
  local best, bs = nil, 0
  for _, g in ipairs(GASES) do
    local v = cave and cave[g] or 0
    if v > 0 then
      local s = v / LIMIT[g]
      if s > bs then best, bs = g, s end
    end
  end
  local fr, fl = flammable(cave, p, o2)
  local r = { gas = best, pp = best and cave[best] or 0, sev = bs, frac = fr, flammable = fl, level = 0 }
  if fl or (fr >= LEL * 0.6 and (o2 or 0) >= O2_FLAME) then r.level = 3
  elseif bs >= 1 then r.level = 3
  elseif bs >= 0.5 then r.level = 2
  elseif bs >= 0.2 then r.level = 1 end
  if best then
    local v = r.pp
    local t = v >= 1e-3 and string.format("%.0f mbar", v * 1000) or string.format("%.0f ppm", v / max(p or 1, 0.05) * 1e6)
    r.text = (LABEL[best] or best) .. " " .. t
    if (fr or 0) >= 0.01 then r.text = r.text .. string.format(" · CH₄ %.0f %%", fr * 100) end
    if fl then r.text = r.text .. " · FLAMMABLE" end
  end
  return r
end

-- Methane by volume and whether it burns: → fraction, flammable.
function flammable(cave, p, o2)
  local ch4 = cave and cave.CH4 or 0
  if ch4 <= 0 or not p or p <= 0 then return 0, false end
  local x = ch4 / p
  return x, x >= LEL and x <= UEL and (o2 or 0) >= O2_FLAME
end

-- Harm a minute bare-headed in `cave` air (bar): the worst gas's. → harm, gas
function gasHarm(cave)
  local h, worst = 0, nil
  for _, g in ipairs(GASES) do
    local v = cave and cave[g] or 0
    local s = v / LIMIT[g]
    if s >= 1 then
      local x = HARM[g] * min(HARM_CAP, s)
      if x > h then h, worst = x, g end
    end
  end
  return h, worst
end

-- ── ROCKFALL ────────────────────────────────────────────────────────────────
UNSTABLE_CELL = 12.0
UNSTABLE_K = 0.6          -- × the kind's hazards.unstable: lava 21 %, karst 6 %, collapse 30 % of cells
STEP_P = 0.04             -- a probe's chance, walking in an unstable cell (≈ 12 s of walking)
DIG_P = 0.15              -- a probe's chance, the laser digging under one (≈ 3 s of digging)
FALL_COOLDOWN = 30.0      -- s between rockfalls
DUST_S = 1.5              -- s from the crack to the slabs
-- Is cell (i, j, k) of a `kind` cave unstable? (`unstable` the kind's chance)
function unstableAt(seed, unstable, i, j, k, force)
  if force then return true end
  return hash((seed or 1) + 313, i, j, k) < (unstable or 0) * UNSTABLE_K
end
-- The slabs of one fall from draws u[1..]: 1–3, each { dx, dz (m, across the
-- roof point), s (scale) }.
function rockfallPlan(u)
  local n = 1 + floor(clamp(u[1] or 0, 0, 0.999) * 3)
  local out = {}
  for i = 1, n do
    local a = (u[1 + i] or 0.5) * 6.2832
    local r = 0.2 + 1.0 * (u[4 + i] or 0.5)
    out[i] = { dx = math.cos(a) * r, dz = math.sin(a) * r, s = 0.7 + 0.7 * (u[7 + i] or 0.5) }
  end
  return out
end
-- What a slab of scale `s` hitting at `speed` m/s does (share of a body).
function slabHurt(s, speed)
  if (speed or 0) < 2.5 then return 0 end
  return clamp(0.10 * (s or 1) ^ 3 * speed / 5, 0.06, 0.75)
end
-- (Ty 2026-11-11: "cave-in rocks get stuck in tunnels so easily … they're
-- trivial to avoid; you also can't break the rocks that fell".) A fall comes
-- down ON the crew, or AHEAD of them or BEHIND them in the passage, and what
-- comes down stays as a PILE OF RUBBLE: terrain (a union of balls painted the
-- roof's rock), sized to the passage, so a tunnel is partly or wholly blocked
-- and the Terrain Laser digs through it as it digs rock. The slabs are the
-- fall itself (they hurt); those that come to rest in the pile are buried in
-- it, the rest stay as loose rock.
SPOT_ALONG = { 3.0, 5.0 }  -- m: a fall ahead or behind lands this far along the passage
LB_HALF = 0.64             -- m: LooseBoulder's largest half-extent at scale 1
RUBBLE_MIN = 1.5           -- m: the smallest pile (one planet voxel is 1.5 m: a smaller ball is not drawn)
RUBBLE_MAX = 5.0           -- m: a big gallery gets a heap (10 m across), not a wall
PILE_CLEAR = 0.6           -- m: a pile waits while the crew stands inside it (never buried alive)
PILE_WAIT = 60.0           -- s: …for this long at most; then only the slabs stay
-- Where a fall comes down: `why` "step" | "dig" | "ignite" | "probe", draws
-- u1, u2 → kind "on" | "ahead" | "behind" | "face", along (m, signed along
-- the walking or digging direction; 0 = at the point).
function rockfallSpot(why, u1, u2)
  u1, u2 = u1 or 0.5, u2 or 0.5
  local d = SPOT_ALONG[1] + (SPOT_ALONG[2] - SPOT_ALONG[1]) * clamp(u2, 0, 1)
  if why == "dig" then
    -- at the face you are cutting, or the way you came in
    if u1 < 0.5 then return "face", 0 end
    return "behind", -d
  end
  if why == "step" then
    if u1 < 0.4 then return "on", 0 end
    if u1 < 0.7 then return "ahead", d end
    return "behind", -d
  end
  return "on", 0
end
-- The scale of a slab for a passage `H` m from floor to roof and `W` m across
-- at its narrowest, from draw `u`: 0.7–1.4 as before where there is room,
-- never more than 30 % of the passage (it falls clear, it does not wedge).
function slabScale(H, W, u)
  local room = min(H or 8, W or 8)
  local cap = 0.30 * room / LB_HALF
  return clamp(min(0.7 + 0.7 * clamp(u or 0.5, 0, 1), cap), 0.35, 1.4)
end
-- The pile a fall leaves in a passage `H` m high and `W` m across, from draw
-- `u`: → { r (m, the main ball, centred on the floor under the fall), need
-- (m, the radius that closes the passage), blocks (bool), balls = { { a
-- (m along the passage), r } … } }. A ball centred on the floor of a round
-- passage reaches its whole section at r = H; an arched or square one wants
-- a little more for the corners (√(H² + 0.1 W²)). f = r / need runs 0.6 to
-- 1.15: a little under half the falls close the passage, the rest choke it
-- to a crawl over the top or a squeeze at a wall.
function rubblePile(H, W, u)
  H, W = max(0.5, H or 3), max(0.5, W or 3)
  local need = sqrt(H * H + 0.1 * W * W)
  local f = 0.6 + 0.55 * clamp(u or 0.5, 0, 1)
  local r = clamp(f * need, RUBBLE_MIN, RUBBLE_MAX)
  local out = { r = r, need = need, blocks = r >= need * 0.98, balls = { { a = 0, r = r } } }
  -- a talus either side along the passage: the heap is longer than it is high
  local r2 = max(RUBBLE_MIN, 0.7 * r)
  out.balls[2] = { a = 0.6 * r, r = r2 }
  out.balls[3] = { a = -0.6 * r, r = r2 }
  return out
end
-- Where along the passage a ball of the heap goes for a fall ahead of or
-- behind the crew: planned at `a` (m along the passage from the fall), radius
-- r, the crew's feet at `ac` along it. Slid away from the crew until its
-- near edge is PILE_CLEAR + 0.4 m short of them; never toward them.
function pileAlong(a, r, ac)
  local s = (ac <= 0) and 1 or -1         -- away from the crew
  local gap = (a - ac) * s                -- how far past the crew it sits
  local want = r + PILE_CLEAR + 0.4
  if gap < want then return a + s * (want - gap) end
  return a
end
-- Would a ball (body-local centre c, radius r) bury the crew standing from
-- foot point f to head point h (body-local)? The segment's distance to the
-- centre under r + PILE_CLEAR.
function pileBuries(c, r, f, h)
  local sx, sy, sz = h[1] - f[1], h[2] - f[2], h[3] - f[3]
  local ss = sx * sx + sy * sy + sz * sz
  local t = 0
  if ss > 1e-9 then t = clamp(((c[1] - f[1]) * sx + (c[2] - f[2]) * sy + (c[3] - f[3]) * sz) / ss, 0, 1) end
  local px, py, pz = f[1] + sx * t, f[2] + sy * t, f[3] + sz * t
  return len(c[1] - px, c[2] - py, c[3] - pz) < r + PILE_CLEAR
end

-- ── COLD AND HEAT ───────────────────────────────────────────────────────────
-- The air of a `kind` cave on a world at `worldK`: caves keep their world's
-- mean; an ice cave is its kind's cold or colder; a vent or a tube runs hot
-- (the kind's heat over the world's), more so the deeper (`d` 0..1).
function caveTempK(worldK, kind, hz, d)
  worldK = worldK or 288
  hz = hz or {}
  if hz.cold then return min(worldK, hz.cold) end
  if hz.heat then return worldK + hz.heat * (0.5 + 0.5 * clamp(d or 0.5, 0, 1)) end
  return worldK
end

-- ── DOSE ────────────────────────────────────────────────────────────────────
-- Within SEAM_REACH m of a pitchblende seam: the reading's ore share over
-- what a 2 m seam gives at that distance (mineral_field.doseFrom). GAME_K is
-- the lethal share an hour per µSv/h the ground reads in a SEALED cave,
-- where radon builds: an hour at the face of a rich seam (28 µSv/h) costs 2
-- % of a lethal dose, in the open a tenth of that. (Game scale: a real
-- seam's gamma is about ten thousand times milder; radon in a closed, dead-
-- air cave is what makes it the hazard.)
SEAM_REACH = 6.0
GAME_K = 0.02 / 28
function seamShare(doseFrom)
  if doseFrom then return doseFrom(SEAM_REACH, 2, 1) end
  return 28 * exp(-SEAM_REACH / 4.5)
end
-- → lethal share a game second
function doseRate(doseOre, enclosed, share6)
  if not doseOre or doseOre < (share6 or seamShare()) then return 0 end
  return doseOre * GAME_K * (0.1 + 0.9 * clamp(enclosed or 0, 0, 1)) / 3600
end

-- ── DROPS ───────────────────────────────────────────────────────────────────
DROP_HINT = 6.0
-- The hint for a drop of `drop` m ahead (nil under DROP_HINT).
function dropHint(drop, hasRope)
  if not drop or drop < DROP_HINT then return nil end
  local d = drop >= 39 and "40 m or more" or string.format("%d m", floor(drop + 0.5))
  if hasRope then return string.format("A drop of %s ahead. Plant the Rope Kit at the edge and clip on.", d) end
  return string.format("A drop of %s ahead, and no rope in the pack. A fall like that breaks a crew.", d)
end

-- ── REWARDS ─────────────────────────────────────────────────────────────────
COMP_GAIN = 0.15
-- First entry into `kind` given the kinds already seen (a list)? → bool
function firstEntry(seen, kind)
  if not kind then return false end
  for _, k in ipairs(seen or {}) do if k == kind then return false end end
  return true
end
function compGain(comp) return min(1, (comp or 0) + COMP_GAIN) end

-- ── THE CODEX LINES (one per hazard; codex.CODEX["hazard_<id>"]) ────────────
HAZARDS = {
  co2 = { name = "Bad air (carbon dioxide)", summary = "Carbon dioxide pools in low passages, invisible and heavier than air.", facts = {
    "At 3 % CO2 a caver pants and gets a headache; at 5 % thinking slows; near 10 % people collapse within minutes.",
    "The gas comes from soil and rotting organics washed in, or from volcanic rock; it sinks and fills sumps like water.",
    "Old cavers carried a candle: it gutters at about 15 % oxygen. A suit's sensor reads the CO2 itself.",
  } },
  so2 = { name = "Sulfur dioxide", summary = "A sharp, choking volcanic gas, harmful at a few parts per million.", facts = {
    "SO2 stings the eyes and throat at 2 ppm and is immediately dangerous at 100 ppm; with water it makes sulfurous acid.",
    "Volcanologists at fumaroles wear acid-gas respirator cartridges and turn back when the plume shifts onto them.",
  } },
  h2s = { name = "Hydrogen sulfide", summary = "Rotten eggs, until it numbs the nose; then it kills.", facts = {
    "H2S smells of rotten eggs at a fraction of a ppm, but above about 100 ppm it paralyses the sense of smell.",
    "At 500-700 ppm it causes collapse within minutes. It is heavier than air and collects in vents and pits.",
  } },
  ch4 = { name = "Firedamp (methane)", summary = "Methane gathers under a roof and burns between 5 and 15 %.", facts = {
    "Miners called it firedamp. Lighter than air, it collects at the roof and in high cavities.",
    "Between about 5 and 15 % in air it ignites from a spark, a flame or a hot surface: the deflagration that killed thousands in coal mines.",
    "A cutting laser is a hot surface. Below 12 % oxygen methane will not burn at all.",
  } },
  rockfall = { name = "Rockfall", summary = "A roof that ticks is a roof deciding whether to fall.", facts = {
    "Breakdown, fallen roof blocks, is the floor of many caves: every block was once overhead.",
    "Fresh cracks, ticking, and grit sifting down are the signs miners learned to run from.",
    "Digging under a loose roof takes away what holds it; so can the vibration of walking through.",
  } },
  cold = { name = "Cold", summary = "An ice cave holds well below freezing, and the suit pays for it.", facts = {
    "Glacier caves stay near the ice's own temperature, often far below zero in winter and in cold climates.",
    "A suit's heater runs on the same cell as its lamps: a long stay in the cold shortens the light.",
    "Bare skin at −25 °C freezes in under half an hour; the airway suffers first.",
  } },
  heat = { name = "Heat", summary = "Near magma and vents the rock itself is hot.", facts = {
    "Naica's Cave of the Crystals sits at 58 °C and 99 % humidity: unprotected people last about ten minutes.",
    "A suit's sublimator sheds heat by boiling water away; in hot air it has to work harder.",
  } },
  dose = { name = "Radon and gamma", summary = "A pitchblende seam in a closed cave fills the air with radon.", facts = {
    "Uraninite decays through radium to radon, a gas that seeps out of the rock and builds up where the air is still.",
    "The miners of Joachimsthal and Schneeberg suffered 'mountain sickness' for centuries: lung cancer from radon.",
    "Ventilation, not shielding, is what protects a uranium miner; a dosimeter tells you how long you have.",
  } },
  drop = { name = "Drops", summary = "Shafts, moulins and sinks go straight down further than a lamp reaches.", facts = {
    "Vertical caving is done on single static ropes with ascenders and a descender, never by climbing free.",
    "A fall of more than a few metres onto rock is how most caving accidents end.",
  } },
  flood = { name = "Flooded passages", summary = "Below the water table, a passage simply fills.", facts = {
    "Sumps, passages full to the roof, are passed only by cave divers with their own air.",
    "Water levels in caves can rise metres in an hour after rain on the surface far above.",
  } },
}
HAZARD_OF_GAS = { CO2 = "co2", SO2 = "so2", H2S = "h2s", CH4 = "ch4" }
function lineOf(id) local H = HAZARDS[id]; return H and H.facts and H.facts[1] or nil end

-- ════════════════════════════════════════════════════════════════════════════
-- THE SCENE HALF (on the Weather node, after cave_field)
-- ════════════════════════════════════════════════════════════════════════════
state = { kind = nil, gas = nil, tempK = nil, dose = 0, unstable = false, flood = false, drop = 0 }
stats = { probes = 0, rockfalls = 0, slabs = 0, hits = 0, ignitions = 0, harm = 0, firsts = 0, dosed = 0, ms = 0 }
last = {}             -- (probes) last event of each kind: rockfall, ignite, first, gas, drop, flood, dose
hazard = nil          -- the same as cave_field.hazard, with this script's numbers in

local refs = {}
local function ref(k)
  local r = refs[k]
  if r and r.valid ~= false then return r end
  r = findScript and findScript(k, { quiet = true }) or nil
  refs[k] = r
  return r
end
local function P(k) if params and params[k] ~= nil then return params[k] end return defaults[k] end
local function now() return time or 0 end
local function wall() return (app and app.wallClock and app.wallClock()) or (os and os.clock and os.clock()) or 0 end
local function sget(k) return save and save.get and save.get(k) or nil end
local function sset(k, v) if save and save.set then pcall(save.set, k, v) end end

local CK
local function kinds()
  if CK and CK.KINDS then return CK end
  CK = ref("cave_kinds")
  return CK
end

local function say(key, title, line, secs, every)
  last.said = last.said or {}
  local t = last.said[key]
  if t and now() - t < (every or 1e9) then return false end
  last.said[key] = now()
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, title, line or "", secs or 4.0)
  elseif caption then pcall(caption, title .. " · " .. (line or "")) end
  if log then log("cave_hazards: " .. title .. " · " .. tostring(line or "")) end
  return true
end

-- The codex: each hazard's lines in codex.CODEX["hazard_<id>"], and a line
-- told the first time a hazard is met (saved: cave.codex = { id … }).
local codex_done = false
local function register_codex()
  if codex_done then return end
  local cx = ref("codex")
  if not (cx and type(cx.CODEX) == "table") then return end
  for id, H in pairs(HAZARDS) do cx.CODEX["hazard_" .. id] = { name = H.name, summary = H.summary, facts = H.facts } end
  codex_done = true
end
local function met(id)
  local seen = sget("cave.codex")
  if type(seen) ~= "table" then seen = {} end
  for _, k in ipairs(seen) do if k == id then return false end end
  seen[#seen + 1] = id
  sset("cave.codex", seen)
  return true
end
-- The caption's second line: the hazard's codex line the first time.
local function tell(id, line)
  if met(id) then return (line and (line .. "  ") or "") .. (lineOf(id) or "") end
  return line
end

-- ── sounds at body-local points (the planet moves: re-placed each frame) ───
local ringing = {}
local function play_at(clip, bname, lx, ly, lz, o)
  if not (audio and audio.play) then return nil end
  local b = space.body(bname)
  if not b then return nil end
  o = o or {}
  local ok, h = pcall(audio.play, clip, b.x + lx, b.y + ly, b.z + lz, {
    track = "SFX", mode = "Spatial", falloff = "Inverse", minDistance = o.min or 5, maxDistance = o.max or 60,
    volume = o.volume or 0.8, pitch = o.pitch or 1.0 })
  if ok and h then ringing[#ringing + 1] = { h = h, body = bname, lx = lx, ly = ly, lz = lz, till = now() + (o.secs or 5) } end
  return ok and h or nil
end
local function ring_update()
  if #ringing == 0 then return end
  local keep = {}
  for _, r in ipairs(ringing) do
    local b = space.body(r.body)
    if b and now() < r.till then
      pcall(r.h.setPosition, r.h, b.x + r.lx, b.y + r.ly, b.z + r.lz)
      keep[#keep + 1] = r
    end
  end
  ringing = keep
end

local CLIPS = {
  crack = "audio/ambience/cave_crack.ogg",
  ticks = { "audio/ambience/cave_tick_1.ogg", "audio/ambience/cave_tick_2.ogg", "audio/ambience/cave_tick_3.ogg" },
  trickle = "audio/ambience/cave_trickle.ogg",
  falls = { "audio/ambience/cave_rockfall_1.ogg", "audio/ambience/cave_rockfall_2.ogg" },
  hits = { "audio/ambience/cave_slab_hit_1.ogg", "audio/ambience/cave_slab_hit_2.ogg" },
  whump = "audio/ambience/cave_gas_whump.ogg",
  boom = "audio/foley/explosion_far.ogg",
}

-- ── the body's saved sets ───────────────────────────────────────────────────
local cur = { body = nil, fell = {}, burnt = {}, seen = {} }
local function load_body(name)
  cur.body = name
  local function set_of(k)
    local l = sget(k .. name)
    local s = {}
    if type(l) == "table" then for _, v in ipairs(l) do s[v] = true end end
    return s
  end
  cur.fell = set_of("cave.fell.")
  cur.burnt = set_of("cave.burnt.")
  local seen = sget("cave.seen." .. name)
  cur.seen = type(seen) == "table" and seen or {}
end
local function save_set(k, set)
  local l = {}
  for v in pairs(set) do l[#l + 1] = v end
  table.sort(l)
  sset(k .. cur.body, l)
end
function fellCount() local n = 0 for _ in pairs(cur.fell) do n = n + 1 end return n end

-- ── the air (cave_field.airAt asks: cached per probe near the eye) ─────────
local air_cache = { n = -1, x = 0, y = 0, z = 0, gases = nil }
probePocket = nil      -- (probes; see gases_local)
local function world_air_p(name)
  local cl = ref("climate")
  local w = cl and cl.worldOf and cl.worldOf(name)
  local air = type(w) == "table" and w.air or nil
  if type(air) ~= "table" then return 0, nil, w end
  return air.p0 or 0, air, w
end
-- The cave's gases at a BODY-LOCAL point of body `name` (bar), or nil.
local function gases_local(name, x, y, z)
  local cf = ref("cave_field")
  local ck = kinds()
  if not (cf and ck and cf.worldInfo) then return nil end
  local wi = cf.worldInfo(name)
  if not wi then return nil end
  local p0 = world_air_p(name)
  local k = airScale(p0)
  if k <= 0 then return nil end
  -- the kind of the region the point is in (cave_field's forced kind for probes)
  local kind
  local fk = cf.params and cf.params.forceKind
  if fk and fk ~= "" and ck.KINDS[fk] then kind = fk
  else kind = ck.regionOf(wi.seed, x, y, z, wi.R, wi.cdepth, wi.f, wi.ty, wi.fam) end
  local g, pk, share = airAtLocal(wi.seed, kind, x, y, z, cur.burnt, P("forceAir"))
  if not g then return nil end
  -- (probes) a pocket put where a probe wants it: { x, y, z (body-local), r, gas, key }
  local pp = probePocket
  if pp and not (cur.burnt[pp.key] and pp.gas.CH4) then
    local ps = pocketShare({ cx = pp.x, cy = pp.y, cz = pp.z, r = pp.r, gas = pp.gas }, x, y, z)
    if ps > 0 then
      for gname, v in pairs(pp.gas) do g[gname] = (g[gname] or 0) + v * ps end
      if ps > share then pk, share = { key = pp.key, gas = pp.gas, name = "probe pocket" }, ps end
    end
  end
  local out, any = {}, false
  for gname, v in pairs(g) do if v > 0 then out[gname] = v * k; any = true end end
  return any and out or nil, pk, share
end
function airAtWorld(x, y, z)
  local cf = ref("cave_field")
  if not (cf and cf.caveKind) then return nil end
  local name = cf.probeBody or (space and space.dominant and space.dominant(x, y, z))
  local b = name and space.body(name)
  if not b then return nil end
  local lx, ly, lz = x - b.x, y - b.y, z - b.z
  local e = cf.eyeLocal
  -- (only near the crew: the probe's cave)
  if not e or len(lx - e[1], ly - e[2], lz - e[3]) > 40 then return nil end
  if air_cache.n == (cf.probeN or 0) and air_cache.body == name and len(lx - air_cache.x, ly - air_cache.y, lz - air_cache.z) < 2.0 then
    return air_cache.gases
  end
  local g = gases_local(name, lx, ly, lz)
  air_cache = { n = cf.probeN or 0, body = name, x = lx, y = ly, z = lz, gases = g }
  return g
end

-- ── rockfall ────────────────────────────────────────────────────────────────
-- A fall under way: { body, lx, ly, lz (the roof point), ux, uy, uz (up), t0,
-- stage (0 dust, 1 slabs falling, 2 the pile), slabs, mat, slot, kind, H, W,
-- fx, fy, fz (the floor point), ax, ay, az (the passage's long axis), pile,
-- balls = { { x, y, z (body-local), r, done } } }. Everything is body-local
-- (the planet moves metres a tick: docs/positions-and-frames.md rule 1).
local fall = nil
local fall_t = -1e9
local function cell_key(x, y, z, size)
  return floor(x / size) .. "," .. floor(y / size) .. "," .. floor(z / size)
end
local function rock_at(bname, lx, ly, lz, ux, uy, uz)
  local mf = ref("mineral_field")
  local b = space.body(bname)
  if mf and mf.materialAt and b then
    local ok, m = pcall(mf.materialAt, b.x + lx + ux * 0.4, b.y + ly + uy * 0.4, b.z + lz + uz * 0.4)
    if ok and type(m) == "string" then return m end
  end
  return "regolith"
end
-- the roof rock's palette slot (the pile is painted with it, so the laser
-- cuts it as that rock and pays it as that rock)
local function slot_at(bname, lx, ly, lz, ux, uy, uz)
  local b = space.body(bname)
  if not (b and terrain and terrain.slotAt) then return nil end
  local ok, s = pcall(terrain.slotAt, b.x + lx + ux * 0.5, b.y + ly + uy * 0.5, b.z + lz + uz * 0.5)
  if ok and type(s) == "number" and s > 0 and s ~= 255 then return s end
  return nil
end
-- One terrain ray from body-local (ox, oy, oz) along unit (dx, dy, dz): → the
-- distance to rock, or `far` when none is that close.
local function ray(b, ox, oy, oz, dx, dy, dz, far)
  local ok, h = pcall(terrain.raycast, vec3(b.x + ox, b.y + oy, b.z + oz), vec3(dx, dy, dz), far)
  if ok and h and h.distance then return h.distance, h end
  return far, nil
end
-- Set a fall off over body-local point (px, py, pz). `why` "step" | "dig" |
-- "ignite" | "probe". opts = { dir = { x, y, z } (body frame: the way the
-- crew walks or digs), kind = "on" | "ahead" | "behind" | "face" (else
-- drawn by rockfallSpot), eye = { x, y, z } (where a ray along the passage
-- starts) }. Rays: one along the passage for a fall ahead or behind, one up,
-- one down, four across: a few a fall, none between.
function startRockfall(bname, px, py, pz, why, key, opts)
  if fall then return false end
  local b = space.body(bname)
  if not b then return false end
  opts = opts or {}
  local l = len(px, py, pz)
  local ux, uy, uz = px / l, py / l, pz / l
  -- the passage's direction, flat to the local up
  local dx, dy, dz = 0, 0, 0
  if type(opts.dir) == "table" then dx, dy, dz = opts.dir[1] or opts.dir.x or 0, opts.dir[2] or opts.dir.y or 0, opts.dir[3] or opts.dir.z or 0 end
  local du = dx * ux + dy * uy + dz * uz
  dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
  local dl = len(dx, dy, dz)
  if dl < 1e-3 then
    local ax, ay, az = 0, 1, 0
    if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
    dx, dy, dz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
    dl = len(dx, dy, dz)
  end
  dx, dy, dz = dx / dl, dy / dl, dz / dl
  local kind, along = opts.kind, 0
  if not kind then kind, along = rockfallSpot(why, math.random(), math.random())
  elseif kind == "ahead" or kind == "behind" then
    along = (SPOT_ALONG[1] + SPOT_ALONG[2]) * 0.5 * (kind == "behind" and -1 or 1)
  end
  -- ahead or behind: along the passage from where the crew is, short of rock
  if along ~= 0 then
    local e = opts.eye or { px, py, pz }
    local sg = along > 0 and 1 or -1
    local d = ray(b, e[1], e[2], e[3], dx * sg, dy * sg, dz * sg, math.abs(along) + 1.0)
    local go = math.max(0, math.min(math.abs(along), d - 1.0))
    px, py, pz = e[1] + dx * sg * go, e[2] + dy * sg * go, e[3] + dz * sg * go
    along = sg * go
  end
  -- the roof over the point and the floor under it
  local roof, h = ray(b, px + ux * 0.3, py + uy * 0.3, pz + uz * 0.3, ux, uy, uz, 30)
  if not h then return false end
  roof = roof + 0.3
  local down = ray(b, px, py, pz, -ux, -uy, -uz, 30)
  local rx, ry, rz = px + ux * roof, py + uy * roof, pz + uz * roof
  local fx, fy, fz = px - ux * down, py - uy * down, pz - uz * down
  local H = roof + down
  -- across, at half height: the passage's width each way (along dir and across it)
  local sx, sy, sz = uy * dz - uz * dy, uz * dx - ux * dz, ux * dy - uy * dx
  local mx, my, mz = fx + ux * H * 0.5, fy + uy * H * 0.5, fz + uz * H * 0.5
  local cap = 12
  local ca1 = ray(b, mx, my, mz, dx, dy, dz, cap)
  local ca2 = ray(b, mx, my, mz, -dx, -dy, -dz, cap)
  local cs1 = ray(b, mx, my, mz, sx, sy, sz, cap)
  local cs2 = ray(b, mx, my, mz, -sx, -sy, -sz, cap)
  -- the long axis is the more open one (a tunnel runs that way)
  local ax, ay, az, ta, tn, na = dx, dy, dz, { ca1, ca2 }, { cs1, cs2 }, { sx, sy, sz }, nil
  if cs1 + cs2 > ca1 + ca2 then ax, ay, az, ta, tn, na = sx, sy, sz, { cs1, cs2 }, { ca1, ca2 }, { dx, dy, dz } end
  local W = math.min(ta[1] + ta[2], tn[1] + tn[2])
  fall = { body = bname, lx = rx, ly = ry, lz = rz, ux = ux, uy = uy, uz = uz, t0 = now(), stage = 0, slabs = {},
           why = why, kind = kind, along = along, roof = roof, H = H, W = W,
           fx = fx, fy = fy, fz = fz, ax = ax, ay = ay, az = az, nx = na[1], ny = na[2], nz = na[3],
           ca = ta, cn = tn, mat = rock_at(bname, rx, ry, rz, ux, uy, uz), slot = slot_at(bname, rx, ry, rz, ux, uy, uz) }
  fall_t = now()
  if key then cur.fell[key] = true; save_set("cave.fell.", cur.fell) end
  stats.rockfalls = stats.rockfalls + 1
  -- the crack, at the roof (no caption: you hear it, you see the dust)
  play_at(CLIPS.crack, bname, rx - ux * 0.3, ry - uy * 0.3, rz - uz * 0.3, { volume = 1.0, pitch = 0.78 + 0.1 * math.random(), min = 8, max = 90, secs = 3 })
  play_at(CLIPS.trickle, bname, rx - ux * 0.5, ry - uy * 0.5, rz - uz * 0.5, { volume = 0.9, min = 4, max = 40, secs = 4 })
  if log then log(string.format("cave_hazards: rockfall (%s, %s %.1f m) roof %.1f m, passage %.1f m high %.1f m across, %s",
    tostring(why), kind, along, roof, H, W, fall.mat)) end
  last.rockfall = { t = now(), why = why, kind = kind, along = along, roof = roof, H = H, W = W, mat = fall.mat, slot = fall.slot, body = bname,
                    floor = { fx, fy, fz } }
  return true
end
-- (probes) a fall over the crew's eye, or `kind` ("ahead" | "behind") along `dir`
function forceRockfall(kind, dir)
  local cf = ref("cave_field")
  local e = cf and cf.eyeLocal
  if not (e and cf.probeBody) then return false end
  fall = nil
  return startRockfall(cf.probeBody, e[1], e[2], e[3], "probe", nil, { kind = kind, dir = dir, eye = e })
end

local function dust(bname, lx, ly, lz, ux, uy, uz, k)
  local b = space.body(bname)
  local fx = ref("vfx")
  if not b then return end
  local x, y, z = b.x + lx - ux * 0.4, b.y + ly - uy * 0.4, b.z + lz - uz * 0.4
  local o = { normal = vec3(-ux, -uy, -uz), intensity = k or 0.8, dust = true }
  if fx and fx.emit then
    pcall(fx.emit, "LaunchDust", x, y, z, o)
    pcall(fx.emit, "DigClods", x, y, z, { normal = vec3(-ux, -uy, -uz), intensity = 0.6 })
  elseif spawnEffect then
    pcall(spawnEffect, "LaunchDust", vec3(x, y, z), { normal = vec3(-ux, -uy, -uz) })
  end
end

local seq = 0
local function drop_slabs()
  local f = fall
  local u = {}
  for i = 1, 14 do u[i] = math.random() end
  local plan = rockfallPlan(u)
  local b = space.body(f.body)
  if not (b and spawn) then return end
  for i, s in ipairs(plan) do
    -- sized to the passage, and inside it: never in the roof or a wall
    local sc = slabScale(f.H, f.W, u[7 + i])
    local hs = LB_HALF * sc
    local a = clamp(s.dx, -(f.ca[2] - hs - 0.1), f.ca[1] - hs - 0.1)
    local c = clamp(s.dz, -(f.cn[2] - hs - 0.1), f.cn[1] - hs - 0.1)
    if f.ca[1] + f.ca[2] < 2 * hs + 0.2 then a = 0 end
    if f.cn[1] + f.cn[2] < 2 * hs + 0.2 then c = 0 end
    local drop = math.min(hs + 0.25, math.max(hs, f.H - hs - 0.05))
    local lx = f.lx - f.ux * drop + f.ax * a + f.nx * c
    local ly = f.ly - f.uy * drop + f.ay * a + f.ny * c
    local lz = f.lz - f.uz * drop + f.az * a + f.nz * c
    seq = seq + 1
    local nm = string.format("CaveSlab %d", seq)
    local rec = { name = nm, s = sc, lx = lx, ly = ly, lz = lz, hit = false, t0 = now(), landed = false }
    f.slabs[#f.slabs + 1] = rec
    local w = space.body(f.body)
    spawn("LooseBoulder", vec3(w.x + lx, w.y + ly, w.z + lz), function(n)
      n.name = nm
      rec.n = n
      pcall(function() n.scale = sc end)
      pcall(n.setAngles, n, math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
      local mf = ref("mineral_field")
      if mf and mf.adoptBody then pcall(mf.adoptBody, n, "LooseBoulder", f.mat, floor(3 * sc ^ 3 + 0.5) + 1, sc) end
      -- it FALLS: started downward (planet-relative, as node.vel is), which
      -- also wakes it (a body spawned still was seen hanging in the air,
      -- 2026-11-11 hazardprobe before-shots)
      local function go()
        if n.valid == false then return end
        pcall(function() n.asleep = false; n.vel = vec3(-f.ux * 2.0, -f.uy * 2.0, -f.uz * 2.0) end)
      end
      if assembly and assembly.rebuild then
        local okr = pcall(assembly.rebuild, n, go)
        if not okr then go() end
      else go() end
      -- no sky in a cave (W4's finding): the rock's own colour, no sky sheen
      rec.look_t = now()
      stats.slabs = stats.slabs + 1
    end)
  end
  local fa = CLIPS.falls[math.random(1, #CLIPS.falls)]
  play_at(fa, f.body, f.lx - f.ux * 1.5, f.ly - f.uy * 1.5, f.lz - f.uz * 1.5, { volume = 1.0, min = 8, max = 100, secs = 5 })
  dust(f.body, f.lx, f.ly, f.lz, f.ux, f.uy, f.uz, 1.2)
  last.rockfall.slabs = #plan
end

-- The crew's feet and head, body-local, this frame (nil off foot).
local function crew_seg(b)
  local wk = ref("planet_walker")
  local a = (wk and wk.node) or (find and find("Astronaut"))
  if not (a and a.valid ~= false and b) then return nil end
  local ax, ay, az = a.x - b.x, a.y - b.y, a.z - b.z
  local al = math.max(1e-6, len(ax, ay, az))
  local ux, uy, uz = ax / al, ay / al, az / al
  return { ax - ux * 0.9, ay - uy * 0.9, az - uz * 0.9 }, { ax + ux * 0.9, ay + uy * 0.9, az + uz * 0.9 }
end
-- The pile's balls, body-local, on the floor under the fall along the passage.
local function plan_pile(f)
  local p = rubblePile(f.H, f.W, math.random())
  f.pile = p
  f.balls = {}
  -- a fall ahead of or behind the crew heaps up away from them (the passage
  -- closes between them and the far side, not on their boots): each ball
  -- slid along the passage until it clears them (pileAlong)
  local ac = nil
  if f.kind ~= "on" then
    local b = space.body(f.body)
    local feet = b and crew_seg(b)
    if feet then ac = (feet[1] - f.fx) * f.ax + (feet[2] - f.fy) * f.ay + (feet[3] - f.fz) * f.az end
  end
  for _, q in ipairs(p.balls) do
    local a = ac and pileAlong(q.a, q.r, ac) or q.a
    f.balls[#f.balls + 1] = { x = f.fx + f.ax * a, y = f.fy + f.ay * a, z = f.fz + f.az * a, r = q.r, done = false }
  end
  last.rockfall.pile = { r = p.r, need = p.need, blocks = p.blocks, n = #f.balls }
end
-- Land what can land of the pile: each ball that would not bury the crew.
-- → true once every ball is down.
local function land_pile(f)
  local b = space.body(f.body)
  if not (b and terrain and terrain.sculpt) then return true end
  local feet, head = crew_seg(b)
  local left, landed = 0, 0
  for _, q in ipairs(f.balls) do
    if not q.done then
      if feet and pileBuries({ q.x, q.y, q.z }, q.r, feet, head) and now() - f.t0 < DUST_S + PILE_WAIT then
        left = left + 1
      else
        q.done = true
        landed = landed + 1
        local wx, wy, wz = b.x + q.x, b.y + q.y, b.z + q.z
        pcall(terrain.sculpt, wx, wy, wz, q.r, 1.0, "raise", { hardness = 0.55, falloff = "smooth" })
        if f.slot and terrain.paintTexture then pcall(terrain.paintTexture, wx, wy, wz, q.r + 0.25, f.slot) end
        -- the slabs it covers go into it (buried rubble), the rest stay loose
        -- (over the heap's footprint, anywhere up to the roof: a slab
        -- caught on a ledge above it comes down with it)
        for _, s in ipairs(f.slabs) do
          local n = s.n
          if n and n.valid ~= false and not s.buried then
            local ox, oy, oz = n.x - wx, n.y - wy, n.z - wz
            local hu = ox * f.ux + oy * f.uy + oz * f.uz
            local d = len(ox - f.ux * hu, oy - f.uy * hu, oz - f.uz * hu)
            if d < q.r + 0.2 and hu > -q.r and hu < f.H + 0.5 then
              s.buried = true
              pcall(function() n:destroy() end)
            end
          end
        end
        stats.pileBalls = (stats.pileBalls or 0) + 1
      end
    end
  end
  if landed > 0 then
    -- the heap settling: its dust and a last knock of rock
    dust(f.body, f.fx + f.ux * 1.2, f.fy + f.uy * 1.2, f.fz + f.uz * 1.2, f.ux, f.uy, f.uz, 1.4)
    play_at(CLIPS.hits[math.random(1, #CLIPS.hits)], f.body, f.fx + f.ux * 0.8, f.fy + f.uy * 0.8, f.fz + f.uz * 0.8,
      { volume = 0.9, min = 4, max = 60, secs = 3 })
    last.pile = { t = now(), r = f.pile.r, blocks = f.pile.blocks, landed = landed, left = left, body = f.body,
                  x = f.fx, y = f.fy, z = f.fz, ax = f.ax, ay = f.ay, az = f.az, H = f.H, W = f.W }
    if log then log(string.format("cave_hazards: rubble pile r %.1f m in a %.1f m passage (%s), %d ball(s) down, %d waiting",
      f.pile.r, f.H, f.pile.blocks and "closes it" or "chokes it", landed, left)) end
  end
  if left == 0 then stats.piles = (stats.piles or 0) + 1 end
  return left == 0
end

-- Follow the fall: dust while it hangs, the slabs, their hits on the crew,
-- then the pile they leave.
local function fall_update()
  local f = fall
  local t = now() - f.t0
  if f.stage == 0 then
    -- dust sifting down while it hangs (three puffs over DUST_S)
    local want = floor(t / 0.5)
    if want > (f.puffs or -1) and t < DUST_S then f.puffs = want; dust(f.body, f.lx, f.ly, f.lz, f.ux, f.uy, f.uz, 0.5 + 0.2 * want) end
    if t >= DUST_S then f.stage = 1; drop_slabs(); plan_pile(f) end
    return
  end
  if f.stage == 2 then
    if land_pile(f) then fall = nil end
    return
  end
  -- the slabs' look, a beat after their models land: the cave's rock, no sky reflection
  for _, s in ipairs(f.slabs) do
    if s.n and s.n.valid ~= false and s.look_t and not s.looked and now() - s.look_t > 0.3 then
      s.looked = true
      local cf = ref("cave_field")
      local wi = cf and cf.worldInfo and cf.worldInfo(f.body)
      local c = wi and wi.rock or { 0.45, 0.42, 0.4 }
      local kids = (s.n.children and s.n:children()) or {}
      kids[#kids + 1] = s.n
      for _, k in ipairs(kids) do
        if k.setMaterial then pcall(k.setMaterial, k, { reflectivity = 0 }) end
        if k.setTint then pcall(k.setTint, k, { color = { c[1] * 1.6, c[2] * 1.6, c[3] * 1.6 }, ambient = 3.0 }) end
      end
    end
  end
  -- THE FALL HELD TO GRAVITY. In a cave the engine let a loose body drift
  -- (2026-11-11 hazardprobe only=slabdiag: wake "unsupported", its speed
  -- along up wandering ±3 m/s, 2.5 m down in 3 s; the same prefab on the
  -- surface falls and settles; engine card draft in the slice's notes). A
  -- slab still over the floor and falling slower than gravity would have it
  -- is given that speed (planet-relative, as node.vel is); the engine still
  -- owns its collisions and its rest.
  do
    local b = space.body(f.body)
    local tf = t - DUST_S
    if b and tf > 0 and tf < 3.0 then
      if not f.g then
        local g = 6
        if space.gravity then
          local ok, gx, gy, gz = pcall(space.gravity, b.x + f.fx, b.y + f.fy, b.z + f.fz)
          if ok and gx then g = len(gx, gy, gz) end
        end
        f.g = g
      end
      for _, s in ipairs(f.slabs) do
        local n = s.n
        if n and n.valid ~= false and not s.landed and not s.buried then
          local hgt = (n.x - b.x - f.fx) * f.ux + (n.y - b.y - f.fy) * f.uy + (n.z - b.z - f.fz) * f.uz
          local hs = LB_HALF * (s.s or 1)
          s.hgt = hgt - hs
          local okv, v = pcall(function() return n.vel end)
          if okv and v and hgt > hs + 0.25 then
            local vu = v.x * f.ux + v.y * f.uy + v.z * f.uz
            local want = -math.min(f.g * tf + 2.0, sqrt(2 * f.g * math.max(0.1, f.H)) + 2.0)
            if vu > want + 0.5 then
              local d = want - vu
              pcall(function() n.vel = vec3(v.x + f.ux * d, v.y + f.uy * d, v.z + f.uz * d) end)
            end
          end
        end
      end
    end
  end
  -- hits: a slab within reach of the crew's chest while it still moves fast
  local wk = ref("planet_walker")
  local a = (wk and wk.node) or (find and find("Astronaut"))
  local C = ref("crew")
  local all_down = #f.slabs > 0
  if a and a.valid ~= false then
    local b = space.body(f.body)
    for _, s in ipairs(f.slabs) do
      local n = s.n
      if n and n.valid ~= false and not s.hit and b then
        local ax, ay, az = a.x - b.x, a.y - b.y, a.z - b.z
        local al = len(ax, ay, az)
        local cx, cy, cz = ax + ax / al * 1.0, ay + ay / al * 1.0, az + az / al * 1.0
        local d = len(n.x - b.x - cx, n.y - b.y - cy, n.z - b.z - cz)
        -- its speed from its body-relative positions frame to frame (rule 4)
        local lx, ly, lz = n.x - b.x, n.y - b.y, n.z - b.z
        local v = 0
        local fdt = now() - (s.pt or now())
        if s.px and fdt > 1e-4 then v = len(lx - s.px, ly - s.py, lz - s.pz) / fdt end
        s.px, s.py, s.pz, s.pt = lx, ly, lz, now()
        s.v = v
        if d < 0.75 + 0.45 * s.s and v > 2.5 then
          s.hit = true
          local amt = slabHurt(s.s, v)
          local id = C and C.activeId and C.activeId()
          if id and C.hurt then pcall(C.hurt, id, amt, "crushed", "a rockfall") end
          stats.hits = stats.hits + 1
          last.hit = { t = now(), amount = amt, speed = v, s = s.s }
          play_at(CLIPS.hits[math.random(1, #CLIPS.hits)], f.body, n.x - b.x, n.y - b.y, n.z - b.z, { volume = 0.9, min = 3, max = 40, secs = 3 })
          if log then log(string.format("cave_hazards: hit by a falling slab, %.0f %% of health", amt * 100)) end
        elseif not s.landed and t > DUST_S + 0.6 and v < 1.0 and (s.hgt or 0) < 0.5 then
          s.landed = true
          play_at(CLIPS.hits[math.random(1, #CLIPS.hits)], f.body, n.x - b.x, n.y - b.y, n.z - b.z, { volume = 0.7 * s.s, min = 4, max = 50, secs = 3 })
        end
      end
      if not s.landed and not s.hit then all_down = false end
    end
  end
  -- the slabs are down (or 3 s have passed): what came down becomes the heap
  if (all_down and t > DUST_S + 0.9) or t > DUST_S + 3.0 then
    f.stage = 2
    if land_pile(f) then fall = nil end
  end
end
-- (probes) the fall under way: its stage and pile, or nil
function fallState()
  if not fall then return nil end
  local waiting = 0
  for _, q in ipairs(fall.balls or {}) do if not q.done then waiting = waiting + 1 end end
  return { stage = fall.stage, kind = fall.kind, H = fall.H, W = fall.W, pile = fall.pile, waiting = waiting, slabs = #fall.slabs }
end

-- ── methane ignition ────────────────────────────────────────────────────────
local function laser_firing()
  local tb = ref("tool_belt")
  if not (tb and tb.toolId) then return false end
  local ok, id = pcall(tb.toolId)
  if not (ok and id == "laser") then return false end
  return tb.inUse == true and (tb.charge or 0) > 0.15 and not tb.cutMode
end
-- The laser's aim point, body-local, this frame (tool_belt.aimNow; a call
-- through a script handle may hand back only its first value, so a table or a
-- missing y is taken as no aim). → lx, ly, lz or nil
local function aim_local(bname)
  local tb = ref("tool_belt")
  local b = space.body(bname)
  if not (tb and tb.aimNow and b) then return nil end
  local ok, ax, ay, az = pcall(tb.aimNow)
  if not ok or ax == nil then return nil end
  if type(ax) == "table" then ax, ay, az = ax.x, ax.y, ax.z end
  if type(ax) ~= "number" or type(ay) ~= "number" or type(az) ~= "number" then return nil end
  return ax - b.x, ay - b.y, az - b.z
end

function ignite(bname, lx, ly, lz, pk, frac)
  local b = space.body(bname)
  if not b then return false end
  if pk and pk.key then cur.burnt[pk.key] = true; save_set("cave.burnt.", cur.burnt) end
  air_cache.n = -1
  local x, y, z = b.x + lx, b.y + ly, b.z + lz
  local fx = ref("vfx")
  if fx and fx.flash then pcall(fx.flash, x, y, z, 1.0, 0.55, 0.22, 7.0, 22, 0.55) end
  if fx and fx.emit then
    pcall(fx.emit, "ExplosionSmall", x, y, z, { intensity = 1.2 })
    pcall(fx.emit, "SmokePuff", x, y, z, { intensity = 1.0 })
  end
  play_at(CLIPS.whump, bname, lx, ly, lz, { volume = 1.0, pitch = 0.62, min = 6, max = 120, secs = 2 })
  play_at(CLIPS.boom, bname, lx, ly, lz, { volume = 0.7, pitch = 0.8, min = 10, max = 200, secs = 4 })
  local su, C = ref("suit"), ref("crew")
  local helm = su and su.helmetOn and su.helmetOn()
  local k = clamp(((frac or LEL) - LEL) / LEL, 0, 1)
  local amt = (0.25 + 0.45 * k) * (helm and 0.6 or 1.0)
  local id = C and C.activeId and C.activeId()
  if id and C.hurt then pcall(C.hurt, id, amt, "explosion", "a methane pocket lit by the laser") end
  stats.ignitions = stats.ignitions + 1
  stats.harm = stats.harm + amt
  last.ignite = { t = now(), amount = amt, frac = frac, helmet = helm, key = pk and pk.key }
  say("ignite", "FIREDAMP", tell("ch4", string.format("The laser lit the methane: burns, %.0f %% of your health.", amt * 100)), 4.5, 3)
  return true
end
function forceIgnite()
  local cf = ref("cave_field")
  local e = cf and cf.eyeLocal
  if not (e and cf.probeBody) then return false end
  return ignite(cf.probeBody, e[1], e[2], e[3], nil, 0.09)
end

-- ── the probe step ──────────────────────────────────────────────────────────
local prev = { n = -1, eye = nil, gt = nil, t = 0, tick_t = 0, drop_n = 0 }
local function has_item(id)
  local inv, C = ref("inventory"), ref("crew")
  local pack = (C and C.packOf and C.packOf()) or "astro"
  if not (inv and inv.itemCount) then return false end
  local ok, n = pcall(inv.itemCount, pack, id)
  return ok and (n or 0) > 0
end

local function first_entry(name, kind)
  if not firstEntry(cur.seen, kind) then return end
  cur.seen[#cur.seen + 1] = kind
  sset("cave.seen." .. name, cur.seen)
  local ck = kinds()
  local K = ck and ck.KINDS[kind] or {}
  local SV, RS = ref("survey"), ref("research")
  local comp = nil
  if SV and SV.record then
    local ok, r = pcall(SV.record, name)
    if ok and type(r) == "table" and type(r.L) == "table" then comp = r.L.comp end
  end
  local newc = compGain(comp)
  if SV and SV.credit then pcall(SV.credit, name, "cave", { comp = newc }) end
  local rp = (K.rewards and K.rewards.rp) or 20
  if RS and RS.addPoints then pcall(RS.addPoints, rp, string.format("cave: %s on %s", K.label or kind, name)) end
  stats.firsts = stats.firsts + 1
  last.first = { t = now(), kind = kind, body = name, comp = newc, rp = rp }
  local fact = K.facts and K.facts[1] or ""
  -- (progression P1) a feat: a cave kind entered (once a kind)
  local F = ref("feats")
  if F and F.mark then pcall(F.mark, "cave_kinds", { key = kind, b = name }) end
  say("first:" .. kind, string.upper(K.label or kind) .. string.format(" · +%d RP", rp), fact, 5.0)
end

local function step_probe(cf, name, gdt, rdt)
  local e = cf.eyeLocal
  local kind = cf.caveKind
  state.kind = kind
  local ck = kinds()
  local hz = ck and kind and ck.hazardsOf(kind) or {}
  local wk = ref("planet_walker")
  local su, C = ref("suit"), ref("crew")
  local helm = not (su and su.helmetOn) or su.helmetOn()
  local id = C and C.activeId and C.activeId()
  -- 1. first entry into a kind on this world
  first_entry(name, kind)
  -- 2. the air where the crew breathes it (the helmet's height)
  local g, pk, share = gases_local(name, e[1], e[2], e[3])
  local p0, wair = world_air_p(name)
  local ptot, o2 = p0, (wair and wair.gases and wair.gases.O2) or 0
  if g then
    local add = 0
    for _, v in pairs(g) do add = add + v end
    o2 = o2 * p0 / max(1e-6, p0 + add)
    ptot = p0 + add
  end
  local rd = readout(g, ptot, o2)
  state.gas = rd
  if rd.level >= 2 and rd.gas then
    local hid = HAZARD_OF_GAS[rd.gas] or "co2"
    if rd.flammable then
      say("flam:" .. tostring(pk and pk.key), "FLAMMABLE AIR", tell("ch4", string.format("Methane at %.0f %%. Any spark lights it: not the laser.", (rd.frac or 0) * 100)), 4.0, 30)
    elseif rd.level >= 3 then
      say("bad:" .. tostring(pk and pk.key), "BAD AIR", tell(hid, (rd.text or "") .. ": over the safe limit."), 3.5, 30)
    end
    last.gas = { t = now(), text = rd.text, level = rd.level, gas = rd.gas, pocket = pk and pk.name }
  end
  -- bare-headed in it: hurt (the dare; the suit closes itself otherwise)
  if not helm and g then
    local h, worst = gasHarm(g)
    if h > 0 and id and C.hurt then
      pcall(C.hurt, id, h * rdt / 60, "gas", "breathed " .. (LABEL[worst] or worst) .. " bare-headed")
      stats.harm = stats.harm + h * rdt / 60
      say("dare:" .. worst, "BREATHING " .. (LABEL[worst] or worst), "Your head swims. Helmet on.", 2.5, 8)
    end
  end
  -- 3. methane and the laser
  if rd.flammable and laser_firing() then
    local lx, ly, lz = aim_local(name)
    if not lx then lx, ly, lz = e[1], e[2], e[3] end
    ignite(name, lx, ly, lz, pk, rd.frac)
    if (hz.unstable or 0) > 0 and not fall then startRockfall(name, lx, ly, lz, "ignite") end
  end
  -- 4. the roof: ticks in an unstable cell; a step or a dig sets it off
  local wi = cf.worldInfo and cf.worldInfo(name)
  local seed = wi and wi.seed or 1
  local function unstable_cell(x, y, z)
    local i, j, k = floor(x / UNSTABLE_CELL), floor(y / UNSTABLE_CELL), floor(z / UNSTABLE_CELL)
    local key = i .. "," .. j .. "," .. k
    return unstableAt(seed, hz.unstable, i, j, k, P("forceUnstable")) and not cur.fell[key], key
  end
  local here, hkey = unstable_cell(e[1], e[2], e[3])
  state.unstable = here
  if here and cf.roofLocal and now() >= (prev.tick_t or 0) then
    prev.tick_t = now() + 3 + 5 * math.random()
    local r = cf.roofLocal
    play_at(CLIPS.ticks[math.random(1, #CLIPS.ticks)], name, r[1], r[2], r[3], { volume = 0.9, pitch = 0.85 + 0.3 * math.random(), min = 3, max = 30, secs = 2 })
    last.tick = { t = now(), key = hkey }
  end
  local speed = 0
  if prev.eye and rdt > 0 then speed = len(e[1] - prev.eye[1], e[2] - prev.eye[2], e[3] - prev.eye[3]) / rdt end
  state.speed = speed
  if not fall and now() - fall_t > FALL_COOLDOWN then
    if here and speed > 0.6 and speed < 12 and math.random() < STEP_P then
      -- (on the crew, or ahead or behind them along the way they walk)
      local wd = { e[1] - prev.eye[1], e[2] - prev.eye[2], e[3] - prev.eye[3] }
      startRockfall(name, e[1], e[2], e[3], "step", hkey, { dir = wd, eye = e })
    elseif laser_firing() then
      local lx, ly, lz = aim_local(name)
      if lx then
        -- (back toward the crew: out of the rock the beam bites, under the
        -- roof of the cut; or the way they came in)
        local dx, dy, dz = e[1] - lx, e[2] - ly, e[3] - lz
        local dl = max(1e-6, len(dx, dy, dz))
        local bk = math.min(1.2, dl * 0.5)
        lx, ly, lz = lx + dx / dl * bk, ly + dy / dl * bk, lz + dz / dl * bk
        local dig_here, dkey = unstable_cell(lx, ly, lz)
        if dig_here and math.random() < DIG_P then
          startRockfall(name, lx, ly, lz, "dig", dkey, { dir = { -dx, -dy, -dz }, eye = e })
        end
      end
    end
  end
  -- 5. cold and heat (thermal.suitThermal): the heater on the lamp cell
  local cl = ref("climate")
  local w = cl and cl.worldOf and cl.worldOf(name)
  local wk_ = type(w) == "table" and type(w.bio) == "table" and w.bio.tempK or nil
  local dfrac = (wi and wi.cdepth and wi.cdepth > 0) and clamp((cf.depth or 0) / wi.cdepth, 0, 1) or 0.5
  local tK = (hz.cold or hz.heat) and caveTempK(wk_, kind, hz, dfrac) or nil
  state.tempK = tK
  local TH = ref("thermal")
  state.heater, state.therm = 0, nil
  if tK and TH and TH.suitThermal then
    local draw, harm, tkind = TH.suitThermal(tK, helm)
    state.heater, state.therm = draw, tkind
    if draw > 0 then
      local fl = ref("flashlight")
      if fl and fl.cellAdd then pcall(fl.cellAdd, -draw * gdt / 3600) end
    end
    if tkind then
      say("therm:" .. tkind .. ":" .. kind, tkind == "cold" and "COLD" or "HEAT",
        tell(tkind, string.format("%d °C. The suit's %s draws on the lamp cell.", floor(tK - 273.15 + 0.5), tkind == "cold" and "heater" or "cooling")), 3.5, 120)
    end
    if harm > 0 and id and C.hurt then
      pcall(C.hurt, id, harm * rdt / 60, tkind == "cold" and "cold" or "hotair", tkind == "cold" and "frostbite, bare-headed" or "heat stroke, bare-headed")
      stats.harm = stats.harm + harm * rdt / 60
    end
  end
  -- 6. dose within 6 m of a pitchblende seam (the reactor's dose step)
  local mf = ref("mineral_field")
  state.dose = 0
  local fdo = P("forceDoseOre") or 0
  if mf and (fdo > 0 or ((mf.doseT or -1) >= 0 and now() - (mf.doseT or 0) < 1.0)) then
    local share6 = seamShare(mf.doseFrom)
    local ore = fdo > 0 and fdo or (mf.doseOre or 0)
    local rate = doseRate(ore, cf.enclosure or 0, share6)
    state.dose = rate * 3600
    if rate > 0 and id and C.addDose then
      pcall(C.addDose, id, rate * gdt, "a pitchblende seam", rate)
      stats.dosed = stats.dosed + rate * gdt
      last.dose = { t = now(), rate = rate * 3600, ore = ore, forced = fdo > 0 }
      say("dose", "RADON", tell("dose", string.format("A pitchblende seam within metres: %.1f %% of a lethal dose an hour here.", rate * 3600 * 100)), 4.0, 90)
    end
  end
  -- 7. a drop ahead: the rope hint (two probes running, so a glance at a
  -- ledge does not caption)
  local drop = cf.hazard and cf.hazard.drop or 0
  state.drop = drop
  if drop >= DROP_HINT then prev.drop_n = prev.drop_n + 1 else prev.drop_n = 0 end
  if prev.drop_n >= 2 then
    local line = dropHint(drop, has_item("rope"))
    if line and say("drop", "DROP", tell("drop", line), 3.5, 25) then last.drop = { t = now(), drop = drop } end
  end
  -- 8. flooding ahead (climate's cave_wet fill)
  state.flood = false
  local a = cf.aheadLocal
  if a and cl and cl.seaRadius and cl.seaDepth then
    local sea = cl.seaRadius(name) or 0
    local ar = len(a[1], a[2], a[3])
    if sea > 0 and ar < sea then
      local b = space.body(name)
      local ok, sd = pcall(cl.seaDepth, b.x + a[1] * (1 + 0.5 / ar), b.y + a[2] * (1 + 0.5 / ar), b.z + a[3] * (1 + 0.5 / ar))
      if ok and sd and sd > 0.3 then
        state.flood = true
        if say("flood", "FLOODED", tell("flood", "The passage ahead is under water."), 3.0, 30) then last.flood = { t = now(), depth = sd } end
      end
    end
  end
  -- publish
  hazard = cf.hazard
  if type(hazard) == "table" then
    hazard.gas = rd.gas
    hazard.gasLevel = rd.level
    hazard.flammable = rd.flammable
    hazard.unstableHere = here
    hazard.tempK = tK
    hazard.doseNow = state.dose
    hazard.flood = state.flood or hazard.flood
  end
  prev.eye = { e[1], e[2], e[3] }
  stats.probes = stats.probes + 1
end

-- The status chips (status_hud): the gas reading and the cold or heat, in a
-- cave, on foot.
function chips()
  local out = {}
  if not state.kind then return out end
  local rd = state.gas
  if rd and rd.level >= 1 and rd.text then
    out[#out + 1] = { key = "gas", label = rd.flammable and "Flammable" or "Air", value = rd.text,
                      warn = rd.level >= 3, heavy = rd.level == 2 }
  end
  if state.therm and state.tempK then
    out[#out + 1] = { key = "therm", label = state.therm == "cold" and "Cold" or "Heat",
                      value = string.format("%d °C · suit %.0f %%/h", floor(state.tempK - 273.15 + 0.5), state.heater or 0),
                      heavy = true }
  end
  return out
end

function reset()
  fall, fall_t = nil, -1e9
  cur.fell, cur.burnt, cur.seen = {}, {}, {}
  if cur.body then save_set("cave.fell.", cur.fell); save_set("cave.burnt.", cur.burnt); sset("cave.seen." .. cur.body, {}) end
  sset("cave.codex", {})
  last = {}
end

function start(node)
  if audio and audio.preload then
    local l = { CLIPS.crack, CLIPS.trickle, CLIPS.whump }
    for _, c in ipairs(CLIPS.ticks) do l[#l + 1] = c end
    for _, c in ipairs(CLIPS.falls) do l[#l + 1] = c end
    for _, c in ipairs(CLIPS.hits) do l[#l + 1] = c end
    pcall(audio.preload, l)
  end
  local C = ref("crew")
  if C and type(C.CAUSE_TEXT) == "table" then
    C.CAUSE_TEXT.gas = C.CAUSE_TEXT.gas or "poisoned by cave gas"
    C.CAUSE_TEXT.cold = C.CAUSE_TEXT.cold or "frozen"
    C.CAUSE_TEXT.hotair = C.CAUSE_TEXT.hotair or "heat stroke"
  end
end

function update(node, dt)
  if fall then fall_update() end
  ring_update()
  if P("on") == false then return end
  local cf = ref("cave_field")
  if not cf then return end
  local n = cf.probeN or 0
  if n == prev.n then return end
  prev.n = n
  local t0 = wall()
  register_codex()
  local name = cf.probeBody
  if not (name and cf.caveKind and cf.eyeLocal) then
    state.kind, state.gas, state.therm, state.tempK, state.dose, state.unstable = nil, nil, nil, nil, 0, false
    prev.eye, prev.gt = nil, nil
    return
  end
  local wk = ref("planet_walker")
  if wk and (wk.onFoot == false or wk.downed) then state.kind = nil return end
  if name ~= cur.body then load_body(name); prev.eye = nil end
  local gt = space and space.time and space.time() or now()
  local gdt = prev.gt and clamp(gt - prev.gt, 0, 60) or 0
  local rdt = clamp(now() - (prev.t or now()), 0, 2)
  prev.gt, prev.t = gt, now()
  local ok, err = pcall(step_probe, cf, name, gdt, rdt)
  if not ok and log then log("cave_hazards: probe failed: " .. tostring(err)) end
  stats.ms = stats.ms + ((wall() - t0) * 1000 - stats.ms) * 0.2
  if P("debug") and log then
    local g = state.gas
    log(string.format("cave_hazards: %s gas %s lvl %d T %s dose %.4f unstable %s drop %.1f flood %s",
      tostring(state.kind), g and tostring(g.text) or "-", g and g.level or 0, tostring(state.tempK), state.dose or 0,
      tostring(state.unstable), state.drop or 0, tostring(state.flood)))
  end
end
