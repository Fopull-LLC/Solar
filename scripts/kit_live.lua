-- KIT_LIVE — what the modular kit's live pieces do once placed (sandbox plan
-- S1/S2; docs/base-building.md §13): doors that open, lights that switch,
-- switch plates, status screens. Also the Equipment Shed's and the Surface
-- Hab's door and lights (parts_base names this script for them, Ty 11-06:
-- they stay one-click prefabs and must work).
--
-- On the Build Kit node (scenes/system.ron). structures.lua calls
-- `spawned(rec, part, node)` as a piece's node lands and `gone(sid, uid)` as
-- it goes; this keeps one entry per live piece and nothing for the rest.
--
--   DOORS   a piece's `door` = { slide = { x, y, z } (m, in its frame),
--           secs, near, pair, vertical }: its "Door" child (and "Door2" the
--           other way, for a pair) slides open while a crew member on foot
--           is within `near` of it and shuts behind them. The leaf's
--           colliders are its own children, so they go with it (a Collidable
--           a script moves: engine docs/scripting/physics.md). A door is
--           eased in its parent's frame (planet-relative: nothing is kept in
--           the world). A leaf servo and the seal's hiss play as it goes.
--   LIGHTS  a piece's `light` = { color, intensity, range }: its "Light"
--           child carries a point light. On/off is the part's state
--           (rec.st[uid].off), switched from its menu or a switch plate. The
--           16-light shader limit (card 0656) is met with a POOL: at most
--           POOL lights lit, the nearest the crew within LIGHT_R, the rest
--           give their slot back (intensity 0) and show by their emissive
--           lens. On a base grid that is short with its battery empty the
--           lights drop to an emergency glow.
--   SWITCH  a switch plate's menu switches every light of its structure.
--   SCREEN  a wall screen's "Screen" quad shows its base: the grid's in/out,
--           the battery, the crew there, what's wrong. Drawn into a picture
--           (img:text in the project's fonts) every SCREEN_EVERY s while the
--           crew is within SCREEN_R, never per frame.
--
-- COST. Nothing at all with no live piece in reach: one scan of the entries
-- every SCAN s for those within REACH of the crew, then per frame only those
-- doors (a toLocal and a lerp each); the lights re-pooled every 0.5 s.
--
-- Probes: entries(), doorOpen(sid, uid), setLight(sid, uid, on), lit(),
-- screenText(sid, uid), forceDoors.

POOL = 8
LIGHT_R = 45.0
REACH = 6.0          -- doors this near the crew are stepped each frame (they open within 3 m)
SCAN = 0.25
SCREEN_R = 30.0
SCREEN_EVERY = 2.0

forceDoors = false

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function child(n, name)
  if not valid(n) then return nil end
  local ok, c = pcall(n.getChild, n, name)
  if ok and c then return c end
  for _, k in ipairs(n:children() or {}) do if k.name == name then return k end end
  return nil
end
local function key(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
local function partsDef(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end

local E = {}            -- key → { sid, uid, node, def, doors = { { node, rest, slide, open } }, light, screen, lit }
local near = {}         -- the entries with doors within REACH (rebuilt every SCAN)
local scan_t, pool_t = -10, -10

function entries() return E end

-- ── the structures hooks ────────────────────────────────────────────────────
function spawned(rec, part, node)
  local def = partsDef(part.id)
  if not (def and valid(node)) then return end
  local e = { sid = rec.id, uid = part.uid, node = node, def = def, doors = {}, open = 0, b = rec.b }
  -- (where it stands, body-relative, once: the scan's distances are then
  -- arithmetic, not an engine read per piece — 1,000 doors in a 6,000-piece
  -- base cost 0.45 ms a frame by worldPos)
  local ST = ref("structures")
  if ST and ST.partPose then e.px, e.py, e.pz = ST.partPose(rec, part, def.seat or 0) end
  if def.door then
    local d = child(node, "Door")
    if d then e.doors[#e.doors + 1] = { node = d, rest = { x = d.x, y = d.y, z = d.z }, sgn = 1 } end
    local d2 = child(node, "Door2")
    if d2 then e.doors[#e.doors + 1] = { node = d2, rest = { x = d2.x, y = d2.y, z = d2.z }, sgn = -1 } end
  end
  if def.light then
    e.light = child(node, "Light")
    e.lamp = def.kit and child(node, "Mesh") or nil   -- (a kit fitting's lens; never a whole shed)
  end
  if def.screen then e.screen = child(node, "Screen") end
  E[key(rec.id, part.uid)] = e
  scan_t = -10
  pool_t = -10
end

function gone(sid, uid)
  local e = E[key(sid, uid)]
  if e and e.img and assets and assets.release and e.tex then pcall(assets.release, e.tex) end
  E[key(sid, uid)] = nil
  scan_t = -10
end

-- ── lights: state, the pool ─────────────────────────────────────────────────
local function light_on(e)
  local ST = ref("structures")
  local st = ST and ST.partState(e.sid, e.uid)
  return not (st and st.off)
end
function setLight(sid, uid, on)
  local ST = ref("structures")
  if not ST then return false end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  t.off = (not on) or nil
  ST.setPartState(sid, uid, next(t) and t or nil)
  pool_t = -10
  return true
end
-- every light of structure `sid`: on (true) or off; → how many
function setLights(sid, on)
  local n = 0
  for _, e in pairs(E) do
    if e.sid == sid and e.def.light then setLight(e.sid, e.uid, on); n = n + 1 end
  end
  if audio and audio.play then pcall(audio.play, "audio/foley/switch_3.ogg", { track = "UI", volume = 0.45 }) end
  return n
end
function lightsOf(sid)
  local n, on = 0, 0
  for _, e in pairs(E) do if e.sid == sid and e.def.light then n = n + 1; if light_on(e) then on = on + 1 end end end
  return n, on
end

-- Is this structure's grid browned out (short, battery empty)? Off any grid
-- the fittings run on their own cells.
-- (a grid of loads alone — fittings with no tower, source or store on it —
-- is no grid: they run on their own cells)
local function real_grid(sid)
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  if not g then return nil end
  local M = BG.model and BG.model(g.id)
  local real = #(g.bases or {}) > 0 or (M and ((M.sources or 0) > 0 or (M.C or 0) > 0))
  return real and g or nil, BG.status and BG.status(g.id), M
end
local function browned(sid)
  local g, s = real_grid(sid)
  return g ~= nil and s ~= nil and (s.short or 0) > 0 and (s.stored or 0) <= 0
end

local LIT = {}           -- key → true: the lights holding a slot
function lit() return LIT end
local function pool(a)
  local cand = {}
  for k, e in pairs(E) do
    if e.def.light and valid(e.light) then
      local on = light_on(e)
      local d = 1e9
      if a and on then
        local w = e.light.worldPos
        d = math.sqrt((w.x - a.x) ^ 2 + (w.y - a.y) ^ 2 + (w.z - a.z) ^ 2)
      end
      cand[#cand + 1] = { k = k, e = e, d = d, on = on }
    end
  end
  table.sort(cand, function(x, y) return x.d < y.d end)
  local got = {}
  for i, c in ipairs(cand) do
    local L = c.e.def.light
    local want = c.on and c.d <= LIGHT_R and i <= POOL
    local dim = c.on and browned(c.e.sid)
    if want then
      got[c.k] = true
      local col = dim and { 1.0, 0.25, 0.15 } or L.color
      pcall(c.e.light.setPointLight, c.e.light, { color = col, intensity = dim and L.intensity * 0.12 or L.intensity, range = L.range })
    elseif LIT[c.k] or c.e.lit == nil then
      pcall(c.e.light.setPointLight, c.e.light, { intensity = 0 })
    end
    -- the lens: lit, dim red, or dark
    local state = (not c.on) and "off" or (dim and "dim" or "on")
    if c.e.lit ~= state and valid(c.e.lamp) then
      c.e.lit = state
      if state == "on" then pcall(c.e.lamp.setTint, c.e.lamp)
      elseif state == "dim" then pcall(c.e.lamp.setTint, c.e.lamp, { color = { 1.0, 0.35, 0.3 } })
      else pcall(c.e.lamp.setTint, c.e.lamp, { color = { 0.16, 0.16, 0.17 } }) end
    end
  end
  LIT = got
end

-- ── doors ───────────────────────────────────────────────────────────────────
function doorOpen(sid, uid) local e = E[key(sid, uid)]; return e and e.open or nil end
local SND = { open = "audio/foley/servo_short.ogg", heavy = "audio/foley/servo_run.ogg", seal = "audio/foley/hiss_seal.ogg" }
local function crew_points()
  local out = {}
  local a = find and find("Astronaut")
  local pw = ref("planet_walker")
  if valid(a) and (not pw or pw.onFoot ~= false) then out[#out + 1] = a end
  return out
end
local function step_door(e, dt, pts)
  local D = e.def.door
  local want = forceDoors and 1 or 0
  if want == 0 then
    for _, a in ipairs(pts) do
      for _, d in ipairs(e.doors) do
        if valid(d.node) then
          -- (the crew in the door's parent frame: drawn poses, this frame)
          local ok, lp = pcall(e.node.toLocal, e.node, vec3(a.x, a.y, a.z))
          if ok and lp then
            local dx, dy, dz = lp.x - d.rest.x, lp.y - d.rest.y, lp.z - d.rest.z
            local vert = D.vertical
            if vert then
              if dx * dx + dz * dz < (D.near or 1.6) ^ 2 and math.abs(dy) < vert then want = 1 end
            elseif dx * dx + dz * dz < (D.near or 2.2) ^ 2 and dy > -1.6 and dy < 2.8 then want = 1 end
          end
        end
      end
    end
  end
  local was = e.open
  local rate = dt / math.max(0.2, D.secs or 1.0)
  if want > e.open then e.open = math.min(1, e.open + rate) elseif want < e.open then e.open = math.max(0, e.open - rate) end
  if e.open ~= was then
    if (was == 0 or was == 1) and audio and audio.play and valid(e.node) then
      local w = e.node.worldPos
      pcall(audio.play, D.heavy and SND.heavy or SND.open, w.x, w.y, w.z, { maxDistance = 25, track = "SFX", volume = 0.5 })
      if D.heavy and was == 1 then pcall(audio.play, SND.seal, w.x, w.y, w.z, { maxDistance = 20, track = "SFX", volume = 0.35 }) end
    end
    local o = e.open
    o = o * o * (3 - 2 * o)
    for _, d in ipairs(e.doors) do
      if valid(d.node) then
        local s = D.slide
        d.node.x, d.node.y, d.node.z = d.rest.x + s[1] * o * d.sgn, d.rest.y + s[2] * o * d.sgn, d.rest.z + s[3] * o * d.sgn
      end
    end
  end
end

-- ── screens ─────────────────────────────────────────────────────────────────
local function money(v) local Ec = ref("base_economy"); return Ec and Ec.money and Ec.money(v) or ("$" .. tostring(v)) end
-- The lines a screen shows for structure `sid` (pure enough: reads the bases
-- and the grid). → { title, lines = { { text, warn } … } }
function screenLines(sid)
  local ST, B, BG = ref("structures"), ref("bases"), ref("base_grid")
  local rec = ST and ST.get(sid)
  local out = { title = "BASE STATUS", lines = {} }
  local function L(t, w) out.lines[#out.lines + 1] = { t, w } end
  if not rec then L("NO STRUCTURE", true) return out end
  local base = B and B.baseAt and B.baseAt(rec.b, rec.x, rec.y, rec.z)
  if base then out.title = string.upper(tostring(base.n or "BASE")) end
  local g, s, M = nil, nil, nil
  if BG then g, s, M = real_grid(sid) end
  if not g then
    L("NO BASE GRID", true)
    L("fittings on their own cells")
    L("a Base Station Tower within 150 m, or")
    L("a Power Cable to one, joins them up")
  else
    L(string.format("GRID IN   %5.2f EC/s", s and s.supply or 0))
    L(string.format("GRID OUT  %5.2f EC/s", M and M.need or 0))
    local cap = M and M.C or 0
    if cap > 0 then
      L(string.format("BATTERY   %3d %%  %4.0f / %.0f EC", math.floor(100 * (s and s.stored or 0) / cap + 0.5), s and s.stored or 0, cap),
        (s and s.stored or 0) / cap < 0.15)
      local left = BG.nightLeft and BG.nightLeft(g.id)
      L(left and string.format("NO SUN     %.1f h on the battery", left / 3600) or "NO SUN     covered")
    else
      L("BATTERY   none on this grid", true)
    end
    if s and (s.short or 0) > 0 then L(string.format("SHORT     %.2f EC/s: loads shed", s.short), true) end
  end
  local n, on = lightsOf(sid)
  L(string.format("LIGHTS    %d of %d on", on, n))
  local C = ref("crew")
  local here = 0
  if C and C.roster then
    for _, r in ipairs(C.roster()) do
      if r.status == "afoot" and r.body == rec.b and r.x then
        if math.sqrt((r.x - rec.x) ^ 2 + (r.y - rec.y) ^ 2 + (r.z - rec.z) ^ 2) < 150 then here = here + 1 end
      end
    end
  end
  L(string.format("CREW HERE %d", here))
  local co = ref("company")
  if co and co.funds then local ok, f = pcall(co.funds); if ok and f then L("FUNDS     " .. money(math.floor(f))) end end
  L(string.format("ROOMS     (S3)  ·  %d pieces", #rec.bp))
  return out
end
function screenText(sid, uid) local e = E[key(sid, uid)]; return e and e.text or nil end

local SW, SH = 512, 308
local function paint_screen(e)
  if not (image and image.new and valid(e.screen)) then return end
  local info = screenLines(e.sid)
  local img = e.img
  if not img then
    local ok, im = pcall(image.new, SW, SH, 0.02, 0.05, 0.06, 1)
    if not ok or not im then return end
    img, e.img = im, im
  else
    pcall(img.fill, img, 0, 0, SW, SH, 0.02, 0.05, 0.06, 1)
  end
  local F = "fonts/SolarMono.ttf"
  pcall(img.fill, img, 0, 0, SW, 46, 0.03, 0.10, 0.12, 1)
  pcall(img.fill, img, 0, 46, SW, 2, 0.20, 0.55, 0.50, 1)
  pcall(img.text, img, 16, 10, info.title, 28, 0.55, 0.95, 0.85, 1, "left", "fonts/SolarLabel.ttf")
  local t = {}
  for i, l in ipairs(info.lines) do
    local c = l[2] and { 1.0, 0.55, 0.25 } or { 0.62, 0.88, 0.82 }
    pcall(img.text, img, 16, 56 + (i - 1) * 25, l[1], 20, c[1], c[2], c[3], 1, "left", F)
    t[#t + 1] = l[1]
  end
  e.text = info.title .. " | " .. table.concat(t, " | ")
  local ok, tex = pcall(img.texture, img)
  if ok and tex then
    if e.tex ~= tex then
      e.tex = tex
      pcall(e.screen.setMaterial, e.screen, { texture = tex, unlit = true, color = { 1, 1, 1 } })
    end
  end
end

-- ── the menu: switch a light, every light, read the screen ──────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local def = partsDef(part.id) or {}
  local sid, uid = rec.id, part.uid
  local out = {}
  if def.light then
    out[#out + 1] = { id = "kl_light", type = "toggle", label = "Light", group = "Fitting", keep = true,
      on = function() local e = E[key(sid, uid)]; return e and light_on(e) or false end,
      act = function(want) setLight(sid, uid, want); if audio and audio.play then pcall(audio.play, "audio/foley/switch_2.ogg", { track = "UI", volume = 0.4 }) end end,
      hint = browned(sid) and "grid short" or nil }
  end
  if def.switch or def.light then
    local n, on = lightsOf(sid)
    if n > 0 then
      out[#out + 1] = { id = "kl_all", type = "toggle", label = string.format("All lights here (%d)", n), group = "Fitting", keep = true,
        on = function() local _, o = lightsOf(sid); return o > 0 end,
        act = function(want) setLights(sid, want) end }
    else
      out[#out + 1] = { id = "kl_none", type = "info", label = "Lights", value = "no light fittings on this structure", group = "Fitting" }
    end
  end
  if def.screen then
    out[#out + 1] = { id = "kl_scr", type = "info", label = "Screen", group = "Fitting",
      value = function() local e = E[key(sid, uid)]; return e and e.text and e.text:sub(1, 60) or "warming up" end }
  end
  if def.door then
    out[#out + 1] = { id = "kl_door", type = "info", label = "Door", group = "Fitting",
      value = function() local e = E[key(sid, uid)]; return e and (e.open > 0.99 and "open" or e.open < 0.01 and "shut" or "moving") or "—" end }
  end
  return out, (#out > 0) and def.label or nil
end
providerFn = provider
local reg_on = false

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("kit_live")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  E, near, LIT = {}, {}, {}
end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "kit_live", order = 5 }); reg_on = true end
  end
  if next(E) == nil then return end
  local t = now()
  local pts = crew_points()
  local a = pts[1]
  if t - scan_t >= SCAN then
    scan_t = t
    near = {}
    local bodies = {}
    for k, e in pairs(E) do
      if not valid(e.node) then E[k] = nil
      elseif a then
        local d
        if e.px and e.b then
          local bb = bodies[e.b]
          if bb == nil then bb = (space and space.body and space.body(e.b)) or false; bodies[e.b] = bb end
          if bb then d = math.sqrt((bb.x + e.px - a.x) ^ 2 + (bb.y + e.py - a.y) ^ 2 + (bb.z + e.pz - a.z) ^ 2) end
        end
        if not d then
          local w = e.node.worldPos
          d = math.sqrt((w.x - a.x) ^ 2 + (w.y - a.y) ^ 2 + (w.z - a.z) ^ 2)
        end
        if (#e.doors > 0) and (d < REACH or e.open > 0) then near[#near + 1] = e end
        if e.screen and d < SCREEN_R and t - (e.scr_t or -10) >= SCREEN_EVERY then e.scr_t = t; paint_screen(e) end
      end
    end
  end
  for _, e in ipairs(near) do if valid(e.node) then step_door(e, dt, pts) end end
  if t - pool_t >= 0.5 then pool_t = t; pool(a) end
end
