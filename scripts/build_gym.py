#!/usr/bin/env python3
"""Generates the gym world files Rojo syncs into Workspace.

The gym is original part geometry — no Toolbox models, no imported meshes, so
nothing here carries a licence. Machines are built from primitives (blocks,
cylinders, wedges) laid out in each machine's own local space and then placed
into the world by a single origin CFrame.

Run it after editing a layout below:

    python3 scripts/build_gym.py

It rewrites src/Workspace/Gym/*.model.json in place. Those JSON files are the
committed source of truth that Rojo reads; this script is the authoring tool
that keeps their numbers consistent.

Conventions the runtime depends on (see EquipmentConfig):
  * Each machine Model is tagged "TrainingStation" and carries an "EquipmentId"
    attribute.
  * A part named "Base" is the machine's visual anchor for billboards/prompts.
  * Every part named "TrainAnchor" is one training spot. Its CFrame is used
    verbatim as the player's HumanoidRootPart CFrame, so it encodes both where
    they stand and how they are posed — lying back on a bench, hanging from a
    bar, standing on a belt.
  * An optional part named "TrainExit" is where the player is put down when
    they leave. Without one they stand up in place.
"""

from __future__ import annotations

import json
import math
import os

# Floor slabs are 1 stud thick centred at y=0.5, so everything stands on y=1.
FLOOR_TOP = 1.0
# A standing R15 HumanoidRootPart sits this far above the ground it stands on
# (HipHeight 2 + half of the 2-stud root part).
ROOT_HEIGHT = 3.0

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "src", "Workspace", "Gym")


# --------------------------------------------------------------------------
# CFrame maths. A CFrame is (position, 3x3 row-major rotation) where column 0
# is RightVector, column 1 UpVector and column 2 BackVector, matching Roblox.
# --------------------------------------------------------------------------

IDENTITY = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))


def cf(x=0.0, y=0.0, z=0.0, rot=IDENTITY):
    return ((float(x), float(y), float(z)), rot)


def mat_mul(a, b):
    return tuple(
        tuple(sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3))
        for r in range(3)
    )


def mat_apply(m, v):
    return tuple(sum(m[r][c] * v[c] for c in range(3)) for r in range(3))


def mul(a, b):
    """Composes two CFrames, exactly as `a * b` does in Luau."""
    pos = tuple(a[0][i] + mat_apply(a[1], b[0])[i] for i in range(3))
    return (pos, mat_mul(a[1], b[1]))


def rot_x(deg):
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    return cf(rot=((1, 0, 0), (0, c, -s), (0, s, c)))


def rot_y(deg):
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    return cf(rot=((c, 0, s), (0, 1, 0), (-s, 0, c)))


def rot_z(deg):
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    return cf(rot=((c, -s, 0), (s, c, 0), (0, 0, 1)))


def axes(pos, right, up):
    """Builds a CFrame from an explicit right and up vector.

    Used for the lying-down and hanging anchors, where naming the axes is far
    clearer than composing three Euler rotations and hoping.
    """
    back = cross(right, up)
    m = (
        (right[0], up[0], back[0]),
        (right[1], up[1], back[1]),
        (right[2], up[2], back[2]),
    )
    return (tuple(float(v) for v in pos), m)


def cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def serialise_cf(c):
    (x, y, z), m = c
    return [
        round(x, 4), round(y, 4), round(z, 4),
        round(m[0][0], 6), round(m[0][1], 6), round(m[0][2], 6),
        round(m[1][0], 6), round(m[1][1], 6), round(m[1][2], 6),
        round(m[2][0], 6), round(m[2][1], 6), round(m[2][2], 6),
    ]


# --------------------------------------------------------------------------
# Palette. Kept small on purpose: a handful of repeated materials reads as one
# designed room, where a colour per part reads as a prototype.
# --------------------------------------------------------------------------

