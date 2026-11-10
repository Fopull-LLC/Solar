-- THE STORY PROBE (v2 framework test, and a small worked example of the
-- story features: docs/scenarios.md §5). A folder scenario
-- (scenarios/_story/scenario.lua), never listed. A cast with a voice off the
-- roster, a variable set by a choice, a cutscene with an orbit, a dolly and a
-- crew walk, a fault on a timer (knock), an event on a variable, a branch,
-- a goto and a hook goal. Played by tests/smoke_scenarios.lua and
-- tools/perf/scnprobe.sh (BENCH_STRS='("scn", "_story")').
return {
  id = "_story", title = "Story Probe", v = 1, order = 998,
  teaches = { "dialogue", "cutscenes", "events" },
  blurb = "The story features, end to end.",
  brief = { "Night shift at the hut. The light keeps failing.", "Hale has the plant; you have the hut." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  cast = {
    hale = { name = "Dr. Hale", tag = "SITE CHIEF", color = { 1.0, 0.78, 0.45 } },
    okafor = { name = "Dele Okafor", tag = "ENGINEER", crew = "Okafor" },
  },
  vars = { trust = 0 },
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
      ridge = { at = "crew:Okafor", offset = { 20, 0, -20 } },
    },
    structures = { { bp = "_story/hut.bp.txt", name = "Story Hut", at = "mark:hut", yaw = 0, air = true } },
  },
  sequences = {
    intro = {
      { cutscene = true },
      { shot = { orbit = "struct:Story Hut", dist = 22, height = 8, turn = 50, secs = 4, wait = false } },
      { say = { who = "hale", text = "That light has failed three nights running." } },
      { walk = { who = "Reyes", to = "mark:ridge", secs = 6 } },
      { shot = { from = "mark:ridge", to = "mark:door", look = "struct:Story Hut", secs = 3 } },
      { say = { who = "okafor", text = "I'll look at it." } },
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
      { shot = { look = "struct:Story Hut", secs = 2 } },
      { say = { who = "hale", text = "And there it goes again." } },
      { alarm = false },
    },
  },
  events = {
    { id = "fault", when = { kind = "timer", secs = 3, from = "step:walk" }, run = "fault" },
    { id = "grumble", when = { kind = "var", name = "trust", lt = 0 }, beats = { { say = { who = "hale", text = "Fine. After." } } } },
  },
  on_start = { { run = "intro" }, { run = "ask" } },
  steps = {
    { id = "walk", text = "Walk to the hut's door.", mark = "mark:door",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:door", r = 4 } } },
    { id = "fix", text = "The light is out. Repair it.",
      goals = { { kind = "piece_ok", struct = "Story Hut", part = "lightFitting" }, { kind = "hook", fn = "faultSeen" } },
      on_done = { { say = { who = "hale", text = "Lit. Thank you." } }, { done = true } } },
    { id = "late", text = "The shift is over.", goals = { { kind = "var", name = "trust", lt = 0 } } },
  },
  fail = { { kind = "crew_dead", any = true, text = "Okafor did not make it." } },
  score = { par = 120, medals = { gold = { time = 1.0 }, silver = { time = 2.0 }, bronze = "done" } },
  after = "freeplay",
  debrief = { gold = "Lit.", silver = "Lit, eventually.", bronze = "Lit.", fail = "Dark." },
}
