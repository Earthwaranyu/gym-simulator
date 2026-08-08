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
STRUCTURE_PATH = ROOT / "src" / "Workspace" / "Gym" / "Structure.model.json"
MACHINES_PATH = ROOT / "src" / "Workspace" / "Gym" / "Machines.model.json"

FAMILIES = ("Chest", "Arms", "Back", "Core", "Legs")
ACCESS_KINDS = {"Street", "ThirdFloor", "Sky"}
HELD_NAMES = {"HeldBoth", "HeldRight", "HeldLeft"}
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
EXPECTED_SKY_STATIONS = 5
MIN_SKY_PIN_SEPARATION = 32.0
MAX_MAP_FEATURES = 400
MAX_BASE_PARTS = 7_000
MAX_INSTANCES = 9_000

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
                f"{equipment_id}: BaseGain must equal RepInterval for exactly +1/s base rate",
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

        expected_access = "Sky" if location.get("style") == "sky" else (
            "ThirdFloor" if location.get("style") == "tower" else "Street"
        )
        validator.check(access_kind == expected_access, f"{travel_id}: AccessKind should be {expected_access}")
        validator.check(
            requires_flight == bool(location.get("requires_flight")),
            f"{travel_id}: RequiresFlight differs from layout",
        )
        if access_kind == "Sky":
            sky_ids.append(travel_id)
            validator.check(requires_flight is True, f"{travel_id}: Sky station must require flight")
        if access_kind == "ThirdFloor":
            validator.check(floor_index == 3, f"{travel_id}: ThirdFloor station must use FloorIndex 3")
        else:
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
        validator.check(bool(base_parts), f"{travel_id}: machine has no Base part")
        validator.check(bool(anchors), f"{travel_id}: machine has no TrainAnchor part")
        validator.check(bool(exits), f"{travel_id}: machine has no TrainExit part")

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
        validator.check(family_access_counts[(family, "Sky")] == 1, f"{family}: expected one Sky destination")
        validator.check(
            family_access_counts[(family, "ThirdFloor")] == 1,
            f"{family}: expected one ThirdFloor destination",
        )

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
    validator.check(
        len(sky_ids) == EXPECTED_SKY_STATIONS,
        f"expected {EXPECTED_SKY_STATIONS} Sky stations, found {len(sky_ids)}",
    )
    validator.check(access_counts["ThirdFloor"] == 5, "expected five third-floor training locations")
    validator.check(access_counts["Street"] == 25, "expected 25 street/interior training locations")

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


def validate_irregular_map(
    validator: Validator,
    structure: Any,
    station_by_id: dict[str, Node],
) -> None:
    features = [node for node in walk(structure) if "MapFeature" in tags(node)]
    land = [node for node in features if node.get("attributes", {}).get("MapKind") == "Land"]
    validator.check(len(features) <= MAX_MAP_FEATURES, f"MapFeature budget exceeded: {len(features)} > {MAX_MAP_FEATURES}")
    validator.check(len(land) >= 10, f"irregular map needs at least ten Land features, found {len(land)}")

    land_bounds = [bounds for node in land if (bounds := rotated_aabb(node)) is not None]
    validator.check(len(land_bounds) == len(land), "every Land MapFeature must have a valid CFrame and Size")
    if land_bounds:
        global_min_x = min(bounds[0] for bounds in land_bounds)
        global_max_x = max(bounds[1] for bounds in land_bounds)
        global_min_z = min(bounds[2] for bounds in land_bounds)
        global_max_z = max(bounds[3] for bounds in land_bounds)
        global_width = max(global_max_x - global_min_x, 1)
        global_depth = max(global_max_z - global_min_z, 1)
        validator.check(global_width >= 4700, f"world is only {global_width:.0f} studs wide")
        validator.check(global_depth >= 4300, f"world is only {global_depth:.0f} studs deep")
        for node, bounds in zip(land, land_bounds):
            shape = node.get("attributes", {}).get("MapShape", "Rect")
            if shape != "Rect":
                continue
            width = bounds[1] - bounds[0]
            depth = bounds[3] - bounds[2]
            validator.check(
                not (width >= global_width * 0.95 and depth >= global_depth * 0.95),
                f"{node.get('name', '<land>')}: rectangular Land feature covers the whole map",
            )

    shapes = {node.get("attributes", {}).get("MapShape") for node in land}
    validator.check("Circle" in shapes and "Rect" in shapes, "Land silhouette must mix circular and rectangular features")

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
        foundation.get("className") == "Folder",
        "WorldFoundation must be a tiled Folder, not an oversized BasePart",
    )
    validator.check(
        isinstance(width, (int, float))
        and isinstance(depth, (int, float))
        and width >= 6000
        and depth >= 5400,
        "WorldFoundation must be at least 6,000 x 5,400 studs",
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
    validator.check(
        columns == 4 and rows == 4 and len(tiles) == 16,
        f"WorldFoundation must contain a 4 x 4 tile grid, found {len(tiles)} tiles",
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
            abs(tile_area - width * depth) <= 1,
            "foundation tiles contain gaps or overlap in their declared footprint",
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

        validate_committed_payload(validator, first_structure, STRUCTURE_PATH, "Structure.model.json")
        validate_committed_payload(validator, first_machines, MACHINES_PATH, "Machines.model.json")
        validate_finite_geometry(validator, (first_structure, first_machines))
        family_by_equipment = validate_equipment_tables(validator, builder)
        stations = [node for node in walk(first_machines) if "TrainingStation" in tags(node)]
        station_by_id = validate_locations(validator, builder, stations, family_by_equipment)
        validate_irregular_map(validator, first_structure, station_by_id)
        validate_world_foundation(validator, first_structure, first_machines)
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
        f"35 stations, 7 tiers x 5 muscles / 35 unique exercises, {instance_count} instances, "
        f"{base_part_count} BaseParts, build {short_hash(first_canonical)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
