-- A reactor plant as structure records, for tests/smoke_reactor.lua (and a
-- driver to explore the physics). Every piece on one floor (y 0), structure
-- frame, yaw in radians; the core's columns on the vessel's top (y 1.0).
--
--   primary   vessel (0,0) → pipe1 → steam generator (0.5, 3.5) → elbow →
--             pipe → elbow → pump → pipe → elbow → pipe → tee (the
--             pressuriser on its branch) → elbow → pipe1 → vessel
--   secondary steam generator → pipe → turbine (1, 7.5) → elbow → two
--             radiator panels → elbow → elbow → feed pump → pipes → elbow →
--             steam generator
local F = {}
local Q = math.pi / 2

-- the loops' pieces (no core)
function F.loops(opts)
  opts = opts or {}
  local bp = {}
  local uid = 0
  local function add(id, x, z, yaw, y)
    uid = uid + 1
    bp[#bp + 1] = { uid = uid, id = id, x = x, y = y or 0, z = z, yaw = yaw or 0, pitch = 0, roll = 0 }
    return uid
  end
  local U = {}
  U.vessel = add("reactorBase.steel", 0, 0, 0)
  if not opts.noPrimary then
    add("pipe1.steel", 0, 2.0, 0)
    U.sg = add("steamGen.steel", 0.5, 3.5, 0)
    add("pipeElbow.steel", 1.0, 2.0, -Q)
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 2.5, 2.0, Q)
    add("pipeElbow.steel", 4.0, 2.0, Q)
    U.pump = add("coolantPump.steel", 4.0, 0.5, math.pi)
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 4.0, -1.5, 0)
    add("pipeElbow.steel", 4.0, -3.0, math.pi)
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 2.5, -3.0, Q)
    if opts.noPress then add("pipe1.steel", 1.0, -3.0, Q)
    else
      add("pipeTee.steel", 1.0, -3.0, Q)
      U.press = add("pressuriser.steel", 1.0, -4.5, math.pi)
    end
    add("pipeElbow.steel", 0, -3.0, -Q)
    if not opts.openPrimary then add("pipe1.steel", 0, -2.0, 0) end
  end
  if not opts.noSecondary then
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 0, 5.5, 0)
    U.turbine = add("turbineSet.steel", 1.0, 7.5, 0)
    add("pipeElbow.steel", 2.0, 6.0, -Q)
    if opts.sink == "rad" then
      -- (two radiator panels end to end: 32 m², too little for the whole plant)
      U.rad1 = add("radiatorPanel.steel", 4.0, 6.0, 0)
      U.rad2 = add("radiatorPanel.steel", 7.0, 6.0, 0)
    else
      -- (a cooling tower cell north of the line, its nozzles on two elbows)
      add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 3.5, 6.0, Q)
      add("pipeElbow.steel", 5.0, 6.0, math.pi)
      U.tower = add("coolingTower.steel", 5.5, 8.5, 0)
      add("pipeElbow.steel", 6.0, 6.0, -Q)
      add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 7.5, 6.0, Q)
    end
    add("pipeElbow.steel", 9.0, 6.0, Q)
    add("pipeElbow.steel", 9.0, 5.0, math.pi)
    U.feed = add("coolantPump.steel", 7.5, 5.0, -Q)
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 5.5, 5.0, Q)
    add(opts.insulated and "pipeIns2.steel" or "pipe2.steel", 3.5, 5.0, Q)
    add("pipe1.steel", 2.0, 5.0, Q)
    add("pipeElbow.steel", 1.0, 5.0, 0)
  end
  return bp, U, add
end

-- The core: `rows` = 5 strings of 5 characters, north (j = 2) first; the
-- columns: F fuel, G graphite, W light water, H heavy water, R control rod,
-- . empty. A second storey with `rows2`.
local KIND = { F = "fuelChannel.steel", G = "modGraphite.graphite", W = "modWater.steel", H = "modHeavy.steel", R = "controlRod.steel" }
function F.core(add, rows, level)
  local cells = {}
  for r = 1, 5 do
    local j = 3 - r
    local s = rows[r]
    for i = -2, 2 do
      local ch = s:sub(i + 3, i + 3)
      if KIND[ch] then
        local u = add(KIND[ch], i * 0.5, j * 0.5, 0, 1.0 + 2.4 * (level or 0))
        cells[#cells + 1] = { uid = u, ch = ch, i = i, j = j }
      end
    end
  end
  return cells
end

-- A whole plant record. → rec, U (uids), cells
function F.plant(rows, opts)
  local bp, U, add = F.loops(opts)
  local cells = F.core(add, rows, 0)
  if opts and opts.rows2 then for _, c in ipairs(F.core(add, opts.rows2, 1)) do cells[#cells + 1] = c end end
  local rec = { id = opts and opts.sid or 7, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp, st = {} }
  return rec, U, cells
end

-- Channels loaded with n rods of `item` each (a list: the rods by turn).
function F.fuel(RX, cells, item, n)
  local ch = {}
  for _, c in ipairs(cells) do
    if c.ch == "F" then
      local rods = {}
      for k = 1, (n or 8) do rods[k] = RX.newRod(type(item) == "table" and item[(k - 1) % #item + 1] or item) end
      ch[c.uid] = { rods = rods }
    end
  end
  return ch
end

return F
