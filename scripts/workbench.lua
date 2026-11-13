-- WORKBENCH — parts made by hand from a base's own stock (playtest 11-12b;
-- work/baseloop/DESIGN.md phase 5). "Craft parts out of materials at
-- workbenches, drawing on a material storage … I don't want to go back to the
-- main base constantly or buy everything with money."
--
-- On the Build Kit node (scenes/system.ron) beside refinery.lua and timber.lua.
-- The rules are pure (tests/smoke_workbench.lua); the scene half finds the
-- stock, runs the jobs and puts the menu on every Workbench (parts_kit
-- `workbench`, the prop that was only drawers until now).
--
-- ── THE LOOP ────────────────────────────────────────────────────────────────
--   refined materials (Steel, Alloy, Wiring, Glass, Regocrete, Planks)
--     → THE STOCK: every container within 60 m of the bench: its own drawers,
--       lockers and crates, silos and hoppers, machine outlets, a
--       Fabricator's store, the warehouse when the bench is at the spaceport,
--       and the pack of whoever works it
--     → the BENCH: a job at a time, worked by a crew member standing at it
--     → a crated part (`part:<id>`) or a tool, into the bench's drawers:
--       where the Build Kit's reach finds it (field_builder.reachScan)
--
-- ── WHAT A BENCH MAKES ──────────────────────────────────────────────────────
--   kit pieces up to 150 kg (walls, floors, doors, lights, breakers, junction
--   boxes …), by recipes.recipeFor: the Fabricator's own recipes; and TOOLS
--   (Repair Kit, Relay Beacon, Flashlight, Gas Can, Company Flag).
--   Anything heavier wants a Fabricator: powered, queued, nobody standing by.
--
-- ── TIME AND SKILL ──────────────────────────────────────────────────────────
--   by hand a part takes HAND_K (3) times the Fabricator's seconds, and
--   someone must be AT the bench (within 2.6 m) for the clock to run;
--   an Engineer works at twice the pace and wastes nothing; anyone else
--   loses 10 % of the materials; every part a member has made raises their
--   pace a little (to +50 % at 100 parts; `bench.made.<member>`).
--   Fittings (the valves, seals and chips a recipe prices in money) are paid
--   as the Fabricator's are; a sandbox game waives them.
--
-- ── SAVE ────────────────────────────────────────────────────────────────────
--   bench.<sid>.<uid> = { q = { { id, n, t, started, by, need } … } }
--   bench.list        = { "<sid>.<uid>" … } the benches with a queue
--   bench.made.<id>   = parts a crew member has made at a bench
--
-- COST: nothing while no bench has a job; with one, a 4 Hz step (a distance
-- test a crew member). The stock is scanned when a job starts, the menu
-- opens, or the panel repaints (2 Hz).
--
-- Probes: makes(def, r), queue(sid, uid, id, n), cancel(sid, uid, k),
-- benchOf(sid, uid), stockOf(sid, uid), have(sid, uid, mat), step(dt), PROF.

HAND_K = 3.0          -- a hand's seconds for one of the Fabricator's
MAX_KG = 150          -- the heaviest part a bench turns out
WASTE = 0.10          -- a hand that is not an Engineer's loses this share
REACH = 60.0          -- the stock: containers this near the bench
WORK_R = 2.6          -- "at the bench"
QUEUE = 4
PRACTICE_N, PRACTICE_K = 100, 0.5
PROF = { made = 0, steps = 0 }

-- The tools a bench makes: { mats = { { mat, kg } … }, secs (the Fabricator's
-- clock: × HAND_K by hand), fittings ($) }.
TOOLS = {
  repairkit  = { mats = { { mat = "steel", kg = 3 }, { mat = "wiring", kg = 1 } }, secs = 20, fittings = 15 },
  beacon     = { mats = { { mat = "steel", kg = 3 }, { mat = "wiring", kg = 2 }, { mat = "glass", kg = 1 } }, secs = 30, fittings = 20 },
  flashlight = { mats = { { mat = "steel", kg = 1 }, { mat = "wiring", kg = 1 }, { mat = "glass", kg = 1 } }, secs = 10, fittings = 5 },
  gascan     = { mats = { { mat = "steel", kg = 3 } }, secs = 10, fittings = 0 },
  flag       = { mats = { { mat = "steel", kg = 2 }, { mat = "plank", kg = 1 } }, secs = 10, fittings = 0 },
}
TOOL_ORDER = { "repairkit", "beacon", "flashlight", "gascan", "flag" }
function toolId(id) return "tool:" .. tostring(id) end
function toolOf(id) return type(id) == "string" and id:match("^tool:(.+)$") or nil end

