"""The VEHICLE ASSEMBLY BUILDING's dimensions, in one place.

tools/base_buildings.py (the exterior, prefab FacHangar) and tools/gen_vab.py
(the interior, prefab VabInterior) both build from these, so the shell and
what stands inside it can never disagree. Ground frame, metres: the ground is
y = 0, the front (+Z) faces the apron and the runway (layout "S"), the back
(−Z) the crawlerway and the pad; the lot centre is x = z = 0.

WHY THESE NUMBERS. The builder has to hold:
  * a rocket of 40–60 m standing on the mobile launcher (deck 2.6 m): the
    roof trusses' bottom chord is at 65.5 m, so 62.9 m stands clear under
    them, and the upper door slot (24 m wide) is 64 m high to roll it out;
  * a plane of 30–40 m span: the high bay is 48.8 m clear wall to wall, the
    work platforms start 10.5 m up (over any wing), and the lower door is
    42 m wide by 20 m high — the inverted T of a real VAB door;
  * a big rover anywhere on the 48.8 × 48.8 m floor.
It stays "mostly to scale": a 50 × 50 × 72 m box is under half the height of
KSC's VAB (160 m) and close to Kourou's BIL (58 m) or a Baikonur MIK hall;
anything taller would dwarf a 600–950 m home world's whole base.
"""

W = 25.0            # half width (x), outer face of the side walls
D = 25.0            # half depth (z), outer face of the end walls
H = 72.0            # roof top
T = 0.6             # wall thickness
IN_W = W - T        # inner face of the side walls (24.4)
IN_D = D - T        # inner face of the end walls (24.4)
ROOF_SLAB = 0.6     # the roof deck is H - ROOF_SLAB .. H
SLAB_Y0, SLAB_Y1 = -0.6, 0.12   # the floor slab; its top is the high bay's floor
# FacHangar's root mesh is the slab alone, and the engine centres a model on
# its box, so the prefab origin (shared by VabInterior) is the slab's centre.
ORIGIN = (0.0, (SLAB_Y0 + SLAB_Y1) / 2, 0.0)

# The door, on both ends: an inverted T.
LOW_W = 21.0        # lower opening half width
LOW_H = 20.0        # lower opening height
SLOT_W = 12.0       # upper slot half width
SLOT_H = 64.0       # upper slot top

# The roof trusses and the bridge crane.
TRUSS_LO = 65.5     # bottom chord (underside)
TRUSS_HI = 71.3     # top chord (top), just under the roof deck
CRANE_RAIL = 59.0   # runway rail top

# The structural bays: interior columns along the side walls.
COL_Z = (-23.6, -16.0, -8.0, 0.0, 8.0, 16.0, 23.6)
COL_DEPTH = 0.9     # column depth off the wall's inner face
TRUSS_Z = COL_Z     # a roof truss bears on each pair of columns

# Work platforms on both side walls, and the stair towers that reach them.
LEVELS = (10.5, 21.0, 31.5, 42.0, 52.5)
PLAT_DEPTH = 5.1    # deck depth, in front of the columns
PLAT_X0 = IN_W - COL_DEPTH - PLAT_DEPTH    # inner edge |x| (18.4)
PLAT_X1 = IN_W - COL_DEPTH                 # wall edge |x| (23.5)
PLAT_Z0, PLAT_Z1 = -17.6, 17.6
STAIR_Z0, STAIR_Z1 = -IN_D + 0.1, PLAT_Z0  # stair towers, north corners

# The mobile launcher the craft is built on.
ML_HX, ML_HZ = 12.0, 10.0
ML_TOP = 2.6
BUILD_POINT = (0.0, ML_TOP, 0.0)
