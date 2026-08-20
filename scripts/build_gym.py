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
# How far a paved surface is lifted when it is laid on top of another one.
#
# Every walkable surface here is built to top out at exactly FLOOR_TOP so a machine
# placed at FLOOR_TOP stands flush wherever it is put. Two of them overlapping is the
# problem: the plaza is a 180-stud disc lying on a 470-stud ground disc, and two
# coplanar faces do not take turns — the renderer tears them into a flickering
# checkerboard, which is what the hub floor was doing.
#
# The fix lifts the upper surface rather than sinking the ground, and the direction
# matters. Sinking the ground leaves every lamp post and bench standing on it hovering a
# visible hair above nothing. Lifting the pavement instead means anything standing on
# the pavement is bedded a hundredth of a stud into it, which no one can see and nothing
# reads as a bug.
SURFACE_LIFT = 0.04
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
ACCENT_STARTER = [0.49, 0.83, 0.61]
ACCENT_IRON = [0.26, 0.65, 0.96]
WOOD = [0.35, 0.24, 0.16]


def part(name, size, frame, color, material="Metal", class_name="Part", **props):
    properties = {
        "Anchored": True,
        "CFrame": serialise_cf(frame),
        "Size": [round(v, 3) for v in size],
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


def wedge(name, size, frame, color, material="Metal", **props):
    """A ramp. Roblox slopes a WedgePart down along +Z from the top of its -Z face,
    so a roof pitch is a wedge rotated to face the eave it falls toward."""
    return part(name, size, frame, color, material, class_name="WedgePart", **props)


def marker(name, size, frame):
    """An invisible, non-colliding reference part — anchors and exits."""
    return part(name, size, frame, [1, 1, 1], "SmoothPlastic",
                Transparency=1, CanCollide=False, CastShadow=False)


# --------------------------------------------------------------------------
# Detail helpers. A machine built from bare boxes reads as a blockout no matter
# how many boxes it has, so these exist to add the specific cues that separate
# real equipment from a placeholder: round steel instead of square, rolled pad
# edges instead of a flat slab, visible hardware at the joints, feet under the
# frame. They are shared rather than per-machine because 35 builders hand-rolling
# their own bolt heads is how a room stops looking designed.
# --------------------------------------------------------------------------


def _unit(v):
    """A vector scaled to length 1, and the length it had."""
    length = math.sqrt(sum(c * c for c in v))
    if length < 1e-6:
        raise ValueError("zero-length vector has no direction")
    return tuple(c / length for c in v), length


def _perpendicular(direction):
    """Any unit vector at right angles to `direction`.

    Round geometry is symmetric about its own axis, so which perpendicular this
    picks never shows. Seeding off X unless the run is nearly parallel to X keeps
    the cross product well away from zero.
    """
    seed = (1.0, 0.0, 0.0) if abs(direction[0]) < 0.9 else (0.0, 0.0, 1.0)
    axis, _ = _unit(cross(seed, direction))
    return axis


def tube(name, start, end, diameter, color, material="Metal", **props):
    """Round stock running between two points.

    The single strongest "this is real equipment" cue available without meshes.
    Gym frames are welded tube; drawn as boxes they read as scaffolding. Because
    a cylinder's axis is its local X, the run direction becomes the right vector
    and the length becomes the X size.
    """
    span = tuple(e - s for s, e in zip(start, end))
    direction, length = _unit(span)
    middle = tuple((s + e) / 2 for s, e in zip(start, end))
    return part(name, [length, diameter, diameter],
                axes(middle, direction, _perpendicular(direction)),
                color, material, Shape="Cylinder", **props)


def hardware(name, frame, diameter=0.18, depth=0.09, color=CHROME):
    """A bolt head or tube end cap.

    One part, and the cheapest detail in the file: an unbroken steel surface
    reads as a untextured box, and the eye finds the same surface convincing the
    moment something interrupts it at the joints.
    """
    return cylinder(name, depth, diameter, frame, color, "Metal",
                    Reflectance=0.3, CanCollide=False)


def foot_pad(name, frame, size=(0.9, 0.22, 0.9)):
    """A rubber foot under a frame leg.

    Machines authored flush to the floor look like they were dropped through it.
    A foot gives the frame somewhere to end.
    """
    return part(name, list(size), frame, RUBBER, "Rubber")


def padded_slab(name, size, frame, color, caps=False):
    """Upholstery with a rolled edge instead of a flat slab.

    Every pad in the gym is currently one rectangular box, which is the detail
    most responsible for the equipment looking cheap: real vinyl is wrapped over
    foam and turns a radius at every edge. The core is inset and the radius is
    drawn as round stock down each long side, so the silhouette curves.

    Rolls run along whichever of X/Z is longer, which is the pad's length for
    every pad in the file. `caps` adds the short-end rolls too — worth it on a
    bench pad the player lies on, wasted on a small roller pad.
    """
    sx, sy, sz = size
    roll = min(sy, min(sx, sz) * 0.5)
    out = []

    if sz >= sx:
        core_x, core_z = sx - roll, sz - (roll if caps else 0.0)
        out.append(part(name, [core_x, sy, core_z], frame, color, "Fabric"))
        for side in (-1, 1):
            out.append(cylinder(
                f"{name}Roll", core_z, roll,
                mul(frame, mul(cf(side * core_x / 2, 0, 0), rot_y(90))),
                color, "Fabric"))
        if caps:
            for side in (-1, 1):
                out.append(cylinder(
                    f"{name}Cap", core_x, roll,
                    mul(frame, cf(0, 0, side * core_z / 2)), color, "Fabric"))
    else:
        core_x, core_z = sx - (roll if caps else 0.0), sz - roll
        out.append(part(name, [core_x, sy, core_z], frame, color, "Fabric"))
        for side in (-1, 1):
            out.append(cylinder(
                f"{name}Roll", core_x, roll,
                mul(frame, cf(0, 0, side * core_z / 2)), color, "Fabric"))
        if caps:
            for side in (-1, 1):
                out.append(cylinder(
                    f"{name}Cap", core_z, roll,
                    mul(frame, mul(cf(side * core_x / 2, 0, 0), rot_y(90))),
                    color, "Fabric"))
    return out


def pulley(name, centre, diameter, accent, axis_length=0.5, mount=None):
    """A cable wheel in its housing, on the bracket that carries it.

    Selectorised machines currently route their cable past nothing at all, so the
    line changes direction in mid-air. A wheel at the corner is what makes the
    routing legible — the cable turns because something turns it.

    The wheel's axle runs along X, so the wheel itself lies in the machine's
    YZ plane, which is the plane every cable in the gym runs in.

    `mount` is where the bracket is bolted; without one the wheel hangs in the
    air, which is the exact problem it was added to solve. The cheeks are kept
    well under the wheel diameter so the rim the cable actually rides on still
    shows between them.
    """
    cheek = diameter * 0.62
    out = [
        cylinder(f"{name}Wheel", 0.22, diameter,
                 mul(cf(*centre), rot_z(90)), CHROME, "Metal", Reflectance=0.3),
        cylinder(f"{name}Axle", axis_length + 0.24, 0.16,
                 cf(*centre), STEEL_LIGHT, "Metal"),
    ]
    for side in (-1, 1):
        out.append(part(f"{name}Cheek", [0.12, cheek, cheek],
                        cf(centre[0] + side * axis_length / 2, centre[1], centre[2]),
                        accent, "Metal"))
    if mount is not None:
        out.append(tube(f"{name}Bracket", mount, centre, 0.3, STEEL_LIGHT))
        out.append(hardware(f"{name}BracketBolt",
                            mul(cf(*mount), rot_z(90)), 0.34))
    return out


def console(name, frame, accent, size=(2.6, 1.5, 0.18)):
    """A machine readout: bezel, screen, and the light it throws.

    A Neon slab on its own is a glowing rectangle; the bezel is what makes it a
    screen. The light is deliberately short-range and shadowless — 35 of these
    across the gym is affordable only because none of them cast.
    """
    sx, sy, sz = size
    screen = part(f"{name}Screen", [sx * 0.82, sy * 0.72, sz * 0.6],
                  mul(frame, cf(0, 0, sz * 0.4)), accent, "Neon",
                  CanCollide=False)
    screen["children"] = [{
        "name": "Glow", "className": "PointLight",
        "properties": {
            "Brightness": 1.4, "Range": 9, "Shadows": False,
            "Color": [round(c, 4) for c in accent],
        },
    }]
    return [
        part(f"{name}Bezel", [sx, sy, sz], frame, STEEL, "Metal"),
        screen,
    ]


def stack_shroud(name, top_centre, width, height, depth, accent):
    """The housing around a weight stack.

    `add_load_visuals` grows the plates themselves; this is the cabinet they sit
    in. Bare slabs stacked in the open are the clearest tell that a machine was
    blocked out and never finished, and the shroud is also what the selector
    label has to sit on.
    """
    cx, cy, cz = top_centre
    return [
        part(f"{name}Shroud", [0.14, height, depth],
             cf(cx - width / 2, cy - height / 2, cz), STEEL, "Metal"),
        part(f"{name}Shroud", [0.14, height, depth],
             cf(cx + width / 2, cy - height / 2, cz), STEEL, "Metal"),
        part(f"{name}Cap", [width + 0.3, 0.5, depth + 0.2],
             cf(cx, cy + 0.25, cz), STEEL_LIGHT, "DiamondPlate"),
        part(f"{name}Label", [width * 0.5, 0.34, 0.1],
             cf(cx, cy - 0.55, cz + depth / 2), accent, "Neon",
             CanCollide=False),
    ]


# Every machine lays a floor_mat under itself, and the mat is 0.12 thick. Builders
# pass FLOOR_TOP to anchor_standing because that is the height they think of as "the
# ground", so without this the avatar stands at FLOOR_TOP and its soles finish 0.12
# studs inside the mat it is standing on. Measured on eight standing machines: every
# one sank between 0.08 and 0.12.
MAT_THICKNESS = 0.12


def anchor_standing(frame):
    """A training spot where the player stands upright, facing the CFrame's look."""
    return marker("TrainAnchor", [2, 2, 1],
                  mul(frame, cf(0, ROOT_HEIGHT + MAT_THICKNESS, 0)))


# A lying anchor's up vector runs along the body from hips to head, so both of
# these put the head toward -Z; the right vector is what rolls the body over.
# Face-up and face-down differ by that one sign, which is exactly why they are
# named here rather than written out at each machine — three prone exercises were
# being performed on their backs because the supine line had been copied to them.
LYING_HEAD = (0, 0, -1)


def anchor_supine(pos):
    """Lying face-up — a bench press, a skull crusher."""
    return marker("TrainAnchor", [2, 2, 1], axes(pos, (-1, 0, 0), LYING_HEAD))


def anchor_prone(pos):
    """Lying face-down — a push-up, a plank, a lying leg curl."""
    return marker("TrainAnchor", [2, 2, 1], axes(pos, (1, 0, 0), LYING_HEAD))


# --------------------------------------------------------------------------
# Machines. Each returns a Model in its own local space: +Y up, the machine's
# front (the side a player approaches from) facing +Z.
# --------------------------------------------------------------------------

# Equipment whose resistance is visibly carried on a bar/dumbbell, versus a pin-
# selected stack. Bodyweight and cardio stations still use the load selector as game
# resistance, but do not grow implausible steel plates out of the floor.
FREE_WEIGHT_EQUIPMENT = {
    "BenchPress", "InclinePress", "Dumbbells", "BarbellCurl", "HammerCurl",
    "PreacherCurl", "SkullCrusher", "Deadlift", "TBarRow", "SquatRack",
    "DeclinePress",
}
SELECTORISED_EQUIPMENT = {
    "PecDeck", "CableCrossover", "TricepsPushdown", "SeatedRow", "LatPulldown",
    "CableCrunch", "WoodChop", "LegPress", "LegExtension",
    "HamstringCurl", "CalfRaise",
}

# IWF competition-disc denominations and colours. A gameplay load is the added
# resistance, so each 10 kg step is split symmetrically across both sleeves: the first
# step is one 5 kg white disc per side, while 100 kg is two 25 kg red discs
# per side. Configurations are ordered heaviest-to-lightest, as real bars are loaded.
OLYMPIC_DISC_STYLE = {
    25: ([0.72, 0.08, 0.10], 0.22, 1.90),
    20: ([0.10, 0.34, 0.73], 0.20, 1.85),
    15: ([0.91, 0.72, 0.10], 0.17, 1.75),
    10: ([0.10, 0.46, 0.20], 0.14, 1.60),
    5: ([0.84, 0.84, 0.80], 0.10, 1.32),
    2.5: ([0.72, 0.08, 0.10], 0.08, 1.05),
}
OLYMPIC_LOAD_STATES = (
    (5,), (10,), (15,), (20,), (25,),
    (25, 5), (25, 10), (25, 15), (25, 20), (25, 25),
)


def _cf_from_properties(properties):
    raw = properties["CFrame"]
    return (
        (raw[0], raw[1], raw[2]),
        (tuple(raw[3:6]), tuple(raw[6:9]), tuple(raw[9:12])),
    )


def _load_visual(node, kind, index, count):
    node.setdefault("attributes", {}).update({
        "LoadVisualKind": kind,
        "LoadVisualIndex": index,
        "LoadVisualCount": count,
    })
    return node


def olympic_load_visuals(base_frame, handle_length, scale=1.0):
    """All 10-100 kg symmetric Olympic loading states for one held implement."""
    visuals = []
    count = len(OLYMPIC_LOAD_STATES)
    inner = handle_length * 0.30
    for index, configuration in enumerate(OLYMPIC_LOAD_STATES, start=1):
        for side in (-1, 1):
            cursor = 0.0
            for plate_number, denomination in enumerate(configuration, start=1):
                color, authored_thickness, authored_diameter = OLYMPIC_DISC_STYLE[denomination]
                thickness = authored_thickness * scale
                diameter = authored_diameter * scale
                offset = side * (inner + cursor + thickness / 2)
                visual = cylinder(
                    f"Olympic{index:02d}_{denomination:g}kg_{plate_number}",
                    thickness, diameter, mul(base_frame, cf(offset, 0, 0)),
                    color, "SmoothPlastic", CanCollide=False, CanTouch=False,
                    CanQuery=False, Transparency=1,
                )
                visual.setdefault("attributes", {})["PlateKg"] = denomination
                visuals.append(_load_visual(visual, "FreePlate", index, count))
                cursor += thickness + 0.018 * scale
    return visuals


def body_load_visuals(base_frame, axis="x", scale=1.0):
    """All ten body-carried load states, preserving every individual disc.

    These are complete states just like ``olympic_load_visuals``. Unlike a bar there
    is only one central stack, but a 100% load is still visibly two 25 kg red discs,
    not one red cylinder whose extra thickness hides that a second plate exists.
    ``axis`` names the local direction in which the stack grows.
    """
    visuals = []
    count = len(OLYMPIC_LOAD_STATES)
    for index, configuration in enumerate(OLYMPIC_LOAD_STATES, start=1):
        total = sum(OLYMPIC_DISC_STYLE[value][1] * scale for value in configuration)
        cursor = -total / 2
        for plate_number, denomination in enumerate(configuration, start=1):
            color, authored_thickness, authored_diameter = OLYMPIC_DISC_STYLE[denomination]
            thickness = authored_thickness * scale
            diameter = authored_diameter * scale
            centre = cursor + thickness / 2
            offset = {
                "x": cf(centre, 0, 0),
                "y": cf(0, centre, 0),
                "z": cf(0, 0, centre),
            }[axis]
            visual = cylinder(
                f"OlympicBody{index:02d}_{denomination:g}kg_{plate_number}",
                thickness, diameter, mul(base_frame, offset),
                color, "SmoothPlastic", CanCollide=False, CanTouch=False,
                CanQuery=False, Transparency=1,
            )
            visual.setdefault("attributes", {})["PlateKg"] = denomination
            visuals.append(_load_visual(visual, "BodyPlate", index, count))
            cursor += thickness
    return visuals


def add_load_visuals(equipment_id, children):
    """Adds client-driven plate geometry before the machine is placed in the world.

    Each visual carries only an index. Runtime reads the server's replicated load
    ratio and reveals the matching number of discs/stack slices. The exact kg stays
    on the UI because late-game fantasy loads cannot be represented by literal 25 kg
    discs without making a bar hundreds of studs wide.
    """
    if equipment_id in FREE_WEIGHT_EQUIPMENT:
        def visit_held(node):
            if node.get("name") in ("HeldRight", "HeldLeft"):
                cylinders = [
                    child for child in node.get("children", [])
                    if child.get("className") in ("Part", "MeshPart")
                    and child.get("properties", {}).get("Shape") == "Cylinder"
                ]
                # Authored rubber heads are replaced by identifiable competition discs.
                for child in cylinders:
                    if child.get("name") in ("Head", "DumbbellHead", "Weight"):
                        child.get("properties", {})["Transparency"] = 1

                has_visual = any(
                    "LoadVisualKind" in child.get("attributes", {})
                    for child in node.get("children", [])
                )
                if not has_visual and cylinders:
                    grip = max(cylinders, key=lambda item: item["properties"]["Size"][0])
                    node["children"].extend(olympic_load_visuals(
                        _cf_from_properties(grip["properties"]),
                        grip["properties"]["Size"][0], 0.62,
                    ))

            if node.get("name") == "HeldBoth":
                candidates = [
                    child for child in node.get("children", [])
                    if child.get("className") == "Part"
                    and child.get("properties", {}).get("Shape") == "Cylinder"
                ]
                if candidates:
                    bar = max(candidates, key=lambda item: item["properties"]["Size"][0])
                    bar_size = bar["properties"]["Size"]
                    bar_frame = _cf_from_properties(bar["properties"])

                    # Authored plates become the invisible base; the five calibrated
                    # discs below are what respond to the selected load.
                    for child in node.get("children", []):
                        if "Plate" in child.get("name", ""):
                            child.get("properties", {})["Transparency"] = 1

                    node["children"].extend(olympic_load_visuals(
                        bar_frame, bar_size[0], 1.0,
                    ))

            for child in list(node.get("children", [])):
                visit_held(child)

        for child in children:
            visit_held(child)

    if equipment_id in SELECTORISED_EQUIPMENT:
        def add_stack_plates(nodes):
            additions = []
            for node in list(nodes):
                properties = node.get("properties", {})
                if node.get("name") in ("WeightStack", "WeightTower", "Tower") and "CFrame" in properties:
                    width, height, depth = properties["Size"]
                    tower_frame = _cf_from_properties(properties)
                    count = 10
                    gap = height / count
                    thickness = max(0.12, gap * 0.62)
                    # Real slabs sitting in the tower, not decals stuck on its front.
                    # These used to be 0.10 deep and pasted onto the outside face at
                    # depth/2 + 0.035, which reads as a sticker the moment it moves.
                    plate_depth = max(0.35, depth * 0.72)
                    for index in range(1, count + 1):
                        # Index 1 is the bottom of the stack, and the client lifts the
                        # top `selected` plates -- a pin goes in at the chosen plate and
                        # everything above it comes up. See TrainingPoseController.
                        y = -height / 2 + gap * (index - 0.5)
                        plate_frame = mul(tower_frame, cf(0, y, 0))
                        plate = part(
                            f"StackPlate{index:02d}",
                            [max(0.3, width * 0.86), thickness, plate_depth],
                            plate_frame, [0.07, 0.075, 0.085], "Metal",
                            CanCollide=False, CanTouch=False, CanQuery=False,
                            CastShadow=False,
                        )
                        additions.append(_load_visual(
                            plate, "StackPlate", index, count
                        ))
                    # The pin, and the guide rods the lifted block rides on. Without
                    # them a stack is a column of slabs that inexplicably splits in two.
                    for side in (-1, 1):
                        additions.append(part(
                            "StackGuideRod", [0.16, height * 0.98, 0.16],
                            mul(tower_frame, cf(side * width * 0.3, 0, 0)),
                            CHROME, "Metal", Reflectance=0.3,
                            CanCollide=False, CanTouch=False, CanQuery=False,
                            CastShadow=False,
                        ))
                    additions.append(_load_visual(part(
                        "StackPin", [width * 0.5, 0.22, 0.22],
                        mul(tower_frame, cf(0, 0, plate_depth / 2 + 0.12)),
                        [0.85, 0.62, 0.15], "Metal",
                        CanCollide=False, CanTouch=False, CanQuery=False,
                        CastShadow=False,
                    ), "StackPin", 1, count))
                add_stack_plates(node.get("children", []))
            nodes.extend(additions)

        add_stack_plates(children)


def machine_palette(equipment_id, row):
    """The upholstery and accent one machine is built in.

    Every machine on a court used to be handed its district's single pad colour, so
    five machines standing together were the same machine in different shapes. The
    accent still is the district's -- that is the thing carrying the identity of the
    room, and the palette comment above is right that a colour per part reads as a
    prototype -- but the upholstery now shifts a little per machine, which is what a
    real gym looks like as pads get replaced one at a time.

    Derived from the id rather than randomised, so a machine is the same colour in
    every build and the output stays byte-for-byte deterministic.
    """
    digest = 0
    for character in equipment_id:
        digest = (digest * 31 + ord(character)) % 9973

    # +/-12% per channel, on three different digits of the same digest so the
    # channels do not move together and merely brighten the pad.
    pad = []
    for index, channel in enumerate(row["pad"]):
        step = (digest // (7 ** index)) % 5 - 2
        pad.append(min(1.0, max(0.0, channel * (1 + step * 0.06))))
    return pad, row["accent"]


def machine_light(accent):
    """One short-range, shadowless light per machine.

    Machines contributed nothing to the room's own lighting: every lamp in the gym
    was in the structure, so equipment sat in whatever fell on it. Thirty-five of
    these is affordable exactly because none of them casts a shadow -- the same
    count with shadows on would not be.
    """
    fixture = marker("MachineLight", [0.4, 0.4, 0.4], cf(0, FLOOR_TOP + 6.5, 0))
    fixture["children"] = [{
        "name": "Glow", "className": "PointLight",
        "properties": {
            "Brightness": 0.85, "Range": 17, "Shadows": False,
            "Color": [round(c, 4) for c in accent],
        },
    }]
    return fixture


def machine(name, equipment_id, origin, children, travel_id=None,
            access_kind=None, floor_index=None, exercise_family=None,
            environment_id=None, requires_flight=False, location_name=None,
            location_tagline=None, accent=None):
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
    add_load_visuals(equipment_id, children)

    # Only if the machine does not already light itself. A console carries its own
    # glow, and hanging the generic fixture over it as well would put two lights on
    # one machine for no visible gain.
    def emits(node):
        if node.get("className") in ("PointLight", "SpotLight", "SurfaceLight"):
            return True
        return any(emits(child) for child in node.get("children", []))

    children = list(children)
    if not any(emits(child) for child in children):
        children.append(machine_light(accent or ACCENT_IRON))
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


def level_bar(children):
    """A HeldBoth barbell that stays horizontal while it is carried.

    A loaded olympic bar does not roll. The carry code otherwise takes the bar's
    axis straight from the two hand positions, so any asymmetry between them —
    the idle animation underneath the pose, the blend on the way in — shows up as
    the bar tilting through the rep. This tag tells it to flatten that axis.
    """
    held = group("HeldBoth", children)
    held["attributes"] = {"GripStyle": "LevelBar"}
    return held


def waist_chain_load(x, y, z):
    """Dip belt, short chain, and scalable hanging plates for pull movements."""
    pieces = [
        part("BeltFront", [2.5, 0.45, 0.28], cf(x, y + 1.55, z - 0.5),
             RUBBER, "Fabric", CanCollide=False, CanTouch=False, CanQuery=False),
        part("BeltBack", [2.5, 0.45, 0.28], cf(x, y + 1.55, z + 0.5),
             RUBBER, "Fabric", CanCollide=False, CanTouch=False, CanQuery=False),
        part("Buckle", [0.5, 0.55, 0.18], cf(x, y + 1.55, z - 0.68),
             CHROME, "Metal", CanCollide=False, CanTouch=False, CanQuery=False),
    ]
    for index in range(6):
        link_y = y + 1.12 - index * 0.42
        pieces.append(part(
            f"ChainLink{index + 1:02d}",
            [0.13 if index % 2 == 0 else 0.52, 0.34, 0.52 if index % 2 == 0 else 0.13],
            cf(x, link_y, z - 0.35), CHROME, "Metal",
            CanCollide=False, CanTouch=False, CanQuery=False,
        ))
    # The disc cylinder is rotated so its own X axis points front-to-back. Stack
    # along local X to keep multiple plates together on the hanging chain.
    pieces.extend(body_load_visuals(
        mul(cf(x, y - 1.45, z - 0.35), rot_y(90)), axis="x",
    ))
    return group("HeldWaist", pieces)


def hand_plate_load(x, y, z):
    """A compact plate held against the chest during loaded trunk work."""
    pieces = body_load_visuals(cf(x, y, z), axis="x")
    held = group("HeldBoth", pieces)
    held["attributes"] = {"GripStyle": "ChestPlate"}
    return held


def back_plate_load(x, y, z):
    """Flat plates that ride securely on the upper back for push-ups and planks."""
    # After rot_y(90), local X is front-to-back through the torso. Keep every disc
    # in that local stack instead of merging it into one thick visual.
    pieces = body_load_visuals(mul(cf(x, y, z), rot_y(90)), axis="x")
    return group("HeldBack", pieces)


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
    out.extend(padded_slab("Base", [2.7, 0.55, 6.6],
                    cf(0, FLOOR_TOP + 1.58, 0.2), pad_color, caps=True))
    out.extend(padded_slab("HeadPad", [2.7, 0.35, 1.6],
                    cf(0, FLOOR_TOP + 1.75, -2.9), pad_color))

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
        anchor_supine((0, FLOOR_TOP + 2.85, 0.1)),
        level_bar(bar),
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
        pieces = [
            cylinder("IronHandle", 3.3, 0.26, cf(x, y, z), CHROME, "Metal",
                     Reflectance=0.3, CanCollide=False),
        ]
        for side in (-1, 1):
            pieces.append(cylinder(
                "Collar", 0.12, 0.48, cf(x + side * 0.58, y, z),
                CHROME, "Metal", Reflectance=0.25, CanCollide=False,
            ))

        # Each selector step owns a complete symmetric IWF-style configuration.
        # Runtime swaps configurations rather than accumulating fantasy discs.
        pieces.extend(olympic_load_visuals(cf(x, y, z), 3.3, 0.62))
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
        out.append(part(
            "BeltStorageHook", [0.35, 0.35, 1.8],
            cf(side * 1.9, FLOOR_TOP + 3.45, 1.15), CHROME, "Metal",
            CanCollide=False, CanTouch=False, CanQuery=False,
        ))
        # Hanging: feet well clear of the floor, facing out into the room. Height is
        # set so the hands meet the bar with the arms overhead and the chin clears it
        # at the top of the pull — the arms cannot stretch to find the bar on their
        # own, so the body has to hang at the right distance below it. The number is
        # measured: at 6.2 the closest the hands came all rep was 0.64 studs short.
        out.append(group("Spot", [
            marker("TrainAnchor", [2, 2, 1],
                   mul(cf(side * 1.9, FLOOR_TOP + 6.85, -0.71), rot_y(180))),
            waist_chain_load(side * 1.9, FLOOR_TOP + 3.0, 1.6),
        ]))
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
    out.extend(padded_slab("Base", [2.6, 0.5, 7.2], pad, pad_color, caps=True))

    # Rollers the lifter hooks their ankles under, at the low end.
    for offset in (-0.55, 0.55):
        out.append(cylinder("Roller", 2.4, 1.0,
                            mul(pad, cf(0, 0.95, -3.1 + offset * 1.1)),
                            RUBBER, "Pebble"))
    out.append(part("RollerPost", [0.35, 1.6, 0.35],
                    mul(pad, cf(0, 0.55, -3.1)), accent, "Metal"))

    # Reclined along the pad: rot_x(90) tips the body from standing onto its
    # back, so the head runs up the slope and the face points away from the pad.
    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1],
               mul(pad, mul(cf(0, 1.35, 0.3), rot_x(90)))),
        hand_plate_load(0, FLOOR_TOP + 1.25, -3.8),
    ]))
    out.append(marker("TrainExit", [2, 2, 1],
                      mul(cf(3.2, FLOOR_TOP + ROOT_HEIGHT, 0), rot_y(-90))))
    return out


