-- SMOKE: the SANDBOX game mode (company.lua `isSandbox`, research.lua) and the
-- new-save panel's GAME MODE / CREW SAFETY (menu_newsave.lua), against stubs.
--
--   * a Sandbox save: the balance is unlimited ("∞"), anything is affordable,
--     spending and earning leave it there (the ledger still lists both),
--     reputation reads the maximum (Legend), so every standing gate is open,
--     losing reputation doesn't move it, and Mission Control never advances;
--   * research: the whole catalogue is open in a Sandbox save;
--   * a Career save (no `game.mode`, as every older save) is unchanged;
--   * CREATE writes game.mode, crew.safety and the crew.death boolean.
--
--   luajit solar/tests/smoke_sandbox.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function load(path, store, scripts, extra)
  local E = setmetatable({
    time = 1.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  local f = assert(loadfile(path))
  setfenv(f, E)
  f()
  if E.defaults then
    E.params = {}
    for k, v in pairs(E.defaults) do E.params[k] = v end
  end
  return E
end

local function company(store)
  local scripts = {}
  local co = load("solar/scripts/company.lua", store, scripts)
  scripts.company = co
  local rs = load("solar/scripts/research.lua", store, scripts)
  scripts.research = rs
  scripts.inventory = { seen = function() return false end }
  scripts.materials = { label = function(m) return m end }
  return co, rs
end

-- ── Career: today's rules ──────────────────────────────────────────────────
local cs = {}
local co, rs = company(cs)
co.start()
check(co.balance() == 500 and not co.isSandbox(), "career: the opening $500")
check(not co.afford(5000), "career: $5,000 is out of reach")
check(co.spend(400, "hull") and co.balance() == 100, "career: spending takes it off")
check(not co.spend(400, "hull"), "career: no overdraft")
check(co.rep() == 0 and co.standing().name == "Unknown", "career: reputation starts at 0")
co.addRep(4, "contract")
check(co.rep() == 4, "career: reputation moves")
check(co.money(1234567) == "$1,234,567", "career: money formats as before")
check(not rs.isUnlocked("skipper") and rs.blockedBy("skipper") ~= nil, "career: the Skipper is locked")
check(not rs.isUnlocked("rcs") and rs.blockedBy("rcs") ~= nil, "career: research has its gates")

-- ── Sandbox ────────────────────────────────────────────────────────────────
local ss = { ["game.mode"] = "sandbox" }
local so, sr = company(ss)
so.start()
check(so.isSandbox(), "sandbox: game.mode read")
check(so.balance() >= so.SANDBOX_FUNDS and so.money(so.balance()) == "∞", "sandbox: the balance reads ∞")
check(so.afford(1e12) and so.afford(4000), "sandbox: anything is affordable")
check(so.spend(250000, "hull: Big One") and so.money(so.balance()) == "∞", "sandbox: a $250,000 hull leaves it at ∞")
local l = ss["co.ledger"]
check(l and l[#l].amount == -250000 and l[#l].why == "hull: Big One", "sandbox: the ledger still lists the purchase")
so.earn(1000, "contract")
check(so.money(so.balance()) == "∞" and (ss["co.funds"] or 0) == 500, "sandbox: earning doesn't touch the books")
check(so.rep() == so.REP_MAX and so.standing().name == "Legend", "sandbox: reputation at the top (Legend)")
so.addRep(-5, "abandoned")
check(so.rep() == so.REP_MAX, "sandbox: losing reputation doesn't move it")
check(so.standingLine():match("Legend") ~= nil, "sandbox: the standing line says Legend")
check(so.advanceReady() == false, "sandbox: never an advance")
check(so.money(4500) == "$4,500", "sandbox: prices still read as prices")
for _, id in ipairs({ "skipper", "rcs", "dockPort", "dishL" }) do
  check(sr.isUnlocked(id) and sr.blockedBy(id) == nil and sr.lockLine(id) == nil, "sandbox: " .. id .. " is open")
end
check(sr.unlock("skipper") == true, "sandbox: unlock() answers yes")

-- ── the new-save panel's CREATE ────────────────────────────────────────────
local function create(m, s)
  local store = {}
  local ns = load("solar/scripts/menu_newsave.lua", store, {}, {
    find = function() return nil end,
    terrain = { saveDir = function() return "" end, deleteSaveDir = function() end },
    scene = { load = function() end },
    app = { version = function() return "0.117.0-rc38" end },
  })
  ns.save.slot = function() end
  ns.openFor(2)
  local m0, s0 = ns.options()
  if m then ns.setOptions(m, s) end
  ns.press("create")
  return store, m0, s0
end
local st, m0, s0 = create()
check(m0 == "career" and s0 == "death", "the panel opens on Career + Permadeath")
check(st["game.mode"] == "career" and st["crew.safety"] == "death" and st["crew.death"] == true, "CREATE: a career with permadeath")
st = create("sandbox", "invincible")
check(st["game.mode"] == "sandbox" and st["crew.safety"] == "invincible" and st["crew.death"] == false,
  "CREATE: Sandbox + Invincible stored")
st = create("career", "rescue")
check(st["crew.safety"] == "rescue" and st["crew.death"] == false, "CREATE: Rescue keeps the old boolean off")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_sandbox: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_sandbox: all %d checks passed", passed))
