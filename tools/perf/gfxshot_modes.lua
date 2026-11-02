-- ── gfxshots (tools/perf/gfxshot.sh): the Graphics tab, and what each preset costs ──
-- mode "gfxshots": a fresh save; on foot at the base:
--   1 the pause menu's SETTINGS ▸ Graphics, pictures at the top of the list,
--     scrolled half way and to the end; one option changed (Custom), a picture
--   2 every preset (Low, Medium, High, Ultra) in turn: 6 s settled, then 8 s
--     measured (frame p50/p95, the GPU total and its passes), a picture of
--     the world; then each single option of Ultra switched OFF against Ultra
--     (param `gfx_ab` 1 for that sweep): the GPU ms each one is worth here
-- Pictures: $WORK/proj/save/user/gfxshots/*.png (1920×1080 when the window is).
local GS_DIR = "user://gfxshots/"
local function gs_shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1920, h = 1080, ui = true, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes(GS_DIR .. nm .. ".png", bytes); P("GS SHOT %s", nm) else P("GS SHOT %s failed %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 8, "shot " .. nm) else P("GS SHOT %s: capture refused", nm) end
end
local function gs_measure(tag, secs)
  local name = "gs_" .. tag
  sc_begin(name)
  local g, gn, passes = 0, 0, {}
  local t0 = time
  while time - t0 < secs do
    yield()
    local ok, gg = pcall(perf.gpu)
    if ok and gg and gg.total then
      g, gn = g + gg.total, gn + 1
      for _, ps in ipairs(gg.passes or {}) do passes[ps.name] = (passes[ps.name] or 0) + ps.ms end
    end
  end
  local r = RECS[name]
  local st = stats(r.dts)
  sc_end(name)
  P("GS %s: frame p50 %.1f p95 %.1f mean %.1f | gpu %.2f ms: %s | scale %.2f", tag, st.p50, st.p95, st.mean,
    gn > 0 and g / gn or -1, fmtk(topk(passes, 6, math.max(gn, 1))), app.renderScale and app.renderScale() or -1)
  return st, gn > 0 and g / gn or -1
end
local function run_gfxshots()
  wait_ready(120)
  local st = findScript("settings")
  local pm = findScript("pause_menu")
  if not (st and pm) then P("GS no settings/pause_menu"); return end
  -- stand at the base looking out over the ground
  wait(4)
  -- 1. the screen
  if pm.openMenu then pm.openMenu() else tap("escape") end
  wait(0.5)
  pm.showPage("settings")
  st.showTab("graphics")
  wait(1.0)
  gs_shot("tab_top")
  st.gfxScrollTo = 380; wait(0.6); gs_shot("tab_mid")
  st.gfxScrollTo = 1150; wait(0.6); gs_shot("tab_end")
  st.gfxScrollTo = 0
  st.set("gfx_shadow_distance", 400)
  st.set("gfx_contact_shadows", true)
  wait(0.6)
  gs_shot("tab_custom")
  st.showTab("display"); wait(0.6); gs_shot("tab_display")
  st.set("gfx_level", "Medium")
  st.showTab("graphics")
  if pm.close then pm.close() else tap("escape") end
  wait(1.0)
  -- 2. the presets
  local rows = {}
  for _, lv in ipairs({ "Low", "Medium", "High", "Ultra" }) do
    st.set("gfx_level", lv)
    wait(6)
    local s, g = gs_measure(lv, 8)
    rows[#rows + 1] = string.format("%s p50 %.1f p95 %.1f gpu %.2f", lv, s.p50, s.p95, g)
    gs_shot("world_" .. lv)
  end
  P("GS PRESETS: %s", table.concat(rows, " | "))
  if (tonumber(params.gfx_ab) or 0) > 0 then
    st.set("gfx_level", "Ultra"); wait(4)
    local _, base = gs_measure("ultra_ref", 6)
    local offs = { { "volumetric", false }, { "shafts", false }, { "fog_quality", 8 }, { "shadows", false },
                   { "contact_shadows", false }, { "reflections", false }, { "ao", 0.0 }, { "dof", false },
                   { "flare", false }, { "bloom", false }, { "antialias", "Off" }, { "render_scale", 0.75 } }
    local out = {}
    for _, o in ipairs(offs) do
      st.set("gfx_level", "Ultra")
      st.set("gfx_" .. o[1], o[2])
      if o[1] == "flare" then st.set("lens_flare", o[2]) end
      if o[1] == "dof" then st.set("far_blur", o[2]) end
      if o[1] == "render_scale" then st.set("render_scale", o[2]) end
      wait(3)
      local _, g = gs_measure("ab_" .. o[1], 5)
      out[#out + 1] = string.format("%s %+.2f", o[1], g - base)
    end
    st.set("gfx_level", "Medium")
    P("GS AB (gpu ms vs Ultra %.2f): %s", base, table.concat(out, ", "))
  end
end
