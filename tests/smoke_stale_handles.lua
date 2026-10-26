-- SMOKE HARNESS: a handle kept from a node that is gone (engine card 0552).
--
-- A script's node handle is the engine's bare slot number: once the node is
-- destroyed, the next node spawned can be made in that slot, and the OLD
-- handle then reads `valid == true` again — every read and write through it
-- lands on the NEW node. A list that keeps handles and destroys "the oldest"
-- must not trust `valid` alone. Held here:
--
--   * flora_field's felled LOGS (the oldest goes when another falls): a log the
--     depot or the pack took away (tool_belt destroys it) leaves its handle in
--     the list; when its slot is handed to some other node, that node is NOT
--     destroyed in its place — and a log still lying there is.
--
-- (tool_belt's knocked-loose rocks keep the same { n, name } record and the
-- same check.)
--
--   luajit solar/tests/smoke_stale_handles.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

local function vec3(x, y, z) return { x = x, y = y, z = z } end
local BODY = { name = "Verdance", x = 0, y = 0, z = 0, radius = 100 }

local made = {}
local function node(name)
  local n = { name = name, valid = true, x = 0, y = 0, z = 0 }
  function n:destroy() self.valid = false; self.destroyed = (self.destroyed or 0) + 1 end
  function n:setUp() end
  function n:setParent(p) self.parent = p end
  function n:material() return {} end
  made[#made + 1] = n
  return n
end
local planet = node("Verdance")

local env = setmetatable({}, { __index = _G })
env.vec3 = vec3
env.time = 0
env.log, env.print = function() end, function() end
env.space = { body = function(n) return n == BODY.name and BODY or nil end,
              dominant = function() return BODY.name end }
env.find = function(n) return n == BODY.name and planet or nil end
env.findScript = function(k)
  if k == "flora_gen" then return { valid = true, assetFor = function() return "models/flora/oak.glb" end } end
  return nil
end
env.findTagged = function() return {} end
env.spawn = function(prefab, p, cb) local n = node(prefab); if cb then cb(n) end end
env.createNode = function(name, parent, cb) local n = node(name); n.parent = parent; if cb then cb(n) end end
env.assembly = { rebuild = function() end }

local chunk = assert(loadfile("solar/scripts/flora_field.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
check("flora_field loads in a stub world", ok, tostring(err))
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
env.params.motes = 0

-- the world the field is on (a local of the script's: set through `fell`)
for i = 1, 64 do
  local name = debug.getupvalue(env.fell, i)
  if not name then break end
  if name == "cur_body" then debug.setupvalue(env.fell, i, BODY.name) end
end

-- Fell a tree and let it come down: its log is laid. → the log's node.
local SELF = node("Flora Field")
local function fell_one()
  local before = #made
  local hit = { rec = { sp = { form = "tree", name = "Oak" }, scale = 1 }, x = 0, y = 100, z = 0,
                ux = 0, uy = 1, uz = 0, height = 6 }
  check("a tree falls", env.fell(hit, 1, 0, 0) == true)
  for _ = 1, 40 do
    env.time = env.time + 0.1
    env.lateUpdate(SELF, 0.1)
  end
  for i = before + 1, #made do
    if made[i].name:sub(1, 8) == "LooseLog" then return made[i] end
  end
  return nil
end

local logs = {}
for i = 1, 6 do logs[i] = fell_one() end
check("six logs lie on the ground", #logs == 6 and env.logCount() == 6)
check("each log has a name of its own", logs[1] and logs[2] and logs[1].name ~= logs[2].name,
  tostring(logs[1] and logs[1].name))

-- The first log goes into the pack (tool_belt destroys it, not flora_field),
-- and its slot is handed on: the handle now reads a live node, some other one.
logs[1]:destroy()
logs[1].valid, logs[1].name, logs[1].destroyed = true, "Flora 12:7", nil

local seventh = fell_one()
check("a seventh log falls", seventh ~= nil)
check("the node now in the first log's slot is not destroyed in its place", not logs[1].destroyed)
check("...and the list moved on: six again", env.logCount() == 6)

-- A log still lying there goes as before: the eighth takes the second.
fell_one()
check("the oldest log still there goes when the next one falls", logs[2].destroyed == 1)
check("...and only it", not logs[3].destroyed and not logs[1].destroyed)

if #failures > 0 then
  print("STALE HANDLE SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  x " .. f) end
  os.exit(1)
end
print(string.format("stale handle smoke: %d checks passed", passes))
