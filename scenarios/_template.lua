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
    crates = {                                 -- a "Supply drop" crate (salvage.lua) with crated parts
      -- { at = "crew:Okafor", offset = { 4, 0, 2 }, parts = { ["wall.steel"] = 6 }, items = { repairkit = 1 } },
    },
    flags = {}, survey = {},
    craft = {
      -- { file = "my_scenario/lander.json", name = "Kestrel", where = { pad = true } }
      -- where: pad | runway | orbit = { body = "moon", alt = 12000, e = 0, inc = 0 }
    },
  },

  on_start = { { ops = "We're live. Take it slow." } },

  steps = {
    { id = "walk", text = "Walk to the marker.",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:shelter", r = 6 } },
      mark = "mark:shelter",                   -- the card's bearing and the world marker
      hint = "The amber marker. W to walk.",   -- after 90 s with no progress (or the HINT button)
      on_done = { { ops = "Good." } } },
    -- { id = "seal", text = "Close the shell.", goals = { { kind = "rooms", struct = "Shelter", sealed = 1 } },
    --   teach = { overlay = "ROOMS", catalogue = "WALL", ghost = "my_scenario/ghost.bp.txt", at = "mark:shelter" },
    --   checkpoint = true, stage = { structures = { … } } },   -- RETRY restages from here
    -- optional = true: counts for nothing, blocks nothing; parallel = "jobs": open together
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
