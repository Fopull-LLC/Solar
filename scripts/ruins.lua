-- RUINS — abandoned bases on the worlds that were lived on (expansion X8,
-- work/expansion/PLAN.md §5; docs/base-building.md §26). Ty, 11-09:
-- "abandoned bases on inhabited or previously inhabited planets. There's no
-- planet life system yet, so combat is pointless for now."
--
-- On the Build Kit node (scenes/system.ron) beside structures.lua. The rules
-- half is pure (it loads in a luajit test: tests/smoke_ruins.lua); the scene
-- half sites, stamps, unstamps and discovers, and serves the right-click rows.
--
-- ── SITES (pure, from the world seed: nothing saved until something happens)
--   worldClass(name, w, home) → "inhabited" (air over 0.15, or a home) |
--             "past" (a rocky airless or thin world whose seed rolled a warm
--             past: PAST_CHANCE of the PAST_FAMILY worlds) | "none"
--   sitesFor(name, w, home, R) → { site … }: inhabited 1–3 (and one more
--             `pending`: reserved for the life system, never stamped or
--             found), past 1–2, none a NONE_CHANCE of one survey camp.
--   site = { id = "<body>#<i>", body, kind, ux, uy, uz (unit direction from
--             the body's centre), age (days), yaw, seed, co (the company),
--             num, name ("Pell Survey Camp 3"), pending?, life = nil }
-- KINDS (each a grammar over the Build Kit's own pieces, so a claimed ruin
-- is a base you repair, power and build on): camp, mine, hab, reactor, relay.
--   blueprintOf(site) → pieces { id, x, y, z, yaw, pitch, roll, paint, rl
--             (role), dep (the piece it hangs on) } in the site's frame
--   decay(pieces, site) → kept (each with ri = its index in the full build,
--             and o_p / o_r / o_c / wr when it was knocked or rusted), stats.
--             Roofs go first (30–60 % by age), then 10–30 % of the walls;
--             slabs, floors, doors, the tower, the terminal, the crates and
--             the silo never; windows break to open frames; one piece in six
--             leans 6–12°; props topple; grime on one wall in four.
--   recordOf(site, g, kept, now) → a structures record (`ru` = the site id,
--             `t` back-dated by the age: instant dust, kit_paint.dustOf;
--             every light off; a battery flat)
--   coreReward(site, mult) → { rp, lore = { lines }, layer }
--   occupant(site) → nil   THE LIFE SEAM: "who lives here now". A life system
--             fills it; sites carry life = nil. DEFENCE waits for it.
--
-- ── THE SCENE HALF ──────────────────────────────────────────────────────────
--   STAMPED   once a second: the sites of the focus's world within STAMP_R
--             (along the ground) are sited (siteGround: 9 field raycasts,
--             flat to FLAT_SPREAD over 11 m, dry, clear of the spaceport, the
--             bases and anything built; up to SITE_TRIES spots, else the site
--             is dropped), decayed and written as a structure; structures.lua
--             streams it in by distance (ruin_in / ruin_out) and paces its
--             spawn (`pace` parts a frame). Past UNSTAMP_R an UNTOUCHED ruin
--             is taken out of the records again (it comes back the same: the
--             seed); a touched one (a crate searched, the core pulled, a
--             piece taken or mended, a claim) stays, unloaded far away.
--   FOUND     by the crew within DISCOVER_R, by an Orbital Scanner's swath
--             over its cell (survey.swathOf), or by a telescope sweep of its
--             world (survey.credit tells telescopeSwept: a 0.3 m finds one, a
--             1 m every one). The Tracking Station lists it then (fleet_view
--             kind `ruin`).
--   LOOT      crates ("crate:ruin.<site>.<ri>" containers, filled once from
--             the site's seed: o2 tanks, a repair kit, ore samples);
--             a mine's silo is filled with what the world's rock holds.
--   THE CORE  "Pull the Data Core" at the terminal: a 6 kg item; carried
--             into the home Research Lab it is read (RP by kind, × the
--             carrier's study_mult; the last log; the site's blueprint saved
--             to the library; a survey layer).
--   CLAIMING  an Engineer's "Claim the site" on its tower: the tower founds a
--             base under the site's name (base_tower.reconcile asks
--             towerHeld), so its grid, its roles (base_roles), its repairs
--             and runs are a base's. Then: "Repair" a knocked piece (a Repair
--             Kit, 4 s) and "Restore the missing pieces" at the tower (the
--             pieces' price, one bill).
--
-- SAVE: ruins.s = { [site id] = { g = { x, y, z, ux, uy, uz, fx, fy, fz }
--   (the sited frame, body-relative), dsc (how found), dt (when), sid, n
--   (the stamped piece count), tc (touched), core (pulled), read, cl
--   (claimed), lf (crates filled: ",3,7,"), silo, drop (no room) } };
--   ruins.cores = { site id … } the cores pulled and not yet read (FIFO).
-- An old save has neither: every site is new, nothing changes until the crew
-- comes near one.
--
-- COST: once a second, a few distances for the focus world's 1–3 sites; a
-- scanner look every SCAN_EVERY s (a mask lookup a site); nothing a frame.
-- A stamped ruin is static kit pieces (the S11 rule), drawn only near.
--
-- AUTHORED (scenarios2 F8): stampAuthored(def, pieces, g, now) stamps a
--   scenario's blueprint as a ruin (authoredSite, decayAuthored: the
--   author's gone / knocked / broken pieces, the dice only rust and grime);
--   it is registered in ruins.x, so claim, crates (`loot`), repair, restore
--   (`lots`: named jobs at the author's prices) and the LOG (`lore`) work.
--
-- Probes: sites(body), site(id), state(id), discover(id, how), stampNow(id),
-- unstampNow(id), claim(id), pullCore(id, pack), readCores(pack),
-- restoreQuote(id), restore(id), repairPiece(sid, uid), stats.

STAMP_R = 600.0        -- m along the ground: a site this near the focus is stamped
UNSTAMP_R = 900.0      -- m: an untouched ruin this far is taken out again
DISCOVER_R = 420.0     -- m: the crew finds a ruin this near
SCAN_EVERY = 5.0       -- s between looks at the scanners' swaths
FLAT_SPREAD = 1.6      -- m: the most the ground may rise over the 11 m round the site
SITE_TRIES = 10       -- spots tried round a site (50 m further out each), on dry flat ground
HOME_MIN = 450.0       -- m from the spaceport's middle
BASE_MIN = 320.0       -- m from a base's tower (towers stand 300 m apart)
BUILT_MIN = 150.0      -- m from anything built
PAST_CHANCE = 0.20
NONE_CHANCE = 0.10
PAST_FAMILY = { barren = true, frost = true, canyon = true, dune = true, crystal = true, ice = true }
RP = { camp = 60, mine = 120, hab = 150, reactor = 300, relay = 90 }
LABEL = { camp = "survey camp", mine = "mine head", hab = "hab block", reactor = "power hall", relay = "relay post" }
NOUN = { camp = "Survey Camp", mine = "Mine Head", hab = "Habitat", reactor = "Power Hall", relay = "Relay Post" }
WEIGHTS = {
  inhabited = { { "hab", 3 }, { "camp", 2 }, { "relay", 2 }, { "mine", 2 }, { "reactor", 1 } },
  past      = { { "camp", 3 }, { "mine", 2 }, { "hab", 2 }, { "relay", 1 } },
  none      = { { "camp", 1 } },
}
AGES = { inhabited = { 400, 2500 }, past = { 2500, 6000 }, none = { 400, 1500 } }
-- the companies that prospected these worlds before the agency (the lore's;
-- the first two are N1's suppliers, whose marks the kit carries)
COMPANIES = { "Pell Groundworks", "Halden Structural", "Varro Extraction", "Okafor Survey", "Tessaly Orbital",
              "Brannock Energy", "Kestrel Relay", "Ashdown Habitats", "Morrow & Daughters", "Ilse Geophysical" }
SHORT = { "Pell", "Halden", "Varro", "Okafor", "Tessaly", "Brannock", "Kestrel", "Ashdown", "Morrow", "Ilse" }

version = 0
stats = { ms = 0, stamps = 0, unstamps = 0, found = 0, pieces = 0, scans = 0 }

local Q = math.pi / 2
local T = 0.2          -- a slab's top
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- ── pure: numbers from a seed ───────────────────────────────────────────────
function hash(s)
  s = tostring(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end
-- Park–Miller in doubles (exact: the product stays under 2^53)
function rng(seed)
  local s = math.floor(seed or 1) % 2147483646 + 1
  local function nx() s = (s * 16807) % 2147483647; return s / 2147483647 end
  nx(); nx()
  return nx
end
local function pick(r, list)
  local tot = 0
  for _, e in ipairs(list) do tot = tot + e[2] end
  local x = r() * tot
  for _, e in ipairs(list) do
    x = x - e[2]
    if x <= 0 then return e[1] end
  end
  return list[#list][1]
end

-- ── pure: which worlds, which sites ─────────────────────────────────────────
function worldClass(name, w, home)
  w = type(w) == "table" and w or {}
  local geo = type(w.geo) == "table" and w.geo or {}
  if home or geo.home or geo.alienHome or (w.atmo or 0) > 0.15 then return "inhabited" end
  local fam = geo.family or w.kind
  if fam and PAST_FAMILY[fam] then
    local r = rng(hash(tostring(name) .. ":" .. tostring(w.seed or 0) .. ":past"))
    if r() < PAST_CHANCE then return "past" end
  end
  return "none"
end

function siteName(co, kind, num)
  return string.format("%s %s %d", SHORT[co] or "Pell", NOUN[kind] or "Camp", num)
end

-- The sites of a world (deterministic: the same list every session).
function sitesFor(name, w, home, R)
  w = type(w) == "table" and w or {}
  local class = worldClass(name, w, home)
  local r = rng(hash(tostring(name) .. ":" .. tostring(w.seed or 0) .. ":ruins"))
  local n
  if class == "inhabited" then n = 1 + math.floor(r() * 3)
  elseif class == "past" then n = 1 + math.floor(r() * 2)
  else n = (r() < NONE_CHANCE) and 1 or 0 end
  local pend = class == "inhabited" and 1 or 0
  R = R or w.radius or 800
  -- (sites keep apart: 300 m along the ground, or as far as a small moon allows)
  local apart = math.cos(math.min(300 / R, 1.0))
  local out = {}
  local ages = AGES[class]
  for i = 1, n + pend do
    local ux, uy, uz
    for _ = 1, 12 do
      local z = 2 * r() - 1
      local ph = 2 * math.pi * r()
      local s = math.sqrt(math.max(0, 1 - z * z))
      ux, uy, uz = s * math.cos(ph), z, s * math.sin(ph)
      local ok = true
      for _, o in ipairs(out) do if ux * o.ux + uy * o.uy + uz * o.uz > apart then ok = false end end
      if ok then break end
    end
    local kind = pick(r, WEIGHTS[class])
    local co = 1 + math.floor(r() * #COMPANIES)
    local num = 1 + math.floor(r() * 9)
    local site = { id = tostring(name) .. "#" .. i, body = name, kind = kind, ux = ux, uy = uy, uz = uz, class = class,
                   age = math.floor(ages[1] + r() * (ages[2] - ages[1])), yaw = r() * 2 * math.pi,
                   seed = math.floor(r() * 2147483000) + 1, co = co, num = num, name = siteName(co, kind, num), life = nil }
    if i > n then site.pending = true end
    out[#out + 1] = site
  end
  return out
end

-- THE LIFE SEAM: who lives at a site now. Nothing yet (no planet life); a
-- life system fills this, and the pending sites are where it starts.
function occupant(site) return nil end

-- ── pure: the grammars (kit pieces in the site's frame: +X right, +Y up,
-- +Z front; a slab's ground point at y = 0, its top at T) ──────────────────
local function builder()
  local P = {}
  local function add(id, x, y, z, yaw, pitch, roll, paint, rl, dep, extra)
    P[#P + 1] = { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0, paint = paint,
                  rl = rl or "prop", dep = dep }
    if extra then for k, v in pairs(extra) do P[#P][k] = v end end
    return #P
  end
  return P, add
end
local function mark(co) return (co % 2 == 0) and "decalHalden.film" or "decalPell.film" end

-- A 2 × 2 m shack with an open front at (ox, oz): a bench, tools, drums.
local function shack(add, ox, oz, paint, core)
  add("slab2.concrete", ox, 0, oz, 0, 0, 0, nil, "slab")
  add("openFrame.steel", ox, T, oz + 1, 0, 0, 0, paint, "door")
  local wb = add("wall.steel", ox, T, oz - 1, math.pi, 0, 0, paint, "wall")
  local wl = add("wall.steel", ox - 1, T, oz, -Q, 0, 0, paint, "wall")
  add("wall.steel", ox + 1, T, oz, Q, 0, 0, paint, "wall")
  add("floor.steel", ox, T + 2.2, oz, 0, 0, 0, "gunmetal", "roof")
  -- (Ty 11-10, z-fighting: at oz - 0.55 the pegboard's face lay in the back wall's; 5 mm clear of it now)
  local bench = add("workbench.steel", ox, T, oz - 0.52, 0, 0, 0, "oxide", "fix")
  add("toolRack.steel", ox - 0.9, T + 1.45, oz + 0.2, Q, Q, 0, nil, "mount", wl)
  if core then add("monitor.steel", ox + 0.3, T + 0.92, oz - 0.6, 0, 0, 0, nil, "core", bench) end
  -- (Ty 11-10: "things blocking doorways": the drum stood in the open front; outside beside it now)
  add("drum.steel", ox + 1.45, 0, oz + 1.5, 0, 0, 0, "orange", "prop")
  return wb
end

local GRAMMAR = {}
-- SURVEY CAMP: a 4 × 4 crew hut, a tool shack, the tower, crates and drums.
GRAMMAR.camp = function(site)
  local P, add = builder()
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do add("slab2.concrete", s[1], 0, s[2], 0, 0, 0, nil, "slab") end
  add("doorWall.steel", 0, T, 3, 0, 0, 0, "hull", "door")
  add("windowWall.steel", 2, T, 3, 0, 0, 0, "hull", "wall")
  local wb = add("wall.steel", 0, T, -1, math.pi, 0, 0, "hull", "wall")
  add("wall.steel", 2, T, -1, math.pi, 0, 0, "hull", "wall")
  add("windowWall.steel", -1, T, 0, -Q, 0, 0, "hull", "wall")
  add("wall.steel", -1, T, 2, -Q, 0, 0, "hull", "wall")
  local ws = add("wall.steel", 3, T, 0, Q, 0, 0, "hull", "wall")
  add("wall.steel", 3, T, 2, Q, 0, 0, "hull", "wall")
  local roof = {}
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do roof[#roof + 1] = add("floor.steel", s[1], T + 2.2, s[2], 0, 0, 0, "gunmetal", "roof") end
  add("lightFitting.steel", 1, T + 2.2, 1, 0, math.pi, 0, nil, "light", roof[4])
  add("bunk.steel", 0.1, T, -0.4, 0, 0, 0, "olive", "fix")
  local tb = add("table.steel", 1.75, T, 1.5, Q, 0, 0, nil, "fix")
  add("monitor.steel", 1.75, T + 0.74, 1.5, Q, 0, 0, nil, "core", tb)
  add("chair.steel", 0.95, T, 1.5, Q, 0, 0, nil, "prop")
  add("chair.steel", 2.55, T, 1.5, -Q, 0, 0, nil, "prop")
  add("shelf.steel", 2.6, T, 0.0, -Q, 0, 0, nil, "fix")
  add("crateS.steel", 2.6, T, 2.55, 0, 0, 0, "orange", "loot")
  add(mark(site.co), 3.1, T + 1.3, 0, Q, Q, 0, nil, "decal", ws)
  add("grimeStreaks.film", 0.0, T + 1.1, -1.1, math.pi, Q, 0, nil, "decal", wb)
  shack(add, 7, 0, "olive", false)
  add("tower", -5, 0, -4, 0, 0, 0, nil, "tower")
  add("crate.steel", 4.6, 0, 3.2, 0.3, 0, 0, "olive", "loot")
  add("drum.steel", -1.8, 0, 3.4, 0, 0, 0, "orange", "prop")
  add("drum.steel", -2.5, 0, 3.0, 0, 0, 0, "oxide", "prop")
  add("cableReel.steel", 5.0, 0, -2.5, 0.6, 0, 0, nil, "prop")
  -- (the interaction plan S5: a personnel locker by the hut's west wall; appended, so every
  -- piece before it keeps its index: ri)
  add("locker.steel", -0.64, T, 1.2, Q, 0, 0, "olive", "store")
  return P
end
-- HAB BLOCK: the two-storey hab (the fullbuilder's, kit pieces only): an
-- airlock, the life support (an O2 generator, a scrubber, an air tank), the
-- terminal upstairs; the tower and its crates outside.
GRAMMAR.hab = function(site)
  local P, add = builder()
  for _, s in ipairs({ { 0, 0 }, { 0, -2 }, { 2, 0 }, { 2, -2 } }) do add("slab2.concrete", s[1], 0, s[2], 0, 0, 0, nil, "slab") end
  -- (Ty 11-10: "the stairs going up to the entrance doorway I had to get on it and crouch to get
  -- inside": Steps 0.8 m stood on the ground 0.5 m out, their top 0.6 m over the sill. Now their
  -- top tread is the slab's top, butted to its edge under the door, the lower treads in the ground)
  add("steps.steel", -0.46, T - 0.8, 1.5, 0, 0, 0, nil, "fix")
  local wb = add("wall.steel", 0, T, -3, math.pi, 0, 0, "bone", "wall")
  add("porthole.steel", 2, T, -3, math.pi, 0, 0, "bone", "wall")
  add("airlockWall.steel", 0, T, 1, 0, 0, 0, "bone", "door")
  add("windowWall.steel", 2, T, 1, 0, 0, 0, "bone", "wall")
  local ws = add("wall.steel", 3, T, 0, Q, 0, 0, "bone", "wall")
  add("windowWall.steel", 3, T, -2, Q, 0, 0, "bone", "wall")
  add("wall.steel", -1, T, 0, -Q, 0, 0, "bone", "wall")
  add("wall.steel", -1, T, -2, -Q, 0, 0, "bone", "wall")
  add("airlockWall.steel", 0, T, -1, 0, 0, 0, "bone", "door")
  add("wall.steel", 1, T, 0, Q, 0, 0, "bone", "wall")
  -- (the ladder climbs north to the edge of an open well over x 1..3, z -3..0: its head clears the
  -- floor all the way up, and its top tread is the floor's top at that edge)
  add("ladder.steel", 2.2, T, -1.1, math.pi, 0, 0, nil, "fix")
  add("o2gen.steel", -0.3, T, -2.4, 0, 0, 0, nil, "fix")
  add("scrubber.steel", 0.65, T, -2.5, 0, 0, 0, nil, "fix")
  add("airReceiver.steel", 0.44, T, 0.0, 0, 0, 0, nil, "fix")      -- (beside the doors' path, not across it)
  local f = {}
  f[1] = add("floor.steel", 0, 2.4, 0, 0, 0, 0, "gunmetal", "floor")
  f[2] = add("floor21.steel", 2, 2.4, 0.5, 0, 0, 0, "gunmetal", "floor")
  add("floor.steel", 0, 2.4, -2, 0, 0, 0, "gunmetal", "floor")
  add("rail.steel", 0.96, 2.6, -1.85, Q, 0, 0, nil, "fix")   -- (the well's west edge, its feet on the floor, clear of the back wall)
  add("lightFitting.steel", 2, 2.4, 0.5, 0, math.pi, 0, nil, "light", f[2])
  add("lightFitting.steel", 0, 2.4, 0, 0, math.pi, 0, nil, "light", f[1])
  add("wall.steel", 0, 2.6, -3, math.pi, 0, 0, "bone", "wall")
  add("wall.steel", 2, 2.6, -3, math.pi, 0, 0, "bone", "wall")
  add("windowWall.steel", 0, 2.6, 1, 0, 0, 0, "bone", "wall")
  add("wall.steel", 2, 2.6, 1, 0, 0, 0, "bone", "wall")
  add("porthole.steel", 3, 2.6, 0, Q, 0, 0, "bone", "wall")
  add("wall.steel", 3, 2.6, -2, Q, 0, 0, "bone", "wall")
  add("wall.steel", -1, 2.6, 0, -Q, 0, 0, "bone", "wall")
  add("windowWall.steel", -1, 2.6, -2, -Q, 0, 0, "bone", "wall")
  add("airTank.steel", 0, 2.6, -2.6, 0, 0, 0, nil, "fix")
  add("bunk.steel", 0.1, 2.6, 0.45, math.pi, 0, 0, "olive", "fix")
  local tb = add("table.steel", 0.1, 2.6, -1.55, 0, 0, 0, nil, "fix")
  add("monitor.steel", 0.1, 2.6 + 0.74, -1.6, 0, 0, 0, nil, "core", tb)
  add("chair.steel", 0.1, 2.6, -0.9, math.pi, 0, 0, nil, "prop")
  local roof = {}
  for _, s in ipairs({ { 0, 0 }, { 0, -2 }, { 2, 0 }, { 2, -2 } }) do roof[#roof + 1] = add("floor.steel", s[1], 4.8, s[2], 0, 0, 0, "gunmetal", "roof") end
  add("lightFitting.steel", 1, 4.8, -1, 0, math.pi, 0, nil, "light", roof[1])
  add(mark(site.co), 3.1, T + 1.3, -2, Q, Q, 0, nil, "decal", ws)
  add("grimeStreaks.film", 0, T + 1.1, -3.1, math.pi, Q, 0, nil, "decal", wb)
  add("tower", -6, 0, -5, 0, 0, 0, nil, "tower")
  add("crate.steel", 5, 0, 1.5, 0.2, 0, 0, "olive", "loot")
  add("crateS.steel", 5.2, 0, 0.4, 0, 0, 0, "orange", "loot")
  add("drum.steel", -2.4, 0, 1.6, 0, 0, 0, "oxide", "prop")
  -- (S5) a locker beside the scrubber, clear of the ladder's foot; a store cabinet upstairs
  -- between the table and the bunk
  add("locker.steel", 1.38, T, -2.64, 0, 0, 0, "bone", "store")
  add("cabinet.steel", -0.64, 2.6, -0.6, Q, 0, 0, "olive", "store")
  return P
end
-- POWER HALL: the reactor shed with its core pulled (the vessel base, the
-- lattice and the rods are gone: nothing for reactor_plant to run), its
-- loops, turbine and console left; shield blocks knocked over outside.
GRAMMAR.reactor = function(site)
  local P, add = builder()
  for x = 0, 8, 2 do for z = 0, -10, -2 do add("slab2.concrete", x, 0, z, 0, 0, 0, nil, "slab") end end
  local walls = {}
  for _, st in ipairs({ { T, "wall.steel" }, { 2.4, "ventWall.steel" } }) do
    local y, id = st[1], st[2]
    for z = 0, -10, -2 do
      walls[#walls + 1] = add(id, -1, y, z, -Q, 0, 0, "gunmetal", "wall")
      walls[#walls + 1] = add(id, 9, y, z, Q, 0, 0, "gunmetal", "wall")
    end
    for x = 0, 8, 2 do walls[#walls + 1] = add(id, x, y, -11, math.pi, 0, 0, "gunmetal", "wall") end
    if y == T then
      walls[#walls + 1] = add(id, 0, y, 1, 0, 0, 0, "gunmetal", "wall")
      walls[#walls + 1] = add(id, 2, y, 1, 0, 0, 0, "gunmetal", "wall")
      add("doubleDoor.steel", 5, y, 1, 0, 0, 0, "gunmetal", "door")
      walls[#walls + 1] = add(id, 8, y, 1, 0, 0, 0, "gunmetal", "wall")
    else
      for x = 0, 8, 2 do walls[#walls + 1] = add(id, x, y, 1, 0, 0, 0, "gunmetal", "wall") end
    end
  end
  local roof = {}
  for x = 0, 8, 2 do for z = 0, -10, -2 do roof[#roof + 1] = add("floor.steel", x, 4.6, z, 0, 0, 0, "gunmetal", "roof") end end
  add("lightFitting.steel", 4, 4.6, -5, 0, math.pi, 0, nil, "light", roof[15])
  add("lightFitting.steel", 4, 4.6, -1, 0, math.pi, 0, nil, "light", roof[13])
  add("lightFitting.steel", 4, 4.6, -9, 0, math.pi, 0, nil, "light", roof[17])
  add("pipe2.steel", 4, T, -4.5, 0, 0, 0, nil, "fix")
  add("coolantPump.steel", 4, T, -6.5, math.pi, 0, 0, nil, "fix")
  add("steamGen.steel", 3.5, T, -8.5, math.pi, 0, 0, nil, "fix")
  add("turbineSet.steel", 3, T, -10.5, math.pi, 0, 0, nil, "fix")
  add("pressuriser.steel", 6.4, T, -6.4, 0, 0, 0, nil, "fix")
  add("reactorConsole.steel", 7.6, T, -1, -Q, 0, 0, nil, "core")
  add("radiatorPanel.steel", 11.5, 0, -6, Q, 0, 0, nil, "fix")
  add("drum.steel", 3.6, T, -2.2, 0, 0, 0, "oxide", "prop")
  add("drum.steel", 4.4, T, -1.8, 0, 0, 0, "oxide", "prop")
  -- (west of the double door's approach, not across it)
  for i = 0, 5 do add("shieldBlock.concrete", -3.5 + i * 1.25, 0, 3.4 + (i % 2) * 0.6, i * 0.4, 0, (i % 3 == 0) and Q or 0, nil, "prop") end
  add(mark(site.co), 9.1, T + 1.3, -4, Q, Q, 0, nil, "decal", walls[4])
  add("tower", -5, 0, 4, 0, 0, 0, nil, "tower")
  add("crate.steel", 10.5, 0, 1.5, 0.4, 0, 0, "olive", "loot")
  add("crateS.steel", 7.6, T, -3.2, 0, 0, 0, "orange", "loot")
  -- (S5) the shift's store cabinet and a locker on the east wall
  add("cabinet.steel", 8.64, T, -8.5, -Q, 0, 0, "gunmetal", "store")
  add("locker.steel", 8.64, T, -9.6, -Q, 0, 0, "gunmetal", "store")
  return P
end
-- RELAY POST: a tower on its pads, a mast of truss (one length fallen), a
-- battery cabinet run flat, two solar arrays blown over, the junction box
-- (the terminal) and a transformer.
GRAMMAR.relay = function(site)
  local P, add = builder()
  for _, s in ipairs({ { 0, 0 }, { 2, 0 }, { 4, 0 }, { 0, -2 }, { 2, -2 }, { 4, -2 } }) do add("slab2.concrete", s[1], 0, s[2], 0, 0, 0, nil, "slab") end
  add("tower", 2, T, -1, 0, 0, 0, nil, "tower")
  add("batteryBank", 4.3, T, 0.2, 0, 0, 0, nil, "power", nil, { fill = 0 })
  add("junctionBox.steel", 0.0, T, -2.4, math.pi, 0, 0, nil, "core")
  add("transformer.steel", 4.2, T, -2.3, math.pi, 0, 0, nil, "fix")
  add("solarArray", -3.5, 0, 0.5, 0, 0, 1.2, nil, "array")
  add("solarArray", -3.5, 0, -3, 0, 0, -1.1, nil, "array")
  add("truss6.steel", 8, 0, -1, 0, 0, 0, nil, "fix")
  local up = add("truss6.steel", 8, 6, -1, 0, 0, 0, nil, "roof")
  add("trussNode.steel", 8, 12, -1, 0, 0, 0, nil, "mount", up)
  add("truss6.steel", 9, 0.25, 2, 0.5, Q, 0, nil, "prop")
  add("cableReel.steel", 6, 0, 1.5, 0.4, 0, 0, nil, "prop")
  add("crate.steel", -1.5, 0, 2.8, 0.2, 0, 0, "olive", "loot")
  add("crateS.steel", 1.2, T, 0.7, 0, 0, 0, "orange", "loot")
  add("drum.steel", 5.8, 0, -3.4, 0, 0, 0, "oxide", "prop")
  return P
end
-- MINE HEAD: a gantry over a silo (its digging head long gone), a bench
-- shack with the terminal, drums and crates; the silo holds what the
-- world's rock holds.
GRAMMAR.mine = function(site)
  local P, add = builder()
  for x = 0, 4, 2 do for z = 0, -4, -2 do add("slab2.concrete", x, 0, z, 0, 0, 0, nil, "slab") end end
  for _, c in ipairs({ { 0, 0 }, { 4, 0 }, { 0, -4 }, { 4, -4 } }) do add("pillar4.steel", c[1], T, c[2], 0, 0, 0, "oxide", "fix") end
  add("beam4.steel", 2, T + 4.4, 0, 0, 0, 0, "oxide", "roof")
  add("beam4.steel", 2, T + 4.4, -4, 0, 0, 0, "oxide", "roof")
  add("beam4.steel", 0, T + 4.403, -2, Q, 0, 0, "oxide", "roof")
  add("beam4.steel", 4, T + 4.403, -2, Q, 0, 0, "oxide", "roof")
  add("lgHopper.steel", 2, T, -2, 0, 0, 0, nil, "silo")
  add("beam4.steel", 6.5, 0, -6, 0.7, 0, Q, "oxide", "prop")
  shack(add, 9, -1, "oxide", true)
  add("tower", -5, 0, 3, 0, 0, 0, nil, "tower")
  add("crate.steel", 6.5, 0, 2.5, 0.3, 0, 0, "olive", "loot")
  add("crateS.steel", 7.7, 0, 2.6, 0, 0, 0, "orange", "loot")
  add("drum.steel", -1.6, 0, 1.8, 0, 0, 0, "oxide", "prop")
  add("drum.steel", -2.2, 0, 1.1, 0, 0, 0, "orange", "prop")
  add("drum.steel", 6, 0, -3.5, 0, 0, 0, "oxide", "prop")
  add("cableReel.steel", -1.8, 0, -3, 1.0, 0, 0, nil, "prop")
  return P
end

function blueprintOf(site)
  if site and site.full then return site.full end      -- (F8) an authored ruin's own blueprint
  local g = GRAMMAR[site and site.kind] or GRAMMAR.camp
  local P = g(site)
  if site and site.near and nearExtras then nearExtras(site, P) end   -- (R1: THE RUIN NEAR HOME below)
  return P
end
function kinds() return { "camp", "mine", "hab", "reactor", "relay", "sinkcamp" } end

-- ── pure: decay ─────────────────────────────────────────────────────────────
local GLASS = { ["windowWall.steel"] = true, ["porthole.steel"] = true }
local TOPPLE = { ["chair.steel"] = true, ["drum.steel"] = true, ["cableReel.steel"] = true, ["shieldBlock.concrete"] = true }
local GRIME = { "grimeStreaks.film", "grimeLeak.film", "grimeSoot.film" }
WT = 0.2               -- a wall's thickness (parts_kit WT)
function decay(pieces, site)
  local r = rng((site and site.seed) or 1)
  local ageK = clamp(((site and site.age or 400) - 400) / 5600, 0, 1)
  local roofShare = clamp(0.30 + 0.30 * ageK + 0.10 * (r() - 0.5), 0.30, 0.60)
  local wallShare = clamp(0.10 + 0.20 * ageK + 0.06 * (r() - 0.5), 0.10, 0.30)
  local gone = {}
  local kept = {}
  local st = { total = #pieces, roofs = 0, roofsGone = 0, walls = 0, wallsGone = 0, broken = 0, tilted = 0, toppled = 0, grime = 0, rust = 0 }
  for i, p in ipairs(pieces) do
    local drop = false
    if p.rl == "roof" then
      st.roofs = st.roofs + 1
      if r() < roofShare then drop = true; st.roofsGone = st.roofsGone + 1 end
    elseif p.rl == "wall" then
      st.walls = st.walls + 1
      if r() < wallShare then drop = true; st.wallsGone = st.wallsGone + 1 end
    elseif p.rl == "light" then
      if r() < 0.25 then drop = true end
    end
    if p.dep and gone[p.dep] then drop = true end
    if drop then
      gone[i] = true
    else
      local e = {}
      for k, v in pairs(p) do e[k] = v end
      e.dep = nil
      e.ri = i
      if p.rl == "wall" and GLASS[p.id] and r() < 0.5 then
        e.o_id = p.id; e.id = "openFrame.steel"; st.broken = st.broken + 1
      end
      if TOPPLE[p.id] and p.rl == "prop" and r() < 0.34 then
        e.o_r = e.roll; e.roll = Q; e.wr = 0.5; st.toppled = st.toppled + 1
      elseif (p.rl == "wall" or p.rl == "prop" or p.rl == "fix" or p.rl == "array") and r() < 1 / 6 then
        local a = math.rad(6 + 6 * r()) * (r() < 0.5 and -1 or 1)
        if p.rl == "wall" then e.o_p = e.pitch; e.pitch = (e.pitch or 0) + a
        else e.o_r = e.roll; e.roll = (e.roll or 0) + a end
        e.wr = 0.3 + 0.4 * r()
        st.tilted = st.tilted + 1
      end
      if p.rl == "array" then e.wr = e.wr or 0.6; e.o_r = 0 end
      if p.rl == "wall" and r() < 0.35 then e.o_c = p.paint or ""; e.paint = "oxide"; st.rust = st.rust + 1 end
      kept[#kept + 1] = e
    end
  end
  -- grime down one standing wall in four (its outside face, flush: a film
  -- piece lies on its own +Y, pitched a quarter turn onto the wall)
  local n0 = #kept
  for k = 1, n0 do
    local e = kept[k]
    if e.rl == "wall" and (e.pitch or 0) == 0 and r() < 0.25 then
      local nx, nz = math.sin(e.yaw or 0), math.cos(e.yaw or 0)
      local off = WT / 2 + 0.006
      kept[#kept + 1] = { id = GRIME[1 + math.floor(r() * #GRIME)], x = e.x + nx * off, y = e.y + 0.9 + 0.4 * r(), z = e.z + nz * off,
                          yaw = e.yaw or 0, pitch = Q, roll = 0, rl = "grime", ri = 0 }
      st.grime = st.grime + 1
    end
  end
  st.kept = n0
  st.gone = st.total - n0
  return kept, st
end

-- The pieces the decay took (for a claimed ruin's restore): the full build's
-- entries whose index no standing piece carries. → { { ri, piece } … }
function missing(full, bp)
  local have = {}
  for _, p in ipairs(bp or {}) do if p.ri and p.ri > 0 then have[p.ri] = true end end
  local out = {}
  for i, p in ipairs(full) do
    if not have[i] and p.rl ~= "grime" then out[#out + 1] = { ri = i, piece = p } end
  end
  return out
end

-- ── pure: locks (the interaction plan S5) ──────────────────────────────────
-- Which standing pieces are locked on a keypad, and their codes: doors by the
-- site's kind (a power hall's nearly always, a relay post's never), a store
-- cabinet or a locker three times in five. The codes are in the site's data
-- logs and on its terminal's DATA page (scripts/loot.lua). → { [k] = code }
-- (k: the piece's index in `kept`)
LOCK_DOOR = { camp = 0.3, mine = 0.35, hab = 0.55, reactor = 0.85, relay = 0 }
LOCK_STORE = 0.6
LOCK_DOORS = { doorWall = true, doorWallM = true, airlockWall = true, doubleDoor = true, bulkhead = true }
LOCK_STORES = { cabinet = true, locker = true }
function codeOf(site, ri) return string.format("%04d", hash(tostring(site and site.seed or 1) .. ":code:" .. tostring(ri)) % 10000) end
function lockPlan(site, kept)
  local r = rng(hash(tostring(site and site.seed or 1) .. ":locks"))
  local out = {}
  local pd = LOCK_DOOR[site and site.kind] or 0.3
  for k, e in ipairs(kept or {}) do
    local name = type(e.id) == "string" and e.id:match("^([%w]+)") or ""
    local roll = r()
    if site and site.near and nearLocked then
      -- (R1: THE RUIN NEAR HOME below: the locker, never a door)
      if nearLocked(name) then out[k] = codeOf(site, e.ri or k) end
    elseif (LOCK_DOORS[name] and roll < pd) or (LOCK_STORES[name] and roll < LOCK_STORE) then
      out[k] = codeOf(site, e.ri or k)
    end
  end
  return out
end
function isLockDoor(id) return LOCK_DOORS[type(id) == "string" and id:match("^([%w]+)") or ""] == true end

-- ── pure: the structure record ──────────────────────────────────────────────
-- g = { x, y, z (the ground point), ux, uy, uz (up), fx, fy, fz (front) }
-- in the body's frame; `now` the agency clock.
function recordOf(site, g, kept, now)
  local bp, st = {}, {}
  for i, e in ipairs(kept) do
    local p = { uid = i, id = e.id, x = e.x, y = e.y, z = e.z, yaw = e.yaw or 0, pitch = e.pitch or 0, roll = e.roll or 0,
                parent = 0, att = "", sym = 0, mir = "", stage = 0, paint = e.paint, paintIn = e.paintIn, ri = e.ri, rl = e.rl,
                wr = e.wr, o_p = e.o_p, o_r = e.o_r, o_c = e.o_c, o_id = e.o_id, fill = e.fill }
    bp[i] = p
    if e.rl == "light" then st[tostring(i)] = { off = true } end
  end
  -- (S5) the keypads: a locked door is bolted too (kit_live's hold)
  for k, code in pairs(lockPlan(site, kept)) do
    local t = st[tostring(k)] or {}
    t.kp = code
    if isLockDoor(kept[k].id) then t.dh = "lock" end
    st[tostring(k)] = t
  end
  return { b = site.body, x = g.x, y = g.y, z = g.z, ux = g.ux, uy = g.uy, uz = g.uz, fx = g.fx, fy = g.fy, fz = g.fz,
           n = site.name, by = "ruin", t = (now or 0) - (site.age or 0) * 86400, ru = site.id, bp = bp, st = st }
end

-- ── pure: the Data Core ─────────────────────────────────────────────────────
-- ≥ 40 fragments, three by seed: how it opens, what happened, the last line.
LORE_A = {
  "Day %d before the agency's calendar. %s logs the camp's last full shift.",
  "%d days before Day 1, %s's site manager files the weekly return.",
  "Entry %d. The %s crew count is down to four.",
  "Shift log %d, %s: the relay is up again after the dust.",
  "Day %d (company time). %s orders the site wound down.",
  "Return %d to %s head office: production below the line again.",
  "%d days out from the last supply drop. %s still promises the next.",
  "Maintenance log %d. %s's inspector arrives on the morning lander.",
  "Day %d. Survey quota met; %s asks for more.",
  "Log %d: %s's insurer refuses the renewal.",
  "Entry %d, %s: the second shift is moved into the hab.",
  "Day %d. Payroll from %s is late for the third month.",
  "%d sols logged. %s's beacon answers, then stops.",
  "Report %d for %s: the core samples are better than the brochure.",
}
LORE_B = {
  "The seals on the north wall failed overnight and nobody could find the leak.",
  "Dust got into the scrubber again; we ran on the tanks for a week.",
  "The vein pinched out at forty metres. Varro's geologist says it comes back further east.",
  "Two of the arrays went over in the storm and we never had the parts to stand them up.",
  "The turbine tripped on its own and wouldn't reset. We pulled the core for shipment.",
  "Half the crew rotated home on the last lander and the rest were told to wait.",
  "We traded the spare battery for a week of water with the camp over the ridge.",
  "The tower lost the link home for nine days. We kept working blind.",
  "Someone has been taking ration packs from the store. We stopped counting.",
  "The roof panels are lifting at the bolts; we stopped going upstairs.",
  "We found the old survey stakes from a crew before ours. No record of them anywhere.",
  "The doctor says the dose readings are fine. The doctor would say that.",
  "Morale is fine. The coffee is not.",
  "The company sold the claim while we were still standing on it.",
}
LORE_C = {
  "Closing up. Leaving the lights on for whoever comes next.",
  "Last lander lifts at dawn. Taking what we can carry.",
  "If you are reading this, the parts list is in the shed.",
  "Power down. Doors open. Good luck.",
  "We'll be back for the silo. Nobody believes it.",
  "Tell Mara the hab is hers if she wants it.",
  "Core logged and sealed. End of record.",
  "The storm is here. Writing the rest later.",
  "Don't trust the north wall.",
  "Whoever owns this now: it was good ground.",
  "Signing off from the edge of the map.",
  "Battery at four percent. Saving this.",
  "We were here first. Keep it standing.",
  "Lights out.",
}
function lore(site)
  if site and type(site.lore) == "table" then return site.lore end   -- (F8) an authored ruin's own log
  if site and site.near and nearLore then return nearLore(site) end    -- (R1: THE RUIN NEAR HOME below)
  local r = rng(hash((site and site.seed or 1) .. ":lore"))
  local a = LORE_A[1 + math.floor(r() * #LORE_A)]
  local b = LORE_B[1 + math.floor(r() * #LORE_B)]
  local c = LORE_C[1 + math.floor(r() * #LORE_C)]
  local d = math.floor((site and site.age or 400) + r() * 40)
  if site and site.caveLine then b = site.caveLine end   -- (worlds W5: a shaft's log names its ore)
  return { string.format(a, d, COMPANIES[site and site.co or 1] or "Pell Groundworks"), b, c }
end
-- What reading the core gives: RP by kind × the reader's study multiplier,
-- the log, and the survey layer it carries (a mine's vein map: res; a hab's
-- weather log: atmo and temp; a relay's: nothing more).
CORE_LAYER = { mine = { res = 0.6 }, hab = { atmo = 1.0, temp = 1.0 }, camp = { comp = 0.6 }, reactor = { mag = 0.8 } }
function coreReward(site, mult)
  local rp = math.floor((RP[site and site.kind] or RP.camp) * (mult or 1) + 0.5)
  return { rp = rp, lore = lore(site), layer = CORE_LAYER[site and site.kind] }
end

-- A crate's manifest (from the seed): items and ore samples.
-- ores = the world's ores (materials.bodyOres order) or {}.
function crateManifest(site, ri, ores)
  -- (F8) an authored ruin's crate holds what its author packed
  if site and type(site.loot) == "table" then
    for _, l in ipairs(site.loot) do
      if l.uid == ri then
        local items, mats = {}, {}
        for k, n in pairs(l.items or {}) do items[k] = n end
        for k, n in pairs(l.mats or {}) do mats[k] = n end
        return items, mats
      end
    end
  end
  local r = rng(hash(tostring(site and site.seed or 1) .. ":crate:" .. tostring(ri)))
  local items, mats = {}, {}
  if r() < 0.5 then items.repairkit = 1 end
  if r() < 0.35 then items.o2tank = 1 end
  if r() < 0.25 then items.medkit = 1 end
  if r() < 0.15 then items.beacon = 1 end
  local o = ores and ores[1 + math.floor(r() * math.max(1, #ores))]
  if o then mats[o] = 2 + math.floor(r() * 7) end
  return items, mats
end
-- A mine's silo: 200–2,000 kg of the ore its world's rock holds most of.
function siloFill(site, ores)
  local r = rng(hash(tostring(site and site.seed or 1) .. ":silo"))
  local ore = ores and ores[1] or "regolith"
  return ore, math.floor(200 + r() * 1800)
end

-- ── pure: AUTHORED RUINS (scenarios2 F8: a scenario's `start.ruins`) ─────────
-- A scenario stamps a named blueprint as a ruin at a mark. It is not a site
-- of the seed: it is REGISTERED (saved under ruins.x, rebuilt into the sites
-- list on load), so every ruin path works on it as on any other: the tower's
-- claim, the crates, the Repair Kit on a knocked piece, the restore bill,
-- the terminal's LOG. Its decay is the AUTHOR'S, not the dice's: `gone`
-- pieces are missing (restored by the bill), `knocked` ones lean (a Repair
-- Kit once claimed), `broken` windows are open frames; the dice only rust,
-- grime and topple props (`decay`, 0..1, their share). `lots` split the
-- restore bill into named jobs at the author's prices ("Bunk room roof"
-- $1,300), so a scenario can price an order.
-- def = { name, kind, age (days), company, co, seed, decay, gone = { uid… },
--   knocked = { uid… }, broken = { uid… }, lots = { { id, name, uids, price } },
--   loot = { { uid, items, mats } }, lore = { lines } }
-- pieces = the blueprint's (blueprints.decode: { id, x, y, z, yaw, pitch, roll, paint })
local ROLE_PROP = { ["drum"] = true, ["chair"] = true, ["cableReel"] = true, ["shieldBlock"] = true }
function roleOf(id, y, lootSet)
  local base = tostring(id):match("^([^.]+)") or tostring(id)
  if base == "tower" then return "tower" end
  if lootSet and lootSet[id] then return "loot" end
  if base == "lightFitting" then return "light" end
  if ROLE_PROP[base] then return "prop" end
  if base:match("^floor") and (y or 0) > 1.0 then return "roof" end
  if base:match("[Ww]all$") or base == "porthole" or base == "bulkhead" or base == "openFrame" then return "wall" end
  if base:match("^slab") then return "slab" end
  return "fix"
end
local function set_of(list) local s = {}; for _, v in ipairs(list or {}) do s[v] = true end return s end
function authoredSite(def, pieces, body, g)
  local name = tostring(def.name or "Abandoned Camp")
  local loot = {}
  for _, l in ipairs(def.loot or {}) do loot[l.uid] = true end
  local full = {}
  for i, p in ipairs(pieces or {}) do
    full[i] = { id = p.id, x = p.x or 0, y = p.y or 0, z = p.z or 0, yaw = p.yaw or 0, pitch = p.pitch or 0, roll = p.roll or 0,
                paint = p.paint, rl = loot[i] and "loot" or roleOf(p.id, p.y, nil), fill = p.fill }
    if p.id == "batteryBank" then full[i].fill = 0 end
  end
  local co = def.co
  if type(def.company) == "string" then co = 0 end
  local l = g and math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z) or 1
  return { id = "scn:" .. name, authored = true, body = body, kind = def.kind or "hab", name = name,
           age = def.age or 1000, seed = def.seed or hash(name), co = co or 1, company = def.company,
           ux = g and g.x / l or 0, uy = g and g.y / l or 1, uz = g and g.z / l or 0, yaw = 0, num = 1,
           full = full, gone = def.gone, knocked = def.knocked, broken = def.broken, lots = def.lots,
           loot = def.loot, lore = def.lore, decay = def.decay or 0.5, lean = def.lean }
end
function decayAuthored(full, site)
  local r = rng((site and site.seed) or 1)
  local share = clamp(site and site.decay or 0.5, 0, 1)
  local gone, knocked, broken = set_of(site.gone), set_of(site.knocked), set_of(site.broken)
  local kept = {}
  local st = { total = #full, gone = 0, knocked = 0, broken = 0, toppled = 0, rust = 0, grime = 0 }
  for i, p in ipairs(full) do
    if gone[i] then st.gone = st.gone + 1
    else
      local e = {}
      for k, v in pairs(p) do e[k] = v end
      e.ri = i
      if broken[i] and GLASS[p.id] then e.o_id = p.id; e.id = "openFrame.steel"; st.broken = st.broken + 1 end
      if knocked[i] then
        local a = math.rad(8 + 6 * r()) * (r() < 0.5 and -1 or 1)
        -- (`lean` degrees: a block fallen over, tipped on its face, not leaning)
        if type(site.lean) == "number" then a = math.rad(site.lean) end
        if p.rl == "wall" or type(site.lean) == "number" then e.o_p = e.pitch; e.pitch = (e.pitch or 0) + a
        else e.o_r = e.roll; e.roll = (e.roll or 0) + a end
        e.wr = 0.5
        st.knocked = st.knocked + 1
      elseif TOPPLE[p.id] and p.rl == "prop" and r() < 0.34 * share then
        e.o_r = e.roll; e.roll = Q; e.wr = 0.5; st.toppled = st.toppled + 1
      end
      if p.rl == "wall" and r() < 0.6 * share then e.o_c = p.paint or ""; e.paint = "oxide"; st.rust = st.rust + 1 end
      kept[#kept + 1] = e
    end
  end
  local n0 = #kept
  for k = 1, n0 do
    local e = kept[k]
    if e.rl == "wall" and (e.pitch or 0) == 0 and not e.o_id and r() < 0.5 * share then
      local nx, nz = math.sin(e.yaw or 0), math.cos(e.yaw or 0)
      local off = WT / 2 + 0.006
      kept[#kept + 1] = { id = GRIME[1 + math.floor(r() * #GRIME)], x = e.x + nx * off, y = e.y + 0.9 + 0.4 * r(), z = e.z + nz * off,
                          yaw = e.yaw or 0, pitch = Q, roll = 0, rl = "grime", ri = 0 }
      st.grime = st.grime + 1
    end
  end
  st.kept = n0
  return kept, st
end
-- A lot of the restore bill: its pieces still missing → { { ri, piece } … }
function lotMissing(site, lot, list)
  local want = set_of(lot and lot.uids)
  local out = {}
  for _, m in ipairs(list or {}) do if want[m.ri] then out[#out + 1] = m end end
  return out
end
-- The pieces no lot names (the rest of the bill)
function restMissing(site, list)
  local named = {}
  for _, lot in ipairs(site and site.lots or {}) do for _, u in ipairs(lot.uids or {}) do named[u] = true end end
  local out = {}
  for _, m in ipairs(list or {}) do if not named[m.ri] then out[#out + 1] = m end end
  return out
end

-- Ground distance (m) between two body-relative points on a world of radius R.
function groundDist(R, ax, ay, az, bx, by, bz)
  local la = math.sqrt(ax * ax + ay * ay + az * az)
  local lb = math.sqrt(bx * bx + by * by + bz * bz)
  if la < 1e-6 or lb < 1e-6 then return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) end
  local c = clamp((ax * bx + ay * by + az * bz) / (la * lb), -1, 1)
  return math.acos(c) * (R or la)
end
-- A tangent basis at unit u: e1, e2 (u × e1). (pure)
function tangent(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local d = ax * ux + ay * uy + az * uz
  local ex, ey, ez = ax - ux * d, ay - uy * d, az - uz * d
  local l = math.sqrt(ex * ex + ey * ey + ez * ez)
  ex, ey, ez = ex / l, ey / l, ez / l
  return ex, ey, ez, uy * ez - uz * ey, uz * ex - ux * ez, ux * ey - uy * ex
end
-- The 400-cell swath grid index nearest a direction (survey.swathCells).
function cellOf(cells, ux, uy, uz)
  local best, bd = 1, -2
  for i, c in ipairs(cells) do
    local d = c[1] * ux + c[2] * uy + c[3] * uz
    if d > bd then best, bd = i, d end
  end
  return best
end
function latlon(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return "0°" end
  local lat = math.deg(math.asin(clamp(y / l, -1, 1)))
  local lon = math.deg(math.atan2 and math.atan2(z, x) or math.atan(z, x))
  return string.format("%d° %s, %d° %s", math.floor(math.abs(lat) + 0.5), lat >= 0 and "N" or "S", math.floor(math.abs(lon) + 0.5), lon >= 0 and "E" or "W")
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE SCENE HALF
-- ════════════════════════════════════════════════════════════════════════════
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or os.clock() end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function say(title, line, secs)
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, title, line or "", secs or 4.0)
  elseif caption then pcall(caption, title .. " · " .. (line or "")) end
  if log then log("ruins: " .. title .. " · " .. tostring(line or "")) end
end

-- (progression P1) a thing done: scripts/feats.lua
local function feat(id, ctx) local F = ref("feats"); if F and F.mark then pcall(F.mark, id, ctx) end end

local SITES = nil      -- body → { site … }
local BYID = {}        -- id → site
local S = nil          -- ruins.s (the save's), cached
local function states()
  if S then return S end
  S = save and save.get and save.get("ruins.s")
  if type(S) ~= "table" then S = {} end
  return S
end
local function write() if save and save.set then save.set("ruins.s", states()) end end
function saveStates() write() end
function state(id) local s = states(); local e = s[id]; if not e then e = {}; s[id] = e end return e end
local function peek(id) return states()[id] end
function peekState(id) return peek(id) end   -- (part_info: read without making an entry)
local function bump() version = version + 1 end

local function home_list()
  local h = save and save.get and save.get("system.home")
  return type(h) == "table" and type(h.bodies) == "table" and h.bodies or {}
end
local function home_name()
  local list = home_list()
  return (save and save.get and save.get("base.body")) or (list[1] and list[1].name) or nil
end
local function world(name)
  local cl = ref("climate")
  local w = cl and cl.worldOf and cl.worldOf(name)
  if type(w) ~= "table" and save and save.get then w = save.get("world." .. name) end
  return type(w) == "table" and w or {}
end
local function build_sites()
  SITES, BYID = {}, {}
  local home = home_name()
  for _, b in ipairs(home_list()) do
    if type(b.name) == "string" then
      local w = world(b.name)
      local list = sitesFor(b.name, w, b.name == home, b.radius or w.radius)
      if cave_sites then cave_sites(b.name, w, list) end   -- (worlds W5: CAVE RUINS below)
      if near_sites then near_sites(b.name, w, list, b.name == home) end   -- (R1: THE RUIN NEAR HOME below)
      SITES[b.name] = list
      for _, s in ipairs(list) do BYID[s.id] = s end
    end
  end
  -- (F8) the authored ruins a scenario stamped
  local X = save and save.get and save.get("ruins.x")
  for _, s in ipairs(type(X) == "table" and X or {}) do
    if type(s) == "table" and s.id and s.body then
      SITES[s.body] = SITES[s.body] or {}
      table.insert(SITES[s.body], s)
      BYID[s.id] = s
    end
  end
end
function sites(body)
  if not SITES then build_sites() end
  if body then return SITES[body] or {} end
  local out = {}
  for _, list in pairs(SITES) do for _, s in ipairs(list) do out[#out + 1] = s end end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
function site(id) if not SITES then build_sites() end return BYID[id] end
function siteOfRec(rec) return rec and rec.ru and site(rec.ru) or nil end

-- (base_tower.reconcile) an abandoned base's tower founds nothing until claimed
function towerHeld(rec)
  if not (rec and rec.ru) then return false end
  local e = peek(rec.ru)
  return not (e and e.cl)
end
function baseName(rec)
  local s = siteOfRec(rec)
  return s and s.name or rec.n
end
function discovered(id) local e = peek(id); return e ~= nil and e.dsc ~= nil end
function claimed(id) local e = peek(id); return e ~= nil and e.cl ~= nil end

-- Where a site is (body-relative): its sited ground point, or the direction
-- on the mean radius until it is sited.
function pointOf(s)
  local e = peek(s.id)
  if e and e.g then return e.g.x, e.g.y, e.g.z end
  local b = space and space.body and space.body(s.body)
  local R = (b and b.radius) or world(s.body).radius or 800
  return s.ux * R, s.uy * R, s.uz * R
end

function discover(id, how, quiet)
  local s = site(id)
  if not s or s.pending then return false end
  local e = state(id)
  if e.dsc then return false end
  e.dsc, e.dt = how or "proximity", agency_now()
  write()
  bump()
  stats.found = stats.found + 1
  feat("ruin_found", { key = id, b = s.body })   -- (progression P1)
  if not quiet then
    local x, y, z = pointOf(s)
    if how == "telescope" then
      say("ANOMALY", string.format("a regular shape at %s on %s · %s", latlon(x, y, z), s.body, s.name), 5.0)
    elseif how == "log" then
      say("SITE ON FILE", string.format("a %s on %s at %s · %s, from its records", LABEL[s.kind], s.body, latlon(x, y, z), s.name), 5.0)
    elseif how == "scanner" then
      say("RUIN MAPPED", string.format("the scanner's swath shows a %s on %s at %s", LABEL[s.kind], s.body, latlon(x, y, z)), 5.0)
    else
      say("ABANDONED BASE", string.format("%s · a %s, empty %s days", s.name, LABEL[s.kind], tostring(s.age)), 5.0)
    end
  end
  return true
end

-- A telescope swept a world (survey.credit): a 0.3 m finds the nearest-in-
-- order site not yet found, a 1 m every one.
function telescopeSwept(body, src)
  local n = 0
  for _, s in ipairs(sites(body)) do
    if not s.pending and not discovered(s.id) then
      discover(s.id, "telescope")
      n = n + 1
      if src ~= "tel100" then break end
    end
  end
  return n
end

-- ── siting: where on the ground (9 field raycasts a try) ────────────────────
local function cast(b, R, relief, ux, uy, uz)
  if not (terrain and terrain.raycast and vec3) then return nil, "no terrain" end
  local h0 = R + relief + 80
  local ok, hit, why = pcall(terrain.raycast, vec3(b.x + ux * h0, b.y + uy * h0, b.z + uz * h0), vec3(-ux, -uy, -uz), relief * 2 + 300)
  if not ok or not hit then return nil, why or "miss" end
  local px, py, pz = hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z
  return math.sqrt(px * px + py * py + pz * pz), hit.exact ~= false
end
local function clear_of(name, R, gx, gy, gz)
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if fp and fp.body == name and groundDist(R, gx, gy, gz, fp.x, fp.y, fp.z) < HOME_MIN then return false, "the spaceport" end
  local B = ref("bases")
  for _, r in ipairs(B and B.list and B.list() or {}) do
    if r.b == name and groundDist(R, gx, gy, gz, r.x, r.y, r.z) < BASE_MIN then return false, "a base" end
  end
  local ST = ref("structures")
  for _, r in ipairs(ST and ST.list and ST.list() or {}) do
    if r.b == name and not r.ru and groundDist(R, gx, gy, gz, r.x, r.y, r.z) < BUILT_MIN then return false, "a structure" end
  end
  for _, o in ipairs(sites(name)) do
    local e = peek(o.id)
    if e and e.g and e.sid and groundDist(R, gx, gy, gz, e.g.x, e.g.y, e.g.z) < 60 then return false, "another ruin" end
  end
  return true
end
-- → g | nil, why ("wait": the ground isn't made yet; anything else: no room)
function siteGround(s, force)
  local b = space and space.body and space.body(s.body)
  if not b then return nil, "wait" end
  local w = world(s.body)
  local R = b.radius or w.radius or 800
  local relief = tonumber(w.relief) or 60
  local sea = tonumber(w.sea) or 0
  local e1x, e1y, e1z, e2x, e2y, e2z = tangent(s.ux, s.uy, s.uz)
  local why = "no room"
  for k = 0, SITE_TRIES - 1 do
    local ux, uy, uz = s.ux, s.uy, s.uz
    if k > 0 then
      local a = k * 2.4
      local d = 50 * k / R
      ux = ux + (e1x * math.cos(a) + e2x * math.sin(a)) * d
      uy = uy + (e1y * math.cos(a) + e2y * math.sin(a)) * d
      uz = uz + (e1z * math.cos(a) + e2z * math.sin(a)) * d
      local l = math.sqrt(ux * ux + uy * uy + uz * uz)
      ux, uy, uz = ux / l, uy / l, uz / l
    end
    local h0, exact = cast(b, R, relief, ux, uy, uz)
    if not h0 then return nil, "wait" end
    if not exact and not force then return nil, "wait" end
    local ok = true
    if sea > 0 and h0 < sea + 1.0 then ok = false; why = "under the sea" end
    local hs = { h0 }
    if ok then
      local f1x, f1y, f1z, f2x, f2y, f2z = tangent(ux, uy, uz)
      for j = 0, 7 do
        local a = j * math.pi / 4
        local d = 11 / R
        local vx = ux + (f1x * math.cos(a) + f2x * math.sin(a)) * d
        local vy = uy + (f1y * math.cos(a) + f2y * math.sin(a)) * d
        local vz = uz + (f1z * math.cos(a) + f2z * math.sin(a)) * d
        local l = math.sqrt(vx * vx + vy * vy + vz * vz)
        local h = cast(b, R, relief, vx / l, vy / l, vz / l)
        if not h then return nil, "wait" end
        hs[#hs + 1] = h
      end
      local lo, hi, sum = 1e18, -1e18, 0
      for _, h in ipairs(hs) do lo = math.min(lo, h); hi = math.max(hi, h); sum = sum + h end
      if hi - lo > FLAT_SPREAD then ok = false; why = string.format("too steep (%.1f m over 11 m)", hi - lo) end
      if ok then
        local gr = sum / #hs - 0.15
        local gx, gy, gz = ux * gr, uy * gr, uz * gr
        local c, cwhy = clear_of(s.body, R, gx, gy, gz)
        if not c then ok = false; why = "too near " .. cwhy end
        if ok then
          local t1x, t1y, t1z, t2x, t2y, t2z = tangent(ux, uy, uz)
          local cy, sy = math.cos(s.yaw or 0), math.sin(s.yaw or 0)
          return { x = gx, y = gy, z = gz, ux = ux, uy = uy, uz = uz,
                   fx = t1x * cy + t2x * sy, fy = t1y * cy + t2y * sy, fz = t1z * cy + t2z * sy, spread = hi - lo, try = k }
        end
      end
    end
  end
  return nil, why
end

-- (F8) Flat ground for an authored ruin near a body-relative point: the
-- point itself, then rings 20 m apart out to 120 m (8 a ring), the first whose
-- ground rises no more than `spread` m over a circle of `radius` m (12 casts
-- round it, the field's raycast). → x, y, z (body-relative, on the ground),
-- spread | nil, why
function flatSpot(bodyName, px, py, pz, radius, spread)
  local b = space and space.body and space.body(bodyName)
  if not b then return nil, "no body" end
  local w = world(bodyName)
  local R = b.radius or w.radius or 800
  local relief = tonumber(w.relief) or 60
  local l0 = math.sqrt(px * px + py * py + pz * pz)
  local ux0, uy0, uz0 = px / l0, py / l0, pz / l0
  local e1x, e1y, e1z, e2x, e2y, e2z = tangent(ux0, uy0, uz0)
  radius, spread = radius or 14, spread or 1.2
  local best, bestS = nil, math.huge
  local function try(ux, uy, uz)
    local h0 = cast(b, R, relief, ux, uy, uz)
    if not h0 then return nil end
    local lo, hi = h0, h0
    local f1x, f1y, f1z, f2x, f2y, f2z = tangent(ux, uy, uz)
    for j = 0, 11 do
      local a = j * math.pi / 6
      local d = radius / R
      local vx = ux + (f1x * math.cos(a) + f2x * math.sin(a)) * d
      local vy = uy + (f1y * math.cos(a) + f2y * math.sin(a)) * d
      local vz = uz + (f1z * math.cos(a) + f2z * math.sin(a)) * d
      local l = math.sqrt(vx * vx + vy * vy + vz * vz)
      local h = cast(b, R, relief, vx / l, vy / l, vz / l)
      if not h then return nil end
      lo, hi = math.min(lo, h), math.max(hi, h)
    end
    return h0, hi - lo
  end
  for ring = 0, 6 do
    for k = 0, (ring == 0 and 0 or 7) do
      local ux, uy, uz = ux0, uy0, uz0
      if ring > 0 then
        local a = k * math.pi / 4 + ring * 0.4
        local d = 20 * ring / R
        ux = ux0 + (e1x * math.cos(a) + e2x * math.sin(a)) * d
        uy = uy0 + (e1y * math.cos(a) + e2y * math.sin(a)) * d
        uz = uz0 + (e1z * math.cos(a) + e2z * math.sin(a)) * d
        local l = math.sqrt(ux * ux + uy * uy + uz * uz)
        ux, uy, uz = ux / l, uy / l, uz / l
      end
      local h, sp = try(ux, uy, uz)
      if h and sp < bestS then best, bestS = { ux * h, uy * h, uz * h }, sp end
      if h and sp <= spread then return ux * h, uy * h, uz * h, sp end
    end
  end
  if best then return best[1], best[2], best[3], bestS end
  return nil, "no ground"
end

-- ── stamping ────────────────────────────────────────────────────────────────
local stamp_wait = {}    -- id → first time a stamp waited on the ground
function stampNow(id, force)
  local s = site(id)
  if not s or s.pending then return nil, "no site" end
  local e = state(id)
  local ST = ref("structures")
  if not ST then return nil, "no structures" end
  if e.sid and ST.get(e.sid) then return e.sid end
  if e.drop then return nil, "no room" end
  if not e.g then
    if s.near then return nil, "wait" end   -- (R1: sited by near_tick, never dropped)
    local g, why = siteGround(s, force)
    if not g then
      if why ~= "wait" then e.drop = why; write(); if log then log("ruins: " .. s.name .. " dropped: " .. tostring(why)) end end
      return nil, why
    end
    e.g = { x = g.x, y = g.y, z = g.z, ux = g.ux, uy = g.uy, uz = g.uz, fx = g.fx, fy = g.fy, fz = g.fz }
  end
  local w0 = wall()
  local kept, ds = decay(blueprintOf(s), s)
  if caveKept then kept = caveKept(s, e, kept) end   -- (worlds W5: CAVE RUINS below)
  local rec = recordOf(s, e.g, kept, agency_now())
  local sid = ST.add(rec)
  e.sid, e.n = sid, #rec.bp
  write()
  bump()
  stats.stamps = stats.stamps + 1
  stats.pieces = #rec.bp
  stats.stamp_ms = (wall() - w0) * 1000
  if log then log(string.format("ruins: stamped %s (%s, %d of %d pieces stand: %d roofs and %d walls gone, %d broken windows, %d leaning) as structure %s in %.2f ms",
    s.name, s.kind, ds.kept, ds.total, ds.roofsGone, ds.wallsGone, ds.broken, ds.tilted, tostring(sid), stats.stamp_ms)) end
  return sid
end
local function touched(id)
  local e = peek(id)
  if not e then return false end
  if e.tc or e.cl or e.core or e.lf or e.silo then return true end
  local ST = ref("structures")
  local r = e.sid and ST and ST.get(e.sid)
  return r ~= nil and #r.bp ~= e.n
end
function unstampNow(id)
  local e = peek(id)
  local ST = ref("structures")
  if not (e and e.sid and ST) then return false end
  if touched(id) then return false end
  ST.remove(e.sid)
  e.sid, e.n = nil, nil
  write()
  bump()
  stats.unstamps = stats.unstamps + 1
  return true
end
local function touch(id) local e = state(id); if not e.tc then e.tc = 1; write() end end

-- (F8) A scenario's ruin: the blueprint `pieces` decayed by its author and
-- written as a ruin's structure on the ground point g (body-relative, with
-- its frame: scenario_run's resolve). Found at once (quietly), touched (so
-- it is never unstamped), registered. → sid, site | nil, why
function stampAuthored(def, pieces, g, now_)
  local ST = ref("structures")
  if not (ST and ST.recordFromPieces) then return nil, "no structures" end
  if not (g and g.body) then return nil, "no ground" end
  local s = authoredSite(def, pieces, g.body, g)
  if not SITES then build_sites() end
  if BYID[s.id] then
    local e0 = peek(s.id)
    if e0 and e0.sid and ST.get(e0.sid) then return e0.sid, BYID[s.id] end
  end
  local kept, ds = decayAuthored(s.full, s)
  local rec = ST.recordFromPieces(kept, g.body, g, s.name, "ruin", { t = (now_ or 0) - (s.age or 0) * 86400 })
  rec.ru = s.id
  -- (a piece's uid is its line in the author's blueprint, as for any staged
  -- structure: the scenario names pieces by it, gaps where the decay took one;
  -- the grime films after the last line)
  local extra = #s.full
  for _, p in ipairs(rec.bp) do
    if (p.ri or 0) > 0 then p.uid = p.ri else extra = extra + 1; p.uid = extra end
  end
  for _, p in ipairs(rec.bp) do if p.rl == "light" then rec.st[tostring(p.uid)] = { off = true } end end
  local sid = ST.add(rec)
  local X = save and save.get and save.get("ruins.x")
  X = type(X) == "table" and X or {}
  local keep = {}
  for _, o in ipairs(X) do if type(o) == "table" and o.id ~= s.id then keep[#keep + 1] = o end end
  keep[#keep + 1] = s
  if save and save.set then save.set("ruins.x", keep) end
  SITES[s.body] = SITES[s.body] or {}
  local found = false
  for i, o in ipairs(SITES[s.body]) do if o.id == s.id then SITES[s.body][i] = s; found = true end end
  if not found then table.insert(SITES[s.body], s) end
  BYID[s.id] = s
  local e = state(s.id)
  e.g = { x = g.x, y = g.y, z = g.z, ux = g.ux, uy = g.uy, uz = g.uz, fx = g.fx, fy = g.fy, fz = g.fz }
  e.sid, e.n, e.tc = sid, #rec.bp, 1
  e.dsc, e.dt = "scenario", now_ or 0
  e.core = 1        -- (its log is the author's: no generic Data Core to pull)
  write()
  bump()
  stats.stamps = stats.stamps + 1
  if log then log(string.format("ruins: authored %s: %d of %d pieces stand (%d gone, %d knocked, %d broken, %d rusted, %d grime) as structure %s",
    s.name, ds.kept, ds.total, ds.gone, ds.knocked, ds.broken, ds.rust, ds.grime, tostring(sid))) end
  return sid, s
end

-- ── the focus (the crew on foot, or what it rides) ──────────────────────────
local function focus()
  local a = find and find("Astronaut")
  if a then return a.x, a.y, a.z end
  return nil
end
local function tick()
  local fx, fy, fz = focus()
  if not fx then return end
  local name = space.dominant(fx, fy, fz)
  local b = name and space.body(name)
  if not b then return end
  local list = sites(name)
  local R = b.radius or 800
  local px, py, pz = fx - b.x, fy - b.y, fz - b.z
  stats.dist = nil
  if near_tick then near_tick(name, b, px, py, pz, list) end   -- (R1: THE RUIN NEAR HOME below)
  for _, s in ipairs(list) do
    if not s.pending then
      local x, y, z = pointOf(s)
      local d = groundDist(R, px, py, pz, x, y, z)
      stats.dist = math.min(stats.dist or 1e18, d)
      local e = peek(s.id)
      -- (R1: the ruin near home is found by walking up to it, not from the pad)
      if d < (s.near and NEAR_FIND_R or DISCOVER_R) and not (e and (e.dsc or e.drop)) then discover(s.id, "proximity") end
      e = peek(s.id)
      if d < STAMP_R and not (e and (e.sid or e.drop)) then
        local t0 = stamp_wait[s.id] or now()
        stamp_wait[s.id] = t0
        -- (the field's ground may be a stand-in at first: wait for it, but
        -- not for ever: near, or after 20 s, the stand-in will do)
        local sid = stampNow(s.id, d < 300 or now() - t0 > 20)
        if sid then stamp_wait[s.id] = nil end
      elseif d > UNSTAMP_R and e and e.sid then
        unstampNow(s.id)
      end
    end
  end
  if cave_tick then cave_tick(name, b, px, py, pz, list) end   -- (worlds W5: CAVE RUINS below)
  -- (an untouched ruin on another world: out of the records)
  for _, s in ipairs(sites()) do
    local e = peek(s.id)
    if e and e.sid and s.body ~= name then unstampNow(s.id) end
  end
end

local scan_t = -10
local function scan_tick()
  local SV = ref("survey")
  if not (SV and SV.swathOf and SV.swathCells) then return end
  stats.scans = stats.scans + 1
  local cells = nil
  for _, s in ipairs(sites()) do
    if not s.pending and not discovered(s.id) then
      local sw = SV.swathOf(s.body)
      if sw and (sw.n or 0) > 0 then
        cells = cells or SV.swathCells(SV.SWATH_N)
        s.cell = s.cell or cellOf(cells, s.ux, s.uy, s.uz)
        if sw.mask[s.cell] then discover(s.id, "scanner") end
      end
    end
  end
end

-- ── the core, read at the lab ───────────────────────────────────────────────
local function cores()
  local c = save and save.get and save.get("ruins.cores")
  return type(c) == "table" and c or {}
end
function pullCore(id, pack)
  local s, e = site(id), peek(id)
  if not (s and e and e.sid) then return false, "no ruin here" end
  if e.core then return false, "the terminal is empty: its core was taken" end
  local inv = ref("inventory")
  if not inv then return false, "no inventory" end
  local n, why = inv.addItem(pack or "astro", "datacore", 1)
  if (n or 0) < 1 then return false, why or "no room in the pack" end
  e.core, e.tc = agency_now(), 1
  local c = cores()
  c[#c + 1] = id
  if save and save.set then save.set("ruins.cores", c) end
  write()
  bump()
  say("DATA CORE", string.format("%s's log, 6 kg · carry it into the Research Lab", s.name), 4.0)
  return true
end
lastRead = nil
function readCores(pack)
  local inv = ref("inventory")
  if not inv then return 0 end
  pack = pack or "astro"
  local n = inv.itemCount(pack, "datacore") or 0
  if n <= 0 then return 0 end
  local C = ref("crew")
  local mult = 1
  if C and C.activeId and C.perk and C.role then
    local id = C.activeId()
    local okr, role = pcall(C.role, id)
    if okr and role == "scientist" then local okp, m = pcall(C.perk, id, "study_mult"); if okp and tonumber(m) then mult = m end end
  end
  local read = 0
  for _ = 1, n do
    local got = inv.removeItem(pack, "datacore", 1)
    if (got or 0) < 1 then break end
    local c = cores()
    local id = table.remove(c, 1)
    if save and save.set then save.set("ruins.cores", c) end
    local s = id and site(id) or { kind = "camp", name = "an unknown site", seed = 7, co = 1, age = 900, body = home_name() }
    local rw = coreReward(s, mult)
    if save and save.set and save.get then save.set("res.pts", (save.get("res.pts") or 0) + rw.rp) end
    local e = id and state(id)
    if e then e.read = agency_now(); write() end
    feat("core_read", { key = id or "?", b = s.body })   -- (progression P1)
    if s.near and s.other then discover(s.other, "log") end   -- (R1: its log names the next site)
    -- the site's blueprint, as it stood, into the library
    local BP, pb = ref("blueprints"), ref("parts_base")
    local saved = nil
    if BP and BP.saveBp and pb then
      local ps = {}
      for _, p in ipairs(blueprintOf(s)) do
        local d = pb.partInfo(p.id)
        if d and d.kit then ps[#ps + 1] = { id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll, paint = p.paint } end
      end
      local ok, slug = pcall(BP.saveBp, { v = 1, name = s.name .. " (recovered)", by = "data core", n = #ps, pieces = ps })
      if ok and slug then saved = slug end
    end
    local SV = ref("survey")
    if rw.layer and SV and SV.creditNow and s.body then pcall(SV.creditNow, s.body, "datacore", rw.layer) end
    lastRead = { id = id, name = s.name, rp = rw.rp, lore = rw.lore, bp = saved, t = now() }
    say("DATA CORE READ", string.format("%s · +%d RP%s · \"%s\"", s.name, rw.rp, saved and " · its blueprint is in your library" or "", rw.lore[3]), 6.0)
    if log then for _, l in ipairs(rw.lore) do log("ruins: core " .. tostring(id) .. ": " .. l) end end
    read = read + 1
  end
  bump()
  return read
end

-- ── crates, the silo ────────────────────────────────────────────────────────
-- The world's ores, the most common first (materials.bodyOres: { { mat, w } }).
local function ores_of(body)
  local M = ref("materials")
  local ok, o = pcall(function() return M and M.bodyOres and M.bodyOres(body) end)
  local list = {}
  if ok and type(o) == "table" then
    for _, v in ipairs(o) do if type(v) == "table" and type(v.mat) == "string" then list[#list + 1] = v end end
  end
  table.sort(list, function(a, b) if (a.w or 0) ~= (b.w or 0) then return (a.w or 0) > (b.w or 0) end return a.mat < b.mat end)
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = v.mat end
  return out
end
function crateId(id, ri) return "crate:ruin." .. tostring(id) .. "." .. tostring(ri) end
local function filled(e, ri) return e.lf and e.lf:find("," .. tostring(ri) .. ",", 1, true) ~= nil end
function searchCrate(id, ri, pack)
  local s, e = site(id), peek(id)
  local inv = ref("inventory")
  if not (s and e and inv) then return 0, "nothing here" end
  -- (S5: with scripts/loot.lua every crate is a container `piece:<sid>:<uid>`, the
  -- whole site rolled at once; a search is "take everything that fits")
  local L = ref("loot")
  local ST = ref("structures")
  local r = L and e.sid and ST and ST.get(e.sid)
  if r and L.prepare then
    for _, p in ipairs(r.bp) do
      if p.ri == ri then
        L.prepare(r.id, p.uid)
        local cid = L.cidOf(r.id, p.uid)
        local a = inv.moveAllItems(cid, pack or "astro") or 0
        local b = inv.transferAll(cid, pack or "astro") or 0
        bump()
        return a + b, not L.isEmpty(cid) and "the rest won't fit in the pack" or nil
      end
    end
  end
  local cid = crateId(id, ri)
  if not filled(e, ri) then
    local items, mats = crateManifest(s, ri, ores_of(s.body))
    for it, n in pairs(items) do inv.addItem(cid, it, n) end
    for m, n in pairs(mats) do inv.add(cid, m, n, s.body) end
    e.lf = (e.lf or ",") .. tostring(ri) .. ","
    e.tc = 1
    write()
  end
  local a = inv.moveAllItems(cid, pack or "astro") or 0
  local b = inv.transferAll(cid, pack or "astro") or 0
  bump()
  return a + b, not crateEmpty(id, ri) and "the rest won't fit in the pack" or nil
end
function crateEmpty(id, ri)
  local e = peek(id)
  local inv = ref("inventory")
  local L = ref("loot")
  local ST = ref("structures")
  local r = L and e and e.sid and ST and ST.get(e.sid)
  if r and L.filled then
    for _, p in ipairs(r.bp) do
      if p.ri == ri then return L.filled(r.id, p.uid) and L.isEmpty(L.cidOf(r.id, p.uid)) end
    end
  end
  if not (e and filled(e, ri) and inv) then return false end
  local cid = crateId(id, ri)
  return inv.isEmpty(cid) and #(inv.itemList(cid) or {}) == 0
end
local function fill_silo(id)
  local s, e = site(id), peek(id)
  local ST, inv = ref("structures"), ref("inventory")
  local r = e and e.sid and ST and ST.get(e.sid)
  if not (s and r and inv) or e.silo then return end
  for _, p in ipairs(r.bp) do
    if p.rl == "silo" then
      local ore, kg = siloFill(s, ores_of(s.body))
      inv.add("hopper:" .. tostring(r.id) .. "." .. tostring(p.uid), ore, kg, s.body)
      e.silo = 1
      write()
      if log then log(string.format("ruins: %s's silo holds %d kg of %s", s.name, kg, ore)) end
    end
  end
end

-- ── claiming, repair, restore ───────────────────────────────────────────────
local function role_of(ctx)
  local C = ref("crew")
  local id = ctx and ctx.actor and ctx.actor.id
  if not (C and C.role) then return nil end
  if not id and C.activeId then id = C.activeId() end
  local ok, r = pcall(C.role, id)
  return ok and r or nil
end
function claim(id, ctx, force)
  local s, e = site(id), peek(id)
  local ST = ref("structures")
  if not (s and e and e.sid and ST and ST.get(e.sid)) then return false, "no ruin here" end
  if e.cl then return false, "it's already yours" end
  if not force and role_of(ctx) ~= "engineer" then return false, "an Engineer claims a site (the tower's records, the grid's breakers)" end
  e.cl, e.tc = agency_now(), 1
  if not e.dsc then e.dsc, e.dt = "proximity", agency_now() end
  feat("ruin_claimed", { key = id, b = s.body })   -- (progression P1; the tower's founding marks base_founded)
  write()
  fill_silo(id)
  -- (the tower founds its base on the records' next change: base_tower)
  local r = ST.get(e.sid)
  ST.put(r)
  bump()
  say("CLAIMED", string.format("%s is yours: a base. Repair what leans, restore what's gone, and power it", s.name), 5.0)
  return true
end
function baseOf(id)
  local e, B = peek(id), ref("bases")
  if not (e and e.sid and B and B.list) then return nil end
  for _, r in ipairs(B.list()) do if r.sid == e.sid then return r end end
  return nil
end
local function price_of(pid)
  local pb = ref("parts_base")
  local d = pb and pb.partInfo(pid)
  return d and (d.cost or 0) or 0
end
-- → { n, cost, list = { { ri, piece } } }
-- → { n, cost, list = { { ri, piece } } }. (F8) `lot`: one of an authored
-- ruin's named jobs (its id), at the author's price; "rest": what no lot names.
function restoreQuote(id, lot)
  local s, e = site(id), peek(id)
  local ST = ref("structures")
  local r = e and e.sid and ST and ST.get(e.sid)
  if not (s and r) then return { n = 0, cost = 0, list = {} } end
  local list = missing(blueprintOf(s), r.bp)
  local L = nil
  if lot == "rest" then list = restMissing(s, list)
  elseif lot ~= nil then
    for _, l in ipairs(s.lots or {}) do if l.id == lot then L = l end end
    list = L and lotMissing(s, L, list) or {}
  end
  local cost = 0
  for _, m in ipairs(list) do cost = cost + price_of(m.piece.id) end
  if L and L.price and #list > 0 then cost = L.price end
  return { n = #list, cost = cost, list = list, name = L and L.name or nil }
end
function restore(id, free, lot)
  local q = restoreQuote(id, lot)
  if q.n == 0 then return 0, "nothing is missing" end
  local co = ref("company")
  if not free and co and co.spend and not co.spend(q.cost, string.format("restore %s at %s", q.name or (q.n .. " pieces"), site(id).name)) then
    return 0, string.format("restoring costs $%d", q.cost)
  end
  local e = peek(id)
  local ST = ref("structures")
  local n = 0
  for _, m in ipairs(q.list) do
    local p = m.piece
    local uid = ST.addPart(e.sid, { id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll, paint = p.paint,
                                    ri = m.ri, rl = p.rl, fill = p.fill, uid = site(id).authored and m.ri or nil })   -- (F8: back on its own line)
    if uid then n = n + 1 end
  end
  e.n = nil
  e.tc = 1
  write()
  bump()
  return n
end
function repairPiece(sid, uid)
  local ST = ref("structures")
  local r = ST and ST.get(sid)
  local p = r and ST.getPart(sid, uid)
  if not (p and p.wr) then return false end
  if p.o_p ~= nil then p.pitch = p.o_p end
  if p.o_r ~= nil then p.roll = p.o_r end
  if p.o_c ~= nil then p.paint = (p.o_c ~= "") and p.o_c or nil end
  if p.o_id ~= nil then p.id = p.o_id end
  p.wr, p.o_p, p.o_r, p.o_c, p.o_id = nil, nil, nil, nil, nil
  ST.put(r)
  if ST.respawnPart then ST.respawnPart(sid, uid) end
  if r.ru then touch(r.ru) end
  bump()
  return true
end

-- ── the right-click rows on a ruin's piece ─────────────────────────────────
local function pack_of(ctx) return (ctx and ctx.actor and ctx.actor.pack) or "astro" end
local function near(ctx, t, extra)
  local CP = ref("context_providers")
  if CP and CP.actorReach then
    local where = CP.actorReach(ctx, t, extra or 1.0)
    return where ~= nil
  end
  return true
end
local function count_worn(r)
  local n = 0
  for _, p in ipairs(r.bp) do if p.wr then n = n + 1 end end
  return n
end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not (rec and rec.ru and part) then return {} end
  local s = site(rec.ru)
  if not s then return {} end
  local id = s.id
  local G = "Ruin"
  local out = {}
  local e = state(id)
  out[#out + 1] = { id = "ru_site", type = "info", label = e.cl and "Claimed" or "Abandoned", group = G, value = function()
    local r = ST.get(rec.id)
    local full = #blueprintOf(s)
    local stand = 0
    for _, p in ipairs(r and r.bp or {}) do if (p.ri or 0) > 0 then stand = stand + 1 end end
    return string.format("%s · %s · %d of %d pieces stand · %d knocked", LABEL[s.kind], e.cl and "yours" or (s.age .. " days empty"),
      stand, full, r and count_worn(r) or 0)
  end }
  if part.rl == "core" then
    out[#out + 1] = { id = "ru_core", type = "action", group = G, label = e.core and "The terminal is empty" or "Pull the Data Core",
      hint = "6 kg", enabled = function() return not peek(id).core and near(ctx, t) end,
      why = function() return peek(id).core and "its core was taken" or "come closer" end,
      act = function()
        local ok, why = pullCore(id, pack_of(ctx))
        if ctx and ctx.toast then ctx.toast(ok and "Data Core in the pack: read it at the Research Lab" or tostring(why), not ok) end
        return ok
      end }
  end
  if part.rl == "loot" and not ref("loot") then
    out[#out + 1] = { id = "ru_crate", type = "action", group = G,
      label = function() return crateEmpty(id, part.ri) and "The crate is empty" or "Search the crate" end,
      enabled = function() return not crateEmpty(id, part.ri) and near(ctx, t) end, why = "come closer",
      act = function()
        local n, why = searchCrate(id, part.ri, pack_of(ctx))
        if ctx and ctx.toast then ctx.toast(n > 0 and (string.format("took %d thing%s from the crate", n, n == 1 and "" or "s") .. (why and (" · " .. why) or "")) or (why or "nothing you can carry"), n == 0) end
        return n > 0
      end }
  end
  if part.id == "tower" then
    if not e.cl then
      out[#out + 1] = { id = "ru_claim", type = "action", group = G, label = "Claim the site", hint = "Engineer",
        enabled = function() return role_of(ctx) == "engineer" and near(ctx, t, 9.0) end,
        why = function() return role_of(ctx) ~= "engineer" and "an Engineer claims a site" or "come closer" end,
        act = function()
          local ok, why = claim(id, ctx)
          if ctx and ctx.toast then ctx.toast(ok and (s.name .. " is your base now") or tostring(why), not ok) end
          return ok
        end }
    elseif s.lots then
      -- (F8) an authored ruin's bill in its author's jobs, each at its price
      local lots = {}
      for _, l in ipairs(s.lots) do lots[#lots + 1] = l.id end
      lots[#lots + 1] = "rest"
      for _, lid in ipairs(lots) do
        local function q() return restoreQuote(id, lid) end
        if q().n > 0 then
          out[#out + 1] = { id = "ru_restore_" .. tostring(lid), type = "action", group = G,
            label = function() local qq = q(); return qq.n > 0 and ("Restore: " .. (qq.name or string.format("%d other piece%s", qq.n, qq.n == 1 and "" or "s"))) or "Restored" end,
            hint = function() local qq = q(); return qq.n > 0 and string.format("$%d", qq.cost) or "" end,
            enabled = function() return q().n > 0 end, why = "it stands as it was built",
            act = function()
              local n, why = restore(id, false, lid)
              if ctx and ctx.toast then ctx.toast(n > 0 and string.format("%d pieces shipped and set back", n) or tostring(why), n == 0) end
              return n > 0
            end }
        end
      end
    else
      out[#out + 1] = { id = "ru_restore", type = "action", group = G,
        label = function() local q = restoreQuote(id); return q.n > 0 and string.format("Restore %d missing piece%s", q.n, q.n == 1 and "" or "s") or "Nothing is missing" end,
        hint = function() local q = restoreQuote(id); return q.n > 0 and string.format("$%d", q.cost) or "" end,
        enabled = function() return restoreQuote(id).n > 0 end, why = "it stands as it was built",
        act = function()
          local n, why = restore(id)
          if ctx and ctx.toast then ctx.toast(n > 0 and string.format("%d pieces shipped and set back", n) or tostring(why), n == 0) end
          return n > 0
        end }
    end
  end
  if part.wr and e.cl then
    local label = part.id
    local pb = ref("parts_base")
    local d = pb and pb.partInfo(part.id)
    if d and d.label then label = d.label end
    out[#out + 1] = { id = "ru_fix", type = "action", group = G, label = "Repair the " .. label, hint = "Repair Kit · 4 s",
      enabled = function()
        local inv = ref("inventory")
        return inv and (inv.itemCount(pack_of(ctx), "repairkit") or 0) > 0 and near(ctx, t)
      end,
      why = "needs a Repair Kit in the pack",
      job = { secs = 4.0, label = "Repairing the " .. label,
        check = function() return near(ctx, t), "walked away" end,
        done = function()
          local inv = ref("inventory")
          if inv and inv.removeItem then inv.removeItem(pack_of(ctx), "repairkit", 1) end
          return repairPiece(rec.id, part.uid), nil
        end } }
  elseif part.wr then
    out[#out + 1] = { id = "ru_fix0", type = "info", group = G, label = "Damage", value = "knocked askew · claim the site to repair it" }
  end
  local sub = string.format("Abandoned · %s · %s days", LABEL[s.kind], tostring(s.age))
  if e.cl then sub = "Claimed · " .. LABEL[s.kind] end
  return out, s.name, sub
end
providerFn = provider

-- ── the frame ───────────────────────────────────────────────────────────────
local reg_on, reg_t = false, -10
local tick_t, read_t = -10, -10
function start(node)
  if findScripts then
    local all = findScripts("ruins")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  SITES, BYID, S = nil, {}, nil
  stamp_wait = {}
  reg_on = false
end
function reset() SITES, BYID, S = nil, {}, nil; stamp_wait = {} end

function update(node, dt)
  if not reg_on and now() - reg_t > 1.0 then
    reg_t = now()
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "ruins", order = 3 }); reg_on = true end
  end
  local t = now()
  if t - tick_t < 1.0 then return end
  tick_t = t
  if not (save and save.get and save.get("system.home")) then return end
  local w0 = wall()
  local ok, err = pcall(tick)
  if not ok and log then log("ruins: tick failed: " .. tostring(err)) end
  if t - scan_t >= SCAN_EVERY then
    scan_t = t
    pcall(scan_tick)
  end
  if t - read_t >= 1.0 then
    read_t = t
    local L = ref("lab")
    if L and L.crewInLab then pcall(readCores, "astro") end
  end
  stats.ms = (wall() - w0) * 1000
end


-- ════════════════════════════════════════════════════════════════════════════
-- CAVE RUINS (worlds W5, work/worlds/PLAN.md §4.5; docs/worlds-and-caves.md
-- §4.7). Kept apart from the rest of the file: it hooks in at five marked
-- lines (build_sites, stampNow, tick, lore, kinds).
--
--   MINE SHAFT     a mine head with a cave under it (a column 14-36 m from
--                  the head, a chamber within SHAFT_R m down): a shaft dug
--                  from the surface to the chamber's floor, ONCE (terrain.dig
--                  and flatten, paced by the engine's edit budget), a ship's
--                  ladder switchback down it with a landing at each turn (an
--                  old site has lost some flights: bring a rope), and the
--                  last shift's cache at the bottom, in the cave: a bench,
--                  crates, a store cabinet, drums. Its Data Core's log names
--                  the ore they sank it for.
--   SINKHOLE CAMP  SINK_SHARE of the survey camps on a world with caves
--                  (decided by the seed; a camp already stamped as a camp
--                  stays one) are camped IN a sink: the hut, its terminal (the
--                  core), bunk and crates on the floor; the tower and a winch
--                  drum on the rim; flights down its side. The sink opens into
--                  a chamber found under the site, or is a SINK_D m doline dug
--                  where there is none.
--   LOOT           the cave pieces are a ruin's containers like any other:
--                  scripts/loot.lua rolls them with the site (planSite, by
--                  kind and age), keyed by their piece index (ri > CAVE_RI).
--   WHEN           the cave is looked for once the crew is within CAVE_NEAR
--                  m and the ground there is made (a few dozen field reads a
--                  column, once a site: ruins.s[id].sh = { x, z, d, roof, nat,
--                  s0, dug } or false); found, an untouched ruin is stamped
--                  again with its cave pieces and the ground is dug.
--
-- Pure: SINK_SHARE, caveKindOf, flightPieces, shaftPieces, caveKept,
-- shaftLine. Probes: caveNow(id), forceCaveKind(id, kind).
SINK_SHARE = 0.5
SINK_D = 12.0          -- m: the doline's depth where no chamber lies under a sink camp
SINK_R = 7.0           -- m: its radius
SHAFT_R = 60.0         -- m: the deepest a shaft is sunk
SHAFT_REACH = 36.0     -- m: how far from the head a shaft may be sunk
CAVE_NEAR = 220.0      -- m: the crew this near, the cave is looked for
CAVE_RI = 1000         -- the cave pieces' indices (ri) start past this
FLIGHT_H = 2.4         -- a ship's ladder's rise (parts_kit ladder)
LABEL.sinkcamp = "sinkhole camp"
NOUN.sinkcamp = "Sink Camp"
RP.sinkcamp = 90
CORE_LAYER.sinkcamp = { comp = 0.8 }
LOCK_DOOR.sinkcamp = 0.3

-- Is this camp camped in a sink? info = { caves (the world has rock to hold
-- caves), keep (a camp already stamped as a camp) } → "sinkcamp" | nil
function caveKindOf(site, info)
  info = info or {}
  if not site or site.kind ~= "camp" or site.pending or not info.caves or info.keep then return nil end
  local r = rng(hash(tostring(site.seed) .. ":sink"))
  if r() < SINK_SHARE then return "sinkcamp" end
  return nil
end

-- A ship's-ladder switchback from y0 (its foot) up to at least y1, at x0 in
-- the site's frame (z0 its middle): flights side by side, turning at a
-- landing at each end; `drop` the chance an old flight is gone (rng `r`;
-- never the first or the last). → pieces (cv = true), flights lost
function flightPieces(x0, z0, y0, y1, r, drop)
  local P, lost = {}, 0
  local n = math.max(1, math.ceil((y1 - y0) / FLIGHT_H - 1e-6))
  for k = 0, n - 1 do
    local y = y0 + k * FLIGHT_H
    local odd = k % 2 == 1
    -- (a flight rises toward its local −Z: yaw 0 tops out at z0 − 1.1, yaw π at z0 + 1.1)
    local gone = k > 0 and k < n - 1 and r ~= nil and r() < (drop or 0)
    if gone then lost = lost + 1
    else P[#P + 1] = { id = "ladder.steel", x = x0 + (odd and 1.0 or 0), y = y, z = z0, yaw = odd and math.pi or 0, pitch = 0, roll = 0,
                       rl = "fix", cv = true } end
    if k < n - 1 then
      -- the landing where this flight tops out and the next starts (its top at the tread's)
      P[#P + 1] = { id = "floor.steel", x = x0 + 0.5, y = y + FLIGHT_H - 0.2, z = z0 + (odd and 2.1 or -2.1), yaw = 0, pitch = 0, roll = 0,
                    rl = "floor", cv = true }
    end
  end
  return P, lost
end

-- A mine shaft's pieces in the site's frame: sh = { x, z (the shaft's
-- column), d (its floor's depth under the site's ground), s0 (the ground at
-- the column, + up) }. The flights from the floor to the collar, and the
-- cache beside their foot.
function shaftPieces(site, sh)
  local r = rng(hash(tostring(site and site.seed or 1) .. ":shaft"))
  local ageK = clamp(((site and site.age or 400) - 400) / 5600, 0, 1)
  local P = flightPieces(sh.x - 0.5, sh.z, -sh.d, (sh.s0 or 0), r, 0.10 + 0.25 * ageK)
  local cx, y = sh.x + 3.6, -sh.d
  local T2 = y + T
  for _, q in ipairs({
    { "slab2.concrete", cx, y, sh.z - 1, 0, "slab" }, { "slab2.concrete", cx, y, sh.z + 1, 0, "slab" },
    { "workbench.steel", cx + 0.45, T2, sh.z - 1.2, -Q, "fix" },
    { "crate.steel", cx - 0.1, T2, sh.z + 1.2, 0.3, "loot" },
    { "crateS.steel", cx + 0.6, T2, sh.z + 1.6, 0, "loot" },
    { "cabinet.steel", cx + 0.64, T2, sh.z + 0.2, -Q, "store" },
    { "drum.steel", cx - 1.4, y, sh.z + 2.6, 0, "prop" },
    { "drum.steel", cx + 2.2, y, sh.z - 1.8, 0, "prop" },
    { "cableReel.steel", cx + 2.0, y, sh.z + 2.4, 0.8, "prop" },
  }) do
    P[#P + 1] = { id = q[1], x = q[2], y = q[3], z = q[4], yaw = q[5], pitch = 0, roll = 0, rl = q[6], cv = true,
                  paint = (q[1]:match("^crate") or q[1]:match("^cabinet")) and "olive" or (q[1]:match("^drum") and "oxide" or nil) }
  end
  return P
end

-- THE SINK CAMP's blueprint (pure; through blueprintOf): the rim (y ≥ 0)
-- and the camp on the floor at the nominal depth SINK_D (cv: moved to the
-- real floor, or held back until it is known, by caveKept). The hut is the
-- survey camp's, its middle on the sink's.
GRAMMAR.sinkcamp = function(site)
  local P, add = builder()
  local D = -SINK_D
  local function cv(i) P[i].cv = true; return i end
  local ox, oz = -1, -1
  for _, sl in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do cv(add("slab2.concrete", sl[1] + ox, D, sl[2] + oz, 0, 0, 0, nil, "slab")) end
  cv(add("doorWall.steel", 0 + ox, D + T, 3 + oz, 0, 0, 0, "hull", "door"))
  cv(add("windowWall.steel", 2 + ox, D + T, 3 + oz, 0, 0, 0, "hull", "wall"))
  local wb = cv(add("wall.steel", 0 + ox, D + T, -1 + oz, math.pi, 0, 0, "hull", "wall"))
  cv(add("wall.steel", 2 + ox, D + T, -1 + oz, math.pi, 0, 0, "hull", "wall"))
  cv(add("windowWall.steel", -1 + ox, D + T, 0 + oz, -Q, 0, 0, "hull", "wall"))
  cv(add("wall.steel", -1 + ox, D + T, 2 + oz, -Q, 0, 0, "hull", "wall"))
  local ws = cv(add("wall.steel", 3 + ox, D + T, 0 + oz, Q, 0, 0, "hull", "wall"))
  cv(add("wall.steel", 3 + ox, D + T, 2 + oz, Q, 0, 0, "hull", "wall"))
  local roof = {}
  for _, sl in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }) do roof[#roof + 1] = cv(add("floor.steel", sl[1] + ox, D + T + 2.2, sl[2] + oz, 0, 0, 0, "gunmetal", "roof")) end
  cv(add("lightFitting.steel", 1 + ox, D + T + 2.2, 1 + oz, 0, math.pi, 0, nil, "light", roof[4]))
  cv(add("bunk.steel", 0.1 + ox, D + T, -0.4 + oz, 0, 0, 0, "olive", "fix"))
  local tb = cv(add("table.steel", 1.75 + ox, D + T, 1.5 + oz, Q, 0, 0, nil, "fix"))
  cv(add("monitor.steel", 1.75 + ox, D + T + 0.74, 1.5 + oz, Q, 0, 0, nil, "core", tb))
  cv(add("chair.steel", 0.95 + ox, D + T, 1.5 + oz, Q, 0, 0, nil, "prop"))
  cv(add("chair.steel", 2.55 + ox, D + T, 1.5 + oz, -Q, 0, 0, nil, "prop"))
  cv(add("shelf.steel", 2.6 + ox, D + T, 0.0 + oz, -Q, 0, 0, nil, "fix"))
  cv(add("crateS.steel", 2.6 + ox, D + T, 2.55 + oz, 0, 0, 0, "orange", "loot"))
  cv(add(mark(site.co), 3.1 + ox, D + T + 1.3, 0 + oz, Q, Q, 0, nil, "decal", ws))
  cv(add("grimeStreaks.film", 0.0 + ox, D + T + 1.1, -1.1 + oz, math.pi, Q, 0, nil, "decal", wb))
  cv(add("locker.steel", -0.64 + ox, D + T, 1.2 + oz, Q, 0, 0, "olive", "store"))
  cv(add("crate.steel", -3.6, D, 2.4, 0.3, 0, 0, "olive", "loot"))
  cv(add("drum.steel", -3.4, D, -2.6, 0, 0, 0, "orange", "prop"))
  cv(add("drum.steel", -4.0, D, -1.9, 0, 0, 0, "oxide", "prop"))
  -- the rim: the tower, the winch's drum and its cable, a crate left up top
  add("tower", -SINK_R - 4, 0, 0, 0, 0, 0, nil, "tower")
  add("drum.steel", SINK_R + 1.5, 0, -3, 0, 0, 0, "oxide", "prop")
  add("cableReel.steel", SINK_R + 1.5, 0, 2, 0.6, 0, 0, nil, "prop")
  add("crateS.steel", -SINK_R - 2, 0, 3, 0.2, 0, 0, "orange", "loot")
  return P
end

-- The kept pieces with the cave's: a sink camp's floor pieces moved to the
-- real floor (or held back while the floor is not known), the flights; a
-- mine's shaft. `e` the site's state (e.sh). Cave pieces get ri past CAVE_RI.
function caveKept(site, e, kept)
  local sh = e and e.sh or nil
  if e then e.kk = site.kind end
  local out = {}
  if site.kind == "sinkcamp" then
    local dy = sh and (SINK_D - sh.d) or nil
    for _, p in ipairs(kept) do
      if p.cv then
        if dy then
          local q = {}
          for k2, v in pairs(p) do q[k2] = v end
          q.y = p.y + dy
          out[#out + 1] = q
        end
      else out[#out + 1] = p end
    end
    if sh then
      local r = rng(hash(tostring(site.seed) .. ":flights"))
      local ageK = clamp(((site.age or 400) - 400) / 5600, 0, 1)
      local fl = flightPieces(SINK_R - 2.6, 0, -sh.d, 0, r, 0.08 + 0.2 * ageK)
      for i, p in ipairs(fl) do p.ri = CAVE_RI + i; out[#out + 1] = p end
    end
    return out
  end
  for _, p in ipairs(kept) do out[#out + 1] = p end
  if site.kind == "mine" and sh then
    for i, p in ipairs(shaftPieces(site, sh)) do p.ri = CAVE_RI + i; out[#out + 1] = p end
  end
  return out
end

-- The line a mine's core gives when it had a shaft (pure).
function shaftLine(site, sh, ore)
  if not sh then return nil end
  return string.format("We sank the shaft %d metres into the cave under the head, after the %s. The cache is at the bottom.",
    math.floor(sh.d + 0.5), tostring(ore or "ore"))
end

-- ── the scene ───────────────────────────────────────────────────────────────
local function world_caves(w)
  if type(w) == "table" and w.kind == "gas" then return false end
  return true
end
function cave_sites(name, w, list)
  local caves = world_caves(w)
  for _, s in ipairs(list) do
    local e = peek(s.id)
    local keep = e ~= nil and e.kk == "camp" and (e.sid ~= nil or e.tc ~= nil or e.lp ~= nil)
    local k = caveKindOf(s, { caves = caves, keep = keep })
    if k then
      s.kind = k
      s.name = siteName(s.co, k, s.num)
    end
    if e and e.fk then s.kind = e.fk; s.name = siteName(s.co, e.fk, s.num) end
    if s.kind == "mine" and e and e.sh then s.caveLine = shaftLine(s, e.sh, ores_of(s.body)[1]) end
  end
end

-- The point of the site's frame (x, y, z) on its body (body-relative).
local function frame_pt(g, x, y, z)
  local ST = ref("structures")
  if ST and ST.partPose then
    local px, py, pz = ST.partPose(g, { x = x, y = y, z = z })
    return px, py, pz
  end
  local rx, ry, rz = g.uy * g.fz - g.uz * g.fy, g.uz * g.fx - g.ux * g.fz, g.ux * g.fy - g.uy * g.fx
  return g.x + rx * x + g.ux * y + g.fx * z, g.y + ry * x + g.uy * y + g.fy * z, g.z + rz * x + g.uz * y + g.fz * z
end

-- A chamber under column (cx, cz) of the site's frame, within `deep` m:
-- → { x, z, d (floor depth), roof (roof depth), s0 (the ground there, + up),
-- nat } or nil. Field reads every 1.5 m down the column and three rays.
local function chamber_under(b, g, cx, cz, deep)
  local tx, ty, tz = frame_pt(g, cx, 0, cz)
  local ux, uy, uz = g.ux, g.uy, g.uz
  local ok, h = pcall(terrain.raycast, vec3(b.x + tx + ux * 30, b.y + ty + uy * 30, b.z + tz + uz * 30), vec3(-ux, -uy, -uz), 80)
  if not (ok and h and h.distance) then return nil end
  local s0 = 30 - h.distance
  local y = s0 - 2.5
  while y > -deep do
    local q = terrain.query(b.x + tx + ux * y, b.y + ty + uy * y, b.z + tz + uz * y)
    if q and q > 1.0 then
      local px, py, pz = b.x + tx + ux * y, b.y + ty + uy * y, b.z + tz + uz * y
      local okd, hd = pcall(terrain.raycast, vec3(px, py, pz), vec3(-ux, -uy, -uz), 40)
      local oku, hu = pcall(terrain.raycast, vec3(px, py, pz), vec3(ux, uy, uz), 40)
      if okd and hd and hd.distance and oku and hu and hu.distance and hd.distance + hu.distance >= 3.0 then
        local d = -(y - hd.distance)
        if d <= deep then return { x = cx, z = cz, d = d, roof = -(y + hu.distance), s0 = s0, nat = true } end
      end
      return nil
    end
    y = y - 1.5
  end
  return nil
end

-- Look for the site's cave (see WHEN). → sh | false
function findCave(s, e, b)
  local g = e.g
  if s.kind == "mine" then
    -- (rings round the head, clear of its slabs, gantry, shack and tower)
    local cols = {}
    for _, rr in ipairs({ 14, 24, SHAFT_REACH }) do
      for k = 0, 7 do local a = k * math.pi / 4; cols[#cols + 1] = { 2 + math.cos(a) * rr, -2 + math.sin(a) * rr } end
    end
    for _, c in ipairs(cols) do
      local sh = chamber_under(b, g, c[1], c[2], SHAFT_R)
      if sh then return sh end
    end
    return false
  end
  if s.kind == "sinkcamp" then
    local sh = chamber_under(b, g, 0, 0, 45)
    if sh and sh.d >= 6 then return sh end
    return { x = 0, z = 0, d = SINK_D, s0 = 0, nat = false }
  end
  return false
end

-- Dig it, once: balls down the column, a room at the foot, the floor levelled.
local function dig_cave(s, e, b)
  local sh = e.sh
  if not (sh and terrain and terrain.dig) or sh.dug then return 0 end
  local g = e.g
  local n = 0
  local function dig(x, y, z, r)
    local px, py, pz = frame_pt(g, x, y, z)
    if pcall(terrain.dig, b.x + px, b.y + py, b.z + pz, r, 1.0, { hardness = 1.0, falloff = "sharp" }) then n = n + 1 end
  end
  local function flat(x, y, z, r)
    if not terrain.sculpt then return end
    local px, py, pz = frame_pt(g, x, y, z)
    if pcall(terrain.sculpt, b.x + px, b.y + py, b.z + pz, r, 1.0, "flatten", { hardness = 0.8, falloff = "smooth" }) then n = n + 1 end
  end
  if s.kind == "mine" then
    local x0 = sh.x
    local y = (sh.s0 or 0) + 2.5
    while y > -sh.d + 2.2 do dig(x0, y, sh.z, 3.4); y = y - 1.6 end
    dig(x0, -sh.d + 2.2, sh.z, 3.4)
    dig(x0 + 3.6, -sh.d + 2.0, sh.z, 3.2)
    flat(x0, -sh.d, sh.z, 3.0)
    flat(x0 + 3.6, -sh.d, sh.z, 3.0)
  elseif s.kind == "sinkcamp" then
    local bottom = sh.nat and ((sh.roof or sh.d) + 1.0) or sh.d
    local y = 2.0
    while y > -bottom + SINK_R * 0.6 do dig(0, y, 0, SINK_R); y = y - 3.0 end
    dig(0, -bottom + SINK_R * 0.6, 0, SINK_R)
    -- (in a chamber: room round the camp, so its door does not open on rock)
    if sh.nat then dig(0, -sh.d + 2.8, 0, 5.5); dig(-3.5, -sh.d + 2.4, 1.0, 3.5) end
    flat(0, -sh.d, 0, sh.nat and 5.0 or (SINK_R - 1))
  end
  sh.dug = n
  write()
  if log then log(string.format("ruins: %s: %s dug (%d edits, floor %.1f m down, %s)", s.name, s.kind == "mine" and "shaft" or "sink",
    n, sh.d, sh.nat and "into a chamber" or "a doline")) end
  return n
end

local function cave_found(s, e, b)
  if not e.sh then return end
  if e.sid and not touched(s.id) then unstampNow(s.id) end
  dig_cave(s, e, b)
  if not e.sid then stampNow(s.id, true) end
  if s.kind == "mine" then s.caveLine = shaftLine(s, e.sh, ores_of(s.body)[1]) end
  bump()
end

-- Probes: look for the site's cave and dig it now (the crew anywhere).
function caveNow(id)
  local s, e = site(id), peek(id)
  local b = s and space.body(s.body)
  if not (s and e and e.g and b and terrain and terrain.query) then return nil, "not sited" end
  e.sh = findCave(s, e, b)
  write()
  cave_found(s, e, b)
  return e.sh
end
-- Probes: make a site this kind ("mine" | "sinkcamp"), saved (e.fk).
function forceCaveKind(id, kind)
  local s = site(id)
  if not s then return false end
  local e = state(id)
  if e.sid and not touched(id) then unstampNow(id) end
  e.fk, e.sh = kind, nil
  s.kind = kind
  s.name = siteName(s.co, kind, s.num)
  write()
  bump()
  return true
end

function cave_tick(name, b, px, py, pz, list)
  if not (terrain and terrain.query and terrain.raycast) then return end
  local R = b.radius or 800
  for _, s in ipairs(list) do
    if not s.pending and (s.kind == "mine" or s.kind == "sinkcamp") then
      local e = peek(s.id)
      if e and e.sid and e.g and e.sh == nil and not e.drop then
        local d = groundDist(R, px, py, pz, e.g.x, e.g.y, e.g.z)
        if d < CAVE_NEAR and (not terrain.ready or terrain.ready(b.x + e.g.x, b.y + e.g.y, b.z + e.g.z, 12)) then
          e.sh = findCave(s, e, b)
          write()
          cave_found(s, e, b)
        end
      end
    end
  end
end


-- ════════════════════════════════════════════════════════════════════════════
-- THE RUIN NEAR HOME (progression R1, work/progression/PLAN.md §4). Ty, 11-11:
-- "at least one abandoned base should spawn near the home base." Kept apart
-- from the rest of the file: it hooks in at marked lines (blueprintOf,
-- lockPlan, lore, build_sites, tick, stampNow, readCores).
--
--   THE SITE   one more site on the home world, "<home>#near" (sitesFor is
--              untouched: every other site keeps its seed, id and kind). A
--              survey camp (3 in 5) or a relay post, empty 400–900 days.
--              An old save gets it on load too, unless one of its sites
--              already stands within NEAR_HAVE m of the spaceport (that one
--              is pointed at instead: e.alias).
--   SITING     once the crew is within STAMP_R of the pad: a spot in the
--              ring NEAR_RING m from the spaceport's middle (bases.SPACING
--              and BASE_MIN hold, so claiming it founds a legal base; inside
--              STAMP_R from the pad, so it stands from the first minute).
--              The flattest of 16 bearings at NEAR_MID; else the first flat
--              spot of 36 bearings × 3 radii; else the flattest under
--              NEAR_RELAX m; else rings further out (NEAR_FAR); else the
--              flattest dry, clear spot of all. Never dropped: a world with
--              no dry ground in the whole annulus tries again next session.
--              Clear of the player's structures (BUILT_MIN), bases
--              (BASE_MIN), the Tracking Station (BASE_MIN) and other ruins.
--              Its door faces the pad. NEAR_BUDGET spots a tick (nearStep).
--   THE YARD   the camp's (or relay's) build plus a power yard: two Solar
--              Arrays (one sound, one knocked over: a Repair Kit once
--              claimed) and a flat Battery Bank; a Personnel Locker always
--              on a code, never a door; the shift note with the code in the
--              outside crate, with a crated Solar Panel and a Repair Kit
--              (loot.planSite); the terminal's Data Core.
--   THE LOG    an authored three-entry log (nearLore) naming the next site;
--              its survey note (loot) finds it, and so does reading the core.
--   FOUND      by walking up to it (NEAR_FIND_R), not from the pad: the
--              crew stands within DISCOVER_R of it the moment they land.
--   THE POINTER once First Steps is done, Ops says on the radio where it is
--              (ops_strip, one line, once: ruins.s[id].ptr). No marker.
--   CLAIMING   as any ruin: its tower founds a base (base_tower), which
--              grants the Solar Array and the Battery Bank (feats).
-- Not in a scenario (game.mode "scenario": the author's world is the author's).
--
-- Pure: NEAR_*, nearSite, nearPlan, ringDir, nearClear, nearStep, compass,
-- nearExtras, nearLocked, nearLore. Probes: nearNow(), nearOf(body).
NEAR_RING = { 330, 400 }   -- m from the spaceport's middle
NEAR_MID = 365
NEAR_FIND_R = 120.0        -- m: found by walking up to it
NEAR_RELAX = 3.0           -- m over 11 m: a ruin may lean
NEAR_FAR = { 450, 525, 600, 700, 800 }
NEAR_HAVE = 450.0          -- m: an old save's site this near the spaceport is the near one
NEAR_BUDGET = 24           -- spots looked at a tick (9 field raycasts each)
NEAR_KIND = { { "camp", 3 }, { "relay", 2 } }
NEAR_AGE = { 400, 900 }
nearStats = { tries = 0, ms = 0, picked = nil }

-- The near site of home world `name` (pure). `others`: the world's sites
-- (its name is kept apart from theirs; `other` = the first real one, the
-- site its log names).
function nearSite(name, w, others)
  w = type(w) == "table" and w or {}
  local r = rng(hash(tostring(name) .. ":" .. tostring(w.seed or 0) .. ":near"))
  local kind = pick(r, NEAR_KIND)
  local co = 1 + math.floor(r() * #COMPANIES)
  local num = 1 + math.floor(r() * 9)
  local taken = {}
  local other = nil
  for _, o in ipairs(others or {}) do
    taken[o.name or ""] = true
    if not other and not o.pending and not o.near then other = o end
  end
  for _ = 1, 9 do
    if not taken[siteName(co, kind, num)] then break end
    num = num % 9 + 1
  end
  return { id = tostring(name) .. "#near", body = name, kind = kind, class = "inhabited", near = true,
           ux = 0, uy = 1, uz = 0, age = math.floor(NEAR_AGE[1] + r() * (NEAR_AGE[2] - NEAR_AGE[1])), yaw = 0,
           seed = math.floor(r() * 2147483000) + 1, co = co, num = num, name = siteName(co, kind, num),
           other = other and other.id or nil, otherName = other and other.name or nil, life = nil }
end

-- The spots tried, in order (pure): { b (bearing, rad), d (m), ph }:
-- ph 1 the 16 bearings at NEAR_MID, ph 2 36 bearings × 3 radii in the ring,
-- ph 3 36 bearings on each of NEAR_FAR.
function nearPlan(seed)
  local r = rng(seed or 1)
  local b0 = r() * 2 * math.pi
  local P = {}
  for k = 0, 15 do P[#P + 1] = { b = b0 + k * 2 * math.pi / 16, d = NEAR_MID, ph = 1 } end
  for _, d in ipairs({ NEAR_MID, NEAR_RING[1] + 5, NEAR_RING[2] - 5 }) do
    for k = 0, 35 do P[#P + 1] = { b = b0 + (k + 0.5) * 2 * math.pi / 36, d = d, ph = 2 } end
  end
  for _, d in ipairs(NEAR_FAR) do
    for k = 0, 35 do P[#P + 1] = { b = b0 + k * 2 * math.pi / 36, d = d, ph = 3 } end
  end
  return P
end

-- The unit direction `d` m along the ground from unit (fx, fy, fz) on bearing
-- `b` (0 = the tangent basis's e1; pure).
function ringDir(fx, fy, fz, b, d, R)
  local e1x, e1y, e1z, e2x, e2y, e2z = tangent(fx, fy, fz)
  local th = d / (R or 800)
  local c, sn = math.cos(th), math.sin(th)
  local tx = e1x * math.cos(b) + e2x * math.sin(b)
  local ty = e1y * math.cos(b) + e2y * math.sin(b)
  local tz = e1z * math.cos(b) + e2z * math.sin(b)
  local ux, uy, uz = fx * c + tx * sn, fy * c + ty * sn, fz * c + tz * sn
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  return ux / l, uy / l, uz / l
end

-- Is the body-relative ground point clear for the near site? (pure)
-- w = { R, fp = {x,y,z} (the spaceport's middle), station = {x,y,z} | nil,
-- bases = { {x,y,z} }, structs = { {x,y,z} } (the player's), ruins = { {x,y,z} } }
function nearClear(w, gx, gy, gz)
  local R = w.R or 800
  if w.fp and groundDist(R, gx, gy, gz, w.fp.x, w.fp.y, w.fp.z) < NEAR_RING[1] - 1 then return false, "the spaceport" end
  if w.station and groundDist(R, gx, gy, gz, w.station.x, w.station.y, w.station.z) < BASE_MIN then return false, "the Tracking Station" end
  for _, p in ipairs(w.bases or {}) do
    if groundDist(R, gx, gy, gz, p.x, p.y, p.z) < BASE_MIN then return false, "a base" end
  end
  for _, p in ipairs(w.structs or {}) do
    if groundDist(R, gx, gy, gz, p.x, p.y, p.z) < BUILT_MIN then return false, "a structure" end
  end
  for _, p in ipairs(w.ruins or {}) do
    if groundDist(R, gx, gy, gz, p.x, p.y, p.z) < 60 then return false, "another ruin" end
  end
  return true
end

-- One step of the search (pure). st = { plan, res, i, clear(gx,gy,gz) → ok }
-- (kept between ticks); probe(p) → { spread, dry, gx, gy, gz, … } | nil, why
-- ("wait": the ground isn't made: try again later; anything else: no ground
-- there). → the index of the spot taken | nil, "more" | "wait" | "no room"
function nearStep(st, probe, budget)
  st.plan = st.plan or nearPlan(st.seed)
  st.res = st.res or {}
  st.i = st.i or 1
  local P, res = st.plan, st.res
  local function ok(r, lim) return type(r) == "table" and r.dry and r.clear and r.spread <= lim end
  local function best(lo, hi, lim)
    local bi, bs = nil, math.huge
    for i, p in ipairs(P) do
      local r = res[i]
      if p.ph >= lo and p.ph <= hi and ok(r, lim) and r.spread < bs then bi, bs = i, r.spread end
    end
    return bi
  end
  local spent = 0
  while true do
    local p = P[st.i]
    local ph = p and p.ph or 99
    if ph > 1 and not st.d1 then st.d1 = true; local k = best(1, 1, FLAT_SPREAD); if k then return k end end
    if ph > 2 and not st.d2 then st.d2 = true; local k = best(1, 2, NEAR_RELAX); if k then return k end end
    if ph > 3 then
      local k = best(3, 3, NEAR_RELAX) or best(1, 2, math.huge) or best(3, 3, math.huge)
      if k then return k end
      return nil, "no room"
    end
    if spent >= (budget or 1e9) then return nil, "more" end
    local r, why = probe(p)
    if r == nil and why == "wait" then return nil, "wait" end
    if type(r) == "table" and r.dry and st.clear then
      local c, cwhy = st.clear(r.gx, r.gy, r.gz)
      r.clear, r.why = c, cwhy
    elseif type(r) == "table" and r.clear == nil then
      r.clear = not st.clear
    end
    res[st.i] = r or false
    spent = spent + 1
    st.i = st.i + 1
    if ph >= 2 and ok(r, FLAT_SPREAD) then return st.i - 1 end
  end
end

-- "north-east": the way from unit u to point t, on the ground (pure; north
-- is the body's +Y, as latlon's).
WAYS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
function compass(ux, uy, uz, tx, ty, tz)
  local nx, ny, nz = -ux * uy, 1 - uy * uy, -uz * uy
  local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
  if nl < 1e-6 then nx, ny, nz, nl = 1, 0, 0, 1 end
  nx, ny, nz = nx / nl, ny / nl, nz / nl
  local ex, ey, ez = uy * nz - uz * ny, uz * nx - ux * nz, ux * ny - uy * nx
  local d = tx * ux + ty * uy + tz * uz
  local vx, vy, vz = tx - ux * d, ty - uy * d, tz - uz * d
  local fe, fn = vx * ex + vy * ey + vz * ez, vx * nx + vy * ny + vz * nz
  local a = math.atan2 and math.atan2(fe, fn) or math.atan(fe, fn)
  local k = math.floor(((a / (2 * math.pi)) * 8 + 0.5)) % 8
  return WAYS[k + 1]
end

-- The power yard and the store, appended to the build (every piece before
-- keeps its index). A camp's yard behind the hut; a relay's arrays are its
-- own (the first stood up again), a locker and a desk by its junction box.
function nearExtras(site, P)
  local function add(id, x, y, z, yaw, roll, rl, extra)
    local e = { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = roll or 0, rl = rl }
    for k, v in pairs(extra or {}) do e[k] = v end
    P[#P + 1] = e
    return #P
  end
  if site.kind == "relay" then
    for _, p in ipairs(P) do
      if p.id == "solarArray" then p.roll = 0; p.rl = "power"; break end   -- (the other stays over: rl array, knocked)
    end
    local tb = add("table.steel", -0.15, T, 0.45, 0, 0, "fix")
    add("monitor.steel", -0.15, T + 0.74, 0.4, 0, 0, "fix", { dep = tb })
    add("locker.steel", -0.75, T, -1.2, Q, 0, "store", { paint = "olive" })
  else
    add("solarArray", -0.6, 0, -6.5, 0, 0, "power")
    add("solarArray", 3.9, 0, -6.5, 0, -1.15, "array")   -- (4.5 m apart: the fallen one clear of the standing one)
    add("batteryBank", 7.0, 0, -3.6, 0, 0, "power", { fill = 0 })
  end
  return P
end
-- The near site's locks: its lockers, never a door (pure)
function nearLocked(name) return name == "locker" end

-- The near site's log: the survey team, why they left, where the others went.
NEAR_LORE = {
  { "Day %d before the agency's calendar. %s's survey team moves into the camp: four of us, two arrays, one battery bank, a year's contract.",
    "%d days before Day 1. %s sets the camp on the flat by the old survey line: panels up, the bank charging, the core logging every shift." },
  { "The storm took the east array over in the night. The bank never held a whole night after that, and the company would not ship a new one.",
    "The battery ran flat every night once the east array went over. We stopped heating the hut and started counting days." },
  { "The others went on to %s. Its position is in the survey note in the crate. The locker code is in there too.",
    "Packed what we could. The rest of the crew walked to %s: the survey note in the crate has where. Locker code's on it." },
}
function nearLore(site)
  local r = rng(hash(tostring(site and site.seed or 1) .. ":nearlore"))
  local a = NEAR_LORE[1][1 + math.floor(r() * 2)]
  local b = NEAR_LORE[2][1 + math.floor(r() * 2)]
  local c = NEAR_LORE[3][1 + math.floor(r() * 2)]
  local d = math.floor((site and site.age or 400) + 30 + r() * 40)
  return { string.format(a, d, COMPANIES[site and site.co or 1] or "Pell Groundworks"), b,
           string.format(c, site and site.otherName or "the relay over the ridge") }
end

-- ── the scene ───────────────────────────────────────────────────────────────
local NEAR = { st = {}, said = {} }
function near_sites(name, w, list, home)
  if not home then return end
  if save and save.get and save.get("game.mode") == "scenario" then return end
  local s = nearSite(name, w, list)
  local e = peek(s.id)
  if e and e.g then
    local l = math.sqrt(e.g.x ^ 2 + e.g.y ^ 2 + e.g.z ^ 2)
    if l > 1e-6 then s.ux, s.uy, s.uz = e.g.x / l, e.g.y / l, e.g.z / l end
  else
    -- (not sited yet: every list skips it as it skips a pending site, until near_tick sites it)
    s.pending = true
  end
  if e and e.alias then s.pending = true end
  list[#list + 1] = s
end
function nearOf(body)
  for _, s in ipairs(sites(body)) do if s.near then return s end end
  return nil
end

-- The world as the near site's clearance reads it (body-relative points).
function NEAR.world(name, R, fp)
  local w = { R = R, fp = fp, bases = {}, structs = {}, ruins = {} }
  local net = ref("comms")
  local b = space and space.body and space.body(name)
  if net and net.station and b then
    local ok, sx, sy, sz = pcall(net.station)
    if ok and sx then w.station = { x = sx - b.x, y = sy - b.y, z = sz - b.z } end
  end
  local B = ref("bases")
  for _, r in ipairs(B and B.list and B.list() or {}) do if r.b == name then w.bases[#w.bases + 1] = r end end
  local ST = ref("structures")
  for _, r in ipairs(ST and ST.list and ST.list() or {}) do if r.b == name and not r.ru then w.structs[#w.structs + 1] = r end end
  for _, o in ipairs(sites(name)) do
    local e = peek(o.id)
    if not o.near and e and e.g and e.sid then w.ruins[#w.ruins + 1] = e.g end
  end
  return w
end

-- 9 field raycasts round a ring spot: → { spread, dry, gx, gy, gz, ux, uy, uz, exact } | nil, why
function NEAR.probe(b, R, relief, sea, fu, p, force)
  local ux, uy, uz = ringDir(fu.x, fu.y, fu.z, p.b, p.d, R)
  local h0, exact = cast(b, R, relief, ux, uy, uz)
  if not h0 then return nil, "wait" end
  if not exact and not force then return nil, "wait" end
  local hs = { h0 }
  local f1x, f1y, f1z, f2x, f2y, f2z = tangent(ux, uy, uz)
  for j = 0, 7 do
    local a = j * math.pi / 4
    local d = 11 / R
    local vx = ux + (f1x * math.cos(a) + f2x * math.sin(a)) * d
    local vy = uy + (f1y * math.cos(a) + f2y * math.sin(a)) * d
    local vz = uz + (f1z * math.cos(a) + f2z * math.sin(a)) * d
    local l = math.sqrt(vx * vx + vy * vy + vz * vz)
    local h = cast(b, R, relief, vx / l, vy / l, vz / l)
    if not h then return nil, "wait" end
    hs[#hs + 1] = h
  end
  local lo, hi, sum = 1e18, -1e18, 0
  for _, h in ipairs(hs) do lo = math.min(lo, h); hi = math.max(hi, h); sum = sum + h end
  local gr = sum / #hs - 0.15
  return { spread = hi - lo, dry = not (sea > 0 and h0 < sea + 1.0), gx = ux * gr, gy = uy * gr, gz = uz * gr,
           ux = ux, uy = uy, uz = uz, exact = exact }
end

-- The ground frame for a spot: up, and front toward the spaceport (its door faces the pad).
function nearFrame(r, fp)
  local ux, uy, uz = r.ux, r.uy, r.uz
  local dx, dy, dz = fp.x - r.gx, fp.y - r.gy, fp.z - r.gz
  local d = dx * ux + dy * uy + dz * uz
  local fx, fy, fz = dx - ux * d, dy - uy * d, dz - uz * d
  local l = math.sqrt(fx * fx + fy * fy + fz * fz)
  if l < 1e-6 then fx, fy, fz = tangent(ux, uy, uz); l = 1 end
  return { x = r.gx, y = r.gy, z = r.gz, ux = ux, uy = uy, uz = uz, fx = fx / l, fy = fy / l, fz = fz / l }
end

-- Ops on the radio, once First Steps is done: where the structure is (pure
-- but for the save's word on the programme). → the line | nil
function nearLine(tgt, fp, R, x, y, z)
  local l = math.sqrt(fp.x ^ 2 + fp.y ^ 2 + fp.z ^ 2)
  local d = groundDist(R, fp.x, fp.y, fp.z, x, y, z)
  local way = compass(fp.x / l, fp.y / l, fp.z / l, x, y, z)
  return string.format("Survey flight logged a structure about %d m %s of the pad. An old %s by the look of it, nobody on our books. Worth a walk.",
    math.floor(d / 50 + 0.5) * 50, way, LABEL[tgt.kind] or "survey camp")
end
lastPointer = nil
function NEAR.pointer(s, e, fp, R)
  if e.ptr or NEAR.said[s.id] then return end
  local tgt = s
  if e.alias then tgt = site(e.alias) or s end
  if discovered(tgt.id) then return end
  local done = save and save.get and save.get("prog.done")
  if not (type(done) == "table" and done.first_steps) then return end
  local line = nearLine(tgt, fp, R, pointOf(tgt))
  NEAR.said[s.id] = true
  e.ptr = agency_now()
  write()
  lastPointer = { id = tgt.id, line = line, t = now() }
  local strip = ref("ops_strip")
  if strip and strip.say then pcall(strip.say, line, "Ops")
  elseif caption then pcall(caption, "Ops: " .. line) end
  if log then log("ruins: OPS: " .. line) end
end

function near_tick(name, b, px, py, pz, list)
  local s = nil
  for _, o in ipairs(list) do if o.near then s = o end end
  if not s then return end
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if not (fp and fp.body == name) then return end
  local R = b.radius or 800
  local e = peek(s.id)
  if e and (e.g or e.alias) then NEAR.pointer(s, e, fp, R) return end
  -- (an old save with a site already near home: that one is the near one)
  for _, o in ipairs(list) do
    local eo = peek(o.id)
    if not o.near and not o.pending and eo and eo.g and groundDist(R, fp.x, fp.y, fp.z, eo.g.x, eo.g.y, eo.g.z) < NEAR_HAVE then
      state(s.id).alias = o.id
      write()
      if log then log(string.format("ruins: near home already: %s", o.name)) end
      return
    end
  end
  if groundDist(R, px, py, pz, fp.x, fp.y, fp.z) > STAMP_R then return end
  local st = NEAR.st[s.id]
  if st and st.gave_up then return end
  if not st then st = { t0 = now(), seed = s.seed }; NEAR.st[s.id] = st end
  local w0 = wall()
  local wv = NEAR.world(name, R, fp)
  st.clear = function(gx, gy, gz) return nearClear(wv, gx, gy, gz) end
  local w = world(name)
  local relief, sea = tonumber(w.relief) or 60, tonumber(w.sea) or 0
  local fl = math.sqrt(fp.x ^ 2 + fp.y ^ 2 + fp.z ^ 2)
  local fu = { x = fp.x / fl, y = fp.y / fl, z = fp.z / fl }
  local force = now() - st.t0 > 20
  local k, why = nearStep(st, function(p) return NEAR.probe(b, R, relief, sea, fu, p, force) end, NEAR_BUDGET)
  nearStats.tries = st.i - 1
  nearStats.ms = (wall() - w0) * 1000
  if k then
    local r = st.res[k]
    local g = nearFrame(r, fp)
    local e2 = state(s.id)
    e2.g = g
    write()
    s.ux, s.uy, s.uz, s.pending = r.ux, r.uy, r.uz, nil
    nearStats.picked = { i = k, ph = st.plan[k].ph, d = st.plan[k].d, spread = r.spread,
                         dist = groundDist(R, fp.x, fp.y, fp.z, g.x, g.y, g.z) }
    NEAR.st[s.id] = nil
    bump()
    if log then log(string.format("ruins: the ruin near home, %s (%s), sited %.0f m from the pad (spot %d, phase %d, %.1f m over 11 m) after %d spots, %.2f ms",
      s.name, s.kind, nearStats.picked.dist, k, nearStats.picked.ph, r.spread, st.i - 1, nearStats.ms)) end
  elseif why == "no room" then
    st.gave_up = true
    if log then log("ruins: no dry, clear ground 330-800 m round the spaceport for the ruin near home: next session") end
  end
end

-- Probe: site the near ruin now (the crew near the pad), however many ticks it takes.
function nearNow(force)
  if not SITES then build_sites() end
  local a = find and find("Astronaut")
  if not a then return nil, "no crew" end
  local name = space.dominant(a.x, a.y, a.z)
  local b = name and space.body(name)
  if not b then return nil, "no body" end
  local s = nearOf(name)
  if not s then return nil, "no near site" end
  if force and NEAR.st[s.id] then NEAR.st[s.id].t0 = -100 end
  for _ = 1, 40 do
    near_tick(name, b, a.x - b.x, a.y - b.y, a.z - b.z, sites(name))
    local e = peek(s.id)
    if e and (e.g or e.alias) then return s end
    local st = NEAR.st[s.id]
    if st and st.gave_up then return nil, "no room" end
    if force and st then st.t0 = -100 end
  end
  return nil, "wait"
end
