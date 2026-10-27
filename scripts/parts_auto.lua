-- PARTS_AUTO — the auto-engineering parts: a moto wheel, a telescopic fork,
-- a swing arm, a coil-over strut, a balance gyro, a battery pack and a moto
-- saddle (docs/auto-engineering.md).
--
-- A data script on the AutoLib node (prefabs/AutoLib.prefab.ron, beside
-- scripts/auto_drive.lua), like parts_aero on the AeroLib node. The builder
-- reaches it with findScript("parts_auto") and calls `register(REG,
-- CATALOGUE)` once through parts_registry.extend: every entry joins the
-- registry as if it were written there, and the parts join the ROVER section
-- (renamed AUTO & ROVER) of the catalogue.
--
-- Entries are ordinary registry entries (parts_registry.lua REG) plus three
-- keys the builder's attach rules read (builder_attach nodesOf, the hub patch):
--
--   hubs    { { kind, p = {x,y,z}, n = {x,y,z} }, … } attach points in the
--           part's own frame:
--             "hub"  where a WHEEL is clamped centred (between a fork's legs,
--                    in a swing arm's jaws), axle along n — and, on a wheel,
--                    the centre a fork or arm clamps onto;
--             "end"  a face any part mounts on like a flank (a strut's hub
--                    flange, a through-axle's two ends)
--   hubpt, hubax   the point of THIS part that goes on another part's "hub"
--                  node, and its axle (a wheel: its tyre centre and its X; a
--                  fork or arm: its hub and its Z)
--   upright        a radial part that keeps its +Y on the build's up whatever
--                  it is mounted on (a fork on the end of a beam lying along
--                  the bike stands up, not on its side)
--   mountpt        the point of a radial part that sits on the face it is put
--                  on (the fork's head bracket, high on its box)
--
-- and two electronics modules the flight reads (vessel_controller, the moto
-- patch, through scripts/auto_drive.lua), so the blueprint carries them with
-- no new record keys:
--
--   susp    the suspension a wheel on this part rides: kind "fork" | "arm" |
--           "strut", travel (m), sag (share of the travel the craft's weight
--           sits it down), zeta (damping ratio), steer (1 steers, 0 never,
--           −1 the wheel's own rule: ahead of the centre of mass), the axis
--           (ax, ay, az; part frame, pointing up) the wheel slides on and
--           steers about, and the points its moving halves are drawn from
--   gyro    a balance gyro: torque (kN·m) and draw (EC/s at full effort)
--
-- FRAMES (tools/gen_auto_parts.py prints these; keep them in step):
--   the fork, swing arm and strut are radial parts, +X out of the face they
--   mount on: the fork on a FRONT face (+X ahead), the swing arm on a REAR
--   face (+X back), the strut on a flank (+X outboard); +Y up, Z across.

local DRIVE_B = { type = "drive", torque = 0.45, speed = 16.0, draw = 0.3, r = 0.33, centred = true }

PARTS = {
  -- MOTO WHEEL: a 0.33 m spoked wheel with a hub motor and a disc brake,
  -- centred on its own part: its axle runs right through (±0.11 m), so a fork
  -- or swing arm clamps it in the middle and either end takes another part (a
  -- strut each side, a fender, a beam). On a flank it mounts by an axle end.
  wheelB   = { prefab = "PartWheelB", label = "Moto Wheel", h = 0.66, rx = 0.11, rz = 0.33, mass = 0.05, cost = 35,
               top = false, bottom = false, radial_orient = true, kind = "structural", strength = 260, wheel = "B", travel = 0.04,
               hubpt = { 0, 0, 0 }, hubax = { 1, 0, 0 },
               hubs = { { kind = "hub", p = { 0, 0, 0 }, n = { 1, 0, 0 } },
                        { kind = "end", p = { 0.11, 0, 0 }, n = { 1, 0, 0 } },
                        { kind = "end", p = { -0.11, 0, 0 }, n = { -1, 0, 0 } } },
               mods = { DRIVE_B } },
  -- TELESCOPIC FORK: bolts to a FRONT face; a wheel clamps between its legs.
  -- It steers (A/D) about its raked head and rides 13 cm of travel; the
  -- handlebar turns with it.
  forkT    = { prefab = "PartForkT", label = "Telescopic Fork", h = 0.9588, rx = 0.4416, rz = 0.3585, mass = 0.03, cost = 40,
               top = false, bottom = false, radial_orient = true, upright = true, mountpt = { -0.4416, 0.3116, 0 },
               kind = "structural", strength = 300,
               hubpt = { 0.0606, -0.4067, 0 }, hubax = { 0, 0, 1 },
               hubs = { { kind = "hub", p = { 0.0606, -0.4067, 0 }, n = { 0, 0, 1 } } },
               mods = { { type = "susp", kind = "fork", travel = 0.13, sag = 0.33, zeta = 0.5, steer = 1,
                          ax = -0.4067, ay = 0.9135, az = 0, px = -0.2716, py = 0.2116, pz = 0 } } },
  -- SWING ARM: hinges off a REAR face; a wheel clamps in its jaws. A
  -- monoshock gives it 12 cm of travel; it never steers.
  swingArm = { prefab = "PartSwingArm", label = "Swing Arm", h = 0.3348, rx = 0.335, rz = 0.1505, mass = 0.025, cost = 25,
               top = false, bottom = false, radial_orient = true, upright = true, kind = "structural", strength = 300,
               hubpt = { 0.265, -0.1326, 0 }, hubax = { 0, 0, 1 },
               hubs = { { kind = "hub", p = { 0.265, -0.1326, 0 }, n = { 0, 0, 1 } } },
               mods = { { type = "susp", kind = "arm", travel = 0.12, sag = 0.33, zeta = 0.5, steer = 0,
                          ax = 0, ay = 1, az = 0, px = -0.285, py = -0.0626, pz = 0, len = 0.5544 } } },
  -- COIL-OVER STRUT: on a flank (a car's, a rover's), a wheel bolted to its
  -- hub flange. 18 cm of travel; a front strut steers about its own axis.
  strutS   = { prefab = "PartStrutS", label = "Coil-over Strut", h = 0.625, rx = 0.1235, rz = 0.13, mass = 0.04, cost = 30,
               top = false, bottom = false, radial_orient = true, upright = true, kind = "structural", strength = 420,
               hubs = { { kind = "end", p = { 0.1235, -0.2275, 0 }, n = { 1, 0, 0 } } },
               mods = { { type = "susp", kind = "strut", travel = 0.18, sag = 0.33, zeta = 0.5, steer = -1,
                          ax = 0, ay = 1, az = 0, sx = 0.0165, px = -0.0935, py = -0.2675, pz = 0, len = 0.15 } } },
  -- BALANCE GYRO: a flywheel that holds a two-wheeler up at a standstill and
  -- leans it into its turns. Anywhere on the craft.
  gyro     = { prefab = "PartGyro", label = "Balance Gyro", h = 0.355, rx = 0.2, rz = 0.1824, mass = 0.06, cost = 60,
               top = true, bottom = true, side = true, kind = "structural", strength = 400,
               mods = { { type = "gyro", torque = 1.5, draw = 0.4 } } },
  -- BATTERY PACK: a tank-shaped 200 EC pack, the power a bike's hub motors
  -- run on (a seat carries none). Stacks or sits on any face.
  packB    = { prefab = "PartPackB", label = "Battery Pack", h = 0.35, rx = 0.31, rz = 0.171, mass = 0.04, cost = 25,
               top = true, bottom = true, side = true, kind = "structural", power = true, ec = 200, strength = 300,
               mods = { { type = "battery", ec = 200 } } },
  -- MOTO SADDLE: a crew part, the open seat of a motorcycle (or a quad, a
  -- trike): a saddle and tank-tail shroud on a short subframe, faces +X. It
  -- stacks on a frame block, a beam or the pack by its mount cradle (the
  -- box's bottom; the box is the Command Seat's height, the rider's room:
  -- the crew is parked at its centre); its footpegs hang either side of
  -- whatever it is on. It
  -- commands like the Command Seat (`seat`: F to sit, the rider stays in
  -- view, a bike counts them as its rider) and scripts/command_seat.lua sits
  -- them astride it, feet on the pegs, hands on a fork's grips (the
  -- prefab's params; tools/gen_auto_parts.py moto_saddle).
  saddle   = { prefab = "PartSaddle", label = "Moto Saddle", h = 1.30, rx = 0.36, rz = 0.17, mass = 0.03, cost = 15,
               top = false, bottom = true, kind = "crewed", seat = true, strength = 260,
               mods = { { type = "command", crew = 1, draw = 0.0, seat = true } } },
}

DESC = {
  wheelB = "moto wheel · r 0.33 m · through-axle: parts on both ends",
  forkT = "telescopic fork · front face · steers A/D · 13 cm travel",
  swingArm = "swing arm · rear face · monoshock · 12 cm travel",
  strutS = "coil-over strut · on a flank · wheel on its flange · 18 cm",
  gyro = "balance gyro · holds a bike up · leans it into turns",
  packB = "battery pack · 200 EC · a bike's tank",
  saddle = "moto saddle · crew 1 · F to ride astride · faces +X",
}
for id, d in pairs(DESC) do if PARTS[id] then PARTS[id].desc = d end end

-- Where they go in the catalogue: after the rover's own parts.
SECTION = "ROVER"
ORDER = { "wheelB", "forkT", "swingArm", "strutS", "gyro", "packB", "saddle" }



-- parts_registry.extend calls this once.
function register(REG, CATALOGUE)
  local n = 0
  for _, id in ipairs(ORDER) do
    if not REG[id] then REG[id] = PARTS[id]; n = n + 1 end
  end
  local placed = false
  for _, sec in ipairs(CATALOGUE) do
    if sec[1] == SECTION then
      local have = {}
      for _, id in ipairs(sec[2]) do have[id] = true end
      for _, id in ipairs(ORDER) do if not have[id] then sec[2][#sec[2] + 1] = id end end
      placed = true
    end
  end
  if not placed then CATALOGUE[#CATALOGUE + 1] = { SECTION, ORDER } end
  return n
end
