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
  local g = GRAMMAR[site and site.kind] or GRAMMAR.camp
  return g(site)
end
function kinds() return { "camp", "mine", "hab", "reactor", "relay" } end

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
  local r = rng(hash((site and site.seed or 1) .. ":lore"))
  local a = LORE_A[1 + math.floor(r() * #LORE_A)]
  local b = LORE_B[1 + math.floor(r() * #LORE_B)]
  local c = LORE_C[1 + math.floor(r() * #LORE_C)]
  local d = math.floor((site and site.age or 400) + r() * 40)
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
      SITES[b.name] = list
      for _, s in ipairs(list) do BYID[s.id] = s end
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
  if not quiet then
    local x, y, z = pointOf(s)
    if how == "telescope" then
      say("ANOMALY", string.format("a regular shape at %s on %s · %s", latlon(x, y, z), s.body, s.name), 5.0)
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
    local g, why = siteGround(s, force)
    if not g then
      if why ~= "wait" then e.drop = why; write(); if log then log("ruins: " .. s.name .. " dropped: " .. tostring(why)) end end
      return nil, why
    end
    e.g = { x = g.x, y = g.y, z = g.z, ux = g.ux, uy = g.uy, uz = g.uz, fx = g.fx, fy = g.fy, fz = g.fz }
  end
  local w0 = wall()
  local kept, ds = decay(blueprintOf(s), s)
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
  for _, s in ipairs(list) do
    if not s.pending then
      local x, y, z = pointOf(s)
      local d = groundDist(R, px, py, pz, x, y, z)
      stats.dist = math.min(stats.dist or 1e18, d)
      local e = peek(s.id)
      if d < DISCOVER_R and not (e and (e.dsc or e.drop)) then discover(s.id, "proximity") end
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
function restoreQuote(id)
  local s, e = site(id), peek(id)
  local ST = ref("structures")
  local r = e and e.sid and ST and ST.get(e.sid)
  if not (s and r) then return { n = 0, cost = 0, list = {} } end
  local list = missing(blueprintOf(s), r.bp)
  local cost = 0
  for _, m in ipairs(list) do cost = cost + price_of(m.piece.id) end
  return { n = #list, cost = cost, list = list }
end
function restore(id, free)
  local q = restoreQuote(id)
  if q.n == 0 then return 0, "nothing is missing" end
  local co = ref("company")
  if not free and co and co.spend and not co.spend(q.cost, string.format("restore %d pieces at %s", q.n, site(id).name)) then
    return 0, string.format("restoring costs $%d", q.cost)
  end
  local e = peek(id)
  local ST = ref("structures")
  local n = 0
  for _, m in ipairs(q.list) do
    local p = m.piece
    local uid = ST.addPart(e.sid, { id = p.id, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll, paint = p.paint,
                                    ri = m.ri, rl = p.rl, fill = p.fill })
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
  if part.rl == "loot" then
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
