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
--           AIRLOCKS AND PRESSURE (S3): a door opens only when room_air.gate
--           lets it: an airlock chamber's are interlocked (one at a time, at
--           the pressure behind it), and any other door is held shut by a
--           pressure difference across it until its menu forces it; a door
--           opening or shutting past room_air's OPEN_T tells room_air
--           (doorMoved), so the air vents from then.
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
local paint_sign, paint_emblem   -- (S4: signs and the emblem, below)

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
    -- (a kit fitting's lens; a lamp's own "Lens" child (S4); never a whole shed)
    e.lamp = def.kit and ((def.lens and child(node, "Lens")) or child(node, "Mesh")) or nil
  end
  if def.screen then e.screen = child(node, "Screen") end
  if def.door then
    local st = ST and ST.partState and ST.partState(rec.id, part.uid)
    e.hold = st and st.dh or nil
  end
  -- (S4) a sign's face (its words drawn on spawn, again when they or the
  -- base's name change) and the agency emblem's
  if def.sign or def.emblem then e.face = child(node, "Face"); e.sign_t = -10 end
  E[key(rec.id, part.uid)] = e
  if def.sign then paint_sign(e) end
  if def.emblem then paint_emblem(e) end
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
-- (the interaction plan §3) would a hand on this light's switch be refused?
-- Only by a Signal Cable on its ON terminal (logic_net's authority). → nil | why
function lightWhyNot(sid, uid, want)
  local LN = ref("logic_net")
  if LN and LN.whyNot then
    local ok, w = pcall(LN.whyNot, sid, uid, want)
    if ok and w then return w end
  end
  return nil
end
-- Switch a light. A light switched off stops drawing its power (base_grid
-- reads `st.off` of every load). `by` = "hand" asks lightWhyNot first. → ok, why
function setLight(sid, uid, on, by)
  local ST = ref("structures")
  if not ST then return false end
  if by == "hand" then
    local w = lightWhyNot(sid, uid, on)
    if w then return false, w end
  end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  t.off = (not on) or nil
  ST.setPartState(sid, uid, next(t) and t or nil)
  pool_t = -10
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
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
-- (the interaction plan §2.2, a console's DOORS page) A door's hand command:
-- "lock" (its bolt: shut whoever walks up, whatever a signal says), "open"
-- (held open: an airlock's chamber still rules its own doors, a pressure
-- difference still holds it shut) or nil (it answers the crew). Part state
-- `dh`, mirrored on the live entry so the step reads no state.
function doorHold(sid, uid)
  local e = E[key(sid, uid)]
  if e then return e.hold end
  local ST = ref("structures")
  local st = ST and ST.partState and ST.partState(sid, uid)
  return st and st.dh or nil
end
-- Would a hand be refused making the door `mode`? Only for a physical reason. → nil | why
function doorWhyNot(sid, uid, mode)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  if not p then return "that door is gone" end
  local d = partsDef(p.id)
  if not (d and d.door) then return "that piece is not a door" end
  if p.wr and mode == "open" then return "the door is knocked askew: its track is jammed (a Repair Kit)" end
  return nil
end
function setDoorHold(sid, uid, mode, by)
  if mode ~= "lock" and mode ~= "open" then mode = nil end
  if by == "hand" then local w = doorWhyNot(sid, uid, mode); if w then return false, w end end
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return false, "no structures" end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  local was = t.dh
  t.dh = mode
  if not ST.setPartState(sid, uid, next(t) and t or nil) then return false, "that door is gone" end
  local e = E[key(sid, uid)]
  if e then e.hold = mode end
  scan_t = -10
  local warn = nil
  if mode == "lock" then warn = "locked: nobody walks through it until it is unlocked"
  elseif mode == "open" then
    local RA = ref("room_air")
    local s = RA and RA.state and RA.state(sid)
    local dp = s and RA.door_dp and RA.door_dp(s, uid)
    if dp and dp > 0.05 then warn = string.format("%.2f atm across it: it stays held shut until the sides are equalised (or it is forced)", dp) end
  end
  if was ~= mode then
    local BL = ref("base_log")
    local PI = ref("part_info")
    local nm = (PI and PI.designate) and PI.designate(sid, uid) or "a door"
    if BL and BL.add then pcall(BL.add, sid, "door", string.format("%s %s", nm, mode == "lock" and "locked" or (mode == "open" and "held open" or (was == "lock" and "unlocked" or "released")))) end
  end
  return true, warn
end
local SND = { open = "audio/foley/servo_short.ogg", heavy = "audio/foley/servo_run.ogg", seal = "audio/foley/hiss_seal.ogg" }
-- (graveyard2) a crew member WALKING (crew_body's steer: a scenario walk, a
-- step aside) opens doors too: their walking point, body-relative, placed
-- against this frame's body (frames doc rule 1). The walkers are looked up
-- four times a second, not a scene walk a frame.
local walkers, walkers_t = {}, -1
local function walker_points(out)
  local t = now()
  if t - walkers_t >= 0.25 then
    walkers_t = t
    walkers = {}
    for _, s in ipairs(findScripts and findScripts("crew_body") or {}) do
      if s.doll ~= true and s.walking and s.walking() then walkers[#walkers + 1] = s end
    end
  end
  for _, s in ipairs(walkers) do
    local bn, x, y, z = nil, nil, nil, nil
    if s.walkPoint then bn, x, y, z = s.walkPoint() end
    local b = bn and space and space.body and space.body(bn)
    if b then out[#out + 1] = { x = b.x + x, y = b.y + y, z = b.z + z } end
  end
end
local function crew_points()
  local out = {}
  local a = find and find("Astronaut")
  local pw = ref("planet_walker")
  if valid(a) and (not pw or pw.onFoot ~= false) then out[#out + 1] = a end
  walker_points(out)
  return out
end
local function step_door(e, dt, pts)
  local D = e.def.door
  local want = forceDoors and 1 or 0
  local hold = e.hold
  if want == 0 and hold ~= "lock" then
    for _, a in ipairs(pts) do
      for _, d in ipairs(e.doors) do
        if valid(d.node) then
          -- (the crew in the door's parent frame: drawn poses, this frame)
          local ok, lp = pcall(e.node.toLocal, e.node, vec3(a.x, a.y, a.z))
          if ok and lp then
            local dx, dy, dz = lp.x - d.rest.x, lp.y - d.rest.y, lp.z - d.rest.z
            local vert = D.vertical
            -- WALKING UP TO IT (playtest 2026-11-10: "barely squeezing
            -- through doors"): a door opened only once the crew was `near`,
            -- and a leaf that takes `secs` to slide was 40 % open when a
            -- walker's shoulder reached it (a sprinter's, 25 %), so the
            -- 0.62 m capsule rubbed past the leaf's edge. Coming toward it,
            -- the reach grows by how far the crew closes in the time the
            -- leaf takes (the planet-relative speed, in the door's frame).
            local near = vert and (D.near or 1.6) or (D.near or 2.2)
            local vx, vz = a.vx or 0, a.vz or 0
            if (vx ~= 0 or vz ~= 0 or (a.vy or 0) ~= 0) then
              local ok2, lv = pcall(e.node.toLocal, e.node, vec3(a.x + (a.vx or 0), a.y + (a.vy or 0), a.z + (a.vz or 0)))
              local hd = math.sqrt(dx * dx + dz * dz)
              if ok2 and lv and hd > 1e-3 then
                local closing = -((lv.x - lp.x) * dx + (lv.z - lp.z) * dz) / hd
                if closing > 0.5 then near = math.min(near + 4.0, near + closing * (D.secs or 1.0) * 0.9) end
              end
            end
            if vert then
              if dx * dx + dz * dz < near ^ 2 and math.abs(dy) < vert then want = 1 end
            elseif dx * dx + dz * dz < near ^ 2 and dy > -1.6 and dy < 2.8 then want = 1 end
          end
        end
      end
    end
  end
  -- (a console's hand command, kit_live.setDoorHold) held open: as if crew stood in it
  if hold == "open" and not forceDoors then want = 1 end
  -- (S8) a signal on the door's terminals: `open` holds it open, `lock`
  -- keeps it shut whoever walks up (logic_net); the interlock below still rules
  if not forceDoors then
    local LN = ref("logic_net")
    local c = LN and LN.doorCmd and LN.doorCmd(e.sid, e.uid)
    if c then
      if c.lock then
        if want > 0 and not e.lock_said then
          e.lock_said = true
          local fx = ref("sfx")
          if fx and fx.caption then fx.caption(string.format("the %s is locked by its control signal", e.def.label or "door")) end
        end
        want = 0
      elseif c.open then want = 1 end
    end
    if not (c and c.lock) then e.lock_said = nil end
  end
  -- (the bolt: a door locked by hand stays shut, a signal or not)
  if hold == "lock" and not forceDoors then want = 0 end
  -- (S3) an airlock's doors are interlocked: room_air says which may open
  if not forceDoors then
    local RA = ref("room_air")
    if RA and RA.gate then want = RA.gate(e.sid, e.uid, want) end
  end
  local was = e.open
  local rate = dt / math.max(0.2, D.secs or 1.0)
  if want > e.open then e.open = math.min(1, e.open + rate) elseif want < e.open then e.open = math.max(0, e.open - rate) end
  if e.open ~= was then
    if (was > 0.02) ~= (e.open > 0.02) then
      local RA = ref("room_air")
      if RA and RA.doorMoved then RA.doorMoved(e.sid, e.uid) end
    end
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
    -- (S5) the network: what the cables and transformers lose, what limits it
    if s and (s.loss or 0) > 0.0005 then
      local out_ = (M and M.need or 0) + s.loss
      L(string.format("LOSSES    %.2f kW · %.1f %% of the draw", s.loss, 100 * s.loss / math.max(1e-9, out_)), s.loss / math.max(1e-9, out_) > 0.1)
    end
    if s and s.limited then L("LIMIT     " .. s.limited, (s.limitShare or 0) > 1) end
    local BP = ref("base_power")
    local tr = BP and BP.lastTrips and BP.lastTrips[#BP.lastTrips]
    if tr and M and M.breakers then
      for _, b in ipairs(M.breakers) do
        if b.state == "tripped" then L(string.format("TRIPPED   breaker %d A · reset it by hand", b.pw.amps or 63), true) break end
      end
    end
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
  local RA = ref("room_air")
  local rs = RA and RA.summary and RA.summary(sid)
  if rs and rs.n > 0 then
    L(string.format("ROOMS     %d · sealed %d · %.0f m³", rs.n, rs.sealed, rs.m3), rs.sealed < rs.n)
    if rs.pmin then
      -- (the room the crew are in, else the biggest sealed one; a leak anywhere)
      local a, best, leak = nil, -1, nil
      local st = RA.state and RA.state(sid)
      if st and st.R then
        for _, r in ipairs(st.R.rooms) do
          local q = RA.airOf(sid, r.id)
          if q and r.sealed then
            local score = r.m3 + ((q.crew or 0) > 0 and 1e6 or 0)
            if score > best then a, best = q, score end
          end
          if q and q.venting and not leak and q.p > 0.05 then leak = q.causes[1] or "venting" end
        end
      end
      if a then
        L(string.format("AIR       %.2f atm · O2 %.0f %% · CO2 %.1f %%", a.p, 100 * a.o2 / math.max(a.p, 1e-6), 100 * a.co2 / math.max(a.p, 1e-6)),
          not a.breathable or a.venting)
      end
      if leak then L("LEAK      " .. tostring(leak), true) end
    end
    if rs.life > 0 then L(rs.powered and "LIFE SUPP on the base grid" or "LIFE SUPP NO POWER", not rs.powered) end
  else
    L(string.format("ROOMS     none sealed  ·  %d pieces", #rec.bp))
  end
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
    local many = #info.lines > 9
    pcall(img.text, img, 16, 54 + (i - 1) * (many and 20 or 25), l[1], many and 16 or 20, c[1], c[2], c[3], 1, "left", F)
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

-- ── signs and the emblem (S4) ───────────────────────────────────────────────
-- A sign shows its own words (the part state's `text`) or, with none, its
-- base's name (bases.baseAt), redrawn when either changes. Drawn once into a
-- picture (img:text in the project's fonts, docs/ui-style.md signage: the
-- stencil face for names and big lettering, the label face for placards),
-- never per frame: each sign is its own texture, so its own draw.
NAME_EVERY = 2.0
function signWords(sid, uid)
  local ST, B = ref("structures"), ref("bases")
  local st = ST and ST.partState(sid, uid)
  if st and type(st.text) == "string" and st.text:match("%S") then return st.text, false end
  local rec = ST and ST.get(sid)
  local base = rec and B and B.baseAt and B.baseAt(rec.b, rec.x, rec.y, rec.z)
  if base and base.n then return tostring(base.n), true end
  return (rec and rec.n and rec.n ~= "Structure") and tostring(rec.n) or "OUTPOST", true
end
function setSignWords(sid, uid, text)
  local ST = ref("structures")
  if not ST then return false end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for k, v in pairs(st) do t[k] = v end
  t.text = (type(text) == "string" and text:match("%S")) and text:sub(1, 40) or nil
  ST.setPartState(sid, uid, next(t) and t or nil)
  local e = E[key(sid, uid)]
  if e then paint_sign(e) end
  return true
end
function signText(sid, uid) local e = E[key(sid, uid)]; return e and e.words or nil end

-- (S5 polish: signs readable at 8 m.) The words are set from the fonts' own
-- advance widths (tools: fontTools on fonts/SolarStencil.ttf and
-- SolarLabel.ttf, em units), so the capitals fill the plate: one line, or two
-- when that sets them bigger, and the plate narrows to the words (its Mesh
-- and Face scaled along their width; never under its `fit` share). Light ink
-- on a near-black enamel (ui-style signage: ink on dark enamel).
local ADV = {
  stencil = { [" "] = 0.26, ["!"] = 0.363, ["'"] = 0.3, ["("] = 0.374, [")"] = 0.374, ["+"] = 0.54, [","] = 0.33, ["-"] = 0.379, ["."] = 0.33,
    ["/"] = 0.429, ["0"] = 0.66, ["1"] = 0.402, ["2"] = 0.614, ["3"] = 0.61, ["4"] = 0.654, ["5"] = 0.628, ["6"] = 0.662, ["7"] = 0.576,
    ["8"] = 0.676, ["9"] = 0.662, [":"] = 0.33, ["<"] = 0.541, [">"] = 0.541, ["?"] = 0.521, ["&"] = 0.739, ["#"] = 0.7, ["%"] = 0.898,
    A = 0.687, B = 0.67, C = 0.568, D = 0.68, E = 0.616, F = 0.576, G = 0.66, H = 0.716, I = 0.33, J = 0.425, K = 0.683, L = 0.541,
    M = 0.885, N = 0.716, O = 0.698, P = 0.645, Q = 0.698, R = 0.674, S = 0.612, T = 0.581, U = 0.69, V = 0.663, W = 0.996, X = 0.678,
    Y = 0.633, Z = 0.618, other = 0.62 },
  label = { [" "] = 0.2, ["!"] = 0.302, ["'"] = 0.153, ["("] = 0.298, [")"] = 0.298, ["+"] = 0.465, [","] = 0.232, ["-"] = 0.364, ["."] = 0.242,
    ["/"] = 0.417, ["0"] = 0.509, ["1"] = 0.313, ["2"] = 0.488, ["3"] = 0.478, ["4"] = 0.522, ["5"] = 0.478, ["6"] = 0.479, ["7"] = 0.44,
    ["8"] = 0.484, ["9"] = 0.48, [":"] = 0.304, ["<"] = 0.465, [">"] = 0.465, ["?"] = 0.456, ["&"] = 0.635, ["#"] = 0.642, ["%"] = 0.802,
    A = 0.552, B = 0.542, C = 0.533, D = 0.545, E = 0.513, F = 0.489, G = 0.537, H = 0.557, I = 0.243, J = 0.512, K = 0.549, L = 0.493,
    M = 0.627, N = 0.588, O = 0.544, P = 0.526, Q = 0.521, R = 0.537, S = 0.513, T = 0.516, U = 0.557, V = 0.54, W = 0.771, X = 0.538,
    Y = 0.528, Z = 0.48, other = 0.52 },
}
-- The width of `s` in ems in a face ("stencil" | "label"), UTF-8 aware.
-- (×1.15: the engine sets a run wider than the bare advances add up to; the
-- probe's first plate ran ~10 % over its estimate and lost a letter)
TEXT_SLACK = 1.15
function textEm(s, face)
  local A = ADV[face] or ADV.label
  local w = 0
  for ch in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do w = w + (A[ch] or A.other) end
  return w * TEXT_SLACK
end
-- How a sign's words sit on it (pure): S = the piece's `sign`, words in
-- capitals. → { lines = { … }, size (px), W, H (the picture), f (the plate's
-- share of its full width), m, pad }
function signLayout(S, words)
  local face = (S.style == "plate") and "label" or "stencil"
  local W0 = S.px or 512
  local H = math.max(32, math.floor(W0 * S.h / S.w + 0.5))
  local stencil = S.style == "stencil"
  local m = stencil and 0 or math.floor(H * 0.06)
  local pad = math.floor(H * 0.06)
  local Wt, Ht = W0 - 2 * (m + pad), H - 2 * (m + pad)
  local w1 = math.max(0.5, textEm(words, face))
  local size1 = math.min(Ht * 0.95, Wt / w1)
  local best = { lines = { words }, size = size1, w = w1 }
  -- two lines, split at the space that balances them best
  local bestSplit = nil
  for i = 2, #words - 1 do
    if words:sub(i, i) == " " then
      local a, b = words:sub(1, i - 1), words:sub(i + 1)
      local wa, wb = textEm(a, face), textEm(b, face)
      local wm = math.max(wa, wb)
      if not bestSplit or wm < bestSplit.w then bestSplit = { lines = { a, b }, w = wm } end
    end
  end
  if bestSplit then
    local size2 = math.min(Ht * 0.95 / 2.1, Wt / bestSplit.w)
    if size2 > size1 * 1.15 then best = { lines = bestSplit.lines, size = size2, w = bestSplit.w } end
  end
  -- the plate narrowed to the words (a plate, a board; paint has no plate)
  local f = 1
  if not stencil and S.fit then
    f = math.max(S.fit, math.min(1, (best.w * best.size + 2 * (m + pad) + H * 0.12) / W0))
  end
  return { lines = best.lines, size = best.size, W = math.max(32, math.floor(W0 * f + 0.5)), H = H, f = f, m = m, pad = pad, face = face }
end

local INK = { 0.95, 0.94, 0.89 }
local ENAMEL = { 0.085, 0.09, 0.085 }
paint_sign = function(e)
  local S = e.def.sign
  if not (S and image and image.new and valid(e.face)) then return end
  local words = signWords(e.sid, e.uid)
  words = string.upper(words)
  if e.words == words and e.tex then return end
  e.words = words
  local Lt = signLayout(S, words)
  local W, H = Lt.W, Lt.H
  local stencil = S.style == "stencil"
  local img = e.img
  if not img or img.width ~= W or img.height ~= H then
    if img and assets and assets.release and e.tex then pcall(assets.release, e.tex); e.tex = nil end
    local ok, im = pcall(image.new, W, H)
    if not ok or not im then return end
    img, e.img = im, im
  end
  pcall(img.clear, img)
  local font = (S.style == "plate") and "fonts/SolarLabel.ttf" or "fonts/SolarStencil.ttf"
  if not stencil then
    -- near-black enamel, a light-from-above sheen, a ruled inner border
    pcall(img.fill, img, 0, 0, W, H, ENAMEL[1], ENAMEL[2], ENAMEL[3], 1)
    pcall(img.blend, img, 0, 0, W, math.floor(H * 0.35), 1, 1, 1, 0.035)
    local m = Lt.m
    local t = math.max(3, math.floor(H * 0.014))
    pcall(img.fill, img, m, m, W - 2 * m, t, INK[1], INK[2], INK[3], 0.9)
    pcall(img.fill, img, m, H - m - t, W - 2 * m, t, INK[1], INK[2], INK[3], 0.9)
    pcall(img.fill, img, m, m, t, H - 2 * m, INK[1], INK[2], INK[3], 0.9)
    pcall(img.fill, img, W - m - t, m, t, H - 2 * m, INK[1], INK[2], INK[3], 0.9)
  end
  local size = Lt.size
  local n = #Lt.lines
  local lh = size * 1.05
  local y0 = (H - (n - 1) * lh - size * 1.12) / 2
  for i, line in ipairs(Lt.lines) do
    pcall(img.text, img, W / 2, y0 + (i - 1) * lh, line, size, INK[1], INK[2], INK[3], 1, "center", font)
  end
  -- wear: a few rubbed spots, softer on a plate than on sprayed paint
  local seed = (e.uid or 1) * 7919 + #words * 104729
  for _ = 1, (stencil and 28 or 10) do
    seed = (seed * 1103515245 + 12345) % 2147483648
    local x = seed % W
    local y = math.floor(seed / W) % H
    local r = 1 + seed % 3
    if stencil then pcall(img.fill, img, x, y, r, r, 0, 0, 0, 0)
    else pcall(img.blend, img, x, y, r * 2, r, 0.30, 0.29, 0.26, 0.5) end
  end
  -- the plate as wide as its words
  if e.fitf ~= Lt.f then
    e.fitf = Lt.f
    for _, nm in ipairs({ "Face", "Mesh" }) do
      local c = child(e.node, nm)
      if c then c.scale_x = Lt.f end
    end
  end
  e.layout = Lt
  local ok, tex = pcall(img.texture, img)
  if ok and tex then
    if e.tex ~= tex then
      e.tex = tex
      pcall(e.face.setMaterial, e.face, { texture = tex, color = { 1, 1, 1 } })
    end
  end
  e.sign_t = now()
end
paint_emblem = function(e)
  if not valid(e.face) then return end
  local em = ref("emblem")
  if not em and spawn and not e.em_asked then e.em_asked = true; pcall(spawn, "AgencyLib", vec3(0, 0, 0)) return end
  local tex = em and em.tex and em.tex()
  if tex and (e.tex ~= tex or e.em_v ~= em.version) then
    e.tex, e.em_v = tex, em.version
    pcall(e.face.setMaterial, e.face, { texture = tex, color = { 1, 1, 1 } })
  end
end

-- ── the menu: switch a light, every light, read the screen ──────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  -- (S4: a click on a decal, a sign or a fitting lands on the wall behind it:
  -- field_builder.pickTarget finds the mount at the click point)
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local def = partsDef(part.id) or {}
  local sid, uid = rec.id, part.uid
  local out = {}
  if def.sign then
    out[#out + 1] = { id = "kl_words", type = "info", label = "Words", group = "Sign",
      value = function() local w, isBase = signWords(sid, uid); return isBase and (w .. " (the base's name)") or w end }
    out[#out + 1] = { id = "kl_write", type = "action", label = "Write the words…", group = "Sign", hint = "✎",
      act = function()
        local BP = ref("blueprints")
        if not (BP and BP.prompt) then return false end
        local cur, isBase = signWords(sid, uid)
        BP.prompt({ title = "What the sign says", line = "Leave it empty for the base's name (it follows a rename).",
          text = isBase and "" or cur, placeholder = cur, maxLen = 40, ok = "Paint it",
          onOk = function(text) setSignWords(sid, uid, text); return true end })
        return true
      end }
  end
  if def.light then
    out[#out + 1] = { id = "kl_light", type = "toggle", label = "Light", group = "Fitting", keep = true,
      on = function() local e = E[key(sid, uid)]; return e and light_on(e) or false end,
      act = function(want)
        local ok, why = setLight(sid, uid, want, "hand")
        if ok and audio and audio.play then pcall(audio.play, "audio/foley/switch_2.ogg", { track = "UI", volume = 0.4 }) end
        return ok, why
      end,
      enabled = function() local e = E[key(sid, uid)]; return lightWhyNot(sid, uid, not (e and light_on(e))) == nil end,
      why = function() local e = E[key(sid, uid)]; return lightWhyNot(sid, uid, not (e and light_on(e))) end,
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
        -- (the nearest of the crew points: the Astronaut, a walking body)
        for _, q in ipairs(pts) do
          local dq
          if e.px and e.b then
            local bb = bodies[e.b]
            if bb == nil then bb = (space and space.body and space.body(e.b)) or false; bodies[e.b] = bb end
            if bb then dq = math.sqrt((bb.x + e.px - q.x) ^ 2 + (bb.y + e.py - q.y) ^ 2 + (bb.z + e.pz - q.z) ^ 2) end
          end
          if not dq then
            local w = e.node.worldPos
            dq = math.sqrt((w.x - q.x) ^ 2 + (w.y - q.y) ^ 2 + (w.z - q.z) ^ 2)
          end
          if not d or dq < d then d = dq end
        end
        -- (S8: a door a signal holds open is stepped wherever the crew is)
        local held = false
        if #e.doors > 0 and d >= REACH and e.open <= 0 then
          local LN = ref("logic_net")
          held = LN ~= nil and LN.holding ~= nil and LN.holding(e.sid, e.uid)
        end
        if (#e.doors > 0) and (d < REACH or e.open > 0 or held or e.hold == "open") then near[#near + 1] = e end
        if e.screen and d < SCREEN_R and t - (e.scr_t or -10) >= SCREEN_EVERY then e.scr_t = t; paint_screen(e) end
        -- (S4) a sign showing the base's name follows a rename; the emblem a new one
        if e.face and d < SCREEN_R and t - (e.sign_t or -10) >= NAME_EVERY then
          e.sign_t = t
          if e.def.sign then paint_sign(e) elseif e.def.emblem then paint_emblem(e) end
        end
      end
    end
  end
  for _, e in ipairs(near) do if valid(e.node) then step_door(e, dt, pts) end end
  if t - pool_t >= 0.5 then pool_t = t; pool(a) end
end