def goblet_squat(pad_color, accent):
    """A starter squat platform with a plate carried at the chest."""
    out = [floor_mat(9, 10)]

    out.append(part("Base", [6.8, 0.45, 6.8],
                    cf(0, FLOOR_TOP + 0.23, 0), STEEL, "DiamondPlate"))
    out.append(part("LiftingMat", [5.8, 0.12, 5.8],
                    cf(0, FLOOR_TOP + 0.52, 0), pad_color, "Rubber"))
    # Toe guides give the pose a believable shoulder-width stance without blocking
    # the player. They also make the station readable from the promenade.
    for side in (-1, 1):
        out.append(part("FootGuide", [1.05, 0.08, 2.4],
                        mul(cf(side * 1.15, FLOOR_TOP + 0.61, 0.25), rot_y(side * 8)),
                        accent, "Neon", CanCollide=False))

    # A compact storage peg explains where the selected plate comes from. The ten
    # BodyPlate slices move onto the avatar's hands when training starts.
    out.append(part("PlateStand", [0.45, 2.4, 0.45],
                    cf(-3.3, FLOOR_TOP + 1.2, -2.8), STEEL, "Metal"))
    out.append(part("StandFoot", [2.1, 0.35, 1.4],
                    cf(-3.3, FLOOR_TOP + 0.18, -2.8), STEEL, "DiamondPlate"))
    out.append(cylinder("StoragePeg", 1.35, 0.3,
                        mul(cf(-3.3, FLOOR_TOP + 1.55, -2.45), rot_x(90)),
                        CHROME, "Metal", Reflectance=0.25))
    for index, radius in enumerate((2.05, 1.82, 1.60), start=1):
        out.append(cylinder(f"StoredPlate{index}", 0.22, radius,
                            mul(cf(-3.3, FLOOR_TOP + 1.55, -2.1 + index * 0.2), rot_x(90)),
                            [0.12, 0.13, 0.16], "Metal"))

    out.append(group("Spot", [
        anchor_standing(cf(0, FLOOR_TOP + 0.55, 0.25)),
        hand_plate_load(-3.3, FLOOR_TOP + 1.55, -1.3),
    ]))
    out.append(marker("TrainExit", [2, 2, 1],
                      cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.8)))
    return out


def incline_press(pad_color, accent):
    """Incline dumbbell press on a 32-degree adjustable bench."""
    out = [floor_mat(11, 13)]
    bench = mul(cf(0, FLOOR_TOP + 2.15, 0.5), rot_x(-32))
    out.extend([
        part("BenchSpine", [0.6, 0.5, 8.0], bench, STEEL, "DiamondPlate"),
        *padded_slab("Base", [3.2, 0.65, 5.2], bench, pad_color, caps=True),
        *padded_slab("SeatPad", [3.2, 0.65, 2.4],
             mul(cf(0, FLOOR_TOP + 1.45, 3.0), rot_x(8)), pad_color, caps=True),
        part("RearFoot", [4.4, 1.8, 0.55], cf(0, FLOOR_TOP + 0.9, -2.6), STEEL, "Metal"),
        part("FrontFoot", [4.4, 0.55, 1.8], cf(0, FLOOR_TOP + 0.28, 3.0), STEEL, "Metal"),
        part("AngleBrace", [0.55, 3.5, 0.55], cf(0, FLOOR_TOP + 1.75, -1.8), accent, "Metal"),
    ])

    # Standing on the floor either side of the bench, which is where a pair of
    # dumbbells lives between sets. They were authored at bench height and half a
    # stud clear of the frame, so they hovered beside the seat.
    # Head radius 0.75 sitting on the 0.12 mat.
    rest_y = FLOOR_TOP + 0.87

    def dumbbell(name, x):
        pieces = [cylinder("Handle", 1.5, 0.3, cf(x, rest_y, 1.0),
                           CHROME, "Metal", CanCollide=False, CanTouch=False,
                           CanQuery=False)]
        for side in (-1, 1):
            pieces.append(cylinder("Head", 0.72, 1.5,
                                   cf(x + side * 0.92, rest_y, 1.0),
                                   RUBBER, "Pebble", CanCollide=False,
                                   CanTouch=False, CanQuery=False))
        return group(name, pieces)

    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1],
               mul(bench, mul(cf(0, 1.25, 0.2), rot_x(90)))),
        dumbbell("HeldRight", -2.7),
        dumbbell("HeldLeft", 2.7),
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
        *padded_slab("Seat", [4.0, 0.6, 4.0], cf(0, FLOOR_TOP + 2.35, 1.8), pad_color, caps=True),
        *padded_slab("BackPad", [4.4, 6.0, 0.7], cf(0, FLOOR_TOP + 5.2, 3.4), pad_color),
        part("TopBeam", [11.0, 0.7, 0.8], cf(0, FLOOR_TOP + 9.0, 1.2), STEEL, "Metal"),
    ])
    for side in (-1, 1):
        out.extend([
            part("WeightTower", [2.0, 8.5, 2.4],
                 cf(side * 4.6, FLOOR_TOP + 4.25, 1.2), STEEL_LIGHT, "Metal"),
            *stack_shroud("Tower", (side * 4.6, FLOOR_TOP + 8.5, 1.2),
                          2.3, 8.5, 2.4, accent),
            # Hung from the top beam and angled inward so the lower end arrives
            # exactly where the hand grips it. The old sign swung the arm the other
            # way, so its free end travelled outward and finished two studs wide of
            # the grip it was supposed to be carrying.
            part("FlyArm", [0.55, 5.2, 0.55],
                 mul(cf(side * 4.09, FLOOR_TOP + 7.13, -0.2), rot_z(-side * 35)),
                 accent, "Metal"),
        ])

    # Where each arm's lower end lands: 2.6 out, 2.13 below the arm's centre.
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
        part("Cable", [0.12, 5.0, 0.12], cf(0, FLOOR_TOP + 7.0, 1.2), RUBBER,
             "SmoothPlastic", CanCollide=False, CanTouch=False, CanQuery=False),
    ])

    # The wheel the cable turns over, now in a housing bolted to the arm above it
    # rather than a bare cylinder floating at the end of the boom.
    out.extend(pulley("Pulley", (0, FLOOR_TOP + 9.4, 1.2), 1.7, accent,
                      axis_length=0.8, mount=(0, FLOOR_TOP + 10.1, 1.2)))
    out.extend(stack_shroud("Stack", (0, FLOOR_TOP + 8.0, -3.4), 4.1, 8.0, 2.5, accent))

    # Diagonal braces: a ten-stud mast on a five-stud base needs to look held up.
    for side in (-1, 1):
        out.append(tube("Brace", (side * 1.9, FLOOR_TOP + 0.65, -2.6),
                        (side * 0.3, FLOOR_TOP + 4.2, -2.1), 0.3, STEEL_LIGHT))
        out.append(hardware("MastBolt",
                            mul(cf(side * 0.42, FLOOR_TOP + 1.2, -2.0), rot_z(90))))
        out.append(foot_pad("Foot", cf(side * 2.0, FLOOR_TOP + 0.11, -4.6)))
        out.append(foot_pad("Foot", cf(side * 2.0, FLOOR_TOP + 0.11, -1.4)))
    out.append(tube("ArmStay", (0, FLOOR_TOP + 8.6, -1.9),
                    (0, FLOOR_TOP + 9.9, -0.2), 0.28, STEEL_LIGHT))

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
        *padded_slab("Seat", [4.2, 0.65, 4.0], cf(0, FLOOR_TOP + 2.1, 2.7), pad_color, caps=True),
        part("SeatPost", [1.0, 1.8, 1.0], cf(0, FLOOR_TOP + 0.9, 2.7), STEEL, "Metal"),
        part("WeightTower", [4.0, 7.5, 2.4], cf(0, FLOOR_TOP + 3.75, -4.4), STEEL_LIGHT, "Metal"),
        *stack_shroud("Tower", (0, FLOOR_TOP + 7.5, -4.4), 4.3, 7.5, 2.4, accent),
        part("TowerStripe", [4.2, 0.45, 2.6], cf(0, FLOOR_TOP + 6.3, -4.4), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.append(part("FootPlate", [3.0, 0.4, 3.4],
                        mul(cf(side * 2.1, FLOOR_TOP + 1.2, -0.7), rot_z(side * 28)),
                        STEEL, "DiamondPlate"))
    # A low outlet on the front of the stack, and the cable running forward from it
    # to the handle. A row's cable is near horizontal, which is the one case where
    # its absence is most obvious: the handle sat in mid-air over the foot plates.
    out.append(cylinder("Outlet", 0.8, 1.4, cf(0, FLOOR_TOP + 3.5, -3.2),
                        CHROME, "Metal"))
    out.append(_cable((0, FLOOR_TOP + 3.5, -3.2), (0, FLOOR_TOP + 3.5, -1.6)))
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
        *padded_slab("Seat", [4.0, 0.65, 4.0], cf(0, FLOOR_TOP + 2.1, 1.8), pad_color, caps=True),
        part("SeatPost", [1.0, 1.8, 1.0], cf(0, FLOOR_TOP + 0.9, 1.8), STEEL, "Metal"),
        cylinder("ThighRoller", 5.0, 1.0, cf(0, FLOOR_TOP + 3.5, 0.2), RUBBER, "Pebble"),
        part("TopCrossbar", [10.5, 0.8, 0.8], cf(0, FLOOR_TOP + 11.0, -1.5), STEEL, "Metal"),
    ])
    for side in (-1, 1):
        out.append(part("WeightTower", [2.1, 10.5, 2.3],
                        cf(side * 4.4, FLOOR_TOP + 5.25, -1.5), STEEL_LIGHT, "Metal"))
        out.extend(stack_shroud("Tower", (side * 4.4, FLOOR_TOP + 10.5, -1.5),
                                2.4, 10.5, 2.3, accent))
    # The bar hangs off the crossbar on a cable. Without one it floats under the
    # frame attached to nothing, and at 8.0 long its ends were buried inside the two
    # weight towers, whose inner faces are 3.35 out.
    bar_y = FLOOR_TOP + 9.5
    out.append(_cable((0, FLOOR_TOP + 11.0, -1.5), (0, bar_y, 0)))
    bar = [cylinder("LatBar", 6.4, 0.38, cf(0, bar_y, 0),
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
        *padded_slab("BackPad", [4.4, 5.5, 0.65], cf(0, FLOOR_TOP + 6.0, -2.45), pad_color),
        part("TopStripe", [6.2, 0.5, 1.0], cf(0, FLOOR_TOP + 9.7, -2.7), accent, "Neon"),
    ])
    for side in (-1, 1):
        out.extend([
            *padded_slab("ArmRest", [2.0, 0.65, 4.5],
                 cf(side * 2.7, FLOOR_TOP + 6.0, -0.2), pad_color),
            cylinder("Handle", 2.3, 0.42,
                     mul(cf(side * 2.7, FLOOR_TOP + 6.35, 1.2), rot_y(90)),
                     CHROME, "Metal"),
        ])
    out.append(group("Spot", [
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 5.4, -0.5)),
        waist_chain_load(0, FLOOR_TOP + 2.2, 2.4),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.2)))
    return out


def torso_twist(pad_color, accent):
    """Seated torso-rotation station with a medicine ball held in both hands."""
    out = [floor_mat(10, 10)]
    out.extend([
        # A pedestal with some height to it. The base was a 7-wide disc only 0.7
        # thick, and the machine's own mat covered its bottom 0.12 -- so barely half a
        # stud of the whole structure stood above the floor and the rig read as
        # something sunk into the pad rather than bolted onto it. Narrower and much
        # taller: the same footprint idea, but visible.
        # 0.7 thick, not thicker: the seated feet rest on the FootBrace at 2.01 and
        # this disc sits directly under them, so anything taller tops out inside them --
        # measured 0.78 studs of foot inside a 1.1-thick base. The height this machine
        # was missing comes from the column, the back rest and the raised gauge, none of
        # which are anywhere near the feet.
        cylinder("Base", 0.7, 5.0, mul(cf(0, FLOOR_TOP + 0.35, 0), rot_z(90)),
                 STEEL, "DiamondPlate"),
        # Narrow enough that the seated feet clear it. At 1.0 square the post's corner
        # caught the inside edge of each foot by 0.14 studs once the anchor came down to
        # the seated convention; the feet sit at x +/-0.86, so 0.7 gets out of the way.
        part("SeatPost", [0.9, 1.8, 0.9], cf(0, FLOOR_TOP + 0.9, 0), STEEL, "Metal"),
        # A back rest, so the seat reads as a rotation machine and not a stool. Behind
        # the sitter (they face -Z), clear of the seat top at 2.525.
    ])
    out.extend(padded_slab("BackRest", [4.4, 3.4, 0.7],
                           cf(0, FLOOR_TOP + 3.9, 2.1), pad_color))
    out.extend([
        part("BackPost", [0.8, 2.6, 0.8], cf(0, FLOOR_TOP + 2.4, 2.1), STEEL, "Metal"),
        # Set back behind the knees, same reason as the preacher bench: a 4.2-deep pad
        # centred on the sitter runs forward through the dangling legs and hides them.
    ])
    out.extend(padded_slab("Seat", [4.4, 0.65, 2.4],
                           cf(0, FLOOR_TOP + 2.2, 1.1), pad_color, caps=True))
    out.extend([
        # In front, where the feet actually land. The brace used to sit at z +2.3 --
        # behind the lifter, who faces -Z -- so it braced nothing.
        part("FootBrace", [7.0, 0.5, 2.4], cf(0, FLOOR_TOP + 0.55, -1.1), STEEL, "Metal"),
        # Lifted out of the mat. At 0.25 its underside sat at 1.075 against a mat top
        # of 1.12, so the gauge was partly buried in the floor it stands on. Also no
        # longer emissive, like the rest of the district trim.
        part("ArcGauge", [8.0, 0.5, 0.8], cf(0, FLOOR_TOP + 1.5, -3.0),
             accent, "SmoothPlastic"),
        part("ArcGaugePost", [0.6, 1.4, 0.6], cf(-3.4, FLOOR_TOP + 0.7, -3.0),
             STEEL, "Metal"),
        part("ArcGaugePost", [0.6, 1.4, 0.6], cf(3.4, FLOOR_TOP + 0.7, -3.0),
             STEEL, "Metal"),
    ])
    # A rotation machine that visibly rotates: a bearing collar at the top of the
    # post the seat turns on, kept under the 0.86 the seated feet sit at, and
    # graduations along the arc gauge so the sweep reads as measured.
    out.append(cylinder("BearingCollar", 0.32, 1.5,
                        mul(cf(0, FLOOR_TOP + 1.72, 0), rot_x(90)), CHROME, "Metal",
                        Reflectance=0.3))
    for side in (-1, 1):
        out.append(tube("GaugePost", (side * 3.4, FLOOR_TOP + 0.12, -3.0),
                        (side * 3.4, FLOOR_TOP + 1.4, -3.0), 0.5, STEEL))
        out.append(tube("BackBrace", (side * 1.6, FLOOR_TOP + 2.5, 2.45),
                        (side * 0.3, FLOOR_TOP + 1.5, 2.1), 0.28, STEEL_LIGHT))
        out.append(hardware("SeatBolt",
                            mul(cf(side * 0.5, FLOOR_TOP + 1.9, 0), rot_z(90))))
        out.append(foot_pad("Foot", cf(side * 2.0, FLOOR_TOP + 0.11, 0),
                            (1.1, 0.22, 1.1)))
    for tick in (-3.2, -1.6, 0.0, 1.6, 3.2):
        out.append(part("GaugeTick", [0.16, 0.62, 0.9],
                        cf(tick, FLOOR_TOP + 1.6, -3.0), STEEL_LIGHT,
                        "SmoothPlastic", CanCollide=False))

    # On the mat in front of the machine — radius 1.1 on the 0.12 mat. It used to
    # be parked at chest height over the seat, floating just above the pad the
    # player sits on.
    ball = [part("MedicineBall", [2.2, 2.2, 2.2], cf(0, FLOOR_TOP + 1.22, -3.2),
                 accent, "Rubber", Shape="Ball", CanCollide=False,
                 CanTouch=False, CanQuery=False)]
    out.append(group("Spot", [
        # Seat tops at FLOOR_TOP + 2.525, and every other seated rig puts the root
        # 0.775 above its seat -- PecDeck, SeatedRow, LatPulldown and LegExtension all
        # measure between 0.75 and 0.78. This one was at 1.825, more than a stud higher
        # than the convention, and raising it is what broke it: the pose folds the legs
        # straight down (hip 70 / knee -82), so from a root that high the feet finish at
        # 3.06 -- wedged between the top of the SeatPost at 3.02 and the underside of
        # the Seat at 3.095, which is the "stuck in the ground" that was reported.
        #
        # Measured on the rig, the feet hang 2.29 below the root in this pose. Putting
        # the root on the standard 0.775 lands them at 2.01, right on the FootBrace,
        # and satisfies both constraints at once.
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.30, 0)),
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
    # J-hooks. The cage had four posts at z = +/-3.8 and nothing at all at z = 0,
    # so the loaded bar hung in the middle of the cage touching none of it. Each
    # hook cantilevers forward off a back post to meet the bar where it rests.
    bar_y = FLOOR_TOP + 6.3
    for side in (-1, 1):
        out.append(part("HookArm", [0.4, 0.4, 3.4],
                        cf(side * 4.4, bar_y - 0.5, -1.9), STEEL, "Metal"))
        out.append(part("RackHook", [0.42, 1.1, 0.42],
                        cf(side * 4.4, bar_y - 0.1, -0.3), accent, "Metal"))
    bar = [cylinder("Bar", 9.4, 0.34, cf(0, bar_y, 0),
                    CHROME, "Metal", CanCollide=False, CanTouch=False,
                    CanQuery=False)]
    # Inboard of the J-hooks at 4.4, so the plates load the sleeve rather than
    # clipping through the hook the bar is resting in.
    for side in (-1, 1):
        for offset in (2.9, 3.5):
            bar.append(cylinder("Plate", 0.55, 2.0,
                                cf(side * offset, bar_y, 0),
                                RUBBER, "Pebble", CanCollide=False,
                                CanTouch=False, CanQuery=False))
    out.append(group("Spot", [
        # On the base plate. Standing at floor level put the feet 0.46 studs inside
        # the plate the rack is built on.
        anchor_standing(cf(0, FLOOR_TOP + 0.46, 0.4)),
        level_bar(bar),
    ]))
    out.append(marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 6.1)))
    return out


def leg_press(pad_color, accent):
    """Reclined sled press; the avatar extends against a broad fixed footplate."""
    out = [floor_mat(12, 14)]
    seat_frame = mul(cf(0, FLOOR_TOP + 2.1, 2.4), rot_x(28))
    out.extend([
        part("Base", [7.0, 0.6, 11.0], cf(0, FLOOR_TOP + 0.3, 0), STEEL, "DiamondPlate"),
        *padded_slab("Seat", [5.0, 0.7, 4.0], seat_frame, pad_color, caps=True),
        *padded_slab("BackPad", [5.0, 0.7, 6.0],
             mul(cf(0, FLOOR_TOP + 3.8, 4.1), rot_x(58)), pad_color),
        part("FootPlate", [7.5, 0.65, 7.5],
             mul(cf(0, FLOOR_TOP + 5.0, -3.7), rot_x(-38)), STEEL_LIGHT, "DiamondPlate"),
        part("SledStripe", [7.7, 0.4, 1.0],
             mul(cf(0, FLOOR_TOP + 5.4, -3.2), rot_x(-38)), accent, "Neon"),
        part("WeightStack", [2.2, 7.0, 2.4],
             cf(-4.7, FLOOR_TOP + 3.5, 2.2), STEEL_LIGHT, "Metal"),
        *stack_shroud("Stack", (-4.7, FLOOR_TOP + 7.0, 2.2), 2.5, 7.0, 2.4, accent),
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


def _held_bar(name, length, y, z, accent, diameter=0.38, x=0.0,
              grip_style=None):
    """A collision-free two-hand prop whose long axis is local X.

    The x offset exists because a prop has to be authored where the machine
    actually keeps it, and on a two-sided machine that is not the centreline: a
    crossover grip belongs at the end of its own cable, a rope handle at the end of
    its own rope.
    """
    held = group(name, [cylinder(
        "Grip", length, diameter, cf(x, y, z), accent, "Metal",
        CanCollide=False, CanTouch=False, CanQuery=False,
    )])
    if grip_style is not None:
        held["attributes"] = {"GripStyle": grip_style}
    return held


def _cable(start, end, thickness=0.12, name="Cable"):
    """A taut cable drawn between two points.

    A selectorised machine's handle is held up by a cable, and without one drawn
    the handle simply hangs in the air with nothing above it — which is what a
    player reads as a broken machine. The part's local Y is laid along the run, so
    its Size height is the distance between the two ends.
    """
    span = tuple(e - s for s, e in zip(start, end))
    length = math.sqrt(sum(v * v for v in span))
    if length < 1e-4:
        raise ValueError(f"{name}: cable needs two distinct ends")
    up = tuple(v / length for v in span)

    # Any vector not parallel to the run gives a usable right axis; a cable is
    # round, so which one it is never shows.
    seed = (1.0, 0.0, 0.0) if abs(up[0]) < 0.9 else (0.0, 0.0, 1.0)
    right = cross(seed, up)
    scale = math.sqrt(sum(v * v for v in right))
    right = tuple(v / scale for v in right)

    middle = tuple((s + e) / 2 for s, e in zip(start, end))
    return part(name, [thickness, length, thickness], axes(middle, right, up),
                RUBBER, "SmoothPlastic",
                CanCollide=False, CanTouch=False, CanQuery=False)


def cable_run(points, thickness=0.12, name="Cable", sag=0.0, segments=1):
    """A cable routed through a list of points, optionally hanging between them.

    `_cable` draws one taut straight run, which is right for a handle held up
    directly above its stack. It is wrong for the long routed lines on a
    crossover or a pulldown, where the cable leaves the stack, turns over a
    wheel, and only then reaches the handle: drawn as a single straight part it
    cuts through the frame instead of following the machine.

    Sag is drawn rather than simulated — a parabola sampled at `segments` points,
    zero at both ends and deepest in the middle. A cable under load is very
    nearly taut, so the default is no sag at all; it is worth spending segments
    on only where slack actually shows, such as the loose end of a rope handle.
    """
    out = []
    for index in range(len(points) - 1):
        start, end = points[index], points[index + 1]
        if segments <= 1 or sag <= 0.0:
            out.append(_cable(start, end, thickness, name))
            continue
        previous = start
        for step in range(1, segments + 1):
            alpha = step / segments
            point = tuple(s + (e - s) * alpha for s, e in zip(start, end))
            # 4*a*(1-a) peaks at 1.0 mid-span and vanishes at both ends, which is
            # what keeps every segment meeting its neighbours exactly.
            drop = sag * 4.0 * alpha * (1.0 - alpha)
            point = (point[0], point[1] - drop, point[2])
            out.append(_cable(previous, point, thickness, name))
            previous = point
    return out


def push_up_deck(pad_color, accent):
    """Low weighted push-up platform with parallel hand blocks."""
    out = [floor_mat(11, 12)]
    out.extend([
        part("Base", [8.5, 0.65, 10.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Deck", [7.5, 0.3, 9.0], cf(0, FLOOR_TOP + 0.8, 0), pad_color, "Rubber"),
        cylinder("RightHandle", 2.2, 0.45, cf(-2.0, FLOOR_TOP + 1.25, -2.2), CHROME),
        cylinder("LeftHandle", 2.2, 0.45, cf(2.0, FLOOR_TOP + 1.25, -2.2), CHROME),
        part("WeightMarker", [5.0, 0.2, 0.7], cf(0, FLOOR_TOP + 1.0, 2.8), accent, "Neon"),
    ])

    # The handles were parallel bars resting on nothing: their undersides sit at
    # 1.025 and the deck tops out at 0.95. Uprights at each end close that gap and
    # turn them into push-up bars rather than floating pipes.
    for side in (-1, 1):
        for end in (-1, 1):
            out.append(tube("HandleLeg", (side * 2.0 + end * 0.95, FLOOR_TOP + 0.95, -2.2),
                            (side * 2.0 + end * 0.95, FLOOR_TOP + 1.25, -2.2),
                            0.34, CHROME, Reflectance=0.3))
        out.append(cylinder("HandleCap", 0.14, 0.5,
                            cf(side * 2.0, FLOOR_TOP + 1.25, -3.3), accent, "Metal"))
        out.append(cylinder("HandleCap", 0.14, 0.5,
                            cf(side * 2.0, FLOOR_TOP + 1.25, -1.1), accent, "Metal"))

    # Deck edging, so the rubber reads as a bonded surface and not a loose sheet.
    for side in (-1, 1):
        out.append(cylinder("DeckEdge", 9.0, 0.36,
                            mul(cf(side * 3.75, FLOOR_TOP + 0.9, 0), rot_y(90)),
                            STEEL_LIGHT, "Metal"))
        out.append(foot_pad("Foot", cf(side * 3.7, FLOOR_TOP + 0.11, -4.4)))
        out.append(foot_pad("Foot", cf(side * 3.7, FLOOR_TOP + 0.11, 4.4)))
        out.append(hardware("DeckBolt", mul(cf(side * 3.2, FLOOR_TOP + 0.96, 3.9), rot_x(90))))
        out.append(hardware("DeckBolt", mul(cf(side * 3.2, FLOOR_TOP + 0.96, -3.9), rot_x(90))))

    out.extend([
        group("Spot", [
            anchor_prone((0, FLOOR_TOP + 2.5, 0.5)),
            back_plate_load(0, FLOOR_TOP + 1.25, 3.4),
        ]),
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
            *stack_shroud("Tower", (side * 5.2, FLOOR_TOP + 10.5, -1.5),
                          2.7, 10.5, 3.0, accent),
            part("PulleyArm", [4.2, 0.65, 0.65], cf(side * 3.7, FLOOR_TOP + 9.8, -1.5),
                 STEEL, "Metal"),
            part("Cable", [0.1, 6.0, 0.1], cf(side * 2.0, FLOOR_TOP + 6.7, -1.5),
                 RUBBER, "SmoothPlastic", CanCollide=False),
        ])
    # Grip rest positions, at the two cable ends. They used to be authored on the
    # centreline and offset in z instead, which put both grips in the middle of the
    # machine with the cables ending two studs away on either side of them.
    grip_y = FLOOR_TOP + 3.9
    out.extend([
        part("Base", [12.8, 0.55, 5.0], cf(0, FLOOR_TOP + 0.28, -1.5), STEEL, "DiamondPlate"),
        part("CrossBeam", [12.0, 0.65, 0.65], cf(0, FLOOR_TOP + 10.3, -1.5), accent, "Metal"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 2.0)),
            _held_bar("HeldRight", 1.2, grip_y, -1.5, CHROME, x=-2.0),
            _held_bar("HeldLeft", 1.2, grip_y, -1.5, CHROME, x=2.0),
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
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 5.1, -0.2)),
            waist_chain_load(0, FLOOR_TOP + 2.2, 2.5),
        ]),
        marker("TrainExit", [2, 2, 1], cf(0, FLOOR_TOP + ROOT_HEIGHT, 4.2)),
    ])
    return out


