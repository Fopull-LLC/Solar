# Card 0410 repro: landed colliding particles

- `scenes/rest0.ron` / `rest4900000.ron` + `scripts/restprobe.lua`: 200 particles (vfx/Rest200, bounce 0 friction 1) dropped on a static floor at y=0 / y=4.9e6. Prints `REST particles mean ... ms`.
- `scenes/planet_rest.ron` + `scripts/planet_rest.lua`: the planet case. Use a scratch copy of Solar with project.ron `entry_scene` = scenes/planet_rest.ron and real empty save/ and saves/ dirs. Starts slot9 with seed 1911564384, waits 70 s at the base, drops Rest200 beside the crew, and prints `PLANETREST before / falling / landed` particle-bucket means.

Result on 0.117.0-rc2 (2026-10-20, crew standing still, terrain settled):
before 0.013 ms, falling 0.249 ms, landed 3–14 s 0.014 ms (200 live). Resting works in this case.
The earlier 0.19–0.21 ms "landed" figure was measured while other things were going on (camera framing the crew, terrain/flora still streaming), so a level change near the cloud (terrain re-mesh / `level_edits`) is the likely trigger.
