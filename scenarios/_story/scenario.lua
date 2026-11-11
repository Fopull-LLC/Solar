-- THE STORY PROBE (the framework's test, and a small worked example of the
-- story features: docs/scenarios.md §4–§6). A folder scenario
-- (scenarios/_story/scenario.lua), never listed. Played by
-- tests/smoke_scenarios.lua and tools/perf/scnprobe.sh (_story).
--
--   v2  a cast with a voice off the roster, a variable set by a choice, a
--       cutscene with an orbit and a dolly, a fault on a timer (knock), an
--       event on a variable, a branch, a goto and a hook goal
--   FW-C (work/scenarios2/PLAN.md §2): a `walk` that steers Reyes's body
--       along the ground; `look` and `face`; two speakers on one plate
--       (say.with); a radio voice three seconds away (cast radio, delay);
--       the time of day held at evening (world.time); a `light` beat that
--       dims the hut's ambient while the light is out; a METER (seconds in
--       the dark, the hut's air) and a MODEL (the hut cooling while the
--       light is out, with a line when it crosses 12 °C)
--   S6 (the interaction plan §5.3; scripts/loot.lua): a log card on the
--       shelf (start.datalogs, start.containers) gives the code of the small
--       crate (start.locks) that holds the Repair Kit the fix needs; a line in
--       the hut's base log (start.logs); optional steps on `terminal read`,
--       `part_state` (locked), `has_item` and `looted`; the fix's beats paint
--       the light "L-1" (tag), leave a ration on the shelf (container), lock
--       the crate again (lock) and write the base log (log)
return {
  id = "_story", title = "Story Probe", v = 2, order = 998,
  teaches = { "dialogue", "cutscenes", "events" },
  blurb = "The story features, end to end.",
  brief = { "Evening at the hut. The light keeps failing.", "Hale has the plant; you have the hut." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth", time = { at = "evening", hold = true } },
  cast = {
    hale = { name = "Dr. Hale", tag = "SITE CHIEF", color = { 1.0, 0.78, 0.45 }, portrait = "auto", look = 1907, expression = "tired" },
    okafor = { name = "Dele Okafor", tag = "ENGINEER", crew = "Okafor", portrait = "auto" },
    reyes = { name = "Ana Reyes", tag = "PILOT", crew = "Reyes", color = { 0.62, 0.92, 0.70 }, portrait = "auto" },
    -- a voice on the radio, three seconds of light-time away: her lines are
    -- heard 3 game seconds after their beat, and the queue does not wait
    vance = { name = "Mara Vance", tag = "HARROW RELAY · RADIO", color = { 0.55, 0.85, 1.0 }, radio = true, delay = 3 },
  },
  vars = { trust = 0, dark_secs = 0, hut_c = 18 },
  hooks = "scn_story_hooks",       -- scripts/scn_story_hooks.lua on prefabs/scn_story_hooks (game scenarios only)
  start = {
    funds = 5000, safety = "rescue", contracts = false, programme = false, weather = "calm",
    crew = {
      { name = "Okafor", role = "engineer", control = true, where = { body = "home", site = "near_base", dist = 140 } },
      { name = "Reyes", role = "pilot", where = { body = "home", site = "near_base", dist = 140, offset = { 4, 0, 0 } }, post = "mark:door" },
    },
    marks = {
      hut = { at = "crew:Okafor", offset = { -10, 0, 8 } },
      door = { at = "struct:Story Hut", offset = { 1, 0, 5 } },
      ridge = { at = "crew:Okafor", offset = { 14, 0, -10 } },
    },
    structures = { { bp = "_story/hut.bp.txt", name = "Story Hut", at = "mark:hut", yaw = 0, air = true } },
    -- S6: what is in the hut, and how it is locked
    datalogs = {
      hale_note = { title = "Hale's note", who = "Dr. Hale", when = "day 212",
                    lines = { "Dele: the spare kit is in the small crate. I put it on a code after the last one walked off.",
                              "Small crate: 0417" },
                    codes = { { struct = "Story Hut", part = "crateS" } }, rp = 0 },
    },
    containers = {
      { struct = "Story Hut", part = "shelf", items = { ration = 3, ["datalog:hale_note"] = 1 }, mats = { iron = 4 } },
      { struct = "Story Hut", part = "crateS", items = { repairkit = 1, medkit = 1 } },
      { struct = "Story Hut", part = "bunk", items = { flashlight = 1 } },
    },
    locks = { { struct = "Story Hut", part = "crateS", code = "0417" } },
    logs = { { struct = "Story Hut", when = "21:10", who = "Dr. Hale", text = "Light out again. Third night running." } },
  },
  -- METERS: variables that follow a reading (no hooks)
  meters = {
    -- seconds the light has been out: the piece's knocked flag (1 or 0), integrated
    { var = "dark_secs", read = "piece.knocked", struct = "Story Hut", part = "lightFitting", mode = "integrate", round = 0.1 },
    -- the hut's oxygen share, sampled
    { var = "hut_o2", read = "room.o2", struct = "Story Hut", round = 0.01 },
    -- the coldest the hut got (the model's variable, its minimum)
    { var = "hut_min", read = "var.hut_c", mode = "min" },
  },
  -- MODELS: a number with its own law (what the systems do not simulate)
  models = {
    -- the hut cools a degree every 2.5 s with the light (and its heater) out,
    -- and settles back toward 18 °C once it is fixed; under 12 °C Hale says so
    { var = "hut_c", start = 18, rate = -0.4, rest = 18, tau = 20, min = -10, round = 0.1,
      when = { kind = "piece_state", struct = "Story Hut", part = "lightFitting", knocked = true },
      at = { { value = 12, down = true, beats = { { say = { who = "hale", text = "It's getting cold in there, Dele." } } } } } },
  },
  sequences = {
    intro = {
      { cutscene = true },
      { shot = { orbit = "struct:Story Hut", dist = 22, height = 8, turn = 50, secs = 4, wait = false } },
      { say = { who = "hale", with = "okafor", text = "That light has failed three nights running." } },
      -- Reyes walks to the ridge: her body steers there along the ground
      { walk = { who = "Reyes", to = "mark:ridge", secs = 30 } },
      { look = { who = "Reyes", at = "struct:Story Hut" } },
      { shot = { from = "mark:ridge", to = "mark:door", look = "struct:Story Hut", secs = 3 } },
      { say = { who = "okafor", with = "hale", text = "I'll look at it." } },
    },
    ask = {
      { choice = { who = "hale", prompt = "Do it now, or after the shift?",
                   options = { { text = "Now.", var = { trust = 1 }, run = "now" },
                               { text = "After the shift.", var = { trust = -1 }, step = "late" } },
                   default = 1, timeout = 20 } },
    },
    now = { { say = { who = "hale", text = "Good. Walk over." } } },
    fault = {
      { cutscene = true },
      { alarm = true },
      { knock = { struct = "Story Hut", part = "lightFitting" } },
      { hook = "markFault" },
      { light = { ambient = 0.5, secs = 1.5 } },
      { face = { who = "Reyes", emotion = "worried", secs = 6 } },
      { shot = { look = "struct:Story Hut", secs = 2 } },
      { say = { who = "hale", with = "reyes", text = "And there it goes again." } },
      { alarm = false },
    },
  },
  events = {
    { id = "fault", when = { kind = "timer", secs = 3, from = "step:walk" }, run = "fault" },
    { id = "grumble", when = { kind = "var", name = "trust", lt = 0 }, beats = { { say = { who = "hale", text = "Fine. After." } } } },
  },
  on_start = {
    { say = { who = "vance", text = "Harrow relay. I have you on the mast, Dele." } },
    { run = "intro" }, { run = "ask" },
  },
  steps = {
    -- S6: the hut's things (optional, and first: open from the start; none blocks the walk or the fix)
    { id = "note", text = "Read the note Hale left on the shelf.", optional = true,
      goals = { { kind = "terminal", read = "hale_note" } } },
    { id = "kit", text = "Open the small crate and take the Repair Kit.", optional = true,
      goals = { { kind = "part_state", struct = "Story Hut", part = "crateS", key = "locked", is = false },
                { kind = "has_item", who = "crew:Okafor", item = "repairkit" } },
      on_done = { { log = { struct = "Story Hut", who = "Okafor", text = "Took the spare kit from the small crate." } } } },
    { id = "rations", text = "Take the rations off the shelf.", optional = true,
      goals = { { kind = "looted", struct = "Story Hut", part = "shelf", item = "ration" } } },
    { id = "walk", text = "Walk to the hut's door.", mark = "mark:door",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:door", r = 4 } } },
    -- a CHECKPOINT: a setback from here comes back to the fix, the light
    -- knocked again (the restaged hut is whole; the story's `faulted` is kept)
    { id = "fix", text = "The light is out. Repair it.", checkpoint = true, act = "the fix",
      on_enter = { { branch = { var = "faulted", is = true, beats = { { knock = { struct = "Story Hut", part = "lightFitting" } } } } } },
      goals = { { kind = "piece_ok", struct = "Story Hut", part = "lightFitting" }, { kind = "hook", fn = "faultSeen" } },
      on_done = { { light = { ambient = false } }, { look = { who = "Reyes", at = false } },
                  { tag = { struct = "Story Hut", part = "lightFitting", name = "L-1" } },
                  { container = { struct = "Story Hut", part = "shelf", items = { ration = 1 } } },
                  { lock = { struct = "Story Hut", part = "crateS", open = false } },
                  { log = { struct = "Story Hut", who = "Okafor", text = "L-1 back in. Ration on the shelf for Hale." } },
                  { say = { who = "hale", with = "okafor", text = "Lit. Thank you." } },
                  { say = { who = "vance", text = "Mast sees the hut lit. Harrow out." } }, { done = true } } },
    { id = "late", text = "The shift is over.", goals = { { kind = "var", name = "trust", lt = 0 } } },
  },
  fail = { { kind = "crew_dead", any = true, text = "Okafor did not make it." } },
  score = { par = 120, medals = { gold = { time = 1.0 }, silver = { time = 2.0 }, bronze = "done" },
            rows = { { label = "In the dark", var = "dark_secs", fmt = "%.0f s", lte = 60 },
                     { label = "Coldest", var = "hut_min", fmt = "%.1f °C" } } },
  after = "freeplay",
  debrief = { gold = "Lit.", silver = "Lit, eventually.", bronze = "Lit.", fail = "Dark." },
}