def decline_press(pad_color, accent):
    """Head-low decline bench with a carried loaded bar."""
    out = [floor_mat(11, 13)]
    pad = mul(cf(0, FLOOR_TOP + 2.1, 0), rot_x(18))
    out.extend([
        *padded_slab("Base", [3.2, 0.6, 8.2], pad, pad_color, caps=True),
        part("Frame", [0.7, 1.0, 9.0], cf(0, FLOOR_TOP + 0.7, 0), STEEL, "DiamondPlate"),
        cylinder("AnkleRoller", 4.0, 1.1, cf(0, FLOOR_TOP + 3.7, 3.6), RUBBER, "Pebble"),
        part("Rack", [8.5, 6.0, 0.7], cf(0, FLOOR_TOP + 3.0, -4.1), STEEL, "Metal"),
        part("RackStripe", [8.7, 0.4, 0.9], cf(0, FLOOR_TOP + 5.8, -4.1), accent, "Neon"),
    ])
    # Hook arms cantilevered forward off the rack wall, the same way bench_press
    # does it: the bar has to rest where the hands press it, and the rack stands
    # 3.1 studs behind that, so without the arms the bar floated over the lifter.
    bar_y = FLOOR_TOP + 4.7
    for side in (-1, 1):
        out.append(part("HookArm", [0.3, 0.3, 2.8],
                        cf(side * 1.9, bar_y - 0.45, -2.6), STEEL, "Metal"))
        out.append(part("RackHook", [0.32, 0.9, 0.32],
                        cf(side * 1.9, bar_y - 0.05, -1.3), accent, "Metal"))
    out.extend([
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], mul(pad, mul(cf(0, 1.35, 0), rot_x(90)))),
            _held_bar("HeldBoth", 7.5, bar_y, -1.0, CHROME, grip_style="LevelBar"),
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
        # A shelf to actually put the dumbbells on. The rack was a flat wall, and
        # the pair floated in front of it with a stud and a half of air underneath.
        part("Shelf", [8.0, 0.3, 1.8], cf(0, FLOOR_TOP + 2.6, -2.6),
             STEEL, "DiamondPlate"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 1.0)),
            # Neutral grip: the dumbbell shaft runs front-to-back through the fist,
            # not left-to-right like a supinated curl.
            _held_bar("HeldRight", 1.6, FLOOR_TOP + 3.08, -2.6, CHROME, 0.65,
                      x=-1.2, grip_style="Neutral"),
            _held_bar("HeldLeft", 1.6, FLOOR_TOP + 3.08, -2.6, CHROME, 0.65,
                      x=1.2, grip_style="Neutral"),
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
        # Shallow, set back behind the knee line, and low enough to sit on. A 3.5-deep
        # pad reached forward under the legs and, being 4 wide, hid them from any side
        # view; at 2.2 high it also sat a seated lifter's feet 0.9 studs off the floor.
        # Seat top lands at 2.78 so the pelvis rests on it with the soles on the mat.
        *padded_slab("Seat", [4.0, 0.65, 2.2], cf(0, FLOOR_TOP + 1.455, 3.4), pad_color, caps=True),
        *padded_slab("PreacherPad", [5.6, 0.8, 4.6], pad, pad_color),
        part("PadPost", [0.8, 4.0, 0.8], cf(0, FLOOR_TOP + 2.0, -0.4), STEEL, "Metal"),
        part("Cradle", [6.0, 0.4, 1.0], cf(0, FLOOR_TOP + 2.1, -3.1), accent, "Metal"),
        group("Spot", [
            # Sized from the seated fold: the soles hang 2.43 below the root, so this
            # puts them on the 1.12 mat and the pelvis on the 2.78 seat at the same
            # time. The old 4.3 left the lifter hovering a full stud above the pad.
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 2.55, 2.55)),
            _held_bar("HeldBoth", 5.5, FLOOR_TOP + 2.6, -2.5, CHROME, grip_style="LevelBar"),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out


def skull_crusher(pad_color, accent):
    """Flat triceps bench with a short EZ bar above the forehead."""
    out = [floor_mat(10, 12)]
    out.extend([
        *padded_slab("Base", [3.3, 0.65, 8.0], cf(0, FLOOR_TOP + 1.7, 0), pad_color, caps=True),
        part("BenchFrame", [0.7, 1.2, 9.0], cf(0, FLOOR_TOP + 0.7, 0), STEEL, "DiamondPlate"),
        part("BarStand", [7.0, 4.8, 0.6], cf(0, FLOOR_TOP + 2.4, -4.0), STEEL, "Metal"),
        part("WarningStripe", [7.2, 0.4, 0.8], cf(0, FLOOR_TOP + 4.6, -4.0), accent, "Neon"),
    ])
    # Same cantilever as bench_press and decline_press: the EZ bar is racked over
    # the forehead, 2.8 studs clear of the stand behind it.
    bar_y = FLOOR_TOP + 4.2
    for side in (-1, 1):
        out.append(part("HookArm", [0.3, 0.3, 2.6],
                        cf(side * 1.6, bar_y - 0.45, -2.6), STEEL, "Metal"))
        out.append(part("RackHook", [0.32, 0.9, 0.32],
                        cf(side * 1.6, bar_y - 0.05, -1.4), accent, "Metal"))
    out.extend([
        group("Spot", [
            anchor_supine((0, FLOOR_TOP + 2.9, 0)),
            _held_bar("HeldBoth", 5.8, bar_y, -1.2, CHROME, grip_style="LevelBar"),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 1.5)),
    ])
    return out


def battle_ropes(pad_color, accent):
    """Two long ropes anchored to a weighted floor post."""
    out = [floor_mat(14, 14)]
    out.extend([
        # A wall anchor with real mass, not a lone post. What stood here before was a
        # 1.2-square post and a 0.8-thick disc, and with the ropes only 0.3 thick and
        # half a stud off the mat there was nothing on this pad taller than a kerb --
        # the whole station read as markings painted on the floor rather than as
        # equipment somebody had put there.
        part("Base", [7.0, 0.8, 3.0], cf(0, FLOOR_TOP + 0.4, -5.0),
             STEEL, "DiamondPlate"),
        part("AnchorFrame", [6.0, 5.5, 1.0], cf(0, FLOOR_TOP + 3.55, -5.4),
             STEEL, "Metal"),
        part("AnchorCap", [7.0, 0.9, 2.0], cf(0, FLOOR_TOP + 6.6, -5.0),
             accent, "Metal"),
        cylinder("AnchorRoller", 6.4, 0.9, cf(0, FLOOR_TOP + 4.9, -4.6),
                 CHROME, "Metal", Reflectance=0.25),
        part("AnchorLeg", [1.0, 2.6, 3.4], cf(-3.0, FLOOR_TOP + 1.3, -4.6),
             STEEL, "Metal"),
        part("AnchorLeg", [1.0, 2.6, 3.4], cf(3.0, FLOOR_TOP + 1.3, -4.6),
             STEEL, "Metal"),
        group("Spot", [
            anchor_standing(cf(0, FLOOR_TOP, 4.0)),
            # Down at the loose end of each rope, one handle per rope. They used to
            # sit on the centreline at chest height, so a station nobody was using
            # showed two handles hanging in mid-air with the ropes lying a stud to
            # either side of them and never reaching.
            _held_bar("HeldRight", 1.2, FLOOR_TOP + 0.8, 3.3, accent, x=-1.0),
            _held_bar("HeldLeft", 1.2, FLOOR_TOP + 0.8, 3.3, accent, x=1.0),
        ]),
        marker("TrainExit", [2, 2, 1], cf(5.5, FLOOR_TOP + ROOT_HEIGHT, 4.0)),
    ])
    # Short articulated segments are reshaped client-side between the fixed post
    # and each moving hand. Two rigid 8.5-stud bars could never make a rope wave and
    # visually pinned the player to the floor.
    segment_count = 12
    for side_name, x in (("Right", -1.0), ("Left", 1.0)):
        start_z, end_z = -4.5, 3.3
        for index in range(1, segment_count + 1):
            t0 = (index - 1) / segment_count
            t1 = index / segment_count
            z0 = start_z + (end_z - start_z) * t0
            z1 = start_z + (end_z - start_z) * t1
            # Slung from the roller at 5.9 down to the handles at 1.8, sagging in the
            # middle. The old line ran flat at 0.72 with a 0.22 bump, i.e. along the
            # floor, which is why the ropes were invisible from standing height.
            y0 = FLOOR_TOP + 4.9 - 4.1 * t0 - math.sin(t0 * math.pi) * 0.85
            y1 = FLOOR_TOP + 4.9 - 4.1 * t1 - math.sin(t1 * math.pi) * 0.85
            segment = _cable(
                (x, y0, z0), (x, y1, z1), 0.55,
                f"BattleRope{side_name}{index:02d}",
            )
            segment["properties"]["Color"] = accent
            segment["properties"]["Material"] = "Fabric"
            segment["attributes"] = {
                "BattleRopeSide": side_name,
                "BattleRopeIndex": index,
                "BattleRopeCount": segment_count,
            }
            out.append(segment)
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
            # Down on the oak, which is where a deadlift starts and where the bar
            # is between sets. It was parked 0.55 clear of the platform.
            _held_bar("HeldBoth", 10.5, FLOOR_TOP + 1.25, -0.6, CHROME, 0.5,
                      grip_style="LevelBar"),
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
        *padded_slab("ChestPad", [4.0, 0.8, 3.5], mul(cf(0, FLOOR_TOP + 4.0, 2.2), rot_x(-35)),
             pad_color),
        part("PlateStop", [5.5, 2.0, 1.0], cf(0, FLOOR_TOP + 1.4, -4.6), accent, "Metal"),
        group("Spot", [
            # PoseConfig already hinges the root 31 degrees. Tilting the anchor too
            # doubled that lean and pushed the avatar through the chest pad/rail.
            anchor_standing(cf(0, FLOOR_TOP + 0.65, 3.35)),
            _held_bar("HeldBoth", 3.0, FLOOR_TOP + 2.2, -0.5, CHROME, grip_style="LevelBar"),
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
        part("Frame", [1.0, 5.5, 1.0], cf(0, FLOOR_TOP + 2.75, 0), STEEL, "Metal"),
        cylinder("AnkleRoller", 5.0, 1.1, cf(0, FLOOR_TOP + 1.5, 4.0), RUBBER, "Pebble"),
        part("AngleMarker", [5.5, 0.35, 0.8], cf(0, FLOOR_TOP + 5.4, -1.5), accent, "Neon"),
    ])
    # The hip pad is the one surface bearing the lifter's weight, on the measured
    # 45-degree slope the anchor is derived from — same frame, rolled edge.
    out.extend(padded_slab("HipPad", [5.0, 1.0, 3.0], slope, pad_color, caps=True))

    for side in (-1, 1):
        # A second roller: ankles go between two pads on a Roman chair, and the
        # lower one is what actually stops the lifter sliding out.
        out.append(cylinder("RollerCap", 0.18, 1.15,
                            cf(side * 2.5, FLOOR_TOP + 1.5, 4.0), accent, "Metal"))
        out.append(tube("RollerPost", (side * 1.5, FLOOR_TOP + 0.6, 4.0),
                        (side * 1.5, FLOOR_TOP + 1.5, 4.0), 0.34, STEEL_LIGHT))
        out.append(tube("FootPlate", (side * 1.4, FLOOR_TOP + 0.9, 4.9),
                        (side * 1.4, FLOOR_TOP + 1.9, 5.1), 0.5, STEEL))
        out.append(tube("MastBrace", (side * 1.6, FLOOR_TOP + 0.6, 0.9),
                        (side * 0.35, FLOOR_TOP + 4.2, 0.2), 0.3, STEEL_LIGHT))
        out.append(hardware("PadBolt",
                            mul(cf(side * 0.55, FLOOR_TOP + 4.6, -0.6), rot_z(90))))
        out.append(foot_pad("Foot", cf(side * 2.9, FLOOR_TOP + 0.11, -4.4)))
        out.append(foot_pad("Foot", cf(side * 2.9, FLOOR_TOP + 0.11, 4.4)))
    # Height collar: a Roman chair adjusts, and the pin is what says so.
    out.append(cylinder("HeightCollar", 0.55, 1.35,
                        mul(cf(0, FLOOR_TOP + 1.6, 0), rot_x(90)), STEEL_LIGHT, "Metal"))
    out.append(hardware("HeightPin", cf(0.75, FLOOR_TOP + 1.6, 0), 0.3, 0.5, accent))

    out.extend([
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], mul(slope, mul(cf(0, 1.1, 0), rot_x(90)))),
            hand_plate_load(0, FLOOR_TOP + 1.3, -3.8),
        ]),
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
        # Hung 1.0 stud behind the anchor rather than straight through it. The
        # arms reach overhead in the sagittal plane, because the shoulder cannot
        # abduct far enough past 150 to bring a hand onto the body's own centreline
        # — so the rope goes where the hands are, which is also how a rope is
        # actually climbed.
        cylinder("ClimbRope", 12.0, 0.55, mul(cf(0, FLOOR_TOP + 7.0, -1.0), rot_z(90)),
                 RUBBER, "Fabric", CanCollide=False),
        group("Spot", [
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 7.0, 0)),
            waist_chain_load(0, FLOOR_TOP + 2.2, 2.6),
        ]),
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
    ])

    # An arch, not a signboard. It was one 4.5-tall slab standing on the mat with
    # no legs; a plank timer is a gantry you look up into from the floor.
    out.append(part("TimerBeam", [8.0, 0.8, 0.6], cf(0, FLOOR_TOP + 4.15, -5.0),
                    STEEL, "Metal"))
    out.extend(console("Timer", cf(0, FLOOR_TOP + 3.1, -4.68), accent,
                       size=(3.4, 1.6, 0.3)))
    for side in (-1, 1):
        out.append(tube("TimerLeg", (side * 3.6, FLOOR_TOP + 0.65, -5.0),
                        (side * 3.6, FLOOR_TOP + 4.15, -5.0), 0.55, STEEL))
        out.append(hardware("TimerBolt",
                            mul(cf(side * 3.6, FLOOR_TOP + 0.95, -4.7), rot_x(90)), 0.34))
        # Deck edging and feet, matching the other floor-level stations.
        out.append(cylinder("MatEdge", 9.8, 0.34,
                            mul(cf(side * 3.4, FLOOR_TOP + 0.88, 0), rot_y(90)),
                            STEEL_LIGHT, "Metal"))
        out.append(foot_pad("Foot", cf(side * 3.4, FLOOR_TOP + 0.11, -4.9)))
        out.append(foot_pad("Foot", cf(side * 3.4, FLOOR_TOP + 0.11, 4.9)))
        out.append(part("LaneStripe", [0.25, 0.14, 9.4],
                        cf(side * 2.6, FLOOR_TOP + 0.95, 0), STEEL_LIGHT,
                        "SmoothPlastic", CanCollide=False))

    out.extend([
        group("Spot", [
            anchor_prone((0, FLOOR_TOP + 2.15, 0.5)),
            back_plate_load(0, FLOOR_TOP + 1.25, 3.6),
        ]),
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
        # The rope hangs off the pulley. Without this the attachment floats over the
        # kneeling pad with the tower three studs behind it.
        _cable((0, FLOOR_TOP + 9.3, -1.7), (0, FLOOR_TOP + 6.4, 0.2), 0.16),
    ])
    out.extend(padded_slab("KneePad", [5.0, 0.5, 4.0],
                           cf(0, FLOOR_TOP + 0.6, 2.4), pad_color, caps=True))
    out.extend(pulley("Head", (0, FLOOR_TOP + 9.3, -0.4), 1.5, accent,
                      axis_length=0.7, mount=(0, FLOOR_TOP + 9.5, -1.4)))
    out.extend(stack_shroud("Tower", (0, FLOOR_TOP + 10.0, -3.6), 4.3, 10.0, 2.8, accent))

    for side in (-1, 1):
        out.append(tube("TowerBrace", (side * 2.0, FLOOR_TOP + 0.7, -2.0),
                        (side * 0.5, FLOOR_TOP + 4.4, -2.4), 0.3, STEEL))
        out.append(hardware("TowerBolt",
                            mul(cf(side * 2.05, FLOOR_TOP + 1.4, -3.6), rot_z(90))))
        out.append(foot_pad("Foot", cf(side * 2.0, FLOOR_TOP + 0.11, -4.6)))
        out.append(foot_pad("Foot", cf(side * 2.0, FLOOR_TOP + 0.11, -1.4)))
        # A rail either side of the kneeling pad, to line the lifter up under the rope.
        out.append(tube("KneeRail", (side * 2.6, FLOOR_TOP + 0.85, 0.6),
                        (side * 2.6, FLOOR_TOP + 0.85, 4.2), 0.3, STEEL_LIGHT))

    out.extend([
        group("Spot", [
            # Kneeling height: the shins rest on the KneePad rather than the body
            # standing with its feet through the floor, which is what a pose with no
            # knee bend at a kneeling machine was doing.
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.35, 2.2)),
            _held_bar("HeldBoth", 2.5, FLOOR_TOP + 6.4, 0.2, RUBBER, 0.55, grip_style="LevelBar"),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.0, FLOOR_TOP + ROOT_HEIGHT, 2.5)),
    ])
    return out
