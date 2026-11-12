-- THIRTY KILOMETRES — a rover recovery at night (work/scenarios2/PLAN.md §1.3,
-- SC-5; docs/scenarios.md).
--
-- Taquo is small: 885 m to the ground, a horizon two hundred metres off, a
-- night that comes down like a lid. Asha-2 is on the far side of Barrow
-- Ridge, 1.9 km from Caird by the ridge road, with its front-left hub gone,
-- its traction cell cooked and Ray Castellanos sitting in the dirt with a leg
-- he says isn't broken and a suit seal that is leaking. Kit Nakamura has done
-- thirty kilometres on that cell since Tuesday. It is rated for twenty-five.
--
-- Everything that happens is the game's own: two rovers staged on the ground
-- (start.craft, the far one rebuilt the right way up on the far side), the
-- wreck worn by `wear` and flat by `where.charge`, Caird's beacon line
-- planted as relay beacons (start.beacons) so Ops fades exactly where the
-- line ends behind the ridge (`link` on the cast: the real comms solve),
-- the repair with Repair Kits on the real parts (the hub, the cell's
-- cradle), the spare cell out of Asha-1's locker (the item tractionCell), the
-- night and the cold front (light, weather), the convoy driven by Kit in
-- Asha-2 (the `drive` beat: vessel_controller npcDrive, re-read every tick).
-- The hooks keep only what the game has no model of: Ray's suit (a body
-- breathes nothing in the game) and a hub pressed back in by hand.
--
--   ACT 1  out: Sunniva's hand-over at the pad, the route, the drive, dusk
--          to dark, the check-ins, Caird fading behind the ridge
--   ACT 2  there: Kit, Ray, the medical, the hub, the cradle, the cell; who
--          rides where (split, crawl, or leave Asha-2)
--   ACT 3  home: the cold front, the convoy, the hub (if you push it), Ray's
--          air (if you crawl), the beacon line and Caird's voice again
--   ACT 4  Caird: what each of them says about the night
--
-- The full dialogue for reading is work/scn_30km/SCRIPT.md (script_md.lua).
return {
  id = "thirty_km", title = "Thirty Kilometres", v = 1, order = 20, minutes = 30,
  teaches = { "rover", "night driving", "repair", "convoy", "comms" },
  blurb = "Asha-2 is broken down on the far side of Barrow Ridge with a flat cell, a dead hub and a hurt engineer. Take Asha-1 out at nightfall, fix what can be fixed, and bring all four of them home before Ray's suit runs dry.",
  brief = {
    "Caird Base, Taquo, 18:52 local. The sun is going down behind the pad and it will not come back up tonight.",
    "Asha-2 is 1.9 km away on the far side of Barrow Ridge: front-left hub gone, cell cooked, Ray hurt. You have Asha-1, two Repair Kits, a spare cell in the locker and the base's only medic.",
  },
  world = { seed = 731905, scale = 4, names = 2, air = "thin", home = "alien", homeSeed = 4412,
            time = { at = "dusk", hold = true } },

  cast = {
    ops = { name = "Hester Achebe", tag = "CAIRD OPS", color = { 0.55, 0.85, 1.0 }, radio = true, link = "craft:Asha-1",
            portrait = "auto", look = 2207, expression = "focus" },
    jonah = { name = "Jonah Priestley", tag = "PILOT", crew = "Priestley", color = { 0.85, 0.88, 0.95 }, portrait = "auto" },
    sunniva = { name = "Dr Sunniva Berge", tag = "SCIENTIST · MEDIC", crew = "Berge", color = { 0.62, 0.92, 0.70 }, portrait = "auto" },
    ray = { name = "Ray Castellanos", tag = "ENGINEER · ASHA-2", crew = "Castellanos", color = { 1.0, 0.70, 0.45 }, portrait = "auto", expression = "pain" },
    kit = { name = "Kit Nakamura", tag = "SURVEYOR · ASHA-2", crew = "Nakamura", color = { 1.0, 0.86, 0.42 }, portrait = "auto", expression = "tired" },
    -- Kit on her suit radio once Asha-1 is in range of it (clear), and on
    -- Asha-2's set before that (its battery is flat: garbled, LINK LOST)
    kit_r = { name = "Kit Nakamura", tag = "SURVEYOR · SUIT RADIO", crew = "Nakamura", color = { 1.0, 0.86, 0.42 }, portrait = "auto", radio = true },
    kit_far = { name = "Kit Nakamura", tag = "ASHA-2 · RADIO", crew = "Nakamura", color = { 1.0, 0.86, 0.42 }, portrait = "auto", radio = true, link = "craft:Asha-2" },
  },

  vars = { route = "", plan = "", air_on = false, ray_air = 1380, ray_min = 1380, patched = false, kit_bottle = false,
           cell_in = false, convoy = false, hub_heat = 0, hub_failed = false, hub_fixed2 = false, dist_m = 0, a1_pct = 100,
           a1_min = 100, lamp_ec = 0, lamp_secs = 0, met_kit = false, asha2_home = false, link_lost = false,
           debriefed = false, ray_out = false },
  hooks = "scn_thirty_km_hooks",    -- scripts/scn_thirty_km_hooks.lua on its prefab

  start = {
    funds = 0, rp = 0, safety = "death", contracts = false, programme = false, ruins = false, weather = "calm",
    crew = {
      { name = "Priestley", role = "pilot", title = "Pilot · nights", control = true,
        where = { body = "home", site = "near_base", dist = 40 },
        pack = { { item = "repairkit", n = 2 }, { item = "flare", n = 3 } } },
      { name = "Berge", role = "scientist", title = "Scientist · Caird's medic",
        where = { body = "home", site = "near_base", dist = 40, offset = { 3, 0, 0 } }, post = "mark:sunniva", face = "crew:Priestley" },
      -- (the far side: 1.9 km round an 885 m world is the other side of the sky)
      { name = "Nakamura", role = "pilot", title = "Surveyor · Asha-2",
        where = { body = "home", site = "near_base", dist = 1800 }, post = "mark:kitspot", face = "mark:raysit" },
      { name = "Castellanos", role = "engineer", title = "Engineer · Asha-2 · hurt",
        where = { body = "home", site = "near_base", dist = 1800, offset = { 3, 0, 0 } }, post = "mark:raysit", face = "mark:kitspot" },
    },
    marks = {
      caird   = { at = "base" },
      a1spot  = { along = { "base", "crew:Nakamura" }, frac = 0.03, offset = { -7, 0, 0 } },
      sunniva = { at = "crew:Priestley", offset = { 4, 0, 1.5 } },
      -- Asha-2 where it stopped, Ray against its flank, Kit by him
      wreck   = { at = "crew:Nakamura", offset = { 6, 0, 2 } },
      raysit  = { at = "crew:Nakamura", offset = { 4.4, 0, 3.4 } },
      kitspot = { at = "crew:Nakamura", offset = { 2.0, 0, 0.5 } },
      wreckcam = { at = "crew:Nakamura", offset = { -8, 0, -6 } },
      -- the ridge road: along the ground from the pad to Asha-2's fix
      r1 = { along = { "base", "crew:Nakamura" }, frac = 0.17 },
      r2 = { along = { "base", "crew:Nakamura" }, frac = 0.55 },          -- the crest of Barrow Ridge
      r3 = { along = { "base", "crew:Nakamura" }, frac = 0.80 },
      -- the flats: round the ridge's west end
      f1 = { along = { "base", "crew:Nakamura" }, frac = 0.30, offset = { 300, 0, 0 } },
      f2 = { along = { "base", "crew:Nakamura" }, frac = 0.55, offset = { 380, 0, 0 } },
      f3 = { along = { "base", "crew:Nakamura" }, frac = 0.80, offset = { 250, 0, 0 } },
      park = { along = { "base", "crew:Nakamura" }, frac = 0.99, offset = { -6, 0, 0 } },
      -- Caird's beacon line, beside the ridge road out to the crest
      b1 = { along = { "base", "crew:Nakamura" }, frac = 0.16, offset = { 14, 0, 0 } },
      b2 = { along = { "base", "crew:Nakamura" }, frac = 0.33, offset = { 14, 0, 0 } },
      b3 = { along = { "base", "crew:Nakamura" }, frac = 0.47, offset = { 14, 0, 0 } },
      b4 = { along = { "base", "crew:Nakamura" }, frac = 0.555, offset = { 14, 0, 0 } },
    },
    beacons = { { at = "mark:b1" }, { at = "mark:b2" }, { at = "mark:b3" }, { at = "mark:b4" } },
    craft = {
      { file = "thirty_km/asha1.json", name = "Asha-1", where = { ground = "mark:a1spot", face = "mark:r1" }, control = false },
      -- (flat: its batteries rebuilt empty; worn in on_start)
      { file = "thirty_km/asha2.json", name = "Asha-2", where = { ground = "mark:wreck", face = "base", charge = 0 }, control = false },
    },
  },

  -- the night's damage, the kit in the locker, Ray down, the suit clock
  on_start = {
    { wear = { craft = "Asha-2", uid = 2, hp = 0.1 } },
    { wear = { craft = "Asha-2", uid = 8, hp = 0.2 } },
    { give = { craft = "Asha-1", item = "tractionCell", n = 1 } },
    { give = { craft = "Asha-1", item = "repairkit", n = 1 } },
    { give = { craft = "Asha-1", item = "medkit", n = 1 } },
    { pose = { who = "Castellanos", kind = "sit", at = "mark:raysit", facing = "mark:kitspot" } },
    { face = { who = "ray", emotion = "pain", secs = 600 } },
    { hook = "start_air" },
    { run = "opening" },
  },

  sequences = {
    -- ── ACT 1 ──────────────────────────────────────────────────────────────
    opening = {
      { cutscene = true },
      { shot = { orbit = "craft:Asha-1", dist = 13, height = 3.5, turn = 50, start = 210, secs = 9, wait = false } },
      { caption = { "THIRTY KILOMETRES", "Caird Base · Taquo · 18:52 local · the sun going down", 6 } },
      { wait = 4 },
      { say = { who = "ops", text = "Asha-2 called in at 18:31. Front-left hub's gone, the cell's cooked, and Ray's hurt. They're on the far side, past Barrow Ridge." } },
      { say = { who = "ops", text = "Nineteen hundred metres by the ridge road. Kit says they've done thirty kilometres on that cell since Tuesday. It's rated for twenty-five." } },
      { shot = { orbit = "mark:wreck", dist = 16, height = 5, turn = 30, start = 120, secs = 6, wait = false } },
      { say = { who = "ops", text = "Ray's suit tore at the knee when the hub went. Kit taped it. Kit's counting his minutes. Last count was twenty-three." } },
      { shot = { orbit = "crew:Priestley", dist = 5, height = 1.8, turn = 25, start = 160, secs = 3 } },
    },
    handover = {
      { look = { who = "sunniva", at = "crew:Priestley" } },
      { walk = { who = "Berge", to = "crew:Priestley", near = 1.4, speed = 1.3, secs = 14, wait = true } },
      { turn = { who = "Berge", to = "crew:Priestley" } },
      { face = { who = "sunniva", emotion = "worried", secs = 30 } },
      { say = { who = "sunniva", with = "jonah", text = "I've got the trauma bag and the medical bottle. If Ray's leg is what Kit says it is, I'm splinting it on the ground in the dark." } },
      { gesture = { who = "Berge", clip = "stand_talk", secs = 10 } },
      { say = { who = "sunniva", with = "jonah", text = "And I'm going to be sick in that rover. I'm telling you now so you don't slow down for it." } },
      { say = { who = "ops", text = "Jonah. Spare cell's in Asha-1's rear locker, sixteen kilos, with a third Repair Kit beside it. You've got two on your belt. Count them." } },
      { run = "route_q" },
    },
    route_q = {
      { choice = { who = "ops", prompt = "Which way, Jonah?",
        options = {
          { text = "The ridge road. Straight over Barrow Ridge.", var = { route = "ridge" }, run = "route_ridge" },
          { text = "The flats. The long way round the west end.", var = { route = "flats" }, run = "route_flats" },
          { text = "Tell me the difference.", run = "route_ask" },
        }, default = 1, timeout = 45 } },
    },
    route_ask = {
      { say = { who = "ops", text = "Ridge road's nineteen hundred metres, the beacon line most of the way, and eighteen degrees at the top." } },
      { say = { who = "ops", text = "The flats are longer and flat. Once you're round the end, the ridge is between us and you're on your own." } },
      { say = { who = "sunniva", with = "jonah", text = "Ray's suit has a number on it. I'd like to arrive with some of it left." } },
      { choice = { who = "ops", prompt = "Which way?",
        options = {
          { text = "The ridge road.", var = { route = "ridge" }, run = "route_ridge" },
          { text = "The flats.", var = { route = "flats" }, run = "route_flats" },
        }, default = 1, timeout = 40 } },
    },
    route_ridge = {
      { say = { who = "ops", text = "Ridge road. It's eighteen degrees at the top, the slope that put Asha-2 on its side in the spring. Take it straight up, not across." } },
      { say = { who = "ops", text = "The beacon line runs to the crest. Past the crest I can't hear you, and nobody can hear them." } },
      { run = "get_in" },
    },
    route_flats = {
      { say = { who = "ops", text = "The flats. Two kilometres and change, nothing steeper than a car park." } },
      { say = { who = "ops", text = "The beacons are on the ridge. I'll hear you down the flats until you turn the end of it. Then the ridge has you." } },
      { run = "get_in" },
    },
    get_in = {
      { say = { who = "sunniva", with = "jonah", text = "Right. I'm in the front. Lamps on before you need them, Jonah, it gets dark here like a door shutting." } },
      { look = { who = "sunniva", at = false } },
      { walk = { who = "Berge", to = "craft:Asha-1", near = 1.6, speed = 1.3, secs = 16, wait = true } },
      { board = { who = "Berge", craft = "Asha-1", seat = 8 } },
    },
    set_off = {
      { say = { who = "ops", text = "Asha-1 rolling at 18:58. Caird copies. Keep talking to me while you can." } },
      { light = { time = "night", ambient = 0.45, secs = 150 } },
      { board = { who = "Berge", craft = "Asha-1", seat = 8 } },
    },
    check_pad = {
      { say = { who = "jonah", text = "Caird, Asha-1. Past the pad lights, first beacon on my left." } },
      { say = { who = "ops", text = "Copy, Asha-1. Strong and clear. Sun's down behind you." } },
      { branch = { var = "route", eq = "ridge",
        beats = { { say = { who = "sunniva", text = "That's the ridge. It's bigger in the dark." } } } } },
    },
    check_crest = {
      { say = { who = "jonah", text = "Caird, Asha-1. On the crest. Last beacon. Going over." } },
      { say = { who = "ops", text = "Copy, Asha-1, on the crest. You've got about three hundred metres of me left. After that, find them and talk to each other." } },
      { say = { who = "kit_far", text = "Asha-1, this is Kit. We see a light on the ridge. Ray's at fourteen minutes. Don't come down the gully, come down the spur." } },
      { say = { who = "sunniva", text = "Was that Kit? I got about every third word." } },
    },
    check_flat = {
      { say = { who = "jonah", text = "Caird, Asha-1. On the flats, ridge on my right." } },
      { say = { who = "ops", text = "Copy, Asha-1. You're faint. Ridge on your right and I lose you round the end." } },
      { say = { who = "sunniva", text = "It's a long way round in the dark. Drive." } },
    },
    far_side = {
      { say = { who = "sunniva", text = "I can see something. Low, to the left. A torch. Somebody's waving a torch." } },
      { say = { who = "kit_r", text = "Asha-1, Kit, on suit. I have your lamps. Come straight to me, there's nothing in the way but me." } },
      { var = { met_kit = true } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    arrival = {
      { cutscene = true },
      { shot = { from = "mark:wreckcam", look = "craft:Asha-2", offset = { 0, 2.2, 0 }, toOffset = { 0, 0.8, 0 }, secs = 5, wait = false } },
      { caption = { "ASHA-2", "The far side of Barrow Ridge · 19:06", 4 } },
      { gesture = { who = "Nakamura", clip = "wave", secs = 3 } },
      { face = { who = "kit", emotion = "relief", secs = 10 } },
      -- (she knows which way you came: your lamps told her)
      { branch = { var = "route", eq = "ridge",
        beats = { { say = { who = "kit", text = "You came over the ridge. I'd have come over the ridge. Hello. I'm very glad you're here." } } },
        elseBeats = { { say = { who = "kit", text = "You came round by the flats. Twenty minutes of nobody, and then your lamps. Hello. I'm very glad you're here." } } } } },
      { say = { who = "ray", text = "Hub bearing walked out of its seat. I pressed it back in with a rock. It's in. It's not in in any way you'd sign for." } },
      { shot = { orbit = "mark:raysit", dist = 4.5, height = 1.6, turn = 25, secs = 5, wait = false } },
      { say = { who = "ray", text = "And the cell cooked when we kept pulling on it in the cold. The case is split. Don't touch the green stuff." } },
    },
    meet = {
      { look = { who = "kit", at = "crew:Priestley" } },
      { walk = { who = "Nakamura", to = "crew:Priestley", near = 1.6, speed = 1.2, secs = 20, wait = true } },
      { turn = { who = "Nakamura", to = "crew:Priestley" } },
      { face = { who = "kit", emotion = "tired", secs = 30 } },
      { say = { who = "kit", with = "jonah", text = "Ray's leg is broken, whatever he tells you. His suit's at what it's at. I've been counting out loud for an hour and he's sick of me." } },
      { gesture = { who = "Nakamura", clip = "point", secs = 3 } },
      { say = { who = "kit", with = "jonah", text = "Front left's the hub. The drum behind the seats is the cell. Ray says mend the cradle before the new one goes in. Ray says it every four minutes." } },
      { look = { who = "kit", at = false } },
    },
    medic = {
      { board = { who = "Berge", craft = false } },
      { walk = { who = "Berge", to = "crew:Castellanos", near = 0.9, speed = 1.5, secs = 25, wait = true } },
      { turn = { who = "Berge", to = "crew:Castellanos" } },
      { gesture = { who = "Berge", clip = "kneel_work" } },
      { say = { who = "sunniva", with = "ray", text = "Ray. I'm Sunniva. I'm going to cut your tape off and put better tape on, and then I'm going to look at your leg, and you're going to be rude to me." } },
      { say = { who = "ray", with = "sunniva", text = "It's not broken." } },
      { wait = 14 },
      { say = { who = "sunniva", with = "ray", text = "Seal's taped. You're losing air at the suit's own rate now, not one and a half times it." } },
      { var = { patched = true } },
      { wait = 12 },
      { say = { who = "sunniva", with = "ray", text = "And it's broken. Tib and fib, I'd bet my bag on it. Splinted. Don't stand on it, don't let anyone stand you on it." } },
      { say = { who = "ray", with = "sunniva", text = "It's not that broken." } },
      { gesture = { who = "Berge", clip = false } },
    },
    hub_done = {
      { say = { who = "ray", text = "Listen to it turn. Hear that? That's a bearing back in its seat. Not a good seat. Keep her under twenty and she'll get us home." } },
    },
    cradle_done = {
      { say = { who = "ray", text = "Cradle's clean. Now the new cell. It's sixteen kilos and it only goes in one way, the way with the arrow." } },
    },
    cell_fitted = {
      { hook = "fit_cell" },
      { face = { who = "kit", emotion = "delight", secs = 10 } },
      { say = { who = "kit", text = "She's awake. Asha-2's got lights. Look at that. A hundred per cent." } },
      { say = { who = "ray", text = "Thirty-one kilometres on the old one. I want that written down somewhere." } },
    },
    who_rides = {
      { say = { who = "sunniva", text = "Ray's suit is the clock. On Asha-1 he's on my bottle and it fills back up. Anywhere else it only goes down." } },
      { say = { who = "ray", text = "And that hub is pressed in by hand. It wants a gentle driver and a slow road." } },
      { choice = { who = "kit", prompt = "How do we go home, Jonah?",
        options = {
          { text = "Ray rides with Sunniva in Asha-1. Kit, you follow me in Asha-2.", var = { plan = "split" }, run = "plan_split" },
          { text = "Ray stays with Kit in Asha-2. We crawl home together.", var = { plan = "crawl" }, run = "plan_crawl" },
          { text = "Leave Asha-2 here. All four of us in Asha-1.", var = { plan = "abandon" }, run = "plan_abandon" },
        }, default = 1, timeout = 60 } },
    },
    plan_split = {
      { say = { who = "kit", text = "I'll sit on your lamps. If you go over twenty, I'm going over twenty, so don't." } },
      { say = { who = "ray", text = "Look after my rover, Kit." } },
    },
    plan_crawl = {
      { say = { who = "kit", text = "Walking pace, then. Ray, you're with me. You can count your own minutes for a change." } },
      { say = { who = "sunniva", with = "jonah", text = "If his number gets low, Jonah, I want him on my bottle, whatever that costs the rover." } },
    },
    plan_abandon = {
      { say = { who = "ray", text = "There's six weeks of cores in that rover." } },
      { say = { who = "kit", text = "There's one of you. Get in, Ray." } },
    },
    -- ── ACT 3 ──────────────────────────────────────────────────────────────
    front = {
      { weather = { kind = "snow", secs = 60 } },
      { say = { who = "kit_r", text = "The wind's backing. Feel that? That's the front off the pole. It'll be snow in five minutes and nothing to see in ten." } },
      { light = { fog = 0.35, secs = 90 } },
    },
    blizzard = {
      { weather = { kind = "blizzard", secs = 90 } },
      { light = { fog = 0.6, secs = 60 } },
      { say = { who = "sunniva", text = "I can't see the ground. I can see your lamps on the snow and then nothing." } },
    },
    hub_hot = {
      { say = { who = "kit_r", text = "Jonah, I can smell the hub through the suit. That's not possible. Slow down." } },
    },
    hub_fails = {
      { say = { who = "kit_r", text = "That's it. That's the bearing gone again. I've stopped. She won't turn." } },
      { say = { who = "ray", text = "I told you. Twenty. I said twenty." } },
      { objective = { step = "home", text = "Asha-2's hub has failed again. Mend it with the third Repair Kit (Asha-1's locker), or bring Kit aboard Asha-1 and leave Asha-2." } },
    },
    kit_bottle = {
      { say = { who = "kit_r", text = "Ray's under four minutes. I'm putting my spare bottle on him. That's five more and then that's all there is." } },
    },
    caird_hears = {
      { say = { who = "ops", text = "Asha-1, Caird. I have you on the beacon line. Say souls." } },
      { say = { who = "jonah", text = "Caird, Asha-1. Four souls." } },
      { say = { who = "ops", text = "Four. Copy four. The pad lights are on for you." } },
    },
    -- ── ACT 4 ──────────────────────────────────────────────────────────────
    resolution = {
      { cutscene = true },
      -- (storypolish, Ty 11-11: endings that cut away) the convoy rolling in
      -- first, seen from outside, lamps on the snow; then the base
      { shot = { from = "craft:Asha-1", offset = { 6, 2.4, 7 }, to = "craft:Asha-1", toOffset = { 4, 3.2, 11 }, look = "craft:Asha-1", lookOffset = { 0, -0.4, 0 }, secs = 7 , wait = false } },
      { say = { who = "ops", text = "I have your lamps. Both sets. Come in slow, the pad's glazed." } },
      { wait = 2.0 },
      { weather = { kind = "snow", secs = 20 } },
      { shot = { orbit = "mark:caird", dist = 40, height = 14, turn = 40, start = 30, secs = 12, wait = false } },
      { caption = { "21:14", "Caird Base · four souls · the front going over", 5 } },
      { branch = { var = "route", eq = "ridge",
        beats = { { say = { who = "kit", text = "You came over the ridge in the dark. I watched your lamps all the way down. I'd have done the same, and I'd have been wrong to." } } },
        elseBeats = { { say = { who = "kit", text = "You came round by the flats. Nobody heard from you for twenty minutes. That was the longest twenty minutes I've had." } } } } },
      { shot = { orbit = "craft:Asha-1", dist = 9, height = 2.6, turn = 40, start = 200, secs = 14, wait = false } },
      { branch = { var = "hub_failed", is = true,
        beats = { { say = { who = "ray", text = "The hub let go a second time. My bearing, my rock. Next time somebody else holds the rock." } } },
        elseBeats = { { say = { who = "ray", text = "The hub held. All the way. Somebody write down that a rock and an engineer did that." } } } } },
      -- (his sister is three days out on the Ansel: Hard Vacuum)
      { say = { who = "ray", text = "And nobody tells my sister. She's on a freighter three days from anywhere and she'd still hear about it by morning." } },
      { branch = { var = "plan", eq = "abandon",
        beats = { { say = { who = "kit", text = "Asha-2's out there with six weeks of cores in her. We'll go back for her in daylight. She'll keep." } } } } },
      { branch = { var = "kit_bottle", is = true,
        beats = { { say = { who = "sunniva", text = "Kit gave Ray her spare bottle on the flats. That's the only reason he's breathing. I want that in the log." } } },
        elseBeats = { { say = { who = "sunniva", text = "Ray's leg is broken in two places and he's asleep on my table. His suit had air in it the whole way. That's a good night." } } } } },
      { say = { who = "sunniva", text = "And I wasn't sick. Put that in the log too, under the hub." } },
      -- (Ops counts the rovers she can see: Asha-2 left on the far side by plan; else home, or still
      -- short of the pad when the convoy's tail lags the `a2home` event: then she counts souls only)
      { branch = { var = "plan", eq = "abandon",
        beats = { { say = { who = "ops", text = "Asha-1, Caird. Logged in at 21:14. Four souls, one rover. The other one keeps till daylight. Go to bed. Ops out." } } },
        elseBeats = { { branch = { var = "asha2_home", is = true,
          beats = { { say = { who = "ops", text = "Asha-1, Asha-2, Caird. Logged in at 21:14. Thirty-two kilometres on Asha-2's odometer, one rover I didn't think I'd see again. Go to bed. Ops out." } } },
          elseBeats = { { say = { who = "ops", text = "Asha-1, Caird. Logged in at 21:14. Four souls. Bring Asha-2 up to the pad lights and go to bed. Ops out." } } } } } } } },
      { var = { debriefed = true } },
    },
  },

  events = {
    -- Caird's voice goes when Asha-1's comms path does (the real solve)
    { id = "link_lost", when = { kind = "hook", fn = "link_down" }, after = "board",
      beats = { { var = { link_lost = true } },
                { say = { who = "ops", text = "Asha-1, Caird. Say again. Asha-1, Caird, I am losing your carrier." } },
                { say = { who = "sunniva", text = "That's Caird gone. It's very quiet when they stop talking." } } } },
    { id = "sick", when = { kind = "timer", secs = 30, from = "step:r2" },
      beats = { { say = { who = "sunniva", text = "Don't look at me. Look at the slope. I'm fine. I'm absolutely fine." } } } },
    { id = "half", when = { kind = "var", name = "a1_pct", lt = 55 }, after = "board",
      beats = { { say = { who = "sunniva", text = "Asha-1's at half. Half got us here. Your lamps are costing us, Jonah, but I'd rather see the rocks." } } } },
    { id = "quarter", when = { kind = "var", name = "a1_pct", lt = 25 }, after = "board",
      beats = { { say = { who = "sunniva", text = "A quarter. Under a quarter. Will it get us home?" } } } },
    -- Kit counts Ray's minutes
    { id = "air10", when = { kind = "var", name = "ray_air", lt = 600 },
      beats = { { branch = { var = "met_kit", is = true,
        beats = { { say = { who = "kit", text = "Ray's at ten minutes." } } },
        elseBeats = { { say = { who = "kit_far", text = "Asha-1, Kit. Ray's at ten. Ten minutes. Are you close?" } } } } } } },
    { id = "air5", when = { kind = "var", name = "ray_air", lt = 300 },
      beats = { { say = { who = "kit", text = "Five minutes, Ray. Five." } }, { face = { who = "ray", emotion = "scared", secs = 20 } } } },
    { id = "air2", when = { kind = "var", name = "ray_air", lt = 120 },
      beats = { { say = { who = "ray", text = "It's getting thick in here. The air's going thick." } } } },
    -- the medical starts as soon as Sunniva is there
    { id = "medic_go", when = { kind = "var", name = "met_kit", is = true }, after = "arrive", run = "medic" },
    -- the cell goes in the moment it can (the cradle mended, the cell carried, at Asha-2)
    { id = "cell", when = { kind = "hook", fn = "cell_ready" }, after = "arrive", run = "cell_fitted" },
    { id = "hub_hot", when = { kind = "var", name = "hub_heat", gt = 60 }, after = "who", run = "hub_hot" },
    { id = "hub2", when = { kind = "part_hp", craft = "Asha-2", uid = 2, above = 0.9 }, also = { kind = "var", name = "hub_failed", is = true },
      beats = { { var = { hub_fixed2 = true, hub_failed = false, hub_heat = 0 } },
                { say = { who = "ray", text = "Again. Fine. Under twenty, Jonah. I mean it this time." } },
                { drive = { craft = "Asha-2", follow = "craft:Asha-1", speed = 7, gap = 14 } } } },
    { id = "front2", when = { kind = "timer", secs = 150, from = "step:home" }, run = "blizzard" },
    { id = "caird", when = { kind = "hook", fn = "link_up" }, after = "who", run = "caird_hears" },
    { id = "a2home", when = { kind = "at", who = "craft:Asha-2", at = "mark:caird", r = 70 }, after = "who",
      beats = { { var = { asha2_home = true } } } },
  },

  steps = {
    -- ACT 1: out
    { id = "board", text = "Get in Asha-1. Sunniva's taking the seat beside you.", act = "Act 1 · out", run = "handover", mark = "craft:Asha-1",
      goals = { { kind = "at", who = "crew:Priestley", at = "craft:Asha-1", r = 1.0, label = "In Asha-1's driver's seat" } },
      hint = "Asha-1 is the four-seat rover parked beside you at the pad. Walk up to it and press F to take a seat (the front left drives).",
      hint2 = "The spare traction cell is in Asha-1's rear locker (right-click the locker on the back deck). You'll need it at the wreck.",
      on_done = { { branch = { var = "route", eq = "flats", beats = { { ["goto"] = "f1" } } } }, { run = "set_off" } } },
    { id = "r1", text = "The ridge road. Out past the pad lights to the first relay beacon.", mark = "mark:r1",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:r1", r = 30, label = "First beacon, 300 m out" } },
      hint = "W drives, A and D steer, S brakes. Head for the marker. Y switches Asha-1's lamps: the night comes down fast.",
      hint2 = "The beacon line runs beside the road all the way to the crest. Follow the masts.",
      on_done = { { run = "check_pad" } } },
    { id = "r2", text = "Up Barrow Ridge. Take the slope straight, not across it.", mark = "mark:r2",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:r2", r = 45, label = "The crest of Barrow Ridge" } },
      hint = "Point Asha-1 straight up the fall line and keep the power on gently. Across an eighteen-degree slope a tall rover rolls.",
      hint2 = "If you go over, F gets you out. Asha-1 can't be righted out here: you'd walk the rest.",
      on_done = { { run = "check_crest" } } },
    { id = "r3", text = "Over the crest and down the far side. Past here Caird can't hear you.", mark = "mark:r3",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:r3", r = 35, label = "The far side" } },
      hint = "Down the spur, not the gully: keep the marker ahead. Brake (S) on the steep part, the lamps only show you forty metres.",
      on_done = { { ["goto"] = "arrive" }, { run = "far_side" } } },
    { id = "f1", text = "The flats. West, round the end of the ridge.", mark = "mark:f1",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:f1", r = 40, label = "The ridge's west end" } },
      hint = "Head for the marker, west of the ridge. It's flat and long; past the ridge's end Caird can't hear you.",
      on_done = { { run = "check_flat" } } },
    { id = "f2", text = "Keep the ridge on your right.", mark = "mark:f2",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:f2", r = 40, label = "Under the ridge" } },
      hint = "The dark mass on your right is Barrow Ridge. Keep it there and follow the marker." },
    { id = "f3", text = "Swing back east toward Asha-2's last fix.", mark = "mark:f3",
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:f3", r = 40, label = "Asha-2's side of the ridge" } },
      hint = "Turn east for the marker. Kit will see your lamps before you see her.",
      on_done = { { run = "far_side" } } },
    -- ACT 2: there
    -- (a setback here: the rovers and the two of you back by Asha-2, the
    -- wreck as it was; the story's variables as they were when it opened)
    { id = "arrive", text = "Find Asha-2. Kit's torch is the only light out there.", act = "Act 2 · Asha-2", checkpoint = true, mark = "craft:Asha-2",
      stage = { beats = {
        { place = { craft = "Asha-1", at = "mark:park" } },
        { place = { who = "Priestley", at = "mark:park", offset = { 2.5, 0, 0 } } },
        { place = { who = "Berge", at = "mark:park", offset = { -2.5, 0, 0 } } },
        { wear = { craft = "Asha-2", uid = 2, hp = 0.1 } },
        { wear = { craft = "Asha-2", uid = 8, hp = 0.2 } },
        { give = { craft = "Asha-1", item = "tractionCell", n = 1 } },
        { give = { craft = "Asha-1", item = "repairkit", n = 1 } },
        { pose = { who = "Castellanos", kind = "sit", at = "mark:raysit", facing = "mark:kitspot" } },
        { hook = "start_air" },
        { light = { time = "night", ambient = 0.45, secs = 1 } } } },
      goals = { { kind = "at", who = "crew:Priestley", at = "craft:Asha-2", r = 24, label = "At Asha-2" },
                { kind = "hook", fn = "ray_air", label = "Ray's suit" } },
      hint = "Asha-2 is at the marker, low on the far slope. Drive (or walk) up to it.",
      on_done = { { run = "arrival" }, { run = "meet" } } },
    { id = "medic", text = "Sunniva sees to Ray.", parallel = "repair",
      goals = { { kind = "var", name = "patched", is = true, label = "Ray's suit seal taped" },
                { kind = "hook", fn = "ray_air", label = "Ray's suit" } },
      hint = "Sunniva is working on Ray. Nothing for you to do there: start on Asha-2." },
    { id = "hub", text = "Repair Asha-2's front-left hub.", parallel = "repair", mark = "craft:Asha-2",
      goals = { { kind = "part_hp", craft = "Asha-2", uid = 2, above = 0.9, label = "Front-left hub mended" } },
      hint = "Hold the Repair Kit (its belt key) and right-click Asha-2's front-left wheel, the one leaning in: Repair. Stay with it until it finishes, about twenty seconds.",
      hint2 = "Ray is an engineer and would do it twice as fast. You can switch to him ([ or ]), but he has a broken leg.",
      on_done = { { run = "hub_done" } } },
    { id = "cradle", text = "Mend the cooked cell's cradle.", parallel = "repair", mark = "craft:Asha-2",
      goals = { { kind = "part_hp", craft = "Asha-2", uid = 8, above = 0.9, label = "Cell cradle mended" } },
      hint = "The traction cell is the drum behind Asha-2's seats. Repair Kit in hand, right-click it: Repair.",
      hint2 = "Two kits for the hub and the cradle. The third is in Asha-1's rear locker.",
      on_done = { { run = "cradle_done" } } },
    { id = "cell", text = "Fit the spare traction cell from Asha-1's locker.", parallel = "repair", mark = "craft:Asha-2",
      goals = { { kind = "hook", fn = "cell_ready", label = "The new cell" }, { kind = "hook", fn = "cell_in", label = "Asha-2 powered" } },
      hint = "Right-click Asha-1's rear locker and take the Traction Cell into your pack (16 kg), then walk up to Asha-2 with it. It goes in once the cradle is mended.",
      hint2 = "The cell goes in by itself when you stand at Asha-2 carrying it, with the cradle repaired." },
    { id = "who", text = "Decide who rides where.", run = "who_rides",
      goals = { { kind = "var", name = "plan", ne = "", label = "The plan home" } },
      hint = "Choose with the number keys (or the mouse). Asha-1 refills Ray's suit; Asha-2's hub hates speed." },
    -- ACT 3: home
    -- (a setback here: both rovers by Asha-2's fix, Asha-2 mended and
    -- powered, everyone where they were when the convoy formed)
    { id = "home", text = "Lead them home. Caird is behind the ridge.", act = "Act 3 · the front", checkpoint = true, mark = "mark:caird",
      stage = { beats = {
        { place = { craft = "Asha-1", at = "mark:park" } },
        { place = { who = "Priestley", at = "mark:park", offset = { 2.5, 0, 0 } } },
        { place = { who = "Berge", at = "mark:park", offset = { -2.5, 0, 0 } } },
        { charge = { craft = "Asha-2", frac = 1.0 } },
        { give = { craft = "Asha-1", item = "repairkit", n = 1 } },
        { hook = "start_air" },
        { light = { time = "night", ambient = 0.45, secs = 1 } } } },
      on_enter = {
        { branch = { var = "plan", eq = "split", beats = {
          { walk = { who = "Nakamura", to = "craft:Asha-2", near = 1.5, secs = 20, wait = true } },
          { board = { who = "Nakamura", craft = "Asha-2", seat = 6 } },
          { walk = { who = "Berge", to = "craft:Asha-1", near = 1.5, secs = 25 } },
          { board = { who = "Castellanos", craft = "Asha-1", seat = 9 } },
          { board = { who = "Berge", craft = "Asha-1", seat = 8 } },
          { drive = { craft = "Asha-2", follow = "craft:Asha-1", speed = 7, gap = 14 } } } } },
        { branch = { var = "plan", eq = "crawl", beats = {
          { walk = { who = "Nakamura", to = "craft:Asha-2", near = 1.5, secs = 20, wait = true } },
          { board = { who = "Castellanos", craft = "Asha-2", seat = 7 } },
          { board = { who = "Nakamura", craft = "Asha-2", seat = 6 } },
          { walk = { who = "Berge", to = "craft:Asha-1", near = 1.5, secs = 25, wait = true } },
          { board = { who = "Berge", craft = "Asha-1", seat = 8 } },
          { drive = { craft = "Asha-2", follow = "craft:Asha-1", speed = 3.5, gap = 16 } } } } },
        { branch = { var = "plan", eq = "abandon", beats = {
          { walk = { who = "Nakamura", to = "craft:Asha-1", near = 1.5, secs = 25, wait = true } },
          { board = { who = "Castellanos", craft = "Asha-1", seat = 9 } },
          { board = { who = "Nakamura", craft = "Asha-1", seat = 10 } },
          { board = { who = "Berge", craft = "Asha-1", seat = 8 } } } } },
        { hook = "convoy_on" },
        { run = "front" },
      },
      goals = { { kind = "at", who = "crew:Priestley", at = "mark:caird", r = 70, label = "Jonah at Caird" },
                { kind = "at", who = "crew:Berge", at = "mark:caird", r = 70, label = "Sunniva at Caird" },
                { kind = "at", who = "crew:Castellanos", at = "mark:caird", r = 70, label = "Ray at Caird" },
                { kind = "at", who = "crew:Nakamura", at = "mark:caird", r = 70, label = "Kit at Caird" },
                { kind = "hook", fn = "ray_air", label = "Ray's suit" },
                { kind = "hook", fn = "convoy", label = "The convoy" } },
      hint = "Drive back the way you came: the marker is Caird. Asha-2 follows your lamps; over 20 km/h its hub heats (the card shows it).",
      hint2 = "Ray's suit only fills on Asha-1. If his number gets low, stop and put him in Asha-1's free seat (right-click him: Board, or walk him there).",
      on_done = { { run = "resolution" } } },
    -- ACT 4: Caird
    { id = "morning", text = "Caird.", act = "Act 4 · Caird",
      goals = { { kind = "var", name = "debriefed", is = true, label = "Logged in" } },
      hint = "Nothing left to do. The front is going over." },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Somebody didn't come back from the far side of Barrow Ridge.",
      hint = "Ray's suit only fills on Asha-1. Watch his number, and stop to swap seats before it is low, not when it is." },
  },

  score = {
    par = 1200,
    rows = {
      { label = "Distance driven (Asha-1)", var = "dist_m", fmt = "%.0f m" },
      { label = "Ray's lowest air", var = "ray_min", fmt = "%.0f s", par = "≥ 300 s", gte = 300 },
      { label = "Asha-1's battery, lowest", var = "a1_min", fmt = "%.0f %%", par = "≥ 20 %", gte = 20 },
      { label = "What the lamps cost", var = "lamp_ec", fmt = "%.0f EC" },
      { label = "Asha-2 home", var = "asha2_home", par = "yes" },
    },
    medals = {
      gold = { time = 1.0, vars = { ray_min = { gte = 300 }, hub_failed = { is = false }, hub_fixed2 = { is = false }, asha2_home = { is = true } } },
      silver = { time = 1.8, vars = { ray_min = { gte = 60 } } },
      bronze = "done",
    },
  },
  after = "freeplay",
  freeplay = { contracts = false, programme = false },
  debrief = {
    gold = "Two rovers, four souls, one hub that held. Ray's suit never went under five minutes. Caird is writing your route up for the next idiot who breaks down past the ridge.",
    silver = "Everyone is home and breathing. Some of it was close and some of it was luck. Read Ray's notes on the hub before you drive Asha-2 again.",
    bronze = "Caird has all four of you. Ask Sunniva what the last ten minutes looked like from her side.",
    fail = "Somebody is still out past Barrow Ridge. Caird is sending the day crew at first light.",
  },
}
