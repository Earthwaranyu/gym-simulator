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
import random

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


def machine(name, equipment_id, origin, children, travel_id=None,
            access_kind=None, floor_index=None, exercise_family=None,
            environment_id=None, requires_flight=False, location_name=None,
            location_tagline=None):
    # Atomic streaming: a machine arrives whole or not at all. Under the default
    # mode Roblox streams a model's parts in one at a time, and a bench press
    # missing its rack — or worse, missing the TrainAnchor the server pivots you
    # onto — is what a 2,800-stud map with StreamingEnabled hands you otherwise.
    attributes = {"EquipmentId": equipment_id}
    if travel_id is not None:
        attributes["TravelId"] = travel_id
    if access_kind is not None:
        attributes["AccessKind"] = access_kind
    if floor_index is not None:
        attributes["FloorIndex"] = floor_index
    if exercise_family is not None:
        attributes["ExerciseFamily"] = exercise_family
    attributes["VariantId"] = equipment_id
    if environment_id is not None:
        attributes["EnvironmentId"] = environment_id
    attributes["RequiresFlight"] = requires_flight
    if location_name is not None:
        attributes["LocationName"] = location_name
    if location_tagline is not None:
        attributes["LocationTagline"] = location_tagline
    return {
        "name": name,
        "className": "Model",
        "attributes": attributes,
        "properties": {"Tags": ["TrainingStation"], "ModelStreamingMode": "Atomic"},
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


def incline_press(pad_color, accent):
    """Incline dumbbell press on a 32-degree adjustable bench."""
    out = [floor_mat(11, 13)]
    bench = mul(cf(0, FLOOR_TOP + 2.15, 0.5), rot_x(-32))
    out.extend([
        part("BenchSpine", [0.6, 0.5, 8.0], bench, STEEL, "DiamondPlate"),
        part("Base", [3.2, 0.65, 5.2], bench, pad_color, "Fabric"),
        part("SeatPad", [3.2, 0.65, 2.4],
             mul(cf(0, FLOOR_TOP + 1.45, 3.0), rot_x(8)), pad_color, "Fabric"),
        part("RearFoot", [4.4, 1.8, 0.55], cf(0, FLOOR_TOP + 0.9, -2.6), STEEL, "Metal"),
        part("FrontFoot", [4.4, 0.55, 1.8], cf(0, FLOOR_TOP + 0.28, 3.0), STEEL, "Metal"),
        part("AngleBrace", [0.55, 3.5, 0.55], cf(0, FLOOR_TOP + 1.75, -1.8), accent, "Metal"),
    ])

    def dumbbell(name, x):
        pieces = [cylinder("Handle", 1.5, 0.3, cf(x, FLOOR_TOP + 2.1, 1.0),
                           CHROME, "Metal", CanCollide=False, CanTouch=False,
                           CanQuery=False)]
        for side in (-1, 1):
            pieces.append(cylinder("Head", 0.72, 1.5,
                                   cf(x + side * 0.92, FLOOR_TOP + 2.1, 1.0),
                                   RUBBER, "Pebble", CanCollide=False,
                                   CanTouch=False, CanQuery=False))
        return group(name, pieces)

    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1],
               mul(bench, mul(cf(0, 1.25, 0.2), rot_x(90)))),
        dumbbell("HeldRight", -2.0),
        dumbbell("HeldLeft", 2.0),
    ]))
    out.append(marker("TrainExit", [2, 2, 1],
                      mul(cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 1.5), rot_y(-90))))
    return out


def pec_deck(pad_color, accent):
    """Selectorised fly station; the hands sweep two independent grips inward."""
    out = [floor_mat(12, 12)]
    out.extend([
        part("Base", [8.0, 0.55, 8.5], cf(0, FLOOR_TOP + 0.28, -0.2), STEEL, "DiamondPlate"),
        part("SeatPost", [1.2, 2.2, 1.2], cf(0, FLOOR_TOP + 1.1, 1.8), STEEL, "Metal"),
        part("Seat", [4.0, 0.6, 4.0], cf(0, FLOOR_TOP + 2.35, 1.8), pad_color, "Fabric"),
        part("BackPad", [4.4, 6.0, 0.7], cf(0, FLOOR_TOP + 5.2, 3.4), pad_color, "Fabric"),
        part("TopBeam", [11.0, 0.7, 0.8], cf(0, FLOOR_TOP + 9.0, 1.2), STEEL, "Metal"),
    ])
    for side in (-1, 1):
        out.extend([
            part("WeightTower", [2.0, 8.5, 2.4],
                 cf(side * 4.6, FLOOR_TOP + 4.25, 1.2), STEEL_LIGHT, "Metal"),
            part("FlyArm", [0.55, 5.2, 0.55],
                 mul(cf(side * 3.7, FLOOR_TOP + 6.4, 0.2), rot_z(side * 35)),
                 accent, "Metal"),
        ])

    def grip(name, x):
        return group(name, [cylinder(
            "Grip", 1.4, 0.48, cf(x, FLOOR_TOP + 5.0, -0.2),
            CHROME, "Pebble", CanCollide=False, CanTouch=False, CanQuery=False,
        )])

    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.4, 1.8)),
        grip("HeldRight", -2.6),
        grip("HeldLeft", 2.6),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 5.7)))
    return out


def barbell_curl(pad_color, accent):
    """A short street rack for synchronized standing barbell curls."""
    out = [floor_mat(11, 10)]
    out.extend([
        part("Base", [10.0, 0.55, 4.0], cf(0, FLOOR_TOP + 0.28, -2.5), STEEL, "DiamondPlate"),
        part("RackBack", [10.0, 3.8, 0.6], cf(0, FLOOR_TOP + 2.0, -3.7), STEEL_LIGHT, "Metal"),
        part("RackStripe", [10.0, 0.35, 0.75], cf(0, FLOOR_TOP + 3.6, -3.35), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.append(part("CurlHook", [0.6, 2.5, 2.0],
                        cf(side * 3.5, FLOOR_TOP + 1.25, -2.4), STEEL, "Metal"))

    bar = [cylinder("Bar", 7.2, 0.3, cf(0, FLOOR_TOP + 2.1, -2.2),
                    CHROME, "Metal", Reflectance=0.3, CanCollide=False,
                    CanTouch=False, CanQuery=False)]
    for side in (-1, 1):
        bar.append(cylinder("Plate", 0.6, 1.8,
                            cf(side * 3.0, FLOOR_TOP + 2.1, -2.2),
                            RUBBER, "Pebble", CanCollide=False, CanTouch=False,
                            CanQuery=False))
    out.append(group("Spot", [
        anchor_standing(cf(0, FLOOR_TOP, 0.8)),
        group("HeldBoth", bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.7)))
    return out


def triceps_pushdown(pad_color, accent):
    """A cable-stack pushdown station with a short two-hand bar."""
    out = [floor_mat(10, 11)]
    out.extend([
        part("Base", [5.0, 0.65, 5.0], cf(0, FLOOR_TOP + 0.33, -3.0), STEEL, "DiamondPlate"),
        part("WeightStack", [3.8, 8.0, 2.5], cf(0, FLOOR_TOP + 4.0, -3.4), STEEL_LIGHT, "Metal"),
        part("StackStripe", [4.0, 0.45, 2.7], cf(0, FLOOR_TOP + 6.8, -3.4), accent, "Neon"),
        part("PulleyPost", [0.8, 10.5, 0.8], cf(0, FLOOR_TOP + 5.25, -2.0), STEEL, "Metal"),
        part("PulleyArm", [0.8, 0.8, 4.0], cf(0, FLOOR_TOP + 10.1, -0.4), STEEL, "Metal"),
        cylinder("Pulley", 0.8, 1.7, cf(0, FLOOR_TOP + 9.4, 1.2), CHROME, "Metal"),
        part("Cable", [0.12, 5.0, 0.12], cf(0, FLOOR_TOP + 7.0, 1.2), RUBBER,
             "SmoothPlastic", CanCollide=False, CanTouch=False, CanQuery=False),
    ])
    bar = [cylinder("PushBar", 4.0, 0.38, cf(0, FLOOR_TOP + 4.6, 1.2),
                    CHROME, "Metal", CanCollide=False, CanTouch=False,
                    CanQuery=False)]
    out.append(group("Spot", [
        anchor_standing(cf(0, FLOOR_TOP, 2.5)),
        group("HeldBoth", bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(3.8, FLOOR_TOP + ROOT_HEIGHT, 2.5)))
    return out


def seated_row(pad_color, accent):
    """Low cable row with a seat, foot plates, stack and close-grip handle."""
    out = [floor_mat(10, 13)]
    out.extend([
        part("Base", [4.5, 0.55, 10.0], cf(0, FLOOR_TOP + 0.28, 0), STEEL, "DiamondPlate"),
        part("Seat", [4.2, 0.65, 4.0], cf(0, FLOOR_TOP + 2.1, 2.7), pad_color, "Fabric"),
        part("SeatPost", [1.0, 1.8, 1.0], cf(0, FLOOR_TOP + 0.9, 2.7), STEEL, "Metal"),
        part("WeightTower", [4.0, 7.5, 2.4], cf(0, FLOOR_TOP + 3.75, -4.4), STEEL_LIGHT, "Metal"),
        part("TowerStripe", [4.2, 0.45, 2.6], cf(0, FLOOR_TOP + 6.3, -4.4), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.append(part("FootPlate", [3.0, 0.4, 3.4],
                        mul(cf(side * 2.1, FLOOR_TOP + 1.2, -0.7), rot_z(side * 28)),
                        STEEL, "DiamondPlate"))
    handle = [cylinder("RowHandle", 3.2, 0.4, cf(0, FLOOR_TOP + 3.5, -1.6),
                       CHROME, "Metal", CanCollide=False, CanTouch=False,
                       CanQuery=False)]
    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.2, 2.7)),
        group("HeldBoth", handle),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 3.6)))
    return out


def lat_pulldown(pad_color, accent):
    """Tall dual-tower pulldown with thigh restraint and an overhead bar."""
    out = [floor_mat(12, 12)]
    out.extend([
        part("Base", [10.0, 0.6, 9.0], cf(0, FLOOR_TOP + 0.3, -0.2), STEEL, "DiamondPlate"),
        part("Seat", [4.0, 0.65, 4.0], cf(0, FLOOR_TOP + 2.1, 1.8), pad_color, "Fabric"),
        part("SeatPost", [1.0, 1.8, 1.0], cf(0, FLOOR_TOP + 0.9, 1.8), STEEL, "Metal"),
        cylinder("ThighRoller", 5.0, 1.0, cf(0, FLOOR_TOP + 3.5, 0.2), RUBBER, "Pebble"),
        part("TopCrossbar", [10.5, 0.8, 0.8], cf(0, FLOOR_TOP + 11.0, -1.5), STEEL, "Metal"),
    ])
    for side in (-1, 1):
        out.append(part("WeightTower", [2.1, 10.5, 2.3],
                        cf(side * 4.4, FLOOR_TOP + 5.25, -1.5), STEEL_LIGHT, "Metal"))
    bar = [cylinder("LatBar", 8.0, 0.38, cf(0, FLOOR_TOP + 9.5, 0),
                    CHROME, "Metal", CanCollide=False, CanTouch=False,
                    CanQuery=False)]
    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.2, 1.8)),
        group("HeldBoth", bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(4.6, FLOOR_TOP + ROOT_HEIGHT, 3.6)))
    return out


def knee_raise(pad_color, accent):
    """Captain's chair for supported hanging knee raises."""
    out = [floor_mat(10, 10)]
    out.extend([
        part("Base", [8.0, 0.65, 6.0], cf(0, FLOOR_TOP + 0.33, -1.0), STEEL, "DiamondPlate"),
        part("BackFrame", [6.0, 9.0, 0.8], cf(0, FLOOR_TOP + 5.0, -3.0), STEEL, "Metal"),
        part("BackPad", [4.4, 5.5, 0.65], cf(0, FLOOR_TOP + 6.0, -2.45), pad_color, "Fabric"),
        part("TopStripe", [6.2, 0.5, 1.0], cf(0, FLOOR_TOP + 9.7, -2.7), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.extend([
            part("ArmRest", [2.0, 0.65, 4.5],
                 cf(side * 2.7, FLOOR_TOP + 6.0, -0.2), pad_color, "Fabric"),
            cylinder("Handle", 2.3, 0.42,
                     mul(cf(side * 2.7, FLOOR_TOP + 6.35, 1.2), rot_y(90)),
                     CHROME, "Metal"),
        ])
    out.append(marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 5.4, -0.5)))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.2)))
    return out


def torso_twist(pad_color, accent):
    """Seated torso-rotation station with a medicine ball held in both hands."""
    out = [floor_mat(10, 10)]
    out.extend([
        cylinder("Base", 0.7, 7.0, mul(cf(0, FLOOR_TOP + 0.35, 0), rot_z(90)),
                 STEEL, "DiamondPlate"),
        part("SeatPost", [1.0, 1.8, 1.0], cf(0, FLOOR_TOP + 0.9, 0), STEEL, "Metal"),
        part("Seat", [4.4, 0.65, 4.2], cf(0, FLOOR_TOP + 2.2, 0), pad_color, "Fabric"),
        part("FootBrace", [7.0, 0.5, 2.5], cf(0, FLOOR_TOP + 0.8, 2.3), STEEL, "Metal"),
        part("ArcGauge", [8.0, 0.35, 0.8], cf(0, FLOOR_TOP + 0.25, -3.0), accent, "Neon"),
    ])
    ball = [part("MedicineBall", [2.2, 2.2, 2.2], cf(0, FLOOR_TOP + 4.5, -1.2),
                 accent, "Rubber", Shape="Ball", CanCollide=False,
                 CanTouch=False, CanQuery=False)]
    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.2, 0)),
        group("HeldBoth", ball),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 2.0)))
    return out


