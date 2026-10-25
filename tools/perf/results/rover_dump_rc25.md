Engine 0.117.0-rc25 (~/.local/share/floptle/versions/0.117.0-rc25/floptle), XWayland, vsync Off, silent; load avg before/after: 14.59, 21.19, 37.29 / 12.34, 18.98, 35.26; 2026-10-25 17:30.
Save: a copy of the player's slot1 (seed 1510406233, Zorosia R 799, scale 4, played 180); `USERSAVE=1 BENCH_PARAMS='("dump", 1.0)' tools/perf/bench.sh 0.117.0-rc25 park` (perfbench.lua park mode, dump=1): the 4-wheel probe rover rolled out on the runway, released, brakes on, 10 s, then the dump.

```
PB   18.30 PARK brakes: true true true true
PB   18.30 PARK rover released: 6 parts, |v| 0.074, body |v| 347.2, anchored false, asleep false, wake settling
PB   28.31 DUMP ---- static, after 10 s parked and braked ----
PB   28.31 DUMP planet Zorosia R 799.0 mu 5.84e+06: g at the rover 9.7096 m/s2 (mu/R^2 9.1484), altitude -23.43 m over R, planet |v| 347.22 m/s (5.787 m/tick)
PB   28.31 DUMP chassis assembly.info: mass 0.5920000076293945 parts 6 grounded true anchored false asleep false wake settling |v| 0.0774 angVel 0.0241 carry 5.787; node.asleep false
PB   28.31 DUMP chassis root: mass 1.0000 radius 0.500 (world 0.500) half 0.500/0.500/0.500 (world 0.500/0.500/0.500) shape 0 friction 0.70 restitution 0.05 kinematic false
PB   28.31 DUMP tyre 1 (WheelTyreM uid 2): Solar set otherAnchor (hull) (0.660 0.400 0.770) r 0.400 steer0 0.0 rs -1; wcfg spring 1 damper 1 motor 1 brake 1 friction 1; motor torque 1.7818437057902723; brakes true
PB   28.31 DUMP tyre 1 rigidbody: mass 0.0720 radius 0.400 (world 0.400) half 0.400/0.400/0.400 (world 0.400/0.400/0.400) shape 0 friction 0.70 restitution 0.00 kinematic false; grounded true asleep false wake settling |v| 0.1804
PB   28.31 DUMP tyre 1 joint (engine): stiffness 8.669 damping 0.700 maxForce 3.5637 motor 1 motorSpeed 0.0000 steer 0.00 force 2.87311 position 1.126 speed 0.977 length -1.000 limit 0 broken 0 (otherAnchor/axis: not readable from Lua, Solar's above)
PB   28.31 DUMP tyre 1 ground: PartWheelM at 0.0374 m below the centre (radius 0.400: SUNK by 0.3626 m), normal (0.0586 -0.9413 0.3324)
PB   28.31 DUMP tyre 2 (WheelTyreM uid 3): Solar set otherAnchor (hull) (0.660 0.400 -0.770) r 0.400 steer0 0.0 rs -1; wcfg spring 1 damper 1 motor 1 brake 1 friction 1; motor torque 1.7818437057902723; brakes true
PB   28.31 DUMP tyre 2 rigidbody: mass 0.0720 radius 0.400 (world 0.400) half 0.400/0.400/0.400 (world 0.400/0.400/0.400) shape 0 friction 0.70 restitution 0.00 kinematic false; grounded true asleep false wake settling |v| 0.1319
PB   28.31 DUMP tyre 2 joint (engine): stiffness 8.669 damping 0.700 maxForce 3.5637 motor 1 motorSpeed 0.0000 steer 0.00 force 2.39183 position 0.845 speed -3.711 length -1.000 limit 0 broken 0 (otherAnchor/axis: not readable from Lua, Solar's above)
PB   28.31 DUMP tyre 2 ground: Zorosia at 0.3999 m below the centre (radius 0.400: SUNK by 0.0001 m), normal (0.8375 -0.1570 -0.5234)
PB   28.31 DUMP tyre 3 (WheelTyreM uid 4): Solar set otherAnchor (hull) (-0.660 0.400 0.770) r 0.400 steer0 0.0 rs -1; wcfg spring 1 damper 1 motor 1 brake 1 friction 1; motor torque 1.7818437057902723; brakes true
PB   28.31 DUMP tyre 3 rigidbody: mass 0.0720 radius 0.400 (world 0.400) half 0.400/0.400/0.400 (world 0.400/0.400/0.400) shape 0 friction 0.70 restitution 0.00 kinematic false; grounded true asleep false wake settling |v| 0.1282
PB   28.31 DUMP tyre 3 joint (engine): stiffness 8.669 damping 0.700 maxForce 3.5637 motor 1 motorSpeed 0.0000 steer 0.00 force 2.37508 position 0.847 speed -3.982 length -1.000 limit 0 broken 0 (otherAnchor/axis: not readable from Lua, Solar's above)
PB   28.31 DUMP tyre 3 ground: PartWheelM at 0.0325 m below the centre (radius 0.400: SUNK by 0.3675 m), normal (0.0586 -0.9413 0.3324)
PB   28.31 DUMP tyre 4 (WheelTyreM uid 5): Solar set otherAnchor (hull) (-0.660 0.400 -0.770) r 0.400 steer0 0.0 rs -1; wcfg spring 1 damper 1 motor 1 brake 1 friction 1; motor torque 1.7818437057902723; brakes true
PB   28.31 DUMP tyre 4 rigidbody: mass 0.0720 radius 0.400 (world 0.400) half 0.400/0.400/0.400 (world 0.400/0.400/0.400) shape 0 friction 0.70 restitution 0.00 kinematic false; grounded true asleep false wake settling |v| 0.1852
PB   28.31 DUMP tyre 4 joint (engine): stiffness 8.669 damping 0.700 maxForce 3.5637 motor 1 motorSpeed 0.0000 steer 0.00 force 3.19183 position 1.102 speed -1.462 length -1.000 limit 0 broken 0 (otherAnchor/axis: not readable from Lua, Solar's above)
PB   28.31 DUMP tyre 4 ground: Zorosia at 0.4000 m below the centre (radius 0.400: SUNK by 0.0000 m), normal (0.7845 -0.1961 -0.5883)
PB   28.31 DUMP props: PropCrate true, PropCan true beside it (3 crates, 5 cans in the scene)
PB   28.31 DUMP PropCrate root: mass 1.0000 radius 0.300 (world 0.300) half 0.273/0.248/0.253 (world 0.273/0.248/0.253) shape 0 friction 0.80 restitution 0.15 kinematic false
PB   28.31 DUMP PropCrate Body: mass 0.1400 radius 0.300 (world 0.165) half 0.273/0.248/0.253 (world 0.150/0.136/0.139) shape 2 friction 0.80 restitution 0.15 kinematic true
PB   28.31 DUMP PropCrate assembly.info: mass 0.14000000059604645 grounded true asleep false wake settling |v| 0.0107 angVel 0.0794; node.asleep false node.wake settling
PB   28.31 DUMP PropCrate up (0.7010 -0.1274 -0.7017) vs ground normal (0.7058 -0.1269 -0.6970): 0.39 deg; planet up·normal 0.06 deg; ground Zorosia at 0.137 m below the centre (half_y 0.248: SUNK by 0.111 m), material nil
PB   28.31 DUMP PropCan root: mass 1.0000 radius 0.300 (world 0.300) half 0.232/0.322/0.232 (world 0.232/0.322/0.232) shape 0 friction 0.80 restitution 0.15 kinematic false
PB   28.31 DUMP PropCan Body: mass 0.0700 radius 0.300 (world 0.300) half 0.232/0.322/0.232 (world 0.232/0.322/0.232) shape 2 friction 0.80 restitution 0.15 kinematic true
PB   28.31 DUMP PropCan assembly.info: mass 0.07000000029802322 grounded true asleep true wake settling |v| 0.0000 angVel 0.0000; node.asleep true node.wake settling
PB   28.31 DUMP PropCan up (0.7012 -0.1273 -0.7015) vs ground normal (0.7044 -0.1285 -0.6980): 0.28 deg; planet up·normal 0.15 deg; ground Zorosia at 0.322 m below the centre (half_y 0.322: clear by 0.000 m), material nil
PB   28.31 DUMP ---- 120 ticks (2 s) in the planet frame; displacement per tick in mm (sleep threshold 0.83 mm/tick) ----
PB   28.31 DUMP R columns: tick t planet_m chassis_com_dmm chassis_node_dmm tyre1..4_dmm |v|mm/s asleep wake
PB   28.31 DUMP P columns: tick t crate_dmm crate_asleep crate_wake crate|v|mm/s can_dmm can_asleep can_wake can|v|mm/s
PB   28.31 DUMP R   1 -0.011 0.000 - - - - - - 77.4 false settling
PB   28.31 DUMP P   1 -0.011 - false settling 10.7 - true settling 0.0
PB   28.32 DUMP R   2 0.005 5.787 0.07 0.60 0.58 0.60 0.54 0.57 85.6 false settling
PB   28.32 DUMP P   2 0.005 0.50 false settling 11.3 0.57 true settling 0.0
PB   28.34 DUMP R   3 0.022 5.787 0.28 0.68 0.54 0.57 0.57 0.57 74.5 false settling
PB   28.34 DUMP P   3 0.022 0.50 false settling 0.0 0.57 true settling 0.0
PB   28.35 DUMP R   4 0.039 5.787 0.24 0.65 0.60 0.57 0.62 0.57 80.7 false settling
PB   28.35 DUMP P   4 0.039 0.63 false settling 0.0 0.62 true settling 0.0
PB   28.36 DUMP R   5 0.055 5.787 0.27 0.51 0.58 0.57 0.56 0.56 73.7 false settling
PB   28.36 DUMP P   5 0.055 0.61 false settling 9.4 0.52 true settling 0.0
PB   28.39 DUMP R   6 0.072 5.787 0.14 0.57 0.54 0.57 0.55 0.63 73.6 false settling
PB   28.39 DUMP P   6 0.072 0.62 false moving 12.0 0.57 true settling 0.0
PB   28.40 DUMP R   7 0.089 5.787 0.27 0.63 0.58 0.57 0.61 0.58 93.0 false settling
PB   28.40 DUMP P   7 0.089 0.53 false moving 11.4 0.57 true settling 0.0
PB   28.42 DUMP R   8 0.105 5.787 0.15 0.57 0.60 0.61 0.54 0.54 84.4 false settling
PB   28.42 DUMP P   8 0.105 0.57 false settling 0.0 0.57 true settling 0.0
PB   28.44 DUMP R   9 0.122 5.787 0.26 0.84 0.57 0.52 0.57 0.58 76.9 false settling
PB   28.44 DUMP P   9 0.122 0.68 false settling 0.0 0.57 true settling 0.0
PB   28.46 DUMP R  10 0.139 5.787 0.14 0.49 0.57 0.59 0.60 0.60 117.2 false settling
PB   28.46 DUMP P  10 0.139 0.57 false settling 13.3 0.57 true settling 0.0
PB   28.47 DUMP R  11 0.155 5.787 0.49 0.68 0.54 0.57 0.54 0.54 73.9 false settling
PB   28.47 DUMP P  11 0.155 0.59 false settling 0.0 0.57 true settling 0.0
PB   28.48 DUMP R  12 0.172 5.787 0.03 0.74 0.61 0.58 0.60 0.57 79.3 false settling
PB   28.48 DUMP P  12 0.172 0.57 false settling 10.3 0.57 true settling 0.0
PB   28.51 DUMP R  13 0.189 5.787 0.13 0.63 0.57 0.57 0.57 0.60 88.1 false settling
PB   28.51 DUMP P  13 0.189 0.64 false settling 0.0 0.57 true settling 0.0
PB   28.52 DUMP R  14 0.205 5.787 0.38 0.57 0.57 0.57 0.57 0.54 87.8 false settling
PB   28.52 DUMP P  14 0.205 0.62 false settling 8.7 0.57 true settling 0.0
PB   28.53 DUMP R  15 0.222 5.787 0.00 0.64 0.57 0.57 0.51 0.58 100.6 false settling
PB   28.53 DUMP P  15 0.222 0.65 false settling 8.1 0.57 true settling 0.0
PB   28.55 DUMP R  16 0.239 5.787 0.16 0.60 0.58 0.57 0.61 0.58 80.5 false joint
PB   28.55 DUMP P  16 0.239 0.53 false settling 0.0 0.57 true settling 0.0
PB   28.57 DUMP R  17 0.255 5.787 0.37 0.83 0.54 0.54 0.57 0.59 75.2 false settling
PB   28.57 DUMP P  17 0.255 0.64 false settling 8.7 0.57 true settling 0.0
PB   28.59 DUMP R  18 0.272 5.787 0.14 0.53 0.61 0.60 0.62 0.57 73.8 false settling
PB   28.59 DUMP P  18 0.272 0.57 false settling 0.0 0.57 true settling 0.0
PB   28.60 DUMP R  19 0.289 5.787 0.03 0.50 0.57 0.54 0.54 0.57 78.8 false settling
PB   28.60 DUMP P  19 0.289 0.67 false settling 0.0 0.57 true settling 0.0
PB   28.62 DUMP R  20 0.305 5.787 0.15 0.59 0.56 0.58 0.54 0.57 80.9 false settling
PB   28.62 DUMP P  20 0.305 0.66 false settling 0.0 0.57 true settling 0.0
PB   28.64 DUMP R  21 0.322 5.787 0.27 0.95 0.63 0.59 0.57 0.54 76.8 false settling
PB   28.64 DUMP P  21 0.322 0.68 false settling 10.8 0.57 true settling 0.0
PB   28.66 DUMP R  22 0.339 5.787 0.14 0.62 0.56 0.54 0.60 0.61 87.2 false settling
PB   28.66 DUMP P  22 0.339 0.55 false settling 0.0 0.57 true settling 0.0
PB   28.67 DUMP R  23 0.355 5.787 0.38 0.64 0.54 0.58 0.54 0.52 76.6 false settling
PB   28.67 DUMP P  23 0.355 0.54 false settling 10.5 0.57 true settling 0.0
PB   28.68 DUMP R  24 0.372 5.787 0.06 0.70 0.57 0.60 0.60 0.60 79.8 false joint
PB   28.68 DUMP P  24 0.372 0.57 false settling 0.0 0.57 true settling 0.0
PB   28.71 DUMP R  25 0.389 5.787 0.25 0.89 0.54 0.57 0.54 0.60 70.4 false settling
PB   28.71 DUMP P  25 0.389 0.73 false settling 0.0 0.57 true settling 0.0
PB   28.72 DUMP R  26 0.405 5.787 0.25 0.72 0.62 0.57 0.60 0.57 70.8 false settling
PB   28.72 DUMP P  26 0.405 0.57 false settling 12.1 0.57 true settling 0.0
PB   28.74 DUMP R  27 0.422 5.787 0.14 0.56 0.60 0.57 0.61 0.57 71.7 false settling
PB   28.74 DUMP P  27 0.422 0.57 false settling 0.0 0.57 true settling 0.0
PB   28.75 DUMP R  28 0.439 5.787 0.18 0.53 0.57 0.54 0.52 0.54 76.8 false settling
PB   28.75 DUMP P  28 0.439 0.55 false settling 11.7 0.57 true settling 0.0
PB   28.78 DUMP R  29 0.455 5.787 0.25 0.67 0.58 0.60 0.59 0.57 76.3 false settling
PB   28.78 DUMP P  29 0.455 0.71 false settling 10.0 0.57 true settling 0.0
PB   28.79 DUMP R  30 0.472 5.787 0.31 0.76 0.57 0.57 0.57 0.57 78.3 false joint
PB   28.79 DUMP P  30 0.472 0.55 false settling 0.0 0.57 true settling 0.0
PB   28.80 DUMP R  31 0.489 5.787 0.14 0.67 0.60 0.58 0.57 0.61 82.8 false settling
PB   28.80 DUMP P  31 0.489 0.68 false settling 0.0 0.57 true settling 0.0
PB   28.82 DUMP R  32 0.505 5.787 0.19 0.51 0.54 0.58 0.58 0.64 75.0 false settling
PB   28.82 DUMP P  32 0.505 0.47 false settling 12.0 0.57 true settling 0.0
PB   28.84 DUMP R  33 0.522 5.787 0.25 0.67 0.52 0.58 0.54 0.54 77.4 false settling
PB   28.84 DUMP P  33 0.522 0.60 false settling 10.4 0.57 true settling 0.0
PB   28.86 DUMP R  34 0.539 5.787 0.11 0.48 0.62 0.57 0.58 0.56 81.7 false settling
PB   28.86 DUMP P  34 0.539 0.54 false settling 9.0 0.57 true settling 0.0
PB   28.87 DUMP R  35 0.555 5.787 0.12 0.59 0.57 0.57 0.57 0.60 96.5 false settling
PB   28.87 DUMP P  35 0.555 0.50 false settling 11.9 0.57 true settling 0.0
PB   28.88 DUMP R  36 0.572 5.787 0.27 0.69 0.56 0.57 0.59 0.57 79.1 false joint
PB   28.88 DUMP P  36 0.572 0.49 false settling 0.0 0.57 true settling 0.0
PB   28.90 DUMP R  37 0.589 5.787 0.18 0.65 0.57 0.57 0.62 0.54 77.6 false settling
PB   28.90 DUMP P  37 0.589 0.54 false settling 0.0 0.57 true settling 0.0
PB   28.92 DUMP R  38 0.605 5.787 0.14 0.49 0.60 0.57 0.54 0.61 75.6 false settling
PB   28.92 DUMP P  38 0.605 0.71 false settling 0.0 0.57 true settling 0.0
PB   28.94 DUMP R  39 0.622 5.787 0.39 0.75 0.54 0.52 0.59 0.54 74.5 false joint
PB   28.94 DUMP P  39 0.622 0.58 false settling 0.0 0.57 true settling 0.0
PB   28.95 DUMP R  40 0.639 5.787 0.03 0.62 0.57 0.61 0.54 0.57 74.8 false settling
PB   28.95 DUMP P  40 0.639 0.57 false settling 8.0 0.57 true settling 0.0
PB   28.98 DUMP R  41 0.655 5.787 0.25 0.48 0.60 0.58 0.58 0.58 77.0 false settling
PB   28.98 DUMP P  41 0.655 0.60 false settling 6.8 0.57 true settling 0.0
PB   28.99 DUMP R  42 0.672 5.787 0.37 0.70 0.54 0.57 0.57 0.57 72.0 false settling
PB   28.99 DUMP P  42 0.672 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.00 DUMP R  43 0.689 5.787 0.13 0.64 0.60 0.54 0.57 0.54 74.0 false settling
PB   29.00 DUMP P  43 0.689 0.53 false settling 8.8 0.57 true settling 0.0
PB   29.02 DUMP R  44 0.705 5.787 0.22 0.58 0.60 0.60 0.54 0.63 82.4 false settling
PB   29.02 DUMP P  44 0.705 0.62 false settling 8.3 0.62 true settling 0.0
PB   29.04 DUMP R  45 0.722 5.787 0.28 0.87 0.54 0.58 0.61 0.53 86.3 false settling
PB   29.04 DUMP P  45 0.722 0.57 false settling 12.0 0.52 true settling 0.0
PB   29.06 DUMP R  46 0.739 5.787 0.14 0.61 0.57 0.57 0.57 0.62 93.0 false settling
PB   29.06 DUMP P  46 0.739 0.52 false settling 0.0 0.57 true settling 0.0
PB   29.07 DUMP R  47 0.755 5.787 0.27 0.51 0.57 0.57 0.57 0.57 78.0 false settling
PB   29.07 DUMP P  47 0.755 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.08 DUMP R  48 0.772 5.787 0.13 0.53 0.57 0.57 0.58 0.56 88.8 false settling
PB   29.08 DUMP P  48 0.772 0.62 false settling 9.0 0.57 true settling 0.0
PB   29.10 DUMP R  49 0.789 5.787 0.24 0.58 0.57 0.60 0.57 0.54 80.6 false settling
PB   29.10 DUMP P  49 0.789 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.11 DUMP R  50 0.805 5.787 0.15 0.70 0.58 0.57 0.51 0.62 101.2 false settling
PB   29.11 DUMP P  50 0.805 0.57 false settling 9.9 0.57 true settling 0.0
PB   29.14 DUMP R  51 0.822 5.787 0.40 0.90 0.58 0.57 0.62 0.57 83.6 false settling
PB   29.14 DUMP P  51 0.822 0.62 false moving 12.6 0.57 true settling 0.0
PB   29.15 DUMP R  52 0.839 5.787 0.29 0.40 0.54 0.57 0.54 0.57 76.3 false settling
PB   29.15 DUMP P  52 0.839 0.50 false settling 0.0 0.57 true settling 0.0
PB   29.17 DUMP R  53 0.855 5.787 0.09 0.62 0.60 0.57 0.57 0.54 85.8 false settling
PB   29.17 DUMP P  53 0.855 0.54 false settling 0.0 0.57 true settling 0.0
PB   29.19 DUMP R  54 0.872 5.787 0.17 0.94 0.54 0.57 0.58 0.54 78.2 false settling
PB   29.19 DUMP P  54 0.872 0.64 false settling 0.0 0.57 true settling 0.0
PB   29.21 DUMP R  55 0.889 5.787 0.14 0.48 0.60 0.54 0.57 0.60 75.3 false settling
PB   29.21 DUMP P  55 0.889 0.65 false settling 8.4 0.57 true settling 0.0
PB   29.22 DUMP R  56 0.905 5.787 0.14 0.49 0.57 0.54 0.57 0.57 78.6 false settling
PB   29.22 DUMP P  56 0.905 0.49 false settling 7.5 0.57 true settling 0.0
PB   29.24 DUMP R  57 0.922 5.787 0.14 0.56 0.56 0.62 0.57 0.57 76.7 false settling
PB   29.24 DUMP P  57 0.922 0.59 false settling 10.3 0.52 true settling 0.0
PB   29.25 DUMP R  58 0.939 5.787 0.03 0.61 0.59 0.61 0.57 0.61 76.9 false settling
PB   29.25 DUMP P  58 0.939 0.52 false settling 0.0 0.62 true settling 0.0
PB   29.27 DUMP R  59 0.955 5.787 0.15 0.61 0.57 0.58 0.57 0.51 74.9 false settling
PB   29.27 DUMP P  59 0.955 0.56 false settling 10.8 0.57 true settling 0.0
PB   29.29 DUMP R  60 0.972 5.787 0.13 0.61 0.57 0.54 0.61 0.61 78.4 false settling
PB   29.29 DUMP P  60 0.972 0.53 false settling 0.0 0.57 true settling 0.0
PB   29.30 DUMP R  61 0.989 5.787 0.07 0.50 0.58 0.57 0.54 0.57 77.2 false joint
PB   29.30 DUMP P  61 0.989 0.62 false moving 12.4 0.57 true settling 0.0
PB   29.33 DUMP R  62 1.005 5.787 0.25 0.23 0.57 0.60 0.59 0.58 81.5 false settling
PB   29.33 DUMP P  62 1.005 0.67 false settling 8.7 0.57 true settling 0.0
PB   29.34 DUMP R  63 1.022 5.787 0.18 0.75 0.57 0.54 0.57 0.57 74.9 false settling
PB   29.34 DUMP P  63 1.022 0.59 false settling 0.0 0.57 true settling 0.0
PB   29.35 DUMP R  64 1.039 5.787 0.06 0.74 0.57 0.60 0.57 0.58 73.7 false settling
PB   29.35 DUMP P  64 1.039 0.53 false settling 0.0 0.57 true settling 0.0
PB   29.37 DUMP R  65 1.055 5.787 0.06 0.66 0.57 0.58 0.57 0.57 82.9 false settling
PB   29.37 DUMP P  65 1.055 0.59 false settling 10.0 0.57 true settling 0.0
PB   29.39 DUMP R  66 1.072 5.787 0.07 0.63 0.57 0.58 0.54 0.57 85.1 false joint
PB   29.39 DUMP P  66 1.072 0.60 false settling 0.0 0.57 true settling 0.0
PB   29.41 DUMP R  67 1.089 5.787 0.16 0.52 0.57 0.61 0.60 0.57 82.1 false settling
PB   29.41 DUMP P  67 1.089 0.58 false settling 0.0 0.57 true settling 0.0
PB   29.42 DUMP R  68 1.105 5.787 0.27 0.69 0.57 0.54 0.57 0.61 75.1 false settling
PB   29.42 DUMP P  68 1.105 0.61 false settling 11.1 0.57 true settling 0.0
PB   29.43 DUMP R  69 1.122 5.787 0.14 0.68 0.57 0.57 0.54 0.54 76.1 false settling
PB   29.43 DUMP P  69 1.122 0.58 false settling 0.0 0.57 true settling 0.0
PB   29.46 DUMP R  70 1.139 5.787 0.37 0.70 0.56 0.57 0.62 0.58 77.3 false settling
PB   29.46 DUMP P  70 1.139 0.74 false settling 10.8 0.57 true settling 0.0
PB   29.47 DUMP R  71 1.155 5.787 0.00 0.49 0.57 0.58 0.59 0.60 77.1 false settling
PB   29.47 DUMP P  71 1.155 0.50 false settling 0.0 0.57 true settling 0.0
PB   29.49 DUMP R  72 1.172 5.787 0.06 0.58 0.60 0.57 0.55 0.58 75.8 false settling
PB   29.49 DUMP P  72 1.172 0.68 false settling 0.0 0.57 true settling 0.0
PB   29.50 DUMP R  73 1.189 5.787 0.14 0.58 0.54 0.57 0.59 0.51 81.9 false settling
PB   29.50 DUMP P  73 1.189 0.49 false moving 11.3 0.62 true settling 0.0
PB   29.53 DUMP R  74 1.205 5.787 0.14 0.52 0.60 0.58 0.57 0.63 77.2 false settling
PB   29.53 DUMP P  74 1.205 0.54 false settling 0.0 0.52 true settling 0.0
PB   29.54 DUMP R  75 1.222 5.787 0.14 0.62 0.60 0.57 0.58 0.58 72.2 false settling
PB   29.54 DUMP P  75 1.222 0.57 false moving 11.6 0.57 true settling 0.0
PB   29.56 DUMP R  76 1.239 5.787 0.27 0.63 0.54 0.54 0.54 0.57 81.1 false settling
PB   29.56 DUMP P  76 1.239 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.57 DUMP R  77 1.255 5.787 0.50 0.72 0.57 0.60 0.60 0.58 72.4 false settling
PB   29.57 DUMP P  77 1.255 0.58 false settling 9.1 0.57 true settling 0.0
PB   29.58 DUMP R  78 1.272 5.787 0.14 0.79 0.58 0.57 0.56 0.57 77.4 false settling
PB   29.58 DUMP P  78 1.272 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.61 DUMP R  79 1.289 5.787 0.31 0.84 0.54 0.54 0.58 0.56 94.1 false settling
PB   29.61 DUMP P  79 1.289 0.64 false settling 0.0 0.57 true settling 0.0
PB   29.63 DUMP R  80 1.305 5.787 0.28 0.65 0.59 0.61 0.54 0.57 77.9 false settling
PB   29.63 DUMP P  80 1.305 0.53 false settling 0.0 0.57 true settling 0.0
PB   29.64 DUMP R  81 1.322 5.787 0.13 0.54 0.57 0.57 0.63 0.58 134.9 false joint
PB   29.64 DUMP P  81 1.322 0.57 false settling 0.0 0.57 true settling 0.0
PB   29.66 DUMP R  82 1.339 5.787 0.63 0.78 0.57 0.57 0.57 0.58 76.9 false settling
PB   29.66 DUMP P  82 1.339 0.53 false settling 0.0 0.57 true settling 0.0
PB   29.67 DUMP R  83 1.355 5.787 0.16 0.75 0.57 0.57 0.54 0.57 89.2 false settling
PB   29.67 DUMP P  83 1.355 0.59 false settling 0.0 0.57 true settling 0.0
PB   29.68 DUMP R  84 1.372 5.787 0.39 0.66 0.57 0.56 0.57 0.57 91.2 false settling
PB   29.68 DUMP P  84 1.372 0.65 false settling 8.0 0.57 true settling 0.0
PB   29.71 DUMP R  85 1.389 5.787 0.06 0.71 0.54 0.60 0.60 0.58 87.2 false settling
PB   29.71 DUMP P  85 1.389 0.54 false settling 0.0 0.57 true settling 0.0
PB   29.72 DUMP R  86 1.405 5.787 0.14 0.45 0.65 0.54 0.57 0.54 76.1 false joint
PB   29.72 DUMP P  86 1.405 0.61 false moving 8.0 0.57 true settling 0.0
PB   29.73 DUMP R  87 1.422 5.787 0.07 0.56 0.52 0.58 0.58 0.62 75.6 false joint
PB   29.74 DUMP P  87 1.422 0.61 false settling 10.7 0.52 true settling 0.0
PB   29.75 DUMP R  88 1.439 5.787 0.27 0.61 0.56 0.64 0.53 0.54 91.2 false settling
PB   29.75 DUMP P  88 1.439 0.57 false settling 0.0 0.62 true settling 0.0
PB   29.77 DUMP R  89 1.455 5.787 0.18 0.52 0.57 0.54 0.61 0.58 98.7 false settling
PB   29.77 DUMP P  89 1.455 0.71 false settling 0.0 0.57 true settling 0.0
PB   29.79 DUMP R  90 1.472 5.787 0.15 0.60 0.59 0.57 0.57 0.54 91.0 false settling
PB   29.79 DUMP P  90 1.472 0.53 false moving 11.4 0.57 true settling 0.0
PB   29.80 DUMP R  91 1.489 5.787 0.37 0.64 0.57 0.57 0.57 0.60 79.3 false settling
PB   29.80 DUMP P  91 1.489 0.55 false settling 0.0 0.57 true settling 0.0
PB   29.82 DUMP R  92 1.505 5.787 0.27 0.49 0.57 0.57 0.57 0.59 122.3 false settling
PB   29.82 DUMP P  92 1.505 0.74 false settling 0.0 0.57 true settling 0.0
PB   29.84 DUMP R  93 1.522 5.787 0.66 0.99 0.57 0.61 0.58 0.57 75.6 false settling
PB   29.84 DUMP P  93 1.522 0.55 false settling 0.0 0.57 true settling 0.0
PB   29.85 DUMP R  94 1.539 5.787 0.29 0.58 0.57 0.54 0.57 0.60 103.8 false joint
PB   29.85 DUMP P  94 1.539 0.59 false settling 0.0 0.57 true settling 0.0
PB   29.87 DUMP R  95 1.555 5.787 0.31 0.72 0.61 0.57 0.57 0.54 82.6 false joint
PB   29.87 DUMP P  95 1.555 0.61 false settling 0.0 0.62 true settling 0.0
PB   29.89 DUMP R  96 1.572 5.787 0.25 0.80 0.54 0.57 0.57 0.57 74.3 false settling
PB   29.89 DUMP P  96 1.572 0.67 false settling 9.8 0.52 true settling 0.0
PB   29.91 DUMP R  97 1.589 5.787 0.14 0.61 0.57 0.57 0.59 0.58 75.0 false settling
PB   29.91 DUMP P  97 1.589 0.57 false moving 11.6 0.57 true settling 0.0
PB   29.92 DUMP R  98 1.605 5.787 0.24 0.55 0.57 0.58 0.55 0.57 75.4 false settling
PB   29.92 DUMP P  98 1.605 0.42 false settling 11.0 0.62 true settling 0.0
PB   29.93 DUMP R  99 1.622 5.787 0.06 0.54 0.54 0.59 0.62 0.57 78.0 false settling
PB   29.93 DUMP P  99 1.622 0.45 false settling 11.4 0.52 true settling 0.0
PB   29.96 DUMP R 100 1.639 5.787 0.14 0.72 0.60 0.60 0.56 0.61 74.9 false joint
PB   29.96 DUMP P 100 1.639 0.62 false settling 0.0 0.57 true settling 0.0
PB   29.97 DUMP R 101 1.655 5.787 0.14 0.48 0.57 0.54 0.60 0.54 74.6 false settling
PB   29.97 DUMP P 101 1.655 0.58 false settling 11.3 0.57 true settling 0.0
PB   29.98 DUMP R 102 1.672 5.787 0.25 0.59 0.54 0.56 0.60 0.57 90.9 false joint
PB   29.98 DUMP P 102 1.672 0.54 false settling 9.0 0.57 true settling 0.0
PB   30.00 DUMP R 103 1.689 5.787 0.50 0.83 0.54 0.62 0.57 0.54 75.5 false settling
PB   30.00 DUMP P 103 1.689 0.57 false settling 0.0 0.57 true settling 0.0
PB   30.02 DUMP R 104 1.705 5.787 0.27 0.67 0.62 0.51 0.51 0.57 84.9 false joint
PB   30.02 DUMP P 104 1.705 0.54 false settling 0.0 0.57 true settling 0.0
PB   30.04 DUMP R 105 1.722 5.787 0.37 0.80 0.57 0.54 0.60 0.60 70.7 false settling
PB   30.04 DUMP P 105 1.722 0.62 false moving 12.5 0.57 true settling 0.0
PB   30.05 DUMP R 106 1.739 5.787 0.27 0.54 0.57 0.63 0.61 0.58 88.1 false settling
PB   30.05 DUMP P 106 1.739 0.53 false settling 0.0 0.57 true settling 0.0
PB   30.07 DUMP R 107 1.755 5.787 0.51 0.53 0.57 0.54 0.54 0.57 75.7 false settling
PB   30.07 DUMP P 107 1.755 0.57 false settling 0.0 0.57 true settling 0.0
PB   30.09 DUMP R 108 1.772 5.787 0.31 1.02 0.58 0.60 0.54 0.61 76.6 false settling
PB   30.09 DUMP P 108 1.772 0.75 false settling 7.9 0.57 true settling 0.0
PB   30.11 DUMP R 109 1.789 5.787 0.38 0.80 0.57 0.57 0.60 0.54 86.6 false joint
PB   30.11 DUMP P 109 1.789 0.57 false settling 0.0 0.57 true settling 0.0
PB   30.12 DUMP R 110 1.805 5.787 0.18 0.76 0.57 0.54 0.57 0.57 85.1 false settling
PB   30.12 DUMP P 110 1.805 0.62 false settling 8.4 0.57 true settling 0.0
PB   30.14 DUMP R 111 1.822 5.787 0.15 0.60 0.57 0.61 0.60 0.61 75.7 false joint
PB   30.14 DUMP P 111 1.822 0.57 false settling 0.0 0.57 true settling 0.0
PB   30.15 DUMP R 112 1.839 5.787 0.14 0.68 0.57 0.57 0.54 0.57 74.3 false settling
PB   30.15 DUMP P 112 1.839 0.54 false settling 0.0 0.57 true settling 0.0
PB   30.18 DUMP R 113 1.855 5.787 0.14 0.50 0.58 0.56 0.58 0.57 73.9 false settling
PB   30.18 DUMP P 113 1.855 0.64 false settling 11.7 0.57 true settling 0.0
PB   30.19 DUMP R 114 1.872 5.787 0.14 0.62 0.57 0.57 0.54 0.57 81.0 false settling
PB   30.19 DUMP P 114 1.872 0.49 false moving 12.7 0.57 true settling 0.0
PB   30.20 DUMP R 115 1.889 5.787 0.09 0.66 0.57 0.60 0.58 0.57 80.9 false settling
PB   30.20 DUMP P 115 1.889 0.61 false settling 0.0 0.57 true settling 0.0
PB   30.22 DUMP R 116 1.905 5.787 0.14 0.61 0.57 0.57 0.57 0.58 87.2 false settling
PB   30.22 DUMP P 116 1.905 0.54 false moving 8.1 0.57 true settling 0.0
PB   30.24 DUMP R 117 1.922 5.787 0.27 0.56 0.54 0.58 0.60 0.54 77.3 false settling
PB   30.24 DUMP P 117 1.922 0.74 false moving 8.9 0.57 true settling 0.0
PB   30.26 DUMP R 118 1.939 5.787 0.07 0.64 0.60 0.53 0.54 0.58 75.7 false settling
PB   30.26 DUMP P 118 1.939 0.53 false settling 10.1 0.57 true settling 0.0
PB   30.27 DUMP R 119 1.955 5.787 0.12 0.53 0.57 0.62 0.60 0.60 76.8 false settling
PB   30.27 DUMP P 119 1.955 0.54 false settling 11.2 0.57 true settling 0.0
PB   30.28 DUMP R 120 1.972 5.787 0.06 0.56 0.57 0.57 0.54 0.57 77.5 false settling
PB   30.28 DUMP P 120 1.972 0.50 false settling 10.1 0.57 true settling 0.0
PB   30.29 DUMP ---- end ----

PB   75.30 RESULT [s_park_rover] SLEEP: NEVER asleep in 45 s (2942 frames), last wake settling |v| 0.081; awake 2942 frames physics 0.56 ms/frame (static 0.48); asleep 0 frames physics 0.00 (static 0.00); re-woke frames 0; wake reasons settling 2544, joint 398; drift on its planet 0.001 m (max 0.001)
PB   77.30 PARK after W 2 s: asleep false wake settling |v| 0.08
```

