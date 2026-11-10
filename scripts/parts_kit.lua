-- PARTS_KIT — the modular structure kit: habs built from pieces (sandbox plan
-- S1, work/sandbox/PLAN.md §1; docs/base-building.md §13).
--
-- A pure data script on the Build Kit node (scenes/system.ron) beside
-- parts_base.lua; it loads from disk in a luajit test (tests/smoke_kit.lua).
-- parts_base.partInfo falls back to it, so every reader of a structure's parts
-- (structures, base_snap, field_builder, base_grid, base_shield) sees a piece
-- as one more part record.
--
-- ── WHAT A PIECE IS ─────────────────────────────────────────────────────────
-- 2 m modules on a 0.5 m grid (Ty, 11-06). A storey is 2.4 m floor to floor:
-- a 0.2 m floor, a 2.2 m wall (a 2.05 m door fits under a 0.15 m lintel), the
-- next floor on the walls' tops. Every piece is built in its own GROUND frame:
-- its ground point is the origin (the prefab's root is an Empty there, so
-- `seat` is 0), +Y up, +Z its front (a wall's outside), +X its right. `box` is
-- the nominal solid { x0, x1, y0, y1, z0, z1 } in that frame: what snapping,
-- support and overlap read (tools/gen_kit_parts.py builds the mesh and the
-- colliders to it; smoke_kit checks the generated bounds against it).
--
-- MATERIAL IS A PROPERTY, NOT A PART. One `wall` with mat ∈ { steel,
-- concrete, regocrete, glass }. A placed piece's id is "<piece>.<mat>"
-- ("wall.steel"): every reader that calls partInfo(p.id) gets that
-- material's mass, cost, prefab and shield. Mass = gross volume × density ×
-- the material's fill for that piece's class (a steel wall is a sandwich
-- panel: two 1.6 mm skins over a core, ~1.6 % of its gross volume; a glass
-- wall is a 20 mm pane in a 200 mm frame; concrete is solid). Price = the
-- piece's steel price × COSTK[mat] unless it names its own.
--
-- ── SNAP CLASSES (base_snap.face reads `snap`) ──────────────────────────────
--   slab    foundations: edge-to-edge tiles on the ground (`tile`, `deck`)
--   floor   horizontal panels: beside a floor, on a deck, on a wall's top
--   wall    vertical panels: on a floor's edge, along a wall's end, on its top,
--           square off its face
--   post    pillars, trusses, piers: on a top face (a corner if near one), on
--           a post's top
--   block   stairs, steps, ramps, blocks, fittings: on a top face, on the grid
--   mount   lights, screens, switches, trays: flush on any face
--   hab     the 2.5 m pressure can family: end to end along its Z, or on a deck
--
-- ── LIVE PIECES (sandbox plan S2; scripts/kit_live.lua) ─────────────────────
--   door    = { slide = { x, y, z } (m, piece frame), secs, near }  a child
--             "Door" (its mesh and its own collider box) slides open as crew
--             come near and shut behind them (a Collidable moved by a script:
--             its collider follows; engine docs/scripting/physics.md)
--   light   = { color, intensity, range, draw }  a child "Light": a pooled
--             point light (the 16 nearest the crew), on/off in the part state
--   screen  = { w, h }  a child "Screen": the base's status, redrawn every 2 s
--   switch  = true      toggles every light of its structure
-- FITTINGS are VAB parts (pods, seats, lockers, lights, batteries, panels):
-- `live = true`; they are not drawn by structures.lua but by struct_live.lua,
-- as one anchored structure vessel per structure.
--
-- ── SEAMS FOR LATER STEPS ───────────────────────────────────────────────────
--   seals   the faces a piece closes for S3's room flood fill: "z" (across a
--           wall's thickness), "y" (a floor's), "ring" (a hab can's), "door"
--           (sealed when shut), nil = never (open frames, vents, rails)
--   u, k    the material's heat leak (S3 room heat) and radiation share (by
--           record, thermal.shieldFactor: concrete walls shield)
--
-- ── ROOMS AND AIR (S3; scripts/rooms.lua, scripts/room_air.lua) ─────────────
--   seals   is read by the flood fill (above)
--   door.airlock   an Airlock Wall: the small room it closes with a second
--           door is an airlock (interlocked, cycled)
--   life    LIFE SUPPORT, run from the base grid (`use` = its load, EC/s):
--           { o2 = atm·m³ of O2 a second }   the O2 Generator
--           { scrub = atm·m³ of CO2 a second }   the CO2 Scrubber
--           { store = atm·m³, flow = atm·m³/s, price = $ a m³ }   the Air Tank
--           Rack (a regulator: no power)
--
-- ── MIRROR (G; field_builder.mirrorPose) ────────────────────────────────────
--   sym     which of its own planes a piece is symmetric in: "x" (default:
--           left and right alike: a wall, a floor), "z" (front and back alike,
--           its left and right not: a gable, an airlock wall, a pod with its
--           hatch on one side). A mirror reflects about the structure's plane;
--           a piece symmetric in one of its own planes IS that reflection,
--           turned (yaw, pitch, roll worked out in field_builder.mirrorPose).
--   mirror  a piece symmetric in neither (the Door Wall: its door at one end,
--           its lamp outside) is placed as its MIRRORED VARIANT, a hidden
--           piece of its own built reflected (tools/gen_kit_parts.py)