def squat_rack(pad_color, accent):
    """Open squat cage with a locally carried barbell."""
    out = [floor_mat(12, 12)]
    for side in (-1, 1):
        for z in (-3.8, 3.8):
            out.append(part("RackPost", [0.75, 10.0, 0.75],
                            cf(side * 4.4, FLOOR_TOP + 5.0, z), STEEL, "DiamondPlate"))
        out.append(part("RackTop", [0.75, 0.75, 8.3],
                        cf(side * 4.4, FLOOR_TOP + 9.7, 0), STEEL, "Metal"))
    out.extend([
        part("Base", [10.0, 0.45, 9.0], cf(0, FLOOR_TOP + 0.23, 0), STEEL, "DiamondPlate"),
        part("TopBeam", [9.6, 0.75, 0.75], cf(0, FLOOR_TOP + 9.7, -3.8), accent, "Metal"),
    ])
    bar = [cylinder("Bar", 9.4, 0.34, cf(0, FLOOR_TOP + 6.3, 0),
                    CHROME, "Metal", CanCollide=False, CanTouch=False,
                    CanQuery=False)]
    for side in (-1, 1):
        for offset in (3.4, 4.0):
            bar.append(cylinder("Plate", 0.55, 2.0,
                                cf(side * offset, FLOOR_TOP + 6.3, 0),
                                RUBBER, "Pebble", CanCollide=False,
                                CanTouch=False, CanQuery=False))
    out.append(group("Spot", [
        anchor_standing(cf(0, FLOOR_TOP, 0.4)),
        group("HeldBoth", bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 6.1)))
    return out


def leg_press(pad_color, accent):
    """Reclined sled press; the avatar extends against a broad fixed footplate."""
    out = [floor_mat(12, 14)]
    seat_frame = mul(cf(0, FLOOR_TOP + 2.1, 2.4), rot_x(28))
    out.extend([
        part("Base", [7.0, 0.6, 11.0], cf(0, FLOOR_TOP + 0.3, 0), STEEL, "DiamondPlate"),
        part("Seat", [5.0, 0.7, 4.0], seat_frame, pad_color, "Fabric"),
        part("BackPad", [5.0, 0.7, 6.0],
             mul(cf(0, FLOOR_TOP + 3.8, 4.1), rot_x(58)), pad_color, "Fabric"),
        part("FootPlate", [7.5, 0.65, 7.5],
             mul(cf(0, FLOOR_TOP + 5.0, -3.7), rot_x(-38)), STEEL_LIGHT, "DiamondPlate"),
        part("SledStripe", [7.7, 0.4, 1.0],
             mul(cf(0, FLOOR_TOP + 5.4, -3.2), rot_x(-38)), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.append(part("Rail", [0.55, 0.55, 10.0],
                        mul(cf(side * 3.4, FLOOR_TOP + 3.2, -0.4), rot_x(-25)),
                        CHROME, "Metal"))
    out.append(marker("TrainAnchor", [2, 2, 1],
                      mul(seat_frame, mul(cf(0, 1.4, 1.0), rot_x(90)))))
    out.append(marker("TrainExit", [2, 2, 1],
                      mul(cf(5.0, FLOOR_TOP + ROOT_HEIGHT, 3.6), rot_y(-90))))
    return out


def _held_bar(name, length, y, z, accent, diameter=0.38):
    """A collision-free two-hand prop whose long axis is local X."""
    return group(name, [cylinder(
        "Grip", length, diameter, cf(0, y, z), accent, "Metal",
        CanCollide=False, CanTouch=False, CanQuery=False,
    )])


def push_up_deck(pad_color, accent):
    """Low weighted push-up platform with parallel hand blocks."""
    out = [floor_mat(11, 12)]
    out.extend([
        part("Base", [8.5, 0.65, 10.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Deck", [7.5, 0.3, 9.0], cf(0, FLOOR_TOP + 0.8, 0), pad_color, "Rubber"),
        cylinder("RightHandle", 2.2, 0.45, cf(-2.0, FLOOR_TOP + 1.25, -2.2), CHROME),
        cylinder("LeftHandle", 2.2, 0.45, cf(2.0, FLOOR_TOP + 1.25, -2.2), CHROME),
        part("WeightMarker", [5.0, 0.2, 0.7], cf(0, FLOOR_TOP + 1.0, 2.8), accent, "Neon"),
        marker("TrainAnchor", [2, 2, 1],
               axes((0, FLOOR_TOP + 2.25, 0.5), (-1, 0, 0), (0, 0, -1))),
        marker("TrainExit", [2, 2, 1], cf(5.0, FLOOR_TOP + ROOT_HEIGHT, 1.5)),
    ])
    return out


def cable_crossover(pad_color, accent):
    """Twin cable towers with independent hand grips."""
    out = [floor_mat(14, 12)]
    for side in (-1, 1):
        out.extend([
            part("Tower", [2.4, 10.5, 3.0], cf(side * 5.2, FLOOR_TOP + 5.25, -1.5),
                 STEEL_LIGHT, "Metal"),
            part("PulleyArm", [4.2, 0.65, 0.65], cf(side * 3.7, FLOOR_TOP + 9.8, -1.5),
                 STEEL, "Metal"),
            part("Cable", [0.1, 6.0, 0.1], cf(side * 2.0, FLOOR_TOP + 6.7, -1.5),
                 RUBBER, "SmoothPlastic", CanCollide=False),
        ])
    out.extend([
        part("Base", [12.8, 0.55, 5.0], cf(0, FLOOR_TOP + 0.28, -1.5), STEEL, "DiamondPlate"),
        part("CrossBeam", [12.0, 0.65, 0.65], cf(0, FLOOR_TOP + 10.3, -1.5), accent, "Metal"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 2.0)),
            _held_bar("HeldRight", 1.2, FLOOR_TOP + 5.0, -0.5, CHROME),
            _held_bar("HeldLeft", 1.2, FLOOR_TOP + 5.0, -2.4, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 5.2)),
    ])
    return out


def chest_dip(pad_color, accent):
    """Raised parallel dip bars with a recovery step."""
    out = [floor_mat(10, 10)]
    out.extend([
        part("Base", [8.5, 0.7, 7.0], cf(0, FLOOR_TOP + 0.35, -0.5), STEEL, "DiamondPlate"),
        part("BackPost", [1.1, 8.5, 1.1], cf(0, FLOOR_TOP + 4.25, -2.8), STEEL, "Metal"),
        part("Step", [4.0, 0.6, 2.0], cf(0, FLOOR_TOP + 1.4, 2.5), pad_color, "Rubber"),
        part("TopSign", [6.0, 0.5, 1.2], cf(0, FLOOR_TOP + 8.2, -2.8), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.append(cylinder("DipBar", 6.0, 0.48,
                            mul(cf(side * 1.8, FLOOR_TOP + 5.2, 0), rot_y(90)), CHROME))
    out.extend([
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 5.1, -0.2)),
        marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.2)),
    ])
    return out


def decline_press(pad_color, accent):
    """Head-low decline bench with a carried loaded bar."""
    out = [floor_mat(11, 13)]
    pad = mul(cf(0, FLOOR_TOP + 2.1, 0), rot_x(18))
    out.extend([
        part("Base", [3.2, 0.6, 8.2], pad, pad_color, "Fabric"),
        part("Frame", [0.7, 1.0, 9.0], cf(0, FLOOR_TOP + 0.7, 0), STEEL, "DiamondPlate"),
        cylinder("AnkleRoller", 4.0, 1.1, cf(0, FLOOR_TOP + 3.7, 3.6), RUBBER, "Pebble"),
        part("Rack", [8.5, 6.0, 0.7], cf(0, FLOOR_TOP + 3.0, -4.1), STEEL, "Metal"),
        part("RackStripe", [8.7, 0.4, 0.9], cf(0, FLOOR_TOP + 5.8, -4.1), accent, "Neon"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], mul(pad, mul(cf(0, 1.35, 0), rot_x(90)))),
            _held_bar("HeldBoth", 7.5, FLOOR_TOP + 4.7, -1.0, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.5, FLOOR_TOP + ROOT_HEIGHT, 2.0)),
    ])
    return out


def hammer_curl(pad_color, accent):
    """Vertical-grip dumbbell rack for neutral-grip curls."""
    out = [floor_mat(10, 9)]
    out.extend([
        part("Base", [8.5, 0.65, 4.2], cf(0, FLOOR_TOP + 0.33, -2.2), STEEL, "DiamondPlate"),
        part("Rack", [8.0, 4.5, 1.0], cf(0, FLOOR_TOP + 2.3, -3.2), STEEL_LIGHT, "Metal"),
        part("Stripe", [8.2, 0.4, 1.2], cf(0, FLOOR_TOP + 4.3, -3.2), accent, "Neon"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 1.0)),
            _held_bar("HeldRight", 1.6, FLOOR_TOP + 2.8, -2.4, CHROME, 0.65),
            _held_bar("HeldLeft", 1.6, FLOOR_TOP + 2.8, -1.0, CHROME, 0.65),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def preacher_curl(pad_color, accent):
    """Angled arm pad and EZ-bar cradle."""
    out = [floor_mat(10, 11)]
    pad = mul(cf(0, FLOOR_TOP + 4.2, -0.5), rot_x(-48))
    out.extend([
        part("Base", [7.0, 0.6, 8.5], cf(0, FLOOR_TOP + 0.3, 0), STEEL, "DiamondPlate"),
        part("Seat", [4.0, 0.65, 3.5], cf(0, FLOOR_TOP + 2.2, 2.7), pad_color, "Fabric"),
        part("PreacherPad", [5.6, 0.8, 4.6], pad, pad_color, "Fabric"),
        part("PadPost", [0.8, 4.0, 0.8], cf(0, FLOOR_TOP + 2.0, -0.4), STEEL, "Metal"),
        part("Cradle", [6.0, 0.4, 1.0], cf(0, FLOOR_TOP + 2.1, -3.1), accent, "Metal"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.2, 2.7)),
            _held_bar("HeldBoth", 5.5, FLOOR_TOP + 2.6, -2.5, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out


def skull_crusher(pad_color, accent):
    """Flat triceps bench with a short EZ bar above the forehead."""
    out = [floor_mat(10, 12)]
    out.extend([
        part("Base", [3.3, 0.65, 8.0], cf(0, FLOOR_TOP + 1.7, 0), pad_color, "Fabric"),
        part("BenchFrame", [0.7, 1.2, 9.0], cf(0, FLOOR_TOP + 0.7, 0), STEEL, "DiamondPlate"),
        part("BarStand", [7.0, 4.8, 0.6], cf(0, FLOOR_TOP + 2.4, -4.0), STEEL, "Metal"),
        part("WarningStripe", [7.2, 0.4, 0.8], cf(0, FLOOR_TOP + 4.6, -4.0), accent, "Neon"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1],
                   axes((0, FLOOR_TOP + 2.9, 0), (-1, 0, 0), (0, 0, -1))),
            _held_bar("HeldBoth", 5.8, FLOOR_TOP + 4.2, -1.2, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 1.5)),
    ])
    return out


def battle_ropes(pad_color, accent):
    """Two long ropes anchored to a weighted floor post."""
    out = [floor_mat(14, 14)]
    out.extend([
        cylinder("Base", 0.8, 4.5, mul(cf(0, FLOOR_TOP + 0.4, -5.0), rot_z(90)),
                 STEEL, "DiamondPlate"),
        part("AnchorPost", [1.2, 3.5, 1.2], cf(0, FLOOR_TOP + 1.75, -5.0), STEEL, "Metal"),
        part("RopeRight", [0.35, 0.35, 8.5], mul(cf(-1.0, FLOOR_TOP + 0.8, -0.7), rot_x(-4)),
             accent, "Fabric", CanCollide=False),
        part("RopeLeft", [0.35, 0.35, 8.5], mul(cf(1.0, FLOOR_TOP + 0.8, -0.7), rot_x(4)),
             accent, "Fabric", CanCollide=False),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 4.0)),
            _held_bar("HeldRight", 1.2, FLOOR_TOP + 3.5, 1.3, accent),
            _held_bar("HeldLeft", 1.2, FLOOR_TOP + 3.5, 2.7, accent),
        ]),
        marker("TrainExit", [2, 2, 1], cf(5.5, FLOOR_TOP + ROOT_HEIGHT, 4.0)),
    ])
    return out


def deadlift_platform(pad_color, accent):
    """Reinforced lifting platform with a heavy carried barbell."""
    out = [floor_mat(13, 11)]
    out.extend([
        part("Base", [12.0, 0.8, 9.0], cf(0, FLOOR_TOP + 0.4, 0), STEEL, "DiamondPlate"),
        part("OakCenter", [6.5, 0.2, 8.2], cf(0, FLOOR_TOP + 0.9, 0), pad_color, "WoodPlanks"),
        part("BackStop", [12.0, 1.0, 1.0], cf(0, FLOOR_TOP + 1.2, -4.5), accent, "Metal"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP + 0.8, 1.1)),
            _held_bar("HeldBoth", 10.5, FLOOR_TOP + 1.8, -0.6, CHROME, 0.5),
        ]),
        marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 5.5)),
    ])
    return out


def t_bar_row(pad_color, accent):
    """Landmine row rail with chest brace and close handle."""
    out = [floor_mat(11, 13)]
    rail = mul(cf(0, FLOOR_TOP + 1.4, -0.4), rot_x(-10))
    out.extend([
        part("Base", [7.5, 0.65, 11.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("TBarRail", [0.7, 0.7, 10.0], rail, CHROME, "Metal"),
        part("ChestPad", [4.0, 0.8, 3.5], mul(cf(0, FLOOR_TOP + 4.0, 2.2), rot_x(-35)),
             pad_color, "Fabric"),
        part("PlateStop", [5.5, 2.0, 1.0], cf(0, FLOOR_TOP + 1.4, -4.6), accent, "Metal"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], mul(cf(0, FLOOR_TOP + 3.4, 2.5), rot_x(25))),
            _held_bar("HeldBoth", 3.0, FLOOR_TOP + 2.2, -0.5, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.5, FLOOR_TOP + ROOT_HEIGHT, 3.0)),
    ])
    return out


def back_extension_bench(pad_color, accent):
    """Forty-five-degree Roman chair with hip and ankle pads."""
    out = [floor_mat(10, 12)]
    slope = mul(cf(0, FLOOR_TOP + 3.5, 0), rot_x(-45))
    out.extend([
        part("Base", [7.0, 0.6, 10.0], cf(0, FLOOR_TOP + 0.3, 0), STEEL, "DiamondPlate"),
        part("HipPad", [5.0, 1.0, 3.0], slope, pad_color, "Fabric"),
        part("Frame", [1.0, 5.5, 1.0], cf(0, FLOOR_TOP + 2.75, 0), STEEL, "Metal"),
        cylinder("AnkleRoller", 5.0, 1.1, cf(0, FLOOR_TOP + 1.5, 4.0), RUBBER, "Pebble"),
        part("AngleMarker", [5.5, 0.35, 0.8], cf(0, FLOOR_TOP + 5.4, -1.5), accent, "Neon"),
        marker("TrainAnchor", [2, 2, 1], mul(slope, mul(cf(0, 1.1, 0), rot_x(90)))),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def rope_climb(pad_color, accent):
    """Tall rope gantry; the avatar climbs in place under a crash mat."""
    out = [floor_mat(10, 10)]
    out.extend([
        part("Base", [9.0, 0.8, 8.0], cf(0, FLOOR_TOP + 0.4, 0), pad_color, "Rubber"),
        part("LeftPost", [1.0, 14.0, 1.0], cf(-3.8, FLOOR_TOP + 7.0, 0), STEEL, "Metal"),
        part("RightPost", [1.0, 14.0, 1.0], cf(3.8, FLOOR_TOP + 7.0, 0), STEEL, "Metal"),
        part("TopBeam", [8.5, 1.0, 1.0], cf(0, FLOOR_TOP + 13.6, 0), accent, "Metal"),
        cylinder("ClimbRope", 12.0, 0.55, mul(cf(0, FLOOR_TOP + 7.0, 0), rot_z(90)),
                 RUBBER, "Fabric", CanCollide=False),
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 7.0, 0)),
        marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.5)),
    ])
    return out


