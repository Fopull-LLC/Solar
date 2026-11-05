-- FIELD BUILDER — the Engineer's build mode on foot (deep-space addendum K1–K4,
-- K8, K13, N1; docs/base-building.md). The VAB, but you stand in the world and
-- the craft is the ground: the same parts column, a ghost on the ground under
-- the cursor, a click to buy, truck out and set the part down.
--
--   THE KIT     the Build Kit (items.lua `buildkit`), a belt item every
--               Engineer is issued (once per member). Take it out with its
--               number key or B; the cursor is free while it is up (the
--               camera leaves first person and shift-lock; RMB held still
--               looks round, WASD still walks). B again folds the parts column
--               to a tab and back; Esc drops the part in hand, then closes the
--               kit; H or another number key puts it away like any item.
--               Non-Engineers have no kit: B says so.
--   THE PANEL   catalog_panel.lua re-hosted (a FieldCatalogue node spawned
--               under the HUD while the kit is up, destroyed when it closes):
--               this script is its host (the dozen methods below). Search,
--               ALL · ★ · RECENT · BASE, the cards, the spinning preview.
--               The SUB-ASSY tab is hidden, and each card's lines read
--               "$1,040" / "$900 + $140 shipping · Pell Groundworks".
--   THE GHOST   the part's own prefab, spawned once per pick without its
--               bodies (spawn opts body = false: no collider, no physics),
--               parented to the planet, and made a hologram by ghost.apply
--               (green: it can go there; red: it can't, with the reason on the
--               hint line). Moved every frame by its local position, retinted
--               only when its state changes: no mesh is rebuilt per frame.
--   THE AIM     a ray through the cursor (camera.screenToRay) in lateUpdate,
--               after the camera has placed itself for the frame, against
--               terrain and colliders, at most 24 m from the Engineer. The hit
--               is kept in its planet's frame at once; the ghost is drawn
--               from it against the same frame's read.
--   PLACE       LMB: valid → charged (N1: price + 10 % + $50 shipping, at
--               placement), a STRUCTURE record written (structures.lua: body
--               frame, a blueprint part list), the part spawned, the member
--               credited one "built". Shift+LMB keeps a copy in hand. RMB
--               tapped drops the ghost. Ctrl+Z within 60 s takes the last
--               placement back for a full refund (base_economy.UNDO_SECS).
--
-- Gated: the active member is an Engineer (crew.hasRole), on foot, on a world
-- (EVA building is K11), with no other panel up. Off the home world nothing is
-- placed yet (materials and the Fabricator are step 13): the card says why.
--
-- STEP 5's HOOKS: `validity(req)` is the one place a placement is judged (K7
-- adds foundations, keep-outs, crew in the footprint); `pose(hit)` the one
-- place a ground hit becomes a pose (K5 snapping, K6 rotation: `yawOffset`);
-- `place(sid, partId, pose, payer)` the pure-shaped placement (K12); UNDO is
-- a list of { sid, t } (K9's ring replaces it).
--
-- Probes: isOpen(), open(), close(), pick(id), req, lastPlace, lastUndo,
-- placeAt(x, y, z) (a world point, this frame), undo(), sim = { lmb, shift }.

defaults = {
  --@range 4 60 --@units m
  reach = 24.0,
  --@range 0 1
  sound = 1.0,
}

-- Published.
open_ = false
collapsed = false
heldPart = nil        -- the part id in hand (nil = none)
req = nil             -- this frame's placement request (see `validity`)
lastPlace = nil       -- { sid, id, total, t }
lastUndo = nil        -- { sid, refund, t }
gate = "starting up"
escTakenAt = -1
sim = nil             -- probes: { lmb = bool, shift = bool, mouse = {x, y} }

local KIT = "buildkit"
local GREEN, RED = { 0.30, 0.95, 0.65 }, { 1.0, 0.28, 0.20 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end
local function say(s)
  if caption then pcall(caption, s) end
  if log then log("build: " .. s) end
end
local SFX = { place = "audio/foley/clamp_clunk.ogg", denied = "audio/foley/buzz_denied.ogg",
              pick = "audio/foley/switch_2.ogg", undo = "audio/foley/latch_clunk.ogg" }
local function play(k, vol)
  if (params.sound or 1) <= 0 or not (audio and audio.play) then return end
  pcall(audio.play, SFX[k], { track = "UI", volume = vol or 0.5 })
end

local function astro() local a = find and find("Astronaut"); return (a and a.valid ~= false) and a or nil end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save.get("agency.clock")) or 0
end
local function home_body() return save.get("base.body") end

-- ── who may build ───────────────────────────────────────────────────────────
local function member() local c = ref("crew"); return c and c.activeId and c.activeId() or nil end
function isEngineer(id)
  local c = ref("crew")
  if not (c and c.hasRole) then return false end
  local ok, yes = pcall(c.hasRole, id or member(), "engineer")
  return ok and yes == true
end
local function pack() local c = ref("crew"); local id = member(); return (c and c.packOf and id) and c.packOf(id) or "astro" end
local function has_kit() local V = ref("inventory"); return V and V.itemCount and V.itemCount("astro", KIT) > 0 end

-- THE ISSUE: every Engineer gets one Build Kit, once (a kit left in a locker
-- stays there). Checked every few seconds: hires, retrains and old saves.
local issue_t = -10
local function issue_tick()
  if now() - issue_t < 3.0 then return end
  issue_t = now()
  local c, V = ref("crew"), ref("inventory")
  if not (c and c.roster and V and V.addItem and V.itemCount) then return end
  for _, r in ipairs(c.roster()) do
    if r.status ~= "dead" and isEngineer(r) then
      local cid = c.packOf(r.id)
      local key = "inv.issued.buildkit." .. cid
      if save.get(key) ~= true then
        if V.itemCount(cid, KIT) < 1 then pcall(V.addItem, cid, KIT, 1, { force = true }) end
        save.set(key, true)
        if log then log(string.format("build: issued a Build Kit to %s (%s)", tostring(r.name), cid)) end
      end
    end
  end
end

function issueNow() issue_t = -10; issue_tick() end

-- ── is the kit up? ──────────────────────────────────────────────────────────
local function blocked()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return "aboard" end
  if pw.swimming == true then return "swimming" end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then return "the VAB has the keys" end
  for _, k in ipairs({ "pause_menu", "inventory_panel" }) do local s = ref(k); if s and s.open then return k end end
  for _, k in ipairs({ "facility_menu", "ops_board", "orbit_map", "lab_talk" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then return k end
  end
  local H = ref("item_hand")
  if H and H.busy and H.busy() then return "the hands are at the work" end
  return nil
end
local function kit_in_hand() local H = ref("item_hand"); return H and H.held and H.held() == KIT end

function isOpen() return open_ == true end

-- ── the panel host (catalog_panel calls these) ──────────────────────────────
local PB = nil
local function parts() if not PB or PB.valid == false then PB = ref("parts_base") end return PB end
function catalogue() local p = parts(); return p and p.catalogue() or {} end
function partInfo(id) local p = parts(); return p and p.partInfo(id) or nil end
function liveDef(id) return nil end
function heldId() return heldPart end
function holding() return heldPart and "part" or nil end
function researchPending() return false end
subAssemblies = nil
noSubAssy = true
function hint(text, secs) if text then say(text) end end
local panel = nil
function registerPanel(s) panel = s return true end
function previewPrefab(id) local d = partInfo(id); return d and d.prefab or nil end
-- (the preview stand rides with the crew, INSIDE the planet under them: the
-- catalogue's stand sits 2.4 km up its frame, so the frame is put 2.4 km plus
-- half the world's radius down. The studio cameras draw no terrain; the main
-- camera can't see through the ground. The VAB's layer, viewmodel. The live
-- plate works; the 64 px card icons come out as bare sky in the world on
-- either layer — open, see docs/base-building.md §2.)
function previewLayer() return "viewmodel", 3 end
local pv_frame, pv_making = nil, false
function frameNodeOrNil()
  if pv_frame and pv_frame.valid ~= false then return pv_frame end
  local a = astro()
  if a and createNode and not pv_making then
    pv_making = true
    local bn = space.dominant(a.x, a.y, a.z)
    local bb = bn and space.body(bn)
    local down = 2400 + ((bb and bb.radius) or 600) * 0.5
    createNode("FieldPreviewFrame", a, function(n) pv_making = false; pv_frame = n; n.x, n.y, n.z = 0, -down, 0 end)
  end
  return nil
end
-- The parts column: the VAB's left column, below the HUD's top-left chips.
function layout(W, H) return { W = W, H = H, left = { x = 8, y = 112, w = 228, h = math.max(240, H - 252) } } end
local function section_of(id)
  for _, s in ipairs(catalogue()) do for _, x in ipairs(s.ids) do if x == id then return s.title end end end
  return nil
end
local function quote_of(id)
  local E = ref("base_economy")
  local def = partInfo(id)
  if not (E and def) then return nil end
  local a = astro()
  local body = a and space.dominant(a.x, a.y, a.z) or home_body()
  return E.quote(def, section_of(id), body, home_body())
end
function cardLines(id, def, locked)
  local E = ref("base_economy")
  if locked or not E then return nil, nil end
  return E.cardLines(quote_of(id))
end
function footText()
  return heldPart and "IN HAND — LMB places · Shift+LMB keeps one · RMB tap drops" or "click a part to hold its ghost · B folds this"
end

-- Take a part in hand (the card click). → ok
function hold(id)
  if not partInfo(id) then return false end
  if heldPart ~= id then heldPart = id; play("pick", 0.35) end
  return true
end
function dropHeld() heldPart = nil end
pick = hold

-- ── the FieldCatalogue node ─────────────────────────────────────────────────
local cat = { node = nil, making = false }
local function hud() return find and find("Ship HUD") or nil end
local function cat_show(on)
  if on then
    if cat.node and cat.node.valid ~= false then
      local el = cat.node:getcomponent("UiElement")
      if el and el.visible ~= (not collapsed) then el.visible = not collapsed end
      return
    end
    if cat.making then return end
    local h = hud()
    if not (h and spawn) then return end
    cat.making = true
    spawn("FieldCatalogue", vec3(0, 0, 0), function(n)
      cat.making = false
      if not open_ then n:destroy() return end
      cat.node = n
    end, h)
  else
    if cat.node and cat.node.valid ~= false then cat.node:destroy() end
    cat.node = nil
    if pv_frame and pv_frame.valid ~= false then pv_frame:destroy() end
    pv_frame = nil
    panel = nil
  end
end
local function over_panel()
  if collapsed then return false end
  local cp = panel
  if cp and cp.ownsMouse then local ok, r = pcall(cp.ownsMouse); return ok and r == true end
  return false
end
local function typing()
  local f = ui and ui.focused and ui.focused()
  return f ~= nil and f.name == "FieldPartSearch"
end

-- ── the aim and the pose ────────────────────────────────────────────────────
local function mouse_xy()
  if sim and sim.mouse then return sim.mouse[1], sim.mouse[2] end
  return input.mouse()
end
-- A ground hit → the pose a ground part takes there: on the ground point, up
-- = the radial up, its front (+Z) turned toward the Engineer. (Step 5: grid
-- snap, yaw steps, snapping to a structure's nodes.) → pose | nil, why
yawOffset = 0.0
function pose(hit)
  local bname = space.dominant(hit.x, hit.y, hit.z)
  local b = bname and space.body(bname)
  if not b then return nil, "not on a world" end
  local x, y, z = hit.x - b.x, hit.y - b.y, hit.z - b.z
  local ux, uy, uz = norm(x, y, z)
  local a = astro()
  local fx, fy, fz = 0, 0, 1
  if a then fx, fy, fz = a.x - hit.x, a.y - hit.y, a.z - hit.z end
  local d = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-3 then fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz end
  fx, fy, fz = norm(fx, fy, fz)
  if yawOffset ~= 0 then
    local rx, ry, rz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
    local c, s = math.cos(yawOffset), math.sin(yawOffset)
    fx, fy, fz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s
  end
  -- (wx, wy, wz: the hit as the ray found it, for this frame's physics
  -- queries only: never kept past the frame)
  return { body = bname, x = x, y = y, z = z, wx = hit.x, wy = hit.y, wz = hit.z,
           up = { x = ux, y = uy, z = uz }, fwd = { x = fx, y = fy, z = fz },
           nx = hit.nx or ux, ny = hit.ny or uy, nz = hit.nz or uz, node = hit.node }
end

local function is_ground(n, bname)
  if not n then return true end
  if n.name == bname then return true end
  local ok, t = pcall(function() return n.terrain end)
  return ok and t ~= nil and t ~= false
end

-- THE ONE PLACE a placement is judged. → req (with .bad = the reason, or nil)
local ov = { key = nil, hit = nil, t = -10 }
local vmemo = { key = nil, t = -10 }   -- the last judged pose (lateUpdate)
function validity(id, p)
  local def = partInfo(id)
  local r = { id = id, def = def, pose = p }
  if not def then r.bad = "no such part" return r end
  local q = quote_of(id)
  r.quote = q
  local up = p.up
  if q and q.mode == "away" then r.bad = q.why return r end
  local slope = p.nx * up.x + p.ny * up.y + p.nz * up.z
  if slope < (def.slope or 0.8) then r.bad = string.format("too steep for a %s (%.0f°)", def.label, math.deg(math.acos(math.max(-1, math.min(1, slope))))) return r end
  -- the ray stopped on something that isn't ground (a placed part, a crate,
  -- a facility): standing a part on another is snapping's (step 5, K5a)
  if p.node and not is_ground(p.node, p.body) then
    local n = p.node
    local nm = tostring(n.name or "something")
    if nm:match("^Wall %d+$") or nm:match("^Shell") then
      local okp, par = pcall(function() return n.parent end)
      if okp and par and par.name then nm = tostring(par.name) end
    end
    r.bad = "on the " .. nm .. ": building on top of a part comes with snapping"
    return r
  end
  local wx, wy, wz = p.wx, p.wy, p.wz
  local cl = ref("climate")
  local dep = cl and cl.seaDepth and cl.seaDepth(wx, wy, wz)
  if dep and dep > 0.05 then r.bad = "under water" return r end
  local bf = ref("base_facilities")
  if bf and bf.keepClear then
    local ok, kc = pcall(bf.keepClear, p.body, p.x, p.y, p.z)
    if ok and kc then r.bad = "inside the spaceport: build out past its paving" return r end
  end
  -- something in the way (placement.overlapObb; cached while the ghost holds still)
  local pl = ref("placement")
  if pl and pl.overlapObb and def.half then
    local key = string.format("%s|%.1f|%.1f|%.1f|%.2f|%.2f", id, p.x, p.y, p.z, p.fwd.x, p.fwd.z)
    if key ~= ov.key or now() - ov.t > 0.5 then
      local h = def.half
      local lift = 0.25
      local cx, cy, cz = wx + up.x * (h.y + lift), wy + up.y * (h.y + lift), wz + up.z * (h.y + lift)
      local rx, ry, rz = up.y * p.fwd.z - up.z * p.fwd.y, up.z * p.fwd.x - up.x * p.fwd.z, up.x * p.fwd.y - up.y * p.fwd.x
      local shrink = { x = math.max(0.1, h.x - 0.05), y = math.max(0.1, h.y), z = math.max(0.1, h.z - 0.05) }
      local hit = pl.overlapObb({ x = cx, y = cy, z = cz }, shrink, { r = { x = rx, y = ry, z = rz }, u = up, f = p.fwd },
        { skip = function(n) return is_ground(n, p.body) or (ghost_node and n == ghost_node) end })
      ov.key, ov.hit, ov.t = key, hit, now()
    end
    if ov.hit then
      local n = ov.hit.node
      local a = astro()
      r.bad = (a and n and n.id == a.id) and "you're standing where it goes"
        or ("something's in the way" .. (n and n.name and (": " .. tostring(n.name)) or ""))
      return r
    end
  end
  local co = ref("company")
  if q and co and co.afford and not co.afford(q.total) then
    r.bad = string.format("can't afford it: %s", ref("base_economy").money(q.total))
    return r
  end
  return r
end

local function aim()
  if not (camera and camera.screenToRay and raycast) then return nil, "no camera" end
  local pc = ref("planet_camera")
  if pc and pc.mouseLooking and not sim then return "keep" end   -- (RMB held: the cursor is not moving)
  local mx, my = mouse_xy()
  local ok, ox, oy, oz, dx, dy, dz = pcall(camera.screenToRay, mx, my)
  if not ok or not ox then return nil, "no ray" end
  local a = astro()
  local reach = params.reach or 24
  local range = reach + (a and len(a.x - ox, a.y - oy, a.z - oz) or 0)
  local ig = { a }
  local okr, h = pcall(raycast, ox, oy, oz, dx, dy, dz, range, { ignore = ig })
  if not okr or not h then return nil, string.format("no ground within %.0f m of the cursor", reach) end
  if a and len(h.x - a.x, h.y - a.y, h.z - a.z) > reach then return nil, string.format("out of reach (%.0f m)", reach) end
  return h
end

-- ── the ghost ───────────────────────────────────────────────────────────────
ghost_node = nil
local G = { id = nil, body = nil, making = false, color = nil }
local function ghost_drop()
  if ghost_node and ghost_node.valid ~= false then ghost_node:destroy() end
  ghost_node, G.id, G.body, G.color = nil, nil, nil, nil
end
local function ghost_want(id, body)
  if G.id == id and G.body == body and (G.making or (ghost_node and ghost_node.valid ~= false)) then return ghost_node end
  ghost_drop()
  local def = partInfo(id)
  local planet = find and find(body)
  if not (def and planet and spawn) then return nil end
  G.id, G.body, G.making = id, body, true
  local want = id
  spawn(def.prefab, vec3(planet.x, planet.y, planet.z), function(n)
    G.making = false
    if G.id ~= want or not heldPart then n:destroy() return end
    ghost_node = n
    n.visible = false
    pcall(function() n.name = "BuildGhost" end)
  end, { parent = planet, body = false })
  return nil
end
local function ghost_paint()
  if not (heldPart and req and req.pose and open_) then
    if ghost_node and ghost_node.valid ~= false and ghost_node.visible then ghost_node.visible = false end
    return
  end
  local p = req.pose
  local g = ghost_want(heldPart, p.body)
  if not g then return end
  local def = req.def
  local sx, sy, sz = p.x + p.up.x * def.seat, p.y + p.up.y * def.seat, p.z + p.up.z * def.seat
  g:setUp(vec3(p.up.x, p.up.y, p.up.z), vec3(-p.fwd.x, -p.fwd.y, -p.fwd.z))
  g.x, g.y, g.z = sx, sy, sz
  local col = req.bad and RED or GREEN
  if G.color ~= col then
    G.color = col
    local gh = ref("ghost")
    if gh and gh.apply then gh.apply(g, col, req.bad and 0.55 or 0.6) end
  end
  if not g.visible then g.visible = true end
end
-- ── placing ─────────────────────────────────────────────────────────────────
local UNDO = {}        -- { { sid, t } … } newest last (K9's ring replaces this)

-- THE PLACEMENT (K12's shape: a pure function of what, where and who pays).
-- sid = nil: a new structure. pose = { body, x, y, z, up, fwd } (body frame).
-- payer = "money". → sid | nil, why
function place(sid, partId, p, payer)
  local def = partInfo(partId)
  if not def then return nil, "no such part" end
  local E, ST, co = ref("base_economy"), ref("structures"), ref("company")
  if not (E and ST and co) then return nil, "the building rules aren't in this scene" end
  if sid ~= nil then return nil, "joining a structure comes with snapping (step 5)" end
  local q = E.quote(def, section_of(partId), p.body, home_body())
  if q.mode ~= "money" or payer ~= "money" then return nil, q.why or "nothing to pay with" end
  if not co.spend(q.total, E.ledgerWhy(def.label, q)) then return nil, "can't afford it: " .. E.money(q.total) end
  local t = agency_now()
  local dp = ref("deployables")
  local by = member()
  local rec = ST.newRecord(nil, p.body, p.x, p.y, p.z, p.up, p.fwd, partId,
    { by = by, t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, name = def.label,
      paid = { cost = q.cost, ship = q.ship, total = q.total, t = t, supplier = q.supplier, by = by } })
  local id = ST.add(rec)
  if ST.spawnNow then ST.spawnNow(id) end
  local c = ref("crew")
  if c and c.credit and by then pcall(c.credit, by, "built", 1, { body = p.body }) end
  UNDO[#UNDO + 1] = { sid = id, t = t }
  while #UNDO > 16 do table.remove(UNDO, 1) end
  lastPlace = { sid = id, id = partId, total = q.total, cost = q.cost, ship = q.ship, t = t }
  return id, nil, q
end

-- Take the last placement back (Ctrl+Z): a full refund within 60 s. → refund | nil, why
function undo()
  local E, ST, co = ref("base_economy"), ref("structures"), ref("company")
  if not (E and ST and co) then return nil, "nothing to undo" end
  local u = UNDO[#UNDO]
  while u and not ST.get(u.sid) do table.remove(UNDO); u = UNDO[#UNDO] end
  if not u then return nil, "nothing to undo" end
  local rec = ST.get(u.sid)
  local amount, why = E.undoRefund(rec, agency_now())
  if not amount then return nil, why end
  table.remove(UNDO)
  ST.remove(u.sid)
  local label = (rec.bp[1] and partInfo(rec.bp[1].id) or {}).label or "part"
  if co.refund then co.refund(amount, "returned: " .. label .. " (undone within a minute)")
  else co.earn(amount, "returned: " .. label) end
  local c = ref("crew")
  if c and c.credit and rec.by then pcall(c.credit, rec.by, "built", -1) end
  lastUndo = { sid = u.sid, refund = amount, t = agency_now() }
  return amount
end

local function do_place(keep)
  if not (req and heldPart) then return end
  if req.bad then play("denied"); say(req.bad) return end
  local sid, why, q = place(nil, heldPart, req.pose, "money")
  if not sid then play("denied"); say(why or "it wouldn't go there") return end
  play("place", 0.6)
  local E = ref("base_economy")
  say(string.format("%s placed · %s (%s + %s shipping) · Ctrl+Z within a minute returns it", req.def.label,
    E.money(q.total), E.money(q.cost), E.money(q.ship)))
  ov.key, vmemo.key = nil, nil
  if not keep then heldPart = nil end
end

-- A probe's way: put the held part at a world point (this frame's), as a click would.
function placeAt(x, y, z, nx, ny, nz)
  if not heldPart then return nil, "nothing in hand" end
  local p, why = pose({ x = x, y = y, z = z, nx = nx, ny = ny, nz = nz })
  if not p then return nil, why end
  ov.key = nil
  req = validity(heldPart, p)
  if req.bad then return nil, req.bad end
  local sid, why2 = place(nil, heldPart, p, "money")
  return sid, why2
end

-- ── the hint line (item_hand shows it under the belt: items.lua hintFrom) ──
function hintLine()
  if not open_ then return "Build Kit  ·  B opens it" end
  local keys = (collapsed and "B unfolds the parts" or "B folds the parts") .. "  ·  Esc " .. (heldPart and "drops the part" or "closes the kit") .. "  ·  Ctrl+Z undo (60 s)"
  if not heldPart then return "Build Kit  ·  pick a part from the column  ·  RMB held looks round  ·  " .. keys end
  if not req then return string.format("%s  ·  %s  ·  %s", partInfo(heldPart).label, aim_why or "aim at the ground", keys) end
  if req.bad then return string.format("%s  ·  %s  ·  RMB tap drops it", req.def.label, req.bad) end
  local E = ref("base_economy")
  local q = req.quote
  return string.format("%s  ·  LMB place for %s (%s + %s shipping)  ·  Shift+LMB keeps one  ·  RMB tap drops  ·  %s",
    req.def.label, E.money(q.total), E.money(q.cost), E.money(q.ship), keys)
end
aim_why = nil

-- ── the driver ──────────────────────────────────────────────────────────────
local function set_open(on)
  if on == open_ then return end
  open_ = on
  if on then
    collapsed = false
  else
    heldPart, req = nil, nil
    ghost_drop()
  end
  cat_show(on)
end
function open()
  local H = ref("item_hand")
  if not isEngineer() then return false, "Build Kit: Engineers only" end
  if not has_kit() then return false, "no Build Kit in the pack" end
  if not kit_in_hand() and H and H.hold then
    local ok, why = H.hold(KIT)
    if not ok then return false, why end
  end
  return true
end
function close()
  local H = ref("item_hand")
  if kit_in_hand() and H and H.hold then H.hold(nil) end
  set_open(false)
end

local rmb = { down = false, t = 0, x = 0, y = 0 }
-- The right button is ours while a part is in hand (and a moment after a tap
-- dropped it): context_menu asks, so the tap doesn't also open a menu.
local rmb_own_t = -10
function ownsRmb() return open_ and (heldPart ~= nil or now() - rmb_own_t < 0.3) end
local lmb_was = false

function start(node)
  open_, heldPart, req = false, nil, nil
end

local closed_t = -10
local DIGITS = { "b", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
function update(node, dt)
  issue_tick()
  -- Closed, the kit costs one look a fifth of a second (or on a belt key):
  -- item_hand.held() walks the pack.
  if not open_ then
    local key = false
    for _, k in ipairs(DIGITS) do if input.pressed(k) then key = true break end end
    if not key and now() - closed_t < 0.2 then return end
    closed_t = now()
  end
  local why = blocked()
  local want = why == nil and kit_in_hand() and isEngineer()
  gate = why or (want and "open" or "closed")
  if not want and open_ then set_open(false) end
  -- B: take the kit out / fold the column (on foot, not typing, nothing else up)
  if why == nil and not typing() and input.pressed("b") then
    if not open_ then
      local ok, w = open()
      if not ok then play("denied"); say(w) end
      want = ok and kit_in_hand() and isEngineer()
    else
      collapsed = not collapsed
    end
  end
  if want and not open_ then set_open(true) end
  if not open_ then return end
  cat_show(true)
  -- (planet_camera keeps third person and lets go of shift-lock while isOpen())
  -- Esc: the part in hand first, then the kit
  if input.pressed("escape") then
    escTakenAt = now()
    if heldPart then heldPart = nil else close() return end
  end
  -- Ctrl+Z
  if input.key("ctrl") and input.pressed("z") and not typing() then
    local amt, w = undo()
    if amt then play("undo", 0.6); say(string.format("returned · %s back", ref("base_economy").money(amt)))
    else play("denied"); say(w) end
  end
  -- RMB: a tap drops the ghost; held, the camera looks round
  local r_down = input.button and input.button(1) == true
  if r_down and not rmb.down then rmb.t = now(); rmb.x, rmb.y = mouse_xy() end
  if not r_down and rmb.down and now() - rmb.t < 0.25 then heldPart = nil end
  rmb.down = r_down
  if heldPart then rmb_own_t = now() end
end

function lateUpdate(node, dt)
  if not open_ then ghost_paint() return end
  if heldPart then
    local h, w = aim()
    if h == "keep" then
      -- (held still under a held RMB)
    elseif h then
      local p, pw = pose(h)
      if p then
        -- judged again only when the ghost has moved 2 cm or turned, or
        -- every quarter second (money, a crate rolled in)
        local key = string.format("%s|%s|%.2f|%.2f|%.2f|%.2f|%.2f", heldPart, p.body, p.x, p.y, p.z, p.fwd.x, p.fwd.z)
        if key ~= vmemo.key or now() - vmemo.t > 0.25 or not req then
          req = validity(heldPart, p)
          vmemo.key, vmemo.t = key, now()
        else
          req.pose = p
        end
        aim_why = nil
      else req = nil; aim_why = pw end
    else
      req, aim_why = nil, w
    end
  else
    req = nil
  end
  ghost_paint()
  -- LMB (an edge, off the panel and the HUD's buttons)
  local l = (sim and sim.lmb) or (input.button and input.button(0) == true)
  if l and not lmb_was and heldPart and not over_panel() and not typing() then
    local shift = (sim and sim.shift) or input.key("shift")
    do_place(shift == true)
  end
  lmb_was = l == true
end
