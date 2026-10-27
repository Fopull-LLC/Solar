-- PARTS_AERO — the aircraft parts: wings, control surfaces, a cockpit, a
-- turbojet, intakes, a fuselage tank and landing gear.
--
-- A data script on the AeroLib node (prefabs/AeroLib.prefab.ron, beside
-- scripts/aero.lua). The builder reaches it with findScript("parts_aero") and
-- calls `register(REG, CATALOGUE)` once (SCRATCH/aero/builder.patch): every
-- entry joins the registry as if it were written there, and the AIRCRAFT
-- section joins the catalogue.
--
-- The entries are builder registry entries (see builder.lua REG for the
-- common keys: prefab, label, h, rx, rz, mass, cost, top, bottom, kind, side,
-- radial_orient, strength, maxq, thrust, ve, fuel, wheel, mods) plus ONE new
-- key, `af`: the part's aerodynamics as a string (scripts/aero.lua `parse`,
-- and SCRATCH/aero/NOTES.md for the format). The blueprint carries `af`
-- verbatim, so the flight never has to know a part by name.
--
-- FRAMES. A lifting surface is a radial part: +X is its span (out from the
-- root, which sits on the host's flank), +Y its chord with the LEADING EDGE at
-- +Y — the host's own +Y, which is the nose-ward axis of a fuselage built
-- nose-up — and ±Z its faces. So a wing on a fuselage's side, a tail fin on
-- its back and a fin on a rocket are the same kind of part, and a mirrored or
-- ring copy keeps its leading edge forward. The cockpit flies nose-first:
-- its +Y is the nose and −Z the canopy (its top), the same convention the pod
-- has (window at −Z). Lay it down in the builder (nose along the floor) for a
-- runway plane, or stand it up for a VAB-style spaceplane; the controls follow
-- the cockpit either way.
--
-- MASSES are an aircraft's, not a rocket's: composite skins and a light jet.
-- A light jet built from these (cockpit, fuselage tank, Wasp, two Wing Panel
-- L, two tips, two elevon panels, a tail fin, two intakes and three gears)
-- weighs 1.8 t, stands on 12.5 m² of wing and leaves the 250 m runway at
-- ~45 m/s (SCRATCH/aero/NOTES.md has the flight numbers).

local function wing(span, root, tip, lsw, le, extra)
  return string.format("wing span=%g root=%g tip=%g lsw=%g le=%g%s", span, root, tip, lsw, le, extra or "")
end

PARTS = {
  -- ── COMMAND ───────────────────────────────────────────────────────────────
  -- A one-seat fighter cockpit on a 1.0 m fuselage: a bubble canopy over the
  -- −Z side (the top), the nose at +Y, the stack node at its tail. A light
  -- reaction wheel (a plane is flown by its surfaces), a battery.
  cockpit = { prefab = "PartCockpit", label = "Swift Cockpit", h = 2.20, rx = 0.50, rz = 0.50, mass = 0.35, cost = 700,
              top = false, bottom = true, kind = "crewed", side = true, strength = 600, maxq = 140,
              af = "cockpit cdF=0.1 cd=0.45",
              mods = { { type = "command", crew = 1, draw = 0.04 }, { type = "wheel", torque = 0.12, draw = 0.1 },
                       { type = "battery", ec = 60 } } },

  -- ── PROPULSION ────────────────────────────────────────────────────────────
  -- FUSELAGE TANK: liquid fuel in a 2 m painted fuselage section; jets and
  -- rockets drink the same pool.
  fuseTank = { prefab = "PartFuseTank", label = "Fuselage Tank", h = 2.00, rx = 0.50, rz = 0.50, mass = 0.12, cost = 200,
               top = true, bottom = true, kind = "tank", fuel = 50, side = true, strength = 600, af = "cd=0.55" },
  -- WASP TURBOJET: air-breathing. Its thrust needs an intake's air and an
  -- atmosphere with oxygen in it; it spools up over ~2 s, holds roughly level
  -- to Mach 1 and falls away past it, thins with the air, and burns its fuel
  -- twenty times slower than a rocket (ve 3200 against a Sputter's 160).
  -- `air` is the intake area (m²) it needs for full thrust.
  jet = { prefab = "PartTurbojet", label = "Wasp Turbojet", h = 1.80, rx = 0.50, rz = 0.50, mass = 0.35, cost = 1000,
          top = true, bottom = false, kind = "engine", thrust = 11, ve = 3200, strength = 700,
          af = "jet air=0.12 spool=2.2 mmax=1.6 cdB=0.35 cd=0.55" },
  -- RAM INTAKE: a radial scoop (its mouth at +Y, facing the flight). Two feed
  -- one Wasp at full thrust standing still; ram air feeds it more with speed.
  intake = { prefab = "PartIntake", label = "Ram Intake", h = 0.90, rx = 0.20, rz = 0.24, mass = 0.03, cost = 120,
             top = false, bottom = false, kind = "structural", radial_orient = true, strength = 250,
             af = "intake=0.06 cdF=0.45 cd=0.5" },
  -- SHOCK CONE: a nose intake for a jet with no cockpit at the front (a
  -- drone, a cruise missile, an engine pod).
  intakeCone = { prefab = "PartIntakeCone", label = "Shock Cone Intake", h = 1.00, rx = 0.50, rz = 0.50, mass = 0.06, cost = 220,
                 top = false, bottom = true, kind = "structural", aero = true, side = true, strength = 400,
                 af = "intake=0.14 cdF=0.18 cd=0.5" },

  -- ── WINGS ─────────────────────────────────────────────────────────────────
  -- Cambered (cl0: lift at zero angle, toward the craft's top), so a wing set
  -- level lifts; the tail surfaces are symmetric.
  wingS = { prefab = "PartWingS", label = "Wing Panel S", h = 1.00, rx = 1.00, rz = 0.05, mass = 0.03, cost = 90,
            top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 350, maxq = 140,
            af = wing(2.0, 1.0, 1.0, 0, 0.5, " cl0=0.3") },
  wingL = { prefab = "PartWingL", label = "Wing Panel L", h = 1.60, rx = 1.75, rz = 0.07, mass = 0.07, cost = 180,
            top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 500, maxq = 140,
            af = wing(3.5, 1.6, 1.6, 0, 0.8, " cl0=0.3") },
  wingSwept = { prefab = "PartWingSwept", label = "Swept Wing", h = 2.00, rx = 1.50, rz = 0.07, mass = 0.06, cost = 200,
                top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 500, maxq = 160,
                af = wing(3.0, 1.8, 0.8, 1.2, 1.0, " cl0=0.2") },
  wingTip = { prefab = "PartWingTip", label = "Wing Tip", h = 0.80, rx = 0.60, rz = 0.04, mass = 0.012, cost = 50,
              top = false, bottom = false, kind = "structural", radial_orient = true, strength = 250, maxq = 160,
              af = wing(1.2, 0.8, 0.3, 0.5, 0.4, " cl0=0.2") },
  wingDelta = { prefab = "PartWingDelta", label = "Delta Wing", h = 3.00, rx = 1.20, rz = 0.08, mass = 0.07, cost = 250,
                top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 550, maxq = 180,
                af = wing(2.4, 3.0, 0.4, 2.4, 1.5, " cl0=0.1") },

  -- ── CONTROL SURFACES ──────────────────────────────────────────────────────
  -- Each is a whole panel with a hinged trailing-edge flap (or all-moving, the
  -- canard). `ctl` names the axes it answers (p pitch, y yaw, r roll): the
  -- flight works out which way each must move for each axis from where it
  -- sits. `flap` is the moving share of the chord (its hinge line at 1 − flap;
  -- none = all-moving), `defl` its travel in degrees.
  elevon = { prefab = "PartElevon", label = "Elevon Panel", h = 1.00, rx = 0.80, rz = 0.05, mass = 0.025, cost = 150,
             top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 300, maxq = 160,
             af = wing(1.6, 1.0, 0.6, 0.4, 0.5, " ctl=pr defl=25 flap=0.35") },
  aileron = { prefab = "PartAileron", label = "Aileron Panel", h = 1.20, rx = 1.00, rz = 0.06, mass = 0.035, cost = 160,
              top = false, bottom = false, kind = "structural", radial_orient = true, side = true, strength = 350, maxq = 160,
              af = wing(2.0, 1.2, 1.2, 0, 0.6, " cl0=0.25 ctl=r defl=20 flap=0.3") },
  tailFin = { prefab = "PartTailFin", label = "Tail Fin", h = 1.50, rx = 0.75, rz = 0.05, mass = 0.03, cost = 140,
              top = false, bottom = false, kind = "structural", radial_orient = true, strength = 300, maxq = 160,
              af = wing(1.5, 1.5, 0.7, 0.8, 0.75, " ctl=y defl=25 flap=0.35") },
  canard = { prefab = "PartCanard", label = "Canard", h = 0.60, rx = 0.50, rz = 0.04, mass = 0.012, cost = 120,
             top = false, bottom = false, kind = "structural", radial_orient = true, strength = 200, maxq = 160,
             af = wing(1.0, 0.6, 0.4, 0.2, 0.3, " ctl=p defl=15") },

  -- ── LANDING GEAR ──────────────────────────────────────────────────────────
  -- A radial leg (+X out = DOWN when it hangs under the belly) with a free-
  -- rolling tyre on the engine's wheel joint: brakes on B, the front gear
  -- steers with A/D, and G folds the legs up into the hull (and down again).
  gearS = { prefab = "PartGearS", label = "Landing Gear S", h = 0.60, rx = 0.50, rz = 0.15, mass = 0.035, cost = 100,
            top = false, bottom = false, kind = "structural", radial_orient = true, strength = 400, wheel = "S", travel = 0.12,
            af = "gear cd=0.9",
            mods = { { type = "drive", torque = 0.15, speed = 0, draw = 0.0, r = 0.25 },
                     { type = "deploy", anim = "legs", default = true } } },
  gearM = { prefab = "PartGearM", label = "Landing Gear M", h = 0.95, rx = 0.75, rz = 0.20, mass = 0.08, cost = 160,
            top = false, bottom = false, kind = "structural", radial_orient = true, strength = 700, wheel = "M", travel = 0.16,
            af = "gear cd=0.9",
            mods = { { type = "drive", torque = 0.4, speed = 0, draw = 0.0, r = 0.40 },
                     { type = "deploy", anim = "legs", default = true } } },
}

-- One line under each name on its catalogue card.
DESC = {
  cockpit = "jet cockpit · 1 crew · nose at +Y, canopy on top · light reaction wheel",
  fuseTank = "fuselage tank · 50 fuel · jets and rockets share it",
  jet = "turbojet · needs an intake and oxygen · spools up · 20× a rocket's economy",
  intake = "radial air intake · mouth forward · two feed one Wasp",
  intakeCone = "nose intake · for a jet with no cockpit in front",
  wingS = "wing 2.0 × 1.0 m · 2.0 m² · cambered",
  wingL = "wing 3.5 × 1.6 m · 5.6 m² · cambered",
  wingSwept = "swept wing 3.0 m · 3.9 m² · for speed",
  wingTip = "tapered wing tip · 0.66 m²",
  wingDelta = "delta wing 2.4 m · 4.1 m² · stalls late",
  elevon = "tail / delta elevon · pitch and roll · 1.3 m²",
  aileron = "wing panel with aileron · roll · 2.4 m²",
  tailFin = "tail fin with rudder · yaw · 1.6 m²",
  canard = "all-moving canard · pitch",
  gearS = "landing gear · r 0.25 m tyre · brakes B, steers A/D, retracts G",
  gearM = "landing gear · r 0.4 m tyre · for heavier aircraft",
}
for id, d in pairs(DESC) do if PARTS[id] then PARTS[id].desc = d end end

-- The catalogue section, in the order the panel shows it.
SECTION = { "AIRCRAFT", { "cockpit", "fuseTank", "jet", "intake", "intakeCone",
                          "wingS", "wingL", "wingSwept", "wingTip", "wingDelta",
                          "elevon", "aileron", "tailFin", "canard", "gearS", "gearM" } }

-- Join the builder: copy every entry into its registry (a fresh table each, so
-- the builder may decorate them) and add the section once. Returns how many
-- parts it added.
function register(REG, CATALOGUE)
  local n = 0
  for id, d in pairs(PARTS) do
    if REG and not REG[id] then
      local c = {}
      for k, v in pairs(d) do c[k] = v end
      REG[id] = c
      n = n + 1
    end
  end
  if CATALOGUE then
    local have = false
    for _, s in ipairs(CATALOGUE) do if s[1] == SECTION[1] then have = true end end
    if not have then CATALOGUE[#CATALOGUE + 1] = { SECTION[1], SECTION[2] } end
  end
  return n
end
