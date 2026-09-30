-- LOOP PROBE — the game's own new-save path, driven without a player.
--
-- The complaint this exists to answer is about the LOOP: rewards that cannot be
-- claimed, materials that cannot be seen, sold, or researched. None of it was
-- reachable from `floptle run`, because the only way into a real save is the
-- main menu, and `run` presses nothing.
--
-- So this does exactly what clicking "Create" on an empty slot does — wipe the
-- slot's terrain, select it, store the seed, load the system scene — and then
-- reports, once a second, on every system the complaint names: the balance, the
-- contract on the books and whether its goals are ticking, what the pack holds
-- and what it is worth, what research is affordable, and whether the depot will
-- take a sale.
--
-- It is a TEST FIXTURE. `scenes/loop_probe.ron` is the only thing that names it.
--
--     floptle run . --scene loop_probe --seconds 120

defaults = {
  --- Which slot to run in. NOT slot1 — the rig wipes the slot's terrain on the
  --- way in, and wiping the slot somebody actually plays would be rude.
  slot = 9,
  --- Galaxy seed for the run. Fixed, so two runs of the rig agree.
  seed = 4242,
  --- Seconds between reports.
  --@range 1 30
  every = 10.0,
}

local jumped = false
local drove = false
local t_report = 0

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

function update(node, dt)
  if not jumped then
    jumped = true
    local s = "slot" .. math.floor(params.slot or 9)
    terrain.deleteSaveDir("saves/" .. s .. "/terrain")
    save.slot(s)
    save.set("g_seed", math.floor(params.seed or 4242))
    -- Ride the swap. `scene.load` replaces the world, which would take this
    -- node with it and end the run one frame after it started — the rig has to
    -- outlive the scene it is testing.
    node.persistent = true
    print("loop probe: created " .. s .. ", loading the system…")
    scene.load("system")
    return
  end

  if time - t_report < (params.every or 10.0) then return end
  t_report = time
  print(string.rep("-", 64))
  print(string.format("loop probe @ %.0fs   slot=%s", time, tostring(save.slot())))

  print("  terrain.busy: " .. tostring(terrain.busy and terrain.busy()))
  local lt = find("Loading Text")
  if lt then
    for line in (tostring(lt.text) .. "\n"):gmatch("(.-)\n") do
      if #line > 0 then print("  | " .. line) end
    end
  end

  local co = ref("company")
  if not co then print("  company: MISSING") else
    print(string.format("  company: %s   standing %s",
      tostring(co.money(co.balance())), tostring(co.rep())))
  end

  local mi = ref("missions")
  if not mi then print("  missions: MISSING") else
    local line = mi.activeLine()
    print("  contract: " .. (line and tostring(line) or "none signed"))
    for _, g in ipairs(mi.goalLines() or {}) do print("     " .. tostring(g)) end
    print("  offers on the board: " .. tostring(#(mi.offers() or {})))
  end

  local inv = ref("inventory")
  if not inv then print("  inventory: MISSING") else
    -- "astro" is the crew's own pack, the container the I / Tab panel reads.
    print(string.format("  pack: %.1f / %.1f kg   worth %s",
      inv.mass("astro"), inv.cap("astro"), tostring(inv.totalValue("astro"))))
    local items = inv.items("astro") or {}
    if #items == 0 then print("     (empty)") end
    for _, st in ipairs(items) do
      print(string.format("     %-14s x%-5d %7.1f kg   $%d",
        tostring(st.mat), st.n or 0, st.kg or 0, math.floor(st.value or 0)))
    end
    print("  seen so far: " .. tostring(#(inv.seenList() or {})))
  end

  -- ── DRIVE THE LOOP ────────────────────────────────────────────────────────
  -- Once the base is up, do what a player does: put ore in the pack, walk it
  -- to the depot, unload, sell, and spend the money on research. Every step is
  -- reported so a failure names itself instead of showing up as "I could not
  -- sell them".
  local inv2, fm, co2, rs2 = ref("inventory"), ref("facility_menu"), ref("company"), ref("research")
  if not drove and inv2 and fm and co2 and time > 12 then
    drove = true
    print("  ++ DRIVING THE LOOP")
    local m = ref("materials")
    local ore = m and m.list() and m.list()[1] or nil
    if not ore then print("     no materials catalogue — cannot mine") return end
    inv2.add("astro", ore, 20)
    print(string.format("     mined 20 x %s -> pack %.1f kg worth %d",
      tostring(ore), inv2.mass("astro"), inv2.totalValue("astro")))
    print("     depot offers: " .. tostring(fm.depotAction()))
    local before = co2.balance()
    -- The two presses the panel asks for, called directly: the rig cannot
    -- open a facility panel, and `action()` needs one open. These are the same
    -- two functions that button reaches.
    print("     press 1: " .. tostring(fm.depotUnload()))
    print("     depot now offers: " .. tostring(fm.depotAction()))
    print("     press 2: " .. tostring(fm.depotSell()))
    print(string.format("     balance %d -> %d  (%+d)", before, co2.balance(), co2.balance() - before))
    if rs2 then
      local id = "tankM"
      local ok, why = rs2.unlock(id)
      print(string.format("     research %s: %s %s", id, tostring(ok), tostring(why or "")))
      print("     still locked: " .. tostring(#(rs2.pendingLines() or {})))
    end
  end

  local rs = ref("research")
  if not rs then print("  research: MISSING") else
    local pend = rs.pendingLines() or {}
    print("  research still locked: " .. tostring(#pend))
    for i, l in ipairs(pend) do
      if i > 4 then break end
      print("     " .. tostring(l))
    end
  end
end
