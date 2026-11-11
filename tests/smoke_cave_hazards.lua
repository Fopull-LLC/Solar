-- SMOKE HARNESS: cave hazards and rewards (worlds W5, 2026-11-10).
--
--   * the rules (scripts/cave_hazards.lua, pure): every cave kind has its air
--     (a background and pockets that fit their cells); a pocket's gas falls
--     off from its heart so the reading CLIMBS as you walk in (telegraphed);
--     heavy gas pools low, methane at the roof; a burnt-out methane pocket
--     stays burnt; a vacuum holds no cave gas; the readout's levels and its
--     words; methane burns between 5 and 15 % with oxygen to carry a flame;
--     bare-headed harm by the gas and how far over; unstable cells by the
--     kind's chance; 1–3 slabs; a slab's hurt by size and speed; the cave's
--     air temperature; the dose within 6 m of a pitchblende seam; the drop's
--     rope hint; first entry raises composition by 0.15; a codex line per
--     hazard; every recording on disk and in audio/SOURCES.md
--   * atmo.mergeCave / caveVerdict and the suit: a CO2 sump under an
--     Earth-like sky is toxic, the background is not; the helmet closes
--     itself in bad cave air, comes off again if the crew insists (never
--     prevented), and a world's own refusals still refuse
--   * thermal.suitThermal: the heater's draw in an ice cave, the harm
--     bare-headed
--   * the scene half over stubs (a cave_field that probes, the crew, the
--     survey): first entry credits once; bad air shows and hurts bare-
--     headed; the laser lights a methane pocket and burns it out; a rockfall
--     cracks, dusts (no caption), drops 1–3 adopted slabs and a slab on the
--     crew hurts; it leaves a rubble pile (raised, painted the roof's rock)
--     that waits while the crew stands in it; a fall behind the crew;
--     the ice cave's heater draws on the lamp cell; the seam doses; the drop
--     captions with the rope; nothing runs between probes
--
--   luajit solar/tests/smoke_cave_hazards.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function exists(p)
  local f = io.open("solar/" .. p, "rb")
  if f then f:close() return true end
  return false
end
local function load(path, api)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return api.time or 0 end
    return api[k] or _G[k]
  end, __newindex = function(t, k, v) rawset(t, k, v) end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local CK = load("solar/scripts/cave_kinds.lua", {})
local H = load("solar/scripts/cave_hazards.lua", {})
local AT = load("solar/scripts/atmo.lua", {})
local TH = load("solar/scripts/thermal.lua", {})

-- ── the air table ──────────────────────────────────────────────────────────
for _, id in ipairs(CK.ORDER) do
  local A = H.AIR[id]
  ok(A ~= nil, id .. ": an air entry")
  if A then
    local sum = 0
    for _, pk in ipairs(A.pockets or {}) do
      sum = sum + pk.p
      ok(pk.r[1] > 0 and pk.r[2] >= pk.r[1] and pk.r[2] * 2 <= H.AIR_CELL, id .. ": a pocket fits its cell")
      for g in pairs(pk.gas) do ok(H.LIMIT[g] ~= nil, id .. ": pocket gas " .. g .. " has a limit") end
    end
    ok(sum <= 1, id .. ": pocket chances sum to at most 1")
    for g in pairs(A.base or {}) do
      ok(H.LIMIT[g] ~= nil, id .. ": background gas " .. g .. " has a limit")
      ok(A.base[g] < H.LIMIT[g], id .. ": the background alone is under the limit (" .. g .. ")")
    end
  end
end
-- the gas each kind's hazards name is in its air
for _, id in ipairs(CK.ORDER) do
  local gas = CK.hazardsOf(id).gas
  if gas then
    local found = (H.AIR[id].base or {})[gas] ~= nil
    for _, pk in ipairs(H.AIR[id].pockets) do if pk.gas[gas] then found = true end end
    ok(found, id .. ": its hazard gas " .. gas .. " is in its air")
  end
end

-- pockets: deterministic, at about their chance
do
  local n, hits = 3000, 0
  for i = 1, n do if H.airCellOf(77, "karst", i, 3, -i) then hits = hits + 1 end end
  local want = 0
  for _, pk in ipairs(H.AIR.karst.pockets) do want = want + pk.p end
  ok(math.abs(hits / n - want) < 0.04, string.format("karst pockets at their chance (%.2f vs %.2f)", hits / n, want))
  local a, b = H.airCellOf(77, "karst", 5, 6, 7), H.airCellOf(77, "karst", 5, 6, 7)
  ok((a == nil and b == nil) or (a.cx == b.cx and a.r == b.r and a.key == b.key), "a cell's pocket is the same every time")
  ok(H.airCellOf(77, "salt", 1, 2, 3) == nil, "a salt cavern has no pockets")
end

-- find a pocket of a gas in a kind (scanning cells on a sphere of radius 900)
local R = 900
local function find_pocket(kind, gas)
  for i = -40, 40 do
    for k = -40, 40 do
      local pk = H.airCellOf(4242, kind, i, math.floor((R - 30) / H.AIR_CELL), k)
      if pk and pk.gas[gas] then return pk end
    end
  end
end

-- ── the gradient: the reading climbs as you walk in ────────────────────────
do
  local pk = find_pocket("karst", "CO2")
  ok(pk ~= nil, "a karst world has a CO2 sump")
  if pk then
    ok(math.abs(H.pocketShare(pk, pk.cx, pk.cy, pk.cz) - 1) < 1e-9, "at the heart: the pocket's full gas")
    local l = math.sqrt(pk.cx ^ 2 + pk.cy ^ 2 + pk.cz ^ 2)
    local ux, uy, uz = pk.cx / l, pk.cy / l, pk.cz / l
    local above = H.pocketShare(pk, pk.cx + ux * pk.r * 0.4, pk.cy + uy * pk.r * 0.4, pk.cz + uz * pk.r * 0.4)
    local below = H.pocketShare(pk, pk.cx - ux * pk.r * 0.4, pk.cy - uy * pk.r * 0.4, pk.cz - uz * pk.r * 0.4)
    ok(below > above, string.format("CO2 pools low (below %.2f, above %.2f)", below, above))
    -- walk in along a tangent: 1 m steps from outside the ball to its heart
    local tx, ty, tz = -uz, 0, ux
    local tl = math.sqrt(tx * tx + tz * tz)
    tx, tz = tx / tl, tz / tl
    local levels, prev, mono = {}, -1, true
    for s = math.ceil(pk.r) + 1, 0, -1 do
      local x, y, z = pk.cx + tx * s, pk.cy + ty * s, pk.cz + tz * s
      local g = H.airAtLocal(4242, "karst", x, y, z)
      local p = 1 + (g.CO2 or 0)
      local rd = H.readout(g, p, 0.21 / p)
      levels[#levels + 1] = rd.level
      if (g.CO2 or 0) < prev - 1e-12 then mono = false end
      prev = g.CO2 or 0
    end
    ok(mono, "walking in, the CO2 only rises")
    local first_seen, first_toxic = nil, nil
    for i, lv in ipairs(levels) do
      if lv >= 1 and not first_seen then first_seen = i end
      if lv >= 3 and not first_toxic then first_toxic = i end
    end
    ok(first_seen and first_toxic and first_toxic - first_seen >= 2,
      string.format("telegraphed: the chip shows at least 2 m before the limit (%s → %s)", tostring(first_seen), tostring(first_toxic)))
    ok(levels[#levels] == 3, "at the heart of a sump: over the limit")
  end
  local mp = find_pocket("karst", "CH4")
  ok(mp ~= nil, "a karst world has firedamp")
  if mp then
    local l = math.sqrt(mp.cx ^ 2 + mp.cy ^ 2 + mp.cz ^ 2)
    local ux, uy, uz = mp.cx / l, mp.cy / l, mp.cz / l
    local above = H.pocketShare(mp, mp.cx + ux * mp.r * 0.4, mp.cy + uy * mp.r * 0.4, mp.cz + uz * mp.r * 0.4)
    local below = H.pocketShare(mp, mp.cx - ux * mp.r * 0.4, mp.cy - uy * mp.r * 0.4, mp.cz - uz * mp.r * 0.4)
    ok(above > below, "methane gathers at the roof")
    local g = H.airAtLocal(4242, "karst", mp.cx, mp.cy, mp.cz)
    ok((g.CH4 or 0) > 0.05, "firedamp's heart is rich in methane")
    local burnt = { [mp.key] = true }
    local g2 = H.airAtLocal(4242, "karst", mp.cx, mp.cy, mp.cz, burnt)
    ok((g2.CH4 or 0) == 0, "a burnt-out methane pocket holds none")
  end
  local vp = find_pocket("vent", "SO2")
  ok(vp ~= nil, "a vent world has fumarole gas")
  if vp then
    local g = H.airAtLocal(4242, "vent", vp.cx, vp.cy, vp.cz)
    ok(g.SO2 > H.LIMIT.SO2 and g.H2S > H.LIMIT.H2S, "a fumarole's heart: SO2 and H2S over their limits")
    local h, worst = H.gasHarm(g)
    ok(worst == "H2S" and h > 0.3, string.format("H2S hurts fastest (%.2f a minute, %s)", h, tostring(worst)))
  end
  ok(H.airScale(0) == 0 and H.airScale(0.01) == 0, "a vacuum holds no cave gas")
  ok(H.airScale(1) == 1 and H.airScale(5) == 1.5 and H.airScale(0.1) == 0.3, "the gas scales with the air, 0.3–1.5×")
  local g = H.airAtLocal(1, "lava_tube", 0, 0, 870)
  ok(g and g.CO2 and g.CO2 >= 0.004, "a lava tube's background CO2 everywhere")
end

-- ── readout, flammability, harm ────────────────────────────────────────────
do
  local r = H.readout({ CO2 = 0.032 }, 1.032, 0.2)
  ok(r.gas == "CO2" and r.level == 3 and r.text:find("32 mbar", 1, true), "CO2 at 32 mbar: over the limit, said in mbar (" .. tostring(r.text) .. ")")
  r = H.readout({ CO2 = 0.012 }, 1.012, 0.2)
  ok(r.level == 2, "CO2 at 12 mbar: caution")
  r = H.readout({ CO2 = 0.005 }, 1.005, 0.2)
  ok(r.level == 1, "CO2 at 5 mbar: shown")
  r = H.readout({ CO2 = 0.001 }, 1.001, 0.2)
  ok(r.level == 0, "1 mbar: nothing to say")
  r = H.readout({ SO2 = 4e-6 }, 1, 0.2)
  ok(r.level == 1 and r.text:find("ppm", 1, true), "a vent's trace SO2 in ppm (" .. tostring(r.text) .. ")")
  local x, fl = H.flammable({ CH4 = 0.08 }, 1.0, 0.19)
  ok(fl and math.abs(x - 0.08) < 1e-9, "8 % methane with oxygen: flammable")
  _, fl = H.flammable({ CH4 = 0.08 }, 1.0, 0.0)
  ok(not fl, "…with no oxygen it cannot burn")
  _, fl = H.flammable({ CH4 = 0.2 }, 1.0, 0.19)
  ok(not fl, "20 % methane: too rich to burn")
  _, fl = H.flammable({ CH4 = 0.03 }, 1.0, 0.19)
  ok(not fl, "3 %: too lean")
  r = H.readout({ CH4 = 0.035 }, 1.0, 0.2)
  ok(r.level == 3 and not r.flammable, "near the lower limit the chip warns before it can burn")
  r = H.readout({ CH4 = 0.08 }, 1.0, 0.2)
  ok(r.flammable and r.text:find("FLAMMABLE", 1, true), "flammable air is said so (" .. tostring(r.text) .. ")")
  local h = H.gasHarm({ CO2 = 0.05 })
  ok(math.abs(h - 0.02 * 2.5) < 1e-9, "CO2 at 2.5× its limit: 5 % a minute bare-headed")
  ok(H.gasHarm({ CO2 = 0.01 }) == 0, "under the limit: no harm")
  ok(H.gasHarm({ H2S = 1 }) == H.HARM.H2S * H.HARM_CAP, "harm is capped")
end

-- ── atmo: the cave's air mixed into the world's ────────────────────────────
do
  local earth = AT.roll({ type = "verdant", atmo = 0.75, tempK = 290 })
  local m = AT.mergeCave(earth, 1, { CO2 = 0.06 })
  local okb, why, info = AT.breathable(m, 1)
  ok(not okb and info.toxic == "CO2", "Earth air with a CO2 sump: toxic CO2 (" .. tostring(why) .. ")")
  ok(math.abs(m.p0 - (earth.p0 + 0.06)) < 1e-9, "the merged air's pressure is the world's plus the cave's")
  okb = AT.breathable(AT.mergeCave(earth, 1, { CO2 = 0.006 }), 1)
  ok(okb, "the background alone breathes")
  okb, _, info = AT.breathable(AT.mergeCave(earth, 1, { H2S = 5e-5 }), 1)
  ok(not okb and info.toxic == "H2S", "H2S over 10 µbar is toxic (atmo.H2S_MAX)")
  ok(AT.mergeCave(nil, 1, { CO2 = 0.1 }) == nil, "an airless world holds no cave air")
  ok(AT.GAS_LABEL.H2S == "H₂S", "H2S has its label")
end

-- ── the rest of the rules ──────────────────────────────────────────────────
do
  for _, id in ipairs({ "lava_tube", "karst", "collapse" }) do
    local u = CK.hazardsOf(id).unstable
    local n, hits = 4000, 0
    for i = 1, n do if H.unstableAt(9, u, i, -i, i * 3) then hits = hits + 1 end end
    ok(math.abs(hits / n - u * H.UNSTABLE_K) < 0.03, string.format("%s: unstable cells at its chance (%.3f vs %.3f)", id, hits / n, u * H.UNSTABLE_K))
  end
  ok(H.unstableAt(9, 0, 1, 1, 1, true), "a probe can force a cell unstable")
  for t = 1, 50 do
    local u = {}
    for i = 1, 11 do u[i] = ((t * 37 + i * 101) % 997) / 997 end
    local p = H.rockfallPlan(u)
    local good = #p >= 1 and #p <= 3
    for _, s in ipairs(p) do good = good and math.sqrt(s.dx ^ 2 + s.dz ^ 2) <= 1.21 and s.s >= 0.7 and s.s <= 1.4 end
    ok(good, "a fall is 1–3 slabs within 1.2 m of the roof point")
  end
  ok(#H.rockfallPlan({ 0 }) == 1 and #H.rockfallPlan({ 0.99 }) == 3, "one slab to three")
  ok(H.slabHurt(1.4, 1.0) == 0, "a slab barely moving does nothing")
  ok(H.slabHurt(1.0, 6) > 0.1 and H.slabHurt(1.4, 9) > 0.4 and H.slabHurt(1.4, 30) == 0.75, "a falling slab hurts, capped at 75 %")
  ok(H.slabHurt(0.7, 3) >= 0.06, "even a small one bruises")
  -- (2026-11-11) where a fall comes down, the slabs sized to the passage, the pile it leaves
  do
    local seen = {}
    for i = 0, 99 do
      local k, a = H.rockfallSpot("step", i / 100, 0.5)
      seen[k] = (seen[k] or 0) + 1
      if k == "ahead" then ok(a >= 3 and a <= 5, "a fall ahead lands 3–5 m along (" .. a .. ")") end
      if k == "behind" then ok(a <= -3 and a >= -5, "a fall behind lands 3–5 m back (" .. a .. ")") end
      if k == "on" then ok(a == 0, "a fall on the crew is at the crew") end
    end
    ok(seen.on == 40 and seen.ahead == 30 and seen.behind == 30, "walking: on the crew 40 %, ahead 30 %, behind 30 %")
    local dk = {}
    for i = 0, 99 do local k = H.rockfallSpot("dig", i / 100, 0.2); dk[k] = (dk[k] or 0) + 1 end
    ok(dk.face == 50 and dk.behind == 50, "digging: at the face or the way you came, half and half")
    ok(H.rockfallSpot("probe", 0.9, 0.9) == "on", "a probe's fall is on the point")
    ok(math.abs(H.slabScale(8, 8, 1) - 1.4) < 1e-9 and math.abs(H.slabScale(8, 8, 0) - 0.7) < 1e-9, "room to fall: slabs 0.7–1.4 as before")
    for _, hw in ipairs({ { 2.0, 2.4 }, { 3.0, 3.0 }, { 1.6, 4 } }) do
      local s = H.slabScale(hw[1], hw[2], 1)
      ok(2 * H.LB_HALF * s <= 0.6 * math.min(hw[1], hw[2]) + 1e-9, string.format("a %.1f × %.1f m tunnel: a slab is at most 60 %% of it across (%.2f m), it cannot wedge", hw[1], hw[2], 2 * H.LB_HALF * s))
    end
    local nb, nc = 0, 0
    for i = 0, 99 do
      local p = H.rubblePile(4.0, 4.0, i / 99)
      if p.blocks then nb = nb + 1 end
      ok(p.r >= H.RUBBLE_MIN and p.r <= H.RUBBLE_MAX, "a pile is between the smallest drawn and a heap")
      ok(p.r >= 0.6 * p.need - 1e-9, "…and at least chokes the passage (r ≥ 0.6 of what closes it)")
      ok(#p.balls == 3 and p.balls[1].a == 0 and p.balls[2].a > 0 and p.balls[3].a < 0, "…a heap with a talus each way along the passage")
      if p.r >= p.need * 0.98 then nc = nc + 1 end
    end
    ok(nb == nc and nb > 20 and nb < 60, "in a 4 m laser tunnel some falls close it, most choke it (" .. nb .. " of 100 close)")
    local big = H.rubblePile(20, 20, 1)
    ok(big.r == H.RUBBLE_MAX and not big.blocks, "a big gallery gets a heap, not a wall")
    local tiny = H.rubblePile(1.2, 1.2, 0)
    ok(tiny.r == H.RUBBLE_MIN and tiny.blocks, "a crawlway is closed by the smallest pile")
    ok(H.pileAlong(0, 2, -4) >= 0 and H.pileAlong(0, 2, -4) - 2 - H.PILE_CLEAR >= -4 + 0.39, "a heap ahead slides off the crew's boots, away from them")
    ok(H.pileAlong(0, 2, 4) <= 0 and 4 - (H.pileAlong(0, 2, 4) + 2) >= H.PILE_CLEAR + 0.39, "…and one behind, the other way")
    ok(H.pileAlong(5, 1.5, -4) == 5, "…a ball already clear stays put")
    local f, h = { 0, 0, 0 }, { 0, 1.8, 0 }
    ok(H.pileBuries({ 0, 0, 0 }, 1.5, f, h), "a pile on the crew's feet would bury them")
    ok(H.pileBuries({ 1.5, 1.0, 0 }, 1.5, f, h), "…beside them, within reach")
    ok(not H.pileBuries({ 3.0, 0, 0 }, 1.5, f, h), "…clear of them, it lands")
  end
  ok(H.caveTempK(280, "ice", CK.hazardsOf("ice")) == 248, "an ice cave on a mild world: −25 °C")
  ok(H.caveTempK(230, "ice", CK.hazardsOf("ice")) == 230, "…on a colder one, colder")
  ok(H.caveTempK(290, "vent", CK.hazardsOf("vent"), 1) == 325, "a deep vent runs 35 K over the world")
  ok(H.caveTempK(290, "karst", CK.hazardsOf("karst")) == 290, "a karst cave keeps its world's air")
  -- thermal
  local d, h, k = TH.suitThermal(248, true)
  ok(k == "cold" and h == 0 and math.abs(d - 6) < 1e-9, "−25 °C, helmet on: the heater draws 6 %/h, no harm")
  d, h, k = TH.suitThermal(248, false)
  ok(h > 0 and d > 0 and d < 6, "…bare-headed: harm, and most of the draw")
  d, h, k = TH.suitThermal(290, false)
  ok(d == 0 and h == 0 and k == nil, "in the comfort band: nothing")
  d, h, k = TH.suitThermal(330, true)
  ok(k == "hot" and d > 0, "a hot vent: the suit's cooling draws")
  -- dose
  local s6 = H.seamShare()
  ok(math.abs(s6 - 28 * math.exp(-6 / 4.5)) < 1e-6, "the share at 6 m of a 2 m seam (≈7.4 µSv/h)")
  ok(H.doseRate(s6 * 0.9, 1) == 0, "beyond 6 m: no dose")
  ok(math.abs(H.doseRate(28, 1) * 3600 - 0.02) < 1e-9, "at a rich face in a sealed cave: 2 % of a lethal dose an hour")
  ok(math.abs(H.doseRate(28, 0) * 3600 - 0.002) < 1e-9, "…in the open, a tenth")
  -- drops
  ok(H.dropHint(4, true) == nil, "a 4 m step: no hint")
  ok(H.dropHint(14, true):find("Rope Kit", 1, true) and H.dropHint(14, true):find("14 m", 1, true), "a 14 m drop with a rope: plant it")
  ok(H.dropHint(14, false):find("no rope", 1, true), "…without one: said")
  ok(H.dropHint(40, false):find("40 m or more", 1, true), "past the ray's reach: 40 m or more")
  -- rewards
  ok(H.firstEntry({ "karst" }, "ice") and not H.firstEntry({ "karst", "ice" }, "ice"), "first entry per kind, once")
  ok(math.abs(H.compGain(0.3) - 0.45) < 1e-9 and H.compGain(0.95) == 1, "composition +0.15, capped at 1")
  -- the codex
  local ids = { "co2", "so2", "h2s", "ch4", "rockfall", "cold", "heat", "dose", "drop", "flood" }
  for _, id in ipairs(ids) do
    local E = H.HAZARDS[id]
    ok(E and E.name and E.summary and #E.facts >= 2, id .. ": a codex entry with facts")
    ok(H.lineOf(id) ~= nil, id .. ": a line for its caption")
  end
  for g, id in pairs(H.HAZARD_OF_GAS) do ok(H.HAZARDS[id] ~= nil, g .. ": its gas has a codex entry") end
end

-- ── the recordings ─────────────────────────────────────────────────────────
do
  local f = io.open("solar/audio/SOURCES.md", "rb")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  for _, c in ipairs({ "cave_crack", "cave_tick_1", "cave_tick_2", "cave_tick_3", "cave_trickle", "cave_rockfall_1",
                       "cave_rockfall_2", "cave_slab_hit_1", "cave_slab_hit_2", "cave_gas_whump" }) do
    ok(exists("audio/ambience/" .. c .. ".ogg"), c .. ": on disk")
  end
  for _, id in ipairs({ "109360", "489905", "500638", "389303", "381645", "145400" }) do
    ok(src:find("/sounds/" .. id .. "/", 1, true) ~= nil, "freesound #" .. id .. " is logged in audio/SOURCES.md")
  end
  ok(src:find("cave_gas_whump", 1, true) and src:find("cave_crack", 1, true), "SOURCES.md names the hazard files")
end

-- ── the suit: closes itself in bad cave air, never locks ───────────────────
do
  local WORLDS = { Home = { atmo = 0.75, atmoHeight = 300, radius = 800, geo = { home = true, type = "verdant" }, bio = { tempK = 290 } } }
  WORLDS.Home.air = AT.roll({ type = "verdant", atmo = 0.75, tempK = 290 })
  local BODY = { name = "Home", x = 0, y = 0, z = 0, radius = 800 }
  local cave_gas = nil
  local saved = {}
  local walker = { onFoot = true, downed = false, headUnder = false, swimming = false, valid = true }
  local caps = {}
  local SCRIPTS = {}
  local api = {
    vec3 = vec3, findScript = function(k) return SCRIPTS[k] end,
    save = { get = function(k) return saved[k] end, set = function(k, v) saved[k] = v end },
    space = { dominant = function() return "Home" end, body = function() return BODY end },
    audio = { play = function() end },
  }
  local AT2 = load("solar/scripts/atmo.lua", api)
  SCRIPTS = { planet_walker = walker, climate = { valid = true, worldOf = function(n) return WORLDS[n] end },
              big_caption = { valid = true, show = function(t, s) caps[#caps + 1] = t .. ": " .. tostring(s) end },
              atmo = AT2, cave_field = { valid = true, airAt = function() return cave_gas end } }
  local SU = load("solar/scripts/suit.lua", api)
  local crew = { name = "Astronaut", valid = true, x = 0, y = 799, z = 0, children = function() return {} end }
  SU.start(crew)
  SU.update(crew, 1 / 60)
  local okh = SU.canRemoveHelmet()
  ok(okh == true, "the cave adds nothing: the helmet may come off")
  cave_gas = { CO2 = 0.06 }
  local a, why, tag = SU.canRemoveHelmet()
  ok(a == false and tag == "cave" and why:find("CO", 1, true), "in a CO2 sump: unsafe, said why (" .. tostring(why) .. ")")
  ok(SU.helmetRefusal(false) == nil, "…but never a lock: helmetRefusal lets it come off")
  cave_gas = nil
  SU.setHelmet(false, { instant = true, quiet = true })
  ok(SU.helmetOn() == false, "off in good air")
  cave_gas = { CO2 = 0.06 }
  SU.update(crew, 1 / 60)
  ok(SU.helmetOn() == true, "walk into the sump bare-headed: the helmet closes itself")
  ok(caps[#caps] and caps[#caps]:find("HELMET ON", 1, true), "…with a caption saying why")
  local s_ok = SU.setHelmet(false, { instant = true, quiet = true })
  ok(s_ok == true and SU.helmetOn() == false and SU.caveDare == true, "take it off again in the sump: allowed (the dare)")
  ok(caps[#caps]:find("HELMET OFF IN BAD AIR", 1, true), "…and warned")
  SU.update(crew, 1 / 60)
  ok(SU.helmetOn() == false, "…and the suit does not fight you")
  cave_gas = nil
  SU.update(crew, 1 / 60)
  ok(SU.caveDare == false, "the air clears: the dare is over")
  cave_gas = { CO2 = 0.06 }
  SU.update(crew, 1 / 60)
  ok(SU.helmetOn() == true, "…so the next sump closes the helmet again")
  -- a world's own refusal is still a refusal
  cave_gas = nil
  WORLDS.Home.bio.tempK = 200
  local b2 = SU.canRemoveHelmet()
  local s2 = SU.setHelmet(false, { instant = true })
  ok(b2 == false and s2 == false and SU.helmetOn() == true, "a world too cold to stand in still refuses")
  WORLDS.Home.bio.tempK = 290
  -- atmo.caveVerdict over an airless world: nothing
  WORLDS.Home.air = nil
  cave_gas = { CO2 = 0.06 }
  ok(AT2.caveVerdict(0, 799, 0) == nil, "no air: no cave verdict")
end

-- ── the scene half over stubs ──────────────────────────────────────────────
do
  local saved = {}
  local T = { t = 0, g = 0 }
  local BODY = { name = "Draethos", x = 1000, y = -500, z = 300, radius = R }
  local caps, hurts, doses, credits, rp, cells, spawned, adopted, plays = {}, {}, {}, {}, {}, {}, {}, {}, 0
  local sculpts, paints = {}, {}
  local surveyRec = { L = { comp = 0.3 } }
  local SCRIPTS = {}
  local worldK = 288
  local cf = { valid = true, probeN = 0, probeBody = "Draethos", caveKind = "karst", eyeLocal = { 0, 0, R - 40 },
               roofLocal = { 0, 0, R - 36 }, aheadLocal = nil, enclosure = 0.9, depth = 40, params = { forceKind = "" },
               hazard = { drop = 0 } }
  cf.worldInfo = function() return { seed = 4242, R = R, cdepth = 100, f = "limestone_nappe", ty = "alpine" } end
  local function probe(eye, kind)
    cf.probeN = cf.probeN + 1
    cf.caveKind = kind or cf.caveKind
    cf.params.forceKind = cf.caveKind   -- (the region's kind is the probe's here)
    if eye then cf.eyeLocal = eye; cf.roofLocal = { eye[1], eye[2], eye[3] + 4 } end
    cf.hazard = CK.hazardsOf(cf.caveKind)
    cf.hazard.drop = cf.dropNext or 0
  end
  local helmet = true
  local suit = { valid = true, helmetOn = function() return helmet end }
  local crew = { valid = true, activeId = function() return 7 end, packOf = function() return "astro" end,
                 hurt = function(id, a, cause, detail) hurts[#hurts + 1] = { a = a, cause = cause, detail = detail } return 1 end,
                 addDose = function(id, a, src, rate) doses[#doses + 1] = { a = a, rate = rate } end, CAUSE_TEXT = {} }
  local astro = { valid = true, x = 0, y = 0, z = 0 }
  local tb = { valid = true, inUse = false, charge = 0, toolId = function() return "laser" end, aimNow = function() return nil end }
  local mf = { valid = true, doseOre = 0, doseT = 0, doseFrom = function(d, w, k) return 28 * (k or 1) * math.min(1.5, (w or 2) / 2) * math.exp(-d / 4.5) end,
               adoptBody = function(n, pf, m, q, s) adopted[#adopted + 1] = { pf = pf, m = m, q = q } end,
               materialAt = function() return "limestone" end }
  local inv = { valid = true, itemCount = function(p, id) return (id == "rope") and 1 or 0 end }
  local fl = { valid = true, cellAdd = function(a) cells[#cells + 1] = a end }
  local function put_body(x, y, z) BODY.x, BODY.y, BODY.z = x, y, z end
  SCRIPTS = {
    cave_field = cf, cave_kinds = CK, suit = suit, crew = crew, tool_belt = tb, mineral_field = mf, inventory = inv,
    flashlight = fl, thermal = TH, planet_walker = { valid = true, onFoot = true, node = astro },
    survey = { valid = true, record = function() return surveyRec end,
               credit = function(n, src, vals) credits[#credits + 1] = { src = src, vals = vals }; surveyRec.L.comp = vals.comp end },
    research = { valid = true, addPoints = function(n, why) rp[#rp + 1] = { n = n, why = why } end },
    codex = { valid = true, CODEX = {} },
    big_caption = { valid = true, show = function(t, s) caps[#caps + 1] = t .. ": " .. tostring(s) end },
    climate = { valid = true, worldOf = function() return { air = { p0 = 1.0, gases = { N2 = 0.78, O2 = 0.21, Ar = 0.01 } }, bio = { tempK = worldK } } end,
                seaRadius = function() return 0 end },
  }
  local api = {
    vec3 = vec3, findScript = function(k) return SCRIPTS[k] end,
    save = { get = function(k) return saved[k] end, set = function(k, v) saved[k] = v end },
    space = { body = function() return BODY end, dominant = function() return "Draethos" end, time = function() return T.g end },
    terrain = { raycast = function(o, d, far)
      -- a roof 4 m over anything (and a floor and walls 4 m off)
      return { pos = vec3(o.x + d.x * 4, o.y + d.y * 4, o.z + d.z * 4), distance = 4 }
    end,
      sculpt = function(x, y, z, r, s, mode, o) sculpts[#sculpts + 1] = { x = x, y = y, z = z, r = r, mode = mode } return #sculpts end,
      paintTexture = function(x, y, z, r, slot) paints[#paints + 1] = { r = r, slot = slot } return #paints end,
      slotAt = function() return 6 end },
    audio = { play = function() plays = plays + 1; return { setPosition = function() end } end },
    spawn = function(pf, pos, cb)
      local n = { valid = true, name = pf, x = pos.x, y = pos.y, z = pos.z, vel = vec3(0, -8, 0) }
      n.setAngles = function() end
      n.destroy = function(self) self.valid = false end
      spawned[#spawned + 1] = n
      cb(n)
    end,
    find = function() return astro end,
    log = function() end,
  }
  setmetatable(api, { __index = function(_, k) if k == "time" then return T.t end end })
  local CH = load("solar/scripts/cave_hazards.lua", api)
  CH.start({})
  local function step(dt, n)
    for _ = 1, n or 1 do
      T.t = T.t + dt; T.g = T.g + dt
      CH.update({}, dt)
    end
  end
  -- 1. the first probe in a karst cave: composition +0.15, RP, once
  local pk = find_pocket("karst", "CO2")
  local eye = { pk.cx + 20, pk.cy, pk.cz }   -- (outside the sump, beside it)
  probe({ pk.cx + pk.r + 6, pk.cy, pk.cz })
  step(0.5)
  ok(#credits == 1 and credits[1].src == "cave" and math.abs(credits[1].vals.comp - 0.45) < 1e-9, "first karst cave: composition 0.3 → 0.45")
  ok(#rp == 1 and rp[1].n == CK.KINDS.karst.rewards.rp, "…and the kind's RP")
  ok(SCRIPTS.codex.CODEX.hazard_co2 ~= nil and SCRIPTS.codex.CODEX.hazard_rockfall ~= nil, "the hazards' codex entries are registered")
  local nupd = CH.stats.probes
  step(0.016, 10)
  ok(CH.stats.probes == nupd, "nothing runs between probes")
  probe()
  step(0.5)
  ok(#credits == 1 and #rp == 1, "…a second probe credits nothing more")
  -- 2. into the sump: the reading climbs, then warns
  probe({ pk.cx, pk.cy, pk.cz })
  step(0.5)
  ok(CH.state.gas and CH.state.gas.level == 3 and CH.state.gas.gas == "CO2", "at the sump's heart: CO2 over the limit")
  local chips = CH.chips()
  ok(chips[1] and chips[1].key == "gas" and chips[1].warn, "the suit's chip warns")
  local said = false
  for _, c in ipairs(caps) do if c:find("BAD AIR", 1, true) then said = true end end
  ok(said, "…and the caption says BAD AIR")
  local g = CH.airAtWorld(BODY.x + pk.cx, BODY.y + pk.cy, BODY.z + pk.cz)
  ok(g and g.CO2 > 0.02, "airAtWorld (atmo's hook through cave_field) gives the sump's gas")
  ok(CH.airAtWorld(BODY.x + pk.cx + 200, BODY.y + pk.cy, BODY.z + pk.cz) == nil, "…nothing far from the crew")
  ok(#hurts == 0, "helmet on: no harm")
  helmet = false
  probe()
  step(0.5)
  ok(#hurts == 1 and hurts[1].cause == "gas" and hurts[1].a > 0, "bare-headed in the sump: hurt by the gas")
  helmet = true
  -- 3. firedamp and the laser
  local mp = find_pocket("karst", "CH4")
  hurts = {}
  probe({ mp.cx, mp.cy, mp.cz })
  step(0.5)
  ok(CH.state.gas.flammable, "in firedamp: flammable")
  tb.inUse, tb.charge = true, 0.6
  probe()
  step(0.5)
  ok(CH.stats.ignitions == 1 and #hurts >= 1 and hurts[1].cause == "explosion", "the laser lights it: an explosion that hurts")
  ok(hurts[1] and hurts[1].a < 0.5, "…less with the helmet on")
  local bl = saved["cave.burnt.Draethos"]
  ok(type(bl) == "table" and bl[1] == mp.key, "…the pocket is burnt out, saved")
  probe()
  step(0.5)
  ok(CH.stats.ignitions == 1 and not CH.state.gas.flammable, "…and does not burn twice")
  tb.inUse, tb.charge = false, 0
  step(7, 1)   -- (the ignition's own rockfall, if the cell was unstable, runs out)
  -- 4. a rockfall: crack, dust, slabs, a hit
  hurts, spawned, adopted, sculpts, paints = {}, {}, {}, {}, {}
  probe(eye)
  step(0.5)
  local n0 = CH.stats.rockfalls
  sculpts, paints = {}, {}   -- (the firedamp's own fall may have just landed its heap)
  ok(CH.forceRockfall(), "a rockfall starts")
  ok(CH.stats.rockfalls == n0 + 1 and CH.last.rockfall and CH.last.rockfall.mat == "limestone", "…cracking a limestone roof")
  local cracked = false
  for _, c in ipairs(caps) do if c:find("ROOF", 1, true) or c:find("ROCK", 1, true) then cracked = true end end
  ok(not cracked, "…telegraphed by its sounds and dust only: no caption")
  ok(plays >= 2, "…the crack and the grit are heard")
  ok(CH.last.rockfall.kind == "on" and CH.last.rockfall.H > 8 and CH.last.rockfall.W > 7, "…over the crew, the passage measured (" .. string.format("%.1f × %.1f m", CH.last.rockfall.H, CH.last.rockfall.W) .. ")")
  step(0.5, 2)
  ok(#spawned == 0, "…nothing falls during the dust")
  step(0.6)
  ok(#spawned >= 1 and #spawned <= 3, "after 1.5 s: 1–3 slabs (" .. #spawned .. ")")
  ok(#adopted == #spawned and adopted[1].pf == "LooseBoulder" and adopted[1].m == "limestone", "…adopted as loose limestone you can haul")
  -- a slab on the crew (its speed from where it was a frame before)
  step(0.016)
  local b = BODY
  local l = math.sqrt(eye[1] ^ 2 + eye[2] ^ 2 + eye[3] ^ 2)
  astro.x, astro.y, astro.z = b.x + eye[1] - eye[1] / l * 1.6, b.y + eye[2] - eye[2] / l * 1.6, b.z + eye[3] - eye[3] / l * 1.6
  local s1 = spawned[1]
  s1.x, s1.y, s1.z = astro.x + eye[1] / l * 1.0, astro.y + eye[2] / l * 1.0, astro.z + eye[3] / l * 1.0
  step(0.016)
  ok(#hurts == 1 and hurts[1].cause == "crushed" and hurts[1].a > 0, "a slab on the crew: hurt")
  step(0.016)
  ok(#hurts == 1, "…once per slab")
  for _, c in ipairs(caps) do ok(not c:find("SLAB", 1, true), "…and no caption for the hit either") end
  step(6)
  ok(CH.stats.rockfalls == n0 + 1, "one fall at a time")
  -- the pile: it waits while the crew stands in it, then lands as painted rock
  local fs = CH.fallState()
  ok(fs and fs.stage == 2 and fs.waiting == 3 and #sculpts == 0, "the crew stands where the heap goes: it waits (never buried alive)")
  astro.x, astro.y, astro.z = astro.x + 12, astro.y, astro.z
  step(0.016)
  ok(#sculpts == 3 and sculpts[1].mode == "raise" and math.abs(sculpts[1].r - CH.last.rockfall.pile.r) < 1e-9, "…stepped clear: the heap is raised, three balls")
  ok(#paints == 3 and paints[1].slot == 6, "…painted the roof's rock (its slot), so the laser cuts it as that rock")
  local fl = CH.last.rockfall.floor
  local s1l = math.sqrt((sculpts[1].x - BODY.x - fl[1]) ^ 2 + (sculpts[1].y - BODY.y - fl[2]) ^ 2 + (sculpts[1].z - BODY.z - fl[3]) ^ 2)
  ok(s1l < 1e-6, "…on the floor under the fall")
  local buried = 0
  for _, n in ipairs(spawned) do if n.valid == false then buried = buried + 1 end end
  ok(buried >= 1, "…the slabs in it are buried in it (" .. buried .. ")")
  ok(CH.fallState() == nil and (CH.stats.piles or 0) >= 1, "…and the fall is over")
  -- a fall behind the crew: along the passage, 3–5 m back
  T.t = T.t + 40
  sculpts = {}
  ok(CH.forceRockfall("behind", { 1, 0, 0 }), "a fall behind the crew starts")
  local lr = CH.last.rockfall
  ok(lr.kind == "behind" and lr.along < -2.5 and lr.along > -5.01, "…along the passage, back the way they came (" .. lr.along .. " m)")
  step(0.5, 4)
  step(0.5, 8)
  ok(#sculpts == 3, "…the heap lands at once: the crew is not under it")
  -- the roof ticks in an unstable cell; walking through one can set it off
  CH.params.forceUnstable = true
  local plays0 = plays
  probe(eye)
  step(0.5)
  ok(CH.state.unstable and plays > plays0, "an unstable cell: the roof ticks (a recording at the roof)")
  -- 5. an ice cave: the heater on the lamp cell
  CH.params.forceUnstable = false
  cells = {}
  probe(nil, "ice")
  step(0.5)
  probe(nil, "ice")
  step(0.5)
  ok(CH.state.tempK == 248 and CH.state.therm == "cold", "an ice cave: −25 °C")
  ok(#cells >= 1 and cells[#cells] < 0, "…the suit's heater draws on the lamp cell")
  local cc = CH.chips()
  local has = false
  for _, c in ipairs(cc) do if c.key == "therm" then has = true end end
  ok(has, "…the Cold chip")
  hurts = {}
  helmet = false
  probe(nil, "ice")
  step(0.5)
  local cold = false
  for _, hh in ipairs(hurts) do if hh.cause == "cold" then cold = true end end
  ok(cold, "…bare-headed: frostbite")
  helmet = true
  -- 6. the seam
  probe(nil, "karst")
  mf.doseOre, mf.doseT = 20, T.t
  doses = {}
  step(0.5)
  probe()
  mf.doseT = T.t
  step(0.5)
  ok(#doses >= 1 and doses[1].a > 0, "within 6 m of a pitchblende seam: dosed (the reactor's dose step)")
  mf.doseOre, mf.doseT = 3, T.t
  doses = {}
  probe()
  step(0.5)
  ok(#doses == 0, "further off: not")
  -- 7. a drop
  caps = {}
  cf.dropNext = 14
  probe()
  step(0.5)
  probe()
  step(0.5)
  local drop = false
  for _, c in ipairs(caps) do if c:find("Rope Kit", 1, true) then drop = true end end
  ok(drop, "a 14 m drop ahead: the rope hint")
  cf.dropNext = 0
  -- 8. out of the cave: quiet
  cf.caveKind = nil
  cf.probeN = cf.probeN + 1
  step(0.5)
  ok(CH.state.kind == nil and #CH.chips() == 0, "out of the cave: no chips")
end

if #failures == 0 then
  print(string.format("CAVE HAZARDS SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
for _, f in ipairs(failures) do print("FAIL: " .. f) end
print(string.format("CAVE HAZARDS SMOKE: %d of %d checks failed", #failures, checks))
os.exit(1)
