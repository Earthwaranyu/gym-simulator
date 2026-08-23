--!strict
--[[
	MuscleDefinitionConfig — primitive anatomy layered over the R15 silhouette.

	Scaling an R15 limb can make it broad, but it cannot produce a bicep peak, separated
	pecs, lats, abs or a calf. These rows describe the rounded contours welded to the
	body. They are cosmetic, client-side and asset-free.

	## Why this file is shaped the way it is

	The first version modelled every muscle as a part sitting *on the surface* of its
	limb, so half of each belly stuck out into the air. At full growth that reads as a
	bag of eggs rather than a bodybuilder. Reference art solves the same problem the
	opposite way round: the silhouette is one smooth tapered mass, and the muscles are
	*shading* on it. Nothing protrudes.

	So responsibilities are split, and the split is the point:

	  Shells   own the SILHOUETTE. Overlapping segments down a chain, continuous in
	           girth, so a limb is one shape rather than beads on a string.
	  Features own the DEFINITION. Buried up to `Emerge`, they contribute a tonal step
	           and a soft edge, never a lump.
	  Lines    own the fine detail — ab separations, linea alba, pec split — drawn as
	           flat geometry on a shell face, because a crisp dark line on a smooth
	           surface is what actually sells muscle at Roblox's polygon budget.

	A feature never states where its own surface is. It states which shell covers it,
	which face it sits on, and how much of it emerges; the controller derives the rest.
	That is deliberate — "poking out of the body" was a whole class of bug, and this
	removes the field that made it expressible.

	## Shape conventions worth knowing

	Roblox characters face local -Z, so anterior muscles are Face = "Front".
	`Enum.PartType.Cylinder`'s flat faces are on +/-X — its axis runs left-right, which
	is why the abs and pecs once rendered as a row of horizontal pipes across the chest.
	Every contour here is a Ball for exactly that reason: an ellipsoid has no axis
	convention to get wrong.

	Start and Full are progress inside the current physique, not lifetime stats, so
	every contour disappears when a new class begins and only the trained group grows
	back.
]]

local MuscleDefinitionConfig = {}

-- Shared replication names. The server publishes which muscle is being trained;
-- the local highlight controller uses the same value without inventing a second
-- training state that could drift from the payout state.
MuscleDefinitionConfig.TRAINING_ATTRIBUTE = "TrainingMuscleStat"
MuscleDefinitionConfig.DEFINITION_FOLDER_NAME = "MuscleDefinition"
MuscleDefinitionConfig.FEATURE_STAT_ATTRIBUTE = "MuscleStatId"
MuscleDefinitionConfig.SHELL_STATS_ATTRIBUTE = "MuscleShellStats"

