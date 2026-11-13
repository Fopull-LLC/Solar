-- HARD VACUUM — an EVA hull patch on a transit freighter (work/scenarios2
-- PLAN §1.7, §3 SC-8; docs/scenarios.md).
--
-- The freighter Ansel, three days into a six-day coast to Kessel, two crew.
-- Everything here is the game's own: the craft is a VAB blueprint
-- (ansel.json, built by tools/perf/vacprobe.sh anselbuild) with three cabin
-- modules joined by two docking-port hatches (G1 cabin air,
-- docs/crew-and-items.md §13); the hole is a part worn to hp 0.38, so
-- damage.holeArea gives it 7 cm² and the stores' regulator feeds its two
-- bottles straight out of it (the clock); the hiss is cabin_air's recorded
-- leak, a 3D sound on that can; the dose is the Ember's real cone past the
-- shadow shield (vessel_thermal's dose pass); the EVA is the RCS pack and
-- HOLD; the patch is the Repair Kit's "Patch the leak" row.
--
--   uids: 4 the Ember · 9 the shadow shield · 10-11 the stores (10 is hit)
--         12-13 hatch B · 14 the hab (Mira) · 15-16 hatch A · 17 the flight
--         deck (Ewan)
--
--   ACT 1  the strike: a grain of something at eleven kilometres a second
--   ACT 2  isolate: hatch B dogged, the stores on its own bottles
--   ACT 3  outside: the hab vents, the hull, the hiss, the shadow, the patch
--   ACT 4  home: the hab comes back from its bottles, the stores, the choice
--
-- No hooks. The full dialogue for reading is work/scn_vacuum/SCRIPT.md.
return {
  id = "hard_vacuum", title = "Hard Vacuum", v = 1, order = 30, minutes = 20,
  teaches = { "cabin air", "eva", "repair", "dose" },
  blurb = "Three days out on the freighter Ansel, something small and fast goes through the stores can. Find the hole by its sound, patch it from outside, and keep out of the reactor's way.",
  brief = {
    "The Ansel: a nuclear freighter on the long coast to Kessel. Reactor at the back, cargo spine, three cans of crew space up front.",
    "Two of you aboard. Ewan Pryce flies her. You are Mira Castellanos: cargo, air, and anything that leaks.",
  },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },

  cast = {
    mira  = { name = "Mira Castellanos", tag = "ENGINEER · THE HAB", crew = "Castellanos", color = { 0.86, 0.88, 0.95 }, portrait = "auto" },
    ewan  = { name = "Ewan Pryce", tag = "PILOT · FLIGHT DECK", crew = "Pryce", color = { 1.0, 0.78, 0.45 }, portrait = "auto", radio = true },
    ansel = { name = "Ansel", tag = "TERMINAL · CAUTION PANEL", color = { 1.0, 0.70, 0.25 } },
  },

  vars = { struck = false, briefed = false, core = "up", decided = false, choice = "", debriefed = false,
           dose_msv = 0, stores_res = 100, res_at_patch = 100, stores_p = 1, t_patch = 0 },

  -- the numbers the story watches, as data (docs/scenarios.md §4.2)
  meters = {
    { var = "dose_msv", read = "dose.msv", who = "Castellanos", delta = true, round = 0.1 },
    { var = "stores_res", read = "cabin.res", craft = "Ansel", module = "#10", scale = 100, round = 1 },
    { var = "stores_p", read = "cabin.p", craft = "Ansel", module = "#10", round = 0.01 },
    -- what was left in the stores' bottles when the patch went on
    { var = "res_at_patch", read = "cabin.res", craft = "Ansel", module = "#10", scale = 100, round = 1,
      when = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 } },
  },
  models = {
    -- seconds from the strike to the patch
    { var = "t_patch", start = 0, rate = 1,
      active = { kind = "var", name = "struck", is = true },
      when = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 } },
  },
  failure = "checkpoint",

  start = {
    funds = 0, rp = 0, safety = "death",
    research = { "ember", "radPanel", "shadowShield", "dockPort", "cargo", "dish", "engineM", "tankM" },
    contracts = false, programme = false, ruins = false,
    crew = {
      { name = "Castellanos", role = "engineer", title = "Engineer · cargo and air", control = true,
        pack = { { item = "repairkit" }, { item = "rcspack" } } },
      { name = "Pryce", role = "pilot", title = "Pilot · flight deck" },
    },
    -- the freighter on a circular orbit; Ewan on the flight deck, Mira in the hab
    craft = {
      { file = "hard_vacuum/ansel.json", name = "Ansel", where = { orbit = { body = "home", alt = 1200, e = 0, inc = 0.3 } },
        crew = { { who = "Pryce", uid = 17, slot = 1 }, { who = "Castellanos", uid = 14, slot = 1 } } },
    },
  },

  on_start = { { run = "strike" } },

  sequences = {
    -- ── ACT 1 ──────────────────────────────────────────────────────────────
    strike = {
      { cutscene = true },
      { shot = { orbit = "craft:Ansel@14", dist = 26, height = 5, turn = 35, secs = 9, wait = false } },
      { caption = { "HARD VACUUM", "Freighter Ansel · day 3 of 6 · the coast to Kessel", 6 } },
      { wait = 3 },
      { say = { who = "ewan", text = "Come on. Hold that. Hold that for me, old girl." } },
      { say = { who = "mira", text = "She can't hear you, Ewan. She's a can of propellant with a reactor on the end." } },
      { say = { who = "ewan", text = "She hears me fine. She just doesn't listen. You two have that in common." } },
      { shot = { from = "craft:Ansel@11", look = "craft:Ansel@10", offset = { 3, 1.2, 2.5 }, secs = 5, wait = false } },
      { wait = 1.2 },
      { sound = "audio/foley/steel_drop.ogg" },
      { wait = 0.6 },
    },
    -- (the hole goes in as the cutscene ends: the DEPRESSURISATION banner and
    -- the cabin gauge are the player's to see, and a cutscene hides them)
    brief = {
      { wear = { craft = "Ansel", uid = 10, hp = 0.38 } },
      { var = { struck = true } },
      { say = { who = "ewan", text = "What was that. Ansel, what was that." } },
      { say = { who = "ansel", text = "CAUTION  CABIN PRESSURE  STORES  0.97 ATM FALLING  ·  REGULATOR FEEDING" } },
      { say = { who = "mira", text = "That was a rock. Something the size of a grain of rice doing eleven kilometres a second." } },
      { say = { who = "ewan", text = "Stores can's leaking. All three cans are open to it, so the whole ship is feeding the hole." } },
      { say = { who = "ewan", text = "Hatch B. The one between you and the stores. Dog it, before it takes the hab down with it." } },
      { say = { who = "mira", text = "Dogging B. Tell me something reassuring." } },
      { say = { who = "ewan", text = "It's a small hole. Ansel, it's a small hole. You hear that? Small." } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    isolated = {
      { sound = "audio/foley/latch_clunk.ogg" },
      { say = { who = "ewan", text = "B's dogged. Hab and the deck are holding. Stores is on its own now." } },
      { say = { who = "ewan", text = "It's got two bottles on its regulator, and the regulator's doing its job. It's feeding them straight out the hole." } },
      { say = { who = "mira", text = "So that's the clock." } },
      { say = { who = "ewan", text = "That's the clock. Eight minutes of bottle, give or take. After that it just bleeds down." } },
    },
    -- ── ACT 3 ──────────────────────────────────────────────────────────────
    eva_brief = {
      { say = { who = "ewan", text = "No airlock on this bucket. You go out the hab's side hatch and the hab goes with you. Its own bottles bring it back after." } },
      { say = { who = "ewan", text = "I'm dogging A. If you're going to breathe vacuum, I'm not doing it with you." } },
      { state = { craft = "Ansel", uid = 16, st = { ph = "sealed" } } },
      { sound = "audio/foley/latch_clunk.ogg" },
      { say = { who = "ewan", text = "The hole's somewhere on the stores. Two cans below B. You'll hear it before you see it, while there's still air to hear." } },
      { say = { who = "ewan", text = "And Mira. The stores sits right on top of the shield. Up there its shadow is about a metre wide." } },
      { say = { who = "ewan", text = "Keep tight to the hull. Drift out of the shadow and you're standing in front of the core." } },
      { say = { who = "mira", text = "Tight to the hull. Got it." } },
      { choice = { who = "ewan", prompt = "I can take the Ember down while you're out there.",
        options = {
          { text = "Take her down to ten per cent.", var = { core = "ten" }, run = "core_ten" },
          { text = "Scram it. All the way down.", var = { core = "scram" }, run = "core_scram" },
          { text = "Leave her. I'll be quick.", var = { core = "up" }, run = "core_up" },
        }, default = 1, timeout = 45 } },
      { say = { who = "ewan", text = "Helmet's on? Pack's on? Repair Kit in your hand, not in your pocket. Go." } },
      { var = { briefed = true } },
    },
    core_ten = {
      { state = { craft = "Ansel", uid = 4, st = { output = 10 } } },
      { say = { who = "ewan", text = "Ten per cent. Radiators will cold-soak and she'll sulk for an hour when I bring her back. Worth it." } },
    },
    core_scram = {
      { state = { craft = "Ansel", uid = 4, st = { critical = false } } },
      { say = { who = "ewan", text = "Rods in. She's scrammed. She won't restart until she's cooled off, so we're on batteries till then. Don't dawdle." } },
    },
    core_up = {
      { say = { who = "ewan", text = "Quick. Right. Your dosimeter, your quarter." } },
    },
    -- (scnfix2, Ty 2026-11-12b: "I just go outside and the rest completes
    -- itself") the hole is found by its cues, not handed over: the hiss
    -- louder as you close on it (cabin_air's leak loop on the holed can),
    -- the plume of freezing air off its face (cabin_air JET), and the can's
    -- own LEAK row on its menu. Ewan gives the side of the ship, nothing more.
    outside = {
      { say = { who = "ewan", text = "Hab's open. I've got you on the suit camera. Don't wave." } },
      { say = { who = "mira", text = "I wasn't going to." } },
      { state = { craft = "Ansel", uid = 14, st = { creg = "off" } } },
      { say = { who = "ewan", text = "I've shut the hab's regulator, or its bottles follow you out the door. It's yours to turn back on when you're in." } },
      { say = { who = "ewan", text = "X holds you on the ship. Stores is aft of you, past B. I can't see the hole from here. Listen for it, and watch for frost coming off the hull." } },
    },
    found = {
      { say = { who = "mira", text = "Here. It's this can. I can feel it through my gloves, and there's frost coming off it." } },
      { say = { who = "ewan", text = "I see the plume on the camera. That's your hole." } },
    },
    patched = {
      { sound = "audio/foley/hiss_seal.ogg" },
      { say = { who = "mira", text = "Patch is on. Holding. The hiss has stopped." } },
      { say = { who = "ewan", text = "That's in. That's... Mira. That's in. Come home." } },
      { branch = { var = "res_at_patch", lt = 5,
        beats = { { say = { who = "ewan", text = "Stores bottles are dry, so it stays at nothing till we feed it from the hab. Later. Come in first." } } },
        elseBeats = { { say = { who = "ewan", text = "Stores regulator's bringing it back up on what's left in its bottles. Come in." } } } } },
    },
    -- ── ACT 4 ──────────────────────────────────────────────────────────────
    home = {
      { say = { who = "ewan", text = "Hab's sealed and climbing. Helmet stays on until it's green, Castellanos. I mean it." } },
      { branch = { var = "core", eq = "ten",
        beats = { { state = { craft = "Ansel", uid = 4, st = { output = 40 } } },
                  { say = { who = "ewan", text = "Bringing the Ember back to forty. Come on, girl. Slowly." } } } } },
      { branch = { var = "core", eq = "scram",
        beats = { { state = { craft = "Ansel", uid = 4, st = { critical = true } } },
                  { say = { who = "ewan", text = "Trying a restart. If she says no, she's still too warm, and we sit on batteries until she says yes." } } } } },
      { say = { who = "ewan", text = "Stores next. Crack B on its valve, let the hab bleed into it, then open it. Slowly. I've had enough noises for one day." } },
    },
    decide = {
      { say = { who = "ewan", text = "Here's the sum. Kessel's three days on. Home's three days back, and a burn we don't have the margin for twice." } },
      { say = { who = "ewan", text = "We've got what's left in the bottles and a patch on the stores that's rated for the yard, not for three more days of this." } },
      { say = { who = "mira", text = "And the cargo?" } },
      { say = { who = "ewan", text = "The cargo doesn't breathe. Your call, you're the one who's been outside." } },
      { choice = { who = "ewan", prompt = "Kessel, or home?",
        options = {
          { text = "Kessel. The patch will hold. I'll check it every watch.", var = { choice = "on", decided = true } },
          { text = "Home. We turn round and we nurse her back.", var = { choice = "back", decided = true } },
        }, default = 1, timeout = 60 } },
    },
    resolution = {
      { cutscene = true },
      { shot = { orbit = "craft:Ansel@11", dist = 16, height = 3, turn = 50, secs = 12, wait = false } },
      { branch = { var = "choice", eq = "on",
        beats = { { say = { who = "ewan", text = "Kessel it is. Ansel, you heard her. Three more days. Behave." } } },
        elseBeats = { { say = { who = "ewan", text = "Turning round. Ansel, we're going home. Don't make me regret it." } } } } },
      { branch = { var = "dose_msv", gt = 20,
        beats = { { say = { who = "ewan", text = "Your badge says you stood in front of the core longer than you should. I'm logging it. Medical will want words." } } },
        elseBeats = { { say = { who = "ewan", text = "Your badge barely moved. You stayed in the shadow. I watched you do it." } } } } },
      { branch = { var = "res_at_patch", lt = 25,
        beats = { { say = { who = "mira", text = "The stores bottles went out the hole. That's air we'll want on day six." } } },
        elseBeats = { { say = { who = "mira", text = "We kept most of the stores bottles. That's day six sorted." } } } } },
      -- (her brother pressed a hub bearing back in with a rock: Thirty Kilometres)
      { say = { who = "mira", text = "My brother once fixed a wheel hub with a rock and called it a repair. He's hearing about this patch for the rest of his life." } },
      { shot = { orbit = "craft:Ansel@17", dist = 10, height = 2.5, turn = 45, start = 160, secs = 14, wait = false } },
      { say = { who = "mira", text = "You talked to me, you know. Out there. Not to her. To me." } },
      { say = { who = "ewan", text = "Don't tell her. She gets jealous." } },
      { var = { debriefed = true } },
    },
  },

  events = {
    -- the clock: the stores' bottles
    { id = "res50", when = { kind = "var", name = "stores_res", lt = 50 }, after = "isolate", also = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 },
      beats = { { say = { who = "ewan", text = "Stores bottles at half." } } } },
    { id = "res20", when = { kind = "var", name = "stores_res", lt = 20 }, after = "isolate", also = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 },
      beats = { { say = { who = "ewan", text = "Bottles at twenty. When they're gone it stops hissing, and then you're looking for a hole with your eyes." } } } },
    { id = "res0", when = { kind = "var", name = "stores_res", lt = 2 }, after = "isolate", also = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 },
      beats = { { say = { who = "ewan", text = "Bottles are dry. It's bleeding down on its own now." } } } },
    { id = "quiet", when = { kind = "var", name = "stores_p", lt = 0.05 }, after = "isolate", also = { kind = "part_hp", craft = "Ansel", uid = 10, below = 0.5 },
      beats = { { say = { who = "mira", text = "It's stopped. I can't hear it any more." } },
                { say = { who = "ewan", text = "Then the can's empty. The hole's still there. Look for the frost round it, on the aft can." } } } },
    -- the badge
    { id = "dose5", when = { kind = "var", name = "dose_msv", gt = 5 }, after = "plan",
      beats = { { say = { who = "ewan", text = "Your badge is climbing. You're out of the shadow. Tighter to the hull." } } } },
    { id = "dose20", when = { kind = "var", name = "dose_msv", gt = 20 }, after = "plan",
      beats = { { say = { who = "ewan", text = "Twenty millisieverts. That's your quarter, Mira. Whatever you're doing, do it faster." } } } },
    { id = "dose60", when = { kind = "var", name = "dose_msv", gt = 60 }, after = "plan",
      beats = { { say = { who = "ewan", text = "Sixty. Patch or no patch, get inside. Please." } } } },
  },

  steps = {
    -- ACT 1: the strike
    { id = "listen", text = "Something hit the ship. Hear Ewan out.", act = "Act 1 · the strike", run = "brief",
      goals = { { kind = "var", name = "struck", is = true, label = "The strike" } },
      hint = "Let the lines run (Enter skips one). The DEPRESSURISATION banner and the cabin gauge (top right) say what the air is doing." },
    { id = "isolate", text = "Dog hatch B, between the hab and the stores.", act = "Act 2 · isolate", checkpoint = true,
      stage = { beats = { { wear = { craft = "Ansel", uid = 10, hp = 0.38 } }, { var = { struck = true } } } },
      goals = { { kind = "cabin", craft = "Ansel", module = "#14", sealed = true, label = "Hab and flight deck holding" } },
      hint = "Hatch B is the docking-port pair just below your can (the hab). Right-click it from your seat: Seal the hatch.",
      hint2 = "Either half of the pair will do: a docking hatch is only as open as its tighter side.",
      on_done = { { run = "isolated" } } },
    -- ACT 3: outside
    { id = "plan", text = "Ewan has the plan. Hear him out.", act = "Act 3 · outside", checkpoint = true, run = "eva_brief",
      stage = { beats = { { wear = { craft = "Ansel", uid = 10, hp = 0.38 } }, { var = { struck = true } },
                          { state = { craft = "Ansel", uid = 13, st = { ph = "sealed" } } } } },
      goals = { { kind = "var", name = "briefed", is = true, label = "The plan" } },
      hint = "Listen to Ewan; pick the reactor's setting with the number keys when he asks." },
    { id = "out", text = "Out through the hab's side hatch.",
      goals = { { kind = "helmet", who = "crew:Castellanos", off = false, label = "Outside, helmet on" } },
      hint = "From your seat press F (EVA): the hab's hatch opens and its air goes. The RCS pack is on your back: WASD, Space and Ctrl to move, X to HOLD still against the ship.",
      on_done = { { run = "outside" } } },
    { id = "find", text = "Find the hole: listen for the hiss, look for frost venting off the hull.",
      goals = { { kind = "at", who = "crew:Castellanos", at = "craft:Ansel@10", r = 1.8, hold = 2, label = "At the hole" } },
      hint = "The stores is the two cans aft of hatch B. The hiss gets louder as you close on the hole; while it still has air, a plume of frost comes off it. Right-click a can: the holed one shows a LEAK row.",
      hint2 = "It's the aft can, the one standing on the shadow shield. Go round it: the plume comes off one face.",
      on_done = { { run = "found" } } },
    { id = "patch", text = "Patch it: the Repair Kit in hand, right-click the can, Patch the leak.", mark = "craft:Ansel@10",
      goals = { { kind = "part_hp", craft = "Ansel", uid = 10, above = 0.5, label = "The hole patched" } },
      hint = "Hold the Repair Kit (its belt key), slow down (X), and right-click the aft stores can: Patch the leak. Stay put until it finishes.",
      hint2 = "If the dose chip is climbing, you're out of the shield's shadow: come in closer to the can's surface.",
      on_done = { { run = "patched" } } },
    -- ACT 4: home
    { id = "home", text = "Back in through the hab's hatch, then turn its air regulator back on.", act = "Act 4 · home", checkpoint = true,
      stage = { beats = { { wear = { craft = "Ansel", uid = 10, hp = 0.55 } }, { var = { struck = true, briefed = true } },
                          { state = { craft = "Ansel", uid = 13, st = { ph = "sealed" } } },
                          { state = { craft = "Ansel", uid = 16, st = { ph = "sealed" } } },
                          { state = { craft = "Ansel", uid = 14, st = { creg = "off" } } } } },
      -- (scnfix2) the air comes back when you put it back: Ewan shut the
      -- hab's regulator for the EVA, and with it off nothing refills the can
      goals = { { kind = "cabin", craft = "Ansel", module = "#14", breathable = true, p = 0.9, label = "The hab breathable again" } },
      waitLabel = "The hab's bottles filling it",      -- (scnfix) the wait bar, only once the air is climbing
      hint = "Fly back to the hab, the can between hatch A and hatch B, and press F at its side hatch to board. Then right-click the hab (your can): Air regulator, AUTO. The gauge (top right) shows the air climb.",
      hint2 = "Boarding seals the hatch, but the regulator Ewan shut stays shut: nothing refills the hab until you turn it back on.",
      on_done = { { run = "home" } } },
    { id = "stores", text = "Bring the stores back over 0.85 atm: its own bottles, or the hab's through hatch B.",
      goals = { { kind = "cabin", craft = "Ansel", module = "#10", p = 0.85, label = "Stores back over 0.85 atm" } },
      waitLabel = "The stores filling",                -- (scnfix) shown only while the air is coming up
      hint = "If the stores' bottles held, its regulator brings it back on its own. If they ran dry, right-click hatch B: \"Shut it, valve open (equalise)\", and when both sides read the same, Open the hatch.",
      hint2 = "Opening hatch B straight away works too: the hab drops while the stores fills." },
    { id = "decide", text = "Kessel, or home.", run = "decide",
      goals = { { kind = "var", name = "decided", is = true, label = "The call" } },
      hint = "Ewan wants your answer: the number keys." },
    { id = "end", text = "Day three.", run = "resolution",
      goals = { { kind = "var", name = "debriefed", is = true, label = "The coast" } },
      hint = "Nothing left to do. Let them talk." },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "The Ansel lost a crew member three days from anywhere.",
      hint = "Outside, stay on the shaded side of the core and keep an eye on the suit's air: the walk aft is longer than it looks." },
    { kind = "craft_pressure", craft = "Ansel", module = "#17", below = 0.5, secs = 60, text = "The flight deck lost its air with Ewan in it.",
      hint = "Dog hatch B first, before anything else: the hole is aft, and every second it is open the whole ship breathes out of it." },
  },

  score = {
    par = 720,     -- (the solve plays it in 3:31 of game time, clicking every line through; a player reading them, ~12 min)
    rows = {
      { label = "Strike to patch", var = "t_patch", fmt = "%.0f s", par = "≤ 360 s", lte = 360 },
      { label = "Your dose", var = "dose_msv", fmt = "%.1f mSv", par = "≤ 20 mSv", lte = 20 },
      { label = "Stores bottles left at the patch", var = "res_at_patch", fmt = "%.0f %%", par = "≥ 25 %", gte = 25 },
    },
    medals = {
      gold = { time = 1.5, vars = { t_patch = { lte = 360 }, dose_msv = { lte = 20 }, res_at_patch = { gte = 25 } } },
      silver = { time = 2.5, vars = { dose_msv = { lte = 100 } } },
      bronze = "done",
    },
  },
  after = "freeplay",
  freeplay = { contracts = false, programme = false },
  debrief = {
    gold = "A clean patch, fast, in the shadow, with air to spare. Ewan logged it in one line and then sat looking at the line for a while.",
    silver = "The hole is patched and everyone is breathing. Some of it cost more than it needed to. Read your badge before the next watch.",
    bronze = "The Ansel is holding air. It was close in ways you will think about on day six.",
    fail = "The Ansel coasts on toward Kessel with nobody to answer her.",
  },
}
