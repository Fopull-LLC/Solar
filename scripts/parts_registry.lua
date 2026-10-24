-- PARTS_REGISTRY — every part the builder knows: its registry entry (REG),
-- the line under its name on the catalogue card (DESC) and the order the
-- catalogue shows it in (CATALOGUE).
--
-- Owner: WP3 (attachment and frame parts), docs/builder-design.md §11.2.
-- Moved here VERBATIM from builder.lua on day 0 (§11.1). A pure rulebook
-- script on the "PartsRegistry" manager node of scenes/builder.ron:
--   * no scene access — nothing here touches nodes, input or the camera;
--   * its globals are its API (below);
--   * it loads from disk in a luajit test, like electronics.lua
--     (tests/smoke_parts_registry.lua).
--
-- The builder reads it with findScript("parts_registry") and never copies it,
-- so the data lives in exactly one place:
--
--   REG[id]                 the entry (prefab, label, h, rx, rz, mass, cost, top,
--                           bottom, kind, side, radial_orient, axial_out,
--                           strength, maxq, thrust, ve, fuel, wheel, mods, desc…)
--   DESC[id]                the catalogue card's line (also copied onto REG[id].desc)
--   CATALOGUE               { { "SECTION", { ids… } }, … } in panel order
--   registryIds()           every id in REG, sorted
--   catalogue()             { { title, ids }, … } with ids missing from REG dropped
--   partInfo(id)            REG[id] (nil if unknown)
--   sizeOf(def, size)       { mass, cost, strength, rx, rz, h } of a part at a
--                           procedural size (drawn members, panels, the Brace)
--   PROFILES                drawn-member profiles (per-metre figures)
--   extend(provider)        let another rulebook add parts: calls
--                           provider.register(REG, CATALOGUE) once per provider
--                           and returns how many it added. This is the hook for
--                           the aero agent's parts_aero.lua (`register(REG,
--                           CATALOGUE)`); nothing calls it yet.
--
-- Wheel settings (WCFG_*), staging and every placement rule stay in builder.lua.

-- ── Part registry (builder-side only; blueprints embed everything) ──────────
-- h = FULL visual stack height (measured from the mesh AABB × prefab scale,
-- so stacked parts sit flush); rx/rz = half-widths for overlap tests.
-- side = true exposes 4 radial attach nodes on the part's flanks.
-- mass = the part's DRY mass in tonnes. A tank's propellant is on top of it:
-- `fuel` units of FUEL_T_PER_UNIT tonnes each, so a full tank is heavy and an
-- empty one light, and the craft lightens as it burns (builder.lua BALANCE).
-- thrust (kN) and ve (exhaust velocity, m/s) are an engine's figures on the
-- REFERENCE world as rating version 2 built them (version 3's vacuum figures
-- and sea-level share are in RATED, below the registry); the catalogue is built once per save for its home world
-- (builder.lua `rating`) and every card, readout and flight uses those numbers.
-- strength = the load (kN) this part's attachment to its parent takes before it
-- gives — the joint the flight's stress model loads with the mass hanging off
-- it times what the craft is doing (thrust, drag, a canopy snatch, a tumble).
-- maxq = dynamic pressure (kPa) the part itself takes (default 80; aero parts
-- more). Both ride in the blueprint; vessel_controller has kind-based fallbacks
-- for builds saved before they existed.
REG = {
  -- ELECTRONICS (`mods`): what a part does electrically, as modules the
  -- electronics rulebook (scripts/electronics.lua) knows — supply, storage,
  -- demand, antennas, and the ACTIONS each one offers the action-group editor.
  -- Engines, decouplers, chutes, legs, RCS and ports get theirs from their flags
  -- (electronics.deriveMods), so only the electrical parts spell them out.
  -- Figures are EC (charge) and EC/s; antenna power is metres (two antennas
  -- reach sqrt(P1·P2) — the ground station is 400 km of power, so from home:
  -- a probe core's internal antenna ≈ 6 km (the home world and its moons), the
  -- whip ≈ 30 km, the relay dish ≈ 300 km (the home system), the deep space
  -- dish ≈ 2,400 km (the next star). Craft to craft they reach much less.)
  pod       = { prefab = "PartPod",       label = "Pod Mk1",      h = 0.80, rx = 0.50, rz = 0.50, mass = 1.3,  cost = 400, top = true,  bottom = true,  kind = "crewed", side = true, strength = 600,
                mods = { { type = "command", crew = 1, draw = 0.05 }, { type = "wheel", torque = 1.0, draw = 0.5 },
                         { type = "battery", ec = 40 } } },
  -- COMMAND SEAT: an open chair for one, KSP's external seat. It commands the
  -- craft like a pod (the crew in it IS the pilot) when it is the only crewed
  -- part aboard, with no reaction wheel and no battery of its own — the craft
  -- brings those. Bolt it to a rover deck, a lander's flank, anywhere; walk up
  -- and press F to sit, F again to get off. The crew stays in view, seated.
  -- It faces its +X (a rover's front). h is the whole chair: base plate to
  -- headrest; its centre is where the rider's hips sit.
  seat      = { prefab = "PartSeat",      label = "Command Seat", h = 1.30, rx = 0.45, rz = 0.30, mass = 0.05, cost = 160, top = false, bottom = true,  kind = "crewed", seat = true, strength = 320,
                mods = { { type = "command", crew = 1, draw = 0.0, seat = true } } },
  -- PROBE CORE: an uncrewed command part. It flies a craft with nobody aboard —
  -- but only while it has POWER and a comms PATH home (its own little internal
  -- antenna reaches the ground station from around the home world and its
  -- moons; past that it needs a real antenna, or a relay). No link, no control.
  probe     = { prefab = "PartProbe",     label = "Probe Core",   h = 0.42, rx = 0.42, rz = 0.42, mass = 0.12, cost = 450, top = true,  bottom = true,  kind = "probe", side = true, strength = 380,
                mods = { { type = "command", crew = 0, draw = 0.06 }, { type = "wheel", torque = 0.6, draw = 0.35 },
                         { type = "battery", ec = 50 }, { type = "antenna", power = 100, rate = 1, draw = 0.02 } } },
  nose      = { prefab = "PartNose",      label = "Nose Cone",    h = 0.90, rx = 0.50, rz = 0.50, mass = 0.08, cost = 50,  top = false, bottom = true,  kind = "structural", aero = true, strength = 300, maxq = 120 },
  chute     = { prefab = "PartChute",     label = "Parachute",    h = 0.34, rx = 0.22, rz = 0.22, mass = 0.08, cost = 80,  top = false, bottom = true,  kind = "canvas", chute = true, side = true, strength = 150 },
  tankS     = { prefab = "PartTankS",     label = "FT-S Tank",    h = 1.00, rx = 0.50, rz = 0.50, mass = 0.2,  cost = 120, top = true,  bottom = true,  kind = "tank", fuel = 80,  side = true, strength = 450 },
  tankM     = { prefab = "PartTankM",     label = "FT-M Tank",    h = 1.50, rx = 0.50, rz = 0.50, mass = 0.35, cost = 220, top = true,  bottom = true,  kind = "tank", fuel = 160, side = true, strength = 650 },
  engineS   = { prefab = "PartEngineS",   label = "Sputter",      h = 1.30, rx = 0.90, rz = 0.90, mass = 0.45, cost = 150, top = true,  bottom = true,  kind = "engine", thrust = 35,  ve = 160, strength = 500 },
  engineM   = { prefab = "PartEngineM",   label = "Anvil",        h = 1.60, rx = 0.90, rz = 0.90, mass = 0.9,  cost = 380, top = true,  bottom = true,  kind = "engine", thrust = 85,  ve = 173, strength = 800 },
  -- A fin is a SIDE-MOUNT blade: no axial nodes (never centred), not a side
  -- host itself — it can only attach to another part's flank, where it self-
  -- orients to point outward. Ring it with X symmetry for a proper fin set.
  fins      = { prefab = "PartFins",      label = "Aero Fin",     h = 0.95, rx = 0.35, rz = 0.03, mass = 0.04, cost = 35, top = false, bottom = false, kind = "structural", aero = true, radial_orient = true, strength = 200, maxq = 100 },
  battery   = { prefab = "PartBattery",   label = "Battery",      h = 1.00, rx = 0.50, rz = 0.50, mass = 0.1,  cost = 130, top = true,  bottom = true,  kind = "structural", power = true, ec = 150, side = true, strength = 350,
                mods = { { type = "battery", ec = 150 } } },
  -- Solar panel: a RADIAL blade (mounts on a flank like a fin, self-orients
  -- outward) that EXTENDS in flight (the Deploy group, U) and charges the
  -- batteries while the sun is on it. It tracks about its own long axis, so it
  -- loses output only as the sun swings toward that axis — and nothing at all in
  -- a planet's shadow. gen = EC/s at home-orbit sunlight (more nearer the star).
  solar     = { prefab = "PartSolar",     label = "Solar Panel",  h = 0.70, rx = 0.45, rz = 0.06, mass = 0.05, cost = 200, top = false, bottom = false, kind = "structural", solar = true, gen = 1.0, radial_orient = true, strength = 80,
                mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } },
  -- ANTENNAS. The whip is OMNI and short: it reaches home from the near planets
  -- and talks craft to craft over tens of km, folded for launch. The dishes are
  -- DIRECTIONAL — they extend, swing to face whoever they're talking to, draw
  -- real power while out — and RELAY: a craft carrying one passes everybody
  -- else's signal on, which is how a web of satellites gets you home from
  -- behind a moon or from the next star.
  antenna   = { prefab = "PartAntenna",   label = "Comm Whip",    h = 0.90, rx = 0.12, rz = 0.12, mass = 0.01, cost = 90,  top = false, bottom = false, kind = "structural", radial_orient = true, strength = 60,
                mods = { { type = "antenna", power = 2250, rate = 4, draw = 0.12, omni = true },
                         { type = "deploy", anim = "whip" } } },
  dish      = { prefab = "PartDish",      label = "Relay Dish",   h = 0.80, rx = 0.40, rz = 0.40, mass = 0.08, cost = 260, top = true,  bottom = true,  kind = "structural", comms = true, side = true, strength = 100,
                mods = { { type = "antenna", power = 2.25e5, relay = true, dish = true, rate = 12, draw = 0.6 },
                         { type = "deploy", anim = "dish" } } },
  dishL     = { prefab = "PartDishL",     label = "Deep Space Dish", h = 1.20, rx = 0.60, rz = 0.60, mass = 0.25, cost = 1200, top = true, bottom = true, kind = "structural", comms = true, side = true, strength = 160,
                mods = { { type = "antenna", power = 1.44e7, relay = true, dish = true, rate = 40, draw = 1.6 },
                         { type = "deploy", anim = "dish" } } },
  -- RELAY BEACON (comms, electronics.COMMS.beacon): the cheap ground relay the
  -- crew plants by hand, as a part. A low-power relay that is always on: on a
  -- lander it carries the network a few hundred metres over the ground.
  beacon    = { prefab = "PartBeacon",    label = "Relay Beacon", h = 4.20, rx = 0.35, rz = 0.35, mass = 0.02, cost = 80, top = false, bottom = true,  kind = "structural", strength = 60,
                mods = { { type = "antenna", power = 1500, relay = true, rate = 2, draw = 0.0, omni = true } } },
  -- FLOODLIGHT: a lamp for landing at night and for working in a shadow. It is
  -- what the Lights group (Y) switches; it draws power while it's on.
  light     = { prefab = "PartLight",     label = "Floodlight",   h = 0.30, rx = 0.15, rz = 0.15, mass = 0.01, cost = 40,  top = false, bottom = false, kind = "structural", radial_orient = true, strength = 60,
                mods = { { type = "light", draw = 0.2 } } },
  decoupler = { prefab = "PartDecoupler", label = "Decoupler",    h = 0.25, rx = 0.51, rz = 0.51, mass = 0.06, cost = 60,  top = true,  bottom = true,  kind = "structural", decouple = true, strength = 400 },
  -- The RADIAL decoupler mounts on a flank and kicks its outboard branch
  -- away at staging (side boosters). It is itself a side host: booster
  -- stacks attach to its outer face.
  radialDec = { prefab = "PartDecoupler", label = "Radial Decoupler", h = 0.25, rx = 0.51, rz = 0.51, mass = 0.05, cost = 60, top = false, bottom = false, kind = "structural", decouple = true, radial = true, side = true, strength = 350 },
  -- Landing legs are RADIAL now (like fins): mount on the flank of a tank/engine
  -- with symmetry (X = ×N), each strut self-orients outward, and they fold down
  -- to deploy / up to stow as ONE symmetry ring (G in flight). No more stack
  -- sandwich — bolt three or four around the base and they splay out to land.
  legs      = { prefab = "PartLegs",      label = "Landing Legs", h = 0.90, rx = 0.40, rz = 0.18, mass = 0.015, cost = 40,  top = false, bottom = false, kind = "structural", legs = true, radial_orient = true, strength = 300 },
  -- SKIPPER: a heavier, punchier engine in the Anvil's exact footprint (same
  -- proven collider) — twice the Anvil's thrust: the first stage of anything
  -- going to another planet. (Rating version 3 gives the three engines their
  -- jobs, sea level against vacuum: see ENGINE NICHES below.)
  skipper    = { prefab = "PartSkipper",    label = "Skipper",      h = 1.60, rx = 0.90, rz = 0.90, mass = 1.6,  cost = 520, top = true,  bottom = true,  kind = "engine", thrust = 170, ve = 184, strength = 1000 },
  -- RADIAL TANK: a strap-on drop-tank. radial_orient mounts it on a flank like a
  -- fin (ring it with symmetry); its fuel joins the shared pool, and a radial
  -- decoupler kicks it (and its ring) away when spent.
  radialTank = { prefab = "PartRadialTank", label = "Radial Tank",  h = 1.00, rx = 0.50, rz = 0.50, mass = 0.15, cost = 110, top = false, bottom = false, kind = "tank", fuel = 60, radial_orient = true, strength = 400 },
  -- DOCKING PORT: the androgynous latch two craft mate through. It stacks like
  -- a decoupler (same collar footprint) and hosts side mounts, so you can put
  -- one on the nose of a lander and another under a station module. In flight
  -- it is BOTH halves of the job: bring two ports face to face and it captures
  -- (the assemblies weld into one vessel); press its UNDOCK control and it
  -- splits the stack right back apart at that seam, sending the far half away
  -- as a live craft you can fly. That's the whole orbit → land → return loop.
  -- radial_orient makes a FLANK-mounted port face outward (+X) instead of
  -- keeping its authored "up" — that's what makes side berths work. Stacked
  -- axially it behaves exactly as before, so one part covers both.
  dockPort  = { prefab = "PartDockPort",  label = "Docking Port", h = 0.28, rx = 0.53, rz = 0.53, mass = 0.1,  cost = 180, top = true,  bottom = true,  kind = "structural", dock = true, side = true, radial_orient = true, strength = 500 },
  -- RCS BLOCK: the small four-way thruster cluster docking is actually flown
  -- with. Mounts on a flank like a fin, rings with symmetry, and pools its
  -- thrust into the craft's translation authority (IJKL + HN). Balance them
  -- around the hull — the pooled push goes through the centre of mass, so a
  -- lopsided set costs you nothing but looks wrong, and a bare craft with no
  -- blocks simply has no translation at all.
  rcs       = { prefab = "PartRCS",       label = "RCS Block",    h = 0.34, rx = 0.20, rz = 0.20, mass = 0.04, cost = 80,  top = false, bottom = false, kind = "structural", rcs = true, rcs_thrust = 3.0, radial_orient = true, strength = 60 },
  -- CARGO BAY: the hold. `cargo` is its capacity in kilograms; a vessel's total
  -- is the sum of its bays, and that number is the only thing standing between
  -- a planet full of ore and the warehouse. The bay's own mass is the EMPTY
  -- mass — what's inside is added in flight from the manifest, so a full hold
  -- genuinely flies worse than an empty one.
  cargo     = { prefab = "PartCargo",     label = "Cargo Bay",    h = 1.20, rx = 0.50, rz = 0.50, mass = 0.4,  cost = 300, top = true,  bottom = true,  kind = "structural", cargo = 250, side = true, strength = 500 },

  -- ── FRAME: struts, beams, panels, plates and adapters ─────────────────────
  -- Light and cheap, and they attach every way: stack nodes on both ends,
  -- a node on every flank, and SURFACE attach anywhere on them (aim at the
  -- part away from its nodes). `axial_out` makes a strut or beam snapped onto
  -- a flank point straight out of it, so a frame is built by clicking rather
  -- than by pitching every member by hand. Aluminium tube is ~6 kg a metre,
  -- the I-beams painted steel; strength is what each joint takes (kN).
  strut1    = { prefab = "PartStrut1",    label = "Strut 1 m",    h = 1.00, rx = 0.07, rz = 0.07, mass = 0.012, cost = 15, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 250 },
  strut2    = { prefab = "PartStrut2",    label = "Strut 2 m",    h = 2.00, rx = 0.07, rz = 0.07, mass = 0.024, cost = 25, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 250 },
  strut3    = { prefab = "PartStrut3",    label = "Strut 3 m",    h = 3.00, rx = 0.07, rz = 0.07, mass = 0.036, cost = 35, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 250 },
  beam1     = { prefab = "PartBeam1",     label = "Box Beam 1 m", h = 1.00, rx = 0.12, rz = 0.07, mass = 0.02,  cost = 20, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 380 },
  beam2     = { prefab = "PartBeam2",     label = "Box Beam 2 m", h = 2.00, rx = 0.12, rz = 0.07, mass = 0.04,  cost = 35, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 380 },
  ibeam2    = { prefab = "PartIBeam2",    label = "I-Beam 2 m",   h = 2.00, rx = 0.12, rz = 0.13, mass = 0.06,  cost = 45, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 650 },
  ibeam3    = { prefab = "PartIBeam3",    label = "I-Beam 3 m",   h = 3.00, rx = 0.12, rz = 0.13, mass = 0.09,  cost = 60, top = true, bottom = true, side = true, axial_out = true, member = true, kind = "structural", strength = 650 },
  -- Panels lie flat (X–Z): their stack nodes are the two faces, their flank
  -- nodes the middle of each edge, so they tile edge to edge into a deck.
  panel1    = { prefab = "PartPanel1",    label = "Panel 1×1 m",  h = 0.04, rx = 0.50, rz = 0.50, mass = 0.025, cost = 20, top = true, bottom = true, side = true, panel = true, kind = "structural", strength = 220 },
  panel2    = { prefab = "PartPanel2",    label = "Panel 2×1 m",  h = 0.04, rx = 1.00, rz = 0.50, mass = 0.05,  cost = 35, top = true, bottom = true, side = true, panel = true, kind = "structural", strength = 220 },
  panel3    = { prefab = "PartPanel3",    label = "Panel 2×2 m",  h = 0.04, rx = 1.00, rz = 1.00, mass = 0.10,  cost = 60, top = true, bottom = true, side = true, panel = true, kind = "structural", strength = 260 },
  plate     = { prefab = "PartPlate",     label = "Deck Plate",   h = 0.10, rx = 0.50, rz = 0.50, mass = 0.06,  cost = 40, top = true, bottom = true, side = true, panel = true, kind = "structural", strength = 500 },
  hub       = { prefab = "PartHub",       label = "Strut Hub",    h = 0.24, rx = 0.12, rz = 0.12, mass = 0.008, cost = 12, top = true, bottom = true, side = true, kind = "structural", strength = 400 },
  -- DRAWN MEMBERS (§5.5): one part for any length and profile. The Beam tool
  -- drags it from a start point to an end point; `size = { len, prof }` rides
  -- in the blueprint and builder_proc builds its mesh (cached per profile and
  -- 5 cm of length) and sets its collider. Figures below are PER METRE
  -- (sizeOf scales them); h/rx/rz are the 1 m box default. prof is one of
  -- PROFILES below. Joints come from builder_attach: splice, corner, tee and
  -- cross, each with a gusset or plate and a weld — no hub needed.
  beamP     = { prefab = "PartMember",    label = "Beam (drawn)", h = 1.00, rx = 0.12, rz = 0.07, mass = 0.02, cost = 20, top = true, bottom = true, side = true, axial_out = true, member = true, proc = "member", prof = "box", kind = "structural", strength = 380 },
  -- DRAWN PANEL: a rectangle dragged on a face or the floor; size = { w, d, t }
  -- (t 0.04 sheet, 0.10 deck). mass and cost are per square metre of sheet.
  panelP    = { prefab = "PartPanelP",    label = "Panel (drawn)", h = 0.04, rx = 0.50, rz = 0.50, mass = 0.025, cost = 20, top = true, bottom = true, side = true, panel = true, proc = "panel", kind = "structural", strength = 240 },
  -- BRACE (§5.3, Besiege/KSP style): click point A on any part, then point B
  -- on another. A thin tube with a bolted lug each end, length as drawn, and
  -- a `brace` link at each end that stiffens big frames and booster rings.
  brace     = { prefab = "PartBrace",     label = "Brace",        h = 1.00, rx = 0.035, rz = 0.035, mass = 0.004, cost = 8, top = false, bottom = false, member = true, proc = "brace", prof = "brace", kind = "structural", strength = 200 },
  adapter   = { prefab = "PartAdapter",   label = "Adapter 1.0–0.5", h = 0.50, rx = 0.50, rz = 0.50, mass = 0.05, cost = 45, top = true, bottom = true, kind = "structural", strength = 500 },

  -- ── ROVERS ───────────────────────────────────────────────────────────────
  -- ROVER BODY: a chassis with its own probe core, battery and whip — a body
  -- and four wheels is a whole rover. Its FRONT is +X (the headlights); W
  -- drives that way.
  roverBody = { prefab = "PartRoverBody", label = "Rover Body",   h = 0.30, rx = 0.80, rz = 0.50, mass = 0.35, cost = 520, top = true, bottom = true, side = true, kind = "probe", strength = 500, front = true,
                mods = { { type = "command", crew = 0, draw = 0.04 }, { type = "wheel", torque = 0.3, draw = 0.2 },
                         { type = "battery", ec = 400 }, { type = "antenna", power = 120, rate = 1, draw = 0.02 },
                         { type = "light", draw = 0.15 } } },
  -- POWERED WHEELS on a flank (radial_orient: +X out is the axle). `drive`
  -- is the hub motor: torque (kN·m on the reference world, rated for the home
  -- world like engine thrust), top speed (m/s), draw at full power (EC/s) and
  -- the tyre radius. A tyre this size on a world this small grips by the load
  -- it carries — the flight hangs it on the engine's wheel joint.
  wheelS    = { prefab = "PartWheelS",    label = "Wheel S",      h = 0.50, rx = 0.14, rz = 0.25, mass = 0.05, cost = 110, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 180, wheel = "S", travel = 0.10,
                mods = { { type = "drive", torque = 0.2, speed = 5.0, draw = 0.12, r = 0.25 } } },
  wheelM    = { prefab = "PartWheelM",    label = "Wheel M",      h = 0.80, rx = 0.20, rz = 0.40, mass = 0.12, cost = 190, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 300, wheel = "M", travel = 0.15,
                mods = { { type = "drive", torque = 0.5, speed = 7.0, draw = 0.25, r = 0.40 } } },
  wheelL    = { prefab = "PartWheelL",    label = "Wheel L",      h = 1.20, rx = 0.28, rz = 0.60, mass = 0.25, cost = 320, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 520, wheel = "L", travel = 0.20,
                mods = { { type = "drive", torque = 1.1, speed = 9.0, draw = 0.5, r = 0.60 } } },
  -- FAIRINGS: a base ring that grows a shell to enclose whatever is stacked
  -- on it (the shell is built to fit — scripts measure the payload), keeps the
  -- air and the heat off it on the way up, and splits away by its action or
  -- as a staging event. `fairing` is the base radius.
  fairingS  = { prefab = "PartFairingS",  label = "Fairing 1.25 m", h = 0.20, rx = 0.625, rz = 0.625, mass = 0.08, cost = 140, top = true, bottom = true, kind = "structural", fairing = 0.625, strength = 450,
                mods = { { type = "fairing" } } },
  fairingM  = { prefab = "PartFairingM",  label = "Fairing 2.5 m",  h = 0.20, rx = 1.25,  rz = 1.25,  mass = 0.2,  cost = 260, top = true, bottom = true, kind = "structural", fairing = 1.25, strength = 700,
                mods = { { type = "fairing" } } },

  -- ── ROBOTICS ─────────────────────────────────────────────────────────────
  -- Electric actuators. Everything stacked on the moving face (the top node)
  -- moves with it; they draw power while they move and hold where they stop.
  -- `robo` = the joint kind; the module carries the motor's figures.
  hinge     = { prefab = "PartHinge",     label = "Servo Hinge",  h = 0.40, rx = 0.20, rz = 0.20, mass = 0.06, cost = 240, top = true, bottom = true, kind = "structural", robo = "hinge", strength = 420,
                mods = { { type = "hinge", torque = 3.0, rate = 30, draw = 0.5 } } },
  piston    = { prefab = "PartPiston",    label = "Piston",       h = 0.50, rx = 0.16, rz = 0.16, mass = 0.08, cost = 260, top = true, bottom = true, kind = "structural", robo = "piston", strength = 420,
                mods = { { type = "piston", force = 8.0, rate = 0.3, draw = 0.5 } } },
  rotor     = { prefab = "PartRotor",     label = "Rotor",        h = 0.30, rx = 0.30, rz = 0.30, mass = 0.10, cost = 300, top = true, bottom = true, kind = "structural", robo = "rotor", strength = 450,
                mods = { { type = "rotor", torque = 2.0, draw = 0.8 } } },
  -- LANDING CLAW: arm it and it bites into whatever it touches — rock, an
  -- asteroid, another craft — and holds the craft there until released.
  claw      = { prefab = "PartClaw",      label = "Landing Claw", h = 0.80, rx = 0.35, rz = 0.35, mass = 0.09, cost = 380, top = true, bottom = false, kind = "structural", claw = true, strength = 600,
                mods = { { type = "claw", draw = 0.05, hold = 400 } } },
  -- CORE DRILL: on a flank, bit down. Lowered and running while the craft is
  -- landed or gripped, it bores into the ground and lifts what it cuts into
  -- the cargo hold (sample cores count for the labs).
  drill     = { prefab = "PartDrill",     label = "Core Drill",   h = 1.20, rx = 0.20, rz = 0.20, mass = 0.12, cost = 450, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 300,
                mods = { { type = "drill", rate = 24.0, draw = 1.2, reach = 0.9 } } },
}

-- ── ENGINE NICHES: sea level and vacuum (rating version 3) ─────────────────
--
-- A real nozzle is shaped for one outside pressure. The same propellant flow
-- leaves at a lower exhaust velocity into thick air than into vacuum, and so
-- pushes less: thrust and ve both scale by
--
--     k(σ) = 1 − (1 − asl) · σ        (never under NOZZLE_FLOOR)
--
-- where σ is the air's density as a share of reference sea level (aero.lua
-- `airAt` / RHO0: 1 on a home of atmo 0.75 at its datum, 0 in vacuum, over 1
-- on a thick world) and `asl` is the engine's sea-level share of its vacuum
-- figures. A nozzle built for vacuum (a big bell, low asl) loses the most.
-- The burn rate (propellant per second) does not change, so a vacuum engine
-- fired at sea level wastes its fuel.
--
-- Each engine has a JOB, so none of them is simply the best:
--   SPUTTER  the lander and small-probe engine. Light and cheap, decent at
--            any pressure (asl 0.92), tiny thrust. The starter rocket's engine
--            and still the right one for anything small.
--   ANVIL    the upper stage. The best ve in vacuum (195), but a vacuum bell:
--            at sea level it keeps 60 % (asl 0.6), so a big Anvil-only stack
--            can't leave the pad. Light for its thrust.
--   SKIPPER  the lifter. Big thrust that holds up at sea level (asl 0.92),
--            but heavy and only middling in vacuum (ve 168).
-- So the classic two-stage rocket, Skipper below and Anvil above, is the way
-- to orbit and beyond (tests/smoke_engine_niches.lua flies the arithmetic).
--
-- THESE FIGURES ARE RATING VERSION 3. A save's catalogue is frozen at the
-- rating version it was first built with (builder.lua `rating`, save key
-- `parts.rating`): a save rated at version 2 keeps the plain REG figures above
-- (no asl, the same in air and vacuum), so its catalogue, readouts and every
-- craft it has built fly exactly as before. A blueprint carries the figures it
-- was built with (thrust, burn, ve and, from version 3, asl), so even a v3
-- engine's behaviour is frozen into the craft that carries it. A new version is
-- a new entry here; nothing in an existing entry may ever change.
NOZZLE_FLOOR = 0.05
RATED = {
  [3] = {
    engineS = { thrust = 35,  ve = 160, asl = 0.92,
                desc = "lander / probe engine · light, cheap · fine in air or vacuum" },
    engineM = { thrust = 85,  ve = 195, asl = 0.60,
                desc = "upper stage · best in vacuum · weak at sea level" },
    skipper = { thrust = 180, ve = 168, asl = 0.92,
                desc = "lifter · huge thrust at sea level · heavy, so-so in vacuum" },
  },
}
RATING_LATEST = 3
for v, t in pairs(RATED) do
  for id, f in pairs(t) do
    if REG[id] then
      REG[id].rated = REG[id].rated or {}
      REG[id].rated[v] = f
    end
  end
end

-- An engine's figures at rating version v: { thrust, ve, asl, desc } (asl 1
-- and the plain REG figures for a version with no entry). Pure.
function engineAt(def, v)
  if type(def) == "string" then def = REG[def] end
  if not (def and def.thrust) then return nil end
  local f = def.rated and def.rated[v]
  if f then return { thrust = f.thrust, ve = f.ve, asl = f.asl or 1, desc = f.desc } end
  return { thrust = def.thrust, ve = def.ve or 160, asl = 1, desc = nil }
end

-- The nozzle factor at air σ (density / reference sea level): what share of
-- its vacuum thrust and ve an engine of sea-level share `asl` gives there.
-- asl nil (a part rated before nozzles) is 1 everywhere. Pure.
function nozzle(asl, sigma)
  if not asl or asl >= 1 then return 1.0 end
  sigma = math.max(0.0, math.min(2.5, sigma or 0))
  return math.max(NOZZLE_FLOOR, 1.0 - (1.0 - asl) * sigma)
end

-- What the round-two parts are for, under their names on the catalogue card.
-- (The ENGINES' lines — what each one is for — ride with their rating, in
-- RATED above: a save rated before the niches keeps its figures on the card.)
DESC = {
  strut1 = "square strut · 12 kg · nodes on every face", strut2 = "square strut · 24 kg · nodes on every face",
  strut3 = "square strut · 36 kg · nodes on every face", beam1 = "box beam · 20 kg · stiffer than a strut",
  beam2 = "box beam · 40 kg · stiffer than a strut", ibeam2 = "steel I-beam · 60 kg · the strongest member",
  ibeam3 = "steel I-beam · 90 kg · the strongest member", panel1 = "flat panel · 25 kg · decks, walls, fenders",
  panel2 = "flat panel · 50 kg · decks, walls, fenders", panel3 = "flat panel · 100 kg · decks, walls, fenders",
  plate = "tread-plate deck · 60 kg · a floor to build on", hub = "node block · optional · six faces · beams join without one",
  adapter = "stack adapter · 1.0 m to 0.5 m",
  beamP = "drawn beam · any length · tube, box, I or truss · joins flush",
  panelP = "drawn panel · drag a rectangle · sheet or deck",
  brace = "two-point brace · click A, click B · stiffens a frame",
  roverBody = "rover body · probe core, battery, lights · front = +X",
  seat = "open seat · F to sit and drive · faces +X · no wheel or battery",
  wheelS = "powered wheel · r 0.25 m · 5 m/s · −0.12 power/s", wheelM = "powered wheel · r 0.4 m · 7 m/s · −0.25 power/s",
  wheelL = "powered wheel · r 0.6 m · 9 m/s · −0.5 power/s",
  fairingS = "fairing · B draws its shell (or it fits the payload) · jettisons",
  fairingM = "fairing · B draws its shell (or it fits the payload) · jettisons",
  hinge = "servo hinge · ±90° · holds where it stops", piston = "piston · extends 0.8 m · holds where it stops",
  rotor = "rotor · spins what's on it · up to 60 rpm", claw = "landing claw · arm it to grip the ground",
  drill = "core drill · bores while landed · fills the hold",
  beacon = "relay beacon · always on · relays a few hundred m over the ground",
}
for id, d in pairs(DESC) do if REG[id] then REG[id].desc = d end end

-- THE CATALOGUE, in the order the panel shows it. Grouped the way you build:
-- the crew capsule and what brings it home, then what pushes it, then what it
-- flies with, then what it does once it's there.
--
-- This list is the ONE place the order lives. It used to be spread across
-- three: a parallel `IDS` array in `catalog_button.lua`, a `part` index on each
-- of nineteen authored button nodes in `builder.ron`, and this registry — so
-- adding a part meant editing a scene file and keeping two arrays in step, and
-- getting an index wrong silently mislabelled a card. A part added to `REG` and
-- named here now appears in the catalogue and nowhere else needs to know.
CATALOGUE = {
  { "COMMAND",   { "pod", "probe", "seat", "nose", "chute" } },
  { "ELECTRICAL",{ "battery", "solar", "light", "antenna", "beacon", "dish", "dishL" } },
  { "PROPULSION",{ "engineS", "engineM", "skipper", "tankS", "tankM", "radialTank", "rcs" } },
  { "STRUCTURE", { "decoupler", "radialDec", "legs", "fins" } },
  { "FRAME",     { "strut1", "strut2", "strut3", "beam1", "beam2", "ibeam2", "ibeam3",
                   "panel1", "panel2", "panel3", "plate", "hub", "adapter",
                   "beamP", "panelP", "brace" } },
  { "PAYLOAD",   { "cargo", "dockPort", "fairingS", "fairingM" } },
  { "ROVER",     { "roverBody", "wheelS", "wheelM", "wheelL" } },
  { "ROBOTICS",  { "hinge", "piston", "rotor", "claw", "drill" } },
}

-- Every part this builder knows how to spawn. The catalogue test compares this
-- against what `catalogue()` lists, so a part added to `REG` and forgotten here
-- is a build failure rather than a part nobody can buy.
function registryIds()
  local out = {}
  for id in pairs(REG) do out[#out + 1] = id end
  table.sort(out)
  return out
end

-- The catalogue panel asks for this: sections, each with the parts it holds.
-- Ids with no entry in `REG` are dropped rather than drawn as a broken card.
function catalogue()
  local out = {}
  for _, section in ipairs(CATALOGUE) do
    local ids = {}
    for _, id in ipairs(section[2]) do
      if REG[id] then ids[#ids + 1] = id end
    end
    if #ids > 0 then out[#out + 1] = { title = section[1], ids = ids } end
  end
  return out
end

function partInfo(id)
  return REG[id]
end

-- Drawn-member profiles: per-metre mass (t) and cost, and the joint
-- strength (kN). The half-widths match builder_attach.PROFILES.
PROFILES = {
  tube  = { rx = 0.07, rz = 0.07, mass = 0.012, cost = 15, strength = 250, label = "tube" },
  box   = { rx = 0.12, rz = 0.07, mass = 0.020, cost = 20, strength = 380, label = "box" },
  ibeam = { rx = 0.12, rz = 0.13, mass = 0.030, cost = 23, strength = 650, label = "I-beam" },
  truss = { rx = 0.20, rz = 0.18, mass = 0.025, cost = 30, strength = 520, label = "truss" },
  brace = { rx = 0.035, rz = 0.035, mass = 0.004, cost = 8, strength = 200, label = "brace" },
}

-- A part's mass, cost and joint strength at a procedural size (§5.5):
--   member  size = { len, prof }: mass and cost scale with length from the
--           profile's per-metre figures; strength is the profile's (a joint
--           is no stronger for a longer member);
--   brace   size = { len }: as a member, plus 6 $ for its two lugs;
--   panel   size = { w, d, t }: per square metre, a 0.10 deck 2.4× a sheet.
-- Fixed parts (or no size) answer their catalogue figures.
function sizeOf(def, size)
  if type(def) == "string" then def = REG[def] end
  if not def then return nil end
  if def.proc and size then
    if def.proc == "member" or def.proc == "brace" then
      local P = PROFILES[size.prof or def.prof or "box"] or PROFILES.box
      local L = size.len or def.h
      local extra = def.proc == "brace" and 6 or 0
      return { mass = P.mass * L, cost = math.floor(P.cost * L + extra + 0.5), strength = P.strength,
               rx = P.rx, rz = P.rz, h = L }
    elseif def.proc == "panel" then
      local A = (size.w or 1) * (size.d or 1)
      local k = (size.t or 0.04) >= 0.08 and 2.4 or 1.0
      return { mass = def.mass * A * k, cost = math.floor(def.cost * A * k + 0.5), strength = def.strength * (k > 1 and 1.6 or 1),
               rx = (size.w or 1) * 0.5, rz = (size.d or 1) * 0.5, h = size.t or 0.04 }
    end
  end
  return { mass = def.mass, cost = def.cost, strength = def.strength, rx = def.rx, rz = def.rz, h = def.h }
end

-- Another rulebook adds its parts (and its catalogue section) through its own
-- `register(REG, CATALOGUE)`. Once per provider: a second call is a no-op.
local extended = {}
function extend(provider)
  if not (provider and provider.register) then return 0 end
  local key = provider.kind or provider
  if extended[key] then return 0 end
  extended[key] = true
  return provider.register(REG, CATALOGUE) or 0
end
