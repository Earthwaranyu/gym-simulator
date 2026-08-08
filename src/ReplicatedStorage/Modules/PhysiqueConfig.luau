--!strict
--[[
	PhysiqueConfig — how a stat's growth is distributed over a body part's axes.

	`MuscleService` decides *how much* each part grows. This decides *what shape* that
	growth takes, and it exists because scaling a part uniformly does not make a body
	look strong — it makes a box. A limb at 2.5x uniform is two and a half times longer
	as well as thicker, so the character stops reading as a person and starts reading as
	furniture, which is exactly what happens at high power today.

	Real hypertrophy is almost entirely girth. A bodybuilder is not taller than they
	were; they are wider and deeper, with the widening concentrated at the shoulders and
	the waist deliberately left behind. So each part gets a weight per axis, and the
	scale MuscleService asked for is applied through it:

	    axis = 1 + (scale - 1) * weight

	A weight of 1 grows fully, 0 does not grow at all. Keeping the Y weights low is what
	produces a V-taper rather than a cube, and keeping LowerTorso's weights below
	UpperTorso's is what makes the torso read as a chest above a waist rather than as
	one continuous barrel.

	Adding a body part is a row here. Anything not listed falls back to DEFAULT, which
	is girth-only — the safe shape for a part nobody has tuned yet.

	Everything here is plain numbers rather than Vector3 and Color3 on purpose: it keeps
	the file requireable by the bare `luau` CLI, so its self-test — which is what stops
	a mistyped weight from producing one arm bigger than the other — runs in check.sh
	rather than only in Studio.
]]

local PhysiqueConfig = {}

export type AxisWeights = {
	-- Left-right. Shoulder width and limb girth.
	X: number,
	-- Up-down. Kept small everywhere: muscle does not make you taller.
	Y: number,
	-- Front-back. Chest depth and limb girth.
	Z: number,
}

-- Girth without height, for any part not named below.
local DEFAULT: AxisWeights = { X = 0.4, Y = 0.25, Z = 0.4 }

--[[
	Measured base sizes of the R15 rig this game spawns, in studs. Not used at runtime
	— they are here so the self-test can check what the weights actually PRODUCE.

	They are the reason the weights are as low as they are. An R15 upper arm is
	1.00 wide by 1.17 long: nearly square already. Growing girth at full rate while
	holding length flat takes it to 2.50 by 1.38 — wider than it is long, which reads
	as a disc stuck to a shoulder. The first pass of this file did exactly that, and it
	is not obvious from the weights alone; it is only obvious from the result.
]]
local BASE_SIZE: { [string]: { W: number, H: number, D: number } } = {
	UpperTorso = { W = 2.0, H = 1.6, D = 1.0 },
	LowerTorso = { W = 2.0, H = 0.4, D = 1.0 },
	LeftUpperArm = { W = 1.0, H = 1.17, D = 1.0 },
	RightUpperArm = { W = 1.0, H = 1.17, D = 1.0 },
	LeftLowerArm = { W = 1.0, H = 1.05, D = 1.0 },
	RightLowerArm = { W = 1.0, H = 1.05, D = 1.0 },
	LeftUpperLeg = { W = 1.0, H = 1.22, D = 1.0 },
	RightUpperLeg = { W = 1.0, H = 1.22, D = 1.0 },
	LeftLowerLeg = { W = 1.0, H = 1.19, D = 1.0 },
	RightLowerLeg = { W = 1.0, H = 1.19, D = 1.0 },
}

PhysiqueConfig.BASE_SIZE = BASE_SIZE

-- How much thicker, relative to its own length, a part may become. 1.6 means a limb
-- may end up 60% stouter in proportion than it started — a lot, and about where a
-- heavy bodybuilder sits. Past it the part stops reading as the thing it was.
PhysiqueConfig.MAX_RELATIVE_THICKENING = 1.6
-- Limbs additionally may not become wider than they are long. Torsos are exempt: a
-- chest is legitimately wider than it is tall, on any body.
PhysiqueConfig.LIMB_PARTS = {
	"LeftUpperArm",
	"RightUpperArm",
	"LeftLowerArm",
	"RightLowerArm",
	"LeftUpperLeg",
	"RightUpperLeg",
	"LeftLowerLeg",
	"RightLowerLeg",
}

