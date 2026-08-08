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
			{ Joint = "RightShoulder", Rest = deg(0, 0, 145), Peak = deg(0, 0, 136) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -145), Peak = deg(0, 0, -136) },
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
	{
		-- Synchronous barbell curl. The small shoulder sweep keeps the motion
		-- readable on simplified rigs while the elbows perform most of the lift.
		Id = "BarbellCurl",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(2, 0, 9), Peak = deg(-12, 0, 12) },
			{ Joint = "LeftShoulder", Rest = deg(2, 0, -9), Peak = deg(-12, 0, -12) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(120, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(120, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(-4, 0, 0) },
			{ Joint = "RightHip", Rest = deg(0, 0, 5), Peak = deg(0, 0, 5) },
			{ Joint = "LeftHip", Rest = deg(0, 0, -5), Peak = deg(0, 0, -5) },
		},
	},
	{
		-- Cable pushdown: elbows extend beside the ribs and the shoulders settle
		-- slightly as the bar reaches the thighs.
		Id = "TricepsPushdown",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(18, 0, 10), Peak = deg(3, 0, 8) },
			{ Joint = "LeftShoulder", Rest = deg(18, 0, -10), Peak = deg(3, 0, -8) },
			{ Joint = "RightElbow", Rest = deg(105, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(105, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "Waist", Rest = deg(-8, 0, 0), Peak = deg(-5, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-3, 0, 5), Peak = deg(0, 0, 5) },
			{ Joint = "LeftHip", Rest = deg(-3, 0, -5), Peak = deg(0, 0, -5) },
		},
	},
	{
		-- Incline dumbbell press. The anchor supplies the bench angle; these joint
		-- transforms lower the weights wide and press them above the upper chest.
		Id = "InclinePress",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(55, 0, 24), Peak = deg(82, 0, 8) },
			{ Joint = "LeftShoulder", Rest = deg(55, 0, -24), Peak = deg(82, 0, -8) },
			{ Joint = "RightElbow", Rest = deg(75, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(75, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "Waist", Rest = deg(-5, 0, 0), Peak = deg(-2, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-45, 0, 8), Peak = deg(-42, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-45, 0, -8), Peak = deg(-42, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-60, 0, 0), Peak = deg(-60, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-60, 0, 0), Peak = deg(-60, 0, 0) },
		},
	},
	{
		-- Pec-deck fly: bent arms sweep from a wide position to meet in front of
		-- the chest while the torso stays against the back pad.
		Id = "PecDeck",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(20, 0, 78), Peak = deg(70, 0, 12) },
			{ Joint = "LeftShoulder", Rest = deg(20, 0, -78), Peak = deg(70, 0, -12) },
			{ Joint = "RightElbow", Rest = deg(85, 0, 0), Peak = deg(78, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(85, 0, 0), Peak = deg(78, 0, 0) },
			{ Joint = "Waist", Rest = deg(-4, 0, 0), Peak = deg(2, 0, 0) },
			{ Joint = "RightHip", Rest = deg(72, 0, 7), Peak = deg(70, 0, 7) },
			{ Joint = "LeftHip", Rest = deg(72, 0, -7), Peak = deg(70, 0, -7) },
			{ Joint = "RightKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
		},
	},
	{
		-- Seated cable row. Arms reach toward the stack, then the shoulders and
		-- elbows pull the close-grip handle to the abdomen without a large body swing.
		Id = "SeatedRow",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(45, 0, 10), Peak = deg(-15, 0, 18) },
			{ Joint = "LeftShoulder", Rest = deg(45, 0, -10), Peak = deg(-15, 0, -18) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(95, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(95, 0, 0) },
			{ Joint = "Waist", Rest = deg(8, 0, 0), Peak = deg(-4, 0, 0) },
			{ Joint = "RightHip", Rest = deg(68, 0, 7), Peak = deg(64, 0, 7) },
			{ Joint = "LeftHip", Rest = deg(68, 0, -7), Peak = deg(64, 0, -7) },
			{ Joint = "RightKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
		},
	},
	{
		-- Lat pulldown from full overhead reach to a bar near the upper chest.
		-- Shoulders remain below the rig's measured reversal threshold.
		Id = "LatPulldown",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(0, 0, 145), Peak = deg(10, 0, 90) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -145), Peak = deg(10, 0, -90) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(95, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(95, 0, 0) },
			{ Joint = "Waist", Rest = deg(-8, 0, 0), Peak = deg(-12, 0, 0) },
			{ Joint = "RightHip", Rest = deg(72, 0, 7), Peak = deg(68, 0, 7) },
			{ Joint = "LeftHip", Rest = deg(72, 0, -7), Peak = deg(68, 0, -7) },
			{ Joint = "RightKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
		},
	},
	{
		-- Captain's-chair knee raise. The upper body presses into the pads while
		-- the pelvis rises and both knees fold toward the torso.
		Id = "KneeRaise",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(-6, 0, 0),
				RestOffset = Vector3.new(0, -0.08, 0),
				PeakOffset = Vector3.new(0, 0.25, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(0, 0, 132), Peak = deg(-8, 0, 125) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -132), Peak = deg(-8, 0, -125) },
			{ Joint = "RightElbow", Rest = deg(20, 0, 0), Peak = deg(24, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(20, 0, 0), Peak = deg(24, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(20, 0, 0) },
			{ Joint = "RightHip", Rest = deg(0, 0, 6), Peak = deg(75, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(0, 0, -6), Peak = deg(75, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-10, 0, 0), Peak = deg(-105, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-10, 0, 0), Peak = deg(-105, 0, 0) },
		},
	},
	{
		-- Seated transverse rotation. Root and waist share the turn so the exercise
		-- stays visible on rigs that do not expose a separate waist joint.
		Id = "TorsoTwist",
		Cycles = 1,
		Joints = {
			{ Joint = "Root", Rest = deg(0, -12, 0), Peak = deg(0, 12, 0) },
			{ Joint = "Waist", Rest = deg(0, -35, 0), Peak = deg(0, 35, 0) },
			{ Joint = "RightShoulder", Rest = deg(62, -8, 12), Peak = deg(68, 8, 10) },
			{ Joint = "LeftShoulder", Rest = deg(62, -8, -12), Peak = deg(68, 8, -10) },
			{ Joint = "RightElbow", Rest = deg(20, 0, 0), Peak = deg(20, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(20, 0, 0), Peak = deg(20, 0, 0) },
			{ Joint = "RightHip", Rest = deg(70, 8, 7), Peak = deg(70, -8, 7) },
			{ Joint = "LeftHip", Rest = deg(70, 8, -7), Peak = deg(70, -8, -7) },
			{ Joint = "RightKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
		},
	},
	{
		-- Barbell squat. Root translation lowers the whole rig while simultaneous
		-- hip and knee flexion keeps the movement compact inside the rack.
		Id = "SquatRack",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(8, 0, 0),
				RestOffset = Vector3.new(0, 0, 0),
				PeakOffset = Vector3.new(0, -1.4, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(-8, 0, 58), Peak = deg(-2, 0, 54) },
			{ Joint = "LeftShoulder", Rest = deg(-8, 0, -58), Peak = deg(-2, 0, -54) },
			{ Joint = "RightElbow", Rest = deg(95, 0, 0), Peak = deg(100, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(95, 0, 0), Peak = deg(100, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "RightHip", Rest = deg(0, 0, 6), Peak = deg(65, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(0, 0, -6), Peak = deg(65, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-5, 0, 0), Peak = deg(-90, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-5, 0, 0), Peak = deg(-90, 0, 0) },
		},
	},
	{
		-- Reclined leg press. The machine anchor supplies the seat angle; the legs
		-- drive from a controlled ninety-degree fold toward relaxed extension.
		Id = "LegPress",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(-3, 0, 0),
				RestOffset = Vector3.new(0, 0, 0),
				PeakOffset = Vector3.new(0, 0.12, -0.08),
			},
			{ Joint = "RightShoulder", Rest = deg(-5, 0, 18), Peak = deg(2, 0, 14) },
			{ Joint = "LeftShoulder", Rest = deg(-5, 0, -18), Peak = deg(2, 0, -14) },
			{ Joint = "RightElbow", Rest = deg(75, 0, 0), Peak = deg(72, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(75, 0, 0), Peak = deg(72, 0, 0) },
			{ Joint = "Waist", Rest = deg(-8, 0, 0), Peak = deg(-3, 0, 0) },
			{ Joint = "RightHip", Rest = deg(65, 0, 7), Peak = deg(10, 0, 5) },
			{ Joint = "LeftHip", Rest = deg(65, 0, -7), Peak = deg(10, 0, -5) },
			{ Joint = "RightKnee", Rest = deg(-100, 0, 0), Peak = deg(-8, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-100, 0, 0), Peak = deg(-8, 0, 0) },
			{ Joint = "RightAnkle", Rest = deg(15, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "LeftAnkle", Rest = deg(15, 0, 0), Peak = deg(0, 0, 0) },
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
