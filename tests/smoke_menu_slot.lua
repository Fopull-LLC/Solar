-- SMOKE: the main menu's save card fits the agency's name between its emblem
-- and CONTINUE (scripts/menu_slot.lua fitName) — QA 2026-10-26: the default
-- "Solar Exploration Agency" ran up against CONTINUE at size 18, and a
-- longer name ran under it.
--
--   luajit solar/tests/smoke_menu_slot.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end

assert(loadfile("solar/scripts/menu_slot.lua"))()

local function width(txt, size)
  local n = utf8 and utf8.len and utf8.len(txt) or #txt
  if txt:sub(-3) == "…" then n = n - 2 end   -- (luajit counts the ellipsis as 3 bytes)
  return n * CHAR_W * size
end

local t, s, st = fitName("Kestrel")
check(t == "Kestrel" and s == NAME_SIZE and st == "menu/slotName", "a short name keeps the full size and the base style")
t, s, st = fitName("Solar Exploration Agency")
check(t == "Solar Exploration Agency" and s < NAME_SIZE and width(t, s) <= NAME_W and st == "menu/slotName" .. s,
  "the default name steps down to a size that fits (" .. s .. ", " .. tostring(st) .. ")")
t, s = fitName(string.rep("W", 32))
check(t:sub(-3) ~= "…" and width(t, s) <= NAME_W, "a 32-letter name (the new-save field's limit) fits whole, at " .. s)
t, s = fitName(string.rep("W", 48))
check(s == SIZE_MIN and t:sub(-3) == "…" and width(t, s) <= NAME_W, "a longer one is cut with an ellipsis at the smallest size: " .. t)
t, s = fitName("")
check(t == "" and s == NAME_SIZE, "an empty name is left alone")
-- every style the card can ask for is in the style sheet
local sheet = io.open("solar/ui/solar.uistyle.ron"):read("*a")
for _, size in ipairs(SIZES) do
  local name = size == 18 and "menu/slotName" or ("menu/slotName" .. size)
  check(sheet:find('"' .. name .. '"', 1, true) ~= nil, "the style " .. name .. " exists")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_menu_slot OK — %d checks", passed))
