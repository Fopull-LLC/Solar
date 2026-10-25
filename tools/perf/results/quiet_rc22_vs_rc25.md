# Quiet benchmark, rc22 vs rc25 (2026-10-25 18:04–18:21, load 3–8, no other engine or build running)

Both engines, all five modes, tools/perf/bench.sh on fresh saves. Rover drive repeated twice per engine, alternating.

## 0.117.0-rc22

| scenario | load (1/5/15) | frames | p50 | p95 | p99 | max | >33 ms | >100 ms | hitches | work p50/p95/max | script | physics | terrain | render | gpu/vsync | untimed | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a_load (base) | 5.55, 7.37, 9.75 | 1663 | 8.0 | 27.5 | 32.3 | 327 | 12 | 4 | 6 | 7.7/18.1/366 | 4.2 | 0.1 | 0.4 | 3.1 | 1.4 | 1.6 | 0.0 |
| a_onfoot30 (base) | 5.55, 7.37, 9.75 | 1147 | 25.9 | 32.6 | 46.9 | 52 | 41 | 0 | 2 | 13.0/16.4/35 | 4.2 | 0.9 | 0.9 | 5.5 | 12.9 | 1.8 | 0.0 |
| a_after30_until_ready (base) | 5.55, 7.37, 9.75 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| b_dig_meadow (base) | 5.55, 7.37, 9.75 | 1116 | 19.9 | 20.9 | 23.6 | 41 | 1 | 0 | 0 | 11.8/13.7/35 | 3.7 | 0.4 | 0.6 | 5.6 | 7.8 | 1.7 | 0.0 |
| b_dig_rock (base) | 5.55, 7.37, 9.75 | 1113 | 19.9 | 21.8 | 23.6 | 37 | 1 | 0 | 0 | 11.7/14.0/32 | 3.8 | 0.2 | 0.6 | 5.7 | 8.0 | 1.7 | 0.0 |
| f_map_onfoot (base) | 5.55, 7.37, 9.75 | 1903 | 6.6 | 7.8 | 21.7 | 29 | 0 | 0 | 0 | 6.4/7.6/18 | 3.0 | 0.0 | 0.2 | 2.2 | 0.4 | 1.3 | 0.0 |
| a_load (rocket) | 3.58, 6.22, 9.04 | 1674 | 9.0 | 34.7 | 38.9 | 129 | 134 | 2 | 6 | 8.8/20.4/116 | 4.8 | 0.1 | 0.8 | 3.8 | 3.8 | 1.9 | 0.0 |
| launch_load (rocket) | 3.58, 6.22, 9.04 | 231 | 16.9 | 51.5 | 82.7 | 106 | 29 | 2 | 16 | 14.9/52.0/111 | 8.0 | 0.2 | 5.3 | 3.9 | 1.2 | 2.4 | 0.0 |
| launch_regrade (rocket) | 3.58, 6.22, 9.04 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| c_ascent (rocket) | 3.58, 6.22, 9.04 | 3631 | 9.7 | 23.1 | 31.9 | 49 | 25 | 0 | 0 | 9.6/16.4/40 | 3.4 | 1.1 | 0.6 | 3.4 | 0.9 | 1.7 | 0.0 |
| c_throttle_change (rocket) | 3.58, 6.22, 9.04 | 882 | 10.7 | 25.9 | 29.5 | 32 | 0 | 0 | 0 | 10.4/17.1/22 | 3.4 | 1.3 | 0.6 | 3.9 | 2.2 | 1.9 | 0.0 |
| c_orbit_coast (rocket) | 3.58, 6.22, 9.04 | 1129 | 8.4 | 13.5 | 16.3 | 19 | 0 | 0 | 0 | 8.1/13.7/19 | 3.2 | 0.8 | 0.5 | 2.4 | 0.2 | 1.7 | 0.0 |
| f_map_flight (rocket) | 3.58, 6.22, 9.04 | 1712 | 7.8 | 9.7 | 11.1 | 15 | 0 | 0 | 0 | 7.6/9.4/13 | 3.2 | 0.5 | 0.2 | 2.4 | 0.2 | 1.4 | 0.0 |
| a_onfoot30 (rocket) | 3.58, 6.22, 9.04 | 128 | 31.3 | 35.6 | 36.7 | 51 | 11 | 0 | 0 | 12.8/18.3/33 | 4.8 | 0.5 | 0.9 | 5.1 | 18.0 | 2.1 | 0.0 |
| a_load (plane) | 5.11, 6.24, 8.76 | 1364 | 8.6 | 30.7 | 35.8 | 134 | 32 | 4 | 7 | 8.3/21.1/126 | 5.2 | 0.2 | 0.6 | 3.9 | 2.0 | 2.1 | 0.0 |
| launch_load (plane) | 5.11, 6.24, 8.76 | 221 | 19.5 | 57.2 | 94.2 | 116 | 47 | 2 | 28 | 18.7/58.7/107 | 9.9 | 0.3 | 6.0 | 4.7 | 0.7 | 3.2 | 0.0 |
| launch_regrade (plane) | 5.11, 6.24, 8.76 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| d_takeoff (plane) | 5.11, 6.24, 8.76 | 374 | 26.6 | 50.3 | 109.3 | 194 | 77 | 4 | 20 | 25.9/50.6/198 | 7.7 | 11.9 | 1.1 | 5.0 | 0.3 | 3.3 | 0.0 |
| d_low_flight (plane) | 5.11, 6.24, 8.76 | 2088 | 19.9 | 34.2 | 45.6 | 55 | 126 | 0 | 6 | 17.1/27.1/45 | 5.6 | 3.9 | 1.3 | 5.1 | 3.3 | 2.4 | 0.0 |
| a_onfoot30 (plane) | 5.11, 6.24, 8.76 | 147 | 27.3 | 31.7 | 32.9 | 35 | 1 | 0 | 0 | 13.3/18.3/22 | 4.8 | 1.1 | 1.2 | 4.8 | 13.5 | 1.9 | 0.0 |
| a_load (rover) | 7.11, 6.68, 8.70 | 1424 | 9.4 | 25.9 | 30.1 | 138 | 10 | 3 | 7 | 9.2/19.8/127 | 5.1 | 0.2 | 0.7 | 4.0 | 1.8 | 2.1 | 0.0 |
| launch_load (rover) | 7.11, 6.68, 8.70 | 189 | 19.7 | 65.0 | 86.2 | 115 | 49 | 1 | 22 | 19.1/60.3/113 | 10.8 | 0.3 | 6.6 | 4.8 | 0.6 | 3.2 | 0.0 |
| launch_regrade (rover) | 7.11, 6.68, 8.70 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| e_rover (rover) | 7.11, 6.68, 8.70 | 1882 | 24.2 | 28.5 | 31.5 | 36 | 7 | 0 | 0 | 17.0/23.5/35 | 5.1 | 1.8 | 1.4 | 6.5 | 6.2 | 3.0 | 0.0 |
| a_onfoot30 (rover) | 7.11, 6.68, 8.70 | 179 | 22.4 | 26.7 | 27.1 | 29 | 0 | 0 | 0 | 12.8/18.3/24 | 4.8 | 0.9 | 1.0 | 4.9 | 8.9 | 1.9 | 0.0 |
| a_load (builder) | 7.48, 7.32, 8.79 | 1458 | 12.3 | 29.9 | 36.0 | 133 | 28 | 2 | 8 | 11.7/20.5/122 | 5.2 | 0.2 | 0.8 | 4.0 | 1.9 | 2.2 | 0.0 |
| g_enter (builder) | 7.48, 7.32, 8.79 | 4 | 27.2 | 51.0 | 51.0 | 51 | 1 | 0 | 1 | 11.7/55.4/55 | 11.0 | 0.8 | 0.9 | 5.8 | 10.7 | 4.1 | 0.0 |
| g_load_300 (builder) | 7.48, 7.32, 8.79 | 4 | 27.0 | 36.1 | 36.1 | 36 | 1 | 0 | 0 | 19.8/35.2/35 | 8.2 | 0.9 | 0.7 | 8.0 | 4.3 | 6.2 | 0.0 |
| g_idle_300 (builder) | 7.48, 7.32, 8.79 | 132 | 30.1 | 32.5 | 34.6 | 35 | 5 | 0 | 0 | 18.2/22.5/33 | 4.2 | 0.9 | 0.8 | 8.3 | 11.4 | 4.7 | 0.0 |
| g_hand_300 (builder) | 7.48, 7.32, 8.79 | 134 | 30.2 | 32.5 | 34.5 | 35 | 2 | 0 | 0 | 17.7/21.2/31 | 3.5 | 0.8 | 0.8 | 8.3 | 12.2 | 4.6 | 0.0 |
| g_load_1000 (builder) | 7.48, 7.32, 8.79 | 16 | 31.3 | 54.0 | 54.0 | 54 | 4 | 0 | 1 | 22.9/52.4/52 | 7.5 | 0.9 | 0.9 | 9.4 | 6.5 | 6.0 | 0.0 |
| g_idle_1000 (builder) | 7.48, 7.32, 8.79 | 122 | 32.7 | 37.1 | 39.5 | 40 | 35 | 0 | 0 | 23.0/29.7/41 | 5.6 | 0.9 | 0.9 | 10.9 | 8.8 | 5.6 | 0.0 |
| g_hand_1000 (builder) | 7.48, 7.32, 8.79 | 124 | 32.7 | 35.9 | 37.5 | 39 | 37 | 0 | 0 | 21.3/26.0/38 | 3.8 | 0.9 | 0.9 | 10.9 | 10.8 | 5.5 | 0.0 |
| g_load_3000 (builder) | 7.48, 7.32, 8.79 | 49 | 35.4 | 39.9 | 132.0 | 132 | 30 | 1 | 1 | 30.3/39.6/123 | 8.9 | 1.0 | 1.0 | 13.2 | 4.3 | 7.4 | 0.0 |
| g_idle_3000 (builder) | 7.48, 7.32, 8.79 | 111 | 35.3 | 45.9 | 57.6 | 62 | 99 | 0 | 3 | 34.8/46.5/63 | 7.8 | 1.0 | 1.1 | 17.6 | 0.5 | 8.2 | 0.0 |
| g_hand_3000 (builder) | 7.48, 7.32, 8.79 | 115 | 35.5 | 39.7 | 44.6 | 47 | 100 | 0 | 0 | 31.6/35.7/47 | 4.6 | 1.0 | 1.1 | 17.5 | 3.4 | 8.1 | 0.0 |
| g_load_craft1002 (builder) | 7.48, 7.32, 8.79 | 16 | 29.2 | 119.3 | 119.3 | 119 | 1 | 1 | 2 | 23.1/98.4/98 | 9.8 | 0.9 | 0.9 | 10.5 | 3.6 | 7.6 | 0.0 |
| g_idle_craft (builder) | 7.48, 7.32, 8.79 | 135 | 29.6 | 33.3 | 37.1 | 37 | 6 | 0 | 0 | 22.1/27.6/37 | 4.3 | 0.8 | 0.8 | 11.2 | 6.6 | 5.9 | 0.0 |
| g_launch_rollout (builder) | 7.48, 7.32, 8.79 | 109 | 30.6 | 38.0 | 51.1 | 59 | 17 | 0 | 2 | 25.5/39.5/64 | 9.8 | 0.4 | 1.0 | 10.5 | 4.3 | 5.1 | 0.0 |
| g_launch_pad (builder) | 7.48, 7.32, 8.79 | 249 | 32.1 | 35.0 | 36.8 | 37 | 46 | 0 | 0 | 23.4/27.6/33 | 6.9 | 0.2 | 1.6 | 10.5 | 8.7 | 4.3 | 0.0 |
| g_launch_release (builder) | 7.48, 7.32, 8.79 | 141 | 64.3 | 89.3 | 316.4 | 334 | 141 | 5 | 141 | 64.0/89.2/331 | 18.9 | 38.6 | 1.0 | 10.7 | 0.2 | 4.7 | 0.0 |
| g_launch_settle (builder) | 7.48, 7.32, 8.79 | 304 | 64.2 | 86.3 | 94.2 | 97 | 304 | 0 | 304 | 64.2/86.7/96 | 18.1 | 31.4 | 1.0 | 10.8 | 0.2 | 4.5 | 0.0 |
| a_onfoot30 (builder) | 7.48, 7.32, 8.79 | 132 | 30.4 | 34.3 | 37.8 | 49 | 10 | 0 | 0 | 13.6/19.1/35 | 4.9 | 1.1 | 1.1 | 5.2 | 16.2 | 2.0 | 0.0 |

### Frames over 33 ms: what they were spent on (ms per spike frame)

| scenario | spikes | script | physics | terrain | render | gpu/vsync | untimed | other | top scripts in spikes | top parts |
|---|---|---|---|---|---|---|---|---|---|---|
| a_load (base) | 12 | 43.9 | 1.1 | 9.9 | 18.4 | 3.5 | 6.2 | 0.1 | game_manager 8.3, planet_walker 1.1, flora_field 1.0, perfbench 0.7 | |
| a_onfoot30 (base) | 41 | 4.3 | 1.2 | 0.8 | 5.7 | 24.3 | 1.8 | 0.0 | planet_camera 0.4, perfbench 0.4, tool_belt 0.4, objectives 0.4 | |
| b_dig_meadow (base) | 1 | 3.6 | 0.4 | 0.3 | 5.5 | 8.3 | 1.5 | 0.0 | objectives 0.4, perfbench 0.4, planet_walker 0.3, tool_belt 0.3 | |
| b_dig_rock (base) | 1 | 4.6 | 0.4 | 1.0 | 5.6 | 6.2 | 1.5 | 0.0 | perfbench 0.7, objectives 0.7, tool_belt 0.4, planet_walker 0.3 | |
| a_load (rocket) | 134 | 8.5 | 0.3 | 2.4 | 5.8 | 15.1 | 2.7 | 0.0 | flora_field 2.5, game_manager 0.8, perfbench 0.4, tool_belt 0.4 | |
| launch_load (rocket) | 29 | 12.3 | 0.8 | 32.1 | 3.8 | 0.6 | 2.7 | 0.0 | mineral_field 1.8, base_facilities 1.6, perfbench 0.8, flora_field 0.5 | |
| c_ascent (rocket) | 25 | 10.9 | 3.1 | 2.8 | 7.2 | 5.9 | 4.4 | 0.0 | flora_field 4.1, flight_hud 0.9, vessel_controller 0.9, perfbench 0.7 | |
| a_onfoot30 (rocket) | 11 | 4.7 | 0.5 | 0.4 | 5.1 | 18.8 | 1.9 | 0.0 | flora_field 1.2, perfbench 0.4, tool_belt 0.3, planet_walker 0.3 | |
| a_load (plane) | 32 | 14.7 | 1.8 | 6.0 | 11.1 | 9.2 | 3.8 | 0.0 | game_manager 3.1, flora_field 2.6, climate 0.8, base_facilities 0.8 | |
| launch_load (plane) | 47 | 14.4 | 1.2 | 21.6 | 6.5 | 1.0 | 5.6 | 0.0 | base_facilities 2.0, flight_hud 1.1, climate 1.0, mineral_field 1.0 | |
| d_takeoff (plane) | 77 | 12.8 | 23.7 | 1.3 | 6.1 | 0.3 | 4.8 | 0.0 | flora_field 2.3, vessel_controller 1.7, perfbench 1.2, climate 1.1 | |
| d_low_flight (plane) | 126 | 8.4 | 6.9 | 1.7 | 5.6 | 13.0 | 3.2 | 0.0 | perfbench 1.4, flora_field 1.2, vessel_controller 1.0, flight_hud 0.8 | |
| a_onfoot30 (plane) | 1 | 5.3 | 0.6 | 0.5 | 4.5 | 14.3 | 1.8 | 0.0 | flora_field 1.1, perfbench 0.6, planet_walker 0.6, tool_belt 0.4 | |
| a_load (rover) | 10 | 28.3 | 2.1 | 14.4 | 27.3 | 0.4 | 6.7 | 0.0 | game_manager 9.6, flora_field 1.9, base_facilities 0.9, planet_walker 0.9 | |
| launch_load (rover) | 49 | 18.0 | 0.9 | 21.1 | 6.7 | 0.4 | 5.3 | 0.0 | flora_field 2.3, base_facilities 2.0, climate 1.2, perfbench 1.0 | |
| e_rover (rover) | 7 | 9.1 | 4.3 | 3.3 | 6.0 | 6.7 | 3.2 | 0.0 | flora_field 3.6, vessel_controller 0.7, flight_hud 0.7, base_props 0.5 | |
| a_load (builder) | 28 | 15.3 | 1.1 | 7.8 | 10.9 | 7.5 | 4.4 | 0.0 | game_manager 3.7, flora_field 1.8, base_facilities 1.4, planet_walker 0.7 | |
| g_enter (builder) | 1 | 2.5 | 1.1 | 1.6 | 5.2 | 14.0 | 1.3 | 0.0 | perfbench 0.3, flora_field 0.1, tool_belt 0.1, far_bodies 0.1 | |
| g_load_300 (builder) | 1 | 18.4 | 1.1 | 0.3 | 7.6 | 0.2 | 7.9 | 0.0 | perfbench 5.6, builder 5.4, builder_camera 2.3, builder_toolbar 0.5 | |
| g_idle_300 (builder) | 5 | 4.4 | 0.9 | 0.5 | 9.6 | 9.9 | 5.7 | 0.0 | builder 1.2, perfbench 0.4, flora_field 0.2, far_bodies 0.1 | |
| g_hand_300 (builder) | 2 | 3.1 | 0.7 | 0.3 | 8.2 | 14.2 | 4.0 | 0.0 | perfbench 0.3, builder 0.2, flora_field 0.1, far_bodies 0.1 | |
| g_load_1000 (builder) | 4 | 12.2 | 0.8 | 0.5 | 9.5 | 7.8 | 6.3 | 0.0 | perfbench 4.2, builder 3.5, builder_camera 0.8, builder_toolbar 0.2 | |
| g_idle_1000 (builder) | 35 | 5.8 | 0.9 | 0.5 | 11.1 | 9.1 | 6.0 | 0.0 | builder 2.1, perfbench 0.4, flora_field 0.2, catalog_panel 0.2 | |
| g_hand_1000 (builder) | 37 | 4.1 | 0.9 | 0.5 | 10.8 | 10.9 | 6.0 | 0.0 | perfbench 0.5, flora_field 0.3, catalog_panel 0.2, builder 0.2 | |
| g_load_3000 (builder) | 30 | 9.8 | 1.0 | 1.0 | 15.0 | 4.4 | 8.2 | 0.0 | builder 2.7, perfbench 2.1, builder_camera 0.9, builder_toolbar 0.3 | |
| g_idle_3000 (builder) | 99 | 8.1 | 1.1 | 1.1 | 17.7 | 0.5 | 8.3 | 0.0 | builder 3.8, perfbench 0.5, builder_toolbar 0.3, flora_field 0.3 | |
| g_hand_3000 (builder) | 100 | 4.6 | 1.0 | 1.0 | 17.4 | 3.8 | 8.0 | 0.0 | perfbench 0.4, builder 0.4, builder_toolbar 0.3, flora_field 0.3 | |
| g_load_craft1002 (builder) | 1 | 62.6 | 1.4 | 1.6 | 12.4 | 0.3 | 20.5 | 0.0 | builder 28.0, perfbench 22.3, builder_camera 4.3, builder_toolbar 1.7 | |
| g_idle_craft (builder) | 6 | 5.5 | 0.9 | 0.9 | 12.9 | 3.2 | 10.9 | 0.0 | catalog_panel 1.2, builder 0.6, builder_camera 0.4, perfbench 0.4 | |
| g_launch_rollout (builder) | 17 | 17.4 | 0.4 | 1.3 | 10.0 | 2.0 | 6.9 | 0.0 | vessel_controller 3.9, flora_field 2.4, climate 1.2, perfbench 1.2 | |
| g_launch_pad (builder) | 46 | 7.3 | 0.2 | 1.7 | 10.6 | 8.9 | 4.2 | 0.0 | vessel_controller 2.1, planet_camera 0.9, flight_hud 0.8, flora_field 0.7 | |
| g_launch_release (builder) | 141 | 18.9 | 38.6 | 1.0 | 10.7 | 0.2 | 4.7 | 0.0 | flight_ops 7.4, vessel_controller 6.0, planet_camera 1.0, flight_hud 0.8 | |
| g_launch_settle (builder) | 304 | 18.1 | 31.4 | 1.0 | 10.8 | 0.2 | 4.5 | 0.0 | flight_ops 7.5, vessel_controller 5.3, planet_camera 0.9, flight_hud 0.8 | |
| a_onfoot30 (builder) | 10 | 4.7 | 1.1 | 0.6 | 5.1 | 17.0 | 1.9 | 0.0 | flora_field 1.1, perfbench 0.4, planet_walker 0.3, tool_belt 0.3 | |

