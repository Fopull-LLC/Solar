-- LOOT — what every piece holds, how it is locked, and what it strips into.
--
-- (The interaction plan, work/interact/PLAN.md §5.1, slice S5; Ty 2026-11-10:
-- "a lot of depth with how you can interact with every individual part in a
-- world that needs to extend to looting, exploration, your own bases,
-- scenarios". Binding: a full sandbox that never blocks a dangerous choice;
-- refused only for a physical reason, and the consequence said first.)
--
-- On the ContextLib node beside part_info and the terminal. Four things:
--
--   CONTAINERS  every kit piece whose record has `container = { kg, L }`
--               (parts_kit: Cargo Crate, Small Crate, Shelving, Workbench
--               drawers, a Bunk's footlocker, Store Cabinet, Personnel
--               Locker) is an inventory container `piece:<sid>:<uid>`
--               (inventory.lua's `piece` kind asks capsOf here). Open one
--               with E (scripts/loot_panel.lua: a two-pane transfer to and
--               from the pack) or "Open" on its menu. Storage is real: what
--               goes into a locker on your base is there next week. A piece
--               taken down (Deconstruct, a laser, a strip) spills what it
--               held into a salvage crate where it stood.
--   RUIN LOOT   a ruin's containers are filled ONCE, all at once, the first
--               time any of them is opened (planSite: by the site's kind and
--               age, from its seed): rations, rusted tools, crated spare
--               parts, cells and flares (W4's items, by id: rolled now, they
--               land when the items exist), oxygen tanks, medkits, ore
--               samples of the world, and DATA LOGS (items `datalog:<key>`,
--               read in the pack or at a terminal): a shift note with the
--               door codes, a diary, a survey note with another site's
--               position (reading it finds that site). Saved in the
--               inventory and ruins.s[id].lp; never rolled again.
--   LOCKS       part state `kp` (the code), `kpo` (opened with it), `kpb`
--               (forced: broken). A locked door is also bolted (kit_live's
--               `dh = "lock"`: a console that reaches it may still release
--               it, the wired way in). Enter the code at its keypad (E, or
--               "Enter the code…"), three wrong codes lock the keypad out
--               for 30 s; set your own code on your own lockers and doors;
--               or FORCE it: a Repair Kit's cutter (40 s), the Terrain Laser
--               (25 s) or the Gravity Gun as a pry bar (60 s), an Engineer
--               in 60 % of the time. It is loud (heard 60 m off: lastNoise)
--               and it breaks things: a door's seal, a container's lock.
--               Ruin doors and cabinets lock by site kind (ruins.lockPlan);
--               their codes are in the site's data logs and on its
--               terminal's DATA page.
--   STRIP       "Strip for parts" on any kit piece and machine: an Engineer
--               with a Repair Kit or the Terrain Laser in the pack, 5–45 s by
--               mass. A sound fitting comes off crated (part:<id>); the rest
--               is its materials less a loss (40 % sound, 55 % rusted, 60 %
--               knocked; concrete comes back as regocrete rubble). What the
--               pack cannot take lands in a salvage crate beside it. The
--               piece goes through structures.removeParts (rooms and air
--               re-solve: stripping a wall of a pressurised room VENTS it,
--               allowed, warned first), and what stood only on it comes down
--               too (warned: "3 pieces stand on it").
--
-- The rules are pure (the globals under PURE: tests/smoke_loot.lua); the
-- scene half answers the menus (only while one is open) and watches the
-- structures' version for containers taken down. Nothing runs a frame.

defaults = {}

-- ── PURE ────────────────────────────────────────────────────────────────────
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
function hash(s)
  s = tostring(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end
function rng(seed)
  local s = math.floor(seed or 1) % 2147483646 + 1
  local function nx() s = (s * 16807) % 2147483647; return s / 2147483647 end
  nx(); nx()
  return nx
end

function cidOf(sid, uid) return "piece:" .. tostring(sid) .. ":" .. tostring(uid) end
function parseCid(cid)
  if type(cid) ~= "string" then return nil end
  local s, u = cid:match("^piece:([^:]+):(%d+)$")
  if not s then return nil end
  return tonumber(s) or s, tonumber(u)
end
function pieceName(id) return type(id) == "string" and id:match("^([%w]+)") or nil end

-- What each kind of container tends to hold: { id, chance, nmin, nmax, fresh }
-- (`fresh`: a thing that ages out: its chance falls with the site's age).
-- Special ids: "ore" (a sample of the world's rock), "spare" (a crated spare
-- part of the site's kind), "datalog" (a slot a site's log may land in).
POOLS = {
  crate     = { { "ration", 0.55, 1, 4 }, { "repairkit", 0.35, 1, 1, true }, { "o2tank", 0.25, 1, 1, true }, { "cell", 0.30, 1, 2, true },
                { "flare", 0.35, 2, 4, true }, { "rustytools", 0.30, 1, 1 }, { "ore", 1.0 }, { "spare", 0.35 }, { "datalog", 0.15 } },
  crateS    = { { "ration", 0.40, 1, 2 }, { "medkit", 0.25, 1, 1, true }, { "cell", 0.25, 1, 1, true }, { "flare", 0.30, 1, 3, true },
                { "ore", 0.6 }, { "datalog", 0.2 } },
  shelf     = { { "ration", 0.60, 2, 6 }, { "spare", 0.6 }, { "cell", 0.35, 1, 3, true }, { "repairkit", 0.30, 1, 1, true },
                { "flare", 0.30, 2, 5, true }, { "ore", 0.4 }, { "datalog", 0.25 } },
  workbench = { { "rustytools", 0.70, 1, 2 }, { "repairkit", 0.45, 1, 1, true }, { "spare", 0.7 }, { "cell", 0.30, 1, 1, true },
                { "datalog", 0.35 } },
  bunk      = { { "ration", 0.45, 1, 2 }, { "medkit", 0.25, 1, 1, true }, { "flashlight", 0.20, 1, 1, true }, { "datalog", 0.6 } },
  cabinet   = { { "o2tank", 0.40, 1, 2, true }, { "medkit", 0.40, 1, 2, true }, { "repairkit", 0.30, 1, 1, true }, { "cell", 0.40, 1, 3, true },
                { "spare", 0.4 }, { "datalog", 0.4 } },
  locker    = { { "o2tank", 0.35, 1, 1, true }, { "o2mask", 0.25, 1, 1, true }, { "flashlight", 0.30, 1, 1, true }, { "medkit", 0.25, 1, 1, true },
                { "ration", 0.30, 1, 2 }, { "datalog", 0.5 } },
}
-- the crated spares a site's kind keeps (kit pieces: a part item each)
SPARES = {
  camp    = { "lightFitting.steel", "switchPlate.steel", "lsTemp.steel", "flValve.steel" },
  hab     = { "lightFitting.steel", "flReg.steel", "flValve.steel", "eqValve.steel", "lsPress.steel" },
  mine    = { "lightFitting.steel", "breaker63.steel", "lsLevel.steel", "flValve.steel" },
  reactor = { "flValve.steel", "flGauge.steel", "breaker63.steel", "lsDose.steel", "lsTemp.steel" },
  relay   = { "breaker63.steel", "lwRx.steel", "lwTx.steel", "lsPower.steel" },
}
-- (R1) what the ruin near home's outside crate always holds: a crated craft
-- Solar Panel and a Repair Kit (the knocked array wants one once claimed)
NEAR_CRATE = { "part:vab.solar", "repairkit" }
-- where a log is most likely kept (a diary under a bunk, a note in a drawer)
LOG_AFFINITY = { bunk = 6, locker = 5, workbench = 4, cabinet = 3, shelf = 2, crateS = 1, crate = 1 }

-- How old a site reads: 0 (400 days) … 1 (6,000 days).
function ageK(age) return clamp(((age or 400) - 400) / 5600, 0, 1) end

-- One container's roll: → items { id = n }, mats { mat = n }, logs (slots),
-- fills { id = { level share … } } (a found tank or cell is part spent).
-- `known(id)` says whether the item registry has it: W4's cells and flares
-- are rolled now and kept by id (`pend`) until the item exists.
function manifest(seed, key, piece, kind, age, ores, known)
  local r = rng(hash(tostring(seed) .. ":loot:" .. tostring(key) .. ":" .. tostring(piece)))
  local pool = POOLS[piece] or POOLS.crate
  local k = ageK(age)
  local items, mats, fills, pend = {}, {}, {}, {}
  local logs = 0
  for _, e in ipairs(pool) do
    local id, ch, n0, n1, fresh = e[1], e[2], e[3] or 1, e[4] or 1, e[5]
    if fresh then ch = ch * (1 - 0.65 * k) end
    if id == "rustytools" then ch = math.min(0.95, ch * (1 + k)) end
    local roll = r()
    local n = n0 + math.floor(r() * (n1 - n0 + 1))
    local lvl = r()
    if roll < ch then
      if id == "ore" then
        local o = ores and ores[1 + math.floor(r() * math.max(1, #ores))]
        if o then mats[o] = (mats[o] or 0) + 2 + math.floor(r() * 7) end
      elseif id == "spare" then
        local list = SPARES[kind] or SPARES.camp
        local pid = list[1 + math.floor(r() * #list)]
        local iid = "part:" .. pid
        items[iid] = (items[iid] or 0) + 1
      elseif id == "datalog" then
        logs = logs + 1
      else
        local bag = (known == nil or known(id)) and items or pend
        bag[id] = (bag[id] or 0) + n
        if fresh then
          fills[id] = fills[id] or {}
          for _ = 1, n do fills[id][#fills[id] + 1] = clamp(0.1 + 0.8 * (1 - k) * lvl, 0.05, 1) end
        end
      end
    end
  end
  return items, mats, logs, fills, pend
end

-- The words a log is written in (the site's people, the site's trouble).
LOG_WHO = { "M. Okafor", "J. Halden", "R. Varro", "T. Ashdown", "K. Brannock", "S. Ilse", "D. Morrow", "A. Tessaly", "P. Kestrel", "L. Pell" }
LOG_DIARY = {
  "Third week without the resupply. We ration the coffee now.",
  "The wind took the north array again. Nobody wants to go out for it.",
  "Can't sleep with the hab ticking as it cools. Counted the bolts on the ceiling: 112.",
  "Mara says the company will send a lander for the silo. Mara believes a lot of things.",
  "Found someone's initials scratched under the bunk. Dated four years before we landed.",
  "If the scrubber goes again I am walking to the relay and not coming back.",
  "Two of us now. The rest went home on the last lander.",
  "The doctor's dose card says I'm fine. The doctor's dose card always says I'm fine.",
}
LOG_SHIFT = {
  "Shift handover. Doors on the code from now on, after last week's business with the ration store.",
  "Night shift note: the bolt on %s is back on its keypad. Code below. Don't write it on the wall again.",
  "Security memo from head office: every external door on a keypad. Codes changed today.",
  "Somebody keeps leaving %s open. It's locked now. Ask me for the code, or read this.",
}
LOG_SURVEY = {
  "The old survey stakes run east. There was a crew here before us: their camp is at %s.",
  "Picked up a carrier wave from another site at %s. No answer on voice.",
  "Varro's geologist says the better ground is at %s. Varro's geologist says a lot of things.",
}
-- A site's logs (pure): info = { kind, age, co (company index), locks =
-- { { uid, label, code } … }, others = { { id, name, where } … } } → list of
-- { key, title, who, when, lines = { … }, codes = { { uid, code, label } },
-- coords = site id }. key = "r:<site id>:<n>".
function siteLogs(site, info)
  info = info or {}
  local r = rng(hash(tostring(site and site.seed or 1) .. ":logs"))
  local out = {}
  local id = tostring(site and site.id or "?")
  local function who() return LOG_WHO[1 + math.floor(r() * #LOG_WHO)] end
  local function day() return string.format("day %d before", math.floor((site and site.age or 400) + r() * 60)) end
  local locks = info.locks or {}
  -- the shift note: every door code (and the store's), so a site is never sealed for good
  if #locks > 0 then
    local first = locks[1]
    local fmt = LOG_SHIFT[1 + math.floor(r() * #LOG_SHIFT)]
    local lines = { (fmt:gsub("%%s", tostring(first.label or "the door"))) }
    local codes = {}
    for _, l in ipairs(locks) do
      lines[#lines + 1] = string.format("%s: %s", tostring(l.label or "door"), tostring(l.code))
      codes[#codes + 1] = { uid = l.uid, code = l.code, label = l.label }
    end
    out[#out + 1] = { key = string.format("r:%s:%d", id, #out + 1), title = "Shift note", who = who(), when = day(), lines = lines, codes = codes }
  end
  -- a diary or two
  local nd = 1 + math.floor(r() * 2)
  for _ = 1, nd do
    local a = LOG_DIARY[1 + math.floor(r() * #LOG_DIARY)]
    local b = LOG_DIARY[1 + math.floor(r() * #LOG_DIARY)]
    out[#out + 1] = { key = string.format("r:%s:%d", id, #out + 1), title = "Personal log", who = who(), when = day(), lines = { a, b ~= a and b or nil } }
  end
  -- a survey note with another site's position
  local others = info.others or {}
  -- (R1: the ruin near home always leaves its survey note, on the site its log names)
  if site and site.near and site.other then
    for _, o in ipairs(others) do if o.id == site.other then others = { o } break end end
  end
  if #others > 0 and ((site and site.near) or r() < 0.85) then
    local o = others[1 + math.floor(r() * #others)]
    local fmt = LOG_SURVEY[1 + math.floor(r() * #LOG_SURVEY)]
    out[#out + 1] = { key = string.format("r:%s:%d", id, #out + 1), title = "Survey note", who = who(), when = day(),
                      lines = { (fmt:gsub("%%s", tostring(o.where or "?"))) }, coords = o.id }
  end
  return out
end

-- The whole site's loot, at once (pure): containers = { { uid, piece, key,
-- locked } … } (key: the piece's index in the full build when known, so a
-- restamped ruin rolls the same), logs = siteLogs(...) → plan { [uid] =
-- { items, mats, fills, pend } } — every log placed: one carrying codes in a
-- container that is NOT locked (a bunk's footlocker first), the rest by
-- each container's own slots, then by affinity.
function planSite(site, containers, ores, logs, known)
  local plan, slots = {}, {}
  for _, c in ipairs(containers or {}) do
    local items, mats, nlogs, fills, pend = manifest(site and site.seed or 1, c.key or c.uid, c.piece, site and site.kind, site and site.age, ores, known)
    plan[c.uid] = { items = items, mats = mats, fills = fills, pend = pend }
    slots[#slots + 1] = { c = c, n = nlogs, aff = LOG_AFFINITY[c.piece] or 0 }
  end
  table.sort(slots, function(a, b)
    if a.aff ~= b.aff then return a.aff > b.aff end
    return (a.c.uid or 0) < (b.c.uid or 0)
  end)
  local function put(c, lg) local it = plan[c.uid].items; local id = "datalog:" .. lg.key; it[id] = (it[id] or 0) + 1 end
  -- (R1: the ruin near home: its outside crate holds the shift note, a crated
  -- Solar Panel and a Repair Kit, whatever the dice rolled)
  local nearCrate = nil
  if site and site.near then
    for _, c in ipairs(containers or {}) do
      if not c.locked and c.piece == "crate" then nearCrate = c break end
    end
    if not nearCrate then for _, c in ipairs(containers or {}) do if not c.locked and c.piece == "crateS" then nearCrate = c break end end end
    if nearCrate then
      local it = plan[nearCrate.uid].items
      for _, id in ipairs(NEAR_CRATE) do it[id] = math.max(it[id] or 0, 1) end
    end
  end
  for _, lg in ipairs(logs or {}) do
    local best = nil
    if nearCrate and (lg.codes or lg.coords) then best = { c = nearCrate, n = 1 } end
    -- a log with codes never goes into a container one of its codes opens (nor any locked one)
    if not best then
      for _, s in ipairs(slots) do
        local ok = not (lg.codes and s.c.locked)
        if ok and s.n > 0 then best = s; break end
      end
    end
    if not best then for _, s in ipairs(slots) do if not (lg.codes and s.c.locked) then best = s; break end end end
    if best then best.n = math.max(0, best.n - 1); put(best.c, lg) end
  end
  return plan
end

-- A lock's state from its part state: "none" | "locked" | "open" | "broken".
-- A door's code lock is its bolt too: a bolt released by a console reads open.
function lockState(st, isDoor)
  if type(st) ~= "table" then return "none" end
  if st.kpb then return "broken" end
  if not st.kp then return "none" end
  if st.kpo then return "open" end
  if isDoor and st.dh ~= "lock" then return "open" end
  return "locked"
end
-- A code a keypad takes: 3 to 8 digits.
function validCode(s)
  s = tostring(s or ""):gsub("%s", "")
  if s:match("^%d%d%d+$") and #s <= 8 then return s end
  return nil
end
-- Wrong codes: three inside LOCKOUT_WINDOW s and the keypad refuses for LOCKOUT s.
LOCKOUT, LOCKOUT_WINDOW, LOCKOUT_TRIES = 30, 60, 3
function lockedOut(tries, now)
  if type(tries) ~= "table" then return nil end
  if tries.until_ and now < tries.until_ then return tries.until_ - now end
  return nil
end
function noteWrong(tries, now)
  tries = type(tries) == "table" and tries or {}
  if not tries.t0 or now - tries.t0 > LOCKOUT_WINDOW then tries.t0, tries.n = now, 0 end
  tries.n = (tries.n or 0) + 1
  if tries.n >= LOCKOUT_TRIES then tries.until_ = now + LOCKOUT; tries.n, tries.t0 = 0, nil end
  return tries
end

-- The tool a job uses, from what the pack holds (count(id) → n): → id, time
-- factor, the words. A Repair Kit's cutter, the Terrain Laser, the Gravity Gun
-- as a pry bar; nil when there is none.
TOOLS = {
  force = { { "laser", 25, "the Terrain Laser" }, { "repairkit", 40, "a Repair Kit's cutter" }, { "gravgun", 60, "the Gravity Gun as a pry bar" } },
  strip = { { "laser", 0.7, "the Terrain Laser" }, { "repairkit", 1.0, "a Repair Kit" } },
}
function toolFor(job, count)
  for _, t in ipairs(TOOLS[job] or {}) do
    if (count and count(t[1]) or 0) > 0 then return t[1], t[2], t[3] end
  end
  return nil
end
-- Seconds to force a lock: the tool's, an Engineer's 60 %, a door 1.25×.
function forceSecs(tool, engineer, isDoor)
  local base = 60
  for _, t in ipairs(TOOLS.force) do if t[1] == tool then base = t[2] end end
  return base * (engineer and 0.6 or 1.0) * (isDoor and 1.25 or 1.0)
end

-- What a piece strips into (pure): def (parts_base record), p (its bp entry),
-- kgOf(mat) (materials.kg), crateable (bool: a part item resolves for it),
-- toolK (TOOLS.strip factor). → { item = "part:<id>" | nil, mats = { mat = n },
-- secs, share (what comes back), why (nil, or why it can't be crated) }
STRIP_MAT = { steel = "steel", concrete = "regocrete", regocrete = "regocrete", glass = "glass", graphite = "graphite", wood = "plank" }
CRATE_MAX_KG = 60
local function fittingish(d)
  if not d then return false end
  if d.light or d.screen or d.switch or d.console or d.lg or d.life then return true end
  if d.fl and d.fl.kind ~= "pipe" then return true end
  if d.power and (d.power.kind == "breaker" or d.power.kind == "xfmr" or d.power.kind == "load") then return true end
  if d.section == "PROPS" or d.section == "FITTINGS" then return true end
  return false
end
function stripYield(d, p, kgOf, crateable, toolK)
  d = d or {}
  local t = tonumber(d.mass) or 0.05
  local kg = t * 1000
  local share = 0.6
  if p and p.o_c ~= nil then share = 0.45 end
  if p and p.wr then share = 0.4 end
  local secs = clamp(5 + 25 * t, 5, 45) * (toolK or 1.0)
  local out = { mats = {}, secs = secs, share = share }
  if fittingish(d) and kg <= CRATE_MAX_KG and not (p and p.wr) and crateable and p and p.id then
    out.item = "part:" .. tostring(p.id)
    out.share = 1
    return out
  end
  if d.film then return out end
  local mat = STRIP_MAT[d.mat or "steel"] or "steel"
  local per = (kgOf and kgOf(mat)) or 1
  local n = math.floor(kg * share / math.max(per, 1e-6))
  if n > 0 then out.mats[mat] = n end
  return out
end

-- ── THE SCENE ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function sget(k) return save and save.get and save.get(k) or nil end
local function sset(k, v) if save and save.set then save.set(k, v) end end
local function feat(id, ctx) local F = ref("feats"); if F and F.mark then pcall(F.mark, id, ctx) end end   -- (progression P1)
local function blog(sid, k, txt, who) local BL = ref("base_log"); if BL and BL.add then pcall(BL.add, sid, k, txt, who) end end
local function play(path, sid, uid, vol, dist)
  if not (audio and audio.play) then return end
  local ST = ref("structures")
  local n = ST and ST.nodeOf and ST.nodeOf(sid, uid)
  if n and n.valid ~= false then
    local w = n.worldPos
    pcall(audio.play, path, w.x, w.y, w.z, { maxDistance = dist or 30, track = "SFX", volume = vol or 0.7 })
  else
    pcall(audio.play, path, { track = "SFX", volume = (vol or 0.7) * 0.6 })
  end
end
-- A take of one of sfx's banks at the part (a lock wrenched open is metal
-- tearing, a stripped part a clatter of metal on metal), or `path` without sfx.
local function play_bank(bank, path, sid, uid, vol, dist)
  local fx = ref("sfx")
  if not (fx and fx.playBank) then return play(path, sid, uid, vol, dist) end
  local ST = ref("structures")
  local n = ST and ST.nodeOf and ST.nodeOf(sid, uid)
  local w = n and n.valid ~= false and n.worldPos
  if w then pcall(fx.playBank, bank, nil, w.x, w.y, w.z, { vol = vol, event = bank })
  else pcall(fx.playBank, bank, nil, nil, nil, nil, { vol = (vol or 0.7) * 0.6, event = bank }) end
end
version = 0
local function bump() version = version + 1 end
stats = { fills = 0, strips = 0, forced = 0, spills = 0, last_fill_ms = 0 }
lastNoise = nil           -- { sid, uid, what, t, loud } (a life system will listen; probes read it)
lastStrip = nil           -- { sid, uids, item, mats, dropped, vented }

local function piece(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not (rec and p) then return nil end
  return rec, p, defs(p.id) or {}
end
local function label_of(sid, uid)
  local PI = ref("part_info")
  if PI and PI.designate then local ok, n = pcall(PI.designate, sid, uid); if ok and n then return n end end
  local _, p, d = piece(sid, uid)
  return (d and d.label) or (p and p.id) or "piece"
end
local function called(sid, uid)
  local PI = ref("part_info")
  if PI and PI.called then local ok, n = pcall(PI.called, sid, uid); if ok and n then return n end end
  return "the " .. label_of(sid, uid)
end
labelOf = label_of

-- ── containers ──────────────────────────────────────────────────────────────
-- The kilograms and litres of container `cid` (inventory's `piece` kind). → kg, L
function capsOf(cid)
  local sid, uid = parseCid(cid)
  if not sid then return nil end
  local _, _, d = piece(sid, uid)
  local c = d and d.container
  if c then return c.kg or 100, c.L or 100 end
  return nil
end
-- Is piece (sid, uid) a container? → its container def, the part | nil
function containerAt(sid, uid)
  local _, p, d = piece(sid, uid)
  if d and d.container then return d.container, p end
  return nil
end
function isDoor(sid, uid) local _, _, d = piece(sid, uid); return d ~= nil and d.door ~= nil end
local function inv() return ref("inventory") end
function isEmpty(cid)
  local I = inv()
  if not I then return true end
  return I.isEmpty(cid) and #(I.itemList(cid) or {}) == 0
end
-- One line: "3 things · 12.4 kg of 400" / "empty" / "not searched yet".
function summary(sid, uid)
  local cid = cidOf(sid, uid)
  local I = inv()
  if not I then return "" end
  if not filled(sid, uid) then return "not searched yet" end
  local n = 0
  for _, g in ipairs(I.itemList(cid) or {}) do n = n + g.n end
  for _, it in ipairs(I.items(cid) or {}) do n = n + 1; local _ = it end
  if n == 0 then return "empty" end
  return string.format("%d thing%s · %.1f of %.0f kg", n, n == 1 and "" or "s", I.mass(cid), I.cap(cid))
end

-- (containers that ever held something: where they stood, body-relative, so
-- a piece taken down by any hand spills what it held: `loot.cids`)
local function cids() local t = sget("loot.cids"); return type(t) == "table" and t or {} end
function remember(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not (rec and p and ST.partPose) then return end
  local x, y, z = ST.partPose(rec, p, 0.5)
  local t = cids()
  local k = cidOf(sid, uid)
  local e = t[k]
  if not (e and e.b == rec.b and math.abs((e.x or 0) - x) < 0.05 and math.abs((e.y or 0) - y) < 0.05) then
    t[k] = { b = rec.b, x = x, y = y, z = z }
    sset("loot.cids", t)
  end
end

-- ── a ruin's loot: rolled once for the whole site ──────────────────────────
local function ruin_ores(body)
  local M = ref("materials")
  local ok, o = pcall(function() return M and M.bodyOres and M.bodyOres(body) end)
  local list = {}
  if ok and type(o) == "table" then
    for _, v in ipairs(o) do if type(v) == "table" and type(v.mat) == "string" then list[#list + 1] = v end end
  end
  table.sort(list, function(a, b) if (a.w or 0) ~= (b.w or 0) then return (a.w or 0) > (b.w or 0) end return a.mat < b.mat end)
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = v.mat end
  return out
end
local function item_known(id)
  local I = ref("items")
  if not I then return true end
  return I.known and I.known(id) or false
end
-- the log records (ruins' rolled ones and a scenario's): `loot.logs`
local function logs_all() local t = sget("loot.logs"); return type(t) == "table" and t or {} end
function logRecord(key) return logs_all()[key] end
function registerLogs(list)
  local t = logs_all()
  local n = 0
  for _, lg in ipairs(list or {}) do
    if type(lg) == "table" and lg.key then
      local e = {}
      for k, v in pairs(lg) do if k ~= "key" then e[k] = v end end
      t[lg.key] = e
      n = n + 1
    end
  end
  if n > 0 then sset("loot.logs", t) end
  local I = ref("items")
  if I and I.forgetLogs then pcall(I.forgetLogs) end
  return n
end

-- Has piece (sid, uid) been searched (a ruin's site planned)? Any other
-- structure's container is simply what was put in it.
function filled(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  if not (rec and rec.ru) then return true end
  local RU = ref("ruins")
  local e = RU and RU.peekState and RU.peekState(rec.ru)
  return e ~= nil and e.lp ~= nil
end

local function where_of(RU, s)
  if not (RU and RU.pointOf and RU.latlon) then return "?" end
  local ok, x, y, z = pcall(RU.pointOf, s)
  if not ok then return "?" end
  return RU.latlon(x, y, z)
end
-- Roll every container of the ruin structure `sid` once. → n containers filled
function fillSite(sid)
  local ST, RU, I = ref("structures"), ref("ruins"), inv()
  local rec = ST and ST.get and ST.get(sid)
  if not (rec and rec.ru and RU and I) then return 0 end
  local s = RU.site and RU.site(rec.ru)
  local e = RU.state and RU.state(rec.ru)
  if not (s and e) or e.lp then return 0 end
  local w0 = app and app.wallClock and app.wallClock() or nil
  local list, locks = {}, {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    local st = ST.partState and ST.partState(sid, p.uid)
    if d and d.container then
      list[#list + 1] = { uid = p.uid, piece = pieceName(p.id), key = p.ri or p.uid, locked = lockState(st, false) == "locked" }
    end
    if st and st.kp and not st.kpo then
      locks[#locks + 1] = { uid = p.uid, code = st.kp, label = (d and d.label or "door") .. ((p.ri and p.ri > 0) and (" #" .. p.ri) or "") }
    end
  end
  local others = {}
  for _, o in ipairs(RU.sites and RU.sites(s.body) or {}) do
    if o.id ~= s.id and not o.pending then others[#others + 1] = { id = o.id, name = o.name, where = where_of(RU, o) } end
  end
  local logs = siteLogs(s, { kind = s.kind, age = s.age, locks = locks, others = others })
  registerLogs(logs)
  local ores = ruin_ores(s.body)
  local plan = planSite(s, list, ores, logs, item_known)
  local n = 0
  for _, c in ipairs(list) do
    local cid = cidOf(sid, c.uid)
    local pl = plan[c.uid]
    -- (an old save's crate searched by the X8 rule: what it left is moved over, nothing new rolled)
    local old = RU.crateId and RU.crateId(s.id, c.key)
    if old and e.lf and e.lf:find("," .. tostring(c.key) .. ",", 1, true) then
      I.moveAllItems(old, cid, { force = true }); I.transferAll(old, cid)
    elseif pl then
      for id, k in pairs(pl.items) do
        local fc = nil
        local Ireg = ref("items")
        local dd = Ireg and Ireg.def and Ireg.def(id)
        if dd and dd.fill and dd.fill.cap and pl.fills[id] then
          fc = {}
          for i, f in ipairs(pl.fills[id]) do fc[i] = f * dd.fill.cap end
        end
        I.addItem(cid, id, k, { force = true, fills = fc })
      end
      for m, k in pairs(pl.mats) do I.add(cid, m, k, s.body) end
      if next(pl.pend) then
        local pd = sget("loot.pend") or {}
        pd[cid] = pl.pend
        sset("loot.pend", pd)
      end
    end
    remember(sid, c.uid)
    n = n + 1
  end
  e.lp, e.tc = agency_now(), 1
  if RU.saveStates then RU.saveStates() end
  stats.fills = stats.fills + 1
  if w0 then stats.last_fill_ms = (app.wallClock() - w0) * 1000 end
  if log then log(string.format("loot: %s's containers rolled (%d, %d logs, %d locks)", tostring(s.name), n, #logs, #locks)) end
  bump()
  return n
end
-- Pending items (rolled before their item existed) that exist now go in.
function settlePending(cid)
  local pd = sget("loot.pend")
  local p = type(pd) == "table" and pd[cid]
  if not p then return 0 end
  local I = inv()
  local n, left = 0, {}
  for id, k in pairs(p) do
    if item_known(id) then n = n + (I.addItem(cid, id, k, { force = true }) or 0) else left[id] = k end
  end
  pd[cid] = next(left) and left or nil
  sset("loot.pend", pd)
  return n
end
-- Make container (sid, uid) ready to open: a ruin's site rolled, its pending items in.
function prepare(sid, uid)
  local FT = ref("feats"); if FT and FT.cacheOpened then pcall(FT.cacheOpened, sid, uid) end   -- (progression P2: cave_cache)
  if not filled(sid, uid) then fillSite(sid) end
  settlePending(cidOf(sid, uid))
  remember(sid, uid)
end

-- ── data logs ───────────────────────────────────────────────────────────────
local function reads() local t = sget("loot.read"); return type(t) == "table" and t or {} end
function isRead(key) return reads()[key] ~= nil end
function logKeyOf(itemId) return type(itemId) == "string" and itemId:match("^datalog:(.+)$") or nil end
-- The code for piece (sid, uid) the crew has read somewhere (a log, a
-- terminal), or nil. `loot.known` = { ["sid:uid"] = code }.
function knownCode(sid, uid)
  local t = sget("loot.known")
  return type(t) == "table" and t[tostring(sid) .. ":" .. tostring(uid)] or nil
end
local function learn(sid, uid, code)
  local t = sget("loot.known")
  t = type(t) == "table" and t or {}
  local k = tostring(sid) .. ":" .. tostring(uid)
  if t[k] == code then return false end
  t[k] = code
  sset("loot.known", t)
  return true
end
-- The structure a log's codes belong to: its site's stamp, or (a scenario's
-- log) its struct named in the record.
local function log_sid(rec)
  if rec.sid then return rec.sid end
  if rec.site then
    local RU = ref("ruins")
    local e = RU and RU.peekState and RU.peekState(rec.site)
    return e and e.sid or nil
  end
  return nil
end
-- Read log `key`: its codes learned, the site it names found, the first read
-- noted. → record, { learned codes }, found site id
lastRead = nil
function readLog(key, who)
  local rec = logRecord(key)
  if not rec then return nil end
  local t = reads()
  local first = t[key] == nil
  if first then t[key] = agency_now(); sset("loot.read", t) end
  local got = {}
  local sid = log_sid(rec)
  if not sid and key:match("^r:") then
    local site_id = key:match("^r:(.+):%d+$")
    local RU = ref("ruins")
    local e = site_id and RU and RU.peekState and RU.peekState(site_id)
    sid = e and e.sid or nil
  end
  for _, c in ipairs(rec.codes or {}) do
    local csid = c.sid or sid
    if csid and c.uid and c.code and learn(csid, c.uid, c.code) then got[#got + 1] = c end
  end
  local found = nil
  if rec.coords then
    local RU = ref("ruins")
    if RU and RU.discover and RU.discover(rec.coords, "log") then found = rec.coords end
  end
  if first then
    local rp = tonumber(rec.rp) or 5
    if rp > 0 and save and save.get and save.set then save.set("res.pts", (save.get("res.pts") or 0) + rp) end
  end
  lastRead = { key = key, t = now(), first = first, codes = #got, found = found }
  bump()
  return rec, got, found
end
-- The text of a log as lines (title, who and when, the body).
function logLines(key)
  local rec = logRecord(key)
  if not rec then return { "the card is blank" } end
  local out = { string.format("%s · %s · %s", tostring(rec.title or "Log"), tostring(rec.who or "?"), tostring(rec.when or "")) }
  for _, l in ipairs(rec.lines or {}) do out[#out + 1] = tostring(l) end
  if rec.text then out[#out + 1] = tostring(rec.text) end
  return out
end

-- ── locks ───────────────────────────────────────────────────────────────────
local function part_state(sid, uid) local ST = ref("structures"); return ST and ST.partState and ST.partState(sid, uid) or nil end
local function patch_state(sid, uid, fields)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return false end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  for k, v in pairs(fields) do if v == false then t[k] = nil else t[k] = v end end
  return ST.setPartState(sid, uid, next(t) and t or nil)
end
function lockOf(sid, uid) return lockState(part_state(sid, uid), isDoor(sid, uid)) end
function isLocked(sid, uid) return lockOf(sid, uid) == "locked" end
local tries = {}          -- "sid:uid" → { n, t0, until_ } (a session's: a keypad's memory)
function lockoutLeft(sid, uid) return lockedOut(tries[tostring(sid) .. ":" .. tostring(uid)], now()) end
local function bolt(sid, uid, on)
  local KL = ref("kit_live")
  if KL and KL.setDoorHold and isDoor(sid, uid) then pcall(KL.setDoorHold, sid, uid, on and "lock" or nil) end
end
-- Key a code into the keypad of (sid, uid). → ok, why
function enterCode(sid, uid, code, who)
  local st = part_state(sid, uid)
  local state = lockState(st, isDoor(sid, uid))
  if state == "none" then return false, "it has no lock" end
  if state == "broken" then return true, "its lock is broken: it opens" end
  local k = tostring(sid) .. ":" .. tostring(uid)
  local left = lockedOut(tries[k], now())
  if left then return false, string.format("the keypad is locked out: %d s", math.ceil(left)) end
  code = validCode(code)
  if code and code == st.kp then
    tries[k] = nil
    patch_state(sid, uid, { kpo = true })
    bolt(sid, uid, false)
    if who ~= false then learn(sid, uid, code) end
    if who ~= false then feat("lock_opened", { key = tostring(sid) .. ":" .. tostring(uid) }) end   -- (P1)
    play("audio/foley/latch_clunk.ogg", sid, uid, 0.7, 20)
    blog(sid, "lock", string.format("%s opened with its code", tostring(label_of(sid, uid))), who)
    bump()
    return true, nil
  end
  tries[k] = noteWrong(tries[k], now())
  play("audio/foley/buzz_denied.ogg", sid, uid, 0.5, 15)
  if tries[k].until_ then return false, string.format("wrong code · the keypad locks out for %d s", LOCKOUT) end
  return false, string.format("wrong code (%d of %d)", tries[k].n or 1, LOCKOUT_TRIES)
end
-- Lock (sid, uid) on its code (a new code sets one: your own locker, your
-- own door). → ok, why
function setCode(sid, uid, code, who)
  local st = part_state(sid, uid) or {}
  local _, p, d = piece(sid, uid)
  if not p then return false, "that piece is gone" end
  if not (d.container or d.door) then return false, "it has nowhere to fit a lock" end
  if st.kpb and who ~= false then return false, "its lock was forced: it is broken for good" end
  local c = validCode(code) or st.kp
  if not c then return false, "a code is 3 to 8 digits" end
  -- (who == false: a scenario's or a ruin's staging: it may re-key a lock, and teaches the crew nothing)
  if who ~= false and lockState(st, d.door ~= nil) == "locked" and code and validCode(code) ~= st.kp then return false, "it is locked: open it with its code first" end
  if who == false and st.kpb then patch_state(sid, uid, { kpb = false }) end
  patch_state(sid, uid, { kp = c, kpo = false })
  bolt(sid, uid, true)
  if who ~= false then learn(sid, uid, c) end
  play("audio/foley/latch_clunk.ogg", sid, uid, 0.6, 15)
  blog(sid, "lock", string.format("%s locked on a code", tostring(label_of(sid, uid))), who)
  bump()
  local warn = nil
  if d.door then warn = "locked: nobody walks through it without the code (or a console that reaches its bolt)" end
  return true, warn
end
-- Lock it again on the code it has.
function relock(sid, uid, who) return setCode(sid, uid, nil, who) end
-- Take the lock off (it must be open). → ok, why
function clearCode(sid, uid, who)
  local st = part_state(sid, uid)
  local state = lockState(st, isDoor(sid, uid))
  if state == "none" then return false, "it has no lock" end
  if state == "locked" then return false, "it is locked: open it with its code first" end
  patch_state(sid, uid, { kp = false, kpo = false, kpb = false })
  bolt(sid, uid, false)
  blog(sid, "lock", string.format("%s: its lock taken off", tostring(label_of(sid, uid))), who)
  bump()
  return true
end
-- What forcing (sid, uid) will do, in words (never a refusal).
function forceWarn(sid, uid)
  if isDoor(sid, uid) then
    local RA = ref("room_air")
    local s = RA and RA.state and RA.state(sid)
    local dp = s and RA.door_dp and RA.door_dp(s, uid)
    local w = "loud (heard 60 m off) · the door's seal is wrecked: the rooms it closes leak"
    if dp and dp > 0.05 then w = w .. string.format(" · %.2f atm across it: it VENTS when it gives", dp) end
    return w
  end
  return "loud (heard 60 m off) · the lock is broken for good and the piece knocked"
end
-- Force (sid, uid) open now (the job is done). → ok, why
function forceLock(sid, uid, who, tool)
  local st = part_state(sid, uid)
  local door = isDoor(sid, uid)
  local state = lockState(st, door)
  if state == "none" or state == "broken" then return false, "it isn't locked" end
  patch_state(sid, uid, { kpb = true, kpo = false, kp = false })
  bolt(sid, uid, false)
  local rec, p = piece(sid, uid)
  if door then
    local RA = ref("room_air")
    local seal = RA and RA.sealOf and RA.sealOf(sid, uid) or 0
    patch_state(sid, uid, { seal = math.min(1, seal + 0.6) })
    if RA and RA.forceDoor then pcall(RA.forceDoor, sid, uid) end
  elseif p and not p.wr then
    p.wr = true
    p.wrl = "its lock was forced"
    local ST = ref("structures")
    if ST and ST.put then ST.put(rec) end
  end
  play_bank("part_break", "audio/foley/steel_drop.ogg", sid, uid, 1.0, 60)
  if who ~= false then feat("lock_opened", { key = tostring(sid) .. ":" .. tostring(uid) }) end   -- (P1: forced counts too)
  lastNoise = { sid = sid, uid = uid, what = "forced", t = now(), loud = 60 }
  stats.forced = stats.forced + 1
  blog(sid, "forced", string.format("%s: its lock FORCED%s", tostring(label_of(sid, uid)), tool and (" with " .. tostring(tool)) or ""), who)
  bump()
  return true, door and "the lock gives: the door is free (its seal is wrecked)" or "the lock gives"
end

-- ── stripping ───────────────────────────────────────────────────────────────
local function crateable(pid, d)
  local R = ref("recipes")
  if not (R and R.partItemDef) then return false end
  local ok, it = pcall(R.partItemDef, pid, d)
  return ok and it ~= nil
end
-- the sealed, pressurised rooms piece (sid, uid) closes: → { { id, p } … }
function ventsOf(sid, uid)
  local rec, p, d = piece(sid, uid)
  local RA, RM = ref("room_air"), ref("rooms")
  if not (rec and RA and RM and RA.roomsOf and RM.roomAt and RA.airOf) then return {} end
  if RM.localQuads then
    local okq, q = pcall(RM.localQuads, d)
    if okq and type(q) == "table" and #q == 0 then return {} end
  end
  local R = RA.roomsOf(sid)
  if not R then return {} end
  local b = d.box or { -0.5, 0.5, 0, 1, -0.5, 0.5 }
  local cy = (p.y or 0) + (b[3] + b[4]) / 2
  local yaw = p.yaw or 0
  local nx, nz = math.sin(yaw), math.cos(yaw)
  local tx, tz = math.cos(yaw), -math.sin(yaw)
  local hy = (b[4] - b[3]) / 2 + 0.3
  local pts = { { nx * 0.45, 0, nz * 0.45 }, { -nx * 0.45, 0, -nz * 0.45 }, { 0, hy, 0 }, { 0, -hy, 0 },
                { tx * 0.6, 0, tz * 0.6 }, { -tx * 0.6, 0, -tz * 0.6 } }
  local seen, out = {}, {}
  for _, o in ipairs(pts) do
    local ok, r = pcall(RM.roomAt, R, (p.x or 0) + o[1], cy + o[2], (p.z or 0) + o[3])
    if ok and r and not seen[r.id] then
      seen[r.id] = true
      local a = RA.airOf(sid, r.id)
      if a and a.sealed and (a.p or 0) > 0.05 then out[#out + 1] = { id = r.id, p = a.p } end
    end
  end
  return out
end
local function role_of(ctx)
  local C = ref("crew")
  if not (C and C.role) then return nil end
  local id = ctx and ctx.actor and ctx.actor.id
  if (not id or id == "astro") and C.activeId then id = C.activeId() end
  local ok, r = pcall(C.role, id)
  return ok and r or nil
end
roleOf = role_of
local function pack_of(ctx) return (ctx and ctx.actor and ctx.actor.pack) or "astro" end
local function counter(ctx) local I = inv(); return function(id) return I and I.itemCount(pack_of(ctx), id) or 0 end end
-- What comes down with (sid, uid) and which rooms it vents: the structural
-- half of a strip quote, kept while the structures are unchanged (the falls)
-- and for a second (the rooms' air). A piece's menu reads the quote in five
-- rows at every refresh; the support graph walk under it once took 50-250 ms
-- (Ty 11-11: a base part's menu brought the game to 1 fps).
local SQ = {}
local function strip_reach(sid, uid, rec)
  local ST = ref("structures")
  local ver = ST and ST.version
  local key = tostring(sid) .. ":" .. tostring(uid)
  local c = SQ[key]
  if not (c and c.rec == rec and c.ver == ver and c.n == #(rec.bp or {})) then
    local uids = { uid }
    local SN, KS = ref("base_snap"), ref("kit_snap")
    if SN and SN.dependents then
      local ok, list = pcall(SN.dependents, rec, defs, uid)
      if ok then for _, u in ipairs(list or {}) do uids[#uids + 1] = u end end
    end
    if KS and KS.fallsWith then
      local ok, list = pcall(KS.fallsWith, rec, defs, uids)
      if ok then for _, u in ipairs(list or {}) do uids[#uids + 1] = u end end
    end
    if next(SQ) and not SQ[key] then
      local n = 0
      for _ in pairs(SQ) do n = n + 1 end
      if n > 32 then SQ = {} end
    end
    c = { rec = rec, ver = ver, n = #(rec.bp or {}), uids = uids, vt = -1e9 }
    SQ[key] = c
  end
  if now() - c.vt >= 1.0 or c.vents == nil then c.vents, c.vt = ventsOf(sid, uid), now() end
  local uids = {}
  for i, u in ipairs(c.uids) do uids[i] = u end
  return uids, c.vents
end
-- What stripping (sid, uid) would give and cost. → q = { item, mats, secs,
-- share, uids (it and what falls with it), falls, vents, tool, toolName,
-- why (a physical refusal) }, nil
function stripQuote(sid, uid, ctx)
  local rec, p, d = piece(sid, uid)
  if not rec then return nil end
  local M = ref("materials")
  local tool, tk, tname = toolFor("strip", counter(ctx))
  local q = stripYield(d, p, M and M.kg, crateable(p.id, d), tk)
  q.tool, q.toolName = tool, tname
  local uids, vents = strip_reach(sid, uid, rec)
  q.uids, q.falls = uids, #uids - 1
  q.vents = vents
  if role_of(ctx) ~= "engineer" then q.why = "an Engineer strips a piece for parts (the fixings, the bolts, what is worth keeping)"
  elseif not tool then q.why = "needs a Repair Kit or the Terrain Laser in the pack" end
  if d.film then q.why = "it is paint: there is nothing to strip" end
  return q
end
-- The consequences, in words (nil: none worth saying).
function stripWarn(q)
  if not q then return nil end
  local bits = {}
  for _, v in ipairs(q.vents or {}) do bits[#bits + 1] = string.format("Room %s (%.2f atm) VENTS", tostring(v.id), v.p or 0) end
  if (q.falls or 0) > 0 then bits[#bits + 1] = string.format("%d piece%s on it come%s down too", q.falls, q.falls == 1 and "" or "s", q.falls == 1 and "s" or "") end
  if #bits == 0 then return nil end
  return table.concat(bits, " · ")
end
function yieldText(q)
  if not q then return "" end
  if q.item then
    local I = ref("items")
    return (I and I.nameOf and I.nameOf(q.item)) or q.item
  end
  local M = ref("materials")
  local bits = {}
  for m, n in pairs(q.mats or {}) do bits[#bits + 1] = string.format("%d %s", n, (M and M.label and M.label(m)) or m) end
  table.sort(bits)
  if #bits == 0 then return "nothing worth keeping" end
  return table.concat(bits, ", ") .. string.format(" (%d %% back)", math.floor((q.share or 0) * 100 + 0.5))
end
local drop_seq = 0
-- Put a bag of things in the pack, the rest into a salvage crate at the
-- body-relative point (b, x, y, z). → kg into the pack, salvage id | nil
local function deliver(pack, items, mats, b, x, y, z, from_cid, label)
  local I, SV = inv(), ref("salvage")
  if not I then return 0, nil end
  drop_seq = drop_seq + 1
  local tmp = "lootdrop:" .. tostring(math.floor(now() * 1000)) .. "." .. drop_seq
  I.setCap(tmp, 1e6)
  local m0 = I.mass(pack)
  for id, n in pairs(items or {}) do
    local got = I.addItem(pack, id, n) or 0
    if got < n then I.addItem(tmp, id, n - got, { force = true }) end
  end
  for m, n in pairs(mats or {}) do
    local got = I.add(pack, m, n) or 0
    if got < n then I.add(tmp, m, n - got) end
  end
  if from_cid then
    I.moveAllItems(from_cid, tmp, { force = true })
    I.transferAll(from_cid, tmp)
  end
  local into = I.mass(pack) - m0
  local sid = nil
  if (not I.isEmpty(tmp) or #(I.itemList(tmp) or {}) > 0) and SV and SV.drop and b and space and space.body then
    local bb = space.body(b)
    if bb then sid = SV.drop(b, bb.x + x, bb.y + y, bb.z + z, nil, { from = tmp, items = true, label = label or "Stripped parts" }) end
  end
  I.setCap(tmp, 0)
  return into, sid
end
-- Strip (sid, uid) now (the job is done). → ok, why | warn
function strip(sid, uid, ctx)
  local q = stripQuote(sid, uid, ctx)
  if not q then return false, "that piece is gone" end
  if q.why then return false, q.why end
  local rec, p, d = piece(sid, uid)
  local ST = ref("structures")
  local x, y, z = ST.partPose(rec, p, 0.6)
  local cid = d.container and cidOf(sid, uid) or nil
  local warn = stripWarn(q)
  -- what falls with it comes back at a quarter (it fell)
  local items, mats = {}, {}
  if q.item then items[q.item] = 1 end
  for m, n in pairs(q.mats) do mats[m] = n end
  local M = ref("materials")
  for i = 2, #q.uids do
    local fp = ST.getPart(sid, q.uids[i])
    local fd = fp and defs(fp.id)
    if fd then
      local y2 = stripYield(fd, fp, M and M.kg, false, 1)
      for m, n in pairs(y2.mats) do mats[m] = (mats[m] or 0) + math.floor(n * 0.4) end
    end
  end
  -- (the tool's consumable: a strip with a Repair Kit spends nothing; the cutter is reused)
  local spills = {}
  for i = 2, #q.uids do
    local fp = ST.getPart(sid, q.uids[i])
    local fd = fp and defs(fp.id)
    if fd and fd.container then spills[#spills + 1] = cidOf(sid, q.uids[i]) end
  end
  ST.removeParts(sid, q.uids)
  local into, salv = deliver(pack_of(ctx), items, mats, rec.b, x, y, z, cid, "Stripped parts")
  for _, c in ipairs(spills) do
    local _, s2 = deliver(pack_of(ctx), {}, {}, rec.b, x, y, z, c, "Spilled from a container")
    salv = salv or s2
  end
  local t = cids()
  for _, u in ipairs(q.uids) do t[cidOf(sid, u)] = nil end
  sset("loot.cids", t)
  if #(q.vents or {}) > 0 then play("audio/foley/hiss_cylinder.ogg", sid, uid, 1.0, 40) end
  play_bank("metal_metal", "audio/foley/steel_drop.ogg", sid, uid, 0.8, 35)
  lastNoise = { sid = sid, uid = uid, what = "stripped", t = now(), loud = 35 }
  lastStrip = { sid = sid, uids = q.uids, item = q.item, mats = mats, into = into, salvage = salv, vented = #(q.vents or {}), warn = warn }
  stats.strips = stats.strips + 1
  blog(sid, "strip", string.format("%s stripped for parts%s", tostring(d.label or p.id), (q.falls or 0) > 0 and string.format(" (%d more came down)", q.falls) or ""))
  -- a ruin stripped is a ruin touched: it stays in the records
  if rec.ru then local RU = ref("ruins"); local e = RU and RU.state and RU.state(rec.ru); if e and not e.tc then e.tc = 1; if RU.saveStates then RU.saveStates() end end end
  -- (progression P1) a feat: a ruin's piece stripped (once a piece)
  if rec.ru then feat("ruin_stripped", { key = tostring(rec.ru) .. ":" .. tostring(p.ri or uid), b = rec.b }) end
  bump()
  local msg = string.format("stripped: %s%s", yieldText(q), salv and " · the rest in a salvage crate beside it" or "")
  if warn then msg = msg .. " · " .. warn end
  return true, msg
end

-- ── the menus: a piece's CONTENTS, LOCK and SALVAGE rows ───────────────────
local function near(ctx, t, extra)
  local CP = ref("context_providers")
  if CP and CP.actorReach then return CP.actorReach(ctx, t, extra or 0.6) ~= nil end
  return true
end
local function panel() return ref("loot_panel") end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, FB = ref("structures"), ref("field_builder")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not (rec and part) then return {} end
  local sid, uid = rec.id, part.uid
  local d = defs(part.id) or {}
  local out = {}
  local door = d.door ~= nil
  local function lk() return lockOf(sid, uid) end
  -- CONTENTS
  if d.container then
    local G = "Contents"
    out[#out + 1] = { id = "lo_sum", type = "info", group = G, label = (d.container.what and (d.container.what:gsub("^%l", string.upper))) or "Holds",
      value = function() return summary(sid, uid) end }
    out[#out + 1] = { id = "lo_open", type = "action", group = G, label = function() return lk() == "locked" and "Open it (locked)" or "Open it" end,
      hint = "E",
      enabled = function() return lk() ~= "locked" and near(ctx, t) end,
      why = function() return lk() == "locked" and "it is locked: enter its code, or force it" or "walk up to it" end,
      act = function()
        local LP = panel()
        if not (LP and LP.openContainer) then return false, "no panel" end
        return LP.openContainer(sid, uid)
      end }
  end
  -- LOCK (a container's or a door's)
  if d.container or door then
    local G = "Lock"
    local st0 = part_state(sid, uid)
    local state = lockState(st0, door)
    if state ~= "none" then
      out[#out + 1] = { id = "lo_lock", type = "info", group = G, label = "Keypad",
        value = function()
          local s = lk()
          local kc = knownCode(sid, uid)
          local left = lockoutLeft(sid, uid)
          if s == "broken" then return "forced: the lock is broken" end
          if left then return string.format("LOCKED OUT · %d s", math.ceil(left)) end
          return (s == "locked" and "LOCKED" or "open") .. (kc and (" · you know its code: " .. kc) or "")
        end, warn = function() return lk() == "locked" end }
      out[#out + 1] = { id = "lo_code", type = "action", group = G, label = "Enter the code…", hint = "keypad", keep = true,
        enabled = function() return lk() == "locked" and near(ctx, t) end,
        why = function() return lk() ~= "locked" and "it is open" or "walk up to its keypad" end,
        act = function() local LP = panel(); return LP and LP.openKeypad and LP.openKeypad(sid, uid) or false end }
      out[#out + 1] = { id = "lo_force", type = "action", group = G, label = "Force the lock", danger = true,
        hint = function()
          local tool, _, tname = toolFor("force", counter(ctx))
          return tool and string.format("%s · %.0f s", tname, forceSecs(tool, role_of(ctx) == "engineer", door)) or "a tool"
        end,
        tip = function() return forceWarn(sid, uid) end,
        enabled = function() return lk() == "locked" and toolFor("force", counter(ctx)) ~= nil and near(ctx, t) end,
        why = function()
          if lk() ~= "locked" then return "it isn't locked" end
          if not toolFor("force", counter(ctx)) then return "needs a tool in the pack: the Terrain Laser, a Repair Kit or the Gravity Gun" end
          return "walk up to it"
        end,
        job = { secs = 40, label = "Forcing the lock",
          check = function() return near(ctx, t), "walked away" end,
          tick = function(dt, frac)
            -- (the noise of it, every couple of seconds)
            if math.floor(frac * 20) ~= math.floor((frac - dt / 40) * 20) then play("audio/foley/ratchet_" .. (1 + math.floor(frac * 50) % 5) .. ".ogg", sid, uid, 0.9, 60) end
          end,
          done = function()
            local tool, _, tname = toolFor("force", counter(ctx))
            local ok, why = forceLock(sid, uid, nil, tname)
            if ctx and ctx.toast then ctx.toast(ok and (why .. " · " .. forceWarn(sid, uid)) or tostring(why), not ok) end
            return ok, why
          end } }
      -- (the job's length follows the tool in the pack: set when the menu describes it)
      local tool = toolFor("force", counter(ctx))
      if tool then out[#out].job.secs = forceSecs(tool, role_of(ctx) == "engineer", door) end
      if state == "open" then
        out[#out + 1] = { id = "lo_relock", type = "action", group = G, label = "Lock it again", keep = true,
          act = function() return relock(sid, uid) end }
        if not rec.ru then
          out[#out + 1] = { id = "lo_clear", type = "action", group = G, label = "Take the lock off", keep = true,
            act = function() return clearCode(sid, uid) end }
        end
      end
    end
    if state == "none" or (state == "open" and not rec.ru) then
      out[#out + 1] = { id = "lo_set", type = "action", group = G, label = state == "none" and "Fit a code lock…" or "Change the code…",
        hint = "✎",
        enabled = function() return lk() ~= "broken" end, why = "its lock was forced: it is broken",
        act = function()
          local BP = ref("blueprints")
          if not (BP and BP.prompt) then return false, "no prompt" end
          BP.prompt({ title = "Set a code", line = "3 to 8 digits on its keypad. Whoever knows it gets in.", text = "", placeholder = "4471",
            maxLen = 8, ok = "Lock it", onOk = function(text) return setCode(sid, uid, text) end })
          return true
        end }
    end
  end
  -- SALVAGE: strip for parts
  if not d.film and part.id ~= "tower" then
    local G = "Salvage"
    local q = stripQuote(sid, uid, ctx)
    if q then
      out[#out + 1] = { id = "lo_yield", type = "info", group = G, label = "Strips into", value = function() return yieldText(stripQuote(sid, uid, ctx)) end }
      local w = stripWarn(q)
      if w then out[#out + 1] = { id = "lo_warn", type = "info", group = G, label = "If stripped", warn = true, value = function() return stripWarn(stripQuote(sid, uid, ctx)) or "nothing follows" end } end
      out[#out + 1] = { id = "lo_strip", type = "action", group = G, label = "Strip for parts", danger = w ~= nil,
        hint = string.format("Engineer · %.0f s", q.secs),
        enabled = function() local q2 = stripQuote(sid, uid, ctx); return q2 ~= nil and q2.why == nil and near(ctx, t) end,
        why = function() local q2 = stripQuote(sid, uid, ctx); return (q2 and q2.why) or "walk up to it" end,
        job = { secs = q.secs, label = "Stripping the " .. tostring(d.label or part.id),
          check = function() return near(ctx, t), "walked away" end,
          tick = function(dt, frac)
            if math.floor(frac * 8) ~= math.floor((frac - dt / q.secs) * 8) then play("audio/foley/ratchet_" .. (1 + math.floor(frac * 40) % 5) .. ".ogg", sid, uid, 0.7, 35) end
          end,
          done = function()
            local ok, why = strip(sid, uid, ctx)
            if ctx and ctx.toast then ctx.toast(tostring(why), not ok) end
            if ok and ctx and ctx.close then pcall(ctx.close) end
            return ok, why
          end } }
    end
  end
  return out
end
providerFn = provider

-- ── a ruin terminal's DATA page (terminal_pages.lootRows) ──────────────────
local function data_rows(scope, ctx)
  local rows = {}
  local s = scope and scope.ruin
  local ST = ref("structures")
  if not (s and ST) then return rows end
  local sid = scope.sid
  local rec = ST.get(sid)
  local codes = {}
  for _, p in ipairs(rec and rec.bp or {}) do
    local st = ST.partState(sid, p.uid)
    if st and st.kp then codes[#codes + 1] = { uid = p.uid, code = st.kp, label = label_of(sid, p.uid), open = st.kpo } end
  end
  if #codes > 0 then
    rows[#rows + 1] = { type = "header", label = "ACCESS CODES" }
    for _, c in ipairs(codes) do
      rows[#rows + 1] = { type = "line", text = string.format("%s · %s%s", c.label, c.code, c.open and " (open)" or "") }
    end
    rows[#rows + 1] = { id = "lo_learn", type = "action", label = "Note the codes", hint = function() return "into the crew's notes" end,
      act = function()
        local n = 0
        for _, c in ipairs(codes) do if learn(sid, c.uid, c.code) then n = n + 1 end end
        return true, n > 0 and string.format("%d code%s noted: the keypads will offer them", n, n == 1 and "" or "s") or "already noted"
      end }
  end
  -- the site's own logs and any in the pack
  local I = inv()
  local pack = (ctx and ctx.actor and ctx.actor.pack) or "astro"
  local mine = {}
  for _, g in ipairs(I and I.itemList(pack) or {}) do local k = logKeyOf(g.id); if k then mine[#mine + 1] = { key = k, name = g.name } end end
  if #mine > 0 then
    rows[#rows + 1] = { type = "header", label = "LOG CARDS IN THE PACK" }
    for _, m in ipairs(mine) do
      rows[#rows + 1] = { id = "lo_read_" .. m.key, type = "action", label = "Read: " .. tostring(m.name), hint = function() return isRead(m.key) and "read" or "new" end,
        act = function()
          local LP = panel()
          if LP and LP.openReader then LP.openReader(m.key) else readLog(m.key) end
          return true
        end }
    end
  end
  -- other sites this one's records name
  local RU = ref("ruins")
  local others = {}
  for _, o in ipairs(RU and RU.sites and RU.sites(s.body) or {}) do if o.id ~= s.id and not o.pending then others[#others + 1] = o end end
  if #others > 0 then
    rows[#rows + 1] = { type = "header", label = "SITES ON FILE" }
    for _, o in ipairs(others) do
      rows[#rows + 1] = { id = "lo_site_" .. tostring(o.id), type = "action", label = o.name, hint = function() return (RU.discovered and RU.discovered(o.id)) and "on the map" or where_of(RU, o) end,
        act = function()
          local ok = RU.discover and RU.discover(o.id, "log")
          return true, ok and (o.name .. " is on the Tracking Station now") or "already on the map"
        end }
    end
  end
  return rows
end
dataRows = data_rows

-- ── spills: a container taken down by any hand ─────────────────────────────
local spill_ver, spill_t = nil, -10
local function spill_tick()
  if now() - spill_t < 0.5 then return end
  spill_t = now()
  local ST, I = ref("structures"), inv()
  if not (ST and I) or ST.version == spill_ver then return end
  spill_ver = ST.version
  local t = cids()
  local changed = false
  for k, e in pairs(t) do
    local sid, uid = parseCid(k)
    if sid and not (ST.getPart and ST.getPart(sid, uid)) then
      if not isEmpty(k) and e.b then
        deliver("lootdrop:none", {}, {}, e.b, e.x, e.y, e.z, k, "Spilled from a container")
        stats.spills = stats.spills + 1
      end
      t[k] = nil
      changed = true
    end
  end
  if changed then sset("loot.cids", t) end
end

-- ── the frame ───────────────────────────────────────────────────────────────
local reg_on, reg_t, hook_on = false, -10, false
function start(node)
  if findScripts then
    local all = findScripts("loot")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  reg_on, hook_on, spill_ver = false, false, nil
  tries = {}
end
function update(node, dt)
  local t = now()
  if (not reg_on or not hook_on) and t - reg_t > 1.0 then
    reg_t = t
    local reg = ref("context_registry")
    if not reg_on and reg and reg.register then reg.register("prop", provider, { id = "loot", order = 4 }); reg_on = true end
    local TP = ref("terminal_pages")
    if not hook_on and TP and type(TP.lootRows) == "table" then
      local have = false
      for _, f in ipairs(TP.lootRows) do if f == data_rows then have = true end end
      if not have then TP.lootRows[#TP.lootRows + 1] = data_rows end
      hook_on = true
    end
  end
  spill_tick()
end