MuscleDefinitionConfig.BodyPartsByStat = {
	Arms = { "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm" },
	Chest = { "UpperTorso" },
	Back = { "UpperTorso" },
	Core = { "UpperTorso", "LowerTorso" },
	Legs = { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg" },
}

export type VectorSpec = { X: number, Y: number, Z: number }

--[[
	A silhouette segment. `Part` is what it welds to; `GirthPart` is what its width and
	depth are measured against, and every shell in a chain must name the same one. That
	indirection is what keeps a limb continuous: UpperArm and LowerArm grow at different
	rates (0.29 vs 0.21 in PhysiqueConfig), so sizing each segment against its own
	parent would pull the arm apart at the elbow as the player trains.
]]
export type Shell = {
	Id: string,
	StatIds: { string },
	Part: string,
	HidePart: string,
	GirthPart: string,
	Chain: string,
	-- Position down the chain, 1 = topmost. Only used to order the continuity checks.
	Rank: number,
	-- Fractions of GirthPart's X and Z.
	Width: number,
	Depth: number,
	-- Fraction of Part's Y.
	Length: number,
	OffsetY: number,
	Start: number,
	Full: number,
	Shade: number,
	-- Which of the player's colours this segment wears. A shell hides the rig part
	-- underneath, and the rig part is what renders Pants — so a leg shell that took
	-- its colour from the limb came out bare-skinned over black shorts.
	ClothingSlot: string,
	Shape: string,
}

export type Feature = {
	Id: string,
	StatId: string,
	Part: string,
	-- The shell this belly sits under. Its girth defines the surface to bury into.
	CoverShell: string,
	-- Which way the muscle faces: Front, Back, Outward, Top.
	Face: string,
	-- Which way "Outward" points. Required for that face and meaningless otherwise;
	-- deriving it from the part name would break for the torso, where a lat and an
	-- oblique both live on UpperTorso and only differ by which flank they are on.
	Side: string?,
	-- Placement across the face. The component along the face normal is ignored —
	-- burial depth is derived, never authored.
	Offset: VectorSpec,
	Size: VectorSpec,
	Rotation: VectorSpec,
	-- Fraction of the belly's own depth that clears the shell surface. Small on
	-- purpose: definition comes from the tonal step, not from the bulge.
	Emerge: number,
	Start: number,
	Full: number,
	-- Positive darkens the class colour; negative adds a highlight.
	Shade: number,
}

--[[
	A crease drawn on a shell surface — an ab separation, the linea alba, the pec split.

	These began as SurfaceGui frames, which is the obvious way to draw a crisp line. It
	does not survive the torso being a rounded slab rather than a box: a SurfaceGui is
	flat, so on an ellipsoid it either sinks into the surface at the centre or floats
	off it at the edges. So a line is instead a very flat sliver of a part, placed by
	the same burial rule as a muscle belly. It follows the curve for free, it takes the
	world's lighting with the rest of the body, and it needs no second mechanism.

	X and Y are tangential placement, as fractions of the shell's girth reference and
	the parent's height, with the origin at the parent's centre. Width and Height are
	the sliver's extent in the same units; Depth is how thick it is before burial.
]]
export type Line = {
	Id: string,
	StatId: string,
	Shell: string,
	Part: string,
	X: number,
	Y: number,
	Width: number,
	Height: number,
	Depth: number,
	Rotation: number,
	Emerge: number,
	Start: number,
	Full: number,
	Shade: number,
	-- Peak opacity. A crease is a shadow, not paint, so it never goes fully solid.
	Opacity: number,
}

local ZERO: VectorSpec = { X = 0, Y = 0, Z = 0 }
local shells: { Shell } = {}
local features: { Feature } = {}
local lines: { Line } = {}

--[[
	Rig part heights, copied from PhysiqueConfig.BASE_SIZE, and the resting centre of
	each part in its chain. Duplicated rather than required because this module has to
	load under the bare `luau` CLI for its self-test to run in check.sh, and the CLI
	cannot resolve a `ReplicatedStorage.Modules` path. If PhysiqueConfig's base sizes
	change, these change with them.
]]
local CHAIN_GEOMETRY: { [string]: { Height: number, Centre: number } } = {
	UpperTorso = { Height = 1.6, Centre = 0 },
	LowerTorso = { Height = 0.4, Centre = -1.0 },
	LeftUpperArm = { Height = 1.17, Centre = 0 },
	RightUpperArm = { Height = 1.17, Centre = 0 },
	LeftLowerArm = { Height = 1.05, Centre = -1.11 },
	RightLowerArm = { Height = 1.05, Centre = -1.11 },
	LeftUpperLeg = { Height = 1.22, Centre = 0 },
	RightUpperLeg = { Height = 1.22, Centre = 0 },
	LeftLowerLeg = { Height = 1.19, Centre = -1.205 },
	RightLowerLeg = { Height = 1.19, Centre = -1.205 },
	LeftHand = { Height = 0.3, Centre = -1.785 },
	RightHand = { Height = 0.3, Centre = -1.785 },
	LeftFoot = { Height = 0.3, Centre = -1.95 },
	RightFoot = { Height = 0.3, Centre = -1.95 },
}

-- Neighbouring segments may differ in girth by at most this fraction. Limbs are not
-- monotonic — a calf is wider than the knee above it — so the invariant that actually
-- prevents a visible seam is continuity, not a one-way taper.
local MAX_GIRTH_STEP = 0.35

local function addShell(shell: Shell)
	table.insert(shells, shell)
end

local function addFeature(feature: Feature)
	table.insert(features, feature)
end

local function addLine(line: Line)
	table.insert(lines, line)
end

-- ---------------------------------------------------------------------------
-- Silhouette
-- ---------------------------------------------------------------------------

-- Torso: a broad chest over a narrower midriff over a narrower waist. The V-taper is
-- the whole reason these are three segments rather than one box.
addShell({
	Id = "TorsoChest",
	StatIds = { "Chest", "Back", "Core" },
	Part = "UpperTorso",
	HidePart = "UpperTorso",
	GirthPart = "UpperTorso",
	Chain = "Torso",
	Rank = 1,
	Width = 1.05,
	Depth = 1.08,
	Length = 0.8,
	OffsetY = 0.16,
	Start = 0.08,
	Full = 0.5,
	Shade = 0.03,
	ClothingSlot = "Skin",
	Shape = "Ball",
})
addShell({
	Id = "TorsoMidriff",
	StatIds = { "Chest", "Back", "Core" },
	Part = "UpperTorso",
	HidePart = "UpperTorso",
	GirthPart = "UpperTorso",
	Chain = "Torso",
	Rank = 2,
	Width = 0.95,
	Depth = 1.0,
	Length = 0.88,
	OffsetY = -0.26,
	Start = 0.08,
	Full = 0.5,
	Shade = 0.045,
	ClothingSlot = "Skin",
	Shape = "Ball",
})
addShell({
	Id = "TorsoWaist",
	StatIds = { "Chest", "Back", "Core" },
	Part = "LowerTorso",
	HidePart = "LowerTorso",
	GirthPart = "UpperTorso",
	Chain = "Torso",
	Rank = 3,
	Width = 0.86,
	Depth = 0.92,
	Length = 2.8,
	OffsetY = 0,
	Start = 0.08,
	Full = 0.5,
	Shade = 0.055,
	ClothingSlot = "Skin",
	Shape = "Ball",
})

for _, side in { "Left", "Right" } do
	-- Arm: deltoid cap, bicep mass, elbow, forearm, wrist. Each overlaps the next by
	-- more than half, so no seam or radius step is ever on screen.
	addShell({
		Id = `{side}ArmDelt`,
		StatIds = { "Arms" },
		Part = `{side}UpperArm`,
		HidePart = `{side}UpperArm`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 1,
		Width = 1.1,
		Depth = 1.12,
		Length = 0.66,
		OffsetY = 0.34,
		Start = 0.08,
		Full = 0.5,
		Shade = -0.02,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}ArmBicep`,
		StatIds = { "Arms" },
		Part = `{side}UpperArm`,
		HidePart = `{side}UpperArm`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 2,
		Width = 1.12,
		Depth = 1.12,
		Length = 1.1,
		OffsetY = 0,
		Start = 0.08,
		Full = 0.5,
		Shade = 0.02,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}ArmElbow`,
		StatIds = { "Arms" },
		Part = `{side}UpperArm`,
		HidePart = `{side}UpperArm`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 3,
		Width = 0.95,
		Depth = 0.95,
		Length = 0.62,
		OffsetY = -0.42,
		Start = 0.08,
		Full = 0.5,
		Shade = 0.05,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}ArmForearm`,
		StatIds = { "Arms" },
		Part = `{side}LowerArm`,
		HidePart = `{side}LowerArm`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 4,
		Width = 0.98,
		Depth = 0.98,
		Length = 0.95,
		OffsetY = 0.22,
		Start = 0.12,
		Full = 0.55,
		Shade = 0.035,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}ArmWrist`,
		StatIds = { "Arms" },
		Part = `{side}LowerArm`,
		HidePart = `{side}LowerArm`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 5,
		Width = 0.72,
		Depth = 0.72,
		Length = 0.6,
		OffsetY = -0.34,
		Start = 0.12,
		Full = 0.55,
		Shade = 0.06,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}ArmHand`,
		StatIds = { "Arms" },
		Part = `{side}Hand`,
		HidePart = `{side}Hand`,
		GirthPart = `{side}UpperArm`,
		Chain = `{side}Arm`,
		Rank = 6,
		Width = 0.7,
		Depth = 0.7,
		Length = 2.2,
		OffsetY = 0,
		Start = 0.12,
		Full = 0.55,
		Shade = 0.05,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})

	-- Leg: the calf is deliberately wider than the knee above it. Real legs do that,
	-- and it is why the continuity rule allows a step back up.
	addShell({
		Id = `{side}LegGlute`,
		StatIds = { "Legs" },
		Part = `{side}UpperLeg`,
		HidePart = `{side}UpperLeg`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 1,
		Width = 1.12,
		Depth = 1.12,
		Length = 0.85,
		OffsetY = 0.3,
		Start = 0.1,
		Full = 0.52,
		Shade = 0.02,
		ClothingSlot = "Pants",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}LegThigh`,
		StatIds = { "Legs" },
		Part = `{side}UpperLeg`,
		HidePart = `{side}UpperLeg`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 2,
		Width = 1.1,
		Depth = 1.08,
		Length = 0.95,
		OffsetY = -0.12,
		Start = 0.1,
		Full = 0.52,
		Shade = 0.03,
		ClothingSlot = "Pants",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}LegKnee`,
		StatIds = { "Legs" },
		Part = `{side}UpperLeg`,
		HidePart = `{side}UpperLeg`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 3,
		Width = 0.85,
		Depth = 0.86,
		Length = 0.55,
		OffsetY = -0.46,
		Start = 0.1,
		Full = 0.52,
		Shade = 0.055,
		-- Bare, even though it hides part of the shorts-coloured UpperLeg: the hem
		-- has to land above the knee or the shorts read as trousers.
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}LegCalf`,
		StatIds = { "Legs" },
		Part = `{side}LowerLeg`,
		HidePart = `{side}LowerLeg`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 4,
		Width = 0.94,
		Depth = 0.98,
		Length = 0.92,
		OffsetY = 0.2,
		Start = 0.14,
		Full = 0.58,
		Shade = 0.035,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}LegAnkle`,
		StatIds = { "Legs" },
		Part = `{side}LowerLeg`,
		HidePart = `{side}LowerLeg`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 5,
		Width = 0.64,
		Depth = 0.66,
		Length = 0.58,
		OffsetY = -0.36,
		Start = 0.14,
		Full = 0.58,
		Shade = 0.07,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
	addShell({
		Id = `{side}LegFoot`,
		StatIds = { "Legs" },
		Part = `{side}Foot`,
		HidePart = `{side}Foot`,
		GirthPart = `{side}UpperLeg`,
		Chain = `{side}Leg`,
		Rank = 6,
		Width = 0.7,
		Depth = 1.0,
		Length = 2.0,
		OffsetY = 0,
		Start = 0.14,
		Full = 0.58,
		Shade = 0.09,
		ClothingSlot = "Skin",
		Shape = "Ball",
	})
end

-- ---------------------------------------------------------------------------
-- Definition
-- ---------------------------------------------------------------------------

for _, side in { "Left", "Right" } do
	local sign = if side == "Left" then -1 else 1
	addFeature({
		Id = `{side}Deltoid`,
		StatId = "Arms",
		Part = `{side}UpperArm`,
		CoverShell = `{side}ArmDelt`,
		Face = "Outward",
		Side = side,
		Offset = { X = 0, Y = 0.34, Z = 0 },
		Size = { X = 0.6, Y = 0.6, Z = 0.78 },
		Rotation = { X = 0, Y = 0, Z = sign * 5 },
		Emerge = 0.16,
		Start = 0.08,
		Full = 0.72,
		Shade = -0.12,
	})
	addFeature({
		Id = `{side}Bicep`,
		StatId = "Arms",
		Part = `{side}UpperArm`,
		CoverShell = `{side}ArmBicep`,
		Face = "Front",
		Offset = { X = 0, Y = 0.02, Z = 0 },
		Size = { X = 0.62, Y = 0.66, Z = 0.5 },
		Rotation = ZERO,
		Emerge = 0.18,
		Start = 0.12,
		Full = 0.82,
		Shade = -0.16,
	})
	addFeature({
		Id = `{side}Tricep`,
		StatId = "Arms",
		Part = `{side}UpperArm`,
		CoverShell = `{side}ArmBicep`,
		Face = "Back",
		Offset = { X = 0, Y = -0.06, Z = 0 },
		Size = { X = 0.56, Y = 0.6, Z = 0.44 },
		Rotation = ZERO,
		Emerge = 0.12,
		Start = 0.22,
		Full = 0.95,
		Shade = 0.3,
	})
	addFeature({
		Id = `{side}Forearm`,
		StatId = "Arms",
		Part = `{side}LowerArm`,
		CoverShell = `{side}ArmForearm`,
		Face = "Front",
		Offset = { X = 0, Y = 0.12, Z = 0 },
		Size = { X = 0.44, Y = 0.54, Z = 0.36 },
		Rotation = { X = 0, Y = 0, Z = sign * 8 },
		Emerge = 0.14,
		Start = 0.3,
		Full = 1,
		Shade = 0.16,
	})
end

-- Chest and Back share UpperTorso structurally, but their contours listen to
-- different progress values, so training pecs never grows lats and vice versa.
for _, sign in { -1, 1 } do
	local side = if sign < 0 then "Left" else "Right"
	addFeature({
		Id = `{side}Pec`,
		StatId = "Chest",
		Part = "UpperTorso",
		CoverShell = "TorsoChest",
		Face = "Front",
		Offset = { X = sign * 0.2, Y = 0.16, Z = 0 },
		Size = { X = 0.44, Y = 0.4, Z = 0.34 },
		Rotation = { X = 0, Y = 0, Z = sign * 3 },
		Emerge = 0.16,
		Start = 0.1,
		Full = 0.8,
		Shade = -0.12,
	})
	addFeature({
		Id = `{side}Lat`,
		StatId = "Back",
		Part = "UpperTorso",
		CoverShell = "TorsoMidriff",
		Face = "Outward",
		Side = side,
		Offset = { X = 0, Y = 0.02, Z = 0.18 },
		Size = { X = 0.2, Y = 0.62, Z = 0.5 },
		Rotation = { X = 0, Y = 0, Z = sign * 10 },
		Emerge = 0.2,
		Start = 0.16,
		Full = 0.88,
		Shade = 0.22,
	})
	addFeature({
		Id = `{side}Trap`,
		StatId = "Back",
		Part = "UpperTorso",
		CoverShell = "TorsoChest",
		Face = "Back",
		Offset = { X = sign * 0.13, Y = 0.28, Z = 0 },
		Size = { X = 0.3, Y = 0.3, Z = 0.24 },
		Rotation = { X = 0, Y = 0, Z = -sign * 18 },
		Emerge = 0.14,
		Start = 0.24,
		Full = 0.9,
		Shade = 0.18,
	})
	addFeature({
		Id = `{side}RearDelt`,
		StatId = "Back",
		Part = "UpperTorso",
		CoverShell = "TorsoChest",
		Face = "Back",
		Offset = { X = sign * 0.4, Y = 0.16, Z = 0 },
		Size = { X = 0.24, Y = 0.36, Z = 0.22 },
		Rotation = { X = 0, Y = 0, Z = sign * 10 },
		Emerge = 0.12,
		Start = 0.14,
		Full = 0.82,
		Shade = -0.06,
	})
	addFeature({
		Id = `{side}Erector`,
		StatId = "Back",
		Part = "UpperTorso",
		CoverShell = "TorsoMidriff",
		Face = "Back",
		Offset = { X = sign * 0.1, Y = -0.12, Z = 0 },
		Size = { X = 0.16, Y = 0.5, Z = 0.16 },
		Rotation = { X = 0, Y = 0, Z = sign * 4 },
		Emerge = 0.12,
		Start = 0.3,
		Full = 0.95,
		Shade = 0.24,
	})
	addFeature({
		Id = `{side}Rhomboid`,
		StatId = "Back",
		Part = "UpperTorso",
		CoverShell = "TorsoChest",
		Face = "Back",
		Offset = { X = sign * 0.16, Y = 0.02, Z = 0 },
		Size = { X = 0.26, Y = 0.24, Z = 0.18 },
		Rotation = { X = 0, Y = 0, Z = -sign * 35 },
		Emerge = 0.1,
		Start = 0.34,
		Full = 0.96,
		Shade = 0.16,
	})
end

-- Six abdominal blocks. They sit on UpperTorso because the stock R15 LowerTorso is too
-- short to hold readable abdominal separation. The bellies are barely proud of the
-- surface; what the player actually reads as a six-pack is the drawn line work below.
for row, y in { 0.02, -0.16, -0.34 } do
	for _, sign in { -1, 1 } do
		addFeature({
			Id = `Ab{row}{if sign < 0 then "L" else "R"}`,
			StatId = "Core",
			Part = "UpperTorso",
			CoverShell = "TorsoMidriff",
			Face = "Front",
			Offset = { X = sign * 0.075, Y = y, Z = 0 },
			Size = { X = 0.13, Y = 0.15, Z = 0.16 },
			Rotation = ZERO,
			Emerge = 0.1,
			Start = 0.3 + (row - 1) * 0.08,
			Full = 0.92,
			Shade = if row % 2 == 0 then 0.12 else -0.06,
		})
	end
end
for _, sign in { -1, 1 } do
	addFeature({
		Id = `Oblique{if sign < 0 then "L" else "R"}`,
		StatId = "Core",
		Part = "UpperTorso",
		CoverShell = "TorsoMidriff",
		Face = "Outward",
		Side = if sign < 0 then "Left" else "Right",
		Offset = { X = 0, Y = -0.26, Z = -0.1 },
		Size = { X = 0.18, Y = 0.44, Z = 0.3 },
		Rotation = { X = 0, Y = 0, Z = sign * 16 },
		Emerge = 0.14,
		Start = 0.42,
		Full = 1,
		Shade = 0.26,
	})
end

for _, side in { "Left", "Right" } do
	local sign = if side == "Left" then -1 else 1
	addFeature({
		Id = `{side}Quad`,
		StatId = "Legs",
		Part = `{side}UpperLeg`,
		CoverShell = `{side}LegThigh`,
		Face = "Front",
		Offset = { X = 0, Y = -0.16, Z = 0 },
		Size = { X = 0.54, Y = 0.58, Z = 0.36 },
		Rotation = { X = 0, Y = 0, Z = sign * 5 },
		Emerge = 0.14,
		Start = 0.12,
		Full = 0.84,
		Shade = -0.1,
	})
	addFeature({
		Id = `{side}Hamstring`,
		StatId = "Legs",
		Part = `{side}UpperLeg`,
		CoverShell = `{side}LegThigh`,
		Face = "Back",
		Offset = { X = 0, Y = -0.18, Z = 0 },
		Size = { X = 0.5, Y = 0.54, Z = 0.34 },
		Rotation = ZERO,
		Emerge = 0.1,
		Start = 0.25,
		Full = 0.95,
		Shade = 0.26,
	})
	addFeature({
		Id = `{side}Calf`,
		StatId = "Legs",
		Part = `{side}LowerLeg`,
		CoverShell = `{side}LegCalf`,
		Face = "Back",
		Offset = { X = sign * 0.1, Y = 0.1, Z = 0 },
		Size = { X = 0.48, Y = 0.56, Z = 0.4 },
		Rotation = ZERO,
		Emerge = 0.14,
		Start = 0.28,
		Full = 1,
		Shade = 0.2,
	})
end

-- ---------------------------------------------------------------------------
-- Drawn line work
-- ---------------------------------------------------------------------------
-- Rects are in the face's 0..1 space with the origin at its centre.

addLine({
	Id = "PecSplit",
	StatId = "Chest",
	Shell = "TorsoChest",
	Part = "UpperTorso",
	X = 0,
	Y = 0.06,
	Width = 0.035,
	Height = 0.4,
	Depth = 0.16,
	Rotation = 0,
	Emerge = 0.06,
	Start = 0.14,
	Full = 0.7,
	Shade = 0.45,
	Opacity = 0.6,
})
for _, sign in { -1, 1 } do
	addLine({
		Id = `PecUnder{if sign < 0 then "L" else "R"}`,
		StatId = "Chest",
		Shell = "TorsoChest",
		Part = "UpperTorso",
		X = sign * 0.17,
		Y = -0.12,
		Width = 0.3,
		Height = 0.035,
		Depth = 0.16,
		Rotation = -sign * 8,
		Emerge = 0.06,
		Start = 0.2,
		Full = 0.8,
		Shade = 0.4,
		Opacity = 0.55,
	})
end
addLine({
	Id = "LineaAlba",
	StatId = "Core",
	Shell = "TorsoMidriff",
	Part = "UpperTorso",
	X = 0,
	Y = -0.06,
	Width = 0.03,
	Height = 0.55,
	Depth = 0.14,
	Rotation = 0,
	Emerge = 0.06,
	Start = 0.28,
	Full = 0.85,
	Shade = 0.45,
	Opacity = 0.6,
})
for row, y in { 0.1, -0.06, -0.22 } do
	addLine({
		Id = `AbSeparation{row}`,
		StatId = "Core",
		Shell = "TorsoMidriff",
		Part = "UpperTorso",
		X = 0,
		Y = y,
		Width = 0.3,
		Height = 0.032,
		Depth = 0.14,
		Rotation = 0,
		Emerge = 0.06,
		Start = 0.3 + (row - 1) * 0.08,
		Full = 0.9,
		Shade = 0.42,
		Opacity = 0.55,
	})
end
for _, sign in { -1, 1 } do
	addLine({
		Id = `Serratus{if sign < 0 then "L" else "R"}`,
		StatId = "Core",
		Shell = "TorsoMidriff",
		Part = "UpperTorso",
		X = sign * 0.28,
		Y = 0.04,
		Width = 0.2,
		Height = 0.03,
		Depth = 0.12,
		Rotation = sign * 32,
		Emerge = 0.05,
		Start = 0.5,
		Full = 1,
		Shade = 0.4,
		Opacity = 0.45,
	})
end

MuscleDefinitionConfig.Shells = shells
MuscleDefinitionConfig.List = features
MuscleDefinitionConfig.Lines = lines
MuscleDefinitionConfig.MAX_GIRTH_STEP = MAX_GIRTH_STEP

local shellsById: { [string]: Shell } = {}
for _, shell in shells do
	shellsById[shell.Id] = shell
end
MuscleDefinitionConfig.ShellsById = shellsById

function MuscleDefinitionConfig.Strength(feature: Feature, progress: number): number
	local span = feature.Full - feature.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - feature.Start) / span, 0, 1)
	return linear * linear * (3 - 2 * linear)
end

function MuscleDefinitionConfig.ShellStrength(shell: Shell, progressByStat: { [string]: number }): number
	local progress = 0
	for _, statId in shell.StatIds do
		progress = math.max(progress, progressByStat[statId] or 0)
	end
	local span = shell.Full - shell.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - shell.Start) / span, 0, 1)
	return linear * linear * (3 - 2 * linear)
end

function MuscleDefinitionConfig.LineStrength(line: Line, progress: number): number
	local span = line.Full - line.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - line.Start) / span, 0, 1)
	return linear * linear * (3 - 2 * linear)
end

--[[
	Where a feature's centre sits along its face normal, in studs from the parent
	part's origin, given the covering shell's half-extent on that axis and the
	feature's own depth. Shared with the controller so the burial rule lives in one
	place and can be tested without Studio.

	Emerge = 0 leaves the belly tangent to the surface from the inside; Emerge = 1
	would put it entirely outside, which is the failure this whole model exists to
	prevent, so the self-test caps it well below that.
]]
function MuscleDefinitionConfig.BurialOffset(
	shellHalfExtent: number,
	featureDepth: number,
	emerge: number
): number
	return shellHalfExtent + emerge * featureDepth - featureDepth * 0.5
end

function MuscleDefinitionConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local validStats = { Arms = true, Chest = true, Back = true, Core = true, Legs = true }
	local validParts = {
		UpperTorso = true,
		LowerTorso = true,
		LeftUpperArm = true,
		RightUpperArm = true,
		LeftLowerArm = true,
		RightLowerArm = true,
		LeftUpperLeg = true,
		RightUpperLeg = true,
		LeftLowerLeg = true,
		RightLowerLeg = true,
	}
	local validFaces = { Front = true, Back = true, Outward = true, Top = true }
	-- Hands and feet carry a shell so they are not the last bare R15 rectangles on
	-- the body, but nothing is sculpted onto them.
	local validShellParts = table.clone(validParts)
	for _, name in { "LeftHand", "RightHand", "LeftFoot", "RightFoot" } do
		validShellParts[name] = true
	end

	-- Shells ------------------------------------------------------------------
	local shellIds: { [string]: boolean } = {}
	local chains: { [string]: { Shell } } = {}
	for _, shell in shells do
		if shellIds[shell.Id] then
			table.insert(failures, `duplicate shell id {shell.Id}`)
		end
		shellIds[shell.Id] = true
		if not validShellParts[shell.Part] then
			table.insert(failures, `{shell.Id} uses unknown body part {shell.Part}`)
		end
		if CHAIN_GEOMETRY[shell.Part] == nil then
			table.insert(failures, `{shell.Id} has no chain geometry for {shell.Part}`)
		end
		if shell.Start < 0 or shell.Full > 1 or shell.Start >= shell.Full then
			table.insert(failures, `{shell.Id} has invalid visibility range`)
		end
		if shell.Width <= 0 or shell.Depth <= 0 or shell.Length <= 0 then
			table.insert(failures, `{shell.Id} has non-positive extent`)
		end
		if shell.ClothingSlot ~= "Skin" and shell.ClothingSlot ~= "Pants" then
			table.insert(failures, `{shell.Id} has unknown clothing slot {shell.ClothingSlot}`)
		end
		if MuscleDefinitionConfig.ShellStrength(shell, {}) ~= 0 then
			table.insert(failures, `{shell.Id} appears on a lean physique`)
		end
		local chain = chains[shell.Chain]
		if chain == nil then
			chain = {}
			chains[shell.Chain] = chain
		end
		table.insert(chain, shell)
	end

	for chainId, members in chains do
		table.sort(members, function(a, b)
			return a.Rank < b.Rank
		end)
		local girthPart = members[1].GirthPart
		for index, shell in members do
			if shell.Rank ~= index then
				table.insert(failures, `chain {chainId} has a gap or repeat at rank {index}`)
			end
			-- Comparing girths across a chain is only meaningful if they are
			-- fractions of the same thing.
			if shell.GirthPart ~= girthPart then
				table.insert(
					failures,
					`{shell.Id} measures girth against {shell.GirthPart}, not the chain's {girthPart}`
				)
			end
		end
		for index = 1, #members - 1 do
			local upper, lower = members[index], members[index + 1]
			local upperGeometry = CHAIN_GEOMETRY[upper.Part]
			local lowerGeometry = CHAIN_GEOMETRY[lower.Part]
			if upperGeometry == nil or lowerGeometry == nil then
				continue
			end
			local upperBottom = upperGeometry.Centre
				+ upper.OffsetY * upperGeometry.Height
				- upper.Length * upperGeometry.Height * 0.5
			local lowerTop = lowerGeometry.Centre
				+ lower.OffsetY * lowerGeometry.Height
				+ lower.Length * lowerGeometry.Height * 0.5
			if lowerTop <= upperBottom then
				table.insert(failures, `{lower.Id} leaves a gap below {upper.Id}`)
			end
			if math.abs(upper.Width - lower.Width) > MAX_GIRTH_STEP then
				table.insert(failures, `{upper.Id} to {lower.Id} steps too far in width`)
			end
			if math.abs(upper.Depth - lower.Depth) > MAX_GIRTH_STEP then
				table.insert(failures, `{upper.Id} to {lower.Id} steps too far in depth`)
			end
		end
	end

	-- Features ----------------------------------------------------------------
	local ids: { [string]: boolean } = {}
	local expectedCounts: { [string]: number } = { Arms = 8, Chest = 2, Back = 10, Core = 8, Legs = 6 }
	local statCounts: { [string]: number } = {}
	for _, feature in features do
		if ids[feature.Id] then
			table.insert(failures, `duplicate feature id {feature.Id}`)
		end
		ids[feature.Id] = true
		if not validStats[feature.StatId] then
			table.insert(failures, `{feature.Id} uses unknown stat {feature.StatId}`)
		end
		statCounts[feature.StatId] = (statCounts[feature.StatId] or 0) + 1
		if not validParts[feature.Part] then
			table.insert(failures, `{feature.Id} uses unknown body part {feature.Part}`)
		end
		if not validFaces[feature.Face] then
			table.insert(failures, `{feature.Id} uses unknown face {feature.Face}`)
		end
		if feature.Face == "Outward" and feature.Side ~= "Left" and feature.Side ~= "Right" then
			table.insert(failures, `{feature.Id} faces outward without saying which side`)
		end
		local cover = shellsById[feature.CoverShell]
		if cover == nil then
			table.insert(failures, `{feature.Id} names missing cover shell {feature.CoverShell}`)
		elseif cover.Part ~= feature.Part then
			-- A belly welds to its parent part; if the shell covering it welds to a
			-- different one they drift apart the moment the two grow at different
			-- rates, and the belly surfaces through the body.
			table.insert(failures, `{feature.Id} is covered by {cover.Id}, which is welded to {cover.Part}`)
		end
		if feature.Start < 0 or feature.Full > 1 or feature.Start >= feature.Full then
			table.insert(failures, `{feature.Id} has invalid visibility range`)
		end
		if feature.Size.X <= 0 or feature.Size.Y <= 0 or feature.Size.Z <= 0 then
			table.insert(failures, `{feature.Id} has non-positive size`)
		end
		-- The whole point of the rewrite: a belly is shading, not a lump. Anything
		-- clearing a quarter of its own depth is back to the bag-of-eggs silhouette.
		if feature.Emerge < 0 or feature.Emerge > 0.25 then
			table.insert(failures, `{feature.Id} emerges {feature.Emerge}, past the 0.25 shading limit`)
		end
		if MuscleDefinitionConfig.Strength(feature, 0) ~= 0 then
			table.insert(failures, `{feature.Id} appears on a lean physique`)
		end
	end
	for statId, expected in expectedCounts do
		if statCounts[statId] ~= expected then
			table.insert(failures, `{statId} has {statCounts[statId] or 0} contours, expected {expected}`)
		end
	end

	-- Lines -------------------------------------------------------------------
	local lineIds: { [string]: boolean } = {}
	for _, line in lines do
		if lineIds[line.Id] then
			table.insert(failures, `duplicate line id {line.Id}`)
		end
		lineIds[line.Id] = true
		if not validStats[line.StatId] then
			table.insert(failures, `{line.Id} uses unknown stat {line.StatId}`)
		end
		local host = shellsById[line.Shell]
		if host == nil then
			table.insert(failures, `{line.Id} draws on missing shell {line.Shell}`)
		end
		if line.Start < 0 or line.Full > 1 or line.Start >= line.Full then
			table.insert(failures, `{line.Id} has invalid visibility range`)
		end
		if line.Opacity <= 0 or line.Opacity > 0.7 then
			-- Fully opaque line work reads as a sticker rather than a shadow.
			table.insert(failures, `{line.Id} has opacity {line.Opacity}, outside the shadow range`)
		end
		if not validParts[line.Part] then
			table.insert(failures, `{line.Id} uses unknown body part {line.Part}`)
		end
		if host ~= nil and host.Part ~= line.Part then
			table.insert(
				failures,
				`{line.Id} welds to {line.Part} but is placed against {host.Id} on {host.Part}`
			)
		end
		-- A crease clearing more than a tenth of its own thickness stops being a
		-- shadow and starts being a raised welt.
		if line.Emerge < 0 or line.Emerge > 0.1 then
			table.insert(failures, `{line.Id} emerges {line.Emerge}, past the 0.1 crease limit`)
		end
		if math.abs(line.X) + line.Width * 0.5 > 0.5 or math.abs(line.Y) + line.Height * 0.5 > 0.5 then
			table.insert(failures, `{line.Id} runs off the edge of {line.Shell}`)
		end
	end

	-- Burial rule -------------------------------------------------------------
	-- A belly half a stud deep, buried under a surface one stud out, must end up
	-- with its far edge only just past that surface.
	local centre = MuscleDefinitionConfig.BurialOffset(1, 0.5, 0.2)
	if math.abs((centre + 0.25) - 1.1) > 1e-9 then
		table.insert(
			failures,
			"BurialOffset does not place the belly's outer edge at the configured emergence"
		)
	end

	return failures
end

return MuscleDefinitionConfig
