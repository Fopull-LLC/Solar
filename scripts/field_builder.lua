-- FIELD BUILDER — the Engineer's build mode on foot (deep-space addendum K1–K10,
-- K13, N1; docs/base-building.md). The VAB, but you stand in the world and
-- the craft is the ground: the same parts column, a ghost on the ground under
-- the cursor, a click to buy, truck out and set the part down.
--
--   THE KIT     the Build Kit (items.lua `buildkit`), a belt item every
--               Engineer is issued (once per member). Take it out with its
--               number key or B; the cursor is free while it is up (the
--               camera leaves first person and shift-lock; RMB held still
--               looks round, WASD still walks). B again folds the parts column
--               to a 36 px tab and back; Esc drops the part in hand, then
--               closes the kit; H or another number key puts it away.
--               Non-Engineers have no kit: B says so.
--   THE PANEL   catalog_panel.lua re-hosted (a FieldCatalogue node spawned
--               under the HUD while the kit is up, destroyed when it closes):
--               this script is its host (the dozen methods below).
--   THE GHOST   the part's own prefab, spawned once per pick without its
--               bodies (spawn opts body = false: no collider, no physics),
--               parented to the planet, and made a hologram by ghost.apply
--               (green: it can go there; red: it can't, with the reason on the
--               hint line). A footing under it shows as a second hologram.
--   THE AIM     a ray through the cursor (camera.screenToRay) in lateUpdate,
--               after the camera has placed itself for the frame, against
--               terrain and colliders, at most 24 m from the Engineer. The hit
--               is kept in its planet's frame at once.
--   SNAPPING    (K5, base_snap.lua) a plate beside a plate takes the free edge
--               slot nearest the cursor; a shed or hab aimed at a plate stands
--               on its deck, square to it; anything else on the ground is a
--               new structure on a 0.5 m grid square to the nearest structure
--               (or the spaceport's layout). Shift frees grid and steps.
--   ROTATE      (K6) scroll turns the part in hand 15° (Shift: 5°), R a
--               quarter turn, PgUp / PgDn raise it on a taller footing (0–2 m),
--               Backspace resets both. (Base parts stand upright: pitch and
--               roll keys come with parts that can lie down.)
--   THE GROUND  (K7) the terrain under a ground part is sampled; up to the
--               part's `grade` it is levelled to the part's base and a cast
--               footing fills where it falls away; past that it is refused.
--   PLACE       LMB: valid → charged (N1: price + 10 % + $50 shipping, and
--               the footing's concrete, at placement), a STRUCTURE part
--               written (structures.lua), the ground levelled, the member
--               credited one "built". Shift+LMB keeps a copy in hand. RMB
--               tapped drops the ghost.
--   UNDO        (K9) Ctrl+Z / Ctrl+Shift+Z (or Ctrl+Y) walk a builder_history
--               ring of placements and removals; a step older than 60 s is
--               refused ("deconstruct it instead"). An undone placement is a
--               full refund; an undone removal puts the parts back and takes
--               the refund back.
--   DECONSTRUCT (K10) RMB on a placed part (the context menu) → Deconstruct,
--               3 s, Engineers only. What stands on its deck comes down with
--               it. Refund: base_economy.deconstructRefund (within 60 s all of
--               it, later the price: the fee and footing are kept).
--
-- Gated: the active member is an Engineer (crew.hasRole), on foot, on a world
-- (EVA building is K11), with no other panel up. Off the home world nothing is
-- placed yet (materials and the Fabricator are step 13): the card says why.
--
-- THE HOOKS: `pose(hit)` is the one place a hit becomes a pose (snapping);
-- `validity(id, pose)` the one place a placement is judged; `place(sid,
-- partId, pose, payer)` the placement (K12's shape: sid = the structure it
-- joins or nil); `deconstruct(sid, uid)` the removal.
--
-- Probes: isOpen(), open(), close(), pick(id), req, lastPlace, lastUndo,
-- lastDecon, placeAt(x, y, z), undo(), redo(), deconstruct(sid, uid),
-- history(), sim = { lmb, shift, mouse = {x, y} }, yawOffset, raise.

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
lastPlace = nil       -- { sid, uid, id, total, t }
lastUndo = nil        -- { sid, refund, t }
lastDecon = nil       -- { sid, uids, refund, t }
gate = "starting up"
escTakenAt = -1
sim = nil             -- probes: { lmb = bool, shift = bool, mouse = {x, y} }
wantsScroll = false   -- planet_camera: the wheel turns the part, not the view
yawOffset = 0.0       -- the turn dialled (rad)
raise = 0.0           -- the stilts dialled (m)

local KIT = "buildkit"
VEIN_CLEAR = 30        -- M8: no building this close to a vein being mined (m)
local GREEN, RED = { 0.30, 0.95, 0.65 }, { 1.0, 0.28, 0.20 }
local UNDO_RING = 50

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
local function money(v) local E = ref("base_economy"); return E and E.money(v) or ("$" .. tostring(v)) end

-- ── who may build ───────────────────────────────────────────────────────────
local function member() local c = ref("crew"); return c and c.activeId and c.activeId() or nil end
function isEngineer(id)
  local c = ref("crew")
  if not (c and c.hasRole) then return false end
  local ok, yes = pcall(c.hasRole, id or member(), "engineer")
  return ok and yes == true
end
local function has_kit() local V = ref("inventory"); return V and V.itemCount and V.itemCount("astro", KIT) > 0 end

-- THE ISSUE: every Engineer gets one Build Kit, once (a kit left in a locker
-- stays there), once the kit is unlocked (M3: the Relay Network's first goal,
-- 10 % of the ground linked) and the next time they are at the base (in it, or
-- on foot within 400 m of it). Checked every few seconds: hires, retrains and
-- old saves. (A save whose Engineers already had one keeps it.)
function kitUnlocked()
  local rs = ref("research")
  if rs and rs.isUnlocked then return rs.isUnlocked(KIT) == true end
  return true
end
local function at_base(r)
  if r.status ~= "afoot" then return r.status == "base" or r.status == nil end
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if not fp then return false end
  -- (the one walking: where the walker is this frame, not the roster's last note)
  local a = astro()
  local b = space and space.body and space.body(fp.body)
  if a and b and r.id == member() then
    if space.dominant(a.x, a.y, a.z) ~= fp.body then return false end
    return len(a.x - b.x - fp.x, a.y - b.y - fp.y, a.z - b.z - fp.z) <= 400
  end
  if not (r.body == fp.body and r.x and r.y and r.z) then return false end
  return len(r.x - fp.x, r.y - fp.y, r.z - fp.z) <= 400
end
local issue_t = -10
local function issue_tick()
  if now() - issue_t < 3.0 then return end
  issue_t = now()
  local c, V = ref("crew"), ref("inventory")
  if not (c and c.roster and V and V.addItem and V.itemCount) then return end
  -- M3: the kit is the Relay Network's 10 % unlock (research `buildkit`):
  -- before it nobody is issued one; after it every Engineer is, at the base
  if not kitUnlocked() then return end
  for _, r in ipairs(c.roster()) do
    if r.status ~= "dead" and isEngineer(r) and at_base(r) then
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
function isCollapsed() return collapsed end
function unfold() collapsed = false end
-- THE PREVIEW STAND rides with the crew, 2.4 km up its frame, on the
-- `offstage` layer the main camera never draws (planet_camera.cullBase), as
-- lab_talk's stand does. (Step 4 hid it INSIDE the planet on `viewmodel`;
-- the live plate drew it, but camera.captureTexture renders through a camera
-- with every draw on — terrain, fog, sky — whatever its setCamera{terrain =
-- false, fog = false} says, so down there the 64 px card icons came out as
-- bare fog-coloured sky. Up here those draws find nothing to hide the part
-- behind. NOTES: the engine card proposal.)
function previewLayer() return "offstage", 5 end
local pv_frame, pv_making = nil, false
function frameNodeOrNil()
  if pv_frame and pv_frame.valid ~= false then return pv_frame end
  local a = astro()
  if a and createNode and not pv_making then
    pv_making = true
    createNode("FieldPreviewFrame", a, function(n) pv_making = false; pv_frame = n; n.x, n.y, n.z = 0, 0, 0 end)
  end
  return nil
end
-- The parts column: the VAB's left column, below the HUD's top-left chips.
function layout(W, H) return { W = W, H = H, left = { x = 8, y = 112, w = 228, h = math.max(240, H - 252) } } end
local function section_of(id)
  for _, s in ipairs(catalogue()) do for _, x in ipairs(s.ids) do if x == id then return s.title end end end
  return nil
end
local function quote_of(id, footVol)
  local E = ref("base_economy")
  local def = partInfo(id)
  if not (E and def) then return nil end
  local a = astro()
  local body = a and space.dominant(a.x, a.y, a.z) or home_body()
  return E.quote(def, section_of(id), body, home_body(), footVol)
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
  -- (a BASE part behind a craft part's research: the Isotope Skid's cells)
  local rs = ref("research")
  if rs and rs.isUnlocked and not rs.isUnlocked(id) then
    play("denied"); say((rs.labelOf and rs.labelOf(id) or id) .. ": " .. tostring(rs.lockLine and rs.lockLine(id) or "locked"))
    return false
  end
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
    if cat.node and cat.node.valid ~= false then return end
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
  local cp = panel
  if cp and cp.ownsMouse then local ok, r = pcall(cp.ownsMouse); return ok and r == true end
  return false
end
local function typing()
  local f = ui and ui.focused and ui.focused()
  return f ~= nil and (f.name == "FieldPartSearch" or f.name == "FieldBaseName")
end
-- A new base's name field is up (base_tower.lua): the kit's keys and clicks wait.
local function naming()
  local bt = ref("base_tower")
  return bt ~= nil and bt.prompting ~= nil and bt.prompting() == true
end

-- ── the aim and the pose ────────────────────────────────────────────────────
local function mouse_xy()
  if sim and sim.mouse then return sim.mouse[1], sim.mouse[2] end
  return input.mouse()
end
local function shift_held() return (sim and sim.shift) or (input and input.key and input.key("shift")) or false end

local function is_ground(n, bname)
  if not n then return true end
  if n.name == bname then return true end
  local ok, t = pcall(function() return n.terrain end)
  return ok and t ~= nil and t ~= false
end

-- The spaceport's layout as a frame (the ground grid with no structure near).
local layout_ref = { F = nil, fr = nil }
local function layout_frame(bname)
  local bf, SN = ref("base_facilities"), ref("base_snap")
  local F = bf and bf.F
  if not (F and SN and bf.baseBody == bname) then return nil end
  if layout_ref.F ~= F then
    layout_ref.F = F
    layout_ref.fr = SN.frameOf({ x = F.c.x * F.R, y = F.c.y * F.R, z = F.c.z * F.R, ux = F.c.x, uy = F.c.y, uz = F.c.z,
                                 fx = F.ev.x, fy = F.ev.y, fz = F.ev.z })
  end
  return layout_ref.fr
end

-- The parts round a point (structures' cell index), kept while the cursor
-- stays within 0.5 m and nothing was built or taken down.
local near_memo = { key = nil, list = nil }
local function near_parts(ST, bname, x, y, z, rad)
  local key = string.format("%s|%d|%d|%d|%d", bname, math.floor(x * 2), math.floor(y * 2), math.floor(z * 2), ST.version or 0)
  if near_memo.key ~= key then near_memo.key, near_memo.list = key, ST.partsNear(bname, x, y, z, rad) end
  return near_memo.list
end

-- A hit → the pose the held part takes there (K5 snapping, K6 turns).
-- → pose { body, x, y, z (its ground point, body frame), up, fwd, mode,
--          sid (the structure it joins) | nil, lx, ly, lz, yaw (in it),
--          anchor, hitRec, hitPart, nx, ny, nz, node, wx, wy, wz } | nil, why
function pose(hit, id)
  id = id or heldPart
  local bname = space.dominant(hit.x, hit.y, hit.z)
  local b = bname and space.body(bname)
  if not b then return nil, "not on a world" end
  local x, y, z = hit.x - b.x, hit.y - b.y, hit.z - b.z
  local ux, uy, uz = norm(x, y, z)
  local a = astro()
  local tx, ty, tz = 0, 0, 1
  if a then tx, ty, tz = a.x - hit.x, a.y - hit.y, a.z - hit.z end
  local def = id and partInfo(id)
  local ST, SN = ref("structures"), ref("base_snap")
  local hrec, hpart = nil, nil
  if hit.node and ST and ST.partOfNode then hrec, hpart = ST.partOfNode(hit.node) end
  local p
  if def and SN and ST then
    local s = SN.snap({ def = def, P = { x = x, y = y, z = z }, U = { x = ux, y = uy, z = uz }, toward = { x = tx, y = ty, z = tz },
      hit = hrec and { rec = hrec, part = hpart } or nil, near = near_parts(ST, bname, x, y, z, SN.NEAR_R),
      defs = partInfo, free = shift_held(), yawOff = yawOffset, ref = layout_frame(bname) })
    p = { body = bname, x = s.x, y = s.y, z = s.z, up = s.up, fwd = s.fwd, mode = s.mode, sid = s.rec and s.rec.id or nil,
          lx = s.lx, ly = s.ly, lz = s.lz, yaw = s.yaw, anchor = s.anchor }
  else
    -- (no rulebook: step 4's pose, the front toward the Engineer)
    local d = tx * ux + ty * uy + tz * uz
    local fx, fy, fz = norm(tx - ux * d, ty - uy * d, tz - uz * d)
    p = { body = bname, x = x, y = y, z = z, up = { x = ux, y = uy, z = uz }, fwd = { x = fx, y = fy, z = fz }, mode = "free" }
  end
  p.hitRec, p.hitPart = hrec, hpart
  p.nx, p.ny, p.nz, p.node = hit.nx or ux, hit.ny or uy, hit.nz or uz, hit.node
  -- (wx, wy, wz: the pose's ground point in this frame's world, for this
  -- frame's physics queries only: never kept past the frame)
  p.wx, p.wy, p.wz = b.x + p.x, b.y + p.y, b.z + p.z
  return p
end

-- The part's own axes at a pose: right, up, front (body-frame vectors).
local function axes(p)
  local U, F = p.up, p.fwd
  return { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }, U, F
end

-- The ground under a ground part's footprint: heights (m along up from the
-- pose's ground point, + above) at base_snap.footPoints, by terrain rays.
local function sample_ground(def, p)
  local SN = ref("base_snap")
  local b = space.body(p.body)
  if not (SN and b) then return nil end
  local R, U, F = axes(p)
  local cast = (terrain and terrain.raycast) and function(ox, oy, oz, dx, dy, dz, d)
    local h = terrain.raycast(vec3(ox, oy, oz), vec3(dx, dy, dz), d)
    return h and h.distance
  end or function(ox, oy, oz, dx, dy, dz, d)
    local ok, h = pcall(raycast, ox, oy, oz, dx, dy, dz, d, { ignore = astro() })
    return ok and h and len(h.x - ox, h.y - oy, h.z - oz) or nil
  end
  local top = (def.grade or 2) + 2.5
  local out = {}
  for i, q in ipairs(SN.footPoints(def, 0, 0, 0, 0.10)) do
    local ox = b.x + p.x + R.x * q.x + F.x * q.z + U.x * top
    local oy = b.y + p.y + R.y * q.x + F.y * q.z + U.y * top
    local oz = b.z + p.z + R.z * q.x + F.z * q.z + U.z * top
    local d = cast(ox, oy, oz, -U.x, -U.y, -U.z, 2 * top + 1)
    out[i] = d and (top - d) or false
  end
  return out
end

-- THE ONE PLACE a placement is judged. → req { id, def, pose, quote, plan
-- (the ground: base_snap.foundation), base (m the part sits over the pose's
-- ground point), bad = the reason or nil }
local ov = { key = nil, hit = nil, t = -10 }
local vmemo = { key = nil, t = -10 }   -- the last judged pose (lateUpdate)
function validity(id, p)
  local def = partInfo(id)
  local r = { id = id, def = def, pose = p, base = 0 }
  if not def then r.bad = "no such part" return r end
  local SN = ref("base_snap")
  local q0 = quote_of(id)
  r.quote = q0
  local up = p.up
  if q0 and q0.mode == "away" then r.bad = q0.why return r end
  -- reach: the snapped spot, not only the cursor's
  local a = astro()
  local reach = params.reach or 24
  if a and p.wx and len(p.wx - a.x, p.wy - a.y, p.wz - a.z) > reach + 2 then
    r.bad = string.format("out of reach (%.0f m)", reach) return r
  end
  -- the ray stopped on something: a placed part is snapping's, anything else
  -- (a crate, a facility) is in the way
  local mode = p.mode or "free"
  if p.hitRec and mode ~= "edge" and mode ~= "deck" then
    local hd = partInfo(p.hitPart.id) or {}
    if def.tile and hd.tile == def.tile then r.bad = "no free edge on that " .. tostring(hd.label) .. " there"
    elseif def.onDeck and not hd.deck then r.bad = "the " .. tostring(hd.label) .. " has no deck to stand on"
    else r.bad = string.format("on the %s: a %s goes on the ground%s", tostring(hd.label), def.label,
      def.tile and " or beside another" or "") end
    return r
  end
  if not p.hitRec and p.node and not is_ground(p.node, p.body) then
    local n = p.node
    local nm = tostring(n.name or "something")
    if nm:match("^Wall %d+$") or nm:match("^Shell") then
      local okp, par = pcall(function() return n.parent end)
      if okp and par and par.name then nm = tostring(par.name) end
    end
    r.bad = "on the " .. nm
    return r
  end
  if mode ~= "deck" then
    local slope = p.nx * up.x + p.ny * up.y + p.nz * up.z
    if mode ~= "edge" and slope < (def.slope or 0.6) then
      r.bad = string.format("too steep for a %s (%.0f°)", def.label, math.deg(math.acos(math.max(-1, math.min(1, slope))))) return r
    end
  end
  -- THE GROUND (K7): standing on a deck, or levelled with a footing
  if mode == "deck" then
    local ST = ref("structures")
    local rec = ST and ST.get(p.sid)
    if not (SN and rec) then r.bad = "that structure is gone" return r end
    local ok, n = SN.supported(rec, partInfo, def, p.lx, p.ly, p.lz, p.yaw)
    if ok < n then
      r.bad = string.format("hangs off the deck (%d of %d points unsupported): set a plate beside it", n - ok, n)
      return r
    end
  elseif SN then
    local hs = sample_ground(def, p)
    local plan = hs and SN.foundation(def, hs, mode == "edge" and 0 or nil, mode ~= "edge" and raise or 0)
    if not plan then r.bad = "can't read the ground here" return r end
    r.plan = plan
    if not plan.ok then r.bad = plan.why return r end
    r.base = plan.base
    if plan.vol and plan.vol > 0 then r.quote = quote_of(id, plan.vol) end
  end
  local bx, by, bz = p.wx + up.x * r.base, p.wy + up.y * r.base, p.wz + up.z * r.base
  local cl = ref("climate")
  local dep = cl and cl.seaDepth and cl.seaDepth(bx, by, bz)
  if dep and dep > 0.05 then r.bad = "under water" return r end
  local bf = ref("base_facilities")
  if bf and bf.keepClear and SN then
    local R, _, F = axes(p)
    for _, c in ipairs({ { 0, 0 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
      local kx, kz = c[1] * def.half.x, c[2] * def.half.z
      local ok, kc = pcall(bf.keepClear, p.body, p.x + R.x * kx + F.x * kz, p.y + R.y * kx + F.y * kz, p.z + R.z * kx + F.z * kz)
      if ok and kc then r.bad = "on the spaceport's ground: build out past its paving" return r end
    end
  end
  -- M8: not within 30 m of a vein being mined (one a cut has taken ore from,
  -- or whose outcrops were broken: mineral_field.workedVeinNear)
  local mf = ref("mineral_field")
  if mf and mf.workedVeinNear then
    local ok, v, d = pcall(mf.workedVeinNear, bx, by, bz, VEIN_CLEAR + math.max(def.half.x or 0, def.half.z or 0))
    if ok and v then
      r.bad = string.format("%.0f m from a %s vein being mined: build %d m clear of it", d or 0, tostring(v.ore or "mined"), VEIN_CLEAR)
      return r
    end
  end
  -- a part's own rules (its parts_base `script`: a tower stands 1 km from the next)
  if def.script then
    local sc = ref(def.script)
    if sc and sc.placeWhy then
      local ok, why = pcall(sc.placeWhy, id, def, p)
      if ok and why then r.bad = why return r end
    end
  end
  -- something in the way (placement.overlapObb; cached while the ghost holds still)
  local pl = ref("placement")
  if pl and pl.overlapObb and def.half then
    local key = string.format("%s|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f", id, p.x, p.y, p.z, p.fwd.x, p.fwd.z, r.base)
    if key ~= ov.key or now() - ov.t > 0.5 then
      local h = def.half
      local lift = 0.25
      local cx, cy, cz = bx + up.x * (h.y + lift), by + up.y * (h.y + lift), bz + up.z * (h.y + lift)
      local R = axes(p)
      local shrink = { x = math.max(0.1, h.x - 0.05), y = math.max(0.1, h.y), z = math.max(0.1, h.z - 0.05) }
      local hit = pl.overlapObb({ x = cx, y = cy, z = cz }, shrink, { r = R, u = up, f = p.fwd },
        { skip = function(n) return is_ground(n, p.body) or (ghost_node and n == ghost_node) end })
      ov.key, ov.hit, ov.t = key, hit, now()
    end
    if ov.hit then
      local n = ov.hit.node
      local ST = ref("structures")
      local orec, opart = nil, nil
      if n and ST and ST.partOfNode then orec, opart = ST.partOfNode(n) end
      r.bad = (a and n and n.id == a.id) and "you're standing where it goes"
        or (opart and ("the " .. tostring((partInfo(opart.id) or {}).label) .. " is in the way"))
        or (n and n.name == "CrewBody" and "someone is standing where it goes")
        or ("something's in the way" .. (n and n.name and (": " .. tostring(n.name)) or ""))
      return r
    end
  end
  local co = ref("company")
  if r.quote and co and co.afford and not co.afford(r.quote.total) then
    r.bad = string.format("can't afford it: %s", money(r.quote.total))
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
  local okr, h = pcall(raycast, ox, oy, oz, dx, dy, dz, range, { ignore = { a } })
  if not okr or not h then return nil, string.format("no ground within %.0f m of the cursor", reach) end
  if a and len(h.x - a.x, h.y - a.y, h.z - a.z) > reach then return nil, string.format("out of reach (%.0f m)", reach) end
  return h
end

-- ── the ghost ───────────────────────────────────────────────────────────────
ghost_node = nil
ghost_foot = nil
local G = { id = nil, body = nil, making = false, color = nil, fcolor = nil, fmaking = false, fbody = nil }
local function ghost_drop()
  if ghost_node and ghost_node.valid ~= false then ghost_node:destroy() end
  if ghost_foot and ghost_foot.valid ~= false then ghost_foot:destroy() end
  ghost_node, ghost_foot, G.id, G.body, G.color, G.fcolor, G.fbody = nil, nil, nil, nil, nil, nil, nil
end
local function ghost_want(id, body)
  if G.id == id and G.body == body and (G.making or (ghost_node and ghost_node.valid ~= false)) then return ghost_node end
  if ghost_node and ghost_node.valid ~= false then ghost_node:destroy() end
  ghost_node, G.color = nil, nil
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
-- The footing's hologram: one unit cube, scaled to the footing.
local function foot_want(body)
  if G.fbody == body and (G.fmaking or (ghost_foot and ghost_foot.valid ~= false)) then return ghost_foot end
  if ghost_foot and ghost_foot.valid ~= false then ghost_foot:destroy() end
  ghost_foot, G.fcolor = nil, nil
  local planet = find and find(body)
  if not (planet and createNode) then return nil end
  G.fbody, G.fmaking = body, true
  createNode("BuildGhostFooting", planet, function(n)
    G.fmaking = false
    if not heldPart then n:destroy() return end
    pcall(function() n:setPrimitive("Cube", { 0.6, 0.6, 0.6 }) end)
    n.visible = false
    ghost_foot = n
  end)
  return nil
end
local function ghost_paint()
  if not (heldPart and req and req.pose and open_) then
    if ghost_node and ghost_node.valid ~= false and ghost_node.visible then ghost_node.visible = false end
    if ghost_foot and ghost_foot.valid ~= false and ghost_foot.visible then ghost_foot.visible = false end
    return
  end
  local p = req.pose
  local g = ghost_want(heldPart, p.body)
  local def = req.def
  local col = req.bad and RED or GREEN
  local gh = ref("ghost")
  local base = req.base or 0
  if g then
    local s = def.seat + base
    g:setUp(vec3(p.up.x, p.up.y, p.up.z), vec3(-p.fwd.x, -p.fwd.y, -p.fwd.z))
    g.x, g.y, g.z = p.x + p.up.x * s, p.y + p.up.y * s, p.z + p.up.z * s
    if G.color ~= col then
      G.color = col
      if gh and gh.apply then gh.apply(g, col, req.bad and 0.55 or 0.6) end
    end
    if not g.visible then g.visible = true end
  end
  local ft = req.plan and req.plan.footing
  if ft then
    local f = foot_want(p.body)
    if f then
      local c = base - ft.d / 2 - 0.02
      f:setUp(vec3(p.up.x, p.up.y, p.up.z), vec3(-p.fwd.x, -p.fwd.y, -p.fwd.z))
      f.x, f.y, f.z = p.x + p.up.x * c, p.y + p.up.y * c, p.z + p.up.z * c
      f.scale_x, f.scale_y, f.scale_z = 2 * ft.hx, ft.d, 2 * ft.hz
      if G.fcolor ~= col then
        G.fcolor = col
        if gh and gh.apply then gh.apply(f, col, 0.35) end
      end
      if not f.visible then f.visible = true end
    end
  elseif ghost_foot and ghost_foot.valid ~= false and ghost_foot.visible then
    ghost_foot.visible = false
  end
end

-- ── the ground work (K7) ────────────────────────────────────────────────────
-- Level the ground under a part to its base: flatten discs in its plane
-- (terrain.sculpt "flatten", the plane named by the part's up), sent now in
-- this frame's world (the engine lands each where it was aimed).
local function level_ground(def, rec, part)
  local SN = ref("base_snap")
  local ST = ref("structures")
  local b = space and space.body and space.body(rec.b)
  if not (SN and ST and b and terrain and terrain.sculpt) then return 0 end
  local gx, gy, gz, U, F = ST.partPose(rec, part, 0)
  local R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }
  local discs, rad = SN.gradeDiscs(def)
  local n = 0
  -- (two passes, as the base's grade: one flatten moves deep fill only part
  -- of the way; the probe measured 0.32 m left after one over a 1.7 m fall)
  for pass = 1, 2 do for _, d in ipairs(discs) do
    local x = b.x + gx + R.x * d.x + F.x * d.z
    local y = b.y + gy + R.y * d.x + F.y * d.z
    local z = b.z + gz + R.z * d.x + F.z * d.z
    local ok = pcall(terrain.sculpt, x, y, z, rad, 1.0, "flatten",
      { normal = vec3(U.x, U.y, U.z), hardness = 0.75, falloff = "smooth" })
    if ok then n = n + 1 end
  end end
  return n
end

-- ── the history (K9) ────────────────────────────────────────────────────────
local HIST = nil
function history()
  if HIST then return HIST end
  local bh = ref("builder_history")
  if bh and bh.newHistory then HIST = bh.newHistory(UNDO_RING) end
  return HIST
end
local function hist_push(e)
  local H = history()
  if H then H:push(e); H:seal() end
end
local function label_of(id) return (partInfo(id) or {}).label or "part" end
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
-- A structure's header (no parts), to put it back after its last part went.
local function header(rec)
  local h = copy(rec)
  h.bp = {}
  return h
end
-- Put parts back into structure `sid` (re-made from `hdr` if it is gone).
local function restore(sid, hdr, list)
  local ST = ref("structures")
  if ST.get(sid) then
    for _, p in ipairs(list) do ST.addPart(sid, copy(p)) end
  else
    local r = copy(hdr)
    r.id = sid
    r.bp = {}
    for _, p in ipairs(list) do r.bp[#r.bp + 1] = copy(p) end
    ST.add(r)
  end
  if ST.spawnNow then ST.spawnNow(sid) end
end

-- ── placing ─────────────────────────────────────────────────────────────────

-- May these parts of structure `sid` come down? A part with behaviour says
-- (its parts_base `script`'s canRemove: a stand with a craft on it can't).
-- → nil (they may) | why
function removalBlocked(sid, uids)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  if not rec then return nil end
  for _, u in ipairs(uids or {}) do
    local p = ST.getPart(sid, u)
    local def = p and partInfo(p.id)
    local s = def and def.script and ref(def.script)
    if s and s.canRemove then
      local ok, yes, why = pcall(s.canRemove, rec, p)
      if ok and yes == false then return why or ("the " .. tostring(def.label) .. " is in use") end
    end
  end
  return nil
end

-- THE PLACEMENT (K12's shape: a function of what, where and who pays).
-- sid = the structure it joins (a snap: p.lx/ly/lz/yaw in its frame) or nil
-- (a new one at p's ground point). p = a pose (body frame); p.base / p.plan
-- = the judged ground (validity's r.base, r.plan) if any. payer = "money".
-- → sid, nil, quote, uid | nil, why
function place(sid, partId, p, payer)
  local def = partInfo(partId)
  if not def then return nil, "no such part" end
  local E, ST, co = ref("base_economy"), ref("structures"), ref("company")
  if not (E and ST and co) then return nil, "the building rules aren't in this scene" end
  local plan = p.plan
  local q = E.quote(def, section_of(partId), p.body, home_body(), plan and plan.vol or 0)
  if q.mode ~= "money" or payer ~= "money" then return nil, q.why or "nothing to pay with" end
  if sid ~= nil and not ST.get(sid) then return nil, "that structure is gone" end
  if not co.spend(q.total, E.ledgerWhy(def.label, q)) then return nil, "can't afford it: " .. E.money(q.total) end
  local t = agency_now()
  local by = member()
  local paid = { cost = q.cost, ship = q.ship, foot = q.foot, total = q.total, t = t, supplier = q.supplier, by = by }
  local base = p.base or 0
  local ft = plan and plan.footing and { d = plan.footing.d, hx = plan.footing.hx, hz = plan.footing.hz } or nil
  local uid
  -- (a part's own fields, as it starts: a stand's deck height)
  local function own(entry)
    for k, v in pairs(def.fields or {}) do if entry[k] == nil then entry[k] = v end end
    return entry
  end
  if sid ~= nil then
    uid = ST.addPart(sid, own({ id = partId, x = p.lx or 0, y = (p.ly or 0) + base, z = p.lz or 0, yaw = p.yaw or 0, paid = paid, ft = ft }))
  else
    local dp = ref("deployables")
    local up = p.up
    local rec = ST.newRecord(nil, p.body, p.x + up.x * base, p.y + up.y * base, p.z + up.z * base, up, p.fwd, partId,
      { by = by, t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, name = def.label, paid = paid })
    rec.bp[1].paid, rec.bp[1].ft = paid, ft
    own(rec.bp[1])
    sid = ST.add(rec)
    uid = 1
    if ST.spawnNow then ST.spawnNow(sid) end
  end
  local rec = ST.get(sid)
  local part = ST.getPart and ST.getPart(sid, uid)
  if plan and plan.level and rec and part then level_ground(def, rec, part) end
  local c = ref("crew")
  if c and c.credit and by then pcall(c.credit, by, "built", 1, { body = p.body }) end
  lastPlace = { sid = sid, uid = uid, id = partId, total = q.total, cost = q.cost, ship = q.ship, foot = q.foot, t = t, mode = p.mode }
  -- the ring: undo = a full refund within the minute; redo = buy it again
  local e = { label = "place " .. def.label, kind = "place", t = t, sid = sid, uid = uid, partId = partId,
              hdr = rec and header(rec) or nil, part = part and copy(part) or nil }
  e.undo = function()
    local held = removalBlocked(e.sid, { e.uid })
    if held then e.res, e.why = nil, held return end
    local amount = math.floor((e.part and e.part.paid and e.part.paid.total) or 0)
    ST.removeParts(e.sid, { e.uid })
    if co.refund then co.refund(amount, "returned: " .. def.label .. " (undone within a minute)") else co.earn(amount, "returned: " .. def.label) end
    if c and c.credit and by then pcall(c.credit, by, "built", -1) end
    e.res = amount
  end
  e.redo = function()
    local q2 = E.quote(def, section_of(partId), e.hdr.b, home_body(), (e.part.ft and plan and plan.vol) or 0)
    if not co.spend(q2.total, E.ledgerWhy(def.label, q2)) then e.res = nil return end
    local t2 = agency_now()
    e.part.paid = { cost = q2.cost, ship = q2.ship, foot = q2.foot, total = q2.total, t = t2, supplier = q2.supplier, by = by }
    e.t = t2
    restore(e.sid, e.hdr, { e.part })
    if c and c.credit and by then pcall(c.credit, by, "built", 1, { body = e.hdr.b }) end
    e.res = q2.total
  end
  hist_push(e)
  return sid, nil, q, uid
end

-- K10: take part `uid` of structure `sid` down, with what stands on its deck.
-- Refund each by base_economy.deconstructRefund. → refund, { uid … } | nil, why
function deconstruct(sid, uid)
  local E, ST, co, SN = ref("base_economy"), ref("structures"), ref("company"), ref("base_snap")
  if not (E and ST and co and SN) then return nil, "the building rules aren't in this scene" end
  local rec = ST.get(sid)
  local part = rec and ST.getPart(sid, uid)
  if not part then return nil, "it's already gone" end
  local uids = { uid }
  for _, u in ipairs(SN.dependents(rec, partInfo, uid)) do uids[#uids + 1] = u end
  local held = removalBlocked(sid, uids)
  if held then return nil, held end
  local t = agency_now()
  local total, full = 0, true
  for _, u in ipairs(uids) do
    local p = ST.getPart(sid, u)
    local amt, rule = E.deconstructRefund(p and p.paid, t)
    total = total + amt
    if rule ~= "full" then full = false end
  end
  local hdr = header(rec)
  local taken = ST.removeParts(sid, uids)
  local saved = {}
  for _, p in ipairs(taken) do saved[#saved + 1] = copy(p) end
  local lbl = label_of(part.id)
  local why = string.format("taken down: %s%s · %s", lbl, #uids > 1 and string.format(" and %d on it", #uids - 1) or "",
    full and "all of it back (within a minute)" or "the price back, fee kept")
  if co.refund then co.refund(total, why) else co.earn(total, why) end
  lastDecon = { sid = sid, uids = uids, refund = total, full = full, t = t }
  local e = { label = "take down " .. lbl, kind = "decon", t = t, sid = sid, hdr = hdr, parts = saved, refund = total }
  e.undo = function()
    if not co.spend(e.refund, "put back: " .. lbl .. " (undone within a minute)") then e.res = nil return end
    restore(e.sid, e.hdr, e.parts)
    e.res = e.refund
  end
  e.redo = function()
    local us = {}
    for _, p in ipairs(e.parts) do us[#us + 1] = p.uid end
    ST.removeParts(e.sid, us)
    co.refund(e.refund, "taken down again: " .. lbl)
    e.t = agency_now()
    e.res = e.refund
  end
  hist_push(e)
  return total, uids
end

-- What deconstructing would return now. → refund, n parts, full
function deconstructQuote(sid, uid)
  local E, ST, SN = ref("base_economy"), ref("structures"), ref("base_snap")
  local rec = ST and ST.get(sid)
  if not (E and rec and SN) then return 0, 0, false end
  local uids = { uid }
  for _, u in ipairs(SN.dependents(rec, partInfo, uid)) do uids[#uids + 1] = u end
  local total, full, t = 0, true, agency_now()
  for _, u in ipairs(uids) do
    local amt, rule = E.deconstructRefund((ST.getPart(sid, u) or {}).paid, t)
    total = total + amt
    if rule ~= "full" then full = false end
  end
  return total, #uids, full
end

-- Ctrl+Z: the newest step in the ring, if it is under a minute old.
-- → amount | nil, why
function undo()
  local E, H = ref("base_economy"), history()
  if not (E and H) then return nil, "nothing to undo" end
  local e = H:top()
  if not e then return nil, "nothing to undo" end
  local age = agency_now() - (e.t or -1e9)
  if age > E.UNDO_SECS + 1e-6 then
    return nil, string.format("%s was %.0f s ago: only the last %d s can be undone (deconstruct it instead)",
      e.label, age, E.UNDO_SECS)
  end
  e.res = nil
  H:undo()
  if e.res == nil then
    H.index = H.index + 1   -- (it could not be undone: the ring stays as it was)
    local w = e.why
    e.why = nil
    return nil, "couldn't undo " .. e.label .. " (" .. (w or "can't afford to put it back") .. ")"
  end
  lastUndo = { sid = e.sid, refund = e.res, kind = e.kind, t = agency_now() }
  return e.res, e
end
-- Ctrl+Shift+Z: the step just undone, again. → amount | nil, why
function redo()
  local H = history()
  if not (H and H:canRedo()) then return nil, "nothing to redo" end
  local e = H.items[H.index + 1]
  e.res = nil
  H:redo()
  if e.res == nil then H.index = H.index - 1 return nil, "couldn't redo " .. e.label .. " (can't afford it)" end
  return e.res, e
end

local function do_place(keep)
  if not (req and heldPart) then return end
  if req.bad then play("denied"); say(req.bad) return end
  local p = req.pose
  p.base, p.plan = req.base, req.plan
  local sid, why, q = place(p.sid, heldPart, p, "money")
  if not sid then play("denied"); say(why or "it wouldn't go there") return end
  play("place", 0.6)
  say(string.format("%s placed · %s (%s + %s shipping%s) · Ctrl+Z within a minute returns it", req.def.label,
    money(q.total), money(q.cost), money(q.ship), (q.foot or 0) > 0 and (" + " .. money(q.foot) .. " footing") or ""))
  ov.key, vmemo.key = nil, nil
  if not keep then heldPart = nil end
end

-- A probe's way: put the held part at a world point (this frame's), as a click would.
function placeAt(x, y, z, nx, ny, nz, node)
  if not heldPart then return nil, "nothing in hand" end
  local p, why = pose({ x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, node = node })
  if not p then return nil, why end
  ov.key = nil
  req = validity(heldPart, p)
  if req.bad then return nil, req.bad end
  p.base, p.plan = req.base, req.plan
  return place(p.sid, heldPart, p, "money")
end

-- ── deconstruct from the context menu (K10) ─────────────────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local def = partInfo(part.id) or {}
  local sid, uid = rec.id, part.uid
  local function ask()
    local amt, n, full = deconstructQuote(sid, uid)
    return string.format("%s back%s%s", money(amt), full and "" or " (fee kept)",
      n > 1 and string.format(" · takes %d part%s with it", n - 1, n > 2 and "s" or "") or "")
  end
  return {
    { id = "bk_what", type = "info", label = def.label or "Part", value = function()
        local r = ST.get(sid)
        return string.format("structure %d · %d part%s", sid, r and #r.bp or 0, (r and #r.bp or 0) == 1 and "" or "s")
      end, group = "Base" },
    { id = "bk_decon", type = "action", label = "Deconstruct", group = "Base", danger = true, value = ask,
      hint = "3 s", enabled = function() return isEngineer() and removalBlocked(sid, { uid }) == nil end,
      why = function() return isEngineer() and (removalBlocked(sid, { uid }) or "in use") or "Engineers only" end,
      job = { secs = 3.0, label = "Taking the " .. tostring(def.label) .. " down",
        check = function()
          if not ST.getPart(sid, uid) then return false, "it's gone" end
          return true
        end,
        tick = function() end,
        done = function()
          local amt, w = deconstruct(sid, uid)
          if ctx and ctx.toast then ctx.toast(amt and string.format("taken down · %s back", money(amt)) or tostring(w), amt == nil) end
          if amt then play("undo", 0.6) end
          return amt ~= nil, w
        end } },
  }, def.label
end
providerFn = provider   -- (probes)
local provider_on = false
local function register_provider()
  if provider_on then return end
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", provider, { id = "field_builder", order = 6 })
    provider_on = true
  end
end

-- ── the hint line (item_hand shows it under the belt: items.lua hintFrom) ──
local MODE_TXT = { edge = "EDGE TO EDGE", deck = "ON THE DECK", grid = "GRID 0.5 m", free = "FREE" }
function hintLine()
  if not open_ then return "Build Kit  ·  B opens it" end
  local keys = (collapsed and "B unfolds the parts" or "B folds the parts") .. "  ·  Esc " .. (heldPart and "drops the part" or "closes the kit") .. "  ·  Ctrl+Z undo"
  if not heldPart then return "Build Kit  ·  pick a part  ·  RMB tap a placed part to take it down  ·  " .. keys end
  local turn = "scroll turns  ·  R quarter  ·  PgUp/PgDn raise  ·  Shift frees"
  if not req then return string.format("%s  ·  %s  ·  %s", partInfo(heldPart).label, aim_why or "aim at the ground", turn) end
  if req.bad then return string.format("%s  ·  %s  ·  RMB tap drops it", req.def.label, req.bad) end
  local q = req.quote
  local extra = {}
  local p = req.pose
  extra[#extra + 1] = MODE_TXT[p.mode or "free"] or ""
  if math.abs(yawOffset) > 1e-3 then extra[#extra + 1] = string.format("%+.0f°", math.deg(yawOffset)) end
  if raise > 1e-3 then extra[#extra + 1] = string.format("raised %.2f m", raise) end
  local pl = req.plan
  if pl and pl.footing then extra[#extra + 1] = string.format("footing %.1f m", pl.footing.d)
  elseif pl and pl.level then extra[#extra + 1] = "levelled" end
  return string.format("%s  ·  %s  ·  LMB place for %s (%s + %s shipping%s)  ·  %s",
    req.def.label, table.concat(extra, " · "), money(q.total), money(q.cost), money(q.ship),
    (q.foot or 0) > 0 and (" + " .. money(q.foot) .. " footing") or "", turn)
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

-- K6: the turn and raise keys, with a part in hand.
local function turn_keys()
  if typing() then return end
  local fine = shift_held()
  local dz = (input.scroll and not over_panel()) and input.scroll() or 0
  local SN = ref("base_snap")
  local step = SN and (fine and SN.YAW_FINE or SN.YAW_STEP) or math.rad(15)
  if dz ~= 0 then yawOffset = SN.wrap(yawOffset + (dz > 0 and step or -step)) end
  if input.pressed("r") then yawOffset = SN.wrap(yawOffset + SN.QUARTER) end
  local rs, rm = SN and SN.RAISE_STEP or 0.25, SN and SN.RAISE_MAX or 2.0
  if input.pressed("pageup") then raise = math.min(rm, raise + rs) end
  if input.pressed("pagedown") then raise = math.max(0, raise - rs) end
  if input.pressed("backspace") then yawOffset, raise = 0, 0 end
end

local closed_t = -10
local DIGITS = { "b", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
function update(node, dt)
  issue_tick()
  register_provider()
  -- Closed, the kit costs one look a fifth of a second (or on a belt key):
  -- item_hand.held() walks the pack.
  if not open_ then
    wantsScroll = false
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
  if naming() then wantsScroll = false return end
  -- (planet_camera keeps third person and lets go of shift-lock while isOpen())
  -- Esc: the part in hand first, then the kit
  if input.pressed("escape") then
    escTakenAt = now()
    if heldPart then heldPart = nil else close() return end
  end
  -- Ctrl+Z / Ctrl+Shift+Z (Ctrl+Y)
  if input.key("ctrl") and not typing() then
    local redo_k = (input.pressed("z") and shift_held()) or input.pressed("y")
    if redo_k then
      local amt, w = redo()
      if amt then play("place", 0.5); say(string.format("redone · %s", w.label)) else play("denied"); say(w) end
    elseif input.pressed("z") then
      local amt, w = undo()
      if amt then
        play("undo", 0.6)
        say(w.kind == "decon" and string.format("put back · %s charged again", money(amt)) or string.format("returned · %s back", money(amt)))
      else play("denied"); say(w) end
    end
  end
  wantsScroll = heldPart ~= nil and not over_panel()
  if heldPart and not input.key("ctrl") then turn_keys() end
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
        local key = string.format("%s|%s|%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.2f", heldPart, p.body, tostring(p.mode), p.x, p.y, p.z,
          p.fwd.x, p.fwd.z, raise)
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
  if l and not lmb_was and heldPart and not over_panel() and not typing() and not naming() then
    do_place(shift_held() == true)
  end
  lmb_was = l == true
end
