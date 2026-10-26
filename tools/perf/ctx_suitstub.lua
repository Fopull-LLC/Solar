-- SUIT STUB (scratch only, tools/perf/ctxshot.sh): stands in for the EVA-suit
-- work's helmet API until it lands, so the context menu's helmet row can be
-- driven end to end. setHelmet(on) → ok, why; helmetOn(); helmetRefusal(want).
-- The real rule (breathable air, water) is the suit's; this one only refuses
-- with the head under water.
local on = true
function helmetOn() return on end
function helmetRefusal(want)
  local pw = findScript("planet_walker")
  if not want and pw and pw.headUnder then return "not with your head under water" end
  return nil
end
function setHelmet(want)
  local why = helmetRefusal(want)
  if why then return false, why end
  on = want and true or false
  log("suit stub: helmet " .. (on and "on" or "off"))
  return true
end
