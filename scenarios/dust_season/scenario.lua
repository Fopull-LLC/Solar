-- DUST SEASON — a pre-built base under a storm (work/scenarios2/PLAN.md §1.1).
--
-- Tarrant Flats, a six-room solar survey base on a dry red CO2 world, forty
-- minutes before the first dust storm of the season. The base is real
-- (tools/gen_dust_station.lua: the hab's six rooms, the shop, the field, the
-- mast), the power is real (base_grid, base_power: twelve Solar Arrays and
-- twelve Battery Banks, the mast's 150 m bus, the shop on Beck's 2.5 mm²
-- flex run behind B-3), the storm is real weather (the `weather` beat), the
-- dust on the panels is G4's, the store's blown seal is room_air's, and the
-- cable that burns is base_power's. Two things the systems do not simulate
-- are models, as data (docs/scenarios.md §4.2): the grow room's temperature
-- (its heater, HTR-1, against the outside's −55 °C) and Beck's drive home
-- (eight kilometres he can only cover while the mast is lit). No hooks.
--
--   ACT 1  the front: Beck's radio hand-over, Wren's four degrees, a plan
--   ACT 2  the ledger: the battery through the front; B-3 and the shop run
--   ACT 3  the seal: the north store door lets go in the gusts
--   ACT 4  Beck comes home by the mast light, or waits for morning
--
-- The full dialogue for reading is work/scn_dust/SCRIPT.md (script_md.lua).
return {
  id = "dust_season", title = "Dust Season", v = 1, order = 20, minutes = 40,
  teaches = { "power", "breakers", "console", "weather", "airlock", "repair" },
  blurb = "Tarrant Flats, a solar base on a red desert, forty minutes before the first dust storm of the season. The chief is eight kilometres out with the rover, the battery is at 71 %, and the storm will sit on you for hours. Keep the right things running.",
  brief = {
    "Tarrant Flats: six rooms, a shop, twelve solar arrays and a mast, on a dry red world. Minus fifty-five outside and the air is carbon dioxide.",
    "You are Imre Szabo, the base engineer. Beck is out on the Sefton track with the rover. Wren has a seed trial in the grow room. Marlow's met office has a front coming.",
  },
  world = { seed = 731905, scale = 4, names = 2, air = "alien", home = "alien", homeSeed = 53,
            time = { at = "afternoon", hold = true } },

  cast = {
    ops   = { name = "Marlow Ops", tag = "OPS · MET", color = { 0.55, 0.85, 1.0 }, radio = true },
    beck  = { name = "Beck Oyelaran", tag = "BASE CHIEF · ON THE ROAD", crew = "Oyelaran", color = { 1.0, 0.72, 0.38 }, portrait = "auto", radio = true },
    wren  = { name = "Dr Wren Achterberg", tag = "BOTANIST · GROW ROOM", crew = "Achterberg", color = { 0.62, 0.92, 0.70 }, portrait = "auto", expression = "worried" },
    me    = { name = "Imre Szabo", tag = "ENGINEER", crew = "Szabo", color = { 0.85, 0.88, 0.95 }, portrait = "auto" },
    log   = { name = "Base Log", tag = "TERMINAL · TARRANT-1", color = { 1.0, 0.70, 0.25 } },
  },

  vars = { plan = "", shed_ok = false, read_log = false, storm = false, front_passed = false, shop_cold = false,
           b3_trips = 0, b3_armed = true, taped = false, burnt = false, spliced = false,
           grow_c = 18, grow_min = 18, trial_lost = false, batt_min = 0.71, unbreathable_s = 0,
           seal_choice = "", seal_blown = false, seal_fixed = false,
           beck_km = 8, beck_dark = 0, beck_parked = false, beck_home = false, beck_driving = false, act4 = false,
           silver_ok = false, debriefed = false, handover = false, wren_pleaded = false },

  -- METERS: the lowest the battery went until the front's core passed; the coldest
  -- the grow room got
  meters = {
    { var = "batt_min", read = "grid.battery", struct = "Tarrant Flats", mode = "min", round = 0.001,
      when = { kind = "var", name = "front_passed", is = false } },   -- (through the front: act 4's battery is the mast's problem)
    { var = "grow_min", read = "var.grow_c", mode = "min", round = 0.1 },
  },
  -- MODELS: what the systems do not simulate
  models = {
    -- the grow room: with HTR-1 running (switched on and served) it settles
    -- at 18 °C; without it the room falls toward the outside's −55 °C,
    -- Newton's law with τ = 2250 s (18 → 4 °C in about eight minutes):
    -- rate · (1 + accel · (v − base)) = −(v + 55) / 2250 with accel 1, base −54
    { var = "grow_c", start = 18, rate = -0.000444, accel = 1, base = -54, rest = 18, tau = 600, min = -55, max = 18, round = 0.1,
      when = { kind = "piece_state", struct = "Tarrant Flats", uid = 130, field = "running", is = false } },
    -- Beck's drive: he sits out the front's core behind the Sefton ridge, then
    -- eight kilometres at eighteen an hour, only while the mast is lit (its
    -- floodlights are what he steers by, and the tower is his radio: a ground
    -- station needs its power); parked for the night, he stays parked
    { var = "beck_km", start = 8, rate = -0.005, min = 0, round = 0.01,
      active = { kind = "var", name = "beck_driving", is = true },
      when = { kind = "piece_state", struct = "Mast", uid = 1, field = "running", is = true } },
    -- the mast dark: four minutes of it and Beck parks for the night
    { var = "beck_dark", start = 0, rate = 1, rest = 0, tau = 5, min = 0, round = 1,
      active = { kind = "var", name = "beck_driving", is = true },
      when = { kind = "piece_state", struct = "Mast", uid = 1, field = "running", is = false },
      at = { { value = 60, run = "mast_dark" }, { value = 240, run = "beck_parks" } } },
    -- the time the hab's biggest room has been unbreathable (a score row)
    { var = "unbreathable_s", start = 0, rate = 1, round = 1,
      when = { kind = "room_air", struct = "Tarrant Flats", room = "largest", breathable = false } },
  },
  failure = "checkpoint",

  start = {
    funds = 2500, rp = 0, safety = "death",
    contracts = false, programme = false, ruins = false, weather = "clear",
    crew = {
      { name = "Szabo", role = "engineer", title = "Base engineer", control = true,
        where = { body = "home", site = "far_flat" }, post = "mark:start", face = "mark:desk",
        pack = { { item = "repairkit" } } },
      { name = "Achterberg", role = "scientist", title = "Botanist · seed trial",
        where = { body = "home", site = "far_flat", offset = { 1, 0, 0 } }, post = "mark:wren", face = "mark:bench" },
    },
    structures = {
      -- (the crew are sited on open ground 10 m north-west of the hab, then
      -- set at their posts once it stands: never under its slabs)
      { bp = "dust_season/hab.bp.txt", name = "Tarrant Flats", at = "crew:Szabo", offset = { 10, 0, -10 }, yaw = 0, powered = 0.71, air = true },
      { bp = "dust_season/field.bp.txt", name = "South Field", at = "struct:Tarrant Flats", offset = { 0, 0, -30 }, yaw = 0 },
      { bp = "dust_season/mast.bp.txt", name = "Mast", at = "struct:Tarrant Flats", offset = { 0, 0, 45 }, yaw = 0 },
      { bp = "dust_season/shop.bp.txt", name = "Workshop", at = "struct:Tarrant Flats", offset = { 95, 0, -95 }, yaw = 0 },
    },
    -- before the run joins the shop to the grid: the shop's fourth heater is
    -- its thermostat's last stage (off for now), and B-3's trip dial is where
    -- Beck set it, Ir 0.4 (10.1 kW), a hair over the flex's rating
    states = {
      { struct = "Workshop", uid = 26, st = { off = true } },
      { struct = "Tarrant Flats", uid = 150, st = { ir = 0.4 } },
    },
    -- the shop run: Beck's 2.5 mm² flex from B-3 on the grow room's east wall
    -- to the shop's junction box, 125 m over the flats
    cables = {
      { from = { struct = "Tarrant Flats", uid = 150 }, to = { struct = "Workshop", uid = 36 }, ty = "lv2" },
    },
    tags = {
      { struct = "Tarrant Flats", uid = 150, name = "B-3" },
      { struct = "Tarrant Flats", uid = 112, name = "HAB MAIN" },
      { struct = "Tarrant Flats", uid = 130, name = "HTR-1" },
      { struct = "Tarrant Flats", uid = 96, name = "NORTH DOOR" },
      { struct = "Workshop", uid = 23, name = "SHOP HTR-1" },
      { struct = "Workshop", uid = 24, name = "SHOP HTR-2" },
      { struct = "Workshop", uid = 25, name = "SHOP HTR-3" },
      { struct = "Workshop", uid = 26, name = "SHOP HTR-4" },
    },
    marks = {
      -- (offsets in the hab's own frame: x east, z north)
      center  = { at = "struct:Tarrant Flats", offset = { -1, 0, 0 } },
      start   = { at = "struct:Tarrant Flats", offset = { -2.6, 0, 1.0 } },
      desk    = { at = "struct:Tarrant Flats", offset = { -4.0, 0, 2.45 } },
      console = { at = "struct:Tarrant Flats", offset = { -4.0, 0, 1.55 } },
      wren    = { at = "struct:Tarrant Flats", offset = { 4.05, 0, -1.55 } },
      bench   = { at = "struct:Tarrant Flats", offset = { 4.05, 0, -2.5 } },
      wrenwatch = { at = "struct:Tarrant Flats", offset = { 2.3, 0, 0.6 } },
      growdoor = { at = "struct:Tarrant Flats", offset = { 0.2, 0, 1.0 } },
      heater  = { at = "struct:Tarrant Flats", offset = { 6.0, 0, -0.9 } },
      main    = { at = "struct:Tarrant Flats", offset = { -4.0, 0, -2.2 } },
      b3      = { at = "struct:Tarrant Flats", offset = { 7.9, 0, -2.0 } },
      store   = { at = "struct:Tarrant Flats", offset = { 1.55, 0, 4.0 } },
      northdoor = { at = "struct:Tarrant Flats", offset = { 1.55, 0, 6.0 } },
      lockout = { at = "struct:Tarrant Flats", offset = { -1.5, 0, -6.8 } },
      lockin  = { at = "struct:Tarrant Flats", offset = { -1.55, 0, -4.0 } },     -- in the airlock's chamber
      bunk    = { at = "struct:Tarrant Flats", offset = { -3.0, 0, 5.4 } },
      beckin  = { at = "struct:Tarrant Flats", offset = { -6, 0, -22 } },
      beckops = { at = "struct:Tarrant Flats", offset = { -1.6, 0, -1.2 } },
      field   = { at = "struct:South Field", offset = { 0, 0, -6 } },
      panel   = { at = "struct:South Field", offset = { -6, 0, 1.6 } },
      mast    = { at = "struct:Mast", offset = { 0, 0, 0 } },
      mastfoot = { at = "struct:Mast", offset = { 6, 0, -4 } },
      shop    = { at = "struct:Workshop", offset = { 0, 0, 3 } },
      camne   = { at = "struct:Tarrant Flats", offset = { 26, 0, 22 } },
      camsw   = { at = "struct:Tarrant Flats", offset = { -24, 0, -34 } },
      camstore = { at = "struct:Tarrant Flats", offset = { 6.5, 0, 9.5 } },
      cammast = { at = "struct:Mast", offset = { -10, 0, -14 } },
    },
  },

  on_start = {
    { gesture = { who = "Achterberg", clip = "lean_console" } },
    { run = "arrival" },
  },

  sequences = {
    -- ── ACT 1 ──────────────────────────────────────────────────────────────
    arrival = {
      { cutscene = true },
      { shot = { orbit = "mark:center", dist = 60, height = 22, turn = 60, start = 210, secs = 9, wait = false } },
      { caption = { "DUST SEASON", "Tarrant Flats · 16:20 local · the front is forty minutes out", 6, kind = "story" } },
      { wait = 4 },
      { say = { who = "ops", text = "Tarrant, Marlow Ops, met desk. Your front is forty minutes out, wind to thirty, optical depth past six by dark. It will sit on you for a couple of hours. Marlow out." } },
      { shot = { from = "mark:camsw", to = "mark:field", look = "mark:center", offset = { 0, 5, 0 }, toOffset = { 0, 3, 0 }, secs = 6 } },
      { shot = { from = "mark:cammast", look = "mark:mast", offset = { 0, 2, 0 }, toOffset = { 0, 9, 0 }, secs = 3 } },
    },
    handover = {
      { say = { who = "beck", text = "Imre. Beck. Tell me you can hear me over this, because I can barely hear me." } },
      { say = { who = "me", text = "Loud enough." } },
      { say = { who = "beck", text = "Good. I'm eight k out on the Sefton track and the front's going to land between us. I'll crawl in on the mast light. So the mast stays lit. Whatever else you do." } },
      { say = { who = "beck", text = "Battery's at seventy-one. The field goes to a trickle for as long as the front sits on you, call it two hours. Two hours on seventy-one per cent." } },
      { look = { who = "wren", at = "crew:Szabo" } },
      { walk = { who = "Achterberg", to = "crew:Szabo", near = 1.4, speed = 1.2, secs = 16, wait = true } },
      { turn = { who = "Achterberg", to = "crew:Szabo" } },
      { face = { who = "wren", emotion = "worried", secs = 40 } },
      { say = { who = "wren", text = "Sorry. Sorry, I heard the word battery through the door.", with = "me" } },
      { gesture = { who = "Achterberg", clip = "stand_talk", secs = 12 } },
      { say = { who = "wren", text = "The trial's in its fourth week. Under four degrees the seedlings stop, and they don't start again. The heater is three kilowatts. That's all it is.", with = "me", cross = true } },
      { say = { who = "beck", text = "And the shop's nine, the mast's two, life support's two, and I'm doing sums on a steering wheel. Your call, Imre. I'm not there." } },
      { var = { handover = true } },
      { choice = { who = "beck", prompt = "What do we shed?",
        options = {
          { text = "The grow room. HTR-1 off, now.", var = { plan = "grow" }, run = "plan_grow" },
          { text = "The shop. I'll open B-3.", var = { plan = "shop" }, run = "plan_shop" },
          { text = "Nothing yet. We ride the battery and watch it.", var = { plan = "ride", shed_ok = true }, run = "plan_ride" },
        }, default = 2, timeout = 60 } },
    },
    plan_grow = {
      { face = { who = "wren", emotion = "tired", secs = 20 } },
      { say = { who = "wren", text = "All right. No, that's the sensible answer. I'll write it up as a storm loss. I'll write it up very neatly.", with = "me" } },
      { say = { who = "beck", text = "Sorry, Wren. Imre, HTR-1's the heater on the grow room's east wall, or the POWER page on the console." } },
      { objective = { step = "shed", text = "Shed the grow room: switch HTR-1 off (right-click the heater, or the console's POWER page)." } },
      { run = "wren_back" },
    },
    plan_shop = {
      { face = { who = "wren", emotion = "relief", secs = 10 } },
      { say = { who = "wren", text = "Thank you. I know what it costs you out there.", with = "me" } },
      { say = { who = "beck", text = "The shop will be a fridge by morning. The drill packs can take minus twenty. Probably. B-3's on the grow room's east wall outside, or open it from the console." } },
      { objective = { step = "shed", text = "Shed the shop: open B-3 (the console's POWER page, or the panel on the grow room's east wall)." } },
      { run = "wren_back" },
    },
    plan_ride = {
      { face = { who = "wren", emotion = "worried", secs = 15 } },
      { say = { who = "beck", text = "Bold. I like bold, from eight k away. Watch the number, Imre. If it goes under thirty, you shed, and you don't argue with yourself about it." } },
      { say = { who = "wren", text = "I'll keep the door shut. Doors are free.", with = "me" } },
      { run = "wren_back" },
    },
    wren_back = {
      { look = { who = "wren", at = false } },
      { walk = { who = "Achterberg", to = "mark:wren", face = "mark:bench", speed = 1.1, secs = 25 } },
      { gesture = { who = "Achterberg", clip = "lean_console" } },
      { say = { who = "beck", text = "One more thing. My log's on the console, the LOG page. Read item three before the wind does." } },
    },
    read_log = {
      { var = { read_log = true } },
      { say = { who = "log", text = "09:12  B.O.  Field washed down. 38 kW at noon, all twelve tracking. Battery bank 6 cell temps high, watching it." } },
      { say = { who = "log", text = "11:40  B.O.  Shop run: 2.5 mm² flex, 125 m, temporary. The 35 mm² drum is still on the supply list. Shop heaters on the thermostat, three stages, four in a cold snap." } },
      { say = { who = "log", text = "12:05  B.O.  B-3 nuisance-trips above 10 kW. Did not fix. Do not tape it. North store door seal weeping again: re-seat when the kit's back." } },
      { say = { who = "log", text = "13:30  B.O.  Out to Sefton for the seismic pods. Back before the front. Imre has the base." } },
    },
    -- the front arrives: the weather beat ramps the sky over 90 s
    front = {
      { cutscene = true },
      { weather = { kind = "duststorm", secs = 90 } },
      { light = { time = "evening", secs = 80 } },
      { var = { storm = true } },
      { shot = { from = "mark:camne", look = "mark:center", offset = { 0, 6, 0 }, toOffset = { 0, 3, 0 }, secs = 7, wait = false } },
      { caption = { "17:02", "the front", 4, kind = "alarm" } },
      { say = { who = "ops", text = "Tarrant, Marlow. The front's on your coordinates. We'll lose you in the static in a minute. Good luck. Marlow out." } },
      { say = { who = "wren", text = "It's gone dark in here. The grow lamps are the only light for a kilometre." } },
      { shot = { from = "mark:camsw", look = "mark:field", offset = { 0, 3, 0 }, toOffset = { 0, 1, 0 }, secs = 4 } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    ledger = {
      { say = { who = "beck", text = "Front's on me too. I can see about as far as my own knees. Talk to me about the number, Imre." } },
      { objective = { step = "hold", text = "Hold the base through the front. Keep the battery off the floor, the mast lit, and the console's POWER page open. (Time warp: the . key.)" } },
    },
    b60 = { { say = { who = "beck", text = "What's the number?" } }, { say = { who = "me", text = "Sixty." } }, { say = { who = "beck", text = "Sixty. Fine. Sixty's a number with a future." } } },
    b45 = { { say = { who = "wren", text = "The console says forty-five. Is forty-five bad? You've gone quiet. You go quiet when it's bad." } } },
    b35 = { { say = { who = "beck", text = "Thirty-five. That's the line, Imre. Shed something or tell me why not." } } },
    b20 = { { alarm = true }, { say = { who = "beck", text = "Twenty. Below twenty the banks start dropping loads on their own and they won't ask you which. Shed now." } }, { alarm = false } },
    b05 = { { say = { who = "wren", text = "The lights in here just went. The heater's stopped. Imre, the heater's stopped." } } },
    -- the shop's thermostat calls for its last stage (the cold behind the front)
    shop_cold = {
      { var = { shop_cold = true } },
      { state = { struct = "Workshop", uid = 26, st = { off = false } } },
      { say = { who = "beck", text = "Shop'll be getting cold. Thermostat brings the fourth heater in about now. That's twelve kilowatts down that flex." } },
    },
    b3_tripped = {
      { add = { b3_trips = 1 } },
      { var = { b3_armed = false } },
      { branch = { var = "b3_trips", eq = 1,
        beats = { { say = { who = "beck", text = "B-3 went, didn't it. I can hear it in your breathing. It does that. It trips, you reset it, it trips." } },
                  { say = { who = "beck", text = "Don't tape it." } } },
        elseBeats = { { say = { who = "wren", text = "That clunk again. The panel outside, the one by my window." } } } } },
      { objective = { step = "hold", text = "B-3 has tripped: the shop is cold. Shed a shop heater (the console's POWER page) and reset B-3, or leave the shop off." } },
    },
    taped = {
      { var = { taped = true } },
      { say = { who = "beck", text = "Imre. The console shows me B-3's dial. Tell me you didn't turn it up." } },
      { say = { who = "me", text = "It kept tripping." } },
      { say = { who = "beck", text = "It kept tripping because that flex is a two-and-a-half. Turn it back down." } },
    },
    burnt = {
      { cutscene = true },
      { alarm = true },
      { shot = { from = "mark:b3", look = "mark:shop", offset = { 1, 1.5, 2 }, toOffset = { 0, 1, 0 }, secs = 3.5, wait = false } },
      { say = { who = "wren", text = "There's a smell. Like a kettle with no water in it. Is that coming from outside?" } },
      { say = { who = "beck", text = "That's the flex. That's my flex cooking. Get the load off it and splice it, Imre. Right-click its end at B-3." } },
      { alarm = false },
      { objective = { step = "hold", text = "The shop run has burnt through. Get a shop heater off, turn B-3's dial back down, and splice the cable (right-click B-3: Splice)." } },
    },
    spliced = {
      { say = { who = "beck", text = "Spliced. And the dial's down? Then it'll trip before it cooks. That's what it's for." } },
    },
    grow12 = { { say = { who = "wren", text = "Twelve degrees in here. I've put my coat over the trays. That's not a joke, I really have." } } },
    grow8 = { { say = { who = "wren", text = "Eight. They're slowing. I can see it in the leaves, the edges go dull." } } },
    grow4 = {
      { var = { trial_lost = true } },
      { face = { who = "wren", emotion = "tired", secs = 30 } },
      { say = { who = "wren", text = "Four. That's it, then. Four weeks. I'll keep taking the readings. Someone should." } },
    },
    beck8 = { { say = { who = "beck", text = "Six k. Doing eighteen an hour on dead reckoning and faith." } } },
    beck5 = { { say = { who = "beck", text = "Five k. I'm on the mast light now. It's a smudge, but it's my smudge. Keep it on." } } },
    beck2 = { { say = { who = "beck", text = "Two. I can see it. Red mast, white light on top. Put the kettle on, Imre." } } },
    mast_dark = { { say = { who = "beck", text = "Imre, I've lost the mast. I've lost the mast and the radio's going funny. Is it dark?" } } },
    beck_parks = {
      { var = { beck_parked = true, beck_driving = false } },
      { say = { who = "beck", text = "I'm parking. I'm not driving into a crater I can't see. I'll come in at first light. Keep the heaters on for me, the ones you've got left." } },
    },
    beck_home = {
      { var = { beck_home = true, beck_driving = false } },
      { say = { who = "beck", text = "I'm at the airlock. I'm at the actual airlock. Somebody open it before I cry." } },
    },
    front_thins = {
      { var = { front_passed = true, beck_driving = true } },
      { weather = { kind = "dust", secs = 120 } },
      { say = { who = "ops", text = "Tarrant, Marlow. You're back on the scope. The front's core is past you. Gusts behind it, forty plus, for an hour. Marlow out." } },
      { say = { who = "beck", text = "Core's past me too. I'm rolling. Eight k, mast light all the way. Keep it lit." } },
      { say = { who = "beck", text = "And the field's under a crust after that. The POWER page'll tell you how bad. If the battery's thin, take a cloth to the panels before I need the mast." } },
    },
    -- ── ACT 3 ──────────────────────────────────────────────────────────────
    seal = {
      { cutscene = true },
      { shot = { from = "mark:camstore", look = "mark:northdoor", offset = { 0, 2.6, 0 }, toOffset = { 0, 1.2, 0 }, secs = 3, wait = false } },
      { weather = { kind = "duststorm", secs = 6 } },
      { sound = "audio/foley/latch_clunk.ogg" },
      { state = { struct = "Tarrant Flats", uid = 96, st = { seal = 1, blown = true } } },
      { var = { seal_blown = true } },
      { alarm = true },
      { say = { who = "wren", text = "What was that. The store. That was the store door, Imre, I felt it in my ears." } },
      { shot = { from = "mark:wrenwatch", look = "mark:store", offset = { 0, 1.6, 0 }, toOffset = { 0, 1.2, 0 }, secs = 3 } },
      { alarm = false },
      { weather = { kind = "dust", secs = 40 } },
    },
    seal_q = {
      { say = { who = "wren", text = "The inner door's holding. I think it's holding. The console says the store's venting. Everything in it is going to freeze." } },
      { choice = { who = "wren", prompt = "What do we do?",
        options = {
          { text = "Leave it. The inner door holds. We lose the store till morning.", var = { seal_choice = "off" }, run = "seal_off" },
          { text = "I'm going out to it. Helmet on, round the outside, re-seat the seal.", var = { seal_choice = "fix" }, run = "seal_fix" },
        }, default = 2, timeout = 40 } },
    },
    seal_off = {
      { say = { who = "wren", text = "Then nobody opens that door. I'll put a chair against it. I know a chair won't do anything. I'm putting a chair against it." } },
      { say = { who = "beck", text = "Sensible. Boring. My favourite kind of decision." } },
    },
    seal_fix = {
      { say = { who = "wren", text = "In this? You'll be walking blind. Keep your hand on the wall the whole way round, please." } },
      { say = { who = "beck", text = "Out the south airlock, left, along the west wall, round the bunk room. The north door's past the porthole. Count your steps." } },
      { say = { who = "beck", text = "And lock it before you touch the seal. The store's empty now, so that door'll open for anyone who walks up to it, and you can't seat a seal on an open door." } },
      { objective = { step = "seal", text = "Helmet on (H). Out through the south airlock, round the outside to the NORTH DOOR. Lock it (its menu, or the console's DOORS page), then re-seat its seal (right-click it, Engineer 12 s)." } },
    },
    seal_done = {
      { var = { seal_fixed = true } },
      { say = { who = "wren", text = "The console says the store's holding pressure. The bottle rack's refilling it. You can come in now. You can come in now, Imre." } },
    },
    -- ── ACT 4 ──────────────────────────────────────────────────────────────
    beck_arrives = {
      { cutscene = true },
      { spawn = { crew = { name = "Oyelaran", role = "engineer", title = "Base chief", where = { body = "home", site = "far_flat", offset = { -2, 0, 0 } }, post = "mark:beckin" } } },
      { shot = { from = "mark:lockout", look = "mark:beckin", offset = { 2, 2.2, -3 }, toOffset = { 0, 1.4, 0 }, secs = 4, wait = false } },
      { walk = { who = "Oyelaran", to = "mark:lockout", speed = 1.1, secs = 14, wait = true } },
      { say = { who = "beck", text = "Eleven hours in a rover with a broken heater seat. I've never loved a mast more." } },
      { walk = { who = "Oyelaran", to = "mark:beckops", speed = 1.0, secs = 2 } },
      { var = { act4 = true } },
    },
    beck_waits = {
      { say = { who = "beck", text = "First light's in an hour. I'm eating the emergency chocolate. All of it." } },
      { var = { act4 = true } },
    },
    resolution = {
      { cutscene = true },
      { alarm = false },
      { weather = { kind = "clear", secs = 30 } },
      { light = { time = "dawn", secs = 30 } },
      { shot = { orbit = "mark:center", dist = 52, height = 16, turn = 45, start = 20, secs = 11, wait = false } },
      { caption = { "06:10", "Tarrant Flats · the morning after", 5, kind = "story" } },
      { say = { who = "log", text = "06:10  I.S.  Front passed 02:40. Field under dust, output low. All crew accounted for." } },
      { branch = { var = "beck_home", is = true,
        beats = { { say = { who = "beck", text = "Field's under a centimetre of it. The cloths are in the store. We'll do them after coffee. A lot of coffee." } } },
        elseBeats = { { say = { who = "beck", text = "Morning. I can see you now. I'll be in in twenty minutes. Nobody touch my chocolate. There is no chocolate." } } } } },
      { branch = { var = "trial_lost", is = false,
        beats = { { say = { who = "wren", text = "They're fine. All eight trays. One of them has put out a leaf overnight, as if nothing happened. They don't know it was a storm." } } },
        elseBeats = { { say = { who = "wren", text = "I've bagged them for the lab. Someone will want to know exactly how they died. I'll start again next season. I'm already planning it, which is the only way I know how to be sad." } } } } },
      { branch = { var = "burnt", is = true,
        beats = { { say = { who = "beck", text = "And you taped B-3. I wrote it in capitals. Capital letters, Imre. That flex was the only thing cheaper than a fire." } } },
        elseBeats = { { branch = { var = "b3_trips", gt = 0,
          beats = { { say = { who = "beck", text = "B-3 tripped on you and you let it. Good. That flex is a two-and-a-half I ran in a hurry. B-3 was the only thing between it and a fire. I'll order the drum." } } },
          elseBeats = { { say = { who = "beck", text = "B-3 never went. Either you shed the shop or you were lucky. Don't tell me which." } } } } } } } },
      { branch = { var = "seal_fixed", is = true,
        beats = { { say = { who = "beck", text = "And you went round to the north door in that. In the dark. I'd shout at you, but it's my seal, and I didn't do it either." } } },
        elseBeats = { { branch = { var = "seal_blown", is = true,
          beats = { { say = { who = "beck", text = "Store's at minus fifty. Everything in it's a brick. We'll re-seat it after coffee. Right call, last night." } } } } } } } },
      { say = { who = "ops", text = "Tarrant, Marlow Ops. Good to hear all three of you. Next front's in nine days. Marlow out." } },
      { var = { debriefed = true } },
    },
  },

  events = {
    -- the hand-over starts when the arrival cutscene lets go
    { id = "log_open", when = { kind = "terminal", struct = "Tarrant Flats", page = "LOG" }, run = "read_log" },
    -- the plan done by hand
    { id = "shed_grow", when = { kind = "piece_state", struct = "Tarrant Flats", uid = 130, on = false },
      also = { kind = "var", name = "plan", eq = "grow" }, beats = { { var = { shed_ok = true } } } },
    { id = "shed_shop", when = { kind = "power_read", struct = "Tarrant Flats", breaker = 150, state = "open" },
      also = { kind = "var", name = "plan", eq = "shop" }, beats = { { var = { shed_ok = true } } } },
    { id = "front", when = { kind = "timer", secs = 20, from = "step:power" }, run = "front" },
    -- the battery as the front eats it
    { id = "b60", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.60 }, after = "power", run = "b60" },
    { id = "b55", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.55 }, after = "power", run = "shop_cold" },
    { id = "b45", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.45 }, after = "power", run = "b45" },
    { id = "b35", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.35 }, after = "power", run = "b35" },
    { id = "b20", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.20 }, after = "power", run = "b20" },
    { id = "b05", when = { kind = "power_read", struct = "Tarrant Flats", battery_below = 0.02 }, after = "power", run = "b05" },
    -- B-3: every trip counted (armed again when it is closed)
    { id = "b3trip", when = { kind = "power_read", struct = "Tarrant Flats", breaker = 150, state = "tripped" },
      also = { kind = "var", name = "b3_armed", is = true }, once = false, run = "b3_tripped" },
    { id = "b3reset", when = { kind = "power_read", struct = "Tarrant Flats", breaker = 150, state = "closed" },
      also = { kind = "var", name = "b3_armed", is = false }, once = false, beats = { { var = { b3_armed = true } } } },
    { id = "taped", when = { kind = "piece_state", struct = "Tarrant Flats", uid = 150, field = "ir", gt = 0.45 }, run = "taped" },
    { id = "burnt", when = { kind = "power_read", struct = "Workshop", burnt = true }, run = "burnt", beats = { { var = { burnt = true } } } },
    { id = "spliced", when = { kind = "power_read", struct = "Workshop", burnt = false }, also = { kind = "var", name = "burnt", is = true }, run = "spliced",
      beats = { { var = { spliced = true } } } },
    -- the models' readings (as events on their variables: the probe saw a
    -- model's downward `at` crossings never fire in the engine here)
    { id = "grow12", when = { kind = "var", name = "grow_c", lte = 12 }, run = "grow12" },
    { id = "grow8", when = { kind = "var", name = "grow_c", lte = 8 }, run = "grow8" },
    { id = "grow4", when = { kind = "var", name = "grow_c", lte = 4 }, run = "grow4" },
    { id = "beck6", when = { kind = "var", name = "beck_km", lte = 6 }, run = "beck8" },
    { id = "beck5", when = { kind = "var", name = "beck_km", lte = 5 }, run = "beck5" },
    { id = "beck2", when = { kind = "var", name = "beck_km", lte = 2 }, run = "beck2" },
    { id = "beck0", when = { kind = "var", name = "beck_km", lte = 0.01 }, also = { kind = "var", name = "beck_parked", is = false }, run = "beck_home" },
    -- the front: twenty-five minutes of it from the hold's start
    { id = "thins", when = { kind = "timer", secs = 1500, from = "step:hold" }, run = "front_thins" },
    -- act 3: the seal, two minutes after the front's core passes
    { id = "seal", when = { kind = "timer", secs = 30, from = "step:gusts" }, run = "seal" },
    { id = "seal_q", when = { kind = "var", name = "seal_blown", is = true }, run = "seal_q" },
    { id = "seal_done", when = { kind = "piece_state", struct = "Tarrant Flats", uid = 96, field = "blown", is = false },
      also = { kind = "var", name = "seal_blown", is = true }, run = "seal_done" },
    -- act 4
    { id = "beck_in", when = { kind = "var", name = "beck_home", is = true }, after = "gusts", run = "beck_arrives" },
    { id = "beck_wait", when = { kind = "var", name = "beck_parked", is = true }, after = "gusts", run = "beck_waits" },
  },

  steps = {
    -- ACT 1: the front
    { id = "handover", text = "Beck is on the radio. Hear him out.", run = "handover", act = "Act 1 · the front",
      goals = { { kind = "var", name = "handover", is = true, label = "Beck's hand-over" } },
      hint = "Beck is calling from the rover. Let the lines run (Enter), and when he asks, pick a plan with the number keys." },
    { id = "shed", text = "Carry out the plan.",
      goals = { { kind = "var", name = "shed_ok", is = true, label = "The plan carried out" } },
      hint = "The console (the Desk Monitor on the ops room's north wall): press E, then the POWER page. Its HEATERS list switches HTR-1; its BREAKERS list opens B-3.",
      hint2 = "Or by hand: HTR-1 is the heater on the grow room's east wall (right-click: Heater). B-3 is the breaker panel outside on the grow room's east wall." },
    { id = "log", optional = true, text = "(optional) Read Beck's log: the console's LOG page.", mark = "mark:desk",
      goals = { { kind = "var", name = "read_log", is = true, label = "Beck's log" } },
      hint = "The Desk Monitor on the ops room's north wall: walk up, press E, and pick the LOG page (TAB or the number keys)." },
    { id = "power", text = "Watch the field: the console's POWER page.", mark = "mark:console",
      goals = { { kind = "terminal", struct = "Tarrant Flats", page = "POWER", label = "The POWER page open" } },
      hint = "Walk up to the Desk Monitor (ops, north wall) and press E; pick POWER. It shows what the field makes, what the base draws, the store, and the panels' dust and sky." },
    -- ACT 2: the ledger
    { id = "hold", text = "Hold the base through the front.", act = "Act 2 · the ledger", checkpoint = true, run = "ledger",
      stage = { beats = { { weather = { kind = "duststorm", secs = 5 } }, { var = { storm = true } } } },
      goals = { { kind = "var", name = "front_passed", is = true, label = "The front's core past" } },
      hint = "Keep the POWER page open (E at the console). Time warp (the . key) brings the front through. Shed if the store falls: HTR-1, B-3, the shop heaters, the lights. Keep the mast lit: Beck steers by it.",
      hint2 = "If B-3 trips, the shop run is over its rating: switch a shop heater off on the POWER page before you reset B-3. Turning its dial up only moves the fire into the cable." },
    -- ACT 3: the seal
    { id = "gusts", text = "The gusts behind the front. Stay on the board.", act = "Act 3 · the seal", checkpoint = true,
      stage = { beats = { { weather = { kind = "dust", secs = 5 } }, { var = { storm = true, front_passed = true, beck_driving = true } } } },
      goals = { { kind = "var", name = "seal_choice", ne = "", label = "The north door" } },
      hint = "Something will give in the gusts. Listen to Wren, then decide.",
      hint2 = "The store is north of the grow room; its outer door is the NORTH DOOR." },
    { id = "seal", text = "Re-seat the north door's seal, or leave the store sealed off.",
      goals = { { kind = "var", name = "seal_fixed", is = true, label = "The north door's seal" } },
      on_enter = { { branch = { var = "seal_choice", eq = "off", beats = { { var = { seal_fixed = false } }, { goto = "home" } } } } },
      mark = "mark:northdoor",
      hint = "Helmet on (H). Out through the airlock (the south door of the ops room), turn left, follow the west wall round the galley and the bunk room to the north side. The NORTH DOOR is past the porthole. With the store empty of air it opens as you come near: right-click it and Lock it, then Re-seat the seal.",
      hint2 = "Stay on the outside: the inner door from the grow room is held shut by the pressure, and forcing it vents the grow room with Wren in it." },
    -- ACT 4: Beck comes home
    { id = "home", text = "Bring Beck home: keep the mast lit.", act = "Act 4 · the mast light", checkpoint = true,
      stage = { beats = { { weather = { kind = "dust", secs = 5 } }, { var = { storm = true, front_passed = true } } } },
      on_enter = { { branch = { var = "beck_parked", is = false, beats = { { var = { beck_driving = true } } } } },
                   { weather = { kind = "overcast", secs = 180 } } },
      mark = "mark:mast",
      goals = { { kind = "var", name = "act4", is = true, label = "Beck" } },
      hint = "Beck drives only while the mast is lit: its floodlights and the tower are on the grid. Keep the battery up (the POWER page) and the mast served. Time warp brings him in.",
      hint2 = "The front left the field caked: walk out to the South Field and wipe its panels (right-click a Solar Array: Wipe the panel, 10 s each), and shed what you can spare. A flat battery puts the mast out." },
    { id = "morning", text = "Morning.", run = "resolution",
      on_enter = { { branch = { var = "beck_home", is = true, beats = { { var = { silver_ok = true } } } } },
                   { branch = { var = "trial_lost", is = false, beats = { { var = { silver_ok = true } } } } } },
      goals = { { kind = "var", name = "debriefed", is = true, label = "The morning" } },
      hint = "Nothing left to do. Watch the morning come up." },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Tarrant Flats lost one of its crew in the storm." },
    { kind = "room_unbreathable", struct = "Tarrant Flats", room = "largest", secs = 90, text = "The hab's biggest room was unbreathable for ninety seconds." },
  },

  score = {
    par = 3600,         -- (game seconds, from the solve: 60:32 with the front and the drive warped)
    rows = {
      { label = "Battery, lowest", var = "batt_min", fmt = "%.2f", par = "≥ 0.20", gte = 0.20 },
      { label = "Grow room, coldest", var = "grow_min", fmt = "%.1f °C", par = "≥ 4 °C", gte = 4 },
      { label = "Hab unbreathable", var = "unbreathable_s", fmt = "%.0f s", par = "0 s", lte = 0 },
      { label = "B-3 trips", var = "b3_trips", fmt = "%d" },
      { label = "North door re-seated", var = "seal_fixed", par = "yes" },
      { label = "Beck home", var = "beck_home", par = "yes" },
    },
    medals = {
      gold = { time = 1.5, vars = { batt_min = { gte = 0.20 }, trial_lost = { is = false }, seal_fixed = { is = true }, beck_home = { is = true }, burnt = { is = false } } },
      silver = { time = 2.5, vars = { silver_ok = { is = true } } },
      bronze = "done",
    },
  },
  after = "freeplay",
  freeplay = { contracts = false, programme = false },
  debrief = {
    gold = "Every light that mattered stayed on. The trial lived, the store holds, Beck came in on the mast light, and B-3 did its job.",
    silver = "The base is standing and someone is glad about it. Beck has a list for you; it is not long.",
    bronze = "Tarrant Flats made it to morning. Read Beck's log again before the next front.",
    fail = "Tarrant Flats went dark in the storm.",
  },
}