STEEL = [0.10, 0.11, 0.13]
STEEL_LIGHT = [0.22, 0.23, 0.27]
CHROME = [0.78, 0.80, 0.84]
RUBBER = [0.07, 0.07, 0.08]
PAD_RED = [0.45, 0.11, 0.12]
PAD_BLUE = [0.09, 0.22, 0.40]
FLOOR_DARK = [0.16, 0.17, 0.21]
FLOOR_IRON = [0.11, 0.13, 0.17]
WALL = [0.24, 0.25, 0.30]
WALL_IRON = [0.16, 0.18, 0.24]
ACCENT_STARTER = [0.49, 0.83, 0.61]
ACCENT_IRON = [0.26, 0.65, 0.96]
WOOD = [0.35, 0.24, 0.16]


def part(name, size, frame, color, material="Metal", class_name="Part", **props):
    properties = {
        "Anchored": True,
        "CFrame": serialise_cf(frame),
        "Size": [round(v, 4) for v in size],
        "Color": color,
        "Material": material,
        "TopSurface": "Smooth",
        "BottomSurface": "Smooth",
    }
    properties.update(props)
    return {"name": name, "className": class_name, "properties": properties}


def cylinder(name, length, diameter, frame, color, material="Metal", **props):
    """A cylinder whose axis runs along the part's local X, as Roblox defines it."""
    return part(name, [length, diameter, diameter], frame, color, material,
                Shape="Cylinder", **props)


def marker(name, size, frame):
    """An invisible, non-colliding reference part — anchors and exits."""
    return part(name, size, frame, [1, 1, 1], "SmoothPlastic",
                Transparency=1, CanCollide=False, CastShadow=False)


def anchor_standing(frame):
    """A training spot where the player stands upright, facing the CFrame's look."""
    return marker("TrainAnchor", [2, 2, 1], mul(frame, cf(0, ROOT_HEIGHT, 0)))


# --------------------------------------------------------------------------
# Machines. Each returns a Model in its own local space: +Y up, the machine's
# front (the side a player approaches from) facing +Z.
# --------------------------------------------------------------------------


def machine(name, equipment_id, origin, children):
    return {
        "name": name,
        "className": "Model",
        "attributes": {"EquipmentId": equipment_id},
        "properties": {"Tags": ["TrainingStation"]},
        "children": [place(origin, child) for child in children],
    }


def group(name, children, class_name="Model"):
    """A container with no geometry of its own — a training spot, or a held prop."""
    return {"name": name, "className": class_name, "children": children}


def place(origin, child):
    """Re-expresses a locally-built child, and everything under it, in world space."""
    properties = child.get("properties", {})
    if "CFrame" in properties:
        local = properties["CFrame"]
        (px, py, pz) = local[0:3]
        m = (tuple(local[3:6]), tuple(local[6:9]), tuple(local[9:12]))
        properties["CFrame"] = serialise_cf(mul(origin, ((px, py, pz), m)))
    for sub in child.get("children", []):
        place(origin, sub)
    return child


def floor_mat(width, depth, color=RUBBER):
    return part("Mat", [width, 0.12, depth], cf(0, FLOOR_TOP + 0.06, 0), color,
                "Pebble", CanCollide=False)


def plates(prefix, y, z, spacing, radius, thickness, out):
    """A loaded barbell sleeve: mirrored discs either side of the bar."""
    for side in (-1, 1):
        for offset in spacing:
            out.append(cylinder(
                f"{prefix}Plate", thickness, radius * 2,
                cf(side * offset, y, z), STEEL, "DiamondPlate",
            ))
        out.append(cylinder(f"{prefix}Collar", 0.35, 0.75,
                            cf(side * (spacing[-1] + 0.45), y, z), CHROME,
                            "Metal", Reflectance=0.25))


