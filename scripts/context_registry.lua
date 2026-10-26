-- CONTEXT_REGISTRY — what a right-click on a thing can do, as data.
--
-- The game's context menus (scripts/context_menu.lua in the world,
-- builder_context.lua in the Vehicle Assembly) don't know what a fuel tank or
-- a helmet is. They ask this registry for a TARGET's entries, and the entries
-- come from PROVIDERS: small functions that look at a target and say what can
-- be done to it. A provider is registered against a target KIND:
--
--   "astro"         the crew on foot (the menu on your own astronaut)
--   "part"          a part of a craft in the world (flying, parked, on the pad)
--   "builder_part"  a placed part in the builder
--   "crate"         a salvage crate
--   "prop"          anything else the pick lands on (a loose rock, a crate)
--
-- Any script can add one, and several providers can serve one kind: the fuel
-- tank's rows, the storage locker's and the repair kit's "Repair" all arrive
-- on the same part menu from different providers, in `order`.
--
--     local reg = findScript("context_registry")
--     reg.register("part", function(t, ctx) return { ... } end, { id = "mine", order = 50 })
--     reg.entriesFor(target, ctx)   -- the merged, normalised list
--
-- ── THE PROVIDER CONTRACT ───────────────────────────────────────────────────
--
--   fn(target, ctx) → entries [, title [, subtitle]]
--
-- called each time the menu is described (a few times a second while it is
-- open), so keep it cheap and put live numbers in functions (`value = fn`).
-- Return {} for a target that isn't yours. An error is caught and reported;
-- it drops that provider's rows, never the menu.
--
-- TARGET (what was right-clicked), always { kind, label?, wx, wy, wz } plus:
--   astro         node (that crew member's body), pack (their container id)
--   part          vessel (its vessel_controller handle), uid, rec (the
--                 blueprint record), node (the part's live node)
--   builder_part  B (the builder handle), uid, rec (builder part record)
--   crate         id (salvage id), entry, node
--   prop          node, mass?
-- wx/wy/wz is the world point the click landed on (stale next frame: the
-- planet moves; re-read the node for anything kept).
--
-- CTX (who is asking, and the menu's services):
--   ctx.actor     WHO OPENED THE MENU. Never assume one global astronaut:
--                 { kind = "crew",  node, id, pack, held, aboard = false }
--                     a crew member on foot: their body, a stable id, their
--                     pack's container id, and what they hold;
--                 { kind = "craft", vessel, node, id, crew = { … }, held = nil }
--                     the piloted craft (menus opened while flying, or from
--                     a seat): its controller handle and who rides it.
--                 `held` = { id = "<gear id>", n } or nil — the item in hand.
--                 A provider for "Repair" / "Take" / "Deploy here" checks
--                 `ctx.actor.held` and the reach (context_providers'
--                 `actorReach(ctx, target)` → "near" | "aboard" | nil, metres).
--   ctx.ref(kind)            a cached findScript
--   ctx.toast(msg, bad)      a line on the menu's foot (and a sound)
--   ctx.sparks(target)       a burst of sparks at the target (work effects)
--   ctx.close()              close the menu
--
-- A timed entry (`job`) is run by the menu: { secs, label, check() → ok, why
-- (polled every frame; false calls it off — the actor walked away, the item
-- left their hands), tick(dt, frac), done() → ok, why }. The menu shows its
-- progress and keeps the actor; nothing else needs a per-frame script.
--
-- A pure rulebook (no scene access, no input): its globals are its API, and it
-- loads from disk in a luajit test (tests/smoke_context.lua).
--
-- ── AN ENTRY ────────────────────────────────────────────────────────────────
--
--   id       unique within the menu (the provider's id is prefixed if absent)
--   type     "action"   a row you press: act()
--            "toggle"   on/off: on (bool or fn → bool), act(want)
--            "slider"   a value: get() → number, set(v), min, max, step, fmt
--            "info"     a read-only row: value (string or fn → string, live)
--            "meter"    a read-only gauge: frac (0..1 or fn), value (text)
--            "sub"      opens a sub-panel: sub() → entries, title
--            "header"   a printed section label
--   label    what it says
--   enabled  bool or fn → bool (default true); why: the reason it is not
--   hint     a key or a short tag shown at the row's end
--   danger   a red key (delete)
--   keep     the menu stays open after the action (default: closes)
--   job      an action that takes time: { secs, label, check() → ok, why,
--            done(), cancel() } — the menu runs it, with a progress bar, and
--            calls off the job when `check` says no (the crew walked away)
--   group    the section the row sits under (a header is put in front of the
--            first row of each new group)

PROVIDERS = {}   -- kind → { { id, fn, order, n } … } sorted by order
local seq = 0

TYPES = { action = true, toggle = true, slider = true, info = true, meter = true, sub = true, header = true }

-- Register (or replace, by id) a provider for a kind. Returns the id.
function register(kind, fn, opts)
  if type(kind) ~= "string" or type(fn) ~= "function" then return nil end
  opts = opts or {}
  seq = seq + 1
  local id = opts.id or (kind .. "#" .. seq)
  local list = PROVIDERS[kind] or {}
  for i = #list, 1, -1 do
    if list[i].id == id then table.remove(list, i) end
  end
  list[#list + 1] = { id = id, fn = fn, order = opts.order or 50, n = seq }
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.n < b.n
  end)
  PROVIDERS[kind] = list
  return id
end

function unregister(kind, id)
  local list = PROVIDERS[kind]
  if not list then return false end
  for i = #list, 1, -1 do
    if list[i].id == id then table.remove(list, i) return true end
  end
  return false
end

function providers(kind)
  local out = {}
  for _, p in ipairs(PROVIDERS[kind] or {}) do out[#out + 1] = p.id end
  return out
end

-- A value that may be live: a function is called (protected), anything else
-- is itself.
function live(v, ...)
  if type(v) == "function" then
    local ok, r = pcall(v, ...)
    if ok then return r end
    return nil
  end
  return v
end

-- One entry made whole: a type, an id, `enabled` answered. Returns nil for
-- something that isn't an entry (a provider's typo must not take the menu down).
function normalize(e, pid, i)
  if type(e) ~= "table" then return nil end
  local ty = e.type or (e.sub and "sub") or (e.act and "action") or "info"
  if not TYPES[ty] then return nil end
  e.type = ty
  e.id = e.id or string.format("%s.%d", pid or "p", i or 0)
  if e.id:find("%.") == nil and pid then e.id = pid .. "." .. e.id end
  e.label = e.label or ""
  return e
end

-- Is this entry usable now? → ok, why.
function usable(e)
  local en = e.enabled
  if en == nil then return true, nil end
  local ok = live(en)
  if ok then return true, nil end
  return false, live(e.why) or "not available"
end

-- Everything every provider of the target's kind offers, in order. Errors in
-- a provider are reported (second value) and its entries dropped, never the
-- whole menu. The `title` of the first provider that names one is the menu's.
function entriesFor(target, ctx)
  local out, errs, title, sub = {}, {}, nil, nil
  if type(target) ~= "table" or not target.kind then return out, errs, title end
  for _, p in ipairs(PROVIDERS[target.kind] or {}) do
    local ok, list, t2, s2 = pcall(p.fn, target, ctx)
    if not ok then
      errs[#errs + 1] = p.id .. ": " .. tostring(list)
    elseif type(list) == "table" then
      if t2 and not title then title, sub = t2, s2 end
      for i, e in ipairs(list) do
        local n = normalize(e, p.id, i)
        if n then out[#out + 1] = n end
      end
    end
  end
  -- Section headers where the group changes (a provider can also give its own).
  local final, last = {}, nil
  for _, e in ipairs(out) do
    if e.group and e.group ~= last and e.type ~= "header" then
      final[#final + 1] = { type = "header", id = "hdr." .. e.group .. "." .. #final, label = e.group }
    end
    if e.type == "header" then last = e.label else last = e.group or last end
    final[#final + 1] = e
  end
  return final, errs, title, sub
end

-- One entry by id (or by the tail after the provider prefix) — probes press entries by id.
function byId(list, id)
  for _, e in ipairs(list or {}) do
    if e.id == id then return e end
    local tail = e.id:match("%.([^%.]+)$")
    if tail == id then return e end
  end
  return nil
end

-- Press an entry the way the panel does: an action runs, a toggle flips, a
-- slider steps (dir ±1). Returns ok, why. A job is handed back for the driver
-- to run (third value).
function press(e, dir)
  if not e then return false, "no such entry" end
  local ok, why = usable(e)
  if not ok then return false, why end
  if e.job then return true, nil, e.job end
  if e.type == "action" and e.act then
    local okc, r, r2 = pcall(e.act)
    if not okc then return false, tostring(r) end
    if r == false then return false, r2 end
    return true, r2
  elseif e.type == "toggle" and e.act then
    local want = not live(e.on)
    local okc, r, r2 = pcall(e.act, want)
    if not okc then return false, tostring(r) end
    if r == false then return false, r2 end
    return true, r2
  elseif e.type == "slider" and e.set and e.get then
    local v = live(e.get) or 0
    local step = e.step or ((e.max or 1) - (e.min or 0)) / 10
    v = math.max(e.min or -math.huge, math.min(e.max or math.huge, v + step * (dir or 1)))
    local okc, r = pcall(e.set, v)
    if not okc then return false, tostring(r) end
    return true, nil
  end
  return false, "nothing to do"
end

-- ── small shared formatters (providers and tests use them) ─────────────────
function kg(x)
  x = x or 0
  if x >= 1000 then return string.format("%.2f t", x / 1000) end
  if x >= 100 then return string.format("%.0f kg", x) end
  return string.format("%.1f kg", x)
end
function tonnes(t)
  t = t or 0
  if t < 1 then return string.format("%.0f kg", t * 1000) end
  return string.format("%.2f t", t)
end
function pct(f) return string.format("%d%%", math.floor((f or 0) * 100 + 0.5)) end
