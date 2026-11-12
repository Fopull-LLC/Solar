-- GRAVEYARD SHIFT — the flagship story scenario (docs/scenarios.md).
--
-- A night shift at Kerne Station, a reactor outpost on the dark side of a cold
-- world with a little thin air. The plant is real (reactor_plant: a 320 kW
-- light-water core, two coolant pumps, a pressuriser, a steam generator, a
-- 100 kW turbine, eight radiator panels, two feed pumps; tools/
-- gen_graveyard_station.lua builds it and checks the loops close), the rooms
-- are real (room_air), the alarms are logic (the console's TRIPPED wired to two
-- beacons), the break is a real loss of coolant (15 % of the PL-7 spool's
-- bore), and the dose is the dose model's.
--
--   ACT 1  hand-over: Dana Kowalczyk's notes, the plant from 2 % to 60 %
--   ACT 2  FW-2's bearing: the readings, OP-14, the airlock, the dark, the swap
--   ACT 3  PL-7 lets go: the trip (or not), makeup, the weld, the refill
--   ACT 4  morning: what you did, in their words, and the numbers
--
-- The full dialogue for reading is work/scn_reactor/SCRIPT.md.
return {
  id = "graveyard_shift", title = "Graveyard Shift", v = 1, order = 10, minutes = 35,
  teaches = { "reactor", "console", "fluids", "airlock", "repair", "logic", "dose" },
  blurb = "Night shift at Kerne Station, a reactor outpost on the dark side. Take the hand-over, bring the plant up by the book, and keep it that way until morning.",
  brief = {
    "Kerne Station, night side of a small, cold, fast-turning world. Minus sixty-one outside, and the sun is going down.",
    "You have the graveyard shift: the reactor, the radiators, and two people asleep or nearly. Dana will hand over at the console.",
  },
  world = { seed = 731905, scale = 4, names = 2, air = "thin", home = "alien", homeSeed = 4412 },

  cast = {
    ops   = { name = "Kessel Ops", tag = "OPS · 9 MIN DELAY", color = { 0.55, 0.85, 1.0 } },
    dana  = { name = "Dana Kowalczyk", tag = "ENGINEER · OFF SHIFT", crew = "Kowalczyk", color = { 1.0, 0.78, 0.45 }, portrait = "auto", expression = "tired" },
    priya = { name = "Dr Priya Anand", tag = "SCIENTIST", crew = "Anand", color = { 0.62, 0.92, 0.70 }, portrait = "auto" },
    me    = { name = "Halloran", tag = "ENGINEER · NIGHTS", crew = "Halloran", color = { 0.85, 0.88, 0.95 }, portrait = "auto" },
    log   = { name = "Shift Log", tag = "TERMINAL · KERNE-1", color = { 1.0, 0.70, 0.25 } },
  },

  vars = { diag = false, woke = false, prot_ok = false, prot_at_break = true, loca = false, peak_k = 0, dose_msv = 0,
           kwh = 0, brg = 39, seized = false, dana_mu = false, welded_by = "", debriefed = false, read_log = false,
           handover = false, setback_first = true, wake_go = false, dana_bed = false },
  hooks = "scn_graveyard_shift_hooks",       -- scripts/scn_graveyard_shift_hooks.lua on its prefab
  -- (FW-C, docs/scenarios.md §4.2) FW-2's bearing, which the hooks keep in
  -- `tick`, written as DATA, a model a mod could ship (not used here; the hook
  -- stays the one in play). The hook's law: from 61 °C, +0.085 · (1 + (T −
  -- 58) / 120) °C a second while FW-2 turns, settling toward 40 °C (τ 300 s)
  -- while it is off, seizing at 115 °C; smoke_scenarios checks the curve.
  --   models = {
  --     { var = "brg", start = 61, rate = 0.085, accel = 0.008333, base = 58, rest = 40, tau = 300, round = 0.1,
  --       active = { kind = "var", name = "brg_on", is = true },            -- set by the hum (with brg_fixed false)
  --       when = { kind = "piece_state", struct = "Kerne Station", uid = 147, on = true, knocked = false },
  --       at = { { value = 115, beats = { { var = { seized = true, brg_on = false } },
  --                                       { knock = { struct = "Kerne Station", uid = 147, lean = 0,
  --                                                   label = "Swap FW-2's seized bearing cartridge", secs = 30 } } } } } },
  --   },
  -- and its meters: energy to the grid, the dose, the peak after the break
  --   meters = {
  --     { var = "kwh", read = "reactor.genKW", struct = "Kerne Station", mode = "integrate", scale = 0.000278, round = 0.01 },
  --     { var = "dose_msv", read = "dose.msv", who = "Halloran", delta = true, round = 0.1 },
  --     { var = "peak_k", read = "reactor.fuelK", struct = "Kerne Station", mode = "peak", round = 1,
  --       when = { kind = "var", name = "loca", is = true } },
  --   },

  start = {
    funds = 0, rp = 0, safety = "death",
    research = { "ember", "rtg", "radPanel" },
    contracts = false, programme = false, ruins = false,
    crew = {
      { name = "Halloran", role = "engineer", title = "Night engineer", control = true,
        where = { body = "home", site = "far_flat_dark" }, post = "mark:start", face = "mark:dana",
        pack = { { item = "repairkit" } } },
      -- (graveyard2: Dana is there, at the console, when you come out of the
      -- bunk room; Priya at her bench with her back to the room)
      { name = "Kowalczyk", role = "engineer", title = "Engineer · going off shift",
        where = { body = "home", site = "far_flat_dark", offset = { 1, 0, 0 } }, post = "mark:dana", face = "mark:window" },
      { name = "Anand", role = "scientist", title = "Scientist · strainmeter run",
        where = { body = "home", site = "far_flat_dark", offset = { -1, 0, 0 } }, post = "mark:priya", face = "mark:priyabench" },
    },
    structures = {
      -- (the crew are sited on open ground 10 m north-west of the hab, then
      -- set at their posts once the station stands: never under its slabs)
      { bp = "graveyard_shift/station.bp.txt", name = "Kerne Station", at = "crew:Halloran", offset = { 10, 0, -10 }, yaw = 0, powered = true, air = true },
    },
    -- the plant: twenty days at 60 %, tripped by Dana at 23:10 for the FW-2 job,
    -- brought back to 2 % and parked there for the hand-over. She bypassed the
    -- trips while she worked the skid and did not put them back (log item 3).
    plants = { { struct = "Kerne Station", fuel = { item = "fuelRod", n = 8 }, power = 0.6, days = 20, scramFor = 1500,
                 standby = 0.02, hold = 1800, protection = false, turbine = false,
                 fill = { { uid = 118, kg = 1990 } } } },   -- the makeup line's Coolant Tank, full
    -- the alarm is logic: the console's TRIPPED to the beacons in the hall and the control room
    wires = {
      { struct = "Kerne Station", from = { part = "reactorConsole", pin = "tripped" }, to = { uid = 378, pin = "IN" } },
      { struct = "Kerne Station", from = { part = "reactorConsole", pin = "tripped" }, to = { uid = 379, pin = "IN" } },
    },
    -- the designations the crew use on the radio, painted on the pieces (their
    -- menus and every refusal or warning name them: "FW-2 is knocked askew")
    -- (the interaction agent's; graveyard2's layout rework kept these uids)
    tags = {
      { struct = "Kerne Station", uid = 116, name = "P-3" },
      { struct = "Kerne Station", uid = 114, name = "MU-1" },
      { struct = "Kerne Station", uid = 109, name = "PL-7" },
      { struct = "Kerne Station", uid = 147, name = "FW-2" },
    },
    marks = {
      -- (offsets are the station's own frame: x east, z north)
      -- (graveyard2: the hab grew west and north; tools/gen_graveyard_station.lua)
      center  = { at = "struct:Kerne Station", offset = { 4, 0, 1 } },
      start   = { at = "struct:Kerne Station", offset = { -5.4, 0, 3.9 } },      -- just out of the bunk room
      console = { at = "struct:Kerne Station", offset = { -3.7, 0, 0.0 } },
      dana    = { at = "struct:Kerne Station", offset = { -3.9, 0, 1.65 } },     -- beside the console, 1.2 m clear of it (a right-click at the console never lands on her)
      danawatch = { at = "struct:Kerne Station", offset = { -5.6, 0, 0.9 } },    -- out of your way, watching the board
      danaboard = { at = "struct:Kerne Station", offset = { -4.3, 0, 1.7 } },    -- woken: back on the board, clear of the console
      priya   = { at = "struct:Kerne Station", offset = { -7.0, 0, 0.4 } },
      priyabench = { at = "struct:Kerne Station", offset = { -7.0, 0, -0.5 } },
      logdesk = { at = "struct:Kerne Station", offset = { -7.0, 0, 2.6 } },
      bunkdoor = { at = "struct:Kerne Station", offset = { -4.0, 0, 5.0 } },
      bunk    = { at = "struct:Kerne Station", offset = { -5.4, 0, 7.55 } },     -- beside Dana's bunk
      danabed = { at = "struct:Kerne Station", offset = { -5.55, 0, 8.45 } },    -- the lower bunk's middle
      danapillow = { at = "struct:Kerne Station", offset = { -6.6, 0, 8.45 } },  -- the pillow end (west)
      danasit = { at = "struct:Kerne Station", offset = { -5.4, 0, 8.12 } },     -- sitting up on its edge
      wakespot = { at = "struct:Kerne Station", offset = { -4.3, 0, 7.5 } },     -- (the probe stands here to wake her)
      lockout = { at = "struct:Kerne Station", offset = { -4, 0, -5.0 } },
      skid    = { at = "struct:Kerne Station", offset = { 18.5, 0, 3.7 } },
      fw2     = { at = "struct:Kerne Station", offset = { 18.5, 0, 5.0 } },
      pl7     = { at = "struct:Kerne Station", offset = { 6.5, 0, -3.9 } },
      mu1     = { at = "struct:Kerne Station", offset = { 3.2, 0, -3.7 } },
      core    = { at = "struct:Kerne Station", offset = { 4, 0, 0 } },
      window  = { at = "struct:Kerne Station", offset = { -2.0, 0, 0.0 } },
      camsw   = { at = "struct:Kerne Station", offset = { -26, 0, -30 } },
      camhall = { at = "struct:Kerne Station", offset = { 9.8, 0, -6.2 } },
      dolly1  = { at = "struct:Kerne Station", offset = { 10.5, 0, -5.0 } },
      dolly2  = { at = "struct:Kerne Station", offset = { 10.5, 0, 3.5 } },
      rads    = { at = "struct:Kerne Station", offset = { 26, 0, 6 } },
    },
  },

  on_start = {
    { state = { struct = "Kerne Station", part = "flPump", st = { off = true } } },       -- P-3: the makeup pump, off in standby (MU-1, its valve, stands open)
    -- (graveyard2) Priya bent over her strainmeter's readout at the bench
    { gesture = { who = "Anand", clip = "lean_console" } },
    { run = "arrival" },
  },

  sequences = {
    -- ── ACT 1 ──────────────────────────────────────────────────────────────
    arrival = {
      { cutscene = true },
      { shot = { orbit = "mark:center", dist = 70, height = 26, turn = 55, start = 200, secs = 9, wait = false } },
      { caption = { "GRAVEYARD SHIFT", "Kerne Station · 23:52 local · night side", 6 } },
      { wait = 5 },
      { say = { who = "ops", text = "Kerne, Kessel Ops. Shift change logged at 23:52. Night crew has the plant. Ops out." } },
      { shot = { from = "mark:rads", to = "mark:skid", look = "mark:center", offset = { 0, 6, 8 }, toOffset = { 0, 3, -6 }, secs = 6 } },
      { shot = { from = "mark:priya", look = "mark:window", offset = { 0, 1.7, 0 }, secs = 3 } },
    },
    -- (graveyard2, Ty 2026-11-10: "I'm actually talking to that npc") Dana
    -- turns from the console, walks up to you and hands over face to face
    handover = {
      { look = { who = "dana", at = "crew:Halloran" } },
      { walk = { who = "Kowalczyk", to = "crew:Halloran", near = 1.35, speed = 1.1, secs = 14, wait = true } },
      { turn = { who = "Kowalczyk", to = "crew:Halloran" } },
      { face = { who = "dana", emotion = "tired", secs = 60 } },
      { say = { who = "dana", text = "There you are. Coffee's on the bench, it's been on since nine, drink it at your own risk.", with = "me" } },
      { gesture = { who = "Kowalczyk", clip = "stand_talk", secs = 14 } },
      { say = { who = "dana", text = "Where we are. I tripped her at ten past eleven to look at FW-2, the feed pump out by the radiators. She's back up and parked at two per cent.", with = "me" } },
      { say = { who = "dana", text = "Turbine's off line. Both coolant pumps running, pressuriser's holding. The radiators are cold-soaked, so take the first thirty slowly or the condenser sulks.", with = "me" } },
      { gesture = { who = "Anand", clip = false } },
      { turn = { who = "Anand", to = "crew:Halloran" } },
      { look = { who = "priya", at = "crew:Halloran" } },
      { say = { who = "priya", text = "And she means slowly. My strainmeter hears every load step through the rock. Last Tuesday it heard Dana sneeze.", with = "me" } },
      { look = { who = "dana", at = "crew:Anand" } },
      { say = { who = "dana", text = "Priya's measuring the ridge breathing. Forty-hour run, she's on hour thirty-one. Don't be the reason she starts again.", with = "me" } },
      { turn = { who = "Anand", to = "mark:priyabench" } },
      { look = { who = "priya", at = false } },
      { gesture = { who = "Anand", clip = "lean_console" } },
      { look = { who = "dana", at = "crew:Halloran" } },
      -- (she points the desk out with the line; her eyes stay on you: the talk gaze)
      { gesture = { who = "Kowalczyk", clip = "point", secs = 4 } },
      { say = { who = "dana", text = "The log's on the desk terminal, under the porthole. Read it. Three items, all mine, none of them finished.", with = "me" } },
      { gesture = { who = "Kowalczyk", clip = "stand_talk", secs = 30 } },
      { choice = { who = "dana", prompt = "Questions before I fall over?",
        options = {
          { text = "What did you find on FW-2?", run = "q_fw2" },
          { text = "Anything I should know about the hall?", run = "q_hall" },
          { text = "No. Go to bed, Dana.", run = "q_bed" },
        }, default = 3, timeout = 40 } },
    },
    q_fw2 = {
      { say = { who = "dana", text = "Nothing I could prove. Bearing housing's warm to the hand, warmer than FW-1. Could be the cold, the grease goes stiff out there." } },
      { say = { who = "dana", text = "Spare cartridge is in the crate on the skid. If it starts singing, OP-14: forty per cent, isolate, swap, back. Twenty minutes." } },
      { run = "q_end" },
    },
    q_hall = {
      { say = { who = "dana", text = "PL-7. The cold-leg spool by the pressuriser tee. Weld's got a crack indication, so there's a clamp on it till day shift re-welds it." } },
      { say = { who = "dana", text = "Clamp's rated for the pressure. Day shift says stay under sixty per cent till it's done. So we stay under sixty." } },
      { say = { who = "dana", text = "And two of the shield blocks are out at the foot of the south face for the job. Don't stand in that gap with the core at power." } },
      { run = "q_end" },
    },
    q_bed = {
      { say = { who = "dana", text = "Bed. Yes. That word. Say it again, slowly." } },
      { face = { who = "dana", emotion = "smile", secs = 5 } },
      { run = "q_end" },
    },
    -- (gy3, Ty 2026-11-11: "she doesn't go to the bedroom to sleep when she
    -- hands things over and says she's gonna sleep") she goes when she says it
    q_end = {
      { say = { who = "dana", text = "Console's yours. Two to thirty, turbine on line, thirty to sixty. Watch the period.", with = "me" } },
      { say = { who = "dana", text = "Wake me if something's on fire. And mean it. Bunk room, ten metres. Don't make it nine.", with = "me" } },
      { var = { handover = true } },
      { look = { who = "dana", at = false } },
      { run = "dana_off" },
    },
    read_log = {
      { var = { read_log = true } },
      { say = { who = "log", text = "22:47  D.K.  FW-2 brg housing 61 °C, FW-1 38 °C. Vib not measured: no probe on site. Spare cartridge staged in crate at skid." } },
      { say = { who = "log", text = "23:10  D.K.  RX tripped by hand for FW-2 inspection. Protection BYPASSED: low-flow trip kept firing while I cycled the pump. RESTORE BEFORE POWER." } },
      { say = { who = "log", text = "23:15  D.K.  PL-7 clamp checked, torque OK. Re-weld booked day shift. HOLD < 60 %. Shield blocks S-4, S-5 out at the foot for access. Replace after weld." } },
      { say = { who = "log", text = "23:40  D.K.  RX at 2 % auto. Hand-over to nights. Item 2 is the one that matters, Halloran. The console's PROTECTION toggle." } },
    },
    -- (graveyard2: she walks to the bunk room, through its door, and lies
    -- down on her bunk; she stays there until someone wakes her)
    dana_off = {
      { walk = { who = "Kowalczyk", to = "mark:bunk", speed = 1.0, secs = 40,
                 pose = { kind = "lie", struct = "Kerne Station", spot = { -5.55, 0.68, 8.45 }, toward = { -6.6, 0.68, 8.45 }, stand = "mark:bunk" } } },
      { var = { dana_bed = true } },
      { wait = 2.5 },
      { face = { who = "priya", emotion = "smile", secs = 6 } },
      { say = { who = "priya", text = "She says that every night. She's asleep before the door closes." } },
    },
    -- (gy3) the climb, with Dana in her bunk: Priya has the board's other half
    at_sixty = {
      { say = { who = "priya", text = "Sixty. Dana would say that's a plant. She'd also say don't touch anything else." } },
      { say = { who = "priya", text = "Held like that, my strainmeter can't tell you're there. That's the nicest thing I know how to say to an engineer." } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    hum = {
      { hook = "bearing_start" },
      -- (she comes off the bench for this one: the first thing all night that isn't hers)
      { gesture = { who = "Anand", clip = false } },
      { turn = { who = "Anand", to = "crew:Halloran" } },
      { face = { who = "priya", emotion = "worried", secs = 40 } },
      { say = { who = "priya", text = "Halloran. Is that new? There's a tone in the floor. My strainmeter's got a line at forty-nine hertz that wasn't there an hour ago." } },
      { say = { who = "priya", text = "Something in the plant is turning and it's not happy about it. Can you see it on the board?" } },
      { objective = { step = "diagnose", text = "Something is singing at 49 Hz. Read the feed pump bearings (the card) and the LOOPS page, then tell Priya which pump." } },
      { run = "diag_q" },
    },
    diag_q = {
      { choice = { who = "priya", prompt = "Which one is it?",
        options = {
          { text = "FW-2. The bearing on the outside skid is running away.", var = { diag = "fw2" }, run = "diag_right" },
          { text = "FW-1, in the hall.", run = "diag_fw1" },
          { text = "A coolant pump. RCP-2.", run = "diag_rcp" },
        }, default = 1, timeout = 60 } },
    },
    diag_fw1 = { { say = { who = "priya", text = "Your card says FW-1's at thirty-nine degrees, which is less than me. Look again." } }, { run = "diag_q" } },
    diag_rcp = { { say = { who = "priya", text = "The coolant pumps are canned motors, they don't have a bearing you could hear from here. Dana told me that twice. Look again." } }, { run = "diag_q" } },
    diag_right = {
      { say = { who = "priya", text = "The one outside. In the dark. Of course it is." } },
      { say = { who = "priya", text = "I've got OP-14 up. Step one: setpoint to forty per cent, so FW-1 can carry the secondary on its own." } },
      { say = { who = "priya", text = "Step two, isolate. Step three, swap the cartridge. I'll read, you do." } },
      -- (back to her readout: she reads you the procedure from there)
      { face = { who = "priya", emotion = "focus", secs = 30 } },
      { turn = { who = "Anand", to = "mark:priyabench" } },
      { gesture = { who = "Anand", clip = "lean_console" } },
    },
    at_skid = {
      { say = { who = "priya", text = "I've got your helmet camera. That's FW-2? It's frosted over. You can hear it from there?" } },
      { say = { who = "me", text = "I can feel it through my boots." } },
      { say = { who = "priya", text = "Lovely. Step two: the pump's switch, right side of the casing. OFF. FW-1 will take the flow." } },
    },
    swap_talk = {
      { say = { who = "priya", text = "FW-2 off. Flow on FW-1's up to four kilos a second, which the procedure says is fine. Step three." } },
      { say = { who = "priya", text = "Cartridge is the round housing at the drive end. Four bolts. Old cartridge out, new one in, torque to the tag." } },
      { say = { who = "priya", text = "It says, and I quote, do not drop the cartridge." } },
      { say = { who = "priya", text = "The puller's in your Repair Kit. Hands on the pump, and don't drop the cartridge. I'm reading that bit twice." } },
    },
    swap_done = {
      { say = { who = "priya", text = "That's in. The old one's sitting in your hand, isn't it. Look at the race. Is it blue?" } },
      { say = { who = "me", text = "Blue and scored. Another night and it would have welded itself." } },
      { say = { who = "priya", text = "Then you saved Dana a much worse morning. Step four: FW-2 back on. Then come in. Your suit's been complaining on my screen for five minutes." } },
    },
    seized = {
      { say = { who = "priya", text = "Halloran, the line's gone. The forty-nine hertz line, it just stopped. And FW-2's current went to nothing." } },
      { say = { who = "priya", text = "It seized. FW-1 is carrying the whole secondary alone. If FW-1 so much as coughs we lose the heat sink." } },
      { objective = { step = "setback", text = "FW-2 has seized. OP-14: setpoint to 40 % now, then go and swap its cartridge." } },
    },
    -- ── ACT 3 ──────────────────────────────────────────────────────────────
    trip = {
      { cutscene = true },
      { hook = "at_break" },
      { state = { struct = "Kerne Station", uid = 109, st = { brk = 0.15 } } },
      { var = { loca = true } },
      { shot = { from = "mark:camhall", look = "mark:pl7", offset = { 0, 2.2, 0 }, toOffset = { 0, 2.0, 0 }, secs = 3.5, wait = false } },
      { sound = "audio/foley/switch_3.ogg" },
      { alarm = true },
      { gesture = { who = "Anand", clip = false } },
      { face = { who = "priya", emotion = "alarmed", secs = 25 } },
      { say = { who = "priya", text = "What was that? That was a bang. That was a bang in the hall." } },
      { shot = { from = "mark:dolly1", to = "mark:dolly2", look = "mark:core", offset = { 0, 3.3, 0 }, toOffset = { 0, 3.0, 0 }, secs = 6, wait = false } },
      { branch = { var = "prot_at_break", is = true,
        beats = { { say = { who = "priya", text = "Every light on the board just went red. It says TRIP. It says COOLANT NEAR BOILING. Is that the reactor? Tell me that's the reactor shutting itself off." } } },
        elseBeats = { { say = { who = "priya", text = "The board's flashing PRESSURE but the power's still at sixty. Shouldn't it trip? Halloran, why hasn't it tripped?" } } } } },
      { shot = { from = "mark:priya", look = "mark:window", offset = { 0, 1.7, 0 }, secs = 2 } },
    },
    after_trip = {
      { objective = { step = "loca", text = "LOSS OF COOLANT on the primary. Get the reactor shut down: SCRAM at the console if it hasn't tripped." } },
      { choice = { who = "priya", prompt = "Dana's asleep. Do I wake her?",
        options = {
          { text = "I'll wake her. Watch the board for me.", var = { wake_go = true }, run = "wake_go" },
          { text = "Let her sleep. I've got the board.", var = { woke = false }, run = "nowake" },
        }, default = 1, timeout = 20 } },
    },
    -- (graveyard2, Ty: "wake Dana" means walking to the bunk room and talking
    -- to her; the event `wake` fires when you stand by her bunk)
    wake_go = {
      { say = { who = "priya", text = "Go. Bunk room, the north door. I'll shout if anything else goes red." } },
      { objective = { step = "loca", text = "LOSS OF COOLANT on the primary. SCRAM at the console if it hasn't tripped. Dana is asleep in the bunk room (the north door)." } },
    },
    wake = {
      { pose = { who = "Kowalczyk", kind = "sit", struct = "Kerne Station", spot = { -5.4, 0.68, 8.12 }, toward = { -5.0, 0.68, 7.0 }, stand = "mark:bunk" } },
      { look = { who = "dana", at = "crew:Halloran" } },
      { face = { who = "dana", emotion = "tired", secs = 8 } },
      { say = { who = "dana", text = "Mm. Halloran? What time is it. What's that noise?", with = "me", cross = true } },
      { say = { who = "me", text = "PL-7's let go. The hall's losing coolant.", with = "dana" } },
      { face = { who = "dana", emotion = "alarmed", secs = 20 } },
      { choice = { who = "dana", prompt = "What do you need?",
        options = {
          { text = "You, on the board. Now.", var = { woke = true }, run = "wake_yes" },
          { text = "Nothing. Go back to sleep, I've got it.", var = { woke = false }, run = "wake_no" },
        }, default = 1, timeout = 25 } },
    },
    wake_yes = {
      { say = { who = "dana", text = "I'm up. I'm up. Talk to me on the way, what's the inventory doing?", with = "me" } },
      { walk = { who = "Kowalczyk", to = "mark:danaboard", face = "mark:console", speed = 1.7, secs = 30 } },
      { look = { who = "dana", at = false } },
    },
    wake_no = {
      { say = { who = "dana", text = "You're sure. Then why are you still standing here? Go.", with = "me" } },
      { look = { who = "dana", at = false } },
      { pose = { who = "Kowalczyk", kind = "lie", struct = "Kerne Station", spot = { -5.55, 0.68, 8.45 }, toward = { -6.6, 0.68, 8.45 }, stand = "mark:bunk" } },
    },
    nowake = {
      { say = { who = "priya", text = "Okay. Okay. Your board. Tell me what to watch and I'll watch it." } },
    },
    shut_down = {
      { say = { who = "priya", text = "Power's falling. One per cent. Under one. That's shut down? That's shut down." } },
      { objective = { step = "stabilise", text = "The primary is losing water through PL-7. Makeup: start P-3, the makeup pump by the pressuriser (its valve MU-1 must be open). Weld PL-7. Refill until the core is covered." } },
      { branch = { var = "woke", is = true,
        beats = { { say = { who = "dana", text = "Decay heat's small, we've only been at power an hour. But she's still losing water through that clamp." } },
                  { say = { who = "dana", text = "Makeup first, P-3 on the charging line, then the weld. I'll keep the board." } } },
        elseBeats = { { say = { who = "priya", text = "The LOOPS page says INVENTORY, and it's going down. What puts water back in?" } } } } },
    },
    dana_steps_in = {
      { say = { who = "dana", text = "Too slow. I'm on the charging line. P-3's running. Go and weld the bloody thing, Halloran." } },
      { state = { struct = "Kerne Station", part = "flPump", st = { off = false } } },
      { var = { dana_mu = true } },
    },
    -- ── ACT 4 ──────────────────────────────────────────────────────────────
    resolution = {
      { cutscene = true },
      { alarm = false },
      -- (morning: Dana is up, whoever woke her)
      { walk = { who = "Kowalczyk", to = "mark:danawatch", face = "mark:console", secs = 30 } },
      { shot = { orbit = "mark:center", dist = 48, height = 18, turn = 40, start = 30, secs = 10, wait = false } },
      { caption = { "05:58", "Kerne Station · the primary holds", 5 } },
      { say = { who = "log", text = "05:58  Halloran.  Primary intact, inventory recovering, plant shut down and stable. Hand-over to day shift at 07:40." } },
      -- (inside: Dana at the board, in a shot from the window; she has had the night she had)
      -- (a crew ref is the capsule's centre, a metre up, and a look lifts 1.2 more: the lookOffset brings it back to her face)
      -- (a metre north of the window, so the line to her clears you at the console; gs2's monitor had the camera
      -- pulled out in front of your capsule when it was authored on that line)
      { shot = { from = "mark:window", look = "crew:Kowalczyk", offset = { 0, 1.6, 1.0 }, lookOffset = { 0, -0.8, 0 }, secs = 14, wait = false } },
      { face = { who = "dana", emotion = "tired", secs = 40 } },
      { branch = { var = "woke", is = true,
        beats = { { say = { who = "dana", text = "Clamp's off, weld's in, inventory's back over ninety. I'll write it up. You'll sign it." } } },
        elseBeats = { { say = { who = "dana", text = "Somebody could have woken me. I'd have said the same thing you did, but somebody could have." } } } } },
      { branch = { var = "prot_at_break", is = true,
        beats = { { say = { who = "dana", text = "And the trips were in. You read the log. She shut herself down the second that clamp went, the way she's meant to." } } },
        elseBeats = { { say = { who = "dana", text = "And the protection was still bypassed. My bypass. My log item. I'll be the one explaining that to Kessel, not you." } } } } },
      { branch = { var = "seized", is = true,
        beats = { { say = { who = "dana", text = "And FW-2 seized on your watch. Next time it sings, you go out when it starts singing." } } } } },
      { say = { who = "dana", text = "There's fresh coffee. I made it at five, which tells you what kind of night I've had." } },
      -- (Priya, from the window end of the room, with the night on her screen; not from the console: you stand there)
      { shot = { from = "mark:window", look = "crew:Anand", offset = { 0, 1.7, 1.3 }, lookOffset = { 0, -0.8, 0 }, secs = 14, wait = false } },
      { branch = { var = "peak_k", gt = 900,
        beats = { { say = { who = "priya", text = "The fuel went past nine hundred kelvin. I don't know what that means. Dana's face says it means paperwork." } } },
        elseBeats = { { face = { who = "priya", emotion = "happy", secs = 20 } },
                      { say = { who = "priya", text = "The fuel never got hot. I watched it the whole time. That's the most boring graph I've ever been glad to see." } } } } },
      { say = { who = "priya", text = "My strainmeter's got the whole night on it. The bang, the trip, your boots on the catwalk. Thirty-seven hours in and the best data I've taken all year." } },
      { say = { who = "dana", text = "Did I sneeze?", with = "priya" } },
      { say = { who = "priya", text = "Twice. Ten past four. It's the clearest thing on the trace.", with = "dana" } },
      { shot = { orbit = "mark:center", dist = 56, height = 20, turn = 30, start = 70, secs = 12, wait = false } },
      { say = { who = "ops", text = "Kerne, Kessel Ops. Event report received. Day shift lands 07:40 with a welder and a spare spool. Nights, go to bed. Ops out." } },
      { var = { debriefed = true } },
    },
  },

  events = {
    { id = "readlog", when = { kind = "at", who = "crew:Halloran", at = "mark:logdesk", r = 1.4 }, run = "read_log" },
    { id = "prot_seen", when = { kind = "var", name = "prot_ok", is = true }, after = "console",
      beats = { { say = { who = "priya", text = "Your board just went from BYPASS to ARMED. That was Dana's item two, wasn't it? She'll be pleased. Tomorrow." } } } },
    { id = "hum", when = { kind = "timer", secs = 35, from = "step:diagnose" }, run = "hum" },
    { id = "seized", when = { kind = "var", name = "seized", is = true }, run = "seized" },
    { id = "cold", when = { kind = "at", who = "crew:Halloran", at = "mark:lockout", r = 3 }, during = "skid",
      beats = { { say = { who = "priya", text = "Outside. It's minus sixty-one and the wind's at fourteen. Your lamp's the only light between you and the radiators, so follow the pipe." } } } },
    { id = "trip", when = { kind = "timer", secs = 30, from = "step:loca" }, run = "trip" },
    { id = "after_trip", when = { kind = "var", name = "loca", is = true }, run = "after_trip" },
    -- (graveyard2) whatever you told Priya, standing by Dana's bunk after the break wakes her
    { id = "wake", when = { kind = "at", who = "crew:Halloran", at = "crew:Kowalczyk", r = 1.9 },
      also = { kind = "var", name = "loca", is = true }, after = "back", run = "wake" },
    { id = "shut", when = { kind = "reactor", struct = "Kerne Station", power_below = 0.02 }, after = "back", run = "shut_down" },
    { id = "inv40", when = { kind = "hook", fn = "inv_below", below = 0.45 }, after = "back",
      beats = { { say = { who = "priya", text = "INVENTORY says forty-four per cent. Is that the water? That's the water. Where is it going?" } } } },
    { id = "uncovered", when = { kind = "hook", fn = "inv_below", below = 0.27 }, after = "back",
      beats = { { say = { who = "priya", text = "Twenty-six. The fuel temperature's turned round, it's going up again. It was going down, Halloran, now it's going up." } } } },
    { id = "hot700", when = { kind = "hook", fn = "fuel_above", above = 700 }, after = "back",
      beats = { { say = { who = "priya", text = "Fuel's at seven hundred kelvin and climbing. Halloran, it's climbing." } } } },
    { id = "makeup_on", when = { kind = "hook", fn = "makeup" }, after = "back",
      beats = { { say = { who = "priya", text = "Something's moving on the charging line. The FLUIDS page has an arrow. Arrows are good?" } } } },
    { id = "welded", when = { kind = "hook", fn = "welded" }, after = "back",
      beats = { { say = { who = "priya", text = "The break's gone off the screen. The red ring. It's just gone." } } } },
    { id = "dana_mu", when = { kind = "hook", fn = "dana_should_act", secs = 80 }, after = "loca", run = "dana_steps_in" },
  },

  steps = {
    -- ACT 1: the hand-over and the climb
    { id = "handover", text = "Hand-over. Hear Dana out.", run = "handover", act = "Act 1 · the hand-over",
      goals = { { kind = "var", name = "handover", is = true, label = "Dana's hand-over" } },
      hint = "Dana is coming over to you. Let her talk; when she asks, pick a question with the number keys (or the mouse). Then she goes to bed." },
    { id = "log", optional = true, text = "(optional) Read the shift log on the desk terminal (E at the monitor: its LOG page).", mark = "mark:logdesk",
      goals = { { kind = "var", name = "read_log", is = true, label = "The shift log" } },
      hint = "The desk is under the porthole on the control room's west wall. Walk up to it: the log reads itself out." },
    { id = "console", text = "Take the console.", mark = "mark:console",
      -- (gy3, Ty: "told to go to the reactor console while already using it")
      goals = { { kind = "any", label = "At the reactor console",
                  goals = { { kind = "at", who = "crew:Halloran", at = "mark:console", r = 1.8 },
                            { kind = "using", struct = "Kerne Station", part = "reactorConsole" } } } },
      hint = "The console stands at the windows onto the hall, by the bulkhead door (east side of the control room). Walk right up to it and press E: its REACTOR page has every reading and control. Right-click still opens its menu.",
      hint2 = "Item 2 of Dana's log: the PROTECTION toggle on the console's REACTOR page. If it reads BYPASS, set it to ARMED. Not a step, but it matters later." },
    { id = "p30", text = "Raise the reactor from 2 % to 30 %. Console: Setpoint +10 %, three times. Watch the period.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_above = 0.28, label = "Reactor at 30 %" } },
      hint = "At the console press E: on the REACTOR page, Setpoint + steps it 5 % (its right-click menu: Setpoint +10 %). The automatic controller walks the rods out for you.",
      on_done = { { say = { who = "priya", text = "Thirty on your board. Dana's note says the turbine next. She underlined it twice." } } } },
    { id = "turbine", text = "Put the turbine on line (console: Turbine online).",
      goals = { { kind = "hook", fn = "turbine_on", label = "Turbine on line, making power" } },
      hint = "The console's REACTOR page (E) has a Turbine online key, so does its menu. It needs steam: 10 % of its rating to spin.",
      on_done = { { say = { who = "priya", text = "There. A step, then a hum. I felt that in the rock. Thank you for not slamming it." } } } },
    { id = "p60", text = "Raise to 60 % and hold it there for a minute. Not over: PL-7's clamp.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_above = 0.57, label = "Reactor at 60 %", hold = 60 },
                { kind = "reactor", struct = "Kerne Station", power_below = 0.64, label = "Not over 60 % (the PL-7 clamp)" } },
      hint = "Setpoint +10 % three more times. The turbine follows the steam.",
      on_done = { { run = "at_sixty" } } },
    -- ACT 2: the bearing
    { id = "diagnose", text = "Hold 60 %. Log the restart. Night shift.", act = "Act 2 · the bearing", checkpoint = true,
      -- (a setback here: the plant restaged at 60 % on line, as the climb left it)
      stage = { plants = { { struct = "Kerne Station", standby = 0.6, hold = 600, turbine = true } },
                beats = { { pose = { who = "Kowalczyk", kind = "lie", struct = "Kerne Station", spot = { -5.55, 0.68, 8.45 }, toward = { -6.6, 0.68, 8.45 }, stand = "mark:bunk" } } } },
      goals = { { kind = "hook", fn = "bearing_read", label = "Feed pump bearings" } },
      hint = "Nothing to do but hold 60 % and keep an eye on the console. Something will come up: listen to Priya." },
    { id = "setback", text = "OP-14 step 1: setpoint to 40 % so FW-1 can carry the secondary alone.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_below = 0.43, label = "Reactor at 40 %" } },
      hint = "At the console (E): Setpoint − until it reads 40 %. Or its menu: Setpoint −10 %, twice." },
    { id = "suit", text = "Helmet on. Cycle out through the airlock (the south door of the control room).", mark = "mark:lockout",
      goals = { { kind = "helmet", who = "crew:Halloran", off = false, label = "Helmet on" },
                { kind = "at", who = "crew:Halloran", at = "mark:lockout", r = 3.5, label = "Outside the airlock" } },
      hint = "H puts the helmet on. Walk into the airlock: it cycles when the inner door shuts behind you." },
    { id = "skid", text = "Walk to the FW-2 skid by the radiator row. Follow the pipe east, round the hall.", mark = "mark:skid",
      goals = { { kind = "at", who = "crew:Halloran", at = "mark:skid", r = 3, label = "At the FW-2 skid" } },
      hint = "From the airlock steps go east along the hall's south wall, round its far corner, then north to the radiator row. The work lamp marks the skid.",
      on_done = { { run = "at_skid" } } },
    { id = "isolate", text = "OP-14 step 2: isolate FW-2. Right-click the pump: its switch OFF.", mark = "mark:fw2",
      goals = { { kind = "hook", fn = "fw2_off", label = "FW-2 off" } },
      hint = "FW-2 is the pump on the skid under the work lamp, in the lagged return line. Right-click it and switch it OFF. FW-1, inside, takes the flow.",
      on_done = { { knock = { struct = "Kerne Station", uid = 147, lean = 0, label = "Swap FW-2's bearing cartridge", secs = 20 } }, { run = "swap_talk" } } },
    { id = "swap", text = "OP-14 step 3: swap the bearing cartridge. Right-click FW-2 with the Repair Kit.", mark = "mark:fw2",
      goals = { { kind = "piece_ok", struct = "Kerne Station", uid = 147, label = "New cartridge in" } },
      hint = "Hold the Repair Kit (it's in your pack: the belt keys) and right-click FW-2: the repair row swaps the cartridge. Stay at the pump until it finishes.",
      on_done = { { run = "swap_done" } } },
    { id = "restore", text = "OP-14 step 4: FW-2 back on.", mark = "mark:fw2",
      goals = { { kind = "hook", fn = "fw2_on", label = "FW-2 running" } },
      hint = "Right-click FW-2 again and switch it ON." },
    { id = "back", text = "Back inside, back to the console, back to 60 %.", mark = "mark:console",
      goals = { { kind = "at", who = "crew:Halloran", at = "mark:console", r = 2.5, label = "At the console" },
                { kind = "reactor", struct = "Kerne Station", power_above = 0.57, label = "Reactor at 60 %" } },
      hint = "Back the way you came: the airlock is the south door of the control room. Then the console: Setpoint +10 % twice." },
    -- ACT 3: PL-7
    -- (FW-C, PLAN §2 F5) a fail from here (the core melted, a death) goes back
    -- to this checkpoint: the plant restaged at 60 % on line, FW-2 mended, the
    -- story's variables as they were when it opened; protection back in if you
    -- had restored it (its on_enter branch)
    { id = "loca", text = "Hold 60 %. Four hours to day shift.", act = "Act 3 · PL-7", checkpoint = true,
      stage = { plants = { { struct = "Kerne Station", standby = 0.6, hold = 600, turbine = true } },
                beats = { { pose = { who = "Kowalczyk", kind = "lie", struct = "Kerne Station", spot = { -5.55, 0.68, 8.45 }, toward = { -6.6, 0.68, 8.45 }, stand = "mark:bunk" } } } },
      on_enter = { { branch = { var = "prot_ok", is = true, beats = { { reactor = { struct = "Kerne Station", protection = true } } } } } },
      goals = { { kind = "reactor", struct = "Kerne Station", power_below = 0.02, label = "Reactor shut down" } },
      hint = "At the console press E: SCRAM is the red key, every rod in two seconds (its right-click menu has it too). If the board says TRIPPED it already has.",
      hint2 = "Dana is asleep in the bunk room, through the north door of the control room: walk up to her bunk to wake her." },
    { id = "stabilise", text = "Stop the loss of coolant and refill the primary.", mark = "mark:mu1",
      goals = { { kind = "hook", fn = "makeup", label = "Makeup on: P-3 running, MU-1 open" },
                { kind = "hook", fn = "welded", label = "PL-7 welded" },
                { kind = "hook", fn = "covered", label = "Primary refilled, fuel cool", hold = 10 } },
      hint = "P-3 (the process pump) and MU-1 (its gate valve) are by the pressuriser: right-click P-3 to start it, or start it from the console's REACTOR page (E: MAKEUP). Weld PL-7 from its menu: an Engineer, 30 s.",
      hint2 = "PL-7 is the lagged spool south of the core, between the pump elbow and the tee. Stand clear of the gap in the shield." },
    -- ACT 4
    { id = "morning", text = "Morning.",
      run = "resolution",
      goals = { { kind = "var", name = "debriefed", is = true, label = "Day shift" } },
      hint = "Nothing left to do. Watch the morning come in." },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Kerne Station lost its night engineer.",
      hint = "Dose is time near the core: stay out of the gap in the shield, and do the weld in one go." },
    { kind = "core_melted", struct = "Kerne Station", text = "{clock} into the shift the core uncovered, and nothing was cooling it. Kerne Station will not make power again.",
      hint = "SCRAM first, then water: P-3 on the charging line with MU-1 open keeps the fuel covered while you weld." },
  },

  score = {
    par = 2100, budget = nil,
    rows = {
      { label = "Peak fuel temp (after the break)", var = "peak_k", fmt = "%.0f K", par = "≤ 700 K", lte = 700 },
      { label = "Your dose", var = "dose_msv", fmt = "%.1f mSv", par = "≤ 20 mSv", lte = 20 },
      { label = "Energy to the grid", var = "kwh", fmt = "%.1f kWh", par = "≥ 5 kWh", gte = 5 },
      { label = "Protection in at the break", var = "prot_at_break", par = "yes", lte = nil },
    },
    medals = {
      gold = { time = 1.25, vars = { peak_k = { lte = 700 }, dose_msv = { lte = 20 }, kwh = { gte = 5 }, prot_at_break = { is = true }, seized = { is = false } } },
      silver = { time = 2.0, vars = { peak_k = { lte = 950 }, dose_msv = { lte = 100 } } },
      bronze = "done",
    },
  },
  after = "freeplay",
  freeplay = { contracts = false, programme = false },
  debrief = {
    gold = "By the book, all night. The trips were in, the core never got warm, and Priya kept her run. Kessel is framing your log.",
    silver = "The plant is safe and so are you. Some of it was luck. Read Dana's write-up before your next shift.",
    bronze = "Kerne is standing and the primary holds. The board will want to talk to you about the hours between two and four.",
    fail = "Kerne Station is dark. The investigation will start with the shift log.",
  },
}
