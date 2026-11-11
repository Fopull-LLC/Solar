-- PART INFO — every single piece of every structure answers for itself.
--
-- (The interaction plan, work/interact/PLAN.md §2.1, §3.2; Ty 2026-11-10:
-- "right clicking any of these parts just says the name of the base".)
--
-- On the ContextLib node (prefabs/ContextLib.prefab.ron) beside the registry.
-- It registers the IDENTITY provider on "prop" and "part" at order 1, the
-- first to name a title, so every kit piece's menu — your own base's, a
-- ruin's, a scenario station's — is titled by the piece itself:
--
--   TITLE      its designation and label, "P-3 · Transfer Pump", or the
--              label alone, "Wall (steel)"
--   SUBTITLE   "<structure> · piece 109 of 148 · Steel"; a ruin's piece
--              "<site> · Abandoned · survey camp · 212 days" (the site's
--              name moved here from the title)
--   CONDITION  knocked askew (and the scenario's words for it), leaning,
--              rusted, dust; a primary pipe's break
--   CONNECTED  one row per system that claims the piece: the grid, its
--              fluid network, its signal cables, its room's air, its plant
--   WHY        one sentence when the piece is not doing its job, from the
--              systems' own answers (base_grid.powerWhy, room_air.runWhy,
--              logic_net.drivenBy, fluid_net.readout, the knock)
--   Name this piece…   the designation the player gives it (part state `tag`)
--   CABIN      (a craft's closed crew part or a port on one, G1) the module,
--              its air, its reserve, a leak: cabin_air.infoRows
--   CRAFT PART (2026-11-11) its wear, when it has any: "WORN to 40 % · a
--              Repair Kit mends it" (craftCondition)
--   A WRECK    (2026-11-11) a craft part torn or broken off, lying about:
--              "TORN OFF <craft> · 1.2 m from its mount · a Repair Kit puts
--              it back on", or why it can't (wreckCondition). Both worked out
--              once when the menu opens.
--
-- DESIGNATIONS: `designate(sid, uid)` → "P-3" (the part state's `tag`, else a
-- running scenario's `start.tags` entry) or the label; `called(sid, uid)` →
-- "P-3" or "the Transfer Pump", the form every system's refusal uses ("P-3
-- is knocked askew: repair it first").
--
-- The rules are pure (the global functions under PURE take plain tables:
-- tests/smoke_interact.lua); the provider reads the systems while a menu is
-- open (8 Hz, context_menu's refresh) and nothing in a frame.

defaults = {}

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

-- ── PURE ────────────────────────────────────────────────────────────────────
-- A designation is short words a person paints on a piece: up to 12 chars,
-- letters, digits, spaces and - . / #
function cleanTag(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  s = s:gsub("[^%w%s%-%./#]", "")
  if s == "" then return nil end
  return s:sub(1, 12)
end
function designateWith(tag, label)
  if tag and tag ~= "" then return tag end
  return label or "piece"
end
function calledWith(tag, label)
  if tag and tag ~= "" then return tag end
  return "the " .. tostring(label or "piece")
end
function titleWith(tag, label)
  if tag and tag ~= "" then return tag .. " · " .. tostring(label or "piece") end
  return label or "piece"
end
-- The WHY line: the first reason any system gave (in the order asked). nil
-- when the piece is doing its job.
function composeWhy(list)
  list = list or {}
  for i = 1, table.maxn(list) do
    local w = list[i]
    if type(w) == "string" and w:match("%S") then return w end
  end
  return nil
end
-- What the piece's condition reads: (part record, part state, def, dust 0..1)
-- → text, warn
function conditionOf(p, st, def, dust)
  local bits, warn = {}, false
  if p and p.wr then
    bits[#bits + 1] = "KNOCKED askew" .. (p.wrl and (": " .. tostring(p.wrl)) or "")
    warn = true
  end
  if p and p.o_p ~= nil and not p.wr then
    local lean = math.abs((p.pitch or 0) - (p.o_p or 0))
    if lean > math.rad(1) then bits[#bits + 1] = string.format("leaning %.0f°", math.deg(lean)) end
  end
  if p and p.o_r ~= nil then
    local lean = math.abs((p.roll or 0) - (p.o_r or 0))
    if lean > math.rad(1) then bits[#bits + 1] = string.format("tilted %.0f°", math.deg(lean)) end
  end
  if p and p.o_c ~= nil then bits[#bits + 1] = "rusted" end
  local hp = st and tonumber(st.hp)
  if hp and hp > 0 and hp < 0.999 then bits[#bits + 1] = string.format("WORN to %d %%", math.floor(hp * 100 + 0.5)); warn = true end
  local brk = st and tonumber(st.brk) or 0
  if brk > 0 then bits[#bits + 1] = string.format("BROKEN: %.0f %% of its bore open", brk * 100); warn = true end
  if st and st.blown then bits[#bits + 1] = "seal BLOWN"; warn = true end
  if (dust or 0) >= 0.05 then bits[#bits + 1] = string.format("dust %d %%", math.floor(dust * 100 + 0.5)) end
  if #bits == 0 then return "sound", false end
  return table.concat(bits, " · "), warn
end
-- "piece 109 of 148"
function pieceIndex(bp, uid)
  for i, q in ipairs(bp or {}) do if q.uid == uid then return i, #bp end end
  return nil, #(bp or {})
end
-- The subtitle: structure name, piece index, material; a ruin's site instead.
-- ruin = { name, kind, age, claimed } | nil
function subtitleWith(recName, idx, n, mat, ruin)
  if ruin then
    if ruin.claimed then return string.format("%s · Claimed · %s", tostring(ruin.name), tostring(ruin.kind)) end
    return string.format("%s · Abandoned · %s · %s days", tostring(ruin.name), tostring(ruin.kind), tostring(ruin.age))
  end
  local s = tostring(recName or "Structure")
  if idx then s = s .. string.format(" · piece %d of %d", idx, n) end
  if mat and mat ~= "" then s = s .. " · " .. tostring(mat) end
  return s
end

-- ── designations in the world ───────────────────────────────────────────────
-- a running scenario's start.tags: { { struct, part | uid, name } … },
-- resolved through scenario_run.pieceOf; re-read every 2 s while asked
local scn = { t = -10, sc = nil, map = {} }
local function scenario_tags()
  if now() - scn.t < 2.0 then return scn.map end
  scn.t = now()
  local SR = ref("scenario_run")
  local sc = SR and SR.isActive and SR.isActive() and SR.scenario and SR.scenario() or nil
  if sc == scn.sc and sc ~= nil then return scn.map end
  scn.sc, scn.map = sc, {}
  local tags = sc and type(sc.start) == "table" and sc.start.tags
  if type(tags) ~= "table" or not SR.pieceOf then return scn.map end
  for _, t in ipairs(tags) do
    if type(t) == "table" and t.name then
      local ok, sid, uid = pcall(SR.pieceOf, { struct = t.struct, part = t.part, uid = t.uid })
      if ok and sid and uid then scn.map[tostring(sid) .. ":" .. tostring(uid)] = cleanTag(tostring(t.name)) end
    end
  end
  return scn.map
end
function tagOf(sid, uid)
  local ST = ref("structures")
  local st = ST and ST.partState and ST.partState(sid, uid)
  if st and type(st.tag) == "string" and st.tag ~= "" then return st.tag end
  return scenario_tags()[tostring(sid) .. ":" .. tostring(uid)]
end
local function label_of(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  return d and d.label or (p and p.id) or "piece"
end
function designate(sid, uid) return designateWith(tagOf(sid, uid), label_of(sid, uid)) end
function called(sid, uid) return calledWith(tagOf(sid, uid), label_of(sid, uid)) end
-- Name a piece (nil or "" clears it). → ok, why
function setTag(sid, uid, name)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return false, "no structures" end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  t.tag = cleanTag(name)
  if not ST.setPartState(sid, uid, next(t) and t or nil) then return false, "that piece is gone" end
  return true
end

-- ── what the systems say about one piece ────────────────────────────────────
local function grid_row(sid, uid, d)
  local pw = d and d.power
  if not pw then return nil end
  local BG = ref("base_grid")
  if not BG then return nil end
  local g = BG.gridOfStruct and BG.gridOfStruct(sid)
  if pw.kind == "breaker" or pw.kind == "xfmr" then return nil end   -- (base_power's own rows)
  if not g then return "not on a base grid" end
  local s = BG.status and BG.status(g.id)
  local head = s and string.format("grid %s · %s of %s kW", s.short and "SHORT" or "ok", string.format("%.1f", s.need or 0), string.format("%.1f", s.supply or 0)) or "on a grid"
  if pw.kind == "load" or pw.kind == "aux" then
    local ST = ref("structures")
    local st = ST and ST.partState and ST.partState(sid, uid)
    if st and st.off then return "switched off · draws nothing · " .. head end
    local served = BG.partServed and BG.partServed(sid, uid)
    local use = pw.kind == "load" and pw.use or nil
    -- (an aux load draws only while it works: a plant's pump, a rack's purge pump)
    return string.format("%s%s · %s", use and string.format("draws %.2f kW", use) or ((pw.use or 0) > 0 and string.format("up to %.1f kW while it works", pw.use) or "a plant load"),
      served == false and " · NOT SERVED" or "", head)
  end
  if pw.kind == "store" then return "a store on " .. head end
  return "a source on " .. head
end
local function fluid_row(sid, uid, d)
  if not (d and d.fl) then return nil end
  local FN = ref("fluid_net")
  local o = FN and FN.readout and FN.readout(sid, uid)
  if not o then return "not piped to anything yet" end
  local F = ref("fluids")
  local sub = o.sub and F and F.SUB and F.SUB[o.sub] and F.SUB[o.sub].label or "empty"
  return string.format("%s · %.2f bar%s", sub, (o.p or 0) / 1e5, o.q and string.format(" · %.2f kg/s", o.q) or "")
end
local function logic_row(sid, uid, d)
  local LN = ref("logic_net")
  if not (LN and LN.wiresAt) then return nil end
  local ws = LN.wiresAt(sid, uid)
  if #ws == 0 then return nil end
  local w, from = nil, nil
  if LN.drivenBy then w, from = LN.drivenBy(sid, uid) end
  if w then
    return string.format("%d signal cable%s · driven by %s%s", #ws, #ws == 1 and "" or "s", from,
      (LN.localControl and LN.localControl(sid, uid)) and " (Local control)" or "")
  end
  return string.format("%d signal cable%s", #ws, #ws == 1 and "" or "s")
end
local function room_row(sid, uid, p, d)
  local RA, RM = ref("room_air"), ref("rooms")
  if not (RA and RA.roomsOf and RA.airOf and RM and RM.roomAt and p) then return nil end
  local R = RA.roomsOf(sid)
  if not R then return nil end
  local b = d and d.box
  local cy = (p.y or 0) + (b and (b[3] + b[4]) / 2 or 0.5)
  local ok, r = pcall(RM.roomAt, R, p.x or 0, cy, p.z or 0)
  if not (ok and r) then return nil end
  local q = RA.airOf(sid, r.id)
  if not q then return "Room " .. tostring(r.id) end
  -- (roompurge) a purge under way, or a sealed room still holding the outside's gas
  local tag = q.purging and " · PURGING" or ((q.foul and q.sealed and not q.airlock and not q.leaky) and " · the outside's gas: purge it at an Air Tank Rack" or "")
  return string.format("Room %s · %.2f atm · O2 %.0f %%%s", tostring(r.id), q.p or 0, 100 * (q.o2 or 0) / math.max(q.p or 0, 1e-6), tag)
end
local function plant_row(sid, uid, d)
  if not (d and (d.nuclear or d.pump or d.reject or d.console or d.turbine or d.press)) then return nil end
  local RP = ref("reactor_plant")
  local e = RP and RP.plantOfPart and RP.plantOfPart(sid, uid)
  if not e then return "no Reactor Vessel Base in this structure" end
  local pg = RP.page and RP.page(e)
  return pg and tostring(pg.title) or "on the plant"
end
-- The WHY sentence for piece (sid, uid) now, or nil.
function whyOf(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not p then return nil end
  local d = defs(p.id) or {}
  local st = ST.partState and ST.partState(sid, uid)
  local list = {}
  if p.wr then
    local rec = ST.get and ST.get(sid)
    local RU = ref("ruins")
    local e = rec and rec.ru and RU and RU.peekState and RU.peekState(rec.ru)
    if rec and rec.ru and not (e and e.cl) then list[#list + 1] = "knocked askew: claim the site, then a Repair Kit puts it back"
    else list[#list + 1] = "knocked askew: a Repair Kit puts it back" end
  end
  local hpw = st and tonumber(st.hp)
  if hpw and hpw > 0 and hpw < 0.999 then list[#list + 1] = string.format("worn to %d %%: a Repair Kit makes it whole", math.floor(hpw * 100 + 0.5)) end
  if st and (tonumber(st.brk) or 0) > 0 then list[#list + 1] = "the pipe is broken open: an Engineer welds it (30 s)" end
  local LN = ref("logic_net")
  if LN and LN.drivenBy and not (LN.localControl and LN.localControl(sid, uid)) then
    local w, from = LN.drivenBy(sid, uid)
    if w then list[#list + 1] = "driven by the Signal Cable from " .. from end
  end
  local RA = ref("room_air")
  if d.life and RA and RA.runWhy then list[#list + 1] = RA.runWhy(sid, uid) end
  if d.fl then
    local FN = ref("fluid_net")
    local o = FN and FN.readout and FN.readout(sid, uid)
    if not o then list[#list + 1] = "not piped to anything yet"
    elseif d.fl.kind == "pump" and st and st.off then list[#list + 1] = "switched off"
    elseif d.fl.kind == "valve" and st and st.shut then list[#list + 1] = "shut: nothing passes it"
    elseif d.fl.kind == "pump" and o.mode == "stall" then list[#list + 1] = "stalled: the line beyond holds more than its head"
    elseif o.mixed then list[#list + 1] = "two substances meet on its network: nothing flows" end
  end
  if d.pump then
    local RP = ref("reactor_plant")
    if RP and RP.whyNot then
      local w = RP.whyNot(sid, uid, true)
      if w and w:find("not plumbed", 1, true) then list[#list + 1] = "not plumbed to a reactor loop" end
    end
    if RP and RP.pumpOn and not RP.pumpOn(sid, uid) then list[#list + 1] = "switched off" end
  end
  if d.light and st and st.off then list[#list + 1] = "switched off" end
  local BG = ref("base_grid")
  if BG and BG.powerWhy and not (st and st.off) then list[#list + 1] = BG.powerWhy(sid, uid) end
  return composeWhy(list)
end

-- WARN: what switching piece (sid, uid) off would do, from the system that
-- owns its switch (fluid_net, reactor_plant, room_air, base_grid warnOf), or
-- nil. Never a refusal: Ty's sandbox lets the player melt the core; the
-- panel says so first.
function warnOf(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not p then return nil end
  local d = defs(p.id) or {}
  local FN, RP, RA, BG, BP = ref("fluid_net"), ref("reactor_plant"), ref("room_air"), ref("base_grid"), ref("base_power")
  local function ask(S, on)
    if not (S and S.warnOf) or not on then return nil end
    local ok, w = pcall(S.warnOf, sid, uid, false)
    return ok and w or nil
  end
  if d.fl and FN then return ask(FN, FN.isOn and FN.isOn(sid, uid)) end
  if d.pump and RP then return ask(RP, RP.pumpOn and RP.pumpOn(sid, uid)) end
  if d.reject and RP then
    if d.reject.kind == "tower" then return ask(RP, RP.towerOn and RP.towerOn(sid, uid)) end
    return ask(RP, RP.radiatorOpen and RP.radiatorOpen(sid, uid))
  end
  if d.life and RA then return ask(RA, RA.machineOn and RA.machineOn(sid, uid)) end
  if d.power and d.power.kind == "breaker" and BG then return ask(BG, BP and BP.breakerState and BP.breakerState(sid, uid) == "closed") end
  return nil
end

-- ── the provider ────────────────────────────────────────────────────────────
local function ruin_of(rec)
  if not (rec and rec.ru) then return nil end
  local RU = ref("ruins")
  local s = RU and RU.site and RU.site(rec.ru)
  if not s then return nil end
  local e = RU.peekState and RU.peekState(rec.ru) or nil
  return { name = s.name, kind = (RU.LABEL and RU.LABEL[s.kind]) or s.kind, age = s.age, claimed = e and e.cl and true or false }
end
local function rec_name(rec)
  if rec.n and rec.n ~= "Structure" then return tostring(rec.n) end
  local B = ref("bases")
  local base = B and B.baseAt and B.baseAt(rec.b, rec.x, rec.y, rec.z)
  if base and base.n then return tostring(base.n) end
  return "Structure " .. tostring(rec.id)
end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, FB = ref("structures"), ref("field_builder")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not (rec and part) then return {} end
  local sid, uid = rec.id, part.uid
  local d = defs(part.id) or {}
  local label = d.label or part.id
  local G = "Piece"
  local out = {}
  local KP = ref("kit_paint")
  out[#out + 1] = { id = "pi_cond", type = "info", label = "Condition", group = G,
    value = function()
      local p = ST.getPart(sid, uid) or part
      local dust = 0
      if KP and KP.dustOf and d.exterior then local ok, v = pcall(KP.dustOf, rec, p, agency_now()); if ok then dust = v or 0 end end
      local txt = conditionOf(p, ST.partState and ST.partState(sid, uid), d, dust)
      return txt
    end,
    warn = function() local p = ST.getPart(sid, uid) or part; local _, w = conditionOf(p, ST.partState and ST.partState(sid, uid), d, 0); return w end }
  local rows = {
    { "pi_grid", "Grid", function() return grid_row(sid, uid, d) end },
    { "pi_fl", "Fluids", function() return fluid_row(sid, uid, d) end },
    { "pi_lg", "Logic", function() return logic_row(sid, uid, d) end },
    { "pi_room", "Air", function() return room_row(sid, uid, ST.getPart(sid, uid) or part, d) end },
    { "pi_rx", "Plant", function() return plant_row(sid, uid, d) end },
  }
  -- CONNECTED: one line naming the systems that claim it; the readings
  -- themselves in the Inspect… sub-panel (the menu stays short enough to
  -- reach its switches)
  local live_rows, names = {}, {}
  for _, r in ipairs(rows) do
    local ok, v = pcall(r[3])
    if ok and v then
      live_rows[#live_rows + 1] = r
      names[#names + 1] = r[2]:lower()
    end
  end
  if #live_rows > 0 then
    out[#out + 1] = { id = "pi_conn", type = "info", label = "On", group = G, value = table.concat(names, " · ") }
  end
  local okw, why = pcall(whyOf, sid, uid)
  if okw and why then
    out[#out + 1] = { id = "pi_why", type = "info", label = "Why", group = G, warn = true,
      value = function() local ok2, w2 = pcall(whyOf, sid, uid); return (ok2 and w2) or "working" end }
  end
  local okn, wn = pcall(warnOf, sid, uid)
  if okn and wn then
    out[#out + 1] = { id = "pi_warn", type = "info", label = "If shut off", group = G, warn = true,
      value = function() local ok2, w2 = pcall(warnOf, sid, uid); return (ok2 and w2) or "nothing follows" end }
  end
  if #live_rows > 0 then
    out[#out + 1] = { id = "pi_insp", type = "sub", group = G, label = "Inspect…", title = titleWith(tagOf(sid, uid), label),
      subtitle = "what its systems read now",
      sub = function()
        local list = {}
        for _, r in ipairs(live_rows) do
          list[#list + 1] = { id = r[1], type = "info", label = r[2], value = function() local ok2, v2 = pcall(r[3]); return ok2 and v2 or "—" end }
        end
        return list
      end }
  end
  local ruin = ruin_of(rec)
  if not (ruin and not ruin.claimed) then
    out[#out + 1] = { id = "pi_tag", type = "action", group = G, hint = "✎",
      label = tagOf(sid, uid) and "Rename this piece…" or "Name this piece…",
      act = function()
        local BP = ref("blueprints")
        if not (BP and BP.prompt) then return false, "no prompt" end
        local cur = tagOf(sid, uid) or ""
        BP.prompt({ title = "Name this piece", line = "A short designation painted on it (P-3, MU-1). Empty clears it.",
          text = cur, placeholder = "P-1", maxLen = 12, ok = "Paint it",
          onOk = function(text) return setTag(sid, uid, text) end })
        return true
      end }
  end
  local idx, n = pieceIndex(rec.bp, uid)
  local title = titleWith(tagOf(sid, uid), label)
  local sub = subtitleWith(rec_name(rec), idx, n, d.matLabel, ruin)
  return out, title, sub
end
providerFn = provider

-- (G1) A CRAFT part in a cabin module (or a docking port on one): its CABIN
-- section, the module's air as cabin_air reads it (the hatches and the patch
-- are cabin_air's own rows).
local function craft_cabin(t, ctx)
  if not (t and t.vessel and t.uid) then return {} end
  local CA = ref("cabin_air")
  if not (CA and CA.infoRows) then return {} end
  local ok, rows = pcall(CA.infoRows, t)
  return (ok and rows) or {}
end
cabinFn = craft_cabin

-- (2026-11-11, the Repair Kit) CONDITION rows on a CRAFT part and on a
-- craft part's WRECK, worked out once when the menu opens (kept on the
-- target the menu holds while it stays open: no scan at the refresh):
--   a craft part   "worn to 40 % · a Repair Kit mends it" (or "sound")
--   a wreck        "TORN OFF Kestrel 2 · 1.2 m from its mount · a Repair
--                  Kit puts it back on" (or the physical reason it can't:
--                  too far, its mount gone, the craft moving)
-- The reattach itself is item_hand's row (KIT.reattachRows).
function craftCondition(hp)
  if not hp then return nil, false end
  if hp <= 0 then return "BROKEN", true end
  if hp < 0.999 then return string.format("WORN to %d %% · a Repair Kit mends it", math.floor(hp * 100 + 0.5)), true end
  return "sound", false
end
function wreckCondition(craft, plan, why, dist)
  local head = "TORN OFF " .. tostring(craft or "its craft")
  if plan then
    return string.format("%s · %.1f m from its mount · a Repair Kit puts it back on%s", head, plan.dist or dist or 0,
      plan.broke and " (it broke: it goes back worn)" or "")
  end
  return head .. (dist and string.format(" · %.1f m from its mount", dist) or "") .. " · " .. tostring(why or "it can't go back on")
end
local function craft_cond(t, ctx)
  if not (t and t.vessel and t.uid and t.vessel.partHp) then return {} end
  local c = t._pi_cond
  if c == nil then
    local ok, hp = pcall(t.vessel.partHp, t.uid)
    local txt, warn = craftCondition(ok and hp or nil)
    c = (txt and warn) and { txt, warn } or false   -- (a sound part: no row, the menu stays short)
    t._pi_cond = c
  end
  if not c then return {} end
  return { { id = "pi_ccond", type = "info", label = "Condition", group = "Piece", value = c[1], warn = c[2] } }
end
craftCondFn = craft_cond
local function wreck_cond(t, ctx)
  if not (t and t.node) then return {} end
  local c = t._pi_wreck
  if c == nil then
    c = false
    for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
      if v.lostOfNode then
        local ok, uid = pcall(v.lostOfNode, t.node)
        if ok and uid then
          local okp, plan, why = pcall(v.reattachPlan, uid)
          local dist = v.reattachDist and select(1, v.reattachDist(uid)) or nil
          if not okp then plan, why = nil, tostring(plan) end
          local lost = v.lostRec and v.lostRec(uid)
          c = { wreckCondition(v.craftName, plan, why, dist), plan == nil, plan and plan.label or (lost and lost.label) }
          break
        end
      end
    end
    t._pi_wreck = c
  end
  if not c then return {} end
  return { { id = "pi_wreck", type = "info", label = "Condition", group = "Piece", value = c[1], warn = true } },
    c[3] and tostring(c[3]) or nil, c[3] and "a craft part, off its craft" or nil
end
wreckCondFn = wreck_cond

local reg_on, reg_t = false, -10
function update(node, dt)
  if reg_on or now() - reg_t < 1.0 then return end
  reg_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", provider, { id = "part_info", order = 1 })
    -- (a VAB part placed live is a part of its structure's vessel)
    reg.register("part", provider, { id = "part_info_live", order = 1 })
    reg.register("part", craft_cabin, { id = "part_info_cabin", order = 12 })
    reg.register("part", craft_cond, { id = "part_info_craft", order = 2 })
    reg.register("prop", wreck_cond, { id = "part_info_wreck", order = 2 })
    reg_on = true
  end
end
