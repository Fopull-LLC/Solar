-- CHEATS — the testing keys. Not a secret, not an easter egg: a game whose
-- money loop takes twenty minutes to walk through is a game you cannot iterate
-- on, and every one of these exists because something downstream of money or
-- distance needed checking without playing the game first.
--
--   F6   re-site the colony where you're standing
--   F7   teleport to the base
--   F8   +$25,000
--   F9   INFINITE FUNDS on/off   (survives the scene hop and the reload)
--   F10  unlock every part in the catalogue
--   F11  complete the contract on the books
--
-- F9 is a FLAG, not a big deposit. A one-off grant still runs dry halfway
-- through a builder session and then "did that fail because of the bug or
-- because I ran out of money?" is a question you have to stop and answer.
-- While it is on, `company.balance()` reads absurd and `company.spend()` never
-- refuses — see company.lua.
--
-- Everything is written to the SAVE SLOT, so a cheated slot stays cheated and
-- a clean one stays clean. The pink badge in the corner is deliberate: nothing
-- else in the game is that colour, so a screenshot of a cheated run is
-- obviously a screenshot of a cheated run.

defaults = {
  --@header Keys
  --@range 0 1
  enabled = 1,        -- 0 disables every key (ship a build with this off)
  --@range 100 1000000 --@units $
  grant = 25000,      -- what F8 pays in
}

local flash, flash_t = nil, -100
local el

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function say(msg)
  flash, flash_t = msg, time
  log("debug: " .. msg)
end

-- ── the keys ────────────────────────────────────────────────────────────────

local function toggle_rich()
  local on = not (save.get("debug.rich") == true)
  save.set("debug.rich", on)
  say(on and "INFINITE FUNDS ON" or "infinite funds off")
end

local function grant()
  local co = ref("company")
  if not co then return say("no company in this scene") end
  co.earn(params.grant, "debug grant")
  say(string.format("+%s", co.money(params.grant)))
end

local function unlock_all()
  local rs = ref("research")
  if not (rs and rs.TECH) then return say("no research in this scene") end
  local d = save.get("res.done") or {}
  local n = 0
  for id in pairs(rs.TECH) do
    if not d[id] then d[id], n = true, n + 1 end
  end
  save.set("res.done", d)
  say(n > 0 and string.format("%d part(s) unlocked", n) or "everything was already unlocked")
end

local function finish_contract()
  local mi = ref("missions")
  if not (mi and mi.active) then return say("no contract on the books") end
  local m = mi.byId(mi.active)
  -- Through the mission board's own payout, so the ledger and the reputation
  -- move exactly as a real completion moves them.
  if mi.forceComplete() then
    say("contract completed: " .. ((m and m.title) or "?"))
  end
end

-- Home, from wherever you wandered to. Placed a few metres up so you land on
-- the roof of nothing and fall the rest of the way.
local function go_home()
  local bf = ref("base_facilities")
  local astro = find("Astronaut")
  if not (bf and astro) then return say("no base in this scene") end
  if not bf.sited then return say("the base isn't sited yet") end
  local d = space.dominant(bf.baseX, bf.baseY, bf.baseZ)
  local b = d and space.body(d)
  local ux, uy, uz = 0, 1, 0
  if b then
    ux, uy, uz = bf.baseX - b.x, bf.baseY - b.y, bf.baseZ - b.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    if l > 1e-3 then ux, uy, uz = ux / l, uy / l, uz / l end
  end
  astro.x, astro.y, astro.z = bf.baseX + ux * 4, bf.baseY + uy * 4, bf.baseZ + uz * 4
  astro.vx, astro.vy, astro.vz = 0, 0, 0
  say("teleported to the base")
end

local function resite()
  local bf = ref("base_facilities")
  if not (bf and bf.resite) then return say("no base in this scene") end
  bf.resite()
  say("re-siting the colony here")
end

local KEYS = {
  { "f6",  resite,          "F6  re-site base here" },
  { "f7",  go_home,         "F7  teleport to base" },
  { "f8",  grant,           "F8  +money" },
  { "f9",  toggle_rich,     "F9  infinite funds" },
  { "f10", unlock_all,      "F10 unlock all parts" },
  { "f11", finish_contract, "F11 finish contract" },
}

-- ── the badge ───────────────────────────────────────────────────────────────

-- The pink pill: a padded row around its label, sized to what it says.
local function pill(key, text)
  return { "row", key = key, style = "hud/debugChip", w = "fit", h = 24, align = "center",
           pad = 0, gap = 0,
           items = { { "box", key = "l", w = 12, h = 1 },
                     { "text", key = "t", style = "hud/debugChipText", w = "fit", h = "fit", text = text },
                     { "box", key = "r", w = 12, h = 1 } }, function(x) return x end }
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if params.enabled >= 0.5 then
    for _, k in ipairs(KEYS) do
      if input.pressed(k[1]) then k[2]() end
    end
  end

  local co = ref("company")
  local on = co and co.isRich and co.isRich()
  local recent = flash and (time - flash_t) < 5.0
  -- The badge is up whenever the account is cheated, and for a few seconds
  -- after any key so you can see that the key landed. Otherwise nothing: a
  -- debug HUD you can't turn off is a debug HUD you stop reading.
  if not (on or recent) then
    if el then el.visible = false end
    return
  end
  if el then el.visible = true end

  local rows = {}
  if on then
    rows[#rows + 1] = pill("chip", "debug · infinite funds")
  end
  if recent then
    rows[#rows + 1] = pill("flash", flash)
    local keys = {}
    for _, k in ipairs(KEYS) do keys[#keys + 1] = k[3] end
    rows[#rows + 1] = { "text", key = "keys", style = "hud/debugKeys", w = 150, textAlign = "end",
                        h = "fit", text = table.concat(keys, "\n") }
  end
  ui.make(node, { "col", key = "dbg", w = "100%", dir = "col", gap = 5, pad = 0,
                  align = "end", items = rows, function(row) return row end })
end
