-- ═══ THE PUBLIC BUILDER API (docs/builder-design.md §11.1; WP1) ═══════════
-- Globals on this script, reached with findScript("builder"). Every panel and
-- overlay uses ONLY these; nothing outside this file reads `parts`. All
-- coordinates are BuildFrame-LOCAL (the identity in standalone builder.ron).
-- WP1's rulebooks sit beside it on the BuilderGraph node: builder_graph (the
-- links graph, blueprint v2), builder_space (frame adapter, spatial hash),
-- builder_history (the command history). Under luajit they load from disk.
--
-- QUERIES
--   craftVersion        bumped on any change (poses too; parts IN HAND don't
--                       bump it until they are put down). structVersion: only
--                       topology (parts and links).
--   partUids()          the uids on the stand, sorted.
--   partRec(uid)        a fresh copy: { uid, id, def, x,y,z, yaw,pitch,roll, B,
--                       size, sym, mir, parent, att, an, wcfg, links = { {id, a,
--                       b, k, sa, sb, pa, pb, n, s, prim}… }, hidden, root,
--                       loose, landed }. k ∈ stack surface splice corner tee
--                       cross brace weld decouple hinge piston rotor.
--   selection() (primary last) · selectionPrimary() · select(uids, mode)
--                       mode "set"|"add"|"toggle"|"remove" (shadows Lua's
--                       builtin `select` in this file) · selectAll() ·
--                       selectInvert() · selectConnected(uid, "assembly"|
--                       "craft"|"ring"|"same")
--   hovered() · held() → { ids… } · holding() → "part"|"carry"|"paste"|nil
--   stats()             { parts, mass, dry, cost, thrust, dv, twr, hop, stages,
--                       com, comDry, cot, launch, islands, loose, version };
--                       cached per craftVersion (≤ 2 a second during a drag).
--   frame()             the adapter: identity, node, toLocal/toWorld/
--                       dirToLocal/dirToWorld(x,y,z) (. or :), ray(mx,my).
--   root() · links(uid) · dependents(uids) · components() · separation(uid) ·
--   hingeLocked(uid) · rayCraft(ox,oy,oz,dx,dy,dz) → uid,t,x,y,z,nx,ny,nz
--   currentTool() "select"|"offset"|"rotate"|"root"|"stage"|"groups" ·
--   setTool(name) · gizmoSpace()/setGizmoSpace("local"|"world") ·
--   snapGrid()/setSnapGrid(m) · snapAngle()/setSnapAngle(rad) · setSym(n) ·
--   setMirror(on, "host"|"center") · mirrorPlane() · testMode()/
--   setTestMode(on) · overlayMode()/setOverlayMode(0..3) · attachRules()/
--   setAttachRules("wp3"|"legacy") · drawingTool() · loadProgress() ·
--   frameMs() · perfCounters() · hiddenUids() · outliner() · hintText() ·
--   controlsData()/setControls(t)/controlsCtx() · partNode(uid)
--
-- COMMANDS cmd(name, args) — one history step each (args.merge folds a drag)
--   place move rotate delete(only=) setWcfg insert detach link unlink
--   setParam root group rename hide unhideAll isolate mirror
--   bind unbind bindAxis (→ scripts/controls.lua with controlsCtx())
--   hold(spec)  part id | { uid… } (with dependents) | sub-assembly name |
--               a blueprint fragment
--   copy(uids) · paste() · duplicate(uids) · clipboard()
--   undoStep() · redoStep() · canUndo() · canRedo() · historyList() ·
--   historyJump(i)   (500 steps)
--   craftList() · craftName() · craftSave(name) · craftOpen(name, "replace"|
--   "merge") · craftNew() · craftDelete(name) · subAssemblies() ·
--   makeSubAssembly(name, uids) · subAssembly(name) · reload()
--
-- UI PLUMBING
--   registerPanel(s)    s.ownsMouse() → the builder does no picking while
--                       true; s.ownsKeys() → no builder keys while true.
--   hint(msg, secs) · placard(msg, kind, secs) (→ builder_statusbar.
--   showPlacard when present) · setLaunchSite(site)
--
-- KEYS (§4.3): W/S A/D Q/E turn the held part or the selection (RMB = the
-- camera's), Space reset, R spin, 1–4 tools, L space, X/Shift+X symmetry, M
-- mirror (Alt+M centre plane), G grid / Shift+G angle snap, T test, V overlays,
-- H / Alt+H / Shift+H hide, B bind (builder_bind.begin), N beam tool, [ ]
-- profile, Ctrl+Z/Y undo/redo, Ctrl+C/V/D, Del (Alt+Del only the selection),
-- Ctrl+S/O/N, Ctrl+F or /, Tab, arrows nudge, Esc backs out ONE level and
-- never leaves (Ctrl+Q twice leaves).
--
-- The part registry (REG, DESC, CATALOGUE) is scripts/parts_registry.lua
-- (WP3); registryIds(), catalogue() and partInfo(id) still answer from here.
-- ════════════════════════════════════════════════════════════════════════════
--
-- SHIP BUILDER v1.3 (game roadmap SC1) — free placement, free ORIENTATION,
-- radial mounts + SYMMETRY, precise editing. A ship is just the connected
-- part graph; any part (or the whole ship) moves freely; the blueprint is
-- self-contained (the launch site never needs this registry).
--
--   catalogue button   pick up a part (ghost follows the cursor)
--     click            place — ONLY on a highlighted attach node (green tie
--                      line); hold ALT to place free (red halo = overlapping,
--                      refused). The first part places freely on the pad.
--     W/S A/D Q/E      pitch / yaw / roll 90° (SHIFT 15°), about the CAMERA's
--                      view or the PART's own axes (C switches; see ROTATING)
--     R / SHIFT+R      spin 15° / 5° about the face it mounts on
--     SPACE            reset its turn to how the mount stands it
--     X / SHIFT+X      SYMMETRY off ×2 ×3 ×4 ×6 ×8 — a radial placement
--                      repeats around the host's axis (boosters in one click);
--                      the mode is always on screen, bottom centre
--     ESC              put the part back
--   click a placed part      pick it (and everything stacked on it) back up
--                            (a SYMMETRY member brings its whole ring)
--   hover a placed part      arrows nudge it (SHIFT = fine; ↑/↓ vertical,
--                            ←/→ screen-horizontal, ALT+←/→ depth)
--                            R / SPACE (and W/A/S/D/Q/E in the rotate tool)
--   DEL (hovering)           scrap a part + its stack (a symmetry member
--                            scraps the whole ring)
--   G                        grab the WHOLE ship; click sets it down
--   CTRL+Z undo   ·   CTRL+S save   ·   F5 reload
--
-- RADIAL MOUNTS: parts with side nodes (pod, tanks, radial decoupler) show
-- extra rings on their flanks — anything can snap there, side-by-side at the
-- same height: side boosters, outriggers, wheels-on-a-sideways-ship. The
-- radial decoupler is the separator: at staging its whole outboard branch
-- (parent links) kicks away laterally.
--
-- SYMMETRY: with ×N up, one radial placement rings N copies around the host
-- (ghost previews show all of them). With symmetry ON, anything stacked ON a
-- symmetry member — a tank on one radial decoupler, an engine under one
-- booster — goes onto every other member of that ring too; with it OFF it is
-- just one part (symCopies: it depends on the mode NOW, not on how the host
-- was placed). Rings are edited as one: pick one up and the ring comes with
-- it, scrap one and the ring goes, turn one and they all turn.
--
-- All clicks are edge-detected IN-SCRIPT (input snapshots can serve two
-- frames at uneven fps — raw `input.clicked` double-fires a pickup into an
-- instant re-place, which reads as "selection doesn't work").

defaults = {
  snap_px = 52.0,     -- screen px within which an attach node captures the ghost
  floor_y = 0.11,     -- top of the pad
  nudge = 0.1,        -- precise-edit step (SHIFT = a quarter of this)
}

-- The API's hint (see the top). Declared HERE, before `local function hint`
-- below, so it lands on the script's globals; inside this file every later
-- `hint(…)` is the local one.
function hint(msg, secs) return hintNow(msg, secs or 2.5) end

-- ── Builder audio (non-spatial UI clicks) ────────────────────────────────────
-- Every build action gets a crisp click on the UI mixer bus. Kenney CC0 clips.
local UI_SFX = {
  place  = "audio/foley/clamp_clunk.ogg",
  pickup = "audio/foley/hiss_cylinder.ogg",
  scrap  = "audio/foley/steel_drop.ogg",
  tool   = "audio/foley/switch_3.ogg",
  save   = "audio/foley/key_strike.ogg",
  launch = "audio/foley/latch_clunk.ogg",
}
-- Take a KEY (into UI_SFX), not a clip path, so callers don't each capture
-- UI_SFX as an upvalue — `update` is already near LuaJIT's 60-upvalue ceiling.
local function ui(key, vol)
  if not audio then return end
  audio.play(UI_SFX[key] or key, { track = "UI", volume = vol or 1.0 })
end

-- ── Part registry: scripts/parts_registry.lua (WP3) ─────────────────────────
-- REG, DESC and CATALOGUE live in the pure rulebook script on the scene's
-- PartsRegistry manager node, reached with findScript("parts_registry"). The
-- builder never copies it: `REG` below is a read-through view of that table,
-- resolved on first use (script start order doesn't matter), so `REG[id]` and
-- `REG.chute` read exactly as they did when the table lived here. Wheel
-- settings (WCFG_*) and every placement rule stay in this file.
local REGISTRY = { reg = nil, lib = nil, aero = false, asked = false, auto = false, auto_asked = false }
local function registry()
  local R = REGISTRY
  if not R.reg then
    local lib = findScript and findScript("parts_registry") or nil
    if lib and lib.REG then R.lib, R.reg = lib, lib.REG end
  end
  -- THE AIRCRAFT PARTS (scripts/parts_aero.lua, on the AeroLib node beside
  -- scripts/aero.lua): joined once through parts_registry.extend. A scene
  -- with no AeroLib node gets one spawned; until it is up the catalogue simply
  -- has no AIRCRAFT section yet.
  if R.lib and not R.aero then
    local pa = findScript and findScript("parts_aero") or nil
    if pa and pa.register and R.lib.extend then
      R.lib.extend(pa)
      R.aero = true
    elseif not pa and not R.asked and spawn then
      R.asked = true
      pcall(spawn, "AeroLib", vec3(0, 0, 0))
    end
  end
  -- THE AUTO-ENGINEERING PARTS (scripts/parts_auto.lua on the AutoLib node,
  -- docs/auto-engineering.md): the moto wheel, fork, swing arm, strut and
  -- gyro, joined the same way into the ROVER section.
  if R.lib and not R.auto then
    local pu = findScript and findScript("parts_auto") or nil
    if pu and pu.register and R.lib.extend then
      R.lib.extend(pu)
      R.auto = true
    elseif not pu and not R.auto_asked and spawn then
      R.auto_asked = true
      pcall(spawn, "AutoLib", vec3(0, 0, 0))
    end
  end
  return R.lib
end
local REG = setmetatable({}, { __index = function(_, id)
  local R = REGISTRY
  if not R.reg then registry() end
  return R.reg and R.reg[id] or nil
end })

-- Every part this builder knows how to spawn (parts_registry.registryIds).
function registryIds()
  local lib = registry()
  return lib and lib.registryIds() or {}
end

-- The catalogue panel asks for this: sections, each with the parts it holds
-- (parts_registry.catalogue: ids with no entry in REG are dropped).
function catalogue()
  local lib = registry()
  return lib and lib.catalogue() or {}
end

-- ── WP1 rulebooks: builder_graph, builder_space, builder_history ───────────
-- Pure scripts on the BuilderGraph manager node (findScript). Under luajit
-- (the smoke harnesses) they are loaded from disk instead, so a harness needs
-- no wiring. Their functions are copied into LIB once: a handle lookup per
-- call would cost a crossing into the host every time.
local LIB = {}
local function lib(kind)
  local m = LIB[kind]
  if m then return m end
  local h = findScript and findScript(kind) or nil
  if h and h.valid == false then h = nil end
  if not h and loadfile and setfenv then
    local f = loadfile("solar/scripts/" .. kind .. ".lua") or loadfile("scripts/" .. kind .. ".lua")
    if f then
      local e = setmetatable({}, { __index = _G })
      setfenv(f, e)
      f()
      h = e
    end
  end
  if not h then return nil end
  LIB[kind] = h
  return h
end

-- ── State ───────────────────────────────────────────────────────────────────
local parts = {}        -- uid -> { id, def, node, x,y,z, yaw,pitch,roll, parent (uid|nil) }
local next_uid = 1
local ghost = nil       -- { id, def, node, yaw,pitch,roll [, carried, from_uid] }
local pending_spawns = 0
-- WP1 state in ONE table (the main chunk is near LuaJIT's 200-local limit):
--   G        the links graph (builder_graph.newGraph)
--   H        the spatial hash of part AABBs (builder_space.newHash)
--   F        the frame adapter (builder_space.newFrame)
--   hist     the history (builder_history.newHistory(500))
--   sel      selection set uid → true ; sel_order list (primary last)
--   sv       structVersion (topology) ; dirty (stats) ; queue (spawns)
--   caches   per-version caches
local W = { G = nil, H = nil, F = nil, hist = nil, sel = {}, sel_order = {}, sv = 0,
            dirty = true, dirty_t = 0, queue = {}, qhead = 1, budget = 60, cache = {},
            root = nil, hidden = {}, grid = 0.05, angle = math.pi / 12, space = "world",
            test = false, overlay = 1, visits = 0, outliner = {}, controls = nil,
            clip = nil, craft = nil, attach = "auto", load_total = 0, vis = nil,
            press = nil, last_click = nil, box = nil, bynode = {} }
structVersion = 0
local hover_uid = nil
local stats_node, hint_node
local hint_t = 0        -- seconds a transient hint stays up

-- Edge-detected mouse + a short cooldown so one physical click never both
-- picks up AND re-places.
local lmb_prev = false
local click_cool = 0

-- Published (builder_camera frames the ship with these).
centerX, centerY, centerZ = 0.0, 1.5, 0.0
partCount = 0
craftVersion = 0        -- API: bumped on every change to the craft (see the top)

-- ── Symmetry state ──────────────────────────────────────────────────────────
-- sym_n is the ×N mode (X cycles it); parts placed as a ring share a `sym`
-- group id, and children stacked on a ring member auto-mirror into their own
-- ring (chained groups). Group geometry is DERIVED, never stored: a ring's
-- HUB is the members' common parent (first generation) or, for a chained
-- ring, the hub of the parent ring — so save/load only needs the id.
local SYM_STEPS = { 1, 2, 3, 4, 6, 8 }
local sym_n = 1
local next_sym = 0

-- ── Staging order ───────────────────────────────────────────────────────────
-- Stage ITEMS are separation events: each axial decoupler is one; a radial-
-- decoupler RING (symmetry group) is ONE bundled item. `stage_order` lists
-- item keys in FIRING order (row 1 fires first); drag rows in the STAGING
-- panel to reorder. Persisted per-part (`stage`) in the blueprint — flight
-- fires the events in exactly this order.
local stage_order = {}   -- array of keys: "u<uid>" | "g<sym gid>"
local stage_hover = nil  -- stage-panel row the cursor is over (world highlight)
local stage_node2 = nil  -- the StagePanel UI node
local stage_rows = nil   -- cached array of the StageRow## UI nodes
local stage_ghost = nil  -- the StageDragGhost UI node (follows the cursor)
local saved_stage = {}   -- uid → stage index from a loaded blueprint
local STAGE_MAX_ROWS = 14 -- size of the StageRow## pool authored in builder.ron

-- ── Tools & selection ───────────────────────────────────────────────────────
-- Clicking a part SELECTS it (it doesn't grab/move) — hovering only previews
-- what a click would select. The active TOOL decides what the selection's
-- gizmo does: 1 = Move (arrows), 2 = Rotate (rings), 3 = Stage (numbered
-- decoupler badges + the staging panel), 4 = Grab (pick the part up to
-- re-attach it elsewhere). Switching tools never changes the selection, and
-- editing never changes the selection — no more "moving the wrong thing".
-- 1 SELECT · 2 OFFSET · 3 ROTATE · 4 ROOT (§4.1, the KSP numbering) · 5 MOVE
-- (internally "lift": click a placed part to pick it up with what hangs on
-- it, click to put it down; "move" is the old alias of OFFSET); STAGE and
-- GROUPS are right-panel tabs now, reached through setTool().
local TOOLS = { "select", "offset", "rotate", "root", "lift", "stage", "groups" }
local TOOL_LABEL = { select = "SELECT", offset = "OFFSET", rotate = "ROTATE", root = "ROOT", lift = "MOVE",
                     stage = "STAGE", groups = "ACTION GROUPS" }
local tool = "select"
local selected_uid = nil

-- ── MULTI-SELECTION (WP1, §4.2) ─────────────────────────────────────────────
-- W.sel is the set, W.sel_order the order it was built (the PRIMARY — the
-- gizmo's pivot, the inspector's part — is the last). `selected_uid` stays
-- the primary, which is what every single-part rule here reads.
local function sel_apply(list, mode)
  mode = mode or "set"
  local S, O = W.sel, W.sel_order
  if mode == "set" then
    S, O = {}, {}
    W.sel, W.sel_order = S, O
    mode = "add"
  end
  for _, u in ipairs(list) do
    if parts[u] then
      local on = S[u]
      local want = (mode == "add") or (mode == "toggle" and not on)
      if mode == "remove" then want = false end
      if want and not on then S[u] = true; O[#O + 1] = u
      elseif want and on then
        -- re-adding moves it to primary
        for i = #O, 1, -1 do if O[i] == u then table.remove(O, i) end end
        O[#O + 1] = u
      elseif not want and on then
        S[u] = nil
        for i = #O, 1, -1 do if O[i] == u then table.remove(O, i) end end
      end
    end
  end
  selected_uid = O[#O]
  W.sel_v = (W.sel_v or 0) + 1
  if W.hist then W.hist:seal() end
end
local function sel_only(u) sel_apply(u and { u } or {}, "set") end

-- ── Electronics & action groups ─────────────────────────────────────────────
-- The rulebook (scripts/electronics.lua) is a script on the scene's manager
-- node; nil in a harness without it, and then the builder simply has no power
-- readout and no groups editor rather than failing.
local elib_ref = nil
local function elib()
  if not elib_ref or not elib_ref.valid then
    elib_ref = findScript and findScript("electronics") or nil
  end
  return elib_ref
end

-- Every electronics module a part carries: the ones REG declares plus the ones
-- its flags imply (an engine's alternator, a decoupler's Decouple…).
local function part_mods(def)
  local E = elib()
  if E then return E.deriveMods(def, def.mods) end
  return def.mods
end

-- The craft's ACTION GROUPS while it's on the stand. `groups` stays nil until
-- the player edits one: until then the editor (and the flight) shows the
-- standard set built from what is aboard, so adding a solar panel puts it on
-- Deploy without anyone asking. `gid` is the group the editor has open.
local groups_state = { groups = nil, edited = false, gid = "1" }

-- The craft as blueprint-shaped records (uid → { uid, id, mods, … }), which
-- is what every electronics question is asked about.
local function craft_records()
  local out = {}
  for uid, p in pairs(parts) do
    local d = p.def
    out[uid] = { uid = uid, id = p.id, label = d.label, kind = d.kind, mods = part_mods(d),
                 legs = d.legs and 1 or 0, decouple = d.decouple and 1 or 0,
                 chute = d.chute and 1 or 0, rcs = d.rcs and 1 or 0, dock = d.dock and 1 or 0,
                 thrust = d.thrust or 0, sym = p.sym, parent = p.parent, af = d.af }
  end
  return out
end

local function hint(msg, secs)
  if hint_node then hint_node.text = msg end
  W.hint_text = msg
  hint_t = secs or 2.5
end

-- The full key list is on the pause menu's Controls page; the idle line only
-- has to say how to start and how to leave (this scene has no pause menu: ESC
-- leaves it).
local HINT_IDLE = "click to select · drag to move (ALT only this) · drag empty space to box-select   ·   1 select · 2 offset · 3 rotate · 4 root · 5 move   ·   CTRL+Z/Y undo/redo · CTRL+C/V/D"
local HINT_GHOST = "click a node or any surface to place (SHIFT keeps a copy)   ·   the floor places free   ·   W/S A/D Q/E rotate · R spin · SPACE reset   ·   X symmetry · M mirror   ·   ESC drop"

-- The craft's centre and part count. Cheap now: called from the dirty-flag
-- refresh (at most once a frame), never from a spawn callback.
local function center_now()
  if not W.center_dirty then return end
  W.center_dirty = false
  local n, sx, sy, sz = 0, 0.0, 0.0, 0.0
  for _, p in pairs(parts) do
    n = n + 1; sx = sx + p.x; sy = sy + p.y; sz = sz + p.z
  end
  partCount = n
  if n > 0 then centerX, centerY, centerZ = sx / n, sy / n, sz / n
  else centerX, centerY, centerZ = 0.0, 1.5, 0.0 end
end
local function publish_center()
  craftVersion = craftVersion + 1
  W.dirty = true
  W.center_dirty = true
end

-- Topology changed (a part came or went, a link was made or cut).
local function struct_changed()
  W.sv = W.sv + 1
  structVersion = W.sv
  craftVersion = craftVersion + 1
  W.dirty = true
end

-- The graph, the hash and the frame, made on first use.
local function graph()
  if not W.G then
    local L = lib("builder_graph")
    W.G = L and L.newGraph() or nil
  end
  return W.G
end
local function alive_set()
  local c = W.cache
  if c.alive_v ~= W.sv then
    local s = {}
    for u in pairs(parts) do s[u] = true end
    c.alive, c.alive_v = s, W.sv
  end
  return c.alive
end
local function is_command(u)
  local p = parts[u]
  return p ~= nil and (p.def.kind == "crewed" or p.def.kind == "probe")
end
-- The craft root: the one set with tool 4 (cmd root), else the lowest-uid
-- command part, else the lowest uid with no primary link.
local function craft_root()
  if W.root and parts[W.root] then return W.root end
  local c = W.cache
  if c.root_v == W.sv then return c.root end
  local best, free
  for u, p in pairs(parts) do
    if is_command(u) and (not best or u < best) then best = u end
    if not p.parent and (not free or u < free) then free = u end
  end
  c.root, c.root_v = best or free, W.sv
  return c.root
end
-- dependents of a set (uid → true), cached per structVersion and set.
local function deps_of(set)
  local G, L = graph(), lib("builder_graph")
  if not (G and L) then return {} end
  local keys = {}
  for u in pairs(set) do keys[#keys + 1] = u end
  table.sort(keys)
  local k = table.concat(keys, ",")
  local c = W.cache
  if c.deps_v ~= W.sv then c.deps, c.deps_v = {}, W.sv end
  local hit = c.deps[k]
  if hit then return hit end
  hit = L.dependents(G, alive_set(), set, craft_root(), is_command)
  c.deps[k] = hit
  return hit
end

-- Everything that comes along with `uid` (it and its dependents): what the
-- old parent-tree `subtree` was, asked of the graph.
local function subtree(uid)
  local out = { [uid] = true }
  for u in pairs(deps_of({ [uid] = true })) do out[u] = true end
  return out
end

-- Everything reachable from `from` without passing `via` (what stands on a
-- fairing base's top, a booster beyond its decoupler).
local function beyond_of(from, via)
  local G, L = graph(), lib("builder_graph")
  if not (G and L) then return { [from] = true } end
  return L.beyond(G, alive_set(), from, via)
end

-- What a decoupler throws off (it included); just itself when a loop keeps it on.
local function separation_of(uid)
  local G, L = graph(), lib("builder_graph")
  if G and L then
    local far = L.separation(G, alive_set(), uid, craft_root())
    if far then return far end
    local p = parts[uid]
    if p and p.parent then return L.beyond(G, alive_set(), uid, p.parent) end
  end
  return subtree(uid)
end

-- The AABB of a part (local frame): the larger of its registry box and its
-- drawn box, under its turn.
local function part_box(p)
  local d = p.def
  local hx, hy, hz = d.rx, d.h * 0.5, d.rz
  if visHalf then
    local a, b, c = visHalf(p.id, d)
    hx, hy, hz = math.max(hx, a), math.max(hy, b), math.max(hz, c)
  end
  local cy, sy = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  local cx, sx = math.cos(p.pitch or 0), math.sin(p.pitch or 0)
  local cz, sz = math.cos(p.roll or 0), math.sin(p.roll or 0)
  local Xx, Xy, Xz = cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz
  local Yx, Yy, Yz = -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz
  local Zx, Zy, Zz = sy * cx, -sx, cy * cx
  local ex = math.abs(Xx) * hx + math.abs(Yx) * hy + math.abs(Zx) * hz
  local ey = math.abs(Xy) * hx + math.abs(Yy) * hy + math.abs(Zy) * hz
  local ez = math.abs(Xz) * hx + math.abs(Yz) * hy + math.abs(Zz) * hz
  return ex, ey, ez
end
local function hash_put(uid, p)
  if not W.H or p.carried then return end
  local ex, ey, ez = part_box(p)
  W.H:set(uid, p.x - ex, p.y - ey, p.z - ez, p.x + ex, p.y + ey, p.z + ez)
end

-- A part in hand (p.carried) is a preview: its moves don't bump craftVersion
-- (panels would rebuild every frame of a drag); putting it down does.
local function set_part_pos(p, x, y, z)
  if not p.carried then craftVersion = craftVersion + 1; W.dirty = true end
  p.x, p.y, p.z = x, y, z
  p.pv = (p.pv or 0) + 1
  if p.node then p.node.x, p.node.y, p.node.z = x, y, z end
  if p.uid then hash_put(p.uid, p) end
end

local function set_part_rot(p, yaw, pitch, roll)
  if p.yaw == yaw and p.pitch == pitch and p.roll == roll then return end
  if not p.carried then craftVersion = craftVersion + 1; W.dirty = true end
  p.yaw, p.pitch, p.roll = yaw, pitch, roll
  p.pv = (p.pv or 0) + 1
  if p.node then p.node.yaw, p.node.pitch, p.node.roll = yaw, pitch, roll end
  if p.uid then hash_put(p.uid, p) end
end

-- ── Orientation math ────────────────────────────────────────────────────────
-- Engine euler order is YXZ (yaw, pitch, roll). rot_basis returns the world
-- columns of the part's local X/Y/Z axes; eff_extents the axis-aligned
-- half-extents of the part's (rx, h/2, rz) box under that rotation — what
-- snapping and overlap tests need once parts can lie on their sides.
local function rot_basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  local X = { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz }
  local Y = { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz }
  local Z = { x = sy * cx, y = -sx, z = cy * cx }
  return X, Y, Z
end

local function eff_extents(def, yaw, pitch, roll)
  local X, Y, Z = rot_basis(yaw, pitch, roll)
  local hx, hy, hz = def.rx, def.h * 0.5, def.rz
  return math.abs(X.x) * hx + math.abs(Y.x) * hy + math.abs(Z.x) * hz,
         math.abs(X.y) * hx + math.abs(Y.y) * hy + math.abs(Z.y) * hz,
         math.abs(X.z) * hx + math.abs(Y.z) * hy + math.abs(Z.z) * hz
end

local function part_extents(p)
  return eff_extents(p.def, p.yaw, p.pitch, p.roll)
end

-- ── Symmetry geometry ───────────────────────────────────────────────────────
-- Rotate world vector (vx,vy,vz) about the hub part's stack axis by `a`.
local function rot_about(hub, vx, vy, vz, a)
  local e1, ax, e2 = rot_basis(hub.yaw, hub.pitch, hub.roll)
  local d = vx * ax.x + vy * ax.y + vz * ax.z
  local px, py, pz = vx - ax.x * d, vy - ax.y * d, vz - ax.z * d
  local c1 = px * e1.x + py * e1.y + pz * e1.z
  local c2 = px * e2.x + py * e2.y + pz * e2.z
  local ca, sa = math.cos(a), math.sin(a)
  local r1 = c1 * ca - c2 * sa
  local r2 = c1 * sa + c2 * ca
  return e1.x * r1 + e2.x * r2 + ax.x * d,
         e1.y * r1 + e2.y * r2 + ax.y * d,
         e1.z * r1 + e2.z * r2 + ax.z * d
end

-- A part's angle around the hub's axis (for mapping ring member → member).
local function angle_about(hub, p)
  local e1, ax, e2 = rot_basis(hub.yaw, hub.pitch, hub.roll)
  local vx, vy, vz = p.x - hub.x, p.y - hub.y, p.z - hub.z
  local d = vx * ax.x + vy * ax.y + vz * ax.z
  local px, py, pz = vx - ax.x * d, vy - ax.y * d, vz - ax.z * d
  return math.atan2(px * e2.x + py * e2.y + pz * e2.z,
                    px * e1.x + py * e1.y + pz * e1.z)
end

-- Ring / mirror-pair members, from an index rebuilt once per structVersion
-- (sym ids only change when parts come and go).
local function group_members(gid)
  local c = W.cache
  if c.sym_v ~= W.sv then
    local idx = {}
    for uid, p in pairs(parts) do
      if p.sym then
        local t = idx[p.sym]
        if not t then t = {}; idx[p.sym] = t end
        t[#t + 1] = uid
      end
    end
    for _, t in pairs(idx) do table.sort(t) end
    c.sym, c.sym_v = idx, W.sv
  end
  local out = {}
  for i, u in ipairs(c.sym[gid] or {}) do out[i] = u end
  return out
end

-- The ring's HUB part: first generation rings share a parent (the hub);
-- a chained ring (children mirrored onto ring members) inherits the hub of
-- its parents' ring. Bounded walk — malformed links return nil safely.
local function group_hub(gid, depth)
  depth = (depth or 0) + 1
  if depth > 8 then return nil end
  local members = group_members(gid)
  if #members == 0 then return nil end
  local first_parent = parts[members[1]] and parts[members[1]].parent
  if not first_parent then return nil end
  local shared = true
  for _, u in ipairs(members) do
    if not parts[u] or parts[u].parent ~= first_parent then shared = false break end
  end
  if shared then return parts[first_parent] end
  local pp = parts[first_parent]
  if pp and pp.sym then return group_hub(pp.sym, depth) end
  return nil
end

-- The EDIT SET for a part: its subtree — and, for a symmetry-ring member,
-- every member's subtree. Rings pick up, scrap and highlight as ONE.
local function edit_set(uid)
  local p = parts[uid]
  if not (p and p.sym) then return subtree(uid) end
  local out = {}
  for _, m in ipairs(group_members(p.sym)) do
    for u in pairs(subtree(m)) do out[u] = true end
  end
  return out
end

-- ── Stats + staging readout ─────────────────────────────────────────────────
-- Stages mirror the FLIGHT model exactly: SPACE fires the lowest remaining
-- decoupler and everything at/below it detaches, and only the BOTTOM live
-- stage's engines burn (everything above the next decoupler waits its turn).
-- Stage k = the stack above the k-th decoupler, thrusting on the engines
-- between decouplers k and k+1 and drinking the tanks between them first:
-- the flight drains the tanks that leave SOONEST first (boosters, then the
-- bottom stage, upward), so a stage's Δv is its own tanks burned under
-- everything it still carries.
--
-- ── BALANCE: real rocket physics, scaled to these worlds ───────────────────
--
-- PROPELLANT HAS MASS. A fuel unit is FUEL_T_PER_UNIT tonnes (10 kg): a full
-- FT-S is 0.8 t of propellant in a 0.2 t tank. An engine burns thrust / ve
-- tonnes a second (`burn` is that in units), so the Δv is Tsiolkovsky's,
--
--     Δv = ve · ln(m_wet / m_dry)
--
-- and the flight flies the same thing: vessel_controller gives every part's
-- rigidbody its catalogue mass plus the propellant it still holds, so physics
-- flies the craft's live wet mass — a full stack climbs slowly and an emptying
-- one accelerates (the part prefabs carry the same dry masses as REG). A
-- second tank is not twice the Δv of one — it has to lift the first — which
-- is the diminishing return every real rocket lives with, and why staging
-- exists. Legs, chutes, cones and fins are tens of kilos.
--
-- ONE CATALOGUE PER SAVE. Worlds are generated 100–300 m across with 4.5–15 m/s²
-- of gravity, so escape runs from ~30 m/s to ~85, and no single set of engine
-- figures works across that: a Sputter that lifts the starter on a 15 g world
-- sends it out of a 4.5 g world's sphere of influence in three seconds. So the
-- parts are BUILT FOR THE HOME WORLD, once, the first time the save sees it:
--
--   thrust × g_home / G_REF       every craft has the same TWR on every save
--   ve     × (solved once)        the stock starter (Pod, Parachute, FT-S,
--                                 Sputter) flown straight up at full throttle
--                                 peaks at HOP_MULT × the First Flight's height
--
-- That is frozen in the save (`parts.rating`) and is what every catalogue card,
-- every readout and every flight uses: the same Sputter is exactly as strong on
-- a moon, another planet or the next launch. Nothing is re-rated at the pad and
-- nothing is hidden — the card prints the thrust and ve you fly with. Masses and
-- fuel loads never scale. (Burns are short because the worlds are: the natural
-- time of a world this size, sqrt(r/g), is about five seconds, and a hop to
-- twice its radius takes a few of them at full throttle.)
FUEL_T_PER_UNIT = 0.01
local G_REF = 7.0
-- The starter's full-throttle hop, as a multiple of the First Flight's height
-- (and never under HOP_MIN): enough margin that legs or a nose cone don't cost
-- the contract, and well short of The High Road (3.7× the First Flight).
HOP_MULT = 1.8
HOP_MIN = 220.0
-- RATING VERSIONS. A save is rated once, at the version current then, and keeps
-- it: its catalogue (and so every craft it builds) never changes under it.
--   2  every engine the same in air and vacuum (REG's own thrust and ve)
--   3  (2026-10-24) ENGINE NICHES: vacuum figures and a sea-level share per
--      engine (parts_registry RATED / `nozzle`) — Sputter the lander, Anvil
--      the upper stage, Skipper the lifter. A blueprint carries `asl`, and
--      vessel_controller scales its thrust by the air it is flying in.
-- A save rated at any version listed in RATING_KEEP keeps it; anything older
-- (or unrated) is rated at RATING_VERSION.
RATING_VERSION = 3
RATING_KEEP = { [2] = true, [3] = true }
local STARTER = { "pod", "chute", "tankS", "engineS" }

function launchWorld()
  local w = save.get("launch.world")
  if type(w) == "table" and (w.g or 0) > 0 and (w.r or 0) > 0 then
    return { name = w.name, g = w.g, r = w.r, soi = (w.soi or 0) > w.r and w.soi or w.r * 7.5 }
  end
  -- No base yet: a typical home of the save's WORLD SCALE (system_generator
  -- SCALES), so the first readout is the right order of magnitude. Unsaved.
  local gs = tonumber(save.get("g_scale")) or 1
  if gs >= 3 then
    -- scale 3 (system_generator SCALES[3]): planets 600–950 m
    return { name = nil, g = 6.0, r = 775.0, soi = 9600.0 }
  end
  if gs >= 2 then
    return { name = nil, g = 6.0, r = 310.0, soi = 3850.0 }
  end
  return { name = nil, g = G_REF, r = 165.0, soi = 1500.0 }
end

-- The altitude the "Made Orbit" contract asks a periapsis above on world w
-- (missions.lua: 10 % of the room to the edge of the sphere of influence).
function orbitAlt(w)
  w = w or launchWorld()
  local body_r = w.r + math.max(w.r * 0.035, 4)
  local alt = 0.10 * math.max(1, w.soi - body_r)
  -- …and never inside the air (missions.lua target_of): a deep-air world
  -- (scale 4) has air up to a radius high.
  local rec = w.name and save.get("world." .. w.name)
  if type(rec) == "table" and (rec.atmo or 0) > 0.01 and (rec.atmoHeight or 0) * 1.08 > alt then
    alt = rec.atmoHeight * 1.08
  end
  return alt
end

-- Δv to that orbit from the pad, FLOWN WELL: the ideal two-burn climb (a
-- Hohmann ellipse from the ground to the orbit, then the circularisation)
-- plus the gravity a real ascent spends holding itself up — 50 % on these
-- worlds, which the 2-D ascent sim in smoke_balance measures at 40–60 % for
-- TWR 2.8 down to 1.3. What the readout quotes as "orbit needs".
function orbitNeed(w)
  w = w or launchWorld()
  local mu, R = w.g * w.r * w.r, w.r
  local ro = R + orbitAlt(w)
  local vp = math.sqrt(2 * mu * ro / (R * (R + ro)))
  local va = vp * R / ro
  return 1.5 * (vp + (math.sqrt(mu / ro) - va))
end

-- The First Flight's altitude on world w the way missions.lua resolves it
-- (15 % of the room between the body and the edge of its influence; the body
-- radius carries the same margin `system_generator` gives it), unrounded.
function firstFlightAlt(w)
  w = w or launchWorld()
  local body_r = w.r + math.max(w.r * 0.035, 4)
  return 0.15 * math.max(1, w.soi - body_r)
end

-- Where the stock starter is built to peak on world w.
function hopTarget(w)
  return math.max(HOP_MIN, HOP_MULT * firstFlightAlt(w))
end

-- Straight up from the surface at full throttle: thrust T (kN) on a craft of
-- m0 tonnes that burns mf tonnes of propellant at exhaust velocity ve (m/s),
-- lightening as it goes, under inverse-square gravity. Returns the apoapsis
-- ALTITUDE, or math.huge when the craft leaves the sphere of influence. A craft
-- too heavy to lift sits on the pad burning until it isn't (or never lifts).
-- Pure, so the smoke test can fly it too.
function hopApoapsis(T, m0, mf, ve, w)
  w = w or launchWorld()
  local mu, R = w.g * w.r * w.r, w.r
  if m0 <= 0 or T <= 0 or mf <= 0 or ve <= 0 or mf >= m0 then return 0 end
  local mdot = T / ve
  local steps = 600
  local dt = mf / mdot / steps
  local r, v, m = R, 0.0, m0
  for _ = 1, steps do
    local mm = m - 0.5 * mdot * dt         -- the mass at the middle of the step
    v = v + (T / mm - mu / (r * r)) * dt
    if r <= R and v < 0 then v = 0 end
    r = math.max(R, r + v * dt)
    m = m - mdot * dt
  end
  if r <= R and v <= 0 then return 0 end
  local e = 0.5 * v * v - mu / r
  if e >= -mu / w.soi then return math.huge end
  return -mu / e - R
end

-- Escape speed from the surface to the edge of the sphere of influence.
function escapeSpeed(w)
  w = w or launchWorld()
  local mu = w.g * w.r * w.r
  return math.sqrt(math.max(0, 2 * mu * (1 / w.r - 1 / w.soi)))
end

-- An engine's reference figures at rating version v (parts_registry
-- `engineAt`; REG's own for a version with none, or a registry without it).
local function engine_at(d, v)
  local R = registry()
  if R and R.engineAt then
    local f = R.engineAt(d, v)
    if f then return f end
  end
  return { thrust = d.thrust, ve = d.ve or 160, asl = 1 }
end

-- The stock starter on the reference figures (VACUUM — the hop is solved in
-- vacuum, exactly as before nozzles): wet mass, propellant, thrust, ve.
function starter_numbers(v)
  local m0, mf, T, ve = 0.0, 0.0, 0.0, 0.0
  for _, id in ipairs(STARTER) do
    local d = REG[id]
    local f = (d.fuel or 0) * FUEL_T_PER_UNIT
    m0, mf = m0 + d.mass + f, mf + f
    if d.thrust then
      local e = engine_at(d, v or RATING_VERSION)
      T, ve = e.thrust, e.ve
    end
  end
  return m0, mf, T, ve
end

-- { thrust = ×, ve = × } the catalogue is built with for this save (see the
-- header). The first world it is asked about with a NAME is the home world, and
-- its answer is written to the save and never recomputed; until a base exists
-- (no named world) the reference figures stand, unsaved.
local memo_key, memo_val = nil, nil
function rating(w)
  w = w or launchWorld()
  local key = string.format("%s/%.4f/%.3f/%.1f", tostring(w.name), w.g, w.r, w.soi)
  if key == memo_key then return memo_val end
  local saved = w.name and save.get("parts.rating")
  local hit
  if type(saved) == "table" and saved.name == w.name and RATING_KEEP[saved.v]
    and (saved.thrust or 0) > 0 and (saved.ve or 0) > 0 then
    hit = saved
  else
    local kT = w.g / G_REF
    local m0, mf, T, ve = starter_numbers(RATING_VERSION)
    local target = hopTarget(w)
    local lo, hi = 0.05, 20.0
    for _ = 1, 48 do
      local kV = 0.5 * (lo + hi)
      if hopApoapsis(T * kT, m0, mf, ve * kV, w) > target then hi = kV else lo = kV end
    end
    hit = { thrust = kT, ve = 0.5 * (lo + hi), name = w.name, g = w.g, r = w.r,
            soi = w.soi, hop = target, v = RATING_VERSION }
    if w.name then save.set("parts.rating", hit) end
  end
  memo_key, memo_val = key, hit
  return hit
end

-- A part as this save builds it: the registry entry with thrust and ve built
-- for the home world at the save's rating version (VACUUM figures), its
-- nozzle's sea-level share `asl` (version 3 on; nil = the same everywhere),
-- the burn rate that follows (units/s), and a tank's propellant density.
-- Everything else is REG's.
local eff_cache = setmetatable({}, { __mode = "k" })
function liveDef(id)
  local d = type(id) == "table" and id or REG[id]
  if not d then return nil end
  if not (d.thrust or d.fuel) then return d end
  local k = rating()
  local c = eff_cache[d]
  if c and c.kT == k.thrust and c.kV == k.ve and c.v == k.v then return c.def end
  local out = {}
  for key, v in pairs(d) do out[key] = v end
  if d.thrust then
    local e = engine_at(d, k.v)
    out.thrust = e.thrust * k.thrust
    out.ve = (e.ve or 160) * k.ve
    out.asl = (e.asl and e.asl < 1) and e.asl or nil
    if e.desc then out.desc = e.desc end
    out.burn = out.thrust / (out.ve * FUEL_T_PER_UNIT)
  end
  if d.fuel then out.fuel_t = FUEL_T_PER_UNIT end
  eff_cache[d] = { kT = k.thrust, kV = k.ve, v = k.v, def = out }
  return out
end

-- The air at the pad, as σ (density over reference sea level, aero.lua
-- RHO0): the launch world's record (`world.<name>` atmo, as aero.lua `airAt`
-- reads it at the datum), 1 until a base exists, 0 on an airless home.
function padAir(w)
  w = w or launchWorld()
  local rec = w.name and save.get("world." .. w.name)
  if type(rec) == "table" and rec.atmo ~= nil then
    return (rec.atmo or 0) > 0.005 and (rec.atmo / 0.75) or 0.0
  end
  return 1.0
end

-- An engine's share of its vacuum thrust and ve in air σ (parts_registry
-- `nozzle`; 1 for an engine with no asl).
local function nozzle_k(asl, sigma)
  local R = registry()
  if R and R.nozzle then return R.nozzle(asl, sigma) end
  if not asl then return 1.0 end
  return math.max(0.05, 1 - (1 - asl) * math.max(0, sigma or 0))
end

-- Δv of a burn from m0 down to m1 tonnes on engines totalling `th` kN and
-- `burn` units/s (so exhaust velocity th / (burn · FUEL_T_PER_UNIT)).
function burn_dv(th, burn, m0, m1)
  if th <= 0 or burn <= 0 or m1 <= 0 or m0 <= m1 then return 0.0 end
  return th / (burn * FUEL_T_PER_UNIT) * math.log(m0 / m1)
end

-- THE NUMBERS, as data: what each SPACE leaves burning, with the thrust and burn
-- rate the blueprint will carry into flight. Global and pure (reads `parts`,
-- returns tables) so the smoke test reads the figures rather than scraping them
-- back out of the panel text. Masses are WET (dry + propellant aboard).
--
--   boosters  { n, m, th, fu, m0, dv, twr, tb }  or nil — lit with stage 1,
--             their tanks drunk first, then thrown away
--   stages    { { k, m, th, burn, fu, dv, twr, tb } … }  firing order
--   dv        the total
--   twr       lift-off TWR (boosters and stage 1 together)
--   hop       apoapsis altitude for Z + SPACE straight up, never staging
--             (math.huge = escape)
--   world     the launch world the figures are for
function stageStats()
  local w = launchWorld()
  local U = FUEL_T_PER_UNIT
  -- SEA LEVEL: the same burn in the pad's air (padAir), where a vacuum
  -- nozzle gives less thrust and ve. `th`, `dv`, `twr` stay the VACUUM
  -- figures; `th_sl`, `dv_sl`, `twr_sl` are the pad's.
  local sig = padAir(w)
  local booster_uids = {}
  local n_boost = 0
  for uid, p in pairs(parts) do
    if p.def.radial then
      n_boost = n_boost + 1
      -- the booster: what this decoupler throws off (the graph's separation:
      -- its far side once its links to the root side are cut)
      for u in pairs(separation_of(uid)) do booster_uids[u] = true end
    end
  end
  local out = { stages = {}, world = w, dv = 0.0, dv_sl = 0.0, air = sig }
  local cuts = {}
  for _, p in pairs(parts) do
    if p.def.decouple and not p.def.radial then cuts[#cuts + 1] = p.y end
  end
  table.sort(cuts)
  local raw, fu_all = {}, 0
  for k = 0, #cuts do
    local lo = (k == 0) and -math.huge or cuts[k]
    local hi = cuts[k + 1] or math.huge
    local s = { m = 0.0, th = 0.0, th_sl = 0.0, burn = 0.0, fu = 0 }
    for uid, p in pairs(parts) do
      if not booster_uids[uid] and p.y > lo + 0.01 then
        local d = liveDef(p.def)
        s.m = s.m + d.mass + (d.fuel or 0) * U
        if p.y < hi - 0.01 then
          s.fu = s.fu + (d.fuel or 0)
          if (d.thrust or 0) > 0 then
            s.th = s.th + d.thrust
            s.th_sl = s.th_sl + d.thrust * nozzle_k(d.asl, sig)
            s.burn = s.burn + (d.burn or 0)
          end
        end
      end
    end
    fu_all = fu_all + s.fu
    raw[k] = s
  end
  local s1 = raw[0]
  local bm, bth, bth_sl, bburn, bfu = 0.0, 0.0, 0.0, 0.0, 0
  if n_boost > 0 then
    for u in pairs(booster_uids) do
      local p = parts[u]
      if p then
        local d = liveDef(p.def)
        bm = bm + d.mass + (d.fuel or 0) * U
        bfu = bfu + (d.fuel or 0)
        bth = bth + (d.thrust or 0)
        bth_sl = bth_sl + (d.thrust or 0) * nozzle_k(d.asl, sig)
        bburn = bburn + (d.burn or 0)
      end
    end
    -- The core's stage-1 engines burn alongside, drinking the boosters' tanks
    -- first (the flight drains the tanks that leave soonest first).
    local m0 = s1.m + bm
    local th, burn = bth + s1.th, bburn + s1.burn
    local th_sl = bth_sl + s1.th_sl
    out.boosters = { n = n_boost, m = bm, th = bth, fu = bfu, m0 = m0,
                     dv = burn_dv(th, burn, m0, m0 - bfu * U),
                     twr = (th > 0) and th / (m0 * w.g) or 0,
                     dv_sl = burn_dv(th_sl, burn, m0, m0 - bfu * U),
                     twr_sl = (th_sl > 0) and th_sl / (m0 * w.g) or 0,
                     tb = (burn > 0) and bfu / burn or 0 }
    out.dv = out.dv + out.boosters.dv
    out.dv_sl = out.dv_sl + out.boosters.dv_sl
    fu_all = fu_all + bfu
  end
  for k = 0, #cuts do
    local s = raw[k]
    if k == 0 or s.th > 0 or s.fu > 0 then
      -- A stage with no engine gets no Δv, which is the correct answer and the
      -- one that catches "I forgot to put an engine on the upper stage".
      local st = { k = k + 1, m = s.m, th = s.th, burn = s.burn, fu = s.fu,
                   dv = burn_dv(s.th, s.burn, s.m, s.m - s.fu * U),
                   twr = (s.m > 0 and s.th > 0) and s.th / (s.m * w.g) or 0,
                   th_sl = s.th_sl,
                   dv_sl = burn_dv(s.th_sl, s.burn, s.m, s.m - s.fu * U),
                   twr_sl = (s.m > 0 and s.th_sl > 0) and s.th_sl / (s.m * w.g) or 0,
                   tb = (s.burn > 0) and s.fu / s.burn or 0 }
      out.stages[#out.stages + 1] = st
      out.dv = out.dv + st.dv
      out.dv_sl = out.dv_sl + st.dv_sl
    end
  end
  local T, burn, m0 = s1.th + bth, s1.burn + bburn, s1.m + bm
  out.twr = (T > 0 and m0 > 0) and T / (m0 * w.g) or 0
  -- lift-off is AT the pad: this is the TWR that says whether it leaves
  local T_sl = s1.th_sl + bth_sl
  out.twr_sl = (T_sl > 0 and m0 > 0) and T_sl / (m0 * w.g) or 0
  -- any engine aboard that gives less at sea level than in vacuum
  out.nozzles = math.abs(T_sl - T) > 1e-6 or math.abs(out.dv_sl - out.dv) > 1e-6
  -- Z + SPACE, straight up, never staging: stage 1's engines (and any boosters)
  -- burn the whole pool, upper stages' tanks included.
  if T > 0 and burn > 0 and fu_all > 0 then
    out.hop = hopApoapsis(T, m0, fu_all * U, T / (burn * U), w)
    out.tb = fu_all / burn
  end
  return out
end

function fmt_alt(m)
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

function stage_lines()
  local s = stageStats()
  local out = ""
  local function dv_s(v) return v > 0 and string.format("%.0f m/s", v) or "—" end
  -- With a nozzle that cares about the air aboard, each figure reads SEA
  -- LEVEL / VACUUM (the pad's air and space); otherwise just the one.
  local both = s.nozzles
  local function twr2(a, b) return both and string.format("%.2f / %.2f", a or 0, b or 0) or string.format("%.2f", b or 0) end
  local function dv2(a, b)
    if not both then return dv_s(b) end
    return (b or 0) > 0 and string.format("%.0f / %.0f m/s", a or 0, b) or "—"
  end
  if both then out = out .. "\n(sea level / vacuum)" end
  if s.boosters then
    local b = s.boosters
    out = out .. string.format("\nBOOSTERS ×%d:  TWR %s   Δv %s   burn %.1f s   %.2f t",
      b.n, twr2(b.twr_sl, b.twr), dv2(b.dv_sl, b.dv), b.tb, b.m)
  end
  for _, st in ipairs(s.stages) do
    out = out .. string.format("\nSTAGE %d:  TWR %s   Δv %s   burn %.1f s   %.2f t",
      st.k, twr2(st.twr_sl, st.twr), dv2(st.dv_sl, st.dv), st.tb, st.m)
  end
  if #s.stages > 1 or s.boosters then
    out = out .. string.format("\nTOTAL  Δv %s", dv2(s.dv_sl, s.dv))
  end
  -- What that Δv MEANS here. Δv alone misleads on a world this small: gravity
  -- eats a large share of a short, steep climb, so the starter's ~55 m/s peaks
  -- a few hundred metres up although escape is quoted at 45-odd.
  local w = s.world
  local where = w.name or "the launch world"
  out = out .. string.format("\n%s:  g %.1f m/s²  ·  escape %.0f m/s", where, w.g, escapeSpeed(w))
  -- What the Δv buys, in one line: the orbit the contracts ask for costs this
  -- much flown well, so the player can see whether a design is a hop or an
  -- orbiter before paying for it. TWR under 1 is said first: no Δv matters
  -- if the craft can't leave the pad.
  local need = orbitNeed(w)
  local verdict
  local lift = s.nozzles and s.twr_sl or s.twr
  if (lift or 0) > 0 and lift < 1.0 then
    verdict = "too heavy to lift off — add thrust or lose mass"
  elseif s.dv >= need * 1.6 then
    verdict = "orbit with plenty to spare"
  elseif s.dv >= need then
    verdict = "enough for orbit"
  elseif s.dv > 0 then
    verdict = "a suborbital hop"
  end
  out = out .. string.format("\norbit (%s up) needs ≈ %.0f m/s%s", fmt_alt(orbitAlt(w)), need,
    verdict and ("  →  " .. verdict) or "")
  if s.hop then
    if s.hop == math.huge then
      out = out .. "\nfull throttle straight up: escapes " .. where
    elseif s.hop > 0 then
      out = out .. string.format("\nfull throttle straight up peaks ≈ %s", fmt_alt(s.hop))
    end
  end
  return out
end

-- ══ STAGE MODEL BEGIN (pure: tests/smoke_stage_split.lua loads this block) ══
-- THE STAGING STACK, as data. A STAGE is what one SPACE fires: a list of
-- separation EVENTS (items). `stages` is an array of stages in FIRING order
-- (stage 1 fires first), each an array of item keys. Items come from the
-- craft (`stage_items`): an axial decoupler "u<uid>", a radial-decoupler ring
-- "g<sym>" (a lone one "u<uid>"), a fairing "u<uid>", the chutes "c".
--   STAGEM.rank(it)          the default order: rings, then axial cuts and
--                            fairings bottom-up, chutes last
--   STAGEM.sync(stages, items, saved) → stages: gone items drop, empty stages
--                            close, a reloaded blueprint's saved stage numbers
--                            come back (uid → n), and a NEW item gets a stage
--                            of its own after the last stage that fires
--                            before it by default (so a decoupler added under
--                            the stack fires before the ones above it)
--   STAGEM.move(stages, key, to, asNew) → stages: the item into stage `to`
--                            (asNew: a new stage inserted at `to`)
--   STAGEM.swap(stages, i, j) → stages: two stages trade places
--   STAGEM.index(stages, items) → uid → stage number (what the blueprint saves)
STAGEM = {}
function STAGEM.rank(it)
  if it.chute then return 3e6 end
  if it.ring then return 1e6 + (it.y or 0) end
  return 1e6 + 1e3 + (it.y or 0)
end
function STAGEM.minrank(stage, items)
  local m = math.huge
  for _, k in ipairs(stage) do
    local it = items[k]
    if it then m = math.min(m, STAGEM.rank(it)) end
  end
  return m
end
function STAGEM.sortgroup(g, items)
  table.sort(g, function(a, b)
    local ra, rb = STAGEM.rank(items[a]), STAGEM.rank(items[b])
    if ra ~= rb then return ra < rb end
    return a < b
  end)
end
function STAGEM.sync(stages, items, saved)
  local out, placed = {}, {}
  for _, g in ipairs(stages or {}) do
    local ng = {}
    -- (an old save's flat list of keys: each key its own stage)
    if type(g) == "string" then g = { g } end
    for _, k in ipairs(g) do
      if items[k] and not placed[k] then ng[#ng + 1] = k; placed[k] = true end
    end
    if #ng > 0 then out[#out + 1] = ng end
  end
  local fresh, by_n = {}, {}
  local keys = {}
  for k in pairs(items) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if not placed[k] then
      local it, n = items[k], nil
      for _, u in ipairs(it.uids or {}) do
        local su = saved and saved[u]
        if su and su > 0 and (not n or su < n) then n = su end
      end
      if n then
        by_n[n] = by_n[n] or {}
        table.insert(by_n[n], k)
      else
        fresh[#fresh + 1] = k
      end
    end
  end
  local ns = {}
  for n in pairs(by_n) do ns[#ns + 1] = n end
  table.sort(ns)
  for _, n in ipairs(ns) do
    STAGEM.sortgroup(by_n[n], items)
    out[#out + 1] = by_n[n]
  end
  table.sort(fresh, function(a, b)
    local ra, rb = STAGEM.rank(items[a]), STAGEM.rank(items[b])
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  for _, k in ipairs(fresh) do
    local r = STAGEM.rank(items[k])
    local at = 1
    for i, g in ipairs(out) do
      if STAGEM.minrank(g, items) < r then at = i + 1 end
    end
    table.insert(out, at, { k })
  end
  return out
end
function STAGEM.move(stages, key, to, asNew)
  local out = {}
  for i, g in ipairs(stages) do
    local ng = {}
    for _, k in ipairs(g) do if k ~= key then ng[#ng + 1] = k end end
    out[i] = ng
  end
  to = math.max(1, math.min(to or 1, #out + 1))
  if asNew or not out[to] then
    table.insert(out, to, { key })
  else
    table.insert(out[to], key)
  end
  local kept = {}
  for _, g in ipairs(out) do if #g > 0 then kept[#kept + 1] = g end end
  return kept
end
function STAGEM.swap(stages, i, j)
  if not (stages[i] and stages[j]) then return stages end
  stages[i], stages[j] = stages[j], stages[i]
  return stages
end
function STAGEM.index(stages, items)
  local out = {}
  for n, g in ipairs(stages) do
    for _, k in ipairs(g) do
      local it = items[k]
      for _, u in ipairs(it and it.uids or {}) do out[u] = n end
    end
  end
  return out
end
-- ══ STAGE MODEL END ══

-- The current stage items: key → { key, uids = {part uids}, y, ring | fair | chute }.
function stage_items()
  local items = {}
  for uid, p in pairs(parts) do
    if p.def.decouple then
      if p.def.radial then
        local key = p.sym and ("g" .. p.sym) or ("u" .. uid)
        local it = items[key]
        if not it then
          it = { key = key, uids = {}, ring = true, y = p.y }
          items[key] = it
        end
        it.uids[#it.uids + 1] = uid
        it.y = math.min(it.y, p.y)
      else
        items["u" .. uid] = { key = "u" .. uid, uids = { uid }, ring = false, y = p.y }
      end
    elseif p.def.fairing then
      -- A fairing's jettison is a staging event too (and an action).
      items["u" .. uid] = { key = "u" .. uid, uids = { uid }, ring = false, y = p.y, fair = true }
    elseif p.def.chute then
      -- every chute aboard opens on ONE event (the flight's), so they are one item
      local it = items.c
      if not it then it = { key = "c", uids = {}, chute = true, y = p.y }; items.c = it end
      it.uids[#it.uids + 1] = uid
      it.y = math.max(it.y, p.y)
    end
  end
  for _, it in pairs(items) do table.sort(it.uids) end
  return items
end

-- Reconcile the staging stack with the live items (STAGEM.sync); cached per
-- craft version, so the panel, the badges and the blueprint read one answer.
function sync_stage_order()
  if W.stage_sync_v == craftVersion and W.stage_items then return W.stage_items end
  local items = stage_items()
  stage_order = STAGEM.sync(stage_order, items, saved_stage)
  W.stage_items, W.stage_sync_v = items, craftVersion
  return items
end

-- Lazily resolve (and cache) the pool of StageRow## UI nodes authored in
-- builder.ron (the old floating panel; the STAGE tab draws the stack now).
function stage_row_node(i)
  if not stage_rows then
    stage_rows = {}
    for k = 1, STAGE_MAX_ROWS do
      stage_rows[k] = find(string.format("StageRow%02d", k))
    end
  end
  return stage_rows[i]
end

-- What a separation event IS, in words: its kind and how many.
function stageItemLabel(it)
  if it.chute then return #it.uids > 1 and string.format("Parachutes ×%d", #it.uids) or "Parachute" end
  if it.fair then return "Fairing jettison" end
  local p = parts[it.uids[1]]
  local nm = p and p.def.label or "Decoupler"
  if it.ring and #it.uids > 1 then return string.format("%s ×%d", nm, #it.uids) end
  return nm
end
function stage_label(k, it)
  return string.format("%d   %s", k, stageItemLabel(it))
end

-- Labels counted: "FT-M Tank ×2, Skipper" (most first, at most `n`).
function countLabels(set, n, skip)
  local cnt, order = {}, {}
  for u in pairs(set) do
    local p = parts[u]
    if p and not (skip and skip[u]) then
      local l = p.def.label or p.id
      if not cnt[l] then cnt[l] = 0; order[#order + 1] = l end
      cnt[l] = cnt[l] + 1
    end
  end
  table.sort(order, function(a, b) if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end return a < b end)
  local out = {}
  for i, l in ipairs(order) do
    if i > (n or 3) then out[#out + 1] = string.format("+%d more", #order - (n or 3)) break end
    out[#out + 1] = cnt[l] > 1 and string.format("%s ×%d", l, cnt[l]) or l
  end
  return table.concat(out, ", "), #order
end

-- THE STAGE TAB'S DATA (builder_inspector draws it): one entry per stage in
-- firing order, each with its events (what each one is, which parts it
-- throws off, which engines it leaves burning) — the same model the flight
-- flies (vessel_controller events, grouped by stage number).
-- The part the flight keeps when a decoupler fires (vessel_controller
-- splitKeeper): where the crew sits — the crewed part nearest the tree's root,
-- a pod before an open seat — else the probe core nearest it.
function stageKeep()
  local best, rank = nil, nil
  for u, p in pairs(parts) do
    local k = p.def.kind
    if k == "crewed" or k == "probe" then
      local depth, x, g = 0, u, 0
      while parts[x] and parts[x].parent and g < 256 do x = parts[x].parent; depth = depth + 1; g = g + 1 end
      local r = (k == "probe" and 1e12 or 0) + (p.def.seat and 1e9 or 0) + depth * 1e5 + u
      if not rank or r < rank then best, rank = u, r end
    end
  end
  return best
end
-- What firing decoupler `uid` throws off, seen from the crew's side (the
-- flight's rule), it included; {} when a loop through a strut keeps it on.
function stageDrops(uid, keep)
  local G, L = graph(), lib("builder_graph")
  if G and L and keep and keep ~= uid then
    local far = L.separation(G, alive_set(), uid, keep)
    return far or {}
  end
  return separation_of(uid)
end

function stageView()
  local items = sync_stage_order()
  local keep = stageKeep()
  local out = { stages = {}, launch = nil }
  -- engines by the flight's rule: below the lowest axial cut (and boosters)
  -- burn from lift-off; each axial cut lights the engines above it, up to the
  -- next cut
  local cuts = {}
  for _, p in pairs(parts) do if p.def.decouple and not p.def.radial then cuts[#cuts + 1] = p.y end end
  table.sort(cuts)
  local boost = {}
  for ru, p in pairs(parts) do
    if p.def.radial and p.def.decouple then
      for u in pairs(stageDrops(ru, keep)) do boost[u] = true end
    end
  end
  local function engines_between(lo, hi, with_boost)
    local set = {}
    for u, p in pairs(parts) do
      if (p.def.thrust or 0) > 0 then
        if (with_boost and boost[u]) or (not boost[u] and p.y > lo + 0.01 and p.y < hi - 0.01) then set[u] = true end
      end
    end
    return set
  end
  local first = cuts[1] or math.huge
  out.launch = { lights = (countLabels(engines_between(-math.huge, first, true), 3)) }
  for n, g in ipairs(stage_order) do
    local st = { n = n, items = {} }
    for _, k in ipairs(g) do
      local it = items[k]
      if it then
        local e = { key = k, label = stageItemLabel(it), uids = it.uids, kind = it.chute and "chute" or it.fair and "fairing" or it.ring and "ring" or "axial" }
        if not it.chute and not it.fair then
          local drop, own = {}, {}
          for _, u in ipairs(it.uids) do
            own[u] = true
            for v in pairs(stageDrops(u, keep)) do drop[v] = true end
          end
          local txt, nk = countLabels(drop, 3, own)
          e.drops = nk > 0 and txt or nil
          if not it.ring then
            local hi = math.huge
            for _, y in ipairs(cuts) do if y > it.y + 0.01 and y < hi then hi = y end end
            local lit = countLabels(engines_between(it.y, hi, false), 3)
            e.lights = lit ~= "" and lit or nil
          end
        end
        st.items[#st.items + 1] = e
      end
    end
    out.stages[#out.stages + 1] = st
  end
  return out
end

-- The STAGE tab's hover: the event (key) or stage ("s<n>") the cursor is on
-- lights its parts in the view for a moment.
function stageHover(key)
  stage_hover = key
  W.stage_hover_t = time or 0
end

-- The old floating staging panel is retired (the STAGE tab of the right plate
-- shows the stack): keep its scene nodes hidden.
function paint_stages()
  if not stage_node2 then stage_node2 = find("StagePanel") end
  if stage_node2 then
    local panel = stage_node2:getcomponent("UiElement")
    if panel and panel.visible then panel.visible = false end
  end
  for k = 1, STAGE_MAX_ROWS do
    local rn = stage_row_node(k)
    local el = rn and rn:getcomponent("UiElement")
    if el and el.visible then el.visible = false end
  end
  if not stage_ghost then stage_ghost = find("StageDragGhost") end
  local gel = stage_ghost and stage_ghost:getcomponent("UiElement")
  if gel and gel.visible then gel.visible = false end
end

-- The company ledger, if this scene has one mounted (it does; the builder is
-- where money is spent). Fetched fresh — scripts don't survive a scene load.
local co_ref = nil
function company_ref()
  if not co_ref or not co_ref.node or not co_ref.node.valid then
    co_ref = findScript("company")
  end
  return co_ref
end

-- What this build costs to put on the pad.
function build_cost()
  local c = 0
  for _, p in pairs(parts) do c = c + p.def.cost end
  return c
end

-- The header card (BuildTitle) holds a heading and this stats text. The text
-- is "fit" tall in the scene, and the card grows to where the engine laid it
-- out: the stats start 32 down and the card keeps a 10 bottom margin under them.
local STATS_TOP, STATS_PAD = 32, 10
local header_refs = {}
function set_stats(text)
  stats_node.text = text
end

function fit_header()
  local r = header_refs
  if not r.card and find then r.card = find("BuildTitle") end
  if not (r.card and stats_node and stats_node.uiRect) then return end
  -- (no `select` here: the builder exports its own `select`, the API's)
  local _, _, _, h = stats_node:uiRect()
  local sh = nil
  if camera and camera.screenSize then _, sh = camera.screenSize() end
  if not (h and h > 0 and sh and sh > 0) then return end
  local cel = r.card:getcomponent("UiElement")
  local want = math.ceil(STATS_TOP + h * uiDesignH() / sh + STATS_PAD)
  if cel and math.abs(cel.height - want) > 0.5 then cel.height = want end
end

-- What a first rocket is still missing, in the order you'd add it. A pod on
-- its own sat on the pad with a readout of mass and money and nothing to say
-- that it wasn't a rocket yet.
function next_step(has)
  if not has.command then return "Next: add a Pod Mk1 (crewed) or a Probe Core — something has to fly it" end
  -- A ROVER (wheels, no engine) is whole without tanks: it drives out.
  if has.wheel and not has.engine then
    if (has.wheels or 0) < 3 then return "Next: add wheels — four on two flanks (M mirrors them left/right)" end
    return "Ready to drive — press LAUNCH (W/S drive · A/D steer · B brakes)"
  end
  if not has.tank then return "Next: add a fuel tank under the pod" end
  if not has.engine then return "Next: add an engine under the tank" end
  if not has.chute and has.crewed then return "Next: add a parachute on top of the pod" end
  return "Ready to fly — press LAUNCH"
end

-- CAN THIS GO TO THE PAD? Global and pure so the LAUNCH button, the readout and
-- the smoke test all ask the same question.
--
--   block   why LAUNCH is refused outright (nil = it may launch). Only a craft
--           nobody can fly is refused: no crewed part means there is no seat,
--           and the flight has nobody to put in it.
--   warn    things that are legal and almost certainly a mistake — no engine,
--           no parachute, too heavy to lift. LAUNCH asks before it charges.
function launchCheck()
  local has, n = {}, 0
  for _, p in pairs(parts) do
    n = n + 1
    has[p.def.kind] = true
    if p.def.chute then has.chute = true end
    if p.def.legs then has.legs = true end
    if p.def.wheel then has.wheel = true; has.wheels = (has.wheels or 0) + 1 end
  end
  has.command = has.crewed or has.probe
  if n == 0 then return { block = "nothing to launch — build something first", warn = {}, has = has } end
  if not has.command then
    return { block = "no command part — add a Pod Mk1 (crewed) or a Probe Core", warn = {}, has = has }
  end
  -- THE CREW (docs/crew-and-items.md §5.6; builder_crew.lua): crewed command
  -- parts with nobody planned at the controls and no probe core can't fly.
  local bcrew = findScript and findScript("builder_crew") or nil
  if bcrew and bcrew.launchBlock then
    local okb, why = pcall(bcrew.launchBlock)
    if okb and why then return { block = why, warn = {}, has = has } end
  end
  local warn = {}
  if bcrew and bcrew.launchWarn then
    local okw, lines = pcall(bcrew.launchWarn)
    if okw and type(lines) == "table" then for _, l in ipairs(lines) do warn[#warn + 1] = l end end
  end
  -- the offset limit (§5.6): a part nudged off what it is attached to
  if detachedParts then
    local det = detachedParts()
    if #det > 0 then
      return { block = string.format("%d part%s not touching what %s attached to — move %s back", #det,
        #det == 1 and " is" or "s are", #det == 1 and "it is" or "they are", #det == 1 and "it" or "them"),
        warn = {}, has = has, detached = det }
    end
  end
  -- loose islands (§5.2): only the root's island is the craft
  if islands then
    local comps = islands()
    if comps and #comps > 1 then
      warn[#warn + 1] = string.format("%d loose part group%s not attached to the craft (orange)", #comps - 1,
        #comps == 2 and "" or "s")
    end
  end
  -- parts buried in each other (red): harmless, unless it is a wheel or a
  -- leg that can no longer reach the ground
  if badOverlaps then
    local ov = badOverlaps()
    if #ov > 0 then
      local p = parts[ov[1].sunk]
      local q = parts[ov[1].sunk == ov[1].a and ov[1].b or ov[1].a]
      local what = (p and p.def.label or "a part") .. " is " .. string.format("%.0f cm", ov[1].depth * 100)
        .. " inside " .. (q and q.def.label or "another part")
      warn[#warn + 1] = (#ov == 1 and what or string.format("%d parts overlap (red) — %s", #ov, what))
        .. ((p and (p.def.wheel or p.def.legs)) and " — it may not reach the ground" or "")
    end
  end
  if not has.engine and not has.wheel then
    warn[#warn + 1] = "no engine — it will sit on the pad"
  else
    local s = stageStats()
    -- lift-off happens in the pad's air: the sea-level TWR decides it
    local lift = s.nozzles and s.twr_sl or s.twr
    if (lift or 0) > 0 and lift < 1.0 then
      warn[#warn + 1] = string.format("TWR %.2f%s — too heavy to lift off %s", lift,
        s.nozzles and " at the pad" or "", s.world.name or "this world")
    end
    if s.hop == math.huge then
      warn[#warn + 1] = "full throttle straight up escapes " .. (s.world.name or "this world")
        .. " — watch the apoapsis and cut the throttle"
    end
  end
  if not has.chute and has.crewed and not (has.wheel and not has.engine) then
    warn[#warn + 1] = "no parachute — the pod will not survive the landing"
  end
  if has.wheel then
    for _, w in ipairs(wheelChecks()) do warn[#warn + 1] = w end
  end
  -- A probe with nothing aboard to keep it powered is a probe that goes dark
  -- before it gets anywhere. Say how long it has.
  if has.probe and not has.crewed then
    local pw = powerStats()
    if pw and pw.solar <= 0 and pw.idle > 0 then
      local secs = pw.store / pw.idle
      if secs < 600 then
        warn[#warn + 1] = string.format("no solar panels — the probe runs flat after ≈ %d min idle", math.floor(secs / 60 + 0.5))
      end
    end
  end
  return { warn = warn, has = has }
end

-- WHAT A WHEELED CRAFT IS MISSING (playtest 2026-10-26: "motorcycles are
-- hard to build right"). The flight works out the front and lays every wheel
-- to roll along it (vessel_controller r2WheelSetup), so how the wheels are
-- turned no longer matters; what still does, said plainly:
--   no battery      driven wheels and nothing to power them (a seat or a
--                   saddle carries none)
--   no motor        wheels, none of them driven, and no engine
--   a two-wheeler   (every wheel in one line) with no seat to ride it and no
--                   Balance Gyro: it falls over; its wheels a few cm out of
--                   line: it crabs
-- Global and pure over the craft records, for the smoke tests.
function wheelChecks()
  local out = {}
  local E = elib()
  local pw = powerStats()
  if not (E and pw) then return out end
  local wheels, driven, rider, gyro, engine = {}, 0, false, false, false
  for uid, r in pairs(pw.records or {}) do
    local p = parts[uid]
    local dm = E.modOf(r, "drive")
    if dm and p then
      wheels[#wheels + 1] = { x = p.x or 0, z = p.z or 0 }
      if (tonumber(dm.speed) or 0) > 0 and (tonumber(dm.torque) or 0) > 0 then driven = driven + 1 end
    end
    if p and p.def and p.def.seat then rider = true end
    if E.modOf(r, "gyro") then gyro = true end
    if (tonumber(r.thrust) or 0) > 0 then engine = true end
  end
  if #wheels == 0 then return out end
  if driven > 0 and (pw.store or 0) <= 0 and (pw.solar or 0) <= 0 then
    out[#out + 1] = "no battery — the wheel motors have no power (a seat carries none): add a Battery Pack"
  end
  if driven == 0 and not engine then
    out[#out + 1] = "no driven wheel — landing gear only rolls: add a wheel with a motor (Wheel S/M/L, Moto Wheel)"
  end
  -- in one line? (the wheels' spread across their own long axis)
  if #wheels >= 2 then
    local mx, mz = 0, 0
    for _, r in ipairs(wheels) do mx, mz = mx + r.x, mz + r.z end
    mx, mz = mx / #wheels, mz / #wheels
    local sxx, sxz, szz = 0, 0, 0
    for _, r in ipairs(wheels) do
      local dx, dz = r.x - mx, r.z - mz
      sxx, sxz, szz = sxx + dx * dx, sxz + dx * dz, szz + dz * dz
    end
    local ang = 0.5 * math.atan2(2 * sxz, sxx - szz)
    local ax, az = math.cos(ang), math.sin(ang)
    local lo, hi = math.huge, -math.huge
    for _, r in ipairs(wheels) do
      local l = -(r.x - mx) * az + (r.z - mz) * ax
      lo, hi = math.min(lo, l), math.max(hi, l)
    end
    local spread = hi - lo
    if spread <= 0.3 and driven > 0 then
      if not (rider or gyro) then
        out[#out + 1] = "a two-wheeler with no seat to ride it and no Balance Gyro falls over — add a Moto Saddle or a gyro"
      end
      if spread > 0.04 then
        out[#out + 1] = string.format("the wheels are %.0f cm out of line — a bike's wheels go one behind the other", spread * 100)
      end
    end
  end
  return out
end

-- THE ELECTRICAL PICTURE of the craft on the stand (electronics.summary):
-- battery store, solar at home-orbit daylight, the idle and peak draw, and how
-- far its antennas reach. Global and pure so the smoke test reads the numbers.
function powerStats()
  local E = elib()
  if not E then return nil end
  local recs = craft_records()
  local s = E.summary(recs, 1.0)
  s.records = recs
  return s
end

function fmt_range(m)
  if m >= 1e6 then return string.format("%.0f Mm", m / 1e6) end
  if m >= 1e4 then return string.format("%.0f km", m / 1000) end
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end

function fmt_secs(t)
  if t == math.huge then return "indefinitely" end
  if t >= 3600 then return string.format("%.1f h", t / 3600) end
  if t >= 60 then return string.format("%.0f min", t / 60) end
  return string.format("%.0f s", t)
end

-- Two lines for the header card: POWER (store, supply, the draw at idle and
-- how long the batteries carry it in the dark) and COMMS (how far the best
-- antenna reaches home and another craft, and whether it relays).
function elec_lines()
  local s = powerStats()
  if not s then return "" end
  local out = ""
  if s.store > 0 or s.solar > 0 or s.idle > 0 then
    local dark = (s.idle > 0) and (s.store / s.idle) or math.huge
    local supply = s.solar > 0 and string.format("  ·  sun +%.1f/s", s.solar) or ""
    local verdict
    if s.solar >= s.idle and s.idle > 0 then
      verdict = "sun covers it"
    elseif s.idle > 0 then
      verdict = fmt_secs(dark) .. " on battery"
    end
    out = out .. string.format("\nPOWER  %.0f EC%s  ·  idle −%.2f/s%s", s.store, supply,
      s.idle, verdict and ("  ·  " .. verdict) or "")
    if (s.motors or 0) > 0 then
      -- Wheels, actuators and the drill draw only while they work.
      out = out .. string.format("\nMOTORS  −%.1f/s flat out  ·  %s of driving on battery", s.motors,
        fmt_secs(s.store / math.max(1e-6, s.motors + s.idle)))
    end
  end
  if s.antenna.any > 0 then
    out = out .. string.format("\nCOMMS  home %s  ·  craft to craft %s%s", fmt_range(s.reachHome),
      fmt_range(s.reachCraft), s.relay and "  ·  relay" or "")
  elseif s.probe > 0 then
    out = out .. "\nCOMMS  none — a probe with no antenna can't be flown"
  end
  if s.probe > 0 and s.crew == 0 then
    out = out .. "\nPROBE  flies only with power and a link home"
  end
  return out
end

-- WHERE THE CRAFT ROLLS OUT: the spaceport's PAD (Launch Complex 1) or its
-- RUNWAY (the threshold, facing down it — rovers and planes). L switches;
-- until it is pressed a craft on wheels goes to the runway and anything
-- else to the pad. vessel_spawner reads `shipyard.site`.
launchSiteChoice = nil
function launchSite()
  if launchSiteChoice then return launchSiteChoice end
  for _, p in pairs(parts) do
    if p.def and p.def.wheel then return "runway" end
  end
  return "pad"
end
function toggleLaunchSite()
  launchSiteChoice = launchSite() == "pad" and "runway" or "pad"
  hint(launchSiteChoice == "runway"
    and "launch site: RUNWAY — the craft rolls out at the threshold, facing down it   ·   L for the pad"
    or "launch site: PAD — Launch Complex 1, on the hold-downs   ·   L for the runway", 3.0)
end

local launch_btn_el = nil
local launch_btn_n = nil
function paint_launch_button(chk)
  if not launch_btn_el then
    launch_btn_n = find and find("LaunchBtn")
    launch_btn_el = launch_btn_n and launch_btn_n:getcomponent("UiElement") or false
  end
  if launch_btn_el then
    local want = chk.block and 1 or 0
    if launch_btn_el.disabled ~= want then launch_btn_el.disabled = want end
  end
  if launch_btn_n and launch_btn_n.valid ~= false then
    local label = launchSite() == "runway" and "RUNWAY  ▸" or "PAD  ▸"
    if launch_btn_n.text ~= label then launch_btn_n.text = label end
  end
end

-- DIRTY-FLAG STATS: every edit calls refresh_stats(), which only marks the
-- readout stale; update() repaints it at most once a frame (and at most every
-- half second while a drag is in progress). Spawn callbacks never touch it.
local function refresh_stats() W.dirty = true end
function refreshStatsNow()
  W.dirty = false
  craftVersion = craftVersion + 1
  W.stats_v = (W.stats_v or 0) + 1
  center_now()
  paint_stages()
  if not stats_node then return end
  -- Mass as it stands on the pad: dry parts plus full tanks.
  local mass, dry, cost, n = 0.0, 0.0, 0, 0
  for _, p in pairs(parts) do
    n = n + 1
    dry = dry + p.def.mass
    mass = mass + p.def.mass + (p.def.fuel or 0) * FUEL_T_PER_UNIT
    cost = cost + p.def.cost
  end
  local chk = launchCheck()
  paint_launch_button(chk)
  if n == 0 then
    set_stats("empty pad — start with a Pod Mk1 from the catalogue")
    return
  end
  -- Lift-off TWR: what the first stage (and any boosters) pushes against the
  -- whole stack, in the LAUNCH WORLD's gravity — not Earth's 9.81, which
  -- understated it by half on the review's world. The flight HUD reads the same
  -- figure at the pad.
  local st = stageStats()
  local twr_s = ((st.twr or 0) > 0) and string.format("  ·  TWR %.2f", st.twr) or ""
  -- (with air-sensitive nozzles aboard: the pad's TWR first, vacuum after)
  if st.nozzles and (st.twr or 0) > 0 then
    twr_s = string.format("  ·  TWR %.2f pad / %.2f vac", st.twr_sl or 0, st.twr)
  end
  -- The build cost against the company's actual balance: you should be able to
  -- see you can't afford it WHILE you're adding the part, not after you press
  -- LAUNCH. Over budget turns the figure red-flagged rather than hiding it.
  local co = company_ref()
  local bal = co and co.balance and co.balance() or nil
  -- "cost $400 of $1,170" read as a progress bar; it is a price and a budget.
  local money = string.format("cost $%d", cost)
  if bal then
    money = string.format("cost %s   ·   budget %s%s", co.money(cost), co.money(bal),
      (cost > bal) and "   ⚠ OVER BUDGET" or "")
  end
  -- What to do next while it's still being built; once it's a whole rocket,
  -- the first thing LAUNCH would ask you about (too heavy, escapes).
  local status = chk.block and ("⚠ " .. chk.block) or next_step(chk.has)
  local whole = (chk.has.engine and (chk.has.chute or not chk.has.crewed) and chk.has.tank)
    or (chk.has.wheel and not chk.has.engine and (chk.has.wheels or 0) >= 3)
  if not chk.block and whole and #chk.warn > 0 then status = "⚠ " .. chk.warn[1] end
  local mass_s = (mass > dry + 1e-6) and string.format("%.2f t (%.2f dry)", mass, dry)
    or string.format("%.2f t", mass)
  set_stats(string.format("%d %s  ·  %s%s\n%s\n%s\ntool: %s%s%s%s",
    n, n == 1 and "part" or "parts", mass_s, twr_s, money, status,
    TOOL_LABEL[tool] or "?",
    sym_mirror and "  ·  mirror" or (sym_n > 1 and ("  ·  symmetry ×" .. sym_n) or ""),
    elec_lines(),
    stage_lines()))
end

-- ── PARTS ARE DATA FIRST (WP1) ──────────────────────────────────────────────
-- A part exists the moment its record is in `parts`; its node is asked for and
-- lands later (spawns are asynchronous, and at most W.budget = 60 are started a
-- frame — a 2,000-part load is time-sliced instead of stalling one frame). The
-- callback dresses the node from the record AS IT IS THEN, so a part moved or
-- deleted before its node arrives is never wrong. Nothing in a spawn callback
-- recomputes stats (dirty flag) or the centre.

-- The prefab a part shows on the stand: the visual-only variant when WP3's
-- prefabs/vis/ has one (no rigidbody: nothing simulates on the stand), else
-- the flight prefab.
local function stand_prefab(prefab)
  if W.vis == nil then
    W.vis = {}
    if assets and assets.getContents then
      local ok, list = pcall(assets.getContents, "prefabs/vis")
      if ok and type(list) == "table" then
        for _, f in ipairs(list) do
          local name = tostring(f):match("([^/]+)%.prefab%.ron$")
          if name then W.vis[name] = true end
        end
      end
    end
  end
  if W.vis[prefab] then return "vis/" .. prefab end
  return prefab
end

-- A drawn part's mesh and its joint plates (builder_proc, WP3).
function dress_proc(node, p)
  if not (p.def.proc or p.joints) then return end
  local P = lib("builder_proc")
  if not P then return end
  if p.def.proc and P.dress then P.dress(node, { def = p.def, size = p.size }) end
  if P.dressJoint then
    for _, j in ipairs(p.joints or {}) do P.dressJoint(node, decodeJoint(j)) end
  end
end

-- Put a freshly landed node in the frame: a child of the BuildFrame when there
-- is one (its local numbers are the builder's), placed as the record says.
local function dress_node(node, p)
  if W.F and not W.F.identity and W.F.node and node.setParent then
    node:setParent(W.F.node, { keepWorld = false })
  end
  node.x, node.y, node.z = p.x, p.y, p.z
  node.yaw, node.pitch, node.roll = p.yaw or 0, p.pitch or 0, p.roll or 0
  if p.hidden then node.visible = false end
  if node.id and p.uid then W.bynode[node.id] = p.uid end
  W.landed = (W.landed or 0) + 1
  dress_proc(node, p)
end

local function spawn_now(u, p)
  W.budget = W.budget - 1
  pending_spawns = pending_spawns + 1
  local wx, wy, wz = p.x, p.y, p.z
  if W.F and not W.F.identity then wx, wy, wz = W.F.toWorld(p.x, p.y, p.z) end
  spawn(stand_prefab(p.def.prefab), vec3(wx, wy, wz), function(node)
    pending_spawns = pending_spawns - 1
    if parts[u] == p and not p.node then
      p.node = node
      dress_node(node, p)
    else
      destroy(node)
    end
  end)
end

local function request_node(u, p)
  if W.budget > 0 then spawn_now(u, p)
  else W.queue[#W.queue + 1] = { u, p } end
end

-- Start this frame's share of the queued spawns (update calls it first).
function spawnQueueTick()
  W.budget = 60
  local q = W.queue
  local h = W.qhead
  while h <= #q and W.budget > 0 do
    local it = q[h]
    q[h] = false
    h = h + 1
    if parts[it[1]] == it[2] and not it[2].node then spawn_now(it[1], it[2]) end
  end
  if h > #q then W.queue, W.qhead = {}, 1 else W.qhead = h end
end
-- nil, or { done, total } while a load or paste is still spawning.
function loadProgress()
  local left = #W.queue - W.qhead + 1
  if left <= 0 then
    W.load_total = 0
    return nil
  end
  if left > W.load_total then W.load_total = left end
  return { done = W.load_total - left, total = W.load_total }
end

-- The primary link (the old parent edge) as a graph link, and the fields.
local function set_parent(u, parent, att)
  local p = parts[u]
  if not p then return end
  local G = graph()
  if G then
    local old = G:primary(u)
    if old then G:remove(old.id) end
  end
  p.parent, p.att = parent, att
  if parent and parts[parent] and G then
    local L = lib("builder_graph")
    local l = L.v1Link(parent, u, att)
    -- joint points in each part's own frame (stack nodes: the end faces)
    if l.k == "stack" then
      local hp, hc = parts[parent].def.h * 0.5, p.def.h * 0.5
      l.pa = { x = 0, y = (att == "bottom") and -hp or hp, z = 0 }
      l.pb = { x = 0, y = (att == "bottom") and hc or -hc, z = 0 }
    end
    G:add(l)
  end
  struct_changed()
end

-- A DRAWN part (WP3: beamP, panelP, brace — `def.proc`) is one registry entry
-- for every size: its def on the stand is the entry with h, rx, rz, mass,
-- cost and strength from parts_registry.sizeOf(def, size) (cached per size),
-- so every rule here (extents, picking, stats, the blueprint) reads it as an
-- ordinary part.
local SIZED = setmetatable({}, { __mode = "v" })
local function def_of(id, size)
  local d = REG[id]
  if not d then return nil end
  if not (d.proc and type(size) == "table") then return d end
  local key = table.concat({ id, tostring(size.prof), tostring(size.len), tostring(size.w),
                             tostring(size.d), tostring(size.t) }, ":")
  local c = SIZED[key]
  if c then return c end
  c = {}
  for k, v in pairs(d) do c[k] = v end
  local lib2 = registry()
  local z = lib2 and lib2.sizeOf and lib2.sizeOf(d, size)
  if z then for k, v in pairs(z) do c[k] = v end end
  c.prof = size.prof or d.prof
  SIZED[key] = c
  return c
end

-- JOINT VISUALS (WP3's gussets, splice plates, clamps) ride on their part as
-- builder_attach joint tables; the blueprint stores each as ONE string (save.set
-- holds four tables deep: bp → parts → rec → joints is already four).
local function jv(p) return p and string.format("%.4f,%.4f,%.4f", p.x, p.y, p.z) or "" end
function encodeJoint(j)
  local h = j.held or {}
  return table.concat({ j.style or "", jv(j.c), jv(j.ax), jv(j.u), jv(j.w),
    tostring(j.ow or ""), tostring(j.leg or ""), tostring(j.t or ""), tostring(j.hd or ""),
    tostring(h.hx or ""), tostring(h.hz or ""), tostring(h.prof or "") }, "|")
end
function decodeJoint(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" then return nil end
  local f = {}
  for x in (s .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
  local function vec(t)
    local a, b, c = (t or ""):match("^([^,]+),([^,]+),([^,]+)$")
    if not a then return nil end
    return { x = tonumber(a), y = tonumber(b), z = tonumber(c) }
  end
  return { style = f[1], c = vec(f[2]), ax = vec(f[3]), u = vec(f[4]), w = vec(f[5]),
           ow = tonumber(f[6]), leg = tonumber(f[7]), t = tonumber(f[8]), hd = tonumber(f[9]),
           held = { hx = tonumber(f[10]), hz = tonumber(f[11]), prof = (f[12] ~= "" and f[12]) or nil } }
end

local function add_part(u, r, node)
  local def = def_of(r.id, r.size)
  if not def then return nil end
  local p = { uid = u, id = r.id, def = def, node = nil, x = r.x, y = r.y, z = r.z,
              yaw = r.yaw or 0, pitch = r.pitch or 0, roll = r.roll or 0,
              parent = nil, att = nil, sym = r.sym, mir = r.mir, an = r.an, size = r.size,
              hidden = r.hidden, pv = 0, joints = r.joints }
  parts[u] = p
  partCount = partCount + 1
  if u >= next_uid then next_uid = u + 1 end
  if r.sym and r.sym > next_sym then next_sym = r.sym end
  hash_put(u, p)
  if r.parent then set_parent(u, r.parent, r.att) else p.att = r.att end
  struct_changed()
  publish_center()
  if node then p.node = node; dress_node(node, p) else request_node(u, p) end
  return p
end

local function spawn_part(id, x, y, z, yaw, parent, uid, pitch, roll, att, sym, mir)
  if not REG[id] then return nil end
  local u = uid or next_uid
  if not uid then next_uid = next_uid + 1 end
  local an = copyNormal[u]
  copyNormal[u] = nil
  add_part(u, { id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll,
                parent = parent, att = att, sym = sym, mir = mir, an = an })
  return u
end

local function remove_part(uid)
  local p = parts[uid]
  if not p then return nil end
  local data = { uid = uid, id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw,
                 pitch = p.pitch, roll = p.roll, parent = p.parent,
                 att = p.att, sym = p.sym, mir = p.mir, an = p.an }
  if p.node then destroy(p.node) end
  parts[uid] = nil
  partCount = partCount - 1
  if W.H then W.H:remove(uid) end
  local G = graph()
  if G then
    for _, l in ipairs(G:removePart(uid)) do
      -- the parts placed through it lose their parent field with the link
      local o = (l.a == uid) and l.b or l.a
      if l.prim and l.a == uid and parts[o] then parts[o].parent = nil end
    end
  else
    for _, q in pairs(parts) do if q.parent == uid then q.parent = nil end end
  end
  if W.sel[uid] then
    W.sel[uid] = nil
    for i = #W.sel_order, 1, -1 do if W.sel_order[i] == uid then table.remove(W.sel_order, i) end end
    selected_uid = W.sel_order[#W.sel_order]
  end
  if W.root == uid then W.root = nil end
  struct_changed()
  publish_center(); refresh_stats()
  return data
end

-- ── HISTORY (WP1, §8.4): snapshots of what an edit touches ─────────────────
-- An edit records the BEFORE state of the parts it touches (records, their
-- links, wheel settings and fairing shapes; optionally the craft-wide tables:
-- staging order, root, outliner groups, action groups, controls). Its AFTER
-- state is taken lazily the first time it is undone — at that moment the
-- craft is exactly as the edit left it — so a drag that merges 300 frames
-- into one step costs one snapshot, not 300.
local function vcopy(v) return v and { x = v.x, y = v.y, z = v.z } or nil end
local function tcopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = tcopy(v) end
  return o
end

local function snap_parts(uids, extra)
  local S = { order = {}, parts = {}, links = {}, extra = nil }
  local seen, lseen = {}, {}
  local G = graph()
  for k, v in pairs(uids) do
    local u = (type(k) == "number" and v == true) and k or v
    if type(u) == "number" and not seen[u] then
      seen[u] = true
      S.order[#S.order + 1] = u
      local p = parts[u]
      if p then
        S.parts[u] = { id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll,
                       parent = p.parent, att = p.att, sym = p.sym, mir = p.mir, an = vcopy(p.an),
                       size = tcopy(p.size), hidden = p.hidden, joints = tcopy(p.joints),
                       wcfg = wcfgs and wcfgs[u] and tcopy(wcfgs[u]) or nil,
                       fshape = fshapes and fshapes[u] and tcopy(fshapes[u]) or nil }
        if G then
          for _, l in ipairs(G:incident(u)) do
            if not lseen[l.id] then lseen[l.id] = true; S.links[#S.links + 1] = tcopy(l) end
          end
        end
      end
    end
  end
  if extra then
    S.extra = { stage = tcopy(stage_order), root = W.root, outliner = tcopy(W.outliner),
                groups = tcopy(groups_state.groups), edited = groups_state.edited,
                controls = tcopy(W.controls), ctrl = W.ctrl }
  end
  return S
end

local function apply_snap(S)
  local G = graph()
  -- removals first (a removal clears the parent field of what hung on it)
  for _, u in ipairs(S.order) do
    local r, p = S.parts[u], parts[u]
    if p and (not r or p.id ~= r.id) then remove_part(u) end
  end
  for _, u in ipairs(S.order) do
    local r, p = S.parts[u], parts[u]
    if r then
      if not p then
        p = add_part(u, { id = r.id, x = r.x, y = r.y, z = r.z, yaw = r.yaw, pitch = r.pitch,
                          roll = r.roll, sym = r.sym, mir = r.mir, an = vcopy(r.an),
                          size = tcopy(r.size), hidden = r.hidden, joints = tcopy(r.joints) })
      else
        set_part_pos(p, r.x, r.y, r.z)
        set_part_rot(p, r.yaw, r.pitch, r.roll)
        p.sym, p.mir, p.an, p.size, p.joints = r.sym, r.mir, vcopy(r.an), tcopy(r.size), tcopy(r.joints)
        p.def = def_of(p.id, p.size) or p.def
        if p.hidden ~= r.hidden then
          p.hidden = r.hidden
          if p.node then p.node.visible = not r.hidden end
        end
      end
      if p then
        p.parent, p.att = r.parent, r.att
        if wcfgs then wcfgs[u] = tcopy(r.wcfg) end
        if fshapes then fshapes[u] = tcopy(r.fshape) end
      end
    end
  end
  if G then
    for _, u in ipairs(S.order) do
      for _, l in ipairs(G:incident(u)) do G:remove(l.id) end
    end
    for _, l in ipairs(S.links) do
      if parts[l.a] and parts[l.b] then G:add(tcopy(l)) end
    end
    -- a parent field with no primary link behind it (a host that is gone)
    for _, u in ipairs(S.order) do
      local p = parts[u]
      if p and p.parent and not parts[p.parent] then p.parent = nil end
    end
  end
  local X = S.extra
  if X then
    stage_order = tcopy(X.stage) or {}
    W.stage_sync_v = nil
    W.root = X.root
    W.outliner = tcopy(X.outliner) or {}
    groups_state.groups, groups_state.edited = tcopy(X.groups), X.edited
    W.controls = tcopy(X.controls)
    W.ctrl = X.ctrl
  end
  struct_changed()
  publish_center(); refresh_stats()
end

local function history()
  if not W.hist then
    local L = lib("builder_history")
    W.hist = L and L.newHistory(500) or nil
  end
  return W.hist
end

-- Open an edit of `uids` (list or set). `merge` = a key that folds repeated
-- edits (a drag, a slider) into the open step. Returns the transaction; add
-- parts created during it with tx_touch, then tx_commit.
local function tx_begin(label, uids, merge, extra)
  local H = history()
  if merge and H and H.open == merge and H:top() and H:top().tx then
    local t = H:top().tx
    -- only when it covers the same parts (else a fresh step)
    local all = true
    for k, v in pairs(uids) do
      local u = (type(k) == "number" and v == true) and k or v
      if type(u) == "number" and not t.has[u] then all = false break end
    end
    if all then return { merged = true } end
  end
  local before = snap_parts(uids, extra)
  local has = {}
  for _, u in ipairs(before.order) do has[u] = true end
  return { label = label, before = before, has = has, merge = merge, extra = extra }
end
local function tx_touch(t, u)
  if t.merged or t.has[u] then return end
  t.has[u] = true
  t.before.order[#t.before.order + 1] = u   -- absent before: undo removes it
end
local function tx_commit(t)
  if t.merged then return end
  local H = history()
  if not H then return end
  local entry = { label = t.label, merge = t.merge, tx = t }
  local after = nil
  entry.undo = function()
    if not after then
      local ids = {}
      for u in pairs(t.has) do ids[#ids + 1] = u end
      after = snap_parts(ids, t.extra)
    end
    apply_snap(t.before)
  end
  entry.redo = function() if after then apply_snap(after) end end
  H:push(entry)
end
-- One-shot: run fn inside a step.
local function tx_run(label, uids, fn, merge, extra)
  local t = tx_begin(label, uids, merge, extra)
  local r = fn(t)
  tx_commit(t)
  return r
end

-- The legacy op table (fairing shaping, wheel settings) as history steps.
local function push_undo(op)
  local H = history()
  if not H then return end
  if op.type == "wcfg" then
    local prev = op.prev or {}
    local after = nil
    H:push({ label = "wheel settings", merge = op.merge,
      undo = function() after = after or tcopy(wcfgs); wcfgs = tcopy(prev); craftVersion = craftVersion + 1 end,
      redo = function() if after then wcfgs = tcopy(after); craftVersion = craftVersion + 1 end end })
  elseif op.type == "shape" then
    local u, prev, after = op.uid, op.prev, nil
    H:push({ label = "fairing shape",
      undo = function() after = after or tcopy(fshapes[u]); fshapes[u] = tcopy(prev); craftVersion = craftVersion + 1 end,
      redo = function() fshapes[u] = tcopy(after); craftVersion = craftVersion + 1 end })
  end
end

local function undo()
  local H = history()
  if not H then return end
  local e = H:undo()
  if e then hint("undo: " .. (e.label or "edit") .. "   ·   CTRL+Y redo", 1.5) end
end
local function redo()
  local H = history()
  if not H then return end
  local e = H:redo()
  if e then hint("redo: " .. (e.label or "edit"), 1.5) end
end

-- ── Picking & snapping ──────────────────────────────────────────────────────
local function screen_of(x, y, z)
  local sx, sy, _, on = camera.worldToScreen(x, y, z)
  return sx, sy, on
end

-- ── PICKING WITHOUT COLLIDERS (WP1, §8.2) ───────────────────────────────────
-- Parts on the stand have no bodies (visual-only spawns), so every pick is a
-- walk of the spatial hash along the cursor ray and an exact rayPart test of
-- the few parts it finds. W.visits counts the parts examined a frame (the
-- perf smoke asserts on it).
local function ensure_hash()
  if W.H then return W.H end
  local L = lib("builder_space")
  if not L then return nil end
  W.H = L.newHash(1.0, 0.5)
  for u, p in pairs(parts) do hash_put(u, p) end
  return W.H
end
-- Past 1,000 parts the cells grow to 2 m (fewer, fuller buckets).
local function rehash_if_needed()
  local H = W.H
  if not H then return end
  local want = (partCount > 1000) and 2.0 or 1.0
  if H.cell ~= want then
    H.cell = want
    H:clear()
    for u, p in pairs(parts) do hash_put(u, p) end
  end
end

-- The parts whose boxes (grown by `grow`, ≤ 0.5 m) the local ray passes,
-- nearest first.
local function near_ray(ox, oy, oz, dx, dy, dz, grow)
  local H = ensure_hash()
  if not H then
    local out = {}
    for u in pairs(parts) do out[#out + 1] = u end
    return out
  end
  return H:ray(ox, oy, oz, dx, dy, dz, 400.0, {}, grow or 0)
end

-- The first part a local ray meets (exact shape) → uid, t, point, normal.
-- `exclude` = set of uids to look through (carried parts, hidden ones).
local function ray_craft(ox, oy, oz, dx, dy, dz, exclude)
  local o = { x = ox, y = oy, z = oz }
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-12 then return nil end
  local d = { x = dx / l, y = dy / l, z = dz / l }
  local best, bt, bP, bn = nil, math.huge, nil, nil
  for _, u in ipairs(near_ray(ox, oy, oz, d.x, d.y, d.z, 0)) do
    local p = parts[u]
    if p and not p.hidden and not p.carried and not (exclude and exclude[u]) then
      W.visits = W.visits + 1
      local t, P, n = rayPart(p, o, d)
      if t and t < bt then best, bt, bP, bn = u, t, P, n end
    end
  end
  if not best then return nil end
  return best, bt, bP, bn
end

function rayCraft(ox, oy, oz, dx, dy, dz)
  local u, t, P, n = ray_craft(ox, oy, oz, dx, dy, dz)
  if not u then return nil end
  return u, t, P.x, P.y, P.z, n.x, n.y, n.z
end

local function part_under_cursor(px)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local u = ray_craft(ox, oy, oz, dx, dy, dz)
  if u then return u end
  -- Fallback: the nearest projected centre among parts near the ray (small
  -- parts between big ones).
  local best, best_d = nil, px * px
  for _, v in ipairs(near_ray(ox, oy, oz, dx, dy, dz, 0.5)) do
    local p = parts[v]
    if p and not p.hidden and not p.carried then
      W.visits = W.visits + 1
      local sx, sy, on = screen_of(p.x, p.y, p.z)
      if on then
        local d = (sx - mx) ^ 2 + (sy - my) ^ 2
        if d < best_d then best, best_d = v, d end
      end
    end
  end
  return best
end

-- In-game telegraphs (draw.* — always visible, unlike the editor's debug
-- gizmo layer). Rings mark attach nodes; boxes outline parts.
local function outline(p, r, g, b, a)
  -- An ORIENTED box: the part's own axes, its mesh's half-extents (drawObb).
  local hx, hy, hz = visHalf(p.id, p.def)
  drawObb(p.x, p.y, p.z, basisOf(p.yaw, p.pitch, p.roll), hx + 0.05, hy + 0.05, hz + 0.05,
          r, g, b, a or 1.0)
end

-- Is a stack node of `uid` in use? From the LINKS (never world Y: a part
-- lying down used to offer its occupied joint). Links to `exclude` (the parts
-- in hand) don't count. Returns the uid on the other end, or nil.
local function side_user(uid, side, exclude)
  local G = graph()
  if not G then return nil end
  for id in pairs(G.adj[uid] or {}) do
    local l = G.links[id]
    local o
    if l.a == uid and l.sa == side then o = l.b
    elseif l.b == uid and l.sb == side then o = l.a end
    if o and not (exclude and exclude[o]) and parts[o] then return o end
  end
  return nil
end

-- Is the point inside (70 % of) a placed part? (the hash, not every part)
local function is_side_occupied(px, py, pz, exclude)
  local H = ensure_hash()
  local list
  if H then list = H:box(px, py, pz, px, py, pz, {}) else list = {} for u in pairs(parts) do list[#list + 1] = u end end
  for _, uid in ipairs(list) do
    local q = parts[uid]
    if q and not (exclude and exclude[uid]) and not q.carried then
      W.visits = W.visits + 1
      local ex, ey, ez = part_extents(q)
      if math.abs(px - q.x) < ex * 0.7 and math.abs(py - q.y) < ey * 0.7
        and math.abs(pz - q.z) < ez * 0.7 then
        return true
      end
    end
  end
  return false
end

-- CACHED ATTACH FRAMES: a part's axes, worked out once per pose (p.pv).
local function part_axes(p)
  local c = p.axes
  if c and c.pv == p.pv then return c.X, c.Y, c.Z end
  local X, Y, Z = rot_basis(p.yaw, p.pitch, p.roll)
  p.axes = { pv = p.pv, X = X, Y = Y, Z = Z }
  return X, Y, Z
end

-- Every free attach node of part `p` for the current ghost: axial top/bottom
-- (along the part's OWN axis) + radial flank nodes on `side = true` parts.
-- Each node carries the point where the GHOST CENTRE would land. An OCCUPIED
-- stack node is offered as an INSERT (a new stack part goes between) when the
-- part in hand is a fresh stack part.
local function attach_nodes_of(uid, p, gdef, g_ext_y, exclude)
  local out = {}
  local X, Y, Z = part_axes(p)
  local hh = p.def.h * 0.5
  local fresh_stack = ghost and not ghost.carried and not ghost.paste and gdef.top and gdef.bottom
  if p.def.top and gdef.bottom then
    local user = side_user(uid, "top", exclude)
    if not user or fresh_stack then
      local ax, ay, az = p.x + Y.x * hh, p.y + Y.y * hh, p.z + Y.z * hh
      out[#out + 1] = { uid = uid, side = "top", x = ax, y = ay, z = az, insert = user,
        cx = ax + Y.x * g_ext_y, cy = ay + Y.y * g_ext_y, cz = az + Y.z * g_ext_y }
    end
  end
  if p.def.bottom and gdef.top then
    local user = side_user(uid, "bottom", exclude)
    if not user or fresh_stack then
      local ax, ay, az = p.x - Y.x * hh, p.y - Y.y * hh, p.z - Y.z * hh
      out[#out + 1] = { uid = uid, side = "bottom", x = ax, y = ay, z = az, insert = user,
        cx = ax - Y.x * g_ext_y, cy = ay - Y.y * g_ext_y, cz = az - Y.z * g_ext_y }
    end
  end
  -- Radial flanks: ghost sits side-by-side at the same height, its center
  -- pushed out by host half-width + the ghost's own half-width that way.
  if p.def.side then
    local gex, gey, gez = eff_extents(gdef, ghost.yaw, ghost.pitch, ghost.roll)
    local dirs
    if p.def.radial then
      -- A mounted radial decoupler's usable face is its disc's OUTWARD +Y.
      dirs = { { a = Y, r = hh } }
    else
      dirs = {
        { a = X, r = p.def.rx },
        { a = { x = -X.x, y = -X.y, z = -X.z }, r = p.def.rx },
        { a = Z, r = p.def.rz },
        { a = { x = -Z.x, y = -Z.y, z = -Z.z }, r = p.def.rz },
      }
    end
    for _, d in ipairs(dirs) do
      local g = math.abs(d.a.x) * gex + math.abs(d.a.y) * gey + math.abs(d.a.z) * gez
      local ax = p.x + d.a.x * d.r
      local ay = p.y + d.a.y * d.r
      local az = p.z + d.a.z * d.r
      local cx, cy, cz = ax + d.a.x * g, ay + d.a.y * g, az + d.a.z * g
      if not is_side_occupied(cx, cy, cz, exclude) then
        out[#out + 1] = { uid = uid, side = "radial", x = ax, y = ay, z = az,
          cx = cx, cy = cy, cz = cz, dx = d.a.x, dy = d.a.y, dz = d.a.z }
      end
    end
  end
  return out
end

-- The parts a snap may come from this frame: the parts near the cursor ray
-- plus the graph neighbours of the one it hits. Also what the node rings are
-- drawn on (the hit part and its neighbours only — §4.6).
local function snap_candidates(exclude)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local hit = ray_craft(ox, oy, oz, dx, dy, dz, exclude)
  local list, seen = {}, {}
  local function add(u)
    if not seen[u] and parts[u] and not (exclude and exclude[u]) and not parts[u].carried
      and not parts[u].hidden then
      seen[u] = true
      list[#list + 1] = u
    end
  end
  local show = {}
  if hit then
    add(hit)
    show[hit] = true
    local G = graph()
    if G then for _, n in ipairs(G:neighbours(hit)) do add(n); show[n] = true end end
  end
  for _, u in ipairs(near_ray(ox, oy, oz, dx, dy, dz, 0.5)) do add(u) end
  return list, show, hit
end

-- ── WP3's attach rules (builder_attach) ─────────────────────────────────────
-- attachRules() == "wp3" (the default once builder_attach.best exists): the
-- snap, the node rings, the joints and the welds come from WP3's rulebook.
-- "legacy" keeps the old node magnet (setAttachRules).
local function attach_v2()
  if W.attach == "legacy" then return nil end
  local A = lib("builder_attach")
  if not (A and A.best) then return nil end
  return A
end
-- A part as builder_attach reads it, cached per pose.
local function arec(u)
  local p = parts[u]
  if not p then return nil end
  local r = p.arec
  if r and r.pv == p.pv and r.def == p.def then return r end
  r = { uid = u, id = p.id, def = p.def, x = p.x, y = p.y, z = p.z, B = basisOf(p.yaw, p.pitch, p.roll),
        size = p.size, pv = p.pv }
  p.arec = r
  return r
end
local function alinks(u)
  local G = graph()
  return G and G:incident(u) or {}
end
-- The question for builder_attach this frame.
function attachQuery(held, exclude, cands, hit)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local q = {
    held = held, mouse = { x = mx, y = my },
    get = function(u)
      local p = parts[u]
      if not p or p.carried or p.hidden or (exclude and exclude[u]) then return nil end
      W.visits = W.visits + 1
      return arec(u)
    end,
    links = alinks, near = cands,
    project = function(x, y, z) local sx, sy, on = screen_of(x, y, z); return sx, sy, on end,
    grid = (W.grid > 0) and W.grid or 0, gridHull = (W.grid > 0) and math.max(W.grid, 0.25) or 0,
    angle = W.angle, free = input.key("shift"), cornerAngle = W.corner or math.pi / 2,
    floor = { y = params.floor_y, grid = (W.grid > 0) and math.max(W.grid, 0.05) or 0 },
    ray = { o = { x = ox, y = oy, z = oz }, d = { x = dx, y = dy, z = dz } },
    round = roundProfile,
  }
  if hit then
    local P, n = hit[3], hit[4]
    q.hit = { uid = hit[1], x = P.x, y = P.y, z = P.z, nx = n.x, ny = n.y, nz = n.z }
  end
  return q
end

local function find_snap_v2(A, gdef, exclude)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local hu, ht, hP, hn = ray_craft(ox, oy, oz, dx, dy, dz, exclude)
  if not hu then
    -- a collider hit (flight prefabs, before prefabs/vis/)
    local sc = surfaceUnderCursor(exclude)
    if sc then hu, ht, hP, hn = sc.uid, 0, { x = sc.x, y = sc.y, z = sc.z }, { x = sc.dx, y = sc.dy, z = sc.dz } end
  end
  local cands, show = snap_candidates(exclude)
  if hu and not show[hu] then show[hu] = true; cands[#cands + 1] = hu end
  ghost.show = show
  local q = attachQuery({ def = gdef, id = ghost.id, size = ghost.size, off = ghost.off or IDENT },
    exclude, cands, hu and { hu, ht, hP, hn } or nil)
  ghost.q = q
  -- an INSERT on an occupied stack joint is the builder's own (§5.4)
  if not ghost.carried and gdef.top and gdef.bottom then
    local _, g_ext_y = eff_extents(gdef, ghost.yaw, ghost.pitch, ghost.roll)
    local best, bd = nil, 24 * 24
    for u in pairs(show) do
      for _, a in ipairs(attach_nodes_of(u, parts[u], gdef, g_ext_y, exclude)) do
        if a.insert then
          local sx, sy, on = screen_of(a.x, a.y, a.z)
          local d = on and (sx - mx) ^ 2 + (sy - my) ^ 2 or math.huge
          if d < bd then best, bd = a, d end
        end
      end
    end
    if best then return best end
  end
  local c = A.best(q)
  q.snap = c
  if not c then return nil end
  local side = c.side or "surface"
  if c.kind ~= "stack" and side ~= "radial" then side = "surface" end
  return { wp3 = c, uid = c.host, side = side, floor = (c.kind == "floor") or nil,
           x = c.at and c.at.x or c.x, y = c.at and c.at.y or c.y, z = c.at and c.at.z or c.z,
           dx = c.n and c.n.x, dy = c.n and c.n.y, dz = c.n and c.n.z }
end

-- The best FREE attach node for the current ghost (nearest to the cursor on
-- screen, within snap_px) among the candidates; carried parts never attach to
-- themselves. With no node near: the surface under the cursor.
local function find_snap()
  if not ghost then return nil end
  do
    local A = attach_v2()
    if A then return find_snap_v2(A, ghost.def, ghost.exclude or {}) end
  end
  local gdef = ghost.def
  local mx, my = input.mouse()
  local best, best_d = nil, params.snap_px * params.snap_px
  local exclude = ghost.exclude or {}
  local cands, show = snap_candidates(exclude)
  ghost.show = show
  ghost.cands = cands
  local _, g_ext_y = eff_extents(gdef, ghost.yaw, ghost.pitch, ghost.roll)
  for _, uid in ipairs(cands) do
    W.visits = W.visits + 1
    local p = parts[uid]
    for _, a in ipairs(attach_nodes_of(uid, p, gdef, g_ext_y, exclude)) do
      local sx, sy, on = screen_of(a.x, a.y, a.z)
      if on then
        local d = (sx - mx) ^ 2 + (sy - my) ^ 2
        -- an INSERT only wins when it is clearly the node aimed at
        if a.insert then d = d * 2.0 end
        if d < best_d then best, best_d = a, d end
      end
    end
  end
  -- No node near the cursor: the surface under it (round two).
  if not best then best = surfaceUnderCursor(exclude) end
  return best
end

-- Would a part of `def` (at the ghost's orientation) centered at (x,y,z)
-- DEEPLY overlap a placed part? FORGIVING on purpose: only a near-total
-- overlap (one part buried inside another) is refused. Asks the hash.
local OVERLAP = 0.55
local function overlaps(def, x, y, z, exclude, gy, gp, gr)
  local ax, ay, az = eff_extents(def, gy, gp, gr)
  local H = ensure_hash()
  local list
  if H then
    list = H:box(x - ax, y - ay, z - az, x + ax, y + ay, z + az, {})
  else
    list = {}
    for u in pairs(parts) do list[#list + 1] = u end
  end
  for _, uid in ipairs(list) do
    local p = parts[uid]
    if p and not (exclude and exclude[uid]) and not p.carried then
      W.visits = W.visits + 1
      local bx, by, bz = part_extents(p)
      if math.abs(x - p.x) < (ax + bx) * OVERLAP
        and math.abs(y - p.y) < (ay + by) * OVERLAP
        and math.abs(z - p.z) < (az + bz) * OVERLAP then
        return true, uid
      end
    end
  end
  return false
end

-- Where a free-floating ghost sits: the cursor ray onto the build floor,
-- snapped to the floor grid; else held at the ship's depth (and not
-- placeable: free placement is on the floor).
local function free_pos()
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local _, gey = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
  local gh = gey + params.floor_y
  if dy < -1e-4 then
    local t = (gh - oy) / dy
    if t > 0.3 and t < 400 then
      local x, z = ox + dx * t, oz + dz * t
      local gs = (W.grid > 0 and not input.key("shift")) and math.max(W.grid, 0.05) or 0
      if gs > 0 then x, z = math.floor(x / gs + 0.5) * gs, math.floor(z / gs + 0.5) * gs end
      return x, gh, z, true
    end
  end
  center_now()
  local ddx, ddy, ddz = centerX - ox, centerY - oy, centerZ - oz
  local t = math.max(3.0, ddx * dx + ddy * dy + ddz * dz)
  return ox + dx * t, math.max(gh, oy + dy * t), oz + dz * t, false
end

-- Keep an angle readable: wrap to (-π, π].
local function wrap_angle(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a <= -math.pi do a = a + 2 * math.pi end
  return a
end

-- ── ROUND TWO: outward snapping, SURFACE attach and MIRROR symmetry ─────────
-- SURFACE ATTACH: away from every attach node, a part in hand snaps onto the
-- surface of whatever placed part is under the cursor, standing out of it
-- along that face's normal (a stack part's +Y, a flank part's +X), and R spins
-- it about that normal. Struts and beams (`axial_out`) snapped onto a flank
-- node point straight out of it the same way.
-- MIRROR (M): a flank or surface placement makes a mirrored PAIR across the
-- host's own X or Z plane — whichever faces the way you are attaching — which
-- is how a rover gets its left and right wheels in one click. A mirror pair is
-- a symmetry group like a ring (picked up, scrapped and moved as one); its
-- members carry `mir` = "x" | "z", the host axis they mirror across.
sym_mirror = false
function toggleMirror()
  sym_mirror = not sym_mirror
  if sym_mirror then sym_n = 1 end
  hint(sym_mirror and "mirror — a flank or surface placement makes a left/right pair (M again: off)"
    or "mirror off", 2.5)
  refresh_stats()
end

-- A basis (columns X, Y, Z) as the engine's YXZ Euler angles.
function eulerOf(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
  if math.abs(Z.y) > 1 - 1e-10 then
    -- Z straight up or down: yaw and roll turn about the same axis, so put
    -- the whole turn in yaw (roll 0 keeps X level: X = (cos yaw, 0, −sin yaw)).
    return math.atan2(-X.z, X.x), pitch, 0
  end
  return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
end

local function unit(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

local function cross3(a, b)
  return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end
local function dot3(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function norm3(v)
  local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  if l < 1e-12 then return { x = 0, y = 0, z = 0 } end
  return { x = v.x / l, y = v.y / l, z = v.z / l }
end
local function neg3(v) return { x = -v.x, y = -v.y, z = -v.z } end

-- v turned about unit axis k by angle a (Rodrigues).
local function turn_about(v, k, a)
  local c, s = math.cos(a), math.sin(a)
  local d = v.x * k.x + v.y * k.y + v.z * k.z
  local kx = cross3(k, v)
  return { x = v.x * c + kx.x * s + k.x * d * (1 - c), y = v.y * c + kx.y * s + k.y * d * (1 - c),
           z = v.z * c + kx.z * s + k.z * d * (1 - c) }
end

-- The orientation that stands `def` out of a face with outward unit normal n
-- on a world-aligned host (see attachBasis), spun by `spin` about n.
function attachOrient(def, nx, ny, nz, spin)
  local n = { x = nx, y = ny, z = nz }
  local B = attachBasis(def, "surface", n, IDENT)
  if spin and spin ~= 0 then B = basisMul(basisRot(norm3(n), spin), B) end
  return basisEuler(B)
end

-- How far a part's centre stands off the face it is attached to.
function attach_reach(def)
  if def.radial_orient then return def.rx end
  return def.h * 0.5
end

-- The placed part under the cursor and the face it shows there, skipping the
-- part in hand (and anything carried with it). nil when the cursor is over
-- nothing of the craft.
function surfaceUnderCursor(exclude)
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  -- The part's REAL shape (rayPart: round hulls are round), nearest along the
  -- ray, from the spatial hash. Parts in hand are looked through.
  local u, _, P, n = ray_craft(ox, oy, oz, dx, dy, dz, exclude)
  if u then
    return { uid = u, side = "surface", x = P.x, y = P.y, z = P.z, dx = n.x, dy = n.y, dz = n.z }
  end
  -- A part's collider, when it has one (flight prefabs, before prefabs/vis/):
  -- the engine ray, in the world, mapped back to the part by its node.
  if not raycast then return nil end
  local F = W.F
  local wox, woy, woz, wdx, wdy, wdz = ox, oy, oz, dx, dy, dz
  if F and not F.identity then
    wox, woy, woz = F.toWorld(ox, oy, oz)
    wdx, wdy, wdz = F.dirToWorld(dx, dy, dz)
  end
  local hit = raycast(wox, woy, woz, wdx, wdy, wdz, 300.0)
  local hu = hit and hit.node and W.bynode[hit.node.id]
  if not (hu and parts[hu] and hit.nx) or (exclude and exclude[hu]) or parts[hu].carried then return nil end
  local x, y, z, nx, ny, nz = hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz
  if F and not F.identity then
    x, y, z = F.toLocal(x, y, z)
    nx, ny, nz = F.dirToLocal(nx, ny, nz)
  end
  return { uid = hu, side = "surface", x = x, y = y, z = z, dx = nx, dy = ny, dz = nz }
end

-- Where the ghost goes for a snap, and how it is turned: the mount's ATTACH
-- FRAME (attachBasis) times the player's own turn (`ghost.off`, kept in that
-- frame — so a fin tipped 15° stays tipped 15° relative to the hull wherever it
-- is dropped next). The centre stands off the face by the part's extent along
-- the normal. Returns x, y, z and sets ghost.B and ghost.yaw/pitch/roll.
function snapPlace(snap)
  local g = ghost
  local def = g.def
  local host = parts[snap.uid]
  local hostB = host and basisOf(host.yaw, host.pitch, host.roll) or IDENT
  local n
  if snap.side == "top" then n = hostB.Y
  elseif snap.side == "bottom" then n = neg3(hostB.Y)
  else n = norm3({ x = snap.dx or 0, y = snap.dy or 1, z = snap.dz or 0 }) end
  local A = attachBasis(def, snap.side, n, hostB)
  local B = basisClean(basisMul(A, g.off or IDENT))
  g.A, g.n, g.B = A, n, B
  g.yaw, g.pitch, g.roll = basisEuler(B)
  local r = supportAlong(def, B, n)
  return snap.x + n.x * r, snap.y + n.y * r, snap.z + n.z * r
end

-- The mirror plane for a placement on `host` facing (dx,dy,dz): the host's
-- own X or Z axis, whichever that face looks along. Returns the axis vector
-- and its name, or nil for a face along the host's Y (a top or bottom face
-- has no opposite flank to mirror to).
function mirror_axis(host, dx, dy, dz)
  local X, Y, Z = rot_basis(host.yaw, host.pitch, host.roll)
  local ax = math.abs(dx * X.x + dy * X.y + dz * X.z)
  local az = math.abs(dx * Z.x + dy * Z.y + dz * Z.z)
  local ay = math.abs(dx * Y.x + dy * Y.y + dz * Y.z)
  if ay > ax and ay > az then return nil end
  if ax >= az then return X, "x" end
  return Z, "z"
end

local function axis_of(host, mir)
  local X, _, Z = rot_basis(host.yaw, host.pitch, host.roll)
  return mir == "x" and X or Z
end

-- Reflect a point across the plane through `host` with normal A, and a vector.
local function reflect_pt(host, A, x, y, z)
  local d = (x - host.x) * A.x + (y - host.y) * A.y + (z - host.z) * A.z
  return x - 2 * d * A.x, y - 2 * d * A.y, z - 2 * d * A.z
end
local function reflect_vec(A, v)
  local d = v.x * A.x + v.y * A.y + v.z * A.z
  return { x = v.x - 2 * d * A.x, y = v.y - 2 * d * A.y, z = v.z - 2 * d * A.z }
end

-- The mirror image of an orientation as a proper rotation: X and Y reflected,
-- Z re-derived (a reflection flips handedness; flipping the part's own Z
-- keeps a flank part's +X outward and its +Y up, and a stack part's axis).
function mirrorOrient(A, yaw, pitch, roll)
  local X, Y = rot_basis(yaw, pitch, roll)
  local X2, Y2 = reflect_vec(A, X), reflect_vec(A, Y)
  return eulerOf(X2, Y2, cross3(X2, Y2))
end

-- The mirror image of a basis as a proper rotation (see mirrorOrient).
function mirrorBasis(A, B)
  local X2, Y2 = reflect_vec(A, B.X), reflect_vec(A, B.Y)
  return { X = X2, Y = Y2, Z = cross3(X2, Y2) }
end

-- Symmetry is ON when the player has it on NOW: X (×2…×8) or M (mirror).
function symActive() return sym_mirror or sym_n > 1 end
function symMode() return sym_mirror and "mirror" or sym_n end

-- The COPIES a placement at (x, y, z) turned B makes, if symmetry is on now —
-- and only then (2026-10-23: placing on a part that was itself placed in a
-- ring used to copy round the ring whatever the mode said, "fighting
-- symmetry"). Each copy: { x, y, z, B, parent [, mir] }. Kinds:
--   "follow"  the host is a ring/mirror member: one copy on every OTHER member
--             (boosters: an engine under one goes under all)
--   "ring"    a ×N ring about a plain host's axis (radial/surface placements)
--   "mirror"  a mirrored pair across the host's X or Z plane
-- A copy is the placed pose ROTATED about the hub's axis (or reflected), the
-- whole frame with it — so a fin's tilt and roll come round the ring exactly.
function symCopies(snap, x, y, z, B, n)
  if not snap or not symActive() then return nil end
  local host = parts[snap.uid]
  if not host then return nil end
  if host.sym then
    local hub = group_hub(host.sym)
    if not hub then return nil end
    local out = {}
    if host.mir then
      local A = axis_of(hub, host.mir)
      for _, m in ipairs(group_members(host.sym)) do
        if m ~= snap.uid and parts[m] then
          local mx, my, mz = reflect_pt(hub, A, x, y, z)
          out[#out + 1] = { x = mx, y = my, z = mz, B = mirrorBasis(A, B), parent = m, mir = host.mir,
                            n = n and reflect_vec(A, n) }
        end
      end
      return out, "follow"
    end
    local hubB = basisOf(hub.yaw, hub.pitch, hub.roll)
    local a0 = angle_about(hub, host)
    for _, m in ipairs(group_members(host.sym)) do
      if m ~= snap.uid and parts[m] then
        -- angle_about runs X → Z, which is a NEGATIVE turn about the hub's +Y
        local da = angle_about(hub, parts[m]) - a0
        local px, py, pz, Bm = rotatePose(hub, hubB.Y, -da, x, y, z, B)
        out[#out + 1] = { x = px, y = py, z = pz, B = Bm, parent = m, n = n and turn_about(n, hubB.Y, -da) }
      end
    end
    return out, "follow"
  end
  if snap.side ~= "radial" and snap.side ~= "surface" then return nil end
  if sym_mirror then
    local A, name = mirror_axis(host, snap.dx, snap.dy, snap.dz)
    if not A then return nil end
    local mx, my, mz = reflect_pt(host, A, x, y, z)
    if (mx - x) ^ 2 + (my - y) ^ 2 + (mz - z) ^ 2 < 0.01 then return nil end
    return { { x = mx, y = my, z = mz, B = mirrorBasis(A, B), parent = snap.uid, mir = name,
               n = n and reflect_vec(A, n) } }, "mirror"
  end
  local hostB = basisOf(host.yaw, host.pitch, host.roll)
  local out = {}
  for k = 1, sym_n - 1 do
    local a = k * (2 * math.pi / sym_n)
    local px, py, pz, Bm = rotatePose(host, hostB.Y, a, x, y, z, B)
    out[#out + 1] = { x = px, y = py, z = pz, B = Bm, parent = snap.uid, n = n and turn_about(n, hostB.Y, a) }
  end
  return out, "ring"
end

-- A mirror group's partner pose for a member pose (position + orientation).
function mirrorPose(host, mir, x, y, z, yaw, pitch, roll)
  local A = axis_of(host, mir)
  local mx, my, mz = reflect_pt(host, A, x, y, z)
  local a, b, c = mirrorOrient(A, yaw, pitch, roll)
  return mx, my, mz, a, b, c
end
function mirrorVec(host, mir, dx, dy, dz)
  local v = reflect_vec(axis_of(host, mir), { x = dx, y = dy, z = dz })
  return v.x, v.y, v.z
end

-- ── ORIENTATION AS MATRICES (2026-10-23 playtest) ───────────────────────────
-- Every turn the builder makes is a ROTATION MATRIX — three world columns
-- {X, Y, Z}, a part's local axes — composed and only then written back as the
-- engine's YXZ euler. Adding angles to yaw/pitch/roll (what the rotate tool
-- used to do) turns about the wrong axis as soon as a part is tipped: a pitch
-- of a yawed part came out as a roll, which read as "inverted, and never the
-- direction I want".
local EX, EY, EZ = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
IDENT = { X = EX, Y = EY, Z = EZ }


function basisOf(yaw, pitch, roll)
  local X, Y, Z = rot_basis(yaw, pitch, roll)
  return { X = X, Y = Y, Z = Z }
end
-- B·v (local → world) and Bᵀ·v (world → local).
function basisApply(B, v)
  return { x = B.X.x * v.x + B.Y.x * v.y + B.Z.x * v.z,
           y = B.X.y * v.x + B.Y.y * v.y + B.Z.y * v.z,
           z = B.X.z * v.x + B.Y.z * v.y + B.Z.z * v.z }
end
function basisApplyT(B, v) return { x = dot3(B.X, v), y = dot3(B.Y, v), z = dot3(B.Z, v) } end
function basisMul(A, B) return { X = basisApply(A, B.X), Y = basisApply(A, B.Y), Z = basisApply(A, B.Z) } end
function basisT(B)
  return { X = { x = B.X.x, y = B.Y.x, z = B.Z.x }, Y = { x = B.X.y, y = B.Y.y, z = B.Z.y },
           Z = { x = B.X.z, y = B.Y.z, z = B.Z.z } }
end
-- Rotation by angle a about the unit axis k (right-handed).
function basisRot(k, a)
  return { X = turn_about(EX, k, a), Y = turn_about(EY, k, a), Z = turn_about(EZ, k, a) }
end
-- Re-square a basis that has been multiplied many times (keeps eulerOf exact).
function basisClean(B)
  local X = norm3(B.X)
  local d = dot3(B.Y, X)
  local Y = norm3({ x = B.Y.x - X.x * d, y = B.Y.y - X.y * d, z = B.Y.z - X.z * d })
  return { X = X, Y = Y, Z = cross3(X, Y) }
end
function basisEuler(B)
  local C = basisClean(B)
  return eulerOf(C.X, C.Y, C.Z)
end
-- The reflection-conjugate M·Q·M of a rotation (what a mirror partner does
-- when its twin turns by Q): reflect each column of Q applied to reflected axes.
function basisMirror(A, Q)
  local function M(v) return reflect_vec(A, v) end
  return { X = M(basisApply(Q, M(EX))), Y = M(basisApply(Q, M(EY))), Z = M(basisApply(Q, M(EZ))) }
end

-- The half-extents a part's OUTLINE is drawn with: what the mesh really
-- occupies. The registry's rx is sometimes an attach/overlap figure instead
-- (an engine's 0.9 clears its plume), which drew boxes half again too wide.
local VIS = {
  engineS = { 0.60, 0.65, 0.60 }, engineM = { 0.51, 0.80, 0.51 }, skipper = { 0.51, 0.80, 0.51 },
}
function visHalf(id, def)
  local v = VIS[id]
  if v then return v[1], v[2], v[3] end
  return def.rx, def.h * 0.5, def.rz
end

-- The 8 corners of a part's oriented box (centre, basis, half-extents).
function obbCorners(x, y, z, B, hx, hy, hz)
  local out = {}
  for _, s in ipairs({ { -1, -1, -1 }, { 1, -1, -1 }, { 1, -1, 1 }, { -1, -1, 1 },
                       { -1, 1, -1 }, { 1, 1, -1 }, { 1, 1, 1 }, { -1, 1, 1 } }) do
    local a, b, c = s[1] * hx, s[2] * hy, s[3] * hz
    out[#out + 1] = { x = x + B.X.x * a + B.Y.x * b + B.Z.x * c,
                      y = y + B.X.y * a + B.Y.y * b + B.Z.y * c,
                      z = z + B.X.z * a + B.Y.z * b + B.Z.z * c }
  end
  return out
end
local OBB_EDGES = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
                    { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
-- A wireframe box turned with the part on ALL THREE axes. draw.box only takes
-- a yaw, and it was being handed an extent that had ALREADY been rotated into
-- a world AABB — the yaw applied twice — so a part turned 90° drew its bounds
-- 90° off the mesh (1.png: the seat on a beam).
function drawObb(x, y, z, B, hx, hy, hz, r, g, b, a)
  local c = obbCorners(x, y, z, B, hx, hy, hz)
  for _, e in ipairs(OBB_EDGES) do
    local p, q = c[e[1]], c[e[2]]
    draw.line(p.x, p.y, p.z, q.x, q.y, q.z, r, g, b, a or 1.0)
  end
end

-- ── The SHAPE of a part, for surface attach ─────────────────────────────────
-- The hull colliders are all boxes, so the old surface attach took a BOX
-- face's normal on a round tank: a fin dropped anywhere but dead on a flank
-- node stood out along one of four box normals (and off the hull at the box's
-- corners) — "facing the wrong direction other than the first one". Round
-- parts are now surfaces of revolution: radius profiles measured off their
-- meshes, bottom → top at evenly spaced heights (tools/gen_part_meshes.py
-- shapes; re-measure if a mesh changes). Everything else is its box.
local ROUND = {
  pod = { 0.50, 0.50, 0.44, 0.41, 0.37, 0.34, 0.27, 0.20 },
  probe = { 0.42, 0.40, 0.38, 0.38, 0.38, 0.38, 0.40, 0.42 },
  nose = { 0.51, 0.50, 0.48, 0.44, 0.38, 0.32, 0.20, 0.04 },
  chute = { 0.22 },
  tankS = { 0.50 }, tankM = { 0.50 }, battery = { 0.50 }, cargo = { 0.50 },
  decoupler = { 0.51 }, radialDec = { 0.51 },
  engineS = { 0.41, 0.33, 0.27, 0.21, 0.12, 0.47, 0.50, 0.51 },
  engineM = { 0.49, 0.42, 0.35, 0.28, 0.19, 0.28, 0.28, 0.51 },
  skipper = { 0.39, 0.36, 0.33, 0.30, 0.27, 0.39, 0.47, 0.51 },
  radialTank = { 0.16, 0.30, 0.49, 0.44, 0.44, 0.49, 0.30, 0.16 },
  dockPort = { 0.53, 0.52, 0.45, 0.38, 0.38, 0.39, 0.37, 0.37 },
  adapter = { 0.51, 0.45, 0.43, 0.40, 0.36, 0.32, 0.28, 0.25 },
  strut1 = { 0.07 }, strut2 = { 0.07 }, strut3 = { 0.07 },
  fairingS = { 0.625 }, fairingM = { 1.25 },
  piston = { 0.16, 0.15, 0.15, 0.15, 0.14, 0.14, 0.12, 0.11 }, rotor = { 0.31 },
}
function roundProfile(id) return ROUND[id] end

-- Ray (o, d in the part's LOCAL frame) against a surface of revolution about
-- local Y, radius profile `prof` over y ∈ [-hh, hh]. → t, local normal.
function ray_round(prof, hh, o, d)
  local n = #prof
  local ys, rs = { -hh }, { prof[1] }
  for i = 1, n do ys[#ys + 1] = -hh + (i - 0.5) / n * 2 * hh; rs[#rs + 1] = prof[i] end
  ys[#ys + 1], rs[#rs + 1] = hh, prof[n]
  local best, bn = math.huge, nil
  local function take(t, nx, ny, nz)
    if t > 1e-4 and t < best then best, bn = t, norm3({ x = nx, y = ny, z = nz }) end
  end
  for i = 1, #ys - 1 do
    local y0, y1 = ys[i], ys[i + 1]
    if y1 - y0 > 1e-6 then
      local b = (rs[i + 1] - rs[i]) / (y1 - y0)
      local a = rs[i] - b * y0
      -- (ox + t dx)² + (oz + t dz)² = (a + b (oy + t dy))²
      local ry = a + b * o.y
      local A = d.x * d.x + d.z * d.z - (b * d.y) ^ 2
      local B2 = 2 * (o.x * d.x + o.z * d.z - ry * b * d.y)
      local C = o.x * o.x + o.z * o.z - ry * ry
      local roots = {}
      if math.abs(A) < 1e-9 then
        if math.abs(B2) > 1e-9 then roots[1] = -C / B2 end
      else
        local disc = B2 * B2 - 4 * A * C
        if disc >= 0 then
          local sq = math.sqrt(disc)
          roots[1], roots[2] = (-B2 - sq) / (2 * A), (-B2 + sq) / (2 * A)
        end
      end
      for _, t in ipairs(roots) do
        local y = o.y + t * d.y
        local r = a + b * y
        if y >= y0 - 1e-6 and y <= y1 + 1e-6 and r > 0 then
          take(t, o.x + t * d.x, -b * r, o.z + t * d.z)
        end
      end
    end
  end
  -- the end caps
  for _, s in ipairs({ -1, 1 }) do
    if math.abs(d.y) > 1e-9 then
      local t = (s * hh - o.y) / d.y
      local x, z = o.x + t * d.x, o.z + t * d.z
      local r = (s < 0) and prof[1] or prof[n]
      if x * x + z * z <= r * r then take(t, 0, s, 0) end
    end
  end
  if bn then return best, bn end
  return nil
end

-- Ray against an axis-aligned box (half-extents h) in the local frame (slabs).
function ray_box(hx, hy, hz, o, d)
  local tmin, tmax, nmin = -math.huge, math.huge, nil
  for _, ax in ipairs({ { "x", hx, EX }, { "y", hy, EY }, { "z", hz, EZ } }) do
    local k, h = ax[1], ax[2]
    if math.abs(d[k]) < 1e-12 then
      if math.abs(o[k]) > h then return nil end
    else
      local t1, t2 = (-h - o[k]) / d[k], (h - o[k]) / d[k]
      local s = -1
      if t1 > t2 then t1, t2 = t2, t1; s = 1 end
      if t1 > tmin then
        tmin = t1
        nmin = { x = 0, y = 0, z = 0 }
        nmin[k] = s
      end
      if t2 < tmax then tmax = t2 end
      if tmin > tmax then return nil end
    end
  end
  if tmin > 1e-4 and nmin then return tmin, nmin end
  return nil
end

-- Where a world ray (o, d) first meets part `p`'s real shape: t, world point,
-- world outward normal. nil = a miss.
function rayPart(p, o, d)
  local B = basisOf(p.yaw, p.pitch, p.roll)
  local rel = { x = o.x - p.x, y = o.y - p.y, z = o.z - p.z }
  local ol, dl = basisApplyT(B, rel), basisApplyT(B, d)
  local prof = ROUND[p.id]
  local t, nl
  if prof then
    t, nl = ray_round(prof, p.def.h * 0.5, ol, dl)
  else
    local hx, hy, hz = visHalf(p.id, p.def)
    t, nl = ray_box(hx, hy, hz, ol, dl)
  end
  if not t then return nil end
  local nw = norm3(basisApply(B, nl))
  return t, { x = o.x + d.x * t, y = o.y + d.y * t, z = o.z + d.z * t }, nw
end

-- ── Attach frames ───────────────────────────────────────────────────────────
-- The frame a part is mounted in, before the player's own turn is applied:
--   a stack node (top/bottom) or a booster on a flank node: the HOST's frame,
--     so a stack continues along a tipped host and a booster hangs parallel;
--   a fin-like part (radial_orient) on a face: +X out along the normal n,
--     +Y along the host's own axis — every fin round a tank comes out with the
--     same roll, wherever on the hull it is dropped;
--   anything else on a face (radial decoupler, a strut, a panel): +Y out
--     along n, +X along the host's axis;
--   nothing under it: the world.
local function perp_ref(n, refs)
  for _, r in ipairs(refs) do
    local d = dot3(r, n)
    if math.abs(d) < 0.95 then
      return norm3({ x = r.x - n.x * d, y = r.y - n.y * d, z = r.z - n.z * d })
    end
  end
  return nil
end
function attachBasis(def, side, n, hostB)
  hostB = hostB or IDENT
  if side == "top" or side == "bottom" then return hostB end
  if not n then return IDENT end
  if side == "radial" and not (def.radial_orient or def.radial or def.axial_out) then return hostB end
  n = norm3(n)
  if def.radial_orient then
    local Y = perp_ref(n, { hostB.Y, hostB.Z, EY })
    return { X = n, Y = Y, Z = cross3(n, Y) }
  end
  local X = perp_ref(n, { hostB.Y, hostB.X, EX })
  return { X = X, Y = n, Z = cross3(X, n) }
end
-- How far the centre of a part turned B stands off a face with normal n.
function supportAlong(def, B, n)
  return math.abs(dot3(n, B.X)) * def.rx + math.abs(dot3(n, B.Y)) * def.h * 0.5
       + math.abs(dot3(n, B.Z)) * def.rz
end
-- Rotate a pose (position + basis) about the axis through c along k by a.
function rotatePose(c, k, a, x, y, z, B)
  local v = turn_about({ x = x - c.x, y = y - c.y, z = z - c.z }, k, a)
  local R = basisRot(k, a)
  return c.x + v.x, c.y + v.y, c.z + v.z, basisMul(R, B)
end

-- Open (once per editing streak) the history step an edit of `uid` lands
-- in: a merge key per part, so arrow presses and a gizmo drag on one part are
-- one step until something else happens (history():seal()).
local nudge_uid = nil
local function edit_begin(uid, set)
  local t = tx_begin("edit " .. ((parts[uid] and parts[uid].def.label) or "part"),
    set or edit_set(uid), "edit:" .. tostring(uid))
  tx_commit(t)
  nudge_uid = uid
end
local function tx_add(t, uids)
  if t.merged then return end
  local more = {}
  for k, v in pairs(uids) do
    local u = (type(k) == "number" and v == true) and k or v
    if type(u) == "number" and not t.has[u] then more[#more + 1] = u end
  end
  if #more == 0 then return end
  local S = snap_parts(more)
  local lseen = {}
  for _, l in ipairs(t.before.links) do lseen[l.id] = true end
  for _, u in ipairs(S.order) do
    t.has[u] = true
    t.before.order[#t.before.order + 1] = u
    t.before.parts[u] = S.parts[u]
  end
  for _, l in ipairs(S.links) do
    if not lseen[l.id] then t.before.links[#t.before.links + 1] = l end
  end
end

local function apply_edit(uid, ddx, ddy, ddz, dyaw, dpitch, droll)
  local p = parts[uid]
  if not p then return end
  edit_begin(uid)
  local turned = dyaw ~= 0 or dpitch ~= 0 or droll ~= 0
  local hub = p.sym and group_hub(p.sym) or nil
  if hub and p.mir then
    -- A MIRROR pair: edit this one, and its partner becomes its reflection
    -- (its stack moving by the reflected displacement).
    if turned then
      set_part_rot(p, wrap_angle((p.yaw or 0) + dyaw), wrap_angle((p.pitch or 0) + dpitch),
                   wrap_angle((p.roll or 0) + droll))
    end
    for u in pairs(subtree(uid)) do
      local q = parts[u]
      if q then set_part_pos(q, q.x + ddx, q.y + ddy, q.z + ddz) end
    end
    local rdx, rdy, rdz = mirrorVec(hub, p.mir, ddx, ddy, ddz)
    for _, m in ipairs(group_members(p.sym)) do
      local q = parts[m]
      if q and m ~= uid then
        for u in pairs(subtree(m)) do
          local sub = parts[u]
          if sub and u ~= m then set_part_pos(sub, sub.x + rdx, sub.y + rdy, sub.z + rdz) end
        end
        local x2, y2, z2, a, b, c = mirrorPose(hub, p.mir, p.x, p.y, p.z, p.yaw, p.pitch, p.roll)
        set_part_pos(q, x2, y2, z2)
        set_part_rot(q, a, b, c)
      end
    end
  elseif hub then
    local a0 = angle_about(hub, p)
    for _, m in ipairs(group_members(p.sym)) do
      local q = parts[m]
      if q then
        local da = angle_about(hub, q) - a0
        local rdx, rdy, rdz = rot_about(hub, ddx, ddy, ddz, da)
        for u in pairs(subtree(m)) do
          local sub = parts[u]
          if sub then set_part_pos(sub, sub.x + rdx, sub.y + rdy, sub.z + rdz) end
        end
        if turned then
          set_part_rot(q, wrap_angle((q.yaw or 0) + dyaw),
                       wrap_angle((q.pitch or 0) + dpitch),
                       wrap_angle((q.roll or 0) + droll))
        end
      end
    end
  else
    if turned then
      set_part_rot(p, wrap_angle((p.yaw or 0) + dyaw),
                   wrap_angle((p.pitch or 0) + dpitch),
                   wrap_angle((p.roll or 0) + droll))
    end
    if ddx ~= 0 or ddy ~= 0 or ddz ~= 0 then
      for u in pairs(subtree(uid)) do
        local q = parts[u]
        if q then set_part_pos(q, q.x + ddx, q.y + ddy, q.z + ddz) end
      end
    end
  end
  publish_center()
  refresh_stats()
end

-- ── ROTATING (2026-10-23: "the rotation tool feels limiting … inverted") ────
-- KSP's keys: W/S pitch, A/D yaw, Q/E roll — 90° a press, SHIFT 15° — R spins
-- the part about the face it is mounted on (15°, SHIFT 5°), SPACE puts it back
-- to how its mount stands it, and C switches what all of them (and the rotate
-- gizmo's rings) turn about:
--   CAMERA  world axes picked by the view: W always tips the part's top AWAY
--           from you and D always turns its near face to your right
--   PART    the part's own axes, however it is already turned
-- The keys work on a part in hand, and on the selection in the ROTATE tool
-- (the camera's own W/A/S/D/Q/E fly yields to them then; hold RMB to fly).
ROT_FRAME = "camera"
ROT_SNAP = math.pi / 12   -- the rotate gizmo's notch (SHIFT drags free)
rotKeysBusy = false       -- read by builder_camera

-- The pitch / yaw / roll axes (world unit vectors) for a part turned B.
function rotAxes(B)
  if ROT_FRAME == "part" and B then return B.X, B.Y, B.Z end
  local sx, sy, sw, sh = 0, 0, 1920, 1080
  if camera.screenRect then
    local a, b, c, d = camera.screenRect()
    if c and c > 0 and d and d > 0 then sx, sy, sw, sh = a, b, c, d end
  end
  local cx, cy = sx + sw * 0.5, sy + sh * 0.5
  local _, _, _, d1x, _, d1z = camera.screenToRay(cx, cy)
  local _, _, _, d2x, _, d2z = camera.screenToRay(cx + 40, cy)
  local rx, rz = d2x - d1x, d2z - d1z
  local right
  if math.abs(rx) >= math.abs(rz) then right = { x = (rx >= 0) and 1 or -1, y = 0, z = 0 }
  else right = { x = 0, y = 0, z = (rz >= 0) and 1 or -1 } end
  return right, EY, cross3(EY, right) -- (up × right = straight away from you)
end

-- One frame of rotation keys as a world rotation Q (nil = none). B is what is
-- being turned, n the face it is mounted on; `wasd` = the W/A/S/D/Q/E set too.
function rotKeysQ(B, n, wasd)
  local fine = input.key("shift")
  local big = fine and ((ROT_SNAP and ROT_SNAP > 0) and ROT_SNAP or math.pi / 12) or math.pi / 2
  local P, Yw, Rl = rotAxes(B)
  local Q = nil
  local function turn(k, a)
    local R = basisRot(k, a)
    Q = Q and basisMul(R, Q) or R
  end
  if wasd then
    if input.pressed("w") then turn(P, -big) end
    if input.pressed("s") then turn(P, big) end
    if input.pressed("a") then turn(Yw, -big) end
    if input.pressed("d") then turn(Yw, big) end
    if input.pressed("q") then turn(Rl, -big) end
    if input.pressed("e") then turn(Rl, big) end
  end
  if input.pressed("r") then turn(n or (B and B.Y) or EY, fine and (math.pi / 36) or (math.pi / 12)) end
  return Q
end

-- The face a placed part is mounted on, as a world normal (+ its host's
-- basis): the host-local normal stored at placement, else read off where the
-- part sits on its host. nil for a part with no host.
function mountNormal(uid)
  local p = parts[uid]
  local h = p and p.parent and parts[p.parent]
  if not h then return nil end
  local hB = basisOf(h.yaw, h.pitch, h.roll)
  if p.att == "top" then return hB.Y, hB end
  if p.att == "bottom" then return neg3(hB.Y), hB end
  if p.an then return norm3(basisApply(hB, p.an)), hB end
  local rel = basisApplyT(hB, { x = p.x - h.x, y = p.y - h.y, z = p.z - h.z })
  local nl
  local prof = ROUND[h.id]
  if prof then
    local rr = math.sqrt(rel.x * rel.x + rel.z * rel.z)
    if rr < 1e-6 or math.abs(rel.y) / (h.def.h * 0.5) > rr / math.max(prof[1], 1e-3) then
      nl = { x = 0, y = (rel.y >= 0) and 1 or -1, z = 0 }
    else
      nl = { x = rel.x / rr, y = 0, z = rel.z / rr }
    end
  else
    local hx, hy, hz = visHalf(h.id, h.def)
    local ax, ay, az = math.abs(rel.x) / hx, math.abs(rel.y) / hy, math.abs(rel.z) / hz
    if ax >= ay and ax >= az then nl = { x = (rel.x >= 0) and 1 or -1, y = 0, z = 0 }
    elseif ay >= az then nl = { x = 0, y = (rel.y >= 0) and 1 or -1, z = 0 }
    else nl = { x = 0, y = 0, z = (rel.z >= 0) and 1 or -1 } end
  end
  return norm3(basisApply(hB, nl)), hB
end
-- How the part's mount stands it, before any turn of the player's: the frame
-- SPACE resets to (the world's, for a part on nothing).
function mountFrame(uid)
  local p = parts[uid]
  if not p then return IDENT end
  local n, hB = mountNormal(uid)
  if not n then return IDENT end
  return attachBasis(p.def, p.att or "top", n, hB)
end

-- Turn a placed part by the world rotation Q about its own centre, carrying
-- everything stacked on it. A symmetry member turns its whole ring, each
-- counterpart by Q carried round to it (a ring: conjugated by the ring angle;
-- a mirror pair: the reflection M·Q·M) — so a fin tipped one way tips every
-- fin the same way RELATIVE TO THE HULL, mirrored where it should be.
function rotateSelection(uid, Q)
  local p = parts[uid]
  if not p then return end
  edit_begin(uid)
  local function turn_tree(root_uid, Qm)
    local c = parts[root_uid]
    if not c then return end
    local cx, cy, cz = c.x, c.y, c.z
    for u in pairs(subtree(root_uid)) do
      local q = parts[u]
      if q then
        local v = basisApply(Qm, { x = q.x - cx, y = q.y - cy, z = q.z - cz })
        set_part_pos(q, cx + v.x, cy + v.y, cz + v.z)
        set_part_rot(q, basisEuler(basisMul(Qm, basisOf(q.yaw, q.pitch, q.roll))))
      end
    end
  end
  local hub = p.sym and group_hub(p.sym) or nil
  if hub and p.mir then
    local Qm = basisMirror(axis_of(hub, p.mir), Q)
    for _, m in ipairs(group_members(p.sym)) do turn_tree(m, (m == uid) and Q or Qm) end
  elseif hub then
    local hubB = basisOf(hub.yaw, hub.pitch, hub.roll)
    local a0 = angle_about(hub, p)
    for _, m in ipairs(group_members(p.sym)) do
      if parts[m] then
        local R = basisRot(hubB.Y, -(angle_about(hub, parts[m]) - a0))
        turn_tree(m, basisMul(R, basisMul(Q, basisT(R))))
      end
    end
  else
    turn_tree(uid, Q)
  end
  publish_center()
  refresh_stats()
end

-- SPACE on a placed part: back to its mount's frame (and its ring with it).
function resetSelection(uid)
  local p = parts[uid]
  if not p then return end
  local Q = basisMul(mountFrame(uid), basisT(basisOf(p.yaw, p.pitch, p.roll)))
  rotateSelection(uid, basisClean(Q))
end

-- A turn of the part in hand: Q is a WORLD rotation; the ghost keeps it in its
-- attach frame (ghost.off), so it rides along to the next face it snaps to.
function ghostRotate(Q)
  local g = ghost
  if not g then return end
  local A = g.A or IDENT
  g.off = basisClean(basisMul(basisT(A), basisMul(Q, basisMul(A, g.off or IDENT))))
end

-- The rotation keys, every frame (cam_busy = RMB, the camera's).
function rotKeysTick(cam_busy)
  local sel = selected_uid and parts[selected_uid]
  -- §4.3: W/S A/D Q/E always turn the held part or the selection; the camera
  -- flies on them only with RMB held (cam_busy).
  rotKeysBusy = (ghost ~= nil) or (sel ~= nil)
  if cam_busy then return end
  if input.pressed("l") and not input.key("ctrl") then
    ROT_FRAME = (ROT_FRAME == "camera") and "part" or "camera"
    ui("tool", 0.7)
    hint(ROT_FRAME == "camera"
      and "gizmo space WORLD — keys and rings turn about the world (picked by the view)   ·   L: LOCAL"
      or "gizmo space LOCAL — keys and rings turn about the part's own axes   ·   L: WORLD", 3.0)
  end
  if ghost then
    if input.pressed("space") then
      ghost.off = IDENT
      hint("rotation reset — the part stands the way its mount holds it", 2.0)
    end
    local Q = rotKeysQ(ghost.B, ghost.n, true)
    if Q then ghostRotate(Q) end
    return
  end
  if sel and tool ~= "stage" and tool ~= "groups" and not input.key("ctrl") then
    if input.pressed("space") then
      resetSelection(selected_uid)
      hint("rotation reset", 1.5)
    end
    local Q = rotKeysQ(basisOf(sel.yaw, sel.pitch, sel.roll), mountNormal(selected_uid), true)
    if Q then rotateMulti(Q) end
  end
end

-- The part in hand follows the cursor: snapped (snapPlace) or free, then
-- posed — a carried stack moves RIGIDLY with its root, turns included.
-- Returns snap, x, y, z.
function ghostFollow()
  local snap = find_snap()
  local x, y, z
  if snap and snap.wp3 then
    -- WP3: the candidate IS the pose
    local c = snap.wp3
    ghost.B = c.B
    ghost.A = basisClean(basisMul(c.B, basisT(ghost.off or IDENT)))
    ghost.n = snap.uid and c.n or nil
    ghost.yaw, ghost.pitch, ghost.roll = basisEuler(c.B)
    x, y, z = c.x, c.y, c.z
    ghost.on_floor = snap.floor == true
    if snap.floor then snap = nil end
  elseif snap then
    x, y, z = snapPlace(snap)
    ghost.on_floor = false
  else
    ghost.A, ghost.n = IDENT, nil
    ghost.B = basisClean(ghost.off or IDENT)
    ghost.yaw, ghost.pitch, ghost.roll = basisEuler(ghost.B)
    x, y, z, ghost.on_floor = free_pos()
  end
  if ghost.carried then
    for _, m in ipairs(ghost.carried) do
      local p = parts[m.uid]
      if p and m.rel then
        local v = basisApply(ghost.B, m.rel)
        set_part_pos(p, x + v.x, y + v.y, z + v.z)
        set_part_rot(p, basisEuler(basisMul(ghost.B, m.relB)))
      end
    end
  elseif ghost.node then
    ghost.node.x, ghost.node.y, ghost.node.z = x, y, z
    ghost.node.yaw, ghost.node.pitch, ghost.node.roll = ghost.yaw, ghost.pitch, ghost.roll
  end
  return snap, x, y, z
end

-- Preview every copy symmetry would make (amber boxes, the part's own turn).
function drawCopies(copies)
  if not (copies and ghost) then return end
  local hx, hy, hz = visHalf(ghost.id, ghost.def)
  for _, c in ipairs(copies) do
    drawObb(c.x, c.y, c.z, c.B, hx, hy, hz, 1.0, 0.75, 0.3, 0.75)
    local Xa = c.B.X
    draw.line(c.x, c.y, c.z, c.x + Xa.x * 0.35, c.y + Xa.y * 0.35, c.z + Xa.z * 0.35, 1.0, 0.75, 0.3, 0.75)
  end
end

-- Place the copies a symmetric placement makes (after the ghost itself went
-- down as `placed`): one symmetry group, ONE undo op for the lot.
function placeCopies(placed, copies, kind, n)
  local root = parts[placed]
  if not root then return end
  next_sym = next_sym + 1
  local gid = next_sym
  root.sym = gid
  if kind == "mirror" then root.mir = copies[1].mir
  elseif kind == "follow" and copies[1] and copies[1].mir then root.mir = copies[1].mir end
  local uids = { placed }
  for _, c in ipairs(copies) do
    local yaw, pitch, roll = basisEuler(c.B)
    local u = spawn_part(root.id, c.x, c.y, c.z, yaw, c.parent, nil, pitch, roll, root.att, gid, c.mir)
    uids[#uids + 1] = u
    if W.ptx then tx_touch(W.ptx, u) end
    if c.n and parts[c.parent] and parts[u] then
      local h = parts[c.parent]
      parts[u].an = basisApplyT(basisOf(h.yaw, h.pitch, h.roll), c.n)
    end
  end
  struct_changed()
  if kind == "follow" then
    hint(string.format("symmetry: copied onto all %d of the ring — X off to place just one", #uids), 2.5)
  elseif kind == "mirror" then
    hint("mirrored pair placed — CTRL+Z removes both", 2.0)
  else
    hint(string.format("×%d ring placed — CTRL+Z removes it all", #uids), 2.5)
  end
end
-- Mount normals for copies whose spawn has not landed yet (spawn is async).
copyNormal = {}

-- ── Transform gizmos (editor-style, tool-specific) ──────────────────────────
-- ONE gizmo at a time, on the SELECTED part, for the ACTIVE tool: the MOVE
-- tool shows three solid arrows (world X/Y/Z, filled cone heads); the ROTATE
-- tool shows three solid rings (filled bands about those axes). Grab a handle
-- and drag: an arrow moves along its axis, a ring turns about it (SHIFT = fine
-- / 15° snap). Standard R/G/B axis colors so it reads at a glance.
local GIZ_AXES = {
  { x = 1, y = 0, z = 0, r = 0.95, g = 0.30, b = 0.28 }, -- X (red)  → pitch
  { x = 0, y = 1, z = 0, r = 0.40, g = 0.90, b = 0.42 }, -- Y (green)→ yaw
  { x = 0, y = 0, z = 1, r = 0.35, g = 0.55, b = 1.0 },  -- Z (blue) → roll
}
local gizmo_drag = nil -- { uid, kind = "move"|"turn", axis, lmx, lmy, acc }

-- The gizmo's size scales with the selected part so it never swamps a small
-- part or hides inside a big one. Returns the arrow length + ring radius.
function gizmo_dims(p)
  local ex, ey, ez = part_extents(p)
  local reach = math.max(ex, ey, ez)
  return 1.15 + reach * 0.5, 0.85 + reach * 0.55
end

-- Two unit vectors spanning the plane ⊥ to axis `a` (for the rotate ring).
-- (Any axis now: the rings follow the part in the PART rotation frame.)
function ring_basis(a)
  local u = perp_ref(a, { EY, EX })
  local v = cross3(a, u)
  return u.x, u.y, u.z, v.x, v.y, v.z
end

-- The rotate gizmo's three rings: world X/Y/Z in the CAMERA frame, the
-- part's own axes in the PART frame (C). Same colours either way.
-- OFFSET in LOCAL space: the MOUNT frame (two along the host face, one along
-- its normal), so "slide along the hull" is one arrow.
function gizmoAxes(p, tool)
  if ROT_FRAME ~= "part" then return GIZ_AXES end
  local B
  if tool == "rotate" then B = basisOf(p.yaw, p.pitch, p.roll)
  elseif p.uid and p.parent then B = mountFrame(p.uid)
  else return GIZ_AXES end
  local out = {}
  for i, k in ipairs({ B.X, B.Y, B.Z }) do
    local c = GIZ_AXES[i]
    out[i] = { x = k.x, y = k.y, z = k.z, r = c.r, g = c.g, b = c.b }
  end
  return out
end

local function draw_gizmo(p, tool)
  local len, rad = gizmo_dims(p)
  if tool == "rotate" then
    for _, a in ipairs(gizmoAxes(p, tool)) do
      -- A solid band (filled annulus) reads as a real ring, not a thin line.
      draw.disc(p.x, p.y, p.z, a.x, a.y, a.z, rad * 0.9, rad, a.r, a.g, a.b, 0.7)
    end
    -- a small hub so the pivot is obvious
    draw.sphere(p.x, p.y, p.z, 0.09, 0.9, 0.9, 0.95, 1.0)
  else -- offset
    for _, a in ipairs(gizmoAxes(p, tool)) do
      local hx, hy, hz = p.x + a.x * len, p.y + a.y * len, p.z + a.z * len
      -- shaft
      draw.line(p.x, p.y, p.z, hx, hy, hz, a.r, a.g, a.b, 1.0)
      -- solid cone arrowhead (base a bit back from the tip)
      local bl = 0.26
      draw.cone(hx - a.x * bl, hy - a.y * bl, hz - a.z * bl,
        a.x, a.y, a.z, 0.11, bl, a.r, a.g, a.b, 1.0)
    end
    draw.box(p.x, p.y, p.z, 0.09, 0.09, 0.09, 0, 0.95, 0.95, 1.0, 1.0)
  end
  return len, rad
end

-- Which handle is under the cursor for `tool`? → kind, axis index (nil none).
-- Generously sampled: a big rotate ring at a shallow angle projects to a long
-- screen arc, so we walk it densely and use a fat pixel radius — aiming at a
-- ring should GRAB it, never fall through to a deselect.
-- MEASURED TO THE DRAWN LINE, NOT TO ITS SAMPLES (playtest 2026-10-27: "rotating
-- or moving parts with the gizmo keeps accidentally picking up and moving
-- parts"). The ring's 48 points and the shaft's 10 were tested as points: on a
-- ring a few hundred pixels across, the gap between two points left a press
-- right ON the band 30–40 px from either, a miss — and the press fell through
-- to the part under it, which a 6 px drag then picked up. Now the distance is
-- to the segment between neighbouring points (a ring is a polyline, an arrow
-- its shaft to the tip of its cone). `slack` (px) widens the catch: a press
-- inside the gizmo's footprint takes the nearest handle within GIZ_NEAR_PX.
GIZ_HIT_PX = 22
GIZ_NEAR_PX = 40
function gizmoSegD2(mx, my, ax, ay, bx, by)
  local vx, vy = bx - ax, by - ay
  local l2 = vx * vx + vy * vy
  local t = 0
  if l2 > 1e-9 then t = math.max(0, math.min(1, ((mx - ax) * vx + (my - ay) * vy) / l2)) end
  local px, py = ax + vx * t - mx, ay + vy * t - my
  return px * px + py * py, t
end
local function gizmo_hit(p, tool, len, rad, slack)
  local mx, my = input.mouse()
  local lim = slack or GIZ_HIT_PX
  local best, best_kind, best_d = nil, nil, lim * lim
  local best_pt = nil
  if tool == "rotate" then
    for ai, a in ipairs(gizmoAxes(p, tool)) do
      local ux, uy, uz, vx2, vy2, vz2 = ring_basis(a)
      local psx, psy, pon, pw = nil, nil, false, nil
      for k = 0, 48 do
        local t = k * (2 * math.pi / 48)
        local cx = p.x + (ux * math.cos(t) + vx2 * math.sin(t)) * rad
        local cy2 = p.y + (uy * math.cos(t) + vy2 * math.sin(t)) * rad
        local cz = p.z + (uz * math.cos(t) + vz2 * math.sin(t)) * rad
        local sx, sy, on = screen_of(cx, cy2, cz)
        if on and pon then
          local d, f = gizmoSegD2(mx, my, psx, psy, sx, sy)
          if d < best_d then
            best, best_kind, best_d = ai, "turn", d
            local w = { x = cx, y = cy2, z = cz }
            if f < 0.5 and pw then w = pw end
            best_pt = w
          end
        end
        psx, psy, pon, pw = sx, sy, on, { x = cx, y = cy2, z = cz }
      end
    end
  else
    for ai, a in ipairs(gizmoAxes(p, tool)) do
      -- the whole arrow, from a little out of the centre to the cone's tip
      local x0, y0, on0 = screen_of(p.x + a.x * len * 0.15, p.y + a.y * len * 0.15, p.z + a.z * len * 0.15)
      local x1, y1, on1 = screen_of(p.x + a.x * len, p.y + a.y * len, p.z + a.z * len)
      if on0 and on1 then
        local d = gizmoSegD2(mx, my, x0, y0, x1, y1)
        if d < best_d then best, best_kind, best_d = ai, "move", d end
      end
    end
  end
  if best then return best_kind, best, best_pt end
  return nil
end

-- One frame of a rotate-ring drag: the mouse moved (dmx, dmy) to (mx, my).
-- A ring that FACES you turns like a dial — the part follows the cursor round
-- the centre; a ring seen edge-on turns as the cursor slides along the way
-- the ring travels where you grabbed it. Either way it goes the way the mouse
-- goes. ROT_SNAP notches (15°) unless SHIFT is held. Returns the total turn.
function gizmoTurn(p, gd, mx, my, dmx, dmy)
  local k = gd.k
  local csx, csy = screen_of(p.x, p.y, p.z)
  local ox, oy, oz = camera.screenToRay(csx, csy)
  local f = norm3({ x = p.x - ox, y = p.y - oy, z = p.z - oz })
  local facing = dot3(k, f)
  local dth = 0
  if math.abs(facing) > 0.3 then
    local a1 = math.atan2(my - dmy - csy, mx - dmx - csx)
    local a2 = math.atan2(my - csy, mx - csx)
    local da = wrap_angle(a2 - a1)
    -- y runs DOWN the screen, so a turn that looks counter-clockwise has a
    -- falling screen angle; +about k looks counter-clockwise from k's tip.
    if (mx - csx) ^ 2 + (my - csy) ^ 2 > 64 then dth = (facing < 0) and -da or da end
  else
    local P = gd.P or { x = p.x, y = p.y + 1, z = p.z }
    local t = norm3(cross3(k, { x = P.x - p.x, y = P.y - p.y, z = P.z - p.z }))
    local e = 0.05 * (gd.rad or 1)
    local s0x, s0y = screen_of(P.x, P.y, P.z)
    local s1x, s1y = screen_of(P.x + t.x * e, P.y + t.y * e, P.z + t.z * e)
    local vx, vy = (s1x - s0x) / 0.05, (s1y - s0y) / 0.05 -- px per radian
    local l2 = vx * vx + vy * vy
    if l2 > 25 then dth = (dmx * vx + dmy * vy) / l2 end
  end
  gd.acc = (gd.acc or 0) + dth
  local free = input.key("shift") or not ROT_SNAP or ROT_SNAP <= 0
  local target = free and gd.acc or math.floor(gd.acc / ROT_SNAP + 0.5) * ROT_SNAP
  local delta = target - (gd.applied or 0)
  if math.abs(delta) > 1e-9 then
    gd.applied = target
    rotateMulti(basisRot(k, delta), gd.uid)
  end
  return gd.applied or 0
end

-- The screen-space bounding radius of the selection's gizmo (center + max
-- reach to any handle tip, in pixels). A click INSIDE this footprint that
-- misses a handle must NOT deselect — the player was aiming at the gizmo.
function gizmo_footprint_px(p, tool, len, rad)
  local cx, cy, on = screen_of(p.x, p.y, p.z)
  if not on then return nil end
  local reach = (tool == "rotate") and rad or len
  local maxr = 26 -- always swallow a near-center miss
  for _, a in ipairs(GIZ_AXES) do
    for _, s in ipairs({ 1, -1 }) do
      local sx, sy, o2 = screen_of(p.x + a.x * reach * s, p.y + a.y * reach * s,
        p.z + a.z * reach * s)
      if o2 then
        local d = math.sqrt((sx - cx) ^ 2 + (sy - cy) ^ 2)
        if d > maxr then maxr = d end
      end
    end
  end
  return cx, cy, maxr
end

-- The catalogue's buttons ask for these: what a part is called and costs, and
-- whether R&D has opened it yet.
function partInfo(id)
  return REG[id]
end

-- The research click that is waiting for its confirmation: { id, t } or nil.
-- The catalogue reads it to paint that card's price as "confirm".
RESEARCH_CONFIRM = 5.0
researchArmed = nil
function researchPending(id)
  local a = researchArmed
  return a ~= nil and a.id == id and time - a.t <= RESEARCH_CONFIRM
end

-- Let a catalogue button push a line into the builder's hint bar (it has no
-- text node of its own, and the hint bar is where every other explanation in
-- this scene appears).
function hintNow(msg, secs)
  hint(msg, secs or 3.0)
end

-- ── The catalogue calls this (findScript("builder").pick) ───────────────────
function pick(id)
  if ghost or not REG[id] then return end
  -- reaching for a part ends shaping (the shape closes itself)
  if shapingUid() then shapeStop(true) end
  -- A LOCKED part's click IS its research purchase — or the sentence saying
  -- what it wants first. The catalogue never holds a card you can't act on,
  -- and you never have to go somewhere else to open one.
  --
  -- And it is TWO clicks. One click used to spend $480–$1,250 of a $3,000
  -- account on the spot — a card you meant to hover was a purchase. The first
  -- click names the price and arms the card (the catalogue shows "confirm");
  -- the second, on the same card within RESEARCH_CONFIRM seconds, buys it.
  local rs = findScript("research")
  if rs and not rs.isUnlocked(id) then
    local why_not = rs.blockedBy and rs.blockedBy(id)
    if why_not then
      researchArmed = nil
      hint("LOCKED  ·  " .. rs.labelOf(id) .. "  —  " .. why_not, 4.0)
      ui("tool", 0.7)
      return
    end
    if not (researchArmed and researchArmed.id == id
            and time - researchArmed.t <= RESEARCH_CONFIRM) then
      researchArmed = { id = id, t = time }
      local co = company_ref()
      local price = rs.costOf(id)
      hint(string.format("RESEARCH %s for %s?  —  click it again to confirm",
        rs.labelOf(id), co and co.money(price) or ("$" .. price)), RESEARCH_CONFIRM)
      ui("tool", 0.7)
      return
    end
    researchArmed = nil
    local ok, why = rs.unlock(id)
    if not ok then
      hint("LOCKED  ·  " .. rs.labelOf(id) .. "  —  " .. why, 4.0)
      ui("tool", 0.7)
      return
    end
    hint("RESEARCH COMPLETE  ·  " .. why .. "  —  placing it now", 4.0)
    ui("save", 0.9)
  end
  local def = REG[id]
  -- a DRAWN part (Beam, Panel, Brace) is a tool, not a part in hand (§5.5)
  if def.proc and startDrawTool(id) then return end
  ghost = { id = id, def = def, yaw = 0, pitch = 0, roll = 0, node = nil, off = IDENT, B = IDENT }
  click_cool = 0.15
  ui("pickup", 0.9) -- in your hand: heard, not only seen (playtest 2026-10-26)
  holdStarted()
  hint(holdHint(), 8.0)
  spawn(stand_prefab(def.prefab), vec3(0, -80, 0), function(node)
    if ghost and ghost.id == id and not ghost.node and not ghost.carried then
      ghost.node = node
      if W.F and not W.F.identity and W.F.node and node.setParent then
        node:setParent(W.F.node, { keepWorld = false })
      end
    else
      destroy(node)
    end
  end)
end

-- LIFT parts into the hand (a drag-move, tool 4's old grab, hold({uid…})).
-- What comes: `opts.set` (default: uid's ring) plus everything that depends on
-- it (§5.4) — unless opts.only (Alt): then only the set, and its links to its
-- dependents are cut (they stay as loose islands). Every link between what is
-- lifted and what stays is cut now; placing makes the new ones. One history
-- step from lift to drop (the BEFORE is taken here); ESC puts it all back.
local function pickup(uid, opts)
  opts = opts or {}
  local root = parts[uid]
  if not root then return end
  local set = {}
  if opts.set then for u in pairs(opts.set) do if parts[u] then set[u] = true end end
  else for u in pairs(edit_set(uid)) do set[u] = true end end
  set[uid] = true
  if not opts.only then
    for u in pairs(deps_of(set)) do set[u] = true end
  end
  local t = nil
  if opts.paste then t = opts.paste
  else
    -- the parts on the far end of every link we cut join the snapshot too
    local G = graph()
    local around = {}
    for u in pairs(set) do
      around[u] = true
      if G then for _, n in ipairs(G:neighbours(u)) do around[n] = true end end
    end
    t = tx_begin("move " .. (root.def.label or root.id), around)
  end
  local G = graph()
  if G then
    for u in pairs(set) do
      for _, l in ipairs(G:incident(u)) do
        local o = (l.a == u) and l.b or l.a
        if not set[o] then
          G:remove(l.id)
          if l.prim and parts[l.b] then parts[l.b].parent = nil end
        end
      end
    end
  end
  struct_changed()
  local moved = {}
  -- The carried set moves RIGIDLY with its root (turns included): each part's
  -- pose is kept in the root's frame. The root's own turn is kept relative to
  -- the mount it came off, so it re-attaches the same way round elsewhere.
  local Rr = basisOf(root.yaw, root.pitch, root.roll)
  for u in pairs(set) do
    local p = parts[u]
    p.carried = true
    if W.H then W.H:remove(u) end
    moved[#moved + 1] = { uid = u, id = p.id, x = p.x, y = p.y, z = p.z,
                          yaw = p.yaw, pitch = p.pitch, roll = p.roll,
                          rel = basisApplyT(Rr, { x = p.x - root.x, y = p.y - root.y, z = p.z - root.z }),
                          relB = basisMul(basisT(Rr), basisOf(p.yaw, p.pitch, p.roll)) }
  end
  local A0 = opts.paste and IDENT or mountFrame(uid)
  ghost = { id = root.id, def = root.def, yaw = root.yaw, pitch = root.pitch or 0,
            roll = root.roll or 0, node = root.node, carried = moved, from_uid = uid,
            off = basisClean(basisMul(basisT(A0), Rr)), B = Rr, tx = t, exclude = set,
            paste = opts.paste and true or nil, only = opts.only }
  click_cool = 0.18
  ui("pickup", 0.8) -- lifted off the stack
  holdStarted()
  hint(holdHint(), 8.0)
end

-- The carried parts go back to being ordinary parts on the stand.
local function uncarry(g)
  for _, m in ipairs(g.carried or {}) do
    local p = parts[m.uid]
    if p then p.carried = nil; hash_put(m.uid, p) end
  end
end

local function place_ghost(x, y, z, parent, att, sym)
  local placed_uid = nil
  local an = nil
  if parent and parts[parent] and ghost.n then
    local h = parts[parent]
    an = basisApplyT(basisOf(h.yaw, h.pitch, h.roll), ghost.n)
  end
  local g = ghost
  if g.carried then
    local root = parts[g.from_uid]
    if root then
      local dx, dy, dz = x - root.x, y - root.y, z - root.z
      for _, m in ipairs(g.carried) do
        local p = parts[m.uid]
        if p then set_part_pos(p, p.x + dx, p.y + dy, p.z + dz) end
      end
      uncarry(g)
      set_parent(g.from_uid, parent, att)
      root.an = an
      placed_uid = g.from_uid
    end
    if g.tx then tx_commit(g.tx) end
  else
    -- The ghost node BECOMES the placed part. (Spawning a second node here
    -- was the great twin bug.)
    local u = next_uid
    next_uid = next_uid + 1
    local t = W.ptx or tx_begin("place " .. (g.def.label or g.id), {})
    tx_touch(t, u)
    add_part(u, { id = g.id, x = x, y = y, z = z, yaw = g.yaw, pitch = g.pitch, roll = g.roll,
                  parent = parent, att = att, sym = sym, an = an }, g.node)
    if not W.ptx then tx_commit(t) end
    placed_uid = u
  end
  ghost = nil
  click_cool = 0.15
  ui("place", 0.9) -- the part snaps home
  hint(HINT_IDLE, 0.0); hint_t = 0
  publish_center(); refresh_stats()
  return placed_uid
end

-- ── Symmetry placement ──────────────────────────────────────────────────────
-- (Copies are laid out by `symCopies` and placed by `placeCopies`, above.)

local function cancel_ghost()
  if not ghost then return end
  local g = ghost
  ghost = nil
  if g.carried then
    uncarry(g)
    if g.paste then
      -- a paste or a sub-assembly that never went down leaves nothing behind
      for _, m in ipairs(g.carried) do remove_part(m.uid) end
    elseif g.tx and not g.tx.merged then
      apply_snap(g.tx.before)   -- the poses and links from before the lift
    end
  else
    if g.node then destroy(g.node) end
  end
  hint(HINT_IDLE, 0.0); hint_t = 0
end

-- ── ROUND TWO at save: fairing shells, rover axles, rated motors ──────────
-- FAIRING ENVELOPE: what stands on a fairing base's top node (and everything
-- built onto that), measured in the base's frame — how tall the payload
-- reaches above the base and how far out from its axis — so the shell is
-- built to fit it. nil when nothing stands on it.
SHELL_T_PER_M2 = 0.012   -- composite shell, tonnes per square metre
function fairingEnvelope(uid)
  local b = parts[uid]
  if not (b and b.def.fairing) then return nil end
  local X, Y, Z = rot_basis(b.yaw, b.pitch, b.roll)
  local load = {}
  for u, q in pairs(parts) do
    if q.parent == uid and (q.att == "top" or q.att == "surface") then
      local up = (q.x - b.x) * Y.x + (q.y - b.y) * Y.y + (q.z - b.z) * Y.z
      if up > 0 then for v in pairs(beyond_of(u, uid)) do load[v] = true end end
    end
  end
  local top, rad, n = 0.0, 0.0, 0
  for u in pairs(load) do
    local q = parts[u]
    if q then
      n = n + 1
      local ex, ey, ez = part_extents(q)
      local dx, dy, dz = q.x - b.x, q.y - b.y, q.z - b.z
      local h = dx * Y.x + dy * Y.y + dz * Y.z
      local reach = math.abs(Y.x) * ex + math.abs(Y.y) * ey + math.abs(Y.z) * ez
      top = math.max(top, h + reach)
      local rx = dx * X.x + dy * X.y + dz * X.z
      local rz = dx * Z.x + dy * Z.y + dz * Z.z
      local wx = math.abs(X.x) * ex + math.abs(X.y) * ey + math.abs(X.z) * ez
      local wz = math.abs(Z.x) * ex + math.abs(Z.y) * ey + math.abs(Z.z) * ez
      rad = math.max(rad, math.sqrt((math.abs(rx) + wx) ^ 2 + (math.abs(rz) + wz) ^ 2))
    end
  end
  if n == 0 then return nil end
  local base_top = b.def.h * 0.5
  local R = math.max(b.def.fairing, rad + 0.08)
  local hc = math.max(base_top + 0.3, top + 0.1)      -- the cylinder's top, above the base centre
  local hn = R * 1.1                                    -- the ogive nose
  local area = 2 * math.pi * R * (hc - base_top) + math.pi * R * math.sqrt(R * R + hn * hn)
  return { r = R, hc = hc, hn = hn, y0 = base_top, mass = area * SHELL_T_PER_M2, load = load, n = n }
end

-- ── SHAPED FAIRINGS ──────────────────────────────────────────────────────────
-- A fairing base can carry a SHAPE the player draws (B with the base selected,
-- or its SHAPE button): rings stacked up its axis, each a radius and a height
-- above the base ring, closed over the top with a nose. Without one it grows
-- the fitted shell above (what every fairing did before, and what an old craft
-- still gets). Kept per uid, apart from `parts`, so a scrap + CTRL+Z brings a
-- base back with its shape:
--
--   fshapes[uid] = { secs = { { r =, h = }, … }, closed = bool, split = 2 | 3 }
fshapes = {}

function copy_wcfg(w)
  local c = {}
  for k, v in pairs(w or {}) do c[k] = v end
  return c
end

function copy_shape(sh)
  if not sh then return nil end
  local out = { secs = {}, closed = sh.closed, split = sh.split or 2 }
  for i, sc in ipairs(sh.secs or {}) do out.secs[i] = { r = sc.r, h = sc.h } end
  return out
end

-- Everything that stands on the base's top node (and everything built onto
-- that), with each part's reach in the base frame: its height range above the
-- base centre and how far it reaches out from the axis.
function fairing_payload(uid)
  local b = parts[uid]
  local X, Y, Z = rot_basis(b.yaw, b.pitch, b.roll)
  local load = {}
  for u, q in pairs(parts) do
    if q.parent == uid and (q.att == "top" or q.att == "surface") then
      local up = (q.x - b.x) * Y.x + (q.y - b.y) * Y.y + (q.z - b.z) * Y.z
      if up > 0 then for v in pairs(beyond_of(u, uid)) do load[v] = true end end
    end
  end
  local out = {}
  for u in pairs(load) do
    local q = parts[u]
    if q then
      local ex, ey, ez = part_extents(q)
      local dx, dy, dz = q.x - b.x, q.y - b.y, q.z - b.z
      local h = dx * Y.x + dy * Y.y + dz * Y.z
      local reach = math.abs(Y.x) * ex + math.abs(Y.y) * ey + math.abs(Y.z) * ez
      local rx = dx * X.x + dy * X.y + dz * X.z
      local rz = dx * Z.x + dy * Z.y + dz * Z.z
      local wx = math.abs(X.x) * ex + math.abs(X.y) * ey + math.abs(X.z) * ez
      local wz = math.abs(Z.x) * ex + math.abs(Z.y) * ey + math.abs(Z.z) * ez
      out[u] = { lo = h - reach, hi = h + reach,
                 rad = math.sqrt((math.abs(rx) + wx) ^ 2 + (math.abs(rz) + wz) ^ 2) }
    end
  end
  return out
end

-- THE SHELL A FAIRING BASE WILL FLY WITH: its profile (base frame, { r, y }
-- bottom to top), skin area and mass, the payload it encloses (`load`, uid →
-- true) and what sticks out of it (`out`), how many pieces it splits into, and
-- whether it was drawn (`shaped`) or fitted. nil = no shell at all (a fitted
-- base with nothing on it, or a drawn shape with no rings yet).
function fairingFit(uid)
  local b = parts[uid]
  if not (b and b.def.fairing) then return nil end
  local E = elib()
  local sh = fshapes[uid]
  local y0 = b.def.h * 0.5
  local prof, shaped
  if sh and #sh.secs > 0 and E then
    prof = E.fairingSectionsProfile(b.def.fairing, y0, sh.secs, sh.closed)
    shaped = true
  else
    local env = fairingEnvelope(uid)
    if not env then return nil end
    if E then prof = E.fairingAutoProfile(env.r, env.y0, env.hc, env.hn) end
    if not prof then
      return { env = env, load = env.load, out = {}, mass = env.mass, split = 2, shaped = false, y0 = y0 }
    end
  end
  local area, rmax, height = E.fairingStats(prof)
  local load, out, nin, nout = {}, {}, 0, 0
  local closed = (not shaped) or (sh and sh.closed)
  for u, pl in pairs(fairing_payload(uid)) do
    if closed and E.fairingHolds(prof, pl.lo, pl.hi, pl.rad) then load[u] = true; nin = nin + 1
    else out[u] = true; nout = nout + 1 end
  end
  return { prof = prof, area = area, rmax = rmax, height = height, mass = area * SHELL_T_PER_M2,
           load = load, out = out, nin = nin, nout = nout, split = (sh and sh.split) or 2,
           shaped = shaped == true, closed = closed, y0 = y0 }
end

-- The shape's rings as a flat list for the blueprint (r1, h1, r2, h2 …) and back.
function secs_flat(sh)
  local out = {}
  for _, sc in ipairs(sh and sh.secs or {}) do out[#out + 1] = sc.r; out[#out + 1] = sc.h end
  return out
end
function secs_unflat(flat)
  local out = {}
  if type(flat) ~= "table" then return out end
  for i = 1, #flat - 1, 2 do out[#out + 1] = { r = flat[i], h = flat[i + 1] } end
  return out
end

-- The craft's wheels, by the way their axles point (vessel frame). A rover
-- needs them all on ONE axle line: the engine's wheel joint turns a wheel
-- about the chassis's Z (floptle/0420), so at rollout the build is turned
-- about the vertical to put that line on Z if it was built along X.
function wheelAxles()
  local nx, nz, other, n = 0, 0, 0, 0
  for _, p in pairs(parts) do
    if p.def.wheel then
      n = n + 1
      local X = rot_basis(p.yaw, p.pitch, p.roll)
      if math.abs(X.x) > 0.9 then nx = nx + 1
      elseif math.abs(X.z) > 0.9 then nz = nz + 1
      else other = other + 1 end
    end
  end
  return n, nx, nz, other
end

-- Called by save_blueprint on the finished records (vessel frame, y = 0 at
-- the bottom): shells, axles, and motors rated for the home world like
-- engines are (torque × g_home / G_REF, so a rover climbs the same slope on
-- every save).
function finishBlueprint(bp)
  local by = {}
  for _, d in ipairs(bp.parts) do by[d.uid] = d end
  -- fairings: the fitted or drawn shell, its mass, and who rides inside
  local E = elib()
  for _, d in ipairs(bp.parts) do
    if (d.fairing or 0) > 0 then
      local fit = fairingFit(d.uid)
      local sh = fshapes[d.uid]
      if sh and #sh.secs > 0 then
        -- the drawn rings ride along so the builder can open the shape again
        d.fsec = secs_flat(sh)
        d.fclosed = sh.closed and 1 or 0
      end
      if fit and fit.prof and fit.closed then
        local p = fit.prof
        -- fr / fy0 / fhc / fhn describe the fitted shell, and stand in for a
        -- drawn one wherever the flight only knows those (a widest-radius
        -- cylinder and nose), so an older flight still flies a sensible shell.
        local top = p[#p][2]
        local hn = math.max(0.15, fit.rmax * 1.1)
        if fit.shaped then
          d.fr, d.fy0, d.fhc, d.fhn = fit.rmax, fit.y0, math.max(fit.y0 + 0.05, top - hn), hn
          d.fprof = E.fairingFlat(p)
        else
          d.fr, d.fy0, d.fhc, d.fhn = fit.env and fit.env.r or fit.rmax, fit.y0,
            fit.env and fit.env.hc or (top - hn), fit.env and fit.env.hn or hn
        end
        d.fsplit = fit.split or 2
        d.farea = math.pi * fit.rmax * fit.rmax   -- frontal area the shell shows the air
        d.mass = (d.mass or 0) + fit.mass
        d.shellm = fit.mass
        for u in pairs(fit.load) do if by[u] then by[u].faired = d.uid end end
      elseif fit and fit.env then
        local env = fit.env
        d.fr, d.fhc, d.fhn, d.fy0 = env.r, env.hc, env.hn, env.y0
        d.mass = (d.mass or 0) + env.mass
        d.shellm = env.mass
        for u in pairs(env.load) do if by[u] then by[u].faired = d.uid end end
      end
    end
  end
  -- motors rated for the home world
  local k = rating().thrust
  for _, d in ipairs(bp.parts) do
    if type(d.mods) == "table" then
      for _, m in ipairs(d.mods) do
        if m.type == "drive" or m.type == "hinge" or m.type == "rotor" then m.torque = (m.torque or 0) * k
        elseif m.type == "piston" then m.force = (m.force or 0) * k end
      end
    end
  end
  -- axles on Z: a build whose wheels all point along X turns 90° about Y
  local n, nx, nz = wheelAxles()
  if n > 0 and nx > nz then
    for _, d in ipairs(bp.parts) do
      d.x, d.z = -d.z, d.x
      d.yaw = wrap_angle((d.yaw or 0) - math.pi / 2)
    end
    bp.turned = -math.pi / 2
  end
end

-- ── Blueprint (self-contained; save.* slot store) ───────────────────────────
local function make_blueprint()
  center_now()
  local bp = { parts = {} }
  local ref_y = math.huge
  for _, p in pairs(parts) do ref_y = math.min(ref_y, p.y - p.def.h * 0.5) end
  if ref_y == math.huge then ref_y = 0 end
  -- Firing order: each decoupler carries its stage-event index.
  -- (every event of a stage carries its number: the flight fires them on one SPACE)
  local items = sync_stage_order()
  local stage_of = STAGEM.index(stage_order, items)
  local i = 0
  -- (a part's modules depend on its definition alone: encoded once a
  -- definition per pass, not once a part — 3,000 parts are a handful of kinds)
  local mods_of = {}
  for uid, p in pairs(parts) do
    i = i + 1
    -- As this save builds it (thrust and ve for the home world, see BALANCE).
    local d = liveDef(p.def)
    local mo = mods_of[d]
    if mo == nil then
      mo = (elib() and elib().encodeMods(part_mods(d))) or false
      mods_of[d] = mo
    end
    bp.parts[i] = {
      uid = uid, id = p.id, prefab = d.prefab, label = d.label,
      x = p.x - centerX, y = p.y - ref_y, z = p.z - centerZ,
      yaw = p.yaw, pitch = p.pitch or 0, roll = p.roll or 0,
      parent = p.parent or 0, att = p.att or "", sym = p.sym or 0,
      stage = stage_of[uid] or 0,
      h = d.h, mass = d.mass + (p.joints and #p.joints or 0) * 0.001, cost = d.cost, kind = d.kind,
      -- Half-widths ride along too: the flight side needs a part's real
      -- footprint for hull contact, not just its stack height.
      rx = d.rx or 0, rz = d.rz or 0,
      -- Structural ratings for the flight's stress model (see REG).
      strength = d.strength or 0, maxq = d.maxq or 0,
      -- burn = units/s at full throttle; fuel_t = tonnes per unit, so the
      -- flight gives the propellant its mass (absent = an older, massless build).
      thrust = d.thrust or 0, burn = d.burn or 0, fuel = d.fuel or 0,
      ve = d.ve or 0, fuel_t = d.fuel_t or 0,
      -- the nozzle's sea-level share (rating version 3 on): vessel_controller
      -- scales thrust by the air; absent = the same in air and vacuum
      asl = d.asl,
      decouple = d.decouple and 1 or 0, legs = d.legs and 1 or 0,
      radial = d.radial and 1 or 0, chute = d.chute and 1 or 0,
      comms = d.comms and 1 or 0, aero = d.aero and 1 or 0,
      -- AERODYNAMICS (scripts/aero.lua): the part's aero spec, verbatim — the
      -- flight reads wings, control surfaces, jets, intakes, gear and drag
      -- shapes from it (nil for a part without one).
      af = d.af,
      -- Electrical capabilities: these were being DROPPED on save, so a battery
      -- (power) or solar panel (solar) never did anything in flight. Carry them
      -- and their ratings (EC capacity / charge rate) through to the vessel.
      power = d.power and 1 or 0, solar = d.solar and 1 or 0,
      ec = d.ec or 0, gen = d.gen or 0,
      -- Docking ports and RCS blocks are peripherals, not staging events: the
      -- flight side reads these to find every mating face and thruster aboard.
      dock = d.dock and 1 or 0,
      rcs = d.rcs and 1 or 0, rcs_thrust = d.rcs_thrust or 0,
      -- Hold capacity in kg (0 = not a cargo bay). The vessel sums these into
      -- one pooled hold when it spawns.
      cargo = d.cargo or 0,
      -- A stowage locker's own capacity in kg (0 = none): its own container in
      -- flight (vessel_controller lockers).
      store = d.store or 0,
      -- ROUND TWO: a rover body's FRONT, a powered wheel's size, a fairing's
      -- base radius (and the shell it grew, see fairingShell), a robotic
      -- joint's kind, a claw, and a mirror pair's plane.
      front = d.front and 1 or 0, wheel = d.wheel or "", fairing = d.fairing or 0,
      -- an OPEN SEAT commands like a pod but keeps its rider in view
      seat = d.seat and 1 or 0,
      -- a wheel's settings, defaults left out (WHEEL SETTINGS)
      wcfg = (d.wheel and wcfgs[uid] and next(wcfgs[uid])) and copy_wcfg(wcfgs[uid]) or nil,
      robo = d.robo or "", claw = d.claw and 1 or 0, mir = p.mir or "",
      -- the face it is mounted on, in its host's frame (what SPACE resets to)
      anx = p.an and p.an.x or nil, any = p.an and p.an.y or nil, anz = p.an and p.an.z or nil,
      -- ELECTRONICS: every module the part carries (declared + implied by its
      -- flags), so the flight never has to know a part by name to power it,
      -- link it or offer its actions.
      -- (as a string: save.set holds four tables deep at most — electronics
      -- encodeMods / decodeMods)
      mods = mo or nil,
      -- procedural parameters (WP3's members and panels), when it has them
      size = p.size and tcopy(p.size) or nil,
      -- a drawn part (WP3): what it is and its joint plates (encoded strings;
      -- each adds builder_attach.JOINT_MASS to the part's mass below)
      proc = d.proc, prof = d.proc and (p.size and p.size.prof or d.prof) or nil,
      joints = (p.joints and #p.joints > 0) and tcopy(p.joints) or nil,
    }
  end
  -- BLUEPRINT v2 (§5.8): the links, the root, the outliner groups and WP5's
  -- controls ride along; every v1 field above stays, so the flight reads it
  -- exactly as before.
  bp.v = 2
  bp.name = W.craft
  bp.root = craft_root()
  local G, L = graph(), lib("builder_graph")
  if G and L then
    bp.links = {}
    for _, l in ipairs(G:all()) do bp.links[#bp.links + 1] = L.packLink(l) end
  end
  if W.outliner and #W.outliner > 0 then bp.outliner = tcopy(W.outliner) end
  if W.controls then bp.controls = tcopy(W.controls) end
  -- THE CONTROL MODE (ctrlMode): on the blueprint and on every command part,
  -- whose records a fleet save, a staging and a docking carry
  if W.ctrl then
    bp.ctrl = W.ctrl
    local L = ctrlLib()
    for _, d in ipairs(bp.parts) do
      if L and L.isCommand(d) then d.ctrl = W.ctrl end
    end
  end
  -- ACTION GROUPS: only once the player has edited them. Until then the flight
  -- builds the standard ones (legs on Gear, panels and antennas on Deploy…) from
  -- whatever is aboard, so a craft that never opened the editor still has them.
  if groups_state.edited and groups_state.groups then
    local alive = {}
    for uid in pairs(parts) do alive[uid] = true end
    local E = elib()
    if E then
      E.pruneGroups(groups_state.groups, alive)
      bp.groups = E.packGroups(groups_state.groups)
    end
  end
  -- The catalogue this was built from (see BALANCE): for the record only. The
  -- pad no longer re-rates anything — the blueprint flies exactly as quoted.
  local k = rating()
  bp.catalogue = { home = k.name, thrust = k.thrust, ve = k.ve, v = k.v }
  finishBlueprint(bp)
  return bp, i
end

local function save_blueprint(noflush)
  -- An autosave still in flight (craftSave quiet, over four frames) lands
  -- first, so the writes happen in the order they were asked for.
  -- (its library file, encoded a few milliseconds a frame, is finished now)
  if W.save_job and saveJobTick then
    W.lib_now = true
    for _ = 1, 6 do if not W.save_job then break end saveJobTick() end
    W.lib_now = false
  end
  local bp, i = make_blueprint()
  save.set("shipyard.blueprint", bp)
  W.launch_bp = nil
  if not noflush then save.flush() end
  ui("save", 0.9)
  hint("blueprint saved  ·  " .. i .. " parts", 2.5)
  return bp
end

-- The parachute canister was redrawn to sit on the pod's collar: 0.61 → 0.34 m
-- tall, 0.28 → 0.22 m half-wide (tools/gen_part_meshes.py part_chute). A build
-- saved before keeps the old centre, which would leave the new canister
-- floating above its mount: sit it back down — its foot where it was, anything
-- hung on its flanks moving with it, anything under it staying put.
function refit_chutes(list)
  local cur = REG.chute
  local by, kids = {}, {}
  for _, d in pairs(list) do
    by[d.uid] = d
    local pu = d.parent or 0
    if pu ~= 0 then kids[pu] = kids[pu] or {}; kids[pu][#kids[pu] + 1] = d end
  end
  local function move(d, dx, dy, dz, root)
    d.x, d.y, d.z = d.x + dx, d.y + dy, d.z + dz
    for _, k in ipairs(kids[d.uid] or {}) do
      if not (root and k.att == "bottom") then move(k, dx, dy, dz, false) end
    end
  end
  for _, d in pairs(list) do
    if d.id == "chute" and d.h and math.abs(d.h - cur.h) > 1e-3 then
      local par = by[d.parent or 0]
      if d.att == "radial" and par then
        -- in toward the flank it hangs on
        local ox, oz = d.x - par.x, d.z - par.z
        local l = math.sqrt(ox * ox + oz * oz)
        local pull = (d.rx or 0.28) - cur.rx
        if l > 1e-3 then move(d, -ox / l * pull, 0, -oz / l * pull, true) end
      else
        local _, Y = rot_basis(d.yaw, d.pitch, d.roll)
        local dh = (d.h - cur.h) * 0.5
        move(d, -Y.x * dh, -Y.y * dh, -Y.z * dh, true)
      end
      d.h, d.rx, d.rz = cur.h, cur.rx, cur.rz
    end
  end
end

-- Wipe the stand: every part, link, selection and the history.
local function clear_stand()
  for _, p in pairs(parts) do if p.node then destroy(p.node) end end
  parts = {}
  partCount = 0
  if W.G then W.G:clear() end
  if W.H then W.H:clear() end
  W.queue, W.qhead = {}, 1
  W.sel, W.sel_order, selected_uid = {}, {}, nil
  W.root, W.outliner, W.controls, W.ctrl = nil, {}, nil, nil
  W.cache = {}
  if W.hist then W.hist:clear() end
  struct_changed()
  publish_center()
end

-- Put a blueprint (v1 or v2) on the stand. v2 brings its links; a v1 one has
-- them made from its parent/att fields (§5.8). Parts land time-sliced.
local function load_blueprint(bp)
  bp = bp or save.get("shipyard.blueprint")
  if not bp or not bp.parts then return end
  refit_chutes(bp.parts)
  -- A rover rolled out turned 90° (finishBlueprint: wheel axles on Z) comes
  -- back onto the stand the way it was built.
  if bp.turned then
    for _, d in pairs(bp.parts) do
      d.x, d.z = d.z, -d.x
      d.yaw = wrap_angle((d.yaw or 0) + math.pi / 2)
    end
    bp.turned = nil
  end
  local E = elib()
  if bp.groups and E then
    groups_state.groups, groups_state.edited = E.unpackGroups(bp.groups), true
  else
    groups_state.groups, groups_state.edited = nil, false
  end
  if ghost and ghost.node and not ghost.carried then destroy(ghost.node) end
  ghost = nil
  clear_stand()
  stage_order, saved_stage = {}, {}
  W.stage_sync_v = nil
  fshapes = {}
  wcfgs = {}
  if shapeStop then shapeStop(false) end
  local have = {}
  for _, d in pairs(bp.parts) do
    if REG[d.id] then have[d.uid] = true end
  end
  for _, d in pairs(bp.parts) do
    if have[d.uid] then
      if (d.stage or 0) > 0 then saved_stage[d.uid] = d.stage end
      if type(d.wcfg) == "table" and next(d.wcfg) then wcfgs[d.uid] = copy_wcfg(d.wcfg) end
      -- a drawn fairing comes back drawn (a craft from before shaping has no
      -- `fsec` and keeps its fitted shell)
      if (d.fairing or 0) > 0 and type(d.fsec) == "table" and #d.fsec >= 2 then
        fshapes[d.uid] = { secs = secs_unflat(d.fsec), closed = (d.fclosed or 1) ~= 0,
                           split = (d.fsplit == 3) and 3 or 2 }
      end
      local an = (d.anx and d.any and d.anz) and { x = d.anx, y = d.any, z = d.anz } or nil
      local p = add_part(d.uid, { id = d.id, x = d.x, y = d.y + params.floor_y, z = d.z,
        yaw = d.yaw, pitch = d.pitch, roll = d.roll,
        sym = (d.sym or 0) ~= 0 and d.sym or nil, mir = (d.mir or "") ~= "" and d.mir or nil,
        an = an, size = type(d.size) == "table" and tcopy(d.size) or nil,
        joints = type(d.joints) == "table" and tcopy(d.joints) or nil })
      if p then
        local par = d.parent or 0
        p.parent = (par ~= 0 and have[par]) and par or nil
        p.att = (d.att ~= "" and d.att) or nil
      end
    end
  end
  -- the links: v2 carries them; a v1 blueprint makes them from parent/att
  local G, L = graph(), lib("builder_graph")
  if G and L then
    local list
    if type(bp.links) == "table" and #bp.links > 0 then
      list = {}
      for i, t in ipairs(bp.links) do list[i] = L.unpackLink(t) end
    else
      list = L.linksFromV1(bp.parts)
    end
    for _, l in ipairs(list) do
      if parts[l.a] and parts[l.b] then G:add(l) end
    end
  end
  if bp.root and parts[bp.root] then W.root = bp.root end
  if type(bp.outliner) == "table" then W.outliner = tcopy(bp.outliner) end
  if type(bp.controls) == "table" then W.controls = tcopy(bp.controls) end
  if type(bp.name) == "string" and bp.name ~= "" then W.craft = bp.name end
  -- the control mode: the blueprint's, or (a fleet craft's records) its
  -- command parts'
  do
    local m = bp.ctrl
    if m == nil then
      for _, d in pairs(bp.parts) do
        if type(d.ctrl) == "string" and (d.kind == "crewed" or d.kind == "probe") then m = d.ctrl break end
      end
    end
    W.ctrl = (m == "rover" or m == "aircraft" or m == "rocket") and m or nil
  end
  struct_changed()
  publish_center(); refresh_stats()
end

-- ── ACTION GROUPS (tool 5) ──────────────────────────────────────────────────
-- Pick a group on the panel (Gear, Deploy, Lights, Brakes, RCS, SAS, Abort or
-- one of 1–0), click a part on the craft, and tick the actions it should run
-- when that group's key is pressed. A symmetry ring is edited as one, like
-- everything else in here. The panel itself is scripts/groups_panel.lua; it
-- reads and edits through these globals, so the rules live in one place.

-- The groups as they stand: the edited set, or the standard one built from
-- what's aboard. Bindings to scrapped parts are dropped.
function groupsNow()
  local E = elib()
  if not E then return {} end
  local recs = craft_records()
  if not groups_state.edited or not groups_state.groups then
    return E.defaultGroups(recs), recs
  end
  -- Shown without bindings to parts that aren't on the stand — but not
  -- forgotten: CTRL+Z brings a scrapped part back with its uid, and its
  -- bindings come back with it. (The save drops them for good.)
  local alive = {}
  for uid in pairs(parts) do alive[uid] = true end
  return E.pruneGroups(E.deepCopy(groups_state.groups), alive), recs
end

function groupsTool() return tool == "groups" end
-- The tool in use, by its TOOLS name (the toolbar lights its key from this:
-- `tool` itself is a local here, so the panels' B.tool read nil and the
-- toolbar only ever knew the key it had been clicked with, not 1–5).
function toolName() return tool end
-- Switch tools from outside (the toolbar, a probe). Same names as TOOLS;
-- the old "move" is OFFSET and the old "grab" is SELECT (drag moves now).
function setTool(name)
  if name == "move" then name = "offset" elseif name == "grab" then name = "select" end
  for _, t in ipairs(TOOLS) do
    if t == name then
      tool = name
      refresh_stats()
      if W.hist then W.hist:seal() end
      return true
    end
  end
  return false
end
-- The uids on the stand, sorted (probes and the harness).
function partUids()
  local out = {}
  for uid in pairs(parts) do out[#out + 1] = uid end
  table.sort(out)
  return out
end
function partIdOf(uid) return parts[uid] and parts[uid].id or nil end
function groupsSelected() return groups_state.gid end
function groupsSelect(gid) groups_state.gid = gid end
function groupsEdited() return groups_state.edited end
function selectedPart() return selected_uid end
function selectPart(uid) if parts[uid] then sel_only(uid) else sel_only(nil) end end

-- First edit: the standard set becomes the player's own, then changes.
function groups_own()
  local E = elib()
  if not E then return nil end
  if not groups_state.edited or not groups_state.groups then
    groups_state.groups = E.defaultGroups(craft_records())
    groups_state.edited = true
  end
  craftVersion = craftVersion + 1 -- every caller is about to edit them
  return groups_state.groups
end

-- Tick / untick one action of one part in a group — and of every member of
-- the part's symmetry ring. Returns the new bound state.
function groupsToggle(gid, uid, act)
  local E = elib()
  local g = groups_own()
  if not (E and g and parts[uid]) then return false end
  local on = not E.isBound(g, gid, uid, act)
  local members = { uid }
  local p = parts[uid]
  if p.sym then members = group_members(p.sym) end
  for _, u in ipairs(members) do
    if on then E.bind(g, gid, u, act) else E.unbind(g, gid, u, act) end
  end
  ui("tool", 0.6)
  return on
end

-- Give every actuator that has no key yet keys of its own on the free custom
-- groups (electronics.actuatorGroups: a piston on one, a hinge on two held
-- keys, a rotor, drill or claw on one). The groups panel's one-click setup.
function groupsAutoActuators()
  local E = elib()
  local g = groups_own()
  if not (E and g) then return 0 end
  local recs = craft_records()
  local list = {}
  for uid, r in pairs(recs) do
    if E.actuatorOf(r) and #E.bindsOfPart(g, uid) == 0 then list[#list + 1] = r end
  end
  table.sort(list, function(a, b) return a.uid < b.uid end)
  local n = E.actuatorGroups(g, list)
  ui("tool", 0.7)
  hint(n > 0 and string.format("actuators on keys — %d custom group%s set up", n, n == 1 and "" or "s")
    or "no free custom group left (1–0) — clear one first", 3.0)
  return n
end

-- Empty one group, or put every group back to the standard set.
function groupsClear(gid)
  local g = groups_own()
  if g and g[gid] then g[gid].binds = {} end
  ui("scrap", 0.6)
end

function groupsReset()
  groups_state.groups, groups_state.edited = nil, false
  craftVersion = craftVersion + 1
  ui("tool", 0.6)
  hint("action groups back to the standard set", 2.5)
end

-- Rename a custom group (the label the flight HUD shows on its key).
function groupsRename(gid, name)
  local g = groups_own()
  if not g then return end
  local E = elib()
  if not g[gid] then g[gid] = { name = name, binds = {} } end
  g[gid].name = (name and name ~= "") and name or ((E and E.groupInfo(gid) or {}).label or gid)
end

-- The builder's half of the panel: outline every part the open group touches
-- (the selection in the ring colour), and own the mouse while it is over the
-- panel so a click on a checkbox never deselects the part it's editing.
local groups_panel_node = nil
function groupsPanelTick(clicked)
  local groups_on = tool == "groups"
  if not groups_on and not wheelSelected() then return false end
  local E = groups_on and elib()
  if E then
    local g = groupsNow()
    local gg = g and g[groups_state.gid]
    if gg then
      local seen = {}
      for _, b in ipairs(gg.binds) do
        local p = parts[b.uid]
        if p and not seen[b.uid] then
          seen[b.uid] = true
          outline(p, 1.0, 0.72, 0.32, 0.85)
        end
      end
    end
  end
  if not groups_panel_node or not groups_panel_node.valid then groups_panel_node = find("GroupsPanel") end
  if not (groups_panel_node and groups_panel_node.uiRect) then return false end
  local px, py, pw, ph = groups_panel_node:uiRect()
  if not (px and pw and pw > 1) then return false end
  local mx, my = input.mouse()
  return mx >= px and mx <= px + pw and my >= py and my <= py + ph
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────
function start(node)
  stats_node = find("BuildStats")
  hint_node = find("BuildHint")
  -- the frame first: parts spawn into it
  W.budget = 60
  frameTick()
  local cur = save.get("shipyard.current")
  if type(cur) == "string" and cur ~= "" then W.craft = cur end
  -- parts spawn INTO the frame: if builder_space isn't reachable yet (script
  -- start order), the load waits for the first frame that has it
  if W.F then load_blueprint() else W.load_wait = true end
  refreshStatsNow()
end


-- Engineering markers (in-game draw.* layer): the CENTER OF MASS (amber
-- sphere + ring) and CENTER OF THRUST (blue sphere + thrust-axis line).
-- Watching them line up IS the balance tool — an off-axis CoT will pirouette
-- exactly this way at launch, because flight thrusts at these same offsets.
-- The dry CoM and CoT, summed once per craftVersion (not every frame).
local function eng_points()
  local c = W.cache
  if c.eng_v == craftVersion then return c.eng end
  local m, cx, cy, cz = 0.0, 0.0, 0.0, 0.0
  local th, tx, ty, tz = 0.0, 0.0, 0.0, 0.0
  for _, p in pairs(parts) do
    local pm = p.def.mass
    m = m + pm
    cx, cy, cz = cx + p.x * pm, cy + p.y * pm, cz + p.z * pm
    local t = p.def.thrust or 0
    if t > 0 then
      th = th + t
      tx, ty, tz = tx + p.x * t, ty + p.y * t, tz + p.z * t
    end
  end
  c.eng = { m = m, cx = cx, cy = cy, cz = cz, th = th, tx = tx, ty = ty, tz = tz }
  c.eng_v = craftVersion
  return c.eng
end
-- The parts of one kind (wheels, fairings), listed once per structVersion.
local function parts_with(flag)
  local c = W.cache
  c.with = (c.with_v == W.sv) and c.with or {}
  c.with_v = W.sv
  local l = c.with[flag]
  if l then return l end
  l = {}
  for u, p in pairs(parts) do if p.def[flag] then l[#l + 1] = u end end
  table.sort(l)
  c.with[flag] = l
  return l
end

function draw_engineering()
  if partCount == 0 then return end
  local e = eng_points()
  local m, cx, cy, cz = e.m, e.cx, e.cy, e.cz
  local th, tx, ty, tz = e.th, e.tx, e.ty, e.tz
  if m <= 0 then return end
  cx, cy, cz = cx / m, cy / m, cz / m
  draw.sphere(cx, cy, cz, 0.16, 1.0, 0.8, 0.2, 1.0)
  draw.ring(cx, cy, cz, 0, 1, 0, 0.34, 1.0, 0.8, 0.2, 0.7)
  if th > 0 then
    tx, ty, tz = tx / th, ty / th, tz / th
    draw.sphere(tx, ty, tz, 0.13, 0.3, 0.7, 1.0, 1.0)
    -- The thrust axis (builder ships point +Y): CoT up through the CoM
    -- region — if this line misses the amber ball, the ship will torque.
    draw.line(tx, ty, tz, tx, ty + 2.2, tz, 0.3, 0.7, 1.0, 0.8)
  end
end


-- ── WHEEL SETTINGS (SCRATCH wheel_spec.md; the flight reads them) ──────────
-- Every wheel can be told how to steer and drive and how its suspension and
-- tyre behave. Kept per uid like fairing shapes, written to the wheel's craft
-- record as `wcfg` with the defaults left out (so an old craft, which has
-- none, drives on the defaults — and `wheel` stays the size string):
--
--   steer     "auto" (steers if it is ahead of the centre of mass) | "on" |
--             "off" | "invert"            steerMax  degrees (25)
--   drive     "auto" (pushes the craft forward; the sign comes from its
--             mount) | "on" | "off" | "invert"
--   motor, brake   0..1 (1)              spring, damper  0.25..4 (1)
--   travel    suspension travel, m (the part's)   friction 0.5..2 (1)
--   skid      skid-steer torque on top of steering (false)
--
-- In the builder each wheel shows the way it will roll when you press W (an
-- arrow, green = drives, orange = inverted, grey = free) and, if it steers,
-- the arc it can swing through — so a wheel mounted the wrong way round is
-- visible before launch. Select a wheel and the Wheel settings panel (scripts/
-- groups_panel.lua) edits it, its symmetry partners, or every wheel.
WCFG_DEFAULTS = { steer = "auto", steerMax = 25, drive = "auto", motor = 1, brake = 1,
                  spring = 1, damper = 1, friction = 1, skid = false }
WCFG_RANGES = { steerMax = { 0, 45 }, motor = { 0, 1 }, brake = { 0, 1 }, spring = { 0.25, 4 },
                damper = { 0.25, 4 }, travel = { 0.03, 0.5 }, friction = { 0.5, 2 } }
local WCFG_MODES = { auto = true, on = true, off = true, invert = true }
wcfgs = {}

-- A wheel's settings, every field filled in (travel: the part's own).
function wheelCfg(uid)
  local p = parts[uid]
  if not (p and p.def.wheel) then return nil end
  local w = wcfgs[uid] or {}
  local out = {}
  for k, v in pairs(WCFG_DEFAULTS) do out[k] = v end
  for k, v in pairs(w) do out[k] = v end
  if out.travel == nil then out.travel = p.def.travel or 0.15 end
  return out
end

-- Set one field (clamped, a mode checked); a value equal to its default is
-- dropped, so the record only ever carries what was changed.
function wcfg_put(uid, key, v)
  local p = parts[uid]
  if not (p and p.def.wheel) then return end
  local w = wcfgs[uid] or {}
  if key == "steer" or key == "drive" then
    if not WCFG_MODES[v] then return end
  elseif key == "skid" then
    v = v == true
  else
    local r = WCFG_RANGES[key]
    v = tonumber(v)
    if not (r and v) then return end
    v = math.max(r[1], math.min(r[2], v))
    v = math.floor(v * 100 + 0.5) / 100
  end
  local def = WCFG_DEFAULTS[key]
  if key == "travel" then def = p.def.travel end
  if v == def then w[key] = nil else w[key] = v end
  wcfgs[uid] = next(w) and w or nil
  craftVersion = craftVersion + 1
end

function wcfg_undo()
  local snap = {}
  for u, w in pairs(wcfgs) do
    local c = {}
    for k, v in pairs(w) do c[k] = v end
    snap[u] = c
  end
  push_undo({ type = "wcfg", prev = snap })
end

function wheelSet(uid, key, v, quiet)
  if not wheelCfg(uid) then return false end
  -- one history step per field drag (a slider fires every frame it moves)
  local snap = {}
  for u, w in pairs(wcfgs) do snap[u] = copy_wcfg(w) end
  push_undo({ type = "wcfg", prev = snap, merge = "wcfg:" .. tostring(uid) .. ":" .. tostring(key) })
  wcfg_put(uid, key, v)
  if not quiet then ui("tool", 0.5) end
  return true
end

-- Flip which way it pushes: auto/on ↔ invert.
function wheelFlip(uid)
  local c = wheelCfg(uid)
  if not c then return end
  wheelSet(uid, "drive", c.drive == "invert" and "auto" or "invert")
  hint(c.drive == "invert" and "wheel drives the normal way again" or "wheel flipped — it pushes the other way now", 2.5)
end

-- Copy this wheel's settings onto its symmetry partners ("sym") or onto every
-- wheel on the craft ("all").
function wheelApply(uid, scope)
  local p = parts[uid]
  if not (p and p.def.wheel) then return 0 end
  wcfg_undo()
  local src = wcfgs[uid]
  local n = 0
  for u, q in pairs(parts) do
    if u ~= uid and q.def.wheel and (scope == "all" or (p.sym and q.sym == p.sym)) then
      local c = nil
      if src then c = {} for k, v in pairs(src) do c[k] = v end end
      -- a travel set on a different-sized wheel goes back to that wheel's own
      if c and q.def.travel ~= p.def.travel then c.travel = nil end
      wcfgs[u] = c
      n = n + 1
      craftVersion = craftVersion + 1
    end
  end
  ui("place", 0.7)
  hint(string.format("wheel settings copied to %d other wheel%s", n, n == 1 and "" or "s"), 2.5)
  return n
end

function wheelReset(uid)
  if not (parts[uid] and parts[uid].def.wheel) then return end
  wcfg_undo()
  wcfgs[uid] = nil
  craftVersion = craftVersion + 1
  ui("scrap", 0.6)
end

-- The wheel the settings panel is for: the selection, when it's a wheel and
-- nothing else (a part in hand, shaping, the stage or groups tool) has the
-- right-hand panel.
function wheelSelected()
  if ghost or shapingUid() or tool == "groups" or tool == "stage" then return nil end
  local p = selected_uid and parts[selected_uid]
  if p and p.def.wheel then return selected_uid end
  return nil
end

-- The craft's front on the stand, level (x, z): a rover body or a command
-- seat faces its +X; failing those, the command part's +X; failing that, +X.
-- The same rule as the flight's (vessel_controller r2FrontOf).
function craftFront()
  local function level(p)
    local X = rot_basis(p.yaw, p.pitch, p.roll)
    local l = math.sqrt(X.x * X.x + X.z * X.z)
    if l < 0.5 then return nil end
    return X.x / l, X.z / l
  end
  local best, bu
  for u, p in pairs(parts) do
    if (p.def.front or p.def.seat) and (not bu or u < bu) then
      local fx, fz = level(p)
      if fx then best, bu = { fx, fz }, u end
    end
  end
  if best then return best[1], best[2] end
  local cu
  for u, p in pairs(parts) do
    if (p.def.kind == "crewed" or p.def.kind == "probe") and (not cu or u < cu) then cu = u end
  end
  if cu then
    local fx, fz = level(parts[cu])
    if fx then return fx, fz end
  end
  return 1, 0
end

-- Each wheel as the flight will treat it: which way it rolls the craft when W
-- is pressed (`roll` x, z, or nil when it can't push forward or back — its
-- axle lies along the travel), whether it drives and steers, and where.
function wheelPlan()
  local fx, fz = craftFront()
  local m, cx, cz = 0, 0, 0
  for _, p in pairs(parts) do
    local dm = math.max(0.001, p.def.mass or 0.1)
    m, cx, cz = m + dm, cx + p.x * dm, cz + p.z * dm
  end
  if m > 0 then cx, cz = cx / m, cz / m end
  local out, amin, amax = {}, math.huge, -math.huge
  for u, p in pairs(parts) do
    if p.def.wheel then
      local c = wheelCfg(u)
      local X = rot_basis(p.yaw, p.pitch, p.roll)
      local al = math.sqrt(X.x * X.x + X.z * X.z)
      local w = { uid = u, p = p, cfg = c, ax = X, a = (p.x - cx) * fx + (p.z - cz) * fz }
      if al > 0.3 then
        -- the rolling direction: level, square to the axle, toward the front
        local dx, dz = -X.z / al, X.x / al
        local along = dx * fx + dz * fz
        if math.abs(along) > 0.3 then
          local sg = along > 0 and 1 or -1
          if c.drive == "invert" then sg = -sg end
          w.roll = { dx * sg, dz * sg }
        else
          w.sideways = true
        end
      else
        w.upright = true
      end
      w.drives = w.roll ~= nil and c.drive ~= "off"
      amin, amax = math.min(amin, w.a), math.max(amax, w.a)
      out[#out + 1] = w
    end
  end
  local span = (#out > 0) and (amax - amin) or 0
  for _, w in ipairs(out) do
    local c = w.cfg
    if c.steer == "off" or c.steerMax <= 0 then w.steers = false
    elseif c.steer == "on" or c.steer == "invert" then w.steers = true
    else w.steers = span > 0.3 and w.a > 0.2 * span end
  end
  return out, fx, fz
end

-- The front arrow on the pad and, at every wheel, its roll arrow and steer arc.
function wheelArrows()
  local any = false
  for _, p in pairs(parts) do if p.def.wheel then any = true break end end
  if not any then return end
  local plan, fx, fz = wheelPlan()
  local y = params.floor_y + 0.03
  draw.line(centerX, y, centerZ, centerX + fx * 1.6, y, centerZ + fz * 1.6, 0.35, 0.95, 0.55, 1.0)
  draw.cone(centerX + fx * 1.6, y, centerZ + fz * 1.6, fx, 0, fz, 0.16, 0.36, 0.35, 0.95, 0.55, 1.0)
  local sel = wheelSelected()
  for _, w in ipairs(plan) do
    local p, X = w.p, w.ax
    -- just outside the tyre, at hub height: out along the axle, away from the hull
    local ox, oz = X.x, X.z
    local ol = math.sqrt(ox * ox + oz * oz)
    if ol > 1e-3 then ox, oz = ox / ol, oz / ol end
    if (p.x - centerX) * ox + (p.z - centerZ) * oz < 0 then ox, oz = -ox, -oz end
    local reach = (p.def.rx or 0.2) + 0.08
    local bx, by, bz = p.x + ox * reach, p.y, p.z + oz * reach
    local hot = sel == w.uid or (sel and parts[sel] and parts[sel].sym and parts[sel].sym == p.sym)
    local L = 0.55 + (p.def.rz or 0.3)
    if w.roll then
      local r, g, b = 0.35, 0.95, 0.55
      if not w.drives then r, g, b = 0.6, 0.65, 0.7
      elseif w.cfg.drive == "invert" then r, g, b = 1.0, 0.62, 0.2 end
      local ex, ez = bx + w.roll[1] * L, bz + w.roll[2] * L
      draw.line(bx, by, bz, ex, by, ez, r, g, b, hot and 1.0 or 0.8)
      draw.cone(ex, by, ez, w.roll[1], 0, w.roll[2], 0.07, 0.18, r, g, b, hot and 1.0 or 0.8)
      if w.steers then
        -- the arc it swings through, about the vertical, either side of ahead
        local pts, m = {}, math.rad(w.cfg.steerMax)
        local rr = L * 0.75
        for k = 0, 12 do
          local a = -m + 2 * m * k / 12
          local ca, sa = math.cos(a), math.sin(a)
          local dx = w.roll[1] * ca - w.roll[2] * sa
          local dz = w.roll[1] * sa + w.roll[2] * ca
          pts[#pts + 1] = bx + dx * rr; pts[#pts + 1] = by; pts[#pts + 1] = bz + dz * rr
        end
        draw.polyline(pts, 0.4, 0.85, 1.0, hot and 1.0 or 0.7)
        local ca, sa = math.cos(m), math.sin(m)
        for _, s2 in ipairs({ -1, 1 }) do
          local dx = w.roll[1] * ca - w.roll[2] * sa * s2
          local dz = w.roll[1] * sa * s2 + w.roll[2] * ca
          draw.line(bx, by, bz, bx + dx * rr, by, bz + dz * rr, 0.4, 0.85, 1.0, 0.45)
        end
      end
    else
      -- it can't roll the craft forward: its axle lies along the travel (or stands up)
      draw.sphere(bx, by, bz, 0.12, 1.0, 0.3, 0.25, 1.0)
      draw.line(bx - fx * 0.4, by, bz - fz * 0.4, bx + fx * 0.4, by, bz + fz * 0.4, 1.0, 0.3, 0.25, 1.0)
    end
  end
end

-- ── ROUND TWO, every frame: rover FRONT arrow, fairing shells ───────────────
-- A rover drives toward its FRONT (a rover body's +X, else the build's +X):
-- an arrow on the pad says which way W goes. A fairing base with a payload on
-- it shows the shell it will grow, translucent, rebuilt when the payload
-- changes.
local shells = {}   -- fairing uid → { sig, nodes = {…}, meshes = {…} }
function free_shell(uid)
  local sh = shells[uid]
  if not sh then return end
  for _, n in ipairs(sh.nodes or {}) do if n.valid then destroy(n) end end
  for _, m in ipairs(sh.meshes or {}) do if mesh and mesh.free then mesh.free(m) end end
  shells[uid] = nil
end

function roundTwoTick()
  -- the rover's front and every wheel's roll and steer (wheelArrows)
  if partCount > 0 and #parts_with("wheel") > 0 then wheelArrows() end
  -- fairing shells
  local E = elib()
  if not (E and E.fairingShell and mesh and mesh.build) then return end
  for uid in pairs(shells) do
    if not parts[uid] then free_shell(uid) end
  end
  -- (only fairings, and their fit only when the craft changed or one is being shaped)
  local fl = parts_with("fairing")
  if #fl == 0 then return end
  if W.cache.shell_v == craftVersion and W.cache.shell_l == W.landed and not (shapingUid and shapingUid()) then return end
  W.cache.shell_v, W.cache.shell_l = craftVersion, W.landed
  for _, uid in ipairs(fl) do
    local p = parts[uid]
    if p.def.fairing and p.node and p.node.valid then
      local fit = fairingFit(uid)
      local prof = fit and fit.prof
      local editing = shapingUid and shapingUid() == uid
      local sig = "none"
      if prof then
        local bits = { fit.split or 2, editing and "e" or "" }
        for _, q in ipairs(prof) do bits[#bits + 1] = string.format("%.3f,%.3f", q[1], q[2]) end
        sig = table.concat(bits, "/")
      end
      local sh = shells[uid]
      if not sh or sh.sig ~= sig or sh.node ~= p.node.id then
        free_shell(uid)
        sh = { sig = sig, nodes = {}, meshes = {}, node = p.node.id }
        shells[uid] = sh
        if prof and #prof >= 2 then
          local n = fit.split or 2
          for k = 1, n do
            local name = mesh.build(E.fairingPiece(prof, k, n, 24))
            sh.meshes[#sh.meshes + 1] = name
            createNode("Fairing Shell", p.node, function(c)
              c.model = name
              -- A drawn shell's pieces part by a hair, so the clamshell seams
              -- show where it will split.
              if n == 3 or fit.shaped then
                local ac = (k - 0.5) * 2 * math.pi / n
                c.x, c.z = math.cos(ac) * 0.012, math.sin(ac) * 0.012
              end
              c:setMaterial{ texture = "textures/parts/paint_albedo.png", normalMap = "textures/parts/paint_normal.png",
                             roughnessMap = "textures/parts/paint_orm.png", shading = "physical",
                             roughness = 0.8, metallic = 0.2, alpha = editing and 0.18 or 0.28 }
              if shells[uid] == sh then sh.nodes[#sh.nodes + 1] = c else destroy(c) end
            end)
          end
        end
      end
    end
  end
end

-- ── SHAPING A FAIRING (KSP-style) ────────────────────────────────────────────
-- Select a fairing base and press B (or click the SHAPE FAIRING button under
-- it). The mouse then drives a RING around the base's axis — out from the axis
-- is its radius, up the axis its height — drawn live with the wireframe it
-- would add. Each click lays a ring there; the shell is lathed through them,
-- translucent, as you go. C closes it over the top with a nose (so does
-- ENTER/ESC on the way out), BACKSPACE (or CTRL+Z) takes the last ring back,
-- DEL clears the shape (back to the shell that fits itself to the payload),
-- V splits it into 2 or 3 clamshell pieces. SHIFT turns off the snapping
-- (5 cm steps, and a ring near the last one's radius makes a straight wall).
-- Parts the closed shell would hold outline green, parts sticking out red.
local shaping = nil       -- { uid, prev } while a fairing is being shaped
shapeCursor = nil         -- { r =, h = } overrides the mouse (probes)

function shapingUid() return shaping and shaping.uid or nil end

function shape_frame(uid)
  local b = parts[uid]
  local X, Y, Z = rot_basis(b.yaw, b.pitch, b.roll)
  return b, X, Y, Z, b.def.h * 0.5
end

-- A point at radius r, angle a (about the axis, from the base's X toward its
-- Z: the profile's own convention) and height y in the base frame.
function shape_pt(b, X, Y, Z, r, a, y)
  local c, s = math.cos(a) * r, math.sin(a) * r
  return b.x + X.x * c + Y.x * y + Z.x * s, b.y + X.y * c + Y.y * y + Z.y * s, b.z + X.z * c + Y.z * y + Z.z * s
end

function shape_ring(b, Y, r, y, cr, cg, cb, ca)
  draw.ring(b.x + Y.x * y, b.y + Y.y * y, b.z + Y.z * y, Y.x, Y.y, Y.z, math.max(0.01, r), cr, cg, cb, ca)
end

-- The profile's rings and `n` meridians through them: the wireframe shell.
function shape_wire(b, X, Y, Z, prof, n, cr, cg, cb, ca, rings)
  for k = 0, n - 1 do
    local a = k * 2 * math.pi / n
    local pts = {}
    for _, q in ipairs(prof) do
      local x, y, z = shape_pt(b, X, Y, Z, q[1], a, q[2])
      pts[#pts + 1] = x; pts[#pts + 1] = y; pts[#pts + 1] = z
    end
    if #pts >= 6 then draw.polyline(pts, cr, cg, cb, ca) end
  end
  if rings then
    for _, q in ipairs(prof) do if q[1] > 0.01 then shape_ring(b, Y, q[1], q[2], cr, cg, cb, ca) end end
  end
end

-- The mouse as a (radius, height-above-the-ring) pair: its ray meets the plane
-- through the base's axis that faces the camera.
function shape_cursor(b, X, Y, Z, y0)
  if shapeCursor then return shapeCursor.r, shapeCursor.h end
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local cx, cy, cz = b.x + Y.x * y0, b.y + Y.y * y0, b.z + Y.z * y0
  local vx, vy, vz = ox - cx, oy - cy, oz - cz
  local d = vx * Y.x + vy * Y.y + vz * Y.z
  local nx, ny, nz = unit(vx - Y.x * d, vy - Y.y * d, vz - Y.z * d)
  if nx == 0 and ny == 0 and nz == 0 then return nil end
  local den = dx * nx + dy * ny + dz * nz
  if math.abs(den) < 1e-6 then return nil end
  local t = ((cx - ox) * nx + (cy - oy) * ny + (cz - oz) * nz) / den
  if t <= 0 then return nil end
  local px, py, pz = ox + dx * t - cx, oy + dy * t - cy, oz + dz * t - cz
  local h = px * Y.x + py * Y.y + pz * Y.z
  local wx, wy, wz = px - Y.x * h, py - Y.y * h, pz - Y.z * h
  return math.sqrt(wx * wx + wy * wy + wz * wz), h
end

-- Snap a cursor ring (5 cm steps; near the last ring's radius = a straight
-- wall) and say whether it can go there. Pure, so the smoke test asks it.
function shapeSnap(secs, R0, r, h, free)
  local last = secs[#secs]
  local lr, lh = last and last.r or R0, last and last.h or 0
  if not free then
    r = math.floor(r / 0.05 + 0.5) * 0.05
    h = math.floor(h / 0.05 + 0.5) * 0.05
    if math.abs(r - lr) < 0.08 then r = lr end
  end
  r = math.max(0.05, math.min(6.0, r))
  if h < lh + 0.05 - 1e-6 then
    return r, h, false, "each ring goes ABOVE the last one — move the mouse up the axis"
  end
  return r, h, true
end

function shapeStart(uid)
  if not (parts[uid] and parts[uid].def.fairing) then return false end
  if shaping then shapeStop(true) end
  local prev = copy_shape(fshapes[uid])
  local sh = fshapes[uid] or { secs = {}, closed = false, split = 2 }
  sh.closed = false
  fshapes[uid] = sh
  craftVersion = craftVersion + 1
  shaping = { uid = uid, prev = prev }
  sel_only(uid)
  click_cool = 0.15
  ui("tool", 0.8)
  hint("SHAPING THE FAIRING — click to lay a ring at the cursor  ·  C close it over the top  ·  ENTER done", 6.0)
  return true
end

-- Leave shaping. The shape closes itself over the top (a shell must be closed
-- to hold anything); one with no rings goes back to the fitted shell. `commit`
-- false leaves no undo step (a reload).
function shapeStop(commit)
  if not shaping then return end
  local uid = shaping.uid
  local sh = fshapes[uid]
  if sh then
    if #sh.secs == 0 then fshapes[uid] = nil
    elseif not sh.closed then sh.closed = true end
  end
  craftVersion = craftVersion + 1
  local prev = shaping.prev
  shaping = nil
  click_cool = 0.15
  if commit == false or not parts[uid] then return end
  push_undo({ type = "shape", uid = uid, prev = prev })
  local fit = fairingFit(uid)
  if fshapes[uid] and fit and fit.prof then
    hint(string.format("fairing shaped — %d ring%s · %.0f kg shell · %d piece%s · holds %d of %d parts%s  (CTRL+Z undoes it)",
      #fshapes[uid].secs, #fshapes[uid].secs == 1 and "" or "s", fit.mass * 1000, fit.split, fit.split == 1 and "" or "s",
      fit.nin, fit.nin + fit.nout, fit.nout > 0 and "  ⚠ some stick out" or ""), 5.0)
  else
    hint("fairing: no shape drawn — its shell fits whatever stands on it", 3.0)
  end
  ui("place", 0.9)
  refresh_stats()
end

-- The interface's design height: 720 at an interface size of 100%
-- (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
local dh_ref = nil
function uiDesignH()
  if not (dh_ref and dh_ref.valid) then dh_ref = findScript and findScript("settings") or nil end
  return (dh_ref and dh_ref.designHeight and dh_ref.designHeight()) or 720
end

function screen_k()
  local _, sh = nil, nil
  if camera.screenSize then _, sh = camera.screenSize() end
  return (sh and sh > 1) and sh / uiDesignH() or 1.0, sh or 720
end

-- Screen-space drawing that a host without it (the smoke harness) skips.
local function srect(...) if draw.rect then draw.rect(...) end end
local function sframe(...) if draw.rectOutline then draw.rectOutline(...) end end
local function stext(...) if draw.text then draw.text(...) end end

-- The key card while shaping, bottom-centre over the hangar.
function shape_hud(sh, cur, pv, nin, nout)
  local k, shh = screen_k()
  local sw = camera.screenSize and camera.screenSize() or 1280
  local w, hgt = 552 * k, 112 * k
  local x, y = (sw - w) * 0.5, shh - hgt - 52 * k
  srect(x, y, w, hgt, 0.035, 0.08, 0.10, 0.9, 8 * k)
  sframe(x, y, w, hgt, 0.35, 0.9, 0.75, 0.9, 1.5 * k)
  local ts, lx, rx = 13 * k, x + 14 * k, x + w * 0.5 + 4 * k
  stext(lx, y + 9 * k, string.format("SHAPING THE FAIRING  ·  %d ring%s  ·  %d pieces", #sh.secs,
    #sh.secs == 1 and "" or "s", sh.split or 2), 15 * k, 0.55, 1.0, 0.85, 1.0)
  if cur then
    stext(x + w - 14 * k, y + 10 * k, string.format("ring  r %.2f m · h %.2f m", cur.r, cur.h), ts,
      0.62, 0.78, 0.8, 1.0, "right")
  end
  local L = {
    { "CLICK", "lay a ring at the cursor", "BACKSPACE", "take the last ring back" },
    { "C", "close it over the top", "DEL", "clear (fit to payload)" },
    { "V", "2 or 3 pieces", "ENTER · ESC", "done" },
  }
  for i, l in ipairs(L) do
    local yy = y + (14 + 20 * i) * k
    stext(lx, yy, l[1], ts, 1.0, 0.82, 0.4, 1.0)
    stext(lx + 56 * k, yy, l[2], ts, 0.85, 0.9, 0.95, 1.0)
    stext(rx, yy, l[3], ts, 1.0, 0.82, 0.4, 1.0)
    stext(rx + 92 * k, yy, l[4], ts, 0.85, 0.9, 0.95, 1.0)
  end
  local s
  if pv then
    s = string.format("closed: %.2f m wide · %.2f m tall · %.0f kg · holds %d of %d parts", pv.rmax * 2,
      pv.height, pv.mass * 1000, nin, nin + nout)
    if nout > 0 then s = s .. "  ⚠ red = sticks out" end
  else
    s = "the base ring is where the shell starts — lay the first ring above it"
  end
  stext(lx, y + 90 * k, s, ts, (nout or 0) > 0 and 1.0 or 0.62, (nout or 0) > 0 and 0.7 or 0.78,
    (nout or 0) > 0 and 0.55 or 0.8, 1.0)
end

-- The SHAPE FAIRING button under a selected base; true = it took the click.
function shape_button(clicked, cam_busy)
  local uid = selected_uid
  local b, X, Y, Z, y0 = shape_frame(uid)
  local sx, sy, on = screen_of(b.x - Y.x * y0, b.y - Y.y * y0, b.z - Y.z * y0)
  if not on then return false end
  local k = screen_k()
  local w, h = 210 * k, 30 * k
  local bx, by = sx - w * 0.5, sy + 36 * k
  local mx, my = input.mouse()
  local hot = mx >= bx and mx <= bx + w and my >= by and my <= by + h
  srect(bx, by, w, h, 0.05, 0.16, 0.19, hot and 0.97 or 0.86, 6 * k)
  sframe(bx, by, w, h, 0.4, 0.95, 0.8, 1.0, (hot and 2.0 or 1.2) * k)
  stext(bx + w * 0.5, by + 7 * k, (fshapes[uid] and "✎  RESHAPE FAIRING   [B]" or "✎  SHAPE FAIRING   [B]"),
    14 * k, 0.75, 1.0, 0.9, 1.0, "center")
  if hot and clicked and not cam_busy then return shapeStart(uid) end
  return false
end

-- Every frame, before anything else in `update` takes input. Returns true when
-- shaping (or the SHAPE button) owns this frame's input.
function shapeTick(clicked, cam_busy)
  if not shaping then
    local sel = selected_uid and parts[selected_uid]
    if ghost or not (sel and sel.def.fairing) or tool == "stage" or tool == "groups" or gizmo_drag then return false end
    -- B shapes a fairing only while WP5's bind prompt (builder_bind.begin)
    -- isn't there to take the key
    local bd = findScript and findScript("builder_bind")
    if input.pressed("b") and not input.key("ctrl") and not (bd and bd.begin) then return shapeStart(selected_uid) end
    return shape_button(clicked, cam_busy)
  end
  local uid = shaping.uid
  local b = parts[uid]
  local E = elib()
  if not (b and E) then shaping = nil return false end
  local sh = fshapes[uid]
  if not sh then sh = { secs = {}, closed = false, split = 2 }; fshapes[uid] = sh end
  local _, X, Y, Z, y0 = shape_frame(uid)
  local R0 = b.def.fairing
  -- keys
  if input.pressed("enter") or input.pressed("escape") then shapeStop(true) return true end
  if input.pressed("c") then
    if #sh.secs > 0 then sh.closed = true; shapeStop(true)
    else hint("lay at least one ring first — click where the shell should reach", 2.5) end
    return true
  end
  if input.pressed("backspace") or (input.key("ctrl") and input.pressed("z")) then
    if #sh.secs > 0 then table.remove(sh.secs); ui("pickup", 0.7)
    else hint("no rings to take back — ENTER leaves shaping", 2.0) end
    return true
  end
  if input.pressed("delete") or input.pressed("del") then
    sh.secs = {}
    ui("scrap", 0.7)
    hint("shape cleared — click to start again, or ENTER to keep the shell that fits itself", 3.0)
    return true
  end
  if input.pressed("v") then
    sh.split = (sh.split == 3) and 2 or 3
    ui("tool", 0.7)
    hint(string.format("the shell splits into %d pieces at staging", sh.split), 2.0)
  end
  -- the cursor ring
  local r, h = shape_cursor(b, X, Y, Z, y0)
  local ok, why
  if r then r, h, ok, why = shapeSnap(sh.secs, R0, r, h, input.key("shift")) end
  -- what's drawn: the base ring, the rings laid, the nose C would add, and the
  -- ring under the cursor tied to the last one
  local open = E.fairingSectionsProfile(R0, y0, sh.secs, false)
  shape_ring(b, Y, R0, y0, 0.9, 0.95, 1.0, 0.9)
  if #sh.secs > 0 then
    shape_wire(b, X, Y, Z, open, 12, 0.35, 0.95, 0.85, 0.95, true)
    local nose = E.fairingNose(E.fairingSectionsProfile(R0, y0, sh.secs, false))
    local tail = {}
    for i = #open, #nose do tail[#tail + 1] = nose[i] end
    shape_wire(b, X, Y, Z, tail, 12, 0.6, 0.7, 0.75, 0.45, false)
  end
  if r then
    local cr, cg, cb = 0.35, 1.0, 0.45
    if not ok then cr, cg, cb = 1.0, 0.3, 0.25 end
    shape_ring(b, Y, r, y0 + h, cr, cg, cb, 1.0)
    local last = open[#open]
    shape_wire(b, X, Y, Z, { last, { r, y0 + h } }, 12, cr, cg, cb, 0.55, false)
    -- a spoke from the axis to the cursor, so the radius reads
    local ax, ay, az = shape_pt(b, X, Y, Z, 0, 0, y0 + h)
    local px, py, pz = shape_pt(b, X, Y, Z, r, 0, y0 + h)
    draw.line(ax, ay, az, px, py, pz, cr, cg, cb, 0.8)
  end
  -- the payload: green if the closed shell would hold it, red if it sticks out
  local pv, nin, nout = nil, 0, 0
  if #sh.secs > 0 then
    local closed = E.fairingSectionsProfile(R0, y0, sh.secs, true)
    local area, rmax, height = E.fairingStats(closed)
    pv = { rmax = rmax, height = height, mass = area * SHELL_T_PER_M2 }
    for u, pl in pairs(fairing_payload(uid)) do
      local q = parts[u]
      if E.fairingHolds(closed, pl.lo, pl.hi, pl.rad) then
        nin = nin + 1
        if q then outline(q, 0.35, 1.0, 0.5, 0.55) end
      else
        nout = nout + 1
        if q then outline(q, 1.0, 0.3, 0.25, 0.95) end
      end
    end
  end
  shape_hud(sh, r and { r = r, h = h } or nil, pv, nin, nout)
  if clicked and not cam_busy and r then
    if ok then
      sh.secs[#sh.secs + 1] = { r = r, h = h }
      ui("place", 0.7)
    elseif why then
      hint(why, 2.0)
    end
  end
  return true
end

-- PROBE: run the shaping sequence on fairing `uid` up to `step` (shots).
--   0 selected (the SHAPE button)   1 shaping, cursor ring only
--   2 one ring laid, cursor up the side   3 two rings, cursor toward the top
--   4 closed (2 pieces)   5 closed, 3 pieces, cursor shape re-opened
function fairingProbe(uid, step)
  sel_only(uid)
  if step <= 0 then return end
  shapeStart(uid)
  local sh = fshapes[uid]
  shapeCursor = { r = 0.78, h = 0.3 }
  if step >= 2 then sh.secs[#sh.secs + 1] = { r = 0.75, h = 0.25 }; shapeCursor = { r = 0.82, h = 2.05 } end
  if step >= 3 then sh.secs[#sh.secs + 1] = { r = 0.75, h = 2.1 }; shapeCursor = { r = 0.42, h = 2.55 } end
  if step >= 4 then
    sh.secs[#sh.secs + 1] = { r = 0.45, h = 2.5 }
    if step >= 5 then sh.split = 3 end
    sh.closed = true
    shapeCursor = nil
    shapeStop(true)
  end
end
-- In the STAGE tab, a numbered badge at each event's part(s) — the stage
-- number beside it — so the list and the craft are unmistakably the same.
-- The hovered event (or stage) glows green.
function draw_stage_badges()
  if tool ~= "stage" then return end
  if stage_hover and (time or 0) - (W.stage_hover_t or 0) > 0.25 then stage_hover = nil end
  local items = sync_stage_order()
  local k = screen_k and screen_k() or 1
  for n, g in ipairs(stage_order) do
    for _, key in ipairs(g) do
      local it = items[key]
      if it then
        local hot = (stage_hover == key) or (stage_hover == ("s" .. n))
        local r, gg, b = 1.0, 0.75, 0.25
        if it.chute then r, gg, b = 0.55, 0.8, 1.0 end
        if hot then r, gg, b = 0.3, 1.0, 0.5 end
        for _, uid in ipairs(it.uids) do
          local p = parts[uid]
          if p then
            local up = { x = 0, y = 1, z = 0 }
            draw.disc(p.x, p.y + 0.15, p.z, up.x, up.y, up.z, 0.0, 0.22 + (hot and 0.08 or 0), r, gg, b, 0.9)
            draw.ring(p.x, p.y + 0.15, p.z, up.x, up.y, up.z, 0.30, r, gg, b, 1.0)
            draw.line(p.x, p.y, p.z, p.x, p.y + 0.15, p.z, r, gg, b, 0.8)
            if hot then outline(p, 0.3, 1.0, 0.5, 0.9) end
            if draw.text and camera and camera.worldToScreen then
              -- (the builder's camera takes stand-local points: builder_space wrapCamera)
              local sx, sy = camera.worldToScreen(p.x, p.y + 0.15, p.z)
              if sx then draw.text(sx + 14 * k, sy - 9 * k, tostring(n), 16 * k, r, gg, b, 1.0) end
            end
          end
        end
      end
    end
  end
end

-- The world badges of the STAGE tab (the tab itself is the right plate's,
-- builder_inspector; it owns its own mouse). Lives OUTSIDE `update` so that
-- huge function stays under LuaJIT's 60-upvalue-per-function ceiling.
function handle_staging(clicked, lmb, grab_mode)
  draw_stage_badges()
  return false
end

-- THE MODES, always on screen (bottom centre): symmetry as a row of chips —
-- OFF ×2 ×3 ×4 ×6 ×8 and MIRROR, the live one lit (X / SHIFT+X, M) — and what
-- the rotation keys turn about (C), with the keys themselves while they work.
function drawModes()
  if not draw.rect then return end
  local k, sh = screen_k()
  local sw = (camera.screenSize and camera.screenSize()) or 1280
  local chips = { { "OFF", not sym_mirror and sym_n == 1 } }
  for _, n in ipairs(SYM_STEPS) do
    if n > 1 then chips[#chips + 1] = { "×" .. n, not sym_mirror and sym_n == n } end
  end
  chips[#chips + 1] = { "MIRROR", sym_mirror }
  local cw, ch, gap = 44 * k, 22 * k, 4 * k
  local wide = 64 * k
  local total = 0
  for _, c in ipairs(chips) do total = total + ((#c[1] > 3) and wide or cw) + gap end
  local label_w = 112 * k
  local x = sw * 0.5 - (total + label_w) * 0.5
  local y = sh - 98 * k
  srect(x - 8 * k, y - 6 * k, total + label_w + 12 * k, ch + 12 * k, 0.05, 0.07, 0.09, 0.78, 6 * k)
  stext(x, y + 4 * k, "SYMMETRY  X", 13 * k, 0.75, 0.82, 0.88, 1.0)
  x = x + label_w
  for _, c in ipairs(chips) do
    local w = (#c[1] > 3) and wide or cw
    if c[2] then
      srect(x, y, w, ch, 1.0, 0.62, 0.22, 0.95, 4 * k)
      stext(x + w * 0.5, y + 4 * k, c[1], 13 * k, 0.08, 0.06, 0.04, 1.0, "center")
    else
      srect(x, y, w, ch, 0.22, 0.25, 0.28, 0.85, 4 * k)
      stext(x + w * 0.5, y + 4 * k, c[1], 13 * k, 0.75, 0.78, 0.8, 1.0, "center")
    end
    x = x + w + gap
  end
  local sel = selected_uid and parts[selected_uid]
  local rot = "ROTATE about the " .. ((ROT_FRAME == "camera") and "CAMERA" or "PART") .. "  (C)"
  if ghost or (sel and tool == "rotate") then
    rot = rot .. "   ·   W/S pitch  A/D yaw  Q/E roll  (SHIFT 15°)   R spin   SPACE reset"
  elseif sel then
    rot = rot .. "   ·   R spin   SPACE reset   ·   2 = rotate tool"
  end
  stext(sw * 0.5, y + ch + 12 * k, rot, 12 * k, 0.7, 0.78, 0.86, 0.95, "center")
end

-- ═══ WP1: THE FRAME, THE INPUT MODEL AND THE KEY MAP (§4) ═════════════════
-- `update` is a short list of global ticks (LuaJIT allows a function 60
-- upvalues; the old single `update` sat at the ceiling).

RAW_CAMERA, RAW_DRAW = camera, draw
API_PANELS = {}

-- The frame adapter, the hash and this frame's share of the spawn queue.
function frameTick()
  if not W.F then
    local L = lib("builder_space")
    if L then
      local fnode = find and find("BuildFrame") or nil
      W.F = L.newFrame(fnode, RAW_CAMERA)
      if not W.F.identity then
        W.F.refresh()
        -- every builder coordinate is local: rays come in, draws go out
        camera = L.wrapCamera(W.F, RAW_CAMERA)
        draw = L.wrapDraw(W.F, RAW_DRAW)
      end
    end
  elseif not W.F.identity then
    W.F.refresh()
  end
  if W.load_wait and (W.F or W.load_wait_n and W.load_wait_n > 30) then
    W.load_wait = nil
    load_blueprint()
  elseif W.load_wait then
    W.load_wait_n = (W.load_wait_n or 0) + 1
  end
  ensure_hash()
  rehash_if_needed()
  spawnQueueTick()
end

-- The dirty-flag readout: at most once a frame, and at most twice a second
-- while a drag or a part in hand keeps changing the craft.
function statsTick()
  if not W.dirty then return end
  if (ghost ~= nil or gizmo_drag ~= nil) and time - (W.stats_t or -1e9) < 0.5 then return end
  W.stats_t = time
  refreshStatsNow()
end

local function other(kind)
  local h = findScript and findScript(kind) or nil
  if h and h.valid == false then return nil end
  return h
end
function toolbarOwnsModes()
  local t = other("builder_toolbar")
  return t ~= nil and t.ownsModes == true
end
function aeroDrawsOverlays()
  local a = other("builder_aero")
  return a ~= nil and a.drawsOverlays == true
end

-- ── the offset limit (§5.6): does a part still touch what it is attached to?
-- Oriented boxes (the larger of the registry and drawn half-extents), a
-- separating-axis test with a 2 cm margin.
local function half3(p)
  local d = p.def
  local a, b, c = visHalf(p.id, d)
  return math.max(d.rx, a), math.max(d.h * 0.5, b), math.max(d.rz, c)
end
function partsTouch(p, q, margin)
  margin = margin or 0.02
  local A, B = basisOf(p.yaw, p.pitch, p.roll), basisOf(q.yaw, q.pitch, q.roll)
  local ax, ay, az = half3(p)
  local bx, by, bz = half3(q)
  local T = { x = q.x - p.x, y = q.y - p.y, z = q.z - p.z }
  local Aa, Ba = { A.X, A.Y, A.Z }, { B.X, B.Y, B.Z }
  local ah, bh = { ax, ay, az }, { bx, by, bz }
  local function sep(L)
    local l2 = L.x * L.x + L.y * L.y + L.z * L.z
    if l2 < 1e-10 then return false end
    local l = math.sqrt(l2)
    local ra, rb = 0, 0
    for i = 1, 3 do
      ra = ra + math.abs(dot3(L, Aa[i])) * ah[i]
      rb = rb + math.abs(dot3(L, Ba[i])) * bh[i]
    end
    return math.abs(dot3(T, L)) > ra + rb + margin * l
  end
  for i = 1, 3 do
    if sep(Aa[i]) or sep(Ba[i]) then return false end
  end
  for i = 1, 3 do
    for j = 1, 3 do
      if sep(cross3(Aa[i], Ba[j])) then return false end
    end
  end
  return true
end
-- The parts that no longer touch their primary host (cached per craftVersion).
function detachedParts()
  local c = W.cache
  if c.det_v == craftVersion then return c.det end
  local out = {}
  for u, p in pairs(parts) do
    local h = p.parent and parts[p.parent]
    if h and not p.carried and not partsTouch(p, h, 0.02) then out[#out + 1] = u end
  end
  table.sort(out)
  c.det, c.det_v = out, craftVersion
  return out
end
-- The islands (components), cached per structVersion; loose = not the root's.
function islands()
  local c = W.cache
  if c.isl_v == W.sv then return c.isl end
  local G, L = graph(), lib("builder_graph")
  local comps = (G and L) and L.components(G, alive_set(), craft_root(), is_command) or {}
  local loose = {}
  for _, k in ipairs(comps) do
    if not k.root then for _, u in ipairs(k) do loose[u] = true end end
  end
  c.isl, c.loose, c.isl_v = comps, loose, W.sv
  return comps, loose
end
local function loose_set()
  islands()
  return W.cache.loose or {}
end

-- ── BADLY OVERLAPPING PARTS (playtest 2026-10-26) ─────────────────────────
-- "i moved the front wheel up inside of the cockpit a bit ... im wondering if
-- that odd movement i did also is making the physics freak out". Parts of one
-- craft never collide with each other (they are one rigid body), so an
-- overlap does the flight no harm — except where a part has to MEET
-- something: a wheel or a leg buried in the hull cannot reach the ground. The
-- builder says so instead of leaving it to a guess: a pair whose oriented
-- boxes interpenetrate deeper than OVERLAP_WARN_DEPTH (and than
-- OVERLAP_WARN_SHARE of the thinner part's half-thickness), neither mounted
-- on the other, is marked with a
-- thin red box on the part that sinks in (the smaller one), and LAUNCH lists
-- it among the warnings. A surface mount hugging its host, a wing root on a
-- fuselage, a part nudged to touch — all a few centimetres — say nothing.
OVERLAP_WARN_DEPTH = 0.10
OVERLAP_WARN_SHARE = 0.35
-- How deep two parts' oriented boxes go into each other (m), 0 apart: the
-- smallest overlap along the 15 separating axes (the SAT test partsTouch
-- does, measured instead of asked).
function partsOverlapDepth(p, q)
  local A, B = basisOf(p.yaw, p.pitch, p.roll), basisOf(q.yaw, q.pitch, q.roll)
  local ax, ay, az = half3(p)
  local bx, by, bz = half3(q)
  local T = { x = q.x - p.x, y = q.y - p.y, z = q.z - p.z }
  local Aa, Ba = { A.X, A.Y, A.Z }, { B.X, B.Y, B.Z }
  local ah, bh = { ax, ay, az }, { bx, by, bz }
  local best = math.huge
  local function axis(L)
    local l2 = L.x * L.x + L.y * L.y + L.z * L.z
    if l2 < 1e-10 then return true end
    local l = math.sqrt(l2)
    local ra, rb = 0, 0
    for i = 1, 3 do
      ra = ra + math.abs(dot3(L, Aa[i])) * ah[i]
      rb = rb + math.abs(dot3(L, Ba[i])) * bh[i]
    end
    local o = (ra + rb - math.abs(dot3(T, L))) / l
    if o <= 0 then return false end
    if o < best then best = o end
    return true
  end
  for i = 1, 3 do
    if not axis(Aa[i]) or not axis(Ba[i]) then return 0 end
  end
  for i = 1, 3 do
    for j = 1, 3 do
      if not axis(cross3(Aa[i], Ba[j])) then return 0 end
    end
  end
  return best == math.huge and 0 or best
end
-- The pairs that overlap badly: { { a = uid, b = uid, depth = m, sunk = uid } },
-- cached per craftVersion. The spatial hash finds the neighbours.
function badOverlaps()
  local c = W.cache
  if c.ovl_v == craftVersion then return c.ovl end
  local out, seen = {}, {}
  local H = ensure_hash()
  for u, p in pairs(parts) do
    if not p.carried then
      local ex, ey, ez = part_box(p)
      local list
      if H then list = H:box(p.x - ex, p.y - ey, p.z - ez, p.x + ex, p.y + ey, p.z + ez, {})
      else list = {} for v in pairs(parts) do list[#list + 1] = v end end
      for _, v in ipairs(list) do
        local q = parts[v]
        -- (a part and the host it is mounted on hug by design: a leg round
        -- an engine bell, a wing root in a fuselage)
        if v ~= u and q and not q.carried and p.parent ~= v and q.parent ~= u then
          local key = u < v and (u .. ":" .. v) or (v .. ":" .. u)
          if not seen[key] then
            seen[key] = true
            local d = partsOverlapDepth(p, q)
            if d > OVERLAP_WARN_DEPTH then
              local pa, pb, pc = half3(p)
              local qa, qb, qc = half3(q)
              local thin = math.min(math.min(pa, pb, pc), math.min(qa, qb, qc))
              if d > OVERLAP_WARN_SHARE * thin then
                local vp, vq = pa * pb * pc, qa * qb * qc
                out[#out + 1] = { a = u, b = v, depth = d, sunk = (vp <= vq) and u or v }
              end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(x, y) return x.depth > y.depth end)
  c.ovl, c.ovl_v = out, craftVersion
  return out
end

-- ── moving and turning the selection (one part, a ring, or many) ──────────
local function sel_units()
  local seen, n = {}, 0
  for _, u in ipairs(W.sel_order) do
    local p = parts[u]
    if p then
      local key = p.sym and ("g" .. p.sym) or ("u" .. u)
      if not seen[key] then seen[key] = true; n = n + 1 end
    end
  end
  return n
end
-- The selection plus its dependents (what a drag or a gizmo carries).
function selectionCarry()
  local set = {}
  for _, u in ipairs(W.sel_order) do
    if parts[u] then for v in pairs(edit_set(u)) do set[v] = true end end
  end
  for v in pairs(deps_of(set)) do set[v] = true end
  return set
end
function moveMulti(dx, dy, dz)
  if not selected_uid then return end
  if sel_units() <= 1 then return apply_edit(selected_uid, dx, dy, dz, 0, 0, 0) end
  local set = selectionCarry()
  edit_begin(selected_uid, set)
  for u in pairs(set) do
    local q = parts[u]
    if q then set_part_pos(q, q.x + dx, q.y + dy, q.z + dz) end
  end
  publish_center(); refresh_stats()
end
function rotateMulti(Q, uid)
  uid = uid or selected_uid
  if not (uid and parts[uid]) then return end
  if sel_units() <= 1 then return rotateSelection(uid, Q) end
  local set = selectionCarry()
  edit_begin(uid, set)
  local c = parts[uid]
  local cx, cy, cz = c.x, c.y, c.z
  for u in pairs(set) do
    local q = parts[u]
    if q then
      local v = basisApply(Q, { x = q.x - cx, y = q.y - cy, z = q.z - cz })
      set_part_pos(q, cx + v.x, cy + v.y, cz + v.z)
      set_part_rot(q, basisEuler(basisMul(Q, basisOf(q.yaw, q.pitch, q.roll))))
    end
  end
  publish_center(); refresh_stats()
end

-- ── selection by connection (double-click, menu ▸ Select) ─────────────────
function selectConnected(uid, scope, mode)
  local p = parts[uid]
  if not p then return selection() end
  local list = {}
  if scope == "ring" then
    list = p.sym and group_members(p.sym) or { uid }
  elseif scope == "same" then
    for u, q in pairs(parts) do if q.id == p.id then list[#list + 1] = u end end
    table.sort(list)
  else
    local G, L = graph(), lib("builder_graph")
    local block = nil
    if scope ~= "craft" then
      -- an assembly stops AT the first decoupler (it is included, not crossed)
      block = {}
      for u, q in pairs(parts) do if q.def.decouple and u ~= uid then block[u] = true end end
    end
    local set = (G and L) and L.graphFlood(G, alive_set(), { uid }, block) or { [uid] = true }
    if block then
      for u in pairs(block) do
        if G then
          for _, n in ipairs(G:neighbours(u)) do if set[n] then set[u] = true break end end
        end
      end
    end
    for u in pairs(set) do list[#list + 1] = u end
    table.sort(list)
  end
  -- the clicked part stays primary
  for i = #list, 1, -1 do if list[i] == uid then table.remove(list, i) end end
  list[#list + 1] = uid
  sel_apply(list, mode or "set")
  return selection()
end

-- ── the keys (§4.3) ─────────────────────────────────────────────────────────
local SNAP_GRIDS = { 0.01, 0.05, 0.25, 1.0, 0 }
local SNAP_ANGLES = { math.rad(1), math.rad(5), math.rad(15), 0 }
local function cycle(list, v)
  local i = 1
  for k, x in ipairs(list) do if math.abs(x - v) < 1e-9 then i = k end end
  return list[i % #list + 1]
end
local function fmt_grid(g)
  if g <= 0 then return "OFF" end
  if g < 1 then return string.format("%d cm", math.floor(g * 100 + 0.5)) end
  return string.format("%g m", g)
end

-- ESC backs out ONE level: the part in hand, a gizmo drag, the context menu, a
-- box being drawn, the selection. It never leaves the VAB (LEAVE is a button;
-- CTRL+Q asks first).
function escapeLadder()
  if ghost then cancel_ghost(); return "hand" end
  if W.drawing then
    if W.drawing.p0 then W.drawing.p0 = nil; hint("start point dropped — click a new start, ESC ends the tool", 2.0)
    else W.drawing = nil; hint(HINT_IDLE, 0.0); hint_t = 0 end
    return "draw"
  end
  if gizmo_drag then gizmo_drag = nil; if W.hist then W.hist:seal() end; return "gizmo" end
  local cx = other("builder_context")
  if cx and cx.isOpen and cx.isOpen() then if cx.close then cx.close() end; return "menu" end
  if W.box or W.press then W.box, W.press = nil, nil; return "box" end
  if #W.sel_order > 0 then sel_only(nil); hint("selection cleared", 1.0); return "selection" end
  return nil
end

-- A registered panel whose text field has focus owns the keyboard (WP2:
-- toolbar, catalogue and inspector export ownsKeys()).
function panelsOwnKeys()
  for _, s2 in ipairs(API_PANELS) do
    if s2.valid ~= false and s2.ownsKeys and s2.ownsKeys() then return true end
  end
  return false
end

function keysTick(cam_busy)
  if panelsOwnKeys() then return false end
  local ctrl, shift, alt = input.key("ctrl"), input.key("shift"), input.key("alt")
  if input.pressed("escape") then
    escapeLadder()
    return true
  end
  -- tools 1–4 (never while holding or dragging)
  if not ghost and not gizmo_drag and not ctrl then
    for i = 1, 5 do
      if input.pressed(tostring(i)) then
        setTool(TOOLS[i])
        ui("tool", 0.7)
        hint("tool: " .. TOOL_LABEL[tool] .. ((tool == "root") and " — click the part the craft hangs from"
          or (tool == "lift") and LIFT_HINT or ""), tool == "lift" and 5.0 or 2.0)
      end
    end
  end
  -- SYMMETRY: X cycles ×1 ×2 ×3 ×4 ×6 ×8 (SHIFT+X back)
  if input.pressed("x") and not ctrl then
    local idx = 1
    for i, n in ipairs(SYM_STEPS) do if n == sym_n then idx = i end end
    idx = shift and ((idx - 2) % #SYM_STEPS + 1) or (idx % #SYM_STEPS + 1)
    sym_n = SYM_STEPS[idx]
    sym_mirror = false
    hint(sym_n > 1
      and ("symmetry ×" .. sym_n .. " — a placement on a flank or face rings the hull, and one on a ring member copies to the whole ring")
      or "symmetry OFF — every placement is a single part", 2.5)
    refresh_stats()
  end
  -- MIRROR: M across the host, ALT+M across the craft's centre plane
  if input.pressed("m") and not ctrl then
    if alt then
      W.mirror_plane = (W.mirror_plane == "center") and "host" or "center"
      if not sym_mirror then toggleMirror() end
      hint(W.mirror_plane == "center" and "mirror across the CRAFT's centre plane (ALT+M: across the host)"
        or "mirror across the host", 2.5)
    else
      toggleMirror()
    end
  end
  -- SNAP: G grid, SHIFT+G angle
  if input.pressed("g") and not ctrl then
    if shift then
      W.angle = cycle(SNAP_ANGLES, W.angle)
      ROT_SNAP = W.angle
      hint("angle snap " .. ((W.angle > 0) and string.format("%d°", math.floor(math.deg(W.angle) + 0.5)) or "OFF"), 2.0)
    else
      W.grid = cycle(SNAP_GRIDS, W.grid)
      hint("grid snap " .. fmt_grid(W.grid), 2.0)
    end
    ui("tool", 0.6)
  end
  if input.pressed("t") and not ctrl then setTestMode(not W.test) end
  if input.pressed("v") and not ctrl then
    W.overlay = (W.overlay + 1) % 4
    hint(({ "overlays off", "overlays: CoM · CoT", "overlays: CoM · CoT · CoL", "overlays: CoM · CoT · CoL · aero" })[W.overlay + 1], 2.0)
  end
  -- F5 reloaded the blueprint before PHOTO took the key (§8.6): it still does
  -- while the camera does not claim it (builder_camera.photoKeys).
  if input.pressed("f5") and not ghost then
    local bc = other("builder_camera")
    if not (bc and bc.photoKeys == true) then load_blueprint() end
  end
  if input.pressed("tab") then
    local tb = other("builder_toolbar")
    if tb and tb.cycleTab then tb.cycleTab() end
  end
  if (input.pressed("/") and not shift) or (ctrl and input.pressed("f")) then
    local cp = other("catalog_panel")
    if cp and cp.focusSearch then cp.focusSearch() end
  end
  if ghost or gizmo_drag then return false end
  -- the selection
  if not ctrl and input.pressed("h") then
    if alt then cmd("unhideAll", {})
    elseif shift then cmd("isolate", { uids = selection() })
    elseif #W.sel_order > 0 then cmd("hide", { uids = selection(), on = true }) end
  end
  if not ctrl and input.pressed("n") and not W.drawing and REG.beamP then startDrawTool("beamP") end
  if W.drawing and (input.pressed("[") or input.pressed("]")) then drawToolCycle(input.pressed("]") and 1 or -1) end
  if not ctrl and input.pressed("b") then
    local bd = other("builder_bind")
    if bd and bd.begin and #W.sel_order > 0 then bd.begin(selection()) end
  end
  if ctrl then
    if input.pressed("z") then if shift then redo() else undo() end end
    if input.pressed("y") then redo() end
    if input.pressed("c") and #W.sel_order > 0 then copy(selection()) end
    if input.pressed("v") then paste() end
    if input.pressed("d") and #W.sel_order > 0 then duplicate(selection()) end
    if input.pressed("s") then craftSave() end
    if input.pressed("o") then
      local tb = other("builder_toolbar")
      if tb and tb.openLibrary then tb.openLibrary()
      else
        local names = {}
        for _, c in ipairs(craftList()) do names[#names + 1] = c.name end
        hint(#names > 0 and ("library: " .. table.concat(names, " · ")) or "the craft library is empty — CTRL+S saves this one", 4.0)
      end
    end
    if input.pressed("n") then craftNew() end
    if input.pressed("q") then
      if W.quit_t and time - W.quit_t <= 3.0 then W.quit_t = nil; doLeave()
      else W.quit_t = time; hint("CTRL+Q again to leave the VAB (the craft is kept)", 3.0) end
    end
  end
  return false
end

-- ── holding: the part (or carried set, or paste) in hand ───────────────────
function ghostTick(dt, clicked, released, cam_busy)
  -- Self-heal: never let a bad ghost wedge the builder.
  if ghost.carried and not parts[ghost.from_uid] then
    ghost = nil
    hint(HINT_IDLE, 0.0); hint_t = 0
    return
  elseif not ghost.carried and not ghost.node then
    ghost.wait = (ghost.wait or 0) + dt
    if ghost.wait > 4.0 then
      ghost = nil
      hint("that part failed to spawn — try again", 2.5)
    end
    return
  end
  -- snapped or free, turned by its mount and the player's keys (ghostFollow)
  local snap, x, y, z = ghostFollow()
  local exclude = ghost.exclude
  if ghost.carried then
    -- the part grabbed, outlined; past 24 parts the rest as one merged box (§8.2)
    local list = ghost.carried
    if #list <= 24 then
      for _, m in ipairs(list) do
        local cp = parts[m.uid]
        if cp then outline(cp, 1.0, 0.75, 0.3, 0.9) end
      end
    else
      local a, b2, cc, d, e, f = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
      for _, m in ipairs(list) do
        local cp = parts[m.uid]
        if cp then
          a, b2, cc = math.min(a, cp.x), math.min(b2, cp.y), math.min(cc, cp.z)
          d, e, f = math.max(d, cp.x), math.max(e, cp.y), math.max(f, cp.z)
        end
      end
      if a < math.huge then
        drawObb((a + d) * 0.5, (b2 + e) * 0.5, (cc + f) * 0.5, IDENT, (d - a) * 0.5 + 0.6, (e - b2) * 0.5 + 0.6,
          (f - cc) * 0.5 + 0.6, 1.0, 0.75, 0.3, 0.9)
      end
      local rp = parts[ghost.from_uid]
      if rp then outline(rp, 1.0, 0.75, 0.3, 0.9) end
    end
  end
  -- node rings: only on the part under the cursor and its neighbours (§4.6)
  local _, gey = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
  local A = attach_v2()
  if A and ghost.q and A.visibleNodes then
    for _, nd in ipairs(A.visibleNodes(ghost.q)) do
      if nd.captured then draw.ring(nd.x, nd.y, nd.z, nd.nx, nd.ny, nd.nz, 0.3, 1.0, 0.62, 0.22, 1.0)
      else draw.ring(nd.x, nd.y, nd.z, nd.nx, nd.ny, nd.nz, 0.26, 0.35, 0.85, 1.0, 0.8) end
    end
  end
  for u in pairs((not A) and ghost.show or {}) do
    local p = parts[u]
    if p then
      for _, a in ipairs(attach_nodes_of(u, p, ghost.def, gey, exclude)) do
        if a.insert then
          draw.ring(a.x, a.y, a.z, 0, 1, 0, 0.34, 1.0, 0.55, 0.15, 0.85)
        elseif a.side == "radial" then
          draw.ring(a.x, a.y, a.z, a.dx, a.dy, a.dz, 0.22, 1.0, 0.75, 0.3, 0.8)
        else
          draw.ring(a.x, a.y, a.z, 0, 1, 0, 0.3, 0.35, 0.85, 1.0, 0.8)
        end
      end
    end
  end
  local can_place, why
  local sym_slots, sym_kind = nil, nil
  local on_floor = ghost.on_floor
  if snap then
    local ex2 = { [snap.uid] = true }
    if snap.insert then ex2[snap.insert] = true end
    if exclude then for u in pairs(exclude) do ex2[u] = true end end
    local blocked
    -- a surface or flank mount hugs the hull by design: never overlap-gated
    -- (the old rule; builder_attach.blockedBy reads registry boxes, and an
    -- engine's rx is its plume clearance)
    if snap.wp3 then blocked = snap.wp3.blocked ~= nil and snap.wp3.kind ~= "surface"
    elseif snap.insert then blocked = false -- the far side moves out of the way
    else
      blocked = snap.side ~= "radial" and snap.side ~= "surface"
        and overlaps(ghost.def, x, y, z, ex2, ghost.yaw, ghost.pitch, ghost.roll)
    end
    if blocked then
      can_place, why = false, "that spot is buried inside another part"
      draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
    else
      can_place = true
      local cr, cg, cb = 0.3, 1.0, 0.4
      if snap.insert then cr, cg, cb = 1.0, 0.55, 0.15 end
      draw.line(x, y, z, snap.x, snap.y, snap.z, cr, cg, cb, 1.0)
      draw.ring(snap.x, snap.y, snap.z, snap.dx or 0, snap.dy or 1, snap.dz or 0, 0.4, cr, cg, cb, 1.0)
      if snap.insert then why = "INSERT — the stack beyond moves out to make room" end
      if snap.wp3 and snap.wp3.why then why = snap.wp3.why end
    end
    if can_place and not ghost.carried then
      sym_slots, sym_kind = symCopies(snap, x, y, z, ghost.B or IDENT, ghost.n)
      drawCopies(sym_slots)
    end
  elseif on_floor then
    if overlaps(ghost.def, x, y, z, exclude, ghost.yaw, ghost.pitch, ghost.roll) then
      can_place, why = false, "overlapping — find clear floor"
      draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
    else
      can_place = true
      local _, gey2 = eff_extents(ghost.def, ghost.yaw, ghost.pitch, ghost.roll)
      draw.ring(x, y - gey2, z, 0, 1, 0, 0.35, 0.4, 0.7, 1.0, 1.0)
    end
  else
    can_place, why = false, nil
    draw.sphere(x, y, z, 0.35, 1.0, 0.25, 0.2, 1.0)
  end
  -- DEL with a part in hand scraps everything being carried.
  if input.pressed("delete") or input.pressed("del") then
    local g = ghost
    if g.carried then
      ghost = nil
      uncarry(g)
      local n = 0
      for _, m in ipairs(g.carried) do if remove_part(m.uid) then n = n + 1 end end
      if g.tx and not g.paste then tx_commit(g.tx) end
      ui("scrap", 0.8)
      hint("scrapped " .. n .. " carried part(s) — CTRL+Z to undo", 2.5)
    else
      if g.node then destroy(g.node) end
      ghost = nil
      hint(HINT_IDLE, 0.0); hint_t = 0
    end
    return
  end
  local go = (clicked and not cam_busy) or (ghost.drag and released)
  if not go then return end
  if ghost.drag and released then ghost.drag = nil end
  if not can_place then
    if why then hint(why, 2.0)
    elseif clicked then hint("aim at a node, a part's surface or the floor", 2.5) end
    return
  end
  placeHeld(snap, x, y, z, sym_slots, sym_kind)
end

-- WP3's joint for a placement: the primary link takes the candidate's kind
-- and points, and the joint plate (gusset, splice, clamp) rides on the part.
function joinWp3(u, c)
  local p, G = parts[u], graph()
  if not (p and G) then return end
  local l = G:primary(u)
  if l and c.link then
    l.k = c.link.k or l.k
    -- the candidate's link runs held → host; ours runs host (a) → part (b)
    l.pa, l.pb, l.n = vcopy(c.link.pb), vcopy(c.link.pa), vcopy(c.link.n)
    if c.joint then
      local A = lib("builder_attach")
      l.s = (p.def.strength or 0) * ((A and A.JOINT_BONUS) or 1.25)
    end
  end
  if c.joint then
    p.joints = p.joints or {}
    p.joints[#p.joints + 1] = encodeJoint(c.joint)
    local P = lib("builder_proc")
    if p.node and P and P.dressJoint then P.dressJoint(p.node, c.joint) end
  end
  struct_changed()
end

-- AUTO-WELD (§5.3): every end of a placed part within 2 cm of another part's
-- surface gets a `weld` link (builder_attach.autoWelds on the hash's
-- neighbours). Closing a rectangle with its fourth beam welds both ends.
function autoWeld(u, t)
  local A, G, p = attach_v2(), graph(), parts[u]
  if not (A and A.autoWelds and G and p) then return 0 end
  local ex, ey, ez = part_box(p)
  local near = {}
  local H = ensure_hash()
  if not H then return 0 end
  local linked = { [u] = true }
  for _, n in ipairs(G:neighbours(u)) do linked[n] = true end
  for _, v in ipairs(H:box(p.x - ex - 0.05, p.y - ey - 0.05, p.z - ez - 0.05, p.x + ex + 0.05, p.y + ey + 0.05,
                           p.z + ez + 0.05, {})) do
    if v ~= u and parts[v] and not parts[v].carried then near[#near + 1] = arec(v) end
  end
  local n = 0
  for _, l in ipairs(A.autoWelds(arec(u), near, linked)) do
    if t then tx_add(t, { l.b }) end
    l.at = nil
    G:add(l)
    n = n + 1
  end
  if n > 0 then struct_changed() end
  return n
end

-- Put the hand down: the placement, its symmetry copies, an insert's shift —
-- one history step.
function placeHeld(snap, x, y, z, sym_slots, sym_kind)
  local g = ghost
  local host_uid = snap and snap.uid or nil
  local n_mount = g.n
  local keep = input.key("shift") and not g.carried
  local keep_id, keep_off = g.id, g.off
  local reselect = g.reselect
  local t = nil
  if not g.carried then
    t = tx_begin("place " .. (g.def.label or g.id), {})
    W.ptx = t
  end
  local ins = snap and snap.insert and parts[snap.insert] and parts[host_uid] and not g.carried
  if ins then
    -- INSERT: the far side moves out along the node's normal by the new part's
    -- height, and the joint re-forms through it (§5.4).
    local H, N = host_uid, snap.insert
    local far = beyond_of(N, H)
    local around = { [H] = true, [N] = true }
    for u in pairs(far) do around[u] = true end
    tx_add(t, around)
    local hB = basisOf(parts[H].yaw, parts[H].pitch, parts[H].roll)
    local nrm = (snap.side == "top") and hB.Y or neg3(hB.Y)
    local L = 2 * supportAlong(g.def, g.B or IDENT, nrm)
    for u in pairs(far) do
      local q = parts[u]
      if q then set_part_pos(q, q.x + nrm.x * L, q.y + nrm.y * L, q.z + nrm.z * L) end
    end
    local G = graph()
    if G then
      for _, l in ipairs(G:incident(H)) do
        if (l.a == N or l.b == N) and (l.k == "stack") then G:remove(l.id) end
      end
    end
    local placed = place_ghost(x, y, z, H, snap.side, nil)
    local opp = (snap.side == "top") and "bottom" or "top"
    if parts[N] and parts[N].parent == H then set_parent(N, placed, snap.side)
    elseif parts[H] and parts[H].parent == N then set_parent(H, placed, opp)
    else
      if G then G:add({ a = placed, b = N, k = "stack", sa = snap.side, sb = opp }) end
    end
    -- a stack pushed through the floor stands back up on it (the whole craft lifts)
    local comp = beyond_of(placed, -1)
    local low = math.huge
    for u in pairs(comp) do
      local q = parts[u]
      if q then local _, ey = part_box(q); low = math.min(low, q.y - ey) end
    end
    if low < params.floor_y - 0.005 then
      local lift = params.floor_y - low
      tx_add(t, comp)
      for u in pairs(comp) do
        local q = parts[u]
        if q then set_part_pos(q, q.x, q.y + lift, q.z) end
      end
    end
    sel_only(placed)
    hint("inserted — the stack moved out " .. string.format("%.2f m", L), 2.5)
  else
    local placed = place_ghost(x, y, z, host_uid, snap and snap.side or nil, nil)
    if placed and snap and snap.wp3 then joinWp3(placed, snap.wp3) end
    if placed then autoWeld(placed, t) end
    if reselect then sel_apply(reselect, "set") else sel_only(placed) end
    if sym_slots and #sym_slots > 0 and placed then
      placeCopies(placed, sym_slots, sym_kind, n_mount)
    end
    if placed and parts[placed] and parts[placed].def.fairing then
      hint("fairing base placed — stack the payload on it, then SHAPE FAIRING under it draws its shell", 5.0)
    end
    if placed and parts[placed] and parts[placed].def.dock then
      local host = host_uid and parts[host_uid]
      if host and host.def.dock then
        hint("docking seam — these two separate in flight (peripherals ▸ UNDOCK) and can re-dock later", 4.0)
      else
        hint("docking port placed — it needs a SECOND port stacked on its free face to make a seam that separates", 4.0)
      end
    end
  end
  if t then W.ptx = nil; tx_commit(t) end
  -- SHIFT+click keeps a copy in hand for the next one
  if keep and not ghost then
    pick(keep_id)
    if ghost then ghost.off = keep_off end
  end
end

-- ── THE BEAM, PANEL AND BRACE TOOLS (§5.5, WP3's builder_attach) ───────────
-- Beam: click a start (a node, a face on the host grid, the floor grid), move
-- (a live member stretches, its length snapped, a phosphor tag at the cursor),
-- click the end; SHIFT+click chains the next member from that end, ESC ends
-- the chain and then the tool. [ / ] change the profile (tube, box, I-beam,
-- truss). Panel: two corners on a face or the floor ([ / ] sheet or deck).
-- Brace: point A on a part, point B on another.
local DRAW_PROFILES = { "tube", "box", "ibeam", "truss" }
function startDrawTool(id)
  local A = attach_v2()
  local def = REG[id]
  if not (A and def and def.proc and A.pointOn) then return false end
  local kind = def.proc
  W.drawing = { id = id, kind = kind, prof = (kind == "member") and (W.draw_prof or def.prof or "box") or "brace",
                thick = W.draw_thick or 0.04, p0 = nil }
  click_cool = 0.15
  ui("tool", 0.7)
  hint(kind == "member" and "BEAM — click a start, then the end (ALT: end in the air · SHIFT+click chains · [ ] profile · ESC ends)"
    or (kind == "panel" and "PANEL — click one corner, then the opposite one ([ ] sheet or deck · ESC ends)"
    or "BRACE — click point A on a part, then point B on another (ESC ends)"), 6.0)
  return true
end
function drawingTool() return W.drawing and { id = W.drawing.id, kind = W.drawing.kind, prof = W.drawing.prof,
  started = W.drawing.p0 ~= nil } or nil end
function drawToolCycle(dir)
  local d = W.drawing
  if not d then return end
  if d.kind == "member" then
    local i = 1
    for k, n in ipairs(DRAW_PROFILES) do if n == d.prof then i = k end end
    d.prof = DRAW_PROFILES[(i - 1 + dir) % #DRAW_PROFILES + 1]
    W.draw_prof = d.prof
    hint("profile: " .. d.prof, 1.5)
  elseif d.kind == "panel" then
    d.thick = (d.thick >= 0.08) and 0.04 or 0.10
    W.draw_thick = d.thick
    hint(d.thick >= 0.08 and "deck 10 cm" or "sheet 4 cm", 1.5)
  end
end

-- The member / panel / brace the tool would make from p0 to p1.
local function draw_shape(A, d, p1, get)
  if d.kind == "member" then return A.memberBetween(d.p0, p1, d.prof, { get = get, exactEnd = p1.host ~= nil }) end
  if d.kind == "panel" then return A.panelOn(d.p0, p1, d.p0.n, d.thick) end
  return A.braceBetween(d.p0, p1)
end

-- Make it: one history step with its end links (WP3's endLink: splice,
-- corner, tee or brace, with the joint plates) and any welds.
local function draw_place(A, d, m)
  local u = next_uid
  local G = graph()
  local def = def_of(d.id, m.size)
  local rec = { uid = u, id = d.id, def = def, x = m.x, y = m.y, z = m.z, B = m.B, size = m.size }
  local around = {}
  local ends = {}
  if d.kind == "panel" then
    if d.p0.host and parts[d.p0.host] then ends[#ends + 1] = { "a", d.p0.host } end
  else
    for _, w in ipairs({ "a", "b" }) do
      local e = m.ends and m.ends[w]
      if e and e.host and parts[e.host] then ends[#ends + 1] = { w, e.host } end
    end
  end
  for _, e in ipairs(ends) do around[e[2]] = true end
  local t = tx_begin("draw " .. (def.label or d.id), around)
  tx_touch(t, u)
  local links, joints = {}, {}
  for _, e in ipairs(ends) do
    local host = arec(e[2])
    local l, j
    if d.kind == "panel" then
      l = { a = u, b = e[2], k = "surface" }
    else
      l, j = A.endLink(rec, e[1], host)
    end
    -- ours run host (a) → part (b), the placed part's first end is its primary
    local link = { a = e[2], b = u, k = l.k, pa = vcopy(l.pb), pb = vcopy(l.pa), n = vcopy(l.n),
                   sa = "surface", sb = (d.kind ~= "panel") and e[1] or "surface", prim = (#links == 0) or nil }
    if j then
      joints[#joints + 1] = encodeJoint(j)
      link.s = (def.strength or 0) * (A.JOINT_BONUS or 1.25)
    end
    links[#links + 1] = link
  end
  local yaw, pitch, roll = basisEuler(m.B)
  local p = add_part(u, { id = d.id, x = m.x, y = m.y, z = m.z, yaw = yaw, pitch = pitch, roll = roll,
                          size = tcopy(m.size), joints = (#joints > 0) and joints or nil })
  if p and G then
    for _, l in ipairs(links) do G:add(l) end
    if links[1] then p.parent, p.att = links[1].a, "surface" end
    autoWeld(u, t)
  end
  struct_changed()
  tx_commit(t)
  ui("place", 0.9)
  return u
end

function drawToolTick(clicked, cam_busy)
  local d = W.drawing
  local A = attach_v2()
  if not A then W.drawing = nil return end
  local mx, my = input.mouse()
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my)
  local hu, ht, hP, hn = ray_craft(ox, oy, oz, dx, dy, dz)
  local cands = snap_candidates({})
  local q = attachQuery({ def = REG[d.id], id = d.id, off = IDENT }, nil, cands, hu and { hu, ht, hP, hn } or nil)
  local pt = A.pointOn(q)
  -- ALT: the end goes IN THE AIR, on the upright plane through the start that
  -- faces the camera (a post, a mast), its height on the grid
  if d.p0 and input.key("alt") and d.kind ~= "panel" then
    local nx, nz = ox - d.p0.x, oz - d.p0.z
    local l = math.sqrt(nx * nx + nz * nz)
    if l > 1e-6 then
      nx, nz = nx / l, nz / l
      local den = dx * nx + dz * nz
      if math.abs(den) > 1e-6 then
        local tt = ((d.p0.x - ox) * nx + (d.p0.z - oz) * nz) / den
        if tt > 0 then
          local g = (W.grid > 0) and W.grid or 0
          local px, py, pz = ox + dx * tt, oy + dy * tt, oz + dz * tt
          if g > 0 then py = d.p0.y + math.floor((py - d.p0.y) / g + 0.5) * g end
          pt = { x = px, y = py, z = pz, n = { x = 0, y = 1, z = 0 }, kind = "air" }
        end
      end
    end
  end
  if pt then
    local n = pt.n or { x = 0, y = 1, z = 0 }
    draw.ring(pt.x, pt.y, pt.z, n.x, n.y, n.z, 0.12, 1.0, 0.62, 0.22, 1.0)
  end
  if hu and parts[hu] then outline(parts[hu], 0.8, 0.88, 1.0, 0.45) end
  local m
  if d.p0 and pt then
    m = draw_shape(A, d, pt, q.get)
    local p0n = d.p0.n or { x = 0, y = 1, z = 0 }
    draw.ring(d.p0.x, d.p0.y, d.p0.z, p0n.x, p0n.y, p0n.z, 0.12, 1.0, 0.62, 0.22, 1.0)
    if m then
      local sh = A.shapeOf(REG[d.id], m.size)
      drawObb(m.x, m.y, m.z, m.B, sh.hx, sh.hy, sh.hz, 1.0, 0.62, 0.22, 0.9)
      local tag = m.size.len and string.format("%.2f m", m.size.len)
        or string.format("%.2f × %.2f m", m.size.w or 0, m.size.d or 0)
      stext(mx + 16, my + 8, tag, 15, 0.55, 1.0, 0.6, 1.0)
    end
  end
  if clicked and not cam_busy then
    if not pt then hint("aim at a part or the floor", 1.5)
    elseif not d.p0 then d.p0 = pt
    elseif m then
      draw_place(A, d, m)
      -- SHIFT chains the next member from this one's far end
      if input.key("shift") and d.kind == "member" and m.ends and m.ends.b then
        local e = m.ends.b
        d.p0 = { x = e.x, y = e.y, z = e.z, n = pt.n, host = next_uid - 1, region = "b" }
      else
        d.p0 = nil
      end
    end
  end
end

-- ── a gizmo drag owns the mouse until release ───────────────────────────────
function gizmoDragTick(lmb)
  local gd = gizmo_drag
  local p = parts[gd.uid]
  if not lmb or not p then
    gizmo_drag = nil
    click_cool = 0.12
    if W.hist then W.hist:seal() end
    if p and p.parent and parts[p.parent] and not partsTouch(p, parts[p.parent], 0.02) then
      placard("not touching what it is attached to — move it back, or LAUNCH refuses", "warn")
    end
    return
  end
  local mx, my = input.mouse()
  local dmx, dmy = mx - gd.lmx, my - gd.lmy
  gd.lmx, gd.lmy = mx, my
  draw_gizmo(p, tool)
  outline(p, 0.55, 0.85, 1.0, 1.0)
  if gd.kind == "move" then
    local a = gd.k
    local sx0, sy0 = screen_of(p.x, p.y, p.z)
    local sx1, sy1 = screen_of(p.x + a.x, p.y + a.y, p.z + a.z)
    local vx2, vy2 = sx1 - sx0, sy1 - sy0
    local l2 = vx2 * vx2 + vy2 * vy2
    if l2 > 1e-3 and (dmx ~= 0 or dmy ~= 0) then
      gd.acc = (gd.acc or 0) + (dmx * vx2 + dmy * vy2) / l2
    end
    local step = input.key("shift") and 0.01 or W.grid
    local target = (step > 0) and math.floor((gd.acc or 0) / step + 0.5) * step or (gd.acc or 0)
    local delta = target - (gd.applied or 0)
    if math.abs(delta) > 1e-9 then
      gd.applied = target
      moveMulti(a.x * delta, a.y * delta, a.z * delta)
    end
    stext(mx + 16, my + 8, string.format("%+.3f m", target), 15, 1.0, 0.75, 0.3, 1.0)
    local h = p.parent and parts[p.parent]
    if h then
      local ok = partsTouch(p, h, 0.02)
      draw.line(p.x, p.y, p.z, h.x, h.y, h.z, ok and 0.3 or 1.0, ok and 1.0 or 0.25, ok and 0.4 or 0.2, 1.0)
      if not ok then stext(mx + 16, my + 28, "not touching what it is attached to", 14, 1.0, 0.3, 0.25, 1.0) end
    end
    hint("OFFSET — drag the arrow  ·  snaps " .. fmt_grid(W.grid) .. ", SHIFT 1 cm  ·  release to set", 1.0)
  else
    local total = gizmoTurn(p, gd, mx, my, dmx, dmy)
    hint(string.format("ROTATE %+.0f°  ·  snaps %s, SHIFT turns free  ·  release to set",
      math.deg(total), (ROT_SNAP and ROT_SNAP > 0) and string.format("%d°", math.floor(math.deg(ROT_SNAP) + 0.5)) or "off"), 1.0)
  end
end

-- ── idle: hover, select (click / SHIFT / CTRL / box / double-click), drag ──
local function draw_selection()
  local n = 0
  local sel = W.sel_order
  for i = #sel, 1, -1 do
    local p = parts[sel[i]]
    if p then
      n = n + 1
      if n > 200 then break end
      outline(p, 1.0, 0.62, 0.22, (sel[i] == selected_uid) and 1.0 or 0.75)
    end
  end
  -- dependents, faint (they come along with a drag)
  local c = W.cache
  if c.sdep_v ~= W.sv or c.sdep_s ~= W.sel_v then
    local set = {}
    for _, u in ipairs(sel) do set[u] = true end
    c.sdep = (#sel > 0) and deps_of(set) or {}
    c.sdep_v, c.sdep_s = W.sv, W.sel_v
  end
  for u in pairs(c.sdep) do
    if n > 200 then break end
    n = n + 1
    if parts[u] then outline(parts[u], 1.0, 0.62, 0.22, 0.25) end
  end
  -- loose islands (orange): one merged box per island, cached per change
  if c.lbox_v ~= craftVersion then
    local boxes = {}
    local comps = islands()
    for _, k in ipairs(comps or {}) do
      if not k.root and #boxes < 64 then
        local a, b2, cc, d, e, f = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
        for _, u in ipairs(k) do
          local p = parts[u]
          if p and not p.carried then
            local ex, ey, ez = part_box(p)
            a, b2, cc = math.min(a, p.x - ex), math.min(b2, p.y - ey), math.min(cc, p.z - ez)
            d, e, f = math.max(d, p.x + ex), math.max(e, p.y + ey), math.max(f, p.z + ez)
          end
        end
        if a < d then boxes[#boxes + 1] = { (a + d) * 0.5, (b2 + e) * 0.5, (cc + f) * 0.5, (d - a) * 0.5 + 0.04,
                                            (e - b2) * 0.5 + 0.04, (f - cc) * 0.5 + 0.04 } end
      end
    end
    c.lbox, c.lbox_v = boxes, craftVersion
  end
  for _, b in ipairs(c.lbox) do
    drawObb(b[1], b[2], b[3], IDENT, b[4], b[5], b[6], 1.0, 0.45, 0.1, 0.55)
  end
  -- parts sunk into another (badOverlaps): a thin red box on the one that
  -- sinks in, a dozen at most
  local ov = badOverlaps and badOverlaps() or {}
  for k = 1, math.min(#ov, 12) do
    local p = parts[ov[k].sunk]
    if p and not p.carried then outline(p, 1.0, 0.22, 0.18, 0.8) end
  end
  local r = craft_root()
  if r and parts[r] and partCount > 1 then
    local p = parts[r]
    draw.ring(p.x, p.y, p.z, 0, 1, 0, 0.25 + p.def.rx, 0.95, 0.85, 0.3, tool == "root" and 1.0 or 0.35)
  end
end

local function click_at(pr)
  local u = pr.uid
  if tool == "root" and u then cmd("root", { uid = u }); return end
  if u then
    local lc = W.last_click
    if lc and lc.uid == u and time - lc.t <= 0.3 and not pr.shift and not pr.ctrl and not lc.dbl then
      -- a second double-click on the same part (within 1.5 s) widens to the craft
      local ld = W.last_dbl
      local scope = (ld and ld.uid == u and time - ld.t <= 1.5 and ld.scope == "assembly") and "craft" or "assembly"
      selectConnected(u, scope)
      W.last_click = { uid = u, t = time, dbl = true }
      W.last_dbl = { uid = u, t = time, scope = scope }
      hint(scope == "assembly" and "selected the assembly (up to its decouplers) — double-click again for the craft"
        or "selected the whole craft", 2.0)
      return
    end
    sel_apply({ u }, pr.ctrl and "toggle" or (pr.shift and "add" or "set"))
    W.last_click = { uid = u, t = time }
    return
  end
  if pr.keep then return end -- a near miss on the gizmo keeps the selection
  if not pr.shift and not pr.ctrl then sel_only(nil) end
end

local function finish_box(b, mx, my)
  local x0, x1 = math.min(b.x0, mx), math.max(b.x0, mx)
  local y0, y1 = math.min(b.y0, my), math.max(b.y0, my)
  local list = {}
  for u, p in pairs(parts) do
    if not p.hidden then
      local sx, sy, on = screen_of(p.x, p.y, p.z)
      if on and sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then list[#list + 1] = u end
    end
  end
  table.sort(list)
  sel_apply(list, b.add and "add" or "set")
  if #list > 0 then hint(string.format("%d part%s selected", #W.sel_order, #W.sel_order == 1 and "" or "s"), 1.5) end
end

function startDragMove(uid, only)
  local reselect = {}
  for i, u in ipairs(W.sel_order) do reselect[i] = u end
  pickup(uid, { set = W.sel, only = only })
  if ghost then
    ghost.drag = true
    ghost.reselect = reselect
    if only then hint("moving only the selection — what hung on it stays, loose (orange)", 2.5) end
  end
end

-- ── WHAT IS IN YOUR HAND (playtest 2026-10-26) ──────────────────────────────
-- "right now it's hard to tell — I have to drag my mouse back in view to see
-- if the part is in my hand or not." A part in hand now says so four ways
-- without the cursor going near the 3D view: the pickup click, its catalogue
-- card latched "IN HAND" (catalog_panel reads heldId), a chip riding the
-- cursor with the part's name, and the hint line ("HOLDING …"). A right-
-- click TAP drops it (as ESC does); an RMB drag still orbits.
HOLD = { seq = nil, cam = nil, t = 0 }
function heldId()
  if not ghost or ghost.paste then return nil end
  return ghost.id
end
function heldLabel()
  if not ghost then return nil end
  local lbl = (ghost.def and ghost.def.label) or ghost.id or "part"
  if ghost.paste then return "the clipboard" end
  if ghost.carried and #ghost.carried > 1 then
    return string.format("%s + %d attached", lbl, #ghost.carried - 1)
  end
  return lbl
end
function holdHint()
  local lbl = heldLabel()
  if not lbl then return HINT_IDLE end
  return "HOLDING  " .. lbl .. "  —  click a node or surface to place (SHIFT keeps a copy)  ·  ESC / right-click drops it"
    .. "  ·  W/S A/D Q/E rotate · R spin · X symmetry"
end
-- Put back what is in hand (the catalogue swaps a fresh part this way).
function dropHeld()
  if not ghost then return false end
  cancel_ghost()
  return true
end
function holdStarted()
  HOLD.t = time or 0
  local cam = HOLD.cam
  if not cam or cam.valid == false then cam = other("builder_camera"); HOLD.cam = cam end
  HOLD.seq = cam and cam.rmbClick and cam.rmbClick.seq or nil
end
-- Every frame while something is in hand: the right-click tap, and the chip.
function holdTick()
  if not ghost then return end
  local cam = HOLD.cam
  if not cam or cam.valid == false then cam = other("builder_camera"); HOLD.cam = cam end
  local c = cam and cam.rmbClick
  if c and c.seq then
    if HOLD.seq == nil then HOLD.seq = c.seq
    elseif c.seq ~= HOLD.seq then
      HOLD.seq = c.seq
      local what = heldLabel()
      cancel_ghost()
      ui("scrap", 0.5)
      hint("dropped " .. tostring(what or "the part") .. (tool == "lift" and " — it went back where it was" or ""), 2.0)
      return
    end
  end
  holdChip()
end
-- The chip: a dark tag with an orange rim just below-right of the cursor,
-- "IN HAND  FT-M Tank". Screen drawing, so it shows over the catalogue too.
function holdChip()
  if not (draw and draw.text and input and input.mouse) or ghost.drag then return end
  local lbl = heldLabel()
  if not lbl then return end
  local mx, my = input.mouse()
  local k = screen_k()
  local fs = 15 * k
  local txt = "IN HAND  " .. lbl
  local w = (#txt * 0.5 * fs) + 18 * k
  local h = fs + 12 * k
  local x, y = mx + 20 * k, my + 22 * k
  local sw, shh = 1920, 1080
  if camera and camera.screenSize then sw, shh = camera.screenSize() end
  if x + w > (sw or 1920) - 4 then x = mx - 20 * k - w end
  if y + h > (shh or 1080) - 4 then y = my - 22 * k - h end
  -- a short pulse when it arrives, so the eye catches it
  local age = (time or 0) - (HOLD.t or 0)
  local a = age < 0.35 and (0.75 + 0.25 * math.sin(age * 40)) or 1.0
  if draw.rect then draw.rect(x, y, w, h, 0.08, 0.075, 0.065, 0.88 * a, 4 * k) end
  if draw.rectOutline then draw.rectOutline(x, y, w, h, 1.0, 0.62, 0.22, 0.95 * a, 1.5 * k) end
  draw.text(x + 9 * k, y + 6 * k, txt, fs, 1.0, 0.80, 0.55, a)
end

-- THE MOVE TOOL (5, "lift"; playtest: "a tool for picking up parts that have
-- been placed and moving them around easily"). Click a placed part: it and
-- everything that hangs on it come up into your hand (a symmetry member
-- brings its ring); click again to put it down — the ordinary attach rules,
-- nodes, surfaces and the floor, exactly as a new part. A press-and-drag
-- moves it too (release puts it down). ESC or a right-click tap puts it back
-- where it was (the lift's history step is undone, links and all).
LIFT_HINT = " — click a part to pick it up (with what hangs on it), click to put it down · drag works too · ESC puts it back"
function liftClick(pr)
  if not (pr and pr.uid and parts[pr.uid]) then return end
  if not W.sel[pr.uid] then sel_apply({ pr.uid }, "set") end
  startDragMove(pr.uid, pr.alt)
  if ghost then ghost.drag = nil end   -- in hand: the next click puts it down
end
function liftHoverTick(u)
  local p = u and parts[u]
  if not p then return end
  outline(p, 1.0, 0.75, 0.3, 0.9)
  if draw and draw.text and input and input.mouse then
    local mx, my = input.mouse()
    local k = screen_k()
    draw.text(mx + 18 * k, my + 18 * k, "click to pick up " .. ((p.def and p.def.label) or p.id), 13 * k, 1.0, 0.80, 0.55, 0.9)
  end
end

function idleTick(dt, clicked, lmb, released, cam_busy)
  hover_uid = (not cam_busy and not W.box) and part_under_cursor(70) or nil
  local sel = selected_uid and parts[selected_uid]
  if selected_uid and not sel then sel_only(nil) end
  draw_selection()
  local giz_len, giz_rad
  if sel and (tool == "offset" or tool == "rotate") then
    giz_len, giz_rad = draw_gizmo(sel, tool)
    local h = sel.parent and parts[sel.parent]
    if h and tool == "offset" and not partsTouch(sel, h, 0.02) then
      draw.line(sel.x, sel.y, sel.z, h.x, h.y, h.z, 1.0, 0.25, 0.2, 1.0)
    end
  end
  if hover_uid and not W.sel[hover_uid] then
    outline(parts[hover_uid], 0.8, 0.88, 1.0, 0.45)
  end
  if tool == "lift" then liftHoverTick(hover_uid) end
  local mx, my = input.mouse()
  if clicked and not cam_busy then
    if giz_len then
      local kind, ai, gpt = gizmo_hit(sel, tool, giz_len, giz_rad)
      if kind then
        local ka = gizmoAxes(sel, tool)[ai]
        gizmo_drag = { uid = selected_uid, kind = kind, axis = ai, lmx = mx, lmy = my,
                       k = { x = ka.x, y = ka.y, z = ka.z }, P = gpt, rad = giz_rad }
        if W.hist then W.hist:seal() end
        return
      end
    end
    -- INSIDE THE GIZMO'S FOOTPRINT the press is the gizmo's (playtest
    -- 2026-10-27: a press just off a ring or an arrow, over a part, became a
    -- pick-up the moment the mouse moved 6 px). A near miss takes the nearest
    -- handle within GIZ_NEAR_PX; further off, a click still selects the part
    -- under it, but a drag never lifts one (`giz`) — the Move tool (5) does.
    -- (…and just OUTSIDE it: a press 25–35 px beyond a ring's rim, over the
    -- next part up the stack, lifted that part and carried it off — verified
    -- 2026-10-27, verifyprobe vvab. Within GIZ_NEAR_PX of the footprint the
    -- nearest handle is asked for too.)
    local keep, giz = false, false
    if sel and giz_len then
      local gx, gy, gr = gizmo_footprint_px(sel, tool, giz_len, giz_rad)
      local d2 = gx and (mx - gx) ^ 2 + (my - gy) ^ 2
      giz = gx ~= nil and d2 <= gr * gr
      if gx ~= nil and d2 <= (gr + GIZ_NEAR_PX) ^ 2 then
        local kind, ai, gpt = gizmo_hit(sel, tool, giz_len, giz_rad, GIZ_NEAR_PX)
        if kind then
          local ka = gizmoAxes(sel, tool)[ai]
          gizmo_drag = { uid = selected_uid, kind = kind, axis = ai, lmx = mx, lmy = my,
                         k = { x = ka.x, y = ka.y, z = ka.z }, P = gpt, rad = giz_rad }
          if W.hist then W.hist:seal() end
          return
        end
      end
      keep = giz and not hover_uid
    end
    W.press = { x = mx, y = my, uid = hover_uid, shift = input.key("shift"), ctrl = input.key("ctrl"),
                alt = input.key("alt"), t = time, keep = keep, giz = giz }
  end
  local pr = W.press
  if pr then
    if lmb then
      if not pr.drag and (mx - pr.x) ^ 2 + (my - pr.y) ^ 2 > 36 then
        pr.drag = true
        if pr.giz then
          -- (a drag that began on the gizmo moves nothing: not a part, not a box)
        elseif pr.uid and tool ~= "root" and not cam_busy then
          if not W.sel[pr.uid] then sel_apply({ pr.uid }, (pr.shift or pr.ctrl) and "add" or "set") end
          W.press = nil
          startDragMove(pr.uid, pr.alt)
          return
        elseif not pr.uid and not pr.keep then
          W.box = { x0 = pr.x, y0 = pr.y, add = pr.shift }
        end
      end
      if W.box then
        local b = W.box
        local x0, y0 = math.min(b.x0, mx), math.min(b.y0, my)
        srect(x0, y0, math.abs(mx - b.x0), math.abs(my - b.y0), 1.0, 0.62, 0.22, 0.10, 0)
        sframe(x0, y0, math.abs(mx - b.x0), math.abs(my - b.y0), 1.0, 0.62, 0.22, 0.9, 1.5)
      end
    else
      if W.box then finish_box(W.box, mx, my)
      elseif not pr.drag and tool == "lift" and pr.uid and parts[pr.uid] then liftClick(pr)
      elseif not pr.drag then click_at(pr) end
      W.press, W.box = nil, nil
    end
  end
  -- arrows nudge the selection (one step a press; SHIFT 1 cm)
  if sel then
    local step = input.key("shift") and 0.01 or ((W.grid > 0) and W.grid or params.nudge)
    local ddx, ddy, ddz = 0, 0, 0
    if input.pressed("up") then ddy = step end
    if input.pressed("down") then ddy = -step end
    local hh = (input.pressed("right") and 1 or 0) - (input.pressed("left") and 1 or 0)
    if hh ~= 0 then
      local _, _, _, d1x, _, d1z = camera.screenToRay(mx, my)
      local _, _, _, d2x, _, d2z = camera.screenToRay(mx + 40, my)
      local rxx, rzz = d2x - d1x, d2z - d1z
      if input.key("alt") then rxx, rzz = -rzz, rxx end
      if math.abs(rxx) >= math.abs(rzz) then ddx = (rxx >= 0 and 1 or -1) * hh * step
      else ddz = (rzz >= 0 and 1 or -1) * hh * step end
    end
    if ddx ~= 0 or ddy ~= 0 or ddz ~= 0 then moveMulti(ddx, ddy, ddz) end
    -- DEL scraps the selection and what hangs on it; ALT+DEL only the selection
    if input.pressed("delete") or input.pressed("del") then
      local n = cmd("delete", { uids = selection(), only = input.key("alt") })
      ui("scrap", 0.8)
      hint("scrapped " .. tostring(n or 0) .. " part(s) — CTRL+Z to undo", 2.5)
    end
  end
end

function update(node, dt)
  -- in the world: this frame's frame-space shapes wait for lateUpdate (F.flush)
  if W.F and W.F.beginQueue then W.F.beginQueue() end
  saveJobTick()
  W.visits = 0
  frameTick()
  statsTick()
  if W.overlay >= 1 and not aeroDrawsOverlays() then draw_engineering() end
  if not toolbarOwnsModes() then drawModes() end
  roundTwoTick()
  fit_header()
  -- One shared click edge for the whole frame.
  local lmb = input.button(0)
  local clicked = lmb and not lmb_prev and click_cool <= 0
  local released = (not lmb) and lmb_prev
  lmb_prev = lmb
  if click_cool > 0 then click_cool = click_cool - dt end
  if hint_t > 0 then
    hint_t = hint_t - dt
    if hint_t <= 0 and not ghost then
      W.hint_text = HINT_IDLE
      if hint_node then hint_node.text = HINT_IDLE end
    end
  end
  local cam_busy = input.button(1) -- RMB = the camera's; never build through it
  -- Shaping a fairing (or its SHAPE button) takes the frame's input first.
  if shapeTick(clicked, cam_busy) then return end
  if keysTick(cam_busy) then return end
  -- the part in hand says so even over a panel (the chip, the RMB-tap drop)
  if ghost then holdTick() end
  -- STAGE and GROUPS panels, then any registered panel, own the mouse first.
  if handle_staging(clicked, lmb, false) then return end
  if groupsPanelTick(clicked) then return end
  if panelsOwnMouse() then W.press, W.box = nil, nil; return end
  if W.drawing and not ghost then drawToolTick(clicked, cam_busy) return end
  rotKeysTick(cam_busy or panelsOwnKeys())
  if ghost then
    if ghost.node or ghost.carried then ghostTick(dt, clicked, released, cam_busy)
    else ghostTick(dt, false, false, cam_busy) end
    return
  end
  if gizmo_drag then gizmoDragTick(lmb) return end
  idleTick(dt, clicked, lmb, released, cam_busy)
end

-- The HUD buttons call these too.
function doSave() save_blueprint() end

-- LEAVE WITHOUT BUYING ANYTHING.
--
-- There was no way out of here. The Vehicle Assembly is a whole scene, and the
-- only two doors were SAVE (which stays) and LAUNCH (which charges you for a
-- hull and puts it on the pad). Walk into the hangar to look at the parts, or
-- open it by accident on the way past, and the game's answer was: buy a rocket.
--
-- The blueprint is kept, because leaving is not the same as discarding — you
-- come back to the craft you were drawing.
-- In the real VAB (build_host, WP6) the builder is an overlay on the live
-- world: leaving and launching hand back to it instead of loading a scene.
function buildHost()
  local bh = findScript and findScript("build_host") or nil
  if bh and bh.valid ~= false and bh.inWorld and bh.inWorld() then return bh end
  return nil
end

function doLeave()
  save_blueprint()
  save.set("shipyard.launch", false)
  save.set("shipyard.pilot", 0)
  save.flush()
  local bh = buildHost()
  if bh then bh.leave() return end
  scene.load("system")
end
-- A launch with warnings is TWO presses: the first says what is wrong and
-- arms; the second, within LAUNCH_CONFIRM seconds, goes. Nothing is charged
-- until it actually goes.
LAUNCH_CONFIRM = 6.0
launchArmedAt = nil
-- The blueprint LAUNCH stored in `shipyard.blueprint`, for the rollout to
-- start from without reading 1,000 parts back out of the save (build_host
-- hands it to vessel_spawner.launchNow). nil once anything else is saved.
function launchBlueprint() return W.launch_bp end
function doLaunch()
  W.launch_bp = nil
  local chk = launchCheck()
  if chk.block then
    hint("can't launch — " .. chk.block, 4.0)
    ui("tool", 0.7)
    return false
  end
  if #chk.warn > 0 and not (launchArmedAt and time - launchArmedAt <= LAUNCH_CONFIRM) then
    launchArmedAt = time
    hint("⚠ " .. table.concat(chk.warn, "  ·  ") .. "  —  press LAUNCH again to fly it anyway", LAUNCH_CONFIRM)
    ui("tool", 0.7)
    return false
  end
  launchArmedAt = nil
  -- THE SITE MUST BE CLEAR. A craft left on the pad (or the runway), its
  -- debris or the crew: the launch is refused here, before the hull is
  -- charged, with what is in the way and what to do about it
  -- (vessel_spawner.launchBlockedWhy; it checks again as it rolls out).
  -- (The blueprint is made and stored ONCE here, and the store written once
  -- at the end: LAUNCH made it twice and flushed three times, each a pass
  -- over every part — ~180 ms at 1,000 parts, on the click.)
  local saved = false
  local vs = findScript and findScript("vessel_spawner") or nil
  if vs and vs.valid ~= false and vs.launchBlockedWhy then
    -- (the check sizes the footprint from the craft on the stand: the
    -- blueprint just stored is handed over, not read back out of the save)
    W.launch_bp = save_blueprint(true)
    saved = true
    local why = vs.launchBlockedWhy(launchSite(), W.launch_bp)
    if why then
      -- a short placard so it is seen, the whole sentence on the hint bar
      local kind = launchSite() == "runway" and "RUNWAY BLOCKED" or "PAD BLOCKED"
      if placard then placard(kind, "error", 4.0) end
      hint("can't launch — " .. why, 8.0)
      ui("tool", 0.7)
      return false
    end
  end
  -- The hull is BOUGHT at rollout. Crash it and that money is gone; bring it
  -- home and recover it and most of it comes back. That's the whole loop, and
  -- it only means anything if the pad refuses a build you can't pay for.
  local co = company_ref()
  local cost = build_cost()
  if co and co.afford and not co.afford(cost) then
    hint(string.format("can't afford this build — it costs %s and the budget is %s. Sell ore at the depot or fly a contract.",
      co.money(cost), co.money(co.balance())), 4.0)
    return
  end
  if co and co.spend then co.spend(cost, "hull rollout (" .. partCount .. " parts)") end
  save.set("shipyard.spent", cost)
  if not saved then W.launch_bp = save_blueprint(true) end
  ui("launch", 1.0)
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", launchSite())
  save.set("shipyard.pilot", 1) -- you launch IN the pod, not beside it
  save.flush()
  local bh = buildHost()
  if bh then bh.rollout(launchSite()) return end
  scene.load("system")
end

-- ═══ THE PUBLIC BUILDER API (documented at the top of this file) ═══════════
-- Defined last so every local above is in scope. Globals, never upvalues of
-- `update`.
local API = { panels = API_PANELS, stats = nil, stats_cv = -1, stats_t = -1e9 }

function api_not_yet(what)
  local msg = "builder API: '" .. tostring(what) .. "' not yet"
  if log then log(msg) elseif print then print(msg) end
  return false
end

local function uid_list(a)
  if type(a) == "number" then return { a } end
  if type(a) ~= "table" then return {} end
  local src = a.uids or (a.uid and { a.uid }) or a
  local out = {}
  for _, u in ipairs(src) do if parts[u] then out[#out + 1] = u end end
  return out
end
local function list_set(list)
  local s2 = {}
  for _, u in ipairs(list) do s2[u] = true end
  return s2
end
local function set_list(set)
  local out = {}
  for u in pairs(set) do out[#out + 1] = u end
  table.sort(out)
  return out
end

-- ── queries ────────────────────────────────────────────────────────────────
function partRec(uid)
  local p = parts[uid]
  if not p then return nil end
  local links = {}
  local G = graph()
  if G then for _, l in ipairs(G:incident(uid)) do links[#links + 1] = tcopy(l) end end
  return { uid = uid, id = p.id, def = p.def, x = p.x, y = p.y, z = p.z,
           yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0,
           B = basisOf(p.yaw, p.pitch, p.roll), size = tcopy(p.size), sym = p.sym, mir = p.mir,
           parent = p.parent, att = p.att,
           an = p.an and { x = p.an.x, y = p.an.y, z = p.an.z } or nil,
           wcfg = wcfgs[uid] and copy_wcfg(wcfgs[uid]) or nil, links = links,
           hidden = p.hidden == true, root = craft_root() == uid, loose = loose_set()[uid] == true,
           landed = p.node ~= nil }
end

function selection()
  local out = {}
  for _, u in ipairs(W.sel_order) do if parts[u] then out[#out + 1] = u end end
  return out
end
function selectionPrimary() return (selected_uid and parts[selected_uid]) and selected_uid or nil end
function select(uids, mode)
  if type(uids) ~= "table" then uids = { uids } end
  sel_apply(uids, mode or "set")
  return selection()
end
function selectAll() sel_apply(set_list(alive_set()), "set"); return selection() end
function selectInvert()
  local list = {}
  for u in pairs(parts) do if not W.sel[u] then list[#list + 1] = u end end
  table.sort(list)
  sel_apply(list, "set")
  return selection()
end

function hovered()
  return (hover_uid and parts[hover_uid]) and hover_uid or nil
end

function held()
  if not ghost then return nil end
  if ghost.carried then
    local out = { ghost.id }
    for _, m in ipairs(ghost.carried) do
      if m.uid ~= ghost.from_uid and parts[m.uid] then out[#out + 1] = parts[m.uid].id end
    end
    return out
  end
  return { ghost.id }
end
function holding()
  if not ghost then return nil end
  if ghost.paste then return "paste" end
  return ghost.carried and "carry" or "part"
end

-- Cached per craftVersion; while a drag or a part in hand keeps changing the
-- craft it is recomputed at most twice a second.
function stats()
  if API.stats and API.stats_cv == craftVersion then return API.stats end
  if API.stats and (ghost or gizmo_drag) and time - API.stats_t < 0.5 then return API.stats end
  local n, mass, dry, cost, thrust = 0, 0.0, 0.0, 0, 0.0
  local wx, wy, wz, dx, dy, dz = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
  local th, tx, ty, tz = 0.0, 0.0, 0.0, 0.0
  for _, p in pairs(parts) do
    local d = p.def
    local wet = d.mass + (d.fuel or 0) * FUEL_T_PER_UNIT
    n = n + 1
    mass, dry, cost = mass + wet, dry + d.mass, cost + d.cost
    wx, wy, wz = wx + p.x * wet, wy + p.y * wet, wz + p.z * wet
    dx, dy, dz = dx + p.x * d.mass, dy + p.y * d.mass, dz + p.z * d.mass
    local t = d.thrust or 0
    if t > 0 then
      th = th + t
      tx, ty, tz = tx + p.x * t, ty + p.y * t, tz + p.z * t
      thrust = thrust + (liveDef(d).thrust or t)
    end
  end
  local st = (n > 0) and stageStats() or nil
  local comps, loose = islands()
  local nl = 0
  for _ in pairs(loose or {}) do nl = nl + 1 end
  local out = {
    parts = n, mass = mass, dry = dry, cost = cost, thrust = thrust,
    dv = st and st.dv or 0, twr = st and st.twr or 0, hop = st and st.hop or 0,
    dv_sl = st and st.dv_sl or 0, twr_sl = st and st.twr_sl or 0, nozzles = st and st.nozzles or false,
    stages = st and st.stages or {},
    com = (mass > 0) and { x = wx / mass, y = wy / mass, z = wz / mass } or nil,
    comDry = (dry > 0) and { x = dx / dry, y = dy / dry, z = dz / dry } or nil,
    cot = (th > 0) and { x = tx / th, y = ty / th, z = tz / th } or nil,
    launch = launchCheck(), version = craftVersion, islands = #(comps or {}), loose = nl,
  }
  API.stats, API.stats_cv, API.stats_t = out, craftVersion, time
  return out
end

-- THE FRAME ADAPTER (builder_space.newFrame): the identity in standalone
-- builder.ron; the BuildFrame's own frame when the scene has one.
-- The catalogue's spinning preview (catalog_panel): the prefab a part's
-- stand-in is spawned from, and the node the builder's world hangs on (the
-- BuildFrame in the VAB, nil = the scene root in standalone builder.ron).
function previewPrefab(id)
  local def = REG[id]
  return def and def.prefab and stand_prefab(def.prefab) or nil
end
function frameNodeOrNil()
  return (W.F and not W.F.identity and W.F.node) or nil
end

function frame()
  if W.F then return W.F end
  local L = lib("builder_space")
  if L then return L.newFrame(nil, RAW_CAMERA) end
  return nil
end

-- the graph
function root() return craft_root() end
function links(uid)
  local G, out = graph(), {}
  if G then for _, l in ipairs(G:incident(uid)) do out[#out + 1] = tcopy(l) end end
  return out
end
function dependents(uids)
  return set_list(deps_of(list_set(uid_list(uids))))
end
function components()
  local comps = islands()
  local out = {}
  for i, c in ipairs(comps or {}) do
    local l = {}
    for k, u in ipairs(c) do l[k] = u end
    l.root, l.anchor = c.root, c.anchor
    out[i] = l
  end
  return out
end
function separation(uid)
  local G, L = graph(), lib("builder_graph")
  if not (G and L) then return nil end
  local far = L.separation(G, alive_set(), uid, craft_root())
  return far and set_list(far) or nil
end
function hingeLocked(uid)
  local G, L = graph(), lib("builder_graph")
  return (G and L and parts[uid]) and L.hingeLocked(G, alive_set(), uid) or false
end

-- modes
function currentTool() return tool end
function gizmoSpace() return (ROT_FRAME == "part") and "local" or "world" end
function setGizmoSpace(sp) ROT_FRAME = (sp == "local") and "part" or "camera" end
function snapGrid() return W.grid end
function setSnapGrid(m) W.grid = math.max(0, tonumber(m) or 0) end
function snapAngle() return W.angle end
function setSnapAngle(r) W.angle = math.max(0, tonumber(r) or 0); ROT_SNAP = W.angle end
function setSym(n)
  n = tonumber(n) or 1
  for _, k in ipairs(SYM_STEPS) do if k == n then sym_n = n; sym_mirror = false end end
  refresh_stats()
  return sym_n
end
function setMirror(on, plane)
  if (on and true or false) ~= sym_mirror then toggleMirror() end
  if plane then W.mirror_plane = plane end
  return sym_mirror
end
function mirrorPlane() return W.mirror_plane or "host" end
function testMode() return W.test end
function setTestMode(on)
  W.test = on and true or false
  hint(W.test and "TEST — the craft's controls drive it here, kinematically (T again: off)" or "TEST off", 2.5)
  craftVersion = craftVersion + 1
  return W.test
end
function overlayMode() return W.overlay end
function setOverlayMode(n) W.overlay = math.max(0, math.min(3, math.floor(tonumber(n) or 0))); return W.overlay end
function attachRules() return attach_v2() and "wp3" or "legacy" end
function setAttachRules(r) W.attach = (r == "legacy") and "legacy" or "auto"; return attachRules() end
function frameMs()
  if perf and perf.enabled and perf.enabled() and perf.scriptMs then return perf.scriptMs("builder") end
  return nil
end
function perfCounters()
  return { visits = W.visits, hashParts = W.H and W.H:count() or 0, hashVisits = W.H and W.H.visits or 0,
           links = W.G and W.G:count() or 0, queued = #W.queue - W.qhead + 1 }
end
function hiddenUids()
  local out = {}
  for u, p in pairs(parts) do if p.hidden then out[#out + 1] = u end end
  table.sort(out)
  return out
end
function outliner() return tcopy(W.outliner or {}) end
function controlsData() return W.controls end

-- ── THE CONTROL MODE (scripts/craft_mode.lua) ──────────────────────────────
-- How the craft is driven in flight: Rover, Aircraft or Rocket, or Auto,
-- which reads the whole craft (wings that carry it fly it, wheels that carry
-- it drive it). The mode, not the wheel's part type, says what the wheels do,
-- so landing gear can be a rover's wheel and rover wheels a plane's gear.
-- W.ctrl is the player's choice (nil = Auto); it rides the blueprint as
-- `bp.ctrl` and on every command part's record (`ctrl`), so the fleet save,
-- a staging and a docking carry it. The rulebook is on the CraftModeLib node,
-- spawned here when the scene has none; until it answers, Auto says "Auto".
CTRL_MODES = { "auto", "rover", "aircraft", "rocket" }
function ctrlLib()
  local L = lib("craft_mode")
  if not L and not W.ctrl_asked and spawn then
    W.ctrl_asked = true
    pcall(spawn, "CraftModeLib", vec3(0, 0, 0))
  end
  -- (a just-spawned library is found a frame before its chunk has run)
  if L and type(L.resolve) ~= "function" then return nil end
  return L
end
-- { set (nil = Auto), auto, why, mode, label, labels, tips }, cached per craftVersion.
function ctrlMode()
  local c = W.cache
  if c.ctrl and c.ctrl_v == craftVersion and c.ctrl.ready then return c.ctrl end
  local L = ctrlLib()
  local out = { set = W.ctrl, ready = L ~= nil }
  if L then
    local recs = {}
    for uid, p in pairs(parts) do
      local d = p.def or {}
      recs[uid] = { uid = uid, af = d.af, wheel = d.wheel, mass = d.mass, fuel = d.fuel, fuel_t = FUEL_T_PER_UNIT,
                    kind = d.kind, seat = d.seat, front = d.front }
    end
    out.auto, out.why = L.autoOf(recs)
    out.mode = W.ctrl or out.auto
    out.label = L.describe(W.ctrl, out.auto)
    out.labels, out.tips = L.LABEL, L.TIP
  else
    out.mode = W.ctrl
    out.label = W.ctrl and (W.ctrl:sub(1, 1):upper() .. W.ctrl:sub(2)) or "Auto"
  end
  c.ctrl, c.ctrl_v = out, craftVersion
  return out
end
-- What controls.lua's bind / unbind / bindAxis edit beside W.controls: the
-- live action groups (bp.groups), the craft's records and symmetry rings (WP5).
function controlsCtx()
  return { groups = groups_own(), recs = craft_records(), E = elib(),
           members = function(uid)
             local p = parts[uid]
             if p and p.sym then return group_members(p.sym) end
             return { uid }
           end }
end
-- A part's display node, for TEST: builder_bind poses the moving side of each
-- joint kinematically and puts every node back when TEST ends (no data edits).
function partNode(uid)
  local p = parts[uid]
  return p and p.node or nil
end
function setControls(t)
  tx_run("controls", {}, function() W.controls = t end, "controls", true)
  craftVersion = craftVersion + 1
end
function reload() load_blueprint() end

-- history
function undoStep() undo() end
function redoStep() redo() end
function canUndo() return W.hist ~= nil and W.hist:canUndo() end
function canRedo() return W.hist ~= nil and W.hist:canRedo() end
function historyList()
  local H = history()
  return H and H:list() or { items = {}, index = 0 }
end
function historyJump(i)
  local H = history()
  return H and H:jump(i) or 0
end

-- ── fragments: the clipboard, sub-assemblies, merge ─────────────────────────
-- A FRAGMENT is a little v2 blueprint in the frame's own coordinates:
-- { v = 2, kind = "fragment", root, parts = { rec… }, links = { … }, controls }.
local function fragment(uids)
  local set = list_set(uids)
  local frag = { v = 2, kind = "fragment", root = uids[1], parts = {}, links = {}, controls = tcopy(W.controls) }
  for _, u in ipairs(uids) do
    local p = parts[u]
    if p then
      frag.parts[#frag.parts + 1] = {
        uid = u, id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll,
        parent = (p.parent and set[p.parent]) and p.parent or 0, att = p.att or "",
        sym = p.sym or 0, mir = p.mir or "", an = vcopy(p.an), size = tcopy(p.size), joints = tcopy(p.joints),
        wcfg = wcfgs[u] and copy_wcfg(wcfgs[u]) or nil, fshape = fshapes[u] and tcopy(fshapes[u]) or nil }
    end
  end
  local G, L = graph(), lib("builder_graph")
  if G and L then
    local seen = {}
    for _, u in ipairs(uids) do
      for _, l in ipairs(G:incident(u)) do
        if not seen[l.id] and set[l.a] and set[l.b] then
          seen[l.id] = true
          frag.links[#frag.links + 1] = L.packLink(l)
        end
      end
    end
  end
  return frag
end

-- Fragment from a saved craft (a whole blueprint: bottom at 0, centred).
local function fragment_of_bp(bp)
  local frag = { v = 2, kind = "fragment", parts = {}, links = tcopy(bp.links), controls = tcopy(bp.controls) }
  local first = nil
  for _, d in ipairs(bp.parts or {}) do
    if REG[d.id] then
      local an = (d.anx and d.any and d.anz) and { x = d.anx, y = d.any, z = d.anz } or nil
      frag.parts[#frag.parts + 1] = { uid = d.uid, id = d.id, x = d.x, y = d.y + params.floor_y, z = d.z,
        yaw = d.yaw, pitch = d.pitch, roll = d.roll, parent = d.parent or 0, att = d.att or "",
        sym = d.sym or 0, mir = d.mir or "", an = an, size = tcopy(d.size), wcfg = tcopy(d.wcfg),
        joints = tcopy(d.joints) }
      if not first or d.uid == bp.root then first = d.uid end
    end
  end
  frag.root = bp.root or first
  return frag
end

-- Spawn a fragment's parts with NEW uids (and new symmetry groups), offset by
-- (ox, oy, oz). Returns the new uids (root first) and old → new.
local function instantiate(frag, ox, oy, oz, t)
  ox, oy, oz = ox or 0, oy or 0, oz or 0
  local map, symmap, out = {}, {}, {}
  for _, r in ipairs(frag.parts or {}) do
    if REG[r.id] then map[r.uid] = next_uid; next_uid = next_uid + 1 end
  end
  for _, r in ipairs(frag.parts or {}) do
    local u = map[r.uid]
    if u then
      local sym = nil
      if (r.sym or 0) ~= 0 then
        if not symmap[r.sym] then next_sym = next_sym + 1; symmap[r.sym] = next_sym end
        sym = symmap[r.sym]
      end
      if t then tx_touch(t, u) end
      local p = add_part(u, { id = r.id, x = r.x + ox, y = r.y + oy, z = r.z + oz, yaw = r.yaw, pitch = r.pitch,
        roll = r.roll, sym = sym, mir = (r.mir ~= "" and r.mir) or nil, an = vcopy(r.an), size = tcopy(r.size),
        joints = tcopy(r.joints) })
      if p then
        local par = map[r.parent or 0]
        p.parent, p.att = par, (r.att ~= "" and r.att) or nil
        if type(r.wcfg) == "table" then wcfgs[u] = copy_wcfg(r.wcfg) end
        if type(r.fshape) == "table" then fshapes[u] = tcopy(r.fshape) end
      end
    end
  end
  local G, L = graph(), lib("builder_graph")
  if G and L then
    local list = frag.links
    if not (type(list) == "table" and #list > 0) then
      list = {}
      for i, l in ipairs(L.linksFromV1(frag.parts)) do list[i] = l end
    else
      local u2 = {}
      for i, l in ipairs(list) do u2[i] = L.unpackLink(l) end
      list = u2
    end
    for _, l in ipairs(list) do
      local a, b = map[l.a], map[l.b]
      if a and b then
        l.a, l.b, l.id = a, b, nil
        G:add(l)
      end
    end
  end
  -- WP5's controls come along with the uids remapped, when it can
  local cs = other("controls")
  if frag.controls and cs and cs.remap and cs.merge then
    W.controls = cs.merge(W.controls, cs.remap(tcopy(frag.controls), map))
  end
  local r0 = map[frag.root or -1]
  if r0 then out[1] = r0 end
  for _, r in ipairs(frag.parts or {}) do
    local u = map[r.uid]
    if u and u ~= r0 then out[#out + 1] = u end
  end
  struct_changed()
  publish_center(); refresh_stats()
  return out, map
end

-- A fragment into the hand: spawned, lifted, and placed (one step) or dropped.
local function hold_fragment(frag)
  if ghost or not frag or #(frag.parts or {}) == 0 then return false end
  local t = tx_begin("paste " .. #frag.parts .. " parts", {})
  local uids = instantiate(frag, 0, 0, 0, t)
  if #uids == 0 then return false end
  pickup(uids[1], { set = list_set(uids), only = true, paste = t })
  hint(string.format("%d part%s in hand — click to place · ESC drops them", #uids, #uids == 1 and "" or "s"), 3.0)
  return ghost ~= nil
end

function copy(uids)
  local list = uid_list(uids or selection())
  if #list == 0 then return false end
  -- the primary first, so it is what the paste hangs from
  if selected_uid and list_set(list)[selected_uid] then
    for i = #list, 1, -1 do if list[i] == selected_uid then table.remove(list, i) end end
    table.insert(list, 1, selected_uid)
  end
  W.clip = fragment(list)
  hint(string.format("copied %d part%s — CTRL+V puts them in your hand", #list, #list == 1 and "" or "s"), 2.0)
  return #list
end
function paste()
  if not W.clip then hint("nothing copied yet — CTRL+C copies the selection", 2.0); return false end
  return hold_fragment(W.clip)
end
function clipboard() return W.clip end
-- A copy 0.5 m along the camera's right, selected (one step).
function duplicate(uids)
  local list = uid_list(uids or selection())
  if #list == 0 or ghost then return false end
  local frag = fragment(list)
  local mx, my = input.mouse()
  local _, _, _, d1x, d1y, d1z = camera.screenToRay(mx, my)
  local _, _, _, d2x, d2y, d2z = camera.screenToRay(mx + 40, my)
  local rx, ry, rz = unit(d2x - d1x, d2y - d1y, d2z - d1z)
  if rx == 0 and ry == 0 and rz == 0 then rx = 1 end
  local t = tx_begin("duplicate " .. #list .. " parts", {})
  local out = instantiate(frag, rx * 0.5, ry * 0.5, rz * 0.5, t)
  tx_commit(t)
  sel_apply(out, "set")
  ui("place", 0.8)
  return out
end

-- ── the craft library (§8.4) ────────────────────────────────────────────────
local function slug(name)
  local s2 = tostring(name or "untitled"):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return (s2 ~= "" and s2) or "untitled"
end
function craftName() return W.craft or "Untitled" end
function craftList()
  local idx = save.get("shipyard.crafts")
  local out = {}
  if type(idx) == "table" then
    for _, c in ipairs(idx) do out[#out + 1] = tcopy(c) end
  end
  return out
end
local function index_put(entry)
  local idx = craftList()
  for i = #idx, 1, -1 do if idx[i].slug == entry.slug then table.remove(idx, i) end end
  if entry.name then table.insert(idx, 1, entry) end
  save.set("shipyard.crafts", idx)
end
-- The library entry for a saved craft, and its thumbnail for the OPEN list
-- (async; skipped where there is no capture).
-- (globals, and the job on W: this file's main chunk is at Lua's 200-local limit)
function libraryPut(name, sl, st)
  st = st or stats()
  index_put({ name = name, slug = sl, parts = st.parts, mass = st.mass, cost = st.cost, t = time,
              thumb = "user://crafts/" .. sl .. ".png", file = LIBFMT })
  save.set("shipyard.current", name)
  if camera and camera.capture and assets and assets.writeBytes then
    pcall(camera.capture, { w = 256, h = 144, ui = false, draws = false }, function(bytes)
      if bytes then pcall(assets.writeBytes, "user://crafts/" .. sl .. ".png", bytes) end
    end)
  end
  return st
end

-- ── the library's blueprints are FILES ──────────────────────────────────────
-- A craft kept in the library is a user:// file, one per craft and save slot
-- (user://library/<slot>/<slug>.json); the save keeps only the index
-- (`shipyard.crafts`). In the save, each copy counted against the slot's 4 MB:
-- a 3,000-part craft (beside the stand's own copy) was refused, and the
-- library could not keep it. Entries written before are moved to files the
-- first time they are opened, and in the background (one a frame, sliced),
-- and their save key is then dropped.
--
-- The file is JSON the engine decodes, written by this encoder so that every
-- value comes back as it went in: a list is a list, any other table an object
-- whose non-string keys are tagged ("\0n:12"), every number exact (see the
-- number case below), and the few values JSON has no word for tagged as
-- strings ("\0f:inf").
-- `step` is called between parts; the autosave's job yields there.
LIBFMT = 1
function libEsc(str)
  return '"' .. str:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end
function libEncode(v, out, step)
  local t = type(v)
  if t == "number" then
    if v ~= v then out[#out + 1] = '"\\u0000f:nan"'
    elseif v == math.huge then out[#out + 1] = '"\\u0000f:inf"'
    elseif v == -math.huge then out[#out + 1] = '"\\u0000f:-inf"'
    elseif v == 0 and 1 / v < 0 then out[#out + 1] = "-0.0"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%d", v)
    else
      -- A decimal the reader parses exactly (15 digits, a modest exponent:
      -- one correctly rounded step); anything else as mantissa and binary
      -- exponent, both integers ("\0d:m:e" = m × 2^e). The engine's JSON
      -- reader rounds a 17-digit decimal to the nearest double only most of
      -- the time (1 in 6 came back a bit off, measured on rc16).
      local a = math.abs(v)
      local str = (a >= 1e-6 and a < 1e15) and string.format("%.15g", v) or nil
      if str and tonumber(str) == v and not str:find("e", 1, true) then
        out[#out + 1] = str
      else
        local m, e = math.frexp(v)
        out[#out + 1] = string.format('"\\u0000d:%d:%d"', m * 2 ^ 53, e - 53)
      end
    end
  elseif t == "string" then
    out[#out + 1] = libEsc(v:sub(1, 1) == "\0" and ("\0s:" .. v) or v)
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "table" then
    local n, cnt = #v, 0
    for _ in pairs(v) do cnt = cnt + 1 end
    local list = n > 0 and cnt == n
    if list then for i = 1, n do if v[i] == nil then list = false break end end end
    if list then
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        libEncode(v[i], out, step)
        if step then step() end
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, x in pairs(v) do
        local kt, ks = type(k), nil
        if kt == "string" then ks = (k:sub(1, 1) == "\0") and ("\0s:" .. k) or k
        elseif kt == "number" then ks = "\0n:" .. string.format("%.17g", k)
        elseif kt == "boolean" then ks = "\0b:" .. tostring(k) end
        if ks and type(x) ~= "function" and type(x) ~= "userdata" then
          if not first then out[#out + 1] = "," end
          first = false
          out[#out + 1] = libEsc(ks)
          out[#out + 1] = ":"
          libEncode(x, out, step)
        end
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end
-- The decoded JSON back into the tables that were written (fresh tables).
function libDecode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then
      local m, e = rest:match("^(-?%d+):(-?%d+)$")
      if m then return math.ldexp(tonumber(m), tonumber(e)) end
      return v
    end
    if tag == "f:" then return rest == "nan" and (0 / 0) or (rest == "-inf" and -math.huge or math.huge) end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" and k:sub(1, 1) == "\0" then
      local tag, rest = k:sub(2, 3), k:sub(4)
      if tag == "n:" then k = tonumber(rest)
      elseif tag == "b:" then k = rest == "true"
      elseif tag == "s:" then k = rest end
    end
    if k ~= nil then out[k] = libDecode(x) end
  end
  return out
end
function libSlot()
  local sl = (save.slot and save.slot()) or "default"
  return (tostring(sl):gsub("[^%w_%-]", "_"))
end
function libPath(sl) return "user://library/" .. libSlot() .. "/" .. sl .. ".json" end
function libText(bp, step)
  local out = {}
  libEncode({ fmt = LIBFMT, bp = bp }, out, step)
  return table.concat(out)
end
-- Write a craft's file. true, or false and why.
function libWrite(sl, text)
  if not (assets and assets.writeText) then return false, "no file access" end
  local ok, res, why = pcall(assets.writeText, libPath(sl), text)
  if not ok then return false, tostring(res) end
  if res == false then return false, tostring(why) end
  return true
end
-- A craft's blueprint from its file, or nil.
function libRead(sl)
  if not (assets and assets.readText and json and json.decode) then return nil end
  local ok, text = pcall(assets.readText, libPath(sl))
  if not ok or type(text) ~= "string" then return nil end
  local v = json.decode(text)
  if type(v) ~= "table" or type(v.bp) ~= "table" then return nil end
  return libDecode(v.bp)
end
-- The save key a library blueprint lived under before it was a file.
function libLegacyKey(sl) return "shipyard.craft." .. sl end
function libDropLegacy(sl)
  if save.delete then save.delete(libLegacyKey(sl)) else save.set(libLegacyKey(sl), nil) end
end

-- craftSave(name [, quiet]). A save you ask for is written at once, with one
-- flush (it used to flush twice). A QUIET one is build_host's autosave: no
-- sound, no hint, and no flush of its own (the engine writes the store within
-- a few seconds anyway), and it is spread over frames — the blueprint, then
-- its save.set, then the library file (encoded a few milliseconds a frame),
-- then the library entry — because each of those is one pass over every part:
-- 7 + 12 + 11 ms at 1,000 parts, three times that at 3,000, and the autosave
-- landing two seconds after every edit was the builder's periodic hitch
-- (perfbench g_idle_*, build_host 55-120 ms).
function craftSave(name, quiet)
  name = name or W.craft or "Untitled"
  W.craft = name
  local sl = slug(name)
  if quiet then
    W.save_job = { stage = 1, name = name, sl = sl }
    return true
  end
  W.save_job = nil
  local bp, i = make_blueprint()
  save.set("shipyard.blueprint", bp)
  W.launch_bp = nil
  ui("save", 0.9)
  -- A big craft's file is written like the autosave's, a few milliseconds a
  -- frame (its text is ~50 ms of Lua per 1,000 parts); the hint says when.
  if partCount > LIB_SYNC_PARTS then
    W.save_job = { stage = 3, name = name, sl = sl, bp = bp, loud = true, st = tcopy(stats()) }
    return true
  end
  local ok, why = libWrite(sl, libText(bp))
  if not ok then
    log("builder: the library could not keep “" .. name .. "” — " .. tostring(why))
    hint("the library could not keep “" .. name .. "”", 3.0)
    save.flush()
    return false
  end
  libDropLegacy(sl)
  local st = libraryPut(name, sl)
  save.flush()
  hint("saved “" .. name .. "” to the library  ·  " .. st.parts .. " parts", 2.5)
  return true
end
LIB_SYNC_PARTS = 300
-- The library file's text, a few milliseconds a frame: a coroutine that
-- yields between parts once LIB_SLICE_MS of this frame has gone.
LIB_SLICE_MS = 2.5
function libClock() return (app and app.wallClock and app.wallClock()) or os.clock() end
function libEncodeJob(bp)
  local co = coroutine.create(function()
    local t0, n = libClock(), 0
    return libText(bp, function()
      n = n + 1
      if n % 8 == 0 and not W.lib_now and (libClock() - t0) * 1000 > LIB_SLICE_MS then
        coroutine.yield()
        t0 = libClock()
      end
    end)
  end)
  return co
end
-- Run an encode job for this frame: the text when it is done, else nil.
function libEncodeTick(job)
  local ok, res = coroutine.resume(job)
  if not ok then error(res, 0) end
  if coroutine.status(job) == "dead" then return res or "" end
  return nil
end
-- One step of a quiet save a frame (from update).
-- A stage that fails (save.set refuses a blueprint that would take the slot
-- past its byte cap) ends the job and says so once, instead of failing again
-- every frame.
function saveJobStep(j)
  if j.stage == 1 then
    j.bp = make_blueprint()
    j.st = tcopy(stats())   -- (the entry describes the craft saved, not the stand later)
  elseif j.stage == 2 then
    save.set("shipyard.blueprint", j.bp)
    W.launch_bp = nil
  elseif j.stage == 3 then
    j.lib = true
    j.enc = j.enc or libEncodeJob(j.bp)
    local text = libEncodeTick(j.enc)
    if not text then return false end
    local ok, why = libWrite(j.sl, text)
    if not ok then error("the library file: " .. tostring(why), 0) end
    libDropLegacy(j.sl)
  else
    local st = libraryPut(j.name, j.sl, j.st)
    if j.loud then
      save.flush()
      hint("saved “" .. j.name .. "” to the library  ·  " .. st.parts .. " parts", 2.5)
    end
    return true
  end
  j.stage = j.stage + 1
  return false
end
function saveJobTick()
  local j = W.save_job
  if not j then return libMigrateTick() end
  local ok, done = pcall(saveJobStep, j)
  if not ok then
    W.save_job = nil
    if j.loud then hint("the library could not keep “" .. tostring(j.name) .. "”", 3.0) end
    if W.save_err ~= tostring(done) then
      W.save_err = tostring(done)
      log("builder: autosave stopped — " .. tostring(done))
    end
    return
  end
  if done then W.save_job = nil end
end
-- MIGRATION: a library entry still kept in the save is moved to its file, one
-- at a time while nothing else is being saved: read (one frame), encode
-- (sliced), written, and its save key dropped.
function libMigrateTick()
  if W.lib_migrated then return end
  local m = W.lib_mig
  if not m then
    local idx = save.get("shipyard.crafts")
    if type(idx) == "table" then
      for _, e in ipairs(idx) do
        if type(e) == "table" and e.slug and not e.file and not (W.lib_skip and W.lib_skip[e.slug]) then
          m = { slug = e.slug }
          break
        end
      end
    end
    if not m then W.lib_migrated = true; return end
    W.lib_mig = m
    return
  end
  local okm, err = pcall(function()
    if not m.bp then
      local bp = save.get(libLegacyKey(m.slug))
      if type(bp) ~= "table" then m.gone = true; return end
      m.bp = bp
      return
    end
    m.enc = m.enc or libEncodeJob(m.bp)
    local text = libEncodeTick(m.enc)
    if not text then return end
    local ok, why = libWrite(m.slug, text)
    if not ok then error(why, 0) end
    m.done = true
  end)
  if not okm then
    log("builder: could not move “" .. tostring(m.slug) .. "” to the library folder — " .. tostring(err))
    W.lib_skip = W.lib_skip or {}
    W.lib_skip[m.slug] = true
    W.lib_mig = nil
    return
  end
  if m.done or m.gone then
    libMarkFile(m.slug, m.done)
    if m.done then libDropLegacy(m.slug) end
    W.lib_mig = nil
  end
end
-- Mark an index entry as kept in a file (or, `false`, as having no blueprint
-- anywhere: an entry whose key was already gone).
function libMarkFile(sl, has)
  local idx = craftList()
  for _, e in ipairs(idx) do
    if e.slug == sl then
      if has then e.file = LIBFMT else e.file = 0 end
    end
  end
  save.set("shipyard.crafts", idx)
end
function saving() return W.save_job ~= nil end
-- Has every library entry been moved to its file? (rescan: look again)
function libMigrated(rescan)
  if rescan then W.lib_migrated, W.lib_mig = nil, nil end
  return W.lib_migrated == true
end
-- The blueprint of a library craft (its file; an entry not moved yet is read
-- from the save, and moved now). nil when there is none.
function libBlueprint(sl)
  local entry
  for _, e in ipairs(craftList()) do if e.slug == sl then entry = e end end
  if not entry then return nil end
  if (entry.file or 0) ~= 0 then
    local bp = libRead(sl)
    if bp then return bp end
  end
  local old = save.get(libLegacyKey(sl))
  if type(old) ~= "table" then return nil end
  local ok = libWrite(sl, libText(old))
  if ok then
    libMarkFile(sl, true)
    libDropLegacy(sl)
    if W.lib_mig and W.lib_mig.slug == sl then W.lib_mig = nil end
  end
  return tcopy(old)
end
function craftOpen(name, mode)
  local bp = libBlueprint(slug(name))
  if type(bp) ~= "table" then hint("no craft called “" .. tostring(name) .. "” in the library", 2.5); return false end
  if mode == "merge" then return hold_fragment(fragment_of_bp(bp)) end
  load_blueprint(bp)
  W.craft = name
  save.set("shipyard.current", name)
  hint("opened “" .. name .. "”", 2.0)
  return true
end
function craftNew()
  if ghost then cancel_ghost() end
  if partCount > 0 then craftSave() end
  clear_stand()
  stage_order, saved_stage = {}, {}
  W.stage_sync_v = nil
  groups_state.groups, groups_state.edited = nil, false
  W.craft = nil
  save.set("shipyard.current", nil)
  hint("new craft — the last one is kept in the library (CTRL+O)", 3.0)
  return true
end
function craftDelete(name)
  local sl = slug(name)
  if assets and assets.remove then pcall(assets.remove, libPath(sl)) end
  libDropLegacy(sl)
  index_put({ slug = sl })
  if W.lib_mig and W.lib_mig.slug == sl then W.lib_mig = nil end
  save.flush()
  return true
end

-- Sub-assemblies: user://subassemblies/<slug>.json (+ index.json), so they
-- carry across saves. Kept in memory too (and only there without files).
W.subs = {}
local function subs_index()
  if assets and assets.readJson then
    local ok, v = pcall(assets.readJson, "user://subassemblies/index.json")
    if ok and type(v) == "table" then return v end
  end
  return {}
end
function subAssemblies()
  local seen, out = {}, {}
  for _, n in ipairs(subs_index()) do if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  for n in pairs(W.subs) do if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  table.sort(out)
  return out
end
function makeSubAssembly(name, uids)
  local list = uid_list(uids or selection())
  if #list == 0 or not name or name == "" then return false end
  local frag = fragment(list)
  frag.name = name
  W.subs[name] = frag
  if assets and assets.writeJson then
    pcall(assets.writeJson, "user://subassemblies/" .. slug(name) .. ".json", frag)
    local idx = subs_index()
    local have = false
    for _, n in ipairs(idx) do if n == name then have = true end end
    if not have then idx[#idx + 1] = name end
    pcall(assets.writeJson, "user://subassemblies/index.json", idx)
  end
  hint("sub-assembly “" .. name .. "” saved (" .. #list .. " parts)", 2.5)
  return true
end
function subAssembly(name)
  if W.subs[name] then return W.subs[name] end
  if assets and assets.readJson then
    local ok, v = pcall(assets.readJson, "user://subassemblies/" .. slug(name) .. ".json")
    if ok and type(v) == "table" then W.subs[name] = v; return v end
  end
  return nil
end

-- ── commands ────────────────────────────────────────────────────────────────
local CMD = {}

-- the parts an edit of `list` touches, with their neighbours (links change)
local function with_neighbours(set)
  local out = {}
  local G = graph()
  for u in pairs(set) do
    out[u] = true
    if G then for _, n in ipairs(G:neighbours(u)) do out[n] = true end end
  end
  return out
end

function CMD.place(a)
  local id = a.id
  if not (id and REG[id]) then return false end
  local rs = findScript and findScript("research")
  if rs and rs.isUnlocked and not rs.isUnlocked(id) then return false end
  local u = next_uid
  local around = {}
  if a.parent and parts[a.parent] then around[a.parent] = true end
  local t = tx_begin("place " .. (REG[id].label or id), around)
  tx_touch(t, u)
  if a.an then copyNormal[u] = { x = a.an.x, y = a.an.y, z = a.an.z } end
  spawn_part(id, a.x or 0, a.y or 0, a.z or 0, a.yaw or 0, a.parent, nil,
             a.pitch or 0, a.roll or 0, a.att, nil, nil)
  if a.size and parts[u] then parts[u].size = tcopy(a.size) end
  tx_commit(t)
  ui("place", 0.9)
  return u
end

function CMD.move(a)
  local list = uid_list(a)
  if #list == 0 then return false end
  if W.hist and not a.merge then W.hist:seal() end
  local p = parts[list[1]]
  local ddx, ddy, ddz = a.dx or 0, a.dy or 0, a.dz or 0
  if a.x or a.y or a.z then
    ddx, ddy, ddz = (a.x or p.x) - p.x, (a.y or p.y) - p.y, (a.z or p.z) - p.z
  end
  if #list == 1 then
    apply_edit(list[1], ddx, ddy, ddz, 0, 0, 0)
  else
    local set = {}
    for _, u in ipairs(list) do for v in pairs(edit_set(u)) do set[v] = true end end
    for v in pairs(deps_of(set)) do set[v] = true end
    edit_begin(list[1], set)
    for u in pairs(set) do
      local q = parts[u]
      if q then set_part_pos(q, q.x + ddx, q.y + ddy, q.z + ddz) end
    end
    publish_center(); refresh_stats()
  end
  if W.hist and not a.merge then W.hist:seal() end
  return true
end

function CMD.rotate(a)
  local list = uid_list(a)
  if #list == 0 then return false end
  if W.hist and not a.merge then W.hist:seal() end
  if a.reset then
    resetSelection(list[1])
  else
    local Q = a.Q
    if not Q and a.axis and a.angle then Q = basisRot(norm3(a.axis), a.angle) end
    if not Q then return false end
    rotateSelection(list[1], Q)
  end
  if W.hist and not a.merge then W.hist:seal() end
  return true
end

CMD["delete"] = function(a)
  local list = uid_list(a)
  local gone = {}
  for _, uid in ipairs(list) do
    local p = parts[uid]
    gone[uid] = true
    if p and p.sym then for _, m in ipairs(group_members(p.sym)) do gone[m] = true end end
  end
  if not a.only then for u in pairs(deps_of(gone)) do gone[u] = true end end
  if next(gone) == nil then return false end
  local t = tx_begin("delete " .. tostring(#set_list(gone)) .. " parts", with_neighbours(gone))
  local n = 0
  for u in pairs(gone) do if remove_part(u) then n = n + 1 end end
  tx_commit(t)
  if n == 0 then return false end
  ui("scrap", 0.8)
  return n
end

function CMD.setWcfg(a)
  local p = parts[a.uid]
  if not (p and p.def.wheel) then return false end
  wheelSet(a.uid, a.key, a.value, a.quiet)
  return true
end

-- A new stack part between `host` and what stands on its `side` node; the
-- far side moves out by the new part's height.
function CMD.insert(a)
  local H = a.host
  local hp = parts[H]
  local def = REG[a.id or ""]
  local side = (a.side == "bottom") and "bottom" or "top"
  if not (hp and def) then return false end
  local N = side_user(H, side)
  local hB = basisOf(hp.yaw, hp.pitch, hp.roll)
  local nrm = (side == "top") and hB.Y or neg3(hB.Y)
  local L = def.h
  local around = { [H] = true }
  local far = {}
  if N then far = beyond_of(N, H); for u in pairs(far) do around[u] = true end; around[N] = true end
  local u = next_uid
  local t = tx_begin("insert " .. (def.label or a.id), around)
  tx_touch(t, u)
  for v in pairs(far) do
    local q = parts[v]
    if q then set_part_pos(q, q.x + nrm.x * L, q.y + nrm.y * L, q.z + nrm.z * L) end
  end
  local G = graph()
  if G and N then
    for _, l in ipairs(G:incident(H)) do
      if (l.a == N or l.b == N) and l.k == "stack" then G:remove(l.id) end
    end
  end
  local hh = hp.def.h * 0.5
  local cx = hp.x + nrm.x * (hh + L * 0.5)
  local cy = hp.y + nrm.y * (hh + L * 0.5)
  local cz = hp.z + nrm.z * (hh + L * 0.5)
  spawn_part(a.id, cx, cy, cz, hp.yaw, H, nil, hp.pitch, hp.roll, side, nil, nil)
  local opp = (side == "top") and "bottom" or "top"
  if N and parts[N] then
    if parts[N].parent == H then set_parent(N, u, side)
    elseif hp.parent == N then set_parent(H, u, opp)
    elseif G then G:add({ a = u, b = N, k = "stack", sa = side, sb = opp }) end
  end
  tx_commit(t)
  ui("place", 0.9)
  return u
end

-- Cut every link between the selection and the rest; poses stay.
function CMD.detach(a)
  local set = list_set(uid_list(a))
  if next(set) == nil then return false end
  local G = graph()
  if not G then return false end
  local t = tx_begin("detach", with_neighbours(set))
  local n = 0
  for u in pairs(set) do
    for _, l in ipairs(G:incident(u)) do
      local o = (l.a == u) and l.b or l.a
      if not set[o] then
        G:remove(l.id)
        n = n + 1
        if l.prim and parts[l.b] then parts[l.b].parent = nil end
      end
    end
  end
  struct_changed()
  tx_commit(t)
  return n
end

function CMD.link(a)
  if not (parts[a.a] and parts[a.b]) or a.a == a.b then return false end
  local G = graph()
  if not G then return false end
  local t = tx_begin("link", { a.a, a.b })
  local id = G:add({ a = a.a, b = a.b, k = a.k or "weld", sa = a.sa, sb = a.sb, pa = vcopy(a.pa),
                     pb = vcopy(a.pb), n = vcopy(a.n), s = a.s, prim = a.prim })
  if a.prim and parts[a.b] then parts[a.b].parent = a.a; parts[a.b].att = a.sa end
  struct_changed()
  tx_commit(t)
  return id
end

function CMD.unlink(a)
  local G = graph()
  if not G then return false end
  local l = a.id and G:get(a.id)
  if not l and a.a and a.b then
    for _, x in ipairs(G:incident(a.a)) do
      if (x.a == a.b or x.b == a.b) and (not a.k or x.k == a.k) then l = x break end
    end
  end
  if not l then return false end
  local t = tx_begin("unlink", { l.a, l.b })
  G:remove(l.id)
  if l.prim and parts[l.b] then parts[l.b].parent = nil end
  struct_changed()
  tx_commit(t)
  return true
end

function CMD.setParam(a)
  local p = parts[a.uid]
  if not (p and a.key) then return false end
  local t = tx_begin("set " .. tostring(a.key), { a.uid }, a.merge or ("param:" .. a.uid .. ":" .. tostring(a.key)))
  tx_commit(t)
  p.size = p.size or {}
  p.size[a.key] = a.value
  p.def = def_of(p.id, p.size) or p.def
  p.pv = (p.pv or 0) + 1
  if p.node then
    -- a new size is a new mesh: the drawn part is re-dressed by a fresh node
    destroy(p.node); p.node = nil
    request_node(a.uid, p)
  end
  hash_put(a.uid, p)
  craftVersion = craftVersion + 1
  refresh_stats()
  return true
end

function CMD.root(a)
  if not parts[a.uid] then return false end
  tx_run("root", {}, function() W.root = a.uid end, nil, true)
  struct_changed()
  hint("root: " .. (parts[a.uid].def.label or parts[a.uid].id) .. " — everything hangs from it", 2.0)
  return true
end

function CMD.group(a)
  local list = uid_list(a)
  if #list == 0 then return false end
  tx_run("group", {}, function()
    W.outliner = W.outliner or {}
    W.outliner[#W.outliner + 1] = { name = a.name or ("Group " .. (#W.outliner + 1)), uids = list }
  end, nil, true)
  craftVersion = craftVersion + 1
  return #W.outliner
end

-- The craft's control mode (ctrlMode): "auto" | "rover" | "aircraft" | "rocket".
function CMD.setCtrl(a)
  local m = a.mode
  if m ~= "rover" and m ~= "aircraft" and m ~= "rocket" then m = nil end
  if m == W.ctrl then return true end
  tx_run("control mode", {}, function() W.ctrl = m end, nil, true)
  craftVersion = craftVersion + 1
  local c = ctrlMode()
  hint("control mode: " .. (c.label or "Auto") .. "   ·   how the craft drives in flight (the command part's menu changes it there)", 3.0)
  return true
end

function CMD.rename(a)
  local found = false
  tx_run("rename", {}, function()
    for _, g in ipairs(W.outliner or {}) do
      if g.name == a.group then g.name = a.name; found = true end
    end
    if not found then W.craft = a.name or W.craft end
  end, nil, true)
  craftVersion = craftVersion + 1
  return true
end

local function set_hidden(list, on)
  for _, u in ipairs(list) do
    local p = parts[u]
    if p then
      p.hidden = on or nil
      if p.node then p.node.visible = not on end
    end
  end
  craftVersion = craftVersion + 1
end
function CMD.hide(a)
  local list = uid_list(a)
  if #list == 0 then return false end
  tx_run("hide", list, function() set_hidden(list, a.on ~= false) end)
  if a.on ~= false then sel_apply(list, "remove") end
  return #list
end
function CMD.unhideAll()
  local list = hiddenUids()
  if #list == 0 then return 0 end
  tx_run("unhide all", list, function() set_hidden(list, false) end)
  return #list
end
function CMD.isolate(a)
  local keep = list_set(uid_list(a))
  local list = {}
  for u in pairs(parts) do if not keep[u] then list[#list + 1] = u end end
  tx_run("isolate", list, function() set_hidden(list, true) end)
  return #list
end

-- A mirrored copy of the selection across the craft's centre plane (its X)
-- or across a part's own X plane.
function CMD.mirror(a)
  local list = uid_list(a)
  if #list == 0 then return false end
  center_now()
  local cx, A = centerX, { x = 1, y = 0, z = 0 }
  local pl = parts[a.plane or -1]
  local frag = fragment(list)
  local t = tx_begin("mirror " .. #list .. " parts", {})
  local out = instantiate(frag, 0, 0, 0, t)
  for _, u in ipairs(out) do
    local p = parts[u]
    if p then
      local x, y, z
      if pl then
        local h = { x = pl.x, y = pl.y, z = pl.z }
        local B = basisOf(pl.yaw, pl.pitch, pl.roll)
        A = B.X
        x, y, z = reflect_pt(h, A, p.x, p.y, p.z)
      else
        x, y, z = 2 * cx - p.x, p.y, p.z
      end
      set_part_pos(p, x, y, z)
      set_part_rot(p, basisEuler(mirrorBasis(A, basisOf(p.yaw, p.pitch, p.roll))))
    end
  end
  tx_commit(t)
  sel_apply(out, "set")
  return out
end

-- WP5's controls model: bind / unbind / bindAxis live in scripts/controls.lua
-- as functions (state, args) → new state | result. One history step each.
for _, name in ipairs({ "bind", "unbind", "bindAxis" }) do
  CMD[name] = function(a)
    local cs = other("controls")
    local f = cs and cs[name]
    if not f then return api_not_yet("cmd " .. name .. " (no controls." .. name .. ")") end
    -- one history step, and none at all for a bind that was refused
    local t = tx_begin(name, {}, nil, true)
    W.controls = W.controls or {}
    local res = f(W.controls, a, controlsCtx())
    if res == false or res == nil then
      apply_snap(t.before)  -- put back anything a refused bind touched
      return false
    end
    if type(res) == "table" and res ~= a then W.controls = res end
    tx_commit(t)
    craftVersion = craftVersion + 1
    return res
  end
end

-- STAGE EDITS (one undo step each), from the STAGE tab:
--   { op = "item", key, to, new }   an event into stage `to` (new: a stage of its own there)
--   { op = "swap", i, j }           two stages trade places
--   { op = "reset" }                the default order again
CMD.stage = function(a)
  sync_stage_order()
  local t = tx_begin("staging", {}, nil, true)
  if a.op == "item" and a.key then
    stage_order = STAGEM.move(stage_order, a.key, a.to, a.new)
  elseif a.op == "swap" and a.i and a.j then
    stage_order = STAGEM.swap(stage_order, a.i, a.j)
  elseif a.op == "reset" then
    stage_order, saved_stage = {}, {}
    W.stage_sync_v = nil
  end
  tx_commit(t)
  craftVersion = craftVersion + 1
  sync_stage_order()
  refresh_stats()
  return true
end

function cmd(name, args)
  local f = CMD[name]
  if not f then return api_not_yet("cmd " .. tostring(name)) end
  return f(args or {})
end

function hold(spec)
  if ghost then return false end
  if type(spec) == "string" then
    if REG[spec] then
      pick(spec)
      return ghost ~= nil
    end
    return hold_fragment(subAssembly(spec))
  end
  if type(spec) == "table" and spec.parts then return hold_fragment(spec) end
  if type(spec) == "table" and type(spec[1]) == "number" then
    if not parts[spec[1]] then return false end
    pickup(spec[1], { set = list_set(uid_list(spec)) })
    return ghost ~= nil
  end
  return false
end

function registerPanel(s)
  if not (s and s.ownsMouse) then return false end
  for _, p in ipairs(API.panels) do if p == s then return true end end
  API.panels[#API.panels + 1] = s
  return true
end

-- Called by `update` each frame (a global, for the upvalue ceiling).
function panelsOwnMouse()
  local list = API.panels
  if #list == 0 then return false end
  local i = 1
  while i <= #list do
    local s = list[i]
    if s.valid == false then
      table.remove(list, i)
    else
      if s.ownsMouse() then return true end
      i = i + 1
    end
  end
  return false
end

function placard(msg, kind, secs)
  local warn = kind == "error" or kind == "warn"
  local sb = other("builder_statusbar")
  if sb and sb.showPlacard then
    sb.showPlacard(tostring(msg), kind or "info", secs or (warn and 3.0 or 2.5))
    return
  end
  hint((warn and "⚠ " or "") .. tostring(msg), secs or (warn and 3.0 or 2.5))
end
-- The hint bar's current line (WP2's status strip shows it).
function hintText()
  if W.hint_text then return W.hint_text end
  return hint_node and hint_node.text or HINT_IDLE
end
function setLaunchSite(site)
  launchSiteChoice = (site == "runway") and "runway" or "pad"
  refresh_stats()
  return launchSiteChoice
end

-- The frame-space shapes queued during update, drawn against the frame as the
-- rails left it this frame (builder_space.wrapDraw).
function lateUpdate(node, dt)
  if W.F and W.F.flush then W.F.flush() end
end
