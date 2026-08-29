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
	    already has works on a thief without a translation layer. A joint a pose asks for
	    that this rig does not have (ankles) resolves to nil and is skipped, which is how
	    PosePlayback.FindJoint already degrades on R6. Sizes and shapes are free to
	    change; these names are not.
	  * `Decor` is everything welded rigidly to a bone — ears, horns, hands, eyes. It never
	    moves on its own, it just rides whatever bone it hangs off.

	Shapes follow the technique MuscleIcons proved: a capsule (a cylinder with a ball at
	each end) reads as a limb where a box reads as a plank, and a wedge gives a jaw or a
	shoulder a direction. Everything is a Roblox primitive, per the project's asset rule —
	no meshes, no Toolbox, nothing anyone else drew.

	There are two rigs, and they no longer share a skeleton. The brute used to be the
	goblin's own Bones and Joints at 2.1x with horns bolted on, which is a zoomed goblin
	however much you decorate it. Proportion is the thing a silhouette is read by, so
	each rig now owns its own.

	Colour is one number per part. `Shade` lerps the mob's own colour toward black below
	zero and toward white above it, so a whole figure still comes from the single Color
	on its MobConfig row and a tier reads as one creature rather than a paint chart. It
	is also what puts a thief in dark cloth and a brute in skin with shorts without
	either needing a second colour field.
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
	-- painted. Kept off everything else: a whole neon figure is a lamp, not a person.
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
-- Stock materials, so this costs no asset question at all. Cloth and leather under the
-- same light are most of what reads as "not plastic" at a glance, and a thief is almost
-- entirely made of both.
local FABRIC = Enum.Material.Fabric
local LEATHER = Enum.Material.Leather

