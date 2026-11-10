-- PARTS_SURVEY — the survey parts (expansion plan X1; scripts/survey.lua).
--
-- A data script on the Electronics node (scenes/system.ron and builder.ron,
-- beside parts_nuclear), joined once by the builder through
-- parts_registry.extend as the SCIENCE section of the catalogue.
--
--   Space Telescope  a 0.3 m reflector on a radial cradle. On a craft with
--                    power and a link home it SWEEPS by itself: ten game
--                    minutes on the world it knows least about in its sky
--                    (not hidden behind the one it is at), then the next —
--                    temperature and air, a telescope's 0.3 (survey tel30).
--   Orbital Scanner  an imaging spectrometer and limb sounder (a CRISM-class
--                    instrument). In orbit 0.1–1.5 radii up a world, powered
--                    and heard by the ground, it maps the ground under its
--                    track: composition 0.7, the air 0.9, and the resources
--                    by SWATH (X7): the cells of the world's grid its swath
--                    passes over (30° either side of nadir; the worlds do not
--                    turn, so each orbital plane maps one band, a higher
--                    orbit a wider one). Mount it on the belly, looking down.
--   Gravimeter       (X7) a cold-atom gravity gradiometer with a fluxgate
--                    magnetometer on a boom, in the scanner's housing: in
--                    orbit 0.1–1.5 radii up, powered and heard, gravity at
--                    once and the magnetic field over three orbits (GOCE and
--                    Swarm-class; the mag layer without landing).
-- Both are RADIAL parts: +X out of the face they mount on, +Y up the stack
-- (tools/gen_survey_parts.py writes the meshes; keep the boxes in step).
--
-- MASSES from the real things: a 0.3 m space telescope's OTA and cradle are
-- ~60 kg; CRISM is 33 kg, a scanner with its bracket, radiators and
-- electronics 180 kg here.

PARTS = {
  telescopeS = { prefab = "PartTelescopeS", label = "Space Telescope", h = 0.81, rx = 0.215, rz = 0.20, mass = 0.06, cost = 3200,
                 top = false, bottom = false, kind = "structural", radial_orient = true, strength = 120,
                 survey = { kind = "telescope", ap = 0.3 } },
  scanner = { prefab = "PartScanner", label = "Orbital Scanner", h = 0.42, rx = 0.23, rz = 0.14, mass = 0.18, cost = 4500,
              top = false, bottom = false, kind = "structural", radial_orient = true, strength = 140,
              survey = { kind = "scanner" } },
  -- (X7) the same housing and mesh as the scanner: GOCE's gradiometer is ~180 kg
  gravimeter = { prefab = "PartScanner", label = "Gravimeter", h = 0.42, rx = 0.23, rz = 0.14, mass = 0.16, cost = 5200,
                 top = false, bottom = false, kind = "structural", radial_orient = true, strength = 140,
                 survey = { kind = "gravimeter" } },
}

ORDER = { "telescopeS", "scanner", "gravimeter" }
SECTION = "SCIENCE"

DESC = {
  telescopeS = "0.3 m space telescope · sweeps the worlds in its sky by itself: temperature and air · needs power and a link",
  scanner = "orbital scanner · in orbit 0.1–1.5 radii up: composition, air, and the resources under its swath (each orbital plane maps a band) · needs power and a link",
  gravimeter = "gravimeter · in orbit 0.1–1.5 radii up: gravity, and the magnetic field in three orbits · needs power and a link",
}
for id, d in pairs(DESC) do if PARTS[id] then PARTS[id].desc = d end end

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
