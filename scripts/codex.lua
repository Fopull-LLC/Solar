-- CODEX — what the lab knows about each material: a name, a one-line summary
-- and a few facts the scientists tell you when you ask (scripts/lab_talk.lua).
--
-- DATA, NOT UI. Any script can add or replace entries; another agent adds the
-- off-world ores (materials.lua's ORE table) here. An entry:
--
--   CODEX[id] = { name = "…" (else materials.label), summary = "one line",
--                 facts = { "a sentence", … }, fictional = true|nil,
--                 sample = "LooseRock" | "LooseLog" | "LooseCrystal" | … (the
--                 model the talk view turns; else chosen by class) }
--
--     local cx = findScript("codex")
--     cx.entry("iron")  → the entry, or a plain one made from the material
--
-- REAL MATERIALS get real facts: how it is refined, where it occurs in the
-- solar system, what it is for on a spacecraft, its use in ISRU (in-situ
-- resource utilisation: living off the land), missions that met it.
--
-- FICTIONAL MATERIALS follow the RULES below, and every entry that touches
-- one obeys them, so a player who reads closely finds a physics that holds
-- together. They are written in the same flat, factual voice as the real
-- ones — that is the joke and the point.
--
-- THE RULES OF THIS UNIVERSE (keep every fictional entry consistent):
--   1. VEY'S LAW (lattice memory). Some crystal lattices hold a standing
--      phonon — a sound wave in the atoms — without loss below their VEY
--      POINT, a temperature set by the lattice. Above it the stored energy
--      leaks out as light: glow brightness rises with (T − T_vey). Resonant
--      Crystal's Vey point is −38 °C, so it glows faintly at room
--      temperature and goes dark in a freezer.
--   2. A held mode RINGS at a pitch fixed by the crystal's longest dimension
--      (about 4.1 kHz for a 1 cm crystal, falling as 1/length). Two crystals
--      tuned to the same pitch exchange energy across a room ("sympathy").
--   3. CLOSED CAVITIES (geodes) trap their modes: the lining's waves
--      interfere into a stable CHORD that does not decay at any temperature
--      — the only Vey-exempt structure known.
--   4. BIORESONANCE. A few organisms grow lattice-forming proteins and feed
--      on ambient resonance as plants feed on light; their glow obeys rule 1.
--   5. PHASE DENSITY (phasite). Some matter's density scales with local
--      gravity as g^−½: lighter where gravity is strong, heavier where it is
--      weak. (materials.lua: phasite, cryovolt.)

CODEX = {
  -- ── bulk ground ────────────────────────────────────────────────────────
  regolith = { summary = "The broken rock dust that blankets airless worlds.", facts = {
    "On an airless body regolith is made by billions of years of micrometeorite impacts, so its grains stay jagged: no wind or water ever rounds them.",
    "Apollo crews found it clung to everything and abraded suit seals and visors; dust was one of the programme's biggest engineering surprises.",
    "Lunar regolith is about 40-45% oxygen by mass, locked in oxides. Molten regolith electrolysis can pull that oxygen out for breathing and propellant.",
    "Microwave-sintered regolith is a candidate for landing pads, which would stop a lander's plume from sandblasting everything nearby.",
  } },
  soil = { summary = "Weathered rock mixed with organic matter and water.", facts = {
    "True soil is partly biological: on Earth a gram can hold billions of microbes. Without life, planetary scientists say regolith instead.",
    "The Phoenix lander found perchlorate salts in Martian soil in 2008, about 0.5%. They are toxic to people and must be washed out before farming.",
    "Soil's water content changes its strength sharply. Rover traction models use terramechanics equations first written for military vehicles.",
  } },
  sand = { summary = "Rock and mineral grains between 0.06 and 2 mm.", facts = {
    "Sand is defined by grain size, not by what it is made of. On Titan the dunes are probably organic grains, not silicate.",
    "Spirit, the Mars rover, broke through a crust into soft sand at 'Troy' in 2009 and never drove out. It worked on as a stationary station until 2010.",
    "Quartz sand melted with soda and lime is ordinary glass, the oldest high-temperature industry there is.",
  } },
  clay = { summary = "Fine sheet-silicate minerals that form when rock meets water.", facts = {
    "Clay minerals need liquid water to form, so orbiters mapping clays on Mars (at Mawrth Vallis, for example) found ancient wet environments from space.",
    "Curiosity found clays in Gale Crater's mudstones, evidence of a long-lived lake that could have supported microbes.",
    "Fired clay ceramics are the ancestors of the tiles that protected the Space Shuttle's belly on re-entry.",
  } },
  gravel = { summary = "Loose rock fragments, 2 to 64 mm.", facts = {
    "Crushed gravel is aggregate: about three-quarters of the volume of ordinary concrete.",
    "Rounded pebbles seen by Curiosity at 'Hottah' in 2012 were shaped by flowing water, ankle to hip deep, on ancient Mars.",
    "Graded gravel spreads a load and drains water, which is why launch pads and runways start with layers of it.",
  } },
  ash = { summary = "Powdered rock and glass thrown out by volcanic eruptions.", facts = {
    "Ash is glass, not soot, and it melts inside jet engines. British Airways Flight 9 lost all four engines to an ash cloud in 1982 and restarted them in the descent.",
    "Apollo 17 geologist Harrison Schmitt found 'orange soil' at Shorty crater: tiny glass beads from a lunar fire-fountain eruption about 3.6 billion years ago.",
    "Volcanic ash mixed with lime is the pozzolanic cement that kept Roman harbour concrete standing for two thousand years.",
  } },
  basalt = { summary = "Dark volcanic rock, the most common crust on rocky worlds.", facts = {
    "The dark lunar maria are basalt flows, as are much of Mars, Venus and the ocean floors of Earth.",
    "Basalt drawn into fibre makes a composite reinforcement that rivals glass fibre and resists heat. It is a strong candidate for building with local rock off Earth.",
    "Cast basalt is melted and poured into liners for chutes and pipes, because it outlasts steel against abrasive flows.",
  } },
  granite = { summary = "Coarse quartz-and-feldspar rock that cooled slowly underground.", facts = {
    "Granite is rare beyond Earth: it needs water and recycling of crust, so it is a sign of a geologically busy world.",
    "Granite is so dimensionally stable that precision metrology plates and optical tables are made from it.",
    "Granite holds trace uranium and thorium. Their slow decay is part of what keeps Earth's interior warm.",
  } },
  sandstone = { summary = "Sand cemented into rock by minerals in groundwater.", facts = {
    "Cross-bedding in Martian sandstone, the tilted layers left by migrating ripples, records ancient winds and streams. Curiosity photographed it at Gale Crater.",
    "Sandstone's open pores make it a reservoir rock for water, oil and gas on Earth.",
    "Sintering lunar simulant into sandstone-like bricks is one of ESA's tested methods for 3D-printing shelters.",
  } },
  limestone = { summary = "Calcium carbonate rock, mostly made by living things.", facts = {
    "Most limestone is the shells and skeletons of sea creatures, so a limestone layer is a fossil record of an ocean.",
    "Heat limestone and it gives off CO₂ and leaves lime, the start of cement, along with a large share of industry's carbon emissions.",
    "Carbonates are scarce on Mars; Perseverance was sent to Jezero Crater partly because orbiters spotted them around its old lake shore.",
  } },
  shale = { summary = "Fine mud pressed into layered rock.", facts = {
    "Curiosity's first drill holes, in 2013 at Yellowknife Bay, were in mudstone that had formed at the bottom of a calm, drinkable lake.",
    "Fine-grained mudstones are where organic molecules survive best: they seal them away from radiation and oxygen.",
    "Shale splits along its bedding, which makes a sample easy to break and also easy to misjudge in a drill.",
  } },
  slate = { summary = "Shale changed by heat and pressure into a hard, splitting rock.", facts = {
    "Slate splits along cleavage planes set by the pressure that formed it, not along its original bedding.",
    "Its low water absorption made it the classic roofing material, and once the standard for blackboards.",
    "Slate's cleavage direction records the direction of the squeeze that built a mountain range.",
  } },
  rustrock = { summary = "Iron-rich rock reddened by oxidation.", facts = {
    "The rust colour is ferric iron oxide, the same chemistry that makes Mars red: just a thin coating can tint a whole landscape.",
    "Oxidised iron in rock means free oxygen or water once reached it. On Earth that dates many red beds to after the Great Oxidation Event.",
    "Red, iron-rich crusts absorb sunlight, so they run hotter than pale rock nearby. Rover thermal models account for it.",
  } },
  veinstone = { summary = "The barren mineral filling around ore in a vein (gangue).", facts = {
    "Hot fluids moving through cracks drop quartz and carbonate as they cool; the ore minerals ride along in a fraction of a percent.",
    "Miners call it gangue. Separating it from the ore by flotation, magnets or density is most of the cost of processing.",
    "Its orange staining is iron oxide weathered out of sulfides, the same 'gossan' signal prospectors have followed for centuries.",
  } },
  hematite = { summary = "Earthy red iron oxide, Fe₂O₃.", facts = {
    "Red ochre, earthy hematite, is one of humanity's oldest pigments: it is in cave paintings tens of thousands of years old.",
    "The Opportunity rover found small hematite spheres, the 'blueberries', at Meridiani Planum: concretions grown in groundwater.",
    "Hematite is about 70% iron by mass, a rich ore once the clay and sand around it are removed.",
  } },
  salt = { summary = "Halite, sodium chloride, left where water evaporated.", facts = {
    "Hubble spectra in 2019 showed sodium chloride on the surface of Europa, likely brought up from the ocean beneath its ice.",
    "Ceres' bright spots in Occator Crater, imaged by Dawn, are mostly sodium carbonate salts from brine that welled up and evaporated.",
    "Molten salts carry and store heat well. Molten salt reactors and solar thermal plants both rely on that.",
  } },
  onyx = { summary = "Banded chalcedony: microcrystalline quartz laid down in layers.", facts = {
    "Each band is a pulse of silica-rich water filling a cavity. The banding is a timeline of the fluid's chemistry.",
    "Chalcedony's fibres are microscopic quartz crystals, which makes it tougher than a single quartz crystal.",
    "Much stone sold as 'onyx' is really banded calcite. A drop of acid tells them apart: calcite fizzes.",
  } },

  -- ── ore ────────────────────────────────────────────────────────────────
  silica = { summary = "Silicon dioxide: quartz, glass and the start of every solar cell.", facts = {
    "Spacecraft windows are fused silica. The Space Shuttle's outer panes were fused silica to survive re-entry heating and thermal shock.",
    "Silica aerogel, more than 99% empty space, captured comet dust intact for the Stardust mission in 2004.",
    "Solar-grade silicon starts as quartz reduced with carbon in an arc furnace above 1,900 °C, then purified to 99.9999% or better.",
  } },
  iron = { summary = "Iron oxide ore, the backbone of heavy industry.", facts = {
    "Iron oxide can be reduced with hydrogen instead of coke, and the by-product is water. That is a candidate ISRU process for making steel and water together on the Moon or Mars.",
    "Mars is red because its dust is coated in nanophase iron oxides.",
    "Iron meteorites are iron-nickel alloy from the cores of shattered planetesimals. They were humanity's first source of metallic iron.",
    "Steel is still the default for launch pads, tanks on the ground and transporters: cheap, weldable and forgiving.",
  } },
  copper = { summary = "Copper ore, usually chalcopyrite, CuFeS₂.", facts = {
    "Copper conducts heat at about 400 W/m·K, which is why rocket combustion chambers are lined with copper alloys and cooled by propellant running through channels in the wall.",
    "The Space Shuttle main engine's combustion chamber liner was NARloy-Z, a copper-silver-zirconium alloy. NASA's newer GRCop alloys are 3D-printed.",
    "Ore is concentrated by froth flotation, smelted to about 99% copper, then electrorefined to 99.99%.",
    "Wiring harnesses can be a surprising share of a spacecraft's dry mass, so aluminium and thinner gauges are traded against copper's conductivity.",
  } },
  sulfur = { summary = "Native yellow sulfur from volcanic vents.", facts = {
    "Jupiter's moon Io is painted yellow, red and black by sulfur and sulfur dioxide from the most active volcanoes in the solar system.",
    "Sulfur concrete binds aggregate with molten sulfur at about 120-140 °C and needs no water, an attractive building material for the Moon.",
    "The clouds of Venus are droplets of sulfuric acid, a hazard for any balloon or probe sent there.",
    "Vulcanising rubber with sulfur gave us durable seals and tyres. Almost every O-ring descends from that 1839 discovery.",
  } },
  obsidian = { summary = "Volcanic glass from lava that cooled too fast to crystallise.", facts = {
    "A fractured obsidian edge can be a few nanometres thick, far finer than a steel scalpel. Obsidian blades are still used in some surgery.",
    "It is not a mineral but a glass, typically over 70% silica, rich enough in silica to resist crystallising as it cools.",
    "Obsidian slowly absorbs water at its surfaces, and the thickness of that rind is used to date artefacts.",
  } },
  uranium = { summary = "Uraninite (pitchblende): the main ore of uranium.", facts = {
    "Pitchblende is massive uraninite, UO2: black with a greasy, pitch-like lustre, often in rounded botryoidal crusts. It does not glow. Prospectors find it by its radiation with a Geiger counter or scintillometer, the way your suit's dosimeter does.",
    "Where it weathers it grows bright secondary minerals: yellow-green autunite and torbernite, orange gummite. A yellow stain on dark rock was the classic sign of a uranium showing.",
    "It is one of the densest common minerals, about 10.6 grams per cubic centimetre as pure crystal, and its decay chain fills fractures round it with radon, which rock gas surveys sniff for.",
    "Marie and Pierre Curie found polonium and radium in 1898 by working through tonnes of pitchblende waste from the mines of Joachimsthal (Jachymov), in Bohemia.",
    "Natural uranium is only about 0.72% fissile U-235; reactor fuel is enriched to a few percent.",
    "SNAP-10A in 1965 is still the only US fission reactor operated in orbit. The Soviet Union flew dozens of reactors on its RORSAT radar satellites.",
    "NASA's KRUSTY test in 2018 ran a small uranium-235 reactor for 28 hours, the basis of the Kilopower design for surface power on the Moon and Mars.",
    "A nuclear thermal rocket such as NERVA reached a specific impulse of about 850 s, nearly twice that of the best chemical engines.",
    "Radioisotope generators like Curiosity's MMRTG burn plutonium-238, not uranium: they need heat from decay, not a chain reaction.",
  } },
  magma = { summary = "Molten rock from a magma pocket or seam, quenched glassy and vesicular as it is cut.", facts = {
    "Basaltic magma erupts at about 1100 to 1200 degrees C and glows orange-yellow; it is the only rock on these worlds that gives off its own light, and only because it is hot.",
    "Cooled in seconds it freezes to glass and froth (scoria, pumice) instead of crystals; cooled over years in a sill it becomes ordinary basalt or gabbro.",
    "Volcanic gases come out of it as it rises and the pressure drops: water, carbon dioxide and sulfur dioxide, which is why sulfur crusts gather round vents.",
    "Iceland drills into magma's heat for power; in 2009 the IDDP-1 well hit rhyolite magma at about 2.1 km and briefly ran as the world's hottest geothermal well.",
    "Molten regolith electrolysis, proposed for the Moon, makes its own magma on purpose: melted rock conducts, and a current through it frees oxygen and leaves metal.",
  } },
  ice = { summary = "Frozen water: air, drink, radiation shield and rocket fuel.", facts = {
    "Split water by electrolysis and you get hydrogen and oxygen, rocket propellant. That is why polar ice is the most valuable resource on the Moon.",
    "In 2009 LCROSS slammed a spent rocket stage into Cabeus Crater and saw water in the plume.",
    "Hydrogen-rich water is one of the best radiation shields per kilogram. A water wall around a crew cabin does double duty.",
    "Ice in permanently shadowed craters may stay below about −230 °C, cold enough to trap volatiles for billions of years.",
  } },
  water = { summary = "Liquid water.", facts = {
    "The ISS recovers about 98% of its crew's water, including urine, through distillation and catalytic oxidation.",
    "Water's high specific heat makes it a good coolant loop fluid. Station loops use water inside the cabin and ammonia outside, where water would freeze.",
  } },

  -- ── flora ──────────────────────────────────────────────────────────────
  timber = { sample = "LooseLog", summary = "Wood: cellulose fibres in a lignin matrix.", facts = {
    "LignoSat, a magnolia-wood satellite built by Kyoto University and Sumitomo Forestry, was launched to the ISS in November 2024: the first wooden spacecraft.",
    "Wood burns up completely on re-entry, so a wooden satellite leaves no aluminium oxide particles in the upper atmosphere.",
    "Along the grain, wood's strength-to-weight ratio rivals mild steel. Early aircraft such as the Mosquito bomber were built of it.",
  } },
  fiber = { summary = "Long plant fibres, bast and leaf.", facts = {
    "Flax and hemp fibres reinforce bio-composites. Some car door panels and racing-car bodywork already use flax.",
    "Cellulose is the most abundant organic polymer on Earth, and a feedstock for paper, rayon and nanocellulose films.",
  } },
  biomass = { summary = "Plant matter: food, fuel and air for a closed habitat.", facts = {
    "The Soviet BIOS-3 experiment in the 1970s sealed people in for months, with algae and wheat regenerating their air and much of their food.",
    "ESA's MELiSSA project models a closed ecological loop in compartments, from waste-eating bacteria to higher plants.",
    "Vegetables grown in the ISS Veggie unit were first eaten by a crew in 2015: red romaine lettuce.",
  } },
  resin = { summary = "Sticky tree exudate that hardens in air.", facts = {
    "Orion's heat shield uses Avcoat, an epoxy novolac resin packed into a fibreglass honeycomb: the same family flown on Apollo.",
    "An ablative heat shield works by charring and wearing away, carrying the heat off with the gas it gives off.",
    "Rosin, distilled pine resin, gives violin bows their grip and keeps dancers' shoes from slipping.",
  } },
  kelp = { summary = "Large brown seaweed.", facts = {
    "Giant kelp can grow up to about half a metre a day, one of the fastest growth rates of any organism.",
    "Kelp gives alginate, a gel used in food, wound dressings and some bioprinting inks.",
  } },
  spores = { summary = "Fungal spore pods.", facts = {
    "NASA's myco-architecture research grows building blocks from fungal mycelium, which could be grown on Mars from spores and water.",
    "Some fungi that grow inside the ruined Chernobyl reactor are rich in melanin, and are studied as a radiation-tolerant material.",
  } },

  -- ── fictional (THE RULES, above) ──────────────────────────────────────
  crystal = { fictional = true, sample = "LooseCrystal", summary = "A lattice that remembers sound: it holds a standing phonon and glows as it leaks.", facts = {
    "Its Vey point is −38 °C. Below it the crystal holds its standing mode indefinitely; in a room it leaks the mode as the faint glow you see.",
    "Glow brightness rises with temperature above the Vey point, so a field crystal is a thermometer you can read across a valley.",
    "A 1 cm crystal rings at about 4.1 kHz, and longer crystals ring lower. Two crystals cut to the same pitch trade energy across a room: 'sympathy'.",
    "Packed in dry ice at −78 °C, a charged crystal keeps its mode for years. Thermal shipping is the industry's single biggest cost.",
  } },
  glowsap = { fictional = true, summary = "Sap from plants that feed on ambient resonance.", facts = {
    "The plants grow lattice-forming proteins in their xylem and absorb resonance as other plants absorb light: bioresonance.",
    "The sap's glow obeys Vey's law like mineral crystal: it dims when chilled and brightens when warm.",
    "Glowing stands grow thickest over resonant crystal deposits, so prospectors use them as a free survey.",
  } },
  geode = { fictional = true, summary = "A hollow nodule lined with resonant crystal: a chord in a box.", facts = {
    "In a closed cavity the lining's modes interfere into a stable chord that does not decay at any temperature. It is the only known exception to Vey's law.",
    "Each geode's chord is unique to its cavity, like a fingerprint. Two halves of one geode, cracked apart, keep ringing in sympathy.",
    "They form only deep in the rock, where the cavity sealed while the crystal grew. A surface find has always been weathered out of a deep layer.",
  } },
  rare_cave = { fictional = true, summary = "Spores of a cave fungus that glows in total darkness.", facts = {
    "With no sunlight, gloamcap lives entirely on bioresonance drawn from crystal in the cave walls.",
    "Its glow is brightest in the warmest part of a cave, as Vey's law predicts, so it lights the way toward geothermal vents.",
  } },
  rare_peak = { fictional = true, summary = "Petals from a flower that blooms only above the snow line.", facts = {
    "Frostbloom stores its resonance in its petals and keeps it below the Vey point of its proteins, close to −20 °C.",
    "Carried into a warm cabin, the petals glow for a few hours as the held mode leaks away.",
  } },
  rare_ravine = { fictional = true, summary = "Seed pods that heat themselves.", facts = {
    "Ember pods dump their stored resonance as heat instead of light, warming the seed to germinate on cold ravine floors.",
    "A ripe pod is several degrees warmer than the air. Thermal cameras find them first.",
  } },
  rare_lake = { fictional = true, summary = "Pearls grown by shore molluscs around crystal grit.", facts = {
    "Each pearl's nacre is laid around a grain of resonant crystal, a closed cavity like a tiny geode.",
    "Shore pearls ring a faint, stable chord, so they are a cheap way to study rule-3 cavities in the lab.",
  } },
  rare_river = { fictional = true, summary = "Fronds of a plant that tunes itself to running water.", facts = {
    "Silkspire fronds lengthen until their pitch matches the hum of the current, which tunes them for sympathy with the river.",
    "Cut a frond and it slowly falls out of tune, a natural clock botanists use to date samples.",
  } },
  scrap = { sample = "Debris", summary = "Wreckage: aluminium-lithium alloy, composites, wiring.", facts = {
    "Modern tanks are aluminium-lithium alloys such as 2195, lighter and stiffer than ordinary aerospace aluminium.",
    "The ISS 'Refabricator' in 2019 turned waste plastic into 3D-printer filament, a first step toward recycling in orbit.",
    "Recovered hardware is studied for wear and fatigue. NASA examined Shuttle boosters fished from the Atlantic after every flight.",
  } },
}

local function ref(kind)
  return findScript and findScript(kind) or nil
end

-- The entry for `id`: the codex's own, or a plain one from the materials
-- table (name and class) so the view always has something to show.
function entry(id)
  local e = CODEX[id]
  local mats = ref("materials")
  -- the per-world ores keep their write-ups beside their rules (materials.lua
  -- ORE_CODEX, the same shape): read them from there
  if not e and mats and type(mats.ORE_CODEX) == "table" then e = mats.ORE_CODEX[id] end
  local name = (e and e.name) or (mats and mats.label and mats.label(id)) or id
  if e then
    return { id = id, name = name, summary = e.summary or "", facts = e.facts or {}, fictional = e.fictional == true,
             sample = e.sample }
  end
  local cls = mats and mats.class and mats.class(id) or "ore"
  return { id = id, name = name, summary = "Not yet characterised: the lab is still working on it.",
           facts = { "Bring more samples to the Materials Intake and the team will write it up." },
           fictional = false, sample = nil, class = cls }
end

-- Every id with an entry (sorted), for tests and the other agent's checks.
function ids()
  local out, seen = {}, {}
  for k in pairs(CODEX) do out[#out + 1] = k; seen[k] = true end
  local mats = ref("materials")
  if mats and type(mats.ORE_CODEX) == "table" then
    for k in pairs(mats.ORE_CODEX) do if not seen[k] then out[#out + 1] = k end end
  end
  table.sort(out)
  return out
end
