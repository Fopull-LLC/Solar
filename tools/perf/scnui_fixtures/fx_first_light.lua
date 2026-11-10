-- scnuishots.sh fixture (never shipped): see fx_two_rooms.lua.
return {
  id = "fx_first_light", title = "First Light", v = 1, order = 1,
  teaches = { "vab", "staging", "orbit", "recovery" },
  blurb = "A two-stage rocket on the pad and a Pilot who has never flown it. Get to orbit, come home, and recover the capsule.",
  brief = { "Reyes, the Kestrel II is on the pad and fuelled.", "Orbit, one revolution, then bring it down near the base." },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  start = { mode = "scenario", funds = 20000 },
  steps = {
    { id = "launch", text = "Launch.", goals = {} }, { id = "air", text = "Clear 70 % of the air.", goals = {} },
    { id = "orbit", text = "Raise the periapsis above the air.", goals = {} }, { id = "home", text = "Land and RECOVER.", goals = {} },
  },
  score = { par = 360 },
  debrief = { gold = "Clean.", silver = "Round and home.", bronze = "Home.", fail = "The Kestrel is gone." },
}
