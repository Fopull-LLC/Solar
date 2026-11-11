-- TIMBER — planks: sawn from timber at a Sawbench, bought at the Depot, and
-- what a timber kit piece is paid with (progression W1; work/progression/
-- PLAN.md §3.1; docs/base-building.md §35). Ty 11-11: "cheaper building
-- options like things made of wood for making bridges and simple structures".
--
-- On the Build Kit node (scenes/system.ron) beside machines.lua. The rules
-- are pure (luajit, tests/smoke_kit_wood.lua); the scene half is a menu on
-- every Sawbench and two rows on the Materials Intake's menu, and a job list
-- advanced once a second on the game clock.
--
--   PLANKS     a refined material (materials.lua `plank`), counted in kg. A
--              timber (what a tree yields, flora_gen; a log the intake took)
--              is a sawlog length: it saws to PLANK_PER_TIMBER kg of boards.
--   THE SAW    right-click a Sawbench: "Saw 1 / 5 / all timber". It takes
--              timber from your pack, then the warehouse, and saws on the game
--              clock (a long warp saws a lot): by hand HAND kg of planks a
--              minute, twice that if an Engineer set it up; on a base grid
--              that serves it (base_grid.partServed: its 0.6 kW is an aux load
--              while it saws, `gridAux`) POWERED kg a minute. Planks go to the
--              warehouse on the home world; off it, into the setter's pack (what
--              fits; the rest waits in the bench until there is room).
--   THE DEPOT  on the home world the Intake's menu sells planks by the lot,
--              PLANK_PRICE a kg plus the usual shipping (base_economy.shipping),
--              into the warehouse. The Sawbench's menu offers the same order.
--   PAYING     base_economy.quote takes a timber piece's planks (its mass) from
--              the warehouse and charges its fittings (parts_kit `fit`) when the
--              warehouse holds enough; otherwise its price ships it ready-cut.
--
-- SAVE: `timber.saw` = { { sid, uid, b, kg (planks to make), made (kg so far),
-- units (timber taken), by, eng, home, held (kg waiting for room) } }.
-- COST: nothing a frame; one look at the job list a second.

defaults = {}

PLANK_PER_TIMBER = 25      -- kg of boards from one timber (a sawlog length)
PLANK_PRICE = 0.6          -- $ a kg of planks at the Depot (shipping on top)
HAND = 10                  -- kg of planks a minute, by hand (an Engineer twice)
POWERED = 40               -- kg a minute on a served base grid
KW = 0.6                   -- the saw's motor
LOTS = { 100, 500 }        -- the Depot's lots (kg)
SAW_KEY = "timber.saw"

-- ── pure ────────────────────────────────────────────────────────────────────

-- kg of planks a second at a bench: on the grid, or by hand (an Engineer 2×).
function sawRate(powered, engineer)
  if powered then return POWERED / 60 end
  return HAND * (engineer and 2 or 1) / 60