--[[
	The thief.

	Ordinary human proportions, because that is the whole point of the silhouette: a
	field of these should read as people robbing the place, not as monsters. The chest
	is narrow — the goblin that stood here was 2.1 wide, and that width was most of why
	it read as a creature rather than a man.

	What carries at fifty studs is the hood and the covered face, so those are the two
	things drawn generously. Everything below the neck is cloth in one colour: a thief
	is a shape moving fast in the dark, not a costume you inspect.
]]
local THIEF: Rig = {
	Id = "Thief",
	RootSize = Vector3.new(2, 2, 1),

	Bones = {
		{
			Name = "LowerTorso",
			Shape = "Block",
			Size = Vector3.new(1.15, 0.85, 0.75),
			Shade = -0.15,
			Material = FABRIC,
		},
		{
			Name = "UpperTorso",
			Shape = "Block",
			Size = Vector3.new(1.55, 1.5, 0.9),
			Shade = 0,
			Material = FABRIC,
		},
		-- Hooded and masked, so the head is cloth rather than skin and takes the body's
		-- colour without looking wrong.
		{ Name = "Head", Shape = "Ball", Size = Vector3.new(1, 1, 1), Shade = 0.05, Material = FABRIC },

		{
			Name = "RightUpperArm",
			Shape = "Capsule",
			Size = Vector3.new(0.45, 1.2, 0.45),
			Shade = -0.05,
			Material = FABRIC,
		},
		{
			Name = "RightLowerArm",
			Shape = "Capsule",
			Size = Vector3.new(0.4, 1.1, 0.4),
			Shade = -0.1,
			Material = FABRIC,
		},
		{
			Name = "LeftUpperArm",
			Shape = "Capsule",
			Size = Vector3.new(0.45, 1.2, 0.45),
			Shade = -0.05,
			Material = FABRIC,
		},
		{
			Name = "LeftLowerArm",
			Shape = "Capsule",
			Size = Vector3.new(0.4, 1.1, 0.4),
			Shade = -0.1,
			Material = FABRIC,
		},

		{
			Name = "RightUpperLeg",
			Shape = "Capsule",
			Size = Vector3.new(0.55, 1.15, 0.55),
			Shade = -0.25,
			Material = FABRIC,
		},
		{
			Name = "RightLowerLeg",
			Shape = "Capsule",
			Size = Vector3.new(0.48, 1.05, 0.48),
			Shade = -0.32,
			Material = FABRIC,
		},
		{
			Name = "LeftUpperLeg",
			Shape = "Capsule",
			Size = Vector3.new(0.55, 1.15, 0.55),
			Shade = -0.25,
			Material = FABRIC,
		},
		{
			Name = "LeftLowerLeg",
			Shape = "Capsule",
			Size = Vector3.new(0.48, 1.05, 0.48),
			Shade = -0.32,
			Material = FABRIC,
		},

		--[[
			Hands and feet are bones now, not decor welded to a forearm.

			They were rigid, which meant they could not follow a wrist or an ankle
			because the rig had neither. Promoting them is free animation: GaitConfig
			already drives ankles, and PosePlayback was skipping that channel only
			because there was nothing there to find.
		]]
		{
			Name = "RightHand",
			Shape = "Ball",
			Size = Vector3.new(0.44, 0.44, 0.44),
			Shade = -0.45,
			Material = LEATHER,
		},
		{
			Name = "LeftHand",
			Shape = "Ball",
			Size = Vector3.new(0.44, 0.44, 0.44),
			Shade = -0.45,
			Material = LEATHER,
		},
		{
			Name = "RightFoot",
			Shape = "Block",
			Size = Vector3.new(0.5, 0.3, 0.82),
			Shade = -0.5,
			Material = LEATHER,
		},
		{
			Name = "LeftFoot",
			Shape = "Block",
			Size = Vector3.new(0.5, 0.3, 0.82),
			Shade = -0.5,
			Material = LEATHER,
		},
	},

	-- Stock R15 names, deliberately. This is what lets GaitConfig and StrikeConfig drive
	-- a thief with no mapping layer at all, and it is why reshaping a mob is safe while
	-- renaming one of these joints is not.
	Joints = {
		{
			Name = "Root",
			Part0 = "HumanoidRootPart",
			Part1 = "LowerTorso",
			C0 = Vector3.new(0, -0.55, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "Waist",
			Part0 = "LowerTorso",
			Part1 = "UpperTorso",
			C0 = Vector3.new(0, 0.42, 0),
			C1 = Vector3.new(0, -0.75, 0),
		},
		{
			Name = "Neck",
			Part0 = "UpperTorso",
			Part1 = "Head",
			C0 = Vector3.new(0, 0.75, 0),
			C1 = Vector3.new(0, -0.5, 0),
		},

		{
			Name = "RightShoulder",
			Part0 = "UpperTorso",
			Part1 = "RightUpperArm",
			C0 = Vector3.new(0.9, 0.55, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "RightElbow",
			Part0 = "RightUpperArm",
			Part1 = "RightLowerArm",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.new(0, 0.52, 0),
		},
		{
			Name = "LeftShoulder",
			Part0 = "UpperTorso",
			Part1 = "LeftUpperArm",
			C0 = Vector3.new(-0.9, 0.55, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "LeftElbow",
			Part0 = "LeftUpperArm",
			Part1 = "LeftLowerArm",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.new(0, 0.52, 0),
		},

		{
			Name = "RightHip",
			Part0 = "LowerTorso",
			Part1 = "RightUpperLeg",
			C0 = Vector3.new(0.34, -0.42, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "RightKnee",
			Part0 = "RightUpperLeg",
			Part1 = "RightLowerLeg",
			C0 = Vector3.new(0, -0.55, 0),
			C1 = Vector3.new(0, 0.5, 0),
		},
		{
			Name = "LeftHip",
			Part0 = "LowerTorso",
			Part1 = "LeftUpperLeg",
			C0 = Vector3.new(-0.34, -0.42, 0),
			C1 = Vector3.new(0, 0.55, 0),
		},
		{
			Name = "LeftKnee",
			Part0 = "LeftUpperLeg",
			Part1 = "LeftLowerLeg",
			C0 = Vector3.new(0, -0.55, 0),
			C1 = Vector3.new(0, 0.5, 0),
		},

		-- Stock R15 names again, so the gait's ankle channel finds something.
		{
			Name = "RightWrist",
			Part0 = "RightLowerArm",
			Part1 = "RightHand",
			C0 = Vector3.new(0, -0.55, 0),
			C1 = Vector3.new(0, 0.02, 0),
		},
		{
			Name = "LeftWrist",
			Part0 = "LeftLowerArm",
			Part1 = "LeftHand",
			C0 = Vector3.new(0, -0.55, 0),
			C1 = Vector3.new(0, 0.02, 0),
		},
		{
			Name = "RightAnkle",
			Part0 = "RightLowerLeg",
			Part1 = "RightFoot",
			C0 = Vector3.new(0, -0.52, 0),
			C1 = Vector3.new(0, 0.05, -0.16),
		},
		{
			Name = "LeftAnkle",
			Part0 = "LeftLowerLeg",
			Part1 = "LeftFoot",
			C0 = Vector3.new(0, -0.52, 0),
			C1 = Vector3.new(0, 0.05, -0.16),
		},
	},

	Decor = {
		-- The hood is the read. It is a shell a little larger than the skull, so the
		-- head reads as covered rather than as a ball wearing a hat.
		{
			Name = "Hood",
			Parent = "Head",
			Shape = "Ball",
			Size = Vector3.new(1.24, 1.2, 1.2),
			Offset = Vector3.new(0, 0.1, -0.06),
			Shade = -0.35,
			Material = FABRIC,
		},
		-- The peak is what makes it a hood and not a helmet: it overhangs the face and
		-- throws the eyes into shadow.
		{
			Name = "HoodPeak",
			Parent = "Head",
			Shape = "Wedge",
			Size = Vector3.new(0.92, 0.5, 0.7),
			Offset = Vector3.new(0, 0.4, 0.34),
			Rotation = Vector3.new(-20, 0, 0),
			Shade = -0.42,
			Material = FABRIC,
		},
		-- Cloth across the nose and mouth. Darker than the hood so the face reads as
		-- two layers rather than one solid lump.
		{
			Name = "Mask",
			Parent = "Head",
			Shape = "Block",
			Size = Vector3.new(1.02, 0.36, 1),
			Offset = Vector3.new(0, -0.14, 0.02),
			Shade = -0.55,
			Material = FABRIC,
		},
		-- One slit rather than the goblin's two lit eyeballs. A pair of glowing spheres
		-- is a monster; a band of light under a hood is a person hiding their face.
		{
			Name = "EyeSlit",
			Parent = "Head",
			Shape = "Block",
			Size = Vector3.new(0.62, 0.1, 0.08),
			Offset = Vector3.new(0, 0.08, 0.49),
			Shade = 0.9,
			Material = Enum.Material.Neon,
		},

		-- What they are here for.
		{
			Name = "Satchel",
			Parent = "LowerTorso",
			Shape = "Block",
			Size = Vector3.new(0.62, 0.5, 0.34),
			Offset = Vector3.new(0.55, -0.02, -0.44),
			Rotation = Vector3.new(0, 0, -12),
			Shade = -0.45,
			Material = LEATHER,
		},
		{
			Name = "Strap",
			Parent = "UpperTorso",
			Shape = "Block",
			Size = Vector3.new(0.2, 1.6, 0.12),
			Offset = Vector3.new(0.26, 0, 0.47),
			Rotation = Vector3.new(0, 0, 16),
			Shade = -0.5,
			Material = LEATHER,
		},
		{
			Name = "Belt",
			Parent = "LowerTorso",
			Shape = "Block",
			Size = Vector3.new(1.2, 0.22, 0.82),
			Offset = Vector3.new(0, -0.22, 0),
			Shade = -0.5,
			Material = LEATHER,
		},

		-- The coat hem. Legs emerging from cloth rather than straight out of a box is
		-- most of the difference between a figure and a set of shapes.
		{
			Name = "CoatHem",
			Parent = "LowerTorso",
			Shape = "Block",
			Size = Vector3.new(1.16, 0.5, 0.86),
			Offset = Vector3.new(0, -0.52, 0),
			Shade = -0.4,
			Material = FABRIC,
		},
	},
}

--[[
	The brute.

	This rig is deliberately ordinary. Its bones sit at the **stock R15 bind pose**
	BodyLoftConfig.BONES describes — shoulders at x +/- 1.5, hips at +/- 0.5, the torso
	from y 0.1 down to -0.9 — because a lofted body is dressed onto it, and the loft's
	geometry is authored against exactly those positions. A bone that sits anywhere else
	hands the mesh a constant offset and the body arrives bent.

	So the muscle does not come from the boxes any more. The boxes are the skeleton and
	the fallback; the bulk comes from the loft, which is given every muscle progress at
	1.0. That is the whole point of the change: a very muscular man rather than a large
	arrangement of shapes.

	It still has to look right unclothed, because the loft is allowed to fail — a client
	holds only seven or eight EditableMesh instances and a busy arena can spend them all
	— so these proportions are a heavy build, not a placeholder.
]]
local BRUTE: Rig = {
	Id = "Brute",
	RootSize = Vector3.new(2, 2, 1),

	Bones = {
		{ Name = "LowerTorso", Shape = "Block", Size = Vector3.new(1.9, 0.9, 1), Shade = 0 },
		{ Name = "UpperTorso", Shape = "Block", Size = Vector3.new(2.1, 1.6, 1.15), Shade = 0 },
		{ Name = "Head", Shape = "Ball", Size = Vector3.new(1.15, 1.15, 1.15), Shade = 0.04 },

		{ Name = "RightUpperArm", Shape = "Capsule", Size = Vector3.new(0.82, 1.1, 0.82), Shade = 0 },
		{ Name = "RightLowerArm", Shape = "Capsule", Size = Vector3.new(0.72, 1.05, 0.72), Shade = -0.03 },
		{ Name = "RightHand", Shape = "Ball", Size = Vector3.new(0.68, 0.68, 0.68), Shade = -0.02 },
		{ Name = "LeftUpperArm", Shape = "Capsule", Size = Vector3.new(0.82, 1.1, 0.82), Shade = 0 },
		{ Name = "LeftLowerArm", Shape = "Capsule", Size = Vector3.new(0.72, 1.05, 0.72), Shade = -0.03 },
		{ Name = "LeftHand", Shape = "Ball", Size = Vector3.new(0.68, 0.68, 0.68), Shade = -0.02 },

		{ Name = "RightUpperLeg", Shape = "Capsule", Size = Vector3.new(0.92, 1.25, 0.92), Shade = -0.06 },
		{ Name = "RightLowerLeg", Shape = "Capsule", Size = Vector3.new(0.8, 1.15, 0.8), Shade = -0.1 },
		{ Name = "RightFoot", Shape = "Block", Size = Vector3.new(0.86, 0.36, 1.1), Shade = -0.55 },
		{ Name = "LeftUpperLeg", Shape = "Capsule", Size = Vector3.new(0.92, 1.25, 0.92), Shade = -0.06 },
		{ Name = "LeftLowerLeg", Shape = "Capsule", Size = Vector3.new(0.8, 1.15, 0.8), Shade = -0.1 },
		{ Name = "LeftFoot", Shape = "Block", Size = Vector3.new(0.86, 0.36, 1.1), Shade = -0.55 },
	},

	--[[
		Every C1 is zero and every C0 is the plain difference between two bind
		positions, so each part lands exactly on the coordinate BodyLoftConfig.BONES
		names for it. Written this way on purpose: the moment a C1 starts nudging a
		limb for looks, the rig and the mesh disagree and nobody can see why.
	]]
	Joints = {
		{
			Name = "Root",
			Part0 = "HumanoidRootPart",
			Part1 = "LowerTorso",
			C0 = Vector3.new(0, -0.9, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "Waist",
			Part0 = "LowerTorso",
			Part1 = "UpperTorso",
			C0 = Vector3.new(0, 1, 0),
			C1 = Vector3.zero,
		},
		-- The head is not a loft bone; it keeps its own placement above the chest.
		{
			Name = "Neck",
			Part0 = "UpperTorso",
			Part1 = "Head",
			C0 = Vector3.new(0, 1.35, 0),
			C1 = Vector3.zero,
		},

		{
			Name = "RightShoulder",
			Part0 = "UpperTorso",
			Part1 = "RightUpperArm",
			C0 = Vector3.new(1.5, 0.2, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "RightElbow",
			Part0 = "RightUpperArm",
			Part1 = "RightLowerArm",
			C0 = Vector3.new(0, -0.59, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "RightWrist",
			Part0 = "RightLowerArm",
			Part1 = "RightHand",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftShoulder",
			Part0 = "UpperTorso",
			Part1 = "LeftUpperArm",
			C0 = Vector3.new(-1.5, 0.2, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftElbow",
			Part0 = "LeftUpperArm",
			Part1 = "LeftLowerArm",
			C0 = Vector3.new(0, -0.59, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftWrist",
			Part0 = "LeftLowerArm",
			Part1 = "LeftHand",
			C0 = Vector3.new(0, -0.6, 0),
			C1 = Vector3.zero,
		},

		{
			Name = "RightHip",
			Part0 = "LowerTorso",
			Part1 = "RightUpperLeg",
			C0 = Vector3.new(0.5, -0.59, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "RightKnee",
			Part0 = "RightUpperLeg",
			Part1 = "RightLowerLeg",
			C0 = Vector3.new(0, -0.73, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "RightAnkle",
			Part0 = "RightLowerLeg",
			Part1 = "RightFoot",
			C0 = Vector3.new(0, -0.63, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftHip",
			Part0 = "LowerTorso",
			Part1 = "LeftUpperLeg",
			C0 = Vector3.new(-0.5, -0.59, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftKnee",
			Part0 = "LeftUpperLeg",
			Part1 = "LeftLowerLeg",
			C0 = Vector3.new(0, -0.73, 0),
			C1 = Vector3.zero,
		},
		{
			Name = "LeftAnkle",
			Part0 = "LeftLowerLeg",
			Part1 = "LeftFoot",
			C0 = Vector3.new(0, -0.63, 0),
			C1 = Vector3.zero,
		},
	},

	--[[
		Almost nothing. Decor rides the bones rigidly, and anything sitting proud of
		the chest would poke through the lofted body that is dressed over it. What is
		left is the face, which the loft does not generate, and the shorts.
	]]
	Decor = {
		{
			Name = "Brow",
			Parent = "Head",
			Shape = "Block",
			Size = Vector3.new(0.9, 0.16, 0.36),
			Offset = Vector3.new(0, 0.2, 0.46),
			Rotation = Vector3.new(-14, 0, 0),
			Shade = -0.2,
		},
		{
			Name = "EyeRight",
			Parent = "Head",
			Shape = "Ball",
			Size = Vector3.new(0.17, 0.17, 0.17),
			Offset = Vector3.new(0.26, 0.06, 0.53),
			Shade = -0.85,
		},
		{
			Name = "EyeLeft",
			Parent = "Head",
			Shape = "Ball",
			Size = Vector3.new(0.17, 0.17, 0.17),
			Offset = Vector3.new(-0.26, 0.06, 0.53),
			Shade = -0.85,
		},
	},
}

local rigs: { Rig } = { THIEF, BRUTE }

MobRigConfig.List = rigs
MobRigConfig.Thief = THIEF
MobRigConfig.Brute = BRUTE
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
	return if kind == "Boss" then BRUTE else THIEF
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