### Top scripts (mean ms/frame, worst frame ms)

- **a_load** (base): perfbench 0.50 (max 4), flora_field 0.34 (max 15), game_manager 0.23 (max 95), planet_camera 0.22 (max 1), dock_row 0.13 (max 2), far_bodies 0.12 (max 6), base_facilities 0.12 (max 14), tool_belt 0.12 (max 2)
- **a_onfoot30** (base): flora_field 0.51 (max 3), perfbench 0.36 (max 2), planet_camera 0.35 (max 1), tool_belt 0.35 (max 3), objectives 0.32 (max 1), planet_walker 0.29 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **a_after30_until_ready** (base): 
- **b_dig_meadow** (base): objectives 0.35 (max 1), perfbench 0.35 (max 1), tool_belt 0.32 (max 1), planet_walker 0.31 (max 1), planet_camera 0.29 (max 1), flora_field 0.19 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **b_dig_rock** (base): objectives 0.36 (max 1), perfbench 0.35 (max 1), tool_belt 0.32 (max 1), planet_walker 0.32 (max 1), planet_camera 0.29 (max 1), flora_field 0.19 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **f_map_onfoot** (base): orbit_map 0.57 (max 5), perfbench 0.30 (max 1), planet_walker 0.29 (max 1), flora_field 0.13 (max 1), far_bodies 0.09 (max 1), dock_row 0.08 (max 0), tool_belt 0.07 (max 1), weather 0.06 (max 0)
- **a_load** (rocket): flora_field 0.56 (max 21), perfbench 0.52 (max 4), far_bodies 0.27 (max 10), planet_camera 0.24 (max 4), game_manager 0.23 (max 91), tool_belt 0.17 (max 2), dock_row 0.12 (max 2), planet_walker 0.12 (max 7)
- **launch_load** (rocket): climate 0.82 (max 3), flora_field 0.70 (max 10), perfbench 0.67 (max 4), base_facilities 0.67 (max 28), far_bodies 0.45 (max 6), planet_camera 0.30 (max 3), mineral_field 0.28 (max 40), flight_hud 0.21 (max 1)
- **launch_regrade** (rocket): 
- **c_ascent** (rocket): perfbench 0.37 (max 3), vessel_controller 0.25 (max 2), flora_field 0.25 (max 14), planet_camera 0.23 (max 2), flight_hud 0.21 (max 3), dock_row 0.12 (max 0), flight_ops 0.10 (max 3), far_bodies 0.09 (max 3)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.06, vessel_controller.groupKeysTick 0.03, vessel_controller.safetyTick 0.03, vessel_controller.waterTick 0.02, vessel_controller.aeroTick 0.02, vessel_controller.stressTick 0.02, flight_ops.survey 0.01, planet_camera.cinematic_tick 0.01
- **c_throttle_change** (rocket): perfbench 0.38 (max 2), vessel_controller 0.30 (max 1), flight_hud 0.23 (max 1), planet_camera 0.23 (max 1), flora_field 0.16 (max 3), dock_row 0.12 (max 0), flight_ops 0.11 (max 1), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.23, vessel_controller.groupKeysTick 0.13, vessel_controller.safetyTick 0.10, vessel_controller.waterTick 0.09, vessel_controller.aeroTick 0.07, vessel_controller.stressTick 0.07, flight_ops.survey 0.06, planet_camera.cinematic_tick 0.04
- **c_orbit_coast** (rocket): perfbench 0.37 (max 1), planet_camera 0.21 (max 1), vessel_controller 0.20 (max 1), flight_hud 0.19 (max 1), flora_field 0.15 (max 0), dock_row 0.13 (max 0), flight_ops 0.10 (max 0), far_bodies 0.10 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.06, vessel_controller.groupKeysTick 0.03, vessel_controller.safetyTick 0.02, vessel_controller.waterTick 0.02, flight_ops.survey 0.02, vessel_controller.stressTick 0.01, planet_camera.cinematic_tick 0.01, vessel_controller.controlsCard 0.01
- **f_map_flight** (rocket): orbit_map 0.64 (max 5), perfbench 0.39 (max 1), dock_row 0.14 (max 0), vessel_controller 0.14 (max 1), flight_ops 0.09 (max 0), far_bodies 0.09 (max 1), flora_field 0.08 (max 0), weather 0.06 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.safetyTick 0.02, flight_ops.survey 0.01, vessel_controller.groupKeysTick 0.01, vessel_controller.stressTick 0.01, planet_camera.cinematic_tick 0.01, vessel_controller.waterTick 0.01, planet_camera.chase_clip 0.00, vessel_controller.peripherals 0.00
- **a_onfoot30** (rocket): flora_field 1.18 (max 3), perfbench 0.37 (max 2), tool_belt 0.35 (max 1), planet_walker 0.32 (max 1), planet_camera 0.29 (max 1), objectives 0.23 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 2.22, vessel_controller.groupKeysTick 1.43, vessel_controller.safetyTick 1.23, vessel_controller.waterTick 0.90, flight_ops.survey 0.76, vessel_controller.stressTick 0.72, vessel_controller.aeroTick 0.64, planet_camera.cinematic_tick 0.50
- **a_load** (plane): perfbench 0.63 (max 5), flora_field 0.51 (max 22), game_manager 0.27 (max 94), planet_camera 0.25 (max 3), far_bodies 0.18 (max 14), tool_belt 0.16 (max 6), base_facilities 0.15 (max 15), dock_row 0.14 (max 2)
- **launch_load** (plane): climate 1.20 (max 4), base_facilities 0.82 (max 30), far_bodies 0.80 (max 12), perfbench 0.79 (max 4), planet_camera 0.44 (max 9), flight_hud 0.38 (max 4), flora_field 0.37 (max 11), mineral_field 0.29 (max 15)
- **launch_regrade** (plane): 
- **d_takeoff** (plane): flora_field 1.56 (max 10), vessel_controller 0.93 (max 5), perfbench 0.75 (max 11), flight_hud 0.56 (max 3), planet_camera 0.48 (max 3), climate 0.37 (max 5), flight_ops 0.24 (max 3), dock_row 0.14 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.25, vessel_controller.r2Tick 0.13, vessel_controller.aeroTick 0.12, vessel_controller.groupKeysTick 0.11, vessel_controller.safetyTick 0.09, vessel_controller.waterTick 0.07, vessel_controller.stressTick 0.07, vessel_controller.controlsCard 0.06
- **d_low_flight** (plane): perfbench 0.99 (max 22), vessel_controller 0.55 (max 2), flight_hud 0.45 (max 2), flora_field 0.40 (max 8), planet_camera 0.28 (max 1), climate 0.27 (max 4), flight_ops 0.21 (max 2), dock_row 0.14 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.aeroTick 0.09, vessel_controller.groupKeysTick 0.07, planet_camera.chase_clip 0.07, vessel_controller.safetyTick 0.06, vessel_controller.waterTick 0.05, vessel_controller.controlsCard 0.05, vessel_controller.stressTick 0.05, vessel_controller.groupStrip 0.03
- **a_onfoot30** (plane): flora_field 1.24 (max 2), perfbench 0.37 (max 2), tool_belt 0.35 (max 1), planet_walker 0.33 (max 1), planet_camera 0.28 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 1.64, vessel_controller.aeroTick 1.53, vessel_controller.groupKeysTick 1.31, vessel_controller.safetyTick 1.07, vessel_controller.waterTick 0.87, vessel_controller.stressTick 0.85, vessel_controller.controlsCard 0.84, vessel_controller.groupStrip 0.56
- **a_load** (rover): perfbench 0.64 (max 4), flora_field 0.46 (max 16), game_manager 0.25 (max 93), planet_camera 0.25 (max 4), far_bodies 0.18 (max 13), tool_belt 0.15 (max 2), dock_row 0.14 (max 3), weather 0.14 (max 5)
- **launch_load** (rover): base_facilities 0.95 (max 27), perfbench 0.91 (max 4), flora_field 0.88 (max 33), climate 0.85 (max 5), far_bodies 0.78 (max 8), planet_camera 0.56 (max 19), flight_hud 0.38 (max 3), mineral_field 0.30 (max 24)
- **launch_regrade** (rover): 
- **e_rover** (rover): flora_field 0.82 (max 13), vessel_controller 0.61 (max 2), perfbench 0.43 (max 1), flight_hud 0.37 (max 2), planet_camera 0.29 (max 1), flight_ops 0.15 (max 3), dock_row 0.12 (max 0), far_bodies 0.10 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.r2Tick 0.10, planet_camera.chase_clip 0.09, vessel_controller.groupKeysTick 0.08, vessel_controller.safetyTick 0.06, vessel_controller.aeroTick 0.05, vessel_controller.waterTick 0.05, vessel_controller.stressTick 0.04, vessel_controller.controlsCard 0.04
- **a_onfoot30** (rover): flora_field 1.21 (max 2), perfbench 0.37 (max 2), tool_belt 0.34 (max 1), planet_walker 0.33 (max 1), planet_camera 0.28 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.r2Tick 1.19, planet_camera.chase_clip 1.01, vessel_controller.groupKeysTick 0.88, vessel_controller.safetyTick 0.67, vessel_controller.aeroTick 0.58, vessel_controller.waterTick 0.58, vessel_controller.controlsCard 0.41, vessel_controller.stressTick 0.41
- **a_load** (builder): perfbench 0.62 (max 4), flora_field 0.55 (max 23), planet_camera 0.27 (max 5), game_manager 0.25 (max 95), far_bodies 0.17 (max 8), tool_belt 0.17 (max 2), dock_row 0.14 (max 3), base_facilities 0.13 (max 19)
- **g_enter** (builder): catalog_panel 1.30 (max 5), perfbench 0.35 (max 0), tool_belt 0.18 (max 0), objectives 0.17 (max 0), planet_walker 0.15 (max 0), flora_field 0.12 (max 0), far_bodies 0.09 (max 0), builder_toolbar 0.08 (max 0)
- **g_load_300** (builder): builder 1.87 (max 5), perfbench 1.73 (max 6), builder_camera 0.70 (max 2), builder_toolbar 0.24 (max 1), weather 0.17 (max 0), flora_field 0.12 (max 0), far_bodies 0.09 (max 0), dock_row 0.08 (max 0)
- **g_idle_300** (builder): builder 0.82 (max 4), perfbench 0.39 (max 1), flora_field 0.24 (max 1), far_bodies 0.10 (max 0), catalog_panel 0.09 (max 3), dock_row 0.08 (max 0), weather 0.08 (max 0), tool_belt 0.07 (max 0)
- **g_hand_300** (builder): perfbench 0.39 (max 1), flora_field 0.25 (max 1), builder 0.19 (max 0), catalog_panel 0.10 (max 3), far_bodies 0.10 (max 0), dock_row 0.08 (max 0), weather 0.08 (max 0), tool_belt 0.07 (max 0)
- **g_load_1000** (builder): builder 1.88 (max 10), perfbench 1.34 (max 16), builder_camera 0.65 (max 3), flora_field 0.23 (max 1), builder_toolbar 0.14 (max 1), far_bodies 0.09 (max 0), dock_row 0.08 (max 0), weather 0.07 (max 0)
- **g_idle_1000** (builder): builder 1.97 (max 8), perfbench 0.41 (max 1), flora_field 0.25 (max 1), builder_camera 0.12 (max 2), builder_toolbar 0.11 (max 0), far_bodies 0.10 (max 0), catalog_panel 0.10 (max 2), dock_row 0.08 (max 0)
- **g_hand_1000** (builder): perfbench 0.42 (max 1), flora_field 0.25 (max 1), builder 0.20 (max 0), builder_toolbar 0.11 (max 0), catalog_panel 0.10 (max 3), far_bodies 0.10 (max 0), dock_row 0.08 (max 0), weather 0.08 (max 0)
- **g_load_3000** (builder): builder 2.28 (max 37), perfbench 1.43 (max 49), builder_camera 1.03 (max 6), builder_toolbar 0.28 (max 2), flora_field 0.25 (max 1), far_bodies 0.10 (max 0), dock_row 0.08 (max 0), weather 0.07 (max 0)
- **g_idle_3000** (builder): builder 3.55 (max 25), perfbench 0.45 (max 1), builder_toolbar 0.29 (max 1), flora_field 0.26 (max 1), catalog_panel 0.11 (max 3), far_bodies 0.10 (max 0), dock_row 0.08 (max 0), weather 0.08 (max 0)
- **g_hand_3000** (builder): perfbench 0.44 (max 1), builder 0.35 (max 0), builder_toolbar 0.28 (max 0), flora_field 0.26 (max 1), catalog_panel 0.10 (max 2), far_bodies 0.10 (max 0), dock_row 0.08 (max 0), weather 0.08 (max 1)
- **g_load_craft1002** (builder): builder 1.95 (max 28), perfbench 1.74 (max 22), builder_camera 0.65 (max 4), flora_field 0.24 (max 1), builder_toolbar 0.22 (max 2), far_bodies 0.09 (max 0), dock_row 0.08 (max 0), weather 0.07 (max 0)
- **g_idle_craft** (builder): builder 0.72 (max 7), perfbench 0.40 (max 1), flora_field 0.23 (max 1), builder_camera 0.11 (max 2), builder_toolbar 0.11 (max 0), far_bodies 0.10 (max 0), catalog_panel 0.09 (max 2), dock_row 0.08 (max 0)
- **g_launch_rollout** (builder): flora_field 2.01 (max 11), vessel_controller 1.59 (max 23), climate 1.14 (max 3), planet_camera 0.58 (max 6), perfbench 0.56 (max 13), flight_hud 0.37 (max 1), dock_row 0.16 (max 0), build_host 0.12 (max 12)
- **g_launch_pad** (builder): vessel_controller 1.67 (max 4), planet_camera 0.81 (max 2), flora_field 0.76 (max 7), flight_hud 0.66 (max 1), perfbench 0.38 (max 2), dock_row 0.19 (max 0), far_bodies 0.09 (max 0), objectives 0.08 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.60, vessel_controller.massSync 0.49, vessel_controller.aboardRecs 0.17, vessel_controller.controlsCard 0.10, vessel_controller.groupStrip 0.10, vessel_controller.groupKeysTick 0.09, vessel_controller.recoverValue 0.08, vessel_controller.stagedDv 0.03
- **g_launch_release** (builder): flight_ops 7.45 (max 32), vessel_controller 6.04 (max 31), planet_camera 0.98 (max 3), flight_hud 0.81 (max 1), perfbench 0.47 (max 1), flora_field 0.36 (max 1), comms 0.26 (max 9), dock_row 0.19 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.aeroTick 1.72, flight_ops.fleetSync 1.59, vessel_controller.waterTick 0.99, vessel_controller.stressTick 0.94, planet_camera.chase_clip 0.69, vessel_controller.massSync 0.36, vessel_controller.aboardRecs 0.22, vessel_controller.recoverValue 0.17
- **g_launch_settle** (builder): flight_ops 7.52 (max 31), vessel_controller 5.35 (max 9), planet_camera 0.95 (max 3), flight_hud 0.81 (max 1), perfbench 0.51 (max 2), flora_field 0.35 (max 1), comms 0.20 (max 7), dock_row 0.19 (max 0)
  - Lua functions (inclusive ms/frame): flight_ops.fleetSync 1.44, vessel_controller.aeroTick 1.39, vessel_controller.stressTick 0.90, vessel_controller.waterTick 0.81, planet_camera.chase_clip 0.69, vessel_controller.massSync 0.31, vessel_controller.aboardRecs 0.22, vessel_controller.recoverValue 0.16
