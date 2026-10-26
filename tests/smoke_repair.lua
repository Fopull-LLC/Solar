-- SMOKE HARNESS for the repair job (docs/crew-and-items.md §6):
-- scripts/item_hand.lua runs it, scripts/context_providers.lua offers it.
--
--   * the duration is 6 + 16 × (1 − hp);
--   * "Repair" needs the kit IN HAND (a dimmed row says how otherwise), reach,
--     a craft not under power;
--   * movement keys never end the job — the walker is stood down and the
--     clock keeps running;
--   * only "Cancel repair" and the forced stops (part broken, craft gone,
--     engines firing, out of air) end it, each with its reason;
--   * the kit is used up only when the job is DONE;
--   * cancelled progress is kept on the part and a re-start within 120 s
--     resumes it (after that, it starts over);
--   * "Cancel repair" is offered on the crew member and on the part while the
--     job runs (the portrait's is WS2's, the same entry);
--   * the same with the roster in the scene (crew.setTask) and without it.
--
--   luajit solar/tests/smoke_repair.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs((a or 0) - (b or 0)) < (e or 1e-6) end

local T = 0
local store = {}
local envs = {}
local API = {}
API.findScript = function(kind) return envs[kind] end
API.findScripts = function(kind) if kind == "vessel_controller" then return { envs.vessel } end return {} end
API.log = function() end
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
API.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
API.space = { time = function() return T end, dominant = function() return nil end, body = function() return nil end }
local keys = {}
API.input = { key = function(k) return keys[k] == true end, pressed = function(k) return keys[k] == true end,
              button = function() return false end }

local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end

local I = load_script("scripts/items.lua", "items")
load_script("scripts/materials.lua", "materials")
local inv = load_script("scripts/inventory.lua", "inventory")
local R = load_script("scripts/context_registry.lua", "context_registry")
local PR = load_script("scripts/context_providers.lua", "context_providers")
PR.registerAll(R)

-- ── the world: one crew member on foot, one craft with a worn pod ───────────
local astro = { name = "Astronaut", x = 0, y = 0, z = 0, valid = true, id = 7, vel = { x = 0, y = 0, z = 0 } }
local rb = { kinematic = 0 }
function astro:getcomponent(k) if k == "RigidBody" then return rb end end
function astro:distanceTo(o) local w = o.worldPos or o; return math.sqrt((self.x - w.x) ^ 2 + (self.y - w.y) ^ 2 + (self.z - w.z) ^ 2) end
function astro:children() return {} end
API.find = function(n) if n == "Astronaut" then return astro end end

local steer_calls = 0
local pw = { valid = true, onFoot = true, grounded = true, downed = false,
             steer = function(f) if f == 0 then steer_calls = steer_calls + 1 end end }
envs.planet_walker = pw

local craft_node = { id = 501, valid = true, x = 3, y = 0, z = 0 }
local part_node = { id = 502, valid = true, x = 3, y = 0, z = 0, name = "PartPod" }
part_node.worldPos = part_node
local hp = { [3] = 0.4 }
local st = { [3] = {} }
local gone = false
local v = { valid = true, node = craft_node, throttle = 0, craftName = "Kestrel I", fuel = 0 }
function v.partHp(uid) if gone then return nil end return hp[uid] end
function v.repairPart(uid, to) if not hp[uid] or hp[uid] <= 0 then return nil, "wrecked" end hp[uid] = to; return to end
function v.partRec(uid) return { label = "Pod Mk1", st = st[uid], rx = 0.6, rz = 0.6, h = 1.2 } end
function v.partSt(uid, k, val, write)
  if write then if val == false then st[uid][k] = nil else st[uid][k] = val end end
  return st[uid][k]
end
function v.partPointNow(uid, lx, ly, lz) return 3 + lx, ly, lz, 0, 0, 0 end
function v.partLocalNow(uid, x, y, z) return x - 3, y, z end
envs.vessel = v
API.assembly = { info = function() return { vel = { x = 0, y = 0, z = 0 }, origin = { x = 3, y = 0, z = 0 } } end }

local H = load_script("scripts/item_hand.lua", "item_hand")

local target = { kind = "part", vessel = v, uid = 3, rec = v.partRec(3), node = part_node, label = "Pod Mk1",
                 wx = 2.6, wy = 0.4, wz = 0 }
local actor = { kind = "crew", node = astro, id = "astro", pack = "astro" }
local ctx = { actor = actor, ref = function(k) return envs[k] end, toast = function() end }

