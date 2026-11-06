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
-- (sandbox S1: the modular kit)
pitchOff = 0.0        -- Shift+R: quarter turns about the piece's X
rollOff = 0.0         -- T: quarter turns about its Z
storey = 0            -- PgUp / PgDn with a kit piece on a face: storeys (2.4 m) up
sym = nil             -- X: mirror placements { axis = "x"|"z", sid, at } (structure frame)
selection = {}        -- Alt+click: { ["sid:uid"] = { sid, uid } } (copy)
clip = nil            -- Ctrl+C: { parts = { { id, dx, dy, dz, yaw, pitch, roll } … }, label, n }
lastRun = nil         -- a Ctrl+drag run: { n, total, t }
STOREY = 2.4
RUN_CAP = 64

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
-- (S1: the modular kit's sections follow the BASE section, each piece in the
-- material picked; S2: FITTINGS, the VAB parts that work where they're put)
material = "steel"     -- the material the next kit pieces take (M cycles it)
-- (S4: the PAINT and BLUEPRINTS sections are the kit's tools, not parts:
-- "paint:<swatch>" (and paint:pick, the eyedropper; paint:strip) and
-- "bp:<key>" (a saved or stock blueprint; bp:save and bp:import are actions))
local tool_secs = { v = nil, list = nil }
local function tool_sections()
  local BP, KP = ref("blueprints"), ref("kit_paint")
  local v = tostring(BP and BP.version or 0) .. "|" .. tostring(KP ~= nil)
  if tool_secs.v == v and tool_secs.list then return tool_secs.list end
  local out = {}
  if KP and KP.PALETTE then
    local ids = { "paint:pick", "paint:strip" }
    for _, s in ipairs(KP.PALETTE) do ids[#ids + 1] = "paint:" .. s.key end
    out[#out + 1] = { title = "PAINT", ids = ids }
  end
  if BP and BP.all then
    local ids = { "bp:save", "bp:import" }
    for _, e in ipairs(BP.all()) do ids[#ids + 1] = "bp:" .. e.key end
    out[#out + 1] = { title = "BLUEPRINTS", ids = ids }
  end
  tool_secs.v, tool_secs.list = v, out
  return out
end
function catalogue()
  local p = parts()
  local out = {}
  for _, s in ipairs(p and p.catalogue() or {}) do out[#out + 1] = s end
  local K = ref("parts_kit")
  if K and K.catalogue then for _, s in ipairs(K.catalogue(material)) do out[#out + 1] = s end end
  for _, s in ipairs(tool_sections()) do out[#out + 1] = s end
  return out
end
-- A tool's card: { label, desc, cost, tool = "paint" | "bp" | "action" }
local tool_defs = {}
function toolDef(id)
  if type(id) ~= "string" then return nil end
  local kind, key = id:match("^(%a+):(.+)$")
  if kind ~= "paint" and kind ~= "bp" then return nil end
  local BP, KP = ref("blueprints"), ref("kit_paint")
  local ck = id .. "|" .. tostring(BP and BP.version or 0)
  if tool_defs[ck] then return tool_defs[ck] end
  local d
  if kind == "paint" and KP then
    if key == "pick" then d = { label = "Eyedropper", desc = "click a piece to take its colour · I with a paint in hand", tool = "pick", cost = 0 }
    elseif key == "strip" then d = { label = "Strip Paint", desc = "back to the bare material", tool = "paint", paint = nil, strip = true, cost = 0 }
    else
      local s = KP.swatch(key)
      if s then d = { label = s.label, desc = "enamel over the piece's own surface · its wear shows through", tool = "paint", paint = key, cost = KP.PAINT_COST } end
    end
  elseif kind == "bp" and BP then
    if key == "save" then d = { label = "Save as Blueprint", desc = "the Alt-selected pieces, or the structure you stand at", tool = "action", cost = 0 }
    elseif key == "import" then d = { label = "Import a Code", desc = "paste a SOLBP1 code someone shared · or drop a .json on the window", tool = "action", cost = 0 }
    else
      local bp = BP.get(key)
      if bp then
        local b = blueprintBill(bp)
        d = { label = bp.name, tool = "bp", bp = bp, key = key, cost = b.total, bill = b,
              desc = string.format("%d pieces · %.1f t%s", b.n, b.mass, #b.missing > 0 and string.format(" · %d unknown", #b.missing) or "") }
      end
    end
  end
  if d then d.section = kind == "paint" and "PAINT" or "BLUEPRINTS"; d.mass = d.mass or 0; d.id = id end
  tool_defs[ck] = d or false
  return d
end
function partInfo(id)
  local p = parts()
  local d = p and p.partInfo(id) or nil
  if d then return d end
  return toolDef(id) or nil
end
function liveDef(id) return nil end
heldBp = nil          -- (S4) the blueprint card in hand ("bp:<key>"), its clip pasting
function heldId() return heldBp or heldPart end
function holding() return heldPart and "part" or nil end
local function is_tool(id) local d = id and toolDef(id); return d ~= nil and (d.tool == "paint" or d.tool == "pick") end
isTool = is_tool
function researchPending() return false end
subAssemblies = nil
noSubAssy = true
function hint(text, secs) if text then say(text) end end
local panel = nil
function registerPanel(s) panel = s return true end
function previewPrefab(id) local d = partInfo(id); return d and d.prefab or nil end
-- (S4) a tool card's icon: the swatch chip, a blueprint's plan drawing
function iconFor(id)
  local d = toolDef(id)
  if not d then return nil end
  local KP, BP = ref("kit_paint"), ref("blueprints")
  if d.tool == "paint" or d.tool == "pick" then
    return KP and KP.iconOf and KP.iconOf(d.strip and "strip" or (d.tool == "pick" and "pick") or d.paint) or nil
  end
  if d.tool == "bp" then return blueprintIcon(d) end
  return nil
end
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
  -- (S4) the tools: a coat of paint, a blueprint's one bill, the actions
  if def and def.tool == "paint" then return def.strip and "strip" or (creative() and "free" or money(def.cost) .. " a coat"), def.desc end
  if def and def.tool == "pick" then return "pick", def.desc end
  if def and def.tool == "action" then return "…", def.desc end
  if def and def.tool == "bp" then
    local b = def.bill
    return money(b.total), string.format("%d pieces · %.1f t · %s + %s one delivery", b.n, b.mass, money(b.cost), money(b.ship))
  end
  -- (step 8, B9b: a cable is billed by the metre when its run is laid)
  if def and def.cable then
    return string.format("$%g a metre", def.cable.perm or 3),
      string.format("%.1f kg/m · up to %.1f km a run · + shipping", def.cable.kgm or 1.4, (def.cable.max or 1500) / 1000)
  end
  return E.cardLines(quote_of(id))
end
function footText()
  if heldPart and is_tool(heldPart) then return "PAINT — LMB paints · Shift both faces · Ctrl all of a kind · I picks · RMB tap drops" end
  if heldBp then return "BLUEPRINT — LMB builds it (one bill) · R / wheel turns · RMB tap drops" end
  return heldPart and "IN HAND — LMB places · Shift+LMB keeps one · RMB tap drops" or "click a part to hold its ghost · B folds this"
end

-- Take a part in hand (the card click). → ok
function hold(id)
  if not partInfo(id) then return false end
  -- (S4) the tools: paint and the eyedropper in hand; a blueprint as a paste;
  -- the save and import actions run and hold nothing
  local td = toolDef(id)
  if td then
    if td.tool == "action" then
      if id == "bp:save" then saveBlueprint() elseif id == "bp:import" then importBlueprint() end
      return false
    end
    if td.tool == "bp" then return holdBlueprint(td.key) end
    heldBp, pasting = nil, false
    if heldPart ~= id then heldPart = id; play("pick", 0.35) end
    return true
  end
  heldBp = nil
  -- (a BASE part behind a craft part's research: the Isotope Skid's cells)
  local rs = ref("research")
  local d0 = partInfo(id)
  local rid = d0 and d0.vab or id   -- (a VAB part placed live: its own research)
  if rs and rs.isUnlocked and not rs.isUnlocked(rid) then
    play("denied"); say((rs.labelOf and rs.labelOf(rid) or rid) .. ": " .. tostring(rs.lockLine and rs.lockLine(rid) or "locked"))
    return false
  end
  if heldPart ~= id then
    heldPart = id; play("pick", 0.35)
    -- (a cockpit lies on its belly; everything else starts upright)
    pitchOff, rollOff = (d0 and d0.lay) and (math.pi / 2) or 0, 0
  end
  return true
end
function dropHeld() heldPart, heldBp = nil, nil end
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
  return f ~= nil and (f.name == "FieldPartSearch" or f.name == "FieldBaseName" or f.name == "FieldKitText" or f.name == "FieldKitCode")
end
-- A new base's name field is up (base_tower.lua), or the kit's own prompt (a
-- blueprint's name, a sign's words, a code: blueprints.lua): keys and clicks wait.
local function naming()
  local bt, BP = ref("base_tower"), ref("blueprints")
  if BP and BP.prompting and BP.prompting() then return true end
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
  local KS = ref("kit_snap")
  local kf = nil
  if def and def.kit and KS and hrec and not shift_held() then
    kf = KS.face({ def = def, id = id, P = { x = x, y = y, z = z }, N = { x = hit.nx or ux, y = hit.ny or uy, z = hit.nz or uz },
      toward = { x = tx, y = ty, z = tz }, hit = { rec = hrec, part = hpart }, defs = partInfo, yawOff = yawOffset })
  end
  if kf then
    -- (S1: a face snap, then the storeys and the pitch / roll dialled)
    local yaw, pitch, roll = kf.yaw, kf.pitch + pitchOff, rollOff
    -- (S4: T turns a mount — a decal, a sign, a rack — on its own face)
    if def.snap == "mount" and KS.spinPose and math.abs(rollOff) > 1e-6 then yaw, pitch, roll = KS.spinPose(kf.yaw, kf.pitch + pitchOff, rollOff) end
    local lx, ly, lz = kf.lx, kf.ly + storey * STOREY, kf.lz
    local fr = KS.frameOf(hrec)
    local lu, lf = KS.localAxes(yaw, pitch, roll)
    local function bv(v) return { x = fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], y = fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                                  z = fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3] } end
    p = { body = bname, x = fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz, y = fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
          z = fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz, up = bv(lu), fwd = bv(lf), sup = fr.U, mode = "face", sid = hrec.id,
          lx = lx, ly = ly, lz = lz, yaw = yaw, pitch = pitch, roll = roll, anchor = kf.anchor, face = kf.face }
  elseif def and SN and ST then
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
  -- (a kit piece on the ground or a deck, turned in pitch or roll: the record's
  -- frame keeps the radial up, the piece carries the turn)
  if def and def.kit and p.mode ~= "face" then
    p.sup, p.fwd0 = p.up, p.fwd
    if (pitchOff ~= 0 or rollOff ~= 0) and KS then
      local U, F = p.up, p.fwd
      local R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }
      local lu, lf = KS.localAxes(0, pitchOff, rollOff)
      local function bv(v) return { x = R.x * v[1] + U.x * v[2] + F.x * v[3], y = R.y * v[1] + U.y * v[2] + F.y * v[3], z = R.z * v[1] + U.z * v[2] + F.z * v[3] } end
      p.up, p.fwd = bv(lu), bv(lf)
      p.pitch, p.roll = pitchOff, rollOff
    end
  end
  p.nx, p.ny, p.nz, p.node = hit.nx or ux, hit.ny or uy, hit.nz or uz, hit.node
  -- (wx, wy, wz: the pose's ground point in this frame's world, for this
  -- frame's physics queries only: never kept past the frame)
  p.wx, p.wy, p.wz = b.x + p.x, b.y + p.y, b.z + p.z
  return p
end

-- The part's own axes at a pose: right, up, front (body-frame vectors).
local function axes(p)
  local U, F = p.sup or p.up, p.fwd0 or p.fwd
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
    local h, why, dd = terrain.raycast(vec3(ox, oy, oz), vec3(dx, dy, dz), d)
    if h then return h.distance end
    lastRayWhy = tostring(why) .. (dd and string.format(" at %.2f m", dd) or "")
    -- (sandbox S1: a ray that reaches ground the world hasn't made at full
    -- detail yet — stand-in ground round fresh edits and put-away chunks —
    -- answers nil, "unknown", distance. That ground IS there, at that
    -- distance: a stand set down near the hab read "no ground under most of
    -- it" from nine such rays. The distance is the answer.)
    if why == "unknown" and type(dd) == "number" and dd <= d then return dd end
    -- (and the physics ray as the last word: the ground's own collider only,
    -- never a part or a plant)
    local ok, ph = pcall(raycast, ox, oy, oz, dx, dy, dz, d, { ignore = astro() })
    if ok and ph and is_ground(ph.node, p.body) then return len(ph.x - ox, ph.y - oy, ph.z - oz) end
    return nil
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
sampleGround = sample_ground   -- (probes)

-- ── the kit's rules (S1) ────────────────────────────────────────────────────
KIT_WHERE = {
  wall = "aim at a floor's edge, a wall's end or top",
  floor = "aim beside a floor, on a slab, or at a wall's top",
  post = "aim at a top face or a wall's end",
  block = "aim at a floor's or slab's top",
  mount = "aim at any face",
  hab = "aim at a can's end, or a slab's top",
  slab = "beside another slab, or on the ground",
}
-- The sandbox (Creative): no support check.
function creative()
  local co = ref("company")
  return co ~= nil and co.isSandbox ~= nil and co.isSandbox() == true
end
-- The part record a face pose would write (for the records rules).
local function as_part(id, p)
  return { uid = -1, id = id, x = p.lx or 0, y = p.ly or 0, z = p.lz or 0, yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0 }
end
-- A kit piece on another: inside a piece of its structure, or held by nothing
-- (Career). `extra` = parts about to join with it (a paste). → nil | why
function kitWhy(def, p, id, extra)
  local ST, KS = ref("structures"), ref("kit_snap")
  local rec = ST and p.sid and ST.get(p.sid)
  if not (rec and KS) then return "that structure is gone" end
  local np = as_part(id, p)
  local probe = rec
  if extra and #extra > 0 then
    probe = { bp = {} }
    for _, q in ipairs(rec.bp) do probe.bp[#probe.bp + 1] = q end
    for _, q in ipairs(extra) do probe.bp[#probe.bp + 1] = q end
  end
  local o, od = KS.overlapIn(probe, partInfo, np, def)
  if o then return string.format("the %s%s is there", tostring(od and od.label or "part"),
    od and od.matLabel and (" (" .. od.matLabel:lower() .. ")") or "") end
  if not creative() and not KS.supported(probe, partInfo, np, def) then
    return "nothing holds that up: stand it on a floor, a wall or a slab"
  end
  return nil
end
-- Anything that is not its structure inside a face-snapped piece (the crew, a
-- crate, a rover): placement.overlapObb on the piece's own box. → nil | why
local kov = { key = nil, hit = nil, t = -10 }
function kit_obstacle(def, p)
  local pl, ST, KS = ref("placement"), ref("structures"), ref("kit_snap")
  local b = space.body(p.body)
  local rec = ST and ST.get(p.sid)
  if not (pl and pl.overlapObb and KS and b and rec) then return nil end
  local key = string.format("%s|%d|%.2f|%.2f|%.2f|%.2f|%.2f", def.prefab or "", p.sid, p.lx, p.ly, p.lz, p.yaw or 0, p.pitch or 0)
  if key ~= kov.key or now() - kov.t > 0.5 then
    local so = KS.solid(as_part("", p), def)
    local fr = KS.frameOf(rec)
    local my = (so.y0 + so.y1) / 2
    local cx = fr.O.x + fr.R.x * so.x + fr.U.x * my + fr.F.x * so.z
    local cy = fr.O.y + fr.R.y * so.x + fr.U.y * my + fr.F.y * so.z
    local cz = fr.O.z + fr.R.z * so.x + fr.U.z * my + fr.F.z * so.z
    local c, s = math.cos(so.yaw), math.sin(so.yaw)
    local R = { x = fr.R.x * c - fr.F.x * s, y = fr.R.y * c - fr.F.y * s, z = fr.R.z * c - fr.F.z * s }
    local F = { x = fr.F.x * c + fr.R.x * s, y = fr.F.y * c + fr.R.y * s, z = fr.F.z * c + fr.R.z * s }
    local half = { x = math.max(0.03, so.hx - 0.06), y = math.max(0.03, (so.y1 - so.y0) / 2 - 0.06), z = math.max(0.03, so.hz - 0.04) }
    local hit = pl.overlapObb({ x = b.x + cx, y = b.y + cy, z = b.z + cz }, half, { r = R, u = fr.U, f = F },
      { skip = function(n)
          if is_ground(n, p.body) or (ghost_node and n == ghost_node) then return true end
          return ST.partOfNode(n) ~= nil
        end })
    kov.key, kov.hit, kov.t = key, hit, now()
  end
  local h = kov.hit
  if not h then return nil end
  local a = astro()
  local n = h.node
  if a and n and n.id == a.id then return "you're standing where it goes" end
  if n and n.name == "CrewBody" then return "someone is standing where it goes" end
  return "something's in the way" .. (n and n.name and (": " .. tostring(n.name)) or "")
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
  -- J6: building is an Engineer's (the kit already is; a Shield Wall's
  -- placement says so in its own words)
  if not isEngineer() then
    r.bad = def.shield and "Engineers only: a Shield Wall is set by an Engineer" or "Engineers only"
    return r
  end
  local SN = ref("base_snap")
  local q0 = quote_of(id)
  r.quote = q0
  local up = p.sup or p.up
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
  if p.hitRec and mode ~= "edge" and mode ~= "deck" and mode ~= "face" then
    local hd = partInfo(p.hitPart.id) or {}
    if def.kit then r.bad = string.format("no place for a %s on the %s there: %s", def.label, tostring(hd.label),
        KIT_WHERE[def.snap or "block"] or "aim at another face")
    elseif def.tile and hd.tile == def.tile then r.bad = "no free edge on that " .. tostring(hd.label) .. " there"
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
  if mode ~= "deck" and mode ~= "face" then
    local slope = p.nx * up.x + p.ny * up.y + p.nz * up.z
    if mode ~= "edge" and slope < (def.slope or 0.6) then
      r.bad = string.format("too steep for a %s (%.0f°)", def.label, math.deg(math.acos(math.max(-1, math.min(1, slope))))) return r
    end
  end
  -- THE GROUND (K7): standing on a deck, or levelled with a footing
  if mode == "face" then
    -- (S1: a kit piece on another: the records say whether it fits and is held)
    local why = kitWhy(def, p, id)
    if why then r.bad = why return r end
  elseif mode == "deck" then
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
  if mode == "face" then
    -- (a film of paint is never in anyone's way, nor they in its)
    local why = not def.film and kit_obstacle(def, p) or nil
    if why then r.bad = why return r end
  elseif pl and pl.overlapObb and def.half then
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
-- THE PASTE'S COMPOSITE GHOST (S1): one BuildGhost root on the planet with a
-- child hologram per copied piece past the first, posed in the anchor's frame.
local PG = { root = nil, making = false, clip = nil, kids = {}, color = nil }
local function paste_drop()
  if PG.root and PG.root.valid ~= false then PG.root:destroy() end
  PG.root, PG.clip, PG.kids, PG.color, PG.making = nil, nil, {}, nil, false
end
function paste_ghosts(p, col)
  if not (pasting and clip and p) then
    if PG.root then paste_drop() end
    return
  end
  local planet = find and find(p.body)
  if PG.clip ~= clip then
    paste_drop()
    if not (planet and createNode and spawn) then return end
    PG.clip, PG.making = clip, true
    local want = clip
    createNode("BuildGhost", planet, function(root)
      PG.making = false
      if PG.clip ~= want then root:destroy() return end
      PG.root = root
      for i = 2, #want.parts do
        local d = partInfo(want.parts[i].id)
        if d and d.prefab then
          spawn(d.prefab, vec3(planet.x, planet.y, planet.z), function(n)
            if PG.clip ~= want or not (PG.root and PG.root.valid ~= false) then n:destroy() return end
            PG.kids[i] = n
            PG.color = nil
          end, { parent = root, body = false })
        end
      end
    end)
    return
  end
  local root = PG.root
  if not (root and root.valid ~= false) then return end
  local KS, ST = ref("kit_snap"), ref("structures")
  -- the anchor's frame: its structure's, or (a new one on the ground) the pose's own
  local fr, anchor
  if p.mode == "face" then
    local rec = ST and ST.get(p.sid)
    if not (KS and rec) then return end
    fr, anchor = KS.frameOf(rec), { lx = p.lx, ly = p.ly, lz = p.lz, yaw = p.yaw }
  else
    local U, F = p.sup or p.up, p.fwd0 or p.fwd
    local base = (req and req.base) or 0
    fr = { O = { x = p.x + U.x * base, y = p.y + U.y * base, z = p.z + U.z * base }, U = U, F = F,
           R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x } }
    anchor = { lx = 0, ly = 0, lz = 0, yaw = 0 }
  end
  root.x, root.y, root.z = 0, 0, 0
  local gh = ref("ghost")
  for i, n in pairs(PG.kids) do
    if n and n.valid ~= false then
      local e = clip.parts[i]
      local d = partInfo(e.id)
      local cp = clipPose(anchor, e)
      local lu, lf = KS.localAxes(cp.yaw, cp.pitch or 0, cp.roll or 0)
      local function bv(v) return vec3(fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                                       fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3]) end
      local u, f = bv(lu), bv(lf)
      n:setUp(u, vec3(-f.x, -f.y, -f.z))
      local sy = cp.ly + (d and d.seat or 0)
      n.x = fr.O.x + fr.R.x * cp.lx + fr.U.x * sy + fr.F.x * cp.lz
      n.y = fr.O.y + fr.R.y * cp.lx + fr.U.y * sy + fr.F.y * cp.lz
      n.z = fr.O.z + fr.R.z * cp.lx + fr.U.z * sy + fr.F.z * cp.lz
    end
  end
  if PG.color ~= col and gh and gh.apply then PG.color = col; gh.apply(root, col, 0.45) end
end

local function ghost_paint()
  if not (heldPart and req and (req.pose or req.cable) and open_) then
    if PG.root or PG.making then paste_drop() end
    if ghost_node and ghost_node.valid ~= false and ghost_node.visible then ghost_node.visible = false end
    if ghost_foot and ghost_foot.valid ~= false and ghost_foot.visible then ghost_foot.visible = false end
    return
  end
  if req.cable then
    -- (a cable has no ghost: its run is drawn, base_cable.drawPreview)
    if ghost_node and ghost_node.valid ~= false and ghost_node.visible then ghost_node.visible = false end
    if ghost_foot and ghost_foot.valid ~= false and ghost_foot.visible then ghost_foot.visible = false end
    local CB = ref("base_cable")
    if CB and CB.drawPreview then CB.drawPreview() end
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
    local su = p.sup or p.up
    g:setUp(vec3(p.up.x, p.up.y, p.up.z), vec3(-p.fwd.x, -p.fwd.y, -p.fwd.z))
    g.x, g.y, g.z = p.x + su.x * s, p.y + su.y * s, p.z + su.z * s
    if G.color ~= col then
      G.color = col
      if gh and gh.apply then gh.apply(g, col, req.bad and 0.55 or 0.6) end
    end
    if not g.visible then g.visible = true end
  end
  paste_ghosts(p, col)
  local ft = req.plan and req.plan.footing
  if ft then
    local f = foot_want(p.body)
    if f then
      local c = base - ft.d / 2 - 0.02
      local fu, ff = p.sup or p.up, p.fwd0 or p.fwd
      f:setUp(vec3(fu.x, fu.y, fu.z), vec3(-ff.x, -ff.y, -ff.z))
      f.x, f.y, f.z = p.x + fu.x * c, p.y + fu.y * c, p.z + fu.z * c
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
-- (step 8) another script's step in the ring: base_cable's laid cable
function pushHistory(e) hist_push(e) end
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
function place(sid, partId, p, payer, opts)
  local def = partInfo(partId)
  if not def then return nil, "no such part" end
  local E, ST, co = ref("base_economy"), ref("structures"), ref("company")
  if not (E and ST and co) then return nil, "the building rules aren't in this scene" end
  local plan = p.plan
  if not isEngineer() then return nil, def.shield and "Engineers only: a Shield Wall is set by an Engineer" or "Engineers only" end
  local q = E.quote(def, section_of(partId), p.body, home_body(), plan and plan.vol or 0)
  if q.mode ~= "money" or payer ~= "money" then return nil, q.why or "nothing to pay with" end
  if sid ~= nil and not ST.get(sid) then return nil, "that structure is gone" end
  -- (S4: a paste or a blueprint is ONE bill, paid before its pieces go down;
  -- each piece's record carries its share, so an undo refunds the bill)
  local pre = opts and opts.prepaid
  if pre then
    q = { mode = "money", cost = pre.cost, ship = pre.ship, foot = 0, total = pre.cost + pre.ship, supplier = q.supplier }
  elseif not co.spend(q.total, E.ledgerWhy(def.label, q)) then return nil, "can't afford it: " .. E.money(q.total) end
  local t = agency_now()
  local by = member()
  local paid = { cost = q.cost, ship = q.ship, foot = q.foot, total = q.total, t = t, supplier = q.supplier, by = by }
  local base = p.base or 0
  local ft = plan and plan.footing and { d = plan.footing.d, hx = plan.footing.hx, hz = plan.footing.hz } or nil
  local uid
  -- J6: a Battery Bank set up by an Engineer from level 2 charges better
  -- (crew.perk "battery_eff", fixed at placement: base_grid reads `effk`)
  local effk = nil
  if def.power and def.power.kind == "store" then
    local c = ref("crew")
    local okp, k = false, nil
    if c and c.perk and by ~= nil then okp, k = pcall(c.perk, by, "battery_eff") end
    if okp and type(k) == "number" and k > 0 then effk = k end
  end
  -- (a part's own fields, as it starts: a stand's deck height)
  local function own(entry)
    for k, v in pairs(def.fields or {}) do if entry[k] == nil then entry[k] = v end end
    if effk then entry.effk = effk end
    -- (S4) what the piece carries from a paste or a blueprint: its paint
    for k, v in pairs((opts and opts.fields) or {}) do entry[k] = v end
    return entry
  end
  if sid ~= nil then
    uid = ST.addPart(sid, own({ id = partId, x = p.lx or 0, y = (p.ly or 0) + base, z = p.lz or 0, yaw = p.yaw or 0,
      pitch = p.pitch or 0, roll = p.roll or 0, paid = paid, ft = ft }))
  else
    local dp = ref("deployables")
    local up, fw = p.sup or p.up, p.fwd0 or p.fwd
    local rec = ST.newRecord(nil, p.body, p.x + up.x * base, p.y + up.y * base, p.z + up.z * base, up, fw, partId,
      { by = by, t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, name = def.kit and "Structure" or def.label, paid = paid })
    rec.bp[1].paid, rec.bp[1].ft = paid, ft
    rec.bp[1].pitch, rec.bp[1].roll = p.pitch or 0, p.roll or 0
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
  -- (a drag-run, a mirrored twin, a paste: one step in the ring for all of them)
  if opts and opts.collect then opts.collect[#opts.collect + 1] = e else hist_push(e) end
  return sid, nil, q, uid
end

-- Several placements as ONE step of the ring (S1: a drag-run, a paste, a
-- mirrored pair): undo takes them all back newest first, redo buys them again.
local function push_group(list, label)
  if #list == 0 then return end
  if #list == 1 then hist_push(list[1]) return end
  local g = { label = label or string.format("place %d pieces", #list), kind = "place", t = list[#list].t, sid = list[1].sid }
  g.undo = function()
    local total = 0
    for i = #list, 1, -1 do
      local e = list[i]
      e.res = nil
      e.undo()
      if e.res == nil then g.res, g.why = nil, e.why return end
      total = total + e.res
    end
    g.res = total
  end
  g.redo = function()
    local total = 0
    for _, e in ipairs(list) do
      e.res = nil
      e.redo()
      if e.res == nil then g.res = nil return end
      total = total + e.res
    end
    g.t = agency_now()
    g.res = total
  end
  hist_push(g)
end
pushGroup = push_group

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
  -- (S1: kit pieces no longer held once these are gone come down with them)
  do local KS = ref("kit_snap"); if KS and not creative() then for _, u in ipairs(KS.fallsWith(rec, partInfo, uids)) do uids[#uids + 1] = u end end end
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
  -- (S1: kit pieces no longer held once these are gone come down with them)
  do local KS = ref("kit_snap"); if KS and not creative() then for _, u in ipairs(KS.fallsWith(rec, partInfo, uids)) do uids[#uids + 1] = u end end end
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

-- B9b: the Power Cable in hand. The first click makes it off at a part, the
-- second (on another structure's part) lays the run and bills it.
local function cable_click()
  local CB = ref("base_cable")
  if not (CB and req) then return end
  if not CB.pending then
    if req.bad then play("denied"); say(req.bad) return end
    CB.makeOff(req.hitRec, req.hitPart)
    play("pick", 0.5)
    local cd = (req.def and req.def.cable) or ((partInfo("powerCable") or {}).cable) or {}
    say(string.format("%s made off at the %s · walk it out to a part on another structure and click it (up to %.1f km)",
      tostring(req.def and req.def.label or "Power Cable"), tostring(req.label or "part"), (cd.max or 1500) / 1000))
    return
  end
  if req.bad then play("denied"); say(req.bad) return end
  local id, why, q, L = CB.lay(CB.pending, { sid = req.hitRec.id, uid = req.hitPart.uid })
  if not id then play("denied"); say(why or "it wouldn't lay there") return end
  CB.clearPending()
  play("place", 0.6)
  say(string.format("%s laid · %.0f m, %.1f t · %s (%s + %s shipping) · Ctrl+Z within a minute takes it up",
    tostring(req.def and req.def.label or "Power Cable"), L or 0, (q and q.mass) or 0, money(q.total), money(q.cost), money(q.ship)))
  heldPart = nil
end

local function do_place(keep)
  if not (req and heldPart) then return end
  if req.cable then cable_click() return end
  if req.bad then play("denied"); say(req.bad) return end
  local p = req.pose
  p.base, p.plan = req.base, req.plan
  if clip and pasting then paste_click(p) return end
  local list = {}
  local sid, why, q = place(p.sid, heldPart, p, "money", { collect = run and run.list or list })
  if not sid then play("denied"); say(why or "it wouldn't go there") return end
  local total = q.total
  -- SYM (S1): the mirrored twin about the plane picked, in the same structure
  local twin = mirror_twin(heldPart, req.def, p, sid)
  if twin then
    local s2, _, q2 = place(sid, twin.id or heldPart, twin, "money", { collect = run and run.list or list })
    if s2 then total = total + q2.total end
  end
  if run then run.n = run.n + 1 + (twin and 1 or 0); run.total = run.total + total; run.key = vmemo.key
  else push_group(list, "place " .. req.def.label .. (twin and " (mirrored)" or "")) end
  play("place", 0.6)
  if run then
    say(string.format("%s × %d · %s so far · release to finish the run (one undo)", req.def.label, run.n, money(run.total)))
  else
    say(string.format("%s placed%s · %s (%s + %s shipping%s) · Ctrl+Z within a minute returns it", req.def.label,
      twin and " with its mirror" or "", money(total), money(q.cost), money(q.ship), (q.foot or 0) > 0 and (" + " .. money(q.foot) .. " footing") or ""))
  end
  ov.key, vmemo.key = nil, nil
  -- (kit pieces stay in hand: building is many of them)
  if not keep and not (req.def and req.def.kit) then heldPart = nil end
end

-- ── SYM: mirror placements (S1 §1.4; the VAB's mirrorPose on a structure) ───
-- G toggles: off → about the structure's X plane through the piece under the
-- cursor → its Z plane → off. A twin is placed only in that structure, only
-- if it fits (kitWhy), and never onto the piece itself (a piece on the plane).
--
-- A TRUE REFLECTION (S3 follow-up: it used to turn asymmetric pieces). The
-- twin of a piece at R = Ry(yaw)·Rx(pitch)·Rz(roll) reflected in the
-- structure's plane S is S·R·S applied to the piece reflected in its own
-- matching plane: about X that is Ry(-yaw)·Rx(pitch)·Rz(-roll) on the piece
-- flipped left for right, about Z Ry(-yaw)·Rx(-pitch)·Rz(roll) on it flipped
-- front for back. A piece symmetric in that plane IS its flip; one symmetric
-- in the other plane is its flip turned half round (Ry(pi)), which moves the
-- signs through: `sym` (parts_kit) says which. A piece symmetric in neither
-- has a mirrored variant (`mirror`, built reflected) placed instead.
-- → the twin pose, and the part id to place (the variant's, or nil = the same)
function mirrorPose(p, axis, at, def)
  local m = {}
  for k, v in pairs(p) do m[k] = v end
  local y, pi_, r = p.yaw or 0, p.pitch or 0, p.roll or 0
  local sym = (def and def.sym) or "x"
  local variant = def and def.mirror
  local id = nil
  if axis == "x" then
    m.lx = 2 * at - (p.lx or 0)
    -- (flipped left for right: Ry(-y)·Rx(p)·Rz(-r))
    if variant or sym == "x" then m.yaw, m.pitch, m.roll = -y, pi_, -r
    else m.yaw, m.pitch, m.roll = math.pi - y, -pi_, r end
  else
    m.lz = 2 * at - (p.lz or 0)
    -- (flipped front for back: Ry(-y)·Rx(-p)·Rz(r))
    if sym == "z" and not variant then m.yaw, m.pitch, m.roll = -y, -pi_, r
    else m.yaw, m.pitch, m.roll = math.pi - y, pi_, -r end
  end
  if variant then
    local K = ref("parts_kit")
    id = K and K.idOf and K.idOf(variant, def.mat) or nil
  end
  local KS = ref("kit_snap")
  if KS then m.yaw, m.pitch, m.roll = KS.wrap(m.yaw), KS.wrap(m.pitch), KS.wrap(m.roll) end
  return m, id
end
function mirror_twin(id, def, p, sid)
  if not (sym and p.mode == "face" and sym.sid == sid and def and def.kit) then return nil end
  local m, vid = mirrorPose(p, sym.axis, sym.at, def)
  if math.abs((m.lx or 0) - (p.lx or 0)) < 0.05 and math.abs((m.lz or 0) - (p.lz or 0)) < 0.05 then return nil end
  local ST, KS = ref("structures"), ref("kit_snap")
  local rec = ST and ST.get(sid)
  if not (rec and KS) then return nil end
  local fr = KS.frameOf(rec)
  m.x = fr.O.x + fr.R.x * m.lx + fr.U.x * m.ly + fr.F.x * m.lz
  m.y = fr.O.y + fr.R.y * m.lx + fr.U.y * m.ly + fr.F.y * m.lz
  m.z = fr.O.z + fr.R.z * m.lx + fr.U.z * m.ly + fr.F.z * m.lz
  local tid = vid or id
  local tdef = vid and partInfo(vid) or def
  if not tdef or kitWhy(tdef, m, tid) then return nil end
  m.id = vid
  return m
end
local function toggle_sym()
  local ST = ref("structures")
  local h = aim()
  local rec, part = nil, nil
  if type(h) == "table" and h.node and ST then rec, part = ST.partOfNode(h.node) end
  if not sym then
    if not part then say("SYM: aim at a piece of the structure to mirror about") return end
    sym = { axis = "x", sid = rec.id, at = part.x or 0 }
  elseif sym.axis == "x" then
    sym = { axis = "z", sid = sym.sid, at = (part and rec.id == sym.sid) and (part.z or 0) or 0 }
  else sym = nil end
  say(sym and string.format("SYM on: mirrored about the structure's %s plane at %.1f m", sym.axis:upper(), sym.at) or "SYM off")
end

-- ── SELECT / COPY / PASTE (S1 §1.4) ─────────────────────────────────────────
-- Alt+click toggles a piece in the selection (tinted); Ctrl+C copies it (or
-- the piece under the cursor); Ctrl+V holds the copy as a composite ghost,
-- placed with one bill and one step in the ring; Ctrl+D copies and holds.
local function sel_key(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
local function sel_tint(sid, uid, on)
  local ST, KP = ref("structures"), ref("kit_paint")
  local n = ST and ST.nodeOf(sid, uid)
  if not (n and n.setTint) then return end
  -- (S4: on the piece's own surfaces — the root draws nothing — and its paint
  -- and dust back when it is let go)
  if KP and KP.highlight then
    local rec, p = ST.get(sid), ST.getPart(sid, uid)
    local def = p and partInfo(p.id)
    local d, c = 0, nil
    if rec and p and def and def.exterior and KP.dustOf then d, c = KP.dustOf(rec, p) end
    KP.highlight(n, on, p, def, d, c)
    return
  end
  if on then pcall(n.setTint, n, { color = { 0.6, 0.9, 1.0 }, rim = { 0.2, 0.7, 1.0 }, rimStrength = 0.8 })
  else pcall(n.setTint, n) end
end
function selectToggle(sid, uid)
  local k = sel_key(sid, uid)
  if selection[k] then selection[k] = nil; sel_tint(sid, uid, false)
  else
    for kk, e in pairs(selection) do if e.sid ~= sid then selection[kk] = nil; sel_tint(e.sid, e.uid, false) end end
    selection[k] = { sid = sid, uid = uid }; sel_tint(sid, uid, true)
  end
end
function selectClear() for _, e in pairs(selection) do sel_tint(e.sid, e.uid, false) end selection = {} end
-- Copy the selection (or the given pieces) of one structure. → n
function copyParts(sid, uids)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  if not rec then return 0 end
  local list = {}
  for _, u in ipairs(uids) do local p = ST.getPart(sid, u); local d = p and partInfo(p.id); if d and d.kit then list[#list + 1] = p end end
  if #list == 0 then return 0 end
  -- the anchor: the lowest, then the first placed
  table.sort(list, function(a, b) if math.abs((a.y or 0) - (b.y or 0)) > 0.05 then return (a.y or 0) < (b.y or 0) end return a.uid < b.uid end)
  local a = list[1]
  local c, s = math.cos(a.yaw or 0), math.sin(a.yaw or 0)
  local out = {}
  for _, p in ipairs(list) do
    local dx, dz = (p.x or 0) - (a.x or 0), (p.z or 0) - (a.z or 0)
    local st = ST.partState(sid, p.uid)
    out[#out + 1] = { id = p.id, dx = dx * c - dz * s, dy = (p.y or 0) - (a.y or 0), dz = dx * s + dz * c,
                      yaw = (p.yaw or 0) - (a.yaw or 0), pitch = p.pitch or 0, roll = p.roll or 0,
                      paint = p.paint, paintIn = p.paintIn, text = st and st.text or nil }
  end
  clip = { parts = out, n = #out, label = (partInfo(a.id) or {}).label }
  heldBp = nil
  return #out
end
local function copy_now()
  local uids, sid = {}, nil
  for _, e in pairs(selection) do sid = sid or e.sid; if e.sid == sid then uids[#uids + 1] = e.uid end end
  if #uids == 0 then
    local h = aim()
    local ST = ref("structures")
    local rec, part = nil, nil
    if type(h) == "table" and h.node and ST then rec, part = ST.partOfNode(h.node) end
    if part then sid, uids = rec.id, { part.uid } end
  end
  local n = sid and copyParts(sid, uids) or 0
  if n > 0 then play("pick", 0.4); say(string.format("copied %d piece%s · Ctrl+V holds them", n, n == 1 and "" or "s"))
  else play("denied"); say("nothing to copy: Alt+click pieces, or aim at one") end
  return n
end
pasting = false
function pasteHold()
  if not clip then return false end
  heldPart, pasting = clip.parts[1].id, true
  yawOffset, pitchOff, rollOff = 0, 0, 0
  return true
end
-- Where clip entry `e` goes for an anchor pose `p`: { lx, ly, lz, yaw, pitch, roll }
-- in the anchor's structure (dx.. turned by the anchor's yaw).
function clipPose(p, e)
  local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  return { lx = (p.lx or 0) + e.dx * c + e.dz * s, ly = (p.ly or 0) + e.dy, lz = (p.lz or 0) - e.dx * s + e.dz * c,
           yaw = (p.yaw or 0) + e.yaw, pitch = e.pitch, roll = e.roll }
end
-- (S4) ONE BILL for a clipboard or a blueprint: the pieces' prices, one
-- delivery's shipping (blueprints.bill). → { cost, ship, total, mass, n, missing }
function blueprintBill(bp)
  local BP, E = ref("blueprints"), ref("base_economy")
  local function price(id)
    local d = partInfo(id)
    if not (d and d.kit) then return nil end
    return math.floor(d.cost or 0)
  end
  local function mass(id) local d = partInfo(id); return d and d.mass or 0 end
  if not BP then return { cost = 0, ship = 0, total = 0, mass = 0, n = 0, missing = {} } end
  return BP.bill(bp, price, mass, E and E.shipping or nil)
end
local function clip_bill(c)
  local ps = {}
  for _, e in ipairs(c.parts) do ps[#ps + 1] = { id = e.id } end
  return blueprintBill({ pieces = ps })
end
clipBill = clip_bill
function paste_click(p)
  local ST, KS, co = ref("structures"), ref("kit_snap"), ref("company")
  local BP = ref("blueprints")
  local list, placed, skipped, total = {}, 0, 0, 0
  -- the bill, paid once, before anything goes down
  local b = clip_bill(clip)
  local what = (heldBp and clip.label) and ("blueprint " .. tostring(clip.label)) or string.format("paste of %d pieces", clip.n)
  if not co.spend(b.total, string.format("%s · %s + %s shipping, one delivery", what, money(b.cost), money(b.ship))) then
    play("denied"); say("can't afford it: " .. money(b.total)) return
  end
  local function pre(id)
    local d = partInfo(id)
    local c = math.floor((d and d.cost) or 0)
    return { cost = c, ship = BP and BP.shareOf(b, c) or 0 }
  end
  local refund = 0
  local why_skip = {}
  local function fields(e) return { paint = e.paint, paintIn = e.paintIn } end
  local function words(s2, uid, e)
    if e.text and uid then ST.setPartState(s2, uid, { text = e.text }) end
  end
  local a0 = clip.parts[1]
  local sid, _, q, uid0 = place(p.sid, a0.id, p, "money", { collect = list, prepaid = pre(a0.id), fields = fields(a0) })
  if not sid then co.refund(b.total, "returned: " .. what .. " (it couldn't go there)"); play("denied"); say("couldn't build it there") return end
  words(sid, uid0, a0)
  total = total + q.total
  placed = 1
  local rec = ST.get(sid)
  local anchor = p.mode == "face" and { lx = p.lx, ly = p.ly, lz = p.lz, yaw = p.yaw } or { lx = 0, ly = 0, lz = 0, yaw = 0 }
  local fr = KS.frameOf(rec)
  -- (lowest first: a wall goes on after the floor it stands on; mounts last)
  local order = {}
  for i = 2, #clip.parts do order[#order + 1] = clip.parts[i] end
  local function mnt(e) local d = partInfo(e.id); return (d and d.snap == "mount") and 1 or 0 end
  table.sort(order, function(x, y)
    if mnt(x) ~= mnt(y) then return mnt(x) < mnt(y) end
    return x.dy < y.dy
  end)
  for _, e in ipairs(order) do
    local def = partInfo(e.id)
    local cp = clipPose(anchor, e)
    local m = { body = p.body, mode = "face", sid = sid, lx = cp.lx, ly = cp.ly, lz = cp.lz, yaw = cp.yaw, pitch = cp.pitch, roll = cp.roll,
                x = fr.O.x + fr.R.x * cp.lx + fr.U.x * cp.ly + fr.F.x * cp.lz, y = fr.O.y + fr.R.y * cp.lx + fr.U.y * cp.ly + fr.F.y * cp.lz,
                z = fr.O.z + fr.R.z * cp.lx + fr.U.z * cp.ly + fr.F.z * cp.lz, up = fr.U, fwd = fr.F }
    local pe = pre(e.id)
    local kw = def and def.kit and kitWhy(def, m, e.id) or (def and not def.kit and "not a kit piece") or (not def and "unknown")
    if not kw then
      local s2, w2, q2, u2 = place(sid, e.id, m, "money", { collect = list, prepaid = pe, fields = fields(e) })
      if s2 then placed = placed + 1; total = total + q2.total; words(s2, u2, e)
      else skipped = skipped + 1; refund = refund + pe.cost + pe.ship; why_skip[#why_skip + 1] = e.id .. ": " .. tostring(w2) end
    else
      skipped = skipped + 1
      if def and def.kit then refund = refund + pe.cost + pe.ship end
      why_skip[#why_skip + 1] = e.id .. ": " .. tostring(kw)
    end
  end
  if refund > 0 then co.refund(refund, string.format("returned: %d piece%s of the %s that didn't fit", skipped, skipped == 1 and "" or "s", what)) end
  push_group(list, heldBp and ("build " .. tostring(clip.label)) or string.format("paste %d pieces", placed))
  lastPaste = { sid = sid, placed = placed, skipped = skipped, total = total, bill = b, bp = heldBp, why = why_skip }
  if #why_skip > 0 and log then log("build: didn't fit: " .. table.concat(why_skip, " · ")) end
  play("place", 0.6)
  say(string.format("%s %d piece%s · %s, one delivery%s · Ctrl+Z within a minute takes them back", heldBp and "built" or "pasted",
    placed, placed == 1 and "" or "s", money(total), skipped > 0 and string.format(" · %d didn't fit (refunded)", skipped) or ""))
  ov.key, vmemo.key = nil, nil
end

-- ── BLUEPRINTS (S4; blueprints.lua) ─────────────────────────────────────────
-- A blueprint card in hand is a paste: its clip, its composite ghost, its one
-- bill; R and the wheel turn it, its anchor snaps as a piece would.
function holdBlueprint(key)
  local BP = ref("blueprints")
  local bp = BP and BP.get(key)
  if not bp then play("denied"); say("that blueprint is gone") return false end
  local c = BP.toClip(bp)
  -- (pieces this Solar doesn't know are left out, and said)
  local keep, miss = {}, 0
  for _, e in ipairs(c.parts) do if partInfo(e.id) then keep[#keep + 1] = e else miss = miss + 1 end end
  if #keep == 0 then play("denied"); say("none of its pieces are in this kit") return false end
  -- (the anchor must stay first: re-anchored on the first known piece)
  if keep[1] ~= c.parts[1] then
    local a = keep[1]
    local ax, ay, az, ayaw = a.dx, a.dy, a.dz, a.yaw
    local ca, sa = math.cos(ayaw), math.sin(ayaw)
    for _, e in ipairs(keep) do
      local dx, dz = e.dx - ax, e.dz - az
      e.dx, e.dy, e.dz, e.yaw = dx * ca - dz * sa, e.dy - ay, dx * sa + dz * ca, e.yaw - ayaw
    end
  end
  clip = { parts = keep, n = #keep, label = bp.name, bp = bp }
  heldBp = "bp:" .. key
  heldPart, pasting = keep[1].id, true
  yawOffset, pitchOff, rollOff, storey = 0, 0, 0, 0
  play("pick", 0.4)
  local b = clip_bill(clip)
  say(string.format("%s · %d pieces · %s one delivery · LMB builds it, R turns it%s", bp.name, #keep, money(b.total),
    miss > 0 and string.format(" · %d unknown pieces left out", miss) or ""))
  return true
end
-- the card's picture: a plan drawing (top-down, ink on enamel), kept per key
local bp_icons = {}
function blueprintIcon(d)
  local k = tostring(d.key) .. "|" .. tostring(d.bp and d.bp.n)
  if bp_icons[k] ~= nil then return bp_icons[k] or nil end
  local BP = ref("blueprints")
  if not (BP and image and image.new) then return nil end
  local rects, lo, hi = BP.planOf(d.bp, partInfo)
  local ok, img = pcall(image.new, 64, 64, 0.12, 0.13, 0.115, 1)
  if not ok or not img then bp_icons[k] = false return nil end
  local w, h = math.max(0.5, hi[1] - lo[1]), math.max(0.5, hi[2] - lo[2])
  local sc = 52 / math.max(w, h)
  local ox, oz = 32 - (lo[1] + w / 2) * sc, 32 - (lo[2] + h / 2) * sc
  table.sort(rects, function(a, b) return (a[6] or 0) < (b[6] or 0) end)
  for _, r in ipairs(rects) do
    local x0, z0 = ox + r[1] * sc, oz + r[2] * sc
    local rw, rh = math.max(1, (r[3] - r[1]) * sc), math.max(1, (r[4] - r[2]) * sc)
    local c = ((r[5] == "slab" or r[5] == "floor") and { 0.40, 0.40, 0.37 }) or (r[5] == "wall" and { 0.92, 0.89, 0.81 })
      or (r[5] == "prop" and { 0.97, 0.55, 0.22 }) or { 0.70, 0.67, 0.59 }
    pcall(img.fill, img, x0, z0, rw, rh, c[1], c[2], c[3], (r[5] == "slab" or r[5] == "floor") and 0.6 or 1)
  end
  local okt, tex = pcall(img.texture, img)
  bp_icons[k] = (okt and tex) or false
  return bp_icons[k] or nil
end
-- Save the Alt-selection (or the whole structure `sid`, or the one the crew
-- stands at) as a blueprint: the name prompt, then its code. → ok, why
lastBlueprint = nil
function saveBlueprint(sid, uids, name)
  local ST, BP = ref("structures"), ref("blueprints")
  if not (ST and BP) then return false, "no blueprint library here" end
  if not sid then
    local s0, us = nil, {}
    for _, e in pairs(selection) do s0 = s0 or e.sid; if e.sid == s0 then us[#us + 1] = e.uid end end
    if s0 then sid, uids = s0, us end
  end
  if not sid then
    local a = astro()
    local bname = a and space.dominant(a.x, a.y, a.z)
    local b = bname and space.body(bname)
    local near = b and ST.partsNear(bname, a.x - b.x, a.y - b.y, a.z - b.z, 30)
    if near and near[1] then sid = near[1].rec.id end
  end
  local rec = sid and ST.get(sid)
  if not rec then play("denied"); say("Save as Blueprint: Alt+click pieces to choose them, or stand at a structure") return false, "nothing chosen" end
  local bp, why = BP.fromParts(rec, uids, partInfo, { name = (rec.n and rec.n ~= "Structure") and rec.n or "My Build", by = member(), made = agency_now(),
    texts = function(uid) local st = ST.partState(sid, uid); return st and st.text or nil end })
  if not bp then play("denied"); say("Save as Blueprint: " .. tostring(why)) return false, why end
  local b = blueprintBill(bp)
  local function finish(text)
    if type(text) == "string" and text:match("%S") then bp.name = text:sub(1, BP.NAME_MAX) end
    local s, path, code = BP.saveBp(bp)
    if not s then return false, path end
    play("place", 0.5)
    lastBlueprint = { slug = s, path = path, code = code, n = bp.n, name = bp.name }
    BP.prompt({ title = "Saved: " .. bp.name, readOnly = true, code = code, ok = "Done", cancel = "Close",
      line = string.format("In your blueprints (%s), and in the BLUEPRINTS tab. To share it, send the file, or this code (%d characters):",
        (tostring(path):gsub("^user://", "")), #code),
      hint = "The code is also written beside the file as " .. s .. ".code.txt",
      onOk = function() return true end })
    return true
  end
  -- (a probe names it: no prompt)
  if name then return finish(name) end
  BP.prompt({ title = "Save as a blueprint", maxLen = BP.NAME_MAX, ok = "Save it", text = "", placeholder = bp.name,
    line = string.format("%d pieces · %.1f t · %s to build again, one delivery%s", bp.n, b.mass, money(b.total),
      uids and "  ·  the pieces you chose" or "  ·  the whole structure"),
    onOk = finish })
  return true
end
function importBlueprint(code)
  local BP = ref("blueprints")
  if not BP then return false end
  local function take(text)
    local s, why = BP.importCode(text)
    if not s then return false, why end
    play("place", 0.5)
    say(string.format("blueprint \"%s\" added · it's in the BLUEPRINTS tab", BP.get(s).name))
    return true, s
  end
  if code then return take(code) end
  BP.prompt({ title = "Import a blueprint code", maxLen = BP.CODE_MAX, ok = "Import", placeholder = "SOLBP1.…",
    line = "Paste a code someone shared (SOLBP1.…). A blueprint's .json file dropped on the window works too.",
    onOk = take })
  return true
end

-- ── PAINT (S4; kit_paint.lua) ───────────────────────────────────────────────
-- A swatch in hand paints what the cursor is on: a wall's face (the side you
-- see; Shift both), any other piece whole; Ctrl every piece of that kind on
-- the structure; a piece in the Alt-selection paints the selection. I (or the
-- Eyedropper card) takes a piece's colour into the hand. One step in the undo
-- ring a click, refunded within the minute like a placement.
paintReq = nil        -- { rec, part, def, face, bad } (this frame's aim)
lastPaint = nil       -- { n, key, face, cost, t } (probes)
local hover = { sid = nil, uid = nil }
local function rim(sid, uid, on)
  local ST, KP = ref("structures"), ref("kit_paint")
  local n = ST and ST.nodeOf(sid, uid)
  if not (n and KP) then return end
  local out, inn = KP.surfaces(n)
  local t = on and { rim = { 1.0, 0.62, 0.30 }, rimStrength = 0.7 } or { rimStrength = 0 }
  for _, c in ipairs(out) do pcall(c.setTint, c, t) end
  for _, c in ipairs(inn) do pcall(c.setTint, c, t) end
end
local function hover_set(sid, uid)
  if hover.sid == sid and hover.uid == uid then return end
  if hover.sid then rim(hover.sid, hover.uid, false) end
  hover.sid, hover.uid = sid, uid
  if sid then rim(sid, uid, true) end
end
function hoverClear() hover_set(nil, nil) end
-- The piece under a hit: a mount (decal, sign, fitting) at the hit point
-- first — a ray passes through them to the wall — else the hit piece.
-- → rec, part, (nx, ny, nz: the hit normal in its structure's frame)
function pickAt(node, body, rx, ry, rz, wnx, wny, wnz)
  local ST, KS = ref("structures"), ref("kit_snap")
  if not (ST and node) then return nil end
  local rec, part = ST.partOfNode(node)
  if not rec then return nil end
  if not (KS and body == rec.b and rx) then return rec, part end
  local fr = KS.frameOf(rec)
  local dx, dy, dz = rx - fr.O.x, ry - fr.O.y, rz - fr.O.z
  local lx = dx * fr.R.x + dy * fr.R.y + dz * fr.R.z
  local ly = dx * fr.U.x + dy * fr.U.y + dz * fr.U.z
  local lz = dx * fr.F.x + dy * fr.F.y + dz * fr.F.z
  local nx, ny, nz
  if wnx then
    nx = wnx * fr.R.x + wny * fr.R.y + wnz * fr.R.z
    ny = wnx * fr.U.x + wny * fr.U.y + wnz * fr.U.z
    nz = wnx * fr.F.x + wny * fr.F.y + wnz * fr.F.z
  end
  local m = KS.mountAt and KS.mountAt(rec, partInfo, lx, ly, lz)
  if m then part = m end
  return rec, part, nx, ny, nz
end
-- (a context menu target: the click point was kept body-relative at the pick)
function pickTarget(t)
  if not (t and t.node) then return nil end
  if t._kit ~= nil then
    local ST = ref("structures")
    if not t._kit then return nil end
    local r = ST.get(t._kit[1])
    return r, r and ST.getPart(t._kit[1], t._kit[2])
  end
  local rec, part = pickAt(t.node, t.body, t.rx, t.ry, t.rz)
  t._kit = (rec and part) and { rec.id, part.uid } or false
  return rec, part
end
local function hit_pick(h)
  local bname = space.dominant(h.x, h.y, h.z)
  local b = bname and space.body(bname)
  if not b then return nil end
  return pickAt(h.node, bname, h.x - b.x, h.y - b.y, h.z - b.z, h.nx, h.ny, h.nz)
end
hitPick = hit_pick
local function paint_aim()
  local h = aim()
  if h == "keep" then return paintReq end
  if type(h) ~= "table" or not h.node then return nil end
  local rec, part, nx, _, nz = hit_pick(h)
  if not part then return nil end
  local def = partInfo(part.id)
  local KP = ref("kit_paint")
  if not (def and KP) then return nil end
  local r = { rec = rec, part = part, def = def, face = "both" }
  if def.faces2 and nx then r.face = KP.faceOf(part.yaw or 0, nx, nz) end
  local hd = toolDef(heldPart)
  if hd and hd.tool == "paint" and not KP.paintable(def) then
    r.bad = (def.film and "paint goes on pieces, not on decals") or (def.live and "a fitting keeps its own finish") or "that doesn't take paint"
  end
  return r
end
paintAim = paint_aim
-- Paint parts { uid … } of structure `sid` with `key` (nil strips) on `face`
-- ("out" | "in" | "both"). → n | nil, why
function paintParts(sid, uids, key, face)
  local ST, KP, co = ref("structures"), ref("kit_paint"), ref("company")
  local rec = ST and ST.get(sid)
  if not (rec and KP and co) then return nil, "nothing to paint" end
  local targets = {}
  for _, u in ipairs(uids) do
    local p = ST.getPart(sid, u)
    local d = p and partInfo(p.id)
    if p and d and KP.paintable(d) then targets[#targets + 1] = p end
  end
  if #targets == 0 then return nil, "nothing there takes paint" end
  local cost = key and KP.costOf(#targets, creative()) or 0
  if cost > 0 and not co.spend(cost, string.format("paint: %d piece%s, %s", #targets, #targets == 1 and "" or "s", KP.swatch(key).label)) then
    return nil, "can't afford the paint: " .. money(cost)
  end
  local t = agency_now()
  local before = {}
  for _, p in ipairs(targets) do
    before[#before + 1] = { uid = p.uid, paint = p.paint, paintIn = p.paintIn, pt = p.pt }
    local f = KP.painted(p, key, (face == "both" or not partInfo(p.id).faces2) and "both" or face, t)
    p.paint, p.paintIn, p.pt = f.paint, f.paintIn, f.pt
  end
  ST.put(rec)
  for _, p in ipairs(targets) do KP.refresh(sid, p.uid) end
  local function restore_to(list)
    local r2 = ST.get(sid)
    if not r2 then return end
    for _, b in ipairs(list) do
      local p = ST.getPart(sid, b.uid)
      if p then p.paint, p.paintIn, p.pt = b.paint, b.paintIn, b.pt end
    end
    ST.put(r2)
    for _, b in ipairs(list) do KP.refresh(sid, b.uid) end
  end
  local after = {}
  for _, p in ipairs(targets) do after[#after + 1] = { uid = p.uid, paint = p.paint, paintIn = p.paintIn, pt = p.pt } end
  local lbl = key and KP.swatch(key).label or "bare"
  local e = { label = string.format("paint %d %s", #targets, lbl), kind = "paint", t = t, sid = sid }
  e.undo = function()
    restore_to(before)
    if cost > 0 then co.refund(cost, "paint taken back (undone within a minute)") end
    e.res = cost
  end
  e.redo = function()
    if cost > 0 and not co.spend(cost, "paint again") then e.res = nil return end
    restore_to(after)
    e.t = agency_now()
    e.res = cost
  end
  hist_push(e)
  lastPaint = { n = #targets, key = key, face = face, cost = cost, t = t }
  return #targets
end
local function paint_click(ctrl, shift)
  local r = paintReq
  local KP = ref("kit_paint")
  local hd = toolDef(heldPart)
  if not (r and hd and KP) then play("denied"); say("aim at a piece of a structure") return end
  if hd.tool == "pick" or (input and input.key and input.key("i")) then
    local k = KP.pick(r.part, r.face)
    if k then hold("paint:" .. k); say(string.format("picked up %s from the %s", KP.swatch(k).label, tostring(r.def.label)))
    else say(string.format("the %s is bare %s", tostring(r.def.label), tostring(r.def.matLabel or ""):lower())) end
    return
  end
  if r.bad then play("denied"); say(r.bad) return end
  local key = hd.paint
  local uids, face = { r.part.uid }, (shift and "both") or r.face
  local skey = sel_key(r.rec.id, r.part.uid)
  if selection[skey] then
    uids, face = {}, "both"
    for _, e in pairs(selection) do if e.sid == r.rec.id then uids[#uids + 1] = e.uid end end
  elseif ctrl then
    uids = {}
    for _, p in ipairs(r.rec.bp) do
      local d = partInfo(p.id)
      if d and d.piece == r.def.piece then uids[#uids + 1] = p.uid end
    end
  end
  local n, why = paintParts(r.rec.id, uids, key, face)
  if not n then play("denied"); say(why) return end
  play("place", 0.45)
  local where = (#uids > 1 and string.format("%d pieces", n)) or (face == "in" and "its inside") or (face == "out" and "its outside") or "it"
  say(string.format("%s %s · %s%s", key and "painted" or "stripped", where, key and KP.swatch(key).label or "bare",
    (lastPaint.cost or 0) > 0 and (" · " .. money(lastPaint.cost)) or ""))
end
paintClick = paint_click

lastPaste = nil

-- ── a Ctrl+drag RUN (S1): pieces laid as the snapped ghost moves, one step ──
run = nil
local function run_begin() run = { list = {}, n = 0, total = 0, t = now() } end
local function run_end()
  if not run then return end
  local r = run
  run = nil
  if r.n > 0 then
    push_group(r.list, string.format("a run of %d", r.n))
    lastRun = { n = r.n, total = r.total, t = now() }
    say(string.format("a run of %d · %s · one Ctrl+Z takes it all back", r.n, money(r.total)))
  end
end
runBegin, runEnd = run_begin, run_end

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
  -- (S4: a decal or a sign under the click, not the wall behind it)
  local rec, part = pickTarget(t)
  if not part then return {} end
  local def = partInfo(part.id) or {}
  local sid, uid = rec.id, part.uid
  local function ask()
    local amt, n, full = deconstructQuote(sid, uid)
    return string.format("%s back%s%s", money(amt), full and "" or " (fee kept)",
      n > 1 and string.format(" · takes %d part%s with it", n - 1, n > 2 and "s" or "") or "")
  end
  local rows = {
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
  }
  -- (S4) blueprints from here: the whole structure, or the Alt-selection
  if def.kit then
    rows[#rows + 1] = { id = "bk_bp", type = "action", label = "Save structure as blueprint", group = "Base", hint = "▣",
      act = function() if ctx and ctx.close then ctx.close() end saveBlueprint(sid, nil); return true end }
    local n = 0
    for _, e in pairs(selection) do if e.sid == sid then n = n + 1 end end
    if n > 0 then
      rows[#rows + 1] = { id = "bk_bpsel", type = "action", label = string.format("Save the %d selected as blueprint", n), group = "Base", hint = "▣",
        act = function() if ctx and ctx.close then ctx.close() end saveBlueprint(); return true end }
    end
  end
  return rows, def.label
end
providerFn = provider   -- (probes)
local provider_on = false
local function register_provider()
  if provider_on then return end
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", provider, { id = "field_builder", order = 6 })
    -- (S2: a VAB part placed live is a part of its structure's vessel: the
    -- same Deconstruct row on its part menu)
    reg.register("part", provider, { id = "field_builder_live", order = 90 })
    provider_on = true
  end
end

-- ── the hint line (item_hand shows it under the belt: items.lua hintFrom) ──
local MODE_TXT = { edge = "EDGE TO EDGE", deck = "ON THE DECK", grid = "GRID 0.5 m", free = "FREE" }
function hintLine()
  if not open_ then return "Build Kit  ·  B opens it" end
  local keys = (collapsed and "B unfolds the parts" or "B folds the parts") .. "  ·  Esc " .. (heldPart and "drops the part" or "closes the kit") .. "  ·  Ctrl+Z undo  ·  F1 rooms  ·  F2 power"
  if not heldPart then return "Build Kit  ·  pick a part  ·  RMB tap a placed part to take it down  ·  " .. keys end
  local hdef = partInfo(heldPart)
  -- (S4) paint and the eyedropper
  if hdef and (hdef.tool == "paint" or hdef.tool == "pick") then
    local r = paintReq
    local what = r and string.format("%s%s", tostring(r.def.label), (r.def.faces2 and r.face ~= "both") and (r.face == "in" and " (inside)" or " (outside)") or "") or (aim_why or "aim at a piece")
    if hdef.tool == "pick" then return string.format("Eyedropper  ·  %s  ·  LMB takes its colour  ·  RMB tap drops it", what) end
    if r and r.bad then return string.format("%s  ·  %s  ·  %s", hdef.label, what, r.bad) end
    return string.format("%s  ·  %s  ·  LMB paints %s%s  ·  Shift both faces  ·  Ctrl every one of its kind  ·  Alt-selected: all of them  ·  hold I + LMB picks a colour",
      hdef.label, what, (r and r.def.faces2) and "this side" or "it", hdef.strip and "" or (creative() and " (free)" or (" for " .. money(hdef.cost))))
  end
  if hdef and hdef.cable then
    local CB = ref("base_cable")
    local pend = CB and CB.pending
    local nm = hdef.label or "Power Cable"
    if not req then return string.format("%s  ·  %s", nm, aim_why or "aim at a placed part") end
    if req.bad then return string.format("%s  ·  %s  ·  RMB tap drops it", nm, req.bad) end
    if not pend then return string.format("%s  ·  LMB makes it off at the %s  ·  then walk it out to another structure", nm, tostring(req.label or "part")) end
    local q = req.quote or {}
    -- (S5) what the run would lose at the grid's load now: the loss of a
    -- 10 kW draw over its length at its voltage, so the gauge is chosen
    local BP = ref("base_power")
    local lossTxt = ""
    if BP and BP.lossShare and req.len then
      lossTxt = string.format("  ·  loses %.1f %% at 10 kW", 100 * BP.lossShare(10, hdef.cable.type or "lv16", req.len))
    end
    return string.format("%s from the %s  ·  %.0f m, %.1f t%s  ·  LMB lays it for %s (%s + %s shipping)",
      nm, tostring(pend.label), req.len or 0, q.mass or 0, lossTxt, money(q.total or 0), money(q.cost or 0), money(q.ship or 0))
  end
  local turn = "scroll turns  ·  R quarter  ·  PgUp/PgDn raise  ·  Shift frees"
  local hk = partInfo(heldPart)
  if hk and hk.kit then
    turn = (hk.live and "" or "M material  ·  ") .. "R quarter  ·  Shift+R pitch  ·  T roll  ·  PgUp storey  ·  Ctrl+drag a run  ·  G mirror  ·  Ctrl+C/V copy"
  end
  if not req then return string.format("%s  ·  %s  ·  %s", partInfo(heldPart).label, aim_why or "aim at the ground", turn) end
  if req.bad then return string.format("%s  ·  %s  ·  RMB tap drops it", req.def.label, req.bad) end
  local q = req.quote
  local extra = {}
  local p = req.pose
  if p.mode == "face" then
    local ad = p.anchor and partInfo(p.anchor.id)
    extra[#extra + 1] = "ON THE " .. string.upper(tostring(ad and ad.label or "PIECE"))
  else extra[#extra + 1] = MODE_TXT[p.mode or "free"] or "" end
  if req.def.kit and req.def.matLabel and not req.def.live then extra[#extra + 1] = req.def.matLabel:lower() .. string.format(" %.2f t", req.def.mass or 0) end
  if storey > 0 then extra[#extra + 1] = string.format("+%d storey", storey) end
  if sym then extra[#extra + 1] = "SYM " .. sym.axis:upper() end
  if pasting and clip then
    local b = clip_bill(clip)
    extra[#extra + 1] = string.format("%s %d · %s one delivery", heldBp and ("BLUEPRINT " .. tostring(clip.label)) or "PASTE", clip.n, money(b.total))
  end
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
  local hd = heldPart and partInfo(heldPart)
  local kit = hd and hd.kit
  if input.pressed("r") then
    -- (S1: Shift+R pitches a kit piece a quarter — a truss laid down)
    if kit and fine then pitchOff = SN.wrap(pitchOff + SN.QUARTER) else yawOffset = SN.wrap(yawOffset + SN.QUARTER) end
  end
  if kit and input.pressed("t") then rollOff = SN.wrap(rollOff + SN.QUARTER) end
  -- M: the next material this piece comes in (and the kit's for the next ones)
  if kit and not hd.live and input.pressed("m") then
    local K = ref("parts_kit")
    if K then
      local m = material
      for _ = 1, #K.MAT_ORDER do
        m = K.nextMat(m)
        if K.matFor(hd.piece, m) == m then break end
      end
      material = m
      local nid = K.idOf(hd.piece, K.matFor(hd.piece, m))
      if nid ~= heldPart then heldPart = nid; play("pick", 0.35) end
      say(string.format("%s · %s", hd.label, (K.MATS[K.matFor(hd.piece, m)] or {}).label or m))
    end
  end
  local rs, rm = SN and SN.RAISE_STEP or 0.25, SN and SN.RAISE_MAX or 2.0
  local onface = kit and req and req.pose and req.pose.mode == "face"
  if input.pressed("pageup") then if onface then storey = math.min(4, storey + 1) else raise = math.min(rm, raise + rs) end end
  if input.pressed("pagedown") then if onface or storey > 0 then storey = math.max(0, storey - 1) else raise = math.max(0, raise - rs) end end
  if input.pressed("backspace") then yawOffset, raise, pitchOff, rollOff, storey = 0, 0, 0, 0, 0 end
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
  -- (an Esc the kit's own prompt took this frame — blueprints.lua — is spent)
  if input.pressed("escape") and escTakenAt ~= now() then
    escTakenAt = now()
    if heldPart then heldPart, pasting, heldBp = nil, false, nil
    elseif next(selection) then selectClear()
    else close() return end
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
  do local hd = heldPart and partInfo(heldPart); materialKey = hd ~= nil and hd.kit == true and not hd.live end
  if heldPart and not input.key("ctrl") then turn_keys() end
  -- S1: G mirrors placements; Ctrl+C / Ctrl+V / Ctrl+D copy, paste, duplicate
  if not typing() then
    if input.pressed("g") and not input.key("ctrl") then toggle_sym() end
    -- S3: F1 shows the ROOMS overlay (each room's outline and its air)
    if input.pressed("f1") then
      local RA = ref("room_air")
      if RA then RA.overlay = not RA.overlay; say(RA.overlay and "ROOMS: each room's outline and air · green sealed with air, amber sealed and thin, red open or venting" or "ROOMS overlay off") end
    end
    -- S5: F2 shows the POWER overlay (each cable's load and flow, breakers, the grid's card)
    if input.pressed("f2") then
      local BP = ref("base_power")
      if BP then BP.overlay = not BP.overlay; say(BP.overlay and "POWER: each cable's flow and load · green under half its rating, amber to full, red over it or tripped, grey off" or "POWER overlay off") end
    end
    if input.key("ctrl") then
      if input.pressed("c") then copy_now() end
      if input.pressed("v") then if pasteHold() then say(string.format("paste: %d piece%s in hand · LMB places them", clip.n, clip.n == 1 and "" or "s")) else say("nothing copied yet (Ctrl+C)") end end
      if input.pressed("d") then if copy_now() > 0 then pasteHold() end end
    end
  end
  if not heldPart then pasting = false end
  if heldPart and pasting and clip and heldPart ~= clip.parts[1].id then pasting = false end
  if not pasting then heldBp = nil end
  -- RMB: a tap drops the ghost; held, the camera looks round
  local r_down = input.button and input.button(1) == true
  if r_down and not rmb.down then rmb.t = now(); rmb.x, rmb.y = mouse_xy() end
  if not r_down and rmb.down and now() - rmb.t < 0.25 then heldPart, heldBp = nil, nil end
  rmb.down = r_down
  if heldPart then rmb_own_t = now() end
end

function lateUpdate(node, dt)
  if not open_ then ghost_paint() return end
  local hdef = heldPart and partInfo(heldPart)
  if hdef and hdef.cable then
    local h, w = aim()
    local CB = ref("base_cable")
    if h == "keep" then
      -- (held still under a held RMB)
    elseif h and CB and CB.aimTick then
      req = CB.aimTick(h)
      req.cable, req.id, req.def = true, heldPart, hdef
      aim_why = nil
    else
      req, aim_why = nil, w
      if CB and CB.pending and CB.drawPreview then CB.drawPreview() end
    end
  elseif heldPart and is_tool(heldPart) then
    -- (S4) paint or the eyedropper: what the cursor is on, its rim lit
    req = nil
    paintReq = paint_aim()
    aim_why = paintReq == nil and "aim at a piece of a structure" or nil
    if paintReq then hover_set(paintReq.rec.id, paintReq.part.uid) else hover_set(nil, nil) end
  elseif heldPart then
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
  if not (heldPart and is_tool(heldPart)) then
    paintReq = nil
    if hover.sid then hover_set(nil, nil) end
  end
  ghost_paint()
  -- LMB (an edge, off the panel and the HUD's buttons)
  local l = (sim and sim.lmb) or (input.button and input.button(0) == true)
  local ctrl = (sim and sim.ctrl) or (input.key and input.key("ctrl")) or false
  local alt = (sim and sim.alt) or (input.key and input.key("alt")) or false
  if l and not lmb_was and not over_panel() and not typing() and not naming() then
    if alt then
      -- (S1: Alt+click a piece: in or out of the selection)
      local h = aim()
      local ST = ref("structures")
      local rec, part = nil, nil
      if type(h) == "table" and h.node and ST then rec, part = hit_pick(h) end
      if part and (partInfo(part.id) or {}).kit then selectToggle(rec.id, part.uid); play("pick", 0.3) end
    elseif heldPart and is_tool(heldPart) then
      paint_click(ctrl, shift_held() == true)
    elseif heldPart then
      local hd = partInfo(heldPart)
      if ctrl and hd and hd.kit and not pasting then
        run_begin()
        local p = req and req.pose
        if p then run.first = { yaw = p.yaw or 0, ly = p.ly or 0, lx = p.lx or 0, lz = p.lz or 0, sid = p.sid, snap = hd.snap }; run.done = {} end
      end
      do_place(shift_held() == true)
      if run and req and req.pose then run.done[string.format("%.2f|%.2f|%.2f", req.pose.lx or 0, req.pose.ly or 0, req.pose.lz or 0)] = true end
    end
  elseif l and lmb_was and run and heldPart and req and not req.bad and req.pose and req.pose.mode == "face" and run.n < RUN_CAP then
    -- the run goes on along its own line (a wall's) or level (a floor's)
    local p, f = req.pose, run.first
    local key = string.format("%.2f|%.2f|%.2f", p.lx or 0, p.ly or 0, p.lz or 0)
    local ok = f and p.sid == f.sid and math.abs((p.ly or 0) - f.ly) < 0.05 and not run.done[key]
    if ok and f.snap ~= "floor" then
      local d = math.abs(((p.yaw or 0) - f.yaw + math.pi / 2) % math.pi - math.pi / 2)
      local ex, ez = math.cos(f.yaw), -math.sin(f.yaw)     -- the line's X in the structure frame
      local off = ((p.lx or 0) - f.lx) * (-ez) + ((p.lz or 0) - f.lz) * ex
      ok = d < 0.01 and math.abs(off) < 0.05
    end
    if ok then
      run.done[key] = true
      do_place(true)
    end
  end
  if not l and run then run_end() end
  lmb_was = l == true
end
