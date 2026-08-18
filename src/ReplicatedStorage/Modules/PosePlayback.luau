--!strict
--[[
	PosePlayback — turning a PoseConfig entry into joint transforms.

	This is the arithmetic between "a pose is two states per joint" and "a body is
	moving": where in the rep a joint is right now, what rotation that works out to,
	and which instance on a given rig to write it to.

	It lives here rather than inside TrainingPoseController because two things need
	it and they must agree exactly. The controller plays poses in-game. The preview
	harness (scripts/preview_poses.luau) plays them on a dummy in Studio so a pose
	can be looked at without walking to the machine. A harness with its own copy of
	this maths would show a pose the game does not play, which is worse than no
	harness at all: every fix would be tuned against a lie.

	Nothing here touches the world. It reads a pose and a rig and returns values;
	deciding when to apply them, how to blend in, and what to do with held weights
	stays with the caller.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

--[[
	A rig joint, described by the one thing a pose needs from it.

	Motor6D (classic rigs) and AnimationConstraint (rigs built since Roblox's avatar
	joint upgrade) both carry a Transform layered over the joint's rest pose, and
	both mean the same thing by it — but they share no ancestor that declares it.
	Naming the shape instead of the classes is what lets one code path drive either
	without branching on rig generation everywhere.
]]
export type Joint = Instance & { Transform: CFrame }

local PosePlayback = {}

--[[
	Finds the joint a motion drives, translating R15 joint names to their R6
	equivalents on an R6 rig. Joints with no equivalent return nil and are dropped,
	which is how a pose degrades on R6 rather than erroring.

	Matched on name *and* class rather than name alone: a rig carries several
	instances per joint — RightShoulderAttachment, RightShoulderBallSocket — and a
	plain name search can land on one of those instead.
]]
function PosePlayback.FindJoint(character: Model, rigType: Enum.HumanoidRigType, jointName: string): Joint?
	local name = jointName
	if rigType == Enum.HumanoidRigType.R6 then
		local alias = PoseConfig.R6Joints[jointName]
		if alias == nil then
			return nil
		end
		name = alias
	end

	for _, descendant in character:GetDescendants() do
		if descendant.Name == name then
			if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
				-- Sound by the check above; the cast only bridges the type the two
				-- joint classes are missing in common.
				return (descendant :: any) :: Joint
			end
		end
	end
	return nil
end

--[[
	Where a joint sits at a given point through its motion, 0 at Rest and 1 at Peak.
]]
function PosePlayback.PoseAt(motion: PoseConfig.JointMotion, alpha: number): CFrame
	local angles = motion.Rest:Lerp(motion.Peak, alpha)
	local rotation = CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))

	local restOffset = motion.RestOffset
	local peakOffset = motion.PeakOffset
	if restOffset == nil and peakOffset == nil then
		return rotation
	end

	local from = restOffset or Vector3.zero
	local offset = from:Lerp(peakOffset or from, alpha)
	return CFrame.new(offset) * rotation
end

local function smootherstep(alpha: number): number
	local t = math.clamp(alpha, 0, 1)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

--[[
	How far through its motion one joint is, this many seconds into the exercise.

	Controlled strength reps now have four readable beats: lift, squeeze/lockout,
	return, settle. The old cosine never stopped at either turnaround, which made a
	heavy squat, press or curl look weightless. Cyclical exercises opt into the
	continuous cosine so ropes, climbing and stairs never hitch between strokes.

	Phase offsets the full cycle before shaping it, preserving alternating limbs.
]]
function PosePlayback.AlphaAt(
	pose: PoseConfig.Pose,
	motion: PoseConfig.JointMotion,
	elapsed: number,
	interval: number
): number
	local phase = (elapsed / interval * pose.Cycles + (motion.Phase or 0)) % 1
	if pose.MotionStyle == "Continuous" then
		return 0.5 - 0.5 * math.cos(phase * math.pi * 2)
	end
	--[[
		Snapped: the cosine, pushed toward its own extremes.

		StrikeConfig's header makes the point that "the anime read comes from the timing
		far more than the angles" — a cartoon motion holds at full extension and crosses
		between poses in two frames, where a real one is roughly symmetric. A pure cosine
		is the *most* symmetric curve available, so anime poses played on it still read as
		realistic.

		Running the cosine through smootherstep flattens it near 0 and 1 and steepens it
		through the middle, so a limb spends most of the cycle near full extension and
		transits fast. Deliberately not a literal hold: freezing a joint for a third of
		every stride reads as dropped frames rather than as style, and this keeps the
		motion continuous while getting most of the same read.
	]]
	if pose.MotionStyle == "Snapped" then
		return smootherstep(0.5 - 0.5 * math.cos(phase * math.pi * 2))
	end

	-- 40% concentric, 10% squeeze, 42% controlled eccentric, 8% settled reset.
	if phase < 0.4 then
		return smootherstep(phase / 0.4)
	elseif phase < 0.5 then
		return 1
	elseif phase < 0.92 then
		return 1 - smootherstep((phase - 0.5) / 0.42)
	end
	return 0
end

return PosePlayback
