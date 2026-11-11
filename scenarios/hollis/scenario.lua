-- WHAT HOLLIS LEFT: a ruin, four Data Cores, and a company that wants them sealed
-- (docs/scenarios.md; work/scenarios2/PLAN.md §1.2, SC-4).
--
-- Lindqvist Camp, a Hendry Resources habitat on a cold thin-air world, empty
-- for 4,015 days. The camp is a real ruin (start.ruins: tools/gen_hollis_camp.lua
-- builds it as it stood; the author's decay takes the roofs, breaks the
-- windows and drops a shield block in the reactor shed). Its tower is
-- claimed the way any ruin's is, its grid comes back through its own breaker,
-- its bunk room holds air only once the roof is back on and the door's blown
-- seal is re-seated, and the restore bill is in the author's lots at the
-- author's prices. The four cores (start.cores) sit in its pieces: two in
-- terminals (read on the console's CORE page), one in the chief's bunk (read
-- only in breathable air), one under the fallen block (read once it is lifted).
-- No hooks: every rule is a goal or a core's field.
--
--   ACT 1  the walk in: the camp at dusk, core 1 on the mess table
--   ACT 2  power: the claim, the breaker, core 2 in the workshop
--   ACT 3  the sealed room: the roof, the seal, the air, core 3; Brennan
--   ACT 4  the shed: night, the block, core 4 read or sealed; first light
--
-- Every line, in act order: work/scn_hollis/SCRIPT.md (script_md.lua).
return {
  id = "hollis", title = "What Hollis Left", v = 1, order = 20, minutes = 30,
  teaches = { "ruins", "claim", "power", "restore", "airtight", "terminal" },
  blurb = "Lindqvist Camp has been empty for eleven years. Claim it for Hendry Resources, bring it back to life, and decide what to do with what its chief left behind.",
  brief = {
    "Lindqvist Camp, a Hendry Resources habitat on a cold world with a little thin air. Abandoned 4,015 days ago after a coolant pump failure. One fatality: the camp chief, Agnes Lindqvist.",
    "You are Noor Haddad, Hendry's contract engineer: claim the site and make it safe. Teodor Lindqvist comes with you as the survey scientist. He is her son. The company wants the camp's Data Cores recovered and sealed.",
  },
  world = { seed = 731905, scale = 4, names = 2, air = "thin", home = "alien", homeSeed = 4412,      -- (Kerne's world: Graveyard Shift's, its flats)
            time = { at = "dusk", hold = true } },

  cast = {
    me      = { name = "Noor Haddad", tag = "ENGINEER · HENDRY CONTRACT", crew = "Haddad", color = { 0.85, 0.88, 0.95 }, portrait = "auto" },
    teo     = { name = "Teodor Lindqvist", tag = "SCIENTIST · HER SON", crew = "Lindqvist", color = { 0.70, 0.86, 1.0 }, portrait = "auto", expression = "tired" },
    agnes   = { name = "Agnes Lindqvist", tag = "CAMP CHIEF · ELEVEN YEARS AGO", color = { 1.0, 0.72, 0.30 }, portrait = "auto", look = 52917, expression = "tired" },
    brennan = { name = "Robert Brennan", tag = "HENDRY RESOURCES · LEGAL", color = { 0.72, 0.76, 0.82 }, radio = true },
    kestrel = { name = "Kestrel", tag = "HENDRY SHUTTLE · ORBIT", color = { 0.55, 0.85, 1.0 }, radio = true },
  },

  vars = { trust = 0, cores_read = 0, choice4 = "", owed = false, teo_read = false, camp = "", debriefed = false,
           core_c1 = false, core_c2 = false, core_c3 = false, core_c4 = false },

  start = {
    funds = 2400, rp = 0, safety = "death",
    contracts = false, programme = false,
    crew = {
      { name = "Haddad", role = "engineer", title = "Engineer · Hendry contract", control = true,
        where = { body = "home", site = "far_flat_lit" }, post = "mark:start", face = "mark:hab",
        pack = { { item = "repairkit", n = 2 } } },
      { name = "Lindqvist", role = "scientist", title = "Scientist · Agnes Lindqvist's son",
        where = { body = "home", site = "far_flat_lit", offset = { 1.5, 0, 0 } }, post = "mark:teostart", face = "mark:hab" },
    },
    -- the camp: sited where the crew were sited (flat, in the sun: its array
    -- still charges), the crew then set down at the shuttle's drop, south
    ruins = {
      { name = "Lindqvist Camp", bp = "hollis/camp.bp.txt", at = "crew:Haddad", offset = { -40, 0, 70 }, yaw = 0,
        age = 4015, company = "Hendry Resources", decay = 0.6, lean = 70,
        flat = 18, flatSpread = 2.5,      -- (the mark unless the ground there rises over 2.5 m across the camp: then the nearest flatter ground)
        gone = { 41, 42, 43, 44, 45, 46, 47, 48, 50, 51, 52, 53, 54, 102, 103, 104, 105, 106, 107, 108, 109, 110 },
        broken = { 19, 20, 23 },
        knocked = { 117 },
        -- the restore bill, in jobs at Hendry's prices: the allowance ($2,400)
        -- covers the bunk room and one more, not everything; spent in the
        -- wrong order, it does not cover the bunk room at all
        lots = {
          { id = "bunks", name = "the bunk room roof", uids = { 50, 51, 52, 53, 54 }, price = 1300 },
          { id = "shop", name = "the workshop roof", uids = { 46, 47, 48 }, price = 900 },
          { id = "mess", name = "the mess roof", uids = { 41, 42, 43, 44, 45 }, price = 1100 },
          { id = "shed", name = "the reactor shed roof", uids = { 102, 103, 104, 105, 106, 107, 108, 109, 110 }, price = 1700 },
        },
        lore = {
          "LINDQVIST CAMP · HENDRY RESOURCES · SITE 7",
          "Seven on site. Weekly return pending relay.",
          "Shed: pump 2 cartridge requested (HR-40 filed, twice).",
          "Last entry on this terminal: day 3,112. The chief's cores are in the camp.",
        } },
    },
    -- (the cores: uids are camp.bp.txt's lines, tools/gen_hollis_camp.lua prints them)
    cores = {
      -- CORE 1: the mess terminal, on the core's own cell (no power needed)
      { id = "c1", struct = "Lindqvist Camp", uid = 60, who = "agnes", title = "MESS TERMINAL · WEEKLY RETURN", run = "after_c1",
        pages = {
          { date = "Day 3,112 · 06:40 · A. Lindqvist", text = "Weekly return, which is now a monthly return, because the relay is late again, and Hendry says the relay is not late, it is scheduled. Seven on site. Morale good. Coffee gone. We have replaced the coffee with arguing about who drank the coffee." },
          { date = "Day 3,112 · 06:52", text = "Pump 2 in the shed is singing in the cold. Ilse says it is the grease. I have asked Hendry for a spare cartridge. Hendry has asked me to fill in form HR-40, Justification of Need, explaining why a pump needs to pump. I have filled it in. Twice." },
          { date = "Day 3,112 · 07:05", text = "Teo. If this ever finds its way to you: I am well, I am cold, I am still the best poker player on this rock, and Mira Hollis cheats. Write to me. The relay is scheduled." },
        } },
      -- CORE 2: the workshop terminal: its cell is flat, it reads on the grid
      { id = "c2", struct = "Lindqvist Camp", uid = 70, who = "agnes", title = "WORKSHOP TERMINAL · SHED LOG", power = true, run = "after_c2",
        why = "the terminal is dark and the core's cell is flat: bring the camp's grid up (claim the tower, close the breaker)",
        pages = {
          { date = "Day 3,131 · 02:55 · A. Lindqvist", text = "Pump 2 seized at 02:10. The primary is on Pump 1 alone. Ilse and I took the reactor down to ten per cent and sat with it. It is very quiet in the shed when one pump is doing the work of two." },
          { date = "Day 3,131 · 03:30", text = "Asked Hendry for the cartridge or a lander, whichever is sooner. Hendry says an evacuation abandons the claim, and the claim is the asset. Hold the site. Part to follow. Forty days." },
          { date = "Day 3,131 · 03:41", text = "So we hold. I want it written down that I was asked to hold, that I said yes, and that I knew what I was saying yes to. The jokes stop here. Ilse has started counting the days on the shed wall." },
        } },
      -- CORE 3: Agnes's bunk, in a shock case that opens only in a sealed room
      { id = "c3", struct = "Lindqvist Camp", uid = 77, who = "agnes", title = "THE CHIEF'S BUNK · PERSONAL", air = "sealed", run = "after_c3",
        label = "Open the shock case under Agnes's pillow", againLabel = "Read Agnes's last night in camp again",
        why = "the shock case opens only inside a sealed room (the dust here eats its contacts): the roof back on, the door's seal re-seated, the door shut",
        pages = {
          { date = "Day 3,152 · 21:10 · A. Lindqvist", text = "Lander at six tomorrow, twenty-one days late. The evacuation order is for six. We are seven. Mira Hollis has been on Hendry's books as transferred since last winter, because the transfer lander never came either, and nobody at head office has ever counted us with their eyes." },
          { date = "Day 3,152 · 21:24", text = "The lander has seats and mass for six. Pump 1 is running hot, and somebody has to be at the console when it goes, or the core goes and takes the camp with it. I have told them I will take the next lander. Mira knows there is no next lander. She took my seat because I asked her to." },
          { date = "Day 3,152 · 21:40", text = "If anyone but Teo reads this: the six are Ilse Varga, Dimitri Osei, Paul Achterberg, June Okonkwo, Sam Reyes and Mira Hollis. Count them. Write it down. Hollis left. That was the point." },
        } },
      -- CORE 4: under the shield block that fell across it in the shed
      { id = "c4", struct = "Lindqvist Camp", uid = 117, who = "agnes", title = "THE SHED · UNDER THE BLOCK", open = "c4_open", run = "after_c4",
        label = "Take the Data Core from under the block", againLabel = "Read the last entry again",
        needs = { kind = "piece_ok", struct = "Lindqvist Camp", uid = 117 },
        why = "the shield block lies across the case: claim the camp, then right the block (a Repair Kit)",
        pages = {
          { date = "Day 3,161 · 23:58 · A. Lindqvist", text = "Day nine on my own. The lander's light went over the ridge at 06:12 on the 153rd and I watched it until there was nothing to watch. Pump 1 seized at 19:40 that night. I scrammed her by hand and cooled her down on natural circulation, by the book, which took until morning. She is cold. She will never hurt anybody." },
          { date = "Day 3,161 · 23:59", text = "Hendry called at noon. They are writing it up as a surface accident during the evacuation, on the 153rd, so the insurance pays and the claim stays clean. They asked me to confirm that I was outside when the pump failed. I said I would think about it. I have thought about it." },
          { date = "Day 3,162 · 00:04", text = "Teo. I did not stay for the claim. The shed was the only thing between seven people and a very bad night, and I knew how to sit with it. Do not let them call it an accident. It was a decision, and it was mine. I am going up on the shed roof to watch for the next lander, like I told them I would." },
        } },
    },
    -- the supply drop the shuttle left at the camp's door
    crates = { { at = "mark:drop", items = { repairkit = 2, o2tank = 2 }, name = "Hendry supply drop" } },
    marks = {
      -- (offsets in the camp's own frame: x east, z north; tools/gen_hollis_camp.lua)
      hab      = { at = "struct:Lindqvist Camp", offset = { 3, 0, 2 } },
      start    = { at = "struct:Lindqvist Camp", offset = { 2.5, 0, -62 } },
      teostart = { at = "struct:Lindqvist Camp", offset = { 4.0, 0, -62.6 } },
      approach = { at = "struct:Lindqvist Camp", offset = { 2.5, 0, -18 } },
      front    = { at = "struct:Lindqvist Camp", offset = { 2.0, 0, -2.4 } },
      teofront = { at = "struct:Lindqvist Camp", offset = { 3.6, 0, -3.0 } },
      drop     = { at = "struct:Lindqvist Camp", offset = { -1.6, 0, -5.0 } },
      mess     = { at = "struct:Lindqvist Camp", offset = { 2.5, 0, 0.0 } },
      teomess  = { at = "struct:Lindqvist Camp", offset = { 1.0, 0, 2.2 } },
      tower    = { at = "struct:Lindqvist Camp", offset = { -6.0, 0, -2.0 } },
      teotower = { at = "struct:Lindqvist Camp", offset = { -3.6, 0, -3.4 } },
      shop     = { at = "struct:Lindqvist Camp", offset = { 7.5, 0, 1.3 } },
      teoshop  = { at = "struct:Lindqvist Camp", offset = { 6.2, 0, 0.4 } },
      breaker  = { at = "struct:Lindqvist Camp", offset = { 8.2, 0, 0.1 } },
      bunkdoor = { at = "struct:Lindqvist Camp", offset = { 2.0, 0, 2.2 } },
      bunk     = { at = "struct:Lindqvist Camp", offset = { 3.4, 0, 5.3 } },
      teobunk  = { at = "struct:Lindqvist Camp", offset = { 0.9, 0, 5.2 } },
      shed     = { at = "struct:Lindqvist Camp", offset = { 17.0, 0, -2.6 } },
      shedin   = { at = "struct:Lindqvist Camp", offset = { 16.4, 0, 0.3 } },
      block    = { at = "struct:Lindqvist Camp", offset = { 16.4, 0, 1.6 } },
      console  = { at = "struct:Lindqvist Camp", offset = { 17.3, 0, 2.0 } },
      teoconsole = { at = "struct:Lindqvist Camp", offset = { 17.35, 0, 2.7 } },
      ridge    = { at = "struct:Lindqvist Camp", offset = { 24.0, 0, 9.0 } },
      center   = { at = "struct:Lindqvist Camp", offset = { 7.0, 0, 2.0 } },
      camfar   = { at = "struct:Lindqvist Camp", offset = { -18.0, 0, -26.0 } },
      shedmid  = { at = "struct:Lindqvist Camp", offset = { 15.6, 0, 2.2 } },      -- (the middle of the shed's floor, clear of its walls)
    },
  },

  on_start = {
    -- (the state Agnes left it in: the bunk-room door's seal blown on her way
    -- out, the camp's main breaker open; a checkpoint's stage puts these back)
    { state = { struct = "Lindqvist Camp", uid = 27, st = { seal = 1, blown = true } } },
    { breaker = { struct = "Lindqvist Camp", uid = 73, closed = false } },
    { weather = { kind = "dust", secs = 2, k = 0.45 } },
    { run = "arrival" },
    { run = "walk_in" },
  },

  sequences = {
    -- ── ACT 1 ──────────────────────────────────────────────────────────────
    arrival = {
      { cutscene = true },
      { shot = { orbit = "mark:center", dist = 46, height = 15, turn = 40, start = 210, secs = 9, wait = false } },
      { caption = { "WHAT HOLLIS LEFT", "Lindqvist Camp · Hendry Resources · empty 4,015 days", 6 } },
      { wait = 4 },
      { say = { who = "kestrel", text = "Haddad, Kestrel. You're down, I'm up. The pad's cracked, so you walk the last stretch. I'm back over the ridge at first light. Kestrel out." } },
      { shot = { from = "mark:camfar", to = "mark:approach", look = "mark:hab", offset = { 0, 5, 0 }, toOffset = { 0, 2.5, 0 }, secs = 6 } },
      { shot = { from = "mark:teostart", look = "mark:hab", offset = { 0, 1.7, 0 }, secs = 2.5 } },
    },
    walk_in = {
      { look = { who = "teo", at = "crew:Haddad" } },
      { walk = { who = "Lindqvist", to = "crew:Haddad", near = 1.4, speed = 1.0, secs = 10, wait = true } },
      { turn = { who = "Lindqvist", to = "crew:Haddad" } },
      { face = { who = "teo", emotion = "tired", secs = 40 } },
      { say = { who = "teo", text = "That's it. That's the camp. It's smaller than in the photographs.", with = "me" } },
      { turn = { who = "Lindqvist", to = "mark:hab" } },
      { look = { who = "teo", at = "mark:hab" } },
      { say = { who = "teo", text = "The public report is nine pages. Pump failure in the reactor shed, orderly evacuation, one fatality in a surface accident during the evacuation. My mother. Four of the nine pages are the claim's coordinates.", with = "me" } },
      { look = { who = "teo", at = "crew:Haddad" } },
      { turn = { who = "Lindqvist", to = "crew:Haddad" } },
      { choice = { who = "teo", prompt = "You've read it. Do you believe it?",
        options = {
          { text = "I've read it. What don't you believe?", var = { arrive = "ask" }, run = "w_ask" },
          { text = "We're here to claim it, Teo. That's the job.", var = { arrive = "job" }, run = "w_job" },
          { text = "Then we find out.", var = { arrive = "find" }, run = "w_find" },
        }, default = 1, timeout = 40 } },
    },
    w_ask = {
      { add = { trust = 1 } },
      { say = { who = "teo", text = "She ran this place for nine years. She didn't have accidents. She had procedures for accidents.", with = "me" } },
      { run = "w_end" },
    },
    w_job = {
      { say = { who = "teo", text = "It's your job. Mine says survey scientist. Hendry wrote that too.", with = "me" } },
      { run = "w_end" },
    },
    w_find = {
      { add = { trust = 1 } },
      { face = { who = "teo", emotion = "relief", secs = 6 } },
      { say = { who = "teo", text = "Thank you. I didn't think anyone was going to say that out loud.", with = "me" } },
      { run = "w_end" },
    },
    w_end = {
      { say = { who = "brennan", text = "Ms Haddad, Mr Lindqvist. Robert Brennan, Hendry Resources, legal. The site's Data Cores are company records. Hendry asks that they be handled as such." } },
      { face = { who = "teo", emotion = "grim", secs = 10 } },
      { say = { who = "teo", text = "That means don't read them.", with = "me" } },
      { look = { who = "teo", at = false } },
      { walk = { who = "Lindqvist", to = "mark:teofront", face = "mark:hab", speed = 1.25, secs = 70 } },
    },
    approach = {
      { look = { who = "teo", at = "mark:hab" } },
      { say = { who = "teo", text = "The roofs have gone. Eleven winters of wind. The door's standing open." } },
      { say = { who = "teo", text = "The mess is the first room. She kept the camp log on the table, so everybody could read it with their breakfast." } },
      { look = { who = "teo", at = false } },
    },
    after_c1 = {
      { add = { cores_read = 1 } },
      { walk = { who = "Lindqvist", to = "mark:teomess", face = "crew:Haddad", speed = 1.1, secs = 20 } },
      { look = { who = "teo", at = "crew:Haddad" } },
      { say = { who = "teo", text = "I wrote every month. She never got them. The relay was scheduled.", with = "me" } },
      { face = { who = "teo", emotion = "worried", secs = 14 } },
      { say = { who = "teo", text = "Seven on site. The report says six. Five evacuated and her.", with = "me" } },
      { say = { who = "me", text = "Who's Mira Hollis?", with = "teo" } },
      { say = { who = "teo", text = "I don't know. She isn't in the report. Nobody is in the report who isn't in the report.", with = "me" } },
      { look = { who = "teo", at = false } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    power_brief = {
      { say = { who = "teo", text = "The other terminal's in the workshop. Dead. Everything's dead. Her log says the camp ran on that array and one battery bank." } },
      { say = { who = "teo", text = "You're the one with the claim papers. The tower's west of the hab. Claim it and the camp's grid is yours." } },
      { walk = { who = "Lindqvist", to = "mark:teotower", face = "mark:tower", speed = 1.1, secs = 30 } },
    },
    claimed = {
      { say = { who = "teo", text = "Hendry's tower again. Eleven years and it still answers to them first." } },
      { say = { who = "teo", text = "Nothing's lit. If she left it the way she left everything, the main breaker's open. Workshop, east wall." } },
      { walk = { who = "Lindqvist", to = "mark:teoshop", face = "mark:shop", speed = 1.1, secs = 30 } },
    },
    grid_up = {
      { look = { who = "teo", at = "mark:shop" } },
      { say = { who = "teo", text = "There. Her bench terminal just woke up. It's been waiting eleven years for somebody to close one switch." } },
      { look = { who = "teo", at = false } },
    },
    after_c2 = {
      { add = { cores_read = 1 } },
      { look = { who = "teo", at = "mark:shop" } },
      { face = { who = "teo", emotion = "grim", secs = 30 } },
      { wait = 2 },
      { say = { who = "teo", text = "Forty days." } },
      { say = { who = "teo", text = "The report says the pump failed and they evacuated. It doesn't say they sat here for three weeks with half a cooling system, waiting for a part." } },
      { say = { who = "teo", text = "She said yes. Of course she said yes." } },
      { look = { who = "teo", at = "crew:Haddad" } },
      { turn = { who = "Lindqvist", to = "crew:Haddad" } },
      { choice = { who = "teo", prompt = "I'm fine. I'm fine. Give me a second.",
        options = {
          { text = "Take a minute. I'll look at the bunk room.", run = "s_minute" },
          { text = "We keep moving. The light's going.", run = "s_move" },
          { text = "Hendry ordered her to sit with a failing reactor.", run = "s_say" },
        }, default = 2, timeout = 40 } },
    },
    s_minute = {
      { add = { trust = 1 } },
      { say = { who = "teo", text = "No. I'll come. I don't want to be the one standing still.", with = "me" } },
      { run = "room_brief" },
    },
    s_move = {
      { say = { who = "teo", text = "Yes. Of course. The light.", with = "me" } },
      { run = "room_brief" },
    },
    s_say = {
      { add = { trust = 1 } },
      { say = { who = "teo", text = "Say it like that to Brennan. He'll have a word for it that isn't that one.", with = "me" } },
      { run = "room_brief" },
    },
    -- ── ACT 3 ──────────────────────────────────────────────────────────────
    room_brief = {
      { look = { who = "teo", at = false } },
      { say = { who = "teo", text = "Her personal core will be in the bunk room. She kept it in a shock case under her pillow, and she only ever opened it in a sealed room. She said the dust here eats contacts." } },
      { say = { who = "teo", text = "The bunk room has no roof. The tower can ship one in. Mind the allowance: Hendry gave you twenty-four hundred, and Hendry counts." } },
    },
    short = {
      { say = { who = "brennan", text = "Ms Haddad, Brennan again. Your tower tells me the allowance won't cover the bunk room roof." } },
      { say = { who = "brennan", text = "Hendry can advance thirteen hundred against the job. The only condition is the one you already know: the remaining cores are sealed unread for counsel." } },
      { choice = { who = "brennan", prompt = "Will you take Hendry's advance?",
        options = {
          { text = "Send it.", var = { owed = true }, beats = {
            { funds = 1300 },
            { say = { who = "brennan", text = "Sent. I'm glad we understand each other." } },
            { face = { who = "teo", emotion = "worried", secs = 8 } },
            { say = { who = "teo", text = "You know what you just sold him." } } } },
          { text = "Not yet.", beats = {
            { say = { who = "brennan", text = "The offer stands. Your tower can reach me." } } } },
        }, default = 2, timeout = 30 } },
    },
    short_again = {
      { choice = { who = "brennan", prompt = "The tower's relay is open to Hendry. Brennan's advance: thirteen hundred, the cores sealed.",
        options = {
          { text = "Send it.", var = { owed = true }, beats = { { funds = 1300 }, { say = { who = "brennan", text = "Sent." } } } },
          { text = "Close the channel.", beats = {} },
        }, default = 2, timeout = 20 } },
    },
    room_shut = {
      { say = { who = "teo", text = "Roof's on. Listen to the door. That's the seal, the wind's going straight through it." } },
    },
    breathing = {
      { say = { who = "teo", text = "That's a room again. First time in eleven years." } },
      { say = { who = "teo", text = "Keep your helmet on. It's sealed, it isn't air. Same thin stuff as outside, just not moving." } },
    },
    after_c3 = {
      { add = { cores_read = 1 } },
      { walk = { who = "Lindqvist", to = "mark:teobunk", speed = 0.9, secs = 25,
                 pose = { kind = "sit", struct = "Lindqvist Camp", spot = { 0.55, 0.68, 6.1 }, toward = { 0.55, 0.68, 4.6 }, stand = "mark:teobunk" } } },
      { face = { who = "teo", emotion = "grim", secs = 40 } },
      { wait = 2 },
      { say = { who = "teo", text = "Hollis. Mira Hollis took the seat." } },
      { say = { who = "teo", text = "Hendry evacuated somebody who didn't exist, and wrote down that my mother died in the evacuation. Five names and a fatality. Six names and a decision." } },
      { look = { who = "teo", at = "crew:Haddad" } },
      { say = { who = "brennan", text = "Ms Haddad. Your tower has logged three core reads to Hendry's relay. I'll assume you've had your reasons." } },
      { say = { who = "brennan", text = "The fourth core is in the shed. Hendry's position is that it be sealed for counsel, unread, and shipped with you at first light. I'll put it plainly, because I think you'd prefer that: reading it doesn't help Mr Lindqvist, and it doesn't help you." } },
      { choice = { who = "brennan", prompt = "Will you seal the fourth core?",
        options = {
          { text = "Understood. It'll be sealed.", var = { choice4 = "seal" }, run = "b_seal" },
          { text = "No. We'll read it.", var = { choice4 = "read" }, run = "b_read" },
          { text = "It's his mother's log. Teodor decides.", var = { choice4 = "teo" }, run = "b_teo" },
        }, default = 1, timeout = 20 } },
    },
    b_seal = {
      { add = { trust = -1 } },
      { say = { who = "brennan", text = "Thank you, Ms Haddad. Hendry won't forget it." } },
      { say = { who = "teo", text = "You didn't ask me.", with = "me" } },
      { run = "night_falls" },
    },
    b_read = {
      { say = { who = "brennan", text = "Then I'll note that you were asked. Good evening, Ms Haddad." } },
      { say = { who = "teo", text = "Thank you.", with = "me" } },
      { run = "night_falls" },
    },
    b_teo = {
      { add = { trust = 1 } },
      { say = { who = "brennan", text = "Mr Lindqvist, I'm sorry for your loss. I'm still asking." } },
      { face = { who = "teo", emotion = "focus", secs = 10 } },
      { say = { who = "teo", text = "I want to hear her. I'd like to hear her once without a lawyer in the room.", with = "me" } },
      { run = "night_falls" },
    },
    night_falls = {
      { pose = { who = "Lindqvist", kind = "stand", stand = "mark:teobunk" } },
      { say = { who = "teo", text = "The shed's east of the hab. The block she mentioned in the report's appendix, the one 'disturbed in the incident'. That's where the last core is." } },
      { look = { who = "teo", at = false } },
    },
    -- ── ACT 4 ──────────────────────────────────────────────────────────────
    shed_in = {
      { cutscene = true },
      { light = { ambient = 0.35, secs = 3 } },
      { walk = { who = "Lindqvist", to = "mark:teoconsole", face = "mark:console", speed = 1.0, secs = 12 } },
      -- (the shed has no roof: the camera looks down into it over the walls)
      { shot = { orbit = "mark:shedmid", dist = 2.2, height = 2.6, turn = 40, start = 200, secs = 6, wait = false } },
      { caption = { "THE SHED", "Pump 1 · seized day 3,153, 19:40", 4 } },
      { wait = 3.5 },
      { gesture = { who = "Lindqvist", clip = "lean_console" } },
      { shot = { from = "mark:shedmid", look = "mark:teoconsole", offset = { 0, 1.7, 0 }, toOffset = { 0, 1.3, 0 }, secs = 5 } },
      { say = { who = "teo", text = "Her console. Her hand would have been here." } },
      { say = { who = "teo", text = "The roof's gone. There's nothing between this desk and the sky." } },
    },
    c4_open = {
      { branch = { var = "choice4", eq = "seal", beats = {
        { say = { who = "teo", text = "You told him it would be sealed. It's in your hands. I won't take it from you.", with = "me" } } } } },
      { choice = { who = "teo", prompt = "It's in your hands. Hendry's tape is in your pack. What are you going to do with it?",
        options = {
          { text = "Seal it for Hendry. Unread.", var = { teo_read = false }, beats = {
            { core = { seal = "c4" } },
            { run = "after_seal" } } },
          { text = "Read it.", beats = {
            { core = { read = "c4" } } } },
          { text = "Give it to Teodor.", var = { teo_read = true }, beats = {
            { add = { trust = 1 } },
            { walk = { who = "Lindqvist", to = "crew:Haddad", near = 1.2, speed = 0.8, secs = 10, wait = true } },
            { turn = { who = "Lindqvist", to = "crew:Haddad" } },
            { gesture = { who = "Lindqvist", clip = "kneel_work", secs = 6 } },
            { say = { who = "teo", text = "It's lighter than I thought it would be.", with = "me" } },
            { core = { read = "c4" } } } },
        }, default = 2, timeout = 60 } },
    },
    after_c4 = {
      { add = { cores_read = 1 } },
      { gesture = { who = "Lindqvist", clip = false } },
      { look = { who = "teo", at = "crew:Haddad" } },
      { face = { who = "teo", emotion = "grim", secs = 30 } },
      { say = { who = "teo", text = "Nine days. She was alive nine days after the date on her death certificate. They called her at noon and asked her to lie for them." } },
      { look = { who = "teo", at = "mark:ridge" } },
      { say = { who = "teo", text = "She went up on the roof." } },
      { wait = 2 },
      { look = { who = "teo", at = false } },
      -- (he walks out of the shed to the ridge she watched from, and waits there for the shuttle)
      { walk = { who = "Lindqvist", to = "mark:ridge", face = "mark:block", speed = 0.9, secs = 40, wait = true } },
    },
    after_seal = {
      { face = { who = "teo", emotion = "grim", secs = 30 } },
      { say = { who = "teo", text = "You've put tape across my mother." } },
      { say = { who = "teo", text = "I'll carry it to the shuttle. I'd like to have carried it somewhere." } },
      { walk = { who = "Lindqvist", to = "mark:ridge", face = "mark:block", speed = 0.9, secs = 40, wait = true } },
    },
    resolution = {
      { cutscene = true },
      { light = { ambient = false, time = "dawn", secs = 10 } },
      { shot = { orbit = "mark:center", dist = 42, height = 12, turn = 35, start = 150, secs = 12, wait = false } },
      { caption = { "FIRST LIGHT", "Lindqvist Camp · day 4,016", 5 } },
      { say = { who = "kestrel", text = "Haddad, Kestrel. Coming over the ridge. Ten minutes." } },
      { branch = { var = "core_c4", eq = "read",
        beats = {
          { say = { who = "teo", text = "I'm taking the cores to the agency inquiry. All four. Brennan can write to me. The relay is scheduled." } },
          { say = { who = "brennan", text = "Ms Haddad. Hendry Resources will contest the provenance of anything removed from that site. I'd keep copies. Good morning." } },
          { say = { who = "teo", text = "Mira Hollis would be sixty-one. If she's alive, she's waited eleven years for somebody to count to seven." } } },
        elseBeats = {
          { say = { who = "brennan", text = "Ms Haddad. Counsel has the case number. Hendry's records will show a clean claim and a careful contractor. That is worth something to a contractor." } },
          { say = { who = "teo", text = "I'll count them anyway. Ilse. Dimitri. Paul. June. Sam. Mira." } },
          { wait = 1.5 },
          { say = { who = "teo", text = "Mum." } } } } },
      { branch = { var = "owed", is = true, beats = {
        { say = { who = "brennan", text = "And the advance stands as agreed. Hendry keeps its word as well as its records." } } } } },
      { choice = { who = "teo", prompt = "What happens to the camp?",
        options = {
          { text = "We keep it standing. Her name stays on the tower.", var = { camp = "keep" }, beats = {
            { say = { who = "teo", text = "Lindqvist Camp. Good. Let it be useful. She'd have hated being a monument." } } } },
          { text = "We leave it the way she left it.", var = { camp = "grave" }, beats = {
            { say = { who = "teo", text = "Then nobody fixes the shed roof. Ever." } } } },
        }, default = 2, timeout = 30 } },
      { say = { who = "kestrel", text = "Wheels down. Two minutes. Bring what you're bringing." } },
      { var = { debriefed = true } },
    },
  },

  events = {
    { id = "approach", when = { kind = "at", who = "crew:Haddad", at = "mark:approach", r = 9 }, run = "approach" },
    { id = "grid_up", when = { kind = "grid", struct = "Lindqvist Camp" }, after = "claim", run = "grid_up" },
    -- the allowance short of the bunk room's roof (spent elsewhere first): Brennan's advance
    { id = "short", when = { kind = "ruin", struct = "Lindqvist Camp", lot = "bunks", restored = false, afford = false }, after = "core2", run = "short" },
    { id = "short_again", when = { kind = "at", who = "crew:Haddad", at = "mark:tower", r = 3.5 },
      also = { kind = "ruin", struct = "Lindqvist Camp", lot = "bunks", restored = false, afford = false },
      after = "core2", once = false, cooldown = 45, run = "short_again" },
    { id = "roof_on", when = { kind = "ruin", struct = "Lindqvist Camp", lot = "bunks", restored = true }, after = "core2",
      also = { kind = "piece_state", struct = "Lindqvist Camp", uid = 27, field = "blown", is = true }, run = "room_shut" },
    { id = "breathing", when = { kind = "rooms", struct = "Lindqvist Camp", sealed = 1 }, after = "room", run = "breathing" },
    { id = "shed_in", when = { kind = "at", who = "crew:Haddad", at = "mark:shedin", r = 2.6 }, after = "core3", run = "shed_in" },
  },

  steps = {
    -- ACT 1: the walk in
    { id = "walk", text = "Walk to Lindqvist Camp, north across the flats. Teodor knows the way.", act = "Act 1 · the walk in", checkpoint = true,
      mark = "mark:front",
      goals = { { kind = "at", who = "crew:Haddad", at = "mark:front", r = 4, label = "At the camp's front door" } },
      hint = "The camp is the cluster of roofless huts due north of where the shuttle left you, about sixty metres. Walk with W; the marker on the HUD is its front door.",
      hint2 = "Teodor walks ahead of you: follow his lamp." },
    { id = "core1", text = "Read the camp log on the mess terminal (walk up to it, E).", mark = "mark:mess",
      goals = { { kind = "core_read", id = "c1", label = "Core 1 · the weekly return" } },
      hint = "Through the front door: the mess is the first room. The terminal sits on the table in the middle. Walk right up to it and press E; the CORE page reads on the core's own cell, no power needed.",
      hint2 = "E again (or Esc) closes the terminal when you have read it." },
    -- ACT 2: power
    { id = "claim", text = "Claim the camp for Hendry: right-click the tower west of the hab, Claim the site.", act = "Act 2 · power", checkpoint = true,
      run = "power_brief", mark = "mark:tower",
      stage = { crew = { { name = "Haddad", title = "Engineer · Hendry contract", post = "mark:front", face = "mark:hab" },
                         { name = "Lindqvist", title = "Scientist · Agnes Lindqvist's son", post = "mark:teomess", face = "mark:mess" } },
                beats = { { state = { struct = "Lindqvist Camp", uid = 27, st = { seal = 1, blown = true } } },
                          { breaker = { struct = "Lindqvist Camp", uid = 73, closed = false } } } },
      goals = { { kind = "ruin", struct = "Lindqvist Camp", claimed = true, label = "Lindqvist Camp claimed" } },
      hint = "The tower is the lattice mast on the west side of the camp. Right-click it: Claim the site. Only an Engineer can, and you are one.",
      hint2 = "Stand within a few metres of the mast. The claim makes the camp a base: its grid, its repairs and its restore bill are yours." },
    { id = "power", text = "Bring the camp's grid up: close the main breaker in the workshop.", mark = "mark:breaker",
      on_enter = { { run = "claimed" } },
      goals = { { kind = "power_read", struct = "Lindqvist Camp", breaker = 73, state = "closed", label = "The main breaker closed" },
                { kind = "grid", struct = "Lindqvist Camp", label = "The camp's grid has power" } },
      hint = "The workshop is the room east of the mess, through the inner door. The breaker panel is on its east wall, by the window. Right-click it: Close. The array west of the hab charges the battery once the breaker is in.",
      hint2 = "Any terminal's POWER page can close it too, now the camp is claimed." },
    { id = "core2", text = "Read the workshop terminal's core, now it has power (E at the bench).", mark = "mark:shop",
      goals = { { kind = "core_read", id = "c2", label = "Core 2 · the shed log" } },
      hint = "The terminal stands on the workbench against the workshop's north wall. Walk up to it and press E: its CORE page reads now the grid is up.",
      hint2 = "If it says the cell is flat, the grid has no power: check the breaker and that the claim went through." },
    -- ACT 3: the sealed room
    { id = "room", text = "Make the bunk room tight: put its roof back (the tower's restore jobs) and re-seat the door's blown seal.", act = "Act 3 · the sealed room", checkpoint = true,
      mark = "mark:bunkdoor",
      stage = { crew = { { name = "Haddad", title = "Engineer · Hendry contract", post = "mark:shop", face = "mark:bunkdoor" },
                         { name = "Lindqvist", title = "Scientist · Agnes Lindqvist's son", post = "mark:teoshop", face = "mark:shop" } },
                ruins = { { name = "Lindqvist Camp", claimed = true } },
                beats = { { state = { struct = "Lindqvist Camp", uid = 27, st = { seal = 1, blown = true } } } } },
      goals = { { kind = "ruin", struct = "Lindqvist Camp", lot = "bunks", restored = true, label = "The bunk room's roof" },
                { kind = "piece_state", struct = "Lindqvist Camp", uid = 27, field = "blown", ne = true, label = "The door's seal re-seated" } },
      hint = "Right-click the tower: Restore: the bunk room roof ($1,300). Then the bunk-room door, north wall of the mess: go in, let it shut, right-click it: Re-seat the seal (an Engineer, about 12 s).",
      hint2 = "Spend the allowance on the bunk room first: $2,400 does not cover every roof. If it is gone, Brennan will offer an advance, at a price." },
    { id = "core3", text = "Open Agnes's shock case in the sealed bunk room (E at her bunk, the east one).", mark = "mark:bunk",
      goals = { { kind = "core_read", id = "c3", label = "Core 3 · the last night in camp" } },
      hint = "Agnes's bunk is the east one of the two. Walk up to it and press E. The case opens only while the room is sealed: the door shut behind you, its seal whole, the roof complete.",
      hint2 = "Still refused? Right-click the door: if its seal reads damaged, re-seat it. The ROOMS overlay of the Build Kit (F1 in the kit) shows whether the room closes." },
    -- ACT 4: the shed
    { id = "shed", text = "Core 4 is in the reactor shed, under the shield block that fell across it. Right the block (Repair Kit).", act = "Act 4 · the shed", checkpoint = true,
      mark = "mark:block",
      -- (the sun well down, not black: the helmet lamp and the dust carry the dark)
      on_enter = { { light = { time = -9, secs = 60 } }, { weather = { kind = "dust", secs = 30, k = 0.7 } } },
      stage = { crew = { { name = "Haddad", title = "Engineer · Hendry contract", post = "mark:bunk", face = "mark:bunkdoor" },
                         { name = "Lindqvist", title = "Scientist · Agnes Lindqvist's son", post = "mark:teobunk", face = "mark:bunk" } },
                ruins = { { name = "Lindqvist Camp", claimed = true, restore = { "bunks" } } } },
      goals = { { kind = "piece_ok", struct = "Lindqvist Camp", uid = 117, label = "The fallen block righted" } },
      hint = "The shed is the concrete building east of the hab; its double door faces south. It is dark: L is your helmet lamp. Right-click the block lying in the middle of the floor with a Repair Kit in your pack.",
      hint2 = "Out of Repair Kits? The Hendry supply drop by the front door has two more." },
    { id = "core4", text = "Take the Data Core from under the block (E). Read it, or seal it for Hendry.", mark = "mark:block",
      goals = { { kind = "core_read", id = "c4", any = true, label = "Core 4 · read or sealed" } },
      hint = "Walk up to where the block lay and press E. You choose what happens to it: Hendry's seal, your eyes, or Teodor's.",
      hint2 = "Whatever you told Brennan, the choice is still yours here." },
    { id = "dawn", text = "First light. The shuttle is coming over the ridge.", run = "resolution",
      goals = { { kind = "var", name = "debriefed", is = true, label = "First light" } },
      hint = "Nothing left to do but answer Teodor and wait for the Kestrel." },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Lindqvist Camp has another name to add to its report." },
  },

  score = {
    par = 900,          -- (the solve: 3:53 with every line clicked at 0.8 s; a player reads ~66 lines, ~9.5 min, and walks ~3 min: 15 min)
    rows = {
      { label = "Agnes's entries read", var = "cores_read", fmt = "%d of 4", par = "4", gte = 4 },
      { label = "Teodor's trust", var = "trust", fmt = "%d", par = "≥ 2", gte = 2 },
      { label = "Hendry's advance taken", var = "owed", par = "no", lte = nil },
    },
    medals = {
      gold = { time = 1.3, vars = { cores_read = { gte = 4 }, trust = { gte = 2 }, owed = { is = false } } },
      silver = { time = 2.2, vars = { cores_read = { gte = 3 } } },
      bronze = "done",
    },
  },
  after = "freeplay",
  freeplay = { contracts = false, programme = false },
  debrief = {
    gold = "Four entries read, in the order she wrote them, and Teodor heard every one with you. The camp stands, Hendry's money is Hendry's, and the inquiry has a name it never had: Mira Hollis.",
    silver = "You know most of what Agnes Lindqvist left. Some of it is in a Hendry vault, and some of it is in Teodor, who will be deciding for a long time what you owe each other.",
    bronze = "Lindqvist Camp is claimed and the shuttle is down. What the chief wrote, and what was done about it, is a matter for whoever reads the report next.",
    fail = "Lindqvist Camp is empty again.",
  },
}