def bench_press(pad_color, accent):
    """Flat bench under a two-post rack. The player lies back on the pad."""
    out = [floor_mat(11, 13)]

    # Rack posts stand just behind the lifter's head, with hook arms cantilevered
    # forward so the bar sits over the chest — level with where the hands top out
    # in the press (PoseConfig "BenchPress"). Racking it back over the uprights,
    # where a bare rack would hold it, leaves the lifter pressing thin air.
    for side in (-1, 1):
        out.append(part("RackPost", [0.45, 4.55, 0.45],
                        cf(side * 1.7, FLOOR_TOP + 2.28, -2.6), STEEL, "DiamondPlate"))
        out.append(part("RackFoot", [0.7, 0.35, 2.8],
                        cf(side * 1.7, FLOOR_TOP + 0.18, -2.6), STEEL, "DiamondPlate"))
        out.append(part("HookArm", [0.3, 0.3, 2.3],
                        cf(side * 1.7, FLOOR_TOP + 4.45, -1.5), STEEL, "Metal"))
        out.append(part("RackHook", [0.32, 0.85, 0.32],
                        cf(side * 1.7, FLOOR_TOP + 4.7, -0.45), accent, "Metal"))

    # Bench frame and pad.
    out.append(part("FrameSpine", [0.55, 0.45, 8.4],
                    cf(0, FLOOR_TOP + 0.7, 0.4), STEEL, "DiamondPlate"))
    for z in (-2.6, 3.0):
        out.append(part("FrameLeg", [2.6, 1.3, 0.45],
                        cf(0, FLOOR_TOP + 0.65, z), STEEL, "DiamondPlate"))
    out.append(part("Base", [2.7, 0.55, 6.6],
                    cf(0, FLOOR_TOP + 1.58, 0.2), pad_color, "Fabric"))
    out.append(part("HeadPad", [2.7, 0.35, 1.6],
                    cf(0, FLOOR_TOP + 1.75, -2.9), pad_color, "Fabric"))

    # The barbell is a held prop rather than scenery: while a set runs it leaves the
    # hooks and tracks the lifter's hands, so a press moves the weight instead of
    # miming underneath it. It is authored resting in the hooks, which is where it
    # sits whenever nobody is on the bench.
    bar_y = FLOOR_TOP + 4.55
    bar = [cylinder("Bar", 7.6, 0.32, cf(0, bar_y, -0.45), CHROME, "Metal",
                    Reflectance=0.3, CanCollide=False)]
    plates("Bar", bar_y, -0.45, (2.35, 2.85), 1.25, 0.4, bar)
    for piece in bar:
        piece["properties"]["CanCollide"] = False

    out.append(group("Spot", [
        # Lying on the back: head toward the rack (-Z), face toward the ceiling.
        marker("TrainAnchor", [2, 2, 1],
               axes((0, FLOOR_TOP + 2.85, 0.1), (-1, 0, 0), (0, 0, -1))),
        group("HeldBoth", bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1],
                      mul(cf(3.6, FLOOR_TOP + ROOT_HEIGHT, 1.5), rot_y(-90))))
    return out


def dumbbell_rack(pad_color, accent):
    """A two-tier rack. Three lifters can curl in front of it at once."""
    out = [floor_mat(14, 8)]

    out.append(part("Base", [13.0, 0.5, 2.6],
                    cf(0, FLOOR_TOP + 0.25, -1.4), STEEL, "DiamondPlate"))
    out.append(part("BackPanel", [13.0, 3.4, 0.4],
                    cf(0, FLOOR_TOP + 1.9, -2.5), STEEL_LIGHT, "Metal"))
    out.append(part("AccentStripe", [13.0, 0.35, 0.15],
                    cf(0, FLOOR_TOP + 3.4, -2.28), accent, "Neon"))

    # Lower shelf: scenery, six fixed dumbbells.
    shelf_y, shelf_z = 1.05, -1.0
    out.append(part("Shelf", [12.6, 0.3, 1.9],
                    cf(0, FLOOR_TOP + shelf_y, shelf_z), STEEL, "DiamondPlate"))
    for index in range(6):
        x = -5.25 + index * 2.1
        y = FLOOR_TOP + shelf_y + 0.15 + 0.62
        out.append(cylinder("DumbbellHandle", 1.5, 0.3,
                            cf(x, y, shelf_z), CHROME, "Metal", Reflectance=0.25))
        for side in (-1, 1):
            out.append(cylinder("DumbbellHead", 0.75, 1.24,
                                cf(x + side * 0.95, y, shelf_z), RUBBER, "Pebble"))

    # Upper shelf: the three pairs that are actually picked up. Each pair belongs to
    # one spot and is authored resting on the shelf, which is where it sits until
    # somebody curls with it.
    top_y, top_z = 2.55, -1.75
    out.append(part("Shelf", [12.6, 0.3, 1.9],
                    cf(0, FLOOR_TOP + top_y, top_z), STEEL, "DiamondPlate"))

    def dumbbell(name, x, y, z):
        pieces = [cylinder("Handle", 1.5, 0.3, cf(x, y, z), CHROME, "Metal",
                           Reflectance=0.25, CanCollide=False)]
        for side in (-1, 1):
            pieces.append(cylinder("Head", 0.75, 1.56, cf(x + side * 0.95, y, z),
                                   RUBBER, "Pebble", CanCollide=False))
        return group(name, pieces)

    # Three curl spots facing the rack (a CFrame's look is its -Z, so an
    # unrotated anchor in front of the rack already faces back into it).
    rest_y = FLOOR_TOP + top_y + 0.15 + 0.78
    for x in (-4.2, 0.0, 4.2):
        out.append(group("Spot", [
            anchor_standing(cf(x, FLOOR_TOP, 1.6)),
            dumbbell("HeldRight", x, rest_y, top_z + 0.55),
            dumbbell("HeldLeft", x, rest_y, top_z - 0.55),
        ]))

    out.append(marker("TrainExit", [2, 2, 1],
                      cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.5)))
    return out