def ab_wheel_runway(pad_color, accent):
    """Kneeling rollout lane with a carried ab wheel."""
    out = [floor_mat(9, 14)]
    # Rolling on the runway rather than half sunk through it: the runway tops out
    # at 0.925 and the wheel's radius is 1.1, so its axle belongs at 2.025.
    wheel_y = FLOOR_TOP + 2.025
    wheel = [
        cylinder("Wheel", 0.8, 2.2, mul(cf(0, wheel_y, -1.8), rot_y(90)),
                 RUBBER, "Rubber", CanCollide=False, CanTouch=False, CanQuery=False),
        cylinder("Handle", 4.2, 0.35, cf(0, wheel_y, -1.8), CHROME, "Metal",
                 CanCollide=False, CanTouch=False, CanQuery=False),
    ]
    out.extend([
        part("Base", [7.0, 0.65, 12.0], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        part("Runway", [5.5, 0.25, 10.8], cf(0, FLOOR_TOP + 0.8, 0), pad_color, "Rubber"),
        part("Finish", [5.7, 0.2, 0.7], cf(0, FLOOR_TOP + 1.0, -4.5), accent, "Neon"),
    ])

    # A lane, not a strip of paint: side rails to roll between, distance ticks to
    # roll toward, and a padded kneeling block at the near end to start from.
    for side in (-1, 1):
        out.append(tube("LaneRail", (side * 3.0, FLOOR_TOP + 1.05, -5.4),
                        (side * 3.0, FLOOR_TOP + 1.05, 5.4), 0.4, STEEL_LIGHT))
        for end in (-5.4, 5.4):
            out.append(tube("RailPost", (side * 3.0, FLOOR_TOP + 0.65, end),
                            (side * 3.0, FLOOR_TOP + 1.05, end), 0.42, STEEL))
        out.append(foot_pad("Foot", cf(side * 2.9, FLOOR_TOP + 0.11, -5.4)))
        out.append(foot_pad("Foot", cf(side * 2.9, FLOOR_TOP + 0.11, 5.4)))
        for end in (-5.4, 5.4):
            out.append(hardware("RailCap",
                                mul(cf(side * 3.0, FLOOR_TOP + 1.05, end), rot_x(90)), 0.46))
    for index, z in enumerate((-3.0, -1.5, 0.0, 1.5)):
        out.append(part("DistanceTick", [4.6 - index * 0.3, 0.14, 0.22],
                        cf(0, FLOOR_TOP + 0.95, z), STEEL_LIGHT, "SmoothPlastic",
                        CanCollide=False))
    out.extend(padded_slab("StartBlock", [4.6, 0.45, 2.2],
                           cf(0, FLOOR_TOP + 1.05, 4.2), pad_color))

    out.extend([
        group("Spot", [
            # Measured, not guessed: at FLOOR_TOP + 2.2 the kneeling shins finished
            # 1.53 studs under the runway they are supposed to be kneeling on.
            # Bracketed from there: the shins move stud for stud with this number,
            # 3.33 sinking them 0.39 in and 3.53 leaving 0.19.
            marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.72, 2.0)),
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
        # A pulley head on the tower, and the cable that actually holds the handle
        # up. The diagonal guide is a painted path marker, not structure, so before
        # this the handle hung on nothing.
        _cable((-3.0, FLOOR_TOP + 9.6, -1.6), (0, FLOOR_TOP + 7.2, -0.8)),
    ])
    out.extend(pulley("Head", (-3.0, FLOOR_TOP + 9.6, -1.6), 1.6, accent,
                      axis_length=0.9, mount=(-3.0, FLOOR_TOP + 9.6, -2.6)))
    out.extend(stack_shroud("Tower", (-3.0, FLOOR_TOP + 10.0, -3.0), 3.3, 10.0, 3.0, accent))

    # The mast is carried on braces now, and the painted guide runs between real
    # posts instead of hanging in the air at one end.
    for side in (-1, 1):
        out.append(tube("TowerBrace", (-3.0 + side * 1.9, FLOOR_TOP + 0.7, -1.5),
                        (-3.0 + side * 0.6, FLOOR_TOP + 4.4, -2.0), 0.3, STEEL))
        out.append(hardware("TowerBolt",
                            mul(cf(-3.0 + side * 1.55, FLOOR_TOP + 1.5, -3.0), rot_z(90))))
        out.append(foot_pad("Foot", cf(-3.0 + side * 1.9, FLOOR_TOP + 0.11, -4.1)))
        out.append(foot_pad("Foot", cf(-3.0 + side * 1.9, FLOOR_TOP + 0.11, -0.9)))
    out.append(tube("GuidePost", (0.9, FLOOR_TOP + 0.12, -0.1),
                    (0.9, FLOOR_TOP + 3.4, -0.1), 0.36, STEEL))
    out.append(tube("GuideTop", (-2.6, FLOOR_TOP + 9.3, -0.6),
                    (0.6, FLOOR_TOP + 7.6, -0.2), 0.3, STEEL_LIGHT))
    out.append(part("StancePad", [4.4, 0.16, 4.4], cf(1.5, FLOOR_TOP + 0.14, 1.8),
                    RUBBER, "Pebble", CanCollide=False))

    out.extend([
        group("Spot", [
            anchor_standing(cf(1.5, FLOOR_TOP, 1.8)),
            _held_bar("HeldBoth", 2.2, FLOOR_TOP + 7.2, -0.8, CHROME, grip_style="LevelBar"),
        ]),
        marker("TrainExit", [2, 2, 1], cf(4.8, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out
def leg_extension(pad_color, accent):
    """Seated quad extension with a front ankle roller."""
    out = [floor_mat(10, 11)]
    out.extend([
        part("Base", [7.5, 0.65, 8.5], cf(0, FLOOR_TOP + 0.33, 0), STEEL, "DiamondPlate"),
        cylinder("AnkleRoller", 5.5, 1.2, cf(0, FLOOR_TOP + 1.6, -2.2), RUBBER, "Pebble"),
        part("Pivot", [1.0, 4.0, 1.0], cf(0, FLOOR_TOP + 2.0, -0.5), accent, "Metal"),
        part("WeightStack", [2.2, 6.0, 2.4],
             cf(-3.3, FLOOR_TOP + 3.0, -2.8), STEEL_LIGHT, "Metal"),
    ])

    # The seat and back are what the lifter is actually touching, so they are the
    # two surfaces worth spending a rolled edge on.
    out.extend(padded_slab("Seat", [4.5, 0.7, 4.0],
                           cf(0, FLOOR_TOP + 2.4, 1.8), pad_color, caps=True))
    out.extend(padded_slab("BackPad", [4.5, 5.5, 0.7],
                           cf(0, FLOOR_TOP + 5.1, 3.4), pad_color))

    # Tubular frame. The seat used to float over its base with nothing carrying it.
    for side in (-1, 1):
        out.append(tube("SeatPost", (side * 1.8, FLOOR_TOP + 0.65, 1.8),
                        (side * 1.8, FLOOR_TOP + 2.1, 1.8), 0.34, STEEL_LIGHT))
        out.append(tube("BackPost", (side * 2.0, FLOOR_TOP + 0.65, 3.8),
                        (side * 2.0, FLOOR_TOP + 7.4, 3.8), 0.38, STEEL))
        out.append(tube("RollerArm", (side * 0.45, FLOOR_TOP + 3.6, -0.5),
                        (side * 0.45, FLOOR_TOP + 1.6, -2.2), 0.3, STEEL_LIGHT))
        out.append(hardware("PivotBolt",
                            mul(cf(side * 0.5, FLOOR_TOP + 3.6, -0.5), rot_z(90)), 0.4))
        out.append(cylinder("RollerCap", 0.2, 1.25,
                            cf(side * 2.75, FLOOR_TOP + 1.6, -2.2), accent, "Metal"))
    out.append(tube("BackBrace", (-2.0, FLOOR_TOP + 7.4, 3.8),
                    (2.0, FLOOR_TOP + 7.4, 3.8), 0.34, STEEL))

    # The stack now pulls on something: over the wheel, down to the lifting arm.
    out.extend(pulley("Lift", (-3.3, FLOOR_TOP + 7.0, -2.8), 1.1, accent,
                      mount=(-3.3, FLOOR_TOP + 6.3, -2.8)))
    out.extend(cable_run([(-3.3, FLOOR_TOP + 6.05, -2.8),
                          (-3.3, FLOOR_TOP + 7.0, -2.8),
                          (-0.5, FLOOR_TOP + 3.7, -0.5)]))
    out.extend(stack_shroud("Stack", (-3.3, FLOOR_TOP + 6.0, -2.8), 2.5, 6.0, 2.4, accent))

    for fx in (-3.4, 3.4):
        for fz in (-3.9, 3.9):
            out.append(foot_pad("Foot", cf(fx, FLOOR_TOP + 0.11, fz)))

    out.extend([
        marker("TrainAnchor", [2, 2, 1], cf(0, FLOOR_TOP + 3.5, 1.8)),
        marker("TrainExit", [2, 2, 1], cf(4.2, FLOOR_TOP + ROOT_HEIGHT, 2.6)),
    ])
    return out

def hamstring_curl(pad_color, accent):
    """Prone leg-curl bench with heel roller and selector stack."""
    out = [floor_mat(10, 13)]
    out.extend([
        part("Frame", [1.0, 1.5, 11.0], cf(0, FLOOR_TOP + 0.8, 0), STEEL, "DiamondPlate"),
        part("WeightStack", [3.5, 6.0, 2.5], cf(0, FLOOR_TOP + 3.0, -5.0), STEEL_LIGHT, "Metal"),
        cylinder("HeelRoller", 6.0, 1.25, cf(0, FLOOR_TOP + 2.8, 4.2), RUBBER, "Pebble"),
        part("StackStripe", [3.7, 0.4, 2.7], cf(0, FLOOR_TOP + 5.5, -5.0), accent, "Neon"),
    ])

    # The bench the lifter lies face-down on: the anchor sits at 2.9, so the pad
    # surface it rests against must stay exactly where it was.
    out.extend(padded_slab("Base", [4.8, 0.7, 10.0],
                           cf(0, FLOOR_TOP + 1.7, 0), pad_color, caps=True))

    for side in (-1, 1):
        out.append(tube("Leg", (side * 0.0, FLOOR_TOP + 0.06, side * 4.6),
                        (side * 0.0, FLOOR_TOP + 1.4, side * 4.6), 0.5, STEEL))
        out.append(tube("RollerArm", (side * 0.4, FLOOR_TOP + 1.5, 3.0),
                        (side * 0.4, FLOOR_TOP + 2.8, 4.2), 0.3, STEEL_LIGHT))
        out.append(cylinder("RollerCap", 0.2, 1.3,
                            cf(side * 3.0, FLOOR_TOP + 2.8, 4.2), accent, "Metal"))
        out.append(tube("ChestRail", (side * 1.9, FLOOR_TOP + 2.1, 2.6),
                        (side * 1.9, FLOOR_TOP + 2.1, 4.0), 0.28, CHROME))
        out.append(hardware("FrameBolt",
                            mul(cf(side * 0.55, FLOOR_TOP + 1.5, 2.4), rot_z(90))))

    out.extend(pulley("Lift", (0, FLOOR_TOP + 6.6, -5.0), 1.0, accent,
                      mount=(0, FLOOR_TOP + 6.0, -5.0)))
    out.extend(cable_run([(0, FLOOR_TOP + 6.05, -5.0),
                          (0, FLOOR_TOP + 6.6, -5.0),
                          (0, FLOOR_TOP + 2.1, -1.0),
                          (0.4, FLOOR_TOP + 2.6, 3.0)]))
    out.extend(stack_shroud("Stack", (0, FLOOR_TOP + 6.0, -5.0), 3.8, 6.0, 2.5, accent))

    for fz in (-5.2, 5.2):
        out.append(foot_pad("Foot", cf(0, FLOOR_TOP + 0.11, fz), (1.6, 0.22, 1.0)))

    out.extend([
        anchor_prone((0, FLOOR_TOP + 2.9, 0)),
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
        # A yoke, not a bar. One 5.5-wide pad across the middle at head height put the
        # avatar's head 0.61 studs inside it at the top of the raise -- measured. A real
        # calf-raise yoke is two pads that sit on the shoulders either side of the neck,
        # which is also the shape that leaves the head somewhere to be.
        part("TopStripe", [7.7, 0.4, 1.0], cf(0, FLOOR_TOP + 8.7, -3.0), accent, "Neon"),
        part("WeightStack", [2.2, 6.5, 2.4],
             cf(-3.0, FLOOR_TOP + 3.25, -2.2), STEEL_LIGHT, "Metal"),
    ])

    for side in (-1, 1):
        out.extend(padded_slab("ShoulderPads", [2.0, 0.8, 2.0],
                               cf(side * 1.9, FLOOR_TOP + 4.9, -0.2), pad_color))
        # The yoke the pads hang from, and the rails the lifter steadies against.
        out.append(tube("YokeArm", (side * 1.9, FLOOR_TOP + 4.9, -0.2),
                        (side * 1.9, FLOOR_TOP + 4.9, -2.6), 0.34, STEEL_LIGHT))
        out.append(tube("YokePost", (side * 1.9, FLOOR_TOP + 4.55, -2.6),
                        (side * 1.9, FLOOR_TOP + 7.6, -2.6), 0.36, STEEL_LIGHT))
        out.append(tube("GuideRail", (side * 3.4, FLOOR_TOP + 0.7, -2.6),
                        (side * 3.4, FLOOR_TOP + 8.4, -2.6), 0.4, CHROME,
                        Reflectance=0.3))
        out.append(tube("HandRail", (side * 2.6, FLOOR_TOP + 5.4, 0.6),
                        (side * 3.4, FLOOR_TOP + 5.4, -1.4), 0.3, CHROME,
                        Reflectance=0.3))
        out.append(hardware("YokeBolt",
                            mul(cf(side * 1.9, FLOOR_TOP + 4.9, -2.78), rot_x(90))))
        out.append(foot_pad("Foot", cf(side * 3.5, FLOOR_TOP + 0.11, -3.2)))
        out.append(foot_pad("Foot", cf(side * 3.5, FLOOR_TOP + 0.11, 3.2)))

    # Toe block edge: the one part of this machine the player's feet overhang.
    out.append(cylinder("ToeEdge", 6.0, 0.5,
                        mul(cf(0, FLOOR_TOP + 1.25, 2.75), rot_y(90)),
                        accent, "Rubber"))
    out.extend(pulley("Lift", (-3.0, FLOOR_TOP + 7.2, -2.2), 1.0, accent,
                      mount=(-3.0, FLOOR_TOP + 6.6, -2.2)))
    out.extend(cable_run([(-3.0, FLOOR_TOP + 6.55, -2.2),
                          (-3.0, FLOOR_TOP + 7.2, -2.2),
                          (-1.9, FLOOR_TOP + 7.6, -2.6)]))
    out.extend(stack_shroud("Stack", (-3.0, FLOOR_TOP + 6.5, -2.2), 2.5, 6.5, 2.4, accent))

    out.extend([
        anchor_standing(cf(0, FLOOR_TOP + 0.8, 0.3)),
        marker("TrainExit", [2, 2, 1], cf(4.3, FLOOR_TOP + ROOT_HEIGHT, 2.8)),
    ])
    return out

def stair_climber(pad_color, accent):
    """Compact rotating stair machine with hand rails and console."""
    out = [floor_mat(10, 12)]
    out.extend([
        part("Base", [7.0, 0.7, 10.0], cf(0, FLOOR_TOP + 0.35, 0), STEEL, "DiamondPlate"),
        # Pedals, not a staircase. Three solid blocks up to 2.2 tall stood exactly where
        # the climbing stride swings its shins through -- measured 0.75 studs of shin
        # inside StepHigh -- because a static staircase has no way to get out of the way
        # of a leg. A stair machine has two thin pedals that rise and fall, and thin is
        # the part that matters here: the feet land at 2.21 and 2.95 above the mat in
        # this pose, so the pedals go there and the shins pass over nothing.
        part("PedalLow", [5.5, 0.35, 2.6], cf(0, FLOOR_TOP + 2.21, 1.2), pad_color, "Rubber"),
        part("PedalHigh", [5.5, 0.35, 2.6], cf(0, FLOOR_TOP + 2.95, -1.4), pad_color, "Rubber"),
        part("PedalArmLow", [0.4, 0.4, 4.0], cf(-2.4, FLOOR_TOP + 2.0, 0.4), STEEL, "Metal"),
        part("PedalArmHigh", [0.4, 0.4, 4.0], cf(2.4, FLOOR_TOP + 2.74, -0.2), STEEL, "Metal"),
        cylinder("Handlebar", 6.0, 0.45, cf(0, FLOOR_TOP + 5.0, -2.8), CHROME),
    ])

    # A console with a bezel and a screen that throws light, in place of the flat
    # Neon slab that used to stand in for one.
    out.append(part("Console", [5.0, 4.0, 1.0], cf(0, FLOOR_TOP + 6.0, -4.0),
                    STEEL_LIGHT, "Metal"))
    out.extend(console("Readout", mul(cf(0, FLOOR_TOP + 6.6, -3.45), rot_x(-8)),
                       accent, size=(4.2, 1.8, 0.25)))

    # The mast the console and rails are carried on, and the drive housing the
    # pedal arms disappear into at the back.
    for side in (-1, 1):
        out.append(tube("Mast", (side * 2.2, FLOOR_TOP + 0.7, -3.6),
                        (side * 2.2, FLOOR_TOP + 6.2, -3.6), 0.45, STEEL))
        out.append(tube("SideRail", (side * 2.6, FLOOR_TOP + 5.0, -2.8),
                        (side * 2.6, FLOOR_TOP + 5.0, 1.2), 0.4, CHROME,
                        Reflectance=0.3))
        out.append(tube("RailDrop", (side * 2.6, FLOOR_TOP + 5.0, 1.2),
                        (side * 2.6, FLOOR_TOP + 3.4, 2.0), 0.36, CHROME,
                        Reflectance=0.3))
        out.append(cylinder("PedalPivot", 0.6, 0.7,
                            cf(side * 2.4, FLOOR_TOP + 2.4, -2.2), accent, "Metal"))
        out.append(hardware("MastBolt",
                            mul(cf(side * 2.2, FLOOR_TOP + 0.95, -3.35), rot_x(90)), 0.36))
        out.append(foot_pad("Foot", cf(side * 3.0, FLOOR_TOP + 0.11, -4.4)))
        out.append(foot_pad("Foot", cf(side * 3.0, FLOOR_TOP + 0.11, 4.4)))

    out.append(part("DriveHousing", [6.4, 2.4, 2.2],
                    cf(0, FLOOR_TOP + 1.9, -3.6), STEEL, "DiamondPlate"))
    out.append(part("DriveVent", [5.2, 0.25, 0.14],
                    cf(0, FLOOR_TOP + 2.5, -2.48), accent, "Neon", CanCollide=False))
    for side in (-1, 1):
        out.append(cylinder("PedalTread", 0.12, 0.4,
                            mul(cf(side * 1.6, FLOOR_TOP + 2.4, 1.2), rot_z(90)),
                            RUBBER, "Rubber", CanCollide=False))
        out.append(cylinder("PedalTread", 0.12, 0.4,
                            mul(cf(side * 1.6, FLOOR_TOP + 3.14, -1.4), rot_z(90)),
                            RUBBER, "Rubber", CanCollide=False))

    out.extend([
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
    "GobletSquat": goblet_squat,
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

SAFE_ZONE_HALF = 34


def disc(name, thickness, diameter, y, color, material, **props):
    """A flat horizontal disc. Roblox cylinders run along local X, so a disc is
    a cylinder stood on its end."""
    return cylinder(name, thickness, diameter,
                    mul(cf(0, y, 0), rot_z(90)), color, material, **props)


def beacon(row, x, z, height):
    """A lit pylon. Islands are far apart and mostly seen against sky, so each
    one needs something that carries its colour at distance."""
    out = []
    out.append(part("Pylon", [4.5, height, 4.5],
                    cf(x, FLOOR_TOP + height / 2, z), STEEL, "DiamondPlate"))
    # A painted cap, not a lamp. These stand either side of the approach to a gym
    # now, and a brightness-3 point light with a 70-stud range at head height washed
    # out the entrance it was supposed to mark. The colour still identifies the
    # district; the glow was part of the "random lightning" look.
    out.append(part("Beacon", [6, 3, 6], cf(x, FLOOR_TOP + height + 1.5, z),
                    row["accent"], "SmoothPlastic", CanCollide=False))
    return out


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
            "Size": [round(v, 3) for v in size],
            "CFrame": serialise_cf(frame),
            "Material": "SmoothPlastic",
        },
    }, tags=["GymZone"], attributes={"ZoneId": zone_id})


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
    "Legs": ("GobletSquat", "SquatRack", "LegPress", "LegExtension",
             "HamstringCurl", "CalfRaise", "StairClimber"),
}
EQUIPMENT_FAMILY = {
    equipment_id: family
    for family, variants in STAT_VARIANTS.items()
    for equipment_id in variants
}


# The colour that says which muscle a machine trains, before its label streams in.
#
# It used to be architecture: an Arms cage, a Chest bay, a Back tower, a Core court,
# a Legs lane, each up to eighteen studs tall around the machine. Outdoors on a bare
# island that read as a landmark. Indoors, in a lit hall, it read as a pile of dark
# slabs — the canopy shaded the very machine you were walking to, and the pad beneath
# it was the same near-black as the floor, so the training area you were meant to
# stand on was invisible and the thing standing over it was all you could see.
#
# So the venue is now a floor pad and nothing else: a pale rubber mat, ringed in the
# muscle's colour. It contrasts against the floor, it names the muscle at a glance
# from any angle, and it does not stand between you and the machine.
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

# The mat surface itself, light enough to read against a dark gym floor.
VENUE_PAD_COLOR = [0.58, 0.58, 0.60]

# How far the mat stands proud of the floor it is laid on. Every machine builder
# places its geometry against FLOOR_TOP, so a machine dropped straight onto a bay
# origin sinks by exactly this much: its own rubber mat vanishes inside the pad and
# the bottom of every leg, base ring and post goes with it. Machines are raised by it
# at placement time rather than each of the 35 builders being taught about the pad.
VENUE_PAD_RISE = 0.22


def training_venue(equipment_id, district_accent):
    """The floor a machine stands on, in its muscle's colour. Two parts, no walls.

    The border is a slightly larger plate underneath rather than four separate
    strips: one part instead of four, and nothing to misalign at the corners.
    """
    family = EQUIPMENT_FAMILY[equipment_id]
    color = FAMILY_COLORS[family]
    out = [
        part("VenueEdge", [30, 0.16, 30], cf(0, FLOOR_TOP + 0.08, 0),
             color, "SmoothPlastic", CanCollide=False),
        # Tops out at exactly FLOOR_TOP + VENUE_PAD_RISE, which is the height every
        # machine is raised onto. Changing this means changing that constant.
        part("VenuePad", [26.5, 0.22, 26.5], cf(0, FLOOR_TOP + 0.11, 0),
             VENUE_PAD_COLOR, "Pebble", CanCollide=False),
    ]

    if family == "Legs":
        # The one exception, because a running machine reads as one: two painted lane
        # lines running past the mat. Flat markings, not structure.
        for x in (-5, 5):
            out.append(part("LaneLine", [0.35, 0.12, 42], cf(x, FLOOR_TOP + 0.30, 5),
                            color, "SmoothPlastic", CanCollide=False, CastShadow=False))

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


def city_tree(x, z, rng):
    """A compact street/park tree made from original primitive geometry."""
    height = rng.uniform(18, 27)
    out = [cylinder(
        "TreeTrunk", height, 2.0,
        mul(cf(x, FLOOR_TOP + height / 2, z), rot_z(90)),
        [0.27, 0.20, 0.14], "Wood", CanCollide=False,
    )]
    for ox, oy, oz, scale in ((0, 0, 0, 1), (-4, -1, 1, 0.72), (4, -2, -1, 0.68)):
        out.append(part(
            "TreeCanopy", [13 * scale, 10 * scale, 13 * scale],
            cf(x + ox, FLOOR_TOP + height + oy, z + oz),
            [0.12, rng.uniform(0.30, 0.39), 0.16], "Grass", Shape="Ball",
            CanCollide=False, CanTouch=False, CanQuery=False,
        ))
    return out


def coastal_public_realm():
    """Beach, boardwalk and seawall: the continuous public edge of the city."""
    out = []
    surface_columns = max(1, math.ceil(CITY_MAINLAND_SIZE[0] / 1800))
    city_min_x = CITY_MAINLAND_CENTER[0] - CITY_MAINLAND_SIZE[0] / 2
    city_max_x = CITY_MAINLAND_CENTER[0] + CITY_MAINLAND_SIZE[0] / 2
    # Visible sand stops before the seawall; the underlying mainland remains the
    # collision surface, so the thin finish can never trap a player at its edge.
    out.extend(place(cf(CITY_MAINLAND_CENTER[0], 0, 178), node)
               for node in tiled_surface(
                   "BeachSand", CITY_MAINLAND_SIZE[0], 344, 0.08,
                   FLOOR_TOP, [0.66, 0.57, 0.40], "Sand",
                   columns=surface_columns, rows=1, map_kind="Park", CanCollide=False,
               ))
    out.extend(place(cf(CITY_MAINLAND_CENTER[0], 0, 24), node)
               for node in tiled_surface(
                   "Boardwalk", CITY_MAINLAND_SIZE[0], 42, 0.12,
                   FLOOR_TOP + 0.02, [0.34, 0.25, 0.17], "WoodPlanks",
                   columns=surface_columns, rows=1, map_kind="Plaza", CanCollide=False,
               ))
    out.extend(city_road("CoastalBoulevard", CITY_MAINLAND_SIZE[0], 64,
                         CITY_MAINLAND_CENTER[0], -86))
    # No sea-facing rail. A 120-stud near-black bar repeated the length of the coast
    # read as a barrier cutting the promenade off from the beach rather than as trim,
    # and it sat directly across the benches.
    for x in range(int(city_min_x + 150), int(city_max_x - 140), 190):
        out.extend(street_light(x, -50, 180))
    return out


# --------------------------------------------------------------------------
# City props.
#
# Small, cheap, repeated pieces. One function per kind, registered in CITY_PROPS,
# so a new piece of scenery is a new function and a new dict key rather than an
# edit to whatever scatters them.
#
# Every function returns nodes in local space around the origin; the caller places
# them and decides what they collide with. These were written for an island world
# that no longer exists and were never placed anywhere -- they are moved here,
# ahead of that dead builder being deleted, because the shapes are sound and the
# city needs exactly this kit.
# --------------------------------------------------------------------------


def clutter_rock(rng, accent, ground):
    scale = rng.uniform(1.6, 4.2)
    return [part("Rock", [scale * 1.7, scale * 1.3, scale * 1.5],
                 mul(rot_y(rng.uniform(0, 360)),
                     cf(0, FLOOR_TOP + scale * 0.5, 0)),
                 [c * rng.uniform(0.72, 0.95) for c in ground], "Rock")]


def clutter_shrub(rng, accent, ground):
    height = rng.uniform(2.4, 4.6)
    green = [0.16 + rng.uniform(0, 0.09), 0.30 + rng.uniform(0, 0.14), 0.15]
    return [
        cylinder("ShrubStem", height, 0.5, cf(0, FLOOR_TOP + height / 2, 0),
                 [0.24, 0.17, 0.11], "Wood"),
        part("ShrubCanopy", [height * 1.1, height * 0.8, height * 1.1],
             mul(rot_y(rng.uniform(0, 360)), cf(0, FLOOR_TOP + height, 0)),
             green, "Grass"),
    ]


def clutter_grass(rng, accent, ground):
    out = []
    for _index in range(rng.randint(2, 4)):
        blade = rng.uniform(1.0, 2.2)
        out.append(part("GrassTuft", [rng.uniform(1.4, 2.6), blade, rng.uniform(1.4, 2.6)],
                        mul(rot_y(rng.uniform(0, 360)),
                            cf(rng.uniform(-3, 3), FLOOR_TOP + blade / 2, rng.uniform(-3, 3))),
                        [0.18, 0.28 + rng.uniform(0, 0.12), 0.14], "Grass"))
    return out


def clutter_crate(rng, accent, ground):
    out = []
    for level in range(rng.randint(1, 3)):
        side = rng.uniform(3.0, 4.4)
        out.append(part("Crate", [side, side, side],
                        mul(rot_y(rng.uniform(0, 360)),
                            cf(rng.uniform(-1, 1), FLOOR_TOP + side * (level + 0.5),
                               rng.uniform(-1, 1))),
                        [c * rng.uniform(0.85, 1.15) for c in WOOD], "WoodPlanks"))
    return out


def clutter_barrel(rng, accent, ground):
    height = rng.uniform(3.2, 4.2)
    return [cylinder("Barrel", height, rng.uniform(2.4, 3.2),
                     cf(0, FLOOR_TOP + height / 2, 0),
                     rng.choice([[0.42, 0.16, 0.12], [0.16, 0.28, 0.34],
                                 [0.36, 0.34, 0.14]]), "CorrodedMetal")]


def clutter_lamp(rng, accent, ground):
    height = rng.uniform(14, 20)
    return [
        cylinder("LampPost", height, 0.9, cf(0, FLOOR_TOP + height / 2, 0),
                 [0.14, 0.15, 0.17], "Metal"),
        part("LampHead", [2.6, 1.0, 2.6], cf(0, FLOOR_TOP + height, 0),
             accent, "Neon"),
    ]


def clutter_sign(rng, accent, ground):
    height = rng.uniform(8, 13)
    return [
        cylinder("SignPost", height, 0.7, cf(0, FLOOR_TOP + height / 2, 0),
                 [0.17, 0.18, 0.20], "Metal"),
        # Not "SignBoard": gym_hall's own signage owns that name, and collision here
        # is decided by name, so a scenery part that shares one with a structural
        # part cannot be told apart from it.
        part("SignPanel", [rng.uniform(5, 8), rng.uniform(2.4, 3.6), 0.4],
             mul(rot_y(rng.uniform(0, 360)), cf(0, FLOOR_TOP + height, 0)),
             accent, "SmoothPlastic"),
    ]


def clutter_pillar(rng, accent, ground):
    height = rng.uniform(9, 18)
    return [part("Pillar", [rng.uniform(2.4, 4.0), height, rng.uniform(2.4, 4.0)],
                 mul(rot_y(rng.uniform(0, 360)), cf(0, FLOOR_TOP + height / 2, 0)),
                 [c * 0.85 for c in ground], "Slate")]


def clutter_palm(rng, accent, ground):
    height = rng.uniform(16, 24)
    lean = rng.uniform(-9, 9)
    out = [cylinder("PalmTrunk", height, 1.5,
                    mul(rot_z(lean), cf(0, FLOOR_TOP + height / 2, 0)),
                    [0.34, 0.25, 0.16], "Wood")]
    for index in range(6):
        out.append(part("PalmFrond", [11, 0.5, 2.6],
                        mul(mul(rot_y(index * 60 + rng.uniform(-10, 10)),
                                cf(5, FLOOR_TOP + height, 0)), rot_z(-16)),
                        [0.18, 0.36, 0.18], "Grass"))
    return out


def clutter_debris(rng, accent, ground):
    out = []
    for _index in range(rng.randint(2, 5)):
        out.append(part("Debris", [rng.uniform(2, 5), rng.uniform(0.4, 1.1), rng.uniform(2, 5)],
                        mul(rot_y(rng.uniform(0, 360)),
                            cf(rng.uniform(-4, 4), FLOOR_TOP + 0.4, rng.uniform(-4, 4))),
                        [c * rng.uniform(0.6, 0.9) for c in ground], "Rock"))
    return out


# Scenery that keeps its collision because its shape is cover: waist-to-chest,
# compact footprint, sitting flat on the ground with nothing overhanging. These are
# the only non-structural parts in the world you can hide behind, and a punch is
# range 12, so a 4-stud crate is enough to break a line.
#
# Names, not kinds, because _decorate walks parts: clutter_shrub returns a stem and
# a canopy and neither is cover, while clutter_crate returns one to three stacked
# Crate parts and all of them are. Anything not named here is stripped exactly as
# before, which is every landmark prop in PROPS and every thin or overhanging piece.
# The mixed-use city authors cover deliberately as architecture.  Random clutter is
# decorative and non-colliding; in particular, Rock/Boulder props are intentionally
# absent so machines no longer look as though a stone was dropped beside every mat.
SOLID_CITY_PROPS = frozenset()

CITY_PROPS = {
    "rock": clutter_rock,
    "shrub": clutter_shrub,
    "grass": clutter_grass,
    "crate": clutter_crate,
    "barrel": clutter_barrel,
    "lamp": clutter_lamp,
    "sign": clutter_sign,
    "pillar": clutter_pillar,
    "palm": clutter_palm,
    "debris": clutter_debris,
}


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


# --------------------------------------------------------------------------
# What stands in the plaza.
#
# The plaza is the only safe ground in the game and the only place travel is
# free, so it is where everybody ends up. That makes it the right place for the
# two things the player needs a person or an object for: quests and standings.
# Both are inert geometry here — a tag and an id — and the client controllers
# in #75 and #76 give them behaviour.
# --------------------------------------------------------------------------

# The surface benches, the coach and the leaderboard stand on: the plaza itself.
#
# This said FLOOR_TOP + 0.8 and had done for a long time, which is nothing the plaza has
# ever been — the disc tops out at FLOOR_TOP, plus the hair SURFACE_LIFT adds to keep it
# off the ground beneath. Everything positioned against it has therefore been hovering
# 0.72 studs in the air, which is small enough to look like a rendering quirk and large
# enough to see once you stand next to a bench.
PLAZA_TOP = FLOOR_TOP + SURFACE_LIFT

SKIN = [0.76, 0.58, 0.44]
TRACKSUIT = [0.13, 0.14, 0.17]


def facing_centre(x, z):
    """Degrees of yaw that turn an object's +Z front toward the origin."""
    return math.degrees(math.atan2(x, z)) + 180


# The quest giver's ring. A flat disc on the floor, in the colour of the marker the
# HUD uses for objectives, so "this is the person with the quests" is legible from
# across the concourse without a nameplate being readable yet.
QUEST_RING_COLOR = [1.0, 0.80, 0.22]
COACH_GI = [0.93, 0.93, 0.90]
COACH_TROUSERS = [0.13, 0.13, 0.15]
COACH_HAIR = [0.88, 0.88, 0.86]


def npc(name, npc_id, x, z, accent, style="tracksuit", ring_color=None):
    """A part-built figure. R6 proportions, no rig and no animation — it stands
    there and holds a ProximityPrompt, which is all a quest giver has to do.

    Two styles, because the two roles have to be told apart at a glance: the
    shopkeeper is a tracksuit-and-cap staffer, and the coach is the one in the pale
    gi who hands out the objectives. Both are the same seven parts in different
    colours -- a second silhouette would be a second thing to keep in sync.
    """
    torso = COACH_GI if style == "coach" else TRACKSUIT
    legs = COACH_TROUSERS if style == "coach" else TRACKSUIT
    frame = mul(cf(x, 0, z), rot_y(facing_centre(x, z)))
    body = [
        part("LeftLeg", [1.0, 2.8, 1.0], cf(-0.6, PLAZA_TOP + 1.4, 0), legs, "Fabric"),
        part("RightLeg", [1.0, 2.8, 1.0], cf(0.6, PLAZA_TOP + 1.4, 0), legs, "Fabric"),
        # Named Base to match the station contract, so anything looking for an
        # object's anchor part finds the same name everywhere in the world.
        part("Base", [2.3, 2.8, 1.3], cf(0, PLAZA_TOP + 4.2, 0), torso, "Fabric"),
        part("Stripe", [2.4, 0.5, 1.35], cf(0, PLAZA_TOP + 4.6, 0), accent, "Neon",
             CanCollide=False),
        part("LeftArm", [0.9, 2.6, 0.9], cf(-1.6, PLAZA_TOP + 4.2, 0), torso, "Fabric"),
        part("RightArm", [0.9, 2.6, 0.9], cf(1.6, PLAZA_TOP + 4.2, 0), torso, "Fabric"),
        part("Head", [1.5, 1.5, 1.5], cf(0, PLAZA_TOP + 6.4, 0), SKIN, "SmoothPlastic"),
    ]

    if style == "coach":
        body.append(part("Hair", [1.7, 0.7, 1.7], cf(0, PLAZA_TOP + 7.35, 0),
                         COACH_HAIR, "Fabric", CanCollide=False))
    else:
        body.extend([
            part("Cap", [1.7, 0.6, 1.7], cf(0, PLAZA_TOP + 7.3, 0), accent, "Fabric"),
            part("CapPeak", [1.6, 0.25, 0.9], cf(0, PLAZA_TOP + 7.1, 1.1), accent, "Fabric",
                 CanCollide=False),
        ])

    if ring_color is not None:
        # Sits a hair above the floor so it never z-fights the campus slab, and is
        # non-collidable so it is a marking rather than a kerb to trip on.
        # rot_z(90) stands the cylinder's local-X axis up, which is what turns it from
        # a log lying on the floor into a disc painted on it.
        body.append(cylinder("QuestRing", 0.08, 11,
                             mul(cf(0, PLAZA_TOP + 0.06, 0), rot_z(90)),
                             ring_color, "Neon",
                             CanCollide=False, CastShadow=False))

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
    """The standings, and something to sit on.

    The coach used to stand here, which meant the only quest giver in the game was at
    spawn: once a player travelled out to a multiplier tier, picking up the next
    objective meant a round trip home. campus_shell now puts one on every campus,
    including this one, so plaza_furniture no longer places its own.
    """
    out = []

    # Two monuments, because LeaderboardService defines two boards. A third
    # board would be a third entry here and nothing else.
    out.append(leaderboard_monument("StrongestBoard", "Power", -23, 18, [1.0, 0.77, 0.24]))
    out.append(leaderboard_monument("KnockoutsBoard", "Kills", 23, 18, [1.0, 0.36, 0.36]))

    out.extend(bench(-20, -2))
    out.extend(bench(20, -2))
    return out


# --------------------------------------------------------------------------
# Scattered training archipelago.
#
# The original district geometry remains above as a record of the island pass
# and as a library of props/builders. Shipping now uses a bridge-free field of
# distant islands over walkable water. One island is one multiplier tier: the
# island you can see across the water IS the x8 gym, and you go there when your
# Power lets you train in it. The map UI reveals every location; physically
# reaching its doorway remains the exploration layer.
# --------------------------------------------------------------------------

MAP_FEATURE_TAG = "MapFeature"

# The world is an irregular archipelago rather than a rectangular grid or ring.
# A region IS a progression tier, and its theme names the zone standing on it, so
# there is exactly one island per non-starter zone and the five muscles of that
# tier are the five bays of its one gym. The large hidden foundation is only a
# fall catcher; visible land is six unrelated island silhouettes.
WORLD_FOUNDATION_SIZE = (10000, 9000)
WORLD_WATER_SIZE = (9600, 8600)
WATER_SURFACE_Y = FLOOR_TOP - 8.5

# The altitude Storm — the top tier — floats at. It has no shore steps, so the
# only way onto it is to fly, which is what keeps flight worth levelling Legs for
# now that no individual machine is flight-gated.
STORM_ALTITUDE = 300

# --------------------------------------------------------------------------
# One mainland, and a promenade along its coast.
#
# The archipelago is gone. A player who has to swim between tiers spends the
# session travelling, and an island you cannot see the next island from teaches
# nothing about where to go next. Now there is a single beach, one paved path
# running along it, and the tiers strung out down that path in order: the x2 yard
# is the one you can see from spawn, and the x64 slab is the shape in the sky at
# the far end. Progression is "keep walking", which needs no map to understand.
# --------------------------------------------------------------------------

# The promenade runs along world z = 0 in +X, starting at the spawn plaza at the
# world origin. The island is offset so that lands where it should: the plaza sits
# near the western end, and the sea is on the +Z side of the path the whole way.
PROMENADE_Z = 0
# Beach between the seaward fence and the water, so the yards look out over sand.
BEACH_DEPTH = 350

MAINLAND_SIZE = (5200, 2600)
MAINLAND_CENTER = (2200, -(MAINLAND_SIZE[1] / 2 - BEACH_DEPTH))

MAINLAND = {
    "id": "Mainland",
    # Which DISTRICTS row supplies the palette and the prop kit. The whole coast is
    # one beach, so it reads from the sand district rather than from a tier.
    "visual": "Strongman",
    "clutter": "coast",
    # Island-local x of each flight of shore steps: one near the spawn end of the
    # promenade, one near the far end.
    "shore_offsets": (-1800, 1200),
    "size": MAINLAND_SIZE,
    "shape": "Rect",
    "count": 9,
    "center": MAINLAND_CENTER,
    "yaw": 0,
    "altitude": 0,
    "flight_only": False,
}


# How far apart consecutive tier yards stand along the promenade. Far enough that
# arriving somewhere is an event and that a fight at one yard does not spill into
# the next, close enough that the following tier is always visible down the path.
TIER_AREA_SPACING = 600
TIER_AREA_FIRST_X = 600

# One area per non-starter tier, in order, walking east. Storm is the exception:
# its yard is a slab in the air over the end of the promenade, with no ramp and no
# stairs, so the last tier is the one thing on the coast you have to fly to.
TIER_AREAS = [
    {"zone": "Iron", "altitude": 0, "flight_only": False},
    {"zone": "Powerhouse", "altitude": 0, "flight_only": False},
    {"zone": "Strongman", "altitude": 0, "flight_only": False},
    {"zone": "Titan", "altitude": 0, "flight_only": False},
    {"zone": "Skydeck", "altitude": 0, "flight_only": False},
    {"zone": "Storm", "altitude": STORM_ALTITUDE, "flight_only": True},
]


def tier_areas():
    """Each tier's yard placed down the promenade, nearest tier first."""
    out = []
    for index, spec in enumerate(TIER_AREAS):
        area = dict(spec)
        area["id"] = f"Area{spec['zone']}"
        area["x"] = TIER_AREA_FIRST_X + index * TIER_AREA_SPACING
        area["frame"] = cf(area["x"], area["altitude"], PROMENADE_Z)
        out.append(area)
    return out


AREAS = tier_areas()


# --------------------------------------------------------------------------
# One gym per island.
#
# Every island used to scatter three small shells — a warehouse here, a fenced
# yard three hundred studs away — with a machine hidden under each. Flying in,
# that reads as an island with some sheds on it: the thing the game is about was
# the least visible thing on the ground.
#
# Now each island is a single enclosed gym hall, and its five machines are five
# bays inside it — one per muscle, one whole multiplier tier under one roof. The
# access ladder moved up a level with them: a machine is not flight-gated by
# sitting up a shaft, it is flight-gated by standing on an island that flies.
# --------------------------------------------------------------------------


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


def persistent_model(name, children, attributes=None):
    """Small always-streamed collision model used for global traversal surfaces."""
    return {
        "name": name,
        "className": "Model",
        "attributes": dict(attributes or {}),
        "properties": {"ModelStreamingMode": "Persistent"},
        "children": children,
    }


def shore_access(frame, edge, accent):
    """Ten shallow steps let walkers climb from the water onto one island."""
    out = []
    low_base = WATER_SURFACE_Y - 0.5
    rise = FLOOR_TOP - WATER_SURFACE_Y
    for index in range(10):
        top = WATER_SURFACE_Y + rise * (index + 1) / 10
        height = top - low_base
        local = cf(0, low_base + height / 2, edge + 38 - index * 4)
        out.append(place(frame, part(
            f"ShoreStep_{index + 1:02d}", [22, height, 5], local,
            [0.29, 0.30, 0.31], "Concrete",
        )))
    out.append(place(frame, map_footprint(
        "ShoreAccessMap", 22, 44,
        cf(0, WATER_SURFACE_Y + 0.15, edge + 20), accent, "Park",
    )))
    return out


def world_boundary():
    """Persistent physical perimeter that cannot be outrun by fast flight."""
    width, depth = WORLD_WATER_SIZE
    center_x, center_z = WORLD_CENTER
    wall_height = 2048
    wall_y = WATER_SURFACE_Y + wall_height / 2 - 32
    x_segments = max(1, math.ceil(width / 1800))
    z_segments = max(1, math.ceil(depth / 1800))
    out = []
    for side in (-1, 1):
        for segment in range(z_segments):
            z = center_z - depth / 2 + depth / z_segments * (segment + 0.5)
            out.append(part(
                f"BoundaryX_{side}_{segment + 1}",
                [12, wall_height, depth / z_segments + 4],
                cf(center_x + side * width / 2, wall_y, z),
                [0.06, 0.10, 0.14], "ForceField",
                Transparency=1, CanTouch=False, CanQuery=False, CastShadow=False,
            ))
        for segment in range(x_segments):
            x = center_x - width / 2 + width / x_segments * (segment + 0.5)
            out.append(part(
                f"BoundaryZ_{side}_{segment + 1}",
                [width / x_segments + 4, wall_height, 12],
                cf(x, wall_y, center_z + side * depth / 2),
                [0.06, 0.10, 0.14], "ForceField",
                Transparency=1, CanTouch=False, CanQuery=False, CastShadow=False,
            ))
    return persistent_model("WorldBoundary", out, {
        "WorldBoundary": True,
        "CenterX": center_x,
        "CenterZ": center_z,
        "HalfWidth": width / 2,
        "HalfDepth": depth / 2,
        "XSegments": x_segments,
        "ZSegments": z_segments,
        "WaterSurfaceY": WATER_SURFACE_Y,
    })


def region_frame(region):
    """The frame every piece of an island hangs off, altitude included.

    Raising the island here rather than at each builder is what makes a flying
    island possible at all: ground, hall, bays, scenery and shore all compose off
    this one frame, so they go up together and every local Y stays measured from
    the island's own floor.
    """
    x, z = region["center"]
    return mul(cf(x, region["altitude"], z), rot_y(region["yaw"]))


# A real gym is lit like an office: broad flush panels in a pale ceiling, throwing
# even light everywhere, with no single fixture bright enough to stare at. That is
# the opposite of a thin saturated batten, which is a bright line in a black room
# and makes everything near it — a player especially — harder to see, not easier.
# These colours are deliberately mid-tone, not white. A Neon part renders at its
# colour's full value and the place runs Bloom on top, so a near-white panel face
# is not a bright light in the render — it is a blown-out white smear that takes
# the wall behind it with it. Pale surfaces compound it by bouncing the lot back.
CEILING_LIGHT = [0.76, 0.74, 0.69]
CEILING_LINER = [0.60, 0.59, 0.56]


def ceiling_panel(frame):
    """One flush ceiling panel: a wide soft face plus the light it stands for."""
    node = part("CeilingPanel", [34, 0.5, 26], frame, CEILING_LIGHT, "Neon",
                CanCollide=False, CanTouch=False, CanQuery=False, CastShadow=False)
    node["children"] = [{
        "name": "Light",
        "className": "SurfaceLight",
        "properties": {
            "Face": "Bottom",
            # Nine of these overlap in one hall, and the place already runs a
            # global Brightness of 2.5 with positive exposure compensation. Each
            # one only has to light the floor under itself.
            "Brightness": 0.9,
            "Range": 46,
            "Angle": 140,
            "Color": [1.0, 0.97, 0.92],
            "Shadows": False,
        },
    }]
    return node


# Furniture kinds, each returning parts in hall-local space around the point it is
# given. A new piece of gym furniture is a new function and a new HALL_FURNITURE
# entry — never an edit to hall_interior, which only decides where things stand.


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


def region_ground(region):
    """One non-uniform island whose top remains the shared ground Y=1."""
    visual = next(row for row in DISTRICTS if row["zone"] == region["visual"])
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
        # Tiled, not one slab: the mainland is 5,200 studs across and a BasePart
        # stops at 2,048. The tiles share edges exactly, so the seam is invisible
        # and the top face stays the shared FLOOR_TOP.
        columns = max(1, math.ceil(width / 1800))
        rows = max(1, math.ceil(depth / 1800))
        out.extend(place(frame, node) for node in tiled_surface(
            "DistrictGround", width, depth, 4, FLOOR_TOP - 2,
            visual["ground"], visual["ground_material"],
            columns=columns, rows=rows, map_kind="Land",
        ))
        out.extend(place(frame, node) for node in tiled_surface(
            "DistrictFoundation", width + 10, depth + 10, 5, FLOOR_TOP - 6.5,
            visual["rock"], visual["rock_material"],
            columns=columns, rows=rows, CanTouch=False, CanQuery=False,
        ))

        # Two rounded lobes break the silhouette of each rotated slab and make
        # actual coves/peninsulas on both the world and its plan map.
        lobe_diameter = min(depth * 0.48, 260)
        for side in (-1, 1):
            lobe_frame = mul(frame, cf(side * width * 0.43, 0, side * depth * 0.22))
            out.append(place(lobe_frame, disc(
                "DistrictLobe", 4, lobe_diameter,
                FLOOR_TOP - 2 + SURFACE_LIFT / 2,
                visual["ground"], visual["ground_material"],
            )))
            out.append(place(frame, map_footprint(
                "DistrictLobeMap", lobe_diameter, lobe_diameter,
                cf(side * width * 0.43, FLOOR_TOP + 0.1, side * depth * 0.22),
                visual["ground"], "Land", "Circle",
            )))
    shore_edge = min(width, depth) / 2 if region["shape"] == "Circle" else depth / 2
    # A five-thousand-stud coast needs more than one way up out of the sea, or a
    # player knocked into the water at the far end swims the length of the map to
    # get back on land. One flight of steps near each end of the promenade.
    for offset in region.get("shore_offsets", (0,)):
        out.extend(shore_access(
            mul(frame, cf(offset, 0, 0)), shore_edge, visual["accent"]
        ))
    return out


def _decorate(node):
    """Make a scenery node non-blocking, in place, and return it.

    Props exist to make each island look like a place. Most of them are not
    obstacles, and every one that collides is something to get snagged on while
    running a hundred studs between machines or flying between districts — a
    shipping container is 26 studs deep and a crane leg is 62 tall.

    The exceptions are named in SOLID_CITY_PROPS: crates, barrels, rocks and pillars
    keep their collision, because this is a PvP game and a fight on ground with
    nothing to break line of sight is two players standing still trading hits. Those
    four are short, compact and flush to the floor, so they read as cover rather than
    as the snag hazard this function exists to remove.

    Everything else keeps its shadows and its looks and simply stops being in the
    way.
    """
    properties = node.setdefault("properties", {})
    if "Size" in properties or "CFrame" in properties:
        # Both branches are written out rather than one being left to Roblox's
        # defaults. Rojo patches existing instances, so a property the payload does
        # not mention keeps whatever the instance already had — and every one of
        # these parts already exists in the place as non-colliding scenery. Stating
        # the solid case is what actually turns it back on. CanQuery matters as much
        # as CanCollide: cover that raycasts pass straight through is not cover.
        solid = node.get("name") in SOLID_CITY_PROPS
        properties["CanCollide"] = solid
        properties["CanTouch"] = solid
        properties["CanQuery"] = solid
    for child in node.get("children", []):
        _decorate(child)
    return node


def connected_ground():
    """Persistent water and fall catcher beneath the enlarged coastal city."""
    foundation_columns = max(1, math.ceil(WORLD_FOUNDATION_SIZE[0] / 1800))
    foundation_rows = max(1, math.ceil(WORLD_FOUNDATION_SIZE[1] / 1800))
    water_columns = max(1, math.ceil(WORLD_WATER_SIZE[0] / 1800))
    water_rows = max(1, math.ceil(WORLD_WATER_SIZE[1] / 1800))
    foundation = persistent_model("WorldFoundation", [
        place(cf(WORLD_CENTER[0], 0, WORLD_CENTER[1]), node)
        for node in tiled_surface(
        "FoundationTile", WORLD_FOUNDATION_SIZE[0], WORLD_FOUNDATION_SIZE[1],
        6, WATER_SURFACE_Y - 4, [0.055, 0.06, 0.07], "Rock",
        columns=foundation_columns, rows=foundation_rows,
        CanTouch=False, CanQuery=False,
    )], {
        "PlayableFoundation": True,
        "Purpose": "WorldBoundsAndFallCatcher",
        "FoundationCenterX": WORLD_CENTER[0],
        "FoundationCenterZ": WORLD_CENTER[1],
        "FoundationWidth": WORLD_FOUNDATION_SIZE[0],
        "FoundationDepth": WORLD_FOUNDATION_SIZE[1],
        "TileColumns": foundation_columns,
        "TileRows": foundation_rows,
    })
    water = persistent_model("WorldWater", [
        place(cf(WORLD_CENTER[0], 0, WORLD_CENTER[1]), node)
        for node in tiled_surface(
        "OceanTile", WORLD_WATER_SIZE[0], WORLD_WATER_SIZE[1],
        3, WATER_SURFACE_Y - 1.5, [0.08, 0.20, 0.27], "Glass",
        columns=water_columns, rows=water_rows, map_kind="Water", CanCollide=True,
        CanTouch=False, CanQuery=True, Transparency=0.18,
    )], {
        "WalkableWater": True,
        "WaterSurfaceY": WATER_SURFACE_Y,
        "CenterX": WORLD_CENTER[0],
        "CenterZ": WORLD_CENTER[1],
        "TileColumns": water_columns,
        "TileRows": water_rows,
    })
    # The hub no longer has an island of its own: spawn stands on the western end
    # of the mainland, at the head of the promenade. A separate disc here would
    # overlap the mainland's ground and share a top face with it, which z-fights.
    return [
        foundation,
        water,
        world_boundary(),
        environment_model("Hub", "Ground", []),
    ]


# --------------------------------------------------------------------------
# Coastal city layout.
#
# The coast-only yard pass above is kept as a reusable kit, but the shipping
# world is a mixed-use city.  The player starts at Muscle Beach, follows a
# continuous boardwalk and a simple street grid inland, and learns the multiplier
# ladder through six landmarks: park, boardwalk, docks, civic plaza, office gym,
# and a flight-only rooftop.  Each tier still owns all five muscles so geography
# remains an honest progression guide.
# --------------------------------------------------------------------------

# The previous 5,200 x 3,000 coast was only 15.6 million square studs.  This
# 16,000 x 9,000 mainland is 9.23 times that land area: close to the requested
# tenfold expansion without turning each axis into a tenfold, 100x-area world.
CITY_MAINLAND_SIZE = (16000, 9000)
CITY_MAINLAND_CENTER = (7600, -4200)

# Global traversal surfaces sit slightly outside the land and share its offset
# centre.  Every tile stays below Roblox's 2,048-stud BasePart limit.
WORLD_CENTER = (7600, -4000)
WORLD_FOUNDATION_SIZE = (18000, 12000)
WORLD_WATER_SIZE = (17600, 11600)

MAINLAND = {
    "id": "Mainland",
    "visual": "Iron",
    "size": CITY_MAINLAND_SIZE,
    "shape": "Rect",
    "center": CITY_MAINLAND_CENTER,
    "yaw": 0,
    "altitude": 0,
    "flight_only": False,
    "shore_offsets": (-6900, -2500, 2000, 6500),
}
REGIONS = [MAINLAND]
REGION_BY_ID = {MAINLAND["id"]: MAINLAND}


CITY_AREA_SPECS = (
    {
        "zone": "Iron", "sequence": 1, "venue_type": "Park",
        "display_name": "Civic Park Gym", "x": 1750, "z": -2250, "yaw": 12,
        "altitude": 0, "flight_only": False,
        "tagline": "Train beneath the trees in the public fitness garden.",
    },
    {
        "zone": "Powerhouse", "sequence": 2, "venue_type": "Beach",
        "display_name": "Boardwalk Barbell Club", "x": 3850, "z": 105, "yaw": -7,
        "altitude": 0, "flight_only": False,
        "tagline": "An open-air club between the boardwalk and the surf.",
    },
    {
        "zone": "Strongman", "sequence": 3, "venue_type": "Dock",
        "display_name": "Freight Yard Strength", "x": 6600, "z": -1050, "yaw": 9,
        "altitude": 0, "flight_only": False,
        "tagline": "Heavy steel in the working harbor district.",
    },
    {
        "zone": "Titan", "sequence": 4, "venue_type": "City",
        "display_name": "Titan Square", "x": 8650, "z": -4300, "yaw": -14,
        "altitude": 0, "flight_only": False,
        "tagline": "A floodlit performance plaza in the downtown blocks.",
    },
    {
        "zone": "Skydeck", "sequence": 5, "venue_type": "Office",
        "display_name": "Apex Office Gym", "x": 12050, "z": -2050, "yaw": 8,
        "altitude": 0, "flight_only": False,
        "tagline": "A glass-walled executive gym inside Apex Tower.",
    },
    {
        "zone": "Storm", "sequence": 6, "venue_type": "Sky",
        "display_name": "Stormline Rooftop", "x": 14500, "z": -6100, "yaw": 17,
        "altitude": STORM_ALTITUDE, "flight_only": True,
        "tagline": "The final rooftop platform; flight is the only way up.",
    },
)


def city_areas():
    out = []
    for spec in CITY_AREA_SPECS:
        area = dict(spec)
        area["id"] = f"Area{area['zone']}"
        area["frame"] = mul(
            cf(area["x"], area["altitude"], area["z"]),
            rot_y(area["yaw"]),
        )
        out.append(area)
    return out


AREAS = city_areas()

COPY_OFFSETS = (0,)
CITY_CAMPUS_WIDTH = 370
CITY_CAMPUS_DEPTH = 270


STARTER_CAMPUS_FRAME = mul(cf(0, 0, 150), rot_y(180))


# Streaming and file-split units. One environment per machine would be 35 models
# in the districts file and 35 streaming groups; one for the whole city would be a
# single 28,000-part model. Six geographic bands is the middle: enough that a
# player only ever holds a slice of the city, few enough that the tree stays
# readable.
SECTOR_COUNT = 6


def sector_for(x):
    """Which sector environment a point belongs to."""
    span = (CITY_MAX_X - CITY_MIN_X) / SECTOR_COUNT
    index = int((x - CITY_MIN_X) // span)
    return f"Sector{min(max(index, 0), SECTOR_COUNT - 1) + 1}"


# Stride used to walk the scattered sites when handing out tier/muscle pairs.
# Coprime with 30, so stepping by it visits every scattered site exactly once and
# lands each tier's five machines about six sites apart in distance from spawn.
# That is what keeps the tiers genuinely interleaved: no band of the map belongs
# to one multiplier, which is the point of scattering rather than zoning. The
# starter tier is not in this pool at all -- it rings the plaza.
SITE_STRIDE = 13


# A fight is somewhere you choose to walk to, so a hostile site must never land
# on a training court -- being anchored to a machine for minutes at a time is the
# one thing in this game that has to be safe.
HOSTILE_STATION_CLEARANCE = 320
MIN_HOSTILE_SEPARATION = 650


def scatter_hostile_sites(station_sites):
    """Seven mob fields and seven boss arenas, spread across the city.

    Drawn from the same ground pool as the machines and picked with the same
    farthest-point routine, so fighting grounds are destinations in their own
    right rather than a disc parked behind whatever campus owned them.
    """
    taken = list(station_sites)
    free = [
        candidate for candidate in site_candidates()
        if candidate["kind"] == "ground"
        and all(math.hypot(candidate["x"] - site["x"], candidate["z"] - site["z"])
                > HOSTILE_STATION_CLEARANCE for site in station_sites)
    ]
    # Spread against the stations as well as against each other: a boss arena
    # equidistant from two machines is more useful than one tucked in a corner.
    picked = _spread_pick(free, len(taken) + 14, taken)
    return picked[len(taken):]


def connected_locations():
    """Thirty-five machines, each its own destination somewhere in the city."""
    tier_rows = DISTRICTS[:7]
    # Nearest the spawn plaza first, which is the only ordering a player can
    # perceive, and the one the stride below is meant to interleave.
    scattered = sorted(scatter_sites(),
                       key=lambda site: math.hypot(site["x"], site["z"] - 150))
    ring = garage_ring_sites()

    pairs = [(row["zone"], family) for row in tier_rows for family in FAMILY_ORDER]
    out = []
    scattered_index, ring_index = 0, 0
    for zone, family in pairs:
        if zone == STARTER_ZONE:
            site = ring[ring_index]
            ring_index += 1
        else:
            site = scattered[(scattered_index * SITE_STRIDE) % len(scattered)]
            scattered_index += 1
        tier_index = next(i for i, row in enumerate(tier_rows) if row["zone"] == zone)
        equipment_id = STAT_VARIANTS[family][tier_index]

        # Roof sites lift the whole court by the height of the roof they stand on;
        # every builder places its geometry against FLOOR_TOP, so the offset goes
        # on the origin rather than into 35 builders.
        lift = site["top"] - FLOOR_TOP
        origin = mul(cf(site["x"], lift, site["z"]), rot_y(site.get("yaw", 0)))

        travel_id = f"{zone}-{family}"
        out.append({
            "id": travel_id,
            "zone": zone,
            "family": family,
            "slot": equipment_id,
            "equipment": equipment_id,
            "site_x": site["x"],
            "site_z": site["z"],
            "site_kind": site["kind"],
            "site_top": site["top"],
            "site_width": site["width"],
            "site_depth": site["depth"],
            "site_base_depth": site["base_depth"],
            "ground_origin": origin,
            "origin": origin,
            "style": "street",
            "seed": f"scattered-city-v1:{travel_id}",
            "starter": zone == "Garage",
            "landmark": False,
            "region_id": MAINLAND["id"],
            "environment_id": sector_for(site["x"]),
            "neighborhood": character_name_at(site["x"], site["z"]),
            "requires_flight": False,
            "altitude": 0,
            "location_name": f"{SITE_NAMES[family]} — {zone}",
            "location_tagline": SITE_TAGLINES[site["kind"]],
        })
    return out


SITE_NAMES = {
    "Chest": "Press Point",
    "Arms": "Curl Corner",
    "Back": "Pull Yard",
    "Core": "Core Deck",
    "Legs": "Squat Stand",
}

SITE_TAGLINES = {
    "ground": "A street-level training spot out in the city.",
    "roof": "A rooftop training spot; take the fire escape up.",
}


def character_name_at(x, z):
    """The neighbourhood label a site inherits from the architecture around it."""
    for name, character in CITY_CHARACTER.items():
        if character is character_at(x, z):
            return name
    return "City"


def city_road(name, width, depth, x, z, surface_offset=0.0):
    """A tiled asphalt road with a plan-map footprint and restrained markings."""
    columns = max(1, math.ceil(width / 1750))
    rows = max(1, math.ceil(depth / 1750))
    out = [
        place(cf(x, 0, z), node)
        for node in tiled_surface(
            name, width, depth, 0.16,
            FLOOR_TOP - 0.08 + SURFACE_LIFT + surface_offset,
            ROAD, "Asphalt", columns=columns, rows=rows, map_kind="Road",
            CanCollide=False, CastShadow=False,
        )
    ]
    # A road gets one long centre marking per legal-sized tile rather than hundreds
    # of dashes.  It remains legible at flight speed and stays within the part budget.
    if width >= depth:
        segment = width / columns
        for column in range(columns):
            px = x - width / 2 + segment * (column + 0.5)
            out.append(part(
                "RoadLine", [segment - 12, 0.08, 1.0],
                cf(px, FLOOR_TOP + 0.13 + surface_offset, z),
                ROAD_LINE, "SmoothPlastic",
                CanCollide=False, CastShadow=False,
            ))
    else:
        segment = depth / rows
        for row in range(rows):
            pz = z - depth / 2 + segment * (row + 0.5)
            out.append(part(
                "RoadLine", [1.0, 0.08, segment - 12],
                cf(x, FLOOR_TOP + 0.13 + surface_offset, pz),
                ROAD_LINE, "SmoothPlastic",
                CanCollide=False, CastShadow=False,
            ))
    return out


def crosswalk(x, z, across_x):
    out = []
    for offset in (-18, -9, 0, 9, 18):
        size = [5, 0.09, 26] if across_x else [26, 0.09, 5]
        frame = cf(x + (offset if across_x else 0), FLOOR_TOP + 0.16,
                   z + (0 if across_x else offset))
        out.append(part(
            "CrosswalkStripe", size, frame, [0.76, 0.76, 0.72], "SmoothPlastic",
            CanCollide=False, CastShadow=False,
        ))
    return out


# --------------------------------------------------------------------------
# City blocks.
#
# The street grid was already here; what was missing was anything standing in
# it. The old lattice put one building on each of 54 hand-picked centres, which
# on a ~1,650-stud pitch left seven to ten hundred studs of bare ground between
# every one of them -- the emptiness this whole pass exists to fix.
#
# A block is now derived from the roads themselves rather than from a separate
# table of centres, so a block can never drift out of alignment with the street
# it fronts: change a road and the blocks follow.
# --------------------------------------------------------------------------

# Half-widths of the two road classes, plus the gap between kerb and asphalt.
CROSSTOWN_HALF = 29
AVENUE_HALF = 27
KERB_SETBACK = 10

# Heights. Each surface gets its own band so nothing shares a top face with
# anything else -- coplanar surfaces z-fight, and validate_no_coplanar_floors
# exists because that shipped once already.
SIDEWALK_Y = FLOOR_TOP + 0.10
KERB_Y = FLOOR_TOP + 0.06
ALLEY_Y = FLOOR_TOP + 0.03

# The city's outer edge. Blocks are clipped to this so none runs off the
# mainland into the sea.
CITY_MIN_X, CITY_MAX_X = -200, 15500
CITY_MIN_Z, CITY_MAX_Z = -8600, -180


def _band_edges(centres, half, low, high):
    """The gaps between consecutive roads, as (near, far) pairs.

    Includes the two outer gaps -- between the map edge and the first road --
    which is where a third of the bare ground was: the old centre table simply
    stopped, leaving a margin hundreds of studs deep with nothing in it.
    """
    edges = []
    ordered = sorted(centres)
    bounds = [low] + [c for c in ordered] + [high]
    for index in range(len(bounds) - 1):
        near = bounds[index] + (half if index > 0 else 0)
        far = bounds[index + 1] - (half if index + 1 < len(bounds) - 1 else 0)
        if far - near >= 220:
            edges.append((near, far))
    return edges


def city_block_rects(crosstown_roads, upland_avenues):
    """Every rectangle the street grid encloses, as (x, z, width, depth).

    Derived from the road centrelines that already exist rather than authored
    separately, which is what guarantees a block fronts the street beside it.
    """
    rects = []
    for near_x, far_x in _band_edges(upland_avenues, AVENUE_HALF, CITY_MIN_X, CITY_MAX_X):
        for near_z, far_z in _band_edges(crosstown_roads, CROSSTOWN_HALF, CITY_MIN_Z, CITY_MAX_Z):
            rects.append((
                (near_x + far_x) / 2, (near_z + far_z) / 2,
                far_x - near_x, far_z - near_z,
            ))
    return rects


def block_seed(index):
    """A block's own generator, keyed on its index rather than its coordinates.

    Integers, not floats: seeding from an x/z centre would reshuffle every block
    in the city the first time a road moved by a stud.
    """
    return random.Random(f"city-v3:block:{index}")


def city_block_shell(rect, index, keep_out=(), catalogue=None):
    """The ground a block stands on: pavement, kerb, service alley, map footprint.

    Buildings arrive in a later pass; this is deliberately separable so the
    rectangles can be checked against the streets before anything expensive is
    placed on them.
    """
    x, z, width, depth = rect
    rng = block_seed(index)
    inner_w, inner_d = width - KERB_SETBACK * 2, depth - KERB_SETBACK * 2
    out = []

    def cleared(px, pz, reach):
        """Whether a piece stands clear of every campus keep-out."""
        return all(math.hypot(px - kx, pz - kz) >= radius + reach
                   for kx, kz, radius in keep_out)

    # The kerb is wider than the pavement and deliberately non-colliding: left
    # solid it is a few hundred ankle-height ledges across the city for a
    # sprinting player to catch on.
    out.append(part("Kerb", [inner_w + 5, 0.5, inner_d + 5], cf(x, KERB_Y, z),
                    [0.30, 0.30, 0.31], "Concrete", CanCollide=False,
                    CastShadow=False))
    out.append(part("Sidewalk", [inner_w, 0.6, inner_d], cf(x, SIDEWALK_Y, z),
                    SIDEWALK, "Concrete", CanCollide=False, CastShadow=False))

    # One service alley across the long axis of the bigger blocks, which is what
    # gives a block a back as well as a front.
    if max(inner_w, inner_d) >= 520:
        if inner_w >= inner_d:
            out.append(part("Alley", [22, 0.4, inner_d], cf(x + rng.uniform(-0.18, 0.18) * inner_w, ALLEY_Y, z),
                            ROAD, "Asphalt", CanCollide=False, CastShadow=False))
        else:
            out.append(part("Alley", [inner_w, 0.4, 22], cf(x, ALLEY_Y, z + rng.uniform(-0.18, 0.18) * inner_d),
                            ROAD, "Asphalt", CanCollide=False, CastShadow=False))

    # Exactly one map footprint per block. Per building would put thousands of
    # features on the wire; the minimap wants city blocks, not window ledges.
    out.append(map_footprint("CityBlockMap", width, depth,
                             cf(x, FLOOR_TOP + 0.12, z), SIDEWALK, "Block"))

    # The buildable interior, inset again so nothing overhangs the pavement.
    character = character_at(x, z)
    out.extend(street_furniture(x, z, inner_w, inner_d, index,
                                character["skins"][0]["trim"], SIDEWALK))

    # A yard costs a whole band when the band is shallow. The coastal strip is
    # barely 440 studs deep and is also the most-walked ground in the game -- the
    # promenade every player follows from one tier to the next -- so thin blocks
    # are built out rather than left to the usual mix, which was leaving stretches
    # of the seafront with a lamp post and nothing behind it.
    weights = character["weights"]
    if min(inner_w, inner_d) < 600:
        weights = tuple((kind, weight) for kind, weight in weights
                        if kind not in ("yard", "parking"))

    build_w, build_d = inner_w - 30, inner_d - 30
    if build_w > 90 and build_d > 90:
        for lot in subdivide(x, z, build_w, build_d, rng):
            kind = weighted_kind(weights, rng)
            # Tested per lot, not per block. A block is up to 1,650 studs across,
            # so measuring its own corner reach against a 300-stud campus radius
            # threw away the whole block -- three quarters of a million square
            # studs of city to protect one circle. That put the emptiness this
            # pass exists to remove straight back on the seafront, which is the
            # most-walked ground in the game. Drawing the roll either way keeps
            # the rest of the block identical whether a lot is dropped or not.
            if cleared(lot[0], lot[1], math.hypot(lot[2], lot[3]) / 2):
                out.extend(city_lot(lot, kind, character, rng, catalogue))
    return out


# Architectural character, keyed on the venue_type of the nearest campus. A city
# where every block is the same is a texture, not a place; this is what makes the
# walk from the park to the docks to the office towers read as going somewhere.
#
# Resolved by nearest campus with a blend band (see character_at), so the change
# is gradual rather than a line ruled across the map.
CITY_CHARACTER = {
    "Park": {
        "skins": [BUILDING_SKINS[1], BUILDING_SKINS[2]],
        "heights": {"tower": (95, 155), "midrise": (48, 85), "shophouse": (16, 28)},
        "weights": (("tower", 6), ("midrise", 4), ("shophouse", 2), ("yard", 1), ("parking", 1)),
    },
    "Beach": {
        "skins": [BUILDING_SKINS[2], BUILDING_SKINS[0]],
        "heights": {"tower": (115, 190), "midrise": (55, 95), "shophouse": (16, 28)},
        "weights": (("tower", 7), ("midrise", 4), ("shophouse", 1), ("yard", 1), ("parking", 1)),
    },
    "Dock": {
        "skins": [BUILDING_SKINS[3], BUILDING_SKINS[0]],
        "heights": {"tower": (105, 170), "midrise": (48, 85), "shophouse": (14, 26)},
        "weights": (("tower", 6), ("midrise", 4), ("shophouse", 1), ("yard", 2), ("parking", 2)),
    },
    "City": {
        "skins": [BUILDING_SKINS[0], BUILDING_SKINS[3]],
        "heights": {"tower": (180, 300), "midrise": (85, 150), "shophouse": (20, 34)},
        "weights": (("tower", 9), ("midrise", 3), ("shophouse", 1), ("yard", 1), ("parking", 1)),
    },
    "Office": {
        "skins": [BUILDING_SKINS[3], BUILDING_SKINS[0]],
        "heights": {"tower": (230, 380), "midrise": (105, 185), "shophouse": (22, 36)},
        "weights": (("tower", 10), ("midrise", 3), ("shophouse", 1), ("yard", 1), ("parking", 1)),
    },
}

# The coast between campuses belongs to nobody in particular.
DEFAULT_CHARACTER = CITY_CHARACTER["Beach"]


def character_at(x, z):
    """The architectural character governing a point, by nearest campus."""
    best, best_distance = None, math.inf
    for area in AREAS:
        if area["flight_only"]:
            continue
        distance = math.hypot(x - area["x"], z - area["z"])
        if distance < best_distance:
            best, best_distance = area, distance
    if best is None:
        return DEFAULT_CHARACTER
    return CITY_CHARACTER.get(best["venue_type"], DEFAULT_CHARACTER)


def weighted_kind(weights, rng):
    total = sum(weight for _, weight in weights)
    roll = rng.uniform(0, total)
    for kind, weight in weights:
        roll -= weight
        if roll <= 0:
            return kind
    return weights[-1][0]


def subdivide(x, z, width, depth, rng, min_side=250, depth_limit=3):
    """A block's interior cut into lots by recursive binary splitting.

    Always splits the longer axis, which is what keeps lots roughly square
    instead of degenerating into strips, and stops on size rather than on a
    fixed count so a small edge block gets two lots and a full interior block
    gets a dozen.
    """
    if depth_limit <= 0 or max(width, depth) < min_side * 2:
        return [(x, z, width, depth)]

    if width >= depth:
        cut = width * rng.uniform(0.38, 0.62)
        return (
            subdivide(x - (width - cut) / 2, z, cut, depth, rng, min_side, depth_limit - 1)
            + subdivide(x + cut / 2, z, width - cut, depth, rng, min_side, depth_limit - 1)
        )
    cut = depth * rng.uniform(0.38, 0.62)
    return (
        subdivide(x, z - (depth - cut) / 2, width, cut, rng, min_side, depth_limit - 1)
        + subdivide(x, z + cut / 2, width, depth - cut, rng, min_side, depth_limit - 1)
    )


def procedural_building(x, z, width, depth, height, skin, rng):
    """One building: a setback mass, a bay-rhythm facade, and a used roof.

    The old generator spent its parts on a single extruded box with a window
    strip per face. That instinct was right about windows -- a per-floor grid is
    invisible at the distance these are seen from -- but wrong about the mass:
    what actually reads at range is the silhouette, so the parts go there.

    Everything here is capped by MAX_BUILDING_PARTS in the validator.

    Draws from its own stream, seeded on where the building stands rather than on
    the block's rng. Interior detail and block layout are separate concerns, and
    while they shared a stream every tweak in here consumed a different number of
    rolls and reshuffled every building after it -- which is how an earlier pass
    made a part-*saving* change increase the part count. Seeded on position, not
    on an index, so the seed survives a lot being subdivided differently.
    """
    brng = random.Random(f"city-v4:building:{round(x, 1)}:{round(z, 1)}")
    out = []
    ground_y = FLOOR_TOP

    # Podium: the two-storey base a street actually meets.
    podium = min(height * 0.35, 11)
    out.append(part("Podium", [width, podium, depth],
                    cf(x, ground_y + podium / 2, z), skin["trim"], skin["material"]))

    # A setback stack rather than one extrusion. Each volume steps in, so the
    # skyline reads as stepped rather than as a row of cuboids.
    volumes = 1 if height < 45 else (2 if height < 110 else 3)
    remaining = height - podium
    base_y = ground_y + podium
    w, d = width - 3, depth - 3
    for level in range(volumes):
        share = remaining if level == volumes - 1 else remaining * brng.uniform(0.45, 0.65)
        out.append(part("Shaft", [w, share, d],
                        cf(x, base_y + share / 2, z), skin["wall"], skin["material"]))
        # A cornice at every setback: the line that stops two stacked boxes
        # reading as one badly-proportioned box.
        out.append(part("Cornice", [w + 2.2, 1.6, d + 2.2],
                        cf(x, base_y + share, z), skin["trim"], skin["material"],
                        CanCollide=False))

        # Bay rhythm, not a window grid. A glazing band sits *on* each of the four
        # faces rather than spanning the mass: two crossed slabs would intersect
        # through the corners, which is real interpenetration and z-fights there.
        # Bands carry a facade at streaming distance for four parts, where a
        # per-floor grid would cost hundreds and read identically.
        bands = 2 if (level == 0 and share >= 30) else 1
        for band in range(bands):
            band_y = base_y + share * (band + 0.5) / bands
            band_h = max(3.5, min(share / bands - 6, 9))
            for face in (-1, 1):
                out.append(part("Glazing", [w - 8, band_h, 0.7],
                                cf(x, band_y, z + face * d / 2),
                                skin["glass"], "Glass", Transparency=0.3,
                                CanCollide=False, CastShadow=False))
                out.append(part("Glazing", [0.7, band_h, d - 8],
                                cf(x + face * w / 2, band_y, z),
                                skin["glass"], "Glass", Transparency=0.3,
                                CanCollide=False, CastShadow=False))
        # Piers only on the volume the street sees; higher setbacks are read as
        # silhouette, not as facade.
        if level == 0:
            for side in (-1, 1):
                out.append(part("Pier", [2.4, share, d * 0.62],
                                cf(x + side * (w / 2 - 1.2), base_y + share / 2, z),
                                skin["trim"], skin["material"], CanCollide=False))

        base_y += share
        remaining -= share
        w, d = w - brng.uniform(7, 15), d - brng.uniform(7, 15)
        if w < 24 or d < 24:
            break

    # A used roof. Flight means players look down at these constantly, and a
    # bare slab reads as a lid; a stair head and a tank are the cheapest things
    # that say the building has an inside.
    roof_y = base_y
    out.append(part("RoofDeck", [w + 3, 0.8, d + 3], cf(x, roof_y, z),
                    skin["trim"], skin["material"], CanCollide=False))
    out.append(part("RoofHouse", [w * 0.3, 6, d * 0.3],
                    cf(x + w * 0.18, roof_y + 3, z - d * 0.16),
                    skin["trim"], skin["material"], CanCollide=False))
    if height > 60:
        # Absolute size, not a fraction of the footprint. Scaled, a tank on a
        # 250-stud tower came out 54 studs across -- a flying saucer parked on the
        # roof. Water tanks are the same size on every building; that is what makes
        # them read as a tank and give the roof its scale.
        out.append(cylinder("RoofTank", 7, min(13.0, min(w, d) * 0.22),
                            mul(cf(x - w * 0.2, roof_y + 5.5, z + d * 0.14), rot_z(90)),
                            [0.32, 0.28, 0.24], "Metal", CanCollide=False))
    for vent in (-1, 1):
        out.append(tube("RoofVent",
                        (x + vent * w * 0.12, roof_y, z + d * 0.28),
                        (x + vent * w * 0.12, roof_y + 3.2, z + d * 0.28),
                        1.5, [0.34, 0.34, 0.36], CanCollide=False))

    # The shopfront the street sees, and the awning over it.
    out.append(part("ShopGlass", [width - 14, 5, 0.5],
                    cf(x, ground_y + 4.5, z + depth / 2 - 0.2),
                    [0.85, 0.72, 0.38], "Neon", CanCollide=False, CastShadow=False))
    out.append(part("Awning", [width - 10, 0.5, 3.4],
                    cf(x, ground_y + 8.2, z + depth / 2 + 1.2),
                    skin["glass"], "Fabric", CanCollide=False))

    # The roof is reported alongside the geometry rather than recomputed later.
    # roof_y, w and d are already known here and nowhere else; a second function
    # deriving them from the finished parts would be a copy of this arithmetic
    # that could quietly drift out of step with it.
    # base_* is the podium footprint, which is wider than the roof by every
    # setback the stack took. A fire escape has to clear the *building*, not the
    # roof: placed off the roof edge it starts life inside the podium.
    return out, {"x": x, "z": z, "top": roof_y,
                 "width": w + 3, "depth": d + 3,
                 "base_width": width, "base_depth": depth}


# Nothing may grow into a platform that floats over the city. Storm's slab sits
# at STORM_ALTITUDE with no ramp and no stairs, and flight being the only way up
# is the whole reason it is up there -- a tower punched through it would be both
# a hole in the geometry and a staircase to the top tier.
FLIGHT_PLATFORM_CLEARANCE = 45


def height_ceiling(x, z):
    """The tallest a building at this point may be."""
    ceiling = math.inf
    for area in AREAS:
        if not area["flight_only"]:
            continue
        # Generous horizontally: a tower merely *near* the underside still reads
        # as scaffolding up to a place you are supposed to have to fly to.
        if math.hypot(x - area["x"], z - area["z"]) < 1100:
            ceiling = min(ceiling, area["altitude"] - FLIGHT_PLATFORM_CLEARANCE)
    return ceiling


# A tower is allowed to be slender, but not a needle: past roughly six times its
# own footprint a building stops reading as a building and starts reading as a
# post. Small lots therefore get shorter towers rather than being excluded from
# having one.
MAX_SLENDERNESS = 6.0


def city_lot(lot, kind, character, rng, catalogue=None):
    """One subdivided lot, built according to what it was zoned.

    `catalogue` collects the open ground and the rooftops this lot produces, so a
    later pass can put a training site on them. Recording only -- nothing here
    reads it, and passing None builds exactly the same geometry.
    """
    x, z, width, depth = lot
    # Inset off the lot boundary so neighbours do not share walls and the alley
    # and pavement stay walkable between them.
    width, depth = width - 26, depth - 26
    if width < 34 or depth < 34:
        return []

    if kind == "parking":
        if catalogue is not None:
            catalogue["ground"].append({"x": x, "z": z, "width": width, "depth": depth})
        return parking_lot(x, z, width, depth, rng)

    if kind == "yard":
        # Deliberately empty ground, but finished: a yard reads as a place, a
        # gap in the lattice reads as unfinished.
        # Sat at +0.16 this topped out at exactly the height of a machine's rubber
        # mat, which never mattered while yards and machines were in different
        # places. Scattered sites stand on yards, so the two now meet -- and two
        # surfaces sharing a top face is the z-fighting the coplanar check exists
        # to catch.
        out = [part("Yard", [width, 0.35, depth], cf(x, FLOOR_TOP + 0.12, z),
                    [0.29, 0.31, 0.27], "Slate", CanCollide=False, CastShadow=False)]
        for corner in (-1, 1):
            out.append(part("YardFence", [width, 3.2, 0.6],
                            cf(x, FLOOR_TOP + 1.6, z + corner * depth / 2),
                            [0.26, 0.26, 0.28], "Metal", CanCollide=False))
        if catalogue is not None:
            catalogue["ground"].append({"x": x, "z": z, "width": width, "depth": depth})
        return out

    low, high = character["heights"][kind]
    height = rng.uniform(low, high)
    # Rolled first and clamped after, so a lot that happens to sit under the sky
    # platform or on a small footprint does not reshuffle every building after it.
    height = min(height, min(width, depth) * MAX_SLENDERNESS, height_ceiling(x, z))
    if height < 12:
        return []
    skin = rng.choice(character["skins"])
    # Grouped into a Model rather than left as loose parts: it is what lets the
    # validator hold a single building to a part budget, and it gives streaming a
    # unit to load a building as, instead of forty unrelated slabs.
    parts, roof = procedural_building(x, z, width, depth, height, skin, rng)
    if catalogue is not None:
        catalogue["roofs"].append(roof)
    return [group("Building", parts)]


# How far apart kerbside furniture stations sit. Fixed stations with a random
# choice at each, rather than random positions: scattering by position clumps and
# leaves gaps, and a street reads as a street precisely because its lamps and
# benches are evenly spaced.
FURNITURE_PITCH = 260


def _scenery(pieces, x, z):
    """Places a prop kit at a point and strips its collision.

    SOLID_CITY_PROPS is empty on purpose -- nothing scattered on a pavement is
    cover -- so a crate the player can run through is the rule rather than the
    exception, and the validator enforces it.
    """
    out = []
    for piece in pieces:
        node = place(cf(x, 0, z), piece)
        node["properties"]["CanCollide"] = False
        out.append(node)
    return out


def street_furniture(x, z, width, depth, index, accent, ground):
    """What stands along a block's kerb: lamps, trees, props, cars.

    Draws from its own stream rather than the block's. Sharing one meant every
    tweak to the furniture pitch consumed a different number of rolls and
    reshuffled every building in the city behind it -- so tuning the street
    silently redesigned the skyline, and no change could be judged on its own.
    """
    rng = random.Random(f"city-v3:furniture:{index}")
    out = []
    half_w, half_d = width / 2, depth / 2

    # Walk the two long kerbs. One side per axis is enough -- both sides of every
    # block would double the cost to say the same thing.
    stations = []
    steps = max(1, int(width // FURNITURE_PITCH))
    for step in range(steps):
        px = -half_w + width * (step + 0.5) / steps
        stations.append((x + px, z + half_d, 0))
        stations.append((x + px, z - half_d, 180))
    steps = max(1, int(depth // FURNITURE_PITCH))
    for step in range(steps):
        pz = -half_d + depth * (step + 0.5) / steps
        stations.append((x + half_w, z + pz, 90))
        stations.append((x - half_w, z + pz, -90))

    for sx, sz, facing in stations:
        roll = rng.random()
        if roll < 0.22:
            out.extend(street_light(sx, sz, facing))
        elif roll < 0.44:
            out.extend(city_tree(sx, sz, rng))
        elif roll < 0.50:
            out.extend(_scenery(CITY_PROPS["crate"](rng, accent, ground), sx, sz))
        elif roll < 0.56:
            out.extend(_scenery(CITY_PROPS["barrel"](rng, accent, ground), sx, sz))
        elif roll < 0.64:
            out.append(part("Bollard", [1.1, 3.2, 1.1], cf(sx, FLOOR_TOP + 1.6, sz),
                            [0.22, 0.22, 0.24], "Metal", CanCollide=False))
        elif roll < 0.72:
            # Kerbside parking. Cars are the cheapest thing that gives a street
            # its scale -- a road with nothing on it could be any width.
            out.extend(parked_car(sx, sz, facing + 90, rng))
        # The remainder is deliberately nothing: furniture at every station is
        # as wrong as furniture at none.
    return out


def parking_lot(x, z, width, depth, rng):
    """An asphalt lot with bay markings and a few cars.

    One stripe per row rather than per bay: at the distance a lot is read from,
    the rows are the pattern and the individual bays are not.
    """
    out = [part("Parking", [width, 0.3, depth], cf(x, FLOOR_TOP + 0.14, z),
                ROAD, "Asphalt", CanCollide=False, CastShadow=False)]
    rows = max(1, int(depth // 46))
    for row in range(rows):
        rz = z - depth / 2 + depth * (row + 0.5) / rows
        out.append(part("BayLine", [width - 8, 0.12, 0.6], cf(x, FLOOR_TOP + 0.32, rz),
                        [0.72, 0.70, 0.62], "SmoothPlastic",
                        CanCollide=False, CastShadow=False))
        for slot in range(max(1, int(width // 34))):
            if rng.random() < 0.28:
                sx = x - width / 2 + width * (slot + 0.5) / max(1, int(width // 34))
                out.extend(parked_car(sx, rz + 8, 0, rng))
    return out


def district_approach(area):
    """The paved ring a campus stands in, in world space.

    Every campus sits inside a 300-380 stud keep-out that strips blocks away so
    the gym stays visible and its entrances stay clear. That radius is right, but
    it was left as bare ground, so each destination stood in a bald circle -- the
    one place in the city with neither buildings nor anything else.

    This keeps the clearance and fills it: paving out to the ring, an approach
    axis pointing back at the street, planters marking the edge, and lamps. The
    campus still reads as arriving somewhere rather than as a clearing.
    """
    radius = 380 if area["venue_type"] == "Office" else 300
    x, z = area["x"], area["z"]
    rng = random.Random(f"city-v3:approach:{area['id']}")
    out = []

    # Paving, as a ring of tiles rather than one disc: a single 760-stud part
    # would z-fight the campus floor it surrounds and swamp the block beside it.
    # Heights are picked so no surface here shares a top face with the campus
    # floor, its running lane or a muscle court edge: paving tops out at +0.15,
    # the axis at +0.36.
    out.append(disc("ApproachPaving", 0.24, radius * 2, FLOOR_TOP + 0.03,
                    [0.34, 0.34, 0.36], "Concrete",
                    CanCollide=False, CastShadow=False))

    # No map footprint. The campus already puts itself on the minimap, and a
    # second feature the size of the whole approach would only smear over it --
    # its square corners also run off the world foundation at the edge campuses.

    # An axis from the street to the front of the campus, so the approach has a
    # direction rather than being a uniform apron.
    out.append(part("ApproachAxis", [46, 0.20, radius], cf(0, FLOOR_TOP + 0.26, radius / 2),
                    [0.28, 0.28, 0.30], "Concrete", CanCollide=False, CastShadow=False))

    # The edge: planters and lamps around the ring, and two banner pylons where
    # the axis meets it.
    for step in range(12):
        angle = math.radians(step * 30 + 15)
        px, pz = math.sin(angle) * (radius - 26), math.cos(angle) * (radius - 26)
        if step % 3 == 0:
            out.extend(street_light(px, pz, math.degrees(angle) + 180))
        else:
            out.append(part("Planter", [11, 2.6, 11], cf(px, FLOOR_TOP + 1.3, pz),
                            [0.30, 0.29, 0.27], "Concrete", CanCollide=False))
            out.append(part("PlanterShrub", [8, 3.4, 8], cf(px, FLOOR_TOP + 3.6, pz),
                            [0.20, 0.34, 0.19], "Grass", CanCollide=False))
    for side in (-1, 1):
        out.append(part("BannerPylon", [3.2, 26, 3.2],
                        cf(side * 30, FLOOR_TOP + 13, radius - 40),
                        [0.20, 0.20, 0.22], "Metal"))
        out.append(part("Banner", [1.0, 16, 8],
                        cf(side * 30, FLOOR_TOP + 17, radius - 36),
                        rng.choice([[0.72, 0.24, 0.22], [0.22, 0.44, 0.72]]),
                        "Fabric", CanCollide=False))
    return [place(mul(cf(x, area["altitude"], z), rot_y(area.get("yaw", 0))), piece)
            for piece in out]


# Every buildable surface the last city build produced: open ground worth
# standing a machine on, and rooftops wide and low enough to carry one.
#
# Rebuilt from scratch on every call to city_grid rather than memoised. The
# validator builds the whole world twice in one process to prove the output is
# deterministic, and `place()` rewrites node CFrames in place -- so a cache would
# hand the second build already-transformed geometry and make the determinism
# check compare a world against itself.
CITY_CATALOGUE = {"ground": [], "roofs": []}

# The street grid, hoisted out of city_grid so site selection can keep machines
# off the roads without a second copy of these numbers drifting from the first.
CROSSTOWN_ROADS = (-650, -1850, -3150, -4550, -6150, -7850)
UPLAND_AVENUES = (350, 1800, 3300, 4900, 6600, 8400, 10100, 11900, 13600, 15100)


# --------------------------------------------------------------------------
# Rooftop access.
#
# A machine on a roof has to be reachable on foot. Flight exists, but gating a
# training machine behind it would strand exactly the players who have not
# trained Legs yet -- which is to say, the ones who most need a machine.
# --------------------------------------------------------------------------

# Ramps rather than steps. Nothing in this project sets StepHeight or
# MaxSlopeAngle, so Roblox defaults apply: a humanoid walks any slope under 89
# degrees, which makes a ramp walkable by construction. Treads have to be kept
# individually under the ~2-stud auto-step or they silently become a wall, and
# they cost five times the parts to say the same thing.
# A comfortable, unambiguous walking pitch, and the width to walk it without
# aiming. Both matter more than they look: Roblox's navmesh ignores geometry that
# is too narrow, and a player who has to steer up a ramp will fall off it.
RAMP_PITCH_DEGREES = 26.0
RAMP_WIDTH = 16.0
# The travel of one ramp, measured between the landings it joins -- not between
# their centres. Spanning centre to centre put the last third of every ramp
# underneath the landing above it, so a climbing player met the landing's edge as
# a three-stud vertical face and stopped dead. Measured: the character reached
# x=563.6 of a 571 target and stayed there.
RAMP_RUN = 16.0
# Wide enough to turn around on. At 8 studs a walking player arriving at a
# switchback carried straight off the edge and fell the height they had just
# climbed -- measured, not guessed. The run is the one piece of this world a
# player has to negotiate rather than walk across, so it gets the room.
STAIR_WIDTH = 12.0
LANDING_SIZE = 14.0
# Centre to centre, so the ramp between them is exactly RAMP_RUN long.
FLIGHT_RUN = LANDING_SIZE + RAMP_RUN
STAIR_THICKNESS = 0.6

# How far the run stands off the wall it climbs. The landing is only half its own
# depth clear of the facade otherwise, which puts its inside edge exactly on the
# podium face -- close enough to catch a walking player on the corner.
STAIR_STANDOFF = 9.0

# How far below the pavement the ramp's low end is buried, so it surfaces without
# an edge.
STAIR_BASE_SINK = 2.5


def ramp_between(name, start, end, width, color, material="Concrete", **props):
    """A walkable slab spanning two points, given as the two *top-face* ends.

    Taking the ends as inputs rather than deriving them from a centre and a pitch
    is the whole point: a ramp built from an angle and a length has to have its
    endpoints kept in agreement with the landings it serves by arithmetic done
    somewhere else, and the failure mode is a gap you only find by walking into
    it. Here the ends are given, so they cannot drift.
    """
    span = tuple(e - s for s, e in zip(start, end))
    forward, length = _unit(span)
    # Horizontal and perpendicular to the run. Any ramp with a pitch under 90
    # degrees has a well-defined one.
    right, _ = _unit(cross((0.0, 1.0, 0.0), forward))
    up = cross(forward, right)

    middle = tuple((s + e) / 2 for s, e in zip(start, end))
    centre = tuple(m - u * STAIR_THICKNESS / 2 for m, u in zip(middle, up))
    return part(name, [width, STAIR_THICKNESS, length],
                axes(centre, right, up), color, material, **props)


def roof_access_stair(x, z, roof_y, roof_depth, color, accent):
    """A single straight ramp from the pavement to a roof.

    This was a switchback, and it did not work. Roblox's own pathfinder could not
    find a route between two *adjacent* landings on it while happily pathing forty
    studs of open pavement, and a walking character oscillated between the first
    two landings forever: a switchback stacks its up-ramp and its down-ramp at the
    same two spots, so "toward the next landing" and "back down the way I came"
    are the same direction. Clever geometry that a player cannot climb is worse
    than none.

    One straight run has none of that. There is exactly one way to go, it is wide
    enough to walk without aiming, and it costs four parts instead of twenty-five.
    Roof sites are capped low enough that a single flight reaches them.
    """
    # The ramp starts *below* the pavement and rises out of it. Starting on top of
    # the ground leaves a leading edge, and a leading edge is a lip: the character
    # walked into it, ragdolled, and sat in GettingUp forever instead of climbing.
    # Buried, there is no edge to catch -- the walkable surface simply emerges.
    base = FLOOR_TOP - STAIR_BASE_SINK
    rise = roof_y - base
    run = rise / math.tan(math.radians(RAMP_PITCH_DEGREES))
    face_z = z + roof_depth / 2 + STAIR_STANDOFF
    start_z = face_z + run

    return [
        # A flat pad where the ramp breaks the surface, so the approach reads as a
        # deliberate entrance rather than a slab sticking out of the pavement. The
        # roof-access check reads it to prove the climb starts at ground level.
        part("StairLanding", [RAMP_WIDTH + 4, 0.4, LANDING_SIZE],
             cf(x, FLOOR_TOP + 0.1, start_z + LANDING_SIZE / 2),
             color, "Concrete"),
        ramp_between("StairFlight",
                     (x, base, start_z), (x, roof_y, face_z),
                     RAMP_WIDTH, color),
        # The top landing reaches back onto the roof so there is no lip to clear.
        part("StairTopLanding",
             [RAMP_WIDTH + 4, STAIR_THICKNESS, LANDING_SIZE * 2],
             cf(x, roof_y - STAIR_THICKNESS / 2, face_z - LANDING_SIZE),
             color, "Concrete"),
        # Solid kerbs either side, so a player who drifts is turned back onto the
        # ramp rather than off it.
        part("StairRail", [0.8, 3.0, run + LANDING_SIZE],
             mul(cf(x - RAMP_WIDTH / 2, base + rise / 2 + 1.5, face_z + run / 2),
                 rot_x(0)),
             accent, "Metal"),
        part("StairRail", [0.8, 3.0, run + LANDING_SIZE],
             mul(cf(x + RAMP_WIDTH / 2, base + rise / 2 + 1.5, face_z + run / 2),
                 rot_x(0)),
             accent, "Metal"),
    ]


# --------------------------------------------------------------------------
# Scattered training sites.
#
# The gym used to be seven campuses of five machines: a 16,000 x 9,000 stud
# world with all of its gameplay inside about half a percent of its area. Every
# machine is now its own destination somewhere in the city.
#
# Sites are *chosen from* the city rather than authored beside it, which is why
# city_grid runs first and records what it built. A machine therefore always
# stands on ground the city generator actually made -- a yard, a parking lot, a
# rooftop -- instead of hovering wherever a hand-written coordinate happened to
# land.
# --------------------------------------------------------------------------

# A court is 44 x 42. Anything hosting one needs room for it plus a margin.
SITE_CLEAR_WIDTH = 50
SITE_CLEAR_DEPTH = 48

# Roofs above this are not worth reaching: the ramp to a 376-stud roof costs more
# parts than the site it serves, and a fire escape taller than its own building
# stops reading as a fire escape.
# One straight ramp has to reach it, and a ramp long enough for a tall roof would
# run across the street. 30 studs is about 55 studs of run -- the depth of a
# pavement and a front yard -- and 38 roofs still qualify.
MAX_ROOF_SITE_HEIGHT = 30

# Machines must not sit in the roadway, and must leave the spawn plaza alone.
ROAD_SITE_CLEARANCE = 70
HUB_SITE_CLEARANCE = 460

# Five muscles across seven tiers: one site per machine.
# The starter tier no longer draws from the scattered pool: its five machines ring
# the spawn plaza instead, so a new player has something to train on before they
# have any way to travel.
STARTER_ZONE = "Garage"
SCATTERED_SITE_COUNT = len(FAMILY_ORDER) * (len(STAT_VARIANTS["Chest"]) - 1)

# How many of those stand on rooftops. The rest are street and park level.
ROOF_SITE_QUOTA = 10

# The starter ring, as a horseshoe open toward the campus rather than a full
# circle. The +z half of the plaza is not free: the campus floor begins at z 15,
# the coach stands at (0, 32) and the entrance beacons at (+/-52, 28). A ring
# through them would put a court on the campus slab, whose top face is 0.02 studs
# from a court's own -- the tight kind of coplanar pair that z-fights.
#
# So the arc runs from due east round through south to due west, into the empty
# band between the plaza and the first city block at z -180.
GARAGE_RING_CENTER = (0, -25)
GARAGE_RING_RADIUS = 120
GARAGE_RING_ANGLES = (90, 135, 180, 225, 270)
# Reported to the builders as the site's footprint. Comfortably larger than the
# 44x42 court so nothing reads as crowded.
GARAGE_RING_SITE_SPAN = 60


def _off_road(x, z):
    """Whether a point clears every road centreline."""
    if any(abs(z - centre) < CROSSTOWN_HALF + ROAD_SITE_CLEARANCE
           for centre in CROSSTOWN_ROADS):
        return False
    if any(abs(x - centre) < AVENUE_HALF + ROAD_SITE_CLEARANCE
           for centre in UPLAND_AVENUES):
        return False
    return True


def garage_ring_sites():
    """The five starter machines, ringing the spawn plaza.

    Authored rather than selected. Every other machine is chosen from whatever the
    city generator happened to build, which is what makes the world feel found; the
    starter five are the one place that has to be somewhere specific, because a
    player who has just spawned has no Tokens, no travel and no reason to walk
    eight thousand studs on faith.

    Deliberately *outside* the spawn safe zone. Safe zones block Token accrual --
    "no pay where you cannot be hit" -- so a protected starter gym would grow
    stats while paying nothing, and Tokens are what buy the multipliers. Outside
    also means the first five machines still teach that this is a PvP game.

    Returns the same shape site_candidates does, so connected_locations needs no
    special case beyond choosing which pool a tier draws from.
    """
    centre_x, centre_z = GARAGE_RING_CENTER
    out = []
    for angle in GARAGE_RING_ANGLES:
        theta = math.radians(angle)
        out.append({
            "kind": "ground",
            "x": centre_x + GARAGE_RING_RADIUS * math.sin(theta),
            "z": centre_z + GARAGE_RING_RADIUS * math.cos(theta),
            "top": FLOOR_TOP,
            "width": GARAGE_RING_SITE_SPAN,
            "depth": GARAGE_RING_SITE_SPAN,
            "base_depth": GARAGE_RING_SITE_SPAN,
            # Facing the plaza, so a player walking out of spawn meets the front of
            # each machine rather than its back.
            "yaw": angle,
        })
    return out


def site_candidates():
    """Every place in the built city that could carry a training court."""
    catalogue = CITY_CATALOGUE
    out = []

    for lot in catalogue["ground"]:
        if lot["width"] < SITE_CLEAR_WIDTH or lot["depth"] < SITE_CLEAR_DEPTH:
            continue
        out.append({"kind": "ground", "x": lot["x"], "z": lot["z"], "top": FLOOR_TOP,
                    "width": lot["width"], "depth": lot["depth"],
                    "base_depth": lot["depth"]})

    for roof in catalogue["roofs"]:
        if roof["width"] < SITE_CLEAR_WIDTH or roof["depth"] < SITE_CLEAR_DEPTH:
            continue
        if roof["top"] - FLOOR_TOP > MAX_ROOF_SITE_HEIGHT:
            continue
        out.append({"kind": "roof", "x": roof["x"], "z": roof["z"], "top": roof["top"],
                    "width": roof["width"], "depth": roof["depth"],
                    "base_depth": roof["base_depth"]})

    kept = [
        site for site in out
        if _off_road(site["x"], site["z"])
        and math.hypot(site["x"], site["z"] - 150) > HUB_SITE_CLEARANCE
    ]
    # Sorted so selection below is reproducible regardless of the order the city
    # generator happened to emit blocks in.
    kept.sort(key=lambda site: (round(site["x"], 3), round(site["z"], 3), site["kind"]))
    return kept


def _spread_pick(candidates, count, chosen=()):
    """Farthest-point selection: repeatedly take whatever is furthest from the
    set already taken.

    Deliberately not random. A seeded shuffle gives clumps and voids at these
    counts and needs tuning to look even; this is the standard greedy
    maximin construction, is within a factor of two of the optimal spread, and
    -- being a pure function of a sorted list -- is reproducible with no seed at
    all.
    """
    picked = list(chosen)
    pool = list(candidates)
    if not picked and pool:
        # Start from the candidate nearest the spawn plaza, so the first site is
        # somewhere a new player will actually walk past.
        first = min(pool, key=lambda s: math.hypot(s["x"], s["z"] - 150))
        picked.append(first)
        pool.remove(first)

    while len(picked) < count and pool:
        best, best_distance = None, -1.0
        for site in pool:
            nearest = min(math.hypot(site["x"] - p["x"], site["z"] - p["z"])
                          for p in picked)
            if nearest > best_distance:
                best, best_distance = site, nearest
        picked.append(best)
        pool.remove(best)
    return picked


def scatter_sites():
    """The 35 places the machines stand, spread across the whole city."""
    candidates = site_candidates()
    roofs = [site for site in candidates if site["kind"] == "roof"]
    ground = [site for site in candidates if site["kind"] == "ground"]

    # Roofs first and ground second against one shared set, so the two pools
    # spread against each other rather than each spreading only against itself.
    picked = _spread_pick(roofs, min(ROOF_SITE_QUOTA, len(roofs)))
    picked = _spread_pick(ground, SCATTERED_SITE_COUNT, picked)
    if len(picked) < SCATTERED_SITE_COUNT:
        # Falling back to roofs rather than failing: a short ground pool is a
        # tuning problem, and a world that refuses to build is a worse way to
        # find out about it than a validator that names the shortfall.
        picked = _spread_pick(candidates, SCATTERED_SITE_COUNT, picked)
    return picked


# --------------------------------------------------------------------------
# Roof forms.
#
# Every roof in the city was a flat slab, which is most of why 438 buildings read
# as one building. These are the shapes that give a skyline a vocabulary, and all
# of them are reachable with the primitives this project already allows: a pitch
# is two wedges, a vault is a half-buried cylinder, a dome is a single ball.
#
# The wedge maths comes from the gym halls, which have had working pitched and
# sawtooth roofs all along -- hard-coded to their own constants. Promoted here to
# arguments so any building can use them.
# --------------------------------------------------------------------------


def pitched_roof(name, x, z, top, width, depth, rise, colour, material,
                 ridge_colour=None, along_x=False):
    """Two slopes meeting at a ridge down the middle of the span.

    The wedge convention is the one documented on `wedge`: Roblox slopes a
    WedgePart down along +Z from the top of its -Z face, so the two halves face
    opposite ways and each covers half the depth.
    """
    half = depth / 2 if not along_x else width / 2
    out = []
    for side, yaw in ((-1, 0), (1, 180)):
        if along_x:
            size = [depth, rise, half]
            frame = mul(cf(x + side * half / 2, top + rise / 2, z),
                        rot_y(yaw + 90))
        else:
            size = [width, rise, half]
            frame = mul(cf(x, top + rise / 2, z + side * half / 2), rot_y(yaw))
        out.append(wedge(f"{name}Pitch", size, frame, colour, material))
    ridge_span = width if not along_x else depth
    out.append(part(f"{name}Ridge", [ridge_span, 1.4, 3] if not along_x else [3, 1.4, ridge_span],
                    cf(x, top + rise, z), ridge_colour or colour, "Metal"))
    return out


def hipped_roof(name, x, z, top, width, depth, rise, colour, material):
    """A pitch that also falls to the two ends, so the roof has four slopes.

    The difference from a gable is only visible in silhouette -- which is exactly
    where a roof does its work.
    """
    out = pitched_roof(name, x, z, top, width * 0.72, depth, rise, colour, material)
    for side, yaw in ((-1, 90), (1, 270)):
        out.append(wedge(f"{name}Hip", [depth, rise, width * 0.14],
                         mul(cf(x + side * width * 0.43, top + rise / 2, z), rot_y(yaw)),
                         colour, material))
    return out


def sawtooth_roof(name, x, z, top, width, depth, bays, rise, colour, material, glass):
    """North-light sawtooth: the freight-shed roof, glazed on every riser."""
    out = []
    bay_depth = depth / bays
    for index in range(bays):
        bz = z - depth / 2 + bay_depth * (index + 0.5)
        out.append(wedge(f"{name}Saw", [width, rise, bay_depth],
                         cf(x, top + rise / 2, bz), colour, material))
        out.append(part(f"{name}SawGlass", [width, rise, 0.8],
                        cf(x, top + rise / 2, bz - bay_depth / 2),
                        glass, "Glass", Transparency=0.4, CanCollide=False))
    return out


def barrel_vault(name, x, z, top, width, depth, colour, material):
    """A half-cylinder lying along the building, the cheapest curve available.

    One part. A cylinder's axis is its local X, so this is turned to lie along the
    depth and sunk by its own radius so only the upper half shows.
    """
    radius = width / 2
    return [cylinder(f"{name}Vault", depth, width,
                     mul(cf(x, top, z), rot_y(90)), colour, material)]


def dome_roof(name, x, z, top, diameter, rise, colour, material, lantern=None):
    """A dome, as a ball sunk to its equator, with a drum ring at the springing.

    Shape="Ball" is a plain Roblox part shape and the first use of it in this
    project -- a dome is otherwise a great many small rotated boxes.
    """
    out = [
        part(f"{name}Dome", [diameter, rise * 2, diameter],
             cf(x, top, z), colour, material, Shape="Ball"),
        # A drum, not a rim. At 1.6 thick and fifty across this registered as a
        # floor to the coplanar check, which would have needed a height band for
        # what is really just a shape problem: the springing of a dome sits on a
        # drum, and a drum is tall.
        cylinder(f"{name}DomeRing", 7.0, diameter * 1.04,
                 mul(cf(x, top - 2.5, z), rot_z(90)), colour, material),
    ]
    if lantern is not None:
        out.append(cylinder(f"{name}Lantern", 6, diameter * 0.16,
                            mul(cf(x, top + rise, z), rot_z(90)), lantern, "Neon",
                            CanCollide=False))
    return out


def stepped_crown(name, x, z, top, width, depth, steps, colour, material, spire=None):
    """The art-deco answer: shrinking blocks, optionally topped with a spire.

    Each step is a genuine block rather than a thin lid. That is partly how a
    ziggurat should look and partly deliberate: a slab under six studs tall and
    over twelve across counts as a floor to the coplanar check, and a stack of
    those inside one building would all overlap in plan.
    """
    out = []
    w, d, y = width, depth, top
    for index in range(steps):
        height = 7.2 + index * 0.6
        w, d = w * 0.74, d * 0.74
        out.append(part(f"{name}Crown", [w, height, d],
                        cf(x, y + height / 2, z), colour, material))
        y += height
    if spire is not None:
        out.append(cylinder(f"{name}Spire", 14, max(2.0, w * 0.10),
                            mul(cf(x, y + 7, z), rot_z(90)), spire, "Metal",
                            CanCollide=False))
    return out


def city_grid(locations=None):
    """A dense but readable street hierarchy with varied, human-scale blocks."""
    global CITY_CATALOGUE
    catalogue = {"ground": [], "roofs": []}
    CITY_CATALOGUE = catalogue
    out = []
    crosstown_roads, upland_avenues = CROSSTOWN_ROADS, UPLAND_AVENUES
    for z in crosstown_roads:
        out.extend(city_road("CrosstownRoad", 15400, 58, 7600, z))
    for x in upland_avenues:
        # A one-hundredth lift at crossings prevents two independent asphalt parts
        # from occupying the same top face.  It is visually imperceptible and keeps
        # the intersections free of flicker.
        out.extend(city_road("UplandAvenue", 54, 8300, x, -4350, 0.01))
        for z in crosstown_roads:
            out.extend(crosswalk(x, z, True))

    # Blocks fill the rectangles between streets. A radial keep-out around every
    # training district preserves clear entrances and skyline views.
    keep_out = [(0, 150, 260)] + [
        (area["x"], area["z"], 380 if area["venue_type"] == "Office" else 300)
        for area in AREAS if not area["flight_only"]
    ]
    for index, rect in enumerate(city_block_rects(crosstown_roads, upland_avenues)):
        x, z, width, depth = rect
        # Only a block whose *centre* is inside a keep-out is dropped outright;
        # everything else keeps its pavement and hands the clearance decision to
        # the individual lots, which are small enough for the question to have a
        # sensible answer.
        if any(math.hypot(x - kx, z - kz) < radius for kx, kz, radius in keep_out):
            continue
        out.extend(city_block_shell(rect, index, keep_out, catalogue))

    # Street trees reinforce the main boulevard and make the park district visible
    # from several blocks away without adding random ground clutter.
    # Each campus keeps its clearance, and now stands in something.
    for area in AREAS:
        if not area["flight_only"]:
            out.extend(district_approach(area))

    rng = random.Random("coastal-city-v2:boulevard-trees")
    for x in range(-150, 15450, 210):
        if all(math.hypot(x - area["x"], -520 - area["z"]) > 300 for area in AREAS):
            out.extend(city_tree(x, -520, rng))
    return out


SHOP_X = 140
# Pushed south from -103 when the districts gained gym halls. The shop is 54 deep with
# an awning in front of that, so at -103 its canopy reached to about z -70 and lapped
# over the hall's south wall -- caught by GetPartsInPart, not by eye. It belongs in the
# forecourt, so it moves rather than the wall.
SHOP_Z = -124


def campus_shop(accent, x=None, z=None):
    """The shopkeeper's stall, and the counter and signage that mark it.

    This was a 74 x 54 walled room with a roof, sitting in a corner of the forecourt.
    Inside a gym there is nothing for a second building to do -- the hall is already the
    room -- so what is left is the furniture: a counter to stand behind, a shelf, and a
    sign high enough to spot from the door.

    `x`/`z` are campus-local. City districts put the stall in the middle of their hall;
    the starter beach, which has no hall, leaves it out in the open where the room was.
    """
    dark = [0.10, 0.12, 0.15]
    x = SHOP_X if x is None else x
    z = SHOP_Z if z is None else z
    pieces = [
        part("ShopCounter", [22, 4, 5], cf(x, FLOOR_TOP + 2, z),
             [0.30, 0.22, 0.16], "WoodPlanks"),
        part("ShopCounterTop", [23, 0.4, 6], cf(x, FLOOR_TOP + 4.2, z),
             [0.42, 0.32, 0.22], "WoodPlanks"),
        part("ShopShelf", [22, 1.2, 4], cf(x, FLOOR_TOP + 7.5, z - 4),
             [0.40, 0.31, 0.22], "WoodPlanks", CanCollide=False),
        # A sign on posts rather than on a facade there no longer is.
        part("ShopSignPost", [0.8, 12, 0.8], cf(x - 9, FLOOR_TOP + 6, z - 4.4),
             dark, "Metal"),
        part("ShopSignPost", [0.8, 12, 0.8], cf(x + 9, FLOOR_TOP + 6, z - 4.4),
             dark, "Metal"),
        part("ShopSign", [20, 5, 1.2], cf(x, FLOOR_TOP + 12, z - 4.4),
             dark, "Metal", CanCollide=False),
    ]
    # Primitive dumbbell logo: readable from farther away than text on a small sign.
    pieces.extend([
        part("ShopLogoBar", [11, 1.0, 1.0], cf(x, FLOOR_TOP + 12, z - 5.2),
             accent, "SmoothPlastic", CanCollide=False),
        part("ShopLogoPlate", [2.2, 4, 1.6], cf(x - 4.5, FLOOR_TOP + 12, z - 5.2),
             accent, "SmoothPlastic", CanCollide=False),
        part("ShopLogoPlate", [2.2, 4, 1.6], cf(x + 4.5, FLOOR_TOP + 12, z - 5.2),
             accent, "SmoothPlastic", CanCollide=False),
        npc("Shopkeeper", "Shopkeeper", x, z - 3.5, accent),
    ])
    return group("CampusShop", pieces)


# --- The gym hall -----------------------------------------------------------------
#
# Every city district used to be an open slab: five training courts on a paved
# rectangle under the sky, lit by neon floor strips and corner floods. It read as a
# car park with equipment on it rather than as a gym.
#
# This wraps the courts in an actual building. One generator, one theme table: the six
# districts differ by data, not by six copies of the same function, so a new venue type
# is an entry here and nothing else.
#
# The envelope is fixed by what it has to contain and avoid, not chosen for looks:
#
#   * the five bays span x +/-162 and z -46..+81, so the walls sit outside that
#   * the rope climb tops out at FLOOR_TOP + 13.6, and the GymZone multiplier volumes
#     reach local y 27, so the ceiling has to clear both
#   * the shop sits at (140, -103) and the monument at z -95..-126, the plate trees at
#     (+/-170, 92-97) and the entrance pylons at (+/-52, 122) -- all of which stay
#     outside in the forecourt, so the south wall stops at -80 and the north at 88.
#     -80 rather than -72 because the shop's awning reaches to about z -70: measured
#     with GetPartsInPart, the wall and its service lintel were clipping ShopRoof and
#     ShopAwning at -72
GYM_HALL_HALF_WIDTH = 180
GYM_HALL_SOUTH_Z = -80
GYM_HALL_NORTH_Z = 88
GYM_HALL_WALL = 3
GYM_HALL_HEIGHT = 32
GYM_HALL_DOOR_WIDTH = 60
GYM_HALL_DOOR_HEIGHT = 24
# The forecourt approach is from +Z, where the entrance pylons already stand, so the
# main doors face that way and a service opening on -Z keeps the shop reachable.
GYM_HALL_SERVICE_X = 140
GYM_HALL_SERVICE_WIDTH = 44

GYM_HALL_DEPTH = GYM_HALL_NORTH_Z - GYM_HALL_SOUTH_Z
GYM_HALL_CENTRE_Z = (GYM_HALL_NORTH_Z + GYM_HALL_SOUTH_Z) / 2


def _hall_wall_run(name, x_from, x_to, z, theme, height=None, y=None):
    """One straight length of wall between two x positions."""
    height = height or GYM_HALL_HEIGHT
    width = abs(x_to - x_from)
    if width < 0.5:
        return []
    return [part(name, [width, height, GYM_HALL_WALL],
                 cf((x_from + x_to) / 2, (y if y is not None else FLOOR_TOP + height / 2), z),
                 theme["wall"], theme["wall_material"])]


def _hall_roof_flat(theme, accent):
    """A flat deck with a parapet lip, the civic-sports-hall answer."""
    out = [part("HallRoof", [GYM_HALL_HALF_WIDTH * 2, 1.6, GYM_HALL_DEPTH],
                cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 0.8, GYM_HALL_CENTRE_Z),
                theme["roof"], theme["roof_material"])]
    for z in (GYM_HALL_SOUTH_Z, GYM_HALL_NORTH_Z):
        out.append(part("HallParapet", [GYM_HALL_HALF_WIDTH * 2, 3, 2],
                        cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 3, z),
                        theme["roof"], theme["roof_material"]))
    return out


def _hall_roof_pitched(theme, accent):
    """Two slopes meeting at a ridge down the middle of the span."""
    half = GYM_HALL_DEPTH / 2
    rise = 10
    out = []
    for side, yaw in ((-1, 0), (1, 180)):
        out.append(wedge(
            "HallRoofPitch", [GYM_HALL_HALF_WIDTH * 2, rise, half],
            mul(cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + rise / 2,
                   GYM_HALL_CENTRE_Z + side * half / 2), rot_y(yaw)),
            theme["roof"], theme["roof_material"]))
    out.append(part("HallRidge", [GYM_HALL_HALF_WIDTH * 2, 1.4, 3],
                    cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + rise, GYM_HALL_CENTRE_Z),
                    theme["trim"], "Metal"))
    return out


def _hall_roof_sawtooth(theme, accent):
    """North-light sawtooth: the freight-shed roof, glazed on every riser."""
    out = []
    bays = 3
    depth = GYM_HALL_DEPTH / bays
    for index in range(bays):
        z = GYM_HALL_SOUTH_Z + depth * (index + 0.5)
        out.append(wedge("HallSawtooth", [GYM_HALL_HALF_WIDTH * 2, 7, depth],
                         cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 3.5, z),
                         theme["roof"], theme["roof_material"]))
        out.append(part("HallSawtoothGlass", [GYM_HALL_HALF_WIDTH * 2, 7, 0.8],
                        cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 3.5, z - depth / 2),
                        theme["glass"], "Glass", Transparency=0.4, CanCollide=False))
    return out


def _hall_roof_truss(theme, accent):
    """Open steel trusses with non-colliding glazing between them.

    Storm is flight-only and sits at altitude, so players arrive from above. A solid
    deck would mean flying into a ceiling; this reads as a roof and lets them through.
    """
    out = []
    for z in range(int(GYM_HALL_SOUTH_Z) + 16, int(GYM_HALL_NORTH_Z), 32):
        out.append(part("HallTruss", [GYM_HALL_HALF_WIDTH * 2, 2.2, 2.2],
                        cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 1, z),
                        theme["roof"], theme["roof_material"]))
    out.append(part("HallCanopy", [GYM_HALL_HALF_WIDTH * 2, 0.4, GYM_HALL_DEPTH],
                    cf(0, FLOOR_TOP + GYM_HALL_HEIGHT + 2.4, GYM_HALL_CENTRE_Z),
                    theme["glass"], "Glass",
                    Transparency=0.55, CanCollide=False, CastShadow=False))
    return out


GYM_ROOF_BUILDERS = {
    "flat": _hall_roof_flat,
    "pitched": _hall_roof_pitched,
    "sawtooth": _hall_roof_sawtooth,
    "truss": _hall_roof_truss,
}


# Wall colour, material, roof style, glazing and light colour per venue type. Adding a
# seventh district means adding a row here; it means editing nothing else.
GYM_HALL_THEMES = {
    "Park": {
        "wall": [0.78, 0.76, 0.70], "wall_material": "Concrete",
        "roof": [0.34, 0.22, 0.18], "roof_material": "Slate", "roof_style": "pitched",
        "trim": [0.45, 0.33, 0.22], "glass": [0.62, 0.74, 0.72],
        "column": [0.42, 0.30, 0.20], "column_material": "Wood",
        "light": [0.60, 0.58, 0.52], "sign": "CIVIC PARK GYM",
    },
    "Beach": {
        "wall": [0.62, 0.46, 0.30], "wall_material": "WoodPlanks",
        "roof": [0.40, 0.28, 0.18], "roof_material": "WoodPlanks", "roof_style": "pitched",
        "trim": [0.72, 0.58, 0.36], "glass": [0.68, 0.80, 0.82],
        "column": [0.46, 0.32, 0.20], "column_material": "Wood",
        "light": [0.62, 0.57, 0.46], "sign": "BOARDWALK BARBELL",
    },
    "Dock": {
        "wall": [0.36, 0.34, 0.31], "wall_material": "CorrodedMetal",
        "roof": [0.28, 0.28, 0.30], "roof_material": "CorrodedMetal", "roof_style": "sawtooth",
        "trim": [0.55, 0.40, 0.24], "glass": [0.55, 0.62, 0.66],
        "column": [0.24, 0.25, 0.28], "column_material": "Metal",
        "light": [0.54, 0.56, 0.58], "sign": "FREIGHT YARD STRENGTH",
    },
    "City": {
        "wall": [0.52, 0.51, 0.48], "wall_material": "Concrete",
        "roof": [0.34, 0.34, 0.34], "roof_material": "Concrete", "roof_style": "flat",
        "trim": [0.66, 0.58, 0.36], "glass": [0.50, 0.62, 0.70],
        "column": [0.44, 0.44, 0.42], "column_material": "Concrete",
        "light": [0.58, 0.58, 0.54], "sign": "TITAN SQUARE",
    },
    "Office": {
        "wall": [0.16, 0.18, 0.22], "wall_material": "Metal",
        "roof": [0.14, 0.16, 0.20], "roof_material": "Metal", "roof_style": "flat",
        "trim": [0.42, 0.60, 0.70], "glass": [0.28, 0.50, 0.60],
        "column": [0.26, 0.28, 0.32], "column_material": "Metal",
        "light": [0.56, 0.59, 0.62], "sign": "APEX OFFICE GYM",
    },
    "Sky": {
        "wall": [0.22, 0.24, 0.30], "wall_material": "DiamondPlate",
        "roof": [0.26, 0.28, 0.34], "roof_material": "Metal", "roof_style": "truss",
        "trim": [0.58, 0.62, 0.78], "glass": [0.46, 0.56, 0.78],
        "column": [0.24, 0.26, 0.32], "column_material": "Metal",
        "light": [0.54, 0.57, 0.64], "sign": "STORMLINE ROOFTOP",
    },
}


def gym_building(area, theme):
    """The hall around one district's five training courts.

    Returns campus-local pieces, like every other builder here; the caller places
    them by the area frame.
    """
    accent = next(item for item in DISTRICTS if item["zone"] == area["zone"])["accent"]
    half = GYM_HALL_HALF_WIDTH
    door = GYM_HALL_DOOR_WIDTH / 2
    out = []

    # North face: the way in, split around a wide central opening with a lintel over.
    out.extend(_hall_wall_run("HallWallNorth", -half, -door, GYM_HALL_NORTH_Z, theme))
    out.extend(_hall_wall_run("HallWallNorth", door, half, GYM_HALL_NORTH_Z, theme))
    lintel = GYM_HALL_HEIGHT - GYM_HALL_DOOR_HEIGHT
    out.extend(_hall_wall_run(
        "HallLintel", -door, door, GYM_HALL_NORTH_Z, theme,
        height=lintel, y=FLOOR_TOP + GYM_HALL_DOOR_HEIGHT + lintel / 2))

    # South face: solid except a service opening lined up with the shop outside.
    service_from = GYM_HALL_SERVICE_X - GYM_HALL_SERVICE_WIDTH / 2
    service_to = GYM_HALL_SERVICE_X + GYM_HALL_SERVICE_WIDTH / 2
    out.extend(_hall_wall_run("HallWallSouth", -half, service_from, GYM_HALL_SOUTH_Z, theme))
    out.extend(_hall_wall_run("HallWallSouth", service_to, half, GYM_HALL_SOUTH_Z, theme))
    out.extend(_hall_wall_run(
        "HallLintel", service_from, service_to, GYM_HALL_SOUTH_Z, theme,
        height=lintel, y=FLOOR_TOP + GYM_HALL_DOOR_HEIGHT + lintel / 2))

    # Side walls, and a glazed strip high on each so the hall is not a windowless box.
    for side in (-1, 1):
        out.append(part("HallWallSide", [GYM_HALL_WALL, GYM_HALL_HEIGHT, GYM_HALL_DEPTH],
                        cf(side * half, FLOOR_TOP + GYM_HALL_HEIGHT / 2, GYM_HALL_CENTRE_Z),
                        theme["wall"], theme["wall_material"]))
        out.append(part("HallClerestory", [1.0, 7, GYM_HALL_DEPTH - 24],
                        cf(side * half, FLOOR_TOP + GYM_HALL_HEIGHT - 6, GYM_HALL_CENTRE_Z),
                        theme["glass"], "Glass",
                        Transparency=0.42, CanCollide=False, CastShadow=False))

    # Columns land in the concourse gaps between bays, never on a court.
    for x in (-54, 54):
        for z in (GYM_HALL_SOUTH_Z + 10, GYM_HALL_NORTH_Z - 10):
            out.append(part("HallColumn", [3.5, GYM_HALL_HEIGHT, 3.5],
                            cf(x, FLOOR_TOP + GYM_HALL_HEIGHT / 2, z),
                            theme["column"], theme["column_material"]))

    out.extend(GYM_ROOF_BUILDERS[theme["roof_style"]](theme, accent))

    # A soffit so the interior has a ceiling rather than the roof's underside, except
    # under an open truss where seeing the sky is the point.
    if theme["roof_style"] != "truss":
        out.append(part("HallSoffit",
                        [half * 2 - GYM_HALL_WALL, 0.5, GYM_HALL_DEPTH - GYM_HALL_WALL],
                        cf(0, FLOOR_TOP + GYM_HALL_HEIGHT - 0.6, GYM_HALL_CENTRE_Z),
                        CEILING_LINER, "Concrete",
                        CanCollide=False, CastShadow=False))

    # Interior lighting. ceiling_panel is already tuned for this place's Bloom and
    # global brightness -- see the note above it -- so only the colour is theme data.
    for x in (-120, -40, 40, 120):
        for z in (GYM_HALL_SOUTH_Z + 44, GYM_HALL_NORTH_Z - 44):
            panel = ceiling_panel(cf(x, FLOOR_TOP + GYM_HALL_HEIGHT - 2, z))
            panel["properties"]["Color"] = theme["light"]
            # Their ranges already overlap at this spacing, and the place runs Bloom on
            # top of a global Brightness of 2.5, so each panel only has to light the
            # floor beneath it. Left at ceiling_panel's own value they stacked into a
            # white ceiling.
            panel["children"][0]["properties"]["Brightness"] = 0.55
            out.append(panel)

    # Fascia over the entrance, in the district's own colour.
    out.append(part("HallFascia", [half * 2, 6, 2],
                    cf(0, FLOOR_TOP + GYM_HALL_HEIGHT - 3, GYM_HALL_NORTH_Z + 2.2),
                    theme["trim"], "Metal", CanCollide=False))
    out.append(part("HallSignBand", [136, 4, 1],
                    cf(0, FLOOR_TOP + GYM_HALL_HEIGHT - 3, GYM_HALL_NORTH_Z + 3.4),
                    accent, "SmoothPlastic", CanCollide=False))

    out.append(map_footprint(
        "GymHallMap", half * 2, GYM_HALL_DEPTH,
        cf(0, FLOOR_TOP + 0.16, GYM_HALL_CENTRE_Z), theme["wall"], "Building"))
    return out


def campus_shell(area, surface, material, map_kind="Building"):
    """Shared readable composition: courts, concourse, entrance, and focal stage."""
    accent = next(item for item in DISTRICTS if item["zone"] == area["zone"])["accent"]
    dark = [0.10, 0.12, 0.15]
    # Where the shop stall goes. A district with a hall puts it inside, in the gap the
    # five bays leave in the middle -- the bays sit at x -108/0/108 and z -25/60, so
    # x -54..54 at z 39..81 is free, and it is straight ahead of the north door.
    # The starter beach has no hall, so its stall stays out in the forecourt.
    theme = GYM_HALL_THEMES.get(area.get("venue_type"))
    shop_x, shop_z = (0, 60) if theme is not None else (SHOP_X, SHOP_Z)
    out = [
        # Solid, unlike everything stacked on it. The whole campus surface used to be
        # decoration over the world's 4-stud ground slab, so a player standing anywhere
        # on a district was at y 1.0 while the floor they could see was at 1.18 and a
        # training pad's mat was at 1.34 -- feet a third of a stud inside every pad they
        # walked onto. Making the one broad surface collide puts the visible floor and
        # the real floor in the same place; the courts and pads sitting 0.03-0.04 above
        # it are flush enough to walk over.
        map_feature(part(
            "CampusFloor", [CITY_CAMPUS_WIDTH, 0.18, CITY_CAMPUS_DEPTH],
            cf(0, FLOOR_TOP + 0.09, 0), surface, material,
            # Stated rather than left to the class default: dropping the CanCollide key
            # from the model JSON does not reset an instance Rojo has already synced,
            # so the flag has to be written for the change to reach a live place.
            CanCollide=True,
        ), map_kind),
        part("CentralConcourse", [52, 0.10, CITY_CAMPUS_DEPTH - 24],
             cf(0, FLOOR_TOP + 0.20, 0), dark, "Slate",
             CanCollide=False, CastShadow=False),
        # Painted, not lit. This was Neon: a glowing accent line running the length
        # of every campus, which together with the court stripes was most of the
        # "random lightning" look. The marking is still useful, the glow was not.
        part("ConcourseLine", [1.4, 0.08, CITY_CAMPUS_DEPTH - 50],
             cf(0, FLOOR_TOP + 0.27, 0),
             [c * 0.55 for c in accent], "SmoothPlastic",
             CanCollide=False, CastShadow=False),
        part("ShowStage", [120, 1.2, 34], cf(0, FLOOR_TOP + 0.6, -112),
             dark, "DiamondPlate"),
        part("StageAccent", [108, 0.18, 25], cf(0, FLOOR_TOP + 1.28, -112),
             accent, "SmoothPlastic", CanCollide=False),
        campus_shop(accent, shop_x, shop_z),
        # The quest giver, on the open concourse at the entrance end -- south of every
        # court, clear of the bays, and the first thing a player walks past on arrival.
        # One per campus so an objective is never a trip back to spawn.
        npc("Coach", "Coach", 0, 118, accent, style="coach", ring_color=QUEST_RING_COLOR),
    ]

    # A district-scale strength monument gives every arrival one thing to steer at.
    for x in (-60, 60):
        out.append(part("StageTruss", [4, 32, 4], cf(x, FLOOR_TOP + 17, -124),
                        dark, "Metal"))
    # Signage now, not a lamp: the gym itself is lit from inside, and a 55-stud
    # point light on a board 250 studs from the courts only washed out the monument.
    out.append(part("DistrictMarquee", [124, 7, 4], cf(0, FLOOR_TOP + 32, -124),
                    accent, "SmoothPlastic", CanCollide=False, CastShadow=False))
    out.extend([
        part("MonumentBar", [46, 3, 3], cf(0, FLOOR_TOP + 17, -121),
             [0.68, 0.70, 0.74], "Metal", CanCollide=False),
        cylinder("MonumentPlate", 5, 16,
                 mul(cf(-18, FLOOR_TOP + 17, -121), rot_z(90)),
                 accent, "Metal", CanCollide=False),
        cylinder("MonumentPlate", 5, 16,
                 mul(cf(18, FLOOR_TOP + 17, -121), rot_z(90)),
                 accent, "Metal", CanCollide=False),
    ])

    # Lit entrance pylons and corner floods frame the campus without fencing players in.
    for x in (-52, 52):
        out.extend(beacon({"accent": accent}, x, 122, 20))
    for x in (-170, 170):
        for z in (-115, 115):
            out.append(part("CampusFloodMast", [2, 28, 2],
                            cf(x, FLOOR_TOP + 14, z), dark, "Metal"))
            # Kept, and still lit: these are outdoor masts over the forecourt, shop
            # and monument, not floor strips, and with the courts indoors they are the
            # only thing lighting the approach. The head is no longer emissive.
            lamp = part("CampusFloodHead", [7, 2, 4],
                        cf(x, FLOOR_TOP + 28, z), [0.84, 0.82, 0.74], "SmoothPlastic",
                        CanCollide=False, CastShadow=False)
            lamp["children"] = [{
                "name": "CourtLight", "className": "PointLight",
                "properties": {"Brightness": 0.8, "Range": 45,
                               "Color": [1.0, 0.95, 0.84], "Shadows": False},
            }]
            out.append(lamp)

    # The hall around the courts, if this district has a venue type to build one from.
    #
    # The lookup is the switch: every city area carries a venue_type, and the Muscle
    # Beach starter campus -- the one caller that passes a bare {"zone": "Garage"} --
    # does not. So the starter stays an open-air beach by construction rather than by
    # a special case somebody has to remember, and it goes on reading as the "before"
    # that makes the first real gym feel like progress.
    if theme is not None:
        out.append(group("GymHall", gym_building(area, theme)))
    return out


def connected_plaza():
    """Muscle Beach spawn: safe pavilion, boardwalk furniture and palms."""
    rng = random.Random("coastal-city-v2:starter-beach")
    starter_area = {"zone": "Garage"}
    out = [place(STARTER_CAMPUS_FRAME, piece) for piece in campus_shell(
        starter_area, [0.39, 0.28, 0.18], "WoodPlanks"
    )]
    out.extend([
        tagged(part("SpawnSafeZone", [SAFE_ZONE_HALF * 2, 44, SAFE_ZONE_HALF * 2],
                    cf(0, FLOOR_TOP + 22, 0), [0.30, 0.80, 1.0], "ForceField",
                    CanCollide=False, Transparency=1, CastShadow=False),
               tags=["SafeZone"]),
        map_footprint("SafeZoneMap", SAFE_ZONE_HALF * 2, SAFE_ZONE_HALF * 2,
                      cf(0, FLOOR_TOP + 0.15, 0), [0.30, 0.80, 1.0], "SafeZone"),
    ])
    # The lifeguard pavilion is gone: a pale 28x18x20 cabin on a deck, with an emissive
    # sign over it. It was the last Neon part at spawn and, being a plain block, read as
    # a stray box on the sand rather than as a landmark.
    for x in (-175, 175):
        out.extend(_decorate(piece) for piece in palm(x, 260, rng))
        out.extend(_decorate(piece) for piece in palm(x, 38, rng))
    out.extend(plaza_furniture())
    return out


def scattered_training_area(location, tier_row):
    """One machine's site: its court, its tier volume, its sign, and its access.

    The zone volume is what makes a machine's tier real -- ZoneConfig.AtPosition
    reads the volume the player is standing in, not the machine -- so it travels
    with the court wherever the court goes.
    """
    origin = location["origin"]
    accent = tier_row["accent"]
    out = [place(origin, piece) for piece in training_court(
        location["equipment"], accent
    )]
    out.append(place(origin, volume(
        location["zone"], f"{location['id']}Volume", [48, 28, 58], cf(0, 13, 0)
    )))
    out.extend(place(origin, piece) for piece in site_marker(location, accent))

    # A rooftop court needs a way up and a floor that holds you. The deck the
    # building generator lays is CanCollide=False -- fine for scenery nobody
    # stands on, and a hole to fall through the moment a machine is up there.
    if location["site_kind"] == "roof":
        # Sized to the roof it covers rather than to a fixed number: roofs vary,
        # and a fixed slab either floats past the parapet or leaves the court
        # standing on the non-collidable deck underneath it.
        width, depth = location["site_width"], location["site_depth"]
        out.append(part(f"{location['id']}RoofFloor", [width, 1.0, depth],
                        cf(location["site_x"], location["site_top"] - 0.5,
                           location["site_z"]),
                        [0.30, 0.30, 0.32], "Concrete"))
        out.extend(roof_access_stair(
            location["site_x"], location["site_z"], location["site_top"],
            location["site_base_depth"], [0.34, 0.34, 0.36], accent))
    return out


def site_marker(location, accent):
    """The pylon that says a machine is here, in site-local space.

    Thirty-five destinations scattered over sixteen thousand studs are only worth
    having if they can be found. The board carries the muscle colour and the
    beacon is lit, so a site reads from street level and from the air.
    """
    family_color = FAMILY_COLORS[location["family"]]
    return [
        part("SitePost", [1.6, 26, 1.6], cf(-24, FLOOR_TOP + 13, -20),
             [0.20, 0.20, 0.22], "Metal"),
        part("SiteBoard", [12, 6, 0.6], cf(-24, FLOOR_TOP + 23, -20),
             family_color, "SmoothPlastic", CanCollide=False),
        part("SiteBeacon", [3, 3, 3], cf(-24, FLOOR_TOP + 27.5, -20),
             accent, "Neon", CanCollide=False),
    ]


def training_court(equipment_id, district_accent):
    """One readable muscle court framing a single machine.

    Sized to the one venue pad it contains (30 studs plus a walkable margin) rather
    than to the three-pad row it used to hold, so the painted floor ends where the
    equipment does instead of running 108 studs across the concourse.
    """
    family = EQUIPMENT_FAMILY[equipment_id]
    family_color = FAMILY_COLORS[family]
    out = [
        # Spaced 0.06 apart, not 0.01. A hundredth of a stud z-fights outright at
        # any distance; it survived review only because the coplanar check buckets
        # heights to the nearest hundredth and Python rounds halves to even, so
        # 1.205 and 1.215 landed in different buckets while 23.235 and 23.245 --
        # the same court lifted onto a roof -- landed in the same one.
        part("MuscleCourtEdge", [44, 0.04, 42], cf(0, FLOOR_TOP + 0.18, 0),
             district_accent, "SmoothPlastic", CanCollide=False, CastShadow=False),
        part("MuscleCourt", [40, 0.04, 38], cf(0, FLOOR_TOP + 0.25, 0),
             [0.17, 0.19, 0.22], "Slate", CanCollide=False),
        # Painted floor marking. This was Neon in the muscle family's colour -- the
        # bright green and orange bars visible from across the map -- and it is what
        # made the areas read as lit by lasers. MuscleCourtEdge above is already
        # SmoothPlastic and stays: it is the painted court boundary.
        part("MuscleStripe", [36, 0.02, 1.0], cf(0, FLOOR_TOP + 0.32, -17.2),
             family_color, "SmoothPlastic", CanCollide=False, CastShadow=False),
    ]
    for offset in COPY_OFFSETS:
        out.extend(place(cf(offset, 0, 0), piece)
                   for piece in training_venue(equipment_id, district_accent))
    return out


MOB_FIELD_RADIUS = 90
BOSS_ARENA_RADIUS = 70
# Sickly green for the field, dried blood for the arena. Both read as "not the gym" at
# a glance, which is the whole job of the ground colour.
MOB_FIELD_COLOR = [0.24, 0.34, 0.18]
BOSS_ARENA_COLOR = [0.32, 0.13, 0.14]


def mob_site(name_prefix, zone_id, offset_z, radius, ground_color, tag, map_kind):
    """One hostile site: visible ground, an invisible spawn marker, and a map icon.

    The marker rather than the ground carries the tag, for the same reason ZoneSpawn
    does: the ground is decoration that may be restyled or split into several parts,
    while the marker is a single stable point the server resolves a spawn area from.
    """
    origin = cf(0, 0, offset_z)
    pieces = [
        # Collidable, unlike the court markings. On the ground tiers this is a
        # redundant 0.1-stud step over the campus floor, but Skydeck and Storm are
        # flight-only platforms and their arenas sit past the edge of the deck: with a
        # non-colliding disc the boss spawned and immediately fell out of the world.
        disc(f"{name_prefix}Ground", 0.3, radius * 2, FLOOR_TOP + 0.10,
             ground_color, "Ground", CanCollide=True, CastShadow=False),
        # A ring of the same colour, brighter, so the boundary reads from inside it.
        disc(f"{name_prefix}Edge", 0.24, radius * 2 + 8, FLOOR_TOP + 0.08,
             [min(1.0, c * 1.7) for c in ground_color], "SmoothPlastic",
             CanCollide=False, CastShadow=False),
        tagged(
            part(f"{name_prefix}Marker", [3, 3, 3], cf(0, FLOOR_TOP + 1.5, 0),
                 ground_color, "SmoothPlastic",
                 CanCollide=False, CanTouch=False, CanQuery=False,
                 Transparency=1, CastShadow=False),
            tags=[tag],
            attributes={"ZoneId": zone_id, "Radius": radius},
        ),
        map_footprint(f"{name_prefix}Map", radius * 2, radius * 2,
                      cf(0, FLOOR_TOP + 0.15, 0), ground_color, map_kind,
                      shape="Circle"),
    ]
    return [place(origin, piece) for piece in pieces]


def mob_field(zone_id):
    """One tier's mob field, in site-local space."""
    return mob_site("MobField", zone_id, 0, MOB_FIELD_RADIUS,
                    MOB_FIELD_COLOR, "MobField", "MobField")


def boss_arena(zone_id):
    """One tier's boss arena, in site-local space."""
    return mob_site("BossArena", zone_id, 0, BOSS_ARENA_RADIUS,
                    BOSS_ARENA_COLOR, "BossArena", "BossArena")


def single_user_equipment(pieces):
    """Prune authored multi-user spots so one physical copy seats one player.

    A few legacy silhouettes (the starter dumbbell rack and pull-up rig) contain
    several sibling Spot models. The map now repeats the entire silhouette three
    times, so retaining those internal spots would make one visible copy serve two
    or three people. Keep the anchor nearest the equipment's local centre and remove
    every sibling branch that owns another anchor, including its held weights.
    """
    anchors = []

    def collect(node):
        if node.get("name") == "TrainAnchor":
            anchors.append(node)
        for child in node.get("children", []):
            collect(child)

    for piece in pieces:
        collect(piece)
    if len(anchors) <= 1:
        return pieces

    def centre_distance(anchor):
        frame = anchor.get("properties", {}).get("CFrame", [0, 0, 0])
        return frame[0] * frame[0] + frame[2] * frame[2]

    chosen = min(anchors, key=centre_distance)

    def contains_chosen(node):
        if node is chosen:
            return True
        return any(contains_chosen(child) for child in node.get("children", []))

    def anchor_count(node):
        return (1 if node.get("name") == "TrainAnchor" else 0) + sum(
            anchor_count(child) for child in node.get("children", [])
        )

    def prune(node):
        kept = []
        for child in node.get("children", []):
            if child.get("name") == "TrainAnchor" and child is not chosen:
                continue
            if anchor_count(child) > 0 and not contains_chosen(child):
                continue
            prune(child)
            kept.append(child)
        if "children" in node:
            node["children"] = kept

    kept_pieces = []
    for piece in pieces:
        if anchor_count(piece) > 0 and not contains_chosen(piece):
            continue
        prune(piece)
        kept_pieces.append(piece)
    return kept_pieces


def machine_copies(equipment_id, row):
    """The spots that stand on one destination's court -- one, as of the single-machine
    layout. Kept as a loop over COPY_OFFSETS so capacity is a constant, not a rewrite."""
    copies = []
    for index, offset in enumerate(COPY_OFFSETS, start=1):
        pieces = single_user_equipment(
            BUILDERS[equipment_id](*machine_palette(equipment_id, row))
        )
        copies.append(group(
            f"Spot{index:02d}",
            [place(cf(offset, 0, 0), piece) for piece in pieces],
        ))
    return copies


def district_plate_storage():
    """Two commercial plate trees kept outside the five training mats."""
    out = []
    plate_colors = (
        [0.10, 0.46, 0.20],
        [0.91, 0.72, 0.10],
        [0.10, 0.34, 0.73],
        [0.72, 0.08, 0.10],
    )
    for rack_x in (-170, 170):
        out.extend([
            part("PlateTreeBase", [22, 0.7, 9], cf(rack_x, FLOOR_TOP + 0.35, 95),
                 STEEL, "DiamondPlate"),
            part("PlateTreePost", [2, 10, 2], cf(rack_x, FLOOR_TOP + 5, 95),
                 STEEL_LIGHT, "Metal"),
            part("PlateTreeHeader", [2.5, 2.5, 10], cf(rack_x, FLOOR_TOP + 10, 95),
                 STEEL, "Metal"),
        ])
        for level, color in enumerate(plate_colors):
            y = FLOOR_TOP + 2.0 + level * 2.15
            out.append(cylinder(
                "StorageHorn", 8.0, 0.38,
                mul(cf(rack_x, y, 95), rot_y(90)), CHROME, "Metal",
            ))
            for plate_index in range(3):
                z = 92.2 + plate_index * 0.48
                out.append(cylinder(
                    "StoredPlate", 0.38, 2.7 + level * 0.28,
                    mul(cf(rack_x, y, z), rot_y(90)), color, "SmoothPlastic",
                    CanCollide=False,
                ))
    return out


def build_connected_world():
    zone_rows = {row["zone"]: row for row in DISTRICTS}
    structure = connected_ground()
    machines = []

    # The city is built before anything is placed in it. Scattered sites are
    # chosen from what the city generator actually produced -- its yards, its
    # parking lots, its rooftops -- so the catalogue has to exist before a single
    # location does. This ordering is the whole reason a machine always stands on
    # real ground instead of wherever a hand-written coordinate happened to land.
    mainland_children = region_ground(MAINLAND)
    mainland_children.extend(coastal_public_realm())
    mainland_children.extend(city_grid())
    structure.append(environment_model(
        MAINLAND["id"], "Ground", mainland_children
    ))

    locations = connected_locations()
    # Measured against all 35 courts, not just the scattered thirty. The starter
    # ring is where brand-new players train, and a boss arena landing beside it is
    # the last thing that should happen.
    hostile = scatter_hostile_sites(scatter_sites() + garage_ring_sites())

    # The hub is now the only place with a shop and a coach. Seven campuses each
    # carrying their own was seven walks to the same conversation.
    hub_children = connected_plaza()
    hub_children.extend(place(STARTER_CAMPUS_FRAME, piece)
                        for piece in district_plate_storage())

    sector_children = {f"Sector{index + 1}": [] for index in range(SECTOR_COUNT)}

    for location in locations:
        row = zone_rows[location["zone"]]
        sector_children[location["environment_id"]].append(
            folder(location["id"], scattered_training_area(location, row))
        )
        machines.append(machine(
            location["id"], location["equipment"],
            mul(location["origin"], cf(0, VENUE_PAD_RISE, 0)),
            machine_copies(location["equipment"], row),
            travel_id=location["id"],
            # Nothing is flight-gated any more: every rooftop site carries its own
            # fire escape, so the whole gym is reachable on foot.
            access_kind="Street",
            floor_index=1,
            exercise_family=location["family"],
            environment_id=location["environment_id"],
            requires_flight=False,
            location_name=location["location_name"],
            location_tagline=location["location_tagline"],
        ))

    # One mob field and one boss arena per tier, spread like the machines. The
    # server finds both purely through their tags, so moving them is placement
    # only -- MobService never learns they used to sit behind a campus.
    for index, row in enumerate(DISTRICTS[:7]):
        field_site = hostile[index]
        arena_site = hostile[index + 7]
        for site, builder in ((field_site, mob_field), (arena_site, boss_arena)):
            pieces = [place(cf(site["x"], 0, site["z"]), piece)
                      for piece in builder(row["zone"])]
            sector_children[sector_for(site["x"])].append(
                folder(f"{row['zone']}{'Field' if builder is mob_field else 'Arena'}",
                       pieces)
            )

    # connected_ground creates Hub first, so extend that environment with its
    # complete plaza while preserving global water/boundary siblings.
    for index, node in enumerate(structure):
        if node.get("name") == "Environment_Hub":
            node["children"].extend(hub_children)
            structure[index] = node
            break

    for index in range(SECTOR_COUNT):
        sector_id = f"Sector{index + 1}"
        structure.append(environment_model(
            sector_id, "Ground", sector_children[sector_id]
        ))

    return (
        {"className": "Folder", "children": [folder("CoastTrainingMainland", structure)]},
        {"className": "Folder", "children": machines},
    )


# Which environments belong in which half of the split output. The city is the one
# that grows without bound as blocks fill in; the districts are seven small, mostly
# static models, so keeping them in their own file means editing a campus does not
# rewrite the multi-megabyte city blob next to it.
CITY_ENVIRONMENTS = ("WorldFoundation", "WorldWater", "WorldBoundary", "Environment_Mainland")


def split_structure(payload):
    """The world's environments, sorted into the two committed files.

    Takes the payload `build_connected_world` returns rather than the raw list, so
    that function keeps the one shape every validator check already walks. The
    `CoastTrainingMainland` wrapper it carries existed only to group the
    environments; the two files do that job now, so the tree ends up the same depth
    it was.

    Shared with the validator rather than reimplemented there: a validator that
    sorted the environments its own way would be checking a world that is never
    written.
    """
    environments = []
    for wrapper in payload["children"]:
        environments.extend(wrapper["children"])

    city = [node for node in environments if node.get("name") in CITY_ENVIRONMENTS]
    districts = [node for node in environments if node.get("name") not in CITY_ENVIRONMENTS]
    missing = [name for name in CITY_ENVIRONMENTS if not any(n.get("name") == name for n in city)]
    if missing:
        raise ValueError(f"split_structure: no environment named {missing}")
    return (
        {"className": "Folder", "children": city},
        {"className": "Folder", "children": districts},
    )


def write(name, payload):
    path = os.path.abspath(os.path.join(OUT_DIR, name))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        # Compact, not pretty-printed. At three megabytes and a million lines this
        # file passed the point of human review long ago, and the indentation was
        # costing roughly half the bytes of every commit that touches the world.
        json.dump(payload, handle, separators=(",", ":"), sort_keys=False)
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
    city, districts = split_structure(structure)
    write("init.meta.json", {"className": "Model"})
    write("Structure/init.meta.json", {"className": "Folder"})
    write("Structure/City.model.json", city)
    write("Structure/Districts.model.json", districts)
    write("Machines.model.json", machines)


if __name__ == "__main__":
    main()
