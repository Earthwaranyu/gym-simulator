--!strict
--[[
	MobRigConfig — what a monster is made of, and where it bends.

	Monsters used to be ten boxes welded rigidly to the root. That was honest about what
	they needed at the time ("the mob walks and swings, it does not animate") and it is
	exactly what made animating them impossible: a WeldConstraint has nothing to rotate,
	and parts named `ArmLeft` are not something a pose config can address.

	So the body is described here instead, as data, and MobService interprets it. Two
	tables do the work:

	  * `Bones` are the parts a joint moves. They are named for the R15 rig — UpperTorso,
	    RightUpperArm — and the joints between them take the **stock R15 joint names**.
	    That is the whole trick: PoseConfig, GaitConfig, StrikeConfig and PosePlayback all
	    address joints by those names, so every piece of animation machinery the player
	    already has works on a goblin without a translation layer. A joint a pose asks for
	    that this rig does not have (ankles) resolves to nil and is skipped, which is how
	    PosePlayback.FindJoint already degrades on R6.
	  * `Decor` is everything welded rigidly to a bone — ears, horns, hands, eyes. It never
	    moves on its own, it just rides whatever bone it hangs off.

	Shapes follow the technique MuscleIcons proved: a capsule (a cylinder with a ball at
	each end) reads as a limb where a box reads as a plank, and a wedge gives a jaw or a
	shoulder a direction. Everything is a Roblox primitive, per the project's asset rule —
	no meshes, no Toolbox, nothing anyone else drew.

	Colour is one number per part. `Shade` lerps the mob's own colour toward black below
	zero and toward white above it, so a whole monster still comes from the single Color
	on its MobConfig row and a tier reads as one creature rather than a paint chart.
]]

local MobRigConfig = {}

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "Capsule"

export type Bone = {
	Name: string,
	Shape: Shape,
	Size: Vector3,
	-- Toward black below zero, toward white above it, from the mob's own colour.
	Shade: number,
	Material: Enum.Material?,
	-- Neon parts ignore lighting, which is what makes an eye read as lit rather than
	-- painted. Kept off everything else: a whole neon goblin is a lamp, not a monster.
	Transparency: number?,
}

export type Joint = {
	Name: string,
	Part0: string,
	Part1: string,
	-- Where the joint sits, in each part's own space. The child hangs so that its C1
	-- point lands on the parent's C0 point, which is what puts a shoulder at the top
	-- outer corner of a torso rather than at its centre.
	C0: Vector3,
	C1: Vector3,
}

export type Decor = {
	Name: string,
	Parent: string,
	Shape: Shape,
	Size: Vector3,
	Offset: Vector3,
	-- Degrees. Available at all now that decoration hangs off a bone rather than being
	-- placed by a bare CFrame.new offset the old builder could not rotate.
	Rotation: Vector3?,
	Shade: number,
	Material: Enum.Material?,
}

export type Rig = {
	Id: string,
	-- The collidable, invisible body the humanoid actually walks around. Everything
	-- else is Massless and non-collidable so the silhouette cannot catch on terrain.
	RootSize: Vector3,
	Bones: { Bone },
	Joints: { Joint },
	Decor: { Decor },
}

local SMOOTH = Enum.Material.SmoothPlastic