end
-- Seconds to saw `kg` of planks.
function sawSecs(kg, powered, engineer) return (kg or 0) / sawRate(powered, engineer) end
-- kg of planks from `units` of timber.
function planksOf(units) return math.floor((units or 0) * PLANK_PER_TIMBER + 0.5) end
-- A Depot order of `kg` planks: → { cost, ship, total } (shipping by
-- base_economy's rule, 10 % + $50, when given; else that rule here).
function orderQuote(kg, shipping)
  local cost = math.floor((kg or 0) * PLANK_PRICE + 0.5)
  local ship = shipping and shipping(cost) or math.floor(cost * 0.10 + 50 + 0.5)
  return { cost = cost, ship = ship, total = cost + ship, kg = kg }
end
-- A job advanced by `dt` s at `rate` kg/s: → kg made this step (whole kg
-- are paid out; the fraction is carried in `job.frac`), done (bool).
function advance(job, dt, rate)
  local left = math.max(0, (job.kg or 0) - (job.made or 0))
  local want = math.min(left, (job.frac or 0) + rate * math.max(0, dt))
  local whole = math.floor(want + 1e-9)
  if left - whole < 1 and want >= left - 1e-9 then whole = math.floor(left + 0.5) end
  job.frac = want - whole
  job.made = (job.made or 0) + whole
  return whole, job.made >= (job.kg or 0)
end
-- The timber a stopped job gives back: what it hasn't sawn yet, whole logs.
function unsawn(job)
  return math.max(0, math.floor(((job.kg or 0) - (job.made or 0)) / PLANK_PER_TIMBER + 1e-9))
end
-- A job's status line.
function jobLine(job, powered, engineer)
  if not job then return "idle" end
  local left = math.max(0, (job.kg or 0) - (job.made or 0))
  local secs = sawSecs(left, powered, engineer)
  local how = powered and "on the grid" or (engineer and "by hand (an Engineer)" or "by hand")
  return string.format("%d / %d kg of planks · %s · %s left", job.made or 0, job.kg or 0, how,
    secs >= 3600 and string.format("%.1f h", secs / 3600) or string.format("%.0f min", math.max(1, secs / 60)))
end

-- ── the scene ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function sget(k) return save and save.get and save.get(k) or nil end
local function sset(k, v) if save and save.set then save.set(k, v) end end
local function game_now() return (space and space.time and space.time()) or (time or 0) end
local function home_body() return sget("base.body") end
local function jobs()
  local q = sget(SAW_KEY)
  return type(q) == "table" and q or {}
end
local function job_at(sid, uid)
  for i, j in ipairs(jobs()) do if j.sid == sid and j.uid == uid then return j, i end end
  return nil
end
local function served(j)
  local G = ref("base_grid")
  if not (G and G.partServed) then return false end
  local ok, s = pcall(G.partServed, j.sid, j.uid)
  return ok and s == true
end
local function money(v) local E = ref("base_economy"); return (E and E.money and E.money(v)) or ("$" .. tostring(v)) end

-- (base_grid's aux callback) the saw's motor while it saws
function gridAux(sid, uid)
  local j = job_at(sid, uid)
  return j and KW or 0
end

-- Hand planks to where they go: the warehouse at home, else the setter's
-- pack (what fits). → kg placed
local function deliver(j, kg)
  local inv = ref("inventory")
  if not inv or kg <= 0 then return 0 end
  if j.home then return inv.add("base", "plank", kg) end
  local got = j.pack and inv.add(j.pack, "plank", kg) or 0
  return got
end

local tick_t = 0
local last_t = nil
local function tick(dt)
  tick_t = tick_t + (dt or 0)
  if tick_t < 1.0 then return end
  tick_t = 0
  local now = game_now()
  local step = last_t and math.max(0, math.min(now - last_t, 86400 * 30)) or 0
  last_t = now
  local q = sget(SAW_KEY)
  if type(q) ~= "table" or #q == 0 or step <= 0 then return end
  local ST = ref("structures")
  local keep, said = {}, nil
  for _, j in ipairs(q) do
    local alive = not ST or not ST.getPart or ST.getPart(j.sid, j.uid) ~= nil
    if alive then
      local pw = served(j)
      local whole, done = advance(j, step, sawRate(pw, j.eng))
      local give = whole + (j.held or 0)
      local put = deliver(j, give)
      j.held = give - put
      if done and (j.held or 0) <= 0 then
        said = string.format("Sawbench: %d kg of planks sawn%s", j.kg or 0, j.home and " · in the warehouse" or " · in the pack")
      else
        keep[#keep + 1] = j
      end
    end
  end
  sset(SAW_KEY, keep)
  if said and log then log(said) end
end

-- Start sawing `n` timber (math.huge: all there is) at piece (sid, uid) for
-- actor `a` (ctx.actor). Takes from the pack, then the warehouse. → ok, why
function startSaw(sid, uid, n, a)
  local inv, ST = ref("inventory"), ref("structures")
  if not (inv and ST) then return false, "no inventory here" end
  if job_at(sid, uid) then return false, "it is already sawing: wait, or stop it" end
  local rec = ST.get and ST.get(sid)
  if not rec then return false, "that bench is gone" end
  local pack = a and a.pack
  local home = rec.b ~= nil and rec.b == home_body()
  local have_p = pack and (inv.count(pack, "timber") or 0) or 0
  local have_w = home and (inv.count("base", "timber") or 0) or 0
  local want = math.min(n or 1, have_p + have_w)
  if want <= 0 then
    return false, home and "no timber in your pack or the warehouse: fell a tree (the laser's CUT) and bring the logs to the intake"
      or "no timber in your pack"
  end
  local took = 0
  if pack and have_p > 0 then took = took + (inv.remove(pack, "timber", math.min(want, have_p)) or 0) end
  if took < want and have_w > 0 then took = took + (inv.remove("base", "timber", want - took) or 0) end
  if took <= 0 then return false, "couldn't take the timber" end
  local cl = ref("crew")
  local eng = a and a.id and cl and cl.hasRole and cl.hasRole(a.id, "engineer") == true or false
  local q = jobs()
  q[#q + 1] = { sid = sid, uid = uid, b = rec.b, kg = planksOf(took), made = 0, units = took, by = a and a.id or nil,
                eng = eng, home = home, pack = (not home) and pack or nil }
  sset(SAW_KEY, q)
  local G = ref("base_grid")
  if G and G.markDirty then G.markDirty() end
  return true, string.format("sawing %d timber → %d kg of planks", took, planksOf(took))
end

-- Stop a bench: what it hasn't sawn goes back as timber (to the warehouse
-- at home, else the pack). → ok, why
function stopSaw(sid, uid, a)
  local j, i = job_at(sid, uid)
  if not j then return false, "it isn't sawing" end
  local inv = ref("inventory")
  local back = unsawn(j)
  if inv and back > 0 then
    local dest = j.home and "base" or (a and a.pack) or j.pack
    if dest then inv.add(dest, "timber", back) end
  end
  if inv and (j.held or 0) > 0 then deliver(j, j.held) end
  local q = jobs()
  table.remove(q, i)
  sset(SAW_KEY, q)
  local G = ref("base_grid")
  if G and G.markDirty then G.markDirty() end
  return true, string.format("stopped · %d kg sawn · %d timber back", j.made or 0, back)
end

-- Order `kg` of planks from the Depot into the warehouse (home world only). → ok, why
function orderPlanks(kg)
  local inv, co, E = ref("inventory"), ref("company"), ref("base_economy")
  if not (inv and co) then return false, "the depot isn't reachable" end
  local q = orderQuote(kg, E and E.shipping)
  if co.spend and not co.spend(q.total, string.format("planks, %d kg · %s + %s shipping (shipped by Halden Structural)", kg, money(q.cost), money(q.ship))) then
    return false, "not enough money: " .. money(q.total)
  end
  local got = inv.add("base", "plank", kg)
  return true, string.format("%d kg of planks into the warehouse · %s", got, money(q.total))
end

-- The Depot's rows (the Materials Intake's menu calls this; and the Sawbench's).
function depotRows(out, ctx, group)
  local inv, E = ref("inventory"), ref("base_economy")
  if not inv then return end
  local G = group or "TIMBER YARD"
  out[#out + 1] = { type = "info", id = "tb_stock", group = G, label = "WAREHOUSE", value = function()
      return string.format("%d kg of planks · %d timber", inv.count("base", "plank") or 0, inv.count("base", "timber") or 0) end }
  for _, kg in ipairs(LOTS) do
    local q = orderQuote(kg, E and E.shipping)
    out[#out + 1] = { type = "action", id = "tb_buy" .. kg, group = G, label = string.format("Order %d kg of planks", kg),
      hint = money(q.total),
      act = function()
        local ok, why = orderPlanks(kg)
        if ctx and ctx.toast then ctx.toast(why, not ok) end
        return ok, why
      end }
  end
end

-- ── the Sawbench's menu ─────────────────────────────────────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, FB, PB = ref("structures"), ref("field_builder"), ref("parts_base")
  if not (ST and PB) then return {} end
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) elseif ST.partOfNode then rec, part = ST.partOfNode(t.node) end
  if not (rec and part) then return {} end
  local d = PB.partInfo(part.id)
  if not (d and d.saw) then return {} end
  local sid, uid = rec.id, part.uid
  local a = ctx and ctx.actor
  local inv = ref("inventory")
  local G = "Sawbench"
  local out = {}
  out[#out + 1] = { type = "info", id = "tb_saw", group = G, label = "SAW", value = function()
      local j = job_at(sid, uid)
      if not j then return "idle · " .. string.format("by hand %d kg a minute, on the grid %d", HAND, POWERED) end
      return jobLine(j, served(j), j.eng)
    end }
  local function timber_n()
    local n = (a and a.pack and inv and inv.count(a.pack, "timber")) or 0
    if rec.b == home_body() and inv then n = n + (inv.count("base", "timber") or 0) end
    return n
  end
  for _, n in ipairs({ 1, 5, math.huge }) do
    out[#out + 1] = { type = "action", id = "tb_go" .. (n == math.huge and "all" or n), group = G,
      label = function()
        if n == math.huge then return string.format("Saw all the timber (%d)", timber_n()) end
        return string.format("Saw %d timber (%d kg of planks)", n, planksOf(n))
      end,
      enabled = function() return not job_at(sid, uid) and timber_n() >= (n == math.huge and 1 or n) end,
      why = function() return job_at(sid, uid) and "it is sawing" or "not enough timber in your pack or the warehouse" end,
      act = function()
        local ok, why = startSaw(sid, uid, n, a)
        if ctx and ctx.toast then ctx.toast(why, not ok) end
        return ok, why
      end }
  end
  out[#out + 1] = { type = "action", id = "tb_stop", group = G, label = "Stop sawing",
    enabled = function() return job_at(sid, uid) ~= nil end, why = function() return "it isn't sawing" end,
    act = function()
      local ok, why = stopSaw(sid, uid, a)
      if ctx and ctx.toast then ctx.toast(why, not ok) end
      return ok, why
    end }
  if rec.b == home_body() then depotRows(out, ctx, "Depot") end
  return out, "SAWBENCH", "timber → planks"
end
providerFn = provider

local reg_on, reg_t = false, -10
function update(node, dt)
  local t = time or 0
  if not reg_on and t - reg_t > 1.0 then
    reg_t = t
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "timber", order = 5 }); reg_on = true end
  end
  tick(dt)
end
function start(node) reg_on = false; last_t = nil end
