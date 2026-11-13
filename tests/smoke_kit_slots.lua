-- smoke_kit_slots: PREBUILT BASES ARE ON THE PLAYER'S GRID, and a missing
-- piece has a slot (playtest 11-12b: "pre-built and abandoned bases must be
-- built on the same grid and snapping a player would use. Replacing one wall
-- today comes out misaligned").
--
--   1. THE AUDIT: every upright wall of every ruin grammar (all kinds, 12
--      seeds), the Hollis camp and the Graveyard and Dust Season stations is
--      a pose kit_snap.face() itself produces: aimed at the floor's edge
--      under it, at the top of the wall below it, or at the end of the wall
--      beside it. A wall typed off the grid fails here.
--   2. THE SLOTS: take any one wall out of a design, or any one roof panel:
--      kit_snap.slots() offers the exact place it stood (0.5 cm), when
--      something beside it still stands. So does a decayed ruin, for every
--      piece the decay took whose neighbours stand.
--   3. THE RAY: the slot the aim passes nearest wins; one behind the hit
--      point, or a metre off the ray, does not.
--
--   luajit solar/tests/smoke_kit_slots.lua        (from the Floptle repo root)
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e); f(); return e
end
local RU = loadlib("ruins.lua")
local KIT = loadlib("parts_kit.lua")
local PB = loadlib("parts_base.lua", { findScript = function(k) return k == "parts_kit" and KIT or nil end })
local KS = loadlib("kit_snap.lua")
local BPs = loadlib("blueprints.lua", {})
local defs = PB.partInfo
local function V(x, y, z) return { x = x, y = y, z = z } end
local function record(P, skip)
  local rec = { id = 1, x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = {} }
  for i, p in ipairs(P) do
    if not (skip and skip[i]) then
      rec.bp[#rec.bp + 1] = { uid = i, id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0, wr = p.wr }
    end
  end
  return rec
end
local function yawOff(a, b) local d = math.abs(KS.wrap(a - b)); return math.min(d, math.abs(d - math.pi)) end

-- ── 1. the audit ────────────────────────────────────────────────────────────
local function audit(P)
  local rec = record(P)
  local n, bad, what = 0, 0, {}
  for _, w in ipairs(rec.bp) do
    local d = defs(w.id)
    if d and d.kit and d.snap == "wall" and math.abs(w.pitch) < 1e-6 and math.abs(w.roll) < 1e-6 then
      n = n + 1
      local best = nil
      local function try(pose)
        if not pose then return end
        local e = math.sqrt((pose.lx - w.x) ^ 2 + (pose.ly - w.y) ^ 2 + (pose.lz - w.z) ^ 2) + yawOff(pose.yaw, w.yaw)
        if not best or e < best then best = e end
      end
      local nx, nz = math.sin(w.yaw), math.cos(w.yaw)
      for _, f in ipairs(rec.bp) do
        local fd = defs(f.id)
        local fc = fd and KS.classOf(fd)
        if fd and f ~= w and math.abs(f.pitch or 0) < 1e-6 then
          local fb = KS.boxOf(fd)
          local top = (f.y or 0) + (fd.deckTop or fb[4])
          if (fc == "floor" or fc == "slab") and math.abs(top - w.y) < 0.02 then
            for _, sg in ipairs({ 1, -1 }) do
              for _, along in ipairs({ 0, 0.6, -0.6 }) do
                local ax, az = w.x + nx * 0.3 * sg + nz * along, w.z + nz * 0.3 * sg - nx * along
                local c, s2 = math.cos(f.yaw or 0), math.sin(f.yaw or 0)
                local dx, dz = ax - f.x, az - f.z
                local px, pz = dx * c - dz * s2, dx * s2 + dz * c
                if px > fb[1] + 0.01 and px < fb[2] - 0.01 and pz > fb[5] + 0.01 and pz < fb[6] - 0.01 then
                  try(KS.face({ def = d, id = w.id, P = V(ax, top, az), N = V(0, 1, 0), toward = V(0, 0, 1), hit = { rec = rec, part = f }, defs = defs }))
                end
              end
            end
          elseif fc == "wall" and math.abs((f.y or 0) + fb[4] - w.y) < 0.02 and math.abs(f.x - w.x) + math.abs(f.z - w.z) < 2.1 then
            try(KS.face({ def = d, id = w.id, P = V(w.x, w.y, w.z), N = V(0, 1, 0), toward = V(0, 0, 1), hit = { rec = rec, part = f }, defs = defs }))
          elseif fc == "wall" and math.abs((f.y or 0) - w.y) < 0.02 then
            local c, s2 = math.cos(f.yaw or 0), math.sin(f.yaw or 0)
            for _, sg in ipairs({ 1, -1 }) do
              local ex, ez = f.x + (sg > 0 and fb[2] or fb[1]) * c, f.z - (sg > 0 and fb[2] or fb[1]) * s2
              if math.abs(ex - w.x) + math.abs(ez - w.z) < 2.6 then
                try(KS.face({ def = d, id = w.id, P = V(ex, w.y + 1.0, ez), N = V(sg * c, 0, -sg * s2), toward = V(0, 0, 1), hit = { rec = rec, part = f }, defs = defs }))
              end
            end
          end
        end
      end
      if not best or best > 0.011 then bad = bad + 1; what[#what + 1] = string.format("%s at %.2f, %.2f, %.2f", w.id, w.x, w.y, w.z) end
    end
  end
  return n, bad, what
end
local designs = {}
for _, k in ipairs(RU.kinds()) do
  for seed = 1, 12 do
    designs[#designs + 1] = { name = k .. "#" .. seed, site = { kind = k, co = 1 + seed % 5, seed = seed * 101 + 7, age = 600 + seed * 400, id = "X#" .. seed, body = "X", name = "Test" } }
    designs[#designs].P = RU.blueprintOf(designs[#designs].site)
  end
end
for _, f in ipairs({ "hollis/camp", "graveyard_shift/station", "dust_season/hab", "dust_season/shop", "dust_season/field", "dust_season/mast" }) do
  local fh = io.open("solar/scenarios/" .. f .. ".bp.txt")
  if fh then
    local code = fh:read("*a"); fh:close()
    local ok, bp = pcall(BPs.decode, code)
    check(ok and bp ~= nil, f .. ": its blueprint decodes")
    if ok and bp then designs[#designs + 1] = { name = f, P = bp.pieces } end
  end
end
local totalW, totalBad = 0, 0
for _, D in ipairs(designs) do
  local n, bad, what = audit(D.P)
  totalW, totalBad = totalW + n, totalBad + bad
  if bad > 0 then check(false, string.format("%s: %d of %d walls are off the player's snap (%s)", D.name, bad, n, table.concat(what, "; ", 1, math.min(3, #what)))) end
end
check(totalW > 1000 and totalBad == 0, string.format("every prebuilt wall is a pose the player's snap produces (%d walls in %d designs, %d off)", totalW, #designs, totalBad))

-- ── 2. the slots ────────────────────────────────────────────────────────────
local function has_slot(list, p, kind)
  for _, e in ipairs(list) do
    if e.kind == kind and math.abs(e.lx - p.x) < 0.005 and math.abs(e.ly - p.y) < 0.005 and math.abs(e.lz - p.z) < 0.005
       and (kind == "floor" and yawOff(e.yaw, p.yaw or 0) % (math.pi / 2) < 1e-3 or yawOff(e.yaw, p.yaw or 0) < 1e-3) then return true end
  end
  return false
end
local nW, okW, nR, okR, loneW, loneR = 0, 0, 0, 0, 0, 0
local miss = {}
for _, D in ipairs(designs) do
  if D.site and D.site.seed % 3 == 0 then     -- (a third of the seeds: the grammar, not the dice, is what is tested)
    for i, p in ipairs(D.P) do
      local d = defs(p.id)
      -- (walls and roof PANELS: a headframe's beams are not a roof to close)
      if d and d.kit and (p.rl == "wall" or p.rl == "roof") and (p.pitch or 0) == 0 and (d.snap == "wall" or (d.snap == "floor" and d.piece == "floor")) then
        local rec = record(D.P, { [i] = true })
        local list = KS.slots(rec, defs, d)
        local got = has_slot(list, p, d.snap)
        if d.snap == "wall" then
          -- (a ground-storey wall on a floor's edge; an upper wall stacks on the one below: face()'s own rule)
          local onFloor = false
          for _, f in ipairs(rec.bp) do
            local fd = defs(f.id)
            if fd and (KS.classOf(fd) == "floor" or KS.classOf(fd) == "slab") and math.abs((f.y or 0) + (fd.deckTop or KS.boxOf(fd)[4]) - p.y) < 0.02 then onFloor = true end
          end
          if onFloor then
            nW = nW + 1
            if got then okW = okW + 1 else loneW = loneW + 1; if #miss < 6 then miss[#miss + 1] = string.format("%s %s (%.1f, %.1f, %.1f)", D.name, p.id, p.x, p.y, p.z) end end
          end
        else
          nR = nR + 1
          if got then okR = okR + 1 else loneR = loneR + 1; if #miss < 6 then miss[#miss + 1] = string.format("%s %s (%.1f, %.1f, %.1f)", D.name, p.id, p.x, p.y, p.z) end end
        end
      end
    end
  end
end
check(nW > 100 and okW >= nW * 0.9, string.format("one wall taken out: its slot is offered in %d of %d cases (the rest stood alone: %d)", okW, nW, loneW) .. (#miss > 0 and (" e.g. " .. table.concat(miss, "; ")) or ""))
check(nR > 50 and okR >= nR * 0.95, string.format("one roof panel taken out: its slot is offered in %d of %d cases (%d not)", okR, nR, loneR) .. (#miss > 0 and (" e.g. " .. table.concat(miss, "; ")) or ""))
-- a decayed ruin: what the decay took, where neighbours stand
do
  local offered, gone, extra = 0, 0, 0
  for _, D in ipairs(designs) do
    if D.site and D.site.seed % 4 == 0 then
      local kept = RU.decay(D.P, D.site)
      local have = {}
      local rec = { id = 1, x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = {} }
      for k, e in ipairs(kept) do
        have[e.ri or 0] = true
        rec.bp[#rec.bp + 1] = { uid = k, id = e.id, x = e.x, y = e.y, z = e.z, yaw = e.yaw or 0, pitch = e.pitch or 0, roll = e.roll or 0, wr = e.wr }
      end
      local wl = KS.slots(rec, defs, defs("wall.steel"))
      local fl = KS.slots(rec, defs, defs("floor.steel"))
      for i, p in ipairs(D.P) do
        local d = defs(p.id)
        if not have[i] and d and d.kit and (p.rl == "wall" or p.rl == "roof") then
          gone = gone + 1
          if has_slot(d.snap == "wall" and wl or fl, p, d.snap) then offered = offered + 1 end
        end
      end
      -- every wall slot offered is on the design's own lines (a design wall stood there) or closes a real edge
      for _, e in ipairs(wl) do
        local on = false
        for _, p in ipairs(D.P) do if math.abs(p.x - e.lx) < 0.01 and math.abs(p.z - e.lz) < 0.01 then on = true end end
        if not on then extra = extra + 1 end
      end
    end
  end
  check(gone > 30 and offered >= gone * 0.6, string.format("decayed ruins: %d of the %d walls and roof panels the decay took have a slot at their exact place", offered, gone))
  print(string.format("  slots: decayed ruins offer %d of %d missing pieces; %d wall slots on edges the design left open", offered, gone, extra))
end

-- ── 3. the ray ──────────────────────────────────────────────────────────────
do
  local list = { { kind = "wall", lx = 0, ly = 0.2, lz = 5, yaw = 0, cx = 0, cy = 1.3, cz = 5 }, { kind = "wall", lx = 2, ly = 0.2, lz = 5, yaw = 0, cx = 2, cy = 1.3, cz = 5 } }
  local O = V(0.3, 1.7, 0)
  local function dir(x, y, z) local l = math.sqrt(x * x + y * y + z * z); return V(x / l, y / l, z / l) end
  local s1, t1, d1 = KS.slotOnRay(list, O, dir(0, -0.05, 1), 20)
  check(s1 == list[1] and t1 > 4.8 and d1 < 0.5, "the slot the aim passes nearest wins")
  local s2 = KS.slotOnRay(list, O, dir(0.34, -0.05, 1), 20)
  check(s2 == list[2], "...the other one when the aim turns to it")
  check(KS.slotOnRay(list, O, dir(0, -0.05, 1), 3.0) == nil, "a slot beyond what the ray hit first is not taken")
  check(KS.slotOnRay(list, O, dir(-0.5, 0, 1), 20) == nil, "a slot a metre and more off the ray is not taken")
  local Ol, Dl = KS.rayLocal({ x = 10, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }, 10.3, 1.7, 0, 0, 0, 1)
  check(math.abs(Ol.x - 0.3) < 1e-9 and math.abs(Ol.y - 1.7) < 1e-9 and math.abs(Dl.z - 1) < 1e-9, "a ray goes into the structure's frame")
end

if #failures > 0 then
  print("smoke_kit_slots FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print("smoke_kit_slots: " .. passed .. " passed")