def pull_up_rig(pad_color, accent):
    """A gantry the player hangs from. Two grips, side by side."""
    out = [floor_mat(12, 8)]

    for side in (-1, 1):
        out.append(part("Upright", [0.7, 9.0, 0.7],
                        cf(side * 4.4, FLOOR_TOP + 4.5, 0), STEEL, "DiamondPlate"))
        out.append(part("Foot", [1.6, 0.4, 4.4],
                        cf(side * 4.4, FLOOR_TOP + 0.2, 0), STEEL, "DiamondPlate"))
        out.append(part("Brace", [0.4, 0.4, 3.0],
                        mul(cf(side * 4.4, FLOOR_TOP + 7.4, 1.4), rot_x(38)),
                        STEEL_LIGHT, "Metal"))

    out.append(part("Base", [9.5, 0.55, 0.55],
                    cf(0, FLOOR_TOP + 8.75, 0), STEEL, "DiamondPlate"))
    out.append(cylinder("Bar", 9.4, 0.42, cf(0, FLOOR_TOP + 8.35, 0.0),
                        CHROME, "Metal", Reflectance=0.3))
    for side in (-1, 1):
        out.append(cylinder("Grip", 1.3, 0.5, cf(side * 1.9, FLOOR_TOP + 8.35, 0),
                            accent, "Pebble"))
        # Hanging: feet well clear of the floor, facing out into the room. Height is
        # set so the hands meet the bar with the arms overhead and the chin clears it
        # at the top of the pull — the arms cannot stretch to find the bar on their
        # own, so the body has to hang at the right distance below it.
        out.append(marker("TrainAnchor", [2, 2, 1],
                          mul(cf(side * 1.9, FLOOR_TOP + 6.2, 0), rot_y(180))))
    out.append(marker("TrainExit", [2, 2, 1],
                      cf(0, FLOOR_TOP + ROOT_HEIGHT, 3.4)))
    return out


