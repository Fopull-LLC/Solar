-- THE SCENARIO TEMPLATE (docs/scenarios.md). Copy this file to
-- scenarios/<id>.lua, keep the folder scenarios/<id>/ beside it for its files,
-- and fill it in. Files whose names start with "_" are never listed on the
-- menu. `luajit solar/tests/smoke_scenarios.lua` checks every scenario.
--
-- Rules: never a world point (use refs and siting rules); ids are words; every
-- line the player reads is Ops' voice: short, dry, first names, no "!".
return {
  id = "my_scenario",            -- = the file name
  title = "My Scenario",
  v = 1,                         -- bump when the start or the steps change
  order = 100,                   -- the menu's order (lower first)
  minutes = 10,                  -- the menu's "· 10 min"
  teaches = { "buildkit", "rooms" },          -- words the menu shows under the title
  blurb = "One or two sentences for the menu card.",
  -- requires = { "first_light", medal = "bronze" },   -- greyed on the menu until then
  brief = {                      -- the BRIEFING panel, typed in Ops' voice, physics paused
    "Who, where, why: one line.",
    "What we need from you: one line.",
  },

  -- WORLD: the generator's keys (as the new-save panel writes them), or "any"
  -- for the player's own choice. seed rolls the system; home = "alien" with
  -- homeSeed picks an alien home; air = earth | rich | thin | none | random.
  -- gen = { planets = 4, moonchance = 1.0 } overrides a slider.
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  -- time = { at = "night", hold = true } in world holds the key light over the
  -- site: night | dusk | dawn | morning | noon | afternoon | evening | degrees

  -- CAST: who talks. A key per voice; `crew` ties one to a start.crew member.
  -- portrait = "auto": their own face, photographed once the scenario is
  -- staged (random, as every crew member is; `look = <seed>` pins one); the
  -- fallback scenarios/<id>/<key>.png is baked by tools/perf/portraitbooth.sh.
  -- radio = true: heard over the set; delay = secs: each line heard that long
  -- after its beat (light-time); link = "craft:<name>": garbled with no path.
  cast = {
    okafor = { name = "Dele Okafor", tag = "ENGINEER", crew = "Okafor", portrait = "auto", expression = "focus" },
    ops    = { name = "Harrow Ops", tag = "OPS · 3 S DELAY", radio = true, delay = 3 },
  },
  vars = { cold = 20 },
  -- failure = "checkpoint" (the default: a fail goes back to the last
  -- checkpoint with a card) | "end" (a fail ends the run: a challenge)
  failure = "checkpoint",

  -- METERS follow a reading into a variable; MODELS are numbers with a law
  -- of their own (docs/scenarios.md §4.2). Both are data: no hooks.
  meters = {
    -- { var = "kwh", read = "reactor.genKW", struct = "Plant", mode = "integrate", scale = 0.000278 },
    -- { var = "batt", read = "grid.battery", struct = "Shelter" },   -- also dose.msv, suit.o2, room.o2, part.hp, piece.<f>, var.<n>
  },
  models = {
    -- { var = "cold", start = 20, rate = -0.2, rest = 20, tau = 60,
    --   when = { kind = "power_read", struct = "Shelter", powered = false },
    --   at = { { value = 5, down = true, beats = { { say = { who = "okafor", text = "It's freezing in here." } } } } } },
  },

  start = {
    funds = 9000, rp = 0, safety = "rescue",   -- safety: rescue | death | invincible
    research = { "battery" },                  -- research.grant ids (research.lua TECH)
    contracts = false, programme = false,      -- the Ops Board and the programme stand down
    weather = "calm",
    crew = {
      -- the first `control = true` member is the one you play; starters are
      -- renamed to these names and given these roles; more are hired free
      { name = "Okafor", role = "engineer", control = true,
        where = { body = "home", site = "near_base", dist = 80, offset = { 0, 0, 0 } },
        -- site: base | near_base (dist m from the spaceport) | far_flat_lit | far_flat | "lat:12.5,lon:-40"
        pack = { { item = "repairkit" }, { part = "wall.steel", n = 2 }, { mat = "iron", kg = 10 } } },
    },
    marks = {                                  -- named points the steps and beats refer to
      shelter = { at = "crew:Okafor", offset = { 12, 0, 0 } },   -- offset = { right, up, front } m; up 0 = on the ground
    },
    structures = {                             -- SOLBP1 codes in files (the Build Kit's BLUEPRINTS tab, or Shift+F12)
      -- { bp = "my_scenario/shell.bp.txt", name = "Shelter", at = "mark:shelter", offset = { 0, 0, 0 }, yaw = 90 },
    },
    -- (F8, docs/scenarios.md §5.9) a blueprint stamped as an abandoned ruin, decayed by its author:
    -- gone / knocked / broken are piece uids (blueprint lines); lots are the restore bill's jobs at your prices
    ruins = {
      -- { name = "Old Camp", bp = "my_scenario/camp.bp.txt", at = "mark:shelter", age = 3000, decay = 0.5,
      --   gone = { 12, 13 }, knocked = { 40 }, broken = { 7 }, lots = { { id = "roof", name = "the roof", uids = { 12, 13 }, price = 900 } },
      --   lore = { "the terminal's LOG lines" } },
    },
    -- (F8) Data Cores in pieces: on a console, its CORE page; elsewhere E on the piece (plates, the date as the header)
    cores = {
      -- { id = "c1", struct = "Old Camp", uid = 30, who = "chief", title = "THE CHIEF'S LOG", power = false, air = false,
      --   needs = { kind = "piece_ok", struct = "Old Camp", uid = 40 }, why = "the words when it cannot be read",
      --   run = "after_c1", open = nil, pages = { { date = "Day 211 · 06:40", text = "…" } } },
    },
    crates = {                                 -- a "Supply drop" crate (salvage.lua) with crated parts
      -- { at = "crew:Okafor", offset = { 4, 0, 2 }, parts = { ["wall.steel"] = 6 }, items = { repairkit = 1 } },
    },
    -- S6 (docs/scenarios.md §3.1, §6.1): pieces that hold things, keypads, log cards, base-log lines
    -- tags = { { struct = "Shelter", part = "lightFitting", name = "L-1" } },
    -- datalogs = { note = { title = "Shift note", who = "M. Okafor", when = "23:40",
    --                       lines = { "Locker code below.", "Locker: 2580" }, codes = { { struct = "Shelter", part = "locker" } } } },
    -- containers = { { struct = "Shelter", part = "shelf", items = { ration = 2, ["datalog:note"] = 1 }, parts = { ["lightFitting.steel"] = 1 }, mats = { iron = 4 } } },
    -- locks = { { struct = "Shelter", part = "locker", code = "2580" } },     -- a door or a container; open = true: fitted but open
    -- logs = { { struct = "Shelter", when = "06:10", who = "M. Okafor", text = "Scrubber cartridge changed." } },
    flags = {}, survey = {},
    craft = {
      -- { file = "my_scenario/lander.json", name = "Kestrel", where = { pad = true } }
      -- where: pad | runway | orbit = { body = "moon", alt = 12000, e = 0, inc = 0 }
      --        | ground = ref, offset, face = ref, charge = 0..1 (far from the pad: rebuilt the right way up there)
    },
  },

  on_start = { { ops = "We're live. Take it slow." } },
  -- story beats (docs/scenarios.md §5.1): say = { who, text, with = "<listener>" },
  -- walk = { who, to = ref }, look = { who, at = ref | false }, face = { who,
  -- emotion }, light = { ambient, fog, time, secs }, weather = { kind, secs },
  -- breaker = { struct, part, closed }, wear = { craft, part, hp }, music = "audio/music/x.ogg" | false
  -- S6: tag = { struct, part, name }, log = { struct, text, who }, container = { struct, part, items, mats, clear },
  -- lock = { struct, part, code = "1234" | false, open }, terminal = { struct, page = "LOG" | close = true }
  -- SC-5: drive = { craft, follow = "craft:<name>", speed, gap } | { craft, to = ref, speed, r } | { craft, stop = true }
  -- (a crew member seated aboard drives it), board = { who, craft, seat = uid } | { who, craft = false },
  -- place = { craft | who, at = ref } (a checkpoint's stage), charge = { craft, frac }, give = { craft, item, n }

  steps = {
    { id = "walk", text = "Walk to the marker.",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:shelter", r = 6 } },
      mark = "mark:shelter",                   -- the card's bearing and the world marker
      hint = "The amber marker. W to walk.",   -- after 90 s with no progress (or the HINT button)
      on_done = { { ops = "Good." } } },
    -- { id = "seal", text = "Close the shell.", goals = { { kind = "rooms", struct = "Shelter", sealed = 1 } },
    --   teach = { overlay = "ROOMS", catalogue = "WALL", ghost = "my_scenario/ghost.bp.txt", at = "mark:shelter" },
    --   checkpoint = true, act = "Act 2 · the shell", stage = { structures = { … } } },   -- a setback comes back here
    -- optional = true: counts for nothing, blocks nothing; parallel = "jobs": open together
    -- S6 goals: { kind = "looted", struct, part, item, n }, { kind = "has_item", who, item | mat, n },
    --   { kind = "part_state", struct, part, key = "locked", is = false }, { kind = "switched", struct, part, on = true },
    --   { kind = "terminal", read = "note" } (a log card read)
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Okafor did not make it." },
  },
  on_fail = {},

  score = { par = 300, budget = { funds = 9000 },
            medals = { gold = { time = 1.0, hints = 0 }, silver = { time = 1.5 }, bronze = "done" } },
  after = "freeplay",            -- CONTINUE keeps playing here; "menu" returns
  freeplay = { contracts = true, programme = true },
  debrief = { gold = "Gold line.", silver = "Silver line.", bronze = "Bronze line.", fail = "Fail line." },
}