--[[
	Weights are quoted as "what this part measures at full growth", because that is the
	number a human can judge and the weight is not. Full growth is MAX_MUSCLE_SCALE
	(2.5), so growth = 1.5 and weight = (target - 1) / 1.5.
]]
local WEIGHTS: { [string]: AxisWeights } = {
	-- Chest: 1.9x wide and deep against 1.38x tall. Depth matters as much as width —
	-- width alone makes a signboard.
	UpperTorso = { X = 0.6, Y = 0.25, Z = 0.6 },
	-- Waist: 1.3x wide against the chest's 1.9x. That gap IS the V; the waist still
	-- grows a little because an unchanged waist under a doubled chest looks broken.
	LowerTorso = { X = 0.2, Y = 0.18, Z = 0.23 },

	-- Upper arm: 1.69x girth, 1.45x length — a thick arm that is still an arm.
	--
	-- The length growth is not padding. An R15 upper arm starts 1.00 wide by 1.17
	-- long, so girth alone hits "wider than it is long" almost immediately; letting
	-- the limb lengthen with it is what buys the girth room to be dramatic. The whole
	-- character ends up around 1.4x taller at full growth, which is the correct look
	-- for someone whose stats are in the trillions.
	LeftUpperArm = { X = 0.46, Y = 0.3, Z = 0.46 },
	RightUpperArm = { X = 0.46, Y = 0.3, Z = 0.46 },
	-- Forearm behind the upper arm, so the limb tapers toward the wrist.
	LeftLowerArm = { X = 0.28, Y = 0.25, Z = 0.28 },
	RightLowerArm = { X = 0.28, Y = 0.25, Z = 0.28 },

	-- Thigh 1.72x girth: the deepest muscle on the body, and the one that sells size
	-- from behind.
	LeftUpperLeg = { X = 0.48, Y = 0.28, Z = 0.48 },
	RightUpperLeg = { X = 0.48, Y = 0.28, Z = 0.48 },
	-- Calf, same taper logic as the forearm.
	LeftLowerLeg = { X = 0.4, Y = 0.24, Z = 0.4 },
	RightLowerLeg = { X = 0.4, Y = 0.24, Z = 0.4 },

	-- Hands and feet grow just enough not to look stuck onto a giant. They are the
	-- fastest way to make a character read as a cartoon, so: barely.
	LeftHand = { X = 0.18, Y = 0.16, Z = 0.18 },
	RightHand = { X = 0.18, Y = 0.16, Z = 0.18 },
	LeftFoot = { X = 0.16, Y = 0.14, Z = 0.18 },
	RightFoot = { X = 0.16, Y = 0.14, Z = 0.18 },
}

PhysiqueConfig.WEIGHTS = WEIGHTS
PhysiqueConfig.DEFAULT = DEFAULT

--[[
	The per-axis multiplier for one part at one overall scale.
]]
function PhysiqueConfig.AxisScale(partName: string, scale: number): (number, number, number)
	local weights = WEIGHTS[partName] or DEFAULT
	local growth = scale - 1
	return 1 + growth * weights.X, 1 + growth * weights.Y, 1 + growth * weights.Z
end

-- === Veins ==================================================================

-- Below this overall scale nobody is veiny; a lean beginner with cords standing out
-- of their arms looks ill rather than strong.
PhysiqueConfig.VEIN_THRESHOLD = 1.35
-- Fully drawn by here. Between the two the veins fade in with the muscle.
PhysiqueConfig.VEIN_FULL = 2.0

-- Vein colour. A desaturated blue-green under skin, not a blue tube — anything
-- saturated reads as a wire glued to the arm.
PhysiqueConfig.VEIN_COLOR = { R = 96, G = 104, B = 118 }
-- How transparent veins are at full growth. They are meant to be noticed on a second
-- look, not to be the first thing you see.
PhysiqueConfig.VEIN_MIN_TRANSPARENCY = 0.35

