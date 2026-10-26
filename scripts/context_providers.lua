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
-- NOT HERE, ON PURPOSE: Repair, Take, Deploy here, moving things in and out
-- of a locker. Those belong to whatever the actor is HOLDING (a repair kit, a
-- beacon, a flag): the item work registers its own providers and conditions
-- them on `ctx.actor.held` and on `actorReach` below. The menu runs a timed
-- entry for them (`job`, see context_registry.lua).
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
  elseif target.wx then d = crew:distanceTo(vec3 and vec3(target.wx, target.wy, target.wz) or { x = target.wx, y = target.wy, z = target.wz })
  else return nil, nil end
  local rec = target.rec or {}
  local size = math.max(rec.rx or 0.5, rec.rz or 0.5, (rec.h or 1) * 0.5)
  local reach = (P.reach or 2.6) + size + (extra or 0)
  if d <= reach then return "near", d end
  return nil, d
end
crewAccess = actorReach   -- (the old name)

local function far_why(d)
  if not d then return "the crew has to be out on foot, or aboard" end
  return string.format("walk up to it (%.0f m away)", d)
end

-- A container's contents as rows: { { what = "mat"|"gear", id, n, kg, label } }.
function contents(inv, mats, cid)
  local out = {}
  for _, it in ipairs(inv.items(cid)) do
    out[#out + 1] = { what = "mat", id = it.mat, n = it.n, kg = it.kg,
                      label = (mats and mats.label and mats.label(it.mat)) or it.mat }
  end
  for _, g in ipairs(inv.gearItems and inv.gearItems(cid) or {}) do
    out[#out + 1] = { what = "gear", id = g.id, n = g.n, kg = g.kg, label = g.name, tool = g.tool }
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
  local tb = R(ctx, "tool_belt")
  if tb and tb.toolId then
    local okb, belt = pcall(tb.belt)
    local cur = tb.toolId()
    local name = cur
    for _, b in ipairs(okb and belt or {}) do if b.id == cur then name = b.label end end
    out[#out + 1] = { type = "info", id = "hand", group = "PACK", label = "IN HAND", value = name or "—" }
    -- Putting the tool away is the belt's to offer (a `stow`/`holster` of its
    -- own); until it does, nothing pretends to.
    if tb.stow or tb.holster then
      out[#out + 1] = { type = "action", id = "stow", group = "PACK", label = "Stow tool",
        act = function() return (tb.stow or tb.holster)() ~= false end }
    end
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
  end
  if (rec.cargo or 0) > 0 and v.holdId and inv then
    local hid = v.holdId
    out[#out + 1] = { type = "meter", id = "hold", group = "CARGO", label = "HOLD",
      frac = function() local c = inv.cap(hid); return c > 0 and inv.mass(hid) / c or 0 end,
      value = function() return string.format("%s / %s", kgs(ctx, inv.mass(hid)), kgs(ctx, inv.cap(hid))) end }
    out[#out + 1] = { type = "sub", id = "openhold", group = "CARGO", label = "Contents",
      hint = "▸", title = "HOLD  ·  " .. (v.craftName or "craft"), sub = contents_sub(ctx, hid, "Hold") }
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
  if t.mass then out[#out + 1] = { type = "info", id = "mass", label = "MASS", value = tonnes(ctx, t.mass) } end
  out[#out + 1] = { type = "info", id = "grab", label = "", value = "the Gravity Gun can carry it" }
  return out, t.label or (t.node and t.node.name) or "Object"
end

-- ── registration ────────────────────────────────────────────────────────────
PROVIDED = {
  { "astro", "suit", astro_provider, 10 },
  { "part", "core", part_core, 10 },
  { "part", "tank", part_tank, 20 },
  { "part", "engine", part_engine, 25 },
  { "part", "battery", part_battery, 26 },
  { "part", "storage", part_storage, 30 },
  { "part", "actions", part_actions, 40 },
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
