--!strict
--[[
	FlinchConfig — what being hit looks like.

	Until now, nothing at all happened to the person taking a punch. The attacker played
	a swing, a damage number appeared on the victim's screen, and the victim's body did
	not move a joint. In a game whose entire hook is interrupting somebody mid-training,
	the person being interrupted was the one character in the fight showing no sign of it.

	Three silhouettes, one per impact band, so a jab is not the same as a finisher. The
	bands come from Formulas.ImpactTier and the weight is stated by the ability — see
	that function for why it is not derived from damage.

	Shaped like FlightConfig rather than StrikeConfig: a flinch is one silhouette snapped
	into and eased out of, not a multi-stage clip, so PosePlayback.PoseAt renders it with
	no new maths. The asymmetry in the timing is the whole read — in fast, out slow.
	Getting hit is instantaneous and recovering from it is not, and a flinch that eased in
	as gently as it eased out would look like the victim had decided to lean.

	Axis conventions and the ~150 degree ceiling are PoseConfig's, unchanged.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

export type Flinch = {
	Id: string,
	Angles: { [string]: Vector3 },
	Offset: Vector3,
	-- Seconds the pose is held at full strength before it starts easing out. Zero for a
	-- light hit, which is over the instant it happens.
	HoldSeconds: number,
	BlendInSeconds: number,
	BlendOutSeconds: number,
}

local FlinchConfig = {}

--[[
	Stamped on the victim by CombatService when a hit actually lands.

	On the victim rather than the attacker, and that is the point of the whole design:
	the attacker's swing plays whether or not it connects, so an effect driven off it
	fires when a player punches empty air. A hit is an event that happens to somebody,
	so the somebody is what carries it.

	HurtAt is a server timestamp rather than a flag, so two hits in a row are two events.
]]
FlinchConfig.HURT_AT_ATTRIBUTE = "HurtAt"
FlinchConfig.HURT_IMPACT_ATTRIBUTE = "HurtImpact"

--[[
	Every joint a flinch drives.

	Upper body only, deliberately. The legs belong to whatever the victim was already
	doing — running, standing, being posed on a machine — and a flinch that seized the
	hips would stop a fleeing player dead every time they were clipped, which is a
	gameplay change disguised as an animation.
]]
FlinchConfig.Joints = {
	"Root",
	"Waist",
	"Neck",
	"RightShoulder",
	"LeftShoulder",
	"RightElbow",
	"LeftElbow",
}

local function deg(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

--[[
	A jab landing. Barely more than a twitch — the head turns, the shoulders check.

	It has to be small: this fires on the first contact of every combo thrown at you, so
	several times a second in a real fight. A large flinch here would make a victim look
	like they were being electrocuted and would drown out the finisher that follows.
]]
local LIGHT: Flinch = {
	Id = "Light",
	Offset = Vector3.new(0, 0, 0.06),
	Angles = {
		Root = deg(-3, 2, 0),
		Waist = deg(-4, 3, 0),
		Neck = deg(-7, -5, 0),
		RightShoulder = deg(6, 0, 4),
		LeftShoulder = deg(4, 0, -3),
		RightElbow = deg(16, 0, 0),
		LeftElbow = deg(12, 0, 0),
	},
	HoldSeconds = 0,
	BlendInSeconds = 0.04,
	BlendOutSeconds = 0.16,
}

--[[
	A cross landing. The torso folds and the guard starts coming up.
]]
local SOLID: Flinch = {
	Id = "Solid",
	Offset = Vector3.new(0, -0.05, 0.16),
	Angles = {
		Root = deg(-8, 5, 0),
		Waist = deg(-11, 7, 0),
		Neck = deg(-16, -11, 0),
		RightShoulder = deg(18, 0, 10),
		LeftShoulder = deg(14, 0, -8),
		RightElbow = deg(42, 0, 0),
		LeftElbow = deg(36, 0, 0),
	},
	HoldSeconds = 0.04,
	BlendInSeconds = 0.05,
	BlendOutSeconds = 0.22,
}

--[[
	The finisher, and anything that hits like one.

	Head snapped back, torso folded away from the blow, both arms thrown up, and the root
	staggered back and down — the offset is what makes this read as being moved rather
	than as posing. Held a beat before it releases, which is the same trick the slam uses:
	a shape held for a moment past the impact is what carries weight.
]]
local CRUSHING: Flinch = {
	Id = "Crushing",
	Offset = Vector3.new(0, -0.14, 0.34),
	Angles = {
		Root = deg(-17, 9, 0),
		Waist = deg(-22, 13, 0),
		Neck = deg(-30, -18, 0),
		RightShoulder = deg(34, 0, 20),
		LeftShoulder = deg(28, 0, -16),
		RightElbow = deg(74, 0, 0),
		LeftElbow = deg(66, 0, 0),
	},
	HoldSeconds = 0.09,
	BlendInSeconds = 0.05,
	BlendOutSeconds = 0.3,
}

local flinches: { Flinch } = { LIGHT, SOLID, CRUSHING }

FlinchConfig.List = flinches

local byId: { [string]: Flinch } = {}
for _, flinch in flinches do
	if byId[flinch.Id] ~= nil then
		error(`[FlinchConfig] Duplicate flinch id "{flinch.Id}"`)
	end
	byId[flinch.Id] = flinch
end

--[[
	The flinch for an impact band. Ids match Formulas.ImpactTier's return values.
]]
function FlinchConfig.Get(tier: string): Flinch?
	return byId[tier]
end

--[[
	Total time a flinch occupies, so the controller knows when to hand the joints back.
]]
function FlinchConfig.Duration(flinch: Flinch): number
	return flinch.BlendInSeconds + flinch.HoldSeconds + flinch.BlendOutSeconds
end

--[[
	A flinch as JointMotions, ready for PosePlayback.PoseAt.

	Rest equals Peak because a flinch holds a shape rather than cycling through one; the
	controller supplies the strength by lerping from identity, exactly as the flight pose
	does.
]]
function FlinchConfig.Motions(flinch: Flinch): { PoseConfig.JointMotion }
	local motions: { PoseConfig.JointMotion } = {}
	for _, joint in FlinchConfig.Joints do
		local angles = flinch.Angles[joint] or Vector3.zero
		local motion: PoseConfig.JointMotion = {
			Joint = joint,
			Rest = angles,
			Peak = angles,
		}
		if joint == "Root" then
			motion.RestOffset = flinch.Offset
			motion.PeakOffset = flinch.Offset
		end
		table.insert(motions, motion)
	end
	return motions
end

function FlinchConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	for _, flinch in flinches do
		for _, joint in FlinchConfig.Joints do
			local angles: Vector3? = flinch.Angles[joint]
			check(angles ~= nil, `{flinch.Id} drives {joint}`)
			if angles ~= nil then
				check(
					math.abs(angles.X) <= 150 and math.abs(angles.Y) <= 150 and math.abs(angles.Z) <= 150,
					`{flinch.Id} keeps {joint} inside the joint ceiling`
				)
			end
		end
		check(flinch.BlendInSeconds > 0, `{flinch.Id} takes time to arrive`)
		check(flinch.HoldSeconds >= 0, `{flinch.Id} holds for a non-negative time`)
		-- In fast, out slow. Reversing this is what would make a flinch read as the
		-- victim leaning into the punch rather than being knocked out of shape by it.
		check(flinch.BlendOutSeconds > flinch.BlendInSeconds, `{flinch.Id} recovers slower than it is struck`)
	end

	-- The three bands have to actually escalate, or the combo's whole point is lost.
	check(
		math.abs(SOLID.Angles.Neck.X) > math.abs(LIGHT.Angles.Neck.X),
		"a cross snaps the head further than a jab"
	)
	check(
		math.abs(CRUSHING.Angles.Neck.X) > math.abs(SOLID.Angles.Neck.X),
		"a finisher snaps it further still"
	)
	check(CRUSHING.Offset.Z > SOLID.Offset.Z, "a finisher staggers the body further back")
	check(SOLID.Offset.Z > LIGHT.Offset.Z, "a cross staggers further than a jab")
	check(
		FlinchConfig.Duration(CRUSHING) > FlinchConfig.Duration(LIGHT),
		"a finisher lasts longer than a jab"
	)

	-- Every band Formulas can return has to exist here, or a hit lands and nothing plays.
	for _, tier in { "Light", "Solid", "Crushing" } do
		check(byId[tier] ~= nil, `there is a flinch for the {tier} band`)
	end

	-- Upper body only. A flinch that seized the hips would stop a fleeing player dead.
	for _, joint in FlinchConfig.Joints do
		check(
			joint ~= "RightHip" and joint ~= "LeftHip" and joint ~= "RightKnee" and joint ~= "LeftKnee",
			"a flinch leaves the legs to whatever the victim was already doing"
		)
	end

	local motions = FlinchConfig.Motions(CRUSHING)
	check(#motions == #FlinchConfig.Joints, "a flinch drives every listed joint")
	for _, motion in motions do
		check(motion.Rest == motion.Peak, `a flinch holds {motion.Joint} still`)
	end

	return failures
end

return FlinchConfig