export type Vein = {
	-- Which part it lies on.
	Part: string,
	-- Position on that part, as a fraction of its size from the centre. Recomputed
	-- against live size every time the limb grows, so a vein stays on the surface.
	OffsetX: number,
	OffsetY: number,
	OffsetZ: number,
	-- Length and thickness, also as fractions of the part's size.
	Length: number,
	Thickness: number,
	-- Rotation about the limb's long axis, in degrees, so the three veins on an arm
	-- are not stacked in a line.
	Twist: number,
}

--[[
	Where the veins go.

	Arms and upper torso only. Veins on a thigh are anatomically fine and visually
	noise at the distance this game is played from, and the arms are what a player
	actually looks at — they are in shot in third person the whole time.
]]
local VEINS: { Vein } = {
	{
		Part = "LeftUpperArm",
		OffsetX = -0.42,
		OffsetY = 0.05,
		OffsetZ = 0.1,
		Length = 0.62,
		Thickness = 0.1,
		Twist = 12,
	},
	{
		Part = "LeftUpperArm",
		OffsetX = -0.3,
		OffsetY = -0.1,
		OffsetZ = 0.4,
		Length = 0.5,
		Thickness = 0.08,
		Twist = -20,
	},
	{
		Part = "RightUpperArm",
		OffsetX = 0.42,
		OffsetY = 0.05,
		OffsetZ = 0.1,
		Length = 0.62,
		Thickness = 0.1,
		Twist = -12,
	},
	{
		Part = "RightUpperArm",
		OffsetX = 0.3,
		OffsetY = -0.1,
		OffsetZ = 0.4,
		Length = 0.5,
		Thickness = 0.08,
		Twist = 20,
	},

	{
		Part = "LeftLowerArm",
		OffsetX = -0.35,
		OffsetY = 0.0,
		OffsetZ = 0.32,
		Length = 0.55,
		Thickness = 0.08,
		Twist = 15,
	},
	{
		Part = "RightLowerArm",
		OffsetX = 0.35,
		OffsetY = 0.0,
		OffsetZ = 0.32,
		Length = 0.55,
		Thickness = 0.08,
		Twist = -15,
	},

	-- Two down the chest, reading as the line between the pecs plus a shoulder vein.
	{
		Part = "UpperTorso",
		OffsetX = 0,
		OffsetY = -0.05,
		OffsetZ = 0.46,
		Length = 0.5,
		Thickness = 0.07,
		Twist = 0,
	},
	{
		Part = "UpperTorso",
		OffsetX = -0.38,
		OffsetY = 0.22,
		OffsetZ = 0.34,
		Length = 0.34,
		Thickness = 0.06,
		Twist = 25,
	},
	{
		Part = "UpperTorso",
		OffsetX = 0.38,
		OffsetY = 0.22,
		OffsetZ = 0.34,
		Length = 0.34,
		Thickness = 0.06,
		Twist = -25,
	},
}

PhysiqueConfig.VEINS = VEINS

--[[
	How visible veins should be at a given scale: 0 hidden, 1 fully drawn.
]]
function PhysiqueConfig.VeinStrength(scale: number): number
	if scale <= PhysiqueConfig.VEIN_THRESHOLD then
		return 0
	end
	local span = PhysiqueConfig.VEIN_FULL - PhysiqueConfig.VEIN_THRESHOLD
	return math.clamp((scale - PhysiqueConfig.VEIN_THRESHOLD) / span, 0, 1)
end