-- ── pure ────────────────────────────────────────────────────────────────────
-- Does a bench make this part? `def` its part record, `r` its recipe.
-- → true | false, why
function makes(def, r)
  if not (def and r) then return false, "it has no recipe" end
  if r.shipOnly then return false, "made at home only: " .. tostring(r.shipOnly) end
  if r.perMetre then return false, "a cable is laid by the metre, not made at a bench" end
  if not def.kit then return false, "a bench makes the kit's pieces; this wants a Fabricator" end
  if (r.kg or r.total or 0) > MAX_KG + 1e-9 then return false, string.format("%d kg: too heavy for a bench (over %d kg wants a Fabricator)", math.floor((r.kg or r.total) + 0.5), MAX_KG) end
  if (r.total or 0) <= 0 then return false, "it has no recipe" end
  return true
end
-- A hand's pace: an Engineer 2, anyone else 1; practice adds up to half.
function paceOf(engineer, made)
  local base = engineer and 2.0 or 1.0
  return base * (1 + PRACTICE_K * math.min(1, (made or 0) / PRACTICE_N))
end
-- The materials a job takes from the stock: the recipe's, plus the waste of a
-- hand that is not an Engineer's (whole kg, rounded up). → { { mat, kg } … }
function needOf(r, engineer)
  local out = {}
  for _, m in ipairs((r and r.mats) or {}) do
    local kg = m.kg * (engineer and 1 or (1 + WASTE))
    out[#out + 1] = { mat = m.mat, kg = math.ceil(kg - 1e-9), label = m.label }
  end
  return out
end
-- The hand's seconds of a recipe at pace 1.
function secsOf(r) return ((r and r.secs) or 10) * HAND_K end
-- One job's step. j = { id, n, t, started, need }, env = { recipe(id), have(mat),
-- take(mats) → ok, pay($) → ok, put(id) → ok, worker() → { engineer, made, id } | nil }.
-- → why it waits (or nil), parts made
function advance(B, dt, env)
  B.q = B.q or {}
  local made, why = 0, nil
  local guard = 0
  while #B.q > 0 and guard < 32 do
    guard = guard + 1
    local j = B.q[1]
    local r = env.recipe(j.id)
    if not r then table.remove(B.q, 1); why = "a bench can't make that"
    elseif j.done then
      if env.put(j.id, j.by) then
        made = made + 1
        j.done, j.started, j.t, j.need = nil, nil, 0, nil
        j.n = (j.n or 1) - 1
        if j.n <= 0 then table.remove(B.q, 1) end
      else why = "no room for it: the stores round the bench are full"; break end
    else
      local w = env.worker()
      if not w then why = "nobody at the bench: stand at it and the work goes on"; break end
      if not j.started then
        local need = needOf(r, w.engineer)
        local short = nil
        for _, e in ipairs(need) do if (env.have(e.mat) or 0) + 1e-9 < e.kg then short = short or e end end
        if short then
          why = string.format("short of %s: %d of %d kg in the stock round the bench", short.label or short.mat, math.floor(env.have(short.mat) or 0), short.kg)
          break
        end
        if (r.fittings or 0) > 0 and not env.pay(r.fittings) then why = string.format("fittings: $%d short", r.fittings); break end
        if not env.take(need) then why = "the stock moved: not enough any more"; break end
        j.started, j.t, j.by, j.need = true, 0, w.id, need
      end
      if dt <= 1e-12 then break end
      local pace = paceOf(w.engineer, w.made)
      local left = secsOf(r) - (j.t or 0)
      local can = dt * pace
      if can + 1e-9 >= left then
        dt = dt - left / pace
        j.t = secsOf(r)
        j.done = true
        j.by = w.id
      else
        j.t = (j.t or 0) + can
        dt = 0
        break
      end
    end
  end
  return why, made
