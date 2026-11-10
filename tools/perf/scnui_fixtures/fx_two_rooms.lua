-- scnuishots.sh fixture (never shipped): a scenario table in the PLAN §1.3
-- shape, so the menu page and the panels have something real-sized to show
-- before the content agents' scenarios land. The world is the bench seed (a
-- quick Earth-like start), not Haldane.
return {
  id = "fx_two_rooms", title = "Two Rooms", v = 1, order = 3,
  teaches = { "buildkit", "rooms", "air", "airlock", "basegrid" },
  blurb = "An Engineer, a pad plate and a crate of walls on a world with no air. Build two sealed rooms and an airlock between you and the vacuum.",
  brief = {
    "Okafor, you are on the night side of Haldane with eleven hours of suit air and a crate of structure.",
    "We need a shelter we can take a helmet off in. Two rooms, one airlock, power to the scrubber.",
  },
  world = { seed = 1911564384, scale = 4, names = 2, air = "earth" },
  start = { mode = "scenario", funds = 9000, safety = "rescue" },
  steps = {
    { id = "shell", text = "Close the shell: walls and a roof on the pad plate until ROOMS shows one sealed room.", goals = {} },
    { id = "split", text = "Divide it into two rooms with a wall and a Door Wall.", goals = {} },
    { id = "lock", text = "Make the outer door an Airlock Wall, with the small room as the lock.", goals = {} },
    { id = "power", text = "Power it: two Solar Arrays, a Battery Bank, a cable to the shelter.", goals = {} },
    { id = "air", text = "An Oxygen Generator and a CO2 Scrubber inside. Hold the inner room at 1 atm.", goals = {} },
    { id = "cycle", text = "Cycle the airlock and go in.", goals = {} },
    { id = "helmet", text = "Take the helmet off.", goals = {} },
  },
  score = { par = 1200 },
  after = "freeplay",
  debrief = { gold = "Textbook. Ops is framing the ROOMS overlay.", silver = "Sealed and breathing. The budget went on the roof.",
              bronze = "You are inside and the air holds. We will talk about the cable run.", fail = "Haldane keeps its first shelter." },
}
