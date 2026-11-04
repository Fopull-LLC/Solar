-- SMOKE: the VAB's bottom bar shows the agency's FUNDS beside the craft's COST
-- (playtest 2026-11-04: "make sure budget shows next to cost in the VAB").
--
--  * a career in budget: COST $964 ▐ FUNDS $19,526, neither red;
--  * over budget (the hull and the CREW tab's kit, the sum LAUNCH asks for):
--    both red, and the toolbar's LAUNCH tip says why it would refuse;
--  * a sandbox (and the debug account): FUNDS ∞, dim, the cost never red.
--
--   luajit solar/tests/smoke_vab_funds.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local S = { ["co.funds"] = 19526 }
local KIT = 0
local B = { craftVersion = 1 }
function B.stats() return { parts = 4, mass = 1.2, cost = 964, dv = 800, twr = 1.4, launch = { warn = {} } } end

local scripts = {}
local function env()
  local e = setmetatable({}, { __index = _G })
  e.findScript = function(k) if k == "builder" then return B end return scripts[k] end
  e.save = { get = function(k) return S[k] end, set = function(k, v) S[k] = v end }
  e.time = 0
  e.log = function() end
  return e
end
local function load(path, name)
  local e = env()
  local chunk = assert(loadfile(path))
  setfenv(chunk, e)
  chunk()
  scripts[name] = e
  return e
end

local CO = load("solar/scripts/company.lua", "company")
scripts.builder_crew = { kitForLaunch = function() return { cost = KIT } end }
local SB = load("solar/scripts/builder_statusbar.lua", "builder_statusbar")

local function fig(k)
  for _, f in ipairs(SB.figures(B)) do if f.key == k then return f end end
end
local function fresh() SB.time = (SB.time or 0) + 1 end   -- past fundsState's quarter second

-- a career, in budget
S["co.booted"] = true
fresh()
local c, f = fig("cost"), fig("funds")
check(c and c.value == "$964" and c.tone == nil, "COST $964, not red: " .. tostring(c and c.value) .. " " .. tostring(c and c.tone))
check(f and f.value == "$19,526" and f.tone == nil, "FUNDS $19,526 beside it: " .. tostring(f and f.value) .. " " .. tostring(f and f.tone))
local order = {}
for _, x in ipairs(SB.figures(B)) do order[#order + 1] = x.key end
local ci, fi
for i, k in ipairs(order) do if k == "cost" then ci = i elseif k == "funds" then fi = i end end
check(ci and fi == ci + 1, "FUNDS sits right after COST: " .. table.concat(order, " "))

-- over budget
S["co.funds"] = 900
fresh()
c, f = fig("cost"), fig("funds")
check(c.tone == "danger" and f.tone == "danger" and f.value == "$900", "over budget: both red (" .. tostring(c.tone) .. ", " .. tostring(f.tone) .. ")")
-- exactly the money: affordable, as company.afford says
S["co.funds"] = 964
fresh()
check(fig("funds").tone == nil, "cost == funds is affordable")
-- the kit counts, as LAUNCH counts it
KIT = 50
fresh()
c, f = fig("cost"), fig("funds")
check(c.value == "$964 + $50 kit" and c.tone == "danger" and f.tone == "danger", "the kit pushes it over: " .. c.value)
KIT = 0

-- the toolbar's LAUNCH tip, over budget
S["co.funds"] = 100
fresh()
local fs = SB.fundsState(964)
check(fs.over and fs.funds == "$100" and not fs.unlimited, "fundsState over budget")

-- sandbox
S["game.mode"] = "sandbox"
fresh()
c, f = fig("cost"), fig("funds")
check(f.value == "∞" and f.tone == "dim" and c.tone == nil, "sandbox: FUNDS ∞ dim, the cost never red: " .. f.value .. " " .. tostring(f.tone))
S["game.mode"] = nil
-- the debug account
S["debug.rich"] = true
fresh()
f = fig("funds")
check(f.value == "∞" and fig("cost").tone == nil, "debug account: FUNDS ∞")
S["debug.rich"] = nil

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_vab_funds: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_vab_funds: all %d checks passed", passed))