end
function queued(B)
  local n = 0
  for _, j in ipairs((B and B.q) or {}) do n = n + (j.n or 1) end
  return n
end

-- ── the scene ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function keyOf(sid, uid) return tostring(sid) .. "." .. tostring(uid) end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function is_bench(d) return d ~= nil and d.kit == true and d.piece == "workbench" end
local function benchCid(sid, uid) return "piece:" .. tostring(sid) .. ":" .. tostring(uid) end

local B_ = {}           -- key → { q }
local why_ = {}         -- key → why its head waits
local function load_bench(sid, uid)
  local k = keyOf(sid, uid)
  if B_[k] then return B_[k] end
  local s = save and save.get and save.get("bench." .. k)
  B_[k] = (type(s) == "table" and type(s.q) == "table") and { q = s.q } or { q = {} }
  return B_[k]
end
local function active_list()
  local l = save and save.get and save.get("bench.list")
  return type(l) == "table" and l or {}
end
local function save_bench(sid, uid)
  if not (save and save.set) then return end
  local k = keyOf(sid, uid)
  local B = B_[k]
  local l, has = active_list(), false
  for i = #l, 1, -1 do if l[i] == k then has = true; if not (B and #B.q > 0) then table.remove(l, i) end end end
  if B and #B.q > 0 then
    save.set("bench." .. k, { q = B.q })
    if not has then l[#l + 1] = k end
  elseif save.delete then save.delete("bench." .. k) else save.set("bench." .. k, false) end
  save.set("bench.list", l)
end

-- The recipe of a bench job: a part's (the Fabricator's own), or a tool's.
function recipeOf(id)
  local t = toolOf(id)
  if t then
    local T = TOOLS[t]
    if not T then return nil end
    local I = ref("items")
    local it = I and I.ITEMS and I.ITEMS[t]
    local M = ref("materials")
    local mats, total = {}, 0
    for _, m in ipairs(T.mats) do mats[#mats + 1] = { mat = m.mat, kg = m.kg, label = M and M.label and M.label(m.mat) or m.mat }; total = total + m.kg end
    return { id = id, tool = t, kg = it and it.kg or total, mats = mats, total = total, fittings = T.fittings or 0, secs = T.secs or 10,
             label = it and it.name or t }
  end
  local FB = ref("field_builder")
  local r = FB and FB.recipeOf and FB.recipeOf(id) or nil
  if not r then return nil end
  local ok = makes(FB.partInfo and FB.partInfo(id), r)
  return ok and r or nil
end
function labelOf(id)
  local t = toolOf(id)
  if t then local I = ref("items"); local it = I and I.ITEMS and I.ITEMS[t]; return it and it.name or t end
  local d = defs(id)
  return d and (d.label .. ((d.matLabel and d.matLabel ~= "Steel") and (" · " .. d.matLabel) or "")) or tostring(id)
end

-- THE STOCK round a bench: its containers, nearest first (its own drawers
-- first of all), the warehouse at the spaceport, the worker's pack last.
-- → { cid … }, { [cid] = label }
local stock_memo = {}
function stockOf(sid, uid)
  local k = keyOf(sid, uid)
  local ST, LG = ref("structures"), ref("logistics")
  local m = stock_memo[k]
  if m and m.v == (ST and ST.version) and now() - m.t < 2.0 then return m.list, m.names end
  local list, names, seen = {}, {}, {}
  local function add(cid, label) if cid and not seen[cid] then seen[cid] = true; list[#list + 1] = cid; names[cid] = label end end
  add(benchCid(sid, uid), "its drawers")
  local rec = ST and ST.get and ST.get(sid)
  local p = rec and ST.getPart(sid, uid)
  if p and ST.partsNear and ST.partPose then
    local x, y, z = ST.partPose(rec, p, 0)
    for _, e in ipairs(ST.partsNear(rec.b, x, y, z, REACH)) do
      local d = defs(e.part.id)
      if d and d.container then add("piece:" .. tostring(e.rec.id) .. ":" .. tostring(e.part.uid), d.label)
      elseif d and d.it and LG and LG.storeCid then
        local a, b2 = LG.storeCid(d.it, e.rec.id, e.part.uid)
        if d.it.kind == "machine" then add(b2, d.label .. " outlet") else add(a, d.label) end
      end
    end
    -- the warehouse, when the bench stands at the spaceport
    local bf = ref("base_facilities")
    local fp = bf and bf.footprint
    if fp and fp.body == rec.b and (x - fp.x) ^ 2 + (y - fp.y) ^ 2 + (z - fp.z) ^ 2 <= 400 * 400 then add("base", "the warehouse") end
  end
  stock_memo[k] = { list = list, names = names, v = ST and ST.version, t = now() }
  return list, names
end
-- who is at the bench: the member you are, when on foot within WORK_R (their
-- pack joins the stock); else a crew member posted there. → { id, engineer, made, pack } | nil
local function worker_at(sid, uid)
  local ST, C = ref("structures"), ref("crew")
  local rec = ST and ST.get and ST.get(sid)
  local p = rec and ST.getPart(sid, uid)
  local b = rec and space and space.body and space.body(rec.b)
  if not (p and b and C) then return nil end
  local x, y, z = ST.partPose(rec, p, 0.9)
  local best = nil
  local function consider(id, px, py, pz, pack)
    if (px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2 > WORK_R * WORK_R then return end
    local okr, eng = pcall(C.hasRole, id, "engineer")
    local w = { id = id, engineer = okr and eng == true, made = tonumber(save.get("bench.made." .. tostring(id))) or 0, pack = pack }
    if not best or (w.engineer and not best.engineer) then best = w end
  end
  local pw = ref("planet_walker")
  local a = find and find("Astronaut")
  local me = C.activeId and C.activeId()
  if a and a.valid ~= false and pw and pw.onFoot == true and me ~= nil and not (C.dying and C.dying()) then
    consider(me, a.x - b.x, a.y - b.y, a.z - b.z, "astro")
  end
  for _, r in ipairs(C.roster and C.roster() or {}) do
    if r.id ~= me and r.status == "afoot" and r.body == rec.b and r.x then consider(r.id, r.x, r.y, r.z, C.packOf and C.packOf(r.id) or nil) end
  end
  return best
end
function workerAt(sid, uid) return worker_at(sid, uid) end

-- a material in the stock (with the worker's pack, when someone is there)
local function stores_for(sid, uid, w)
  local list = stockOf(sid, uid)
  if w and w.pack then
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c end
    out[#out + 1] = w.pack
    return out
  end
  return list
end
function have(sid, uid, mat)
  local inv = ref("inventory")
  if not inv then return 0 end
  local n = 0
  for _, cid in ipairs(stores_for(sid, uid, worker_at(sid, uid))) do n = n + (inv.count(cid, mat) or 0) end
  return n
end
local function env_of(sid, uid)
  local inv, co, R = ref("inventory"), ref("company"), ref("recipes")
  return {
    recipe = recipeOf,
    worker = function() return worker_at(sid, uid) end,
    have = function(mat) return have(sid, uid, mat) end,
    take = function(mats)
      local order = stores_for(sid, uid, worker_at(sid, uid))
      for _, e in ipairs(mats) do if have(sid, uid, e.mat) + 1e-9 < e.kg then return false end end
      for _, e in ipairs(mats) do
        local left = e.kg
        for _, cid in ipairs(order) do
          if left <= 0 then break end
          local h = inv.count(cid, e.mat) or 0
          if h > 0 then left = left - (inv.remove(cid, e.mat, math.min(h, left)) or 0) end
        end
      end
      return true
    end,
    pay = function(f)
      if (f or 0) <= 0 then return true end
      if save and save.get and save.get("game.mode") == "sandbox" then return true end
      if not (co and co.spend) then return true end
      return co.spend(f, "Workbench fittings") == true
    end,
    put = function(id, by)
      local t = toolOf(id)
      local item = t or ((R and R.partItemId and R.partItemId(id)) or ("part:" .. tostring(id)))
      -- (it is set down on the bench: its drawers take it whatever they
      -- hold, as a part too big for a drawer stands on the top)
      local ok, n = pcall(inv.addItem, benchCid(sid, uid), item, 1, { force = true })
      if ok and (tonumber(n) or 0) > 0 then return true end
      for _, cid in ipairs(stores_for(sid, uid, worker_at(sid, uid))) do
        local ok2, n2 = pcall(inv.addItem, cid, item, 1)
        if ok2 and (tonumber(n2) or 0) > 0 then return true end
      end
      return false
    end,
  }
end

-- The queue: n of `id` (a part id, or "tool:<item>"). → ok, why
function queue(sid, uid, id, n)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not (p and is_bench(defs(p.id))) then return false, "not a Workbench" end
  local r = recipeOf(id)
  if not r then
    local FB = ref("field_builder")
    local d = FB and FB.partInfo and FB.partInfo(id)
    local _, why = makes(d, FB and FB.recipeOf and FB.recipeOf(id))
    return false, why or "a bench can't make that"
  end
  if not toolOf(id) then
    local rs = ref("research")
    local d0 = defs(id)
    local rid = d0 and (d0.vab or d0.tech) or id
    if rs and rs.isUnlocked and not rs.isUnlocked(rid) then return false, "not researched: " .. tostring(rs.lockLine and rs.lockLine(rid) or rid) end
  end
  local B = load_bench(sid, uid)
  n = math.max(1, math.floor(n or 1))
  for _, j in ipairs(B.q) do
    if j.id == id and not j.started then j.n = (j.n or 1) + n; save_bench(sid, uid); return true end
  end
  if #B.q >= QUEUE then return false, string.format("the bench has %d jobs waiting", QUEUE) end
  B.q[#B.q + 1] = { id = id, n = n, t = 0 }
  save_bench(sid, uid)
  return true
end
-- Cancel job k: what a started job took goes back to the drawers (or stays
-- on the bench's floor: the pack, then lost only if nothing has room).
function cancel(sid, uid, k)
  local B = load_bench(sid, uid)
  local j = B.q[k]
  if not j then return false end
  if j.started and not j.done then
    local inv = ref("inventory")
    for _, e in ipairs(j.need or {}) do
      local left = e.kg
      for _, cid in ipairs(stores_for(sid, uid, worker_at(sid, uid))) do
        if left <= 0 then break end
        left = left - (inv.add(cid, e.mat, left) or 0)
      end
    end
  end
  table.remove(B.q, k)
  save_bench(sid, uid)
  return true
end
-- → B ({ q }), P ({ label }), s ({ duty (the pace now, 0 with nobody there), fwhy, worker })
function benchOf(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  if not is_bench(d) then return nil end
  local w = worker_at(sid, uid)
  return load_bench(sid, uid), { label = d.label or "Workbench", bench = true },
    { duty = w and paceOf(w.engineer, w.made) or 0, fwhy = why_[keyOf(sid, uid)], worker = w }
end
function isBench(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  return p ~= nil and is_bench(defs(p.id))
end

-- One step of every bench with a queue. → parts made
function step(dt)
  local made_all = 0
  local l = active_list()
  if #l == 0 then return 0 end
  PROF.steps = PROF.steps + 1
  for i = #l, 1, -1 do
    local sid, uid = tostring(l[i]):match("^(.-)%.([^.]+)$")
    sid, uid = tonumber(sid) or sid, tonumber(uid) or uid
    if not isBench(sid, uid) then
      -- (the bench is gone: its queue with it)
      B_[l[i]] = { q = {} }
      save_bench(sid, uid)
    else
      local B = load_bench(sid, uid)
      local n0 = queued(B)
      local t0 = B.q[1] and B.q[1].t or 0
      local why, made = advance(B, dt, env_of(sid, uid))
      why_[l[i]] = why
      if made > 0 then
        made_all = made_all + made
        PROF.made = PROF.made + made
        local by = nil
        local w = worker_at(sid, uid)
        by = w and w.id
        if by ~= nil then save.set("bench.made." .. tostring(by), (tonumber(save.get("bench.made." .. tostring(by))) or 0) + made) end
        local FT = ref("feats")
        if FT and FT.mark then pcall(FT.mark, "part_crafted", { n = made }) end
        local C = ref("crew")
        if C and C.credit and by ~= nil then pcall(C.credit, by, "built", made) end
        if caption then pcall(caption, string.format("Workbench: made, in its drawers (%d left to make)", queued(B))) end
        local sfx = ref("sfx")
        if sfx and sfx.play then pcall(sfx.play, "click") end
      end
      if made > 0 or queued(B) ~= n0 or math.floor(((B.q[1] and B.q[1].t) or 0) / 5) ~= math.floor(t0 / 5) or (B.q[1] and B.q[1].started and t0 == 0) then
        save_bench(sid, uid)
      end
    end
  end
  return made_all
end

-- ── the menu ────────────────────────────────────────────────────────────────
local function kgs(v) return string.format("%d kg", math.floor((v or 0) + 0.5)) end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, FB = ref("structures"), ref("field_builder")
  if not ST then return {} end
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) elseif ST.partOfNode then rec, part = ST.partOfNode(t.node) end
  if not (rec and part and is_bench(defs(part.id))) then return {} end
  local sid, uid = rec.id, part.uid
  local G = "Workbench"
  local out = {}
  out[#out + 1] = { id = "wb_job", type = "info", group = G, label = "On the bench", value = function()
      local B, _, s = benchOf(sid, uid)
      local j = B and B.q[1]
      if not j then return "nothing: pick a part to make" end
      local r = recipeOf(j.id)
      local pr = (j.started and r) and math.min(1, (j.t or 0) / math.max(1, secsOf(r))) or 0
      return string.format("%s ×%d · %d %%%s", labelOf(j.id), j.n or 1, math.floor(pr * 100 + 0.5), s and s.fwhy and (" · " .. s.fwhy) or "")
    end }
  out[#out + 1] = { id = "wb_stock", type = "info", group = G, label = "Stock in reach", value = function()
      local M = ref("materials")
      local parts = {}
      for _, m in ipairs((M and M.REFINED) or { "steel", "alloy", "wiring", "glass", "regocrete", "plank" }) do
        local n = have(sid, uid, m)
        if n > 0 then parts[#parts + 1] = string.format("%s %s", (M and M.label and M.label(m)) or m, kgs(n)) end
      end
      local list = stockOf(sid, uid)
      return (#parts > 0 and table.concat(parts, " · ") or "no refined materials") .. string.format(" · %d store%s within %d m", #list, #list == 1 and "" or "s", REACH)
    end }
  out[#out + 1] = { id = "wb_work", type = "action", group = G, label = "Work at the bench: make a part", hint = "▸",
    act = function()
      local FP = ref("fab_panel")
      if FP and FP.open and FP.open(sid, uid, "bench") then return true end
      return false, "the recipe panel isn't in this scene"
    end }
  return out, "WORKBENCH", "parts by hand from the stock round it"
end
providerFn = provider

local reg_on, reg_t, acc, last_t = false, -10, 0, nil
function start(node)
  if findScripts then
    local all = findScripts("workbench")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  B_, why_, stock_memo, reg_on, acc, last_t = {}, {}, {}, false, 0, nil
end
function update(node, dt)
  if not reg_on and now() - reg_t > 1.0 then
    reg_t = now()
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "workbench", order = 5 }); reg_on = true end
  end
  -- (the game clock: a warp works the bench as fast as it runs everything)
  local t = now()
  local d = last_t and (t - last_t) or 0
  last_t = t
  if d <= 0 or d > 5 then return end
  acc = acc + d
  if acc < 0.25 then return end
  local a = acc
  acc = 0
  step(a)
end
