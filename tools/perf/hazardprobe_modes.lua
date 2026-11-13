-- ── hazard probe (tools/perf/hazardprobe.sh): cave hazards and rewards (worlds W5) ─
-- Spliced into a copy of perfbench.lua AFTER caveprobe_modes.lua (it uses CV's
-- cave finder, stand and shots). One table, HZ.
--   hazard  on the save's home world: find a natural cave (CV.find), stand in
--           it and walk it; then
--     AIR      every pocket made CO2 (cave_hazards.forceAir): stand at points
--              closing on a pocket's heart and log the suit's reading, the
--              chip, the helmet (bare-headed at the start: it closes itself),
--              then take it off in the sump (the dare) and log the harm
--     METHANE  pockets made CH4: stand in one, fire the Terrain Laser at the
--              rock (tool_belt.sim): the ignition, its harm, burnt out
--     ROCKFALL a fall 5 m ahead, photographed through the crack, the dust and
--              the slabs; then one over the crew: the hit
--     RUBBLE   a laser-sized tunnel cut from the cave wall; a fall ahead in it
--              leaves a heap that blocks it (a ray at chest height), no slab
--              hangs in the roof, the laser digs through it; a fall on the
--              crew waits while they stand in it and lands once they back off
--     DOSE     a real uranite seam (mineral_field.veinsNear) dug to and stood
--              beside if one is near, else forceDoseOre: the crew's dose
--     VENT     the cave dressed as a sulfur vent, its gas on the chip
--     RUINS    a home site made a mine head and another a sink camp
--              (ruins.forceCaveKind), the crew sent there: the cave found,
--              dug, stamped; its cache's containers rolled (loot.fillSite)
--              and listed; pictures at the foot
--     COST     cave_hazards' ms a frame walking, against cave_field's
-- `HZ` lines; pictures in save/user/caveshots/ (CV's folder).
local HZ = { fails = 0, checks = 0 }

function HZ.check(what, cond, fmt, ...)
  HZ.checks = HZ.checks + 1
  if not cond then HZ.fails = HZ.fails + 1 end
  P("HZ CHECK %s %s%s", cond and "PASS" or "FAIL", what, fmt and (" — " .. string.format(fmt, ...)) or "")
end

function HZ.hp()
  local C = findScript("crew")
  local id = C and C.activeId and C.activeId()
  local r = id and C.get and C.get(id)
  return r and (r.hp or 1) or -1, r and (tonumber(r.dose) or 0) or -1
end

function HZ.heal()
  local C = findScript("crew")
  local id = C and C.activeId and C.activeId()
  if id and C.patch then pcall(C.patch, id, { hp = 1, dose = 0 }) end
end

-- the chips' line (status_hud) and the cave_hazards state, in one line
function HZ.read(tag)
  local ch = findScript("cave_hazards")
  local su = findScript("suit")
  local hud = findScript("status_hud")
  local g = ch.state.gas
  local hp, dose = HZ.hp()
  P("HZ READ %s: kind %s gas %s lvl %s flam %s | T %s heater %.1f | dose %.4f/h | unstable %s drop %.1f flood %s | helmet %s dare %s | hp %.3f dose %.4f | HUD %s",
    tag, tostring(ch.state.kind), g and tostring(g.text) or "-", g and tostring(g.level) or "-", tostring(g and g.flammable),
    tostring(ch.state.tempK), ch.state.heater or 0, ch.state.dose or 0, tostring(ch.state.unstable), ch.state.drop or 0,
    tostring(ch.state.flood), tostring(su.helmetOn()), tostring(su.caveDare), hp, dose, tostring(hud and hud.line or "-"))
  return g
end

-- A pocket of the forced gas whose heart is in the cave's open air within
-- `reach` m of the crew, with a floor under it: → heart (body-local), floor
-- (body-local), r, or nil.
function HZ.pocket(gas, reach)
  local ch = findScript("cave_hazards")
  local cf = findScript("cave_field")
  local b = home()
  local wi = cf.worldInfo(b.name)
  local a = astro()
  local lx, ly, lz = a.x - b.x, a.y - b.y, a.z - b.z
  local C = ch.AIR_CELL
  ch.probePocket = nil
  local ci, cj, ck = math.floor(lx / C), math.floor(ly / C), math.floor(lz / C)
  local best
  for di = -2, 2 do for dj = -2, 2 do for dk = -2, 2 do
    local pk = ch.airCellOf(wi.seed, cf.params.forceKind ~= "" and cf.params.forceKind or "karst", ci + di, cj + dj, ck + dk, gas)
    if pk then
      local d = len(pk.cx - lx, pk.cy - ly, pk.cz - lz)
      local q = terrain.query(b.x + pk.cx, b.y + pk.cy, b.z + pk.cz)
      if d < (reach or 40) and q and q > 1.2 then
        local u = unit({ x = pk.cx, y = pk.cy, z = pk.cz })
        local hd = terrain.raycast(vec3(b.x + pk.cx, b.y + pk.cy, b.z + pk.cz), vec3(-u.x, -u.y, -u.z), 8)
        if hd and hd.pos and (not best or d < best.d) then
          best = { d = d, heart = { x = pk.cx, y = pk.cy, z = pk.cz }, floor = { x = hd.pos.x - b.x, y = hd.pos.y - b.y, z = hd.pos.z - b.z },
                   r = pk.r, u = u, key = pk.key }
        end
      end
    end
  end end end
  if best then return best end
  -- the cave here is smaller than the cells' hearts land in: a pocket put in
  -- the cave's air 5 m ahead (cave_hazards.probePocket), the same rules
  local up = unit({ x = lx, y = ly, z = lz })
  local fwd = HZ.t or { x = 1, y = 0, z = 0 }
  for _, d in ipairs({ 5, 3, 1 }) do
    local hp = { x = lx + fwd.x * d + up.x * 0.6, y = ly + fwd.y * d + up.y * 0.6, z = lz + fwd.z * d + up.z * 0.6 }
    local q = terrain.query(b.x + hp.x, b.y + hp.y, b.z + hp.z)
    if q and q > 0.8 then
      local hd = terrain.raycast(vec3(b.x + hp.x, b.y + hp.y, b.z + hp.z), vec3(-up.x, -up.y, -up.z), 8)
      if hd and hd.pos then
        local g = {}
        g[gas] = (gas == "CH4" and 0.09) or (gas == "CO2" and 0.07) or 1.5e-4
        if gas == "SO2" then g.H2S = 1.6e-4 end
        ch.probePocket = { x = hp.x, y = hp.y, z = hp.z, r = 9, gas = g, key = "probe:" .. gas }
        return { d = d, heart = hp, floor = { x = hd.pos.x - b.x, y = hd.pos.y - b.y, z = hd.pos.z - b.z }, r = 9, u = up, key = "probe:" .. gas, probe = true }
      end
    end
  end
  return nil
end

function HZ.put(p, up)
  local b = home()
  local a = astro()
  a.x, a.y, a.z = b.x + p.x + up.x * 1.1, b.y + p.y + up.y * 1.1, b.z + p.z + up.z * 1.1
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.5) end
end

