--!strict
--[[
	BodyLoftConfig — the player's body as a surface, described in numbers.

	This replaces the primitive-cosmetic system, and the difference is not one of
	degree. There, a bicep was an ellipsoid welded onto an arm; here it is a *bulge in
	the arm's own surface*. Nothing is stuck on, so nothing can stick out, and the
	seams that came from butting solids together do not exist to be hidden.

	## Why the body is five tubes

	The whole body is one EditableMesh, because a Play client allows only seven or
	eight EditableMesh instances at once — a hard cap on instances, not a memory
	budget. That measurement is what killed the previous fourteen-piece design, and it
	is why nothing here may be split into more meshes for convenience.

	Inside that one mesh the body is five separate tubes — torso, two arms, two legs —
	rather than one branching surface. A properly branched shoulder is a great deal of
	topology for something no player will ever see: the tubes overlap inside the body
	at the shoulder and hip, and the overlap is buried. They are all skinned to the
	same skeleton, so they move as one thing regardless.

	The head, hands and feet stay as stock R15 parts. They are small, they read fine as
	they are, and every ring spent on them is a ring not spent on a chest.

	## Conventions

	Bind space is relative to the HumanoidRootPart, Y up, and the avatar faces -Z.
	A ring's angle runs 0..2π with **0 at the front**, so `offset = (sin a · RX, 0,
	-cos a · RZ)`. Front is 0, the character's right is π/2, back is π. Muscle rows
	read naturally from that: a bicep sits at 0 and a tricep at π.

	The skeleton is deliberately **flat** — every bone parents to Root. A bone's
	runtime transform is then just `bind⁻¹ · current` from its R15 part, with no
	accumulation down a chain and no chance of a parent's error compounding into a
	child. It costs nothing here because we read every joint's live CFrame anyway.

	Plain numbers throughout, no Vector3 or CFrame, so this module loads under the bare
	`luau` CLI and `RunSelfTest` runs in check.sh rather than only in Studio.
]]

local BodyLoftConfig = {}

BodyLoftConfig.FOLDER_NAME = "GeneratedLoft"
--[[
	Non-player models that should also be dressed in the generated body.

	Tagged rather than discovered, because the cap on EditableMesh instances means this
	can never be "every model that happens to have an R15 rig" — it has to be an
	explicit, small, deliberate list. MobService tags bosses and nothing else.
]]
BodyLoftConfig.MOB_TAG = "LoftBody"
BodyLoftConfig.PART_NAME = "Body"

--[[
	Bind pose, relative to the HumanoidRootPart.

	Authored rather than sampled from a live character on purpose. A running rig is
	mid-animation and measurably asymmetric — sampling one gives a left arm at
	x = -1.520 against a right arm at 1.525, and that asymmetry would be baked into
	the mesh forever. These are the R15 rest offsets, symmetrised.
]]
export type Bone = { Name: string, Part: string, X: number, Y: number, Z: number }

local BONES: { Bone } = {
	{ Name = "Root", Part = "HumanoidRootPart", X = 0, Y = 0, Z = 0 },
	{ Name = "LowerTorso", Part = "LowerTorso", X = 0, Y = -0.9, Z = 0 },
	{ Name = "UpperTorso", Part = "UpperTorso", X = 0, Y = 0.1, Z = 0 },
	{ Name = "LeftUpperArm", Part = "LeftUpperArm", X = -1.5, Y = 0.3, Z = 0 },
	{ Name = "LeftLowerArm", Part = "LeftLowerArm", X = -1.5, Y = -0.29, Z = 0 },
	{ Name = "LeftHand", Part = "LeftHand", X = -1.5, Y = -0.89, Z = 0 },
	{ Name = "RightUpperArm", Part = "RightUpperArm", X = 1.5, Y = 0.3, Z = 0 },
	{ Name = "RightLowerArm", Part = "RightLowerArm", X = 1.5, Y = -0.29, Z = 0 },
	{ Name = "RightHand", Part = "RightHand", X = 1.5, Y = -0.89, Z = 0 },
	{ Name = "LeftUpperLeg", Part = "LeftUpperLeg", X = -0.5, Y = -1.49, Z = 0 },
	{ Name = "LeftLowerLeg", Part = "LeftLowerLeg", X = -0.5, Y = -2.22, Z = 0 },
	{ Name = "LeftFoot", Part = "LeftFoot", X = -0.5, Y = -2.85, Z = 0 },
	{ Name = "RightUpperLeg", Part = "RightUpperLeg", X = 0.5, Y = -1.49, Z = 0 },
	{ Name = "RightLowerLeg", Part = "RightLowerLeg", X = 0.5, Y = -2.22, Z = 0 },
	{ Name = "RightFoot", Part = "RightFoot", X = 0.5, Y = -2.85, Z = 0 },
}
BodyLoftConfig.BONES = BONES

-- Roblox allows at most four bone influences per vertex; a fifth is rejected with
-- "More skinning elements than allowed".
BodyLoftConfig.MAX_INFLUENCES = 4

-- How dark the deepest groove goes, as a fraction toward black. Only grooves are
-- tinted at all; see ReliefTint.
BodyLoftConfig.GROOVE_SHADE = 0.18

--[[
	How cut a body is, independently of how big it is.

	Until now definition was purely a function of the same progress that drove size, so
	nothing could be big and lean at once — a maxed body was simply a larger version of a
	beginner's. Leanness is the missing axis: it deepens the cuts between muscles and
	darkens the shadow in them without touching a single radius.

	1 is a player and the default everywhere. A boss runs higher, which is what lets it
	look like something no amount of training produces.

	Clamped rather than trusted. It multiplies values that self-tests guard — groove
	depth against the minimum surviving radius, stroke depth against pure black — and a
	number arriving from an attribute has no business being able to walk through those.
]]
BodyLoftConfig.DEFAULT_LEANNESS = 1
BodyLoftConfig.MAX_LEANNESS = 2
BodyLoftConfig.LEANNESS_ATTRIBUTE = "LoftLeanness"

function BodyLoftConfig.Leanness(value: number?): number
	if value == nil or value ~= value then
		return BodyLoftConfig.DEFAULT_LEANNESS
	end
	return math.clamp(value, 1, BodyLoftConfig.MAX_LEANNESS)
end

-- The widest authored torso half-width. Arm spread is measured against this, so a
-- chest that grows by 65% pushes the arms out by 65% of this, not of their own girth.
BodyLoftConfig.TORSO_HALF_WIDTH = 1.0

--[[
	A ring is one cross-section of a tube: where it sits in bind space, how wide and
	deep it is, and which bones carry it. Weights are normalised by the builder, so a
	row may state them in whatever proportions read clearly.
]]
export type Influence = { Bone: string, Weight: number }
export type Ring = {
	X: number,
	Y: number,
	Z: number,
	RX: number,
	RZ: number,
	Bones: { Influence },
	-- "Skin" or "Pants". AppearanceService paints the rig through BodyColors, so the
	-- live rig part is the source of truth for what colour this band should be.
	Slot: string,
}
export type Tube = {
	Id: string,
	Side: string?,
	--[[
		How far this tube rides outward as the chest widens, as a fraction of the
		torso's width growth. Arms follow it fully — a 3.3-stud chest with the arms
		still pinned at the lean body's 1.5 buries them in the ribs. Legs follow it
		only a little, because hips widen far less than shoulders.
	]]
	Spread: number,
	--[[
		This tube's column in the texture atlas. Without one, every tube maps to the
		same square and a chest painting repeats identically down a shin.

		The angle is rotated half a turn inside the column so the body's FRONT centre
		line sits mid-column. Left as-is, the wrap seam runs straight down the abs —
		the most visible place on the model. Rotated, it falls down the back, which is
		where real clothing puts it.
	]]
	U0: number,
	U1: number,
	Rings: { Ring },
}

local function ring(
	y: number,
	rx: number,
	rz: number,
	bones: { Influence },
	slot: string?,
	x: number?,
	z: number?
): Ring
	return { X = x or 0, Y = y, Z = z or 0, RX = rx, RZ = rz, Bones = bones, Slot = slot or "Skin" }
end

local tubes: { Tube } = {}

-- Torso: hips to neck. Deliberately deeper than the stock R15 slab and tapered to a
-- waist, because a chest above a waist is what reads as a physique at a glance.
table.insert(tubes, {
	Id = "Torso",
	Spread = 0,
	U0 = 0,
	U1 = 0.5,
	Rings = {
		ring(-1.55, 0.60, 0.40, { { Bone = "LowerTorso", Weight = 1 } }, "Pants"),
		ring(-1.20, 0.66, 0.42, { { Bone = "LowerTorso", Weight = 1 } }, "Pants"),
		ring(
			-0.90,
			0.66,
			0.42,
			{ { Bone = "LowerTorso", Weight = 0.8 }, { Bone = "UpperTorso", Weight = 0.2 } },
			"Pants"
		),
		-- The waist, pinched hard on purpose. A chest reads as big because of what
		-- sits under it: the V-taper does more for the silhouette than the chest's
		-- own width ever does, and the previous 1.22 ratio is why this looked like
		-- a barrel however wide the shoulders got.
		ring(
			-0.60,
			0.64,
			0.42,
			{ { Bone = "LowerTorso", Weight = 0.45 }, { Bone = "UpperTorso", Weight = 0.55 } }
		),
		ring(-0.30, 0.68, 0.44, { { Bone = "UpperTorso", Weight = 1 } }),
		ring(0.00, 0.82, 0.52, { { Bone = "UpperTorso", Weight = 1 } }),
		ring(0.28, 0.98, 0.60, { { Bone = "UpperTorso", Weight = 1 } }),
		-- The pec shelf and the yoke of the shoulders above it.
		ring(0.52, 1.10, 0.66, { { Bone = "UpperTorso", Weight = 1 } }),
		ring(0.72, 1.14, 0.62, { { Bone = "UpperTorso", Weight = 1 } }),
		ring(0.88, 0.92, 0.48, { { Bone = "UpperTorso", Weight = 1 } }),
		ring(1.00, 0.44, 0.32, { { Bone = "UpperTorso", Weight = 1 } }),
	},
})

for _, side in { "Left", "Right" } do
	local sx = if side == "Left" then -1 else 1
	-- Arm: shoulder cap to wrist. The top rings carry some UpperTorso weight so the
	-- deltoid stays welded to the shoulder instead of shearing away when the arm lifts.
	table.insert(tubes, {
		Id = `{side}Arm`,
		Side = side,
		Spread = 1,
		U0 = if side == "Left" then 0.5 else 0.65,
		U1 = if side == "Left" then 0.65 else 0.8,
		Rings = {
			ring(0.86, 0.34, 0.34, {
				{ Bone = "UpperTorso", Weight = 0.7 },
				{ Bone = `{side}UpperArm`, Weight = 0.3 },
			}, "Skin", sx * 1.18),
			ring(0.78, 0.46, 0.46, {
				{ Bone = "UpperTorso", Weight = 0.55 },
				{ Bone = `{side}UpperArm`, Weight = 0.45 },
			}, "Skin", sx * 1.28),
			ring(0.68, 0.52, 0.52, {
				{ Bone = "UpperTorso", Weight = 0.35 },
				{ Bone = `{side}UpperArm`, Weight = 0.65 },
			}, "Skin", sx * 1.37),
			ring(0.58, 0.56, 0.56, {
				{ Bone = "UpperTorso", Weight = 0.2 },
				{ Bone = `{side}UpperArm`, Weight = 0.8 },
			}, "Skin", sx * 1.44),
			ring(0.30, 0.56, 0.56, { { Bone = `{side}UpperArm`, Weight = 1 } }, "Skin", sx * 1.5),
			ring(0.02, 0.50, 0.50, { { Bone = `{side}UpperArm`, Weight = 1 } }, "Skin", sx * 1.5),
			ring(-0.24, 0.40, 0.40, {
				{ Bone = `{side}UpperArm`, Weight = 0.5 },
				{ Bone = `{side}LowerArm`, Weight = 0.5 },
			}, "Skin", sx * 1.5),
			ring(-0.50, 0.44, 0.44, { { Bone = `{side}LowerArm`, Weight = 1 } }, "Skin", sx * 1.5),
			ring(-0.76, 0.34, 0.34, { { Bone = `{side}LowerArm`, Weight = 1 } }, "Skin", sx * 1.5),
			ring(-0.92, 0.27, 0.27, {
				{ Bone = `{side}LowerArm`, Weight = 0.6 },
				{ Bone = `{side}Hand`, Weight = 0.4 },
			}, "Skin", sx * 1.5),
		},
	})

	-- Leg: hip to ankle. The calf is wider than the knee above it, as a real leg is.
	table.insert(tubes, {
		Id = `{side}Leg`,
		Side = side,
		Spread = 0.3,
		U0 = if side == "Left" then 0.8 else 0.9,
		U1 = if side == "Left" then 0.9 else 1,
		Rings = {
			ring(-0.98, 0.62, 0.58, {
				{ Bone = "LowerTorso", Weight = 0.4 },
				{ Bone = `{side}UpperLeg`, Weight = 0.6 },
			}, "Pants", sx * 0.5),
			ring(-1.30, 0.66, 0.62, { { Bone = `{side}UpperLeg`, Weight = 1 } }, "Pants", sx * 0.5),
			ring(-1.65, 0.62, 0.58, { { Bone = `{side}UpperLeg`, Weight = 1 } }, "Pants", sx * 0.5),
			ring(-1.95, 0.48, 0.47, { { Bone = `{side}UpperLeg`, Weight = 1 } }, "Skin", sx * 0.5),
			ring(-2.20, 0.40, 0.42, {
				{ Bone = `{side}UpperLeg`, Weight = 0.5 },
				{ Bone = `{side}LowerLeg`, Weight = 0.5 },
			}, "Skin", sx * 0.5),
			ring(-2.45, 0.50, 0.52, { { Bone = `{side}LowerLeg`, Weight = 1 } }, "Skin", sx * 0.5),
			ring(-2.70, 0.35, 0.37, { { Bone = `{side}LowerLeg`, Weight = 1 } }, "Skin", sx * 0.5),
			ring(-2.86, 0.28, 0.30, {
				{ Bone = `{side}LowerLeg`, Weight = 0.6 },
				{ Bone = `{side}Foot`, Weight = 0.4 },
			}, "Skin", sx * 0.5),
		},
	})
end

BodyLoftConfig.TUBES = tubes

--[[
	A muscle. Not an object — a displacement of the surface it lives on.

	`T` runs 0..1 from the first ring of the tube to the last. `Angle` is radians with
	0 at the front. Spread is the Gaussian falloff either side, so a muscle with a
	small SpreadAngle is a tight cord and a large one is a broad sheet.
]]
export type Groove = {
	Id: string,
	StatId: string,
	Tube: string,
	T: number,
	Angle: number,
	SpreadT: number,
	SpreadAngle: number,
	--[[
		How far this pushes the surface, in studs. **Negative carves inward.**

		Grooves are the whole reason a body reads as separate muscles. Six swells
		side by side make one smooth belly; it is the channel between them that makes
		a six-pack. The first version of this file had 26 muscles and not one groove,
		which is why every increase in amplitude only produced a rounder barrel.

		A groove wants a much tighter SpreadAngle than a belly — a crevice is narrow
		and a muscle is broad — but it is the same row, not a new concept.
	]]
	Amplitude: number,
	Start: number,
	Full: number,
}

local grooves: { Groove } = {}
local PI = math.pi

--[[
	Where a secondary muscle head begins to separate out of its group.

	Late on purpose. Every group's primary head keeps the early ramp it always had, so
	a beginner grows a recognisable body on the same curve as before; the second and
	third heads arrive only near the top. That is what makes maxing out a change in
	*kind* rather than one more increment of size — the arms do not merely get bigger,
	they come apart into pieces. Shared by the lobes and the grooves that cut between
	them, because a head and its channel must arrive together or the split reads as a
	dent in a smooth muscle.
]]
local SPLIT_START = 0.58

local function addGroove(
	id: string,
	statId: string,
	tube: string,
	t: number,
	angle: number,
	spreadT: number,
	spreadAngle: number,
	amplitude: number,
	start: number,
	full: number
)
	table.insert(grooves, {
		Id = id,
		StatId = statId,
		Tube = tube,
		T = t,
		Angle = angle,
		SpreadT = spreadT,
		SpreadAngle = spreadAngle,
		Amplitude = amplitude,
		Start = start,
		Full = full,
	})
end

--[[
	Lobes — the muscles themselves, as solid shapes under the skin.

	A muscle is a sphere, and the body's surface is the smooth union of the base tube
	and every sphere on it. That is a deliberate replacement for what used to be here:
	a Gaussian added to the radius. A Gaussian is a soft hill that fades in every
	direction, so scaling it up gives a taller hill and never a mass with an edge —
	which is why several rounds of raising amplitudes changed almost nothing on screen.
	A sphere breaking through a surface has an edge for free.

	Placement is in the tube's own frame, not in body space:

	  T       where along the tube, 0..1, same convention as everything else
	  Angle   radians, 0 at the body's front
	  Out     how far the centre sits from the axis, as a fraction of the local
	          radius. Below 1 it is buried; the sphere only shows where its radius
	          carries it past the surface
	  Radius  its size in studs
	  Blend   how softly it fuses. Small reads as a hard-edged delt, large as a pec
	          melting into the chest

	Authoring in tube space means a lobe follows the body automatically as it scales
	with the growth curve and as the arms spread outward — there is no second set of
	coordinates to keep in sync, which is the mistake that would otherwise show up as
	muscles drifting off the body at high rank.
]]
export type Lobe = {
	Id: string,
	StatId: string,
	Tube: string,
	T: number,
	Angle: number,
	Out: number,
	Radius: number,
	Blend: number,
	--[[
		Per-axis stretch, defaulting to 1. A sphere cannot be a latissimus: that
		muscle is a broad flat sheet, and rendered as a ball it reads as a lump on an
		otherwise smooth back. Stretching lets one row be wide and shallow, or long
		and thin, without needing a second kind of shape.

		X is across the body, Y up it, Z front to back.
	]]
	StretchX: number,
	StretchY: number,
	StretchZ: number,
	Start: number,
	Full: number,
}

local lobes: { Lobe } = {}

local function lobe(
	id: string,
	statId: string,
	tube: string,
	t: number,
	angle: number,
	out: number,
	radius: number,
	blend: number,
	start: number,
	full: number,
	stretch: { number }?
)
	local sx, sy, sz = 1, 1, 1
	if stretch ~= nil then
		sx, sy, sz = stretch[1], stretch[2], stretch[3]
	end
	table.insert(lobes, {
		Id = id,
		StatId = statId,
		Tube = tube,
		T = t,
		Angle = angle,
		Out = out,
		Radius = radius,
		Blend = blend,
		StretchX = sx,
		StretchY = sy,
		StretchZ = sz,
		Start = start,
		Full = full,
	})
end

--[[
	Muscles come in heads, and heads are what the eye counts.

	Every group below used to be a single lobe: one deltoid, one bicep, one pec, one
	lat. That reads as a *smooth* big arm rather than a segmented one, and no amount of
	raising a radius fixes it — a bigger ball is still one ball. Splitting a group into
	the heads it actually has, with a groove between them, is what makes an arm read as
	built rather than inflated. Two half-size lobes side by side look bigger than one
	large one, because the channel between them gives the eye an edge to measure.

	The primary head of each group keeps its original early ramp, so a beginner grows a
	recognisable body on the same curve as before. The secondary heads start late
	(SPLIT_START and after), which is what makes the top of the grind a visible change
	in *kind* rather than one more increment of size: the arms do not merely get bigger,
	they come apart into pieces.
]]

for _, side in { "Left", "Right" } do
	local arm = `{side}Arm`
	-- The deltoid wraps the outside of the shoulder: +pi/2 is the character's right,
	-- -pi/2 their left.
	local outward = if side == "Left" then -PI / 2 else PI / 2

	-- Three heads on a shoulder cap barely half a stud wide, so they are deliberately
	-- tight and hard-edged: a delt that melts into the arm is the thing that made the
	-- old shoulder read as a sphere. Blend is the lever, not radius.
	lobe(`{side}DeltSide`, "Arms", arm, 0.12, outward, 0.50, 0.52, 0.10, 0.08, 0.72)
	lobe(`{side}DeltFront`, "Arms", arm, 0.13, outward * 0.45, 0.50, 0.42, 0.10, SPLIT_START, 0.95)
	lobe(`{side}DeltRear`, "Arms", arm, 0.13, outward * 1.55, 0.50, 0.40, 0.11, SPLIT_START, 0.95)

	-- StretchY below 1 shortens the lobe *along the arm*, which is what turns a ball
	-- into a peak. A bicep is short and tall, not a sausage.
	lobe(`{side}Bicep`, "Arms", arm, 0.31, 0, 0.46, 0.50, 0.13, 0.12, 0.82, { 1, 0.82, 1 })
	lobe(`{side}Brachialis`, "Arms", arm, 0.43, outward * 0.5, 0.55, 0.34, 0.14, SPLIT_START, 1.00)

	lobe(`{side}Tricep`, "Arms", arm, 0.35, PI, 0.46, 0.44, 0.16, 0.22, 0.95)
	-- The outer head that makes the horseshoe. Note the angle: PI - outward*0.45 lands
	-- outboard-and-behind on both sides, where writing PI + a bare offset would put the
	-- left one on the inside of the arm and pass the mirror test anyway.
	lobe(`{side}TricepLateral`, "Arms", arm, 0.44, PI - outward * 0.45, 0.55, 0.36, 0.13, SPLIT_START, 1.00)

	-- A trained forearm is nearly as thick as the upper arm, and splitting it front and
	-- back is most of why. StretchY above 1 is right here for the opposite reason it is
	-- wrong on a bicep: these are long straps, not peaks.
	lobe(`{side}Forearm`, "Arms", arm, 0.62, 0, 0.44, 0.33, 0.13, 0.30, 1.00, { 1, 1.25, 1 })
	lobe(`{side}ForearmExtensor`, "Arms", arm, 0.66, PI, 0.44, 0.30, 0.13, SPLIT_START, 1.00, { 1, 1.25, 1 })

	local leg = `{side}Leg`
	lobe(`{side}Glute`, "Legs", leg, 0.05, PI, 0.46, 0.60, 0.20, 0.10, 0.80)

	lobe(`{side}Quad`, "Legs", leg, 0.32, 0, 0.46, 0.56, 0.17, 0.12, 0.84, { 1, 1.3, 1 })
	lobe(`{side}VastusLateralis`, "Legs", leg, 0.38, outward * 0.42, 0.46, 0.38, 0.15, SPLIT_START, 1.00)
	-- The teardrop just above the knee. Small and low, and the last thing to arrive.
	lobe(`{side}VastusMedialis`, "Legs", leg, 0.52, -outward * 0.38, 0.46, 0.30, 0.12, 0.66, 1.00)

	lobe(`{side}Hamstring`, "Legs", leg, 0.36, PI, 0.46, 0.52, 0.19, 0.25, 0.95)
	lobe(`{side}Calf`, "Legs", leg, 0.70, PI - outward * 0.20, 0.42, 0.42, 0.14, 0.28, 1.00)
	lobe(`{side}CalfLateral`, "Legs", leg, 0.76, PI + outward * 0.20, 0.42, 0.34, 0.14, SPLIT_START, 1.00)
end

-- Chest and Back share the torso tube but listen to different stats, so training
-- pecs never grows lats and vice versa.
for _, sign in { -1, 1 } do
	local side = if sign < 0 then "Left" else "Right"

	-- A pec is a shelf, not a dome, and the shelf is the lower head: wide across the
	-- body (StretchX) and squashed vertically (StretchY) so it ends in an edge rather
	-- than curving away. The upper head sits above and behind it toward the collarbone.
	lobe(
		`{side}PecLower`,
		"Chest",
		"Torso",
		0.705,
		sign * 0.44,
		0.58,
		0.52,
		0.13,
		0.10,
		0.80,
		{ 1.15, 0.62, 1 }
	)
	lobe(`{side}PecUpper`, "Chest", "Torso", 0.775, sign * 0.40, 0.58, 0.48, 0.14, 0.34, 0.92, { 1, 0.85, 1 })

	--[[
		The lat, and the reason Stretch exists at all.

		A latissimus is a broad flat sheet down the side of the ribs. Rendered as a
		sphere — which is what every lobe here was until now — it is a lump on an
		otherwise smooth back, and the wide V that makes the whole silhouette read
		simply is not there. Stretched tall in Y and flattened in Z it becomes the
		sheet, and the flare is what pushes the arms out.
	]]
	lobe(
		`{side}Lat`,
		"Back",
		"Torso",
		0.60,
		sign * (PI / 2 - 0.15),
		0.56,
		0.54,
		0.20,
		0.16,
		0.88,
		{ 1.15, 1.7, 0.6 }
	)
	lobe(
		`{side}LatSweep`,
		"Back",
		"Torso",
		0.44,
		sign * (PI / 2 + 0.22),
		0.56,
		0.44,
		0.22,
		0.40,
		0.95,
		{ 1.1, 1.5, 0.65 }
	)
	-- Between the lat and the rear delt. Small, but the armpit reads as a hollow
	-- without it and the back loses its outline against the arm.
	lobe(`{side}Teres`, "Back", "Torso", 0.66, sign * (PI / 2 + 0.55), 0.62, 0.46, 0.14, SPLIT_START, 0.95)

	lobe(`{side}Trap`, "Back", "Torso", 0.86, sign * 0.55 + PI, 0.50, 0.44, 0.19, 0.24, 0.90)
	-- The shoulder blade slab. Wide and shallow, so it is a plate between spine and
	-- trap rather than another ball.
	lobe(
		`{side}Rhomboid`,
		"Back",
		"Torso",
		0.70,
		sign * (PI - 0.40),
		0.62,
		0.40,
		0.15,
		SPLIT_START,
		0.95,
		{ 1.3, 0.9, 1 }
	)

	lobe(`{side}Erector`, "Back", "Torso", 0.44, sign * 0.30 + PI, 0.54, 0.36, 0.16, 0.30, 0.95)
	lobe(`{side}Oblique`, "Core", "Torso", 0.34, sign * 1.05, 0.58, 0.34, 0.14, 0.42, 1.00)
end

-- The abdominal wall: six small lobes in two columns, cut apart by the grooves
-- below. Small on purpose — an ab block that protrudes as far as a pec reads as a
-- tumour, and the separation does the work.
for row, t in { 0.56, 0.46, 0.36 } do
	for _, sign in { -1, 1 } do
		lobe(
			`Ab{row}{if sign < 0 then "L" else "R"}`,
			"Core",
			"Torso",
			t,
			sign * 0.20,
			0.70,
			0.26,
			0.09,
			0.30 + (row - 1) * 0.08,
			0.92
		)
	end
end

BodyLoftConfig.LOBES = lobes

--[[
	Grooves — the crevices that turn one mass into separate muscles.

	Written as their own block rather than mixed in with the bellies because they are
	read differently: a belly is "how big is this muscle", a groove is "how deeply is
	it cut away from its neighbour", and tuning one against the other is much easier
	when they are side by side.
]]
local function groove(
	id: string,
	statId: string,
	tube: string,
	t: number,
	angle: number,
	spreadT: number,
	spreadAngle: number,
	depth: number,
	start: number,
	full: number
)
	addGroove(id, statId, tube, t, angle, spreadT, spreadAngle, -depth, start, full)
end

-- The abdominal grid: one channel down the middle, three across it.
groove("LineaAlba", "Core", "Torso", 0.46, 0, 0.16, 0.16, 0.16, 0.18, 0.75)
for row, t in { 0.57, 0.47, 0.37 } do
	groove(`AbGap{row}`, "Core", "Torso", t, 0, 0.028, 0.42, 0.13, 0.22 + row * 0.05, 0.85)
end

for _, sign in { -1, 1 } do
	local tag = if sign < 0 then "L" else "R"
	-- Between the pecs, and underneath them, so the chest is a shelf not a dome.
	groove(`PecUnder{tag}`, "Chest", "Torso", 0.665, sign * 0.34, 0.035, 0.30, 0.17, 0.15, 0.78)
	-- The flank, separating lat from oblique.
	groove(`Flank{tag}`, "Back", "Torso", 0.45, sign * 1.35, 0.13, 0.20, 0.13, 0.25, 0.90)
	-- The spine channel.
	groove(`Spine{tag}`, "Back", "Torso", 0.55, PI + sign * 0.06, 0.20, 0.10, 0.12, 0.25, 0.88)
end
groove("PecCleft", "Chest", "Torso", 0.72, 0, 0.09, 0.14, 0.18, 0.12, 0.70)

--[[
	The cuts that come with the split heads.

	Every lobe added above needs the channel that separates it from its neighbour, or
	the two simply fuse into a larger version of the single lobe they replaced — which
	is the failure this file's header describes at its very start. They share the split
	heads' late Start for the same reason: the body comes apart into pieces at the top
	of the curve, rather than arriving pre-cut.
]]
for _, sign in { -1, 1 } do
	local tag = if sign < 0 then "L" else "R"
	-- The shelf under the pec. Tight in T and wide in angle: an under-pec line is a
	-- horizontal edge, and the old PecUnder is a nick beside it rather than the line
	-- itself. This is what stops the chest curving away into the ribs.
	groove(`PecShelf{tag}`, "Chest", "Torso", 0.678, sign * 0.44, 0.022, 0.46, 0.16, 0.40, 0.90)
	-- Between the two pec heads.
	groove(`PecSplit{tag}`, "Chest", "Torso", 0.742, sign * 0.42, 0.030, 0.34, 0.12, SPLIT_START, 0.95)
	--[[
		The lat's outer edge, from armpit to waist.

		The single most recognisable line in the silhouette: it is the outside of the V,
		and it is what makes a back read as wide rather than merely thick. Deliberately
		long in T and narrow in angle — it is one continuous line down the side of the
		body, not a dimple.
	]]
	groove(`LatEdge{tag}`, "Back", "Torso", 0.52, sign * (PI / 2 + 0.42), 0.22, 0.12, 0.15, 0.30, 0.92)
	-- Above it, cutting the lat free of the teres and the rear delt so the armpit
	-- reads as a hollow instead of a fused mass.
	groove(
		`TeresGap{tag}`,
		"Back",
		"Torso",
		0.70,
		sign * (PI / 2 + 0.30),
		0.045,
		0.20,
		0.13,
		SPLIT_START,
		0.95
	)
	-- The shoulder blade's inner border, between rhomboid and spine.
	groove(`ScapulaGap{tag}`, "Back", "Torso", 0.70, sign * (PI - 0.16), 0.10, 0.11, 0.12, SPLIT_START, 0.95)
	-- The serratus fingers along the ribs, under the armpit and above the oblique.
	groove(`Serratus{tag}`, "Core", "Torso", 0.50, sign * 1.20, 0.055, 0.16, 0.11, 0.55, 1.00)
end

for _, side in { "Left", "Right" } do
	local arm = `{side}Arm`
	local outward = if side == "Left" then -PI / 2 else PI / 2
	-- A ring around the deltoid, cutting it free of both pec and bicep.
	groove(`{side}DeltGap`, "Arms", arm, 0.19, outward, 0.035, 1.8, 0.15, 0.10, 0.72)
	-- The two channels down the sides of the upper arm, between bicep and tricep.
	groove(`{side}ArmSeamF`, "Arms", arm, 0.34, outward, 0.16, 0.22, 0.13, 0.18, 0.82)
	groove(`{side}ArmSeamB`, "Arms", arm, 0.34, -outward, 0.16, 0.22, 0.13, 0.18, 0.82)
	-- The elbow.
	groove(`{side}ElbowGap`, "Arms", arm, 0.53, 0, 0.030, 2.4, 0.11, 0.28, 0.90)
	-- Between the three deltoid heads. Very tight in T, wide in angle: these run
	-- down the cap rather than around it, which is the opposite of DeltGap above.
	groove(`{side}DeltFrontGap`, "Arms", arm, 0.13, outward * 0.72, 0.10, 0.075, 0.13, SPLIT_START, 0.95)
	groove(`{side}DeltRearGap`, "Arms", arm, 0.13, outward * 1.28, 0.10, 0.075, 0.13, SPLIT_START, 0.95)
	-- The horseshoe: the line between the tricep's long and lateral heads.
	groove(`{side}TricepSplit`, "Arms", arm, 0.40, PI - outward * 0.22, 0.11, 0.11, 0.12, SPLIT_START, 1.00)
	-- Bicep down the middle, and the forearm's flexor/extensor seam.
	groove(`{side}BicepSplit`, "Arms", arm, 0.31, 0, 0.10, 0.075, 0.12, 0.62, 1.00)
	groove(`{side}ForearmSeam`, "Arms", arm, 0.64, outward, 0.12, 0.16, 0.11, SPLIT_START, 1.00)

	local leg = `{side}Leg`
	-- Between the quads, and up the back of the calf.
	groove(`{side}QuadGap`, "Legs", leg, 0.36, 0, 0.15, 0.18, 0.13, 0.15, 0.84)
	groove(`{side}KneeGap`, "Legs", leg, 0.60, 0, 0.030, 2.4, 0.11, 0.25, 0.88)
	groove(`{side}CalfGap`, "Legs", leg, 0.74, PI, 0.13, 0.20, 0.12, 0.28, 0.95)
	-- Down the outside of the thigh, between rectus femoris and vastus lateralis.
	groove(`{side}QuadOuter`, "Legs", leg, 0.36, outward * 0.22, 0.14, 0.13, 0.12, SPLIT_START, 1.00)
	-- And the medial teardrop's upper border, just above the knee.
	groove(`{side}TeardropGap`, "Legs", leg, 0.47, -outward * 0.30, 0.055, 0.16, 0.11, 0.66, 1.00)
end

BodyLoftConfig.GROOVES = grooves

--[[
	Detail buckets. Rings are subdivided between the authored cross-sections, so
	`Subdivisions` is how many extra rings to interpolate between each authored pair —
	that is what makes a limb read as a smooth curve rather than a stack of cans.
]]
BodyLoftConfig.DETAIL = {
	-- Grooves are narrow, so they alias into a smudge without enough sides to land
	-- on. Thirty is the point where an ab channel reads as a channel rather than a
	-- dark patch; the cost is measured in check 4 of the plan rather than assumed.
	Near = { Sides = 30, Subdivisions = 3, MaxDistance = 40 },
	Mid = { Sides = 14, Subdivisions = 1, MaxDistance = 110 },
	-- Beyond Mid the generated body is dropped entirely and the stock rig shows.
}

--[[
	Which way a tube was authored, and therefore whether the builder must reverse its
	triangle winding.

	The torso is authored hips-upward because that is how a body reads when you write
	it down; the limbs are authored shoulder-downward for the same reason. Feeding both
	through one winding formula makes one of them inside-out, and an inside-out surface
	is backface-culled — it renders as *nothing*, with every property on the MeshPart
	still looking perfectly healthy. That cost an afternoon, so the rule lives here
	next to the data it depends on, and RunSelfTest checks it rather than trusting it.
]]
function BodyLoftConfig.IsAscending(tube: Tube): boolean
	return #tube.Rings > 1 and tube.Rings[#tube.Rings].Y > tube.Rings[1].Y
end

-- Growth ramps, matched to the primitive system's so a physique does not change
-- character when the fallback takes over.
function BodyLoftConfig.Strength(m: Groove, progress: number): number
	local span = m.Full - m.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - m.Start) / span, 0, 1)
	return linear * linear * (3 - 2 * linear)
end

--[[
	How far a muscle pushes the surface out at a given point on its tube.

	The angular term wraps, so a muscle centred at 0 still bulges at 2π - 0.1. Getting
	that wrong splits a bicep down the seam of the UV wrap, which is invisible in the
	numbers and obvious on the model.
]]
function BodyLoftConfig.Displacement(m: Groove, t: number, angle: number, progress: number): number
	local strength = BodyLoftConfig.Strength(m, progress)
	if strength <= 0 then
		return 0
	end
	local dt = (t - m.T) / m.SpreadT
	if dt > 3 or dt < -3 then
		return 0
	end
	local da = math.abs(angle - m.Angle) % (2 * PI)
	if da > PI then
		da = 2 * PI - da
	end
	da /= m.SpreadAngle
	if da > 3 then
		return 0
	end
	return m.Amplitude * strength * math.exp(-dt * dt) * math.exp(-da * da)
end

--[[
	Smooth maximum. Fuses a lobe into the body with a fillet instead of a crease.

	A plain max() would give every muscle a hard rim where its sphere cuts the
	surface, which reads as a seam rather than anatomy. `k` is how wide that fillet
	is, per lobe: small for a delt that should stand proud, large for a pec melting
	into the chest.
]]
function BodyLoftConfig.SmoothMax(a: number, b: number, k: number): number
	if k <= 1e-6 then
		return math.max(a, b)
	end
	local h = math.clamp(0.5 + 0.5 * (a - b) / k, 0, 1)
	return b + (a - b) * h + k * h * (1 - h)
end

--[[
	Where a ray leaves an ellipsoid, or nil if it misses.

	The ray starts on the tube's axis and points outward through the vertex, so the
	*far* root is the one that matters: it is where the muscle's surface sits along
	that direction.

	Stretch is handled by working in the ellipsoid's own space — dividing the offset
	and the direction by the same factors. Because both are scaled together the `t`
	that comes back is still measured along the original ray, so it drops straight
	into the union without any correction. That is why the direction is deliberately
	not renormalised here.
]]
function BodyLoftConfig.RayExit(
	px: number,
	py: number,
	pz: number,
	dx: number,
	dy: number,
	dz: number,
	cx: number,
	cy: number,
	cz: number,
	radius: number,
	sx: number,
	sy: number,
	sz: number
): number?
	local ox, oy, oz = (px - cx) / sx, (py - cy) / sy, (pz - cz) / sz
	local ex, ey, ez = dx / sx, dy / sy, dz / sz
	local a = ex * ex + ey * ey + ez * ez
	if a <= 1e-12 then
		return nil
	end
	local b = ox * ex + oy * ey + oz * ez
	local c = ox * ox + oy * oy + oz * oz - radius * radius
	local disc = b * b - a * c
	if disc < 0 then
		return nil
	end
	local t = (-b + math.sqrt(disc)) / a
	if t <= 0 then
		return nil
	end
	return t
end

-- How big a lobe is at a given progress. It grows from a speck buried inside the
-- body, so a lean physique is lean without needing a second rule to hide it.
function BodyLoftConfig.LobeRadius(l: Lobe, progress: number): number
	local span = l.Full - l.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - l.Start) / span, 0, 1)
	return l.Radius * (linear * linear * (3 - 2 * linear))
end

--[[
	The tube's own radius at a point, before any muscle. Shared with the self-test so
	"does this lobe actually break the surface" is asked against the real profile.
]]
function BodyLoftConfig.BaseRadius(tube: Tube, t: number, angle: number): number
	local rings = tube.Rings
	local scaled = math.clamp(t, 0, 1) * (#rings - 1) + 1
	local lower = math.clamp(math.floor(scaled), 1, #rings)
	local upper = math.clamp(lower + 1, 1, #rings)
	local frac = scaled - lower
	local rx = rings[lower].RX + (rings[upper].RX - rings[lower].RX) * frac
	local rz = rings[lower].RZ + (rings[upper].RZ - rings[lower].RZ) * frac
	local sx, cz = math.sin(angle) * rx, math.cos(angle) * rz
	return math.sqrt(sx * sx + cz * cz)
end

--[[
	How much darker a vertex is than the plain surface, as a plain multiplier.

	The rule that matters is the first line: a flat or raised surface returns
	**exactly** 1, never 0.98. The body's colour comes from its texture, and any
	tint at all on flat skin multiplies into that texture and shifts the whole body
	away from the head — which is precisely the bug this replaced. The body once
	rendered its skin tone twice and came out at 218,157,111 against a head of
	236,200,168, and nothing short of comparing pixels would have shown it.

	So only grooves darken. Muscle peaks are left to the mesh's own normals and the
	world's lighting, which brighten a bulge perfectly well without help.

	Lives here rather than in the builder so it loads under the bare `luau` CLI and
	can be asserted, like SmoothMax and RayExit before it.
]]
function BodyLoftConfig.ReliefTint(relief: number, reach: number, leanness: number?): number
	if reach <= 1e-4 or relief >= 0 then
		return 1
	end
	local depth = math.clamp(-relief / reach, 0, 1)
	-- Capped short of 1: a groove is a shadow, and a shadow that reaches black is a
	-- hole. The existing self-test asserts exactly that and must keep passing.
	local shade = math.min(BodyLoftConfig.GROOVE_SHADE * BodyLoftConfig.Leanness(leanness), 0.6)
	return 1 - depth * shade
end

function BodyLoftConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local validStats = { Arms = true, Chest = true, Back = true, Core = true, Legs = true }

	local boneNames: { [string]: boolean } = {}
	for _, bone in BONES do
		if boneNames[bone.Name] then
			table.insert(failures, `duplicate bone {bone.Name}`)
		end
		boneNames[bone.Name] = true
	end

	local tubeIds: { [string]: Tube } = {}
	for _, tube in tubes do
		if tubeIds[tube.Id] then
			table.insert(failures, `duplicate tube {tube.Id}`)
		end
		tubeIds[tube.Id] = tube
		if #tube.Rings < 3 then
			table.insert(failures, `{tube.Id} has too few rings to loft`)
		end
		if tube.Spread < 0 or tube.Spread > 1 then
			table.insert(failures, `{tube.Id} has a spread outside 0..1`)
		end
		if tube.U1 <= tube.U0 or tube.U0 < 0 or tube.U1 > 1 then
			table.insert(failures, `{tube.Id} has an empty or out-of-range texture column`)
		end
		-- A tube runs whichever way it was authored — the torso bottom-up, the limbs
		-- top-down — but it must be strictly monotonic. A repeated or reversing Y
		-- folds the tube back through itself, which renders as a crease that no
		-- amount of tuning removes.
		local rising = #tube.Rings > 1 and tube.Rings[2].Y > tube.Rings[1].Y
		local previousY: number? = nil
		for index, r in tube.Rings do
			if r.RX <= 0 or r.RZ <= 0 then
				table.insert(failures, `{tube.Id} ring {index} has a non-positive radius`)
			end
			if previousY ~= nil then
				local step = r.Y - previousY
				if (rising and step <= 0) or (not rising and step >= 0) then
					table.insert(failures, `{tube.Id} ring {index} reverses the tube`)
				end
			end
			previousY = r.Y
			if r.Slot ~= "Skin" and r.Slot ~= "Pants" then
				table.insert(failures, `{tube.Id} ring {index} has unknown slot {r.Slot}`)
			end
			if #r.Bones == 0 then
				table.insert(failures, `{tube.Id} ring {index} is bound to no bone`)
			end
			if #r.Bones > BodyLoftConfig.MAX_INFLUENCES then
				table.insert(
					failures,
					`{tube.Id} ring {index} exceeds {BodyLoftConfig.MAX_INFLUENCES} influences`
				)
			end
			for _, inf in r.Bones do
				if not boneNames[inf.Bone] then
					table.insert(failures, `{tube.Id} ring {index} binds to unknown bone {inf.Bone}`)
				end
				if inf.Weight <= 0 then
					table.insert(failures, `{tube.Id} ring {index} has a non-positive weight`)
				end
			end
		end
	end

	local ids: { [string]: boolean } = {}
	for _, m in grooves do
		if ids[m.Id] then
			table.insert(failures, `duplicate muscle {m.Id}`)
		end
		ids[m.Id] = true
		if not validStats[m.StatId] then
			table.insert(failures, `{m.Id} uses unknown stat {m.StatId}`)
		end
		if tubeIds[m.Tube] == nil then
			table.insert(failures, `{m.Id} lives on unknown tube {m.Tube}`)
		end
		if m.T < 0 or m.T > 1 then
			table.insert(failures, `{m.Id} sits off the end of its tube`)
		end
		if m.SpreadT <= 0 or m.SpreadAngle <= 0 then
			table.insert(failures, `{m.Id} has a non-positive spread`)
		end
		if m.Amplitude == 0 then
			table.insert(failures, `{m.Id} has zero amplitude and does nothing`)
		end
		if m.Start < 0 or m.Full > 1 or m.Start >= m.Full then
			table.insert(failures, `{m.Id} has an invalid growth range`)
		end
		-- A lean physique must be lean.
		if BodyLoftConfig.Displacement(m, m.T, m.Angle, 0) ~= 0 then
			table.insert(failures, `{m.Id} shows on an untrained body`)
		end
		-- And a muscle that never moves the surface is a row doing nothing, which is
		-- the failure mode no screenshot makes obvious.
		if math.abs(BodyLoftConfig.Displacement(m, m.T, m.Angle, 1)) < 0.02 then
			table.insert(failures, `{m.Id} barely changes the surface at full growth`)
		end
	end

	-- Left and right must be exact mirrors, or the body is subtly lopsided in a way
	-- that is very hard to see and impossible to unsee.
	for _, m in grooves do
		local left = string.match(m.Id, "^Left(.+)$")
		if left ~= nil then
			local partner: Groove? = nil
			for _, other in grooves do
				if other.Id == "Right" .. left then
					partner = other
				end
			end
			if partner == nil then
				table.insert(failures, `{m.Id} has no right-side partner`)
			else
				local p = partner :: Groove
				if p.T ~= m.T or p.Amplitude ~= m.Amplitude or p.SpreadT ~= m.SpreadT then
					table.insert(failures, `{m.Id} and {p.Id} are not mirrors`)
				end
				-- Mirrored means reflected about the front-back axis: angleL == -angleR
				-- once both are normalised to (-pi, pi]. Comparing magnitudes instead
				-- passes a trap at pi-0.55 against one at pi+0.55, which are not
				-- mirrors at all.
				local function normalise(a: number): number
					local wrapped = a % (2 * PI)
					if wrapped > PI then
						wrapped -= 2 * PI
					end
					return wrapped
				end
				-- The sum is compared modulo a full turn, because a muscle sitting on
				-- the back centre line is its own mirror: pi and -pi are one place,
				-- and a plain sum reads 2pi there and cries foul.
				local sum = normalise(normalise(m.Angle) + normalise(p.Angle))
				if math.abs(sum) > 1e-9 then
					table.insert(failures, `{m.Id} and {p.Id} sit at different angles`)
				end
			end
		end
	end

	-- The wrap-around case: a muscle at the front seam must bulge on both sides of it.
	local front: Groove? = nil
	for _, m in grooves do
		if m.Id == "LeftBicep" then
			front = m
		end
	end
	if front ~= nil then
		local f = front :: Groove
		local justBelow = BodyLoftConfig.Displacement(f, f.T, 2 * PI - 0.05, 1)
		local justAbove = BodyLoftConfig.Displacement(f, f.T, 0.05, 1)
		if math.abs(justBelow - justAbove) > 1e-6 then
			table.insert(failures, "Displacement does not wrap around the 0/2pi seam")
		end
	end

	--[[
		The tint must not touch flat skin.

		The body's colour lives in its texture, so a tint of even 0.98 on a flat
		surface multiplies in and pulls the whole body away from the head. Checking
		for exactly 1 rather than approximately 1 is deliberate.
	]]
	do
		if BodyLoftConfig.ReliefTint(0, 0.5) ~= 1 then
			table.insert(failures, "ReliefTint darkens flat skin")
		end
		if BodyLoftConfig.ReliefTint(0.3, 0.5) ~= 1 then
			table.insert(failures, "ReliefTint darkens a raised muscle")
		end
		if BodyLoftConfig.ReliefTint(-0.5, 0.5) >= 1 then
			table.insert(failures, "ReliefTint does not darken the deepest groove")
		end
		if BodyLoftConfig.ReliefTint(-0.5, 0.5) <= 0 then
			table.insert(failures, "ReliefTint drives a groove to black or beyond")
		end
		-- Reach of zero means nothing on this tube moved; it must be a no-op, not a
		-- division by zero.
		if BodyLoftConfig.ReliefTint(0, 0) ~= 1 then
			table.insert(failures, "ReliefTint mishandles a body with no relief")
		end
	end

	--[[
		Lobes must actually show.

		A sphere buried inside the body is a row that costs a build and changes
		nothing, and there is no way to see that in a screenshot — the body simply
		looks a bit plain and you go tuning the wrong number. So each lobe is measured
		against the tube's own profile at its own position: at full growth its far
		edge must clear the surface by a real margin, and at zero it must be inside.
	]]
	do
		local tubeById: { [string]: Tube } = {}
		for _, tube in tubes do
			tubeById[tube.Id] = tube
		end
		for _, l in lobes do
			local tube = tubeById[l.Tube]
			if tube == nil then
				table.insert(failures, `{l.Id} lives on unknown tube {l.Tube}`)
				continue
			end
			if l.Out <= 0 or l.Out > 1 then
				table.insert(failures, `{l.Id} sits outside the body before it even grows`)
			end
			if l.Radius <= 0 or l.Blend < 0 then
				table.insert(failures, `{l.Id} has a non-positive radius or negative blend`)
			end
			--[[
				Stretch is divided by, not multiplied by, inside RayExit — the ray is
				worked in the ellipsoid's own space. A zero is therefore a division by
				zero that comes back as nan, and a nan radius propagates through
				SmoothMax into every vertex on the tube: the whole limb disappears with
				no error anywhere. Cheap to assert, impossible to diagnose from a
				screenshot of nothing.
			]]
			if l.StretchX <= 0 or l.StretchY <= 0 or l.StretchZ <= 0 then
				table.insert(failures, `{l.Id} has a non-positive stretch axis`)
			end
			if l.Start < 0 or l.Full > 1 or l.Start >= l.Full then
				table.insert(failures, `{l.Id} has an invalid growth range`)
			end
			local base = BodyLoftConfig.BaseRadius(tube, l.T, l.Angle)
			--[[
				How far the lobe reaches along the direction it has to break through.

				A stretched lobe does not reach its radius in every direction: an
				ellipsoid's extent along a unit direction is
				`R * sqrt((dx·sx)^2 + (dy·sy)^2 + (dz·sz)^2)`. Ignoring that would pass
				a lat flattened to 0.72 in Z as though it still reached its full radius
				— which is exactly the shape most likely to end up buried.
			]]
			local dirX, dirZ = math.sin(l.Angle), -math.cos(l.Angle)
			local reachFactor = math.sqrt((dirX * l.StretchX) ^ 2 + (dirZ * l.StretchZ) ^ 2)
			local reachFull = base * l.Out + BodyLoftConfig.LobeRadius(l, 1) * reachFactor
			if reachFull < base + 0.05 then
				table.insert(
					failures,
					`{l.Id} never breaks the surface: reaches {string.format("%.2f", reachFull)} `
						.. `against a radius of {string.format("%.2f", base)}`
				)
			end
			local reachLean = base * l.Out + BodyLoftConfig.LobeRadius(l, 0) * reachFactor
			if reachLean > base then
				table.insert(failures, `{l.Id} already shows on an untrained body`)
			end
		end
		-- Left and right must be exact mirrors.
		for _, l in lobes do
			local bare = string.match(l.Id, "^Left(.+)$")
			if bare ~= nil then
				local partner: Lobe? = nil
				for _, other in lobes do
					if other.Id == "Right" .. bare then
						partner = other
					end
				end
				if partner == nil then
					table.insert(failures, `{l.Id} has no right-side partner`)
				else
					local o = partner :: Lobe
					if o.T ~= l.T or o.Radius ~= l.Radius or o.Out ~= l.Out then
						table.insert(failures, `{l.Id} and {o.Id} are not mirrors`)
					end
					-- Stretch mirrors as-is rather than negating: the reflection is
					-- about the front-back axis, and an ellipsoid's extent along X is
					-- the same either side of it. A lat sheeted on one side and balled
					-- on the other is the exact kind of asymmetry the comment above
					-- calls impossible to unsee.
					if o.StretchX ~= l.StretchX or o.StretchY ~= l.StretchY or o.StretchZ ~= l.StretchZ then
						table.insert(failures, `{l.Id} and {o.Id} are stretched differently`)
					end
				end
			end
		end
	end

	--[[
		The surface must survive its own grooves.

		A groove is negative displacement, so a deep one on a thin part of a limb can
		drive the radius to zero and through it — the ring turns inside out and the
		mesh renders as a knot. Nothing about the individual numbers reveals this;
		only the sum does, and only at the worst angle of the worst ring. So the whole
		field is evaluated across every authored ring at full growth and the net
		radius is required to keep real clearance.

		The margin is a quarter of the ring's authored radius rather than zero,
		because a surface that merely avoids inverting still pinches into a crease
		that reads as damage.
	]]
	do
		local SAMPLES = 48
		for _, tube in tubes do
			for index, r in tube.Rings do
				local t = (index - 1) / math.max(1, #tube.Rings - 1)
				for step = 0, SAMPLES - 1 do
					local angle = step / SAMPLES * 2 * PI
					local push = 0
					for _, m in grooves do
						if m.Tube == tube.Id then
							push += BodyLoftConfig.Displacement(m, t, angle, 1)
						end
					end
					local smallest = math.min(r.RX, r.RZ)
					if smallest + push < smallest * 0.25 then
						table.insert(
							failures,
							`{tube.Id} ring {index} collapses at angle {string.format("%.2f", angle)}: `
								.. `radius {string.format("%.2f", smallest)} with {string.format("%.2f", push)} of muscle`
						)
						break
					end
				end
			end
		end
	end

	-- Texture columns must tile 0..1 exactly: a gap wastes texture and an overlap
	-- paints a shin with someone's abs.
	do
		local columns = {}
		for _, tube in tubes do
			table.insert(columns, { U0 = tube.U0, U1 = tube.U1, Id = tube.Id })
		end
		table.sort(columns, function(a, b)
			return a.U0 < b.U0
		end)
		local cursor = 0
		for _, column in columns do
			if math.abs(column.U0 - cursor) > 1e-9 then
				table.insert(failures, `texture atlas has a gap or overlap at {column.Id}`)
			end
			cursor = column.U1
		end
		if math.abs(cursor - 1) > 1e-9 then
			table.insert(failures, `texture atlas stops at {cursor}, not 1`)
		end
	end

	--[[
		The winding check. For each tube, build the two triangles the builder would
		build across a mid-section and confirm the face normal points away from the
		tube's axis. This is the only invariant here that catches a defect which is
		completely invisible from the outside: the surface simply is not drawn.
	]]
	local SIDES = 16
	for _, tube in tubes do
		if #tube.Rings < 4 then
			continue
		end
		local a, b = tube.Rings[3], tube.Rings[4]
		local flip = BodyLoftConfig.IsAscending(tube)
		local side, nextSide = 2, 3
		local function vertex(r: Ring, index: number): { number }
			local angle = index / SIDES * 2 * PI
			return { r.X + math.sin(angle) * r.RX, r.Y, r.Z - math.cos(angle) * r.RZ }
		end
		local v1 = vertex(a, side)
		local v2 = if flip then vertex(b, side) else vertex(a, nextSide)
		local v3 = if flip then vertex(a, nextSide) else vertex(b, side)
		local e1 = { v2[1] - v1[1], v2[2] - v1[2], v2[3] - v1[3] }
		local e2 = { v3[1] - v1[1], v3[2] - v1[2], v3[3] - v1[3] }
		local normal = {
			e1[2] * e2[3] - e1[3] * e2[2],
			e1[3] * e2[1] - e1[1] * e2[3],
			e1[1] * e2[2] - e1[2] * e2[1],
		}
		local angle = side / SIDES * 2 * PI
		local outward = { math.sin(angle), 0, -math.cos(angle) }
		local facing = normal[1] * outward[1] + normal[2] * outward[2] + normal[3] * outward[3]
		if facing <= 0 then
			table.insert(failures, `{tube.Id} is wound inside out and will not render`)
		end
	end

	return failures
end

return BodyLoftConfig
