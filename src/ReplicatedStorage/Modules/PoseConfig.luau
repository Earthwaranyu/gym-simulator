--!strict
--[[
	PoseConfig — the training animations, expressed as joint motion rather than
	animation assets.

	Why not AnimationIds: a Roblox animation is an uploaded asset owned by some
	account. Referencing ids we do not own either fails to load or ships someone
	else's work, and inventing plausible ids silently animates whatever happens to
	live there. Every pose below is generated at runtime from these numbers, so the
	game animates out of the box and owns everything it plays.

	How a pose works: each entry lists joints and two rotations for each — Rest and
	Peak. The client eases between them on a sine, once per rep, and writes the
	result to the joint's Motor6D.Transform. Transform is what the animation system
	itself writes, so posing a joint overrides the idle animation on that joint only
	and leaves the rest of the body alone.

	Angles are degrees on the joint's own axes. For an R15 rig those axes line up
	with the torso, which makes the signs predictable:

	  * +X swings a limb forward, -X swings it back. A knee bends backward, so a
	    bent knee is negative; an elbow bends forward, so a curl is positive.
	  * +Z lifts the right arm out to the right; the left arm mirrors it.
	  * Offsets are studs, and only really matter on Root, which moves the whole
	    body — that is what lifts a player up the pull-up bar.

	**Keep angles under about 150.** Rigs carry BallSocketConstraints that limit how
	far a joint may actually travel, so past roughly 150 degrees the achieved angle
	stops tracking the requested one and then goes back the way it came: measured on
	a stock R15 avatar, a shoulder asked for 150 reaches 166, but asked for 180 it
	reaches only 149. A pose written past that ceiling does not merely clamp, it
	animates backwards. The same limits are why a lifter's feet hang short of the
	floor on the bench rather than planting on it — the hips will not fold that far.

	Adding a machine reuses a pose by id, or adds one entry here. Nothing consumes
	these except TrainingPoseController, which knows nothing about any specific pose.
]]

export type JointMotion = {
	-- Motor6D name on an R15 rig. Unknown joints are skipped, never an error.
	Joint: string,
	-- Rotation at the bottom of the rep, in degrees.
	Rest: Vector3,
	-- Rotation at the top. Equal to Rest for a joint that only holds a shape.
	Peak: Vector3,
	-- Translation in studs, if the joint should move as well as rotate.
	RestOffset: Vector3?,
	PeakOffset: Vector3?,
	-- Where in the cycle this joint starts, 0-1. 0.5 puts a limb in opposition,
	-- which is what makes alternating curls and a running stride read correctly.
	Phase: number?,
}

export type Pose = {
	Id: string,
	-- Full out-and-back cycles per rep.
	Cycles: number,
	Joints: { JointMotion },
}

