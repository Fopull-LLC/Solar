-- BUILDER_AERO — the aircraft package of the Vehicle Assembly (WP4, docs/builder-design.md §7.2).
--
-- Will hold: CoM/CoT/CoL overlays, deflection preview, wing placement rules (§7.2).
-- Has today: the CRT strip's MARGIN and STALL figures (§7.2 item 4), read off the
-- craft check (scripts/craft_check.lua: aero.staticMargin and aero.stallSpeed at
-- the pad's air, cached per edit in builder.stats().launch.check). The gear and
-- jet checks (§7.2 items 6-7) are craft_check's rows A1, A6, A7.
--
-- A PANEL script on the "BuilderAero" host node of scenes/builder.ron (a hidden
-- child of Builder UI). It talks to the builder only through the public API
-- at the top of scripts/builder.lua (findScript("builder")).

local builder_ref = nil
local function builder()
  if not builder_ref or builder_ref.valid == false then builder_ref = findScript and findScript("builder") or nil end
  return builder_ref
end

-- { { label, value, tone } } for builder_statusbar: MARGIN in mean chords
-- (caution yellow under +0.03, red at or under 0) and STALL ≈ v, for a craft
-- with lifting surfaces the flight flies as a plane. Nothing otherwise.
function statusFigures()
  local B = builder()
  local s = B and B.stats and B.stats() or nil
  local chk = s and s.launch and s.launch.check
  if not chk then return {} end
  local out = {}
  if chk.margin then
    local m = chk.margin
    out[#out + 1] = { label = "MARGIN", value = string.format("%+.2f MAC", m),
                      tone = (m <= 0) and "danger" or (m < 0.03 and "warn" or nil) }
  end
  if chk.stall and chk.stall.v then
    out[#out + 1] = { label = "STALL", value = string.format("≈ %.0f m/s", chk.stall.v) }
  end
  return out
end