- **a_onfoot30** (builder): flora_field 1.24 (max 2), perfbench 0.37 (max 2), tool_belt 0.35 (max 1), planet_walker 0.32 (max 1), planet_camera 0.29 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.aeroTick 5.04, flight_ops.fleetSync 5.02, planet_camera.chase_clip 3.46, vessel_controller.stressTick 3.09, vessel_controller.waterTick 2.92, vessel_controller.massSync 2.02, vessel_controller.aboardRecs 1.08, vessel_controller.recoverValue 0.71

### Hitches (frames >= 50 ms, the engine's own record): where the time went

- a_load (base): 6 hitches, 817 ms in all — buckets mirror 248, scripts 238, models 98, terrain 85, untimed 59; parts terrainLoad 52, assetDecode 33, terrainMeshing 23, renderPasses 20, terrainShadow 9
- a_onfoot30 (base): 2 hitches, 103 ms in all — buckets gpuWait 75, render 10, scripts 8, untimed 4, physics 3; parts renderPasses 9, physicsStatic 3, renderInstancing 1, terrainMeshing 1, physicsBroadphase 0
- a_load (rocket): 6 hitches, 512 ms in all — buckets scripts 221, terrain 128, untimed 49, models 42, assets 34; parts terrainLoad 51, terrainMeshing 45, assetDecode 26, terrainStreaming 24, renderPasses 16
- launch_load (rocket): 16 hitches, 1058 ms in all — buckets terrain 747, scripts 200, render 32, untimed 32, ui 26; parts terrainLoad 739, renderPasses 30, terrainShadow 3, terrainPalette 3, sceneLoad 2
- a_load (plane): 7 hitches, 706 ms in all — buckets scripts 245, models 141, terrain 124, untimed 68, physics 40; parts terrainMeshing 61, terrainLoad 54, physicsStatic 40, renderPasses 27, assetDecode 26
- launch_load (plane): 28 hitches, 1791 ms in all — buckets terrain 970, scripts 443, untimed 137, render 98, physics 57; parts terrainLoad 896, renderPasses 82, physicsStatic 56, terrainMeshing 54, renderInstancing 12
- d_takeoff (plane): 20 hitches, 1551 ms in all — buckets physics 962, scripts 279, untimed 115, render 107, mirror 21; parts physicsSweeps 554, physicsStatic 402, renderPasses 87, renderInstancing 18, terrainMeshing 17
- d_low_flight (plane): 6 hitches, 308 ms in all — buckets gpuWait 151, physics 50, scripts 44, render 26, untimed 20; parts physicsSweeps 46, renderPasses 23, scatterSettle 4, physicsStatic 3, renderInstancing 3
- a_load (rover): 7 hitches, 700 ms in all — buckets scripts 246, models 146, terrain 120, untimed 64, assets 43; parts terrainMeshing 55, terrainLoad 52, assetDecode 35, renderPasses 30, terrainShadow 12
- launch_load (rover): 22 hitches, 1467 ms in all — buckets terrain 751, scripts 429, untimed 101, render 85, physics 29; parts terrainLoad 707, renderPasses 74, physicsStatic 26, terrainMeshing 25, renderInstancing 9
- a_load (builder): 8 hitches, 681 ms in all — buckets scripts 262, terrain 131, models 95, untimed 78, assets 37; parts terrainLoad 53, terrainMeshing 51, renderPasses 34, assetDecode 28, terrainShadow 13
- g_enter (builder): 1 hitches, 56 ms in all — buckets scripts 34, untimed 12, render 7, mirror 1, physics 0; parts renderPasses 5, renderInstancing 1, physicsStatic 0, sceneLoad 0, terrainMeshing 0
- g_load_1000 (builder): 1 hitches, 53 ms in all — buckets scripts 33, untimed 8, render 6, mirror 2, ui 2; parts renderPasses 5, renderInstancing 1, terrainMeshing 1, physicsStatic 0, renderCull 0
- g_load_3000 (builder): 1 hitches, 123 ms in all — buckets scripts 97, untimed 11, render 8, mirror 2, ui 2; parts renderPasses 6, renderInstancing 2, physicsStatic 1, terrainStreaming 1, terrainShadow 0
- g_idle_3000 (builder): 3 hitches, 174 ms in all — buckets render 60, scripts 46, untimed 42, ui 8, assets 5; parts renderPasses 28, renderInstancing 27, physicsStatic 4, terrainMeshing 2, renderCull 1
- g_load_craft1002 (builder): 2 hitches, 150 ms in all — buckets scripts 65, untimed 31, mirror 24, render 16, ui 4; parts renderPasses 12, physicsStatic 4, renderInstancing 4, terrainMeshing 2, terrainShadow 0
- g_launch_rollout (builder): 2 hitches, 123 ms in all — buckets scripts 65, mirror 27, render 15, untimed 11, scatter 2; parts renderPasses 11, renderInstancing 3, scatterSettle 1, assemblyRebuild 0, terrainMeshing 0
- g_launch_release (builder): 141 hitches, 10450 ms in all — buckets physics 5447, scripts 2600, render 1279, untimed 656, assets 113; parts physicsStatic 5392, renderPasses 831, renderInstancing 404, physicsSweeps 40, terrainMeshing 28
- g_launch_settle (builder): 304 hitches, 20026 ms in all — buckets physics 9542, scripts 5358, render 2800, untimed 1360, assets 242; parts physicsStatic 9443, renderPasses 1835, renderInstancing 868, physicsSweeps 71, terrainMeshing 60

### Worst frames (engine hitch records; scripts from the inverted means, approximate)

- a_load #1: 366 ms at +0.5 s — buckets mirror 243, scripts 64, assets 37; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 33, assetUpload 4, renderPasses 3
- a_load #2: 122 ms at +12.6 s — buckets models 71, scripts 29, terrain 9; scripts status_hud 4, tool_belt 2, vfx 2; parts terrainMeshing 4, renderPasses 4, terrainShadow 4
- a_load #3: 103 ms at +1.1 s — buckets scripts 97, untimed 2, render 2; scripts game_manager 95, perfbench 0, planet_camera 0; parts renderPasses 1, terrainShadow 1, renderInstancing 0
- a_onfoot30 #1: 51 ms at +22.3 s — buckets gpuWait 38, render 5, scripts 4; scripts tool_belt 0, planet_camera 0, perfbench 0; parts renderPasses 4, physicsStatic 2, renderInstancing 1
- a_onfoot30 #2: 51 ms at +22.6 s — buckets gpuWait 37, render 5, scripts 4; scripts perfbench 0, planet_camera 0, objectives 0; parts renderPasses 4, physicsStatic 2, renderInstancing 1
- a_load #1: 116 ms at +0.2 s — buckets scripts 64, assets 30, untimed 15; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 26, renderPasses 4, assetUpload 4
- a_load #2: 102 ms at +11.9 s — buckets models 40, terrain 30, scripts 16; scripts perfbench 2, weather 2, base_facilities 2; parts terrainMeshing 21, terrainStreaming 6, renderPasses 4
- a_load #3: 98 ms at +0.9 s — buckets scripts 93, untimed 2, render 1; scripts game_manager 91, perfbench 0, planet_camera 0; parts renderPasses 1, terrainShadow 1, renderInstancing 0
- launch_load #1: 111 ms at +0.4 s — buckets terrain 91, scripts 11, untimed 5; scripts perfbench 4, game_manager 0, tool_belt 0; parts terrainLoad 91, renderPasses 3, renderInstancing 0
- launch_load #2: 97 ms at +0.5 s — buckets terrain 82, scripts 9, render 3; scripts dock_row 2, perfbench 1, tool_belt 0; parts terrainLoad 82, renderPasses 3, renderInstancing 0
- launch_load #3: 79 ms at +0.6 s — buckets terrain 66, scripts 6, untimed 3; scripts objectives 2, perfbench 1, tool_belt 0; parts terrainLoad 66, renderPasses 1, renderInstancing 0
- a_load #1: 127 ms at +12.1 s — buckets models 78, scripts 19, terrain 15; scripts base_facilities 5, perfbench 3, dock_row 2; parts terrainMeshing 12, renderPasses 3, physicsStatic 3
- a_load #2: 120 ms at +0.2 s — buckets scripts 66, assets 29, untimed 17; scripts game_manager 1, planet_camera 1, tool_belt 0; parts assetDecode 26, assetUpload 4, renderPasses 3
- a_load #3: 110 ms at +12.3 s — buckets models 60, scripts 20, terrain 13; scripts climate 6, planet_camera 2, comms 2; parts terrainMeshing 9, renderPasses 5, physicsStatic 2
- launch_load #1: 107 ms at +5.2 s — buckets physics 46, scripts 29, untimed 12; scripts flora_field 7, far_bodies 5, vessel_controller 4; parts physicsStatic 46, renderPasses 8, terrainMeshing 4
- launch_load #2: 100 ms at +0.5 s — buckets terrain 92, scripts 5, render 2; scripts perfbench 1, tool_belt 0, game_manager 0; parts terrainLoad 92, renderPasses 2, renderInstancing 0
- launch_load #3: 89 ms at +0.6 s — buckets terrain 79, scripts 6, untimed 2; scripts perfbench 1, planet_camera 0, tool_belt 0; parts terrainLoad 79, renderPasses 1, terrainShadow 0
- d_takeoff #1: 198 ms at +10.3 s — buckets physics 170, scripts 12, untimed 7; scripts vessel_controller 3, flora_field 2, planet_camera 1; parts physicsSweeps 101, physicsStatic 69, renderPasses 4
- d_takeoff #2: 153 ms at +10.4 s — buckets physics 131, scripts 11, render 4; scripts vessel_controller 3, flora_field 2, perfbench 1; parts physicsSweeps 78, physicsStatic 52, renderPasses 4
- d_takeoff #3: 146 ms at +10.1 s — buckets physics 124, scripts 11, render 4; scripts flora_field 3, vessel_controller 3, flight_hud 1; parts physicsSweeps 74, physicsStatic 49, renderPasses 4
- d_low_flight #1: 54 ms at +1.1 s — buckets gpuWait 30, physics 8, scripts 6; scripts flora_field 1, vessel_controller 1, flight_hud 1; parts physicsSweeps 8, renderPasses 4, terrainMeshing 1
- d_low_flight #2: 51 ms at +1.2 s — buckets gpuWait 26, physics 8, scripts 8; scripts vessel_controller 2, flora_field 1, flight_hud 1; parts physicsSweeps 8, renderPasses 4, scatterSettle 1
- d_low_flight #3: 51 ms at +1.1 s — buckets gpuWait 25, physics 8, scripts 7; scripts vessel_controller 1, flora_field 1, perfbench 1; parts physicsSweeps 8, renderPasses 4, scatterSettle 1
- a_load #1: 127 ms at +0.2 s — buckets scripts 65, assets 39, untimed 14; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 35, assetUpload 4, renderPasses 3
- a_load #2: 116 ms at +12.2 s — buckets models 51, scripts 19, terrain 14; scripts weather 5, perfbench 3, peripheral_row 2; parts terrainMeshing 11, renderPasses 6, physicsStatic 4
- a_load #3: 103 ms at +0.3 s — buckets terrain 67, scripts 14, untimed 11; scripts objectives 2, perfbench 1, tool_belt 0; parts terrainLoad 52, terrainMeshing 14, assetUpload 3
- launch_load #1: 113 ms at +0.5 s — buckets terrain 87, untimed 12, scripts 10; scripts vessel_switcher 2, perfbench 1, tool_belt 0; parts terrainLoad 86, renderPasses 3, renderInstancing 0
- launch_load #2: 106 ms at +1.3 s — buckets terrain 76, scripts 22, untimed 4; scripts game_manager 11, perfbench 3, peripheral_row 2; parts terrainLoad 76, renderPasses 3, renderInstancing 0
- launch_load #3: 95 ms at +0.4 s — buckets terrain 78, scripts 9, render 3; scripts perfbench 2, tool_belt 1, game_manager 0; parts terrainLoad 78, renderPasses 3, renderInstancing 0
- a_load #1: 122 ms at +0.2 s — buckets scripts 67, assets 31, untimed 17; scripts build_host 2, game_manager 1, tool_belt 0; parts assetDecode 28, assetUpload 4, renderPasses 3
- a_load #2: 102 ms at +0.9 s — buckets scripts 97, untimed 2, terrain 1; scripts game_manager 95, perfbench 0, planet_camera 0; parts terrainShadow 1, renderPasses 1, renderInstancing 0
- a_load #3: 98 ms at +12.3 s — buckets models 53, scripts 24, terrain 9; scripts planet_walker 8, climate 3, perfbench 2; parts terrainMeshing 4, terrainShadow 3, renderPasses 3
- g_enter #1: 56 ms at +0.1 s — buckets scripts 34, untimed 12, render 7; scripts catalog_panel 5, perfbench 0, builder_toolbar 0; parts renderPasses 5, renderInstancing 1, physicsStatic 0
- g_load_1000 #1: 53 ms at +0.1 s — buckets scripts 33, untimed 8, render 6; scripts perfbench 16, builder 10, builder_camera 3; parts renderPasses 5, renderInstancing 1, terrainMeshing 1
- g_load_3000 #1: 123 ms at +0.1 s — buckets scripts 97, untimed 11, render 8; scripts perfbench 49, builder 37, builder_camera 6; parts renderPasses 6, renderInstancing 2, physicsStatic 1
- g_idle_3000 #1: 64 ms at +0.5 s — buckets scripts 29, render 15, untimed 11; scripts builder 25, flora_field 1, perfbench 0; parts renderPasses 8, renderInstancing 7, physicsStatic 1
- g_idle_3000 #2: 58 ms at +3.2 s — buckets render 30, untimed 14, scripts 5; scripts builder 1, perfbench 0, builder_toolbar 0; parts renderInstancing 13, renderPasses 13, physicsStatic 1
- g_idle_3000 #3: 52 ms at +2.3 s — buckets untimed 17, render 14, scripts 12; scripts builder 4, catalog_panel 3, builder_toolbar 1; parts renderInstancing 7, renderPasses 7, physicsStatic 1
- g_load_craft1002 #1: 99 ms at +0.1 s — buckets scripts 59, untimed 20, render 8; scripts builder 28, perfbench 22, builder_camera 4; parts renderPasses 6, renderInstancing 2, physicsStatic 1
- g_load_craft1002 #2: 51 ms at +0.1 s — buckets mirror 20, untimed 10, render 8; scripts builder_camera 2, perfbench 1, builder 0; parts renderPasses 6, physicsStatic 3, renderInstancing 2
- g_launch_rollout #1: 64 ms at +1.1 s — buckets scripts 41, mirror 9, render 6; scripts vessel_controller 23, planet_camera 2, perfbench 0; parts renderPasses 5, renderInstancing 1, scatterSettle 1
- g_launch_rollout #2: 59 ms at +1.4 s — buckets scripts 24, mirror 19, render 8; scripts vessel_controller 16, flora_field 3, climate 2; parts renderPasses 6, renderInstancing 2, assemblyRebuild 0
- g_launch_release #1: 331 ms at +1.2 s — buckets physics 249, scripts 59, render 11; scripts vessel_controller 27, flight_ops 23, planet_camera 2; parts physicsStatic 247, renderPasses 7, renderInstancing 4
- g_launch_release #2: 319 ms at +1.6 s — buckets physics 251, scripts 45, render 10; scripts vessel_controller 31, flight_ops 6, planet_camera 3; parts physicsStatic 248, renderPasses 7, renderInstancing 3
- g_launch_release #3: 314 ms at +0.9 s — buckets physics 250, scripts 34, render 13; scripts vessel_controller 25, planet_camera 3, flora_field 1; parts physicsStatic 247, renderPasses 9, renderInstancing 4
- g_launch_settle #1: 96 ms at +10.4 s — buckets scripts 47, physics 31, render 10; scripts flight_ops 30, comms 6, vessel_controller 6; parts physicsStatic 31, renderPasses 7, renderInstancing 3
- g_launch_settle #2: 96 ms at +8.3 s — buckets scripts 48, physics 31, render 10; scripts flight_ops 31, vessel_controller 6, comms 6; parts physicsStatic 31, renderPasses 6, renderInstancing 3
- g_launch_settle #3: 94 ms at +15.7 s — buckets scripts 41, physics 31, render 13; scripts flight_ops 30, vessel_controller 7, flight_hud 1; parts physicsStatic 31, renderPasses 9, renderInstancing 4