-- the floor `d` m from body-local point p along t (a ray down from p's height)
function HZ.floor_at(p, t, d, up)
  local b = home()
  local q = { x = b.x + p.x + t.x * d + up.x * 1.4, y = b.y + p.y + t.y * d + up.y * 1.4, z = b.z + p.z + t.z * d + up.z * 1.4 }
  local qq = terrain.query(q.x, q.y, q.z)
  if not qq or qq < 0.6 then return nil end
  local h = terrain.raycast(vec3(q.x, q.y, q.z), vec3(-up.x, -up.y, -up.z), 6)
  return h and h.pos and { x = h.pos.x - b.x, y = h.pos.y - b.y, z = h.pos.z - b.z } or nil
end

function HZ.air(cv)
  local ch, su, cf = findScript("cave_hazards"), findScript("suit"), findScript("cave_field")
  cf.params.forceKind = "karst"
  ch.params.forceAir = "CO2"
  wait(1.2)
  local pk = HZ.pocket("CO2", 45)
  if not pk then P("HZ AIR no CO2 pocket heart in open air near"); HZ.check("a CO2 pocket to walk into", false); return end
  P("HZ AIR pocket %s heart %.1f m away, r %.1f", pk.key, pk.d, pk.r)
  -- approach: points along a level line into the heart
  local t = unit(sub(cv.t, scl(pk.u, dot(cv.t, pk.u))))
  local lv, prev_lv = {}, -1
  -- bare-headed at the start (if the world's air allows it)
  local okh, why = su.setHelmet(false, { instant = true, quiet = true })
  P("HZ AIR helmet off at the start: %s %s", tostring(okh), tostring(why))
  local heal0 = HZ.hp()
  local closed_at = nil
  for _, d in ipairs({ 16, 12, 9, 6, 4, 2, 0 }) do
    local f = d == 0 and pk.floor or HZ.floor_at(pk.floor, t, d, pk.u)
    if f then
      HZ.put(f, pk.u)
      wait(1.3)
      local g = HZ.read(string.format("air_%02dm", d))
      lv[#lv + 1] = { d = d, lvl = g and g.level or 0 }
      if not closed_at and okh and su.helmetOn() then closed_at = d end
    end
  end
  local saw, toxic = nil, nil
  for _, e in ipairs(lv) do
    if e.lvl >= 1 and not saw then saw = e.d end
    if e.lvl >= 3 and not toxic then toxic = e.d end
  end
  HZ.check("bad air: the reading shows before it is over the limit", saw and toxic and saw > toxic, "shown at %s m, over at %s m", tostring(saw), tostring(toxic))
  if okh then HZ.check("…bare-headed, the helmet closes itself in it", closed_at ~= nil, "closed %s m from the heart", tostring(closed_at)) end
  CV.look(t, pk.u, -0.1, "air_hud", true)
  -- the dare: off again in the sump
  local hp0 = HZ.hp()
  local okd, whyd = su.setHelmet(false, { instant = true, quiet = true })
  wait(4)
  local hp1 = HZ.hp()
  HZ.read("air_dare")
  HZ.check("…taken off again in the sump (allowed), it hurts", okd and su.caveDare and hp1 < hp0, "allowed %s (%s), hp %.3f → %.3f",
    tostring(okd), tostring(whyd), hp0, hp1)
  su.setHelmet(true, { instant = true, quiet = true })
  HZ.heal()
  ch.params.forceAir = ""
  ch.probePocket = nil
end

function HZ.methane(cv)
  local ch, cf = findScript("cave_hazards"), findScript("cave_field")
  cf.params.forceKind = "karst"
  ch.params.forceAir = "CH4"
  wait(1.2)
  local pk = HZ.pocket("CH4", 45)
  if not pk then P("HZ CH4 no methane heart in open air"); HZ.check("a methane pocket", false); ch.params.forceAir = ""; return end
  HZ.put(pk.floor, pk.u)
  wait(1.5)
  local g = HZ.read("ch4_heart")
  local wair = findScript("climate").worldOf(home().name).air
  P("HZ CH4 world O2 %.3f p0 %.3f", wair and wair.o2 or -1, wair and wair.p0 or -1)
  local inv = findScript("inventory")
  local tb = findScript("tool_belt")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  pcall(tb.hold, "laser")
  wait(0.8)
  local n0 = ch.stats.ignitions
  local hp0 = HZ.hp()
  local t = unit(sub(cv.t, scl(pk.u, dot(cv.t, pk.u))))
  local pc = findScript("planet_camera")
  pc.face(t.x, t.y, t.z, -0.4)
  local t0 = time
  local shot = false
  while time - t0 < 6 do
    local a, bb = astro(), home()
    local up = unit(sub(a, bb))
    tb.sim = { btn = { [0] = true }, aim = function()
      local aa, b2 = astro(), home()
      local u2 = unit(sub(aa, b2))
      local e = { x = aa.x + u2.x * 1.5, y = aa.y + u2.y * 1.5, z = aa.z + u2.z * 1.5 }
      return e.x, e.y, e.z, t.x - u2.x * 0.6, t.y - u2.y * 0.6, t.z - u2.z * 0.6
    end }
    yield()
    if ch.stats.ignitions > n0 and not shot then
      shot = true
      wait(0.12)
      CV.shot("ch4_ignite", true)
      break
    end
  end
  tb.sim = { btn = { [0] = false } }
  wait(0.5)
  local hp1 = HZ.hp()
  HZ.read("ch4_after")
  HZ.check("methane: flammable, and the laser lights it", g and g.flammable and ch.stats.ignitions > n0,
    "flammable %s, ignitions %d → %d", tostring(g and g.flammable), n0, ch.stats.ignitions)
  HZ.check("…it hurts", hp1 < hp0, "hp %.3f → %.3f", hp0, hp1)
  local g2 = HZ.read("ch4_burnt")
  HZ.check("…the pocket is burnt out", not (g2 and g2.flammable))
  pcall(tb.hold, "gravgun")
  HZ.heal()
  ch.params.forceAir = ""
  ch.probePocket = nil
end

function HZ.rockfall(cv)
  local ch, cf = findScript("cave_hazards"), findScript("cave_field")
  CV.stand(cv)
  wait(7)   -- (a fall the firedamp set off runs out first: one fall at a time)
  local b = home()
  local a = astro()
  local up = unit(sub(a, b))
  local t = cv.t
  -- a point 5 m ahead at eye height (in the cave's air, else 3 m)
  local tgt
  for _, d in ipairs({ 5, 4, 3, 2 }) do
    local p = { x = a.x - b.x + t.x * d + up.x * 1.4, y = a.y - b.y + t.y * d + up.y * 1.4, z = a.z - b.z + t.z * d + up.z * 1.4 }
    local q = terrain.query(b.x + p.x, b.y + p.y, b.z + p.z)
    if q and q > 0.8 then tgt = p; break end
  end
  tgt = tgt or { x = a.x - b.x + up.x * 1.4, y = a.y - b.y + up.y * 1.4, z = a.z - b.z + up.z * 1.4 }
  local pc = findScript("planet_camera")
  pc.face(t.x, t.y, t.z, 0.25)
  wait(1.0)
  local n0 = ch.stats.slabs
  ch.startRockfall(b.name, tgt.x, tgt.y, tgt.z, "probe")
  P("HZ FALL started: roof %.1f m over the point, rock %s", ch.last.rockfall and ch.last.rockfall.roof or -1, ch.last.rockfall and ch.last.rockfall.mat or "?")
  wait(0.5); CV.shot("rockfall_crack", true)
  wait(1.2); CV.shot("rockfall_falling", false)
  wait(0.5); CV.shot("rockfall_falling2", false)
  wait(2.0); CV.shot("rockfall_down", false)
  pc.face(t.x, t.y, t.z, -0.15)
  wait(0.8); CV.shot("rockfall_down_low", false)
  local slabs = ch.stats.slabs - n0
  HZ.check("a rockfall drops 1–3 slabs after its dust", slabs >= 1 and slabs <= 3, "%d slabs", slabs)
  -- where did they land?
  local mf = findScript("mineral_field")
  local lb = mf and mf.looseBodies and mf.looseBodies() or {}
  local seen = 0
  for _, e in ipairs(lb) do
    if e.pf == "LooseBoulder" and e.n and e.n.valid then
      local bb = home()
      local d = len(e.n.x - bb.x - tgt.x, e.n.y - bb.y - tgt.y, e.n.z - bb.z - tgt.z)
      if d < 12 then seen = seen + 1; P("HZ FALL slab %s: %.1f m from the point, adopted as %s ×%s", e.name, d, tostring(e.mat), tostring(e.qty)) end
    end
  end
  local pl = ch.last.pile
  HZ.check("…the slabs are loose rock on the floor, or buried in the heap they leave", seen >= 1 or pl ~= nil, "%d loose near, heap %s", seen,
    pl and string.format("r %.1f m (%s)", pl.r or 0, pl.blocks and "closes the passage" or "chokes it") or "none")
  -- one over the crew
  wait(4)
  HZ.heal()
  local hp0 = HZ.hp()
  local h0 = ch.stats.hits
  ch.forceRockfall()
  wait(5.5)
  local hp1 = HZ.hp()
  P("HZ FALL over the crew: hits %d, hp %.3f → %.3f, last hit %s", ch.stats.hits - h0, hp0, hp1,
    ch.last.hit and string.format("%.2f at %.1f m/s", ch.last.hit.amount, ch.last.hit.speed) or "none")
  HZ.check("…one over the crew: a slab that hits hurts", (ch.stats.hits > h0 and hp1 < hp0) or ch.stats.hits == h0,
    "hits %d, hp %.3f → %.3f", ch.stats.hits - h0, hp0, hp1)
  HZ.heal()
end

-- RUBBLE (2026-11-11): a fall in a laser-sized tunnel blocks it, and the
-- laser digs through what came down. A tunnel is cut from the cave's wall
-- along cv.t (balls of the laser's own size), the crew stands 5 m in, a fall
-- AHEAD is forced; the passage ahead is measured by one ray at chest height
-- before, after the heap lands and after the laser has cut at it for 10 s.
-- Then a fall ON the crew: the heap waits while they stand in it and lands
-- once they back off. Everything kept body-local (rule 1).
function HZ.rubble(cv)
  local ch = findScript("cave_hazards")
  local tb = findScript("tool_belt")
  local pc = findScript("planet_camera")
  CV.stand(cv)
  wait(1)
  local b = home()
  local a = astro()
  local up = unit(sub(a, b))
  local t = cv.t
  local fl = cv.floor
  -- a tunnel the laser's size in solid rock 7 m under the cave floor (one
  -- ball of the laser's own bite, 2.4 x 0.85, every metre for 18 m), so the
  -- passage is a dug one, not the gallery around it
  local o = { x = fl.x - up.x * 7, y = fl.y - up.y * 7, z = fl.z - up.z * 7 }
  P("HZ RUBBLE cutting a tunnel 7 m under the cave floor")
  for i = 0, 18 do
    local c = { x = o.x + t.x * i, y = o.y + t.y * i, z = o.z + t.z * i }
    b = home()
    terrain.dig(b.x + c.x, b.y + c.y, b.z + c.z, 2.4, 0.85)
  end
  wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 30, "the tunnel")
  wait(1.0)
  -- the tunnel's floor at `d` m along it (body-local)
  local function floor_at(d)
    local s0 = { x = o.x + t.x * d, y = o.y + t.y * d, z = o.z + t.z * d }
    local bb = home()
    local hd = terrain.raycast(vec3(bb.x + s0.x, bb.y + s0.y, bb.z + s0.z), vec3(-up.x, -up.y, -up.z), 10)
    local hu = terrain.raycast(vec3(bb.x + s0.x, bb.y + s0.y, bb.z + s0.z), vec3(up.x, up.y, up.z), 10)
    local f = hd and { x = hd.pos.x - bb.x, y = hd.pos.y - bb.y, z = hd.pos.z - bb.z } or s0
    return f, (hd and hd.distance or 0) + (hu and hu.distance or 0)
  end
  local function stand_at(p)
    local bb, aa = home(), astro()
    aa.x, aa.y, aa.z = bb.x + p.x + up.x * 1.1, bb.y + p.y + up.y * 1.1, bb.z + p.z + up.z * 1.1
    aa.vx, aa.vy, aa.vz = 0, 0, 0
  end
  -- the passage along `s` (+1 ahead, -1 back), from 1.4 m over the floor at p
  local function clear(p, s)
    local bb = home()
    local q = { x = p.x + up.x * 1.4, y = p.y + up.y * 1.4, z = p.z + up.z * 1.4 }
    local h = terrain.raycast(vec3(bb.x + q.x, bb.y + q.y, bb.z + q.z), vec3(t.x * s, t.y * s, t.z * s), 30)
    return h and h.distance or 30
  end
  local mf = findScript("mineral_field")
  local function hanging(p)
    local bb, n = home(), 0
    for _, e in ipairs(mf and mf.looseBodies and mf.looseBodies() or {}) do
      if e.n and e.n.valid and tostring(e.name):find("CaveSlab", 1, true) then
        local q = sub({ x = e.n.x - bb.x, y = e.n.y - bb.y, z = e.n.z - bb.z }, p)
        local hgt = dot(q, up)
        if len(q.x, q.y, q.z) < 12 and hgt > 1.6 then n = n + 1; P("HZ RUBBLE slab %s %.1f m up", e.name, hgt) end
      end
    end
    return n
  end
  CV.torch(true)
  -- 1. a fall ON the crew 4 m in: the heap waits while they stand in it,
  -- and lands behind them once they walk on
  local f4, h4 = floor_at(4)
  P("HZ RUBBLE tunnel cut: %.1f m floor to roof 4 m in", h4)
  stand_at(f4)
  pc.face(t.x, t.y, t.z, 0.1)
  wait(2.0)
  CV.shot("rubble_0_tunnel", false)
  HZ.heal()
  local hp0 = HZ.hp()
  local p1 = ch.stats.piles or 0
  local h0 = ch.stats.hits
  ch.forceRockfall("on")
  local lr = ch.last.rockfall or {}
  P("HZ RUBBLE fall on the crew: roof %.1f, passage %.1f m high %.1f m across, rock %s slot %s",
    lr.roof or 0, lr.H or 0, lr.W or 0, tostring(lr.mat), tostring(lr.slot))
  pc.face(t.x, t.y, t.z, 0.45)
  wait(0.9); CV.shot("rubble_1_dust", false)
  wait(0.9); CV.shot("rubble_2_falling", false)
  wait(2.9)
  local fs = ch.fallState()
  local hp1 = HZ.hp()
  P("HZ RUBBLE on the crew: hits %d hp %.3f → %.3f, fall %s waiting %s", ch.stats.hits - h0, hp0, hp1, fs and tostring(fs.stage) or "over", fs and tostring(fs.waiting) or "-")
  pc.face(t.x, t.y, t.z, -0.35)
  wait(0.3); CV.shot("rubble_3_slabs_down", false)
  HZ.check("a fall on the crew: the heap waits while they stand in it", fs ~= nil and fs.stage == 2 and fs.waiting > 0, "stage %s waiting %s", fs and tostring(fs.stage) or "-", fs and tostring(fs.waiting) or "-")
  local f11 = floor_at(11)
  local back0 = clear(f11, -1)
  stand_at(f11)
  wait_for(function() return (ch.stats.piles or 0) > p1 end, 5, "the waiting heap")
  wait(1.5)
  wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 10, "the heap's edits")
  local back1 = clear(f11, -1)
  local pl = ch.last.pile or {}
  -- look back at it
  pc.face(-t.x, -t.y, -t.z, -0.05)
  wait(0.6); CV.shot("rubble_4_heap_behind", false)
  pc.face(-t.x, -t.y, -t.z, -0.35)
  wait(0.4); CV.shot("rubble_4_heap_behind_low", false)
  -- (once the heap is down: a slab may rest on the crew while they stand under it)
  HZ.check("…no slab left hanging in the roof", hanging(f4) == 0)
  P("HZ RUBBLE heap r %.1f m (%s); the way back from 11 m: %.1f m → %.1f m", pl.r or 0, pl.blocks and "closes it" or "chokes it", back0, back1)
  HZ.check("…walked on, it lands: the way back is blocked at chest height", (ch.stats.piles or 0) > p1 and back1 < back0 - 1.0 and back1 < 8.5,
    "piles %d → %d, %.1f → %.1f m", p1, ch.stats.piles or 0, back0, back1)
  -- 2. a fall AHEAD of them in the tunnel: it blocks it, and the laser digs through
  wait(2)
  local d0 = clear(f11, 1)
  local p2 = ch.stats.piles or 0
  ch.forceRockfall("ahead", { t.x, t.y, t.z })
  pc.face(t.x, t.y, t.z, 0.1)
  lr = ch.last.rockfall or {}
  P("HZ RUBBLE fall ahead %.1f m along: roof %.1f, passage %.1f m high %.1f m across", lr.along or 0, lr.roof or 0, lr.H or 0, lr.W or 0)
  wait(2.0); CV.shot("rubble_5_ahead_falling", false)
  wait_for(function() return (ch.stats.piles or 0) > p2 end, 8, "the heap ahead")
  wait(1.5)
  wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 10, "the heap's edits")
  local d1 = clear(f11, 1)
  pl = ch.last.pile or {}
  pc.face(t.x, t.y, t.z, -0.1)
  wait(0.4); CV.shot("rubble_6_heap_ahead", false)
  P("HZ RUBBLE heap r %.1f m (%s); the way ahead: %.1f m → %.1f m", pl.r or 0, pl.blocks and "closes it" or "chokes it", d0, d1)
  HZ.check("a fall ahead: a heap that blocks the tunnel ahead (the crew not under it)", (ch.stats.piles or 0) > p2 and d1 < d0 - 1.0,
    "piles %d → %d, %.1f → %.1f m", p2, ch.stats.piles or 0, d0, d1)
  HZ.check("…no slab left hanging in the roof", hanging(f11) == 0)
  -- the slabs fell by themselves: the heap lands once they are all down
  -- (not at the 3 s fallback that waits on slabs that never land)
  local downs = (pl.t or 0) - (lr.t or 0) - (ch.DUST_S or 1.5)
  HZ.check("…its slabs came down by themselves (the heap landed before the 3 s fallback)", pl.t and downs < 2.9, "%.2f s after the drop", downs)
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  pcall(tb.hold, "laser")
  wait(0.8)
  local tdig = time
  while time - tdig < 14 do
    tb.sim = { btn = { [0] = true }, aim = function()
      local aa, bb = astro(), home()
      local e = { x = aa.x + up.x * 0.6, y = aa.y + up.y * 0.6, z = aa.z + up.z * 0.6 }
      -- (origin, then a DIRECTION: tool_belt aim_ray) along the tunnel, a little down
      return e.x, e.y, e.z, t.x - up.x * 0.08, t.y - up.y * 0.08, t.z - up.z * 0.08
    end }
    yield()
    if time - tdig > 4 and clear(f11, 1) > d1 + 2.5 then break end
  end
  tb.sim = { btn = { [0] = false } }
  wait(1.0)
  local d2 = clear(f11, 1)
  CV.shot("rubble_7_dug", false)
  P("HZ RUBBLE dug %.1f s: the way ahead %.1f → %.1f m", time - tdig, d1, d2)
  HZ.check("…and the laser digs through it like rock", d2 > d1 + 1.5, "%.1f → %.1f m", d1, d2)
  pcall(tb.hold, "gravgun")
  HZ.heal()
end

-- (diagnosis) a LooseBoulder spawned in the cave's air: does it fall?
function HZ.slabdiag(cv)
  CV.stand(cv)
  wait(1)
  local b, a = home(), astro()
  local up = unit(sub(a, b))
  local t = cv.t
  local rel = { x = a.x - b.x + t.x * 3 + up.x * 3, y = a.y - b.y + t.y * 3 + up.y * 3, z = a.z - b.z + t.z * 3 + up.z * 3 }
  local nodes = {}
  do
    local wp = { x = b.x + rel.x, y = b.y + rel.y, z = b.z + rel.z }
    local okw, wa = pcall(function() return water and water.at and water.at(wp.x, wp.y, wp.z) end)
    local gx, gy, gz = 0, 0, 0
    if space.gravity then gx, gy, gz = space.gravity(wp.x, wp.y, wp.z) end
    local oc = findScript("ocean")
    local cl = findScript("climate")
    P("HZ DIAG at the cave point: water.at %s depth %s density %s | space.gravity %.2f (up %.2f) | ocean.caveDry %s | sea radius %s | r %.1f",
      tostring(okw), okw and wa and tostring(wa.depth) or "-", okw and wa and tostring(wa.density) or "-",
      len(gx, gy, gz), (gx * up.x + gy * up.y + gz * up.z), tostring(oc and oc.caveDry), tostring(cl and cl.seaRadius and cl.seaRadius(b.name)),
      len(rel.x, rel.y, rel.z))
  end
  -- one on the surface above the cave, for comparison (3 m over the ground)
  do
    local top = cv.top
    if top then
      local tu = unit(top)
      local hs = terrain.raycast(vec3(b.x + top.x + tu.x * 40, b.y + top.y + tu.y * 40, b.z + top.z + tu.z * 40), vec3(-tu.x, -tu.y, -tu.z), 200)
      if hs then
        local p = { x = hs.pos.x - b.x + tu.x * 3, y = hs.pos.y - b.y + tu.y * 3, z = hs.pos.z - b.z + tu.z * 3 }
        spawn("LooseBoulder", vec3(b.x + p.x, b.y + p.y, b.z + p.z), function(n) nodes[4] = { n = n, how = "surface", up = tu, rel = p } end)
      end
    end
  end
  for i, how in ipairs({ "plain", "rebuild", "vel" }) do
    b = home()
    -- 3.5 m apart (a boulder is 1.3 m across: 1.5 m apart they overlapped
    -- and shoved each other, 0688 review), each in open air
    local p = { x = rel.x + t.x * i * 3.5, y = rel.y + t.y * i * 3.5, z = rel.z + t.z * i * 3.5 }
    local hits = overlapSphere and overlapSphere(vec3(b.x + p.x, b.y + p.y, b.z + p.z), 0.7) or {}
    local fl = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-up.x, -up.y, -up.z), 30)
    P("HZ DIAG %s spot: %d overlaps, floor %.2f m under", how, #hits, fl and fl.distance or -1)
    spawn("LooseBoulder", vec3(b.x + p.x, b.y + p.y, b.z + p.z), function(n)
      nodes[i] = { n = n, how = how }
      if how ~= "plain" then pcall(assembly.rebuild, n) end
      if how == "vel" then pcall(function() n.asleep = false; n.vel = vec3(-up.x * 2, -up.y * 2, -up.z * 2) end) end
      local rb = n.getcomponent and n:getcomponent("RigidBody")
      P("HZ DIAG spawned %s: rb %s mode %s gravity %s kinematic %s parent %s", how, tostring(rb ~= nil), rb and tostring(rb.mode) or "-",
        rb and tostring(rb.gravity) or "-", rb and tostring(rb.kinematic) or "-", n.parent and tostring(n.parent.name) or "none")
    end)
  end
  for k = 1, 6 do
    wait(0.5)
    b = home()
    for i, e in pairs(nodes) do
      local n = e.n
      if n.valid then
        local q = { x = n.x - b.x, y = n.y - b.y, z = n.z - b.z }
        local inf = assembly.info(n)
        local uu, rr = e.up or up, e.rel or rel
        local iv = inf and inf.vel
        local fq = terrain.raycast(vec3(n.x, n.y, n.z), vec3(-uu.x, -uu.y, -uu.z), 30)
        P("HZ DIAG t%.1f %s: floor %.2f m under, height %.2f vel %s info.vel %s asleep %s wake %s", k * 0.5, e.how,
          fq and fq.distance or -1, dot(q, uu) - dot(rr, uu),
          n.vel and string.format("%.2f", dot(n.vel, uu)) or "-", iv and string.format("%.2f", dot(iv, uu)) or "-",
          tostring(inf and inf.asleep), tostring(inf and inf.wake))
      end
    end
  end
  for _, e in pairs(nodes) do if e.n.valid then e.n:destroy() end end
end

-- ROCKS (playtest 2026-11-12b: "rocks from cave-ins still float in the
-- air"): a fall 4 m ahead; once it is down, each loose slab's gap — its
-- box's lowest corner over what is under its centre (a ray down past itself)
-- — then the ground under each dug (a 1.3 m ball under its centre) and the
-- gap again 3 s later; then the world saved and loaded again and the gap of
-- every slab brought back. `HZ ROCK` lines.
function HZ.rock_gap(n)
  local b = home()
  local u = unit({ x = n.x - b.x, y = n.y - b.y, z = n.z - b.z })
  local h = raycast(n.x, n.y, n.z, -u.x, -u.y, -u.z, 8, { ignore = { n } })
  if not h then return nil end
  local s = n.scale
  if type(s) == "table" then s = s.x end
  s = tonumber(s) or 1
  local R, U, F = n:worldRight(), n:worldUp(), n:worldForward()
  local e = (math.abs(dot(R, u)) * 0.637 + math.abs(dot(U, u)) * 0.377 + math.abs(dot(F, u)) * 0.559) * s
  -- (on a slope, a rubble edge or a pit's rim the box rests on a corner the
  -- ray down from its centre misses: the ground's own distance (the field)
  -- at its 8 corners, the nearest, is the gap; the ray's is kept for the log)
  local cg = nil
  if terrain.query and n.toWorld then
    for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
      local okw, w = pcall(n.toWorld, n, vec3(sx * 0.637, sy * 0.377, sz * 0.559))
      local q = okw and w and terrain.query(w.x, w.y, w.z)
      if q then cg = math.min(cg or 99, q) end
    end end end
  end
  return cg or (h.distance - e), h.distance, e, h.distance - e
end
function HZ.slabs_near(p, r)
  local mf = findScript("mineral_field")
  local out = {}
  local b = home()
  for _, e in ipairs(mf.looseBodies() or {}) do
    if e.pf == "LooseBoulder" and e.n and e.n.valid then
      if not p or len(e.n.x - b.x - p.x, e.n.y - b.y - p.y, e.n.z - b.z - p.z) < r then out[#out + 1] = e end
    end
  end
  return out
end
function HZ.rock_report(tag, list)
  local worst, n = -9, 0
  for _, e in ipairs(list) do
    local g, d, ex, rg = HZ.rock_gap(e.n)
    if g then
      n = n + 1
      worst = math.max(worst, g)
      local inf = assembly.info(e.n)
      -- what it touches (a prop, a slab, the crew: not terrain), within its half-height and a hand
      local touch = {}
      local okh, hits = pcall(overlapSphere, vec3(e.n.x, e.n.y, e.n.z), ex + 0.15, { ignore = { e.n }, ignoreChildren = true })
      for _, hh in ipairs(okh and hits or {}) do touch[#touch + 1] = tostring(hh.node and hh.node.name or "terrain") end
      P("HZ ROCK %s %s: nearest corner %.2f m off the ground (under the centre %.2f: centre %.2f over it, half-height %.2f), asleep %s, wake %s, touching [%s]", tag, e.name, g, rg or -1, d, ex,
        tostring(inf and inf.asleep), tostring(inf and inf.wake), table.concat(touch, ","))
    end
  end
  return worst, n
end
function HZ.rocks(cv)
  local ch = findScript("cave_hazards")
  local b = home()
  local a = astro()
  local up = unit(sub(a, b))
  local t = cv.t
  local tgt
  for _, d in ipairs({ 4, 3, 5, 2 }) do
    local p = { x = a.x - b.x + t.x * d + up.x * 1.4, y = a.y - b.y + t.y * d + up.y * 1.4, z = a.z - b.z + t.z * d + up.z * 1.4 }
    local q = terrain.query(b.x + p.x, b.y + p.y, b.z + p.z)
    if q and q > 0.8 then tgt = p; break end
  end
  tgt = tgt or { x = a.x - b.x + t.x * 3 + up.x * 1.4, y = a.y - b.y + t.y * 3 + up.y * 1.4, z = a.z - b.z + t.z * 3 + up.z * 1.4 }
  local pc = findScript("planet_camera")
  pc.face(t.x, t.y, t.z, -0.1)
  for k = 1, tonumber(params.falls) or 2 do
    ch.fallCooldown = 0
    ch.startRockfall(b.name, tgt.x, tgt.y, tgt.z, "probe")
    wait_for(function() return ch.fallState() == nil end, 20, "the fall")
    wait(2.5)
  end
  wait(3)
  CV.shot("rocks_1_down", false)
  local list = HZ.slabs_near(tgt, 25)
  local w1, n1 = HZ.rock_report("settled", list)
  HZ.check("cave-in slabs rest on the ground", n1 == 0 or w1 < 0.25, "%d slabs, worst gap %.2f m", n1, w1)
  -- the ground under each dug
  local y0 = {}
  for _, e in ipairs(list) do
    local n = e.n
    local bb = home()
    local u = unit({ x = n.x - bb.x, y = n.y - bb.y, z = n.z - bb.z })
    local g, d = HZ.rock_gap(n)
    if d then
      y0[e.name] = len(n.x - bb.x, n.y - bb.y, n.z - bb.z)
      terrain.dig(n.x - u.x * (d + 0.4), n.y - u.y * (d + 0.4), n.z - u.z * (d + 0.4), 1.3, 1.0, { hardness = 0.8 })
    end
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20, "the digs")
  wait(3)
  local dropped, nd = 0, 0
  for _, e in ipairs(list) do
    if e.n.valid and y0[e.name] then
      nd = nd + 1
      local bb = home()
      local dr = y0[e.name] - len(e.n.x - bb.x, e.n.y - bb.y, e.n.z - bb.z)
      P("HZ ROCK dug %s: dropped %.2f m", e.name, dr)
      if dr > 0.3 then dropped = dropped + 1 end
    end
  end
  local w2, n2 = HZ.rock_report("dug", list)
  CV.shot("rocks_2_dug", false)
  local mf = findScript("mineral_field")
  HZ.check("…and fall when their ground is dug", nd == 0 or (dropped == nd and w2 < 0.25), "%d of %d dropped, worst gap %.2f m, woken %d", dropped, nd, w2, mf.looseWoken or -1)
  -- saved and loaded again
  findScript("flight_ops").fleetSync(true)
  wait(2.5)   -- (mineral_field writes loose.bodies every 2 s)
  save.flush()
  local rel = { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
  scene.load("system")
  yield()
  wait_for(function()
    local gm = findScript("game_manager")
    return gm and not gm.loading and not gm.curtain
  end, 240, "the reload")
  CV.stand(cv)
  wait(8)
  local back = HZ.slabs_near(tgt, 25)
  local w3, n3 = HZ.rock_report("reloaded", back)
  CV.shot("rocks_3_reloaded", false)
  HZ.check("…and after a reload", n3 >= 1 and w3 < 0.25, "%d slabs back, worst gap %.2f m", n3, w3)
end

function HZ.dose(cv)
  local ch, mf = findScript("cave_hazards"), findScript("mineral_field")
  local a = astro()
  local found
  for _, v in ipairs(mf.veinsNear(a.x, a.y, a.z, 200)) do
    if v.ore == "uranium" and (v.depth or 0) > 6 then found = v; break end
  end
  local C = findScript("crew")
  local id = C.activeId()
  local _, d0 = HZ.hp()
  if found then
    -- dig a pocket at the seam's side and stand in it
    local b = home()
    local U = { x = found.ux, y = found.uy, z = found.uz }
    local side = unit(cross(U, unit({ x = found.sx, y = found.sy, z = found.sz })))
    local p = { x = found.x + side.x * 3, y = found.y + side.y * 3, z = found.z + side.z * 3 }
    terrain.dig(p.x, p.y, p.z, 2.6, 1.0, { hardness = 0.9, falloff = "smooth" })
    wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 20, "the pocket")
    local bb = home()
    local rel = { x = p.x - b.x, y = p.y - b.y, z = p.z - b.z }
    local aa = astro()
    aa.x, aa.y, aa.z = bb.x + rel.x - U.x * 1.0, bb.y + rel.y - U.y * 1.0, bb.z + rel.z - U.z * 1.0
    aa.vx, aa.vy, aa.vz = 0, 0, 0
    P("HZ DOSE a uranite seam %.0f m down: standing 3 m from its line", found.depth or -1)
  else
    P("HZ DOSE no uranite seam within 200 m: forceDoseOre 20 µSv/h in the cave")
    ch.params.forceDoseOre = 20
  end
  wait(6)
  HZ.read("dose")
  local _, d1 = HZ.hp()
  HZ.check("within 6 m of pitchblende: the crew takes a dose (the reactor's step)", d1 > d0, "dose %.6f → %.6f (%s)", d0, d1, found and "real seam" or "forced")
  ch.params.forceDoseOre = 0
  HZ.heal()
  CV.stand(cv)
  wait(1.5)
end

function HZ.vent(cv)
  local ch, cf = findScript("cave_hazards"), findScript("cave_field")
  cf.params.forceKind = "vent"
  cf.reset()
  ch.params.forceAir = "SO2"
  CV.stand(cv)
  wait(7)
  local pk = HZ.pocket("SO2", 40)
  if pk then HZ.put(HZ.floor_at(pk.floor, cv.t, 3, pk.u) or pk.floor, pk.u); wait(2) end
  local g = HZ.read("vent")
  CV.look(cv.t, cv.dir, -0.05, "vent_hud", true)
  CV.look(cv.t, cv.dir, -0.05, "vent", false)
  HZ.check("a sulfur vent: SO2 on the chip", g and (g.gas == "SO2" or g.gas == "H2S") and g.level >= 1, "%s", g and tostring(g.text) or "-")
  ch.params.forceAir = ""
  ch.probePocket = nil
  cf.params.forceKind = ""
  cf.reset()
end

function HZ.cost(tag, secs)
  sc_begin(tag)
  local t0 = time
  key_down("w")
  while time - t0 < (secs or 4) do yield() end
  key_up("w")
  local r = RECS[tag]
  sc_end(tag)
  local function ms(k) return (r and r.s[k] or 0) / math.max(r and #r.dts or 1, 1) end
  local ch = findScript("cave_hazards")
  P("HZ COST %s: cave_hazards %.4f cave_field %.4f underground %.4f ms/frame | cave_hazards' own %.4f ms a probe | probes %d",
    tag, ms("cave_hazards"), ms("cave_field"), ms("underground"), ch.stats.ms or -1, ch.stats.probes or -1)
end

-- the ruins: a mine head and a sink camp on the home world
function HZ.ruins()
  local RU = findScript("ruins")
  local L = findScript("loot")
  local ST = findScript("structures")
  local b = home()
  local list = RU.sites(b.name)
  local real = {}
  for _, s in ipairs(list) do if not s.pending then real[#real + 1] = s end end
  P("HZ RUINS %d sites on %s", #real, b.name)
  local plan = { "mine", "sinkcamp" }
  for i, kind in ipairs(plan) do
    local s = real[i]
    if not s then P("HZ RUINS no site for %s", kind); break end
    RU.forceCaveKind(s.id, kind)
    -- go there (the site's direction, on the ground)
    local x, y, z = RU.pointOf(s)
    local u = unit({ x = x, y = y, z = z })
    local bb = home()
    local gr = ground_r(bb, u.x, u.y, u.z, len(x, y, z) + 200)
    local t1 = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
    local off = dir_at(u, t1, 40, len(x, y, z))
    local g2 = ground_r(bb, off.x, off.y, off.z, len(x, y, z) + 200) or gr
    local a = astro()
    a.x, a.y, a.z = bb.x + off.x * (g2 + 1.5), bb.y + off.y * (g2 + 1.5), bb.z + off.z * (g2 + 1.5)
    a.vx, a.vy, a.vz = 0, 0, 0
    if terrain.prepare then pcall(terrain.prepare, a.x, a.y, a.z, 80) end
    wait_for(function() local e = RU.peekState(s.id); return e and e.sid ~= nil end, 30, "the stamp")
    wait_for(function() local e = RU.peekState(s.id); return e and e.sh ~= nil end, 40, "the cave search")
    local e = RU.peekState(s.id)
    if e and e.sh == nil then RU.caveNow(s.id); e = RU.peekState(s.id) end
    wait_for(function() return not (terrain.pending and terrain.pending() > 0) end, 40, "the dig")
    wait(2)
    local sh = e and e.sh
    P("HZ RUINS %s (%s): cave %s", s.name, kind, sh and string.format("floor %.1f m down at (%.1f, %.1f), %s, %s edits", sh.d, sh.x, sh.z,
      sh.nat and "a natural chamber" or "a doline", tostring(sh.dug)) or "none")
    HZ.check(kind .. ": its cave found and dug", sh ~= nil and sh ~= false and sh.dug ~= nil)
    if sh and e.sid then
      local rec = ST.get(e.sid)
      local foot, cont = nil, {}
      for _, p in ipairs(rec and rec.bp or {}) do
        if (p.ri or 0) > RU.CAVE_RI or (kind == "sinkcamp" and (p.y or 0) < -2) then
          if p.rl == "loot" or p.rl == "store" then cont[#cont + 1] = p end
          if p.rl == "loot" and not foot then foot = p end
        end
      end
      HZ.check(kind .. ": containers in the cave", #cont >= 2, "%d", #cont)
      -- loot: the site's containers rolled once; list the cave ones
      local n = L and L.fillSite and L.fillSite(e.sid) or 0
      local inv = findScript("inventory")
      local items = 0
      for _, p in ipairs(cont) do
        local cid = L.cidOf(e.sid, p.uid)
        local li = inv.itemList(cid) or {}
        local names = {}
        for _, it in ipairs(li) do names[#names + 1] = string.format("%s×%s", tostring(it.id), tostring(it.n or it.count)) ; items = items + 1 end
        P("HZ LOOT %s %s (ri %s): %s", s.name, p.id, tostring(p.ri), #names > 0 and table.concat(names, ", ") or "(empty, or materials only)")
      end
      HZ.check(kind .. ": its cave containers hold loot (loot.fillSite)", n > 0 and items > 0, "%d containers rolled, %d stacks in the cave's", n, items)
      -- stand at the foot and look about
      if foot then
        local px, py, pz = ST.partPose(rec, foot, 0)
        local bb2 = home()
        local up = { x = rec.ux, y = rec.uy, z = rec.uz }
        local f = { x = rec.fx, y = rec.fy, z = rec.fz }
        local aa = astro()
        aa.x, aa.y, aa.z = bb2.x + px + up.x * 1.2 - f.x * 2.5, bb2.y + py + up.y * 1.2 - f.y * 2.5, bb2.z + pz + up.z * 1.2 - f.z * 2.5
        aa.vx, aa.vy, aa.vz = 0, 0, 0
        wait(4)
        local pc = findScript("planet_camera")
        local fl = findScript("flashlight")
        if fl and fl.setOn then fl.setOn(true) end
        pc.face(f.x, f.y, f.z, -0.1)
        wait(1.5)
        CV.shot("ruin_" .. kind .. "_foot", false)
        pc.face(-f.x, -f.y, -f.z, 0.3)
        wait(1.2)
        CV.shot("ruin_" .. kind .. "_up", false)
        HZ.read("ruin_" .. kind)
        if fl and fl.setOn then fl.setOn(false) end
      end
    end
  end
end

function HZ.run()
  wait_ready(90)
  clear_weather()
  CV.level()
  CV.tag = string.format("hz%d", math.floor(params.seed or 0))
  local b = home()
  local wd = save.get("world." .. b.name) or {}
  P("HZ WORLD %s type %s air O2 %s p0 %s", b.name, tostring(wd.geo and wd.geo.type), tostring(wd.air and wd.air.o2), tostring(wd.air and wd.air.p0))
  CV.give()
  local cv = CV.find()
  if not cv then cv = CV.carve() end
  CV.stand(cv)
  wait(2)
  CV.stand(cv)
  HZ.t = cv.t
  local pc = findScript("planet_camera")
  pc.firstPerson = true
  wait_for(function() local c = perf.counts() or {}; return (c.meshesPending or 0) < 4 end, 30, "meshes")
  wait(6)
  local ch = findScript("cave_hazards")
  local cf = findScript("cave_field")
  HZ.read("natural")
  HZ.check("cave_hazards runs on cave_field's probe", ch.stats.probes > 0 and cf.caveKind ~= nil, "probes %d kind %s", ch.stats.probes, tostring(cf.caveKind))
  if ch.last.first then P("HZ FIRST %s on %s: comp → %.2f, +%d RP", ch.last.first.kind, ch.last.first.body, ch.last.first.comp or -1, ch.last.first.rp or 0) end
  HZ.check("first entry into the kind: survey composition and RP", ch.last.first ~= nil)
  HZ.cost("cost_walk", 4)
  CV.stand(cv); wait(1)
  if (params.only or "") == "" or params.only == "air" then HZ.air(cv) end
  CV.stand(cv); wait(1)
  if (params.only or "") == "" or params.only == "ch4" then HZ.methane(cv) end
  cf.params.forceKind = ""
  CV.stand(cv); wait(1)
  if params.only == "slabdiag" then HZ.slabdiag(cv) end
  if params.only == "rocks" then HZ.rocks(cv) end
  if (params.only or "") == "" or params.only == "fall" then HZ.rockfall(cv) end
  CV.stand(cv); wait(1)
  if (params.only or "") == "" or params.only == "fall" or params.only == "rubble" then HZ.rubble(cv) end
  if (params.only or "") == "" or params.only == "dose" then HZ.dose(cv) end
  if (params.only or "") == "" or params.only == "vent" then HZ.vent(cv) end
  if (params.only or "") == "" or params.only == "ruins" then HZ.ruins() end
  pc.firstPerson = false
  P("HZ RESULT %d/%d checks passed", HZ.checks - HZ.fails, HZ.checks)
end
