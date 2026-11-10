-- scnuishots.sh fixture (never shipped): see fx_two_rooms.lua.
return {
  id = "fx_flag_day", title = "Flag Day", v = 1, order = 2, requires = "fx_first_light",
  teaches = { "moon", "eva", "flags" },
  blurb = "A lander in low orbit of the home moon with a Pilot and a Scientist aboard. Put it down by the mark and plant the flag.",
  brief = { "Reyes, Adeyemi: you are two hundred kilometres over the moon.", "Land by the mark, plant the flag, bag a sample." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  steps = { { id = "deorbit", text = "Deorbit.", goals = {} }, { id = "land", text = "Land within 500 m of the mark.", goals = {} } },
  score = { par = 540 },
}
