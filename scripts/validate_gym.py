#!/usr/bin/env python3
"""Read-only structural validation for the generated gym world.

This script deliberately imports ``build_gym.py`` without calling its ``main``
function.  It builds the two model-JSON payloads in memory, checks the gameplay
and layout contracts, and confirms that the committed JSON is not stale.

It uses only the Python standard library and never writes to the workspace.
"""

from __future__ import annotations

from collections import Counter
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
from types import ModuleType
from typing import Any, Iterable, Iterator


ROOT = Path(__file__).resolve().parent.parent
BUILDER_PATH = ROOT / "scripts" / "build_gym.py"
EQUIPMENT_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "EquipmentConfig.luau"
ZONE_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "ZoneConfig.luau"
POSE_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "PoseConfig.luau"
MOVEMENT_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "MovementConfig.luau"
MOB_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "MobConfig.luau"
FORMULAS_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "Formulas.luau"
MOB_RIG_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "MobRigConfig.luau"
STRIKE_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "StrikeConfig.luau"
ABILITY_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "AbilityConfig.luau"
WEIGHT_CONFIG_PATH = ROOT / "src" / "ReplicatedStorage" / "Modules" / "WeightConfig.luau"
CITY_PATH = ROOT / "src" / "Workspace" / "Gym" / "Structure" / "City.model.json"
DISTRICTS_PATH = ROOT / "src" / "Workspace" / "Gym" / "Structure" / "Districts.model.json"
MACHINES_PATH = ROOT / "src" / "Workspace" / "Gym" / "Machines.model.json"

FAMILIES = ("Chest", "Arms", "Back", "Core", "Legs")
ACCESS_KINDS = {"Street", "ThirdFloor", "Sky"}
HELD_NAMES = {"HeldBoth", "HeldRight", "HeldLeft", "HeldWaist", "HeldBack"}
REQUIRED_STATION_ATTRIBUTES = {
    "EquipmentId",
    "TravelId",
    "VariantId",
    "ExerciseFamily",
    "EnvironmentId",
    "AccessKind",
    "FloorIndex",
    "RequiresFlight",
    "LocationName",
    "LocationTagline",
}

EXPECTED_STATIONS = 35
EXPECTED_ACTIVE_TIERS = 7
EXPECTED_BUILDERS = 35
# One connected coastal mainland. Multiplier districts occupy its beach, park,
# downtown blocks and office building rather than separate progression islands.
EXPECTED_ISLANDS = 1
# One destination district per non-starter tier; the starter tier is Muscle Beach.
# A flying yard has to be high enough that walking or jumping to it is plainly
# impossible, not merely awkward.
MIN_FLIGHT_ISLAND_ALTITUDE = 120
MIN_SKY_PIN_SEPARATION = 32.0
# Joints a pose may drive. TrainingPoseController resolves a joint by name and
# silently skips one it cannot find, which is how a pose degrades on R6 instead of
# erroring — and also how a typo becomes a limb that simply never moves.
POSE_JOINTS = {
    "Root", "Waist", "Neck",
    "RightShoulder", "LeftShoulder",
    "RightElbow", "LeftElbow",
    "RightHip", "LeftHip",
    "RightKnee", "LeftKnee",
    "RightAnkle", "LeftAnkle",
}
# The ceiling PoseConfig's own header documents. Rigs carry BallSocketConstraints,
# and past roughly this angle the achieved rotation stops tracking the requested one
# and then travels back the way it came — a pose written past it does not clamp, it
# animates backwards.
POSE_ANGLE_CEILING = 150.0
# Minimap footprints. Every feature crosses the wire in one GetDestinations call,
# so this is a payload budget as much as a rendering one.
#
# It used to be one footprint per city block and never per building, which kept
# the count down but meant the map drew solid rectangles where the city has
# masses, yards and gaps. Buildings are drawn now -- the map should match the
# place you walk through -- which is what took this from 600 to 900.
MAX_MAP_FEATURES = 900
# Raised from 7,000 when the six city districts gained enclosed gym halls. The halls
# cost about 31 BaseParts each and the world now sits near 6,950. The number that
# matters to a client is per-area, not global: StreamingEnabled brings in one district
# at a time and each hall lives inside its own area environment model.
# Global ceilings. These are authoring budgets, not engine limits: with
# StreamingEnabled only a radius around the player is ever resident, so what a
# client pays is MAX_PARTS_PER_STREAM_CELL below, and these exist to stop the
# generator producing a world nobody meant to make.
#
# 34,000 now, and the headroom over the ~27,000 the world currently uses is
# earmarked: the city is 438 buildings of a single archetype, and giving it a real
# architectural vocabulary costs parts. Raised before any of that geometry lands so
# the geometry commits are not also budget commits.
#
# 28,000 was the previous figure, itself raised from the 25,000 first planned. That estimate was made before the
# per-lot keep-out fix, which restored roughly a dozen full blocks that a
# too-coarse test had been deleting whole. Filling the city honestly costs about
# 27,300 parts, and hitting a rounder number would have meant thinning the street
# life this pass exists to add. The number that governs client cost is the cell
# cap below, and that is unchanged at 444 against a 560 ceiling.
MAX_BASE_PARTS = 34_000
MAX_INSTANCES = 38_000

# What a client actually pays for. StreamingEnabled keeps only a radius around the
# player resident (StreamingTargetRadius 512 in default.project.json), so the global
# budget above says almost nothing about frame time -- a world twice the size costs
# nothing extra if the extra parts are somewhere else. This is the number that
# matters, and it is why the global cap can be raised at all.
#
# Measured with the city built: the worst 512-stud cell holds 444 parts, a campus
# core with its blocks around it. That is only sixteen more than the same cell
# held before any of the fill went in, because block content is spread rather than
# piled -- which is the whole reason a five-fold larger world costs a client
# nothing extra.
#
# The cap sits about 25% above the real worst case. Loose enough that ordinary
# additions do not trip it, tight enough that a generator piling geometry into one
# place is caught while it is still one block rather than after it is everywhere.
STREAM_CELL = 512
MAX_PARTS_PER_STREAM_CELL = 560

# Per-machine detail budget. The floor is the real check: twelve machines once sat
# under 25 parts and read as blockouts standing next to 50-part benches, and nothing
# here noticed because every existing check is about correctness and layout rather
# than whether a machine looks finished. The ceiling keeps the global budget above
# safe by construction instead of discovering it blown after the fact.
#
# Both counts include the invisible load-state plates a selectorised machine grows,
# which is why the ceiling is well clear of the richest machine's visible geometry.
MIN_MACHINE_PARTS = 26
MAX_MACHINE_PARTS = 190

# One light per machine, and it must not cast. Thirty-five shadow-casting lights in
# one room is the difference between the gym running and not.
MAX_MACHINE_LIGHTS = 1

# A single building may not run away with the budget. A shophouse is around 12
# parts, a midrise 22 and a tower 34; anything past this is a generator bug, not
# a design decision.
MAX_BUILDING_PARTS = 48

BASE_PART_CLASSES = {
    "Part",
    "MeshPart",
    "WedgePart",
    "CornerWedgePart",
    "TrussPart",
    "SpawnLocation",
    "Seat",
    "VehicleSeat",
}

Node = dict[str, Any]


class Validator:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            self.failures.append(message)

    def fail(self, message: str) -> None:
        self.failures.append(message)