## How to read it (the probe's notes, not part of the dump)

- Units are the engine's own: assembly.info mass 0.592 and the tyre rb.mass 0.072 are in the same unit as the prefabs' `mass:` (the crate reads 0.14, the can 0.07). The chassis root's own RigidBody reads mass 1.0, a 0.5 m sphere (shape 0): the assembly's shape is its parts', not the root's.
- The rover is the 4-wheel probe blueprint (4 wheelM + body + seat = 6 parts); g at the spot 9.71 m/s2; the planet carries everything 5.787 m a tick.
- Joint params: `stiffness`, `damping`, `maxForce`, `motor`, `motorSpeed`, `steer`, `force`, `position`, `speed` are read back from the engine (`tyre:getcomponent("Joint")`). `otherAnchor` and `axis` are not in the Joint component's readable fields (floptle-script api.rs 1395-1427), so the dump prints what Solar set: otherAnchor = the mount in hull space, axis (0,1,0), kind "wheel". Solar hung the joints with stiffness 8.669 cycles/s (spring 1), damping 0.7, maxForce = the motor's 1.78 at hang; the brake handler then writes `motor = 1, motorSpeed = 0, maxForce = full × 2 × brake` every tick, which is the 3.5637 the engine reads.
- Per-tick lines: `DUMP R tick t planet_step_m chassis_com_dmm chassis_node_dmm tyre1..4_dmm |v|_mm/s asleep wake`; `DUMP P tick t crate_dmm asleep wake |v|_mm/s can_dmm asleep wake |v|_mm/s`. Every position is `node − space.body("Zorosia")` taken in the same fixedUpdate; the chassis com is `assembly.info(vn).com` the same way. The first line has no displacement (no previous tick).
- MEASUREMENT FLOOR: the PropCan is asleep on every tick (|v| 0.000, the solver skips it) and still reads a steady 0.57 mm/tick (105 of 119 ticks exactly 0.57, the rest 0.52/0.62). So `node.pos − body.pos` in Lua carries a ~0.57 mm/tick artefact for a body that does not move at all relative to its planet: f32 rounding of world positions kilometres from the origin under a 5.787 m carry (ulp 0.5-1 mm at 4-8 km) fits the size and the steadiness. Every tyre (0.572-0.574 mm/tick mean, the same 0.57 quantum) and the crate (0.584) sit on that floor: they are NOT displacing relative to the planet by anything this read can resolve. The chassis com (assembly.info) reads below the floor, 0.16 mm median, 0.66 max, 0 ticks over the 0.83 mm sleep allowance; the chassis node pos reads 0.62 median with 9 of 119 ticks over 0.83 (the same artefact plus the frame's pose). Next run prints the distance from the world origin (the probe now does; see `DUMP world origin`).
- The thing that is NOT at the floor: the rover's reported velocity. `assembly.info(vn).vel` is 70-135 mm/s (median 77.5) on every tick, and the tyres read 0.13-0.19 m/s, while the 45 s drift on the planet is 0.001 m and the com moves ≤0.66 mm a tick (≤40 mm/s even at the floor). A body whose velocity reads 0.08 m/s but whose position does not move is above SLEEP_LINEAR_SPEED (0.05) by velocity and below it by displacement; the wheel joints also read `speed` −4.0..+1.0 deg/s and `force` 2.4-3.2 while braked, and 17 of the 119 ticks carried wake `joint` (398 of 2942 frames over the 45 s).
- The crate: its root's half_y 0.248 is the prefab's unscaled number; the Body part that the solver collides with is scaled 0.55 (world half 0.150/0.136/0.139), and the ground is 0.137 m below the crate's centre, so the "SUNK by 0.111 m" the dump prints is the root's number against the part's: the crate rests exactly on its box, upright within 0.39 deg of the ground normal (the can, which sleeps, is identical: 0.28 deg, ground at exactly its half_y 0.322). The crate's |v| is 0.0 on 61 ticks and 8-12 mm/s on the rest, its angVel 0.079 rad/s at the static read (1.3 mrad/tick, over the 0.83 mrad turn allowance in `compound_barely_moved`), wake `settling` throughout, never asleep. The can beside it, same prefab shape and material, mass 0.07 instead of 0.14, unscaled Body, sleeps.
- Tyres 1 and 3 (the +z side) have the hull's live 5 cm wheel box (PartWheelM, vessel_controller wheel_collider) 0.033-0.037 m under their centre along the planet's down; tyres 2 and 4 see the terrain at exactly their radius (0.400). The 1/3 tyres thus sit about 8-9 cm above their mount on that side; Solar-side geometry, noted for completeness.
