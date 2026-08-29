--!strict
--[[
	StanceConfig — how far a body's own mass holds its arms away from its ribs.

	A bodybuilder cannot put their arms down. That is not a stylistic choice, it is
	what happens when the latissimus fills the space the upper arm used to hang in,
	and it is most of why the reference physique reads as huge even standing still.
	This module turns "how wide is the chest" into "how far out is the shoulder".

	## Why the angle is derived rather than picked

	BodyLoftBuilder already pushes the arm *tubes* outward as the chest grows:

	    spreadStuds = (AxisScale("UpperTorso", scale).X - 1) * TORSO_HALF_WIDTH

	If the rig's arms do not travel the same distance, the mesh and the skeleton
	disagree — too little and the upper arm sinks into the lat, too much and the
	character T-poses away from its own body. So MAX_DEGREES is not a taste number:
	it is the abduction whose lateral hand travel equals that same spread over the
	arm's reach, and RunSelfTest asserts the two against each other. Retuning
	PhysiqueConfig.WEIGHTS.UpperTorso.X therefore fails loudly here instead of
	silently starting to clip arms through a chest.

	## Why this is a config and not a controller

	Two systems need the offset — GaitController while moving, StanceController while
	standing — and neither should own the numbers. Apply() is deliberately inert for
	any joint it does not know, so a consumer wraps its whole joint loop in one call
	with no branch, and adding a new joint later touches only this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PhysiqueConfig = require(ReplicatedStorage.Modules.PhysiqueConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local StanceConfig = {}

-- An untrained player stands like a person. Non-negotiable: the whole point of the
-- growth curve is that the transformation is visible, and a beginner already holding
-- a lat spread throws that away on the first spawn.
StanceConfig.MIN_DEGREES = 0

--[[
	Full abduction, in degrees, at Formulas.MAX_MUSCLE_SCALE.

	33 = asin(0.648 / 1.19), where 0.648 studs is how far the mesh spreads the arm
	tubes at the cap and 1.19 studs is the shoulder-to-hand reach in
	BodyLoftConfig.BONES. See the header; RunSelfTest check 2 is the real definition.
]]
StanceConfig.MAX_DEGREES = 33

--[[
	Shape of the ramp between the two.

	Below 1 on purpose. Linear spends the whole visible change in the last third of a
	grind measured in hours, so the first sessions — the ones that decide whether
	somebody keeps playing — would show nothing at all.
]]
StanceConfig.CURVE_EXPONENT = 0.7

-- Shoulder bone to hand bone in the loft's bind pose: 0.3 - (-0.89). Stated here so
-- Degrees() needs no geometry module, and checked against BONES in RunSelfTest so
-- moving a bone cannot silently desync it.
StanceConfig.ARM_REACH = 1.19

-- The narrowest the shoulder is ever allowed to sit at full growth, counting the
-- gait's own swing against it. The sprint tucks the arms to +-4 degrees, so this is
-- the check that catches a gait retune quietly letting a maxed player's arms drop.
StanceConfig.HELD_OUT_FLOOR = 30

--[[
	Which joints abduct, and which way "out" is for each.

	+Z lifts the right arm away from the body under PoseConfig's convention, and the
	gait poses already carry +Z right / -Z left, so this adds to the existing sign
	rather than fighting it. A joint absent from this table is left exactly alone.
]]
local SIGN: { [string]: number } = {
	RightShoulder = 1,
	LeftShoulder = -1,
}
StanceConfig.SIGN = SIGN

--[[
	How far out the arms are held, in degrees, for a chest of this scale.

	The input is the *chest*, not the arm. That is the number the lat mass grows with,
	and matching it is what keeps the arm riding on the lat instead of through it.
	Clamped at both ends, which is also what covers a boss for free: MobService writes
	MuscleScales.UpperTorso = BRUTE_SCALE = MAX_MUSCLE_SCALE, so growth saturates at 1
	and this module never needs to know what a boss is.
]]
function StanceConfig.Degrees(torsoScale: number): number
	if torsoScale ~= torsoScale then
		return StanceConfig.MIN_DEGREES
	end
	local maxX = select(1, PhysiqueConfig.AxisScale("UpperTorso", Formulas.MAX_MUSCLE_SCALE))
	local span = maxX - 1
	if span <= 0 then
		return StanceConfig.MIN_DEGREES
	end
	local x = select(1, PhysiqueConfig.AxisScale("UpperTorso", torsoScale))
	local growth = math.clamp((x - 1) / span, 0, 1)
	local eased = growth ^ StanceConfig.CURVE_EXPONENT
	return StanceConfig.MIN_DEGREES + (StanceConfig.MAX_DEGREES - StanceConfig.MIN_DEGREES) * eased
end

--[[
	Hold one joint's transform out from the body.

	**Pre**-multiplied, and that is load-bearing. Abduction means "away from the ribs",
	which is a rotation in the torso's frame; post-multiplying would apply it in the
	frame the stride has already swung, and part of the spread would come out as a
	twist that grows and shrinks over the walk cycle. GaitController's neck line
	post-multiplies deliberately for the opposite reason (a pitch applied after a Y
	counter-rotation), so the two are not interchangeable and RunSelfTest asserts it.

	Returns `transform` untouched for anything not in SIGN, so a caller can wrap its
	entire joint loop without a branch.
]]
function StanceConfig.Apply(jointName: string, transform: CFrame, degrees: number): CFrame
	local sign = SIGN[jointName]
	if sign == nil or degrees == 0 then
		return transform
	end
	return CFrame.Angles(0, 0, sign * math.rad(degrees)) * transform
end

--[[
	Runs from Bootstrap rather than scripts/selftest.luau: this module touches CFrame,
	which the bare `luau` CLI has no definition for. Same reason already recorded there
	for StrikeConfig, FlightConfig and GaitConfig.
]]
function StanceConfig.RunSelfTest(): { string }
	local BodyLoftConfig = require(ReplicatedStorage.Modules.BodyLoftConfig)
	local GaitConfig = require(ReplicatedStorage.Modules.GaitConfig)

	local failures: { string } = {}
	local cap = Formulas.MAX_MUSCLE_SCALE

	-- 1. A fresh spawn stands normally, and growing never lowers the arms.
	if StanceConfig.Degrees(1) ~= StanceConfig.MIN_DEGREES then
		table.insert(failures, "an untrained body does not stand at rest")
	end
	local previous = -math.huge
	for step = 0, 20 do
		local value = StanceConfig.Degrees(1 + (cap - 1) * step / 20)
		if value < previous - 1e-6 then
			table.insert(failures, "abduction falls as the chest grows")
			break
		end
		previous = value
	end
	if math.abs(StanceConfig.Degrees(cap) - StanceConfig.MAX_DEGREES) > 1e-6 then
		table.insert(failures, "the cap does not reach full abduction")
	end
	-- Above the cap it must hold, not keep opening. This is what makes a boss safe
	-- without a boss-specific branch anywhere in the stack.
	if math.abs(StanceConfig.Degrees(cap * 2) - StanceConfig.MAX_DEGREES) > 1e-6 then
		table.insert(failures, "abduction is not clamped above the scale cap")
	end

	-- 2. The mesh invariant: the arm travels out by exactly as far as the lat grew.
	local torsoX = select(1, PhysiqueConfig.AxisScale("UpperTorso", cap))
	local spreadStuds = (torsoX - 1) * BodyLoftConfig.TORSO_HALF_WIDTH
	local handTravel = math.sin(math.rad(StanceConfig.MAX_DEGREES)) * StanceConfig.ARM_REACH
	if math.abs(handTravel - spreadStuds) > 0.02 then
		table.insert(
			failures,
			`abduction moves the hand {handTravel} studs against a mesh spread of {spreadStuds}`
		)
	end

	-- 3. ARM_REACH must still describe the real bind pose.
	local shoulderY: number? = nil
	local handY: number? = nil
	for _, bone in BodyLoftConfig.BONES do
		if bone.Name == "RightUpperArm" then
			shoulderY = bone.Y
		elseif bone.Name == "RightHand" then
			handY = bone.Y
		end
	end
	if shoulderY == nil or handY == nil then
		table.insert(failures, "the loft has no right arm to measure")
	elseif math.abs((shoulderY - handY) - StanceConfig.ARM_REACH) > 1e-6 then
		table.insert(failures, `ARM_REACH is {StanceConfig.ARM_REACH}, bind pose says {shoulderY - handY}`)
	end

	-- 4/5. Against every gait: the joint never exceeds its ceiling, and a maxed body
	-- never gets its arms back down to its sides.
	local poses = { GaitConfig.Walk, GaitConfig.Sprint, GaitConfig.Dash }
	for _, pose in poses do
		for _, motion in pose.Joints do
			if SIGN[motion.Joint] == nil then
				continue
			end
			for _, z in { motion.Rest.Z, motion.Peak.Z } do
				if math.abs(z) + StanceConfig.MAX_DEGREES > 150 then
					table.insert(failures, `{pose.Id} {motion.Joint} exceeds the joint ceiling`)
				end
			end
			-- The swing works against the stance wherever it is signed opposite to it.
			local lowest = math.min(motion.Rest.Z * SIGN[motion.Joint], motion.Peak.Z * SIGN[motion.Joint])
			if StanceConfig.MAX_DEGREES + lowest < StanceConfig.HELD_OUT_FLOOR then
				table.insert(failures, `{pose.Id} lets a maxed {motion.Joint} drop to the ribs`)
			end
		end
	end

	-- 6. Mirror, inertness, and the pre/post-multiply distinction.
	local right = StanceConfig.Apply("RightShoulder", CFrame.identity, 20)
	local left = StanceConfig.Apply("LeftShoulder", CFrame.identity, 20)
	local _, _, rz = right:ToEulerAnglesXYZ()
	local _, _, lz = left:ToEulerAnglesXYZ()
	if math.abs(rz + lz) > 1e-5 then
		table.insert(failures, "the shoulders do not abduct as mirrors")
	end
	local hip = CFrame.Angles(0.3, 0, 0)
	if StanceConfig.Apply("RightHip", hip, 20) ~= hip then
		table.insert(failures, "abduction leaks onto a joint it does not own")
	end
	if StanceConfig.Apply("RightShoulder", hip, 0) ~= hip then
		table.insert(failures, "zero abduction is not the identity")
	end
	-- If these ever agree, someone has flattened the arm swing out of the test and
	-- the pre-multiply above can be "simplified" into a mid-stride twist.
	local swung = CFrame.Angles(math.rad(50), 0, 0)
	local pre = StanceConfig.Apply("RightShoulder", swung, 30)
	local post = swung * CFrame.Angles(0, 0, math.rad(30))
	if (pre.Position - post.Position).Magnitude < 1e-6 and pre.LookVector:Dot(post.LookVector) > 1 - 1e-9 then
		table.insert(failures, "pre- and post-multiplied abduction are indistinguishable")
	end

	return failures
end

return StanceConfig