def sit_up_bench(pad_color, accent):
    """A decline bench with foot rollers. The player reclines against the slope."""
    out = [floor_mat(9, 11)]

    slope = 22.0
    out.append(part("FrameSpine", [0.5, 0.4, 7.6],
                    cf(0, FLOOR_TOP + 0.9, 0), STEEL, "DiamondPlate"))
    out.append(part("FrameLegLow", [2.4, 1.4, 0.4],
                    cf(0, FLOOR_TOP + 0.7, -3.2), STEEL, "DiamondPlate"))
    out.append(part("FrameLegHigh", [2.4, 2.8, 0.4],
                    cf(0, FLOOR_TOP + 1.4, 3.2), STEEL, "DiamondPlate"))

    pad = mul(cf(0, FLOOR_TOP + 2.0, 0), rot_x(-slope))
    out.append(part("Base", [2.6, 0.5, 7.2], pad, pad_color, "Fabric"))

    # Rollers the lifter hooks their ankles under, at the low end.
    for offset in (-0.55, 0.55):
        out.append(cylinder("Roller", 2.4, 1.0,
                            mul(pad, cf(0, 0.95, -3.1 + offset * 1.1)),
                            RUBBER, "Pebble"))
    out.append(part("RollerPost", [0.35, 1.6, 0.35],
                    mul(pad, cf(0, 0.55, -3.1)), accent, "Metal"))

    # Reclined along the pad: rot_x(90) tips the body from standing onto its
    # back, so the head runs up the slope and the face points away from the pad.
    out.append(marker("TrainAnchor", [2, 2, 1],
                      mul(pad, mul(cf(0, 1.35, 0.3), rot_x(90)))))
    out.append(marker("TrainExit", [2, 2, 1],
                      mul(cf(3.2, FLOOR_TOP + ROOT_HEIGHT, 0), rot_y(-90))))
    return out


def treadmill(pad_color, accent):
    """Belt, side rails and a console. The player runs facing the readout."""
    out = [floor_mat(8, 12)]

    out.append(part("Deck", [4.2, 0.7, 8.4],
                    mul(cf(0, FLOOR_TOP + 0.75, 0), rot_x(-4)), STEEL, "DiamondPlate"))
    out.append(part("Base", [3.4, 0.22, 7.6],
                    mul(cf(0, FLOOR_TOP + 1.16, 0), rot_x(-4)), RUBBER, "Pebble"))
    for side in (-1, 1):
        out.append(part("Rail", [0.45, 0.45, 6.2],
                        cf(side * 2.15, FLOOR_TOP + 2.6, -0.4), CHROME, "Metal",
                        Reflectance=0.2))
        out.append(part("RailPost", [0.4, 1.9, 0.4],
                        cf(side * 2.15, FLOOR_TOP + 1.75, 2.2), STEEL, "Metal"))

    # Console at the far end, so a runner faces -Z into the room's mirror wall.
    out.append(part("ConsolePost", [3.6, 3.4, 0.4],
                    cf(0, FLOOR_TOP + 2.5, -4.0), STEEL, "Metal"))
    out.append(part("Console", [3.4, 1.9, 0.5],
                    mul(cf(0, FLOOR_TOP + 4.3, -3.9), rot_x(18)), STEEL_LIGHT, "Metal"))
    out.append(part("Readout", [2.6, 1.2, 0.12],
                    mul(cf(0, FLOOR_TOP + 4.36, -3.65), rot_x(18)), accent, "Neon"))
    out.append(cylinder("Handlebar", 3.9, 0.34, cf(0, FLOOR_TOP + 3.5, -3.3),
                        CHROME, "Metal", Reflectance=0.25))

    # Standing on the belt, facing the console.
    out.append(anchor_standing(cf(0, FLOOR_TOP + 1.3, -0.2)))
    out.append(marker("TrainExit", [2, 2, 1],
                      cf(0, FLOOR_TOP + ROOT_HEIGHT, 5.2)))
    return out


BUILDERS = {
    "BenchPress": bench_press,
    "Dumbbells": dumbbell_rack,
    "PullUpBar": pull_up_rig,
    "SitUpBench": sit_up_bench,
    "Treadmill": treadmill,
}


# --------------------------------------------------------------------------
# The world.
#
# Eleven training platforms on a spiral out to ~1,600 studs, so the map is a bit
# over 3,000 studs across. Tiers must match ZoneConfig by id; the ids and the
# power gates live there, the geometry lives here, and ZoneService warns at boot
# if either side names a tier the other does not.
#
# The first three sit on the ground and can be walked to. Everything past them
# floats, at a height that climbs with tier, so the back half of the map is only
# reachable by flying — which makes the movement ladder and the progression
# ladder the same ladder.
# --------------------------------------------------------------------------

