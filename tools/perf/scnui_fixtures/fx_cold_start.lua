-- scnuishots.sh fixture (never shipped): a long title and a locked row
-- (needs gold on Two Rooms), to see both fit. See fx_two_rooms.lua.
return {
  id = "fx_cold_start", title = "Cold Start and Scram", v = 1, order = 8,
  requires = { id = "fx_two_rooms", medal = "gold" },
  teaches = { "reactor", "pumps", "rods", "scram", "dose" },
  blurb = "A built reactor hall, cold, rods in, and an Engineer at the console. Bring it to power, then keep it alive when a pump fails.",
  brief = { "Okafor, the hall is cold." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  steps = { { id = "pumps", text = "Start the pumps.", goals = {} } },
  score = { par = 2400 },
}
