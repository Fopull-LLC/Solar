-- CONTEXT_PROVIDERS — the game's own entries for the right-click menus.
--
-- Registered with scripts/context_registry.lua when this script starts (it
-- rides the ContextLib node with the registry). Each provider looks at one
-- target, and at the ACTOR who opened the menu (ctx.actor: a crew member on
-- foot, or a craft), and lists what can be done; scripts/context_menu.lua
-- draws them, builder_context.lua shows the builder's.
--
--   astro         the suit: helmet off / on (the suit's own rule says when it
--                 may come off), the air, the pack (open it), what's in hand
--   part          what the part IS and how it is: health, mass; a tank's own
--                 propellant and a pump to any other tank; an engine's figures;
--                 a battery's charge; a stowage locker's or a cargo bay's
--                 contents (read-only); the part's own actions (deploy,
--                 lights, decouple…)
--   builder_part  a placed part's figures: mass, cost, strength, what it
--                 holds, what it's attached to, its ring; a wheel's modes
--   crate         a salvage crate: what's in it, take it back
--   prop          anything else: what and how far
--
-- THE ITEMS' VERBS (docs/crew-and-items.md §5.3, §6.4) are providers of
-- their own, conditioned on the actor and what they hold:
--   part   held.repair  "Repair" while a Repair Kit is in hand (a dimmed row
--                       saying how to get one when it isn't), a timed TASK
--                       on the crew member (scripts/item_hand.lua runs it)
--          task.cancel  "Cancel repair" on the part being worked
--          (storage)    a locker's or a hold's Take ▸ / Put ▸ / Take all,
--                       and "Refill oxygen tanks" at a locker
--   astro  task.cancel  "Cancel repair" on the crew member at work
--          (suit)       what is in hand, Hold ▸ another, Put it away; the air
--                       with every Oxygen Tank's level; "Give ▸" (later)
--   prop   pickup       "Pick up" a planted relay beacon or a deployable
--
-- Everything here works through other scripts' published API, and every
-- entry that can't be used says why instead of disappearing.

defaults = {
  --@range 1 10 --@units m
  reach = 2.6,           -- how close (beyond the part's own size) an actor on foot must stand
}

local P = params or defaults

-- ── shared helpers ──────────────────────────────────────────────────────────
local function R(ctx, kind) return ctx and ctx.ref and ctx.ref(kind) or nil end
local function reg(ctx) return R(ctx, "context_registry") end

local function kgs(ctx, x)
  local r = reg(ctx)
  if r and r.kg then return r.kg(x) end
  return string.format("%.1f kg", x or 0)
end
local function tonnes(ctx, t)
  local r = reg(ctx)
  if r and r.tonnes then return r.tonnes(t) end
  return string.format("%.2f t", t or 0)
end
local function pctf(f) return string.format("%d%%", math.floor((f or 0) * 100 + 0.5)) end

-- How the ACTOR stands to a target: "aboard" (a craft actor, or a crew
-- member riding the target's craft) | "near" (on foot within reach of it) |
-- nil, and how far (m). Published: the item work's providers use it.
function actorReach(ctx, target, extra)
  local a = ctx and ctx.actor
  if not a then return nil, nil end
  local v = target.vessel
  if v and v.node and a.vessel and a.vessel.node and a.vessel.node.id == v.node.id then return "aboard", 0 end
  if a.kind ~= "crew" or a.aboard then return nil, nil end
  local crew = a.node
  if not (crew and crew.valid ~= false and crew.distanceTo) then return nil, nil end
  local n = target.node
  local d
  if n and n.valid ~= false then d = crew:distanceTo(n)
  elseif target.wx then
    local x, y, z = pickNow(target)
    d = crew:distanceTo(vec3 and vec3(x, y, z) or { x = x, y = y, z = z })
  else return nil, nil end
  local rec = target.rec or {}
  local size = math.max(rec.rx or 0.5, rec.rz or 0.5, (rec.h or 1) * 0.5)
  local reach = (P.reach or 2.6) + size + (extra or 0)
  if d <= reach then return "near", d end
  return nil, d
end
crewAccess = actorReach   -- (the old name)

-- THE PICK POINT, KEPT. A target's wx/wy/wz is the world point of the frame
-- the menu opened, and the home planet moves metres a tick: read raw a
-- second later it is metres off. The first time a provider sees a target
-- (the same frame as the pick: the menu describes itself right after it
-- opens) the point is pinned in the frame it belongs to — the part's own
-- (vessel_controller.partLocalNow), else the world's body — and every later
-- read gets it back where it is NOW. → wx, wy, wz | nil
function pickNow(t)
  if not (t and t.wx) then return nil end
  local v = t.vessel
  if t._pin == nil then
    t._pin = false
    if t.kind == "part" and v and v.partLocalNow then
      local lx, ly, lz = v.partLocalNow(t.uid, t.wx, t.wy, t.wz, true)
      if lx then t._pin = { part = true, lx, ly, lz } end
    end
    if not t._pin and space and space.dominant then
      local d = space.dominant(t.wx, t.wy, t.wz)
      local b = d and space.body(d)
      if b then t._pin = { body = d, t.wx - b.x, t.wy - b.y, t.wz - b.z } end
    end
  end
  local p = t._pin
  if p and p.part and v and v.partPointNow then
    local x, y, z = v.partPointNow(t.uid, p[1], p[2], p[3], true)
    if x then return x, y, z end
  elseif p and p.body then
    local b = space.body(p.body)
    if b then return b.x + p[1], b.y + p[2], b.z + p[3] end
  end
  return t.wx, t.wy, t.wz
end

local function far_why(d)
  if not d then return "the crew has to be out on foot, or aboard" end
  return string.format("walk up to it (%.0f m away)", d)
end

-- An item stack's levels in words: "15 · 9 · 0 min" (the Oxygen Tank).
function tank_levels(g)
  local parts = {}
  -- (a rifle's cell reads in percent: items.fillText)
  local I = findScript and findScript("items")
  if I and I.fillText and g.id then
    local unit
    for i = #g.fills, 1, -1 do parts[#parts + 1], unit = I.fillText(g.id, g.fills[i]) end
    if unit == "%" then return table.concat(parts, " · ") end
    return table.concat(parts, " · ") .. " min"
  end
  for i = #g.fills, 1, -1 do parts[#parts + 1] = string.format("%.0f", g.fills[i] / 60) end
  return table.concat(parts, " · ") .. " min"
end

-- A container's contents as rows: { { what = "mat"|"gear", id, n, kg, label } }.
function contents(inv, mats, cid)
  local out = {}
  for _, it in ipairs(inv.items(cid)) do
    out[#out + 1] = { what = "mat", id = it.mat, n = it.n, kg = it.kg,
                      label = (mats and mats.label and mats.label(it.mat)) or it.mat }
  end
  for _, g in ipairs(inv.gearItems and inv.gearItems(cid) or {}) do
    local label = g.name
    if g.fills then label = string.format("%s  (%s)", g.name, tank_levels(g)) end
    out[#out + 1] = { what = "gear", id = g.id, n = g.n, kg = g.kg, label = label, tool = g.tool, fills = g.fills }
  end
  return out
end

-- A container, READ-ONLY: its load and what is in it. (Moving things in and
-- out is the item work's: a provider of its own, conditioned on the actor and
-- what they hold — see the API at the top of context_registry.lua.)
local function contents_sub(ctx, cid, name)
  return function()
    local inv, mats = R(ctx, "inventory"), R(ctx, "materials")
    if not inv then return { { type = "info", label = "no inventory in this scene" } } end
    local out = {}
    out[#out + 1] = { type = "meter", id = "load", label = string.upper(name),
      frac = function() local c = inv.cap(cid); return c > 0 and inv.mass(cid) / c or 0 end,
      value = function() return string.format("%s / %s", kgs(ctx, inv.mass(cid)), kgs(ctx, inv.cap(cid))) end }
    local inside = contents(inv, mats, cid)
    if #inside == 0 then out[#out + 1] = { type = "info", id = "empty", label = "— empty —" } end
    for _, it in ipairs(inside) do
      out[#out + 1] = { type = "info", id = "c_" .. it.what .. "_" .. it.id,
        label = string.format("%d × %s", it.n, it.label), value = kgs(ctx, it.kg) }
    end
    return out
  end
end

-- ── the suit ────────────────────────────────────────────────────────────────
-- The helmet is the suit's (the EVA-suit work publishes setHelmet / helmetOn
-- and the reason it won't come off). Asked defensively: whichever script
-- carries it, and a dimmed row until one does.
local function suit_api(ctx)
  for _, k in ipairs({ "suit", "eva_suit", "astro_suit", "suit_helmet", "planet_walker" }) do
    local s = R(ctx, k)
    if s and s.setHelmet then return s end
  end
  return nil
end

function helmetWhyNot(s, want)
  if not s then return "the suit has no helmet control in this build" end
  for _, f in ipairs({ "helmetRefusal", "helmetWhyNot", "helmetBlocked" }) do
    if s[f] then
      local ok, why = pcall(s[f], want)
      if ok and why then return why end
      if ok then return nil end
    end
  end
  if s.canRemoveHelmet and not want then
    local ok, can, why = pcall(s.canRemoveHelmet)
    if ok and not can then return why or "not here" end
  end
  return nil
end

local function astro_provider(t, ctx)
  local out = {}
  local pw = R(ctx, "planet_walker")
  local s = suit_api(ctx)
  local on = true
  if s and s.helmetOn then
    local ok, v = pcall(s.helmetOn)
    if ok then on = v ~= false end
  end
  local want = not on
  local why = helmetWhyNot(s, want)
  if not why and s and s.busy then why = "the hands are at the neck ring" end
  out[#out + 1] = { type = "action", id = "helmet", group = "SUIT",
    label = on and "Remove helmet" or "Put on helmet",
    enabled = why == nil, why = why, keep = true,
    act = function()
      local ok, r, r2 = pcall(s.setHelmet, want, t.node)
      if not ok then return false, tostring(r) end
      if r == false then
        if ctx.toast then ctx.toast(r2 or "the helmet stays on", true) end
        return false, r2
      end
      local fx = R(ctx, "sfx")
      if fx and fx.play then pcall(fx.play, want and "close" or "open") end
      if ctx.toast then ctx.toast(want and "helmet on" or "helmet off") end
      return true
    end }
  -- the gold visor and the helmet lamps (the suit's own switches)
  if s and s.setVisor and s.visorDown and on then
    out[#out + 1] = { type = "toggle", id = "visor", group = "SUIT", label = "Sun visor", keep = true,
      on = function() return s.visorDown() == true end,
      act = function(w) local okv, r, r2 = pcall(s.setVisor, w); if okv and r == false then return false, r2 end return okv end }
  end
  if s and s.setLamps and s.lampsOn and on then
    out[#out + 1] = { type = "toggle", id = "lamps", group = "SUIT", label = "Helmet lamps", keep = true,
      on = function() return s.lampsOn() == true end,
      act = function(w) local okl, r, r2 = pcall(s.setLamps, w); if okl and r == false then return false, r2 end return okl end }
  end
  if pw then
    out[#out + 1] = { type = "meter", id = "air", group = "SUIT", label = "AIR",
      frac = function() return pw.oxygen or 1 end,
      value = function()
        if pw.headUnder then return string.format("%.0f s left", pw.o2Left or 0) end
        return pctf(pw.oxygen or 1)
      end }
  end
  local inv = R(ctx, "inventory")
  if inv then
    out[#out + 1] = { type = "info", id = "pack", group = "PACK", label = "LOAD",
      value = function() return inv.line and inv.line(t.pack or "astro") or "" end }
  end
  local ip = R(ctx, "inventory_panel")
  if ip then
    out[#out + 1] = { type = "action", id = "openpack", group = "PACK", label = "Open pack", hint = "TAB",
      act = function()
        if ip.openCounters then ip.openCounters(nil) else ip.open = true end
        return true
      end }
  end
  -- the carried Oxygen Tanks: the total and each tank's level
  local I = R(ctx, "items")
  if inv and inv.fills and I and I.fillCap then
    local cap = I.fillCap("o2tank") or 900
    local fl = inv.fills(t.pack or "astro", "o2tank")
    if #fl > 0 then
      table.sort(fl, function(a, b) return a > b end)
      out[#out + 1] = { type = "meter", id = "tanks", group = "SUIT", label = "O2 TANKS",
        frac = function()
          local tot = 0
          for _, f in ipairs(inv.fills(t.pack or "astro", "o2tank")) do tot = tot + f end
          return tot / math.max(1, cap * #fl)
        end,
        value = function()
          local tot = 0
          for _, f in ipairs(inv.fills(t.pack or "astro", "o2tank")) do tot = tot + f end
          return string.format("%.0f min in %d", tot / 60, #fl)
        end }
      for i, f in ipairs(fl) do
        if i > 6 then break end
        out[#out + 1] = { type = "info", id = "tank" .. i, group = "SUIT", label = string.format("TANK %d", i),
          value = f <= 0 and "empty — refill aboard or at a locker" or string.format("%.0f min  ·  %s", f / 60, pctf(f / cap)),
          warn = f < cap * 0.1 }
      end
    end
  end
  -- what is in hand, another out of the pack, or put away (item_hand)
  local H = R(ctx, "item_hand")
  local mine = ctx.actor and ctx.actor.kind == "crew" and (not t.node or not ctx.actor.node or ctx.actor.node == t.node
    or (t.node.id and ctx.actor.node.id == t.node.id))
  if H and H.held and mine then
    local cur = H.held()
    out[#out + 1] = { type = "info", id = "hand", group = "PACK", label = "IN HAND",
      value = cur and (I and I.nameOf(cur) or cur) or "empty hands" }
    local okb, b = pcall(H.belt)
    if okb and #b > 0 then
      out[#out + 1] = { type = "sub", id = "holdsub", group = "PACK", label = "Hold…", hint = "1–9",
        title = "TAKE IN HAND", sub = function()
          local list = {}
          for i, e in ipairs(H.belt()) do
            list[#list + 1] = { type = "action", id = "hold_" .. e.id, label = e.label .. (e.n > 1 and string.format("  ×%d", e.n) or ""),
              hint = tostring(i), enabled = e.id ~= H.held(), why = "already in hand",
              act = function() local ok2, w = H.hold(e.id); return ok2, w end }
          end
          return list
        end }
    end
    if cur then
      out[#out + 1] = { type = "action", id = "stow", group = "PACK", label = "Put it away", hint = "H",
        act = function() return H.stow() ~= false end }
    end
  end
  -- another crew member: hand them something (slice 3)
  if not mine and ctx.actor and ctx.actor.kind == "crew" then
    out[#out + 1] = { type = "action", id = "give", group = "PACK", label = "Give…", enabled = false,
      why = "handing things over comes with the crew's own bodies" }
  end
  return out, "EVA SUIT", (pw and pw.headUnder) and "under water" or nil
end

-- ── parts of a craft ────────────────────────────────────────────────────────
local function health_words(h)
  if h >= 0.999 then return "sound" end
  if h >= 0.75 then return "scuffed" end
  if h >= 0.45 then return "damaged" end
  return "failing"
end

local function part_core(t, ctx)
  local v, uid, rec = t.vessel, t.uid, t.rec or {}
  local out = {}
  if v and v.partHp then
    out[#out + 1] = { type = "meter", id = "health", label = "HEALTH",
      frac = function() return v.partHp(uid) or 0 end,
      value = function()
        local h = v.partHp(uid)
        if not h then return "gone" end
        return pctf(h) .. "  " .. health_words(h)
      end, warn = function() return (v.partHp(uid) or 1) < 0.75 end }
  end
  out[#out + 1] = { type = "info", id = "mass", label = "MASS",
    value = function()
      local m = rec.mass or 0
      if v and v.tankFuelT then m = m + (v.tankFuelT(uid) or 0) end
      if v and v.LOCKER_T then m = m + (v.LOCKER_T[uid] or 0) end
      return tonnes(ctx, m)
    end }
  local sub = (v and v.craftName) or "craft"
  if rec.kind then sub = sub .. "  ·  " .. rec.kind end
  return out, rec.label or rec.id or "Part", sub
end

local function part_tank(t, ctx)
  local v, uid, rec = t.vessel, t.uid, t.rec or {}
  if not (v and ((rec.fuel or 0) > 0) and v.tankLeft and v.tankLeft(uid) ~= nil) then return {} end
  local cap = rec.fuel or 0
  local out = {}
  out[#out + 1] = { type = "meter", id = "fuel", group = "PROPELLANT", label = "THIS TANK",
    frac = function() return cap > 0 and (v.tankLeft(uid) or 0) / cap or 0 end,
    value = function()
      local l = v.tankLeft(uid) or 0
      return string.format("%.1f / %.0f u  ·  %s", l, cap, tonnes(ctx, l * (rec.fuel_t or 0)))
    end }
  out[#out + 1] = { type = "info", id = "pool", group = "PROPELLANT", label = "ALL TANKS",
    value = function()
      local tot, c = 0, 0
      for _, tk in ipairs(v.tankList and v.tankList() or {}) do tot, c = tot + tk.left, c + tk.cap end
      if c <= 0 then return string.format("%.0f u", v.fuel or 0) end
      return string.format("%.0f / %.0f u in %d", tot, c, #(v.tankList() or {}))
    end }
  if v.tankTransfer and v.tankList then
    local others = {}
    for _, tk in ipairs(v.tankList()) do if tk.uid ~= uid then others[#others + 1] = tk end end
    if #others > 0 then
      out[#out + 1] = { type = "sub", id = "pump", group = "PROPELLANT", label = "Pump propellant…", hint = "▸",
        title = "PUMP  ·  " .. (rec.label or "tank"),
        sub = function()
          local list = {}
          local recs = v.aboardRecs and v.aboardRecs() or {}
          for i, tk in ipairs(v.tankList()) do
            if tk.uid ~= uid then
              local r2 = recs[tk.uid] or {}
              local nm = string.format("%s  #%d", r2.label or "Tank", tk.uid)
              local g = string.format("%s  ·  %.0f / %.0f u", nm:upper(), tk.left, tk.cap)
              list[#list + 1] = { type = "header", id = "h" .. tk.uid, label = g }
              list[#list + 1] = { type = "action", id = "in" .. tk.uid, keep = true, label = "Draw from it", hint = "◂",
                enabled = function() return (v.tankLeft(tk.uid) or 0) > 0.05 and (v.tankLeft(uid) or 0) < cap - 0.05 end,
                why = "nothing to move, or this tank is full",
                act = function()
                  local m = v.tankTransfer(tk.uid, uid)
                  if ctx.toast then ctx.toast(string.format("%.1f u pumped in", m), m <= 0) end
                  return m > 0
                end }
              list[#list + 1] = { type = "action", id = "out" .. tk.uid, keep = true, label = "Pump into it", hint = "▸",
                enabled = function() return (v.tankLeft(uid) or 0) > 0.05 and (v.tankLeft(tk.uid) or 0) < tk.cap - 0.05 end,
                why = "this tank is empty, or that one is full",
                act = function()
                  local m = v.tankTransfer(uid, tk.uid)
                  if ctx.toast then ctx.toast(string.format("%.1f u pumped out", m), m <= 0) end
                  return m > 0
                end }
              if i > 12 then break end
            end
          end
          return list
        end }
    end
  end
  return out
end

local function part_engine(t, ctx)
  local rec = t.rec or {}
  if (rec.thrust or 0) <= 0 then return {} end
  local out = {}
  local k = rec.asl
  local th = rec.thrust
  -- vacuum and sea level on rows of their own: one row with both doesn't fit a screen line
  if k then
    out[#out + 1] = { type = "info", id = "thrust", group = "ENGINE", label = "THRUST VAC", value = string.format("%.0f kN", th) }
    out[#out + 1] = { type = "info", id = "thrust_sl", group = "ENGINE", label = "THRUST SEA", value = string.format("%.0f kN", th * k) }
  else
    out[#out + 1] = { type = "info", id = "thrust", group = "ENGINE", label = "THRUST", value = string.format("%.0f kN", th) }
  end
  if (rec.ve or 0) > 0 then
    out[#out + 1] = { type = "info", id = "ve", group = "ENGINE", label = k and "EXHAUST VAC" or "EXHAUST",
      value = string.format("%.0f m/s", rec.ve) }
    if k then
      out[#out + 1] = { type = "info", id = "ve_sl", group = "ENGINE", label = "EXHAUST SEA", value = string.format("%.0f m/s", rec.ve * k) }
    end
  end
  if (rec.burn or 0) > 0 then
    out[#out + 1] = { type = "info", id = "burn", group = "ENGINE", label = "BURN",
      value = string.format("%.2f u/s full", rec.burn) }
  end
  local v = t.vessel
  if v then
    out[#out + 1] = { type = "info", id = "thr", group = "ENGINE", label = "THROTTLE",
      value = function() return pctf(v.throttle or 0) end }
  end
  return out
end

local function part_battery(t, ctx)
  local E, rec = R(ctx, "electronics"), t.rec or {}
  local m = E and E.modOf and E.modOf(rec, "battery")
  if not (m and (m.ec or 0) > 0) then return {} end
  return { { type = "meter", id = "charge", group = "POWER", label = "CHARGE",
    frac = function() local st = E.stateOf(rec); return (st.charge or 0) / m.ec end,
    value = function() local st = E.stateOf(rec); return string.format("%.0f / %.0f EC", st.charge or 0, m.ec) end } }
end

-- TAKE / PUT between a container on a craft (a locker, a hold) and the
-- actor's pack: one item a press, "Take all" for everything that fits. The
-- actor must be on foot within reach of the part, or aboard that craft; a
-- row that can't go says why (the inventory's reason: "no room: 4 L free").
local function moved_toast(ctx, verb, n, name, why)
  if not ctx.toast then return end
  if n > 0 then ctx.toast(string.format("%s %s%s", verb, name, why and ("  ·  " .. why) or ""))
  else ctx.toast(why or "it didn't move", true) end
end
function move_rows(out, ctx, t, cid, group, what)
  local function pack() return (ctx.actor and ctx.actor.pack) or "astro" end
  local function reach_ok() return actorReach(ctx, t) ~= nil end
  local function reach_why() local _, d = actorReach(ctx, t); return far_why(d) end
  out[#out + 1] = { type = "sub", id = "take_" .. cid, group = group, label = "Take…", hint = "▸",
    title = "TAKE  ·  " .. what, enabled = reach_ok, why = reach_why,
    sub = function()
      local inv, mats = R(ctx, "inventory"), R(ctx, "materials")
      local list = {}
      if not inv then return list end
      for _, g in ipairs(inv.itemList and inv.itemList(cid) or {}) do
        list[#list + 1] = { type = "action", id = "take_" .. g.id, keep = true,
          label = string.format("%s%s", g.name, g.fills and ("  (" .. tank_levels(g) .. ")") or ""),
          hint = string.format("×%d", g.n), enabled = reach_ok, why = reach_why,
          act = function()
            local n, why = inv.moveItem(cid, pack(), g.id, 1)
            moved_toast(ctx, "took the", n, g.name, n > 0 and nil or why)
            if n > 0 then local v = t.vessel; if v and v.holdApplyMass then pcall(v.holdApplyMass, v.node) end end
            return n > 0, why
          end }
      end
      local mat_rows = inv.items(cid)
      if #mat_rows > 0 then
        list[#list + 1] = { type = "action", id = "take_mats", keep = true, label = "Take the materials",
          hint = string.format("%d kinds", #mat_rows), enabled = reach_ok, why = reach_why,
          act = function()
            local n = inv.transferAll(cid, pack())
            if ctx.toast then ctx.toast(n > 0 and string.format("%d unit(s) into the pack", n) or "no room in the pack", n <= 0) end
            local v = t.vessel; if v and v.holdApplyMass then pcall(v.holdApplyMass, v.node) end
            return n > 0
          end }
      end
      if #list == 0 then list[#list + 1] = { type = "info", id = "empty", label = "— empty —" } end
      list[#list + 1] = { type = "action", id = "takeall", label = "Take all", keep = true,
        enabled = reach_ok, why = reach_why,
        act = function()
          local n, why = inv.moveAllItems(cid, pack())
          local m = inv.transferAll(cid, pack())
          if ctx.toast then ctx.toast(string.format("%d item(s), %d unit(s) into the pack%s", n, m, why and ("  ·  " .. why) or ""), n + m <= 0) end
          local v = t.vessel; if v and v.holdApplyMass then pcall(v.holdApplyMass, v.node) end
          return n + m > 0
        end }
      return list
    end }
  out[#out + 1] = { type = "sub", id = "put_" .. cid, group = group, label = "Put…", hint = "▸",
    title = "PUT  ·  " .. what, enabled = reach_ok, why = reach_why,
    sub = function()
      local inv = R(ctx, "inventory")
      local list = {}
      if not inv then return list end
      for _, g in ipairs(inv.itemList and inv.itemList(pack()) or {}) do
        list[#list + 1] = { type = "action", id = "put_" .. g.id, keep = true,
          label = string.format("%s%s", g.name, g.fills and ("  (" .. tank_levels(g) .. ")") or ""),
          hint = string.format("×%d", g.n), enabled = reach_ok, why = reach_why,
          act = function()
            local n, why = inv.moveItem(pack(), cid, g.id, 1)
            moved_toast(ctx, "stowed the", n, g.name, n > 0 and nil or why)
            if n > 0 then local v = t.vessel; if v and v.holdApplyMass then pcall(v.holdApplyMass, v.node) end end
            return n > 0, why
          end }
      end
      if #list == 0 then list[#list + 1] = { type = "info", id = "none", label = "— nothing in the pack —" } end
      return list
    end }
end

local function part_storage(t, ctx)
  local v, uid, rec = t.vessel, t.uid, t.rec or {}
  if not v then return {} end
  local out = {}
  local inv = R(ctx, "inventory")
  local cid = v.lockerOf and v.lockerOf(uid)
  if cid and inv then
    out[#out + 1] = { type = "meter", id = "locker", group = "STOWAGE", label = "LOCKER",
      frac = function() local c = inv.cap(cid); return c > 0 and inv.mass(cid) / c or 0 end,
      value = function() return string.format("%s / %s", kgs(ctx, inv.mass(cid)), kgs(ctx, inv.cap(cid))) end }
    out[#out + 1] = { type = "sub", id = "open", group = "STOWAGE", label = "Contents",
      hint = "▸", title = "LOCKER  ·  " .. (v.craftName or "craft"), sub = contents_sub(ctx, cid, "Locker") }
    move_rows(out, ctx, t, cid, "STOWAGE", "LOCKER")
    local I = R(ctx, "items")
    if inv.refill and I and I.fillCap then
      out[#out + 1] = { type = "action", id = "refill", group = "STOWAGE", keep = true,
        label = "Refill oxygen tanks", hint = v.craftName and ("from " .. v.craftName) or nil,
        enabled = function()
          local acc = actorReach(ctx, t)
          if acc == nil then return false end
          local cap = I.fillCap("o2tank")
          for _, c in ipairs({ ctx.actor and ctx.actor.pack or "astro", cid }) do
            for _, f in ipairs(inv.fills(c, "o2tank")) do if f < cap - 0.5 then return true end end
          end
          return false
        end,
        why = function()
          local acc, d = actorReach(ctx, t)
          if acc == nil then return far_why(d) end
          return "every tank here and in the pack is full"
        end,
        act = function()
          local add = inv.refill(ctx.actor and ctx.actor.pack or "astro", "o2tank") + inv.refill(cid, "o2tank")
          if ctx.toast then ctx.toast(string.format("tanks topped up: +%.0f min of air", add / 60)) end
          local fx = R(ctx, "sfx")
          if fx and fx.play then pcall(fx.play, "close") end
          return add > 0
        end }
    end
  end
  if (rec.cargo or 0) > 0 and v.holdId and inv then
    local hid = v.holdId
    out[#out + 1] = { type = "meter", id = "hold", group = "CARGO", label = "HOLD",
      frac = function() local c = inv.cap(hid); return c > 0 and inv.mass(hid) / c or 0 end,
      value = function() return string.format("%s / %s", kgs(ctx, inv.mass(hid)), kgs(ctx, inv.cap(hid))) end }
    out[#out + 1] = { type = "sub", id = "openhold", group = "CARGO", label = "Contents",
      hint = "▸", title = "HOLD  ·  " .. (v.craftName or "craft"), sub = contents_sub(ctx, hid, "Hold") }
    move_rows(out, ctx, t, hid, "CARGO", "HOLD")
  end
  return out
end

-- The part's own actions (electronics.actionsOf): what its action groups can
-- do, one press each. A toggle shows its state.
local function part_actions(t, ctx)
  local v, uid, rec = t.vessel, t.uid, t.rec or {}
  local E = R(ctx, "electronics")
  if not (v and v.partAction and E and E.actionsOf) then return {} end
  local out = {}
  local ok, acts = pcall(E.actionsOf, rec)
  if not ok then return {} end
  local n = 0
  for _, a in ipairs(acts) do
    if n >= 8 then break end
    if a.kind == "toggle" then
      n = n + 1
      local state = a.state
      out[#out + 1] = { type = "toggle", id = "act_" .. a.id, group = "ACTIONS", label = a.label, keep = true,
        on = function() local st = E.stateOf(rec); return st[state] == true end,
        act = function(want)
          local r = v.partAction(uid, state .. (want and ".on" or ".off"))
          if not r and ctx.toast then ctx.toast("no control of this craft", true) end
          return r
        end }
    elseif a.kind == "trigger" then
      n = n + 1
      out[#out + 1] = { type = "action", id = "act_" .. a.id, group = "ACTIONS", label = a.label,
        danger = a.id == "decouple" or a.id == "jettison",
        act = function()
          local r = v.partAction(uid, a.id)
          if not r and ctx.toast then ctx.toast("it didn't fire", true) end
          return r
        end }
    elseif a.kind == "axis" and a.dir == 0 and a.preset then
      n = n + 1
      out[#out + 1] = { type = "action", id = "act_" .. a.id, group = "ACTIONS", label = a.label, keep = true,
        act = function() return v.partAction(uid, a.id) end }
    end
  end
  return out
end

-- THE CONTROL MODE, on a command part (a pod, cockpit, probe core, rover
-- body or seat): how the craft drives — Auto, Rover, Aircraft or Rocket
-- (scripts/craft_mode.lua; vessel_controller setCtrlMode). One row that
-- steps to the next mode; the craft re-lays its wheels at once.
local CTRL_ORDER = { "auto", "rover", "aircraft", "rocket" }
local CTRL_NAME = { auto = "Auto", rover = "Rover", aircraft = "Aircraft", rocket = "Rocket" }
local function part_ctrl(t, ctx)
  local v, rec = t.vessel, t.rec or {}
  if not (v and v.setCtrlMode and v.ctrlModeInfo) then return {} end
  local isCmd = rec.kind == "crewed" or rec.kind == "probe" or rec.seat == 1 or rec.seat == true or rec.front == 1
  if not isCmd then return {} end
  local function cur()
    local ok, info = pcall(v.ctrlModeInfo)
    return ok and info or {}
  end
  local function nxt(set)
    local s = set or "auto"
    for i, m in ipairs(CTRL_ORDER) do if m == s then return CTRL_ORDER[i % #CTRL_ORDER + 1] end end
    return "auto"
  end
  local i = cur()
  return { { type = "action", id = "ctrlmode", group = "CONTROL MODE", keep = true,
    label = "Mode  " .. (i.set and CTRL_NAME[i.set] or ("Auto: " .. (CTRL_NAME[i.auto or i.mode or ""] or "…"))),
    hint = "▸ " .. CTRL_NAME[nxt(i.set)],
    act = function()
      local m = nxt(cur().set)
      local r = v.setCtrlMode(m)
      if ctx.toast then ctx.toast("control mode: " .. CTRL_NAME[m]) end
      return r
    end } }
end

-- ── the builder ─────────────────────────────────────────────────────────────
local WHEEL_MODES = { "auto", "on", "off", "invert" }
local function builder_part(t, ctx)
  local B, uid = t.B, t.uid
  local rec = t.rec or (B and B.partRec and B.partRec(uid))
  if not rec then return {} end
  local raw = rec.def or {}
  local def = (raw.thrust and B.liveDef) and (B.liveDef(raw) or raw) or raw
  local out = {}
  local ft = B.FUEL_T_PER_UNIT or 0.01
  local wet = (def.mass or 0) + (def.fuel or 0) * ft
  out[#out + 1] = { type = "info", id = "mass", group = "FIGURES", label = "MASS",
    value = (def.fuel or 0) > 0 and string.format("%s dry  ·  %s full", tonnes(ctx, def.mass or 0), tonnes(ctx, wet))
      or tonnes(ctx, def.mass or 0) }
  local co = R(ctx, "company")
  out[#out + 1] = { type = "info", id = "cost", group = "FIGURES", label = "COST",
    value = (co and co.money) and co.money(def.cost or 0) or string.format("$%d", def.cost or 0) }
  if (def.strength or 0) > 0 then
    out[#out + 1] = { type = "info", id = "str", group = "FIGURES", label = "JOINT",
      value = string.format("%.0f kN", def.strength) }
  end
  if (def.fuel or 0) > 0 then
    out[#out + 1] = { type = "info", id = "fuel", group = "HOLDS", label = "PROPELLANT", value = string.format("%.0f u", def.fuel) }
  end
  local ec = def.ec or 0
  local E = R(ctx, "electronics")
  if ec <= 0 and E and E.modOf then
    local m = E.modOf({ mods = def.mods }, "battery")
    ec = m and m.ec or 0
  end
  if ec > 0 then out[#out + 1] = { type = "info", id = "ec", group = "HOLDS", label = "CHARGE", value = string.format("%.0f EC", ec) } end
  if (def.cargo or 0) > 0 then out[#out + 1] = { type = "info", id = "cargo", group = "HOLDS", label = "CARGO", value = kgs(ctx, def.cargo) } end
  if (def.store or 0) > 0 then out[#out + 1] = { type = "info", id = "store", group = "HOLDS", label = "LOCKER", value = kgs(ctx, def.store) } end
  if (def.thrust or 0) > 0 then
    local k = def.asl
    out[#out + 1] = { type = "info", id = "thrust", group = "ENGINE", label = "THRUST",
      value = k and string.format("%.0f kN vac · %.0f sea", def.thrust, def.thrust * k) or string.format("%.0f kN", def.thrust) }
    if (def.ve or 0) > 0 then
      out[#out + 1] = { type = "info", id = "ve", group = "ENGINE", label = "EXHAUST",
        value = k and string.format("%.0f m/s vac · %.0f sea", def.ve, def.ve * k) or string.format("%.0f m/s", def.ve) }
    end
  end
  -- What it hangs off, and how.
  local par = (rec.parent or 0) ~= 0 and B.partRec(rec.parent) or nil
  local how = ({ top = "on top of", bottom = "under", radial = "on the flank of", surface = "on the surface of" })[rec.att or ""]
    or (rec.att and rec.att ~= "" and rec.att) or "on"
  out[#out + 1] = { type = "info", id = "att", group = "ATTACHED", label = "MOUNT",
    value = par and string.format("%s %s", how, (par.def and par.def.label) or par.id or "?") or "the root — nothing under it" }
  if (rec.sym or 0) ~= 0 then
    local n = 0
    for _, u in ipairs(B.partUids and B.partUids() or {}) do
      local r2 = B.partRec(u)
      if r2 and r2.sym == rec.sym then n = n + 1 end
    end
    out[#out + 1] = { type = "info", id = "ring", group = "ATTACHED", label = "SYMMETRY",
      value = rec.mir and rec.mir ~= "" and string.format("mirror pair (%s)", rec.mir) or string.format("ring of %d", n) }
    if B.selectConnected then
      out[#out + 1] = { type = "action", id = "selring", group = "ATTACHED", label = "Select symmetry group",
        act = function() B.selectConnected(uid, "ring") return true end }
    end
  end
  -- A wheel's two modes, as quick keys (the rest is the inspector's).
  if def.wheel and B.cmd then
    local c = B.wheelCfg and B.wheelCfg(uid) or rec.wcfg or {}
    for _, key in ipairs({ "steer", "drive" }) do
      local cur = c[key] or "auto"
      local nxt = WHEEL_MODES[1]
      for i, m in ipairs(WHEEL_MODES) do if m == cur then nxt = WHEEL_MODES[i % #WHEEL_MODES + 1] end end
      out[#out + 1] = { type = "action", id = "w" .. key, group = "WHEEL", keep = true,
        label = (key == "steer" and "Steering  " or "Drive  ") .. cur, hint = "▸ " .. nxt,
        act = function()
          return B.cmd("setWcfg", { uid = uid, key = key, value = nxt, merge = "wcfg" .. key .. uid }) ~= false
        end }
    end
  end
  return out
end

-- ── loose things ────────────────────────────────────────────────────────────
local function crate_provider(t, ctx)
  local sv = R(ctx, "salvage")
  local inv, mats = R(ctx, "inventory"), R(ctx, "materials")
  local out = {}
  if not (sv and inv and t.id) then return out, "SALVAGE CRATE" end
  local cid = sv.containerOf(t.id)
  for _, it in ipairs(contents(inv, mats, cid)) do
    out[#out + 1] = { type = "info", id = "c_" .. it.id, label = string.format("%d × %s", it.n, it.label), value = kgs(ctx, it.kg) }
  end
  local access, d = actorReach(ctx, t, 1.0)
  out[#out + 1] = { type = "action", id = "recover", label = "Take it all back", hint = "E",
    enabled = access ~= nil, why = far_why(d),
    act = function()
      local kg, left = sv.recover(t.id)
      if ctx.toast then ctx.toast(string.format("%s back in the pack%s", kgs(ctx, kg or 0),
        (left or 0) > 0.05 and string.format(" — %s didn't fit", kgs(ctx, left)) or ""), (kg or 0) <= 0) end
      return (kg or 0) > 0
    end }
  return out, "SALVAGE CRATE", "your suit pack"
end

local function prop_provider(t, ctx)
  local out = {}
  local crew = ctx.actor and ctx.actor.kind == "crew" and ctx.actor.node or nil
  if crew and t.node and t.node.valid ~= false and crew.distanceTo then
    out[#out + 1] = { type = "info", id = "dist", label = "DISTANCE",
      value = function() return string.format("%.1f m", crew:distanceTo(t.node)) end }
  end
  -- (a base supply crate is static: supply_crates.lua gives its own rows)
  if t.node and t.node.hasTag and t.node:hasTag("supply_crate") then return out, "Supply crate" end
  if t.mass then out[#out + 1] = { type = "info", id = "mass", label = "MASS", value = tonnes(ctx, t.mass) } end
  out[#out + 1] = { type = "info", id = "grab", label = "", value = "the Gravity Gun can carry it" }
  return out, t.label or (t.node and t.node.name) or "Object"
end

-- ── what the held item brings ───────────────────────────────────────────────
local function damaged(t)
  local v = t.vessel
  local h = v and v.partHp and v.partHp(t.uid)
  return h ~= nil and h > 0 and h < 0.999, h
end
local function slot_key(H, id)
  for i, e in ipairs(H and H.belt and H.belt() or {}) do if e.id == id then return tostring(i) end end
  return "its belt slot"
end
local function member_task(ctx)
  local H = R(ctx, "item_hand")
  if not (H and H.task) then return nil, H end
  local ok, tk = pcall(H.task)
  return ok and tk or nil, H
end

-- REPAIR (§6.4): the kit in hand makes the verb; without it a dimmed row
-- says how to get one, so the verb is discoverable.
local function held_repair(t, ctx)
  pickNow(t)   -- (pinned in the part's frame this frame: see pickNow)
  local is_dmg, hp = damaged(t)
  if not is_dmg then return {} end
  local H = R(ctx, "item_hand")
  local I = R(ctx, "items")
  if not (H and I) then return {} end
  local tk = member_task(ctx)
  if tk then return {} end   -- at work: the cancel row is task.cancel's
  local inv = R(ctx, "inventory")
  if ctx.actor and ctx.actor.kind ~= "crew" then
    return { { type = "action", id = "repair", group = "SERVICE", label = "Repair", enabled = false,
               why = "only on foot or on EVA: no repairs from the seat" } }
  end
  if H.held() ~= "repairkit" then
    local has = inv and inv.itemCount("astro", "repairkit") > 0
    return { { type = "action", id = "repair", group = "SERVICE", label = "Repair", enabled = false,
               why = has and ("hold the Repair Kit (" .. slot_key(H, "repairkit") .. ")")
                 or "needs a Repair Kit — lockers, or the VAB" } }
  end
  local secs = I.repairSecs(hp)
  local v = t.vessel
  local rprog = (v and v.partSt) and v.partSt(t.uid, "rprog") or (t.rec and t.rec.st or {}).rprog
  local kept = I.keptProgress(rprog, (space and space.time and space.time()) or (time or 0), secs)
  return { { type = "action", id = "repair", group = "SERVICE", label = kept > 0 and "Resume repair" or "Repair",
             hint = kept > 0 and string.format("%d%%  ·  %.0f s left", math.floor(kept / secs * 100 + 0.5), secs - kept)
               or string.format("%.0f s", secs),
             enabled = function() return H.repairWhyNot(t, ctx) == nil end,
             why = function() return H.repairWhyNot(t, ctx) end,
             act = function() return H.startRepair(t, ctx) end } }
end

-- CANCEL: explicit, on the crew member and on the part being worked (§6.2).
local function cancel_row(H, label)
  return { type = "action", id = "cancel", group = "WORK", label = label or "Cancel repair", danger = true,
           act = function() return H.cancel("cancelled") end }
end
local function task_cancel_part(t, ctx)
  local tk, H = member_task(ctx)
  if not (tk and H) or tk.uid ~= t.uid then return {} end
  local v = t.vessel
  if v and v.node and tk.craft and v.node.id ~= tk.craft then return {} end
  local f = (tk.done or 0) / math.max(0.1, tk.secs or 1)
  return { { type = "meter", id = "work", group = "WORK", label = "REPAIR", frac = function()
               local k = member_task(ctx); return k and (k.done or 0) / math.max(0.1, k.secs or 1) or f end,
             value = function() local k = member_task(ctx); return pctf(k and (k.done or 0) / math.max(0.1, k.secs or 1) or f) end },
           cancel_row(H) }
end
local function task_cancel_astro(t, ctx)
  local tk, H = member_task(ctx)
  if not (tk and H) then return {} end
  return { { type = "info", id = "work", group = "WORK", label = "AT WORK",
             value = function() local k = member_task(ctx); return k and string.format("%s  ·  %s", k.label or k.kind,
               pctf((k.done or 0) / math.max(0.1, k.secs or 1))) or "—" end },
           cancel_row(H, tk.kind == "repair" and "Cancel repair" or "Cancel") }
end

-- PICK UP a planted relay beacon (comms owns its record) or a deployable
-- (deployables.lua owns those): reach and pack room.
local function pickup(t, ctx)
  local n = t.node
  local inv = R(ctx, "inventory")
  if not (n and inv) then return {} end
  -- where the thing is NOW: its node (a beacon's origin is half its height
  -- over the ground), else the pinned pick point
  local px, py, pz
  if n.valid ~= false and n.worldX then px, py, pz = n.worldX, n.worldY, n.worldZ
  elseif t.wx then px, py, pz = pickNow(t)
  else return {} end
  local net = R(ctx, "comms")
  local is_beacon = n.name == "RelayBeacon" or (n.parent and n.parent.name == "RelayBeacon")
    or (n.hasTag and pcall(n.hasTag, n, "RelayBeacon") and n:hasTag("RelayBeacon"))
  local out = {}
  if net and net.beaconNear then
    local near = net.beaconNear(px, py, pz, 3.5)
    if near or is_beacon then
      local b = near
      local acc, d = actorReach(ctx, t, 1.0)
      out[#out + 1] = { type = "info", id = "relay", group = "RELAY", label = "LINK",
        value = b and (b.linked and string.format("linked, %d%%", math.floor((b.strength or 0) * 100 + 0.5)) or "no link") or "—" }
      out[#out + 1] = { type = "action", id = "pickup", group = "RELAY", label = "Pick up",
        enabled = function()
          if not b then return false end
          if actorReach(ctx, t, 1.0) == nil then return false end
          return (inv.roomForItem("astro", "beacon", 1)) >= 1
        end,
        why = function()
          if not b then return "no beacon there" end
          local a2, d2 = actorReach(ctx, t, 1.0)
          if a2 == nil then return far_why(d2) end
          local _, w = inv.roomForItem("astro", "beacon", 1)
          return w or "no room in the pack"
        end,
        act = function()
          local got = inv.addItem("astro", "beacon", 1)
          if got < 1 then return false, "no room in the pack" end
          net.removeBeacon(b.id)
          if ctx.toast then ctx.toast((b.name or "Relay") .. " picked up") end
          return true
        end }
      return out, (b and b.name) or "RELAY BEACON", "a ground relay"
    end
  end
  local dep = R(ctx, "deployables")
  if dep and dep.near then
    local okn, rec = pcall(dep.near, px, py, pz, 2.5)
    if okn and type(rec) == "table" and rec.id then
      local kind = rec.k or rec.kind or "flag"
      local I = R(ctx, "items")
      local item = (I and I.known(kind)) and kind or nil
      out[#out + 1] = { type = "action", id = "pickup", group = "DEPLOYED", label = "Pick up",
        enabled = function() return item ~= nil and actorReach(ctx, t, 1.0) ~= nil and (inv.roomForItem("astro", item, 1)) >= 1 end,
        why = function()
          if not item then return "it can't be carried" end
          local a2, d2 = actorReach(ctx, t, 1.0)
          if a2 == nil then return far_why(d2) end
          local _, w = inv.roomForItem("astro", item, 1); return w or "no room in the pack"
        end,
        act = function()
          if inv.addItem("astro", item, 1) < 1 then return false, "no room in the pack" end
          local okr = pcall(dep.remove, rec.id)
          if not okr then inv.removeItem("astro", item, 1) return false, "it wouldn't come up" end
          if ctx.toast then ctx.toast((rec.n or (I and I.nameOf(item)) or "it") .. " picked up") end
          return true
        end }
      return out, rec.n or (I and I.nameOf(item)) or "DEPLOYED"
    end
  end
  return {}
end

-- THE MEDKIT (crew.lua's treat): on a crew member on foot (a CrewBody, the
-- "member" target) or on yourself. Their state first — DOWN and the seconds
-- left, or their hp — then "Use Medkit" (dimmed with the reason when it
-- can't be), or "Cancel" while the work runs.
local function medkit_rows(id, ctx)
  local c = R(ctx, "crew")
  if not (c and c.get and c.treatWhyNot) then return {} end
  local r = c.get(id)
  if not r or r.status == "dead" then return {} end
  local out = {}
  local T = c.treating and c.treating()
  if r.downed then
    out[#out + 1] = { type = "info", id = "down", group = "CREW", label = "DOWN", value = function()
      local q = c.get(id)
      return (q and q.downed) and string.format("bleeding out  ·  %d s", math.max(0, math.floor((q.downed.left or 0) + 0.5))) or "—" end }
  elseif (r.hp or 1) < 0.995 then
    out[#out + 1] = { type = "info", id = "hp", group = "CREW", label = "HEALTH", value = function()
      local q = c.get(id); return pctf(q and q.hp or 1) end }
  else
    return out
  end
  if T then
    if T.target == id then
      out[#out + 1] = { type = "meter", id = "treat", group = "CREW", label = T.kind == "revive" and "REVIVING" or "TREATING",
        frac = function() local k = c.treating(); return k and k.frac or 1 end,
        value = function() local k = c.treating(); return pctf(k and k.frac or 1) end }
      out[#out + 1] = { type = "action", id = "cancel_treat", group = "CREW", label = "Cancel", danger = true,
        act = function() return c.cancelTreat("cancelled") end }
    end
    return out
  end
  local I = R(ctx, "items")
  local M = I and I.MEDKIT or {}
  out[#out + 1] = { type = "action", id = "medkit", group = "CREW", label = "Use Medkit",
    hint = r.downed and string.format("revive · %.0f s", M.revive_secs or 6) or string.format("+%d%% · %.0f s",
      math.floor((M.heal or 0.5) * 100 + 0.5), M.heal_secs or 4),
    enabled = function() return c.treatWhyNot(id) == nil end,
    why = function() return c.treatWhyNot(id) end,
    act = function() return c.treat(id) end }
  return out
end
local function member_medkit(t, ctx)
  if not t.id then return {} end
  return medkit_rows(t.id, ctx)
end
local function astro_medkit(t, ctx)
  local c = R(ctx, "crew")
  local id = c and c.activeId and c.activeId()
  if not id then return {} end
  return medkit_rows(id, ctx)
end

-- ── registration ────────────────────────────────────────────────────────────
PROVIDED = {
  { "astro", "task.cancel", task_cancel_astro, 5 },
  { "astro", "medkit", astro_medkit, 8 },
  { "member", "medkit", member_medkit, 10 },
  { "astro", "suit", astro_provider, 10 },
  { "part", "task.cancel", task_cancel_part, 5 },
  { "part", "held.repair", held_repair, 15 },
  { "prop", "pickup", pickup, 20 },
  { "part", "core", part_core, 10 },
  { "part", "tank", part_tank, 20 },
  { "part", "engine", part_engine, 25 },
  { "part", "battery", part_battery, 26 },
  { "part", "storage", part_storage, 30 },
  { "part", "actions", part_actions, 40 },
  { "part", "ctrlmode", part_ctrl, 45 },
  { "builder_part", "figures", builder_part, 10 },
  { "crate", "salvage", crate_provider, 10 },
  { "prop", "prop", prop_provider, 90 },
}

local registered_with = nil
function registerAll(r)
  if not (r and r.register) then return false end
  for _, p in ipairs(PROVIDED) do r.register(p[1], p[3], { id = p[2], order = p[4] }) end
  registered_with = r
  return true
end

local function try_register()
  if registered_with and registered_with.valid ~= false then return true end
  local r = findScript and findScript("context_registry")
  return registerAll(r)
end

function start(node) P = params or defaults; try_register() end
function update(node, dt)
  if not try_register() then return end
  -- Nothing else to do every frame: a provider runs only when a menu asks.
  if script and script.sleep and registered_with then pcall(script.sleep, 2.0) end
end
