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

SECTION_ORDER = { "FOUNDATION", "FLOOR", "WALL", "ROOF", "FRAME", "HAB", "SHIELD", "UTILITY", "LIFE", "FITTINGS" }

MATS = {
  steel     = { label = "Steel", kgm3 = 7850, strength = 180, k = 0.9, u = 1.4, seal = true,
                desc = "sandwich panel · light, strong, quick" },
  concrete  = { label = "Concrete", kgm3 = 2300, strength = 400, k = 0.35, u = 0.6, seal = true,
                desc = "precast · heavy, cheap, shields" },
  regocrete = { label = "Regocrete", kgm3 = 2000, strength = 320, k = 0.40, u = 0.7, seal = true, offworld = true,
                desc = "regolith concrete mixed on site · the cheapest wall there is" },
  glass     = { label = "Glass", kgm3 = 2500, strength = 60, k = 0.95, u = 2.8, seal = true, blend = true,
                desc = "laminated pane in a steel frame · light comes in" },
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
                desc = "a pressure door · with a second door it makes an airlock: interlocked, it cycles" },
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
                light = { color = { 1.0, 0.86, 0.66 }, intensity = 2.4, range = 9, draw = 0.03 },
                desc = "a 3,200 K strip light · right-click switches it · draws 0.03 EC/s" },
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
  -- ── LIFE (S3: a room's air, scripts/room_air.lua; on the base grid) ──
  -- rates in atm·m³ a second: a crew member breathes 6.8e-6 of O2 and makes
  -- 5.85e-6 of CO2 (0.84 and 1.0 kg a day); each machine serves four.
  scrubber  = { label = "CO2 Scrubber", section = "LIFE", snap = "block", box = B(-0.35, 0.35, 0, 1.4, -0.25, 0.25),
                mats = { "steel" }, vol = 0.49, fill = "solid", cost = 2600, fillk = { steel = 0.022 },
                life = { scrub = 2.4e-5 }, use = 0.4,
                desc = "amine-bed CO2 scrubber for four crew · 0.4 EC/s from the base grid" },
  o2gen     = { label = "Oxygen Generator", section = "LIFE", snap = "block", box = B(-0.45, 0.45, 0, 1.6, -0.3, 0.3),
                mats = { "steel" }, vol = 0.86, fill = "solid", cost = 5200, fillk = { steel = 0.03 },
                life = { o2 = 2.8e-5 }, use = 1.5,
                desc = "an electrolyser: O2 for four crew from its water · 1.5 EC/s from the base grid" },
  airTank   = { label = "Air Tank Rack", section = "LIFE", snap = "block", box = B(-0.6, 0.6, 0, 1.8, -0.25, 0.25),
                mats = { "steel" }, vol = 1.08, fill = "solid", cost = 1800, fillk = { steel = 0.04 },
                life = { store = 60, flow = 0.25, price = 4 },
                desc = "three 200 bar cylinders of air on a regulator · fills a room to 1 atm · 60 m³" },
}

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

local cache = {}
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
    script = (P.door or P.light or P.screen or P.switch) and "kit_live" or nil,
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
  if P.use then d.power = { kind = "load", use = P.use } end
  return d
end

local function live_def(id)
  local L = LIVE[id]
  if not L then return nil end
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
  if a == "vab" then d = live_def(b)
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