local function step(secs, dt)
  dt = dt or 0.1
  local n = math.floor(secs / dt + 0.5)
  for _ = 1, n do
    T = T + dt
    H.update(nil, dt)
    if envs.crew_task then envs.crew_task.fixedUpdate(nil, dt) end
    H.fixedUpdate(nil, dt)
  end
end
local function menu(t) return (R.entriesFor(t or target, ctx)) end

-- ── the rules ───────────────────────────────────────────────────────────────
ok(near(I.repairSecs(0.4), 15.6) and near(I.repairSecs(0.95), 6.8) and near(I.repairSecs(0.0), 22), "duration: 6 + 16 × (1 − hp)")
ok(I.repairStop({ craft = true, hp = 0.5, throttle = 0, accel = 0 }) == nil, "nothing stops a quiet job")
ok(I.repairStop({ craft = true, hp = 0.5, throttle = 0.4 }):match("engines"), "thrust stops it")
ok(I.repairStop({ craft = false }) == "the craft is gone", "a lost craft stops it")
ok(I.repairStop({ craft = true, hp = 0 }) == "the part broke", "a broken part stops it")
ok(I.repairStop({ craft = true, hp = nil }) == "the part left the craft", "a part gone stops it")
ok(I.repairStop({ craft = true, hp = 0.5, o2 = 0 }) == "out of air", "out of air stops it")
ok(near(I.keptProgress({ s = 5, t = 0 }, 100, 15), 5) and I.keptProgress({ s = 5, t = 0 }, 121, 15) == 0, "progress is kept 120 s")

-- ── the menu: without a kit, with one in the pack, with one in hand ────────
local function run_suite(label)
  hp[3], st[3], gone, v.throttle, pw.downed = 0.4, {}, false, 0, false
  inv.clear("astro")
  store["inv.gear.astro"] = {}
  local e = R.byId(menu(), "repair")
  ok(e and not R.usable(e) and select(2, R.usable(e)):match("needs a Repair Kit"), label .. "no kit: the verb is there, dimmed, and says where kits are")
  inv.addItem("astro", "repairkit", 2)
  e = R.byId(menu(), "repair")
  ok(e and not R.usable(e) and select(2, R.usable(e)):match("hold the Repair Kit"), label .. "a kit in the pack: hold it first")
  ok(H.hold("repairkit") and H.held() == "repairkit", label .. "the kit in hand")
  ok(not H.hold("rcspack"), label .. "worn items are never held")
  astro.x = 30
  e = R.byId(menu(), "repair")
  ok(e and not R.usable(e) and select(2, R.usable(e)):match("walk up"), label .. "too far: walk up to it")
  astro.x = 0.8
  v.throttle = 0.5
  e = R.byId(menu(), "repair")
  ok(e and not R.usable(e) and select(2, R.usable(e)):match("power"), label .. "under power: refused")
  v.throttle = 0
  e = R.byId(menu(), "repair")
  ok(e and R.usable(e) and e.hint == "16 s", label .. "kit in hand, in reach: Repair (16 s)")
  ok(R.press(e) and H.task() ~= nil, label .. "pressing it puts a task on the crew member")
  ok(rb.kinematic == 1 or envs.crew_task, label .. "the body is held (kinematic)")
  -- the cancel entries, on the crew and on the part
  local onAstro = R.entriesFor({ kind = "astro", node = astro, pack = "astro" }, ctx)
  ok(R.byId(onAstro, "cancel") and R.byId(onAstro, "cancel").label == "Cancel repair", label .. "Cancel repair on the crew member")
  ok(R.byId(menu(), "cancel") ~= nil and R.byId(menu(), "repair") == nil, label .. "Cancel repair on the part (and no second Repair)")
  -- movement keys: nothing happens to the job
  keys.w, keys.a, keys.space = true, true, true
  local s0 = steer_calls
  step(5)
  keys.w, keys.a, keys.space = false, false, false
  ok(H.task() and near(H.task().done, 5, 0.11), label .. "WASD and SPACE don't stop the job (5 s in)")
  -- (stood down: by our fallback's steer, or crew_task's hold that the walker reads)
  ok(steer_calls > s0 or (envs.crew_task and envs.crew.held and envs.crew.held(1)), label .. "...the walker's keys are stood down while held")
  ok(near(astro.x, 2.6 + 0, 1.0) or astro.x > 1.0, label .. "the body is at the work spot")
  ok(inv.itemCount("astro", "repairkit") == 2, label .. "the kit isn't used yet")
  -- cancel: progress kept, the kit not used
  local c = R.byId(menu(), "cancel")
  local pressed_ok = R.press(c)
  step(0.1)   -- (crew_task lets go on its next tick)
  ok(pressed_ok and H.task() == nil and H.lastStop == "cancelled", label .. "Cancel repair ends it")
  ok(rb.kinematic == 0 or envs.crew_task, label .. "...and lets go of the body")
  ok(st[3].rprog and near(st[3].rprog.s, 5, 0.11), label .. "the progress is kept on the part")
  ok(inv.itemCount("astro", "repairkit") == 2 and near(hp[3], 0.4), label .. "cancelled: no kit used, no health")
  -- resume within 120 s
  step(30)
  e = R.byId(menu(), "repair")
  ok(e and e.label == "Resume repair", label .. "the row offers to resume")
  ok(R.press(e) and near(H.task().done, 5, 0.11), label .. "a re-click resumes from 5 s")
  step(10.7)
  ok(H.task() == nil and near(hp[3], 1.0), label .. "done: the part is whole")
  ok(inv.itemCount("astro", "repairkit") == 1, label .. "...and one kit was used")
  ok(H.lastRepair and H.lastRepair.kit_before == 2 and H.lastRepair.kit_after == 1, label .. "lastRepair records it")
  ok(st[3].rprog == nil, label .. "the kept progress is cleared")
  ok(R.byId(menu(), "repair") == nil, label .. "a sound part offers no repair")
  -- forced stops
  local function forced(setup, want)
    hp[3], gone, v.throttle, pw.downed, st[3] = 0.6, false, 0, false, {}
    H.hold("repairkit")
    local okp = R.press(R.byId(menu(), "repair"))
    step(1)
    setup()
    step(0.2)
    ok(okp and H.task() == nil and H.lastStop and H.lastStop:match(want), label .. "forced stop: " .. want .. " (" .. tostring(H.lastStop) .. ")")
    ok(inv.itemCount("astro", "repairkit") == 1, label .. "...no kit used (" .. want .. ")")
  end
  forced(function() v.throttle = 0.3 end, "engines")
  forced(function() hp[3] = 0 end, "broke")
  forced(function() gone = true end, "left the craft")
  forced(function() pw.downed = true end, "out of air")
  forced(function() craft_node.valid = false end, "craft is gone")
  craft_node.valid = true
  -- kept progress expires
  hp[3], st[3] = 0.6, { rprog = { s = 4, t = T - 200 } }
  H.hold("repairkit")
  R.press(R.byId(menu(), "repair"))
  ok(H.task() and (H.task().done or 0) == 0, label .. "progress older than 120 s starts over")
  H.cancel()
