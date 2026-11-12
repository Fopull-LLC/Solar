-- SMOKE: CAREER STORY BEATS (scripts/scenario_run.lua CAREER BEATS; missions
-- plan slice S0). Pure, against stubs.
--
--   * runBeats plays in a career save (no `scn` slot, no g_scenario): the
--     runner stays idle as a scenario, the beats run;
--   * a say reaches the plate (scenario_stage.onSay) with the cast's name,
--     tag and portrait; a radio voice goes to the Ops strip, garbled when its
--     link reads no comms path;
--   * a choice reaches the plate, the answer writes the CALLER's vars and
--     runs the option's hook; a branch reads them;
--   * a shot's camera pivot is a career ref (a function, re-read each
--     frame) and rides the moving planet; a crew ref finds a survivor who is
--     not on the roster (ctx.crew);
--   * scenario-only beats (objective, goto, fail, done) are dropped and named;
--   * nothing writes scn.*; onDone gets the vars; a second run waits its turn;
--   * a scenario save refuses (the scenario owns the runner).
--
--   luajit solar/tests/smoke_scenario_career.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function loadlib(path, extra)
  local e = extra or {}
  if not getmetatable(e) then setmetatable(e, { __index = _G }) end
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end

local SCN = loadlib("scenario.lua")

local function world(slot, g_scenario)
  local store = { ["base.body"] = "Home", ["base.x"] = 0, ["base.y"] = 600, ["base.z"] = 0, g_scenario = g_scenario }
  local writes = {}
  local SAVE = { slot = function() return slot end, get = function(k) return store[k] end,
                 set = function(k, v) store[k] = v; writes[#writes + 1] = k end }
  local W = { T = 0, store = store, writes = writes, said = {}, chose = {}, strip = {}, shot = nil, cine = nil }
  local HOME = { name = "Home", x = 1e6, y = 0, z = 0, radius = 600 }
  W.HOME = HOME
  local function body_now() return { name = "Home", x = HOME.x, y = HOME.y, z = HOME.z, radius = HOME.radius } end
  local space = { body = function(n) if n == "Home" then return body_now() end end, bodies = function() return { body_now() } end,
                  dominant = function() return "Home" end, time = function() return W.T end }
  local roster = { { id = 1, name = "Dana Hale", role = "pilot", status = "afoot", body = "Home", x = 0, y = 601, z = 0 } }
  local clients = { [7] = { id = 7, name = "Ines Barrow", status = "client", body = "Home", x = 30, y = 600, z = 0 } }
  local C = { activeId = function() return 1 end, roster = function() return roster end,
              get = function(id) for _, r in ipairs(roster) do if r.id == id then return r end end return clients[id] end,
              craftOf = function() return nil end, patch = function() return true end }
  W.link = true
  local SCRIPTS = {
    scenario = SCN, crew = C,
    game_manager = { loading = false },
    planet_walker = { onFoot = false },
    deployables = { agencyClock = function() return W.T end },
    planet_camera = { setShot = function(fn) W.shot = fn end, clearShot = function() W.shot = nil end,
                      setCinematic = function(on) W.cine = on end },
    scenario_stage = { onSay = function(l) W.said[#W.said + 1] = l end, onChoice = function(c) W.chose[#W.chose + 1] = c end,
                       onCutscene = function() end, sync = function() end },
    ops_strip = { say = function(text, who, done) W.strip[#W.strip + 1] = { text = text, who = who }; W.strip_done = done end },
    comms = { statusOf = function() return { connected = W.link } end },
    big_caption = { show = function() end },
  }
  W.vessels = { { craftName = "Barrow Rover", node = { id = 99, x = HOME.x + 40, y = 600, z = 0, valid = true } } }
  local terrain = { query = function(x, y, z) return math.sqrt((x - HOME.x) ^ 2 + (y - HOME.y) ^ 2 + (z - HOME.z) ^ 2) - HOME.radius end }
  local env = { save = SAVE, space = space, terrain = terrain, findScript = function(k) return SCRIPTS[k] end,
                findScripts = function(k) if k == "vessel_controller" then return W.vessels end return {} end,
                find = function() return nil end, log = function() end,
                vec3 = function(x, y, z) return { x = x, y = y, z = z } end }
  setmetatable(env, { __index = function(_, k) if k == "time" then return W.T end return _G[k] end })
  W.RUN = loadlib("scenario_run.lua", env)
  W.node = { x = 0, y = 0, z = 0 }
  function W.frame(dt)
    W.T = W.T + (dt or 0.1)
    HOME.x = HOME.x + 3.0
    W.vessels[1].node.x = W.vessels[1].node.x + 3.0
    W.RUN.update(W.node, dt or 0.1)
  end
  function W.run(secs) for _ = 1, math.floor(secs / 0.1 + 0.5) do W.frame(0.1) end end
  return W
end

-- ── a career save ───────────────────────────────────────────────────────────
do
  local W = world("slot1", nil)
  local RUN = W.RUN
  RUN.start(W.node)
  W.frame(0.1)
  check("idle as a scenario in a career save", not RUN.isActive())
  local vars, done_with, hooked = { met = false }, nil, 0
  local medic_at = function()   -- a career ref: re-read every frame (body-relative)
    return { body = "Home", x = 0, y = 600, z = 4 }
  end
  local ok, why = RUN.runBeats({
    { say = { who = "rao", text = "Sit down before you fall down.", secs = 2 } },
    { say = { who = "dispatch", text = "Barrow Survey, do you read? Our rover is dead on the ridge.", secs = 2 } },
    { objective = { text = "a scenario's objective" } },
    { choice = { who = "rao", prompt = "What brings you in?", options = {
        { text = "Patch me up", var = { want = "treat" }, hook = "treat" },
        { text = "Just passing", var = { want = "none" } } } } },
    { branch = { var = "want", eq = "treat", beats = { { say = { who = "rao", text = "On the bed, then.", secs = 1 } } },
                 elseBeats = { { say = { who = "rao", text = "Mind the floor.", secs = 1 } } } } },
    { shot = { look = "medic", secs = 2, offset = { 0, 2, -4 } } },
    { ["goto"] = "nowhere" },
    { mark = { name = "here", at = "crew:Ines Barrow" } },
  }, {
    id = "medic_talk",
    cast = { rao = { name = "Dr Imke Rao", tag = "MEDICAL OFFICER", portrait = "rt:medic_face" },
             dispatch = { name = "Barrow Survey", tag = "CLIENT", radio = true, link = "craft:Barrow Rover" } },
    vars = vars, refs = { medic = medic_at }, crew = { ["Ines Barrow"] = 7 },
    hooks = { treat = function(api) hooked = hooked + 1; api.setVar("treated", true) end },
    onDone = function(v, w) done_with = { v = v, why = w } end,
  })
  check("runBeats plays in a career save", ok == true, why)
  check("still no scenario", not RUN.isActive())
  local dropped = table.concat(RUN.lastCareer and RUN.lastCareer.dropped or {}, ",")
  check("scenario-only beats are dropped and named", dropped:find("objective", 1, true) and dropped:find("goto", 1, true), dropped)
  W.frame(0.1)
  check("the say reaches the plate", #W.said == 1 and W.said[1].name == "Dr Imke Rao" and W.said[1].text:find("Sit down", 1, true), #W.said)
  check("the plate gets the cast's tag and portrait", W.said[1] and W.said[1].tag == "MEDICAL OFFICER" and W.said[1].portrait == "rt:medic_face")
  W.link = false
  W.run(2.8)
  check("a radio voice goes to the Ops strip", #W.strip == 1 and W.strip[1].who == "Barrow Survey", #W.strip)
  check("garbled while its link reads no path", W.strip[1] and W.strip[1].text:find("—", 1, true) ~= nil, W.strip[1] and W.strip[1].text)
  W.run(2.8)
  check("the choice reaches the plate", #W.chose == 1 and W.chose[1].prompt == "What brings you in?" and #W.chose[1].options == 2, #W.chose)
  -- the world waits on the choice
  W.run(3)
  check("the queue holds at the choice", W.shot == nil and #W.said == 1)
  RUN.choose(1)
  check("the answer writes the caller's vars", vars.want == "treat", vars.want)
  W.frame(0.1)
  check("the option's hook ran with the api", hooked == 1 and vars.treated == true)
  W.frame(0.1)
  check("the branch read the var", W.said[#W.said] and W.said[#W.said].text == "On the bed, then.", W.said[#W.said] and W.said[#W.said].text)
  W.run(1.7)
  check("the shot is up", type(W.shot) == "function" and W.cine == true)
  local cx, cy, cz, lx = W.shot()
  local b0 = W.HOME.x
  W.frame(0.1)
  local _, _, _, lx2 = W.shot()
  check("its pivot is the career ref, riding the moving planet", lx and lx2 and math.abs((lx2 - lx) - (W.HOME.x - b0)) < 1e-6, lx and lx2 and (lx2 - lx))
  W.run(3)
  check("the shot ends", W.shot == nil)
  W.run(0.5)
  check("the mark stayed in the run (never scn.marks)", W.store["scn.marks"] == nil)
  check("onDone with the vars", done_with and done_with.v == vars and done_with.why == "done", done_with and done_with.why)
  check("the run is over", not RUN.careerActive())
  local scn_writes = 0
  for _, k in ipairs(W.writes) do if tostring(k):sub(1, 4) == "scn." then scn_writes = scn_writes + 1 end end
  check("nothing wrote scn.*", scn_writes == 0, scn_writes)
  -- a crew ref finds the survivor off the roster
  local ran = false
  RUN.runBeats({ { shot = { look = "crew:Ines Barrow", secs = 1 } } }, { id = "who", crew = { ["Ines Barrow"] = 7 },
    onDone = function() ran = true end })
  W.frame(0.1)
  check("a crew ref finds a survivor who is not on the roster", type(W.shot) == "function" and W.shot() ~= nil)
  W.run(2)
  check("and that run ends too", ran)
  -- two runs: the second waits its turn
  local order = {}
  RUN.runBeats({ { say = { who = "ops", text = "One.", secs = 1 } } }, { id = "a", onDone = function() order[#order + 1] = "a" end })
  local ok2, q = RUN.runBeats({ { say = { who = "ops", text = "Two.", secs = 1 } } }, { id = "b", onDone = function() order[#order + 1] = "b" end })
  check("a second run is queued", ok2 and q == "queued", q)
  W.run(5)
  check("they play in turn", order[1] == "a" and order[2] == "b", table.concat(order, ","))
  -- stopBeats: the line goes, onDone hears why
  local why2 = nil
  RUN.runBeats({ { say = { who = "ops", text = "Long line.", secs = 10 } } }, { id = "c", onDone = function(_, w) why2 = w end })
  W.frame(0.1)
  RUN.stopBeats("abandoned")
  check("stopBeats ends it and says why", why2 == "abandoned" and not RUN.careerActive())
  local ok3 = RUN.runBeats({}, { id = "empty" })
  check("an empty list is refused", ok3 == false)
end

-- ── a scenario save refuses ─────────────────────────────────────────────────
do
  local W = world("scn", "_probe")
  local ok, why = W.RUN.runBeats({ { say = { who = "ops", text = "x" } } }, { id = "x" })
  check("a scenario save refuses career beats", ok == false and tostring(why):find("scenario", 1, true), why)
end

print(string.format("scenario career beats: %d/%d passed", count - failed, count))
if failed > 0 then os.exit(1) end
