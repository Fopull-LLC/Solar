-- SCENARIO — the rulebook of a scripted mission (work/scenarios/PLAN.md §1,
-- docs/scenarios.md). PURE: it loads in luajit (tests/smoke_scenarios.lua), in
-- the menu scene (from disk, as builder.lua's lib() does) and on the
-- ScenarioLib node beside scenario_run.lua, which is its scene half.
--
-- A scenario is a pre-made situation with a script: a fixed start state written
-- into its own save slot (`scn`, never a career's), an ordered list of steps
-- whose goals are read off the world, beats on the step edges, fail
-- conditions, a score with a medal, and a debrief. The table format is PLAN
-- §1.3 and scenarios/_template.lua; this file
--
--   * loads `scenarios/<id>.lua` (a Lua chunk run with no globals but math,
--     string and table) and lists every scenario in the folder;
--   * validates one, every error naming its field ("steps[3].goals[1].kind:
--     unknown kind 'roms'");
--   * resolves refs and SITING RULES into body-relative ground points from a
--     ground query the scene half supplies — a scenario file never holds a
--     world point (docs/positions-and-frames.md rule 1);
--   * runs the step machine (which steps are open, which is current, done);
--   * evaluates goals: every kind reads the world through an adapter `W` the
--     scene half builds (tests hand a stub), returns met and a READING (why it
--     is not met yet), and `hold` latches a goal only after it has read true
--     for that many game seconds;
--   * scores a run, gives the medal, and keeps the profile shape
--     (user://scenarios/profile.json, outside every slot);
--   * writes the keys a new scenario slot needs (worldKeys / prepareSlot) and
--     serialises a world dump as a `start` table (F12's text).
--
-- Goal truth is derived; step completion is latched (by the scene half, into
-- `scn.done`). Beats are a closed set (BEATS). Nothing here touches a node.

SLOT = "scn"
DIR = "scenarios"
PROFILE = "user://scenarios/profile.json"
MEDALS = { "gold", "silver", "bronze" }
HINT_SECS, HINT2_SECS = 90, 180      -- the hint shows after this long without progress; the second after this
EVAL_HZ = 4                           -- how often the scene half evaluates (agency clock)

-- The generator's sliders as the new-save panel leaves them (scenes/menu.ron,
-- perfbench boot()): a scenario's `world.gen` overrides any of them.
GEN_DEFAULTS = { g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                 g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }
WORLD_SCALE = 4                       -- menu_newsave WORLD_SCALE when a scenario names none

-- ── small helpers ───────────────────────────────────────────────────────────
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-12 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end
local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
local function dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
deepCopy = copy

-- ── loading ─────────────────────────────────────────────────────────────────
-- A scenario file's text: the engine's assets (paths relative to the project),
-- else the disk (luajit runs from the folder holding `solar/`).
local function read_text(path)
  if assets and assets.readText then
    local ok, t = pcall(assets.readText, path)
    if ok and type(t) == "string" then return t end
  end
  if io and io.open then
    for _, p in ipairs({ "solar/" .. path, path, "../Solar/" .. path }) do
      local f = io.open(p, "rb")
      if f then local t = f:read("*a"); f:close(); return t end
    end
  end
  return nil
end
readText = read_text

-- A JSON file of the scenario's (a craft), decoded: → value | nil, why
function readJson(path)
  if assets and assets.readJson then
    local ok, v, why = pcall(assets.readJson, path)
    if ok and v ~= nil then return v end
    if ok then return nil, why end
  end
  local t = read_text(path)
  if not t then return nil, "no file " .. path end
  if json and json.decode then
    local ok, v = pcall(json.decode, t)
    if ok then return v end
    return nil, tostring(v)
  end
  return t ~= "" and { raw = t } or nil, "no json decoder"
end

-- What a scenario chunk may see: no engine, no save, no files.
local function sandbox()
  return { math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, tostring = tostring,
           tonumber = tonumber, type = type, select = select, unpack = unpack }
end

-- ── the data reader ─────────────────────────────────────────────────────────
-- A scenario file is DATA written as a Lua table: `return { … }` with strings,
-- numbers, true/false/nil, nested tables, `[key] =` and `name =` fields,
-- comments. It is READ, never run: the engine's Luau has no loadstring (and a
-- mod must not run code), so this small parser is the only way in, under
-- luajit too. No expressions, no functions, no variables: `math.pi` is an
-- error that names the line.
local function data_error(path, line, msg) return string.format("%s:%d: %s", path or "?", line or 0, msg) end
function parseData(text, path)
  local i, n, line = 1, #text, 1
  local sub, byte, find = string.sub, string.byte, string.find
  local function skip()
    while i <= n do
      local c = sub(text, i, i)
      if c == "\n" then line = line + 1; i = i + 1
      elseif c == " " or c == "\t" or c == "\r" then i = i + 1
      elseif sub(text, i, i + 1) == "--" then
        local lvl = text:match("^%[(=*)%[", i + 2)
        if lvl then
          local close = "]" .. lvl .. "]"
          local e = find(text, close, i + 4 + #lvl, true)
          if not e then error(data_error(path, line, "unfinished long comment"), 0) end
          for _ in sub(text, i, e):gmatch("\n") do line = line + 1 end
          i = e + #close
        else
          local e = find(text, "\n", i, true)
          i = e or (n + 1)
        end
      else break end
    end
  end
  local value
  local function str()
    local q = sub(text, i, i)
    local out, j = {}, i + 1
    while j <= n do
      local c = sub(text, j, j)
      if c == q then i = j + 1; return table.concat(out) end
      if c == "\n" then error(data_error(path, line, "unfinished string"), 0) end
      if c == "\\" then
        local d = sub(text, j + 1, j + 1)
        local map = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }
        if map[d] then out[#out + 1] = map[d]; j = j + 2
        elseif d:match("%d") then
          local digits = text:match("^%d%d?%d?", j + 1)
          out[#out + 1] = string.char(tonumber(digits)); j = j + 1 + #digits
        else error(data_error(path, line, "bad escape \\" .. d), 0) end
      else out[#out + 1] = c; j = j + 1 end
    end
    error(data_error(path, line, "unfinished string"), 0)
  end
  local function longstr()
    local lvl = text:match("^%[(=*)%[", i)
    local close = "]" .. lvl .. "]"
    local s = i + 2 + #lvl
    if sub(text, s, s) == "\n" then s = s + 1; line = line + 1 end
    local e = find(text, close, s, true)
    if not e then error(data_error(path, line, "unfinished long string"), 0) end
    local v = sub(text, s, e - 1)
    for _ in v:gmatch("\n") do line = line + 1 end
    i = e + #close
    return v
  end
  local function num()
    local s = text:match("^0[xX]%x+", i) or text:match("^%d+%.?%d*[eE][%+%-]?%d+", i) or text:match("^%.%d+[eE][%+%-]?%d+", i)
      or text:match("^%d+%.?%d*", i) or text:match("^%.%d+", i)
    if not s then error(data_error(path, line, "a number expected"), 0) end
    i = i + #s
    return tonumber(s)
  end
  local function tbl()
    i = i + 1
    local t, k = {}, 1
    while true do
      skip()
      local c = sub(text, i, i)
      if c == "}" then i = i + 1; return t end
      if c == "" then error(data_error(path, line, "unfinished table (a } is missing)"), 0) end
      if c == "[" and not text:match("^%[=*%[", i) then
        i = i + 1; skip()
        local key = value()
        skip()
        if sub(text, i, i) ~= "]" then error(data_error(path, line, "] expected"), 0) end
        i = i + 1; skip()
        if sub(text, i, i) ~= "=" then error(data_error(path, line, "= expected after [key]"), 0) end
        i = i + 1; skip()
        t[key] = value()
      else
        local id = text:match("^[%a_][%w_]*", i)
        local after = id and text:match("^%s*=[^=]", i + #id)
        if id and after and id ~= "true" and id ~= "false" and id ~= "nil" then
          i = i + #id; skip(); i = i + 1; skip()
          t[id] = value()
        else
          t[k] = value(); k = k + 1
        end
      end
      skip()
      c = sub(text, i, i)
      if c == "," or c == ";" then i = i + 1
      elseif c == "" then error(data_error(path, line, "unfinished table (a } is missing)"), 0)
      elseif c ~= "}" then error(data_error(path, line, "',' or '}' expected, found '" .. c .. "'"), 0) end
    end
  end
  value = function()
    skip()
    local c = sub(text, i, i)
    if c == "{" then return tbl() end
    if c == '"' or c == "'" then return str() end
    if c == "[" and text:match("^%[=*%[", i) then return longstr() end
    if c == "-" then i = i + 1; skip(); return -num() end
    if c:match("[%d%.]") then return num() end
    local id = text:match("^[%a_][%w_%.]*", i)
    if id == "true" then i = i + 4; return true end
    if id == "false" then i = i + 5; return false end
    if id == "nil" then i = i + 3; return nil end
    error(data_error(path, line, "a value expected, found '" .. (id or c) .. "' (scenario files are data: no names, sums or functions)"), 0)
  end
  local ok, v = pcall(function()
    skip()
    if text:match("^return[^%w_]", i) then i = i + 6 end
    local r = value()
    skip()
    if i <= n then error(data_error(path, line, "unexpected text after the table"), 0) end
    return r
  end)
  if not ok then return nil, tostring(v) end
  return v
end

-- id → the scenario table | nil, why (the file and the line in the why).
-- Looked for, in order: scenarios/<id>.lua, scenarios/<id>/scenario.lua (the
-- game's), user://scenarios/<id>/scenario.lua, user://scenarios/<id>.lua (a
-- player's, a mod). sc._dir is the folder its file paths are relative to;
-- sc._file the file; sc._user a player's; sc._hooks its hooks table.
USER_DIR = "user://scenarios/"
local cache = {}
function load(id, fresh)
  if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil, "not a scenario id: " .. tostring(id) end
  if cache[id] and not fresh then return cache[id] end
  local cands = { { DIR .. "/" .. id .. ".lua", DIR .. "/" }, { DIR .. "/" .. id .. "/scenario.lua", DIR .. "/" },
                  { USER_DIR .. id .. "/scenario.lua", USER_DIR, true }, { USER_DIR .. id .. ".lua", USER_DIR, true } }
  local text, c
  for _, cc in ipairs(cands) do
    text = read_text(cc[1])
    if text then c = cc break end
  end
  if not text then return nil, "no file " .. DIR .. "/" .. id .. ".lua (or " .. USER_DIR .. id .. "/scenario.lua)" end
  local sc, err = parseData(text, c[1])
  if sc == nil then return nil, err end
  if type(sc) ~= "table" then return nil, c[1] .. " does not return a table" end
  sc.id = sc.id or id
  sc._dir, sc._file, sc._user = c[2], c[1], c[3] == true
  -- HOOKS (game scenarios only: a player's file is data and nothing else):
  -- `hooks = "<script kind>"`, a script in scripts/ whose globals are the
  -- hooks; scenario_run spawns its prefab (prefabs/<hooksPrefab or kind>)
  -- and reads it with findScript. Under luajit it is loaded from disk here.
  if sc.hooks ~= nil and sc._user then return nil, c[1] .. ": hooks: a player's scenario cannot carry code (data only)" end
  if type(sc.hooks) == "string" and loadfile and setfenv then
    local f = loadfile("solar/scripts/" .. sc.hooks .. ".lua") or loadfile("scripts/" .. sc.hooks .. ".lua")
    if not f then return nil, c[1] .. ": hooks: no script scripts/" .. sc.hooks .. ".lua" end
    local H = setmetatable({}, { __index = _G })
    setfenv(f, H)
    local okh, herr = pcall(f)
    if not okh then return nil, "scripts/" .. sc.hooks .. ".lua: " .. tostring(herr) end
    sc._hooks = H
  end
  cache[id] = sc
  return sc
end
function forget() cache = {} end

-- The ids in the game's folder and the player's (files starting with `_` are
-- templates, not listed). → { id … }, { [id] = true when a player's }
function ids()
  local out, seen, user = {}, {}, {}
  local function add(name, isUser)
    local id = name:match("^([%w_%-]+)%.lua$") or name:match("^([%w_%-]+)/scenario%.lua$")
    if id and not id:match("^_") and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
      if isUser then user[id] = true end
    end
  end
  local listed = false
  if assets and assets.getContents then
    for _, base in ipairs({ DIR .. "/", USER_DIR }) do
      local ok, list = pcall(assets.getContents, base:gsub("/$", ""))
      if ok and type(list) == "table" then
        if base == DIR .. "/" then listed = true end
        for _, p in ipairs(list) do
          local rest = tostring(p):gsub("^" .. base:gsub("%p", "%%%0"), "")
          add(rest, base == USER_DIR)
        end
      end
    end
  end
  if not listed and io and io.popen then
    for _, base in ipairs({ "solar/" .. DIR, DIR }) do
      local h = io.popen('ls "' .. base .. '" "' .. base .. '"/*/scenario.lua 2>/dev/null')
      local any = false
      if h then
        for line in h:lines() do
          any = true
          local rel = line:gsub("^" .. base:gsub("%p", "%%%0") .. "/", "")
          add(rel, false)
        end
        h:close()
      end
      if any then break end
    end
  end
  table.sort(out)
  return out, user
end

-- Every scenario, for the SCENARIOS panel: → { { id, title, blurb, teaches,
-- par, requires, steps, v, order, user, err } … }, by `order` then title. A
-- file that does not load is listed with `err` (the panel greys it; the
-- smoke fails it).
function listAll()
  local out = {}
  local list, user = ids()
  for _, id in ipairs(list) do
    local sc, err = load(id)
    if sc then
      out[#out + 1] = { id = id, title = sc.title or id, blurb = sc.blurb, teaches = sc.teaches or {},
                        par = sc.score and sc.score.par, requires = sc.requires, steps = #(sc.steps or {}),
                        v = sc.v or 1, order = sc.order or 100, minutes = sc.minutes, user = sc._user or user[id] or false }
    else
      out[#out + 1] = { id = id, title = id, err = err, order = 1000, user = user[id] or false }
    end
  end
  table.sort(out, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return tostring(a.title) < tostring(b.title)
  end)
  return out
end


-- ── refs ────────────────────────────────────────────────────────────────────
REF_KINDS = { crew = true, mark = true, struct = true, craft = true, body = true }
-- "crew:Okafor" → "crew", "Okafor"; "base" → "base", nil; a bare name → nil
function parseRef(r)
  if r == "base" then return "base", nil end
  if type(r) ~= "string" then return nil end
  local k, n = r:match("^(%a+):(.+)$")
  if k and REF_KINDS[k] then return k, n end
  return nil
end

-- ── geometry (body frame, pure) ─────────────────────────────────────────────
-- The ground frame at a direction from the body's centre: up (radial), front
-- (toward the body's north pole, +Y), right = up × front (structures.lua's
-- convention: +X right, +Y up, +Z front).
function groundFrame(ux, uy, uz)
  ux, uy, uz = norm(ux, uy, uz)
  local fx, fy, fz = -ux * uy, 1 - uy * uy, -uz * uy
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-6 then fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz end
  fx, fy, fz = norm(fx, fy, fz)
  local rx, ry, rz = cross(ux, uy, uz, fx, fy, fz)
  return { ux = ux, uy = uy, uz = uz, fx = fx, fy = fy, fz = fz, rx = rx, ry = ry, rz = rz }
end

-- d metres along the ground from direction u toward tangent t, on radius R
function dirAt(u, t, d, R)
  local a = d / R
  local x, y, z = norm(u.x * math.cos(a) + t.x * math.sin(a), u.y * math.cos(a) + t.y * math.sin(a), u.z * math.cos(a) + t.z * math.sin(a))
  return { x = x, y = y, z = z }
end

-- lat/lon (degrees) → a unit direction in the body frame (+Y the pole)
function latlonDir(lat, lon)
  local a, o = math.rad(lat), math.rad(lon)
  return { x = math.cos(a) * math.cos(o), y = math.sin(a), z = math.cos(a) * math.sin(o) }
end

-- A ground point `g` (body-relative { x,y,z } with its frame) moved by
-- offset { right, up, front } (metres in that frame). up == 0 sets it down on
-- the ground through `ground(dir) → r`. → { x,y,z, ux,uy,uz, fx,fy,fz }
function offsetPoint(g, off, ground, yawDeg)
  off = off or {}
  local F = groundFrame(g.x, g.y, g.z)
  local r_, u_, f_ = off[1] or off.right or 0, off[2] or off.up or 0, off[3] or off.front or 0
  local x = g.x + F.rx * r_ + F.fx * f_
  local y = g.y + F.ry * r_ + F.fy * f_
  local z = g.z + F.rz * r_ + F.fz * f_
  local dx, dy, dz, l = norm(x, y, z)
  if ground then
    local gr = ground({ x = dx, y = dy, z = dz })
    if gr then l = gr end
  end
  local F2 = groundFrame(dx, dy, dz)
  x, y, z = dx * (l + u_), dy * (l + u_), dz * (l + u_)
  local fx, fy, fz = F2.fx, F2.fy, F2.fz
  if yawDeg and yawDeg ~= 0 then
    local c, s = math.cos(math.rad(yawDeg)), math.sin(math.rad(yawDeg))
    fx, fy, fz = F2.fx * c + F2.rx * s, F2.fy * c + F2.ry * s, F2.fz * c + F2.rz * s
  end
  return { x = x, y = y, z = z, ux = F2.ux, uy = F2.uy, uz = F2.uz, fx = fx, fy = fy, fz = fz }
end

-- ── siting rules (pure over a ground query) ─────────────────────────────────
-- C = { R, u, t1, t2 (the base's up and two tangents, unit), ground(dir) →
-- radius | nil, wet(dir, r) → bool, sun = unit dir | nil }
-- rule: "base" | "near_base" | "far_flat_lit" | "far_flat" | "lat:<deg>,lon:<deg>"
-- → { dir, r, spread, lit } | nil, why
local function flatness(C, dir, r0, R)
  local F = groundFrame(dir.x, dir.y, dir.z)
  local lo, hi, n = r0, r0, 0
  for _, e in ipairs({ { 11, 0 }, { -11, 0 }, { 0, 11 }, { 0, -11 }, { 8, 8 }, { -8, -8 }, { 8, -8 }, { -8, 8 } }) do
    local x, y, z = norm(dir.x * R + F.rx * e[1] + F.fx * e[2], dir.y * R + F.ry * e[1] + F.fy * e[2], dir.z * R + F.rz * e[1] + F.fz * e[2])
    local g = C.ground({ x = x, y = y, z = z })
    if g then lo, hi, n = math.min(lo, g), math.max(hi, g), n + 1 end
  end
  return hi - lo, n
end
local function lit_of(C, dir) return C.sun and dot(dir.x, dir.y, dir.z, C.sun.x, C.sun.y, C.sun.z) or 0 end
local function best_of(C, cands, wantLit)
  local best
  for _, dir in ipairs(cands) do
    local g0 = C.ground(dir)
    if g0 then
      local spread, n = flatness(C, dir, g0, C.R)
      local wet = C.wet and C.wet(dir, g0)
      -- nothing built there (the spaceport's buildings, a structure): the scene half's ray
      local clear = not C.clear or C.clear(dir, g0)
      if n >= 7 and not wet and clear then
        local lit = lit_of(C, dir)
        local score = spread + ((wantLit == true and lit <= 0.25) and 2.0 or 0)
        if wantLit == "dark" then
          -- (flagship) a world's day is its year, and short (half an hour on
          -- small worlds): the longest night ahead is at sunset (the sun on
          -- the horizon, the spot turning away from it along the world's motion)
          local turning = C.vel and (dir.x * C.vel.x + dir.y * C.vel.y + dir.z * C.vel.z) or 0
          score = score + ((lit >= 0.15) and 4.0 or 0) + math.abs(lit - 0.04) * 3 + ((C.vel and turning <= 0.1) and 3.0 or 0)
        end
        if not best or score < best.score then best = { dir = dir, r = g0, spread = spread, lit = lit, score = score } end
      end
    end
  end
  return best
end
function findSpot(rule, C, dist)
  if type(rule) ~= "string" then return nil, "no siting rule" end
  local u, t1, t2, R = C.u, C.t1, C.t2, C.R
  if rule == "base" or rule == "near_base" then
    local d = dist or (rule == "base" and 0 or 60)
    local cands = {}
    if d <= 0 then cands[1] = u
    else
      for k = 0, 11 do
        local a = k * math.pi / 6
        local t = { x = t1.x * math.cos(a) + t2.x * math.sin(a), y = t1.y * math.cos(a) + t2.y * math.sin(a), z = t1.z * math.cos(a) + t2.z * math.sin(a) }
        cands[#cands + 1] = dirAt(u, t, d, R)
      end
    end
    local b = best_of(C, cands, false)
    if not b and d <= 0 then local g = C.ground(u); if g then b = { dir = u, r = g, spread = 0, lit = lit_of(C, u) } end end
    if not b then return nil, "no dry ground near the base" end
    return b
  end
  if rule == "far_flat_lit" or rule == "far_flat" or rule == "far_flat_dark" then
    local cands = {}
    -- (flagship) the dark side may be the spaceport's own: the dark rule looks nearer too
    for _, frac in ipairs(rule == "far_flat_dark" and { 0.9, 0.8, 0.7, 0.55, 0.4, 0.25, 0.12 } or { 0.9, 0.8, 0.7 }) do
      for k = 0, 23 do
        local a = k * math.pi / 12
        local t = { x = t1.x * math.cos(a) + t2.x * math.sin(a), y = t1.y * math.cos(a) + t2.y * math.sin(a), z = t1.z * math.cos(a) + t2.z * math.sin(a) }
        cands[#cands + 1] = dirAt(u, t, math.pi * R * frac, R)
      end
    end
    local b = best_of(C, cands, (rule == "far_flat_lit") or (rule == "far_flat_dark" and "dark"))
    if not b then return nil, "no flat dry ground on the far side" end
    return b
  end
  local la, lo = rule:match("^lat:%s*(%-?[%d%.]+)%s*,%s*lon:%s*(%-?[%d%.]+)$")
  if la then
    local c = latlonDir(tonumber(la), tonumber(lo))
    local F = groundFrame(c.x, c.y, c.z)
    local cands = { c }
    for k = 0, 7 do
      local a = k * math.pi / 4
      local t = { x = F.rx * math.cos(a) + F.fx * math.sin(a), y = F.ry * math.cos(a) + F.fy * math.sin(a), z = F.rz * math.cos(a) + F.fz * math.sin(a) }
      cands[#cands + 1] = dirAt(c, t, 60, R)
      cands[#cands + 1] = dirAt(c, t, 140, R)
    end
    local b = best_of(C, cands, false)
    if not b then return nil, "no dry flat ground near " .. rule end
    return b
  end
  return nil, "unknown siting rule '" .. rule .. "'"
end

-- ── two-body (pure): an orbit's state from elements ─────────────────────────
-- mu, and { alt (periapsis altitude), R, e = 0, inc = 0 (deg), lan = 0, argp = 0,
-- nu = 0 (true anomaly, deg) } → r {x,y,z}, v {x,y,z} body-relative, with the
-- body's +Y the pole (inc = 0: an equatorial orbit, prograde about +Y).
function orbitState(mu, o)
  local e = o.e or 0
  local rp = (o.R or 0) + (o.alt or 0)
  local a = rp / (1 - e)
  local p = a * (1 - e * e)
  local nu = math.rad(o.nu or 0)
  local r = p / (1 + e * math.cos(nu))
  -- perifocal (P toward periapsis, Q 90° ahead), orbit normal +W
  local px, qx = r * math.cos(nu), r * math.sin(nu)
  local k = math.sqrt(mu / p)
  local vp, vq = -k * math.sin(nu), k * (e + math.cos(nu))
  local i, W, w = math.rad(o.inc or 0), math.rad(o.lan or 0), math.rad(o.argp or 0)
  -- the equatorial plane is X–Z with +Y the pole: build P, Q in a Z-up frame,
  -- then map (x, y, z_up) → (x, z_up, -y) so a prograde orbit turns about +Y
  local cW, sW, ci, si, cw, sw = math.cos(W), math.sin(W), math.cos(i), math.sin(i), math.cos(w), math.sin(w)
  local P = { cW * cw - sW * sw * ci, sW * cw + cW * sw * ci, sw * si }
  local Q = { -cW * sw - sW * cw * ci, -sW * sw + cW * cw * ci, cw * si }
  local function map(v) return { x = v[1], y = v[3], z = -v[2] } end
  local rr = map({ P[1] * px + Q[1] * qx, P[2] * px + Q[2] * qx, P[3] * px + Q[3] * qx })
  local vv = map({ P[1] * vp + Q[1] * vq, P[2] * vp + Q[2] * vq, P[3] * vp + Q[3] * vq })
  return rr, vv
end

-- ── the step machine ────────────────────────────────────────────────────────
-- done = { [stepId] = t }. → the open step indices (the current one, its
-- parallel group, and every optional step reached), the current index (nil:
-- every required step is done).
function openSteps(sc, done)
  done = done or {}
  local open, cur = {}, nil
  local steps = sc.steps or {}
  local i = 1
  while i <= #steps do
    local s = steps[i]
    if not done[s.id] then
      if s.optional then
        open[#open + 1] = i
      else
        cur = i
        open[#open + 1] = i
        if s.parallel then
          local j = i + 1
          while j <= #steps and steps[j].parallel == s.parallel do
            if not done[steps[j].id] then open[#open + 1] = j end
            j = j + 1
          end
        end
        break
      end
    end
    i = i + 1
  end
  return open, cur
end
function finished(sc, done)
  local _, cur = openSteps(sc, done)
  return cur == nil
end
-- index of the step with id
function stepIndex(sc, id)
  for i, s in ipairs(sc.steps or {}) do if s.id == id then return i end end
  return nil
end
-- How many required steps are done, of how many
function progress(sc, done)
  local n, d = 0, 0
  for _, s in ipairs(sc.steps or {}) do
    if not s.optional then n = n + 1; if done and done[s.id] then d = d + 1 end end
  end
  return d, n
end
-- The steps a checkpoint pre-latches: every step before the last checkpoint
-- reached (index cp). → { stepId … }
function beforeCheckpoint(sc, cpId)
  local out = {}
  for _, s in ipairs(sc.steps or {}) do
    if s.id == cpId then break end
    out[#out + 1] = s.id
  end
  return out
end

-- ── goals ───────────────────────────────────────────────────────────────────
-- Every kind: req (fields that must be there), eval(g, W, mem, ctx) → met,
-- reading. W is the world adapter (docs/scenarios.md "W"); mem is this goal's
-- own memory (for events); ctx = { done, stepT0, t0, now }. A kind with
-- `fail = true` belongs in the fail list (it reads true when the run is lost).
local function fmt_m(d)
  if not d then return "?" end
  if d >= 1000 then return string.format("%.1f km", d / 1000) end
  return string.format("%.0f m", d)
end
local function sid_of(W, g)
  local name = g.struct
  if type(name) == "string" then name = name:gsub("^struct:", "") end
  local sid = W.structId and W.structId(name)
  return sid, name
end
local function who_of(g) return type(g.who) == "string" and g.who:gsub("^crew:", "") or g.who end
local function pick_room(rooms, want)
  if not rooms or #rooms == 0 then return nil end
  if want == nil or want == "any" then return nil end
  if want == "largest" then
    local best
    for _, r in ipairs(rooms) do if r.sealed and not r.airlock and (not best or r.m3 > best.m3) then best = r end end
    return best
  end
  if want == "airlock" then for _, r in ipairs(rooms) do if r.airlock then return r end end return nil end
  if type(want) == "number" then return rooms[want] end
  return nil
end

pickRoom = pick_room
KINDS = {}
local function kind(name, def) KINDS[name] = def end

kind("at", { req = { "who", "at" }, eval = function(g, W)
  local a, b = W.pos(g.who), W.pos(g.at)
  if not a then return false, "no " .. tostring(g.who) end
  if not b then return false, "no " .. tostring(g.at) end
  if a.body ~= b.body then return false, string.format("on %s, not %s", tostring(a.body), tostring(b.body)) end
  local d = len(a.x - b.x, a.y - b.y, a.z - b.z)
  local r = g.r or 20
  return d <= r, d <= r and string.format("there (%s)", fmt_m(d)) or string.format("%s to go", fmt_m(d - r))
end })
kind("in_room", { req = { "who", "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local s, rid = W.roomOf(who_of(g))
  if s ~= sid or not rid then return false, "outside" end
  if g.room == nil or g.room == "any" then return true, "inside" end
  local r = pick_room(W.rooms(sid), g.room)
  if not r then return false, "no such room yet" end
  return r.id == rid, r.id == rid and "inside" or "in another room"
end })
kind("helmet", { req = { "who" }, eval = function(g, W)
  local off = W.helmetOff(who_of(g))
  local want = g.off ~= false
  if off == nil then return false, "not on foot" end
  return off == want, off and "helmet off" or "helmet on"
end })
kind("rooms", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local n = 0
  for _, r in ipairs(W.rooms(sid) or {}) do if r.sealed then n = n + 1 end end
  local want = g.sealed or 1
  return n >= want, string.format("%d of %d sealed", n, want)
end })
kind("airlock", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local n = 0
  for _, r in ipairs(W.rooms(sid) or {}) do if r.airlock then n = n + 1 end end
  local want = g.count or 1
  return n >= want, string.format("%d of %d airlocks", n, want)
end })
kind("airlock_cycled", { req = { "struct" }, eval = function(g, W, mem)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local want = g.n or 1
  local c = W.airlockCycles and W.airlockCycles(sid)
  if c then return c >= want, string.format("%d of %d cycles", c, want) end
  -- no counter: the crew seen inside a chamber, then out of it into a room
  -- of the same structure (an event, kept in mem)
  local s, rid = W.roomOf(g.who and who_of(g) or nil)
  local inLock = false
  if s == sid and rid then
    for _, r in ipairs(W.rooms(sid) or {}) do if r.id == rid and r.airlock then inLock = true end end
  end
  if inLock then mem.inLock = true
  elseif mem.inLock and s == sid and rid then mem.n = (mem.n or 0) + 1; mem.inLock = false end
  local n = mem.n or 0
  return n >= want, string.format("%d of %d cycles", n, want)
end })
kind("room_air", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local rooms = W.rooms(sid) or {}
  local r = pick_room(rooms, g.room or "largest")
  if not r then return false, "no sealed room" end
  local a = W.roomAir(sid, r.id)
  if not a then return false, "no air yet" end
  local ok = true
  local parts = {}
  if g.p then ok = ok and a.p >= g.p; parts[#parts + 1] = string.format("p %.2f of %.2f", a.p, g.p) end
  if g.o2 then ok = ok and a.o2 >= g.o2; parts[#parts + 1] = string.format("O2 %.2f of %.2f", a.o2, g.o2) end
  if g.co2 then ok = ok and a.co2 <= g.co2; parts[#parts + 1] = string.format("CO2 %.3f (max %.3f)", a.co2, g.co2) end
  if g.breathable then ok = ok and a.breathable == true; parts[#parts + 1] = a.breathable and "breathable" or tostring(a.why or "not breathable") end
  return ok, table.concat(parts, " · ")
end })
kind("grid", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local s = W.grid(sid)
  if not s then return false, "not on a grid" end
  local ok = (s.supply or 0) > 0 and s.powered == true
  if ok then return true, string.format("%.1f kW of %.1f", s.need or 0, s.supply or 0) end
  if (s.supply or 0) <= 0 then return false, "no power source" end
  return false, string.format("%.1f kW short", math.max(0, (s.need or 0) - (s.supply or 0)))
end })
kind("struct_has", { req = { "part" }, eval = function(g, W)
  local want = g.count or 1
  local n = 0
  local list
  if g.struct then
    local sid = sid_of(W, g)
    if not sid then return false, "no " .. tostring(g.struct) end
    list = W.parts(sid)
  else
    list = W.partsNear and W.partsNear(g.at, g.r or 30)
  end
  for _, p in ipairs(list or {}) do
    if p.id == g.part or (type(p.id) == "string" and p.id:sub(1, #g.part + 1) == g.part .. ".") then n = n + 1 end
  end
  return n >= want, string.format("%d of %d %s", n, want, g.part)
end })
kind("flag_on", { req = { "body" }, eval = function(g, W)
  local ok = W.flagOn(g.body) == true
  return ok, ok and "planted" or "no flag"
end })
kind("step_done", { req = { "step" }, eval = function(g, W, mem, ctx)
  local ok = ctx and ctx.done and ctx.done[g.step] ~= nil
  return ok, ok and "done" or ("after " .. tostring(g.step))
end })
-- fail conditions (they read TRUE when the run is lost)
kind("crew_dead", { fail = true, eval = function(g, W)
  if g.who then
    local d = W.crewDead(who_of(g))
    return d == true, d and (tostring(who_of(g)) .. " is dead") or "alive"
  end
  local d = W.crewDead(nil)
  return d == true, d and "a crew member died" or "all alive"
end })
kind("suit_air", { fail = true, req = { "who" }, eval = function(g, W)
  local o2 = W.suitO2(who_of(g))
  if not o2 then return false, "no suit reading" end
  return o2 <= (g.below or 0), string.format("suit air %d%%", math.floor(o2 * 100 + 0.5))
end })
kind("craft_lost", { fail = true, req = { "craft" }, eval = function(g, W, mem)
  local alive = W.craftAlive(type(g.craft) == "string" and g.craft:gsub("^craft:", "") or g.craft)
  if alive then mem.seen = true end
  local lost = mem.seen == true and alive == false
  return lost, lost and "lost" or (alive and "flying" or "not out yet")
end })
kind("timer", { fail = true, req = { "secs" }, eval = function(g, W, mem, ctx)
  local from = (g.from == "step" and ctx and ctx.stepT0) or (ctx and ctx.t0) or 0
  if type(g.from) == "string" and g.from:sub(1, 5) == "step:" then
    from = ctx and ctx.stepAt and ctx.stepAt(g.from:sub(6))
    if not from then return false, "waiting for " .. g.from:sub(6) end
  end
  local t = (ctx and ctx.now or 0) - from
  return t >= g.secs, string.format("%d s of %d", math.floor(t), math.floor(g.secs))
end })

-- v2: variables, pieces, the reactor, a hook
local function vtest(v, t)
  if t.is ~= nil then return (v == true) == (t.is == true) end
  if t.eq ~= nil and v ~= t.eq then return false end
  if t.ne ~= nil and v == t.ne then return false end
  local n = type(v) == "number"
  if t.lt ~= nil and not (n and v < t.lt) then return false end
  if t.gt ~= nil and not (n and v > t.gt) then return false end
  if t.lte ~= nil and not (n and v <= t.lte) then return false end
  if t.gte ~= nil and not (n and v >= t.gte) then return false end
  return true
end
varTest = vtest
kind("var", { req = { "name" }, eval = function(g, W)
  local v = W.var and W.var(g.name)
  return vtest(v, g), string.format("%s = %s", g.name, tostring(v))
end })
kind("choice_made", { req = { "name" }, eval = function(g, W)
  local v = W.var and W.var(g.name)
  return v ~= nil, v ~= nil and "chosen" or "not yet"
end })
kind("piece_ok", { req = { "struct" }, eval = function(g, W)
  local ok = W.pieceOk and W.pieceOk({ struct = g.struct, part = g.part, uid = g.uid })
  if ok == nil then return false, "no such piece" end
  return ok, ok and "working" or "knocked"
end })
kind("reactor", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  local r = sid and W.reactor and W.reactor(sid)
  if not r then return false, "no reactor" end
  local ok, parts = true, { string.format("power %d%%", math.floor((r.power or 0) * 100 + 0.5)) }
  if g.power_above and not ((r.power or 0) >= g.power_above) then ok = false end
  if g.power_below and not ((r.power or 0) <= g.power_below) then ok = false end
  if g.temp_below then ok = ok and (r.primaryK or 0) <= g.temp_below; parts[#parts + 1] = string.format("%.0f K", r.primaryK or 0) end
  if g.temp_above then ok = ok and (r.primaryK or 0) >= g.temp_above; parts[#parts + 1] = string.format("%.0f K", r.primaryK or 0) end
  if g.flow_above then ok = ok and (r.flow or 0) >= g.flow_above; parts[#parts + 1] = string.format("%.1f kg/s", r.flow or 0) end
  if g.scrammed ~= nil then ok = ok and (r.scrammed == true) == g.scrammed; parts[#parts + 1] = r.scrammed and "tripped" or "running" end
  if g.melted ~= nil then ok = ok and (r.melted == true) == g.melted end
  if g.net_above then ok = ok and (r.netKW or 0) >= g.net_above; parts[#parts + 1] = string.format("%.1f kW net", r.netKW or 0) end
  return ok, table.concat(parts, " · ")
end })
-- (flagship) a fail condition: the core of struct's plant has melted
kind("core_melted", { fail = true, req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  local r = sid and W.reactor and W.reactor(sid)
  if not r then return false, "no reactor" end
  return r.melted == true, r.melted and "MELTED" or string.format("fuel %.0f K", r.fuelK or 0)
end })
kind("hook", { req = { "fn" }, eval = function(g, W)
  if not W.hookGoal then return false, "no hooks" end
  return W.hookGoal(g.fn, g)
end })

-- ── FW-C: reads a mod can write without hooks (PLAN §2 F6, F7) ──────────────
-- A threshold table on a number: above / below (>= / <=). → ok, "a of b" bits
local function bounds(v, g, lo, hi)
  if type(v) ~= "number" then return false end
  if g[lo] ~= nil and not (v >= g[lo]) then return false end
  if g[hi] ~= nil and not (v <= g[hi]) then return false end
  return true
end
-- power_read: a structure's grid and its breakers (base_grid, base_power).
-- { struct, battery_above | battery_below (share of the store), need_above |
-- need_below (kW drawn), supply_above | supply_below (kW made), powered =
-- bool, breaker = part | uid, state = "closed" | "open" | "tripped" }
kind("power_read", { req = { "struct" }, eval = function(g, W)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local s = W.grid(sid)
  local parts, ok = {}, true
  if g.battery_above or g.battery_below or g.need_above or g.need_below or g.supply_above or g.supply_below or g.powered ~= nil then
    if not s then return false, "not on a grid" end
    local frac = (s.cap or 0) > 0 and (s.stored or 0) / s.cap or 0
    if g.battery_above or g.battery_below then
      ok = ok and bounds(frac, g, "battery_above", "battery_below")
      parts[#parts + 1] = string.format("battery %d%%", math.floor(frac * 100 + 0.5))
    end
    if g.need_above or g.need_below then
      ok = ok and bounds(s.need or 0, g, "need_above", "need_below")
      parts[#parts + 1] = string.format("%.1f kW drawn", s.need or 0)
    end
    if g.supply_above or g.supply_below then
      ok = ok and bounds(s.supply or 0, g, "supply_above", "supply_below")
      parts[#parts + 1] = string.format("%.1f kW made", s.supply or 0)
    end
    if g.powered ~= nil then
      ok = ok and ((s.powered == true) == (g.powered == true))
      parts[#parts + 1] = s.powered and "every load served" or "shedding"
    end
  end
  if g.breaker ~= nil then
    local st = W.breaker and W.breaker({ struct = g.struct, part = type(g.breaker) == "string" and g.breaker or nil,
                                          uid = type(g.breaker) == "number" and g.breaker or nil })
    if not st then return false, "no breaker " .. tostring(g.breaker) end
    ok = ok and (g.state == nil or st == g.state)
    parts[#parts + 1] = "breaker " .. st
  end
  return ok, table.concat(parts, " · ")
end })
-- part_hp: a craft part's health (vessel_controller.partHp, 1 whole … 0
-- broken). { craft, part (id prefix) | uid, above | below }
kind("part_hp", { req = { "craft" }, eval = function(g, W, mem)
  local hp = W.partHp and W.partHp(g, mem)
  if hp == nil then return false, "no such part aboard " .. tostring(g.craft) end
  local ok = bounds(hp, g, "above", "below")
  return ok, string.format("hp %.2f", hp)
end })
-- piece_state: a structure piece's live state: { struct, part | uid, on =
-- bool (a pump or machine running), knocked = bool, field = "<st key>" with
-- eq | ne | lt | gt | lte | gte | is }
kind("piece_state", { req = { "struct" }, eval = function(g, W)
  local p = W.piece and W.piece(g)
  if not p then return false, "no such piece" end
  local ok, parts = true, {}
  if g.on ~= nil then
    local on = p.pumpOn
    if on == nil then on = not p.off end
    ok = ok and (on == (g.on == true)); parts[#parts + 1] = on and "running" or "off"
  end
  if g.knocked ~= nil then ok = ok and ((p.knocked == true) == (g.knocked == true)); parts[#parts + 1] = p.knocked and "knocked" or "whole" end
  if g.field then
    local v = p[g.field]
    ok = ok and varTest(v, g); parts[#parts + 1] = string.format("%s = %s", g.field, tostring(v))
  end
  return ok, table.concat(parts, " · ")
end })
-- (a fail) a room has been unbreathable for `secs`: { struct, room =
-- largest | airlock | n, secs = 60 }
kind("room_unbreathable", { fail = true, req = { "struct" }, eval = function(g, W, mem, ctx)
  local sid = sid_of(W, g)
  if not sid then return false, "no " .. tostring(g.struct) end
  local r = pick_room(W.rooms(sid) or {}, g.room or "largest")
  if not r then mem.since = nil; return false, "no sealed room" end
  local a = W.roomAir(sid, r.id)
  local now = ctx and ctx.now or 0
  if not a or a.breathable then mem.since = nil; return false, "breathable" end
  mem.since = mem.since or now
  local held, secs = now - mem.since, g.secs or 60
  return held >= secs, string.format("unbreathable %d s of %d (%s)", math.floor(held), math.floor(secs), tostring(a.why or "air"))
end })

-- ── FW-C: meters and models (PLAN §2 F6: what Graveyard's hooks did, as data)
-- A METER is a variable that follows a published reading, sampled with the
-- goals (EVAL_HZ, the agency clock):
--   { var, read = "reactor.genKW" | "grid.battery" | "dose.msv" | …, struct,
--     who, craft, part, uid, room, scale = 1, mode = "sample" | "integrate" |
--     "peak" | "min", delta = true (count from the first reading), when =
--     goal (only while it reads true), round = 0.1 }
-- A MODEL is a number with its own law, for what the systems do not simulate
-- (Graveyard's bearing): it runs while `active` reads true (always without
-- it), climbs while `when` reads true by rate · (1 + accel · (v − base)) a
-- second, and otherwise settles toward `rest` with time constant `tau` (or
-- stays, without them); `at` fires beats once as it crosses a value.
--   { var, start, active = goal, when = goal, rate, accel = 0, base = 0,
--     rest, tau, min, max, round = 0.1, at = { { value, beats = {…} | run =
--     "seq", down = true (crossing downward) } } }
METER_READS = { reactor = true, grid = true, dose = true, suit = true, room = true, part = true, var = true, piece = true }
METER_MODES = { sample = true, integrate = true, peak = true, min = true }
local function round_to(v, q) if not q or q <= 0 then return v end return math.floor(v / q + 0.5) * q end
-- → the meter's new value (cur: its value now; r: the reading; first: the
-- first reading seen, for delta)
function stepMeter(m, cur, r, dt, first)
  if type(r) ~= "number" then return cur end
  local v = r
  if m.delta and type(first) == "number" then v = r - first end
  v = v * (m.scale or 1)
  local mode = m.mode or "sample"
  local out
  if mode == "integrate" then out = (tonumber(cur) or 0) + v * (dt or 0)
  elseif mode == "peak" then out = (type(cur) == "number" and cur > v) and cur or v
  elseif mode == "min" then out = (type(cur) == "number" and cur < v) and cur or v
  else out = v end
  return round_to(out, m.round)
end
-- → the model's new value, and the `at` entries crossed this step
function stepModel(md, cur, rising, dt)
  local v = tonumber(cur) or md.start or 0
  local v0 = v
  if rising then
    v = v + (md.rate or 0) * dt * (1 + (md.accel or 0) * (v - (md.base or 0)))
  elseif md.rest ~= nil and md.tau and md.tau > 0 then
    v = md.rest + (v - md.rest) * math.exp(-dt / md.tau)
  elseif md.fall then
    v = v - md.fall * dt
  end
  if md.min and v < md.min then v = md.min end
  if md.max and v > md.max then v = md.max end
  local crossed = {}
  for i, a in ipairs(md.at or {}) do
    if type(a.value) == "number" then
      if a.down then if v0 > a.value and v <= a.value then crossed[#crossed + 1] = i end
      elseif v0 < a.value and v >= a.value then crossed[#crossed + 1] = i end
    end
  end
  return round_to(v, md.round), crossed
end

-- ── FW-C: radio (PLAN §2 F3) ───────────────────────────────────────────────
-- A line over a link with no path: every third word lost, deterministic.
function garble(text, seed)
  local out, i = {}, 0
  local s = math.floor(tonumber(seed) or 0) % 3
  for w in tostring(text):gmatch("%S+") do
    i = i + 1
    out[#out + 1] = ((i + s) % 3 == 0) and "—" or w
  end
  return table.concat(out, " ")
end

-- ── FW-C: time of day (PLAN §2 F4) ─────────────────────────────────────────
-- world.time.at → the key light's elevation over the site's horizon, degrees
TIMES = { night = -25, dusk = -3, dawn = 4, morning = 18, noon = 62, afternoon = 30, evening = 8 }
function elevationOf(at)
  if type(at) == "number" then return math.max(-90, math.min(90, at)) end
  return TIMES[at]
end
-- The direction toward the key light held at elevation `el` (deg) over a
-- site whose up is u, turned toward the real star's azimuth (sun, a unit
-- direction, or nil: the site's north). → x, y, z (unit)
function heldSun(u, el, sun)
  local F = groundFrame(u.x, u.y, u.z)
  local hx, hy, hz = F.fx, F.fy, F.fz
  if sun then
    local d = dot(sun.x, sun.y, sun.z, F.ux, F.uy, F.uz)
    local tx, ty, tz = sun.x - F.ux * d, sun.y - F.uy * d, sun.z - F.uz * d
    local l = len(tx, ty, tz)
    if l > 1e-6 then hx, hy, hz = tx / l, ty / l, tz / l end
  end
  local a = math.rad(el)
  return norm(hx * math.cos(a) + F.ux * math.sin(a), hy * math.cos(a) + F.uy * math.sin(a), hz * math.cos(a) + F.uz * math.sin(a))
end

-- ── FW-C: faces (crew_faces.EXPR, and two kinder names) ─────────────────────
FACES = { neutral = true, focus = true, happy = true, excited = true, relief = true, delight = true, worried = true,
          scared = true, panic = true, pain = true, strain = true, tired = true, bored = true, out = true, dead = true }
FACE_ALIAS = { alarmed = "scared", smile = "happy", calm = "neutral", afraid = "scared", grim = "focus" }
function faceName(n) return FACE_ALIAS[n] or n end

-- ── FW-C: portraits (PLAN §2 F1): "auto" is the booth's picture ─────────────
-- → the portrait's path relative to the scenarios folder, or nil
function portraitOf(sc, key, c)
  if type(c) ~= "table" or type(c.portrait) ~= "string" then return nil end
  if c.portrait == "auto" then return (sc and sc.id or "?") .. "/" .. tostring(key) .. ".png" end
  return c.portrait
end

-- ── FW-C: the checkpoint snapshot (PLAN §2 F5) ──────────────────────────────
-- What a RETRY from a checkpoint keeps of the story: the variables, the
-- events already fired, the objective texts, the clock so far.
function checkpointSnap(id, vars, fired, obj, elapsed)
  return { id = id, vars = copy(vars or {}), ev = copy(fired or {}), obj = copy(obj or {}), t = elapsed or 0 }
end

-- The missions kinds (missions.goalNow), passed through W.mission
MISSION_KINDS = { altitude = true, speed = true, orbit = true, cargo = true, soi = true, land = true, flag = true,
                  dock = true, drive = true, home = true, recover = true, deliver = true, establish = true,
                  layer = true, supply = true, pipeline = true, sample = true }
for k in pairs(MISSION_KINDS) do
  kind(k, { mission = true, eval = function(g, W)
    local ok = W.mission and W.mission(g) == true
    return ok, ok and "done" or "not yet"
  end })
end

-- A default card line for a goal (an author's `label` wins).
function goalLabel(g)
  if g.label then return g.label end
  local k = g.kind
  if k == "at" then return string.format("Reach %s", tostring(g.at):gsub("^%a+:", "")) end
  if k == "in_room" then return "Go inside" end
  if k == "helmet" then return g.off == false and "Helmet on" or "Helmet off" end
  if k == "rooms" then return string.format("%d sealed room%s", g.sealed or 1, (g.sealed or 1) > 1 and "s" or "") end
  if k == "airlock" then return "An airlock" end
  if k == "airlock_cycled" then return "Cycle the airlock" end
  if k == "room_air" then return "Air in the room" end
  if k == "grid" then return "Power it" end
  if k == "struct_has" then return string.format("%d × %s", g.count or 1, tostring(g.part)) end
  if k == "flag_on" then return "Plant the flag" end
  if k == "orbit" then return "Reach orbit" end
  if k == "land" then return "Land" end
  if k == "recover" then return "Recover the craft" end
  if k == "power_read" then return g.breaker and "The breaker" or "The power" end
  if k == "part_hp" then return string.format("%s on %s", tostring(g.part or g.uid or "part"), tostring(g.craft):gsub("^craft:", "")) end
  if k == "piece_state" then return tostring(g.part or g.uid or "the piece") end
  return k
end

-- Evaluate goal g now: → met (with hold applied), reading. mem keeps since/latch.
function evalGoal(g, W, mem, ctx)
  local K = KINDS[g.kind]
  if not K then return false, "unknown kind " .. tostring(g.kind) end
  local ok, met, reading = pcall(K.eval, g, W, mem, ctx)
  if not ok then return false, "error: " .. tostring(met) end
  if g.hold and g.hold > 0 then
    local now = ctx and ctx.now or 0
    if met then
      mem.since = mem.since or now
      local held = now - mem.since
      if held < g.hold then
        return false, string.format("%s · held %d of %d s", tostring(reading or ""), math.floor(held), math.floor(g.hold))
      end
    else
      mem.since = nil
    end
  end
  return met == true, reading
end

-- ── score and medals ────────────────────────────────────────────────────────
-- stats = { secs, spent (funds), hints, pieces, damage, crewSafe }
-- score.medals = { gold = { time = 1.0, funds = 0.8, hints = 0 }, silver = { time = 1.5 }, bronze = "done" }
local function meets(sc, crit, stats)
  if crit == "done" or crit == true then return true end
  if type(crit) ~= "table" then return false end
  local S = sc.score or {}
  if crit.time and S.par and (stats.secs or 0) > S.par * crit.time then return false end
  if crit.funds and S.budget and S.budget.funds and (stats.spent or 0) > S.budget.funds * crit.funds then return false end
  if crit.hints and (stats.hints or 0) > crit.hints then return false end
  if crit.pieces and S.budget and S.budget.pieces and (stats.pieces or 0) > S.budget.pieces * crit.pieces then return false end
  if crit.crewSafe and stats.crewSafe == false then return false end
  -- (flagship) vars = { name = { lte = n, … } }: the run's variables (varTest)
  if type(crit.vars) == "table" then
    for k, t in pairs(crit.vars) do
      if not varTest((stats.vars or {})[k], t) then return false end
    end
  end
  return true
end
function medal(sc, stats)
  local M = (sc.score and sc.score.medals) or { bronze = "done" }
  for _, m in ipairs(MEDALS) do
    if M[m] ~= nil and meets(sc, M[m], stats) then return m end
  end
  return "bronze"
end
local function mmss(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
mmss_ = mmss
-- The debrief's rows: → { { label, value, par, ok } … }
function score(sc, stats)
  local S = sc.score or {}
  local rows = {}
  rows[#rows + 1] = { label = "Time", value = mmss(stats.secs), par = S.par and mmss(S.par) or nil,
                      ok = not S.par or (stats.secs or 0) <= S.par }
  if S.budget and S.budget.funds then
    rows[#rows + 1] = { label = "Spent", value = string.format("$%d", math.floor(stats.spent or 0)),
                        par = string.format("$%d", S.budget.funds), ok = (stats.spent or 0) <= S.budget.funds }
  end
  if S.budget and S.budget.pieces then
    rows[#rows + 1] = { label = "Pieces", value = tostring(stats.pieces or 0), par = tostring(S.budget.pieces),
                        ok = (stats.pieces or 0) <= S.budget.pieces }
  end
  rows[#rows + 1] = { label = "Hints", value = tostring(stats.hints or 0), ok = (stats.hints or 0) == 0 }
  if stats.crewSafe ~= nil then rows[#rows + 1] = { label = "Crew", value = stats.crewSafe and "all safe" or "lost", ok = stats.crewSafe } end
  -- FW-C: the times the run went back to a checkpoint (PLAN §2 F5)
  if (stats.setbacks or 0) > 0 then rows[#rows + 1] = { label = "Setbacks", value = tostring(stats.setbacks), ok = false } end
  -- (flagship) score.rows = { { label, var, fmt, par, lte | gte } }: rows read off the run's variables
  for _, r in ipairs(S.rows or {}) do
    local v = (stats.vars or {})[r.var]
    local ok = true
    if r.lte ~= nil then ok = type(v) == "number" and v <= r.lte end
    if r.gte ~= nil then ok = type(v) == "number" and v >= r.gte end
    rows[#rows + 1] = { label = r.label or r.var, value = (type(v) == "number" and r.fmt) and string.format(r.fmt, v) or tostring(v == nil and "—" or v),
                        par = r.par, ok = ok }
  end
  return rows
end

-- ── the profile (user://scenarios/profile.json) ─────────────────────────────
-- { v = 1, s = { [id] = { best, bestTime, plays, lastOutcome, t } } }
local RANK = { gold = 3, silver = 2, bronze = 1 }
function profileRecord(p, id, outcome, med, secs)
  p = type(p) == "table" and p or {}
  p.v = 1
  p.s = type(p.s) == "table" and p.s or {}
  local e = p.s[id] or {}
  e.plays = (e.plays or 0) + 1
  e.lastOutcome = outcome
  if outcome == "done" then
    if med and (RANK[med] or 0) > (RANK[e.best] or 0) then e.best = med end
    if secs and (not e.bestTime or secs < e.bestTime) then e.bestTime = secs end
  end
  p.s[id] = e
  return p
end
function profileLoad()
  if assets and assets.readJson then
    local ok, v = pcall(assets.readJson, PROFILE)
    if ok and type(v) == "table" then return v end
  end
  return { v = 1, s = {} }
end
function profileSave(p)
  if assets and assets.writeJson then return pcall(assets.writeJson, PROFILE, p, { pretty = true }) end
  return false
end
function profileEntry(p, id) return (type(p) == "table" and type(p.s) == "table" and p.s[id]) or nil end
-- Is a scenario's `requires` (another's medal) met? requires = { id, medal = "bronze" } | "id"
function unlocked(p, sc)
  local r = sc and sc.requires
  if not r then return true end
  local id, want = r, "bronze"
  if type(r) == "table" then id, want = r[1] or r.id, r.medal or "bronze" end
  local e = profileEntry(p, id)
  return e ~= nil and (RANK[e.best] or 0) >= (RANK[want] or 1)
end

-- ── the slot ────────────────────────────────────────────────────────────────
-- Every key a new scenario slot needs before scene.load("system"): the
-- generator's (as the new-save panel writes them), the game mode, the crew
-- safety, and the scenario's id. → { [key] = value }
function worldKeys(sc)
  local w = sc.world
  local out = {}
  for k, v in pairs(GEN_DEFAULTS) do out[k] = v end
  if type(w) == "table" then
    for k, v in pairs(w.gen or {}) do out["g_" .. k:gsub("^g_", "")] = v end
    out.g_seed = math.floor(w.seed or 1)
    out.g_scale = math.floor(w.scale or WORLD_SCALE)
    out.g_names = w.names or 2
    if w.home == "alien" then
      out.g_homeKind = "alien"
      out.g_homeSeed = math.floor(w.homeSeed or 1)
    end
    out.g_air = w.air or ((w.home == "alien") and "random" or "earth")
  else
    out.g_seed, out.g_scale, out.g_names, out.g_air = 1, WORLD_SCALE, 2, "earth"
  end
  local st = sc.start or {}
  out["game.mode"] = "scenario"
  out["crew.safety"] = st.safety or "rescue"
  out["crew.death"] = (st.safety == "death")
  out.g_scenario = sc.id
  out.g_scenarioV = sc.v or 1
  return out
end

-- PLAY: wipe slot scn and its terrain, then write the keys. The caller loads
-- the system scene. api = { save, terrain } (the engine's by default).
function prepareSlot(id, api)
  api = api or {}
  local sv, tr = api.save or save, api.terrain or terrain
  local sc, err = load(id)
  if not sc then return false, err end
  local tdir = "saves/" .. SLOT .. "/terrain"
  if tr then
    if tr.saveDir and tr.saveDir() == tdir and api.release ~= false then pcall(tr.saveDir, "") end
    if tr.deleteSaveDir then pcall(tr.deleteSaveDir, tdir) end
  end
  if sv.deleteSlot then sv.deleteSlot(SLOT) end
  sv.slot(SLOT)
  for k, v in pairs(worldKeys(sc)) do sv.set(k, v) end
  return true
end

-- CONTINUE: what slot scn holds, read through get(key) (the menu peeks it).
-- → { id, title, step, steps, outcome } | nil
function slotSummary(get)
  local id = get("g_scenario")
  if type(id) ~= "string" then return nil end
  local sc = load(id)
  local done = get("scn.done") or {}
  local d, n = 0, 0
  if sc then d, n = progress(sc, done) end
  return { id = id, title = sc and sc.title or id, step = math.min(d + 1, n), steps = n, outcome = get("scn.outcome") }
end

-- ── validation ──────────────────────────────────────────────────────────────
BEATS = { ops = "string", say = "table", caption = "table", camera = "table", wait = "number", warp = "number",
          give = "table", funds = "number", unlock = "string", mark = "table", fail = "string", done = "boolean",
          sound = "string", alarm = "boolean",
          -- v2: dialogue, cutscenes, the world
          choice = "table", run = "string", cutscene = "boolean", shot = "table", var = "table", add = "table",
          branch = "table", ["goto"] = "string", objective = "table", knock = "table", state = "table", power = "table",
          spawn = "table", remove = "string", walk = "table", hook = "string", reactor = "table",
          -- FW-C: direction, light, the world (PLAN §2 F2, F4, F7)
          face = "table", look = "table", light = "table", weather = "table", breaker = "table", wear = "table",
          music = "music",
          -- graveyard2: a body turned to face something; lying or sitting
          turn = "table", pose = "table", gesture = "table" }
GESTURES = { stand_talk = true, point = true, wave = true, lean_console = true, kneel_work = true, sit_idle = true, lie_rest = true }
POSES = { lie = true, sit = true, stand = true }
-- FW-C cast fields (the rest is refused, so a typo is caught)
CAST_FIELDS = { name = true, tag = true, color = true, crew = true, portrait = true, expression = true, look = true,
                radio = true, delay = true, link = true }
TEACH = { overlay = true, catalogue = true, ghost = true, at = true, mark = true, marker = true }
WEATHERS = { clear = true, overcast = true, rain = true, storm = true, thunderstorm = true, hail = true, snow = true,
             blizzard = true, dust = true, duststorm = true, ash = true, ashstorm = true, calm = true }
SITES = { base = true, near_base = true, far_flat_lit = true, far_flat = true, far_flat_dark = true }
-- ctx (all optional): partExists(id) → bool, readFile(path) → text|nil,
-- decodeBp(code) → bp|nil, why, readJson(path) → value|nil, why
function validate(sc, ctx)
  ctx = ctx or {}
  local errs = {}
  local function E(path, msg) errs[#errs + 1] = path .. ": " .. msg end
  if type(sc) ~= "table" then return false, { "scenario: not a table" } end
  if type(sc.id) ~= "string" or not sc.id:match("^[%w_%-]+$") then E("id", "a word of letters, digits, _ or -") end
  if type(sc.title) ~= "string" or sc.title == "" then E("title", "missing") end
  if sc.teaches ~= nil and type(sc.teaches) ~= "table" then E("teaches", "a list of words") end
  if sc.brief ~= nil and type(sc.brief) ~= "table" then E("brief", "a list of lines") end
  local w = sc.world
  if w ~= "any" then
    if type(w) ~= "table" then E("world", "a table or \"any\"")
    else
      if type(w.seed) ~= "number" then E("world.seed", "a number") end
      if w.home ~= nil and w.home ~= "alien" and w.home ~= "earth" then E("world.home", "\"alien\" or \"earth\"") end
      if w.air ~= nil and type(w.air) ~= "string" then E("world.air", "a word (earth, rich, thin, none, random)") end
      -- FW-C: the time of day held over the site (PLAN §2 F4)
      if w.time ~= nil then
        if type(w.time) ~= "table" then E("world.time", "{ at = night | dusk | dawn | morning | noon | afternoon | evening | degrees, hold = true }")
        else
          if not elevationOf(w.time.at) then E("world.time.at", "night, dusk, dawn, morning, noon, afternoon, evening or degrees above the horizon") end
          if w.time.hold ~= nil and type(w.time.hold) ~= "boolean" then E("world.time.hold", "true or false") end
        end
      end
    end
  end
  local st = sc.start or {}
  if sc.start ~= nil and type(sc.start) ~= "table" then E("start", "a table") end
  if st.funds ~= nil and type(st.funds) ~= "number" then E("start.funds", "a number") end
  for i, id in ipairs(st.research or {}) do
    if ctx.techExists and not ctx.techExists(id) then E(string.format("start.research[%d]", i), "no research id " .. tostring(id)) end
  end
  if st.safety ~= nil and st.safety ~= "rescue" and st.safety ~= "death" and st.safety ~= "invincible" then
    E("start.safety", "rescue, death or invincible")
  end
  local names = {}
  for i, c in ipairs(st.crew or {}) do
    local p = string.format("start.crew[%d]", i)
    if type(c.name) ~= "string" then E(p .. ".name", "missing") else names[c.name] = true end
    if c.where then
      local site = c.where.site
      if site and not SITES[site] and not tostring(site):match("^lat:") then E(p .. ".where.site", "unknown siting rule '" .. tostring(site) .. "'") end
    end
    for j, it in ipairs(c.pack or {}) do
      if not (it.item or it.mat or it.part) then E(string.format("%s.pack[%d]", p, j), "item, part or mat") end
    end
    -- graveyard2: what they are, in words ("Night engineer"), shown on the
    -- strip, the picker, the tag over them and the plate
    if c.title ~= nil and type(c.title) ~= "string" then E(p .. ".title", "a few words (\"Night engineer\")") end
  end
  local marks = {}
  for k in pairs(st.marks or {}) do marks[k] = true end
  local structs = {}
  for i, s in ipairs(st.structures or {}) do
    if s.name then structs[s.name] = true end
  end
  local function check_ref(path, r, allowBare)
    if r == nil then return end
    local k, n = parseRef(r)
    if not k then
      if not allowBare then E(path, "not a ref (crew:<name>, mark:<name>, struct:<name>, craft:<name>, body:<name>, base): " .. tostring(r)) end
      return
    end
    if k == "crew" and not names[n] and next(names) then E(path, "no crew member named " .. n) end
    if k == "mark" and not marks[n] then E(path, "no mark named " .. n) end
  end
  for i, s in ipairs(st.structures or {}) do
    local p = string.format("start.structures[%d]", i)
    if type(s.bp) ~= "string" then E(p .. ".bp", "a file under scenarios/ (a SOLBP1 code)")
    elseif ctx.readFile then
      local code = ctx.readFile(DIR .. "/" .. s.bp)
      if not code then E(p .. ".bp", "no file scenarios/" .. s.bp)
      elseif ctx.decodeBp then
        local bp, why = ctx.decodeBp(code)
        if not bp then E(p .. ".bp", tostring(why))
        elseif ctx.partExists then
          for j, pc in ipairs(bp.pieces or {}) do
            if not ctx.partExists(pc.id) then E(string.format("%s.bp piece %d", p, j), "no part " .. tostring(pc.id)) end
          end
        end
      end
    end
    check_ref(p .. ".at", s.at)
  end
  for i, c in ipairs(st.crates or {}) do
    local p = string.format("start.crates[%d]", i)
    check_ref(p .. ".at", c.at)
    if type(c.parts) ~= "table" and type(c.items) ~= "table" then E(p, "parts or items") end
    if ctx.partExists then
      for id in pairs(c.parts or {}) do if not ctx.partExists(id) then E(p .. ".parts." .. tostring(id), "no such part") end end
    end
  end
  -- (the interaction plan §5.3) start.tags = { { struct, part | uid, name } }:
  -- designations painted on pieces ("P-3"), shown on their menus and in every
  -- refusal (scripts/part_info.lua reads them while the scenario runs)
  if st.tags ~= nil and type(st.tags) ~= "table" then E("start.tags", "a list of { struct, part | uid, name }") end
  local tagged = {}
  for i, t in ipairs(type(st.tags) == "table" and st.tags or {}) do
    local p = string.format("start.tags[%d]", i)
    if type(t) ~= "table" then E(p, "a table { struct, part | uid, name }")
    else
      local sn = type(t.struct) == "string" and t.struct:gsub("^struct:", "") or nil
      if not sn then E(p .. ".struct", "a structure's name")
      elseif next(structs) and not structs[sn] then E(p .. ".struct", "no start.structures entry named " .. sn) end
      if t.part == nil and t.uid == nil then E(p, "part or uid") end
      if t.uid ~= nil and (type(t.uid) ~= "number" or t.uid < 1 or t.uid % 1 ~= 0) then E(p .. ".uid", "a piece's uid (a whole number)") end
      if t.part ~= nil and type(t.part) ~= "string" then E(p .. ".part", "a part id (or its prefix)") end
      if type(t.name) ~= "string" or not t.name:match("%S") or #t.name > 12 then E(p .. ".name", "a designation of 1 to 12 characters")
      elseif tagged[t.name] then E(p .. ".name", "'" .. t.name .. "' is already start.tags[" .. tagged[t.name] .. "]")
      else tagged[t.name] = i end
    end
  end
  for i, c in ipairs(st.craft or {}) do
    local p = string.format("start.craft[%d]", i)
    if type(c.file) ~= "string" then E(p .. ".file", "a craft JSON under scenarios/")
    elseif ctx.readJson then
      local v, why = ctx.readJson(DIR .. "/" .. c.file)
      if not v then E(p .. ".file", "unreadable: " .. tostring(why))
      elseif not (v.bp and v.bp.parts) and not v.parts then E(p .. ".file", "not the VAB launch format ({\"fmt\":1,\"bp\":{…}})") end
    end
    local wh = c.where or {}
    if not (wh.pad or wh.vab or wh.orbit or wh.ground or wh.stand or wh.runway) then E(p .. ".where", "pad, runway, vab, orbit, ground or stand") end
  end
  for k, m in pairs(st.marks or {}) do check_ref("start.marks." .. k .. ".at", m.at) end
  -- (every mark a beat makes, first: a beat may name one made later)
  local function pre(list)
    for _, b in ipairs(type(list) == "table" and list or {}) do
      if type(b) == "table" then
        if type(b.mark) == "table" and type(b.mark.name) == "string" then marks[b.mark.name] = true end
        if type(b.choice) == "table" then for _, o in ipairs(b.choice.options or {}) do pre(o.beats) end end
        if type(b.branch) == "table" then pre(b.branch.beats); pre(b.branch.elseBeats) end
      end
    end
  end
  pre(sc.on_start); pre(sc.on_fail)
  for _, s in ipairs(type(sc.steps) == "table" and sc.steps or {}) do pre(s.on_enter); pre(s.on_done) end
  for _, q in pairs(type(sc.sequences) == "table" and sc.sequences or {}) do pre(q) end
  for _, ev in ipairs(type(sc.events) == "table" and sc.events or {}) do pre(ev.beats) end
  for _, md in ipairs(type(sc.models) == "table" and sc.models or {}) do
    for _, a in ipairs(type(md) == "table" and type(md.at) == "table" and md.at or {}) do pre(a.beats) end
  end
  local step_ids = {}
  for _, s in ipairs(type(sc.steps) == "table" and sc.steps or {}) do if type(s) == "table" and s.id then step_ids[s.id] = true end end
  local seqs = type(sc.sequences) == "table" and sc.sequences or {}
  local cast = type(sc.cast) == "table" and sc.cast or {}
  local hooks = sc._hooks
  local function check_who(path, who)
    if who == nil or who == "ops" then return end
    if type(who) ~= "string" then E(path, "a cast key or a crew name") return end
    if not cast[who] and not names[who] then E(path, "no one called '" .. who .. "' in cast or start.crew") end
  end
  local function check_seq(path, name)
    if type(name) ~= "string" or not seqs[name] then E(path, "no sequence '" .. tostring(name) .. "'") end
  end
  local function check_step(path, id)
    if not step_ids[id] then E(path, "no step '" .. tostring(id) .. "'") end
  end
  local function check_struct(path, n)
    if type(n) ~= "string" then E(path, "a structure name") return end
    n = n:gsub("^struct:", "")
    if next(structs) ~= nil and not structs[n] then E(path, "no start structure named " .. n) end
  end
  local check_beats
  check_beats = function(path, list)
    if list == nil then return end
    if type(list) ~= "table" then E(path, "a list of beats") return end
    for j, b in ipairs(list) do
      local p = string.format("%s[%d]", path, j)
      local n = 0
      if type(b) ~= "table" then E(p, "a beat is a table with one key") else
      for key, val in pairs(b) do
        n = n + 1
        local want = BEATS[key]
        local pk = p .. "." .. tostring(key)
        if not want then E(p, "unknown beat '" .. tostring(key) .. "'")
        elseif want == "music" then
          if val ~= false and not (type(val) == "string" and val:match("^audio/.+%.ogg$")) then E(pk, "\"audio/music/<file>.ogg\" or false") end
        elseif type(val) ~= want then E(pk, "a " .. want)
        else
          if key == "camera" or key == "shot" then
            local any = val.orbit or val.from or val.look
            if not any then E(pk, "orbit, from or look (a ref)") end
            for _, f in ipairs({ "orbit", "from", "to", "look" }) do if val[f] then check_ref(pk .. "." .. f, val[f]) end end
          elseif key == "mark" then
            if type(val.name) ~= "string" then E(pk .. ".name", "missing") end
          elseif key == "say" then
            if type(val.text or val[2]) ~= "string" then E(pk .. ".text", "missing") end
            check_who(pk .. ".who", val.who or val[1])
            -- FW-C: the listener beside the speaker; a line's own delay
            if val.with ~= nil then check_who(pk .. ".with", val.with) end
            if val.delay ~= nil and (type(val.delay) ~= "number" or val.delay < 0) then E(pk .. ".delay", "seconds, 0 or more") end
            if val.cross ~= nil and type(val.cross) ~= "boolean" then E(pk .. ".cross", "true: the next line cuts in a second early") end
          elseif key == "face" then
            check_who(pk .. ".who", val.who)
            if val.who == nil then E(pk .. ".who", "missing") end
            if type(val.emotion) ~= "string" or not FACES[faceName(val.emotion)] then
              E(pk .. ".emotion", "one of neutral, focus, happy, excited, relief, delight, worried, scared, panic, pain, strain, tired, bored (or alarmed, smile, calm, grim)")
            end
            if val.weight ~= nil and type(val.weight) ~= "number" then E(pk .. ".weight", "0..1") end
            if val.secs ~= nil and type(val.secs) ~= "number" then E(pk .. ".secs", "seconds") end
          elseif key == "look" then
            check_who(pk .. ".who", val.who)
            if val.who == nil then E(pk .. ".who", "missing") end
            if val.at ~= false then check_ref(pk .. ".at", val.at); if val.at == nil then E(pk .. ".at", "a ref, or false to let go") end end
          elseif key == "light" then
            for lk in pairs(val) do if not ({ ambient = 1, fog = 1, time = 1, secs = 1 })[lk] then E(pk .. "." .. tostring(lk), "ambient, fog, time or secs") end end
            if val.ambient ~= nil and val.ambient ~= false and type(val.ambient) ~= "number" then E(pk .. ".ambient", "a share of the world's ambient (0..2), or false") end
            if val.fog ~= nil and val.fog ~= false and type(val.fog) ~= "number" then E(pk .. ".fog", "a fog bank 0..1, or false") end
            if val.time ~= nil and val.time ~= false and not elevationOf(val.time) then E(pk .. ".time", "night, dusk, dawn, morning, noon, afternoon, evening, degrees, or false") end
          elseif key == "weather" then
            if val.kind ~= false and not WEATHERS[tostring(val.kind)] then E(pk .. ".kind", "clear, overcast, rain, storm, thunderstorm, hail, snow, blizzard, dust, duststorm, ash, ashstorm, or false (the world's own)") end
            if val.secs ~= nil and type(val.secs) ~= "number" then E(pk .. ".secs", "seconds") end
            if val.k ~= nil and type(val.k) ~= "number" then E(pk .. ".k", "0..1") end
          elseif key == "breaker" then
            check_struct(pk .. ".struct", val.struct)
            if not (val.part or val.uid) then E(pk, "part (an id prefix) or uid") end
            if val.closed == nil and not val.trip then E(pk .. ".closed", "true, false, or trip = true") end
          elseif key == "wear" then
            check_ref(pk .. ".craft", (type(val.craft) == "string" and not val.craft:find(":", 1, true)) and ("craft:" .. val.craft) or val.craft)
            if val.craft == nil then E(pk .. ".craft", "missing") end
            if not (val.part or val.uid) then E(pk, "part (an id prefix) or uid") end
            if type(val.hp) ~= "number" then E(pk .. ".hp", "0.05..1") end
          elseif key == "choice" then
            check_who(pk .. ".who", val.who)
            if type(val.options) ~= "table" or #val.options < 1 then E(pk .. ".options", "at least one") end
            for oi, o in ipairs(val.options or {}) do
              local po = string.format("%s.options[%d]", pk, oi)
              if type(o.text) ~= "string" then E(po .. ".text", "missing") end
              if o.run then check_seq(po .. ".run", o.run) end
              if o.step then check_step(po .. ".step", o.step) end
              if o.beats then check_beats(po .. ".beats", o.beats) end
            end
          elseif key == "run" then check_seq(pk, val)
          elseif key == "goto" then check_step(pk, val)
          elseif key == "cutscene" then
            if not (path:match("^sequences%.") and j == 1) then E(pk, "only as the first beat of a sequence") end
          elseif key == "branch" then
            if type(val.var) ~= "string" then E(pk .. ".var", "missing") end
            if val.run then check_seq(pk .. ".run", val.run) end
            if val["else"] then check_seq(pk .. ".else", val["else"]) end
            check_beats(pk .. ".beats", val.beats); check_beats(pk .. ".elseBeats", val.elseBeats)
          elseif key == "knock" or key == "state" or key == "power" then
            check_struct(pk .. ".struct", val.struct)
            if not (val.part or val.uid) then E(pk, "part (an id prefix) or uid") end
          elseif key == "walk" then
            check_who(pk .. ".who", val.who)
            check_ref(pk .. ".to", val.to)
            -- graveyard2: near (stop this far off: a walk up to someone), wait, face (a ref)
            if val.near ~= nil and (type(val.near) ~= "number" or val.near < 0) then E(pk .. ".near", "metres, 0 or more") end
            if val.secs ~= nil and type(val.secs) ~= "number" then E(pk .. ".secs", "seconds") end
            if val.speed ~= nil and type(val.speed) ~= "number" then E(pk .. ".speed", "m/s") end
            if val.wait ~= nil and type(val.wait) ~= "boolean" then E(pk .. ".wait", "true or false") end
            if val.face ~= nil then check_ref(pk .. ".face", val.face) end
            if val.pose ~= nil and (type(val.pose) ~= "table" or not POSES[tostring(val.pose.kind)]) then E(pk .. ".pose", "{ kind = lie|sit, at | struct + spot, head|facing|toward, height } on arrival") end
          elseif key == "gesture" then
            check_who(pk .. ".who", val.who)
            if val.who == nil then E(pk .. ".who", "missing") end
            if val.clip ~= false and not GESTURES[tostring(val.clip)] then E(pk .. ".clip", "stand_talk, point, wave, lean_console, kneel_work, or false") end
            if val.secs ~= nil and type(val.secs) ~= "number" then E(pk .. ".secs", "seconds (none: held)") end
          elseif key == "turn" then
            check_who(pk .. ".who", val.who)
            if val.who == nil then E(pk .. ".who", "missing") end
            check_ref(pk .. ".to", val.to)
            if val.to == nil then E(pk .. ".to", "a ref to face") end
          elseif key == "pose" then
            check_who(pk .. ".who", val.who)
            if val.who == nil then E(pk .. ".who", "missing") end
            if not POSES[tostring(val.kind)] then E(pk .. ".kind", "lie, sit or stand") end
            if val.kind ~= "stand" and val.struct ~= nil then
              -- (a spot in a structure's own frame: its floors do not follow the ground)
              check_struct(pk .. ".struct", val.struct)
              if type(val.spot) ~= "table" or type(val.spot[1]) ~= "number" then E(pk .. ".spot", "{ x, y, z } in the structure's frame (y: the surface's height)") end
              if val.toward ~= nil and type(val.toward) ~= "table" then E(pk .. ".toward", "{ x, y, z } in the structure's frame") end
            elseif val.kind ~= "stand" then
              check_ref(pk .. ".at", val.at)
              if val.at == nil then E(pk .. ".at", "a ref (the bunk, the seat), or struct + spot") end
            end
            if val.head ~= nil then check_ref(pk .. ".head", val.head) end
            if val.facing ~= nil then check_ref(pk .. ".facing", val.facing) end
            if val.height ~= nil and type(val.height) ~= "number" then E(pk .. ".height", "metres over the ref's ground") end
            if val.stand ~= nil then check_ref(pk .. ".stand", val.stand) end
          elseif key == "hook" then
            if not sc.hooks then E(pk, "the scenario names no hooks")
            elseif hooks and type(hooks[val]) ~= "function" then E(pk, "no function '" .. val .. "' in hooks") end
          elseif key == "spawn" then
            for sk in pairs(val) do if not ({ structure = 1, crate = 1, flag = 1, craft = 1, crew = 1 })[sk] then E(pk .. "." .. tostring(sk), "structure, crate, flag, craft or crew") end end
          elseif key == "objective" then
            if type(val.text) ~= "string" then E(pk .. ".text", "missing") end
            if val.step then check_step(pk .. ".step", val.step) end
          end
        end
      end
      if n ~= 1 then E(p, "one key a beat") end
      end
    end
  end
  check_beats("on_start", sc.on_start)
  local function check_goal(path, g, failList)
    if type(g) ~= "table" then E(path, "a table") return end
    local K = KINDS[g.kind]
    if not K then E(path .. ".kind", "unknown kind '" .. tostring(g.kind) .. "'") return end
    if failList and not K.fail then E(path .. ".kind", "'" .. g.kind .. "' is not a fail condition") end
    if not failList and K.fail and g.kind ~= "timer" then E(path .. ".kind", "'" .. g.kind .. "' belongs in fail") end
    for _, f in ipairs(K.req or {}) do
      if g[f] == nil then E(path .. "." .. f, "missing") end
    end
    if g.hold ~= nil and type(g.hold) ~= "number" then E(path .. ".hold", "seconds") end
    for _, f in ipairs({ "who", "at" }) do
      if g[f] ~= nil and type(g[f]) == "string" and g[f]:find(":", 1, true) then check_ref(path .. "." .. f, g[f]) end
    end
    if g.struct and type(g.struct) == "string" then
      local n = g.struct:gsub("^struct:", "")
      if next(structs) == nil and not g.built then -- a structure the player builds is named by them; allow it
      elseif not structs[n] and not g.built then E(path .. ".struct", "no start structure named " .. n .. " (built = true if the player names it)") end
    end
  end
  local ids_ = {}
  if type(sc.steps) ~= "table" or #sc.steps == 0 then E("steps", "at least one step") end
  local required = 0
  for i, s in ipairs(sc.steps or {}) do
    local p = string.format("steps[%d]", i)
    if type(s.id) ~= "string" then E(p .. ".id", "missing")
    elseif ids_[s.id] then E(p .. ".id", "duplicate id " .. s.id)
    else ids_[s.id] = true end
    if type(s.text) ~= "string" then E(p .. ".text", "missing") end
    if not s.optional then required = required + 1 end
    if type(s.goals) ~= "table" or #s.goals == 0 then E(p .. ".goals", "at least one goal")
    else for j, g in ipairs(s.goals) do check_goal(string.format("%s.goals[%d]", p, j), g, false) end end
    check_beats(p .. ".on_enter", s.on_enter)
    check_beats(p .. ".on_done", s.on_done)
    if s.teach ~= nil then
      if type(s.teach) ~= "table" then E(p .. ".teach", "a table")
      else
        for k in pairs(s.teach) do if not TEACH[k] then E(p .. ".teach." .. tostring(k), "unknown teach field") end end
        if s.teach.ghost and ctx.readFile and not ctx.readFile(DIR .. "/" .. s.teach.ghost) then E(p .. ".teach.ghost", "no file scenarios/" .. s.teach.ghost) end
        check_ref(p .. ".teach.at", s.teach.at)
      end
    end
    if s.mark ~= nil then check_ref(p .. ".mark", s.mark) end
    if s.act ~= nil and type(s.act) ~= "string" then E(p .. ".act", "the words a setback card goes back to (\"ACT 3\")") end
    if s.stage ~= nil and type(s.stage) ~= "table" then E(p .. ".stage", "a start-like table restaged on a return to this checkpoint") end
    if type(s.stage) == "table" and s.stage.beats ~= nil then check_beats(p .. ".stage.beats", s.stage.beats) end
  end
  if required == 0 and #(sc.steps or {}) > 0 then E("steps", "every step is optional") end
  for i, s in ipairs(sc.steps or {}) do
    for j, g in ipairs(s.goals or {}) do
      if g.kind == "step_done" and not ids_[g.step] then E(string.format("steps[%d].goals[%d].step", i, j), "no step " .. tostring(g.step)) end
    end
  end
  for i, f in ipairs(sc.fail or {}) do
    check_goal(string.format("fail[%d]", i), f, true)
    if type(f.text) ~= "string" then E(string.format("fail[%d].text", i), "the line the debrief shows") end
  end
  check_beats("on_fail", sc.on_fail)
  local S = sc.score
  if type(S) ~= "table" then E("score", "a table with par")
  else
    if type(S.par) ~= "number" or S.par <= 0 then E("score.par", "seconds, above 0") end
    local M = S.medals or {}
    if M.bronze ~= nil and M.bronze ~= "done" then E("score.medals.bronze", "\"done\": bronze is never a wall") end
    local tg = type(M.gold) == "table" and M.gold.time
    local ts = type(M.silver) == "table" and M.silver.time
    if tg and ts and tg > ts then E("score.medals", "gold's time ratio is looser than silver's") end
    if (type(M.gold) == "table" and M.gold.funds or type(M.silver) == "table" and M.silver.funds) and not (S.budget and S.budget.funds) then
      E("score.budget.funds", "a medal reads funds, so the budget needs them")
    end
  end
  if sc.after ~= nil and sc.after ~= "freeplay" and sc.after ~= "menu" then E("after", "freeplay or menu") end
  if sc.failure ~= nil and sc.failure ~= "checkpoint" and sc.failure ~= "end" then E("failure", "\"checkpoint\" (a fail goes back to the last checkpoint) or \"end\" (a fail ends the run)") end
  -- v2: the cast, the sequences, the events, the hooks
  for k, c in pairs(cast) do
    local pc = "cast." .. tostring(k)
    if type(c) ~= "table" then E(pc, "a table { name, tag, color, crew, portrait, radio, delay, link }")
    else
      if c.crew and not names[c.crew] then E(pc .. ".crew", "no crew member named " .. tostring(c.crew)) end
      -- FW-C (PLAN §2 F1, F3)
      for f in pairs(c) do if not CAST_FIELDS[f] then E(pc .. "." .. tostring(f), "unknown cast field (name, tag, color, crew, portrait, expression, look, radio, delay, link)") end end
      if c.portrait ~= nil and type(c.portrait) ~= "string" then E(pc .. ".portrait", "\"auto\" (the booth's picture) or a file under scenarios/") end
      if c.portrait == "auto" and not c.crew and type(c.look) ~= "number" then E(pc .. ".portrait", "\"auto\" needs crew = <name> or look = <seed>") end
      -- (a missing picture is not an error: the plate draws the role letter)
      if c.expression ~= nil and not (type(c.expression) == "string" and FACES[faceName(c.expression)]) then E(pc .. ".expression", "a face (neutral, tired, alarmed, focus, worried, happy…)") end
      if c.look ~= nil and type(c.look) ~= "number" then E(pc .. ".look", "a face seed (a number)") end
      if c.radio ~= nil and type(c.radio) ~= "boolean" then E(pc .. ".radio", "true or false") end
      if c.delay ~= nil and (type(c.delay) ~= "number" or c.delay < 0) then E(pc .. ".delay", "seconds, 0 or more") end
      if c.link ~= nil then
        local lk = parseRef(c.link)
        if lk ~= "craft" and lk ~= "crew" then E(pc .. ".link", "craft:<name> or crew:<name>") else check_ref(pc .. ".link", c.link) end
      end
    end
  end
  -- FW-C: meters and models (PLAN §2 F6)
  for i, m in ipairs(type(sc.meters) == "table" and sc.meters or {}) do
    local p = string.format("meters[%d]", i)
    if type(m) ~= "table" then E(p, "a table { var, read, … }")
    else
      if type(m.var) ~= "string" then E(p .. ".var", "the variable it keeps") end
      local src, fld = tostring(m.read or ""):match("^(%a+)%.?([%w_]*)$")
      if not (src and METER_READS[src]) then E(p .. ".read", "reactor.<field>, grid.supply|need|stored|battery, dose.msv, suit.o2, room.p|o2|co2, part.hp, piece.<field> or var.<name>")
      elseif (src == "reactor" or src == "grid" or src == "room" or src == "piece") and m.struct == nil then E(p .. ".struct", "the structure it reads")
      elseif (src == "dose" or src == "suit") and m.who == nil then E(p .. ".who", "the crew member it reads")
      elseif src == "part" and m.craft == nil then E(p .. ".craft", "the craft it reads") end
      if m.struct then check_struct(p .. ".struct", m.struct) end
      if m.mode ~= nil and not METER_MODES[m.mode] then E(p .. ".mode", "sample, integrate, peak or min") end
      if m.when ~= nil then
        if type(m.when) ~= "table" or not KINDS[m.when.kind] then E(p .. ".when.kind", "a goal table (any kind)") end
      end
      if m.scale ~= nil and type(m.scale) ~= "number" then E(p .. ".scale", "a number") end
    end
  end
  for i, md in ipairs(type(sc.models) == "table" and sc.models or {}) do
    local p = string.format("models[%d]", i)
    if type(md) ~= "table" then E(p, "a table { var, start, rate, when, … }")
    else
      if type(md.var) ~= "string" then E(p .. ".var", "the variable it keeps") end
      for _, f in ipairs({ "start", "rate", "accel", "base", "rest", "tau", "fall", "min", "max", "round" }) do
        if md[f] ~= nil and type(md[f]) ~= "number" then E(p .. "." .. f, "a number") end
      end
      for _, f in ipairs({ "active", "when" }) do
        if md[f] ~= nil and (type(md[f]) ~= "table" or not KINDS[md[f].kind]) then E(p .. "." .. f .. ".kind", "a goal table (any kind)") end
      end
      for j, a in ipairs(md.at or {}) do
        local pa = string.format("%s.at[%d]", p, j)
        if type(a.value) ~= "number" then E(pa .. ".value", "a number") end
        if a.run then check_seq(pa .. ".run", a.run) end
        if not (a.run or a.beats) then E(pa, "run or beats") end
        check_beats(pa .. ".beats", a.beats)
      end
    end
  end
  if sc.vars ~= nil and type(sc.vars) ~= "table" then E("vars", "a table of name = value") end
  if sc.sequences ~= nil and type(sc.sequences) ~= "table" then E("sequences", "a table of name = { beats }") end
  for name, q in pairs(seqs) do check_beats("sequences." .. tostring(name), q) end
  for i, ev in ipairs(type(sc.events) == "table" and sc.events or {}) do
    local p = string.format("events[%d]", i)
    if type(ev.when) ~= "table" then E(p .. ".when", "a goal table (any kind)")
    else
      local K = KINDS[ev.when.kind]
      if not K then E(p .. ".when.kind", "unknown kind '" .. tostring(ev.when.kind) .. "'")
      else for _, f in ipairs(K.req or {}) do if ev.when[f] == nil then E(p .. ".when." .. f, "missing") end end end
    end
    if not (ev.run or ev.beats) then E(p, "run or beats") end
    if ev.run then check_seq(p .. ".run", ev.run) end
    check_beats(p .. ".beats", ev.beats)
    if ev.after then check_step(p .. ".after", ev.after) end
    -- graveyard2: `also`, a second condition
    if ev.also ~= nil then if type(ev.also) ~= "table" or not ev.also.kind then E(p .. ".also", "a condition { kind = … }") else check_goal(p .. ".also", ev.also) end end
    if ev.during then check_step(p .. ".during", ev.during) end
  end
  for i, s in ipairs(type(sc.steps) == "table" and sc.steps or {}) do
    if s.run then check_seq(string.format("steps[%d].run", i), s.run) end
    for j, g in ipairs(s.goals or {}) do
      if g.kind == "hook" and (not sc.hooks or (hooks and not (hooks.goals and type(hooks.goals[g.fn]) == "function"))) then
        E(string.format("steps[%d].goals[%d].fn", i, j), "no goals." .. tostring(g.fn) .. " in hooks")
      end
    end
  end
  if type(sc.debrief) ~= "table" then E("debrief", "gold, silver, bronze and fail lines")
  else for _, k in ipairs({ "bronze", "fail" }) do if type(sc.debrief[k]) ~= "string" then E("debrief." .. k, "missing") end end end
  if sc._file then for i, e in ipairs(errs) do errs[i] = sc._file .. ": " .. e end end
  return #errs == 0, errs
end

-- ── serialising (F12's dump) ────────────────────────────────────────────────
local function is_ident(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil end
function serialize(v, ind)
  ind = ind or ""
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ".0")
  end
  if t == "boolean" or t == "nil" then return tostring(v) end
  if t ~= "table" then return "nil" end
  local n = #v
  local parts = {}
  local inner = ind .. "  "
  for i = 1, n do parts[#parts + 1] = serialize(v[i], inner) end
  local keys = {}
  for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local ks = is_ident(k) and k or ("[" .. serialize(k) .. "]")
    parts[#parts + 1] = ks .. " = " .. serialize(v[k], inner)
  end
  local flat = "{ " .. table.concat(parts, ", ") .. " }"
  if #parts == 0 then return "{}" end
  if #flat <= 100 and not flat:find("\n", 1, true) then return flat end
  return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. ind .. "}"
end

-- For the menu scene: this file's functions as a table (a copy loaded from disk
-- when there is no ScenarioLib node).
function lib()
  local h = findScript and findScript("scenario") or nil
  if h and h.valid ~= false then return h end
  -- (the engine's Luau has no loadfile: the menu spawns a ScenarioLib)
  if spawn and vec3 and not (find and find("ScenarioLib")) then pcall(spawn, "ScenarioLib", vec3(0, 0, 0)) end
  h = findScript and findScript("scenario") or nil
  if h and h.valid ~= false then return h end
  if loadfile and setfenv then
    for _, p in ipairs({ "solar/scripts/scenario.lua", "scripts/scenario.lua" }) do
      local f = loadfile(p)
      if f then local e = setmetatable({}, { __index = _G }); setfenv(f, e); f(); return e end
    end
  end
  local t = read_text("scripts/scenario.lua")
  if t and loadstring and setfenv then
    local f = loadstring(t, "@scripts/scenario.lua")
    if f then local e = setmetatable({}, { __index = _G }); setfenv(f, e); f(); return e end
  end
  return nil
end
