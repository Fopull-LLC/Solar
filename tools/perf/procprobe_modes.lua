-- ── proc probe (tools/perf/procprobe.sh): builder_proc's meshes over VAB visits ──
-- Spliced into a copy of perfbench.lua before its main (after nothing else).
-- mode "procsoak": a fresh world; `proc_cycles` (3) times: into the VAB (the
-- additive builder overlay), a blueprint of drawn members whose lengths are
-- new each cycle (fresh cache keys, so builder_proc builds new meshes), held
-- a moment, out of the VAB; then the pause menu's MAIN MENU and CONTINUE (a
-- full scene load), and the same visits once more. After each step one
-- `PROC` line: perf.counts().scriptMeshes / scriptMeshBytes, the meshes
-- perf.resources() names per script, and builder_proc.stats(). The engine
-- 0606 owner lifetimes (`scene = true`) should bring builder_proc's count back
-- to zero at the scene load; before them it never came down.
local PR = {}
function PR.line(tag)
  local c = perf.counts() or {}
  local by, nb = {}, 0
  local res = perf.resources and perf.resources() or {}
  for _, m in ipairs(res.meshes or {}) do
    local s = tostring(m.script or "?"):match("([%w_]+)%.lua$") or tostring(m.script or "?")
    by[s] = (by[s] or 0) + 1
    if s == "builder_proc" then nb = nb + 1 end
  end
  local parts = {}
  for k, v in pairs(by) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  local bp = findScript("builder_proc")
  local st = bp and bp.stats and bp.stats() or {}
  P("PROC %-14s scriptMeshes %s (%.1f KB) builder_proc %d | cache %s builds %s | by script: %s",
    tag, tostring(c.scriptMeshes), (c.scriptMeshBytes or 0) / 1024, nb, tostring(st.meshes), tostring(st.builds),
    table.concat(parts, " "))
  return c.scriptMeshes or -1, nb
end
-- drawn members, `n` of them, lengths new for cycle k (5 cm steps: keys differ)
function PR.bp(k, n)
  puid = 0
  local L = {}
  local X, Y = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }
  local H = prec("hub", 0, 1.0, 0, X, Y)
  L[#L + 1] = H
  for j = 1, n do
    local len = 0.4 + 0.05 * ((k - 1) * n + j)
    local prof = ({ "box", "tube", "ibeam", "truss" })[(j % 4) + 1]
    local r = prec("beamP", (j - n / 2) * 0.4, 1.0 + len / 2, 0, X, Y, { parent = H.uid, att = "surface" })
    r.size = { len = len, prof = prof }
    r.proc, r.prof = "member", prof
    L[#L + 1] = r
  end
  return L
end
function PR.visit(k, tag)
  local BH = enter_vab(tag .. "_in")
  if not BH then P("PROC no builder at %s", tag); return false end
  local B = findScript("builder")
  wait(1.5)
  load_bp(B, tag .. "_bp", PR.bp(k, params.proc_members or 12))
  wait(2)
  PR.line(tag .. " in")
  BH.leave(); wait(3)
  PR.line(tag .. " out")
  return true
end
function run_procsoak()
  PR.line("start")
  local cyc = params.proc_cycles or 3
  for k = 1, cyc do PR.visit(k, "v" .. k) end
  local gm = findScript("game_manager")
  local s = save.slot()
  if gm and gm.exitToMenu then
    pcall(gm.exitToMenu)
    wait_for(function() return tostring(scene.current() or ""):match("menu") end, 60, "the menu")
    wait(3)
    PR.line("at menu")
    save.slot(s)
    scene.load("system")
    yield()
    wait_for(function() local g = findScript("game_manager"); return g and not g.loading and not g.curtain end, 300, "the reveal after the menu")
    wait_ready(120)
    clear_weather()
    PR.line("back")
    for k = 1, cyc do PR.visit(k, "w" .. k) end
  end
  local n, nb = PR.line("end")
  P("PROC RESULT procsoak: scriptMeshes %d at the end, builder_proc %d", n, nb)
end