def load_builder() -> ModuleType:
    """Load build_gym without bytecode or filesystem side effects."""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("gym_world_builder", BUILDER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {BUILDER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def short_hash(canonical: str) -> str:
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:12]


def walk(node: Any) -> Iterator[Node]:
    if not isinstance(node, dict):
        return
    yield node
    for child in node.get("children", []):
        yield from walk(child)


def descendants(node: Node) -> Iterator[Node]:
    for child in node.get("children", []):
        yield child
        yield from descendants(child)


def tags(node: Node) -> set[str]:
    raw = node.get("properties", {}).get("Tags", [])
    if isinstance(raw, str):
        return {raw}
    if isinstance(raw, list):
        return {item for item in raw if isinstance(item, str)}
    return set()


def is_base_part(node: Node) -> bool:
    return node.get("className") in BASE_PART_CLASSES


def position(node: Node) -> tuple[float, float, float] | None:
    frame = node.get("properties", {}).get("CFrame")
    if not isinstance(frame, list) or len(frame) != 12:
        return None
    return float(frame[0]), float(frame[1]), float(frame[2])


def named_parts(node: Node, name: str) -> list[Node]:
    return [child for child in descendants(node) if child.get("name") == name and is_base_part(child)]


def parse_equipment_config() -> dict[str, dict[str, Any]]:
    """Extract the simple data rows without needing a Luau parser/runtime."""
    text = EQUIPMENT_CONFIG_PATH.read_text(encoding="utf-8")
    start = text.find("local definitions")
    end = text.find("\nlocal EquipmentConfig", start)
    if start < 0 or end < 0:
        raise RuntimeError("could not locate EquipmentConfig definitions table")
    section = text[start:end]

    rows: dict[str, dict[str, Any]] = {}
    entry_pattern = re.compile(
        r'equipment\("(?P<id>[^"]+)",\s*"[^"]+",\s*"(?P<family>[^"]+)",\s*'
        r'(?P<interval>\d+(?:\.\d+)?),\s*"(?P<pose>[^"]+)",\s*"[^"]+"\)'
    )
    for match in entry_pattern.finditer(section):
        equipment_id = match.group("id")
        fields = {
            "ExerciseFamily": match.group("family"),
            "StatId": match.group("family"),
            "PoseId": match.group("pose"),
            "BaseGain": float(match.group("interval")),
            "RepInterval": float(match.group("interval")),
        }
        if equipment_id in rows:
            raise RuntimeError(f'duplicate EquipmentConfig id "{equipment_id}"')
        rows[equipment_id] = fields
    return rows


def parse_pose_config() -> dict[str, dict[str, Any]]:
    """Extract poses, their joints and their angles without a Luau runtime.

    Same approach as parse_equipment_config, and for the same reason: PoseConfig is
    plain data, but it is data the `luau` CLI cannot load — it is written in Vector3,
    which the CLI does not provide. Reading the text is what lets the angles be
    checked at all.
    """
    text = POSE_CONFIG_PATH.read_text(encoding="utf-8")
    start = text.find("local poses")
    end = text.find("\nlocal r6Joints", start)
    if start < 0 or end < 0:
        raise RuntimeError("could not locate PoseConfig poses table")
    section = text[start:end]

    number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
    header = re.compile(r'Id\s*=\s*"(?P<id>[^"]+)",\s*\n\s*Cycles\s*=\s*(?P<cycles>' + number + r")")
    joint_start = re.compile(r'Joint\s*=\s*"(?P<joint>[^"]+)"')
    triple = rf"deg\(\s*({number})\s*,\s*({number})\s*,\s*({number})\s*\)"

    headers = list(header.finditer(section))
    if not headers:
        raise RuntimeError("could not parse any poses out of PoseConfig")

    poses: dict[str, dict[str, Any]] = {}
    for index, match in enumerate(headers):
        pose_id = match.group("id")
        if pose_id in poses:
            raise RuntimeError(f'duplicate PoseConfig id "{pose_id}"')
        body_end = headers[index + 1].start() if index + 1 < len(headers) else len(section)
        body = section[match.end():body_end]

        joints: list[dict[str, Any]] = []
        for joint_match in joint_start.finditer(body):
            # One joint entry runs from its name to the brace that closes it.
            entry = body[joint_match.end():]
            closing = re.search(r"\n\s*\},", entry)
            if closing is not None:
                entry = entry[: closing.start()]
            angles: dict[str, tuple[float, float, float]] = {}
            for field in ("Rest", "Peak"):
                found = re.search(rf"\b{field}\s*=\s*{triple}", entry)
                if found is not None:
                    angles[field] = tuple(float(found.group(axis)) for axis in (1, 2, 3))
            phase = re.search(rf"\bPhase\s*=\s*({number})", entry)
            joints.append({
                "Joint": joint_match.group("joint"),
                "Angles": angles,
                "Phase": float(phase.group(1)) if phase else None,
            })

        style = re.search(r'\bMotionStyle\s*=\s*"(?P<style>[^"]+)"', body)
        poses[pose_id] = {
            "Cycles": float(match.group("cycles")),
            "MotionStyle": style.group("style") if style else "Controlled",
            "Joints": joints,
        }
    return poses


def parse_movement_number(name: str) -> float:
    """Read one numeric MovementConfig constant without needing Roblox globals."""
    text = MOVEMENT_CONFIG_PATH.read_text(encoding="utf-8")
    match = re.search(rf"MovementConfig\.{re.escape(name)}\s*=\s*([-+]?\d+(?:\.\d+)?)", text)
    if match is None:
        raise RuntimeError(f"could not parse MovementConfig.{name}")
    return float(match.group(1))


def validate_poses(validator: Validator, equipment: dict[str, dict[str, Any]]) -> None:
    """Everything about an animation that can be checked without looking at it.

    A pose fails quietly in all three of these ways. An unresolvable PoseId, an
    unknown joint name and an over-ceiling angle all produce a character that is
    merely standing there or moving oddly, with nothing in the output to say so —
    which is exactly the kind of thing a check should be holding.
    """
    poses = parse_pose_config()

    used = {row["PoseId"] for row in equipment.values()}
    for equipment_id, row in sorted(equipment.items()):
        validator.check(
            row["PoseId"] in poses,
            f'{equipment_id}: PoseId "{row["PoseId"]}" has no PoseConfig entry',
        )
    for pose_id in sorted(set(poses) - used):
        validator.fail(f'PoseConfig entry "{pose_id}" is not used by any machine')

    for pose_id, pose in sorted(poses.items()):
        validator.check(
            pose["Cycles"] == 1,
            f"{pose_id}: Cycles must be 1 so one visible exercise cycle matches one stat popup",
        )
        validator.check(bool(pose["Joints"]), f"{pose_id}: pose drives no joints")
        validator.check(
            pose["MotionStyle"] in {"Controlled", "Continuous"},
            f'{pose_id}: unsupported MotionStyle "{pose["MotionStyle"]}"',
        )
        seen_joints: set[str] = set()
        for joint in pose["Joints"]:
            name = joint["Joint"]
            validator.check(
                name not in seen_joints,
                f'{pose_id}: joint "{name}" is driven twice in the same pose',
            )
            seen_joints.add(name)
            validator.check(
                name in POSE_JOINTS,
                f'{pose_id}: unknown joint "{name}" is silently skipped at runtime',
            )
            phase = joint["Phase"]
            validator.check(
                phase is None or 0.0 <= phase <= 1.0,
                f"{pose_id}/{name}: Phase {phase} is outside 0-1",
            )
            for field, angles in sorted(joint["Angles"].items()):
                worst = max(abs(value) for value in angles)
                validator.check(
                    worst <= POSE_ANGLE_CEILING,
                    f"{pose_id}/{name}: {field} reaches {worst:.0f} degrees, "
                    f"past the {POSE_ANGLE_CEILING:.0f} ceiling where joints reverse",
                )

    # Loaded strength movements need readable turnarounds; locomotor and alternating
    # conditioning patterns must keep flowing. These are easy to accidentally invert
    # because an omitted MotionStyle intentionally defaults to Controlled in Luau.
    for pose_id in ("BenchPress", "InclinePress", "PecDeck", "GobletSquat", "SquatRack", "Deadlift"):
        validator.check(
            poses.get(pose_id, {}).get("MotionStyle") == "Controlled",
            f"{pose_id}: compound lift must use Controlled timing",
        )
    for pose_id in ("BattleRopes", "RopeClimb", "StairClimber"):
        validator.check(
            poses.get(pose_id, {}).get("MotionStyle") == "Continuous",
            f"{pose_id}: cyclical movement must use Continuous timing",
        )


def parse_zone_progression() -> list[tuple[str, float, float]]:
    """Read zone id, power gate and multiplier from the simple config rows."""
    text = ZONE_CONFIG_PATH.read_text(encoding="utf-8")
    start = text.find("local zones")
    end = text.find("\nlocal ZoneConfig", start)
    if start < 0 or end < 0:
        raise RuntimeError("could not locate ZoneConfig zones table")
    section = text[start:end]
    pattern = re.compile(
        r'\{\s*Id\s*=\s*"(?P<id>[^"]+)"(?P<body>.*?)\n\s*\},',
        re.DOTALL,
    )
    number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?"
    out: list[tuple[str, float, float]] = []
    for match in pattern.finditer(section):
        body = match.group("body")
        power = re.search(rf"\bRequiredPower\s*=\s*(?P<value>{number})", body, re.IGNORECASE)
        gain = re.search(rf"\bGainMultiplier\s*=\s*(?P<value>{number})", body, re.IGNORECASE)
        if power is None or gain is None:
            raise RuntimeError(f'zone "{match.group("id")}" is missing numeric progression fields')
        out.append((match.group("id"), float(power.group("value")), float(gain.group("value"))))
    return out


def validate_finite_geometry(validator: Validator, payloads: Iterable[Any]) -> None:
    for payload in payloads:
        for node in walk(payload):
            label = node.get("name", "<unnamed>")
            properties = node.get("properties", {})
            frame = properties.get("CFrame")
            if frame is not None:
                validator.check(
                    isinstance(frame, list) and len(frame) == 12,
                    f"{label}: CFrame must contain exactly 12 numbers",
                )
                if isinstance(frame, list):
                    validator.check(
                        all(isinstance(value, (int, float)) and math.isfinite(value) for value in frame),
                        f"{label}: CFrame contains a non-finite or non-numeric value",
                    )

            size = properties.get("Size")
            if size is not None:
                validator.check(
                    isinstance(size, list) and len(size) == 3,
                    f"{label}: Size must contain exactly three numbers",
                )
                if isinstance(size, list):
                    validator.check(
                        all(
                            isinstance(value, (int, float))
                            and math.isfinite(value)
                            and value > 0
                            for value in size
                        ),
                        f"{label}: Size contains a non-positive, non-finite, or non-numeric value",
                    )
                    if is_base_part(node) and len(size) == 3:
                        validator.check(
                            all(value <= 2048 for value in size if isinstance(value, (int, float))),
                            f"{label}: Size exceeds Roblox's 2,048-stud BasePart limit",
                        )


def validate_equipment_tables(validator: Validator, builder: ModuleType) -> dict[str, str]:
    builders = getattr(builder, "BUILDERS", {})
    variants = getattr(builder, "STAT_VARIANTS", {})
    builder_ids = set(builders)
    flattened = {
        equipment_id
        for family_variants in variants.values()
        for equipment_id in family_variants
    }
    config = parse_equipment_config()
    config_ids = set(config)

    validator.check(len(builders) == EXPECTED_BUILDERS, f"expected 35 BUILDERS, found {len(builders)}")
    validator.check(len(flattened) == EXPECTED_BUILDERS, f"expected 35 STAT_VARIANTS ids, found {len(flattened)}")
    validator.check(len(config) == EXPECTED_BUILDERS, f"expected 35 EquipmentConfig definitions, found {len(config)}")
    validator.check(builder_ids == flattened, f"BUILDERS and STAT_VARIANTS differ: {sorted(builder_ids ^ flattened)}")
    validator.check(builder_ids == config_ids, f"BUILDERS and EquipmentConfig differ: {sorted(builder_ids ^ config_ids)}")
    validator.check(set(variants) == set(FAMILIES), f"STAT_VARIANTS families must be {list(FAMILIES)}")

    family_by_equipment: dict[str, str] = {}
    for family in FAMILIES:
        family_variants = tuple(variants.get(family, ()))
        validator.check(len(family_variants) == 7, f"{family}: expected exactly seven variants, found {len(family_variants)}")
        for equipment_id in family_variants:
            family_by_equipment[equipment_id] = family
            row = config.get(equipment_id, {})
            validator.check(
                row.get("ExerciseFamily") == family,
                f'{equipment_id}: EquipmentConfig ExerciseFamily should be "{family}"',
            )
            validator.check(
                row.get("StatId") == family,
                f'{equipment_id}: EquipmentConfig StatId should be "{family}"',
            )
            validator.check(bool(row.get("PoseId")), f"{equipment_id}: EquipmentConfig is missing PoseId")
            validator.check(
                row.get("BaseGain") == row.get("RepInterval"),
                f"{equipment_id}: BaseGain must equal RepInterval for exactly +1/s equipment rate",
            )
            rep_interval = row.get("RepInterval")
            validator.check(
                isinstance(rep_interval, (int, float)) and 1.25 <= rep_interval <= 2.5,
                f"{equipment_id}: RepInterval must stay in the readable 1.25-2.5s exercise range",
            )

    return family_by_equipment


def validate_locations(
    validator: Validator,
    builder: ModuleType,
    stations: list[Node],
    family_by_equipment: dict[str, str],
) -> dict[str, Node]:
    locations = list(builder.connected_locations())
    validator.check(
        len(locations) == EXPECTED_STATIONS,
        f"expected 35 generated locations, found {len(locations)}",
    )
    validator.check(
        len(stations) == EXPECTED_STATIONS,
        f"expected 35 TrainingStation models, found {len(stations)}",
    )

    location_by_id: dict[str, dict[str, Any]] = {}
    for location in locations:
        travel_id = location.get("id")
        if not isinstance(travel_id, str) or not travel_id:
            validator.fail(f"location has invalid id: {travel_id!r}")
            continue
        if travel_id in location_by_id:
            validator.fail(f'duplicate generated location id "{travel_id}"')
        location_by_id[travel_id] = location

    station_by_id: dict[str, Node] = {}
    family_counts: Counter[str] = Counter()
    equipment_counts: Counter[str] = Counter()
    access_counts: Counter[str] = Counter()
    zone_counts: Counter[str] = Counter()
    pair_counts: Counter[tuple[str, str]] = Counter()
    family_access_counts: Counter[tuple[str, str]] = Counter()
    sky_ids: list[str] = []

    for station in stations:
        attributes = station.get("attributes", {})
        missing = REQUIRED_STATION_ATTRIBUTES - set(attributes)
        label = station.get("name", "<unnamed station>")
        validator.check(not missing, f"{label}: missing station attributes {sorted(missing)}")

        travel_id = attributes.get("TravelId")
        if not isinstance(travel_id, str) or not travel_id:
            validator.fail(f"{label}: TravelId must be a non-empty string")
            continue
        if travel_id in station_by_id:
            validator.fail(f'duplicate station TravelId "{travel_id}"')
        station_by_id[travel_id] = station

        location = location_by_id.get(travel_id)
        if location is None:
            validator.fail(f'{label}: TravelId "{travel_id}" has no generated location record')
            continue

        equipment_id = attributes.get("EquipmentId")
        variant_id = attributes.get("VariantId")
        family = attributes.get("ExerciseFamily")
        access_kind = attributes.get("AccessKind")
        environment_id = attributes.get("EnvironmentId")
        floor_index = attributes.get("FloorIndex")
        requires_flight = attributes.get("RequiresFlight")
        location_name = attributes.get("LocationName")
        location_tagline = attributes.get("LocationTagline")
        zone_id = location.get("zone")

        validator.check(equipment_id in family_by_equipment, f'{travel_id}: unknown EquipmentId "{equipment_id}"')
        validator.check(variant_id == equipment_id, f"{travel_id}: VariantId must equal EquipmentId")
        validator.check(family in FAMILIES, f'{travel_id}: invalid ExerciseFamily "{family}"')
        validator.check(
            family_by_equipment.get(equipment_id) == family,
            f"{travel_id}: equipment family does not match ExerciseFamily",
        )
        validator.check(equipment_id == location.get("equipment"), f"{travel_id}: station EquipmentId differs from layout")
        validator.check(family == location.get("family"), f"{travel_id}: station ExerciseFamily differs from layout")
        validator.check(access_kind in ACCESS_KINDS, f'{travel_id}: invalid AccessKind "{access_kind}"')
        validator.check(
            isinstance(environment_id, str) and bool(environment_id),
            f"{travel_id}: EnvironmentId must be a non-empty string",
        )
        validator.check(environment_id == location.get("environment_id"), f"{travel_id}: EnvironmentId differs from layout")
        validator.check(
            isinstance(floor_index, (int, float)) and not isinstance(floor_index, bool) and floor_index >= 1,
            f"{travel_id}: FloorIndex must be a positive number",
        )
        validator.check(isinstance(requires_flight, bool), f"{travel_id}: RequiresFlight must be boolean")
        validator.check(
            isinstance(location_name, str) and bool(location_name.strip()),
            f"{travel_id}: LocationName must be a non-empty string",
        )
        validator.check(
            isinstance(location_tagline, str) and bool(location_tagline.strip()),
            f"{travel_id}: LocationTagline must be a non-empty string",
        )
        validator.check(location_name == location.get("location_name"), f"{travel_id}: LocationName differs from layout")
        validator.check(
            location_tagline == location.get("location_tagline"),
            f"{travel_id}: LocationTagline differs from layout",
        )

        expected_access = "Sky" if location.get("style") == "sky" else "Street"
        validator.check(access_kind == expected_access, f"{travel_id}: AccessKind should be {expected_access}")
        validator.check(
            requires_flight == bool(location.get("requires_flight")),
            f"{travel_id}: RequiresFlight differs from layout",
        )
        if access_kind == "Sky":
            sky_ids.append(travel_id)
            validator.check(requires_flight is True, f"{travel_id}: Sky station must require flight")
        # Every station stands on its island's own floor now; a Sky station is one
        # whose whole island flies, not one up a shaft.
        validator.check(floor_index == 1, f"{travel_id}: {access_kind} station must use FloorIndex 1")

        family_counts[family] += 1
        equipment_counts[equipment_id] += 1
        access_counts[access_kind] += 1
        zone_counts[zone_id] += 1
        pair_counts[(zone_id, family)] += 1
        family_access_counts[(family, access_kind)] += 1

        base_parts = named_parts(station, "Base")
        anchors = named_parts(station, "TrainAnchor")
        exits = named_parts(station, "TrainExit")
        expected_copies = getattr(builder, "STATION_COPIES", 1)
        validator.check(
            len(base_parts) >= expected_copies,
            f"{travel_id}: expected at least {expected_copies} Base parts, found {len(base_parts)}",
        )
        validator.check(
            len(anchors) == expected_copies,
            f"{travel_id}: expected exactly {expected_copies} TrainAnchor parts, found {len(anchors)}",
        )
        validator.check(
            len(exits) == expected_copies,
            f"{travel_id}: expected {expected_copies} TrainExit parts, found {len(exits)}",
        )
        for copy_index in range(1, expected_copies + 1):
            copy_name = f"Spot{copy_index:02d}"
            copy_models = [
                node for node in station.get("children", [])
                if node.get("name") == copy_name and node.get("className") == "Model"
            ]
            validator.check(
                len(copy_models) == 1,
                f"{travel_id}: expected one self-contained {copy_name} model",
            )
            if len(copy_models) == 1:
                validator.check(
                    len(named_parts(copy_models[0], "TrainAnchor")) == 1
                    and len(named_parts(copy_models[0], "TrainExit")) == 1,
                    f"{travel_id}: {copy_name} must own exactly one TrainAnchor and one TrainExit",
                )

        load_visuals = [
            node for node in descendants(station)
            if node.get("attributes", {}).get("LoadVisualKind") is not None
        ]
        load_kinds = {
            node.get("attributes", {}).get("LoadVisualKind")
            for node in load_visuals
        }
        if equipment_id in getattr(builder, "FREE_WEIGHT_EQUIPMENT", set()):
            validator.check(
                bool(load_kinds & {"FreePlate", "DumbbellHead"}),
                f"{travel_id}: free-weight station has no responsive load visual",
            )
        if equipment_id in getattr(builder, "SELECTORISED_EQUIPMENT", set()):
            validator.check(
                "StackPlate" in load_kinds,
                f"{travel_id}: selectorised station has no sliced weight stack",
            )
        for visual in load_visuals:
            visual_attributes = visual.get("attributes", {})
            index = visual_attributes.get("LoadVisualIndex")
            count = visual_attributes.get("LoadVisualCount")
            validator.check(
                isinstance(index, int) and isinstance(count, int) and 1 <= index <= count,
                f"{travel_id}: invalid load visual index {index!r}/{count!r}",
            )
            validator.check(
                visual.get("properties", {}).get("CanCollide", True) is False,
                f"{travel_id}: load visual {visual.get('name')} must not collide",
            )

        for held in (node for node in descendants(station) if node.get("name") in HELD_NAMES):
            held_parts = [node for node in descendants(held) if is_base_part(node)]
            validator.check(bool(held_parts), f"{travel_id}: {held.get('name')} contains no BasePart")
            for held_part in held_parts:
                can_collide = held_part.get("properties", {}).get("CanCollide", True)
                validator.check(
                    can_collide is False,
                    f"{travel_id}: held prop {held_part.get('name', '<unnamed>')} must set CanCollide=false",
                )

    validator.check(set(station_by_id) == set(location_by_id), "station and location TravelId sets differ")
    for family in FAMILIES:
        validator.check(family_counts[family] == 7, f"{family}: expected seven stations, found {family_counts[family]}")

    zone_order = [row.get("zone") for row in getattr(builder, "DISTRICTS", [])]
    validator.check(len(zone_order) == 11, f"expected 11 DISTRICTS, found {len(zone_order)}")
    active_zone_order = zone_order[:EXPECTED_ACTIVE_TIERS]
    for zone_id in active_zone_order:
        validator.check(zone_counts[zone_id] == 5, f"{zone_id}: expected five stations, found {zone_counts[zone_id]}")
    validator.check(
        set(zone_counts) == set(active_zone_order),
        f"only the first seven tiers may be active, found {sorted(zone_counts)}",
    )
    validator.check(
        len(pair_counts) == EXPECTED_STATIONS and all(count == 1 for count in pair_counts.values()),
        "every active (zone, ExerciseFamily) pair must occur exactly once",
    )
    validator.check(
        set(equipment_counts) == set(family_by_equipment)
        and all(count == 1 for count in equipment_counts.values()),
        "the playable world must spawn every one of the 35 exercises exactly once",
    )

    zone_progression = parse_zone_progression()
    validator.check(len(zone_progression) == 11, f"expected 11 ZoneConfig rows, found {len(zone_progression)}")
    active_progression = zone_progression[:EXPECTED_ACTIVE_TIERS]
    validator.check(
        [zone_id for zone_id, _, _ in active_progression] == active_zone_order,
        "ZoneConfig and generator active tier order differ",
    )
    validator.check(
        [gain for _, _, gain in active_progression] == [1, 2, 4, 8, 16, 32, 64],
        "active GainMultiplier sequence must be exactly x1, x2, x4, x8, x16, x32, x64",
    )
    powers = [power for _, power, _ in active_progression]
    validator.check(powers[0] == 0 and all(a < b for a, b in zip(powers, powers[1:])), "active power gates must rise from zero")
    # Nothing is flight-gated. Every rooftop site carries its own fire escape, so
    # the whole gym is walkable and every station is a Street station.
    validator.check(
        len(sky_ids) == 0,
        f"nothing should be flight-gated any more, found {len(sky_ids)} Sky stations",
    )
    validator.check(access_counts["ThirdFloor"] == 0, "third-floor lofts were removed; none should remain")
    validator.check(
        access_counts["Street"] == EXPECTED_STATIONS,
        f"expected all {EXPECTED_STATIONS} stations to be reachable on foot, "
        f"found {access_counts['Street']}",
    )

    return station_by_id


def rotated_aabb(node: Node) -> tuple[float, float, float, float] | None:
    properties = node.get("properties", {})
    frame = properties.get("CFrame")
    size = properties.get("Size")
    if not isinstance(frame, list) or len(frame) != 12 or not isinstance(size, list) or len(size) != 3:
        return None
    half_x = abs(frame[3]) * size[0] / 2 + abs(frame[5]) * size[2] / 2
    half_z = abs(frame[9]) * size[0] / 2 + abs(frame[11]) * size[2] / 2
    return frame[0] - half_x, frame[0] + half_x, frame[2] - half_z, frame[2] + half_z


def floor_footprint(node: Node) -> tuple[float, float, list[tuple[float, float]], float] | None:
    """A flat visible part as a plan-view rectangle plus the height of its top face.

    Returns (centre_x, centre_z, [edge_a, edge_b], top_y) where the edges are half-extent
    vectors in the XZ plane. Built from the part's own axes rather than an axis-aligned
    box, because two neighbouring slabs inside a rotated building have overlapping
    bounding boxes while their actual footprints only touch.
    """
    properties = node.get("properties", {})
    frame = properties.get("CFrame")
    size = properties.get("Size")
    if not isinstance(frame, list) or len(frame) != 12 or not isinstance(size, list) or len(size) != 3:
        return None
    if float(properties.get("Transparency", 0) or 0) >= 0.95:
        return None

    # Columns of the rotation matrix are the part's own axes in world space.
    axes = [
        ((frame[3], frame[6], frame[9]), size[0] / 2),
        ((frame[4], frame[7], frame[10]), size[1] / 2),
        ((frame[5], frame[8], frame[11]), size[2] / 2),
    ]
    # The axis most nearly vertical is the thickness; the other two spread on the floor.
    axes.sort(key=lambda entry: abs(entry[0][1]), reverse=True)
    thickness_axis, half_thickness = axes[0]
    half_y = abs(thickness_axis[1]) * half_thickness
    if half_y > 3:
        return None

    spread = [((axis[0] * half, axis[2] * half)) for axis, half in axes[1:]]
    if min(math.hypot(*edge) for edge in spread) < 6:
        return None

    return frame[0], frame[2], spread, frame[1] + half_y


def footprints_overlap(a: Any, b: Any, slack: float) -> bool:
    """Separating-axis test between two plan-view rectangles."""
    ax, az, a_edges, _ = a
    bx, bz, b_edges, _ = b
    delta = (bx - ax, bz - az)
    for edges in (a_edges, b_edges):
        for edge in edges:
            length = math.hypot(*edge)
            if length < 1e-6:
                continue
            axis = (edge[0] / length, edge[1] / length)
            centre_gap = abs(delta[0] * axis[0] + delta[1] * axis[1])
            reach = 0.0
            for other in (a_edges, b_edges):
                for candidate in other:
                    reach += abs(candidate[0] * axis[0] + candidate[1] * axis[1])
            reach /= 2
            if centre_gap >= reach - slack:
                return False
    return True


def validate_no_emissive_floor_markings(validator: Validator, structure: Any) -> None:
    """Floor markings are paint, not light.

    The districts used to be lit by Neon strips laid on the ground -- a court stripe
    per bay and an accent line down each concourse -- which is what made the areas look
    like they were lit by lasers rather than by anything in the world. They are still
    there as markings; they must never go back to being emissive.
    """
    lit = []
    for node in walk(structure):
        name = node.get("name", "")
        if name not in ("MuscleStripe", "ConcourseLine", "MuscleCourtEdge"):
            continue
        if node.get("properties", {}).get("Material") == "Neon":
            lit.append(name)
    validator.check(
        not lit,
        f"floor markings must not be Neon: {sorted(set(lit))}",
    )


def validate_no_coplanar_floors(validator: Validator, payloads: Iterable[Any]) -> None:
    """Two floors at exactly the same height tear into a flickering checkerboard.

    The hub shipped like this: a 180-stud plaza lying on a 470-stud ground disc with both
    top faces at exactly FLOOR_TOP. Nothing in the generator looked wrong — every
    walkable surface is *meant* to top out at FLOOR_TOP so a machine placed there stands
    flush — which is why it survived review and had to be found by looking at the floor
    in a screenshot. A rule is cheaper than another pair of eyes.
    """
    surfaces: list[tuple[str, Any]] = []
    for payload in payloads:
        for node in walk(payload):
            if not is_base_part(node):
                continue
            found = floor_footprint(node)
            if found is not None:
                surfaces.append((str(node.get("name", "?")), found))

    # Only pairs sharing a top face can tear, so group by height first: comparing every
    # flat part with every other is thousands of times more work for the same answer.
    by_height: dict[int, list[tuple[str, Any]]] = {}
    for entry in surfaces:
        by_height.setdefault(round(entry[1][3] * 100), []).append(entry)

    slack = 4.0

    def x_span(footprint: Any) -> tuple[float, float]:
        """The part's extent along world X, widened by the overlap slack."""
        centre_x, _, edges, _ = footprint
        half = sum(abs(edge[0]) for edge in edges) + slack
        return centre_x - half, centre_x + half

    clashes: set[str] = set()
    for group in by_height.values():
        # A sweep along X instead of comparing every pair in the bucket.
        #
        # Height alone stopped being a useful filter once the city filled in: every
        # walkable surface is *meant* to top out at the same Y -- that is what the
        # docstring above is about -- so one bucket holds most of the world's flat
        # parts and the pair count grows as its square.
        #
        # Sorting by the left edge and retiring entries whose right edge is behind
        # the sweep is exact rather than approximate: two rectangles that do not
        # overlap along X cannot overlap at all, so no pair this skips could have
        # been a clash. Slack is folded into the span so a borderline pair is still
        # compared. Large parts (a 1,750-stud road tile) stay in the active set for
        # as long as they are genuinely wide, which is the honest cost.
        ordered = sorted(group, key=lambda entry: x_span(entry[1])[0])
        active: list[tuple[str, Any, float]] = []
        for name_b, b in ordered:
            b_min, b_max = x_span(b)
            active = [entry for entry in active if entry[2] >= b_min]
            for name_a, a, _ in active:
                if footprints_overlap(a, b, slack=slack):
                    clashes.add(f"{name_a} and {name_b} share a top face at y={a[3]:.3f}")
            active.append((name_b, b, b_max))

    validator.check(
        not clashes,
        "coplanar floor surfaces will z-fight: " + "; ".join(sorted(clashes)[:8]),
    )


def validate_monster_grounds(
    validator: Validator,
    builder: ModuleType,
    structure: Any,
    station_by_id: dict[str, Node],
) -> None:
    """Every tier gets one mob field and one boss arena, and neither touches a court.

    The overlap check is the one that matters. A hostile site drawn over a training
    court would put monsters on top of players who are anchored to a machine and
    cannot dodge — the exact situation safe zones exist to prevent — and it is an easy
    mistake to make by nudging one offset constant.
    """
    tier_zones = {row["zone"] for row in getattr(builder, "DISTRICTS", [])[:7]}

    for tag, radius_attr in (("MobField", "MOB_FIELD_RADIUS"), ("BossArena", "BOSS_ARENA_RADIUS")):
        markers = [node for node in walk(structure) if tag in tags(node)]
        validator.check(
            len(markers) == len(tier_zones),
            f"expected one {tag} per tier ({len(tier_zones)}), found {len(markers)}",
        )

        seen: set[str] = set()
        expected_radius = getattr(builder, radius_attr, None)
        for marker in markers:
            attributes = marker.get("attributes", {})
            zone_id = attributes.get("ZoneId")
            validator.check(
                zone_id in tier_zones,
                f"{tag} marker carries unknown ZoneId {zone_id!r}",
            )
            validator.check(zone_id not in seen, f"{tag} placed twice for zone {zone_id!r}")
            seen.add(zone_id)
            validator.check(
                attributes.get("Radius") == expected_radius,
                f"{tag} for {zone_id!r} has radius {attributes.get('Radius')!r},"
                f" expected {expected_radius!r}",
            )

            centre = position(marker)
            if centre is None or expected_radius is None:
                continue
            for station_id, station in station_by_id.items():
                station_centre = position(station) or (
                    position(named_parts(station, "Base")[0])
                    if named_parts(station, "Base")
                    else None
                )
                if station_centre is None:
                    continue
                gap = math.hypot(
                    centre[0] - station_centre[0], centre[2] - station_centre[2]
                )
                validator.check(
                    gap > expected_radius,
                    f"{tag} for {zone_id!r} overlaps training station {station_id}"
                    f" ({gap:.0f} studs from a {expected_radius}-stud site)",
                )


def validate_irregular_map(
    validator: Validator,
    builder: ModuleType,
    structure: Any,
    station_by_id: dict[str, Node],
) -> None:
    features = [node for node in walk(structure) if "MapFeature" in tags(node)]
    land = [node for node in features if node.get("attributes", {}).get("MapKind") == "Land"]
    water = [node for node in features if node.get("attributes", {}).get("MapKind") == "Water"]
    roads = [node for node in features if node.get("attributes", {}).get("MapKind") == "Road"]
    validator.check(len(features) <= MAX_MAP_FEATURES, f"MapFeature budget exceeded: {len(features)} > {MAX_MAP_FEATURES}")
    validator.check(len(land) >= 6, f"the city needs at least six Land features, found {len(land)}")
    validator.check(
        len(roads) >= 20,
        f"the connected city needs a visible road network, found {len(roads)} Road features",
    )
    validate_monster_grounds(validator, builder, structure, station_by_id)

    connector_names = {"RoadNetwork", "LandCorridor"}
    connectors = [node for node in walk(structure) if node.get("name") in connector_names]
    validator.check(len(connectors) == 0, f"the coast still has {len(connectors)} connector nodes")
    water_size = getattr(builder, "WORLD_WATER_SIZE", (0, 0))
    expected_water_tiles = (
        math.ceil(water_size[0] / 1800) * math.ceil(water_size[1] / 1800)
        if len(water_size) == 2 else 0
    )
    validator.check(
        len(water) == expected_water_tiles,
        f"walkable ocean must contain {expected_water_tiles} safe-sized tiles, found {len(water)}",
    )
    for node in water:
        validator.check(
            node.get("properties", {}).get("CanCollide", True) is True,
            f"{node.get('name', '<water>')}: water must be walkable",
        )

    regions = getattr(builder, "REGIONS", [])
    validator.check(
        len(regions) == EXPECTED_ISLANDS,
        f"expected {EXPECTED_ISLANDS} landmass, found {len(regions)}",
    )

    venue_types = {area.get("venue_type") for area in getattr(builder, "AREAS", [])}
    expected_venues = {"Park", "Beach", "Dock", "City", "Office", "Sky"}
    validator.check(
        venue_types == expected_venues,
        f"city multiplier districts should be {sorted(expected_venues)}, found {sorted(venue_types)}",
    )

    decorative_stones = [
        node for node in walk(structure)
        if node.get("name") in {"Rock", "Boulder", "RockTip"}
    ]
    validator.check(
        not decorative_stones,
        f"decorative stones remain beside city training areas: {len(decorative_stones)} parts",
    )

    plate_trees = [node for node in walk(structure) if node.get("name") == "PlateTreeBase"]
    validator.check(
        len(plate_trees) == 2,
        f"the hub carries the one pair of organized plate trees; found {len(plate_trees)}",
    )

    # Spawn must stand on the landmass. default.project.json pins the SpawnLocation
    # at the world origin, so the mainland has to be positioned around it rather
    # than the other way round — get this wrong and players spawn over open water.
    for region in regions:
        centre_x, centre_z = region.get("center", (0, 0))
        width, depth = region.get("size", (0, 0))
        validator.check(
            abs(0 - centre_x) <= width / 2 and abs(0 - centre_z) <= depth / 2,
            f"{region['id']} does not cover the world origin, where players spawn",
        )

    # Ten steps per flight, and a coast this long needs more than one way up out of
    # the sea or a player knocked in at the far end swims the length of the map.
    expected_steps = sum(
        len(region.get("shore_offsets", (0,))) * 10
        for region in regions if not region.get("flight_only")
    )
    shore_steps = [node for node in walk(structure) if str(node.get("name", "")).startswith("ShoreStep_")]
    validator.check(
        len(shore_steps) == expected_steps,
        f"the coast needs {expected_steps} shore steps, found {len(shore_steps)}",
    )
    for node in shore_steps:
        validator.check(
            node.get("properties", {}).get("CanCollide", True) is True,
            f"{node.get('name', '<step>')}: shore access must be walkable",
        )


    water_models = [node for node in walk(structure) if node.get("attributes", {}).get("WalkableWater") is True]
    validator.check(len(water_models) == 1, f"expected one persistent walkable-water model, found {len(water_models)}")
    if len(water_models) == 1:
        validator.check(
            water_models[0].get("properties", {}).get("ModelStreamingMode") == "Persistent",
            "walkable water must stream persistently",
        )

    boundaries = [node for node in walk(structure) if node.get("attributes", {}).get("WorldBoundary") is True]
    validator.check(len(boundaries) == 1, f"expected one persistent world boundary, found {len(boundaries)}")
    if len(boundaries) == 1:
        boundary_parts = [node for node in descendants(boundaries[0]) if is_base_part(node)]
        boundary_attributes = boundaries[0].get("attributes", {})
        expected_boundary_parts = 2 * (
            int(boundary_attributes.get("XSegments", 0))
            + int(boundary_attributes.get("ZSegments", 0))
        )
        validator.check(
            len(boundary_parts) == expected_boundary_parts,
            f"world boundary needs {expected_boundary_parts} safe-sized walls, found {len(boundary_parts)}",
        )
        validator.check(
            boundaries[0].get("properties", {}).get("ModelStreamingMode") == "Persistent",
            "world boundary must stream persistently",
        )
        for node in boundary_parts:
            validator.check(
                node.get("properties", {}).get("CanCollide", True) is True,
                f"{node.get('name', '<boundary>')}: world boundary must collide",
            )

    land_bounds = [bounds for node in land if (bounds := rotated_aabb(node)) is not None]
    validator.check(len(land_bounds) == len(land), "every Land MapFeature must have a valid CFrame and Size")
    if land_bounds:
        global_min_x = min(bounds[0] for bounds in land_bounds)
        global_max_x = max(bounds[1] for bounds in land_bounds)
        global_min_z = min(bounds[2] for bounds in land_bounds)
        global_max_z = max(bounds[3] for bounds in land_bounds)
        global_width = max(global_max_x - global_min_x, 1)
        global_depth = max(global_max_z - global_min_z, 1)
        # The city is deliberately coastal: wide enough for a real waterfront and
        # deep enough to hold inland blocks, a park and the office district.
        validator.check(global_width >= 15000, f"the expanded coast is only {global_width:.0f} studs long")
        validator.check(global_depth >= 8500, f"the expanded city is only {global_depth:.0f} studs deep")
        validator.check(
            global_width >= global_depth * 1.5,
            "the landmass should read as a coastal city, not a square continent",
        )

    shapes = {node.get("attributes", {}).get("MapShape") for node in land}
    validator.check("Circle" in shapes and "Rect" in shapes, "Land silhouette must mix circular and rectangular features")

    areas = sorted(getattr(builder, "AREAS", []), key=lambda area: area.get("sequence", math.inf))
    if areas:
        area_x = [float(area.get("x", 0)) for area in areas]
        area_z = [float(area.get("z", 0)) for area in areas]
        validator.check(
            max(area_x) - min(area_x) >= 12000,
            "multiplier districts do not use enough of the enlarged city's width",
        )
        validator.check(
            max(area_z) - min(area_z) >= 5500,
            "multiplier districts still occupy a shallow line instead of the city's depth",
        )
        z_directions = [math.copysign(1, b - a) for a, b in zip(area_z, area_z[1:]) if b != a]
        turns = sum(a != b for a, b in zip(z_directions, z_directions[1:]))
        validator.check(
            turns >= 2,
            "progression route needs at least two inland/coastward turns; it is still visually linear",
        )

    station_positions: dict[str, tuple[float, float, float]] = {}
    for travel_id, station in station_by_id.items():
        exits = named_parts(station, "TrainExit")
        at = position(exits[0]) if exits else None
        if at is not None:
            station_positions[travel_id] = at
    x_levels = {round(at[0], 1) for at in station_positions.values()}
    z_levels = {round(at[2], 1) for at in station_positions.values()}
    validator.check(len(x_levels) >= 25, f"station layout has only {len(x_levels)} distinct X levels")
    validator.check(len(z_levels) >= 25, f"station layout has only {len(z_levels)} distinct Z levels")
    position_rows = list(station_positions.items())
    for index, (travel_id, at) in enumerate(position_rows):
        for other_id, other_at in position_rows[index + 1:]:
            separation = math.hypot(at[0] - other_at[0], at[2] - other_at[2])
            validator.check(
                separation >= 48,
                f"{travel_id} and {other_id} are only {separation:.1f} studs apart",
            )

    sky_ids = [
        travel_id
        for travel_id, station in station_by_id.items()
        if station.get("attributes", {}).get("AccessKind") == "Sky"
    ]
    for sky_id in sky_ids:
        sky_at = station_positions.get(sky_id)
        if sky_at is None:
            continue
        nearest_id: str | None = None
        nearest = math.inf
        for other_id, other_at in station_positions.items():
            if other_id == sky_id:
                continue
            distance = math.hypot(sky_at[0] - other_at[0], sky_at[2] - other_at[2])
            if distance < nearest:
                nearest, nearest_id = distance, other_id
        validator.check(
            nearest >= MIN_SKY_PIN_SEPARATION,
            f"{sky_id}: map pin is only {nearest:.1f} studs from {nearest_id}; minimum is {MIN_SKY_PIN_SEPARATION:.0f}",
        )


def validate_world_foundation(
    validator: Validator,
    structure: Any,
    machines: Any,
) -> None:
    foundations = [
        node
        for node in walk(structure)
        if node.get("attributes", {}).get("PlayableFoundation") is True
    ]
    validator.check(
        len(foundations) == 1,
        f"expected exactly one playable world foundation, found {len(foundations)}",
    )
    if len(foundations) != 1:
        return

    foundation = foundations[0]
    attributes = foundation.get("attributes", {})
    width = attributes.get("FoundationWidth")
    depth = attributes.get("FoundationDepth")
    center_x = attributes.get("FoundationCenterX")
    center_z = attributes.get("FoundationCenterZ")
    validator.check(
        foundation.get("name") == "WorldFoundation",
        "playable foundation must keep the stable WorldFoundation name",
    )
    validator.check(
        foundation.get("className") == "Model",
        "WorldFoundation must be a tiled Model, not an oversized BasePart",
    )
    validator.check(
        foundation.get("properties", {}).get("ModelStreamingMode") == "Persistent",
        "WorldFoundation must stream persistently",
    )
    validator.check(
        isinstance(width, (int, float))
        and isinstance(depth, (int, float))
        and width >= 17800
        and depth >= 11800,
        "WorldFoundation must be at least 17,800 x 11,800 studs for the expanded city",
    )
    validator.check(
        isinstance(center_x, (int, float)) and isinstance(center_z, (int, float)),
        "WorldFoundation needs numeric center attributes",
    )
    if not all(isinstance(value, (int, float)) for value in (width, depth, center_x, center_z)):
        return

    min_x = center_x - width / 2
    max_x = center_x + width / 2
    min_z = center_z - depth / 2
    max_z = center_z + depth / 2
    tiles = [node for node in descendants(foundation) if is_base_part(node)]
    columns = attributes.get("TileColumns")
    rows = attributes.get("TileRows")
    expected_columns = math.ceil(width / 1800)
    expected_rows = math.ceil(depth / 1800)
    validator.check(
        columns == expected_columns
        and rows == expected_rows
        and len(tiles) == expected_columns * expected_rows,
        f"WorldFoundation must contain a {expected_columns} x {expected_rows} safe-sized tile grid, "
        f"found {len(tiles)} tiles",
    )
    tile_bounds = [bounds for tile in tiles if (bounds := rotated_aabb(tile)) is not None]
    validator.check(len(tile_bounds) == len(tiles), "every foundation tile needs valid geometry")
    if tile_bounds:
        validator.check(
            abs(min(bounds[0] for bounds in tile_bounds) - min_x) <= 0.1
            and abs(max(bounds[1] for bounds in tile_bounds) - max_x) <= 0.1
            and abs(min(bounds[2] for bounds in tile_bounds) - min_z) <= 0.1
            and abs(max(bounds[3] for bounds in tile_bounds) - max_z) <= 0.1,
            "foundation tiles do not cover the declared world boundary",
        )
        tile_area = sum((bounds[1] - bounds[0]) * (bounds[3] - bounds[2]) for bounds in tile_bounds)
        validator.check(
            abs(tile_area - width * depth) <= max(1, width * depth * 1e-6),
            "foundation tiles contain gaps or overlap in their declared footprint",
        )

    for tile in tiles:
        size = tile.get("properties", {}).get("Size", [0, 0, 0])
        validator.check(
            max(float(size[0]), float(size[1]), float(size[2])) <= 2048,
            f"{tile.get('name', '<foundation tile>')} exceeds Roblox's 2,048-stud BasePart limit",
        )

    for payload in (structure, machines):
        for node in walk(payload):
            if not is_base_part(node):
                continue
            bounds = rotated_aabb(node)
            if bounds is None:
                continue
            validator.check(
                bounds[0] >= min_x - 0.05
                and bounds[1] <= max_x + 0.05
                and bounds[2] >= min_z - 0.05
                and bounds[3] <= max_z + 0.05,
                f"{node.get('name', '<part>')}: geometry extends outside WorldFoundation",
            )


def validate_movement_bounds(validator: Validator, builder: ModuleType) -> None:
    """Keep movement correction aligned with the generator's physical perimeter."""
    center_x = parse_movement_number("FLIGHT_WORLD_CENTER_X")
    center_z = parse_movement_number("FLIGHT_WORLD_CENTER_Z")
    half_width = parse_movement_number("FLIGHT_WORLD_HALF_WIDTH")
    half_depth = parse_movement_number("FLIGHT_WORLD_HALF_DEPTH")
    world_center_x, world_center_z = builder.WORLD_CENTER
    water_width, water_depth = builder.WORLD_WATER_SIZE

    validator.check(
        center_x == world_center_x and center_z == world_center_z,
        "MovementConfig flight bounds must use the generated WorldBoundary center",
    )
    validator.check(
        half_width == water_width / 2 - 10 and half_depth == water_depth / 2 - 10,
        "MovementConfig flight bounds must stay ten studs inside the generated WorldBoundary",
    )


def validate_instance_budgets(validator: Validator, payloads: Iterable[Any]) -> tuple[int, int]:
    instance_count = 0
    base_part_count = 0
    for payload in payloads:
        for node in walk(payload):
            if "className" not in node:
                continue
            instance_count += 1
            if is_base_part(node):
                base_part_count += 1
    validator.check(instance_count <= MAX_INSTANCES, f"instance budget exceeded: {instance_count} > {MAX_INSTANCES}")
    validator.check(base_part_count <= MAX_BASE_PARTS, f"BasePart budget exceeded: {base_part_count} > {MAX_BASE_PARTS}")
    return instance_count, base_part_count


def validate_machine_detail(validator: Validator, machines: Any) -> None:
    """Every machine carries enough geometry to read as finished, and not so much
    that the global budget is at risk -- plus exactly the lighting it is allowed."""
    seen = 0
    for node in walk(machines):
        attributes = node.get("attributes") or {}
        equipment_id = attributes.get("EquipmentId")
        if not isinstance(equipment_id, str):
            continue
        seen += 1

        parts = 0
        lights = 0
        shadowing = []
        for child in descendants(node):
            if is_base_part(child):
                parts += 1
            class_name = child.get("className")
            if class_name in ("PointLight", "SpotLight", "SurfaceLight"):
                lights += 1
                if child.get("properties", {}).get("Shadows"):
                    shadowing.append(child.get("name"))

        validator.check(
            parts >= MIN_MACHINE_PARTS,
            f"{equipment_id}: {parts} parts is below the detail floor of {MIN_MACHINE_PARTS}",
        )
        validator.check(
            parts <= MAX_MACHINE_PARTS,
            f"{equipment_id}: {parts} parts exceeds the per-machine cap of {MAX_MACHINE_PARTS}",
        )
        validator.check(
            lights <= MAX_MACHINE_LIGHTS,
            f"{equipment_id}: {lights} lights exceeds the per-machine cap of {MAX_MACHINE_LIGHTS}",
        )
        validator.check(
            not shadowing,
            f"{equipment_id}: shadow-casting machine light(s) {shadowing}",
        )

    validator.check(seen > 0, "no machines found to check detail budgets against")


def validate_building_budget(validator: Validator, payloads: Iterable[Any]) -> None:
    """No single building may run away with the world budget.

    Cheap to check and worth checking: the generator picks heights and setback
    counts at random, and a bad interaction between those two is the kind of bug
    that shows up as one 400-part tower somewhere in sixteen thousand studs of
    city rather than as anything obviously wrong.
    """
    worst_name, worst_count = "", 0
    for payload in payloads:
        for node in walk(payload):
            if node.get("name") != "Building" or node.get("className") != "Model":
                continue
            count = sum(1 for child in descendants(node) if is_base_part(child))
            if count > worst_count:
                worst_name, worst_count = node.get("name", "?"), count
    validator.check(
        worst_count <= MAX_BUILDING_PARTS,
        f"a building holds {worst_count} parts, over the {MAX_BUILDING_PARTS} cap ({worst_name})",
    )


# Scattered sites are landmarks, not bays in a shed. The old 48-stud floor was a
# cluster-internal figure -- the gap between two machines on one campus -- and it
# says nothing useful once each machine is its own destination.
MIN_SITE_SEPARATION = 700

# Ground level, and the tallest a single ramped flight may climb. Both are read
# off the builder's own constants at check time where possible; these are the
# fallbacks the checks compare against.
FLOOR_TOP_GUESS = 1.0
# Roblox humanoids walk anything under 89 degrees, but a player steering up a
# ramp at 45 slides off the sides; this is the comfortable-walking limit.
MAX_RAMP_PITCH = 40.0


def validate_scatter_separation(validator: Validator, builder: ModuleType) -> None:
    """The scattered thirty are the right number, far enough apart, and off the road.

    Thirty, not thirty-five: the starter tier rings the spawn plaza and is checked
    by validate_garage_ring against its own, deliberately different rule.

    Checked against the selector directly rather than against the built world, so
    the placement is provably sound before any geometry is moved onto it.
    """
    try:
        sites = builder.scatter_sites()
    except Exception as error:  # a selector that cannot run is a failure, not a crash
        validator.fail(f"scatter_sites() raised {type(error).__name__}: {error}")
        return

    expected = builder.SCATTERED_SITE_COUNT
    validator.check(
        len(sites) == expected,
        f"scatter_sites returned {len(sites)} sites, expected {expected}",
    )

    worst, worst_pair = math.inf, None
    for index, a in enumerate(sites):
        for b in sites[index + 1:]:
            gap = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
            if gap < worst:
                worst, worst_pair = gap, (a, b)
    if worst_pair is not None:
        a, b = worst_pair
        validator.check(
            worst >= MIN_SITE_SEPARATION,
            f"two training sites are {worst:.0f} studs apart, under the "
            f"{MIN_SITE_SEPARATION} floor: ({a['x']:.0f}, {a['z']:.0f}) and "
            f"({b['x']:.0f}, {b['z']:.0f})",
        )

    on_road = [s for s in sites if not builder._off_road(s["x"], s["z"])]
    validator.check(
        not on_road,
        "training sites standing in the roadway: "
        + ", ".join(f"({s['x']:.0f}, {s['z']:.0f})" for s in on_road[:5]),
    )

    roofs = [s for s in sites if s["kind"] == "roof"]
    too_high = [s for s in roofs
                if s["top"] - builder.FLOOR_TOP > builder.MAX_ROOF_SITE_HEIGHT]
    validator.check(
        not too_high,
        f"rooftop sites above the {builder.MAX_ROOF_SITE_HEIGHT}-stud climb limit: "
        + ", ".join(f"({s['x']:.0f}, {s['z']:.0f}) at {s['top']:.0f}" for s in too_high[:5]),
    )


def validate_station_zone_volumes(
    validator: Validator, builder: ModuleType, structure: Any, stations: dict[str, Node]
) -> None:
    """Every machine stands in exactly one zone volume, and it is the right one.

    This is the check that keeps tier gating honest once machines are scattered.
    A machine's multiplier is not a property of the machine -- ZoneConfig.AtPosition
    resolves it from whichever tagged GymZone volume the player is standing in, and
    when two volumes overlap it takes the one with the *highest* multiplier. While
    the gym was seven campuses that could not happen. Scattered across a city it
    can, and the symptom would be a x1 machine quietly paying x64.
    """
    zone_order = [row["zone"] for row in builder.DISTRICTS[:EXPECTED_ACTIVE_TIERS]]

    volumes = []
    for node in walk(structure):
        if "GymZone" not in tags(node):
            continue
        spot = position(node)
        size = node.get("properties", {}).get("Size")
        zone_id = (node.get("attributes") or {}).get("ZoneId")
        if spot is None or not isinstance(size, list):
            continue
        volumes.append((node.get("name", "?"), zone_id, spot, size))

    validator.check(
        len(volumes) == EXPECTED_STATIONS,
        f"expected one zone volume per station, found {len(volumes)}",
    )

    # Overlap, tested as axis-aligned boxes. Every volume in this world is axis
    # aligned in XZ up to the site yaw, and a slightly conservative test is the
    # right bias: a false positive is a nudge, a false negative is a silent
    # multiplier upgrade.
    clashes = []
    for index, (name_a, zone_a, pos_a, size_a) in enumerate(volumes):
        for name_b, zone_b, pos_b, size_b in volumes[index + 1:]:
            if zone_a == zone_b:
                continue
            if (abs(pos_a[0] - pos_b[0]) * 2 < size_a[0] + size_b[0]
                    and abs(pos_a[2] - pos_b[2]) * 2 < size_a[2] + size_b[2]):
                clashes.append(f"{name_a} ({zone_a}) overlaps {name_b} ({zone_b})")
    validator.check(
        not clashes,
        "zone volumes of different tiers overlap, which silently upgrades a "
        "machine's multiplier: " + "; ".join(clashes[:4]),
    )

    # And each station is actually inside the volume carrying its own tier.
    for travel_id, station in stations.items():
        zone_id = travel_id.split("-")[0]
        base = named_parts(station, "Base")
        if not base:
            continue
        spot = position(base[0])
        if spot is None:
            continue
        covering = [
            (name, vzone) for name, vzone, pos, size in volumes
            if abs(spot[0] - pos[0]) * 2 <= size[0]
            and abs(spot[2] - pos[2]) * 2 <= size[2]
        ]
        validator.check(
            any(vzone == zone_id for _, vzone in covering),
            f"{travel_id}: not inside a {zone_id} zone volume "
            f"(covered by {[v for _, v in covering] or 'nothing'}) -- "
            "a machine outside its volume is dropped from the map and refused by Travel",
        )
        validator.check(
            zone_id in zone_order,
            f"{travel_id}: zone {zone_id} is not one of the active tiers",
        )


# What a monster's swing is worth, as a share of the health a player at that tier
# actually has. These are the shares the rows are written from.
THIEF_DAMAGE_SHARE = 0.08
BOSS_DAMAGE_SHARE = 0.25

# How many punches a monster is worth, against a player entering its tier.
#
# This is the only unit that means anything for monster health: a punch does damage
# equal to the attacker's Arms, and a tier's entry stat IS their Arms at that point.
# Health used to be the tier gate over twenty, which sounds like a difficulty curve and
# is not -- it made every thief above the starter field die in a single punch and every
# boss in three.
THIEF_PUNCHES = 8
BOSS_PUNCHES = 60
PUNCH_TOLERANCE = 0.15
# Rounded rows will not hit the share exactly; this is wide enough for that and far
# too narrow to let a tier drift back to a different curve.
DAMAGE_SHARE_TOLERANCE = 0.005


def _luau_number(text: str) -> float:
    return float(text.replace("_", ""))


def _luau_number_table(source: str, name: str) -> dict[str, float]:
    """The `{ Zone = number }` tables MobConfig keys its per-tier rules by."""
    body = re.search(name + r": \{ \[string\]: number \} = \{(.*?)\n\}", source, re.S)
    if body is None:
        return {}
    return {
        key: _luau_number(value)
        for key, value in re.findall(r"(\w+) = ([\d_.e+]+)", body.group(1))
    }


def read_mob_rows() -> tuple[list[dict[str, Any]], dict[str, float], dict[str, float]]:
    """Every monster, parsed from its factory call.

    MobConfig cannot join selftest.luau -- it requires MuscleClassConfig through
    ReplicatedStorage, which the bare `luau` CLI cannot resolve -- so its numbers are
    checked here instead, the same way extract_balance.py reads the configs it needs.
    """
    source = MOB_CONFIG_PATH.read_text(encoding="utf-8")
    patterns = {
        "Normal": r'thief\("(\w+)",\s*"([^"]+)",\s*([\d_.e+]+),\s*([\d_.e+]+),\s*([\d_.e+]+)\)',
        "Boss": r'boss\("(\w+)",\s*"([^"]+)",\s*([\d_.e+]+),\s*([\d_.e+]+),\s*([\d_.e+]+)\)',
    }
    rows: list[dict[str, Any]] = []
    for kind, pattern in patterns.items():
        for match in re.finditer(pattern, source):
            rows.append(
                {
                    "kind": kind,
                    "zone": match.group(1),
                    "name": match.group(2),
                    "health": _luau_number(match.group(3)),
                    "damage": _luau_number(match.group(4)),
                    "reward": _luau_number(match.group(5)),
                }
            )
    return rows, _luau_number_table(source, "TIER_CAP"), _luau_number_table(source, "TIER_ATTACK")


def read_weight_gates() -> dict[str, tuple[float, float]]:
    """Each tier's entry stat and its ceiling, from WeightConfig."""
    source = WEIGHT_CONFIG_PATH.read_text(encoding="utf-8")
    gates: dict[str, tuple[float, float]] = {}
    for match in re.finditer(
        r'ZoneId = "(\w+)",\s*RequiredStat = ([\d_.e+]+).*?MaxRequiredStat = ([\d_.e+]+)',
        source,
        re.S,
    ):
        gates[match.group(1)] = (_luau_number(match.group(2)), _luau_number(match.group(3)))
    return gates


def validate_mob_rig(validator: Validator) -> None:
    """The monster skeleton hangs together, and speaks the joint names poses use.

    A rig is only useful if every joint chains back to the root and every ornament
    hangs off a part that exists -- a typo in either is silent at runtime, because a
    joint whose parent is missing is simply skipped and the limb never appears.
    """
    source = MOB_RIG_CONFIG_PATH.read_text(encoding="utf-8")

    bones = re.findall(r'\{ Name = "(\w+)", Shape = "(\w+)", Size', source)
    bone_names = {name for name, _ in bones}
    joints = re.findall(
        r'Name = "(\w+)",\s*\n?\s*Part0 = "(\w+)",\s*\n?\s*Part1 = "(\w+)"', source
    )
    decor = re.findall(r'Name = "(\w+)",\s*\n?\s*Parent = "(\w+)"', source)

    validator.check(bool(bones), "the mob rig defines no bones")
    validator.check(bool(joints), "the mob rig defines no joints")

    # Every joint's parent must already exist, and every bone must be reachable from
    # the root -- an unreachable bone floats at the origin.
    reachable = {"HumanoidRootPart"}
    for name, part0, part1 in joints:
        validator.check(
            part0 in reachable or part0 in bone_names,
            f"joint {name} hangs off {part0}, which is not a part of the rig",
        )
        validator.check(part1 in bone_names, f"joint {name} moves {part1}, which is not a bone")
        reachable.add(part1)

    stranded = bone_names - reachable
    validator.check(not stranded, f"bones no joint ever moves: {sorted(stranded)}")

    for name, parent in decor:
        validator.check(
            parent in bone_names or parent == "HumanoidRootPart",
            f"ornament {name} hangs off {parent}, which is not a part of the rig",
        )

    # The point of using the stock R15 names is that the player's gait drives a thief
    # untranslated. If a rename ever breaks that, the mob simply stops walking.
    gait_source = ROOT / "src" / "ReplicatedStorage" / "Modules" / "GaitConfig.luau"
    listed = re.search(r"GaitConfig\.Joints = \{(.*?)\n\}", gait_source.read_text(encoding="utf-8"), re.S)
    if listed is not None:
        wanted = set(re.findall(r'"(\w+)"', listed.group(1)))
        have = {name for name, _, _ in joints}
        # Ankles are deliberately absent; PosePlayback skips a joint a rig lacks.
        missing = wanted - have - {"LeftAnkle", "RightAnkle"}
        validator.check(
            not missing,
            f"the mob rig cannot be driven by the shared gait, missing {sorted(missing)}",
        )


def validate_mob_strikes(validator: Validator) -> None:
    """A monster's two swings are whole clips.

    StrikeConfig carries its own RunSelfTest asserting exactly this, but it reaches
    ReplicatedStorage through game:GetService and so cannot run headless. The stage
    portions have to total one or the clip runs short or long, which is precisely the
    arithmetic slip hand-authored poses invite.
    """
    source = STRIKE_CONFIG_PATH.read_text(encoding="utf-8")
    durations: dict[str, float] = {}
    contact_fractions: dict[str, float] = {}
    for strike_id in ("MobSwing", "MobUltimate", "PunchJab", "PunchCross", "PunchFinish"):
        block = re.search(
            r'Id = "' + strike_id + r'",(.*?)\n\t\},\n', source, re.S
        )
        if block is None:
            validator.fail(f"{strike_id} is missing from StrikeConfig")
            continue
        portions = [float(p) for p in re.findall(r"transition\(([\d.]+),", block.group(1))]
        validator.check(bool(portions), f"{strike_id} has no stages")
        total = sum(portions)
        validator.check(
            abs(total - 1) < 1e-6,
            f"{strike_id} stage portions total {total:g}, not 1 -- the clip runs "
            f"{'short' if total < 1 else 'long'}",
        )
        contacts = [float(c) for c in re.findall(r"Contacts = \{ ([\d.]+)", block.group(1))]
        for contact in contacts:
            validator.check(
                0 < contact < 1, f"{strike_id} lands its contact at {contact:g}, outside the clip"
            )
        durations[strike_id] = _strike_duration(source, strike_id)
        if contacts:
            contact_fractions[strike_id] = contacts[0]

    validate_punch_timing(validator, durations, contact_fractions)


def _strike_duration(source: str, strike_id: str) -> float:
    found = re.search(r'Id = "' + strike_id + r'",.*?Duration = ([\d.]+)', source, re.S)
    return float(found.group(1)) if found is not None else 0.0


def validate_punch_timing(
    validator: Validator, durations: dict[str, float], contacts: dict[str, float]
) -> None:
    """The couplings between the punch clips and the ability that fires them.

    StrikeConfig asserts these in its own RunSelfTest, which nothing can run: it reaches
    ReplicatedStorage through game:GetService, so the bare luau CLI cannot load it. They
    are real constraints -- retiming a punch without them silently either fires the next
    swing before this one has landed, or leaves a gap where the animation has finished
    and the input has not come back.
    """
    jab_duration = durations.get("PunchJab", 0)
    jab_contact = jab_duration * contacts.get("PunchJab", 0)

    ability = ABILITY_CONFIG_PATH.read_text(encoding="utf-8")
    found = re.search(r'Id = "Punch",.*?Cooldown = ([\d.]+)', ability, re.S)
    if found is None:
        validator.fail("could not read the Punch cooldown")
        return
    cooldown = float(found.group(1))

    validator.check(
        cooldown > jab_contact,
        f"the punch cooldown {cooldown:g}s fires before the jab lands at {jab_contact:.3f}s",
    )
    validator.check(
        cooldown < jab_duration,
        f"the punch cooldown {cooldown:g}s outlasts the jab clip {jab_duration:g}s, "
        f"leaving a gap with no animation",
    )
    validator.check(
        durations.get("PunchFinish", 0) > jab_duration,
        "the finisher must be a longer clip than the jab",
    )


def validate_mob_roster(validator: Validator) -> None:
    """Every monster, normal and boss, against the rules the curve is built from.

    Mob numbers have been hand-edited a lot and nothing checked them. Two of the bugs
    that reached a play session -- damage sitting at 0.04% of tier health above Garage,
    and monsters resolved against an attacker stat that did not exist -- were both a
    wrong number in a row that compiled, linted and type-checked perfectly.
    """
    rows, tier_cap, tier_attack = read_mob_rows()
    gates = read_weight_gates()
    source_for_factories = MOB_CONFIG_PATH.read_text(encoding="utf-8")

    tiers = [zone for zone in gates if zone in tier_cap]
    validator.check(
        len(rows) == 2 * len(tiers),
        f"expected one thief and one boss per active tier ({2 * len(tiers)}), found {len(rows)}",
    )

    seen: Counter[str] = Counter(f"{row['zone']}{row['kind']}" for row in rows)
    duplicates = [key for key, count in seen.items() if count > 1]
    validator.check(not duplicates, f"duplicate monster rows: {duplicates}")

    for row in rows:
        zone, kind, label = row["zone"], row["kind"], f"{row['name']} ({row['zone']})"
        if zone not in gates:
            validator.fail(f"{label} belongs to a tier WeightConfig does not know")
            continue

        entry_stat, ceiling = gates[zone]
        validator.check(row["health"] > 0, f"{label} has no health")
        validator.check(row["damage"] > 0, f"{label} deals no damage")
        validator.check(row["reward"] > 0, f"{label} pays nothing")

        # Back blocks against this; when it was missing entirely, every player above
        # ten Core was immune to every monster in the game.
        validator.check(
            tier_attack.get(zone) == ceiling,
            f"{label} attack stat {tier_attack.get(zone)} is not its tier ceiling {ceiling}",
        )

        player_health = 100 + entry_stat * 10
        share = row["damage"] / player_health
        want = BOSS_DAMAGE_SHARE if kind == "Boss" else THIEF_DAMAGE_SHARE
        validator.check(
            abs(share - want) <= DAMAGE_SHARE_TOLERANCE,
            f"{label} deals {share:.2%} of tier health, wanted about {want:.0%}",
        )

    # Both currencies double per tier, and so does the class bonus each tier accepts.
    for kind in ("Normal", "Boss"):
        ordered = [row for zone in tiers for row in rows if row["zone"] == zone and row["kind"] == kind]
        for previous, current in zip(ordered, ordered[1:]):
            validator.check(
                current["reward"] == previous["reward"] * 2,
                f"{current['name']} pays {current['reward']:g}, not double {previous['name']}'s "
                f"{previous['reward']:g}",
            )

    for previous, current in zip(tiers, tiers[1:]):
        validator.check(
            tier_cap.get(current) == tier_cap.get(previous, 0) * 2,
            f"{current} reward cap {tier_cap.get(current)} is not double {previous}'s "
            f"{tier_cap.get(previous)}",
        )

    # Health, counted in punches. Garage is exempt: its entry stat is zero, and no
    # multiple of zero says anything about how long a fight lasts. It is checked against
    # its own literals instead, because the starter tier spans Arms 0 to 10,000 and no
    # single number is right across all of it -- it is hand-picked to be beatable at one
    # damage a punch.
    for zone in tiers:
        thief = next((r for r in rows if r["zone"] == zone and r["kind"] == "Normal"), None)
        boss = next((r for r in rows if r["zone"] == zone and r["kind"] == "Boss"), None)
        if thief is None or boss is None:
            validator.fail(f"{zone} is missing a thief or a boss")
            continue

        entry_stat = gates[zone][0]
        if entry_stat <= 0:
            validator.check(
                thief["health"] <= 30,
                f"the starter thief has {thief['health']:g} health, too much to beat at "
                f"one damage a punch",
            )
            continue

        for row, wanted in ((thief, THIEF_PUNCHES), (boss, BOSS_PUNCHES)):
            punches = row["health"] / entry_stat
            validator.check(
                abs(punches - wanted) <= wanted * PUNCH_TOLERANCE,
                f"{row['name']} takes {punches:.1f} punches from a player entering "
                f"{zone}, wanted about {wanted}",
            )

    # The boss heavy. The wind-up has to be shorter than the cooldown or a boss would
    # start the next one before finishing the last, and its reach has to beat its normal
    # swing or standing still would be the safest place to be.
    boss_body = re.search(r"local function boss\(.*?\n\treturn \{(.*?)\n\t\}", source_for_factories, re.S)
    if boss_body is None:
        validator.fail("could not read the boss factory")
    else:
        ult = {k: _luau_number(v) for k, v in re.findall(r"(Ultimate\w+) = ([\d_.e+]+),", boss_body.group(1))}
        for field in ("UltimateCooldown", "UltimateWindup", "UltimateRadius", "UltimateMultiplier"):
            validator.check(ult.get(field, 0) > 0, f"a boss has no {field}")
        validator.check(
            ult.get("UltimateWindup", 0) < ult.get("UltimateCooldown", 0),
            f"the boss wind-up {ult.get('UltimateWindup')} must fit inside its cooldown "
            f"{ult.get('UltimateCooldown')}",
        )

    # Shared behaviour, read off the two factories rather than the rows.
    #
    # Speed is checked against the player's, not against zero. A thief ran at 14 and a
    # boss at 12 while a player walks at 16, so neither could close on anyone who was
    # moving and a whole arena read as empty. "Faster than nothing" is not the contract;
    # "able to catch someone walking away" is.
    walk_speed = re.search(r"Formulas\.BASE_WALK_SPEED = ([\d_.e+]+)", FORMULAS_PATH.read_text(encoding="utf-8"))
    player_walk = _luau_number(walk_speed.group(1)) if walk_speed else 16.0

    source = MOB_CONFIG_PATH.read_text(encoding="utf-8")
    speeds: dict[str, float] = {}
    for factory in ("thief", "boss"):
        body = re.search(
            r"local function " + factory + r"\(.*?\n\treturn \{(.*?)\n\t\}", source, re.S
        )
        if body is None:
            validator.fail(f"could not read the {factory} factory")
            continue
        fields = {k: _luau_number(v) for k, v in re.findall(r"(\w+) = ([\d_.e+]+),", body.group(1))}
        aggro, leash = fields.get("AggroRadius", 0), fields.get("LeashRadius", 0)
        validator.check(
            0 < aggro < leash,
            f"{factory} aggro radius {aggro} must be positive and inside its leash {leash}",
        )
        validator.check(fields.get("AttackRange", 0) > 0, f"{factory} cannot reach anything")
        validator.check(fields.get("AttackCooldown", 0) > 0, f"{factory} has no attack cooldown")

        speed = fields.get("WalkSpeed", 0)
        speeds[factory] = speed
        validator.check(
            speed > player_walk,
            f"{factory} walks at {speed:g}, no faster than a player at {player_walk:g} — "
            f"it can never catch anyone",
        )

    validator.check(
        speeds.get("boss", 0) > speeds.get("thief", 0),
        f"a boss at {speeds.get('boss', 0):g} must outrun its field thieves at "
        f"{speeds.get('thief', 0):g}",
    )


def validate_hostile_scatter(validator: Validator, builder: ModuleType) -> None:
    """Mob fields and boss arenas are spread, and clear of every training court.

    A court is the one place in this game that has to be safe -- a player is
    anchored to a machine for minutes at a time and cannot dodge. That is why a
    fight is somewhere you choose to walk to, and why this clearance is a rule
    rather than a preference.
    """
    # All 35 courts, matching what the builder does: the starter ring is where new
    # players train and must be kept as clear of hostile ground as anywhere else.
    stations = builder.scatter_sites() + builder.garage_ring_sites()
    sites = builder.scatter_hostile_sites(stations)

    validator.check(len(sites) == 14, f"expected 14 hostile sites, found {len(sites)}")

    worst, pair = math.inf, None
    for index, a in enumerate(sites):
        for b in sites[index + 1:]:
            gap = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
            if gap < worst:
                worst, pair = gap, (a, b)
    if pair is not None:
        validator.check(
            worst >= builder.MIN_HOSTILE_SEPARATION,
            f"two hostile sites are {worst:.0f} studs apart, under the "
            f"{builder.MIN_HOSTILE_SEPARATION} floor",
        )

    crowding = [
        (site, station) for site in sites for station in stations
        if math.hypot(site["x"] - station["x"], site["z"] - station["z"])
        < builder.HOSTILE_STATION_CLEARANCE
    ]
    validator.check(
        not crowding,
        "hostile sites crowding a training court: "
        + ", ".join(f"({s['x']:.0f}, {s['z']:.0f})" for s, _ in crowding[:4]),
    )


def validate_roof_access(validator: Validator, structure: Any) -> None:
    """Every elevated training site has a stair a player can actually walk up.

    The whole reason rooftop sites are allowed is that they are reachable on
    foot. That promise is geometry, and geometry drifts: a stair whose top
    landing stops short of the roof, or whose flights leave a gap, looks
    completely correct in a screenshot and is a wall in play.

    Checked per site folder rather than by proximity, because a wide roof puts
    its stair at the edge -- up to 200 studs from the machine at the centre --
    and a radius search either misses it or catches a neighbour's.
    """
    for node in walk(structure):
        if node.get("className") != "Folder":
            continue
        # Direct children only. Every ancestor folder also *contains* a roof floor
        # somewhere beneath it, and walking descendants would run this check on the
        # whole world wrapper and report the same fault under four different names.
        pieces = list(node.get("children", []))
        # The court's own floor, not the machine's TrainAnchor: the anchor lives in
        # the Machines payload and is not reachable from here, and the floor is the
        # surface the stair actually has to deliver you onto anyway.
        floors = [p for p in pieces if str(p.get("name", "")).endswith("RoofFloor")]
        if not floors:
            continue
        spot = position(floors[0])
        if spot is None:
            continue

        name = node.get("name", "?")
        landings = []
        for piece in pieces:
            if piece.get("name") not in ("StairLanding", "StairTopLanding", "StairFlight"):
                continue
            where = position(piece)
            if where is None:
                continue
            if piece.get("properties", {}).get("CanCollide") is False:
                validator.fail(f"{name}: {piece['name']} is non-collidable; a stair you fall through")
            if piece.get("name") != "StairFlight":
                landings.append(where[1])

        validator.check(landings, f"{name}: elevated site with no stair at all")
        if not landings:
            continue

        landings.sort()
        validator.check(
            landings[0] <= FLOOR_TOP_GUESS + 4,
            f"{name}: the stair starts {landings[0]:.1f} studs up, not at the pavement",
        )

        # Pitch, not rise. A single straight ramp climbs the whole height in one
        # go, so how far it rises says nothing; how steeply it does says
        # everything. Read off the ramp's own up-axis: its world Y component is
        # the cosine of the pitch.
        for piece in pieces:
            if piece.get("name") != "StairFlight":
                continue
            frame = piece.get("properties", {}).get("CFrame")
            if not isinstance(frame, list) or len(frame) != 12:
                continue
            pitch = math.degrees(math.acos(max(-1.0, min(1.0, abs(frame[7])))))
            validator.check(
                pitch <= MAX_RAMP_PITCH,
                f"{name}: a ramp pitches {pitch:.1f} degrees, over the "
                f"{MAX_RAMP_PITCH} a player can comfortably walk",
            )
        validator.check(
            abs(landings[-1] - spot[1]) <= 10,
            f"{name}: the stair tops out at {landings[-1]:.1f} but the machine is at "
            f"{spot[1]:.1f} -- the climb does not reach the court",
        )


# The starter ring is a plaza, not a scatter, so it gets its own numbers rather
# than an exemption from MIN_SITE_SEPARATION. Weakening 700 to accommodate it
# would silently permit two x64 machines to be built ninety studs apart on
# opposite sides of the map, which is the thing that rule exists to stop.
MIN_RING_SEPARATION = 80
MIN_RING_SAFE_ZONE_GAP = 30
MAX_RING_WALK = 220
# Half the diagonal of a 44x42 court, so the clearance holds at any yaw.
COURT_HALF_DIAGONAL = 30.4


def validate_garage_ring(validator: Validator, builder: ModuleType) -> None:
    """The five starter machines ring the spawn plaza, outside the safe zone.

    Every other machine is chosen from whatever the city generator built. These
    five are the one place that has to be somewhere specific: a player who has
    just spawned has no Tokens and no travel, so if the starter tier drifts back
    out into the map there is nothing to do on the first visit.
    """
    sites = builder.garage_ring_sites()
    validator.check(
        len(sites) == len(builder.FAMILY_ORDER),
        f"the starter ring should hold one machine per muscle, found {len(sites)}",
    )
    validator.check(
        all(site["kind"] == "ground" for site in sites),
        "starter machines must stand at street level; a new player cannot be asked "
        "to find a fire escape before they have trained anything",
    )

    for site in sites:
        walk = math.hypot(site["x"], site["z"])
        validator.check(
            walk <= MAX_RING_WALK,
            f"a starter machine is {walk:.0f} studs from spawn, past the "
            f"{MAX_RING_WALK} that still reads as ringing the plaza",
        )

        # Outside the safe-zone box, measured to the court's corner. Inside it,
        # TokenService pays nothing -- "no pay where you cannot be hit" -- so a
        # starter gym in the safe zone would grow stats while earning none of the
        # currency that buys multipliers.
        reach = max(abs(site["x"]), abs(site["z"])) - COURT_HALF_DIAGONAL
        validator.check(
            reach >= builder.SAFE_ZONE_HALF + MIN_RING_SAFE_ZONE_GAP,
            f"a starter court reaches {reach:.0f} studs from spawn, inside or too "
            f"near the {builder.SAFE_ZONE_HALF}-stud safe zone, where training earns "
            "no Tokens",
        )

        validator.check(
            builder._off_road(site["x"], site["z"]),
            f"a starter machine stands in the roadway at ({site['x']:.0f}, {site['z']:.0f})",
        )

        # Clear of the campus slab, whose top face sits 0.02 studs from a court's.
        validator.check(
            site["z"] + COURT_HALF_DIAGONAL < 15,
            f"a starter court at z {site['z']:.0f} overlaps the campus floor, whose "
            "top face is close enough to a court's to z-fight",
        )

    for index, a in enumerate(sites):
        for b in sites[index + 1:]:
            gap = math.hypot(a["x"] - b["x"], a["z"] - b["z"])
            validator.check(
                gap >= MIN_RING_SEPARATION,
                f"two starter machines are {gap:.0f} studs apart, under the "
                f"{MIN_RING_SEPARATION} that keeps their zone volumes from touching",
            )

    # The two pools must never interleave, or a scattered machine could land in
    # the ring and its volume overlap a starter one -- a cross-tier overlap, which
    # ZoneConfig resolves by taking the higher multiplier.
    for site in sites:
        for other in builder.scatter_sites():
            gap = math.hypot(site["x"] - other["x"], site["z"] - other["z"])
            validator.check(
                gap > COURT_HALF_DIAGONAL * 2,
                f"a scattered machine sits {gap:.0f} studs from a starter one",
            )


# What "the buildings all look the same" looks like as a number. Before the
# archetype work the city had 438 buildings sharing two part-name signatures, 70%
# of them identical -- and every check passed, because nothing was measuring
# variety. These are the checks that would have caught it.
MIN_BUILDING_SIGNATURES = 24
MAX_SIGNATURE_SHARE = 0.30
MIN_WALL_MATERIALS = 7
# The skyline is deliberately tall and a variety change must not quietly flatten
# it. Measured before this work: 81% of buildings over 100 studs.
MIN_TALL_BUILDING_SHARE = 0.70


def validate_building_variety(validator: Validator, structure: Any) -> None:
    """The city is built from many kinds of building, not one kind repainted.

    Signature here means the set of part names a building is made of, which is a
    good proxy for "is this a different building": two buildings with the same
    parts differ only in size and colour, which is exactly the sameness this
    measures.
    """
    signatures: Counter[tuple[str, ...]] = Counter()
    materials: Counter[str] = Counter()
    tall = 0
    total = 0

    for node in walk(structure):
        if node.get("className") != "Model" or node.get("name") != "Building":
            continue
        total += 1
        names = set()
        top = 0.0
        for child in node.get("children", []):
            names.add(str(child.get("name")))
            properties = child.get("properties", {})
            frame, size = properties.get("CFrame"), properties.get("Size")
            if child.get("name") in ("Slab", "Shaft", "Prism", "Drum", "Hall",
                                     "Tier", "Monolith", "Wing"):
                materials[str(properties.get("Material"))] += 1
            if isinstance(frame, list) and len(frame) == 12 and isinstance(size, list):
                half = (abs(frame[4]) * size[0] / 2 + abs(frame[7]) * size[1] / 2
                        + abs(frame[10]) * size[2] / 2)
                top = max(top, frame[1] + half)
        signatures[tuple(sorted(names))] += 1
        if top >= 100:
            tall += 1

    validator.check(total > 0, "no buildings found to measure variety against")
    if total == 0:
        return

    validator.check(
        len(signatures) >= MIN_BUILDING_SIGNATURES,
        f"the city is built from only {len(signatures)} distinct kinds of building, "
        f"under the {MIN_BUILDING_SIGNATURES} that stops it reading as one repeated",
    )

    common, count = signatures.most_common(1)[0]
    share = count / total
    validator.check(
        share <= MAX_SIGNATURE_SHARE,
        f"{share * 100:.0f}% of buildings are the same kind, over the "
        f"{MAX_SIGNATURE_SHARE * 100:.0f}% cap; the commonest is {sorted(common)[:6]}",
    )

    validator.check(
        len(materials) >= MIN_WALL_MATERIALS,
        f"only {len(materials)} wall materials in the whole city, under "
        f"{MIN_WALL_MATERIALS}",
    )

    tall_share = tall / total
    validator.check(
        tall_share >= MIN_TALL_BUILDING_SHARE,
        f"only {tall_share * 100:.0f}% of buildings clear 100 studs, under the "
        f"{MIN_TALL_BUILDING_SHARE * 100:.0f}% floor -- variety must not flatten "
        "the skyline",
    )


def validate_roof_site_pool(validator: Validator, builder: ModuleType) -> None:
    """There are enough flat roofs to put the rooftop gyms on.

    scatter_sites falls back to open ground when the roof pool is short. It does
    not fail, it does not warn -- the world just quietly stops having rooftop
    gyms, which is exactly what happened the moment the short archetypes all grew
    pitched roofs: ten rooftop sites became zero and every check still passed.
    """
    builder.city_grid()
    roofs = [site for site in builder.site_candidates() if site["kind"] == "roof"]
    needed = builder.ROOF_SITE_QUOTA
    validator.check(
        len(roofs) >= needed + 8,
        f"only {len(roofs)} flat roofs can carry a training court, against a quota "
        f"of {needed}; scatter_sites would fall back to the ground without saying so",
    )


def validate_map_truthfulness(validator: Validator, machines: Any) -> None:
    """What the map says about a machine matches the machine.

    This exists because the map lied for two tasks and nothing noticed. Every
    coordinate was correct the whole time; the fault was in what the map was told
    to display and where it chose to draw it, which no check was looking at.

    So: the muscle a station advertises is the muscle its equipment trains, its
    location name is not a stale stock phrase, and the point the map sends a
    player to is next to the machine rather than somewhere else entirely.
    """
    # Read from EquipmentConfig.luau, which is what the game itself uses, so this
    # is a genuine cross-check between the shipped config and the built world
    # rather than the world agreeing with itself.
    families = {
        equipment_id: fields["ExerciseFamily"]
        for equipment_id, fields in parse_equipment_config().items()
    }
    stale = ("Civic Park Gym", "Boardwalk Barbell Club", "Freight Yard Strength",
             "Titan Square", "Apex Office Gym", "Stormline Rooftop")

    seen = 0
    for node in walk(machines):
        attributes = node.get("attributes") or {}
        equipment_id = attributes.get("EquipmentId")
        if not isinstance(equipment_id, str):
            continue
        seen += 1
        travel_id = str(attributes.get("TravelId", "?"))

        advertised = attributes.get("ExerciseFamily")
        actual = families.get(equipment_id)
        validator.check(
            actual is None or advertised == actual,
            f"{travel_id}: the map calls it {advertised} but {equipment_id} trains {actual}",
        )

        name = str(attributes.get("LocationName", ""))
        validator.check(
            name != "" and not any(dead in name for dead in stale),
            f"{travel_id}: location name {name!r} names a place that no longer exists",
        )

        # The landing point is what the map sends you to. It has to be at the
        # machine, not merely somewhere in the same district.
        anchor = named_parts(node, "TrainAnchor")
        landing = named_parts(node, "TrainExit")
        if anchor and landing:
            here, there = position(anchor[0]), position(landing[0])
            if here is not None and there is not None:
                gap = math.hypot(here[0] - there[0], here[2] - there[2])
                validator.check(
                    gap <= 120,
                    f"{travel_id}: the map lands a player {gap:.0f} studs from the machine",
                )

    validator.check(seen > 0, "no stations found to check the map against")


def validate_streaming_density(validator: Validator, payloads: Iterable[Any]) -> None:
    """No single streaming bubble may carry too much.

    Bucketed over four half-cell-offset lattices rather than one: a dense cluster
    sitting astride a cell boundary splits evenly between two cells and hides from
    a single grid, which is precisely the hotspot worth finding.

    Y is ignored. The world is a plane -- everything stands on one ground height --
    so a third axis would only ever divide by one.
    """
    placed: list[tuple[float, float, str]] = []
    for payload in payloads:
        for node in walk(payload):
            if not is_base_part(node):
                continue
            spot = position(node)
            if spot is not None:
                placed.append((spot[0], spot[2], str(node.get("name", "?"))))

    worst_count = 0
    worst_cell: tuple[float, float] | None = None
    worst_names: Counter[str] = Counter()

    half = STREAM_CELL // 2
    for offset_x, offset_z in ((0, 0), (half, 0), (0, half), (half, half)):
        cells: dict[tuple[int, int], list[str]] = {}
        for x, z, name in placed:
            key = (int((x + offset_x) // STREAM_CELL), int((z + offset_z) // STREAM_CELL))
            cells.setdefault(key, []).append(name)
        for (cell_x, cell_z), names in cells.items():
            if len(names) > worst_count:
                worst_count = len(names)
                worst_cell = (
                    (cell_x + 0.5) * STREAM_CELL - offset_x,
                    (cell_z + 0.5) * STREAM_CELL - offset_z,
                )
                worst_names = Counter(names)

    # Name the place and what is in it. "Some cell is too dense" is not something
    # anyone can act on across a sixteen-thousand-stud map.
    where = f"({worst_cell[0]:.0f}, {worst_cell[1]:.0f})" if worst_cell else "nowhere"
    detail = ", ".join(f"{name} x{count}" for name, count in worst_names.most_common(5))
    validator.check(
        worst_count <= MAX_PARTS_PER_STREAM_CELL,
        f"streaming density exceeded: {worst_count} parts in one {STREAM_CELL}-stud cell "
        f"near {where} (cap {MAX_PARTS_PER_STREAM_CELL}); densest: {detail}",
    )


def validate_committed_payload(
    validator: Validator,
    generated: Any,
    path: Path,
    label: str,
) -> None:
    try:
        committed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        validator.fail(f"{label}: could not read committed JSON: {error}")
        return
    if committed != generated:
        generated_hash = short_hash(canonical_json(generated))
        committed_hash = short_hash(canonical_json(committed))
        validator.fail(
            f"{label}: committed JSON is stale "
            f"(generated {generated_hash}, committed {committed_hash}); run scripts/build_gym.py"
        )


# Solid props are cover, and cover is short. Anything taller becomes a ladder: the
# lofts sit at 24 and a stack of climbable scenery beside a hall wall is a way onto
# a roof the layout never meant to be standing room.
SOLID_PROP_HEIGHT_CAP = 20.0
# Nothing collidable may crowd the spot a player is teleported onto and locked into.
# TrainingService pivots the character to the TrainAnchor; a block intersecting that
# is a character wedged inside geometry with WalkSpeed zeroed.
MIN_ANCHOR_PROP_CLEARANCE = 10.0
# Deliberately solid non-structural geometry. Kept as an explicit list so adding a
# collidable prop is a decision recorded here, not a silent obstacle.
INTENTIONAL_SOLID_PROPS = {
    "VenueCover",
    "RackUpright", "LockerBank", "GymBenchPad", "GymBenchFrame", "FountainBody",
}


def clutter_part_names(builder: ModuleType) -> set[str]:
    """Every part name the city prop builders can emit, by running them."""
    import random

    names: set[str] = set()
    rng = random.Random("validator:clutter-names")
    for factory in builder.CITY_PROPS.values():
        for _attempt in range(12):
            for piece in factory(rng, [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]):
                names.update(node.get("name") for node in walk(piece))
    return {name for name in names if isinstance(name, str)}


def validate_scenery_collision(
    validator: Validator,
    builder: ModuleType,
    structure: Any,
    machines: Any,
    stations: list[Node],
) -> None:
    """Collision is opt-in for scenery, and what opts in has to stay usable cover."""
    solid_scenery = set(builder.SOLID_CITY_PROPS)
    clutter_names = clutter_part_names(builder)

    # Whether a part collides is decided by its name, so a name shared between a
    # scenery builder and a machine builder makes the policy ambiguous — and a
    # machine's own frame legitimately stands right on its TrainAnchor, which is
    # exactly what the clearance check below forbids for props.
    machine_names = {
        node.get("name") for node in walk(machines) if is_base_part(node)
    }
    shared = (solid_scenery | INTENTIONAL_SOLID_PROPS | clutter_names) & machine_names
    validator.check(
        not shared,
        f"scenery/furniture names collide with machine part names: {sorted(shared)}; "
        "rename the scenery side",
    )

    unknown = solid_scenery - clutter_names
    validator.check(
        not unknown,
        f"SOLID_CITY_PROPS names no city prop builder emits: {sorted(unknown)}",
    )

    collidable: list[Node] = []
    seen_solid: set[str] = set()
    must_not_collide = clutter_names - solid_scenery
    for node in walk(structure):
        if not is_base_part(node):
            continue
        if node.get("properties", {}).get("CanCollide", True) is not True:
            continue
        name = node.get("name")
        validator.check(
            name not in must_not_collide,
            f"scenery {name} must not collide: only {sorted(solid_scenery)} are cover",
        )
        if name in solid_scenery or name in INTENTIONAL_SOLID_PROPS:
            collidable.append(node)
            seen_solid.add(name)

    missing = solid_scenery - seen_solid
    validator.check(
        not missing,
        f"SOLID_CITY_PROPS entries never reach the world as collidable: {sorted(missing)}",
    )

    for node in collidable:
        size = node.get("properties", {}).get("Size")
        if not isinstance(size, list) or len(size) != 3:
            continue
        validator.check(
            float(size[1]) <= SOLID_PROP_HEIGHT_CAP,
            f"solid prop {node.get('name')} is {size[1]} tall, over the "
            f"{SOLID_PROP_HEIGHT_CAP} cap that keeps cover from becoming a ladder",
        )

    anchors = [
        anchor_position
        for station in stations
        for anchor in named_parts(station, "TrainAnchor")
        if (anchor_position := position(anchor)) is not None
    ]
    for node in collidable:
        spot = position(node)
        size = node.get("properties", {}).get("Size")
        if spot is None or not isinstance(size, list) or len(size) != 3:
            continue
        radius = max(float(size[0]), float(size[2])) / 2
        for anchor_x, _anchor_y, anchor_z in anchors:
            validator.check(
                math.hypot(spot[0] - anchor_x, spot[2] - anchor_z)
                >= MIN_ANCHOR_PROP_CLEARANCE + radius,
                f"solid prop {node.get('name')} at {spot[0]:.1f},{spot[2]:.1f} is "
                f"inside the {MIN_ANCHOR_PROP_CLEARANCE}-stud clearance around a "
                "TrainAnchor",
            )


# A held prop is only moved onto the player's hands while a set is running;
# the rest of the time it sits where the machine builder authored it, in full view.
# So it has to be authored somewhere that reads as storage — in the rack hooks, on
# a shelf, at the end of its own cable — and not hanging in mid-air. This is the
# separation still counted as the prop touching the machine.
MAX_HELD_PROP_DETACHMENT = 0.4


def _obb_bounds(node: Node) -> tuple[float, ...] | None:
    """Axis-aligned bounds of a rotated box."""
    frame = node.get("properties", {}).get("CFrame")
    size = node.get("properties", {}).get("Size")
    if not isinstance(frame, list) or len(frame) != 12:
        return None
    if not isinstance(size, list) or len(size) != 3:
        return None
    rot = frame[3:12]
    half = [
        sum(abs(float(rot[row * 3 + col])) * float(size[col]) / 2 for col in range(3))
        for row in range(3)
    ]
    return (
        frame[0] - half[0], frame[0] + half[0],
        frame[1] - half[1], frame[1] + half[1],
        frame[2] - half[2], frame[2] + half[2],
    )


def _box_separation(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    """Distance between two boxes; zero when they overlap or touch."""
    worst = 0.0
    for lo_a, hi_a, lo_b, hi_b in (
        (a[0], a[1], b[0], b[1]), (a[2], a[3], b[2], b[3]), (a[4], a[5], b[4], b[5])
    ):
        if hi_a < lo_b:
            worst = max(worst, lo_b - hi_a)
        elif hi_b < lo_a:
            worst = max(worst, lo_a - hi_b)
    return worst


def validate_held_props_rest_on_machine(
    validator: Validator, stations: list[Node]
) -> None:
    """No barbell, handle or dumbbell may hang in the air attached to nothing."""
    for station in stations:
        held_groups: list[Node] = []
        statics: list[tuple[float, ...]] = []

        def sort_node(node: Node, inside_held: bool) -> None:
            name = node.get("name")
            if not inside_held and name in HELD_NAMES:
                held_groups.append(node)
                inside_held = True
            elif not inside_held and is_base_part(node) and name not in (
                "TrainAnchor", "TrainExit"
            ):
                box = _obb_bounds(node)
                if box is not None:
                    statics.append(box)
            for child in node.get("children", []):
                sort_node(child, inside_held)

        sort_node(station, False)
        if not statics:
            continue

        for group in held_groups:
            boxes = [
                box for node in walk(group)
                if is_base_part(node) and (box := _obb_bounds(node)) is not None
            ]
            if not boxes:
                continue
            merged = (
                min(b[0] for b in boxes), max(b[1] for b in boxes),
                min(b[2] for b in boxes), max(b[3] for b in boxes),
                min(b[4] for b in boxes), max(b[5] for b in boxes),
            )
            nearest = min(_box_separation(merged, box) for box in statics)
            validator.check(
                nearest <= MAX_HELD_PROP_DETACHMENT,
                f"{station.get('name')}: {group.get('name')} rests "
                f"{nearest:.2f} studs from the nearest part of its own machine; "
                "a held prop must sit in a hook, on a shelf, or on its cable",
            )


def validate_load_visual_steps(validator: Validator, stations: list[Node]) -> None:
    """Every selectable kg step must have a deterministic physical visual state."""
    stepped_kinds = {"BodyPlate", "FreePlate", "StackPlate"}
    for station in stations:
        indexes: dict[str, set[int]] = {}
        for node in walk(station):
            attributes = node.get("attributes", {})
            kind = attributes.get("LoadVisualKind")
            if not isinstance(kind, str):
                continue
            index = attributes.get("LoadVisualIndex")
            count = attributes.get("LoadVisualCount")
            validator.check(
                isinstance(index, int) and isinstance(count, int),
                f"{station.get('name')}/{node.get('name')}: load visual index/count must be integers",
            )
            if not isinstance(index, int) or not isinstance(count, int):
                continue
            validator.check(
                1 <= index <= count,
                f"{station.get('name')}/{node.get('name')}: load visual {index}/{count} is invalid",
            )
            if kind in stepped_kinds:
                validator.check(
                    count == 10,
                    f"{station.get('name')}/{kind}: expected ten visible load steps, got {count}",
                )
                indexes.setdefault(kind, set()).add(index)
        for kind, found in indexes.items():
            validator.check(
                found == set(range(1, 11)),
                f"{station.get('name')}/{kind}: visible steps are {sorted(found)}, expected 1-10",
            )

        # State 10 is the maximum selected load. Every held body stack and every
        # free-weight implement must show multiple real discs there; one enlarged
        # red cylinder is not a valid substitute for a two-plate configuration.
        for held in (node for node in walk(station) if node.get("name") in HELD_NAMES):
            by_kind: dict[str, list[Node]] = {}
            for visual in walk(held):
                attributes = visual.get("attributes", {})
                if attributes.get("LoadVisualIndex") != 10:
                    continue
                kind = attributes.get("LoadVisualKind")
                if kind in {"BodyPlate", "FreePlate"}:
                    by_kind.setdefault(kind, []).append(visual)
                    validator.check(
                        isinstance(attributes.get("PlateKg"), (int, float)),
                        f"{station.get('name')}/{visual.get('name')}: Olympic disc is missing PlateKg",
                    )
            for kind, maximum in by_kind.items():
                validator.check(
                    len(maximum) >= 2,
                    f"{station.get('name')}/{held.get('name')}/{kind}: "
                    f"maximum load shows {len(maximum)} disc(s), expected at least two",
                )


def run() -> int:
    validator = Validator()
    try:
        builder = load_builder()
        first_structure, first_machines = builder.build_connected_world()
        second_structure, second_machines = builder.build_connected_world()
        first_canonical = canonical_json((first_structure, first_machines))
        second_canonical = canonical_json((second_structure, second_machines))
        validator.check(
            first_canonical == second_canonical,
            "build_connected_world is not deterministic across two in-memory builds",
        )

        # Split the built world exactly the way the build does, using the build's own
        # function: a validator that sorted the environments its own way would be
        # checking a world that is never written.
        first_city, first_districts = builder.split_structure(first_structure)
        validate_committed_payload(validator, first_city, CITY_PATH, "Structure/City.model.json")
        validate_committed_payload(
            validator, first_districts, DISTRICTS_PATH, "Structure/Districts.model.json"
        )
        validate_committed_payload(validator, first_machines, MACHINES_PATH, "Machines.model.json")
        validate_finite_geometry(validator, (first_structure, first_machines))
        family_by_equipment = validate_equipment_tables(validator, builder)
        validate_poses(validator, parse_equipment_config())
        stations = [node for node in walk(first_machines) if "TrainingStation" in tags(node)]
        station_by_id = validate_locations(validator, builder, stations, family_by_equipment)
        validate_held_props_rest_on_machine(validator, stations)
        validate_load_visual_steps(validator, stations)
        validate_irregular_map(validator, builder, first_structure, station_by_id)
        validate_world_foundation(validator, first_structure, first_machines)
        validate_movement_bounds(validator, builder)
        validate_no_coplanar_floors(validator, (first_structure, first_machines))
        validate_no_emissive_floor_markings(validator, first_structure)
        validate_scenery_collision(
            validator, builder, first_structure, first_machines, stations
        )
        validate_machine_detail(validator, first_machines)
        validate_streaming_density(validator, (first_structure, first_machines))
        validate_building_budget(validator, (first_structure,))
        validate_building_variety(validator, first_structure)
        validate_roof_site_pool(validator, builder)
        validate_map_truthfulness(validator, first_machines)
        validate_scatter_separation(validator, builder)
        validate_garage_ring(validator, builder)
        validate_station_zone_volumes(validator, builder, first_structure, station_by_id)
        validate_hostile_scatter(validator, builder)
        validate_mob_roster(validator)
        validate_mob_rig(validator)
        validate_mob_strikes(validator)
        validate_roof_access(validator, first_structure)
        instance_count, base_part_count = validate_instance_budgets(
            validator,
            (first_structure, first_machines),
        )
    except Exception as error:  # A broken generator should still produce one clear result.
        validator.fail(f"validator could not inspect the world: {type(error).__name__}: {error}")
        instance_count = 0
        base_part_count = 0
        first_canonical = ""

    if validator.failures:
        print(f"Gym validation FAILED ({len(validator.failures)} issue(s)):", file=sys.stderr)
        for index, failure in enumerate(validator.failures, 1):
            print(f"  {index:>2}. {failure}", file=sys.stderr)
        return 1

    print(
        "Gym validation passed: "
        f"35 destinations / {35 * getattr(builder, 'STATION_COPIES', 1)} usable stations, "
        f"7 tiers x 5 muscles / 35 unique exercises, "
        f"{instance_count} instances, "
        f"{base_part_count} BaseParts, build {short_hash(first_canonical)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
