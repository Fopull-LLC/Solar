-- THE FRAMEWORK'S OWN TEST SCENARIO (tools/perf/scnprobe.sh, tests/smoke_scenarios.lua).
-- Never listed on the menu (the "_" prefix). It stages one of everything the
-- framework stages on the home world near the spaceport and walks the step
-- machine: an `at` step, an optional room reading, a timed hold, a mark beat,
-- a camera beat and a medal. scenarios/_probe/solve.lua plays it.
return {
  id = "_probe", title = "Framework Probe", v = 1, order = 999,
  teaches = { "framework" },
  blurb = "The scenario framework's own test.",
  brief = { "Probe run. Nothing here is real.", "Walk to the post, wait, done." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  start = {
    funds = 7000, rp = 5, safety = "rescue",
    research = { "battery", "tankM" },
    contracts = false, programme = false, weather = "calm",
    crew = {
      { name = "Okafor", role = "engineer", control = true,
        where = { body = "home", site = "near_base", dist = 120 },
        pack = { { item = "repairkit" }, { part = "wall.steel", n = 1 } } },
      { name = "Reyes", role = "pilot", where = { body = "home", site = "near_base", dist = 120, offset = { 3, 0, 0 } } },
    },
    marks = {
      post = { at = "crew:Okafor", offset = { 0, 0, 25 } },
      hut = { at = "crew:Okafor", offset = { -14, 0, 6 } },
    },
    structures = {
      { bp = "_probe/hut.bp.txt", name = "Probe Hut", at = "mark:hut", yaw = 30 },
    },
    crates = {
      { at = "crew:Okafor", offset = { 4, 0, 2 }, parts = { ["wall.steel"] = 2 }, items = { repairkit = 1 }, name = "Probe drop" },
    },
    flags = { { at = "crew:Okafor", offset = { -4, 0, -3 }, name = "Probe flag" } },
  },
  on_start = { { ops = "Probe live." }, { say = { who = "Reyes", text = "I'm here too." } } },
  steps = {
    { id = "walk", text = "Walk to the post.",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:post", r = 5 } },
      mark = "mark:post", hint = "The marker, 25 m north.",
      on_done = { { ops = "At the post." }, { mark = { name = "beyond", at = "mark:post", offset = { 0, 0, 10 }, show = true } } } },
    { id = "hut", optional = true, text = "(optional) The hut reads as a sealed room.",
      goals = { { kind = "rooms", struct = "Probe Hut", sealed = 1 } } },
    { id = "wait", text = "Stand there for five seconds.",
      goals = { { kind = "at", who = "crew:Okafor", at = "mark:post", r = 8, hold = 5 } },
      teach = { at = "mark:hut", marker = true },
      on_done = { { caption = { "PROBE", "Stood still.", 3 } },
                  { camera = { orbit = "struct:Probe Hut", dist = 16, secs = 4 } },
                  { ops = "Camera done." } } },
    { id = "flag", text = "The flag is up.", goals = { { kind = "flag_on", body = "home" } } },
  },
  fail = {
    { kind = "crew_dead", any = true, text = "Okafor did not make it." },
    { kind = "timer", secs = 3600, text = "An hour went by." },
  },
  score = { par = 120, budget = { funds = 7000 },
            medals = { gold = { time = 1.0, hints = 0 }, silver = { time = 2.0 }, bronze = "done" } },
  after = "freeplay",
  freeplay = { contracts = true, programme = true },
  debrief = { gold = "Probe gold.", silver = "Probe silver.", bronze = "Probe bronze.", fail = "Probe failed." },
}