# (zone id, accent colour, pad colour, platform half-size, altitude)
TIERS = [
    ("Garage", ACCENT_STARTER, PAD_RED, 70, 0),
    ("Iron", ACCENT_IRON, PAD_BLUE, 75, 0),
    ("Powerhouse", [0.94, 0.42, 0.24], [0.42, 0.16, 0.10], 80, 0),
    ("Strongman", [0.75, 0.47, 0.27], [0.34, 0.22, 0.13], 85, 120),
    ("Titan", [1.0, 0.77, 0.24], [0.40, 0.28, 0.08], 90, 260),
    ("Skydeck", [0.47, 0.82, 1.0], [0.13, 0.30, 0.42], 90, 420),
    ("Storm", [0.59, 0.63, 1.0], [0.18, 0.20, 0.40], 95, 600),
    ("Void", [0.63, 0.43, 0.92], [0.20, 0.12, 0.34], 95, 800),
    ("Solar", [1.0, 0.55, 0.24], [0.42, 0.20, 0.08], 100, 1020),
    ("Nebula", [1.0, 0.43, 0.75], [0.40, 0.14, 0.30], 100, 1260),
    ("Ascendant", [1.0, 0.96, 0.78], [0.38, 0.36, 0.28], 110, 1520),
]

# Where the hub sits, and how far out the first and last platforms are.
HUB_RADIUS = 46
FIRST_RADIUS = 210
RADIUS_STEP = 138
# A spiral rather than a ring: consecutive tiers never line up, so the walk out
# always reveals a new direction instead of a corridor.
SPIRAL_DEGREES = 137.5


def tier_origin(index):
    """Where a tier's platform sits, as a CFrame facing back toward the hub."""
    radius = FIRST_RADIUS + index * RADIUS_STEP
    angle = math.radians(index * SPIRAL_DEGREES)
    x = math.sin(angle) * radius
    z = math.cos(angle) * radius
    altitude = TIERS[index][4]
    # Face the hub, so a player arriving at the spawn pad is looking at the gym.
    return mul(cf(x, altitude, z), rot_y(math.degrees(angle) + 180))


def platform(zone_id, accent, half, altitude):
    """A tier's floor, edge trim, corner pylons and lights, in local space."""
    out = []
    size = half * 2

    out.append(part("Deck", [size, 4, size], cf(0, FLOOR_TOP - 2, 0), FLOOR_DARK, "Concrete"))
    out.append(part("DeckTrim", [size + 4, 1.2, size + 4], cf(0, FLOOR_TOP - 4.4, 0),
                    [c * 0.5 for c in accent], "Metal"))
    out.append(part("Rug", [size * 0.45, 0.1, size * 0.45], cf(0, FLOOR_TOP + 0.05, 0),
                    [c * 0.22 for c in accent], "Pebble", CanCollide=False))

    # A low kerb so a running player is nudged rather than walking off a floating
    # slab, but low enough to step over deliberately.
    for sx, sz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        length = size + 3 if sx == 0 else 3
        width = size + 3 if sz == 0 else 3
        out.append(part("Kerb", [width, 2.4, length],
                        cf(sx * (half + 1.5), FLOOR_TOP + 1.2, sz * (half + 1.5)),
                        [c * 0.6 for c in accent], "Metal"))

    for sx in (-1, 1):
        for sz in (-1, 1):
            out.append(part("Pylon", [5, 26, 5],
                            cf(sx * (half - 4), FLOOR_TOP + 13, sz * (half - 4)), STEEL, "DiamondPlate"))
            beacon = part("Beacon", [6, 2.5, 6],
                          cf(sx * (half - 4), FLOOR_TOP + 27, sz * (half - 4)), accent, "Neon",
                          CanCollide=False)
            beacon["children"] = [{
                "name": "Glow",
                "className": "PointLight",
                "properties": {
                    "Brightness": 3,
                    "Range": 60,
                    "Color": accent,
                },
            }]
            out.append(beacon)

    # The spawn pad a gate delivers players onto.
    pad = part("SpawnPad", [16, 1, 16], cf(0, FLOOR_TOP + 0.5, half - 16), accent, "Neon")
    pad["properties"]["Tags"] = ["ZoneSpawn"]
    pad["attributes"] = {"ZoneId": zone_id}
    out.append(pad)

    return out