### Notes and counts

- a_load: grading=12.987, loaded=12.327, loading=0.458, reveal=18.143, sited=17.869 | draws 50 (max 408), nodes 188, chunks 202, props 9, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 9.6 ms (matter / terrain 4.1, opaque + lighting 2.6, glass 1.5, post (AO, bloom, blur…) 0.7), parts renderPasses 1.80, renderInstancing 0.18, terrainMeshing 0.13, physicsStatic 0.09
- a_onfoot30:  | draws 752 (max 824), nodes 522, chunks 2915, props 31, decals 0, rays/frame 5 (0.13 ms), mirror rebuilds 0.00, gpu 26.3 ms (opaque + lighting 17.7, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, depth prepass 0.6), parts renderPasses 4.35, physicsStatic 0.88, renderInstancing 0.52, terrainMeshing 0.42
- a_after30_until_ready:  | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- b_dig_meadow: biome=shore, decals=0->0 | draws 783 (max 783), nodes 551, chunks 5751, props 97, decals 0, rays/frame 8 (0.12 ms), mirror rebuilds 0.00, gpu 19.9 ms (opaque + lighting 11.5, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 4.42, renderInstancing 0.63, physicsStatic 0.35, terrainMeshing 0.18
- b_dig_rock: biome=shore, decals=0->0 | draws 783 (max 783), nodes 551, chunks 5751, props 97, decals 0, rays/frame 8 (0.13 ms), mirror rebuilds 0.00, gpu 19.9 ms (opaque + lighting 11.5, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 4.43, renderInstancing 0.62, physicsStatic 0.20, terrainMeshing 0.18
- f_map_onfoot:  | draws 36 (max 785), nodes 549, chunks 5751, props 2, decals 0, rays/frame 6 (0.04 ms), mirror rebuilds 0.00, gpu 3.4 ms (matter / terrain 1.9, post (AO, bloom, blur…) 0.5, opaque + lighting 0.4, sky / environment 0.3), parts renderPasses 1.39, renderInstancing 0.19, terrainStreaming 0.09, outsideFrame 0.03
- a_load: grading=12.576, loaded=11.877, loading=0.213, reveal=25.352, sited=25.099 | draws 110 (max 573), nodes 222, chunks 531, props 21, decals 0, rays/frame 3 (0.03 ms), mirror rebuilds 0.00, gpu 13.5 ms (opaque + lighting 6.0, matter / terrain 4.5, glass 1.4, post (AO, bloom, blur…) 0.7), parts renderPasses 2.27, renderInstancing 0.24, terrainMeshing 0.23, terrainStreaming 0.16
- launch_load:  | draws 71 (max 235), nodes 326, chunks 365, props 18, decals 0, rays/frame 1 (0.00 ms), mirror rebuilds 0.00, gpu 14.1 ms (opaque + lighting 7.2, matter / terrain 4.4, glass 0.9, post (AO, bloom, blur…) 0.7), parts terrainLoad 4.08, renderPasses 2.50, terrainMeshing 0.65, renderInstancing 0.39
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- c_ascent: apo=None, peri=None, phase=orbit, secs=37.711, world=Naolol R922 | draws 135 (max 594), nodes 651, chunks 5188, props 7, decals 1, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 6.9 ms (opaque + lighting 2.8, matter / terrain 2.5, post (AO, bloom, blur…) 0.6, sky / environment 0.3), parts renderPasses 2.02, physicsSweeps 0.99, renderInstancing 0.62, terrainMeshing 0.40
- c_throttle_change:  | draws 243 (max 594), nodes 652, chunks 4782, props 10, decals 1, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 10.5 ms (opaque + lighting 5.5, matter / terrain 3.4, post (AO, bloom, blur…) 0.6, sky / environment 0.3), parts renderPasses 2.47, physicsSweeps 1.25, renderInstancing 0.62, terrainMeshing 0.41
- c_orbit_coast:  | draws 36 (max 36), nodes 650, chunks 6750, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 3.7 ms (matter / terrain 2.0, post (AO, bloom, blur…) 0.6, sky / environment 0.4, opaque + lighting 0.4), parts renderPasses 1.09, physicsSweeps 0.75, renderInstancing 0.68, terrainMeshing 0.34
- f_map_flight:  | draws 57 (max 63), nodes 594, chunks 6763, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 3.5 ms (matter / terrain 2.1, post (AO, bloom, blur…) 0.5, sky / environment 0.4, opaque + lighting 0.2), parts renderPasses 1.44, physicsSweeps 0.48, renderInstancing 0.27, terrainStreaming 0.10
- a_onfoot30:  | draws 674 (max 775), nodes 458, chunks 1634, props 24, decals 0, rays/frame 7 (0.11 ms), mirror rebuilds 0.00, gpu 31.4 ms (opaque + lighting 22.3, matter / terrain 6.4, sun shadow map 0.9, post (AO, bloom, blur…) 0.7), parts renderPasses 4.04, physicsStatic 0.49, renderInstancing 0.41, terrainMeshing 0.40
- a_load: grading=12.739, loaded=12, loading=0.214, reveal=18.923, sited=18.677 | draws 70 (max 450), nodes 200, chunks 250, props 22, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 10.9 ms (matter / terrain 4.2, opaque + lighting 3.7, glass 1.5, post (AO, bloom, blur…) 0.7), parts renderPasses 2.24, renderInstancing 0.22, terrainMeshing 0.18, physicsStatic 0.16
- launch_load:  | draws 100 (max 312), nodes 259, chunks 312, props 2, decals 0, rays/frame 1 (0.11 ms), mirror rebuilds 0.00, gpu 13.9 ms (opaque + lighting 5.6, matter / terrain 4.4, glass 1.9, post (AO, bloom, blur…) 0.7), parts terrainLoad 4.37, renderPasses 3.09, terrainMeshing 0.80, terrainShadow 0.59
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- d_takeoff: liftoff_s=10.945 | draws 467 (max 583), nodes 591, chunks 1328, props 30, decals 0, rays/frame 1 (0.03 ms), mirror rebuilds 0.00, gpu 20.7 ms (opaque + lighting 11.8, matter / terrain 6.2, depth prepass 0.8, post (AO, bloom, blur…) 0.7), parts physicsSweeps 7.63, physicsStatic 4.09, renderPasses 3.40, terrainMeshing 0.75
- d_low_flight: V_end=92.867, agl_end=0 | draws 370 (max 551), nodes 687, chunks 3286, props 94, decals 0, rays/frame 5 (0.44 ms), mirror rebuilds 0.00, gpu 21.4 ms (opaque + lighting 13.2, matter / terrain 6.2, post (AO, bloom, blur…) 0.6, glass 0.4), parts renderPasses 3.58, physicsSweeps 3.46, terrainMeshing 0.66, renderInstancing 0.61
- a_onfoot30:  | draws 555 (max 651), nodes 449, chunks 1266, props 25, decals 0, rays/frame 7 (0.12 ms), mirror rebuilds 0.00, gpu 27.4 ms (opaque + lighting 18.9, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 3.75, physicsStatic 1.09, terrainStreaming 0.58, renderInstancing 0.39
- a_load: grading=12.723, loaded=12.048, loading=0.222, reveal=19.551, sited=19.301 | draws 90 (max 505), nodes 212, chunks 500, props 12, decals 0, rays/frame 2 (0.03 ms), mirror rebuilds 0.00, gpu 10.8 ms (matter / terrain 4.3, opaque + lighting 3.4, glass 1.4, post (AO, bloom, blur…) 0.7), parts renderPasses 2.27, renderInstancing 0.24, terrainMeshing 0.21, physicsStatic 0.15
- launch_load:  | draws 89 (max 333), nodes 227, chunks 244, props 12, decals 0, rays/frame 1 (0.00 ms), mirror rebuilds 0.00, gpu 10.7 ms (matter / terrain 3.9, opaque + lighting 3.8, glass 1.0, post (AO, bloom, blur…) 0.7), parts terrainLoad 5.07, renderPasses 3.27, terrainMeshing 0.71, terrainShadow 0.49
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- e_rover: maxFromBase=285.603 | draws 735 (max 816), nodes 641, chunks 3840, props 162, decals 41, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 23.7 ms (opaque + lighting 14.9, matter / terrain 6.2, post (AO, bloom, blur…) 0.8, depth prepass 0.7), parts renderPasses 5.00, physicsStatic 0.95, physicsSweeps 0.79, renderInstancing 0.64
- a_onfoot30:  | draws 625 (max 750), nodes 444, chunks 1550, props 24, decals 0, rays/frame 7 (0.11 ms), mirror rebuilds 0.00, gpu 22.5 ms (opaque + lighting 13.5, matter / terrain 6.4, post (AO, bloom, blur…) 0.8, sun shadow map 0.7), parts renderPasses 3.86, physicsStatic 0.90, renderInstancing 0.41, terrainMeshing 0.40
- a_load: grading=12.657, loaded=11.963, loading=0.218, reveal=20.768, sited=20.494 | draws 113 (max 569), nodes 222, chunks 532, props 17, decals 0, rays/frame 3 (0.03 ms), mirror rebuilds 0.00, gpu 11.0 ms (matter / terrain 4.4, opaque + lighting 3.6, glass 1.3, post (AO, bloom, blur…) 0.7), parts renderPasses 2.38, renderInstancing 0.26, terrainMeshing 0.24, terrainEdits 0.19
- g_enter:  | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts renderPasses 4.52, physicsStatic 0.80, renderInstancing 0.69, terrainMeshing 0.38
- g_load_300: load_s=0.113, parts=300 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts renderPasses 4.53, renderInstancing 1.51, physicsStatic 0.88, terrainMeshing 0.43
- g_idle_300:  | draws 813 (max 815), nodes 1489, chunks 2709, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 30.3 ms (opaque + lighting 21.3, matter / terrain 6.4, post (AO, bloom, blur…) 0.8, sun shadow map 0.7), parts renderPasses 4.62, renderInstancing 1.72, physicsStatic 0.83, terrainMeshing 0.45
- g_hand_300:  | draws 819 (max 821), nodes 1489, chunks 3236, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 30.4 ms (opaque + lighting 21.3, matter / terrain 6.4, post (AO, bloom, blur…) 0.8, sun shadow map 0.7), parts renderPasses 4.65, renderInstancing 1.72, physicsStatic 0.81, terrainMeshing 0.46
- g_load_1000: load_s=0.496, parts=1000 | draws 822 (max 822), nodes 1708, chunks 3590, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 31.3 ms (opaque + lighting 22.2, matter / terrain 6.4, post (AO, bloom, blur…) 0.9, sun shadow map 0.7), parts renderPasses 4.93, renderInstancing 2.22, physicsStatic 0.81, terrainMeshing 0.45
- g_idle_1000:  | draws 823 (max 823), nodes 2188, chunks 3863, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 32.8 ms (opaque + lighting 23.4, matter / terrain 6.4, post (AO, bloom, blur…) 0.9, depth prepass 0.9), parts renderPasses 5.27, renderInstancing 3.02, physicsStatic 0.88, terrainMeshing 0.46
- g_hand_1000:  | draws 823 (max 823), nodes 2189, chunks 4326, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 33.0 ms (opaque + lighting 23.5, matter / terrain 6.4, post (AO, bloom, blur…) 0.9, depth prepass 0.9), parts renderPasses 5.23, renderInstancing 2.98, physicsStatic 0.87, terrainMeshing 0.45
- g_load_3000: load_s=1.751, parts=3000 | draws 823 (max 823), nodes 2788, chunks 4738, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 34.0 ms (opaque + lighting 24.6, matter / terrain 6.4, depth prepass 0.9, post (AO, bloom, blur…) 0.9), parts renderPasses 5.88, renderInstancing 4.07, physicsStatic 0.95, terrainMeshing 0.44
- g_idle_3000:  | draws 823 (max 823), nodes 4186, chunks 5059, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 35.8 ms (opaque + lighting 25.4, matter / terrain 6.4, depth prepass 1.5, sun shadow map 1.0), parts renderPasses 6.57, renderInstancing 6.43, physicsStatic 0.99, terrainMeshing 0.48
- g_hand_3000:  | draws 823 (max 823), nodes 4189, chunks 5497, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 35.8 ms (opaque + lighting 25.7, matter / terrain 6.5, depth prepass 1.3, sun shadow map 1.0), parts renderPasses 6.52, renderInstancing 6.33, physicsStatic 0.94, terrainMeshing 0.42
- g_load_craft1002: load_s=0.533, parts=1002 | draws 840 (max 840), nodes 1898, chunks 5837, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 29.4 ms (opaque + lighting 20.3, matter / terrain 6.3, post (AO, bloom, blur…) 0.8, sun shadow map 0.8), parts renderPasses 5.53, renderInstancing 2.19, physicsStatic 0.91, terrainMeshing 0.45
- g_idle_craft:  | draws 840 (max 840), nodes 2201, chunks 6092, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 29.7 ms (opaque + lighting 20.4, matter / terrain 6.4, sun shadow map 0.9, post (AO, bloom, blur…) 0.8), parts renderPasses 5.57, renderInstancing 2.71, physicsStatic 0.80, terrainMeshing 0.32
- g_launch_rollout: secs=3.404 | draws 781 (max 840), nodes 1731, chunks 6181, props 90, decals 0, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 30.4 ms (opaque + lighting 21.4, matter / terrain 6.3, sun shadow map 0.8, depth prepass 0.8), parts renderPasses 5.84, renderInstancing 2.56, physicsStatic 0.27, terrainMeshing 0.24
- g_launch_pad:  | draws 793 (max 796), nodes 1682, chunks 6181, props 122, decals 17, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 32.2 ms (opaque + lighting 23.4, matter / terrain 6.3, sun shadow map 0.8, depth prepass 0.7), parts renderPasses 6.02, renderInstancing 2.69, decalLay 0.55, terrainMeshing 0.20
- g_launch_release:  | draws 794 (max 794), nodes 1678, chunks 6181, props 121, decals 40, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 31.6 ms (opaque + lighting 21.2, matter / terrain 5.5, depth prepass 2.2, sun shadow map 1.0), parts physicsStatic 38.24, renderPasses 5.90, renderInstancing 2.86, physicsSweeps 0.28
- g_launch_settle:  | draws 794 (max 794), nodes 1679, chunks 6181, props 121, decals 40, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 25.8 ms (opaque + lighting 10.8, depth prepass 4.8, sun shadow map 3.5, matter / terrain 3.5), parts physicsStatic 31.06, renderPasses 6.04, renderInstancing 2.85, physicsSweeps 0.23
- a_onfoot30:  | draws 675 (max 779), nodes 454, chunks 1629, props 24, decals 0, rays/frame 7 (0.12 ms), mirror rebuilds 0.00, gpu 30.6 ms (opaque + lighting 21.5, matter / terrain 6.4, sun shadow map 0.8, post (AO, bloom, blur…) 0.7), parts renderPasses 4.11, physicsStatic 1.11, renderInstancing 0.42, terrainMeshing 0.41

## 0.117.0-rc25

| scenario | load (1/5/15) | frames | p50 | p95 | p99 | max | >33 ms | >100 ms | hitches | work p50/p95/max | script | physics | terrain | render | gpu/vsync | untimed | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a_load (base) | 4.64, 7.59, 11.38 | 1536 | 8.1 | 27.8 | 32.7 | 843 | 15 | 4 | 9 | 7.9/19.5/566 | 4.5 | 0.1 | 0.7 | 3.6 | 1.6 | 1.7 | 0.0 |
| a_onfoot30 (base) | 4.64, 7.59, 11.38 | 1151 | 25.8 | 32.4 | 47.4 | 54 | 41 | 0 | 5 | 13.1/16.6/35 | 4.2 | 0.8 | 0.9 | 5.7 | 12.6 | 1.8 | 0.0 |
| a_after30_until_ready (base) | 4.64, 7.59, 11.38 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| b_dig_meadow (base) | 4.64, 7.59, 11.38 | 1115 | 19.8 | 21.0 | 22.6 | 40 | 1 | 0 | 0 | 12.3/14.3/35 | 3.7 | 0.5 | 0.6 | 6.0 | 7.3 | 1.7 | 0.0 |
| b_dig_rock (base) | 4.64, 7.59, 11.38 | 1115 | 19.8 | 21.4 | 23.4 | 36 | 1 | 0 | 0 | 11.8/13.8/31 | 3.7 | 0.0 | 0.6 | 6.0 | 7.8 | 1.7 | 0.0 |
| f_map_onfoot (base) | 4.64, 7.59, 11.38 | 1861 | 6.8 | 8.5 | 21.8 | 28 | 0 | 0 | 0 | 6.6/8.1/21 | 3.0 | 0.0 | 0.2 | 2.4 | 0.4 | 1.3 | 0.0 |
| a_load (rocket) | 3.92, 6.61, 10.57 | 1344 | 11.8 | 26.8 | 33.2 | 128 | 13 | 2 | 6 | 11.2/21.8/120 | 5.3 | 0.1 | 0.8 | 4.0 | 1.6 | 2.2 | 0.0 |
| launch_load (rocket) | 3.92, 6.61, 10.57 | 215 | 17.9 | 66.0 | 98.6 | 112 | 40 | 1 | 18 | 17.3/56.5/115 | 9.0 | 0.3 | 6.1 | 4.3 | 0.9 | 2.8 | 0.0 |
| launch_regrade (rocket) | 3.92, 6.61, 10.57 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| c_ascent (rocket) | 3.92, 6.61, 10.57 | 3713 | 9.8 | 21.5 | 31.5 | 92 | 19 | 0 | 5 | 9.6/16.7/91 | 3.6 | 1.0 | 0.6 | 3.4 | 0.6 | 1.7 | 0.0 |
| c_throttle_change (rocket) | 3.92, 6.61, 10.57 | 917 | 10.8 | 24.0 | 29.5 | 33 | 0 | 0 | 0 | 10.5/18.1/28 | 3.9 | 1.3 | 0.6 | 3.9 | 1.3 | 1.8 | 0.0 |
| c_orbit_coast (rocket) | 3.92, 6.61, 10.57 | 1045 | 9.3 | 14.7 | 16.7 | 22 | 0 | 0 | 0 | 9.1/14.3/20 | 3.3 | 1.1 | 0.6 | 2.6 | 0.2 | 1.7 | 0.0 |
| f_map_flight (rocket) | 3.92, 6.61, 10.57 | 1722 | 7.7 | 9.5 | 10.6 | 13 | 0 | 0 | 0 | 7.5/9.5/16 | 3.0 | 0.5 | 0.2 | 2.5 | 0.2 | 1.4 | 0.0 |
| a_onfoot30 (rocket) | 3.92, 6.61, 10.57 | 170 | 23.5 | 28.0 | 31.9 | 36 | 1 | 0 | 0 | 13.1/18.9/25 | 4.7 | 0.9 | 1.1 | 5.2 | 9.7 | 1.9 | 0.0 |
| a_load (plane) | 5.65, 6.77, 10.26 | 1342 | 9.8 | 31.1 | 36.0 | 127 | 31 | 2 | 6 | 9.4/20.2/120 | 5.2 | 0.2 | 0.6 | 3.8 | 2.4 | 2.2 | 0.0 |
| launch_load (plane) | 5.65, 6.77, 10.26 | 235 | 17.3 | 57.6 | 102.1 | 130 | 55 | 3 | 24 | 16.0/57.7/105 | 9.4 | 0.2 | 5.6 | 4.5 | 1.0 | 3.1 | 0.0 |
| launch_regrade (plane) | 5.65, 6.77, 10.26 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| d_takeoff (plane) | 5.65, 6.77, 10.26 | 394 | 24.6 | 43.3 | 111.2 | 168 | 57 | 4 | 14 | 24.2/43.0/169 | 7.3 | 9.9 | 1.0 | 5.4 | 0.4 | 3.2 | 0.0 |
| d_low_flight (plane) | 5.65, 6.77, 10.26 | 2079 | 19.9 | 34.6 | 44.5 | 52 | 132 | 0 | 1 | 17.2/27.4/49 | 5.6 | 3.9 | 1.3 | 5.3 | 3.2 | 2.4 | 0.0 |
| a_onfoot30 (plane) | 5.65, 6.77, 10.26 | 146 | 27.3 | 31.9 | 32.3 | 35 | 1 | 0 | 0 | 13.4/17.6/20 | 4.8 | 1.0 | 1.3 | 4.9 | 13.5 | 1.9 | 0.0 |
| a_load (rover) | 7.89, 7.47, 10.20 | 1277 | 10.9 | 28.2 | 34.3 | 131 | 15 | 3 | 7 | 10.5/21.0/120 | 5.3 | 0.1 | 0.6 | 3.9 | 1.8 | 2.1 | 0.0 |
| launch_load (rover) | 7.89, 7.47, 10.20 | 236 | 18.4 | 55.6 | 91.0 | 100 | 45 | 0 | 22 | 17.9/57.0/102 | 9.0 | 0.2 | 5.5 | 4.4 | 0.9 | 3.0 | 0.0 |
| launch_regrade (rover) | 7.89, 7.47, 10.20 | 0 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 | 0.0/0.0/0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| e_rover (rover) | 7.89, 7.47, 10.20 | 1640 | 25.6 | 43.4 | 46.5 | 52 | 414 | 0 | 1 | 18.6/24.2/37 | 5.1 | 2.7 | 1.3 | 6.7 | 8.7 | 3.0 | 0.0 |
| a_onfoot30 (rover) | 7.89, 7.47, 10.20 | 150 | 26.6 | 31.4 | 34.4 | 35 | 2 | 0 | 0 | 12.8/18.6/25 | 4.8 | 1.0 | 1.2 | 4.9 | 13.0 | 1.9 | 0.0 |
| a_load (builder) | 7.40, 7.64, 10.06 | 1304 | 8.9 | 32.9 | 37.4 | 132 | 52 | 3 | 7 | 8.6/22.3/124 | 5.3 | 0.1 | 0.8 | 3.8 | 1.9 | 2.1 | 0.0 |
| g_enter (builder) | 7.40, 7.64, 10.06 | 4 | 26.7 | 54.3 | 54.3 | 54 | 1 | 0 | 1 | 12.7/56.8/57 | 12.8 | 0.7 | 0.7 | 5.4 | 10.1 | 3.9 | 0.0 |
| g_load_300 (builder) | 7.40, 7.64, 10.06 | 4 | 34.7 | 36.8 | 36.8 | 37 | 4 | 0 | 0 | 21.0/33.6/34 | 8.8 | 1.0 | 0.6 | 7.8 | 10.9 | 6.0 | 0.0 |
| g_idle_300 (builder) | 7.40, 7.64, 10.06 | 110 | 36.2 | 38.8 | 40.9 | 41 | 107 | 0 | 0 | 19.7/25.3/38 | 5.4 | 1.0 | 0.8 | 8.4 | 16.0 | 4.8 | 0.0 |
| g_hand_300 (builder) | 7.40, 7.64, 10.06 | 112 | 36.2 | 39.2 | 39.7 | 40 | 109 | 0 | 0 | 18.7/23.6/31 | 3.8 | 0.9 | 0.8 | 8.9 | 17.1 | 4.8 | 0.0 |
| g_load_1000 (builder) | 7.40, 7.64, 10.06 | 16 | 37.0 | 58.3 | 58.3 | 58 | 14 | 0 | 1 | 23.1/56.5/56 | 7.7 | 0.9 | 0.9 | 9.6 | 12.0 | 6.0 | 0.0 |
| g_idle_1000 (builder) | 7.40, 7.64, 10.06 | 107 | 37.3 | 40.2 | 40.9 | 42 | 106 | 0 | 0 | 24.6/34.1/40 | 6.0 | 1.0 | 1.0 | 11.7 | 12.0 | 5.8 | 0.0 |
| g_hand_1000 (builder) | 7.40, 7.64, 10.06 | 109 | 37.3 | 40.2 | 40.6 | 41 | 108 | 0 | 0 | 22.3/27.9/37 | 4.0 | 1.0 | 1.0 | 11.5 | 14.4 | 5.7 | 0.0 |
| g_load_3000 (builder) | 7.40, 7.64, 10.06 | 49 | 39.1 | 44.2 | 125.7 | 126 | 44 | 1 | 1 | 31.3/38.0/117 | 9.0 | 1.0 | 1.0 | 13.5 | 7.6 | 7.5 | 0.0 |
| g_idle_3000 (builder) | 7.40, 7.64, 10.06 | 103 | 37.8 | 47.7 | 58.4 | 61 | 103 | 0 | 2 | 36.6/47.5/61 | 8.2 | 1.0 | 1.2 | 18.7 | 1.3 | 8.4 | 0.0 |
| g_hand_3000 (builder) | 7.40, 7.64, 10.06 | 106 | 38.5 | 43.0 | 44.8 | 45 | 103 | 0 | 0 | 32.9/37.6/45 | 4.8 | 1.0 | 1.2 | 18.3 | 5.0 | 8.3 | 0.0 |
| g_load_craft1002 (builder) | 7.40, 7.64, 10.06 | 16 | 35.4 | 117.8 | 117.8 | 118 | 11 | 1 | 1 | 24.9/101.5/102 | 10.1 | 1.0 | 1.0 | 11.4 | 6.6 | 8.3 | 0.0 |
| g_idle_craft (builder) | 7.40, 7.64, 10.06 | 112 | 35.8 | 38.7 | 40.9 | 41 | 104 | 0 | 0 | 23.7/31.7/39 | 4.7 | 0.9 | 1.0 | 12.0 | 11.1 | 6.1 | 0.0 |
| g_launch_rollout (builder) | 7.40, 7.64, 10.06 | 102 | 32.2 | 40.1 | 52.3 | 64 | 39 | 0 | 2 | 26.8/38.2/65 | 10.5 | 0.4 | 1.2 | 11.0 | 4.9 | 5.2 | 0.0 |
| g_launch_pad (builder) | 7.40, 7.64, 10.06 | 249 | 32.3 | 34.6 | 35.8 | 38 | 55 | 0 | 0 | 24.2/29.0/37 | 7.1 | 0.2 | 1.6 | 11.2 | 7.7 | 4.4 | 0.0 |
| g_launch_release (builder) | 7.40, 7.64, 10.06 | 146 | 62.0 | 88.8 | 302.5 | 318 | 146 | 5 | 146 | 61.8/87.7/319 | 19.1 | 35.7 | 1.0 | 10.9 | 0.2 | 4.7 | 0.0 |
| g_launch_settle (builder) | 7.40, 7.64, 10.06 | 316 | 61.7 | 82.6 | 87.9 | 94 | 316 | 0 | 316 | 61.5/82.0/94 | 18.1 | 29.1 | 1.0 | 10.6 | 0.2 | 4.4 | 0.0 |
| a_onfoot30 (builder) | 7.40, 7.64, 10.06 | 128 | 31.0 | 36.0 | 37.7 | 38 | 21 | 0 | 0 | 13.7/19.4/28 | 5.2 | 1.2 | 1.3 | 4.8 | 16.8 | 2.0 | 0.0 |

### Frames over 33 ms: what they were spent on (ms per spike frame)

| scenario | spikes | script | physics | terrain | render | gpu/vsync | untimed | other | top scripts in spikes | top parts |
|---|---|---|---|---|---|---|---|---|---|---|
| a_load (base) | 15 | 22.6 | 1.0 | 6.6 | 57.6 | 1.3 | 12.8 | 0.0 | game_manager 6.1, flora_field 1.9, planet_walker 1.5, climate 0.9 | |
| a_onfoot30 (base) | 41 | 4.3 | 1.1 | 0.6 | 6.0 | 23.7 | 1.8 | 0.0 | flora_field 0.4, perfbench 0.4, planet_camera 0.4, objectives 0.4 | |
| b_dig_meadow (base) | 1 | 3.6 | 0.9 | 0.3 | 6.3 | 7.4 | 1.8 | 0.0 | objectives 0.3, perfbench 0.3, tool_belt 0.3, planet_walker 0.3 | |
| b_dig_rock (base) | 1 | 3.7 | 0.0 | 0.3 | 5.8 | 5.6 | 4.4 | 0.0 | planet_camera 0.5, objectives 0.3, perfbench 0.3, tool_belt 0.3 | |
| a_load (rocket) | 13 | 21.3 | 0.9 | 6.6 | 16.5 | 2.2 | 6.0 | 0.0 | game_manager 7.1, flora_field 2.1, perfbench 0.9, climate 0.9 | |
| launch_load (rocket) | 40 | 13.5 | 1.2 | 24.5 | 6.2 | 1.3 | 5.0 | 0.0 | flora_field 2.0, base_facilities 1.4, climate 1.2, perfbench 1.0 | |
| c_ascent (rocket) | 19 | 20.0 | 2.1 | 3.1 | 9.7 | 2.5 | 7.1 | 0.0 | flora_field 7.7, climate 1.8, flight_hud 1.3, perfbench 1.1 | |
| a_onfoot30 (rocket) | 1 | 5.0 | 0.7 | 0.3 | 5.4 | 11.6 | 1.5 | 0.0 | flora_field 1.7, planet_walker 0.3, perfbench 0.3, tool_belt 0.3 | |
| a_load (plane) | 31 | 14.4 | 1.3 | 3.7 | 9.4 | 8.7 | 3.4 | 0.1 | game_manager 3.3, flora_field 2.8, climate 1.1, planet_walker 0.7 | |
| launch_load (plane) | 55 | 15.6 | 0.8 | 19.5 | 6.7 | 2.4 | 6.3 | 0.0 | base_facilities 2.1, perfbench 1.1, climate 1.1, flight_hud 1.1 | |
| d_takeoff (plane) | 57 | 12.1 | 23.7 | 1.5 | 6.3 | 0.3 | 4.9 | 0.0 | flora_field 1.8, vessel_controller 1.7, climate 1.2, perfbench 1.1 | |
| d_low_flight (plane) | 132 | 9.0 | 6.7 | 1.6 | 5.6 | 12.3 | 3.0 | 0.0 | perfbench 2.2, flora_field 1.2, vessel_controller 0.9, flight_hud 0.8 | |
| a_onfoot30 (plane) | 1 | 4.6 | 1.3 | 0.5 | 5.5 | 14.2 | 1.6 | 0.0 | flora_field 1.2, tool_belt 0.5, perfbench 0.3, planet_walker 0.3 | |
| a_load (rover) | 15 | 22.5 | 1.6 | 11.1 | 17.3 | 1.9 | 5.5 | 0.1 | game_manager 6.6, flora_field 1.8, tool_belt 1.1, base_facilities 1.0 | |
| launch_load (rover) | 45 | 14.4 | 0.9 | 23.0 | 5.8 | 1.7 | 5.2 | 0.0 | base_facilities 2.0, perfbench 1.2, climate 1.2, flight_hud 0.8 | |
| e_rover (rover) | 414 | 5.8 | 2.6 | 1.9 | 7.5 | 18.8 | 3.3 | 0.0 | vessel_controller 1.1, flight_hud 0.7, perfbench 0.5, flora_field 0.4 | |
| a_onfoot30 (rover) | 2 | 5.1 | 1.2 | 0.5 | 5.1 | 11.5 | 3.1 | 0.0 | flora_field 1.2, tool_belt 0.7, planet_camera 0.4, perfbench 0.3 | |
| a_load (builder) | 52 | 12.3 | 1.0 | 6.1 | 7.0 | 10.2 | 3.3 | 0.1 | flora_field 3.1, game_manager 1.9, base_facilities 0.8, perfbench 0.5 | |
| g_enter (builder) | 1 | 3.9 | 0.5 | 0.3 | 5.2 | 14.6 | 1.2 | 0.0 | flora_field 1.2, perfbench 0.7, far_bodies 0.1, tool_belt 0.1 | |
| g_load_300 (builder) | 4 | 8.8 | 1.0 | 0.6 | 7.8 | 10.9 | 6.0 | 0.0 | perfbench 1.9, builder 1.4, flora_field 1.3, builder_camera 0.6 | |
| g_idle_300 (builder) | 107 | 5.4 | 1.0 | 0.8 | 8.4 | 16.1 | 4.7 | 0.0 | flora_field 1.2, builder 0.9, perfbench 0.5, catalog_panel 0.1 | |
| g_hand_300 (builder) | 109 | 3.8 | 0.9 | 0.8 | 8.9 | 17.2 | 4.8 | 0.0 | perfbench 0.4, flora_field 0.3, builder 0.2, catalog_panel 0.1 | |
| g_load_1000 (builder) | 14 | 7.6 | 0.9 | 0.9 | 9.8 | 13.3 | 6.1 | 0.0 | builder 2.1, perfbench 1.5, builder_camera 0.4, flora_field 0.3 | |
| g_idle_1000 (builder) | 106 | 6.0 | 1.0 | 0.9 | 11.7 | 12.1 | 5.8 | 0.0 | builder 2.1, perfbench 0.5, flora_field 0.3, builder_camera 0.1 | |
| g_hand_1000 (builder) | 108 | 4.0 | 1.0 | 1.0 | 11.5 | 14.5 | 5.7 | 0.0 | perfbench 0.4, flora_field 0.3, builder 0.2, builder_toolbar 0.1 | |
| g_load_3000 (builder) | 44 | 9.0 | 1.0 | 1.0 | 13.8 | 8.4 | 7.7 | 0.0 | builder 2.2, perfbench 1.5, builder_camera 1.1, builder_toolbar 0.3 | |
| g_idle_3000 (builder) | 103 | 8.2 | 1.0 | 1.2 | 18.7 | 1.3 | 8.4 | 0.0 | builder 3.8, perfbench 0.4, builder_toolbar 0.3, flora_field 0.3 | |
| g_hand_3000 (builder) | 103 | 4.8 | 1.0 | 1.2 | 18.4 | 5.1 | 8.3 | 0.0 | perfbench 0.5, builder 0.4, builder_toolbar 0.3, flora_field 0.3 | |
| g_load_craft1002 (builder) | 11 | 10.2 | 0.9 | 1.1 | 11.7 | 9.0 | 8.8 | 0.0 | builder 3.1, perfbench 2.0, builder_camera 0.3, flora_field 0.3 | |
| g_idle_craft (builder) | 104 | 4.7 | 0.9 | 1.0 | 12.0 | 11.3 | 6.0 | 0.0 | builder 0.8, perfbench 0.4, flora_field 0.3, catalog_panel 0.1 | |
| g_launch_rollout (builder) | 39 | 9.9 | 0.8 | 1.1 | 11.3 | 8.2 | 6.1 | 0.0 | vessel_controller 1.8, flora_field 1.2, perfbench 0.8, climate 0.4 | |
| g_launch_pad (builder) | 55 | 7.2 | 0.2 | 1.4 | 11.3 | 8.8 | 4.3 | 0.0 | vessel_controller 1.5, flora_field 0.9, flight_hud 0.8, planet_camera 0.8 | |
| g_launch_release (builder) | 146 | 19.1 | 35.7 | 1.0 | 10.9 | 0.2 | 4.7 | 0.0 | flight_ops 7.5, vessel_controller 6.1, planet_camera 1.0, flight_hud 0.8 | |
| g_launch_settle (builder) | 316 | 18.1 | 29.1 | 1.0 | 10.6 | 0.2 | 4.4 | 0.0 | flight_ops 7.5, vessel_controller 5.4, planet_camera 1.0, flight_hud 0.8 | |
| a_onfoot30 (builder) | 21 | 5.0 | 0.9 | 0.6 | 4.8 | 18.0 | 2.0 | 0.0 | flora_field 1.6, perfbench 0.3, planet_walker 0.3, tool_belt 0.3 | |

### Top scripts (mean ms/frame, worst frame ms)

- **a_load** (base): perfbench 0.52 (max 4), far_bodies 0.36 (max 8), flora_field 0.36 (max 15), game_manager 0.23 (max 89), planet_camera 0.22 (max 2), dock_row 0.13 (max 2), base_facilities 0.12 (max 17), tool_belt 0.11 (max 2)
- **a_onfoot30** (base): flora_field 0.55 (max 3), perfbench 0.36 (max 3), tool_belt 0.36 (max 13), planet_camera 0.32 (max 1), objectives 0.32 (max 1), planet_walker 0.29 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **a_after30_until_ready** (base): 
- **b_dig_meadow** (base): perfbench 0.35 (max 1), objectives 0.35 (max 1), tool_belt 0.32 (max 1), planet_walker 0.31 (max 1), planet_camera 0.26 (max 1), flora_field 0.20 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **b_dig_rock** (base): perfbench 0.36 (max 1), objectives 0.35 (max 1), tool_belt 0.32 (max 1), planet_walker 0.31 (max 1), planet_camera 0.26 (max 1), flora_field 0.20 (max 1), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
- **f_map_onfoot** (base): orbit_map 0.57 (max 5), perfbench 0.31 (max 1), planet_walker 0.29 (max 1), flora_field 0.14 (max 1), far_bodies 0.11 (max 2), dock_row 0.07 (max 0), tool_belt 0.07 (max 1), weather 0.06 (max 0)
- **a_load** (rocket): perfbench 0.66 (max 5), flora_field 0.56 (max 21), game_manager 0.27 (max 89), planet_camera 0.27 (max 3), far_bodies 0.17 (max 12), tool_belt 0.17 (max 4), dock_row 0.16 (max 3), base_facilities 0.15 (max 17)
- **launch_load** (rocket): perfbench 0.80 (max 4), base_facilities 0.77 (max 20), climate 0.77 (max 3), flora_field 0.75 (max 19), far_bodies 0.61 (max 11), flight_hud 0.31 (max 4), planet_camera 0.31 (max 3), vessel_controller 0.23 (max 3)
- **launch_regrade** (rocket): 
- **c_ascent** (rocket): flora_field 0.41 (max 45), perfbench 0.37 (max 3), vessel_controller 0.25 (max 3), planet_camera 0.23 (max 3), flight_hud 0.21 (max 3), dock_row 0.12 (max 3), flight_ops 0.10 (max 3), far_bodies 0.09 (max 3)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.06, vessel_controller.groupKeysTick 0.03, vessel_controller.safetyTick 0.03, vessel_controller.waterTick 0.02, vessel_controller.aeroTick 0.02, vessel_controller.stressTick 0.02, flight_ops.survey 0.01, planet_camera.cinematic_tick 0.01
- **c_throttle_change** (rocket): flora_field 0.66 (max 5), perfbench 0.37 (max 2), vessel_controller 0.30 (max 1), flight_hud 0.23 (max 1), planet_camera 0.23 (max 1), dock_row 0.12 (max 0), flight_ops 0.11 (max 1), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.23, vessel_controller.groupKeysTick 0.12, vessel_controller.safetyTick 0.10, vessel_controller.waterTick 0.08, vessel_controller.aeroTick 0.07, vessel_controller.stressTick 0.06, flight_ops.survey 0.06, planet_camera.cinematic_tick 0.04
- **c_orbit_coast** (rocket): perfbench 0.38 (max 1), planet_camera 0.22 (max 1), vessel_controller 0.22 (max 1), flight_hud 0.21 (max 1), flora_field 0.15 (max 0), dock_row 0.14 (max 0), flight_ops 0.10 (max 1), far_bodies 0.10 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.06, vessel_controller.groupKeysTick 0.03, vessel_controller.safetyTick 0.03, vessel_controller.waterTick 0.02, flight_ops.survey 0.02, vessel_controller.stressTick 0.01, planet_camera.cinematic_tick 0.01, vessel_controller.controlsCard 0.01
- **f_map_flight** (rocket): orbit_map 0.65 (max 5), perfbench 0.31 (max 1), vessel_controller 0.14 (max 0), dock_row 0.12 (max 0), far_bodies 0.10 (max 1), flight_ops 0.09 (max 1), flora_field 0.08 (max 0), weather 0.06 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.safetyTick 0.02, flight_ops.survey 0.01, vessel_controller.groupKeysTick 0.01, vessel_controller.stressTick 0.01, planet_camera.cinematic_tick 0.01, vessel_controller.waterTick 0.01, planet_camera.chase_clip 0.01, vessel_controller.peripherals 0.00
- **a_onfoot30** (rocket): flora_field 1.22 (max 2), perfbench 0.36 (max 2), tool_belt 0.34 (max 1), planet_walker 0.32 (max 1), planet_camera 0.26 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 1.67, vessel_controller.groupKeysTick 1.10, vessel_controller.safetyTick 0.94, vessel_controller.waterTick 0.68, flight_ops.survey 0.57, vessel_controller.stressTick 0.55, vessel_controller.aeroTick 0.51, planet_camera.cinematic_tick 0.38
- **a_load** (plane): perfbench 0.64 (max 4), flora_field 0.54 (max 23), game_manager 0.27 (max 92), planet_camera 0.26 (max 2), far_bodies 0.17 (max 7), tool_belt 0.16 (max 3), dock_row 0.15 (max 2), base_facilities 0.14 (max 16)
- **launch_load** (plane): climate 1.12 (max 4), perfbench 0.83 (max 4), base_facilities 0.76 (max 18), far_bodies 0.56 (max 10), planet_camera 0.52 (max 8), flora_field 0.39 (max 4), flight_hud 0.36 (max 5), mineral_field 0.23 (max 13)
- **launch_regrade** (plane): 
- **d_takeoff** (plane): flora_field 1.50 (max 6), vessel_controller 0.85 (max 6), perfbench 0.70 (max 5), flight_hud 0.52 (max 3), planet_camera 0.43 (max 3), climate 0.38 (max 3), flight_ops 0.24 (max 3), dock_row 0.15 (max 2)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.20, vessel_controller.aeroTick 0.12, vessel_controller.r2Tick 0.12, vessel_controller.groupKeysTick 0.10, vessel_controller.safetyTick 0.08, vessel_controller.waterTick 0.06, vessel_controller.stressTick 0.06, vessel_controller.controlsCard 0.05
- **d_low_flight** (plane): perfbench 0.97 (max 21), vessel_controller 0.55 (max 2), flight_hud 0.45 (max 2), flora_field 0.41 (max 6), climate 0.28 (max 3), planet_camera 0.28 (max 1), flight_ops 0.21 (max 2), dock_row 0.14 (max 1)
  - Lua functions (inclusive ms/frame): vessel_controller.aeroTick 0.09, planet_camera.chase_clip 0.07, vessel_controller.groupKeysTick 0.07, vessel_controller.safetyTick 0.06, vessel_controller.waterTick 0.05, vessel_controller.controlsCard 0.05, vessel_controller.stressTick 0.05, vessel_controller.groupStrip 0.03
- **a_onfoot30** (plane): flora_field 1.23 (max 2), perfbench 0.37 (max 2), tool_belt 0.36 (max 1), planet_walker 0.32 (max 1), planet_camera 0.25 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 1.57, vessel_controller.aeroTick 1.55, vessel_controller.groupKeysTick 1.28, vessel_controller.safetyTick 1.06, vessel_controller.waterTick 0.87, vessel_controller.stressTick 0.85, vessel_controller.controlsCard 0.84, vessel_controller.groupStrip 0.57
- **a_load** (rover): perfbench 0.67 (max 4), flora_field 0.45 (max 18), game_manager 0.28 (max 97), planet_camera 0.27 (max 4), far_bodies 0.20 (max 13), base_facilities 0.15 (max 14), system_generator 0.14 (max 6), dock_row 0.14 (max 2)
- **launch_load** (rover): climate 1.07 (max 6), base_facilities 0.80 (max 27), perfbench 0.78 (max 4), far_bodies 0.72 (max 9), planet_camera 0.39 (max 7), flight_hud 0.31 (max 4), flora_field 0.29 (max 5), game_manager 0.24 (max 6)
- **launch_regrade** (rover): 
- **e_rover** (rover): vessel_controller 0.74 (max 2), flora_field 0.58 (max 5), flight_hud 0.46 (max 1), perfbench 0.45 (max 1), planet_camera 0.29 (max 1), flight_ops 0.13 (max 3), dock_row 0.12 (max 1), far_bodies 0.10 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.r2Tick 0.12, vessel_controller.waterTick 0.11, planet_camera.chase_clip 0.09, vessel_controller.groupKeysTick 0.09, vessel_controller.safetyTick 0.07, vessel_controller.aeroTick 0.06, vessel_controller.controlsCard 0.05, vessel_controller.stressTick 0.04
- **a_onfoot30** (rover): flora_field 1.24 (max 2), perfbench 0.37 (max 2), tool_belt 0.35 (max 1), planet_walker 0.32 (max 1), planet_camera 0.26 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.r2Tick 1.33, vessel_controller.waterTick 1.23, planet_camera.chase_clip 1.08, vessel_controller.groupKeysTick 1.04, vessel_controller.safetyTick 0.79, vessel_controller.aeroTick 0.72, vessel_controller.controlsCard 0.56, vessel_controller.stressTick 0.49
- **a_load** (builder): perfbench 0.63 (max 6), flora_field 0.48 (max 22), far_bodies 0.36 (max 10), game_manager 0.27 (max 92), planet_camera 0.24 (max 4), base_facilities 0.16 (max 19), tool_belt 0.14 (max 2), dock_row 0.13 (max 2)
- **g_enter** (builder): flora_field 1.29 (max 2), catalog_panel 1.26 (max 5), perfbench 0.49 (max 1), tool_belt 0.23 (max 0), planet_walker 0.22 (max 1), objectives 0.15 (max 0), far_bodies 0.11 (max 0), ocean 0.09 (max 0)
- **g_load_300** (builder): perfbench 1.93 (max 7), builder 1.37 (max 3), flora_field 1.29 (max 2), builder_camera 0.64 (max 2), builder_toolbar 0.23 (max 1), far_bodies 0.09 (max 0), dock_row 0.07 (max 0), weather 0.07 (max 0)
- **g_idle_300** (builder): flora_field 1.19 (max 3), builder 0.87 (max 3), perfbench 0.46 (max 1), catalog_panel 0.11 (max 3), far_bodies 0.10 (max 0), weather 0.08 (max 0), dock_row 0.08 (max 0), builder_camera 0.08 (max 2)
- **g_hand_300** (builder): perfbench 0.45 (max 1), flora_field 0.26 (max 1), builder 0.20 (max 0), catalog_panel 0.11 (max 3), far_bodies 0.10 (max 0), weather 0.08 (max 0), dock_row 0.08 (max 0), tool_belt 0.07 (max 0)
- **g_load_1000** (builder): builder 1.96 (max 13), perfbench 1.39 (max 16), builder_camera 0.55 (max 3), flora_field 0.27 (max 1), builder_toolbar 0.14 (max 1), far_bodies 0.09 (max 0), dock_row 0.08 (max 0), tool_belt 0.07 (max 0)
- **g_idle_1000** (builder): builder 2.09 (max 8), perfbench 0.47 (max 1), flora_field 0.27 (max 1), builder_camera 0.13 (max 2), catalog_panel 0.12 (max 3), builder_toolbar 0.11 (max 0), far_bodies 0.10 (max 0), dock_row 0.09 (max 1)
- **g_hand_1000** (builder): perfbench 0.44 (max 1), flora_field 0.26 (max 1), builder 0.20 (max 0), builder_toolbar 0.11 (max 0), catalog_panel 0.11 (max 3), far_bodies 0.10 (max 0), weather 0.08 (max 0), dock_row 0.08 (max 0)
- **g_load_3000** (builder): builder 2.15 (max 34), perfbench 1.38 (max 47), builder_camera 1.16 (max 7), builder_toolbar 0.30 (max 2), flora_field 0.28 (max 1), catalog_panel 0.12 (max 2), far_bodies 0.10 (max 0), weather 0.08 (max 0)
- **g_idle_3000** (builder): builder 3.81 (max 26), perfbench 0.45 (max 1), builder_toolbar 0.32 (max 1), flora_field 0.28 (max 1), catalog_panel 0.14 (max 4), far_bodies 0.10 (max 0), weather 0.08 (max 0), dock_row 0.08 (max 0)
- **g_hand_3000** (builder): perfbench 0.47 (max 3), builder 0.36 (max 0), builder_toolbar 0.30 (max 1), flora_field 0.29 (max 1), catalog_panel 0.12 (max 3), far_bodies 0.10 (max 0), weather 0.08 (max 0), dock_row 0.08 (max 0)
- **g_load_craft1002** (builder): builder 2.23 (max 32), perfbench 1.53 (max 19), builder_camera 0.58 (max 3), flora_field 0.29 (max 1), builder_toolbar 0.21 (max 2), catalog_panel 0.17 (max 2), far_bodies 0.09 (max 0), dock_row 0.08 (max 0)
- **g_idle_craft** (builder): builder 0.87 (max 7), perfbench 0.45 (max 1), flora_field 0.26 (max 1), builder_camera 0.12 (max 2), catalog_panel 0.12 (max 3), builder_toolbar 0.11 (max 0), far_bodies 0.10 (max 0), weather 0.08 (max 0)
- **g_launch_rollout** (builder): flora_field 2.14 (max 12), vessel_controller 1.77 (max 22), climate 1.24 (max 3), planet_camera 0.62 (max 6), perfbench 0.59 (max 13), flight_hud 0.41 (max 1), dock_row 0.16 (max 0), build_host 0.13 (max 12)
- **g_launch_pad** (builder): vessel_controller 1.75 (max 5), planet_camera 0.84 (max 2), flight_hud 0.72 (max 1), flora_field 0.69 (max 3), perfbench 0.39 (max 2), dock_row 0.20 (max 0), far_bodies 0.09 (max 0), objectives 0.09 (max 0)
  - Lua functions (inclusive ms/frame): planet_camera.chase_clip 0.62, vessel_controller.massSync 0.51, vessel_controller.aboardRecs 0.20, vessel_controller.controlsCard 0.12, vessel_controller.groupStrip 0.11, vessel_controller.groupKeysTick 0.09, vessel_controller.recoverValue 0.09, vessel_controller.stagedDv 0.04
- **g_launch_release** (builder): flight_ops 7.51 (max 32), vessel_controller 6.14 (max 32), planet_camera 0.98 (max 4), flight_hud 0.83 (max 1), perfbench 0.48 (max 1), flora_field 0.35 (max 1), comms 0.22 (max 6), dock_row 0.20 (max 0)
  - Lua functions (inclusive ms/frame): vessel_controller.aeroTick 1.75, flight_ops.fleetSync 1.60, vessel_controller.waterTick 1.00, vessel_controller.stressTick 0.97, planet_camera.chase_clip 0.69, vessel_controller.massSync 0.36, vessel_controller.aboardRecs 0.23, vessel_controller.recoverValue 0.16
- **g_launch_settle** (builder): flight_ops 7.49 (max 32), vessel_controller 5.37 (max 9), planet_camera 0.95 (max 4), flight_hud 0.82 (max 1), perfbench 0.51 (max 2), flora_field 0.35 (max 1), comms 0.21 (max 8), dock_row 0.19 (max 0)
  - Lua functions (inclusive ms/frame): flight_ops.fleetSync 1.47, vessel_controller.aeroTick 1.39, vessel_controller.stressTick 0.91, vessel_controller.waterTick 0.81, planet_camera.chase_clip 0.67, vessel_controller.massSync 0.31, vessel_controller.aboardRecs 0.23, vessel_controller.recoverValue 0.16
- **a_onfoot30** (builder): flora_field 1.55 (max 4), perfbench 0.38 (max 2), tool_belt 0.36 (max 1), planet_walker 0.33 (max 1), planet_camera 0.26 (max 1), objectives 0.22 (max 0), status_hud 0.11 (max 0), far_bodies 0.09 (max 0)
  - Lua functions (inclusive ms/frame): flight_ops.fleetSync 5.47, vessel_controller.aeroTick 5.44, planet_camera.chase_clip 3.67, vessel_controller.stressTick 3.37, vessel_controller.waterTick 3.13, vessel_controller.massSync 2.17, vessel_controller.aboardRecs 1.23, vessel_controller.recoverValue 0.76

### Hitches (frames >= 50 ms, the engine's own record): where the time went

- a_load (base): 9 hitches, 1722 ms in all — buckets assets 620, terrain 456, scripts 270, untimed 169, models 154; parts assetDecode 502, terrainLoad 391, terrainMeshing 53, sceneModels 51, sceneLoad 27
- a_onfoot30 (base): 5 hitches, 253 ms in all — buckets gpuWait 177, render 29, scripts 21, untimed 9, physics 6; parts renderPasses 25, physicsStatic 6, terrainMeshing 4, renderInstancing 3, terrainStreaming 1
- a_load (rocket): 6 hitches, 544 ms in all — buckets scripts 222, models 88, terrain 85, untimed 58, assets 40; parts terrainLoad 50, assetDecode 31, terrainMeshing 21, renderPasses 21, terrainShadow 13
- launch_load (rocket): 18 hitches, 1308 ms in all — buckets terrain 835, scripts 273, untimed 69, physics 42, render 41; parts terrainLoad 807, physicsStatic 42, renderPasses 36, terrainMeshing 21, renderInstancing 4
- c_ascent (rocket): 5 hitches, 318 ms in all — buckets scripts 164, untimed 53, render 53, terrain 12, physics 8; parts renderPasses 45, terrainMeshing 6, physicsStatic 5, renderInstancing 5, decalLay 5
- a_load (plane): 6 hitches, 542 ms in all — buckets scripts 193, terrain 123, models 82, untimed 40, assets 34; parts terrainLoad 52, terrainMeshing 42, assetDecode 24, physicsStatic 24, renderPasses 23
- launch_load (plane): 24 hitches, 1607 ms in all — buckets terrain 841, scripts 378, untimed 159, render 87, physics 42; parts terrainLoad 760, renderPasses 75, terrainMeshing 61, physicsStatic 40, renderInstancing 8
- d_takeoff (plane): 14 hitches, 1162 ms in all — buckets physics 711, scripts 206, untimed 95, render 81, terrain 24; parts physicsSweeps 391, physicsStatic 316, renderPasses 67, terrainMeshing 18, renderInstancing 11
- d_low_flight (plane): 1 hitches, 51 ms in all — buckets gpuWait 26, physics 8, scripts 6, render 5, untimed 3; parts physicsSweeps 8, renderPasses 4, scatterSettle 1, terrainStreaming 1, physicsStatic 1
- a_load (rover): 7 hitches, 669 ms in all — buckets scripts 256, terrain 139, models 86, untimed 63, render 45; parts terrainMeshing 65, terrainLoad 52, renderPasses 38, assetDecode 27, terrainShadow 15
- launch_load (rover): 22 hitches, 1424 ms in all — buckets terrain 867, scripts 293, untimed 109, render 70, gpuWait 31; parts terrainLoad 787, renderPasses 59, terrainMeshing 59, physicsStatic 11, renderInstancing 9
- e_rover (rover): 1 hitches, 50 ms in all — buckets gpuWait 22, render 7, physics 6, scripts 5, terrain 4; parts renderPasses 6, physicsSweeps 4, physicsStatic 2, decalLay 2, terrainMeshing 1
- a_load (builder): 7 hitches, 642 ms in all — buckets scripts 256, terrain 163, untimed 66, models 60, assets 38; parts terrainLoad 52, terrainMeshing 42, terrainEdits 28, assetDecode 28, renderPasses 27
- g_enter (builder): 1 hitches, 57 ms in all — buckets scripts 36, untimed 11, render 6, terrain 1, physics 1; parts renderPasses 5, terrainMeshing 1, renderInstancing 1, physicsStatic 1, sceneLoad 0
- g_load_1000 (builder): 1 hitches, 57 ms in all — buckets scripts 36, untimed 8, render 7, mirror 2, ui 2; parts renderPasses 5, renderInstancing 1, physicsStatic 1, terrainMeshing 1, renderCull 0
- g_load_3000 (builder): 1 hitches, 118 ms in all — buckets scripts 93, untimed 11, render 8, ui 2, mirror 2; parts renderPasses 6, renderInstancing 1, physicsStatic 1, terrainShadow 0, terrainOccluders 0
- g_idle_3000 (builder): 2 hitches, 120 ms in all — buckets render 46, scripts 34, untimed 22, ui 6, assets 3; parts renderPasses 22, renderInstancing 20, physicsStatic 2, terrainMeshing 1, renderCull 1
- g_load_craft1002 (builder): 1 hitches, 102 ms in all — buckets scripts 59, untimed 22, render 9, mirror 3, ui 3; parts renderPasses 8, renderInstancing 2, physicsStatic 1, terrainStreaming 1, terrainShadow 0
- g_launch_rollout (builder): 2 hitches, 130 ms in all — buckets scripts 70, mirror 28, render 15, untimed 11, scatter 2; parts renderPasses 12, renderInstancing 3, scatterSettle 1, physicsPairs 0, assemblyRebuild 0
- g_launch_release (builder): 146 hitches, 10448 ms in all — buckets physics 5216, scripts 2717, render 1339, untimed 680, assets 117; parts physicsStatic 5161, renderPasses 862, renderInstancing 420, physicsSweeps 42, terrainMeshing 29
- g_launch_settle (builder): 316 hitches, 20019 ms in all — buckets physics 9194, scripts 5584, render 2821, untimed 1402, assets 248; parts physicsStatic 9092, renderPasses 1810, renderInstancing 889, physicsSweeps 74, terrainMeshing 62

### Worst frames (engine hitch records; scripts from the inverted means, approximate)

- a_load #1: 566 ms at +1.2 s — buckets assets 401, scripts 64, models 51; scripts game_manager 1, tool_belt 0, perfbench 0; parts assetDecode 356, sceneModels 51, sceneLoad 27
- a_load #2: 432 ms at +1.3 s — buckets terrain 403, untimed 10, scripts 9; scripts facility_menu 1, perfbench 1, tool_belt 0; parts terrainLoad 391, terrainMeshing 12, assetUpload 2
- a_load #3: 173 ms at +0.3 s — buckets assets 150, models 22, render 2; scripts ; parts assetDecode 146, assetUpload 2, renderPasses 2
- a_onfoot30 #1: 51 ms at +22.1 s — buckets gpuWait 35, render 6, scripts 5; scripts flora_field 1, tool_belt 1, perfbench 0; parts renderPasses 5, physicsStatic 1, terrainStreaming 1
- a_onfoot30 #2: 51 ms at +22.6 s — buckets gpuWait 36, render 5, scripts 4; scripts perfbench 0, objectives 0, planet_camera 0; parts renderPasses 5, physicsStatic 1, terrainMeshing 1
- a_onfoot30 #3: 51 ms at +22.3 s — buckets gpuWait 33, render 6, scripts 5; scripts planet_camera 1, flora_field 1, perfbench 0; parts renderPasses 5, physicsStatic 1, terrainMeshing 1
- a_load #1: 120 ms at +0.2 s — buckets scripts 64, assets 35, untimed 15; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 31, assetUpload 4, renderPasses 3
- a_load #2: 98 ms at +11.9 s — buckets models 53, scripts 19, terrain 7; scripts planet_walker 7, perfbench 2, climate 2; parts renderPasses 6, terrainMeshing 3, terrainShadow 3
- a_load #3: 96 ms at +0.9 s — buckets scripts 91, untimed 2, terrain 1; scripts game_manager 89, perfbench 0, planet_camera 0; parts terrainShadow 1, terrainShadowAtlas 1, renderPasses 1
- launch_load #1: 115 ms at +1.3 s — buckets terrain 94, scripts 12, render 3; scripts objectives 2, planet_walker 2, perfbench 1; parts terrainLoad 94, renderPasses 3, renderInstancing 0
- launch_load #2: 104 ms at +0.5 s — buckets terrain 78, untimed 12, scripts 9; scripts dock_row 2, perfbench 1, tool_belt 0; parts terrainLoad 78, renderPasses 3, renderInstancing 0
- launch_load #3: 101 ms at +0.6 s — buckets terrain 83, scripts 10, untimed 4; scripts flight_ops 2, perfbench 1, tool_belt 0; parts terrainLoad 83, renderPasses 1, renderInstancing 0
- c_ascent #1: 92 ms at +0.5 s — buckets scripts 62, render 11, untimed 10; scripts flora_field 45, climate 3, flight_hud 3; parts renderPasses 10, terrainMeshing 1, renderInstancing 1
- c_ascent #2: 58 ms at +1.2 s — buckets scripts 23, untimed 11, render 10; scripts flora_field 5, dock_row 3, climate 3; parts renderPasses 9, terrainMeshing 4, decalLay 3
- c_ascent #3: 58 ms at +0.8 s — buckets scripts 28, render 12, untimed 11; scripts flora_field 12, vessel_controller 3, climate 2; parts renderPasses 10, renderInstancing 2, scatterSettle 1
- a_load #1: 120 ms at +0.2 s — buckets scripts 64, assets 28, untimed 18; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 24, assetUpload 4, renderPasses 3
- a_load #2: 104 ms at +11.8 s — buckets models 54, terrain 26, scripts 11; scripts climate 2, planet_walker 2, perfbench 1; parts terrainMeshing 12, terrainStreaming 12, renderPasses 2
- a_load #3: 99 ms at +0.8 s — buckets scripts 94, untimed 2, terrain 1; scripts game_manager 92, perfbench 0, planet_camera 0; parts terrainShadow 1, terrainShadowAtlas 1, renderPasses 1
- launch_load #1: 106 ms at +3.5 s — buckets untimed 27, scripts 22, terrain 21; scripts planet_camera 8, base_facilities 6, climate 2; parts terrainMeshing 15, physicsStatic 14, renderPasses 9
- launch_load #2: 103 ms at +0.6 s — buckets terrain 86, scripts 10, render 3; scripts objectives 2, perfbench 1, tool_belt 0; parts terrainLoad 85, renderPasses 3, terrainMeshing 2
- launch_load #3: 102 ms at +0.5 s — buckets terrain 85, scripts 9, untimed 4; scripts perfbench 2, tool_belt 0, game_manager 0; parts terrainLoad 85, renderPasses 1, renderInstancing 0
- d_takeoff #1: 169 ms at +10.3 s — buckets physics 143, scripts 12, render 4; scripts vessel_controller 4, flora_field 3, perfbench 1; parts physicsSweeps 85, physicsStatic 58, renderPasses 4
- d_takeoff #2: 144 ms at +10.1 s — buckets physics 117, scripts 12, untimed 7; scripts vessel_controller 3, flora_field 3, mineral_field 2; parts physicsSweeps 69, physicsStatic 48, renderPasses 4
- d_takeoff #3: 112 ms at +10.4 s — buckets physics 86, scripts 15, render 5; scripts vessel_controller 4, flora_field 4, perfbench 1; parts physicsSweeps 52, physicsStatic 33, renderPasses 4
- d_low_flight #1: 51 ms at +1.3 s — buckets gpuWait 26, physics 8, scripts 6; scripts flora_field 1, vessel_controller 1, flight_hud 1; parts physicsSweeps 8, renderPasses 4, scatterSettle 1
- a_load #1: 120 ms at +0.2 s — buckets scripts 64, assets 31, untimed 15; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 27, renderPasses 4, assetUpload 4
- a_load #2: 117 ms at +12.3 s — buckets models 34, terrain 33, scripts 21; scripts climate 3, weather 2, dock_row 2; parts terrainMeshing 28, physicsStatic 7, terrainShadow 3
- a_load #3: 105 ms at +12.2 s — buckets models 50, scripts 28, terrain 10; scripts tool_belt 7, weather 3, perfbench 3; parts renderPasses 6, terrainShadow 5, terrainShadowAtlas 5
- launch_load #1: 102 ms at +0.8 s — buckets terrain 85, scripts 10, render 3; scripts tool_belt 2, perfbench 1, planet_camera 0; parts terrainLoad 85, renderPasses 3, renderInstancing 0
- launch_load #2: 96 ms at +0.5 s — buckets terrain 85, scripts 6, untimed 2; scripts perfbench 2, tool_belt 0, game_manager 0; parts terrainLoad 85, renderPasses 1, renderInstancing 0
- launch_load #3: 89 ms at +0.7 s — buckets terrain 78, untimed 5, scripts 3; scripts perfbench 1, game_manager 0, tool_belt 0; parts terrainLoad 78, renderPasses 1, renderInstancing 0
- e_rover #1: 50 ms at +30.2 s — buckets gpuWait 22, render 7, physics 6; scripts vessel_controller 1, flight_hud 1, perfbench 1; parts renderPasses 6, physicsSweeps 4, physicsStatic 2
- a_load #1: 124 ms at +0.2 s — buckets scripts 65, assets 32, untimed 18; scripts game_manager 1, tool_belt 0, planet_camera 0; parts assetDecode 28, assetUpload 4, renderPasses 3
- a_load #2: 102 ms at +0.3 s — buckets terrain 66, scripts 13, untimed 8; scripts perfbench 1, dock_row 0, tool_belt 0; parts terrainLoad 52, terrainMeshing 14, renderPasses 6
- a_load #3: 99 ms at +0.9 s — buckets scripts 94, untimed 2, render 1; scripts game_manager 92, perfbench 0, planet_camera 0; parts terrainShadow 1, terrainShadowAtlas 1, renderPasses 1
- g_enter #1: 57 ms at +0.1 s — buckets scripts 36, untimed 11, render 6; scripts catalog_panel 5, flora_field 1, perfbench 0; parts renderPasses 5, terrainMeshing 1, renderInstancing 1
- g_load_1000 #1: 57 ms at +0.1 s — buckets scripts 36, untimed 8, render 7; scripts perfbench 16, builder 13, builder_camera 3; parts renderPasses 5, renderInstancing 1, physicsStatic 1
- g_load_3000 #1: 118 ms at +0.1 s — buckets scripts 93, untimed 11, render 8; scripts perfbench 47, builder 34, builder_camera 7; parts renderPasses 6, renderInstancing 1, physicsStatic 1
- g_idle_3000 #1: 61 ms at +0.3 s — buckets scripts 29, render 15, untimed 8; scripts builder 26, perfbench 0, builder_toolbar 0; parts renderPasses 8, renderInstancing 7, physicsStatic 1
- g_idle_3000 #2: 59 ms at +3.2 s — buckets render 31, untimed 14, scripts 5; scripts builder 2, perfbench 0, builder_toolbar 0; parts renderPasses 14, renderInstancing 13, physicsStatic 1
- g_load_craft1002 #1: 102 ms at +0.1 s — buckets scripts 59, untimed 22, render 9; scripts builder 32, perfbench 19, builder_camera 3; parts renderPasses 8, renderInstancing 2, physicsStatic 1
- g_launch_rollout #1: 65 ms at +1.4 s — buckets scripts 30, mirror 20, render 8; scripts vessel_controller 16, missions 5, flora_field 3; parts renderPasses 6, renderInstancing 2, assemblyRebuild 0
- g_launch_rollout #2: 65 ms at +1.1 s — buckets scripts 40, mirror 9, render 7; scripts vessel_controller 22, planet_camera 2, perfbench 0; parts renderPasses 6, renderInstancing 1, scatterSettle 1
- g_launch_release #1: 319 ms at +0.6 s — buckets physics 233, scripts 61, render 11; scripts vessel_controller 24, flight_ops 24, missions 5; parts physicsStatic 230, renderPasses 8, renderInstancing 3
- g_launch_release #2: 300 ms at +1.5 s — buckets physics 233, scripts 45, render 11; scripts vessel_controller 32, flight_ops 5, planet_camera 3; parts physicsStatic 231, renderPasses 7, renderInstancing 3
- g_launch_release #3: 299 ms at +1.2 s — buckets physics 233, scripts 42, render 11; scripts vessel_controller 24, comms 6, flight_ops 5; parts physicsStatic 230, renderPasses 7, renderInstancing 3
- g_launch_settle #1: 94 ms at +10.6 s — buckets scripts 46, physics 29, render 9; scripts flight_ops 29, vessel_controller 7, missions 6; parts physicsStatic 29, renderPasses 6, renderInstancing 3
- g_launch_settle #2: 93 ms at +0.3 s — buckets scripts 46, physics 29, render 10; scripts flight_ops 29, vessel_controller 7, missions 5; parts physicsStatic 29, renderPasses 7, renderInstancing 3
- g_launch_settle #3: 90 ms at +9.6 s — buckets scripts 45, physics 29, render 9; scripts flight_ops 32, vessel_controller 9, flight_hud 1; parts physicsStatic 28, renderPasses 6, renderInstancing 3

### Notes and counts

- a_load: grading=13.831, loaded=13.108, loading=1.161, reveal=18.8, sited=18.563 | draws 53 (max 387), nodes 188, chunks 429, props 10, decals 0, rays/frame 2 (0.01 ms), mirror rebuilds 0.00, gpu 9.5 ms (matter / terrain 4.0, opaque + lighting 2.7, glass 1.4, post (AO, bloom, blur…) 0.7), parts renderPasses 1.85, assetDecode 0.33, terrainLoad 0.25, renderInstancing 0.20
- a_onfoot30:  | draws 746 (max 821), nodes 517, chunks 3114, props 31, decals 0, rays/frame 6 (0.12 ms), mirror rebuilds 0.00, gpu 26.0 ms (opaque + lighting 17.4, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 4.48, physicsStatic 0.80, renderInstancing 0.53, terrainMeshing 0.43
- a_after30_until_ready:  | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- b_dig_meadow: biome=shore, decals=0->0 | draws 784 (max 784), nodes 551, chunks 6015, props 97, decals 0, rays/frame 8 (0.10 ms), mirror rebuilds 0.00, gpu 19.9 ms (opaque + lighting 11.5, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 4.71, renderInstancing 0.63, physicsStatic 0.47, terrainMeshing 0.19
- b_dig_rock: biome=shore, decals=0->0 | draws 784 (max 784), nodes 551, chunks 6015, props 97, decals 0, rays/frame 8 (0.10 ms), mirror rebuilds 0.00, gpu 19.9 ms (opaque + lighting 11.5, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 4.68, renderInstancing 0.63, terrainMeshing 0.18, terrainStreaming 0.09
- f_map_onfoot:  | draws 48 (max 785), nodes 549, chunks 6015, props 2, decals 0, rays/frame 6 (0.04 ms), mirror rebuilds 0.00, gpu 3.5 ms (matter / terrain 1.9, post (AO, bloom, blur…) 0.5, opaque + lighting 0.4, sky / environment 0.4), parts renderPasses 1.50, renderInstancing 0.20, terrainStreaming 0.08, outsideFrame 0.03
- a_load: grading=12.326, loaded=11.614, loading=0.212, reveal=18.991, sited=18.731 | draws 100 (max 538), nodes 212, chunks 489, props 17, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 10.9 ms (matter / terrain 4.3, opaque + lighting 3.4, glass 1.4, post (AO, bloom, blur…) 0.7), parts renderPasses 2.41, renderInstancing 0.24, terrainMeshing 0.23, terrainEdits 0.21
- launch_load:  | draws 61 (max 211), nodes 251, chunks 287, props 22, decals 0, rays/frame 1 (0.00 ms), mirror rebuilds 0.00, gpu 14.2 ms (opaque + lighting 7.4, matter / terrain 4.1, glass 1.0, post (AO, bloom, blur…) 0.7), parts terrainLoad 4.67, renderPasses 2.87, terrainMeshing 0.77, terrainShadow 0.43
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- c_ascent: apo=None, peri=None, phase=orbit, secs=38.289, world=Naolol R922 | draws 126 (max 575), nodes 639, chunks 5188, props 9, decals 1, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 6.6 ms (matter / terrain 2.5, opaque + lighting 2.4, post (AO, bloom, blur…) 0.6, sky / environment 0.4), parts renderPasses 2.01, physicsSweeps 0.95, renderInstancing 0.62, terrainMeshing 0.40
- c_throttle_change:  | draws 234 (max 575), nodes 615, chunks 4667, props 13, decals 1, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 10.0 ms (opaque + lighting 4.8, matter / terrain 3.5, post (AO, bloom, blur…) 0.6, sky / environment 0.3), parts renderPasses 2.45, physicsSweeps 1.18, renderInstancing 0.59, terrainMeshing 0.40
- c_orbit_coast:  | draws 36 (max 36), nodes 650, chunks 6834, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 3.9 ms (matter / terrain 2.2, post (AO, bloom, blur…) 0.6, sky / environment 0.5, opaque + lighting 0.4), parts renderPasses 1.18, physicsSweeps 0.98, renderInstancing 0.69, terrainMeshing 0.41
- f_map_flight:  | draws 53 (max 55), nodes 596, chunks 6901, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 3.5 ms (matter / terrain 2.1, post (AO, bloom, blur…) 0.5, sky / environment 0.5, opaque + lighting 0.1), parts renderPasses 1.47, physicsSweeps 0.48, renderInstancing 0.27, terrainStreaming 0.11
- a_onfoot30:  | draws 640 (max 743), nodes 449, chunks 1425, props 25, decals 0, rays/frame 7 (0.09 ms), mirror rebuilds 0.00, gpu 23.6 ms (opaque + lighting 14.3, matter / terrain 6.4, sun shadow map 0.9, post (AO, bloom, blur…) 0.8), parts renderPasses 3.99, physicsStatic 0.91, terrainMeshing 0.45, terrainStreaming 0.44
- a_load: grading=12.384, loaded=11.7, loading=0.211, reveal=19.295, sited=19.02 | draws 82 (max 476), nodes 206, chunks 274, props 23, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 11.5 ms (matter / terrain 4.3, opaque + lighting 4.3, glass 1.4, post (AO, bloom, blur…) 0.7), parts renderPasses 2.24, renderInstancing 0.23, terrainMeshing 0.18, physicsStatic 0.16
- launch_load:  | draws 98 (max 366), nodes 233, chunks 316, props 2, decals 0, rays/frame 1 (0.00 ms), mirror rebuilds 0.00, gpu 13.8 ms (opaque + lighting 5.8, matter / terrain 4.2, glass 2.1, post (AO, bloom, blur…) 0.7), parts terrainLoad 4.17, renderPasses 3.06, terrainMeshing 0.84, terrainShadow 0.41
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- d_takeoff: liftoff_s=10.692 | draws 589 (max 751), nodes 591, chunks 1407, props 19, decals 0, rays/frame 1 (0.15 ms), mirror rebuilds 0.00, gpu 22.0 ms (opaque + lighting 12.9, matter / terrain 6.2, post (AO, bloom, blur…) 0.8, depth prepass 0.8), parts physicsSweeps 6.42, renderPasses 3.73, physicsStatic 3.30, terrainMeshing 0.71
- d_low_flight: V_end=93.46, agl_end=0 | draws 389 (max 709), nodes 681, chunks 3359, props 97, decals 0, rays/frame 5 (0.57 ms), mirror rebuilds 0.00, gpu 21.5 ms (opaque + lighting 13.2, matter / terrain 6.2, post (AO, bloom, blur…) 0.6, glass 0.4), parts renderPasses 3.67, physicsSweeps 3.46, terrainMeshing 0.67, renderInstancing 0.62
- a_onfoot30:  | draws 573 (max 662), nodes 457, chunks 1337, props 24, decals 0, rays/frame 8 (0.11 ms), mirror rebuilds 0.00, gpu 27.5 ms (opaque + lighting 19.0, matter / terrain 6.3, post (AO, bloom, blur…) 0.7, sun shadow map 0.6), parts renderPasses 3.78, physicsStatic 0.98, terrainStreaming 0.61, renderInstancing 0.40
- a_load: grading=12.636, loaded=11.963, loading=0.213, reveal=17.772, sited=17.499 | draws 62 (max 404), nodes 197, chunks 457, props 12, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 10.3 ms (matter / terrain 4.2, opaque + lighting 3.1, glass 1.5, post (AO, bloom, blur…) 0.7), parts renderPasses 2.27, renderInstancing 0.25, terrainMeshing 0.20, physicsStatic 0.12
- launch_load:  | draws 88 (max 317), nodes 229, chunks 318, props 2, decals 0, rays/frame 1 (0.00 ms), mirror rebuilds 0.00, gpu 13.0 ms (opaque + lighting 5.4, matter / terrain 4.2, glass 1.6, post (AO, bloom, blur…) 0.7), parts terrainLoad 4.05, renderPasses 2.94, terrainMeshing 0.75, terrainShadow 0.48
- launch_regrade: secs=0 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts 
- e_rover: maxFromBase=352.944 | draws 794 (max 953), nodes 633, chunks 3367, props 303, decals 23, rays/frame 0 (0.04 ms), mirror rebuilds 0.00, gpu 27.5 ms (opaque + lighting 17.9, matter / terrain 6.1, post (AO, bloom, blur…) 0.8, sun shadow map 0.8), parts renderPasses 5.16, physicsSweeps 1.40, physicsStatic 1.18, renderInstancing 0.63
- a_onfoot30:  | draws 508 (max 606), nodes 450, chunks 1272, props 24, decals 0, rays/frame 8 (0.11 ms), mirror rebuilds 0.00, gpu 26.9 ms (opaque + lighting 18.3, matter / terrain 6.4, post (AO, bloom, blur…) 0.7, sun shadow map 0.5), parts renderPasses 3.73, physicsStatic 0.97, terrainStreaming 0.59, renderInstancing 0.39
- a_load: grading=12.682, loaded=11.946, loading=0.217, reveal=18.225, sited=17.971 | draws 57 (max 390), nodes 194, chunks 444, props 17, decals 0, rays/frame 2 (0.02 ms), mirror rebuilds 0.00, gpu 10.6 ms (matter / terrain 4.2, opaque + lighting 3.4, glass 1.5, post (AO, bloom, blur…) 0.7), parts renderPasses 2.15, terrainEdits 0.23, renderInstancing 0.23, terrainMeshing 0.20
- g_enter:  | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts renderPasses 4.19, physicsStatic 0.72, renderInstancing 0.58, terrainMeshing 0.38
- g_load_300: load_s=0.14, parts=300 | draws 0 (max 0), nodes 0, chunks 0, props 0, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu -1.0 ms (), parts renderPasses 4.36, renderInstancing 1.36, physicsStatic 0.95, terrainMeshing 0.38
- g_idle_300:  | draws 776 (max 837), nodes 1400, chunks 2032, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 36.5 ms (opaque + lighting 27.0, matter / terrain 6.4, sun shadow map 1.0, post (AO, bloom, blur…) 0.9), parts renderPasses 4.67, renderInstancing 1.60, physicsStatic 0.94, terrainMeshing 0.41
- g_hand_300:  | draws 850 (max 852), nodes 1483, chunks 2457, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 36.6 ms (opaque + lighting 27.0, matter / terrain 6.4, sun shadow map 1.0, post (AO, bloom, blur…) 0.9), parts renderPasses 5.04, renderInstancing 1.71, physicsStatic 0.89, terrainMeshing 0.44
- g_load_1000: load_s=0.593, parts=1000 | draws 855 (max 855), nodes 1762, chunks 2774, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 36.9 ms (opaque + lighting 27.5, matter / terrain 6.3, sun shadow map 1.0, post (AO, bloom, blur…) 0.9), parts renderPasses 5.03, renderInstancing 2.19, physicsStatic 0.88, terrainMeshing 0.45
- g_idle_1000:  | draws 859 (max 862), nodes 2180, chunks 3003, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 37.5 ms (opaque + lighting 27.7, matter / terrain 6.4, sun shadow map 1.1, depth prepass 1.0), parts renderPasses 5.71, renderInstancing 3.02, physicsStatic 0.92, terrainMeshing 0.46
- g_hand_1000:  | draws 865 (max 866), nodes 2183, chunks 3434, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 37.5 ms (opaque + lighting 27.6, matter / terrain 6.4, sun shadow map 1.1, depth prepass 1.0), parts renderPasses 5.56, renderInstancing 2.96, physicsStatic 0.91, terrainMeshing 0.48
- g_load_3000: load_s=1.945, parts=3000 | draws 866 (max 866), nodes 2602, chunks 3789, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 38.8 ms (opaque + lighting 28.9, matter / terrain 6.4, sun shadow map 1.1, depth prepass 1.1), parts renderPasses 6.00, renderInstancing 4.02, physicsStatic 0.95, terrainMeshing 0.47
- g_idle_3000:  | draws 866 (max 866), nodes 4182, chunks 4076, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 38.7 ms (opaque + lighting 28.2, matter / terrain 6.4, depth prepass 1.4, sun shadow map 1.3), parts renderPasses 7.12, renderInstancing 6.48, physicsStatic 0.96, terrainMeshing 0.47
- g_hand_3000:  | draws 866 (max 866), nodes 4183, chunks 4484, props 18, decals 0, rays/frame 1 (0.04 ms), mirror rebuilds 0.00, gpu 38.7 ms (opaque + lighting 28.2, matter / terrain 6.4, depth prepass 1.4, sun shadow map 1.3), parts renderPasses 6.84, renderInstancing 6.36, physicsStatic 0.94, terrainMeshing 0.48
- g_load_craft1002: load_s=0.613, parts=1002 | draws 883 (max 883), nodes 1650, chunks 4782, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 37.2 ms (opaque + lighting 27.2, matter / terrain 6.4, sun shadow map 1.2, depth prepass 1.2), parts renderPasses 6.14, renderInstancing 2.21, physicsStatic 0.93, terrainMeshing 0.47
- g_idle_craft:  | draws 883 (max 883), nodes 2193, chunks 5041, props 18, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 35.9 ms (opaque + lighting 26.2, matter / terrain 6.4, sun shadow map 1.1, depth prepass 0.9), parts renderPasses 5.97, renderInstancing 2.71, physicsStatic 0.87, terrainMeshing 0.46
- g_launch_rollout: secs=3.38 | draws 776 (max 883), nodes 1807, chunks 5387, props 87, decals 0, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 32.2 ms (opaque + lighting 23.1, matter / terrain 6.3, sun shadow map 0.9, depth prepass 0.8), parts renderPasses 6.08, renderInstancing 2.56, terrainMeshing 0.40, physicsStatic 0.26
- g_launch_pad:  | draws 760 (max 763), nodes 1676, chunks 5955, props 123, decals 16, rays/frame 0 (0.00 ms), mirror rebuilds 0.00, gpu 32.2 ms (opaque + lighting 23.4, matter / terrain 6.3, sun shadow map 0.8, depth prepass 0.7), parts renderPasses 6.38, renderInstancing 2.80, terrainMeshing 0.37, decalLay 0.36
- g_launch_release:  | draws 761 (max 761), nodes 1672, chunks 6160, props 121, decals 40, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 29.8 ms (opaque + lighting 19.9, matter / terrain 5.2, depth prepass 2.0, sun shadow map 1.0), parts physicsStatic 35.35, renderPasses 5.91, renderInstancing 2.88, physicsSweeps 0.28
- g_launch_settle:  | draws 761 (max 761), nodes 1673, chunks 6160, props 122, decals 40, rays/frame 0 (0.01 ms), mirror rebuilds 0.00, gpu 23.2 ms (opaque + lighting 10.3, depth prepass 3.9, matter / terrain 3.5, sun shadow map 2.7), parts physicsStatic 28.77, renderPasses 5.73, renderInstancing 2.81, physicsSweeps 0.23
- a_onfoot30:  | draws 463 (max 537), nodes 451, chunks 1033, props 26, decals 0, rays/frame 7 (0.10 ms), mirror rebuilds 0.00, gpu 31.4 ms (opaque + lighting 22.2, matter / terrain 6.4, sun shadow map 0.9, post (AO, bloom, blur…) 0.7), parts renderPasses 3.70, physicsStatic 1.19, terrainStreaming 0.60, terrainMeshing 0.39

## Rover drive repeats (p50 / p95 / frames over 33 ms, in run order)

- rc22: 28.8 / 36.8 / 349; then 33.7 / 44.1 / 681
- rc25: 29.6 / 41.0 / 506; then 25.5 / 34.7 / 140

Reading: parity within run-to-run spread. Outdoors on both engines the frame is GPU-bound: gpu 26–35 ms a frame driving (opaque + lighting 16–24, matter/terrain ~6; ~750 draws, ~3,000 chunk slots), ~25 ms on foot at the base, against 18–21 ms of engine work. Plane take-off physics 9.9 (rc25) vs 11.9 ms (rc22); the 1,002-part release never settles on either (pre-rc27).
