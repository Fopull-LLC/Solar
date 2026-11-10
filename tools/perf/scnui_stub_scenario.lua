-- A STAND-IN for scripts/scenario.lua (FW-A's rulebook), for scnuishots.sh
-- only: the harness copies it into the scratch project as scripts/scenario.lua
-- when the checkout has no rulebook yet. It carries just the surface the menu
-- page reads (work/scn_fwa/API.md): SLOT, load, listAll, worldKeys,
-- prepareSlot, slotSummary, profileLoad / profileSave. Never shipped.
-- The game's VM (Luau) has no loadfile: scnuishots.sh prepends the fixture
-- tables as FIX[id] = (function() … end)().
SLOT = "scn"
FIX = FIX or {}

local function read_table(id)
  if FIX[id] then return FIX[id] end
  local f = loadfile and loadfile("scenarios/" .. id .. ".lua")
  if not f then return nil, "no scenarios/" .. id .. ".lua" end
  local ok, t = pcall(f)
  if not ok then return nil, tostring(t) end
  return t
end
function load(id) return read_table(id) end

function listAll()
  local out = {}
  local files = {}
  for id in pairs(FIX) do files[#files + 1] = "scenarios/" .. id .. ".lua" end
  if #files == 0 and assets and assets.getContents then files = assets.getContents("scenarios") or {} end
  for _, p in ipairs(files) do
    local id = p:match("^scenarios/([%w_]+)%.lua$")
    if id and id:sub(1, 1) ~= "_" then
      local sc, err = read_table(id)
      if sc then
        out[#out + 1] = { id = sc.id or id, title = sc.title, blurb = sc.blurb, teaches = sc.teaches,
          par = sc.score and sc.score.par, requires = sc.requires, steps = #(sc.steps or {}), v = sc.v, order = sc.order }
      else
        out[#out + 1] = { id = id, title = id, err = err }
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.order or 99) ~= (b.order or 99) then return (a.order or 99) < (b.order or 99) end
    return tostring(a.title) < tostring(b.title)
  end)
  return out
end

function worldKeys(sc)
  local w = type(sc.world) == "table" and sc.world or {}
  local k = { g_seed = w.seed or 1911564384, g_scale = w.scale or 4, g_names = w.names or 2, g_air = w.air or "earth",
              g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
              g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0,
              g_scenario = sc.id, g_scenarioV = sc.v or 1 }
  if w.home == "alien" then k.g_homeKind, k.g_homeSeed = "alien", w.homeSeed or 1 end
  local st = sc.start or {}
  k["game.mode"] = "scenario"
  k["crew.safety"] = st.safety or "rescue"
  k["crew.death"] = (st.safety == "death")
  return k
end

function prepareSlot(id)
  local sc, err = read_table(id)
  if not sc then return false, err end
  terrain.deleteSaveDir("saves/" .. SLOT .. "/terrain")
  if save.deleteSlot then save.deleteSlot(SLOT) end
  save.slot(SLOT)
  for k, v in pairs(worldKeys(sc)) do save.set(k, v) end
  return true
end

function slotSummary(get)
  local id = get("g_scenario")
  if not id then return nil end
  local sc = read_table(id) or {}
  local done = get("scn.done") or {}
  local n = 0
  for _ in pairs(done) do n = n + 1 end
  return { id = id, title = sc.title or id, step = n + 1, steps = #(sc.steps or {}), outcome = get("scn.outcome") }
end

local PROFILE = "user://scenarios/profile.json"
function profileLoad()
  if not (assets and assets.readJson) then return {} end
  local ok, p = pcall(assets.readJson, PROFILE)
  return (ok and type(p) == "table") and p or {}
end
function profileSave(p)
  if assets and assets.writeJson then pcall(assets.writeJson, PROFILE, p or {}) end
end
