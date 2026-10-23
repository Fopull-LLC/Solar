-- SMOKE HARNESS: the material economy. Runs the real materials.lua,
-- inventory.lua, tool_belt.lua, research.lua and the depot half of
-- facility_menu.lua against a stubbed engine, and drives the whole loop the
-- game is built on:
--
--   mine rock → the pack fills (and refuses to overfill) → carry it to a craft
--   → the hold takes what fits → land at base → the crane unloads → the depot
--   sells → the discovery pays → R&D opens the next part.
--
--   luajit solar/tests/smoke_resources.lua
--
-- Fidelity notes (the bugs this stub is shaped to catch):
--  * MASS is the whole limit, so every container here is small enough to fill.
--    A transfer that "succeeds" by exceeding capacity, or one that loses the
--    units that didn't fit, fails a check rather than quietly costing a player
--    an afternoon's mining.
--  * The world record is what mining reads (archetype + seed), so a tool that
--    forgets to resolve the body yields the wrong planet's ore.
--  * Everything is `save.*`-backed: the store here persists across "scene
--    loads" exactly like the engine's.

local T = 0.0

-- ── engine API ──────────────────────────────────────────────────────────────
local API, store, logs = {}, {}, {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
  flush = function() end,
}
function API.log(m) logs[#logs + 1] = tostring(m) end
function API.print(m) logs[#logs + 1] = tostring(m) end
function API.vec3(x, y, z) return { x = x, y = y, z = z } end
local effects = {}                       -- one-shots the tools fired
function API.spawnEffect(key) effects[#effects + 1] = key end
-- The world-space aiming ring is immediate-mode draw calls; record them so a
-- test can check the crosshair actually lands on the hit rather than trusting
-- that it was queued somewhere.
local rings = {}
API.draw = {
  line = function() end,
  disc = function() end,   -- the sight's fill and band (vfx overhaul)
  ring = function(cx, cy, cz, nx, ny, nz, r)
    rings[#rings + 1] = { x = cx, y = cy, z = cz, r = r }
  end,
}
local function last_ring() return rings[#rings] end
-- The outer ring is the aiming circle; an inner one (the cut counting out the
-- next unit) is drawn over it in the same frame, so scan back for the wide one.
local function outer_ring(r)
  for i = #rings, math.max(1, #rings - 4), -1 do
    if math.abs(rings[i].r - r) < 1e-6 then return rings[i] end
  end
  return nil
end

-- Audio: every voice records what it was asked to do, so a test can check that
-- the beam's hum is ONE looping voice rather than a one-shot per frame.
local voices, plays = {}, {}
API.audio = {
  play = function(clip, _, _, _, _)
    plays[#plays + 1] = clip
    local v = { clip = clip, stopped = false, volume = 0, pitch = 1 }
    function v:stop() self.stopped = true end
    function v:setVolume(x) self.volume = x end
    function v:setPitch(x) self.pitch = x end
    voices[#voices + 1] = v
    return v
  end,
}
-- The runtime UI builder. The reticle is described through it; here we just
-- keep the last description so the checks can read what it would have drawn.
local reticle_tree = nil
API.ui = { make = function(_, tree) reticle_tree = tree end }

local function noise(x, y, z, seed)
  seed = seed or 0
  local a = math.sin(x * 1.7 + seed * 0.13) * math.cos(y * 1.3 - seed * 0.21)
  local b = math.sin(z * 2.1 - seed * 0.07) * math.cos(x * 0.9 + y * 0.5)
  return math.max(-1, math.min(1, (a + b) * 0.5))
end
math.noise = noise

local BODY = { name = "Golil", x = 0, y = 0, z = 0, radius = 424, mu = 3.5e6, soi = 1e6 }
local SURFACE = 400.0
API.space = {
  bodies = function() return { BODY } end,
  body = function(n) return (n == BODY.name) and BODY or nil end,
  dominant = function() return BODY.name end,
}
store["world." .. BODY.name] = {
  name = BODY.name, kind = "canyon", seed = 4242, radius = SURFACE,
  relief = 24.0, sea = 0, atmo = 0.6, insol = 1.0,
}

-- The dig target: a face `dig_depth` metres under the surface, straight ahead.
-- `set_depth` also walks the crew down the shaft to stand at the face, because
-- that is what mining forty metres down actually involves — and the tool's reach
-- is measured from the player, so a face forty metres away is out of range by
-- design rather than by accident.
local dig_depth = 0.0
local digs = 0
local dug = {}                             -- every bite, in order
API.terrain = {
  dig = function(x, y, z, r, s)
    digs = digs + 1
    dug[#dug + 1] = { x = x, y = y, z = z, r = r, s = s }
  end,
  sculpt = function() digs = digs + 1 end,
}

-- THE GROUND. Two parallel faces normal to +X — the true surface at `SURFACE`
-- and the shaft face `dig_depth` below it — and every ray is intersected with
-- the right one PROPERLY, so the hit lands ON the ray it was cast along.
--
-- That last clause is the whole point of this rewrite. The old stub answered
-- with a point of its own choosing that was near the ray but not on it, which
-- was harmless while the tool simply used the hit — and silently untestable the
-- moment the tool started projecting its cut point onto the ray. A harness that
-- hands back geometry the caller can't do maths with tests nothing.
--
-- Which face a ray meets is decided by where it STARTS, not by which way it
-- points:
--   * a TOOL ray leaves the camera, just above the ground, and meets the shaft
--     face;
--   * a DEPTH PROBE starts 120 m up (see `depth_at`) and meets the true
--     surface, which is what makes a shaft's tenth metre really be ten metres
--     down.
local PROBE_ALT = SURFACE + 60
local function plane_hit(ox, oy, oz, dx, dy, dz, maxd, px)
  if math.abs(dx) < 1e-9 then return nil end
  local t = (px - ox) / dx
  if t < 0 or t > maxd then return nil end
  return { x = px, y = oy + dy * t, z = oz + dz * t,
           nx = 1, ny = 0, nz = 0, distance = t }
end
-- Everything is measured FROM THE BODY, and the body is allowed to move: this
-- planet orbits a star like every other one, and a tool that remembers a world
-- point across frames is remembering a point that has sailed off. The drift
-- check below moves it.
function API.raycast(ox, oy, oz, dx, dy, dz, maxd)
  local l = math.sqrt((ox - BODY.x) ^ 2 + (oy - BODY.y) ^ 2 + (oz - BODY.z) ^ 2)
  if l < 1e-6 then return nil end
  return plane_hit(ox, oy, oz, dx, dy, dz, maxd or 1e9,
    BODY.x + ((l > PROBE_ALT) and SURFACE or (SURFACE - dig_depth)))
end

local keys = {}
local cursor = { x = 400, y = 300 }        -- where the player is pointing
local buttons = {}
API.input = {
  key = function(k) return keys[k] == true end,
  pressed = function(k) return keys["!" .. k] == true end,
  button = function(b) return buttons[b] == true end,
  mouse = function() return cursor.x, cursor.y end,
}
local function press(k) keys["!" .. k] = true end
local function clear_presses()
  for k in pairs(keys) do if k:sub(1, 1) == "!" then keys[k] = nil end end
end

local ASTRO = { __id = 1, id = 1, name = "Astronaut", valid = true, visible = true,
                x = SURFACE + 2, y = 0, z = 0 }
local DEPOT = { __id = 2, id = 2, name = "FacDepot", valid = true, x = SURFACE + 10, y = 0, z = 0 }
local SHIP = { __id = 3, id = 3, name = "Kestrel I", valid = true,
               x = SURFACE + 6, y = 0, z = 0 }
local FAR_SHIP = { __id = 4, id = 4, name = "Stranded", valid = true,
                   x = SURFACE + 900, y = 0, z = 0 }

-- The laser's two effect nodes and its reticle, stubbed just enough that the
-- presentation path runs: a beam that is played and stopped in the wrong order
-- leaves a laser hanging in the air after you let go.
-- The game view and its cursor ray. 800x600, camera behind the crew looking
-- DOWN into the ground (−X, the direction the shaft face is in); a pixel
-- off-centre tilts the ray, which is the whole thing being tested. The origin is
-- the camera's own position, so scrolling the third-person orbit out really does
-- start the ray further back — the condition that used to eat the tool's range.
--
-- LOOKING somewhere else is what moves the aim, not the OS pointer. The belt
-- fires through the middle of the view now (see `aim_pixel`): the cursor is
-- wherever the last menu left it, and firing through it is how the tool ended
-- up shooting at the sky with no ring, no beam and no message. `look` is the
-- harness's yaw, folded into the ray the same way an off-centre pixel used to
-- be, so every test below still swings the beam — through the path the game
-- actually takes.
local CAM = { x = SURFACE + 6, y = 0, z = 0 }
local look = { yaw = 0.0 }
API.camera = {
  screenRect = function() return 0, 0, 800, 600 end,
  screenSize = function() return 800, 600 end,
  screenToRay = function(sx, sy)
    local dy = -(sy - 300) / 600 * 0.9
    local dz = (sx - 400) / 800 * 1.2 + look.yaw
    local l = math.sqrt(1 + dy * dy + dz * dz)
    return CAM.x, CAM.y, CAM.z, -1 / l, dy / l, dz / l
  end,
}

-- `moved` records any write to .x/.y/.z. A PARENTED node's coordinates are
-- parent-local, so a script that "places" one in world metres puts it at roughly
-- twice the world position — kilometres away on a planet that is thousands of
-- units from its star, and swinging with the orbit. That is a real bug this
-- harness caught the second time round, so the muzzle watches for it.
local function fx_node(name)
  local n = { valid = true, playing = false, intensity = 0, beam = nil,
              moved = false, light = { intensity = 0 } }
  local xyz = { x = 0, y = 0, z = 0 }
  setmetatable(n, {
    __index = function(_, k) return xyz[k] end,
    __newindex = function(t, k, v)
      if k == "x" or k == "y" or k == "z" then
        xyz[k] = v
        rawset(t, "moved", true)
      else
        rawset(t, k, v)
      end
    end,
  })
  rawset(n, "name", name)
  local ps = {
    play = function() n.playing = true end,
    stop = function() n.playing = false end,
    isPlaying = function() return n.playing end,
    setIntensity = function(_, i) n.intensity = i end,
    setBeamEnd = function(_, x, y, z) n.beam = { x, y, z } end,
  }
  -- Colon-called from the script, so swallow the receiver.
  rawset(n, "particles", function(self)
    return { play = ps.play, stop = ps.stop, isPlaying = ps.isPlaying,
             setIntensity = ps.setIntensity, setBeamEnd = ps.setBeamEnd }
  end)
  rawset(n, "getcomponent", function(_, k)
    if k == "PointLight" then return rawget(n, "light") end
  end)
  return n
end
local MUZZLE, IMPACT = fx_node("Laser Muzzle"), fx_node("Laser Impact")
-- The rifle in the astronaut's hand: bone-attached in the real scene, so the
-- script must read its WORLD position rather than placing it.
local TOOLNODE = { name = "Laser Tool", valid = true, visible = true,
                   x = 0, y = 0, z = 0 }
MUZZLE.worldX, MUZZLE.worldY, MUZZLE.worldZ = SURFACE + 2.6, 1.0, 0.3

-- The facility panel's four nodes, so the DEPOT SCREEN can be driven rather than
-- only its two verbs. The action button carries an authored placeholder label
-- ("Action") exactly like the scene does — that placeholder showing through is
-- the bug, so the harness has to be able to see it.
local function ui_node(name, text)
  local el = { visible = true, opacity = 1.0 }
  return { name = name, text = text or "",
           getcomponent = function(_, k) if k == "UiElement" then return el end end,
           __el = el }
end
local PANEL = {
  ["Facility Prompt"] = ui_node("Facility Prompt"),
  ["Facility Panel"] = ui_node("Facility Panel"),
  ["Facility Title"] = ui_node("Facility Title", "Facility"),
  ["Facility Body"] = ui_node("Facility Body"),
  ["Facility Action"] = ui_node("Facility Action", "Action"),
  ["Facility Exit"] = ui_node("Facility Exit", "Close"),
}

-- Prefab spawns (the tool models) land at once, as plain nodes.
SPAWNED = {}
function API.spawn(prefab, _, cb)
  local n = { name = prefab, valid = true, visible = true, x = 0, y = 0, z = 0 }
  function n:setParent(p) self.parent_ = p end
  function n:setAngles() end
  function n:toWorld(v) return { x = ASTRO.x + v.x, y = ASTRO.y + v.y, z = ASTRO.z + v.z } end
  SPAWNED[#SPAWNED + 1] = n
  if cb then cb(n) end
end

function API.find(name)
  if name == "Astronaut" then return ASTRO end
  if name == "FacDepot" then return DEPOT end
  if name == "Laser Muzzle" then return MUZZLE end
  if name == "Laser Impact" then return IMPACT end
  if name == "Laser Tool" then return TOOLNODE end
  return PANEL[name]
end
function API.createNode() end

-- ── script loading ──────────────────────────────────────────────────────────
local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  return env
end
function API.findScript(kind) return envs[kind] end
function API.findScripts(kind)
  if kind == "vessel_controller" then return envs.__vessels or {} end
  return envs[kind] and { envs[kind] } or {}
end

local mats = load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
local co = load_script("solar/scripts/company.lua", "company")
local cl = load_script("solar/scripts/climate.lua", "climate")
local rs = load_script("solar/scripts/research.lua", "research")
local fm = load_script("solar/scripts/facility_menu.lua", "facility_menu")
local tb = load_script("solar/scripts/tool_belt.lua", "tool_belt")

-- The camera the tools aim along: behind the crew, pointing −X at the face.
envs.planet_camera = { cam_x = CAM.x, cam_y = 0, cam_z = 0,
                       fwd_x = -1, fwd_y = 0, fwd_z = 0 }

-- The walker is the ONE place that answers "is the crew out and about" — it
-- watches the fleet and the loading flag and publishes `onFoot`, and every tool
-- and panel asks it rather than re-deriving the answer. Set false to model
-- being in a pod.
envs.planet_walker = { onFoot = true }

local function set_camera(x)
  CAM.x = x
  envs.planet_camera.cam_x = x
end

local function set_depth(d)
  dig_depth = d
  ASTRO.x = BODY.x + SURFACE - d + 2.0        -- standing at the face
  set_camera(ASTRO.x + 4.0)                   -- the orbit camera behind them
  MUZZLE.worldX = ASTRO.x + 0.6
end

-- Advance the planet along its orbit, carrying the crew and the camera with it —
-- which is what actually happens between two frames of a held trigger.
local function orbit(step)
  BODY.x = BODY.x + step
  ASTRO.x = ASTRO.x + step
  set_camera(CAM.x + step)
  DEPOT.x, SHIP.x, FAR_SHIP.x = DEPOT.x + step, SHIP.x + step, FAR_SHIP.x + step
end

-- Two "vessels": one parked at the base with a hold, one stranded far away.
-- Only the interface the depot and the panel use is stubbed.
local function fake_vessel(node, holdcap)
  local v = { node = node, craftName = node.name,
              holdId = holdcap > 0 and ("hold:" .. node.name) or nil,
              holdCap = holdcap, applied = 0 }
  function v.holdApplyMass() v.applied = v.applied + 1 end
  if v.holdId then inv.setCap(v.holdId, holdcap) end
  return v
end
local KESTREL = fake_vessel(SHIP, 60.0)
local STRANDED = fake_vessel(FAR_SHIP, 200.0)
envs.__vessels = { KESTREL, STRANDED }

co.start({})
tb.start(ASTRO)

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

-- ── 1. the registry ─────────────────────────────────────────────────────────
check("every material is weighed and priced", (function()
  for _, id in ipairs(mats.list()) do
    local d = mats.byId(id)
    if not (d and d.kg > 0 and d.value >= 0 and d.name) then return false end
  end
  return #mats.list() > 8
end)())
check("the listing order is stable", (function()
  local a, b = mats.list(), mats.list()
  for i, id in ipairs(a) do if b[i] ~= id then return false end end
  return true
end)())

check("a surface dig never turns up deep ore", (function()
  for i = 0, 200 do
    local m = mats.pickOre("canyon", 0.0, i / 200)
    if m == "uranium" or m == "crystal" then return false end
    if not mats.byId(m) then return false end
  end
  return true
end)())
check("a deep shaft can", (function()
  local deep = false
  for i = 0, 400 do
    local m = mats.pickOre("canyon", 40.0, i / 400)
    if m == "uranium" or m == "crystal" then deep = true end
  end
  return deep
end)())
check("the same hole always yields the same thing",
  mats.pickOre("canyon", 12, 0.42) == mats.pickOre("canyon", 12, 0.42))
check("an unknown archetype still yields something",
  mats.byId(mats.pickOre("no-such-world", 5, 0.5)) ~= nil)
check("an ice world yields ice", (function()
  local ice = false
  for i = 0, 100 do if mats.pickOre("ice", 1, i / 100) == "ice" then ice = true end end
  return ice
end)())

-- ── 2. containers ───────────────────────────────────────────────────────────
check("a fresh pack is empty", inv.isEmpty("astro") and inv.mass("astro") == 0)
check("the suit's capacity is what the params say",
  inv.cap("astro") == inv.params.suit_kg, inv.cap("astro"))

-- Derived, not hardcoded: the suit's capacity is a balance knob against the
-- laser's cut rate and moves when that does. What must hold is the RULE — the
-- units that fit go in and the one that doesn't is refused.
local fits = math.floor(inv.cap("astro") / mats.kg("iron"))
local took = inv.add("astro", "iron", fits)
check("a pack takes what fits", took == fits, took)
local over = inv.add("astro", "iron", 5)
check("...and refuses what doesn't, partially and honestly", over == 0,
  string.format("took %d more, %.1f kg", over, inv.mass("astro")))
check("...without ever exceeding capacity", inv.mass("astro") <= inv.cap("astro") + 1e-9,
  inv.line("astro"))
local part = inv.add("astro", "fiber", 20)   -- 0.3 kg each; 1.8 kg of room left
check("a partial add reports what actually went in", part > 0 and part < 20, part)

check("discoveries are recorded as things are held", inv.seen("iron") and not inv.seen("uranium"))
check("the pack values itself", inv.totalValue("astro") > 0, inv.totalValue("astro"))
check("contents list in registry order", (function()
  local it = inv.items("astro")
  if #it < 2 then return false end
  return mats.tier(it[1].mat) <= mats.tier(it[#it].mat)
end)())

-- Transfers: what fits moves, the rest stays put. Nothing is ever destroyed.
local before_units = 0
for _, it in ipairs(inv.items("astro")) do before_units = before_units + it.n end
inv.setCap("hold:Kestrel I", 10.0)          -- deliberately tiny
local moved = inv.transferAll("astro", "hold:Kestrel I")
local after_units = 0
for _, it in ipairs(inv.items("astro")) do after_units = after_units + it.n end
for _, it in ipairs(inv.items("hold:Kestrel I")) do after_units = after_units + it.n end
check("a transfer moves only what fits", moved > 0 and moved < before_units, moved)
check("...and loses nothing on the way", after_units == before_units,
  string.format("%d → %d", before_units, after_units))
check("...and the hold respects its own capacity",
  inv.mass("hold:Kestrel I") <= 10.0 + 1e-9, inv.line("hold:Kestrel I"))
inv.setCap("hold:Kestrel I", 60.0)

-- ── 3. the tools ────────────────────────────────────────────────────────────
inv.clear("astro")
inv.clear("hold:Kestrel I")

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + 0.05
    tb.update(ASTRO, 0.05)
    tb.lateUpdate(ASTRO, 0.05)
    clear_presses()
  end
end

check("the belt starts on the gravity gun", tb.toolId() == "gravgun", tb.toolId())
check("...and both tools are issued with the suit",
  inv.gearCount("astro", "gravgun") == 1 and inv.gearCount("astro", "laser") == 1)
press("2")
tick(1)
check("2 picks the Terrain Laser", tb.toolId() == "laser", tb.toolId())
buttons[0] = true
set_depth(0.2)
tick(22)                    -- a short burst: the bore stays in the topsoil
buttons[0] = false
check("holding the laser cuts rock", digs > 0, digs)
check("...a short burst stays shallow", tb.aimDepth < 2.0, tb.aimDepth)
check("...and the pack fills with it", not inv.isEmpty("astro"), inv.line("astro"))
check("...with this world's ore", (function()
  for _, it in ipairs(inv.items("astro")) do
    local ok = false
    for _, m in ipairs(mats.oresOf("canyon")) do if m == it.mat then ok = true end end
    if not ok then return false end
  end
  return true
end)(), inv.items("astro")[1] and inv.items("astro")[1].mat)

-- Deep rock is different rock: same tool, same spot, 40 m down.
local shallow_kinds = {}
for _, it in ipairs(inv.items("astro")) do shallow_kinds[it.mat] = true end
inv.clear("astro")
set_depth(40.0)
buttons[0] = true
tick(120)
buttons[0] = false
-- What "deep materials" means precisely: something the registry GATES behind a
-- minimum depth, and therefore something the shallow haul above could not
-- physically have contained. Asserting a tier-3 rarity instead would be a coin
-- flip on the vein noise; this is a statement about the tool reading depth at
-- all, which is the thing that can actually break.
local function gated(mat)
  for _, b in ipairs(mats.BANDS.canyon) do
    if b.mat == mat then return (b.minDepth or 0) > 0 end
  end
  return false
end
check("nothing depth-gated turns up in the topsoil", (function()
  for m in pairs(shallow_kinds) do if gated(m) then return false end end
  return true
end)(), (function()
  local s = {}
  for m in pairs(shallow_kinds) do s[#s + 1] = m end
  return table.concat(s, ",")
end)())
check("a deep shaft yields deep materials", (function()
  for _, it in ipairs(inv.items("astro")) do
    if gated(it.mat) then return true end
  end
  return false
end)(), (function()
  local s = {}
  for _, it in ipairs(inv.items("astro")) do s[#s + 1] = it.mat end
  return table.concat(s, ",")
end)())

-- A full pack stops taking, and the HUD says why rather than silently voiding.
local fillers = math.ceil(inv.cap("astro") / mats.kg("regolith"))
inv.add("astro", "regolith", fillers)
buttons[0] = true
tick(20)
buttons[0] = false
check("a full pack refuses more and says so",
  inv.mass("astro") <= inv.cap("astro") + 1e-9 and tb.hudLine():find("full") ~= nil,
  tb.hudLine())

-- FILL: the spade's raise, now a mode of the laser — and it is PAID for in
-- rubble from the pack, a unit for `fill_bites` bites.
inv.clear("astro")
inv.add("astro", "regolith", 2)
set_depth(0.0)
ASTRO.x = ASTRO.x + 4.0                      -- back from the face: fill won't bury you
set_camera(ASTRO.x + 4.0)
press("q")
tick(1)
check("Q switches the laser to FILL", tb.laserMode == "fill", tb.laserMode)
local d0 = digs
buttons[0] = true
tick(30)
buttons[0] = false
check("fill lays ground", digs > d0, digs - d0)
check("...out of the pack's rubble", inv.count("astro", "regolith") < 2, inv.count("astro", "regolith"))
inv.clear("astro")
d0 = digs
tb.update(ASTRO, 0.05)
local credit = tb.fillCredit()
buttons[0] = true
tick(40)
buttons[0] = false
check("...and an empty canister lays nothing more than it had", digs - d0 <= credit, digs - d0)
check("...and says why", tb.prompt:find("empty") ~= nil, tb.prompt)
press("q")
tick(1)
check("...and Q goes back to DIG", tb.laserMode == "dig")
set_depth(0.0)

-- ── 3b. the mining laser ────────────────────────────────────────────────────
-- Everything the rewrite added, and everything it fixed.
inv.clear("astro")
press("2")
tick(1)
inv.clear("astro")
set_depth(6.0)

-- THE PREVIEW. Trigger up, crosshair on rock: the tool already knows what is
-- under it. This is the feature that turns aiming into prospecting, and it runs
-- through the same `survey` the yield does, so it cannot lie.
tick(2)
check("the crosshair reads the rock before you fire",
  tb.aimMat ~= nil and tb.aimDist ~= nil, tostring(tb.aimMat))
check("...and the material it names is the one the registry would give",
  tb.aimMat == mats.pickOre("canyon", tb.aimDepth,
    (function()
      -- the same roll survey computes, recomputed here from the same field —
      -- down the same cursor ray the tool aims along, so this is a check on the
      -- registry rather than a second guess at the geometry
      local ox, oy, oz, dx, dy, dz = API.camera.screenToRay(400, 300)
      local h = API.raycast(ox, oy, oz, dx, dy, dz, 60)
      local n1 = math.noise(h.x * 0.035, h.y * 0.035, h.z * 0.035, 4242 % 4096)
      local n2 = math.noise(h.x * 0.19, h.y * 0.19, h.z * 0.19, 4242 % 4096 + 3)
      local mix = (n1 * 0.62 + n2 * 0.38) * 2.5 + 0.5
      return mix - math.floor(mix)
    end)()), tostring(tb.aimMat))

-- REACH IS MEASURED FROM THE PLAYER. The old laser cast from the camera, so
-- scrolling the third-person orbit out quietly ate its range. Shove the camera
-- to the far end of its zoom and the tool must cut exactly as well.
local d0 = digs
set_camera(SURFACE + 18)
buttons[0] = true
tick(20)
buttons[0] = false
tick(2)                              -- frames keep running after you let go
check("zooming the camera out doesn't shorten the beam", digs > d0, digs - d0)
set_camera(ASTRO.x + 4.0)

-- THE BEAM IS ON SCREEN. Played while the trigger is down, aimed at the hit,
-- lighting the ground — and stopped when you let go.
local voices0 = #voices
buttons[0] = true
tick(6)
check("the beam plays from the muzzle while firing", MUZZLE.playing)
check("...aimed at what it hit", MUZZLE.beam ~= nil)
-- The muzzle is the barrel tip of a rifle bone-attached to the hand: the rig
-- puts it where it goes. A script writing world coordinates into its
-- parent-local .x/.y/.z is what threw the beam's origin kilometres into the sky.
-- It may be PLACED in its parent's frame (the barrel tip of the model in the
-- hand, a few tenths of a metre), never written a world coordinate.
check("...and the script never writes a world coordinate into the bone-attached muzzle",
  not MUZZLE.moved or (math.abs(MUZZLE.x) < 1 and math.abs(MUZZLE.y) < 1 and math.abs(MUZZLE.z) < 1),
  string.format("%.2f %.2f %.2f", MUZZLE.x or 0, MUZZLE.y or 0, MUZZLE.z or 0))
check("...with sparks and a light on the rock", IMPACT.playing and IMPACT.light.intensity > 0)
check("...and one looping hum, not a one-shot a frame", (function()
  local n = 0
  for i = voices0 + 1, #voices do
    if voices[i].clip:find("forceField") then n = n + 1 end
  end
  return n == 1
end)(), #voices - voices0)
buttons[0] = false
tick(2)
check("letting go stops the beam", not MUZZLE.playing and not IMPACT.playing)
check("...and puts the light out", IMPACT.light.intensity == 0, IMPACT.light.intensity)
check("...and stops the hum", (function()
  for i = voices0 + 1, #voices do
    if voices[i].clip:find("forceField") and not voices[i].stopped then return false end
  end
  return true
end)())

-- IT GOES WHERE THE CURSOR IS. The whole point of the rewrite: one ray through
-- the pointer, and the ring on the ground lands on what it hit. The earlier
-- "cast from the camera, then re-cast from the muzzle" version put the hit a
-- shoulder-width of parallax away from the aim on any sloped ground, which read
-- as the beam jittering off into the distance on its own.
local real_dig = API.terrain.dig
API.terrain.dig = function() end     -- freeze the face: one spot every frame
cursor.x, cursor.y = 400, 300
buttons[0] = true
tick(40)
local ring_a = outer_ring(tb.params.laser_radius * tb.params.laser_strength)
check("the crosshair ring is drawn on what the beam hit, at the cut radius",
  ring_a ~= nil, last_ring() and last_ring().r)
check("holding the beam on one spot builds focus", tb.focus > 0.3, tb.focus)

-- WHILE THE MOUSE TURNS THE VIEW, THE POINTER IS NOT THE AIM. A grabbed
-- cursor sits hidden wherever the OS left it; the beam must not move.
envs.planet_camera.mouseLooking = true
cursor.x = 780
tick(4)
local ring_stay = outer_ring(tb.params.laser_radius * tb.params.laser_strength)
check("with the mouse grabbed, the OS cursor does not steer the beam",
  ring_stay ~= nil and math.abs(ring_stay.z - ring_a.z) < 0.25,
  ring_stay and string.format("%.2f → %.2f", ring_a.z, ring_stay.z))

-- WITH THE POINTER FREE, IT IS THE AIM: the tool goes where you point.
envs.planet_camera.mouseLooking = false
cursor.x = 560
API.terrain.dig = function() end
buttons[0] = false
tick(2)
buttons[0] = true
tick(6)
local ring_cur = outer_ring(tb.params.laser_radius * tb.params.laser_strength)
check("with the mouse free, the beam follows the cursor",
  ring_cur ~= nil and ring_cur.z - ring_a.z > 0.5,
  ring_cur and string.format("%.2f → %.2f", ring_a.z, ring_cur.z))
-- …but a pointer outside the view is not pointing at anything in it.
cursor.x = 900
tick(6)
local ring_out = outer_ring(tb.params.laser_radius * tb.params.laser_strength)
check("a cursor outside the view aims down the middle",
  ring_out ~= nil and math.abs(ring_out.z - ring_a.z) < 0.25,
  ring_out and string.format("%.2f → %.2f", ring_a.z, ring_out.z))
envs.planet_camera.mouseLooking = nil
cursor.x = 400

look.yaw = 0.45                      -- LOOK somewhere else
tick(4)
local ring_b = outer_ring(tb.params.laser_radius * tb.params.laser_strength)
check("looking somewhere else moves where it mines",
  ring_b ~= nil and math.abs(ring_b.z - ring_a.z) > 1.0,
  ring_b and string.format("%.2f → %.2f", ring_a.z, ring_b.z))
check("...and sweeping the beam away drops the focus bonus", tb.focus < 0.25, tb.focus)
look.yaw = 0.0
API.terrain.dig = real_dig
buttons[0] = false
tick(2)

-- ── IT BORES ────────────────────────────────────────────────────────────────
-- The three failures the bore exists to fix, each as a check that would have
-- caught the shipped version.
inv.clear("astro")
set_depth(1.0)
tick(2)
dug = {}
local ends = {}                      -- where the beam ended, frame by frame
local real_dig2 = API.terrain.dig
buttons[0] = true
for _ = 1, 90 do
  T = T + 0.05
  tb.update(ASTRO, 0.05)
  tb.lateUpdate(ASTRO, 0.05)
  if MUZZLE.beam then ends[#ends + 1] = { MUZZLE.beam[1], MUZZLE.beam[2], MUZZLE.beam[3] } end
  clear_presses()
end
buttons[0] = false

-- 1. EVERY BITE LANDS SOMEWHERE NEW. `terrain.dig` subtracts an analytic ball,
-- so a second dab at the same centre is a no-op: a tool that re-derives its cut
-- point from a raycast digs one ball-deep dish and then nothing, however long
-- you hold it. That was "it barely mines anything", and this is the check.
check("every bite lands somewhere new", (function()
  if #dug < 12 then return false end
  for i = 2, #dug do
    local a, b = dug[i - 1], dug[i]
    if math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) < 1e-4 then
      return false
    end
  end
  return true
end)(), #dug .. " bites")

-- 2. …IN A LINE, AND THEY OVERLAP. Consecutive balls closer together than one
-- radius is what makes a bore a tunnel instead of a string of beads.
check("...spaced closely enough to union into a tunnel", (function()
  local worst = 0
  for i = 2, #dug do
    local a, b = dug[i - 1], dug[i]
    local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    if d > worst then worst = d end
  end
  return worst > 0 and worst < tb.params.laser_radius * tb.params.laser_strength
end)())
check("...and four seconds of trigger is metres of tunnel", tb.bored > 3.0, tb.bored)
check("...which reads as real depth, so deep rock is deep",
  tb.aimDepth > 3.0, tb.aimDepth)

-- 3. THE BEAM DOESN'T SHAKE. The cut point is driven at `bore_speed`, so the
-- frame-to-frame step is that speed times dt — not the metre-plus lurch you get
-- when the collider remeshes a few frames behind the edit and the raycast starts
-- answering with the new face. Ty: "its jittering a lot".
check("the beam end never lurches", (function()
  local step = tb.params.bore_speed * 0.05 * 3.0   -- generous: 3x one frame's travel
  for i = 2, #ends do
    local a, b = ends[i - 1], ends[i]
    local d = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    if d > step then return false, d end
  end
  return #ends > 40
end)(), #ends .. " frames")

-- 4. IT STOPS AT ARM'S LENGTH, AND SAYS SO. A bore that ran to the horizon would
-- make the reach meaningless; one that silently stopped would read as broken.
buttons[0] = true
tick(400)
check("the bore runs out at arm's length", tb.atReach, tb.bored)
check("...and the readout says to walk into the tunnel",
  tb.prompt:find("step into") ~= nil, tb.prompt)
check("...without ever cutting past the tool's reach",
  tb.aimDist <= tb.params.laser_reach + 1e-6, tb.aimDist)
buttons[0] = false
tick(2)

-- 5. AIMING SOMEWHERE ELSE STARTS A NEW HOLE rather than dragging the old one
-- sideways through the mountain.
API.terrain.dig = real_dig2
buttons[0] = true
tick(30)
local deep = tb.bored
look.yaw = 0.48
tick(3)
check("aiming somewhere else re-seats the bore", tb.bored < deep * 0.5,
  string.format("%.1f m → %.1f m", deep, tb.bored))
look.yaw = 0.0
buttons[0] = false
tick(2)
check("letting go ends the bore", tb.bored == 0 and not tb.atReach, tb.bored)

-- 6. THE PLANET IS MOVING WHILE YOU DIG. It orbits a star at tens of units a
-- second, so a cut point remembered as a WORLD position is, one frame later, a
-- point in the sky behind the planet — and a depth measured back to where the
-- hole started is measured to somewhere several kilometres away. Both are held
-- body-relative for exactly this reason. Same hold as before, but with the
-- ground sailing along underneath: the numbers have to come out the same.
inv.clear("astro")
set_depth(1.0)
tick(2)
local moved_ends = {}
buttons[0] = true
for _ = 1, 90 do
  T = T + 0.05
  orbit(4.5)                        -- 90 u/s, the rate a real inner planet moves
  tb.update(ASTRO, 0.05)
  tb.lateUpdate(ASTRO, 0.05)
  if MUZZLE.beam then
    moved_ends[#moved_ends + 1] = { MUZZLE.beam[1] - BODY.x, MUZZLE.beam[2], MUZZLE.beam[3] }
  end
  clear_presses()
end
buttons[0] = false
check("boring works the same on a planet that is orbiting",
  tb.bored > 3.0 and tb.bored < 20.0, tb.bored)
check("...and the beam still doesn't lurch, in the planet's own frame", (function()
  local step = tb.params.bore_speed * 0.05 * 3.0
  for i = 2, #moved_ends do
    local a, b = moved_ends[i - 1], moved_ends[i]
    local d = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    if d > step then return false end
  end
  return #moved_ends > 40
end)(), #moved_ends .. " frames")

-- The planet moves AFTER the tools' update and BEFORE the picture (the rails
-- step it inside the frame). The beam's end must be drawn where the bite
-- actually is on the moved planet — not where the ground was when update ran,
-- which is a few metres behind at orbital speed and different every frame.
dug = {}
local drawn_vs_bite = {}
buttons[0] = true
for _ = 1, 40 do
  T = T + 0.05
  local n0 = #dug
  local bx0 = BODY.x
  tb.update(ASTRO, 0.05)
  orbit(4.5)                        -- the rails, between update and the picture
  tb.lateUpdate(ASTRO, 0.05)
  local bite = dug[#dug]
  if #dug > n0 and MUZZLE.beam then
    drawn_vs_bite[#drawn_vs_bite + 1] = math.abs((MUZZLE.beam[1] - BODY.x) - (bite.x - bx0))
  end
  clear_presses()
end
buttons[0] = false
check("the beam is drawn on the moved planet, where the bite is", (function()
  -- Two seconds of trigger at `laser_rate` 0.24 is eight bites.
  if #drawn_vs_bite < 6 then return false end
  for _, d in ipairs(drawn_vs_bite) do if d > 1.0 then return false end end
  return true
end)(), #drawn_vs_bite .. " frames, first gap " .. tostring(drawn_vs_bite[1]))
tick(2)
-- Put the world back where the rest of the suite expects it.
orbit(-BODY.x)
set_depth(0.0)

-- REACH IS MEASURED FROM THE PLAYER, not from the camera the ray starts at.
-- Shrink it below the distance to the face and the tool must say so rather than
-- cutting something twenty metres away.
local reach0 = tb.params.laser_reach
tb.params.laser_reach = 1.0
tick(2)
check("a hit beyond the tool's reach reads as out of range",
  tb.aimMat == nil and tb.prompt:find("no target") ~= nil, tb.prompt)
tb.params.laser_reach = reach0

-- THE TOOL IS A THING IN YOUR HAND, and only while it's the tool you picked.
local function held(prefab)
  for _, n in ipairs(SPAWNED) do if n.name == prefab and n.parent_ == TOOLNODE then return n end end
end
tick(1)
check("the laser is in the astronaut's hand when it's equipped", held("ToolLaser") and held("ToolLaser").visible)
press("1")
tick(1)
check("...and holstered when it isn't", not held("ToolLaser").visible and held("ToolGravGun").visible)
press("2")
tick(1)
check("...and back out when it is", held("ToolLaser").visible)

-- HEAT THROTTLES, IT NEVER STOPS. Twenty seconds of unbroken fire: heat pegs,
-- and the tool is still mining. A cooldown lockout was written here and thrown
-- away — the complaint this rewrite exists to fix is "I can hardly mine
-- anything", and a tool that answers a held trigger with a disabled bar is that
-- complaint with a progress meter.
inv.clear("astro")
buttons[0] = true
tick(400)
buttons[0] = false
check("sustained fire heats the optics", tb.heat > 0.9, tb.heat)
check("...and still mines while hot", not inv.isEmpty("astro"), inv.line("astro"))
tick(120)
check("...and the barrel cools once you let go", tb.heat < 0.5, tb.heat)

-- OUT OF RANGE says so, rather than silently doing nothing.
local real_ray = API.raycast
API.raycast = function() return nil end
tick(2)
check("nothing in reach reads as no target",
  tb.aimMat == nil and tb.hudLine():find("no target") ~= nil, tb.hudLine())
API.raycast = real_ray
inv.clear("astro")
set_depth(0.0)

-- ── 4. the depot ────────────────────────────────────────────────────────────
inv.clear("astro")
inv.clear("base")
inv.add("astro", "iron", 6)
inv.add("hold:Kestrel I", "timber", 8)
inv.add("hold:Stranded", "crystal", 4)

local holds = fm.landedHolds()
check("the crane sees the craft parked at the base", #holds == 1 and holds[1].id == "hold:Kestrel I",
  #holds .. " hold(s)")
check("...and not the one stranded across the planet", (function()
  for _, h in ipairs(holds) do if h.id == "hold:Stranded" then return false end end
  return true
end)())

local msg = fm.depotUnload()
check("unloading empties the hold and the pack into the warehouse",
  inv.isEmpty("hold:Kestrel I") and inv.isEmpty("astro") and not inv.isEmpty("base"), msg)
check("...and the stranded craft keeps its cargo", inv.count("hold:Stranded", "crystal") == 4)

local bal0 = co.balance()
local rep0 = co.rep()
local worth = inv.totalValue("base")
msg = fm.depotSell()
check("selling empties the warehouse", inv.isEmpty("base"), msg)
check("...and pays for it", co.balance() > bal0 + worth,   -- price + discovery premium
  string.format("%d → %d (goods %d)", bal0, co.balance(), worth))
check("...and a first sale is a discovery", msg:find("NEW DISCOVERY") ~= nil, msg)
-- Standing comes from discovering something RARE, not from selling dirt.
check("...which earns standing only for a rare material",
  (co.rep() > rep0) == (msg:find("Resonant") ~= nil or msg:find("Sulfur") ~= nil
    or msg:find("Obsidian") ~= nil or msg:find("Uranite") ~= nil or msg:find("Resin") ~= nil),
  string.format("%d → %d · %s", rep0, co.rep(), msg))

-- Selling the same material again is just money: the premium is paid once.
inv.add("base", "iron", 4)
local bal1, rep1 = co.balance(), co.rep()
fm.depotSell()
local plain = co.balance() - bal1
check("a repeat sale pays the goods and nothing extra",
  plain > 0 and plain < 150 and co.rep() == rep1, plain)

-- Standing moves the price.
co.addRep(5, "test")
inv.add("base", "iron", 10)
local bal2 = co.balance()
local list = mats.valueOf("iron", 10)
fm.depotSell()
check("reputation pays better", (co.balance() - bal2) > list,
  string.format("%d for a list price of %d", co.balance() - bal2, list))

check("an empty warehouse says so rather than paying zero",
  fm.depotSell():find("empty") ~= nil)

-- ── 4b. the depot SCREEN ────────────────────────────────────────────────────
-- The verbs above worked all along. What didn't was the panel in front of them:
-- the action button was only ever relabelled when there WAS an action, so every
-- other path left the scene's authored placeholder — the word "Action" — sitting
-- on the button. Ty: "i opened the commerce depot and it just showed 'action'."
fm.start({ name = "Facilities Menu" })
inv.clear("astro")
inv.clear("base")
inv.clear("hold:Kestrel I")
local ACT, BODY_N = PANEL["Facility Action"], PANEL["Facility Body"]

fm.openMenu("FacDepot")
check("the depot panel opens", PANEL["Facility Panel"].__el.visible
  and PANEL["Facility Title"].text == "Commerce Depot", PANEL["Facility Title"].text)
check("...and the button NEVER says \"Action\"", ACT.text ~= "Action", ACT.text)
check("...with nothing to sell, it says that in words",
  ACT.text:find("Nothing to sell") ~= nil, ACT.text)

-- Carrying a pack of dirt: ONE press sells it. It used to be two (unload, then
-- sell), and a player pressed once, read "9 units into the warehouse", and
-- walked away with no money and no idea there was a second step.
inv.add("astro", "regolith", 9)
fm.openMenu("FacDepot")
check("a full pack makes the button SELL, with the money on it",
  ACT.text:find("Sell everything") ~= nil and ACT.text:find("%$") ~= nil, ACT.text)
check("...and the panel lists what's in the pack, priced",
  BODY_N.text:find("SUIT PACK") ~= nil and (function()
    for _, e in ipairs(fm.depotStock()) do
      if e.mat == "regolith" and e.n == 9 and e.value > 0 then return true end
    end
    return false
  end)())
check("...and there is no two-step instruction to read",
  BODY_N.text:find("STEP") == nil, BODY_N.text)

local bal4 = co.balance()
fm.action()
check("one press empties the pack AND sells it",
  inv.isEmpty("astro") and inv.isEmpty("base") and co.balance() > bal4,
  string.format("%s · %d → %d", inv.line("base"), bal4, co.balance()))
check("...and the button goes back to saying there's nothing to sell",
  ACT.text:find("Nothing to sell") ~= nil, ACT.text)
fm.close()

-- ── 5. research ─────────────────────────────────────────────────────────────
check("the starter parts need no research",
  rs.isUnlocked("pod") and rs.isUnlocked("tankS") and rs.isUnlocked("engineS"))
check("the rest are locked", not rs.isUnlocked("tankM") and not rs.isUnlocked("dockPort"))

-- A material lock names the sample it wants, and holding one clears it. Mining
-- has already turned copper up by now, so forget it for a moment: the discovery
-- set is the real gate and this is the real path through it.
local seen_set = store["inv.seen"]
seen_set.copper = nil
check("a part gated on a material says which", (function()
  local why = rs.blockedBy("battery")
  return why ~= nil and why:find("Copper") ~= nil
end)(), rs.blockedBy("battery"))
inv.add("astro", "copper", 1)
check("...and finding some clears that gate", rs.blockedBy("battery") == nil,
  rs.blockedBy("battery"))

local bal3 = co.balance()
local ok, why = rs.unlock("battery")
check("researching it works", ok and rs.isUnlocked("battery"), why)
check("...and is paid for", co.balance() == bal3 - rs.costOf("battery"),
  string.format("%d → %d", bal3, co.balance()))
check("...and re-researching is free and harmless", (function()
  local b = co.balance()
  local ok2 = rs.unlock("battery")
  return ok2 and co.balance() == b
end)())

check("a laddered part waits for its prerequisite", (function()
  -- The docking port sits behind RCS, which sits behind the Anvil: the lock
  -- names the NEXT rung, not the whole chain.
  local w = rs.blockedBy("dockPort")
  return w ~= nil and w:find("RCS") ~= nil
end)(), rs.blockedBy("dockPort"))
check("the lock line reads as an instruction", (function()
  local l = rs.lockLine("skipper")
  return l ~= nil and l:find("LOCKED") == 1
end)(), rs.lockLine("skipper"))

-- No money = no research, and nothing half-happens.
co.spend(co.balance(), "test: broke")
inv.add("astro", "iron", 1)
rs.unlock("engineM")           -- clear the ladder for skipper
local ok2, why2 = rs.unlock("skipper")
check("a company that can't pay doesn't get the tech",
  not ok2 and not rs.isUnlocked("skipper"), why2)
check("...and the balance is untouched", co.balance() == 0, co.balance())

check("the pending list explains everything still locked", (function()
  local lines = rs.pendingLines()
  if #lines == 0 then return false end
  for _, l in ipairs(lines) do if not l:find("LOCKED") then return false end end
  return true
end)(), #rs.pendingLines() .. " locked")

-- ── ore seams are fixed to the ground ───────────────────────────────────────
-- The planet orbits at tens of metres a second. `survey` reads its noise in the
-- planet's own frame, so the same rock reads the same however far the planet
-- has travelled — in world coordinates the seams slid past at orbital speed.
do
  local px, py, pz = BODY.x, BODY.y, BODY.z
  local same, total = 0, 0
  for i = 1, 24 do
    local lx, ly, lz = BODY.radius * math.cos(i), (i % 5) * 3.0, BODY.radius * math.sin(i)
    BODY.x, BODY.y, BODY.z = px, py, pz
    local a = tb.survey(px + lx, py + ly, pz + lz)
    BODY.x, BODY.y, BODY.z = px + 873.5, py - 41.2, pz + 1290.7   -- the planet moved on
    local b = tb.survey(BODY.x + lx, BODY.y + ly, BODY.z + lz)
    total = total + 1
    if a == b then same = same + 1 end
  end
  BODY.x, BODY.y, BODY.z = px, py, pz
  check("an ore seam stays put on the ground as the planet orbits", same == total,
    string.format("%d/%d spots read the same", same, total))
end

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("RESOURCE SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("RESOURCE SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
print("\n-- script logs --")
for i = math.max(1, #logs - 24), #logs do print("  " .. tostring(logs[i])) end
os.exit(1)