--
-- ── CHARACTER (S4; tools/gen_kit_props.py, scripts/kit_paint.lua) ───────────
--   PROPS   furniture, storage, machines' dressing, lamps: `prop` snap (on a
--           top face on a 0.25 m grid, square toward you; beside one of its
--           kind), or `mount` for what hangs on a wall. `clutter` = no
--           collider (small things the crew walks past); the rest have a box.
--   DECALS  thin quads on a face (`mount`, material "film", `film` = they
--           overlap nothing and nothing blocks them): hazard stripes,
--           numbers, arrows, placards, supplier marks, grime. `sign` pieces
--           carry text kit_live draws (img:text in the project's fonts; the
--           base's name until the player writes their own); `emblem` the
--           agency's emblem. T turns any mount on its face (kit_snap.spinPose).
--   faces2  a two-faced piece (a wall, a hab can): its "MeshIn" child is its
--           inside, painted apart (kit_paint `paintIn`)
--   exterior  dust gathers on it with age (structural sections only)
--
-- ── POWER (S5; scripts/base_power.lua, docs/base-building.md §16) ───────────
--   power   = { kind = "breaker", amps }   guards the cables plugged into it
--             (trips past its rating); with none, its structure's main
--           = { kind = "xfmr", kva, p0, pk, z }   400 V ↔ 11 kV: the HV cable
--             lands on it; it loses p0 kW always and pk at its full rating
--   netgear a pole, a junction, a breaker or a transformer: a cable to it may
--           close a loop or double a line (base_cable's rule)
--   pole    the cable leaves its crossarm (`cableAt` m up) and is strung tight
--   cableAt where a cable leaves the piece, m over its ground point
--
-- ── NUCLEAR (S6; scripts/reactor.lua, reactor_plant.lua; docs/heat-and-nuclear.md §8)
-- A reactor is a LAYOUT, not a part. Columns stand on a Reactor Vessel Base's
-- top, one to a 0.5 m cell (its 5 × 5 lattice), and the cells next to each
-- other decide the neutronics; pipes and components join by their PORTS.
--   nuclear = { role = "vessel" | "fuel" | "mod" | "rod", mod = "graphite" |
--             "water" | "heavy", rods = n (a fuel channel's slots) }
--   ports   = { { name, x, z, nx, nz, loop } }  piece-frame nozzles, all at
--             PIPE_Y over the ground point, on the 0.5 m grid; ports of one
--             piece with the same `loop` tag are joined inside it (a steam
--             generator's primary side and its secondary side are not)
--   pipe    = { len, loss, lagged }  m of run; the share of the plant's rated
--             heat a metre loses to the room at its design temperature (bare
--             0.25 %, lagged 0.004 %); a fitting between lagged runs is lagged
--   pump    = { flow, kw }  kg/s at its rating and its motor's kW (a grid load)
--   press   = { kw, tsat }  a pressuriser: heaters' kW, the loop's boiling point (K)
--   hx      = { ua }        a steam generator's kW/K
--   turbine = { kwe, eta, qmax, min }  rated kW(e), its share of the Carnot
--             limit, the most heat it admits (kW), the least it spins on
--   reject  = { kind = "rad", area, eps } | { kind = "tower", g, kw }  the
--             secondary loop's heat sink (radiators work anywhere, a tower
--             only in air)
--   console = { w, h }      the control desk's screen (reactor_plant paints it)
--   power   = { kind = "aux", use } a pump, heater or fan the plant runs from
--             the grid; { kind = "plant", kwe } the turbine's generator
--   tech    research that opens the piece (research.lua)
--
-- -- FLUID (S7; scripts/fluids.lua, fluid_net.lua; docs/base-building.md §17)
--   fl      = { kind = "pipe" (len, bore) | "tank" (sub, V, A) | "bottle" (sub,
--             V, pmax) | "pump" (q0 kg/s free, H0 Pa shut-off, kw) | "valve" |
--             "check" | "reg" (pset) | "gauge" | "outlet" | "vent" |
--             "consumer" (sub, V, A) }: a piece of the fluid network
--   ports   as NUCLEAR's, at `y` (default PIPE_Y) over the ground point; on a
--           piece without `fl`, a port with `fluid = true` is the network's
--           (`role` = "consumer" an O2 Generator's water, "h2" its hydrogen,
--           "primary" a pressuriser's makeup nozzle into its reactor's loop)
--   eqv     = { C = m3/s per atm }  an Equalise Valve through its wall
--   door.eq a door's own equalising valve (m3/s per atm); door.seal its seal's
--           strength against forcing (0 weak ... 1 never damaged)
--
-- ── LOGIC (S8; scripts/logic.lua, logic_net.lua; docs/base-building.md §18) ─
--   lg      = { kind, pins = { { n, io = "in" | "out", x, y, z } … }, … }  what
--           a piece is to the signals: a sensor (`sense`, its setpoint `set`,
--           `mode` above | below, hysteresis `hys`, `step`, `unit`), a gate
--           (and, or, xor, not, timer, latch, cmp, counter), an input
--           (button, lever, keypad), an output (lamp, alarm), a radio (tx,
--           rx; channel `ch`), the ladder controller (plc), or an existing
--           piece's terminals (kind "device", `dev` = door, airlock, light,
--           pump, valve, breaker, rxpump, rxconsole, machine). Pins are in
--           the piece's frame: where a Signal Cable is made off.
--   wire    the Signal Cable's drum (laid pin to pin by logic_net and settled
--           the way base_cable settles a power cable): { max m, kgm, perm $/m, r m }
PIPE_Y = 0.6
--
-- ── AIR AND SURVEY (expansion X1/X2) ────────────────────────────────────────
--   life.n2   the N2 Compressor: atm·m³/s of the outside's inert gas fed to the
--             room as makeup (room_air: needs power and outside air)
--   life.o2c  the O2 Concentrator: atm·m³/s of O2 made from the outside air
--   survey    a SCIENCE instrument (scripts/survey.lua): { kind = "telescope",
--             ap (aperture, m), crew (a Scientist must run it) } or
--             { kind = "station" } (the Survey Station: weather, seismometer,
--             magnetometer; fills its body's layers while it stands there)

SECTION_ORDER = { "FOUNDATION", "FLOOR", "WALL", "ROOF", "FRAME", "HAB", "SHIELD", "UTILITY", "POWER", "LIFE", "FLUID", "LOGISTICS", "LOGIC", "NUCLEAR", "SCIENCE", "FITTINGS", "PROPS", "DECALS" }
EXTERIOR = { FOUNDATION = true, FLOOR = true, WALL = true, ROOF = true, FRAME = true, HAB = true, SHIELD = true }
FACES2 = { wall = true, halfWall = true, wall12 = true, doorWall = true, doorWallM = true, doubleDoor = true, windowWall = true,
           porthole = true, airlockWall = true, openFrame = true, ventWall = true, leadWall = true, gable = true,
           habSeg = true, habWindow = true }

MATS = {
  steel     = { label = "Steel", kgm3 = 7850, strength = 180, k = 0.9, u = 1.4, seal = true,
                desc = "sandwich panel · light, strong, quick" },
  concrete  = { label = "Concrete", kgm3 = 2300, strength = 400, k = 0.35, u = 0.6, seal = true,
                desc = "precast · heavy, cheap, shields" },
  regocrete = { label = "Regocrete", kgm3 = 2000, strength = 320, k = 0.40, u = 0.7, seal = true, offworld = true,
                desc = "regolith concrete mixed on site · the cheapest wall there is" },
  glass     = { label = "Glass", kgm3 = 2500, strength = 60, k = 0.95, u = 2.8, seal = true, blend = true,
                desc = "laminated pane in a steel frame · light comes in" },
  -- (S6: reactor-grade graphite, the moderator column's own; not in MAT_ORDER)
  graphite  = { label = "Graphite", kgm3 = 1700, strength = 30, k = 0.6, u = 1.0, seal = false,
                desc = "nuclear-grade graphite bricks" },
  -- (S4: a decal's own "material": a film of paint, nothing structural)
  film      = { label = "Paint", kgm3 = 1200, strength = 1, k = 1.0, u = 0, seal = false,
                desc = "a film of paint on a face" },
}
MAT_ORDER = { "steel", "concrete", "regocrete", "glass" }
COSTK = { steel = 1.0, concrete = 0.58, regocrete = 0.47, glass = 1.5 }
-- what share of a piece's gross volume is the material, by class
FILL = {
  panel = { steel = 0.016, concrete = 1.0, regocrete = 1.0, glass = 0.1 },
  floor = { steel = 0.019, concrete = 1.0, regocrete = 1.0, glass = 0.12 },
  roof  = { steel = 0.017, glass = 0.1 },
  solid = { steel = 1.0, concrete = 1.0, regocrete = 1.0 },
  frame = { steel = 0.1, concrete = 1.0, regocrete = 1.0 },
  truss = { steel = 0.0306 },
}

local function B(x0, x1, y0, y1, z0, z1) return { x0, x1, y0, y1, z0, z1 } end
local WT, WH = 0.2, 2.2         -- a wall's thickness and height

-- name → piece. `mats` lists the materials it comes in (first = default);
-- `vol` its gross m³; `fill` the FILL class; `cost` the steel price ($).
PIECES = {
  -- ── FOUNDATION ──
  slab2     = { label = "Slab 2 × 2", section = "FOUNDATION", snap = "slab", box = B(-1, 1, -0.10, 0.20, -1, 1),
                mats = { "concrete", "regocrete" }, vol = 1.2, fill = "solid", cost = 520, tile = 2.0, deck = 0.20,
                grade = 1.6, footPad = 0.15, skirt = 0.10, seals = "y",
                desc = "2 x 2 m precast slab, 0.3 m · tiles edge to edge · build on it" },
  pier      = { label = "Footing Pier", section = "FOUNDATION", snap = "post", box = B(-0.25, 0.25, 0, 1.5, -0.25, 0.25),
                mats = { "concrete", "steel" }, vol = 0.375, fill = "frame", cost = 800, grade = 1.0,
                fillk = { steel = 0.27 },
                desc = "0.5 m square pier, 1.5 m · stands a deck off rough ground" },
  ramp      = { label = "Ramp 2 × 4", section = "FOUNDATION", snap = "block", box = B(-1, 1, 0, 0.5, -2, 2),
                mats = { "concrete", "steel" }, vol = 2.0, fill = "solid", cost = 1300, fillk = { steel = 0.03 },
                desc = "2 m wide, 4 m long, rises 0.5 m · wheels roll up it" },
  stairs    = { label = "Stairs (one storey)", section = "FOUNDATION", snap = "block", box = B(-0.9, 0.9, 0, 2.4, -1.8, 1.8),
                mats = { "steel", "concrete" }, vol = 2.6, fill = "solid", cost = 950, fillk = { steel = 0.017, concrete = 0.36 },
                desc = "a 2.4 m flight · 12 risers of 0.2 m · handrails" },
  steps     = { label = "Steps 0.8 m", section = "FOUNDATION", snap = "block", box = B(-0.7, 0.7, 0, 0.8, -0.5, 0.5),
                mats = { "steel", "concrete" }, vol = 0.56, fill = "solid", cost = 260, fillk = { steel = 0.02, concrete = 0.5 },
                desc = "four 0.2 m risers · up to a hab's deck or a raised door" },
  ladder    = { label = "Ship's Ladder", section = "FOUNDATION", snap = "block", box = B(-0.45, 0.45, 0, 2.4, -1.1, 1.1),
                mats = { "steel" }, vol = 0.6, fill = "solid", cost = 380, fillk = { steel = 0.017 },
                desc = "a steep 47° stair-ladder, one storey · rails both sides" },
  grating   = { label = "Grating Deck 2 × 2", section = "FOUNDATION", snap = "floor", box = B(-1, 1, 0, 0.1, -1, 1),
                mats = { "steel" }, vol = 0.4, fill = "solid", cost = 520, fillk = { steel = 0.035 },
                desc = "open steel grating · light, drains, lets dust through" },
  -- ── FLOOR ──
  floor     = { label = "Floor 2 × 2", section = "FLOOR", snap = "floor", box = B(-1, 1, 0, 0.2, -1, 1),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.8, fill = "floor", cost = 480, seals = "y",
                desc = "2 x 2 m deck panel · also the ceiling and a flat roof" },
  floor21   = { label = "Floor 2 × 1", section = "FLOOR", snap = "floor", box = B(-1, 1, 0, 0.2, -0.5, 0.5),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.4, fill = "floor", cost = 260, seals = "y",
                desc = "half a module · strips, landings" },
  floor11   = { label = "Floor 1 × 1", section = "FLOOR", snap = "floor", box = B(-0.5, 0.5, 0, 0.2, -0.5, 0.5),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.2, fill = "floor", cost = 140, seals = "y",
                desc = "a quarter module · infill" },
  floorHatch = { label = "Hatch Floor 2 × 2", section = "FLOOR", snap = "floor", box = B(-1, 1, 0, 0.2, -1, 1),
                mats = { "steel", "concrete" }, vol = 0.8, fill = "floor", cost = 900, seals = "door",
                door = { slide = { 0.95, 0, 0 }, secs = 1.2, near = 1.6, vertical = 2.6 }, sym = "z",
                desc = "a floor with a 0.9 m deck hatch · slides open as you come near" },
  pressHatch = { label = "Pressure Hatch Floor 2 × 2", section = "FLOOR", snap = "floor", box = B(-1, 1, 0, 0.2, -1, 1),
                mats = { "steel" }, vol = 0.8, fill = "floor", cost = 2800, fillk = { steel = 0.04 }, seals = "door",
                door = { slide = { 0.95, 0, 0 }, secs = 2.2, near = 1.6, vertical = 2.6, heavy = true, eq = 0.4, seal = 0.4 }, sym = "z",
                desc = "a floor with a heavy 0.9 m pressure hatch and its equalising valve · storeys of a station sealed apart" },
  -- ── WALL ──
  wall      = { label = "Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.88, fill = "panel", cost = 600, seals = "z",
                desc = "2 x 2.2 m wall panel" },
  halfWall  = { label = "Half Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, 1.1, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.44, fill = "panel", cost = 340, seals = "z",
                desc = "2 x 1.1 m · parapets, counters, a knee wall under a window" },
  wall12    = { label = "Wall 1 m", section = "WALL", snap = "wall", box = B(-0.5, 0.5, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.44, fill = "panel", cost = 340, seals = "z",
                desc = "1 x 2.2 m · closes an odd metre" },
  doorWall  = { label = "Door Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete" }, vol = 0.88, fill = "panel", cost = 1100, seals = "door",
                door = { slide = { 0.92, 0, 0 }, secs = 1.0, near = 2.2 }, mirror = "doorWallM",
                desc = "0.9 x 2.05 m pocket door · opens as you come near" },
  -- (its mirrored variant: the door at the other end; G places it, the column doesn't list it)
  doorWallM = { label = "Door Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete" }, vol = 0.88, fill = "panel", cost = 1100, seals = "door",
                door = { slide = { -0.92, 0, 0 }, secs = 1.0, near = 2.2 }, mirror = "doorWall", hidden = true,
                desc = "0.9 x 2.05 m pocket door, handed the other way · opens as you come near" },
  doubleDoor = { label = "Double Door Wall", section = "WALL", snap = "wall", box = B(-2, 2, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete" }, vol = 1.76, fill = "panel", cost = 2000, seals = "door",
                door = { slide = { 0.9, 0, 0 }, pair = true, secs = 1.3, near = 3.0 },
                desc = "4 m wall · 1.8 m opening, two pocket leaves · a rover fits a bike through" },
  windowWall = { label = "Window Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete" }, vol = 0.88, fill = "panel", cost = 900, seals = "z",
                desc = "1.2 x 1.0 m double-glazed pane, sill at 0.9 m" },
  porthole  = { label = "Porthole Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete" }, vol = 0.88, fill = "panel", cost = 800, seals = "z",
                desc = "a 0.5 m pressure porthole at eye height" },
  airlockWall = { label = "Airlock Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete" }, vol = 0.88, fill = "panel", cost = 3800, seals = "door",
                door = { slide = { 0.94, 0, 0 }, secs = 2.4, near = 2.0, heavy = true, airlock = true }, sym = "z",
                power = { kind = "aux", use = 2.5 },
                desc = "a pressure door · with a second door it makes an airlock: interlocked, its pump (2.5 kW from the base grid) cycles it" },
  bulkhead  = { label = "Pressure Bulkhead", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel" }, vol = 0.88, fill = "panel", cost = 4600, fillk = { steel = 0.05 }, seals = "door",
                door = { slide = { 0.94, 0, 0 }, secs = 2.8, near = 2.0, heavy = true, eq = 0.5, seal = 0.4 }, sym = "z",
                desc = "a station bulkhead: a heavy hatch door with its own equalising valve and a stronger seal · held shut by pressure like any door" },
  openFrame = { label = "Open Frame", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel", "concrete", "regocrete" }, vol = 0.88, fill = "panel", cost = 380,
                fillk = { steel = 0.006, concrete = 0.3, regocrete = 0.3 },
                desc = "a 1.8 x 2.05 m doorway with no door" },
  ventWall  = { label = "Vent Louvre Wall", section = "WALL", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel" }, vol = 0.88, fill = "panel", cost = 700,
                desc = "a wall with a 1 m louvre · lets air through by design" },
  cornerPost = { label = "Corner Post", section = "WALL", snap = "post", box = B(-0.1, 0.1, 0, WH, -0.1, 0.1),
                mats = { "steel", "concrete" }, vol = 0.088, fill = "frame", cost = 90,
                desc = "0.2 m square post · finishes a corner" },
  -- ── ROOF ──
  roofPitch = { label = "Pitched Roof 2 × 2", section = "ROOF", snap = "floor", box = B(-1, 1, 0, 1.155, -1, 1), slopeZ = 1.155,
                mats = { "steel", "glass" }, vol = 0.92, fill = "roof", cost = 420, seals = "y",
                desc = "a 30° panel, rising 1.15 m to its back edge · glass makes a skylight" },
  roofRidge = { label = "Roof Ridge", section = "ROOF", snap = "mount", box = B(-1, 1, 0, 0.16, -0.18, 0.18),
                mats = { "steel" }, vol = 0.1, fill = "solid", cost = 120, fillk = { steel = 0.03 },
                desc = "a ridge cap for two pitched panels back to back" },
  gable     = { label = "Gable 2 m", section = "ROOF", snap = "wall", box = B(-1, 1, 0, 1.155, -WT / 2, WT / 2), triangle = true,
                mats = { "steel", "concrete", "regocrete", "glass" }, vol = 0.23, fill = "panel", cost = 300, seals = "z", sym = "z",
                desc = "the triangle under a pitched roof's end · high at its right" },
  -- ── FRAME ──
  pillar2   = { label = "Pillar 2.2 m", section = "FRAME", snap = "post", box = B(-0.15, 0.15, 0, 2.2, -0.15, 0.15),
                mats = { "steel", "concrete" }, vol = 0.198, fill = "frame", cost = 240,
                desc = "0.3 m square column, one storey" },
  pillar4   = { label = "Pillar 4.4 m", section = "FRAME", snap = "post", box = B(-0.15, 0.15, 0, 4.4, -0.15, 0.15),
                mats = { "steel", "concrete" }, vol = 0.396, fill = "frame", cost = 440,
                desc = "0.3 m square column, two storeys" },
  beam2     = { label = "Beam 2 m", section = "FRAME", snap = "floor", box = B(-1, 1, 0, 0.4, -0.1, 0.1),
                mats = { "steel" }, vol = 0.16, fill = "frame", cost = 210, fillk = { steel = 0.08 },
                desc = "an I-beam, 0.4 m deep" },
  beam4     = { label = "Beam 4 m", section = "FRAME", snap = "floor", box = B(-2, 2, 0, 0.4, -0.1, 0.1),
                mats = { "steel" }, vol = 0.32, fill = "frame", cost = 380, fillk = { steel = 0.08 },
                desc = "an I-beam, 0.4 m deep · spans a 4 m room" },
  truss2    = { label = "Truss 2 m", section = "FRAME", snap = "post", box = B(-0.25, 0.25, 0, 2, -0.25, 0.25),
                mats = { "steel" }, vol = 0.5, fill = "truss", cost = 280,
                desc = "0.5 m open lattice · Shift+R lays it down" },
  truss4    = { label = "Truss 4 m", section = "FRAME", snap = "post", box = B(-0.25, 0.25, 0, 4, -0.25, 0.25),
                mats = { "steel" }, vol = 1.0, fill = "truss", cost = 500,
                desc = "0.5 m open lattice, 4 m" },
  truss6    = { label = "Truss 6 m", section = "FRAME", snap = "post", box = B(-0.25, 0.25, 0, 6, -0.25, 0.25),
                mats = { "steel" }, vol = 1.5, fill = "truss", cost = 700,
                desc = "0.5 m open lattice, 6 m · masts and spans" },
  trussNode = { label = "Truss Node", section = "FRAME", snap = "post", box = B(-0.25, 0.25, 0, 0.5, -0.25, 0.25),
                mats = { "steel" }, vol = 0.125, fill = "truss", cost = 160, fillk = { steel = 0.07 },
                desc = "a six-way node for lattice corners" },
  catwalk   = { label = "Catwalk 1 × 2", section = "FRAME", snap = "floor", box = B(-0.5, 0.5, 0, 1.15, -1, 1),
                mats = { "steel" }, vol = 0.2, fill = "solid", cost = 360, fillk = { steel = 0.07 },
                deckTop = 0.08,
                desc = "a 1 m grating walkway with handrails" },
  rail      = { label = "Handrail 2 m", section = "FRAME", snap = "wall", box = B(-1, 1, 0, 1.1, -0.04, 0.04),
                mats = { "steel" }, vol = 0.18, fill = "solid", cost = 90, fillk = { steel = 0.02 },
                desc = "a 1.1 m guard rail for a deck's edge" },
  -- ── HAB (the 2.5 m pressure can; along its Z) ──
  habSeg    = { label = "Hab Segment", section = "HAB", snap = "hab", box = B(-1.35, 1.35, 0, 2.9, -1, 1),
                mats = { "steel" }, vol = 1.0, fill = "solid", cost = 4200, fillk = { steel = 0.1146 }, seals = "ring",
                deckTop = 0.80,
                desc = "2.5 m pressure can, 2 m long, on its saddles · a deck inside" },
  habWindow = { label = "Hab Window Segment", section = "HAB", snap = "hab", box = B(-1.35, 1.35, 0, 2.9, -1, 1),
                mats = { "steel" }, vol = 1.0, fill = "solid", cost = 5600, fillk = { steel = 0.1401 }, seals = "ring",
                deckTop = 0.80,
                desc = "a hab segment with two windows" },
  habCap    = { label = "Hab End Cap", section = "HAB", snap = "hab", box = B(-1.35, 1.35, 0, 2.9, -0.35, 0.35),
                mats = { "steel" }, vol = 0.35, fill = "solid", cost = 1800, fillk = { steel = 0.1456 }, seals = "ring",
                desc = "a closed dome for a can's end" },
  habBulkhead = { label = "Hab Door Bulkhead", section = "HAB", snap = "hab", box = B(-1.35, 1.35, 0, 2.9, -0.2, 0.2),
                mats = { "steel" }, vol = 0.2, fill = "solid", cost = 2600, fillk = { steel = 0.2548 }, seals = "door",
                door = { slide = { 0.86, 0, 0 }, secs = 1.6, near = 2.2, heavy = true }, sym = "z",
                desc = "a flat end with a 0.8 x 1.8 m door at deck level (Steps 0.8 m reach it)" },
  -- ── SHIELD ──
  shieldBlock = { label = "Shield Block 1 × 1", section = "SHIELD", snap = "block", box = B(-0.5, 0.5, 0, 1, -0.25, 0.25),
                mats = { "concrete", "regocrete" }, vol = 0.5, fill = "solid", cost = 480, shieldk = 0.05,
                desc = "1 x 1 x 0.5 m shielding block · stacks" },
  leadWall  = { label = "Lead-lined Wall", section = "SHIELD", snap = "wall", box = B(-1, 1, 0, WH, -WT / 2, WT / 2),
                mats = { "steel" }, vol = 0.88, fill = "panel", cost = 2400, mass = { steel = 0.95 }, shieldk = 0.1, seals = "z",
                desc = "a steel wall with 20 mm of lead · lets 10 % of a dose through" },
  -- ── UTILITY ──
  lightFitting = { label = "Light Fitting", section = "UTILITY", snap = "mount", box = B(-0.3, 0.3, 0, 0.09, -0.12, 0.12),
                mats = { "steel" }, vol = 0.013, fill = "solid", cost = 60, fillk = { steel = 0.1 },
                light = { color = { 1.0, 0.91, 0.79 }, intensity = 2.4, range = 9, draw = 0.03 },
                desc = "a 4,300 K strip light, neutral white · right-click switches it · draws 0.03 EC/s" },
  switchPlate = { label = "Switch Plate", section = "UTILITY", snap = "mount", box = B(-0.06, 0.06, 0, 0.03, -0.09, 0.09),
                mats = { "steel" }, vol = 0.0006, fill = "solid", cost = 25, switch = true,
                desc = "switches every light of its structure" },
  wallScreen = { label = "Wall Screen", section = "UTILITY", snap = "mount", box = B(-0.45, 0.45, 0, 0.05, -0.28, 0.28),
                mats = { "steel" }, vol = 0.025, fill = "solid", cost = 400, fillk = { steel = 0.06 },
                screen = { w = 0.8, h = 0.48 },
                desc = "a status screen · the base grid, battery, crew and alerts" },
  wallTray  = { label = "Wall Cable Tray", section = "UTILITY", snap = "mount", box = B(-1, 1, 0, 0.1, -0.1, 0.1),
                mats = { "steel" }, vol = 0.04, fill = "solid", cost = 45, fillk = { steel = 0.04 },
                desc = "2 m perforated tray with its cables" },
  floorDuct = { label = "Floor Duct", section = "UTILITY", snap = "block", box = B(-1, 1, 0, 0.12, -0.2, 0.2),
                mats = { "steel" }, vol = 0.096, fill = "solid", cost = 70, fillk = { steel = 0.03 },
                desc = "2 m covered duct for cable and pipe along a floor" },
  -- ── POWER (S5: scripts/base_power.lua; the base grid's network) ──
  breaker63 = { label = "Breaker Panel 63 A", section = "POWER", snap = "mount", box = B(-0.2, 0.2, 0, 0.14, -0.3, 0.25),
                mats = { "steel" }, vol = 0.028, fill = "solid", mass = { steel = 0.014 }, cost = 180, netgear = true,
                power = { kind = "breaker", amps = 63 }, lens = true,
                desc = "a wall-hung breaker · guards the cables plugged into it: trips past 63 A (25 kW) · with none, its structure's main" },
  breaker160 = { label = "Breaker Panel 160 A", section = "POWER", snap = "mount", box = B(-0.28, 0.28, 0, 0.19, -0.41, 0.36),
                mats = { "steel" }, vol = 0.08, fill = "solid", mass = { steel = 0.032 }, cost = 420, netgear = true,
                power = { kind = "breaker", amps = 160 }, lens = true,
                desc = "a heavy breaker · trips past 160 A (64 kW) · guards its cables, or its structure's loads" },
  transformer = { label = "Transformer 100 kVA", section = "POWER", snap = "block", box = B(-0.72, 0.72, 0, 1.66, -0.56, 0.56),
                mats = { "steel" }, vol = 1.6, fill = "solid", mass = { steel = 0.8 }, cost = 2400, netgear = true, cableAt = 1.62,
                power = { kind = "xfmr", kva = 100, p0 = 0.25, pk = 1.6, z = 0.04 },
                desc = "400 V ↔ 11 kV, 100 kVA · the HV Cable lands on it · loses 0.25 kW always, 1.6 kW at full load · 0.8 t" },
  powerPole = { label = "Power Pole 8 m", section = "POWER", snap = "post", box = B(-0.7, 0.7, 0, 8.04, -0.22, 0.22),
                mats = { "steel", "concrete" }, vol = 0.4, fill = "solid", mass = { steel = 0.24, concrete = 0.95 },
                costs = { steel = 650, concrete = 480 }, cost = 650, netgear = true, pole = true, cableAt = 7.7,
                desc = "an 8 m pole with a crossarm · a cable made off at it is strung tight overhead · carry a line over a road or a crater" },
  junctionBox = { label = "Junction Box", section = "POWER", snap = "block", box = B(-0.32, 0.32, 0, 1.0, -0.24, 0.2),
                mats = { "steel" }, vol = 0.17, fill = "solid", mass = { steel = 0.045 }, cost = 150, netgear = true, cableAt = 0.5,
                desc = "a feeder pillar · splits a line three ways, or splices two runs into one longer one" },
  -- ── LIFE (S3: a room's air, scripts/room_air.lua; on the base grid) ──
  -- rates in atm·m³ a second: a crew member breathes 6.8e-6 of O2 and makes
  -- 5.85e-6 of CO2 (0.84 and 1.0 kg a day); each machine serves four.
  scrubber  = { label = "CO2 Scrubber", section = "LIFE", snap = "block", box = B(-0.35, 0.35, 0, 1.4, -0.25, 0.25),
                mats = { "steel" }, vol = 0.49, fill = "solid", cost = 2600, fillk = { steel = 0.022 },
                life = { scrub = 2.4e-5 }, use = 0.4,
                desc = "amine-bed CO2 scrubber for four crew · 0.4 EC/s from the base grid" },
  o2gen     = { label = "Oxygen Generator", section = "LIFE", snap = "block", box = B(-0.45, 0.45, 0, 1.6, -0.3, 0.3),
                mats = { "steel" }, vol = 0.86, fill = "solid", cost = 5200, fillk = { steel = 0.03 },
                life = { o2 = 2.8e-5, water = 20 }, use = 1.5,
                -- (S7) its 20 L water cell is fed by a pipe (fluids); its hydrogen goes to a bottle or is vented
                ports = { { name = "water", x = 0.2, y = 0.6, z = -0.3, nx = 0, nz = -1, fluid = true, role = "consumer", loop = "w" },
                          { name = "h2", x = -0.2, y = 0.6, z = -0.3, nx = 0, nz = -1, fluid = true, role = "h2", loop = "h" } },
                desc = "an electrolyser: O2 for four crew from water (2 H2O → 2 H2 + O2) · pipe water to its back · 1.5 EC/s from the base grid" },
  airTank   = { label = "Air Tank Rack", section = "LIFE", snap = "block", box = B(-0.6, 0.6, 0, 1.8, -0.25, 0.25),
                mats = { "steel" }, vol = 1.08, fill = "solid", cost = 1800, fillk = { steel = 0.04 },
                life = { store = 60, flow = 0.25, price = 4 },
                desc = "three 200 bar cylinders of air on a regulator · fills a room to 1 atm · 60 m³" },
  -- (X2: the outside's air as the room's, scripts/room_air.lua)
  n2comp    = { label = "N2 Compressor", section = "LIFE", snap = "block", box = B(-0.5, 0.5, 0, 1.3, -0.35, 0.35),
                mats = { "steel" }, vol = 0.91, fill = "solid", mass = { steel = 0.16 }, cost = 4200,
                life = { n2 = 0.004 }, use = 1.2,
                desc = "a membrane nitrogen generator: pulls the outside air and feeds the room its inert gas up to 1 atm (14 m³ an hour) · what the outside holds besides O2 comes in too: on a CO2 world run the scrubbers · 1.2 EC/s" },
  o2conc    = { label = "O2 Concentrator", section = "LIFE", snap = "block", box = B(-0.4, 0.4, 0, 1.5, -0.3, 0.34),
                mats = { "steel" }, vol = 0.72, fill = "solid", mass = { steel = 0.11 }, cost = 4800,
                life = { o2c = 2.8e-5 }, use = 2.0,
                desc = "a pressure-swing O2 concentrator for four crew: makes oxygen from any outside air with 5 % of it, no water · 2 EC/s" },
  -- (S7: pressure mechanics, scripts/room_air.lua)
  airReceiver = { label = "Airlock Receiver", section = "LIFE", snap = "block", box = B(-0.45, 0.45, 0, 2.0, -0.45, 0.45),
                mats = { "steel" }, vol = 1.6, fill = "solid", mass = { steel = 0.32 }, cost = 3400,
                life = { receiver = 24 },
                desc = "a 1.2 m³ receiver to 20 bar for an airlock's air · in the chamber or the hab beside it, the airlock pumps its air into it and back instead of venting it" },
  eqValve   = { label = "Equalise Valve", section = "LIFE", snap = "mount", box = B(-0.16, 0.16, 0, 0.18, -0.16, 0.16),
                mats = { "steel" }, vol = 0.009, fill = "solid", mass = { steel = 0.012 }, cost = 320,
                eqv = { C = 0.25 },
                desc = "a 40 mm bleed valve through the wall it is on · open, it lets the two sides' pressures meet slowly, so a door between them can open · right-click opens it" },
  -- ── SCIENCE (expansion X1: the survey's instruments, scripts/survey.lua) ──
  telescope = { label = "Telescope 0.3 m", section = "SCIENCE", snap = "block", box = B(-0.45, 0.42, 0, 1.9, -0.4, 0.76),
                mats = { "steel" }, vol = 0.2, fill = "solid", mass = { steel = 0.065 }, cost = 8000,
                survey = { kind = "telescope", ap = 0.3, crew = true }, use = 0.15,
                desc = "a 0.3 m reflector on a pier and an equatorial mount · a Scientist at its eyepiece sweeps a world: temperature and air from its light · night or vacuum, the target above the horizon · 0.15 EC/s" },
  telescope1m = { label = "Telescope 1 m", section = "SCIENCE", snap = "block", box = B(-1.12, 1.32, 0, 4.07, -1.12, 1.25),
                mats = { "steel" }, vol = 2.6, fill = "solid", mass = { steel = 2.4 }, cost = 48000,
                survey = { kind = "telescope", ap = 1.0, crew = true }, use = 1.2,
                desc = "a 1 m truss telescope on a fork mount with its spectrograph · resolves a world's air by its spectrum · a Scientist runs it · 1.2 EC/s" },
  surveyStation = { label = "Survey Station", section = "SCIENCE", snap = "block", box = B(-0.88, 0.62, 0, 2.63, -0.69, 0.57),
                mats = { "steel" }, vol = 0.3, fill = "solid", mass = { steel = 0.12 }, cost = 6000,
                survey = { kind = "station" },
                desc = "a landed science package on its own panel: weather mast, buried seismometer, magnetometer boom · reads its world's temperature, air, interior and field over a day" },
  -- ── FLUID (S7: pipes and tanks; scripts/fluids.lua, fluid_net.lua) ──
  -- Ports at PIPE_Y (0.6 m) unless a riser's, on the 0.5 m grid; DN25
  -- (33.7 mm OD) process line. Masses are the pieces' own, empty.
  flPipe2   = { label = "Process Pipe 2 m", section = "FLUID", snap = "pipe", box = B(-0.08, 0.08, 0, 0.66, -1, 1),
                mats = { "steel" }, vol = 0.05, fill = "solid", mass = { steel = 0.009 }, cost = 90, order = 1,
                fl = { kind = "pipe", len = 2.0, bore = "DN25" },
                ports = { { name = "a", x = 0, z = -1, nx = 0, nz = -1 }, { name = "b", x = 0, z = 1, nx = 0, nz = 1 } },
                desc = "DN25 stainless on its stands · water, fuel or gas: whatever its tanks hold · 1.1 kg/s of water at 2 m/s" },
  flPipe1   = { label = "Process Pipe 1 m", section = "FLUID", snap = "pipe", box = B(-0.08, 0.08, 0, 0.66, -0.5, 0.5),
                mats = { "steel" }, vol = 0.025, fill = "solid", mass = { steel = 0.005 }, cost = 55, order = 2,
                fl = { kind = "pipe", len = 1.0, bore = "DN25" },
                ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1 }, { name = "b", x = 0, z = 0.5, nx = 0, nz = 1 } },
                desc = "a 1 m length of DN25 process pipe" },
  flElbow   = { label = "Process Elbow", section = "FLUID", snap = "pipe", box = B(-0.08, 0.5, 0, 0.66, -0.5, 0.08),
                mats = { "steel" }, vol = 0.02, fill = "solid", mass = { steel = 0.004 }, cost = 60, order = 3,
                fl = { kind = "pipe", len = 0.8, bore = "DN25" },
                ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1 }, { name = "b", x = 0.5, z = 0, nx = 1, nz = 0 } },
                desc = "a 90° bend · R turns which end goes on" },
  flTee     = { label = "Process Tee", section = "FLUID", snap = "pipe", box = B(-0.08, 0.5, 0, 0.66, -0.5, 0.5),
                mats = { "steel" }, vol = 0.03, fill = "solid", mass = { steel = 0.005 }, cost = 70, order = 4,
                fl = { kind = "pipe", len = 1.2, bore = "DN25" },
                ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1 }, { name = "b", x = 0, z = 0.5, nx = 0, nz = 1 }, { name = "c", x = 0.5, z = 0, nx = 1, nz = 0 } },
                desc = "a branch: one line into two" },
  flRiser   = { label = "Pipe Riser (one storey)", section = "FLUID", snap = "pipe", box = B(-0.08, 0.08, 0, 3.06, -0.5, 0.08),
                mats = { "steel" }, vol = 0.05, fill = "solid", mass = { steel = 0.012 }, cost = 140, order = 5,
                fl = { kind = "pipe", len = 3.4, bore = "DN25" },
                ports = { { name = "low", x = 0, y = 0.6, z = -0.5, nx = 0, nz = -1 }, { name = "high", x = 0, y = 3.0, z = -0.5, nx = 0, nz = -1 } },
                desc = "a pipe up a storey (2.4 m): its low port at this floor's pipe height, its high port at the next floor's · a pump lifts the water, a tank upstairs feeds down" },
  flTankWater = { label = "Water Tank 2 m³", section = "FLUID", snap = "block", box = B(-0.7, 0.7, 0, 2.3, -1.0, 0.7),
                mats = { "steel" }, vol = 3.0, fill = "solid", mass = { steel = 0.42 }, cost = 2200, order = 10,
                fl = { kind = "tank", sub = "water", V = 2.0, A = 1.131 },
                ports = { { name = "out", x = 0, z = -1.0, nx = 0, nz = -1 } },
                desc = "a 1.2 m steel tank under a nitrogen blanket, 2 m³ (2 t of water) · its level drives what flows out by gravity · fill it from the base stores (right-click)" },
  flTankCool = { label = "Coolant Tank 2 m³", section = "FLUID", snap = "block", box = B(-0.7, 0.7, 0, 2.3, -1.0, 0.7),
                mats = { "steel" }, vol = 3.0, fill = "solid", mass = { steel = 0.42 }, cost = 2600, order = 11,
                fl = { kind = "tank", sub = "coolant", V = 2.0, A = 1.131 },
                ports = { { name = "out", x = 0, z = -1.0, nx = 0, nz = -1 } },
                desc = "demineralised borated water for a reactor's primary · a charging pump from it to the pressuriser's makeup nozzle keeps the loop full" },
  flTankFuel = { label = "Fuel Tank 2 m³", section = "FLUID", snap = "block", box = B(-0.7, 0.7, 0, 2.3, -1.0, 0.7),
                mats = { "steel" }, vol = 3.0, fill = "solid", mass = { steel = 0.42 }, cost = 2400, order = 12,
                fl = { kind = "tank", sub = "fuel", V = 2.0, A = 1.131 },
                ports = { { name = "out", x = 0, z = -1.0, nx = 0, nz = -1 } },
                desc = "RP-1 under a nitrogen blanket, 2 m³ (1.6 t, 162 units) · a pump to a Fuel Hose Stand fuels a craft on a stand" },
  flBottleO2 = { label = "Oxygen Bottle Rack", section = "FLUID", snap = "block", box = B(-0.6, 0.6, 0, 1.8, -0.5, 0.25),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 0.24 }, cost = 1900, order = 20,
                fl = { kind = "bottle", sub = "o2", V = 0.15, pmax = 200e5 },
                ports = { { name = "out", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "three 50 L cylinders of O2 at 200 bar (39 kg) on a manifold · a regulator to a Room Gas Outlet gives a room its oxygen" },
  flBottleN2 = { label = "Nitrogen Bottle Rack", section = "FLUID", snap = "block", box = B(-0.6, 0.6, 0, 1.8, -0.5, 0.25),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 0.24 }, cost = 1500, order = 21,
                fl = { kind = "bottle", sub = "n2", V = 0.15, pmax = 200e5 },
                ports = { { name = "out", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "three 50 L cylinders of N2 at 200 bar (34 kg) · the buffer gas of a room's air" },
  flBottleH2 = { label = "Hydrogen Bottle Rack", section = "FLUID", snap = "block", box = B(-0.6, 0.6, 0, 1.8, -0.5, 0.25),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 0.26 }, cost = 2100, order = 22,
                fl = { kind = "bottle", sub = "h2", V = 0.15, pmax = 200e5, empty = true },
                ports = { { name = "in", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "three 50 L cylinders for hydrogen to 200 bar (2.5 kg) · piped from an Oxygen Generator, it keeps the H2 it makes instead of venting it" },
  flPump    = { label = "Process Pump", section = "FLUID", snap = "block", box = B(-0.3, 0.3, 0, 0.9, -0.5, 0.5),
                mats = { "steel" }, vol = 0.3, fill = "solid", mass = { steel = 0.06 }, cost = 1400, order = 30,
                fl = { kind = "pump", q0 = 2.0, H0 = 6e5, kw = 0.75 },
                ports = { { name = "in", x = 0, z = -0.5, nx = 0, nz = -1 }, { name = "out", x = 0, z = 0.5, nx = 0, nz = 1 } },
                desc = "a centrifugal pump: 2 kg/s free, nothing past 6 bar (its curve between) · 0.75 kW from the grid · in → out" },
  flCharge  = { label = "Charging Pump", section = "FLUID", snap = "block", box = B(-0.45, 0.45, 0, 1.1, -0.75, 0.75),
                mats = { "steel" }, vol = 0.9, fill = "solid", mass = { steel = 0.35 }, cost = 9800, order = 31, tech = "ember",
                fl = { kind = "pump", q0 = 0.5, H0 = 18e6, kw = 4.0 },
                ports = { { name = "in", x = 0, z = -0.75, nx = 0, nz = -1 }, { name = "out", x = 0, z = 0.75, nx = 0, nz = 1 } },
                desc = "a triplex plunger pump to 18 MPa, 0.5 kg/s · the only pump that beats a pressurised primary · 4 kW" },
  flValve   = { label = "Gate Valve", section = "FLUID", snap = "pipe", box = B(-0.1, 0.1, 0, 0.9, -0.25, 0.25),
                mats = { "steel" }, vol = 0.01, fill = "solid", mass = { steel = 0.006 }, cost = 120, order = 40,
                fl = { kind = "valve", len = 0.3 },
                ports = { { name = "a", x = 0, z = -0.25, nx = 0, nz = -1 }, { name = "b", x = 0, z = 0.25, nx = 0, nz = 1 } },
                desc = "open or shut, from its handwheel (right-click)" },
  flCheck   = { label = "Check Valve", section = "FLUID", snap = "pipe", box = B(-0.08, 0.08, 0, 0.7, -0.25, 0.25),
                mats = { "steel" }, vol = 0.008, fill = "solid", mass = { steel = 0.004 }, cost = 90, order = 41,
                fl = { kind = "check", len = 0.3 },
                ports = { { name = "a", x = 0, z = -0.25, nx = 0, nz = -1 }, { name = "b", x = 0, z = 0.25, nx = 0, nz = 1 } },
                desc = "a swing check: passes a → b (the arrow), never back" },
  flReg     = { label = "Pressure Regulator", section = "FLUID", snap = "pipe", box = B(-0.1, 0.1, 0, 0.85, -0.25, 0.25),
                mats = { "steel" }, vol = 0.01, fill = "solid", mass = { steel = 0.005 }, cost = 260, order = 42,
                fl = { kind = "reg", pset = 5e5, len = 0.3 },
                ports = { { name = "in", x = 0, z = -0.25, nx = 0, nz = -1 }, { name = "out", x = 0, z = 0.25, nx = 0, nz = 1 } },
                desc = "holds its outlet at its set pressure (5 bar; right-click sets it) while its inlet is over it · bottles to a line" },
  flGauge   = { label = "Pressure Gauge", section = "FLUID", snap = "pipe", box = B(-0.1, 0.1, 0, 0.84, -0.25, 0.25),
                mats = { "steel" }, vol = 0.006, fill = "solid", mass = { steel = 0.003 }, cost = 80, order = 43,
                fl = { kind = "gauge", len = 0.3 },
                ports = { { name = "a", x = 0, z = -0.25, nx = 0, nz = -1 }, { name = "b", x = 0, z = 0.25, nx = 0, nz = 1 } },
                desc = "a 100 mm dial in the line · right-click (or the FLUIDS overlay) reads the pressure and the flow" },
  flOutlet  = { label = "Room Gas Outlet", section = "FLUID", snap = "block", box = B(-0.2, 0.2, 0, 1.0, -0.5, 0.2),
                mats = { "steel" }, vol = 0.04, fill = "solid", mass = { steel = 0.01 }, cost = 180, order = 44,
                fl = { kind = "outlet", g = 2e-6 },
                ports = { { name = "in", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "a diffuser: the gas its line brings goes into the room it stands in, until the room is at 1 atm" },
  flVent    = { label = "Vent Stack", section = "FLUID", snap = "block", box = B(-0.2, 0.2, 0, 2.6, -0.5, 0.2),
                mats = { "steel" }, vol = 0.05, fill = "solid", mass = { steel = 0.015 }, cost = 150, order = 45,
                fl = { kind = "vent", g = 2e-6 },
                ports = { { name = "in", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "a stack that vents its line to the outside · stands outdoors" },
  flHose    = { label = "Fuel Hose Stand", section = "FLUID", snap = "block", box = B(-0.4, 0.4, 0, 1.6, -0.5, 0.4),
                mats = { "steel" }, vol = 0.3, fill = "solid", mass = { steel = 0.09 }, cost = 1600, order = 50,
                fl = { kind = "consumer", sub = "fuel", V = 0.05, A = 0.1, hose = 30 },
                ports = { { name = "in", x = 0, z = -0.5, nx = 0, nz = -1 } },
                desc = "a reel of fuel hose with a 50 L day tank · a craft held on a stand within 30 m fills from it (right-click)" },
  -- ── NUCLEAR (S6: a reactor built from components; scripts/reactor.lua) ──
  -- Every port is at PIPE_Y (0.6 m) over the piece's ground point, on the
  -- 0.5 m grid; a pipe's ends meet a component's nozzle exactly.
  reactorBase = { label = "Reactor Vessel Base 5 × 5", section = "NUCLEAR", snap = "block", box = B(-1.25, 1.25, 0, 1.0, -1.5, 1.5),
                mats = { "steel" }, vol = 6.25, fill = "solid", mass = { steel = 9.5 }, cost = 48000, tech = "ember", order = 1,
                nuclear = { role = "vessel", cells = 5, top = 1.0 },
                ports = { { name = "in", x = 0, z = -1.5, nx = 0, nz = -1, loop = "pri" }, { name = "out", x = 0, z = 1.5, nx = 0, nz = 1, loop = "pri" } },
                rad = { rad = 0, omni = true, dynamic = true, up = 1.7 },
                desc = "the lower head, inlet plenum and grid plate of a pressure-tube core · stand fuel channels, moderator and control rods on its 5 × 5 lattice · coolant in at −Z, out at +Z" },
  fuelChannel = { label = "Fuel Channel", section = "NUCLEAR", snap = "block", box = B(-0.25, 0.25, 0, 2.4, -0.25, 0.25),
                mats = { "steel" }, vol = 0.6, fill = "solid", mass = { steel = 0.18 }, cost = 6500, tech = "ember", order = 2,
                nuclear = { role = "fuel", rods = 8 },
                desc = "a zircaloy pressure tube for eight fuel rods · cooled by the primary loop · the moderator beside it slows its neutrons" },
  modGraphite = { label = "Graphite Moderator Column", section = "NUCLEAR", snap = "block", box = B(-0.25, 0.25, 0, 2.4, -0.25, 0.25),
                mats = { "graphite" }, vol = 0.6, fill = "solid", cost = 3200, tech = "ember", order = 3,
                nuclear = { role = "mod", mod = "graphite" },
                desc = "stacked graphite bricks · moderates well, absorbs little · a graphite core wants to be big: its neutrons wander far" },
  modWater = { label = "Light Water Moderator Column", section = "NUCLEAR", snap = "block", box = B(-0.25, 0.25, 0, 2.4, -0.25, 0.25),
                mats = { "steel" }, vol = 0.6, fill = "solid", mass = { steel = 0.67 }, cost = 1400, tech = "ember", order = 4,
                nuclear = { role = "mod", mod = "water" },
                desc = "a steel tank of ordinary water · the strongest moderator, but it absorbs: it needs enriched fuel · compact cores" },
  modHeavy = { label = "Heavy Water Moderator Column", section = "NUCLEAR", snap = "block", box = B(-0.25, 0.25, 0, 2.4, -0.25, 0.25),
                mats = { "steel" }, vol = 0.6, fill = "solid", mass = { steel = 0.73 }, cost = 38000, tech = "ember", order = 5,
                nuclear = { role = "mod", mod = "heavy" },
                desc = "a tank of D2O · moderates and hardly absorbs: natural uranium goes critical with it · costly" },
  controlRod = { label = "Control Rod Column", section = "NUCLEAR", snap = "block", box = B(-0.25, 0.25, 0, 3.0, -0.25, 0.25),
                mats = { "steel" }, vol = 0.75, fill = "solid", mass = { steel = 0.42 }, cost = 9000, tech = "ember", order = 6,
                nuclear = { role = "rod" },
                desc = "a boron carbide rod in its guide tube, its drive on top · worth most among fuel · drops in on a SCRAM" },
  pipe2 = { label = "Coolant Pipe 2 m", section = "NUCLEAR", snap = "pipe", box = B(-0.12, 0.12, 0, 0.72, -1, 1),
                mats = { "steel" }, vol = 0.35, fill = "solid", mass = { steel = 0.06 }, cost = 260, tech = "ember", order = 10,
                pipe = { len = 2.0, loss = 0.0025 }, ports = { { name = "a", x = 0, z = -1, nx = 0, nz = -1, loop = "p" }, { name = "b", x = 0, z = 1, nx = 0, nz = 1, loop = "p" } },
                desc = "DN100 schedule 80 steel on its stanchions · bare, it loses 0.25 % of the plant's heat a metre to the room (insulate a long run)" },
  pipe1 = { label = "Coolant Pipe 1 m", section = "NUCLEAR", snap = "pipe", box = B(-0.12, 0.12, 0, 0.72, -0.5, 0.5),
                mats = { "steel" }, vol = 0.17, fill = "solid", mass = { steel = 0.03 }, cost = 150, tech = "ember", order = 11,
                pipe = { len = 1.0, loss = 0.0025 }, ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1, loop = "p" }, { name = "b", x = 0, z = 0.5, nx = 0, nz = 1, loop = "p" } },
                desc = "a 1 m length of DN100 coolant pipe" },
  pipeElbow = { label = "Pipe Elbow", section = "NUCLEAR", snap = "pipe", box = B(-0.12, 0.5, 0, 0.72, -0.5, 0.12),
                mats = { "steel" }, vol = 0.1, fill = "solid", mass = { steel = 0.03 }, cost = 180, tech = "ember", order = 12,
                pipe = { len = 0.8, loss = 0.0025 }, ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1, loop = "p" }, { name = "b", x = 0.5, z = 0, nx = 1, nz = 0, loop = "p" } },
                desc = "a 90° long-radius bend · R turns which end goes on" },
  pipeTee = { label = "Pipe Tee", section = "NUCLEAR", snap = "pipe", box = B(-0.12, 0.5, 0, 0.72, -0.5, 0.5),
                mats = { "steel" }, vol = 0.12, fill = "solid", mass = { steel = 0.04 }, cost = 220, tech = "ember", order = 13,
                pipe = { len = 1.2, loss = 0.0025 }, ports = { { name = "a", x = 0, z = -0.5, nx = 0, nz = -1, loop = "p" }, { name = "b", x = 0, z = 0.5, nx = 0, nz = 1, loop = "p" },
                         { name = "c", x = 0.5, z = 0, nx = 1, nz = 0, loop = "p" } },
                desc = "a branch · where the pressuriser's surge line joins the loop" },
  pipeIns2 = { label = "Insulated Pipe 2 m", section = "NUCLEAR", snap = "pipe", box = B(-0.17, 0.17, 0, 0.8, -1, 1),
                mats = { "steel" }, vol = 0.45, fill = "solid", mass = { steel = 0.08 }, cost = 520, tech = "ember", order = 14,
                pipe = { len = 2.0, loss = 0.00004, lagged = true }, ports = { { name = "a", x = 0, z = -1, nx = 0, nz = -1, loop = "p" }, { name = "b", x = 0, z = 1, nx = 0, nz = 1, loop = "p" } },
                desc = "DN100 under 80 mm of mineral wool in an aluminium jacket · loses a sixtieth of a bare pipe's heat · a fitting between two lagged runs is lagged with them" },
  coolantPump = { label = "Coolant Pump", section = "NUCLEAR", snap = "block", box = B(-0.5, 0.5, 0, 1.5, -1, 1),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 0.65 }, cost = 14000, tech = "ember", order = 20,
                pump = { flow = 4.0, kw = 1.5 }, power = { kind = "aux", use = 1.5 },
                ports = { { name = "in", x = 0, z = -1, nx = 0, nz = -1, loop = "p" }, { name = "out", x = 0, z = 1, nx = 0, nz = 1, loop = "p" } },
                desc = "a canned-motor pump: 4 kg/s round its loop · 1.5 kW from the grid · it pushes in → out (the arrow on its casing) · two in a loop ride out one failing" },
  pressuriser = { label = "Pressuriser", section = "NUCLEAR", snap = "block", box = B(-0.5, 0.5, 0, 3.6, -1, 0.5),
                mats = { "steel" }, vol = 2.9, fill = "solid", mass = { steel = 1.9 }, cost = 22000, tech = "ember", order = 21,
                press = { kw = 0.8, tsat = 618 }, power = { kind = "aux", use = 0.8 },
                ports = { { name = "surge", x = 0, z = -1, nx = 0, nz = -1, loop = "pri" },
                          { name = "makeup", x = 0.5, z = 0, nx = 1, nz = 0, loop = "mk", fluid = true, role = "primary", bore = "DN25" } },
                desc = "holds the primary at 15.5 MPa with its heaters (0.8 kW): the coolant runs at 300 °C without boiling · without one it boils at 100 °C · its DN25 makeup nozzle (+X) takes water from a charging pump" },
  steamGen = { label = "Steam Generator", section = "NUCLEAR", snap = "block", box = B(-0.75, 0.75, 0, 3.8, -1, 1),
                mats = { "steel" }, vol = 4.2, fill = "solid", mass = { steel = 4.2 }, cost = 38000, tech = "ember", order = 22,
                hx = { ua = 30 },
                ports = { { name = "pri_in", x = -0.5, z = -1, nx = 0, nz = -1, loop = "pri" }, { name = "pri_out", x = 0.5, z = -1, nx = 0, nz = -1, loop = "pri" },
                          { name = "sec_in", x = 0.5, z = 1, nx = 0, nz = 1, loop = "sec" }, { name = "sec_out", x = -0.5, z = 1, nx = 0, nz = 1, loop = "sec" } },
                desc = "a U-tube heat exchanger, 30 kW/K · the primary loop (its −Z nozzles) boils the secondary (its +Z nozzles) · the radioactive water stays inside" },
  turbineSet = { label = "Turbine-Generator 100 kW", section = "NUCLEAR", snap = "block", box = B(-1.75, 1.75, 0, 1.7, -1.0, 0.75),
                mats = { "steel" }, vol = 8.0, fill = "solid", mass = { steel = 3.6 }, cost = 65000, tech = "ember", order = 23,
                turbine = { kwe = 100, eta = 0.65, qmax = 420, min = 0.1 }, power = { kind = "plant", kwe = 100 },
                ports = { { name = "steam", x = -1.0, z = -1.0, nx = 0, nz = -1, loop = "sec" }, { name = "exhaust", x = 1.0, z = -1.0, nx = 0, nz = -1, loop = "sec" } },
                desc = "a small steam turbine and its generator, 100 kW(e) · it makes 65 % of the Carnot limit between its steam and its condenser · on the base grid" },
  radiatorPanel = { label = "Radiator Panel 2 × 4 m", section = "NUCLEAR", snap = "block", box = B(-1.5, 1.5, 0, 4.4, -0.3, 0.3),
                mats = { "steel" }, vol = 2.0, fill = "solid", mass = { steel = 0.32 }, cost = 6800, tech = "ember", order = 24,
                reject = { kind = "rad", area = 16, eps = 0.88 },
                ports = { { name = "in", x = -1.5, z = 0, nx = -1, nz = 0, loop = "c" }, { name = "out", x = 1.5, z = 0, nx = 1, nz = 0, loop = "c" } },
                desc = "a condensing radiator, 16 m² both faces · sheds by εσT⁴: run it hotter and it sheds far more, but the turbine makes less · rows chain end to end" },
  coolingTower = { label = "Cooling Tower Cell", section = "NUCLEAR", snap = "block", box = B(-1.5, 1.5, 0, 5.2, -2.0, 1.5),
                mats = { "steel" }, vol = 15, fill = "solid", mass = { steel = 6.5 }, cost = 30000, tech = "ember", order = 25,
                reject = { kind = "tower", g = 14, kw = 2 }, power = { kind = "aux", use = 2.0 },
                ports = { { name = "in", x = -0.5, z = -2.0, nx = 0, nz = -1, loop = "c" }, { name = "out", x = 0.5, z = -2.0, nx = 0, nz = -1, loop = "c" } },
                desc = "a forced-draft cell, 14 kW/K to the air · its fan draws 2 kW · nothing to blow on an airless world" },
  reactorConsole = { label = "Reactor Control Console", section = "NUCLEAR", snap = "block", box = B(-0.8, 0.8, 0, 1.45, -0.45, 0.45),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 0.25 }, cost = 12000, tech = "ember", order = 30,
                console = { w = 1.1, h = 0.62 }, script = "reactor_plant",
                desc = "the plant's desk: k, power, rods, xenon, the loops, the turbine, the dose and what limits it · right-click to run the reactor" },
  shieldHeavy = { label = "Heavy Shield Block 1 × 1", section = "SHIELD", snap = "block", box = B(-0.5, 0.5, 0, 1, -0.5, 0.5),
                mats = { "concrete" }, vol = 1.0, fill = "solid", mass = { concrete = 3.6 }, cost = 2200, shieldk = 0.02,
                desc = "1 m of magnetite concrete · lets 2 % of a dose through · stacks into a reactor's shield" },
  waterShield = { label = "Water Shield Tank", section = "SHIELD", snap = "block", box = B(-0.5, 0.5, 0, 2.0, -0.25, 0.25),
                mats = { "steel" }, vol = 1.0, fill = "solid", mass = { steel = 1.08 }, cost = 700, shieldk = 0.25,
                desc = "a steel tank of water, 0.5 m thick · light and cheap · lets a quarter through" },
}

-- ── PROPS (S4: clutter and character; tools/gen_kit_props.py) ───────────────
-- masses are the things' own (an empty steel crate, a bunk with its mattresses)
local function prop(t)
  t.section = "PROPS"
  t.mats = t.mats or { "steel" }
  t.fill = "solid"
  t.vol = t.vol or 0.01
  return t
end
for k, t in pairs({
  crate     = { label = "Cargo Crate", snap = "prop", box = B(-0.6, 0.6, 0, 0.8, -0.4, 0.4), mass = { steel = 0.065 }, cost = 180,
                desc = "a 1.2 m steel-framed crate · stacks · the gravity gun can't lift a placed one" },
  crateS    = { label = "Small Crate", snap = "prop", box = B(-0.3, 0.3, 0, 0.45, -0.225, 0.225), mass = { steel = 0.018 }, cost = 90,
                desc = "a 0.6 m crate for the shelf or the corner" },
  drum      = { label = "Drum", snap = "prop", box = B(-0.3, 0.3, 0, 0.9, -0.3, 0.3), mass = { steel = 0.022 }, cost = 120,
                desc = "a 200 litre steel drum" },
  shelf     = { label = "Shelving", snap = "prop", box = B(-0.6, 0.6, 0, 2.0, -0.225, 0.225), mass = { steel = 0.055 }, cost = 260,
                desc = "a 2 m steel shelf unit, stocked" },
  table     = { label = "Table", snap = "prop", box = B(-0.8, 0.8, 0, 0.74, -0.4, 0.4), mass = { steel = 0.04 }, cost = 220,
                desc = "a 1.6 m mess table · things go on its top" },
  chair     = { label = "Chair", snap = "prop", box = B(-0.22, 0.22, 0, 0.92, -0.25, 0.2), mass = { steel = 0.008 }, cost = 80,
                desc = "a steel stacking chair" },
  bunk      = { label = "Bunk", snap = "prop", box = B(-1, 1, 0, 1.75, -0.45, 0.45), mass = { steel = 0.11 }, cost = 650,
                desc = "two berths, mattresses and blankets · a crew room's heart" },
  workbench = { label = "Workbench", snap = "prop", box = B(-0.9, 0.9, 0, 1.9, -0.375, 0.375), mass = { steel = 0.16 }, cost = 900,
                desc = "a steel bench with drawers, a vice and a pegboard of tools" },
  coffee    = { label = "Coffee Maker", snap = "prop", box = B(-0.12, 0.34, 0, 0.38, -0.14, 0.125), mass = { steel = 0.004 }, cost = 60,
                clutter = true, desc = "a brewer and two mugs · goes on a table or bench" },
  monitor   = { label = "Desk Monitor", snap = "prop", box = B(-0.28, 0.28, 0, 0.5, -0.09, 0.2), mass = { steel = 0.006 }, cost = 300,
                clutter = true, desc = "a screen and keyboard · goes on a table or bench" },
  plant     = { label = "Potted Plant", snap = "prop", box = B(-0.3, 0.3, 0, 0.9, -0.27, 0.27), mass = { steel = 0.012 }, cost = 45,
                clutter = true, desc = "something green that isn't mould" },
  cableReel = { label = "Cable Reel", snap = "prop", box = B(-0.35, 0.5, 0, 0.7, -0.24, 0.27), mass = { steel = 0.05 }, cost = 140,
                desc = "a drum of power cable, some of it run out" },
  toolRack  = { label = "Tool Rack", snap = "mount", box = B(-0.6, 0.6, 0, 0.07, -0.4, 0.4), mass = { steel = 0.02 }, cost = 240,
                desc = "a wall board of hung tools" },
  pipeRun   = { label = "Pipe Run 2 m", snap = "mount", box = B(-1, 1, 0, 0.24, -0.16, 0.16), mass = { steel = 0.03 }, cost = 180,
                desc = "two service pipes on brackets, a valve · walls and ceilings" },
  cableRun  = { label = "Cable Run 2 m", snap = "mount", box = B(-1, 1, 0, 0.17, -0.08, 0.32), mass = { steel = 0.008 }, cost = 90,
                desc = "a bundle of cables in clips, one sagging free" },
  extinguisher = { label = "Fire Extinguisher", snap = "mount", box = B(-0.08, 0.08, 0, 0.19, -0.32, 0.25), mass = { steel = 0.012 }, cost = 70,
                desc = "a CO2 extinguisher on its wall bracket" },
  lampDesk  = { label = "Desk Lamp", snap = "prop", box = B(-0.08, 0.08, 0, 0.49, -0.09, 0.28), mass = { steel = 0.002 }, cost = 55,
                clutter = true, lens = true, light = { color = { 1.0, 0.80, 0.58 }, intensity = 1.4, range = 4, draw = 0.01 },
                desc = "a warm task lamp · right-click switches it · 0.01 EC/s" },
  lampFloor = { label = "Work Light", snap = "prop", box = B(-0.25, 0.33, 0, 1.74, -0.29, 0.29), mass = { steel = 0.006 }, cost = 160,
                clutter = true, lens = true, light = { color = { 0.86, 0.92, 1.0 }, intensity = 3.2, range = 10, draw = 0.05 },
                desc = "a 5,000 K floodlight on a tripod · right-click switches it · 0.05 EC/s" },
}) do PIECES[k] = prop(t) end

-- ── DECALS AND SIGNS (S4): films and plates on a face ───────────────────────
-- (sizes are the generator's atlas cells at 512 px a metre, grime at 256)
local function film(label, w, h, cost, desc, extra)
  local t = { label = label, section = "DECALS", snap = "mount", box = B(-w / 2, w / 2, 0, 0.004, -h / 2, h / 2),
              mats = { "film" }, vol = w * h * 0.0001, fill = "solid", mass = { film = 0.0005 + w * h * 0.0004 }, cost = cost,
              film = true, desc = desc }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local D = 512
for k, t in pairs({
  decalHaz     = { "Hazard Stripe 2 m", 1024 / D, 104 / D, 30, "black and safety yellow at 45° · edges, steps, anything that bites" },
  decalHazS    = { "Hazard Stripe 1 m", 512 / D, 52 / D, 15, "a narrow band · door edges, kerbs" },
  decalHazSq   = { "Hazard Panel", 256 / D, 256 / D, 15, "a 0.5 m chevron square · pillars, machinery" },
  decalArrow   = { "Arrow", 256 / D, 154 / D, 12, "a stencilled arrow · T turns it on the face" },
  decalChev    = { "Chevrons", 410 / D, 128 / D, 15, "three chevrons · this way" },
  decalNoEntry = { "NO ENTRY", 410 / D, 154 / D, 20, "a placard in danger red" },
  decalAirlock = { "AIRLOCK", 512 / D, 128 / D, 20, "stencilled black on safety yellow" },
  decalPress   = { "PRESSURE DOOR", 410 / D, 128 / D, 20, "PRESSURE DOOR · KEEP CLEAR WHILE CYCLING" },
  decalLoad    = { "Load Rating", 256 / D, 128 / D, 15, "a MAX LOAD 500 kg plate" },
  decalO2      = { "O2 Line Marker", 307 / D, 77 / D, 10, "a pipe band: OXYGEN and its flow" },
  decalVolt    = { "DANGER 400 V", 307 / D, 77 / D, 10, "a voltage warning band" },
  decalExit    = { "EXIT", 307 / D, 102 / D, 15, "an exit placard with its arrow" },
  decalHalden  = { "Halden Structural", 512 / D, 205 / D, 25, "the supplier's mark · structure" },
  decalPell    = { "Pell Groundworks", 512 / D, 205 / D, 25, "the supplier's mark · groundworks" },
  grimeStreaks = { "Grime: Streaks", 2.0, 563 / 256, 10, "run-off down a wall, splash at its foot", { grime = true } },
  grimeScuff   = { "Grime: Floor Scuffs", 2.0, 2.0, 10, "boot traffic worn into a deck", { grime = true } },
  grimeLeak    = { "Grime: Rust Run", 154 / 256, 307 / 256, 10, "a weep of rust under a bolt or a seam", { grime = true } },
  grimeSoot    = { "Grime: Scorch", 1.0, 1.0, 10, "soot from a vent, a welder, a fire", { grime = true } },
  grimeOil     = { "Grime: Oil Stain", 1.0, 1.0, 10, "an oil patch on a floor", { grime = true } },
}) do PIECES[k] = film(t[1], t[2], t[3], t[4], t[5], t[6]) end
for d = 0, 9 do
  PIECES["decalNum" .. d] = film("Number " .. d, 154 / D, 205 / D, 10, "a 0.4 m stencilled numeral · door and bay numbers", { order = 100 + d })
end
-- signs: text kit_live draws (`sign`), or the agency's emblem (`emblem`)
-- (S5 polish: readable at 8 m. The plates grew, kit_live sets the words in
-- capitals ~0.15 m tall on a plate, wraps them onto two lines when that reads
-- bigger, and narrows the plate to the words: `fit` = the narrowest share of
-- its full width a short word may shrink it to)
PIECES.signPlate   = { label = "Sign Plate", section = "DECALS", snap = "mount", box = B(-0.72, 0.72, 0, 0.014, -0.245, 0.245), order = 1,
                       mats = { "steel" }, vol = 0.004, fill = "solid", mass = { steel = 0.009 }, cost = 60,
                       sign = { w = 1.4, h = 0.45, style = "plate", px = 896, fit = 0.4 },
                       desc = "a riveted plate · your words, or the base's name · sized to the words · right-click to write it" }
PIECES.signBoard   = { label = "Name Board", section = "DECALS", snap = "mount", box = B(-1.22, 1.22, 0, 0.014, -0.32, 0.32), order = 2,
                       mats = { "steel" }, vol = 0.009, fill = "solid", mass = { steel = 0.018 }, cost = 180,
                       sign = { w = 2.4, h = 0.6, style = "board", px = 1024, fit = 0.45 },
                       desc = "a 2.4 m board over a door · the base's name in stencil, or yours" }
PIECES.signStencil = film("Stencilled Words", 2.0, 0.4, 40, "letters sprayed straight on the wall · right-click to write them",
                          { sign = { w = 2.0, h = 0.4, style = "stencil", px = 1024 }, order = 3 })
PIECES.decalEmblem = film("Agency Emblem", 0.8, 0.8, 50, "the company's own emblem, sprayed on", { emblem = true, order = 4 })

-- ── LOGIC (S8: signals, sensors, gates, the ladder controller; logic.lua) ───
-- Wall-hung control gear is modelled lying on a floor, its face +Y out (a
-- mount): on a wall its +Z points down, so the cable glands are on the box's
-- +Z end, inputs to the left of it and outputs to the right. Masses are the
-- things' own (a DIN enclosure with its relay board ~1 kg).
local function glands(b, ins, outs)
  local pins = {}
  local n = #ins + #outs
  local w = b[2] - b[1]
  local y = (b[4] - b[3]) * 0.5
  for k = 1, n do
    local x = b[1] + w * (k - 0.5) / n
    local io, nm = "in", ins[k]
    if k > #ins then io, nm = "out", outs[k - #ins] end
    pins[#pins + 1] = { n = nm, io = io, x = x, y = y, z = b[6] }
  end
  return pins
end
local function lgp(t)
  t.section = "LOGIC"
  t.snap = t.snap or "mount"
  t.mats = { "steel" }
  t.fill = "solid"
  t.vol = t.vol or 0.003
  t.script = "logic_net"
  t.lg.pins = t.lg.pins or glands(t.box, t.lg.ins or {}, t.lg.outs or {})
  return t
end
local KG = function(kg) return { steel = kg / 1000 } end
for k, t in pairs({
  -- the drum: not set down, laid pin to pin (logic_net) as a power cable is
  sigCable = { label = "Signal Cable", order = 1, snap = "block", box = B(-0.25, 0.25, 0, 0.42, -0.21, 0.21), mass = KG(6), cost = 40, clutter = true,
               wire = { max = 150, kgm = 0.045, perm = 1.2, r = 0.0045, label = "Signal Cable" }, lg = { kind = "wire", pins = {} },
               desc = "2-core 1.5 mm² screened control cable on a reel · LMB makes it off at a pin, LMB on another pin lays it · it hangs and lies like any cable · $1.20 a metre, up to 150 m" },
  -- ── gates: one function to a DIN enclosure, 18 × 22 cm ──
  lgAnd   = { label = "AND Module", order = 10, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(0.9), cost = 90,
              lg = { kind = "and", ins = { "A", "B" }, outs = { "Q" } }, desc = "Q is on while A and B both are" },
  lgOr    = { label = "OR Module", order = 11, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(0.9), cost = 90,
              lg = { kind = "or", ins = { "A", "B" }, outs = { "Q" } }, desc = "Q is on while A or B is (a pin with two wires already ORs them)" },
  lgXor   = { label = "XOR Module", order = 12, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(0.9), cost = 110,
              lg = { kind = "xor", ins = { "A", "B" }, outs = { "Q" } }, desc = "Q is on while exactly one of A and B is · a two-way light switch" },
  lgNot   = { label = "NOT Module", order = 13, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(0.8), cost = 80,
              lg = { kind = "not", ins = { "A" }, outs = { "Q" } }, desc = "Q is on while A is off · fed back into itself it ticks like a clock" },
  lgTimer = { label = "Timer Relay", order = 14, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(1.1), cost = 160,
              lg = { kind = "timer", ins = { "IN" }, outs = { "Q" }, mode = "on", T = 5 },
              desc = "on-delay, off-delay, pulse or clock, 0.5 s to an hour (right-click sets it) · runs on game time, so it keeps time under warp" },
  lgLatch = { label = "Latching Relay", order = 15, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(1.0), cost = 130,
              lg = { kind = "latch", ins = { "S", "R" }, outs = { "Q" } }, desc = "S sets it, R resets it (R wins) · it holds through a power cut and a reload" },
  lgCmp   = { label = "Comparator", order = 16, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(1.0), cost = 150,
              lg = { kind = "cmp", ins = { "A", "B" }, outs = { "Q" }, set = 0.5, mode = "above", hys = 0.02, step = 0.05 },
              desc = "compares the value on A (a sensor's reading) with B's, or with its own setpoint · hysteresis so it doesn't chatter" },
  lgCounter = { label = "Counter Module", order = 17, box = B(-0.09, 0.09, 0, 0.1, -0.11, 0.11), mass = KG(1.0), cost = 140,
              lg = { kind = "counter", ins = { "IN", "R" }, outs = { "Q" }, n = 3 }, desc = "counts IN's pulses; Q once it reaches its preset; R clears it" },
  -- ── sensors: each reads what it is mounted at; Q against its setpoint ──
  lsPress = { label = "Pressure Switch", order = 30, box = B(-0.07, 0.07, 0, 0.11, -0.09, 0.09), mass = KG(0.6), cost = 220,
              lg = { kind = "sensor", sense = "press", outs = { "Q" }, set = 0.9, mode = "above", hys = 0.02, step = 0.05, unit = "atm" },
              desc = "reads the room it faces into (atm) · Q above or below its setpoint" },
  lsGas   = { label = "Gas Analyser", order = 31, box = B(-0.08, 0.08, 0, 0.09, -0.11, 0.11), mass = KG(1.4), cost = 640,
              lg = { kind = "sensor", sense = "gas", gas = "o2", outs = { "Q" }, set = 19, mode = "below", hys = 0.3, step = 0.5, unit = "%" },
              desc = "an electrochemical cell for O2 and an infrared one for CO2 · reads the room's air in % of an atmosphere" },
  lsTemp  = { label = "Temperature Transmitter", order = 32, box = B(-0.06, 0.06, 0, 0.16, -0.08, 0.08), mass = KG(0.8), cost = 260,
              lg = { kind = "sensor", sense = "temp", src = "primary", outs = { "Q" }, set = 600, mode = "above", hys = 5, step = 10, unit = "K" },
              desc = "a thermocouple head · mounted within 8 m of a reactor it reads its primary loop (or the fuel), else the outside air" },
  lsFlow  = { label = "Flow Switch", order = 33, box = B(-0.07, 0.07, 0, 0.1, -0.09, 0.09), mass = KG(0.9), cost = 300,
              lg = { kind = "sensor", sense = "flow", outs = { "Q" }, set = 2.0, mode = "below", hys = 0.1, step = 0.25, unit = "kg/s" },
              desc = "reads the nearest line within 4 m: a reactor loop's coolant flow, or a pipe's (kg/s)" },
  lsLevel = { label = "Level Switch", order = 34, box = B(-0.07, 0.07, 0, 0.1, -0.09, 0.09), mass = KG(0.7), cost = 240,
              lg = { kind = "sensor", sense = "level", outs = { "Q" }, set = 20, mode = "below", hys = 2, step = 5, unit = "%" },
              desc = "the nearest tank, bottle rack or air tank within 4 m, in % full" },
  lsPower = { label = "Battery Monitor", order = 35, box = B(-0.07, 0.07, 0, 0.07, -0.09, 0.09), mass = KG(0.5), cost = 180,
              lg = { kind = "sensor", sense = "battery", outs = { "Q" }, set = 25, mode = "below", hys = 5, step = 5, unit = "%" },
              desc = "its base grid's battery charge in % · shed load before the batteries go flat" },
  lsDose  = { label = "Area Radiation Monitor", order = 36, box = B(-0.08, 0.08, 0, 0.1, -0.1, 0.1), mass = KG(1.6), cost = 900,
              lg = { kind = "sensor", sense = "dose", outs = { "Q" }, set = 5, mode = "above", hys = 0.5, step = 1, unit = "%/h" },
              desc = "the dose rate where it hangs, in % of a lethal dose an hour, walls counted" },
  lsProx  = { label = "Presence Detector", order = 37, box = B(-0.06, 0.06, 0, 0.05, -0.06, 0.06), mass = KG(0.2), cost = 120,
              lg = { kind = "sensor", sense = "prox", outs = { "Q" }, set = 3, mode = "below", hys = 0.3, step = 0.5, unit = "m" },
              desc = "a PIR head: the nearest crew member on foot (m) · Q while someone is within its setpoint" },
  lsDay   = { label = "Daylight Sensor", order = 38, box = B(-0.05, 0.05, 0, 0.07, -0.07, 0.07), mass = KG(0.2), cost = 60,
              lg = { kind = "sensor", sense = "light", outs = { "Q" }, set = 5, mode = "below", hys = 2, step = 5, unit = "%" },
              desc = "a photocell: the sun's height over its horizon as % of overhead light · Q when it's dark" },
  lsReactor = { label = "Reactor Power Monitor", order = 39, box = B(-0.08, 0.08, 0, 0.09, -0.1, 0.1), mass = KG(1.2), cost = 1400, tech = "ember",
              lg = { kind = "sensor", sense = "reactor", src = "power", outs = { "Q" }, set = 105, mode = "above", hys = 1, step = 5, unit = "%" },
              desc = "the nearest plant within 30 m: its power (% of rated) or k · an overpower trip in one box" },
  lsDoor  = { label = "Door Contact", order = 40, box = B(-0.05, 0.05, 0, 0.04, -0.08, 0.08), mass = KG(0.1), cost = 35,
              lg = { kind = "sensor", sense = "door", outs = { "Q" }, set = 50, mode = "above", hys = 5, step = 10, unit = "% open" },
              desc = "a reed contact on the nearest door within 2.5 m · Q while it is open (every door also has its own state terminal)" },
  -- ── inputs ──
  liButton = { label = "Push Button", order = 50, box = B(-0.06, 0.06, 0, 0.1, -0.08, 0.08), mass = KG(0.3), cost = 45,
              lg = { kind = "button", outs = { "Q" }, T = 1.0 }, desc = "a red mushroom button in a yellow box · right-click presses it: a 1 s pulse" },
  liLever = { label = "Lever Switch", order = 51, box = B(-0.06, 0.06, 0, 0.14, -0.09, 0.09), mass = KG(0.5), cost = 55,
              lg = { kind = "lever", outs = { "Q" } }, desc = "a heavy two-position lever · stays where it is thrown" },
  liKeypad = { label = "Keypad", order = 52, box = B(-0.07, 0.07, 0, 0.04, -0.1, 0.1), mass = KG(0.4), cost = 190,
              lg = { kind = "keypad", outs = { "Q" }, T = 3.0, code = "1234" }, desc = "a 12-key pad · the right code gives a 3 s pulse · an Engineer sets the code" },
  -- ── outputs ──
  loLamp  = { label = "Indicator Lamp", order = 60, box = B(-0.05, 0.05, 0, 0.08, -0.05, 0.05), mass = KG(0.15), cost = 30,
              lg = { kind = "lamp", ins = { "IN" }, col = "green" }, desc = "a 22 mm pilot lamp: lit while IN is on · green, amber, red or white (right-click)" },
  loAlarm = { label = "Alarm Beacon", order = 61, box = B(-0.1, 0.1, 0, 0.22, -0.1, 0.1), mass = KG(1.8), cost = 260,
              lg = { kind = "alarm", ins = { "IN" } }, desc = "a rotating red beacon and a klaxon · while IN is on" },
  -- ── radio channels: for runs a cable can't make ──
  lwTx    = { label = "Radio Transmitter", order = 70, box = B(-0.07, 0.07, 0, 0.08, -0.36, 0.09), mass = KG(0.6), cost = 380,
              lg = { kind = "tx", ins = { "IN" }, ch = 1 }, desc = "sends IN on one of 16 channels to every receiver on it within 2 km" },
  lwRx    = { label = "Radio Receiver", order = 71, box = B(-0.07, 0.07, 0, 0.08, -0.36, 0.09), mass = KG(0.6), cost = 380,
              lg = { kind = "rx", outs = { "Q" }, ch = 1 }, desc = "Q while any transmitter on its channel within 2 km is on" },
}) do PIECES[k] = lgp(t) end
-- the ladder controller: a desk with its CRT, its terminal rail at the back
do
  local pins = {}
  for k = 1, 8 do pins[#pins + 1] = { n = "X" .. k, io = "in", x = -0.52 + (k - 1) * 0.06, y = 0.55, z = -0.40 } end
  for k = 1, 8 do pins[#pins + 1] = { n = "Y" .. k, io = "out", x = 0.10 + (k - 1) * 0.06, y = 0.55, z = -0.40 } end
  PIECES.lgPlc = lgp({ label = "Ladder Controller", order = 80, snap = "block", box = B(-0.6, 0.6, 0, 1.45, -0.4, 0.4), mass = KG(95), cost = 4800, vol = 0.5,
    lg = { kind = "plc", pins = pins, screen = { w = 1.1, h = 0.55 } },
    desc = "a small PLC on its desk: 8 inputs, 8 outputs, 8 relays and 16 ladder rungs you edit on its screen · right-click to program it" })
end

-- (S8) the terminals of pieces that were here before: what a cable may drive
-- or read on them. Each sits where its control box would (piece frame).
local function devpins(name, dev, list)
  local P = PIECES[name]
  if not P then return end
  local pins = {}
  for _, q in ipairs(list) do pins[#pins + 1] = { n = q[1], io = q[2], x = q[3], y = q[4], z = q[5] } end
  P.lg = { kind = "device", dev = dev, pins = pins }
end
local function doorpins(name, dev, x, y, z)
  local L = { { "open", "in", x - 0.08, y, z }, { "lock", "in", x, y, z }, { "state", "out", x + 0.08, y, z } }
  if dev == "airlock" then L = { { "cycle", "in", x - 0.12, y, z }, { "lock", "in", x - 0.04, y, z }, { "ready", "out", x + 0.04, y, z }, { "state", "out", x + 0.12, y, z } } end
  devpins(name, dev, L)
end
doorpins("doorWall", "door", -0.55, 1.35, -0.11)
doorpins("doorWallM", "door", 0.55, 1.35, -0.11)
doorpins("doubleDoor", "door", 1.45, 1.35, -0.11)
doorpins("bulkhead", "door", 0.55, 1.35, -0.11)
doorpins("airlockWall", "airlock", 0.55, 1.35, -0.11)
doorpins("habBulkhead", "door", 1.0, 1.5, -0.21)
doorpins("floorHatch", "door", 0.4, 0.2, 0.8)
doorpins("pressHatch", "door", 0.4, 0.2, 0.8)
devpins("lightFitting", "light", { { "on", "in", 0.3, 0.045, 0 } })
devpins("flPump", "pump", { { "run", "in", 0.2, 0.8, 0 } })
devpins("flCharge", "pump", { { "run", "in", 0.3, 1.0, 0 } })
devpins("flValve", "valve", { { "open", "in", 0.08, 0.85, 0 } })
devpins("breaker63", "breaker", { { "close", "in", -0.05, 0.07, 0.25 }, { "tripped", "out", 0.05, 0.07, 0.25 } })
devpins("breaker160", "breaker", { { "close", "in", -0.06, 0.1, 0.36 }, { "tripped", "out", 0.06, 0.1, 0.36 } })
devpins("coolantPump", "rxpump", { { "run", "in", 0.45, 1.2, 0 } })
devpins("reactorConsole", "rxconsole", { { "scram", "in", -0.2, 0.5, -0.43 }, { "setback", "in", -0.1, 0.5, -0.43 }, { "tripped", "out", 0.0, 0.5, -0.43 } })
devpins("o2gen", "machine", { { "run", "in", 0.35, 1.0, -0.3 } })
devpins("scrubber", "machine", { { "run", "in", 0.3, 1.0, -0.25 } })

-- ── LOGISTICS (expansion X5: the quarry, conveyors, tubes, hoppers, silos and
-- the loading chute; scripts/quarry.lua, item_net.lua, logistics.lua;
-- tools/gen_kit_quarry.py; docs/base-building.md §23) ─────────────────────────
-- Every belt and tube port is at BELT_Y (0.8 m) over its piece's ground point,
-- on the 0.5 m grid; a belt's ports are bore "BELT", a tube's "DN150", so a
-- belt never meets a tube. A conveyor's port "a" is where it takes load and
-- "b" where it gives it (R picks which end goes on; its menu reverses it).
--   it = { kind = "post" | "drive" | "belt" | "tube" | "blower" | "hopper" |
--          "silo" | "chute", cap (kg/s a conveyor), len (m), kw (a grid load
--          while it runs), buf / kg (a store's kg), mouth (a chute's spout,
--          piece frame), reach (m to a craft) }
BELT_Y = 0.8
do
  local function bp(name, x, z, nx, nz, role, y) return { name = name, x = x, y = y or BELT_Y, z = z, nx = nx, nz = nz, bore = "BELT", role = role } end
  local function tp(name, x, z, nx, nz, role) return { name = name, x = x, y = BELT_Y, z = z, nx = nx, nz = nz, bore = "DN150", role = role } end
  local function L(t)
    t.section = "LOGISTICS"
    t.mats = { "steel" }
    t.fill = "solid"
    t.vol = t.vol or 0.1
    t.mass = t.mass or { steel = 0.1 }
    if t.it and t.it.kw then t.power = { kind = "aux", use = t.it.kw } end
    return t
  end
  for k, t in pairs({
    qPost   = { label = "Quarry Post", order = 1, snap = "post", box = B(-0.25, 0.25, 0, 3.0, -0.25, 0.25),
                mass = { steel = 0.4 }, cost = 1800, vol = 0.06, it = { kind = "post" },
                desc = "a 300 mm H-column 3 m tall · four on the corners of a rectangle (4 to 32 m a side) and a Quarry Drive beside them make a quarry: the gantry spans them and digs everything inside, 1 m in from the posts, down to 30 m" },
    qDrive  = { label = "Quarry Drive", order = 2, snap = "block", box = B(-1, 1, 0, 2.5, -1, 1),
                mass = { steel = 1.6 }, cost = 14000, vol = 1.2, it = { kind = "drive", buf = 500, kw = 6 },
                ports = { bp("out", 0, 1.0, 0, 1, "any"), tp("tout", 1.0, 0.4, 1, 0, "any") },
                desc = "the quarry's winch, its bucket-wheel head on 30 m of cable, and a 500 kg discharge bin · set within 14 m of four Quarry Posts · its discharge (+Z) meets a belt, its tube port (+X) a tube · 6 kW from the grid while it digs: soil 0.5 m³/s, rock 0.25, the hard ores 0.12" },
    cvBelt2 = { label = "Conveyor 2 m", order = 10, snap = "pipe", box = B(-0.4, 0.4, 0, 0.8, -1, 1),
                mass = { steel = 0.14 }, cost = 900, it = { kind = "belt", cap = 8, len = 2, kw = 0.06 },
                ports = { bp("a", 0, -1, 0, -1, "in"), bp("b", 0, 1, 0, 1, "out") },
                desc = "a 600 mm troughed belt on its stringers and idlers: 8 kg/s, tail (a) to head (b) · conveyors that meet are one line, driven from the grid (0.3 kW per 10 m) · a Signal Cable on its RUN terminal starts and stops the line" },
    cvBelt1 = { label = "Conveyor 1 m", order = 11, snap = "pipe", box = B(-0.4, 0.4, 0, 0.8, -0.5, 0.5),
                mass = { steel = 0.08 }, cost = 520, it = { kind = "belt", cap = 8, len = 1, kw = 0.03 },
                ports = { bp("a", 0, -0.5, 0, -1, "in"), bp("b", 0, 0.5, 0, 1, "out") },
                desc = "a 1 m length of conveyor: 8 kg/s" },
    cvCorner = { label = "Conveyor Corner", order = 12, snap = "pipe", box = B(-0.3, 0.5, 0, 0.8, -0.5, 0.3),
                mass = { steel = 0.09 }, cost = 780, it = { kind = "belt", cap = 8, len = 0.8, kw = 0.03 },
                ports = { bp("a", 0, -0.5, 0, -1, "in"), bp("b", 0.5, 0, 1, 0, "out") },
                desc = "a curved belt through 90° · R picks which way it turns" },
    cvMerge = { label = "Conveyor Merge (T)", order = 13, snap = "pipe", box = B(-0.4, 0.5, 0, 1.1, -0.5, 0.5),
                mass = { steel = 0.1 }, cost = 950, it = { kind = "belt", cap = 8, len = 1, kw = 0.03 },
                ports = { bp("a", 0, -0.5, 0, -1, "in"), bp("c", 0.5, 0, 1, 0, "in"), bp("b", 0, 0.5, 0, 1, "out") },
                desc = "a side feed onto a belt: two lines into one, together never more than the one belt's 8 kg/s" },
    cvRamp  = { label = "Conveyor Ramp 15°", order = 14, snap = "pipe", box = B(-0.4, 0.4, 0, 1.3, -1, 1),
                mass = { steel = 0.16 }, cost = 1100, it = { kind = "belt", cap = 5, len = 2.06, kw = 0.08 },
                ports = { bp("a", 0, -1, 0, -1, "in"), bp("b", 0, 1, 0, 1, "out", BELT_Y + 0.5) },
                desc = "an inclined belt rising 0.5 m in 2 m: 5 kg/s up the slope (a line is as fast as its slowest piece)" },
    tbTube2 = { label = "Transfer Tube 2 m", order = 20, snap = "pipe", box = B(-0.15, 0.15, 0, 0.94, -1, 1),
                mass = { steel = 0.036 }, cost = 300, it = { kind = "tube", cap = 2, len = 2 },
                ports = { tp("a", 0, -1, 0, -1, "in"), tp("b", 0, 1, 0, 1, "out") },
                desc = "a DN150 pneumatic tube on its stands · sealed, so it works in vacuum, in zero-g, any way up · 20 kg capsules every 10 s: 2 kg/s · a line needs a Tube Blower" },
    tbTube1 = { label = "Transfer Tube 1 m", order = 21, snap = "pipe", box = B(-0.15, 0.15, 0, 0.94, -0.5, 0.5),
                mass = { steel = 0.018 }, cost = 180, it = { kind = "tube", cap = 2, len = 1 },
                ports = { tp("a", 0, -0.5, 0, -1, "in"), tp("b", 0, 0.5, 0, 1, "out") },
                desc = "a 1 m length of transfer tube" },
    tbElbow = { label = "Transfer Tube Elbow", order = 22, snap = "pipe", box = B(-0.15, 0.5, 0, 0.94, -0.5, 0.15),
                mass = { steel = 0.02 }, cost = 220, it = { kind = "tube", cap = 2, len = 0.8 },
                ports = { tp("a", 0, -0.5, 0, -1, "in"), tp("b", 0.5, 0, 1, 0, "out") },
                desc = "a 0.5 m radius bend · R picks which way" },
    tbBlower = { label = "Tube Blower", order = 23, snap = "pipe", box = B(-0.45, 0.45, 0, 1.1, -0.5, 0.5),
                mass = { steel = 0.09 }, cost = 2600, it = { kind = "blower", cap = 2, len = 1, kw = 2.2 },
                ports = { tp("a", 0, -0.5, 0, -1, "in"), tp("b", 0, 0.5, 0, 1, "out") },
                desc = "a side-channel blower in the line: it pushes the capsules at 6 m/s round a sealed loop with its own air · 2.2 kW · one a tube line" },
    lgHopper = { label = "Hopper", order = 30, snap = "block", box = B(-1, 1, 0, 2.6, -1, 1),
                mass = { steel = 1.6 }, cost = 5200, vol = 1.0, it = { kind = "hopper", kg = 4000 },
                ports = { bp("in", 0, -1, 0, -1, "any"), bp("out", 0, 1, 0, 1, "any"), tp("tl", -1, 0, -1, 0, "any"), tp("tr", 1, 0, 1, 0, "any") },
                desc = "a 2 × 2 m bin on four legs: 4,000 kg of anything · belts and tubes in and out at its ports; hands take from it too (right-click)" },
    lgSilo  = { label = "Silo", order = 31, snap = "block", box = B(-1.1, 1.1, 0, 6.6, -1.1, 1.1),
                mass = { steel = 1.4 }, cost = 9500, vol = 1.0, it = { kind = "silo", kg = 8000 },
                ports = { bp("in", 0, -1.1, 0, -1, "any"), bp("out", 0, 1.1, 0, 1, "any"), tp("tl", -1.1, 0, -1, 0, "any"), tp("tr", 1.1, 0, 1, 0, "any") },
                desc = "a 2 m steel silo, 8,000 kg of ONE material (the first in, or the one set in its menu) · a bucket elevator fills it from its inlet (−Z) · a run can load from it" },
    lgChute = { label = "Loading Chute", order = 32, snap = "block", box = B(-0.5, 0.4, 0, 3.3, -0.6, 2.4),
                mass = { steel = 0.45 }, cost = 4200, vol = 0.3, it = { kind = "chute", mouth = { 0, 1.85, 2.2 }, reach = 6 },
                ports = { bp("in", 0, -0.6, 0, -1, "any"), tp("tin", -0.5, 0, -1, 0, "any") },
                desc = "a mast and boom with a telescoping spout · what its line brings goes into the hold of the craft under the spout: one held on a stand, or parked within 6 m · a run loads from what feeds it" },
    -- (the gantry's moving parts: logistics.lua draws them; never in the catalogue)
    qBridge = { label = "Quarry Bridge", order = 90, snap = "block", box = B(-0.5, 0.5, 0, 0.58, -0.25, 0.25), hidden = true, clutter = true,
                mass = { steel = 0.06 }, cost = 10, it = { kind = "visual" } },
    qCable  = { label = "Quarry Hoist Cable", order = 91, snap = "block", box = B(-0.05, 0.05, -1, 0, -0.12, 0.12), hidden = true, clutter = true,
                mass = { steel = 0.003 }, cost = 10, it = { kind = "visual" } },
    qHead   = { label = "Quarry Cutter Head", order = 92, snap = "block", box = B(-0.5, 0.62, -0.1, 1.6, -0.7, 0.7), hidden = true, clutter = true,
                mass = { steel = 1.1 }, cost = 10, it = { kind = "visual" } },
  }) do PIECES[k] = L(t) end
  -- a belt's RUN terminal on its stringer (S8): off stops its whole line
  for _, k in ipairs({ "cvBelt2", "cvBelt1", "cvCorner", "cvMerge", "cvRamp", "tbBlower" }) do
    devpins(k, "belt", { { "run", "in", 0.36, 0.7, 0 } })
  end
end

-- ── FITTINGS: VAB parts placed live (S2) ─────────────────────────────────────
-- The registry figures they carry are parts_registry's (and parts_aero's,
-- parts_nuclear's), copied here because the world scene carries no registry;
-- smoke_kit checks every copied field against the real one.
LIVE = {
  pod     = { prefab = "PartPod", label = "Pod Mk1", sym = "z", h = 0.80, rx = 0.50, rz = 0.50, mass = 1.3, cost = 500, kind = "crewed", strength = 600,
              mods = { { type = "command", crew = 1, draw = 0.05 }, { type = "wheel", torque = 1.0, draw = 0.5 }, { type = "battery", ec = 40 } },
              seats = { { x = 0.0, y = -0.22, z = 0.16, yaw = 1.5708 } },
              hatch = { x = 0.47, y = -0.02, z = 0.0, nx = 1, ny = 0, nz = 0 }, iva = "IvaPodMk1" },
  podMk2  = { prefab = "PartPodMk2", label = "Pod Mk2", sym = "z", h = 1.15, rx = 0.50, rz = 0.50, mass = 2.4, cost = 1400, kind = "crewed", strength = 720,
              mods = { { type = "command", crew = 3, draw = 0.08 }, { type = "wheel", torque = 1.6, draw = 0.6 }, { type = "battery", ec = 80 } },
              seats = { { x = 0.0, y = -0.28, z = 0.22, yaw = 1.5708 }, { x = -0.66, y = -0.28, z = 0.16, yaw = 1.8708 },
                        { x = 0.66, y = -0.28, z = 0.16, yaw = 1.2708 } },
              hatch = { x = 0.49, y = -0.06, z = 0.0, nx = 1, ny = 0, nz = 0 }, iva = "IvaPodMk2" },
  cabin   = { prefab = "PartCabin", label = "Crew Cabin", sym = "z", h = 1.30, rx = 0.50, rz = 0.50, mass = 1.6, cost = 900, kind = "structural", strength = 650,
              mods = { { type = "cabin", crew = 4 } },
              seats = { { x = -0.44, y = -0.3, z = 0.64, yaw = 1.5708 }, { x = 0.44, y = -0.3, z = 0.64, yaw = 1.5708 },
                        { x = 0.44, y = -0.3, z = -0.64, yaw = -1.5708 }, { x = -0.44, y = -0.3, z = -0.64, yaw = -1.5708 } },
              hatch = { x = 0.51, y = -0.1, z = 0.0, nx = 1, ny = 0, nz = 0 }, iva = "IvaCabin" },
  seat    = { prefab = "PartSeat", label = "Command Seat", h = 1.30, rx = 0.45, rz = 0.30, mass = 0.025, cost = 40, kind = "crewed", seat = true, strength = 320,
              mods = { { type = "command", crew = 1, draw = 0.0, seat = true } },
              seats = { { x = 0, y = 0, z = 0, yaw = 0, open = true } } },
  cockpit = { prefab = "PartCockpit", label = "Swift Cockpit", h = 2.20, rx = 0.50, rz = 0.50, mass = 0.35, cost = 700, kind = "crewed", strength = 600,
              af = "cockpit cdF=0.1 cd=0.45",
              mods = { { type = "command", crew = 1, draw = 0.04 }, { type = "wheel", torque = 0.12, draw = 0.1 }, { type = "battery", ec = 60 } },
              seats = { { x = 0.0, y = 0.1, z = 0.05, yaw = 0 } },
              hatch = { x = 0.0, y = 0.2, z = -0.55, nx = 0, ny = 0, nz = -1 }, iva = "IvaCockpit",
              -- (a jet cockpit's nose is its +Y: placed on a floor it lies on its belly)
              lay = true },
  locker  = { prefab = "PartLocker", label = "Stowage Locker", h = 0.50, rx = 0.30, rz = 0.30, mass = 0.03, cost = 40, kind = "structural", store = 80, strength = 300 },
  lockerS = { prefab = "PartLockerS", label = "Small Locker", h = 0.35, rx = 0.20, rz = 0.20, mass = 0.012, cost = 25, kind = "structural", store = 40, vol = 50, strength = 200 },
  light   = { prefab = "PartLight", label = "Floodlight", h = 0.30, rx = 0.15, rz = 0.15, mass = 0.004, cost = 20, kind = "structural", strength = 60,
              mods = { { type = "light", draw = 0.2 } } },
  battery = { prefab = "PartBattery", label = "Battery", h = 1.00, rx = 0.50, rz = 0.50, mass = 0.1, cost = 60, kind = "structural", power = true, ec = 150, strength = 350,
              mods = { { type = "battery", ec = 150 } } },
  solar   = { prefab = "PartSolar", label = "Solar Panel", h = 0.70, rx = 0.45, rz = 0.06, mass = 0.012, cost = 600, kind = "structural", solar = true, gen = 1.0, strength = 80,
              mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } },
  rtg     = { prefab = "PartRTG", label = "Isotope Cell", h = 0.64, rx = 0.36, rz = 0.32, mass = 0.045, cost = 2400, kind = "structural", strength = 120,
              mods = { { type = "rtg", gen = 0.5, heat = 0.25, sink = 0.6, cap = 30, half = 1440000 } } },
}
-- What a live part is to the base grid, by its record (base_grid.lua):
-- the same figures as its electronics module. COUNTED ONCE (S2 follow-up):
-- a battery, panel, cell or floodlight placed live is the grid's, and the
-- structure vessel carries it without that module (struct_live.GRID_MODS); a
-- crewed part's command draw is a grid load too, and the vessel's own cells
-- are kept topped up from the grid while the grid is up.
LIVE_POWER = {
  battery = { kind = "store", cap = 150, eff = 0.92, fill = 0.5 },
  solar   = { kind = "solar", gen = 1.0, lift = 0.5 },
  rtg     = { kind = "rtg", gen = 0.5 },
  light   = { kind = "load", use = 0.2 },
  pod     = { kind = "load", use = 0.05 },
  podMk2  = { kind = "load", use = 0.08 },
  cockpit = { kind = "load", use = 0.04 },
}
LIVE_ORDER = { "pod", "podMk2", "cabin", "seat", "cockpit", "locker", "lockerS", "light", "battery", "solar", "rtg" }
-- (which registry each copy is checked against: smoke_kit)
LIVE_SRC = { cockpit = "parts_aero", rtg = "parts_nuclear" }

-- ── ids ─────────────────────────────────────────────────────────────────────
local function cap1(s) return s:sub(1, 1):upper() .. s:sub(2) end
function prefabOf(piece, mat) return "Kit" .. cap1(piece) .. "_" .. mat end
function split(id)
  if type(id) ~= "string" then return nil end
  local a, b = id:match("^([%w]+)%.([%w]+)$")
  return a, b
end
function idOf(piece, mat) return piece .. "." .. mat end
function isKit(id) local a, b = split(id); return a ~= nil and (PIECES[a] ~= nil or a == "vab") end

-- the material a piece takes: the one asked for if it comes in it, else its first
function matFor(piece, want)
  local P = PIECES[piece]
  if not P then return nil end
  for _, m in ipairs(P.mats) do if m == want then return m end end
  return P.mats[1]
end

function massOf(piece, mat)
  local P = PIECES[piece]
  if P.mass and P.mass[mat] then return P.mass[mat] end
  local f = (P.fillk and P.fillk[mat]) or (FILL[P.fill] and FILL[P.fill][mat]) or 1.0
  return P.vol * MATS[mat].kgm3 / 1000 * f
end
function costOf(piece, mat)
  local P = PIECES[piece]
  if P.costs and P.costs[mat] then return P.costs[mat] end
  return math.floor(P.cost * (COSTK[mat] or 1) / 10 + 0.5) * 10
end

cache = {}
local function resolve(piece, mat)
  local P = PIECES[piece]
  local b = P.box
  local M = MATS[mat]
  local hx, hy, hz = (b[2] - b[1]) / 2, (b[4] - b[3]) / 2, (b[6] - b[5]) / 2
  local d = {
    kit = true, piece = piece, mat = mat, prefab = prefabOf(piece, mat),
    label = P.label, matLabel = M.label, section = P.section, snap = P.snap, box = b,
    h = b[4] - b[3], rx = hx, rz = hz, mass = massOf(piece, mat), cost = costOf(piece, mat),
    kind = "structural", fieldOnly = true, seat = 0,
    -- (the footprint as the step-5 rules read it: centred, its base at y0)
    half = { x = hx, y = hy, z = hz }, base0 = b[3],
    slope = 0.6, onDeck = P.snap ~= "slab", grade = P.grade or 1.2, footPad = P.footPad or 0.15, skirt = P.skirt,
    tile = P.tile, deck = P.deck, deckTop = P.deckTop, slopeZ = P.slopeZ, triangle = P.triangle,
    door = P.door, light = P.light, screen = P.screen, switch = P.switch, life = P.life,
    sym = P.sym or "x", mirror = P.mirror, hidden = P.hidden,
    -- (S4) character: films, clutter, signs, the emblem, a lamp's own lens;
    -- what takes paint on two faces and what gathers dust
    film = P.film, clutter = P.clutter, grime = P.grime, sign = P.sign, emblem = P.emblem, lens = P.lens,
    faces2 = FACES2[piece] == true, exterior = EXTERIOR[P.section] == true, noPaint = P.film or (P.section == "LOGIC") or nil,
    -- (S5) the power network's gear
    netgear = P.netgear, pole = P.pole, cableAt = P.cableAt,
    -- (S6) the reactor's components: the core's lattice, ports, the loops' gear
    nuclear = P.nuclear, ports = P.ports, pipe = P.pipe, pump = P.pump, press = P.press, hx = P.hx, turbine = P.turbine,
    reject = P.reject, console = P.console, rad = P.rad, tech = P.tech,
    -- (S7) the fluid network's pieces; an equalise valve
    fl = P.fl, eqv = P.eqv,
    -- (S8) logic: its pins and what it is to the signals; the Signal Cable's drum
    lg = P.lg, wire = P.wire,
    -- (X1) a survey instrument
    survey = P.survey,
    -- (X5) a logistics piece: the quarry, conveyors, tubes, stores, the chute
    it = P.it,
    script = P.script or ((P.door or P.light or P.screen or P.switch or P.sign or P.emblem) and "kit_live" or nil),
    seals = (P.seals == "door" or P.seals == "ring" or P.seals == "y" or P.seals == "z") and P.seals or nil,
    u = M.u, matk = M.k, strength = M.strength,
    desc = string.format("%s · %s · %.2f t", P.desc or "", M.label, massOf(piece, mat)),
  }
  if P.seals and not M.seal then d.seals = nil end
  -- shielding by record (thermal.shieldFactor): blocks and lead name theirs;
  -- a concrete or regocrete wall or floor lets its material's share through
  if P.shieldk then d.shield = { k = P.shieldk }
  elseif (mat == "concrete" or mat == "regocrete") and (P.snap == "wall" or P.snap == "floor" or P.snap == "slab") then
    d.shield = { k = M.k }
  end
  if d.light then d.power = { kind = "load", use = d.light.draw } end
  if P.fl and P.fl.kind == "pump" then d.power = { kind = "aux", use = P.fl.kw } end
  if P.use then d.power = { kind = "load", use = P.use } end
  if P.power then d.power = P.power end
  return d
end

-- (playtest 11-09) ANY VAB part placed live through the Base Hub's builder:
-- its registry figures, learned when it was placed (base_hub.commit) and kept
-- in the save (`vabdefs`), because the world scene carries no registry. Its
-- box is centred on its origin (seat 0): the hub stores its centre.
VABDEFS = {}
local LEARN_KEEP = { "prefab", "label", "h", "rx", "rz", "mass", "cost", "kind", "store", "mods", "af", "proc" }
function learnVab(id, rec)
  if type(id) ~= "string" or type(rec) ~= "table" or LIVE[id] then return end
  local d = {}
  for _, k in ipairs(LEARN_KEEP) do if type(rec[k]) ~= "table" then d[k] = rec[k] end end
  VABDEFS[id] = d
  if cache then cache["vab." .. id] = nil end
end
function vabDefs() return VABDEFS end
local function learned(id)
  local d = VABDEFS[id]
  if d then return d end
  local all = save and save.get and save.get("vabdefs")
  if type(all) == "table" and type(all[id]) == "table" then VABDEFS[id] = all[id]; return all[id] end
  return nil
end
local function learned_def(id)
  local L = learned(id)
  if not L then return nil end
  local hx, hy, hz = math.max(0.05, L.rx or 0.5), math.max(0.05, (L.h or 1) / 2), math.max(0.05, L.rz or L.rx or 0.5)
  return {
    kit = true, live = true, vab = id, piece = "vab", mat = id, prefab = L.prefab, label = L.label or id, section = "FITTINGS",
    snap = "block", box = { -hx, hx, -hy, hy, -hz, hz }, h = 2 * hy, rx = hx, rz = hz, mass = L.mass or 0.1, cost = L.cost or 0,
    kind = "structural", fieldOnly = true, seat = 0, half = { x = hx, y = hy, z = hz }, base0 = -hy,
    slope = 0.6, onDeck = true, grade = 1.0, footPad = 0.15, reg = L, hub = true,
    desc = string.format("%s · live: built from the Base Hub", L.label or id), sym = "x",
  }
end

local function live_def(id)
  local L = LIVE[id]
  if not L then return learned_def(id) end
  local lay = L.lay == true
  -- the box it stands in, on the ground point: upright, or lying on its belly
  -- (a cockpit: its +Y nose along the structure's front)
  local hx, hy, hz = L.rx, L.h / 2, L.rz
  if lay then hy, hz = L.rz, L.h / 2 end
  local d = {
    kit = true, live = true, vab = id, piece = "vab", mat = id, prefab = L.prefab, label = L.label, section = "FITTINGS",
    snap = "block", box = { -hx, hx, 0, 2 * hy, -hz, hz }, h = 2 * hy, rx = hx, rz = hz, mass = L.mass, cost = L.cost,
    kind = "structural", fieldOnly = true, seat = hy, half = { x = hx, y = hy, z = hz }, base0 = 0,
    slope = 0.6, onDeck = true, grade = 1.0, footPad = 0.15, lay = lay, reg = L,
    desc = string.format("%s · live: %s", L.label, (L.seats and "you can sit in it") or (L.store and "it opens") or "it works here"),
    power = LIVE_POWER[id], sym = L.sym or "x",
  }
  return d
end

-- partInfo for "<piece>.<mat>" and "vab.<id>" (nil for anything else).
function partInfo(id)
  local d = cache[id]
  if d ~= nil then return d or nil end
  local a, b = split(id)
  if a == "vab" then
    d = live_def(b)
    -- (a hub-placed part not learned yet: asked again, not cached as nothing)
    if not d then return nil end
  elseif a and PIECES[a] and MATS[b] then
    local ok = false
    for _, m in ipairs(PIECES[a].mats) do if m == b then ok = true end end
    d = ok and resolve(a, b) or nil
  end
  cache[id] = d or false
  return d
end

-- The kit's sections for the parts column, at material `mat` (each piece
-- in that material, or its own first one). → { { title, ids } }
function catalogue(mat)
  local by = {}
  for _, s in ipairs(SECTION_ORDER) do by[s] = {} end
  local names = {}
  for k, P in pairs(PIECES) do if not P.hidden then names[#names + 1] = k end end
  table.sort(names, function(a, b)
    local pa, pb = PIECES[a], PIECES[b]
    if pa.section ~= pb.section then return a < b end
    return (pa.order or pa.cost) < (pb.order or pb.cost)
  end)
  for _, k in ipairs(names) do
    local s = by[PIECES[k].section]
    s[#s + 1] = idOf(k, matFor(k, mat or "steel"))
  end
  for _, id in ipairs(LIVE_ORDER) do by.FITTINGS[#by.FITTINGS + 1] = "vab." .. id end
  local out = {}
  for _, s in ipairs(SECTION_ORDER) do if #by[s] > 0 then out[#out + 1] = { title = s, ids = by[s] } end end
  return out
end

-- Every prefab the kit names (the generator writes them; smoke_kit checks).
function allPrefabs()
  local out = {}
  for k, P in pairs(PIECES) do for _, m in ipairs(P.mats) do out[#out + 1] = prefabOf(k, m) end end
  table.sort(out)
  return out
end

-- The next material in MAT_ORDER (the M key).
function nextMat(mat)
  for i, m in ipairs(MAT_ORDER) do if m == mat then return MAT_ORDER[i % #MAT_ORDER + 1] end end
  return MAT_ORDER[1]
end
