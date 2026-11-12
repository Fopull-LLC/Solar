-- SMOKE HARNESS: the Ops Board — select, then SIGN; the armed ABANDON; the ladder of
-- contracts you can't sign yet, and the Esc handshake with the pause menu.
--
--   luajit solar/tests/smoke_ops_board.lua

local T = 10.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local drawn
local presses = {}
local API = {
  input = { pressed = function(k) return presses[k] == true end,
            setMouseLocked = function() end },
  ui = { make = function(_, t) drawn = t end },
}

-- Every row the board draws, flattened (containers with `items` + a builder).
local function rows()
  local out = {}
  local function walk(t)
    if type(t) ~= "table" then return end
    out[#out + 1] = t
    for i = 2, #t do if type(t[i]) == "table" then walk(t[i]) end end
    if t.items then
      local build = t[#t]
      for _, it in ipairs(t.items) do
        if type(build) == "function" then walk(build(it)) else walk(it) end
      end
    end
  end
  walk(drawn)
  return out
end
local function button(key)
  for _, r in ipairs(rows()) do if r[1] == "button" and r.key == key then return r end end
end
local function says(needle)
  for _, r in ipairs(rows()) do
    if r.text and tostring(r.text):find(needle, 1, true) then return true end
  end
  return false
end

-- The missions it reads.
local CAT = {
  firstflight = { id = "firstflight", title = "First Flight", reward = 4500, rep = 1, brief = "Fly." },
  highroad = { id = "highroad", title = "The High Road", reward = 9000, rep = 1, brief = "Higher." },
  prospect = { id = "prospect", title = "Prospector", reward = 8000, rep = 1, brief = "Dig." },
}
local extra = false
local abandoned, accepted = 0, nil
local mi = { valid = true, active = nil }
function mi.byId(id) return CAT[id] end
function mi.offers()
  local out = mi.active and {} or { CAT.firstflight }
  if extra then out[#out + 1] = CAT.prospect end
  return out
end
function mi.upcoming() return { { m = CAT.highroad, needs = "First Flight" } } end
function mi.goalLines() return { "○ Reach 150 m" } end
function mi.accept(id) mi.active = id; accepted = id; return true end
function mi.abandon() mi.active = nil; abandoned = abandoned + 1; return true end
local co = { valid = true, money = function(v) return "$" .. v end,
             balance = function() return 3000 end, rep = function() return 0 end }
local played = {}
local sfx = { valid = true, play = function(k) played[#played + 1] = k end }
local walker = { valid = true, onFoot = true }
API.findScript = function(kind)
  return ({ missions = mi, company = co, sfx = sfx, planet_walker = walker })[kind]
end

local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/ops_board.lua"))
setfenv(chunk, env)
chunk()

local el = { visible = false }
local node = { getcomponent = function() return el end }
env.start(node)
env.openBoard()
local function tick() env.update(node, 1 / 60); presses = {}; T = T + 1 / 60 end
tick()

-- 1. Clicking a row SELECTS it; the SIGN button signs. Signing used to be a
-- single click on the row, so reading a contract and taking it were the same act.
ok(button("firstflight") ~= nil, "the offer is drawn as a button")
ok(env.selectedId() == "firstflight", "the first contract you could sign is selected on opening")
ok(says("Fly."), "…and its brief is in the detail pane")
button("firstflight").onClicked()
tick()
ok(accepted == nil, "clicking a row does NOT sign it")
ok(button("sign") ~= nil and not button("sign").disabled, "the detail pane has a SIGN button")
button("sign").onClicked()
ok(accepted == "firstflight", "SIGN signs the selected contract")
ok(played[#played] == "sign", "…and it sounds like it")
tick()
ok(says("On the books"), "the signed contract is on the books")
ok(button("sign") == nil, "…and its detail offers no SIGN")

-- 2. Abandoning is an explicit button that arms, then acts. It used to be a
-- second click on the row — a double-click nothing on screen mentioned.
ok(button("abandon") ~= nil, "the contract on the books has an ABANDON button")
button("firstflight").onClicked()
ok(abandoned == 0, "clicking the active row never abandons it")
button("abandon").onClicked()
ok(abandoned == 0, "the first ABANDON press does NOT abandon")
tick()
ok(says("Confirm") and button("abandon").selected == true, "…it arms, and the button says so")
button("abandon").onClicked()
ok(abandoned == 1, "the second press abandons it")

-- …and an armed abandon disarms itself if you walk away from the decision.
mi.accept("firstflight")
tick()
button("abandon").onClicked()
T = T + 5.0
tick()
button("abandon").onClicked()
ok(abandoned == 1, "a second press long after the first only re-arms")
ok(mi.active == "firstflight", "…and the contract stays on the books")

-- One contract at a time: another offer's SIGN is shown, disabled, with why.
-- (missions.accept would quietly REPLACE the one on the books, progress and all.)
extra = true
tick()
button("prospect").onClicked()
tick()
ok(button("sign") ~= nil and button("sign").disabled == true,
  "with a contract on the books, another offer's SIGN is disabled")
ok(says("One contract at a time"), "…and the pane says why")
button("sign").onClicked()
ok(mi.active == "firstflight", "…and pressing it anyway changes nothing")
extra = false

-- 3. The ladder: what you can't sign yet is shown, with what it waits for.
tick()
ok(says("Coming up"), "the board lists the contracts still to come")
ok(button("highroad") ~= nil, "…selectable, so you can read what it is")
button("highroad").onClicked()
tick()
ok(says("Unlocks after First Flight"), "…and its detail says what unlocks it")
ok(button("sign") == nil and button("abandon") == nil, "…with nothing to press")

-- The way back to the company overview, now that E opens the board directly.
ok(button("overview") ~= nil, "the board offers the Command Centre overview")

-- 4. Esc closes the board and marks the frame, so the pause menu leaves it be.
presses["escape"] = true
local at = T
tick()
ok(el.visible == false, "Esc closes the board")
ok(env.escTakenAt == at, "…and publishes the frame it spent the Esc on")

-- 5. (career missions E1) TWO ON THE BOOKS: a flight and a ground job, both
-- listed; the advance on the detail; a blocked offer says why; abandoning
-- names the advance going back and abandons THAT contract.
do
  CAT.bulk = { id = "bulk", title = "Bulk haul: 160 kg of Iron Ore", reward = 2200, rep = 1, ground = true, kind = "bulk", brief = "Haul." }
  CAT.survey = { id = "survey", title = "Survey: Ryethos", reward = 8000, rep = 2, gen = true, brief = "Fly by." }
  local booked = { "firstflight", "bulk" }
  mi.active = "firstflight"
  mi.actives = function() return booked end
  mi.slotGroup = function(m) return m.ground and "ground" or "flight" end
  mi.advanceFor = function(m) return (m.gen or m.ground) and math.floor(m.reward * 0.3) or 0 end
  mi.advancePaid = function(id) return id == "bulk" and 660 or 0 end
  mi.repOf = function(m) if m.ground then return 1, 8 end return m.rep or 0, nil end
  mi.signBlock = function(m) if m.id == "survey" then return "One flight contract at a time: finish or abandon First Flight first." end end
  co.standing = function(r) return { name = (r or 0) >= 8 and "Trusted" or "Unknown" } end
  local gid
  mi.goalLines = function(id) gid = id; return { "○ 160 kg of Iron Ore in the warehouse" } end
  local ab
  mi.abandon = function(id) ab = id; return true end
  local of = mi.offers
  mi.offers = function() return { CAT.survey } end
  env.openBoard()
  tick()
  ok(button("firstflight") ~= nil and button("bulk") ~= nil, "both contracts on the books are listed")
  ok(says("On the books · 2 of 2"), "…under 'On the books · 2 of 2'")
  button("bulk").onClicked()
  tick()
  ok(gid == "bulk", "the detail asks for THAT contract's goals")
  ok(says("ground job"), "…says it is the ground job")
  ok(says("Advance $660 paid at signing") and says("$1540 on completion"), "…shows the advance and what completion pays")
  ok(says("+1 reputation (up to Trusted)"), "…and that ground work's point stops at Trusted")
  button("abandon").onClicked(); tick()
  ok(says("returns the $660 advance"), "the armed abandon says the advance goes back")
  button("abandon").onClicked(); tick()
  ok(ab == "bulk", "…and abandons that contract, not the flight")
  button("survey").onClicked()
  tick()
  ok(button("sign") and button("sign").disabled == true and says("One flight contract at a time"),
    "an offer whose place is taken: SIGN greyed, the reason under it")
  ok(says("Advance $2400 on signing"), "…and its advance on signing is shown before you sign")
  mi.offers = of
end

if #failures == 0 then
  print(string.format("OPS BOARD SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("OPS BOARD SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