def zone_volume(zone_id, origin, half):
    """The invisible box token accrual and machine tiering both test against."""
    return place(origin, {
        "name": f"{zone_id}Volume",
        "className": "Part",
        "attributes": {"ZoneId": zone_id},
        "properties": {
            "Tags": ["GymZone"],
            "Anchored": True,
            "Locked": True,
            "CanCollide": False,
            "Transparency": 1,
            "CastShadow": False,
            "Size": [half * 2 + 8, 90, half * 2 + 8],
            "CFrame": serialise_cf(cf(0, 40, 0)),
            "Material": "SmoothPlastic",
        },
    })


# Where each machine stands on a platform, as a fraction of its half-size, and
# which way it faces. Spread to the edges on purpose: crossing a platform to
# change exercise should take a moment.
MACHINE_SPOTS = [
    ("BenchPress", -0.55, -0.5, 0),
    ("Dumbbells", 0.6, -0.5, -90),
    ("PullUpBar", -0.6, 0.45, 0),
    ("SitUpBench", 0.0, -0.62, 0),
    ("Treadmill", 0.6, 0.45, 180),
]


def build_world():
    structure = []
    machines = []

    # Hub: the safe plaza everybody starts on, ringed with one gate per tier.
    structure.append(part("HubDeck", [HUB_RADIUS * 2, 4, HUB_RADIUS * 2],
                          cf(0, FLOOR_TOP - 2, 0), FLOOR_DARK, "Concrete"))
    structure.append(part("HubTrim", [HUB_RADIUS * 2 + 6, 1.4, HUB_RADIUS * 2 + 6],
                          cf(0, FLOOR_TOP - 4.6, 0), [0.30, 0.33, 0.40], "Metal"))

    safe = part("SpawnSafeZone", [40, 20, 40], cf(0, FLOOR_TOP + 10, 0),
                [0.4, 0.8, 1.0], "ForceField", CanCollide=False, Transparency=0.9,
                CastShadow=False)
    safe["properties"]["Tags"] = ["SafeZone"]
    structure.append(safe)

    for index, (zone_id, accent, pad_color, half, altitude) in enumerate(TIERS):
        origin = tier_origin(index)

        # Gate on the hub rim, pointing at its tier. Touch it with the power and
        # ZoneService puts you on that tier's spawn pad.
        angle = index * SPIRAL_DEGREES
        gate_at = mul(cf(0, 0, 0), rot_y(angle))
        gate = part(f"{zone_id}Gate", [12, 11, 2],
                    mul(gate_at, cf(0, FLOOR_TOP + 6, HUB_RADIUS - 4)), accent, "ForceField",
                    CanCollide=False, Transparency=0.4)
        gate["properties"]["Tags"] = ["ZoneGate"]
        gate["attributes"] = {"ZoneId": zone_id}
        structure.append(gate)

        post = part(f"{zone_id}GatePost", [14, 1.5, 3],
                    mul(gate_at, cf(0, FLOOR_TOP + 0.6, HUB_RADIUS - 4)), accent, "Neon")
        structure.append(post)

        for piece in platform(zone_id, accent, half, altitude):
            structure.append(place(origin, piece))
        structure.append(zone_volume(zone_id, origin, half))

        for equipment_id, fx, fz, facing in MACHINE_SPOTS:
            spot = mul(cf(fx * half, 0, fz * half), rot_y(facing))
            machines.append(machine(
                f"{zone_id}{equipment_id}", equipment_id, mul(origin, spot),
                BUILDERS[equipment_id](pad_color, accent),
            ))

    return ({"className": "Folder", "children": structure},
            {"className": "Folder", "children": machines})


def write(name, payload):
    path = os.path.abspath(os.path.join(OUT_DIR, name))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    print(f"wrote {os.path.relpath(path)}")


def main():
    structure, machines = build_world()
    write("init.meta.json", {"className": "Model"})
    write("Structure.model.json", structure)
    write("Machines.model.json", machines)


if __name__ == "__main__":
    main()