--[[
	The goblin.

	Squat, top-heavy and hunched: a wide chest over a short waist, long arms that hang
	past the hips, and a head nearly as wide as the shoulders. Those proportions are the
	whole read at fifty studs, which is further out than any detail survives.
]]
local GOBLIN: Rig = {
	Id = "Goblin",
	RootSize = Vector3.new(2, 2, 1),

	Bones = {
		{ Name = "LowerTorso", Shape = "Block", Size = Vector3.new(1.5, 0.8, 0.95), Shade = -0.2 },
		{ Name = "UpperTorso", Shape = "Block", Size = Vector3.new(2.1, 1.5, 1.2), Shade = 0 },
		{ Name = "Head", Shape = "Ball", Size = Vector3.new(1.5, 1.4, 1.5), Shade = 0.06 },

		{ Name = "RightUpperArm", Shape = "Capsule", Size = Vector3.new(0.62, 1.25, 0.62), Shade = -0.04 },
		{ Name = "RightLowerArm", Shape = "Capsule", Size = Vector3.new(0.56, 1.15, 0.56), Shade = -0.08 },
		{ Name = "LeftUpperArm", Shape = "Capsule", Size = Vector3.new(0.62, 1.25, 0.62), Shade = -0.04 },
		{ Name = "LeftLowerArm", Shape = "Capsule", Size = Vector3.new(0.56, 1.15, 0.56), Shade = -0.08 },

		{ Name = "RightUpperLeg", Shape = "Capsule", Size = Vector3.new(0.72, 0.95, 0.72), Shade = -0.28 },
		{ Name = "RightLowerLeg", Shape = "Capsule", Size = Vector3.new(0.62, 0.9, 0.62), Shade = -0.34 },
		{ Name = "LeftUpperLeg", Shape = "Capsule", Size = Vector3.new(0.72, 0.95, 0.72), Shade = -0.28 },
		{ Name = "LeftLowerLeg", Shape = "Capsule", Size = Vector3.new(0.62, 0.9, 0.62), Shade = -0.34 },
	},

	-- Stock R15 names, deliberately. This is what lets GaitConfig and StrikeConfig drive
	-- a goblin with no mapping layer at all.
	Joints = {
		{
			Name = "Root",
			Part0 = "HumanoidRootPart",
			Part1 = "LowerTorso",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "Waist",
			Part0 = "LowerTorso",
			Part1 = "UpperTorso",
			C0 = Vector3.new(0, 0.4, 0),
			C1 = Vector3.new(0, -0.75, 0),
		},
		{
			Name = "Neck",
			Part0 = "UpperTorso",
			Part1 = "Head",
			C0 = Vector3.new(0, 0.75, -0.05),
			C1 = Vector3.new(0, -0.6, 0),
		},

		{
			Name = "RightShoulder",
			Part0 = "UpperTorso",
			Part1 = "RightUpperArm",
			C0 = Vector3.new(1.2, 0.5, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "RightElbow",
			Part0 = "RightUpperArm",
			Part1 = "RightLowerArm",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "LeftShoulder",
			Part0 = "UpperTorso",
			Part1 = "LeftUpperArm",
			C0 = Vector3.new(-1.2, 0.5, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "LeftElbow",
			Part0 = "LeftUpperArm",
			Part1 = "LeftLowerArm",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},

		{
			Name = "RightHip",
			Part0 = "LowerTorso",
			Part1 = "RightUpperLeg",
			C0 = Vector3.new(0.45, -0.4, 0),
			C1 = Vector3.new(0, 0.45, 0),
		},
		{
			Name = "RightKnee",
			Part0 = "RightUpperLeg",
			Part1 = "RightLowerLeg",
			C0 = Vector3.new(0, -0.45, 0),
			C1 = Vector3.new(0, 0.42, 0),
		},
		{
			Name = "LeftHip",
			Part0 = "LowerTorso",
			Part1 = "LeftUpperLeg",
			C0 = Vector3.new(-0.45, -0.4, 0),
			C1 = Vector3.new(0, 0.45, 0),
		},
		{
			Name = "LeftKnee",
			Part0 = "LeftUpperLeg",
			Part1 = "LeftLowerLeg",
			C0 = Vector3.new(0, -0.45, 0),
			C1 = Vector3.new(0, 0.42, 0),
		},
	},

	Decor = {
		-- The ears are most of why this reads as a goblin rather than a small ogre, so
		-- they are long, swept back and angled rather than the flat tabs they were.
		{
			Name = "EarRight",
			Parent = "Head",
			Shape = "Wedge",
			Size = Vector3.new(0.22, 0.5, 1.1),
			Offset = Vector3.new(0.72, 0.18, -0.1),
			Rotation = Vector3.new(0, 12, -34),
			Shade = -0.3,
		},
		{
			Name = "EarLeft",
			Parent = "Head",
			Shape = "Wedge",
			Size = Vector3.new(0.22, 0.5, 1.1),
			Offset = Vector3.new(-0.72, 0.18, -0.1),
			Rotation = Vector3.new(0, -12, 34),
			Shade = -0.3,
		},
		-- A brow ridge shades the eyes and gives the face somewhere to sit.
		{
			Name = "Brow",
			Parent = "Head",
			Shape = "Block",
			Size = Vector3.new(1.2, 0.22, 0.5),
			Offset = Vector3.new(0, 0.28, 0.55),
			Rotation = Vector3.new(-12, 0, 0),
			Shade = -0.32,
		},
		{
			Name = "Jaw",
			Parent = "Head",
			Shape = "Wedge",
			Size = Vector3.new(0.95, 0.42, 0.6),
			Offset = Vector3.new(0, -0.42, 0.42),
			Rotation = Vector3.new(180, 0, 0),
			Shade = -0.14,
		},
		{
			Name = "EyeRight",
			Parent = "Head",
			Shape = "Ball",
			Size = Vector3.new(0.24, 0.24, 0.24),
			Offset = Vector3.new(0.31, 0.08, 0.66),
			Shade = 0.85,
			Material = Enum.Material.Neon,
		},
		{
			Name = "EyeLeft",
			Parent = "Head",
			Shape = "Ball",
			Size = Vector3.new(0.24, 0.24, 0.24),
			Offset = Vector3.new(-0.31, 0.08, 0.66),
			Shade = 0.85,
			Material = Enum.Material.Neon,
		},

		{
			Name = "HandRight",
			Parent = "RightLowerArm",
			Shape = "Ball",
			Size = Vector3.new(0.62, 0.62, 0.62),
			Offset = Vector3.new(0, -0.62, 0),
			Shade = -0.02,
		},
		{
			Name = "HandLeft",
			Parent = "LeftLowerArm",
			Shape = "Ball",
			Size = Vector3.new(0.62, 0.62, 0.62),
			Offset = Vector3.new(0, -0.62, 0),
			Shade = -0.02,
		},
		{
			Name = "FootRight",
			Parent = "RightLowerLeg",
			Shape = "Wedge",
			Size = Vector3.new(0.66, 0.3, 0.95),
			Offset = Vector3.new(0, -0.5, 0.22),
			Rotation = Vector3.new(0, 180, 0),
			Shade = -0.4,
		},
		{
			Name = "FootLeft",
			Parent = "LeftLowerLeg",
			Shape = "Wedge",
			Size = Vector3.new(0.66, 0.3, 0.95),
			Offset = Vector3.new(0, -0.5, 0.22),
			Rotation = Vector3.new(0, 180, 0),
			Shade = -0.4,
		},
	},
}

--[[
	The boss.

	Not simply a bigger goblin: MobService scales the whole rig by the row's Scale, so
	size alone is already handled. What makes a boss read as a boss from across the arena
	is the extra mass on the shoulders, the horns, and eyes that carry further.
]]
local BOSS: Rig = {
	Id = "Boss",
	RootSize = GOBLIN.RootSize,
	Bones = GOBLIN.Bones,
	Joints = GOBLIN.Joints,
	Decor = table.clone(GOBLIN.Decor),
}

-- What a boss wears on top of the goblin rig. Scale already makes it bigger; this is
-- what makes it read as a different creature at a distance rather than a zoomed one.
local BOSS_EXTRA: { Decor } = {
	{
		Name = "HornRight",
		Parent = "Head",
		Shape = "Cylinder",
		Size = Vector3.new(0.9, 0.26, 0.26),
		Offset = Vector3.new(0.42, 0.62, 0.05),
		Rotation = Vector3.new(0, 0, 62),
		Shade = -0.55,
	},
	{
		Name = "HornLeft",
		Parent = "Head",
		Shape = "Cylinder",
		Size = Vector3.new(0.9, 0.26, 0.26),
		Offset = Vector3.new(-0.42, 0.62, 0.05),
		Rotation = Vector3.new(0, 0, 118),
		Shade = -0.55,
	},
	{
		Name = "HornRightTip",
		Parent = "Head",
		Shape = "Cylinder",
		Size = Vector3.new(0.6, 0.16, 0.16),
		Offset = Vector3.new(0.72, 1.16, 0.05),
		Rotation = Vector3.new(0, 0, 24),
		Shade = -0.62,
	},
	{
		Name = "HornLeftTip",
		Parent = "Head",
		Shape = "Cylinder",
		Size = Vector3.new(0.6, 0.16, 0.16),
		Offset = Vector3.new(-0.72, 1.16, 0.05),
		Rotation = Vector3.new(0, 0, 156),
		Shade = -0.62,
	},
	-- Pauldrons. A boss's outline is wider at the shoulder than anything else on the
	-- map, which is what makes it legible in a crowd of its own goblins.
	{
		Name = "PauldronRight",
		Parent = "RightUpperArm",
		Shape = "Wedge",
		Size = Vector3.new(0.5, 0.55, 1.0),
		Offset = Vector3.new(0.16, 0.5, 0),
		Rotation = Vector3.new(0, 90, -14),
		Shade = -0.45,
	},
	{
		Name = "PauldronLeft",
		Parent = "LeftUpperArm",
		Shape = "Wedge",
		Size = Vector3.new(0.5, 0.55, 1.0),
		Offset = Vector3.new(-0.16, 0.5, 0),
		Rotation = Vector3.new(0, -90, 14),
		Shade = -0.45,
	},
	{
		Name = "Spine",
		Parent = "UpperTorso",
		Shape = "Wedge",
		Size = Vector3.new(0.3, 0.7, 0.8),
		Offset = Vector3.new(0, 0.5, -0.62),
		Rotation = Vector3.new(-90, 0, 0),
		Shade = -0.5,
	},
}

for _, extra in BOSS_EXTRA do
	table.insert(BOSS.Decor, extra)
end

local rigs: { Rig } = { GOBLIN, BOSS }

MobRigConfig.List = rigs
MobRigConfig.Goblin = GOBLIN
MobRigConfig.Boss = BOSS
MobRigConfig.DefaultMaterial = SMOOTH

local byId: { [string]: Rig } = {}
for _, rig in rigs do
	if byId[rig.Id] ~= nil then
		error(`[MobRigConfig] Duplicate rig id "{rig.Id}"`)
	end
	byId[rig.Id] = rig
end

function MobRigConfig.Get(rigId: string): Rig?
	return byId[rigId]
end

--[[
	The rig a monster of this kind wears.
]]
function MobRigConfig.ForKind(kind: string): Rig
	return if kind == "Boss" then BOSS else GOBLIN
end

--[[
	A part's colour: the monster's own, pulled toward black or white.

	One number per part rather than a colour per part, so a tier still reads as one
	creature and retinting a mob is one edit on its MobConfig row.
]]
function MobRigConfig.Shade(base: Color3, shade: number): Color3
	if shade < 0 then
		return base:Lerp(Color3.new(0, 0, 0), math.min(-shade, 1))
	end
	return base:Lerp(Color3.new(1, 1, 1), math.min(shade, 1))
end

return MobRigConfig
