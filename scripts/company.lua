-- COMPANY — the ledger the whole game is scored against: funds, reputation,
-- and an audit trail of every credit and debit.
--
-- It is deliberately *only* a ledger. It doesn't know what a rocket is, what a
-- mission is, or where the money came from; it takes an amount and a reason and
-- writes them down. Everything else — the builder charging for a hull, a
-- mission paying out, a recovery refunding what came home — calls in.
--
-- All state lives in `save.*`, so it survives the builder → system scene hop
-- (scripts don't) and rides the save slot (each slot is a separate company).
-- Mount this script on a node in EVERY scene that touches money; whichever copy
-- is loaded reads and writes the same keys.
--
-- Cross-script, the manager pattern:
--     local co = findScript("company")
--     if co.spend(1200, "hull: Kestrel I") then ... end
--     co.balance()   co.rep()   co.ledgerLines(6)

-- NOT quite enough for a first rocket, on purpose. At $12,000 the mining laser
-- and the depot were pointless, because the opening balance already bought four
-- rockets; at $3,000 it still bought two and a half, and the first five minutes
-- never touched the ground game at all. The cheapest thing that flies is about
-- $750 and a sensible first hopper about $1,100, so the opening is: sign the
-- First Flight, then mine and harvest for a few minutes — the first sale of each
-- material pays a discovery premium — and launch with money you earned. The
-- economy run in the agent report puts that launch at about six minutes in.
defaults = {
  start_funds = 500,     -- a fresh company's opening balance
}

-- ── STANDING ────────────────────────────────────────────────────────────────
-- Reputation used to clamp at 10 and do one thing: +4% on sale prices. Now it is
-- the company's track record, and it is what the rest of the game asks before it
-- offers you more:
--
--   * contract TIERS (missions.lua): survey work round your own moons opens at
--     Contractor, interplanetary work at Trusted, landings and hauls on other
--     planets at Prime;
--   * how many generated contracts the Ops Board holds at once;
--   * what a generated contract pays (`rewardMult`);
--   * what the depot pays (`priceMult`);
--   * the late catalogue (research.lua: RCS, Skipper, Docking Port).
--
-- It comes from finishing contracts (+1 to +5, scaled by difficulty), the first
-- sale of a rare material (+1), and is lost by walking away from a signed
-- contract (−1). Research no longer buys it: standing that money can buy is a
-- price, not a reputation.
REP_MIN, REP_MAX = -10, 30
STANDING = {
  { at = -10, name = "Blacklisted" },
  { at = 0,   name = "Unknown" },
  { at = 3,   name = "Contractor" },
  { at = 8,   name = "Trusted" },
  { at = 15,  name = "Prime" },
  { at = 25,  name = "Legend" },
}

-- Published so panels can render without a call.
funds = 0
reputation = 0

local LEDGER_MAX = 40    -- how many transactions we keep (the panel shows ~8)
local booted = false

-- DEBUG: the testing account. `cheats.lua` (F9) sets `debug.rich`, and while it
-- is on the balance reads as a number nothing costs a dent in and `spend` never
-- refuses. It is a flag on the LEDGER rather than a one-off top-up on purpose:
-- a big grant still runs out halfway through a builder session, and "did I fail
-- because of the bug or because I ran out of money?" is exactly the question a
-- test build should never make you ask. It rides the save slot, so it stays on
-- across the builder → system scene hop, and every slot decides for itself.
local RICH = 999999999
local function rich()
  return save.get("debug.rich") == true
end

-- First run on a slot seeds the opening balance. `co.booted` marks it done, so
-- a company that legitimately spends down to zero is never topped back up.
local function boot()
  if booted then return end
  booted = true
  if not save.get("co.booted") then
    save.set("co.booted", true)
    save.set("co.funds", params.start_funds)
    save.set("co.rep", 0)
    save.set("co.ledger", { { amount = params.start_funds, why = "seed capital", t = 0 } })
  end
  funds = save.get("co.funds") or 0
  reputation = save.get("co.rep") or 0
end

function start(node)
  boot()
end

function balance()
  boot()
  if rich() then return RICH end
  return save.get("co.funds") or 0
end

-- Is the testing account on? Panels say so out loud rather than quietly showing
-- an absurd number — a screenshot of a cheated run should be obviously cheated.
function isRich()
  return rich()
end

function rep()
  boot()
  return save.get("co.rep") or 0
end

local function record(amount, why)
  local l = save.get("co.ledger") or {}
  l[#l + 1] = { amount = amount, why = why or "—", t = time }
  while #l > LEDGER_MAX do table.remove(l, 1) end
  save.set("co.ledger", l)
end

-- Can we afford it? Asked by the builder before it lets you launch, so the
-- refusal is a sentence you can act on rather than a balance that went negative.
function afford(amount)
  return balance() >= (amount or 0)
end

-- Spend. Returns false and changes NOTHING if the money isn't there — callers
-- are expected to check, and a half-applied purchase is worse than a refusal.
function spend(amount, why)
  amount = math.max(0, math.floor(amount or 0))
  if amount == 0 then return true end
  if rich() then
    -- Still recorded: the ledger is how you check that the thing you clicked
    -- charged what it said it would, and that's worth having while testing.
    record(-amount, (why or "—") .. "  [debug]")
    log(string.format("company: −$%d  (%s)   [DEBUG FUNDS]", amount, why or "—"))
    return true
  end
  local b = balance()
  if b < amount then return false end
  save.set("co.funds", b - amount)
  funds = b - amount
  record(-amount, why)
  log(string.format("company: −$%d  (%s)   balance $%d", amount, why or "—", funds))
  return true
end

function earn(amount, why)
  amount = math.max(0, math.floor(amount or 0))
  if amount == 0 then return end
  local b = balance()
  save.set("co.funds", b + amount)
  funds = b + amount
  record(amount, why)
  log(string.format("company: +$%d  (%s)   balance $%d", amount, why or "—", funds))
  -- An advance on the books takes its share of every credit until it is paid.
  local owe = save.get("co.loan") or 0
  if owe > 0 and not rich() then
    local pay = math.min(owe, math.max(1, math.floor(amount * ADVANCE.share)))
    save.set("co.loan", owe - pay)
    save.set("co.funds", funds - pay)
    funds, loan = funds - pay, owe - pay
    record(-pay, owe - pay > 0 and "advance repayment" or "advance repaid in full")
    log(string.format("company: −$%d  (advance repayment, $%d still owed)   balance $%d",
      pay, owe - pay, funds))
  end
  -- Money arriving should be HEARD: a balance that changes silently in a
  -- corner is a payout nobody noticed.
  local s = findScript and findScript("sfx")
  if s and s.play then s.play("cash") end
end

-- ── THE ADVANCE: nobody is ever stuck ──────────────────────────────────────
-- Playtest 2026-10-26: "it's very hard to make money back up to where you were
-- and progress again". Three rockets in a crater could leave a company with
-- less than a starter hull and nothing to sell, and the only way out was a
-- long walk with a full pack, over and over.
--
-- So once the company has flown (the First Flight contract is done, so the
-- opening — mine, sell, launch with money you earned — is untouched), Mission
-- Control steps in when the balance sits under `below` for a few seconds: it
-- advances `amount`, enough for a starter rocket or a rover with a hold, and
-- takes `share` of everything earned afterwards until it is paid back. It is
-- a loan, not a gift: no reputation, no interest, and never a second one while
-- the first is owed — so it can't be farmed, only leaned on.
ADVANCE = {
  below = 300,      -- the balance under which the company counts as broke
  amount = 1500,    -- what Mission Control advances
  share = 0.25,     -- of every later credit, until it is repaid
  wait = 4.0,       -- seconds broke before it steps in (a purchase mid-click isn't "broke")
}
loan = 0            -- published: what is still owed on the advance

local broke_t = 0.0

-- What is owed on the advance (0 when nothing is).
function owed()
  return save.get("co.loan") or 0
end

-- Would Mission Control advance money right now, if the company stayed broke?
-- Pure on the save: the harness and a panel can ask without waiting.
function advanceReady()
  if rich() then return false, "debug funds" end
  if owed() > 0 then return false, "an advance is still owed" end
  local done = save.get("mission.done")
  if not (type(done) == "table" and done.firstflight) then return false, "fly the First Flight first" end
  if balance() >= ADVANCE.below then return false, "not broke" end
  return true, nil
end

-- Take the advance now (the update below calls it; so can a harness). Returns
-- the amount credited, or 0.
function advance()
  if not advanceReady() then return 0 end
  local a = ADVANCE.amount
  local b = balance()
  save.set("co.funds", b + a)
  save.set("co.loan", a)
  funds, loan = b + a, a
  save.set("co.loans", (save.get("co.loans") or 0) + 1)
  record(a, "Mission Control advance (repaid from income)")
  log(string.format("company: Mission Control advance +$%d — repaid from %d%% of income   balance $%d",
    a, math.floor(ADVANCE.share * 100 + 0.5), funds))
  local s = findScript and findScript("sfx")
  if s and s.play then s.play("cash") end
  local bc = findScript and findScript("big_caption")
  if bc and bc.show then
    bc.show("MISSION CONTROL ADVANCE",
      string.format("%s to keep the programme flying  ·  repaid from %d%% of what you earn",
        money(a), math.floor(ADVANCE.share * 100 + 0.5)), 6)
  end
  return a
end

-- Keep the published mirrors live for anything reading them as plain state.
function update(node, dt)
  boot()
  funds = save.get("co.funds") or 0
  reputation = save.get("co.rep") or 0
  loan = save.get("co.loan") or 0
  if advanceReady() then
    broke_t = broke_t + (dt or 0)
    if broke_t >= ADVANCE.wait then
      broke_t = 0
      advance()
    end
  else
    broke_t = 0
  end
end

-- Reputation moves slowly and clamps: it gates contracts and the catalogue, so
-- it must never run away on a lucky streak or bottom out unrecoverably.
function addRep(d, why)
  local before = rep()
  local r = math.max(REP_MIN, math.min(REP_MAX, before + (d or 0)))
  save.set("co.rep", r)
  reputation = r
  if d and d ~= 0 then
    log(string.format("company: reputation %+d → %d  (%s)", d, r, why or "—"))
    local a, b = standing(before), standing(r)
    if a.name ~= b.name then
      log(string.format("company: standing is now %s", b.name))
      save.set("co.standingNews", { name = b.name, up = r > before, t = time or 0 })
    end
  end
end

-- The standing a reputation adds up to: { name, at, level, nextAt, nextName }.
-- `level` counts from 1 = Unknown (Blacklisted is 0), so "tier ≥ 3" reads as
-- "Trusted or better" wherever it is asked.
function standing(r)
  r = r or rep()
  local idx = 1
  for i, s in ipairs(STANDING) do
    if r >= s.at then idx = i end
  end
  local s, nx = STANDING[idx], STANDING[idx + 1]
  return { name = s.name, at = s.at, level = idx - 1,
           nextAt = nx and nx.at or nil, nextName = nx and nx.name or nil }
end

-- "Contractor · 5 (Trusted at 8)" — the one line a panel shows.
function standingLine(r)
  r = r or rep()
  local s = standing(r)
  if s.nextAt then
    return string.format("%s · %+d  (%s at %d)", s.name, r, s.nextName, s.nextAt)
  end
  return string.format("%s · %+d", s.name, r)
end

-- What the depot pays against list price: +1.5% a point, so a Legend sells for
-- about +40% and a blacklisted company takes a 15% haircut.
function priceMult(r)
  r = math.max(REP_MIN, math.min(REP_MAX, r or rep()))
  return 1.0 + 0.015 * r
end

-- What a GENERATED contract pays against its base: +2% a point of standing,
-- never below list. The fixed ladder pays what it says.
function rewardMult(r)
  r = math.max(0, math.min(REP_MAX, r or rep()))
  return 1.0 + 0.02 * r
end

-- The most recent `n` transactions, newest first, formatted for a panel. The
-- amount goes through `money` like every other figure in the game; padding it
-- with `%-7d` only lined up in a monospace font, and "+$10450 probe" read as a
-- typo in this one.
function ledgerLines(n)
  local l = save.get("co.ledger") or {}
  local out = {}
  for i = #l, math.max(1, #l - (n or 8) + 1), -1 do
    local e = l[i]
    local amt = money(e.amount)
    if e.amount >= 0 then amt = "+" .. amt end
    out[#out + 1] = string.format("%s   ·   %s", amt, e.why or "—")
  end
  return out
end

-- Money, formatted the one way the whole game formats it.
function money(v)
  v = math.floor(v or 0)
  local s = tostring(math.abs(v))
  local out = ""
  while #s > 3 do
    out = "," .. s:sub(-3) .. out
    s = s:sub(1, -4)
  end
  return (v < 0 and "−$" or "$") .. s .. out
end