def plank_deck(pad_color, accent):
    """Long rubber deck with elbow targets and a weighted timer arch."""
    out = [floor_mat(10, 13)]
    out.extend([
        part("Base", [8.0, 0.65, 11.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Mat", [6.8, 0.25, 9.8], cf(0, FLOOR_TOP + 0.8, 0), pad_color, "Rubber"),
        part("ElbowTargets", [5.0, 0.15, 1.5], cf(0, FLOOR_TOP + 1.0, -3.0), accent, "Neon"),
        part("TimerArch", [8.0, 4.5, 0.6], cf(0, FLOOR_TOP + 2.3, -5.0), STEEL, "Metal"),
        marker("TrainAnchor", [2, 2, 1],
               axes((0, FLOOR_TOP + 2.15, 0.5), (-1, 0, 0), (0, 0, -1))),
        marker("TrainExit", [2, 2, 1], cf(4.5, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def cable_crunch(pad_color, accent):
    """High pulley with a kneeling pad and rope attachment."""
    out = [floor_mat(10, 11)]
    out.extend([
        part("Base", [5.0, 0.7, 5.0], cf(0, FLOOR_TOP + 0.35, -3.0), STEEL, "DiamondPlate"),
        part("Tower", [4.0, 10.0, 2.8], cf(0, FLOOR_TOP + 5.0, -3.6), STEEL_LIGHT, "Metal"),
        part("Pulley", [1.0, 1.0, 4.0], cf(0, FLOOR_TOP + 9.5, -1.7), accent, "Metal"),
        part("KneePad", [5.0, 0.5, 4.0], cf(0, FLOOR_TOP + 0.6, 2.4), pad_color, "Fabric"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 2.2, 2.2)),
            _held_bar("HeldBoth", 2.5, FLOOR_TOP + 6.4, 0.2, RUBBER, 0.55),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def ab_wheel_runway(pad_color, accent):
    """Kneeling rollout lane with a carried ab wheel."""
    out = [floor_mat(9, 14)]
    wheel = [
        cylinder("Wheel", 0.8, 2.2, mul(cf(0, FLOOR_TOP + 1.5, -1.8), rot_y(90)),
                 RUBBER, "Rubber", CanCollide=False, CanTouch=False, CanQuery=False),
        cylinder("Handle", 4.2, 0.35, cf(0, FLOOR_TOP + 1.5, -1.8), CHROME, "Metal",
                 CanCollide=False, CanTouch=False, CanQuery=False),
    ]
    out.extend([
        part("Base", [7.0, 0.65, 12.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Runway", [5.5, 0.25, 10.8], cf(0, FLOOR_TOP + 0.8, 0), pad_color, "Rubber"),
        part("Finish", [5.7, 0.2, 0.7], cf(0, FLOOR_TOP + 1.0, -4.5), accent, "Neon"),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 2.2, 2.0)),
            group("HeldBoth", wheel),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def wood_chop_station(pad_color, accent):
    """Single cable tower with high-to-low diagonal handle path."""
    out = [floor_mat(11, 11)]
    out.extend([
        part("Base", [5.0, 0.7, 5.0], cf(-3.0, FLOOR_TOP + 0.35, -2.5), STEEL, "DiamondPlate"),
        part("Tower", [3.0, 10.0, 3.0], cf(-3.0, FLOOR_TOP + 5.0, -3.0), STEEL_LIGHT, "Metal"),
        part("DiagonalGuide", [0.5, 9.0, 0.5],
             mul(cf(-1.0, FLOOR_TOP + 5.4, -1.0), rot_z(-25)), accent, "Neon"),
        group("Spot", [
            anchor_standing(cf(1.5, FLOOR_TOP, 1.8)),
            _held_bar("HeldBoth", 2.2, FLOOR_TOP + 7.2, -0.8, CHROME),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.8, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out


def leg_extension(pad_color, accent):
    """Seated quad extension with a front ankle roller."""
    out = [floor_mat(10, 11)]
    out.extend([
        part("Base", [7.5, 0.65, 8.5], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Seat", [4.5, 0.7, 4.0], cf(0, FLOOR_TOP + 2.4, 1.8), pad_color, "Fabric"),
        part("BackPad", [4.5, 5.5, 0.7], cf(0, FLOOR_TOP + 5.1, 3.4), pad_color, "Fabric"),
        cylinder("AnkleRoller", 5.5, 1.2, cf(0, FLOOR_TOP + 1.6, -2.2), RUBBER, "Pebble"),
        part("Pivot", [1.0, 4.0, 1.0], cf(0, FLOOR_TOP + 2.0, -0.5), accent, "Metal"),
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.5, 1.8)),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.6)),
    ])
    return out


def hamstring_curl(pad_color, accent):
    """Prone leg-curl bench with heel roller and selector stack."""
    out = [floor_mat(10, 13)]
    out.extend([
        part("Base", [4.8, 0.7, 10.0], cf(0, FLOOR_TOP + 1.7, 0), pad_color, "Fabric"),
        part("Frame", [1.0, 1.5, 11.0], cf(0, FLOOR_TOP + 0.8, 0), STEEL, "DiamondPlate"),
        part("WeightStack", [3.5, 6.0, 2.5], cf(0, FLOOR_TOP + 3.0, -5.0), STEEL_LIGHT, "Metal"),
        cylinder("HeelRoller", 6.0, 1.25, cf(0, FLOOR_TOP + 2.8, 4.2), RUBBER, "Pebble"),
        part("StackStripe", [3.7, 0.4, 2.7], cf(0, FLOOR_TOP + 5.5, -5.0), accent, "Neon"),
        marker("TrainAnchor", [2, 2, 1],
               axes((0, FLOOR_TOP + 2.9, 0), (-1, 0, 0), (0, 0, -1))),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out


def calf_raise(pad_color, accent):
    """Standing calf block with shoulder pads and safety rails."""
    out = [floor_mat(10, 10)]
    out.extend([
        part("Base", [8.0, 0.7, 7.5], cf(0, FLOOR_TOP + 0.35, 0), STEEL, "DiamondPlate"),
        part("ToeBlock", [6.0, 0.8, 2.5], cf(0, FLOOR_TOP + 1.1, 1.5), pad_color, "Rubber"),
        part("Frame", [7.5, 9.0, 0.8], cf(0, FLOOR_TOP + 4.5, -3.0), STEEL, "Metal"),
        part("ShoulderPads", [5.5, 0.8, 2.0], cf(0, FLOOR_TOP + 6.2, -0.2), pad_color, "Fabric"),
        part("TopStripe", [7.7, 0.4, 1.0], cf(0, FLOOR_TOP + 8.7, -3.0), accent, "Neon"),
        anchor_standing(cf(0, FLOOR_TOP + 0.8, 0.3)),
        marker("TrainExit", [2, 2, 1], cf(4.3, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out


def stair_climber(pad_color, accent):
    """Compact rotating stair machine with hand rails and console."""
    out = [floor_mat(10, 12)]
    out.extend([
        part("Base", [7.0, 0.7, 10.0], cf(0, FLOOR_TOP + 0.35, 0), STEEL, "DiamondPlate"),
        part("StepLow", [5.5, 0.8, 2.2], cf(0, FLOOR_TOP + 1.2, 3.0), pad_color, "Rubber"),
        part("StepMid", [5.5, 1.5, 2.2], cf(0, FLOOR_TOP + 1.8, 0.8), pad_color, "Rubber"),
        part("StepHigh", [5.5, 2.2, 2.2], cf(0, FLOOR_TOP + 2.5, -1.4), pad_color, "Rubber"),
        part("Console", [5.0, 4.0, 1.0], cf(0, FLOOR_TOP + 6.0, -4.0), STEEL_LIGHT, "Metal"),
        part("Readout", [4.2, 1.8, 0.2], cf(0, FLOOR_TOP + 6.6, -3.4), accent, "Neon"),
        cylinder("Handlebar", 6.0, 0.45, cf(0, FLOOR_TOP + 5.0, -2.8), CHROME),
        anchor_standing(cf(0, FLOOR_TOP + 2.1, 0.0)),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 3.0)),
    ])
    return out


BUILDERS = {
    "BenchPress": bench_press,
    "InclinePress": incline_press,
    "PecDeck": pec_deck,
    "PushUps": push_up_deck,
    "CableCrossover": cable_crossover,
    "ChestDip": chest_dip,
    "DeclinePress": decline_press,
    "Dumbbells": dumbbell_rack,
    "BarbellCurl": barbell_curl,
    "TricepsPushdown": triceps_pushdown,
    "HammerCurl": hammer_curl,
    "PreacherCurl": preacher_curl,
    "SkullCrusher": skull_crusher,
    "BattleRopes": battle_ropes,
    "PullUpBar": pull_up_rig,
    "SeatedRow": seated_row,
    "LatPulldown": lat_pulldown,
    "Deadlift": deadlift_platform,
    "TBarRow": t_bar_row,
    "BackExtension": back_extension_bench,
    "RopeClimb": rope_climb,
    "SitUpBench": sit_up_bench,
    "KneeRaise": knee_raise,
    "TorsoTwist": torso_twist,
    "Plank": plank_deck,
    "CableCrunch": cable_crunch,
    "AbWheel": ab_wheel_runway,
    "WoodChop": wood_chop_station,
    "Treadmill": treadmill,
    "SquatRack": squat_rack,
    "LegPress": leg_press,
    "LegExtension": leg_extension,
    "HamstringCurl": hamstring_curl,
    "CalfRaise": calf_raise,
    "StairClimber": stair_climber,
}




# --------------------------------------------------------------------------
# The world.
#
# A city island at the origin with themed islands scattered around it. The
# previous pass put eleven identical square decks on a golden-angle spiral,
# which reads as a diagram of the progression ladder rather than as a place.
# Bearings and radii are hand-picked here instead: the point of a map is that
# no two directions look the same.
#
# Downtown, Garage Gym and Iron Hall share the ground island at the origin and
# the Docks is a walk across the causeway. Everything past that floats, higher
# with every tier, so the back half of the map is only reachable by flying and
# the movement ladder and the progression ladder stay the same ladder.
#
# District ids must match ZoneConfig; the ids and the power gates live there,
# the geometry lives here.
# --------------------------------------------------------------------------


def tagged(node, tags=None, attributes=None):
    """Attaches CollectionService tags and instance attributes to a node.

    Tags ride in `properties` and attributes in a sibling key, which is the
    Rojo model-JSON encoding. Every tagged part in the world went through this
    by hand before; getting it wrong silently breaks whichever service reads
    the tag, so it is worth a function.
    """
    if tags:
        node.setdefault("properties", {})["Tags"] = list(tags)
    if attributes:
        node["attributes"] = dict(attributes)
    return node


def folder(name, children):
    return {"name": name, "className": "Folder", "children": children}


# Ground/rock/accent per district, plus the machine pad colour. Keeping the
# palette in the layout row rather than in the shape functions is what lets a
# new district be one entry: the shape says what an island looks like, the row
# says what it is made of.
DISTRICTS = [
    # Garage Gym IS the spawn. Its machines ring the plaza you appear on, so the
    # first thing a new player can see from where they land is the thing the game
    # is about — no walk, no directions, no wondering where the gym is.
    #
    # Its zone volume covers the plaza in the middle of the spread, which would once
    # have made the plaza a safe AFK farm. TokenService refuses to pay inside a
    # safe zone now, so the geometry no longer has to dodge the shelter.
    #
    # The starter venues stay around the safe plaza, but their bearings and distance
    # vary. That keeps every machine attackable without making the first view look
    # like five copies arranged by a level designer's compass.
    {
        "zone": "Garage",
        "bearing": 0, "radius": 0, "altitude": 0, "facing": 0,
        "shape": "plaza", "half": 104, "layout": "scatter",
        "scatter_min": 82, "scatter_max": 99,
        "pad_at": 40, "pad_size": 18,
        "ground": [0.19, 0.19, 0.21], "ground_material": "Asphalt",
        "rock": [0.13, 0.13, 0.15], "rock_material": "Rock",
        "accent": ACCENT_STARTER, "pad": PAD_RED,
    },
    # Iron Hall is still a city block. `facing` overrides the usual "point back at
    # the origin", because a gym at 45 degrees to its street looks like a mistake.
    {
        "zone": "Iron",
        "bearing": 315, "radius": 359, "altitude": 0, "facing": 180,
        "shape": "lot", "half": 66, "layout": "scatter",
        "scatter_min": 40, "scatter_max": 45,
        "ground": [0.17, 0.18, 0.21], "ground_material": "Concrete",
        "rock": [0.12, 0.13, 0.16], "rock_material": "Rock",
        "accent": ACCENT_IRON, "pad": PAD_BLUE,
    },
    {
        "zone": "Powerhouse",
        "bearing": 90, "radius": 570, "altitude": 0,
        "shape": "slab", "half": 128, "layout": "scatter",
        "props": "docks",
        "ground": [0.30, 0.30, 0.31], "ground_material": "Concrete",
        "rock": [0.16, 0.16, 0.17], "rock_material": "Rock",
        "accent": [0.94, 0.42, 0.24], "pad": [0.42, 0.16, 0.10],
    },
    {
        "zone": "Strongman",
        "bearing": 200, "radius": 680, "altitude": 130,
        "shape": "round", "half": 138, "layout": "scatter",
        "props": "beach",
        "ground": [0.82, 0.72, 0.51], "ground_material": "Sand",
        "rock": [0.45, 0.39, 0.30], "rock_material": "Sandstone",
        "accent": [0.75, 0.47, 0.27], "pad": [0.34, 0.22, 0.13],
    },
    {
        "zone": "Titan",
        "bearing": 300, "radius": 800, "altitude": 270,
        "shape": "mesa", "half": 142, "layout": "scatter",
        "props": "quarry",
        "ground": [0.62, 0.50, 0.34], "ground_material": "Sandstone",
        "rock": [0.38, 0.31, 0.22], "rock_material": "Rock",
        "accent": [1.0, 0.77, 0.24], "pad": [0.40, 0.28, 0.08],
    },
    {
        "zone": "Skydeck",
        "bearing": 20, "radius": 920, "altitude": 430,
        "shape": "slab", "half": 126, "layout": "scatter",
        "props": "rooftop",
        "ground": [0.24, 0.26, 0.30], "ground_material": "Concrete",
        "rock": [0.15, 0.17, 0.20], "rock_material": "Slate",
        "accent": [0.47, 0.82, 1.0], "pad": [0.13, 0.30, 0.42],
    },
    {
        "zone": "Storm",
        "bearing": 140, "radius": 1040, "altitude": 610,
        "shape": "crag", "half": 136, "layout": "scatter",
        "props": "peak",
        "ground": [0.36, 0.38, 0.44], "ground_material": "Slate",
        "rock": [0.22, 0.24, 0.30], "rock_material": "Rock",
        "accent": [0.59, 0.63, 1.0], "pad": [0.18, 0.20, 0.40],
    },
    {
        "zone": "Void",
        "bearing": 255, "radius": 1150, "altitude": 810,
        "shape": "slab", "half": 130, "layout": "scatter",
        "props": "void",
        "ground": [0.07, 0.06, 0.10], "ground_material": "Basalt",
        "rock": [0.04, 0.03, 0.06], "rock_material": "Basalt",
        "accent": [0.63, 0.43, 0.92], "pad": [0.20, 0.12, 0.34],
    },
    {
        "zone": "Solar",
        "bearing": 345, "radius": 1260, "altitude": 1030,
        "shape": "crag", "half": 140, "layout": "scatter",
        "props": "solar",
        "ground": [0.24, 0.13, 0.10], "ground_material": "Basalt",
        "rock": [0.14, 0.07, 0.06], "rock_material": "CrackedLava",
        "accent": [1.0, 0.55, 0.24], "pad": [0.42, 0.20, 0.08],
    },
    {
        "zone": "Nebula",
        "bearing": 175, "radius": 1370, "altitude": 1270,
        "shape": "slab", "half": 144, "layout": "scatter",
        "props": "nebula",
        "ground": [0.16, 0.11, 0.20], "ground_material": "Metal",
        "rock": [0.10, 0.07, 0.14], "rock_material": "Slate",
        "accent": [1.0, 0.43, 0.75], "pad": [0.40, 0.14, 0.30],
    },
    {
        "zone": "Ascendant",
        "bearing": 285, "radius": 1480, "altitude": 1530,
        "shape": "round", "half": 152, "layout": "scatter",
        "props": "celestial",
        "ground": [0.86, 0.84, 0.78], "ground_material": "Marble",
        "rock": [0.55, 0.53, 0.48], "rock_material": "Limestone",
        "accent": [1.0, 0.96, 0.78], "pad": [0.38, 0.36, 0.28],
    },
]

# The city island everything starts on. Big enough to hold a street grid, the
# first two gyms and a plaza with room to stand around in.
DOWNTOWN_HALF = 330
# The connected-city starter campus fills its central block. All five x1 training
# venues sit on this pavement, while a smaller square barrier protects the actual
# spawn point in the middle. Keeping the machines outside that barrier preserves
# the game's core risk: somebody can still knock a trainee off a starter machine.
PLAZA_RADIUS = 90
SAFE_ZONE_HALF = 34
# Bearing of the causeway out to the Docks. Due east so it runs straight off
# the end of the east avenue — a bridge you have to go looking for is not a
# bridge anyone walks.
CAUSEWAY_BEARING = 90


def district_origin(row):
    """Where a district sits, as a CFrame.

    Districts face back toward Downtown by default, so a player arriving on the
    spawn pad is looking into the gym. A `facing` key overrides that for the two
    that stand on Downtown's own street grid.
    """
    angle = math.radians(row["bearing"])
    x = math.sin(angle) * row["radius"]
    z = math.cos(angle) * row["radius"]
    facing = row.get("facing", row["bearing"] + 180)
    return mul(cf(x, row["altitude"], z), rot_y(facing))


def disc(name, thickness, diameter, y, color, material, **props):
    """A flat horizontal disc. Roblox cylinders run along local X, so a disc is
    a cylinder stood on its end."""
    return cylinder(name, thickness, diameter,
                    mul(cf(0, y, 0), rot_z(90)), color, material, **props)


def underside(row, rng, round_shape):
    """Tapering rock beneath a deck.

    Islands float. Seen from below — which is most of the time once flight
    unlocks — a bare slab reads as a placeholder, so each island gets a stack
    of shrinking, jittered rock beneath it. Non-colliding and shadowless: it is
    scenery, and a flier who clips it should pass through rather than snag.
    """
    out = []
    half = row["half"]
    y = FLOOR_TOP - 4
    width = half * 2

    for index in range(6):
        width *= 0.79
        depth = 7 + index * 4
        y -= depth * 0.5
        shade = [c * (1.0 - index * 0.1) for c in row["rock"]]
        if round_shape:
            out.append(disc("Rock", depth, width, y, shade, row["rock_material"],
                            CanCollide=False, CastShadow=False))
        else:
            out.append(part("Rock", [width, depth, width],
                            mul(cf(0, y, 0), rot_y(rng.uniform(-16, 16))),
                            shade, row["rock_material"],
                            CanCollide=False, CastShadow=False))
        y -= depth * 0.5

    # A spike at the bottom so the taper ends in a point rather than a stub.
    out.append(part("RockTip", [width * 0.55, 34, width * 0.55],
                    mul(cf(0, y - 14, 0), rot_y(rng.uniform(-20, 20))),
                    [c * 0.4 for c in row["rock"]], row["rock_material"],
                    CanCollide=False, CastShadow=False))
    return out


def spawn_pad(row):
    """The pad travel drops arrivals onto, on the Downtown-facing edge.

    A flat box, not a disc. TravelService lands a player at the pad's CFrame
    raised by half its height, so the pad's orientation becomes the player's:
    a disc is a cylinder turned on its end, and arriving on one would lay you
    on your side. Unrotated in local space, its LookVector points at the middle
    of the island, so you arrive facing the gym rather than the drop.
    """
    size = row.get("pad_size", 30)
    at = row.get("pad_at", row["half"] * 0.74)
    pad = part("SpawnPad", [size, 1, size], cf(0, FLOOR_TOP + 0.5, at),
               row["accent"], "Neon")
    return tagged(pad, tags=["ZoneSpawn"], attributes={"ZoneId": row["zone"]})


def beacon(row, x, z, height):
    """A lit pylon. Islands are far apart and mostly seen against sky, so each
    one needs something that carries its colour at distance."""
    out = []
    out.append(part("Pylon", [4.5, height, 4.5],
                    cf(x, FLOOR_TOP + height / 2, z), STEEL, "DiamondPlate"))
    light = part("Beacon", [6, 3, 6], cf(x, FLOOR_TOP + height + 1.5, z),
                 row["accent"], "Neon", CanCollide=False)
    light["children"] = [{
        "name": "Glow",
        "className": "PointLight",
        "properties": {"Brightness": 3, "Range": 70, "Color": row["accent"]},
    }]
    out.append(light)
    return out


# --------------------------------------------------------------------------
# Island silhouettes. Each returns local-space children; the caller places
# them. A new silhouette is a function plus a SHAPES entry.
# --------------------------------------------------------------------------


def island_slab(row, rng):
    """A rectangular deck with a kerb — quays, rooftops, stations."""
    half = row["half"]
    size = half * 2
    out = [part("Deck", [size, 4, size], cf(0, FLOOR_TOP - 2, 0),
                row["ground"], row["ground_material"])]
    out.append(part("DeckTrim", [size + 5, 1.4, size + 5], cf(0, FLOOR_TOP - 4.5, 0),
                    [c * 0.5 for c in row["accent"]], "Metal"))

    # A kerb runs ALONG the edge it sits on, so the long axis is the one the
    # offset is *not* on. #67's platform() had these two swapped, which put a
    # full-width bar at x = half and left it sticking a whole island's width out
    # into the void — invisible from inside, obvious from the air.
    for sx, sz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        out.append(part("Kerb",
                        [4 if sx != 0 else size + 4, 2.6, 4 if sz != 0 else size + 4],
                        cf(sx * (half + 2), FLOOR_TOP + 1.3, sz * (half + 2)),
                        [c * 0.6 for c in row["accent"]], "Metal"))

    for sx in (-1, 1):
        for sz in (-1, 1):
            out.extend(beacon(row, sx * (half - 6), sz * (half - 6), 26))

    out.extend(underside(row, rng, False))
    return out


def island_round(row, rng):
    """A disc island with a stone rim — beaches and peaks."""
    half = row["half"]
    out = [disc("Deck", 4, half * 2, FLOOR_TOP - 2, row["ground"], row["ground_material"])]
    out.append(disc("DeckTrim", 1.6, half * 2 + 8, FLOOR_TOP - 4.6,
                    [c * 0.5 for c in row["accent"]], "Metal"))

    # A ring of boulders instead of a kerb: on a natural island a machined edge
    # is the thing that gives it away.
    for index in range(14):
        angle = 360.0 * index / 14 + rng.uniform(-6, 6)
        size = rng.uniform(7, 13)
        out.append(part("Boulder", [size, size * 0.8, size],
                        mul(mul(rot_y(angle), cf(0, FLOOR_TOP + size * 0.2, half - 3)),
                            rot_y(rng.uniform(0, 90))),
                        [c * rng.uniform(0.8, 1.1) for c in row["rock"]],
                        row["rock_material"]))

    for angle in (35, 145, 215, 325):
        spot = mul(rot_y(angle), cf(0, 0, half - 20))
        out.extend(beacon(row, spot[0][0], spot[0][2], 24))

    out.extend(underside(row, rng, True))
    return out


def island_mesa(row, rng):
    """A flat top on stepped stone shoulders — quarries and plateaus."""
    half = row["half"]
    size = half * 2
    out = [part("Deck", [size, 4, size], cf(0, FLOOR_TOP - 2, 0),
                row["ground"], row["ground_material"])]

    # Shoulders step outward and down, so the top plate overhangs slightly.
    for index in range(3):
        width = size + 10 + index * 16
        out.append(part("Shoulder", [width, 9, width],
                        mul(cf(0, FLOOR_TOP - 6 - index * 9, 0),
                            rot_y(rng.uniform(-8, 8))),
                        [c * (0.95 - index * 0.12) for c in row["rock"]],
                        row["rock_material"]))

    # Cut walls at the back edge, the quarry face.
    for index in range(4):
        out.append(part("Face", [rng.uniform(24, 44), rng.uniform(14, 30), 12],
                        cf(rng.uniform(-half * 0.7, half * 0.7), FLOOR_TOP + 8,
                           -half + rng.uniform(2, 10)),
                        [c * rng.uniform(0.85, 1.05) for c in row["rock"]],
                        row["rock_material"]))

    for sx in (-1, 1):
        out.extend(beacon(row, sx * (half - 8), half - 8, 22))

    out.extend(underside(row, rng, False))
    return out


def island_crag(row, rng):
    """A deck ringed by jagged spurs — storm peaks and volcanic rock."""
    half = row["half"]
    out = [disc("Deck", 4, half * 2, FLOOR_TOP - 2, row["ground"], row["ground_material"])]

    for index in range(9):
        angle = 360.0 * index / 9 + rng.uniform(-10, 10)
        height = rng.uniform(26, 62)
        width = rng.uniform(14, 26)
        spur = mul(rot_y(angle), cf(0, FLOOR_TOP + height / 2 - 4, half - rng.uniform(4, 16)))
        out.append(part("Spur", [width, height, width],
                        mul(mul(spur, rot_y(rng.uniform(0, 90))),
                            rot_x(rng.uniform(-9, 9))),
                        [c * rng.uniform(0.8, 1.15) for c in row["rock"]],
                        row["rock_material"]))

    for angle in (0, 180):
        spot = mul(rot_y(angle), cf(0, 0, half - 26))
        out.extend(beacon(row, spot[0][0], spot[0][2], 28))

    out.extend(underside(row, rng, True))
    return out


def island_lot(row, _rng):
    """No island at all — a district that stands on Downtown's ground.

    Garage Gym and Iron Hall are city blocks, not islands, so they get a floor
    slab and a kerb and nothing underneath. #69 puts buildings on top of them.
    """
    half = row["half"]
    size = half * 2
    out = [part("Lot", [size, 1.2, size], cf(0, FLOOR_TOP - 0.6, 0),
                row["ground"], row["ground_material"])]
    out.append(part("LotTrim", [size + 4, 0.5, size + 4], cf(0, FLOOR_TOP - 1.4, 0),
                    [c * 0.5 for c in row["accent"]], "Metal"))

    for sx in (-1, 1):
        out.extend(beacon(row, sx * (half - 6), half - 6, 18))

    return out


def island_plaza(row, _rng):
    """No ground of its own — Downtown already paved this.

    Garage Gym rings the spawn plaza, so all it needs is an apron marking where
    the gym is and posts to give the ring an edge. Anything more would be a
    second floor laid on top of the first.
    """
    spots = machine_spots(row)
    radius = max(math.hypot(spot[0][0], spot[0][2]) for spot in spots)
    # Poured concrete, lighter than the asphalt around it. The machines are steel
    # and rubber; on a dark pad they disappear into it from any distance.
    out = [disc("Apron", 0.3, (radius + 24) * 2, FLOOR_TOP + 0.15,
                [0.46, 0.46, 0.47], "Concrete", CanCollide=False)]
    out.append(disc("ApronEdge", 0.35, (radius + 26) * 2, FLOOR_TOP + 0.1,
                    [c * 0.5 for c in row["accent"]], "Neon", CanCollide=False))

    # A painted bay under each machine — the cheapest thing that turns a slab into
    # a floor somebody planned. The bay reads the actual generated spot so the
    # deliberately uneven layout cannot drift away from its floor markings.
    for spot in spots:
        out.append(part("Bay", [26, 0.2, 26],
                        ((spot[0][0], FLOOR_TOP + 0.3, spot[0][2]), spot[1]),
                        [0.30, 0.30, 0.32], "Concrete", CanCollide=False))
        out.append(part("BayLine", [26, 0.25, 1.2],
                        ((spot[0][0], FLOOR_TOP + 0.35, spot[0][2]), spot[1]),
                        [c * 0.7 for c in row["accent"]], "Neon", CanCollide=False))

    # Posts between the machines rather than behind them, so they read as the
    # gym's corners instead of as clutter.
    # Five uneven edge posts preserve the open-gym silhouette without visually
    # snapping the venues back onto a perfect ring.
    rng = random.Random(f"{row['zone']}:posts")
    for index in range(MACHINE_COUNT):
        angle = 360.0 * index / MACHINE_COUNT + rng.uniform(-22, 22)
        spot = mul(rot_y(angle), cf(0, 0, radius + rng.uniform(13, 18)))
        out.append(part("GymPost", [3, 15, 3],
                        cf(spot[0][0], FLOOR_TOP + 7.5, spot[0][2]),
                        [0.17, 0.17, 0.19], "Metal"))
        out.append(part("GymPostLamp", [4.4, 1.6, 4.4],
                        cf(spot[0][0], FLOOR_TOP + 15.8, spot[0][2]),
                        row["accent"], "Neon", CanCollide=False))
    return out


SHAPES = {
    "plaza": island_plaza,
    "slab": island_slab,
    "round": island_round,
    "mesa": island_mesa,
    "crag": island_crag,
    "lot": island_lot,
}


# --------------------------------------------------------------------------
# Props. What makes a district a docks rather than a grey rectangle.
#
# Every set is one function returning local-space children, registered in
# PROPS and named by a district row. Adding a theme is a function and a key;
# no district code changes, and no other theme is touched.
#
# All of them keep clear of the machines: `ring` districts leave the middle
# free and props go to the rim, `rows` districts fill the middle so props stay
# outside RIM. The generator checks this rather than trusting it.
# --------------------------------------------------------------------------

# Fraction of an island's half-size that props must stay beyond, on a district
# whose machines are laid out in rows across the middle.
RIM = 0.76


# Every district's spawn pad sits on local +Z. Props ringing the rim skip this
# arc around it, which stops travel dropping arrivals inside a shipping
# container and leaves them a clear walk onto the island.
SPAWN_ARC = 28


def rim_spots(count, radius, rng, jitter=0.0):
    """Evenly spaced points on a circle, each yawed to face the middle.

    The half-step offset means an even count never puts a prop exactly on the
    spawn pad's bearing, and anything that still lands in the arc is dropped —
    so a set occasionally returns one fewer point than asked for.
    """
    out = []
    for index in range(count):
        angle = 360.0 * index / count + 180.0 / count + rng.uniform(-jitter, jitter)
        if abs((angle + 180) % 360 - 180) < SPAWN_ARC:
            continue
        spot = mul(rot_y(angle), cf(0, 0, radius))
        out.append((spot[0][0], spot[0][2], angle + 180))
    return out


def props_docks(row, rng):
    """Stacked containers, a gantry crane and bollards. An industrial quay."""
    half = row["half"]
    out = []
    colours = [[0.62, 0.24, 0.18], [0.20, 0.36, 0.50], [0.55, 0.48, 0.16],
               [0.24, 0.42, 0.28], [0.45, 0.45, 0.47]]

    # Right out at the quay edge: a container is 26 studs deep radially, and a
    # `rows` layout puts machines within 0.6 of the half-size.
    for x, z, yaw in rim_spots(9, half * 0.9, rng, 6):
        stack = rng.randint(1, 3)
        for level in range(stack):
            frame = mul(mul(cf(x, FLOOR_TOP + 6.5 + level * 12.4, z), rot_y(yaw)),
                        rot_y(rng.uniform(-4, 4)))
            out.append(part("Container", [12, 12, 26], frame,
                            rng.choice(colours), "CorrodedMetal"))
            out.append(part("ContainerRib", [12.4, 12.4, 1.0],
                            mul(frame, cf(0, 0, 8)), [0.14, 0.14, 0.15], "Metal",
                            CanCollide=False))

    # A gantry straddling one edge: legs, beam, trolley.
    gx, gz = 0, -half * RIM
    for side in (-1, 1):
        out.append(part("CraneLeg", [4, 62, 4], cf(gx + side * 26, FLOOR_TOP + 31, gz),
                        [0.55, 0.36, 0.14], "CorrodedMetal"))
    out.append(part("CraneBeam", [64, 5, 5], cf(gx, FLOOR_TOP + 64, gz),
                    [0.55, 0.36, 0.14], "CorrodedMetal"))
    out.append(part("CraneTrolley", [9, 6, 8], cf(gx + 14, FLOOR_TOP + 58, gz),
                    [0.20, 0.21, 0.24], "Metal"))
    out.append(part("CraneCable", [0.6, 22, 0.6], cf(gx + 14, FLOOR_TOP + 44, gz),
                    [0.10, 0.10, 0.11], "Metal", CanCollide=False))
    out.append(part("CraneHook", [4, 3, 4], cf(gx + 14, FLOOR_TOP + 32, gz),
                    [0.30, 0.30, 0.32], "Metal", CanCollide=False))

    for x, z, _ in rim_spots(16, half * 0.94, rng):
        out.append(cylinder("Bollard", 3.4, 3.0,
                            mul(cf(x, FLOOR_TOP + 1.7, z), rot_z(90)),
                            [0.16, 0.17, 0.19], "Metal"))
    return out


def props_beach(row, rng):
    """Boardwalk, lifeguard tower, palms and a volleyball net. Muscle Beach."""
    half = row["half"]
    out = []

    for x, z, yaw in rim_spots(11, half * 0.88, rng, 8):
        out.extend(palm(x, z, rng))

    # The tower, on the far side from the spawn pad.
    tx, tz = -half * 0.62, -half * 0.52
    for sx in (-1, 1):
        for sz in (-1, 1):
            out.append(part("TowerLeg", [1.4, 18, 1.4],
                            cf(tx + sx * 4, FLOOR_TOP + 9, tz + sz * 4),
                            [0.52, 0.38, 0.24], "Wood"))
    out.append(part("TowerDeck", [12, 1.2, 12], cf(tx, FLOOR_TOP + 18.6, tz),
                    [0.60, 0.45, 0.28], "WoodPlanks"))
    out.append(part("TowerHut", [10, 7, 8], cf(tx, FLOOR_TOP + 22.7, tz - 1),
                    [0.86, 0.82, 0.72], "WoodPlanks"))
    out.append(part("TowerRoof", [13, 0.8, 11], cf(tx, FLOOR_TOP + 26.5, tz - 1),
                    row["accent"], "Fabric", CanCollide=False))

    # Volleyball net across one side, and loungers along the rim.
    nx, nz = -half * 0.5, half * 0.62
    for side in (-1, 1):
        out.append(part("NetPost", [0.8, 14, 0.8],
                        cf(nx + side * 13, FLOOR_TOP + 7, nz), [0.50, 0.36, 0.22], "Wood"))
    out.append(part("Net", [26, 5, 0.2], cf(nx, FLOOR_TOP + 11, nz),
                    [0.90, 0.88, 0.80], "Fabric", CanCollide=False, Transparency=0.35))

    for x, z, yaw in rim_spots(6, half * 0.72, rng, 10):
        frame = mul(cf(x, 0, z), rot_y(yaw))
        out.append(part("Lounger", [4, 0.4, 9],
                        mul(frame, mul(cf(0, FLOOR_TOP + 1.6, 0), rot_x(-14))),
                        [0.88, 0.86, 0.78], "Fabric"))
        for side in (-1, 1):
            out.append(part("LoungerLeg", [0.4, 1.4, 0.4],
                            mul(frame, cf(side * 1.6, FLOOR_TOP + 0.7, 0)),
                            [0.30, 0.30, 0.32], "Metal"))
    return out


def props_quarry(row, rng):
    """Cut faces, a conveyor, rusted rigs and floodlights. A working pit."""
    half = row["half"]
    out = []

    for x, z, yaw in rim_spots(12, half * RIM * 1.1, rng, 9):
        size = rng.uniform(10, 22)
        out.append(part("Boulder", [size, size * 0.8, size],
                        mul(mul(cf(x, FLOOR_TOP + size * 0.3, z), rot_y(yaw)),
                            rot_z(rng.uniform(-10, 10))),
                        [c * rng.uniform(0.85, 1.15) for c in row["rock"]],
                        row["rock_material"]))

    # Conveyor climbing out of the pit.
    cx, cz = half * 0.62, -half * 0.66
    belt = mul(mul(cf(cx, FLOOR_TOP + 14, cz), rot_y(34)), rot_x(-22))
    out.append(part("Conveyor", [7, 1.2, 54], belt, [0.24, 0.20, 0.16], "CorrodedMetal"))
    out.append(part("ConveyorRail", [8, 3, 54], mul(belt, cf(0, 1.6, 0)),
                    [0.42, 0.28, 0.14], "CorrodedMetal", CanCollide=False,
                    Transparency=0.5))
    for offset in (-20, 0, 20):
        out.append(part("ConveyorLeg", [1.6, 22, 1.6],
                        mul(mul(cf(cx, FLOOR_TOP, cz), rot_y(34)),
                            cf(0, 11, offset)), [0.42, 0.28, 0.14], "CorrodedMetal"))

    for x, z, yaw in rim_spots(4, half * 0.9, rng):
        out.append(part("FloodPole", [1.6, 30, 1.6], cf(x, FLOOR_TOP + 15, z),
                        [0.30, 0.24, 0.16], "CorrodedMetal"))
        head = part("Flood", [5, 3.4, 2], mul(mul(cf(x, FLOOR_TOP + 30, z), rot_y(yaw)),
                                              rot_x(24)),
                    [1.0, 0.94, 0.72], "Neon", CanCollide=False)
        head["children"] = [{
            "name": "Glow", "className": "SpotLight",
            "properties": {"Brightness": 4, "Range": 60, "Angle": 70},
        }]
        out.append(head)

    # Well inside the machine ring, which sits at 0.54 of the half-size: at 0.5
    # these stacks were standing in the middle of the equipment.
    for x, z, _ in rim_spots(5, half * 0.28, rng, 20):
        for level in range(rng.randint(2, 4)):
            out.append(cylinder("Tyre", 2.2, 7.5,
                                mul(cf(x, FLOOR_TOP + 1.2 + level * 2.3, z), rot_z(90)),
                                [0.07, 0.07, 0.08], "Rubber"))
    return out


def props_rooftop(row, rng):
    """Helipad, plant rooms, aircon and dishes. The top of a tower nobody built."""
    half = row["half"]
    out = [
        disc("Helipad", 0.3, 46, FLOOR_TOP + 1.15, [0.10, 0.11, 0.13], "Asphalt",
             CanCollide=False),
        disc("HelipadRing", 0.35, 38, FLOOR_TOP + 1.3, [0.92, 0.92, 0.88], "Neon",
             CanCollide=False),
        disc("HelipadCentre", 0.4, 30, FLOOR_TOP + 1.35, [0.10, 0.11, 0.13], "Asphalt",
             CanCollide=False),
    ]
    # The helipad sits in the middle, which on a rows district is where the
    # machines are — so it goes to one corner instead.
    for node in out:
        node["properties"]["CFrame"] = serialise_cf(
            cf(-half * 0.62, FLOOR_TOP + 1.15, -half * 0.62))

    for x, z, yaw in rim_spots(7, half * RIM * 1.12, rng, 10):
        w, d, h = rng.uniform(10, 18), rng.uniform(8, 14), rng.uniform(6, 13)
        frame = mul(cf(x, FLOOR_TOP + h / 2, z), rot_y(yaw))
        out.append(part("PlantRoom", [w, h, d], frame, [0.30, 0.32, 0.36], "Concrete"))
        out.append(part("Vent", [w * 0.6, 1.2, d * 0.6],
                        mul(frame, cf(0, h / 2 + 0.6, 0)), [0.42, 0.44, 0.48], "Metal"))

    for x, z, yaw in rim_spots(5, half * 0.88, rng, 14):
        out.append(part("DishMast", [1.2, 9, 1.2], cf(x, FLOOR_TOP + 4.5, z),
                        [0.28, 0.30, 0.34], "Metal"))
        out.append(part("Dish", [8, 8, 1.2],
                        mul(mul(cf(x, FLOOR_TOP + 10, z), rot_y(yaw)), rot_x(38)),
                        [0.80, 0.80, 0.78], "Metal", CanCollide=False))

    for sx in (-1, 1):
        out.append(cylinder("WaterTank", 14, 16,
                            mul(cf(sx * half * 0.8, FLOOR_TOP + 12, half * 0.34), rot_z(90)),
                            [0.44, 0.40, 0.34], "Metal"))
    return out


def props_peak(row, rng):
    """Snow, cable pylons and weather masts. Somewhere the wind is a problem."""
    half = row["half"]
    out = []

    for x, z, yaw in rim_spots(10, half * 0.86, rng, 12):
        size = rng.uniform(12, 24)
        out.append(part("Snowdrift", [size, size * 0.35, size * 0.8],
                        mul(cf(x, FLOOR_TOP + size * 0.14, z), rot_y(yaw)),
                        [0.90, 0.92, 0.96], "Snow", CanCollide=False))

    # Pylons with a cable strung between them, right across the island.
    pylons = rim_spots(4, half * 0.78, rng)
    for x, z, _ in pylons:
        out.append(part("PylonMast", [3, 46, 3], cf(x, FLOOR_TOP + 23, z),
                        [0.34, 0.36, 0.42], "Metal"))
        for level in (16, 30, 42):
            out.append(part("PylonArm", [18, 1.4, 1.4], cf(x, FLOOR_TOP + level, z),
                            [0.34, 0.36, 0.42], "Metal", CanCollide=False))
    for index in range(len(pylons)):
        ax, az, _ = pylons[index]
        bx, bz, _ = pylons[(index + 1) % len(pylons)]
        length = math.hypot(bx - ax, bz - az)
        yaw = math.degrees(math.atan2(bx - ax, bz - az))
        out.append(part("Cable", [0.5, 0.5, length],
                        mul(cf((ax + bx) / 2, FLOOR_TOP + 41, (az + bz) / 2), rot_y(yaw)),
                        [0.09, 0.09, 0.10], "Metal", CanCollide=False))

    for x, z, yaw in rim_spots(3, half * 0.94, rng, 20):
        out.append(part("MastPole", [0.9, 24, 0.9], cf(x, FLOOR_TOP + 12, z),
                        [0.70, 0.72, 0.78], "Metal"))
        out.append(part("Anemometer", [5, 0.4, 0.4],
                        mul(cf(x, FLOOR_TOP + 24, z), rot_y(yaw)),
                        row["accent"], "Neon", CanCollide=False))
    return out


def props_void(row, rng):
    """Monoliths and light strips. Nothing grows here, so nothing does."""
    half = row["half"]
    out = []

    for x, z, yaw in rim_spots(8, half * RIM * 1.14, rng, 8):
        height = rng.uniform(30, 70)
        out.append(part("Monolith", [8, height, 8],
                        mul(mul(cf(x, FLOOR_TOP + height / 2, z), rot_y(yaw)),
                            rot_z(rng.uniform(-5, 5))),
                        [0.05, 0.04, 0.08], "Slate"))
        out.append(part("MonolithVein", [1.2, height * 0.8, 1.2],
                        cf(x, FLOOR_TOP + height / 2, z + 4.2),
                        row["accent"], "Neon", CanCollide=False))

    for index in range(6):
        angle = 60.0 * index
        length = half * 1.5
        out.append(part("LightStrip", [1.6, 0.2, length],
                        mul(rot_y(angle), cf(0, FLOOR_TOP + 0.15, 0)),
                        row["accent"], "Neon", CanCollide=False, CastShadow=False))

    for x, z, _ in rim_spots(5, half * 0.92, rng, 16):
        out.append(part("Shard", [3, rng.uniform(10, 20), 3],
                        mul(cf(x, FLOOR_TOP + 14, z), rot_z(rng.uniform(-24, 24))),
                        row["accent"], "Neon", CanCollide=False))
    return out


def props_solar(row, rng):
    """Magma channels and obsidian. Lit from below, which nothing else here is."""
    half = row["half"]
    out = []

    for index in range(5):
        angle = 72.0 * index + 20
        channel = mul(rot_y(angle), cf(0, FLOOR_TOP + 0.1, half * 0.45))
        out.append(part("Magma", [7, 0.4, half * 0.9], channel,
                       [1.0, 0.42, 0.10], "Neon", CanCollide=False, CastShadow=False))
        glow = part("Ember", [5, 0.3, 8],
                    mul(channel, cf(0, 0.3, rng.uniform(-20, 20))),
                    [1.0, 0.76, 0.30], "Neon", CanCollide=False)
        glow["children"] = [{
            "name": "Glow", "className": "PointLight",
            "properties": {"Brightness": 2.5, "Range": 40, "Color": [1.0, 0.45, 0.12]},
        }]
        out.append(glow)

    for x, z, yaw in rim_spots(10, half * RIM * 1.1, rng, 10):
        height = rng.uniform(14, 34)
        out.append(part("Obsidian", [rng.uniform(6, 12), height, rng.uniform(6, 12)],
                        mul(mul(cf(x, FLOOR_TOP + height / 2, z), rot_y(yaw)),
                            rot_x(rng.uniform(-12, 12))),
                        [0.06, 0.04, 0.05], "Slate"))

    for x, z, _ in rim_spots(6, half * 0.92, rng):
        out.append(cylinder("Brazier", 5, 6,
                            mul(cf(x, FLOOR_TOP + 2.5, z), rot_z(90)),
                            [0.20, 0.13, 0.10], "Basalt"))
        out.append(part("Flame", [4, 4, 4], cf(x, FLOOR_TOP + 6, z),
                        [1.0, 0.55, 0.16], "Neon", CanCollide=False))
    return out


def props_nebula(row, rng):
    """Trusses, solar panels and antennae. A station, not an island."""
    half = row["half"]
    out = []

    for x, z, yaw in rim_spots(8, half * RIM * 1.12, rng, 6):
        frame = mul(cf(x, 0, z), rot_y(yaw))
        out.append(part("TrussPost", [2.2, 26, 2.2], mul(frame, cf(0, FLOOR_TOP + 13, 0)),
                        [0.42, 0.44, 0.52], "Metal"))
        out.append(part("PanelArm", [1.2, 1.2, 14], mul(frame, cf(0, FLOOR_TOP + 24, 6)),
                        [0.42, 0.44, 0.52], "Metal", CanCollide=False))
        out.append(part("SolarPanel", [22, 0.5, 13],
                        mul(mul(frame, cf(0, FLOOR_TOP + 26, 12)), rot_x(26)),
                        [0.10, 0.12, 0.30], "Glass", Reflectance=0.4, CanCollide=False))
        out.append(part("PanelEdge", [22.6, 0.9, 1.0],
                        mul(mul(frame, cf(0, FLOOR_TOP + 25.4, 17.6)), rot_x(26)),
                        row["accent"], "Neon", CanCollide=False))

    for x, z, yaw in rim_spots(5, half * 0.92, rng, 14):
        out.append(part("Antenna", [0.8, 30, 0.8], cf(x, FLOOR_TOP + 15, z),
                        [0.50, 0.52, 0.58], "Metal"))
        for level in (12, 20, 26):
            out.append(part("AntennaRing", [4, 0.4, 4], cf(x, FLOOR_TOP + level, z),
                            row["accent"], "Neon", CanCollide=False))
    return out


def props_celestial(row, rng):
    """Columns, arches and a reflecting pool. The end of the map should feel
    like an arrival, not another platform."""
    half = row["half"]
    out = [disc("Pool", 0.5, half * 0.5, FLOOR_TOP + 0.9,
                [0.55, 0.80, 0.92], "Glass", CanCollide=False,
                Transparency=0.35, Reflectance=0.5)]

    for x, z, yaw in rim_spots(12, half * RIM * 1.12, rng):
        out.append(cylinder("Column", 42, 8,
                            mul(cf(x, FLOOR_TOP + 21, z), rot_z(90)),
                            [0.90, 0.88, 0.82], "Marble"))
        out.append(part("Capital", [11, 3, 11], cf(x, FLOOR_TOP + 43.5, z),
                        [0.94, 0.92, 0.86], "Marble", CanCollide=False))
        out.append(part("ColumnBase", [11, 2.4, 11], cf(x, FLOOR_TOP + 1.2, z),
                        [0.94, 0.92, 0.86], "Marble"))

    # Inside the machine ring, not on it: a `ring` layout leaves the middle free
    # and the pool only takes the innermost quarter of it.
    for x, z, _ in rim_spots(8, half * 0.36, rng):
        out.append(cylinder("Brazier", 4, 5,
                            mul(cf(x, FLOOR_TOP + 2, z), rot_z(90)),
                            [0.82, 0.76, 0.60], "Marble"))
        flame = part("Flame", [3.4, 3.4, 3.4], cf(x, FLOOR_TOP + 5, z),
                     row["accent"], "Neon", CanCollide=False)
        flame["children"] = [{
            "name": "Glow", "className": "PointLight",
            "properties": {"Brightness": 2, "Range": 34, "Color": row["accent"]},
        }]
        out.append(flame)
    return out


PROPS = {
    "docks": props_docks,
    "beach": props_beach,
    "quarry": props_quarry,
    "rooftop": props_rooftop,
    "peak": props_peak,
    "void": props_void,
    "solar": props_solar,
    "nebula": props_nebula,
    "celestial": props_celestial,
}


def volume(zone_id, name, size, frame):
    """One invisible box token accrual and machine tiering test against.

    Must be a genuine volume the standing HumanoidRootPart ends up inside — see
    the warning in ZoneConfig. Tall enough to cover a district's whole playable
    height.
    """
    return tagged({
        "name": name,
        "className": "Part",
        "properties": {
            "Anchored": True,
            "Locked": True,
            "CanCollide": False,
            "Transparency": 1,
            "CastShadow": False,
            "Size": [round(v, 4) for v in size],
            "CFrame": serialise_cf(frame),
            "Material": "SmoothPlastic",
        },
    }, tags=["GymZone"], attributes={"ZoneId": zone_id})


def zone_volume(row):
    """The volume token accrual and machine tiering both test against.

    One box per district, sized to cover its machines. It may overlap the spawn
    plaza's safe zone — Garage Gym's does, because it is built around it — and
    that is fine now: TokenService refuses to pay inside a safe zone regardless
    of which gym zone also covers it.
    """
    half = row["half"]
    return [volume(row["zone"], f"{row['zone']}Volume",
                   [half * 2 + 8, 120, half * 2 + 8], cf(0, 55, 0))]



# --------------------------------------------------------------------------
# Machine layouts. Where stat-specific training venues stand in a district, as
# CFrames in its local space. Random layouts are seeded by zone id: authored
# variety survives a rebuild instead of becoming a moving target in source control.
# --------------------------------------------------------------------------

FAMILY_ORDER = ["Chest", "Arms", "Back", "Core", "Legs"]
STAT_VARIANTS = {
    "Chest": ("BenchPress", "InclinePress", "PecDeck", "PushUps",
              "CableCrossover", "ChestDip", "DeclinePress"),
    "Arms": ("Dumbbells", "BarbellCurl", "TricepsPushdown", "HammerCurl",
             "PreacherCurl", "SkullCrusher", "BattleRopes"),
    "Back": ("PullUpBar", "SeatedRow", "LatPulldown", "Deadlift",
             "TBarRow", "BackExtension", "RopeClimb"),
    "Core": ("SitUpBench", "KneeRaise", "TorsoTwist", "Plank",
             "CableCrunch", "AbWheel", "WoodChop"),
    "Legs": ("Treadmill", "SquatRack", "LegPress", "LegExtension",
             "HamstringCurl", "CalfRaise", "StairClimber"),
}
MACHINE_ORDER = [STAT_VARIANTS[family][0] for family in FAMILY_ORDER]
EQUIPMENT_FAMILY = {
    equipment_id: family
    for family, variants in STAT_VARIANTS.items()
    for equipment_id in variants
}
MACHINE_COUNT = len(MACHINE_ORDER)


def ring_angle(index, count):
    """Where a ring layout puts its Nth item. Anything decorating a ring — a
    painted bay, a post between two of them — has to ask this rather than
    restate it, or it ends up describing a different ring."""
    return 360.0 * index / count + 180.0 / count


def layout_ring(row, count):
    """Evenly around a circle, every machine facing the middle. Reads as a
    deliberate arrangement on a round island, where a grid reads as a car park."""
    out = []
    radius = row.get("ring_radius", row["half"] * 0.54)
    for index in range(count):
        spot = mul(rot_y(ring_angle(index, count)), cf(0, 0, radius))
        out.append(mul(spot, rot_y(180)))
    return out


def layout_rows(row, count):
    """Two alternating rows facing each other across an aisle — a gym floor."""
    out = []
    span = row["half"] * 0.6
    for index in range(count):
        x = -span + (2 * span) * (index / max(1, count - 1))
        near = index % 2 == 0
        out.append(mul(cf(x, 0, span * (0.55 if near else -0.55)),
                       rot_y(180 if near else 0)))
    return out


def layout_scatter(row, count):
    """A reproducible, irregular spread with one venue in each loose sector.

    Sectoring prevents all five random points landing on one side of an island;
    jittered angle and radius keep it from reading as another machine ring. The
    spawn district uses a tighter outer band so its venues clear the safe plaza.
    """
    rng = random.Random(f"{row['zone']}:training-spots")
    minimum = row.get("scatter_min", row["half"] * 0.22)
    maximum = row.get("scatter_max", row["half"] * 0.58)
    phase = rng.uniform(0, 360)
    out = []

    for index in range(count):
        position = None
        angle = 0.0
        # Venue pads are 30 studs wide. Keep their centres at least 38 studs
        # apart so rotated corners and the longer Legs lane do not merge into a
        # neighbouring stat area. With five angular sectors this converges in a
        # handful of attempts, but a bounded loop keeps bad row data harmless.
        for _attempt in range(64):
            angle = phase + 360.0 * index / count + rng.uniform(-18, 18)
            radius = rng.uniform(minimum, maximum)
            candidate = mul(rot_y(angle), cf(0, 0, radius))
            if all(math.hypot(candidate[0][0] - prior[0][0],
                              candidate[0][2] - prior[0][2]) >= 38
                   for prior in out):
                position = candidate
                break
        if position is None:
            angle = phase + 360.0 * index / count
            position = mul(rot_y(angle), cf(0, 0, maximum))
        # Face the machine toward the district interior, leaving its architecture
        # behind it and the approach side open.
        out.append(mul(position, rot_y(angle + 180)))

    return out


LAYOUTS = {
    "ring": layout_ring,
    "rows": layout_rows,
    "scatter": layout_scatter,
}


def machine_spots(row):
    """The single source of truth for machine and venue positions."""
    return LAYOUTS[row["layout"]](row, len(MACHINE_ORDER))


# Architecture makes the stat legible before the machine label streams in.
# These are gameplay venues, not decorative copies of the machine itself: an
# Arms cage, Chest bay, Back tower, Core court and Legs lane have different
# silhouettes and use the stat colour as a restrained wayfinding stripe.
FAMILY_COLORS = {
    "Chest": [1.00, 0.65, 0.15],
    "Arms": [0.94, 0.33, 0.31],
    "Back": [0.40, 0.73, 0.42],
    "Core": [0.26, 0.65, 0.96],
    "Legs": [0.67, 0.28, 0.74],
}
STAT_COLORS = {
    equipment_id: FAMILY_COLORS[family]
    for equipment_id, family in EQUIPMENT_FAMILY.items()
}
STAT_COLORS.update(FAMILY_COLORS)


def training_venue(equipment_id, district_accent):
    """Original part-built architecture wrapped around one training machine."""
    family = EQUIPMENT_FAMILY[equipment_id]
    color = FAMILY_COLORS[family]
    dark = [0.12, 0.13, 0.15]
    concrete = [0.31, 0.31, 0.32]
    out = [
        part("VenuePad", [30, 0.22, 30], cf(0, FLOOR_TOP + 0.11, 0),
             concrete, "Concrete", CanCollide=False),
        part("StatStripe", [30, 0.12, 1.1], cf(0, FLOOR_TOP + 0.26, 13.6),
             color, "Neon", CanCollide=False, CastShadow=False),
    ]

    if family == "Chest":
        # A heavy open-front press bay: concrete sides, lit lintel, no front wall.
        out.extend([
            part("ChestWall", [30, 12, 1.2], cf(0, FLOOR_TOP + 6, -14), dark, "Concrete"),
            part("ChestWing", [1.2, 9, 13], cf(-14.4, FLOOR_TOP + 4.5, -7.5), dark, "Concrete"),
            part("ChestWing", [1.2, 9, 13], cf(14.4, FLOOR_TOP + 4.5, -7.5), dark, "Concrete"),
            part("ChestLintel", [28, 1.0, 1.5], cf(0, FLOOR_TOP + 11.5, -13.4), color, "Neon"),
        ])
    elif family == "Arms":
        # A steel street cage; open sides keep the three curl spots reachable.
        for x in (-14, 14):
            for z in (-13, 13):
                out.append(part("ArmsPost", [1.0, 14, 1.0], cf(x, FLOOR_TOP + 7, z), dark, "Metal"))
        out.extend([
            part("ArmsCanopy", [30, 0.8, 30], cf(0, FLOOR_TOP + 14.2, 0), dark, "Metal"),
            part("ArmsBeam", [30, 0.7, 0.8], cf(0, FLOOR_TOP + 12.6, 13.4), color, "Neon"),
        ])
    elif family == "Back":
        # A tall back-training tower visible over nearby props.
        out.extend([
            part("BackTower", [24, 18, 1.2], cf(0, FLOOR_TOP + 9, -14), dark, "Metal"),
            part("BackCutout", [18, 11, 0.3], cf(0, FLOOR_TOP + 7.5, -13.3),
                 [0.22, 0.24, 0.28], "DiamondPlate"),
            part("BackTop", [26, 1.2, 2.0], cf(0, FLOOR_TOP + 18.3, -14), color, "Neon"),
        ])
    elif family == "Core":
        # A low court keeps sightlines open while marking a dedicated Core area.
        for x, z, sx, sz in ((0, -14, 30, 1), (-14, 0, 1, 28), (14, 0, 1, 28)):
            out.append(part("CoreWall", [sx, 3.2, sz], cf(x, FLOOR_TOP + 1.6, z), dark, "Concrete"))
        for x in (-12, 12):
            out.append(part("CoreBeacon", [1.0, 8, 1.0], cf(x, FLOOR_TOP + 4, -13), color, "Neon"))
    else:
        # The treadmill sits on a long marked running lane with a finish gantry.
        out.extend([
            part("LegsLane", [12, 0.18, 42], cf(0, FLOOR_TOP + 0.22, 5),
                 [0.16, 0.17, 0.19], "Asphalt", CanCollide=False),
            part("LaneLine", [0.35, 0.12, 42], cf(-5, FLOOR_TOP + 0.36, 5), color, "Neon", CanCollide=False),
            part("LaneLine", [0.35, 0.12, 42], cf(5, FLOOR_TOP + 0.36, 5), color, "Neon", CanCollide=False),
            part("LegsGantry", [16, 1.0, 1.0], cf(0, FLOOR_TOP + 11, -14), color, "Neon"),
            part("LegsPost", [1.0, 11, 1.0], cf(-7.5, FLOOR_TOP + 5.5, -14), dark, "Metal"),
            part("LegsPost", [1.0, 11, 1.0], cf(7.5, FLOOR_TOP + 5.5, -14), dark, "Metal"),
        ])

    # One small district-colour marker ties the venue back to its progression zone.
    out.append(part("DistrictMarker", [2.2, 5.5, 2.2], cf(12.5, FLOOR_TOP + 2.75, 12.5),
                    district_accent, "Neon", CanCollide=False))
    return out


# --------------------------------------------------------------------------
# Downtown: the city island at the origin.
#
# A grid, not a scatter. Two roads each way at +/-GRID, with the plaza sitting
# in the block they enclose, and four avenues running from there out to the
# island edge. The twelve rectangles that grid leaves behind are the city's
# plots: ten get buildings, and two are handed to Garage Gym and Iron Hall —
# which is the whole reason those districts are `lot` shaped and stand here
# rather than on islands of their own.
# --------------------------------------------------------------------------

ROAD = [0.12, 0.12, 0.13]
ROAD_LINE = [0.76, 0.70, 0.36]
SIDEWALK = [0.40, 0.40, 0.41]
KERB = [0.53, 0.53, 0.54]

# Pushed out from 140 so the central block can hold the plaza AND the starter
# gym ringing it, with room to walk between them.
GRID = 170
ROAD_WIDTH = 36
# Plots run from the grid roads out to here; past it is promenade and railing.
PLOT_EDGE = 320

# Four skins rather than one, picked per building. A city where every wall is
# the same colour reads as a texture, not as a place people built over time.
BUILDING_SKINS = [
    {"wall": [0.45, 0.41, 0.36], "trim": [0.29, 0.26, 0.23],
     "glass": [0.15, 0.21, 0.26], "material": "Concrete"},
    {"wall": [0.37, 0.24, 0.20], "trim": [0.24, 0.15, 0.12],
     "glass": [0.14, 0.18, 0.23], "material": "Brick"},
    {"wall": [0.56, 0.53, 0.47], "trim": [0.36, 0.34, 0.30],
     "glass": [0.18, 0.25, 0.30], "material": "Sandstone"},
    {"wall": [0.21, 0.23, 0.27], "trim": [0.14, 0.15, 0.18],
     "glass": [0.20, 0.31, 0.37], "material": "Metal"},
]


def city_plots():
    """The twelve rectangles the street grid leaves behind, as (x, z, sx, sz).

    Three per quadrant: one flanking each avenue, one on the corner. The two
    corner plots the gym districts occupy are excluded by the caller.
    """
    out = []
    near, far = ROAD_WIDTH / 2 + 2, GRID - ROAD_WIDTH / 2
    inner, outer = GRID + ROAD_WIDTH / 2, PLOT_EDGE
    for sx in (-1, 1):
        for sz in (-1, 1):
            out.append((sx * (near + far) / 2, sz * (inner + outer) / 2,
                        far - near, outer - inner))
            out.append((sx * (inner + outer) / 2, sz * (near + far) / 2,
                        outer - inner, far - near))
            out.append((sx * (inner + outer) / 2, sz * (inner + outer) / 2,
                        outer - inner, outer - inner))
    return out


def street(length, width, frame, dash_axis):
    """Asphalt laid flush with the ground, with a dashed centre line."""
    out = [part("Road", [width, 0.5, length], frame, ROAD, "Asphalt",
                CanCollide=False)]
    for offset in range(-int(length // 2) + 20, int(length // 2) - 18, 44):
        out.append(part("Line", [1.2, 0.1, 14] if dash_axis else [14, 0.1, 1.2],
                        mul(frame, cf(0, 0.3, offset)), ROAD_LINE, "SmoothPlastic",
                        CanCollide=False, CastShadow=False))
    return out


def street_light(x, z, facing):
    """Pole, arm and head. Three parts, and they are what makes a road at dusk
    read as a road rather than as a grey stripe."""
    arm = mul(cf(x, FLOOR_TOP + 15.5, z), rot_y(facing))
    return [
        part("LightPole", [1.1, 16, 1.1], cf(x, FLOOR_TOP + 8, z), [0.17, 0.17, 0.19], "Metal"),
        part("LightArm", [0.8, 0.8, 7], mul(arm, cf(0, 0, 3.5)), [0.17, 0.17, 0.19], "Metal"),
        part("LightHead", [2.2, 0.7, 3.4], mul(arm, cf(0, -0.6, 6.6)),
             [1.0, 0.90, 0.68], "Neon", CanCollide=False),
    ]


def parked_car(x, z, facing, rng):
    """Six parts. Cars exist to give the kerb a scale and the street a life."""
    body = [rng.uniform(0.15, 0.75) for _ in range(3)]
    frame = mul(cf(x, FLOOR_TOP, z), rot_y(facing))
    out = [
        part("CarBody", [7.4, 3.2, 16], mul(frame, cf(0, 2.6, 0)), body, "Metal"),
        part("CarCabin", [6.6, 2.8, 7.6], mul(frame, cf(0, 5.6, -0.6)),
             [0.11, 0.12, 0.15], "Glass", Reflectance=0.25),
    ]
    for sx in (-1, 1):
        for sz in (-1, 1):
            out.append(cylinder("CarWheel", 1.2, 3.0,
                                mul(frame, mul(cf(sx * 3.6, 1.5, sz * 5.2), rot_y(90))),
                                [0.06, 0.06, 0.07], "Rubber"))
    return out


def palm(x, z, rng):
    """Trunk and fronds. The one plant in a city of concrete."""
    height = rng.uniform(16, 26)
    out = [cylinder("PalmTrunk", height, 2.2,
                    mul(cf(x, FLOOR_TOP + height / 2, z), rot_z(90)),
                    [0.31, 0.25, 0.18], "Wood")]
    for index in range(6):
        angle = 60 * index + rng.uniform(-12, 12)
        frond = mul(mul(cf(x, FLOOR_TOP + height, z), rot_y(angle)), rot_x(-28))
        out.append(part("PalmFrond", [2.4, 0.4, 11],
                        mul(frond, cf(0, 0, 5)), [0.16, 0.33, 0.16], "Grass",
                        CanCollide=False))
    return out


def building(x, z, sx, sz, height, skin, rng):
    """A tower: storefront band, shaft, glazing on each face, and a parapet.

    Deliberately few parts. At the distance you actually see these from, a
    window strip per face carries a building far better than a floor-by-floor
    grid would, and this map has ten plots of them to pay for.
    """
    out = [
        part("Storefront", [sx, 9, sz], cf(x, FLOOR_TOP + 4.5, z),
             skin["trim"], skin["material"]),
        part("Shaft", [sx - 2, height, sz - 2], cf(x, FLOOR_TOP + 9 + height / 2, z),
             skin["wall"], skin["material"]),
        part("Parapet", [sx + 1, 3, sz + 1], cf(x, FLOOR_TOP + 10.5 + height, z),
             skin["trim"], skin["material"]),
    ]

    lit = rng.random() < 0.4
    for side, (ox, oz, w, d) in enumerate((
        (0, sz / 2 - 1, sx - 10, 0.6),
        (0, -sz / 2 + 1, sx - 10, 0.6),
        (sx / 2 - 1, 0, 0.6, sz - 10),
        (-sx / 2 + 1, 0, 0.6, sz - 10),
    )):
        if w <= 0 or d <= 0:
            continue
        out.append(part("Glazing", [w, height - 6, d],
                        cf(x + ox, FLOOR_TOP + 9 + height / 2, z + oz),
                        skin["glass"], "Neon" if lit else "Glass",
                        Transparency=0 if lit else 0.35, CanCollide=False))

    # Lit shopfront across the street-facing side, at head height.
    if sx >= sz:
        shop_size, shop_at = [sx - 12, 5, 0.4], cf(x, FLOOR_TOP + 4.5, z + sz / 2 - 0.2)
    else:
        shop_size, shop_at = [0.4, 5, sz - 12], cf(x + sx / 2 - 0.2, FLOOR_TOP + 4.5, z)
    out.append(part("ShopGlass", shop_size, shop_at, [0.85, 0.72, 0.38], "Neon",
                    CanCollide=False))
    return out


def city_plot(x, z, sx, sz, rng):
    """A sidewalk, its kerb, and two or three buildings standing on it."""
    out = [
        part("Sidewalk", [sx, 1.0, sz], cf(x, FLOOR_TOP + 0.5, z), SIDEWALK, "Concrete"),
        # Non-colliding: a kerb is a painted edge, not a wall. Left solid it is 160
        # ankle-height ledges across the city for a running player to catch on.
        part("Kerb", [sx + 3, 0.7, sz + 3], cf(x, FLOOR_TOP + 0.35, z), KERB, "Concrete",
             CanCollide=False),
    ]

    # Split the long axis into two or three footprints with a gap between, so a
    # plot reads as several buildings rather than one extruded rectangle.
    along_x = sx >= sz
    span = sx if along_x else sz
    count = 2 if span < 150 else 3
    cell = span / count
    for index in range(count):
        offset = -span / 2 + cell * (index + 0.5)
        w = cell - 12 if along_x else sx - 16
        d = sz - 16 if along_x else cell - 12
        out.extend(building(
            x + (offset if along_x else 0), z + (0 if along_x else offset),
            w, d, rng.uniform(26, 104), rng.choice(BUILDING_SKINS), rng,
        ))
    return out


# --------------------------------------------------------------------------
# What stands in the plaza.
#
# The plaza is the only safe ground in the game and the only place travel is
# free, so it is where everybody ends up. That makes it the right place for the
# two things the player needs a person or an object for: quests and standings.
# Both are inert geometry here — a tag and an id — and the client controllers
# in #75 and #76 give them behaviour.
# --------------------------------------------------------------------------

PLAZA_TOP = FLOOR_TOP + 0.8

SKIN = [0.76, 0.58, 0.44]
TRACKSUIT = [0.13, 0.14, 0.17]


def facing_centre(x, z):
    """Degrees of yaw that turn an object's +Z front toward the origin."""
    return math.degrees(math.atan2(x, z)) + 180


def npc(name, npc_id, x, z, accent):
    """A part-built figure. R6 proportions, no rig and no animation — it stands
    there and holds a ProximityPrompt, which is all a quest giver has to do."""
    frame = mul(cf(x, 0, z), rot_y(facing_centre(x, z)))
    body = [
        part("LeftLeg", [1.0, 2.8, 1.0], cf(-0.6, PLAZA_TOP + 1.4, 0), TRACKSUIT, "Fabric"),
        part("RightLeg", [1.0, 2.8, 1.0], cf(0.6, PLAZA_TOP + 1.4, 0), TRACKSUIT, "Fabric"),
        # Named Base to match the station contract, so anything looking for an
        # object's anchor part finds the same name everywhere in the world.
        part("Base", [2.3, 2.8, 1.3], cf(0, PLAZA_TOP + 4.2, 0), TRACKSUIT, "Fabric"),
        part("Stripe", [2.4, 0.5, 1.35], cf(0, PLAZA_TOP + 4.6, 0), accent, "Neon",
             CanCollide=False),
        part("LeftArm", [0.9, 2.6, 0.9], cf(-1.6, PLAZA_TOP + 4.2, 0), TRACKSUIT, "Fabric"),
        part("RightArm", [0.9, 2.6, 0.9], cf(1.6, PLAZA_TOP + 4.2, 0), TRACKSUIT, "Fabric"),
        part("Head", [1.5, 1.5, 1.5], cf(0, PLAZA_TOP + 6.4, 0), SKIN, "SmoothPlastic"),
        part("Cap", [1.7, 0.6, 1.7], cf(0, PLAZA_TOP + 7.3, 0), accent, "Fabric"),
        part("CapPeak", [1.6, 0.25, 0.9], cf(0, PLAZA_TOP + 7.1, 1.1), accent, "Fabric",
             CanCollide=False),
    ]
    return tagged({
        "name": name,
        "className": "Model",
        "properties": {"ModelStreamingMode": "Atomic"},
        "children": [place(frame, piece) for piece in body],
    }, tags=["Npc"], attributes={"NpcId": npc_id})


def leaderboard_monument(name, board_id, x, z, accent):
    """Plinth, frame and a screen the client paints an OrderedDataStore board onto.

    The screen's readable side faces local +Z, which is this script's convention
    for "the side you approach from" — and which is Roblox's Back face, not its
    Front. The controller names that explicitly rather than guessing.
    """
    frame = mul(cf(x, 0, z), rot_y(facing_centre(x, z)))
    pieces = [
        part("Plinth", [13, 3, 5], cf(0, PLAZA_TOP + 1.5, 0), [0.34, 0.34, 0.35], "Concrete"),
        part("Frame", [13, 17, 1.8], cf(0, PLAZA_TOP + 11.5, 0), [0.17, 0.18, 0.21], "Metal"),
        part("Screen", [11.8, 15, 0.3], cf(0, PLAZA_TOP + 11.5, 0.95),
             [0.05, 0.05, 0.07], "SmoothPlastic"),
        part("Header", [13, 0.6, 2.0], cf(0, PLAZA_TOP + 20.3, 0), accent, "Neon",
             CanCollide=False),
    ]
    return tagged({
        "name": name,
        "className": "Model",
        "properties": {"ModelStreamingMode": "Atomic"},
        "children": [place(frame, piece) for piece in pieces],
    }, tags=["LeaderboardBoard"], attributes={"BoardId": board_id})


def bench(x, z):
    """Somewhere to stand around. A plaza with nothing to face is a floor."""
    frame = mul(cf(x, 0, z), rot_y(facing_centre(x, z)))
    pieces = [
        part("Seat", [9, 0.5, 2.6], cf(0, PLAZA_TOP + 2.0, 0), [0.36, 0.25, 0.16], "WoodPlanks"),
        part("BenchBack", [9, 2.2, 0.4], cf(0, PLAZA_TOP + 3.1, -1.1),
             [0.36, 0.25, 0.16], "WoodPlanks"),
    ]
    for side in (-1, 1):
        pieces.append(part("BenchLeg", [0.5, 2.0, 2.4], cf(side * 3.8, PLAZA_TOP + 1.0, 0),
                           [0.17, 0.17, 0.19], "Metal"))
    return [place(frame, piece) for piece in pieces]


def plaza_furniture():
    """The quest giver, the standings, and something to sit on."""
    out = [npc("Coach", "Coach", 0, -17, ACCENT_STARTER)]

    # Two monuments, because LeaderboardService defines two boards. A third
    # board would be a third entry here and nothing else.
    out.append(leaderboard_monument("StrongestBoard", "Power", -23, 18, [1.0, 0.77, 0.24]))
    out.append(leaderboard_monument("KnockoutsBoard", "Kills", 23, 18, [1.0, 0.36, 0.36]))

    out.extend(bench(-20, -2))
    out.extend(bench(20, -2))
    return out


def downtown():
    out = []
    rng = random.Random("Downtown")
    size = DOWNTOWN_HALF * 2
    row = {
        "half": DOWNTOWN_HALF,
        "rock": [0.15, 0.15, 0.17],
        "rock_material": "Rock",
    }

    out.append(part("Ground", [size, 4, size], cf(0, FLOOR_TOP - 2, 0),
                    [0.21, 0.21, 0.22], "Asphalt"))
    out.append(part("GroundTrim", [size + 8, 2, size + 8], cf(0, FLOOR_TOP - 5, 0),
                    [0.26, 0.27, 0.30], "Concrete"))

    # The grid: two roads each way across the island, then four avenues from
    # the plaza block out to the edge.
    # `street` lays its road along the frame's local Z, so the ones that run
    # east-west are the rotated pair, not the ones sitting at x = +/-GRID.
    for sign in (-1, 1):
        out.extend(street(size, ROAD_WIDTH,
                          mul(cf(0, FLOOR_TOP - 0.25, sign * GRID), rot_y(90)), False))
        out.extend(street(size, ROAD_WIDTH, cf(sign * GRID, FLOOR_TOP - 0.25, 0), False))

        inner = GRID - ROAD_WIDTH / 2
        avenue = DOWNTOWN_HALF - inner
        mid = sign * (inner + avenue / 2)
        out.extend(street(avenue, ROAD_WIDTH, cf(0, FLOOR_TOP - 0.25, mid), True))
        out.extend(street(avenue, ROAD_WIDTH,
                          mul(cf(mid, FLOOR_TOP - 0.25, 0), rot_y(90)), True))

    # Plots. The two the gym districts stand on are left bare here; their own
    # `lot` geometry covers them.
    gym_plots = {(round(district_origin(r)[0][0]), round(district_origin(r)[0][2]))
                 for r in DISTRICTS if r["shape"] == "lot"}
    for x, z, sx, sz in city_plots():
        if (round(x), round(z)) in gym_plots:
            continue
        out.extend(city_plot(x, z, sx, sz, rng))

    # Street furniture along both sides of the grid roads.
    for sign in (-1, 1):
        for along in range(-DOWNTOWN_HALF + 60, DOWNTOWN_HALF - 40, 74):
            out.extend(street_light(along, sign * (GRID - ROAD_WIDTH / 2 - 3), 90 * sign))
            out.extend(street_light(sign * (GRID - ROAD_WIDTH / 2 - 3), along, 90 - 90 * sign))
        for along in range(-DOWNTOWN_HALF + 96, DOWNTOWN_HALF - 90, 122):
            out.extend(parked_car(along, sign * (GRID - ROAD_WIDTH / 2 - 6), 90, rng))
            out.extend(parked_car(sign * (GRID - ROAD_WIDTH / 2 - 6), along, 0, rng))

    # Plaza: raised a hair so it reads as its own surface, and the only place
    # in the game where travel is free.
    out.append(disc("Plaza", 1.2, PLAZA_RADIUS * 2, FLOOR_TOP + 0.2,
                    [0.42, 0.41, 0.40], "Pavement"))
    out.append(disc("PlazaInlay", 0.4, PLAZA_RADIUS * 1.1, FLOOR_TOP + 0.9,
                    [0.55, 0.50, 0.38], "Marble", CanCollide=False))

    for index in range(12):
        angle = 360.0 * index / 12
        spot = mul(rot_y(angle), cf(0, 0, PLAZA_RADIUS + 3))
        out.append(part("PlazaLamp", [1.4, 16, 1.4],
                        cf(spot[0][0], FLOOR_TOP + 8, spot[0][2]),
                        [0.16, 0.16, 0.18], "Metal"))
        out.append(part("PlazaLampHead", [2.4, 1.2, 2.4],
                        cf(spot[0][0], FLOOR_TOP + 16.4, spot[0][2]),
                        [1.0, 0.93, 0.76], "Neon", CanCollide=False))

    # The safe zone, sized to the plaza rather than to a 40-stud bubble. It is
    # both the PvP shelter and the origin check for free travel, so its extent
    # is a gameplay number, not decoration.
    out.append(tagged(
        part("SpawnSafeZone", [SAFE_ZONE_HALF * 2, 44, SAFE_ZONE_HALF * 2],
             cf(0, FLOOR_TOP + 22, 0), [0.4, 0.8, 1.0], "ForceField",
             CanCollide=False, Transparency=0.94, CastShadow=False),
        tags=["SafeZone"],
    ))

    # Causeway out to the Docks, so the first three tiers stay walkable.
    # Spans exactly the gap between the two square edges, with a short seat at
    # each end — run it further and its railings end up crossing the city.
    angle = math.radians(CAUSEWAY_BEARING)
    inner = DOWNTOWN_HALF / max(abs(math.sin(angle)), abs(math.cos(angle)))
    docks = next(r for r in DISTRICTS if r["zone"] == "Powerhouse")
    outer = docks["radius"] - docks["half"]
    span = (outer - inner) + 24
    bridge = mul(rot_y(CAUSEWAY_BEARING), cf(0, FLOOR_TOP - 0.8, (inner + outer) / 2))
    out.append(part("Causeway", [36, 1.6, span], bridge,
                    [0.28, 0.28, 0.29], "Concrete"))
    for side in (-1, 1):
        out.append(part("CausewayRail", [1.6, 3.2, span],
                        mul(bridge, cf(side * 17.2, 2.4, 0)),
                        [0.20, 0.21, 0.23], "Metal"))

    # Promenade railing around the island edge, and palms along it. The edge is
    # a 300-stud drop into nothing now that the baseplate is gone, so it wants
    # to be visibly an edge.
    for sign in (-1, 1):
        for axis in (0, 1):
            at = cf(0, FLOOR_TOP + 2, sign * (DOWNTOWN_HALF - 2))
            frame = mul(rot_y(90 * axis), at)
            out.append(part("Railing", [DOWNTOWN_HALF * 2, 3.4, 1.2], frame,
                            [0.24, 0.25, 0.27], "Metal"))
        for along in range(-DOWNTOWN_HALF + 70, DOWNTOWN_HALF - 60, 96):
            out.extend(palm(along, sign * (DOWNTOWN_HALF - 16), rng))
            out.extend(palm(sign * (DOWNTOWN_HALF - 16), along, rng))

    # Palms ring the starter gym rather than the plaza: between the two is where
    # players walk, and a tree there is something to walk around.
    for index in range(8):
        angle = 360.0 * index / 8 + 22.5
        spot = mul(rot_y(angle), cf(0, 0, 130))
        out.extend(palm(spot[0][0], spot[0][2], rng))

    out.extend(plaza_furniture())

    out.extend(underside(row, rng, False))
    return out


def build_world():
    structure = [folder("Downtown", downtown())]
    machines = []

    for row in DISTRICTS:
        origin = district_origin(row)
        rng = random.Random(row["zone"])

        pieces = SHAPES[row["shape"]](row, rng)
        pieces.append(spawn_pad(row))
        pieces.extend(zone_volume(row))
        children = [place(origin, piece) for piece in pieces]

        # Props live in their own folder: it keeps Studio navigable, and it is
        # what lets the layout check tell scenery from the island itself.
        theme = row.get("props")
        if theme is not None:
            children.append(folder("Props", [
                _decorate(place(origin, piece)) for piece in PROPS[theme](row, rng)
            ]))

        spots = machine_spots(row)
        children.append(folder("TrainingAreas", [
            group(f"{equipment_id}Area", [
                place(mul(origin, spot), piece)
                for piece in training_venue(equipment_id, row["accent"])
            ], class_name="Folder")
            for equipment_id, spot in zip(MACHINE_ORDER, spots)
        ]))
        structure.append(folder(row["zone"], children))

        machines.append(folder(row["zone"], [
            machine(f"{row['zone']}{equipment_id}", equipment_id, mul(origin, spot),
                    BUILDERS[equipment_id](row["pad"], row["accent"]))
            for equipment_id, spot in zip(MACHINE_ORDER, spots)
        ]))

    return ({"className": "Folder", "children": structure},
            {"className": "Folder", "children": machines})


# --------------------------------------------------------------------------
# Connected city world.
#
# The original district geometry remains above as a record of the island pass
# and as a library of props/builders. Shipping now uses this layout: one flat,
# continuous street grid with one hidden training location per city block.
# Tier and stat are deliberately shuffled across the grid, so the world is not
# eleven level islands or five stat rows. The map UI reveals every location;
# physically finding its doorway is the exploration layer.
# --------------------------------------------------------------------------

THIRD_FLOOR_Y = 24
MAP_FEATURE_TAG = "MapFeature"
GROUND_STYLES = ["warehouse", "alley", "yard", "underpass", "bunker"]

# The connected world is an irregular coastal loop rather than a rectangular
# grid. A region is a visual landmark, not a progression tier: the 30 non-starter
# tier/family pairs are shuffled across all ten. The large hidden foundation is
# only a fall catcher; visible land remains an irregular chain of districts.
WORLD_FOUNDATION_SIZE = (6200, 5600)
WORLD_WATER_SIZE = (6000, 5400)
REGIONS = [
    {"id": "OldTown", "theme": "Iron", "center": (-790, 300),
     "size": (660, 520), "yaw": -12, "shape": "Rect", "count": 6},
    {"id": "Harbor", "theme": "Powerhouse", "center": (-1950, -260),
     "size": (790, 510), "yaw": 16, "shape": "Rect", "count": 7},
    {"id": "Beach", "theme": "Strongman", "center": (-1690, -1260),
     "size": (660, 660), "yaw": 0, "shape": "Circle", "count": 3},
    {"id": "Quarry", "theme": "Titan", "center": (-360, -1780),
     "size": (700, 700), "yaw": -18, "shape": "Circle", "count": 4},
    {"id": "Highrise", "theme": "Skydeck", "center": (1020, -1410),
     "size": (790, 570), "yaw": 21, "shape": "Rect", "count": 7},
    {"id": "SolarWorks", "theme": "Solar", "center": (2040, -470),
     "size": (750, 530), "yaw": -14, "shape": "Rect", "count": 5},
    {"id": "Stormworks", "theme": "Storm", "center": (1950, 890),
     "size": (660, 660), "yaw": 0, "shape": "Circle", "count": 4},
    {"id": "NeonMarket", "theme": "Nebula", "center": (780, 1650),
     "size": (790, 550), "yaw": 27, "shape": "Rect", "count": 6},
    {"id": "Observatory", "theme": "Ascendant", "center": (-550, 1920),
     "size": (660, 660), "yaw": 0, "shape": "Circle", "count": 3},
    {"id": "VoidRail", "theme": "Void", "center": (-1650, 1270),
     "size": (750, 550), "yaw": -24, "shape": "Rect", "count": 5},
]
REGION_BY_ID = {region["id"]: region for region in REGIONS}
REGION_LINKS = [
    ("OldTown", "Harbor"), ("Harbor", "Beach"), ("Beach", "Quarry"),
    ("Quarry", "Highrise"), ("Highrise", "SolarWorks"),
    ("SolarWorks", "Stormworks"), ("Stormworks", "NeonMarket"),
    ("NeonMarket", "Observatory"), ("Observatory", "VoidRail"),
    ("VoidRail", "OldTown"),
]

# Seven irregular local sites, consumed in different quantities by each region.
# Rotating and scaling these per patch yields 50 non-axial, well-separated sites
# while keeping their authored doors close enough to a road to be found on foot.
REGION_SITE_PATTERN = [
    (-0.31, -0.24), (0.29, -0.27), (-0.34, 0.23), (0.32, 0.25),
    (-0.02, 0.01), (0.00, -0.42), (-0.04, 0.42),
]
NON_STARTER_VARIANT_SEQUENCE = (1, 2, 0, 1, 2, 0, 1, 2, 0, 1)


def map_feature(node, kind, shape="Rect"):
    """Marks real geometry as a simplified feature on the in-game plan map."""
    return tagged(node, tags=[MAP_FEATURE_TAG], attributes={
        "MapKind": kind,
        "MapShape": shape,
    })


def map_footprint(name, width, depth, frame, color, kind, shape="Rect"):
    """Invisible top-down footprint for geometry whose visible parts are complex."""
    return map_feature(
        part(name, [width, 0.2, depth], frame, color, "SmoothPlastic",
             CanCollide=False, CanTouch=False, CanQuery=False,
             Transparency=1, CastShadow=False),
        kind,
        shape,
    )


def tiled_surface(name, width, depth, height, y, color, material,
                  columns=4, rows=4, map_kind=None, **props):
    """Build a seamless surface without exceeding Roblox's 2,048-stud Part cap."""
    tile_width = width / columns
    tile_depth = depth / rows
    out = []
    for column in range(columns):
        x = -width / 2 + tile_width * (column + 0.5)
        for row in range(rows):
            z = -depth / 2 + tile_depth * (row + 0.5)
            node = part(
                f"{name}_{column + 1}_{row + 1}",
                [tile_width, height, tile_depth], cf(x, y, z),
                color, material, **props,
            )
            out.append(map_feature(node, map_kind) if map_kind else node)
    return out


def region_frame(region):
    x, z = region["center"]
    return mul(cf(x, 0, z), rot_y(region["yaw"]))


def region_sites(region):
    """World-space site CFrames for one irregular region."""
    width, depth = region["size"]
    frame = region_frame(region)
    out = []
    for index, (unit_x, unit_z) in enumerate(REGION_SITE_PATTERN[:region["count"]]):
        local = cf(unit_x * width, 0, unit_z * depth)
        yaw_jitter = (-8, -4, 0, 4, 8)[index % 5]
        out.append(mul(mul(frame, local), rot_y(yaw_jitter)))
    return out


def _assignment_is_varied(assignments):
    tier_regions = {}
    family_regions = {family: set() for family in FAMILY_ORDER}
    region_tiers = {}
    region_families = {}
    for record, region_id, _site_index, _site in assignments:
        tier_regions.setdefault(record["zone"], set()).add(region_id)
        family_regions[record["family"]].add(region_id)
        key = (region_id, record["zone"])
        region_tiers[key] = region_tiers.get(key, 0) + 1
        key = (region_id, record["family"])
        region_families[key] = region_families.get(key, 0) + 1
    return (
        all(len(regions) >= 4 for regions in tier_regions.values())
        and all(len(regions) >= 5 for regions in family_regions.values())
        and max(region_tiers.values()) <= 2
        and max(region_families.values()) <= 2
    )


def connected_locations():
    """Thirty-five destinations: seven doubling locations for every muscle.

    The first five form a readable x1 ring around spawn. The other thirty are
    deterministically shuffled over ten far-apart neighborhoods so multiplier,
    muscle and scenery never collapse into rows. Each family keeps one recognizable
    exercise at every tier, while the environment supplies the discovery fantasy.
    """
    tier_rows = DISTRICTS[:7]
    starters = []
    starter_sites = [
        (-62, -42, 32), (54, -56, -24), (-70, 35, 112),
        (12, 68, 188), (70, 20, 254),
    ]
    for family, equipment_id, (x, z, yaw) in zip(
            FAMILY_ORDER, MACHINE_ORDER, starter_sites):
        origin = mul(cf(x, 0, z), rot_y(yaw))
        starters.append({
            "id": f"Garage-{family}",
            "zone": "Garage",
            "family": family,
            "slot": equipment_id,
            "equipment": equipment_id,
            "site_x": x,
            "site_z": z,
            "ground_origin": origin,
            "origin": origin,
            "style": "starter",
            "seed": f"massive-city-v1:Garage:{family}",
            "starter": True,
            "landmark": False,
            "region_id": "Hub",
            "environment_id": "Hub",
            "neighborhood": "Garage",
            "requires_flight": False,
            "altitude": 0,
            "location_name": f"Starter {family} Yard",
            "location_tagline": "The x1 training spot beside the central safe zone.",
        })

    records = []
    for zone_index, zone_row in enumerate(tier_rows[1:], 1):
        for family_index, family in enumerate(FAMILY_ORDER):
            records.append({
                "zone": zone_row["zone"],
                "zone_index": zone_index,
                "family": family,
                "family_index": family_index,
                "equipment": STAT_VARIANTS[family][zone_index],
            })

    # Three active sites in every neighborhood makes the whole 5,000-stud city
    # meaningful while avoiding the old tell of exactly five machines per district.
    slots = [
        (region["id"], site_index, site)
        for region in REGIONS
        for site_index, site in enumerate(region_sites(region)[:3])
    ]
    assignments = None
    for attempt in range(2000):
        shuffled = list(records)
        random.Random(f"massive-city-v1:assignment:{attempt}").shuffle(shuffled)
        candidate = [
            (record, region_id, site_index, site)
            for record, (region_id, site_index, site) in zip(shuffled, slots)
        ]
        if _assignment_is_varied(candidate):
            assignments = candidate
            break
    if assignments is None:
        raise RuntimeError("could not distribute the 30 outer training sites")

    out = list(starters)
    for index, (record, region_id, site_index, site) in enumerate(assignments):
        zone_index = record["zone_index"]
        family_index = record["family_index"]
        requires_flight = zone_index == 6
        # Each muscle has one intermediate third-floor secret, but its multiplier
        # differs by muscle so a player cannot infer the whole progression from one.
        third_floor = not requires_flight and zone_index == 1 + family_index
        style = "sky" if requires_flight else (
            "tower" if third_floor else GROUND_STYLES[(index + zone_index + family_index) % len(GROUND_STYLES)]
        )
        altitude = 0 if not requires_flight else 180 + family_index * 24
        origin = mul(site, cf(0, altitude if requires_flight else (
            THIRD_FLOOR_Y if third_floor else 0), 0))
        region = REGION_BY_ID[region_id]
        site_x, _, site_z = site[0]
        travel_id = f"{record['zone']}-{record['family']}"
        access_text = "Fly to the skyline platform." if requires_flight else (
            "Find the entrance and climb to floor three." if third_floor
            else "Search the street-level gym landmark."
        )
        out.append({
            "id": travel_id,
            "zone": record["zone"],
            "family": record["family"],
            "slot": record["equipment"],
            "equipment": record["equipment"],
            "site_x": site_x,
            "site_z": site_z,
            "ground_origin": site,
            "origin": origin,
            "style": style,
            "seed": f"massive-city-v1:{travel_id}:{region_id}",
            "starter": False,
            "landmark": site_index == 0,
            "region_id": region_id,
            "environment_id": f"Sky-{travel_id}" if requires_flight else region_id,
            "neighborhood": region["theme"],
            "requires_flight": requires_flight,
            "altitude": altitude,
            "location_name": f"{region_id} {record['family']} Gym",
            "location_tagline": access_text,
        })
    return out


def hideout_shell(style, equipment_id, accent):
    """Street-facing cover around a stat venue; the entrance always faces +Z."""
    wall = [0.16, 0.17, 0.19]
    trim = STAT_COLORS[equipment_id]
    out = []

    if style == "warehouse":
        out.extend([
            part("WarehouseBack", [48, 16, 1.2], cf(0, FLOOR_TOP + 8, -26), wall, "Brick"),
            part("WarehouseSide", [1.2, 16, 56], cf(-24, FLOOR_TOP + 8, 2), wall, "Brick"),
            part("WarehouseSide", [1.2, 16, 56], cf(24, FLOOR_TOP + 8, 2), wall, "Brick"),
            part("WarehouseRoof", [48, 1.0, 56], cf(0, FLOOR_TOP + 16.5, 2), wall, "Metal"),
            part("WarehouseSign", [28, 1.2, 1.0], cf(0, FLOOR_TOP + 14, 29), trim, "Neon"),
        ])
    elif style == "alley":
        out.extend([
            part("AlleyLeft", [18, 30, 62], cf(-24, FLOOR_TOP + 15, 0), wall, "Concrete"),
            part("AlleyRight", [18, 24, 62], cf(24, FLOOR_TOP + 12, 0), [0.21, 0.18, 0.17], "Brick"),
            part("AlleyBack", [30, 10, 1.0], cf(0, FLOOR_TOP + 5, -29), wall, "Concrete"),
            part("AlleyLight", [20, 0.5, 0.8], cf(0, FLOOR_TOP + 12, -28), trim, "Neon"),
        ])
    elif style == "yard":
        # A fenced construction yard: visible from the air, concealed from the street.
        for x, z, sx, sz in ((0, -28, 54, 1), (-27, 0, 1, 56), (27, 0, 1, 56)):
            out.append(part("YardFence", [sx, 8, sz], cf(x, FLOOR_TOP + 4, z), wall, "DiamondPlate"))
        out.extend([
            part("SiteOffice", [18, 10, 14], cf(-16, FLOOR_TOP + 5, -18),
                 [0.37, 0.30, 0.22], "Metal"),
            part("YardLamp", [3, 14, 3], cf(24, FLOOR_TOP + 7, -24), accent, "Neon"),
        ])
    elif style == "underpass":
        out.extend([
            part("Overpass", [62, 4, 64], cf(0, FLOOR_TOP + 17, 0), [0.27, 0.27, 0.28], "Concrete"),
            part("Support", [5, 17, 5], cf(-26, FLOOR_TOP + 8.5, -25), wall, "Concrete"),
            part("Support", [5, 17, 5], cf(26, FLOOR_TOP + 8.5, -25), wall, "Concrete"),
            part("UnderpassStrip", [32, 0.7, 1.0], cf(0, FLOOR_TOP + 15, -28), trim, "Neon"),
        ])
    else:
        out.extend([
            part("BunkerBack", [52, 13, 4], cf(0, FLOOR_TOP + 6.5, -27), wall, "Concrete"),
            part("BunkerSide", [4, 13, 58], cf(-26, FLOOR_TOP + 6.5, 0), wall, "Concrete"),
            part("BunkerSide", [4, 13, 58], cf(26, FLOOR_TOP + 6.5, 0), wall, "Concrete"),
            part("BunkerRoof", [56, 3, 60], cf(0, FLOOR_TOP + 14.5, 0), [0.23, 0.23, 0.24], "Concrete"),
            part("BunkerHeader", [24, 1.2, 4.2], cf(0, FLOOR_TOP + 11.5, 29), trim, "Neon"),
        ])
    return out


def enterable_training_tower(travel_id, equipment_id, accent):
    """An atomic, enterable three-storey building with a floor-three gym."""
    wall = [0.18, 0.19, 0.22]
    glass = [0.12, 0.23, 0.30]
    stat = STAT_COLORS[equipment_id]
    out = [
        # All surfaces line up with the builders' local FLOOR_TOP=1 contract.
        # Upper slabs stop at x=16, leaving a 14-stud stairwell at the right wall.
        part("Floor1", [60, 1, 66], cf(0, FLOOR_TOP - 0.5, 0),
             [0.34, 0.34, 0.35], "Concrete"),
        part("Floor2", [46, 1, 62], cf(-7, FLOOR_TOP + 11.5, 0),
             [0.30, 0.30, 0.32], "Concrete"),
        part("Floor3", [46, 1, 62], cf(-7, FLOOR_TOP + 23.5, 0),
             [0.30, 0.30, 0.32], "Concrete"),
        # The first flight rises from the front door toward -Z. The second turns
        # back and rises toward +Z. Both overlap their landings, eliminating the
        # small edge gaps that make Roblox pathfinding reject a staircase.
        part("LandingFloor2", [14, 1, 22], cf(23, FLOOR_TOP + 11.5, -13),
             [0.30, 0.30, 0.32], "Concrete"),
        part("LandingFloor3", [14, 1, 18], cf(23, FLOOR_TOP + 23.5, 7),
             [0.30, 0.30, 0.32], "Concrete"),
        part("Stair_L1", [10, 1.2, 30],
             mul(cf(23, FLOOR_TOP + 5.5, 8), rot_x(23.6)),
             [0.26, 0.27, 0.30], "DiamondPlate"),
        part("Stair_L2", [10, 1.2, 30],
             mul(cf(23, FLOOR_TOP + 17.5, -7), rot_x(-23.6)),
             [0.26, 0.27, 0.30], "DiamondPlate"),
        # Back and side walls, plus a real ground-floor doorway. Upper storeys
        # are closed facades so the hidden machine is not exposed like a dollhouse.
        part("TowerBack", [60, 44, 1.2], cf(0, 22, -33), wall, "Brick"),
        part("TowerLeft", [1.2, 44, 66], cf(-30, 22, 0), wall, "Brick"),
        part("TowerRight", [1.2, 44, 66], cf(30, 22, 0), wall, "Brick"),
        part("TowerRoof", [62, 1.2, 68], cf(0, 44.6, 0), wall, "Metal"),
        part("FrontGroundLeft", [23, 12, 1.2], cf(-18.5, 7, 33), wall, "Brick"),
        part("FrontGroundRight", [23, 12, 1.2], cf(18.5, 7, 33), wall, "Brick"),
        part("EntranceHeader", [14, 2, 1.5], cf(0, 12, 33), stat, "Neon"),
        part("FrontFloor2", [60, 10.8, 1.2], cf(0, 19, 33), wall, "Brick"),
        part("FrontFloor3", [60, 18.8, 1.2], cf(0, 34.6, 33), wall, "Brick"),
        part("TierStrip", [58, 0.8, 1.5], cf(0, 42, 32.2), accent, "Neon"),
        marker("Entrance", [12, 9, 2], cf(0, 5.5, 31.5)),
        part("TrainingRoomFloor", [30, 0.12, 30],
             cf(0, THIRD_FLOOR_Y + FLOOR_TOP + 0.06, 0), stat, "Neon",
             CanCollide=False, Transparency=0.82, CastShadow=False),
    ]

    # Window bands make each storey readable from the street while keeping the
    # machine itself out of sight until the player climbs inside.
    for y in (7, 19, 31):
        out.append(part("Window", [18, 6, 0.3], cf(-18, FLOOR_TOP + y, 33.7),
                        glass, "Glass", Transparency=0.28, CanCollide=False))
        out.append(part("Window", [18, 6, 0.3], cf(18, FLOOR_TOP + y, 33.7),
                        glass, "Glass", Transparency=0.28, CanCollide=False))

    return {
        "name": f"Enterable_{travel_id}",
        "className": "Model",
        "attributes": {
            "Enterable": True,
            "FloorCount": 3,
            "TrainingFloor": 3,
            "TravelId": travel_id,
            "AccessKind": "ThirdFloor",
        },
        "properties": {"ModelStreamingMode": "Atomic"},
        "children": out,
    }


def environment_model(environment_id, kind, children, atomic=False,
                      requires_flight=False, travel_id=None):
    attributes = {
        "EnvironmentId": environment_id,
        "EnvironmentKind": kind,
        "RequiresFlight": requires_flight,
    }
    if travel_id is not None:
        attributes["TravelId"] = travel_id
    properties = {"Tags": ["TrainingEnvironment"]}
    if atomic:
        properties["ModelStreamingMode"] = "Atomic"
    return {
        "name": f"Environment_{environment_id}",
        "className": "Model",
        "attributes": attributes,
        "properties": properties,
        "children": children,
    }


def road_between(name, start, finish):
    """A walkable causeway and road segment between two irregular patches."""
    x1, z1 = start
    x2, z2 = finish
    dx, dz = x2 - x1, z2 - z1
    length = math.hypot(dx, dz)
    yaw = math.degrees(math.atan2(dx, dz))
    frame = mul(cf((x1 + x2) / 2, 0, (z1 + z2) / 2), rot_y(yaw))
    out = [
        place(frame, map_feature(
            part("LandCorridor", [78, 4, length + 44], cf(0, FLOOR_TOP - 2, 0),
                 [0.22, 0.23, 0.23], "Ground"),
            "Land",
        )),
        place(frame, map_feature(
            part("Road", [40, 0.45, length + 18], cf(0, FLOOR_TOP + 0.03, 0),
                 ROAD, "Asphalt", CanCollide=False),
            "Road",
        )),
    ]
    for offset in range(-int(length / 2) + 18, int(length / 2) - 16, 42):
        out.append(place(frame, part(
            "RoadLine", [1.1, 0.1, 15], cf(0, FLOOR_TOP + 0.31, offset),
            ROAD_LINE, "SmoothPlastic", CanCollide=False, CastShadow=False,
        )))
    return folder(name, out)


def region_ground(region):
    """A non-uniform coastal patch whose top remains the shared street Y=1."""
    visual = next(row for row in DISTRICTS if row["zone"] == region["theme"])
    width, depth = region["size"]
    frame = region_frame(region)
    out = []
    if region["shape"] == "Circle":
        diameter = min(width, depth)
        out.append(place(frame, disc(
            "DistrictGround", 4, diameter, FLOOR_TOP - 2,
            visual["ground"], visual["ground_material"],
        )))
        out.append(place(frame, disc(
            "DistrictFoundation", 5, diameter + 10, FLOOR_TOP - 6.5,
            visual["rock"], visual["rock_material"],
        )))
        out.append(place(frame, map_footprint(
            "DistrictLandMap", diameter, diameter, cf(0, FLOOR_TOP + 0.1, 0),
            visual["ground"], "Land", "Circle",
        )))
    else:
        out.extend([
            place(frame, map_feature(part(
                "DistrictGround", [width, 4, depth], cf(0, FLOOR_TOP - 2, 0),
                visual["ground"], visual["ground_material"],
            ), "Land")),
            place(frame, part(
                "DistrictFoundation", [width + 10, 5, depth + 10],
                cf(0, FLOOR_TOP - 6.5, 0), visual["rock"], visual["rock_material"],
            )),
        ])

        # Two rounded lobes break the silhouette of each rotated slab and make
        # actual coves/peninsulas on both the world and its plan map.
        lobe_diameter = min(depth * 0.48, 150)
        for side in (-1, 1):
            lobe_frame = mul(frame, cf(side * width * 0.43, 0, side * depth * 0.22))
            out.append(place(lobe_frame, disc(
                "DistrictLobe", 4, lobe_diameter, FLOOR_TOP - 2,
                visual["ground"], visual["ground_material"],
            )))
            out.append(place(frame, map_footprint(
                "DistrictLobeMap", lobe_diameter, lobe_diameter,
                cf(side * width * 0.43, FLOOR_TOP + 0.1, side * depth * 0.22),
                visual["ground"], "Land", "Circle",
            )))
    return out


def _decorate(node):
    """Make a scenery node non-blocking, in place, and return it.

    Props exist to make the city look like a place. They are not obstacles, and
    every one of them that collides is something to get snagged on while running a
    hundred studs between machines or flying between districts — a shipping
    container is 26 studs deep and a crane leg is 62 tall.

    They keep their shadows and their looks; they simply stop being in the way.
    Collision is reserved for the things the layout actually intends you to walk on
    or around: ground, buildings, platforms and the machines themselves.
    """
    properties = node.setdefault("properties", {})
    if "Size" in properties or "CFrame" in properties:
        properties["CanCollide"] = False
        properties["CanTouch"] = False
        properties["CanQuery"] = False
    for child in node.get("children", []):
        _decorate(child)
    return node


# Clearance around a machine that scenery may not occupy. A container placed at the
# old 48 could still crowd the working space in front of a squat rack, which is the
# one spot a player has to stand.
PROP_CLEARANCE = 72


def _node_hits_sites(node, sites, clearance=PROP_CLEARANCE):
    properties = node.get("properties", {})
    frame = properties.get("CFrame")
    size = properties.get("Size", [0, 0, 0])
    if frame is not None:
        radius = max(size[0], size[2]) / 2
        if any(math.hypot(frame[0] - x, frame[2] - z) < clearance + radius
               for x, z in sites):
            return True
    return any(_node_hits_sites(child, sites, clearance)
               for child in node.get("children", []))


def region_scenery(region, locations):
    """One old-island landmark kit per neighborhood, filtered around gyms."""
    visual = next(row for row in DISTRICTS if row["zone"] == region["theme"])
    theme = visual.get("props")
    if theme is None:
        return []
    row = dict(visual)
    row["half"] = min(region["size"]) * 0.43
    row["layout"] = "ring"
    rng = random.Random(f"irregular-city-v3:scenery:{region['id']}")
    site_positions = [(location["site_x"], location["site_z"])
                      for location in locations]
    out = []
    for piece in PROPS[theme](row, rng):
        placed = place(region_frame(region), piece)
        if not _node_hits_sites(placed, site_positions):
            out.append(_decorate(placed))
    return out


def connected_ground():
    """Large foundation, water background, and irregular causeway graph."""
    out = [
        {
            "name": "WorldFoundation",
            "className": "Folder",
            "attributes": {
                "PlayableFoundation": True,
                "Purpose": "WorldBoundsAndFallCatcher",
                "FoundationCenterX": 0,
                "FoundationCenterZ": 0,
                "FoundationWidth": WORLD_FOUNDATION_SIZE[0],
                "FoundationDepth": WORLD_FOUNDATION_SIZE[1],
                "TileColumns": 4,
                "TileRows": 4,
            },
            "children": tiled_surface(
                "FoundationTile", WORLD_FOUNDATION_SIZE[0], WORLD_FOUNDATION_SIZE[1],
                6, FLOOR_TOP - 12.5, [0.055, 0.06, 0.07], "Rock",
                CanTouch=False, CanQuery=False,
            ),
        },
        folder("WorldWater", tiled_surface(
            "OceanTile", WORLD_WATER_SIZE[0], WORLD_WATER_SIZE[1],
            3, FLOOR_TOP - 10, [0.08, 0.20, 0.27], "Glass",
            map_kind="Water", CanCollide=False, CanTouch=False,
            CanQuery=False, Transparency=0.18,
        )),
        environment_model("Hub", "Ground", [
            disc("HubGround", 5, 470, FLOOR_TOP - 2.5,
                 [0.22, 0.23, 0.23], "Ground"),
            disc("HubFoundation", 5, 482, FLOOR_TOP - 7.5,
                 [0.13, 0.14, 0.15], "Rock"),
            map_footprint("HubLandMap", 470, 470, cf(0, FLOOR_TOP + 0.1, 0),
                          [0.22, 0.23, 0.23], "Land", "Circle"),
        ]),
    ]
    road_nodes = []
    for index, (start_id, finish_id) in enumerate(REGION_LINKS):
        road_nodes.append(road_between(
            f"RingRoad{index + 1}", REGION_BY_ID[start_id]["center"],
            REGION_BY_ID[finish_id]["center"],
        ))
    for region_id in ("OldTown", "Highrise", "NeonMarket"):
        road_nodes.append(road_between(
            f"HubRoad{region_id}", (0, 0), REGION_BY_ID[region_id]["center"],
        ))
    out.append(folder("RoadNetwork", road_nodes))
    return out


def connected_plaza():
    out = [
        # Top surface is exactly FLOOR_TOP, matching every machine builder.
        disc("Plaza", 1.2, PLAZA_RADIUS * 2, FLOOR_TOP - 0.6,
             [0.42, 0.41, 0.40], "Pavement"),
        disc("PlazaInlay", 0.08, PLAZA_RADIUS * 1.1, FLOOR_TOP + 0.04,
             [0.55, 0.50, 0.38], "Marble", CanCollide=False),
        tagged(
            part("SpawnSafeZone", [SAFE_ZONE_HALF * 2, 44, SAFE_ZONE_HALF * 2],
                 cf(0, FLOOR_TOP + 22, 0), [0.4, 0.8, 1.0], "ForceField",
                 CanCollide=False, Transparency=1, CastShadow=False),
            tags=["SafeZone"],
        ),
        map_footprint("PlazaMap", PLAZA_RADIUS * 2, PLAZA_RADIUS * 2,
                      cf(0, FLOOR_TOP + 0.1, 0), [0.48, 0.47, 0.45],
                      "Plaza", "Circle"),
        map_footprint("SafeZoneMap", SAFE_ZONE_HALF * 2, SAFE_ZONE_HALF * 2,
                      cf(0, FLOOR_TOP + 0.15, 0), [0.30, 0.86, 1.0],
                      "SafeZone"),
    ]

    # The safe volume remains invisible and authoritative; these four luminous
    # ForceField walls make its exact boundary obvious without blocking movement.
    barrier_color = [0.30, 0.86, 1.0]
    for x, z, sx, sz in (
        (0, -SAFE_ZONE_HALF, SAFE_ZONE_HALF * 2, 1.2),
        (0, SAFE_ZONE_HALF, SAFE_ZONE_HALF * 2, 1.2),
        (-SAFE_ZONE_HALF, 0, 1.2, SAFE_ZONE_HALF * 2),
        (SAFE_ZONE_HALF, 0, 1.2, SAFE_ZONE_HALF * 2),
    ):
        out.append(part("SafeBarrier", [sx, 20, sz], cf(x, FLOOR_TOP + 10, z),
                        barrier_color, "ForceField", CanCollide=False,
                        Transparency=0.58, CastShadow=False))
        out.append(part("SafeBoundary", [sx, 0.5, sz], cf(x, FLOOR_TOP + 0.35, z),
                        barrier_color, "Neon", CanCollide=False, CastShadow=False))
    for index in range(12):
        angle = 360.0 * index / 12
        spot = mul(rot_y(angle), cf(0, 0, PLAZA_RADIUS + 22))
        out.append(part("PlazaLamp", [1.4, 16, 1.4],
                        cf(spot[0][0], FLOOR_TOP + 8, spot[0][2]),
                        [0.16, 0.16, 0.18], "Metal"))
        out.append(part("PlazaLampHead", [2.4, 1.2, 2.4],
                        cf(spot[0][0], FLOOR_TOP + 16.4, spot[0][2]),
                        [1.0, 0.93, 0.76], "Neon", CanCollide=False))
    out.extend(plaza_furniture())
    return out


def starter_training_area(location, zone_row):
    """One of all five x1 machines openly grouped around the spawn campus."""
    origin = location["origin"]
    out = [
        place(origin, piece)
        for piece in training_venue(location["equipment"], zone_row["accent"])
    ]
    out.append(place(origin, volume(
        location["zone"], f"{location['id']}Volume", [54, 40, 54], cf(0, 19, 0)
    )))
    out.append(place(origin, map_footprint(
        "StarterVenueMap", 30, 30, cf(0, FLOOR_TOP + 0.1, 0),
        FAMILY_COLORS[location["family"]], "Building"
    )))
    return out


def connected_block(location, zone_row, visual_row):
    """One irregular ground site: pavement, secret shell and private zone."""
    ground_origin = location["ground_origin"]
    out = [
        place(ground_origin, map_feature(part(
            "SitePavement", [86, 1, 88], cf(0, FLOOR_TOP - 0.5, 0),
            visual_row["ground"], visual_row["ground_material"],
        ), "Block")),
    ]
    for x, z, sx, sz in (
        (-44, 0, 2, 90), (44, 0, 2, 90),
        (0, -45, 90, 2), (0, 45, 90, 2),
    ):
        out.append(place(ground_origin, part(
            "Kerb", [sx, 0.3, sz], cf(x, FLOOR_TOP + 0.15, z), KERB, "Concrete",
            CanCollide=False,
        )))

    origin = location["origin"]
    if location["style"] == "tower":
        out.append(place(ground_origin, enterable_training_tower(
            location["id"], location["equipment"], visual_row["accent"]
        )))
        out.append(place(ground_origin, map_footprint(
            "TowerMap", 60, 66, cf(0, FLOOR_TOP + 0.2, 0),
            [0.18, 0.19, 0.22], "Building"
        )))
    else:
        out.extend(place(origin, piece) for piece in hideout_shell(
            location["style"], location["equipment"], visual_row["accent"]
        ))
        out.append(place(origin, map_footprint(
            "HideoutMap", 58, 64, cf(0, FLOOR_TOP + 0.2, 0),
            [0.20, 0.21, 0.23], "Building"
        )))
    out.extend(place(origin, piece) for piece in training_venue(
        location["equipment"], visual_row["accent"]
    ))
    out.append(place(origin, volume(
        location["zone"], f"{location['id']}Volume", [78, 54, 84], cf(0, 25, 0)
    )))
    return out


def sky_training_environment(location, zone_row, visual_row):
    """An atomic, flight-only crane deck with rails and a recovery scaffold."""
    accent = visual_row["accent"]
    platform = [0.20, 0.22, 0.25]
    out = [
        part("LandingSurface", [96, 2, 88], cf(0, 0, 0), platform, "DiamondPlate"),
        part("RecoveryDeck", [128, 2, 120], cf(0, -26, 0),
             [0.16, 0.18, 0.21], "DiamondPlate"),
        map_footprint("SkyPlatformMap", 96, 88, cf(0, 0.25, 0),
                      platform, "SkyPlatform"),
        marker("AccessEnd", [18, 10, 4], cf(0, 7, 45)),
        part("CraneMast", [6, location["altitude"], 6],
             cf(-39, -location["altitude"] / 2, -34),
             [0.34, 0.30, 0.22], "DiamondPlate"),
        part("CraneBeacon", [8, 3, 8], cf(-39, 5, -34), accent, "Neon",
             CanCollide=False),
    ]
    tagged(out[3], tags=["VenueAccess"], attributes={
        "TravelId": location["id"], "Role": "AccessEnd",
    })
    for x, z, sx, sz in (
        (0, -43, 96, 2), (-47, 0, 2, 88), (47, 0, 2, 88),
        (-35, 43, 26, 2), (35, 43, 26, 2),
    ):
        out.append(part("SkyRail", [sx, 5, sz], cf(x, 3.5, z),
                        accent, "ForceField", Transparency=0.28))
    for x, z, sx, sz in (
        (0, -58, 128, 2), (-63, 0, 2, 120), (63, 0, 2, 120),
        (0, 58, 128, 2),
    ):
        out.append(part("RecoveryRail", [sx, 4, sz], cf(x, -23, z),
                        [0.34, 0.36, 0.40], "Metal"))
    out.extend(training_venue(location["equipment"], visual_row["accent"]))
    out.append(volume(
        location["zone"], f"{location['id']}Volume", [112, 76, 104], cf(0, 30, 0)
    ))
    placed = [place(location["origin"], piece) for piece in out]
    return environment_model(
        location["environment_id"], "Sky", placed, atomic=True,
        requires_flight=True, travel_id=location["id"],
    )


def sky_launch_site(location, visual_row):
    """A visible ground tether and access marker below every aerial gym."""
    origin = location["ground_origin"]
    out = [
        place(origin, map_feature(part(
            "LaunchPad", [82, 1, 82], cf(0, FLOOR_TOP - 0.5, 0),
            [0.22, 0.24, 0.27], "Concrete",
        ), "Park")),
        place(origin, disc("LaunchRing", 0.18, 48, FLOOR_TOP + 0.1,
                           visual_row["accent"], "Neon", CanCollide=False)),
        place(origin, marker("AccessStart", [18, 8, 18],
                             cf(0, FLOOR_TOP + 4, 18))),
    ]
    tagged(out[2], tags=["VenueAccess"], attributes={
        "TravelId": location["id"], "Role": "AccessStart",
    })
    for x, z in ((-28, -28), (28, -28), (-28, 28), (28, 28)):
        out.append(place(origin, part(
            "FlightBeacon", [2.2, 18, 2.2], cf(x, FLOOR_TOP + 9, z),
            visual_row["accent"], "Neon", CanCollide=False,
        )))
    return out


def build_connected_world():
    locations = connected_locations()
    zone_rows = {row["zone"]: row for row in DISTRICTS}
    structure = connected_ground()
    machines = []
    hub_children = connected_plaza()
    region_children = {region["id"]: region_ground(region) for region in REGIONS}
    sky_environments = []

    for location in locations:
        row = zone_rows[location["zone"]]
        visual_row = zone_rows[location["neighborhood"]]
        if location["starter"]:
            hub_children.append(folder(location["id"], starter_training_area(location, row)))
        elif location["style"] == "sky":
            region_children[location["region_id"]].append(folder(
                f"Launch_{location['id']}", sky_launch_site(location, visual_row)
            ))
            sky_environments.append(sky_training_environment(location, row, visual_row))
        else:
            region_children[location["region_id"]].append(folder(
                location["id"], connected_block(location, row, visual_row)
            ))

        access_kind = "Sky" if location["style"] == "sky" else (
            "ThirdFloor" if location["style"] == "tower" else "Street"
        )
        machines.append(machine(
            location["id"], location["equipment"], location["origin"],
            BUILDERS[location["equipment"]](row["pad"], row["accent"]),
            travel_id=location["id"],
            access_kind=access_kind,
            floor_index=3 if location["style"] == "tower" else 1,
            exercise_family=location["family"],
            environment_id=location["environment_id"],
            requires_flight=location["requires_flight"],
            location_name=location["location_name"],
            location_tagline=location["location_tagline"],
        ))

    # connected_ground creates Hub first so replace that minimal environment with
    # its complete plaza/starter campus while preserving the road/water siblings.
    for index, node in enumerate(structure):
        if node.get("name") == "Environment_Hub":
            node["children"].extend(hub_children)
            structure[index] = node
            break

    for region in REGIONS:
        region_locations = [location for location in locations
                            if location.get("region_id") == region["id"]]
        region_children[region["id"]].extend(region_scenery(region, region_locations))
        structure.append(environment_model(
            region["id"], "Ground", region_children[region["id"]]
        ))
    structure.extend(sky_environments)

    return (
        {"className": "Folder", "children": [folder("IrregularCoastCity", structure)]},
        {"className": "Folder", "children": machines},
    )


def write(name, payload):
    path = os.path.abspath(os.path.join(OUT_DIR, name))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    print(f"wrote {os.path.relpath(path)} ({count_instances(payload)} instances)")


def count_instances(node):
    if isinstance(node, dict):
        return sum(count_instances(child) for child in node.get("children", [])) + (
            1 if "className" in node and "name" in node else 0
        )
    return 0


def main():
    structure, machines = build_connected_world()
    write("init.meta.json", {"className": "Model"})
    write("Structure.model.json", structure)
    write("Machines.model.json", machines)


if __name__ == "__main__":
    main()
