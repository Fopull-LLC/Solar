-- GRAVEYARD SHIFT: the station's pieces (scenarios/graveyard_shift/).
--
-- Writes the scenario's pre-built base as a SOLBP1 code, generated from this
-- list so the plant's loops close nozzle to nozzle (the ports are chained the
-- way the kit's port snap meets them) and the rooms seal. Run from the folder
-- that holds `solar` (the repo):
--
--   luajit solar/tools/gen_graveyard_station.lua          -- check and print
--   luajit solar/tools/gen_graveyard_station.lua write    -- write station.bp.txt
--
-- The structure's frame: +X east, +Z north, +Y up, the slab deck at y 0.2.
--   HALL     x -1..13, z -7..9: two storeys, sealed, the plant inside
--   CONTROL  x -7..-1, z -1..5: the console at the windows onto the hall
--   BUNKS    x -7..-3, z 5..7
--   AIRLOCK  x -5..-3, z -3..-1 (out to the south)
--   OUTSIDE  the radiator row and the FW-2 skid east of the hall, the tower,
--            the battery banks and the isotope skid west of the hab
local M = {}
local Q = math.pi / 2

local function rot(x, z, th)
  local c, s = math.cos(th), math.sin(th)
  return x * c + z * s, -x * s + z * c
end
local function r6(v) return math.floor(v * 1e4 + 0.5) / 1e4 end

