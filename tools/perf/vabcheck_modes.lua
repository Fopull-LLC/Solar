-- ── VAB craft-check probe (tools/perf/vabcheck.sh): the craft check in the
-- real Vehicle Assembly (scripts/craft_check.lua, builder.launchCheck rows).
-- Spliced into a copy of perfbench.lua before its main, with
-- tests/fixtures/check/crafts.lua as VCK.CRAFTS and the bike fixtures as
-- VCK.FIX[name]; one table of functions (perfbench's chunk is near Lua's
-- 200-locals ceiling).
--   vabcheck   enter the VAB, then for each craft in params/strs `crafts`
--              (default: jet_nointake jet_upright bike125 rocket_heavy):
--              load it, nothing selected, INSPECT, frame it; print every
--              row (`VCK ROW`), the chip and the hint line; a screenshot;
--              then the pointer on the first row (its parts outlined) and a
--              second screenshot. Rows the craft must show are checked
--              (`VCK PASS|FAIL`), and the check's cost (`VCK MS`).
-- Pictures: save/user/vabshots/<craft>_{rows,hover}.png in the scratch project.
VCK = { fails = 0 }
function VCK.check(name, ok, fmt, ...)
  P("VCK %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then VCK.fails = VCK.fails + 1 end
  return ok
end
function VCK.shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://vabshots/" .. nm .. ".png", bytes); P("VCK SHOT %s t=%.3f", nm, time)
    else P("VCK SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("VCK capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- craft name → { parts, want = { row ids one of which must show }, site }
function VCK.crafts(REG)
  local C = VCK.CRAFTS
  return {
    jet_nointake = { bp = C.lightjet({ intakes = 0 }), want = { "A1" }, site = "runway" },
    jet_oneintake = { bp = C.lightjet({ intakes = 1 }), want = { "A1" }, site = "runway" },
    jet_upright = { bp = C.lightjet({ upright = true }), want = { "A3" }, site = "runway" },
    jet = { bp = C.lightjet(), want = {}, site = "runway" },
    bike125 = { bp = VCK.FIX.bike125, want = { "V2" }, site = "runway" },
    bike500 = { bp = VCK.FIX.bike500, want = { "V2n" }, site = "runway" },
    rocket_heavy = { bp = C.starter(REG, { tanks = { "tankM", "tankM", "tankM", "tankM" } }), want = { "L" }, site = "pad" },
    rover_tall = { bp = C.rover(REG, { mast = 3, track = 0.8 }), want = { "V3" }, site = "runway" },
  }
end

function VCK.run()
  local BH = enter_vab("vck_enter")
  if not BH then VCK.check("vab", false, "no builder"); return end
  local B = findScript("builder")
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  wait(1.5)
  local REG = (findScript("parts_registry") or {}).REG
  local all = VCK.crafts(REG)
  local list = {}
  for nm in tostring(params.crafts or "jet_nointake,jet_upright,bike125,rocket_heavy"):gmatch("[^,]+") do list[#list + 1] = nm end
  local bc = findScript("builder_camera")
  local ins = findScript("builder_inspector")
  local sb = findScript("builder_statusbar")
  for _, nm in ipairs(list) do
    local c = all[nm]
    if not c then P("VCK unknown craft %s", nm) else
      load_bp(B, "vck_" .. nm, c.bp.parts)
      if B.launchSite and B.launchSite() ~= c.site and B.toggleLaunchSite then B.toggleLaunchSite() end
      B.select({}, "set")
      if ins and ins.setTab then ins.setTab("INSPECT") end
      wait(1.0)
      -- (framed once the parts have landed: a frame on a half-spawned craft
      -- left the jet a speck on the floor)
      if bc and bc.frameCraft then bc.frameCraft() end
      wait(1.5)
      local s = B.stats()
      local L = s.launch or {}
      local seen = {}
      P("VCK CRAFT %s: %d parts, kind %s, site %s, check %.2f ms (craft_check %.2f), block %s", nm, s.parts or -1,
        tostring(L.kind), tostring(B.launchSite and B.launchSite()), L.check and L.check.total_ms or -1,
        L.check and L.check.ms or -1, tostring(L.block))
      for i, r in ipairs(L.rows or {}) do
        seen[r.id] = true
        if r.id:match("^L%d") then seen.L = true end
        P("VCK ROW %s %d [%s %s r%d] %s {%s}", nm, i, r.id, r.sev, r.rank or 2, r.head, table.concat(r.uids or {}, ","))
        if r.text then P("VCK TEXT %s %s", r.id, r.text) end
      end
      if sb and sb.figures then
        for _, f in ipairs(sb.figures(B)) do if f.key == "check" or f.key:match("^a%d") then P("VCK CHIP %s %s = %s (%s)", nm, f.label, f.value, tostring(f.tone)) end end
      end
      P("VCK HINT %s %s", nm, tostring(B.hintText and B.hintText()))
      local hit = #c.want == 0
      for _, id in ipairs(c.want) do if seen[id] then hit = true end end
      VCK.check(nm, hit, "rows %s include %s", (function() local t = {} for _, r in ipairs(L.rows or {}) do t[#t + 1] = r.id end return table.concat(t, " ") end)(),
        table.concat(c.want, "|"))
      VCK.check(nm .. "_ms", (L.check and L.check.total_ms or 0) < 4, "the check cost %.2f ms", L.check and L.check.total_ms or -1)
      VCK.shot(nm .. "_rows")
      -- the pointer on the first row: its parts outlined in the view
      local row = find and find("ChkRow1")
      if row and row.uiRect then
        local x, y, w, h = row:uiRect()
        if x and w and w > 0 then
          mouse_to(x + w * 0.5, y + h * 0.5)
          wait(0.5)
          P("VCK HOVER %s at %.0f,%.0f (%.0fx%.0f)", nm, x + w * 0.5, y + h * 0.5, w, h)
          VCK.shot(nm .. "_hover")
          mouse_to(10, 10)
          wait(0.2)
        end
      else
        P("VCK no ChkRow1 for %s", nm)
      end
    end
  end
  P("VCK RESULT: %s (%d failed check(s))", VCK.fails == 0 and "PASS" or "FAIL", VCK.fails)
end