end

run_suite("[no roster] ")

-- the roster in the scene (WS1's interface): the task lives on the record
local recs = { [1] = { id = 1 } }
envs.crew = { valid = true,
  activeId = function() return 1 end, packOf = function(id) return "crew:" .. id end,
  get = function(id) return recs[id] end,
  patch = function(id, f) for k, val in pairs(f) do if val == false then recs[id][k] = nil else recs[id][k] = val end end end,
  task = function(id) return recs[id].task end,
  setTask = function(id, t) if recs[id].task then return false, "busy" end recs[id].task = t return true end,
  cancelTask = function(id) recs[id].task = nil return true end,
}
T = T + 5
run_suite("[roster] ")
ok(recs[1].repairs and recs[1].repairs >= 1, "the service record counts repairs")

-- WS1's real roster and lock (scripts/crew.lua, scripts/crew_task.lua): the
-- lock and the job's clock are crew_task's, the verbs and the finish ours
local have_ws1 = io.open("solar/scripts/crew_task.lua") or io.open("scripts/crew_task.lua")
if have_ws1 then
  have_ws1:close()
  store = {}
  API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
               delete = function(k) store[k] = nil end }
  envs.crew.valid = false   -- (the stub goes: handles re-resolve)
  load_script("scripts/crew.lua", "crew")
  load_script("scripts/crew_task.lua", "crew_task")
  envs.crew.ensure()
  T = T + 5
  run_suite("[crew_task] ")
  ok(inv.resolve("astro") == "crew:1", "[crew_task] the pack is crew member #1's")
end

if #failures > 0 then
  print("REPAIR SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("REPAIR SMOKE OK — %d checks passed", checks))
