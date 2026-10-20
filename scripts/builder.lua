-- SHIP BUILDER v1.3 (game roadmap SC1) — free placement, free ORIENTATION,
-- radial mounts + SYMMETRY, precise editing. A ship is just the connected
-- part graph; any part (or the whole ship) moves freely; the blueprint is
-- self-contained (the launch site never needs this registry).
--
--   catalogue button   pick up a part (ghost follows the cursor)
--     click            place — ONLY on a highlighted attach node (green tie
--                      line); hold ALT to place free (red halo = overlapping,
--                      refused). The first part places freely on the pad.
--     R / SHIFT+R      rotate 15° / 5° (yaw)
--     T / SHIFT+T      pitch 90° / 15°     Y / SHIFT+Y  roll 90° / 15°
--                      (build sideways — a pitched pod is a rocket car's nose)
--     X / SHIFT+X      SYMMETRY ×1 ×2 ×3 ×4 ×6 ×8 — a radial placement
--                      repeats around the host's axis (boosters in one click)
--     ESC              put the part back
--   click a placed part      pick it (and everything stacked on it) back up
--                            (a SYMMETRY member brings its whole ring)
--   hover a placed part      arrows nudge it (SHIFT = fine; ↑/↓ vertical,
--                            ←/→ screen-horizontal, ALT+←/→ depth)
--                            R/T/Y rotate it in place
--   DEL (hovering)           scrap a part + its stack (a symmetry member
--                            scraps the whole ring)
--   G                        grab the WHOLE ship; click sets it down
--   CTRL+Z undo   ·   CTRL+S save   ·   F5 reload
--
-- RADIAL MOUNTS: parts with side nodes (pod, tanks, radial decoupler) show
-- extra rings on their flanks — anything can snap there, side-by-side at the
-- same height: side boosters, outriggers, wheels-on-a-sideways-ship. The
-- radial decoupler is the separator: at staging its whole outboard branch
-- (parent links) kicks away laterally.
--
-- SYMMETRY: with ×N up, one radial placement rings N copies around the host
-- (ghost previews show all of them). Anything you then stack ON a symmetry
-- member — a tank on one radial decoupler, an engine under one booster —
-- AUTO-MIRRORS onto every other member of that ring, however deep the stack
-- goes. Rings are edited as one: pick one up and the ring comes with it,
-- scrap one and the ring goes.
--
-- All clicks are edge-detected IN-SCRIPT (input snapshots can serve two
-- frames at uneven fps — raw `input.clicked` double-fires a pickup into an
-- instant re-place, which reads as "selection doesn't work").

defaults = {
  snap_px = 52.0,     -- screen px within which an attach node captures the ghost
  floor_y = 0.11,     -- top of the pad
  nudge = 0.1,        -- precise-edit step (SHIFT = a quarter of this)
}

-- ── Builder audio (non-spatial UI clicks) ────────────────────────────────────
-- Every build action gets a crisp click on the UI mixer bus. Kenney CC0 clips.
local UI_SFX = {
  place  = "audio/kenney/interface/click_001.ogg",
  pickup = "audio/kenney/interface/pluck_001.ogg",
  scrap  = "audio/kenney/interface/close_001.ogg",
  tool   = "audio/kenney/interface/tick_001.ogg",
  save   = "audio/kenney/interface/confirmation_001.ogg",
  launch = "audio/kenney/interface/confirmation_003.ogg",
}
-- Take a KEY (into UI_SFX), not a clip path, so callers don't each capture
-- UI_SFX as an upvalue — `update` is already near LuaJIT's 60-upvalue ceiling.
local function ui(key, vol)
  if not audio then return end
  audio.play(UI_SFX[key] or key, { track = "UI", volume = vol or 1.0 })
end

-- ── Part registry (builder-side only; blueprints embed everything) ──────────
-- h = FULL visual stack height (measured from the mesh AABB × prefab scale,
-- so stacked parts sit flush); rx/rz = half-widths for overlap tests.
-- side = true exposes 4 radial attach nodes on the part's flanks.
-- mass = the part's DRY mass in tonnes. A tank's propellant is on top of it:
-- `fuel` units of FUEL_T_PER_UNIT tonnes each, so a full tank is heavy and an
-- empty one light, and the craft lightens as it burns (see BALANCE below).
-- thrust (kN) and ve (exhaust velocity, m/s) are an engine's figures on the
-- REFERENCE world; the catalogue is built once per save for its home world
-- (see `rating`) and every card, readout and flight uses those numbers.
-- strength = the load (kN) this part's attachment to its parent takes before it
-- gives — the joint the flight's stress model loads with the mass hanging off
-- it times what the craft is doing (thrust, drag, a canopy snatch, a tumble).
-- maxq = dynamic pressure (kPa) the part itself takes (default 80; aero parts
-- more). Both ride in the blueprint; vessel_controller has kind-based fallbacks
-- for builds saved before they existed.
local REG = {
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
  -- proven collider) — twice the Anvil's thrust and the best exhaust velocity
  -- on the list: the first stage of anything going to another planet.
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
  strut1    = { prefab = "PartStrut1",    label = "Strut 1 m",    h = 1.00, rx = 0.07, rz = 0.07, mass = 0.012, cost = 15, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 250 },
  strut2    = { prefab = "PartStrut2",    label = "Strut 2 m",    h = 2.00, rx = 0.07, rz = 0.07, mass = 0.024, cost = 25, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 250 },
  strut3    = { prefab = "PartStrut3",    label = "Strut 3 m",    h = 3.00, rx = 0.07, rz = 0.07, mass = 0.036, cost = 35, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 250 },
  beam1     = { prefab = "PartBeam1",     label = "Box Beam 1 m", h = 1.00, rx = 0.12, rz = 0.07, mass = 0.02,  cost = 20, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 380 },
  beam2     = { prefab = "PartBeam2",     label = "Box Beam 2 m", h = 2.00, rx = 0.12, rz = 0.07, mass = 0.04,  cost = 35, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 380 },
  ibeam2    = { prefab = "PartIBeam2",    label = "I-Beam 2 m",   h = 2.00, rx = 0.12, rz = 0.13, mass = 0.06,  cost = 45, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 650 },
  ibeam3    = { prefab = "PartIBeam3",    label = "I-Beam 3 m",   h = 3.00, rx = 0.12, rz = 0.13, mass = 0.09,  cost = 60, top = true, bottom = true, side = true, axial_out = true, kind = "structural", strength = 650 },
  -- Panels lie flat (X–Z): their stack nodes are the two faces, their flank
  -- nodes the middle of each edge, so they tile edge to edge into a deck.
  panel1    = { prefab = "PartPanel1",    label = "Panel 1×1 m",  h = 0.04, rx = 0.50, rz = 0.50, mass = 0.025, cost = 20, top = true, bottom = true, side = true, kind = "structural", strength = 220 },
  panel2    = { prefab = "PartPanel2",    label = "Panel 2×1 m",  h = 0.04, rx = 1.00, rz = 0.50, mass = 0.05,  cost = 35, top = true, bottom = true, side = true, kind = "structural", strength = 220 },
  panel3    = { prefab = "PartPanel3",    label = "Panel 2×2 m",  h = 0.04, rx = 1.00, rz = 1.00, mass = 0.10,  cost = 60, top = true, bottom = true, side = true, kind = "structural", strength = 260 },
  plate     = { prefab = "PartPlate",     label = "Deck Plate",   h = 0.10, rx = 0.50, rz = 0.50, mass = 0.06,  cost = 40, top = true, bottom = true, side = true, kind = "structural", strength = 500 },
  hub       = { prefab = "PartHub",       label = "Strut Hub",    h = 0.24, rx = 0.12, rz = 0.12, mass = 0.008, cost = 12, top = true, bottom = true, side = true, kind = "structural", strength = 400 },
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
  wheelS    = { prefab = "PartWheelS",    label = "Wheel S",      h = 0.50, rx = 0.14, rz = 0.25, mass = 0.05, cost = 110, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 180, wheel = "S",
                mods = { { type = "drive", torque = 0.2, speed = 5.0, draw = 0.12, r = 0.25 } } },
  wheelM    = { prefab = "PartWheelM",    label = "Wheel M",      h = 0.80, rx = 0.20, rz = 0.40, mass = 0.12, cost = 190, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 300, wheel = "M",
                mods = { { type = "drive", torque = 0.5, speed = 7.0, draw = 0.25, r = 0.40 } } },
  wheelL    = { prefab = "PartWheelL",    label = "Wheel L",      h = 1.20, rx = 0.28, rz = 0.60, mass = 0.25, cost = 320, top = false, bottom = false, radial_orient = true, kind = "structural", strength = 520, wheel = "L",
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

-- What the round-two parts are for, under their names on the catalogue card.
local DESC = {
  strut1 = "square strut · 12 kg · nodes on every face", strut2 = "square strut · 24 kg · nodes on every face",
  strut3 = "square strut · 36 kg · nodes on every face", beam1 = "box beam · 20 kg · stiffer than a strut",
  beam2 = "box beam · 40 kg · stiffer than a strut", ibeam2 = "steel I-beam · 60 kg · the strongest member",
  ibeam3 = "steel I-beam · 90 kg · the strongest member", panel1 = "flat panel · 25 kg · decks, walls, fenders",
  panel2 = "flat panel · 50 kg · decks, walls, fenders", panel3 = "flat panel · 100 kg · decks, walls, fenders",
  plate = "tread-plate deck · 60 kg · a floor to build on", hub = "strut hub · a node on all six faces",
  adapter = "stack adapter · 1.0 m to 0.5 m",
  roverBody = "rover body · probe core, battery, lights · front = +X",
  wheelS = "powered wheel · r 0.25 m · 5 m/s · −0.12 power/s", wheelM = "powered wheel · r 0.4 m · 7 m/s · −0.25 power/s",
  wheelL = "powered wheel · r 0.6 m · 9 m/s · −0.5 power/s",
  fairingS = "fairing · shell fits its payload · jettisons", fairingM = "fairing · shell fits its payload · jettisons",
  hinge = "servo hinge · ±90° · holds where it stops", piston = "piston · extends 0.8 m · holds where it stops",
  rotor = "rotor · spins what's on it · up to 60 rpm", claw = "landing claw · arm it to grip the ground",
  drill = "core drill · bores while landed · fills the hold",
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
local CATALOGUE = {
  { "COMMAND",   { "pod", "probe", "nose", "chute" } },
  { "ELECTRICAL",{ "battery", "solar", "light", "antenna", "dish", "dishL" } },
  { "PROPULSION",{ "engineS", "engineM", "skipper", "tankS", "tankM", "radialTank", "rcs" } },
  { "STRUCTURE", { "decoupler", "radialDec", "legs", "fins" } },
  { "FRAME",     { "strut1", "strut2", "strut3", "beam1", "beam2", "ibeam2", "ibeam3",
                   "panel1", "panel2", "panel3", "plate", "hub", "adapter" } },
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

-- ── State ───────────────────────────────────────────────────────────────────
local parts = {}        -- uid -> { id, def, node, x,y,z, yaw,pitch,roll, parent (uid|nil) }
local next_uid = 1
local ghost = nil       -- { id, def, node, yaw,pitch,roll [, carried, from_uid] }
local undo_stack = {}
local pending_spawns = 0
local hover_uid = nil
local stats_node, hint_node
local hint_t = 0        -- seconds a transient hint stays up

-- Edge-detected mouse + a short cooldown so one physical click never both
-- picks up AND re-places.
local lmb_prev = false
local click_cool = 0

-- Published (builder_camera frames the ship with these).
centerX, centerY, centerZ = 0.0, 1.5, 0.0
partCount = 0

-- ── Symmetry state ──────────────────────────────────────────────────────────
-- sym_n is the ×N mode (X cycles it); parts placed as a ring share a `sym`
-- group id, and children stacked on a ring member auto-mirror into their own
-- ring (chained groups). Group geometry is DERIVED, never stored: a ring's
-- HUB is the members' common parent (first generation) or, for a chained
-- ring, the hub of the parent ring — so save/load only needs the id.
local SYM_STEPS = { 1, 2, 3, 4, 6, 8 }
local sym_n = 1
local next_sym = 0

-- ── Staging order ───────────────────────────────────────────────────────────
-- Stage ITEMS are separation events: each axial decoupler is one; a radial-
-- decoupler RING (symmetry group) is ONE bundled item. `stage_order` lists
-- item keys in FIRING order (row 1 fires first); drag rows in the STAGING
-- panel to reorder. Persisted per-part (`stage`) in the blueprint — flight
-- fires the events in exactly this order.
local stage_order = {}   -- array of keys: "u<uid>" | "g<sym gid>"
local stage_drag = nil   -- { key, row, grab_dy } while a row is being dragged
local stage_hover = nil  -- stage-panel row the cursor is over (world highlight)
local stage_node2 = nil  -- the StagePanel UI node
local stage_rows = nil   -- cached array of the StageRow## UI nodes
local stage_ghost = nil  -- the StageDragGhost UI node (follows the cursor)
local saved_stage = {}   -- uid → stage index from a loaded blueprint
local STAGE_MAX_ROWS = 14 -- size of the StageRow## pool authored in builder.ron

-- ── Tools & selection ───────────────────────────────────────────────────────
-- Clicking a part SELECTS it (it doesn't grab/move) — hovering only previews
-- what a click would select. The active TOOL decides what the selection's
-- gizmo does: 1 = Move (arrows), 2 = Rotate (rings), 3 = Stage (numbered
-- decoupler badges + the staging panel), 4 = Grab (pick the part up to
-- re-attach it elsewhere). Switching tools never changes the selection, and
-- editing never changes the selection — no more "moving the wrong thing".
local TOOLS = { "move", "rotate", "stage", "grab", "groups" }
local TOOL_LABEL = { move = "MOVE", rotate = "ROTATE", stage = "STAGE", grab = "GRAB", groups = "ACTION GROUPS" }
local tool = "move"
local selected_uid = nil

-- ── Electronics & action groups ─────────────────────────────────────────────
-- The rulebook (scripts/electronics.lua) is a script on the scene's manager
-- node; nil in a harness without it, and then the builder simply has no power
-- readout and no groups editor rather than failing.
local elib_ref = nil
local function elib()
  if not elib_ref or not elib_ref.valid then
    elib_ref = findScript and findScript("electronics") or nil
  end
  return elib_ref
end

-- Every electronics module a part carries: the ones REG declares plus the ones
-- its flags imply (an engine's alternator, a decoupler's Decouple…).
local function part_mods(def)
  local E = elib()
  if E then return E.deriveMods(def, def.mods) end
  return def.mods
end

-- The craft's ACTION GROUPS while it's on the stand. `groups` stays nil until
-- the player edits one: until then the editor (and the flight) shows the
-- standard set built from what is aboard, so adding a solar panel puts it on
-- Deploy without anyone asking. `gid` is the group the editor has open.
local groups_state = { groups = nil, edited = false, gid = "1" }

-- The craft as blueprint-shaped records (uid → { uid, id, mods, … }), which
-- is what every electronics question is asked about.
local function craft_records()
  local out = {}
  for uid, p in pairs(parts) do
    local d = p.def
    out[uid] = { uid = uid, id = p.id, label = d.label, kind = d.kind, mods = part_mods(d),
                 legs = d.legs and 1 or 0, decouple = d.decouple and 1 or 0,
                 chute = d.chute and 1 or 0, rcs = d.rcs and 1 or 0, dock = d.dock and 1 or 0,
                 thrust = d.thrust or 0, sym = p.sym }
  end
  return out
end

local function hint(msg, secs)
  if hint_node then hint_node.text = msg end
  hint_t = secs or 2.5
end

-- The full key list is on the pause menu's Controls page; the idle line only
-- has to say how to start and how to leave (this scene has no pause menu: ESC
-- leaves it).
local HINT_IDLE = "click a part to select   ·   1 move · 2 rotate · 3 stage · 4 grab · 5 action groups   ·   ESC leave"
local HINT_GHOST = "click a node or any surface to place   ·   ALT = place free   ·   R yaw/spin · T pitch · Y roll   ·   X symmetry ×N · M mirror   ·   ESC cancel"
local HINT_GRAB = "move the mouse to slide the whole ship   ·   click to set it down"

local function publish_center()
  local n, sx, sy, sz = 0, 0.0, 0.0, 0.0
  for _, p in pairs(parts) do
    n = n + 1; sx = sx + p.x; sy = sy + p.y; sz = sz + p.z
  end
  partCount = n
  if n > 0 then centerX, centerY, centerZ = sx / n, sy / n, sz / n
  else centerX, centerY, centerZ = 0.0, 1.5, 0.0 end
end

-- Everything stacked ON `uid`, transitively (the subtree a pickup carries).
local function subtree(uid)
  local out, grew = { [uid] = true }, true
  while grew do
    grew = false
    for u, p in pairs(parts) do
      if p.parent and out[p.parent] and not out[u] then out[u] = true; grew = true end
    end
  end
  return out
end

local function set_part_pos(p, x, y, z)
  p.x, p.y, p.z = x, y, z
  if p.node then p.node.x, p.node.y, p.node.z = x, y, z end
end

local function set_part_rot(p, yaw, pitch, roll)
  p.yaw, p.pitch, p.roll = yaw, pitch, roll
  if p.node then p.node.yaw, p.node.pitch, p.node.roll = yaw, pitch, roll end
end

-- ── Orientation math ────────────────────────────────────────────────────────
-- Engine euler order is YXZ (yaw, pitch, roll). rot_basis returns the world
-- columns of the part's local X/Y/Z axes; eff_extents the axis-aligned
-- half-extents of the part's (rx, h/2, rz) box under that rotation — what
-- snapping and overlap tests need once parts can lie on their sides.
local function rot_basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  local X = { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz }
  local Y = { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz }
  local Z = { x = sy * cx, y = -sx, z = cy * cx }
  return X, Y, Z
end

local function eff_extents(def, yaw, pitch, roll)
  local X, Y, Z = rot_basis(yaw, pitch, roll)
  local hx, hy, hz = def.rx, def.h * 0.5, def.rz
  return math.abs(X.x) * hx + math.abs(Y.x) * hy + math.abs(Z.x) * hz,
         math.abs(X.y) * hx + math.abs(Y.y) * hy + math.abs(Z.y) * hz,
         math.abs(X.z) * hx + math.abs(Y.z) * hy + math.abs(Z.z) * hz
end

local function part_extents(p)
  return eff_extents(p.def, p.yaw, p.pitch, p.roll)
end

-- ── Symmetry geometry ───────────────────────────────────────────────────────
-- Rotate world vector (vx,vy,vz) about the hub part's stack axis by `a`.
local function rot_about(hub, vx, vy, vz, a)
  local e1, ax, e2 = rot_basis(hub.yaw, hub.pitch, hub.roll)
  local d = vx * ax.x + vy * ax.y + vz * ax.z
  local px, py, pz = vx - ax.x * d, vy - ax.y * d, vz - ax.z * d
  local c1 = px * e1.x + py * e1.y + pz * e1.z
  local c2 = px * e2.x + py * e2.y + pz * e2.z
  local ca, sa = math.cos(a), math.sin(a)
  local r1 = c1 * ca - c2 * sa
  local r2 = c1 * sa + c2 * ca
  return e1.x * r1 + e2.x * r2 + ax.x * d,
         e1.y * r1 + e2.y * r2 + ax.y * d,
         e1.z * r1 + e2.z * r2 + ax.z * d
end

-- A part's angle around the hub's axis (for mapping ring member → member).
local function angle_about(hub, p)
  local e1, ax, e2 = rot_basis(hub.yaw, hub.pitch, hub.roll)
  local vx, vy, vz = p.x - hub.x, p.y - hub.y, p.z - hub.z
  local d = vx * ax.x + vy * ax.y + vz * ax.z
  local px, py, pz = vx - ax.x * d, vy - ax.y * d, vz - ax.z * d
  return math.atan2(px * e2.x + py * e2.y + pz * e2.z,
                    px * e1.x + py * e1.y + pz * e1.z)
end

local function group_members(gid)
  local out = {}
  for uid, p in pairs(parts) do
    if p.sym == gid then out[#out + 1] = uid end
  end
  table.sort(out)
  return out
end

-- The ring's HUB part: first generation rings share a parent (the hub);
-- a chained ring (children mirrored onto ring members) inherits the hub of
-- its parents' ring. Bounded walk — malformed links return nil safely.
local function group_hub(gid, depth)
  depth = (depth or 0) + 1
  if depth > 8 then return nil end
  local members = group_members(gid)
  if #members == 0 then return nil end
  local first_parent = parts[members[1]] and parts[members[1]].parent
  if not first_parent then return nil end
  local shared = true
  for _, u in ipairs(members) do
    if not parts[u] or parts[u].parent ~= first_parent then shared = false break end
  end
  if shared then return parts[first_parent] end
  local pp = parts[first_parent]
  if pp and pp.sym then return group_hub(pp.sym, depth) end
  return nil
end

-- The outward self-orientation for a radial decoupler at direction (ux,uy,uz).
local function outward_orient(ux, uy, uz)
  local roll = math.asin(math.max(-1, math.min(1, -ux)))
  local pitch = math.atan2(uz, uy)
  return pitch, roll
end


-- The EDIT SET for a part: its subtree — and, for a symmetry-ring member,
-- every member's subtree. Rings pick up, scrap and highlight as ONE.
local function edit_set(uid)
  local p = parts[uid]
  if not (p and p.sym) then return subtree(uid) end
  local out = {}
  for _, m in ipairs(group_members(p.sym)) do
    for u in pairs(subtree(m)) do out[u] = true end
  end
  return out
end

-- ── Stats + staging readout ─────────────────────────────────────────────────
-- Stages mirror the FLIGHT model exactly: SPACE fires the lowest remaining
-- decoupler and everything at/below it detaches, and only the BOTTOM live
-- stage's engines burn (everything above the next decoupler waits its turn).
-- Stage k = the stack above the k-th decoupler, thrusting on the engines
-- between decouplers k and k+1 and drinking the tanks between them first:
-- the flight drains the tanks that leave SOONEST first (boosters, then the
-- bottom stage, upward), so a stage's Δv is its own tanks burned under
-- everything it still carries.
--
-- ── BALANCE: real rocket physics, scaled to these worlds ───────────────────
--
-- PROPELLANT HAS MASS. A fuel unit is FUEL_T_PER_UNIT tonnes (10 kg): a full
-- FT-S is 0.8 t of propellant in a 0.2 t tank. An engine burns thrust / ve
-- tonnes a second (`burn` is that in units), so the Δv is Tsiolkovsky's,
--
--     Δv = ve · ln(m_wet / m_dry)
--
-- and the flight flies the same thing: vessel_controller gives every part's
-- rigidbody its catalogue mass plus the propellant it still holds, so physics
-- flies the craft's live wet mass — a full stack climbs slowly and an emptying
-- one accelerates (the part prefabs carry the same dry masses as REG). A
-- second tank is not twice the Δv of one — it has to lift the first — which
-- is the diminishing return every real rocket lives with, and why staging
-- exists. Legs, chutes, cones and fins are tens of kilos.
--
-- ONE CATALOGUE PER SAVE. Worlds are generated 100–300 m across with 4.5–15 m/s²
-- of gravity, so escape runs from ~30 m/s to ~85, and no single set of engine
-- figures works across that: a Sputter that lifts the starter on a 15 g world
-- sends it out of a 4.5 g world's sphere of influence in three seconds. So the
-- parts are BUILT FOR THE HOME WORLD, once, the first time the save sees it:
--
--   thrust × g_home / G_REF       every craft has the same TWR on every save
--   ve     × (solved once)        the stock starter (Pod, Parachute, FT-S,
--                                 Sputter) flown straight up at full throttle
--                                 peaks at HOP_MULT × the First Flight's height
--
-- That is frozen in the save (`parts.rating`) and is what every catalogue card,
-- every readout and every flight uses: the same Sputter is exactly as strong on
-- a moon, another planet or the next launch. Nothing is re-rated at the pad and
-- nothing is hidden — the card prints the thrust and ve you fly with. Masses and
-- fuel loads never scale. (Burns are short because the worlds are: the natural
-- time of a world this size, sqrt(r/g), is about five seconds, and a hop to
-- twice its radius takes a few of them at full throttle.)
FUEL_T_PER_UNIT = 0.01
local G_REF = 7.0
-- The starter's full-throttle hop, as a multiple of the First Flight's height
-- (and never under HOP_MIN): enough margin that legs or a nose cone don't cost
-- the contract, and well short of The High Road (3.7× the First Flight).
HOP_MULT = 1.8
HOP_MIN = 220.0
RATING_VERSION = 2
local STARTER = { "pod", "chute", "tankS", "engineS" }

function launchWorld()
  local w = save.get("launch.world")
  if type(w) == "table" and (w.g or 0) > 0 and (w.r or 0) > 0 then
    return { name = w.name, g = w.g, r = w.r, soi = (w.soi or 0) > w.r and w.soi or w.r * 7.5 }
  end
  -- No base yet: a typical home of the save's WORLD SCALE (system_generator
  -- SCALES), so the first readout is the right order of magnitude. Unsaved.
  local gs = tonumber(save.get("g_scale")) or 1
  if gs >= 3 then
    -- scale 3 (system_generator SCALES[3]): planets 600–950 m
    return { name = nil, g = 6.0, r = 775.0, soi = 9600.0 }
  end
  if gs >= 2 then
    return { name = nil, g = 6.0, r = 310.0, soi = 3850.0 }
  end
  return { name = nil, g = G_REF, r = 165.0, soi = 1500.0 }
end

-- The altitude the "Made Orbit" contract asks a periapsis above on world w
-- (missions.lua: 10 % of the room to the edge of the sphere of influence).
function orbitAlt(w)
  w = w or launchWorld()
  local body_r = w.r + math.max(w.r * 0.035, 4)
  return 0.10 * math.max(1, w.soi - body_r)
end

-- Δv to that orbit from the pad, FLOWN WELL: the ideal two-burn climb (a
-- Hohmann ellipse from the ground to the orbit, then the circularisation)
-- plus the gravity a real ascent spends holding itself up — 50 % on these
-- worlds, which the 2-D ascent sim in smoke_balance measures at 40–60 % for
-- TWR 2.8 down to 1.3. What the readout quotes as "orbit needs".
function orbitNeed(w)
  w = w or launchWorld()
  local mu, R = w.g * w.r * w.r, w.r
  local ro = R + orbitAlt(w)
  local vp = math.sqrt(2 * mu * ro / (R * (R + ro)))
  local va = vp * R / ro
  return 1.5 * (vp + (math.sqrt(mu / ro) - va))
end

-- The First Flight's altitude on world w the way missions.lua resolves it
-- (15 % of the room between the body and the edge of its influence; the body
-- radius carries the same margin `system_generator` gives it), unrounded.
function firstFlightAlt(w)
  w = w or launchWorld()
  local body_r = w.r + math.max(w.r * 0.035, 4)
  return 0.15 * math.max(1, w.soi - body_r)
end

-- Where the stock starter is built to peak on world w.
function hopTarget(w)
  return math.max(HOP_MIN, HOP_MULT * firstFlightAlt(w))
end

-- Straight up from the surface at full throttle: thrust T (kN) on a craft of
-- m0 tonnes that burns mf tonnes of propellant at exhaust velocity ve (m/s),
-- lightening as it goes, under inverse-square gravity. Returns the apoapsis
-- ALTITUDE, or math.huge when the craft leaves the sphere of influence. A craft
-- too heavy to lift sits on the pad burning until it isn't (or never lifts).
-- Pure, so the smoke test can fly it too.
function hopApoapsis(T, m0, mf, ve, w)
  w = w or launchWorld()
  local mu, R = w.g * w.r * w.r, w.r
  if m0 <= 0 or T <= 0 or mf <= 0 or ve <= 0 or mf >= m0 then return 0 end
  local mdot = T / ve
  local steps = 600
  local dt = mf / mdot / steps
  local r, v, m = R, 0.0, m0
  for _ = 1, steps do
    local mm = m - 0.5 * mdot * dt         -- the mass at the middle of the step
    v = v + (T / mm - mu / (r * r)) * dt
    if r <= R and v < 0 then v = 0 end
    r = math.max(R, r + v * dt)
    m = m - mdot * dt
  end
  if r <= R and v <= 0 then return 0 end
  local e = 0.5 * v * v - mu / r
  if e >= -mu / w.soi then return math.huge end
  return -mu / e - R
end

-- Escape speed from the surface to the edge of the sphere of influence.
function escapeSpeed(w)
  w = w or launchWorld()
  local mu = w.g * w.r * w.r
  return math.sqrt(math.max(0, 2 * mu * (1 / w.r - 1 / w.soi)))
end

-- The stock starter on the reference figures: wet mass, propellant, thrust, ve.
local function starter_numbers()
  local m0, mf, T, ve = 0.0, 0.0, 0.0, 0.0
  for _, id in ipairs(STARTER) do
    local d = REG[id]
    local f = (d.fuel or 0) * FUEL_T_PER_UNIT
    m0, mf = m0 + d.mass + f, mf + f
    if d.thrust then T, ve = d.thrust, d.ve end
  end
  return m0, mf, T, ve
end

-- { thrust = ×, ve = × } the catalogue is built with for this save (see the
-- header). The first world it is asked about with a NAME is the home world, and
-- its answer is written to the save and never recomputed; until a base exists
-- (no named world) the reference figures stand, unsaved.
local memo_key, memo_val = nil, nil
function rating(w)
  w = w or launchWorld()
  local key = string.format("%s/%.4f/%.3f/%.1f", tostring(w.name), w.g, w.r, w.soi)
  if key == memo_key then return memo_val end
  local saved = w.name and save.get("parts.rating")
  local hit
  if type(saved) == "table" and saved.name == w.name and saved.v == RATING_VERSION
    and (saved.thrust or 0) > 0 and (saved.ve or 0) > 0 then
    hit = saved
  else
    local kT = w.g / G_REF
    local m0, mf, T, ve = starter_numbers()
    local target = hopTarget(w)
    local lo, hi = 0.05, 20.0
    for _ = 1, 48 do
      local kV = 0.5 * (lo + hi)
      if hopApoapsis(T * kT, m0, mf, ve * kV, w) > target then hi = kV else lo = kV end
    end
    hit = { thrust = kT, ve = 0.5 * (lo + hi), name = w.name, g = w.g, r = w.r,
            soi = w.soi, hop = target, v = RATING_VERSION }
    if w.name then save.set("parts.rating", hit) end
  end
  memo_key, memo_val = key, hit
  return hit
end

-- A part as this save builds it: the registry entry with thrust and ve built
-- for the home world, the burn rate that follows from them (units/s), and a
-- tank's propellant density. Everything else is REG's.
local eff_cache = setmetatable({}, { __mode = "k" })
function liveDef(id)
  local d = type(id) == "table" and id or REG[id]
  if not d then return nil end
  if not (d.thrust or d.fuel) then return d end
  local k = rating()
  local c = eff_cache[d]
  if c and c.kT == k.thrust and c.kV == k.ve then return c.def end
  local out = {}
  for key, v in pairs(d) do out[key] = v end
  if d.thrust then
    out.thrust = d.thrust * k.thrust
    out.ve = (d.ve or 160) * k.ve
    out.burn = out.thrust / (out.ve * FUEL_T_PER_UNIT)
  end
  if d.fuel then out.fuel_t = FUEL_T_PER_UNIT end
  eff_cache[d] = { kT = k.thrust, kV = k.ve, def = out }
  return out
end

-- Δv of a burn from m0 down to m1 tonnes on engines totalling `th` kN and
-- `burn` units/s (so exhaust velocity th / (burn · FUEL_T_PER_UNIT)).
local function burn_dv(th, burn, m0, m1)
  if th <= 0 or burn <= 0 or m1 <= 0 or m0 <= m1 then return 0.0 end
  return th / (burn * FUEL_T_PER_UNIT) * math.log(m0 / m1)
end

-- THE NUMBERS, as data: what each SPACE leaves burning, with the thrust and burn
-- rate the blueprint will carry into flight. Global and pure (reads `parts`,
-- returns tables) so the smoke test reads the figures rather than scraping them
-- back out of the panel text. Masses are WET (dry + propellant aboard).
--
--   boosters  { n, m, th, fu, m0, dv, twr, tb }  or nil — lit with stage 1,
--             their tanks drunk first, then thrown away
--   stages    { { k, m, th, burn, fu, dv, twr, tb } … }  firing order
--   dv        the total
--   twr       lift-off TWR (boosters and stage 1 together)
--   hop       apoapsis altitude for Z + SPACE straight up, never staging
--             (math.huge = escape)
--   world     the launch world the figures are for
function stageStats()
  local w = launchWorld()
  local U = FUEL_T_PER_UNIT
  local booster_uids = {}
  local n_boost = 0
  for uid, p in pairs(parts) do
    if p.def.radial then
      n_boost = n_boost + 1
      for u in pairs(subtree(uid)) do booster_uids[u] = true end
    end
  end
  local out = { stages = {}, world = w, dv = 0.0 }
  local cuts = {}
  for _, p in pairs(parts) do
    if p.def.decouple and not p.def.radial then cuts[#cuts + 1] = p.y end
  end
  table.sort(cuts)
  local raw, fu_all = {}, 0
  for k = 0, #cuts do
    local lo = (k == 0) and -math.huge or cuts[k]
    local hi = cuts[k + 1] or math.huge
    local s = { m = 0.0, th = 0.0, burn = 0.0, fu = 0 }
    for uid, p in pairs(parts) do
      if not booster_uids[uid] and p.y > lo + 0.01 then
        local d = liveDef(p.def)
        s.m = s.m + d.mass + (d.fuel or 0) * U
        if p.y < hi - 0.01 then
          s.fu = s.fu + (d.fuel or 0)
          if (d.thrust or 0) > 0 then
            s.th = s.th + d.thrust
            s.burn = s.burn + (d.burn or 0)
          end
        end
      end
    end
    fu_all = fu_all + s.fu
    raw[k] = s
  end
  local s1 = raw[0]
  local bm, bth, bburn, bfu = 0.0, 0.0, 0.0, 0
  if n_boost > 0 then
    for u in pairs(booster_uids) do
      local p = parts[u]
      if p then
        local d = liveDef(p.def)
        bm = bm + d.mass + (d.fuel or 0) * U
        bfu = bfu + (d.fuel or 0)
        bth = bth + (d.thrust or 0)
        bburn = bburn + (d.burn or 0)
      end
    end
    -- The core's stage-1 engines burn alongside, drinking the boosters' tanks
    -- first (the flight drains the tanks that leave soonest first).
    local m0 = s1.m + bm
    local th, burn = bth + s1.th, bburn + s1.burn
    out.boosters = { n = n_boost, m = bm, th = bth, fu = bfu, m0 = m0,
                     dv = burn_dv(th, burn, m0, m0 - bfu * U),
                     twr = (th > 0) and th / (m0 * w.g) or 0,
                     tb = (burn > 0) and bfu / burn or 0 }
    out.dv = out.dv + out.boosters.dv
    fu_all = fu_all + bfu
  end
  for k = 0, #cuts do
    local s = raw[k]
    if k == 0 or s.th > 0 or s.fu > 0 then
      -- A stage with no engine gets no Δv, which is the correct answer and the
      -- one that catches "I forgot to put an engine on the upper stage".
      local st = { k = k + 1, m = s.m, th = s.th, burn = s.burn, fu = s.fu,
                   dv = burn_dv(s.th, s.burn, s.m, s.m - s.fu * U),
                   twr = (s.m > 0 and s.th > 0) and s.th / (s.m * w.g) or 0,
                   tb = (s.burn > 0) and s.fu / s.burn or 0 }
      out.stages[#out.stages + 1] = st
      out.dv = out.dv + st.dv
    end
  end
  local T, burn, m0 = s1.th + bth, s1.burn + bburn, s1.m + bm
  out.twr = (T > 0 and m0 > 0) and T / (m0 * w.g) or 0
  -- Z + SPACE, straight up, never staging: stage 1's engines (and any boosters)
  -- burn the whole pool, upper stages' tanks included.
  if T > 0 and burn > 0 and fu_all > 0 then
    out.hop = hopApoapsis(T, m0, fu_all * U, T / (burn * U), w)
    out.tb = fu_all / burn
  end
  return out
end

local function fmt_alt(m)
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

local function stage_lines()
  local s = stageStats()
  local out = ""
  local function dv_s(v) return v > 0 and string.format("%.0f m/s", v) or "—" end
  if s.boosters then
    local b = s.boosters
    out = out .. string.format("\nBOOSTERS ×%d:  TWR %.2f   Δv %s   burn %.1f s   %.2f t",
      b.n, b.twr, dv_s(b.dv), b.tb, b.m)
  end
  for _, st in ipairs(s.stages) do
    out = out .. string.format("\nSTAGE %d:  TWR %.2f   Δv %s   burn %.1f s   %.2f t",
      st.k, st.twr, dv_s(st.dv), st.tb, st.m)
  end
  if #s.stages > 1 or s.boosters then
    out = out .. string.format("\nTOTAL  Δv %s", dv_s(s.dv))
  end
  -- What that Δv MEANS here. Δv alone misleads on a world this small: gravity
  -- eats a large share of a short, steep climb, so the starter's ~55 m/s peaks
  -- a few hundred metres up although escape is quoted at 45-odd.
  local w = s.world
  local where = w.name or "the launch world"
  out = out .. string.format("\n%s:  g %.1f m/s²  ·  escape %.0f m/s", where, w.g, escapeSpeed(w))
  -- What the Δv buys, in one line: the orbit the contracts ask for costs this
  -- much flown well, so the player can see whether a design is a hop or an
  -- orbiter before paying for it. TWR under 1 is said first: no Δv matters
  -- if the craft can't leave the pad.
  local need = orbitNeed(w)
  local verdict
  if (s.twr or 0) > 0 and s.twr < 1.0 then
    verdict = "too heavy to lift off — add thrust or lose mass"
  elseif s.dv >= need * 1.6 then
    verdict = "orbit with plenty to spare"
  elseif s.dv >= need then
    verdict = "enough for orbit"
  elseif s.dv > 0 then
    verdict = "a suborbital hop"
  end
  out = out .. string.format("\norbit (%s up) needs ≈ %.0f m/s%s", fmt_alt(orbitAlt(w)), need,
    verdict and ("  →  " .. verdict) or "")
  if s.hop then
    if s.hop == math.huge then
      out = out .. "\nfull throttle straight up: escapes " .. where
    elseif s.hop > 0 then
      out = out .. string.format("\nfull throttle straight up peaks ≈ %s", fmt_alt(s.hop))
    end
  end
  return out
end

-- The current stage items: key → { label, uids = {decoupler uids} }.
local function stage_items()
  local items = {}
  for uid, p in pairs(parts) do
    if p.def.decouple then
      if p.def.radial then
        local key = p.sym and ("g" .. p.sym) or ("u" .. uid)
        local it = items[key]
        if not it then
          it = { key = key, uids = {}, ring = true, y = p.y }
          items[key] = it
        end
        it.uids[#it.uids + 1] = uid
        it.y = math.min(it.y, p.y)
      else
        items["u" .. uid] = { key = "u" .. uid, uids = { uid }, ring = false, y = p.y }
      end
    elseif p.def.fairing then
      -- A fairing's jettison is a staging event too (and an action).
      items["u" .. uid] = { key = "u" .. uid, uids = { uid }, ring = false, y = p.y, fair = true }
    end
  end
  return items
end

-- Reconcile stage_order with the live items: stale keys drop, new keys slot
-- in by the classic default (rings first, then axial bottom-up).
local function sync_stage_order()
  local items = stage_items()
  local kept = {}
  for _, key in ipairs(stage_order) do
    if items[key] then
      kept[#kept + 1] = key
      items[key].placed = true
    end
  end
  local fresh = {}
  for _, it in pairs(items) do
    if not it.placed then fresh[#fresh + 1] = it end
  end
  -- New items slot by their SAVED stage when reloading a blueprint, else by
  -- the classic default: rings first, axial bottom-up.
  local function saved_of(it)
    local s = nil
    for _, u in ipairs(it.uids) do
      local su = saved_stage[u]
      if su and su > 0 and (not s or su < s) then s = su end
    end
    return s or 1e9
  end
  table.sort(fresh, function(a, b)
    local sa, sb = saved_of(a), saved_of(b)
    if sa ~= sb then return sa < sb end
    if a.ring ~= b.ring then return a.ring end
    return a.y < b.y
  end)
  for _, it in ipairs(fresh) do kept[#kept + 1] = it.key end
  stage_order = kept
  return items
end

-- Lazily resolve (and cache) the pool of StageRow## UI nodes authored in
-- builder.ron. Each stage event gets its OWN node so `node:uiRect()` gives an
-- exact per-row rect to hit-test against — no font-metric guessing.
local function stage_row_node(i)
  if not stage_rows then
    stage_rows = {}
    for k = 1, STAGE_MAX_ROWS do
      stage_rows[k] = find(string.format("StageRow%02d", k))
    end
  end
  return stage_rows[i]
end

-- The label for stage #k (its firing order) given its separation-event item.
local function stage_label(k, it)
  if it.fair then return string.format("#%d   FAIRING", k) end
  if it.ring then
    return string.format("#%d   BOOSTER RING ×%d", k, #it.uids)
  end
  return string.format("#%d   DECOUPLER", k)
end

-- Paint the STAGING panel: each separation event is a numbered STAGE row (#1
-- fires first), named by what it does. Visible only while the STAGE tool is
-- active (it declutters otherwise). The hovered row lights up; the dragged row
-- fades to a placeholder while its floating ghost rides the cursor.
local function paint_stages()
  if not stage_node2 then stage_node2 = find("StagePanel") end
  if not stage_node2 then return end
  local items = sync_stage_order()
  local panel = stage_node2:getcomponent("UiElement")
  local show = (tool == "stage") and #stage_order > 0
  if panel then panel.visible = show end
  -- One row node per stage event; extras hide (the pool is fixed-size).
  for k = 1, STAGE_MAX_ROWS do
    local rn = stage_row_node(k)
    if rn then
      local el = rn:getcomponent("UiElement")
      local key = stage_order[k]
      local it = key and items[key]
      if show and it then
        if el then el.visible = true end
        rn.text = stage_label(k, it)
        local dragged = stage_drag and stage_drag.key == key
        local hot = (stage_hover == key)
        if el then
          if dragged then         -- gap left behind by the picked-up row
            el.fillA, el.textA = 0.06, 0.30
          elseif hot then         -- cursor is over this row
            el.fillA, el.textA = 0.55, 1.0
          else
            el.fillA, el.textA = 0.16, 1.0
          end
        end
      elseif el then
        el.visible = false
      end
    end
  end
  -- The floating ghost mirrors the dragged row's live label (its number updates
  -- as the order changes); handle_staging positions it on the cursor.
  if not stage_ghost then stage_ghost = find("StageDragGhost") end
  if stage_ghost then
    local gel = stage_ghost:getcomponent("UiElement")
    if stage_drag then
      local row = nil
      for k, key in ipairs(stage_order) do if key == stage_drag.key then row = k end end
      local it = items[stage_drag.key]
      if row and it then stage_ghost.text = stage_label(row, it) end
      if gel then gel.visible = true end
    elseif gel then
      gel.visible = false
    end
  end
end

-- Draw a numbered badge (a filled disc + the number over it) at each stage's
-- decoupler(s), in the STAGE tool — so the row and the physical part are
-- unmistakably the same one. The hovered row's badges glow.
local function draw_stage_badges()
  if tool ~= "stage" then return end
  local items = sync_stage_order()
  for i, key in ipairs(stage_order) do
    local it = items[key]
    if it then
      local hot = (stage_hover == key) or (stage_drag and stage_drag.key == key)
      local r, g, b = 1.0, 0.75, 0.25
      if hot then r, g, b = 0.3, 1.0, 0.5 end
      for _, uid in ipairs(it.uids) do
        local p = parts[uid]
        if p then
          -- A camera-facing badge disc + a bright ring; the stage number is
          -- read off the panel row of the same color when hovered.
          local up = { x = 0, y = 1, z = 0 }
          draw.disc(p.x, p.y + 0.15, p.z, up.x, up.y, up.z, 0.0, 0.22 + (hot and 0.08 or 0),
            r, g, b, 0.9)
          draw.ring(p.x, p.y + 0.15, p.z, up.x, up.y, up.z, 0.30, r, g, b, 1.0)
          -- little riser so the badge reads above the part
          draw.line(p.x, p.y, p.z, p.x, p.y + 0.15, p.z, r, g, b, 0.8)
        end
      end
    end
  end
end

-- The company ledger, if this scene has one mounted (it does; the builder is
-- where money is spent). Fetched fresh — scripts don't survive a scene load.
local co_ref = nil
local function company_ref()
  if not co_ref or not co_ref.node or not co_ref.node.valid then
    co_ref = findScript("company")
  end
  return co_ref
end

-- What this build costs to put on the pad.
local function build_cost()
  local c = 0
  for _, p in pairs(parts) do c = c + p.def.cost end
  return c
end

-- The header card (BuildTitle) holds a heading and this stats text. The text
-- is "fit" tall in the scene, and the card grows to where the engine laid it
-- out: the stats start 32 down and the card keeps a 10 bottom margin under them.
local STATS_TOP, STATS_PAD = 32, 10
local header_refs = {}
local function set_stats(text)
  stats_node.text = text
end

local function fit_header()
  local r = header_refs
  if not r.card and find then r.card = find("BuildTitle") end
  if not (r.card and stats_node and stats_node.uiRect) then return end
  local h = select(4, stats_node:uiRect())
  local sh = camera and camera.screenSize and select(2, camera.screenSize())
  if not (h and h > 0 and sh and sh > 0) then return end
  local cel = r.card:getcomponent("UiElement")
  local want = math.ceil(STATS_TOP + h * 720 / sh + STATS_PAD)
  if cel and math.abs(cel.height - want) > 0.5 then cel.height = want end
end

-- What a first rocket is still missing, in the order you'd add it. A pod on
-- its own sat on the pad with a readout of mass and money and nothing to say
-- that it wasn't a rocket yet.
local function next_step(has)
  if not has.command then return "Next: add a Pod Mk1 (crewed) or a Probe Core — something has to fly it" end
  -- A ROVER (wheels, no engine) is whole without tanks: it drives out.
  if has.wheel and not has.engine then
    if (has.wheels or 0) < 3 then return "Next: add wheels — four on two flanks (M mirrors them left/right)" end
    return "Ready to drive — press LAUNCH (W/S drive · A/D steer · B brakes)"
  end
  if not has.tank then return "Next: add a fuel tank under the pod" end
  if not has.engine then return "Next: add an engine under the tank" end
  if not has.chute and has.crewed then return "Next: add a parachute on top of the pod" end
  return "Ready to fly — press LAUNCH"
end

-- CAN THIS GO TO THE PAD? Global and pure so the LAUNCH button, the readout and
-- the smoke test all ask the same question.
--
--   block   why LAUNCH is refused outright (nil = it may launch). Only a craft
--           nobody can fly is refused: no crewed part means there is no seat,
--           and the flight has nobody to put in it.
--   warn    things that are legal and almost certainly a mistake — no engine,
--           no parachute, too heavy to lift. LAUNCH asks before it charges.
function launchCheck()
  local has, n = {}, 0
  for _, p in pairs(parts) do
    n = n + 1
    has[p.def.kind] = true
    if p.def.chute then has.chute = true end
    if p.def.legs then has.legs = true end
    if p.def.wheel then has.wheel = true; has.wheels = (has.wheels or 0) + 1 end
  end
  has.command = has.crewed or has.probe
  if n == 0 then return { block = "nothing to launch — build something first", warn = {}, has = has } end
  if not has.command then
    return { block = "no command part — add a Pod Mk1 (crewed) or a Probe Core", warn = {}, has = has }
  end
  local warn = {}
  if not has.engine and not has.wheel then
    warn[#warn + 1] = "no engine — it will sit on the pad"
  else
    local s = stageStats()
    if (s.twr or 0) > 0 and s.twr < 1.0 then
      warn[#warn + 1] = string.format("TWR %.2f — too heavy to lift off %s", s.twr,
        s.world.name or "this world")
    end
    if s.hop == math.huge then
      warn[#warn + 1] = "full throttle straight up escapes " .. (s.world.name or "this world")
        .. " — watch the apoapsis and cut the throttle"
    end
  end
  if not has.chute and has.crewed and not (has.wheel and not has.engine) then
    warn[#warn + 1] = "no parachute — the pod will not survive the landing"
  end
  if has.wheel then
    local _, nx, nz, other = wheelAxles()
    if other > 0 or (nx > 0 and nz > 0) then
      warn[#warn + 1] = "wheels on more than one axle line — mount them all on two opposite flanks or they can't all drive"
    end
  end
  -- A probe with nothing aboard to keep it powered is a probe that goes dark
  -- before it gets anywhere. Say how long it has.
  if has.probe and not has.crewed then
    local pw = powerStats()
    if pw and pw.solar <= 0 and pw.idle > 0 then
      local secs = pw.store / pw.idle
      if secs < 600 then
        warn[#warn + 1] = string.format("no solar panels — the probe runs flat after ≈ %d min idle", math.floor(secs / 60 + 0.5))
      end
    end
  end
  return { warn = warn, has = has }
end

-- THE ELECTRICAL PICTURE of the craft on the stand (electronics.summary):
-- battery store, solar at home-orbit daylight, the idle and peak draw, and how
-- far its antennas reach. Global and pure so the smoke test reads the numbers.
function powerStats()
  local E = elib()
  if not E then return nil end
  local recs = craft_records()
  local s = E.summary(recs, 1.0)
  s.records = recs
  return s
end

local function fmt_range(m)
  if m >= 1e6 then return string.format("%.0f Mm", m / 1e6) end
  if m >= 1e4 then return string.format("%.0f km", m / 1000) end
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

local function fmt_secs(t)
  if t == math.huge then return "indefinitely" end
  if t >= 3600 then return string.format("%.1f h", t / 3600) end
  if t >= 60 then return string.format("%.0f min", t / 60) end
  return string.format("%.0f s", t)
end

-- Two lines for the header card: POWER (store, supply, the draw at idle and
-- how long the batteries carry it in the dark) and COMMS (how far the best
-- antenna reaches home and another craft, and whether it relays).
local function elec_lines()
  local s = powerStats()
  if not s then return "" end
  local out = ""
  if s.store > 0 or s.solar > 0 or s.idle > 0 then
    local dark = (s.idle > 0) and (s.store / s.idle) or math.huge
    local supply = s.solar > 0 and string.format("  ·  sun +%.1f/s", s.solar) or ""
    local verdict
    if s.solar >= s.idle and s.idle > 0 then
      verdict = "sun covers it"
    elseif s.idle > 0 then
      verdict = fmt_secs(dark) .. " on battery"
    end
    out = out .. string.format("\nPOWER  %.0f EC%s  ·  idle −%.2f/s%s", s.store, supply,
      s.idle, verdict and ("  ·  " .. verdict) or "")
    if (s.motors or 0) > 0 then
      -- Wheels, actuators and the drill draw only while they work.
      out = out .. string.format("\nMOTORS  −%.1f/s flat out  ·  %s of driving on battery", s.motors,
        fmt_secs(s.store / math.max(1e-6, s.motors + s.idle)))
    end
  end
  if s.antenna.any > 0 then
    out = out .. string.format("\nCOMMS  home %s  ·  craft to craft %s%s", fmt_range(s.reachHome),
      fmt_range(s.reachCraft), s.relay and "  ·  relay" or "")
  elseif s.probe > 0 then
    out = out .. "\nCOMMS  none — a probe with no antenna can't be flown"
  end
  if s.probe > 0 and s.crew == 0 then
    out = out .. "\nPROBE  flies only with power and a link home"
  end
  return out
end

local launch_btn_el = nil
local function paint_launch_button(chk)
  if not launch_btn_el then
    local n = find and find("LaunchBtn")
    launch_btn_el = n and n:getcomponent("UiElement") or false
  end
  if launch_btn_el then
    local want = chk.block and 1 or 0
    if launch_btn_el.disabled ~= want then launch_btn_el.disabled = want end
  end
end

local function refresh_stats()
  paint_stages()
  if not stats_node then return end
  -- Mass as it stands on the pad: dry parts plus full tanks.
  local mass, dry, cost, n = 0.0, 0.0, 0, 0
  for _, p in pairs(parts) do
    n = n + 1
    dry = dry + p.def.mass
    mass = mass + p.def.mass + (p.def.fuel or 0) * FUEL_T_PER_UNIT
    cost = cost + p.def.cost
  end
  local chk = launchCheck()
  paint_launch_button(chk)
  if n == 0 then
    set_stats("empty pad — start with a Pod Mk1 from the catalogue")
    return
  end
  -- Lift-off TWR: what the first stage (and any boosters) pushes against the
  -- whole stack, in the LAUNCH WORLD's gravity — not Earth's 9.81, which
  -- understated it by half on the review's world. The flight HUD reads the same
  -- figure at the pad.
  local st = stageStats()
  local twr_s = ((st.twr or 0) > 0) and string.format("  ·  TWR %.2f", st.twr) or ""
  -- The build cost against the company's actual balance: you should be able to
  -- see you can't afford it WHILE you're adding the part, not after you press
  -- LAUNCH. Over budget turns the figure red-flagged rather than hiding it.
  local co = company_ref()
  local bal = co and co.balance and co.balance() or nil
  -- "cost $400 of $1,170" read as a progress bar; it is a price and a budget.
  local money = string.format("cost $%d", cost)
  if bal then
    money = string.format("cost %s   ·   budget %s%s", co.money(cost), co.money(bal),
      (cost > bal) and "   ⚠ OVER BUDGET" or "")
  end
  -- What to do next while it's still being built; once it's a whole rocket,
  -- the first thing LAUNCH would ask you about (too heavy, escapes).
  local status = chk.block and ("⚠ " .. chk.block) or next_step(chk.has)
  local whole = (chk.has.engine and (chk.has.chute or not chk.has.crewed) and chk.has.tank)
    or (chk.has.wheel and not chk.has.engine and (chk.has.wheels or 0) >= 3)
  if not chk.block and whole and #chk.warn > 0 then status = "⚠ " .. chk.warn[1] end
  local mass_s = (mass > dry + 1e-6) and string.format("%.2f t (%.2f dry)", mass, dry)
    or string.format("%.2f t", mass)
  set_stats(string.format("%d %s  ·  %s%s\n%s\n%s\ntool: %s%s%s%s",
    n, n == 1 and "part" or "parts", mass_s, twr_s, money, status,
    TOOL_LABEL[tool] or "?",
    sym_mirror and "  ·  mirror" or (sym_n > 1 and ("  ·  symmetry ×" .. sym_n) or ""),
    elec_lines(),
    stage_lines()))
end

-- ── Undo (robust: ops that can't apply yet re-push and wait) ────────────────
local function push_undo(op)
  undo_stack[#undo_stack + 1] = op
  if #undo_stack > 40 then table.remove(undo_stack, 1) end
end

local function spawn_part(id, x, y, z, yaw, parent, uid, pitch, roll, att, sym, mir)
  local def = REG[id]
  local u = uid or next_uid
  if not uid then next_uid = next_uid + 1 end
  pending_spawns = pending_spawns + 1
  spawn(def.prefab, vec3(x, y, z), function(node)
    node.yaw, node.pitch, node.roll = yaw or 0, pitch or 0, roll or 0
    parts[u] = { id = id, def = def, node = node, x = x, y = y, z = z,
                 yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0,
                 parent = parent, att = att, sym = sym, mir = mir }
    pending_spawns = pending_spawns - 1
    publish_center(); refresh_stats()
  end)
  return u
end

local function remove_part(uid)
  local p = parts[uid]
  if not p then return nil end
  local data = { uid = uid, id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw,
                 pitch = p.pitch, roll = p.roll, parent = p.parent,
                 att = p.att, sym = p.sym, mir = p.mir }
  if p.node then destroy(p.node) end
  parts[uid] = nil
  for _, q in pairs(parts) do
    if q.parent == uid then q.parent = nil end
  end
  publish_center(); refresh_stats()
  return data
end

local function undo()
  if pending_spawns > 0 then return end -- let in-flight spawns land first
  local op = table.remove(undo_stack)
  if not op then return end
  if op.type == "place" then
    if not remove_part(op.uid) then return end
  elseif op.type == "place_group" then
    -- A symmetry ring placed as one op un-places as one op.
    for _, u in ipairs(op.uids) do remove_part(u) end
  elseif op.type == "scrap" then
    for _, d in ipairs(op.parts) do
      spawn_part(d.id, d.x, d.y, d.z, d.yaw, d.parent, d.uid, d.pitch, d.roll,
                 d.att, d.sym, d.mir)
      if d.uid >= next_uid then next_uid = d.uid + 1 end
    end
  elseif op.type == "move" then
    for _, m in ipairs(op.moved) do
      local p = parts[m.uid]
      if p then
        set_part_pos(p, m.x, m.y, m.z)
        if m.yaw then set_part_rot(p, m.yaw, m.pitch or 0, m.roll or 0) end
        p.parent = m.parent
      end
    end
  end
  publish_center(); refresh_stats()
end

-- ── Picking & snapping ──────────────────────────────────────────────────────
local function screen_of(x, y, z)
  local sx, sy, _, on = camera.worldToScreen(x, y, z)
  return sx, sy, on
end

local function part_under_cursor(px)
  local mx, my = input.mouse()
  -- Precise first: a ray through the cursor against the parts' hulls.
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local hit = raycast(ox, oy, oz, dx, dy, dz, 300.0)
  if hit and hit.node then
    for uid, p in pairs(parts) do
      if p.node and p.node.id == hit.node.id then return uid end
    end
  end
  -- Fallback: nearest projected center (small parts between big ones).
  local best, best_d = nil, px * px
  for uid, p in pairs(parts) do
    local sx, sy, on = screen_of(p.x, p.y, p.z)
    if on then
      local d = (sx - mx) ^ 2 + (sy - my) ^ 2
      if d < best_d then best, best_d = uid, d end
    end
  end
  return best
end

-- In-game telegraphs (draw.* — always visible, unlike the editor's debug
-- gizmo layer). Rings mark attach nodes; boxes outline parts.
local function outline(p, r, g, b, a)
  local ex, ey, ez = part_extents(p)
  draw.box(p.x, p.y, p.z, ex + 0.06, ey + 0.06, ez + 0.06,
           p.yaw or 0, r, g, b, a or 1.0)
end

-- Every free attach node of part `p` for the current ghost: axial top/bottom
-- (along the part's OWN axis — a pitched part's stack continues sideways) +
-- 4 radial side nodes on `side = true` parts. Each node carries the world
-- point where the GHOST CENTER would land, so snapping is one lookup.
local function is_side_occupied(px, py, pz, exclude)
  for uid, q in pairs(parts) do
    if not (exclude and exclude[uid]) then
      local ex, ey, ez = part_extents(q)
      if math.abs(px - q.x) < ex * 0.7 and math.abs(py - q.y) < ey * 0.7
        and math.abs(pz - q.z) < ez * 0.7 then
        return true
      end
    end
  end
  return false
end

local function attach_nodes_of(uid, p, gdef, g_ext_y, exclude, occupied_top, occupied_bottom)
  local out = {}
  local X, Y, Z = rot_basis(p.yaw, p.pitch, p.roll)
  local hh = p.def.h * 0.5
  if p.def.top and gdef.bottom and not occupied_top[uid] then
    local ax, ay, az = p.x + Y.x * hh, p.y + Y.y * hh, p.z + Y.z * hh
    out[#out + 1] = { uid = uid, side = "top", x = ax, y = ay, z = az,
      cx = ax + Y.x * g_ext_y, cy = ay + Y.y * g_ext_y, cz = az + Y.z * g_ext_y }
  end
  if p.def.bottom and gdef.top and not occupied_bottom[uid] then
    local ax, ay, az = p.x - Y.x * hh, p.y - Y.y * hh, p.z - Y.z * hh
    out[#out + 1] = { uid = uid, side = "bottom", x = ax, y = ay, z = az,
      cx = ax - Y.x * g_ext_y, cy = ay - Y.y * g_ext_y, cz = az - Y.z * g_ext_y }
  end
  -- Radial flanks: ghost sits side-by-side at the same height, its center
  -- pushed out by host half-width + the ghost's own half-width that way.
  if p.def.side then
    local gex, gey, gez = eff_extents(gdef, ghost.yaw, ghost.pitch, ghost.roll)
    local dirs
    if p.def.radial then
      -- A mounted radial decoupler's usable face is its disc's OUTWARD +Y
      -- (the inner face is against the hull): ONE node there, and whatever
      -- attaches keeps its own orientation — a vertical booster tank hangs
      -- off the disc exactly like KSP.
      dirs = { { a = Y, r = hh } }
    else
      dirs = {
        { a = X, r = p.def.rx },
        { a = { x = -X.x, y = -X.y, z = -X.z }, r = p.def.rx },
        { a = Z, r = p.def.rz },
        { a = { x = -Z.x, y = -Z.y, z = -Z.z }, r = p.def.rz },
      }
    end
    for _, d in ipairs(dirs) do
      -- Ghost half-width projected along the outward direction.
      local g = math.abs(d.a.x) * gex + math.abs(d.a.y) * gey + math.abs(d.a.z) * gez
      local ax = p.x + d.a.x * d.r
      local ay = p.y + d.a.y * d.r
      local az = p.z + d.a.z * d.r
      local cx, cy, cz = ax + d.a.x * g, ay + d.a.y * g, az + d.a.z * g
      if not is_side_occupied(cx, cy, cz, exclude) then
        out[#out + 1] = { uid = uid, side = "radial", x = ax, y = ay, z = az,
          cx = cx, cy = cy, cz = cz, dx = d.a.x, dy = d.a.y, dz = d.a.z }
      end
    end
  end
  return out
end

-- The best FREE attach node for the current ghost (nearest to the cursor on
-- screen, within snap_px). Carried stacks never attach to themselves.
local function find_snap()
  if not ghost then return nil end
  local gdef = ghost.def
  local mx, my = input.mouse()
  local best, best_d = nil, params.snap_px * params.snap_px
  local exclude = {}
  if ghost.carried then
    for _, m in ipairs(ghost.carried) do exclude[m.uid] = true end
  end
  local occupied_top, occupied_bottom = {}, {}
  for _, p in pairs(parts) do
    if p.parent and parts[p.parent] and not exclude[p.parent] and p.att ~= "radial" and p.att ~= "surface" then
      if p.y >= parts[p.parent].y then occupied_top[p.parent] = true
      else occupied_bottom[p.parent] = true end
    end
  end
  local _, g_ext_y = eff_extents(gdef, ghost.yaw, ghost.pitch, ghost.roll)
  for uid, p in pairs(parts) do
    if not exclude[uid] then
      for _, a in ipairs(attach_nodes_of(uid, p, gdef, g_ext_y, exclude,
                                         occupied_top, occupied_bottom)) do
        local sx, sy, on = screen_of(a.x, a.y, a.z)
        if on then
          local d = (sx - mx) ^ 2 + (sy - my) ^ 2
          if d < best_d then best, best_d = a, d end
        end
      end
    end
  end
  -- No node near the cursor: the surface under it (round two).
  if not best then best = surfaceUnderCursor(exclude) end
  return best
end

-- Would a part of `def` (at the ghost's orientation) centered at (x,y,z)
-- DEEPLY overlap a placed part? FORGIVING on purpose: parts live in ONE rigid
-- compound and dropped stages don't collide with each other, so touching /
-- clipping is harmless — only a near-total overlap (one part buried inside
-- another) is worth refusing. The old 0.9 gate rejected boosters that merely
-- HUG the hull, forcing the pull-out-then-nudge-back dance. 0.55 = "you'd
-- have to shove it most of the way through" before it's blocked.
local OVERLAP = 0.55
local function overlaps(def, x, y, z, exclude, gy, gp, gr)
  local ax, ay, az = eff_extents(def, gy, gp, gr)
  for uid, p in pairs(parts) do
    if not (exclude and exclude[uid]) then
      local bx, by, bz = part_extents(p)
      if math.abs(x - p.x) < (ax + bx) * OVERLAP
        and math.abs(y - p.y) < (ay + by) * OVERLAP
        and math.abs(z - p.z) < (az + bz) * OVERLAP then
        return true
      end
    end
  end
  return false
end

-- Where a free-floating ghost sits: cursor ray onto the pad plane, else held
-- at the ship's depth.
local function free_pos()
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local _, gey = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
  local gh = gey + params.floor_y
  if dy < -1e-4 then
    local t = (gh - oy) / dy
    if t > 0.3 and t < 400 then return ox + dx * t, gh, oz + dz * t end
  end
  local ddx, ddy, ddz = centerX - ox, centerY - oy, centerZ - oz
  local t = math.max(3.0, ddx * dx + ddy * dy + ddz * dz)
  return ox + dx * t, math.max(gh, oy + dy * t), oz + dz * t
end

-- Keep an angle readable: wrap to (-π, π].
local function wrap_angle(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a <= -math.pi do a = a + 2 * math.pi end
  return a
end

-- Shared rotation keys: R yaw 15° (SHIFT 5°), T pitch and Y roll in 90°
-- quarter-turns (SHIFT 15°) — the same grammar for the ghost in hand and a
-- placed part under the cursor. Returns true if anything turned.
local function rot_input(obj)
  local turned = false
  if input.pressed("r") then
    local step = input.key("shift") and (math.pi / 36) or (math.pi / 12)
    obj.yaw = wrap_angle((obj.yaw or 0) + step)
    turned = true
  end
  if input.pressed("t") then
    local step = input.key("shift") and (math.pi / 12) or (math.pi / 2)
    obj.pitch = wrap_angle((obj.pitch or 0) + step)
    turned = true
  end
  if input.pressed("y") then
    local step = input.key("shift") and (math.pi / 12) or (math.pi / 2)
    obj.roll = wrap_angle((obj.roll or 0) + step)
    turned = true
  end
  return turned
end

-- ── ROUND TWO: outward snapping, SURFACE attach and MIRROR symmetry ─────────
-- SURFACE ATTACH: away from every attach node, a part in hand snaps onto the
-- surface of whatever placed part is under the cursor, standing out of it
-- along that face's normal (a stack part's +Y, a flank part's +X), and R spins
-- it about that normal. Struts and beams (`axial_out`) snapped onto a flank
-- node point straight out of it the same way.
-- MIRROR (M): a flank or surface placement makes a mirrored PAIR across the
-- host's own X or Z plane — whichever faces the way you are attaching — which
-- is how a rover gets its left and right wheels in one click. A mirror pair is
-- a symmetry group like a ring (picked up, scrapped and moved as one); its
-- members carry `mir` = "x" | "z", the host axis they mirror across.
sym_mirror = false
function toggleMirror()
  sym_mirror = not sym_mirror
  if sym_mirror then sym_n = 1 end
  hint(sym_mirror and "mirror — a flank or surface placement makes a left/right pair (M again: off)"
    or "mirror off", 2.5)
  refresh_stats()
end

-- A basis (columns X, Y, Z) as the engine's YXZ Euler angles.
function eulerOf(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
  if math.abs(Z.y) > 0.9999 then
    -- Z straight up or down: yaw and roll turn about the same axis, so put
    -- the whole turn in yaw (roll 0 keeps X level: X = (cos yaw, 0, −sin yaw)).
    return math.atan2(-X.z, X.x), pitch, 0
  end
  return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
end

local function unit(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

local function cross3(a, b)
  return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

-- v turned about unit axis k by angle a (Rodrigues).
local function turn_about(v, k, a)
  local c, s = math.cos(a), math.sin(a)
  local d = v.x * k.x + v.y * k.y + v.z * k.z
  local kx = cross3(k, v)
  return { x = v.x * c + kx.x * s + k.x * d * (1 - c), y = v.y * c + kx.y * s + k.y * d * (1 - c),
           z = v.z * c + kx.z * s + k.z * d * (1 - c) }
end

-- The orientation that stands `def` out of a face with outward unit normal n:
-- a flank part's +X along n (upright: its +Y as near world up as it can be),
-- anything else +Y along n. `spin` turns it about n.
function attachOrient(def, nx, ny, nz, spin)
  local n = { x = nx, y = ny, z = nz }
  local X, Y
  if def.radial_orient then
    X = n
    local r = (math.abs(ny) > 0.95) and { x = -1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
    local d = r.x * nx + r.y * ny + r.z * nz
    local yx, yy, yz = unit(r.x - nx * d, r.y - ny * d, r.z - nz * d)
    Y = { x = yx, y = yy, z = yz }
  else
    Y = n
    local r = (math.abs(nx) < 0.9) and { x = 1, y = 0, z = 0 } or { x = 0, y = 0, z = 1 }
    local d = r.x * nx + r.y * ny + r.z * nz
    local xx, xy, xz = unit(r.x - nx * d, r.y - ny * d, r.z - nz * d)
    X = { x = xx, y = xy, z = xz }
  end
  if spin and spin ~= 0 then
    X, Y = turn_about(X, n, spin), turn_about(Y, n, spin)
  end
  return eulerOf(X, Y, cross3(X, Y))
end

-- How far a part's centre stands off the face it is attached to.
local function attach_reach(def)
  if def.radial_orient then return def.rx end
  return def.h * 0.5
end

-- The placed part under the cursor and the face it shows there, skipping the
-- part in hand (and anything carried with it). nil when the cursor is over
-- nothing of the craft.
function surfaceUnderCursor(exclude)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local skip = ghost and (ghost.node or (ghost.carried and parts[ghost.from_uid] and parts[ghost.from_uid].node)) or nil
  local travelled = 0
  for _ = 1, 6 do
    local hit = raycast(ox, oy, oz, dx, dy, dz, 300.0 - travelled, skip)
    if not (hit and hit.node and hit.nx) then return nil end
    local found = nil
    for uid, p in pairs(parts) do
      if p.node and p.node.id == hit.node.id then found = uid break end
    end
    if found and not (exclude and exclude[found]) then
      return { uid = found, side = "surface", x = hit.x, y = hit.y, z = hit.z,
               dx = hit.nx, dy = hit.ny, dz = hit.nz }
    end
    -- a carried part (or something that isn't the craft): look past it
    local step = (hit.distance or 0) + 0.02
    ox, oy, oz = ox + dx * step, oy + dy * step, oz + dz * step
    travelled = travelled + step
    if travelled > 299 then return nil end
  end
  return nil
end

-- Where the ghost goes for a snap, and how it is turned. Returns x, y, z and
-- sets ghost.yaw/pitch/roll. R spins a surface or outward placement about its
-- normal (the yaw R wrote last frame is read back as a spin).
function snapPlace(snap)
  local g = ghost
  local def = g.def
  if g.yset and g.yaw ~= g.yset then
    g.spin = (g.spin or 0) + (g.yaw - g.yset)
  end
  g.yset = nil
  if snap.side == "radial" and def.radial then
    -- A RADIAL DECOUPLER self-orients on a flank: its disc axis turns to
    -- face outward. Yaw is zeroed: the disc is rotationally symmetric.
    g.yaw = 0
    g.roll = math.asin(math.max(-1, math.min(1, -snap.dx)))
    g.pitch = math.atan2(snap.dz, snap.dy)
  elseif snap.side == "radial" and def.radial_orient then
    -- A fin: yaw its blade to face outward (horizontal), upright, re-seat.
    g.yaw = math.atan2(-snap.dz, snap.dx)
    g.pitch, g.roll = 0, 0
  elseif snap.side == "surface" or (snap.side == "radial" and def.axial_out) then
    g.yaw, g.pitch, g.roll = attachOrient(def, snap.dx, snap.dy, snap.dz, g.spin or 0)
    g.yset = g.yaw
    local r = attach_reach(def)
    return snap.x + snap.dx * r, snap.y + snap.dy * r, snap.z + snap.dz * r
  else
    return snap.cx, snap.cy, snap.cz
  end
  local gex, gey, gez = eff_extents(def, g.yaw, g.pitch, g.roll)
  local r = math.abs(snap.dx) * gex + math.abs(snap.dy) * gey + math.abs(snap.dz) * gez
  return snap.x + snap.dx * r, snap.y + snap.dy * r, snap.z + snap.dz * r
end

-- The mirror plane for a placement on `host` facing (dx,dy,dz): the host's
-- own X or Z axis, whichever that face looks along. Returns the axis vector
-- and its name, or nil for a face along the host's Y (a top or bottom face
-- has no opposite flank to mirror to).
local function mirror_axis(host, dx, dy, dz)
  local X, Y, Z = rot_basis(host.yaw, host.pitch, host.roll)
  local ax = math.abs(dx * X.x + dy * X.y + dz * X.z)
  local az = math.abs(dx * Z.x + dy * Z.y + dz * Z.z)
  local ay = math.abs(dx * Y.x + dy * Y.y + dz * Y.z)
  if ay > ax and ay > az then return nil end
  if ax >= az then return X, "x" end
  return Z, "z"
end

local function axis_of(host, mir)
  local X, _, Z = rot_basis(host.yaw, host.pitch, host.roll)
  return mir == "x" and X or Z
end

-- Reflect a point across the plane through `host` with normal A, and a vector.
local function reflect_pt(host, A, x, y, z)
  local d = (x - host.x) * A.x + (y - host.y) * A.y + (z - host.z) * A.z
  return x - 2 * d * A.x, y - 2 * d * A.y, z - 2 * d * A.z
end
local function reflect_vec(A, v)
  local d = v.x * A.x + v.y * A.y + v.z * A.z
  return { x = v.x - 2 * d * A.x, y = v.y - 2 * d * A.y, z = v.z - 2 * d * A.z }
end

-- The mirror image of an orientation as a proper rotation: X and Y reflected,
-- Z re-derived (a reflection flips handedness; flipping the part's own Z
-- keeps a flank part's +X outward and its +Y up, and a stack part's axis).
function mirrorOrient(A, yaw, pitch, roll)
  local X, Y = rot_basis(yaw, pitch, roll)
  local X2, Y2 = reflect_vec(A, X), reflect_vec(A, Y)
  return eulerOf(X2, Y2, cross3(X2, Y2))
end

-- The extra copies a placement makes: a mirror pair (M) or a ×N ring (X), for
-- a flank or surface placement on a host that is not itself in a group.
-- Each slot: { x, y, z, yaw, pitch, roll [, mir] }. nil = just the one part.
function symSlots(host, snap, x, y, z)
  if not (host and snap) or host.sym then return nil end
  if snap.side ~= "radial" and snap.side ~= "surface" then return nil end
  local g = ghost
  if sym_mirror then
    local A, name = mirror_axis(host, snap.dx, snap.dy, snap.dz)
    if not A then return nil end
    local mx, my, mz = reflect_pt(host, A, x, y, z)
    if (mx - x) ^ 2 + (my - y) ^ 2 + (mz - z) ^ 2 < 0.01 then return nil end
    local yaw2, pitch2, roll2 = mirrorOrient(A, g.yaw, g.pitch, g.roll)
    return { { x = mx, y = my, z = mz, yaw = yaw2, pitch = pitch2, roll = roll2, mir = name } }, name
  end
  if sym_n <= 1 then return nil end
  local out = {}
  local _, ax = rot_basis(host.yaw, host.pitch, host.roll)
  for k = 1, sym_n - 1 do
    local a = k * (2 * math.pi / sym_n)
    local vx, vy, vz = rot_about(host, x - host.x, y - host.y, z - host.z, a)
    local s = { x = host.x + vx, y = host.y + vy, z = host.z + vz, yaw = wrap_angle(g.yaw + a), pitch = g.pitch, roll = g.roll }
    if g.def.radial and snap.side == "radial" then
      local ol = math.sqrt(vx * vx + vy * vy + vz * vz)
      if ol > 1e-4 then s.pitch, s.roll = outward_orient(vx / ol, vy / ol, vz / ol); s.yaw = 0 end
    elseif snap.side == "surface" or (g.def.axial_out and snap.side == "radial") then
      local n = turn_about({ x = snap.dx, y = snap.dy, z = snap.dz }, ax, a)
      s.yaw, s.pitch, s.roll = attachOrient(g.def, n.x, n.y, n.z, g.spin or 0)
    elseif g.def.radial_orient then
      s.yaw, s.pitch, s.roll = math.atan2(-vz, vx), 0, 0
    end
    out[#out + 1] = s
  end
  return out, nil
end

-- A mirror group's partner pose for a member pose (position + orientation).
function mirrorPose(host, mir, x, y, z, yaw, pitch, roll)
  local A = axis_of(host, mir)
  local mx, my, mz = reflect_pt(host, A, x, y, z)
  local a, b, c = mirrorOrient(A, yaw, pitch, roll)
  return mx, my, mz, a, b, c
end
function mirrorVec(host, mir, dx, dy, dz)
  local v = reflect_vec(axis_of(host, mir), { x = dx, y = dy, z = dz })
  return v.x, v.y, v.z
end

-- The part a precise-edit undo op is already open for (one op per streak,
-- shared by the arrow keys AND the drag gizmo).
local nudge_uid = nil

-- Apply a precise edit to `uid`: displacement + rotation deltas, with the
-- ring rules (a symmetry member edits every member, displacement rotated to
-- each angle) and ONE undo op per editing streak. The keybinds and the drag
-- gizmo both land here.
local function apply_edit(uid, ddx, ddy, ddz, dyaw, dpitch, droll)
  local p = parts[uid]
  if not p then return end
  if nudge_uid ~= uid then
    nudge_uid = uid
    local moved = {}
    for u in pairs(edit_set(uid)) do
      local q = parts[u]
      moved[#moved + 1] = { uid = u, x = q.x, y = q.y, z = q.z,
                            yaw = q.yaw, pitch = q.pitch, roll = q.roll, parent = q.parent }
    end
    push_undo({ type = "move", moved = moved })
  end
  local turned = dyaw ~= 0 or dpitch ~= 0 or droll ~= 0
  local hub = p.sym and group_hub(p.sym) or nil
  if hub and p.mir then
    -- A MIRROR pair: edit this one, and its partner becomes its reflection
    -- (its stack moving by the reflected displacement).
    if turned then
      set_part_rot(p, wrap_angle((p.yaw or 0) + dyaw), wrap_angle((p.pitch or 0) + dpitch),
                   wrap_angle((p.roll or 0) + droll))
    end
    for u in pairs(subtree(uid)) do
      local q = parts[u]
      if q then set_part_pos(q, q.x + ddx, q.y + ddy, q.z + ddz) end
    end
    local rdx, rdy, rdz = mirrorVec(hub, p.mir, ddx, ddy, ddz)
    for _, m in ipairs(group_members(p.sym)) do
      local q = parts[m]
      if q and m ~= uid then
        for u in pairs(subtree(m)) do
          local sub = parts[u]
          if sub and u ~= m then set_part_pos(sub, sub.x + rdx, sub.y + rdy, sub.z + rdz) end
        end
        local x2, y2, z2, a, b, c = mirrorPose(hub, p.mir, p.x, p.y, p.z, p.yaw, p.pitch, p.roll)
        set_part_pos(q, x2, y2, z2)
        set_part_rot(q, a, b, c)
      end
    end
  elseif hub then
    local a0 = angle_about(hub, p)
    for _, m in ipairs(group_members(p.sym)) do
      local q = parts[m]
      if q then
        local da = angle_about(hub, q) - a0
        local rdx, rdy, rdz = rot_about(hub, ddx, ddy, ddz, da)
        for u in pairs(subtree(m)) do
          local sub = parts[u]
          if sub then set_part_pos(sub, sub.x + rdx, sub.y + rdy, sub.z + rdz) end
        end
        if turned then
          set_part_rot(q, wrap_angle((q.yaw or 0) + dyaw),
                       wrap_angle((q.pitch or 0) + dpitch),
                       wrap_angle((q.roll or 0) + droll))
        end
      end
    end
  else
    if turned then
      set_part_rot(p, wrap_angle((p.yaw or 0) + dyaw),
                   wrap_angle((p.pitch or 0) + dpitch),
                   wrap_angle((p.roll or 0) + droll))
    end
    if ddx ~= 0 or ddy ~= 0 or ddz ~= 0 then
      for u in pairs(subtree(uid)) do
        local q = parts[u]
        if q then set_part_pos(q, q.x + ddx, q.y + ddy, q.z + ddz) end
      end
    end
  end
  publish_center()
  refresh_stats()
end

-- ── Transform gizmos (editor-style, tool-specific) ──────────────────────────
-- ONE gizmo at a time, on the SELECTED part, for the ACTIVE tool: the MOVE
-- tool shows three solid arrows (world X/Y/Z, filled cone heads); the ROTATE
-- tool shows three solid rings (filled bands about those axes). Grab a handle
-- and drag: an arrow moves along its axis, a ring turns about it (SHIFT = fine
-- / 15° snap). Standard R/G/B axis colors so it reads at a glance.
local GIZ_AXES = {
  { x = 1, y = 0, z = 0, r = 0.95, g = 0.30, b = 0.28 }, -- X (red)  → pitch
  { x = 0, y = 1, z = 0, r = 0.40, g = 0.90, b = 0.42 }, -- Y (green)→ yaw
  { x = 0, y = 0, z = 1, r = 0.35, g = 0.55, b = 1.0 },  -- Z (blue) → roll
}
local gizmo_drag = nil -- { uid, kind = "move"|"turn", axis, lmx, lmy, acc }

-- The gizmo's size scales with the selected part so it never swamps a small
-- part or hides inside a big one. Returns the arrow length + ring radius.
local function gizmo_dims(p)
  local ex, ey, ez = part_extents(p)
  local reach = math.max(ex, ey, ez)
  return 1.15 + reach * 0.5, 0.85 + reach * 0.55
end

-- Two unit vectors spanning the plane ⊥ to axis `a` (for the rotate ring).
local function ring_basis(a)
  local ux, uy, uz = a.z, a.x, a.y
  return ux, uy, uz, a.y, a.z, a.x
end

local function draw_gizmo(p, tool)
  local len, rad = gizmo_dims(p)
  if tool == "rotate" then
    for _, a in ipairs(GIZ_AXES) do
      -- A solid band (filled annulus) reads as a real ring, not a thin line.
      draw.disc(p.x, p.y, p.z, a.x, a.y, a.z, rad * 0.9, rad, a.r, a.g, a.b, 0.7)
    end
    -- a small hub so the pivot is obvious
    draw.sphere(p.x, p.y, p.z, 0.09, 0.9, 0.9, 0.95, 1.0)
  else -- move
    for _, a in ipairs(GIZ_AXES) do
      local hx, hy, hz = p.x + a.x * len, p.y + a.y * len, p.z + a.z * len
      -- shaft
      draw.line(p.x, p.y, p.z, hx, hy, hz, a.r, a.g, a.b, 1.0)
      -- solid cone arrowhead (base a bit back from the tip)
      local bl = 0.26
      draw.cone(hx - a.x * bl, hy - a.y * bl, hz - a.z * bl,
        a.x, a.y, a.z, 0.11, bl, a.r, a.g, a.b, 1.0)
    end
    draw.box(p.x, p.y, p.z, 0.09, 0.09, 0.09, 0, 0.95, 0.95, 1.0, 1.0)
  end
  return len, rad
end

-- Which handle is under the cursor for `tool`? → kind, axis index (nil none).
-- Generously sampled: a big rotate ring at a shallow angle projects to a long
-- screen arc, so we walk it densely and use a fat pixel radius — aiming at a
-- ring should GRAB it, never fall through to a deselect.
local GIZ_HIT_PX = 22
local function gizmo_hit(p, tool, len, rad)
  local mx, my = input.mouse()
  local best, best_kind, best_d = nil, nil, GIZ_HIT_PX * GIZ_HIT_PX
  if tool == "rotate" then
    for ai, a in ipairs(GIZ_AXES) do
      local ux, uy, uz, vx2, vy2, vz2 = ring_basis(a)
      for k = 0, 47 do
        local t = k * (2 * math.pi / 48)
        local cx = p.x + (ux * math.cos(t) + vx2 * math.sin(t)) * rad
        local cy2 = p.y + (uy * math.cos(t) + vy2 * math.sin(t)) * rad
        local cz = p.z + (uz * math.cos(t) + vz2 * math.sin(t)) * rad
        local sx, sy, on = screen_of(cx, cy2, cz)
        if on then
          local d = (sx - mx) ^ 2 + (sy - my) ^ 2
          if d < best_d then best, best_kind, best_d = ai, "turn", d end
        end
      end
    end
  else
    for ai, a in ipairs(GIZ_AXES) do
      -- Test many points along the shaft so grabbing anywhere on the arrow
      -- (not just the tip) works — much more forgiving.
      for s = 2, 11 do
        local f = len * s / 11
        local sx, sy, on = screen_of(p.x + a.x * f, p.y + a.y * f, p.z + a.z * f)
        if on then
          local d = (sx - mx) ^ 2 + (sy - my) ^ 2
          if d < best_d then best, best_kind, best_d = ai, "move", d end
        end
      end
    end
  end
  if best then return best_kind, best end
  return nil
end

-- The screen-space bounding radius of the selection's gizmo (center + max
-- reach to any handle tip, in pixels). A click INSIDE this footprint that
-- misses a handle must NOT deselect — the player was aiming at the gizmo.
local function gizmo_footprint_px(p, tool, len, rad)
  local cx, cy, on = screen_of(p.x, p.y, p.z)
  if not on then return nil end
  local reach = (tool == "rotate") and rad or len
  local maxr = 26 -- always swallow a near-center miss
  for _, a in ipairs(GIZ_AXES) do
    for _, s in ipairs({ 1, -1 }) do
      local sx, sy, o2 = screen_of(p.x + a.x * reach * s, p.y + a.y * reach * s,
        p.z + a.z * reach * s)
      if o2 then
        local d = math.sqrt((sx - cx) ^ 2 + (sy - cy) ^ 2)
        if d > maxr then maxr = d end
      end
    end
  end
  return cx, cy, maxr
end

-- The catalogue's buttons ask for these: what a part is called and costs, and
-- whether R&D has opened it yet.
function partInfo(id)
  return REG[id]
end

-- The research click that is waiting for its confirmation: { id, t } or nil.
-- The catalogue reads it to paint that card's price as "confirm".
RESEARCH_CONFIRM = 5.0
researchArmed = nil
function researchPending(id)
  local a = researchArmed
  return a ~= nil and a.id == id and time - a.t <= RESEARCH_CONFIRM
end

-- Let a catalogue button push a line into the builder's hint bar (it has no
-- text node of its own, and the hint bar is where every other explanation in
-- this scene appears).
function hintNow(msg, secs)
  hint(msg, secs or 3.0)
end

-- ── The catalogue calls this (findScript("builder").pick) ───────────────────
function pick(id)
  if ghost or not REG[id] then return end
  -- A LOCKED part's click IS its research purchase — or the sentence saying
  -- what it wants first. The catalogue never holds a card you can't act on,
  -- and you never have to go somewhere else to open one.
  --
  -- And it is TWO clicks. One click used to spend $480–$1,250 of a $3,000
  -- account on the spot — a card you meant to hover was a purchase. The first
  -- click names the price and arms the card (the catalogue shows "confirm");
  -- the second, on the same card within RESEARCH_CONFIRM seconds, buys it.
  local rs = findScript("research")
  if rs and not rs.isUnlocked(id) then
    local why_not = rs.blockedBy and rs.blockedBy(id)
    if why_not then
      researchArmed = nil
      hint("LOCKED  ·  " .. rs.labelOf(id) .. "  —  " .. why_not, 4.0)
      ui("tool", 0.7)
      return
    end
    if not (researchArmed and researchArmed.id == id
            and time - researchArmed.t <= RESEARCH_CONFIRM) then
      researchArmed = { id = id, t = time }
      local co = company_ref()
      local price = rs.costOf(id)
      hint(string.format("RESEARCH %s for %s?  —  click it again to confirm",
        rs.labelOf(id), co and co.money(price) or ("$" .. price)), RESEARCH_CONFIRM)
      ui("tool", 0.7)
      return
    end
    researchArmed = nil
    local ok, why = rs.unlock(id)
    if not ok then
      hint("LOCKED  ·  " .. rs.labelOf(id) .. "  —  " .. why, 4.0)
      ui("tool", 0.7)
      return
    end
    hint("RESEARCH COMPLETE  ·  " .. why .. "  —  placing it now", 4.0)
    ui("save", 0.9)
  end
  local def = REG[id]
  ghost = { id = id, def = def, yaw = 0, pitch = 0, roll = 0, node = nil }
  click_cool = 0.15
  hint(HINT_GHOST, 6.0)
  spawn(def.prefab, vec3(0, -80, 0), function(node)
    if ghost and ghost.id == id and not ghost.node and not ghost.carried then
      ghost.node = node
    else
      destroy(node)
    end
  end)
end

local function pickup(uid)
  local grab = edit_set(uid) -- a ring member brings its whole ring
  local moved = {}
  for u in pairs(grab) do
    local p = parts[u]
    moved[#moved + 1] = { uid = u, id = p.id, x = p.x, y = p.y, z = p.z,
                          yaw = p.yaw, pitch = p.pitch, roll = p.roll, parent = p.parent }
  end
  local root = parts[uid]
  ghost = { id = root.id, def = root.def, yaw = root.yaw, pitch = root.pitch or 0,
            roll = root.roll or 0, node = root.node, carried = moved, from_uid = uid }
  root.parent = nil
  push_undo({ type = "move", moved = moved })
  click_cool = 0.18
  ui("pickup", 0.8) -- lifted off the stack
  hint(HINT_GHOST, 6.0)
end

local function place_ghost(x, y, z, parent, att, sym)
  local placed_uid = nil
  if ghost.carried then
    local root = parts[ghost.from_uid]
    if root then
      local dx, dy, dz = x - root.x, y - root.y, z - root.z
      for _, m in ipairs(ghost.carried) do
        local p = parts[m.uid]
        if p then set_part_pos(p, p.x + dx, p.y + dy, p.z + dz) end
      end
      root.parent = parent
      root.att = att
      placed_uid = ghost.from_uid
    end
  else
    -- The ghost node BECOMES the placed part. (Spawning a second node here
    -- was the great twin bug: every placed part got an invisible orphan
    -- double exactly on top of it — phantom "copies", un-selectable spots,
    -- parts "clipping inside each other".)
    local u = next_uid
    next_uid = next_uid + 1
    ghost.node.x, ghost.node.y, ghost.node.z = x, y, z
    ghost.node.yaw, ghost.node.pitch, ghost.node.roll = ghost.yaw, ghost.pitch, ghost.roll
    parts[u] = { id = ghost.id, def = ghost.def, node = ghost.node,
                 x = x, y = y, z = z, yaw = ghost.yaw, pitch = ghost.pitch,
                 roll = ghost.roll, parent = parent, att = att, sym = sym }
    push_undo({ type = "place", uid = u })
    placed_uid = u
  end
  ghost = nil
  click_cool = 0.15
  ui("place", 0.9) -- the part snaps home
  hint(HINT_IDLE, 0.0); hint_t = 0
  publish_center(); refresh_stats()
  return placed_uid
end

-- ── Symmetry placement ──────────────────────────────────────────────────────
-- (A fresh ×N ring or mirror pair is laid out by `symSlots`, above.)

-- Mirror a just-placed part from ring member `host` onto every OTHER member
-- of its ring — the stacked-children rule that makes ×N boosters build in
-- N clicks total, not N × parts. The copies form their own (chained) ring.
local function mirror_onto_ring(host_uid, placed_uid)
  local host = parts[host_uid]
  local src = parts[placed_uid]
  if not (host and host.sym and src) then return end
  local hub = group_hub(host.sym)
  if not hub then return end
  local a0 = angle_about(hub, host)
  next_sym = next_sym + 1
  local gid = next_sym
  src.sym = gid
  local uids = { placed_uid }
  if host.mir then
    -- A MIRROR pair: the copy is the reflection, across the same plane.
    src.mir = host.mir
    for _, m in ipairs(group_members(host.sym)) do
      if m ~= host_uid then
        local px, py, pz, yaw2, pitch2, roll2 = mirrorPose(hub, host.mir, src.x, src.y, src.z,
          src.yaw, src.pitch, src.roll)
        uids[#uids + 1] = spawn_part(src.id, px, py, pz, yaw2, m, nil, pitch2, roll2, src.att, gid, host.mir)
      end
    end
    if #undo_stack > 0 and undo_stack[#undo_stack].type == "place"
      and undo_stack[#undo_stack].uid == placed_uid then
      table.remove(undo_stack)
    end
    push_undo({ type = "place_group", uids = uids })
    hint("mirrored to the other side", 2.0)
    return
  end
  for _, m in ipairs(group_members(host.sym)) do
    if m ~= host_uid then
      local da = angle_about(hub, parts[m]) - a0
      local vx, vy, vz = rot_about(hub, src.x - hub.x, src.y - hub.y, src.z - hub.z, da)
      local px, py, pz = hub.x + vx, hub.y + vy, hub.z + vz
      local yaw2, pitch2, roll2 = wrap_angle(src.yaw + da), src.pitch, src.roll
      if src.def.radial and src.att == "radial" then
        local ox, oy, oz = px - parts[m].x, py - parts[m].y, pz - parts[m].z
        local ol = math.sqrt(ox * ox + oy * oy + oz * oz)
        if ol > 1e-4 then
          pitch2, roll2 = outward_orient(ox / ol, oy / ol, oz / ol)
          yaw2 = 0
        end
      elseif src.def.radial_orient and src.att == "radial" then
        -- A fin mirrored onto another flank: re-face its blade outward there.
        yaw2, pitch2, roll2 = math.atan2(-(pz - parts[m].z), px - parts[m].x), 0, 0
      end
      uids[#uids + 1] = spawn_part(src.id, px, py, pz, yaw2, m, nil,
                                   pitch2, roll2, src.att, gid)
    end
  end
  -- One undo op covers the whole mirrored set (replace the single-place op).
  if #undo_stack > 0 and undo_stack[#undo_stack].type == "place"
    and undo_stack[#undo_stack].uid == placed_uid then
    table.remove(undo_stack)
  end
  push_undo({ type = "place_group", uids = uids })
  hint(string.format("mirrored ×%d across the ring", #uids), 2.0)
end

local function cancel_ghost()
  if not ghost then return end
  if ghost.carried then
    ghost = nil
    undo() -- restores the pre-pickup poses + links (the op pushed at pickup)
  else
    if ghost.node then destroy(ghost.node) end
    ghost = nil
  end
  hint(HINT_IDLE, 0.0); hint_t = 0
end

-- ── ROUND TWO at save: fairing shells, rover axles, rated motors ──────────
-- FAIRING ENVELOPE: what stands on a fairing base's top node (and everything
-- built onto that), measured in the base's frame — how tall the payload
-- reaches above the base and how far out from its axis — so the shell is
-- built to fit it. nil when nothing stands on it.
SHELL_T_PER_M2 = 0.012   -- composite shell, tonnes per square metre
function fairingEnvelope(uid)
  local b = parts[uid]
  if not (b and b.def.fairing) then return nil end
  local X, Y, Z = rot_basis(b.yaw, b.pitch, b.roll)
  local load = {}
  for u, q in pairs(parts) do
    if q.parent == uid and (q.att == "top" or q.att == "surface") then
      local up = (q.x - b.x) * Y.x + (q.y - b.y) * Y.y + (q.z - b.z) * Y.z
      if up > 0 then for v in pairs(subtree(u)) do load[v] = true end end
    end
  end
  local top, rad, n = 0.0, 0.0, 0
  for u in pairs(load) do
    local q = parts[u]
    if q then
      n = n + 1
      local ex, ey, ez = part_extents(q)
      local dx, dy, dz = q.x - b.x, q.y - b.y, q.z - b.z
      local h = dx * Y.x + dy * Y.y + dz * Y.z
      local reach = math.abs(Y.x) * ex + math.abs(Y.y) * ey + math.abs(Y.z) * ez
      top = math.max(top, h + reach)
      local rx = dx * X.x + dy * X.y + dz * X.z
      local rz = dx * Z.x + dy * Z.y + dz * Z.z
      local wx = math.abs(X.x) * ex + math.abs(X.y) * ey + math.abs(X.z) * ez
      local wz = math.abs(Z.x) * ex + math.abs(Z.y) * ey + math.abs(Z.z) * ez
      rad = math.max(rad, math.sqrt((math.abs(rx) + wx) ^ 2 + (math.abs(rz) + wz) ^ 2))
    end
  end
  if n == 0 then return nil end
  local base_top = b.def.h * 0.5
  local R = math.max(b.def.fairing, rad + 0.08)
  local hc = math.max(base_top + 0.3, top + 0.1)      -- the cylinder's top, above the base centre
  local hn = R * 1.1                                    -- the ogive nose
  local area = 2 * math.pi * R * (hc - base_top) + math.pi * R * math.sqrt(R * R + hn * hn)
  return { r = R, hc = hc, hn = hn, y0 = base_top, mass = area * SHELL_T_PER_M2, load = load, n = n }
end

-- The craft's wheels, by the way their axles point (vessel frame). A rover
-- needs them all on ONE axle line: the engine's wheel joint turns a wheel
-- about the chassis's Z (floptle/0420), so at rollout the build is turned
-- about the vertical to put that line on Z if it was built along X.
function wheelAxles()
  local nx, nz, other, n = 0, 0, 0, 0
  for _, p in pairs(parts) do
    if p.def.wheel then
      n = n + 1
      local X = rot_basis(p.yaw, p.pitch, p.roll)
      if math.abs(X.x) > 0.9 then nx = nx + 1
      elseif math.abs(X.z) > 0.9 then nz = nz + 1
      else other = other + 1 end
    end
  end
  return n, nx, nz, other
end

-- Called by save_blueprint on the finished records (vessel frame, y = 0 at
-- the bottom): shells, axles, and motors rated for the home world like
-- engines are (torque × g_home / G_REF, so a rover climbs the same slope on
-- every save).
function finishBlueprint(bp)
  local by = {}
  for _, d in ipairs(bp.parts) do by[d.uid] = d end
  -- fairings
  for _, d in ipairs(bp.parts) do
    if (d.fairing or 0) > 0 then
      local env = fairingEnvelope(d.uid)
      if env then
        d.fr, d.fhc, d.fhn, d.fy0 = env.r, env.hc, env.hn, env.y0
        d.mass = (d.mass or 0) + env.mass
        d.shellm = env.mass
        for u in pairs(env.load) do if by[u] then by[u].faired = d.uid end end
      end
    end
  end
  -- motors rated for the home world
  local k = rating().thrust
  for _, d in ipairs(bp.parts) do
    if type(d.mods) == "table" then
      for _, m in ipairs(d.mods) do
        if m.type == "drive" or m.type == "hinge" or m.type == "rotor" then m.torque = (m.torque or 0) * k
        elseif m.type == "piston" then m.force = (m.force or 0) * k end
      end
    end
  end
  -- axles on Z: a build whose wheels all point along X turns 90° about Y
  local n, nx, nz = wheelAxles()
  if n > 0 and nx > nz then
    for _, d in ipairs(bp.parts) do
      d.x, d.z = -d.z, d.x
      d.yaw = wrap_angle((d.yaw or 0) - math.pi / 2)
    end
    bp.turned = -math.pi / 2
  end
end

-- ── Blueprint (self-contained; save.* slot store) ───────────────────────────
local function save_blueprint()
  local bp = { parts = {} }
  local ref_y = math.huge
  for _, p in pairs(parts) do ref_y = math.min(ref_y, p.y - p.def.h * 0.5) end
  if ref_y == math.huge then ref_y = 0 end
  -- Firing order: each decoupler carries its stage-event index.
  local items = sync_stage_order()
  local stage_of = {}
  for i2, key in ipairs(stage_order) do
    local it = items[key]
    if it then
      for _, u in ipairs(it.uids) do stage_of[u] = i2 end
    end
  end
  local i = 0
  for uid, p in pairs(parts) do
    i = i + 1
    -- As this save builds it (thrust and ve for the home world, see BALANCE).
    local d = liveDef(p.def)
    bp.parts[i] = {
      uid = uid, id = p.id, prefab = d.prefab, label = d.label,
      x = p.x - centerX, y = p.y - ref_y, z = p.z - centerZ,
      yaw = p.yaw, pitch = p.pitch or 0, roll = p.roll or 0,
      parent = p.parent or 0, att = p.att or "", sym = p.sym or 0,
      stage = stage_of[uid] or 0,
      h = d.h, mass = d.mass, cost = d.cost, kind = d.kind,
      -- Half-widths ride along too: the flight side needs a part's real
      -- footprint for hull contact, not just its stack height.
      rx = d.rx or 0, rz = d.rz or 0,
      -- Structural ratings for the flight's stress model (see REG).
      strength = d.strength or 0, maxq = d.maxq or 0,
      -- burn = units/s at full throttle; fuel_t = tonnes per unit, so the
      -- flight gives the propellant its mass (absent = an older, massless build).
      thrust = d.thrust or 0, burn = d.burn or 0, fuel = d.fuel or 0,
      ve = d.ve or 0, fuel_t = d.fuel_t or 0,
      decouple = d.decouple and 1 or 0, legs = d.legs and 1 or 0,
      radial = d.radial and 1 or 0, chute = d.chute and 1 or 0,
      comms = d.comms and 1 or 0, aero = d.aero and 1 or 0,
      -- Electrical capabilities: these were being DROPPED on save, so a battery
      -- (power) or solar panel (solar) never did anything in flight. Carry them
      -- and their ratings (EC capacity / charge rate) through to the vessel.
      power = d.power and 1 or 0, solar = d.solar and 1 or 0,
      ec = d.ec or 0, gen = d.gen or 0,
      -- Docking ports and RCS blocks are peripherals, not staging events: the
      -- flight side reads these to find every mating face and thruster aboard.
      dock = d.dock and 1 or 0,
      rcs = d.rcs and 1 or 0, rcs_thrust = d.rcs_thrust or 0,
      -- Hold capacity in kg (0 = not a cargo bay). The vessel sums these into
      -- one pooled hold when it spawns.
      cargo = d.cargo or 0,
      -- ROUND TWO: a rover body's FRONT, a powered wheel's size, a fairing's
      -- base radius (and the shell it grew, see fairingShell), a robotic
      -- joint's kind, a claw, and a mirror pair's plane.
      front = d.front and 1 or 0, wheel = d.wheel or "", fairing = d.fairing or 0,
      robo = d.robo or "", claw = d.claw and 1 or 0, mir = p.mir or "",
      -- ELECTRONICS: every module the part carries (declared + implied by its
      -- flags), so the flight never has to know a part by name to power it,
      -- link it or offer its actions.
      -- (as a string: save.set holds four tables deep at most — electronics
      -- encodeMods / decodeMods)
      mods = (elib() and elib().encodeMods(part_mods(d))) or nil,
    }
  end
  -- ACTION GROUPS: only once the player has edited them. Until then the flight
  -- builds the standard ones (legs on Gear, panels and antennas on Deploy…) from
  -- whatever is aboard, so a craft that never opened the editor still has them.
  if groups_state.edited and groups_state.groups then
    local alive = {}
    for uid in pairs(parts) do alive[uid] = true end
    local E = elib()
    if E then
      E.pruneGroups(groups_state.groups, alive)
      bp.groups = E.packGroups(groups_state.groups)
    end
  end
  -- The catalogue this was built from (see BALANCE): for the record only. The
  -- pad no longer re-rates anything — the blueprint flies exactly as quoted.
  local k = rating()
  bp.catalogue = { home = k.name, thrust = k.thrust, ve = k.ve, v = k.v }
  finishBlueprint(bp)
  save.set("shipyard.blueprint", bp)
  save.flush()
  ui("save", 0.9)
  hint("blueprint saved  ·  " .. i .. " parts", 2.5)
end

-- The parachute canister was redrawn to sit on the pod's collar: 0.61 → 0.34 m
-- tall, 0.28 → 0.22 m half-wide (tools/gen_part_meshes.py part_chute). A build
-- saved before keeps the old centre, which would leave the new canister
-- floating above its mount: sit it back down — its foot where it was, anything
-- hung on its flanks moving with it, anything under it staying put.
local function refit_chutes(list)
  local cur = REG.chute
  local by, kids = {}, {}
  for _, d in pairs(list) do
    by[d.uid] = d
    local pu = d.parent or 0
    if pu ~= 0 then kids[pu] = kids[pu] or {}; kids[pu][#kids[pu] + 1] = d end
  end
  local function move(d, dx, dy, dz, root)
    d.x, d.y, d.z = d.x + dx, d.y + dy, d.z + dz
    for _, k in ipairs(kids[d.uid] or {}) do
      if not (root and k.att == "bottom") then move(k, dx, dy, dz, false) end
    end
  end
  for _, d in pairs(list) do
    if d.id == "chute" and d.h and math.abs(d.h - cur.h) > 1e-3 then
      local par = by[d.parent or 0]
      if d.att == "radial" and par then
        -- in toward the flank it hangs on
        local ox, oz = d.x - par.x, d.z - par.z
        local l = math.sqrt(ox * ox + oz * oz)
        local pull = (d.rx or 0.28) - cur.rx
        if l > 1e-3 then move(d, -ox / l * pull, 0, -oz / l * pull, true) end
      else
        local _, Y = rot_basis(d.yaw, d.pitch, d.roll)
        local dh = (d.h - cur.h) * 0.5
        move(d, -Y.x * dh, -Y.y * dh, -Y.z * dh, true)
      end
      d.h, d.rx, d.rz = cur.h, cur.rx, cur.rz
    end
  end
end

local function load_blueprint()
  local bp = save.get("shipyard.blueprint")
  if not bp or not bp.parts then return end
  refit_chutes(bp.parts)
  -- A rover rolled out turned 90° (finishBlueprint: wheel axles on Z) comes
  -- back onto the stand the way it was built.
  if bp.turned then
    for _, d in pairs(bp.parts) do
      d.x, d.z = d.z, -d.x
      d.yaw = wrap_angle((d.yaw or 0) + math.pi / 2)
    end
    bp.turned = nil
  end
  local E = elib()
  if bp.groups and E then
    groups_state.groups, groups_state.edited = E.unpackGroups(bp.groups), true
  else
    groups_state.groups, groups_state.edited = nil, false
  end
  for uid in pairs(parts) do remove_part(uid) end
  undo_stack = {}
  stage_order, saved_stage = {}, {}
  for _, d in pairs(bp.parts) do
    if (d.stage or 0) > 0 then saved_stage[d.uid] = d.stage end
    spawn_part(d.id, d.x, d.y + params.floor_y, d.z, d.yaw,
               d.parent ~= 0 and d.parent or nil, d.uid, d.pitch, d.roll,
               d.att ~= "" and d.att or nil,
               (d.sym or 0) ~= 0 and d.sym or nil,
               (d.mir or "") ~= "" and d.mir or nil)
    if (d.sym or 0) > next_sym then next_sym = d.sym end
    if d.uid >= next_uid then next_uid = d.uid + 1 end
  end
end

-- ── ACTION GROUPS (tool 5) ──────────────────────────────────────────────────
-- Pick a group on the panel (Gear, Deploy, Lights, Brakes, RCS, SAS, Abort or
-- one of 1–0), click a part on the craft, and tick the actions it should run
-- when that group's key is pressed. A symmetry ring is edited as one, like
-- everything else in here. The panel itself is scripts/groups_panel.lua; it
-- reads and edits through these globals, so the rules live in one place.

-- The groups as they stand: the edited set, or the standard one built from
-- what's aboard. Bindings to scrapped parts are dropped.
function groupsNow()
  local E = elib()
  if not E then return {} end
  local recs = craft_records()
  if not groups_state.edited or not groups_state.groups then
    return E.defaultGroups(recs), recs
  end
  -- Shown without bindings to parts that aren't on the stand — but not
  -- forgotten: CTRL+Z brings a scrapped part back with its uid, and its
  -- bindings come back with it. (The save drops them for good.)
  local alive = {}
  for uid in pairs(parts) do alive[uid] = true end
  return E.pruneGroups(E.deepCopy(groups_state.groups), alive), recs
end

function groupsTool() return tool == "groups" end
-- Switch tools from outside (a probe; a future toolbar). Same names as TOOLS.
function setTool(name)
  for _, t in ipairs(TOOLS) do
    if t == name then tool = name; refresh_stats() return true end
  end
  return false
end
-- The uids on the stand, sorted (probes and the harness).
function partUids()
  local out = {}
  for uid in pairs(parts) do out[#out + 1] = uid end
  table.sort(out)
  return out
end
function partIdOf(uid) return parts[uid] and parts[uid].id or nil end
function groupsSelected() return groups_state.gid end
function groupsSelect(gid) groups_state.gid = gid end
function groupsEdited() return groups_state.edited end
function selectedPart() return selected_uid end
function selectPart(uid) if parts[uid] then selected_uid = uid end end

-- First edit: the standard set becomes the player's own, then changes.
local function groups_own()
  local E = elib()
  if not E then return nil end
  if not groups_state.edited or not groups_state.groups then
    groups_state.groups = E.defaultGroups(craft_records())
    groups_state.edited = true
  end
  return groups_state.groups
end

-- Tick / untick one action of one part in a group — and of every member of
-- the part's symmetry ring. Returns the new bound state.
function groupsToggle(gid, uid, act)
  local E = elib()
  local g = groups_own()
  if not (E and g and parts[uid]) then return false end
  local on = not E.isBound(g, gid, uid, act)
  local members = { uid }
  local p = parts[uid]
  if p.sym then members = group_members(p.sym) end
  for _, u in ipairs(members) do
    if on then E.bind(g, gid, u, act) else E.unbind(g, gid, u, act) end
  end
  ui("tool", 0.6)
  return on
end

-- Empty one group, or put every group back to the standard set.
function groupsClear(gid)
  local g = groups_own()
  if g and g[gid] then g[gid].binds = {} end
  ui("scrap", 0.6)
end

function groupsReset()
  groups_state.groups, groups_state.edited = nil, false
  ui("tool", 0.6)
  hint("action groups back to the standard set", 2.5)
end

-- Rename a custom group (the label the flight HUD shows on its key).
function groupsRename(gid, name)
  local g = groups_own()
  if not g then return end
  local E = elib()
  if not g[gid] then g[gid] = { name = name, binds = {} } end
  g[gid].name = (name and name ~= "") and name or ((E and E.groupInfo(gid) or {}).label or gid)
end

-- The builder's half of the panel: outline every part the open group touches
-- (the selection in the ring colour), and own the mouse while it is over the
-- panel so a click on a checkbox never deselects the part it's editing.
local groups_panel_node = nil
function groupsPanelTick(clicked)
  if tool ~= "groups" then return false end
  local E = elib()
  if E then
    local g = groupsNow()
    local gg = g and g[groups_state.gid]
    if gg then
      local seen = {}
      for _, b in ipairs(gg.binds) do
        local p = parts[b.uid]
        if p and not seen[b.uid] then
          seen[b.uid] = true
          outline(p, 1.0, 0.72, 0.32, 0.85)
        end
      end
    end
  end
  if not groups_panel_node or not groups_panel_node.valid then groups_panel_node = find("GroupsPanel") end
  if not (groups_panel_node and groups_panel_node.uiRect) then return false end
  local px, py, pw, ph = groups_panel_node:uiRect()
  if not (px and pw and pw > 1) then return false end
  local mx, my = input.mouse()
  return mx >= px and mx <= px + pw and my >= py and my <= py + ph
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────
function start(node)
  stats_node = find("BuildStats")
  hint_node = find("BuildHint")
  load_blueprint()
  refresh_stats()
end

local grab_mode = false
local grab_last = nil
local grab_moved = false

-- Engineering markers (in-game draw.* layer): the CENTER OF MASS (amber
-- sphere + ring) and CENTER OF THRUST (blue sphere + thrust-axis line).
-- Watching them line up IS the balance tool — an off-axis CoT will pirouette
-- exactly this way at launch, because flight thrusts at these same offsets.
local function draw_engineering()
  if partCount == 0 then return end
  local m, cx, cy, cz = 0.0, 0.0, 0.0, 0.0
  local th, tx, ty, tz = 0.0, 0.0, 0.0, 0.0
  for _, p in pairs(parts) do
    local pm = p.def.mass
    m = m + pm
    cx, cy, cz = cx + p.x * pm, cy + p.y * pm, cz + p.z * pm
    local t = p.def.thrust or 0
    if t > 0 then
      th = th + t
      tx, ty, tz = tx + p.x * t, ty + p.y * t, tz + p.z * t
    end
  end
  if m <= 0 then return end
  cx, cy, cz = cx / m, cy / m, cz / m
  draw.sphere(cx, cy, cz, 0.16, 1.0, 0.8, 0.2, 1.0)
  draw.ring(cx, cy, cz, 0, 1, 0, 0.34, 1.0, 0.8, 0.2, 0.7)
  if th > 0 then
    tx, ty, tz = tx / th, ty / th, tz / th
    draw.sphere(tx, ty, tz, 0.13, 0.3, 0.7, 1.0, 1.0)
    -- The thrust axis (builder ships point +Y): CoT up through the CoM
    -- region — if this line misses the amber ball, the ship will torque.
    draw.line(tx, ty, tz, tx, ty + 2.2, tz, 0.3, 0.7, 1.0, 0.8)
  end
end


-- ── ROUND TWO, every frame: rover FRONT arrow, fairing shells ───────────────
-- A rover drives toward its FRONT (a rover body's +X, else the build's +X):
-- an arrow on the pad says which way W goes. A fairing base with a payload on
-- it shows the shell it will grow, translucent, rebuilt when the payload
-- changes.
local shells = {}   -- fairing uid → { sig, nodes = {…}, meshes = {…} }
local function free_shell(uid)
  local sh = shells[uid]
  if not sh then return end
  for _, n in ipairs(sh.nodes or {}) do if n.valid then destroy(n) end end
  for _, m in ipairs(sh.meshes or {}) do if mesh and mesh.free then mesh.free(m) end end
  shells[uid] = nil
end

function roundTwoTick()
  -- the rover's front
  local front, wheels = nil, false
  for _, p in pairs(parts) do
    if p.def.wheel then wheels = true end
    if p.def.front then front = p end
  end
  if wheels and partCount > 0 then
    local fx, fz = 1, 0
    if front then
      local X = rot_basis(front.yaw, front.pitch, front.roll)
      local l = math.sqrt(X.x * X.x + X.z * X.z)
      if l > 0.3 then fx, fz = X.x / l, X.z / l end
    end
    local y = params.floor_y + 0.03
    local r = 1.6
    draw.line(centerX, y, centerZ, centerX + fx * r, y, centerZ + fz * r, 0.35, 0.95, 0.55, 1.0)
    draw.cone(centerX + fx * r, y, centerZ + fz * r, fx, 0, fz, 0.16, 0.36, 0.35, 0.95, 0.55, 1.0)
  end
  -- fairing shells
  local E = elib()
  if not (E and E.fairingShell and mesh and mesh.build) then return end
  for uid in pairs(shells) do
    if not parts[uid] then free_shell(uid) end
  end
  for uid, p in pairs(parts) do
    if p.def.fairing and p.node and p.node.valid then
      local env = fairingEnvelope(uid)
      local sig = env and string.format("%.3f/%.3f/%.3f", env.r, env.hc, env.hn) or "none"
      local sh = shells[uid]
      if not sh or sh.sig ~= sig or sh.node ~= p.node.id then
        free_shell(uid)
        sh = { sig = sig, nodes = {}, meshes = {}, node = p.node.id }
        shells[uid] = sh
        if env then
          for half = 0, 1 do
            local m = E.fairingShell(env.r, env.y0, env.hc, env.hn, half, 24)
            local name = mesh.build(m)
            sh.meshes[#sh.meshes + 1] = name
            createNode("Fairing Shell", p.node, function(n)
              n.model = name
              n:setMaterial{ texture = "textures/parts/paint_albedo.png", normalMap = "textures/parts/paint_normal.png",
                             roughnessMap = "textures/parts/paint_orm.png", shading = "physical",
                             roughness = 0.8, metallic = 0.2, alpha = 0.28 }
              if shells[uid] == sh then sh.nodes[#sh.nodes + 1] = n else destroy(n) end
            end)
          end
        end
      end
    end
  end
end

-- The STAGING panel (STAGE tool): draw the numbered decoupler badges, then
-- hit-test the panel against its REAL solved rect (node:uiRect — physical px,
-- the mouse's space) and drag rows to reorder the firing sequence. Returns true
-- when the panel owns the mouse this frame. Lives OUTSIDE `update` so that huge
-- function stays under LuaJIT's 60-upvalue-per-function ceiling.
-- Which stage row (1-based) the mouse-Y is over, hit-tested against each row
-- node's REAL solved rect (physical px, the mouse's own space) — exact
-- regardless of font metrics, viewport docking, or panel size.
local function stage_row_at(my)
  for k = 1, #stage_order do
    local rn = stage_row_node(k)
    if rn then
      -- NB: `a and f()` truncates a multi-return — call uiRect on its own line.
      local rx, ry, rw, rh = rn:uiRect()
      if rx and rw > 1 and my >= ry and my <= ry + rh then return k, ry end
    end
  end
  return nil
end

local function handle_staging(clicked, lmb, grab_mode)
  local in_panel = false
  draw_stage_badges()
  stage_hover = nil
  if tool == "stage" and #stage_order > 0 then
    if not stage_node2 then stage_node2 = find("StagePanel") end
    local prx, pry, prw, prh = 0, 0, 0, 0
    if stage_node2 then prx, pry, prw, prh = stage_node2:uiRect() end
    if prx and prw > 1 then
      local mx, my = input.mouse()
      in_panel = mx >= prx and mx <= prx + prw and my >= pry and my <= pry + prh
      local row = stage_row_at(my)
      if in_panel and row and not stage_drag then stage_hover = stage_order[row] end
      if stage_drag then
        -- Ghost tracks the cursor: design_y = (mouse_y - grab_dy) / scale, and
        -- the layer origin cancels because the ghost is drawn origin+pos*scale
        -- while the cursor sits at origin+mouse_y (see builder.ron ghost node).
        if not stage_ghost then stage_ghost = find("StageDragGhost") end
        if stage_ghost then
          local gel = stage_ghost:getcomponent("UiElement")
          if gel then
            local _, sh = camera.screenSize()
            local scale = (sh and sh > 1) and (sh / 720.0) or 1.0
            gel.posY = (my - stage_drag.grab_dy) / scale
          end
        end
        -- Reorder as the cursor crosses into another row's rect.
        if row and row ~= stage_drag.row then
          table.remove(stage_order, stage_drag.row)
          table.insert(stage_order, row, stage_drag.key)
          stage_drag.row = row
        end
        paint_stages()
        if not lmb then
          stage_drag = nil
          click_cool = 0.2
          paint_stages()
          hint("staging order set — #1 fires first in flight", 2.5)
        end
      elseif in_panel and clicked and not grab_mode and row then
        local _, ry = stage_row_at(my)
        stage_drag = { key = stage_order[row], row = row, grab_dy = my - (ry or my) }
        paint_stages()
      else
        paint_stages() -- refresh the hover highlight
      end
    end
  end
  return stage_drag or in_panel
end

function update(node, dt)
  draw_engineering()
  roundTwoTick()
  fit_header()
  -- One shared click edge for the whole frame.
  local lmb = input.button(0)
  local clicked = lmb and not lmb_prev and click_cool <= 0
  lmb_prev = lmb
  if click_cool > 0 then click_cool = click_cool - dt end
  if hint_t > 0 then
    hint_t = hint_t - dt
    if hint_t <= 0 and hint_node and not ghost and not grab_mode then
      hint_node.text = HINT_IDLE
    end
  end
  local cam_busy = input.button(1) -- RMB = the camera's; never build through it

  -- TOOL switch (1 Move · 2 Rotate · 3 Stage · 4 Grab) — never while placing
  -- a part or holding a gizmo. The active tool decides what the SELECTION's
  -- gizmo does; switching tools keeps the selection.
  if not ghost and not gizmo_drag then
    for i, tname in ipairs(TOOLS) do
      if input.pressed(tostring(i)) then
        tool = tname
        ui("tool", 0.7)
        hint("tool: " .. TOOL_LABEL[tool] .. (tool == "grab"
          and " — click a part to pick it up" or ""), 2.0)
        refresh_stats()
      end
    end
  end

  -- SYMMETRY mode: X cycles ×1 ×2 ×3 ×4 ×6 ×8 (SHIFT+X cycles back).
  -- Applies to radial placements; stacking on a ring always auto-mirrors.
  if input.pressed("x") then
    local idx = 1
    for i, n in ipairs(SYM_STEPS) do
      if n == sym_n then idx = i end
    end
    idx = input.key("shift") and ((idx - 2) % #SYM_STEPS + 1) or (idx % #SYM_STEPS + 1)
    sym_n = SYM_STEPS[idx]
    sym_mirror = false
    hint(sym_n > 1
      and ("symmetry ×" .. sym_n .. " — a radial placement rings the hull")
      or "symmetry off", 2.0)
    refresh_stats()
  end

  -- MIRROR mode (M): flank and surface placements come in mirrored pairs.
  if input.pressed("m") and not input.key("ctrl") then toggleMirror() end

  -- ── STAGING panel (STAGE tool): drag rows to reorder the firing sequence ──
  -- Extracted to handle_staging() (below) so this enormous `update` stays under
  -- LuaJIT's 60-upvalue-per-function ceiling. Returns true when the panel owns
  -- the mouse this frame — no picking, placing or scrapping through it.
  if handle_staging(clicked, lmb, grab_mode) then return end
  -- The ACTION GROUPS tool's panel: same rule (a global, for the same reason).
  if groupsPanelTick(clicked) then return end

  -- Self-heal: never let a bad ghost wedge the builder.
  if ghost then
    if ghost.carried and not parts[ghost.from_uid] then
      ghost = nil
      hint(HINT_IDLE, 0.0); hint_t = 0
    elseif not ghost.carried and not ghost.node then
      ghost.wait = (ghost.wait or 0) + dt
      if ghost.wait > 4.0 then
        ghost = nil
        hint("that part failed to spawn — try again", 2.5)
      end
    end
  end

  -- ── Ghost follows the cursor ──
  if ghost and (ghost.node or ghost.carried) then
    local snap = find_snap()
    local x, y, z
    if snap then
      x, y, z = snapPlace(snap) -- the ghost-centre (and turn) this snap implies
    else
      x, y, z = free_pos()
    end
    if ghost.carried then
      local root = parts[ghost.from_uid]
      local dx, dy, dz = x - root.x, y - root.y, z - root.z
      for _, m in ipairs(ghost.carried) do
        local p = parts[m.uid]
        if p then set_part_pos(p, p.x + dx, p.y + dy, p.z + dz) end
      end
    elseif ghost.node then
      ghost.node.x, ghost.node.y, ghost.node.z = x, y, z
      ghost.node.yaw, ghost.node.pitch, ghost.node.roll = ghost.yaw, ghost.pitch, ghost.roll
    end

    -- Telegraphs (in-game draw.* layer): EVERY free attach node shows as a
    -- ring while a part is in hand; the captured one goes bright green with a
    -- tie line; carried stacks get amber outlines.
    local exclude = nil
    if ghost.carried then
      exclude = {}
      for _, m in ipairs(ghost.carried) do
        exclude[m.uid] = true
        local cp = parts[m.uid]
        if cp then outline(cp, 1.0, 0.75, 0.3, 0.9) end
      end
    end
    do
      local occupied_top, occupied_bottom = {}, {}
      for _, p in pairs(parts) do
        if p.parent and parts[p.parent] and not (exclude and exclude[p.parent])
          and p.att ~= "radial" and p.att ~= "surface" then
          if p.y >= parts[p.parent].y then occupied_top[p.parent] = true
          else occupied_bottom[p.parent] = true end
        end
      end
      local _, gey = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
      for uid, p in pairs(parts) do
        if not (exclude and exclude[uid]) then
          for _, a in ipairs(attach_nodes_of(uid, p, ghost.def, gey, exclude,
                                             occupied_top, occupied_bottom)) do
            if a.side == "radial" then
              -- Flank nodes ring in AMBER, facing outward.
              draw.ring(a.x, a.y, a.z, a.dx, a.dy, a.dz, 0.22, 1.0, 0.75, 0.3, 0.8)
            else
              draw.ring(a.x, a.y, a.z, 0, 1, 0, 0.3, 0.35, 0.85, 1.0, 0.8)
            end
          end
        end
      end
    end
    local free_ok = (partCount == 0) or (ghost.carried and #ghost.carried >= partCount)
        or input.key("alt")
    local can_place, why
    -- Symmetry ring this placement would make: a fresh ×N ring on a plain
    -- radial snap (never on a ring member — those AUTO-mirror instead).
    local sym_slots = nil
    if snap then
      local ex2 = { [snap.uid] = true }
      if exclude then for u in pairs(exclude) do ex2[u] = true end end
      -- A RADIAL mount hugs the hull by design — never overlap-gate it (that
      -- was the "pull it out then push it back" jank). Stack snaps still
      -- reject only a DEEP overlap.
      local blocked = snap.side ~= "radial" and snap.side ~= "surface"
        and overlaps(ghost.def, x, y, z, ex2, ghost.yaw, ghost.pitch, ghost.roll)
      if blocked then
        can_place, why = false, "that spot is buried inside another part"
        draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
      else
        can_place = true
        draw.line(x, y, z, snap.x, snap.y, snap.z, 0.3, 1.0, 0.4, 1.0)
        draw.ring(snap.x, snap.y, snap.z, snap.dx or 0, snap.dy or 1, snap.dz or 0, 0.4, 0.3, 1.0, 0.4, 1.0)
      end
      if can_place and not ghost.carried then
        sym_slots = symSlots(parts[snap.uid], snap, x, y, z)
        if sym_slots then
          for _, s in ipairs(sym_slots) do
            -- Radial ring copies hug the hull too — preview only, no gate.
            local bx3, by3, bz3 = eff_extents(ghost.def, s.yaw, s.pitch, s.roll)
            draw.box(s.x, s.y, s.z, bx3, by3, bz3, s.yaw, 1.0, 0.75, 0.3, 0.55)
          end
        end
      end
    elseif free_ok then
      if overlaps(ghost.def, x, y, z, exclude, ghost.yaw, ghost.pitch, ghost.roll) then
        can_place, why = false, "overlapping — find clear ground"
        draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
      else
        can_place = true
        local _, gey2 = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
        draw.ring(x, y - gey2, z, 0, 1, 0, 0.35, 0.4, 0.7, 1.0, 1.0)
      end
    else
      can_place, why = false, nil -- routine: aim at an attach node
      draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
    end

    -- DEL with a part in hand scraps EVERYTHING being carried.
    if input.pressed("delete") or input.pressed("del") then
      if ghost.carried then
        local datas = {}
        for _, m in ipairs(ghost.carried) do
          local d = remove_part(m.uid)
          if d then datas[#datas + 1] = d end
        end
        push_undo({ type = "scrap", parts = datas })
        ui("scrap", 0.8)
        hint("scrapped " .. #datas .. " carried part(s) — CTRL+Z to undo", 2.5)
      elseif ghost.node then
        destroy(ghost.node)
        hint(HINT_IDLE, 0.0); hint_t = 0
      end
      ghost = nil
      return
    end

    if rot_input(ghost) then
      local gn = ghost.carried and parts[ghost.from_uid].node or ghost.node
      if gn then gn.yaw, gn.pitch, gn.roll = ghost.yaw, ghost.pitch, ghost.roll end
      if ghost.carried then
        local r = parts[ghost.from_uid]
        if r then r.yaw, r.pitch, r.roll = ghost.yaw, ghost.pitch, ghost.roll end
      end
    end
    if input.pressed("escape") then cancel_ghost() return end
    if not cam_busy and clicked then
      if can_place then
        local host_uid = snap and snap.uid or nil
        local host = host_uid and parts[host_uid]
        -- Placing ON a ring member auto-mirrors across its whole ring;
        -- sym_slots means a fresh ×N ring around a plain host.
        local on_ring = (host and host.sym and not ghost.carried) or false
        local gdata = sym_slots and { id = ghost.id } or nil
        local gid = nil
        if sym_slots then
          next_sym = next_sym + 1
          gid = next_sym
        end
        local placed = place_ghost(x, y, z, host_uid, snap and snap.side or nil, gid)
        selected_uid = placed -- the freshly placed part becomes the selection
        if sym_slots and placed then
          local uids = { placed }
          local mir = sym_slots[1] and sym_slots[1].mir
          if mir and parts[placed] then parts[placed].mir = mir end
          for _, s in ipairs(sym_slots) do
            uids[#uids + 1] = spawn_part(gdata.id, s.x, s.y, s.z, s.yaw,
                                         host_uid, nil, s.pitch, s.roll, snap.side, gid, s.mir)
          end
          -- The ring un-places as ONE undo op.
          if #undo_stack > 0 and undo_stack[#undo_stack].type == "place"
            and undo_stack[#undo_stack].uid == placed then
            table.remove(undo_stack)
          end
          push_undo({ type = "place_group", uids = uids })
          hint(string.format("×%d ring placed — CTRL+Z removes it all", #uids), 2.5)
        elseif on_ring and placed then
          mirror_onto_ring(host_uid, placed)
        end
        -- DOCKING SEAM: ports work in PAIRS — one on each craft, stacked face
        -- to face. A single port welded into a stack is just a spacer and the
        -- flight panel will (correctly) refuse to separate it, so say which one
        -- you've just built the moment it's placed rather than in orbit.
        if placed and parts[placed] and parts[placed].def.dock then
          local host = host_uid and parts[host_uid]
          if host and host.def.dock then
            hint("docking seam — these two separate in flight (peripherals ▸ UNDOCK) " ..
                 "and can re-dock later", 4.0)
          else
            hint("docking port placed — it needs a SECOND port stacked on its free " ..
                 "face to make a seam that separates", 4.0)
          end
        end
      elseif why then
        hint(why, 2.0)
      else
        hint("no attach node under the cursor — aim at a green node, or hold ALT to place free", 2.5)
      end
    end
    return
  end

  -- ── Whole-ship grab ──
  if input.pressed("g") and partCount > 0 and not grab_mode then
    grab_mode = true
    grab_last = nil
    grab_moved = false
    local moved = {}
    for uid, p in pairs(parts) do
      moved[#moved + 1] = { uid = uid, x = p.x, y = p.y, z = p.z, parent = p.parent }
    end
    push_undo({ type = "move", moved = moved })
    click_cool = 0.15
    hint(HINT_GRAB, 8.0)
  end
  if grab_mode then
    local mx, my = input.mouse()
    local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
    if dy < -1e-4 then
      local t = (params.floor_y - oy) / dy
      if t > 0.3 and t < 500 then
        local gx, gz = ox + dx * t, oz + dz * t
        if grab_last then
          local ddx, ddz = gx - grab_last.x, gz - grab_last.z
          if math.abs(ddx) + math.abs(ddz) > 1e-4 then grab_moved = true end
          for _, p in pairs(parts) do set_part_pos(p, p.x + ddx, p.y, p.z + ddz) end
          publish_center()
        end
        grab_last = { x = gx, z = gz }
      end
    end
    draw.ring(centerX, params.floor_y + 0.02, centerZ, 0, 1, 0, 1.2, 0.4, 0.8, 1.0, 1.0)
    if (clicked and not cam_busy) or input.pressed("escape") or input.pressed("g") then
      grab_mode = false
      -- A grab that never moved anything shouldn't eat a CTRL+Z.
      if not grab_moved and #undo_stack > 0 and undo_stack[#undo_stack].type == "move" then
        table.remove(undo_stack)
      end
      hint(HINT_IDLE, 0.0); hint_t = 0
    end
    return
  end

  -- ── Gizmo drag in progress: it owns the mouse until release ──
  if gizmo_drag then
    local p = parts[gizmo_drag.uid]
    if not lmb or not p then
      gizmo_drag = nil
      click_cool = 0.12
    else
      local mx, my = input.mouse()
      local dmx, dmy = mx - gizmo_drag.lmx, my - gizmo_drag.lmy
      gizmo_drag.lmx, gizmo_drag.lmy = mx, my
      local a = GIZ_AXES[gizmo_drag.axis]
      draw_gizmo(p, tool)
      outline(p, 0.55, 0.85, 1.0, 1.0)
      if gizmo_drag.kind == "move" then
        -- Mouse motion projected onto the arrow's screen direction.
        local sx0, sy0 = screen_of(p.x, p.y, p.z)
        local sx1, sy1 = screen_of(p.x + a.x, p.y + a.y, p.z + a.z)
        local vx2, vy2 = sx1 - sx0, sy1 - sy0
        local l2 = vx2 * vx2 + vy2 * vy2
        if l2 > 1e-3 and (dmx ~= 0 or dmy ~= 0) then
          local t2 = (dmx * vx2 + dmy * vy2) / l2
          if input.key("shift") then t2 = t2 * 0.25 end -- fine control
          apply_edit(gizmo_drag.uid, a.x * t2, a.y * t2, a.z * t2, 0, 0, 0)
        end
        hint("MOVE — drag the arrow  ·  SHIFT fine  ·  release to set", 1.0)
      else
        -- Ring turn: horizontal+vertical drag turns about the ring's axis;
        -- SHIFT snaps the accumulated angle to 15° notches.
        local dang = (dmx - dmy) * 0.01
        if dang ~= 0 then
          if input.key("shift") then
            gizmo_drag.acc = (gizmo_drag.acc or 0) + dang
            local notch = math.pi / 12
            local steps = math.floor(gizmo_drag.acc / notch + 0.5)
            dang = steps * notch - (gizmo_drag.snapped or 0)
            gizmo_drag.snapped = steps * notch
          end
          if dang ~= 0 then
            local dy2 = (gizmo_drag.axis == 2) and dang or 0
            local dp2 = (gizmo_drag.axis == 1) and dang or 0
            local dr2 = (gizmo_drag.axis == 3) and dang or 0
            apply_edit(gizmo_drag.uid, 0, 0, 0, dy2, dp2, dr2)
          end
        end
        hint("ROTATE — drag the ring  ·  SHIFT snaps 15°  ·  release to set", 1.0)
      end
    end
    return
  end

  -- ── Hover preview + SELECT + tool action ──
  -- Clicking a part SELECTS it (persists); hovering only previews what a
  -- click would pick. The selection's gizmo follows the active TOOL — never
  -- the cursor — so nudging one part can't grab another.
  hover_uid = (not cam_busy) and part_under_cursor(70) or nil
  local sel = selected_uid and parts[selected_uid]
  if not sel then selected_uid = nil end

  -- The selected part: bright outline + (in Move/Rotate) its tool gizmo.
  local giz_len, giz_rad = nil, nil
  if sel then
    outline(sel, 0.4, 0.95, 0.7, 1.0)
    for u in pairs(edit_set(selected_uid)) do
      if u ~= selected_uid and parts[u] then outline(parts[u], 0.4, 0.95, 0.7, 0.3) end
    end
    if tool == "move" or tool == "rotate" then
      giz_len, giz_rad = draw_gizmo(sel, tool)
      if clicked and not cam_busy then
        local kind, ai = gizmo_hit(sel, tool, giz_len, giz_rad)
        if kind then
          local mx, my = input.mouse()
          gizmo_drag = { uid = selected_uid, kind = kind, axis = ai, lmx = mx, lmy = my }
          return -- a gizmo grab never re-selects
        end
      end
    end
  end

  -- Hover preview: a soft outline of what a click would select.
  if hover_uid and hover_uid ~= selected_uid then
    outline(parts[hover_uid], 0.8, 0.88, 1.0, 0.45)
  end

  -- Click: SELECT the hovered part, or (GRAB tool) pick it up to re-attach.
  -- Clicking empty space deselects — EXCEPT a click that lands on the active
  -- gizmo's footprint (a missed handle grab), which keeps the selection so
  -- fiddling with the Move/Rotate gizmo never drops what you're editing.
  if clicked and not cam_busy then
    if hover_uid then
      if tool == "grab" then
        pickup(hover_uid) -- carry flow → re-place at a new attach node
        selected_uid = nil
      else
        selected_uid = hover_uid
      end
      return
    end
    if sel and giz_len then
      local gx, gy, gr = gizmo_footprint_px(sel, tool, giz_len, giz_rad)
      if gx then
        local mx, my = input.mouse()
        if (mx - gx) ^ 2 + (my - gy) ^ 2 <= gr * gr then return end -- keep selection
      end
    end
    selected_uid = nil -- clicked the empty canvas, clear of the gizmo
    return
  end

  -- ── Selection editing (acts on the SELECTION; a fallback to the gizmo) ──
  if sel then
    local p = sel
    -- Arrow keys nudge (↑/↓ vertical, ←/→ screen-horizontal, ALT+←/→ depth,
    -- SHIFT fine); R/T/Y rotate. All route through apply_edit on the
    -- selection (ring-symmetric, one undo op per streak).
    local step = input.key("shift") and params.nudge * 0.25 or params.nudge
    local ddx, ddy, ddz = 0, 0, 0
    if input.pressed("up") then ddy = step end
    if input.pressed("down") then ddy = -step end
    local h = (input.pressed("right") and 1 or 0) - (input.pressed("left") and 1 or 0)
    if h ~= 0 then
      local mx, my = input.mouse()
      local _, _, _, d1x, _, d1z = camera.screenToRay(mx, my)
      local _, _, _, d2x, _, d2z = camera.screenToRay(mx + 40, my)
      local rxx, rzz = d2x - d1x, d2z - d1z
      if input.key("alt") then rxx, rzz = -rzz, rxx end
      if math.abs(rxx) >= math.abs(rzz) then
        ddx = (rxx >= 0 and 1 or -1) * h * step
      else
        ddz = (rzz >= 0 and 1 or -1) * h * step
      end
    end
    local rot = { yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0 }
    local turned = rot_input(rot)
    if ddx ~= 0 or ddy ~= 0 or ddz ~= 0 or turned then
      apply_edit(selected_uid, ddx, ddy, ddz,
        turned and (rot.yaw - (p.yaw or 0)) or 0,
        turned and (rot.pitch - (p.pitch or 0)) or 0,
        turned and (rot.roll - (p.roll or 0)) or 0)
    end
    -- DEL scraps the selection + its stack (a ring member takes the ring).
    if input.pressed("delete") or input.pressed("del") then
      local grab = edit_set(selected_uid)
      local datas = {}
      for u in pairs(grab) do
        local d = remove_part(u)
        if d then datas[#datas + 1] = d end
      end
      push_undo({ type = "scrap", parts = datas })
      ui("scrap", 0.8)
      hint("scrapped " .. #datas .. " part(s) — CTRL+Z to undo", 2.5)
      selected_uid = nil
    end
  else
    nudge_uid = nil -- nothing selected: next edit opens a fresh undo op
  end

  -- ── Shortcuts ──
  if input.key("ctrl") and input.pressed("z") then undo() end
  if input.key("ctrl") and input.pressed("s") then save_blueprint() end
  if input.pressed("f5") then load_blueprint() end
  -- ESC LEAVES, once it has nothing nearer to cancel. The two `escape` handlers
  -- above this one take their turn first — a part on the cursor, a gizmo drag —
  -- so the key backs out one level at a time and only reaches the door when
  -- there is nothing else in front of it. Same ladder as the rest of the game.
  if input.pressed("escape") and not ghost and not gizmo_drag and not grab_mode then
    doLeave()
  end
end

-- The HUD buttons call these too.
function doSave() save_blueprint() end

-- LEAVE WITHOUT BUYING ANYTHING.
--
-- There was no way out of here. The Vehicle Assembly is a whole scene, and the
-- only two doors were SAVE (which stays) and LAUNCH (which charges you for a
-- hull and puts it on the pad). Walk into the hangar to look at the parts, or
-- open it by accident on the way past, and the game's answer was: buy a rocket.
--
-- The blueprint is kept, because leaving is not the same as discarding — you
-- come back to the craft you were drawing.
function doLeave()
  save_blueprint()
  save.set("shipyard.launch", false)
  save.set("shipyard.pilot", 0)
  save.flush()
  scene.load("system")
end
-- A launch with warnings is TWO presses: the first says what is wrong and
-- arms; the second, within LAUNCH_CONFIRM seconds, goes. Nothing is charged
-- until it actually goes.
LAUNCH_CONFIRM = 6.0
launchArmedAt = nil
function doLaunch()
  local chk = launchCheck()
  if chk.block then
    hint("can't launch — " .. chk.block, 4.0)
    ui("tool", 0.7)
    return false
  end
  if #chk.warn > 0 and not (launchArmedAt and time - launchArmedAt <= LAUNCH_CONFIRM) then
    launchArmedAt = time
    hint("⚠ " .. table.concat(chk.warn, "  ·  ") .. "  —  press LAUNCH again to fly it anyway", LAUNCH_CONFIRM)
    ui("tool", 0.7)
    return false
  end
  launchArmedAt = nil
  -- The hull is BOUGHT at rollout. Crash it and that money is gone; bring it
  -- home and recover it and most of it comes back. That's the whole loop, and
  -- it only means anything if the pad refuses a build you can't pay for.
  local co = company_ref()
  local cost = build_cost()
  if co and co.afford and not co.afford(cost) then
    hint(string.format("can't afford this build — it costs %s and the budget is %s. Sell ore at the depot or fly a contract.",
      co.money(cost), co.money(co.balance())), 4.0)
    return
  end
  if co and co.spend then co.spend(cost, "hull rollout (" .. partCount .. " parts)") end
  save.set("shipyard.spent", cost)
  save_blueprint()
  ui("launch", 1.0)
  save.set("shipyard.launch", 1)
  save.set("shipyard.pilot", 1) -- you launch IN the pod, not beside it
  save.flush()
  scene.load("system")
end
