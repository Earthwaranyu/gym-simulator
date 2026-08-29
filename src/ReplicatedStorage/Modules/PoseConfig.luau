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
	-- A third key, halfway through the joint's travel by default. Two states can
	-- only ever describe a straight line between them, so a bar path that should
	-- arc — around the chest on a press, in toward the shoulders on a curl — has
	-- to be faked by compromising both ends. Mid is the point the joint actually
	-- passes through; MidAt moves it earlier or later in the stroke.
	Mid: Vector3?,
	MidAt: number?,
	MidOffset: Vector3?,
	-- Shifts this joint's clock against the pose's, in cycles. Small negative
	-- values make a joint lead and positive ones make it follow, which is the
	-- cheapest source of overlapping action available: without it every joint in
	-- the body starts and stops on the same frame, and a body that moves as one
	-- rigid piece is the single clearest tell that an animation was generated.
	-- Unlike Phase this is meant to be tiny — 0.02-0.06, not half a cycle.
	Lead: number?,
}

export type Pose = {
	Id: string,
	-- Full out-and-back cycles per rep.
	Cycles: number,
	-- Strength reps briefly settle at both turnarounds. Continuous motions such as
	-- ropes and stairs keep flowing through them instead.
	-- Snapped holds near both extremes and crosses fast between them; see
	-- PosePlayback.AlphaAt. It is what the gait uses, and nothing in this file does.
	MotionStyle: ("Controlled" | "Continuous" | "Snapped")?,
	-- The four beats of a Controlled rep as fractions of the cycle: how long the
	-- lift takes, the squeeze at the top, the eccentric back down, and the settle
	-- at the bottom. They are normalised, so they need not sum to 1. Omitted, a
	-- pose gets PosePlayback.DEFAULT_TEMPO. A deadlift and a curl are not the same
	-- tempo, and before this they were.
	Tempo: { Lift: number, Squeeze: number, Lower: number, Settle: number }?,
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
			-- The torso is completely braced against the pad. Nearly all visible travel
			-- comes from elbow extension, so the carried bar moves perpendicular to the
			-- chest instead of the avatar folding around it.
			--
			-- Two things were making this read as a bar swinging rather than a bar being
			-- pressed, both measured on the rig by tracking the hand midpoint in the
			-- torso's own frame (chest faces local -Z, the head/foot axis is local Y):
			--
			--   old  sh 68->86 / el 88->4 : travel 0.69, of which 0.43 was Y
			--   new  sh -20->85 / el 145->5 : travel 0.81, of which 0.02 was Y
			--
			-- The old numbers spent 62% of the motion sliding the hands toward the head
			-- instead of away from the chest, so the bar tracked a path about 39 degrees
			-- off perpendicular — it visibly tilted through an arc rather than rising.
			-- Starting the shoulder *behind* the chest and taking the elbow through a
			-- much larger fold sends the hands almost straight up off the sternum.
			--
			-- Shoulder Z is also held constant now. Narrowing it through the press (it
			-- used to run 24 -> 8) walks the hands together on the way up, and the line
			-- joining them is exactly what orients the barbell, so a grip that changes
			-- width mid-rep is a bar that rolls. Grip width is set before the lift.
			{ Joint = "Root", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(-20, 0, 20), Peak = deg(85, 0, 20) },
			{ Joint = "LeftShoulder", Rest = deg(-20, 0, -20), Peak = deg(85, 0, -20) },
			{ Joint = "RightElbow", Rest = deg(145, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(145, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-42, 0, 8), Peak = deg(-42, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-42, 0, -8), Peak = deg(-42, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-68, 0, 0), Peak = deg(-68, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-68, 0, 0), Peak = deg(-68, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "Neck", Rest = deg(8, 0, 0), Peak = deg(8, 0, 0) },
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
			-- The load stays against the chest rather than being swung overhead. This
			-- keeps the hands quiet and makes the trunk, not momentum, drive the rep.
			{ Joint = "RightShoulder", Rest = deg(52, 0, 22), Peak = deg(52, 0, 22) },
			{ Joint = "LeftShoulder", Rest = deg(52, 0, -22), Peak = deg(52, 0, -22) },
			{ Joint = "RightElbow", Rest = deg(92, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(92, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "RightHip", Rest = deg(20, 0, 8), Peak = deg(20, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(20, 0, -8), Peak = deg(20, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-70, 0, 0), Peak = deg(-70, 0, 0) },
		},
	},
	{
		-- Goblet squat: the plate stays tight to the sternum while the hips travel
		-- down and slightly back. Hip and knee flexion move together, the torso leans
		-- only enough to keep the combined centre of mass over the mid-foot, and the
		-- knees remain mirrored instead of becoming a running stride.
		Id = "GobletSquat",
		Cycles = 1,
		Joints = {
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightHip", Rest = deg(2, 0, 7), Peak = deg(42, 0, 9) },
			{ Joint = "LeftHip", Rest = deg(2, 0, -7), Peak = deg(42, 0, -9) },
			{ Joint = "RightKnee", Rest = deg(-3, 0, 0), Peak = deg(-68, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-3, 0, 0), Peak = deg(-68, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(48, 0, 24), Peak = deg(48, 0, 24) },
			{ Joint = "LeftShoulder", Rest = deg(48, 0, -24), Peak = deg(48, 0, -24) },
			{ Joint = "RightElbow", Rest = deg(102, 0, 0), Peak = deg(102, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(102, 0, 0), Peak = deg(102, 0, 0) },
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, 0, 0),
				PeakOffset = Vector3.new(0, -0.82, 0),
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
			{ Joint = "Root", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			-- Same correction as BenchPress, and for the same measured reason: press
			-- from behind the chest through a deep elbow fold so the weights travel
			-- perpendicular to it, and hold shoulder Z constant so the hands do not
			-- converge on the way up.
			{ Joint = "RightShoulder", Rest = deg(-18, 0, 22), Peak = deg(88, 0, 22) },
			{ Joint = "LeftShoulder", Rest = deg(-18, 0, -22), Peak = deg(88, 0, -22) },
			{ Joint = "RightElbow", Rest = deg(142, 0, 0), Peak = deg(4, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(142, 0, 0), Peak = deg(4, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-38, 0, 8), Peak = deg(-38, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-38, 0, -8), Peak = deg(-38, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-65, 0, 0), Peak = deg(-65, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-65, 0, 0), Peak = deg(-65, 0, 0) },
			{ Joint = "Neck", Rest = deg(6, 0, 0), Peak = deg(6, 0, 0) },
		},
	},
	{
		-- Pec-deck fly: bent arms sweep from a wide position to meet in front of
		-- the chest while the torso stays against the back pad.
		Id = "PecDeck",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(58, 0, 72), Peak = deg(82, -8, 16) },
			{ Joint = "LeftShoulder", Rest = deg(58, 0, -72), Peak = deg(82, 8, -16) },
			{ Joint = "RightElbow", Rest = deg(76, 0, 0), Peak = deg(64, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(76, 0, 0), Peak = deg(64, 0, 0) },
			{ Joint = "Waist", Rest = deg(-3, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightHip", Rest = deg(70, 0, 7), Peak = deg(70, 0, 7) },
			{ Joint = "LeftHip", Rest = deg(70, 0, -7), Peak = deg(70, 0, -7) },
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
		MotionStyle = "Continuous",
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
		-- Read against this pose's direction: Rest is standing and Peak is the hole,
		-- so Lift is the descent and Lower is the drive out of it. The ascent gets
		-- the longest beat because that is the half a squat grinds through.
		Tempo = { Lift = 0.34, Squeeze = 0.06, Lower = 0.52, Settle = 0.08 },
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, 0, 0),
				-- How deep the body may drop is not a free choice: it is exactly how
				-- far the folded leg lifts the feet, or they leave the floor (too
				-- shallow) or sink through it (too deep). Measured on the rig by
				-- holding the leg angles and reading the sole height against a
				-- straight-legged reference:
				--
				--   hip  42, knee  -68  ->  0.303   (what this pose used to hold)
				--   hip  78, knee  -90  ->  0.670
				--   hip 110, knee -125  ->  1.133
				--
				-- The old pose paired the first of those with a 0.82 drop, so it drove
				-- the feet half a stud into the platform every rep and still only read
				-- as a dip. Going to a genuinely deep fold buys 1.13 studs of honest
				-- travel with the soles staying exactly on the floor.
				PeakOffset = Vector3.new(0, -1.13, 0),
			},
			-- The bar on the back settles a beat behind the legs, same reasoning as
			-- the deadlift's waist.
			{ Joint = "RightShoulder", Rest = deg(-8, 0, 58), Peak = deg(-2, 0, 54), Lead = 0.02 },
			{ Joint = "LeftShoulder", Rest = deg(-8, 0, -58), Peak = deg(-2, 0, -54), Lead = 0.02 },
			{ Joint = "RightElbow", Rest = deg(95, 0, 0), Peak = deg(100, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(95, 0, 0), Peak = deg(100, 0, 0) },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightHip", Rest = deg(0, 0, 7), Peak = deg(110, 0, 9) },
			{ Joint = "LeftHip", Rest = deg(0, 0, -7), Peak = deg(110, 0, -9) },
			{ Joint = "RightKnee", Rest = deg(-3, 0, 0), Peak = deg(-125, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-3, 0, 0), Peak = deg(-125, 0, 0) },
			-- The shin finishes behind vertical at that fold, so the foot has to come
			-- forward to stay flat on the platform. Without an ankle the depth above
			-- would stand the avatar on its heels, which is the reason this squat was
			-- kept shallow before.
			{ Joint = "RightAnkle", Rest = deg(0, 0, 0), Peak = deg(15, 0, 0) },
			{ Joint = "LeftAnkle", Rest = deg(0, 0, 0), Peak = deg(15, 0, 0) },
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
	{
		Id = "PushUps",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.45, 0),
				PeakOffset = Vector3.new(0, 0.25, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(72, 0, 42), Peak = deg(88, 0, 18) },
			{ Joint = "LeftShoulder", Rest = deg(72, 0, -42), Peak = deg(88, 0, -18) },
			{ Joint = "RightElbow", Rest = deg(95, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(95, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "Waist", Rest = deg(4, 0, 0), Peak = deg(0, 0, 0) },
		},
	},
	{
		Id = "CableCrossover",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(15, 0, 105), Peak = deg(72, -12, 18) },
			{ Joint = "LeftShoulder", Rest = deg(15, 0, -105), Peak = deg(72, 12, -18) },
			{ Joint = "RightElbow", Rest = deg(28, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(28, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "Waist", Rest = deg(-8, 0, 0), Peak = deg(-14, 0, 0) },
			-- Both hips brace the same way. The left used to read +8 on X against the
			-- right's -8, so one leg stood forward and the other back for no reason —
			-- the Z values mirrored correctly and the X did not, which is the signature
			-- of a sign typo rather than a stance.
			{ Joint = "RightHip", Rest = deg(-8, 0, 8), Peak = deg(-8, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-8, 0, -8), Peak = deg(-8, 0, -8) },
		},
	},
	{
		Id = "ChestDip",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(-8, 0, 0),
				Peak = deg(-15, 0, 0),
				RestOffset = Vector3.new(0, 0.45, 0),
				PeakOffset = Vector3.new(0, -0.65, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(-12, 0, 18), Peak = deg(-35, 0, 28) },
			{ Joint = "LeftShoulder", Rest = deg(-12, 0, -18), Peak = deg(-35, 0, -28) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(105, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(105, 0, 0) },
			{ Joint = "Waist", Rest = deg(-5, 0, 0), Peak = deg(-18, 0, 0) },
		},
	},
	{
		Id = "DeclinePress",
		Cycles = 1,
		Joints = {
			-- Constant shoulder Z and a deep elbow fold, the same correction BenchPress
			-- and InclinePress needed and for the same reason: running Z from 35 to 10
			-- walks the hands together as the bar rises, and the line between the hands
			-- is what orients the barbell, so the bar tracked a diagonal instead of a
			-- press.
			{ Joint = "RightShoulder", Rest = deg(-16, 0, 24), Peak = deg(86, 0, 24) },
			{ Joint = "LeftShoulder", Rest = deg(-16, 0, -24), Peak = deg(86, 0, -24) },
			{ Joint = "RightElbow", Rest = deg(140, 0, 0), Peak = deg(6, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(140, 0, 0), Peak = deg(6, 0, 0) },
			{ Joint = "Waist", Rest = deg(8, 0, 0), Peak = deg(5, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-58, 0, 8), Peak = deg(-58, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-58, 0, -8), Peak = deg(-58, 0, -8) },
		},
	},
	{
		Id = "HammerCurl",
		Cycles = 1,
		Joints = {
			{ Joint = "RightElbow", Rest = deg(5, 0, 12), Peak = deg(118, 0, 12) },
			{ Joint = "LeftElbow", Rest = deg(5, 0, -12), Peak = deg(118, 0, -12), Phase = 0.5 },
			{ Joint = "RightShoulder", Rest = deg(2, 0, 5), Peak = deg(-8, 0, 7) },
			{ Joint = "LeftShoulder", Rest = deg(2, 0, -5), Peak = deg(-8, 0, -7), Phase = 0.5 },
			{ Joint = "Waist", Rest = deg(0, 0, 0), Peak = deg(-3, 0, 0) },
		},
	},
	{
		Id = "PreacherCurl",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(42, 0, 14), Peak = deg(42, 0, 14) },
			{ Joint = "LeftShoulder", Rest = deg(42, 0, -14), Peak = deg(42, 0, -14) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(118, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(118, 0, 0) },
			{ Joint = "Waist", Rest = deg(-12, 0, 0), Peak = deg(-8, 0, 0) },
			-- Actually sit. This pose drove no hip or knee at all, so the lifter stood
			-- bolt upright at seat height and its straight legs ran down through the
			-- seat and the base — read as the whole lower body being swallowed by the
			-- bench. Same fold as every other seated rig, which also carries the thighs
			-- forward far enough to clear the pad's front edge.
			{ Joint = "RightHip", Rest = deg(70, 0, 7), Peak = deg(70, 0, 7) },
			{ Joint = "LeftHip", Rest = deg(70, 0, -7), Peak = deg(70, 0, -7) },
			{ Joint = "RightKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-82, 0, 0), Peak = deg(-82, 0, 0) },
		},
	},
	{
		Id = "SkullCrusher",
		Cycles = 1,
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(82, 0, 12), Peak = deg(82, 0, 10) },
			{ Joint = "LeftShoulder", Rest = deg(82, 0, -12), Peak = deg(82, 0, -10) },
			{ Joint = "RightElbow", Rest = deg(115, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(115, 0, 0), Peak = deg(8, 0, 0) },
			{ Joint = "RightHip", Rest = deg(-48, 0, 8), Peak = deg(-48, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-48, 0, -8), Peak = deg(-48, 0, -8) },
		},
	},
	{
		Id = "BattleRopes",
		Cycles = 1,
		MotionStyle = "Continuous",
		Joints = {
			{ Joint = "RightShoulder", Rest = deg(-28, 0, 16), Peak = deg(58, 0, 12) },
			{ Joint = "LeftShoulder", Rest = deg(-28, 0, -16), Peak = deg(58, 0, -12), Phase = 0.5 },
			{ Joint = "RightElbow", Rest = deg(35, 0, 0), Peak = deg(70, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(35, 0, 0), Peak = deg(70, 0, 0), Phase = 0.5 },
			{ Joint = "Waist", Rest = deg(12, 0, 0), Peak = deg(20, 0, 0) },
			{ Joint = "RightKnee", Rest = deg(-25, 0, 0), Peak = deg(-38, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-25, 0, 0), Peak = deg(-38, 0, 0) },
		},
	},
	{
		Id = "Deadlift",
		Cycles = 1,
		-- A deadlift is not a curl. The pull is the slow part, the bar comes back
		-- down faster than it went up, and the rep genuinely ends — the plates rest
		-- on the floor before the next one starts, which is what the long settle is.
		Tempo = { Lift = 0.44, Squeeze = 0.10, Lower = 0.30, Settle = 0.16 },
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				-- Rest is the floor and Peak is lockout, so the drop lives on Rest, and
				-- it is sized the same measured way as SquatRack: hip 65 / knee -70
				-- lifts the soles 0.47 against a straight leg, so the root goes down by
				-- exactly that and the feet stay on the platform.
				RestOffset = Vector3.new(0, -0.47, 0),
				PeakOffset = Vector3.new(0, 0, 0),
			},
			-- The hinge is the Waist, not the hips. Rotating Root would pitch the whole
			-- avatar including the legs — that is what a T-bar row leans into, but a
			-- deadlifter's shins stay under them. Waist pitches the trunk over legs
			-- that are folding underneath it, which is the actual movement, and the
			-- earlier "rubbery" note came from curling the trunk with nothing else
			-- moving rather than from using this joint at all.
			--
			-- Between the trunk pitch and the leg fold the bar now travels roughly
			-- 2.1 studs, against the 0.7 it had when the hinge was 34 degrees of hip.
			-- The trunk finishes a hair after the legs do. Everything arriving on the
			-- same frame is what made the lift look weightless; letting the heaviest
			-- segment lag slightly is most of the difference between lifting a loaded
			-- bar and miming one.
			{ Joint = "Waist", Rest = deg(55, 0, 0), Peak = deg(0, 0, 0), Lead = 0.04 },
			{ Joint = "RightHip", Rest = deg(65, 0, 8), Peak = deg(0, 0, 6) },
			{ Joint = "LeftHip", Rest = deg(65, 0, -8), Peak = deg(0, 0, -6) },
			{ Joint = "RightKnee", Rest = deg(-70, 0, 0), Peak = deg(-3, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-70, 0, 0), Peak = deg(-3, 0, 0) },
			-- Shin sits 5 degrees behind vertical at the floor; the foot matches it.
			{ Joint = "RightAnkle", Rest = deg(5, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "LeftAnkle", Rest = deg(5, 0, 0), Peak = deg(0, 0, 0) },
			-- Shoulder X is measured against a trunk already pitched 55 forward, so
			-- -48 hangs the arms all but plumb at the floor. Straight arms throughout:
			-- a deadlift is not a row, and bending the elbows under load would also
			-- shorten the bar's travel back toward the arc it used to have.
			{ Joint = "RightShoulder", Rest = deg(-48, 0, 13), Peak = deg(0, 0, 12), Lead = 0.03 },
			{ Joint = "LeftShoulder", Rest = deg(-48, 0, -13), Peak = deg(0, 0, -12), Lead = 0.03 },
			{ Joint = "RightElbow", Rest = deg(4, 0, 0), Peak = deg(4, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(4, 0, 0), Peak = deg(4, 0, 0) },
		},
	},
	{
		Id = "TBarRow",
		Cycles = 1,
		Joints = {
			{ Joint = "Root", Rest = deg(31, 0, 0), Peak = deg(31, 0, 0) },
			{ Joint = "Waist", Rest = deg(5, 0, 0), Peak = deg(2, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(50, 0, 12), Peak = deg(-12, 0, 20) },
			{ Joint = "LeftShoulder", Rest = deg(50, 0, -12), Peak = deg(-12, 0, -20) },
			{ Joint = "RightElbow", Rest = deg(8, 0, 0), Peak = deg(105, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(8, 0, 0), Peak = deg(105, 0, 0) },
			{ Joint = "RightHip", Rest = deg(25, 0, 8), Peak = deg(20, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(25, 0, -8), Peak = deg(20, 0, -8) },
		},
	},
	{
		Id = "BackExtension",
		Cycles = 1,
		Joints = {
			{ Joint = "Root", Rest = deg(28, 0, 0), Peak = deg(-4, 0, 0) },
			{ Joint = "Waist", Rest = deg(7, 0, 0), Peak = deg(0, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(52, 0, 22), Peak = deg(52, 0, 22) },
			{ Joint = "LeftShoulder", Rest = deg(52, 0, -22), Peak = deg(52, 0, -22) },
			{ Joint = "RightElbow", Rest = deg(92, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(92, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "RightHip", Rest = deg(15, 0, 8), Peak = deg(-8, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(15, 0, -8), Peak = deg(-8, 0, -8) },
		},
	},
	{
		Id = "RopeClimb",
		Cycles = 1,
		MotionStyle = "Continuous",
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.75, 0),
				PeakOffset = Vector3.new(0, 0.75, 0),
			},
			-- Reaching up in front rather than out to the sides. Abduction on Z can
			-- never bring a hand onto the centreline — the shoulder gives out at
			-- about 150 degrees and the hands finished 1.4 studs off the rope —
			-- whereas flexion on X puts them overhead where the rope now hangs. The
			-- negative Z adducts each arm across the body so both hands close on the
			-- same rope instead of straddling it a stud and a half either side.
			{ Joint = "RightShoulder", Rest = deg(145, 0, -18), Peak = deg(95, 0, -18) },
			{ Joint = "LeftShoulder", Rest = deg(95, 0, 18), Peak = deg(145, 0, 18) },
			{ Joint = "RightElbow", Rest = deg(12, 0, 0), Peak = deg(100, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(100, 0, 0), Peak = deg(12, 0, 0) },
			{ Joint = "RightHip", Rest = deg(5, 0, 8), Peak = deg(55, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(55, 0, -8), Peak = deg(5, 0, -8) },
		},
	},
	{
		Id = "Plank",
		Cycles = 1,
		MotionStyle = "Continuous",
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.08, 0),
				PeakOffset = Vector3.new(0, 0.12, 0),
			},
			{ Joint = "RightShoulder", Rest = deg(75, 0, 22), Peak = deg(82, 0, 18) },
			{ Joint = "LeftShoulder", Rest = deg(75, 0, -22), Peak = deg(82, 0, -18) },
			{ Joint = "RightElbow", Rest = deg(88, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(88, 0, 0), Peak = deg(92, 0, 0) },
			{ Joint = "Waist", Rest = deg(2, 0, 0), Peak = deg(-2, 0, 0) },
		},
	},
	{
		Id = "CableCrunch",
		Cycles = 1,
		Joints = {
			{ Joint = "Waist", Rest = deg(-6, 0, 0), Peak = deg(44, 0, 0) },
			{ Joint = "Neck", Rest = deg(-4, 0, 0), Peak = deg(12, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(0, 0, 125), Peak = deg(52, 0, 72) },
			{ Joint = "LeftShoulder", Rest = deg(0, 0, -125), Peak = deg(52, 0, -72) },
			{ Joint = "RightElbow", Rest = deg(90, 0, 0), Peak = deg(105, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(90, 0, 0), Peak = deg(105, 0, 0) },
			-- Kneeling. The machine has a knee pad and the exercise is done on it,
			-- but this pose used to leave the legs straight, which stood the lifter
			-- up with their feet through the floor and read as a standing crunch.
			{ Joint = "RightHip", Rest = deg(6, 0, 8), Peak = deg(16, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(6, 0, -8), Peak = deg(16, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-95, 0, 0), Peak = deg(-95, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-95, 0, 0), Peak = deg(-95, 0, 0) },
		},
	},
	{
		Id = "AbWheel",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(15, 0, 0),
				RestOffset = Vector3.new(0, 0, 0.7),
				PeakOffset = Vector3.new(0, -0.35, -1.1),
			},
			{ Joint = "Waist", Rest = deg(42, 0, 0), Peak = deg(-12, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(45, 0, 20), Peak = deg(118, 0, 15) },
			{ Joint = "LeftShoulder", Rest = deg(45, 0, -20), Peak = deg(118, 0, -15) },
			{ Joint = "RightHip", Rest = deg(75, 0, 8), Peak = deg(22, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(75, 0, -8), Peak = deg(22, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-95, 0, 0), Peak = deg(-95, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-95, 0, 0), Peak = deg(-95, 0, 0) },
		},
	},
	{
		Id = "WoodChop",
		Cycles = 1,
		Joints = {
			{ Joint = "Root", Rest = deg(5, -18, 0), Peak = deg(12, 18, 0) },
			{ Joint = "Waist", Rest = deg(-8, -42, 0), Peak = deg(28, 42, 0) },
			{ Joint = "RightShoulder", Rest = deg(15, -25, 110), Peak = deg(85, 20, 22) },
			{ Joint = "LeftShoulder", Rest = deg(15, -25, -65), Peak = deg(85, 20, -18) },
			{ Joint = "RightElbow", Rest = deg(25, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "LeftElbow", Rest = deg(25, 0, 0), Peak = deg(18, 0, 0) },
			{ Joint = "RightHip", Rest = deg(8, -12, 8), Peak = deg(28, 12, 8) },
			{ Joint = "LeftHip", Rest = deg(8, -12, -8), Peak = deg(28, 12, -8) },
		},
	},
	{
		Id = "LegExtension",
		Cycles = 1,
		Joints = {
			{ Joint = "RightHip", Rest = deg(72, 0, 8), Peak = deg(72, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(72, 0, -8), Peak = deg(72, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-95, 0, 0), Peak = deg(-5, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-95, 0, 0), Peak = deg(-5, 0, 0) },
			{ Joint = "Waist", Rest = deg(-5, 0, 0), Peak = deg(-2, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(-8, 0, 15), Peak = deg(-3, 0, 12) },
			{ Joint = "LeftShoulder", Rest = deg(-8, 0, -15), Peak = deg(-3, 0, -12) },
		},
	},
	{
		Id = "HamstringCurl",
		Cycles = 1,
		Joints = {
			{ Joint = "RightHip", Rest = deg(-8, 0, 8), Peak = deg(-8, 0, 8) },
			{ Joint = "LeftHip", Rest = deg(-8, 0, -8), Peak = deg(-8, 0, -8) },
			{ Joint = "RightKnee", Rest = deg(-5, 0, 0), Peak = deg(-105, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-5, 0, 0), Peak = deg(-105, 0, 0) },
			{ Joint = "Waist", Rest = deg(-4, 0, 0), Peak = deg(2, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(115, 0, 28), Peak = deg(115, 0, 28) },
			{ Joint = "LeftShoulder", Rest = deg(115, 0, -28), Peak = deg(115, 0, -28) },
		},
	},
	{
		Id = "CalfRaise",
		Cycles = 1,
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, 0, 0),
				PeakOffset = Vector3.new(0, 0.42, 0),
			},
			{ Joint = "RightAnkle", Rest = deg(-12, 0, 0), Peak = deg(25, 0, 0) },
			{ Joint = "LeftAnkle", Rest = deg(-12, 0, 0), Peak = deg(25, 0, 0) },
			{ Joint = "RightKnee", Rest = deg(-4, 0, 0), Peak = deg(-2, 0, 0) },
			{ Joint = "LeftKnee", Rest = deg(-4, 0, 0), Peak = deg(-2, 0, 0) },
			{ Joint = "RightShoulder", Rest = deg(25, 0, 18), Peak = deg(28, 0, 16) },
			{ Joint = "LeftShoulder", Rest = deg(25, 0, -18), Peak = deg(28, 0, -16) },
		},
	},
	{
		Id = "StairClimber",
		Cycles = 1,
		MotionStyle = "Continuous",
		Joints = {
			{
				Joint = "Root",
				Rest = deg(0, 0, 0),
				Peak = deg(0, 0, 0),
				RestOffset = Vector3.new(0, -0.18, 0),
				PeakOffset = Vector3.new(0, 0.18, 0),
			},
			{ Joint = "RightHip", Rest = deg(-12, 0, 5), Peak = deg(48, 0, 5) },
			{ Joint = "LeftHip", Rest = deg(-12, 0, -5), Peak = deg(48, 0, -5), Phase = 0.5 },
			{ Joint = "RightKnee", Rest = deg(-15, 0, 0), Peak = deg(-88, 0, 0), Phase = 0.2 },
			{ Joint = "LeftKnee", Rest = deg(-15, 0, 0), Peak = deg(-88, 0, 0), Phase = 0.7 },
			{ Joint = "RightShoulder", Rest = deg(18, 0, 10), Peak = deg(-20, 0, 10), Phase = 0.5 },
			{ Joint = "LeftShoulder", Rest = deg(18, 0, -10), Peak = deg(-20, 0, -10) },
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

function PoseConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	check(#poses == 35, "all 35 equipment poses are defined")
	for _, pose in poses do
		check(pose.Cycles == 1, `{pose.Id} has exactly one visual cycle per stat popup`)
		check(#pose.Joints > 0, `{pose.Id} drives at least one joint`)
		check(
			pose.MotionStyle == nil or pose.MotionStyle == "Controlled" or pose.MotionStyle == "Continuous",
			`{pose.Id} uses a supported motion style`
		)
	end
	for _, id in { "BenchPress", "InclinePress", "PecDeck", "GobletSquat", "SquatRack", "Deadlift" } do
		local pose = byId[id]
		check(pose ~= nil and pose.MotionStyle ~= "Continuous", `{id} uses controlled strength timing`)
	end
	for _, id in { "BattleRopes", "RopeClimb", "StairClimber" } do
		local pose = byId[id]
		check(pose ~= nil and pose.MotionStyle == "Continuous", `{id} stays continuous`)
	end

	return failures
end

return PoseConfig