local function deg(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local poses: { Pose } = {
	{
		-- Supine on a flat bench: press up, lower to the chest, knees over the side.
		Id = "BenchPress",
		Cycles = 1,
		Joints = {
			-- The bar is a fixed prop, so the bottom of the stroke is deliberately
			-- shallow: a full bench-press range of motion drops the hands far enough
			-- below it to read as letting go rather than lowering the weight.
			{ Joint = "RightShoulder", Rest = deg(66, 0, 26), Peak = deg(88, 0, 8) },
			{ Joint = "LeftShoulder", Rest = deg(66, 0, -26), Peak = deg(88, 0, -8) },
			{ Joint = "RightElbow", Rest = deg(66, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(66, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-50, 0, 8), Peak = deg(-50, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-50, 0, -8), Peak = deg(-50, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-55, 0, 0), Peak = deg(-55, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-55, 0, 0), Peak = deg(-55, 0, 0) },
			{ Joint = "Waist", Rest = deg(-6, 0, 0), Peak = deg(-6, 0, 0) },
			{ Joint = "Neck", Rest = deg(12, 0, 0), Peak = deg(12, 0, 0) },
		},
	},
	{
		-- Alternating dumbbell curls: the half-cycle phase is what alternates them.
		Id = "Curl",
		Cycles = 1,
		Joints = {
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(125, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(125, 0, 0), Phase = 0.5 },
			{ Joint = "RightShoulder", Rest = deg(0, 0, 8), Peak = deg(-14, 0, 10) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -8), Peak = deg(-14, 0, -10), Phase = 0.5 },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(-5, 0, 0) },
			{ Joint = "RightHip", Rest = deg(0, 0, 6), Peak = deg(0, 0, 6) },
			{ Joint = "LeftHip", Rest = deg(0, 0, -6), Peak = deg(0, 0, -6) },
		},
	},
	{
		-- Hanging from the bar. The vertical travel comes from Root, because no
		-- amount of joint rotation can lift a body that is hanging by its hands.
		Id = "PullUp",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.9, 0),
				PeakOffset = Vector3.new(0, 0.9, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(0, 0, 150), Peak = deg(0, 0, 136) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -150), Peak = deg(0, 0, -136) },
			{ Joint = "RightElbow", Rest = deg(10, 0, 0), Peak = deg(85, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(10, 0, 0), Peak = deg(85, 0, 0) },
			{ Joint = "RightHip", Rest = deg(12, 0, 6), Peak = deg(12, 0, 6) },
			{ Joint = "LeftHip", Rest = deg(12, 0, -6), Peak = deg(12, 0, -6) },
			{ Joint = "RightKnee", Rest = deg(-55, 0, 0), Peak = deg(-55, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-55, 0, 0), Peak = deg(-55, 0, 0) },
		},
	},
	{
		-- Reclined on the ab bench with the ankles under the rollers: the whole
		-- motion is the waist folding, with the neck following it.
		Id = "SitUp",
		Cycles = 1,
		Joints = {
			{ Joint = "Waist", Rest = deg(-10, 0, 0), Peak = deg(55, 0, 0) },
			{ Joint = "Neck", Rest = deg(0, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(120, 0, 35), Peak = deg(120, 0, 35) },
			{ Joint = "LeftShoulder", Rest = deg(120, 0, -35), Peak = deg(120, 0, -35) },
			{ Joint = "RightElbow", Rest = deg(120, 0, 0), Peak = deg(120, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(120, 0, 0), Peak = deg(120, 0, 0) },
			{ Joint = "RightHip", Rest = deg(20, 0, 8), Peak = deg(20, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(20, 0, -8), Peak = deg(20, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
		},
	},
	{
		-- Treadmill stride. Knees trail their hip by a quarter cycle, and the arms
		-- run half a cycle against the legs on the same side.
		Id = "Run",
		Cycles = 1,
		Joints = {
			{ Joint = "RightHip", Rest = deg(-30, 0, 4), Peak = deg(35, 0, 4) },
			{ Joint = "LeftHip", Rest = deg(-30, 0, -4), Peak = deg(35, 0, -4), Phase = 0.5 },
			{ Joint = "RightKnee", Rest = deg(-8, 0, 0), Peak = deg(-80, 0, 0), Phase = 0.25 },
			{ Joint = "LeftKnee", Rest = deg(-8, 0, 0), Peak = deg(-80, 0, 0), Phase = 0.75 },
			{ Joint = "RightShoulder", Rest = deg(32, 0, 8), Peak = deg(-30, 0, 8), Phase = 0.5 },
			{ Joint = "LeftShoulder", Rest = deg(32, 0, -8), Peak = deg(-30, 0, -8) },
			{ Joint = "RightElbow", Rest = deg(78, 0, 0), Peak = deg(78, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(78, 0, 0), Peak = deg(78, 0, 0) },
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.18, 0),
				PeakOffset = Vector3.new(0, 0.18, 0),
			},
		},
	},
}

local PoseConfig = {}

PoseConfig.List = poses

--[[
	Character attributes the server sets while a player is training. They are
	attributes rather than a remote because attributes replicate to every client
	for free — which is exactly what is needed, since each client has to animate
	every training player it can see, not just itself.
]]
PoseConfig.POSE_ATTRIBUTE = "TrainingPose"
PoseConfig.INTERVAL_ATTRIBUTE = "TrainingRepInterval"

--[[
	R15 joint name -> the equivalent on an R6 rig.

	R6 has a quarter of the joints and holds them at rotated rest angles, so a pose
	built for R15 lands approximately on R6 rather than exactly: shoulders, hips and
	neck move, and elbows, knees and the waist simply do not exist to move. That is
	a deliberate floor, not a bug — R15 is the default rig and the one poses are
	tuned against.
]]
local r6Joints: { [string]: string } = {
	RightShoulder = "Right Shoulder",
	LeftShoulder = "Left Shoulder",
	RightHip = "Right Hip",
	LeftHip = "Left Hip",
	Neck = "Neck",
	Root = "RootJoint",
}

PoseConfig.R6Joints = r6Joints

local byId: { [string]: Pose } = {}
for _, pose in poses do
	if byId[pose.Id] ~= nil then
		error(`[PoseConfig] Duplicate pose id "{pose.Id}"`)
	end
	byId[pose.Id] = pose
end

function PoseConfig.Get(poseId: string): Pose?
	return byId[poseId]
end

return PoseConfig