function M.build(defs)
  local P, U = {}, {}
  local uid = 0
  local function add(id, x, y, z, yaw, extra)
    uid = uid + 1
    local p = { uid = uid, id = id, x = r6(x), y = r6(y), z = r6(z), yaw = yaw or 0, pitch = 0, roll = 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    P[#P + 1] = p
    return uid, p
  end
  -- ── the port chain: place `id` with its port `pin` on the open end E
  -- (x, z, heading dx, dz), facing back along the heading; → the other
  -- ports' open ends { name → { x, z, dx, dz } } and the uid
  local Y = 0.2
  local function chain(E, id, pin, name, y, extra)
    local d = defs(id)
    assert(d and d.ports, "no ports on " .. id)
    local port
    for _, pt in ipairs(d.ports) do if pt.name == pin then port = pt end end
    assert(port, id .. " has no port " .. pin)
    for _, th in ipairs({ 0, Q, math.pi, -Q }) do
      local nx, nz = rot(port.nx, port.nz, th)
      if math.abs(nx + E.dx) < 1e-6 and math.abs(nz + E.dz) < 1e-6 then
        local px, pz = rot(port.x, port.z, th)
        local cx, cz = E.x - px, E.z - pz
        local u = add(id, cx, y or Y, cz, th, extra)
        if name then U[name] = u end
        local out = {}
        for _, pt in ipairs(d.ports) do
          if pt.name ~= pin then
            local ox, oz = rot(pt.x, pt.z, th)
            local ux, uz = rot(pt.nx, pt.nz, th)
            out[pt.name] = { x = cx + ox, z = cz + oz, dx = r6(ux), dz = r6(uz) }
          end
        end
        return out, u
      end
    end
    error("no yaw fits " .. id .. ":" .. pin)
  end
  local function one(t) local _, v = next(t); return v end
  local function line(E, ids)
    for _, it in ipairs(ids) do
      local o = chain(E, it[1], it[2], it[3])
      E = it[4] and o[it[4]] or one(o)
    end
    return E
  end

  -- ── the slabs (one record; a hall, a hab, the outside pads) ──
  local function slab(x, z) add("slab2.concrete", x, 0, z, 0) end
  for x = -6, 12, 2 do for z = -6, 8, 2 do
    local hab = x < 0
    local inHab = (x >= -6 and x <= -2 and z >= -2 and z <= 4) or (x >= -6 and x <= -4 and z == 6)
    if not hab or inHab then slab(x, z) end
  end end
  for _, z in ipairs({ 4, 6 }) do for x = 14, 20, 2 do slab(x, z) end end    -- the FW-2 skid's pad

  -- ── the plant: the vessel and its core ──
  local VX, VZ = 4, 0
  U.vessel = add("reactorBase.steel", VX, Y, VZ, 0)
  local CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }   -- (north row first; the S6 fixture's core)
  local KIND = { F = "fuelChannel.steel", G = "modGraphite.graphite", W = "modWater.steel", R = "controlRod.steel" }
  U.cells = {}
  for r = 1, 5 do
    local j = 3 - r
    for i = -2, 2 do
      local ch = CORE[r]:sub(i + 3, i + 3)
      if KIND[ch] then
        local u = add(KIND[ch], VX + i * 0.5, Y + 1.0, VZ + j * 0.5, 0)
        U.cells[#U.cells + 1] = { uid = u, ch = ch }
      end
    end
  end
  -- the primary: vessel out (north) → the steam generator → two coolant
  -- pumps in line → the cold leg (spool PL-7) → the pressuriser's tee → in
  local E = { x = VX, z = VZ + 1.5, dx = 0, dz = 1 }
  local o = chain(E, "pipe1.steel", "a", "hotleg")
  o = chain(one(o), "steamGen.steel", "pri_in", "sg")
  local sgo = o
  E = sgo.pri_out
  E = line(E, { { "pipeElbow.steel", "b" }, { "pipeIns2.steel", "a" }, { "pipeElbow.steel", "a" } })
  E = line(E, { { "coolantPump.steel", "in", "rcp1" } })
  E = line(E, { { "coolantPump.steel", "in", "rcp2" } })
  E = line(E, { { "pipeElbow.steel", "a" } })
  E = line(E, { { "pipeIns2.steel", "a", "pl7" } })             -- PL-7: the cold-leg spool with the clamp
  o = chain(E, "pipeTee.steel", "b", "tee")
  -- (the tee's branch c south to the pressuriser, its run a on to the vessel)
  local tc, tb = o.c, o.a
  local po = chain(tc, "pressuriser.steel", "surge", "press")
  E = line(tb, { { "pipeElbow.steel", "a" } })
  E = line(E, { { "pipe1.steel", "a", "coldin" } })
  M.primaryEnd = E
  -- the makeup line: the pressuriser's DN25 nozzle → MU-1 → P-3 → the coolant tank
  local mk = po.makeup
  E = line({ x = mk.x, z = mk.z, dx = mk.dx, dz = mk.dz }, { { "flValve.steel", "a", "mu1" }, { "flPipe1.steel", "a" } })
  E = line(E, { { "flPump.steel", "out", "p3" } })
  E = line(E, { { "flPipe1.steel", "a" } })
  chain(E, "flTankCool.steel", "out", "tank")
  -- the secondary: the generator's steam → the turbine → east through the
  -- hall's wall → the radiator row → FW-2 on its skid → back west → FW-1 → in
  E = line(sgo.sec_out, { { "pipeIns2.steel", "a" } })
  o = chain(E, "turbineSet.steel", "steam", "turbine")
  E = line(o.exhaust, { { "pipeElbow.steel", "b" } })
  E = line(E, { { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" } })
  U.rads = {}
  for k = 1, (M.NRAD or 8) do
    local oo, u = chain(E, "radiatorPanel.steel", "in")
    U.rads[k] = u
    E = one(oo)
  end
  E = line(E, { { "pipe1.steel", "a" }, { "pipeElbow.steel", "a" }, { "pipeElbow.steel", "a" } })
  -- (the return west along z 5, lagged; FW-2 on its skid by the hall, then in)
  for _ = 1, (M.NRAD or 8) * 3 / 2 - 2 do E = line(E, { { "pipeIns2.steel", "a" } }) end
  E = line(E, { { "coolantPump.steel", "in", "fw2" } })
  E = line(E, { { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" } })
  E = line(E, { { "coolantPump.steel", "in", "fw1" } })
  E = line(E, { { "pipeIns2.steel", "a" }, { "pipeIns2.steel", "a" } })
  E = line(E, { { "pipeElbow.steel", "b" } })
  M.secondaryEnd, M.secIn = E, sgo.sec_in
  -- (the run from FW-1 to the generator's secondary inlet: whatever is left, in pipe)
  local gapx = E.x - sgo.sec_in.x
  M.gap = { E = E, to = sgo.sec_in }

  -- ── the shield: magnetite blocks round the core, three high. Two blocks
  -- of the south face are out at the foot (the PL-7 job never put them back)
  local gap = { ["4,-2,0"] = true, ["4,2,0"] = true, ["5,-2,0"] = true, ["5,-2,1"] = true, ["6,-2,0"] = true }
  local ring = {}
  for z = -2, 2 do ring[#ring + 1] = { 2, z }; ring[#ring + 1] = { 6, z } end
  for x = 3, 5 do ring[#ring + 1] = { x, -2 }; ring[#ring + 1] = { x, 2 } end
  for _, c in ipairs(ring) do
    for lv = 0, 2 do
      if not gap[c[1] .. "," .. c[2] .. "," .. lv] then add("shieldHeavy.concrete", c[1], Y + lv, c[2], 0) end
    end
  end
  -- (the two blocks lifted out, left on the floor by the spool)
  add("shieldHeavy.concrete", 6.0, Y, -5.6, 0.3)
  add("shieldHeavy.concrete", 7.2, Y, -5.9, -0.2)

  -- ── walls (a wall at an edge: along X at z = odd with yaw 0, along Z at x = odd with yaw Q) ──
  local function wx(id, x, y, z, out) add(id, x, y, z, out and 0 or math.pi) end        -- along X; out = faces +Z
  local function wz(id, x, y, z, out) add(id, x, y, z, out and Q or -Q) end            -- along Z; out = faces +X
  local CW = "wall.concrete"
  -- the HALL: x -1..13, z -7..9, two storeys, the roof at 4.8
  for _, y in ipairs({ Y, Y + 2.2 }) do   -- (no deck between: the upper course sits straight on the lower)
    for x = 0, 12, 2 do wx(CW, x, y, -7, false); wx(CW, x, y, 9, true) end
    for z = -6, 8, 2 do
      wz(CW, 13, y, z, true)
      local id = CW
      if y == Y and z == 0 then id = "windowWall.concrete" end
      if y == Y and z == 2 then id = "bulkhead.steel"; U.bulkhead = uid + 1 end
      if y == Y and z == 4 then id = "windowWall.concrete" end
      wz(id, -1, y, z, false)
    end
  end
  for x = 0, 12, 2 do for z = -6, 8, 2 do add("floor.steel", x, Y + 4.4, z, 0) end end
  -- the CONTROL ROOM (x -7..-1, z -1..5), the BUNKS (x -7..-3, z 5..7), the AIRLOCK (x -5..-3, z -3..-1)
  wz("wall.steel", -7, Y, 0, false); wz("porthole.steel", -7, Y, 2, false); wz("wall.steel", -7, Y, 4, false)
  wx("wall.steel", -6, Y, -1, false); U.lockIn = uid + 1; wx("airlockWall.steel", -4, Y, -1, false); wx("windowWall.steel", -2, Y, -1, false)
  U.bunkDoor = uid + 1; wx("doorWall.steel", -6, Y, 5, true); wx("wall.steel", -4, Y, 5, true); wx("wall.steel", -2, Y, 5, true)
  wz("wall.steel", -7, Y, 6, false); wx("wall.steel", -6, Y, 7, true); wx("wall.steel", -4, Y, 7, true); wz("wall.steel", -3, Y, 6, true)
  wz("wall.steel", -5, Y, -2, false); wz("wall.steel", -3, Y, -2, true); U.lockOut = uid + 1; wx("airlockWall.steel", -4, Y, -3, false)
  for x = -6, -2, 2 do for z = 0, 4, 2 do add("floor.steel", x, Y + 2.2, z, 0) end end
  add("floor.steel", -6, Y + 2.2, 6, 0); add("floor.steel", -4, Y + 2.2, 6, 0); add("floor.steel", -4, Y + 2.2, -2, 0)
  add("steps.steel", -4, 0, -4.0, math.pi)

  -- ── inside the control room ──
  U.console = add("reactorConsole.steel", -2.3, Y, 0.0, -Q)
  U.logdesk = add("table.steel", -6.1, Y, 3.9, Q)
  add("monitor.steel", -6.1, Y + 0.74, 3.9, Q)
  add("coffee.steel", -6.2, Y + 0.74, 3.2, Q)
  add("chair.steel", -5.5, Y, 3.9, -Q)
  add("chair.steel", -3.3, Y, 0.0, -Q)
  add("shelf.steel", -6.6, Y, 1.0, Q)
  add("o2gen.steel", -2.6, Y, 4.5, math.pi)
  add("scrubber.steel", -3.6, Y, 4.6, math.pi)
  add("airTank.steel", -4.8, Y, 4.6, math.pi)
  add("workbench.steel", -6.5, Y, -0.3, Q)
  add("grimeScuff.film", -4, Y + 0.002, 2, 0)
  for _, c in ipairs({ { -4, 0 }, { -4, 4 }, { -6, 6 } }) do add("lightFitting.steel", c[1], Y + 2.2, c[2], 0, { pitch = math.pi }) end
  -- the bunk room: Dana's
  U.bunk = add("bunk.steel", -5.0, Y, 6.45, 0)
  add("crateS.steel", -3.6, Y, 5.6, 0.4)
  add("coffee.steel", -3.6, Y + 0.45, 5.6, 0.4)
  -- ── the hall's dressing: the half-finished PL-7 job at the cold leg ──
  add("lampFloor.steel", 6.4, Y, -4.6, 2.6)
  add("crateS.steel", 7.6, Y, -4.4, 0.2)
  add("drum.steel", 8.6, Y, -5.6, 0)
  add("grimeSoot.film", 6.5, Y + 0.002, -3.8, 0.4)
  add("grimeOil.film", 8.2, Y + 0.002, 0.6, 1.2)
  add("decalHaz.film", 4, Y + 0.002, -2.75, 0)
  add("decalHaz.film", 4, Y + 0.002, 2.75, 0)
  add("workbench.steel", 11.8, Y, 8.3, 0)
  add("shelf.steel", 12.4, Y, -2.0, -Q)
  -- (four strip lights for a 14 x 16 m hall: a night shift's half-lit plant;
  -- the other two fittings' places carry cable trays)
  for _, c in ipairs({ { 2, -4 }, { 9, -3 }, { 3, 5 }, { 10, 5 } }) do
    add("lightFitting.steel", c[1], Y + 4.4, c[2], 0, { pitch = math.pi })
  end
  add("wallTray.steel", 6, Y + 4.4, 0, 0, { pitch = math.pi })
  add("wallTray.steel", 6, Y + 4.4, 2, 0, { pitch = math.pi })
  -- ── the hall's alarm: the console's TRIPPED → two beacons (wired by the scenario) ──
  U.beaconHall = add("loAlarm.steel", 0, Y + 4.4, -1, 0, { pitch = math.pi })
  U.beaconCtl = add("loAlarm.steel", -2, Y + 2.2, 2, 0, { pitch = math.pi })

  -- ── outside: the FW-2 skid by the radiator row, its work light, the spares crate ──
  U.skidLight = add("lampFloor.steel", 17.0, Y, 3.1, 0.5)
  U.spares = add("crate.steel", 20.6, Y, 3.4, 0.1)
  add("drum.steel", 21.6, Y, 3.6, 0)
  -- the base's power: the tower, the battery banks and two isotope skids west of the hab
  U.tower = add("tower", -16, 0, 6, 0)
  for k = 0, 5 do add("batteryBank", -15 + 2.4 * k, 0, -6, 0) end
  add("isotopeSkid", -12, 0, 2, 0)
  add("isotopeSkid", -12, 0, -1, 0)
  -- a second course of magnetite on the core's west face, between it and the
  -- control room's windows (added last: the scenario's uids above stay put)
  for z = -2, 2 do for lv = 0, 2 do add("shieldHeavy.concrete", 1, Y + lv, z, 0) end end
  return P, U, add, chain, line
end

return M
