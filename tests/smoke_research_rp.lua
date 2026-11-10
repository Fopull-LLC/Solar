-- SMOKE: research points as a currency (expansion X6, PLAN §7.4; Ty 11-09:
-- "RP is a currency on the expansion TECH"; scripts/research.lua).
--
--   * a TECH entry with `rp` is refused short of points, with how many;
--   * researching it spends the money and the points (the lab's tally goes
--     down, the spend is kept);
--   * the lock line and the price name both ("$6,000 + 40 RP");
--   * entries without `rp` cost money only, as before; what is researched
--     stays researched; a sandbox has everything;
--   * rpTree lists what RP buys.
--
--   luajit solar/tests/smoke_research_rp.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local store = {}
local money = 100000
local seen = { iron = true, silica = true, copper = true }
local company = {
  money = function(v) return "$" .. tostring(v) end,
  afford = function(v) return money >= v end,
  spend = function(v) if money < v then return false end money = money - v; return true end,
  rep = function() return 10 end,
}
local inventory = { seen = function(m) return seen[m] == true end }
local E = setmetatable({
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  findScript = function(k) if k == "company" then return company elseif k == "inventory" then return inventory end return nil end,
  log = function() end,
}, { __index = _G })
local f = assert(loadfile("solar/scripts/research.lua"))
setfenv(f, E)
f()
local R = E

check(R.rpOf("refinery") == 40 and R.rpOf("tankM") == 0, "rpOf: the refinery 40, the FT-M tank none")
store["res.pts"] = 12
local why = R.blockedBy("refinery")
check(why and why:find("needs 40 RP") and why:find("has 12"), "short of RP: " .. tostring(why))
local ok, w2 = R.unlock("refinery")
check(not ok and money == 100000 and store["res.pts"] == 12, "refused, nothing spent: " .. tostring(w2))
check(R.priceText("refinery", company.money) == "$6000 + 40 RP", "the price names both: " .. R.priceText("refinery", company.money))
check(R.lockLine("refinery"):find("40 RP"), "the lock line: " .. R.lockLine("refinery"))
store["res.pts"] = 100
check(R.lockLine("refinery"):find("%$6000 %+ 40 RP"), "the lock line, affordable: " .. R.lockLine("refinery"))
ok = R.unlock("refinery")
check(ok and money == 94000 and store["res.pts"] == 60 and R.rpSpent() == 40, string.format("bought: $%d left, %d RP left, %d spent", money, store["res.pts"], R.rpSpent()))
check(R.isUnlocked("refinery"), "researched stays researched")
check(R.unlock("refinery") == true and store["res.pts"] == 60, "researching again costs nothing")
-- a money-only entry: as before
ok = R.unlock("tankM")
check(ok and money == 93400 and store["res.pts"] == 60, "the FT-M tank: money only")
-- the electrolyser (120 RP) refused at 60
check(not R.unlock("electrolysis") and store["res.pts"] == 60, "the electrolyser refused at 60 RP")
-- what RP buys
local tree = R.rpTree()
local byId = {}
for _, t in ipairs(tree) do byId[t.id] = t end
check(#tree >= 6 and byId.refinery.done and not byId.electrolysis.done and byId.electrolysis.why, "rpTree: " .. #tree .. " entries, the refinery done, the electrolyser locked")
check(tree[1].rp <= tree[#tree].rp, "rpTree sorted by RP")
-- the sandbox has everything
store["game.mode"] = "sandbox"
check(R.isUnlocked("fabrication"), "a sandbox has the Fabricator")
store["game.mode"] = nil
-- an old save that researched by money keeps it (no RP owed)
store["res.done"].telescopeS = true
check(R.isUnlocked("telescopeS"), "an old save's Space Telescope stays researched though it now costs 200 RP")

for _, x in ipairs(failures) do print("FAIL: " .. x) end
print(string.format("smoke_research_rp: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
