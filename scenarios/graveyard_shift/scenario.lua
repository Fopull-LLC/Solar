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
           handover = false, setback_first = true },
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
      { name = "Halloran", role = "engineer", control = true,
        where = { body = "home", site = "far_flat_dark" }, post = "mark:start",
        pack = { { item = "repairkit" } } },
      { name = "Kowalczyk", role = "engineer", where = { body = "home", site = "far_flat_dark", offset = { 1, 0, 0 } }, post = "mark:dana" },
      { name = "Anand", role = "scientist", where = { body = "home", site = "far_flat_dark", offset = { -1, 0, 0 } }, post = "mark:priya" },
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
    marks = {
      -- (offsets are the station's own frame: x east, z north)
      center  = { at = "struct:Kerne Station", offset = { 4, 0, 1 } },
      start   = { at = "struct:Kerne Station", offset = { -4.5, 0, 2.6 } },
      console = { at = "struct:Kerne Station", offset = { -3.7, 0, 0.0 } },
      dana    = { at = "struct:Kerne Station", offset = { -3.4, 0, -0.7 } },
      priya   = { at = "struct:Kerne Station", offset = { -5.5, 0, 0.5 } },
      logdesk = { at = "struct:Kerne Station", offset = { -5.3, 0, 3.9 } },
      bunk    = { at = "struct:Kerne Station", offset = { -4.4, 0, 5.8 } },
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
    handover = {
      { say = { who = "dana", text = "There you are. Coffee's on the bench, it's been on since nine, drink it at your own risk." } },
      { say = { who = "dana", text = "Where we are: I tripped her at ten past eleven to look at FW-2. Feed pump, outside, by the radiators. She's back up and parked at two per cent." } },
      { say = { who = "dana", text = "Turbine's off line. Both coolant pumps running, pressuriser's holding, radiators are cold-soaked, so take the first thirty per cent slowly or the condenser sulks." } },
      { say = { who = "priya", text = "And she means slowly. My strainmeter hears every load step through the rock. Last Tuesday it heard Dana sneeze." } },
      { say = { who = "dana", text = "Priya's measuring the ridge breathing. Forty-hour run, she's on hour thirty-one. Don't be the reason she starts again." } },
      { say = { who = "dana", text = "The log's on the desk terminal. Read it. Three items, all mine, none of them finished." } },
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
      { say = { who = "dana", text = "Bed. Yes. That word." } },
      { run = "q_end" },
    },
    q_end = {
      { say = { who = "dana", text = "Console's yours. Two to thirty, turbine on line, thirty to sixty. Watch the period. Wake me if something's on fire, and mean it." } },
      { var = { handover = true } },
    },
    read_log = {
      { var = { read_log = true } },
      { say = { who = "log", text = "22:47  D.K.  FW-2 brg housing 61 °C, FW-1 38 °C. Vib not measured: no probe on site. Spare cartridge staged in crate at skid." } },
      { say = { who = "log", text = "23:10  D.K.  RX tripped by hand for FW-2 inspection. Protection BYPASSED: low-flow trip kept firing while I cycled the pump. RESTORE BEFORE POWER." } },
      { say = { who = "log", text = "23:15  D.K.  PL-7 clamp checked, torque OK. Re-weld booked day shift. HOLD < 60 %. Shield blocks S-4, S-5 out at the foot for access. Replace after weld." } },
      { say = { who = "log", text = "23:40  D.K.  RX at 2 % auto. Hand-over to nights. Item 2 is the one that matters, Halloran. The console's PROTECTION toggle." } },
    },
    dana_off = {
      { say = { who = "dana", text = "Sixty, and steady. That's a plant. Right. I'm horizontal. Bunk room, ten metres. Don't make it nine." } },
      { walk = { who = "Kowalczyk", to = "mark:bunk" } },
      { say = { who = "priya", text = "She says that every night. She's asleep before the door closes." } },
    },
    -- ── ACT 2 ──────────────────────────────────────────────────────────────
    hum = {
      { hook = "bearing_start" },
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
      { say = { who = "priya", text = "I've got OP-14 up. Step one: setpoint to forty per cent, so FW-1 can carry the secondary on its own. Step two, isolate. Step three, swap the cartridge. I'll read, you do." } },
    },
    at_skid = {
      { say = { who = "priya", text = "I've got your helmet camera. That's FW-2? It's frosted over. You can hear it from there?" } },
      { say = { who = "me", text = "I can feel it through my boots." } },
      { say = { who = "priya", text = "Lovely. Step two: the pump's switch, right side of the casing. OFF. FW-1 will take the flow." } },
    },
    swap_talk = {
      { say = { who = "priya", text = "FW-2 off. Flow on FW-1's up to four kilos a second, which the procedure says is fine. Step three." } },
      { say = { who = "priya", text = "Cartridge is the round housing at the drive end. Four bolts. Old cartridge out, new one in, torque to the tag. It says, and I quote, do not drop the cartridge." } },
      { say = { who = "priya", text = "Your Repair Kit has the puller. Right-click the pump." } },
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
          { text = "Wake her. Now.", var = { woke = true }, run = "wake" },
          { text = "Let her sleep. I've got the board.", var = { woke = false }, run = "nowake" },
        }, default = 1, timeout = 20 } },
    },
    wake = {
      { say = { who = "priya", text = "DANA. Up. Hall's got a leak and the board's red." } },
      { walk = { who = "Kowalczyk", to = "mark:dana" } },
      { say = { who = "dana", text = "I'm up. I'm up. Talk to me, what's the inventory doing?" } },
    },
    nowake = {
      { say = { who = "priya", text = "Okay. Okay. Your board. Tell me what to watch and I'll watch it." } },
    },
    shut_down = {
      { say = { who = "priya", text = "Power's falling. One per cent. Under one. That's shut down? That's shut down." } },
      { objective = { step = "stabilise", text = "The primary is losing water through PL-7. Makeup: start P-3, the makeup pump by the pressuriser (its valve MU-1 must be open). Weld PL-7. Refill until the core is covered." } },
      { branch = { var = "woke", is = true,
        beats = { { say = { who = "dana", text = "Decay heat's small, we've only been at power an hour. But she's still losing water through that clamp. Makeup first, P-3 on the charging line, then the weld. I'll keep the board." } } },
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
      { shot = { orbit = "mark:center", dist = 48, height = 18, turn = 40, start = 30, secs = 10, wait = false } },
      { caption = { "05:58", "Kerne Station · the primary holds", 5 } },
      { say = { who = "log", text = "05:58  Halloran.  Primary intact, inventory recovering, plant shut down and stable. Hand-over to day shift at 07:40." } },
      { branch = { var = "woke", is = true,
        beats = { { say = { who = "dana", text = "Clamp's off, weld's in, inventory's back over ninety. I'll write it up. You'll sign it." } } },
        elseBeats = { { say = { who = "dana", text = "Somebody could have woken me. I'd have said the same thing you did, but somebody could have." } } } } },
      { branch = { var = "prot_at_break", is = true,
        beats = { { say = { who = "dana", text = "And the trips were in. You read the log. She shut herself down the second that clamp went, the way she's meant to." } } },
        elseBeats = { { say = { who = "dana", text = "And the protection was still bypassed. My bypass. My log item. I'll be the one explaining that to Kessel, not you." } } } } },
      { branch = { var = "peak_k", gt = 900,
        beats = { { say = { who = "priya", text = "The fuel went past nine hundred kelvin. I don't know what that means. Dana's face says it means paperwork." } } },
        elseBeats = { { say = { who = "priya", text = "The fuel never got hot. I watched it the whole time. That's the most boring graph I've ever been glad to see." } } } } },
      { branch = { var = "seized", is = true,
        beats = { { say = { who = "dana", text = "And FW-2 seized on your watch. Next time it sings, you go out when it starts singing." } } } } },
      { say = { who = "priya", text = "My strainmeter's got the whole night on it. The bang, the trip, your boots on the catwalk. Thirty-seven hours in and the best data I've taken all year." } },
      { say = { who = "ops", text = "Kerne, Kessel Ops. Event report received. Day shift lands 07:40 with a welder and a spare spool. Nights, go to bed. Ops out." } },
      { var = { debriefed = true } },
    },
  },

  events = {
    { id = "readlog", when = { kind = "at", who = "crew:Halloran", at = "mark:logdesk", r = 1.4 }, run = "read_log" },
    { id = "prot_seen", when = { kind = "var", name = "prot_ok", is = true }, after = "console",
      beats = { { say = { who = "dana", text = "Protection's back in. Good. That's the one I'd have forgotten." } } } },
    { id = "hum", when = { kind = "timer", secs = 35, from = "step:diagnose" }, run = "hum" },
    { id = "seized", when = { kind = "var", name = "seized", is = true }, run = "seized" },
    { id = "cold", when = { kind = "at", who = "crew:Halloran", at = "mark:lockout", r = 3 }, during = "skid",
      beats = { { say = { who = "priya", text = "Outside. It's minus sixty-one and the wind's at fourteen. Your lamp's the only light between you and the radiators, so follow the pipe." } } } },
    { id = "trip", when = { kind = "timer", secs = 30, from = "step:loca" }, run = "trip" },
    { id = "after_trip", when = { kind = "var", name = "loca", is = true }, run = "after_trip" },
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
      goals = { { kind = "var", name = "handover", is = true, label = "Dana's hand-over" } } },
    { id = "log", optional = true, text = "(optional) Read the shift log on the desk terminal.", mark = "mark:logdesk",
      goals = { { kind = "var", name = "read_log", is = true, label = "The shift log" } } },
    { id = "console", text = "Take the console.", mark = "mark:console",
      goals = { { kind = "at", who = "crew:Halloran", at = "mark:console", r = 1.6, label = "At the reactor console" } },
      hint = "The console faces the hall windows. Right-click it for the controls; its screen turns pages every 6 s." },
    { id = "p30", text = "Raise the reactor from 2 % to 30 %. Console: Setpoint +10 %, three times. Watch the period.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_above = 0.28, label = "Reactor at 30 %" } },
      hint = "Right-click the console: Setpoint +10 %. The automatic controller walks the rods out for you.",
      on_done = { { say = { who = "dana", text = "Thirty. Now the turbine." } } } },
    { id = "turbine", text = "Put the turbine on line (console: Turbine online).",
      goals = { { kind = "hook", fn = "turbine_on", label = "Turbine on line, making power" } },
      hint = "The console's menu has a Turbine online toggle. It needs steam: 10 % of its rating to spin.",
      on_done = { { say = { who = "priya", text = "There. A step, then a hum. I felt that in the rock. Thank you for not slamming it." } } } },
    { id = "p60", text = "Raise to 60 % and hold it there for a minute. Not over: PL-7's clamp.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_above = 0.57, label = "Reactor at 60 %", hold = 60 },
                { kind = "reactor", struct = "Kerne Station", power_below = 0.64, label = "Not over 60 % (the PL-7 clamp)" } },
      hint = "Setpoint +10 % three more times. The turbine follows the steam.",
      on_done = { { run = "dana_off" } } },
    -- ACT 2: the bearing
    { id = "diagnose", text = "Hold 60 %. Log the restart. Night shift.", act = "Act 2 · the bearing", checkpoint = true,
      -- (a setback here: the plant restaged at 60 % on line, as the climb left it)
      stage = { plants = { { struct = "Kerne Station", standby = 0.6, hold = 600, turbine = true } } },
      goals = { { kind = "hook", fn = "bearing_read", label = "Feed pump bearings" } } },
    { id = "setback", text = "OP-14 step 1: setpoint to 40 % so FW-1 can carry the secondary alone.",
      goals = { { kind = "reactor", struct = "Kerne Station", power_below = 0.43, label = "Reactor at 40 %" } },
      hint = "Console: Setpoint −10 %, twice." },
    { id = "suit", text = "Helmet on. Cycle out through the airlock (the south door of the control room).", mark = "mark:lockout",
      goals = { { kind = "helmet", who = "crew:Halloran", off = false, label = "Helmet on" },
                { kind = "at", who = "crew:Halloran", at = "mark:lockout", r = 3.5, label = "Outside the airlock" } },
      hint = "H puts the helmet on. Walk into the airlock: it cycles when the inner door shuts behind you." },
    { id = "skid", text = "Walk to the FW-2 skid by the radiator row. Follow the pipe east, round the hall.", mark = "mark:skid",
      goals = { { kind = "at", who = "crew:Halloran", at = "mark:skid", r = 3, label = "At the FW-2 skid" } },
      on_done = { { run = "at_skid" } } },
    { id = "isolate", text = "OP-14 step 2: isolate FW-2. Right-click the pump: its switch OFF.", mark = "mark:fw2",
      goals = { { kind = "hook", fn = "fw2_off", label = "FW-2 off" } },
      on_done = { { knock = { struct = "Kerne Station", uid = 147, lean = 0, label = "Swap FW-2's bearing cartridge", secs = 20 } }, { run = "swap_talk" } } },
    { id = "swap", text = "OP-14 step 3: swap the bearing cartridge. Right-click FW-2 with the Repair Kit.", mark = "mark:fw2",
      goals = { { kind = "piece_ok", struct = "Kerne Station", uid = 147, label = "New cartridge in" } },
      on_done = { { run = "swap_done" } } },
    { id = "restore", text = "OP-14 step 4: FW-2 back on.", mark = "mark:fw2",
      goals = { { kind = "hook", fn = "fw2_on", label = "FW-2 running" } } },
    { id = "back", text = "Back inside, back to the console, back to 60 %.", mark = "mark:console",
      goals = { { kind = "at", who = "crew:Halloran", at = "mark:console", r = 2.5, label = "At the console" },
                { kind = "reactor", struct = "Kerne Station", power_above = 0.57, label = "Reactor at 60 %" } } },
    -- ACT 3: PL-7
    -- (FW-C, PLAN §2 F5) a fail from here (the core melted, a death) goes back
    -- to this checkpoint: the plant restaged at 60 % on line, FW-2 mended, the
    -- story's variables as they were when it opened; protection back in if you
    -- had restored it (its on_enter branch)
    { id = "loca", text = "Hold 60 %. Four hours to day shift.", act = "Act 3 · PL-7", checkpoint = true,
      stage = { plants = { { struct = "Kerne Station", standby = 0.6, hold = 600, turbine = true } } },
      on_enter = { { branch = { var = "prot_ok", is = true, beats = { { reactor = { struct = "Kerne Station", protection = true } } } } } },
      goals = { { kind = "reactor", struct = "Kerne Station", power_below = 0.02, label = "Reactor shut down" } },
      hint = "Right-click the console: SCRAM drops every rod in two seconds." },
    { id = "stabilise", text = "Stop the loss of coolant and refill the primary.", mark = "mark:mu1",
      goals = { { kind = "hook", fn = "makeup", label = "Makeup on: P-3 running, MU-1 open" },
                { kind = "hook", fn = "welded", label = "PL-7 welded" },
                { kind = "hook", fn = "covered", label = "Primary refilled, fuel cool", hold = 10 } },
      hint = "P-3 (the process pump) and MU-1 (its gate valve) are by the pressuriser: right-click P-3 to start it. Weld PL-7 from its menu: an Engineer, 30 s.",
      hint2 = "PL-7 is the lagged spool south of the core, between the pump elbow and the tee. Stand clear of the gap in the shield." },
    -- ACT 4
    { id = "morning", text = "Morning.",
      run = "resolution",
      goals = { { kind = "var", name = "debriefed", is = true, label = "Day shift" } } },
  },

  fail = {
    { kind = "crew_dead", any = true, text = "Kerne Station lost its night engineer." },
    { kind = "core_melted", struct = "Kerne Station", text = "The core has melted. Kerne Station will not make power again." },
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