function PhysiqueConfig.RunSelfTest(): { string }
	local failures: { string } = {}

	local function check(label: string, condition: boolean)
		if not condition then
			table.insert(failures, label)
		end
	end

	-- Scale 1 must be the identity, or a character with no stats is already deformed.
	for partName in WEIGHTS do
		local x, y, z = PhysiqueConfig.AxisScale(partName, 1)
		check(`{partName} is unchanged at scale 1`, x == 1 and y == 1 and z == 1)
	end

	-- Height must always trail girth. Hypertrophy is a girth phenomenon; a part that
	-- grew equally on every axis would be the uniform scaling this file exists to
	-- replace.
	for partName, weights in WEIGHTS do
		check(`{partName} grows less tall than wide`, weights.Y < weights.X)
		check(`{partName} weights are sane`, weights.X <= 1 and weights.Y >= 0 and weights.Z <= 1)
	end

	-- The taper: waist must grow slower than chest, forearm slower than upper arm.
	check("waist trails chest", WEIGHTS.LowerTorso.X < WEIGHTS.UpperTorso.X)
	check("forearm trails upper arm", WEIGHTS.LeftLowerArm.X < WEIGHTS.LeftUpperArm.X)
	check("calf trails thigh", WEIGHTS.LeftLowerLeg.X < WEIGHTS.LeftUpperLeg.X)

	-- Symmetry. A body with one arm bigger than the other is a typo, and it is the
	-- kind of typo nobody notices in a table of twenty numbers.
	for _, pair in
		{
			{ "LeftUpperArm", "RightUpperArm" },
			{ "LeftLowerArm", "RightLowerArm" },
			{ "LeftUpperLeg", "RightUpperLeg" },
			{ "LeftLowerLeg", "RightLowerLeg" },
			{ "LeftHand", "RightHand" },
			{ "LeftFoot", "RightFoot" },
		}
	do
		local left, right = WEIGHTS[pair[1]], WEIGHTS[pair[2]]
		check(`{pair[1]} matches {pair[2]}`, left.X == right.X and left.Y == right.Y and left.Z == right.Z)
	end

	-- The check that would have caught the disc: what do these weights actually
	-- produce on the real rig at full growth?
	local FULL = 2.5
	for partName in BASE_SIZE do
		local x, y, z = PhysiqueConfig.AxisScale(partName, FULL)
		local girthGrowth = math.max(x, z)

		check(
			`{partName} does not thicken out of proportion`,
			girthGrowth / y <= PhysiqueConfig.MAX_RELATIVE_THICKENING
		)
		check(`{partName} actually grows`, girthGrowth > 1.2)
		check(`{partName} does not shrink`, x >= 1 and y >= 1 and z >= 1)
	end

	-- A limb wider than it is long is the disc. Torsos are exempt by nature.
	for _, partName in PhysiqueConfig.LIMB_PARTS do
		local base = BASE_SIZE[partName]
		local x, y, z = PhysiqueConfig.AxisScale(partName, FULL)
		local girth = math.max(base.W * x, base.D * z)
		check(`{partName} stays longer than it is thick`, girth <= base.H * y)
	end

	-- The taper has to survive into the finished measurements, not just the weights.
	local chestX = BASE_SIZE.UpperTorso.W * select(1, PhysiqueConfig.AxisScale("UpperTorso", FULL))
	local waistX = BASE_SIZE.LowerTorso.W * select(1, PhysiqueConfig.AxisScale("LowerTorso", FULL))
	check("finished chest is wider than finished waist", chestX > waistX * 1.35)

	local unknownX, unknownY = PhysiqueConfig.AxisScale("NotAPart", 2)
	check("unknown part grows girth more than height", unknownX > unknownY)

	check("no veins on a beginner", PhysiqueConfig.VeinStrength(1) == 0)
	check("no veins at the threshold", PhysiqueConfig.VeinStrength(PhysiqueConfig.VEIN_THRESHOLD) == 0)
	check("veins fully drawn at full", PhysiqueConfig.VeinStrength(PhysiqueConfig.VEIN_FULL) == 1)
	check("veins clamp above full", PhysiqueConfig.VeinStrength(99) == 1)

	for _, vein in VEINS do
		check(`vein on {vein.Part} has a known part`, WEIGHTS[vein.Part] ~= nil)
		check(`vein on {vein.Part} has sane size`, vein.Length > 0 and vein.Thickness > 0)
	end

	return failures
end

return PhysiqueConfig
